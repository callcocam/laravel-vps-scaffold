#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

MANIFEST_PATH="${1:-}"
DRY_RUN="${DRY_RUN:-false}"

if [[ -z "${MANIFEST_PATH}" ]]; then
    log_error "Usage: ./setup-app-host.sh /path/to/manifest.env"
    exit 1
fi

require_root
load_manifest "${MANIFEST_PATH}"

APP_SLUG="${APP_SLUG:-${APP_NAME:-production}}"
APP_DIR="/opt/myapp/${APP_SLUG}"
APP_ENV="${APP_ENV:-production}"
DOMAIN="${DOMAIN:-${DOMAIN_PRODUCTION:-}}"
DB_MODE="${DB_MODE:-local}"
DB_ENGINE="${DB_ENGINE:-${DB_ENGINE_PRODUCTION:-pgsql}}"
DB_CONNECTION_DEFAULT="${DB_CONNECTION_DEFAULT:-${DB_ENGINE}}"
DB_HOST="${DB_HOST:-${DB_HOST_PRODUCTION:-}}"
DB_PORT="${DB_PORT:-${DB_PORT_PRODUCTION:-}}"
DB_NAME="${DB_NAME:-${DB_NAME_PRODUCTION:-myapp_${APP_SLUG}}}"
DB_USER="${DB_USER:-${DB_USER_PRODUCTION:-myapp_${APP_SLUG}_user}}"
DB_PASSWORD="${DB_PASSWORD:-${DB_PASSWORD_PRODUCTION:-$(random_secret)}}"
if [[ "${DB_ENGINE}" == "pgsql" ]]; then
    DB_CHARSET_VALUE="${DB_CHARSET_VALUE:-utf8}"
else
    DB_CHARSET_VALUE="${DB_CHARSET_VALUE:-utf8mb4}"
fi
REDIS_PASSWORD="${REDIS_PASSWORD:-${REDIS_PASSWORD_PRODUCTION:-$(random_secret)}}"
APP_KEY="${APP_KEY:-base64:$(openssl rand -base64 32)}"

if [[ "${DB_MODE}" == "local" ]]; then
    DB_HOST="${DB_HOST:-host.docker.internal}"
    if [[ -z "${DB_PORT}" ]]; then
        if [[ "${DB_ENGINE}" == "pgsql" ]]; then
            DB_PORT="5432"
        else
            DB_PORT="3306"
        fi
    fi
fi

required_vars=(PROJECT_NAME DEPLOY_USER ACME_EMAIL GHCR_REPO GITHUB_DEPLOY_PUBLIC_KEY)
for var_name in "${required_vars[@]}"; do
    if [[ -z "${!var_name:-}" ]]; then
        log_error "Missing required variable in manifest: ${var_name}"
        exit 1
    fi
done

if [[ -z "${DOMAIN}" || -z "${DB_HOST}" || -z "${DB_NAME}" || -z "${DB_USER}" || -z "${DB_PASSWORD}" ]]; then
    log_error "Missing DOMAIN/DB settings in manifest."
    exit 1
fi

if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "DRY_RUN=true; command execution is disabled."
fi

run_cmd() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        printf '[DRY_RUN] %s\n' "$*"
    else
        eval "$@"
    fi
}

log_info "Parando o atualizador automático do Ubuntu (unattended-upgrades) pra liberar o apt — sem isso os próximos passos travam"
run_cmd "systemctl stop unattended-upgrades apt-daily.service apt-daily-upgrade.service 2>/dev/null || true"
run_cmd "systemctl kill --kill-who=all apt-daily.service apt-daily-upgrade.service 2>/dev/null || true"
run_cmd "fuser -k /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock 2>/dev/null || true"
if [[ "${DRY_RUN}" != "true" ]]; then
    _apt_waited=0
    while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
        echo "Aguardando o apt liberar o lock... (${_apt_waited}s)"
        sleep 3
        _apt_waited=$((_apt_waited + 3))
        if [[ ${_apt_waited} -ge 60 ]]; then
            log_warn "O processo teimou mais de 60s — forçando com SIGKILL"
            fuser -k -9 /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock 2>/dev/null || true
            sleep 2
            break
        fi
    done
fi
run_cmd "dpkg --configure -a 2>/dev/null || true"

log_info "Instalando pacotes essenciais — curl, ufw, fail2ban, jq e clientes de banco"
run_cmd "apt-get -o DpkgLock::Timeout=120 update"
run_cmd "DEBIAN_FRONTEND=noninteractive apt-get upgrade -y"
run_cmd "DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg lsb-release ufw fail2ban jq unzip openssl mysql-client postgresql-client"

log_info "Instalando o Docker — motor de containers que vai rodar toda a aplicação"
run_cmd "install -m 0755 -d /etc/apt/keyrings"
run_cmd "rm -f /etc/apt/keyrings/docker.gpg"
run_cmd "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
run_cmd "chmod a+r /etc/apt/keyrings/docker.gpg"
run_cmd "echo 'deb [arch='\"$(dpkg --print-architecture)\"' signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu '$(. /etc/os-release && echo "$VERSION_CODENAME")' stable' > /etc/apt/sources.list.d/docker.list"
run_cmd "apt-get update"
run_cmd "DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

if [[ "${DEPLOY_USER}" == "root" ]]; then
    log_info "DEPLOY_USER=root — sem criação de usuário extra, o root já tem tudo que precisa"
    DEPLOY_HOME="/root"
    run_cmd "usermod -aG docker root 2>/dev/null || true"

    log_info "Adicionando a chave pública de deploy ao authorized_keys do root"
    run_cmd "install -d -m 700 /root/.ssh"
    run_cmd "touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"
    if [[ "${DRY_RUN}" != "true" ]]; then
        if ! grep -Fq "${GITHUB_DEPLOY_PUBLIC_KEY}" /root/.ssh/authorized_keys; then
            printf '%s\n' "${GITHUB_DEPLOY_PUBLIC_KEY}" >> /root/.ssh/authorized_keys
            log_info "Chave deploy adicionada ao authorized_keys do root"
        else
            log_info "Chave deploy já está no authorized_keys — pulando"
        fi
    fi

    log_info "Endurecendo o SSH — desativa login por senha, mantém acesso por chave (PermitRootLogin prohibit-password)"
    if [[ "${DRY_RUN}" != "true" ]]; then
        SSHD_CFG="/etc/ssh/sshd_config"
        SSHD_BACKUP="/etc/ssh/sshd_config.bak-vps-v2"
        cp "${SSHD_CFG}" "${SSHD_BACKUP}"
        grep -Ev '^#?\s*(PermitRootLogin|PasswordAuthentication|MaxAuthTries)\b' "${SSHD_BACKUP}" > "${SSHD_CFG}"
        printf '\n# Added by vps-deployment-v2 setup\nPermitRootLogin prohibit-password\nPasswordAuthentication no\nMaxAuthTries 3\n' >> "${SSHD_CFG}"
        if ! sshd -t -f "${SSHD_CFG}"; then
            log_error "sshd_config inválido — restaurando backup pra não perder o acesso"
            cp "${SSHD_BACKUP}" "${SSHD_CFG}"
        else
            systemctl restart ssh 2>/dev/null || systemctl restart sshd
            log_success "SSH endurecido: sem senha, root só por chave"
        fi
    fi
else
    log_info "Criando usuário '${DEPLOY_USER}' que vai ser o dono dos deploys"
    DEPLOY_HOME="/home/${DEPLOY_USER}"
    if ! id "${DEPLOY_USER}" >/dev/null 2>&1; then
        run_cmd "useradd -m -s /bin/bash ${DEPLOY_USER}"
    else
        log_info "Usuário ${DEPLOY_USER} já existe — pulando criação"
    fi
    run_cmd "usermod -aG docker ${DEPLOY_USER}"
    if [[ "${DRY_RUN}" != "true" && -n "${DEPLOY_USER_PASS:-}" ]]; then
        printf '%s:%s\n' "${DEPLOY_USER}" "${DEPLOY_USER_PASS}" | chpasswd
        log_info "Senha definida para ${DEPLOY_USER} (útil pra acesso via console/KVM)"
    fi

    log_info "Configurando acesso SSH para o usuário '${DEPLOY_USER}' — adicionando a chave de deploy"
    run_cmd "install -d -m 700 -o ${DEPLOY_USER} -g ${DEPLOY_USER} ${DEPLOY_HOME}/.ssh"
    run_cmd "touch ${DEPLOY_HOME}/.ssh/authorized_keys"
    run_cmd "chown ${DEPLOY_USER}:${DEPLOY_USER} ${DEPLOY_HOME}/.ssh/authorized_keys"
    run_cmd "chmod 600 ${DEPLOY_HOME}/.ssh/authorized_keys"
    if [[ "${DRY_RUN}" != "true" ]]; then
        if ! grep -Fq "${GITHUB_DEPLOY_PUBLIC_KEY}" "${DEPLOY_HOME}/.ssh/authorized_keys"; then
            printf '%s\n' "${GITHUB_DEPLOY_PUBLIC_KEY}" >> "${DEPLOY_HOME}/.ssh/authorized_keys"
            log_info "Chave deploy adicionada ao authorized_keys do ${DEPLOY_USER}"
        else
            log_info "Chave deploy já presente — pulando"
        fi
    fi

    log_info "Dando sudo sem senha para '${DEPLOY_USER}' — necessário pra rodar Docker e reiniciar serviços"
    if [[ "${DRY_RUN}" != "true" ]]; then
        printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${DEPLOY_USER}" > /etc/sudoers.d/vps-v2-deploy
        chmod 440 /etc/sudoers.d/vps-v2-deploy
        visudo -cf /etc/sudoers.d/vps-v2-deploy || { rm -f /etc/sudoers.d/vps-v2-deploy; log_error "sudoers inválido — revertido"; exit 1; }
    fi

    log_info "Endurecendo o SSH — desabilita root login e autenticação por senha"
    if [[ "${DRY_RUN}" != "true" ]]; then
        SSHD_CFG="/etc/ssh/sshd_config"
        SSHD_BACKUP="/etc/ssh/sshd_config.bak-vps-v2"
        cp "${SSHD_CFG}" "${SSHD_BACKUP}"
        grep -Ev '^#?\s*(PermitRootLogin|PasswordAuthentication|MaxAuthTries)\b' "${SSHD_BACKUP}" > "${SSHD_CFG}"
        printf '\n# Added by vps-deployment-v2 setup\nPermitRootLogin no\nPasswordAuthentication no\nMaxAuthTries 3\n' >> "${SSHD_CFG}"
        if ! sshd -t -f "${SSHD_CFG}"; then
            log_error "sshd_config inválido — restaurando backup pra não perder o acesso"
            cp "${SSHD_BACKUP}" "${SSHD_CFG}"
        else
            systemctl restart ssh 2>/dev/null || systemctl restart sshd
            log_warn "Login de root via SSH desabilitado. Use '${DEPLOY_USER}' pra se conectar daqui em diante."
            log_info "Backup da config SSH original salvo em ${SSHD_BACKUP}"
        fi
    fi
fi

log_info "Configurando firewall (UFW) — libera 22/SSH, 80/HTTP e 443/HTTPS, bloqueia todo o resto"
run_cmd "ufw default deny incoming"
run_cmd "ufw default allow outgoing"
run_cmd "ufw allow 22/tcp"
run_cmd "ufw allow 80/tcp"
run_cmd "ufw allow 443/tcp"
run_cmd "ufw --force enable"

log_info "Configurando fail2ban — bane IPs que errarem o SSH 5x em 10 minutos por 1 hora"
if [[ "${DRY_RUN}" != "true" ]]; then
    OPERATOR_IP="${OPERATOR_IP:-}"
    if [[ -z "${OPERATOR_IP}" ]]; then
        OPERATOR_IP="$(echo "${SSH_CLIENT:-}" | awk '{print $1}')"
    fi

    mkdir -p /etc/fail2ban/jail.d
    cat > /etc/fail2ban/jail.d/vps-v2-ssh.local << CFG
[sshd]
enabled  = true
port     = ssh
filter   = sshd
maxretry = 5
bantime  = 3600
findtime = 600
ignoreip = 127.0.0.1/8 ::1${OPERATOR_IP:+ ${OPERATOR_IP}}
CFG
    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban
    if [[ -n "${OPERATOR_IP}" ]]; then
        log_info "IP do operador (${OPERATOR_IP}) adicionado à whitelist do fail2ban — você não vai se autobanir"
    fi
fi

log_info "Criando estrutura de diretórios em /opt — app, traefik, backups e monitoramento"
run_cmd "mkdir -p ${APP_DIR} /opt/traefik/letsencrypt /opt/backups"
run_cmd "mkdir -p ${APP_DIR}/storage/framework/views ${APP_DIR}/storage/framework/cache ${APP_DIR}/storage/framework/sessions ${APP_DIR}/bootstrap/cache"
run_cmd "chown -R ${DEPLOY_USER}:${DEPLOY_USER} ${APP_DIR} 2>/dev/null || chown -R root:root ${APP_DIR}"
run_cmd "chmod 750 ${APP_DIR}"
run_cmd "touch /opt/traefik/letsencrypt/acme.json"
run_cmd "chmod 600 /opt/traefik/letsencrypt/acme.json"
run_cmd "docker network create traefik-global >/dev/null 2>&1 || true"

if [[ "${DRY_RUN}" != "true" ]]; then
    if [[ -z "${TRAEFIK_DASHBOARD_BASICAUTH:-}" ]]; then
        TRAEFIK_DASHBOARD_USER="${TRAEFIK_DASHBOARD_USER:-admin}"
        TRAEFIK_DASHBOARD_PASS="${TRAEFIK_DASHBOARD_PASS:-$(random_secret)}"
        _salt="$(openssl rand -base64 6)"
        _hash="$(openssl passwd -apr1 -salt "${_salt}" "${TRAEFIK_DASHBOARD_PASS}")"
        TRAEFIK_DASHBOARD_BASICAUTH="${TRAEFIK_DASHBOARD_USER}:${_hash//\$/\$\$}"
    fi

    log_info "Gerando .env da aplicação em ${APP_DIR}/.env com todas as variáveis de ambiente"
    write_file_secure "${APP_DIR}/.env" "${DEPLOY_USER}:${DEPLOY_USER}" "600" "APP_ENV=${APP_ENV}
APP_DEBUG=false
APP_KEY=${APP_KEY}
APP_URL=https://${DOMAIN}
DOMAIN=${DOMAIN}
APP_SLUG=${APP_SLUG}
GHCR_REPO=${GHCR_REPO}
DB_CONNECTION=${DB_CONNECTION_DEFAULT}
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_CHARSET=${DB_CHARSET_VALUE}
REDIS_HOST=redis
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_PORT=6379
QUEUE_CONNECTION=redis
CACHE_STORE=redis
SESSION_DRIVER=redis
SESSION_CONNECTION=default
REDIS_CACHE_CONNECTION=cache
REDIS_CACHE_LOCK_CONNECTION=default
BROADCAST_CONNECTION=log
IMAGE_TAG=branch-${APP_SLUG}-latest
"

    log_info "Gerando .env do Traefik em /opt/traefik/.env (credenciais do dashboard e ACME)"
    write_file_secure "/opt/traefik/.env" "root:root" "600" "ACME_EMAIL=${ACME_EMAIL}
TRAEFIK_DASHBOARD_HOST=${TRAEFIK_DASHBOARD_HOST:-traefik.${DOMAIN}}
TRAEFIK_DASHBOARD_BASICAUTH=${TRAEFIK_DASHBOARD_BASICAUTH}
"
fi

log_success "Host da aplicação provisionado com sucesso para '${APP_SLUG}'!"
log_info "Diretório da app: ${APP_DIR}"
log_info "Próximo passo: rode install-compose-on-host.sh ou faça o primeiro deploy via GitHub Actions"
