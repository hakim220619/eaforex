//+------------------------------------------------------------------+
//|                                                    MaTrend_EA.mq5 |
//|  EA trend-following berbasis dua Moving Average.                   |
//|                                                                    |
//|  Setup BUY (SELL = cermin), tiga cara masuk yang bisa dipilih:     |
//|    ENTRY_CROSS    : MA cepat memotong ke atas MA lambat (default)  |
//|    ENTRY_PULLBACK : dalam uptrend, harga menyentuh MA cepat lalu   |
//|                     bar ditutup kembali di atasnya                 |
//|    ENTRY_BREAKOUT : dalam uptrend, close menembus high N bar       |
//|                                                                    |
//|  SL = InpSlAtr x ATR dari entry. TP = InpRR x jarak SL.            |
//|  Win rate rendah, RR tinggi: sebagian besar trade rugi kecil dan   |
//|  sedikit trade menang besar. Deret 8-14 loss beruntun itu normal.  |
//|                                                                    |
//|  Default dikalibrasi untuk EURUSD H1 (lihat README):               |
//|    EMA 34/100, SL 2 x ATR, RR 5, tanpa filter tambahan.            |
//|    Dengan lot 0.01 risikonya ~25 pip = $2.50 per trade, sehingga   |
//|    strategi ini masih masuk akal untuk modal kecil ($100-200).     |
//|                                                                    |
//|  Kalibrasi lintas simbol:                                          |
//|   - semua jarak berbasis ATR, jadi bebas dari jumlah digit         |
//|   - kompensasi spread: SL/TP SELL digeser +spread, karena SELL     |
//|     ditutup di Ask sedangkan chart memakai Bid                     |
//|   - filter spread relatif risiko (spread <= X% jarak SL)           |
//|   - Journal mencetak risiko $ dan % equity tiap order              |
//+------------------------------------------------------------------+
#property copyright "forexbot"
#property version   "1.00"
#property description "Trend-following 2 MA (cross / pullback / breakout). SL & TP berbasis ATR, RR tinggi."

#include <Trade/Trade.mqh>

#define OBJ_PREFIX "MT_"

//+------------------------------------------------------------------+
//| Enum                                                              |
//+------------------------------------------------------------------+
enum ENUM_LOT_MODE
  {
   LOT_FIXED        = 0,  // Lot tetap (InpLot)
   LOT_RISK_PERCENT = 1   // Otomatis dari % risiko equity (InpRiskPercent)
  };

enum ENUM_ENTRY_MODE
  {
   ENTRY_CROSS    = 0,  // MA cepat memotong MA lambat
   ENTRY_PULLBACK = 1,  // Koreksi ke MA cepat lalu ditolak
   ENTRY_BREAKOUT = 2   // Close menembus high/low InpBreakoutBars bar
  };

//+------------------------------------------------------------------+
//| Input                                                             |
//+------------------------------------------------------------------+
input group "=== Umum ==="
input long            InpMagic            = 20260906;  // Magic number
input ENUM_LOT_MODE   InpLotMode          = LOT_FIXED; // Mode lot
input double          InpLot              = 0.01;      // Lot tetap
input double          InpRiskPercent      = 2.0;       // Risiko per trade (% equity)
input double          InpMaxRiskPct       = 0.0;       // Blok trade bila risiko > % equity (0=off)
input int             InpMaxOpenTrades    = 1;         // Maks posisi terbuka EA ini
input int             InpCooldownBars     = 0;         // Jeda minimal antar entry (bar)
input int             InpMaxSpreadPts     = 0;         // Spread maks (points), 0=off
input double          InpMaxSpreadRiskPct = 8.0;       // Spread maks sebagai % jarak SL, 0=off
input bool            InpSpreadCompensate = true;      // Geser SL/TP SELL sebesar spread
input int             InpSlippagePts      = 30;        // Deviasi harga (points)

input group "=== Moving Average ==="
input ENUM_MA_METHOD  InpMaType           = MODE_EMA;  // Jenis MA
input int             InpMaFast           = 34;        // Periode MA cepat
input int             InpMaSlow           = 100;       // Periode MA lambat
input bool            InpUseFilter        = false;     // Pakai MA panjang sebagai penyaring rezim
input int             InpMaFilter         = 200;       // Periode MA penyaring
input int             InpSlopeBars        = 0;         // MA lambat harus miring searah N bar (0=off)

input group "=== Entry ==="
input ENUM_ENTRY_MODE InpEntry            = ENTRY_CROSS; // Cara masuk
input int             InpPullbackBars     = 8;        // Jendela sentuhan MA (ENTRY_PULLBACK)
input int             InpBreakoutBars     = 20;       // Jumlah bar high/low (ENTRY_BREAKOUT)

input group "=== SL / TP ==="
input int             InpAtrPeriod        = 14;       // Periode ATR
input double          InpSlAtr            = 2.0;      // Jarak SL (x ATR)
input double          InpRR               = 5.0;      // TP sebagai kelipatan jarak SL
input double          InpMinAtrPct        = 0.0;      // ATR minimal sebagai % harga (0=off)

input group "=== Manajemen posisi ==="
input double          InpBreakEvenRR      = 0.0;      // Pindah SL ke BE di RR ini (0=off)
input double          InpBeOffsetAtr      = 0.05;     // Offset BE (x ATR)
input double          InpTrailAtr         = 0.0;      // Trailing stop (x ATR), 0=off
input double          InpTrailStartRR     = 1.0;      // Trailing mulai di RR ini
input int             InpMaxBarsInTrade   = 0;        // Tutup paksa setelah N bar (0=off)
input bool            InpExitOnOpposite   = false;    // Tutup saat sinyal berlawanan muncul

input group "=== Diagnosa ==="
input bool            InpVerbose          = true;     // Cetak detail ke Journal
input bool            InpDrawObjects      = true;     // Gambar panah entry di chart

//+------------------------------------------------------------------+
//| Global                                                            |
//+------------------------------------------------------------------+
CTrade   trade;
int      hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE;
int      hFilt = INVALID_HANDLE, hAtr  = INVALID_HANDLE;
datetime lastBarTime = 0;
int      barCount     = 0;
int      lastEntryBar = -1000000;
double   gPoint  = 0.0;
int      gDigits = 0;
bool     gOptimizing = false;

struct Stats
  {
   long bars, sigBuy, sigSell, exec;
   long rejCooldown, rejOpen, rejSpread, rejRisk, rejAtr, rejOrder;
  };
Stats st;

struct Signal
  {
   int    dir;
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
   double s = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return (s > 0.0 ? s : 0.0);
  }

double NormLot(double lot)
  {
   double mn  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stp = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stp <= 0.0)
      stp = 0.01;
   lot = MathFloor(lot / stp + 1e-8) * stp;
   if(lot < mn) lot = mn;
   if(lot > mx) lot = mx;
   return NormalizeDouble(lot, 2);
  }

double StopsLevelPrice()
  {
   return (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * gPoint;
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
   gPoint      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   gDigits     = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   gOptimizing = (bool)MQLInfoInteger(MQL_OPTIMIZATION);

   if(InpMaFast >= InpMaSlow)
     {
      Print("Input salah: InpMaFast harus lebih kecil dari InpMaSlow.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMaxOpenTrades < 1)
     {
      Print("Input salah: InpMaxOpenTrades minimal 1.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpSlAtr <= 0.0 || InpRR <= 0.0)
     {
      Print("Input salah: InpSlAtr dan InpRR harus lebih besar dari nol.");
      return INIT_PARAMETERS_INCORRECT;
     }

   hFast = iMA(_Symbol, _Period, InpMaFast, 0, InpMaType, PRICE_CLOSE);
   hSlow = iMA(_Symbol, _Period, InpMaSlow, 0, InpMaType, PRICE_CLOSE);
   hAtr  = iATR(_Symbol, _Period, InpAtrPeriod);
   if(InpUseFilter)
      hFilt = iMA(_Symbol, _Period, InpMaFilter, 0, InpMaType, PRICE_CLOSE);

   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE || hAtr == INVALID_HANDLE ||
      (InpUseFilter && hFilt == INVALID_HANDLE))
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
   PrintFormat("MaTrend EA v1.00 init: %s %s | MA %s %d/%d | SL %.1f x ATR%d | RR %.1f",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period), EnumToString(InpMaType),
               InpMaFast, InpMaSlow, InpSlAtr, InpAtrPeriod, InpRR);
   PrintFormat("  digits=%d point=%.5f | spread=%d pts | lot min=%.2f | nilai 1.00 lot per 1 unit harga=$%.2f | equity=%.2f",
               gDigits, gPoint, (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD),
               minLot, vpl, equity);

   // Perkiraan risiko dengan lot minimum -- inti pertanyaan "cukup tidak modalnya".
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(hAtr, 0, 0, 2, atrBuf) == 2 && vpl > 0.0 && equity > 0.0 && atrBuf[0] > 0.0)
     {
      double slGuess = atrBuf[0] * InpSlAtr;
      double riskMin = slGuess * vpl * minLot;
      PrintFormat("Cek modal: SL %.1f x ATR = %.*f -> lot %.2f berisiko $%.2f = %.1f%% equity",
                  InpSlAtr, gDigits, slGuess, minLot, riskMin, riskMin / equity * 100.0);
      if(riskMin / equity * 100.0 > 5.0)
         PrintFormat("PERINGATAN modal: %.1f%% equity per trade dengan lot minimum. " +
                     "Perbesar modal, pakai akun cent, atau pindah ke simbol/timeframe " +
                     "dengan ATR lebih kecil.", riskMin / equity * 100.0);
     }
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   PrintFormat("RINGKASAN MaTrend EA: bar=%I64d | sinyal BUY=%I64d SELL=%I64d | dieksekusi=%I64d",
               st.bars, st.sigBuy, st.sigSell, st.exec);
   PrintFormat("  ditolak: cooldown=%I64d posisi-penuh=%I64d spread=%I64d risiko=%I64d ATR-kecil=%I64d order-gagal=%I64d",
               st.rejCooldown, st.rejOpen, st.rejSpread, st.rejRisk, st.rejAtr, st.rejOrder);

   if(hFast != INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow != INVALID_HANDLE) IndicatorRelease(hSlow);
   if(hFilt != INVALID_HANDLE) IndicatorRelease(hFilt);
   if(hAtr  != INVALID_HANDLE) IndicatorRelease(hAtr);

   if(!gOptimizing)
      ObjectsDeleteAll(0, OBJ_PREFIX);
  }

//+------------------------------------------------------------------+
//| Arah tren pada bar terakhir yang sudah closed (+1 / -1 / 0)       |
//+------------------------------------------------------------------+
int TrendDir(const double &fast[], const double &slow[], const double &filt[], double close1)
  {
   int d = (fast[1] > slow[1]) ? 1 : -1;

   if(InpUseFilter)
     {
      if((d > 0 && close1 < filt[1]) || (d < 0 && close1 > filt[1]))
         return 0;
     }
   if(InpSlopeBars > 0)
     {
      int j = 1 + InpSlopeBars;
      if((d > 0 && !(slow[1] > slow[j])) || (d < 0 && !(slow[1] < slow[j])))
         return 0;
     }
   return d;
  }

//+------------------------------------------------------------------+
//| Sinyal masuk pada bar 1. Mengembalikan +1 / -1 / 0.               |
//+------------------------------------------------------------------+
int EntrySignal(int d, const double &fast[], const double &slow[])
  {
   if(d == 0)
      return 0;

   if(InpEntry == ENTRY_CROSS)
     {
      bool up = (fast[1] > slow[1] && fast[2] <= slow[2]);
      bool dn = (fast[1] < slow[1] && fast[2] >= slow[2]);
      return (((d > 0 && up) || (d < 0 && dn)) ? d : 0);
     }

   if(InpEntry == ENTRY_BREAKOUT)
     {
      double cb  = iClose(_Symbol, _Period, 1);
      double ext = (d > 0) ? iHigh(_Symbol, _Period, 2) : iLow(_Symbol, _Period, 2);
      for(int i = 2; i <= InpBreakoutBars + 1; i++)
        {
         if(d > 0) ext = MathMax(ext, iHigh(_Symbol, _Period, i));
         else      ext = MathMin(ext, iLow(_Symbol, _Period, i));
        }
      if(d > 0 && cb > ext) return d;
      if(d < 0 && cb < ext) return d;
      return 0;
     }

   // ENTRY_PULLBACK: harga menyentuh MA cepat dalam InpPullbackBars bar terakhir,
   // lalu bar 1 ditutup kembali searah tren. Syarat "fresh" membuat satu sinyal
   // per koreksi, bukan sinyal berulang selama harga bertahan di sisi MA.
   double o1 = iOpen(_Symbol, _Period, 1);
   double c1 = iClose(_Symbol, _Period, 1);
   double c2 = iClose(_Symbol, _Period, 2);
   double l1 = iLow(_Symbol, _Period, 1);
   double h1 = iHigh(_Symbol, _Period, 1);

   if(d > 0)
     {
      if(!(c1 > fast[1] && c1 > o1))
         return 0;
      bool touched = false;
      for(int i = 1; i <= InpPullbackBars && !touched; i++)
         if(iLow(_Symbol, _Period, i) <= fast[i])
            touched = true;
      bool fresh = (c2 <= fast[2]) || (l1 <= fast[1]);
      return ((touched && fresh) ? d : 0);
     }
   else
     {
      if(!(c1 < fast[1] && c1 < o1))
         return 0;
      bool touched = false;
      for(int i = 1; i <= InpPullbackBars && !touched; i++)
         if(iHigh(_Symbol, _Period, i) >= fast[i])
            touched = true;
      bool fresh = (c2 >= fast[2]) || (h1 >= fast[1]);
      return ((touched && fresh) ? d : 0);
     }
  }

//+------------------------------------------------------------------+
//| Susun setup (entry / SL / TP / lot)                               |
//+------------------------------------------------------------------+
bool BuildSetup(int dir, double atr, Signal &s)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spr = SpreadPrice();

   double entry  = (dir > 0) ? ask : bid;
   double slDist = InpSlAtr * atr;
   double sl     = entry - dir * slDist;
   double tp     = entry + dir * InpRR * slDist;

   // stops level broker
   double stops = StopsLevelPrice();
   if(stops > 0.0 && slDist < stops + spr)
     {
      slDist = stops + spr;
      sl = entry - dir * slDist;
      tp = entry + dir * InpRR * slDist;
     }

   // kompensasi spread untuk SELL (SELL ditutup di Ask, chart = Bid)
   if(InpSpreadCompensate && dir < 0 && spr > 0.0)
     {
      sl += spr;
      tp += spr;
      slDist = MathAbs(entry - sl);
     }

   if(InpMaxSpreadPts > 0 && spr > InpMaxSpreadPts * gPoint)
     {
      st.rejSpread++;
      Log(StringFormat("Tolak: spread %.0f pts > maks %d pts", spr / gPoint, InpMaxSpreadPts));
      return false;
     }
   if(InpMaxSpreadRiskPct > 0.0 && slDist > 0.0 && spr / slDist * 100.0 > InpMaxSpreadRiskPct)
     {
      st.rejSpread++;
      Log(StringFormat("Tolak: spread %.1f%% dari jarak SL > maks %.1f%%",
                       spr / slDist * 100.0, InpMaxSpreadRiskPct));
      return false;
     }

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
   bool ok = (s.dir > 0) ? trade.Buy(s.lot, _Symbol, 0.0, s.sl, s.tp, "MaTrend")
                         : trade.Sell(s.lot, _Symbol, 0.0, s.sl, s.tp, "MaTrend");
   if(!ok)
     {
      st.rejOrder++;
      PrintFormat("%s GAGAL: ret=%d %s | sl=%.*f tp=%.*f lot=%.2f",
                  side, trade.ResultRetcode(), trade.ResultRetcodeDescription(),
                  gDigits, s.sl, gDigits, s.tp, s.lot);
      return false;
     }

   st.exec++;
   lastEntryBar = barCount;
   DrawArrow(s);
   double dist = MathAbs(s.entry - s.sl);
   PrintFormat("%s lot %.2f | entry=%.*f sl=%.*f tp=%.*f | SL=%.*f (%.2f x ATR) RR=%.1f | risiko $%.2f = %.1f%%",
               side, s.lot, gDigits, s.entry, gDigits, s.sl, gDigits, s.tp,
               gDigits, dist, (s.atr > 0.0 ? dist / s.atr : 0.0), InpRR,
               s.riskMoney, s.riskPct);
   if(s.riskPct > 5.0)
      PrintFormat("PERINGATAN risiko: %.1f%% equity dalam satu trade.", s.riskPct);
   return true;
  }

//+------------------------------------------------------------------+
//| Manajemen posisi terbuka                                          |
//+------------------------------------------------------------------+
void ManagePositions(double atr)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      int    dir  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      double cur  = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                              : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double risk0 = MathAbs(open - sl);
      if(risk0 <= 0.0)
         risk0 = InpSlAtr * atr;
      if(risk0 <= 0.0)
         continue;
      double rr = (cur - open) * dir / risk0;

      if(InpMaxBarsInTrade > 0)
        {
         datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
         if(Bars(_Symbol, _Period, opened, TimeCurrent()) > InpMaxBarsInTrade)
           {
            trade.PositionClose(tk);
            Log(StringFormat("Tutup #%I64u: melewati %d bar", tk, InpMaxBarsInTrade));
            continue;
           }
        }

      double newSl = sl;
      if(InpBreakEvenRR > 0.0 && rr >= InpBreakEvenRR)
        {
         double be = open + dir * InpBeOffsetAtr * atr;
         if((dir > 0 && be > newSl) || (dir < 0 && (newSl == 0.0 || be < newSl)))
            newSl = be;
        }
      if(InpTrailAtr > 0.0 && rr >= InpTrailStartRR)
        {
         double tr = cur - dir * InpTrailAtr * atr;
         if((dir > 0 && tr > newSl) || (dir < 0 && (newSl == 0.0 || tr < newSl)))
            newSl = tr;
        }

      if(MathAbs(newSl - sl) > gPoint * 0.5)
        {
         if(MathAbs(cur - newSl) > StopsLevelPrice())
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

   ManagePositions(atr);

   datetime t0 = iTime(_Symbol, _Period, 0);
   if(t0 == lastBarTime)
      return;
   lastBarTime = t0;
   barCount++;
   st.bars++;

   int need = (int)MathMax(InpSlopeBars + 3, MathMax(InpPullbackBars + 2, 4));
   double fast[], slow[], filt[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   ArraySetAsSeries(filt, true);
   if(CopyBuffer(hFast, 0, 0, need, fast) < need) return;
   if(CopyBuffer(hSlow, 0, 0, need, slow) < need) return;
   if(InpUseFilter && CopyBuffer(hFilt, 0, 0, need, filt) < need) return;
   if(!InpUseFilter)
     {
      ArrayResize(filt, need);
      ArrayInitialize(filt, 0.0);
     }

   // --- saring pasar terlalu sepi
   if(InpMinAtrPct > 0.0)
     {
      double c1 = iClose(_Symbol, _Period, 1);
      if(c1 > 0.0 && atr / c1 * 100.0 < InpMinAtrPct)
        {
         st.rejAtr++;
         return;
        }
     }

   int d   = TrendDir(fast, slow, filt, iClose(_Symbol, _Period, 1));
   int dir = EntrySignal(d, fast, slow);
   if(dir == 0)
      return;

   if(dir > 0) st.sigBuy++;
   else        st.sigSell++;

   if(barCount - lastEntryBar < InpCooldownBars)
     {
      st.rejCooldown++;
      return;
     }

   CloseOppositeIfNeeded(dir);

   if(CountOwnPositions() >= InpMaxOpenTrades)
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
