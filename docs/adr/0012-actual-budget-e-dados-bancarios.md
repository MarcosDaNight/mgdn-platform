# 0012. Actual Budget e dados bancários sem Open Finance pago

- **Status:** aceita
- **Data:** 2026-10-25

## Contexto

Queremos controle de finanças pessoais na plataforma: um app acessível pela tailnet,
alimentado com as transações dos bancos com o mínimo de trabalho manual e **sem custo
recorrente**. O [Actual Budget](https://github.com/actualbudget/actual) atende ao app: é open
source, usa SQLite, consome pouca RAM e importa OFX, QFX, QIF, CAMT e CSV.

O ponto difícil é a origem dos dados:

- **Open Finance Brasil direto não é possível.** Só instituições autorizadas pelo Banco
  Central participam ([Resolução Conjunta nº 1/2020](https://normativos.bcb.gov.br/Lists/Normativos/Attachments/51028/Res_Conj_0001_v9_L.pdf)).
  A pessoa física apenas consente o compartilhamento dos dados com elas.
- **Agregadores comerciais** (Pluggy, Belvo e outros) cobram na casa dos milhares de reais
  por mês. Isso está fora do orçamento.
- **A Pluggy tem um caminho gratuito**, pelo Meu Pluggy, e o Actual a integra nativamente
  desde a versão 25.4.0 ([docs](https://actualbudget.org/docs/advanced/bank-sync/pluggyai)).
  Mas há limitações:
  - a conexão com o banco só pode ser feita durante o trial;
  - depois do trial, a conexão segue ativa, mas a lista de bancos não pode mais mudar;
  - a integração é experimental;
  - a Pluggy passa a ver todas as transações.
- **APIs não oficiais e raspagem** de apps de banco exigem a senha do banco, violam os termos
  de uso e quebram sem aviso.

## Decisão

- **Actual Budget na VM principal**, em `actual.mgdn.com.br`, no mesmo padrão do Vaultwarden
  (ADR 0010):
  - só pela tailnet, com o middleware `tailnet-only` e o nome existindo só no Blocky;
  - login por senha;
  - backup horário cifrado, restore automático numa VM nova e verificação no DR drill mensal.
- **Dados bancários em camadas, todas sem custo:**
  1. **Arquivos exportados pelos bancos** (OFX de preferência, CSV quando não houver),
     importados no Actual. Não envolve terceiros. A importação de OFX deduplica pelo
     `FITID`, o identificador de cada transação, então reimportar um período não duplica
     nada. Falta confirmar quais dos bancos em uso exportam OFX.
  2. **Pluggy pelo Meu Pluggy**, opcional e só enquanto for gratuita. Só com conectores
     **Open Finance**: o consentimento é feito no app do banco, só para leitura, com prazo e
     revogável. Conectores que pedem a senha do banco ficam de fora.
  3. **Importador próprio: talvez.** Só vale construir se o fluxo manual da camada 1
     incomodar depois de um mês de uso, já que a deduplicação já está resolvida. Se vier,
     ele recebe os arquivos pela tailnet, identifica a conta e chama `importTransactions`
     da [API do Actual](https://actualbudget.org/docs/api/). Viveria **num repositório
     separado**, com CI, testes e imagem própria; aqui entraria só o serviço no Compose,
     com a imagem fixada por digest.
- **Identidade visual (depois da 26.11.0):** a interface segue a identidade da plataforma
  pelos [temas customizados](https://actualbudget.org/docs/custom-themes) do Actual, que usam
  variáveis CSS. As cores são `#13284B` e `#1C9E8C` no tema claro e `#E6EDF3` e `#2BC4AC` no
  escuro. Um fork do app fica descartado, porque exigiria manter builds próprios a
  cada release.

## Consequências

- **Dados financeiros passam a viver na VM.** Mitigações:
  - o app só abre pela tailnet;
  - o backup é cifrado com `age` e imutável;
  - recomenda-se ligar a **criptografia de ponta a ponta** do Actual, cuja chave fica só nos
    aparelhos. Assim, nem a VM nem o backup guardam os orçamentos em claro.

  Os segredos da Pluggy, se usada, ficam no servidor e fora dessa criptografia. Um importador
  próprio precisaria da chave de ponta a ponta, e isso seria decidido no repositório dele.
- **Com a criptografia de ponta a ponta ligada, o restore drill prova menos.** Ele prova que
  os arquivos voltam e que o servidor sobe com eles, mas não que o orçamento abre, porque o
  drill não tem a senha de criptografia. Essa senha fica no Vaultwarden; sem ela, o backup
  dos orçamentos é ilegível, inclusive para o dono.
- **A senha do servidor é definida no primeiro acesso.** Até lá, qualquer aparelho da
  tailnet poderia defini-la; hoje todos os aparelhos são do dono. Defina a senha logo depois
  do deploy.
- **Entra com uma exceção temporária no Trivy.** A 26.10.0 traz o `proxy-addr` 2.0.7
  (CVE-2026-90711, falsificação de IP pelo `X-Forwarded-For`), corrigido na 2.0.8, que sai na
  26.11.0. A exceção fica em `.trivyignore`, com motivo e expiração em 2026-11-15; depois
  dessa data, o CI volta a barrar e força a atualização. O risco é baixo: o app só abre pela
  tailnet, através do Traefik, que não confia no `X-Forwarded-For` enviado pelo cliente.
- `mem_limit` de 256 MB. O healthcheck da principal passa a conferir o Actual pelo Traefik,
  como já faz com o Vaultwarden.
- A camada 1 não é automática: depende de exportar os arquivos no app de cada banco. É o
  preço de não pagar agregador nem entregar a senha do banco a terceiros.
