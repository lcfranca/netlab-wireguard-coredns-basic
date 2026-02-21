#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_SCRIPT="$(cd "${SCRIPT_DIR}/../.." && pwd)/connect-client.sh"
exec "${ROOT_SCRIPT}" "$@"