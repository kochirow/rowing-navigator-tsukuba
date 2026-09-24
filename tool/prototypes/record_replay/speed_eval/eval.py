import csv, math, statistics as st
from datetime import datetime
import os,sys
LOG=os.path.join(sys.argv[1] if len(sys.argv)>1 else os.path.join(os.path.dirname(os.path.abspath(__file__)),'..','..','..','..','実機テストログデータ'),'2026_08_06')+'/'
MIN_WORK=500/240; MOVE=0.5
def f(v):
    try: return float(v)
    except: return None
def hav(a,b,c,d):
    R=6371000;dl=math.radians(c-a);dg=math.radians(d-b);x=math.sin(dl/2)**2+math.cos(math.radians(a))*math.cos(math.radians(c))*math.sin(dg/2)**2;return 2*R*math.asin(math.sqrt(x))
def load(sid):
    rows=list(csv.DictReader(open(LOG+f'rowing_diagnostics_{sid}/track.csv')))
    P=[]
    for r in rows:
        t=datetime.fromisoformat(r['timestamp'].replace('Z','+00:00')).timestamp()
        P.append(dict(t=t,flat=f(r['filtered_lat']),flng=f(r['filtered_lng']),rlat=f(r['raw_lat']) or f(r['filtered_lat']),rlng=f(r['raw_lng']) or f(r['filtered_lng']),
          vf=f(r['speed_mps']) or 0,vd=f(r['raw_gnss_speed_mps']),va=f(r['speed_accuracy_mps']),sr=f(r['spm']),dps=f(r['distance_per_stroke_m'])))
    # SR forward fill (<=6s)
    last=None
    for p in P:
        if p['sr']: last=p;continue
        if last and p['t']-last['t']<=6: p['sr']=last['sr']
    return P
def med(a):
    a=sorted(a);n=len(a)
    return None if not n else (a[n//2] if n%2 else (a[n//2-1]+a[n//2])/2)
def smooth_pos(P):
    n=len(P)
    for i in range(n):
        ks=[k for k in range(max(0,i-1),min(n,i+2)) if abs(P[k]['t']-P[i]['t'])<=3.5]
        P[i]['lat']=sum(P[k]['rlat'] for k in ks)/len(ks); P[i]['lng']=sum(P[k]['rlng'] for k in ks)/len(ks)
def cand(P):
    n=len(P); smooth_pos(P)
    vPos=[None]*n; a=0;b=0
    for i in range(n):
        while a<i and P[i]['t']-P[a+1]['t']>=5: a+=1
        while b+1<n and P[b+1]['t']-P[i]['t']<=5: b+=1
        dt=P[b]['t']-P[a]['t']
        if 6<=dt<=14: vPos[i]=hav(P[a]['lat'],P[a]['lng'],P[b]['lat'],P[b]['lng'])/dt
    vDop=[p['vd'] if p['vd'] is not None and p['vd']>=0 and (p['va'] is None or p['va']<=1.5) else None for p in P]
    vFilt=[p['vf'] for p in P]
    vImu=[p['dps']*p['sr']/60 if p['dps'] and p['sr'] else None for p in P]
    obs=[(P[i]['t'],(vPos[i]+vDop[i])/2*60/P[i]['sr']) for i in range(n) if P[i]['sr'] and vPos[i] and vDop[i] and vPos[i]>MIN_WORK and abs(vPos[i]-vDop[i])/max(vPos[i],vDop[i])<0.1]
    vRate=[None]*n;j0=j1=0
    for i in range(n):
        t=P[i]['t']
        while j0<len(obs) and obs[j0][0]<t-60: j0+=1
        while j1<len(obs) and obs[j1][0]<=t+60: j1+=1
        if P[i]['sr'] and j1-j0>=3: vRate[i]=P[i]['sr']*med([o[1] for o in obs[j0:j1]])/60
    return dict(pos=vPos,dop=vDop,filt=vFilt,imu=vImu,rate=vRate)
def fuse(P,C,keys,cap=True,slew=True,boat='8+',robust='median'):
    n=len(P);wb={'8+':2000/317.75,'4x':2000/332.03}[boat];dmax={'8+':15,'4x':14}[boat]
    raw=[0]*n;prev=None
    for i in range(n):
        c=[C[k][i] for k in keys if C[k][i] is not None and math.isfinite(C[k][i])]
        if not c: v=P[i]['vf']
        elif len(c)==1: v=c[0]
        elif len(c)==2:
            x,y=c; v=(x+y)/2 if abs(x-y)/max(x,y,.5)<0.12 else (min((x,y),key=lambda z:abs(z-prev)) if prev is not None else min(x,y))
        else:
            if robust=='median': v=med(c)
            else: # MAD rejection then mean
                m=med(c);mad=med([abs(z-m) for z in c]) or 0.05
                keep=[z for z in c if abs(z-m)<=max(3*1.4826*mad,0.15)] or [m]; v=sum(keep)/len(keep)
        if cap:
            cp=wb*1.02
            if P[i]['sr'] and P[i]['sr']>=12: cp=min(cp,P[i]['sr']*dmax/60)
            v=min(v,cp)
        raw[i]=v;prev=v
    lim=raw
    if slew:
        A=0.3;fw=raw[:];bw=raw[:]
        for i in range(1,n):
            d=A*max(.5,P[i]['t']-P[i-1]['t']);fw[i]=max(fw[i-1]-d,min(fw[i-1]+d,fw[i]))
        for i in range(n-2,-1,-1):
            d=A*max(.5,P[i+1]['t']-P[i]['t']);bw[i]=max(bw[i+1]-d,min(bw[i+1]+d,bw[i]))
        lim=[(a+b)/2 for a,b in zip(fw,bw)]
    return center(P,lim)
def center(P,v,h=5):
    n=len(P);out=[None]*n
    for i in range(n):
        s=[v[k] for k in range(n) if False]
    # efficient window
    a=b=0
    for i in range(n):
        while P[i]['t']-P[a]['t']>h: a+=1
        while b+1<n and P[b+1]['t']-P[i]['t']<=h: b+=1
        vals=[v[k] for k in range(a,b+1) if v[k] is not None]
        out[i]=sum(vals)/len(vals) if vals else None
    return out
def old_display(P):
    n=len(P);cd=[0]*n
    for i in range(1,n): cd[i]=cd[i-1]+(hav(P[i-1]['flat'],P[i-1]['flng'],P[i]['flat'],P[i]['flng']) if P[i]['vf']>=MOVE else 0)
    out=[None]*n;w=0
    for i in range(1,n):
        while w+1<i and P[i]['t']-P[w]['t']>15: w+=1
        d=cd[i]-cd[w];tm=sum(min(P[k]['t']-P[k-1]['t'],10) for k in range(w+1,i+1) if P[k]['vf']>=MOVE)
        out[i]=d/tm if d>=10 and tm>0 else None
    return out
def interp(P,v,t):
    lo,hi=0,len(P)-1
    if t<P[0]['t'] or t>P[-1]['t']: return None
    while lo<hi:
        m=(lo+hi+1)//2
        if P[m]['t']<=t: lo=m
        else: hi=m-1
    if lo>=len(P)-1: return v[lo]
    a,b=v[lo],v[lo+1]
    if a is None or b is None or P[lo+1]['t']-P[lo]['t']>4: return None
    r=(t-P[lo]['t'])/(P[lo+1]['t']-P[lo]['t']);return a+(b-a)*r
D=load('1785967606648');E=load('1785967619060')
CD=cand(D);CE=cand(E)
# SR agreement
srd=[]
t0=max(D[0]['t'],E[0]['t'])+60;t1=min(D[-1]['t'],E[-1]['t'])
grid=[t0+k*2 for k in range(int((t1-t0)/2))]
def srat(P,t):
    best=min(P,key=lambda p:abs(p['t']-t)); return best['sr'] if abs(best['t']-t)<1.5 else None
methods={
 'M0 旧表示(補正後位置15秒)':lambda P,C:old_display(P),
 'M1 アプリ補正後の艇速のみ':lambda P,C:center(P,C['filt']),
 'M2 GPS直接速度のみ':lambda P,C:center(P,C['dop']),
 'M3 生GPS位置のみ':lambda P,C:center(P,C['pos']),
 'M4 IMU由来(DPS×SR)のみ':lambda P,C:center(P,C['imu']),
 'V3現行 位置+直接+SR×DPS':lambda P,C:fuse(P,C,['pos','dop','rate']),
 'A 位置+直接+補正後':lambda P,C:fuse(P,C,['pos','dop','filt']),
 'B 位置+直接+補正後+SR×DPS':lambda P,C:fuse(P,C,['pos','dop','filt','rate']),
 'C 位置+直接+補正後+IMU':lambda P,C:fuse(P,C,['pos','dop','filt','imu']),
 'D 全部5つ':lambda P,C:fuse(P,C,['pos','dop','filt','imu','rate']),
 'E 位置+直接 (2つ)':lambda P,C:fuse(P,C,['pos','dop']),
 'V3現行 上限なし':lambda P,C:fuse(P,C,['pos','dop','rate'],cap=False),
 'V3現行 変化制限なし':lambda P,C:fuse(P,C,['pos','dop','rate'],slew=False),
 'A 上限・制限なし':lambda P,C:fuse(P,C,['pos','dop','filt'],cap=False,slew=False),
}
# working mask: both sessions moving at work speed by consensus (median of both devices' dop/pos)
res=[]
for name,fn in methods.items():
    vd=fn(D,CD);ve=fn(E,CE)
    diffs=[];vals=[]
    for t in grid:
        a=interp(D,vd,t);b=interp(E,ve,t)
        if a is None or b is None: continue
        if min(a,b)<MIN_WORK: continue
        pa,pb=500/a,500/b; diffs.append(abs(pa-pb)); vals.append((pa+pb)/2)
    diffs.sort()
    fast=sum(1 for t in grid if (lambda a: a is not None and a>=MIN_WORK and 500/a<100)(interp(D,vd,t)))
    res.append((name,len(diffs),st.median(diffs),diffs[int(len(diffs)*.9)],diffs[int(len(diffs)*.99)],max(diffs)))
print(f"{'方式':32s} {'点数':>5s} {'中央値':>6s} {'p90':>6s} {'p99':>6s} {'最大':>6s}  (2台のスプリット差 秒/500m)")
for r in res: print(f"{r[0]:32s} {r[1]:5d} {r[2]:6.2f} {r[3]:6.2f} {r[4]:6.2f} {r[5]:6.1f}")
# SR agreement
sd=[]
for t in grid:
    a=srat(D,t);b=srat(E,t)
    if a and b: sd.append(abs(a-b))
sd.sort();print('SR 2台差: n',len(sd),'median',st.median(sd),'p90',sd[int(len(sd)*.9)],'p99',sd[int(len(sd)*.99)])
