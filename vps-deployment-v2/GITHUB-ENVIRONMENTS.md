# GitHub Environments — Referência de Variáveis e Secrets

> O script `setup.sh` configura o environment `production` automaticamente via GitHub CLI.

---

## O que o `setup.sh` cria automaticamente

Ao rodar `./setup.sh`, o script usa `gh` (GitHub CLI) para criar:

### Repository Variables (nível repositório — todos os workflows)

| Nome | Valor configurado | Workflow que usa |
|------|------------------|------------------|
| `DOMAIN` | domínio da app (ex: `app.example.com`) | compose de produção (router Traefik) |
| `GHCR_REPO` | `callcocam/myapp` | `vps-v2-build-push` (push da imagem) |

### Environment `production` — Secrets

| Nome | Origem | Descrição |
|------|--------|-----------|
| `APP_HOST` | IP do VPS informado no setup | Endereço do servidor |
| `APP_USER` | usuário SSH informado no setup | Usuário de deploy |
| `SSH_PRIVATE_KEY` | chave gerada/informada no setup | Acesso SSH ao VPS |
| `SSH_KNOWN_HOSTS` | fingerprint escaneado no setup | Previne TOFU no SSH |
| `DOMAIN` | domínio da app | Domínio do ambiente |

### Environment `production` — Variables

| Nome | Valor | Descrição |
|------|-------|-----------|
| `DEPLOY_PATH` | `/opt/myapp/production` | Diretório no VPS |
| `COMPOSE_FILE` | `docker-compose.production.yml` | Arquivo compose do ambiente |

---

## Criar o environment `production` via GitHub CLI

```bash
REPO="callcocam/myapp"
VPS_HOST="<ip-do-vps>"
VPS_USER="root"

# Cria o environment
gh api --method PUT "repos/${REPO}/environments/production"

gh secret set APP_HOST        --repo "${REPO}" --env production --body "${VPS_HOST}"
gh secret set APP_USER        --repo "${REPO}" --env production --body "${VPS_USER}"
gh secret set SSH_PRIVATE_KEY --repo "${REPO}" --env production < ~/.ssh/id_ed25519_myapp_deploy
gh secret set SSH_KNOWN_HOSTS --repo "${REPO}" --env production --body "$(ssh-keyscan -H ${VPS_HOST} 2>/dev/null)"

# Variables específicas de production
gh variable set DEPLOY_PATH  --repo "${REPO}" --env production --body "/opt/myapp/production"
gh variable set COMPOSE_FILE --repo "${REPO}" --env production --body "docker-compose.production.yml"
```

---

## Mapa completo: qual workflow usa o quê

```
vps-v2-build-push          (sem environment)
  vars.GHCR_REPO            ← repository variable

vps-v2-deploy-production   (environment: production)
  secrets.APP_HOST
  secrets.APP_USER
  secrets.SSH_PRIVATE_KEY
  vars.DOMAIN              ← usado no compose de produção (router Traefik)
  → deploya em /opt/myapp/production/

vps-v2-rollback            (environment: production)
  secrets.APP_HOST
  secrets.APP_USER
  secrets.SSH_PRIVATE_KEY
```
