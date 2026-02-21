#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ANSIBLE_DIR="$ROOT_DIR/infra/ansible"
INVENTORY_FILE="${1:-$ANSIBLE_DIR/generated/inventory.ini}"

if [[ -f "$ROOT_DIR/.env" ]]; then
  set -a
  source "$ROOT_DIR/.env"
  set +a
fi

if [[ ! -f "$INVENTORY_FILE" ]]; then
  echo "Inventory not found: $INVENTORY_FILE"
  echo "Run 'make infra' first or pass a custom inventory path."
  exit 1
fi

"$ROOT_DIR/infra/scripts/preflight-ssh.sh" "$INVENTORY_FILE" wireguard_server

ANSIBLE_EXTRA_ARGS=()
if [[ -n "${SUDO_PASSWORD:-}" ]]; then
  ANSIBLE_EXTRA_ARGS+=("-e" "ansible_become_pass=${SUDO_PASSWORD}")
fi

ansible-playbook -i "$INVENTORY_FILE" "${ANSIBLE_EXTRA_ARGS[@]}" "$ANSIBLE_DIR/docker.yml"
