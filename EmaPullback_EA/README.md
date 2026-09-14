# EmaPullback EA (MT5) — Trend + Pullback EMA dengan RR Tetap

Strategi trend-following untuk **XAUUSD M5** (bisa juga pair lain) dengan
Risk/Reward tetap yang bisa dipilih: **1:1, 1:2, atau bebas** lewat satu
parameter (`InpRR`).

## Logika Strategi

```
UPTREND  = EMA50 > EMA200  dan harga close di atas EMA200
DOWNTREND = EMA50 < EMA200 dan harga close di bawah EMA200

Sinyal BUY (hanya saat UPTREND):
  candle M5 menyentuh EMA21 (pullback)
  DAN ditutup kembali di atas EMA21
  DAN candle-nya bullish (opsional, InpNeedReversal)

Sinyal SELL: kebalikannya saat DOWNTREND.

SL = 1.5 x ATR(14)   (atau swing low/high N candle, pilih di InpSLMode)
TP = InpRR x jarak SL   ->  InpRR = 1.0 berarti RR 1:1, 2.0 berarti 1:2
```

Kenapa bentuknya begini:

- **SL berbasis ATR/swing, bukan angka tetap** — jarak SL menyesuaikan
  volatilitas, sehingga RR 1:2 tetap bermakna baik saat pasar tenang maupun
  saat GOLD sedang liar.
- **RR 1:2 hanya butuh winrate ±38–40%** untuk profit; strategi pullback
  searah tren biasanya menghasilkan winrate 40–50%.
- **Filter tren dua EMA** membuang sinyal counter-trend yang menjadi
  penyumbang loss terbesar strategi pullback.

## Parameter

| Parameter | Default | Keterangan |
|---|---|---|
| `InpMagic` | 20260811 | Magic number |
| `InpLotMode` | LOT_FIXED | Lot tetap, atau otomatis dari % risiko equity |
| `InpLot` | 0.01 | Lot tetap (default minimal) |
| `InpRiskPercent` | 1.0 | Risiko per trade (% equity) saat mode risk percent |
| `InpMaxSpreadPts` | 60 | Spread maksimal saat entry (points); 0 = abaikan |
| `InpEmaTrendFast` | 50 | EMA tren cepat |
| `InpEmaTrendSlow` | 200 | EMA tren lambat |
| `InpEmaPullback` | 21 | EMA area pullback (trigger entry) |
| `InpNeedReversal` | true | Wajib candle reversal searah tren |
| **`InpRR`** | **2.0** | **TP = RR × SL. Isi 1.0 untuk RR 1:1, 2.0 untuk 1:2** |
| `InpSLMode` | SL_ATR | SL dari ATR atau dari swing high/low |
| `InpATRPeriod` | 14 | Periode ATR |
| `InpATRMult` | 1.5 | SL = ATR × multiplier ini |
| `InpSwingBars` | 10 | Jumlah candle swing (mode swing) |
| `InpSLBufferPts` | 30 | Buffer di belakang swing (points) |
| `InpBreakEvenRR` | 0.0 | Geser SL ke entry setelah profit N × SL (mis. 1.0); 0 = mati |
| `InpMaxOpenTrades` | 1 | Maksimal posisi bersamaan |
| `InpStartHour`/`InpEndHour` | 0/0 | Filter jam server; sama = 24 jam |

Dengan mode `LOT_RISK_PERCENT` dan `InpRiskPercent = 1.0`, EA menghitung lot
otomatis supaya kalau SL kena, kerugian ±1% equity — ukuran risiko tetap
konsisten walau jarak SL berubah-ubah mengikuti ATR.

## Cara Menjalankan (Live/Demo)

EA hanya jalan di **MT5 desktop / VPS** (bukan HP; posisi tetap terlihat di HP).

1. MT5 desktop → **F4** (MetaEditor) → klik kanan folder **Experts → Open
   Folder** → salin `EmaPullback_EA.mq5` ke sana.
2. Buka file di MetaEditor → **F7** (compile) → pastikan `0 errors`.
3. Terminal MT5 → **Ctrl+N** → seret **EmaPullback_EA** ke chart **XAUUSD M5**.
4. Centang **Allow Algo Trading** → OK, dan aktifkan tombol **Algo Trading**.

Compile lewat Terminal macOS (MT5 versi Mac/Wine):

```bash
WINEPREFIX="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5" \
"/Applications/MetaTrader 5.app/Contents/SharedSupport/wine/bin/wine" \
  "C:\\mt5\\MetaEditor64.exe" \
  /compile:"C:\\mt5\\MQL5\\Experts\\EmaPullback_EA.mq5" \
  /include:"C:\\mt5\\MQL5" /log
```

## Cara Backtest di MT5

1. **Ctrl+R** (View → Strategy Tester).
2. Pengaturan tab *Settings*:
   - **Expert:** `EmaPullback_EA`
   - **Symbol:** `XAUUSD` — **Period: `M5`**
   - **Date:** custom, minimal 3–6 bulan (strategi tren butuh sampel panjang
     yang mencakup pasar trending dan sideways)
   - **Modelling:** `Every tick based on real ticks` (paling akurat) atau
     `Every tick`
   - **Deposit/leverage:** samakan dengan akun asli
3. Tab **Inputs** → klik kanan → **Load** → pilih file
   `EmaPullback_backtest.set` dari folder ini. Preset sudah berisi nilai
   default + rentang optimasi.
4. Klik **Start**. Lihat hasil di tab **Backtest** dan **Graph**.
5. **Membandingkan RR 1:1 vs 1:2:** jalankan dua kali backtest, sekali dengan
   `InpRR = 1.0` dan sekali `InpRR = 2.0`, bandingkan *Profit Factor*,
   *Expected Payoff*, dan *Max Drawdown* — bukan cuma total profit.
6. **Optimasi otomatis:** di tab Settings pilih Optimization
   `Slow complete algorithm` (atau `Fast genetic` kalau lama). Preset .set
   sudah menandai `InpRR` (1.0–3.0) dan `InpATRMult` (1.0–2.5) untuk discan.
   Setelah selesai, urutkan hasil berdasarkan *Recovery Factor*.

### Membaca hasil backtest

- **Profit Factor ≥ 1.3** dan **Recovery Factor ≥ 2** = layak lanjut demo.
- **Winrate** wajar untuk RR 1:2 adalah 40–50%. Winrate 60%+ dengan RR 1:2
  di backtest pendek biasanya kebetulan (overfit) — uji ulang di periode lain.
- Cek tab **Backtest → jumlah trade**: minimal ±100 trade agar statistik
  bermakna. Kalau terlalu sedikit, perpanjang periode datanya.

## Catatan Risiko

- Strategi pullback melemah di pasar sideways panjang (EMA50/200 datar dan
  sering silang). Filter jam bisa membantu (mis. 15:00–23:00 waktu server
  untuk sesi London+NY).
- Jangan optimasi semua parameter sekaligus — cukup `InpRR` dan `InpATRMult`.
  Makin banyak yang dioptimasi, makin besar risiko overfit.
- Selalu jalankan di **akun demo minimal 1–2 minggu** sebelum akun riil,
  dan mulai dengan `LOT_RISK_PERCENT` + risiko 0.5–1% per trade.
