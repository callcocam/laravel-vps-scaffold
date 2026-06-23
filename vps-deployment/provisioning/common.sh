#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "This script must run as root."
        exit 1
    fi
}

require_commands() {
    local missing=0
    for cmd in "$@"; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            log_error "Missing required command: ${cmd}"
            missing=1
        fi
    done

    if [[ "${missing}" -ne 0 ]]; then
        exit 1
    fi
}

random_secret() {
    openssl rand -base64 48 | tr -d '=+/' | cut -c1-40
}

ensure_linux_ubuntu() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS (missing /etc/os-release)."
        exit 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
        log_warn "Expected Ubuntu, found: ${PRETTY_NAME:-unknown}."
    fi
}

write_file_secure() {
    local target_path="$1"
    local owner="$2"
    local perms="$3"
    local content="$4"

    umask 077
    printf '%s\n' "${content}" > "${target_path}"
    chown "${owner}" "${target_path}"
    chmod "${perms}" "${target_path}"
}

load_manifest() {
    local manifest_path="$1"

    if [[ ! -f "${manifest_path}" ]]; then
        log_error "Manifest not found: ${manifest_path}"
        exit 1
    fi

    # shellcheck disable=SC1090
    source "${manifest_path}"
}

# Encontra o manifest de production em <dir>.
# Usa manifest.production.env (ou manifest.${DEPLOY_ENV}.env se definido)
# Uso: MANIFEST_PATH="$(find_manifest /path/to/vps-deployment)" || exit 1
find_manifest() {
    local dir="${1:-$(pwd)}"
    local env="${DEPLOY_ENV:-production}"
    local path="${dir}/manifest.${env}.env"

    if [[ -f "${path}" ]]; then
        echo "${path}"
        return 0
    fi

    log_error "Manifest não encontrado: ${path}" >&2
    return 1
}
