# 0004. Evoluir o blocky-cloud-dns em vez de recomeçar

- **Status:** aceita
- **Data:** 2026-10-24

## Contexto

O [blocky-cloud-dns](https://github.com/MarcosDaNight/blocky-cloud-dns) está em produção
desde 28/09/2026 e funciona: GitOps com rollback, allowlist que acompanha o IP dinâmico
(já testado numa troca real de IP), healthcheck externo e limites de disco. Também tem
limitações estruturais: uma VM só (ponto único de falha), DNS sem criptografia e nenhum
bloqueio fora de casa.

## Decisão

- O v1 fica **congelado na release [`1.0.0`](https://github.com/MarcosDaNight/blocky-cloud-dns/releases/tag/1.0.0)**
  e continua no ar até a migração terminar.
- O **mgdn-platform** reaproveita o código que já se provou em produção (`gitops-sync`,
  `allowlist`, `healthcheck` e os limites de disco) e passa a gerenciar **mais de um host**.
  Cada VM tem um papel (`primary` ou `secondary`) e aplica a stack desse papel.
- **Migração sem mexer no roteador:** a VM principal nova **herda o IP público
  `201.23.0.88`**. O IP sai do state do v1 (bloco `removed`) e entra no do v2 (bloco
  `import`), sem ser destruído e recriado.
- A **mesma região principal (br-ne1)** do v1 é mantida. A secundária e os backups ficam em
  br-se1.

## Consequências

- O DNS de casa só fica fora do ar durante a troca da VM (minutos), e o roteador não muda.
- O v1 vira histórico consultável. O README do v2 aponta para ele e para este ADR.
- Correções feitas no v2 nas partes reaproveitadas não voltam para o v1.
