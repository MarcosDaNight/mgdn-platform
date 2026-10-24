# 0005. DNS secundário em outra região

- **Status:** aceita
- **Data:** 2026-10-24

## Contexto

Depois da fase 1, uma única VM (br-ne1) atende o DNS da casa e da tailnet. Se ela cair,
por falha, reboot de patch ou deploy ruim, a casa fica sem resolução de nomes. Na prática,
"sem internet". O v1 já passou por isso: 19 horas sem DNS numa troca de IP de casa.

Opções avaliadas:

| Opção | Custo | Cobre |
|---|---|---|
| DNS público (ex.: 8.8.8.8) como secundário no roteador | R$ 0 | queda total, mas **vaza anúncios**: os aparelhos alternam entre os servidores |
| Segunda VM na **mesma região** | ~R$ 35 | falha da VM, mas não falha da região |
| Segunda VM em **br-se1** | ~R$ 35 | falha da VM e da região, sem vazar anúncios |

## Decisão

- **VM secundária BV1-1-10 em br-se1**, só com o Blocky e a mesma configuração
  (`deploy/common/blocky`). Ela é o **DNS secundário** do roteador e da tailnet.
- Os clientes alternam entre os dois servidores. Como ambos bloqueiam igual, isso não
  causa vazamento.
- **Monitoramento independente:** cada VM pinga o **seu** check no healthchecks.io. Um check
  compartilhado esconderia a queda de uma VM enquanto a outra seguisse pingando.
- A checagem de "tráfego de casa" fica só na principal, porque a secundária quase não
  recebe consultas enquanto a principal está saudável.
- **Entrada na tailnet** com uma chave de uso único (1 h) entregue pelo cloud-init. Depois
  de consumida, ela não serve para mais nada, mesmo continuando no state do Terraform.

## Consequências

- Custo total ≈ R$ 95/mês, dentro do alvo de R$ 100.
- A secundária tem IP público próprio, que precisa ser configurado como DNS secundário no
  roteador (passo manual, feito uma única vez).
- Recriar a secundária exige gerar uma chave nova (`make tailnet-key`). Isso está no runbook.
- As métricas da secundária (Prometheus) ficam para a fase 4. Até lá, a saúde dela é vista
  pelo healthcheck próprio.
