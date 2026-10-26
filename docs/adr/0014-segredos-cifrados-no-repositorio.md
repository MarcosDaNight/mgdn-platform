# 0014. Segredos cifrados no repositório com age

- **Status:** aceita
- **Data:** 2026-10-25
- Substitui o transporte de segredos pelo cloud-init descrito nos ADRs 0006, 0009, 0010 e 0013.

## Contexto

Até aqui, todo segredo chegava às VMs pelo cloud-init: o valor ia para o
`terraform.tfvars` e virava uma linha de `/etc/mgdn-platform/env`. Esse caminho tinha um
custo alto, porque **mudar o cloud-init recria a VM**. Na principal, isso ainda exige o
`make headscale-drain` antes. Na prática:

- renovar as API keys do backup ou o token da Cloudflare (prazos do checklist mensal)
  significava recriar a principal;
- ligar o dead man's switch (ADR 0013) significava recriar a principal;
- adicionar um app com segredo significava recriar a principal;
- recriar a secundária exigia gerar uma chave de uso único da tailnet a menos de 30 min do
  apply, e ela voltava com outro IP na tailnet.

O resto da plataforma já muda por PR, com validação e rollback (ADR 0011). Só os segredos
continuavam fora desse caminho.

## Alternativas consideradas

| Opção | Por que não |
|---|---|
| **Manter no cloud-init** | É o problema descrito acima. |
| **Gerenciador de segredos do provedor** | A VM precisaria de uma credencial para buscá-los, e essa credencial teria de chegar pelo cloud-init. Mais um serviço e mais uma dependência em tempo de boot, para o mesmo resultado. |
| **Vault/OpenBao** | Um servidor a mais para manter, fazer backup e destravar. Desproporcional para uma pessoa e duas VMs. |
| **SOPS** | Cifra valor a valor e mostra no diff qual chave mudou. Mas é mais um binário em cada VM e mais um formato. O `age` já está na principal por causa do backup (ADR 0006) e faz o necessário sozinho. |
| **`age`, arquivo inteiro** | **Escolhida.** |

## Decisão

- **Um arquivo por papel**, `secrets/<papel>.env.age`, no formato `CHAVE='valor'`, cifrado
  com `age` em ASCII (armored).
- **Destinatários por papel**, em `secrets/<papel>.recipients` (só chaves públicas):
  - a chave do **host** daquele papel;
  - a chave de **administração**, que fica no computador do dono
    (`~/.config/mgdn-platform/age/admin.key`), com cópia no Vaultwarden.

  A secundária não decifra os segredos da principal (credenciais do backup, token da
  Cloudflare).
- **A chave privada de cada host chega pelo cloud-init** (`host_age_keys`), só na criação
  da VM. É o único segredo que continua nesse caminho. O Makefile lê as chaves de
  `~/.config/mgdn-platform/age/` e recusa planejar sem elas, porque um plano sem as chaves
  recriaria as VMs sem acesso aos segredos.
- **O `gitops-sync` decifra a cada deploy:**
  - na validação, um arquivo que não decifra ou está fora do formato barra o commit;
  - no apply, o resultado vai para `/etc/mgdn-platform/secrets.env` (0600), lido por todos os
    scripts depois do env e com precedência sobre ele;
  - se o token da Cloudflare mudou, o Traefik é reiniciado.

  Hosts sem chave seguem só com o env, então o merge vem antes da migração.
- **A identidade da secundária na tailnet** (`tailscaled.state`) também fica nos segredos
  dela. Recriada, ela volta como o mesmo nó, com o mesmo IP, sem chave de uso único.
- **Edição:** `make secrets-edit ROLE=<papel>` decifra num diretório em memória (tmpfs),
  abre o editor, confere o formato e recifra. `make secrets-set` grava um valor sem ecoá-lo.
- **`make apply` seguro:** o plano é salvo e mostrado. Se a principal for recriada, o drain
  roda sozinho antes de aplicar o mesmo plano. Se o apply falhar, o drain é desfeito.

## Consequências

- **Trocar um segredo é um PR.** O CI confere que os arquivos estão cifrados, com o número
  certo de destinatários. A VM aplica em até ~2 min, sem recriação e sem drain.
- **O repositório é público e os segredos estão nele, cifrados.** O modelo de ameaça:
  - o X25519 + ChaCha20-Poly1305 do `age` protege o conteúdo; o histórico do Git guarda
    todas as versões, então **um segredo exposto por vazamento de chave é exposto em todas as
    versões** e precisa ser rotacionado, não só recifrado;
  - aparecem em claro só os nomes dos arquivos, o tamanho aproximado e as datas das mudanças;
  - a chave de um host está no disco dele, onde os segredos já estavam em claro. Comprometer
    a VM continua expondo só o que ela já tinha.
- **Se a chave de administração vazar:** gere uma nova, troque-a nos dois `.recipients`,
  recifre e **rotacione todos os segredos**, já que o histórico continua decifrável com a
  chave antiga.
- **Se a chave de administração for perdida:** os hosts ainda decifram os próprios arquivos.
  Copie cada segredo da VM (`/etc/mgdn-platform/secrets.env`) e recifre para uma chave nova.
  A cópia no Vaultwarden evita isso.
- **A migração recria as duas VMs uma vez**, porque o cloud-init passa a levar só a chave
  age. Ordem: merge → `make secrets-bootstrap` (instala as chaves nas VMs atuais) →
  `make secrets-capture-identity` → `make apply`.
- O `age` passa a ser instalado nas duas VMs, e o computador do dono também precisa dele.

## Incidente na migração (2026-10-25)

O primeiro `make apply` da migração deixou a plataforma fora por cerca de 3 h (19:30–23:25).
As VMs recriadas subiram, mas nenhum serviço respondeu. Duas falhas da mesma classe, que o
env antigo do cloud-init escondia por definir todas as variáveis, mesmo vazias:

1. `secrets.sh` expandia `$HOME` com `set -u`, e o cloud-init e o systemd não definem `HOME`.
   A decifragem falhava, e o primeiro deploy saía na validação antes de instalar os timers do
   GitOps, então a VM nunca puxava a correção ([#45](https://github.com/MarcosDaNight/mgdn-platform/pull/45)).
2. `allowlist.sh` expandia `EXTRA_ALLOWED_CIDRS` com `set -u`, e os segredos omitem valores
   vazios. O allowlist falhava e o deploy abortava antes dos containers
   ([#46](https://github.com/MarcosDaNight/mgdn-platform/pull/46)).

O diagnóstico veio do log de console da VM (`mgc virtual-machine instances init-logs`), já que
sem tailnet não havia SSH. Ficaram:

- o CI roda o `secrets.sh` num ambiente vazio (`env -i`);
- se o primeiro deploy de uma VM nova falha, o timer do GitOps é instalado mesmo assim, e o
  próximo commit corrige a VM sem recriá-la ([#47](https://github.com/MarcosDaNight/mgdn-platform/pull/47));
- lição: antes de recriar, rodar os scripts da VM com `env -i` e sem as variáveis opcionais.

## Atualização: chaves SSH dos hosts (2026-10-26)

Cada recriação gerava chaves SSH novas, e o `make ssh` parava no aviso "REMOTE HOST
IDENTIFICATION HAS CHANGED", que se aprende a ignorar. Agora a chave ed25519 de cada host fica
nos segredos (`SSH_HOST_ED25519_KEY_B64`), e o `gitops-sync` a instala e oferece só ela. A
pública fica em `deploy/ssh/known_hosts`, que o Makefile usa com verificação estrita. Trocar a
chave é `make ssh-hostkey ROLE=<papel>` e um PR.
