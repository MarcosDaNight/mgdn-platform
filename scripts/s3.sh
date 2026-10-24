#!/usr/bin/env bash
# Funções S3 mínimas sobre curl (--aws-sigv4), sem depender do awscli.
# Variáveis: BACKUP_ENDPOINT, BACKUP_REGION, BACKUP_BUCKET, BACKUP_ACCESS_KEY,
# BACKUP_SECRET_KEY. Usado por backup.sh e restore.sh (na VM e no CI).

s3_curl() {
  curl -fsS --retry 3 --aws-sigv4 "aws:amz:${BACKUP_REGION}:s3" \
    --user "${BACKUP_ACCESS_KEY}:${BACKUP_SECRET_KEY}" "$@"
}

# s3_put <arquivo> <chave>. O bucket tem object lock, que exige Content-MD5.
s3_put() {
  local md5
  md5=$(openssl dgst -md5 -binary "$1" | base64)
  s3_curl -o /dev/null -H "Content-MD5: ${md5}" -T "$1" "${BACKUP_ENDPOINT}/${BACKUP_BUCKET}/$2"
}

# s3_get <chave> <arquivo>
s3_get() {
  s3_curl -o "$2" "${BACKUP_ENDPOINT}/${BACKUP_BUCKET}/$1"
}

# s3_list <prefixo>: uma chave por linha, em ordem, seguindo a paginação.
s3_list() {
  local token="" page
  while :; do
    page=$(s3_curl -G "${BACKUP_ENDPOINT}/${BACKUP_BUCKET}" \
      --data-urlencode "list-type=2" --data-urlencode "prefix=$1" \
      ${token:+--data-urlencode "continuation-token=${token}"})
    python3 -c 'import re,sys; [print(k) for k in re.findall(r"<Key>([^<]+)</Key>", sys.stdin.read())]' <<<"$page"
    token=$(python3 -c 'import re,sys; m=re.search(r"<NextContinuationToken>([^<]+)</NextContinuationToken>", sys.stdin.read()); print(m.group(1) if m else "")' <<<"$page")
    [[ -n "$token" ]] || break
  done
}
