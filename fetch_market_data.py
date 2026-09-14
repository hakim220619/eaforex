"""Unduh dan satukan seluruh data market (USDJPY, EURUSD, XAUUSD) M1 sampai H1
ke dalam satu folder bersama: market_data/
"""
import csv
import datetime
import json
import os
import sys
import urllib.parse
import urllib.request

SYMBOLS = {
    "eurusd": "EURUSD=X",
    "usdjpy": "USDJPY=X",
    "xauusd": "GC=F",
}

TIMEFRAMES = {
    "m1":  ("1m",  "7d"),
    "m5":  ("5m",  "59d"),
    "m15": ("15m", "59d"),
    "m30": ("30m", "59d"),
    "h1":  ("1h",  "60d"),
}

DECIMALS = {
    "eurusd": 5,
    "usdjpy": 3,
    "xauusd": 3,
}

OUTPUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "market_data")

def fetch(symbol, interval, rng):
    url = (
        "https://query1.finance.yahoo.com/v8/finance/chart/"
        f"{urllib.parse.quote(symbol)}?interval={interval}&range={rng}"
    )
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=90) as r:
        data = json.load(r)
    res = data["chart"]["result"][0]
    q = res["indicators"]["quote"][0]
    rows = []
    for i, t in enumerate(res["timestamp"]):
        o = q["open"][i]
        h = q["high"][i]
        l = q["low"][i]
        c = q["close"][i]
        if None in (o, h, l, c) or h < l:
            continue
        rows.append((t, o, h, l, c))
    return rows

def save_csv(rows, out_path, dec):
    fmt = lambda t: datetime.datetime.fromtimestamp(t, datetime.timezone.utc)
    with open(out_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["time", "open", "high", "low", "close"])
        for t, o, h, l, c in rows:
            w.writerow([
                fmt(t).strftime("%Y-%m-%d %H:%M"),
                *(f"{v:.{dec}f}" for v in (o, h, l, c))
            ])

def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    print(f"Mengunduh data market ke folder: {OUTPUT_DIR}\n")

    total_files = 0
    summary = []
    for sym_name, sym_code in SYMBOLS.items():
        dec = DECIMALS[sym_name]
        for tf, (iv, rg) in TIMEFRAMES.items():
            filename = f"{sym_name}_{tf}.csv"
            out_path = os.path.join(OUTPUT_DIR, filename)
            try:
                print(f"Fetching {sym_name.upper()} {tf.upper()} ({sym_code}, interval={iv}, range={rg})...")
                rows = fetch(sym_code, iv, rg)
                if not rows:
                    print(f"  [GAGAL] Tidak ada data untuk {filename}")
                    continue
                save_csv(rows, out_path, dec)
                fmt = lambda t: datetime.datetime.fromtimestamp(t, datetime.timezone.utc)
                start_dt = fmt(rows[0][0]).strftime("%Y-%m-%d %H:%M")
                end_dt = fmt(rows[-1][0]).strftime("%Y-%m-%d %H:%M")
                size_kb = os.path.getsize(out_path) / 1024.0
                print(f"  [OK] {filename:18s} | {len(rows):5d} bars | {start_dt} s/d {end_dt} | {size_kb:.1f} KB")
                summary.append((filename, len(rows), start_dt, end_dt))
                total_files += 1
            except Exception as e:
                print(f"  [ERROR] {filename}: {e}")

    print(f"\nSelesai! Berhasil mengunduh {total_files} file data market ke folder 'market_data/'.")

if __name__ == "__main__":
    main()
