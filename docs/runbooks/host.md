# Runbook: alertas de host

Alertas das VMs (`host=primary` ou `secondary`), dos certificados do Traefik e dos
aparelhos da tailnet. Regras em `deploy/primary/prometheus/rules/host.yml` e `tailnet.yml`.

## HostDiskFilling / HostDiskWillFill

**O que significa:** o disco de 10 GB passou de 80%, ou a tendência das últimas 6 h o enche
em menos de 24 h. A 85% o healthcheck externo também falha.

1. `make ssh HOST=mgdn-<papel>` e `df -h /`.
2. Onde está o espaço: `sudo docker system df` e `sudo du -xh / --max-depth=3 | sort -h | tail -20`.
3. Suspeitos conhecidos:
   - imagens antigas: `sudo docker image prune -af` (o GitOps já faz isso a cada deploy);
   - logs do Blocky: o volume `mgdn_blocky-logs` cresce com a retenção configurada;
   - journal e cache do apt: `sudo systemctl start mgdn-maintenance.service`;
   - Prometheus: limitado a 1 GB (`--storage.tsdb.retention.size`).

## HostMemoryLow / HostOOMKill

**O que significa:** menos de 100 MB de RAM disponível por 10 min, ou o OOM killer matou um
processo. Em geral, é um container batendo no próprio `mem_limit`.

1. Qual container: `sudo docker stats --no-stream` e
   `sudo docker inspect -f '{{.Name}} {{.State.OOMKilled}}' $(sudo docker ps -aq)`.
2. `sudo journalctl -k --since -1h | grep -i oom` mostra o processo morto.
3. Se o limite ficou pequeno para o uso real, aumente o `mem_limit` em
   `deploy/<papel>/compose.yaml` por PR. A soma dos limites precisa caber na VM.
4. Se um app vaza memória, o `restart: unless-stopped` e o self-heal seguram enquanto você
   investiga. Se o self-heal recoloca o container em loop, chega também o
   `GitOpsSelfHealFlapping`.

## TLSCertExpiringSoon

**O que significa:** um certificado vence em menos de 14 dias. O Traefik renova com 30 dias
de folga, então a renovação por DNS-01 está falhando.

1. `make logs SERVICE=traefik | grep -i -E 'acme|cloudflare|error'`.
2. Causa mais provável: o token da Cloudflare venceu ou perdeu a permissão `DNS:Edit` em
   `mgdn.com.br`. Gere outro e grave com `make secrets-set ROLE=primary KEY=CLOUDFLARE_DNS_TOKEN`
   (ADR 0014). O GitOps reinicia o Traefik quando o token muda.
3. Também acontece com o limite semanal do Let's Encrypt, depois de muitas recriações da VM
   sem o backup do `acme.json`.

## TailnetNodeStale

**O que significa:** um aparelho não aparece na tailnet há mais de 30 dias. Não é urgente; o
aviso repete uma vez por semana.

- Se o aparelho não é mais usado: `make tailnet-nodes` e, na principal,
  `headscale nodes delete -i <id>`. O alerta some na próxima coleta.
- Se é usado (ex.: um notebook guardado), basta conectá-lo uma vez.
