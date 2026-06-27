#!/usr/bin/env bash
# setup.sh — Wizard interativo (multi-app por APP_SLUG)
# Execute: bash vps-deployment/setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_WORKDIR="/tmp/vps-deployment"

# Carrega manifest genérico para pre-preencher valores compartilhados (VPS, GitHub, etc.)
if [[ -f "${SCRIPT_DIR}/manifest.env" ]]; then
    # shellcheck disable=SC1090
    set -a; source "${SCRIPT_DIR}/manifest.env"; set +a || true
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
step() { echo -e "\n${BOLD}${CYAN}▶ $*${RESET}"; }
info() { echo -e "  ${DIM}$*${RESET}"; }
ok() { echo -e "  ${GREEN}✔ $*${RESET}"; }
warn() { echo -e "  ${YELLOW}⚠ $*${RESET}"; }

ask() {
    local var_name="$1" prompt="$2" default="${3:-}"
    local display_default=""
    [[ -n "$default" ]] && display_default=" ${DIM}[${default}]${RESET}"
    echo -ne "  ${BOLD}${prompt}${RESET}${display_default}: "
    read -r input
    input="${input:-$default}"
    while [[ -z "$input" ]]; do
        echo -ne "  ${RED}Obrigatório.${RESET} ${BOLD}${prompt}${RESET}: "
        read -r input
    done
    printf -v "$var_name" '%s' "$input"
}

ask_secret_default() {
    local var_name="$1" prompt="$2" default="${3:-}"
    echo -ne "  ${BOLD}${prompt}${RESET} ${DIM}[ENTER para manter]${RESET}: "
    read -rs input
    echo ""
    input="${input:-$default}"
    while [[ -z "$input" ]]; do
        echo -ne "  ${RED}Obrigatório.${RESET} ${BOLD}${prompt}${RESET}: "
        read -rs input
        echo ""
    done
    printf -v "$var_name" '%s' "$input"
}

ask_secret_suggest() {
    local var_name="$1" prompt="$2" existing="${3:-}"
    local suggestion hint
    suggestion="$(suggest_password)"

    echo -e "  ${DIM}Sugestão: ${CYAN}${suggestion}${RESET}"
    if [[ -n "${existing}" ]]; then
        hint="ENTER para manter a atual, ou cole a sugestão"
    else
        hint="ENTER para usar a sugestão"
    fi
    echo -ne "  ${BOLD}${prompt}${RESET} ${DIM}[${hint}]${RESET}: "
    read -rs input
    echo ""

    if [[ -z "${input}" ]]; then
        input="${existing:-${suggestion}}"
    fi

    while [[ -z "$input" ]]; do
        echo -ne "  ${RED}Obrigatório.${RESET} ${BOLD}${prompt}${RESET}: "
        read -rs input
        echo ""
    done
    printf -v "$var_name" '%s' "$input"
}

ask_yn() {
    local prompt="$1" default="${2:-s}" opts="S/n"
    [[ "$default" == "n" ]] && opts="s/N"
    echo -ne "  ${BOLD}${prompt}${RESET} ${DIM}[${opts}]${RESET}: "
    read -r yn
    yn="${yn:-$default}"
    [[ "${yn,,}" == "s" || "${yn,,}" == "y" ]]
}

ask_choice() {
    local var_name="$1" prompt="$2" default="$3"
    shift 3
    local options=("$@")
    local options_label
    options_label="$(IFS='/'; echo "${options[*]}")"
    local input

    while true; do
        echo -ne "  ${BOLD}${prompt}${RESET} ${DIM}[${options_label}] (padrão: ${default})${RESET}: "
        read -r input
        input="${input:-$default}"
        for option in "${options[@]}"; do
            if [[ "${input}" == "${option}" ]]; then
                printf -v "${var_name}" '%s' "${input}"
                return 0
            fi
        done
        warn "Opção inválida: ${input}"
    done
}

refresh_known_host() {
    local host="$1"

    if [[ -z "${host}" ]]; then
        return 0
    fi

    ssh-keygen -R "${host}" -f "${HOME}/.ssh/known_hosts" >/dev/null 2>&1 || true
    ssh-keygen -R "[${host}]:22" -f "${HOME}/.ssh/known_hosts" >/dev/null 2>&1 || true
}

random_secret() { openssl rand -base64 48 | tr -d '=+/' | cut -c1-40; }
suggest_password() {
    local p
    p="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-20)"
    echo "${p:0:5}-${p:5:5}-${p:10:5}-${p:15:5}"
}
emit_manifest_var() { printf '%s=%q\n' "$1" "${2:-}"; }

clear
step "VPS Deployment — myapp (production)"
info "Ambiente: production (main → deploy manual)"
echo ""
DEPLOY_ENV=production

MANIFEST_OUT="${SCRIPT_DIR}/manifest.${DEPLOY_ENV}.env"
COMPOSE_FILE_NAME="docker-compose.${DEPLOY_ENV}.yml"

# Carrega manifest do ambiente escolhido (sobrescreve valores do manifest genérico)
if [[ -f "${MANIFEST_OUT}" ]]; then
    # shellcheck disable=SC1090
    set -a; source "${MANIFEST_OUT}"; set +a || true
fi

step "Projeto e domínio"
ask PROJECT_NAME "Nome do projeto" "${PROJECT_NAME:-myapp}"
ask APP_SLUG "Nome da app/pasta (slug)" "${APP_SLUG:-${DEPLOY_ENV}}"
ask GITHUB_OWNER "GitHub org/usuário" "${GITHUB_OWNER:-}"
ask GITHUB_REPO "Nome do repositório" "${GITHUB_REPO_NAME:-${PROJECT_NAME}}"
ask GHCR_REPO "Imagem GHCR" "${GHCR_REPO:-${GITHUB_OWNER}/${GITHUB_REPO}}"
ask DOMAIN "Domínio da aplicação (raiz)" "${DOMAIN:-${DOMAIN_PRODUCTION:-}}"
ask ACME_EMAIL "E-mail para Let's Encrypt" "${ACME_EMAIL:-}"

step "VPS e banco"
ask VPS_HOST "IP do App VPS" "${VPS_HOST:-}"
ask VPS_USER "Usuário SSH root no VPS" "${VPS_USER:-root}"
ask DEPLOY_USER "Usuário de deploy (root = mais simples, deploy = mais seguro)" "${DEPLOY_USER:-root}"

is_placeholder_vps_host() {
    local host="$1"
    [[ -z "${host}" ]] && return 0
    [[ "${host}" == "203.0.113.10" ]] && return 0
    [[ "${host}" == "198.51.100.10" ]] && return 0
    [[ "${host}" == "192.0.2.10" ]] && return 0
    [[ "${host}" == *"example.com"* ]] && return 0
    return 1
}

while is_placeholder_vps_host "${VPS_HOST}"; do
    warn "VPS_HOST está com valor de exemplo (${VPS_HOST}). Informe o IP/host real da sua VPS."
    ask VPS_HOST "IP do App VPS" ""
done
if [[ "${DEPLOY_USER}" != "root" ]]; then
    info "Senha usada para acesso via console da VPS (backup — SSH usa chave)."
    ask_secret_suggest DEPLOY_USER_PASS "Senha do usuário ${DEPLOY_USER}" "${DEPLOY_USER_PASS:-}"
fi
ask_choice DB_MODE "Banco é local na mesma VPS ou externo?" "${DB_MODE:-local}" local externo
ask DB_ENGINE "Engine (pgsql|mysql)" "${DB_ENGINE:-${DB_ENGINE_STAGING:-pgsql}}"

if [[ "${DB_MODE}" == "local" ]]; then
    DB_LOCAL_HOST_DEFAULT="${DB_LOCAL_HOST_FALLBACK:-host.docker.internal}"
    DB_HOST="${DB_LOCAL_HOST_DEFAULT}"
    if [[ "${DB_ENGINE}" == "pgsql" ]]; then
        DB_PORT="${DB_PORT:-5432}"
    else
        DB_PORT="${DB_PORT:-3306}"
    fi
    DB_ROOT_USER="${DB_ROOT_USER:-root}"
    ask_secret_suggest DB_ROOT_PASS "Senha root do banco local (para provisionar)" "${DB_ROOT_PASS:-}"
else
    ask DB_HOST "IP/host do banco externo" "${DB_HOST:-${DB_HOST_STAGING:-}}"
    if [[ "${DB_ENGINE}" == "pgsql" ]]; then
        ask DB_PORT "Porta DB externa" "${DB_PORT:-5432}"
    else
        ask DB_PORT "Porta DB externa" "${DB_PORT:-3306}"
    fi
    ask DB_ROOT_USER "Usuário root/admin da VPS do banco externo (referência)" "${DB_ROOT_USER:-root}"
    ask_secret_suggest DB_ROOT_PASS "Senha do user root (ou admin) da VPS do banco externo (referência)" "${DB_ROOT_PASS:-}"
fi
ask DB_NAME "Nome do banco (${APP_SLUG})" "${DB_NAME:-${DB_NAME_STAGING:-${PROJECT_NAME}_${APP_SLUG}}}"
if [[ "${DB_ENGINE}" == "pgsql" ]]; then
    DB_USER_DEFAULT="${DB_USER:-${DB_USER_STAGING:-${DB_NAME}}}"
else
    DB_USER_DEFAULT="${DB_USER:-${DB_USER_STAGING:-${PROJECT_NAME}_${APP_SLUG}_user}}"
fi
ask DB_USER "Usuário DB (${APP_SLUG})" "${DB_USER_DEFAULT}"
ask_secret_suggest DB_PASSWORD "Senha DB (${APP_SLUG})" "${DB_PASSWORD:-${DB_PASSWORD_STAGING:-}}"

if [[ "${DB_MODE}" == "externo" ]]; then
    info "Banco externo em ${DB_HOST} — o wizard vai provisionar automaticamente após salvar o manifest."
    ask DB_ALLOWED_CIDR "CIDR autorizado a acessar o banco (IP da App VPS + /32)" "${DB_ALLOWED_CIDR:-${VPS_HOST}/32}"
    ask DB_BOOTSTRAP_ROOT_PASS "Senha root da VPS do banco para 1ª conexão (vazio se já tem chave SSH)" "${DB_BOOTSTRAP_ROOT_PASS:-}"
fi

step "Chaves SSH"
KEY_DIR="${HOME}/.ssh"
mkdir -p "${KEY_DIR}" && chmod 700 "${KEY_DIR}"

# --- chave deploy (GitHub Actions CI/CD + acesso operator) ---
KEY_PATH="${KEY_DIR}/id_ed25519_${GITHUB_REPO}_deploy"
if [[ ! -f "${KEY_PATH}" ]]; then
    ssh-keygen -t ed25519 -f "${KEY_PATH}" -N "" -C "${GITHUB_OWNER}/${GITHUB_REPO}-deploy" -q
    ok "Chave deploy gerada: ${KEY_PATH}"
else
    ok "Chave deploy existente: ${KEY_PATH}"
fi
DEPLOY_PUBLIC_KEY="$(cat "${KEY_PATH}.pub")"
DEPLOY_PRIVATE_KEY="$(cat "${KEY_PATH}")"

# --- ~/.ssh/config: entrada para a VPS ---
SSH_CONFIG="${HOME}/.ssh/config"
touch "${SSH_CONFIG}" && chmod 600 "${SSH_CONFIG}"
# Remove entrada anterior do mesmo host (evita duplicatas em re-execução)
awk -v host="${VPS_HOST}" '
    /^Host / { in_block = ($2 == host); if (in_block) next }
    in_block && /^[[:space:]]/ { next }
    { in_block = 0; print }
' "${SSH_CONFIG}" > "${SSH_CONFIG}.tmp" && mv "${SSH_CONFIG}.tmp" "${SSH_CONFIG}"
cat >> "${SSH_CONFIG}" << SSHCFG

Host ${VPS_HOST}
    User ${DEPLOY_USER}
    IdentityFile ${KEY_PATH}
    StrictHostKeyChecking accept-new
SSHCFG
ok "~/.ssh/config atualizado — ssh ${DEPLOY_USER}@${VPS_HOST} já funciona com a chave deploy"

refresh_known_host "${VPS_HOST}"
VPS_KNOWN_HOSTS="$(ssh-keyscan -H "${VPS_HOST}" 2>/dev/null || true)"

step "Configurar GitHub (deploy key + secrets)"
GH_OK=false
if command -v gh &>/dev/null && gh auth status --hostname github.com &>/dev/null 2>&1; then
    GH_OK=true
fi

repo="${GITHUB_OWNER}/${GITHUB_REPO}"

if [[ "${GH_OK}" == "true" ]]; then
    # Adiciona deploy key via API (idempotente — compara conteúdo da chave)
    KEY_TITLE="${GITHUB_OWNER}/${GITHUB_REPO}-deploy"
    DEPLOY_KEY_B64="$(echo "${DEPLOY_PUBLIC_KEY}" | awk '{print $2}')"
    existing_key_id="$(gh api "repos/${repo}/keys" 2>/dev/null \
        | grep -B2 "${DEPLOY_KEY_B64}" \
        | grep '"id"' | head -1 | grep -oE '[0-9]+' || true)"

    if [[ -n "${existing_key_id}" ]]; then
        ok "Deploy key já existe no repositório (id=${existing_key_id})"
    else
        gh_err_file="$(mktemp)"
        if gh api --method POST "repos/${repo}/keys" \
            --field title="${KEY_TITLE}" \
            --field key="${DEPLOY_PUBLIC_KEY}" \
            --field read_only=true >/dev/null 2>"${gh_err_file}"; then
            ok "Deploy key adicionada ao GitHub"
        else
            gh_err="$(cat "${gh_err_file}")"
            rm -f "${gh_err_file}"
            if echo "${gh_err}" | grep -qi "already_in_use"; then
                warn "Chave já está em uso em outro repositório ou conta GitHub."
                warn "Opções:"
                warn "  1. Delete a chave antiga: gh api --method DELETE 'user/keys/<id>'"
                warn "  2. Ou gere uma nova: rm ${KEY_PATH} ${KEY_PATH}.pub e reexecute o wizard"
            else
                warn "Erro ao adicionar deploy key: ${gh_err}"
                warn "Adicione manualmente: https://github.com/${repo}/settings/keys/new"
                warn "Chave: ${DEPLOY_PUBLIC_KEY}"
            fi
        fi
        rm -f "${gh_err_file}"
    fi

    # Cria environment e configura secrets/variables
    gh api --method PUT "repos/${repo}/environments/${DEPLOY_ENV}" >/dev/null 2>&1 || true

    gh_secret() {
        local name="$1" value="$2" env="${3:-}"
        if [[ -z "${value}" ]]; then
            warn "Secret ${name} está vazio — pulando (configure manualmente se necessário)"
            return 0
        fi
        if [[ -n "${env}" ]]; then
            printf '%s' "${value}" | gh secret set "${name}" --repo "${repo}" --env "${env}"
        else
            printf '%s' "${value}" | gh secret set "${name}" --repo "${repo}"
        fi
    }
    gh_var() {
        local name="$1" value="$2" env="${3:-}"
        if [[ -z "${value}" ]]; then
            warn "Variable ${name} está vazia — pulando"
            return 0
        fi
        if [[ -n "${env}" ]]; then
            gh variable set "${name}" --repo "${repo}" --env "${env}" --body "${value}"
        else
            gh variable set "${name}" --repo "${repo}" --body "${value}"
        fi
    }

    info "Configurando secrets (environment: ${DEPLOY_ENV})..."
    gh_secret APP_HOST        "${VPS_HOST}"           "${DEPLOY_ENV}"
    gh_secret APP_USER        "${DEPLOY_USER}"        "${DEPLOY_ENV}"
    gh_secret SSH_PRIVATE_KEY "${DEPLOY_PRIVATE_KEY}" "${DEPLOY_ENV}"
    gh_secret SSH_KNOWN_HOSTS "${VPS_KNOWN_HOSTS}"    "${DEPLOY_ENV}"
    gh_secret DOMAIN          "${DOMAIN}"             "${DEPLOY_ENV}"

    info "Configurando variables..."
    gh_var DOMAIN          "${DOMAIN}"
    gh_var GHCR_REPO       "${GHCR_REPO}"
    gh_var PROJECT_NAME    "${PROJECT_NAME}"
    gh_var DEPLOY_PATH     "/opt/${APP_SLUG}/${PROJECT_NAME}"  "${DEPLOY_ENV}"
    gh_var COMPOSE_FILE    "${COMPOSE_FILE_NAME}"         "${DEPLOY_ENV}"

    ok "Secrets/variables de ${DEPLOY_ENV} configurados"
else
    warn "gh CLI não autenticado. Configure manualmente:"
    echo ""
    echo -e "  ${BOLD}1. Deploy key${RESET} — https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/settings/keys/new"
    echo "     Título: ${GITHUB_OWNER}/${GITHUB_REPO}-deploy"
    echo "     Chave:  ${DEPLOY_PUBLIC_KEY}"
    echo ""
    echo -e "  ${BOLD}2. Secrets${RESET} (environment: ${DEPLOY_ENV})"
    echo "     APP_HOST         = ${VPS_HOST}"
    echo "     APP_USER         = ${DEPLOY_USER}"
    echo "     SSH_PRIVATE_KEY  = (conteúdo de ${KEY_PATH})"
    echo "     SSH_KNOWN_HOSTS  = (saída de: ssh-keyscan -H ${VPS_HOST})"
    echo "     DOMAIN           = ${DOMAIN}"
    echo ""
    echo -e "  ${BOLD}3. Variables${RESET} (repositório)"
    echo "     GHCR_REPO    = ${GHCR_REPO}"
    echo "     PROJECT_NAME = ${PROJECT_NAME}"
    echo ""
    echo -e "  ${BOLD}4. Variables${RESET} (environment: ${DEPLOY_ENV})"
    echo "     DEPLOY_PATH  = /opt/${APP_SLUG}/${PROJECT_NAME}"
    echo "     COMPOSE_FILE = ${COMPOSE_FILE_NAME}"
    echo ""
    read -r -p "  Pressione ENTER após configurar manualmente..."
fi

step "Salvar manifest.env"
ask_secret_suggest REDIS_PASSWORD "Senha Redis" "${REDIS_PASSWORD:-${REDIS_PASSWORD_STAGING:-}}"
ask BACKUP_TABLES "Tabelas para backup seletivo no DO Spaces (vazio = banco inteiro, ex: users,orders)" "${BACKUP_TABLES:-}"
{
    emit_manifest_var PROJECT_NAME "$PROJECT_NAME"
    emit_manifest_var DEPLOY_ENV "$DEPLOY_ENV"
    emit_manifest_var APP_SLUG "$APP_SLUG"
    emit_manifest_var GHCR_REPO "$GHCR_REPO"
    emit_manifest_var GITHUB_OWNER "$GITHUB_OWNER"
    emit_manifest_var GITHUB_REPO_NAME "$GITHUB_REPO"
    emit_manifest_var DOMAIN "$DOMAIN"
    emit_manifest_var ACME_EMAIL "$ACME_EMAIL"
    emit_manifest_var VPS_HOST "$VPS_HOST"
    emit_manifest_var VPS_USER "$VPS_USER"
    emit_manifest_var DEPLOY_USER "$DEPLOY_USER"
    emit_manifest_var DEPLOY_USER_PASS "${DEPLOY_USER_PASS:-}"
    emit_manifest_var VPS_DEPLOY_USER "$DEPLOY_USER"
    emit_manifest_var DB_MODE "$DB_MODE"
    emit_manifest_var GITHUB_DEPLOY_PUBLIC_KEY "$DEPLOY_PUBLIC_KEY"
    emit_manifest_var DB_ENGINE "$DB_ENGINE"
    emit_manifest_var DB_HOST "$DB_HOST"
    emit_manifest_var DB_PORT "$DB_PORT"
    emit_manifest_var DB_ROOT_USER "$DB_ROOT_USER"
    emit_manifest_var DB_ROOT_PASS "$DB_ROOT_PASS"
    emit_manifest_var DB_ALLOWED_HOST "%"
    emit_manifest_var DB_ALLOWED_CIDR "${DB_ALLOWED_CIDR:-${VPS_HOST}/32}"
    emit_manifest_var DB_NAME "$DB_NAME"
    emit_manifest_var DB_USER "$DB_USER"
    emit_manifest_var DB_PASSWORD "$DB_PASSWORD"
    emit_manifest_var REDIS_PASSWORD "$REDIS_PASSWORD"
    emit_manifest_var ENABLE_PGADMIN "${ENABLE_PGADMIN:-false}"
    emit_manifest_var PGADMIN_DOMAIN "${PGADMIN_DOMAIN:-pgadmin.${DOMAIN}}"
    emit_manifest_var PGADMIN_DEFAULT_EMAIL "${PGADMIN_DEFAULT_EMAIL:-admin@${DOMAIN}}"
    emit_manifest_var PGADMIN_DEFAULT_PASSWORD "${PGADMIN_DEFAULT_PASSWORD:-}"
    emit_manifest_var BACKUP_TABLES "${BACKUP_TABLES:-}"
    if [[ "${DB_MODE}" == "externo" ]]; then
        DB_SSH_KEY_PATH="${HOME}/.ssh/id_ed25519_${GITHUB_REPO}_db"
        emit_manifest_var DB_SSH_KEY_PATH "${DB_SSH_KEY_PATH}"
        emit_manifest_var DB_BOOTSTRAP_ROOT_PASS "${DB_BOOTSTRAP_ROOT_PASS:-}"
    fi
} > "$MANIFEST_OUT"
chmod 600 "$MANIFEST_OUT"
ok "manifest salvo em ${MANIFEST_OUT}"

# SSH helpers — provisioning usa root (StrictHostKeyChecking=no: máquina nova pode ter key diferente)
# pós-prov usa deploy+chave admin (accept-new: key já conhecida após provisionar)
SSH_ROOT="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ServerAliveCountMax=6"
SCP_ROOT="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SSH_DEPLOY="ssh -o StrictHostKeyChecking=accept-new -i ${KEY_PATH} -o ServerAliveInterval=30 -o ServerAliveCountMax=6"
SCP_DEPLOY="scp -o StrictHostKeyChecking=accept-new -i ${KEY_PATH}"

# Detecta estado da VPS: deploy+chave já funciona (pós-prov) ou precisa provisionar
_deploy_ssh_ok=false
if ${SSH_DEPLOY} -o ConnectTimeout=8 -o BatchMode=yes "${DEPLOY_USER}@${VPS_HOST}" "exit 0" >/dev/null 2>&1; then
    _deploy_ssh_ok=true
fi

# Detecta se a instância específica (APP_SLUG) já foi provisionada no VPS
_app_provisioned=false
if [[ "${_deploy_ssh_ok}" == "true" ]]; then
    if ${SSH_DEPLOY} -o ConnectTimeout=8 -o BatchMode=yes "${DEPLOY_USER}@${VPS_HOST}" \
        "test -f /opt/${APP_SLUG}/${PROJECT_NAME}/.env" >/dev/null 2>&1; then
        _app_provisioned=true
    fi
fi

_install_compose=false

if [[ "${_app_provisioned}" == "false" ]]; then
    if ask_yn "Provisionar App VPS agora?"; then
        PROVISION_MODE="normal"
        ask_choice PROVISION_MODE "Modo de provisionamento (normal|reset)" "normal" normal reset

        if [[ "${PROVISION_MODE}" == "reset" ]]; then
            warn "Reset da instância '${APP_SLUG}': remove /opt/${APP_SLUG}/${PROJECT_NAME} (não remove banco)"
            if [[ "${_deploy_ssh_ok}" == "true" ]]; then
                ${SSH_DEPLOY} "${DEPLOY_USER}@${VPS_HOST}" "
                    set -euo pipefail
                    APP_SLUG='${APP_SLUG}'
                    PROJECT_NAME='${PROJECT_NAME}'

                    if [ -d \"/opt/\${APP_SLUG}/\${PROJECT_NAME}\" ] && [ -f \"/opt/\${APP_SLUG}/\${PROJECT_NAME}/docker-compose.yml\" ]; then
                        cd \"/opt/\${APP_SLUG}/\${PROJECT_NAME}\" && docker compose -p \"myapp-\${APP_SLUG}\" down --remove-orphans || true
                    fi

                    rm -rf \"/opt/\${APP_SLUG}/\${PROJECT_NAME}\"
                    mkdir -p \"/opt/\${APP_SLUG}/\${PROJECT_NAME}\"
                "
            else
                ${SSH_ROOT} "${VPS_USER}@${VPS_HOST}" "
                    set -euo pipefail
                    APP_SLUG='${APP_SLUG}'
                    PROJECT_NAME='${PROJECT_NAME}'

                    if [ -d \"/opt/\${APP_SLUG}/\${PROJECT_NAME}\" ] && [ -f \"/opt/\${APP_SLUG}/\${PROJECT_NAME}/docker-compose.yml\" ]; then
                        cd \"/opt/\${APP_SLUG}/\${PROJECT_NAME}\" && docker compose -p \"myapp-\${APP_SLUG}\" down --remove-orphans || true
                    fi

                    rm -rf \"/opt/\${APP_SLUG}/\${PROJECT_NAME}\"
                    mkdir -p \"/opt/\${APP_SLUG}/\${PROJECT_NAME}\"
                "
            fi
            ok "Reset concluído para ${APP_SLUG}"
        fi

        # Usa deploy+chave se SSH já funciona (VPS base já provisionada, nova instância)
        # Usa root caso contrário (provisionamento inicial do VPS)
        _SSH_PROV="${SSH_ROOT}"
        _SCP_PROV="${SCP_ROOT}"
        _SSH_PROV_TARGET="${VPS_USER}@${VPS_HOST}"
        if [[ "${_deploy_ssh_ok}" == "true" ]]; then
            _SSH_PROV="${SSH_DEPLOY}"
            _SCP_PROV="${SCP_DEPLOY}"
            _SSH_PROV_TARGET="${DEPLOY_USER}@${VPS_HOST}"
        fi

        ${_SSH_PROV} "${_SSH_PROV_TARGET}" "mkdir -p /tmp/vps-provisioning"
        ${_SCP_PROV} -r "${SCRIPT_DIR}/provisioning/." "${_SSH_PROV_TARGET}:/tmp/vps-provisioning/"
        ${_SCP_PROV} "${MANIFEST_OUT}" "${_SSH_PROV_TARGET}:/tmp/vps-provisioning/manifest.env"
        ${_SSH_PROV} "${_SSH_PROV_TARGET}" "bash /tmp/vps-provisioning/validate-prereqs.sh /tmp/vps-provisioning/manifest.env"
        if [[ "${DB_MODE}" == "local" ]]; then
            ${_SSH_PROV} "${_SSH_PROV_TARGET}" "DB_ENGINE='${DB_ENGINE}' bash /tmp/vps-provisioning/setup-db-host.sh /tmp/vps-provisioning/manifest.env"
            ok "Banco local provisionado (${DB_ENGINE})"
        fi
        ${_SSH_PROV} "${_SSH_PROV_TARGET}" "APP_SLUG='${APP_SLUG}' bash /tmp/vps-provisioning/setup-app-host.sh /tmp/vps-provisioning/manifest.env"
        ok "App VPS provisionado — root SSH desabilitado, use a chave admin daqui em diante"
        _install_compose=true
    fi
else
    info "Instância '${APP_SLUG}' já provisionada em /opt/${APP_SLUG}/${PROJECT_NAME} — pulando provisionamento."
fi

if [[ "${DB_MODE}" == "externo" ]]; then
    step "Provisionar banco externo (${DB_HOST})"
    PROVISION_DB_ARGS=("--host" "${DB_HOST}" "--manifest" "${MANIFEST_OUT}" "--no-backup")
    [[ -n "${DB_BOOTSTRAP_ROOT_PASS:-}" ]] && PROVISION_DB_ARGS+=("--bootstrap-password" "${DB_BOOTSTRAP_ROOT_PASS}")
    bash "${SCRIPT_DIR}/automation/provision-external-db.sh" "${PROVISION_DB_ARGS[@]}"
    ok "Banco externo provisionado"
fi

if [[ "${_install_compose}" == "true" ]] || ask_yn "Instalar compose files e iniciar Traefik no VPS agora?"; then
    ${SSH_DEPLOY} "${DEPLOY_USER}@${VPS_HOST}" "mkdir -p '${REMOTE_WORKDIR}'"
    ${SCP_DEPLOY} -r "${SCRIPT_DIR}/." "${DEPLOY_USER}@${VPS_HOST}:${REMOTE_WORKDIR}/"
    ${SSH_DEPLOY} "${DEPLOY_USER}@${VPS_HOST}" "sudo env START_SERVICES=true bash ${REMOTE_WORKDIR}/automation/install-compose-on-host.sh ${REMOTE_WORKDIR}/manifest.${DEPLOY_ENV}.env"
    ok "Compose files instalados — Traefik e app iniciados"
fi

step "Backup automático (DO Spaces)"
_backup_target_host="${VPS_HOST}"
_backup_target_user="${DEPLOY_USER}"
[[ "${DB_MODE}" == "externo" ]] && _backup_target_host="${DB_HOST}" && _backup_target_user="root"
if ask_yn "Configurar backup automático no DO Spaces para ${DEPLOY_ENV}?"; then
    BACKUP_S3_ENDPOINT="${BACKUP_S3_ENDPOINT:-}"
    BACKUP_S3_BUCKET="${BACKUP_S3_BUCKET:-}"
    if [[ -z "${BACKUP_S3_ENDPOINT}" || -z "${BACKUP_S3_BUCKET}" ]]; then
        warn "Variáveis BACKUP_S3_* não configuradas no manifest — backup não instalado."
        warn "Preencha o bloco BACKUP_S3_* no ${MANIFEST_OUT} e re-execute:"
        warn "  DEPLOY_ENV=${DEPLOY_ENV} ./automation/install-backup-cron.sh"
    else
        _BACKUP_SSH="ssh -o StrictHostKeyChecking=accept-new -i ${KEY_PATH} -o ServerAliveInterval=30"
        _BACKUP_SCP="scp -o StrictHostKeyChecking=accept-new -i ${KEY_PATH}"
        if [[ "${DB_MODE}" == "externo" ]]; then
            DB_KEY_PATH="${HOME}/.ssh/id_ed25519_${GITHUB_REPO}_db"
            [[ -f "${DB_KEY_PATH}" ]] && _BACKUP_SSH="ssh -o StrictHostKeyChecking=accept-new -i ${DB_KEY_PATH} -o ServerAliveInterval=30" && _BACKUP_SCP="scp -o StrictHostKeyChecking=accept-new -i ${DB_KEY_PATH}"
        fi
        REMOTE_BACKUP_TMP="/tmp/vps-backup-$$"
        ${_BACKUP_SSH} "${_backup_target_user}@${_backup_target_host}" "mkdir -p ${REMOTE_BACKUP_TMP}"
        ${_BACKUP_SCP} \
            "${SCRIPT_DIR}/automation/backup-db.sh" \
            "${SCRIPT_DIR}/automation/install-backup-cron.sh" \
            "${SCRIPT_DIR}/automation/run-backup-all.sh" \
            "${SCRIPT_DIR}/provisioning/common.sh" \
            "${MANIFEST_OUT}" \
            "${_backup_target_user}@${_backup_target_host}:${REMOTE_BACKUP_TMP}/"
        ${_BACKUP_SSH} "${_backup_target_user}@${_backup_target_host}" \
            "chmod +x ${REMOTE_BACKUP_TMP}/backup-db.sh ${REMOTE_BACKUP_TMP}/install-backup-cron.sh ${REMOTE_BACKUP_TMP}/run-backup-all.sh && \
             command -v aws >/dev/null 2>&1 || apt-get install -y awscli 2>/dev/null || true && \
             CRON_USER=root bash ${REMOTE_BACKUP_TMP}/install-backup-cron.sh ${REMOTE_BACKUP_TMP}/$(basename "${MANIFEST_OUT}") && \
             rm -rf ${REMOTE_BACKUP_TMP}"
        ok "Backup cron instalado em ${_backup_target_host} — ambiente: ${DEPLOY_ENV}"
    fi
else
    info "Backup não configurado. Para instalar depois:"
    info "  DEPLOY_ENV=${DEPLOY_ENV} ./automation/install-backup-cron.sh ${MANIFEST_OUT}"
fi

echo ""
ok "Setup concluído — environment: ${DEPLOY_ENV} | diretório: /opt/${APP_SLUG}/${PROJECT_NAME}"
info "Ambiente: production | push em main aciona o deploy via GitHub Actions"
echo ""
echo -e "  ${BOLD}Acesso à VPS:${RESET}"
echo -e "  ${CYAN}ssh ${DEPLOY_USER}@${VPS_HOST}${RESET}"
info "  Chave deploy (CI/CD + operator): ${KEY_PATH}"
