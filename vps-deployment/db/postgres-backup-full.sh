#!/usr/bin/env bash
# postgres-backup-full.sh — tier COMPLETO (padrão: 1x/dia de madrugada).
#
# Todas as tabelas de cada banco, exceto as efêmeras do framework (BACKUP_EXCLUDED_TABLES:
# cache/sessão/fila/migrations — nada com valor de restore). Percorre TODOS os bancos dos
# donos configurados: landlord + cada tenant, descobertos automaticamente.
#
# Roda como usuário OS `postgres` (peer auth: sem login/senha no script).
#
# USO:
#   BACKUP_CONFIG_FILE=/etc/<projeto>/tenant-backup.env postgres-backup-full.sh [banco]
#   [banco] opcional: roda só nesse banco (teste em 1 tenant / reprocessamento pontual).
#
# RESTORE:
#   tar xzf <timestamp>.tar.gz -C /tmp/restore
#   pg_restore --dbname "<banco>" --verbose --disable-triggers /tmp/restore/<tabela>.tar

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/postgres-backup-lib.sh"

TIER_NAME="full"

select_tables_for_db() {
    local database="$1"
    local excluded=() existing=() e x skip

    read -ra excluded <<< "$(backup_split_list "${BACKUP_EXCLUDED_TABLES}")"
    mapfile -t existing < <(backup_existing_tables "${database}")

    for e in "${existing[@]}"; do
        skip=0
        for x in "${excluded[@]}"; do
            [[ "${e}" == "${x}" ]] && { skip=1; break; }
        done
        (( skip == 0 )) && echo "${e}"
    done
}

backup_load_config
TIER_RETENTION="${BACKUP_FULL_RETENTION_COUNT:-14}"   # 14 dias de histórico

run_backup_tier "${1:-}"
