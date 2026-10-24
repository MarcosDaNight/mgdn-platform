#!/usr/bin/env python3
"""Política de retenção dos backups (ADR 0007).

Lê da entrada padrão linhas "chave<TAB>versionId<TAB>lastModified" e imprime as
versões a apagar ("chave<TAB>versionId"). Mantém:
  - tudo dos últimos --daily-days dias (o mesmo período do object lock);
  - o primeiro backup de cada mês por --monthly-days dias;
  - sempre os --min-keep backups mais recentes, aconteça o que acontecer.

Uso: retention.py [--daily-days 30] [--monthly-days 365] [--min-keep 7] [--now ISO]
     retention.py --self-test
"""
import argparse
import re
import sys
from datetime import datetime, timedelta, timezone

STAMP = re.compile(r"(\d{8}T\d{6}Z)")


def parse_ts(key, last_modified):
    m = STAMP.search(key)
    if m:
        return datetime.strptime(m.group(1), "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
    return datetime.fromisoformat(last_modified.replace("Z", "+00:00"))


def to_delete(items, now, daily_days=30, monthly_days=365, min_keep=7):
    """items: [(key, version_id, timestamp)] -> [(key, version_id)] a apagar."""
    items = sorted(items, key=lambda i: i[2], reverse=True)
    keep = {(k, v) for k, v, _ in items[:min_keep]}
    first_of_month = {}
    for k, v, ts in items:
        age = now - ts
        if age <= timedelta(days=daily_days):
            keep.add((k, v))
        elif age <= timedelta(days=monthly_days):
            month = (ts.year, ts.month)
            if month not in first_of_month or ts < first_of_month[month][2]:
                first_of_month[month] = (k, v, ts)
    keep |= {(k, v) for k, v, _ in first_of_month.values()}
    return [(k, v) for k, v, _ in items if (k, v) not in keep]


def self_test():
    now = datetime(2027, 6, 15, 12, tzinfo=timezone.utc)
    daily = [(f"headscale/{(now - timedelta(days=d)).strftime('%Y%m%dT%H%M%SZ')}.tar.gz.age", f"v{d}",
              now - timedelta(days=d)) for d in range(0, 500)]
    dele = set(to_delete(daily, now))
    kept = [i for i in daily if (i[0], i[1]) not in dele]
    ages = sorted((now - ts).days for _, _, ts in kept)
    assert all(a <= 365 for a in ages), "nada além de 1 ano"
    assert sum(1 for a in ages if a <= 30) == 31, "todos os diários dos últimos 30 dias"
    old = [ts for _, _, ts in kept if (now - ts).days > 30]
    assert len({(t.year, t.month) for t in old}) == len(old), "um por mês além de 30 dias"
    for t in old:
        # O mês mais antigo é cortado pela janela de 1 ano: o mensal é o primeiro
        # backup do mês que ainda está dentro da janela.
        month = [ts for _, _, ts in daily
                 if (ts.year, ts.month) == (t.year, t.month) and 30 < (now - ts).days <= 365]
        assert t == min(month), "o mensal é o primeiro backup do mês (dentro da janela)"
    assert 40 <= len(kept) <= 45, len(kept)
    # Piso de segurança: poucos backups antigos nunca são apagados.
    few = [(f"k{d}", "v", now - timedelta(days=400 + d)) for d in range(5)]
    assert to_delete(few, now) == [], "nunca abaixo de min_keep"
    # Nada recente (dentro do object lock) entra na lista.
    assert all((now - ts).days > 30 for k, v, ts in daily if (k, v) in dele)
    print(f"self-test ok: {len(daily)} backups -> mantém {len(kept)}, apaga {len(dele)}")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--daily-days", type=int, default=30)
    p.add_argument("--monthly-days", type=int, default=365)
    p.add_argument("--min-keep", type=int, default=7)
    p.add_argument("--now")
    p.add_argument("--self-test", action="store_true")
    a = p.parse_args()
    if a.self_test:
        return self_test()
    now = datetime.fromisoformat(a.now) if a.now else datetime.now(timezone.utc)
    items = []
    for line in sys.stdin:
        if line.strip():
            key, vid, lm = line.rstrip("\n").split("\t")
            items.append((key, vid, parse_ts(key, lm)))
    for k, v in to_delete(items, now, a.daily_days, a.monthly_days, a.min_keep):
        print(f"{k}\t{v}")


if __name__ == "__main__":
    main()
