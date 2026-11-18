//+------------------------------------------------------------------+
//|  Supertrend Multi-Timeframe Pyramiding EA           © Eye Algo   |
//+------------------------------------------------------------------+
#property copyright   "Eye Algo"
#property version     "1.00"
#property description "Higher-timeframe Supertrend sets the direction, chart-timeframe Supertrend flips add entries (up to 5 per trend). Optional exit-timeframe flip exit, per-entry skip, separate long/short lots, long/short dashboard."

#define EA_NAME  "ST MTF Pyramiding EA"
#define EA_MAGIC 26010106

enum ENUM_PYR_DIR
  {
   PYR_BOTH  = 0, // Both
   PYR_LONG  = 1, // Long only
   PYR_SHORT = 2  // Short only
  };

enum ENUM_PYR_SL
  {
   PYR_SL_NONE  = 0, // None
   PYR_SL_LINE  = 1, // Supertrend line (trailing)
   PYR_SL_ATR   = 2  // ATR (fixed)
  };

input group "Trend (higher timeframe)"
input ENUM_TIMEFRAMES InpTrendTF = PERIOD_H4; // Trend timeframe
input int    InpTrendAtr  = 10;   // ATR period
input double InpTrendMult = 3.0;  // Multiplier

input group "Entries (chart timeframe)"
input int    InpEntryAtr  = 10;   // ATR period
input double InpEntryMult = 3.0;  // Multiplier
input bool   InpRma       = true; // RMA ATR (same as TradingView)

input group "Exits"
input bool            InpUseExitTF = true;      // Exit on exit-timeframe Supertrend flip
input ENUM_TIMEFRAMES InpExitTF    = PERIOD_H1; // Exit timeframe
input int    InpExitAtr   = 10;   // Exit ATR period
input double InpExitMult  = 3.0;  // Exit multiplier
input ENUM_PYR_SL InpSlMode = PYR_SL_LINE; // Stop loss
input int    InpSlAtrLen  = 14;   // SL ATR length
input double InpSlAtrMul  = 2.0;  // SL ATR multiplier

input group "Pyramiding"
input ENUM_PYR_DIR InpDir = PYR_BOTH; // Trade direction
input int    InpMaxEntries = 5;   // Max entries per trend (1-5)
input bool   InpSlot1 = true;     // Take entry #1
input bool   InpSlot2 = true;     // Take entry #2
input bool   InpSlot3 = true;     // Take entry #3
input bool   InpSlot4 = true;     // Take entry #4
input bool   InpSlot5 = true;     // Take entry #5
input double InpLongLot  = 0.10;  // Long lot per entry
input double InpShortLot = 0.10;  // Short lot per entry

//+------------------------------------------------------------------+
//|  EYE ALGO CORE HELPERS                                           |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

input group "General"
input ulong  InpMagic      = EA_MAGIC;  // Magic number
input int    InpMaxSpread  = 0;         // Max spread in points (0 = off)
input bool   InpAlerts     = false;     // Popup alert on new trade
input bool   InpPush       = false;     // Push notification on new trade
input bool   InpShowPanel  = true;      // Show info panel
input bool   InpShowArrows = true;      // Draw signal arrows

CTrade   g_trade;
datetime g_lastBar = 0;

//--- price / volume -------------------------------------------------
double NP(double p)
  {
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts > 0) p = MathRound(p / ts) * ts;
   return NormalizeDouble(p, _Digits);
  }

double VolStep() { double s = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP); return s > 0 ? s : 0.01; }

double NormLot(double lot)
  {
   double step = VolStep();
   double mn   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lot = MathFloor(lot / step + 1e-9) * step;
   lot = MathMax(mn, MathMin(mx, lot));
   return NormalizeDouble(lot, 8);
  }

double StopsMin() { return (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point; }

bool SpreadOk()
  {
   if(InpMaxSpread > 0 && SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpread)
     {
      Print(EA_NAME, ": spread too high, signal skipped");
      return false;
     }
   return true;
  }

// distance helper: mode 0 = ATR, 1 = fixed points, 2 = percent of price
double BasicSlDist(int mode, double atr, double atrMul, int points, double pct, double price)
  {
   if(mode == 0) return atr * atrMul;
   if(mode == 1) return points * _Point;
   return price * pct / 100.0;
  }

//--- bars / data ----------------------------------------------------
bool IsNewBar()
  {
   datetime t = iTime(_Symbol, _Period, 0);
   if(t == 0 || t == g_lastBar) return false;
   g_lastBar = t;
   return true;
  }

double Buf(int handle, int buffer, int shift)
  {
   double v[1];
   if(CopyBuffer(handle, buffer, shift, 1, v) != 1) return EMPTY_VALUE;
   return v[0];
  }

// closed bars only, oldest first: r[n-1] is bar #1 of that timeframe
int GetRatesTF(ENUM_TIMEFRAMES tf, int count, MqlRates &r[])
  {
   ArraySetAsSeries(r, false);
   return CopyRates(_Symbol, tf, 1, count, r);
  }

int GetRates(int count, MqlRates &r[]) { return GetRatesTF(_Period, count, r); }

// TradingView-style ATR (RMA smoothing), oldest first
void AtrRMA(const MqlRates &r[], int n, int len, double &out[])
  {
   ArrayResize(out, n);
   ArrayInitialize(out, 0.0);
   double sum = 0;
   for(int i = 0; i < n; i++)
     {
      double tr = r[i].high - r[i].low;
      if(i > 0)
         tr = MathMax(tr, MathMax(MathAbs(r[i].high - r[i - 1].close), MathAbs(r[i].low - r[i - 1].close)));
      if(i < len)
        {
         sum += tr;
         out[i] = sum / (i + 1);
        }
      else
         out[i] = (out[i - 1] * (len - 1) + tr) / len;
     }
  }

// TradingView-style EMA (SMA seed), oldest first
void EmaArr(const double &src[], int n, int len, double &out[])
  {
   ArrayResize(out, n);
   ArrayInitialize(out, 0.0);
   double a = 2.0 / (len + 1), sum = 0;
   for(int i = 0; i < n; i++)
     {
      if(i < len)
        {
         sum += src[i];
         out[i] = sum / (i + 1);
        }
      else
         out[i] = a * src[i] + (1 - a) * out[i - 1];
     }
  }

double AtrTV(int len, int shift = 1)
  {
   int cnt = MathMax(len * 10, 200);
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int n = CopyRates(_Symbol, _Period, shift, cnt, r);
   if(n < len + 1) return 0;
   double out[];
   AtrRMA(r, n, len, out);
   return out[n - 1];
  }

// TradingView Supertrend (hl2 source, RMA ATR by default), oldest first.
// trend[i] = 1 up / -1 down, line[i] = active band
void SupertrendArr(const MqlRates &r[], int n, int len, double mult, bool rma, double &line[], int &trend[])
  {
   ArrayResize(line, n);
   ArrayResize(trend, n);
   double atr[];
   if(rma) AtrRMA(r, n, len, atr);
   else
     {
      ArrayResize(atr, n);
      double sum = 0;
      for(int i = 0; i < n; i++)
        {
         double tr = r[i].high - r[i].low;
         if(i > 0) tr = MathMax(tr, MathMax(MathAbs(r[i].high - r[i - 1].close), MathAbs(r[i].low - r[i - 1].close)));
         sum += tr;
         if(i >= len)
           {
            double old = r[i - len].high - r[i - len].low;
            if(i - len > 0) old = MathMax(old, MathMax(MathAbs(r[i - len].high - r[i - len - 1].close), MathAbs(r[i - len].low - r[i - len - 1].close)));
            sum -= old;
           }
         atr[i] = sum / MathMin(i + 1, len);
        }
     }
   double upPrev = 0, dnPrev = 0;
   int tr = 1;
   for(int i = 0; i < n; i++)
     {
      double src = (r[i].high + r[i].low) / 2.0;
      double up = src - mult * atr[i];
      double dn = src + mult * atr[i];
      double up1 = i == 0 ? up : upPrev;
      double dn1 = i == 0 ? dn : dnPrev;
      double c1  = i == 0 ? r[i].close : r[i - 1].close;
      if(c1 > up1) up = MathMax(up, up1);
      if(c1 < dn1) dn = MathMin(dn, dn1);
      if(tr == -1 && r[i].close > dn1) tr = 1;
      else if(tr == 1 && r[i].close < up1) tr = -1;
      trend[i] = tr;
      line[i]  = tr == 1 ? up : dn;
      upPrev = up;
      dnPrev = dn;
     }
  }

//--- positions ------------------------------------------------------
bool SelectMine(int i)
  {
   ulong t = PositionGetTicket(i);
   if(t == 0) return false;
   return PositionGetString(POSITION_SYMBOL) == _Symbol && (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic;
  }

int PosDirOfSelected() { return PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1; }

int PosDir()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(SelectMine(i)) return PosDirOfSelected();
   return 0;
  }

int CountPos(int dir)
  {
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(SelectMine(i) && (dir == 0 || PosDirOfSelected() == dir)) c++;
   return c;
  }

void ClosePositions(int dir, string reason = "")
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!SelectMine(i)) continue;
      if(dir != 0 && PosDirOfSelected() != dir) continue;
      ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
      if(g_trade.PositionClose(ticket) && reason != "")
         Print(EA_NAME, ": closed #", ticket, " (", reason, ")");
     }
  }

// filter = "" deletes all pending orders of this EA, otherwise only those whose comment contains filter
void DeletePendings(string filter = "")
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol || (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if(filter != "" && StringFind(OrderGetString(ORDER_COMMENT), filter) < 0) continue;
      g_trade.OrderDelete(t);
     }
  }

string GVKey(ulong posId, string k) { return "EA" + (string)InpMagic + "_" + (string)posId + "_" + k; }

void Notify(string msg)
  {
   if(InpAlerts) Alert(msg);
   if(InpPush) SendNotification(msg);
  }

void CleanGV()
  {
   string pre = "EA" + (string)InpMagic + "_";
   for(int g = GlobalVariablesTotal() - 1; g >= 0; g--)
     {
      string nm = GlobalVariableName(g);
      if(StringFind(nm, pre) != 0) continue;
      string rest = StringSubstr(nm, StringLen(pre));
      int u = StringFind(rest, "_");
      if(u < 0) continue;
      ulong id = (ulong)StringToInteger(StringSubstr(rest, 0, u));
      if(id == 0) continue;
      bool alive = false;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
         if(SelectMine(i) && (ulong)PositionGetInteger(POSITION_IDENTIFIER) == id) { alive = true; break; }
      if(!alive) GlobalVariableDel(nm);
     }
  }

//--- visuals --------------------------------------------------------
string ObjPre() { return "EA" + (string)InpMagic + "_"; }

void MarkSignal(int dir, int shift = 1)
  {
   if(!InpShowArrows) return;
   datetime t = iTime(_Symbol, _Period, shift);
   string name = ObjPre() + "sig_" + (string)(long)t + (dir == 1 ? "_B" : "_S");
   double price = dir == 1 ? iLow(_Symbol, _Period, shift) : iHigh(_Symbol, _Period, shift);
   if(ObjectFind(0, name) >= 0) return;
   ObjectCreate(0, name, dir == 1 ? OBJ_ARROW_BUY : OBJ_ARROW_SELL, 0, t, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, dir == 1 ? clrLimeGreen : clrTomato);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  }

// simple dark info panel; first line is the title
void DrawPanel(string &lines[], int width = 440)
  {
   string pre = ObjPre() + "pnl_";
   int n = ArraySize(lines);
   string bg = pre + "bg";
   if(ObjectFind(0, bg) < 0)
     {
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, 25);
      ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'15,17,21');
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bg, OBJPROP_COLOR, C'42,47,56');
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bg, OBJPROP_BACK, false);
     }
   ObjectSetInteger(0, bg, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, 18 * n + 12);
   for(int i = 0; i < 40; i++)
     {
      string nm = pre + IntegerToString(i);
      if(i >= n)
        {
         if(ObjectFind(0, nm) >= 0) ObjectDelete(0, nm);
         continue;
        }
      if(ObjectFind(0, nm) < 0)
        {
         ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, 18);
         ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, 31 + 18 * i);
         ObjectSetString(0, nm, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, 9);
         ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
        }
      ObjectSetString(0, nm, OBJPROP_TEXT, lines[i]);
      ObjectSetInteger(0, nm, OBJPROP_COLOR, i == 0 ? C'240,136,62' : C'230,232,235');
     }
   ChartRedraw(0);
  }

void AddLine(string &lines[], string s)
  {
   int n = ArraySize(lines);
   ArrayResize(lines, n + 1);
   lines[n] = s;
  }

// closed-deal statistics for this EA; dir 0 = all, 1 = longs, -1 = shorts
void DealStats(int dir, int &n, int &w, double &net, double &gp, double &gl, double &today)
  {
   n = 0; w = 0; net = 0; gp = 0; gl = 0; today = 0;
   HistorySelect(0, TimeCurrent() + 86400);
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol || (ulong)HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagic) continue;
      long e = HistoryDealGetInteger(d, DEAL_ENTRY);
      if(e != DEAL_ENTRY_OUT && e != DEAL_ENTRY_OUT_BY && e != DEAL_ENTRY_INOUT) continue;
      // a closing SELL deal closes a long position
      int posDir = HistoryDealGetInteger(d, DEAL_TYPE) == DEAL_TYPE_SELL ? 1 : -1;
      if(dir != 0 && posDir != dir) continue;
      double p = HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_COMMISSION);
      n++;
      if(p > 0) { w++; gp += p; } else gl -= p;
      net += p;
      if((datetime)HistoryDealGetInteger(d, DEAL_TIME) >= dayStart) today += p;
     }
  }

string PFText(double gp, double gl) { return gl > 0 ? DoubleToString(gp / gl, 2) : (gp > 0 ? "inf" : "-"); }

void CoreDeinit()
  {
   ObjectsDeleteAll(0, ObjPre() + "pnl_");
   Comment("");
  }


int    g_trendSide = 0;
int    g_slotCount = 0;
int    g_exitTrend = 0;
double g_entryLine = 0;
int    g_entryTrend = 0;

bool SlotOn(int k)
  {
   switch(k)
     {
      case 1: return InpSlot1;
      case 2: return InpSlot2;
      case 3: return InpSlot3;
      case 4: return InpSlot4;
      case 5: return InpSlot5;
     }
   return false;
  }

// last closed-bar Supertrend of a timeframe; returns false if data is not ready
bool StTF(ENUM_TIMEFRAMES tf, int len, double mult, int &tLast, int &tPrev, double &lineLast)
  {
   MqlRates r[];
   int n = GetRatesTF(tf, MathMax(300, len * 20), r);
   if(n < len + 10) return false;
   double line[];
   int tr[];
   SupertrendArr(r, n, len, mult, InpRma, line, tr);
   tLast = tr[n - 1];
   tPrev = tr[n - 2];
   lineLast = line[n - 1];
   return true;
  }

string TfName(ENUM_TIMEFRAMES tf) { string s = EnumToString(tf); StringReplace(s, "PERIOD_", ""); return s; }

int OnInit()
  {
   if(PeriodSeconds(InpTrendTF) < PeriodSeconds(_Period))
     {
      Print(EA_NAME, ": trend timeframe must be equal to or higher than the chart timeframe");
      return INIT_PARAMETERS_INCORRECT;
     }
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(20);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_lastBar = iTime(_Symbol, _Period, 0);
   int tl, tp;
   double ln;
   if(StTF(InpTrendTF, InpTrendAtr, InpTrendMult, tl, tp, ln))
     {
      g_trendSide = tl;
      g_slotCount = CountPos(tl);   // resume after a restart
     }
   UpdatePanel();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason) { CoreDeinit(); }

bool OpenSlot(int dir, int k)
  {
   if(!SpreadOk()) return false;
   double price = dir == 1 ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0;
   if(InpSlMode == PYR_SL_ATR)  sl = price - dir * AtrTV(InpSlAtrLen) * InpSlAtrMul;
   if(InpSlMode == PYR_SL_LINE) sl = g_entryLine;
   if(sl > 0 && dir * (price - sl) <= StopsMin() + _Point) sl = 0;   // too close: open without SL, trailing will set it
   double lot = NormLot(dir == 1 ? InpLongLot : InpShortLot);
   string cmt = (dir == 1 ? "Long #" : "Short #") + IntegerToString(k);
   bool ok = dir == 1 ? g_trade.Buy(lot, _Symbol, 0, sl > 0 ? NP(sl) : 0, 0, cmt) : g_trade.Sell(lot, _Symbol, 0, sl > 0 ? NP(sl) : 0, 0, cmt);
   if(!ok || g_trade.ResultRetcode() != TRADE_RETCODE_DONE)
     {
      Print(EA_NAME, ": order failed ", g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
      return false;
     }
   MarkSignal(dir);
   Notify(StringFormat("%s %s %s @ %s", EA_NAME, _Symbol, cmt, DoubleToString(price, _Digits)));
   return true;
  }

void TrailOnLine()
  {
   if(InpSlMode != PYR_SL_LINE || g_entryLine <= 0) return;
   double stopsMin = StopsMin();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!SelectMine(i)) continue;
      int dir = PosDirOfSelected();
      if(dir != g_entryTrend) continue;   // line is on the wrong side of this position
      double sl  = PositionGetDouble(POSITION_SL);
      double cur = dir == 1 ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double nsl = NP(g_entryLine);
      bool improves = sl <= 0 || dir * (nsl - sl) >= _Point;
      if(improves && dir * (cur - nsl) > stopsMin)
         g_trade.PositionModify((ulong)PositionGetInteger(POSITION_TICKET), nsl, PositionGetDouble(POSITION_TP));
     }
  }

void UpdatePanel()
  {
   if(!InpShowPanel) return;
   string lines[];
   int n = 0, w = 0;
   double net = 0, gp = 0, gl = 0, today = 0;
   AddLine(lines, EA_NAME + "  |  Eye Algo");
   AddLine(lines, StringFormat("Trend %-4s: %s    Exit %-4s: %s", TfName(InpTrendTF), g_trendSide == 1 ? "UP" : g_trendSide == -1 ? "DOWN" : "-",
                               TfName(InpExitTF), !InpUseExitTF ? "off" : g_exitTrend == 1 ? "UP" : "DOWN"));
   AddLine(lines, StringFormat("Entries this trend: %d / %d   Open: %d", g_slotCount, InpMaxEntries, CountPos(0)));
   AddLine(lines, "          Trades   Win%     P/L        PF");
   DealStats(1, n, w, net, gp, gl, today);
   AddLine(lines, StringFormat("Longs   %7d  %6.1f  %9.2f  %6s", n, n > 0 ? 100.0 * w / n : 0.0, net, PFText(gp, gl)));
   DealStats(-1, n, w, net, gp, gl, today);
   AddLine(lines, StringFormat("Shorts  %7d  %6.1f  %9.2f  %6s", n, n > 0 ? 100.0 * w / n : 0.0, net, PFText(gp, gl)));
   DealStats(0, n, w, net, gp, gl, today);
   AddLine(lines, StringFormat("Total   %7d  %6.1f  %9.2f  %6s", n, n > 0 ? 100.0 * w / n : 0.0, net, PFText(gp, gl)));
   DrawPanel(lines, 400);
  }

void OnTick()
  {
   if(!IsNewBar()) return;

   int hT, hP, eT, eP, xT = 0, xP = 0;
   double hL, eL, xL;
   if(!StTF(InpTrendTF, InpTrendAtr, InpTrendMult, hT, hP, hL)) return;
   if(!StTF(_Period, InpEntryAtr, InpEntryMult, eT, eP, eL)) return;
   if(InpUseExitTF && !StTF(InpExitTF, InpExitAtr, InpExitMult, xT, xP, xL)) return;
   g_entryLine  = eL;
   g_entryTrend = eT;

   // higher-timeframe trend change: close everything, reset the counter
   if(g_trendSide == 0)
     {
      g_trendSide = hT;              // trend data was not ready at start
      g_slotCount = CountPos(hT);
     }
   else if(hT != g_trendSide)
     {
      if(CountPos(0) > 0) ClosePositions(0, "trend flip");
      g_trendSide = hT;
      g_slotCount = 0;
     }

   // exit-timeframe flip against the position
   if(InpUseExitTF)
     {
      g_exitTrend = xT;
      bool xDn = xT == -1 && xP == 1, xUp = xT == 1 && xP == -1;
      if(xDn && CountPos(1) > 0)  ClosePositions(1, "exit TF flip");
      if(xUp && CountPos(-1) > 0) ClosePositions(-1, "exit TF flip");
     }

   bool eBuy  = eT == 1 && eP == -1;
   bool eSell = eT == -1 && eP == 1;
   int maxE = MathMax(1, MathMin(5, InpMaxEntries));

   if(eBuy && g_trendSide == 1 && InpDir != PYR_SHORT && g_slotCount < maxE)
     {
      g_slotCount++;
      if(SlotOn(g_slotCount)) OpenSlot(1, g_slotCount);
     }
   if(eSell && g_trendSide == -1 && InpDir != PYR_LONG && g_slotCount < maxE)
     {
      g_slotCount++;
      if(SlotOn(g_slotCount)) OpenSlot(-1, g_slotCount);
     }

   TrailOnLine();
   UpdatePanel();
  }
