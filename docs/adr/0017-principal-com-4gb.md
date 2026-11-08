# 0017. VM principal com 4 GB de RAM

- **Status:** aceita
- **Data:** 2026-11-08

## Contexto

A principal (BV2-2-10, 2 vCPU, 2 GB) roda 12 serviços. A soma dos `mem_limit` está em
**1792 MB**, contra um orçamento de 1800 MB: o último app (Timoneiro) usou praticamente toda a
folga, e cada serviço novo já exige revisar limites dos outros. Os apps planejados (ntfy
próprio, uma segunda instância do Actual) também cabem pouco ou nada.

O orçamento de dinheiro tem folga: o custo real fica em ≈ R$ 95–99/mês, e a conta tem R$ 300 em
créditos renovados.

## Alternativas consideradas

| Opção | Por que não |
|---|---|
| **Seguir com 2 GB e apertar os limites** | Os limites já são 1,5× o pico medido; apertar mais troca RAM por reinícios por OOM. |
| **Mover serviços para a secundária (1 GB, br-se1)** | Ela tem 1 GB e é o DNS de reserva em outra região: carregá-la enfraquece justamente o que ela protege. |
| **BV2-8-10 (8 GB)** | Mais do que o necessário hoje; o custo sobe sem uso. |
| **BV2-4-10 (2 vCPU, 4 GB, mesmo disco de 10 GB)** | **Escolhida.** Dobra a RAM, mantém as 2 vCPUs (a CPU não é o gargalo) e não mexe no disco. |

## Decisão

- A principal passa de `BV2-2-10` para `BV2-4-10`. A secundária não muda.
- A mudança é só o `machine_type` no Terraform. O `make apply` mostra o plano e, **se a
  principal for recriada** em vez de redimensionada, faz o drain do Headscale antes. Mesmo num
  redimensionamento in-place a VM reinicia: rode `make headscale-drain` antes e confira o
  backup, porque o Headscale (controle da tailnet) fica fora do ar durante o reinício.
- O DNS continua respondendo pela secundária durante a janela.
- **Depois do apply**, um PR à parte atualiza o que depende da RAM (orçamento de
  `mem_limit` em `scripts/new-app.py`, `deadlines.yml`, CONTRIBUTING e README) e revisa os
  limites medidos. Isso fica separado para a documentação não afirmar uma RAM que a VM ainda
  não tem.

## Consequências

- A folga de RAM permite os próximos apps sem renegociar limites.
- O custo mensal sobe (confirmar o valor do plano no console da Magalu e registrar no README
  depois do apply).
- Há uma janela curta de indisponibilidade dos apps da tailnet (Headscale, Vaultwarden, Actual,
  FreshRSS, Timoneiro) durante o reinício. O DNS não cai.
