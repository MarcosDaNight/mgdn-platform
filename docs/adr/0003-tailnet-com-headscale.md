# 0003. Tailnet com Headscale, com o Blocky como DNS dela

- **Status:** aceita
- **Data:** 2026-10-24

## Contexto

Limitações do v1 que só uma rede privada resolve:

1. **Sem bloqueio fora de casa:** no 4G o celular usa o DNS da operadora.
2. **DNS em texto puro:** as consultas atravessam a internet em UDP 53, sem criptografia.
3. **SSH exposto:** filtrado pelo allowlist, mas ainda alcançável pela internet.

Restrições: o roteador de casa (Mercusys AC12G) **não roda Tailscale**, e a casa está atrás
de **CGNAT**. Ainda não há domínio próprio (será comprado depois).

## Decisão

- **Headscale** (servidor de controle do Tailscale, auto-hospedado) na VM principal.
  Celular e notebook entram na tailnet, e o **Blocky é o DNS da tailnet**: o bloqueio passa
  a funcionar em qualquer rede, com o tráfego cifrado pelo WireGuard.
- **O SSH só passa pela tailnet.** A porta 22 sai do Security Group. Para emergências há
  break-glass, uma variável do Terraform que reabre o SSH filtrado pelo allowlist.
- **A rede de casa continua no modelo do v1** (porta 53 pública filtrada pelo allowlist via
  DDNS), porque a TV e os visitantes não entram na tailnet. A tailnet **complementa** esse
  modelo, não o substitui.
- **O Headscale fica fora de qualquer coisa que ele mesmo protege**: roda direto na VM e não
  depende da tailnet para subir nem para ser administrado.
- **HTTPS via Let's Encrypt** (ACME nativo do Headscale). Enquanto não há domínio, o
  hostname é `mgdn-platform.duckdns.org`. A troca pelo domínio próprio será um ADR novo.
- **NAT traversal pelos DERPs públicos da Tailscale.** Eles só retransmitem tráfego que já
  sai cifrado pelo WireGuard, e assim não é preciso hospedar um DERP próprio nem abrir a
  porta 3478/udp.

Alternativa descartada: o **plano gratuito do Tailscale**. Ele não exige domínio nem
manutenção, mas deixa o servidor de controle com terceiros e mostra menos domínio técnico no
portfólio.

## Consequências

- O Security Group abre **80/tcp** (desafio ACME) e **443/tcp** (Headscale) para todos.
  Os dois são autenticados: o 443 só aceita aparelhos com chave aprovada.
- Se o Headscale cair, as conexões já estabelecidas continuam funcionando (cada aparelho
  guarda os pares WireGuard), mas aparelhos novos não entram até ele voltar.
- Trocar o DuckDNS pelo domínio próprio exige que os aparelhos entrem de novo na tailnet.
