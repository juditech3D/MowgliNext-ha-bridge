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
#     sudo ./install.sh --update | --reinstall | --uninstall | --purge
#
set -euo pipefail

SERVICE_NAME="mowglinext-ha-bridge"
BIN_PATH="/usr/local/bin/${SERVICE_NAME}"
CONF_PATH="/etc/${SERVICE_NAME}.conf"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
SRC_NAME="mowglinext_ha_bridge.py"
REPO_RAW="https://raw.githubusercontent.com/juditech3D/MowgliNext-ha-bridge/main"
RAW_URL="${REPO_RAW}/${SRC_NAME}"
SELF_URL="${REPO_RAW}/install.sh"

# ---------------------------------------------------------------------------
# One-line install support
#
#   curl -fsSL .../install.sh | sudo bash
#
# When bash reads a script from a pipe, stdin *is* the script — so `read` would
# swallow the rest of the installer instead of waiting for an answer, and the
# prompts below would never work. Re-run ourselves from a real file: bash then
# reads the script from that file and leaves stdin pointing at the terminal.
# ---------------------------------------------------------------------------
if [[ ! -f "${BASH_SOURCE[0]:-}" ]]; then
  if ! command -v curl >/dev/null; then
    echo "curl is required for the one-line install." >&2
    exit 1
  fi
  _self="$(mktemp)"
  curl -fsSL "$SELF_URL" -o "$_self" || { echo "Could not download the installer." >&2; exit 1; }
  chmod +x "$_self"
  exec env _MHB_SELF_TMP="$_self" bash "$_self" "$@"
fi

# Second pass of a one-line install: tidy the copy we downloaded of ourselves.
# Written as an `if` on purpose: under `set -e`, a bare `[[ … ]] && …` whose
# test fails returns non-zero and would abort the installer.
if [[ -n "${_MHB_SELF_TMP:-}" ]]; then
  trap 'rm -f "$_MHB_SELF_TMP"' EXIT
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

c_bold=$'\033[1m'; c_green=$'\033[32m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$c_green" "$c_off" "$*"; }
err()  { printf '%s✗%s %s\n' "$c_red" "$c_off" "$*" >&2; }
head_() { printf '\n%s%s%s\n' "$c_bold" "$*" "$c_off"; }

usage() {
  say "Usage: $0 [--update | --reinstall | --uninstall | --purge]"
  say ""
  say "  (no option)   install, or ask what to do if already installed"
  say "  --update      replace the program, keep the configuration"
  say "  --reinstall   ask every question again"
  say "  --uninstall   remove the service, ask about the configuration"
  say "  --purge       remove the service and the configuration"
  say ""
  say "Any answer already set in the environment is used without asking:"
  say "  sudo MQTT_HOST=… MQTT_USERNAME=… MQTT_PASSWORD=… $0"
}

# Help before the root check — asking what a script does should not need sudo.
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
  esac
done

# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  err "Run me with sudo: sudo $0"
  exit 1
fi

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
do_uninstall() {  # do_uninstall <purge: yes|no|ask>
  local purge="${1:-ask}"
  head_ "Removing ${SERVICE_NAME}"

  # Stop first. Clearing the retained topics while the bridge is still running
  # would achieve nothing: it republishes them within the second.
  systemctl disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
  ok "Service stopped and disabled."

  # Retained MQTT messages outlive the client that sent them. Left alone, Home
  # Assistant would keep displaying the last battery level for ever, with no
  # hint that it is frozen. Clear them while the program and the credentials
  # are both still here.
  if [[ -f "$CONF_PATH" && -x "$BIN_PATH" ]]; then
    say "Clearing retained MQTT topics..."
    if "$BIN_PATH" "$CONF_PATH" --clear-retained 2>&1 | sed 's/^/  /'; then
      ok "Broker cleaned."
    else
      say "${c_dim}Could not reach the broker — retained topics may remain.${c_off}"
      say "${c_dim}Harmless, but Home Assistant will show stale values until cleared.${c_off}"
    fi
  fi

  rm -f "$UNIT_PATH" "$BIN_PATH"
  systemctl daemon-reload
  ok "Service unit and program removed."

  if [[ "$purge" == "ask" ]]; then
    local reply=""
    read -r -p "Also delete ${CONF_PATH} (it holds your broker password)? [y/N]: " reply || true
    [[ "$reply" =~ ^[YyOo] ]] && purge="yes" || purge="no"
  fi

  if [[ "$purge" == "yes" ]]; then
    rm -f "$CONF_PATH"
    ok "Configuration deleted."
  else
    say "${c_dim}${CONF_PATH} kept — delete it with: sudo rm ${CONF_PATH}${c_off}"
  fi

  head_ "Done"
  say "Nothing of this tool is left running. The robot was never modified,"
  say "so it is unaffected."
  say ""
  say "${c_dim}In Home Assistant, remove the mqtt: block you added to${c_off}"
  say "${c_dim}configuration.yaml and the dashboard card, then restart.${c_off}"
  exit 0
}

# ---------------------------------------------------------------------------
# What are we being asked to do?
# ---------------------------------------------------------------------------
ACTION=""
PURGE="ask"
for arg in "$@"; do
  case "$arg" in
    --uninstall|--remove) ACTION="uninstall" ;;
    --purge)              ACTION="uninstall"; PURGE="yes" ;;
    --update|--upgrade)   ACTION="update" ;;
    --reinstall)          ACTION="reinstall" ;;
    -h|--help)            ;;  # already handled above, before the root check
    *) err "Unknown option: $arg  (try --help)"; exit 1 ;;
  esac
done

if [[ "$ACTION" == "uninstall" ]]; then
  do_uninstall "$PURGE"
fi

command -v python3 >/dev/null || { err "python3 is required but not installed."; exit 1; }

# ---------------------------------------------------------------------------
# Already installed? Offer the sensible choices rather than silently redoing it.
# ---------------------------------------------------------------------------
INSTALLED="no"
if [[ -f "$UNIT_PATH" || -x "$BIN_PATH" || -f "$CONF_PATH" ]]; then
  INSTALLED="yes"
fi

if [[ "$INSTALLED" == "yes" && -z "$ACTION" ]]; then
  head_ "${SERVICE_NAME} is already installed"
  if [[ -x "$BIN_PATH"  ]]; then say "  program  ${BIN_PATH}"; fi
  if [[ -f "$CONF_PATH" ]]; then say "  config   ${CONF_PATH}"; fi
  if [[ -f "$UNIT_PATH" ]]; then
    say "  service  $(systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || echo inactive)"
  fi
  say ""
  say "  ${c_bold}1${c_off}) Update      — new program, keep the current settings"
  say "  ${c_bold}2${c_off}) Reconfigure — ask every question again"
  say "  ${c_bold}3${c_off}) Uninstall   — remove it"
  say "  ${c_bold}4${c_off}) Cancel"
  say ""
  choice=""
  while [[ ! "$choice" =~ ^[1-4]$ ]]; do
    read -r -p "Your choice [1]: " choice || true
    choice="${choice:-1}"
  done
  case "$choice" in
    1) ACTION="update" ;;
    2) ACTION="reinstall" ;;
    3) do_uninstall "ask" ;;
    4) say "Nothing done."; exit 0 ;;
  esac
fi

if [[ "$ACTION" == "update" && ! -f "$CONF_PATH" ]]; then
  err "Nothing to update: ${CONF_PATH} does not exist. Run without --update."
  exit 1
fi

head_ "mowglinext-ha-bridge — $( [[ "$ACTION" == "update" ]] && echo update || echo installation )"
say "This publishes your robot's state to MQTT so Home Assistant can read it."
say "${c_dim}It does not change anything on the robot itself.${c_off}"

# ---------------------------------------------------------------------------
# Questions
# ---------------------------------------------------------------------------
ask() {  # ask <variable> <prompt> <default>
  local __var="$1" __prompt="$2" __default="${3:-}" __reply
  # Already provided in the environment? Take it and move on. This is what
  # makes an unattended install possible:
  #   sudo MQTT_HOST=… MQTT_USERNAME=… MQTT_PASSWORD=… ./install.sh
  if [[ -n "${!__var:-}" ]]; then
    printf '%s: %s %s(from environment)%s\n' "$__prompt" "${!__var}" "$c_dim" "$c_off"
    return
  fi
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

if [[ "$ACTION" == "update" ]]; then
  say ""
  say "Keeping the current settings in ${CONF_PATH}."
  say "${c_dim}Use --reinstall to answer the questions again.${c_off}"
else
head_ "1. The robot"
say "${c_dim}If you are installing on the robot's own Pi, keep 127.0.0.1.${c_off}"
ask ROBOT_HOST "  Robot address" "127.0.0.1"
ask ROBOT_PORT "  Robot web UI port" "4006"

head_ "2. The MQTT broker"
say "${c_dim}For Home Assistant this is the machine running the Mosquitto add-on,${c_off}"
say "${c_dim}and the account is a normal Home Assistant user you created for it.${c_off}"

# Try to find it rather than making the user recite an IP address from memory.
# Two passes: the name Home Assistant advertises over mDNS, then a sweep of the
# local /24 for a host serving both the HA web UI and MQTT. Purely a suggestion
# — whatever is found is offered as a default and can be overridden.
DETECTED_BROKER=""
if [[ -z "${MQTT_HOST:-}" ]]; then
  say ""
  say "Looking for a Home Assistant MQTT broker..."
  DETECTED_BROKER="$(timeout 25 python3 - <<'PY' 2>/dev/null || true
import socket, sys, ipaddress
import concurrent.futures as cf

def is_open(host, port, t=0.4):
    try:
        s = socket.create_connection((host, port), timeout=t)
        s.close()
        return True
    except Exception:
        return False

# 1. The name Home Assistant publishes over mDNS.
for name in ("homeassistant.local", "homeassistant", "hassio.local"):
    try:
        ip = socket.gethostbyname(name)
    except Exception:
        continue
    if is_open(ip, 1883):
        print(ip)
        sys.exit(0)

# 2. Sweep the local /24 for a host that answers on both 8123 and 1883.
#    A UDP "connect" to a TEST-NET address sends nothing; it just reveals
#    which local interface would be used.
probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    probe.connect(("192.0.2.1", 9))
    local = probe.getsockname()[0]
finally:
    probe.close()

hosts = [str(h) for h in ipaddress.ip_network(local + "/24", strict=False).hosts()]
candidates = []
with cf.ThreadPoolExecutor(128) as pool:
    futures = {pool.submit(is_open, h, 8123): h for h in hosts}
    for fut in cf.as_completed(futures):
        try:
            if fut.result():
                candidates.append(futures[fut])
        except Exception:
            pass

for host in sorted(candidates):
    if is_open(host, 1883):
        print(host)
        sys.exit(0)

sys.exit(1)
PY
)"
  if [[ -n "$DETECTED_BROKER" ]]; then
    ok "Found Home Assistant with MQTT at ${DETECTED_BROKER}"
  else
    say "${c_dim}None found — you will need the address of your broker.${c_off}"
  fi
fi

ask MQTT_HOST "  Broker address" "$DETECTED_BROKER"
ask MQTT_PORT "  Broker port" "1883"
ask MQTT_USERNAME "  MQTT username" ""

if [[ -n "${MQTT_PASSWORD:-}" ]]; then
  say "  MQTT password: ${c_dim}(from environment)${c_off}"
else
  MQTT_PASSWORD=""
  while [[ -z "$MQTT_PASSWORD" ]]; do
    read -r -s -p "  MQTT password (hidden): " MQTT_PASSWORD || true
    echo
  done
fi

head_ "3. Topics"
ask TOPIC_PREFIX "  Topic prefix" "mowgli"
ask MIN_PUBLISH_INTERVAL "  Minimum seconds between updates" "2.0"
fi

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

if [[ "$ACTION" == "update" ]]; then
  ok "Configuration left untouched"
else
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
fi

# Running unprivileged relies on DynamicUser (systemd 232+) handing the config
# over as a credential (systemd 247+). On anything older, fall back to the
# plain form rather than shipping a unit that will not start.
SYSTEMD_VER="$(systemctl --version 2>/dev/null | head -1 | grep -oE '[0-9]+' | head -1 || true)"
if [[ "$SYSTEMD_VER" =~ ^[0-9]+$ ]] && (( SYSTEMD_VER >= 247 )); then
  SERVICE_IDENTITY="DynamicUser=yes
LoadCredential=conf:${CONF_PATH}
ExecStart=${BIN_PATH} %d/conf"
  ok "Service will run unprivileged (systemd ${SYSTEMD_VER})"
else
  SERVICE_IDENTITY="User=root
ExecStart=${BIN_PATH} ${CONF_PATH}"
  say "${c_dim}systemd ${SYSTEMD_VER:-unknown} is too old for credentials — running as root.${c_off}"
fi

cat > "$UNIT_PATH" <<EOF
[Unit]
Description=MowgliNext to MQTT bridge for Home Assistant
Documentation=https://github.com/juditech3D/MowgliNext-ha-bridge
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=10

# The bridge needs two things: outbound TCP, and its configuration. It never
# needs to be root, so it isn't. DynamicUser gives it a throwaway unprivileged
# account for the lifetime of the service — nothing to create, nothing left
# behind. The config stays root-owned 0600 on disk; systemd reads it while
# still privileged and hands it over as a credential the service user can read.
${SERVICE_IDENTITY}

# It opens sockets and reads one file. Everything else is denied.
CapabilityBoundingSet=
AmbientCapabilities=
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

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
say "  Update         :  sudo $0 --update"
say "  Uninstall      :  sudo $0 --uninstall"
say ""
say "In Home Assistant, add the entities from homeassistant/mowgli_mqtt.yaml"
say "and the dashboard card from homeassistant/mowgli_card.yaml."
say ""
say "${c_dim}If the log shows 'not authorised', the MQTT account is wrong: create a${c_off}"
say "${c_dim}normal Home Assistant user and use those exact credentials.${c_off}"
