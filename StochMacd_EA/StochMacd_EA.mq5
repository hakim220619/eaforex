//+------------------------------------------------------------------+
//|                                                  StochMacd_EA.mq5 |
//|  EA konfluensi MACD + Stochastic untuk M15.                       |
//|                                                                   |
//|  Ide dasar -- "reaksi pasar" dibaca dari dua sisi:                |
//|    MACD       = arah & tenaga momentum (lambat, konfirmasi)       |
//|    Stochastic = titik balik jangka pendek (cepat, pemicu)         |
//|  Sinyal sah bila KEDUANYA setuju dalam jendela InpConfluenceBars  |
//|  bar, dan kejadian yang paling akhir jatuh tepat di bar terakhir  |
//|  yang sudah closed (jadi satu sinyal per kejadian, bukan spam).   |
//|                                                                   |
//|  Setup BUY (SELL = cermin):                                       |
//|   1. MACD  : main cross di atas signal (atau main > signal, lihat |
//|              InpMacdMode) dalam jendela konfluensi.               |
//|   2. STOCH : %K cross di atas %D saat berada di area oversold.    |
//|   3. Filter: sesi jam, EMA trend (opsional), sisi garis nol MACD  |
//|              (opsional), spread, jarak SL minimum.                |
//|   4. ENTRY : market di bar baru, atau limit pullback X x ATR.     |
//|   5. SL    : di balik swing low + buffer ATR (atau murni ATR),    |
//|              dijepit ke [InpSlMinAtr, InpSlMaxAtr] x ATR.         |
//|      TP    : RR tetap, atau swing berlawanan berikutnya.          |
//|                                                                   |
//|  Kalibrasi simbol 3 digit (Exness Pro XAUUSD):                    |
//|   - semua jarak berbasis ATR, bukan points (bebas dari digit)     |
//|   - kompensasi spread: SL/TP SELL digeser +spread, karena SELL    |
//|     ditutup di Ask sedangkan chart memakai Bid                    |
//|   - filter spread relatif risiko (spread <= X% jarak SL)          |
//|   - break-even default OFF (di gold, BE 1R memangkas pemenang)    |
//|   - Journal mencetak risiko $ dan % tiap order                    |
//+------------------------------------------------------------------+
#property copyright "forexbot"
#property version   "1.00"
#property description "Konfluensi MACD + Stochastic M15. Jarak berbasis ATR, kompensasi spread, filter risiko."

#include <Trade/Trade.mqh>

#define OBJ_PREFIX "SM_"

//+------------------------------------------------------------------+
//| Enum                                                              |
//+------------------------------------------------------------------+
enum ENUM_LOT_MODE
  {
   LOT_FIXED        = 0,  // Lot tetap (InpLot)
   LOT_RISK_PERCENT = 1   // Otomatis dari % risiko equity (InpRiskPercent)
  };

enum ENUM_MACD_MODE
  {
   MACD_CROSS = 0,  // Cross main/signal di dalam jendela konfluensi
   MACD_STATE = 1,  // Cukup main > signal (BUY) / main < signal (SELL)
   MACD_HIST  = 2   // main > signal DAN histogram menguat
  };

enum ENUM_MACD_ZERO
  {
   ZERO_OFF      = 0,  // Abaikan posisi terhadap garis nol
   ZERO_PULLBACK = 1,  // BUY hanya saat MACD main < 0 (beli koreksi)
   ZERO_TREND    = 2   // BUY hanya saat MACD main > 0 (ikut tren)
  };

enum ENUM_STOCH_MODE
  {
   STO_CROSS_ZONE = 0,  // %K cross %D dan cross terjadi di zona OS/OB
   STO_EXIT_ZONE  = 1,  // %K keluar dari zona OS/OB
   STO_CROSS_ANY  = 2   // %K cross %D di mana saja
  };

enum ENUM_TRIGGER
  {
   TRIG_ANY   = 0,  // Pemicu = sinyal yang datang paling akhir
   TRIG_STOCH = 1,  // Stochastic wajib memicu di bar terakhir
   TRIG_MACD  = 2   // MACD wajib memicu di bar terakhir
  };

enum ENUM_ENTRY_MODE
  {
   ENTRY_MARKET = 0,  // Market saat bar baru terbuka
   ENTRY_LIMIT  = 1   // Limit pullback InpPullbackAtr x ATR
  };

enum ENUM_SL_MODE
  {
   SL_SWING = 0,  // Di balik swing low/high InpSlSwingBars bar + buffer ATR
   SL_ATR   = 1   // Murni InpSlAtr x ATR dari entry
  };

enum ENUM_TP_MODE
  {
   TP_RR    = 0,  // RR tetap (InpRR)
   TP_SWING = 1   // Swing berlawanan berikutnya, RR dijepit [MinRR, MaxRR]
  };

//+------------------------------------------------------------------+
//| Input                                                             |
//+------------------------------------------------------------------+
input group "=== Umum ==="
input long            InpMagic             = 20260905;  // Magic number
input ENUM_LOT_MODE   InpLotMode           = LOT_FIXED; // Mode lot
input double          InpLot               = 0.01;      // Lot tetap
input double          InpRiskPercent       = 1.0;       // Risiko per trade (% equity)
input double          InpMaxRiskPct        = 0.0;       // Blok trade bila risiko > % equity (0=off)
input int             InpMaxOpenTrades     = 1;         // Maks posisi terbuka EA ini
input int             InpCooldownBars      = 4;         // Jeda minimal antar entry (bar)
input bool            InpUseSession        = false;     // Batasi jam trading (waktu server)
input int             InpStartHour         = 7;         // Jam mulai
input int             InpEndHour           = 21;        // Jam selesai
input int             InpMaxSpreadPts      = 350;       // Spread maks (points), 0=off
input double          InpMaxSpreadRiskPct  = 8.0;       // Spread maks sebagai % jarak SL, 0=off
input bool            InpSpreadCompensate  = true;      // Geser SL/TP SELL sebesar spread
input int             InpSlippagePts       = 30;        // Deviasi harga (points)

input group "=== MACD ==="
input int             InpMacdFast          = 12;        // EMA cepat
input int             InpMacdSlow          = 26;        // EMA lambat
input int             InpMacdSignal        = 9;         // Periode signal (MT5 memakai SMA)
input ENUM_APPLIED_PRICE InpMacdPrice      = PRICE_CLOSE; // Harga MACD
input ENUM_MACD_MODE  InpMacdMode          = MACD_HIST;  // Syarat MACD
input ENUM_MACD_ZERO  InpMacdZero          = ZERO_OFF;   // Filter garis nol
input double          InpMinHistAtr        = 0.0;       // |histogram| minimal (x ATR), 0=off

input group "=== Stochastic ==="
input int             InpStochK            = 21;        // %K period
input int             InpStochD            = 3;         // %D period
input int             InpStochSlowing      = 3;         // Slowing
input ENUM_MA_METHOD  InpStochMethod       = MODE_SMA;  // Metode smoothing
input ENUM_STO_PRICE  InpStochPrice        = STO_LOWHIGH; // Harga Stochastic
input ENUM_STOCH_MODE InpStochMode         = STO_CROSS_ZONE; // Syarat Stochastic
input double          InpStochOS           = 25.0;      // Batas oversold
input double          InpStochOB           = 75.0;      // Batas overbought

input group "=== Konfluensi & filter tren ==="
input int             InpConfluenceBars    = 3;         // Jendela konfluensi (bar)
input ENUM_TRIGGER    InpTrigger           = TRIG_ANY;  // Siapa yang wajib memicu di bar terakhir
input bool            InpUseEma            = false;     // Filter EMA tren
input int             InpEmaPeriod         = 200;       // Periode EMA

input group "=== Entry ==="
input ENUM_ENTRY_MODE InpEntryMode         = ENTRY_MARKET; // Cara masuk
input double          InpPullbackAtr       = 0.5;       // Jarak limit dari harga (x ATR)
input int             InpEntryValidBars    = 6;         // Umur limit (bar)

input group "=== SL / TP ==="
input int             InpAtrPeriod         = 14;        // Periode ATR
input ENUM_SL_MODE    InpSlMode            = SL_ATR;    // Dasar SL
input int             InpSlSwingBars       = 10;        // Bar untuk swing SL
input double          InpSlBufferAtr       = 0.3;       // Buffer di balik swing (x ATR)
input double          InpSlAtr             = 1.5;       // Jarak SL bila SL_ATR (x ATR)
input double          InpSlMinAtr          = 1.0;       // SL minimal (x ATR)
input double          InpSlMaxAtr          = 4.0;       // SL maksimal (x ATR), 0=off
input ENUM_TP_MODE    InpTpMode            = TP_RR;     // Dasar TP
input double          InpRR                = 1.5;       // RR tetap
input int             InpTpSwingBars       = 40;        // Bar untuk cari swing TP
input double          InpMinRR             = 1.2;       // RR minimal (TP_SWING)
input double          InpMaxRR             = 5.0;       // RR maksimal (TP_SWING)
input double          InpTpBufferAtr       = 0.1;       // Mundur dari swing TP (x ATR)

input group "=== Manajemen posisi ==="
input double          InpBreakEvenRR       = 0.0;       // Pindah SL ke BE di RR ini (0=off)
input double          InpBeOffsetAtr       = 0.05;      // Offset BE (x ATR)
input double          InpTrailAtr          = 0.0;       // Trailing stop (x ATR), 0=off
input double          InpTrailStartRR      = 1.0;       // Trailing mulai di RR ini
input bool            InpExitOnOpposite    = false;     // Tutup saat sinyal berlawanan muncul
input bool            InpExitOnStochExt    = false;     // Tutup saat Stochastic sampai zona lawan
input int             InpMaxBarsInTrade    = 16;        // Tutup paksa setelah N bar (0=off)

input group "=== Diagnosa ==="
input bool            InpVerbose           = true;      // Cetak detail ke Journal
input bool            InpDrawObjects       = true;      // Gambar panah entry di chart

//+------------------------------------------------------------------+
//| Global                                                            |
//+------------------------------------------------------------------+
CTrade   trade;
int      hMacd = INVALID_HANDLE, hStoch = INVALID_HANDLE, hAtr = INVALID_HANDLE, hEma = INVALID_HANDLE;
datetime lastBarTime = 0;
int      barCount    = 0;
int      lastEntryBar = -10000;   // barCount saat entry terakhir
double   gPoint = 0.0;
int      gDigits = 0;
bool     gOptimizing = false;

// pending limit yang sedang diawasi
ulong    pendingTicket = 0;
int      pendingBar    = 0;

// counter ringkasan
struct Stats
  {
   long bars, sigBuy, sigSell, exec;
   long rejSession, rejCooldown, rejOpen, rejSpread, rejRisk, rejSl, rejTrend, rejRR, rejOrder;
  };
Stats st;

struct Signal
  {
   int    dir;        // +1 buy, -1 sell, 0 none
   double entry, sl, tp, atr;
   double riskMoney, riskPct;
   double lot;
  };

//+------------------------------------------------------------------+
//| Util                                                              |
//+------------------------------------------------------------------+
double PricePerLot()
  {
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(ts <= 0.0 || tv <= 0.0)
      return 0.0;
   return tv / ts;                       // nilai $ per 1 unit harga per 1.00 lot
  }

double SpreadPrice()
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double s   = ask - bid;
   return (s > 0.0 ? s : 0.0);
  }

double NormLot(double lot)
  {
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stp= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stp <= 0.0)
      stp = 0.01;
   lot = MathFloor(lot / stp + 1e-8) * stp;
   if(lot < mn) lot = mn;
   if(lot > mx) lot = mx;
   return NormalizeDouble(lot, 2);
  }

double StopsLevelPrice()
  {
   long lvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   return (double)lvl * gPoint;
  }

int CountOwnPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk))
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic)
         n++;
     }
   return n;
  }

int CountOwnOrders()
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0 || !OrderSelect(tk))
         continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
         OrderGetInteger(ORDER_MAGIC) == InpMagic)
         n++;
     }
   return n;
  }

void Log(const string msg)
  {
   if(InpVerbose)
      Print(msg);
  }

//+------------------------------------------------------------------+
//| Init / Deinit                                                     |
//+------------------------------------------------------------------+
int OnInit()
  {
   gPoint  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   gDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   gOptimizing = (bool)MQLInfoInteger(MQL_OPTIMIZATION);

   if(InpMacdFast >= InpMacdSlow)
     {
      Print("Input salah: InpMacdFast harus lebih kecil dari InpMacdSlow.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpStochOS >= InpStochOB)
     {
      Print("Input salah: InpStochOS harus lebih kecil dari InpStochOB.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpConfluenceBars < 1)
     {
      Print("Input salah: InpConfluenceBars minimal 1.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMaxOpenTrades < 1)
     {
      Print("Input salah: InpMaxOpenTrades minimal 1.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMacdMode == MACD_STATE && InpTrigger == TRIG_MACD)
     {
      Print("Input salah: MACD_STATE tidak pernah menghasilkan kejadian cross, " +
            "jadi TRIG_MACD membuat EA tidak akan pernah entry.");
      return INIT_PARAMETERS_INCORRECT;
     }

   hMacd  = iMACD(_Symbol, _Period, InpMacdFast, InpMacdSlow, InpMacdSignal, InpMacdPrice);
   hStoch = iStochastic(_Symbol, _Period, InpStochK, InpStochD, InpStochSlowing, InpStochMethod, InpStochPrice);
   hAtr   = iATR(_Symbol, _Period, InpAtrPeriod);
   if(InpUseEma)
      hEma = iMA(_Symbol, _Period, InpEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(hMacd == INVALID_HANDLE || hStoch == INVALID_HANDLE || hAtr == INVALID_HANDLE ||
      (InpUseEma && hEma == INVALID_HANDLE))
     {
      Print("Gagal membuat handle indikator.");
      return INIT_FAILED;
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   ZeroMemory(st);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double vpl    = PricePerLot();
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   PrintFormat("StochMacd EA v1.00 init: %s %s | digits=%d point=%.5f | spread=%d pts | lot min=%.2f | nilai 1.00 lot per 1 unit harga=$%.2f | equity=%.2f",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period), gDigits, gPoint,
               (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), minLot, vpl, equity);

   // gambaran risiko dengan lot minimum
   double atrPrev[];
   ArraySetAsSeries(atrPrev, true);
   if(CopyBuffer(hAtr, 0, 0, 2, atrPrev) == 2 && vpl > 0.0 && equity > 0.0)
     {
      double slGuess = atrPrev[0] * MathMax(InpSlMinAtr, 1.0);
      double riskMin = slGuess * vpl * minLot;
      PrintFormat("Cek risiko: lot %.2f dengan SL %.3f (%.1f x ATR) = $%.2f = %.1f%% equity",
                  minLot, slGuess, MathMax(InpSlMinAtr, 1.0), riskMin, riskMin / equity * 100.0);
     }
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   PrintFormat("RINGKASAN StochMacd EA: bar=%I64d | sinyal BUY=%I64d SELL=%I64d | dieksekusi=%I64d",
               st.bars, st.sigBuy, st.sigSell, st.exec);
   PrintFormat("  ditolak: sesi=%I64d cooldown=%I64d posisi-penuh=%I64d spread=%I64d risiko=%I64d SL=%I64d tren=%I64d RR=%I64d order-gagal=%I64d",
               st.rejSession, st.rejCooldown, st.rejOpen, st.rejSpread, st.rejRisk, st.rejSl, st.rejTrend, st.rejRR, st.rejOrder);

   if(hMacd  != INVALID_HANDLE) IndicatorRelease(hMacd);
   if(hStoch != INVALID_HANDLE) IndicatorRelease(hStoch);
   if(hAtr   != INVALID_HANDLE) IndicatorRelease(hAtr);
   if(hEma   != INVALID_HANDLE) IndicatorRelease(hEma);

   if(!gOptimizing)
      ObjectsDeleteAll(0, OBJ_PREFIX);
  }

//+------------------------------------------------------------------+
//| Deteksi sinyal pada bar terakhir yang sudah closed (shift 1)      |
//+------------------------------------------------------------------+
// Mengembalikan indeks bar (1..InpConfluenceBars) saat MACD memicu, -1 bila tidak.
int MacdEventBar(const double &main[], const double &sig[], int dir)
  {
   for(int i = 1; i <= InpConfluenceBars; i++)
     {
      bool up   = (main[i] > sig[i] && main[i + 1] <= sig[i + 1]);
      bool down = (main[i] < sig[i] && main[i + 1] >= sig[i + 1]);
      if((dir > 0 && up) || (dir < 0 && down))
         return i;
     }
   return -1;
  }

int StochEventBar(const double &k[], const double &d[], int dir)
  {
   for(int i = 1; i <= InpConfluenceBars; i++)
     {
      bool ev = false;
      if(InpStochMode == STO_CROSS_ANY)
        {
         ev = (dir > 0) ? (k[i] > d[i] && k[i + 1] <= d[i + 1])
                        : (k[i] < d[i] && k[i + 1] >= d[i + 1]);
        }
      else
         if(InpStochMode == STO_CROSS_ZONE)
           {
            if(dir > 0)
               ev = (k[i] > d[i] && k[i + 1] <= d[i + 1] && MathMin(k[i + 1], d[i + 1]) < InpStochOS);
            else
               ev = (k[i] < d[i] && k[i + 1] >= d[i + 1] && MathMax(k[i + 1], d[i + 1]) > InpStochOB);
           }
         else // STO_EXIT_ZONE
           {
            if(dir > 0)
               ev = (k[i] > InpStochOS && k[i + 1] <= InpStochOS);
            else
               ev = (k[i] < InpStochOB && k[i + 1] >= InpStochOB);
           }
      if(ev)
         return i;
     }
   return -1;
  }

// Cek konfluensi MACD + Stochastic untuk satu arah (dir = +1 BUY / -1 SELL).
bool DirectionSignal(int dir, const double &main[], const double &sig[],
                     const double &k[], const double &d[], double atr)
  {
   // --- state sekarang harus searah
   bool macdState = (dir > 0) ? (main[1] > sig[1]) : (main[1] < sig[1]);
   bool stochState= (dir > 0) ? (k[1]   > d[1])    : (k[1]   < d[1]);
   if(!macdState || !stochState)
      return false;

   // --- syarat MACD
   int macdBar = -1;
   if(InpMacdMode == MACD_CROSS)
     {
      macdBar = MacdEventBar(main, sig, dir);
      if(macdBar < 0)
         return false;
     }
   else
      if(InpMacdMode == MACD_HIST)
        {
         double h1 = main[1] - sig[1];
         double h2 = main[2] - sig[2];
         if(dir > 0 && !(h1 > h2)) return false;
         if(dir < 0 && !(h1 < h2)) return false;
         macdBar = MacdEventBar(main, sig, dir);   // -1 bila tidak ada cross: mode state
        }

   // --- filter garis nol
   if(InpMacdZero == ZERO_PULLBACK)
     {
      if(dir > 0 && main[1] >= 0.0) return false;
      if(dir < 0 && main[1] <= 0.0) return false;
     }
   else
      if(InpMacdZero == ZERO_TREND)
        {
         if(dir > 0 && main[1] <= 0.0) return false;
         if(dir < 0 && main[1] >= 0.0) return false;
        }

   // --- tenaga momentum minimum
   if(InpMinHistAtr > 0.0 && atr > 0.0)
     {
      if(MathAbs(main[1] - sig[1]) < InpMinHistAtr * atr)
         return false;
     }

   // --- syarat Stochastic
   int stochBar = StochEventBar(k, d, dir);
   if(stochBar < 0)
      return false;

   // --- kesegaran: kejadian terakhir wajib di bar 1, jadi satu sinyal per kejadian
   if(InpTrigger == TRIG_STOCH)
     {
      if(stochBar != 1)
         return false;
     }
   else
      if(InpTrigger == TRIG_MACD)
        {
         if(macdBar != 1)
            return false;
        }
      else // TRIG_ANY
        {
         int last = stochBar;
         if(macdBar > 0 && macdBar < last)
            last = macdBar;
         if(last != 1)
            return false;
        }
   return true;
  }

//+------------------------------------------------------------------+
//| Susun setup lengkap (entry / SL / TP / lot)                       |
//+------------------------------------------------------------------+
bool BuildSetup(int dir, double atr, Signal &s)
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int need = (int)MathMax(InpSlSwingBars, InpTpSwingBars) + 3;
   if(CopyRates(_Symbol, _Period, 0, need, r) < need)
      return false;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spr = SpreadPrice();

   // --- entry
   double entry = (dir > 0) ? ask : bid;
   if(InpEntryMode == ENTRY_LIMIT)
     {
      double back = InpPullbackAtr * atr;
      entry = (dir > 0) ? (ask - back) : (bid + back);
     }

   // --- SL
   double sl;
   if(InpSlMode == SL_SWING)
     {
      double ext = (dir > 0) ? r[1].low : r[1].high;
      for(int i = 1; i <= InpSlSwingBars; i++)
        {
         if(dir > 0) ext = MathMin(ext, r[i].low);
         else        ext = MathMax(ext, r[i].high);
        }
      sl = (dir > 0) ? (ext - InpSlBufferAtr * atr) : (ext + InpSlBufferAtr * atr);
     }
   else
      sl = (dir > 0) ? (entry - InpSlAtr * atr) : (entry + InpSlAtr * atr);

   double slDist = MathAbs(entry - sl);

   // jepit ke [min, max] x ATR
   double minDist = InpSlMinAtr * atr;
   if(slDist < minDist)
     {
      slDist = minDist;
      sl = (dir > 0) ? (entry - slDist) : (entry + slDist);
     }
   if(InpSlMaxAtr > 0.0 && slDist > InpSlMaxAtr * atr)
     {
      st.rejSl++;
      Log(StringFormat("Tolak: jarak SL %.3f > %.1f x ATR (%.3f)", slDist, InpSlMaxAtr, InpSlMaxAtr * atr));
      return false;
     }

   // stops level broker
   double stops = StopsLevelPrice();
   if(stops > 0.0 && slDist < stops + spr)
     {
      slDist = stops + spr;
      sl = (dir > 0) ? (entry - slDist) : (entry + slDist);
     }

   // --- TP
   double tp;
   if(InpTpMode == TP_RR)
      tp = (dir > 0) ? (entry + InpRR * slDist) : (entry - InpRR * slDist);
   else
     {
      double target = 0.0;
      bool   found  = false;
      for(int i = 1; i <= InpTpSwingBars; i++)
        {
         double lvl = (dir > 0) ? r[i].high : r[i].low;
         if(dir > 0 && lvl > entry) { target = (found ? MathMax(target, lvl) : lvl); found = true; }
         if(dir < 0 && lvl < entry) { target = (found ? MathMin(target, lvl) : lvl); found = true; }
        }
      if(!found)
         tp = (dir > 0) ? (entry + InpRR * slDist) : (entry - InpRR * slDist);
      else
        {
         tp = (dir > 0) ? (target - InpTpBufferAtr * atr) : (target + InpTpBufferAtr * atr);
         double rr = MathAbs(tp - entry) / slDist;
         if(rr < InpMinRR)
           {
            st.rejRR++;
            Log(StringFormat("Tolak: RR ke liquidity %.2f < InpMinRR %.2f", rr, InpMinRR));
            return false;
           }
         if(rr > InpMaxRR)
            tp = (dir > 0) ? (entry + InpMaxRR * slDist) : (entry - InpMaxRR * slDist);
        }
     }

   // --- kompensasi spread untuk SELL (SELL ditutup di Ask, chart = Bid)
   if(InpSpreadCompensate && dir < 0 && spr > 0.0)
     {
      sl += spr;
      tp += spr;
      slDist = MathAbs(entry - sl);
     }

   // --- filter spread
   if(InpMaxSpreadPts > 0 && spr > InpMaxSpreadPts * gPoint)
     {
      st.rejSpread++;
      Log(StringFormat("Tolak: spread %.0f pts > maks %d pts", spr / gPoint, InpMaxSpreadPts));
      return false;
     }
   if(InpMaxSpreadRiskPct > 0.0 && slDist > 0.0 && spr / slDist * 100.0 > InpMaxSpreadRiskPct)
     {
      st.rejSpread++;
      Log(StringFormat("Tolak: spread %.1f%% dari jarak SL > maks %.1f%%", spr / slDist * 100.0, InpMaxSpreadRiskPct));
      return false;
     }

   // --- lot & risiko
   double vpl    = PricePerLot();
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lot;
   if(InpLotMode == LOT_RISK_PERCENT && vpl > 0.0 && slDist > 0.0)
      lot = NormLot(equity * InpRiskPercent / 100.0 / (slDist * vpl));
   else
      lot = NormLot(InpLot);

   double riskMoney = slDist * vpl * lot;
   double riskPct   = (equity > 0.0) ? riskMoney / equity * 100.0 : 0.0;
   if(InpMaxRiskPct > 0.0 && riskPct > InpMaxRiskPct)
     {
      st.rejRisk++;
      Log(StringFormat("Tolak: risiko %.1f%% equity > maks %.1f%%", riskPct, InpMaxRiskPct));
      return false;
     }

   s.dir       = dir;
   s.entry     = NormalizeDouble(entry, gDigits);
   s.sl        = NormalizeDouble(sl, gDigits);
   s.tp        = NormalizeDouble(tp, gDigits);
   s.atr       = atr;
   s.lot       = lot;
   s.riskMoney = riskMoney;
   s.riskPct   = riskPct;
   return true;
  }

//+------------------------------------------------------------------+
//| Eksekusi                                                          |
//+------------------------------------------------------------------+
void DrawArrow(const Signal &s)
  {
   if(!InpDrawObjects || gOptimizing)
      return;
   string nm = OBJ_PREFIX + "e" + (string)barCount;
   if(!ObjectCreate(0, nm, OBJ_ARROW, 0, iTime(_Symbol, _Period, 0), s.entry))
      return;
   ObjectSetInteger(0, nm, OBJPROP_ARROWCODE, s.dir > 0 ? 233 : 234);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, s.dir > 0 ? clrDodgerBlue : clrOrangeRed);
   ObjectSetInteger(0, nm, OBJPROP_WIDTH, 2);
  }

bool Execute(Signal &s)
  {
   string side = (s.dir > 0 ? "BUY" : "SELL");
   bool ok;
   if(InpEntryMode == ENTRY_MARKET)
     {
      ok = (s.dir > 0) ? trade.Buy(s.lot, _Symbol, 0.0, s.sl, s.tp, "StochMacd")
                       : trade.Sell(s.lot, _Symbol, 0.0, s.sl, s.tp, "StochMacd");
     }
   else
     {
      ok = (s.dir > 0) ? trade.BuyLimit(s.lot, s.entry, _Symbol, s.sl, s.tp, ORDER_TIME_GTC, 0, "StochMacd")
                       : trade.SellLimit(s.lot, s.entry, _Symbol, s.sl, s.tp, ORDER_TIME_GTC, 0, "StochMacd");
      if(ok)
        {
         pendingTicket = trade.ResultOrder();
         pendingBar    = barCount;
        }
     }

   if(!ok)
     {
      st.rejOrder++;
      PrintFormat("%s GAGAL: ret=%d %s | entry=%.*f sl=%.*f tp=%.*f lot=%.2f",
                  side, trade.ResultRetcode(), trade.ResultRetcodeDescription(),
                  gDigits, s.entry, gDigits, s.sl, gDigits, s.tp, s.lot);
      return false;
     }

   st.exec++;
   lastEntryBar = barCount;
   DrawArrow(s);
   PrintFormat("%s%s lot %.2f | entry=%.*f sl=%.*f tp=%.*f | SL=%.3f (%.2f x ATR) RR=%.2f | risiko $%.2f = %.1f%%",
               side, (InpEntryMode == ENTRY_LIMIT ? " LIMIT" : ""), s.lot,
               gDigits, s.entry, gDigits, s.sl, gDigits, s.tp,
               MathAbs(s.entry - s.sl), (s.atr > 0 ? MathAbs(s.entry - s.sl) / s.atr : 0.0),
               (MathAbs(s.entry - s.sl) > 0 ? MathAbs(s.tp - s.entry) / MathAbs(s.entry - s.sl) : 0.0),
               s.riskMoney, s.riskPct);
   if(s.riskPct > 3.0)
      PrintFormat("PERINGATAN risiko: %.1f%% equity dalam satu trade (lot minimum vs modal kecil).", s.riskPct);
   return true;
  }

//+------------------------------------------------------------------+
//| Manajemen posisi terbuka                                          |
//+------------------------------------------------------------------+
void ManagePositions(double atr, const double &k[])
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      long   type  = PositionGetInteger(POSITION_TYPE);
      int    dir   = (type == POSITION_TYPE_BUY ? 1 : -1);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      double cur   = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                               : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double risk0 = MathAbs(open - sl);
      if(risk0 <= 0.0)
         risk0 = atr;
      double rr    = (cur - open) * dir / risk0;

      // --- keluar karena umur posisi
      if(InpMaxBarsInTrade > 0)
        {
         datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
         int bars = Bars(_Symbol, _Period, opened, TimeCurrent());
         if(bars > InpMaxBarsInTrade)
           {
            trade.PositionClose(tk);
            Log(StringFormat("Tutup #%I64u: melewati %d bar", tk, InpMaxBarsInTrade));
            continue;
           }
        }

      // --- keluar karena Stochastic sampai zona lawan
      if(InpExitOnStochExt)
        {
         if((dir > 0 && k[1] > InpStochOB) || (dir < 0 && k[1] < InpStochOS))
           {
            trade.PositionClose(tk);
            Log(StringFormat("Tutup #%I64u: Stochastic %.1f mencapai zona lawan", tk, k[1]));
            continue;
           }
        }

      double newSl = sl;

      // --- break even
      if(InpBreakEvenRR > 0.0 && rr >= InpBreakEvenRR)
        {
         double be = open + dir * InpBeOffsetAtr * atr;
         if((dir > 0 && be > newSl) || (dir < 0 && (newSl == 0.0 || be < newSl)))
            newSl = be;
        }

      // --- trailing
      if(InpTrailAtr > 0.0 && rr >= InpTrailStartRR)
        {
         double tr = cur - dir * InpTrailAtr * atr;
         if((dir > 0 && tr > newSl) || (dir < 0 && (newSl == 0.0 || tr < newSl)))
            newSl = tr;
        }

      if(MathAbs(newSl - sl) > gPoint * 0.5)
        {
         double stops = StopsLevelPrice();
         if(MathAbs(cur - newSl) > stops)
            trade.PositionModify(tk, NormalizeDouble(newSl, gDigits), tp);
        }
     }
  }

void CloseOppositeIfNeeded(int newDir)
  {
   if(!InpExitOnOpposite)
      return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      int dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1);
      if(dir != newDir)
        {
         trade.PositionClose(tk);
         Log(StringFormat("Tutup #%I64u: muncul sinyal berlawanan", tk));
        }
     }
  }

// hapus limit yang kadaluarsa / sudah tidak relevan
void ManagePending()
  {
   if(pendingTicket == 0)
      return;
   if(!OrderSelect(pendingTicket))
     {
      pendingTicket = 0;                 // sudah terisi atau hilang
      return;
     }
   if(barCount - pendingBar >= InpEntryValidBars)
     {
      trade.OrderDelete(pendingTicket);
      Log(StringFormat("Limit #%I64u dihapus: lewat %d bar", pendingTicket, InpEntryValidBars));
      pendingTicket = 0;
     }
  }

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
  {
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(hAtr, 0, 0, 3, atrBuf) < 3)
      return;
   double atr = atrBuf[1];
   if(atr <= 0.0)
      return;

   int need = InpConfluenceBars + 3;
   double main[], sig[], k[], d[];
   ArraySetAsSeries(main, true); ArraySetAsSeries(sig, true);
   ArraySetAsSeries(k, true);    ArraySetAsSeries(d, true);
   if(CopyBuffer(hMacd,  0, 0, need, main) < need) return;
   if(CopyBuffer(hMacd,  1, 0, need, sig)  < need) return;
   if(CopyBuffer(hStoch, 0, 0, need, k)    < need) return;
   if(CopyBuffer(hStoch, 1, 0, need, d)    < need) return;

   ManagePositions(atr, k);

   // --- hanya bekerja sekali per bar baru
   datetime t0 = iTime(_Symbol, _Period, 0);
   if(t0 == lastBarTime)
      return;
   lastBarTime = t0;
   barCount++;
   st.bars++;

   ManagePending();

   // --- sinyal
   int dir = 0;
   if(DirectionSignal(1, main, sig, k, d, atr))
      dir = 1;
   else
      if(DirectionSignal(-1, main, sig, k, d, atr))
         dir = -1;
   if(dir == 0)
      return;

   if(dir > 0) st.sigBuy++;
   else        st.sigSell++;

   // --- filter tren EMA
   if(InpUseEma)
     {
      double ema[];
      ArraySetAsSeries(ema, true);
      if(CopyBuffer(hEma, 0, 0, 3, ema) < 3)
         return;
      double c1 = iClose(_Symbol, _Period, 1);
      if((dir > 0 && c1 < ema[1]) || (dir < 0 && c1 > ema[1]))
        {
         st.rejTrend++;
         Log(StringFormat("Tolak %s: melawan EMA%d", (dir > 0 ? "BUY" : "SELL"), InpEmaPeriod));
         return;
        }
     }

   // --- sesi
   if(InpUseSession)
     {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      bool inSess = (InpStartHour <= InpEndHour)
                    ? (dt.hour >= InpStartHour && dt.hour < InpEndHour)
                    : (dt.hour >= InpStartHour || dt.hour < InpEndHour);
      if(!inSess)
        {
         st.rejSession++;
         return;
        }
     }

   // --- cooldown
   if(barCount - lastEntryBar < InpCooldownBars)
     {
      st.rejCooldown++;
      return;
     }

   // --- tutup posisi lawan dulu (setelah semua filter lolos), baru cek kapasitas
   CloseOppositeIfNeeded(dir);

   // --- kapasitas
   if(CountOwnPositions() + CountOwnOrders() >= InpMaxOpenTrades)
     {
      st.rejOpen++;
      return;
     }

   Signal s;
   ZeroMemory(s);
   if(!BuildSetup(dir, atr, s))
      return;

   Execute(s);
  }
//+------------------------------------------------------------------+
