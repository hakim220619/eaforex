//+------------------------------------------------------------------+
//|                                              RapidScalper_EA.mq5 |
//|  EA scalping cepat sesuai screenshot XAUUSD M1 (panah buy/sell   |
//|  di hampir setiap candle + pending stop mengurung harga):        |
//|   1. Setiap candle baru, buka posisi scalp mengikuti arah        |
//|      candle sebelumnya (bisa dibalik jadi counter-trend)         |
//|   2. Posisi scalp keluar cepat: TP/SL kecil, atau dipaksa        |
//|      tutup setelah N candle                                      |
//|   3. Opsional: straddle BUY STOP + SELL STOP (dengan SL/TP)      |
//|      tetap mengurung harga untuk menangkap breakout, digeser     |
//|      ulang setiap candle, OCO saat salah satu tereksekusi        |
//+------------------------------------------------------------------+
#property copyright "forexbot"
#property version   "1.00"
#property description "Scalping tiap candle M1 + straddle breakout opsional (lot default 0.13)"

#include <Trade/Trade.mqh>

input group "=== Umum ==="
input long   InpMagic        = 20260730;  // Magic number
input double InpLot          = 0.01;      // Lot per order (minimal; di screenshot: 0.13)
input int    InpMaxSpreadPts = 60;        // Spread maksimal (points), 0 = abaikan

input group "=== Scalping (entry tiap candle baru) ==="
input bool   InpFollowCandle   = true;    // true: ikuti arah candle sebelumnya, false: lawan arah
input int    InpMaxOpenScalps  = 1;       // Maksimal posisi scalp terbuka bersamaan
input int    InpTPPts          = 50;      // TP scalp (points; GOLD: 50 = $0.50)
input int    InpSLPts          = 100;     // SL scalp (points; 0 = tanpa SL, TIDAK disarankan)
input int    InpCloseAfterBars = 3;       // Paksa tutup scalp setelah N candle (0 = nonaktif)

input group "=== Straddle Breakout (opsional) ==="
input bool   InpUseStraddle     = true;   // Pasang BUY STOP + SELL STOP mengurung harga
input int    InpStraddleDistPts = 150;    // Jarak stop order dari harga (points)
input int    InpStraddleSLPts   = 300;    // SL order straddle (points)
input int    InpStraddleTPPts   = 450;    // TP order straddle (points, 0 = tanpa TP)

input group "=== Filter Waktu (jam server, 0-23; start = end -> nonaktif) ==="
input int    InpStartHour = 0;            // Jam mulai trading
input int    InpEndHour   = 0;            // Jam berhenti trading

//--- global
CTrade   trade;
datetime g_lastBar = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(30);
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
   bool newBar = IsNewBar();

   int    scalps = 0, straddles = 0;
   double basket = 0.0;
   CountMyPositions(scalps, straddles, basket);
   int pendings = CountMyPendings();

   // OCO: kalau tinggal satu pending, berarti sisi lain sudah tereksekusi
   if(pendings == 1)
     {
      DeleteMyPendings();
      pendings = 0;
     }

   if(newBar)
     {
      // paksa tutup scalp yang sudah kelamaan nyangkut
      if(InpCloseAfterBars > 0)
         CloseExpiredScalps();

      if(EntryAllowed())
        {
         CountMyPositions(scalps, straddles, basket); // hitung ulang setelah penutupan

         // 1. entry scalp mengikuti arah candle sebelumnya
         if(scalps < InpMaxOpenScalps)
            ScalpEntry();

         // 2. pasang ulang straddle (recenter) selama tidak ada
         //    posisi hasil straddle yang masih terbuka
         if(InpUseStraddle && straddles == 0)
           {
            DeleteMyPendings();
            PlaceStraddle();
           }
        }
     }

   UpdateComment(scalps, straddles, pendings, basket);
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
//| Entry scalp: ikuti (atau lawan) arah candle yang baru ditutup    |
//+------------------------------------------------------------------+
void ScalpEntry()
  {
   double o = iOpen(_Symbol, PERIOD_CURRENT, 1);
   double c = iClose(_Symbol, PERIOD_CURRENT, 1);
   if(c == o)
      return; // doji, tidak ada arah

   bool bullish = (c > o);
   bool goBuy   = InpFollowCandle ? bullish : !bullish;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lot = NormalizeLot(InpLot);

   if(goBuy)
     {
      double sl = (InpSLPts > 0) ? NormalizeDouble(ask - InpSLPts * _Point, _Digits) : 0.0;
      double tp = (InpTPPts > 0) ? NormalizeDouble(ask + InpTPPts * _Point, _Digits) : 0.0;
      if(!trade.Buy(lot, _Symbol, 0, sl, tp, "scalp"))
         Print("Gagal BUY scalp: ", trade.ResultRetcodeDescription());
     }
   else
     {
      double sl = (InpSLPts > 0) ? NormalizeDouble(bid + InpSLPts * _Point, _Digits) : 0.0;
      double tp = (InpTPPts > 0) ? NormalizeDouble(bid - InpTPPts * _Point, _Digits) : 0.0;
      if(!trade.Sell(lot, _Symbol, 0, sl, tp, "scalp"))
         Print("Gagal SELL scalp: ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Pasang straddle: BUY STOP atas + SELL STOP bawah (dengan SL/TP)  |
//+------------------------------------------------------------------+
void PlaceStraddle()
  {
   long   stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    dist = (int)MathMax(InpStraddleDistPts, stopsLevel + 1);

   double buyPrice  = NormalizeDouble(ask + dist * _Point, _Digits);
   double sellPrice = NormalizeDouble(bid - dist * _Point, _Digits);

   double buySL  = (InpStraddleSLPts > 0) ? NormalizeDouble(buyPrice - InpStraddleSLPts * _Point, _Digits) : 0.0;
   double sellSL = (InpStraddleSLPts > 0) ? NormalizeDouble(sellPrice + InpStraddleSLPts * _Point, _Digits) : 0.0;
   double buyTP  = (InpStraddleTPPts > 0) ? NormalizeDouble(buyPrice + InpStraddleTPPts * _Point, _Digits) : 0.0;
   double sellTP = (InpStraddleTPPts > 0) ? NormalizeDouble(sellPrice - InpStraddleTPPts * _Point, _Digits) : 0.0;

   double lot = NormalizeLot(InpLot);

   if(!trade.BuyStop(lot, buyPrice, _Symbol, buySL, buyTP, ORDER_TIME_GTC, 0, "straddle"))
      Print("Gagal pasang BUY STOP: ", trade.ResultRetcodeDescription());
   if(!trade.SellStop(lot, sellPrice, _Symbol, sellSL, sellTP, ORDER_TIME_GTC, 0, "straddle"))
      Print("Gagal pasang SELL STOP: ", trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Tutup posisi scalp yang sudah terbuka >= N candle                |
//+------------------------------------------------------------------+
void CloseExpiredScalps()
  {
   int maxAge = InpCloseAfterBars * PeriodSeconds(PERIOD_CURRENT);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(StringFind(PositionGetString(POSITION_COMMENT), "scalp") < 0)
         continue; // hanya posisi scalp, posisi straddle dibiarkan ke SL/TP

      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      if(TimeCurrent() - opened >= maxAge)
         if(!trade.PositionClose(ticket))
            Print("Gagal tutup scalp #", ticket, ": ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Helper: hitung posisi milik EA (dipisah scalp vs straddle)       |
//+------------------------------------------------------------------+
void CountMyPositions(int &scalps, int &straddles, double &profit)
  {
   scalps    = 0;
   straddles = 0;
   profit    = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      profit += PositionGetDouble(POSITION_PROFIT)
              + PositionGetDouble(POSITION_SWAP);

      // broker tertentu mengubah komentar; kalau tidak dikenali,
      // anggap scalp supaya tetap terkena batas InpMaxOpenScalps
      if(StringFind(PositionGetString(POSITION_COMMENT), "straddle") >= 0)
         straddles++;
      else
         scalps++;
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
      lot = MathRound(lot / step) * step;

   lot = MathMax(minLot, MathMin(lot, maxLot));
   return(NormalizeDouble(lot, 2));
  }

//+------------------------------------------------------------------+
//| Tampilan status di chart                                         |
//+------------------------------------------------------------------+
void UpdateComment(int scalps, int straddles, int pendings, double basket)
  {
   string s = "=== RapidScalper EA ===\n";
   s += "Posisi scalp     : " + IntegerToString(scalps)
      + " / " + IntegerToString(InpMaxOpenScalps) + "\n";
   s += "Posisi straddle  : " + IntegerToString(straddles) + "\n";
   s += "Pending straddle : " + IntegerToString(pendings) + "\n";
   s += "Floating P/L     : " + DoubleToString(basket, 2) + " USD\n";
   s += "Lot              : " + DoubleToString(InpLot, 2) + "\n";
   Comment(s);
  }
//+------------------------------------------------------------------+
