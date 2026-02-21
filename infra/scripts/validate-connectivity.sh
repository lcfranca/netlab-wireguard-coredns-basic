#!/usr/bin/env bash
set -euo pipefail

INVENTORY_FILE="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ansible/generated/inventory.ini}"
SERVER_DNS="${2:-10.0.0.1}"
SERVICE_HOSTNAME="${3:-service1.intranet.local}"

if [[ ! -f "${INVENTORY_FILE}" ]]; then
	echo "Inventory not found: ${INVENTORY_FILE}" >&2
	exit 1
fi

host_line="$(awk '
	BEGIN { in_group=0 }
	/^[[:space:]]*;/ { next }
	/^\[/ {
		in_group = ($0 == "[wireguard_server]")
		next
	}
	in_group && NF > 0 { print; exit }
' "${INVENTORY_FILE}")"

if [[ -z "${host_line}" ]]; then
	echo "No server host entry found in ${INVENTORY_FILE}" >&2
	exit 1
fi

ansible_host="$(sed -n 's/.*ansible_host=\([^[:space:]]*\).*/\1/p' <<<"${host_line}")"
ansible_user="$(sed -n 's/.*ansible_user=\([^[:space:]]*\).*/\1/p' <<<"${host_line}")"
ansible_port="$(sed -n 's/.*ansible_port=\([^[:space:]]*\).*/\1/p' <<<"${host_line}")"
ansible_key="$(sed -n 's/.*ansible_ssh_private_key_file=\([^[:space:]]*\).*/\1/p' <<<"${host_line}")"

ansible_user="${ansible_user:-ubuntu}"
ansible_port="${ansible_port:-22}"

ssh_args=(
	-o BatchMode=yes
	-o ConnectTimeout=8
	-o StrictHostKeyChecking=accept-new
	-p "${ansible_port}"
)

if [[ -n "${ansible_key}" ]]; then
	ssh_args+=(-i "${ansible_key}")
fi

echo "[1/4] Running server-side DNS validation"
RESOLVED_IP="$(ssh "${ssh_args[@]}" "${ansible_user}@${ansible_host}" \
	"dig +short ${SERVICE_HOSTNAME} @${SERVER_DNS} 2>/dev/null | awk '/^([0-9]{1,3}\\.){3}[0-9]{1,3}$/ {print; exit}'")"

if [[ -z "${RESOLVED_IP}" ]]; then
	echo "DNS lookup failed for ${SERVICE_HOSTNAME} on server ${ansible_host}" >&2
	exit 1
fi

echo "Resolved ${SERVICE_HOSTNAME} -> ${RESOLVED_IP}"

echo "[2/4] Validating HTTP over private/VPN path"
ssh "${ssh_args[@]}" "${ansible_user}@${ansible_host}" \
	"curl -sS --fail -H 'Host: ${SERVICE_HOSTNAME}' http://${SERVER_DNS} >/dev/null"

echo "[3/4] Validating service bind address is private-only"
if ssh "${ssh_args[@]}" "${ansible_user}@${ansible_host}" "ss -ltn '( sport = :80 )' | grep -qE '0\\.0\\.0\\.0:80|\\[::\\]:80'"; then
	echo "Service is exposed on all interfaces (0.0.0.0/::), expected private bind only." >&2
	exit 1
fi

echo "[4/4] Validating public host path is rejected"
if ssh "${ssh_args[@]}" "${ansible_user}@${ansible_host}" \
	"curl -s --connect-timeout 3 --max-time 5 -H 'Host: ${SERVICE_HOSTNAME}' http://${ansible_host} >/dev/null 2>&1"; then
	echo "Public host path is reachable at http://${ansible_host}, expected rejection." >&2
	exit 1
fi

echo "Public host path is blocked as expected."

echo "Connectivity checks completed: DNS resolves and HTTP is private-path only."
