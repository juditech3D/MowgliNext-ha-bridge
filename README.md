# mowglinext-ha-bridge

Publish a **MowgliNext** robot mower's live state to MQTT, so **Home Assistant**
can read it — without modifying the robot.

Install it, answer five questions, and a `Mowgli` device shows up in Home
Assistant with battery, blade, GPS, charger and emergency-stop entities.

---

## Why this exists

MowgliNext has an *MQTT / Home Assistant* page in its web UI, with fields for a
broker host, port and credentials. On released images that page cannot work,
for two independent reasons.

**1. The ROS2 bridge node is a stub in every shipped image.**
`mqtt_bridge_node.cpp` picks its MQTT client at compile time:

```cpp
  mqtt_client_ = std::make_unique<MosquittoMqttClient>(std::move(cfg), get_logger());
#else
  mqtt_client_ = std::make_unique<StubMqttClient>(get_logger());
  RCLCPP_WARN(get_logger(),
              "libmosquitto not available — using StubMqttClient. "
              "MQTT messages will be logged at DEBUG level only.");
#endif
```

The `ros2` image does not contain libmosquitto:

```console
$ docker exec mowgli-ros2 ldconfig -p | grep -ci mosquitto
0
```

So the `#else` branch is what ships. The node exists, starts, and publishes
nothing.

**2. The node is never launched anyway.**
In `full_system.launch.py` it sits behind `condition=IfCondition(enable_mqtt)`,
and `enable_mqtt` defaults to `"false"`. The compose command passes
`enable_foxglove:=…` but no `enable_mqtt:=…`, and `ENABLE_MQTT` in `docker/.env`
only starts the eclipse-mosquitto **broker** container — not the bridge.

Turning the web UI switch on writes `mqtt_enabled: true` into
`mowgli_robot.yaml`, which nothing reads. Verified on MowgliNext v1.3.0.

This bridge takes a different route: it connects to the robot's WebSocket API —
the very same one the robot's own web UI uses — and republishes each message as
retained JSON on your broker. The robot is only ever read from.

---

## What you get

| MQTT topic | Source | Contents |
|---|---|---|
| `mowgli/status` | ROS `status` | blade RPM, ESC current/status, motor temperature, firmware, rain |
| `mowgli/power` | ROS `power` | battery voltage, charge current, charger state |
| `mowgli/emergency` | ROS `emergency` | active/latched e-stop, reason, lift warning |
| `mowgli/high_level_status` | ROS `highLevelStatus` | state name, battery %, coverage, GPS quality |
| `mowgli/gps` | ROS `gnssStatus` | fix type, RTK corrections, accuracy |
| `mowgli/available` | the bridge | `online` / `offline` (MQTT last will) |

All state topics are published **retained**, so Home Assistant has values
immediately after a restart instead of waiting for the next robot message.

---

## Requirements

- Python 3.9+ — **standard library only**, nothing to `pip install`
- An MQTT broker. For Home Assistant that is the Mosquitto add-on, and the
  account is an ordinary Home Assistant user.
- A machine that can reach both the robot and the broker. The robot's own
  Raspberry Pi is the natural place: always on, and the robot is at
  `127.0.0.1`.

## Install

One line, on the robot's Pi:

```bash
curl -fsSL https://raw.githubusercontent.com/juditech3D/MowgliNext-ha-bridge/main/install.sh | sudo bash
```

Or clone it first, if you would rather read the script before running it as
root — which is the sensible habit:

```bash
git clone https://github.com/juditech3D/MowgliNext-ha-bridge.git
cd MowgliNext-ha-bridge
sudo ./install.sh
```

The installer asks for your language first, English or French. `--lang en` or
`--lang fr` skips the question.

<details>
<summary>Why the one-liner needs a trick — two of them, in fact</summary>

Piping a script into bash breaks interactive prompts twice over, and fixing
only the first half produces a subtly broken install rather than an obvious
failure.

**First**, bash reads the script from stdin, so a `read` would consume the
script itself. The installer notices it has no file of its own, downloads
itself to a temporary file and re-executes from there.

**Second — and this is the one that bites** — after re-executing, stdin is
*still the pipe*, and the pipe still holds the rest of the downloaded script
that bash had not yet consumed. `read` hands those leftover bytes back as if
you had typed them. The result is an installer that asks nothing and writes a
configuration full of its own source code:

```
ROBOT_PORT=# Second pass of a one-line install: tidy the copy we downloaded…
MQTT_HOST=# Written as an `if` on purpose: under `set -e`, a bare `[[ … ]]`…
TOPIC_PREFIX=fi
```

So the re-exec also points stdin at `/dev/tty`. With no terminal available it
falls back to `/dev/null`, and answers must come from the environment.

Belt and braces: every answer is now validated before anything is written.
A port that is not a number, or an address that is not an address, stops the
installer with a clear message instead of surfacing as a stack trace in the
service log an hour later.

</details>

### Unattended install

Any answer already present in the environment is used as-is, so nothing is
asked:

```bash
sudo MQTT_HOST=192.168.1.10 MQTT_USERNAME=mowgli MQTT_PASSWORD='…' ./install.sh
```

Handy for provisioning several robots. Note that a password written on a
command line lands in your shell history — for a one-off install, let the
script ask for it instead.

The installer asks for the robot address, the broker address and port, and the
**MQTT username and password**. The password is typed hidden and written only
to `/etc/mowglinext-ha-bridge.conf`, `chmod 0600`, root-owned. It is never echoed
and never leaves the machine.

It looks for your broker rather than expecting you to recite an IP address: it
resolves the name Home Assistant advertises over mDNS, and failing that sweeps
the local `/24` for a host answering on both 8123 and 1883. Whatever it finds
is offered as the default — press Enter to accept, or type your own.

```
Looking for a Home Assistant MQTT broker...
✓ Found Home Assistant with MQTT at 192.168.1.239
  Broker address [192.168.1.239]:
```

Then it installs a systemd service, starts it and shows the first log lines.
The service runs unprivileged — see [Security](#security).

### Creating the MQTT account in Home Assistant

The Mosquitto add-on authenticates against Home Assistant users. **Settings →
People → Users → Add**, create a user (for example `mowgli`), and give those
credentials to the installer. A `not authorised` line in the log almost always
means this step was skipped.

## Security

### What `curl … | sudo bash` really means

It means running, as root, whatever that URL returns *at that moment*, without
seeing it first. That is a real risk and it is worth stating plainly rather
than hiding behind a convenient one-liner.

Concretely, for this project:

- **Everything rests on the GitHub repository.** Whoever controls it controls
  what runs as root on your Pi. Today that is its owner — and anyone who
  compromises that account.
- **There is no signature or checksum.** A checksum published in the same
  repository would only catch a truncated download, not a repository that has
  been tampered with, so it would buy you little and might suggest a guarantee
  that is not there.
- **The installer fetches twice** — itself, then the bridge — leaving a
  theoretical window in which the two could differ.

Two ways to remove the doubt entirely:

```bash
# Read it before running it as root
curl -fsSL https://raw.githubusercontent.com/juditech3D/MowgliNext-ha-bridge/main/install.sh -o install.sh
less install.sh && sudo bash install.sh
```

```bash
# Or pin to a specific commit: immutable, reviewable, reproducible
curl -fsSL https://raw.githubusercontent.com/juditech3D/MowgliNext-ha-bridge/<commit-sha>/install.sh | sudo bash
```

The whole thing is about 400 lines of Python and shell, deliberately kept
readable so that reviewing it is realistic rather than notional.

### What the code actually does

- **No dynamic execution.** No `eval`, no `exec`, no `subprocess`, no
  `pickle`, no shelling out. Incoming MQTT and WebSocket data is parsed with
  `json.loads` and never interpreted.
- **Two outbound connections**, both from `socket.create_connection`: your
  robot, and your broker. Nothing else. No telemetry, no phoning home.
- **Three files written**, all named in the source: the program, the config,
  the systemd unit. Uninstalling removes exactly those.
- **Read-only towards the robot.** It subscribes to the WebSocket API; there
  is no code path that sends the robot a command.

### The service does not run as root

The installer needs root — it writes to `/usr/local/bin` and
`/etc/systemd/system`. The **service** does not, and therefore does not get it:

```ini
DynamicUser=yes
LoadCredential=conf:/etc/mowglinext-ha-bridge.conf
ExecStart=/usr/local/bin/mowglinext-ha-bridge %d/conf
```

`DynamicUser` gives it a throwaway unprivileged account for the lifetime of the
service — nothing to create, nothing left behind. The config file stays
root-owned `0600`; systemd reads it while still privileged and passes it as a
credential the service user can read. So the broker password is never in a file
the service account could open on its own.

On top of that the unit drops all capabilities and denies everything it does
not need: `ProtectSystem=strict`, `PrivateDevices`, `ProtectKernelTunables`,
`RestrictAddressFamilies=AF_INET AF_INET6`,
`SystemCallFilter=@system-service`, and the rest. A compromised bridge would
be an unprivileged process that can open TCP sockets and little else.

`LoadCredential` needs systemd 247+. On older systems the installer says so and
falls back to running as root, rather than shipping a unit that will not start.

## Home Assistant entities

`homeassistant/mowgli_mqtt.yaml` defines 20 entities grouped under one `Mowgli`
device. Paste it into `configuration.yaml`, or drop it in
`config/packages/`. Restart Home Assistant.

`homeassistant/mowgli_card.yaml` is a dashboard card built from native cards
only — no HACS. Paste it into your dashboard's raw YAML editor.

> **Entity IDs.** Home Assistant builds `entity_id` from the device name plus
> the entity name, and freezes it on first creation. The card uses the IDs the
> supplied YAML produces. If you rename anything, update the card to match.

Two of the entities are worth knowing about:

- **Blade spinning** cross-checks `mow_enabled` against the real motor RPM.
  A mower that thinks it is cutting while the blade is stopped shows up here
  and nowhere else.
- **Blade ESC code** surfaces `mower_status`. `255` means the ESC is not
  answering at all.

## Update, reconfigure, uninstall

There is only one script. Run it again on a machine that already has the bridge
and it tells you what it found, then asks:

```
mowglinext-ha-bridge is already installed
  program  /usr/local/bin/mowglinext-ha-bridge
  config   /etc/mowglinext-ha-bridge.conf
  service  active

  1) Update      — new program, keep the current settings
  2) Reconfigure — ask every question again
  3) Uninstall   — remove it
  4) Cancel
```

The same choices are available as flags, for scripts and for the one-liner:

```bash
sudo ./install.sh --update       # new program, settings untouched
sudo ./install.sh --reinstall    # ask every question again
sudo ./install.sh --uninstall    # remove, ask about the config file
sudo ./install.sh --purge        # remove, config file included
sudo ./install.sh --help
```

### Removing everything in one line

```bash
curl -fsSL https://raw.githubusercontent.com/juditech3D/MowgliNext-ha-bridge/main/install.sh | sudo bash -s -- --purge
```

Uninstalling does three things, in this order:

1. **stops and disables the service** — it has to go first, or the next step
   would be undone within the second;
2. **clears the retained MQTT topics.** A retained message outlives the client
   that published it: without this, Home Assistant would keep showing your last
   known battery level for ever, with nothing to indicate it is frozen;
3. **removes the unit and the program**, then asks before deleting the config
   file, since that is where your broker password lives.

The robot is never touched, so nothing has to be undone there. On the Home
Assistant side, remove the `mqtt:` block from `configuration.yaml` and the
dashboard card, then restart.

## Day to day

```bash
sudo journalctl -u mowglinext-ha-bridge -f        # follow the log
sudo systemctl restart mowglinext-ha-bridge       # restart
sudo nano /etc/mowglinext-ha-bridge.conf          # edit settings by hand
```

## Configuration reference

| Key | Default | Meaning |
|---|---|---|
| `ROBOT_HOST` | `127.0.0.1` | Robot address |
| `ROBOT_PORT` | `4006` | Robot web UI port |
| `MQTT_HOST` | — | Broker address (required) |
| `MQTT_PORT` | `1883` | Broker port |
| `MQTT_USERNAME` / `MQTT_PASSWORD` | — | Broker credentials, empty for anonymous |
| `MQTT_CLIENT_ID` | `mowglinext-ha-bridge` | Client id seen by the broker |
| `TOPIC_PREFIX` | `mowgli` | Prefix for every topic |
| `MIN_PUBLISH_INTERVAL` | `2.0` | Minimum seconds between two publishes of the same topic |

Environment variables override the file, so systemd drop-ins work.

`MIN_PUBLISH_INTERVAL` matters more than it looks: the robot streams several
messages per second per topic, and every one of them would otherwise become a
row in Home Assistant's recorder database.

## Limitations

- **Read-only.** No `mowgli/command` topic: the command codes are documented in
  a `docs/MQTT_CONTROL.md` that the robot's web UI links to but does not ship.
  Start, pause and dock still go through the robot's own UI.
- TLS to the broker is not implemented. On a home LAN, plain 1883 to Mosquitto
  is the normal setup.
- Tested against MowgliNext v1.3.0. The WebSocket API is what the robot's own
  UI consumes, so it is unlikely to move, but it is not a stability contract.

If a future MowgliNext release ships a working bridge, stop this service — the
topic names are deliberately the same.

## License

MIT. See [LICENSE](LICENSE).
