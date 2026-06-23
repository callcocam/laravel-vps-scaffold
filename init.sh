#!/usr/bin/env bash
# init.sh — Aplica o provisionamento a um app Laravel e configura o ambiente local.
#
# Este repositório é SÓ o provisionamento (Docker, CI/CD, deploy VPS). O fluxo é:
#
#   composer create-project laravel/laravel meu-app
#   cd meu-app
#   git clone <repo-do-provisionamento> provisioning
#   ./provisioning/init.sh meu-app
#
# O script copia os arquivos de infra para a raiz do app, troca o token "myapp"
# pelo slug do projeto NOS ARQUIVOS COPIADOS (o provisionamento fica intacto e
# reutilizável) e prepara o ambiente local. A VPS é configurada depois, via
# vps-deployment/setup.sh.
#
# Uso:
#   ./provisioning/init.sh                 # interativo (slug = nome da pasta do app)
#   ./provisioning/init.sh <slug>          # ex: ./provisioning/init.sh loja
#   ./provisioning/init.sh <slug> <target> # target = raiz do app Laravel (default: detectado)
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# --- saída bonitinha -------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
step() { echo -e "\n${BOLD}${CYAN}▶ $*${RESET}"; }
ok()   { echo -e "  ${GREEN}✔ $*${RESET}"; }
warn() { echo -e "  ${YELLOW}⚠ $*${RESET}"; }
die()  { echo -e "  ${RED}✘ $*${RESET}" >&2; exit 1; }

# --- argumentos ------------------------------------------------------------
SLUG="${1:-}"
TARGET="${2:-}"

# --- localiza a raiz do app Laravel ---------------------------------------
is_laravel_root() { [[ -f "$1/artisan" && -f "$1/composer.json" ]]; }

if [[ -z "${TARGET}" ]]; then
    # 1) diretório atual  2) pai do provisionamento (meu-app/provisioning -> meu-app)
    if is_laravel_root "${PWD}"; then
        TARGET="${PWD}"
    elif is_laravel_root "$(dirname -- "${SCRIPT_DIR}")"; then
        TARGET="$(dirname -- "${SCRIPT_DIR}")"
    fi
fi

[[ -n "${TARGET}" ]] || die "App Laravel não encontrado. Rode de dentro do app (com 'artisan') ou passe o caminho: ./init.sh <slug> <caminho-do-app>"
TARGET="$(cd -- "${TARGET}" >/dev/null 2>&1 && pwd)" || die "Caminho inválido: ${2:-}"
is_laravel_root "${TARGET}" || die "'${TARGET}' não parece um app Laravel (faltam 'artisan'/'composer.json')."

if [[ "${TARGET}" == "${SCRIPT_DIR}" ]]; then
    die "O provisionamento não pode ser o próprio app. Clone-o como subpasta do app (ex: meu-app/provisioning) e rode dali."
fi

# --- slug ------------------------------------------------------------------
if [[ -z "${SLUG}" ]]; then
    DEFAULT_SLUG="$(basename -- "${TARGET}")"
    read -r -p "Slug do projeto (a-z0-9-) [${DEFAULT_SLUG}]: " SLUG
    SLUG="${SLUG:-${DEFAULT_SLUG}}"
fi
[[ "${SLUG}" =~ ^[a-z][a-z0-9-]{1,40}$ ]] || die "Slug inválido: '${SLUG}'. Use [a-z][a-z0-9-], começando por letra."
[[ "${SLUG}" != "myapp" ]] || die "O slug não pode ser 'myapp' (é o placeholder). Escolha outro nome."

step "Provisionamento → ${BOLD}${TARGET}${RESET}${CYAN} (slug: ${BOLD}${SLUG}${RESET}${CYAN})"

# --- 1. copia os arquivos de infra para a raiz do app ----------------------
DEPLOY_ITEMS=(docker docker-compose.yml Dockerfile.prod .dockerignore .github vps-deployment)
step "Copiando arquivos de infra"
for item in "${DEPLOY_ITEMS[@]}"; do
    src="${SCRIPT_DIR}/${item}"
    [[ -e "${src}" ]] || { warn "ausente no provisionamento: ${item} (pulado)"; continue; }
    cp -a "${src}" "${TARGET}/"
    ok "${item}"
done

README_TARGET="${TARGET}/README.provisioning.md"
if [[ -f "${README_TARGET}" ]]; then
    cp -a "${README_TARGET}" "${README_TARGET}.bak"
    warn "README.provisioning.md existente salvo em README.provisioning.md.bak"
fi
cp -a "${SCRIPT_DIR}/README.md" "${README_TARGET}"
ok "README.provisioning.md"

# --- 2. .env.example / .env -----------------------------------------------
step "Configurando .env"
if [[ -f "${TARGET}/.env.example" ]] && ! cmp -s "${SCRIPT_DIR}/.env.example" "${TARGET}/.env.example"; then
    cp -a "${TARGET}/.env.example" "${TARGET}/.env.example.laravel.bak"
    warn ".env.example original salvo em .env.example.laravel.bak"
fi
cp -a "${SCRIPT_DIR}/.env.example" "${TARGET}/.env.example"
ok ".env.example (stack Postgres + Redis)"

if [[ -f "${TARGET}/.env" ]]; then
    cp -a "${TARGET}/.env" "${TARGET}/.env.bak"
    warn ".env existente salvo em .env.bak (será recriado para a stack do Docker)"
fi
cp -a "${SCRIPT_DIR}/.env.example" "${TARGET}/.env"
ok ".env"

# --- 3. .gitignore (segredos do deploy) ------------------------------------
step "Atualizando .gitignore"
GI="${TARGET}/.gitignore"
MARKER="# >>> laravel-vps-scaffold >>>"
if [[ -f "${GI}" ]] && grep -qF "${MARKER}" "${GI}"; then
    ok ".gitignore já tem o bloco do provisionamento"
else
    {
        echo ""
        echo "${MARKER}"
        echo "# Segredos de deploy — NUNCA commitar"
        echo "vps-deployment/manifest.env"
        echo "vps-deployment/manifest.*.env"
        echo "!vps-deployment/templates/manifest.example.env"
        echo "# <<< laravel-vps-scaffold <<<"
    } >> "${GI}"
    ok "bloco de segredos adicionado ao .gitignore"
fi

# --- 4. troca o token myapp -> slug (só nos arquivos copiados) -------------
step "Aplicando slug '${SLUG}'"
mapfile -t FILES < <(cd "${TARGET}" && grep -rIl 'myapp' "${DEPLOY_ITEMS[@]}" .env .env.example 2>/dev/null || true)
if [[ "${#FILES[@]}" -eq 0 ]]; then
    warn "nenhuma ocorrência de 'myapp' encontrada"
else
    for f in "${FILES[@]}"; do
        sed -i "s/myapp/${SLUG}/g" "${TARGET}/${f}"
    done
    ok "'${SLUG}' aplicado em ${#FILES[@]} arquivo(s)"
fi

# --- 5. ambiente local -----------------------------------------------------
step "Preparando ambiente local"
if command -v docker >/dev/null 2>&1; then
    if docker network inspect web >/dev/null 2>&1; then
        ok "rede 'web' (Traefik) já existe"
    else
        docker network create web >/dev/null && ok "rede 'web' (Traefik) criada"
    fi
else
    warn "Docker não encontrado — pulei a criação da rede 'web'"
fi

env_val_or_default() {
    local key="$1"
    local def="$2"
    local val
    val="$(grep -E "^${key}=" "${TARGET}/.env" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
    val="${val%\"}"
    val="${val#\"}"
    [[ -n "${val}" ]] && echo "${val}" || echo "${def}"
}

POSTGRES_FWD_PORT="$(env_val_or_default POSTGRES_FORWARD_PORT 5434)"
PGADMIN_FWD_PORT="$(env_val_or_default PGADMIN_FORWARD_PORT 5052)"
REDIS_FWD_PORT="$(env_val_or_default REDIS_FORWARD_PORT 6381)"
MAILPIT_SMTP_FWD_PORT="$(env_val_or_default MAILPIT_SMTP_FORWARD_PORT 1027)"
MAILPIT_UI_FWD_PORT="$(env_val_or_default MAILPIT_UI_FORWARD_PORT 8027)"

port_in_use() { ss -ltn "( sport = :$1 )" 2>/dev/null | tail -n +2 | grep -q .; }

declare -A CLAIMED=()
# Próxima porta livre >= start (pula portas em uso no host e já reservadas aqui).
find_free_port() {
    local p="$1" tries=0
    while (( tries < 500 )); do
        if [[ -z "${CLAIMED[$p]:-}" ]] && ! port_in_use "$p"; then
            echo "$p"; return 0
        fi
        ((p++)); ((tries++))
    done
    return 1
}
# Upsert KEY=VAL no arquivo .env.
set_env_var() {
    local key="$1" val="$2" file="$3"
    if grep -qE "^${key}=" "${file}" 2>/dev/null; then
        sed -i -E "s#^${key}=.*#${key}=${val}#" "${file}"
    else
        printf '%s=%s\n' "${key}" "${val}" >> "${file}"
    fi
}

PORT_KEYS=(POSTGRES_FORWARD_PORT PGADMIN_FORWARD_PORT REDIS_FORWARD_PORT MAILPIT_SMTP_FORWARD_PORT MAILPIT_UI_FORWARD_PORT)
PORT_LABELS=("Postgres" "pgAdmin" "Redis" "Mailpit SMTP" "Mailpit UI")
PORT_CURRENT=("${POSTGRES_FWD_PORT}" "${PGADMIN_FWD_PORT}" "${REDIS_FWD_PORT}" "${MAILPIT_SMTP_FWD_PORT}" "${MAILPIT_UI_FWD_PORT}")

PORT_CONFLICT=0
declare -a SUGGEST_KEYS=() SUGGEST_VALS=()
if command -v ss >/dev/null 2>&1; then
    step "Verificando conflitos de porta no host"
    for i in "${!PORT_KEYS[@]}"; do
        key="${PORT_KEYS[$i]}"; label="${PORT_LABELS[$i]}"; cur="${PORT_CURRENT[$i]}"
        if [[ -n "${CLAIMED[$cur]:-}" ]] || port_in_use "${cur}"; then
            if new="$(find_free_port "${cur}")"; then
                warn "porta ${cur} em uso (${label}) → sugerida ${new}"
                CLAIMED[$new]=1
                PORT_CURRENT[$i]="${new}"
                SUGGEST_KEYS+=("${key}"); SUGGEST_VALS+=("${new}")
                PORT_CONFLICT=1
            else
                warn "porta ${cur} em uso (${label}) — nenhuma alternativa livre encontrada"
                PORT_CONFLICT=1
            fi
        else
            ok "${label}: ${cur} livre"
            CLAIMED[$cur]=1
        fi
    done

    # Reflete as portas escolhidas nas variáveis usadas adiante.
    POSTGRES_FWD_PORT="${PORT_CURRENT[0]}"; PGADMIN_FWD_PORT="${PORT_CURRENT[1]}"
    REDIS_FWD_PORT="${PORT_CURRENT[2]}";    MAILPIT_SMTP_FWD_PORT="${PORT_CURRENT[3]}"
    MAILPIT_UI_FWD_PORT="${PORT_CURRENT[4]}"

    if [[ "${#SUGGEST_KEYS[@]}" -gt 0 ]]; then
        APPLY="no"
        if [[ -t 0 ]]; then
            read -r -p "$(echo -e "  ${BOLD}Aplicar as portas sugeridas no .env? [Y/n]:${RESET} ")" ans
            [[ "${ans:-Y}" =~ ^[Nn] ]] || APPLY="yes"
        fi
        if [[ "${APPLY}" == "yes" ]]; then
            for j in "${!SUGGEST_KEYS[@]}"; do
                set_env_var "${SUGGEST_KEYS[$j]}" "${SUGGEST_VALS[$j]}" "${TARGET}/.env"
            done
            ok "portas aplicadas no .env"
            PORT_CONFLICT=0
        else
            warn "Sem aplicar — ajuste manualmente no .env antes de subir:"
            for j in "${!SUGGEST_KEYS[@]}"; do
                warn "  ${SUGGEST_KEYS[$j]}=${SUGGEST_VALS[$j]}"
            done
        fi
    elif [[ "${PORT_CONFLICT}" -eq 0 ]]; then
        ok "sem conflitos detectados"
    fi
else
    warn "comando 'ss' não encontrado — pulei a verificação de portas"
fi

UP="no"
if command -v docker >/dev/null 2>&1 && [[ -t 0 ]]; then
    if [[ "${PORT_CONFLICT}" -eq 1 ]]; then
        read -r -p "$(echo -e "  ${BOLD}Conflito detectado. Tentar subir mesmo assim? [y/N]:${RESET} ")" ans
        [[ "${ans:-N}" =~ ^[Yy] ]] && UP="yes"
    else
        read -r -p "$(echo -e "  ${BOLD}Subir os containers agora? [Y/n]:${RESET} ")" ans
        [[ "${ans:-Y}" =~ ^[Nn] ]] || UP="yes"
    fi
fi

if [[ "${UP}" == "yes" ]]; then
    step "Subindo containers"
    (
        cd "${TARGET}"
        docker compose up -d --build
        docker compose exec -T php php artisan key:generate
        docker compose exec -T php php artisan migrate --force
    ) && ok "ambiente no ar" || warn "falha ao subir; rode os passos manualmente (veja abaixo)"
fi

# --- 6. remover o clone do provisionamento (opcional) ----------------------
# Tudo que o app e a VPS precisam (vps-deployment/, .github/, Docker) já foi
# copiado para a raiz do app, então o clone vira redundante.
CLEAN="no"
if [[ -t 0 ]]; then
    read -r -p "$(echo -e "  ${BOLD}Apagar o provisionamento original (${SCRIPT_DIR##*/}/)? [y/N]:${RESET} ")" ans
    [[ "${ans:-N}" =~ ^[Yy] ]] && CLEAN="yes"
fi

# --- pronto ----------------------------------------------------------------
cat <<EOF

$(echo -e "${BOLD}${GREEN}Pronto.${RESET}") Provisionamento aplicado em ${TARGET}

EOF

if [[ "${UP}" != "yes" ]]; then
    cat <<EOF
Para subir o ambiente local:

  cd "${TARGET}"
  docker network create web   # se ainda não existir (Traefik)
  docker compose up -d --build
  docker compose exec php php artisan key:generate
  docker compose exec php php artisan migrate

EOF
fi

cat <<EOF
  App:     http://${SLUG}.localhost
    pgAdmin: http://pgadmin.${SLUG}.localhost   |  Mailpit: http://localhost:${MAILPIT_UI_FWD_PORT}
    Guia:    README.provisioning.md

Deploy na VPS (depois): bash vps-deployment/setup.sh
  (vps-deployment/, .github/ e arquivos Docker já estão na raiz do app)
EOF

# --- limpeza (última ação: o fd do script aberto sobrevive ao rm no Linux) --
if [[ "${CLEAN}" == "yes" ]]; then
    cd "${TARGET}"
    rm -rf "${SCRIPT_DIR}"
    echo -e "  ${GREEN}✔ provisionamento original removido (${SCRIPT_DIR})${RESET}"
fi
