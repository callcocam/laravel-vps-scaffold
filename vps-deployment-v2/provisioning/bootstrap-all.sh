#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
MANIFEST_PATH="${1:-}"
DB_ENGINE="${DB_ENGINE:-pgsql}"

if [[ -z "${MANIFEST_PATH}" ]]; then
    echo "Uso: ./bootstrap-all.sh /path/to/manifest.env"
    exit 1
fi

echo "[bootstrap] Iniciando provisionamento completo da VPS..."
echo "[bootstrap] Etapa 1/3 — Validando pré-requisitos"
"${SCRIPT_DIR}/validate-prereqs.sh" "${MANIFEST_PATH}"

echo "[bootstrap] Etapa 2/3 — Provisionando host da aplicação"
"${SCRIPT_DIR}/setup-app-host.sh" "${MANIFEST_PATH}"

echo "[bootstrap] Etapa 3/3 — Provisionando banco de dados (engine: ${DB_ENGINE})"
DB_ENGINE="${DB_ENGINE}" "${SCRIPT_DIR}/setup-db-host.sh" "${MANIFEST_PATH}"

echo "[bootstrap] Tudo pronto! VPS provisionada com sucesso."
