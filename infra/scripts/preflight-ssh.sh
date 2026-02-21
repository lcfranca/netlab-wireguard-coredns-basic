#!/usr/bin/env bash
set -euo pipefail

INVENTORY_FILE="${1:-}"
GROUP_NAME="${2:-wireguard_server}"

if [[ -z "${INVENTORY_FILE}" || ! -f "${INVENTORY_FILE}" ]]; then
  echo "Inventory file missing: ${INVENTORY_FILE}" >&2
  exit 1
fi

host_line="$(awk -v grp="${GROUP_NAME}" '
  BEGIN { in_group=0 }
  /^[[:space:]]*;/ { next }
  /^\[/ {
    in_group = ($0 == "[" grp "]")
    next
  }
  in_group && NF > 0 { print; exit }
' "${INVENTORY_FILE}")"

if [[ -z "${host_line}" ]]; then
  echo "No host entries found for group [${GROUP_NAME}] in ${INVENTORY_FILE}" >&2
  exit 1
fi

ansible_host="$(sed -n 's/.*ansible_host=\([^[:space:]]*\).*/\1/p' <<<"${host_line}")"
ansible_user="$(sed -n 's/.*ansible_user=\([^[:space:]]*\).*/\1/p' <<<"${host_line}")"
ansible_port="$(sed -n 's/.*ansible_port=\([^[:space:]]*\).*/\1/p' <<<"${host_line}")"
ansible_key="$(sed -n 's/.*ansible_ssh_private_key_file=\([^[:space:]]*\).*/\1/p' <<<"${host_line}")"

ansible_port="${ansible_port:-22}"
ansible_user="${ansible_user:-ubuntu}"

if [[ -z "${ansible_host}" ]]; then
  echo "Inventory entry missing ansible_host in group [${GROUP_NAME}]" >&2
  exit 1
fi

if [[ "${ansible_host}" =~ ^203\.0\.113\.|^198\.51\.100\.|^192\.0\.2\. ]]; then
  echo "Inventory uses documentation placeholder IP (${ansible_host})." >&2
  echo "Set real host details in infra/terraform/terraform.tfvars and run: make infra" >&2
  exit 1
fi

ssh_args=(
  -o BatchMode=yes
  -o ConnectTimeout=7
  -o StrictHostKeyChecking=accept-new
  -p "${ansible_port}"
)

if [[ -n "${ansible_key}" ]]; then
  if [[ ! -f "${ansible_key}" ]]; then
    echo "SSH private key not found: ${ansible_key}" >&2
    exit 1
  fi
  ssh_args+=(-i "${ansible_key}")
fi

ssh_error_log="$(mktemp)"
if ! ssh "${ssh_args[@]}" "${ansible_user}@${ansible_host}" "echo ssh-ok" >/dev/null 2>"${ssh_error_log}"; then
  echo "SSH preflight failed for ${ansible_user}@${ansible_host}:${ansible_port}" >&2
  if grep -qi "Permission denied" "${ssh_error_log}"; then
    echo "Authentication failed: SSH user or private key is not authorized on target host." >&2
    echo "Fix ~/.ssh/authorized_keys on server or set correct server_ssh_user/server_ssh_private_key_file in infra/terraform/terraform.tfvars." >&2
  else
    echo "Verify host reachability, security-group/firewall rules, SSH user, and private key path." >&2
  fi
  rm -f "${ssh_error_log}"
  exit 1
fi
rm -f "${ssh_error_log}"

echo "SSH preflight passed for ${ansible_user}@${ansible_host}:${ansible_port}"
