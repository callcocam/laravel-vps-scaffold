#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

MANIFEST_PATH="${1:-}"
DB_ENGINE="${DB_ENGINE:-pgsql}"
DB_MODE="${DB_MODE:-local}"
DRY_RUN="${DRY_RUN:-false}"

if [[ -z "${MANIFEST_PATH}" ]]; then
    log_error "Usage: DB_ENGINE=pgsql|mysql ./setup-db-host.sh /path/to/manifest.env"
    exit 1
fi

require_root
load_manifest "${MANIFEST_PATH}"

DB_NAME="${DB_NAME:-${DB_NAME_STAGING:-${DB_NAME_PRODUCTION:-}}}"
DB_USER="${DB_USER:-${DB_USER_STAGING:-${DB_USER_PRODUCTION:-}}}"
DB_PASSWORD="${DB_PASSWORD:-${DB_PASSWORD_STAGING:-${DB_PASSWORD_PRODUCTION:-}}}"

required_vars=()

if [[ "${DB_MODE}" == "externo" ]]; then
    required_vars+=(DB_ALLOWED_CIDR)
fi

for var_name in "${required_vars[@]}"; do
    if [[ -z "${!var_name:-}" ]]; then
        log_error "Missing required variable in manifest: ${var_name}"
        exit 1
    fi
done

if [[ -z "${DB_NAME}" || -z "${DB_USER}" || -z "${DB_PASSWORD}" ]]; then
    log_error "Missing DB_NAME/DB_USER/DB_PASSWORD in manifest."
    exit 1
fi

run_cmd() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        printf '[DRY_RUN] %s\n' "$*"
    else
        eval "$@"
    fi
}

if [[ "${DB_MODE}" == "local" ]]; then
    DB_ALLOWED_HOST="${DB_ALLOWED_HOST:-localhost}"
else
    DB_ALLOWED_HOST="${DB_ALLOWED_HOST:-%}"
fi

log_info "Parando o atualizador automático do Ubuntu pra liberar o apt — mesmo processo que no host da app"
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

log_info "Atualizando lista de pacotes e instalando ufw, fail2ban e rsync"
run_cmd "apt-get -o DpkgLock::Timeout=120 update"
run_cmd "DEBIAN_FRONTEND=noninteractive apt-get install -y ufw fail2ban rsync"

if [[ "${DB_ENGINE}" == "mysql" ]]; then
    log_info "Instalando MySQL — isso pode demorar alguns minutos"
    MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-$(random_secret)}"
    run_cmd "DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-server"

    if [[ "${DRY_RUN}" != "true" ]]; then
        log_info "Configurando MySQL para escutar em todas as interfaces e aceitar até 300 conexões"
        MYSQL_BIND_ADDRESS="0.0.0.0"
        cat > /etc/mysql/mysql.conf.d/zz-vps-v2.cnf <<CFG
[mysqld]
bind-address = ${MYSQL_BIND_ADDRESS}
max_connections = 300
innodb_buffer_pool_size = 1G
CFG
    fi

    run_cmd "systemctl restart mysql"

    if [[ "${DRY_RUN}" != "true" ]]; then
        log_info "Criando banco '${DB_NAME}' e usuário '${DB_USER}' no MySQL"
        mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'${DB_ALLOWED_HOST}' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'${DB_ALLOWED_HOST}';
GRANT CREATE, DROP ON *.* TO '${DB_USER}'@'${DB_ALLOWED_HOST}';
FLUSH PRIVILEGES;
SQL
        if [[ "${DB_MODE}" == "local" ]]; then
            log_info "Modo local — adicionando permissão para rede Docker (172.x)"
            mysql -uroot <<SQL
CREATE USER IF NOT EXISTS '${DB_USER}'@'172.%' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'172.%';
GRANT CREATE, DROP ON *.* TO '${DB_USER}'@'172.%';
FLUSH PRIVILEGES;
SQL
        fi

        log_info "Salvando credenciais em /root/.db-credentials-v2 (modo 600)"
        write_file_secure "/root/.db-credentials-v2" "root:root" "600" "DB_ENGINE=mysql
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
"
    fi
elif [[ "${DB_ENGINE}" == "pgsql" ]]; then
    log_info "Instalando PostgreSQL — isso pode demorar alguns minutos"
    run_cmd "DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql postgresql-contrib"

    if [[ "${DRY_RUN}" != "true" ]]; then
        PG_VERSION=$(ls /etc/postgresql | sort -V | tail -n1)
        log_info "PostgreSQL ${PG_VERSION} instalado — configurando listen_addresses e conexões máximas"
        PG_LISTEN_ADDRESSES="'*'"
        cat > "/etc/postgresql/${PG_VERSION}/main/conf.d/vps-v2.conf" <<CFG
listen_addresses = ${PG_LISTEN_ADDRESSES}
max_connections = 300
CFG

        if [[ "${DB_MODE}" == "externo" ]]; then
            log_info "Modo externo — liberando acesso ao CIDR ${DB_ALLOWED_CIDR} no pg_hba.conf"
            grep -qxF "host all all ${DB_ALLOWED_CIDR} scram-sha-256" \
                "/etc/postgresql/${PG_VERSION}/main/pg_hba.conf" || \
                echo "host all all ${DB_ALLOWED_CIDR} scram-sha-256" >> "/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"
        else
            log_info "Modo local — liberando acesso à rede Docker (172.16.0.0/12) no pg_hba.conf"
            grep -qxF "host all all 172.16.0.0/12 scram-sha-256" \
                "/etc/postgresql/${PG_VERSION}/main/pg_hba.conf" || \
                echo "host all all 172.16.0.0/12 scram-sha-256" >> "/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"
        fi
    fi

    run_cmd "systemctl restart postgresql"

    if [[ "${DRY_RUN}" != "true" ]]; then
        log_info "Criando role '${DB_USER}' e banco '${DB_NAME}' no PostgreSQL"
        sudo -u postgres psql <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
        CREATE ROLE ${DB_USER} LOGIN CREATEDB PASSWORD '${DB_PASSWORD}';
    ELSE
        ALTER ROLE ${DB_USER} WITH LOGIN CREATEDB PASSWORD '${DB_PASSWORD}';
    END IF;
END
\$\$;
SQL
        sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 || sudo -u postgres createdb --owner="${DB_USER}" "${DB_NAME}"
        sudo -u postgres psql -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};"
        sudo -u postgres psql -d "${DB_NAME}" <<SQL
GRANT USAGE, CREATE ON SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};
SQL

        log_info "Salvando credenciais em /root/.db-credentials-v2 (modo 600)"
        write_file_secure "/root/.db-credentials-v2" "root:root" "600" "DB_ENGINE=pgsql
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
"
    fi
else
    log_error "DB_ENGINE inválido: '${DB_ENGINE}'. Use 'mysql' ou 'pgsql'."
    exit 1
fi

log_info "Configurando firewall — porta do banco liberada só para o CIDR autorizado, o resto bloqueado"
run_cmd "ufw default deny incoming"
run_cmd "ufw default allow outgoing"
run_cmd "ufw allow 22/tcp"

if [[ "${DB_MODE}" == "externo" ]]; then
    if [[ "${DB_ENGINE}" == "mysql" ]]; then
        run_cmd "ufw allow from ${DB_ALLOWED_CIDR} to any port 3306 proto tcp"
        log_info "MySQL: porta 3306 liberada para ${DB_ALLOWED_CIDR}"
    else
        run_cmd "ufw allow from ${DB_ALLOWED_CIDR} to any port 5432 proto tcp"
        log_info "PostgreSQL: porta 5432 liberada para ${DB_ALLOWED_CIDR}"
    fi
else
    if [[ "${DB_ENGINE}" == "mysql" ]]; then
        run_cmd "ufw allow from 172.16.0.0/12 to any port 3306 proto tcp"
        log_info "MySQL: porta 3306 liberada para rede Docker (172.16.0.0/12)"
    else
        run_cmd "ufw allow from 172.16.0.0/12 to any port 5432 proto tcp"
        log_info "PostgreSQL: porta 5432 liberada para rede Docker (172.16.0.0/12)"
    fi
fi
run_cmd "ufw --force enable"

log_info "Configurando fail2ban — protege o SSH contra força bruta (5 tentativas = 1h de ban)"
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
        log_info "IP do operador (${OPERATOR_IP}) na whitelist do fail2ban — você não vai se autobanir"
    fi
fi

log_success "Banco de dados provisionado com sucesso!"
log_info "Credenciais salvas em /root/.db-credentials-v2"
