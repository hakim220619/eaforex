//+------------------------------------------------------------------+
//|                                               EmaPullback_EA.mq5 |
//|  Strategi trend-following + pullback EMA untuk M5 dengan         |
//|  Risk/Reward tetap (1:1, 1:2, atau bebas):                       |
//|                                                                  |
//|   1. Filter tren : EMA cepat vs EMA lambat (default 50 vs 200).  |
//|      Uptrend  -> hanya cari BUY. Downtrend -> hanya cari SELL.   |
//|   2. Trigger    : harga pullback menyentuh EMA pullback          |
//|      (default 21) lalu candle ditutup kembali searah tren.       |
//|   3. SL         : berbasis ATR (default 1.5 x ATR14) atau        |
//|      swing high/low terakhir -- bukan angka tetap.               |
//|   4. TP         : RR x jarak SL (InpRR = 1.0 -> 1:1, 2.0 -> 1:2) |
//|   5. Lot        : tetap, atau otomatis dari % risiko equity.     |
//|   6. Opsional   : breakeven setelah profit mencapai N x SL.      |
//+------------------------------------------------------------------+
#property copyright "forexbot"
#property version   "1.00"
#property description "EMA pullback M5: filter tren EMA50/200, entry pullback EMA21, SL ATR/swing, TP = RR x SL"

#include <Trade/Trade.mqh>

enum ENUM_LOT_MODE
  {
   LOT_FIXED        = 0,  // Lot tetap (InpLot)
   LOT_RISK_PERCENT = 1   // Otomatis dari % risiko equity (InpRiskPercent)
  };

enum ENUM_SL_MODE
  {
   SL_ATR   = 0,          // SL = ATR x multiplier
   SL_SWING = 1           // SL = swing high/low N candle terakhir + buffer
  };

input group "=== Umum ==="
input long          InpMagic         = 20260811;  // Magic number
input ENUM_LOT_MODE InpLotMode       = LOT_FIXED; // Mode lot
input double        InpLot           = 0.01;      // Lot tetap (minimal)
input double        InpRiskPercent   = 1.0;       // Risiko per trade (% equity, mode risk percent)
input int           InpMaxSpreadPts  = 60;        // Spread maksimal (points), 0 = abaikan

input group "=== Sinyal EMA Pullback ==="
input int           InpEmaTrendFast  = 50;        // Periode EMA tren cepat
input int           InpEmaTrendSlow  = 200;       // Periode EMA tren lambat
input int           InpEmaPullback   = 21;        // Periode EMA area pullback
input bool          InpNeedReversal  = true;      // Wajib candle reversal searah tren

input group "=== Risk / Reward ==="
input double        InpRR            = 2.0;       // RR: TP = RR x jarak SL (1.0 = 1:1, 2.0 = 1:2)
input ENUM_SL_MODE  InpSLMode        = SL_ATR;    // Mode penentuan SL
input int           InpATRPeriod     = 14;        // Periode ATR
input double        InpATRMult       = 1.5;       // Multiplier ATR untuk SL
input int           InpSwingBars     = 10;        // Jumlah candle swing high/low (mode swing)
input int           InpSLBufferPts   = 30;        // Buffer tambahan di belakang swing (points)
input double        InpBreakEvenRR   = 0.0;       // Geser SL ke entry setelah profit N x SL (0 = nonaktif)

input group "=== Batasan ==="
input int           InpMaxOpenTrades = 1;         // Maksimal posisi terbuka bersamaan
input int           InpStartHour     = 0;         // Jam mulai (server, 0-23)
input int           InpEndHour       = 0;         // Jam berhenti (start = end -> 24 jam)

//--- global
CTrade   trade;
datetime g_lastBar    = 0;
int      g_hEmaFast   = INVALID_HANDLE;
int      g_hEmaSlow   = INVALID_HANDLE;
int      g_hEmaPull   = INVALID_HANDLE;
int      g_hATR       = INVALID_HANDLE;

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(30);

   g_hEmaFast = iMA(_Symbol, PERIOD_CURRENT, InpEmaTrendFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaSlow = iMA(_Symbol, PERIOD_CURRENT, InpEmaTrendSlow, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaPull = iMA(_Symbol, PERIOD_CURRENT, InpEmaPullback, 0, MODE_EMA, PRICE_CLOSE);
   g_hATR     = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);

   if(g_hEmaFast == INVALID_HANDLE || g_hEmaSlow == INVALID_HANDLE ||
      g_hEmaPull == INVALID_HANDLE || g_hATR == INVALID_HANDLE)
     {
      Print("Gagal membuat handle indikator");
      return(INIT_FAILED);
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
   // breakeven dicek setiap tick supaya responsif
   if(InpBreakEvenRR > 0)
      ManageBreakEven();

   bool newBar = IsNewBar();

   int    posCount = 0;
   double basket   = 0.0;
   CountMyPositions(posCount, basket);

   if(newBar && posCount < InpMaxOpenTrades && EntryAllowed())
      CheckSignalAndTrade();

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
//| Ambil satu nilai buffer indikator                                |
//+------------------------------------------------------------------+
double BufValue(int handle, int shift)
  {
   double v[];
   if(CopyBuffer(handle, 0, shift, 1, v) != 1)
      return(EMPTY_VALUE);
   return(v[0]);
  }

//+------------------------------------------------------------------+
//| Cek sinyal di candle yang baru ditutup, lalu entry               |
//+------------------------------------------------------------------+
void CheckSignalAndTrade()
  {
   double emaFast = BufValue(g_hEmaFast, 1);
   double emaSlow = BufValue(g_hEmaSlow, 1);
   double emaPull = BufValue(g_hEmaPull, 1);
   double atr     = BufValue(g_hATR, 1);
   if(emaFast == EMPTY_VALUE || emaSlow == EMPTY_VALUE ||
      emaPull == EMPTY_VALUE || atr == EMPTY_VALUE)
      return; // data indikator belum siap

   double o1 = iOpen(_Symbol, PERIOD_CURRENT, 1);
   double c1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double l1 = iLow(_Symbol, PERIOD_CURRENT, 1);
   double h1 = iHigh(_Symbol, PERIOD_CURRENT, 1);

   bool upTrend   = (emaFast > emaSlow) && (c1 > emaSlow);
   bool downTrend = (emaFast < emaSlow) && (c1 < emaSlow);

   // BUY: uptrend + candle menyentuh EMA pullback + ditutup kembali di atasnya
   bool buySignal  = upTrend && (l1 <= emaPull) && (c1 > emaPull)
                     && (!InpNeedReversal || c1 > o1);

   // SELL: downtrend + candle menyentuh EMA pullback + ditutup kembali di bawahnya
   bool sellSignal = downTrend && (h1 >= emaPull) && (c1 < emaPull)
                     && (!InpNeedReversal || c1 < o1);

   if(buySignal)
      OpenTrade(true, atr);
   else if(sellSignal)
      OpenTrade(false, atr);
  }

//+------------------------------------------------------------------+
//| Buka posisi dengan SL berbasis ATR/swing dan TP = RR x SL        |
//+------------------------------------------------------------------+
void OpenTrade(bool isBuy, double atr)
  {
   long   stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double entry = isBuy ? ask : bid;
   double sl;

   if(InpSLMode == SL_ATR)
     {
      double dist = atr * InpATRMult;
      sl = isBuy ? entry - dist : entry + dist;
     }
   else // SL_SWING
     {
      if(isBuy)
        {
         int idx = iLowest(_Symbol, PERIOD_CURRENT, MODE_LOW, InpSwingBars, 1);
         sl = iLow(_Symbol, PERIOD_CURRENT, idx) - InpSLBufferPts * _Point;
        }
      else
        {
         int idx = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, InpSwingBars, 1);
         sl = iHigh(_Symbol, PERIOD_CURRENT, idx) + InpSLBufferPts * _Point;
        }
     }

   // pastikan jarak SL memenuhi aturan minimum broker
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

   double lot = CalcLot(slDist / _Point);

   bool ok = isBuy
             ? trade.Buy(lot, _Symbol, 0, sl, tp, "ema pullback")
             : trade.Sell(lot, _Symbol, 0, sl, tp, "ema pullback");
   if(!ok)
      Print("Gagal open ", (isBuy ? "BUY" : "SELL"), ": ",
            trade.ResultRetcodeDescription());
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
//| Helper: normalisasi lot sesuai aturan broker                     |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
  {
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step > 0)
      lot = MathFloor(lot / step) * step; // dibulatkan ke bawah agar risiko tidak lebih besar

   lot = MathMax(minLot, MathMin(lot, maxLot));
   return(NormalizeDouble(lot, 2));
  }

//+------------------------------------------------------------------+
//| Tampilan status di chart                                         |
//+------------------------------------------------------------------+
void UpdateComment(int posCount, double basket)
  {
   double emaFast = BufValue(g_hEmaFast, 1);
   double emaSlow = BufValue(g_hEmaSlow, 1);

   string tren = "netral / data belum siap";
   if(emaFast != EMPTY_VALUE && emaSlow != EMPTY_VALUE)
      tren = (emaFast > emaSlow) ? "UPTREND (cari BUY)" : "DOWNTREND (cari SELL)";

   string s = "=== EmaPullback EA ===\n";
   s += "Tren          : " + tren + "\n";
   s += "Posisi        : " + IntegerToString(posCount)
      + " / " + IntegerToString(InpMaxOpenTrades) + "\n";
   s += "Floating P/L  : " + DoubleToString(basket, 2) + " USD\n";
   s += "RR            : 1 : " + DoubleToString(InpRR, 1) + "\n";
   Comment(s);
  }
//+------------------------------------------------------------------+
