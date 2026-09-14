//+------------------------------------------------------------------+
//|                                               SMC_Structure_EA.mq5 |
//|  EA Smart Money Concept (SMC) -- alur:                              |
//|      $ (Liquidity Sweep) -> MSS -> POI (FVG / OB / IFVG) -> Entry   |
//|                                                                    |
//|  Setup BUY (SELL = cermin):                                        |
//|   1. $   : candle menusuk swing low terakhir (liquidity/IDM).      |
//|   2. MSS : candle CLOSE di atas swing high terakhir (lower high).  |
//|            Leg sweep->MSS harus >= InpMinLegAtr x ATR agar bukan   |
//|            struktur mikro.                                         |
//|   3. POI : FVG / OB (valid bila liquidity di baliknya diambil) /   |
//|            IFVG pada leg impulsif pembuat MSS.                     |
//|   4. ENTRY: LIMIT di dalam zona POI.                               |
//|   5. SL  : di balik ujung sweep + buffer ATR, minimal N x ATR.     |
//|      TP  : liquidity berikutnya (swing lawan), fallback RR tetap.  |
//|                                                                    |
//|  v1.10 (Exness Pro / symbol 3 digit):                              |
//|   - semua jarak berbasis ATR, bukan points (bebas dari digit)      |
//|   - kompensasi spread: SL/TP SELL digeser sebesar spread karena    |
//|     SELL ditutup di harga Ask, sedangkan chart = Bid               |
//|   - filter spread relatif terhadap risiko (spread <= X% jarak SL)  |
//|   - break-even default OFF (di gold M5 BE 1R mengubah pemenang     |
//|     jadi 0 -- lihat README)                                        |
//|   - peringatan / batas risiko per trade (lot min vs equity kecil)  |
//+------------------------------------------------------------------+
#property copyright "forexbot"
#property version   "1.10"
#property description "SMC: Liquidity Sweep -> MSS -> entry FVG/OB/IFVG. Jarak berbasis ATR, kompensasi spread, TP ke liquidity."

#include <Trade/Trade.mqh>

#define OBJ_PREFIX "SMC_"

//+------------------------------------------------------------------+
//| Enum                                                              |
//+------------------------------------------------------------------+
enum ENUM_LOT_MODE
  {
   LOT_FIXED        = 0,  // Lot tetap (InpLot)
   LOT_RISK_PERCENT = 1   // Otomatis dari % risiko equity (InpRiskPercent)
  };

enum ENUM_ZONE_MODE
  {
   ZONE_AUTO = 0,  // Otomatis: FVG -> IFVG -> OB (pakai yang tersedia)
   ZONE_FVG  = 1,  // Hanya Fair Value Gap
   ZONE_OB   = 2,  // Hanya Order Block
   ZONE_IFVG = 3   // Hanya Inversion FVG
  };

enum ENUM_SL_MODE
  {
   SL_BEHIND_SWEEP = 0,  // Di balik ujung sweep (paling aman)
   SL_BEHIND_OB    = 1   // Di balik Order Block (lebih ketat)
  };

enum ENUM_TP_MODE
  {
   TP_LIQUIDITY = 0,  // Ke swing high/low berikutnya (liquidity), fallback RR
   TP_RR        = 1   // RR tetap (InpRR)
  };

enum ENUM_FVG_PICK
  {
   FVG_DEEPEST = 0,  // FVG paling dekat OB (diskon terdalam)
   FVG_NEAREST = 1   // FVG paling dekat harga (lebih sering terisi)
  };

enum ENUM_POI
  {
   POI_NONE = 0,
   POI_FVG  = 1,
   POI_OB   = 2,
   POI_IFVG = 3
  };

//+------------------------------------------------------------------+
//| Input                                                             |
//+------------------------------------------------------------------+
input group "=== Umum ==="
input long            InpMagic            = 20260825;        // Magic number
input ENUM_LOT_MODE   InpLotMode          = LOT_FIXED;       // Mode lot
input double          InpLot              = 0.01;            // Lot tetap
input double          InpRiskPercent      = 1.0;             // Risiko per trade (% equity, mode risk percent)
input double          InpMaxRiskPct       = 0.0;             // Batalkan trade jika risiko aktual > % equity ini (0 = hanya peringatan)
input int             InpMaxOpenTrades    = 1;               // Maksimal posisi terbuka bersamaan
input int             InpStartHour        = 0;               // Jam mulai entry (server, 0-23)
input int             InpEndHour          = 0;               // Jam berhenti entry (start = end -> 24 jam)

input group "=== Spread (Exness Pro XAUUSD normal 180-200 pts) ==="
input int             InpMaxSpreadPts     = 350;             // Spread maksimal absolut (points), 0 = abaikan. Blok lonjakan spread
input double          InpMaxSpreadRiskPct = 8.0;             // Spread maksimal relatif: spread <= X% dari jarak SL (0 = abaikan)
input bool            InpSpreadCompensate = true;            // Geser SL/TP SELL sebesar spread (SELL ditutup di Ask)

input group "=== Struktur Pasar (Swing) & ATR ==="
input int             InpSwingBars        = 3;               // Kekuatan swing (bar kiri-kanan). Besar = struktur major
input int             InpLookback         = 300;             // Jumlah candle yang dianalisis
input int             InpAtrPeriod        = 14;              // Periode ATR (acuan semua jarak)

input group "=== $ Liquidity Sweep / Inducement ==="
input int             InpSweepMaxBars     = 30;              // MSS harus terjadi maks N candle setelah sweep
input double          InpSweepMinAtr      = 0.0;             // Minimal tusukan di balik liquidity (x ATR)
input bool            InpSweepMustClose   = false;           // Candle sweep wajib close kembali di dalam (wick rejection)

input group "=== MSS (Market Structure Shift) ==="
input double          InpMssMinBreakAtr   = 0.0;             // Minimal close melewati level struktur (x ATR)
input double          InpMinLegAtr        = 2.0;             // Leg ujung sweep -> level MSS minimal (x ATR). Saring struktur mikro
input bool            InpUseTrendFilter   = false;           // Hanya searah EMA (opsional)
input int             InpEmaPeriod        = 200;             // Periode EMA filter tren

input group "=== POI: FVG / OB / IFVG ==="
input ENUM_ZONE_MODE  InpZoneMode         = ZONE_AUTO;       // Zona entry
input ENUM_FVG_PICK   InpFvgPick          = FVG_DEEPEST;     // FVG mana yang dipakai jika ada beberapa
input double          InpMinFvgAtr        = 0.05;            // Ukuran FVG minimal (x ATR), saring noise
input bool            InpObRequireSweep   = true;            // OB valid hanya jika liquidity di baliknya sudah diambil
input int             InpZoneEntryPct     = 50;              // Posisi entry dalam zona (0 = tepi dekat harga, 100 = tepi jauh)
input int             InpEntryValidBars   = 15;              // Masa berlaku limit order (candle)

input group "=== SL / TP (basis ATR) ==="
input ENUM_SL_MODE    InpSlMode           = SL_BEHIND_SWEEP; // Penempatan SL
input double          InpSlBufferAtr      = 0.3;             // Buffer SL di balik sweep/OB (x ATR)
input double          InpSlMinAtr         = 1.0;             // Jarak SL minimal (x ATR); lebih kecil -> setup dilewati
input ENUM_TP_MODE    InpTpMode           = TP_LIQUIDITY;    // Penempatan TP
input double          InpRR               = 2.0;             // RR tetap (TP = RR x risiko)
input double          InpMinRR            = 1.5;             // RR minimal target liquidity (kurang -> liquidity berikutnya / fallback RR)
input double          InpMaxRR            = 5.0;             // RR maksimal target liquidity (lebih -> TP dipangkas)
input double          InpTpBufferAtr      = 0.1;             // TP dipasang N x ATR sebelum level liquidity
input double          InpBreakEvenRR      = 0.0;             // Geser SL ke entry setelah profit N x risiko (0 = OFF, disarankan)
input double          InpBeOffsetAtr      = 0.05;            // Offset SL break-even dari entry (x ATR)

input group "=== Tampilan ==="
input bool            InpDraw             = true;            // Gambar zona OB/FVG/IFVG, garis MSS & $ di chart
input color           InpColorBuy         = clrSeaGreen;     // Warna setup BUY
input color           InpColorSell        = clrFireBrick;    // Warna setup SELL

//+------------------------------------------------------------------+
//| Struktur data setup                                               |
//+------------------------------------------------------------------+
struct SSetup
  {
   int      dir;            // +1 BUY, -1 SELL
   int      barSweep;       // indeks candle sweep
   int      barLiq;         // indeks swing yang disapu ($)
   int      barMss;         // indeks swing struktur yang ditembus
   int      barExt;         // indeks ujung sweep
   int      barOb;          // indeks candle OB
   double   liqLevel;       // level liquidity yang disapu
   double   sweepExtreme;   // ujung sweep
   double   mssLevel;       // level struktur (MSS)
   bool     hasOB, obValid, hasFVG, hasIFVG;
   double   obNear, obFar;  // near = tepi dekat harga, far = tepi jauh (arah SL)
   double   fvgNear, fvgFar;
   double   ifvgNear, ifvgFar;
   ENUM_POI poi;
   double   zoneNear, zoneFar;
   double   entry, sl, tp;
   int      tpBar;          // indeks swing target liquidity, -1 = TP dari RR
   string   skipReason;     // alasan setup ditolak setelah MSS valid (untuk log)
  };

//+------------------------------------------------------------------+
//| State                                                             |
//+------------------------------------------------------------------+
CTrade    trade;
MqlRates  g_r[];                 // candle, series (0 = bar berjalan)
bool      g_sh[], g_sl[];        // swing high / low per bar
int       g_n            = 0;
double    g_atr          = 0.0;  // ATR bar 1
double    g_ema          = 0.0;  // EMA bar 1
int       g_hAtr         = INVALID_HANDLE;
int       g_hEma         = INVALID_HANDLE;
datetime  g_lastBar      = 0;

ulong     g_pendTicket   = 0;    // limit order aktif milik EA
int       g_pendBarsLeft = 0;
int       g_pendDir      = 0;
double    g_pendSl       = 0.0;
double    g_pendTp       = 0.0;

string    g_status       = "Menunggu setup...";
string    g_lastSetup    = "-";
string    g_lastBlock    = "";

// statistik diagnostik (dicetak di akhir backtest / saat EA dilepas)
int g_cntBars = 0, g_cntBlockSpread = 0, g_cntBlockTime = 0, g_cntBlockPos = 0;
int g_cntMss = 0, g_cntSetup = 0, g_cntNoPoi = 0, g_cntSkipLeg = 0, g_cntSkipTrend = 0, g_cntSkipSl = 0;
int g_cntSkipSpreadRisk = 0, g_cntSkipRisk = 0, g_cntSkipStops = 0, g_cntOrderOk = 0, g_cntOrderFail = 0;

//+------------------------------------------------------------------+
//| Init / Deinit                                                     |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpSwingBars < 1)              { Print("InpSwingBars minimal 1");                 return(INIT_PARAMETERS_INCORRECT); }
   if(InpLookback < 4 * InpSwingBars + 20) { Print("InpLookback terlalu kecil");        return(INIT_PARAMETERS_INCORRECT); }
   if(InpEntryValidBars < 1)         { Print("InpEntryValidBars minimal 1");            return(INIT_PARAMETERS_INCORRECT); }
   if(InpAtrPeriod < 1)              { Print("InpAtrPeriod minimal 1");                 return(INIT_PARAMETERS_INCORRECT); }

   g_hAtr = iATR(_Symbol, PERIOD_CURRENT, InpAtrPeriod);
   if(g_hAtr == INVALID_HANDLE) { Print("Gagal membuat handle ATR"); return(INIT_FAILED); }
   if(InpUseTrendFilter)
     {
      g_hEma = iMA(_Symbol, PERIOD_CURRENT, InpEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(g_hEma == INVALID_HANDLE) { Print("Gagal membuat handle EMA"); return(INIT_FAILED); }
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFillingBySymbol(_Symbol);

   PrintEnvironment();
   RecoverPending();
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   PrintFormat("RINGKASAN SMC EA v1.10: bar=%d | MSS valid=%d | setup dieksekusi=%d | order OK=%d gagal=%d | ditolak: POI=%d leg<min=%d tren=%d SL<min=%d spread/risiko=%d risiko%%=%d stops=%d | diblok: spread=%d jam=%d posisi=%d",
               g_cntBars, g_cntMss, g_cntSetup, g_cntOrderOk, g_cntOrderFail, g_cntNoPoi, g_cntSkipLeg, g_cntSkipTrend,
               g_cntSkipSl, g_cntSkipSpreadRisk, g_cntSkipRisk, g_cntSkipStops, g_cntBlockSpread, g_cntBlockTime, g_cntBlockPos);
   if(g_cntBars > 0 && g_cntMss == 0)
      Print("Tidak ada MSS terdeteksi sama sekali: periksa data history symbol / cek pesan ENTRY DIBLOK di Journal.");
   if(g_hAtr != INVALID_HANDLE) IndicatorRelease(g_hAtr);
   if(g_hEma != INVALID_HANDLE) IndicatorRelease(g_hEma);
   Comment("");
   if(InpDraw)
      ObjectsDeleteAll(0, OBJ_PREFIX);
  }

//+------------------------------------------------------------------+
//| Loop utama: semua keputusan diambil saat bar baru (bar 1 closed)  |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(InpBreakEvenRR > 0)
      ManageBreakEven();

   if(!IsNewBar())
      return;

   if(!LoadMarketData())
     {
      ShowInfo();
      return;
     }
   ComputeSwings();
   ManagePending();
   g_cntBars++;

   int posCount = CountMyPositions();
   if(posCount >= InpMaxOpenTrades)
     {
      g_cntBlockPos++;
      g_status = "Posisi penuh (" + (string)posCount + "/" + (string)InpMaxOpenTrades + ")";
      ShowInfo();
      return;
     }
   if(!EntryAllowed())
     {
      ShowInfo();
      return;
     }

   SSetup s;
   bool found = DetectSetup(+1, s);
   if(!found)
      found = DetectSetup(-1, s);
   if(found)
     {
      if(InpDraw)
         DrawSetup(s);
      PlaceSetup(s);
     }
   ShowInfo();
  }

//+------------------------------------------------------------------+
//| Data pasar                                                        |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t == g_lastBar)
      return(false);
   g_lastBar = t;
   return(true);
  }

bool LoadMarketData()
  {
   ArraySetAsSeries(g_r, true);
   g_n = CopyRates(_Symbol, PERIOD_CURRENT, 0, InpLookback, g_r);
   if(g_n < 4 * InpSwingBars + 20)
     {
      g_status = "Data candle belum cukup (" + (string)g_n + ")";
      return(false);
     }
   double buf[1];
   if(CopyBuffer(g_hAtr, 0, 1, 1, buf) != 1 || buf[0] <= 0)
     {
      g_status = "ATR belum siap";
      return(false);
     }
   g_atr = buf[0];
   if(InpUseTrendFilter)
     {
      if(CopyBuffer(g_hEma, 0, 1, 1, buf) != 1)
        {
         g_status = "EMA belum siap";
         return(false);
        }
      g_ema = buf[0];
     }
   return(true);
  }

// swing = fractal InpSwingBars bar kiri-kanan. Kiri (lebih tua) boleh sama tinggi -> equal high/low tetap swing.
void ComputeSwings()
  {
   const int n = InpSwingBars;
   ArrayResize(g_sh, g_n);
   ArrayResize(g_sl, g_n);
   for(int i = 0; i < g_n; i++) { g_sh[i] = false; g_sl[i] = false; }
   for(int i = n + 1; i < g_n - n; i++)
     {
      bool sh = true, sl = true;
      for(int k = 1; k <= n && (sh || sl); k++)
        {
         if(!(g_r[i].high >= g_r[i + k].high && g_r[i].high > g_r[i - k].high)) sh = false;
         if(!(g_r[i].low  <= g_r[i + k].low  && g_r[i].low  < g_r[i - k].low))  sl = false;
        }
      g_sh[i] = sh;
      g_sl[i] = sl;
     }
  }

//+------------------------------------------------------------------+
//| Helper arah. Ext = sisi yang disapu (BUY: low), Opp = lawannya.   |
//| Semua perbandingan memakai dir*(a-b) agar BUY/SELL satu kode.     |
//+------------------------------------------------------------------+
double Ext(const int dir, const int i)        { return(dir > 0 ? g_r[i].low  : g_r[i].high); }
double Opp(const int dir, const int i)        { return(dir > 0 ? g_r[i].high : g_r[i].low);  }
bool   IsExtSwing(const int dir, const int i) { return(dir > 0 ? g_sl[i] : g_sh[i]); }
bool   IsOppSwing(const int dir, const int i) { return(dir > 0 ? g_sh[i] : g_sl[i]); }

int NearestExtSwingBefore(const int dir, const int k)
  {
   for(int i = k + 1; i < g_n; i++)
      if(IsExtSwing(dir, i)) return(i);
   return(-1);
  }

int NearestOppSwingBefore(const int dir, const int k)
  {
   for(int i = k + 1; i < g_n; i++)
      if(IsOppSwing(dir, i)) return(i);
   return(-1);
  }

void InitSetup(SSetup &s)
  {
   s.dir = 0;
   s.barSweep = s.barLiq = s.barMss = s.barExt = s.barOb = -1;
   s.liqLevel = s.sweepExtreme = s.mssLevel = 0.0;
   s.hasOB = s.obValid = s.hasFVG = s.hasIFVG = false;
   s.obNear = s.obFar = s.fvgNear = s.fvgFar = s.ifvgNear = s.ifvgFar = 0.0;
   s.poi = POI_NONE;
   s.zoneNear = s.zoneFar = s.entry = s.sl = s.tp = 0.0;
   s.tpBar = -1;
   s.skipReason = "";
  }

string PoiName(const ENUM_POI p)
  {
   switch(p)
     {
      case POI_FVG:  return("FVG");
      case POI_OB:   return("OB");
      case POI_IFVG: return("IFVG");
      default:       return("-");
     }
  }

string DirName(const int dir) { return(dir > 0 ? "BUY" : "SELL"); }

//+------------------------------------------------------------------+
//| DETEKSI SETUP. Bar 1 (closed terakhir) harus menjadi candle MSS.  |
//+------------------------------------------------------------------+
bool DetectSetup(const int dir, SSetup &s)
  {
   InitSetup(s);
   s.dir = dir;
   const int    n   = InpSwingBars;
   const double atr = g_atr;

   //--- 1. $ LIQUIDITY SWEEP: candle j (2..SweepMaxBars+1) yang menusuk swing terakhir yang lebih tua darinya
   int j = -1, p = -1;
   for(int k = 2; k <= InpSweepMaxBars + 1 && k < g_n - n - 1; k++)
     {
      int pp = NearestExtSwingBefore(dir, k);
      if(pp < 0) break;
      double lvl = Ext(dir, pp);
      double pen = dir * (lvl - Ext(dir, k));          // kedalaman tusukan (>0 = menembus liquidity)
      if(pen <= 0 || pen < InpSweepMinAtr * atr) continue;
      if(InpSweepMustClose && dir * (g_r[k].close - lvl) <= 0) continue;   // close masih di luar
      j = k; p = pp;
      break;
     }
   if(j < 0) return(false);
   s.barSweep = j; s.barLiq = p; s.liqLevel = Ext(dir, p);

   //--- 2. Level struktur = swing berlawanan terdekat yang lebih tua dari sweep (lower high / higher low terakhir)
   int q = NearestOppSwingBefore(dir, j);
   if(q < 0) return(false);
   double mss = Opp(dir, q);
   s.barMss = q; s.mssLevel = mss;

   //--- 3. MSS: bar 1 harus candle PERTAMA yang close menembus level struktur
   double brk = dir * (g_r[1].close - mss);
   if(brk <= 0 || brk < InpMssMinBreakAtr * atr) return(false);
   for(int k = 2; k < q; k++)
      if(dir * (g_r[k].close - mss) > 0) return(false);  // sudah ditembus sebelumnya -> bukan sinyal baru
   g_cntMss++;

   //--- 4. Ujung sweep: ekstrem di antara candle sweep dan candle MSS
   int m = 1;
   for(int k = 1; k <= j; k++)
      if(dir * (Ext(dir, m) - Ext(dir, k)) > 0) m = k;
   s.barExt = m; s.sweepExtreme = Ext(dir, m);

   //--- 4b. Filter kualitas struktur
   if(dir * (mss - s.sweepExtreme) < InpMinLegAtr * atr)
     {
      g_cntSkipLeg++;
      return(false);                                    // leg terlalu kecil = struktur mikro
     }
   if(InpUseTrendFilter && dir * (g_r[1].close - g_ema) <= 0)
     {
      g_cntSkipTrend++;
      return(false);
     }

   //--- 5. ORDER BLOCK: candle berlawanan arah terakhir sebelum impuls (di / sebelum ujung sweep)
   for(int k = m; k <= j + n && k < g_n; k++)
     {
      if(dir * (g_r[k].open - g_r[k].close) <= 0) continue;   // BUY butuh candle bearish
      s.hasOB = true; s.barOb = k;
      s.obNear = Opp(dir, k); s.obFar = Ext(dir, k);
      // valid jika liquidity di balik OB sudah diambil: wick candle sesudahnya menembus tepi jauh OB,
      // atau OB itu sendiri candle ujung sweep (wick-nya yang menyapu liquidity)
      if(k == m) s.obValid = true;
      else
         for(int t = 1; t < k; t++)
            if(dir * (s.obFar - Ext(dir, t)) > 0) { s.obValid = true; break; }
      break;
     }

   //--- 6. FVG searah di leg impulsif (ujung sweep -> candle MSS). triplet (k+1,k,k-1): BUY low[k-1] > high[k+1]
   for(int k = 2; k <= m; k++)
     {
      double nearE = (dir > 0) ? g_r[k - 1].low  : g_r[k - 1].high;
      double farE  = (dir > 0) ? g_r[k + 1].high : g_r[k + 1].low;
      double size  = dir * (nearE - farE);
      if(size <= 0 || size < InpMinFvgAtr * atr) continue;
      s.hasFVG = true; s.fvgNear = nearE; s.fvgFar = farE;
      if(InpFvgPick == FVG_NEAREST) break;               // deepest: lanjut, ambil yang terakhir (dekat OB)
     }

   //--- 7. IFVG: FVG berlawanan di leg sebelumnya (swing struktur -> ujung sweep) yang ditembus close MSS
   for(int k = m + 1; k <= q - 1; k++)
     {
      double nearE = (dir > 0) ? g_r[k + 1].low  : g_r[k + 1].high;
      double farE  = (dir > 0) ? g_r[k - 1].high : g_r[k - 1].low;
      double size  = dir * (nearE - farE);
      if(size <= 0 || size < InpMinFvgAtr * atr) continue;
      if(dir * (g_r[1].close - nearE) <= 0) continue;   // belum ditembus -> belum inversion
      if(!s.hasIFVG || dir * (nearE - s.ifvgNear) > 0)  // ambil yang paling dekat harga
        { s.hasIFVG = true; s.ifvgNear = nearE; s.ifvgFar = farE; }
     }

   //--- 8. Pilih POI
   bool obOk = s.hasOB && (s.obValid || !InpObRequireSweep);
   switch(InpZoneMode)
     {
      case ZONE_FVG:  if(s.hasFVG)  s.poi = POI_FVG;  break;
      case ZONE_OB:   if(obOk)      s.poi = POI_OB;   break;
      case ZONE_IFVG: if(s.hasIFVG) s.poi = POI_IFVG; break;
      default:
         if(s.hasFVG)       s.poi = POI_FVG;
         else if(s.hasIFVG) s.poi = POI_IFVG;
         else if(obOk)      s.poi = POI_OB;
     }
   if(s.poi == POI_NONE)
     {
      g_cntNoPoi++;
      g_status = StringFormat("MSS %s @%s tanpa POI valid (FVG:%s IFVG:%s OB:%s)", DirName(dir),
                              TimeToString(g_r[1].time, TIME_DATE | TIME_MINUTES),
                              s.hasFVG ? "ya" : "-", s.hasIFVG ? "ya" : "-",
                              s.hasOB ? (s.obValid ? "valid" : "invalid") : "-");
      Print(g_status);
      return(false);
     }
   switch(s.poi)
     {
      case POI_FVG:  s.zoneNear = s.fvgNear;  s.zoneFar = s.fvgFar;  break;
      case POI_OB:   s.zoneNear = s.obNear;   s.zoneFar = s.obFar;   break;
      case POI_IFVG: s.zoneNear = s.ifvgNear; s.zoneFar = s.ifvgFar; break;
     }
   double pct = MathMax(0, MathMin(100, InpZoneEntryPct)) / 100.0;
   s.entry = s.zoneNear - (s.zoneNear - s.zoneFar) * pct;

   //--- 9. SL (basis ATR)
   double slBase = s.sweepExtreme;
   if(InpSlMode == SL_BEHIND_OB && s.hasOB) slBase = s.obFar;
   if(dir * (s.zoneFar - slBase) < 0) slBase = s.sweepExtreme;   // SL harus di balik zona entry
   s.sl = slBase - dir * InpSlBufferAtr * atr;
   double risk = dir * (s.entry - s.sl);
   if(risk <= 0) return(false);
   if(risk < InpSlMinAtr * atr)
     {
      g_cntSkipSl++;
      g_status = StringFormat("Setup %s %s dilewati: jarak SL %.1f ATR < minimal %.1f ATR", DirName(dir), PoiName(s.poi), risk / atr, InpSlMinAtr);
      Print(g_status);
      return(false);
     }

   //--- 10. TP
   s.tpBar = -1;
   if(InpTpMode == TP_LIQUIDITY)
     {
      for(int i = n + 1; i < g_n - n; i++)
        {
         if(!IsOppSwing(dir, i)) continue;
         double lvl = Opp(dir, i);
         if(dir * (lvl - g_r[1].close) <= 0) continue;  // liquidity ini sudah dilewati harga
         double tp = lvl - dir * InpTpBufferAtr * atr;
         double rr = dir * (tp - s.entry) / risk;
         if(rr < InpMinRR) continue;                     // terlalu dekat, cari liquidity berikutnya
         if(rr > InpMaxRR) tp = s.entry + dir * InpMaxRR * risk;
         s.tp = tp; s.tpBar = i;
         break;
        }
     }
   if(s.tpBar < 0)
      s.tp = s.entry + dir * InpRR * risk;

   return(true);
  }

//+------------------------------------------------------------------+
//| EKSEKUSI: limit order di zona, atau market jika harga sudah di zona|
//+------------------------------------------------------------------+
void PlaceSetup(SSetup &s)
  {
   const int    dir    = s.dir;
   const int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const double stops  = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   const double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double spread = MathMax(ask - bid, 0.0);
   const double px     = (dir > 0) ? ask : bid;

   //--- kompensasi spread: chart = Bid. BUY: SL/TP dieksekusi di Bid (sesuai chart), tidak perlu geser.
   //    SELL: SL/TP dieksekusi di Ask = Bid + spread -> geser SL & TP ke atas sebesar spread
   //    agar level efektifnya tetap sama dengan level di chart.
   double comp = (InpSpreadCompensate && dir < 0) ? spread : 0.0;
   double entry = NormalizeDouble(s.entry, digits);
   double sl    = NormalizeDouble(s.sl + comp, digits);
   double tp    = NormalizeDouble(s.tp + comp, digits);

   string side = DirName(dir);
   string cmt  = "SMC " + PoiName(s.poi) + " " + side;
   g_lastSetup = StringFormat("%s %s @%s  $=%s  MSS=%s  zona %s-%s  SL=%s  TP=%s (%s)  ATR=%s  spread=%d pts",
                              side, PoiName(s.poi), TimeToString(g_r[1].time, TIME_DATE | TIME_MINUTES),
                              DoubleToString(s.liqLevel, digits), DoubleToString(s.mssLevel, digits),
                              DoubleToString(s.zoneFar, digits), DoubleToString(s.zoneNear, digits),
                              DoubleToString(sl, digits), DoubleToString(tp, digits),
                              s.tpBar >= 0 ? "liquidity" : "RR", DoubleToString(g_atr, digits),
                              (int)MathRound(spread / _Point));
   Print("Setup: ", g_lastSetup);

   //--- tentukan cara masuk
   bool   market = false;
   double risk   = dir * (entry - sl);
   if(dir * (px - entry) > stops)
      market = false;                                   // harga masih di luar zona -> limit
   else if(dir * (px - s.zoneFar) >= 0)
     {
      market = true;                                    // harga sudah di dalam zona -> market
      risk   = dir * (px - sl);
     }
   else
     {
      g_status = "Setup dilewati: harga sudah menembus zona " + PoiName(s.poi);
      Print(g_status);
      return;
     }

   //--- filter spread relatif terhadap risiko
   if(InpMaxSpreadRiskPct > 0 && risk > 0 && spread > risk * InpMaxSpreadRiskPct / 100.0)
     {
      g_cntSkipSpreadRisk++;
      g_status = StringFormat("Setup dilewati: spread %.1f%% dari jarak SL (> %.1f%%)", spread / risk * 100.0, InpMaxSpreadRiskPct);
      Print(g_status);
      return;
     }
   //--- stops level broker
   double refPx = market ? px : entry;
   if(risk <= stops || dir * (tp - refPx) <= stops)
     {
      g_cntSkipStops++;
      g_status = "Setup dilewati: jarak SL/TP di bawah stops level broker";
      Print(g_status);
      return;
     }

   //--- lot & cek risiko aktual terhadap equity
   double lot = CalcLot(risk);
   if(lot <= 0) return;
   double riskMoney = LossForLot(lot, risk);
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskPct   = (equity > 0) ? riskMoney / equity * 100.0 : 0.0;
   if(InpMaxRiskPct > 0 && riskPct > InpMaxRiskPct)
     {
      g_cntSkipRisk++;
      g_status = StringFormat("Setup dilewati: risiko %.2f lot = $%.2f = %.1f%% equity (> batas %.1f%%)", lot, riskMoney, riskPct, InpMaxRiskPct);
      Print(g_status);
      return;
     }
   if(riskPct > 3.0)
      PrintFormat("PERINGATAN risiko: %.2f lot x jarak SL %s = $%.2f = %.1f%% equity ($%.2f). Modal terlalu kecil untuk lot ini.",
                  lot, DoubleToString(risk, digits), riskMoney, riskPct, equity);

   // setup baru menggantikan pending lama
   DeleteMyPendings();

   //--- kirim order
   bool ok;
   if(!market)
     {
      ok = (dir > 0) ? trade.BuyLimit(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, cmt)
                     : trade.SellLimit(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, cmt);
      if(ok)
        {
         g_pendTicket = trade.ResultOrder(); g_pendBarsLeft = InpEntryValidBars;
         g_pendDir = dir; g_pendSl = sl; g_pendTp = tp;
         g_status = StringFormat("%s LIMIT #%I64u @%s lot %.2f (risiko $%.2f = %.1f%%), berlaku %d candle",
                                 side, g_pendTicket, DoubleToString(entry, digits), lot, riskMoney, riskPct, InpEntryValidBars);
        }
     }
   else
     {
      ok = (dir > 0) ? trade.Buy(lot, _Symbol, 0.0, sl, tp, cmt)
                     : trade.Sell(lot, _Symbol, 0.0, sl, tp, cmt);
      if(ok)
         g_status = StringFormat("%s MARKET lot %.2f (harga sudah di zona %s), risiko $%.2f = %.1f%%", side, lot, PoiName(s.poi), riskMoney, riskPct);
     }

   g_cntSetup++;
   if(ok) g_cntOrderOk++; else g_cntOrderFail++;
   if(!ok)
      g_status = StringFormat("Order %s gagal: %d %s", side, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   Print(g_status);
  }

//+------------------------------------------------------------------+
//| Kelola limit order: kadaluarsa / setup gagal / target lewat       |
//+------------------------------------------------------------------+
void ManagePending()
  {
   if(g_pendTicket == 0) return;
   if(!OrderSelect(g_pendTicket))
     {
      g_pendTicket = 0;                                 // sudah terisi (jadi posisi) atau dihapus manual
      return;
     }
   g_pendBarsLeft--;

   string why = "";
   if(g_pendBarsLeft <= 0)                                     why = "masa berlaku habis";
   else if(g_pendDir * (g_r[1].close - g_pendSl) < 0)          why = "harga close melewati SL sebelum terisi (setup gagal)";
   else if(g_pendDir * (g_r[1].close - g_pendTp) > 0)          why = "target tercapai tanpa terisi";
   if(why == "") return;

   if(trade.OrderDelete(g_pendTicket))
      g_status = StringFormat("Limit #%I64u dihapus: %s", g_pendTicket, why);
   else
      g_status = StringFormat("Gagal hapus limit #%I64u: %s", g_pendTicket, trade.ResultRetcodeDescription());
   Print(g_status);
   g_pendTicket = 0;
  }

// adopsi limit order milik EA yang masih ada setelah restart
void RecoverPending()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic || OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_LIMIT && type != ORDER_TYPE_SELL_LIMIT) continue;
      g_pendTicket = tk;
      g_pendDir    = (type == ORDER_TYPE_BUY_LIMIT) ? 1 : -1;
      g_pendSl     = OrderGetDouble(ORDER_SL);
      g_pendTp     = OrderGetDouble(ORDER_TP);
      g_pendBarsLeft = InpEntryValidBars;
      Print("Limit order #", tk, " milik EA ditemukan, dikelola ulang");
      return;
     }
  }

//+------------------------------------------------------------------+
//| Break-even (opsional, default OFF)                                |
//+------------------------------------------------------------------+
void ManageBreakEven()
  {
   if(g_atr <= 0) return;
   const int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const double stops  = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      int    dir  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      if(sl == 0.0 || dir * (sl - open) >= 0) continue;   // tanpa SL, atau sudah break-even

      double risk = dir * (open - sl);
      double px   = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(dir * (px - open) < InpBreakEvenRR * risk) continue;

      double newSl = NormalizeDouble(open + dir * InpBeOffsetAtr * g_atr, digits);
      if(dir * (px - newSl) <= stops) continue;
      if(!trade.PositionModify(tk, newSl, tp))
         Print("Break-even #", tk, " gagal: ", trade.ResultRetcodeDescription());
      else
         Print("Break-even #", tk, " SL -> ", DoubleToString(newSl, digits));
     }
  }

//+------------------------------------------------------------------+
//| Lot & risiko                                                      |
//+------------------------------------------------------------------+
// kerugian (mata uang akun) untuk lot tertentu jika harga bergerak slDist melawan
double LossForLot(const double lot, const double slDist)
  {
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0 || tickSize <= 0) return(0.0);
   return(slDist / tickSize * tickVal * lot);
  }

double CalcLot(const double slDist)
  {
   double lot = InpLot;
   if(InpLotMode == LOT_RISK_PERCENT)
     {
      double lossPerLot = LossForLot(1.0, slDist);
      if(lossPerLot > 0)
         lot = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0 / lossPerLot;
     }
   return(NormalizeLot(lot));
  }

double NormalizeLot(double lot)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepLot <= 0) stepLot = 0.01;
   lot = MathFloor(lot / stepLot + 1e-9) * stepLot;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   int digitsLot = 0;
   for(double st = stepLot; st < 1.0 && digitsLot < 8; st *= 10.0) digitsLot++;
   return(NormalizeDouble(lot, digitsLot));
  }

//+------------------------------------------------------------------+
//| Filter spread & jam                                               |
//+------------------------------------------------------------------+
bool EntryAllowed()
  {
   if(InpMaxSpreadPts > 0)
     {
      int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spread > InpMaxSpreadPts)
        {
         g_cntBlockSpread++;
         g_status = "Spread " + (string)spread + " > batas " + (string)InpMaxSpreadPts;
         LogBlock("ENTRY DIBLOK: " + g_status + " points (lonjakan spread).");
         return(false);
        }
     }
   if(InpStartHour != InpEndHour)
     {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      bool inside = (InpStartHour < InpEndHour) ? (dt.hour >= InpStartHour && dt.hour < InpEndHour)
                                                : (dt.hour >= InpStartHour || dt.hour < InpEndHour);
      if(!inside)
        {
         g_cntBlockTime++;
         g_status = "Di luar jam trading";
         LogBlock("ENTRY DIBLOK: di luar jam trading " + (string)InpStartHour + "-" + (string)InpEndHour + " (server)");
         return(false);
        }
     }
   g_lastBlock = "";
   return(true);
  }

// cetak alasan blokir hanya saat alasannya berubah (anti spam log)
void LogBlock(const string reason)
  {
   if(reason == g_lastBlock) return;
   g_lastBlock = reason;
   Print(reason);
  }

//+------------------------------------------------------------------+
//| Diagnosa lingkungan saat init                                     |
//+------------------------------------------------------------------+
void PrintEnvironment()
  {
   int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   int    spread  = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   long   stops   = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   long   mode    = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   PrintFormat("SMC EA v1.10 init: %s %s | digits=%d point=%s | spread=%d pts (batas abs=%d, rel=%.0f%% risiko) | stops=%d | lot min=%.2f | nilai 1.00 lot per 1 unit harga=$%.2f | equity=$%.2f | mode=%s",
               _Symbol, EnumToString(_Period), digits, DoubleToString(_Point, digits), spread, InpMaxSpreadPts, InpMaxSpreadRiskPct,
               (int)stops, minLot, (tickSz > 0 ? tickVal / tickSz : 0.0), equity, EnumToString((ENUM_SYMBOL_TRADE_MODE)mode));
   if(InpMaxSpreadPts > 0 && spread > InpMaxSpreadPts)
      PrintFormat("PERINGATAN: spread saat ini %d > InpMaxSpreadPts %d -> EA tidak entry sampai spread turun.", spread, InpMaxSpreadPts);
   if(InpLotMode == LOT_FIXED && equity > 0 && tickSz > 0)
     {
      // estimasi: SL tipikal ~1.3 ATR; ATR belum siap saat init, jadi pakai contoh $5 untuk gold / 50 pips forex
      double sampleDist = (digits <= 3) ? 5.0 : 50 * 10 * _Point;
      double loss = sampleDist / tickSz * tickVal * InpLot;
      PrintFormat("Cek risiko: lot %.2f dengan SL %s = $%.2f = %.1f%% equity. Disarankan <= 1-2%% per trade.",
                  InpLot, DoubleToString(sampleDist, digits), loss, loss / equity * 100.0);
     }
   if(mode == SYMBOL_TRADE_MODE_DISABLED || mode == SYMBOL_TRADE_MODE_CLOSEONLY)
      Print("PERINGATAN: trading di symbol ini dinonaktifkan/close-only oleh broker.");
  }

//+------------------------------------------------------------------+
//| Posisi / pending milik EA                                         |
//+------------------------------------------------------------------+
int CountMyPositions()
  {
   int cnt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagic && PositionGetString(POSITION_SYMBOL) == _Symbol) cnt++;
     }
   return(cnt);
  }

void DeleteMyPendings()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic || OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(!trade.OrderDelete(tk))
         Print("Gagal hapus pending #", tk, ": ", trade.ResultRetcodeDescription());
     }
   g_pendTicket = 0;
  }

//+------------------------------------------------------------------+
//| Gambar setup di chart                                             |
//+------------------------------------------------------------------+
void DrawSetup(const SSetup &s)
  {
   color    clr  = (s.dir > 0) ? InpColorBuy : InpColorSell;
   string   id   = OBJ_PREFIX + (string)(long)g_r[1].time + "_";
   datetime tEnd = g_r[1].time + PeriodSeconds() * (InpEntryValidBars + 1);

   DrawLine(id + "LIQ", g_r[s.barLiq].time, s.liqLevel, g_r[s.barSweep].time, s.liqLevel, clr, STYLE_DOT);
   DrawText(id + "LIQt", g_r[s.barSweep].time, s.liqLevel, "$", clr);
   DrawLine(id + "MSS", g_r[s.barMss].time, s.mssLevel, g_r[1].time, s.mssLevel, clr, STYLE_DASH);
   DrawText(id + "MSSt", g_r[1].time, s.mssLevel, "MSS", clr);

   if(s.hasOB)
     {
      DrawRect(id + "OB", g_r[s.barOb].time, s.obNear, tEnd, s.obFar, clr, s.poi == POI_OB);
      DrawText(id + "OBt", tEnd, s.obNear, s.obValid ? "OB" : "OB (invalid)", clr);
     }
   if(s.hasFVG)
     {
      DrawRect(id + "FVG", g_r[s.barExt].time, s.fvgNear, tEnd, s.fvgFar, clr, s.poi == POI_FVG);
      DrawText(id + "FVGt", tEnd, s.fvgNear, "FVG", clr);
     }
   if(s.hasIFVG)
     {
      DrawRect(id + "IFVG", g_r[s.barExt].time, s.ifvgNear, tEnd, s.ifvgFar, clr, s.poi == POI_IFVG);
      DrawText(id + "IFVGt", tEnd, s.ifvgNear, "IFVG", clr);
     }

   DrawLine(id + "ENT", g_r[1].time, s.entry, tEnd, s.entry, clr, STYLE_SOLID);
   DrawText(id + "ENTt", tEnd, s.entry, "ENTRY " + PoiName(s.poi), clr);
   DrawLine(id + "SL",  g_r[1].time, s.sl, tEnd, s.sl, clrRed, STYLE_SOLID);
   DrawText(id + "SLt", tEnd, s.sl, "SL", clrRed);
   DrawLine(id + "TP",  g_r[1].time, s.tp, tEnd, s.tp, clrDodgerBlue, STYLE_SOLID);
   DrawText(id + "TPt", tEnd, s.tp, s.tpBar >= 0 ? "TP ($)" : "TP (RR)", clrDodgerBlue);
  }

void DrawRect(const string name, datetime t1, double p1, datetime t2, double p2, color clr, bool chosen)
  {
   if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2)) return;
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FILL, chosen);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  }

void DrawLine(const string name, datetime t1, double p1, datetime t2, double p2, color clr, ENUM_LINE_STYLE style)
  {
   if(!ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2)) return;
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  }

void DrawText(const string name, datetime t, double p, const string text, color clr)
  {
   if(!ObjectCreate(0, name, OBJ_TEXT, 0, t, p)) return;
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  }

//+------------------------------------------------------------------+
//| Info di pojok chart                                               |
//+------------------------------------------------------------------+
void ShowInfo()
  {
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   string pend = (g_pendTicket != 0)
                 ? StringFormat("#%I64u (%s LIMIT) sisa %d candle", g_pendTicket, DirName(g_pendDir), g_pendBarsLeft) : "-";
   Comment("SMC Structure EA v1.10  |  ", _Symbol, " ", EnumToString(PERIOD_CURRENT),
           "  |  ATR ", DoubleToString(g_atr, digits), "  spread ", (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), " pts",
           "\nStatus       : ", g_status,
           "\nSetup akhir  : ", g_lastSetup,
           "\nPending      : ", pend,
           "\nPosisi EA    : ", CountMyPositions(), " / ", InpMaxOpenTrades,
           "\nMSS/eksekusi : ", g_cntMss, " / ", g_cntSetup, "   ditolak leg=", g_cntSkipLeg, " SL=", g_cntSkipSl, " POI=", g_cntNoPoi,
           "\nMode         : zona ", EnumToString(InpZoneMode), "  SL ", EnumToString(InpSlMode), "  TP ", EnumToString(InpTpMode),
           "  BE ", InpBreakEvenRR > 0 ? DoubleToString(InpBreakEvenRR, 1) + "R" : "off");
  }
//+------------------------------------------------------------------+
