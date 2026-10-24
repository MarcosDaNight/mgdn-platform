# Runbook: DNSResolverDown

**O que significa:** um Blocky (`resolver=primary` ou `secondary`) falha nas sondas há
5 min: não responde, não resolve `cloudflare.com` ou **não bloqueia**
`pagead2.googlesyndication.com`. O serviço segue pelo outro resolver, mas **sem
redundância**.

## Diagnóstico
1. `make test`: confirme qual resolvedor falha e se é resolução ou bloqueio.
2. `make status HOST=mgdn-<primary|secondary>`: o container `blocky` está *healthy*?
3. `make logs HOST=mgdn-<...>`: a lista de bloqueio carregou (`group import finished
   ... total_count=` > 0)? Se `total_count=0`, a HaGeZi ficou inacessível; o cache em
   disco cobre restarts, mas não uma VM nova.
4. Só a secundária falha e ela está viva? Confira a tailnet: `tailscale ping mgdn-secondary`.
   As sondas vão para `100.64.0.4`.

## Mitigação
- Container travado: `make ssh HOST=...` e `sudo docker compose -f /opt/mgdn-platform/deploy/<role>/compose.yaml restart blocky`.
- VM morta: `make apply` recria. Na **secundária**, gere uma chave nova antes (`make tailnet-key`
  → `secondary_tailnet_authkey`) e, depois, atualize o IP dela no Headscale (README,
  "Backup e DR").
