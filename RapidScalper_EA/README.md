# RapidScalper EA (MT5)

EA scalping cepat untuk XAUUSD/GOLD M1, dibuat berdasarkan screenshot yang
menunjukkan **panah buy/sell di hampir setiap candle M1** (masuk-keluar sangat
sering) ditambah pending **BUY STOP 0.13 / SELL STOP 0.13** dengan SL yang
tetap mengurung harga.

EA ini menggabungkan dua mesin:

1. **Scalper per candle** — setiap candle M1 baru, buka satu posisi market
   mengikuti arah candle yang baru ditutup (candle hijau → BUY, candle merah →
   SELL). Keluar cepat lewat TP/SL kecil, atau dipaksa tutup setelah N candle.
   Inilah yang menghasilkan panah di hampir setiap candle seperti di screenshot.
2. **Straddle breakout (opsional)** — sepasang BUY STOP + SELL STOP dengan
   SL/TP tetap mengurung harga, digeser ulang setiap candle, dan OCO (pending
   lawan dihapus saat salah satu tereksekusi). Menangkap lonjakan harga yang
   terlalu cepat untuk scalper.

## Parameter

| Parameter | Default | Keterangan |
|---|---|---|
| `InpMagic` | 20260730 | Magic number (pembeda order milik EA ini) |
| `InpLot` | 0.01 | Lot per order (default minimal; di screenshot 0.13) |
| `InpMaxSpreadPts` | 60 | Spread maksimal (points); 0 = abaikan |
| **Scalping** | | |
| `InpFollowCandle` | true | true = ikuti arah candle sebelumnya; false = lawan arah (fade) |
| `InpMaxOpenScalps` | 1 | Maksimal posisi scalp terbuka bersamaan |
| `InpTPPts` | 50 | TP scalp (points; GOLD: 50 = $0.50) |
| `InpSLPts` | 100 | SL scalp (points); 0 = tanpa SL (tidak disarankan) |
| `InpCloseAfterBars` | 3 | Paksa tutup posisi scalp setelah N candle; 0 = nonaktif |
| **Straddle** | | |
| `InpUseStraddle` | true | Aktifkan straddle breakout |
| `InpStraddleDistPts` | 150 | Jarak BUY/SELL STOP dari harga (points) |
| `InpStraddleSLPts` | 300 | SL order straddle (points) |
| `InpStraddleTPPts` | 450 | TP order straddle (points); 0 = tanpa TP |
| **Waktu** | | |
| `InpStartHour` / `InpEndHour` | 0 / 0 | Filter jam server; sama = trading 24 jam |

> **Points vs harga di GOLD:** 1 point = $0.01, jadi `InpTPPts = 50` berarti
> target $0.50 dari harga entry (= $6.50 profit dengan lot 0.13).

## Alur Kerja per Candle M1

1. Candle baru terbentuk → EA cek posisi scalp yang umurnya sudah ≥
   `InpCloseAfterBars` candle → ditutup paksa.
2. Kalau jumlah posisi scalp < `InpMaxOpenScalps`, spread normal, dan jam
   masuk sesi → buka scalp baru mengikuti arah candle yang baru ditutup.
3. Kalau straddle aktif dan tidak ada posisi hasil straddle yang masih
   terbuka → pending lama dihapus dan sepasang stop order baru dipasang
   mengurung harga terkini.
4. Di antara candle: kalau salah satu stop order tereksekusi, pending lawan
   langsung dihapus (OCO). Semua exit posisi (TP/SL) dieksekusi server broker,
   jadi tetap aman walau terminal sempat mati.

## Cara Menjalankan (Live/Demo)

EA **tidak bisa dijalankan di MT5 Android/iPhone** — harus MT5 desktop atau
VPS. Posisi yang dibuka EA tetap terlihat di HP.

1. Buka MT5 desktop → tekan **F4** (MetaEditor) → klik kanan folder
   **Experts → Open Folder** → salin `RapidScalper_EA.mq5` ke situ.
2. Buka file di MetaEditor → tekan **F7**. Pastikan `0 errors, 0 warnings`.
3. Di terminal MT5: **Ctrl+N** (Navigator) → seret **RapidScalper_EA** ke
   chart **XAUUSD M1**.
4. Centang **Allow Algo Trading** di dialog → OK, dan pastikan tombol
   **Algo Trading** di toolbar aktif.
5. Status EA (jumlah posisi, floating P/L) tampil di pojok kiri atas chart.

Compile lewat Terminal macOS (MT5 versi Mac/Wine):

```bash
WINEPREFIX="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5" \
"/Applications/MetaTrader 5.app/Contents/SharedSupport/wine/bin/wine" \
  "C:\\mt5\\MetaEditor64.exe" \
  /compile:"C:\\mt5\\MQL5\\Experts\\RapidScalper_EA.mq5" \
  /include:"C:\\mt5\\MQL5" /log
```

## Cara Backtest (Strategy Tester)

1. Tekan **Ctrl+R** di MT5 desktop (View → Strategy Tester).
2. Pengaturan:
   - **Expert:** `RapidScalper_EA`
   - **Symbol:** `XAUUSD` (atau `XAUUSD+`/`GOLD` sesuai broker)
   - **Period:** `M1`
   - **Date:** custom, mis. 2–4 minggu terakhir (M1 sangat banyak datanya,
     periode pendek dulu)
   - **Modelling:** **`Every tick based on real ticks`** — WAJIB untuk EA
     se-frequent ini; mode OHLC akan memberi hasil yang menyesatkan.
   - **Deposit & leverage:** samakan dengan akun asli.
3. Tab **Inputs**: atur lot, TP/SL, jam sesi, atau matikan straddle
   (`InpUseStraddle = false`) untuk menguji scalper-nya saja.
4. Klik **Start**, tunggu unduhan tick selesai. Hasil di tab
   **Backtest**/**Graph**; centang **Visual mode** untuk melihat entry per
   candle secara langsung.
5. Optimasi: tab Settings → Optimization `Fast (genetic)`, centang parameter
   di tab Inputs (mis. `InpTPPts` 30–100 step 10, `InpSLPts` 60–200 step 20,
   `InpCloseAfterBars` 1–10). Nilai terbaik dipilih dari *Profit Factor* /
   *Recovery Factor*, bukan total profit semata.

## Catatan Risiko (PENTING untuk EA se-aktif ini)

- **Biaya transaksi adalah musuh utama.** Trading tiap candle M1 berarti
  puluhan–ratusan trade per hari; spread + komisi bisa memakan seluruh profit.
  TP 50 points di GOLD hanya ±2× spread normal — uji dulu di akun demo dengan
  spread broker sesungguhnya.
- Hasil backtest mode selain *real ticks* hampir pasti terlalu optimis.
- Sinyal "ikuti candle sebelumnya" bersifat momentum murni; di pasar sideways
  akan sering kena SL. Gunakan filter jam untuk membatasi ke sesi yang
  trending (mis. overlap London–New York, 19:00–23:00 waktu server umumnya).
- Lot 0.13 di GOLD: SL 100 points = risiko ±$13 per trade scalp; straddle SL
  300 points = ±$39. Sesuaikan dengan ukuran akun.
- Uji minimal 1–2 minggu di **akun demo** sebelum akun riil.
