//+------------------------------------------------------------------+
//|                                             GoldTrailStop_EA.mq5 |
//|  EA berdasarkan pola trading pada screenshot MT5 (GOLD M5):      |
//|   1. Buka posisi BUY                                             |
//|   2. Pasang pending SELL STOP (lot sama) di bawah harga sebagai  |
//|      proteksi / pengunci profit                                  |
//|   3. SELL STOP di-trailing naik mengikuti harga saat posisi      |
//|      profit, sehingga profit terkunci                            |
//|   4. Semua ditutup saat target profit (USD) tercapai atau stop   |
//|      tersentuh                                                   |
//|   5. Lot naik bertahap setelah siklus profit (mis. 0.04 -> 0.05) |
//|                                                                  |
//|  Catatan: berfungsi di akun hedging maupun netting. Di akun      |
//|  hedging, saat SELL STOP tereksekusi posisi menjadi terkunci     |
//|  (lock) dan EA langsung menutup keduanya untuk merealisasikan    |
//|  hasil.                                                          |
//+------------------------------------------------------------------+
#property copyright "forexbot"
#property version   "1.00"
#property description "BUY + trailing SELL STOP protection, target profit dalam USD"

#include <Trade/Trade.mqh>

//--- mode entry
enum ENUM_ENTRY_MODE
  {
   ENTRY_IMMEDIATE = 0,  // Langsung entry tiap awal siklus (per bar baru)
   ENTRY_MOMENTUM  = 1   // Entry hanya jika candle sebelumnya searah
  };

//--- arah trading
enum ENUM_TRADE_DIR
  {
   DIR_BUY  = 0,         // BUY saja (sesuai screenshot)
   DIR_SELL = 1          // SELL saja (kebalikannya)
  };

input group "=== Umum ==="
input long            InpMagic         = 20250811;       // Magic number
input ENUM_TRADE_DIR  InpDirection     = DIR_BUY;        // Arah trading
input ENUM_ENTRY_MODE InpEntryMode     = ENTRY_MOMENTUM; // Mode entry
input int             InpMaxSpreadPts  = 60;             // Spread maksimal (points), 0 = abaikan

input group "=== Lot ==="
input double          InpInitialLot    = 0.01;           // Lot awal (minimal)
input double          InpLotStepOnWin  = 0.01;           // Tambahan lot setelah siklus profit (0 = lot tetap)
input double          InpMaxLot        = 0.20;           // Lot maksimal
input bool            InpResetOnLoss   = true;           // Reset ke lot awal setelah siklus loss

input group "=== Proteksi Stop Order ==="
input int             InpStopDistPts   = 250;            // Jarak stop order dari harga (points, GOLD: 250 = $2.50)
input int             InpTrailStartPts = 100;            // Trailing mulai setelah profit sekian points
input int             InpTrailStepPts  = 20;             // Langkah minimal trailing (points)

input group "=== Target ==="
input double          InpTargetUSD     = 30.0;           // Target profit per siklus (USD)
input double          InpMaxLossUSD    = 0.0;            // Batas floating loss (USD), 0 = nonaktif

//--- global
CTrade   trade;
double   g_lot         = 0.0;    // lot untuk siklus berikutnya
bool     g_cycleActive = false;  // sedang ada siklus berjalan
datetime g_cycleStart  = 0;      // waktu mulai siklus (untuk evaluasi history)
datetime g_lastEntryBar= 0;      // bar terakhir kali entry (maks. 1 entry per bar)

//+------------------------------------------------------------------+
//| Inisialisasi                                                     |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(30);

   g_lot = NormalizeLot(InpInitialLot);

   // resume: kalau EA di-restart saat masih ada posisi milik EA ini
   int buys = 0, sells = 0;
   double basket = 0.0;
   if(MyPositions(buys, sells, basket) > 0)
     {
      g_cycleActive = true;
      g_cycleStart  = EarliestPositionTime();
      Print("Resume siklus yang sedang berjalan, mulai: ", TimeToString(g_cycleStart));
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
   int buys = 0, sells = 0;
   double basket = 0.0;
   int total = MyPositions(buys, sells, basket);

   if(g_cycleActive)
     {
      // akun hedging: stop order tereksekusi -> posisi terkunci, tutup keduanya
      if(buys > 0 && sells > 0)
        {
         CloseMyPositions();
         DeleteMyPendings();
         UpdateComment(basket);
         return;
        }

      if(total > 0)
        {
         // target profit atau batas loss tercapai -> tutup semua
         if(basket >= InpTargetUSD ||
            (InpMaxLossUSD > 0 && basket <= -InpMaxLossUSD))
           {
            CloseMyPositions();
            DeleteMyPendings();
            UpdateComment(basket);
            return;
           }
         ManageProtectiveStop();
        }
      else
        {
         // posisi sudah habis (stop tereksekusi di akun netting,
         // atau ditutup EA/manual) -> bereskan pending & evaluasi hasil
         DeleteMyPendings();
         EndCycle();
        }
     }
   else
     {
      if(total > 0)
        {
         // ada posisi (mis. dibuka manual dengan magic sama) -> ambil alih
         g_cycleActive = true;
         g_cycleStart  = EarliestPositionTime();
        }
      else if(EntrySignal())
         StartCycle();
     }

   UpdateComment(basket);
  }

//+------------------------------------------------------------------+
//| Sinyal entry                                                     |
//+------------------------------------------------------------------+
bool EntrySignal()
  {
   datetime bar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(bar == g_lastEntryBar)
      return(false);  // maksimal 1 entry per bar

   if(InpMaxSpreadPts > 0)
     {
      double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
                       SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
      if(spread > InpMaxSpreadPts)
         return(false);
     }

   if(InpEntryMode == ENTRY_MOMENTUM)
     {
      double o = iOpen(_Symbol, PERIOD_CURRENT, 1);
      double c = iClose(_Symbol, PERIOD_CURRENT, 1);
      if(InpDirection == DIR_BUY && c <= o)
         return(false);
      if(InpDirection == DIR_SELL && c >= o)
         return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| Mulai siklus baru: buka posisi + pasang stop order proteksi      |
//+------------------------------------------------------------------+
void StartCycle()
  {
   double lot = NormalizeLot(g_lot);
   bool ok;

   if(InpDirection == DIR_BUY)
      ok = trade.Buy(lot, _Symbol, 0, 0, 0, "cycle open");
   else
      ok = trade.Sell(lot, _Symbol, 0, 0, 0, "cycle open");

   if(!ok)
     {
      Print("Gagal buka posisi: ", trade.ResultRetcodeDescription());
      return;
     }

   g_cycleActive  = true;
   g_cycleStart   = TimeCurrent();
   g_lastEntryBar = iTime(_Symbol, PERIOD_CURRENT, 0);

   PlaceProtectiveStop(lot);
  }

//+------------------------------------------------------------------+
//| Pasang pending stop proteksi (SELL STOP untuk BUY, sebaliknya)   |
//+------------------------------------------------------------------+
void PlaceProtectiveStop(double lot)
  {
   long   stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double bid        = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask        = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(InpDirection == DIR_BUY)
     {
      double price    = bid - InpStopDistPts * _Point;
      double maxPrice = bid - (stopsLevel + 1) * _Point;
      if(price > maxPrice)
         price = maxPrice;
      price = NormalizeDouble(price, _Digits);

      if(!trade.SellStop(lot, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "protect"))
         Print("Gagal pasang SELL STOP: ", trade.ResultRetcodeDescription());
     }
   else
     {
      double price    = ask + InpStopDistPts * _Point;
      double minPrice = ask + (stopsLevel + 1) * _Point;
      if(price < minPrice)
         price = minPrice;
      price = NormalizeDouble(price, _Digits);

      if(!trade.BuyStop(lot, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "protect"))
         Print("Gagal pasang BUY STOP: ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Kelola stop proteksi: pasang ulang jika hilang + trailing        |
//+------------------------------------------------------------------+
void ManageProtectiveStop()
  {
   // data posisi milik EA
   double entry = 0.0, volume = 0.0;
   long   ptype = -1;
   if(!MyPositionInfo(entry, volume, ptype))
      return;

   double stopPrice   = 0.0;
   ulong  stopTicket  = FindPendingStop(stopPrice);

   if(stopTicket == 0)
     {
      // pending hilang (terhapus manual / gagal) -> pasang ulang
      PlaceProtectiveStop(volume);
      return;
     }

   long   stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double bid        = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask        = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(ptype == POSITION_TYPE_BUY)
     {
      double profitPts = (bid - entry) / _Point;
      if(profitPts < InpTrailStartPts)
         return;

      double newPrice = bid - InpStopDistPts * _Point;
      double maxPrice = bid - (stopsLevel + 1) * _Point;
      if(newPrice > maxPrice)
         newPrice = maxPrice;
      newPrice = NormalizeDouble(newPrice, _Digits);

      // hanya digeser NAIK (mengunci profit), tidak pernah turun
      if(newPrice >= stopPrice + InpTrailStepPts * _Point)
        {
         if(!trade.OrderModify(stopTicket, newPrice, 0, 0, ORDER_TIME_GTC, 0))
            Print("Gagal trailing SELL STOP: ", trade.ResultRetcodeDescription());
        }
     }
   else // POSITION_TYPE_SELL
     {
      double profitPts = (entry - ask) / _Point;
      if(profitPts < InpTrailStartPts)
         return;

      double newPrice = ask + InpStopDistPts * _Point;
      double minPrice = ask + (stopsLevel + 1) * _Point;
      if(newPrice < minPrice)
         newPrice = minPrice;
      newPrice = NormalizeDouble(newPrice, _Digits);

      // hanya digeser TURUN mengikuti harga
      if(newPrice <= stopPrice - InpTrailStepPts * _Point)
        {
         if(!trade.OrderModify(stopTicket, newPrice, 0, 0, ORDER_TIME_GTC, 0))
            Print("Gagal trailing BUY STOP: ", trade.ResultRetcodeDescription());
        }
     }
  }

//+------------------------------------------------------------------+
//| Akhiri siklus: hitung hasil dari history & atur lot berikutnya   |
//+------------------------------------------------------------------+
void EndCycle()
  {
   double result = CycleClosedProfit();

   if(result > 0)
     {
      if(InpLotStepOnWin > 0)
         g_lot = MathMin(g_lot + InpLotStepOnWin, InpMaxLot);
      Print("Siklus selesai PROFIT ", DoubleToString(result, 2),
            " USD. Lot berikutnya: ", DoubleToString(g_lot, 2));
     }
   else
     {
      if(InpResetOnLoss)
         g_lot = InpInitialLot;
      Print("Siklus selesai LOSS ", DoubleToString(result, 2),
            " USD. Lot berikutnya: ", DoubleToString(g_lot, 2));
     }

   g_lot          = NormalizeLot(g_lot);
   g_cycleActive  = false;
   g_cycleStart   = 0;
  }

//+------------------------------------------------------------------+
//| Total profit deal yang sudah ditutup sejak siklus dimulai        |
//+------------------------------------------------------------------+
double CycleClosedProfit()
  {
   double total = 0.0;
   if(!HistorySelect(g_cycleStart - 60, TimeCurrent() + 60))
      return(0.0);

   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0)
         continue;
      if(HistoryDealGetInteger(t, DEAL_MAGIC) != InpMagic)
         continue;
      if(HistoryDealGetString(t, DEAL_SYMBOL) != _Symbol)
         continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(t, DEAL_ENTRY) == DEAL_ENTRY_IN)
         continue; // hanya deal penutupan

      total += HistoryDealGetDouble(t, DEAL_PROFIT)
             + HistoryDealGetDouble(t, DEAL_SWAP)
             + HistoryDealGetDouble(t, DEAL_COMMISSION);
     }
   return(total);
  }

//+------------------------------------------------------------------+
//| Helper: posisi milik EA ini                                      |
//+------------------------------------------------------------------+
int MyPositions(int &buys, int &sells, double &profit)
  {
   buys = 0;
   sells = 0;
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

      profit += PositionGetDouble(POSITION_PROFIT)
              + PositionGetDouble(POSITION_SWAP);

      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         buys++;
      else
         sells++;
     }
   return(buys + sells);
  }

//+------------------------------------------------------------------+
//| Helper: info posisi pertama milik EA (entry, volume, tipe)       |
//+------------------------------------------------------------------+
bool MyPositionInfo(double &entry, double &volume, long &ptype)
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

      entry  = PositionGetDouble(POSITION_PRICE_OPEN);
      volume = PositionGetDouble(POSITION_VOLUME);
      ptype  = PositionGetInteger(POSITION_TYPE);
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Helper: waktu open posisi paling awal (untuk resume)             |
//+------------------------------------------------------------------+
datetime EarliestPositionTime()
  {
   datetime earliest = TimeCurrent();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(t < earliest)
         earliest = t;
     }
   return(earliest);
  }

//+------------------------------------------------------------------+
//| Helper: cari pending stop milik EA                               |
//+------------------------------------------------------------------+
ulong FindPendingStop(double &price)
  {
   price = 0.0;
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
      if(type != ORDER_TYPE_SELL_STOP && type != ORDER_TYPE_BUY_STOP)
         continue;

      price = OrderGetDouble(ORDER_PRICE_OPEN);
      return(ticket);
     }
   return(0);
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
//| Helper: tutup semua posisi milik EA                              |
//+------------------------------------------------------------------+
void CloseMyPositions()
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

      if(!trade.PositionClose(ticket))
         Print("Gagal tutup posisi #", ticket, ": ", trade.ResultRetcodeDescription());
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

   lot = MathMin(lot, InpMaxLot);
   lot = MathMax(minLot, MathMin(lot, maxLot));
   return(NormalizeDouble(lot, 2));
  }

//+------------------------------------------------------------------+
//| Tampilan status di chart                                         |
//+------------------------------------------------------------------+
void UpdateComment(double basket)
  {
   string s = "=== GoldTrailStop EA ===\n";
   s += "Status siklus  : " + (g_cycleActive ? "AKTIF" : "menunggu entry") + "\n";
   s += "Floating P/L   : " + DoubleToString(basket, 2) + " USD"
      + "  (target " + DoubleToString(InpTargetUSD, 2) + " USD)\n";
   s += "Lot berikutnya : " + DoubleToString(g_lot, 2) + "\n";
   Comment(s);
  }
//+------------------------------------------------------------------+
