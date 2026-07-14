#!/usr/bin/env bash
# postgres-backup-lib.sh — mecanismo compartilhado dos tiers de backup banco-a-banco.
#
# OPÇÃO ALTERNATIVA do scaffold: só use isto se o projeto adotou multitenancy com
# UM BANCO POSTGRES POR TENANT. O fluxo padrão (conexão única) continua sendo
# automation/backup-db.sh + install-backup-cron.sh.
#
# Sourced por postgres-backup-hot.sh e postgres-backup-full.sh — não roda sozinho.
#
# Contrato do chamador (definir ANTES de chamar run_backup_tier):
#   TIER_NAME                        rótulo do tier (hot | full) — usado em paths e logs
#   TIER_RETENTION                   nº de rodadas mantidas (local E no S3)
#   select_tables_for_db <database>  função que imprime, uma por linha, as tabelas
#                                    daquele banco que entram na rodada

set -uo pipefail

# Tabelas efêmeras do framework Laravel — sem valor de restore (cache/sessão/fila
# expiram sozinhas; migrations é controle de schema, não dado). Default do scaffold,
# sobrescrevível via BACKUP_EXCLUDED_TABLES no arquivo de config.
BACKUP_DEFAULT_EXCLUDED_TABLES="cache,cache_locks,sessions,jobs,job_batches,failed_jobs,migrations,password_reset_tokens"

# Converte lista separada por vírgula e/ou espaço em palavras (para `read -ra`).
backup_split_list() {
    printf '%s' "${1:-}" | tr ',' ' '
}

backup_log() {
    echo "$(date +%Y/%m/%d\ %X) - $*" | tee -a "${LOG_FILE}"
}

backup_die() {
    if [[ -n "${LOG_FILE:-}" ]]; then
        backup_log "$*"
    else
        echo "$*" >&2
    fi
    exit 1
}

backup_load_config() {
    BACKUP_CONFIG_FILE="${BACKUP_CONFIG_FILE:-/etc/postgres-backup/tenant-backup.env}"

    if [[ ! -f "${BACKUP_CONFIG_FILE}" ]]; then
        echo "ARQUIVO DE CONFIG NÃO ENCONTRADO: ${BACKUP_CONFIG_FILE} — ABORTANDO" >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    source "${BACKUP_CONFIG_FILE}"

    BACKUP_ROOT_DIR="${BACKUP_ROOT_DIR:-/opt/backups}"
    BACKUP_LOG_DIR="${BACKUP_LOG_DIR:-/var/log/postgres-backup}"
    BACKUP_S3_PREFIX="${BACKUP_S3_PREFIX:-db-backups}"
    BACKUP_EXCLUDED_TABLES="${BACKUP_EXCLUDED_TABLES:-${BACKUP_DEFAULT_EXCLUDED_TABLES}}"
    BACKUP_HOT_TABLES="${BACKUP_HOT_TABLES:-}"

    DEST_DIR="${BACKUP_ROOT_DIR}/postgres-${TIER_NAME}"
    LOG_FILE="${BACKUP_LOG_DIR}/postgres-backup-${TIER_NAME}.log"
    LOCK_FILE="${BACKUP_LOCK_DIR:-/tmp}/postgres-backup-${TIER_NAME}.lock"
    TIER_S3_PREFIX="${BACKUP_S3_PREFIX}/${TIER_NAME}"

    mkdir -p "${BACKUP_LOG_DIR}" 2>/dev/null || {
        echo "IMPOSSÍVEL CRIAR O DIRETÓRIO DE LOG: ${BACKUP_LOG_DIR} — ABORTANDO" >&2
        exit 1
    }
    mkdir -p "${DEST_DIR}" 2>/dev/null || backup_die "IMPOSSÍVEL CRIAR O DIRETÓRIO DE DESTINO: ${DEST_DIR} — ABORTANDO"

    if [[ -z "${BACKUP_DB_OWNERS:-}" ]]; then
        backup_die "BACKUP_DB_OWNERS vazio em ${BACKUP_CONFIG_FILE} — sem donos não há como descobrir os bancos. ABORTANDO"
    fi
}

backup_require_commands() {
    PG_DUMP="$(command -v pg_dump || true)"
    PSQL="$(command -v psql || true)"
    AWS="$(command -v aws || true)"
    TAR="$(command -v tar || true)"
    FLOCK="$(command -v flock || true)"

    local name
    for name in PG_DUMP PSQL AWS TAR FLOCK; do
        [[ -z "${!name}" ]] && backup_die "COMANDO OBRIGATÓRIO AUSENTE (${name}) — ABORTANDO"
    done
}

# Credenciais S3 num arquivo separado do config — nunca hardcoded aqui.
# Precisa ser legível pelo usuário OS que roda o backup (tipicamente `postgres`),
# por isso NÃO pode ficar em /root (modo 700 bloqueia até o `cd` de outros usuários).
backup_load_s3_credentials() {
    local creds="${BACKUP_S3_CREDENTIALS_FILE:-}"

    if [[ -n "${creds}" ]]; then
        [[ -f "${creds}" ]] || backup_die "ARQUIVO DE CREDENCIAIS NÃO ENCONTRADO: ${creds} — ABORTANDO"
        [[ -r "${creds}" ]] || backup_die "SEM PERMISSÃO DE LEITURA EM ${creds} (rodando como $(id -un)) — ABORTANDO"
        # shellcheck disable=SC1090
        source "${creds}"
    fi

    BACKUP_S3_REGION="${BACKUP_S3_REGION:-us-east-1}"

    local var
    for var in BACKUP_S3_ENDPOINT BACKUP_S3_BUCKET BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY; do
        [[ -z "${!var:-}" ]] && backup_die "${var} ausente (config ou ${creds:-<sem arquivo de credenciais>}) — ABORTANDO"
    done

    export AWS_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID}"
    export AWS_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY}"
    export AWS_DEFAULT_REGION="${BACKUP_S3_REGION}"
}

# flock em vez de contar processos: sobrevive a script morto sem limpar pidfile.
backup_acquire_lock() {
    exec 9>"${LOCK_FILE}" || backup_die "IMPOSSÍVEL ABRIR O LOCK ${LOCK_FILE} — ABORTANDO"
    if ! "${FLOCK}" -n 9; then
        backup_log "O BACKUP '${TIER_NAME}' JÁ ESTÁ RODANDO — ABORTANDO"
        exit 1
    fi
}

# Descobre os bancos pelo DONO, não por lista fixa de tenants: cobre o landlord + cada
# tenant novo sem editar nada, e exclui bancos de outros donos (bancos de teste avulsos,
# `postgres`, templates) sem precisar de lista de exclusão.
# $1 opcional: restringe a rodada a um único banco (teste ou reprocessamento pontual).
backup_discover_databases() {
    local only_db="${1:-}"
    local owners=() owners_sql=""

    read -ra owners <<< "$(backup_split_list "${BACKUP_DB_OWNERS}")"
    owners_sql="$(printf "'%s'," "${owners[@]}")"
    owners_sql="${owners_sql%,}"

    local all=()
    mapfile -t all < <("${PSQL}" -d postgres -tAc \
        "SELECT d.datname FROM pg_database d JOIN pg_roles r ON d.datdba = r.oid \
         WHERE r.rolname IN (${owners_sql}) AND NOT d.datistemplate ORDER BY d.datname;" \
        2>> "${LOG_FILE}")

    DATABASES=()
    if [[ -n "${only_db}" ]]; then
        local candidate
        for candidate in "${all[@]}"; do
            [[ "${candidate}" == "${only_db}" ]] && DATABASES+=("${candidate}")
        done
        if (( ${#DATABASES[@]} == 0 )); then
            backup_die "Banco '${only_db}' não encontrado entre os donos (${BACKUP_DB_OWNERS}) — ABORTANDO"
        fi
    else
        DATABASES=("${all[@]}")
    fi

    if (( ${#DATABASES[@]} == 0 )); then
        backup_die "NENHUM BANCO ENCONTRADO PARA OS DONOS (${BACKUP_DB_OWNERS}) — ABORTANDO"
    fi
}

# Tabelas que existem de fato no banco (schema public). A interseção com essa lista
# evita erro de "tabela não existe" quando o landlord não tem as tabelas de negócio.
backup_existing_tables() {
    "${PSQL}" -d "$1" -tAc \
        "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname='public' ORDER BY tablename;" \
        2>> "${LOG_FILE}"
}

backup_upload_and_rotate() {
    local database="$1" bundle="$2" datetime="$3"
    local remote_dir="s3://${BACKUP_S3_BUCKET}/${TIER_S3_PREFIX}/${database}"
    local rc=0

    if "${AWS}" --endpoint-url "${BACKUP_S3_ENDPOINT}" s3 cp "${bundle}" "${remote_dir}/${datetime}.tar.gz" \
        --only-show-errors 2>> "${LOG_FILE}"; then
        backup_log "[${database}] Enviado: ${remote_dir}/${datetime}.tar.gz"
    else
        backup_log "[${database}] FALHA no upload para o S3"
        rc=1
    fi

    # Retenção local — mantém as TIER_RETENTION rodadas mais recentes.
    ls -1t "${DEST_DIR}/${database}"/*.tar.gz 2>/dev/null \
        | tail -n +$((TIER_RETENTION + 1)) | xargs -r rm -f

    # Retenção remota — idem, no bucket.
    local old_key
    while read -r old_key; do
        [[ -z "${old_key}" ]] && continue
        "${AWS}" --endpoint-url "${BACKUP_S3_ENDPOINT}" s3 rm "${remote_dir}/${old_key}" \
            --only-show-errors 2>> "${LOG_FILE}"
    done < <("${AWS}" --endpoint-url "${BACKUP_S3_ENDPOINT}" s3 ls "${remote_dir}/" 2>> "${LOG_FILE}" \
        | awk '{print $4}' | sort -r | tail -n +$((TIER_RETENTION + 1)))

    return "${rc}"
}

# Um .tar.gz por banco por rodada, com um .tar (pg_dump -F c) por tabela dentro:
# restaura o banco inteiro ou uma tabela só, e mantém baixo o nº de objetos no bucket.
backup_database() {
    local database="$1" datetime="$2"
    local tables=() table
    mapfile -t tables < <(select_tables_for_db "${database}")

    if (( ${#tables[@]} == 0 )); then
        backup_log "[${database}] Nenhuma tabela elegível para o tier '${TIER_NAME}', pulando"
        return 0
    fi

    local run_dir="${DEST_DIR}/${database}/tmp-${datetime}"
    mkdir -p "${run_dir}" || { backup_log "[${database}] FALHA ao criar ${run_dir}"; return 1; }

    local rc=0
    for table in "${tables[@]}"; do
        if "${PG_DUMP}" -d "${database}" -t "\"public\".\"${table}\"" -F c -b \
            -f "${run_dir}/${table}.tar" 2>> "${LOG_FILE}"; then
            backup_log "[${database}] ${table} [ OK ]"
        else
            backup_log "[${database}] ${table} [ ERRO ]"
            rc=1
        fi
    done

    local bundle="${DEST_DIR}/${database}/${datetime}.tar.gz"
    "${TAR}" -C "${run_dir}" -czf "${bundle}" . 2>> "${LOG_FILE}"
    rm -rf "${run_dir}"

    if [[ ! -f "${bundle}" ]]; then
        backup_log "[${database}] FALHA ao empacotar o backup, pulando upload"
        return 1
    fi

    backup_upload_and_rotate "${database}" "${bundle}" "${datetime}" || rc=1

    if (( rc == 0 )); then
        backup_log "[${database}] Concluído OK (${#tables[@]} tabelas)"
    else
        backup_log "[${database}] Concluído COM ERROS"
    fi
    return "${rc}"
}

run_backup_tier() {
    local only_db="${1:-}"

    backup_load_config
    backup_require_commands
    backup_load_s3_credentials
    backup_acquire_lock

    echo "==================================================================" | tee -a "${LOG_FILE}"
    backup_log "tier '${TIER_NAME}' iniciando (retenção: ${TIER_RETENTION} rodadas)"

    local start
    start="$(date +%s)"

    backup_discover_databases "${only_db}"
    backup_log "Bancos encontrados: ${DATABASES[*]}"

    local datetime overall=0 database
    datetime="$(date +%Y-%m-%d-%H-%M-%S)"

    for database in "${DATABASES[@]}"; do
        backup_database "${database}" "${datetime}" || overall=1
    done

    local elapsed
    elapsed="$(TZ=UTC0 printf '%(%H:%M:%S)T' "$(( $(date +%s) - start ))")"
    backup_log "Rodada '${TIER_NAME}' completa em ${elapsed} (bancos: ${#DATABASES[@]})"

    return "${overall}"
}
