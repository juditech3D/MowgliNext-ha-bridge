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

```bash
git clone https://github.com/__OWNER__/__REPO__.git
cd __REPO__
sudo ./install.sh
```

The installer asks for the robot address, the broker address and port, and the
**MQTT username and password**. The password is typed hidden and written only
to `/etc/mowglinext-ha-bridge.conf`, `chmod 0600`, root-owned. It is never echoed
and never leaves the machine.

Then it installs a systemd service, starts it and shows the first log lines.

### Creating the MQTT account in Home Assistant

The Mosquitto add-on authenticates against Home Assistant users. **Settings →
People → Users → Add**, create a user (for example `mowgli`), and give those
credentials to the installer. A `not authorised` line in the log almost always
means this step was skipped.

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

## Managing the service

```bash
sudo journalctl -u mowglinext-ha-bridge -f        # follow the log
sudo systemctl restart mowglinext-ha-bridge       # restart
sudo nano /etc/mowglinext-ha-bridge.conf          # reconfigure, then restart
sudo ./install.sh --uninstall                     # remove (keeps the config file)
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
