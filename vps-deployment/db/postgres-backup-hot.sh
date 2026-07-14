#!/usr/bin/env bash
# postgres-backup-hot.sh — tier RÁPIDO (padrão: a cada 30min).
#
# Só as tabelas "quentes" do domínio (BACKUP_HOT_TABLES), as que mudam o tempo todo.
# Percorre TODOS os bancos dos donos configurados — landlord + cada tenant — descobrindo
# banco novo sozinho quando um cliente novo chega.
#
# Roda como usuário OS `postgres` (peer auth: sem login/senha no script; `postgres` é
# superuser e conecta em qualquer banco local).
#
# USO:
#   BACKUP_CONFIG_FILE=/etc/<projeto>/tenant-backup.env postgres-backup-hot.sh [banco]
#   [banco] opcional: roda só nesse banco (teste em 1 tenant / reprocessamento pontual).
#
# RESTORE:
#   tar xzf <timestamp>.tar.gz -C /tmp/restore
#   pg_restore --dbname "<banco>" --verbose --disable-triggers /tmp/restore/<tabela>.tar

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/postgres-backup-lib.sh"

TIER_NAME="hot"

# Interseção entre as tabelas quentes configuradas e as que existem de fato no banco
# (o landlord normalmente não tem nenhuma → o banco é pulado, sem erro).
select_tables_for_db() {
    local database="$1"
    local wanted=() existing=() w e

    read -ra wanted <<< "$(backup_split_list "${BACKUP_HOT_TABLES}")"
    mapfile -t existing < <(backup_existing_tables "${database}")

    for w in "${wanted[@]}"; do
        for e in "${existing[@]}"; do
            [[ "${w}" == "${e}" ]] && { echo "${w}"; break; }
        done
    done
}

backup_load_config
TIER_RETENTION="${BACKUP_HOT_RETENTION_COUNT:-48}"   # 48 x 30min = 24h de histórico

if [[ -z "${BACKUP_HOT_TABLES}" ]]; then
    backup_log "BACKUP_HOT_TABLES vazio — tier rápido desativado (só o tier completo roda). Saindo."
    exit 0
fi

run_backup_tier "${1:-}"
