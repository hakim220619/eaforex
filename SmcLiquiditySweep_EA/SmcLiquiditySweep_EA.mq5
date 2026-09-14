//+------------------------------------------------------------------+
//|                                          SmcLiquiditySweep_EA.mq5 |
//|  Strategi SMC/ICT yang bisa diuji objektif: Liquidity Sweep +    |
//|  Fair Value Gap (FVG) entry, RR tetap.                           |
//|                                                                  |
//|  Alur BUY:                                                       |
//|   1. SWEEP  : candle menusuk KE BAWAH low terendah N candle      |
//|      terakhir (stop hunt), tapi DITUTUP kembali di atas level    |
//|      itu -> likuiditas di bawah sudah "dipanen", bias naik.      |
//|   2. FVG    : tunggu terbentuk bullish Fair Value Gap            |
//|      (low candle terakhir > high dua candle sebelumnya)          |
//|      dalam masa berlaku setup.                                   |
//|   3. ENTRY  : BUY LIMIT di dalam area FVG (tepi/tengah).         |
//|   4. SL     : di bawah ujung sweep + buffer.                     |
//|      TP     : RR x jarak SL (InpRR = 2.0 -> RR 1:2).             |
//|  SELL: cermin kebalikannya (sweep ke atas high, bearish FVG).    |
//|                                                                  |
//|  Mode ENTRY_MARKET: langsung entry begitu candle sweep ditutup,  |
//|  tanpa menunggu FVG (sinyal lebih sering, entry kurang optimal). |
//+------------------------------------------------------------------+
#property copyright "forexbot"
#property version   "1.00"
#property description "SMC: liquidity sweep + FVG entry, SL di ujung sweep, TP = RR x SL"

#include <Trade/Trade.mqh>

enum ENUM_LOT_MODE
  {
   LOT_FIXED        = 0,  // Lot tetap (InpLot)
   LOT_RISK_PERCENT = 1   // Otomatis dari % risiko equity (InpRiskPercent)
  };

enum ENUM_ENTRY_MODE
  {
   ENTRY_MARKET = 0,      // Market order begitu sweep terkonfirmasi
   ENTRY_FVG    = 1       // Limit order di Fair Value Gap (lebih selektif)
  };

input group "=== Umum ==="
input long            InpMagic        = 20260812;   // Magic number
input ENUM_LOT_MODE   InpLotMode      = LOT_FIXED;  // Mode lot
input double          InpLot          = 0.01;       // Lot tetap (minimal)
input double          InpRiskPercent  = 1.0;        // Risiko per trade (% equity, mode risk percent)
input int             InpMaxSpreadPts = 60;         // Spread maksimal (points), 0 = abaikan

input group "=== Sinyal Liquidity Sweep + FVG ==="
input int             InpLookback     = 20;         // Jumlah candle penentu swing high/low (likuiditas)
input ENUM_ENTRY_MODE InpEntryMode    = ENTRY_FVG;  // Mode entry
input int             InpWaitBars     = 12;         // Masa berlaku setup setelah sweep (candle)
input int             InpFvgEntryPct  = 50;         // Posisi entry dalam FVG (0 = tepi, 50 = tengah)
input int             InpMinFvgPts    = 10;         // Ukuran FVG minimal (points), saring noise
input bool            InpUseTrendFilter = false;    // Filter arah dengan EMA (opsional)
input int             InpEmaTrendPeriod = 200;      // Periode EMA filter

input group "=== Filter S/R Terdekat (M5) ==="
input bool            InpUseSnrFilter   = true;     // Batalkan entry jika TP terhalang S/R terdekat
input int             InpSnrLookback    = 100;      // Jumlah candle yang discan untuk swing S/R
input int             InpSnrFractalBars = 2;        // Kekuatan swing (bar kiri-kanan lebih rendah/tinggi)
input int             InpSnrBufferPts   = 20;       // Buffer di belakang level S/R (points)

input group "=== Entry Breakout S/R ==="
input bool            InpUseBreakout    = true;     // BUY saat close tembus resistance / SELL saat tembus support
input int             InpBreakBufferPts = 20;       // Minimal close melewati level (points)
input bool            InpReverseOnFail  = true;     // Candle berikutnya balik arah -> tutup & entry berlawanan

input group "=== Risk / Reward ==="
input double          InpRR           = 2.0;        // RR: TP = RR x jarak SL (2.0 = 1:2)
input int             InpSLBufferPts  = 30;         // Buffer SL di belakang ujung sweep (points)
input double          InpBreakEvenRR  = 0.0;        // Geser SL ke entry setelah profit N x SL (0 = nonaktif)

input group "=== Batasan ==="
input int             InpMaxOpenTrades = 1;         // Maksimal posisi terbuka bersamaan
input int             InpStartHour     = 0;         // Jam mulai (server, 0-23)
input int             InpEndHour       = 0;         // Jam berhenti (start = end -> 24 jam)

//--- global
CTrade   trade;
datetime g_lastBar    = 0;
int      g_hEmaTrend  = INVALID_HANDLE;

// state machine setup sweep:
//   0 = tidak ada setup, +1 = menunggu entry BUY, -1 = menunggu entry SELL
int      g_state      = 0;
double   g_sweepLevel = 0.0;  // ujung sweep (low/high candle sweep) untuk SL
int      g_barsLeft   = 0;    // sisa masa berlaku setup (candle)

// state engine breakout S/R:
double   g_breakLevel = 0.0;  // level S/R yang baru ditembus
int      g_breakDir   = 0;    // +1 = breakout naik (BUY), -1 = breakout turun (SELL)
bool     g_breakArmed = false;// true = pantau pembalikan di candle berikutnya

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(30);

   if(InpUseTrendFilter)
     {
      g_hEmaTrend = iMA(_Symbol, PERIOD_CURRENT, InpEmaTrendPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(g_hEmaTrend == INVALID_HANDLE)
        {
         Print("Gagal membuat handle EMA filter");
         return(INIT_FAILED);
        }
     }

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Comment("");
  }

//+------------------------------------------------------------------+
//| Logika utama                                                     |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(InpBreakEvenRR > 0)
      ManageBreakEven();

   bool newBar = IsNewBar();

   int    posCount = 0;
   double basket   = 0.0;
   CountMyPositions(posCount, basket);
   int pendings = CountMyPendings();

   // engine breakout S/R terdekat -- dijalankan sebelum pengelolaan posisi,
   // karena pembalikan perlu menutup posisi breakout yang masih terbuka
   if(newBar && InpUseBreakout)
     {
      if(InpReverseOnFail)
         CheckBreakReversal();

      CountMyPositions(posCount, basket); // posisi bisa berubah setelah pembalikan
      if(posCount < InpMaxOpenTrades && EntryAllowed())
         CheckBreakout();

      CountMyPositions(posCount, basket);
      pendings = CountMyPendings();
     }

   // posisi sudah terbuka -> setup selesai, bereskan sisa pending
   if(posCount > 0)
     {
      if(g_state != 0)
         g_state = 0;
      if(pendings > 0)
         DeleteMyPendings();
      UpdateComment(posCount, basket);
      return;
     }

   if(newBar)
     {
      // hitung mundur masa berlaku setup
      if(g_state != 0)
        {
         g_barsLeft--;
         if(g_barsLeft <= 0)
           {
            g_state = 0;
            DeleteMyPendings(); // limit order kadaluarsa ikut dihapus
           }
        }

      if(g_state == 0 && pendings == 0)
        {
         // cari sweep baru di candle yang baru ditutup
         if(posCount < InpMaxOpenTrades && EntryAllowed())
            DetectSweep();
        }
      else if(g_state != 0 && InpEntryMode == ENTRY_FVG && pendings == 0)
        {
         // setup aktif: cek apakah FVG baru terbentuk -> pasang limit
         TryPlaceFvgOrder();
        }
     }

   UpdateComment(posCount, basket);
  }

//+------------------------------------------------------------------+
//| Deteksi candle baru                                              |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime bar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(bar == g_lastBar)
      return(false);
   g_lastBar = bar;
   return(true);
  }

//+------------------------------------------------------------------+
//| Filter jam server & spread                                       |
//+------------------------------------------------------------------+
bool EntryAllowed()
  {
   if(InpStartHour != InpEndHour)
     {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      bool inSession;
      if(InpStartHour < InpEndHour)
         inSession = (dt.hour >= InpStartHour && dt.hour < InpEndHour);
      else // sesi melewati tengah malam
         inSession = (dt.hour >= InpStartHour || dt.hour < InpEndHour);
      if(!inSession)
         return(false);
     }

   if(InpMaxSpreadPts > 0)
     {
      double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
                       SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
      if(spread > InpMaxSpreadPts)
         return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| Filter tren EMA opsional (true = arah diizinkan)                 |
//+------------------------------------------------------------------+
bool TrendAllows(bool isBuy)
  {
   if(!InpUseTrendFilter)
      return(true);

   double v[];
   if(CopyBuffer(g_hEmaTrend, 0, 1, 1, v) != 1)
      return(false); // data belum siap, jangan trading dulu

   double c1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   return(isBuy ? (c1 > v[0]) : (c1 < v[0]));
  }

//+------------------------------------------------------------------+
//| Cari liquidity sweep di candle yang baru ditutup (bar 1)         |
//+------------------------------------------------------------------+
void DetectSweep()
  {
   double l1 = iLow(_Symbol, PERIOD_CURRENT, 1);
   double h1 = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double c1 = iClose(_Symbol, PERIOD_CURRENT, 1);

   // swing low/high dari N candle SEBELUM candle sweep (bar 2 .. N+1)
   int idxLow  = iLowest(_Symbol, PERIOD_CURRENT, MODE_LOW, InpLookback, 2);
   int idxHigh = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, InpLookback, 2);
   if(idxLow < 0 || idxHigh < 0)
      return;

   double swingLow  = iLow(_Symbol, PERIOD_CURRENT, idxLow);
   double swingHigh = iHigh(_Symbol, PERIOD_CURRENT, idxHigh);

   // BULLISH SWEEP: tusuk ke bawah swing low, ditutup kembali di atasnya
   if(l1 < swingLow && c1 > swingLow && TrendAllows(true))
     {
      g_state      = 1;
      g_sweepLevel = l1;
      g_barsLeft   = InpWaitBars;
      if(InpEntryMode == ENTRY_MARKET)
         OpenMarket(true);
      return;
     }

   // BEARISH SWEEP: tusuk ke atas swing high, ditutup kembali di bawahnya
   if(h1 > swingHigh && c1 < swingHigh && TrendAllows(false))
     {
      g_state      = -1;
      g_sweepLevel = h1;
      g_barsLeft   = InpWaitBars;
      if(InpEntryMode == ENTRY_MARKET)
         OpenMarket(false);
     }
  }

//+------------------------------------------------------------------+
//| Mode market: entry langsung setelah candle sweep ditutup         |
//+------------------------------------------------------------------+
void OpenMarket(bool isBuy)
  {
   long   stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double entry = isBuy ? ask : bid;
   double sl    = isBuy ? g_sweepLevel - InpSLBufferPts * _Point
                        : g_sweepLevel + InpSLBufferPts * _Point;

   double minDist = (stopsLevel + 1) * _Point;
   double slDist  = MathAbs(entry - sl);
   if(slDist < minDist)
     {
      slDist = minDist;
      sl = isBuy ? entry - slDist : entry + slDist;
     }

   double tp = isBuy ? entry + InpRR * slDist : entry - InpRR * slDist;

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   // filter S/R: TP harus punya jalan bersih
   if(!TpClearsSnr(isBuy, entry, tp))
     {
      g_state = 0; // setup dibatalkan, cari sweep berikutnya
      return;
     }

   double lot = CalcLot(slDist / _Point);

   bool ok = isBuy
             ? trade.Buy(lot, _Symbol, 0, sl, tp, "smc sweep")
             : trade.Sell(lot, _Symbol, 0, sl, tp, "smc sweep");
   if(ok)
      g_state = 0; // setup terpakai
   else
      Print("Gagal open ", (isBuy ? "BUY" : "SELL"), ": ",
            trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Mode FVG: cek FVG baru di 3 candle terakhir, pasang limit order  |
//+------------------------------------------------------------------+
void TryPlaceFvgOrder()
  {
   long   stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double h3 = iHigh(_Symbol, PERIOD_CURRENT, 3);
   double l3 = iLow(_Symbol, PERIOD_CURRENT, 3);
   double h1 = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double l1 = iLow(_Symbol, PERIOD_CURRENT, 1);

   if(g_state == 1) // menunggu BUY: cari bullish FVG (l1 > h3)
     {
      double gap = l1 - h3;
      if(gap < InpMinFvgPts * _Point)
         return; // belum ada FVG yang layak, coba lagi candle berikutnya

      double entry = NormalizeDouble(l1 - gap * InpFvgEntryPct / 100.0, _Digits);
      double sl    = NormalizeDouble(g_sweepLevel - InpSLBufferPts * _Point, _Digits);

      // BUY LIMIT harus di bawah harga sekarang & SL di bawah entry
      if(entry >= ask - (stopsLevel + 1) * _Point || sl >= entry)
         return;

      double slDist = entry - sl;
      double tp     = NormalizeDouble(entry + InpRR * slDist, _Digits);

      // filter S/R: coba lagi candle berikutnya selama setup masih berlaku
      if(!TpClearsSnr(true, entry, tp))
         return;

      double lot = CalcLot(slDist / _Point);

      if(!trade.BuyLimit(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "smc fvg"))
         Print("Gagal pasang BUY LIMIT: ", trade.ResultRetcodeDescription());
     }
   else if(g_state == -1) // menunggu SELL: cari bearish FVG (h1 < l3)
     {
      double gap = l3 - h1;
      if(gap < InpMinFvgPts * _Point)
         return;

      double entry = NormalizeDouble(h1 + gap * InpFvgEntryPct / 100.0, _Digits);
      double sl    = NormalizeDouble(g_sweepLevel + InpSLBufferPts * _Point, _Digits);

      // SELL LIMIT harus di atas harga sekarang & SL di atas entry
      if(entry <= bid + (stopsLevel + 1) * _Point || sl <= entry)
         return;

      double slDist = sl - entry;
      double tp     = NormalizeDouble(entry - InpRR * slDist, _Digits);

      // filter S/R: coba lagi candle berikutnya selama setup masih berlaku
      if(!TpClearsSnr(false, entry, tp))
         return;

      double lot = CalcLot(slDist / _Point);

      if(!trade.SellLimit(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "smc fvg"))
         Print("Gagal pasang SELL LIMIT: ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| S/R: resistance terdekat DI ATAS harga (swing high / fractal)    |
//| return 0.0 jika tidak ditemukan                                  |
//+------------------------------------------------------------------+
double NearestResistance(double fromPrice)
  {
   double best = 0.0;
   for(int i = InpSnrFractalBars + 1; i <= InpSnrLookback; i++)
     {
      double h = iHigh(_Symbol, PERIOD_CURRENT, i);
      bool pivot = true;
      for(int k = 1; k <= InpSnrFractalBars && pivot; k++)
        {
         if(iHigh(_Symbol, PERIOD_CURRENT, i - k) >= h)
            pivot = false;
         if(iHigh(_Symbol, PERIOD_CURRENT, i + k) >= h)
            pivot = false;
        }
      if(!pivot)
         continue;
      if(h > fromPrice && (best == 0.0 || h < best))
         best = h; // ambil yang paling dekat di atas harga
     }
   return(best);
  }

//+------------------------------------------------------------------+
//| S/R: support terdekat DI BAWAH harga (swing low / fractal)       |
//| return 0.0 jika tidak ditemukan                                  |
//+------------------------------------------------------------------+
double NearestSupport(double fromPrice)
  {
   double best = 0.0;
   for(int i = InpSnrFractalBars + 1; i <= InpSnrLookback; i++)
     {
      double l = iLow(_Symbol, PERIOD_CURRENT, i);
      bool pivot = true;
      for(int k = 1; k <= InpSnrFractalBars && pivot; k++)
        {
         if(iLow(_Symbol, PERIOD_CURRENT, i - k) <= l)
            pivot = false;
         if(iLow(_Symbol, PERIOD_CURRENT, i + k) <= l)
            pivot = false;
        }
      if(!pivot)
         continue;
      if(l < fromPrice && l > best)
         best = l; // ambil yang paling dekat di bawah harga
     }
   return(best);
  }

//+------------------------------------------------------------------+
//| Filter S/R: TP harus bisa dicapai tanpa terhalang level S/R      |
//| (target tetap RR x SL; S/R hanya menyaring entry, bukan target)  |
//+------------------------------------------------------------------+
bool TpClearsSnr(bool isBuy, double entry, double tp)
  {
   if(!InpUseSnrFilter)
      return(true);

   if(isBuy)
     {
      double res = NearestResistance(entry);
      if(res > 0.0 && res < tp + InpSnrBufferPts * _Point)
        {
         Print("Entry BUY dilewati: resistance ", DoubleToString(res, _Digits),
               " lebih dekat dari TP ", DoubleToString(tp, _Digits));
         return(false);
        }
     }
   else
     {
      double sup = NearestSupport(entry);
      if(sup > 0.0 && sup > tp - InpSnrBufferPts * _Point)
        {
         Print("Entry SELL dilewati: support ", DoubleToString(sup, _Digits),
               " lebih dekat dari TP ", DoubleToString(tp, _Digits));
         return(false);
        }
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Breakout S/R: close candle menembus level terdekat -> entry      |
//| searah tembusan (BUY tembus resistance, SELL tembus support)     |
//+------------------------------------------------------------------+
void CheckBreakout()
  {
   double ref = iClose(_Symbol, PERIOD_CURRENT, 2); // harga sebelum candle breakout
   double c1  = iClose(_Symbol, PERIOD_CURRENT, 1); // candle yang baru ditutup
   double buf = InpBreakBufferPts * _Point;

   long   stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // BREAKOUT NAIK: sebelumnya di bawah resistance, sekarang close di atasnya
   double res = NearestResistance(ref);
   if(res > 0.0 && ref <= res && c1 > res + buf && TrendAllows(true))
     {
      double entry   = ask;
      double sl      = res - InpSLBufferPts * _Point; // level yang ditembus jadi support
      double minDist = (stopsLevel + 1) * _Point;
      double slDist  = entry - sl;
      if(slDist < minDist)
        {
         slDist = minDist;
         sl = entry - slDist;
        }
      double tp = NormalizeDouble(entry + InpRR * slDist, _Digits);
      sl = NormalizeDouble(sl, _Digits);

      if(!TpClearsSnr(true, entry, tp))
         return;

      if(trade.Buy(CalcLot(slDist / _Point), _Symbol, 0, sl, tp, "snr break"))
        {
         g_breakLevel = res;
         g_breakDir   = 1;
         g_breakArmed = true; // pantau pembalikan di candle berikutnya
        }
      else
         Print("Gagal BUY breakout: ", trade.ResultRetcodeDescription());
      return;
     }

   // BREAKOUT TURUN: sebelumnya di atas support, sekarang close di bawahnya
   double sup = NearestSupport(ref);
   if(sup > 0.0 && ref >= sup && c1 < sup - buf && TrendAllows(false))
     {
      double entry   = bid;
      double sl      = sup + InpSLBufferPts * _Point; // level yang ditembus jadi resistance
      double minDist = (stopsLevel + 1) * _Point;
      double slDist  = sl - entry;
      if(slDist < minDist)
        {
         slDist = minDist;
         sl = entry + slDist;
        }
      double tp = NormalizeDouble(entry - InpRR * slDist, _Digits);
      sl = NormalizeDouble(sl, _Digits);

      if(!TpClearsSnr(false, entry, tp))
         return;

      if(trade.Sell(CalcLot(slDist / _Point), _Symbol, 0, sl, tp, "snr break"))
        {
         g_breakLevel = sup;
         g_breakDir   = -1;
         g_breakArmed = true;
        }
      else
         Print("Gagal SELL breakout: ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Pembalikan breakout: candle SETELAH breakout ditutup kembali di  |
//| seberang level -> tutup posisi breakout, langsung entry lawan    |
//+------------------------------------------------------------------+
void CheckBreakReversal()
  {
   if(!g_breakArmed)
      return;
   g_breakArmed = false; // hanya berlaku pada satu candle setelah breakout

   double c1  = iClose(_Symbol, PERIOD_CURRENT, 1);
   double buf = InpBreakBufferPts * _Point;
   long   stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   if(g_breakDir == 1 && c1 < g_breakLevel - buf)
     {
      // breakout naik GAGAL -> tutup BUY breakout, langsung SELL
      CloseBreakoutPositions(1);

      int    posCount = 0;
      double basket   = 0.0;
      CountMyPositions(posCount, basket);
      if(posCount < InpMaxOpenTrades)
        {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double hi  = MathMax(iHigh(_Symbol, PERIOD_CURRENT, 1),
                              iHigh(_Symbol, PERIOD_CURRENT, 2));
         double sl      = hi + InpSLBufferPts * _Point; // di atas puncak breakout palsu
         double minDist = (stopsLevel + 1) * _Point;
         double slDist  = sl - bid;
         if(slDist < minDist)
           {
            slDist = minDist;
            sl = bid + slDist;
           }
         double tp = NormalizeDouble(bid - InpRR * slDist, _Digits);
         sl = NormalizeDouble(sl, _Digits);

         if(!trade.Sell(CalcLot(slDist / _Point), _Symbol, 0, sl, tp, "snr reverse"))
            Print("Gagal SELL pembalikan: ", trade.ResultRetcodeDescription());
        }
     }
   else if(g_breakDir == -1 && c1 > g_breakLevel + buf)
     {
      // breakout turun GAGAL -> tutup SELL breakout, langsung BUY
      CloseBreakoutPositions(-1);

      int    posCount = 0;
      double basket   = 0.0;
      CountMyPositions(posCount, basket);
      if(posCount < InpMaxOpenTrades)
        {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double lo  = MathMin(iLow(_Symbol, PERIOD_CURRENT, 1),
                              iLow(_Symbol, PERIOD_CURRENT, 2));
         double sl      = lo - InpSLBufferPts * _Point; // di bawah dasar breakout palsu
         double minDist = (stopsLevel + 1) * _Point;
         double slDist  = ask - sl;
         if(slDist < minDist)
           {
            slDist = minDist;
            sl = ask - slDist;
           }
         double tp = NormalizeDouble(ask + InpRR * slDist, _Digits);
         sl = NormalizeDouble(sl, _Digits);

         if(!trade.Buy(CalcLot(slDist / _Point), _Symbol, 0, sl, tp, "snr reverse"))
            Print("Gagal BUY pembalikan: ", trade.ResultRetcodeDescription());
        }
     }

   g_breakDir   = 0;
   g_breakLevel = 0.0;
  }

//+------------------------------------------------------------------+
//| Tutup posisi breakout ("snr break") searah dir                   |
//+------------------------------------------------------------------+
void CloseBreakoutPositions(int dir)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(StringFind(PositionGetString(POSITION_COMMENT), "snr break") < 0)
         continue;

      long type = PositionGetInteger(POSITION_TYPE);
      if(dir == 1 && type != POSITION_TYPE_BUY)
         continue;
      if(dir == -1 && type != POSITION_TYPE_SELL)
         continue;

      if(!trade.PositionClose(ticket))
         Print("Gagal tutup posisi breakout #", ticket, ": ",
               trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Geser SL ke entry setelah profit mencapai InpBreakEvenRR x SL    |
//+------------------------------------------------------------------+
void ManageBreakEven()
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      long   type  = PositionGetInteger(POSITION_TYPE);

      if(sl == 0.0)
         continue;

      if(type == POSITION_TYPE_BUY && sl < entry)
        {
         double risk = entry - sl;
         if(bid - entry >= InpBreakEvenRR * risk)
            if(!trade.PositionModify(ticket, NormalizeDouble(entry, _Digits), tp))
               Print("Gagal breakeven BUY: ", trade.ResultRetcodeDescription());
        }
      else if(type == POSITION_TYPE_SELL && sl > entry)
        {
         double risk = sl - entry;
         if(entry - ask >= InpBreakEvenRR * risk)
            if(!trade.PositionModify(ticket, NormalizeDouble(entry, _Digits), tp))
               Print("Gagal breakeven SELL: ", trade.ResultRetcodeDescription());
        }
     }
  }

//+------------------------------------------------------------------+
//| Helper: nilai uang per point per 1.0 lot                         |
//+------------------------------------------------------------------+
double MoneyPerPointPerLot()
  {
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0)
      return(0.0);
   return(tickValue * (_Point / tickSize));
  }

//+------------------------------------------------------------------+
//| Helper: hitung lot (tetap atau dari % risiko equity)             |
//+------------------------------------------------------------------+
double CalcLot(double slDistPoints)
  {
   if(InpLotMode == LOT_FIXED)
      return(NormalizeLot(InpLot));

   double riskUSD  = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0;
   double perPoint = MoneyPerPointPerLot();
   if(perPoint <= 0 || slDistPoints <= 0)
      return(NormalizeLot(InpLot)); // fallback ke lot tetap

   return(NormalizeLot(riskUSD / (slDistPoints * perPoint)));
  }

//+------------------------------------------------------------------+
//| Helper: hitung posisi milik EA                                   |
//+------------------------------------------------------------------+
void CountMyPositions(int &count, double &profit)
  {
   count  = 0;
   profit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      count++;
      profit += PositionGetDouble(POSITION_PROFIT)
              + PositionGetDouble(POSITION_SWAP);
     }
  }

//+------------------------------------------------------------------+
//| Helper: hitung pending milik EA                                  |
//+------------------------------------------------------------------+
int CountMyPendings()
  {
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      count++;
     }
   return(count);
  }

//+------------------------------------------------------------------+
//| Helper: hapus semua pending milik EA                             |
//+------------------------------------------------------------------+
void DeleteMyPendings()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      trade.OrderDelete(ticket);
     }
  }

//+------------------------------------------------------------------+
//| Helper: normalisasi lot sesuai aturan broker                     |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
  {
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step > 0)
      lot = MathFloor(lot / step) * step; // dibulatkan ke bawah agar risiko tidak membesar

   lot = MathMax(minLot, MathMin(lot, maxLot));
   return(NormalizeDouble(lot, 2));
  }

//+------------------------------------------------------------------+
//| Tampilan status di chart                                         |
//+------------------------------------------------------------------+
void UpdateComment(int posCount, double basket)
  {
   string status;
   if(posCount > 0)
      status = "POSISI AKTIF";
   else if(g_state == 1)
      status = "sweep BULLISH terdeteksi, tunggu FVG (" + IntegerToString(g_barsLeft) + " candle)";
   else if(g_state == -1)
      status = "sweep BEARISH terdeteksi, tunggu FVG (" + IntegerToString(g_barsLeft) + " candle)";
   else
      status = "scan liquidity sweep...";

   string s = "=== SmcLiquiditySweep EA ===\n";
   s += "Status        : " + status + "\n";
   s += "Floating P/L  : " + DoubleToString(basket, 2) + " USD\n";
   s += "RR            : 1 : " + DoubleToString(InpRR, 1) + "\n";

   if(g_breakArmed)
      s += "Breakout      : pantau pembalikan di candle berikutnya\n";

   if(InpUseSnrFilter)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double res = NearestResistance(bid);
      double sup = NearestSupport(bid);
      s += "Resist dekat  : " + (res > 0 ? DoubleToString(res, _Digits) : "-") + "\n";
      s += "Support dekat : " + (sup > 0 ? DoubleToString(sup, _Digits) : "-") + "\n";
     }

   Comment(s);
  }
//+------------------------------------------------------------------+
