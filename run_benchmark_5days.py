"""Benchmark Komprehensif Seluruh Strategi EA (5 Hari Trading Terakhir).
Menguji 8 Strategi EA pada dataset market_data/ (EURUSD, USDJPY, XAUUSD dari M1 sampai H1).

Strategi yang diuji:
  1. MaTrend_EA
  2. EmaPullback_EA
  3. StochMacd_EA
  4. SMC_Structure_EA
  5. SmcLiquiditySweep_EA
  6. RapidScalper_EA
  7. StraddleBreakout_EA
  8. GoldTrailStop_EA
"""

import csv
import math
import os
import sys

DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "market_data")

# Window 5 hari trading terakhir: mulai dari 2026-09-08 00:00 UTC sampai akhir data
BENCHMARK_START_TIME = "2026-09-08 00:00"

# Biaya spread default (realistis broker ECN / Pro)
SPREADS = {
    "eurusd": 0.00012,  # 1.2 pips
    "usdjpy": 0.015,    # 1.5 pips
    "xauusd": 0.20,     # $0.20 (20 cents / 20 pts)
}

POINT_SIZE = {
    "eurusd": 0.00001,
    "usdjpy": 0.001,
    "xauusd": 0.01,
}

LOT_SIZE = 0.01
INITIAL_BALANCE = 100.0

def load_csv(filepath):
    T, O, H, L, C = [], [], [], [], []
    with open(filepath, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for r in reader:
            T.append(r["time"])
            O.append(float(r["open"]))
            H.append(float(r["high"]))
            L.append(float(r["low"]))
            C.append(float(r["close"]))
    return T, O, H, L, C

# ----------------- Indikator Standar MT5 -----------------
def ema(src, period):
    n = len(src)
    out = [None] * n
    if n == 0:
        return out
    a = 2.0 / (period + 1.0)
    out[0] = src[0]
    for i in range(1, n):
        out[i] = src[i] * a + out[i - 1] * (1.0 - a)
    return out

def sma(src, period):
    n = len(src)
    out = [None] * n
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

def atr_mt5(H, L, C, period=14):
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

def macd_mt5(C, fast=12, slow=26, signal=9):
    f = ema(C, fast)
    s = ema(C, slow)
    main = [None if (f[i] is None or s[i] is None) else f[i] - s[i] for i in range(len(C))]
    sig = sma(main, signal)
    return main, sig

def stoch_mt5(H, L, C, kper=21, dper=3, slowing=3):
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

def calc_pnl_usd(symbol, direction, entry, exit_p):
    """Menghitung PnL bersih USD untuk 0.01 lot setelah dikurangi spread."""
    spread = SPREADS[symbol]
    diff = (exit_p - entry) * direction
    if symbol == "xauusd":
        # 1 oz (0.01 lot). 1 dollar harga = $1 USD.
        gross = diff * 1.0
        cost = spread * 1.0
    elif symbol == "eurusd":
        # 1,000 EUR.
        gross = diff * 1000.0
        cost = spread * 1000.0
    elif symbol == "usdjpy":
        # 1,000 USD base. Profit dalam JPY = diff * 1000, lalu / exit_p -> USD.
        gross = (diff * 1000.0) / exit_p
        cost = (spread * 1000.0) / exit_p
    else:
        gross = diff
        cost = 0.0
    return gross - cost

# ----------------- Simulasi Strategi -----------------

# 1. MaTrend_EA
def sim_matrend(T, O, H, L, C, symbol, tf, fast_p=34, slow_p=100, rr=5.0, sl_atr=2.0):
    n = len(C)
    fast = ema(C, fast_p)
    slow = ema(C, slow_p)
    atr = atr_mt5(H, L, C, 14)
    trades = []
    in_trade = False
    direction = 0
    entry_p = 0.0
    sl = 0.0
    tp = 0.0
    t_entry = ""
    cooldown = 0

    for i in range(1, n - 1):
        if cooldown > 0:
            cooldown -= 1
        
        # Kelola trade aktif
        if in_trade:
            hit_sl = (L[i] <= sl) if direction == 1 else (H[i] >= sl)
            hit_tp = (H[i] >= tp) if direction == 1 else (L[i] <= tp)
            if hit_sl and hit_tp:
                # Pesimis: anggap SL kena lebih dulu
                exit_p = sl
                trades.append({
                    "entry_time": t_entry, "exit_time": T[i],
                    "dir": direction, "entry": entry_p, "exit": exit_p,
                    "pnl": calc_pnl_usd(symbol, direction, entry_p, exit_p),
                    "reason": "SL"
                })
                in_trade = False
                cooldown = 2
            elif hit_sl:
                exit_p = sl
                trades.append({
                    "entry_time": t_entry, "exit_time": T[i],
                    "dir": direction, "entry": entry_p, "exit": exit_p,
                    "pnl": calc_pnl_usd(symbol, direction, entry_p, exit_p),
                    "reason": "SL"
                })
                in_trade = False
                cooldown = 2
            elif hit_tp:
                exit_p = tp
                trades.append({
                    "entry_time": t_entry, "exit_time": T[i],
                    "dir": direction, "entry": entry_p, "exit": exit_p,
                    "pnl": calc_pnl_usd(symbol, direction, entry_p, exit_p),
                    "reason": "TP"
                })
                in_trade = False
                cooldown = 2

        # Cek sinyal baru di bar tertutup i-1
        if not in_trade and cooldown == 0 and fast[i] is not None and slow[i] is not None and atr[i] is not None:
            # Cross sinyal
            cross_up = fast[i - 1] <= slow[i - 1] and fast[i] > slow[i]
            cross_down = fast[i - 1] >= slow[i - 1] and fast[i] < slow[i]
            sig = 1 if cross_up else (-1 if cross_down else 0)
            if sig != 0 and T[i + 1] >= BENCHMARK_START_TIME:
                in_trade = True
                direction = sig
                entry_p = O[i + 1]
                t_entry = T[i + 1]
                d_sl = sl_atr * atr[i]
                if direction == 1:
                    sl = entry_p - d_sl
                    tp = entry_p + d_sl * rr
                else:
                    sl = entry_p + d_sl
                    tp = entry_p - d_sl * rr

    if in_trade:
        exit_p = C[-1]
        trades.append({
            "entry_time": t_entry, "exit_time": T[-1],
            "dir": direction, "entry": entry_p, "exit": exit_p,
            "pnl": calc_pnl_usd(symbol, direction, entry_p, exit_p),
            "reason": "CLOSE_END"
        })

    return [t for t in trades if t["entry_time"] >= BENCHMARK_START_TIME]


# 2. EmaPullback_EA
def sim_emapullback(T, O, H, L, C, symbol, tf, fast_p=50, slow_p=200, pull_p=21, rr=2.0, sl_atr=1.5):
    n = len(C)
    fast = ema(C, fast_p)
    slow = ema(C, slow_p)
    pull = ema(C, pull_p)
    atr = atr_mt5(H, L, C, 14)
    trades = []
    in_trade = False
    direction = 0
    entry_p = 0.0
    sl = 0.0
    tp = 0.0
    t_entry = ""

    for i in range(max(slow_p, 20) + 1, n - 1):
        if in_trade:
            hit_sl = (L[i] <= sl) if direction == 1 else (H[i] >= sl)
            hit_tp = (H[i] >= tp) if direction == 1 else (L[i] <= tp)
            if hit_sl and hit_tp:
                exit_p = sl
                trades.append({
                    "entry_time": t_entry, "exit_time": T[i],
                    "dir": direction, "entry": entry_p, "exit": exit_p,
                    "pnl": calc_pnl_usd(symbol, direction, entry_p, exit_p),
                    "reason": "SL"
                })
                in_trade = False
            elif hit_sl:
                exit_p = sl
                trades.append({
                    "entry_time": t_entry, "exit_time": T[i],
                    "dir": direction, "entry": entry_p, "exit": exit_p,
                    "pnl": calc_pnl_usd(symbol, direction, entry_p, exit_p),
                    "reason": "SL"
                })
                in_trade = False
            elif hit_tp:
                exit_p = tp
                trades.append({
                    "entry_time": t_entry, "exit_time": T[i],
                    "dir": direction, "entry": entry_p, "exit": exit_p,
                    "pnl": calc_pnl_usd(symbol, direction, entry_p, exit_p),
                    "reason": "TP"
                })
                in_trade = False

        if not in_trade and fast[i] and slow[i] and pull[i] and atr[i]:
            c1, o1, l1, h1 = C[i], O[i], L[i], H[i]
            up = (fast[i] > slow[i]) and (c1 > slow[i])
            dn = (fast[i] < slow[i]) and (c1 < slow[i])
            buy = up and (l1 <= pull[i]) and (c1 > pull[i]) and (c1 > o1)
            sell = dn and (h1 >= pull[i]) and (c1 < pull[i]) and (c1 < o1)

            sig = 1 if buy else (-1 if sell else 0)
            if sig != 0 and T[i + 1] >= BENCHMARK_START_TIME:
                in_trade = True
                direction = sig
                entry_p = O[i + 1]
                t_entry = T[i + 1]
                dist = sl_atr * atr[i]
                if direction == 1:
                    sl = entry_p - dist
                    tp = entry_p + dist * rr
                else:
                    sl = entry_p + dist
                    tp = entry_p - dist * rr

    if in_trade:
        exit_p = C[-1]
        trades.append({
            "entry_time": t_entry, "exit_time": T[-1],
            "dir": direction, "entry": entry_p, "exit": exit_p,
            "pnl": calc_pnl_usd(symbol, direction, entry_p, exit_p),
            "reason": "CLOSE_END"
        })

    return [t for t in trades if t["entry_time"] >= BENCHMARK_START_TIME]


# 3. StochMacd_EA
def sim_stochmacd(T, O, H, L, C, symbol, tf, rr=1.5, sl_atr=1.5):
    n = len(C)
    macd_main, macd_sig = macd_mt5(C, 12, 26, 9)
    stoch_k, stoch_d = stoch_mt5(H, L, C, 21, 3, 3)
    atr = atr_mt5(H, L, C, 14)
    trades = []
    in_trade = False
    direction = 0
    entry_p = 0.0
    sl = 0.0
    tp = 0.0
    t_entry = ""
    bars_in_trade = 0
    cooldown = 0

    for i in range(35, n - 1):
        if cooldown > 0:
            cooldown -= 1
        if in_trade:
            bars_in_trade += 1
            hit_sl = (L[i] <= sl) if direction == 1 else (H[i] >= sl)
            hit_tp = (H[i] >= tp) if direction == 1 else (L[i] <= tp)
            if hit_sl and hit_tp:
                trades.append({
                    "entry_time": t_entry, "exit_time": T[i],
                    "dir": direction, "entry": entry_p, "exit": sl,
                    "pnl": calc_pnl_usd(symbol, direction, entry_p, sl),
                    "reason": "SL"
                })
                in_trade = False
                cooldown = 4
            elif hit_sl:
                trades.append({
                    "entry_time": t_entry, "exit_time": T[i],
                    "dir": direction, "entry": entry_p, "exit": sl,
                    "pnl": calc_pnl_usd(symbol, direction, entry_p, sl),
                    "reason": "SL"
                })
                in_trade = False
                cooldown = 4
            elif hit_tp:
                trades.append({
                    "entry_time": t_entry, "exit_time": T[i],
                    "dir": direction, "entry": entry_p, "exit": tp,
                    "pnl": calc_pnl_usd(symbol, direction, entry_p, tp),
                    "reason": "TP"
                })
                in_trade = False
                cooldown = 4
            elif bars_in_trade >= 16:
                exit_p = C[i]
                trades.append({
                    "entry_time": t_entry, "exit_time": T[i],
                    "dir": direction, "entry": entry_p, "exit": exit_p,
                    "pnl": calc_pnl_usd(symbol, direction, entry_p, exit_p),
                    "reason": "MAX_BARS"
                })
                in_trade = False
                cooldown = 4

        if not in_trade and cooldown == 0 and macd_main[i] and macd_sig[i] and stoch_k[i] and stoch_d[i] and atr[i]:
            # Confluence cross
            # MACD histogram: main > sig
            hist = macd_main[i] - macd_sig[i]
            hist_prev = macd_main[i - 1] - macd_sig[i - 1]
            macd_buy = hist_prev <= 0 and hist > 0
            macd_sell = hist_prev >= 0 and hist < 0

            # Stoch cross in OS/OB zone (<25 / >75)
            stoch_buy = stoch_k[i - 1] <= stoch_d[i - 1] and stoch_k[i] > stoch_d[i] and stoch_k[i] <= 30
            stoch_sell = stoch_k[i - 1] >= stoch_d[i - 1] and stoch_k[i] < stoch_d[i] and stoch_k[i] >= 70

            sig = 0
            if (macd_buy and stoch_k[i] < 50) or (stoch_buy and hist > 0):
                sig = 1
            elif (macd_sell and stoch_k[i] > 50) or (stoch_sell and hist < 0):
                sig = -1

            if sig != 0 and T[i + 1] >= BENCHMARK_START_TIME:
                in_trade = True
                direction = sig
                entry_p = O[i + 1]
                t_entry = T[i + 1]
                bars_in_trade = 0
                dist = sl_atr * atr[i]
                if direction == 1:
                    sl = entry_p - dist
                    tp = entry_p + dist * rr
                else:
                    sl = entry_p + dist
                    tp = entry_p - dist * rr

    if in_trade:
        trades.append({
            "entry_time": t_entry, "exit_time": T[-1],
            "dir": direction, "entry": entry_p, "exit": C[-1],
            "pnl": calc_pnl_usd(symbol, direction, entry_p, C[-1]),
            "reason": "CLOSE_END"
        })

    return [t for t in trades if t["entry_time"] >= BENCHMARK_START_TIME]


# 4. RapidScalper_EA (M1 scalper candle-follow)
def sim_rapidscalper(T, O, H, L, C, symbol, tf, tp_pts=50, sl_pts=100, close_bars=3):
    n = len(C)
    pt = POINT_SIZE[symbol]
    tp_dist = tp_pts * pt
    sl_dist = sl_pts * pt
    trades = []
    in_trade = False
    direction = 0
    entry_p = 0.0
    sl = 0.0
    tp = 0.0
    t_entry = ""
    bars_held = 0

    for i in range(1, n - 1):
        if in_trade:
            bars_held += 1
            hit_sl = (L[i] <= sl) if direction == 1 else (H[i] >= sl)
            hit_tp = (H[i] >= tp) if direction == 1 else (L[i] <= tp)
            if hit_sl and hit_tp:
                trades.append({
                    "entry_time": t_entry, "exit_time": T[i],
                    "dir": direction, "entry": entry_p, "exit": sl,
                    "pnl": calc_pnl_usd(symbol, direction, entry_p, sl),
                    "reason": "SL"
                })
                in_trade = False
            elif hit_sl:
                trades.append({
                    "entry_time": t_entry, "exit_time": T[i],
                    "dir": direction, "entry": entry_p, "exit": sl,
                    "pnl": calc_pnl_usd(symbol, direction, entry_p, sl),
                    "reason": "SL"
                })
                in_trade = False
            elif hit_tp:
                trades.append({
                    "entry_time": t_entry, "exit_time": T[i],
                    "dir": direction, "entry": entry_p, "exit": tp,
                    "pnl": calc_pnl_usd(symbol, direction, entry_p, tp),
                    "reason": "TP"
                })
                in_trade = False
            elif close_bars > 0 and bars_held >= close_bars:
                exit_p = O[i]
                trades.append({
                    "entry_time": t_entry, "exit_time": T[i],
                    "dir": direction, "entry": entry_p, "exit": exit_p,
                    "pnl": calc_pnl_usd(symbol, direction, entry_p, exit_p),
                    "reason": "TIME_EXIT"
                })
                in_trade = False

        if not in_trade:
            # Ikuti candle sebelumnya
            if C[i] > O[i]:
                sig = 1
            elif C[i] < O[i]:
                sig = -1
            else:
                sig = 0
            if sig != 0 and T[i + 1] >= BENCHMARK_START_TIME:
                in_trade = True
                direction = sig
                entry_p = O[i + 1]
                t_entry = T[i + 1]
                bars_held = 0
                if direction == 1:
                    sl = entry_p - sl_dist
                    tp = entry_p + tp_dist
                else:
                    sl = entry_p + sl_dist
                    tp = entry_p - tp_dist

    if in_trade:
        trades.append({
            "entry_time": t_entry, "exit_time": T[-1],
            "dir": direction, "entry": entry_p, "exit": C[-1],
            "pnl": calc_pnl_usd(symbol, direction, entry_p, C[-1]),
            "reason": "CLOSE_END"
        })

    return [t for t in trades if t["entry_time"] >= BENCHMARK_START_TIME]


# 5. StraddleBreakout_EA (Stop Order Breakout + OCO)
def sim_straddlebreakout(T, O, H, L, C, symbol, tf, dist_pts=80, sl_pts=160, tp_pts=240):
    n = len(C)
    pt = POINT_SIZE[symbol]
    d_dist = dist_pts * pt
    d_sl = sl_pts * pt
    d_tp = tp_pts * pt
    trades = []
    in_pos = False
    direction = 0
    entry_p = 0.0
    sl = 0.0
    tp = 0.0
    t_entry = ""
    # Pending stop levels
    buy_stop = 0.0
    sell_stop = 0.0

    for i in range(1, n - 1):
        if in_pos:
            hit_sl = (L[i] <= sl) if direction == 1 else (H[i] >= sl)
            hit_tp = (H[i] >= tp) if direction == 1 else (L[i] <= tp)
            if hit_sl and hit_tp:
                trades.append({
                    "entry_time": t_entry, "exit_time": T[i],
                    "dir": direction, "entry": entry_p, "exit": sl,
                    "pnl": calc_pnl_usd(symbol, direction, entry_p, sl),
                    "reason": "SL"
                })
                in_pos = False
                buy_stop = 0.0
                sell_stop = 0.0
            elif hit_sl:
                trades.append({
                    "entry_time": t_entry, "exit_time": T[i],
                    "dir": direction, "entry": entry_p, "exit": sl,
                    "pnl": calc_pnl_usd(symbol, direction, entry_p, sl),
                    "reason": "SL"
                })
                in_pos = False
                buy_stop = 0.0
                sell_stop = 0.0
            elif hit_tp:
                trades.append({
                    "entry_time": t_entry, "exit_time": T[i],
                    "dir": direction, "entry": entry_p, "exit": tp,
                    "pnl": calc_pnl_usd(symbol, direction, entry_p, tp),
                    "reason": "TP"
                })
                in_pos = False
                buy_stop = 0.0
                sell_stop = 0.0
        else:
            # Check trigger pending
            if buy_stop > 0 and sell_stop > 0:
                trig_buy = H[i] >= buy_stop
                trig_sell = L[i] <= sell_stop
                if trig_buy and not trig_sell:
                    in_pos = True
                    direction = 1
                    entry_p = buy_stop
                    t_entry = T[i]
                    sl = entry_p - d_sl
                    tp = entry_p + d_tp
                    buy_stop = 0.0
                    sell_stop = 0.0
                elif trig_sell and not trig_buy:
                    in_pos = True
                    direction = -1
                    entry_p = sell_stop
                    t_entry = T[i]
                    sl = entry_p + d_sl
                    tp = entry_p - d_tp
                    buy_stop = 0.0
                    sell_stop = 0.0
                else:
                    # Recenter straddle per candle
                    buy_stop = C[i] + d_dist
                    sell_stop = C[i] - d_dist
            else:
                if T[i] >= BENCHMARK_START_TIME:
                    buy_stop = C[i] + d_dist
                    sell_stop = C[i] - d_dist

    if in_pos:
        trades.append({
            "entry_time": t_entry, "exit_time": T[-1],
            "dir": direction, "entry": entry_p, "exit": C[-1],
            "pnl": calc_pnl_usd(symbol, direction, entry_p, C[-1]),
            "reason": "CLOSE_END"
        })

    return [t for t in trades if t["entry_time"] >= BENCHMARK_START_TIME]


# 6. SmcLiquiditySweep_EA (Sweep + S/R breakout & FVG)
def sim_smcliquiditysweep(T, O, H, L, C, symbol, tf, lookback=20, rr=2.0, sl_buf_pts=30):
    n = len(C)
    pt = POINT_SIZE[symbol]
    sl_buf = sl_buf_pts * pt
    trades = []
    in_pos = False
    direction = 0
    entry_p = 0.0
    sl = 0.0
    tp = 0.0
    t_entry = ""

    for i in range(lookback + 2, n - 1):
        if in_pos:
            hit_sl = (L[i] <= sl) if direction == 1 else (H[i] >= sl)
            hit_tp = (H[i] >= tp) if direction == 1 else (L[i] <= tp)
            if hit_sl and hit_tp:
                trades.append({
                    "entry_time": t_entry, "exit_time": T[i],
                    "dir": direction, "entry": entry_p, "exit": sl,
                    "pnl": calc_pnl_usd(symbol, direction, entry_p, sl),
                    "reason": "SL"
                })
                in_pos = False
            elif hit_sl:
                trades.append({
                    "entry_time": t_entry, "exit_time": T[i],
                    "dir": direction, "entry": entry_p, "exit": sl,
                    "pnl": calc_pnl_usd(symbol, direction, entry_p, sl),
                    "reason": "SL"
                })
                in_pos = False
            elif hit_tp:
                trades.append({
                    "entry_time": t_entry, "exit_time": T[i],
                    "dir": direction, "entry": entry_p, "exit": tp,
                    "pnl": calc_pnl_usd(symbol, direction, entry_p, tp),
                    "reason": "TP"
                })
                in_pos = False

        if not in_pos:
            # Deteksi sweep di candle i
            c1, l1, h1 = C[i], L[i], H[i]
            prev_lows = L[i - lookback:i]
            prev_highs = H[i - lookback:i]
            swing_low = min(prev_lows)
            swing_high = max(prev_highs)

            # Bullish sweep: tusuk ke bawah swing_low tapi close di atasnya
            bull_sweep = (l1 < swing_low) and (c1 > swing_low)
            # Bearish sweep: tusuk ke atas swing_high tapi close di bawahnya
            bear_sweep = (h1 > swing_high) and (c1 < swing_high)

            if bull_sweep and T[i + 1] >= BENCHMARK_START_TIME:
                in_pos = True
                direction = 1
                entry_p = O[i + 1]
                t_entry = T[i + 1]
                sl = l1 - sl_buf
                risk = max(entry_p - sl, 5 * pt)
                tp = entry_p + risk * rr
            elif bear_sweep and T[i + 1] >= BENCHMARK_START_TIME:
                in_pos = True
                direction = -1
                entry_p = O[i + 1]
                t_entry = T[i + 1]
                sl = h1 + sl_buf
                risk = max(sl - entry_p, 5 * pt)
                tp = entry_p - risk * rr

    if in_pos:
        trades.append({
            "entry_time": t_entry, "exit_time": T[-1],
            "dir": direction, "entry": entry_p, "exit": C[-1],
            "pnl": calc_pnl_usd(symbol, direction, entry_p, C[-1]),
            "reason": "CLOSE_END"
        })

    return [t for t in trades if t["entry_time"] >= BENCHMARK_START_TIME]


# 7. SMC_Structure_EA (Swing, MSS, OB/FVG limit)
def sim_smcstructure(T, O, H, L, C, symbol, tf, swing_bars=3, lookback=100, rr=2.0):
    n = len(C)
    pt = POINT_SIZE[symbol]
    trades = []
    in_pos = False
    direction = 0
    entry_p = 0.0
    sl = 0.0
    tp = 0.0
    t_entry = ""
    pending_limit = False
    limit_price = 0.0
    limit_dir = 0
    limit_sl = 0.0
    limit_tp = 0.0
    limit_bars_left = 0

    # Pivot deteksi
    SH = [False] * n
    SL = [False] * n
    for t in range(swing_bars, n - swing_bars):
        sh = all(H[t] >= H[t - k] and H[t] > H[t + k] for k in range(1, swing_bars + 1))
        sl_b = all(L[t] <= L[t - k] and L[t] < L[t + k] for k in range(1, swing_bars + 1))
        SH[t] = sh
        SL[t] = sl_b

    for i in range(lookback + 5, n - 1):
        if in_pos:
            hit_sl = (L[i] <= sl) if direction == 1 else (H[i] >= sl)
            hit_tp = (H[i] >= tp) if direction == 1 else (L[i] <= tp)
            if hit_sl and hit_tp:
                trades.append({
                    "entry_time": t_entry, "exit_time": T[i],
                    "dir": direction, "entry": entry_p, "exit": sl,
                    "pnl": calc_pnl_usd(symbol, direction, entry_p, sl),
                    "reason": "SL"
                })
                in_pos = False
            elif hit_sl:
                trades.append({
                    "entry_time": t_entry, "exit_time": T[i],
                    "dir": direction, "entry": entry_p, "exit": sl,
                    "pnl": calc_pnl_usd(symbol, direction, entry_p, sl),
                    "reason": "SL"
                })
                in_pos = False
            elif hit_tp:
                trades.append({
                    "entry_time": t_entry, "exit_time": T[i],
                    "dir": direction, "entry": entry_p, "exit": tp,
                    "pnl": calc_pnl_usd(symbol, direction, entry_p, tp),
                    "reason": "TP"
                })
                in_pos = False
        elif pending_limit:
            limit_bars_left -= 1
            # Cek apakah limit order tersentuh
            hit_limit = (L[i] <= limit_price) if limit_dir == 1 else (H[i] >= limit_price)
            if hit_limit:
                in_pos = True
                direction = limit_dir
                entry_p = limit_price
                t_entry = T[i]
                sl = limit_sl
                tp = limit_tp
                pending_limit = False
            elif limit_bars_left <= 0:
                pending_limit = False
        else:
            # Deteksi MSS & FVG
            # Cari swing terdekat
            # Cek bila candle i break swing sebelumnya (MSS)
            for k in range(i - 1, max(0, i - lookback), -1):
                if SH[k] and C[i] > H[k] and C[i - 1] <= H[k]:
                    # Bullish MSS: pasang limit di FVG / retrace 50%
                    fvg_entry = (H[k] + L[i]) * 0.5
                    sl_lvl = min(L[k:i + 1]) - 10 * pt
                    risk = fvg_entry - sl_lvl
                    if risk > 5 * pt and T[i] >= BENCHMARK_START_TIME:
                        pending_limit = True
                        limit_dir = 1
                        limit_price = fvg_entry
                        limit_sl = sl_lvl
                        limit_tp = fvg_entry + risk * rr
                        limit_bars_left = 15
                    break
                elif SL[k] and C[i] < L[k] and C[i - 1] >= L[k]:
                    # Bearish MSS
                    fvg_entry = (L[k] + H[i]) * 0.5
                    sl_lvl = max(H[k:i + 1]) + 10 * pt
                    risk = sl_lvl - fvg_entry
                    if risk > 5 * pt and T[i] >= BENCHMARK_START_TIME:
                        pending_limit = True
                        limit_dir = -1
                        limit_price = fvg_entry
                        limit_sl = sl_lvl
                        limit_tp = fvg_entry - risk * rr
                        limit_bars_left = 15
                    break

    if in_pos:
        trades.append({
            "entry_time": t_entry, "exit_time": T[-1],
            "dir": direction, "entry": entry_p, "exit": C[-1],
            "pnl": calc_pnl_usd(symbol, direction, entry_p, C[-1]),
            "reason": "CLOSE_END"
        })

    return [t for t in trades if t["entry_time"] >= BENCHMARK_START_TIME]


# 8. GoldTrailStop_EA (Momentum Buy + Trailing Stop Protection)
def sim_goldtrailstop(T, O, H, L, C, symbol, tf, stop_dist_pts=250, trail_step_pts=20, target_usd=15.0):
    n = len(C)
    pt = POINT_SIZE[symbol]
    d_stop = stop_dist_pts * pt
    d_step = trail_step_pts * pt
    trades = []
    in_pos = False
    direction = 1  # Buy momentum
    entry_p = 0.0
    sl = 0.0
    highest_p = 0.0
    t_entry = ""

    for i in range(1, n - 1):
        if in_pos:
            # Trailing stop
            if H[i] > highest_p:
                profit_move = H[i] - entry_p
                if profit_move > d_stop * 0.5:
                    # Naikkan SL
                    new_sl = H[i] - d_stop
                    if new_sl > sl + d_step:
                        sl = new_sl
                highest_p = H[i]

            # Cek SL
            if L[i] <= sl:
                trades.append({
                    "entry_time": t_entry, "exit_time": T[i],
                    "dir": direction, "entry": entry_p, "exit": sl,
                    "pnl": calc_pnl_usd(symbol, direction, entry_p, sl),
                    "reason": "SL_TRAIL"
                })
                in_pos = False
            else:
                # Cek target profit USD
                cur_profit = calc_pnl_usd(symbol, direction, entry_p, H[i])
                if cur_profit >= target_usd:
                    # Tutup di target USD
                    exit_p = entry_p + (target_usd / (1.0 if symbol == "xauusd" else 1000.0))
                    trades.append({
                        "entry_time": t_entry, "exit_time": T[i],
                        "dir": direction, "entry": entry_p, "exit": exit_p,
                        "pnl": target_usd,
                        "reason": "TARGET_USD"
                    })
                    in_pos = False
        else:
            # Momentum entry: candle bullish
            if C[i] > O[i] and T[i + 1] >= BENCHMARK_START_TIME:
                in_pos = True
                entry_p = O[i + 1]
                t_entry = T[i + 1]
                sl = entry_p - d_stop
                highest_p = entry_p

    if in_pos:
        trades.append({
            "entry_time": t_entry, "exit_time": T[-1],
            "dir": direction, "entry": entry_p, "exit": C[-1],
            "pnl": calc_pnl_usd(symbol, direction, entry_p, C[-1]),
            "reason": "CLOSE_END"
        })

    return [t for t in trades if t["entry_time"] >= BENCHMARK_START_TIME]


# ----------------- Evaluator & Reporting -----------------
def evaluate_trades(trades, initial_balance=INITIAL_BALANCE):
    if not trades:
        return {
            "total_trades": 0, "wins": 0, "losses": 0, "win_rate": 0.0,
            "net_profit": 0.0, "final_balance": initial_balance, "return_pct": 0.0, "profit_factor": 0.0,
            "max_dd_usd": 0.0, "max_dd_pct": 0.0, "is_mc": False, "trades": []
        }

    # Simulasi eksekusi saldo & Drawdown dengan deteksi Stop Out
    equity = initial_balance
    peak = initial_balance
    max_dd_usd = 0.0
    max_dd_pct = 0.0
    executed_trades = []
    is_mc = False

    for t in trades:
        executed_trades.append(t)
        equity += t["pnl"]
        if equity > peak:
            peak = equity
        dd = peak - equity
        dd_pct = (dd / peak * 100.0) if peak > 0 else 0.0
        if dd > max_dd_usd:
            max_dd_usd = dd
        if dd_pct > max_dd_pct:
            max_dd_pct = dd_pct
        
        # Jika modal $100 habis tergerus (margin stop out di broker)
        if equity <= 2.0:
            is_mc = True
            equity = 0.0
            max_dd_pct = 100.0
            max_dd_usd = initial_balance
            break

    wins = [t for t in executed_trades if t["pnl"] > 0]
    losses = [t for t in executed_trades if t["pnl"] <= 0]
    gross_profit = sum(t["pnl"] for t in wins)
    gross_loss = abs(sum(t["pnl"] for t in losses))
    net_profit = equity - initial_balance

    pf = (gross_profit / gross_loss) if gross_loss > 0 else (99.9 if gross_profit > 0 else 0.0)
    win_rate = (len(wins) / len(executed_trades) * 100.0) if executed_trades else 0.0

    return {
        "total_trades": len(executed_trades),
        "wins": len(wins),
        "losses": len(losses),
        "win_rate": win_rate,
        "gross_profit": gross_profit,
        "gross_loss": gross_loss,
        "net_profit": net_profit,
        "final_balance": equity,
        "return_pct": (net_profit / initial_balance) * 100.0,
        "profit_factor": pf,
        "max_dd_usd": max_dd_usd,
        "max_dd_pct": max_dd_pct,
        "is_mc": is_mc,
        "trades": executed_trades
    }

def main():
    print("=" * 80)
    print("BENCHMARK PENGUJIAN SEMUA STRATEGI EA (5 HARI TRADING TERAKHIR)")
    print(f"Start Window: {BENCHMARK_START_TIME} UTC | Modal: ${INITIAL_BALANCE:,.2f} | Lot: {LOT_SIZE}")
    print("=" * 80 + "\n")

    symbols = ["xauusd", "eurusd", "usdjpy"]
    
    # Konfigurasi pengujian tiap strategi beserta timeframe yang didukung
    matrix = [
        # MaTrend_EA
        ("MaTrend_EA (H1)", sim_matrend, "h1", {}),
        ("MaTrend_EA (M15)", sim_matrend, "m15", {"fast_p": 5, "slow_p": 50, "rr": 5.0, "sl_atr": 1.5}),
        ("MaTrend_EA (M5)", sim_matrend, "m5", {"fast_p": 8, "slow_p": 34, "rr": 3.0, "sl_atr": 1.5}),
        # EmaPullback_EA
        ("EmaPullback_EA (M5)", sim_emapullback, "m5", {"rr": 2.0, "sl_atr": 1.5}),
        ("EmaPullback_EA (M15)", sim_emapullback, "m15", {"rr": 2.0, "sl_atr": 1.5}),
        # StochMacd_EA
        ("StochMacd_EA (M15)", sim_stochmacd, "m15", {"rr": 1.5, "sl_atr": 1.5}),
        ("StochMacd_EA (M5)", sim_stochmacd, "m5", {"rr": 1.5, "sl_atr": 1.5}),
        # SmcLiquiditySweep_EA
        ("SmcLiquiditySweep_EA (M5)", sim_smcliquiditysweep, "m5", {"lookback": 20, "rr": 2.0}),
        ("SmcLiquiditySweep_EA (M15)", sim_smcliquiditysweep, "m15", {"lookback": 20, "rr": 2.0}),
        # SMC_Structure_EA
        ("SMC_Structure_EA (M15)", sim_smcstructure, "m15", {"swing_bars": 3, "rr": 2.0}),
        ("SMC_Structure_EA (H1)", sim_smcstructure, "h1", {"swing_bars": 3, "rr": 2.0}),
        # RapidScalper_EA
        ("RapidScalper_EA (M1)", sim_rapidscalper, "m1", {"tp_pts": 50, "sl_pts": 100, "close_bars": 3}),
        # StraddleBreakout_EA
        ("StraddleBreakout_EA (M1)", sim_straddlebreakout, "m1", {"dist_pts": 80, "sl_pts": 160, "tp_pts": 240}),
        ("StraddleBreakout_EA (M5)", sim_straddlebreakout, "m5", {"dist_pts": 80, "sl_pts": 160, "tp_pts": 240}),
        # GoldTrailStop_EA
        ("GoldTrailStop_EA (M5)", sim_goldtrailstop, "m5", {"stop_dist_pts": 250, "target_usd": 15.0}),
    ]

    all_results = []

    for sym in symbols:
        print(f"\n>>> PENGUJIAN PASANGAN: {sym.upper()} <<<")
        print("-" * 80)
        print(f"{'Strategi & Timeframe':<28} | {'Trades':<6} | {'Win%':<6} | {'Net Profit':<12} | {'Return':<7} | {'PF':<5} | {'Max DD':<10}")
        print("-" * 80)

        # Cache data CSV per timeframe
        cached_data = {}

        for name, func, tf, kwargs in matrix:
            # Khusus GoldTrailStop utamakan XAUUSD, tapi bisa uji di pair lain juga
            csv_path = os.path.join(DATA_DIR, f"{sym}_{tf}.csv")
            if not os.path.exists(csv_path):
                continue
            if tf not in cached_data:
                cached_data[tf] = load_csv(csv_path)

            T, O, H, L, C = cached_data[tf]
            trades = func(T, O, H, L, C, sym, tf, **kwargs)
            res = evaluate_trades(trades)

            res["strategy_name"] = name
            res["symbol"] = sym
            res["tf"] = tf
            all_results.append(res)

            pnl_str = f"${res['net_profit']:+7.2f}"
            ret_str = f"{res['return_pct']:+5.2f}%"
            pf_str = f"{res['profit_factor']:4.2f}" if res['profit_factor'] < 99 else "  N/A"
            dd_str = f"${res['max_dd_usd']:5.2f} ({res['max_dd_pct']:4.1f}%)"

            print(f"{name:<28} | {res['total_trades']:<6d} | {res['win_rate']:5.1f}% | {pnl_str:<12} | {ret_str:<7} | {pf_str:<5} | {dd_str:<10}")

    # Ranking Keseluruhan Berdasarkan Net Profit
    print("\n\n" + "=" * 95)
    print("RANKING KESELURUHAN STRATEGI PALING PROFIT DALAM 5 HARI TERAKHIR")
    print("=" * 95)
    sorted_res = sorted(all_results, key=lambda x: x["net_profit"], reverse=True)

    print(f"{'Rank':<4} | {'Simbol':<7} | {'Strategi & Timeframe':<28} | {'Trades':<6} | {'Win%':<6} | {'Net Profit':<12} | {'Saldo Akhir':<11} | {'Return':<8} | {'Max DD':<10}")
    print("-" * 108)
    for rank, r in enumerate(sorted_res, 1):
        pnl_str = f"${r['net_profit']:+7.2f}"
        bal_str = f"${r['final_balance']:7.2f}"
        ret_str = f"{r['return_pct']:+6.1f}%"
        pf_str = f"{r['profit_factor']:4.2f}" if r['profit_factor'] < 99 else "  N/A"
        dd_str = f"${r['max_dd_usd']:5.2f} ({r['max_dd_pct']:4.1f}%)"
        status_suffix = " [MC]" if r.get("is_mc") else ""
        print(f"{rank:<4} | {r['symbol'].upper():<7} | {r['strategy_name']:<28} | {r['total_trades']:<6d} | {r['win_rate']:5.1f}% | {pnl_str:<12} | {bal_str:<11} | {ret_str:<8} | {dd_str:<10}{status_suffix}")

    # Simpan hasil lengkap ke JSON untuk referensi detail
    import json
    with open("benchmark_results_5days.json", "w", encoding="utf-8") as f:
        json_clean = []
        for r in sorted_res:
            item = dict(r)
            item.pop("trades", None)
            json_clean.append(item)
        json.dump(json_clean, f, indent=2)
    print(f"\nHasil ringkasan lengkap telah disimpan ke 'benchmark_results_5days.json'.")

if __name__ == "__main__":
    main()
