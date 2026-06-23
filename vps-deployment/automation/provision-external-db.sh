#!/usr/bin/env bash
# provision-external-db.sh — provisiona banco em VPS externa via SSH
#
# Roda LOCALMENTE. Conecta na VPS de banco, instala PostgreSQL/MySQL,
# configura UFW/fail2ban, e opcionalmente instala backup para DO Spaces.
#
# Uso:
#   ./automation/provision-external-db.sh \
#     --host <IP>                      # IP da VPS de banco (obrigatório)
#     [--manifest <path>]              # padrão: ../manifest.env
#     [--bootstrap-password <senha>]   # senha root para 1ª conexão (bootstrap)
#     [--new-passwords]                # gera novas senhas DB e atualiza manifest + app .env
#     [--no-backup]                    # pula instalação do cron de backup DO Spaces
#     [--reset]                        # força reconfiguração mesmo se já provisionado
#     [--dry-run]                      # mostra os comandos sem executar

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROVISIONING_DIR="${SCRIPT_DIR}/../provisioning"
# shellcheck disable=SC1091
source "${PROVISIONING_DIR}/common.sh"

# ── Parse args ────────────────────────────────────────────────────────────────
DB_HOST_ARG=""
MANIFEST_PATH=""
BOOTSTRAP_PASSWORD="${BOOTSTRAP_ROOT_PASSWORD:-}"
NEW_PASSWORDS=false
SETUP_BACKUP=true
DRY_RUN=false
FORCE_RESET=false
UPDATE_FIREWALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)               DB_HOST_ARG="$2"; shift 2 ;;
        --manifest)           MANIFEST_PATH="$2"; shift 2 ;;
        --bootstrap-password) BOOTSTRAP_PASSWORD="$2"; shift 2 ;;
        --new-passwords)      NEW_PASSWORDS=true; shift ;;
        --no-backup)          SETUP_BACKUP=false; shift ;;
        --reset)              FORCE_RESET=true; shift ;;
        --update-firewall)    UPDATE_FIREWALL=true; shift ;;
        --dry-run)            DRY_RUN=true; shift ;;
        # legacy aliases mantidos para compatibilidade
        --bootstrap-root-password) BOOTSTRAP_PASSWORD="$2"; shift 2 ;;
        *) log_error "Argumento desconhecido: $1"; exit 1 ;;
    esac
done

if [[ -z "${DB_HOST_ARG}" ]]; then
    log_error "Uso: $0 --host <IP> [--manifest path] [--bootstrap-password senha] [--new-passwords] [--no-backup] [--reset] [--dry-run]"
    exit 1
fi

MANIFEST_DIR="${SCRIPT_DIR}/.."
if [[ -z "${MANIFEST_PATH}" ]]; then
    if ! MANIFEST_PATH="$(find_manifest "${MANIFEST_DIR}")"; then
        log_error "Nenhum manifest encontrado em ${MANIFEST_DIR}"
        log_error "Esperado: manifest.production.env"
        log_error "Passe explicitamente com --manifest /path/to/manifest.env"
        exit 1
    fi
    log_info "Usando manifest detectado: ${MANIFEST_PATH}"
fi

MANIFEST_PATH="$(realpath "${MANIFEST_PATH}")"
if [[ ! -f "${MANIFEST_PATH}" ]]; then
    log_error "Manifest não encontrado: ${MANIFEST_PATH}"
    exit 1
fi

load_manifest "${MANIFEST_PATH}"

APP_SLUG="${APP_SLUG:-production}"
DB_ENGINE="${DB_ENGINE:-pgsql}"
DB_ALLOWED_CIDR="${DB_ALLOWED_CIDR:-10.0.0.0/8}"
PROJECT_NAME="${PROJECT_NAME:-myapp}"
GITHUB_REPO="${GITHUB_REPO:-${GITHUB_REPO_NAME:-${PROJECT_NAME}}}"

# ── Chave SSH dedicada ao host do banco ───────────────────────────────────────
KEY_DIR="${HOME}/.ssh"
mkdir -p "${KEY_DIR}" && chmod 700 "${KEY_DIR}"

DB_KEY_NAME="id_ed25519_${GITHUB_REPO}_db"
DB_KEY_PATH="${KEY_DIR}/${DB_KEY_NAME}"

if [[ "${DRY_RUN}" != "true" ]]; then
    if [[ ! -f "${DB_KEY_PATH}" ]]; then
        log_info "Gerando chave SSH dedicada para o host do banco: ${DB_KEY_PATH}"
        ssh-keygen -t ed25519 -f "${DB_KEY_PATH}" -N "" -C "${GITHUB_REPO}-db" -q
        log_success "Chave DB gerada: ${DB_KEY_PATH}"
    else
        log_info "Usando chave SSH já existente para banco: ${DB_KEY_PATH}"
    fi
else
    log_info "[DRY_RUN] Geraria/usaria chave: ${DB_KEY_PATH}"
fi

# Atualiza ~/.ssh/config com entrada para o host do banco
SSH_CONFIG="${KEY_DIR}/config"
touch "${SSH_CONFIG}" && chmod 600 "${SSH_CONFIG}"
awk -v host="${DB_HOST_ARG}" '
    /^Host / { in_block = ($2 == host); if (in_block) next }
    in_block && /^[[:space:]]/ { next }
    { in_block = 0; print }
' "${SSH_CONFIG}" > "${SSH_CONFIG}.tmp" && mv "${SSH_CONFIG}.tmp" "${SSH_CONFIG}"
{
    printf '\nHost %s\n' "${DB_HOST_ARG}"
    printf '    User root\n'
    printf '    IdentityFile %s\n' "${DB_KEY_PATH}"
    printf '    StrictHostKeyChecking accept-new\n'
} >> "${SSH_CONFIG}"
log_success "~/.ssh/config atualizado — ssh root@${DB_HOST_ARG} usa ${DB_KEY_NAME}"

# ── SSH helper ────────────────────────────────────────────────────────────────
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -i "${DB_KEY_PATH}" -o IdentitiesOnly=yes)
SSH_TARGET="root@${DB_HOST_ARG}"

run_remote() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        printf '[DRY_RUN remote] %s\n' "$*"
        return
    fi
    ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" "$@"
}

run_scp() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        printf '[DRY_RUN scp] %s\n' "$*"
        return
    fi
    scp "${SSH_OPTS[@]}" "$@"
}

# ── Bootstrap via senha (1ª conexão) ─────────────────────────────────────────
_bootstrap_with_password() {
    require_commands sshpass

    log_info "Tentando bootstrap inicial por senha em ${DB_HOST_ARG}"
    local pub_key
    pub_key="$(cat "${DB_KEY_PATH}.pub")"
    local escaped_key="${pub_key//\'/\'\"\'\"\'}"

    sshpass -p "${BOOTSTRAP_PASSWORD}" ssh \
        -o PubkeyAuthentication=no \
        -o PreferredAuthentications=password \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=15 \
        "root@${DB_HOST_ARG}" \
        "set -euo pipefail; \
         mkdir -p /root/.ssh; chmod 700 /root/.ssh; touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys; \
         grep -qxF '${escaped_key}' /root/.ssh/authorized_keys || echo '${escaped_key}' >> /root/.ssh/authorized_keys; \
         sed -i 's/^#\\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config; \
         sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config; \
         systemctl restart ssh || systemctl restart sshd"

    log_success "Bootstrap concluído: chave pública instalada em root@${DB_HOST_ARG}"
}

# ── Testa conectividade SSH ───────────────────────────────────────────────────
if [[ "${DRY_RUN}" != "true" ]]; then
    log_info "Testando conexão SSH com ${SSH_TARGET}"
    if ! ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" echo "ssh-ok" >/dev/null 2>&1; then
        if [[ -n "${BOOTSTRAP_PASSWORD}" ]]; then
            log_warn "Falha no SSH por chave. Tentando bootstrap por senha inicial..."
            _bootstrap_with_password
            if ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" echo "ssh-ok" >/dev/null 2>&1; then
                log_success "Conexão SSH OK após bootstrap"
            else
                log_error "Bootstrap por senha não conseguiu habilitar acesso por chave."
                log_error "Verifique senha, políticas SSH da VPS e usuário root."
                exit 1
            fi
        else
            log_error "Não foi possível conectar via SSH em ${SSH_TARGET}"
            log_error "Verifique IP/chave ou passe --bootstrap-password para bootstrap automático."
            exit 1
        fi
    else
        log_success "Conexão SSH OK"
    fi
fi

# ── Geração de novas senhas ───────────────────────────────────────────────────
_update_manifest_var() {
    local key="$1" val="$2" file="$3"
    if grep -q "^${key}=" "${file}"; then
        sed -i "s|^${key}=.*|${key}=${val}|" "${file}"
    else
        printf '%s=%s\n' "${key}" "${val}" >> "${file}"
    fi
}

if [[ "${NEW_PASSWORDS}" == "true" ]]; then
    log_info "Gerando novas senhas para o banco"
    NEW_DB_PASSWORD="$(openssl rand -base64 48 | tr -d '=+/' | cut -c1-28)"
    NEW_DB_ROOT_PASS="$(openssl rand -base64 48 | tr -d '=+/' | cut -c1-28)"

    _update_manifest_var "DB_PASSWORD"          "${NEW_DB_PASSWORD}"  "${MANIFEST_PATH}"
    _update_manifest_var "DB_ROOT_PASS"         "${NEW_DB_ROOT_PASS}" "${MANIFEST_PATH}"

    load_manifest "${MANIFEST_PATH}"
    log_success "Novas senhas salvas no manifest"
fi

# ── Atualiza manifest com host, modo e chave SSH ──────────────────────────────
_update_manifest_var "DB_MODE"          "externo"        "${MANIFEST_PATH}"
_update_manifest_var "DB_HOST"          "${DB_HOST_ARG}" "${MANIFEST_PATH}"
_update_manifest_var "DB_SSH_KEY_PATH"  "${DB_KEY_PATH}" "${MANIFEST_PATH}"

load_manifest "${MANIFEST_PATH}"

DB_NAME="${DB_NAME:-${PROJECT_NAME}_${APP_SLUG}}"
DB_USER="${DB_USER:-${DB_NAME}}"

log_info "Provisionando banco em ${DB_HOST_ARG} (engine: ${DB_ENGINE}, modo: externo)"

# ── Detecta se banco já está provisionado ────────────────────────────────────
_check_db_provisioned() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        return 1
    fi

    if [[ "${DB_ENGINE}" == "pgsql" ]]; then
        ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" \
            "systemctl is-active postgresql >/dev/null 2>&1 && \
             sudo -u postgres psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'\" 2>/dev/null | grep -q 1 && \
             sudo -u postgres psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'\" 2>/dev/null | grep -q 1" \
            >/dev/null 2>&1
    else
        ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" \
            "systemctl is-active mysql >/dev/null 2>&1 && \
             mysql -uroot -sse \"SELECT COUNT(*) FROM mysql.user WHERE User='${DB_USER}'\" 2>/dev/null | grep -qv '^0\$' && \
             mysql -uroot -sse \"SELECT COUNT(*) FROM information_schema.schemata WHERE SCHEMA_NAME='${DB_NAME}'\" 2>/dev/null | grep -qv '^0\$'" \
            >/dev/null 2>&1
    fi
}

_skip_db_setup=false

if _check_db_provisioned; then
    log_warn "Banco já provisionado em ${DB_HOST_ARG}"
    log_info "  Engine: ${DB_ENGINE} | Usuário: ${DB_USER} | Banco: ${DB_NAME}"

    if [[ "${FORCE_RESET}" == "true" ]]; then
        log_warn "--reset informado: reconfigurando banco"
    elif [[ "${UPDATE_FIREWALL}" == "true" ]]; then
        log_info "--update-firewall: atualizando regras UFW e pg_hba.conf sem reconfigurar o banco"
        _skip_db_setup=true
    else
        echo ""
        echo -ne "  Banco já configurado. Manter [k] ou reconfigurar [r]? (padrão: k): "
        read -r _proceed_choice
        _proceed_choice="${_proceed_choice:-k}"

        if [[ "${_proceed_choice,,}" != "r" ]]; then
            log_info "Mantendo configuração existente — pulando setup-db-host.sh"
            _skip_db_setup=true
        else
            log_warn "Reconfigurando banco existente"
        fi
    fi
fi

# ── Atualiza firewall e pg_hba.conf com CIDR correto (sem reconfigurar banco) ─
if [[ "${UPDATE_FIREWALL}" == "true" || "${_skip_db_setup}" == "false" ]]; then
    if [[ "${UPDATE_FIREWALL}" == "true" ]]; then
        log_info "Aplicando CIDR ${DB_ALLOWED_CIDR} no UFW e pg_hba.conf de ${DB_HOST_ARG}"
        if [[ "${DB_ENGINE}" == "pgsql" ]]; then
            run_remote "
                ufw allow from ${DB_ALLOWED_CIDR} to any port 5432 proto tcp
                PG_VERSION=\$(ls /etc/postgresql | sort -V | tail -n1)
                grep -qxF 'host all all ${DB_ALLOWED_CIDR} scram-sha-256' \
                    /etc/postgresql/\${PG_VERSION}/main/pg_hba.conf \
                    || echo 'host all all ${DB_ALLOWED_CIDR} scram-sha-256' >> \
                       /etc/postgresql/\${PG_VERSION}/main/pg_hba.conf
                systemctl reload postgresql
            "
        else
            run_remote "
                ufw allow from ${DB_ALLOWED_CIDR} to any port 3306 proto tcp
                mysql -uroot -e \"CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}'; \
                    GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'%'; \
                    GRANT CREATE, DROP ON *.* TO '${DB_USER}'@'%'; FLUSH PRIVILEGES;\" 2>/dev/null || true
            "
        fi
        log_success "Firewall e acesso atualizados para CIDR ${DB_ALLOWED_CIDR}"
    fi
fi

# ── Copia scripts e roda setup-db-host.sh na VPS ─────────────────────────────
if [[ "${_skip_db_setup}" == "false" ]]; then
    REMOTE_TMP="/tmp/vps-db-$$"
    log_info "Copiando scripts para ${SSH_TARGET}:${REMOTE_TMP}"

    run_remote "mkdir -p ${REMOTE_TMP}"
    run_scp \
        "${PROVISIONING_DIR}/common.sh" \
        "${PROVISIONING_DIR}/setup-db-host.sh" \
        "${MANIFEST_PATH}" \
        "${SSH_TARGET}:${REMOTE_TMP}/"
    run_remote "chmod +x ${REMOTE_TMP}/setup-db-host.sh"

    MANIFEST_BASENAME="$(basename "${MANIFEST_PATH}")"
    log_info "Rodando setup-db-host.sh na VPS remota"
    run_remote "DB_MODE=externo DB_ENGINE=${DB_ENGINE} bash ${REMOTE_TMP}/setup-db-host.sh ${REMOTE_TMP}/${MANIFEST_BASENAME}"

    log_info "Removendo arquivos temporários da VPS remota"
    run_remote "rm -rf ${REMOTE_TMP}"
fi

# ── Backup DO Spaces ──────────────────────────────────────────────────────────
if [[ "${SETUP_BACKUP}" == "true" ]]; then
    BACKUP_S3_BUCKET="${BACKUP_S3_BUCKET:-}"
    BACKUP_S3_ENDPOINT="${BACKUP_S3_ENDPOINT:-}"
    BACKUP_S3_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID:-}"
    BACKUP_S3_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY:-}"

    if [[ -z "${BACKUP_S3_BUCKET}" || -z "${BACKUP_S3_ENDPOINT}" || -z "${BACKUP_S3_ACCESS_KEY_ID}" || -z "${BACKUP_S3_SECRET_ACCESS_KEY}" ]]; then
        log_warn "Variáveis BACKUP_S3_* não configuradas no manifest — pulando setup de backup."
        log_warn "Preencha o bloco '# DO Spaces backup' no manifest.env e re-execute sem --no-backup."
    else
        log_info "Instalando backup DO Spaces na VPS de banco"

        REMOTE_BACKUP_TMP="/tmp/vps-backup-$$"
        run_remote "mkdir -p ${REMOTE_BACKUP_TMP}"
        run_scp \
            "${SCRIPT_DIR}/backup-db.sh" \
            "${SCRIPT_DIR}/install-backup-cron.sh" \
            "${SCRIPT_DIR}/run-backup-all.sh" \
            "${MANIFEST_PATH}" \
            "${SSH_TARGET}:${REMOTE_BACKUP_TMP}/"
        run_remote "chmod +x ${REMOTE_BACKUP_TMP}/backup-db.sh ${REMOTE_BACKUP_TMP}/install-backup-cron.sh ${REMOTE_BACKUP_TMP}/run-backup-all.sh"

        run_remote "command -v aws >/dev/null 2>&1 || (apt-get install -y awscli 2>/dev/null || pip3 install --quiet awscli)"

        MANIFEST_BASENAME="$(basename "${MANIFEST_PATH}")"
        run_remote "CRON_USER=root bash ${REMOTE_BACKUP_TMP}/install-backup-cron.sh ${REMOTE_BACKUP_TMP}/${MANIFEST_BASENAME}"
        run_remote "rm -rf ${REMOTE_BACKUP_TMP}"

        log_success "Backup cron instalado na VPS de banco"
        log_info "Agendamento: diário às 02:10 → DO Spaces bucket: ${BACKUP_S3_BUCKET}"
    fi
fi

# ── Atualiza .env do app se senhas mudaram ────────────────────────────────────
APP_VPS_HOST="${VPS_HOST:-}"
if [[ "${NEW_PASSWORDS}" == "true" && -n "${APP_VPS_HOST}" ]]; then
    APP_SSH_USER="${DEPLOY_USER:-root}"
    APP_DIR="/opt/myapp/${APP_SLUG}"
    APP_ENV_FILE="${APP_DIR}/.env"

    log_info "Atualizando senhas no .env do app em ${APP_VPS_HOST}"

    APP_KEY_PATH="${KEY_DIR}/id_ed25519_${GITHUB_REPO}_deploy"
    APP_SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
    [[ -f "${APP_KEY_PATH}" ]] && APP_SSH_OPTS+=(-i "${APP_KEY_PATH}" -o IdentitiesOnly=yes)

    if [[ "${DRY_RUN}" != "true" ]]; then
        ssh "${APP_SSH_OPTS[@]}" "${APP_SSH_USER}@${APP_VPS_HOST}" \
            "sed -i 's|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASSWORD}|;
                     s|^DB_HOST=.*|DB_HOST=${DB_HOST_ARG}|' \
             ${APP_ENV_FILE}"

        log_info "Reiniciando containers do app"
        ssh "${APP_SSH_OPTS[@]}" "${APP_SSH_USER}@${APP_VPS_HOST}" \
            "cd ${APP_DIR} && docker compose up -d"
    else
        printf '[DRY_RUN] Atualizaria .env em %s e reiniciaria containers\n' "${APP_VPS_HOST}"
    fi

    log_success "App .env atualizado e containers reiniciados"
fi

log_success "Provisionamento do banco externo concluído!"
log_info ""
log_info "Próximos passos:"
log_info "  1. Confirm no manifest.env: DB_MODE=externo, DB_HOST=${DB_HOST_ARG}"
log_info "  2. Acesso SSH ao banco: ssh root@${DB_HOST_ARG}  (chave: ${DB_KEY_PATH})"
if [[ "${NEW_PASSWORDS}" == "true" ]]; then
    log_info "  3. Novas senhas gravadas no manifest.env"
fi
log_info "  4. Para apontar o app para o banco externo, atualize o .env na VPS:"
log_info "     ssh ${APP_SLUG}-vps \"sed -i 's|^DB_HOST=.*|DB_HOST=${DB_HOST_ARG}|' /opt/myapp/${APP_SLUG}/.env\""
log_info "     ssh ${APP_SLUG}-vps \"cd /opt/myapp/${APP_SLUG} && docker compose up -d\""
