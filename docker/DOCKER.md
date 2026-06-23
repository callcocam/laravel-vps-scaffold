# Docker Setup Guide

Explica como o stack Docker local deste projeto está organizado e o que mudar ao copiar para outro app.

> O nome do projeto é o token **`myapp`** em todos os arquivos. O `init.sh` na raiz do scaffold
> substitui `myapp` pelo nome real do seu projeto — rode-o antes de usar.

## Arquivos do stack

```text
docker/
  nginx/default.conf   # nginx LOCAL (proxy para o serviço php em php:9000)
  nginx/prod.conf      # nginx PRODUÇÃO (php-fpm na mesma imagem, 127.0.0.1:9000)
  php/Dockerfile       # imagem de DEV (php-fpm + extensões)
  supervisor/app.conf  # php-fpm + nginx sob supervisord (usado no Dockerfile.prod)
  DOCKER.md
docker-compose.yml
Dockerfile.prod        # imagem única de produção
```

## Ajustes ao iniciar um novo projeto

### 1. Nome do projeto

Rode `./init.sh` (substitui `myapp` por todo lado), ou troque manualmente em `docker-compose.yml`:

| Superfície | Valor |
|---------|------------------|
| compose | `name: myapp` |
| nginx   | `traefik.http.routers.myapp-web.rule=Host(\`myapp.localhost\`)` |
| pgadmin | `traefik.http.routers.myapp-pgadmin.rule=Host(\`pgadmin.myapp.localhost\`)` |

Prefixar os routers/services do Traefik com o slug do projeto evita colisão quando vários apps
compartilham o mesmo Traefik.

### 2. Banco PostgreSQL

No serviço `postgres`, `POSTGRES_DB`/`USER`/`PASSWORD` devem casar com o `.env`.

### 3. Portas conflitantes

Se rodar vários projetos ao mesmo tempo, cada um precisa de portas de host distintas
(lado esquerdo de `host:container`):

| Serviço  | Padrão Laravel | Neste scaffold |
|----------|----------------|----------------|
| postgres | `5432:5432`    | `5434:5432`    |
| pgadmin  | `5050:80`      | `5052:80`      |
| redis    | `6379:6379`    | `6381:6379`    |
| mailpit  | `1025:1025`    | `1027:1025`    |
| mailpit  | `8025:8025`    | `8027:8025`    |

### 4. `.env`

Garanta que as credenciais do `.env` casem com o `docker-compose.yml`:

```env
APP_URL=http://myapp.localhost
DB_CONNECTION=pgsql
DB_HOST=postgres
DB_PORT=5432
DB_DATABASE=myapp
DB_USERNAME=myapp
DB_PASSWORD=myapp
REDIS_HOST=redis
REDIS_PORT=6379
MAIL_MAILER=smtp
MAIL_HOST=mailpit
MAIL_PORT=1025
```

## Chamar APIs `*.localhost` de dentro dos containers

Containers PHP não resolvem `*.localhost` por padrão (esses hosts só existem no host via Traefik).

**Sintoma:** `cURL error 7: Failed to connect to some-api.localhost port 80`

**Fix:** adicione o host em `extra_hosts` no serviço `php`:

```yaml
php:
  extra_hosts:
    - "some-api.localhost:host-gateway"
```

## Rede externa do Traefik

Usa uma rede externa chamada `web`. Antes do `docker compose up`:

```bash
docker network create web
```

O Traefik precisa estar rodando nessa rede para rotear `*.localhost`. Sem Traefik, troque os
`labels` do nginx por `ports: ["8080:80"]` e acesse `http://localhost:8080`.

## Serviços

| Serviço  | Função                          |
|----------|---------------------------------|
| nginx    | Web server, proxy para PHP-FPM  |
| php      | App Laravel (PHP-FPM)           |
| worker   | Worker da fila (redis)          |
| postgres | Banco relacional                |
| pgadmin  | GUI do PostgreSQL               |
| redis    | Cache, filas e sessões          |
| mailpit  | Captura de e-mail local (SMTP)  |
