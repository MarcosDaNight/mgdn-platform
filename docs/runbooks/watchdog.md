# Runbook: Watchdog (dead man's switch)

**O que significa:** o check **watchdog** do healthchecks.io parou de receber pings.
Normalmente, o Prometheus mantém o alerta `Watchdog` sempre disparando, e o Alertmanager o
entrega ao healthchecks.io a cada 1–2 min ([ADR 0013](../adr/0013-dead-mans-switch-com-healthchecks.md)).
Sem pings, **algum ponto do caminho de alertas quebrou**. Enquanto isso durar, nenhum alerta
da plataforma chega no celular.

O aviso vem do healthchecks.io, por fora da plataforma: pela integração de ntfy e, como
segundo canal, por e-mail.

## Diagnóstico

Siga a ordem: cada passo descarta uma parte do caminho.

| Passo | Como verificar | Se falhar |
|---|---|---|
| 1. A VM principal está no ar? | o check **principal** do healthchecks.io também está *down*? `make status` responde? | a VM caiu: console da Magalu. O DNS segue pela secundária (ADR 0005). |
| 2. Os containers estão de pé? | `make status`: `prometheus` e `alertmanager` *Up* | `make logs SERVICE=alertmanager` (ou `prometheus`); `docker inspect` para ver `OOMKilled` |
| 3. O Prometheus avalia a regra? | `make tunnel` e, em <http://localhost:9090/alerts>, `Watchdog` em *firing* | regra fora do ar: `journalctl -u mgdn-gitops -n 50` (o último deploy falhou?) |
| 4. O Alertmanager recebeu? | <http://localhost:9093>: `alertname=Watchdog` presente | o Prometheus não alcança o Alertmanager: veja `alerting` em `prometheus.yml` |
| 5. O Alertmanager consegue enviar? | `make logs SERVICE=alertmanager`: erros `notify` para o receiver `healthchecks` | arquivo do segredo (passo abaixo) ou saída para a internet |

Para conferir o arquivo do segredo sem imprimir o valor:

```bash
sudo test -s /etc/mgdn-platform/alertmanager/watchdog-url && echo "arquivo ok"
sudo grep -c 'watchdog-desativado' /etc/mgdn-platform/alertmanager/watchdog-url   # 1 = ALERT_WATCHDOG_URL vazia
```

## Mitigação

- Container parado ou em crash: `docker compose restart alertmanager` (ou `prometheus`). O
  self-heal do GitOps também o recoloca em até ~2 min, desde que o timer esteja ativo.
- URL vazia ou errada: corrija `alert_watchdog_url` no `terraform.tfvars`. O valor chega
  pelo cloud-init, então mudar **recria a VM principal**: `make headscale-drain` e depois
  `make apply`.
- **Manutenção planejada**, como recriar a VM: pause o check no healthchecks.io (*Pause*)
  antes do `make headscale-drain`. Ele volta sozinho no primeiro ping.

## Configuração do check (manual)

O check fica fora do Terraform. O provider da comunidade gerencia checks, mas não os canais
de notificação, que teriam de ser criados à mão de qualquer forma. A justificativa está no
ADR 0013.

1. No mesmo projeto dos outros checks, crie o check **`mgdn-primary-watchdog`**, com a tag
   `mgdn`.
2. **Schedule:** *Simple*, **Period 2 min**, **Grace 3 min**. O Alertmanager pinga a cada
   1–2 min (`repeat_interval: 1m`, alinhado ao `group_interval`). A folga de 3 min absorve
   o reinício do Alertmanager num deploy e do Prometheus, sem alarme falso. O aviso chega
   até ~7 min depois do último ping.
3. **Integrations**, todas ligadas neste check:
   - **ntfy** (canal principal): servidor `https://ntfy.sh` e o tópico secreto da
     integração. Prioridade alta para *down* e normal para *up*.
   - **E-mail** (segundo canal): cobre o caso de o ntfy.sh estar fora, que derrubaria o
     ntfy dos alertas e o deste aviso ao mesmo tempo.
4. Copie a **Ping URL** para `alert_watchdog_url` no `terraform.tfvars`. Essa URL é
   segredo: com ela, qualquer um pinga o check e esconde uma falha real. No próximo
   `make apply`, que recria a principal (`make headscale-drain` antes), o Watchdog começa a
   pingar.

## Teste de aceite

Objetivo: medir o tempo entre a quebra do caminho de alertas e a chegada do aviso no
celular. Faça num horário tranquilo; durante o teste, os alertas reais também não saem.

**Antes:** o check está *up* há pelo menos 10 min, com pings a cada 1–2 min na aba
*Events*. Nenhuma mensagem "Watchdog" chegou no app do ntfy pelo tópico dos alertas (a rota
não deixa).

1. `make ssh`.
2. Pause o GitOps, senão o self-heal sobe o Alertmanager de volta em ~2 min:
   `sudo systemctl stop mgdn-gitops.timer`.
3. Anote **T0** e pare o Alertmanager:

   ```bash
   date '+%T' && sudo docker compose -f /opt/mgdn-platform/deploy/primary/compose.yaml stop alertmanager
   ```

4. Espere a notificação *down* do healthchecks.io no app do ntfy. Anote **T1**, pelo horário
   da notificação, e **T1'**, pelo horário do e-mail.
5. Restaure e anote **T2**:

   ```bash
   date '+%T' && sudo docker compose -f /opt/mgdn-platform/deploy/primary/compose.yaml start alertmanager
   sudo systemctl start mgdn-gitops.timer
   ```

6. Espere a notificação *up* e anote **T3**.

| Medição | Esperado |
|---|---|
| T1 − T0: Alertmanager parado → aviso no celular (ntfy) | ≤ ~7 min |
| T1' − T0: idem, por e-mail | ≤ ~8 min |
| T3 − T2: Alertmanager de volta → aviso de recuperação | ≤ ~2 min |

**Variante opcional: VM principal inteira desligada** (pelo console da Magalu). Ela também
dispara o check **principal**. O DNS segue pela secundária, e as conexões da tailnet já
estabelecidas continuam. Mede o mesmo T1 − T0 com a falha que motivou o ADR.

Publique os tempos na linha *Dead man's switch* do Histórico, no README.
