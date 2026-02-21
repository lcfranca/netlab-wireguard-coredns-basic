#!/usr/bin/env bash
set -euo pipefail

MODE="install"
if [[ "${1:-}" == "--check" ]]; then
  MODE="check"
fi

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
BIN_DIR="${HOME}/.local/bin"
export PATH="${BIN_DIR}:${PATH}"

log() { echo "[deps] $*"; }
warn() { echo "[deps][warn] $*"; }
fail() { echo "[deps][error] $*"; exit 1; }

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

need_sudo() {
  if command_exists sudo && sudo -n true >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

ensure_bin_dir() {
  mkdir -p "${BIN_DIR}"
}

install_terraform_user() {
  local tf_version="1.10.5"
  local tf_os tf_arch tf_zip tf_url tmp_dir

  case "${OS}" in
    linux) tf_os="linux" ;;
    darwin) tf_os="darwin" ;;
    *) fail "Unsupported OS for Terraform install: ${OS}" ;;
  esac

  case "${ARCH}" in
    x86_64|amd64) tf_arch="amd64" ;;
    arm64|aarch64) tf_arch="arm64" ;;
    *) fail "Unsupported architecture for Terraform install: ${ARCH}" ;;
  esac

  tf_zip="terraform_${tf_version}_${tf_os}_${tf_arch}.zip"
  tf_url="https://releases.hashicorp.com/terraform/${tf_version}/${tf_zip}"
  tmp_dir="$(mktemp -d)"

  log "Installing Terraform ${tf_version} to ${BIN_DIR}"
  curl -fsSL "${tf_url}" -o "${tmp_dir}/${tf_zip}"
  unzip -o "${tmp_dir}/${tf_zip}" -d "${tmp_dir}" >/dev/null
  install -m 0755 "${tmp_dir}/terraform" "${BIN_DIR}/terraform"
  rm -rf "${tmp_dir}"
}

install_ansible_user() {
  if ! command_exists python3; then
    fail "python3 is required to install ansible-core"
  fi

  if command_exists pipx; then
    log "Installing ansible-core with pipx"
    pipx install --force ansible-core
    return
  fi

  local venv_dir="${HOME}/.local/share/netlab/ansible-venv"
  log "Installing ansible-core into dedicated virtualenv: ${venv_dir}"

  if [[ ! -d "${venv_dir}" ]]; then
    python3 -m venv "${venv_dir}" || fail "Failed to create Python venv. Install python3-venv and retry."
  fi

  "${venv_dir}/bin/python" -m pip install --upgrade pip
  "${venv_dir}/bin/python" -m pip install --upgrade ansible-core

  ln -sf "${venv_dir}/bin/ansible" "${BIN_DIR}/ansible"
  ln -sf "${venv_dir}/bin/ansible-playbook" "${BIN_DIR}/ansible-playbook"
}

install_linux_system_deps() {
  if command_exists apt-get; then
    if need_sudo; then
      log "Installing Linux dependencies with apt"
      sudo apt-get update -y
      sudo apt-get install -y curl unzip make jq dnsutils wireguard-tools docker.io docker-compose-plugin
    else
      warn "Skipping apt installs (sudo without prompt not available)."
    fi
  elif command_exists dnf; then
    if need_sudo; then
      log "Installing Linux dependencies with dnf"
      sudo dnf install -y curl unzip make jq bind-utils wireguard-tools docker docker-compose-plugin
    else
      warn "Skipping dnf installs (sudo without prompt not available)."
    fi
  elif command_exists pacman; then
    if need_sudo; then
      log "Installing Linux dependencies with pacman"
      sudo pacman -Sy --noconfirm curl unzip make jq bind wireguard-tools docker docker-compose
    else
      warn "Skipping pacman installs (sudo without prompt not available)."
    fi
  else
    warn "No supported Linux package manager detected (apt/dnf/pacman)."
  fi
}

install_macos_deps() {
  if ! command_exists brew; then
    log "Installing Homebrew"
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ -x /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi
  fi

  log "Installing macOS dependencies with Homebrew"
  brew update
  brew install curl unzip make jq python terraform ansible docker docker-compose wireguard-tools
}

verify_dependency() {
  local bin="$1"
  local required="$2"
  if command_exists "${bin}"; then
    log "OK: ${bin}"
  elif [[ "${required}" == "yes" ]]; then
    fail "Missing required dependency: ${bin}"
  else
    warn "Missing optional dependency: ${bin}"
  fi
}

print_versions() {
  echo
  log "Installed tool versions:"
  command_exists terraform && terraform version | head -n 1 || true
  command_exists ansible-playbook && ansible-playbook --version | head -n 1 || true
  command_exists docker && docker --version || true
  command_exists curl && curl --version | head -n 1 || true
  command_exists dig && dig -v | head -n 1 || true
  command_exists wg && wg --version || true
}

main() {
  ensure_bin_dir

  if [[ "${MODE}" == "install" ]]; then
    log "Starting dependency installation for ${OS}/${ARCH}"

    case "${OS}" in
      linux)
        install_linux_system_deps
        ;;
      darwin)
        install_macos_deps
        ;;
      *)
        fail "Unsupported OS: ${OS}"
        ;;
    esac

    if ! command_exists terraform; then
      install_terraform_user
    fi

    if ! command_exists ansible-playbook; then
      install_ansible_user
    fi
  else
    log "Running dependency checks only"
  fi

  verify_dependency terraform yes
  verify_dependency ansible-playbook yes
  verify_dependency docker yes
  verify_dependency curl yes
  verify_dependency dig no
  verify_dependency wg no

  print_versions
  log "Dependency validation completed"
}

main "$@"
