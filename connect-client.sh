#!/usr/bin/env bash
set -euo pipefail

PROFILE_DIR="${HOME}/.config/netlab-wireguard"
PROFILE_FILE="${PROFILE_DIR}/client.env"

usage() {
  cat <<'EOF'
Usage:
  connect-client.sh --server-endpoint <ip:port> --server-ssh <user@host> [options]

Unix/Linux/macOS:
  curl -fsSL https://raw.githubusercontent.com/lcfranca/netlab-wireguard-coredns-basic/main/connect-client.sh | bash -s -- --server-endpoint 172.25.242.222:51820 --server-ssh subtilizer@172.25.242.222

Windows (PowerShell):
  Invoke-WebRequest -Uri "https://raw.githubusercontent.com/lcfranca/netlab-wireguard-coredns-basic/main/connect-client.sh" -OutFile "connect-client.sh"
  bash connect-client.sh --server-endpoint 172.25.242.222:51820 --server-ssh subtilizer@172.25.242.222

Options:
  --server-endpoint <ip:port>      WireGuard endpoint (required)
  --server-ssh <user@host>         SSH host for profile download (required)
  --interface <wg-if>              WireGuard interface (default: wg0)
  --help                           Show help

Authentication:
  Prompts for login user and password and validates against pre-registered users on server.
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

is_windows_shell() {
  case "$(uname -s 2>/dev/null || true)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

save_profile() {
  mkdir -p "${PROFILE_DIR}"
  chmod 700 "${PROFILE_DIR}"
  cat > "${PROFILE_FILE}" <<EOF
SERVER_ENDPOINT=${SERVER_ENDPOINT}
SERVER_SSH=${SERVER_SSH}
WG_IFACE=${WG_IFACE}
LAST_LOGIN_USER=${LOGIN_USER}
EOF
  chmod 600 "${PROFILE_FILE}"
}

load_profile() {
  if [[ -f "${PROFILE_FILE}" ]]; then
    set -a
    source "${PROFILE_FILE}"
    set +a
  fi
}

SERVER_ENDPOINT="${SERVER_ENDPOINT:-}"
SERVER_SSH="${SERVER_SSH:-}"
WG_IFACE="${WG_IFACE:-wg0}"
LOGIN_USER="${LOGIN_USER:-${LAST_LOGIN_USER:-}}"
LOGIN_PASSWORD="${LOGIN_PASSWORD:-}"

load_profile

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-endpoint) SERVER_ENDPOINT="$2"; shift 2 ;;
    --server-ssh) SERVER_SSH="$2"; shift 2 ;;
    --interface) WG_IFACE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "${SERVER_ENDPOINT}" ]] || { echo "--server-endpoint is required" >&2; exit 1; }
[[ -n "${SERVER_SSH}" ]] || { echo "--server-ssh is required" >&2; exit 1; }

require_cmd ssh
require_cmd scp
require_cmd curl

if [[ -z "${LOGIN_USER}" ]]; then
  read -rp "Login user: " LOGIN_USER
fi

if [[ -z "${LOGIN_PASSWORD}" ]]; then
  read -rsp "Login password: " LOGIN_PASSWORD
  echo
fi

USER_DB_CONTENT="$(ssh "${SERVER_SSH}" "cat /opt/netlab/auth/users.yml" 2>/dev/null || true)"
if [[ -z "${USER_DB_CONTENT}" ]]; then
  echo "Could not read server user database at /opt/netlab/auth/users.yml" >&2
  echo "Run make config on server first to generate pre-registered user profiles." >&2
  exit 1
fi

USER_LINE="$(printf '%s\n' "${USER_DB_CONTENT}" | awk -v u="${LOGIN_USER}" '
  /^[[:space:]]*-[[:space:]]+username:[[:space:]]*/ {
    user=$3
    gsub(/["'\''[:space:]]/, "", user)
    hash=""
    client=""
  }
  /^[[:space:]]*password_hash:[[:space:]]*/ {
    hash=$2
    gsub(/["'\''[:space:]]/, "", hash)
  }
  /^[[:space:]]*client_name:[[:space:]]*/ {
    client=$2
    gsub(/["'\''[:space:]]/, "", client)
    if (user == u && hash != "" && client != "") {
      print user ":" hash ":" client
      exit
    }
  }
')"
if [[ -z "${USER_LINE}" ]]; then
  echo "Authentication failed: unknown user '${LOGIN_USER}'" >&2
  exit 1
fi

STORED_HASH="$(printf '%s' "${USER_LINE}" | awk -F: '{print $2}')"
CLIENT_PROFILE_NAME="$(printf '%s' "${USER_LINE}" | awk -F: '{print $3}')"

if [[ -z "${STORED_HASH}" || -z "${CLIENT_PROFILE_NAME}" ]]; then
  echo "Invalid user database format on server." >&2
  exit 1
fi

ENTERED_HASH="$(hash_password "${LOGIN_PASSWORD}")"
if [[ "${ENTERED_HASH}" != "${STORED_HASH}" ]]; then
  echo "Authentication failed: invalid password." >&2
  exit 1
fi

WORK_DIR="${HOME}/.config/netlab-wireguard"
mkdir -p "${WORK_DIR}"
chmod 700 "${WORK_DIR}"
CLIENT_CONF_PATH="${WORK_DIR}/${WG_IFACE}.conf"

scp "${SERVER_SSH}:/opt/netlab/wg-clients/${CLIENT_PROFILE_NAME}.conf" "${CLIENT_CONF_PATH}" >/dev/null
chmod 600 "${CLIENT_CONF_PATH}"

save_profile

echo "Authenticated as ${LOGIN_USER}."

if ! command -v wg >/dev/null 2>&1; then
  if is_windows_shell; then
    cat <<EOF
WireGuard CLI (wg) is not installed in this shell.
Install WireGuard for Windows:
  https://www.wireguard.com/install/
Then import this config in WireGuard UI:
  ${CLIENT_CONF_PATH}
After activating the tunnel, open:
  http://service1.intranet.local
EOF
    exit 0
  fi

  echo "Missing required command: wg" >&2
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  if sudo -n true >/dev/null 2>&1; then
    sudo install -m 600 "${CLIENT_CONF_PATH}" "/etc/wireguard/${WG_IFACE}.conf"
    sudo systemctl enable --now "wg-quick@${WG_IFACE}"
  else
    echo "Root privileges are required to bring up WireGuard on this system." >&2
    echo "Run as root/sudo or activate ${CLIENT_CONF_PATH} via your WireGuard client." >&2
    exit 1
  fi
else
  install -m 600 "${CLIENT_CONF_PATH}" "/etc/wireguard/${WG_IFACE}.conf"
  systemctl enable --now "wg-quick@${WG_IFACE}"
fi

curl -sS --fail "http://service1.intranet.local" >/dev/null

echo "VPN is connected and intranet access is working."
echo "Open in browser: http://service1.intranet.local"
