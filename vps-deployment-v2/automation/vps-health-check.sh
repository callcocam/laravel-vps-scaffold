#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../provisioning/common.sh"

MANIFEST_PATH="${1:-}"
APP_SLUG="${APP_SLUG:-${2:-production}}"

if [[ -z "${MANIFEST_PATH}" ]]; then
    if ! MANIFEST_PATH="$(find_manifest "${SCRIPT_DIR}/..")"; then
        log_error "Nenhum manifest encontrado. Passe: ./vps-health-check.sh /path/to/manifest.env"
        exit 1
    fi
    log_info "Usando manifest: ${MANIFEST_PATH}"
fi

load_manifest "${MANIFEST_PATH}"
require_commands docker curl df free awk grep date

DOMAIN="${DOMAIN:-${DOMAIN_PRODUCTION:-}}"

fail_count=0
warn_count=0
ok() { echo "[OK] $*"; }
warn() { echo "[WARN] $*"; warn_count=$((warn_count + 1)); }
fail() { echo "[FAIL] $*"; fail_count=$((fail_count + 1)); }

check_compose_service_running() {
    local compose_dir="$1"
    local service_name="$2"

    if [[ ! -f "${compose_dir}/docker-compose.yml" ]]; then
        fail "Missing compose file in ${compose_dir}"
        return
    fi

    if docker compose -f "${compose_dir}/docker-compose.yml" ps --status running --services | grep -q "^${service_name}$"; then
        ok "${compose_dir} service ${service_name} is running"
    else
        fail "${compose_dir} service ${service_name} is not running"
    fi
}

check_http() {
    local url="$1"
    local label="$2"

    if curl -fsS --max-time 8 "${url}" >/dev/null; then
        ok "${label} reachable (${url})"
    else
        fail "${label} unreachable (${url})"
    fi
}

echo "=== Verificação de saúde da VPS ==="
echo "Horário: $(date -Iseconds)"

echo ""
echo "--- Docker ---"
if docker info >/dev/null 2>&1; then
    ok "Docker daemon acessível"
else
    fail "Docker daemon não está respondendo"
fi

echo ""
echo "--- Serviços principais ---"
check_compose_service_running "/opt/traefik" "traefik"
check_compose_service_running "/opt/myapp/${APP_SLUG}" "app"
check_compose_service_running "/opt/myapp/${APP_SLUG}" "queue"
check_compose_service_running "/opt/myapp/${APP_SLUG}" "scheduler"

echo ""
echo "--- Endpoints HTTP ---"
if [[ -n "${DOMAIN}" ]]; then
    check_http "https://${DOMAIN}/up" "App (${DOMAIN})"
else
    warn "DOMAIN não configurado — pulando verificação HTTP"
fi

echo ""
echo "--- Backup ---"
if crontab -l 2>/dev/null | grep -q "run-backup-all.sh"; then
    ok "Cron de backup instalado"
else
    fail "Cron de backup NÃO instalado — rode install-backup-cron.sh"
fi

latest_backup=$(find /opt/backups/db -type f -name '*.sql.gz' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | awk '{print $2}')
if [[ -n "${latest_backup:-}" ]]; then
    ok "Último backup local: ${latest_backup}"
else
    warn "Nenhum backup encontrado em /opt/backups/db — esperado se o cron ainda não rodou"
fi

echo ""
echo "--- Recursos do host ---"
disk_used_pct=$(df -P / | awk 'NR==2{gsub(/%/,"",$5); print $5}')
if [[ -n "${disk_used_pct}" && "${disk_used_pct}" -ge 90 ]]; then
    fail "Disco CRÍTICO em / (${disk_used_pct}%) — libere espaço urgente"
elif [[ -n "${disk_used_pct}" && "${disk_used_pct}" -ge 80 ]]; then
    warn "Disco alto em / (${disk_used_pct}%) — fique de olho"
else
    ok "Disco saudável em / (${disk_used_pct}%)"
fi

mem_used_pct=$(free | awk '/Mem:/ {printf("%d", ($3/$2)*100)}')
if [[ -n "${mem_used_pct}" && "${mem_used_pct}" -ge 95 ]]; then
    fail "Memória CRÍTICA (${mem_used_pct}%) — risco de OOM killer"
elif [[ -n "${mem_used_pct}" && "${mem_used_pct}" -ge 85 ]]; then
    warn "Memória alta (${mem_used_pct}%) — monitore"
else
    ok "Memória saudável (${mem_used_pct}%)"
fi

echo ""
echo "--- Resumo ---"
echo "Avisos: ${warn_count}"
echo "Falhas: ${fail_count}"

if [[ "${fail_count}" -gt 0 ]]; then
    echo "Status: FALHOU — verifique os itens marcados com [FAIL] acima"
    exit 2
fi
if [[ "${warn_count}" -gt 0 ]]; then
    echo "Status: OK COM AVISOS"
    exit 1
fi
echo "Status: TUDO CERTO"
exit 0
