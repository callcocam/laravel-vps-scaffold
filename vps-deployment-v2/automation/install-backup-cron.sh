#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../provisioning/common.sh"

MANIFEST_PATH="${1:-}"
CRON_USER="${CRON_USER:-root}"

if [[ -z "${MANIFEST_PATH}" ]]; then
    if ! MANIFEST_PATH="$(find_manifest "${SCRIPT_DIR}/..")"; then
        log_error "Nenhum manifest encontrado. Passe: ./install-backup-cron.sh /path/to/manifest.env"
        exit 1
    fi
    log_info "Usando manifest: ${MANIFEST_PATH}"
fi

require_root
load_manifest "${MANIFEST_PATH}"

require_commands crontab mkdir tee awk

BACKUP_CRON_MINUTE="${BACKUP_CRON_MINUTE:-10}"
BACKUP_CRON_HOUR="${BACKUP_CRON_HOUR:-2}"
BACKUP_CRON_DAY_OF_MONTH="${BACKUP_CRON_DAY_OF_MONTH:-*}"
BACKUP_CRON_MONTH="${BACKUP_CRON_MONTH:-*}"
BACKUP_CRON_DAY_OF_WEEK="${BACKUP_CRON_DAY_OF_WEEK:-*}"
BACKUP_LOG_DIR="${BACKUP_LOG_DIR:-/var/log/myapp}"

log_info "Preparando diretório de log do backup em ${BACKUP_LOG_DIR}"
mkdir -p "${BACKUP_LOG_DIR}"
chmod 750 "${BACKUP_LOG_DIR}"

manifest_escaped="$(printf '%q' "${MANIFEST_PATH}")"
run_script_escaped="$(printf '%q' "${SCRIPT_DIR}/run-backup-all.sh")"
log_file_escaped="$(printf '%q' "${BACKUP_LOG_DIR}/backup-cron.log")"

cron_cmd="${run_script_escaped} ${manifest_escaped} >> ${log_file_escaped} 2>&1"
cron_line="${BACKUP_CRON_MINUTE} ${BACKUP_CRON_HOUR} ${BACKUP_CRON_DAY_OF_MONTH} ${BACKUP_CRON_MONTH} ${BACKUP_CRON_DAY_OF_WEEK} ${cron_cmd}"

existing_cron="$(crontab -u "${CRON_USER}" -l 2>/dev/null || true)"
filtered_cron="$(printf '%s\n' "${existing_cron}" | awk '!/run-backup-all\.sh/')"

{
    printf '%s\n' "${filtered_cron}"
    printf '%s\n' "${cron_line}"
} | sed '/^$/N;/^\n$/D' | crontab -u "${CRON_USER}" -

log_success "Cron de backup instalado para o usuário '${CRON_USER}'"
log_info "Agendamento: ${BACKUP_CRON_MINUTE} ${BACKUP_CRON_HOUR} ${BACKUP_CRON_DAY_OF_MONTH} ${BACKUP_CRON_MONTH} ${BACKUP_CRON_DAY_OF_WEEK} (formato cron padrão)"
log_info "Log do backup: ${BACKUP_LOG_DIR}/backup-cron.log"
