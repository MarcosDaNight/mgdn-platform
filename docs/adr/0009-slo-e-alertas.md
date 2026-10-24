# 0009. SLO do DNS com orçamento de erro e alertas no celular

- **Status:** aceita
- **Data:** 2026-10-24

## Contexto

Até aqui o monitoramento era binário: o healthchecks.io avisa se uma VM some, e o Grafana
mostra métricas, mas ninguém olha. Faltava responder "**o DNS está bom o suficiente?**", com
uma medida que reflita o que o usuário sente, e ser avisado com proporção: uma falha de 30 s
não é uma queda de 30 min. A VM secundária também não era coletada pelo Prometheus.

## Decisão

- **SLI:** sondas do blackbox_exporter a cada 30 s contra cada Blocky. O resolver só conta
  como ok se **resolver** (`cloudflare.com` → IPv4) **e bloquear**
  (`pagead2.googlesyndication.com` → `0.0.0.0`). Testado: um resolver que responde mas não
  bloqueia (`1.1.1.1`) é marcado como falha.
- **SLO:** **99,9% em 30 dias** para o *serviço*, que está ok se ao menos um resolver estiver
  (os clientes usam os dois). O orçamento de erro é ~43 min/mês. Cada resolver também é
  medido separadamente.
- **Alertas por taxa de consumo do orçamento** (SRE Workbook, Google), em duas janelas para
  evitar ruído:
  - `DNSErrorBudgetFastBurn` (14,4x em 1 h e em 5 min): queda real, `severity=page`;
  - `DNSErrorBudgetSlowBurn` (6x em 6 h e em 30 min): degradação persistente;
  - `DNSResolverDown`: um resolver falha há 5 min (perda de redundância);
  - `MonitoringTargetDown`: um alvo sem coleta há 10 min (alertas cegos).

  Cada alerta tem um runbook em `docs/runbooks/`.
- **Regras testadas:** `promtool test rules` com cenários de queda, no CI e na VM antes de
  aplicar.
- **Entrega no celular via ntfy** (open source, app gratuito, template nativo do
  Alertmanager). O tópico é um segredo aleatório: a URL vem de `ALERT_NTFY_URL` e é gravada
  num arquivo da VM, lido pelo Alertmanager via `url_file`. Nunca vai para o repo.
- **Secundária monitorada pela tailnet:** o Prometheus da principal coleta Blocky e
  node-exporter dela em `100.64.0.4`. Na interface pública, as portas de métricas (4000,
  9093, 9100) são descartadas pelo nftables, além de não estarem no security group.

## Consequências

- O SLO é medido **a partir da principal**. Se ela inteira cair, o Prometheus cai junto: a
  cobertura desse caso continua sendo o healthchecks.io (externo, ADR 0005).
- `ALERT_NTFY_URL` entra pelo cloud-init, então defini-la recria a VM principal uma vez
  (`make headscale-drain` antes; sem queda de DNS, ADR 0006).
- O ntfy.sh público é gratuito; o tópico aleatório faz o papel de credencial. Para mais
  privacidade, dá para auto-hospedar o ntfy depois.
