# Monitor de preços (precos)

Coleta preços do Nintendo Switch 2 e de alguns jogos, guarda o histórico e avisa no ntfy. Decisões em
[ADR 0018](adr/0018-monitor-de-precos.md); código em [mgdn-precos](https://github.com/MarcosDaNight/mgdn-precos).
Painel: `https://precos.mgdn.com.br` (só pela tailnet).

## Ligar (uma vez)

1. **ntfy:** escolha um tópico secreto e longo (por exemplo `precos-` + 20 letras aleatórias) e assine no
   celular. Ele **não** é o tópico do Alertmanager.
2. **Healthchecks.io:** crie um check "precos" com período de **1 dia** e tolerância de **4 h**; copie a URL de ping.
3. Grave os segredos (o valor é pedido no terminal, nunca vai para o Git nem para o chat):

   ```bash
   make secrets-set ROLE=primary KEY=PRECOS_NTFY_URL          # https://ntfy.sh/<topico-secreto>
   make secrets-set ROLE=primary KEY=PRECOS_HEALTHCHECK_URL   # a URL de ping do passo 2
   ```

   O GitOps entrega os valores em `/etc/mgdn-platform/precos/` e **reinicia o serviço** quando algum muda.

## Mercado Livre (depois que a conta for validada)

Crie o app em developers.mercadolivre.com.br (escopos `read` e `offline_access`; Redirect URI
`https://precos.mgdn.com.br/ml/callback`), grave o `PRECOS_ML_CLIENT_SECRET` com `make secrets-set`, ponha o
`ML_CLIENT_ID` no `compose.yaml` e autorize **uma vez**, dentro do container:

```bash
make ssh        # abre a VM; os comandos abaixo rodam LÁ (o alias PC abrevia a chamada do Compose)
PC='sudo docker compose -f /opt/mgdn-platform/deploy/primary/compose.yaml exec precos python -m precos'
$PC ml-auth-url                  # abra a URL e autorize
$PC ml-auth <code>               # o code= da URL de retorno (a página pode dar 404)
$PC ml-check <link-do-anúncio>
```

Só depois cole os links dos anúncios (**Loja Oficial**) em `stores.mercadolivre` do `config.yaml`.

## Dia a dia

| Quero | Faço |
|---|---|
| Mudar uma meta ou uma URL | editar `deploy/primary/precos/config.yaml` e abrir um PR |
| Ver o que foi coletado e recusado | abrir o painel |
| Reativar uma loja desativada por bloqueio | na VM, `$PC enable kabum` (com o `PC` definido acima) |
| Rodar uma rodada agora, sem avisar | na VM, `$PC --dry-run once` |
| Ver o log | `make logs SERVICE=precos` |
| Ver por que uma URL não é lida | a seção **Falhas** do painel (URL, nº de falhas seguidas e o erro) |
