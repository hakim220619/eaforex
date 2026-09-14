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
| `MaTrend_XAUUSD_M5.set` | Preset emas untuk **akun standar/Pro modal $200–500** (EMA 34/100, SL 1.5×ATR, risiko ~$7.76/trade) |
| `MaTrend_XAUUSD_H1.set` | Preset emas dengan edge terkuat, tapi **butuh modal ≥ $1150** |
| `MaTrend_XAUUSD_H1.mq5` | **EA terpisah khusus XAUUSD H1** — strategi di atas sudah jadi default, plus trailing 2×ATR dan pengaman simbol/TF (lihat bagian bawah) |
| `MaTrend_XAUUSD_M15.set` | Preset emas **M15 MA cross** (SMA 5/50, SL 1.5×ATR, RR 5) — risiko ~$13/trade, modal ≥ $300; data uji hanya 11 minggu |
| `fetch_data.py` | Unduh OHLC dari Yahoo Finance ke CSV |
| `sim_ma.py` | Port 1:1 logika EA untuk backtest cepat di CSV (bukan bagian EA) |
| `*_h1.csv` | Data uji: 5 simbol H1, Nov 2023 – Sep 2026 |
| `gold_m5.csv`, `gold_m15.csv`, `gold_h4.csv`, `gold_d1.csv` | Data emas lintas timeframe (`gold_m5.csv` dan `gold_m15.csv` 26 Jun – 11 Sep 2026, 78 hari) |
| `eurusd_m15.csv` | EURUSD M15 22 Jun – 11 Sep 2026, pasar pembanding untuk uji M15 |

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

## EA khusus XAUUSD H1: `MaTrend_XAUUSD_H1.mq5`

Versi terpisah yang hanya membawa strategi emas H1, tanpa pilihan mode entry dan tanpa
harus load `.set`. Bedanya dengan EA generik + preset:

| | `MaTrend_EA` + `MaTrend_XAUUSD_H1.set` | `MaTrend_XAUUSD_H1.mq5` |
|---|---|---|
| Entry | pilihan cross / pullback / breakout | breakout saja (EMA 20/100, 20 bar) |
| Trailing | off | **2×ATR, mulai +1R, dievaluasi di close bar** |
| Pengaman | tidak ada | tolak init bila simbol bukan `XAU*` atau TF bukan H1 |
| Rem risiko | `InpMaxRiskPct` 0 (off) | **5%** — di akun $100 standar entry otomatis diblok |
| Manajemen posisi | tiap tick | sekali per bar, memakai close bar 1 (identik dengan `sim_ma.py`) |
| Magic | 20260906 | 20260913 |

**Jangan load `MaTrend_XAUUSD_H1.set` ke EA ini** — nama inputnya sama, jadi preset itu akan
mematikan trailing (`InpTrailAtr=0`) dan rem risiko. Default EA-nya sudah benar.

### Kenapa trailing dinyalakan di sini padahal di EURUSD dimatikan

Diuji ulang di `gold_h1.csv` dengan spread $0.19 (Exness Pro XAUUSD 3 digit, 180–200 pts):

| Emas H1 breakout | Trade | WR | Total | PF | maxDD | Train 60% | Test 40% | Kuartal + | Loss beruntun | Trade terpanjang |
|---|---|---|---|---|---|---|---|---|---|---|
| tanpa trailing (preset lama) | 239 | 23.8% | +102.1R | 1.56 | 15.1R | +45.4R | +55.7R | 9/10 | **14** | **863 bar (5 minggu)** |
| **trailing 2×ATR (default EA ini)** | 326 | 42.3% | **+109.8R** | **1.65** | **13.0R** | +45.4R | **+66.2R** | **10/10** | **9** | **134 bar (6 hari)** |
| trailing 1.5×ATR | 355 | — | — | — | — | +36.8R | +46.4R | 10/10 | 8 | 113 bar |
| trailing 3×ATR | 302 | — | — | — | — | +35.7R | +55.2R | 9/10 | 9 | 465 bar |

Selisih total R-nya kecil dan bisa saja derau. Yang membuat trailing layak dinyalakan di emas
adalah dua hal lain: deret loss turun dari 14 ke 9, dan tidak ada lagi posisi menginap 5 minggu —
swap XAUUSD jauh lebih mahal daripada EURUSD, dan simulasi ini tidak menghitung swap.
Di EURUSD trailing tetap merugikan (+66R vs +70R); jangan disamakan.

Sensitivitas lain di emas H1 (spread $0.19, tanpa trailing): EMA cepat 15 +106R · 30 +80R ·
EMA lambat 80 +110R · 150 +53R · breakout 15 bar +80R · 30 bar +104R · SL 1.0×ATR +107R (tapi 395
trade, DD 26R) · SL 2.0×ATR +53R · RR 3/4/7 +79R/+84R/+86R · spread $0.50 +100.7R. Tidak ada
titik parameter yang sendirian menopang hasilnya, tapi EMA lambat 150 dan SL 2×ATR jelas lebih buruk.

Per tahun (tanpa trailing): 2024 +7.6R (64 trade, mulai April) · 2025 +63.8R (110) · 2026 +30.7R (65).
Sebagian besar hasil datang dari tren emas 2025 — periode datar seperti Q2–Q3 2024 (−0.1R, +1.9R)
adalah bentuk normalnya, bukan pengecualian.

### Modal

SL rata-rata **$22.92 per 0.01 lot**. Simulasi akun, lot 0.01 tetap:

| Modal awal | Hasil | Max drawdown |
|---|---|---|
| $100 | $2229 | **71%** (dan `InpMaxRiskPct=5%` akan memblok semua entry) |
| $1200 | $3329 | 20% |

Untuk modal $100–200 pilihannya tetap dua: **akun cent** (SL jadi $0.23) atau tetap di EURUSD H1.

## MA cross di M15: `MaTrend_XAUUSD_M15.set`

Pertanyaannya: adakah persilangan MA yang *profitable* di M15? Jawaban jujurnya: **ada banyak
yang terlihat profitable, dan justru itu masalahnya.** Dari 342 kombinasi MA cross yang dicoba
di emas M15 (EMA/SMA × 5 MA cepat × 4 MA lambat × 3 SL × 3 RR), **170 positif di train dan test
sekaligus.** Jendela datanya (26 Jun – 11 Sep 2026) adalah emas naik +11% hampir tanpa koreksi —
di pasar seperti itu hampir semua sistem trend-following menang. Itu bukan bukti edge.

Preset default EURUSD (EMA 34/100) di emas M15 hanya +11.6R dengan train **−5.3R**. Jadi setelan
H1 tidak bisa dipindahkan begitu saja ke M15.

### Cara memilih supaya tidak menipu diri

Alih-alih mengambil puncak in-sample (SMA 8/50: +57R, PF 2.55 — tapi **−18R di EURUSD M15**),
setiap kandidat dinilai dengan **lima uji** dan skornya adalah **hasil terburuk** di antara kelimanya:

| Uji | Tujuan |
|---|---|
| Emas M15, 60% pertama | in-sample |
| Emas M15, 40% terakhir | out-of-sample waktu |
| **EURUSD M15** (59 hari) | pasar lain — menyaring "cuma menunggangi rally emas" |
| Emas H1, train 60% (2,4 tahun) | timeframe lain, sejarah panjang |
| Emas H1, test 40% | idem |

240 konfigurasi di wilayah MA cepat 5–13 / MA lambat 50–125; **53 lolos positif di kelima uji.**
Yang terpilih adalah yang kasus terburuknya paling tinggi:

| Konfigurasi | Emas M15 train | test | EURUSD M15 | Emas H1 train | test | Terburuk |
|---|---|---|---|---|---|---|
| **SMA 5/50 SL 1.5 RR 5** | +31.2R | +18.3R | +19.8R | +23.2R | +25.4R | **+18.3R** |
| SMA 6/50 SL 1.5 RR 4 | +33.3R | +16.2R | +29.0R | +39.1R | +16.9R | +16.2R |
| EMA 5/75 SL 2.0 RR 5 | +17.6R | +19.7R | +18.0R | +28.8R | +14.5R | +14.5R |
| EMA 8/100 SL 1.5 RR 5 | +21.8R | +31.7R | +14.3R | +31.2R | +19.8R | +14.3R |
| *SMA 8/50 SL 2.0 RR 5 (puncak in-sample)* | *+45.1R* | *+12.8R* | ***−18.3R*** | *+54.4R* | *+32.9R* | *−18.3R* |

Bahwa 4 baris teratas saling bertetangga (MA cepat 5–8, MA lambat 50–100, SL 1.5) lebih
meyakinkan daripada angka mana pun: ini sebuah wilayah, bukan satu titik yang kebetulan pas.

### Hasil preset: emas M15, SMA 5/50, SL 1.5×ATR, RR 5

26 Jun – 11 Sep 2026 (78 hari), spread $0.19, lot 0.01:

| Metrik | Nilai |
|---|---|
| Trade | 83 dalam 11 minggu (≈7,5 per minggu) |
| Win rate · Total · PF | 27.7% · **+49.5R** · 1.83 |
| Max drawdown | 6.1R |
| BUY / SELL | +23.7R (38) / +25.8R (45) — **seimbang**, bukan hanya ikut rally |
| Per minggu | +4.9 +12.8 +0.9 +2.9 +8.9 +2.8 −2.0 +7.9 +3.9 +1.9 +5.8 −1.3 → 10 dari 12 minggu positif |
| Risiko per trade | **$12.65** rata-rata, maksimum $24 |
| Deret loss terpanjang | 6 |
| Lama trade | median **3 jam**, p90 18 jam, hanya 6% melewati 23 jam → swap kecil |

| Modal awal, lot 0.01 | Hasil 11 minggu | Max drawdown |
|---|---|---|
| $100 | $750 | 23% |
| $300 | $950 | 15% |
| **$500** | **$1150** | **12%** |
| $1000 | $1650 | 7% |

Sensitivitas (semua tetap positif): MA cepat 3 → +25R · 8 → +53R · MA lambat 37 → +53R ·
62 → +34R · SL 1.0 → +42R · **SL 2.0 → +22R** · RR 4 → +61R · RR 7 → +56R · spread $0.60 → +48R ·
ATR 20 → +40R. Yang merusak: trailing 2 ATR (+24R), break-even 1R (+34R), filter MA200 (+20R) —
**biarkan semuanya off**, sama seperti preset lain.

### Yang harus dipahami sebelum memakainya

- **11 minggu, satu rezim pasar.** Tidak ada satu pun periode emas sideways atau turun panjang di
  data ini. Uji EURUSD M15 dan emas H1 2,4 tahun menutup sebagian lubang itu, tapi tidak semuanya.
- **Out-of-sample murni 8–11 Sep** (data yang diunduh setelah pencarian) hanya 7 trade, −0.1R — terlalu
  sedikit untuk berarti apa-apa, ke arah mana pun.
- 83 trade adalah sampel kecil. Di Exness demo ini terkumpul dalam ~10 minggu — itu waktu verifikasi
  yang wajar sebelum uang sungguhan.
- SMA 5 praktis adalah harga yang dihaluskan sedikit; sistem ini pada dasarnya "harga menembus SMA 50
  dengan konfirmasi". Ia akan sering masuk dan sering kena SL kecil. Itu normal dengan WR 28%.
- Modal $100 dengan lot 0.01 = risiko 12,6% per trade. Simulasinya selamat (DD 23%) tapi deret 6 loss =
  −$76. Modal $300–500 atau akun cent jauh lebih masuk akal.

### Modal $200: mana yang dipakai?

Simulasi akun $200, lot 0.01 tetap (kolom kiri) dan Monte Carlo 2000 kali acak urutan trade yang
sama (kolom kanan — ini yang menjawab "seberapa buruk bisa jadi", bukan hanya "berapa hasilnya"):

| Preset | Risiko/trade (% dari $200) | Urutan asli | maxDD Monte Carlo median / p90 / p99 | Peluang equity pernah < $100 |
|---|---|---|---|---|
| EURUSD H1 (2,8 tahun) | $2.50 (1.2%) | $380, DD 7% | 12% / 19% / 28% | **0%** |
| XAUUSD M5 cross (10 minggu) | $10.19 (5.1%), maks $27 | $882, DD 18% | 28% / 50% / 62% | 7% |
| XAUUSD M15 SMA 5/50 (11 minggu) | $12.65 (6.3%), maks $24 | $850, DD 18% | 32% / 54% / 65% | 13% |
| XAUUSD H1 breakout + trail (2,4 tahun) | $22 (11%), maks $174 | $2169, DD 51% | 53% / 76% / **103%** | **38%** |

Drawdown 18% di "urutan asli" itu satu jalur sejarah yang kebetulan ramah. Dengan trade yang persis sama
tapi urutan berbeda, median drawdown-nya 32% dan satu dari delapan skenario menyentuh $100. Emas H1 di
akun standar $200 jelas keluar: 38% skenario tergerus separuh, dan satu SL bisa $174.

**Akun cent mengubah semuanya**, karena lot bisa 0.01 cent = 1/100 lot standar, sehingga
`InpLotMode = LOT_RISK_PERCENT` benar-benar bisa menahan risiko di 2% ($4) per trade:

| Preset, akun cent, risiko 2% equity | $200 menjadi | maxDD asli | maxDD Monte Carlo median / p99 |
|---|---|---|---|
| XAUUSD M15 (11 minggu) | $481 | 13% | 20% / 35% |
| XAUUSD M5 (10 minggu) | $601 | 21% | — |
| **XAUUSD H1 + trail (2,4 tahun)** | **$1459** | **23%** | **23% / 40%** |

Hasil dolarnya lebih kecil dari lot 0.01 tetap, tapi drawdown terburuknya terpotong separuh dan
peluang habis mendekati nol. Itulah harga yang dibayar untuk bisa bertahan cukup lama sampai edge-nya
(kalau memang ada) sempat bekerja.

Rem `InpMaxRiskPct` **tidak** menolong di sini: 8–15% tidak melewati satu trade pun karena equity ikut
tumbuh, jadi rem itu hanya berguna bila akun sudah tergerus — yang justru saat ia paling dibutuhkan.

### Keputusan: tetap di Exness Pro (akun standar, lot minimum 0.01), modal $200

Tanpa akun cent, lot tidak bisa di bawah 0.01, jadi risiko per trade di emas adalah angka tetap dalam dolar.
Yang bisa dipilih hanya *preset mana* dan *SL berapa ATR*. Perbandingan di $200, lot 0.01, Monte Carlo 3000 acak:

| Pilihan | Risiko/trade | Total (PF) | maxDD MC median / p99 | P(equity < $100) | P(DD ≥ 50%) |
|---|---|---|---|---|---|
| EURUSD H1 (2,8 tahun, 133 trade) | $2.50 = 1.2% | +70.7R (1.72) | 12% / 26% | **0%** | **0%** |
| **XAUUSD M5 EMA 34/100, SL 1.5×ATR** | **$7.76 = 3.9%** (maks $20) | +63.4R (1.75) | 24% / 64% | **2.7%** | 3.8% |
| XAUUSD M5 EMA 34/100, SL 2.0×ATR (preset lama) | $10.30 = 5.1% (maks $27) | +63.2R (1.83) | 28% / 86% | 7.9% | 10.8% |
| XAUUSD M15 SMA 5/50, SL 1.5×ATR | $12.65 = 6.3% (maks $24) | +49.5R (1.83) | 32% / 98% | 11.6% | 16.9% |
| XAUUSD M15 SMA 5/50, SL 1.0×ATR | $8.47 = 4.2% | +42.2R (1.46) | 38% / 102% | 15.5% | 26.1% |
| XAUUSD H1 breakout | $22 = 11% (maks $174) | — | 53% / 103% | 38% | — |

Memperketat SL menolong di M5 (SL 1.5 tetap +63R, risiko turun 25%) tapi **tidak** di M15 (SL 1.0
menaikkan trade yang kena SL, PF jatuh ke 1.46, dan peluang tergerus justru naik). Jadi preset M5
diubah ke SL 1.5; preset M15 dibiarkan 1.5.

**Pilihan yang masuk akal di Pro $200 ada dua, dan keduanya punya harga:**

1. **EURUSD H1** — satu-satunya dengan sejarah panjang dan peluang habis nol. Harganya: lambat.
   Sekitar 4 trade per bulan, $5/bulan di lot 0.01, dan butuh 2 tahun untuk mengumpulkan 100 trade.
2. **XAUUSD M5 EMA 34/100 SL 1.5** — cepat (≈45 trade/bulan) dan risiko 3.9% masih bisa ditahan.
   Harganya: **edge-nya belum terbukti**, dan buktinya tipis di beberapa tempat sekaligus:
   - Minggu out-of-sample murni 8–11 Sep 2026 (data diunduh setelah semua pencarian): **−6.7R dari 8 trade**,
     1 menang 7 kalah. Delapan trade tidak membuktikan apa pun, tapi arahnya tidak menyenangkan.
   - **74% profit datang dari Juli 2026 saja** (+47R dari +63R). Agustus +19R, Juni +3R, September −6R.
   - **Parameter MA cepatnya rapuh**: EMA 21 → +11R, EMA 50 → +12R, EMA lambat 150 → −11R. Di EURUSD H1
     tetangga parameter semuanya positif; di emas M5 hanya 34/100 yang bekerja. Itu ciri khas kurva yang
     pas dengan satu periode, bukan edge yang luas.
   - Trailing 2 ATR (+8R) dan break-even 1R (+23R) menghancurkannya — biarkan off.

**Kalau memilih emas M5 di Pro $200**, perlakukan sebagai eksperimen dengan aturan berhenti yang ditulis
sebelum mulai: lot 0.01 tetap, **stop total kalau equity turun ke $140** (−30%, ≈ 8 SL berturut-turut,
angka deret loss terpanjang di data), dan jangan naikkan lot sebelum 100 trade demo/real menunjukkan
PF > 1.3. Kalau September–Oktober 2026 ternyata seperti minggu OOS-nya, aturan itu yang menyelamatkan modal.

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
- **Preset emas M5 (78 hari / 116 trade) dan M15 (78 hari / 83 trade) diuji sangat singkat** — batas data intraday Yahoo — dan minggu OOS pertama keduanya rugi.
  Sudah lolos train/test dan positif di 4 kuartal, tapi 60 hari tidak bisa menangkap pergantian
  rezim pasar. Hasil per kuartalnya juga menurun (+26.5R → +3.8R); itu bisa berarti peluruhan
  edge, bisa juga cuma derau. Uji ulang di tester Exness dengan data M5 setahun sebelum percaya.
- Prosedur pemilihan sudah dijaga (train/test + peta konsistensi), tapi seluruh proses tetap
  menyentuh data yang sama berkali-kali. Anggap ini hipotesis yang layak diuji, bukan kesimpulan.
- **Kedua EA belum pernah di-compile.** MetaTrader 5 tidak terpasang di mesin tempat file ini dibuat,
  jadi sintaks MQL5 diperiksa manual, bukan oleh MetaEditor. Compile dulu dengan F7 dan perbaiki
  bila ada error sebelum dipakai.

Langkah berikutnya: backtest EURUSD H1 ≥ 3 tahun di Strategy Tester dengan data broker sendiri
(model *real ticks*, swap aktif), lalu forward test di demo minimal 50 trade.
