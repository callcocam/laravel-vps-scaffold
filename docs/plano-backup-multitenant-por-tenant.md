# Plano — Backup opcional para multitenancy banco-por-tenant

> **Para quem é este documento:** o agente de IA que vai trabalhar neste repositório
> (`laravel-vps-scaffold`) pra adicionar uma **opção alternativa de backup**, usada quando um
> projeto que nasceu deste scaffold evolui pra multitenancy com **um banco Postgres por tenant**
> (não o `DB_NAME` único que o scaffold assume por padrão).
>
> Este plano nasceu de um caso real: o projeto `plannerate-v1` (Claudio Campos) foi bifurcado deste
> scaffold e depois ganhou `spatie/laravel-multitenancy` no modo banco-por-tenant. O
> `automation/backup-db.sh` herdado do scaffold nunca foi adaptado — ele fazia backup de **um**
> `DB_NAME` fixo do manifest, então só cobria o banco landlord. Os dados de cada cliente, cada um em
> seu próprio banco (`tenant_<slug>`), nunca foram salvos, silenciosamente, por meses. Isso só foi
> descoberto ao investigar por que os backups não apareciam no destino S3 — o bucket estava vazio.

## Por que isso NÃO é um bug do scaffold

O princípio #1 e #2 do `docs/base-laravel-deploy-blueprint.md` são explícitos: **sem multitenancy,
uma única conexão de banco**. Dentro dessa premissa, `automation/backup-db.sh` (um `DB_NAME`, uma
query) está **correto** e deve continuar sendo o default. O que falta é uma **opção adicional**,
opt-in, pra quando alguém bifurca o scaffold e adota banco-por-tenant — sem quebrar ou remover o
fluxo padrão existente.

## O que já existe aqui como referência

Copiei pra `vps-deployment/db/` os dois scripts que validei em produção no `plannerate-v1`
(testados: dump real de 1 tenant → integridade do `.tar.gz` conferida → rodada completa em todos os
bancos → cron instalado e rodando):

- `db/postgres-backup-planogramas.sh` — tier **rápido** (a cada 30min): dump só das tabelas "quentes"
  (que mudam o tempo todo), um `.tar` por tabela, empacotado num `.tar.gz` por banco por rodada.
- `db/postgres-backup-completo.sh` — tier **diário**: todas as tabelas, exceto uma lista fixa de
  tabelas efêmeras do framework Laravel (`cache`, `cache_locks`, `sessions`, `jobs`, `job_batches`,
  `failed_jobs`, `migrations`, `password_reset_tokens` — essas não têm valor de restore).
- `db/spaces-credentials.env.example` — template de credenciais S3-compatible (testado com
  DigitalOcean Spaces), separado do manifest principal.

**Atenção:** esses dois scripts `.sh` estão **hardcoded pro `plannerate-v1`** — não copie/cole como
estão. `DB_OWNERS=("plannerate_prod" "plannerate_staging")` e a lista `TABLES_INCLUDED` (`planograms`,
`gondolas`, `sections`, `shelves`, `segments`, `layers`, ...) são específicos daquele projeto. Use-os
como referência de **mecanismo**, não de configuração.

## Mecanismo validado (preservar ao generalizar)

1. **Descoberta automática de bancos por dono**, não lista fixa de tenants:
   ```sql
   SELECT d.datname FROM pg_database d JOIN pg_roles r ON d.datdba = r.oid
   WHERE r.rolname IN (<db users do manifest>) AND NOT d.datistemplate;
   ```
   Isso cobre o banco landlord + cada tenant automaticamente, e exclui bancos de teste avulsos
   (donos diferentes do usuário de app) sem precisar de lista de exclusão.

2. **Interseção com tabelas reais do banco** antes de tentar o dump (o banco landlord não tem as
   tabelas de negócio do tenant — a interseção evita erro, em vez de precisar de uma condicional
   landlord-vs-tenant).

3. **Um `.tar.gz` por banco por rodada**, contendo um `.tar` por tabela dentro (formato custom do
   `pg_dump -F c`) — restaura banco inteiro ou tabela única.

4. **Roda como usuário OS `postgres`** (autenticação peer, sem login/senha no script — o usuário
   `postgres` é superuser e já lê qualquer banco local). *Pegadinha real que encontrei:* o arquivo de
   credenciais S3 não pode ficar em `/root/` (permissão `700`, o usuário `postgres` não consegue nem
   entrar no diretório) — usar um caminho tipo `/etc/<slug>/spaces-backup-credentials.env` com
   `chown <db-user>:<db-user>` no diretório e no arquivo.

5. **`flock`** pra evitar rodadas sobrepostas (mais confiável que contar processos via `pidof`).

6. **Retenção local E remota** — mantém as últimas N rodadas (contagem configurável por tier),
   apagando o excedente dos dois lados a cada execução.

7. **Argumento opcional `$1`** pra restringir a rodada a um único banco — usado pra testar em 1
   tenant antes de rodar geral, e serve também pra reprocessar um tenant específico depois.

## O que fazer aqui

1. **Genericizar os dois scripts** (renomear pra algo neutro, ex.: `postgres-backup-hot.sh` /
   `postgres-backup-full.sh` — "planogramas" é nome de domínio do plannerate, não faz sentido num
   scaffold genérico):
   - `DB_OWNERS` deve vir do manifest (nova variável, ex.: `BACKUP_DB_OWNERS`), não hardcoded.
   - A lista de tabelas "quentes" do tier rápido deve ser configurável via manifest (ex.:
     `BACKUP_HOT_TABLES`, vazio = pula o tier rápido, só roda o completo). Não existe lista genérica
     de "tabelas que mudam muito" — isso é de domínio de cada app.
   - A lista de exclusão de tabelas efêmeras (`cache`, `sessions`, `jobs`, etc.) **pode** ser um
     default sensato do scaffold (é specific do Laravel, não do domínio do app) — mas mantenha
     override via manifest.

2. **Adicionar ao wizard (`setup.sh`)** uma pergunta nova, próxima de onde hoje se pergunta
   `"Configurar backup automático no DO Spaces para ${DEPLOY_ENV}?"` (linha ~509): algo como
   `"Este projeto usa multitenancy com um banco por tenant?"`. Se sim, usar o fluxo novo
   (`db/postgres-backup-*.sh` + cron do usuário do banco); se não (default, alinhado ao princípio do
   scaffold), manter o fluxo existente (`automation/backup-db.sh` + `install-backup-cron.sh`)
   **sem nenhuma mudança**.

3. **Não remover nada do fluxo single-tenant existente** — `automation/backup-db.sh`,
   `restore-db.sh`, `run-backup-all.sh`, `install-backup-cron.sh` continuam sendo o default correto
   pro caso de uso principal do scaffold.

4. **Documentar** em `vps-deployment/README.md` (nova seção, como já existe pra
   `install-monitoring-on-host.sh` etc.) e citar a opção no `docs/base-laravel-deploy-blueprint.md`
   como "exceção ao princípio #1/#2, só se o projeto adotar multitenancy depois".

## Como testar antes de instalar cron (ordem que validei no plannerate-v1)

1. Rodar o script manual com `$1` = um único tenant de teste → conferir exit code e log.
2. Baixar o `.tar.gz` gerado, rodar `tar -tzf` (integridade) e opcionalmente extrair + `pg_restore`
   num banco descartável local, pra confirmar que não corrompeu.
3. Só depois disso, rodar sem `$1` (todos os bancos) manualmente uma vez, conferir tempo total e
   contagem de arquivos no destino S3.
4. Só então instalar o cron.

## Referência completa (se precisar do histórico real)

O repositório `plannerate-v1` (`/home/caltj/projects/plannerate-v1`, se disponível no mesmo host) tem
os dois scripts finais em `vps-deployment-v2/db/*.sh` e o histórico completo da investigação (por que
o backup antigo nunca funcionou, a descoberta dos 19 bancos reais, os testes de integridade). Não é
necessário pra executar este plano, mas ajuda a entender o "porquê" por trás de cada decisão acima.
