#!/usr/bin/env bash
# init.sh — Aplica o scaffold a um projeto Laravel novo.
#
# O scaffold usa o token "myapp" como nome do projeto em todos os arquivos.
# Este script troca "myapp" pelo slug do seu projeto e (opcional) ajusta o domínio.
#
# Uso:
#   ./init.sh                       # modo interativo
#   ./init.sh <slug> [dominio]      # ex: ./init.sh loja loja.example.com
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "${SCRIPT_DIR}"

SLUG="${1:-}"
DOMAIN="${2:-}"

if [[ -z "${SLUG}" ]]; then
    read -r -p "Slug do projeto (a-z0-9-, ex: loja): " SLUG
fi

if [[ ! "${SLUG}" =~ ^[a-z][a-z0-9-]{1,40}$ ]]; then
    echo "Slug inválido: '${SLUG}'. Use [a-z][a-z0-9-], começando por letra." >&2
    exit 1
fi

if [[ "${SLUG}" == "myapp" ]]; then
    echo "O slug não pode ser 'myapp' (é o placeholder). Escolha outro nome." >&2
    exit 1
fi

# Arquivos a transformar (texto), ignorando .git, node_modules, vendor e este script.
mapfile -t FILES < <(grep -rIl 'myapp' . \
    --exclude-dir=.git \
    --exclude-dir=node_modules \
    --exclude-dir=vendor \
    --exclude='init.sh' 2>/dev/null || true)

if [[ "${#FILES[@]}" -eq 0 ]]; then
    echo "Nenhuma ocorrência de 'myapp' encontrada — scaffold já foi inicializado?"
else
    for f in "${FILES[@]}"; do
        sed -i "s/myapp/${SLUG}/g" "$f"
    done
    echo "✔ '${SLUG}' aplicado em ${#FILES[@]} arquivo(s)."
fi

# Ajuste opcional de domínio local (myapp.localhost -> slug.localhost já foi trocado acima).
if [[ -n "${DOMAIN}" ]]; then
    if [[ -f .env.example ]]; then
        sed -i "s#APP_URL=http://${SLUG}.localhost#APP_URL=http://${SLUG}.localhost  # prod: https://${DOMAIN}#" .env.example || true
    fi
    echo "✔ Domínio de produção sugerido: ${DOMAIN} (configure no wizard: vps-deployment-v2/setup.sh)"
fi

cat <<EOF

Pronto. Próximos passos:

  1. Copie estes arquivos para dentro do seu app Laravel (ou use este repo como base).
  2. Local:
       docker network create web   # se ainda não existir (Traefik)
       cp .env.example .env
       docker compose up -d
       docker compose exec php php artisan key:generate
       docker compose exec php php artisan migrate
     App: http://${SLUG}.localhost   |  Mailpit: http://localhost:8027
  3. Produção: bash vps-deployment-v2/setup.sh

Remova/realize o init: este script não se auto-deleta. Apague-o se quiser.
EOF
