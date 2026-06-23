#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../provisioning/common.sh"

MANIFEST_PATH="${1:-}"

if [[ -z "${MANIFEST_PATH}" ]]; then
    if ! MANIFEST_PATH="$(find_manifest "${SCRIPT_DIR}/..")"; then
        echo "[ERROR] Nenhum manifest encontrado. Passe: ./run-backup-all.sh /path/to/manifest.env" >&2
        exit 1
    fi
    echo "[INFO] Usando manifest: ${MANIFEST_PATH}"
fi

RETENTION_DAYS="${RETENTION_DAYS:-14}"

# Extrai o ambiente do manifest para exibir no log
_env="$(grep -E '^(DEPLOY_ENV|APP_SLUG)=' "${MANIFEST_PATH}" 2>/dev/null | head -1 | cut -d= -f2 | tr -d "'\"")"
echo "[INFO] Rodando backup do banco — ambiente: ${_env:-desconhecido} (retenção: ${RETENTION_DAYS} dias)"
"${SCRIPT_DIR}/backup-db.sh" "${MANIFEST_PATH}"

echo "[OK] Backup concluído — ambiente: ${_env:-desconhecido}"
