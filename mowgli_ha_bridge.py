#!/usr/bin/env python3
"""
mowgli-ha-bridge — publish a MowgliNext robot's live state to an MQTT broker.

Why this exists
---------------
MowgliNext ships an MQTT page in its web UI, but on released images the ROS2
node behind it (`mqtt_bridge_node`) is compiled without libmosquitto: the
`#else` branch instantiates `StubMqttClient`, which only logs at DEBUG and
never contacts a broker. The launch file also gates the node behind
`enable_mqtt`, which the compose command never passes. So the settings page
cannot work, whatever you type into it.

This bridge sidesteps the robot entirely. It speaks the same WebSocket API the
robot's own web UI uses, and republishes each message as retained JSON on an
MQTT broker — typically the Mosquitto add-on of a Home Assistant install.

Nothing on the robot is modified. No image rebuild, no ROS2 changes. If a
future MowgliNext release ships a working bridge, stop this service and the
topics are the same.

Requirements: Python 3.9+, standard library only. No pip packages.

Topics published (with the default `mowgli` prefix):
    mowgli/status              <- ROS "status"          (blade, ESC, firmware)
    mowgli/power               <- ROS "power"           (battery volts, charger)
    mowgli/emergency           <- ROS "emergency"       (e-stop, latch, reason)
    mowgli/high_level_status   <- ROS "highLevelStatus" (state, battery %)
    mowgli/gps                 <- ROS "gnssStatus"      (fix, corrections)
    mowgli/available           <- "online" / "offline"  (MQTT last will)
"""

import base64
import json
import os
import random
import socket
import struct
import sys
import threading
import time

LOG_LOCK = threading.Lock()


def log(level, msg):
    with LOG_LOCK:
        print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} [{level}] {msg}", flush=True)


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
DEFAULTS = {
    "ROBOT_HOST": "127.0.0.1",
    "ROBOT_PORT": "4006",
    "MQTT_HOST": "",
    "MQTT_PORT": "1883",
    "MQTT_USERNAME": "",
    "MQTT_PASSWORD": "",
    "MQTT_CLIENT_ID": "mowgli-ha-bridge",
    "TOPIC_PREFIX": "mowgli",
    # Seconds between two publishes of the same topic. The robot streams far
    # faster than Home Assistant needs; without this the recorder database
    # grows for nothing.
    "MIN_PUBLISH_INTERVAL": "2.0",
}

# ROS topic on the robot -> MQTT topic suffix. The robot names them in
# camelCase; Home Assistant conventions prefer snake_case.
TOPIC_MAP = {
    "status": "status",
    "power": "power",
    "emergency": "emergency",
    "highLevelStatus": "high_level_status",
    "gnssStatus": "gps",
}


def load_config(path):
    cfg = dict(DEFAULTS)
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                cfg[key.strip()] = value.strip().strip('"').strip("'")
    # Environment wins over the file, so systemd drop-ins stay possible.
    for key in cfg:
        if key in os.environ:
            cfg[key] = os.environ[key]
    if not cfg["MQTT_HOST"]:
        raise SystemExit("MQTT_HOST is not set — check the configuration file.")
    return cfg


# ---------------------------------------------------------------------------
# Minimal MQTT 3.1.1 client (publish only, plus last will and keepalive)
# ---------------------------------------------------------------------------
class MqttClient:
    def __init__(self, host, port, client_id, username, password,
                 will_topic, keepalive=45):
        self.host, self.port = host, int(port)
        self.client_id = client_id
        self.username, self.password = username, password
        self.will_topic = will_topic
        self.keepalive = keepalive
        self.sock = None
        self.lock = threading.Lock()
        self.last_ping = 0.0

    # -- wire helpers -------------------------------------------------------
    @staticmethod
    def _len(n):
        out = bytearray()
        while True:
            byte = n % 128
            n //= 128
            if n:
                byte |= 0x80
            out.append(byte)
            if not n:
                return bytes(out)

    @staticmethod
    def _str(text):
        raw = text.encode("utf-8")
        return struct.pack(">H", len(raw)) + raw

    def _read_len(self):
        multiplier, value = 1, 0
        while True:
            chunk = self.sock.recv(1)
            if not chunk:
                raise ConnectionError("broker closed the connection")
            byte = chunk[0]
            value += (byte & 127) * multiplier
            if not byte & 0x80:
                return value
            multiplier *= 128

    # -- session ------------------------------------------------------------
    def connect(self):
        sock = socket.create_connection((self.host, self.port), timeout=10)
        sock.settimeout(20)
        self.sock = sock

        # clean session + last will "offline", retained so a viewer arriving
        # later still learns the bridge is down
        flags = 0x02 | 0x04 | 0x20
        payload = self._str(self.client_id)
        payload += self._str(self.will_topic) + self._str("offline")
        if self.username:
            flags |= 0x80
            payload += self._str(self.username)
            if self.password:
                flags |= 0x40
                payload += self._str(self.password)
        header = self._str("MQTT") + bytes([4, flags]) + struct.pack(">H", self.keepalive)
        packet = header + payload
        sock.sendall(b"\x10" + self._len(len(packet)) + packet)

        kind = sock.recv(1)
        if not kind or kind[0] >> 4 != 2:
            raise ConnectionError(f"expected CONNACK, got {kind!r}")
        body = sock.recv(self._read_len())
        code = body[1] if len(body) > 1 else 0xFF
        if code:
            reasons = {
                1: "protocol version refused",
                2: "client id rejected",
                3: "broker unavailable",
                4: "bad username or password",
                5: "not authorised — check the broker account",
            }
            raise ConnectionError(f"CONNACK refused ({code}): {reasons.get(code, 'unknown')}")
        self.last_ping = time.time()
        log("INFO", f"connected to MQTT broker {self.host}:{self.port} as '{self.username or 'anonymous'}'")

    def publish(self, topic, payload, retain=True):
        body = self._str(topic) + payload.encode("utf-8")
        head = 0x30 | (0x01 if retain else 0x00)
        with self.lock:
            if not self.sock:
                raise ConnectionError("not connected")
            self.sock.sendall(bytes([head]) + self._len(len(body)) + body)

    def keep_alive(self):
        """Send PINGREQ when due and drain whatever the broker sent back."""
        now = time.time()
        with self.lock:
            if not self.sock:
                return
            if now - self.last_ping >= self.keepalive / 2:
                self.sock.sendall(b"\xc0\x00")
                self.last_ping = now
            # Drain PINGRESP and anything else so the socket buffer stays clear.
            self.sock.settimeout(0.05)
            try:
                while True:
                    if not self.sock.recv(4096):
                        raise ConnectionError("broker closed the connection")
            except socket.timeout:
                pass
            finally:
                if self.sock:
                    self.sock.settimeout(20)

    def close(self):
        with self.lock:
            if self.sock:
                try:
                    self.sock.sendall(b"\xe0\x00")  # DISCONNECT
                except Exception:
                    pass
                try:
                    self.sock.close()
                except Exception:
                    pass
                self.sock = None


# ---------------------------------------------------------------------------
# Robot WebSocket reader
# ---------------------------------------------------------------------------
def ws_recv_exact(sock, count):
    buf = b""
    while len(buf) < count:
        chunk = sock.recv(count - len(buf))
        if not chunk:
            raise ConnectionError("websocket closed")
        buf += chunk
    return buf


def ws_read_frame(sock):
    b1, b2 = ws_recv_exact(sock, 2)
    opcode, masked, length = b1 & 0x0F, b2 & 0x80, b2 & 0x7F
    if length == 126:
        length = struct.unpack(">H", ws_recv_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", ws_recv_exact(sock, 8))[0]
    mask = ws_recv_exact(sock, 4) if masked else None
    data = ws_recv_exact(sock, length) if length else b""
    if mask:
        data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    return opcode, data


def ws_send_frame(sock, opcode, payload=b""):
    header = bytearray([0x80 | opcode])
    mask = bytes(random.getrandbits(8) for _ in range(4))
    length = len(payload)
    if length < 126:
        header.append(0x80 | length)
    elif length < 65536:
        header.append(0x80 | 126)
        header += struct.pack(">H", length)
    else:
        header.append(0x80 | 127)
        header += struct.pack(">Q", length)
    header += mask
    sock.sendall(bytes(header) + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))


def topic_worker(ros_topic, mqtt_suffix, cfg, state):
    """Follow one robot topic forever, handing each message to the publisher."""
    host, port = cfg["ROBOT_HOST"], int(cfg["ROBOT_PORT"])
    mqtt_topic = f"{cfg['TOPIC_PREFIX']}/{mqtt_suffix}"
    min_interval = float(cfg["MIN_PUBLISH_INTERVAL"])
    backoff = 1.0
    last_sent = 0.0

    while not state["stop"].is_set():
        sock = None
        try:
            sock = socket.create_connection((host, port), timeout=10)
            sock.settimeout(40)
            key = base64.b64encode(bytes(random.getrandbits(8) for _ in range(16))).decode()
            # No Origin header on purpose: the robot compares Origin against
            # Host and rejects browsers coming from another address. A plain
            # non-browser client is accepted.
            sock.sendall((
                f"GET /api/mowglinext/subscribe/{ros_topic} HTTP/1.1\r\n"
                f"Host: {host}:{port}\r\n"
                "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
            ).encode())

            response = b""
            while b"\r\n\r\n" not in response:
                chunk = sock.recv(4096)
                if not chunk:
                    raise ConnectionError("handshake closed")
                response += chunk
            if b"101" not in response.split(b"\r\n")[0]:
                raise ConnectionError(f"handshake refused: {response.splitlines()[0]!r}")

            log("INFO", f"subscribed to robot topic '{ros_topic}' -> {mqtt_topic}")
            backoff = 1.0

            while not state["stop"].is_set():
                opcode, data = ws_read_frame(sock)
                if opcode == 0x8:
                    raise ConnectionError("websocket close frame")
                if opcode == 0x9:
                    ws_send_frame(sock, 0xA, data)
                    continue
                if opcode not in (0x1, 0x2):
                    continue
                # The robot base64-wraps its JSON; tolerate both forms.
                try:
                    obj = json.loads(base64.b64decode(data).decode("utf-8", "replace"))
                except Exception:
                    try:
                        obj = json.loads(data.decode("utf-8", "replace"))
                    except Exception:
                        continue

                now = time.time()
                if now - last_sent < min_interval:
                    continue
                last_sent = now
                state["publish"](mqtt_topic, json.dumps(obj, separators=(",", ":")))

        except Exception as exc:
            if not state["stop"].is_set():
                log("WARN", f"topic '{ros_topic}': {exc} — retrying in {backoff:.0f}s")
                state["stop"].wait(backoff)
                backoff = min(backoff * 2, 30.0)
        finally:
            if sock:
                try:
                    sock.close()
                except Exception:
                    pass


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    config_path = sys.argv[1] if len(sys.argv) > 1 else "/etc/mowgli-ha-bridge.conf"
    cfg = load_config(config_path)
    availability = f"{cfg['TOPIC_PREFIX']}/available"

    state = {"stop": threading.Event(), "client": None, "publish": None}
    client_lock = threading.Lock()

    def publish(topic, payload):
        """Publish, reconnecting on failure. Called from every topic thread."""
        for attempt in (1, 2):
            with client_lock:
                client = state["client"]
                if client is None:
                    client = MqttClient(
                        cfg["MQTT_HOST"], cfg["MQTT_PORT"], cfg["MQTT_CLIENT_ID"],
                        cfg["MQTT_USERNAME"], cfg["MQTT_PASSWORD"], availability)
                    try:
                        client.connect()
                        client.publish(availability, "online")
                        state["client"] = client
                    except Exception as exc:
                        log("ERROR", f"MQTT connection failed: {exc}")
                        state["stop"].wait(5)
                        return
            try:
                client.publish(topic, payload)
                return
            except Exception as exc:
                log("WARN", f"publish to {topic} failed: {exc} — reconnecting")
                with client_lock:
                    if state["client"] is client:
                        client.close()
                        state["client"] = None
                if attempt == 2:
                    return

    state["publish"] = publish

    log("INFO", f"mowgli-ha-bridge starting — robot {cfg['ROBOT_HOST']}:{cfg['ROBOT_PORT']}, "
                f"broker {cfg['MQTT_HOST']}:{cfg['MQTT_PORT']}, prefix '{cfg['TOPIC_PREFIX']}'")

    threads = []
    for ros_topic, suffix in TOPIC_MAP.items():
        thread = threading.Thread(target=topic_worker,
                                  args=(ros_topic, suffix, cfg, state),
                                  name=f"ws-{ros_topic}", daemon=True)
        thread.start()
        threads.append(thread)

    try:
        while True:
            time.sleep(5)
            with client_lock:
                client = state["client"]
            if client:
                try:
                    client.keep_alive()
                except Exception as exc:
                    log("WARN", f"keepalive failed: {exc} — reconnecting")
                    with client_lock:
                        if state["client"] is client:
                            client.close()
                            state["client"] = None
    except KeyboardInterrupt:
        pass
    finally:
        log("INFO", "stopping")
        state["stop"].set()
        with client_lock:
            if state["client"]:
                try:
                    state["client"].publish(availability, "offline")
                except Exception:
                    pass
                state["client"].close()


if __name__ == "__main__":
    main()
