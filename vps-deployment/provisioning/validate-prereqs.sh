#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

MANIFEST_PATH="${1:-}"

if [[ -z "${MANIFEST_PATH}" ]]; then
    log_error "Usage: ./validate-prereqs.sh /path/to/manifest.env"
    exit 1
fi

load_manifest "${MANIFEST_PATH}"
require_commands awk grep sed ss df curl openssl
ensure_linux_ubuntu

MIN_DISK_GB="${MIN_DISK_GB:-20}"
SSH_PORT="${SSH_PORT:-22}"
DOMAIN="${DOMAIN:-${DOMAIN_PRODUCTION:-}}"
DB_MODE="${DB_MODE:-local}"
DB_HOST="${DB_HOST:-}"
DB_LOCAL_HOST_FALLBACK="${DB_LOCAL_HOST_FALLBACK:-172.17.0.1}"

log_info "Verificando variáveis obrigatórias no manifest"
required_manifest_vars=(
    PROJECT_NAME
    DEPLOY_USER
    GHCR_REPO
)

for var_name in "${required_manifest_vars[@]}"; do
    if [[ -z "${!var_name:-}" ]]; then
        log_error "Variável obrigatória ausente no manifest: ${var_name}"
        exit 1
    fi
done

if [[ -z "${DOMAIN}" ]]; then
    log_error "Domínio não definido — precisa de DOMAIN no manifest."
    exit 1
fi

if [[ "${DB_MODE}" == "local" ]]; then
    is_allowed_local_db_host() {
        local host="$1"
        [[ "${host}" == "host.docker.internal" || "${host}" == "${DB_LOCAL_HOST_FALLBACK}" ]]
    }

    if ! is_allowed_local_db_host "${DB_HOST}"; then
        log_error "DB_MODE=local exige DB_HOST=host.docker.internal ou ${DB_LOCAL_HOST_FALLBACK}. Valor atual: '${DB_HOST:-<vazio>}'"
        exit 1
    fi
fi

log_info "Verificando espaço em disco — mínimo ${MIN_DISK_GB}GB necessários"
available_kb=$(df --output=avail / | tail -n1 | awk '{print $1}')
required_kb=$((MIN_DISK_GB * 1024 * 1024))
if (( available_kb < required_kb )); then
    log_error "Espaço insuficiente no disco raiz. São necessários pelo menos ${MIN_DISK_GB}GB."
    exit 1
fi
log_success "Espaço em disco OK"

if ss -tuln | grep -q ':80 '; then
    log_warn "Porta 80 em uso — certifique-se que isso é esperado antes de subir o Traefik."
fi

if ss -tuln | grep -q ':443 '; then
    log_warn "Porta 443 em uso — certifique-se que isso é esperado antes de subir o Traefik."
fi

if ! ss -tuln | grep -q ":${SSH_PORT} "; then
    log_warn "SSH não está escutando na porta ${SSH_PORT} — verifique se o acesso remoto está ok."
fi

log_info "Testando acesso ao GitHub Container Registry (ghcr.io)"
if ! curl -fsSL https://ghcr.io >/dev/null 2>&1; then
    log_warn "Não foi possível alcançar ghcr.io — o pull da imagem pode falhar depois."
else
    log_success "Acesso ao GHCR confirmado"
fi

log_success "Pré-requisitos validados — tudo certo pra continuar"
