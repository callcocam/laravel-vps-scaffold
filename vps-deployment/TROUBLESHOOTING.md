# Troubleshooting — deploy via GitHub Actions → VPS

Incidentes reais já enfrentados em produção, com sintoma, causa-raiz e correção.
Vários já foram corrigidos no próprio scaffold (marcados com ✅); os demais são
operacionais (configuração de VPS/Cloudflare) e ficam como guia.

A ordem abaixo é a ordem típica em que as falhas aparecem — cada uma esconde a
próxima, então resolva de cima para baixo.

---

## 1. Build falha no "Login GHCR" ✅ corrigido

**Sintoma (logs do `vps-build-push`):**
```
Error: Cannot perform an interactive login from a non TTY device
```

**Causa:** o workflow logava no GHCR com `secrets.GHCR_PAT`, mas o `setup.sh`
nunca cria esse secret → senha vazia → `echo "" | docker login` falha.

**Correção:** usar o `secrets.GITHUB_TOKEN` efêmero (o job já tem
`permissions: packages: write`). Só use um PAT se precisar acessar packages de
**outro** repositório.

---

## 2. Deploy não roda / SSH recusado ✅ proteção adicionada

**Sintoma (logs do `vps-deploy-production`):**
```
ssh: handshake failed: ssh: unable to authenticate,
attempted methods [none publickey], no supported methods remain
```

**Causas possíveis:**
- A chave pública de deploy não está no `authorized_keys` do `APP_USER` na VPS.
- O secret `SSH_PRIVATE_KEY` está incompleto/mal colado (precisa das linhas
  `-----BEGIN/END ... KEY-----` inteiras).
- **Concatenação de chaves:** se o `authorized_keys` já existia sem `\n` no
  final, a chave nova gruda na linha anterior e o sshd a trata como comentário
  da chave de cima → `Permission denied`. (Corrigido: o `setup-app-host.sh`
  agora garante newline antes de adicionar.)

**Diagnóstico:**
```sh
# Teste local com a MESMA chave do secret:
ssh -i caminho/chave_privada <APP_USER>@<APP_HOST>
# Na VPS, inspecione cada linha (devem ser chaves completas, uma por linha):
cut -d' ' -f1,3- ~/.ssh/authorized_keys
```

---

## 3. Pull da imagem falha com "unauthorized" ✅ corrigido

**Sintoma:**
```
Image ghcr.io/<owner>/<repo>:production-xxxx  error from registry: unauthorized
```

**Causa:** a imagem no GHCR é **privada** por padrão e a VPS rodava
`docker compose pull` sem estar autenticada no registry.

**Correção:** o `vps-deploy-production` passa o `GITHUB_TOKEN` para a VPS (via
`envs` do appleboy/ssh-action) e faz `docker login ghcr.io` antes do `pull`. O
job precisa de `permissions: packages: read`. A imagem continua privada.

> Alternativa: tornar o package público no GHCR (Settings → Packages →
> Change visibility). Aí o pull funciona sem login, mas expõe a imagem.

---

## 4. `i/o timeout` no SSH durante o deploy — fail2ban baniu o runner

**Sintoma:**
```
error message: dial tcp <APP_HOST>:22: i/o timeout
```
(diferente do #2: aqui nem chega a negociar auth — os pacotes são dropados)

**Causa:** as tentativas de SSH que falharam por causa do #2 dispararam o
fail2ban, que **baniu o IP do runner do GitHub**. Como os IPs dos runners são
compartilhados/rotativos, não dá pra colocá-los na whitelist de forma confiável.

**Correção/prevenção:**
- A causa primária é sempre uma falha de auth (#2). Corrija a auth e os bans
  param de acontecer.
- Para desbanir agora (rode na VPS):
  ```sh
  fail2ban-client status sshd                 # lista IPs banidos
  fail2ban-client set sshd unbanip <IP>
  ```
- O `setup-app-host.sh` já coloca o `OPERATOR_IP` na `ignoreip`, mas isso só
  protege a SUA máquina, não os runners do CI.

---

## 5. Site responde 404 mesmo com containers saudáveis — colisão de router no Traefik ✅ corrigido

**Sintoma:** `https://seu-dominio` retorna 404; nos logs do `traefik-global`:
```
Router defined multiple times with different configurations
  in [app-projetoA-production-... app-projetoB-production-...] routerName=production-app
```

**Causa:** vários projetos no mesmo Traefik usavam `APP_SLUG=production`, gerando
o mesmo nome de router `production-app`. Com nomes duplicados e configs
diferentes, o Traefik **descarta** o router → sem rota → 404.

**Correção:** os nomes de router/service/middleware agora incluem o prefixo do
projeto (`myapp-...`, substituído pelo slug via `init.sh`), ficando únicos no
Traefik compartilhado. Ex.: `projetoA-production-app`, `projetoB-production-app`.

---

## 6. Certificado do Traefik não emite atrás da Cloudflare 📝 nota

**Sintoma (logs do `traefik-global`):**
```
Cannot negotiate ALPN protocol "acme-tls/1" for tls-alpn-01 challenge
...
acme: error: 429 :: rateLimited :: too many failed authorizations
```

**Causa:** com o domínio atrás do **proxy da Cloudflare** (nuvem laranja), a
Cloudflare termina o TLS na borda; o desafio `tls-alpn-01` nunca chega ao
Traefik. O site ainda funciona em HTTPS (cert de borda da Cloudflare), mas o
Traefik não consegue emitir o cert dele, e as retentativas estouram o rate limit
do Let's Encrypt ("failed authorizations": 5/h por domínio).

**Correção (escolha uma):**
- **DNS-01 via Cloudflare (recomendado se usa o proxy):** veja o bloco comentado
  em `deployments/traefik/docker-compose.yml`. Troque para `dnschallenge`
  provider `cloudflare` e defina `CF_DNS_API_TOKEN` (Zone:DNS:Edit + Zone:Read)
  no `.env` do Traefik. Funciona atrás do proxy e suporta wildcard. Depois,
  configure o SSL/TLS da Cloudflare como **Full (strict)**.
- **Desligar o proxy (DNS only / nuvem cinza):** aí o `tls-alpn-01` padrão volta
  a funcionar, mas você perde CDN/DDoS/ocultação de IP da Cloudflare.

> Atenção ao rate limit: depois de muitas falhas, o Let's Encrypt bloqueia novas
> ordens para o domínio por ~1h. Espere a janela liberar antes de retestar.

---

## Pré-requisitos de DNS

- O registro A/AAAA do domínio precisa apontar para a VPS (ou para a Cloudflare,
  se usar o proxy — ver #6).
- Subdomínios (ex.: `traefik.seu-dominio`) precisam de registro próprio, senão o
  ACME falha com `NXDOMAIN`.
