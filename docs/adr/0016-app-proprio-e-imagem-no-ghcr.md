# 0016. App próprio (estudo) e imagem publicada no ghcr.io

- **Status:** aceita
- **Data:** 2026-11-08

## Contexto

O [ADR 0008](0008-cadeia-de-suprimentos.md) diz que a plataforma não gera imagens: só roda
as oficiais, fixadas por digest. Isso valia enquanto todo app era de terceiros.

Queremos um app de estudo para a CKA e para os fundamentos de Linux, com repetição espaçada,
streak, português e inglês, e interface que funcione no celular e no desktop. Nenhum app
pronto cobre isso:

- o **Anki** tem servidor de sync, mas não tem interface web de estudo;
- os apps de flashcards self-hosted não têm trilha, streak nem conteúdo de CKA.

Então o app é nosso: [`mgdn-study`](https://github.com/MarcosDaNight/mgdn-study).

## Alternativas consideradas

| Opção | Por que não |
|---|---|
| **Código dentro deste repositório** | Mistura produto com infraestrutura. Um bug de UI dispararia o CI de DNS, e o repo de infra passaria a ter `package.json`. |
| **Build na própria VM** (`build:` no Compose) | Gasta RAM e CPU numa VM de 2 GB, deixa o deploy lento e perde o digest fixo: a VM rodaria algo que nunca passou pelo CI. |
| **Imagem privada no ghcr.io** | Exigiria um token de pull nas VMs, que é um segredo a mais para guardar e rotacionar. O código não tem nada sensível, e o progresso de estudo fica no volume, não na imagem. |

## Decisão

- **O app vive em repositório próprio, público**, e o CI dele builda, escaneia e publica em
  `ghcr.io/marcosdanight/mgdn-study`. A plataforma só consome a imagem, por digest.
- **A cadeia do ADR 0008 continua valendo para a imagem:**
  - Actions fixadas por SHA;
  - Trivy bloqueia CRITICAL com correção, em todo PR, na `main` e toda semana;
  - o smoke test sobe o contêiner e confere o `/healthz` antes de publicar;
  - a publicação inclui proveniência (`provenance: mode=max`).
- **A tag é o SHA do commit** (e não `latest`), e o `compose.yaml` fixa o digest.
- **O app segue o contrato de app (ADR 0015):** SQLite no volume `estudo-data`, que entra no
  backup horário, no restore e no DR drill (que mostra quantos itens foram estudados).
- **Só pela tailnet**, em `estudo.mgdn.com.br`, como os outros apps.
- **`ORIGIN` é obrigatório no Compose.** Atrás do Traefik o Node só vê `http://`, e sem
  `ORIGIN` o SvelteKit rejeita os POSTs pela proteção de CSRF.

## Consequências

- Este é o primeiro app cuja imagem não é de terceiros. O ADR 0008 não vale mais para a
  frase "não geramos imagens"; a política de digest e varredura segue igual.
- **Atualizar o app é um PR aqui**, com o novo SHA e digest. O Dependabot não acompanha tags
  por SHA, então não há PR automático. Se isso incomodar, dá para automatizar no CI do app
  (abrir o PR na plataforma) ou passar a publicar tags semver.
- Imagem pública significa que qualquer pessoa pode puxá-la. Ela contém só o código e o
  currículo, ambos já públicos no repositório do app.
- O conteúdo do currículo muda por PR no repo do app, e cada mudança vira uma imagem nova.
- **Limite aceito:** o `mem_limit` de 96 MB é uma estimativa. Ajustar com `docker stats`
  depois de alguns dias de uso, como foi feito com o FreshRSS.
