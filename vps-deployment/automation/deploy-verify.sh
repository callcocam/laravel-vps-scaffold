#!/usr/bin/env bash

set -euo pipefail

APP_SLUG="${1:-production}"
APP_NAME="${APP_NAME:-myapp}"
APP_DIR="/opt/${APP_SLUG}/${APP_NAME}"
PROJECT_NAME="myapp-${APP_SLUG}"
EXPECTED_ASSET="${2:-}"

fail_count=0
warn_count=0

ok() { echo "[OK] $*"; }
warn() { echo "[WARN] $*"; warn_count=$((warn_count + 1)); }
fail() { echo "[FAIL] $*"; fail_count=$((fail_count + 1)); }

require_cmd() {
    if command -v "$1" >/dev/null 2>&1; then
        return
    fi

    fail "Comando obrigatório ausente: $1"
}

status_code() {
    curl -sS -o /dev/null -w '%{http_code}' "$1" || true
}

echo "=== Verificação pós-deploy (${APP_SLUG}) ==="
echo "Horário: $(date -Iseconds)"

require_cmd docker
require_cmd curl
require_cmd grep
require_cmd sed

if [[ ! -d "${APP_DIR}" ]]; then
    fail "Diretório não encontrado: ${APP_DIR}"
    echo "Falhas: ${fail_count}"
    exit 2
fi

if [[ ! -f "${APP_DIR}/docker-compose.yml" ]]; then
    fail "Arquivo docker-compose.yml ausente em ${APP_DIR}"
    echo "Falhas: ${fail_count}"
    exit 2
fi

if [[ ! -f "${APP_DIR}/.env" ]]; then
    fail "Arquivo .env ausente em ${APP_DIR}"
    echo "Falhas: ${fail_count}"
    exit 2
fi

cd "${APP_DIR}"

echo
echo "--- Contexto ---"
DOMAIN="$(grep -E '^DOMAIN=' .env | tail -n1 | cut -d'=' -f2- || true)"
IMAGE_TAG="$(grep -E '^IMAGE_TAG=' .env | tail -n1 | cut -d'=' -f2- || true)"
ENV_APP_SLUG="$(grep -E '^APP_SLUG=' .env | tail -n1 | cut -d'=' -f2- || true)"

[[ -n "${ENV_APP_SLUG}" ]] && ok "APP_SLUG=${ENV_APP_SLUG}" || warn "APP_SLUG não encontrado no .env"
[[ -n "${IMAGE_TAG}" ]] && ok "IMAGE_TAG=${IMAGE_TAG}" || warn "IMAGE_TAG não encontrado no .env"
[[ -n "${DOMAIN}" ]] && ok "DOMAIN=${DOMAIN}" || warn "DOMAIN não encontrado no .env"

echo
echo "--- Containers ---"
docker compose -p "${PROJECT_NAME}" ps || fail "Falha ao listar containers do projeto ${PROJECT_NAME}"

if docker compose -p "${PROJECT_NAME}" ps --status running --services | grep -q '^app$'; then
    ok "Serviço app em execução"
else
    fail "Serviço app não está em execução"
fi

echo
echo "--- Build Frontend (dentro do container) ---"
# Checagens de frontend buildado (Vite). Em apps API-only / Blade puro, isso não se aplica:
# tratamos como aviso, não falha.
if docker compose -p "${PROJECT_NAME}" exec -T app sh -lc 'test -f /var/www/public/build/manifest.json'; then
    ok "manifest.json encontrado"
else
    warn "manifest.json não encontrado em /var/www/public/build (ok se o app não tem frontend buildado)"
fi

if docker compose -p "${PROJECT_NAME}" exec -T app sh -lc 'test -d /var/www/public/build/assets'; then
    ok "Diretório assets encontrado"
else
    warn "Diretório /var/www/public/build/assets não encontrado (ok se o app não tem frontend buildado)"
fi

APP_JS=""
if [[ -z "${EXPECTED_ASSET}" ]]; then
    APP_JS="$(docker compose -p "${PROJECT_NAME}" exec -T app sh -lc "grep -m1 -E '\"file\": \"assets/app-.*\\.js\"' /var/www/public/build/manifest.json | sed -E 's/.*assets\\/(app-[^\"\\]+\\.js).*/\\1/'" || true)"
else
    APP_JS="${EXPECTED_ASSET}"
fi

if [[ -n "${APP_JS}" ]]; then
    if docker compose -p "${PROJECT_NAME}" exec -T app sh -lc "test -f /var/www/public/build/assets/${APP_JS}"; then
        ok "Asset principal encontrado: ${APP_JS}"
    else
        fail "Asset principal não encontrado: ${APP_JS}"
    fi
else
    warn "Não foi possível derivar asset app-*.js do manifest"
fi

echo
echo "--- Health interno ---"
INTERNAL_UP="$(docker compose -p "${PROJECT_NAME}" exec -T app sh -lc 'curl -sS -o /dev/null -w "%{http_code}" http://127.0.0.1/up || true' || true)"
if [[ "${INTERNAL_UP}" == "200" ]]; then
    ok "GET /up interno = 200"
else
    fail "GET /up interno retornou ${INTERNAL_UP:-erro}"
fi

INTERNAL_MANIFEST="$(docker compose -p "${PROJECT_NAME}" exec -T app sh -lc 'curl -sS -o /dev/null -w "%{http_code}" http://127.0.0.1/build/manifest.json || true' || true)"
if [[ "${INTERNAL_MANIFEST}" == "200" ]]; then
    ok "GET /build/manifest.json interno = 200"
else
    warn "GET /build/manifest.json interno retornou ${INTERNAL_MANIFEST:-erro} (ok se sem frontend buildado)"
fi

if [[ -n "${APP_JS}" ]]; then
    INTERNAL_ASSET="$(docker compose -p "${PROJECT_NAME}" exec -T app sh -lc "curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1/build/assets/${APP_JS} || true" || true)"
    if [[ "${INTERNAL_ASSET}" == "200" ]]; then
        ok "GET /build/assets/${APP_JS} interno = 200"
    else
        fail "GET /build/assets/${APP_JS} interno retornou ${INTERNAL_ASSET:-erro}"
    fi
fi

echo
echo "--- Health externo ---"
if [[ -n "${DOMAIN}" ]]; then
    EXTERNAL_MANIFEST="$(status_code "https://${DOMAIN}/build/manifest.json")"
    if [[ "${EXTERNAL_MANIFEST}" == "200" ]]; then
        ok "GET externo /build/manifest.json = 200"
    else
        warn "GET externo /build/manifest.json retornou ${EXTERNAL_MANIFEST:-erro} (ok se sem frontend buildado)"
    fi

    if [[ -n "${APP_JS}" ]]; then
        EXTERNAL_ASSET="$(status_code "https://${DOMAIN}/build/assets/${APP_JS}")"
        if [[ "${EXTERNAL_ASSET}" == "200" ]]; then
            ok "GET externo /build/assets/${APP_JS} = 200"
        else
            fail "GET externo /build/assets/${APP_JS} retornou ${EXTERNAL_ASSET:-erro}"
        fi

        echo "Headers (externo asset):"
        curl -sS -I "https://${DOMAIN}/build/assets/${APP_JS}" | sed -n '1,15p' || true
    fi
else
    warn "DOMAIN ausente no .env; pulando checks externos"
fi

echo
echo "--- Migrações (somente status) ---"
if docker compose -p "${PROJECT_NAME}" exec -T app sh -lc 'php artisan migrate:status >/dev/null'; then
    ok "migrate:status executado"
else
    warn "Falha em migrate:status"
fi

echo
echo "--- Logs rápidos ---"
echo "app (tail 40)"
docker compose -p "${PROJECT_NAME}" logs app --tail=40 || true
echo
echo "queue (tail 40)"
docker compose -p "${PROJECT_NAME}" logs queue --tail=40 || true

echo
echo "--- Resumo ---"
echo "Avisos: ${warn_count}"
echo "Falhas: ${fail_count}"

if [[ "${fail_count}" -gt 0 ]]; then
    echo "Status: FALHOU"
    exit 2
fi

if [[ "${warn_count}" -gt 0 ]]; then
    echo "Status: OK COM AVISOS"
    exit 1
fi

echo "Status: TUDO CERTO"
exit 0