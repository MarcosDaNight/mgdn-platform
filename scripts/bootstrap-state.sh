#!/usr/bin/env bash
# Cria (uma única vez) o bucket privado e versionado do state do Terraform no
# Object Storage da Magalu. Idempotente. Requer AWS_ACCESS_KEY_ID/SECRET do .env.
set -euo pipefail

# Bucket, região e endpoint vêm do backend em infra/versions.tf (fonte única).
versions="$(dirname "$0")/../infra/versions.tf"
field() { sed -nE "s/^ *$1 *= *\"([^\"]+)\".*/\\1/p" "$versions" | head -1; }
bucket=$(field bucket)
region=$(field region)
endpoint=$(field s3)
s3() { AWS_REGION="$region" aws --endpoint-url "$endpoint" s3api "$@"; }

if s3 head-bucket --bucket "$bucket" 2>/dev/null; then
  echo "bucket $bucket já existe"
else
  s3 create-bucket --bucket "$bucket" >/dev/null
  echo "bucket $bucket criado"
fi
s3 put-bucket-versioning --bucket "$bucket" --versioning-configuration Status=Enabled
echo "versionamento habilitado"
