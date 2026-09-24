import sys
exec(open('eval5.py').read().split("def both(")[0].replace("D=load('1785967606648');E=load('1785967619060')","D=load('1785967606648');E=D").replace("CD=cand(D);CE=cand(E)","CD=cand(D);CE=CD"))
import glob
LOG4={'0806 4x':(sys.argv[1] if len(sys.argv)>1 else '../../../../../実機テストログデータ')+'/2026_08_06/rowing_diagnostics_1785964599956','0805 4x':(sys.argv[1] if len(sys.argv)>1 else '../../../../../実機テストログデータ')+'/2026_08_05/rowing_diagnostics_1785878568319'}
for nm,path in LOG4.items():
    globals()['LOG']=path.rsplit('rowing_diagnostics_',1)[0]
    P=load(path.rsplit('_',1)[1]);C=cand(P)
    def bad(v):
        c=0;n=0;jump=0
        for i in range(1,len(P)):
            if v[i] is None or v[i]<MIN_WORK or not P[i]['sr'] or P[i]['sr']>24: continue
            n+=1;c+= 500/v[i]<110
            if v[i-1] and v[i-1]>=MIN_WORK and abs(500/v[i]-500/v[i-1])>8: jump+=1
        return f"SR24以下{n}点のうち 1:50より速い {c}点 / 2秒で8秒以上跳ぶ {jump}点"
    print(nm)
    print('  旧表示           ',bad(old_display(P)))
    for lab,kw in [('G 全候補',dict(voters=['pos','dop','filt','imu'],boat='4x')),('G 全候補 上限・制限なし',dict(voters=['pos','dop','filt','imu'],boat='4x',cap=False,slew=False)),('G 全候補 SR上限なし(世界最高のみ)',dict(voters=['pos','dop','filt','imu'],boat='4x',tiebreak=False))]:
        info={};v=agree_fuse(P,C,info=info,**kw);print(f"  {lab:28s}",bad(v),info)
