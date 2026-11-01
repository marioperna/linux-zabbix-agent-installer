#!/usr/bin/env bash
#
# Installa Zabbix Agent 2 (7.0 LTS) dal repository ufficiale repo.zabbix.com
# su Debian 11/12/13 e Ubuntu 20.04/22.04/24.04/26.04 (amd64 e arm64).
#
# Uso:
#   sudo bash install-zabbix-agent2.sh --server 192.168.1.247
#   sudo bash install-zabbix-agent2.sh --server 100.64.0.10 --hostname web01
#
# Opzioni:
#   --server IP        IP del server Zabbix (obbligatorio, chiesto se manca)
#   --hostname NOME    nome host in Zabbix (default: hostname della macchina)
#   -h, --help         mostra questo aiuto
#
# Il firewall non viene modificato: la porta 10050 va aperta a parte
# (es. dal firewall di Proxmox). Se UFW è attivo, lo script lo segnala.
#
# Si può rilanciare senza problemi: aggiorna solo la configurazione.

set -euo pipefail

ZABBIX_VERSION="7.0"
CONF="/etc/zabbix/zabbix_agent2.conf"
AGENT_PORT="10050"

SERVER=""
HOST_NAME=""

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m OK\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m !!\033[0m %s\n' "$*"; }
fail()  { printf '\033[1;31mERRORE:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Installa Zabbix Agent 2 (7.0 LTS) dal repository ufficiale repo.zabbix.com.

Uso:
  sudo bash install-zabbix-agent2.sh --server IP [--hostname NOME]

Opzioni:
  --server IP        IP del server Zabbix (obbligatorio, chiesto se manca)
  --hostname NOME    nome host in Zabbix (default: hostname della macchina)
  -h, --help         mostra questo aiuto

Il firewall non viene modificato: apri la porta 10050 a parte (es. da Proxmox).
EOF
  exit 0
}

# --- Argomenti -------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server)      SERVER="${2:-}"; shift 2 ;;
    --hostname)    HOST_NAME="${2:-}"; shift 2 ;;
    -h|--help)     usage ;;
    *) fail "opzione sconosciuta: $1 (usa --help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || fail "lancia lo script come root (sudo bash $0 ...)"

if [[ -z "$SERVER" ]]; then
  # Legge dalla tastiera anche quando lo script arriva da una pipe (wget -qO- ... | bash)
  if [[ -r /dev/tty ]]; then
    read -rp "IP del server Zabbix: " SERVER < /dev/tty
  fi
fi
[[ -n "$SERVER" ]] || fail "serve l'IP del server Zabbix (--server)"

if [[ -z "$HOST_NAME" ]]; then
  HOST_NAME="$(hostname -s)"
fi
# Caratteri ammessi da Zabbix per il nome host
[[ "$HOST_NAME" =~ ^[A-Za-z0-9._\ -]+$ ]] || fail "nome host non valido: '$HOST_NAME'"

# --- Sistema operativo -----------------------------------------------------
[[ -r /etc/os-release ]] || fail "/etc/os-release non trovato"
# shellcheck disable=SC1091
. /etc/os-release
OS_ID="${ID:-}"
OS_VER="${VERSION_ID:-}"

case "$OS_ID:$OS_VER" in
  debian:11|debian:12|debian:13) ;;
  ubuntu:20.04|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) ;;
  *) fail "sistema non supportato: ${PRETTY_NAME:-$OS_ID $OS_VER}" ;;
esac

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64) REPO_PATH="$OS_ID" ;;
  arm64) REPO_PATH="${OS_ID}-arm64" ;;
  *) fail "architettura non supportata: $ARCH" ;;
esac

RELEASE_DEB="zabbix-release_latest_${ZABBIX_VERSION}+${OS_ID}${OS_VER}_all.deb"
RELEASE_URL="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/${REPO_PATH}/pool/main/z/zabbix-release/${RELEASE_DEB}"

info "Sistema: ${PRETTY_NAME} (${ARCH})"
info "Server Zabbix: ${SERVER} · Nome host: ${HOST_NAME}"

# --- Repository ufficiale Zabbix ------------------------------------------
export DEBIAN_FRONTEND=noninteractive

info "Installo i prerequisiti (wget, ca-certificates)"
apt-get update -qq
apt-get install -y -qq wget ca-certificates >/dev/null

info "Aggiungo il repository ufficiale Zabbix ${ZABBIX_VERSION}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
wget -q -O "$TMP_DIR/$RELEASE_DEB" "$RELEASE_URL" || fail "download non riuscito: $RELEASE_URL"
dpkg -i "$TMP_DIR/$RELEASE_DEB" >/dev/null
apt-get update -qq
ok "repository aggiunto"

# --- Installazione agent ---------------------------------------------------
info "Installo zabbix-agent2"
apt-get install -y -qq zabbix-agent2 >/dev/null

INSTALLED="$(dpkg-query -W -f='${Version}' zabbix-agent2)"
MADISON="$(apt-cache madison zabbix-agent2 || true)"
if grep -F "$INSTALLED" <<< "$MADISON" | grep -q 'repo.zabbix.com'; then
  ok "zabbix-agent2 ${INSTALLED} (da repo.zabbix.com)"
else
  warn "zabbix-agent2 ${INSTALLED} NON proviene da repo.zabbix.com: controlla con 'apt-cache policy zabbix-agent2'"
fi

# --- Configurazione --------------------------------------------------------
[[ -f "$CONF" ]] || fail "file di configurazione non trovato: $CONF"
[[ -f "${CONF}.orig" ]] || cp -p "$CONF" "${CONF}.orig"

# Imposta "Chiave=valore": sostituisce la riga attiva se c'è, altrimenti la aggiunge.
set_param() {
  local key="$1" value="$2" escaped
  escaped="$(printf '%s' "$value" | sed 's/[&|\\]/\\&/g')"
  if grep -qE "^${key}=" "$CONF"; then
    sed -i "s|^${key}=.*|${key}=${escaped}|" "$CONF"
  else
    printf '%s=%s\n' "$key" "$value" >> "$CONF"
  fi
}

info "Configuro ${CONF} (backup in ${CONF}.orig)"
set_param "Server"       "$SERVER"
set_param "ServerActive" "$SERVER"
set_param "Hostname"     "$HOST_NAME"
ok "Server=${SERVER} · ServerActive=${SERVER} · Hostname=${HOST_NAME}"

# --- Firewall: solo controllo, nessuna modifica ----------------------------
UFW_STATUS=""
command -v ufw >/dev/null && UFW_STATUS="$(ufw status 2>/dev/null || true)"
if grep -q '^Status: active' <<< "$UFW_STATUS"; then
  warn "UFW è attivo in questa macchina e potrebbe bloccare la porta ${AGENT_PORT}."
  warn "Lo script non lo modifica: aprila tu o disattiva UFW se gestisci tutto da Proxmox."
fi

# --- Avvio -----------------------------------------------------------------
info "Avvio il servizio"
systemctl enable zabbix-agent2 >/dev/null 2>&1
systemctl restart zabbix-agent2
sleep 2
if systemctl is-active --quiet zabbix-agent2; then
  ok "zabbix-agent2 attivo"
else
  journalctl -u zabbix-agent2 -n 20 --no-pager || true
  fail "zabbix-agent2 non si è avviato (vedi log sopra)"
fi

# --- Riepilogo -------------------------------------------------------------
LAN_IPS="$(hostname -I 2>/dev/null | xargs || true)"
TS_IP=""
command -v tailscale >/dev/null && TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"

cat <<EOF

────────────────────────────────────────────────────────
 Agent installato. Ora in Zabbix:
   Raccolta dati → Host → Crea host
     Nome host : ${HOST_NAME}
     Template  : Linux by Zabbix agent
     Interfaccia Agent, porta ${AGENT_PORT}, IP:
       ${LAN_IPS:-?}  (rete locale)
EOF
[[ -n "$TS_IP" ]] && echo "       ${TS_IP}  (Tailscale)"
cat <<EOF

 Test dal server Zabbix:
   zabbix_get -s <IP-di-questa-macchina> -k agent.ping   → deve rispondere 1
────────────────────────────────────────────────────────
EOF
