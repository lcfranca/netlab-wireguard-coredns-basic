#!/usr/bin/env bash
set -euo pipefail

PROFILE_DIR="${HOME}/.config/netlab-wireguard"
PROFILE_FILE="${PROFILE_DIR}/client.env"

usage() {
  cat <<'EOF'
Usage:
  connect-client.sh --server-endpoint <ip:port> --server-ssh <user@host> [options]

Unix/Linux/macOS one-liner:
  curl -fsSL https://raw.githubusercontent.com/lcfranca/netlab-wireguard-coredns-basic/main/connect-client.sh | bash -s -- --server-endpoint 172.25.242.222:51820 --server-ssh subtilizer@172.25.242.222

Windows PowerShell one-liner (auto-detects Git Bash/WSL):
  $u='https://raw.githubusercontent.com/lcfranca/netlab-wireguard-coredns-basic/main/connect-client.sh'; $a='--server-endpoint 172.25.242.222:51820 --server-ssh subtilizer@172.25.242.222'; $b=(Get-Command bash -ErrorAction SilentlyContinue).Source; if(-not $b){$c=@("$env:ProgramFiles\\Git\\bin\\bash.exe","$env:ProgramFiles\\Git\\usr\\bin\\bash.exe","$env:ProgramW6432\\Git\\bin\\bash.exe","$env:ProgramW6432\\Git\\usr\\bin\\bash.exe"); $b=$c | Where-Object { Test-Path $_ } | Select-Object -First 1}; if($b){ & $b -lc "curl -fsSL $u | bash -s -- $a" } elseif(Get-Command wsl -ErrorAction SilentlyContinue){ wsl bash -lc "curl -fsSL $u | bash -s -- $a" } else { throw 'Bash runtime not found. Install Git for Windows or WSL.' }

Options:
  --server-endpoint <ip:port>      WireGuard endpoint (required)
  --server-ssh <user@host>         SSH host for profile download (required)
  --interface <wg-if>              WireGuard interface (default: wg0)
  --help                           Show help

Authentication:
  Prompts for login user and password and validates against pre-registered users on server.
EOF
}

is_windows_shell() {
  case "$(uname -s 2>/dev/null || true)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

is_wsl_shell() {
  [[ -f /proc/version ]] && grep -qiE 'microsoft|wsl' /proc/version
}

resolve_cmd() {
  local cmd_name="$1"

  if command -v "${cmd_name}" >/dev/null 2>&1; then
    command -v "${cmd_name}"
    return 0
  fi

  local candidates=()
  case "${cmd_name}" in
    ssh|scp)
      candidates+=(
        "/c/Windows/System32/OpenSSH/${cmd_name}.exe"
        "/c/Windows/SysNative/OpenSSH/${cmd_name}.exe"
        "/mnt/c/Windows/System32/OpenSSH/${cmd_name}.exe"
        "/mnt/c/Windows/Sysnative/OpenSSH/${cmd_name}.exe"
      )
      ;;
    curl)
      candidates+=(
        "/c/Windows/System32/curl.exe"
        "/c/Windows/SysNative/curl.exe"
        "/mnt/c/Windows/System32/curl.exe"
        "/mnt/c/Windows/Sysnative/curl.exe"
      )
      ;;
  esac

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  if [[ -n "${WINDIR:-}" ]]; then
    case "${cmd_name}" in
      ssh|scp)
        candidate="${WINDIR}\\System32\\OpenSSH\\${cmd_name}.exe"
        ;;
      curl)
        candidate="${WINDIR}\\System32\\curl.exe"
        ;;
      *)
        candidate=""
        ;;
    esac
    if [[ -n "${candidate}" && -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  fi

  return 1
}

hash_password() {
  local value="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "${value}" | sha256sum | awk '{print $1}'
  else
    printf '%s' "${value}" | shasum -a 256 | awk '{print $1}'
  fi
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
    --server-endpoint)
      SERVER_ENDPOINT="$2"
      shift 2
      ;;
    --server-ssh)
      SERVER_SSH="$2"
      shift 2
      ;;
    --interface)
      WG_IFACE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

[[ -n "${SERVER_ENDPOINT}" ]] || { echo "--server-endpoint is required" >&2; exit 1; }
[[ -n "${SERVER_SSH}" ]] || { echo "--server-ssh is required" >&2; exit 1; }

SSH_CMD="$(resolve_cmd ssh || true)"
SCP_CMD="$(resolve_cmd scp || true)"
CURL_CMD="$(resolve_cmd curl || true)"

if [[ -z "${SSH_CMD}" || -z "${SCP_CMD}" || -z "${CURL_CMD}" ]]; then
  [[ -n "${SSH_CMD}" ]] || echo "Missing required command: ssh" >&2
  [[ -n "${SCP_CMD}" ]] || echo "Missing required command: scp" >&2
  [[ -n "${CURL_CMD}" ]] || echo "Missing required command: curl" >&2
  echo "Shell: $(uname -s 2>/dev/null || echo unknown)" >&2
  if is_windows_shell; then
    echo "Detected Git Bash/MSYS/Cygwin shell." >&2
  fi
  if is_wsl_shell; then
    echo "Detected WSL shell." >&2
  fi
  echo "If on Windows, ensure OpenSSH Client is installed and accessible." >&2
  exit 1
fi

if [[ -z "${LOGIN_USER}" ]]; then
  read -rp "Login user: " LOGIN_USER
fi

if [[ -z "${LOGIN_PASSWORD}" ]]; then
  read -rsp "Login password: " LOGIN_PASSWORD
  echo
fi

ENTERED_HASH="$(hash_password "${LOGIN_PASSWORD}")"

AUTH_CMD="sudo -n /opt/netlab/auth/validate_user.sh --username $(printf '%q' "${LOGIN_USER}") --password-hash $(printf '%q' "${ENTERED_HASH}")"
set +e
AUTH_OUTPUT="$(${SSH_CMD} "${SERVER_SSH}" "${AUTH_CMD}" 2>/dev/null)"
AUTH_STATUS=$?
set -e

if [[ ${AUTH_STATUS} -ne 0 ]]; then
  if [[ "${AUTH_OUTPUT}" == "SETUP_REQUIRED" ]]; then
    echo "Server-side user database is not initialized. Run make config on server first." >&2
    exit 1
  fi
  echo "Authentication failed: invalid user or password." >&2
  exit 1
fi

CLIENT_PROFILE_NAME="${AUTH_OUTPUT##*$'\n'}"
if [[ -z "${CLIENT_PROFILE_NAME}" ]]; then
  echo "Authentication failed: invalid server auth response." >&2
  exit 1
fi

WORK_DIR="${HOME}/.config/netlab-wireguard"
mkdir -p "${WORK_DIR}"
chmod 700 "${WORK_DIR}"
CLIENT_CONF_PATH="${WORK_DIR}/${WG_IFACE}.conf"

${SCP_CMD} "${SERVER_SSH}:/opt/netlab/wg-clients/${CLIENT_PROFILE_NAME}.conf" "${CLIENT_CONF_PATH}" >/dev/null
chmod 600 "${CLIENT_CONF_PATH}"

save_profile

echo "Authenticated as ${LOGIN_USER}."

if ! command -v wg >/dev/null 2>&1; then
  if is_windows_shell || is_wsl_shell; then
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

${CURL_CMD} -sS --fail "http://service1.intranet.local" >/dev/null

echo "VPN is connected and intranet access is working."
echo "Open in browser: http://service1.intranet.local"
