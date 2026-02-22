#!/usr/bin/env bash
set -euo pipefail

PROFILE_DIR="${HOME}/.config/netlab-wireguard"
PROFILE_FILE="${PROFILE_DIR}/client.env"
AUTH_FAIL_MSG="Authentication failed: invalid user or password"

usage() {
  cat <<'EOF'
Usage:
  connect-client.sh --server-endpoint <ip:port> --server-ssh <user@host> [options]

Unix/Linux/macOS one-liner:
  curl -fsSL https://raw.githubusercontent.com/lcfranca/netlab-wireguard-coredns-basic/main/connect-client.sh | bash -s -- --server-endpoint 172.25.242.222:51820 --server-ssh subtilizer@172.25.242.222

Windows PowerShell one-liner (Git Bash required; no implicit WSL fallback):
  $u='https://raw.githubusercontent.com/lcfranca/netlab-wireguard-coredns-basic/main/connect-client.sh'; $a='--server-endpoint 172.25.242.222:51820 --server-ssh subtilizer@172.25.242.222'; $c=@("$env:ProgramFiles\\Git\\bin\\bash.exe","$env:ProgramFiles\\Git\\usr\\bin\\bash.exe","$env:ProgramW6432\\Git\\bin\\bash.exe","$env:ProgramW6432\\Git\\usr\\bin\\bash.exe"); $b=$c | Where-Object { Test-Path $_ } | Select-Object -First 1; if(-not $b){$g=Get-Command bash -ErrorAction SilentlyContinue; if($g -and $g.Source -and ($g.Source -match 'Git\\.*\\bash(\\.exe)?$')){$b=$g.Source}}; if(-not $b){ throw 'Git Bash not found. Install Git for Windows or run from WSL directly.' }; & $b -lc "curl -fsSL $u | bash -s -- $a"

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
  if [[ -r /proc/version ]]; then
    local proc_version
    proc_version="$(< /proc/version)"
    shopt -s nocasematch
    [[ "${proc_version}" == *microsoft* || "${proc_version}" == *wsl* ]]
    local is_wsl=$?
    shopt -u nocasematch
    return ${is_wsl}
  fi
  return 1
}

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    printf '%s\n' apt-get
    return 0
  fi
  if command -v dnf >/dev/null 2>&1; then
    printf '%s\n' dnf
    return 0
  fi
  if command -v yum >/dev/null 2>&1; then
    printf '%s\n' yum
    return 0
  fi
  if command -v pacman >/dev/null 2>&1; then
    printf '%s\n' pacman
    return 0
  fi
  return 1
}

run_with_sudo_if_needed() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
    return $?
  fi

  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
    return $?
  fi

  return 127
}

auto_install_dependencies() {
  local package_manager
  package_manager="$(detect_package_manager || true)"

  if [[ -z "${package_manager}" ]]; then
    return 2
  fi

  case "${package_manager}" in
    apt-get)
      run_with_sudo_if_needed apt-get update -y >/dev/null 2>&1 || return 3
      run_with_sudo_if_needed apt-get install -y openssh-client curl >/dev/null 2>&1 || return 3
      ;;
    dnf)
      run_with_sudo_if_needed dnf install -y openssh-clients curl >/dev/null 2>&1 || return 3
      ;;
    yum)
      run_with_sudo_if_needed yum install -y openssh-clients curl >/dev/null 2>&1 || return 3
      ;;
    pacman)
      run_with_sudo_if_needed pacman -Sy --noconfirm openssh curl >/dev/null 2>&1 || return 3
      ;;
    *)
      return 2
      ;;
  esac

  return 0
}

print_dependency_help() {
  echo "Unable to auto-install required commands: ssh scp curl" >&2
  if is_windows_shell; then
    echo "Git Bash/Windows detected. Ensure OpenSSH Client and curl are installed and available." >&2
    echo "PowerShell: Get-WindowsCapability -Online | findstr OpenSSH.Client" >&2
    echo "PowerShell (Admin): Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0" >&2
    return
  fi

  local package_manager
  package_manager="$(detect_package_manager || true)"
  case "${package_manager}" in
    apt-get)
      echo "Try: sudo apt-get update -y && sudo apt-get install -y openssh-client curl" >&2
      ;;
    dnf)
      echo "Try: sudo dnf install -y openssh-clients curl" >&2
      ;;
    yum)
      echo "Try: sudo yum install -y openssh-clients curl" >&2
      ;;
    pacman)
      echo "Try: sudo pacman -Sy --noconfirm openssh curl" >&2
      ;;
    *)
      echo "Install openssh client tools and curl using your distribution package manager." >&2
      ;;
  esac
}

resolve_cmd() {
  local cmd_name="$1"

  if command -v "${cmd_name}" >/dev/null 2>&1; then
    command -v "${cmd_name}"
    return 0
  fi

  local candidates=()
  if is_windows_shell; then
    case "${cmd_name}" in
      ssh|scp)
        candidates+=(
          "/c/Windows/System32/OpenSSH/${cmd_name}.exe"
          "/c/Windows/SysNative/OpenSSH/${cmd_name}.exe"
        )
        ;;
      curl)
        candidates+=(
          "/c/Windows/System32/curl.exe"
          "/c/Windows/SysNative/curl.exe"
        )
        ;;
    esac
  fi

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  if is_windows_shell && [[ -n "${WINDIR:-}" ]]; then
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
LOGIN_USER=""
LOGIN_PASSWORD=""

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
SSH_BASE_OPTS=("-o" "BatchMode=yes" "-o" "StrictHostKeyChecking=accept-new" "-o" "ConnectTimeout=10")
SCP_BASE_OPTS=("-o" "BatchMode=yes" "-o" "StrictHostKeyChecking=accept-new" "-o" "ConnectTimeout=10")

if [[ -z "${SSH_CMD}" || -z "${SCP_CMD}" || -z "${CURL_CMD}" ]]; then
  if ! is_windows_shell; then
    auto_install_dependencies || true
    SSH_CMD="$(resolve_cmd ssh || true)"
    SCP_CMD="$(resolve_cmd scp || true)"
    CURL_CMD="$(resolve_cmd curl || true)"
  fi

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
    print_dependency_help
    exit 1
  fi
fi

if [[ ! -r /dev/tty ]]; then
  echo "${AUTH_FAIL_MSG}" >&2
  exit 1
fi

read -rp "Login user: " LOGIN_USER < /dev/tty
read -rsp "Login password: " LOGIN_PASSWORD < /dev/tty
echo > /dev/tty

LOGIN_USER="$(printf '%s' "${LOGIN_USER}" | tr -d '\r\n')"
LOGIN_PASSWORD="$(printf '%s' "${LOGIN_PASSWORD}" | tr -d '\r\n')"

if [[ -z "${LOGIN_USER}" || -z "${LOGIN_PASSWORD}" ]]; then
  echo "${AUTH_FAIL_MSG}" >&2
  exit 1
fi

AUTH_CMD="sudo -n /opt/netlab/auth/validate_user.sh --stdin"
set +e
AUTH_OUTPUT="$(printf '%s\n%s\n' "${LOGIN_USER}" "${LOGIN_PASSWORD}" | "${SSH_CMD}" "${SSH_BASE_OPTS[@]}" "${SERVER_SSH}" "${AUTH_CMD}" 2>/dev/null)"
AUTH_STATUS=$?
set -e

if [[ ${AUTH_STATUS} -ne 0 ]]; then
  ENTERED_HASH="$(hash_password "${LOGIN_PASSWORD}")"
  AUTH_CMD_COMPAT="sudo -n /opt/netlab/auth/validate_user.sh --username $(printf '%q' "${LOGIN_USER}") --password-hash $(printf '%q' "${ENTERED_HASH}")"
  set +e
  AUTH_OUTPUT="$("${SSH_CMD}" "${SSH_BASE_OPTS[@]}" "${SERVER_SSH}" "${AUTH_CMD_COMPAT}" 2>/dev/null)"
  AUTH_STATUS=$?
  set -e
fi

if [[ ${AUTH_STATUS} -ne 0 ]]; then
  if [[ "${NETLAB_AUTH_DEBUG:-0}" == "1" ]]; then
    echo "[debug] auth_status=${AUTH_STATUS}" >&2
    [[ -n "${AUTH_OUTPUT}" ]] && echo "[debug] auth_output=${AUTH_OUTPUT}" >&2
    echo "[debug] ssh_cmd=${SSH_CMD}" >&2
    echo "[debug] server_ssh=${SERVER_SSH}" >&2
    echo "[debug] server_endpoint=${SERVER_ENDPOINT}" >&2
    PROBE_CMD='echo auth_probe_ok'
    set +e
    PROBE_OUT="$("${SSH_CMD}" "${SSH_BASE_OPTS[@]}" "${SERVER_SSH}" "${PROBE_CMD}" 2>&1)"
    PROBE_STATUS=$?
    set -e
    echo "[debug] ssh_probe_status=${PROBE_STATUS}" >&2
    [[ -n "${PROBE_OUT}" ]] && echo "[debug] ssh_probe_output=${PROBE_OUT}" >&2
    DIAG_CMD='if sudo -n /opt/netlab/auth/validate_user.sh --stdin </dev/null >/dev/null 2>&1; then echo validator_access=ok; else echo validator_access=denied; fi; if [ -f /opt/netlab/auth/users.yml ]; then echo users_yml=present; else echo users_yml=missing; fi; if [ -f /opt/netlab/auth/auth.log ]; then echo auth_log=present; else echo auth_log=missing; fi'
    DIAG_OUT="$("${SSH_CMD}" "${SSH_BASE_OPTS[@]}" "${SERVER_SSH}" "${DIAG_CMD}" 2>/dev/null || true)"
    [[ -n "${DIAG_OUT}" ]] && echo "[debug] ${DIAG_OUT}" >&2
  fi
  echo "${AUTH_FAIL_MSG}" >&2
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

"${SCP_CMD}" "${SCP_BASE_OPTS[@]}" "${SERVER_SSH}:/opt/netlab/wg-clients/${CLIENT_PROFILE_NAME}.conf" "${CLIENT_CONF_PATH}" >/dev/null
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
