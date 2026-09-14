# StraddleBreakout EA (MT5)

EA breakout dua arah untuk XAUUSD/GOLD, dibuat berdasarkan pola pada screenshot:
**BUY STOP 0.5** dipasang di atas harga dan **SELL STOP 0.5** di bawah harga,
masing-masing dengan **SL di sisi berlawanan** — harga "dikurung" dari dua sisi
dan EA mengikuti ke arah mana pun harga jebol (breakout).

## Cara Kerja

1. Di setiap awal candle (saat tidak ada posisi/pending), EA memasang sepasang
   pending order:
   - **BUY STOP** = Ask + `InpDistPts` points, SL di bawahnya sejauh `InpSLPts`
     (default tepat di level SELL STOP), TP opsional sejauh `InpTPPts`.
   - **SELL STOP** = Bid − `InpDistPts` points, SL & TP kebalikannya.
2. Selama belum ada yang tereksekusi, kedua pending **digeser mengikuti harga**
   setiap candle baru (recenter) — sama seperti di screenshot di mana kedua
   order selalu menempel di sekitar harga.
3. Saat harga jebol dan salah satu pending tereksekusi, pending lawan
   **langsung dihapus (OCO)**.
4. Posisi ditutup oleh SL/TP di sisi server (tetap aman walau terminal mati).
   Trailing stop opsional bisa diaktifkan lewat `InpTrailPts`.
5. Setelah posisi selesai, EA memasang straddle baru di candle berikutnya.

## Parameter

| Parameter | Default | Keterangan |
|---|---|---|
| `InpMagic` | 20260806 | Magic number (pembeda order milik EA ini) |
| `InpLot` | 0.01 | Lot per order (default minimal; di screenshot 0.5) |
| `InpMaxSpreadPts` | 60 | Spread maksimal saat pasang order (points); 0 = abaikan |
| `InpDistPts` | 80 | Jarak BUY/SELL STOP dari harga (points; di GOLD 100 pts = $1.00) |
| `InpSLPts` | 160 | Jarak SL dari harga pending; default 2× jarak order = SL tepat di level order lawan, persis seperti screenshot |
| `InpTPPts` | 240 | Jarak TP (points); 0 = tanpa TP (keluar hanya lewat SL/trailing) |
| `InpRecenter` | true | Geser ulang straddle mengikuti harga tiap candle baru |
| `InpRecenterMinPts` | 20 | Geser hanya jika perubahannya ≥ sekian points |
| `InpDeleteOpposite` | true | OCO: hapus pending lawan saat salah satu tereksekusi |
| `InpTrailPts` | 0 | Trailing stop posisi aktif (points); 0 = nonaktif |
| `InpTrailStepPts` | 20 | Langkah minimal pergeseran trailing |
| `InpStartHour` / `InpEndHour` | 0 / 0 | Filter jam server (mis. 15–20 untuk sesi news AS); sama = nonaktif |

> **Points vs harga di GOLD:** 1 point = $0.01. Jadi `InpDistPts = 80` berarti
> pending dipasang $0.80 dari harga — sesuai jarak yang terlihat di screenshot
> (~4272.9 vs ~4271.1 dengan harga di tengah).

## Cara Menjalankan (Live/Demo)

EA **tidak bisa dijalankan di MT5 Android/iPhone**. Harus lewat MT5 desktop
(Windows/Mac) atau VPS. Posisi yang dibuka EA tetap terlihat di HP.

1. Buka MT5 desktop → menu **File → Open Data Folder** (atau tekan F4 untuk
   MetaEditor lalu klik kanan folder **Experts → Open Folder**).
2. Salin `StraddleBreakout_EA.mq5` ke folder `MQL5/Experts/`.
3. Di MetaEditor, buka file tersebut lalu tekan **F7** (Compile). Pastikan
   hasilnya `0 errors, 0 warnings`.
4. Kembali ke terminal MT5, tekan **Ctrl+N** untuk membuka Navigator, seret
   **StraddleBreakout_EA** ke chart **XAUUSD M1**.
5. Di dialog yang muncul, tab *Common*: centang **Allow Algo Trading** → OK.
6. Pastikan tombol **Algo Trading** di toolbar atas berwarna hijau/aktif.
7. EA akan menampilkan statusnya di pojok kiri atas chart.

Catatan untuk Mac: MT5 versi Mac (wrapper Wine) sudah terpasang di
`/Applications/MetaTrader 5.app`; semua langkah di atas sama. Compile juga bisa
dilakukan dari Terminal macOS:

```bash
WINEPREFIX="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5" \
"/Applications/MetaTrader 5.app/Contents/SharedSupport/wine/bin/wine" \
  "C:\\mt5\\MetaEditor64.exe" \
  /compile:"C:\\mt5\\MQL5\\Experts\\StraddleBreakout_EA.mq5" \
  /include:"C:\\mt5\\MQL5" /log
```

(`C:\mt5` adalah symlink tanpa spasi ke `Program Files/MetaTrader 5` di dalam
prefix Wine — path berspasi terpotong saat dilempar lewat Wine.)

## Cara Backtest (Strategy Tester)

1. Di MT5 desktop tekan **Ctrl+R** (View → Strategy Tester).
2. Isi pengaturannya:
   - **Expert:** `StraddleBreakout_EA`
   - **Symbol:** `XAUUSD` (atau nama gold di broker kamu, mis. `GOLD`, `XAUUSD+`)
   - **Period:** `M1` (sesuai screenshot)
   - **Date:** custom period, mis. 1–2 bulan terakhir
   - **Modelling:** `Every tick based on real ticks` — paling akurat untuk
     strategi pending order jarak dekat seperti ini. Kalau download tick terlalu
     lama, minimal pakai `Every tick`.
   - **Deposit & leverage:** samakan dengan akun asli (lot 0.5 di GOLD butuh
     margin besar — untuk akun kecil turunkan `InpLot` dulu).
3. Klik tab **Inputs** untuk mengubah parameter (lot, jarak, TP, jam sesi).
4. Klik **Start**. Pertama kali, MT5 akan mengunduh data historis — tunggu
   sampai selesai.
5. Hasil dilihat di tab **Backtest** (profit, drawdown, winrate) dan tab
   **Graph** (kurva equity). Centang **Visual mode** kalau ingin melihat order
   dipasang/digeser candle per candle di chart.
6. Untuk optimasi parameter: set **Optimization = Slow/Genetic**, lalu di tab
   Inputs centang parameter yang mau discan (mis. `InpDistPts` 50–150 step 10,
   `InpTPPts` 100–400 step 50) → Start. Urutkan hasil berdasarkan
   *Recovery Factor* atau *Profit Factor*, jangan hanya total profit.

## Catatan Risiko

- Strategi straddle rawan **whipsaw**: di pasar sideways harga bisa memicu
  BUY STOP lalu berbalik kena SL, lalu memicu SELL STOP dan kena SL lagi.
  Filter jam (`InpStartHour/InpEndHour`) membantu membatasi ke sesi yang
  biasanya trending (mis. buka sesi London/New York atau saat news).
- Saat news besar, **slippage** bisa membuat harga eksekusi jauh dari harga
  pending — hasil backtest (tanpa slippage penuh) akan lebih bagus dari live.
- Lot 0.5 di GOLD = pergerakan $1 bernilai $50. Dengan SL 160 points ($1.60),
  risiko per trade ±$80. Sesuaikan lot dengan ukuran akun.
- Selalu uji di **akun demo** dulu minimal 1–2 minggu sebelum akun riil.
