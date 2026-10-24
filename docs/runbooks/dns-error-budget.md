# Runbook: DNSErrorBudgetFastBurn / DNSErrorBudgetSlowBurn

**O que significa:** nenhum Blocky está resolvendo e bloqueando (*fast burn*: queda real
agora) ou há falhas intermitentes por horas (*slow burn*). O SLO é 99,9% em 30 dias,
ou ~43 min de orçamento de erro por mês. O dashboard **SLO do DNS** mostra quanto resta.

## Impacto
*Fast burn*: casa e tailnet sem DNS, ou seja, "sem internet". *Slow burn*: lentidão e falhas
ocasionais de resolução.

## Diagnóstico (da sua máquina, na tailnet)
1. `make test`: quais resolvedores respondem? (principal, secundária, tailnet)
2. Se nenhum responde pelos IPs públicos, mas a tailnet responde, é o allowlist de casa:
   `make allowlist` (o DDNS acompanha o IP atual?). Veja também `dns-resolver-down.md`.
3. Se nada responde, veja o healthchecks.io (as VMs estão vivas?) e o console da Magalu.
4. `make status` e `make status HOST=mgdn-secondary`: containers, RAM e disco.
5. `make logs` (Blocky): erros de upstream (DoH)? Se Cloudflare e Quad9 falham juntos,
   é rede da VM ou do provedor.

## Mitigação
- **Upstreams DoH fora:** acrescente um upstream em `deploy/common/blocky/config.yml` (PR).
- **VM morta:** `make apply` recria a VM. Na principal, rode `make headscale-drain` antes
  se ela ainda responder; o restore do Headscale é automático (ADR 0006).
- **Deploy ruim:** o GitOps faz rollback sozinho; se não fez, reverta o PR na `main`.

## Depois
Registre a causa no PR ou issue do incidente. Se o orçamento do mês acabou, priorize
confiabilidade em vez de mudanças novas.
