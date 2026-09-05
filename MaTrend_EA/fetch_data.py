"""Unduh OHLC dari Yahoo Finance ke CSV untuk sim_ma.py.

    python3 fetch_data.py GC=F 1h 730d gold_h1.csv
    python3 fetch_data.py EURUSD=X 15m 60d eurusd_m15.csv

Batas Yahoo: interval 15m maksimal ~60 hari, 1h maksimal ~730 hari, 1d panjang.
Data ini proksi (futures / spot FX tanpa bid-ask broker) -- untuk menyaring ide,
bukan untuk menilai hasil akhir. Penilaian akhir tetap di Strategy Tester MT5.
"""
import csv, datetime, json, sys, urllib.parse, urllib.request

def fetch(symbol, interval, rng):
    url = ("https://query1.finance.yahoo.com/v8/finance/chart/"
           f"{urllib.parse.quote(symbol)}?interval={interval}&range={rng}")
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=90) as r:
        data = json.load(r)
    res = data["chart"]["result"][0]
    q = res["indicators"]["quote"][0]
    rows = []
    for i, t in enumerate(res["timestamp"]):
        o, h, l, c = q["open"][i], q["high"][i], q["low"][i], q["close"][i]
        if None in (o, h, l, c) or h < l:
            continue
        rows.append((t, o, h, l, c))
    return rows

def main():
    sym, interval, rng, out = sys.argv[1:5]
    rows = fetch(sym, interval, rng)
    if not rows:
        sys.exit("tidak ada data")
    dec = 3 if rows[-1][4] >= 20 else 5          # emas/indeks 3 desimal, FX 5 desimal
    fmt = lambda t: datetime.datetime.fromtimestamp(t, datetime.timezone.utc)
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["time", "open", "high", "low", "close"])
        for t, o, h, l, c in rows:
            w.writerow([fmt(t).strftime("%Y-%m-%d %H:%M"), *(f"{v:.{dec}f}" for v in (o, h, l, c))])
    print(f"{len(rows):6d} bar -> {out:22s} {fmt(rows[0][0]):%Y-%m-%d} .. {fmt(rows[-1][0]):%Y-%m-%d}")

if __name__ == "__main__":
    main()
