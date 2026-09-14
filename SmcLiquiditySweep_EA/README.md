# SmcLiquiditySweep EA (MT5) — Smart Money Concepts yang Bisa Dibacktest

Implementasi objektif dari strategi **SMC/ICT** yang paling banyak dipakai
trader retail saat ini: **Liquidity Sweep (stop hunt) + Fair Value Gap (FVG)
entry**, dengan SL di ujung sweep dan TP = RR × SL. Dirancang untuk
**XAUUSD M5/M15** tapi bisa dipakai di pair lain.

## Konsep & Alur

```
Setup BUY:

  swing low N candle ────────────────┐
                                     │   3. harga pullback turun
       ██                            │      ke area FVG -> BUY LIMIT
     ██  ██   ██                     │      terisi di sini
   ██      ██ ██  ██   ┌─ FVG ─┐    ▼
 ──────────────██──██──█████████──────────── 
  1. candle menusuk ██ ▲
     KE BAWAH swing low █ 2. reversal kuat naik
     (stop hunt) tapi     meninggalkan gap (FVG)
     DITUTUP di atasnya
     -> SL nanti di bawah ujung tusukan ini
```

1. **Liquidity Sweep** — candle menusuk ke bawah low terendah `InpLookback`
   candle (default 20), tempat stop loss retail menumpuk, tapi **ditutup
   kembali di atas** level itu. Institusi baru saja "memanen" likuiditas —
   bias berbalik naik.
2. **Fair Value Gap** — setelah sweep, tunggu candle impulsif yang
   meninggalkan gap (low candle terakhir > high dua candle sebelumnya).
   Gap minimal `InpMinFvgPts` supaya bukan noise.
3. **Entry** — BUY LIMIT di dalam FVG (`InpFvgEntryPct`: 0 = tepi atas gap,
   50 = tengah gap). Setup hangus kalau dalam `InpWaitBars` candle FVG tidak
   muncul atau harga tidak kembali.
4. **SL** di bawah ujung sweep + buffer; **TP = `InpRR` × jarak SL**
   (2.0 = RR 1:2). Sinyal SELL adalah cermin kebalikannya.
5. **Filter S/R terdekat (M5)** — sebelum entry, EA memindai swing high/low
   dari `InpSnrLookback` candle terakhir (deteksi fractal). Kalau ada
   **resistance yang lebih dekat daripada TP** (untuk BUY) atau **support
   yang lebih dekat daripada TP** (untuk SELL), entry dilewati. Target tetap
   RR 1:2 / 1:1 — S/R hanya menyaring supaya trade diambil saat jalan menuju
   TP "bersih", tidak menabrak level pantulan terdekat. Level S/R terdekat
   juga ditampilkan di komentar chart.
6. **Entry breakout S/R + pembalikan** (engine kedua, `InpUseBreakout`) —
   kalau candle **close menembus resistance terdekat** → langsung **BUY**
   (SL di bawah level yang ditembus, TP = RR × SL). Tembus support → SELL.
   Lalu candle **berikutnya** dipantau: kalau ditutup kembali di seberang
   level (breakout palsu), posisi breakout **ditutup dan EA langsung entry
   berlawanan** (`InpReverseOnFail`) dengan SL di atas/bawah puncak breakout
   palsu — tetap dengan target RR yang sama.

Mode `ENTRY_MARKET` melewatkan langkah FVG: langsung entry begitu candle
sweep ditutup — sinyal lebih sering, tapi harga entry kurang optimal.

## Parameter

| Parameter | Default | Keterangan |
|---|---|---|
| `InpMagic` | 20260812 | Magic number |
| `InpLotMode` | LOT_FIXED | Lot tetap atau % risiko equity |
| `InpLot` | 0.01 | Lot tetap (default minimal) |
| `InpRiskPercent` | 1.0 | Risiko per trade (% equity) |
| `InpMaxSpreadPts` | 60 | Spread maksimal (points); 0 = abaikan |
| `InpLookback` | 20 | Candle penentu swing high/low (area likuiditas) |
| `InpEntryMode` | ENTRY_FVG | FVG limit (selektif) atau market (sering) |
| `InpWaitBars` | 12 | Masa berlaku setup setelah sweep (candle) |
| `InpFvgEntryPct` | 50 | Posisi entry dalam FVG: 0 = tepi, 50 = tengah |
| `InpMinFvgPts` | 10 | Ukuran FVG minimal (points) |
| `InpUseTrendFilter` | false | Filter arah EMA (hanya BUY di atas EMA200, dst.) |
| `InpEmaTrendPeriod` | 200 | Periode EMA filter |
| `InpUseSnrFilter` | true | Lewati entry jika TP terhalang S/R terdekat |
| `InpSnrLookback` | 100 | Jumlah candle M5 yang discan untuk level S/R |
| `InpSnrFractalBars` | 2 | Kekuatan swing (bar kiri-kanan harus lebih rendah/tinggi) |
| `InpSnrBufferPts` | 20 | Buffer di belakang level S/R (points) |
| `InpUseBreakout` | true | Entry saat close menembus S/R terdekat |
| `InpBreakBufferPts` | 20 | Minimal close melewati level agar dihitung breakout (points) |
| `InpReverseOnFail` | true | Candle berikutnya balik arah → tutup posisi & entry berlawanan |
| **`InpRR`** | **2.0** | **TP = RR × SL (1.0 = 1:1, 2.0 = 1:2, 3.0 = 1:3)** |
| `InpSLBufferPts` | 30 | Buffer SL di belakang ujung sweep (points) |
| `InpBreakEvenRR` | 0.0 | SL ke entry setelah profit N × SL; 0 = mati |
| `InpMaxOpenTrades` | 1 | Maksimal posisi bersamaan |
| `InpStartHour`/`InpEndHour` | 0/0 | Filter jam server; sama = 24 jam |

**Tips sesi (ala ICT):** strategi sweep paling bagus saat likuiditas besar —
open London dan open New York. Coba `InpStartHour=14, InpEndHour=23` (sesuaikan
GMT broker; kebanyakan broker GMT+2/+3 → London open ±10:00, NY open ±16:30
waktu server).

## Cara Menjalankan (Live/Demo)

EA hanya jalan di **MT5 desktop / VPS** (bukan HP; posisi tetap terlihat di HP).

1. MT5 desktop → **F4** (MetaEditor) → klik kanan **Experts → Open Folder** →
   salin `SmcLiquiditySweep_EA.mq5` ke sana.
2. Compile dengan **F7** → pastikan `0 errors, 0 warnings`.
3. Terminal MT5 → **Ctrl+N** → seret **SmcLiquiditySweep_EA** ke chart
   **XAUUSD M5**.
4. Centang **Allow Algo Trading** → OK; pastikan tombol **Algo Trading** aktif.
5. Status setup (scan / sweep terdeteksi / posisi aktif) tampil di pojok kiri
   atas chart.

Compile lewat Terminal macOS (MT5 versi Mac/Wine):

```bash
WINEPREFIX="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5" \
"/Applications/MetaTrader 5.app/Contents/SharedSupport/wine/bin/wine" \
  "C:\\mt5\\MetaEditor64.exe" \
  /compile:"C:\\mt5\\MQL5\\Experts\\SmcLiquiditySweep_EA.mq5" \
  /include:"C:\\mt5\\MQL5" /log
```

## Cara Backtest di MT5

1. **Ctrl+R** (View → Strategy Tester).
2. Tab *Settings*:
   - **Expert:** `SmcLiquiditySweep_EA`
   - **Symbol:** `XAUUSD` — **Period: `M5`** (M15 juga bagus, sinyal lebih bersih)
   - **Date:** minimal 3–6 bulan
   - **Modelling:** `Every tick based on real ticks` — penting, karena entry
     limit di dalam FVG sensitif terhadap urutan pergerakan harga di dalam candle
3. Tab **Inputs** → klik kanan → **Load** → pilih preset
   `SmcLiquiditySweep_backtest` (sudah tersedia di folder Presets MT5).
4. **Start**. Centang **Visual mode** untuk melihat prosesnya: sweep terjadi →
   limit order muncul di FVG → terisi saat pullback.
5. Bandingkan dua mode entry: jalankan sekali dengan `InpEntryMode = ENTRY_FVG`
   dan sekali `ENTRY_MARKET` — biasanya FVG lebih sedikit trade tapi kualitas
   entry (dan RR realisasi) lebih baik.
6. Optimasi: preset sudah menandai `InpRR` (1.0–3.0) dan `InpLookback` (10–40)
   untuk discan. Pilih hasil berdasarkan *Profit Factor* / *Recovery Factor*.

### Ekspektasi yang sehat

- Sinyal **jarang**: mode FVG di M5 biasanya hanya 0–3 trade per hari.
  Itu normal — strategi ini menukar frekuensi dengan kualitas entry.
- Winrate wajar 40–55% dengan RR 1:2. Kalau backtest menunjukkan winrate
  tinggi sekali dengan trade sangat sedikit, perpanjang periode datanya dulu
  sebelum percaya.

## Catatan Risiko

- Sweep palsu tetap ada — kadang "stop hunt" ternyata awal breakout sungguhan
  dan SL kena. Itu bagian dari statistik strategi, bukan kegagalan sistem;
  yang penting RR menjaga rata-rata tetap positif.
- Definisi OB/FVG di komunitas SMC bervariasi; EA ini memakai definisi FVG
  standar 3-candle yang paling umum dan bisa diuji. Jangan heran kalau
  entry-nya tidak selalu sama dengan analisa SMC manual di chart.
- Hindari news berdampak tinggi (NFP, CPI, FOMC) — sweep saat news bisa
  bergerak jauh melebihi buffer SL karena slippage.
- Seperti biasa: **demo dulu 1–2 minggu**, mulai dengan risiko 0.5–1% per trade.
