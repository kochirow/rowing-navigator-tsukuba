exec(open('eval.py').read().split("D=load('1785967606648')")[0])
D=load('1785967606648');E=load('1785967619060')
CD=cand(D);CE=cand(E)
# source availability & doppler accuracy
for nm,P,C in (('D',D,CD),('E',E,CE)):
    n=len(P); va=[p['va'] for p in P if p['va'] is not None]; vd=sum(1 for p in P if p['vd'] is not None and p['vd']>=0)
    print(nm,'点',n,'直接速度あり',vd,'精度<=1.5',sum(1 for x in va if x<=1.5),'精度中央',round(med(va),2) if va else None,'SRあり',sum(1 for p in P if p['sr']),'IMUあり',sum(1 for p in P if p['dps']))
t0=max(D[0]['t'],E[0]['t'])+60;t1=min(D[-1]['t'],E[-1]['t'])
grid=[t0+k*2 for k in range(int((t1-t0)/2))]
ref_d=fuse(D,CD,['pos','dop'],cap=False,slew=False);ref_e=fuse(E,CE,['pos','dop'],cap=False,slew=False)
mask=[t for t in grid if (lambda a,b: a is not None and b is not None and min(a,b)>=MIN_WORK+0.3)(interp(D,ref_d,t),interp(E,ref_e,t))]
print('共通の評価時刻(両端末とも漕いでいる):',len(mask))
def evaluate(name,vd,ve):
    diffs=[];miss=0
    for t in mask:
        a=interp(D,vd,t);b=interp(E,ve,t)
        if a is None or b is None or a<=0.5 or b<=0.5: miss+=1;continue
        diffs.append(abs(500/a-500/b))
    diffs.sort()
    q=lambda p:diffs[min(len(diffs)-1,int(len(diffs)*p))]
    print(f"{name:34s} 欠け{miss:4d} 中央{st.median(diffs):5.2f} p90{q(.9):6.2f} p99{q(.99):6.2f} 最大{diffs[-1]:6.1f}")
M={
 'M0 旧表示(アプリ補正後位置)':lambda P,C:old_display(P),
 'M1 アプリ補正後の艇速':lambda P,C:center(P,C['filt']),
 'M2 GPS直接速度':lambda P,C:center(P,[x if x is not None else None for x in C['dop']]),
 'M3 生GPS位置':lambda P,C:center(P,C['pos']),
 'M4 IMU(DPS×SR)':lambda P,C:center(P,C['imu']),
 'M5 SR×DPS基準':lambda P,C:center(P,C['rate']),
 'E 位置+直接':lambda P,C:fuse(P,C,['pos','dop']),
 'V3 位置+直接+SR×DPS':lambda P,C:fuse(P,C,['pos','dop','rate']),
 'A 位置+直接+補正後':lambda P,C:fuse(P,C,['pos','dop','filt']),
 'B 位置+直接+補正後+SR×DPS':lambda P,C:fuse(P,C,['pos','dop','filt','rate']),
 'D 5つ全部(中央値)':lambda P,C:fuse(P,C,['pos','dop','filt','imu','rate']),
 'D 5つ全部(外れ値除去→平均)':lambda P,C:fuse(P,C,['pos','dop','filt','imu','rate'],robust='mad'),
 'A 3つ(外れ値除去→平均)':lambda P,C:fuse(P,C,['pos','dop','filt'],robust='mad'),
}
for k,fn in M.items(): evaluate(k,fn(D,CD),fn(E,CE))
