import random, itertools
src=open('eval3.py').read().split("def run(")[0]
exec(src)
def evaluate(name,vd,ve):
    diffs=[];miss=0
    for t in mask:
        a=interp(D,vd,t);b=interp(E,ve,t)
        if a is None or b is None or a<=0.5 or b<=0.5: miss+=1;continue
        diffs.append(abs(500/a-500/b))
    diffs.sort();q=lambda p:diffs[min(len(diffs)-1,int(len(diffs)*p))]
    print(f"{name:40s} 中央{st.median(diffs):5.2f} p90{q(.9):6.2f} p99{q(.99):6.2f} 最大{diffs[-1]:6.1f}")
def rvar(d):
    m=med(d);return (1.4826*med([abs(x-m) for x in d]))**2
def hat(P,C,keys):
    # 三角測量（three-cornered hat）: 候補どうしの差のばらつきから、各候補自身のばらつきを解く
    n=len(P);ks=[k for k in keys if sum(1 for x in C[k] if x is not None)>=30]
    V={}
    for a,b in itertools.combinations(ks,2):
        d=[C[a][i]-C[b][i] for i in range(n) if C[a][i] is not None and C[b][i] is not None and max(C[a][i],C[b][i])>=MIN_WORK]
        if len(d)>=30: V[(a,b)]=rvar(d)
    # 最小二乗: V_ab = s_a + s_b
    m=len(ks);AtA=[[0.0]*m for _ in range(m)];Aty=[0.0]*m
    for (a,b),v in V.items():
        ia,ib=ks.index(a),ks.index(b)
        for x in (ia,ib):
            Aty[x]+=v
            for y2 in (ia,ib): AtA[x][y2]+=1
    M=[row[:]+[Aty[i]] for i,row in enumerate(AtA)]
    for c in range(m):
        p=max(range(c,m),key=lambda r:abs(M[r][c]));M[c],M[p]=M[p],M[c]
        if abs(M[c][c])<1e-12: continue
        for r in range(m):
            if r!=c:
                fct=M[r][c]/M[c][c];M[r]=[M[r][j]-fct*M[c][j] for j in range(m+1)]
    s=[M[i][m]/M[i][i] if abs(M[i][i])>1e-12 else 0.03**2 for i in range(m)]
    return {k:max(float(s[i]),0.03**2) for i,k in enumerate(ks)}
def adaptive2(P,C,voters,cap=True,slew=True,boat='8+',info=None):
    n=len(P);S2=hat(P,C,voters)
    if info is not None: info.update({k:round(math.sqrt(v),3) for k,v in S2.items()})
    wb={'8+':2000/317.75,'4x':2000/332.03}[boat];dmax={'8+':15,'4x':14}[boat]
    raw=[0]*n;prev=None
    for i in range(n):
        c=[(C[k][i],S2[k]) for k in S2 if C[k][i] is not None]
        if not c: v=prev if prev is not None else P[i]['vf']
        else:
            # 重み付き中央値で基準を作り、そこから各候補のσの3倍以上外れたものを捨てて重み付き平均
            cs=sorted(c);tw=sum(1/s for _,s in cs);acc=0;wm=cs[-1][0]
            for x,s in cs:
                acc+=1/s
                if acc>=tw/2: wm=x;break
            keep=[(x,s) for x,s in c if abs(x-wm)<=max(3*math.sqrt(s),0.2)] or [(wm,1)]
            v=sum(x/s for x,s in keep)/sum(1/s for _,s in keep)
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
iD={};iE={}
evaluate('E 位置+直接（固定）',fuse(D,CD,['pos','dop']),fuse(E,CE,['pos','dop']))
evaluate('V3 位置+直接+SR×DPS（固定・いまの試作）',fuse(D,CD,['pos','dop','rate']),fuse(E,CE,['pos','dop','rate']))
evaluate('A 位置+直接+補正後（固定・中央値）',fuse(D,CD,['pos','dop','filt']),fuse(E,CE,['pos','dop','filt']))
evaluate('H 適応 位置+直接+補正後+IMU',adaptive2(D,CD,['pos','dop','filt','imu'],info=iD),adaptive2(E,CE,['pos','dop','filt','imu'],info=iE))
print('   推定した各候補のばらつき σ[m/s]  D:',iD,' E:',iE)
iD={};iE={}
evaluate('H 適応 ＋良いアプリ値(合成 σ0.04)',adaptive2(D,CD,['pos','dop','filt','imu','good'],info=iD),adaptive2(E,CE,['pos','dop','filt','imu','good'],info=iE))
print('   σ D:',iD,' E:',iE)
iD={};iE={}
evaluate('H 適応 ＋時々大きく外れる値(合成)',adaptive2(D,CD,['pos','dop','filt','imu','bad'],info=iD),adaptive2(E,CE,['pos','dop','filt','imu','bad'],info=iE))
print('   σ D:',iD,' E:',iE)
evaluate('参考 良いアプリ値だけ',center(D,CD['good']),center(E,CE['good']))
