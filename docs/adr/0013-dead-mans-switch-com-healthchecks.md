# 0013. Dead man's switch do caminho de alertas com o healthchecks.io

- **Status:** aceita
- **Data:** 2026-10-25

## Contexto

O Prometheus e o Alertmanager rodam só na VM principal (ADR 0009). Os alertas saem dela
para o ntfy.sh e chegam no celular. A queda da VM inteira já era coberta: o
`healthcheck.sh` pinga o check **principal** do healthchecks.io a cada 5 min (ADR 0005).

Faltava cobrir o **caminho de alertas quebrado com a VM no ar**. Nenhuma checagem existente
percebe estes casos:

- o Alertmanager ou o Prometheus caídos (o Alertmanager tem só 64 MB de `mem_limit`);
- uma configuração válida que não roteia ou não avalia;
- a saída do Alertmanager para a internet bloqueada.

Em qualquer um deles, os alertas param em silêncio, e silêncio parece "tudo bem".

## Alternativas consideradas

| Opção | Por que não |
|---|---|
| **ntfy próprio** | Mais privacidade para os alertas, mas roda na mesma VM: cai junto e não detecta nada. Continua nos próximos passos, por outro motivo. |
| **Segundo Alertmanager na secundária** | Para vigiar a principal, a secundária precisaria também de um Prometheus. São ~300 MB numa VM de 1 GB, com configuração duplicada, e o vigia continuaria dentro da mesma conta e do mesmo provedor da coisa vigiada. |
| **Watchdog → healthchecks.io** | **Escolhida.** É externo, gratuito (o plano gratuito tem 20 checks; usamos 4) e já está em uso. Não consome RAM. |

## Decisão

- **Regra `Watchdog`** (`expr: vector(1)`, `severity: none`) em
  `deploy/primary/prometheus/rules/watchdog.yml`, com teste em `promtool`.
- **Rota dedicada no Alertmanager:** `alertname="Watchdog"` vai só para o receiver
  `healthchecks`, um webhook para a URL de ping do check, com `repeat_interval: 1m`. Sem
  `continue`, ele nunca chega ao receiver `ntfy`. O `amtool config routes test` garante isso
  no CI e na VM antes de cada deploy.
- **A URL de ping é segredo.** Ela entra pelo mesmo mecanismo das outras: a variável
  `alert_watchdog_url` do Terraform vai para `ALERT_WATCHDOG_URL` no cloud-init da principal,
  e o `gitops-sync` a grava em `/etc/mgdn-platform/alertmanager/watchdog-url`, lido pelo
  Alertmanager via `url_file`. Um `terraform test` garante que ela não vai para a secundária.
- **O check é configurado à mão**, documentado no [runbook](../runbooks/watchdog.md):
  período de 2 min, grace de 3 min, ntfy como canal principal e e-mail como segundo canal.
  O provider Terraform da comunidade
  ([kristofferahl/healthchecksio](https://registry.terraform.io/providers/kristofferahl/healthchecksio/latest))
  foi avaliado e não compensa agora:
  - ele gerencia checks, mas os canais (ntfy, e-mail) só existem como data source e teriam
    de ser criados à mão de qualquer forma;
  - exigiria uma API key de escrita do projeto no `terraform.tfvars`, capaz de apagar os
    checks;
  - os três checks existentes são manuais, então só este ficaria como código.

  Reavaliar se o número de checks crescer.
- **Critério de aceite medido:** com o Alertmanager parado, medir o tempo até o aviso chegar
  no celular. O procedimento está no runbook; o esperado é até ~7 min.

## Consequências

- **Dependência de um serviço externo.** Se o healthchecks.io cair, pode haver um alarme
  falso ou a falta de um aviso; o caminho principal (Alertmanager → ntfy) não depende dele.
  Os termos do plano gratuito podem mudar.
- **O healthchecks.io também avisa pelo ntfy.sh.** Uma queda do ntfy.sh derrubaria os
  alertas e o aviso do dead man's switch ao mesmo tempo. Por isso o e-mail fica como segundo
  canal do check.
- **Limitação conhecida:** o Watchdog sai por outro receiver. Se a URL do ntfy estiver
  errada, os alertas reais param e o Watchdog continua pingando. Ele prova que o
  Prometheus avalia, que o Alertmanager roteia e que a saída para a internet funciona; não
  prova a entrega no receiver `ntfy`.
- **Definir `alert_watchdog_url` recria a VM principal**, como toda mudança no cloud-init:
  `make headscale-drain` antes do `make apply`. Em manutenção planejada, pause o check para
  não receber um alarme falso.
- Quem tiver a URL de ping pode mascarar uma falha pingando o check. Ela fica fora do Git,
  como os outros segredos.
