import random
exec(open('eval2.py').read().split("M={")[0].replace("print(","(lambda *a,**k:None)("))
def adaptive(P,C,voters,tiebreak='rate',cap=True,slew=True,boat='8+',info=None):
    n=len(P)
    c0=fuse(P,C,['pos','dop','rate'],cap=False,slew=False)  # 暫定の合意（GNSS由来2つ＋SR×DPSの中央値）
    sig={}
    for k in voters:
        r=[C[k][i]-c0[i] for i in range(n) if C[k][i] is not None and c0[i] is not None and c0[i]>=MIN_WORK]
        if len(r)<30: continue
        m=med(r); s=1.4826*med([abs(x-m) for x in r]); sig[k]=(max(s,0.03),m)
    if info is not None: info.update({k:(round(v[0],3),round(v[1],3)) for k,v in sig.items()})
    wb={'8+':2000/317.75,'4x':2000/332.03}[boat];dmax={'8+':15,'4x':14}[boat]
    raw=[0]*n
    for i in range(n):
        num=den=0
        for k,(s,b) in sig.items():
            x=C[k][i]
            if x is None or c0[i] is None: continue
            if abs(x-c0[i])>max(3*s,0.25): continue   # 外れ値は捨てる
            w=1/s**2; num+=w*x; den+=w
        v=num/den if den else (c0[i] if c0[i] is not None else P[i]['vf'])
        if cap:
            cp=wb*1.02
            if P[i]['sr'] and P[i]['sr']>=12: cp=min(cp,P[i]['sr']*dmax/60)
            v=min(v,cp)
        raw[i]=v
    lim=raw
    if slew:
        A=0.3;fw=raw[:];bw=raw[:]
        for i in range(1,n):
            d=A*max(.5,P[i]['t']-P[i-1]['t']);fw[i]=max(fw[i-1]-d,min(fw[i-1]+d,fw[i]))
        for i in range(n-2,-1,-1):
            d=A*max(.5,P[i+1]['t']-P[i]['t']);bw[i]=max(bw[i+1]-d,min(bw[i+1]+d,bw[i]))
        lim=[(a+b)/2 for a,b in zip(fw,bw)]
    return center(P,lim)
# 合成の「良いアプリ値」: 相手端末と独立なノイズを持つ、真値に近い値の代わり
# 真値の代理 = 2台の E 方式の平均（どちらの端末の誤差も半分になる）
refD=fuse(D,CD,['pos','dop']);refE=fuse(E,CE,['pos','dop'])
def truth_at(t):
    a=interp(D,refD,t);b=interp(E,refE,t)
    return (a+b)/2 if a is not None and b is not None else None
random.seed(1)
for P,C in ((D,CD),(E,CE)):
    C['good']=[ (lambda tr: tr+random.gauss(0,0.04) if tr is not None else None)(truth_at(p['t'])) for p in P]
    C['bad']=[ (x+ (random.choice([0,0,0,0,1.2,-1.0]) ) ) if x is not None else None for x in C['pos']]
def run(name,fn):
    evaluate(name,fn(D,CD),fn(E,CE))
iD={};iE={}
run('E 位置+直接（固定）',lambda P,C:fuse(P,C,['pos','dop']))
run('V3 位置+直接+SR×DPS（固定）',lambda P,C:fuse(P,C,['pos','dop','rate']))
run('A 位置+直接+補正後（固定・中央値）',lambda P,C:fuse(P,C,['pos','dop','filt']))
run('W 適応 位置+直接',lambda P,C:adaptive(P,C,['pos','dop']))
run('W 適応 位置+直接+補正後+IMU',lambda P,C:adaptive(P,C,['pos','dop','filt','imu'],info=iD if P is D else iE))
print('  各候補のばらつきσ[m/s]と偏り: D',iD,' E',iE)
run('W 適応 ＋良いアプリ値(合成)',lambda P,C:adaptive(P,C,['pos','dop','filt','imu','good']))
run('W 適応 ＋時々大きく外れる値(合成)',lambda P,C:adaptive(P,C,['pos','dop','filt','imu','bad']))
run('参考: 良いアプリ値だけ',lambda P,C:center(P,C['good']))
