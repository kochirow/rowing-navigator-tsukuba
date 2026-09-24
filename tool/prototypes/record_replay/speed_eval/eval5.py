exec(open('eval4.py').read().split("iD={};iE={}")[0])
def agree_fuse(P,C,voters,tol=0.05,need=0.6,cap=True,slew=True,boat='8+',info=None,tiebreak=True):
    n=len(P)
    Sm={k:center(P,C[k]) for k in voters}            # 1) 全候補を同じ10秒平均にそろえる
    if tiebreak and 'rate' in C: Sm['rate']=center(P,C['rate'])
    # 2) 一致率: ほかの投票者の中央値から tol 以内に入った割合（漕いでいる間だけ）
    ok={}
    for k in voters:
        hit=tot=0
        for i in range(n):
            x=Sm[k][i];o=[Sm[j][i] for j in voters if j!=k and Sm[j][i] is not None]
            if x is None or len(o)<1: continue
            m=med(o)
            if m<MIN_WORK: continue
            tot+=1;hit+=abs(x-m)/m<=tol
        ok[k]=(hit/tot if tot else 0,tot)
    use=[k for k in voters if ok[k][1]>=60 and ok[k][0]>=need]
    if len(use)<2: use=sorted(voters,key=lambda k:-ok[k][0])[:2]
    if info is not None: info.update({k:f"{ok[k][0]*100:.0f}%" + ('採用' if k in use else '除外') for k in voters})
    wb={'8+':2000/317.75,'4x':2000/332.03}[boat];dmax={'8+':15,'4x':14}[boat]
    raw=[0]*n;prev=None
    for i in range(n):
        c=[Sm[k][i] for k in use if Sm[k][i] is not None]
        if len(c)>=3: v=med(c)
        elif len(c)==2:
            x,y=c
            if abs(x-y)/max(x,y,.5)<0.08: v=(x+y)/2
            else:
                r=Sm.get('rate',[None]*n)[i] if tiebreak else None
                ref=r if r is not None else prev
                v=min((x,y),key=lambda z:abs(z-ref)) if ref is not None else (x+y)/2
        elif len(c)==1: v=c[0]
        else: v=prev if prev is not None else P[i]['vf']
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
    return lim
def both(name,**kw):
    iD={};iE={}
    vd=agree_fuse(D,CD,info=iD,**kw);ve=agree_fuse(E,CE,info=iE,**kw)
    evaluate(name,vd,ve);print('     一致率 D:',iD,' E:',iE)
evaluate('E 位置+直接（固定）',fuse(D,CD,['pos','dop']),fuse(E,CE,['pos','dop']))
evaluate('V3 いまの試作',fuse(D,CD,['pos','dop','rate']),fuse(E,CE,['pos','dop','rate']))
both('G 一致率 位置+直接',voters=['pos','dop'])
both('G 一致率 位置+直接+補正後+IMU',voters=['pos','dop','filt','imu'])
both('G 一致率 ＋良いアプリ値(合成)',voters=['pos','dop','filt','imu','good'])
both('G 一致率 ＋時々外れる値(合成)',voters=['pos','dop','filt','imu','bad'])
both('G 一致率 位置+直接 SR補助なし',voters=['pos','dop'],tiebreak=False)
both('G 一致率 位置+直接 上限・変化制限なし',voters=['pos','dop'],cap=False,slew=False)
