# 0018. Monitor de preços (precos)

- **Status:** aceita
- **Data:** 2026-11-10

## Contexto

Quero comprar um Nintendo Switch 2 e alguns jogos na Black Friday (27/11/2026) pelo menor preço, sem
ficar abrindo lojas. O monitor precisa coletar pelo menos uma vez por dia, guardar o histórico e avisar
quando um item chegar à meta ou ao menor preço, de forma confiável e **sem custo**.

## Decisão

- **App próprio, no fluxo do Timoneiro** ([ADR 0016](0016-app-proprio-e-imagem-no-ghcr.md)): repositório
  [`mgdn-precos`](https://github.com/MarcosDaNight/mgdn-precos), imagem no ghcr com digest fixo, SQLite no
  volume `precos-data` (backup, restore e DR drill pelos labels, [ADR 0015](0015-contrato-de-app-por-labels.md)).
  Painel em `precos.mgdn.com.br`, só pela tailnet (uma tabela HTML; gráficos ficam para depois).
- **Quais lojas, e por quê.** Os **termos de uso vencem o `robots.txt`**:
  - **KaBuM:** leitura das páginas de produto por URL fixa, volume baixo, User-Agent identificável. Não
    achei cláusula que proíba.
  - **Mercado Livre:** **só pela API oficial**, com token, nunca por HTML (aguarda a validação da conta).
  - **Fora, de propósito:** Fast Shop (os termos proíbem robôs, cláusula 6.1 c), Amazon (as Condições de Uso
    proíbem robôs e a API exige afiliado com vendas), Magalu (loja do meu empregador; sem scraping contornando
    anti-bot) e Nintendo Store BR (não vende mídia física). Essas ficam com os alertas gratuitos do Keepa e
    do Zoom/Buscapé, sem código.
- **Nunca** User-Agent de navegador, nunca contornar bloqueio ou captcha. 403/429 **desativa a loja** e
  avisa; `python -m precos enable <loja>` reativa.
- **Só entra no histórico** o que é novo, vendido e entregue pela própria loja, físico (jogos) e com o
  título certo. Uma leitura muito abaixo da mediana espera a confirmação da leitura seguinte, para um erro de
  parser não gerar um falso "COMPRAR".
- **Metas e parcelas:** a KaBuM informa Pix e parcelas sem juros; o Mercado Livre só o valor à vista. A meta
  parcelada só vale para quem informa parcelas; numa loja que não informa, vale **só a meta Pix/à vista** (R$ 3.700
  no console), e a mensagem do alerta diz isso.
- **Notificação pelo ntfy**, em **tópico secreto próprio**, separado do Alertmanager (os avisos de compra não
  se misturam com alertas de infraestrutura). O tópico vem de segredo cifrado ([ADR 0014](0014-segredos-cifrados-no-repositorio.md)).
- **Confiabilidade sem Prometheus nesta versão:** o `/healthz` vira 503 sem coleta bem-sucedida em 26 h (o
  healthcheck da plataforma já avisa), e o app dá um *heartbeat* no Healthchecks a cada rodada que coleta
  (dead-man's switch, [ADR 0013](0013-dead-mans-switch-com-healthchecks.md)). Métricas ficam para a v2.
- **A config mora aqui** (`deploy/primary/precos/config.yaml`): editar uma meta é um PR, e o GitOps reinicia
  o serviço.

## Consequências

- **Risco conhecido:** a VM tem IP de datacenter, que lojas costumam bloquear mais do que um IP residencial.
  Se a KaBuM bloquear a VM, a loja é desativada e eu sou avisado; o plano B é rodar o coletor dela no `pop-os`.
- O preço lido da página pode diferir do final (frete, cupom, estoque na hora de pagar). O alerta traz o link;
  a conferência no checkout é humana.
- `mem_limit` de 96m é **estimativa** (medido: 32 MB em repouso, sem uma rodada de coleta); ajustar com
  `memory.peak` depois de alguns dias.
- Mais um serviço na principal e uma imagem de ~100 MB (estimativa) num disco que já passa de 79%.
