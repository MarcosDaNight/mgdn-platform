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

# s3_list_versions <prefixo>: "chave<TAB>versionId<TAB>lastModified" de cada versão
# (delete markers ignorados), seguindo a paginação.
s3_list_versions() {
  local km="" vm="" page
  while :; do
    page=$(s3_curl -G "${BACKUP_ENDPOINT}/${BACKUP_BUCKET}" --data-urlencode "versions" \
      --data-urlencode "prefix=$1" \
      ${km:+--data-urlencode "key-marker=${km}"} ${vm:+--data-urlencode "version-id-marker=${vm}"})
    python3 -c '
import re, sys
x = sys.stdin.read()
for v in re.findall(r"<Version>(.*?)</Version>", x, re.S):
    g = lambda t: re.search(rf"<{t}>([^<]*)</{t}>", v).group(1)
    print(g("Key"), g("VersionId"), g("LastModified"), sep="\t")' <<<"$page"
    grep -q '<IsTruncated>true</IsTruncated>' <<<"$page" || break
    km=$(sed -n 's:.*<NextKeyMarker>\([^<]*\)</NextKeyMarker>.*:\1:p' <<<"$page")
    vm=$(sed -n 's:.*<NextVersionIdMarker>\([^<]*\)</NextVersionIdMarker>.*:\1:p' <<<"$page")
  done
}

# s3_delete_version <chave> <versionId>: apaga a versão de fato (não cria delete
# marker). O object lock recusa enquanto a retenção não venceu.
s3_delete_version() {
  s3_curl -o /dev/null -X DELETE -G "${BACKUP_ENDPOINT}/${BACKUP_BUCKET}/$1" --data-urlencode "versionId=$2"
}
