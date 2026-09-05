# MaTrend EA (v1.00)

EA MetaTrader 5 trend-following berbasis **dua Moving Average**, dengan tiga cara masuk
yang bisa dipilih (cross / pullback / breakout), SL & TP berbasis ATR.

Parameter default **bukan tebakan** — dipilih lewat pencarian di 2,5 tahun data H1 pada
5 simbol, dengan validasi ke data yang tidak dipakai saat memilih. Hasilnya:
**EURUSD H1, EMA 34/100 cross, SL 2×ATR, TP RR 5.**

## File

| File | Keterangan |
|------|-----------|
| `MaTrend_EA.mq5` | Source EA v1.00 (32 input) |
| `MaTrend_EURUSD_H1.set` | Preset default — untuk **modal kecil** |
| `MaTrend_XAUUSD_M5.set` | Preset emas untuk **modal kecil** (risiko ~$10/trade, modal ≥ $500) |
| `MaTrend_XAUUSD_H1.set` | Preset emas dengan edge terkuat, tapi **butuh modal ≥ $1150** |
| `fetch_data.py` | Unduh OHLC dari Yahoo Finance ke CSV |
| `sim_ma.py` | Port 1:1 logika EA untuk backtest cepat di CSV (bukan bagian EA) |
| `*_h1.csv` | Data uji: 5 simbol H1, Nov 2023 – Sep 2026 |
| `gold_m5.csv`, `gold_m15.csv`, `gold_h4.csv`, `gold_d1.csv` | Data emas lintas timeframe |

## Cara Pakai

1. Salin folder ke `MQL5/Experts/MaTrend_EA/`, buka MetaEditor (F4) → `MaTrend_EA.mq5` → **F7**.
2. Strategy Tester: symbol **EURUSD**, **H1**, load `MaTrend_EURUSD_H1.set`. Perhatikan tab **Journal**.
3. Saat init, EA mencetak baris `Cek modal:` yang langsung menjawab "cukup tidak modal saya" —
   berapa dolar dan berapa persen equity yang dipertaruhkan per trade dengan lot minimum.

Backtest cepat tanpa MT5:

```bash
python3 fetch_data.py EURUSD=X 1h 730d eurusd_h1.csv
python3 sim_ma.py eurusd_h1.csv        # parameter default EA
python3 sim_ma.py eurusd_h1.csv -v     # daftar trade
```

## "Modal kecil" itu soal lot, bukan soal indikator

Ini yang menentukan pilihan simbol di atas. Lot minimum 0.01 punya nilai yang sangat berbeda
antar simbol, dan jarak SL yang wajar mengikuti volatilitas simbol itu:

| Simbol (H1) | Nilai 0.01 lot | SL wajar | Risiko per trade | % dari modal $100 |
|---|---|---|---|---|
| **EURUSD** | $0.10 / pip | 25 pip | **$2.50** | **2.5%** — masuk akal |
| GBPUSD | $0.10 / pip | 33 pip | $3.32 | 3.3% — masih bisa |
| USDJPY | ~$0.07 / pip | 54 pip | $3.64 | 3.6% — masih bisa |
| **XAUUSD** | $1 / $1 gerak | $23–30 | **$23–30** | **23–30%** — tidak mungkin |

Strategi apa pun di XAUUSD dengan lot 0.01 mempertaruhkan seperempat modal $100 per trade.
Itu bukan masalah strategi, itu aritmetika ukuran kontrak. Kalau mau tetap emas: pakai
**akun cent** (0.01 lot cent = 1/100 risiko di atas) atau modal ≥ $1500.

## Logika

| Bagian | Implementasi |
|--------|--------------|
| **Arah tren** | `InpMaFast` vs `InpMaSlow` (jenis MA bebas: `InpMaType`). Fast di atas slow = uptrend. |
| **Filter opsional** | MA panjang `InpMaFilter` (harga harus di sisi yang benar) dan kemiringan MA lambat `InpSlopeBars`. Keduanya default **off** — di uji ini keduanya menurunkan hasil. |
| **ENTRY_CROSS** (default) | Bar terakhir yang closed adalah bar pertama MA cepat memotong MA lambat. |
| **ENTRY_PULLBACK** | Harga menyentuh MA cepat dalam `InpPullbackBars` bar terakhir, lalu bar ditutup kembali searah tren. Syarat "fresh" (close bar sebelumnya masih di seberang MA, atau bar ini sendiri yang menyentuh) membuatnya satu sinyal per koreksi, bukan berulang. |
| **ENTRY_BREAKOUT** | Close menembus high/low `InpBreakoutBars` bar sebelumnya, searah tren. |
| **SL** | `InpSlAtr` × ATR dari harga entry, dijepit ke `SYMBOL_TRADE_STOPS_LEVEL`. |
| **TP** | `InpRR` × jarak SL. Default RR 5 — sistem ini hidup dari sedikit trade besar. |
| **Manajemen** | Break-even, trailing ATR, batas umur posisi, tutup saat sinyal berlawanan — **semua default off**; tidak ada yang memperbaiki hasil di uji ini. |
| **Spread** | SL/TP SELL digeser +spread (SELL ditutup di Ask, chart pakai Bid). Filter `InpMaxSpreadRiskPct` menolak setup bila spread > 8% jarak SL. |

## Bagaimana parameter ini dipilih

Prosedurnya sengaja dibuat supaya tidak menipu diri sendiri:

1. **Data**: H1 dari Yahoo Finance, 5 simbol — EURUSD, GBPUSD, AUDUSD, USDJPY, GC=F (emas).
   Nov 2023 – Sep 2026 (≈17.000 bar per pasangan FX, 13.700 bar emas).
2. **Pencarian kasar** (90 konfigurasi) hanya pada **60% data pertama**: cara masuk ×
   pasangan MA × RR × filter.
3. **Pendalaman** (576 konfigurasi) di area terbaik, tetap hanya di 60% data pertama.
4. **Validasi** 6 kandidat terbaik ke **40% data terakhir yang belum pernah dilihat.**
5. **Peta konsistensi**: 5 blok waktu × 5 simbol = 25 sel, dilihat berapa sel yang positif.

### Yang gagal, dan ini penting

Langkah 2–3 memilih konfigurasi *breakout* dengan hasil train yang mengesankan
(+111R, positif di kelima simbol). Di data test semuanya ambruk:

| Konfigurasi terbaik menurut train | Train | Test 40% | Simbol positif di test |
|---|---|---|---|
| breakout f10/50 bb30 RR5 | +111.0R | **−7.7R** | 1/5 |
| breakout f20/100 bb20 RR3 | +109.6R | +4.1R | 1/5 |
| breakout f10/50 bb20 RR3 | +101.0R | −3.0R | 2/5 |
| breakout f10/50 bb10 RR5 | +91.4R | **−47.1R** | 1/5 |

Hasil train itu sebagian besar adalah tren yen 2024–2025, bukan edge. Kalau saya berhenti
di langkah 3 dan menyerahkan angka +111R, itu menyesatkan.

### Yang bertahan

`ENTRY_CROSS`, EMA 34/100, RR 5, SL 2×ATR, tanpa filter — **19 dari 25 sel positif**,
dan positif di kelima simbol. Uji train→test yang menjatuhkan kandidat lain:

| Simbol | Train (60%) | Test (40%) |
|---|---|---|
| **EURUSD** | +40.8R | **+23.2R** |
| GBPUSD | +27.8R | +4.4R |
| AUDUSD | −5.6R | +2.8R |
| USDJPY | +38.9R | −13.8R |
| Emas | −12.1R | +12.9R |

EURUSD adalah satu-satunya yang positif di **kedua** bagian sekaligus, dan juga satu-satunya
yang positif di **semua** uji sensitivitas — itulah kenapa ia jadi preset default.

## Hasil: EURUSD H1 (preset default)

Nov 2023 – Sep 2026, lot 0.01, spread 1.2 pip dibebankan sekali per trade,
SL diperiksa lebih dulu bila SL dan TP kena di bar yang sama (asumsi pesimis).

| Metrik | Nilai |
|---|---|
| Trade | 133 (≈48 per tahun) |
| Win rate | 26.3% |
| Hasil | **+70.7R** |
| Profit factor | 1.72 |
| Max drawdown | 10.3R |
| **Modal $100, lot 0.01** | **→ $280.18, max drawdown 9.8%** |
| Risiko per trade | $2.50 (2.5% dari $100) |
| Deret loss terpanjang | 8 |
| Lama trade | median 23 bar, maksimum 580 bar |

Per tahun: **2024 +32.1R** (49 trade) · **2025 +10.8R** (42 trade) · **2026 +19.0R** (39 trade).

### Sensitivitas (total R kelima simbol)

Angkanya tidak bergantung pada satu titik parameter yang sempit:

| Perubahan | Total | Perubahan | Total |
|---|---|---|---|
| default | +139.8R | MA cepat 21 / 50 | +109.2R / +67.1R |
| MA lambat 80 / 150 | +96.3R / +15.6R | RR 3 / 4 / 7 | +60.9R / +68.4R / +66.6R |
| SL 1.5 / 2.5 × ATR | +66.7R / +101.8R | SMA (bukan EMA) | +47.9R |
| pakai filter MA200 | +114.9R | trailing 2 ATR | +66.1R |
| break-even 1R | +89.4R | **spread 2×** | **+104.9R** |

EURUSD sendiri **positif di setiap baris** tabel ini. Spread 2× hampir tidak menggigit karena
SL 25 pip membuat spread hanya ~1% dari risiko.

## XAUUSD: bagaimana hasilnya?

Edge di emas **lebih kuat** daripada EURUSD, tapi pertanyaannya bukan itu — pertanyaannya
apakah modalmu sanggup menahan jarak SL-nya. Berikut hasil kedua cara masuk di semua
timeframe emas, lengkap dengan simulasi akun $100 yang **berhenti saat equity habis**:

### `ENTRY_BREAKOUT` EMA 20/100, breakout 20 bar, SL 1.5×ATR, RR 5

| TF | Rentang | Trade | Total | PF | Risiko/trade | Modal $100 | Modal $2000 |
|---|---|---|---|---|---|---|---|
| M5 | 60 hari | 285 | −0.8R | 1.00 | $8.32 | **habis di trade ke-81** | $1880 (DD 23%) |
| M15 | 70 hari | 97 | +10.3R | 1.13 | $14.00 | **habis di trade ke-19** | $2136 (DD 17%) |
| **H1** | **2,4 tahun** | **239** | **+102.1R** | **1.56** | **$22.92** | $2229 (DD **71%**) | **$4129 (DD 16%)** |
| H4 | 2,4 tahun | 77 | +36.9R | 1.64 | $43.35 | **habis di trade ke-6** | $3697 (DD 20%) |
| D1 | 5 tahun | 36 | +42.0R | 2.82 | $57.76 | $1730 (DD 48%) | $3630 (DD 15%) |

### `ENTRY_CROSS` EMA 34/100, SL 2×ATR, RR 5 (setelan yang sama dengan EURUSD)

| TF | Rentang | Trade | Total | PF | Risiko/trade | Modal $100 | Modal $2000 |
|---|---|---|---|---|---|---|---|
| **M5** | **60 hari** | **99** | **+62.0R** | **1.86** | **$10.19** | **$782 (DD 21%)** | $2682 (DD 5%) |
| M15 | 70 hari | 27 | +8.7R | 1.41 | $17.67 | **habis di trade ke-20** | $2165 (DD 11%) |
| H1 | 2,4 tahun | 91 | +4.8R | 1.06 | $30.45 | **habis di trade ke-18** | $2660 (DD 42%) |
| H4 | 2,4 tahun | 25 | +5.0R | 1.25 | $50.63 | **habis di trade ke-4** | $2272 (DD 14%) |
| D1 | 5 tahun | 5 | +7.0R | 3.32 | $55.86 | $286 (DD 41%) | $2186 (DD 8%) |

Perhatikan pola pentingnya: **cara masuk yang menang berbeda per timeframe.** Di H1 ke atas
yang jalan adalah *breakout*; di M5 justru *cross*, sementara breakout di M5 hasilnya nol
(+0.4R) dan pullback malah rugi (−29.5R). Jadi jangan pindahkan preset H1 ke M5 begitu saja.

### Pilihan untuk modal kecil di emas: M5 + `ENTRY_CROSS`

Ini satu-satunya kombinasi emas yang lolos semua saringan sekaligus:

| Metrik | Nilai |
|---|---|
| Trade | 99 dalam 60 hari (≈1,7 per hari) |
| Win rate · Total · PF | 27.3% · **+62.0R** · 1.86 |
| Train 60% / Test 40% | **+39.4R / +24.6R** (keduanya positif) |
| Per kuartal | +26.5R · +15.9R · +9.0R · +3.8R (**keempatnya positif**) |
| Risiko per trade | **$10.19** (10% dari $100, 2% dari $500) |
| **Modal $100, lot 0.01** | **→ $782, max drawdown 21%** |
| Deret loss terpanjang | 8 |
| Lama trade | median **2 jam**, p90 14 jam; hanya 2% melewati 24 jam → **swap hampir tidak berpengaruh** |

Ketahanan parameternya (semua tetap positif di keempat kuartal): MA 21/100 +41.5R ·
RR 4 +48.0R · RR 7 +100.4R · SL 1.5×ATR +68.1R · SL 3×ATR +70.0R · ATR 20 +69.7R ·
filter MA200 aktif +48.1R. **Spread 3× ($0.57) hampir tidak menggigit: +65.8R** — karena
SL $10 membuat spread hanya ~2% dari risiko. Yang merusaknya: trailing (+7.1R) dan
break-even 1R (+14.7R) — biarkan keduanya off, sama seperti di EURUSD.

### Rentang waktu tiap angka — jangan disandingkan mentah-mentah

| Preset | Rentang data | Lama | Trade | Trade/bulan | Hasil |
|---|---|---|---|---|---|
| EURUSD H1 | 20 Nov 2023 – 4 Sep 2026 | **33,5 bulan** | 133 | 4,0 | +70,7R (**+2,1R/bulan**) |
| XAUUSD H1 | 14 Apr 2024 – 4 Sep 2026 | **28,6 bulan** | 239 | 8,4 | +102,1R (**+3,6R/bulan**) |
| XAUUSD D1 | 7 Sep 2021 – 4 Sep 2026 | **59,9 bulan** | 36 | 0,6 | +42,0R (+0,7R/bulan) |
| XAUUSD M5 | 26 Jun – 4 Sep 2026 | **hanya 2,3 bulan** | 99 | 43,1 | +62,0R (+27,0R/bulan) |

Jadi "$100 → $782" di emas M5 terjadi dalam **2,3 bulan**, sedangkan "$100 → $280" di
EURUSD butuh **2,8 tahun**. Keduanya tidak sebanding.

**Dan +27R/bulan itu hampir pasti terlalu tinggi.** Uji diagnostiknya:

- Di jendela waktu yang sama (26 Jun – 4 Sep 2026), preset emas H1 hanya mencetak +11,0R
  (+4,8R/bulan) dan M15 +10,3R. Jadi jendela itu memang agak bersahabat, tapi tidak luar biasa —
  M5 benar-benar unggul di situ.
- Tapi: **jendela 70 hari terbaik yang pernah dicapai preset emas H1 dalam 2,4 tahun adalah
  +24,9R.** M5 mengklaim +62,0R dalam 70 hari — 2,5× lebih baik dari rekor terbaik versi H1.
- Dan M5 punya **tepat satu** jendela 70 hari dalam sejarahnya, dan jendela itu menang.
  Tidak ada bukti sama sekali tentang bagaimana bentuk periode buruknya.
- 82% profit M5 datang dari Juli + Agustus 2026 saja (+$381 dan +$247 dari total +$682).

Sebagai pembanding, distribusi jendela 70 hari yang **punya sejarah panjang**:

| Preset | Jendela | Terburuk | Median | Terbaik | Jendela rugi |
|---|---|---|---|---|---|
| XAUUSD H1 | 114 | −9,1R | +7,0R | +24,9R | 20 (**18%**) |
| EURUSD H1 | 135 | −7,3R | +4,5R | +17,8R | 37 (**27%**) |

Artinya, bahkan pada preset dengan sejarah terpanjang, **satu dari empat periode 2 bulan
adalah periode rugi.** Itu angka yang perlu kamu siapkan mentalnya, bukan +27R/bulan.

### Berapa lama sampai tahu EA-nya benar jalan?

| Preset | Trade/bulan | $/bulan (lot 0.01) | Modal minimum | 100 trade tercapai dalam |
|---|---|---|---|---|
| EURUSD H1 | 4,0 | $5,38 | $125 | **25 bulan** |
| XAUUSD H1 | 8,4 | $74,44 | $1146 | **12 bulan** |
| XAUUSD M5 | 43,1 | $296,50 | $509 | **2,3 bulan** |

Di sinilah keunggulan nyata M5: bukan pada besarnya profit, tapi pada **kecepatan
memverifikasi**. Dengan 43 trade/bulan kamu bisa mengumpulkan 50 trade dalam ~5 minggu
demo. EURUSD H1 butuh setahun forward test untuk sampel setara — kesabaran yang jarang
dimiliki orang, dan itu risiko tersendiri.

### Ringkasan modal minimum di emas (lot 0.01, risiko ≤ 2%)

| TF | Cara masuk | SL rata-rata | Modal minimum |
|---|---|---|---|
| M5 | cross | $10.19 | **$509** |
| M15 | breakout | $14.00 | $700 |
| H1 | breakout | $22.92 | $1146 |
| H4 | breakout | $43.35 | $2167 |
| D1 | breakout | $57.76 | $2888 |

Dengan **akun cent**, semua baris di atas dibagi 100 — emas H1 (edge terkuat) jadi butuh
setara $11,5 saja. Kalau kamu punya akses akun cent Exness, itu jalan terbaik untuk
memakai preset H1.

## Peringatan Risiko

- **Win rate 23–27%.** Tiga dari empat trade rugi. Deret 8 loss beruntun (14 di emas H1) sudah
  terjadi di data uji dan akan terjadi lagi. Sistem ini hidup dari sedikit trade RR 5.
- **Hanya ~48 trade per tahun** di EURUSD H1. Butuh kesabaran; menilai dari 10 trade tidak berarti apa-apa.
- **Di EURUSD H1 trade bisa terbuka sangat lama** (maksimum 580 bar ≈ 3,5 minggu). Perhitungkan
  biaya swap — simulasi ini **tidak** menghitung swap, dan itu bisa memakan sebagian hasil pada
  posisi panjang. Preset emas M5 jauh lebih aman soal ini: median 2 jam, hanya 2% trade menginap.
- Naikkan lot hanya lewat `InpLotMode = LOT_RISK_PERCENT`, dan pasang `InpMaxRiskPct` sebagai rem.

## Batasan yang Jujur

- **Data Yahoo Finance adalah proksi**: FX spot tanpa bid/ask broker, emas memakai futures COMEX.
  Spread dimodelkan sebagai biaya tetap, **swap dan komisi tidak dihitung**.
- **133 trade** di EURUSD tetap sampel kecil untuk menyimpulkan edge, walaupun sudah 2,8 tahun.
- **Preset emas M5 hanya diuji 60 hari / 99 trade** — batas maksimal data 5 menit dari Yahoo.
  Sudah lolos train/test dan positif di 4 kuartal, tapi 60 hari tidak bisa menangkap pergantian
  rezim pasar. Hasil per kuartalnya juga menurun (+26.5R → +3.8R); itu bisa berarti peluruhan
  edge, bisa juga cuma derau. Uji ulang di tester Exness dengan data M5 setahun sebelum percaya.
- Prosedur pemilihan sudah dijaga (train/test + peta konsistensi), tapi seluruh proses tetap
  menyentuh data yang sama berkali-kali. Anggap ini hipotesis yang layak diuji, bukan kesimpulan.
- **EA ini belum pernah di-compile.** MetaTrader 5 tidak terpasang di mesin tempat file ini dibuat,
  jadi sintaks MQL5 diperiksa manual, bukan oleh MetaEditor. Compile dulu dengan F7 dan perbaiki
  bila ada error sebelum dipakai.

Langkah berikutnya: backtest EURUSD H1 ≥ 3 tahun di Strategy Tester dengan data broker sendiri
(model *real ticks*, swap aktif), lalu forward test di demo minimal 50 trade.
