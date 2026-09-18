#!/usr/bin/env bash
#
# mowglinext-ha-bridge installer
#
# Installs a small systemd service that mirrors a MowgliNext robot's live state
# onto an MQTT broker, so Home Assistant can read it. Nothing on the robot is
# modified: the bridge only reads the same WebSocket API the robot's own web UI
# uses.
#
# Usage (on the robot's Raspberry Pi, or any always-on machine that can reach
# both the robot and the broker):
#
#     sudo ./install.sh
#     sudo ./install.sh --uninstall
#
set -euo pipefail

SERVICE_NAME="mowglinext-ha-bridge"
BIN_PATH="/usr/local/bin/${SERVICE_NAME}"
CONF_PATH="/etc/${SERVICE_NAME}.conf"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
SRC_NAME="mowglinext_ha_bridge.py"
RAW_URL="https://raw.githubusercontent.com/__OWNER__/__REPO__/main/${SRC_NAME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

c_bold=$'\033[1m'; c_green=$'\033[32m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$c_green" "$c_off" "$*"; }
err()  { printf '%s✗%s %s\n' "$c_red" "$c_off" "$*" >&2; }
head_() { printf '\n%s%s%s\n' "$c_bold" "$*" "$c_off"; }

# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  err "Run me with sudo: sudo $0"
  exit 1
fi

if [[ "${1:-}" == "--uninstall" ]]; then
  head_ "Removing ${SERVICE_NAME}"
  systemctl disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
  rm -f "$UNIT_PATH" "$BIN_PATH"
  systemctl daemon-reload
  ok "Service and binary removed."
  say "${c_dim}${CONF_PATH} was left in place (it holds your broker password).${c_off}"
  say "Delete it with: sudo rm ${CONF_PATH}"
  exit 0
fi

command -v python3 >/dev/null || { err "python3 is required but not installed."; exit 1; }

head_ "mowglinext-ha-bridge — installation"
say "This publishes your robot's state to MQTT so Home Assistant can read it."
say "${c_dim}It does not change anything on the robot itself.${c_off}"

# ---------------------------------------------------------------------------
# Questions
# ---------------------------------------------------------------------------
ask() {  # ask <variable> <prompt> <default>
  local __var="$1" __prompt="$2" __default="${3:-}" __reply
  if [[ -n "$__default" ]]; then
    read -r -p "$__prompt [$__default]: " __reply || true
    __reply="${__reply:-$__default}"
  else
    while [[ -z "${__reply:-}" ]]; do
      read -r -p "$__prompt: " __reply || true
    done
  fi
  printf -v "$__var" '%s' "$__reply"
}

head_ "1. The robot"
say "${c_dim}If you are installing on the robot's own Pi, keep 127.0.0.1.${c_off}"
ask ROBOT_HOST "  Robot address" "127.0.0.1"
ask ROBOT_PORT "  Robot web UI port" "4006"

head_ "2. The MQTT broker"
say "${c_dim}For Home Assistant this is the machine running the Mosquitto add-on,${c_off}"
say "${c_dim}and the account is a normal Home Assistant user you created for it.${c_off}"
ask MQTT_HOST "  Broker address" ""
ask MQTT_PORT "  Broker port" "1883"
ask MQTT_USERNAME "  MQTT username" ""

MQTT_PASSWORD=""
while [[ -z "$MQTT_PASSWORD" ]]; do
  read -r -s -p "  MQTT password (hidden): " MQTT_PASSWORD || true
  echo
done

head_ "3. Topics"
ask TOPIC_PREFIX "  Topic prefix" "mowgli"
ask MIN_PUBLISH_INTERVAL "  Minimum seconds between updates" "2.0"

# ---------------------------------------------------------------------------
# Fetch the bridge if it is not sitting next to this script
# ---------------------------------------------------------------------------
head_ "Installing"
if [[ -f "${SCRIPT_DIR}/${SRC_NAME}" ]]; then
  install -m 0755 "${SCRIPT_DIR}/${SRC_NAME}" "$BIN_PATH"
  ok "Installed ${BIN_PATH} (from this directory)"
elif command -v curl >/dev/null; then
  curl -fsSL "$RAW_URL" -o "$BIN_PATH"
  chmod 0755 "$BIN_PATH"
  ok "Installed ${BIN_PATH} (downloaded)"
else
  err "${SRC_NAME} not found next to this script, and curl is unavailable."
  exit 1
fi

umask 077
cat > "$CONF_PATH" <<EOF
# mowglinext-ha-bridge configuration — written by install.sh
# This file contains a password: keep it readable by root only.

ROBOT_HOST=${ROBOT_HOST}
ROBOT_PORT=${ROBOT_PORT}

MQTT_HOST=${MQTT_HOST}
MQTT_PORT=${MQTT_PORT}
MQTT_USERNAME=${MQTT_USERNAME}
MQTT_PASSWORD=${MQTT_PASSWORD}
MQTT_CLIENT_ID=mowglinext-ha-bridge

TOPIC_PREFIX=${TOPIC_PREFIX}
MIN_PUBLISH_INTERVAL=${MIN_PUBLISH_INTERVAL}
EOF
chown root:root "$CONF_PATH"
chmod 0600 "$CONF_PATH"
ok "Wrote ${CONF_PATH} (mode 0600, root only)"

cat > "$UNIT_PATH" <<EOF
[Unit]
Description=MowgliNext to MQTT bridge for Home Assistant
Documentation=https://github.com/__OWNER__/__REPO__
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} ${CONF_PATH}
Restart=always
RestartSec=10
User=root

# The bridge only needs the network and its own config file.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=${CONF_PATH}

[Install]
WantedBy=multi-user.target
EOF
ok "Wrote ${UNIT_PATH}"

# ---------------------------------------------------------------------------
# Start and verify
# ---------------------------------------------------------------------------
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service" >/dev/null 2>&1
systemctl restart "${SERVICE_NAME}.service"

say ""
say "Waiting for the first connection..."
sleep 6

if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
  ok "Service is running."
else
  err "Service failed to start."
fi

head_ "Recent log"
journalctl -u "${SERVICE_NAME}.service" -n 20 --no-pager || true

head_ "Next steps"
say "  Follow the log :  sudo journalctl -u ${SERVICE_NAME} -f"
say "  Restart        :  sudo systemctl restart ${SERVICE_NAME}"
say "  Reconfigure    :  sudo nano ${CONF_PATH} && sudo systemctl restart ${SERVICE_NAME}"
say "  Uninstall      :  sudo $0 --uninstall"
say ""
say "In Home Assistant, add the entities from homeassistant/mowgli_mqtt.yaml"
say "and the dashboard card from homeassistant/mowgli_card.yaml."
say ""
say "${c_dim}If the log shows 'not authorised', the MQTT account is wrong: create a${c_off}"
say "${c_dim}normal Home Assistant user and use those exact credentials.${c_off}"
