"""Simulator strategi MA trend-following, port 1:1 dari MaTrend_EA.mq5.

    python3 sim_ma.py eurusd_h1.csv                 # parameter default EA
    python3 sim_ma.py eurusd_h1.csv -v              # daftar trade

Indikator direplikasi seperti MetaTrader 5:
  * SMA/EMA sesuai MovingAverages.mqh (EMA seed = harga pertama)
  * ATR   = SMA dari True Range (MT5 memakai SMA, bukan Wilder)
Eksekusi: sinyal dinilai di bar tertutup i, order masuk di OPEN bar i+1.
Bila SL dan TP kena di bar yang sama, SL dianggap lebih dulu (pesimis).
Spread dibebankan sekali per trade.
"""
import csv, sys

# ----------------------------------------------------------------- indikator
def ema(src, period):
    out = [None] * len(src)
    if not src:
        return out
    a = 2.0 / (period + 1.0)
    out[0] = src[0]
    for i in range(1, len(src)):
        out[i] = src[i] * a + out[i - 1] * (1.0 - a)
    return out


def sma(src, period):
    out = [None] * len(src)
    s = 0.0
    for i, v in enumerate(src):
        s += v
        if i >= period:
            s -= src[i - period]
        if i >= period - 1:
            out[i] = s / period
    return out


def ma(src, period, kind):
    return ema(src, period) if kind == "ema" else sma(src, period)


def atr_mt5(H, L, C, period):
    n = len(C)
    tr = [0.0] * n
    for i in range(1, n):
        tr[i] = max(H[i], C[i - 1]) - min(L[i], C[i - 1])
    out = [None] * n
    s = 0.0
    for i in range(1, n):
        s += tr[i]
        if i > period:
            s -= tr[i - period]
        if i >= period:
            out[i] = s / period
    return out


# ------------------------------------------------------------------ default
DEF = dict(
    MaType="ema", MaFast=34, MaSlow=100,
    UseFilter=False, MaFilter=200,          # MA panjang sebagai penyaring rezim
    Entry="cross",                         # "cross" | "pullback" | "breakout"
    PullbackBars=8,                        # umur sinyal pullback (bar)
    BreakoutBars=20,
    SlopeBars=0,                           # MA lambat harus naik/turun selama N bar (0=off)
    AtrPeriod=14, SlAtr=2.0, TpMode="rr", RR=5.0,
    TrailAtr=0.0, TrailStartRR=1.0, BreakEvenRR=0.0, BeOffsetAtr=0.05,
    MaxBarsInTrade=0, CooldownBars=0,
    MinAtrPct=0.0,                         # ATR minimal sebagai % harga (saring pasar mati)
    Spread=0.00012,
)


def load(path):
    T = []; O = []; H = []; L = []; C = []
    with open(path) as f:
        for r in csv.DictReader(f):
            T.append(r["time"]); O.append(float(r["open"])); H.append(float(r["high"]))
            L.append(float(r["low"])); C.append(float(r["close"]))
    return T, O, H, L, C


# --------------------------------------------------------------------- inti
def run(path, P=None, data=None, verbose=False):
    p = dict(DEF)
    if P:
        p.update(P)
    T, O, H, L, C = data if data else load(path)
    n = len(C)
    fast = ma(C, p["MaFast"], p["MaType"])
    slow = ma(C, p["MaSlow"], p["MaType"])
    filt = ma(C, p["MaFilter"], p["MaType"]) if p["UseFilter"] else [None] * n
    atr = atr_mt5(H, L, C, p["AtrPeriod"])

    warm = max(p["MaSlow"], p["MaFilter"] if p["UseFilter"] else 0,
               p["AtrPeriod"], p["BreakoutBars"]) + 5

    def trend(i):
        """+1 uptrend, -1 downtrend, 0 tidak jelas."""
        if fast[i] is None or slow[i] is None:
            return 0
        d = 1 if fast[i] > slow[i] else -1
        if p["UseFilter"]:
            if filt[i] is None:
                return 0
            if d > 0 and C[i] < filt[i]:
                return 0
            if d < 0 and C[i] > filt[i]:
                return 0
        if p["SlopeBars"] > 0:
            j = i - p["SlopeBars"]
            if j < 0 or slow[j] is None:
                return 0
            if d > 0 and not slow[i] > slow[j]:
                return 0
            if d < 0 and not slow[i] < slow[j]:
                return 0
        return d

    def signal(i):
        d = trend(i)
        if d == 0:
            return 0
        mode = p["Entry"]
        if mode == "cross":
            # bar i adalah bar pertama fast melewati slow
            if fast[i - 1] is None or slow[i - 1] is None:
                return 0
            up = fast[i] > slow[i] and fast[i - 1] <= slow[i - 1]
            dn = fast[i] < slow[i] and fast[i - 1] >= slow[i - 1]
            return d if ((d > 0 and up) or (d < 0 and dn)) else 0
        if mode == "breakout":
            w = range(i - p["BreakoutBars"], i)
            if d > 0 and C[i] > max(H[j] for j in w):
                return d
            if d < 0 and C[i] < min(L[j] for j in w):
                return d
            return 0
        # pullback: harga sempat menyentuh MA cepat dalam PullbackBars bar terakhir,
        # lalu bar i menutup kembali searah tren di sisi MA cepat.
        # Syarat "belum terpicu" (close bar sebelumnya masih di seberang MA, atau bar ini
        # sendiri yang menyentuh MA) membuatnya satu sinyal per pullback, bukan berulang.
        lo = max(0, i - p["PullbackBars"] + 1)
        if d > 0:
            if not (C[i] > fast[i] and C[i] > O[i]):
                return 0
            touched = any(fast[j] is not None and L[j] <= fast[j] for j in range(lo, i + 1))
            fresh = (fast[i - 1] is not None and C[i - 1] <= fast[i - 1]) or L[i] <= fast[i]
            return d if (touched and fresh) else 0
        else:
            if not (C[i] < fast[i] and C[i] < O[i]):
                return 0
            touched = any(fast[j] is not None and H[j] >= fast[j] for j in range(lo, i + 1))
            fresh = (fast[i - 1] is not None and C[i - 1] >= fast[i - 1]) or H[i] >= fast[i]
            return d if (touched and fresh) else 0

    trades = []
    last_entry = -10 ** 9
    i = warm
    while i < n - 2:
        a = atr[i]
        if a is None or a <= 0:
            i += 1
            continue
        if p["MinAtrPct"] > 0 and a / C[i] * 100.0 < p["MinAtrPct"]:
            i += 1
            continue
        dr = signal(i)
        if dr == 0 or i - last_entry < p["CooldownBars"]:
            i += 1
            continue

        e = O[i + 1] + (p["Spread"] if dr > 0 else 0.0)
        dist = p["SlAtr"] * a
        sl = e - dr * dist
        tp = e + dr * p["RR"] * dist
        if dr < 0:                              # kompensasi spread SELL
            sl += p["Spread"]; tp += p["Spread"]
            dist = abs(e - sl)

        last_entry = i
        cur_sl = sl
        be_done = False
        res = None
        j = i + 1
        while j < n:
            hit_sl = (L[j] <= cur_sl) if dr > 0 else (H[j] >= cur_sl)
            hit_tp = (H[j] >= tp) if dr > 0 else (L[j] <= tp)
            if hit_sl:
                res = (cur_sl - e) * dr / dist
                break
            if hit_tp:
                res = (tp - e) * dr / dist
                break
            if p["MaxBarsInTrade"] > 0 and j - i - 1 >= p["MaxBarsInTrade"]:
                res = (C[j] - e) * dr / dist
                break
            rr_now = (C[j] - e) * dr / dist
            if p["BreakEvenRR"] > 0 and not be_done and rr_now >= p["BreakEvenRR"]:
                be = e + dr * p["BeOffsetAtr"] * a
                if (dr > 0 and be > cur_sl) or (dr < 0 and be < cur_sl):
                    cur_sl = be; be_done = True
            if p["TrailAtr"] > 0 and rr_now >= p["TrailStartRR"]:
                tr = C[j] - dr * p["TrailAtr"] * a
                if (dr > 0 and tr > cur_sl) or (dr < 0 and tr < cur_sl):
                    cur_sl = tr
            j += 1
        if res is None:
            res = (C[n - 1] - e) * dr / dist
            j = n - 1
        trades.append((T[i], dr, e, sl, tp, dist, res, j - i))
        if verbose:
            print(f"{T[i]} {'BUY ' if dr>0 else 'SELL'} e={e:.5f} sl={sl:.5f} tp={tp:.5f} R={res:+.2f} bars={j-i}")
        i = j
    return trades, p


def stats(trades):
    if not trades:
        return None
    R = [t[6] for t in trades]
    wins = [r for r in R if r > 0]
    gp = sum(wins); gl = -sum(r for r in R if r <= 0)
    eq = 0.0; peak = 0.0; dd = 0.0
    for r in R:
        eq += r; peak = max(peak, eq); dd = max(dd, peak - eq)
    return dict(n=len(R), wr=len(wins) / len(R) * 100.0, R=sum(R),
                pf=(gp / gl if gl > 0 else float("inf")), ddR=dd,
                avg_dist=sum(t[5] for t in trades) / len(trades))


def report(name, trades, p, pip=None):
    s = stats(trades)
    if not s:
        print(f"{name}: 0 trade"); return
    extra = ""
    if pip:
        extra = f" | SL rata2 {s['avg_dist']/pip:5.1f} pip = ${s['avg_dist']/pip*0.1:5.2f} (0.01 lot)"
    print(f"{name}: {s['n']:4d} trade | WR {s['wr']:4.1f}% | {s['R']:+7.1f}R | "
          f"PF {s['pf']:4.2f} | maxDD {s['ddR']:5.1f}R{extra}")


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "eurusd_h1.csv"
    t, p = run(path, verbose="-v" in sys.argv)
    report("default", t, p, pip=0.0001 if "eur" in path or "gbp" in path or "aud" in path else None)
