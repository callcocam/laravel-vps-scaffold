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
| `init.sh` | Renomeia o projeto (token `myapp` → seu slug) |
| `docs/base-laravel-deploy-blueprint.md` | Documento que explica todas as decisões e a origem (siscom) |

> O nome do projeto é o token **`myapp`** em todos os arquivos. Rode `./init.sh <slug>` para trocá-lo.

## Como usar num projeto novo

```bash
# 1. Crie o app Laravel (qualquer starter; ou API-only)
composer create-project laravel/laravel meu-app
cd meu-app

# 2. Traga os arquivos do scaffold para dentro do app
#    (copie docker/, docker-compose.yml, Dockerfile.prod, .dockerignore,
#     .github/, vps-deployment/, init.sh — mescle .env.example e .gitignore)

# 3. Renomeie o projeto
./init.sh meu-app

# 4. Suba o ambiente local
docker network create web      # uma vez (rede do Traefik); ou exponha o nginx via ports
cp .env.example .env
docker compose up -d
docker compose exec php php artisan key:generate
docker compose exec php php artisan migrate
# App: http://meu-app.localhost   |  Mailpit: http://localhost:8027
```

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
- **Portas locais:** ajustadas para não colidir entre projetos (Postgres `5434`, Redis `6381`,
  Mailpit `1027/8027`, pgAdmin `5052`). Veja `docker/DOCKER.md`.
