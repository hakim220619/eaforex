//+------------------------------------------------------------------+
//|                                             MaTrend_XAUUSD_H1.mq5 |
//|  Versi KHUSUS XAUUSD H1 dari MaTrend_EA.                           |
//|                                                                    |
//|  Strategi (tetap, sudah dikalibrasi di 2,4 tahun data emas H1):    |
//|    Tren   : EMA 20 di atas EMA 100 = uptrend (SELL = cermin)       |
//|    Entry  : close bar menembus high 20 bar sebelumnya (breakout)   |
//|    SL     : 1.5 x ATR(14) dari harga entry                         |
//|    TP     : 5 x jarak SL (RR 5)                                    |
//|    Trail  : 2 x ATR, aktif setelah posisi mencapai +1R,            |
//|             dievaluasi di penutupan bar (bukan tiap tick)          |
//|                                                                    |
//|  Hasil simulasi 14 Apr 2024 - 4 Sep 2026, spread $0.19:            |
//|    326 trade | WR 42% | +109.8R | PF 1.65 | maxDD 13R              |
//|    train 60% +45.4R, test 40% +66.2R, 10/10 kuartal positif        |
//|    deret loss terpanjang 9, trade terpanjang 134 bar (~6 hari)     |
//|                                                                    |
//|  MODAL: SL rata-rata $22-23 per 0.01 lot. Dengan risiko 2%         |
//|  per trade butuh modal ~$1150, atau akun CENT (dibagi 100).        |
//|  Di akun $100 standar, satu SL = 23% modal -- jangan.              |
//|                                                                    |
//|  Pengaman: menolak berjalan bila simbol bukan XAU* atau            |
//|  timeframe bukan H1 (bisa dimatikan lewat input).                  |
//+------------------------------------------------------------------+
#property copyright "forexbot"
#property version   "1.00"
#property description "MaTrend khusus XAUUSD H1: EMA 20/100, breakout 20 bar, SL 1.5 ATR, RR 5, trailing 2 ATR."

#include <Trade/Trade.mqh>

#define OBJ_PREFIX "MTX_"

//+------------------------------------------------------------------+
//| Enum                                                              |
//+------------------------------------------------------------------+
enum ENUM_LOT_MODE
  {
   LOT_FIXED        = 0,  // Lot tetap (InpLot)
   LOT_RISK_PERCENT = 1   // Otomatis dari % risiko equity (InpRiskPercent)
  };

//+------------------------------------------------------------------+
//| Input                                                             |
//+------------------------------------------------------------------+
input group "=== Umum ==="
input long            InpMagic            = 20260913;  // Magic number
input ENUM_LOT_MODE   InpLotMode          = LOT_FIXED; // Mode lot
input double          InpLot              = 0.01;      // Lot tetap
input double          InpRiskPercent      = 2.0;       // Risiko per trade (% equity)
input double          InpMaxRiskPct       = 5.0;       // Blok trade bila risiko > % equity (0=off)
input int             InpMaxOpenTrades    = 1;         // Maks posisi terbuka EA ini
input int             InpCooldownBars     = 0;         // Jeda minimal antar entry (bar)
input int             InpMaxSpreadPts     = 350;       // Spread maks (points; 350 = $0.35 di 3 digit), 0=off
input double          InpMaxSpreadRiskPct = 8.0;       // Spread maks sebagai % jarak SL, 0=off
input bool            InpSpreadCompensate = true;      // Geser SL/TP SELL sebesar spread
input int             InpSlippagePts      = 50;        // Deviasi harga (points)

input group "=== Pengaman simbol / timeframe ==="
input bool            InpRequireXau       = true;      // Tolak bila nama simbol tidak mengandung XAU
input bool            InpRequireH1        = true;      // Tolak bila timeframe bukan H1

input group "=== Strategi (default = hasil kalibrasi) ==="
input int             InpMaFast           = 20;        // Periode EMA cepat
input int             InpMaSlow           = 100;       // Periode EMA lambat
input int             InpBreakoutBars     = 20;        // Jumlah bar high/low untuk breakout
input int             InpAtrPeriod        = 14;        // Periode ATR
input double          InpSlAtr            = 1.5;       // Jarak SL (x ATR)
input double          InpRR               = 5.0;       // TP sebagai kelipatan jarak SL

input group "=== Manajemen posisi (dievaluasi di penutupan bar) ==="
input double          InpTrailAtr         = 2.0;       // Trailing stop (x ATR), 0=off
input double          InpTrailStartRR     = 1.0;       // Trailing mulai di RR ini
input double          InpBreakEvenRR      = 0.0;       // Pindah SL ke BE di RR ini (0=off)
input double          InpBeOffsetAtr      = 0.05;      // Offset BE (x ATR)
input int             InpMaxBarsInTrade   = 0;         // Tutup paksa setelah N bar (0=off)

input group "=== Diagnosa ==="
input bool            InpVerbose          = true;      // Cetak detail ke Journal
input bool            InpDrawObjects      = true;      // Gambar panah entry di chart

//+------------------------------------------------------------------+
//| Global                                                            |
//+------------------------------------------------------------------+
CTrade   trade;
int      hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE, hAtr = INVALID_HANDLE;
datetime lastBarTime  = 0;
int      barCount     = 0;
int      lastEntryBar = -1000000;
double   gPoint  = 0.0;
int      gDigits = 0;
bool     gOptimizing = false;

struct Stats
  {
   long bars, sigBuy, sigSell, exec;
   long rejCooldown, rejOpen, rejSpread, rejRisk, rejOrder;
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

   // --- pengaman: EA ini dikalibrasi hanya untuk emas H1
   string symUpper = _Symbol;
   StringToUpper(symUpper);
   if(InpRequireXau && StringFind(symUpper, "XAU") < 0)
     {
      PrintFormat("DITOLAK: simbol %s bukan XAU*. EA ini khusus XAUUSD. " +
                  "Matikan InpRequireXau bila memang sengaja.", _Symbol);
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRequireH1 && _Period != PERIOD_H1)
     {
      PrintFormat("DITOLAK: timeframe %s, bukan H1. Setelan ini tidak berlaku di TF lain " +
                  "(di M5 breakout hasilnya nol, lihat README). Matikan InpRequireH1 bila sengaja.",
                  EnumToString((ENUM_TIMEFRAMES)_Period));
      return INIT_PARAMETERS_INCORRECT;
     }

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
   if(InpSlAtr <= 0.0 || InpRR <= 0.0 || InpBreakoutBars < 1 || InpAtrPeriod < 1)
     {
      Print("Input salah: InpSlAtr, InpRR, InpBreakoutBars, InpAtrPeriod harus positif.");
      return INIT_PARAMETERS_INCORRECT;
     }

   hFast = iMA(_Symbol, _Period, InpMaFast, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, _Period, InpMaSlow, 0, MODE_EMA, PRICE_CLOSE);
   hAtr  = iATR(_Symbol, _Period, InpAtrPeriod);
   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE || hAtr == INVALID_HANDLE)
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
   int    sprPts = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   PrintFormat("MaTrend XAUUSD H1 v1.00 init: %s %s | EMA %d/%d | breakout %d bar | SL %.1f x ATR%d | RR %.1f | trail %.1f ATR dari %.1fR",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period), InpMaFast, InpMaSlow,
               InpBreakoutBars, InpSlAtr, InpAtrPeriod, InpRR, InpTrailAtr, InpTrailStartRR);
   PrintFormat("  digits=%d point=%.*f | spread=%d pts = $%.2f per unit harga | lot min=%.2f | nilai 1.00 lot per $1 gerak=$%.2f | equity=%.2f",
               gDigits, gDigits, gPoint, sprPts, sprPts * gPoint, minLot, vpl, equity);
   if(InpMaxSpreadPts > 0 && sprPts > InpMaxSpreadPts)
      PrintFormat("PERHATIAN: spread saat ini %d pts > InpMaxSpreadPts %d. Semua entry akan ditolak " +
                  "sampai spread turun. Exness Pro XAUUSD biasanya 180-200 pts.", sprPts, InpMaxSpreadPts);

   // Perkiraan risiko dengan lot minimum -- inti pertanyaan "cukup tidak modalnya".
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(hAtr, 0, 0, 2, atrBuf) == 2 && vpl > 0.0 && equity > 0.0 && atrBuf[0] > 0.0)
     {
      double slGuess  = atrBuf[0] * InpSlAtr;
      double riskMin  = slGuess * vpl * minLot;
      double riskPct  = riskMin / equity * 100.0;
      double modalMin = riskMin / 0.02;
      PrintFormat("Cek modal: SL %.1f x ATR = $%.2f -> lot %.2f berisiko $%.2f = %.1f%% equity. " +
                  "Modal minimum untuk risiko 2%%: $%.0f",
                  InpSlAtr, slGuess, minLot, riskMin, riskPct, modalMin);
      if(riskPct > 5.0)
         PrintFormat("PERINGATAN modal: %.1f%% equity per trade dengan lot minimum. Deret 9 loss " +
                     "beruntun sudah terjadi di data uji = %.0f%% modal. Pakai akun CENT (risiko " +
                     "dibagi 100) atau isi modal ke ~$%.0f. Filter InpMaxRiskPct=%.1f%% akan " +
                     "memblok entry.", riskPct, riskPct * 9.0, modalMin, InpMaxRiskPct);
     }
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   PrintFormat("RINGKASAN MaTrend XAUUSD H1: bar=%I64d | sinyal BUY=%I64d SELL=%I64d | dieksekusi=%I64d",
               st.bars, st.sigBuy, st.sigSell, st.exec);
   PrintFormat("  ditolak: cooldown=%I64d posisi-penuh=%I64d spread=%I64d risiko=%I64d order-gagal=%I64d",
               st.rejCooldown, st.rejOpen, st.rejSpread, st.rejRisk, st.rejOrder);

   if(hFast != INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow != INVALID_HANDLE) IndicatorRelease(hSlow);
   if(hAtr  != INVALID_HANDLE) IndicatorRelease(hAtr);

   if(!gOptimizing)
      ObjectsDeleteAll(0, OBJ_PREFIX);
  }

//+------------------------------------------------------------------+
//| Sinyal breakout searah tren pada bar 1. Mengembalikan +1/-1/0.    |
//+------------------------------------------------------------------+
int BreakoutSignal(const double &fast[], const double &slow[])
  {
   int d = (fast[1] > slow[1]) ? 1 : -1;

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
      Log(StringFormat("Tolak: spread %.0f pts ($%.2f) > maks %d pts", spr / gPoint, spr, InpMaxSpreadPts));
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
      Log(StringFormat("Tolak: risiko $%.2f = %.1f%% equity > maks %.1f%% (modal terlalu kecil untuk lot %.2f)",
                       riskMoney, riskPct, InpMaxRiskPct, lot));
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
   ObjectSetInteger(0, nm, OBJPROP_COLOR, s.dir > 0 ? clrGold : clrOrangeRed);
   ObjectSetInteger(0, nm, OBJPROP_WIDTH, 2);
  }

bool Execute(Signal &s)
  {
   string side = (s.dir > 0 ? "BUY" : "SELL");
   bool ok = (s.dir > 0) ? trade.Buy(s.lot, _Symbol, 0.0, s.sl, s.tp, "MaTrendXAU")
                         : trade.Sell(s.lot, _Symbol, 0.0, s.sl, s.tp, "MaTrendXAU");
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
   PrintFormat("%s lot %.2f | entry=%.*f sl=%.*f tp=%.*f | SL=$%.2f (%.2f x ATR) RR=%.1f | risiko $%.2f = %.1f%%",
               side, s.lot, gDigits, s.entry, gDigits, s.sl, gDigits, s.tp,
               dist, (s.atr > 0.0 ? dist / s.atr : 0.0), InpRR,
               s.riskMoney, s.riskPct);
   if(s.riskPct > 5.0)
      PrintFormat("PERINGATAN risiko: %.1f%% equity dalam satu trade.", s.riskPct);
   return true;
  }

//+------------------------------------------------------------------+
//| Manajemen posisi -- dipanggil sekali per bar baru, memakai close  |
//| bar yang baru ditutup, persis seperti simulator (sim_ma.py).      |
//+------------------------------------------------------------------+
void ManagePositions(double atr, double close1)
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
      // Jarak SL awal dipulihkan dari TP (TP tidak pernah diubah), supaya RR
      // tetap konsisten setelah SL digeser trailing. Cadangan: ATR saat ini.
      double risk0 = (tp > 0.0) ? MathAbs(tp - open) / InpRR : InpSlAtr * atr;
      if(risk0 <= 0.0)
         continue;
      double rr = (close1 - open) * dir / risk0;

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
         double tr = close1 - dir * InpTrailAtr * atr;
         if((dir > 0 && tr > newSl) || (dir < 0 && (newSl == 0.0 || tr < newSl)))
            newSl = tr;
        }

      if(MathAbs(newSl - sl) > gPoint * 0.5)
        {
         double cur = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         // SL baru tidak boleh melewati harga sekarang (dan stops level broker)
         if((cur - newSl) * dir > StopsLevelPrice())
           {
            if(trade.PositionModify(tk, NormalizeDouble(newSl, gDigits), tp))
               Log(StringFormat("Trail #%I64u: SL %.*f -> %.*f (RR sekarang %.2f)",
                                tk, gDigits, sl, gDigits, newSl, rr));
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime t0 = iTime(_Symbol, _Period, 0);
   if(t0 == lastBarTime)
      return;                            // semua logika berjalan sekali per bar
   lastBarTime = t0;
   barCount++;
   st.bars++;

   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(hAtr, 0, 0, 3, atrBuf) < 3)
      return;
   double atr = atrBuf[1];
   if(atr <= 0.0)
      return;

   double close1 = iClose(_Symbol, _Period, 1);
   ManagePositions(atr, close1);

   int need = 4;
   double fast[], slow[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   if(CopyBuffer(hFast, 0, 0, need, fast) < need) return;
   if(CopyBuffer(hSlow, 0, 0, need, slow) < need) return;

   int dir = BreakoutSignal(fast, slow);
   if(dir == 0)
      return;

   if(dir > 0) st.sigBuy++;
   else        st.sigSell++;

   if(barCount - lastEntryBar < InpCooldownBars)
     {
      st.rejCooldown++;
      return;
     }

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
