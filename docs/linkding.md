# Linkding

Favoritos da principal em `linkding.mgdn.com.br`, só pela tailnet e com HTTPS, gerado pelo
[`make new-app`](adicionar-app.md). Guarda tudo em SQLite, no volume, e entra no backup horário
e no DR drill pelos labels (ADR 0015).

> **Logo depois do deploy, crie a conta.** O Linkding não tem cadastro aberto.

## Criar a conta

```bash
make ssh HOST=mgdn-primary
sudo docker exec -it mgdn-linkding-1 python manage.py createsuperuser --username=<usuário> --email=<e-mail>
```

## Extensão do navegador

1. Instale a extensão oficial do Linkding (Chrome ou Firefox, nas lojas de extensões).
2. Em **Configurações → Integrações** do Linkding, gere um token de API.
3. Na extensão, informe a URL `https://linkding.mgdn.com.br` e o token.

O navegador precisa estar na tailnet, ou o nome não resolve.

## Celular

- Abra `https://linkding.mgdn.com.br` no Safari (com o Tailscale ligado) e use
  *Compartilhar → Adicionar à Tela de Início*, que abre o Linkding como um app.
- Para salvar a partir do menu Compartilhar, use um Atalho do iOS que envie um `POST` para
  `https://linkding.mgdn.com.br/api/bookmarks/` com o cabeçalho `Authorization: Token <token>`.
  Também há apps de terceiros que usam o mesmo token.

## Memória

O limite (`mem_limit`) é estimado. Uma semana depois do merge, o workflow `deadlines` abre uma
issue para medir o pico real e ajustar o limite, mantendo-o em pelo menos 1,5x o pico.
