#!/usr/bin/env bash
# install-tenant-backup-cron.sh — instala os tiers de backup banco-a-banco no host do banco.
#
# OPÇÃO ALTERNATIVA: só para projetos que adotaram multitenancy com um banco Postgres por
# tenant. O fluxo padrão do scaffold (conexão única) continua sendo
# automation/install-backup-cron.sh + automation/backup-db.sh — este script não o toca.
#
# Roda como root NO HOST DO BANCO. Lê o manifest, materializa config + credenciais em
# /etc/<PROJECT_NAME>/ (legíveis pelo usuário OS do Postgres), instala os scripts em
# /usr/local/lib/postgres-backup/ e agenda o cron do usuário `postgres`.
#
# USO: ./install-tenant-backup-cron.sh /path/to/manifest.production.env

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# common.sh pode estar em ../provisioning (repo) ou ao lado (quando copiado para a VPS).
if [[ -f "${SCRIPT_DIR}/../provisioning/common.sh" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/../provisioning/common.sh"
elif [[ -f "${SCRIPT_DIR}/common.sh" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/common.sh"
else
    echo "[ERROR] common.sh não encontrado (nem em ../provisioning nem ao lado deste script)." >&2
    exit 1
fi

MANIFEST_PATH="${1:-}"
if [[ -z "${MANIFEST_PATH}" ]]; then
    if ! MANIFEST_PATH="$(find_manifest "${SCRIPT_DIR}/..")"; then
        log_error "Nenhum manifest encontrado. Passe: ./install-tenant-backup-cron.sh /path/to/manifest.env"
        exit 1
    fi
fi

require_root
load_manifest "${MANIFEST_PATH}"
require_commands crontab install psql

DB_ENGINE="${DB_ENGINE:-pgsql}"
if [[ "${DB_ENGINE}" != "pgsql" ]]; then
    log_error "O backup por tenant só existe para PostgreSQL (DB_ENGINE=${DB_ENGINE})."
    exit 1
fi

PROJECT_NAME="${PROJECT_NAME:-myapp}"
BACKUP_OS_USER="${BACKUP_OS_USER:-postgres}"
BACKUP_DB_OWNERS="${BACKUP_DB_OWNERS:-${DB_USER:-}}"
BACKUP_HOT_TABLES="${BACKUP_HOT_TABLES:-}"
BACKUP_EXCLUDED_TABLES="${BACKUP_EXCLUDED_TABLES:-cache,cache_locks,sessions,jobs,job_batches,failed_jobs,migrations,password_reset_tokens}"
BACKUP_HOT_RETENTION_COUNT="${BACKUP_HOT_RETENTION_COUNT:-48}"
BACKUP_FULL_RETENTION_COUNT="${BACKUP_FULL_RETENTION_COUNT:-14}"
BACKUP_HOT_CRON_SCHEDULE="${BACKUP_HOT_CRON_SCHEDULE:-*/30 * * * *}"
BACKUP_FULL_CRON_SCHEDULE="${BACKUP_FULL_CRON_SCHEDULE:-20 3 * * *}"
BACKUP_ROOT_DIR="${BACKUP_ROOT_DIR:-/opt/backups}"
BACKUP_LOG_DIR="${BACKUP_LOG_DIR:-/var/log/${PROJECT_NAME}}"
BACKUP_S3_PREFIX="${BACKUP_S3_PREFIX:-db-backups}"
BACKUP_S3_REGION="${BACKUP_S3_REGION:-us-east-1}"

if [[ -z "${BACKUP_DB_OWNERS}" ]]; then
    log_error "BACKUP_DB_OWNERS (ou DB_USER) ausente no manifest — sem dono não há como descobrir os bancos."
    exit 1
fi
if [[ -z "${BACKUP_S3_ENDPOINT:-}" || -z "${BACKUP_S3_BUCKET:-}" || -z "${BACKUP_S3_ACCESS_KEY_ID:-}" || -z "${BACKUP_S3_SECRET_ACCESS_KEY:-}" ]]; then
    log_error "Bloco BACKUP_S3_* incompleto no manifest (endpoint, bucket, chave, segredo)."
    exit 1
fi
if ! id -u "${BACKUP_OS_USER}" >/dev/null 2>&1; then
    log_error "Usuário OS '${BACKUP_OS_USER}' não existe neste host — o Postgres está instalado aqui?"
    exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
    log_info "awscli ausente — instalando"
    apt-get install -y awscli >/dev/null 2>&1 || log_warn "Falha ao instalar awscli automaticamente — instale manualmente."
fi

CONFIG_DIR="/etc/${PROJECT_NAME}"
CONFIG_FILE="${CONFIG_DIR}/tenant-backup.env"
CREDENTIALS_FILE="${CONFIG_DIR}/spaces-backup-credentials.env"
LIB_DIR="/usr/local/lib/postgres-backup"

# /etc/<projeto> em vez de /root: os scripts rodam como ${BACKUP_OS_USER}, e /root (700)
# bloqueia até a travessia do diretório por outros usuários.
log_info "Preparando ${CONFIG_DIR} (dono: ${BACKUP_OS_USER})"
install -d -o "${BACKUP_OS_USER}" -g "${BACKUP_OS_USER}" -m 750 "${CONFIG_DIR}"
install -d -o "${BACKUP_OS_USER}" -g "${BACKUP_OS_USER}" -m 750 "${BACKUP_LOG_DIR}"
install -d -o "${BACKUP_OS_USER}" -g "${BACKUP_OS_USER}" -m 750 "${BACKUP_ROOT_DIR}"

# Valores sempre aspeados: os arquivos são `source`ados, e uma lista com espaço
# (`a, b`) sem aspas viraria um prefixo de env + comando — a variável ficaria vazia,
# silenciosamente desligando o tier.
emit_var() { printf '%s=%q\n' "$1" "${2:-}"; }

umask 077
{
    echo "# Gerado por install-tenant-backup-cron.sh a partir de ${MANIFEST_PATH}"
    emit_var BACKUP_DB_OWNERS "${BACKUP_DB_OWNERS}"
    emit_var BACKUP_HOT_TABLES "${BACKUP_HOT_TABLES}"
    emit_var BACKUP_EXCLUDED_TABLES "${BACKUP_EXCLUDED_TABLES}"
    emit_var BACKUP_HOT_RETENTION_COUNT "${BACKUP_HOT_RETENTION_COUNT}"
    emit_var BACKUP_FULL_RETENTION_COUNT "${BACKUP_FULL_RETENTION_COUNT}"
    emit_var BACKUP_ROOT_DIR "${BACKUP_ROOT_DIR}"
    emit_var BACKUP_LOG_DIR "${BACKUP_LOG_DIR}"
    emit_var BACKUP_S3_PREFIX "${BACKUP_S3_PREFIX}"
    emit_var BACKUP_S3_CREDENTIALS_FILE "${CREDENTIALS_FILE}"
} > "${CONFIG_FILE}"
chown "${BACKUP_OS_USER}:${BACKUP_OS_USER}" "${CONFIG_FILE}"
chmod 640 "${CONFIG_FILE}"

{
    echo "# Gerado por install-tenant-backup-cron.sh a partir de ${MANIFEST_PATH} — NÃO versionar."
    emit_var BACKUP_S3_ENDPOINT "${BACKUP_S3_ENDPOINT}"
    emit_var BACKUP_S3_REGION "${BACKUP_S3_REGION}"
    emit_var BACKUP_S3_BUCKET "${BACKUP_S3_BUCKET}"
    emit_var BACKUP_S3_ACCESS_KEY_ID "${BACKUP_S3_ACCESS_KEY_ID}"
    emit_var BACKUP_S3_SECRET_ACCESS_KEY "${BACKUP_S3_SECRET_ACCESS_KEY}"
} > "${CREDENTIALS_FILE}"
chown "${BACKUP_OS_USER}:${BACKUP_OS_USER}" "${CREDENTIALS_FILE}"
chmod 600 "${CREDENTIALS_FILE}"
umask 022

log_info "Instalando scripts em ${LIB_DIR}"
install -d -m 755 "${LIB_DIR}"
install -m 644 "${SCRIPT_DIR}/postgres-backup-lib.sh" "${LIB_DIR}/postgres-backup-lib.sh"
install -m 755 "${SCRIPT_DIR}/postgres-backup-hot.sh" "${LIB_DIR}/postgres-backup-hot.sh"
install -m 755 "${SCRIPT_DIR}/postgres-backup-full.sh" "${LIB_DIR}/postgres-backup-full.sh"

cron_env="BACKUP_CONFIG_FILE=${CONFIG_FILE}"
full_line="${BACKUP_FULL_CRON_SCHEDULE} ${cron_env} ${LIB_DIR}/postgres-backup-full.sh >> ${BACKUP_LOG_DIR}/postgres-backup-cron.log 2>&1"
hot_line="${BACKUP_HOT_CRON_SCHEDULE} ${cron_env} ${LIB_DIR}/postgres-backup-hot.sh >> ${BACKUP_LOG_DIR}/postgres-backup-cron.log 2>&1"

existing_cron="$(crontab -u "${BACKUP_OS_USER}" -l 2>/dev/null || true)"
filtered_cron="$(printf '%s\n' "${existing_cron}" | awk '!/postgres-backup-(hot|full)\.sh/')"

{
    printf '%s\n' "${filtered_cron}"
    printf '%s\n' "${full_line}"
    if [[ -n "${BACKUP_HOT_TABLES}" ]]; then
        printf '%s\n' "${hot_line}"
    fi
} | sed '/^$/N;/^\n$/D' | crontab -u "${BACKUP_OS_USER}" -

log_success "Backup por tenant instalado (cron do usuário '${BACKUP_OS_USER}')"
log_info "Bancos: descobertos pelos donos ${BACKUP_DB_OWNERS}"
log_info "Tier completo: ${BACKUP_FULL_CRON_SCHEDULE} (retém ${BACKUP_FULL_RETENTION_COUNT} rodadas)"
if [[ -n "${BACKUP_HOT_TABLES}" ]]; then
    log_info "Tier rápido:   ${BACKUP_HOT_CRON_SCHEDULE} (retém ${BACKUP_HOT_RETENTION_COUNT} rodadas) — tabelas: ${BACKUP_HOT_TABLES}"
else
    log_warn "Tier rápido desativado (BACKUP_HOT_TABLES vazio) — só o tier completo foi agendado."
fi
log_info "Logs: ${BACKUP_LOG_DIR}/postgres-backup-{hot,full}.log"
log_info "Teste manual em 1 banco antes de confiar no cron:"
log_info "  sudo -u ${BACKUP_OS_USER} env BACKUP_CONFIG_FILE=${CONFIG_FILE} ${LIB_DIR}/postgres-backup-full.sh <um-banco>"
