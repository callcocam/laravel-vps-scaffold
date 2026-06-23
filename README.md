# Laravel VPS Scaffold

Ambiente **pré-configurado** para projetos Laravel: Docker local + deploy em VPS, **stack-agnóstico**
(funciona com Blade puro, Livewire, Inertia+Vue/React ou API-only) e **sem multitenancy** — uma conexão
de banco, um domínio.

Este repositório contém **só o ambiente** (Docker, CI/CD, provisionamento de VPS). Você o aplica sobre
um app Laravel limpo e começa a desenvolver.

## O que tem aqui

| Caminho | O quê |
|---------|-------|
| `docker-compose.yml` + `docker/` | Stack local: nginx, php-fpm, worker de fila, Postgres, Redis, pgAdmin, Mailpit (via Traefik em `*.localhost`) |
| `Dockerfile.prod` | Imagem única de produção (php-fpm + nginx + supervisor) |
| `.env.example` | Variáveis alinhadas com o stack (Postgres + Redis) |
| `.github/workflows/` | CI (`tests`) + deploy (`build-push`, `deploy-production`, `rollback`) |
| `vps-deployment/` | Wizard de provisionamento + automações (Traefik, Let's Encrypt, backup, health-check) |
| `init.sh` | Aplica o provisionamento ao app (copia a infra, troca `myapp` → seu slug, prepara o ambiente local) |
| `docs/base-laravel-deploy-blueprint.md` | Documento que explica todas as decisões e a origem (siscom) |

> Este repo é **só o provisionamento**: você o clona para dentro de um app Laravel e roda o `init.sh`,
> que copia a infra para a raiz do app e troca o token **`myapp`** pelo seu slug. O repo do
> provisionamento permanece intacto (com `myapp`), então é reutilizável em outros projetos.

## Como usar num projeto novo

```bash
# 1. Crie o app Laravel (qualquer starter; ou API-only)
composer create-project laravel/laravel meu-app
cd meu-app

# 2. Clone o provisionamento para dentro do app
git clone <repo-do-provisionamento> provisioning

# 3. Aplique o provisionamento (copia a infra, troca myapp → slug, prepara o .env,
#    copia um guia para README.provisioning.md e pergunta se quer subir os containers).
#    Slug default = nome da pasta do app.
./provisioning/init.sh meu-app
# App: http://meu-app.localhost   |  Mailpit: http://localhost:8027
```

O `init.sh` detecta a raiz do app automaticamente (procura `artisan`/`composer.json`), copia
`docker/`, `docker-compose.yml`, `Dockerfile.prod`, `.dockerignore`, `.github/` e `vps-deployment/`,
cria `README.provisioning.md` no app com as instruções do scaffold, faz backup do `.env`/`.env.example`
originais e adiciona o bloco de segredos ao `.gitignore`. Antes de subir, ele também verifica conflito
de portas locais e orienta ajustar as variáveis `*_FORWARD_PORT` no `.env` quando necessário. Se
preferir não subir os containers na hora, ele imprime os comandos no final.

Como `vps-deployment/`, `.github/` e os arquivos do Docker são copiados para a raiz do app, o deploy
na VPS roda direto de lá (`bash vps-deployment/setup.sh`). Ao final, o `init.sh` ainda **oferece
apagar o clone `provisioning/`**, já redundante.

## Deploy em VPS

```bash
bash vps-deployment/setup.sh
```

O wizard provisiona a VPS (Docker, UFW, fail2ban, SSH hardening, Traefik + Let's Encrypt), gera o `.env`
de produção e configura os secrets do GitHub. Daí, **push em `main`** dispara build da imagem (GHCR) e
deploy automático. Veja `vps-deployment/README.md` para detalhes e troubleshooting.

## Decisões / sem-tenant

- **Banco:** uma conexão (`DB_CONNECTION`, Postgres por padrão; MySQL via `DB_ENGINE`).
- **Migração no deploy:** `php artisan migrate --force` (sem landlord/tenant).
- **Domínio único:** sem roteamento por subdomínio, sem baking de domínio no build.
- **Fila/cache/sessão:** Redis (`queue:work redis`, sem Horizon).

Detalhes e a rationale completa em [docs/base-laravel-deploy-blueprint.md](docs/base-laravel-deploy-blueprint.md).

## Ajustes por stack

- **Sem frontend buildado (Blade puro / API-only):** no `Dockerfile.prod`, remova o bloco do Node e o
  `npm ci && npm run build`. O workflow `tests` e `Dockerfile.prod` já são tolerantes à ausência de `package.json`.
- **Com Vite (Inertia/Vue/React/Livewire+Vite):** mantenha tudo como está.
- **Portas locais:** configuráveis por `.env` (`POSTGRES_FORWARD_PORT`, `PGADMIN_FORWARD_PORT`,
  `REDIS_FORWARD_PORT`, `MAILPIT_SMTP_FORWARD_PORT`, `MAILPIT_UI_FORWARD_PORT`). Defaults: Postgres
  `5434`, Redis `6381`, Mailpit `1027/8027`, pgAdmin `5052`. Se alguma já estiver em uso, o `init.sh`
  encontra a próxima porta livre, sugere e oferece gravar a alternativa no `.env`. Veja `docker/DOCKER.md`.
