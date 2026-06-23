# Blueprint — Base Laravel + Docker local + Deploy VPS (sem multitenant)

> **Para quem é este documento:** o agente de IA que vai **scaffoldar um projeto base Laravel**
> reaproveitando a infra de container e deploy do `myapp`, **sem a regra de negócio** (fluxo de caixa)
> e **sem multitenancy**. O objetivo é ter um esqueleto pronto pra clonar e começar qualquer app novo.
>
> Este blueprint foi extraído da análise do projeto `myapp` e do diretório `vps-deployment`.
> Tudo que aqui aparece como "conteúdo pronto" já está com as partes de tenant **removidas**.

---

## 1. Objetivo e princípios

Entregar um repositório Laravel **pré-configurado para rodar** com:

- **Local:** `docker compose up` → app + Postgres + Redis + worker de fila + Mailpit, roteado por Traefik em `*.localhost`.
- **Produção:** imagem única (php-fpm + nginx + supervisor) publicada no GHCR e deployada numa VPS via `vps-deployment` (Traefik + Let's Encrypt + GitHub Actions).
- **Banco:** PostgreSQL (engine padrão; MySQL suportado como alternativa).
- **Fila/cache/sessão:** Redis.
- **Frontend:** **livre**. Use o esqueleto padrão do Laravel. A infra de container/deploy é agnóstica de stack — funciona com Blade puro, Livygwire, Inertia+Vue/React, ou API-only. Não acople o deploy a nenhuma escolha de frontend.

**Princípios de corte (o que NÃO entra na base):**

1. **Sem `spatie/laravel-multitenancy`** e sem nenhum conceito de tenant/landlord.
2. **Uma única conexão de banco** (`DB_CONNECTION`), sem `landlord`/`tenant`.
3. **Sem roteamento por subdomínio** (`HostRegexp`/`Route::domain`). Um domínio = uma app.
4. **Sem baking de domínio no build** (o `WAYFINDER_LANDLORD_DOMAIN` existia só por causa do `Route::domain` do tenant). Se você adotar Wayfinder, as URLs ficam relativas e nada precisa ser embutido na imagem.
5. **Sem `tenants:artisan`** nas migrações nem no workflow. Migração é `php artisan migrate --force`.
6. **Sem regra de negócio do myapp** (Account/Category/Transaction, importação OFX/PDF, WhatsApp/Uazapi, Pluggy, Cashier, área admin landlord). Comece do esqueleto limpo do Laravel.

---

## 2. Decisões de stack (defaults da base)

| Item | Decisão |
|------|---------|
| PHP | 8.4 (`php:8.4-fpm`) |
| Laravel | versão estável mais recente (skeleton `laravel/laravel`) |
| Banco | PostgreSQL 17 (default); MySQL 8 opcional via `DB_ENGINE` |
| Cache/Fila/Sessão | Redis 7 |
| Servidor web (prod) | nginx + php-fpm sob supervisor, **uma imagem** |
| Servidor web (local) | nginx (container separado) → php-fpm |
| Proxy/TLS | Traefik (compartilhado), Let's Encrypt em produção |
| Registry | GHCR (`ghcr.io/<owner>/<repo>`) |
| CI/CD | GitHub Actions (build+push, deploy, rollback) |
| Mail (local) | Mailpit |
| E-mail GUI banco (local) | pgAdmin (opcional) |

**Nomenclatura:** troque o slug `myapp` por um placeholder do projeto novo (ex.: `app`). Onde este doc
mostra `myapp`/`myapp-<APP_SLUG>`/`/opt/myapp/...`, parametrize por `PROJECT_NAME`/`APP_SLUG`.
Mantenha o **padrão** de caminhos (`/opt/<project>/<app_slug>`) — só o nome muda.

---

## 3. Estrutura-alvo do repositório

```
.
├── app/ … (esqueleto Laravel padrão)
├── docker/
│   ├── DOCKER.md                 # guia de cópia/portabilidade do stack local
│   ├── nginx/
│   │   ├── default.conf          # nginx LOCAL (php:9000)
│   │   └── prod.conf             # nginx PROD (127.0.0.1:9000, mesma imagem)
│   ├── php/Dockerfile            # imagem de DEV (php-fpm + extensões)
│   └── supervisor/app.conf       # php-fpm + nginx sob supervisord (PROD)
├── docker-compose.yml            # stack LOCAL
├── Dockerfile.prod               # imagem única de PRODUÇÃO
├── .dockerignore
├── .env.example
├── .github/workflows/
│   ├── tests.yml
│   ├── vps-build-push.yml
│   ├── vps-deploy-production.yml
│   └── vps-rollback.yml
└── vps-deployment/            # toolkit de provisionamento + deploy (ver §7)
```

> **Removido em relação ao myapp:** `.github/workflows/vps-tenant-migrate.yml` e qualquer
> migration/config de tenant.

---

## 4. Ambiente local — `docker-compose.yml`

Reaproveita o stack do myapp. Diferenças: nome do projeto, sem dependência de tenant, regra
de roteamento Traefik **sem** `HostRegexp` de subdomínio.

```yaml
name: app   # <-- PROJECT_NAME

services:
  nginx:
    image: nginx:alpine
    depends_on:
      - php
    volumes:
      - ./:/var/www
      - ./docker/nginx/default.conf:/etc/nginx/conf.d/default.conf
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=web"
      - "traefik.http.routers.app-web.rule=Host(`app.localhost`)"
      - "traefik.http.routers.app-web.priority=1"
      - "traefik.http.services.app-web.loadbalancer.server.port=80"
    networks: [internal, web]

  php:
    build:
      context: .
      dockerfile: docker/php/Dockerfile
    user: "1000:1000"
    volumes:
      - ./:/var/www
    working_dir: /var/www
    depends_on:
      postgres: { condition: service_started }
      redis: { condition: service_started }
    networks: [internal]

  # Worker da fila — processa jobs em background. Reaproveita a imagem do php.
  worker:
    build:
      context: .
      dockerfile: docker/php/Dockerfile
    user: "1000:1000"
    command: php artisan queue:work redis --tries=3 --max-time=3600
    restart: unless-stopped
    volumes:
      - ./:/var/www
    working_dir: /var/www
    depends_on:
      postgres: { condition: service_started }
      redis: { condition: service_started }
    networks: [internal]

  postgres:
    image: postgres:17
    environment:
      POSTGRES_DB: app
      POSTGRES_USER: app
      POSTGRES_PASSWORD: app
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "5434:5432"      # ajuste se houver conflito com outros projetos
    networks: [internal]

  pgadmin:
    image: dpage/pgadmin4:9.14
    depends_on: [postgres]
    environment:
      PGADMIN_DEFAULT_EMAIL: '${PGADMIN_DEFAULT_EMAIL:-admin@app.com}'
      PGADMIN_DEFAULT_PASSWORD: '${PGADMIN_DEFAULT_PASSWORD:-password}'
    volumes:
      - pgadmin_data:/var/lib/pgadmin
    ports:
      - "5052:80"
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=web"
      - "traefik.http.routers.app-pgadmin.rule=Host(`pgadmin.app.localhost`)"
      - "traefik.http.routers.app-pgadmin.priority=100"
      - "traefik.http.services.app-pgadmin.loadbalancer.server.port=80"
    networks: [internal, web]

  redis:
    image: redis:7-alpine
    command: redis-server --appendonly yes
    volumes:
      - redis_data:/data
    ports:
      - "6381:6379"
    networks: [internal]

  mailpit:
    image: axllent/mailpit
    ports:
      - "1027:1025"
      - "8027:8025"
    networks: [internal]

volumes:
  postgres_data:
  pgadmin_data:
  redis_data:

networks:
  internal:
  web:
    external: true
    name: web
```

**Pré-requisito local (uma vez):** `docker network create web` e ter o Traefik local rodando na rede `web`.
(Sem Traefik, troque os `labels` por um `ports: ["8080:80"]` no nginx e acesse `http://localhost:8080`.)

### `docker/php/Dockerfile` (imagem de DEV)

Idêntico ao myapp — extensões `pdo_pgsql`, `pdo_mysql`, `gd` (com webp), `redis`. Sem mudanças de tenant:

```dockerfile
FROM php:8.4-fpm
RUN apt-get update && apt-get install -y \
    libpq-dev zip unzip git curl libzip-dev libpng-dev libonig-dev \
    libxml2-dev libjpeg62-turbo-dev libwebp-dev libfreetype6-dev
RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install pdo pdo_pgsql pgsql pdo_mysql mbstring zip exif pcntl gd
RUN pecl install redis && docker-php-ext-enable redis
RUN echo "memory_limit = 512M" > /usr/local/etc/php/conf.d/memory-limit.ini
WORKDIR /var/www
```

### `docker/nginx/default.conf` (local) e `docker/nginx/prod.conf`

Copie **iguais** ao myapp. Única diferença entre eles: `fastcgi_pass php:9000` (local, serviço `php`)
vs `fastcgi_pass 127.0.0.1:9000` (prod, mesma imagem). Não há nada de tenant nesses arquivos.

### `docker/supervisor/app.conf`

Copie **igual** ao myapp (roda `php-fpm -F` + `nginx -g "daemon off;"`). Sem mudanças.

### `docker/DOCKER.md`

Copie o guia do myapp e troque a tabela de nome/portas para o novo slug. Remova qualquer menção a tenant.

---

## 5. Imagem de produção — `Dockerfile.prod`

Base = `Dockerfile.prod` do myapp, **removendo todo o bloco do Wayfinder/domínio** (que só existia
para embutir o domínio do tenant nas rotas geradas). O build de frontend continua, mas **sem build-arg de domínio**.

```dockerfile
FROM php:8.4-fpm

RUN apt-get update && apt-get install -y \
    nginx supervisor libpq-dev zip unzip git curl libzip-dev libpng-dev \
    libonig-dev libxml2-dev libjpeg62-turbo-dev libwebp-dev libfreetype6-dev \
    && rm -rf /var/lib/apt/lists/*

RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install pdo pdo_pgsql pgsql pdo_mysql mbstring zip exif pcntl bcmath gd opcache

RUN pecl install redis && docker-php-ext-enable redis

RUN echo "memory_limit = 512M" > /usr/local/etc/php/conf.d/memory-limit.ini
RUN { \
    echo "opcache.enable=1"; \
    echo "opcache.memory_consumption=256"; \
    echo "opcache.max_accelerated_files=20000"; \
    echo "opcache.validate_timestamps=0"; \
    } > /usr/local/etc/php/conf.d/opcache.ini

# Node só é necessário se o projeto tiver build de assets (Vite). Mantenha se usar frontend buildado.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs && rm -rf /var/lib/apt/lists/*

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
WORKDIR /var/www
COPY . .

# bootstrap/cache e storage são excluídos pelo .dockerignore; o artisan precisa deles pra bootar.
RUN mkdir -p bootstrap/cache storage/framework/views storage/framework/cache storage/framework/sessions

RUN composer install --no-dev --no-interaction --optimize-autoloader --no-scripts

# --- Build de assets (REMOVA este bloco se for API-only / sem frontend buildado) ---
RUN npm ci && npm run build && rm -rf node_modules
# ------------------------------------------------------------------------------------

RUN composer run-script post-autoload-dump || true

RUN chown -R www-data:www-data /var/www \
    && chmod -R 755 storage bootstrap/cache

COPY docker/nginx/prod.conf /etc/nginx/sites-available/default
COPY docker/supervisor/app.conf /etc/supervisor/conf.d/app.conf
RUN mkdir -p /var/log/supervisor

EXPOSE 80
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]
```

**Notas importantes:**
- O myapp instalava dev-deps só pra rodar `wayfinder:generate` (que estava em `require-dev`) e depois
  removia as dev-deps. **Na base, sem Wayfinder, isso some** — instale direto `--no-dev`.
- Se o projeto **não** tiver frontend buildado, remova o Node e o bloco `npm ci && npm run build`.
- Se adotar Wayfinder com domínio único, as URLs ficam **relativas** (sem `Route::domain`), então **não**
  reintroduza nenhum build-arg de domínio.

---

## 6. Configuração Laravel (de-tenant)

Ao partir do esqueleto limpo do Laravel, a maior parte disso já vem pronta. O que **garantir**:

- **`config/database.php`:** uma conexão `pgsql` (e/ou `mysql`) usando `DB_CONNECTION`, `DB_HOST`,
  `DB_DATABASE`, etc. **Sem** conexões `landlord`/`tenant`, **sem** `DB_LANDLORD_*`/`DB_TENANT_*`.
- **Sem** `config/multitenancy.php`, sem `App\Models\Traits\UsesTenantConnection`, sem `Tenant`/`Landlord` models.
- **Migrações:** tudo em `database/migrations/` (sem subpasta `landlord/`).
- **Rotas:** `routes/web.php` sem `Route::domain(...)`. Domínio único.
- **Redis/sessão (alinhar com produção):** garanta que `SESSION_DRIVER=redis` funcione com
  `SESSION_CONNECTION=default` e que exista a conexão `cache` em `config/database.php`
  (`REDIS_CACHE_CONNECTION=cache`). Isso evita o incidente "Redis connection [landlord] not configured".
- Mantenha a rota de health-check `/up` (padrão do Laravel) — o deploy e o healthcheck dependem dela.

### `.env.example` (base)

```env
APP_NAME=App
APP_ENV=local
APP_KEY=
APP_DEBUG=true
APP_URL=http://app.localhost

DB_CONNECTION=pgsql
DB_HOST=postgres
DB_PORT=5432
DB_DATABASE=app
DB_USERNAME=app
DB_PASSWORD=app

REDIS_HOST=redis
REDIS_PORT=6379

QUEUE_CONNECTION=redis
CACHE_STORE=redis
SESSION_DRIVER=redis
SESSION_CONNECTION=default
REDIS_CACHE_CONNECTION=cache
BROADCAST_CONNECTION=log

MAIL_MAILER=smtp
MAIL_HOST=mailpit
MAIL_PORT=1025
```

---

## 7. Deploy VPS — `vps-deployment`

Copie o diretório `vps-deployment/` do myapp e aplique os cortes abaixo. A arquitetura permanece:
**setup.sh (wizard) → provisiona VPS (Docker, UFW, fail2ban, SSH hardening, Traefik) → grava `.env` e
secrets do GitHub → push em `main` dispara build+deploy**.

### 7.1 O que MANTER como está

- `provisioning/setup-app-host.sh` (estrutura de dirs, Docker, UFW, fail2ban, SSH hardening) — **exceto** o bloco do `.env` (ver 7.3).
- `provisioning/setup-db-host.sh`, `provisioning/common.sh`, `provisioning/validate-prereqs.sh`.
- `automation/*` (backup DO Spaces, health-check, install-compose, cron) — backup já é por tabela/banco inteiro, agnóstico de tenant. Só ajuste `BACKUP_TABLES` (remova exemplos `tenants,...`).
- `deployments/traefik/docker-compose.yml` — Traefik compartilhado, **sem mudança**.
- Estrutura de caminhos `/opt/<project>/<app_slug>` e o naming `-p <project>-<app_slug>`.

### 7.2 O que REMOVER / SIMPLIFICAR

| Arquivo | Ação |
|---------|------|
| `.github/workflows/vps-tenant-migrate.yml` | **Deletar** |
| `manifest.*.env` / `templates/manifest.example.env` | Remover `DB_LANDLORD_*`, `DB_TENANT_DATABASE`, `DOMAIN_LANDLORD`. Renomear `DOMAIN_LANDLORD` → `DOMAIN`. |
| `templates/.env.production.example` | Já é single-conn no myapp; só confirme que não tem `*_LANDLORD_*`. |
| README/SECURITY/GITHUB-ENVIRONMENTS | Remover seções de Spatie/landlord/tenant e a linha do workflow `tenant-migrate`. |

### 7.3 `deployments/docker-compose.production.yml` (de-tenant)

Mesma estrutura do myapp (serviços `app`, `queue`, `scheduler`, `redis`), com **duas** mudanças:

1. **Router Traefik:** trocar `Host || HostRegexp(subdomain)` por só `Host`:
   ```yaml
   - "traefik.http.routers.${APP_SLUG:-production}-app.rule=Host(`${DOMAIN}`)"
   ```
   (mantém entrypoints/tls/middlewares de segurança idênticos).
2. Sem `host.docker.internal`/landlord especial além do necessário pro banco — manter `extra_hosts`
   só se `DB_MODE=local` (banco no mesmo host). O resto (healthcheck `curl /up`, redis com requirepass,
   volumes `prod_storage_data`/`prod_redis_data`) **fica igual**.

### 7.4 Bloco `.env` gerado em `setup-app-host.sh` (de-tenant)

Substitua o heredoc do `.env` (hoje cheio de `DB_LANDLORD_*`/`DB_TENANT_*`/`DOMAIN_LANDLORD`) por:

```env
APP_ENV=${APP_ENV}
APP_DEBUG=false
APP_KEY=${APP_KEY}
APP_URL=https://${DOMAIN}
DOMAIN=${DOMAIN}
APP_SLUG=${APP_SLUG}
GHCR_REPO=${GHCR_REPO}
DB_CONNECTION=${DB_ENGINE}
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_CHARSET=${DB_CHARSET_VALUE}
REDIS_HOST=redis
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_PORT=6379
QUEUE_CONNECTION=redis
CACHE_STORE=redis
SESSION_DRIVER=redis
SESSION_CONNECTION=default
REDIS_CACHE_CONNECTION=cache
REDIS_CACHE_LOCK_CONNECTION=default
BROADCAST_CONNECTION=log
IMAGE_TAG=branch-${APP_SLUG}-latest
```

> Mantenha os fixes de incidentes reais do myapp: `SESSION_CONNECTION=default` (não `landlord`) e
> `REDIS_CACHE_CONNECTION=cache` — eles previnem o erro "Redis connection [...] not configured".

No topo do script, remova as variáveis `DB_LANDLORD_*`, `DB_TENANT_DATABASE`, `DB_CONNECTION_DEFAULT=landlord`
e troque `DOMAIN_LANDLORD` por `DOMAIN`.

### 7.5 Workflows GitHub

**`tests.yml`** — manter (ajustar: se não houver build de assets, troque o passo de build por
`php artisan test` ou `composer test`).

**`vps-build-push.yml`** — **remover** todo o uso de `DOMAIN_LANDLORD`/`WAYFINDER_LANDLORD_DOMAIN`
e o `--build-arg`. Fica um buildx simples:
```yaml
docker buildx build \
  --file ./Dockerfile.prod \
  --tag "${IMAGE}:production-${SHORT_SHA}" \
  --tag "${IMAGE}:branch-production-latest" \
  --cache-from type=gha,scope=vps-build-push \
  --cache-to type=gha,mode=max,scope=vps-build-push \
  --push .
```

**`vps-deploy-production.yml`** — manter a espinha (sync compose via scp, `docker compose pull/up`,
prep de `storage`/`bootstrap/cache`, `optimize:clear`, `storage:link`, healthcheck interno em `127.0.0.1/up`).
**Trocar a etapa de migração** por uma única conexão e **remover** o bloco `tenants:artisan`:
```bash
# substitui o migrate landlord + tenants:artisan por:
php artisan migrate --force
```
E na validação do `.env`, checar apenas `DB_CONNECTION DB_DATABASE` (remover `DB_LANDLORD_*`).

**`vps-rollback.yml`** — manter; trocar o `migrate --database=landlord --path=...` por `php artisan migrate --force`.

### 7.6 Wizard `setup.sh`

Manter o fluxo. Cortes:
- Remover prompts/emissões de `DB_TENANT_DATABASE` e `DB_LANDLORD_*` no manifest.
- Renomear `DOMAIN_LANDLORD` → `DOMAIN` (prompt "Domínio da aplicação (raiz)").
- No DNS, não é mais obrigatório o registro curinga `*.<domínio>` (era para tenants por subdomínio) —
  manter só `A` para a raiz (e `www` se quiser).
- Variável GitHub: publicar `DOMAIN` (em vez de `DOMAIN_LANDLORD`) — embora, sem baking no build, ela
  passe a ser usada **só** no compose de produção (router Traefik), não mais no build.

---

## 8. Ordem de execução para o agente

1. **Scaffold Laravel limpo** (`composer create-project laravel/laravel .` ou equivalente) na versão estável atual.
2. **Copiar a infra local:** `docker/`, `docker-compose.yml`, `.dockerignore` (com os ajustes de nome/slug deste doc).
3. **Ajustar `.env.example`** conforme §6.
4. **Criar `Dockerfile.prod`** conforme §5 (decidir se mantém o bloco de build de assets).
5. **Copiar `vps-deployment/`** e aplicar os cortes de §7 (deletar `tenant-migrate`, de-tenant do `.env`/manifest/workflows).
6. **Criar os 3 workflows** (`tests`, `build-push`, `deploy-production`) + `rollback`, já de-tenant.
7. **Subir local e validar** (§9).
8. **Escrever um `CLAUDE.md`/README curto** do projeto base explicando o stack e os comandos.

> **Regra de ouro:** procure por `tenant`, `landlord`, `spatie`, `multitenan`, `wayfinder`, `DOMAIN_LANDLORD`
> em todo o repo copiado e **garanta zero ocorrências** antes de finalizar.
> `grep -rniE "tenant|landlord|spatie|multitenan|wayfinder|domain_landlord" . --exclude-dir=vendor --exclude-dir=node_modules`

---

## 9. Checklist de verificação

**Local:**
- [ ] `docker network create web` feito (ou nginx exposto via `ports`).
- [ ] `docker compose up -d` sobe nginx, php, worker, postgres, redis, mailpit sem erro.
- [ ] `docker compose exec php php artisan migrate` roda numa conexão única.
- [ ] App responde em `http://app.localhost` (ou porta exposta) e `/up` retorna 200.
- [ ] `php artisan queue:work` (serviço worker) consome um job de teste.
- [ ] Mailpit recebe e-mail de teste em `http://localhost:8027`.

**Produção (1º deploy):**
- [ ] DNS `A` da raiz aponta pra VPS.
- [ ] `bash vps-deployment/setup.sh` provisiona (Docker, UFW, fail2ban, Traefik, `.env`, secrets GH).
- [ ] Push em `main` → `vps-build-push` publica imagem no GHCR.
- [ ] `vps-deploy-production` faz pull/up, roda `migrate --force` e healthcheck `127.0.0.1/up` passa.
- [ ] HTTPS válido (Let's Encrypt) no domínio.
- [ ] `grep` de tenant/landlord/wayfinder retorna **vazio** no repo.

---

## 10. Referência — incidentes do myapp que a base já deve prevenir

Estes vieram da operação real (`vps-deployment/README.md`). Mantenha as prevenções:

- **Redis connection não configurada:** `SESSION_CONNECTION=default` + `REDIS_CACHE_CONNECTION=cache`.
- **Cache path inválido:** o deploy cria `storage/framework/{views,cache,sessions}` e `bootstrap/cache` antes do `optimize`.
- **Healthcheck público falhando por DNS/CDN:** o healthcheck do CI roda **interno** ao container (`127.0.0.1/up`).
- **GD sem WebP:** o `Dockerfile.prod` compila `gd --with-webp`; o deploy valida `imagewebp`.
- **Horizon/Reverb inexistentes:** a fila usa `php artisan queue:work redis` (sem Horizon); `BROADCAST_CONNECTION=log` (sem Reverb). Só reintroduza se instalar os pacotes.
- **`host.docker.internal` não resolve na VPS:** o compose publica `host.docker.internal:host-gateway`; fallback `172.17.0.1` quando `DB_MODE=local`.
```
