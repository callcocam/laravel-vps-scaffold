#!/usr/bin/env bash
# run-install-compose.sh — instala os Compose files na VPS a partir da máquina local
#
# Faz tudo: copia os scripts e os docker-compose para a VPS e executa remotamente.
# Rode a partir de qualquer lugar — ele resolve os caminhos automaticamente.
#
# Uso (de dentro de ~/projects/myapp):
#   ./vps-deployment/automation/run-install-compose.sh [--start]
#
# --start: sobe Traefik e app imediatamente após instalar os Compose files

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
MANIFEST_PATH="${ROOT_DIR}/manifest.env"

if [[ ! -f "${MANIFEST_PATH}" ]]; then
    echo "[ERRO] manifest.env não encontrado em ${MANIFEST_PATH}"
    exit 1
fi

# shellcheck disable=SC1090
source "${MANIFEST_PATH}"

VPS_HOST="${VPS_HOST:-}"
DEPLOY_USER="${DEPLOY_USER:-root}"
START_SERVICES=false
[[ "${1:-}" == "--start" ]] && START_SERVICES=true

if [[ -z "${VPS_HOST}" ]]; then
    echo "[ERRO] VPS_HOST não definido no manifest.env"
    exit 1
fi

SSH_TARGET="${DEPLOY_USER}@${VPS_HOST}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
REMOTE_TMP="/tmp/vps-compose-$$"

echo "[INFO] VPS: ${SSH_TARGET}"
echo "[INFO] START_SERVICES: ${START_SERVICES}"

# ── Cria estrutura de diretórios remotos ──────────────────────────────────────
echo "[INFO] Preparando diretório temporário na VPS: ${REMOTE_TMP}"
ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" "mkdir -p ${REMOTE_TMP}/deployments/traefik"

# ── Copia todos os arquivos necessários ───────────────────────────────────────
echo "[INFO] Copiando script de instalação"
scp "${SSH_OPTS[@]}" \
    "${SCRIPT_DIR}/install-compose-on-host.sh" \
    "${SSH_TARGET}:${REMOTE_TMP}/"

echo "[INFO] Copiando docker-compose da aplicação"
scp "${SSH_OPTS[@]}" \
    "${ROOT_DIR}/deployments/docker-compose.production.yml" \
    "${SSH_TARGET}:${REMOTE_TMP}/deployments/"

echo "[INFO] Copiando docker-compose do Traefik"
scp "${SSH_OPTS[@]}" \
    "${ROOT_DIR}/deployments/traefik/docker-compose.yml" \
    "${SSH_TARGET}:${REMOTE_TMP}/deployments/traefik/"

# ── Executa remotamente com ROOT_DIR apontando pro tmp ───────────────────────
echo "[INFO] Executando install-compose-on-host.sh na VPS"
ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" \
    "ROOT_DIR=${REMOTE_TMP} DEPLOY_USER=${DEPLOY_USER} APP_SLUG=${APP_SLUG:-production} START_SERVICES=${START_SERVICES} bash ${REMOTE_TMP}/install-compose-on-host.sh"

# ── Limpeza ───────────────────────────────────────────────────────────────────
echo "[INFO] Removendo arquivos temporários da VPS"
ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" "rm -rf ${REMOTE_TMP}"

echo "[OK] Compose files instalados na VPS com sucesso!"
echo ""
echo "Próximos passos:"
echo "  - Fazer o primeiro deploy via GitHub Actions, ou"
echo "  - Re-rodar com --start para subir Traefik e app agora:"
echo "    ./vps-deployment/automation/run-install-compose.sh --start"
