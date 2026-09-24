import sys
exec(open('eval7.py').read().split("def both(name,**kw):\n    iD={}")[0])
def both(name,**kw):
    evaluate(name,g2(D,CD,**kw),g2(E,CE,**kw))
print('== 8+ 2台の一致')
evaluate('V3 いまの試作',fuse(D,CD,['pos','dop','rate']),fuse(E,CE,['pos','dop','rate']))
both('G2 全候補',voters=['pos','dop','filt','imu'])
both('G2 全候補+SR×DPS',voters=['pos','dop','filt','imu','rate'])
base=(sys.argv[1] if len(sys.argv)>1 else '../../../../../実機テストログデータ')+'/'
for nm,(d,sid) in {'0806 4x':('2026_08_06','1785964599956'),'0805 4x':('2026_08_05','1785878568319')}.items():
    LOG=base+d+'/';P=load(sid);C=cand(P)
    def m(v):
        c=n=jump=0;steps=[]
        for i in range(1,len(P)):
            if v[i] is None or v[i]<2.78 or not P[i]['sr'] or v[i-1] is None or v[i-1]<2.78: continue
            n+=1;c+=(P[i]['sr']<=24 and 500/v[i]<110);d_=abs(500/v[i]-500/v[i-1]);steps.append(d_);jump+=d_>6
        steps.sort()
        return f"漕行中{n}点: SR24以下で1:50より速い{c:3d} / 2秒で6秒以上跳ぶ{jump:4d} / 隣接差 中央{st.median(steps):.2f} p95{steps[int(len(steps)*.95)]:.2f}"
    print('==',nm);print('  旧表示         ',m(old_display(P)))
    print('  V3 いまの試作   ',m(fuse(P,C,['pos','dop','rate'],boat='4x')))
    for lab,vs in [('G2 全候補',['pos','dop','filt','imu']),('G2 全候補+SR×DPS',['pos','dop','filt','imu','rate'])]:
        info={};print(f"  {lab:14s}",m(g2(P,C,vs,boat='4x',info=info)),info)
