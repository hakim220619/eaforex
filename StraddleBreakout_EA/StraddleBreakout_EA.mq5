//+------------------------------------------------------------------+
//|                                          StraddleBreakout_EA.mq5 |
//|  EA breakout dua arah (straddle) sesuai screenshot XAUUSD M1:    |
//|   1. Pasang BUY STOP di atas harga dan SELL STOP di bawah harga  |
//|      (mengurung harga dari dua sisi)                             |
//|   2. Masing-masing pending order membawa SL di sisi berlawanan   |
//|      dan TP opsional                                             |
//|   3. Selama belum ada yang tereksekusi, kedua pending digeser    |
//|      mengikuti harga setiap candle baru (recenter)               |
//|   4. Saat salah satu tereksekusi, pending lawan dihapus (OCO)    |
//|   5. Setelah posisi selesai (kena SL/TP), straddle baru dipasang |
//|      di candle berikutnya                                        |
//+------------------------------------------------------------------+
#property copyright "forexbot"
#property version   "1.00"
#property description "Straddle breakout: BUY STOP + SELL STOP mengurung harga, OCO, recenter per candle"

#include <Trade/Trade.mqh>

input group "=== Umum ==="
input long   InpMagic        = 20260806;  // Magic number
input double InpLot          = 0.01;      // Lot per order (minimal; di screenshot: 0.5)
input int    InpMaxSpreadPts = 60;        // Spread maksimal (points), 0 = abaikan

input group "=== Jarak Order (points; GOLD: 100 pts = $1.00) ==="
input int    InpDistPts      = 80;        // Jarak BUY/SELL STOP dari harga
input int    InpSLPts        = 160;       // Jarak SL dari harga pending (default = tepat di level order lawan)
input int    InpTPPts        = 240;       // Jarak TP dari harga pending (0 = tanpa TP)

input group "=== Perilaku ==="
input bool   InpRecenter        = true;   // Geser ulang straddle mengikuti harga tiap candle baru
input int    InpRecenterMinPts  = 20;     // Geser hanya jika perubahan >= sekian points
input bool   InpDeleteOpposite  = true;   // Hapus pending lawan saat salah satu tereksekusi (OCO)
input int    InpTrailPts        = 0;      // Trailing stop posisi aktif (points, 0 = nonaktif)
input int    InpTrailStepPts    = 20;     // Langkah minimal trailing

input group "=== Filter Waktu (jam server, 0-23; start = end -> nonaktif) ==="
input int    InpStartHour    = 0;         // Jam mulai pasang straddle
input int    InpEndHour      = 0;         // Jam berhenti pasang straddle

//--- global
CTrade   trade;
datetime g_lastBar = 0;   // deteksi candle baru

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

   int    posCount  = 0;
   double basket    = 0.0;
   CountMyPositions(posCount, basket);
   int pendings = CountMyPendings();

   if(posCount > 0)
     {
      // salah satu stop sudah tereksekusi
      if(InpDeleteOpposite && pendings > 0)
         DeleteMyPendings();

      if(InpTrailPts > 0)
         TrailPositions();
     }
   else
     {
      if(pendings == 2)
        {
         // straddle masih utuh -> geser mengikuti harga di candle baru
         if(InpRecenter && newBar)
            RecenterStraddle();
        }
      else if(pendings == 1)
        {
         // sisa satu pending (posisi sudah selesai / lawan terhapus)
         // bereskan supaya straddle baru bisa dipasang lengkap
         DeleteMyPendings();
        }
      else // tidak ada pending sama sekali
        {
         if(newBar && EntryAllowed())
            PlaceStraddle();
        }
     }

   UpdateComment(posCount, pendings, basket);
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
//| Filter waktu & spread                                            |
//+------------------------------------------------------------------+
bool EntryAllowed()
  {
   // filter jam server
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

   // filter spread
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
//| Pasang sepasang pending: BUY STOP atas + SELL STOP bawah         |
//+------------------------------------------------------------------+
void PlaceStraddle()
  {
   long   stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    dist = (int)MathMax(InpDistPts, stopsLevel + 1);

   double buyPrice  = NormalizeDouble(ask + dist * _Point, _Digits);
   double sellPrice = NormalizeDouble(bid - dist * _Point, _Digits);

   double buySL  = NormalizeDouble(InpSLPts > 0 ? buyPrice - InpSLPts * _Point : sellPrice, _Digits);
   double sellSL = NormalizeDouble(InpSLPts > 0 ? sellPrice + InpSLPts * _Point : buyPrice, _Digits);
   double buyTP  = (InpTPPts > 0) ? NormalizeDouble(buyPrice + InpTPPts * _Point, _Digits) : 0.0;
   double sellTP = (InpTPPts > 0) ? NormalizeDouble(sellPrice - InpTPPts * _Point, _Digits) : 0.0;

   double lot = NormalizeLot(InpLot);

   if(!trade.BuyStop(lot, buyPrice, _Symbol, buySL, buyTP, ORDER_TIME_GTC, 0, "straddle"))
      Print("Gagal pasang BUY STOP: ", trade.ResultRetcodeDescription());
   if(!trade.SellStop(lot, sellPrice, _Symbol, sellSL, sellTP, ORDER_TIME_GTC, 0, "straddle"))
      Print("Gagal pasang SELL STOP: ", trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Geser kedua pending mengikuti harga terkini                      |
//+------------------------------------------------------------------+
void RecenterStraddle()
  {
   long   stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    dist = (int)MathMax(InpDistPts, stopsLevel + 1);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      double oldPrice = OrderGetDouble(ORDER_PRICE_OPEN);

      if(type == ORDER_TYPE_BUY_STOP)
        {
         double newPrice = NormalizeDouble(ask + dist * _Point, _Digits);
         if(MathAbs(newPrice - oldPrice) < InpRecenterMinPts * _Point)
            continue;

         double sl = NormalizeDouble(InpSLPts > 0 ? newPrice - InpSLPts * _Point
                                                  : bid - dist * _Point, _Digits);
         double tp = (InpTPPts > 0) ? NormalizeDouble(newPrice + InpTPPts * _Point, _Digits) : 0.0;

         if(!trade.OrderModify(ticket, newPrice, sl, tp, ORDER_TIME_GTC, 0))
            Print("Gagal geser BUY STOP: ", trade.ResultRetcodeDescription());
        }
      else if(type == ORDER_TYPE_SELL_STOP)
        {
         double newPrice = NormalizeDouble(bid - dist * _Point, _Digits);
         if(MathAbs(newPrice - oldPrice) < InpRecenterMinPts * _Point)
            continue;

         double sl = NormalizeDouble(InpSLPts > 0 ? newPrice + InpSLPts * _Point
                                                  : ask + dist * _Point, _Digits);
         double tp = (InpTPPts > 0) ? NormalizeDouble(newPrice - InpTPPts * _Point, _Digits) : 0.0;

         if(!trade.OrderModify(ticket, newPrice, sl, tp, ORDER_TIME_GTC, 0))
            Print("Gagal geser SELL STOP: ", trade.ResultRetcodeDescription());
        }
     }
  }

//+------------------------------------------------------------------+
//| Trailing stop untuk posisi aktif                                 |
//+------------------------------------------------------------------+
void TrailPositions()
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

      if(type == POSITION_TYPE_BUY)
        {
         if(bid - entry < InpTrailPts * _Point)
            continue; // belum cukup profit
         double newSL = NormalizeDouble(bid - InpTrailPts * _Point, _Digits);
         if(sl == 0.0 || newSL >= sl + InpTrailStepPts * _Point)
            if(!trade.PositionModify(ticket, newSL, tp))
               Print("Gagal trailing BUY: ", trade.ResultRetcodeDescription());
        }
      else // SELL
        {
         if(entry - ask < InpTrailPts * _Point)
            continue;
         double newSL = NormalizeDouble(ask + InpTrailPts * _Point, _Digits);
         if(sl == 0.0 || newSL <= sl - InpTrailStepPts * _Point)
            if(!trade.PositionModify(ticket, newSL, tp))
               Print("Gagal trailing SELL: ", trade.ResultRetcodeDescription());
        }
     }
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
      lot = MathRound(lot / step) * step;

   lot = MathMax(minLot, MathMin(lot, maxLot));
   return(NormalizeDouble(lot, 2));
  }

//+------------------------------------------------------------------+
//| Tampilan status di chart                                         |
//+------------------------------------------------------------------+
void UpdateComment(int posCount, int pendings, double basket)
  {
   string s = "=== StraddleBreakout EA ===\n";
   if(posCount > 0)
      s += "Status        : POSISI AKTIF (" + IntegerToString(posCount) + ")\n"
         + "Floating P/L  : " + DoubleToString(basket, 2) + " USD\n";
   else if(pendings == 2)
      s += "Status        : straddle terpasang, menunggu breakout\n";
   else
      s += "Status        : menunggu pasang straddle (candle baru)\n";
   s += "Lot           : " + DoubleToString(InpLot, 2) + "\n";
   Comment(s);
  }
//+------------------------------------------------------------------+
