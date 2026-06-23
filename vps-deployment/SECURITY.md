# Relatório de Segurança — VPS Deployment

> Auditoria realizada em 2026-05-03. Documenta os achados, as correções aplicadas e os riscos residuais do ambiente de deploy.

---

## Sumário

| Severidade | Achado | Status |
|------------|--------|--------|
| Crítico | `manifest.env` rastreado pelo git com credenciais em texto puro | ✅ Corrigido |
| Crítico | Reutilização de senha entre root/banco | ⚠️ Ação necessária |
| Alto | Root SSH nunca desabilitado após provisionamento | ✅ Corrigido |
| Alto | Sem `PasswordAuthentication no` no sshd | ✅ Corrigido |
| Alto | fail2ban instalado mas sem jail configurado | ✅ Corrigido |
| Alto | UFW não configurava portas 80/443 no app server | ✅ Corrigido |
| Médio | PostgreSQL ouve em `'*'` (todos os interfaces) | ⚠️ Aceito com mitigação |
| Médio | `eval "$@"` no `run_cmd` — risco de injeção via manifest | ⚠️ Documentado |
| Médio | Usuário `deploy` no grupo `docker` (root-equivalent) | ⚠️ Aceito |
| Baixo | `pcov` instalado na imagem de produção | ⚠️ Ação recomendada |

---

## Achados Detalhados

### Crítico — `manifest.env` no git

**Problema:** O `.gitignore` tinha um typo (`/vps-deployment-packagevps-deployment/manifest.env` em vez de `/vps-deployment/manifest.env`). O arquivo com senhas em texto puro era rastreado e commitado.

**Correção aplicada:**
- Corrigido o path no `.gitignore`
- Arquivo removido do índice git com `git rm --cached`
- O arquivo local permanece (necessário para o wizard), mas nunca mais será commitado

**Ação residual:** O histórico git anterior ainda contém as credenciais. Como o repositório é privado, o risco é controlado. Se o repo se tornar público, use `git filter-repo --path vps-deployment/manifest.env --invert-paths` para limpar o histórico.

---

### Crítico — Reutilização de senha

**Problema:** Em `manifest.env`, `DB_ROOT_PASS` e `DB_PASSWORD` podem acabar com o mesmo valor. Uma exposição compromete todos os sistemas de uma vez.

**Correção aplicada:** O wizard (`setup.sh`) agora usa `ask_secret_suggest` para cada campo de senha — gera uma sugestão forte e independente para cada campo, mostrando-a antes do prompt para que o usuário possa salvar.

**Ação necessária:** Rotacionar manualmente as senhas atuais na VPS e no banco de dados. O manifest local também deve ser atualizado.

```bash
# Na VPS, como root:
sudo -u postgres psql -c "ALTER USER myapp_production PASSWORD 'nova-senha-forte';"

# Atualizar /opt/myapp/production/.env com a nova senha
# Reiniciar os containers:
docker compose -p myapp-production restart
```

---

### Alto — Root SSH habilitado indefinidamente

**Problema:** O wizard conecta na VPS como `root` para provisionar, mas nunca desabilitava o login root depois. Qualquer ataque de força-bruta contra o IP público poderia eventualmente comprometer o root.

**Correção aplicada** (`setup-app-host.sh`): Após configurar as chaves SSH do usuário `deploy`, o script agora executa:

```bash
sed -i '/^#\?PermitRootLogin/d' /etc/ssh/sshd_config
sed -i '/^#\?PasswordAuthentication/d' /etc/ssh/sshd_config
sed -i '/^#\?MaxAuthTries/d' /etc/ssh/sshd_config
printf '\nPermitRootLogin no\nPasswordAuthentication no\nMaxAuthTries 3\n' >> /etc/ssh/sshd_config
systemctl restart sshd
```

**Após o provisionamento:** use o usuário `deploy` para acessar a VPS. Root SSH estará desabilitado.

---

### Alto — fail2ban sem configuração

**Problema:** Ambos os scripts instalavam o fail2ban com `apt install` mas sem nenhum jail configurado. O serviço pode iniciar com configuração padrão mínima ou nenhuma, dependendo da versão do Ubuntu.

**Correção aplicada** (`setup-app-host.sh` e `setup-db-host.sh`): Ambos os scripts agora criam `/etc/fail2ban/jail.d/vps-ssh.local`:

```ini
[sshd]
enabled  = true
port     = ssh
filter   = sshd
maxretry = 5
bantime  = 3600
findtime = 600
```

5 tentativas erradas em 10 minutos → ban de 1 hora. Ajuste `bantime` para valores maiores em produção se necessário.

---

### Alto — UFW sem portas HTTP/HTTPS no app server

**Problema:** `setup-db-host.sh` configurava UFW corretamente (22 + porta do banco). Mas `setup-app-host.sh` não configurava UFW, e as portas 80/443 nunca eram explicitamente abertas.

**Nota importante:** O Docker bypassa o UFW diretamente via iptables — então as portas expostas por containers (como Traefik nas 80/443) ficam acessíveis mesmo que o UFW não as libere. Isso cria uma **falsa sensação de proteção**: você pensa que o UFW está bloqueando, mas o Docker já abriu.

**Correção aplicada** (`setup-app-host.sh`): O script agora configura UFW explicitamente:

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
```

Isso documenta a intenção e garante que novos serviços não-Docker (ex: monitoring direto no host) também sigam a política correta.

**Para mitigar o Docker + UFW bypass em produção avançada:**
```bash
# /etc/docker/daemon.json
{ "iptables": false }
```
Desabilitar o iptables do Docker requer configurar as regras manualmente — não recomendado sem experiência com iptables.

---

## Riscos Residuais Aceitos

### Médio — PostgreSQL ouvindo em `'*'`

`setup-db-host.sh` configura `listen_addresses = '*'` no PostgreSQL. Isso faz o serviço aceitar conexões TCP em todos os interfaces, porém o `pg_hba.conf` rejeita qualquer conexão que não seja da rede Docker (`172.16.0.0/12` com scram-sha-256).

**Por que não foi alterado:** Restringir `listen_addresses` a um IP específico exigiria conhecer o IP do gateway Docker no momento do provisionamento, o que não é determinístico. O `pg_hba.conf` é a camada de controle de acesso efetiva.

**Mitigação em vigor:** UFW bloqueia porta 5432 de fora da rede Docker. pg_hba rejeita conexões de IPs não autorizados. Dupla defesa.

---

### Médio — `eval "$@"` no `run_cmd`

Os scripts de provisionamento usam `run_cmd()` com `eval "$@"` para executar comandos com heredocs e pipes. Se uma variável do manifest contiver metacaracteres shell (`;`, `$()`, backticks), poderia executar código arbitrário durante o provisionamento.

**Mitigação em vigor:** O wizard usa `printf -v '%s' %q` para escrever o manifest, fazendo quoting correto de todos os valores. O risco é real apenas se o manifest for editado manualmente com conteúdo malicioso.

**Recomendação:** Validar variáveis críticas com regex antes de usar:
```bash
if [[ ! "${DB_USER}" =~ ^[a-zA-Z0-9_]+$ ]]; then
    log_error "DB_USER contém caracteres inválidos"
    exit 1
fi
```

---

### Médio — Usuário `deploy` no grupo `docker`

`usermod -aG docker deploy` — o grupo `docker` é equivalente a root no Linux, pois permite montar o sistema de arquivos do host:

```bash
docker run -v /:/host alpine chroot /host
```

**Por que foi aceito:** É o padrão de fato para deploy com Docker sem sudo. A alternativa (rootless Docker ou sudo restrito) aumenta significativamente a complexidade de operação.

**Mitigação:** O acesso ao usuário `deploy` requer a chave SSH privada controlada pelo GitHub Actions. Não há acesso por senha.

---

### Baixo — `pcov` na imagem de produção

O `Dockerfile.prod` instala a extensão `pcov` (code coverage). Não é usada em produção e aumenta o tamanho da imagem e a superfície de ataque.

**Recomendação:** Remover do `Dockerfile.prod`:
```diff
-    && pecl install pcov \
-    && docker-php-ext-enable igbinary msgpack redis imagick memcached swoole pcov \
+    && docker-php-ext-enable igbinary msgpack redis imagick memcached swoole \
```

---

## Checklist de Hardening Pós-Provisionamento

Execute após cada novo ambiente provisionado:

- [ ] Confirmar que root SSH está desabilitado: `sshd -T | grep permitrootlogin`
- [ ] Confirmar que autenticação por senha está desabilitada: `sshd -T | grep passwordauthentication`
- [ ] Confirmar fail2ban ativo: `fail2ban-client status sshd`
- [ ] Confirmar UFW ativo: `ufw status verbose`
- [ ] Confirmar que portas desnecessárias não estão abertas: `ss -tlnp`
- [ ] Rotacionar senhas padrão do banco e atualizar `.env` da app
- [ ] Confirmar que `manifest.env` não está no `git status`
- [ ] Verificar `.last-deployed-tag` após primeiro deploy

---

## Referências

- [Docker e UFW — o problema do bypass](https://docs.docker.com/network/iptables/)
- [PostgreSQL pg_hba.conf](https://www.postgresql.org/docs/current/auth-pg-hba-conf.html)
- [fail2ban docs](https://www.fail2ban.org/wiki/index.php/MANUAL_0_8)
- [SSH hardening — Mozilla guidelines](https://infosec.mozilla.org/guidelines/openssh)
