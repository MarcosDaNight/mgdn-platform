# 0011. GitOps sem ArgoCD: self-heal, plano no PR e auto-merge de patches

- **Status:** aceita
- **Data:** 2026-10-25

## Contexto

O ArgoCD é a referência de GitOps, e a pergunta "por que não usar o Argo?" é natural. Ele
reconcilia **manifestos de Kubernetes**; esta plataforma roda Docker Compose em VMs (ADR
0002). Adotá-lo exigiria um k3s (~0,5–1 GB de RAM) mais o próprio Argo (~0,5 GB) e a migração
de toda a stack, numa VM principal com ~1,1 GB livres.

O `gitops-sync` já fazia o núcleo do Argo: pull da `main`, validação, aplicação, verificação de
saúde (o DNS responde) e rollback automático, provados em várias recriações. Comparado ao
Argo, faltavam:

1. **Self-heal:** desvio fora do Git (container parado ou removido) só era corrigido no
   próximo commit.
2. **Visibilidade:** nenhum painel nem alerta quando o sync falha ou fica para trás.
3. **Diff antes do merge:** os PRs não mostravam o que o `terraform apply` faria.

Ferramentas de GitOps para Compose (Komodo, Doco-CD) foram consideradas. O Komodo exige um banco
(MongoDB/FerretDB) e um agente por host, pesado para a secundária de 1 GB. O Doco-CD
substituiria o sync atual por um equivalente sem a validação específica (Blocky, promtool,
Headscale) nem o rollback por saúde do DNS.

## Decisão

Manter o `gitops-sync` e completar as lacunas com o que já existe:

- **Self-heal:** sem commit novo, o sync roda `compose up -d` (idempotente) e conta os
  containers recolocados. Testado: um container parado à mão volta no ciclo seguinte.
- **Métricas e alertas:** toda execução, inclusive as que falham, publica `mgdn_gitops_*`
  (resultado, último sucesso, atraso em relação à `main`, correções, commit aplicado) pelo
  textfile collector do node-exporter. Alertas `GitOpsFailing`, `GitOpsBehind`,
  `GitOpsStale` e `GitOpsSelfHealFlapping`, com testes em `promtool` e runbook. Dashboard
  *Plataforma (GitOps)*.
- **`terraform plan` em todo PR que mexe em `infra/`**, comentado no próprio PR (só ações e
  endereços, nunca valores: o repositório é público), com aviso quando uma VM ou um IP seria
  recriado. O **apply continua manual**.
- **Auto-merge de atualizações de patch do Dependabot**, pelo merge nativo do GitHub, que só
  acontece depois de todos os checks obrigatórios. Minor e major seguem para revisão.

## Consequências

- O plano no CI precisa do `terraform.tfvars` (sem ele, o cloud-init das VMs aparece como
  diferente) e de credenciais de leitura do estado. Isso coloca segredos da plataforma nos
  secrets do GitHub. O risco adicional é pequeno: o GitHub **já é a âncora de confiança**,
  porque quem controla a `main` controla o que as VMs executam (GitOps pull). Mitigações: a
  chave da Magalu do CI é **só leitura**; os secrets não chegam a PRs de forks nem do
  Dependabot.
- Mudanças de patch entram em produção sem revisão humana. Rede de segurança: CI completo,
  Trivy, validação e rollback na VM, alertas de SLO e de GitOps.
- Sem a interface web do Argo: o estado aparece no Grafana e nos logs (`make status`).

## Atualização (2026-10-25)

O auto-merge passou a incluir as atualizações **minor de imagens de container**. Os alertas
de host e o healthcheck externo dos apps cobrem o que o rollback por DNS não cobre. Minor de
Actions e de providers do Terraform e todo major continuam com revisão.
