# 0010. Domínio próprio, Traefik como borda HTTPS e Vaultwarden só na tailnet

- **Status:** aceita (substitui a parte do DuckDNS do ADR 0003)
- **Data:** 2026-10-24

## Contexto

A fase 5 traz apps pessoais, começando pelo Vaultwarden, que **exige HTTPS** (o navegador só
libera a criptografia do cofre em contexto seguro). O Headscale não emite certificados para
os nomes da tailnet, e o DuckDNS era provisório (ADR 0003). O domínio `mgdn.com.br` foi
registrado no registro.br em 24/10/2026, com o DNS delegado à Cloudflare (plano gratuito),
porque o DNS do registro.br não tem API e a emissão automática de certificados precisa de
uma.

## Decisão

- **Zona na Cloudflare gerenciada pelo Terraform** (`infra/dns.tf`), sem proxy (só DNS).
  Os registros que impedem o uso do domínio para spoofing de e-mail (Null MX, SPF `-all`,
  DMARC `reject`) foram importados como estavam.
- **Traefik como borda HTTPS única** na porta 443 da principal. Certificados Let's Encrypt
  por **DNS-01** na Cloudflare, o que funciona inclusive para nomes que só existem na
  tailnet. Imagem oficial, sem build próprio. Rotas em arquivo, **sem acesso ao socket do
  Docker**.
- **Headscale atrás do Traefik**, em `headscale.mgdn.com.br`, com TLS desligado no Headscale e
  timeouts de leitura zerados no Traefik por causa dos long-polls. O nome do DuckDNS segue
  aceito numa rota de compatibilidade, com certificado TLS-ALPN-01: **nenhum aparelho cai** e a
  migração deles é um passo separado. A porta 80 sai do security group.
- **Vaultwarden em `vault.mgdn.com.br`, só pela tailnet**, em duas camadas: o nome existe
  apenas no Blocky (*split-horizon*, não aparece no DNS público) e o Traefik só aceita
  origem `100.64.0.0/10`. Cadastro aberto apenas até a conta do dono existir. Painel admin
  desativado (sem `ADMIN_TOKEN`).
- **Backup de hora em hora**, no mesmo pacote cifrado e bucket imutável do Headscale: banco
  (snapshot SQLite), chaves RSA, anexos e sends. Restore automático numa VM nova, e o drill
  mensal sobe um Vaultwarden com o backup e confere que ele responde.

## Consequências

- **RPO do cofre ≤ 1 h**, e os apps do Bitwarden mantêm uma cópia local cifrada, o que reduz a
  perda real. O object lock de 30 dias segura ~720 backups horários (~15 MB) antes de a
  rotação (ADR 0007) poder afinar para mensais.
- O token da Cloudflare (DNS:Edit só nesta zona) fica na VM para o DNS-01. Se vazar, permite
  alterar registros desta zona. Mitigações: o Headscale é autenticado pela chave Noise, não
  pelo TLS; o `vault` é resolvido pelo Blocky, não pelo DNS público. O token expira em
  25/10/2027 e está no checklist.
- Custo: o domínio (~R$ 40/ano). A Cloudflare free e os certificados são gratuitos.
