#!/usr/bin/env bash
set -euo pipefail

PROFILE_DIR="${HOME}/.config/netlab-wireguard"
PROFILE_FILE="${PROFILE_DIR}/client.env"

usage() {
  cat <<'EOF'
Usage:
  connect-client.sh --server-endpoint <ip:port> --server-ssh <user@host> [options]

One-command onboarding:
  curl -fsSL <raw-connect-client-url> | bash -s -- \
    --server-endpoint <server-public-ip-or-dns>:51820 \
    --server-ssh <server-user>@<server-public-ip>

Options:
  --client-name <name>             Client peer name (default: hostname)
  --server-endpoint <ip:port>      WireGuard endpoint (required)
  --server-ssh <user@host>         SSH host for peer registration (required)
  --client-address <cidr>          Client VPN address (default: 10.0.0.20/24)
  --dns <ip>                       DNS server over VPN (default: 10.0.0.1)
  --allowed-ips <cidr-list>        Allowed route set (default: 10.0.0.0/24)
  --interface <wg-if>              WireGuard interface (default: wg0)
  --server-config-path <path>      Server WG config path (default: /etc/wireguard/wg0.conf)
  --server-public-key <key>        Optional pre-fetched server public key
  --no-register                    Skip server peer registration
  --no-store                       Do not persist profile values
  -h, --help                       Show help

Profile file:
  ~/.config/netlab-wireguard/client.env
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

hash_password() {
  local value="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "${value}" | sha256sum | awk '{print $1}'
  else
    printf '%s' "${value}" | shasum -a 256 | awk '{print $1}'
  fi
}

prompt_secret() {
  local var_name="$1"
  local prompt_text="$2"
  local current_value="${!var_name:-}"
  if [[ -n "${current_value}" ]]; then
    return
  fi
  read -rsp "${prompt_text}: " input_value
  echo
  printf -v "${var_name}" '%s' "${input_value}"
}

prompt_profile_password() {
  local entered hash expected

  if [[ -z "${AUTH_HASH:-}" ]]; then
    read -rsp "Create profile password: " entered
    echo
    read -rsp "Confirm profile password: " confirm
    echo
    if [[ "${entered}" != "${confirm}" ]]; then
      echo "Profile password confirmation does not match." >&2
      exit 1
    fi
    AUTH_HASH="$(hash_password "${entered}")"
    return
  fi

  if [[ -n "${PROFILE_PASSWORD:-}" ]]; then
    entered="${PROFILE_PASSWORD}"
  else
    read -rsp "Profile password: " entered
    echo
  fi

  expected="${AUTH_HASH}"
  hash="$(hash_password "${entered}")"
  if [[ "${hash}" != "${expected}" ]]; then
    echo "Invalid profile password." >&2
    exit 1
  fi
}

save_profile() {
  mkdir -p "${PROFILE_DIR}"
  chmod 700 "${PROFILE_DIR}"
  cat > "${PROFILE_FILE}" <<EOF
AUTH_HASH=${AUTH_HASH}
CLIENT_NAME=${CLIENT_NAME}
SERVER_ENDPOINT=${SERVER_ENDPOINT}
SERVER_SSH=${SERVER_SSH}
CLIENT_ADDRESS=${CLIENT_ADDRESS}
DNS_IP=${DNS_IP}
ALLOWED_IPS=${ALLOWED_IPS}
WG_IFACE=${WG_IFACE}
SERVER_CONFIG_PATH=${SERVER_CONFIG_PATH}
LOCAL_SUDO_PASSWORD=${LOCAL_SUDO_PASSWORD}
SERVER_SUDO_PASSWORD=${SERVER_SUDO_PASSWORD}
EOF
  chmod 600 "${PROFILE_FILE}"
}

sudo_run_local() {
  if [[ -n "${LOCAL_SUDO_PASSWORD:-}" ]]; then
    echo "${LOCAL_SUDO_PASSWORD}" | sudo -S "$@"
  else
    sudo "$@"
  fi
}

ensure_client_tools() {
  local missing=()
  command -v wg >/dev/null 2>&1 || missing+=(wireguard-tools)
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v ssh >/dev/null 2>&1 || missing+=(openssh-client)
  command -v scp >/dev/null 2>&1 || missing+=(openssh-client)

  if [[ ${#missing[@]} -eq 0 ]]; then
    return
  fi

  if command -v apt-get >/dev/null 2>&1; then
    sudo_run_local apt-get update -y >/dev/null
    sudo_run_local apt-get install -y "${missing[@]}" >/dev/null
  fi
}

load_profile() {
  if [[ -f "${PROFILE_FILE}" ]]; then
    set -a
    source "${PROFILE_FILE}"
    set +a
  fi
}

CLIENT_NAME="${CLIENT_NAME:-}"
SERVER_ENDPOINT="${SERVER_ENDPOINT:-}"
SERVER_SSH="${SERVER_SSH:-}"
CLIENT_ADDRESS="${CLIENT_ADDRESS:-10.0.0.20/24}"
DNS_IP="${DNS_IP:-10.0.0.1}"
ALLOWED_IPS="${ALLOWED_IPS:-10.0.0.0/24}"
WG_IFACE="${WG_IFACE:-wg0}"
SERVER_CONFIG_PATH="${SERVER_CONFIG_PATH:-/etc/wireguard/wg0.conf}"
SERVER_PUBLIC_KEY="${SERVER_PUBLIC_KEY:-}"
LOCAL_SUDO_PASSWORD="${LOCAL_SUDO_PASSWORD:-}"
SERVER_SUDO_PASSWORD="${SERVER_SUDO_PASSWORD:-${SUDO_PASSWORD:-}}"
AUTH_HASH="${AUTH_HASH:-}"
NO_REGISTER="false"
NO_STORE="false"

load_profile

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client-name) CLIENT_NAME="$2"; shift 2 ;;
    --server-endpoint) SERVER_ENDPOINT="$2"; shift 2 ;;
    --server-ssh) SERVER_SSH="$2"; shift 2 ;;
    --client-address) CLIENT_ADDRESS="$2"; shift 2 ;;
    --dns) DNS_IP="$2"; shift 2 ;;
    --allowed-ips) ALLOWED_IPS="$2"; shift 2 ;;
    --interface) WG_IFACE="$2"; shift 2 ;;
    --server-config-path) SERVER_CONFIG_PATH="$2"; shift 2 ;;
    --server-public-key) SERVER_PUBLIC_KEY="$2"; shift 2 ;;
    --no-register) NO_REGISTER="true"; shift ;;
    --no-store) NO_STORE="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "${CLIENT_NAME}" ]]; then
  CLIENT_NAME="$(hostname -s 2>/dev/null || echo client-1)"
fi

[[ -n "${SERVER_ENDPOINT}" ]] || { echo "--server-endpoint is required" >&2; exit 1; }
if [[ "${NO_REGISTER}" != "true" ]] && [[ -z "${SERVER_SSH}" ]]; then
  echo "--server-ssh is required unless --no-register is used" >&2
  exit 1
fi

prompt_profile_password
prompt_secret LOCAL_SUDO_PASSWORD "Local sudo password"
if [[ "${NO_REGISTER}" != "true" ]]; then
  prompt_secret SERVER_SUDO_PASSWORD "Server sudo password"
fi

ensure_client_tools
require_cmd wg
require_cmd install
require_cmd systemctl
require_cmd ssh
require_cmd scp
require_cmd curl

if [[ "${NO_STORE}" != "true" ]]; then
  save_profile
fi

WORK_DIR="/tmp/netlab-client-${CLIENT_NAME}"
mkdir -p "$WORK_DIR"
chmod 700 "$WORK_DIR"

CLIENT_PRIVATE_KEY_PATH="$WORK_DIR/${CLIENT_NAME}.key"
CLIENT_PUBLIC_KEY_PATH="$WORK_DIR/${CLIENT_NAME}.pub"
CLIENT_CONF_PATH="$WORK_DIR/${WG_IFACE}.conf"

if [[ ! -f "$CLIENT_PRIVATE_KEY_PATH" ]]; then
  wg genkey | tee "$CLIENT_PRIVATE_KEY_PATH" | wg pubkey > "$CLIENT_PUBLIC_KEY_PATH"
  chmod 600 "$CLIENT_PRIVATE_KEY_PATH" "$CLIENT_PUBLIC_KEY_PATH"
fi

CLIENT_PRIVATE_KEY="$(cat "$CLIENT_PRIVATE_KEY_PATH")"
CLIENT_PUBLIC_KEY="$(cat "$CLIENT_PUBLIC_KEY_PATH")"

if [[ -z "${SERVER_PUBLIC_KEY}" ]]; then
  SERVER_PUBLIC_KEY="$(ssh "$SERVER_SSH" "echo '${SERVER_SUDO_PASSWORD}' | sudo -S sh -c 'cat /etc/wireguard/server_private.key | wg pubkey'")"
fi

if [[ "${NO_REGISTER}" != "true" ]]; then
  TMP_PEER_FILE="$WORK_DIR/${CLIENT_NAME}.peer"
  cat > "$TMP_PEER_FILE" <<EOF

[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = ${CLIENT_ADDRESS%/*}/32
EOF
  chmod 600 "$TMP_PEER_FILE"
  scp "$TMP_PEER_FILE" "${SERVER_SSH}:/tmp/${CLIENT_NAME}.peer"
  ssh "$SERVER_SSH" "echo '${SERVER_SUDO_PASSWORD}' | sudo -S bash -lc 'grep -q \"${CLIENT_PUBLIC_KEY}\" ${SERVER_CONFIG_PATH} || cat /tmp/${CLIENT_NAME}.peer >> ${SERVER_CONFIG_PATH}; systemctl restart wg-quick@${WG_IFACE}; rm -f /tmp/${CLIENT_NAME}.peer'"
fi

cat > "$CLIENT_CONF_PATH" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${CLIENT_ADDRESS}
DNS = ${DNS_IP}

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
Endpoint = ${SERVER_ENDPOINT}
AllowedIPs = ${ALLOWED_IPS}
PersistentKeepalive = 25
EOF
chmod 600 "$CLIENT_CONF_PATH"

sudo_run_local install -m 600 "$CLIENT_CONF_PATH" "/etc/wireguard/${WG_IFACE}.conf"
sudo_run_local systemctl enable --now "wg-quick@${WG_IFACE}"

if ! ip route | grep -q "${ALLOWED_IPS%%,*}.*${WG_IFACE}"; then
  echo "Route for ${ALLOWED_IPS} not found on ${WG_IFACE}." >&2
  exit 1
fi

RESOLVED_IP=""
if command -v dig >/dev/null 2>&1; then
  RESOLVED_IP="$(dig +short service1.intranet.local @"${DNS_IP}" | awk '/^([0-9]{1,3}\.){3}[0-9]{1,3}$/ {print; exit}')"
fi
if [[ -z "${RESOLVED_IP}" ]]; then
  RESOLVED_IP="${DNS_IP}"
fi

sudo_run_local sh -c "grep -q 'service1.intranet.local' /etc/hosts || echo '${RESOLVED_IP} service1.intranet.local' >> /etc/hosts"

curl -sS --fail -H "Host: service1.intranet.local" "http://${RESOLVED_IP}" >/dev/null

echo "VPN is connected and intranet access is working."
echo "Open in browser: http://service1.intranet.local"
