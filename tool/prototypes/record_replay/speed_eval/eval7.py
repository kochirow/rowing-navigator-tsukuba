import sys
exec(open('eval5.py').read().split("def both(")[0])
def g2(P,C,voters,boat='8+',info=None,cap=True,slew=True,final=True,rel=1.6,floor=0.02):
    n=len(P);Sm={k:center(P,C[k]) for k in voters}
    score={}
    for k in voters:
        dev=[]
        for i in range(n):
            x=Sm[k][i];o=[Sm[j][i] for j in voters if j!=k and Sm[j][i] is not None]
            if x is None or not o: continue
            m=med(o)
            if m<MIN_WORK: continue
            dev.append(abs(x-m)/m)
        score[k]=(med(dev),len(dev)) if len(dev)>=60 else (9,len(dev))
    best=min(s for s,_ in score.values())
    use=[k for k in voters if score[k][0]<=max(best*rel,floor)]
    if info is not None: info.update({k:f"{score[k][0]*100:.1f}%{'採用' if k in use else '除外'}" for k in voters})
    wb={'8+':2000/317.75,'4x':2000/332.03}[boat]
    raw=[0]*n;prev=None
    for i in range(n):
        c=[Sm[k][i] for k in use if Sm[k][i] is not None]
        v=med(c) if c else (prev if prev is not None else P[i]['vf'])
        if cap: v=min(v,wb*1.02)
        raw[i]=v;prev=v
    lim=raw
    if slew:
        A=0.3;fw=raw[:];bw=raw[:]
        for i in range(1,n):
            d=A*max(.5,P[i]['t']-P[i-1]['t']);fw[i]=max(fw[i-1]-d,min(fw[i-1]+d,fw[i]))
        for i in range(n-2,-1,-1):
            d=A*max(.5,P[i+1]['t']-P[i]['t']);bw[i]=max(bw[i+1]-d,min(bw[i+1]+d,bw[i]))
        lim=[(a+b)/2 for a,b in zip(fw,bw)]
    return center(P,lim) if final else lim
def both(name,**kw):
    iD={};iE={}
    evaluate(name,g2(D,CD,info=iD,**kw),g2(E,CE,info=iE,**kw));print('     ずれ D:',iD,' E:',iE)
print('== 8+ 2台の一致（小さいほど良い）')
evaluate('V3 いまの試作',fuse(D,CD,['pos','dop','rate']),fuse(E,CE,['pos','dop','rate']))
both('G2 位置+直接',voters=['pos','dop'])
both('G2 全候補(位置+直接+補正後+IMU)',voters=['pos','dop','filt','imu'])
both('G2 ＋良いアプリ値(合成)',voters=['pos','dop','filt','imu','good'])
both('G2 ＋時々外れる値(合成)',voters=['pos','dop','filt','imu','bad'])
both('G2 全候補 上限・制限なし',voters=['pos','dop','filt','imu'],cap=False,slew=False)
LOG4={'0806 4x':('2026_08_06','1785964599956'),'0805 4x':('2026_08_05','1785878568319')}
base=(sys.argv[1] if len(sys.argv)>1 else '../../../../../実機テストログデータ')+'/'
for nm,(d,sid) in LOG4.items():
    LOG=base+d+'/';P=load(sid);C=cand(P)
    def bad(v):
        c=n=jump=0
        for i in range(1,len(P)):
            if v[i] is None or v[i]<MIN_WORK or not P[i]['sr'] or P[i]['sr']>24: continue
            n+=1;c+=500/v[i]<110
            if v[i-1] and v[i-1]>=MIN_WORK and abs(500/v[i]-500/v[i-1])>8: jump+=1
        return f"SR24以下{n}点: 1:50より速い{c:3d}点 / 2秒で8秒以上跳ぶ{jump:4d}点"
    print('==',nm);print('  旧表示                ',bad(old_display(P)))
    print('  V3 いまの試作          ',bad(fuse(P,C,['pos','dop','rate'],boat='4x')))
    for lab,kw in [('G2 全候補',{}),('G2 全候補 上限・制限なし',dict(cap=False,slew=False))]:
        info={};print(f"  {lab:20s}",bad(g2(P,C,['pos','dop','filt','imu'],boat='4x',info=info,**kw)),info)
