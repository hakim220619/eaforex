"""sim v2: + break-even, biaya spread, filter kandidat (untuk diagnosa WR rendah)."""
import csv, sys, collections, statistics
sys.path.insert(0, '/private/tmp/claude-501/-Users-danilukmanhakim-Documents-Dani-python-forexbot/ebf08cb1-a40a-4a50-9edf-07a816782e71/scratchpad')
from sim_smc import load

def ema(vals, per):
    out=[]; k=2/(per+1); e=None
    for v in vals:
        e = v if e is None else v*k+e*(1-k); out.append(e)
    return out
def atr(H,L,C,per=14):
    out=[]; a=None
    for i in range(len(C)):
        tr = H[i]-L[i] if i==0 else max(H[i]-L[i], abs(H[i]-C[i-1]), abs(L[i]-C[i-1]))
        a = tr if a is None else (a*(per-1)+tr)/per; out.append(a)
    return out

def run(path, point, P, spread_pts=0, label=""):
    T,O,H,L,C = load(path)
    N=len(T); n=P['SwingBars']; LB=P['Lookback']
    SH=[False]*N; SL=[False]*N
    for t in range(n, N-n):
        sh=sl=True
        for k in range(1,n+1):
            if not (H[t] >= H[t-k] and H[t] > H[t+k]): sh=False
            if not (L[t] <= L[t-k] and L[t] <  L[t+k]): sl=False
            if not(sh or sl): break
        SH[t]=sh; SL[t]=sl
    EMA = ema(C, P.get('EmaPeriod',200)) if P.get('TrendFilter') else None
    ATR = atr(H,L,C)
    def detect(t, d):
        g_n = LB if t+1 >= LB else t+1
        if g_n < 4*n+20: return None
        ext=lambda i: L[t-i] if d>0 else H[t-i]
        opp=lambda i: H[t-i] if d>0 else L[t-i]
        cl =lambda i: C[t-i]; op=lambda i: O[t-i]
        def is_ext(i): return (n+1<=i<g_n-n) and (SL[t-i] if d>0 else SH[t-i])
        def is_opp(i): return (n+1<=i<g_n-n) and (SH[t-i] if d>0 else SL[t-i])
        def nearest(pred,k):
            for i in range(k+1,g_n):
                if pred(i): return i
            return -1
        pt=point
        j=p=-1; k=2
        while k<=P['SweepMaxBars']+1 and k<g_n-n-1:
            pp=nearest(is_ext,k)
            if pp<0: break
            lvl=ext(pp); pen=d*(lvl-ext(k))
            if pen<=0 or pen<P['SweepMinPts']*pt: k+=1; continue
            if P['SweepMustClose'] and d*(cl(k)-lvl)<=0: k+=1; continue
            j=k;p=pp;break
        if j<0: return None
        q=nearest(is_opp,j)
        if q<0: return None
        mss=opp(q)
        if d*(cl(1)-mss)<=0: return None
        for kk in range(2,q):
            if d*(cl(kk)-mss)>0: return None
        m=1
        for kk in range(1,j+1):
            if d*(ext(m)-ext(kk))>0: m=kk
        # --- filter kandidat ---
        a = ATR[t-1]
        if P.get('TrendFilter') and d*(C[t-1]-EMA[t-1])<0: return None            # searah EMA
        if P.get('MinLegAtr') and d*(mss-ext(m)) < P['MinLegAtr']*a: return None   # leg sweep->MSS terlalu kecil (struktur mikro)
        if P.get('DisplAtr') and (H[t-1]-L[t-1]) < P['DisplAtr']*a: return None    # candle MSS tanpa displacement
        if P.get('Hours'):
            hr=int(T[t][11:13])
            if not any(lo<=hr<hi for lo,hi in P['Hours']): return None
        s=dict(dir=d,j=j,q=q,m=m,sweepExt=ext(m),mss=mss,hasOB=False,obValid=False,hasFVG=False,hasIFVG=False)
        kk=m
        while kk<=j+n and kk<g_n:
            if d*(op(kk)-cl(kk))>0:
                s['hasOB']=True; s['obNear']=opp(kk); s['obFar']=ext(kk)
                if kk==m: s['obValid']=True
                else:
                    for tt in range(1,kk):
                        if d*(s['obFar']-ext(tt))>0: s['obValid']=True;break
                break
            kk+=1
        for kk in range(2,m+1):
            nearE = L[t-(kk-1)] if d>0 else H[t-(kk-1)]
            farE  = H[t-(kk+1)] if d>0 else L[t-(kk+1)]
            size=d*(nearE-farE)
            if size<=0 or size<P['MinFvgPts']*pt: continue
            s['hasFVG']=True; s['fvgNear']=nearE; s['fvgFar']=farE
            if P['FvgPick']=='NEAREST': break
        for kk in range(m+1,q):
            nearE = L[t-(kk+1)] if d>0 else H[t-(kk+1)]
            farE  = H[t-(kk-1)] if d>0 else L[t-(kk-1)]
            size=d*(nearE-farE)
            if size<=0 or size<P['MinFvgPts']*pt: continue
            if d*(cl(1)-nearE)<=0: continue
            if not s['hasIFVG'] or d*(nearE-s['ifvgNear'])>0:
                s['hasIFVG']=True; s['ifvgNear']=nearE; s['ifvgFar']=farE
        obOk = s['hasOB'] and (s['obValid'] or not P['ObRequireSweep'])
        zm=P['ZoneMode']
        if zm=='FVG': poi='FVG' if s['hasFVG'] else None
        elif zm=='OB': poi='OB' if obOk else None
        else: poi = 'FVG' if s['hasFVG'] else ('IFVG' if s['hasIFVG'] else ('OB' if obOk else None))
        if poi is None: return None
        near,far = {'FVG':('fvgNear','fvgFar'),'OB':('obNear','obFar'),'IFVG':('ifvgNear','ifvgFar')}[poi]
        zn,zf=s[near],s[far]
        entry=zn-(zn-zf)*P['ZoneEntryPct']/100.0
        slBase=s['sweepExt']
        if P['SlMode']=='OB' and s['hasOB']: slBase=s['obFar']
        if d*(zf-slBase)<0: slBase=s['sweepExt']
        sl=slBase-d*P['SLBufferPts']*pt
        if P.get('SlAtrBuf'): sl = slBase - d*P['SlAtrBuf']*a          # buffer berbasis ATR
        risk=d*(entry-sl)
        if risk<=0: return None
        if P.get('MinRiskAtr') and risk < P['MinRiskAtr']*a: return None
        tp=None
        if P['TpMode']=='LIQ':
            for i in range(n+1,g_n-n):
                if not is_opp(i): continue
                lvl=opp(i)
                if d*(lvl-cl(1))<=0: continue
                tpc=lvl-d*P['TpBufferPts']*pt
                rr=d*(tpc-entry)/risk
                if rr<P['MinRR']: continue
                if rr>P['MaxRR']: tpc=entry+d*P['MaxRR']*risk
                tp=tpc; break
        if tp is None: tp=entry+d*P['RR']*risk
        return dict(dir=d,entry=entry,sl=sl,tp=tp,risk=risk,rr=d*(tp-entry)/risk,poi=poi,zoneFar=zf)
    pend=None; pos=None; trades=[]; risks=[]
    be_rr=P.get('BeRR',0); be_off=P.get('BeOffPts',5)*point; spr=spread_pts*point
    for t in range(1,N):
        if pos:
            d=pos['dir']; hit=None
            # break-even (cek dulu pakai high/low bar; konservatif: SL/BE dulu)
            if be_rr and not pos.get('be'):
                fav = (H[t]-pos['entry']) if d>0 else (pos['entry']-L[t])
                if fav >= be_rr*pos['risk']:
                    pos['sl']=pos['entry']+d*be_off; pos['be']=True
            if (d>0 and L[t]<=pos['sl']) or (d<0 and H[t]>=pos['sl']): hit='BE' if pos.get('be') else 'SL'
            elif (d>0 and H[t]>=pos['tp']) or (d<0 and L[t]<=pos['tp']): hit='TP'
            if hit:
                pnl = (d*(pos['sl']-pos['entry']) if hit!='TP' else d*(pos['tp']-pos['entry'])) - spr
                trades.append((hit, pnl/pos['risk'], pnl)); pos=None
        if pend:
            d=pend['dir']; pend['left']-=1
            if pend['left']<=0 or d*(C[t-1]-pend['sl'])<0 or d*(C[t-1]-pend['tp'])>0: pend=None
            else:
                if (L[t]<=pend['entry']) if d>0 else (H[t]>=pend['entry']):
                    pos=pend; pend=None
                    if (d>0 and L[t]<=pos['sl']) or (d<0 and H[t]>=pos['sl']):
                        trades.append(('SL', -1.0-spr/pos['risk'], -pos['risk']-spr)); pos=None
                    continue
        if pos: continue
        s=detect(t,+1) or detect(t,-1)
        if s:
            px=O[t]; d=s['dir']; risks.append(s['risk'])
            if d*(px-s['entry'])>0:
                pend=dict(s, left=P['EntryValidBars'])
            elif d*(px-s['zoneFar'])>=0:
                risk=d*(px-s['sl'])
                if risk>0: pos=dict(s, entry=px, risk=risk)
    nT=len(trades); w=sum(1 for x in trades if x[0]=='TP'); be=sum(1 for x in trades if x[0]=='BE'); l=nT-w-be
    R=sum(x[1] for x in trades); usd=sum(x[2] for x in trades)
    mr = statistics.median(risks) if risks else 0
    print(f"{label:52s} trades={nT:4d} TP={w:3d} BE={be:3d} SL={l:3d} WR={w/max(nT,1)*100:4.0f}%  R={R:+6.1f}  P/L@0.01lot=${usd:+7.1f}  median SL=${mr:.1f}")
    return trades

if __name__=='__main__':
    D="/private/tmp/claude-501/-Users-danilukmanhakim-Documents-Dani-python-forexbot/ebf08cb1-a40a-4a50-9edf-07a816782e71/scratchpad/data/"
    DEF=dict(SwingBars=3,Lookback=300,SweepMaxBars=30,SweepMinPts=0,SweepMustClose=False,ZoneMode='AUTO',FvgPick='DEEPEST',
             MinFvgPts=10,ObRequireSweep=True,ZoneEntryPct=50,EntryValidBars=15,SlMode='SWEEP',SLBufferPts=20,TpMode='LIQ',RR=2.0,MinRR=1.5,MaxRR=5.0,TpBufferPts=10)
    for f,pt,spr in (("XAUUSD_5m.csv",0.01,25),("XAUUSD_15m.csv",0.01,25)):
        print(f"\n##### {f}  (spread {spr} pts = ${spr*pt:.2f})")
        run(D+f,pt,DEF,0,"A. default EA v1.01, TANPA BE, tanpa spread")
        run(D+f,pt,dict(DEF,BeRR=1.0),spr,"B. default EA v1.01 + BE 1R + spread  (= tester kamu)")
        run(D+f,pt,dict(DEF,BeRR=0),spr,"C. B tapi BE off")
        run(D+f,pt,dict(DEF,BeRR=0,SweepMustClose=True),spr,"D. C + sweep wajib close balik")
        run(D+f,pt,dict(DEF,BeRR=0,SwingBars=5),spr,"E. C + SwingBars 5 (struktur lebih major)")
        run(D+f,pt,dict(DEF,BeRR=0,TrendFilter=True,EmaPeriod=200),spr,"F. C + filter tren EMA200 searah")
        run(D+f,pt,dict(DEF,BeRR=0,Hours=[(7,20)]),spr,"G. C + sesi London/NY (07-20 UTC)")
        run(D+f,pt,dict(DEF,BeRR=0,DisplAtr=1.2),spr,"H. C + candle MSS displacement >=1.2 ATR")
        run(D+f,pt,dict(DEF,BeRR=0,MinLegAtr=2.0),spr,"I. C + leg sweep->MSS >= 2 ATR")
        run(D+f,pt,dict(DEF,BeRR=0,MinRiskAtr=1.0,SlAtrBuf=0.3),spr,"J. C + SL min 1 ATR, buffer 0.3 ATR")
        run(D+f,pt,dict(DEF,BeRR=0,ZoneEntryPct=0),spr,"K. C + entry di tepi zona (fill lebih banyak)")
        run(D+f,pt,dict(DEF,BeRR=0,TpMode='RR',RR=2.0),spr,"L. C + TP RR tetap 1:2")
        run(D+f,pt,dict(DEF,BeRR=0,SweepMustClose=True,TrendFilter=True,Hours=[(7,20)],MinLegAtr=2.0,MinRiskAtr=1.0,SlAtrBuf=0.3),spr,"M. C + D+F+G+I+J digabung")
        run(D+f,pt,dict(DEF,BeRR=0,TrendFilter=True,MinLegAtr=2.0,MinRiskAtr=1.0,SlAtrBuf=0.3),spr,"N. C + F+I+J (tanpa sesi & must-close)")
