"""Unduh OHLC M15 dari Yahoo Finance ke CSV untuk dipakai sim_stochmacd.py.

    python3 fetch_m15.py GC=F xauusd_m15.csv

Catatan: Yahoo hanya menyimpan ~60 hari data intraday 15m. GC=F adalah futures
emas COMEX -- dekat dengan XAUUSD spot tetapi bukan feed Exness (tidak ada
spread bid/ask, jam dagang sedikit berbeda). Untuk penilaian akhir tetap pakai
Strategy Tester MT5 dengan data broker sendiri.
"""
import csv, datetime, json, sys, urllib.parse, urllib.request

def fetch(symbol, interval="15m", rng="60d"):
    url = ("https://query1.finance.yahoo.com/v8/finance/chart/"
           f"{urllib.parse.quote(symbol)}?interval={interval}&range={rng}")
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=60) as r:
        data = json.load(r)
    res = data["chart"]["result"][0]
    ts = res["timestamp"]
    q = res["indicators"]["quote"][0]
    rows = []
    for i, t in enumerate(ts):
        o, h, l, c = q["open"][i], q["high"][i], q["low"][i], q["close"][i]
        if None in (o, h, l, c):
            continue
        rows.append((t, o, h, l, c))
    return rows

def main():
    symbol = sys.argv[1] if len(sys.argv) > 1 else "GC=F"
    out = sys.argv[2] if len(sys.argv) > 2 else "xauusd_m15.csv"
    rows = fetch(symbol)
    if not rows:
        sys.exit("tidak ada data")
    dec = 3 if rows[-1][4] >= 20 else 5     # gold/index 3 desimal, FX 5 desimal
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["time", "open", "high", "low", "close"])
        for t, o, h, l, c in rows:
            w.writerow([datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%d %H:%M"),
                        *(f"{v:.{dec}f}" for v in (o, h, l, c))])
    fmt = lambda t: datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%d")
    print(f"{len(rows)} bar -> {out}  ({fmt(rows[0][0])} .. {fmt(rows[-1][0])})")

if __name__ == "__main__":
    main()
