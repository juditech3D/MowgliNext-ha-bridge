#!/usr/bin/env python3
"""
mowglinext-ha-bridge — publish a MowgliNext robot's live state to an MQTT broker.

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
import urllib.error
import urllib.request

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
    "MQTT_CLIENT_ID": "mowglinext-ha-bridge",
    "TOPIC_PREFIX": "mowgli",
    # Seconds between two publishes of the same topic. The robot streams far
    # faster than Home Assistant needs; without this the recorder database
    # grows for nothing.
    "MIN_PUBLISH_INTERVAL": "2.0",
    # Accept start / pause / dock on <prefix>/command.
    "ALLOW_COMMANDS": "true",
    # Clearing a latched emergency remotely is deliberately separate and off by
    # default. The latch exists because something went wrong -- a lift, a tilt --
    # and the sane place to decide it is safe again is standing next to the
    # machine, not from a phone. Turn it on only if you know you want it.
    "ALLOW_EMERGENCY_RESET": "false",
}

# High-level commands, from mowgli_interfaces/srv/HighLevelControl.srv.
# COMMAND_STOP is a stop-in-place hold: motion halted, mower off, stays put --
# it does not drive home. That is COMMAND_HOME.
CMD_START = 1
CMD_HOME = 2
CMD_STOP = 8
CMD_RESET_EMERGENCY = 254  # documented, but the robot answers {} to it

# What a payload on <prefix>/command may say.
COMMANDS = {
    "start": ("high_level_control", {"command": CMD_START}, False),
    "resume": ("high_level_control", {"command": CMD_START}, False),
    "pause": ("high_level_control", {"command": CMD_STOP}, False),
    "stop": ("high_level_control", {"command": CMD_STOP}, False),
    "dock": ("high_level_control", {"command": CMD_HOME}, False),
    "home": ("high_level_control", {"command": CMD_HOME}, False),
    "return_to_base": ("high_level_control", {"command": CMD_HOME}, False),
    # Clearing a latched emergency goes through the dedicated EmergencyStop
    # service, not high_level_control. COMMAND_RESET_EMERGENCY=254 exists in
    # HighLevelControl.srv but the robot answers {} to it -- its own web UI
    # calls mowerAction("emergency", {Emergency: 0}) instead
    # (gui/web/src/components/MowerStatus.tsx:99), so this does the same.
    # The bool marks a command as gated behind ALLOW_EMERGENCY_RESET.
    "reset_emergency": ("emergency", {"emergency": 0}, True),
    "clear_emergency": ("emergency", {"emergency": 0}, True),
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
                 will_topic, keepalive=45, on_message=None, subscribe_topic=None):
        self.host, self.port = host, int(port)
        self.client_id = client_id
        self.username, self.password = username, password
        self.will_topic = will_topic
        self.keepalive = keepalive
        self.on_message = on_message
        self.subscribe_topic = subscribe_topic
        self.sock = None
        self.lock = threading.Lock()
        self.last_ping = 0.0
        self.alive = True

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

        if self.subscribe_topic:
            payload = struct.pack(">H", 1) + self._str(self.subscribe_topic) + b"\x00"
            sock.sendall(b"\x82" + self._len(len(payload)) + payload)
            log("INFO", f"listening for commands on {self.subscribe_topic}")

        # Blocking from here on. The handshake above needed a timeout so a dead
        # broker could not hang startup, but the reader must not mistake a quiet
        # broker for a broken one -- and a timeout firing mid-packet would lose
        # framing. Death is detected by the keepalive and by TCP itself.
        sock.settimeout(None)

        # One thread owns recv() for the lifetime of this socket. Sends stay on
        # the caller's thread, serialised by self.lock -- concurrent send and
        # recv on one socket is fine, two concurrent recv() are not.
        threading.Thread(target=self._reader, args=(sock,),
                         name="mqtt-reader", daemon=True).start()

    def _reader(self, sock):
        try:
            while self.alive and self.sock is sock:
                kind = sock.recv(1)
                if not kind:
                    raise ConnectionError("broker closed the connection")
                length = self._read_len()
                body = b""
                while len(body) < length:
                    chunk = sock.recv(length - len(body))
                    if not chunk:
                        raise ConnectionError("broker closed the connection")
                    body += chunk
                if kind[0] >> 4 != 3:      # only PUBLISH carries anything for us
                    continue
                tlen = struct.unpack(">H", body[:2])[0]
                topic = body[2:2 + tlen].decode("utf-8", "replace")
                offset = 2 + tlen
                if (kind[0] >> 1) & 0x03:  # QoS > 0 carries a packet id
                    offset += 2
                message = body[offset:].decode("utf-8", "replace")
                if self.on_message:
                    try:
                        self.on_message(topic, message)
                    except Exception as exc:
                        log("ERROR", f"command handler failed: {exc}")
        except Exception as exc:
            if self.alive and self.sock is sock:
                log("WARN", f"MQTT reader stopped: {exc}")
        finally:
            self.alive = False

    def publish(self, topic, payload, retain=True):
        body = self._str(topic) + payload.encode("utf-8")
        head = 0x30 | (0x01 if retain else 0x00)
        with self.lock:
            if not self.sock:
                raise ConnectionError("not connected")
            self.sock.sendall(bytes([head]) + self._len(len(body)) + body)

    def keep_alive(self):
        """Send PINGREQ when due. The reader thread consumes the reply."""
        if not self.alive:
            raise ConnectionError("reader thread has stopped")
        now = time.time()
        with self.lock:
            if not self.sock:
                return
            if now - self.last_ping >= self.keepalive / 2:
                self.sock.sendall(b"\xc0\x00")
                self.last_ping = now

    def close(self):
        self.alive = False
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
def call_robot(cfg, endpoint, body, timeout=12):
    """POST to the robot's service bridge, the same one its web UI uses.

    No Origin header: the robot compares Origin against Host and rejects
    browsers coming from elsewhere, but accepts a plain non-browser client.
    """
    url = f"http://{cfg['ROBOT_HOST']}:{cfg['ROBOT_PORT']}/api/mowglinext/call/{endpoint}"
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST",
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            raw = response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        # The robot reports refusals as 4xx with {"error": "..."} -- that body
        # is the whole reason the call failed, so it must not be swallowed.
        raw = exc.read().decode("utf-8", "replace")
        try:
            parsed = json.loads(raw)
        except Exception:
            parsed = {"error": raw.strip() or f"HTTP {exc.code}"}
        if "error" not in parsed:
            parsed["error"] = f"HTTP {exc.code}"
        return parsed
    try:
        return json.loads(raw)
    except Exception:
        return {"raw": raw}


def handle_command(cfg, topic, message, publish):
    """Act on one message from <prefix>/command.

    Accepts a bare word ("dock") or JSON ({"command": "dock"}). Anything else
    is reported and ignored -- this topic drives a machine with a blade, so an
    unrecognised payload must never be guessed at.
    """
    text = (message or "").strip()
    if text.startswith("{"):
        try:
            text = str(json.loads(text).get("command", "")).strip()
        except Exception:
            text = ""
    name = text.lower().replace("-", "_").replace(" ", "_")

    result_topic = f"{cfg['TOPIC_PREFIX']}/command/result"

    def reply(ok, detail):
        level = "INFO" if ok else "WARN"
        log(level, f"command '{name or message!r}': {detail}")
        publish(result_topic, json.dumps(
            {"command": name, "ok": ok, "detail": detail, "ts": int(time.time())},
            separators=(",", ":")), retain=False)

    entry = COMMANDS.get(name)
    if entry is None:
        reply(False, f"unknown command; known: {', '.join(sorted(COMMANDS))}")
        return

    endpoint, body, needs_emergency_opt_in = entry
    if needs_emergency_opt_in and cfg["ALLOW_EMERGENCY_RESET"].strip().lower() not in ("1", "true", "yes", "on"):
        reply(False, "refused: clearing an emergency is disabled "
                     "(set ALLOW_EMERGENCY_RESET=true to allow it)")
        return

    try:
        response = call_robot(cfg, endpoint, body)
    except Exception as exc:
        reply(False, f"call to {endpoint} failed: {exc}")
        return

    # An accepted call is HTTP 2xx with an empty body. OkResponse.Ok is a
    # string tagged json:"ok,omitempty" (gui/pkg/api/types.go:3), so success
    # serialises to {}. Refusals come back as 4xx with {"error": ...}, and a
    # few routes forward the ROS service response, which does carry "success".
    # Treating a missing "success" as failure made working commands look dead.
    if "error" in response:
        ok = False
    elif "success" in response:
        ok = bool(response["success"])
    else:
        ok = True
    reply(ok, "accepted by the robot" if ok
              else f"{endpoint} {body} -> {response}")


def clear_retained(cfg):
    """Wipe our retained topics, so nothing of ours outlives an uninstall.

    A retained message survives the client that published it: without this,
    Home Assistant would keep showing the last known battery level forever,
    with no way to tell it is stale. Publishing an empty payload with the
    retain flag is how MQTT deletes one.
    """
    prefix = cfg["TOPIC_PREFIX"]
    client = MqttClient(cfg["MQTT_HOST"], cfg["MQTT_PORT"], cfg["MQTT_CLIENT_ID"] + "-clear",
                        cfg["MQTT_USERNAME"], cfg["MQTT_PASSWORD"], f"{prefix}/available")
    client.connect()
    topics = [f"{prefix}/{suffix}" for suffix in TOPIC_MAP.values()]
    topics.append(f"{prefix}/available")
    for topic in topics:
        client.publish(topic, "", retain=True)
        log("INFO", f"cleared retained {topic}")
    time.sleep(1)  # let the broker apply them before we drop the socket
    client.close()  # clean DISCONNECT, so the last will is not fired
    log("INFO", f"{len(topics)} retained topics cleared")


def main():
    args = sys.argv[1:]
    do_clear = "--clear-retained" in args
    positional = [a for a in args if not a.startswith("-")]
    config_path = positional[0] if positional else "/etc/mowglinext-ha-bridge.conf"
    cfg = load_config(config_path)

    if do_clear:
        try:
            clear_retained(cfg)
        except Exception as exc:
            log("ERROR", f"could not clear retained topics: {exc}")
            return 1
        return 0

    availability = f"{cfg['TOPIC_PREFIX']}/available"

    state = {"stop": threading.Event(), "client": None, "publish": None}
    client_lock = threading.Lock()

    commands_on = cfg["ALLOW_COMMANDS"].strip().lower() in ("1", "true", "yes", "on")
    command_topic = f"{cfg['TOPIC_PREFIX']}/command" if commands_on else None

    def on_command(topic, message):
        handle_command(cfg, topic, message, state["publish"])

    def publish(topic, payload, retain=True):
        """Publish, reconnecting on failure. Called from every topic thread."""
        for attempt in (1, 2):
            with client_lock:
                client = state["client"]
                if client is None:
                    client = MqttClient(
                        cfg["MQTT_HOST"], cfg["MQTT_PORT"], cfg["MQTT_CLIENT_ID"],
                        cfg["MQTT_USERNAME"], cfg["MQTT_PASSWORD"], availability,
                        on_message=on_command, subscribe_topic=command_topic)
                    try:
                        client.connect()
                        client.publish(availability, "online")
                        state["client"] = client
                    except Exception as exc:
                        log("ERROR", f"MQTT connection failed: {exc}")
                        state["stop"].wait(5)
                        return
            try:
                client.publish(topic, payload, retain=retain)
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

    if commands_on:
        emergency_on = cfg["ALLOW_EMERGENCY_RESET"].strip().lower() in ("1", "true", "yes", "on")
        log("INFO", f"commands enabled on {command_topic} "
                    f"(emergency reset: {'ALLOWED' if emergency_on else 'refused'})")
    else:
        log("INFO", "commands disabled -- this bridge is read-only")

    log("INFO", f"mowglinext-ha-bridge starting — robot {cfg['ROBOT_HOST']}:{cfg['ROBOT_PORT']}, "
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
    sys.exit(main() or 0)
