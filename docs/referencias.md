# Referências

Este documento reúne as fontes que embasam a arquitetura, agrupadas por decisão. Os ADRs em
[`docs/adr/`](adr/) dizem **o que** foi decidido e quais foram as alternativas. Aqui ficam as
práticas e a documentação que explicam **por que** a escolha faz sentido.

## Registro de decisões (ADR 0001)

- Michael Nygard, [*Documenting Architecture Decisions*](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions)
  (2011): o formato contexto → decisão → consequências usado em todos os ADRs.
- [adr.github.io](https://adr.github.io/): modelos e boas práticas de ADR.

## VMs com Compose em vez de Kubernetes (ADRs 0002 e 0011)

- [Requisitos do k3s](https://docs.k3s.io/installation/requirements): RAM mínima de um
  servidor k3s, antes de qualquer aplicação. É a base da conta de que a plataforma
  Kubernetes não cabe numa VM de 2 GB junto com os serviços.
- [Documentação do Argo CD](https://argo-cd.readthedocs.io/en/stable/): ele reconcilia
  manifestos de Kubernetes, por isso exigiria um cluster.
- [OpenGitOps](https://opengitops.dev/): os quatro princípios de GitOps (declarativo,
  versionado, puxado automaticamente, reconciliado continuamente). O `gitops-sync` atende
  aos quatro sem Kubernetes: estado no Git, pull a cada 2 min e self-heal.
- Alternativas avaliadas para Compose: [Komodo](https://komo.do/) e
  [Doco-CD](https://github.com/kimdre/doco-cd).
- [The Twelve-Factor App: configuração](https://12factor.net/pt_br/config): a configuração
  fica fora do código. Por isso os segredos vão para o ambiente da VM, não para o Git.

## Tailnet com Headscale (ADR 0003)

- [Headscale](https://github.com/juanfont/headscale): implementação aberta do servidor de
  controle do Tailscale, compatível com os clientes oficiais.
- Tailscale, [*How NAT traversal works*](https://tailscale.com/blog/how-nat-traversal-works):
  por que a tailnet funciona atrás de CGNAT, sem abrir portas em casa, e o papel dos DERPs.
- [Subnet routers](https://tailscale.com/kb/1019/subnets): de onde vem a opção
  `--snat-subnet-routes=false`. Ela faz o Blocky ver o IP real de cada aparelho.

## DNS com bloqueio e redundância (ADRs 0004 e 0005)

- [Documentação do Blocky](https://0xerr0r.github.io/blocky/latest/): listas de bloqueio,
  `customDNS` (split-horizon) e upstreams.
- [RFC 8484: DNS over HTTPS](https://www.rfc-editor.org/rfc/rfc8484): o upstream cifrado
  entre o Blocky e a Cloudflare/Quad9.
- Google SRE, [*Service Level Objectives*](https://sre.google/sre-book/service-level-objectives/):
  a disponibilidade se mede do ponto de vista do usuário. Daí o segundo resolvedor em
  outra região, em vez de mais recursos na mesma VM.

## Backup imutável e restore drill (ADRs 0006 e 0007)

- [age](https://age-encryption.org/): criptografia de arquivos com chave pública. A VM só
  cifra; a chave privada fica fora dela.
- [S3 Object Lock](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html):
  modos GOVERNANCE e COMPLIANCE. O Object Storage da Magalu Cloud implementa a mesma API.
  O modo COMPLIANCE impede que alguém apague um backup antes do prazo, inclusive o dono.
- Google SRE Workbook, [*Implementing SLOs*](https://sre.google/workbook/implementing-slos/):
  um backup só conta depois de um restore testado. Daí o drill mensal com RTO e RPO medidos.

## Cadeia de suprimentos (ADR 0008)

- GitHub, [*Security hardening for GitHub Actions*](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions):
  fixar Actions pelo SHA completo do commit, já que uma tag pode ser movida.
- Docker, [*Pull an image by digest*](https://docs.docker.com/reference/cli/docker/image/pull/#pull-an-image-by-digest-immutable-identifier):
  o digest é imutável; a tag, não.
- [SLSA](https://slsa.dev/): níveis de integridade da cadeia de suprimentos.
- [Trivy](https://trivy.dev/): a varredura de vulnerabilidades das imagens no CI.

## SLO e alertas (ADR 0009)

- Google SRE Workbook, [*Alerting on SLOs*](https://sre.google/workbook/alerting-on-slos/):
  alertas por taxa de consumo do orçamento de erro em múltiplas janelas. As regras de
  `deploy/primary/prometheus/rules/slo.yml` seguem a tabela recomendada.
- [Textfile collector do node-exporter](https://github.com/prometheus/node_exporter#textfile-collector):
  como o `gitops-sync` publica métricas sem rodar um servidor HTTP próprio.

## Borda HTTPS e apps (ADR 0010)

- Let's Encrypt, [tipos de desafio](https://letsencrypt.org/docs/challenge-types/): o
  DNS-01 emite certificados para nomes que não estão na internet, como os apps da tailnet.
- Let's Encrypt, [limites de emissão](https://letsencrypt.org/docs/rate-limits/): por isso
  os certificados entram no backup.
- Traefik, [provider Docker](https://doc.traefik.io/traefik/providers/docker/): acesso ao
  socket do Docker equivale a root no host. Por isso o Traefik usa o provider de arquivo.
- Traefik, [IPAllowList](https://doc.traefik.io/traefik/middlewares/http/ipallowlist/): o
  middleware `tailnet-only`.
- [Vaultwarden](https://github.com/dani-garcia/vaultwarden): servidor compatível com os
  clientes do Bitwarden, leve o bastante para a VM.

## Infraestrutura como código e testes

- [Provider Terraform da Magalu Cloud](https://registry.terraform.io/providers/MagaluCloud/mgc/latest/docs)
  e [documentação da Magalu Cloud](https://docs.magalu.cloud/).
- [Provider Terraform da Cloudflare](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs):
  a zona `mgdn.com.br` como código.
- [`terraform test`](https://developer.hashicorp.com/terraform/language/tests) e
  [providers simulados](https://developer.hashicorp.com/terraform/language/tests/mocking):
  testes da infraestrutura sem credenciais e sem criar recursos.
- GitHub, [*Automating Dependabot with GitHub Actions*](https://docs.github.com/en/code-security/dependabot/working-with-dependabot/automating-dependabot-with-github-actions):
  o padrão do merge automático de patches.
