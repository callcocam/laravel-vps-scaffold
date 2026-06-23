# VPS Deployment

Provisionamento e deploy do `myapp` no VPS, ambiente production. Banco com conexão única.

## Resumo Operacional
- App de uma instância no domínio `DOMAIN` (ex.: `app.example.com`).
- Caminho da instância: `/opt/myapp/<APP_SLUG>`.
- Traefik compartilhado: `/opt/traefik`.
- Deploy automático: branch `main` -> workflow de production.
- Health check do CI: interno no container (`http://127.0.0.1/up`).
- Tags de imagem: `production-<sha>` + `branch-production-latest` (build de `main`).

## Fluxo Recomendado
1. Preparar DNS do domínio (`DOMAIN`) para o IP do VPS.
   - Em Cloudflare, iniciar com `DNS only` (nuvem cinza) para evitar atrito de ACME.
   - Criar registro `A` para a raiz (e `www` se quiser).
2. Rodar setup:
```bash
bash vps-deployment/setup.sh
```
3. Durante o setup:
- informar `APP_SLUG` (ex.: `production`)
- informar `DOMAIN`
- escolher `DB_MODE`:
  - `local`: provisiona o banco automaticamente na VPS e cria database/user
  - `externo`: provisiona um host de banco separado
- permitir provisionamento e instalação de compose
4. Push em `main` para acionar build+deploy.

## Regras Importantes
- `APP_SLUG` é obrigatório como identificador lógico de instância.
- `queue` usa `php artisan queue:work redis` (sem Horizon — `laravel/horizon` não está instalado).
- Não subir monitoring antes do DNS estar pronto.
- Dashboard auth do Traefik com `$` precisa de escape (`$$`).
- Migração no deploy: `php artisan migrate --force` (conexão única).

## Variáveis-Chave
- `APP_SLUG`: nome da instância (pasta/projeto docker/routers).
- `DOMAIN`: domínio raiz da app. Usado em runtime no compose de produção (router Traefik).
- `GHCR_REPO`: imagem no GHCR.
- `DB_*`, `REDIS_PASSWORD`: runtime da instância.

### Pipeline CI/CD
| Branch | DEPLOY_CHANNEL | Formato de tag |
|--------|---------------|----------------|
| `main` | `production`  | `production-<sha>`, `branch-production-latest` |

- `vps-build-push` dispara em push para `main` e publica a imagem no GHCR.

## Validação Pós-Provisionamento
### Local (máquina de operação)
```bash
ssh -i ~/.ssh/id_ed25519_<repo>_deploy deploy@<VPS_IP>
```

### No VPS
```bash
cd /opt/myapp/<APP_SLUG>
docker compose -p myapp-<APP_SLUG> ps
docker compose -p myapp-<APP_SLUG> exec -T app sh -lc 'curl -fsS http://127.0.0.1/up >/dev/null && echo OK'
```

### Traefik
```bash
cd /opt/traefik
docker compose ps
ss -tulpen | grep -E ':80|:443'
```

## Deploy
1. Commit/push em `main`.
2. Confirmar `vps-build-push` OK.
3. Confirmar `vps-deploy-production` OK.
4. Verificar stack no VPS e logs se necessário.

## Migrações
No workflow de production, o deploy executa:
```bash
php artisan migrate --force
```
Manual (dentro do container):
```bash
docker compose -p myapp-<APP_SLUG> exec -T app php artisan migrate --force
```

## Incidentes Reais e Prevenção
### 1) `ssh: unable to authenticate`
Causa: `deploy` sem `authorized_keys` ou chave divergente.
```bash
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
cat >> /home/deploy/.ssh/authorized_keys  # colar chave pública
chmod 600 /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh
```
Prevenção: usar `setup-app-host.sh` + o wizard.

### 2) `REMOTE HOST IDENTIFICATION HAS CHANGED`
```bash
ssh-keygen -f '/home/<user>/.ssh/known_hosts' -R '<VPS_IP>'
ssh-keyscan -H <VPS_IP> >> /home/<user>/.ssh/known_hosts
```
Prevenção: atualizar também `SSH_KNOWN_HOSTS` no environment `production`.

### 3) `No APP_KEY variable was found` / `.env` read-only
Causa: tentar `key:generate` dentro de container com bind read-only.
Correção: gerar `APP_KEY` no host e re-subir stack. `setup-app-host.sh` já escreve `APP_KEY`.

### 4) `404` no `/up` público durante deploy
Causa frequente: dependência de DNS/CDN no health check do workflow.
Prevenção: manter o health check interno do container no CI (`127.0.0.1/up`).

### 5) `Command "horizon" is not defined` / `reverb` namespace
Causa: compose subia serviços de pacotes não instalados → crash-loop.
Correção: fila usa `php artisan queue:work redis`; sem `reverb` (`BROADCAST_CONNECTION=log`).
Para usar no futuro: `composer require laravel/horizon` e/ou `laravel/reverb`, publicar config e reintroduzir os serviços.

### 6) ACME `NXDOMAIN` + `429 rateLimited`
Causa: Traefik tentou emitir cert sem DNS pronto.
Correção: criar registros DNS, aguardar janela de retry e reiniciar Traefik.

### 7) `SQLSTATE[HY000] [2002] Connection timed out` no migrate
Causa: app em container sem rota/permit para o banco local no host.
```bash
cd /opt/myapp/<APP_SLUG>
grep -E '^(DB_HOST|DB_CONNECTION)=' .env
# esperado para local:
# DB_HOST=host.docker.internal
```
Se `host.docker.internal` não resolver, use fallback `172.17.0.1` (ou ajuste `DB_LOCAL_HOST_FALLBACK`).
Prevenção: compose publica `host.docker.internal:host-gateway` e `setup-db-host.sh` libera o CIDR para a porta do banco em `DB_MODE=local`.

### 8) `Please provide a valid cache path`
```bash
docker compose -p myapp-<APP_SLUG> exec -T app sh -lc '
  mkdir -p storage/framework/views storage/framework/cache storage/framework/sessions bootstrap/cache
  chmod -R ug+rwX storage bootstrap/cache
  chown -R www-data:www-data storage bootstrap/cache 2>/dev/null || true
'
```
Prevenção: os workflows de deploy/rollback já preparam esses diretórios antes das migrações.

### 9) `Redis connection [...] not configured`
Causa: `SESSION_DRIVER=redis` apontando para uma conexão Redis inexistente.
```bash
sed -i 's/^SESSION_CONNECTION=.*/SESSION_CONNECTION=default/' /opt/myapp/<APP_SLUG>/.env
grep -q '^REDIS_CACHE_CONNECTION=' /opt/myapp/<APP_SLUG>/.env || echo 'REDIS_CACHE_CONNECTION=cache' >> /opt/myapp/<APP_SLUG>/.env
docker compose -p myapp-<APP_SLUG> up -d --force-recreate
```
Prevenção: `setup-app-host.sh` já escreve `SESSION_CONNECTION=default` e `REDIS_CACHE_CONNECTION=cache`.

### 10) `GET /dashboard 404` no domínio principal
Causa: `DOMAIN`/`APP_URL` ausente ou incorreto no `.env`.
```bash
sed -i 's|^APP_URL=.*|APP_URL=https://app.example.com|' /opt/myapp/<APP_SLUG>/.env
docker compose -p myapp-<APP_SLUG> exec -T app php artisan optimize:clear
docker compose -p myapp-<APP_SLUG> up -d --force-recreate
```
Prevenção: `setup-app-host.sh` já escreve `APP_URL=https://${DOMAIN}`.

## DNS/ACME Guardrails
Antes de monitoring público, criar `A/AAAA` para:
- `traefik.<DOMAIN>` (se dashboard público)
- `pgadmin.<DOMAIN>` (se `ENABLE_PGADMIN=true`)

## pgAdmin Opcional
```bash
ENABLE_PGADMIN=true
PGADMIN_DOMAIN=pgadmin.<DOMAIN>
PGADMIN_DEFAULT_EMAIL=admin@<DOMAIN>
PGADMIN_DEFAULT_PASSWORD=<senha-forte>
```

## Comandos Úteis
```bash
# bootstrap de secrets/vars no GitHub
automation/bootstrap-github.sh vps-deployment/manifest.env

# instalar compose no host
APP_SLUG=production START_SERVICES=true automation/install-compose-on-host.sh

# instalar monitoring (com validação DNS)
APP_SLUG=production automation/install-monitoring-on-host.sh vps-deployment/manifest.production.env production

# health check completo
automation/vps-health-check.sh vps-deployment/manifest.production.env production
```
