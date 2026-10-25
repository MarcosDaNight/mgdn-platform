# 0015. Contrato de app por labels do Compose

- **Status:** aceita
- **Data:** 2026-10-25

## Contexto

Cada app com dados (Headscale, Vaultwarden, Actual Budget e os certificados do Traefik)
tinha um bloco escrito à mão em quatro lugares: `backup.sh`, `restore.sh`, o DR drill e o
`gitops-sync.sh`. Os apps da tailnet tinham ainda um bloco no `healthcheck.sh`. Adicionar o
Actual Budget mexeu em sete arquivos, e o guia de novo app tinha oito passos.

O custo não era só de trabalho. Cada bloco era uma chance de esquecer um app em um dos
lugares: um app fora do backup, ou com backup e sem restore, só apareceria no dia do
desastre.

## Alternativas consideradas

| Opção | Por que não |
|---|---|
| **Manter os blocos** | É o problema acima. |
| **Arquivo de inventário à parte** (`apps.yml`) | Uma segunda fonte de verdade, que pode divergir do Compose. |
| **Provider Docker do Traefik** (rotas por label) | Exige o socket do Docker no Traefik, que é a porta de entrada pública da VM. O ADR 0010 descartou isso. |
| **Labels no próprio serviço do Compose** | **Escolhida.** A declaração fica ao lado do serviço que ela descreve. |

## Decisão

- **Cada app declara o que precisa em labels** do serviço, em `deploy/primary/compose.yaml`:

  | Label | Para quê |
  |---|---|
  | `mgdn.backup.volume` | volume que entra no backup, no restore e no drill |
  | `mgdn.backup.ready` | arquivo que indica que há dados (backup e `--if-empty`) |
  | `mgdn.backup.exclude` | caminhos do volume fora do backup |
  | `mgdn.url`, `mgdn.health` | healthcheck pelo Traefik, com origem na tailnet |
  | `mgdn.port` | porta em que o drill sobe o app |
  | `mgdn.summary` | consulta no SQLite restaurado, mostrada na issue do drill |

- **`scripts/apps.py` é o único leitor:** ele lê o `docker compose config` e entrega listas
  para os scripts em shell. Nenhum script conhece apps pelo nome, exceto as partes que são
  de fato específicas:
  - o Headscale no drill, que confere os nós;
  - os certificados no drill;
  - o `tailscaled.state` da VM, que não é um volume.
- **Formato do backup preservado:** um diretório por serviço, com o nome do serviço. Os
  backups antigos (`headscale/`, `vaultwarden/`, `actual/`, `traefik/`) restauram com o
  código novo.
- **O backup copia o volume inteiro**, menos as exclusões, e troca cada arquivo SQLite
  (detectado pelo cabeçalho, não pela extensão) por um snapshot da API de backup online,
  com `integrity_check`. Antes, a lista de arquivos de cada app era escrita à mão.
- **`make new-app`** (`scripts/new-app.py`) gera o serviço com os labels, a rota no Traefik e
  o nome no Blocky, e resolve o digest da imagem no registro.
- **CI:** `apps.py check` confere que cada `mgdn.url` tem router e nome. O gerador roda numa
  cópia do repositório e o resultado passa pelas mesmas validações.

## Consequências

- Um app novo com dados entra no backup, no restore de VM nova, no healthcheck e no drill
  sem mexer em nenhum script. O guia cai de oito passos para "gere, ajuste, abra o PR".
- O backup do Vaultwarden passa a incluir o que antes ficava de fora por omissão (por
  exemplo, arquivos novos de versões futuras), menos o `icon_cache` e o `tmp`, que são
  descartáveis. O do Headscale passa a incluir o volume inteiro, não só o banco, a chave
  Noise e o cache.
- Os scripts dependem do `docker compose config` e do `python3`, que já estavam nas VMs e
  nos runners. Se o `apps.py` falhar, o backup falha alto (o Headscale é obrigatório) e o
  healthcheck reporta `apps=erro`.
- O gerador edita YAML por texto, ancorado em trechos conhecidos dos três arquivos. Se o
  formato deles mudar, ele falha com uma mensagem, e o teste no CI acusa.
