"""Port 1:1 logika SMC_Structure_EA.mq5 (DetectSetup + eksekusi limit) untuk diagnosa jumlah sinyal."""
import csv, sys, collections

def load(path):
    O=[];H=[];L=[];C=[];T=[]
    with open(path) as f:
        for r in csv.DictReader(f):
            T.append(r['time']); O.append(float(r['open'])); H.append(float(r['high'])); L.append(float(r['low'])); C.append(float(r['close']))
    return T,O,H,L,C

def run(path, point, P, verbose=False):
    T,O,H,L,C = load(path)
    N=len(T); n=P['SwingBars']; LB=P['Lookback']
    # pivot global (ekuivalen dengan per-window karena hanya tergantung tetangga +-n)
    SH=[False]*N; SL=[False]*N
    for t in range(n, N-n):
        sh=sl=True
        for k in range(1,n+1):
            # series: i+k = lebih tua (chrono t-k), i-k = lebih baru (chrono t+k)
            if not (H[t] >= H[t-k] and H[t] > H[t+k]): sh=False
            if not (L[t] <= L[t-k] and L[t] <  L[t+k]): sl=False
            if not(sh or sl): break
        SH[t]=sh; SL[t]=sl
    funnel=collections.Counter(); setups=[]
    def detect(t, d):
        g_n = LB if t+1 >= LB else t+1
        if g_n < 4*n+20: return None,'nodata'
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
        # 1 sweep
        j=p=-1; k=2
        while k<=P['SweepMaxBars']+1 and k<g_n-n-1:
            pp=nearest(is_ext,k)
            if pp<0: break
            lvl=ext(pp); pen=d*(lvl-ext(k))
            if pen<=0 or pen<P['SweepMinPts']*pt: k+=1; continue
            if P['SweepMustClose'] and d*(cl(k)-lvl)<=0: k+=1; continue
            j=k;p=pp;break
        if j<0: return None,'1_no_sweep'
        q=nearest(is_opp,j)
        if q<0: return None,'2_no_q'
        mss=opp(q)
        brk=d*(cl(1)-mss)
        if brk<=0 or brk<P['MssMinBreakPts']*pt: return None,'3_no_break'
        for kk in range(2,q):
            if d*(cl(kk)-mss)>0: return None,'3_not_first_break'
        m=1
        for kk in range(1,j+1):
            if d*(ext(m)-ext(kk))>0: m=kk
        s=dict(dir=d,j=j,p=p,q=q,m=m,liq=ext(p),mss=mss,sweepExt=ext(m),hasOB=False,obValid=False,hasFVG=False,hasIFVG=False)
        kk=m
        while kk<=j+n and kk<g_n:
            if d*(op(kk)-cl(kk))>0:
                s['hasOB']=True; s['obNear']=opp(kk); s['obFar']=ext(kk); s['barOb']=kk
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
        poi=None; zm=P['ZoneMode']
        if zm=='FVG': poi='FVG' if s['hasFVG'] else None
        elif zm=='OB': poi='OB' if obOk else None
        elif zm=='IFVG': poi='IFVG' if s['hasIFVG'] else None
        else: poi = 'FVG' if s['hasFVG'] else ('IFVG' if s['hasIFVG'] else ('OB' if obOk else None))
        if poi is None:
            return s,'4_no_poi(FVG:%d IFVG:%d OB:%s)'%(s['hasFVG'],s['hasIFVG'],('valid' if s['obValid'] else 'invalid') if s['hasOB'] else '-')
        s['poi']=poi
        near,far = {'FVG':('fvgNear','fvgFar'),'OB':('obNear','obFar'),'IFVG':('ifvgNear','ifvgFar')}[poi]
        zn,zf=s[near],s[far]; s['zoneNear']=zn; s['zoneFar']=zf
        pct=P['ZoneEntryPct']/100.0
        entry=zn-(zn-zf)*pct
        slBase=s['sweepExt']
        if P['SlMode']=='OB' and s['hasOB']: slBase=s['obFar']
        if d*(zf-slBase)<0: slBase=s['sweepExt']
        sl=slBase-d*P['SLBufferPts']*pt
        risk=d*(entry-sl)
        if risk<=0: return s,'5_risk<=0'
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
        s.update(entry=entry,sl=sl,tp=tp,risk=risk,rr=d*(tp-entry)/risk,t=t)
        return s,'6_OK'
    # eksekusi
    pend=None; pos=None; trades=[]
    for t in range(1,N):
        # kelola posisi dengan bar t-1 yang baru close? -> di tester intrabar; di sini pakai bar t (bar berjalan) high/low
        if pos:
            d=pos['dir']; hit=None
            if d>0:
                if L[t]<=pos['sl']: hit='SL'
                elif H[t]>=pos['tp']: hit='TP'
            else:
                if H[t]>=pos['sl']: hit='SL'
                elif L[t]<=pos['tp']: hit='TP'
            if hit:
                r = -1.0 if hit=='SL' else pos['rr']
                trades.append((T[t],pos['poi'],'BUY' if d>0 else 'SELL',hit,round(r,2))); pos=None
        if pend:
            d=pend['dir']
            pend['left']-=1
            if pend['left']<=0 or d*(C[t-1]-pend['sl'])<0 or d*(C[t-1]-pend['tp'])>0: pend=None
            else:
                filled = (L[t]<=pend['entry']) if d>0 else (H[t]>=pend['entry'])
                if filled:
                    pos=pend; pend=None
                    # cek SL/TP di bar yang sama (konservatif: SL dulu)
                    if (d>0 and L[t]<=pos['sl']) or (d<0 and H[t]>=pos['sl']):
                        trades.append((T[t],pos['poi'],'BUY' if d>0 else 'SELL','SL(samebar)',-1.0)); pos=None
                    continue
        if pos: continue
        s,st=detect(t,+1)
        if st!='6_OK':
            s2,st2=detect(t,-1)
            if st2=='6_OK': s,st=s2,st2
            else:
                funnel[st.split('(')[0]]+=1; funnel[st2.split('(')[0]]+=1
                if st.startswith('4_') : funnel[st]+=1
                if st2.startswith('4_'): funnel[st2]+=1
        if st=='6_OK':
            funnel['6_OK']+=1; setups.append(s)
            if verbose: print(T[t], 'BUY' if s['dir']>0 else 'SELL', s['poi'], 'entry',round(s['entry'],3),'sl',round(s['sl'],3),'tp',round(s['tp'],3),'rr',round(s['rr'],2),'j',s['j'],'q',s['q'])
            # pending: harga saat ini = open bar t
            px=O[t]; d=s['dir']
            if d*(px-s['entry'])>0:
                pend=dict(dir=d,entry=s['entry'],sl=s['sl'],tp=s['tp'],rr=s['rr'],poi=s['poi'],left=P['EntryValidBars'])
            elif d*(px-s['zoneFar'])>=0:
                risk=d*(px-s['sl']); rr=d*(s['tp']-px)/risk if risk>0 else 0
                if risk>0: pos=dict(dir=d,entry=px,sl=s['sl'],tp=s['tp'],rr=rr,poi=s['poi'])
                funnel['market_entry']+=1
            else: funnel['skip_price_through_zone']+=1
    wins=[x for x in trades if x[4]>0]; loss=[x for x in trades if x[4]<=0]
    print(f"\n=== {path.split('/')[-1]}  bars={N}  point={point}  params={ {k:v for k,v in P.items() if k in ('SwingBars','SweepMaxBars','ZoneMode','ZoneEntryPct','MinFvgPts','EntryValidBars','TpMode')} }")
    print("Funnel (jumlah bar yang gagal di tahap tsb; tiap bar dicek BUY & SELL):")
    for k in sorted(funnel): print(f"   {k:45s} {funnel[k]}")
    print(f"Setup OK: {len(setups)}  -> trade terisi: {len(trades)}  win {len(wins)} loss {len(loss)}  total R = {sum(x[4] for x in trades):.1f}")
    return setups,trades

if __name__=='__main__':
    D="/private/tmp/claude-501/-Users-danilukmanhakim-Documents-Dani-python-forexbot/ebf08cb1-a40a-4a50-9edf-07a816782e71/scratchpad/data/"
    DEF=dict(SwingBars=3,Lookback=300,SweepMaxBars=30,SweepMinPts=0,SweepMustClose=False,MssMinBreakPts=0,ZoneMode='AUTO',FvgPick='DEEPEST',
             MinFvgPts=10,ObRequireSweep=True,ZoneEntryPct=50,EntryValidBars=15,SlMode='SWEEP',SLBufferPts=20,TpMode='LIQ',RR=2.0,MinRR=1.5,MaxRR=5.0,TpBufferPts=10)
    run(D+"XAUUSD_5m.csv",0.01,DEF,verbose=True)
    run(D+"XAUUSD_15m.csv",0.01,DEF)
    run(D+"EURUSD_5m.csv",0.00001,DEF)
