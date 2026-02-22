#!/usr/bin/env bash
set -euo pipefail

SERVER_SSH=""
CLIENT_NAME=""
INTERFACE="wg0"
REMOTE_DIR="/opt/netlab/wg-clients"
OUTPUT_DIR="${HOME}/.config/netlab-wireguard"

usage() {
  cat <<'EOF'
Usage:
  fetch-wireguard-conf.sh --server-ssh <user@host> --client-name <name> [options]

Options:
  --server-ssh <user@host>      SSH host used to fetch profile (required)
  --client-name <name>          Profile basename on server (required)
  --interface <wg-if>           Local output filename base (default: wg0)
  --remote-dir <path>           Remote directory (default: /opt/netlab/wg-clients)
  --output-dir <path>           Local output directory (default: ~/.config/netlab-wireguard)
  -h, --help                    Show help

Example:
  curl -fsSL https://raw.githubusercontent.com/lcfranca/netlab-wireguard-coredns-basic/main/fetch-wireguard-conf.sh | \
    bash -s -- --server-ssh subtilizer@172.25.242.222 --client-name demo-client --interface wg0
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-ssh)
      SERVER_SSH="${2:-}"
      shift 2
      ;;
    --client-name)
      CLIENT_NAME="${2:-}"
      shift 2
      ;;
    --interface)
      INTERFACE="${2:-}"
      shift 2
      ;;
    --remote-dir)
      REMOTE_DIR="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
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

[[ -n "${SERVER_SSH}" ]] || { echo "--server-ssh is required" >&2; exit 1; }
[[ -n "${CLIENT_NAME}" ]] || { echo "--client-name is required" >&2; exit 1; }

if ! command -v scp >/dev/null 2>&1; then
  echo "Missing required command: scp" >&2
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"
chmod 700 "${OUTPUT_DIR}"

OUTPUT_FILE="${OUTPUT_DIR}/${INTERFACE}.conf"
REMOTE_FILE="${SERVER_SSH}:${REMOTE_DIR%/}/${CLIENT_NAME}.conf"

echo "Downloading profile '${CLIENT_NAME}' from ${SERVER_SSH} ..."
scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
  "${REMOTE_FILE}" "${OUTPUT_FILE}"
chmod 600 "${OUTPUT_FILE}"

echo "Saved: ${OUTPUT_FILE}"
echo "Import this file into your WireGuard client and activate the tunnel."
