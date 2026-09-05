# StochMacd EA (v1.00)

EA MetaTrader 5 untuk **M15** dengan dua indikator utama: **MACD** (arah & tenaga momentum)
dan **Stochastic** (titik balik jangka pendek). Sinyal hanya sah bila keduanya setuju
dalam jendela beberapa bar — MACD memberi konteks, Stochastic memberi timing.
Dikalibrasi untuk **Exness Pro XAUUSD M15** (3 digit, spread 180–200 pts).

## File

| File | Keterangan |
|------|-----------|
| `StochMacd_EA.mq5` | Source EA v1.00 |
| `StochMacd_XAUUSD_M15.set` | Preset input XAUUSD M15 (58 input, urutan sama dengan EA) |
| `fetch_m15.py` | Unduh OHLC M15 dari Yahoo Finance ke CSV |
| `sim_stochmacd.py` | Port 1:1 logika EA untuk backtest cepat di CSV (bukan bagian EA) |
| `xauusd_m15.csv`, `eurusd_m15.csv` | Data uji yang dipakai di bawah (26 Jun – 4 Sep 2026) |

## Cara Pakai

1. Salin folder ini ke `MQL5/Experts/StochMacd_EA/`, buka MetaEditor (F4) → `StochMacd_EA.mq5` → **F7**.
2. Strategy Tester: symbol **XAUUSD**, **M15**, model *Every tick based on real ticks*
   atau *1 minute OHLC*, load `StochMacd_XAUUSD_M15.set`. Perhatikan tab **Journal**.
3. Uji demo dulu. **Forex mayor belum terbukti** dengan preset ini (lihat bagian batasan).

Backtest cepat tanpa MT5:

```bash
python3 fetch_m15.py "GC=F" xauusd_m15.csv    # ~60 hari M15 emas
python3 sim_stochmacd.py xauusd_m15.csv       # hasil dengan parameter default EA
python3 sim_stochmacd.py xauusd_m15.csv --grid  # sapuan parameter
```

## Logika

| Bagian | Implementasi |
|--------|--------------|
| **MACD** | `iMACD(12, 26, 9, PRICE_CLOSE)`. Default `InpMacdMode = MACD_HIST`: main > signal **dan** histogram menguat (`h[1] > h[2]` untuk BUY). Mode lain: `MACD_CROSS` (butuh cross), `MACD_STATE` (cukup main > signal). |
| **Stochastic** | `iStochastic(21, 3, 3, SMA, LOWHIGH)`. Default `STO_CROSS_ZONE`: %K cross %D dan cross itu terjadi di bawah `InpStochOS` (BUY) / di atas `InpStochOB` (SELL). |
| **Konfluensi** | Kedua syarat harus terpenuhi dalam `InpConfluenceBars` (3) bar terakhir, **dan** kejadian yang paling akhir jatuh tepat di bar terakhir yang sudah closed. Aturan terakhir ini yang membuat satu sinyal per kejadian, bukan sinyal berulang selama kondisi bertahan. |
| **Pemicu** | `InpTrigger`: `TRIG_ANY` (siapa pun yang datang terakhir), `TRIG_STOCH`, `TRIG_MACD`. |
| **Filter opsional** | EMA200 (`InpUseEma`), sisi garis nol MACD (`InpMacdZero`), tenaga histogram minimal (`InpMinHistAtr`), jam sesi (`InpUseSession`) — semuanya default **off**. |
| **Entry** | Market di bar baru (`ENTRY_MARKET`), atau limit pullback `InpPullbackAtr` × ATR yang kadaluarsa setelah `InpEntryValidBars` bar. |
| **SL** | Default `SL_ATR`: 1.5 × ATR dari entry. Alternatif `SL_SWING` (swing 10 bar + buffer ATR). Dijepit ke `[InpSlMinAtr, InpSlMaxAtr]` × ATR, dan ke `SYMBOL_TRADE_STOPS_LEVEL`. |
| **TP** | Default RR tetap 1.5. Alternatif `TP_SWING` (swing berlawanan terdekat, RR dijepit `[InpMinRR, InpMaxRR]`). |
| **Batas waktu** | `InpMaxBarsInTrade = 16` bar (4 jam). Sinyal osilator M15 punya umur pakai; posisi yang belum selesai setelah 4 jam ditutup di market. |
| **Manajemen** | Break-even (`InpBreakEvenRR`, default **off**), trailing ATR (default off), tutup saat sinyal berlawanan / saat Stochastic sampai zona lawan (keduanya default off). |

## Kalibrasi untuk simbol 3 digit (Exness Pro)

Pelajaran dari EA sebelumnya di akun yang sama sudah dipakai sejak awal di sini:

- **Semua jarak berbasis ATR, bukan points.** Di XAUUSD 3 digit, buffer "20 points" = $0.02 — tidak berarti apa-apa. ATR M15 emas di data uji: median **$8.11** (p10 $5.61, p90 $13.30).
- **Kompensasi spread untuk SELL** (`InpSpreadCompensate`): SELL ditutup di Ask sedangkan chart memakai Bid, jadi SL/TP SELL digeser +spread.
- **Filter spread relatif risiko** (`InpMaxSpreadRiskPct = 8`): spread tidak boleh > 8% jarak SL. `InpMaxSpreadPts = 350` hanya memblok lonjakan.
- **Break-even default OFF** — di uji ini BE 1R memang menaikkan win rate 51.6% → 54.0% tetapi menurunkan hasil (+18.0R → +14.6R) dan menaikkan drawdown.
- Journal mencetak risiko $ dan % equity tiap order, plus peringatan bila > 3%.

## Hasil Backtest

Data: **GC=F (emas COMEX) M15, 26 Jun – 4 Sep 2026, 4602 bar (~70 hari)**, lot 0.01,
spread $0.19 dibebankan sekali per trade, SL diperiksa lebih dulu bila SL dan TP kena
di bar yang sama (asumsi pesimis).

| Periode | Trade | Win rate | Hasil | PF | Max DD |
|---|---|---|---|---|---|
| **Seluruh 70 hari** | 126 | 51.6% | **+18.0R = $224.96** | 1.32 | $84.39 |
| Kuartal 1 | 29 | 48.3% | +0.5R = $8.87 | 1.04 | $63.25 |
| Kuartal 2 | 27 | 55.6% | +4.0R = $29.39 | 1.36 | $53.35 |
| Kuartal 3 | 37 | 56.8% | +9.4R = $127.92 | 1.59 | $56.99 |
| Kuartal 4 | 29 | 44.8% | +2.5R = $51.22 | 1.17 | $76.65 |

Default dipilih karena **positif di keempat kuartal**, bukan karena angka totalnya paling besar.
Beberapa varian mencetak total lebih tinggi tetapi rugi di salah satu kuartal.

### Varian yang diuji

| Varian | Hasil | Catatan |
|---|---|---|
| `InpTrigger = TRIG_MACD` | +19.6R, PF 1.47, DD $57 | Lebih baik dari default di data ini; belum dipakai sebagai default karena hanya unggul di sebagian sapuan. Layak diuji sendiri. |
| `InpMacdMode = MACD_CROSS` | +18.2R, PF 1.39 | Praktis setara — jadi bagian "histogram menguat" bukan penentu. |
| `InpStochK = 14` (default MT5) | +8.1R, PF 1.14 | %K 21 jelas lebih baik; sensitivitasnya halus (K=18 → +18.7R, K=24 → +16.1R), bukan puncak sempit. |
| `InpSlMode = SL_SWING` | +9.2R, DD $124 | SL swing membuat jarak SL tidak seragam ($18.59 rata-rata) dan drawdown naik. |
| Tanpa batas 16 bar | +14.9R, DD $175 | Batas waktu memangkas drawdown lebih dari separuh. |
| `InpRR` 1.2 / 2.0 / 3.0 | +16.8R / +7.2R / +11.9R | RR 1.5 titik terbaik; RR 2.0 justru terburuk. |
| Break-even 1R / 1.5R | +14.6R / +18.0R | 1R merugikan, 1.5R tidak berpengaruh. |
| Trailing 1 ATR | +17.0R | Tidak menolong. |
| Filter EMA200 | +4.1R, hanya 36 trade | Memotong terlalu banyak. |
| `InpMacdZero = ZERO_TREND` | −2.4R, 13 trade | Rugi. `ZERO_PULLBACK` netral (+17.6R). |
| `InpTpMode = TP_SWING` | +2.9R | Jauh lebih buruk dari RR tetap. |
| Jendela konfluensi 1 / 5 bar | +8.0R / +12.0R | 3 bar paling seimbang. |
| Spread 2× ($0.38) | +16.9R | Strategi tidak rapuh terhadap spread — SL rata-rata $13.94 membuat spread hanya ~1.4% risiko. |

## Peringatan Risiko — baca ini

Jarak SL rata-rata di uji ini **$13.94** (median $12.55, maksimum $42.76). Dengan XAUUSD
0.01 lot = **$1 per $1 gerak harga**, artinya:

- risiko per trade dengan lot minimum ≈ **$12–14**, dan sesekali sampai $42;
- max drawdown uji **$84.39** dengan lot 0.01.

Di modal $100 itu berarti 14% risiko per trade dan drawdown 84% — akun habis sebelum
edge-nya sempat bekerja. Modal realistis untuk lot 0.01 di setelan ini adalah
**$700–1000** (risiko ~1.5–2% per trade), atau pakai **akun cent**. Kalau tetap ingin
modal kecil, set `InpMaxRiskPct` (mis. 3) supaya EA memblok setup yang risikonya
terlalu besar — konsekuensinya sebagian sinyal dilewati.

Win rate ~50% dengan RR 1.5: deret 5–6 loss berturut adalah normal.

## Journal / Diagnosa

- Init: `StochMacd EA v1.00 init: XAUUSD PERIOD_M15 | digits=3 point=0.001 | spread=190 pts | lot min=0.01 | nilai 1.00 lot per 1 unit harga=$100 | equity=100.00`, diikuti `Cek risiko: lot 0.01 dengan SL ... = $... = ...% equity`.
- Tiap order: `BUY lot 0.01 | entry=... sl=... tp=... | SL=13.940 (1.50 x ATR) RR=1.50 | risiko $13.94 = 13.9%`, plus `PERINGATAN risiko` bila > 3% equity.
- Akhir test: `RINGKASAN StochMacd EA: bar=... | sinyal BUY=... SELL=... | dieksekusi=...` dan baris `ditolak:` yang memecah alasan (sesi / cooldown / posisi penuh / spread / risiko / SL / tren / RR / order gagal).

## Batasan yang Jujur

- **Data uji hanya ~70 hari** (Yahoo GC=F, futures COMEX — bukan tick Exness, tanpa
  bid/ask nyata, jam dagang sedikit berbeda). 126 trade terlalu sedikit untuk menyebut ini edge.
- **Parameter dipilih setelah ±50 percobaan di data yang sama.** Split per kuartal dan
  sensitivitas yang halus (StochK 18–24 semuanya positif, spread 2× tetap positif)
  mengurangi risiko overfit, tapi tidak menghapusnya.
- **EURUSD M15 negatif** (−13.0R, PF 0.86, 165 trade) dengan preset yang sama. Setelan ini
  spesifik emas; simbol lain harus dikalibrasi ulang.
- **EA ini belum pernah di-compile.** MetaTrader 5 tidak terpasang di mesin tempat file ini
  dibuat, jadi verifikasi sintaks MQL5 dilakukan manual, bukan oleh MetaEditor.
  Compile dulu dengan F7 dan perbaiki bila ada error sebelum dipakai.

Langkah berikutnya sebelum menilai EA ini: backtest **≥ 1 tahun** di Strategy Tester Exness
dengan data broker sendiri, model *real ticks*.
