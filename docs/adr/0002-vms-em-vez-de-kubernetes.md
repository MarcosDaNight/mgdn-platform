# 0002. VMs com Docker Compose em vez de Kubernetes

- **Status:** aceita
- **Data:** 2026-10-24

## Contexto

A evolução natural de um "homelab na nuvem" costuma ser o Kubernetes (gerenciado ou k3s),
com ArgoCD, Kyverno, Loki e afins. As restrições reais deste projeto são:

- **Orçamento:** alvo de R$ 100/mês, teto de R$ 135, com R$ 300/mês de crédito.
- **Carga:** 1 usuário e poucos serviços leves (Blocky ~75 MB, Headscale ~50 MB).
- **Preços medidos ou cotados na Magalu Cloud (out/2026):**

  | Tipo | vCPU / RAM | R$/mês |
  |---|---|---|
  | BV1-1-10 | 1 / 1 GB | ~35 (medido na fatura) |
  | BV2-2-10 | 2 / 2 GB | 59,99 |
  | BV2-4-10 | 2 / 4 GB | 82,99 |

Só a camada de plataforma do Kubernetes (control plane + ArgoCD + Kyverno + Loki) consome
2–3 GB de RAM antes de rodar qualquer serviço. Isso exigiria pelo menos uma BV2-4-10 e não
teria redundância. Com DBaaS e Load Balancer, a conta passa do teto.

## Decisão

Seguir com **VMs pequenas e Docker Compose**, reconciliadas por **GitOps pull**: o
`gitops-sync` herdado do v1, com validação antes de aplicar e rollback automático.

- O orçamento vai para **redundância real**: duas VMs em regiões diferentes (ADR próprio na
  fase 2).
- As práticas que o Kubernetes traria continuam no projeto, mas na forma barata: deploy
  declarativo, imagens fixadas por digest, varredura no CI, SLOs e restore drills.

## Consequências

- **Positivas:** ~R$ 95/mês com redundância entre regiões, menos peças para operar e um
  modelo de deploy já validado em produção no v1.
- **Negativas:** sem agendamento automático entre nós e sem o ecossistema Kubernetes.
  Escalar um serviço exige alterar o Terraform e o Compose à mão.
- **Revisão:** reavaliar se os serviços passarem de ~5 ou se o orçamento subir para comportar
  um k3s com pelo menos 2 nós de 4 GB.
