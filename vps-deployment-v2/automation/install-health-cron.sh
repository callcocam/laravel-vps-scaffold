#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../provisioning/common.sh"

MANIFEST_PATH="${1:-}"
CRON_USER="${CRON_USER:-root}"

if [[ -z "${MANIFEST_PATH}" ]]; then
    if ! MANIFEST_PATH="$(find_manifest "${SCRIPT_DIR}/..")"; then
        log_error "Nenhum manifest encontrado. Passe: ./install-health-cron.sh /path/to/manifest.env"
        exit 1
    fi
    log_info "Usando manifest: ${MANIFEST_PATH}"
fi

require_root
load_manifest "${MANIFEST_PATH}"
require_commands crontab mkdir awk sed

HEALTH_CRON_MINUTE="${HEALTH_CRON_MINUTE:-*/15}"
HEALTH_CRON_HOUR="${HEALTH_CRON_HOUR:-*}"
HEALTH_CRON_DAY_OF_MONTH="${HEALTH_CRON_DAY_OF_MONTH:-*}"
HEALTH_CRON_MONTH="${HEALTH_CRON_MONTH:-*}"
HEALTH_CRON_DAY_OF_WEEK="${HEALTH_CRON_DAY_OF_WEEK:-*}"
HEALTH_LOG_DIR="${HEALTH_LOG_DIR:-/var/log/myapp}"

mkdir -p "${HEALTH_LOG_DIR}"
chmod 750 "${HEALTH_LOG_DIR}"

manifest_escaped="$(printf '%q' "${MANIFEST_PATH}")"
health_script_escaped="$(printf '%q' "${SCRIPT_DIR}/vps-health-check.sh")"
health_log_escaped="$(printf '%q' "${HEALTH_LOG_DIR}/health-cron.log")"

cron_cmd="${health_script_escaped} ${manifest_escaped} >> ${health_log_escaped} 2>&1"
cron_line="${HEALTH_CRON_MINUTE} ${HEALTH_CRON_HOUR} ${HEALTH_CRON_DAY_OF_MONTH} ${HEALTH_CRON_MONTH} ${HEALTH_CRON_DAY_OF_WEEK} ${cron_cmd}"

existing_cron="$(crontab -u "${CRON_USER}" -l 2>/dev/null || true)"
filtered_cron="$(printf '%s\n' "${existing_cron}" | awk '!/vps-health-check\.sh/')"

{
    printf '%s\n' "${filtered_cron}"
    printf '%s\n' "${cron_line}"
} | sed '/^$/N;/^\n$/D' | crontab -u "${CRON_USER}" -

log_success "Health cron installed for user ${CRON_USER}"
log_info "Schedule: ${HEALTH_CRON_MINUTE} ${HEALTH_CRON_HOUR} ${HEALTH_CRON_DAY_OF_MONTH} ${HEALTH_CRON_MONTH} ${HEALTH_CRON_DAY_OF_WEEK}"
log_info "Log file: ${HEALTH_LOG_DIR}/health-cron.log"
