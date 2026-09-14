# SMC Structure EA (v1.10)

EA MetaTrader 5 berbasis **Smart Money Concept**: `$ Liquidity Sweep -> MSS -> POI (FVG / OB / IFVG) -> Entry`,
SL di balik sweep/OB (basis ATR), TP ke liquidity berikutnya. Dikalibrasi untuk **Exness Pro XAUUSD M5** (3 digit, spread 180–200 pts).

## File

| File | Keterangan |
|------|-----------|
| `SMC_Structure_EA.mq5` | Source EA v1.10 |
| `SMC_Structure_EA.ex5` | Hasil compile |
| `SMC_Structure_backtest.set` | Preset input Exness Pro XAUUSD M5 |
| `sim_smc.py`, `sim_smc2.py` | Port Python 1:1 logika deteksi untuk uji cepat di CSV (bukan bagian EA) |

## Cara Pakai

1. MetaEditor (F4) → buka `Experts/SMC_Structure_EA/SMC_Structure_EA.mq5` → **F7**.
2. Strategy Tester: symbol **XAUUSD**, **M5**, model *Every tick based on real ticks* atau *1 minute OHLC*, load `.set`. Perhatikan tab **Journal**.
3. Uji demo sebelum real. **M15 dan forex mayor belum terbukti profit** dengan aturan ini (lihat bawah).

## Apa yang berubah di v1.10 (dari v1.01) dan kenapa

Hasil backtest v1.01 kamu: $100 → $57. Simulasi Python mereproduksi ini (**−$32 / 0.01 lot dalam 60 hari M5**). Penyebab, urut dari yang terbesar:

| Penyebab | Bukti simulasi (XAUUSD M5, 60 hari) | Perbaikan v1.10 |
|---|---|---|
| **Break-even 1R** mengubah pemenang jadi 0: gold selalu "napas" balik ke entry setelah +1R | Tanpa BE: 43 TP / 90 SL, **+14.3R**. Dengan BE 1R: 30 TP / 37 BE / 70 SL, **−1.1R** | `InpBreakEvenRR = 0` (OFF). BE di 2R pun masih mengurangi hasil |
| **Jarak berbasis points tidak berarti di 3 digit**: buffer SL 20 pts = $0.02 → kena noise | SL min 1 ATR + buffer 0.3 ATR: WR 32% → 36%, +14.3R → +22.7R | Semua jarak jadi **x ATR**: `InpSlBufferAtr`, `InpSlMinAtr`, `InpMinFvgAtr`, `InpTpBufferAtr`, `InpSweepMinAtr`, `InpMssMinBreakAtr`, `InpBeOffsetAtr` |
| **"MSS" mikro**: break swing high 3 bar yang cuma pullback kecil | Leg sweep→MSS ≥ 2 ATR: WR → 40%, **+28.6R** (gabung dengan SL ATR) | `InpMinLegAtr = 2.0` |
| **Spread $0.19 × 133 trade ≈ $25–33** — sepertiga modal $100 | Setup dengan SL kecil paling terpukul | `InpMaxSpreadRiskPct = 8` (spread ≤ 8% jarak SL), `InpMaxSpreadPts = 350` hanya blok lonjakan |
| **SELL ditutup di Ask, chart = Bid** → SL SELL efektif lebih dekat sebesar spread | — | `InpSpreadCompensate = true`: SL & TP SELL digeser +spread |
| **Lot 0.01 gold di modal $100 = risiko 6–12% per trade** (0.01 lot = $1 per $1 gerak, SL median $6–8) | Deret 5 loss normal = −30…−40% | Journal mencetak risiko $ dan % tiap order; `InpMaxRiskPct` bisa memblok trade yang terlalu besar |

Filter yang **diuji dan ditolak** (memperburuk / tidak menolong di M5): `InpSwingBars = 5` (−17.5R), displacement candle MSS ≥ 1 ATR (+1.4R), EMA200 (+3.5R), sesi London/NY (+5.7R), TP RR tetap (+1.7R). EMA & sesi tetap tersedia sebagai opsi (default off).

**Peringatan jujur:** data uji hanya 60 hari (Yahoo GC=F, bukan tick Exness). Di **M15 semua varian negatif** (−2…−10R). Angka ini cukup untuk menjelaskan *kenapa* v1.01 rugi, belum bukti edge jangka panjang — lakukan backtest ≥ 1 tahun di tester Exness sebelum menilai.

## Pemetaan Konsep SMC -> Logika EA

| Istilah | Implementasi |
|---------|--------------|
| **$ Liquidity / IDM** | Swing high/low fractal `InpSwingBars`. Syarat #1: candle menusuk swing terakhir. Tanpa sweep, break struktur diabaikan. |
| **MSS / BOS** | Candle closed terakhir = candle *pertama* yang close menembus swing berlawanan terakhir setelah sweep; leg sweep→MSS ≥ `InpMinLegAtr` ATR. |
| **OB** | Candle berlawanan terakhir di/sebelum ujung sweep; valid jika liquidity di baliknya sudah diambil (`InpObRequireSweep`). |
| **FVG** | Gap 3 candle di leg impulsif sweep→MSS, ukuran ≥ `InpMinFvgAtr` ATR. `InpFvgPick`: terdalam / terdekat harga. |
| **IFVG** | FVG berlawanan di leg sebelumnya yang ditembus close MSS; diambil yang terdekat harga. |
| **Entry** | `InpZoneMode` AUTO (FVG → IFVG → OB). Limit di `InpZoneEntryPct` zona; market jika harga sudah di zona. |
| **SL** | Di balik ujung sweep / OB + `InpSlBufferAtr`; setup dilewati bila jarak SL < `InpSlMinAtr` ATR. |
| **TP** | Swing lawan berikutnya di atas harga, RR ∈ [`InpMinRR`, `InpMaxRR`]; fallback `InpRR`. |

## Journal / Diagnosa

- Init: `SMC EA v1.10 init: XAUUSD PERIOD_M5 | digits=3 point=0.001 | spread=190 pts ... | lot min=0.01 | nilai 1.00 lot per 1 unit harga=$100 | equity=$100` + `Cek risiko: lot 0.01 dengan SL 5.000 = $5.00 = 5.0% equity`.
- Tiap order: `BUY LIMIT #... lot 0.01 (risiko $7.80 = 7.8%)` dan `PERINGATAN risiko` jika > 3% equity.
- Akhir test: `RINGKASAN SMC EA v1.10: bar=... | MSS valid=... | setup dieksekusi=... | ditolak: POI=.. leg<min=.. SL<min=.. spread/risiko=..`.

## Pengelolaan Order

- Limit berlaku `InpEntryValidBars` candle; dihapus bila kadaluarsa, harga close melewati SL sebelum terisi, atau TP tercapai tanpa terisi. Setup baru menggantikan pending lama.
- Hanya menyentuh order/posisi ber-magic EA; limit diadopsi ulang setelah restart.
- Chart: garis `$`, `MSS`, kotak OB/FVG/IFVG (zona terpakai diisi warna), garis ENTRY/SL/TP. Prefix objek `SMC_`.

## Peringatan Risiko

Strategi ini menang ~35–40% dengan RR ~2–3: deret 6–8 loss berturut adalah normal. Dengan modal $100, lot minimum 0.01 gold sudah 6–12% risiko per trade — gunakan akun cent / modal lebih besar, atau `LOT_RISK_PERCENT` ≤ 1% pada modal yang memungkinkan lot < risiko itu.
