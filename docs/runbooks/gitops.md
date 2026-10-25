# Runbook: GitOpsFailing / GitOpsBehind / GitOpsStale / GitOpsSelfHealFlapping

O GitOps sync (`scripts/gitops-sync.sh`, a cada 2 min) busca a `main`, valida, aplica e
verifica o DNS. Sem commit novo, faz self-heal (`compose up -d`). Toda execução publica
métricas `mgdn_gitops_*`; o dashboard **Plataforma (GitOps)** mostra o estado por host.

## Diagnóstico
`make status HOST=mgdn-<primary|secondary>` e, na VM, `journalctl -u mgdn-gitops -n 50`.

| Alerta | Causa provável | O que fazer |
|---|---|---|
| **GitOpsFailing** | GitHub fora (fetch), validação recusou (Blocky, promtool, Headscale, amtool) ou deploy falhou | leia o erro no journal; se for o commit, corrija por PR |
| **GitOpsBehind** | o commit da `main` falhou na validação ou houve rollback (o sync não tenta de novo o mesmo commit) | corrija e faça um commit novo |
| **GitOpsStale** | o timer está parado (ex.: `make headscale-drain` sem recriar a VM depois) | `sudo systemctl start mgdn-gitops.timer` |
| **GitOpsSelfHealFlapping** | algo para containers repetidamente: crash, OOM (`mem_limit`) ou intervenção manual | `make logs SERVICE=<serviço>`; `docker inspect` para ver OOMKilled |

## Forçar um sync
`make sync` (ou `sudo /opt/mgdn-platform/scripts/gitops-sync.sh --force` na VM).
