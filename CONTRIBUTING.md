# Contribuindo

Este é um projeto pessoal, mas issues e PRs são bem-vindos: correções, melhorias na
documentação ou ideias para a arquitetura. Este guia explica como o repositório funciona
para que uma contribuição passe pelo CI de primeira.

## Antes de começar

- **Mudanças grandes começam por uma issue.** É o caso de um serviço novo, uma troca de
  ferramenta ou uma mudança de topologia. Se a mudança altera uma decisão registrada, ela
  vem com um ADR novo em [`docs/adr/`](docs/adr/), que segue o formato dos existentes.
- **A `main` é produção.** As VMs aplicam sozinhas cada commit da `main` (GitOps). Por isso
  todo merge passa por PR e pelos checks obrigatórios.
- **Vulnerabilidades** são reportadas em privado, por
  [*Security → Report a vulnerability*](https://github.com/MarcosDaNight/mgdn-platform/security/advisories/new),
  nunca numa issue pública.

## Ambiente local

Ferramentas: Terraform (>= 1.10), Docker com Compose, [pre-commit](https://pre-commit.com/)
e `make`.

```bash
make hooks        # instala os hooks do pre-commit
make lint         # pre-commit em tudo + terraform validate
make test-infra   # terraform test com provider simulado (sem credenciais)
```

Para validar a configuração de um papel como o CI faz:

```bash
cd deploy/primary
docker compose config --quiet
docker compose run --rm --no-deps -T blocky validate
docker compose run --rm --no-deps -T --entrypoint promtool -w /etc/prometheus/tests \
  prometheus test rules slo_test.yml gitops_test.yml
```

## Fluxo de trabalho

1. Crie uma branch a partir da `main`, com um nome descritivo (ex.: `feat/actual-budget`).
2. Faça commits no padrão [Conventional Commits](https://www.conventionalcommits.org/pt-br/v1.0.0/),
   em inglês: `feat:`, `fix:`, `docs:`, `ci:`, `chore:`, com escopo opcional
   (`fix(grafana): ...`).
3. Abra o PR. Ele precisa destes checks verdes:

   | Check | O que verifica |
   |---|---|
   | `pre-commit` | formatação, YAML/JSON, shellcheck, chaves privadas e segredos (gitleaks) |
   | `terraform` | `fmt`, `validate` e `terraform test` |
   | `deploy-config (primary)` / `(secondary)` | Compose, Blocky, Prometheus, testes das regras, Alertmanager e blackbox |
   | `supply-chain` | Trivy nas imagens: CRITICAL com correção disponível bloqueia |

4. Se o PR mexe em `infra/`, o workflow `terraform-plan` comenta o plano. Leia antes do
   merge: ⚠️ indica que uma VM ou um IP público será recriado.
5. Depois do merge, as VMs aplicam a mudança em até ~2 min. Mudanças em `infra/` são
   aplicadas à mão pelo mantenedor (`make apply`).

## Convenções

- **Imagens fixadas por tag e digest** (`imagem:1.2.3@sha256:...`) e **Actions pelo SHA**,
  com a versão em comentário. O Dependabot mantém os dois atualizados.
- **Todo serviço tem `mem_limit`.** A VM principal tem 2 GB, e a soma dos limites precisa
  caber.
- **Nada é publicado na internet além das portas 53 e 443.** UIs ficam em `127.0.0.1` ou
  atrás do Traefik com o middleware `tailnet-only`.
- **Nenhum segredo ou dado pessoal no Git**: tokens, IP de casa, hostname do DDNS, URLs de
  healthcheck ou tópicos do ntfy. Segredos chegam às VMs pelo `terraform.tfvars`, que fica
  fora do Git, e o gitleaks barra os vazamentos mais comuns.
- **Alerta novo vem com teste e runbook**: um teste em `deploy/primary/prometheus/tests/` e
  um runbook em `docs/runbooks/`, referenciado em `runbook_url`.
- **Documentação em português**, com frases diretas. O README descreve o estado atual; o
  histórico fica nos ADRs e no Git.

## Adicionar um app

Comece por `make new-app` e siga o passo a passo em [`docs/adicionar-app.md`](docs/adicionar-app.md).
