#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../provisioning/common.sh"

MANIFEST_PATH="${1:-}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
BACKUP_ROOT="${BACKUP_ROOT:-/opt/backups/db}"

if [[ -z "${MANIFEST_PATH}" ]]; then
    log_error "Usage: ./backup-db.sh /path/to/manifest.env"
    exit 1
fi

load_manifest "${MANIFEST_PATH}"
require_commands gzip date find mkdir aws curl

DB_ENGINE="${DB_ENGINE:-${DB_ENGINE_PRODUCTION:-pgsql}}"
DB_HOST="${DB_HOST:-${DB_HOST_PRODUCTION:-}}"
DB_PORT="${DB_PORT:-${DB_PORT_PRODUCTION:-}}"
DB_NAME="${DB_NAME:-${DB_NAME_PRODUCTION:-}}"
DB_USER="${DB_USER:-${DB_USER_PRODUCTION:-}}"
DB_PASSWORD="${DB_PASSWORD:-${DB_PASSWORD_PRODUCTION:-}}"
BACKUP_TABLES="${BACKUP_TABLES:-${BACKUP_TABLES_PRODUCTION:-}}"

# Ambiente vem do manifest — production only
TARGET_ENV="${DEPLOY_ENV:-${APP_SLUG:-}}"
if [[ -z "${TARGET_ENV}" ]]; then
    log_error "DEPLOY_ENV ou APP_SLUG não definido no manifest. Não é possível isolar o backup por ambiente."
    exit 1
fi

if [[ -z "${DB_HOST}" || -z "${DB_NAME}" || -z "${DB_USER}" || -z "${DB_PASSWORD}" ]]; then
    log_error "Missing DB settings in manifest."
    exit 1
fi

BACKUP_S3_ENDPOINT="${BACKUP_S3_ENDPOINT:-}"
BACKUP_S3_REGION="${BACKUP_S3_REGION:-us-east-1}"
BACKUP_S3_BUCKET="${BACKUP_S3_BUCKET:-}"
BACKUP_S3_PREFIX="${BACKUP_S3_PREFIX:-db-backups}"
BACKUP_S3_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID:-}"
BACKUP_S3_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY:-}"
BACKUP_ALERT_WEBHOOK_URL="${BACKUP_ALERT_WEBHOOK_URL:-}"

if [[ -z "${BACKUP_S3_ENDPOINT}" || -z "${BACKUP_S3_BUCKET}" || -z "${BACKUP_S3_ACCESS_KEY_ID}" || -z "${BACKUP_S3_SECRET_ACCESS_KEY}" ]]; then
    log_error "Variáveis de backup DO Spaces ausentes no manifest (endpoint, bucket, chave e segredo)."
    log_error "Preencha o bloco BACKUP_S3_* no manifest.env antes de rodar este script."
    exit 1
fi

send_backup_fail_alert() {
    local message="$1"

    if [[ -z "${BACKUP_ALERT_WEBHOOK_URL}" ]]; then
        return
    fi

    local payload
    payload=$(printf '{"text":"[myapp][backup-fail][%s] %s"}' "${TARGET_ENV}" "${message}")

    curl -fsS -X POST -H 'Content-Type: application/json' -d "${payload}" "${BACKUP_ALERT_WEBHOOK_URL}" >/dev/null || true
}

on_error() {
    local exit_code="$1"
    local line_no="$2"
    send_backup_fail_alert "Backup failed with exit code ${exit_code} at line ${line_no}."
    exit "${exit_code}"
}

trap 'on_error $? $LINENO' ERR

backup_dir="${BACKUP_ROOT}/${TARGET_ENV}"
mkdir -p "${backup_dir}"

log_info "Iniciando backup do banco '${DB_NAME}' (${DB_ENGINE}) → ${BACKUP_S3_BUCKET}"
ts="$(date +%Y%m%d-%H%M%S)"
output_file="${backup_dir}/${DB_NAME}-${ts}.sql.gz"

tables=()
if [[ -n "${BACKUP_TABLES}" ]]; then
    IFS=',' read -r -a raw_tables <<< "${BACKUP_TABLES}"
    for raw_table in "${raw_tables[@]}"; do
        table_name="$(echo "${raw_table}" | xargs)"
        if [[ -n "${table_name}" ]]; then
            tables+=("${table_name}")
        fi
    done
fi

if [[ "${DB_ENGINE}" == "mysql" ]]; then
    require_commands mysqldump
    mysql_dump_cmd=(mysqldump --single-transaction --quick --host="${DB_HOST}" --port="${DB_PORT}" --user="${DB_USER}" "${DB_NAME}")
    if (( ${#tables[@]} > 0 )); then
        mysql_dump_cmd+=("${tables[@]}")
    fi
    MYSQL_PWD="${DB_PASSWORD}" "${mysql_dump_cmd[@]}" | gzip -9 > "${output_file}"
elif [[ "${DB_ENGINE}" == "pgsql" ]]; then
    require_commands pg_dump
    pg_dump_cmd=(pg_dump --host="${DB_HOST}" --port="${DB_PORT}" --username="${DB_USER}" --format=plain "${DB_NAME}")
    if (( ${#tables[@]} > 0 )); then
        for table_name in "${tables[@]}"; do
            pg_dump_cmd+=("-t" "${table_name}")
        done
    fi
    PGPASSWORD="${DB_PASSWORD}" "${pg_dump_cmd[@]}" | gzip -9 > "${output_file}"
else
    log_error "Unsupported DB engine: ${DB_ENGINE}"
    exit 1
fi

log_info "Enviando backup para DO Spaces: s3://${BACKUP_S3_BUCKET}/${BACKUP_S3_PREFIX}/${TARGET_ENV}/"
s3_key="${BACKUP_S3_PREFIX}/${TARGET_ENV}/$(basename "${output_file}")"
AWS_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID}" AWS_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY}" AWS_DEFAULT_REGION="${BACKUP_S3_REGION}" \
aws --endpoint-url "${BACKUP_S3_ENDPOINT}" s3 cp "${output_file}" "s3://${BACKUP_S3_BUCKET}/${s3_key}" --only-show-errors

log_info "Limpando backups locais com mais de ${RETENTION_DAYS} dias"
find "${backup_dir}" -type f -name '*.sql.gz' -mtime +"${RETENTION_DAYS}" -delete

log_success "Backup criado: ${output_file}"
log_success "Backup enviado: s3://${BACKUP_S3_BUCKET}/${s3_key}"
if (( ${#tables[@]} > 0 )); then
    log_info "Filtro de tabelas aplicado: ${BACKUP_TABLES}"
fi
