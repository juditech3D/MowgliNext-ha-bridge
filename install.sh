#!/usr/bin/env bash
#
# mowglinext-ha-bridge installer
#
# Installs a systemd service that mirrors a MowgliNext robot's live state onto
# an MQTT broker, so Home Assistant can read it. Nothing on the robot is
# modified: the bridge only reads the same WebSocket API the robot's own web UI
# uses.
#
#     sudo ./install.sh
#     sudo ./install.sh --update | --reinstall | --uninstall | --purge
#     curl -fsSL <raw>/install.sh | sudo bash
#
set -euo pipefail

SERVICE_NAME="mowglinext-ha-bridge"
BIN_PATH="/usr/local/bin/${SERVICE_NAME}"
CONF_PATH="/etc/${SERVICE_NAME}.conf"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
SRC_NAME="mowglinext_ha_bridge.py"
REPO_URL="https://github.com/juditech3D/MowgliNext-ha-bridge"
REPO_RAW="https://raw.githubusercontent.com/juditech3D/MowgliNext-ha-bridge/main"
RAW_URL="${REPO_RAW}/${SRC_NAME}"
SELF_URL="${REPO_RAW}/install.sh"

# ---------------------------------------------------------------------------
# One-line install
#
#   curl -fsSL .../install.sh | sudo bash
#
# Two separate problems have to be solved here, and missing either one breaks
# the prompts in a way that is not obvious:
#
#   1. bash reads the script from stdin, so a `read` would consume the script
#      itself. Fixed by re-running from a real file.
#   2. even then, stdin is still the pipe, which still holds the rest of the
#      downloaded script. `read` would hand those leftover bytes back as if the
#      user had typed them. Fixed by pointing stdin at the terminal.
# ---------------------------------------------------------------------------
if [[ ! -f "${BASH_SOURCE[0]:-}" ]]; then
  if ! command -v curl >/dev/null; then
    echo "curl is required for the one-line install." >&2
    exit 1
  fi
  _self="$(mktemp)"
  curl -fsSL "$SELF_URL" -o "$_self" || { echo "Could not download the installer." >&2; exit 1; }
  chmod +x "$_self"
  if [[ -r /dev/tty ]]; then
    exec env _MHB_SELF_TMP="$_self" bash "$_self" "$@" < /dev/tty
  else
    # No terminal at all: answers must come from the environment.
    exec env _MHB_SELF_TMP="$_self" bash "$_self" "$@" < /dev/null
  fi
fi

# Second pass of a one-line install: tidy the copy we downloaded of ourselves.
# Written as an `if` on purpose: under `set -e`, a bare `[[ … ]] && …` whose
# test fails returns non-zero and would abort the installer.
if [[ -n "${_MHB_SELF_TMP:-}" ]]; then
  trap 'rm -f "$_MHB_SELF_TMP"' EXIT
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

c_bold=$'\033[1m'; c_green=$'\033[32m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
say()   { printf '%s\n' "$*"; }
ok()    { printf '%s✓%s %s\n' "$c_green" "$c_off" "$*"; }
err()   { printf '%s✗%s %s\n' "$c_red" "$c_off" "$*" >&2; }
head_() { printf '\n%s%s%s\n' "$c_bold" "$*" "$c_off"; }
die()   { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Language
# ---------------------------------------------------------------------------
declare -A T

lang_en() {
  T[intro1]="This publishes your robot's state to MQTT so Home Assistant can read it."
  T[intro2]="It does not change anything on the robot itself."
  T[sec_robot]="1. The robot"
  T[hint_robot]="If you are installing on the robot's own Pi, keep 127.0.0.1."
  T[q_robot_host]="  Robot address"
  T[q_robot_port]="  Robot web UI port"
  T[sec_broker]="2. The MQTT broker"
  T[hint_broker1]="For Home Assistant this is the machine running the Mosquitto add-on,"
  T[hint_broker2]="and the account is a normal Home Assistant user you created for it."
  T[searching]="Looking for a Home Assistant MQTT broker..."
  T[found]="Found Home Assistant with MQTT at"
  T[notfound]="None found — you will need the address of your broker."
  T[q_mqtt_host]="  Broker address"
  T[q_mqtt_port]="  Broker port"
  T[q_mqtt_user]="  MQTT username"
  T[q_mqtt_pass]="  MQTT password (hidden): "
  T[sec_topics]="3. Topics"
  T[q_prefix]="  Topic prefix"
  T[q_interval]="  Minimum seconds between updates"
  T[from_env]="(from environment)"
  T[installing]="Installing"
  T[inst_local]="Installed %s (from this directory)"
  T[inst_dl]="Installed %s (downloaded)"
  T[conf_written]="Wrote %s (mode 0600, root only)"
  T[conf_kept]="Configuration left untouched"
  T[unpriv]="Service will run unprivileged (systemd %s)"
  T[asroot]="systemd %s is too old for credentials — running as root."
  T[unit_written]="Wrote %s"
  T[waiting]="Waiting for the first connection..."
  T[running]="Service is running."
  T[failed]="Service failed to start."
  T[recent_log]="Recent log"
  T[next_steps]="Next steps"
  T[n_log]="  Follow the log :  "
  T[n_restart]="  Restart        :  "
  T[n_reconf]="  Reconfigure    :  "
  T[n_update]="  Update         :  "
  T[n_uninst]="  Uninstall      :  "
  T[ha_hint1]="In Home Assistant, add the entities from homeassistant/mowgli_mqtt.yaml"
  T[ha_hint2]="and the dashboard card from homeassistant/mowgli_card.yaml."
  T[auth_hint1]="If the log shows 'not authorised', the MQTT account is wrong: create a"
  T[auth_hint2]="normal Home Assistant user and use those exact credentials."
  T[already]="%s is already installed"
  T[l_program]="  program  "
  T[l_config]="  config   "
  T[l_service]="  service  "
  T[m_update]=") Update      — new program, keep the current settings"
  T[m_reconf]=") Reconfigure — ask every question again"
  T[m_uninst]=") Uninstall   — remove it"
  T[m_cancel]=") Cancel"
  T[choice]="Your choice [1]: "
  T[nothing]="Nothing done."
  T[keep_conf]="Keeping the current settings in %s."
  T[keep_hint]="Use --reinstall to answer the questions again."
  T[removing]="Removing %s"
  T[stopped]="Service stopped and disabled."
  T[clearing]="Clearing retained MQTT topics..."
  T[cleared]="Broker cleaned."
  T[clear_fail1]="Could not reach the broker — retained topics may remain."
  T[clear_fail2]="Harmless, but Home Assistant will show stale values until cleared."
  T[removed]="Service unit and program removed."
  T[ask_purge]="Also delete %s (it holds your broker password)? [y/N]: "
  T[conf_deleted]="Configuration deleted."
  T[conf_left]="%s kept — delete it with: sudo rm %s"
  T[done]="Done"
  T[done1]="Nothing of this tool is left running. The robot was never modified,"
  T[done2]="so it is unaffected."
  T[undo_ha1]="In Home Assistant, remove the mqtt: block you added to"
  T[undo_ha2]="configuration.yaml and the dashboard card, then restart."
  T[e_noterm]="No terminal to read the answers from. Provide them in the environment:"
  T[e_port]="Port must be a number between 1 and 65535, got: %s"
  T[e_host]="Not a valid address: %s"
  T[e_prefix]="Topic prefix may only contain letters, digits, - _ and /, got: %s"
  T[e_interval]="Interval must be a number, got: %s"
  T[e_nopy]="python3 is required but not installed."
  T[e_root]="Run me with sudo: sudo %s"
  T[e_noupdate]="Nothing to update: %s does not exist. Run without --update."
  T[e_opt]="Unknown option: %s  (try --help)"
  T[title_inst]="%s — installation"
  T[title_upd]="%s — update"
}

lang_fr() {
  T[intro1]="Publie l'état de votre robot sur MQTT pour que Home Assistant le lise."
  T[intro2]="Ne modifie rien sur le robot lui-même."
  T[sec_robot]="1. Le robot"
  T[hint_robot]="Si vous installez sur le Pi du robot, gardez 127.0.0.1."
  T[q_robot_host]="  Adresse du robot"
  T[q_robot_port]="  Port de l'interface web"
  T[sec_broker]="2. Le broker MQTT"
  T[hint_broker1]="Pour Home Assistant, c'est la machine qui exécute le module Mosquitto,"
  T[hint_broker2]="et le compte est un utilisateur Home Assistant que vous avez créé."
  T[searching]="Recherche d'un broker MQTT Home Assistant..."
  T[found]="Home Assistant avec MQTT trouvé à"
  T[notfound]="Aucun trouvé — il vous faudra l'adresse de votre broker."
  T[q_mqtt_host]="  Adresse du broker"
  T[q_mqtt_port]="  Port du broker"
  T[q_mqtt_user]="  Nom d'utilisateur MQTT"
  T[q_mqtt_pass]="  Mot de passe MQTT (masqué) : "
  T[sec_topics]="3. Les topics"
  T[q_prefix]="  Préfixe des topics"
  T[q_interval]="  Secondes minimum entre deux envois"
  T[from_env]="(depuis l'environnement)"
  T[installing]="Installation"
  T[inst_local]="Installé %s (depuis ce dossier)"
  T[inst_dl]="Installé %s (téléchargé)"
  T[conf_written]="Écrit %s (mode 0600, root uniquement)"
  T[conf_kept]="Configuration laissée intacte"
  T[unpriv]="Le service tournera sans privilèges (systemd %s)"
  T[asroot]="systemd %s trop ancien pour les credentials — exécution en root."
  T[unit_written]="Écrit %s"
  T[waiting]="Attente de la première connexion..."
  T[running]="Le service tourne."
  T[failed]="Le service n'a pas démarré."
  T[recent_log]="Journal récent"
  T[next_steps]="Et ensuite"
  T[n_log]="  Suivre le journal :  "
  T[n_restart]="  Redémarrer        :  "
  T[n_reconf]="  Reconfigurer      :  "
  T[n_update]="  Mettre à jour     :  "
  T[n_uninst]="  Désinstaller      :  "
  T[ha_hint1]="Dans Home Assistant, ajoutez les entités de homeassistant/mowgli_mqtt.yaml"
  T[ha_hint2]="et la carte de tableau de bord de homeassistant/mowgli_card.yaml."
  T[auth_hint1]="Si le journal affiche 'not authorised', le compte MQTT est mauvais :"
  T[auth_hint2]="créez un utilisateur Home Assistant et reprenez ces identifiants exacts."
  T[already]="%s est déjà installé"
  T[l_program]="  programme  "
  T[l_config]="  config     "
  T[l_service]="  service    "
  T[m_update]=") Mettre à jour — nouveau programme, réglages conservés"
  T[m_reconf]=") Reconfigurer  — reposer toutes les questions"
  T[m_uninst]=") Désinstaller  — tout retirer"
  T[m_cancel]=") Annuler"
  T[choice]="Votre choix [1] : "
  T[nothing]="Rien n'a été fait."
  T[keep_conf]="Réglages actuels conservés dans %s."
  T[keep_hint]="Utilisez --reinstall pour reposer les questions."
  T[removing]="Suppression de %s"
  T[stopped]="Service arrêté et désactivé."
  T[clearing]="Effacement des topics MQTT retenus..."
  T[cleared]="Broker nettoyé."
  T[clear_fail1]="Broker injoignable — des topics retenus peuvent subsister."
  T[clear_fail2]="Sans gravité, mais Home Assistant affichera des valeurs figées."
  T[removed]="Unité de service et programme supprimés."
  T[ask_purge]="Supprimer aussi %s (il contient votre mot de passe) ? [o/N] : "
  T[conf_deleted]="Configuration supprimée."
  T[conf_left]="%s conservé — supprimez-le avec : sudo rm %s"
  T[done]="Terminé"
  T[done1]="Plus rien de cet outil ne tourne. Le robot n'a jamais été modifié,"
  T[done2]="il n'est donc pas affecté."
  T[undo_ha1]="Dans Home Assistant, retirez le bloc mqtt: de configuration.yaml"
  T[undo_ha2]="ainsi que la carte, puis redémarrez."
  T[e_noterm]="Aucun terminal pour lire les réponses. Fournissez-les par l'environnement :"
  T[e_port]="Le port doit être un nombre entre 1 et 65535, reçu : %s"
  T[e_host]="Adresse invalide : %s"
  T[e_prefix]="Le préfixe n'accepte que lettres, chiffres, - _ et /, reçu : %s"
  T[e_interval]="L'intervalle doit être un nombre, reçu : %s"
  T[e_nopy]="python3 est requis mais n'est pas installé."
  T[e_root]="Lancez-moi avec sudo : sudo %s"
  T[e_noupdate]="Rien à mettre à jour : %s n'existe pas. Lancez sans --update."
  T[e_opt]="Option inconnue : %s  (essayez --help)"
  T[title_inst]="%s — installation"
  T[title_upd]="%s — mise à jour"
}

usage() {
  cat <<USAGE
Usage: $0 [--update | --reinstall | --uninstall | --purge] [--lang en|fr]

  (no option)   install, or ask what to do if already installed
  --update      replace the program, keep the configuration
  --reinstall   ask every question again
  --uninstall   remove the service, ask about the configuration
  --purge       remove the service and the configuration
  --lang en|fr  skip the language question

Any answer already set in the environment is used without asking:
  sudo MQTT_HOST=… MQTT_USERNAME=… MQTT_PASSWORD=… $0

$REPO_URL
USAGE
}

# Help before the root check — asking what a script does should not need sudo.
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
  esac
done

# ---------------------------------------------------------------------------
LANG_CHOICE="${MHB_LANG:-}"
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--lang" ]]; then LANG_CHOICE="$arg"; fi
  case "$arg" in --lang=*) LANG_CHOICE="${arg#--lang=}" ;; esac
  prev="$arg"
done

lang_en  # so every key exists even if the user never chooses
if [[ -z "$LANG_CHOICE" ]]; then
  # Default to whatever the system suggests, but always let the user override.
  default_lang=1
  case "${LANG:-}${LC_ALL:-}" in fr_*|fr|*fr_FR*) default_lang=2 ;; esac
  printf '\n%sLanguage / Langue%s\n' "$c_bold" "$c_off"
  printf '  1) English\n  2) Français\n'
  reply=""
  if read -r -p "  [${default_lang}]: " reply; then :; else reply=""; fi
  reply="${reply:-$default_lang}"
  case "$reply" in 2|fr|FR|Fr) LANG_CHOICE="fr" ;; *) LANG_CHOICE="en" ;; esac
fi
case "$LANG_CHOICE" in fr|FR|francais|français) lang_fr ;; *) lang_en ;; esac

t() { printf '%s' "${T[$1]}"; }
tf() { local k="$1"; shift; printf "${T[$k]}" "$@"; }

# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  err "$(tf e_root "$0")"
  exit 1
fi

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
do_uninstall() {  # do_uninstall <purge: yes|no|ask>
  local purge="${1:-ask}"
  head_ "$(tf removing "$SERVICE_NAME")"

  # Stop first. Clearing the retained topics while the bridge is still running
  # would achieve nothing: it republishes them within the second.
  systemctl disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
  ok "$(t stopped)"

  # Retained MQTT messages outlive the client that sent them. Left alone, Home
  # Assistant would keep displaying the last battery level for ever, with no
  # hint that it is frozen.
  if [[ -f "$CONF_PATH" && -x "$BIN_PATH" ]]; then
    say "$(t clearing)"
    if "$BIN_PATH" "$CONF_PATH" --clear-retained 2>&1 | sed 's/^/  /'; then
      ok "$(t cleared)"
    else
      say "${c_dim}$(t clear_fail1)${c_off}"
      say "${c_dim}$(t clear_fail2)${c_off}"
    fi
  fi

  rm -f "$UNIT_PATH" "$BIN_PATH"
  systemctl daemon-reload
  ok "$(t removed)"

  if [[ "$purge" == "ask" ]]; then
    local reply=""
    if read -r -p "$(tf ask_purge "$CONF_PATH")" reply; then :; else reply=""; fi
    if [[ "$reply" =~ ^[YyOo] ]]; then purge="yes"; else purge="no"; fi
  fi

  if [[ "$purge" == "yes" ]]; then
    rm -f "$CONF_PATH"
    ok "$(t conf_deleted)"
  else
    say "${c_dim}$(tf conf_left "$CONF_PATH" "$CONF_PATH")${c_off}"
  fi

  head_ "$(t done)"
  say "$(t done1)"
  say "$(t done2)"
  say ""
  say "${c_dim}$(t undo_ha1)${c_off}"
  say "${c_dim}$(t undo_ha2)${c_off}"
  exit 0
}

# ---------------------------------------------------------------------------
# What are we being asked to do?
# ---------------------------------------------------------------------------
ACTION=""
PURGE="ask"
skip_next=""
for arg in "$@"; do
  if [[ -n "$skip_next" ]]; then skip_next=""; continue; fi
  case "$arg" in
    --uninstall|--remove) ACTION="uninstall" ;;
    --purge)              ACTION="uninstall"; PURGE="yes" ;;
    --update|--upgrade)   ACTION="update" ;;
    --reinstall)          ACTION="reinstall" ;;
    --lang)               skip_next="1" ;;
    --lang=*)             ;;
    -h|--help)            ;;  # handled above
    *) die "$(tf e_opt "$arg")" ;;
  esac
done

if [[ "$ACTION" == "uninstall" ]]; then
  do_uninstall "$PURGE"
fi

command -v python3 >/dev/null || die "$(t e_nopy)"

# ---------------------------------------------------------------------------
# Already installed? Offer the sensible choices rather than silently redoing it.
# ---------------------------------------------------------------------------
if [[ ( -f "$UNIT_PATH" || -x "$BIN_PATH" || -f "$CONF_PATH" ) && -z "$ACTION" ]]; then
  head_ "$(tf already "$SERVICE_NAME")"
  if [[ -x "$BIN_PATH"  ]]; then say "$(t l_program)${BIN_PATH}"; fi
  if [[ -f "$CONF_PATH" ]]; then say "$(t l_config)${CONF_PATH}"; fi
  if [[ -f "$UNIT_PATH" ]]; then
    say "$(t l_service)$(systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || echo inactive)"
  fi
  say ""
  say "  ${c_bold}1${c_off}$(t m_update)"
  say "  ${c_bold}2${c_off}$(t m_reconf)"
  say "  ${c_bold}3${c_off}$(t m_uninst)"
  say "  ${c_bold}4${c_off}$(t m_cancel)"
  say ""
  choice=""
  while [[ ! "$choice" =~ ^[1-4]$ ]]; do
    if read -r -p "$(t choice)" choice; then :; else die "$(t e_noterm)"; fi
    choice="${choice:-1}"
  done
  case "$choice" in
    1) ACTION="update" ;;
    2) ACTION="reinstall" ;;
    3) do_uninstall "ask" ;;
    4) say "$(t nothing)"; exit 0 ;;
  esac
fi

if [[ "$ACTION" == "update" && ! -f "$CONF_PATH" ]]; then
  die "$(tf e_noupdate "$CONF_PATH")"
fi

if [[ "$ACTION" == "update" ]]; then
  head_ "$(tf title_upd "$SERVICE_NAME")"
else
  head_ "$(tf title_inst "$SERVICE_NAME")"
fi
say "$(t intro1)"
say "${c_dim}$(t intro2)${c_off}"

# ---------------------------------------------------------------------------
# Questions
# ---------------------------------------------------------------------------
ask() {  # ask <variable> <prompt> <default>
  local __var="$1" __prompt="$2" __default="${3:-}" __reply
  # Already provided in the environment? Take it and move on. This is what
  # makes an unattended install possible.
  if [[ -n "${!__var:-}" ]]; then
    printf '%s: %s %s%s%s\n' "$__prompt" "${!__var}" "$c_dim" "$(t from_env)" "$c_off"
    return
  fi
  while true; do
    if [[ -n "$__default" ]]; then
      if read -r -p "$__prompt [$__default]: " __reply; then :; else __reply=""; fi
      __reply="${__reply:-$__default}"
    else
      # No default: a value is mandatory, and an unreadable stdin is fatal
      # rather than something to paper over with an empty string.
      if ! read -r -p "$__prompt: " __reply; then
        echo
        err "$(t e_noterm)"
        err "  sudo MQTT_HOST=… MQTT_USERNAME=… MQTT_PASSWORD=… $0"
        exit 1
      fi
    fi
    [[ -n "$__reply" ]] && break
  done
  printf -v "$__var" '%s' "$__reply"
}

valid_host() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]]; }
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

if [[ "$ACTION" == "update" ]]; then
  say ""
  say "$(tf keep_conf "$CONF_PATH")"
  say "${c_dim}$(t keep_hint)${c_off}"
else
  head_ "$(t sec_robot)"
  say "${c_dim}$(t hint_robot)${c_off}"
  ask ROBOT_HOST "$(t q_robot_host)" "127.0.0.1"
  ask ROBOT_PORT "$(t q_robot_port)" "4006"

  head_ "$(t sec_broker)"
  say "${c_dim}$(t hint_broker1)${c_off}"
  say "${c_dim}$(t hint_broker2)${c_off}"

  # Find the broker rather than making the user recite an IP address. Two
  # passes: the name Home Assistant advertises over mDNS, then a sweep of the
  # local /24 for a host serving both the HA web UI and MQTT. Only a suggestion.
  DETECTED_BROKER=""
  if [[ -z "${MQTT_HOST:-}" ]]; then
    say ""
    say "$(t searching)"
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

for name in ("homeassistant.local", "homeassistant", "hassio.local"):
    try:
        ip = socket.gethostbyname(name)
    except Exception:
        continue
    if is_open(ip, 1883):
        print(ip)
        sys.exit(0)

# A UDP "connect" to a TEST-NET address sends nothing; it only reveals which
# local interface would be used.
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
      ok "$(t found) ${DETECTED_BROKER}"
    else
      say "${c_dim}$(t notfound)${c_off}"
    fi
  fi

  ask MQTT_HOST "$(t q_mqtt_host)" "$DETECTED_BROKER"
  ask MQTT_PORT "$(t q_mqtt_port)" "1883"
  ask MQTT_USERNAME "$(t q_mqtt_user)" ""

  if [[ -n "${MQTT_PASSWORD:-}" ]]; then
    say "$(t q_mqtt_pass)${c_dim}$(t from_env)${c_off}"
  else
    MQTT_PASSWORD=""
    while [[ -z "$MQTT_PASSWORD" ]]; do
      if ! read -r -s -p "$(t q_mqtt_pass)" MQTT_PASSWORD; then
        echo
        err "$(t e_noterm)"
        err "  sudo MQTT_PASSWORD='…' $0"
        exit 1
      fi
      echo
    done
  fi

  head_ "$(t sec_topics)"
  ask TOPIC_PREFIX "$(t q_prefix)" "mowgli"
  ask MIN_PUBLISH_INTERVAL "$(t q_interval)" "2.0"

  # Validate before writing anything. A bad answer that reaches the config file
  # only surfaces later as a stack trace in the service log.
  valid_host "$ROBOT_HOST"  || die "$(tf e_host "$ROBOT_HOST")"
  valid_host "$MQTT_HOST"   || die "$(tf e_host "$MQTT_HOST")"
  valid_port "$ROBOT_PORT"  || die "$(tf e_port "$ROBOT_PORT")"
  valid_port "$MQTT_PORT"   || die "$(tf e_port "$MQTT_PORT")"
  [[ "$TOPIC_PREFIX" =~ ^[A-Za-z0-9_/-]+$ ]] || die "$(tf e_prefix "$TOPIC_PREFIX")"
  [[ "$MIN_PUBLISH_INTERVAL" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "$(tf e_interval "$MIN_PUBLISH_INTERVAL")"
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
head_ "$(t installing)"
if [[ -f "${SCRIPT_DIR}/${SRC_NAME}" ]]; then
  install -m 0755 "${SCRIPT_DIR}/${SRC_NAME}" "$BIN_PATH"
  ok "$(tf inst_local "$BIN_PATH")"
elif command -v curl >/dev/null; then
  curl -fsSL "$RAW_URL" -o "$BIN_PATH"
  chmod 0755 "$BIN_PATH"
  ok "$(tf inst_dl "$BIN_PATH")"
else
  die "${SRC_NAME} not found next to this script, and curl is unavailable."
fi

if [[ "$ACTION" == "update" ]]; then
  ok "$(t conf_kept)"
else
  umask 077
  cat > "$CONF_PATH" <<EOF
# ${SERVICE_NAME} configuration — written by install.sh
# This file contains a password: keep it readable by root only.

ROBOT_HOST=${ROBOT_HOST}
ROBOT_PORT=${ROBOT_PORT}

MQTT_HOST=${MQTT_HOST}
MQTT_PORT=${MQTT_PORT}
MQTT_USERNAME=${MQTT_USERNAME}
MQTT_PASSWORD=${MQTT_PASSWORD}
MQTT_CLIENT_ID=${SERVICE_NAME}

TOPIC_PREFIX=${TOPIC_PREFIX}
MIN_PUBLISH_INTERVAL=${MIN_PUBLISH_INTERVAL}
EOF
  chown root:root "$CONF_PATH"
  chmod 0600 "$CONF_PATH"
  ok "$(tf conf_written "$CONF_PATH")"
fi

# Running unprivileged relies on DynamicUser (systemd 232+) handing the config
# over as a credential (systemd 247+). On anything older, fall back rather than
# shipping a unit that will not start.
SYSTEMD_VER="$(systemctl --version 2>/dev/null | head -1 | grep -oE '[0-9]+' | head -1 || true)"
if [[ "$SYSTEMD_VER" =~ ^[0-9]+$ ]] && (( SYSTEMD_VER >= 247 )); then
  SERVICE_IDENTITY="DynamicUser=yes
LoadCredential=conf:${CONF_PATH}
ExecStart=${BIN_PATH} %d/conf"
  ok "$(tf unpriv "$SYSTEMD_VER")"
else
  SERVICE_IDENTITY="User=root
ExecStart=${BIN_PATH} ${CONF_PATH}"
  say "${c_dim}$(tf asroot "${SYSTEMD_VER:-?}")${c_off}"
fi

cat > "$UNIT_PATH" <<EOF
[Unit]
Description=MowgliNext to MQTT bridge for Home Assistant
Documentation=${REPO_URL}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=10

# The bridge needs two things: outbound TCP, and its configuration. It never
# needs to be root, so it isn't.
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
ok "$(tf unit_written "$UNIT_PATH")"

# ---------------------------------------------------------------------------
# Start and verify
# ---------------------------------------------------------------------------
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service" >/dev/null 2>&1
systemctl restart "${SERVICE_NAME}.service"

say ""
say "$(t waiting)"
sleep 6

if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
  ok "$(t running)"
else
  err "$(t failed)"
fi

head_ "$(t recent_log)"
journalctl -u "${SERVICE_NAME}.service" -n 20 --no-pager || true

# When run from a pipe, $0 is a temporary file that no longer exists by the
# time the user reads this. Show a command that will still work tomorrow.
if [[ -n "${_MHB_SELF_TMP:-}" ]]; then
  UPD_CMD="curl -fsSL ${SELF_URL} | sudo bash -s -- --update"
  DEL_CMD="curl -fsSL ${SELF_URL} | sudo bash -s -- --purge"
else
  UPD_CMD="sudo $0 --update"
  DEL_CMD="sudo $0 --uninstall"
fi

head_ "$(t next_steps)"
say "$(t n_log)sudo journalctl -u ${SERVICE_NAME} -f"
say "$(t n_restart)sudo systemctl restart ${SERVICE_NAME}"
say "$(t n_reconf)sudo nano ${CONF_PATH} && sudo systemctl restart ${SERVICE_NAME}"
say "$(t n_update)${UPD_CMD}"
say "$(t n_uninst)${DEL_CMD}"
say ""
say "$(t ha_hint1)"
say "$(t ha_hint2)"
say ""
say "${c_dim}$(t auth_hint1)${c_off}"
say "${c_dim}$(t auth_hint2)${c_off}"
