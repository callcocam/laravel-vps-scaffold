#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# ROOT_DIR pode ser sobrescrito via variável de ambiente (útil quando o script é copiado pra /tmp/)
ROOT_DIR="${ROOT_DIR:-$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)}"

MANIFEST_PATH="${1:-}"
if [[ -n "${MANIFEST_PATH}" ]]; then
    if [[ ! -f "${MANIFEST_PATH}" ]]; then
        echo "[ERRO] Manifest não encontrado: ${MANIFEST_PATH}"
        exit 1
    fi
    # shellcheck disable=SC1090
    source "${MANIFEST_PATH}"
    echo "[INFO] Manifest carregado: ${MANIFEST_PATH}"
fi

DEPLOY_USER="${DEPLOY_USER:-root}"
APP_SLUG="${APP_SLUG:-production}"
PROJECT_NAME="${PROJECT_NAME:-myapp}"
START_SERVICES="${START_SERVICES:-false}"
APP_DIR="/opt/${APP_SLUG}/${PROJECT_NAME}"

if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERRO] Este script precisa rodar como root."
    exit 1
fi

# Usa o usuário correto: se for root ou se o usuário não existir no sistema, opera como root
_dir_owner() {
    if [[ "${DEPLOY_USER}" == "root" ]] || ! id "${DEPLOY_USER}" >/dev/null 2>&1; then
        echo "root"
    else
        echo "${DEPLOY_USER}"
    fi
}
EFFECTIVE_USER="$(_dir_owner)"

echo "[INFO] Criando diretórios de destino para app e traefik (dono: ${EFFECTIVE_USER})"
if [[ "${EFFECTIVE_USER}" == "root" ]]; then
    install -d -m 750 "${APP_DIR}"
else
    install -d -m 750 -o "${EFFECTIVE_USER}" -g "${EFFECTIVE_USER}" "${APP_DIR}"
fi
install -d -m 755 /opt/traefik
install -d -m 700 /opt/traefik/letsencrypt
touch /opt/traefik/letsencrypt/acme.json
chmod 600 /opt/traefik/letsencrypt/acme.json

_compose_src="${ROOT_DIR}/deployments/docker-compose.${APP_SLUG}.yml"
if [[ ! -f "${_compose_src}" ]]; then
    _compose_src="${ROOT_DIR}/deployments/docker-compose.production.yml"
fi
echo "[INFO] Copiando docker-compose.${APP_SLUG}.yml para ${APP_DIR}/docker-compose.yml"
cp "${_compose_src}" "${APP_DIR}/docker-compose.yml"

echo "[INFO] Copiando docker-compose do Traefik para /opt/traefik/docker-compose.yml"
cp "${ROOT_DIR}/deployments/traefik/docker-compose.yml" /opt/traefik/docker-compose.yml

chown "${EFFECTIVE_USER}:${EFFECTIVE_USER}" "${APP_DIR}/docker-compose.yml"
chmod 640 "${APP_DIR}/docker-compose.yml"

if [[ "${START_SERVICES}" == "true" ]]; then
    echo "[INFO] START_SERVICES=true — subindo Traefik e app agora"
    docker network create traefik-global >/dev/null 2>&1 || true

    echo "[traefik] Iniciando reverse proxy..."
    (cd /opt/traefik && docker compose up -d)

    _traefik_up=false
    for _i in $(seq 1 15); do
        if docker inspect --format '{{.State.Running}}' traefik-global 2>/dev/null | grep -q true; then
            _traefik_up=true
            break
        fi
        sleep 2
    done
    if [[ "${_traefik_up}" == "true" ]]; then
        echo "[traefik] Rodando — HTTPS e roteamento ativos"
    else
        echo "[traefik] AVISO: container não subiu em 30s — verifique: docker logs traefik-global"
    fi

    echo "[app] Baixando imagem da aplicação myapp-${APP_SLUG}..."
    echo "[app] (Se for o primeiro deploy a imagem pode ainda não existir no registry — tudo bem)"
    if (cd "${APP_DIR}" && docker compose -p "myapp-${APP_SLUG}" pull 2>&1); then
        (cd "${APP_DIR}" && docker compose -p "myapp-${APP_SLUG}" up -d)
        echo "[app] myapp-${APP_SLUG} iniciado com sucesso"
    else
        echo "[app] AVISO: pull da imagem falhou (ainda não publicada?). Traefik está rodando. Faça o primeiro deploy via GitHub Actions."
    fi
fi

echo "[OK] Arquivos Compose instalados em ${APP_DIR} e /opt/traefik"
