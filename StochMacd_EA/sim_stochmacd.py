"""Port 1:1 logika StochMacd_EA.mq5 untuk backtest cepat di CSV OHLC.

    python3 sim_stochmacd.py xauusd_m15.csv                # parameter default EA
    python3 sim_stochmacd.py xauusd_m15.csv --grid         # sapuan parameter

Indikator direplikasi persis seperti MetaTrader 5:
  * ATR   = SMA dari True Range (MT5 memakai SMA, bukan Wilder)
  * MACD  = EMA(fast) - EMA(slow), garis signal = SMA (khas MT5, bukan EMA)
  * Stoch = sum(close-min)/sum(max-min)*100 selama `slowing` bar, signal = SMA
Eksekusi: sinyal dinilai di bar tertutup i, order masuk di OPEN bar i+1;
bila SL dan TP tersentuh di bar yang sama, dianggap SL lebih dulu (pesimis).
Biaya spread dibebankan sekali per trade, sama seperti kompensasi di EA.
"""
import csv, itertools, sys

# ----------------------------------------------------------------- indikator
def ema(src, period, start=0):
    """ExponentialMAOnBuffer MT5: seed = nilai pertama, lalu EMA biasa."""
    out = [None] * len(src)
    if not src:
        return out
    a = 2.0 / (period + 1.0)
    out[start] = src[start]
    for i in range(start + 1, len(src)):
        out[i] = src[i] * a + out[i - 1] * (1.0 - a)
    return out


def sma(src, period):
    out = [None] * len(src)
    s = 0.0
    cnt = 0
    for i, v in enumerate(src):
        if v is None:
            continue
        s += v
        cnt += 1
        if cnt > period:
            s -= src[i - period]
            cnt = period
        if cnt == period:
            out[i] = s / period
    return out


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


def macd_mt5(C, fast, slow, signal):
    f = ema(C, fast)
    s = ema(C, slow)
    main = [None if (f[i] is None or s[i] is None) else f[i] - s[i] for i in range(len(C))]
    sig = sma(main, signal)
    return main, sig


def stoch_mt5(H, L, C, kper, dper, slowing):
    n = len(C)
    lowest = [None] * n
    highest = [None] * n
    for i in range(kper - 1, n):
        lowest[i] = min(L[i - kper + 1:i + 1])
        highest[i] = max(H[i - kper + 1:i + 1])
    main = [None] * n
    for i in range(kper - 1 + slowing - 1, n):
        sl_ = sh = 0.0
        for k in range(i - slowing + 1, i + 1):
            sl_ += C[k] - lowest[k]
            sh += highest[k] - lowest[k]
        main[i] = 100.0 if sh == 0.0 else sl_ / sh * 100.0
    return main, sma(main, dper)


# ------------------------------------------------------------------ default
DEF = dict(
    MacdFast=12, MacdSlow=26, MacdSignal=9, MacdMode="hist", MacdZero="off", MinHistAtr=0.0,
    StochK=21, StochD=3, StochSlowing=3, StochMode="cross_zone", StochOS=25.0, StochOB=75.0,
    ConfluenceBars=3, Trigger="any", UseEma=False, EmaPeriod=200,
    CooldownBars=4, AtrPeriod=14,
    SlMode="atr", SlSwingBars=10, SlBufferAtr=0.3, SlAtr=1.5, SlMinAtr=1.0, SlMaxAtr=4.0,
    TpMode="rr", RR=1.5, TpSwingBars=40, MinRR=1.2, MaxRR=5.0, TpBufferAtr=0.1,
    BreakEvenRR=0.0, BeOffsetAtr=0.05, TrailAtr=0.0, TrailStartRR=1.0,
    ExitOnStochExt=False, MaxBarsInTrade=16,
    Spread=0.19,                      # $ per unit harga (Exness Pro XAUUSD ~190 pts)
    MaxSpreadRiskPct=8.0,
)


def load(path):
    T = []; O = []; H = []; L = []; C = []
    with open(path) as f:
        for r in csv.DictReader(f):
            T.append(r["time"]); O.append(float(r["open"])); H.append(float(r["high"]))
            L.append(float(r["low"])); C.append(float(r["close"]))
    return T, O, H, L, C


# --------------------------------------------------------------------- inti
def run(path, P=None, verbose=False, data=None):
    p = dict(DEF)
    if P:
        p.update(P)
    T, O, H, L, C = data if data else load(path)
    n = len(C)
    main, sig = macd_mt5(C, p["MacdFast"], p["MacdSlow"], p["MacdSignal"])
    k, d = stoch_mt5(H, L, C, p["StochK"], p["StochD"], p["StochSlowing"])
    atr = atr_mt5(H, L, C, p["AtrPeriod"])
    emaT = ema(C, p["EmaPeriod"]) if p["UseEma"] else [None] * n

    CB = p["ConfluenceBars"]

    def macd_event(i, dr):
        """indeks bar (0=i, .. CB-1) saat cross MACD, -1 bila tak ada."""
        for b in range(CB):
            j = i - b
            if j < 1 or main[j] is None or sig[j] is None or main[j - 1] is None or sig[j - 1] is None:
                break
            up = main[j] > sig[j] and main[j - 1] <= sig[j - 1]
            dn = main[j] < sig[j] and main[j - 1] >= sig[j - 1]
            if (dr > 0 and up) or (dr < 0 and dn):
                return b
        return -1

    def stoch_event(i, dr):
        for b in range(CB):
            j = i - b
            if j < 1 or k[j] is None or d[j] is None or k[j - 1] is None or d[j - 1] is None:
                break
            m = p["StochMode"]
            if m == "cross_any":
                ev = (k[j] > d[j] and k[j - 1] <= d[j - 1]) if dr > 0 else (k[j] < d[j] and k[j - 1] >= d[j - 1])
            elif m == "cross_zone":
                if dr > 0:
                    ev = k[j] > d[j] and k[j - 1] <= d[j - 1] and min(k[j - 1], d[j - 1]) < p["StochOS"]
                else:
                    ev = k[j] < d[j] and k[j - 1] >= d[j - 1] and max(k[j - 1], d[j - 1]) > p["StochOB"]
            else:  # exit_zone
                if dr > 0:
                    ev = k[j] > p["StochOS"] and k[j - 1] <= p["StochOS"]
                else:
                    ev = k[j] < p["StochOB"] and k[j - 1] >= p["StochOB"]
            if ev:
                return b
        return -1

    def signal(i, dr):
        if None in (main[i], sig[i], k[i], d[i]):
            return False
        if dr > 0 and not (main[i] > sig[i] and k[i] > d[i]):
            return False
        if dr < 0 and not (main[i] < sig[i] and k[i] < d[i]):
            return False

        mb = -1
        if p["MacdMode"] == "cross":
            mb = macd_event(i, dr)
            if mb < 0:
                return False
        elif p["MacdMode"] == "hist":
            if main[i - 1] is None or sig[i - 1] is None:
                return False
            h1 = main[i] - sig[i]; h2 = main[i - 1] - sig[i - 1]
            if dr > 0 and not h1 > h2:
                return False
            if dr < 0 and not h1 < h2:
                return False
            mb = macd_event(i, dr)

        if p["MacdZero"] == "pullback":
            if (dr > 0 and main[i] >= 0) or (dr < 0 and main[i] <= 0):
                return False
        elif p["MacdZero"] == "trend":
            if (dr > 0 and main[i] <= 0) or (dr < 0 and main[i] >= 0):
                return False

        if p["MinHistAtr"] > 0 and atr[i] and abs(main[i] - sig[i]) < p["MinHistAtr"] * atr[i]:
            return False

        sb = stoch_event(i, dr)
        if sb < 0:
            return False

        tg = p["Trigger"]
        if tg == "stoch":
            return sb == 0
        if tg == "macd":
            return mb == 0
        last = sb if mb < 0 else min(sb, mb)
        return last == 0

    # --------------------------------------------------------------- eksekusi
    trades = []
    rej = dict(sl=0, rr=0, spread=0, cooldown=0)
    last_entry = -10 ** 9
    i = max(p["MacdSlow"] + p["MacdSignal"], p["StochK"] + p["StochSlowing"] + p["StochD"],
            p["AtrPeriod"], p["EmaPeriod"] if p["UseEma"] else 0, p["SlSwingBars"], p["TpSwingBars"]) + 5

    while i < n - 2:
        if atr[i] is None or atr[i] <= 0:
            i += 1
            continue
        dr = 1 if signal(i, 1) else (-1 if signal(i, -1) else 0)
        if dr == 0:
            i += 1
            continue
        if p["UseEma"] and emaT[i] is not None:
            if (dr > 0 and C[i] < emaT[i]) or (dr < 0 and C[i] > emaT[i]):
                i += 1
                continue
        if i - last_entry < p["CooldownBars"]:
            rej["cooldown"] += 1
            i += 1
            continue

        a = atr[i]
        e = O[i + 1]                      # entry di open bar berikutnya
        if dr > 0:
            e += p["Spread"]              # BUY diisi di Ask

        if p["SlMode"] == "swing":
            ext = min(L[i - p["SlSwingBars"] + 1:i + 1]) if dr > 0 else max(H[i - p["SlSwingBars"] + 1:i + 1])
            sl = ext - p["SlBufferAtr"] * a if dr > 0 else ext + p["SlBufferAtr"] * a
        else:
            sl = e - p["SlAtr"] * a if dr > 0 else e + p["SlAtr"] * a
        dist = abs(e - sl)
        if dist < p["SlMinAtr"] * a:
            dist = p["SlMinAtr"] * a
            sl = e - dist if dr > 0 else e + dist
        if p["SlMaxAtr"] > 0 and dist > p["SlMaxAtr"] * a:
            rej["sl"] += 1
            i += 1
            continue

        if p["TpMode"] == "rr":
            tp = e + p["RR"] * dist if dr > 0 else e - p["RR"] * dist
        else:
            win = range(max(0, i - p["TpSwingBars"] + 1), i + 1)
            cand = [H[j] for j in win if H[j] > e] if dr > 0 else [L[j] for j in win if L[j] < e]
            if not cand:
                tp = e + p["RR"] * dist if dr > 0 else e - p["RR"] * dist
            else:
                tgt = max(cand) if dr > 0 else min(cand)
                tp = tgt - p["TpBufferAtr"] * a if dr > 0 else tgt + p["TpBufferAtr"] * a
                rr = abs(tp - e) / dist
                if rr < p["MinRR"]:
                    rej["rr"] += 1
                    i += 1
                    continue
                if rr > p["MaxRR"]:
                    tp = e + p["MaxRR"] * dist if dr > 0 else e - p["MaxRR"] * dist

        if dr < 0:                        # kompensasi spread SELL (tutup di Ask)
            sl += p["Spread"]
            tp += p["Spread"]
            dist = abs(e - sl)

        if p["MaxSpreadRiskPct"] > 0 and p["Spread"] / dist * 100.0 > p["MaxSpreadRiskPct"]:
            rej["spread"] += 1
            i += 1
            continue

        # ------------------------------------------------------ jalankan trade
        last_entry = i
        cur_sl = sl
        be_done = False
        res = None
        j = i + 1
        while j < n:
            hi, lo = H[j], L[j]
            hit_sl = (lo <= cur_sl) if dr > 0 else (hi >= cur_sl)
            hit_tp = (hi >= tp) if dr > 0 else (lo <= tp)
            if hit_sl:                    # pesimis: SL diperiksa lebih dulu
                res = (cur_sl - e) * dr / dist
                break
            if hit_tp:
                res = (tp - e) * dr / dist
                break
            if p["MaxBarsInTrade"] > 0 and j - i - 1 >= p["MaxBarsInTrade"]:
                res = (C[j] - e) * dr / dist
                break
            if p["ExitOnStochExt"] and k[j] is not None:
                if (dr > 0 and k[j] > p["StochOB"]) or (dr < 0 and k[j] < p["StochOS"]):
                    res = (C[j] - e) * dr / dist
                    break
            # trailing / break-even dievaluasi pada close bar
            rr_now = (C[j] - e) * dr / dist
            if p["BreakEvenRR"] > 0 and not be_done and rr_now >= p["BreakEvenRR"]:
                be = e + dr * p["BeOffsetAtr"] * a
                if (dr > 0 and be > cur_sl) or (dr < 0 and be < cur_sl):
                    cur_sl = be
                    be_done = True
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
            print(f"{T[i]} {'BUY ' if dr>0 else 'SELL'} e={e:.2f} sl={sl:.2f} tp={tp:.2f} "
                  f"dist={dist:.2f} R={res:+.2f} bars={j-i}")
        i = j                              # satu posisi pada satu waktu
    return trades, rej, p


def report(name, trades, rej, p, lot=0.01):
    if not trades:
        print(f"{name}: 0 trade")
        return None
    R = [t[6] for t in trades]
    wins = [r for r in R if r > 0]
    totR = sum(R)
    usd = sum(t[6] * t[5] for t in trades) * lot * 100.0     # 1.00 lot gold = $100 per 1 unit harga
    eq = 0.0; peak = 0.0; dd = 0.0
    for t in trades:
        eq += t[6] * t[5] * lot * 100.0
        peak = max(peak, eq)
        dd = max(dd, peak - eq)
    avg_sl = sum(t[5] for t in trades) / len(trades)
    pf_num = sum(w for w in wins)
    pf_den = -sum(r for r in R if r <= 0)
    pf = (pf_num / pf_den) if pf_den > 0 else float("inf")
    print(f"{name}: {len(trades)} trade | WR {len(wins)/len(R)*100:4.1f}% | "
          f"{totR:+7.1f}R | ${usd:+8.2f} (lot {lot}) | PF {pf:4.2f} | maxDD ${dd:6.2f} | "
          f"SL rata2 ${avg_sl:.2f} | tolak {rej}")
    return dict(n=len(trades), wr=len(wins) / len(R), R=totR, usd=usd, pf=pf, dd=dd)


def grid(path):
    base = {}
    print("--- basis")
    t, r, p = run(path, base); report("default        ", t, r, p)
    print("\n--- Stochastic: zona & mode")
    for os_, ob in ((20, 80), (25, 75), (30, 70), (35, 65)):
        t, r, p = run(path, dict(StochOS=os_, StochOB=ob))
        report(f"OS/OB {os_}/{ob}    ", t, r, p)
    for m in ("cross_zone", "exit_zone", "cross_any"):
        t, r, p = run(path, dict(StochMode=m)); report(f"stoch {m:10s}", t, r, p)
    print("\n--- MACD")
    for m in ("cross", "state", "hist"):
        t, r, p = run(path, dict(MacdMode=m)); report(f"macd {m:11s}", t, r, p)
    for z in ("off", "pullback", "trend"):
        t, r, p = run(path, dict(MacdZero=z)); report(f"zero {z:11s}", t, r, p)
    print("\n--- konfluensi & pemicu")
    for cb in (1, 2, 3, 5, 8):
        t, r, p = run(path, dict(ConfluenceBars=cb)); report(f"window {cb} bar   ", t, r, p)
    for tg in ("any", "stoch", "macd"):
        t, r, p = run(path, dict(Trigger=tg)); report(f"trigger {tg:8s}", t, r, p)
    print("\n--- SL / TP")
    for rr in (1.0, 1.5, 2.0, 2.5, 3.0):
        t, r, p = run(path, dict(RR=rr)); report(f"RR {rr:3.1f}         ", t, r, p)
    for sm, extra in (("swing", {}), ("atr", dict(SlAtr=1.5)), ("atr", dict(SlAtr=2.0))):
        e = dict(SlMode=sm); e.update(extra)
        t, r, p = run(path, e); report(f"SL {sm} {extra.get('SlAtr','')}      ", t, r, p)
    for mn in (0.5, 1.0, 1.5, 2.0):
        t, r, p = run(path, dict(SlMinAtr=mn)); report(f"SLmin {mn} ATR   ", t, r, p)
    t, r, p = run(path, dict(TpMode="swing")); report("TP swing       ", t, r, p)
    print("\n--- manajemen")
    for be in (0.0, 1.0, 1.5):
        t, r, p = run(path, dict(BreakEvenRR=be)); report(f"BE {be}R        ", t, r, p)
    for tr in (0.0, 1.0, 2.0):
        t, r, p = run(path, dict(TrailAtr=tr)); report(f"trail {tr} ATR   ", t, r, p)
    t, r, p = run(path, dict(ExitOnStochExt=True)); report("exit stoch ext ", t, r, p)
    t, r, p = run(path, dict(UseEma=True)); report("EMA200 filter  ", t, r, p)
    t, r, p = run(path, dict(Spread=0.0)); report("spread 0 (ideal)", t, r, p)


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "xauusd_m15.csv"
    if "--grid" in sys.argv:
        grid(path)
    else:
        t, r, p = run(path, verbose="-v" in sys.argv)
        report("default", t, r, p)
