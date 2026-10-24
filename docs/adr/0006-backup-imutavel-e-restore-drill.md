# 0006. Backup imutável do Headscale e restore drill mensal

- **Status:** aceita
- **Data:** 2026-10-24

## Contexto

O único estado que não pode ser recriado a partir do Git é o do **Headscale**: o banco
(aparelhos, usuários, chaves) e a **chave privada Noise** do servidor. Sem ela, todos os
aparelhos precisam entrar de novo na tailnet. Hoje, recriar a VM principal (troca de imagem,
mudança no cloud-init) apaga esse estado. Blocky, Grafana e Prometheus são reconstruídos
pelo GitOps; o que eles guardam (logs e métricas) é descartável.

O estado tem ~160 KB e muda pouco, quando um aparelho entra ou sai.

## Decisão

- **Backup diário** na VM principal (`mgdn-backup.timer`, 03:15). O pacote inclui:
  snapshot do SQLite pela API de backup online (consistente com o Headscale rodando, com
  verificação de integridade), a chave Noise, o cache do certificado e o
  `tailscaled.state` da própria VM. Sem esse último, a VM recriada viraria um nó novo e
  perderia o `100.64.0.1`, que é o DNS da tailnet.
- **Cifrado com `age`.** A chave pública fica no repositório
  (`deploy/primary/backup/recipient.txt`). A privada fica no gerenciador de senhas do
  dono, na VM principal (necessária para o restore automático) e nos secrets do GitHub
  (para o drill).
- **Bucket imutável em br-se1**, longe da principal (br-ne1): versionado, com **object
  lock COMPLIANCE de 30 dias**. Testado: apagar uma versão retorna *"object protected by
  object lock"*. Credenciais vazadas não conseguem apagar backups recentes.
- **Restore automático no boot:** no primeiro deploy de uma VM principal nova, o GitOps
  restaura o backup mais recente antes de subir o Headscale. Recriar a VM deixa de derrubar
  a tailnet.
- **Restore drill mensal no GitHub Actions:** restaura num runner descartável, sobe o
  Headscale com o backup, confere os nós e publica **RTO** (tempo até o Headscale restaurado
  responder) e **RPO** (idade do backup) numa issue. Uma falha fica aberta e notifica.
- **Credenciais separadas e mínimas:** `mgdn-backup` (Object Storage leitura e escrita) só
  na VM; `mgdn-backup-ro` (só leitura) no GitHub. Testado: a chave de leitura recebe 403 ao
  tentar gravar.
- **Sem dependências extras:** `curl --aws-sigv4` (o object lock exige `Content-MD5`),
  `sqlite3` e `age`, todos dos repositórios do Ubuntu.

Alternativas descartadas:
- **restic:** o `prune` dele apaga pacotes antigos, o que conflita com o object lock, e
  ele resolve problemas (deduplicação de GBs) que 160 KB não têm.
- **Drill numa VM nova:** mediria também o tempo de boot, mas exigiria credenciais de
  criação de VM no CI. O RTO de infraestrutura (~4 min de bootstrap) já foi medido na troca
  do v1 e é registrado à parte.

## Consequências

- Custo desprezível: ~11 KB por backup.
- O escopo das chaves da Magalu é por serviço, não por bucket: a chave da VM também
  enxerga outros buckets da conta. O object lock limita o estrago nos backups; o bucket do
  state do Terraform depende só do versionamento.
- A chave privada `age` na VM permite decifrar backups antigos, mas quem compromete a VM já
  tem o estado vivo do Headscale, então a exposição adicional é marginal.
- A **VM secundária** não tem estado nem backup. Se for recriada, entra na tailnet como um
  nó novo, com outro IP, e o DNS da tailnet precisa ser atualizado no Headscale (runbook no
  README).
