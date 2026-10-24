# 0001. Registrar decisões de arquitetura

- **Status:** aceita
- **Data:** 2026-10-24

## Contexto

O [blocky-cloud-dns](https://github.com/MarcosDaNight/blocky-cloud-dns) (`1.0.0`) acumulou
decisões importantes, como firewall no host em vez do Security Group, GitOps pull e DDNS
no roteador por causa do CGNAT. O "porquê" delas ficou espalhado entre o README, as
descrições de PR e as conversas. Quem chega depois, inclusive eu daqui a seis meses, vê o
resultado mas não as alternativas descartadas.

## Decisão

Toda decisão que muda a arquitetura, o custo ou a postura de segurança vira um ADR em
`docs/adr/`, no formato de [Michael Nygard](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions):
contexto, decisão e consequências.

- Numeração sequencial (`NNNN-titulo-curto.md`), em português, como o resto da documentação.
- Um ADR aceito não é editado; uma mudança de rumo gera um ADR novo que o **substitui**
  (`Status: substituída por 00XX`).
- O ADR entra no mesmo PR da mudança que ele justifica.

## Consequências

- Cada PR relevante custa alguns minutos a mais de escrita.
- O histórico de decisões fica versionado, revisável e linkável a partir do README.
