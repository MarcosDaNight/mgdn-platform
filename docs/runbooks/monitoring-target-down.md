# Runbook: MonitoringTargetDown

**O que significa:** o Prometheus (na principal) não coleta um alvo há 10 min. Os alertas
de SLO ficam **cegos** para ele. O alerta não diz que o serviço caiu, só que não está
sendo medido.

## Diagnóstico
- `job="dns"`: o blackbox_exporter caiu. `make status` e `make logs SERVICE=blackbox`.
- `host="secondary"` (blocky ou node): a principal não alcança `100.64.0.4` pela tailnet.
  `tailscale ping mgdn-secondary` da principal; `make status HOST=mgdn-secondary`.
- `job="headscale"`: o Headscale caiu. `make logs SERVICE=headscale`. As conexões da tailnet
  já estabelecidas seguem funcionando; aparelhos novos não entram.

## Mitigação
Reinicie o serviço com `docker compose restart <serviço>` na VM. Se a tailnet estiver
fora, use o break-glass do README.
