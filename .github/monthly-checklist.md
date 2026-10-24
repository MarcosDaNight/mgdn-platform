Checklist mensal de manutenção do mgdn-platform. Marque os itens e feche a issue quando terminar.

### DDNS e acesso de casa
- [ ] **No-IP:** confirmar o hostname (e-mail *"Confirm your hostname"* ou <https://my.noip.com>). No plano gratuito, ele expira se não for confirmado a cada 30 dias.
- [ ] `make allowlist`: o IP liberado é igual ao IP atual de casa (`curl -s https://1.1.1.1/cdn-cgi/trace | grep ip=`).

### Saúde
- [ ] <https://healthchecks.io>: os três checks (**principal**, **secundária**, **backup**) estão *up*, sem falhas inesperadas no mês.
- [ ] `make test`: as duas VMs e a tailnet resolvem e bloqueiam.
- [ ] `make status` e `make status HOST=mgdn-secondary`: RAM disponível > 100 MB, disco < 80%, commit aplicado igual ao último da `main`.

### Backup e DR
- [ ] A issue **DR drill** deste mês (aberta no dia 2) está *OK*, com RTO e RPO coerentes.
- [ ] `make backups`: há backups recentes e a rotação está mantendo ~30 diários + mensais.

### Tailnet
- [ ] `make tailnet-nodes`: só aparelhos conhecidos. Remova os que você não usa mais.

### Atualizações
- [ ] Revisar e mergear os PRs abertos do Dependabot. Isso também mantém o repo ativo: o GitHub desativa workflows agendados (como este) depois de 60 dias sem commits.

### Prazos
- [ ] API key `blocky-terraform` (Terraform, `.env`): expira em **28/09/2027**.
- [ ] API keys `mgdn-backup` e `mgdn-backup-ro`: expiram em **24/10/2027**. Renovar exige atualizar o `terraform.tfvars` (recria a principal; rode `make headscale-drain` antes) e os secrets do GitHub.
- [ ] Domínio próprio: quando for comprado, substituir o `mgdn-platform.duckdns.org` (ADR novo).
