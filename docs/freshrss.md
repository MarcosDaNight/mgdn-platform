# FreshRSS

Leitor de RSS da principal em `freshrss.mgdn.com.br`, só pela tailnet e com HTTPS, gerado pelo
[`make new-app`](adicionar-app.md). Guarda tudo em SQLite, no volume, e entra no backup horário
e no DR drill pelos labels (ADR 0015).

> **Logo depois do deploy, crie a conta.** Até lá, o FreshRSS deixa qualquer aparelho da
> tailnet fazer a instalação. Todos os aparelhos são do dono, mas não deixe para depois.

## Criar a conta

Abra `https://freshrss.mgdn.com.br`. O assistente de instalação pede o idioma, confere os
requisitos, pergunta o banco (**SQLite**) e cria o usuário administrador.

## Ligar a API para apps de RSS

A API funciona atrás do Traefik: a versão fixada aceita `%2F` no caminho (o padrão do Traefik
3.7 é `allowEncodedSlash: true`), que a API Google Reader usa.

1. Em **Configurações → Autenticação**, marque *Permitir acesso à API (necessário para apps
   móveis)*.
2. Em **Configurações → Perfil**, preencha a *Senha da API*. Ela é diferente da senha
   principal, de propósito.
3. No mesmo campo há um link `https://freshrss.mgdn.com.br/api/`. Abra-o e use *Check full
   server configuration*. O esperado é **PASS**.

## App no iPhone

Com o Tailscale ligado no iPhone, num app que fale FreshRSS ou Google Reader (por exemplo
Reeder, NetNewsWire, Fiery Feeds ou Lire):

| Campo | Valor |
|---|---|
| Tipo de conta | FreshRSS, ou Google Reader |
| URL | `https://freshrss.mgdn.com.br/api/greader.php` |
| Usuário | o usuário do FreshRSS |
| Senha | a **senha da API** (não a principal) |

Apps que só falam Fever usam `https://freshrss.mgdn.com.br/api/fever.php`; o Google Reader é
mais completo e eficiente. O app só sincroniza com a tailnet ligada.

## Memória

O limite (`mem_limit`) é estimado. Uma semana depois do merge, o workflow `deadlines` abre uma
issue para medir o pico real (`memory.peak` do cgroup e `docker stats`) e ajustar o limite,
mantendo-o em pelo menos 1,5x o pico.
