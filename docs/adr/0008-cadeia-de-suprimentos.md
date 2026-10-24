# 0008. Cadeia de suprimentos: digests fixos e varredura das imagens

- **Status:** aceita
- **Data:** 2026-10-24

## Contexto

Tudo o que roda nas VMs vem de imagens públicas (Headscale, Blocky, Prometheus, Grafana,
node-exporter), e o CI usa Actions de terceiros. Dois riscos:

1. **Tag mutável:** `blocky:v0.35.0` pode ser republicada com outro conteúdo. A VM puxaria
   algo que nunca passou pelo CI. Isso já aconteceu com Actions populares, que tiveram tags
   reescritas para apontar para código malicioso.
2. **Vulnerabilidades conhecidas:** sem varredura, ninguém percebe uma CVE crítica numa
   imagem em uso.

Assinar as imagens (cosign) não se aplica: não geramos imagens, só usamos as oficiais.

Estado medido com o Trivy (out/2026): **0 CRITICAL** em todas as imagens; 29 HIGH, todas em
bibliotecas embutidas e todas com correção já publicada a montante (grafana 7,
node-exporter 15, blocky 7). Só os mantenedores conseguem corrigir.

## Decisão

- **Imagens fixadas por digest** (`nome:tag@sha256:…`, índice multi-arquitetura). A VM só
  roda exatamente o que passou no CI. O Dependabot atualiza tag e digest juntos.
- **Actions fixadas por commit SHA** (`@<sha> # vX.Y.Z`), também atualizadas pelo
  Dependabot.
- **Trivy** (`supply-chain.yml`) em todo PR, na `main` e toda semana:
  - **bloqueia** CRITICAL **com correção disponível**. Há o que fazer: atualizar a imagem;
  - **reporta** HIGH e CRITICAL na aba *Security* (SARIF), sem bloquear;
  - o job agregador `supply-chain` é check obrigatório da `main`.

## Consequências

- Uma imagem nova com CRITICAL corrigível não chega às VMs.
- HIGH não bloqueia, para o CI não ficar vermelho por algo que só o upstream resolve. Elas
  ficam visíveis em *Security* e somem quando o Dependabot traz a versão corrigida.
- A varredura semanal pode ficar vermelha sem nenhum commit, quando sai uma CVE crítica
  nova. O GitHub notifica a falha do workflow, e é esse o objetivo.
