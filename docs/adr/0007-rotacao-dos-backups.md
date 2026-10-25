# 0007. Rotação dos backups sem lifecycle do provedor

- **Status:** aceita
- **Data:** 2026-10-24

## Contexto

O ADR 0006 grava um backup por dia num bucket com object lock de 30 dias. O lock impede
apagar antes do prazo, mas **nada apaga depois dele**: os backups se acumulariam para
sempre. O custo é irrelevante (~12 KB por dia), mas guardar indefinidamente cópias com
chaves e aparelhos antigos é risco sem benefício.

O caminho usual seria uma regra de **lifecycle** no bucket, aplicada pelo provedor sem
credenciais extras. Quando este ADR foi escrito (out/2026), regras de lifecycle não estavam
disponíveis para os buckets do projeto, então a rotação precisava ficar do lado do cliente.

## Decisão

- **Rotação do lado do cliente**, logo depois de cada backup (`scripts/prune.sh`), com a
  chave que a VM já tem.
- **Política** (`scripts/retention.py`, com autoteste no CI):
  - todos os backups dos últimos **30 dias**;
  - o **primeiro backup de cada mês** por **12 meses**;
  - **nunca menos de 7** backups, mesmo que todos estejam velhos (ex.: backup parado).

  No regime estável são ~43 backups (~500 KB).
- **Exclusão por versão** (`DELETE ?versionId=`): no bucket versionado, um `DELETE` comum
  só cria um delete marker e mantém o dado.
- **O object lock continua sendo a garantia.** Mesmo que o script tenha um bug ou que a VM
  seja comprometida, nada com menos de 30 dias pode ser apagado. Testado: apagar uma versão
  travada pelo próprio `s3_delete_version` retorna 403.
- **Verificação mensal:** o restore drill reporta quantos backups existem e falha se houver
  algum com mais de 400 dias, ou seja, se a rotação parou.

## Consequências

- A chave da VM precisa de permissão de exclusão. O efeito é limitado pelo lock: só
  backups com mais de 30 dias podem ser apagados, e só eles já sairiam pela política.
- Quando houver lifecycle disponível para o bucket, este ADR pode ser substituído por uma
  regra no bucket, e a VM perde a necessidade de apagar.
