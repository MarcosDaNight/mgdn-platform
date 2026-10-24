#!/usr/bin/env bash
# Cria (uma única vez) o bucket de backup do Headscale em br-se1: versionado e com
# object lock COMPLIANCE de 30 dias, ou seja, nenhuma versão pode ser apagada ou
# sobrescrita antes do prazo, nem com as credenciais do dono (ADR 0006).
# Idempotente. Requer AWS_ACCESS_KEY_ID/SECRET do .env.
set -euo pipefail

bucket=mgdn-platform-backup-b29a4ccd
endpoint=https://br-se1.magaluobjects.com
retention_days=30
s3() { AWS_REGION=br-se1 aws --endpoint-url "$endpoint" s3api "$@"; }

if s3 head-bucket --bucket "$bucket" 2>/dev/null; then
  echo "bucket $bucket já existe"
else
  # O object lock só pode ser habilitado na criação do bucket.
  s3 create-bucket --bucket "$bucket" --object-lock-enabled-for-bucket >/dev/null
  echo "bucket $bucket criado com object lock"
fi
s3 put-object-lock-configuration --bucket "$bucket" --object-lock-configuration \
  "{\"ObjectLockEnabled\":\"Enabled\",\"Rule\":{\"DefaultRetention\":{\"Mode\":\"COMPLIANCE\",\"Days\":$retention_days}}}"
echo "retenção padrão: COMPLIANCE, $retention_days dias"
