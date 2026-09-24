import csv, json, os
from datetime import datetime
import sys
# 使い方: python3 build_data.py <実機テストログデータのフォルダ>
# 出力の data.js には航跡（位置）が入る。Git に入れない（.gitignore 済み）。
HERE=os.path.dirname(os.path.abspath(__file__))
REPO=os.path.abspath(os.path.join(HERE,'..','..','..'))
LOG=sys.argv[1] if len(sys.argv)>1 else os.path.join(REPO,'..','実機テストログデータ')
SESS=[('2026_08_06/rowing_diagnostics_1785964599956','4x'),
      ('2026_08_05/rowing_diagnostics_1785878568319','4x'),
      ('2026_08_06/rowing_diagnostics_1785967619060','8+')]
def f(v):
    try: return round(float(v),6) if v not in ('',None) else None
    except: return None
out=[]
for path,label in SESS:
    d=os.path.join(LOG,path)
    m=json.load(open(d+'/manifest.json'))['session']
    rows=list(csv.DictReader(open(d+'/track.csv')))
    t0=datetime.fromisoformat(rows[0]['timestamp'].replace('Z','+00:00'))
    pts=[]
    for r in rows:
        t=(datetime.fromisoformat(r['timestamp'].replace('Z','+00:00'))-t0).total_seconds()
        lat=f(r['filtered_lat']) or f(r['raw_lat']); lng=f(r['filtered_lng']) or f(r['raw_lng'])
        if lat is None: continue
        sp=f(r['spm']); dps=f(r['distance_per_stroke_m'])
        rl=f(r['raw_lat']) or lat; rg=f(r['raw_lng']) or lng
        vd=f(r['raw_gnss_speed_mps']); va=f(r['speed_accuracy_mps'])
        pts.append([round(t,1),round(lat,6),round(lng,6),round(f(r['speed_mps']) or 0,2),round(f(r['heading_deg']) or 0),
                    round(sp,1) if sp else None, round(dps,2) if dps else None,
                    {'safe':0,'caution':1,'warning':2,'emergency':3}.get(r['safety_level'],0),
                    r['gnss_quality'][:1] if r['gnss_quality'] else '',
                    round(rl,6),round(rg,6),round(vd,2) if vd is not None and vd>=0 else None,round(va,2) if va is not None and va>=0 else None])
    out.append({'id':m['id'],'boat':m['boatType'],'label':label,'seat':m.get('seatPosition'),
                'startedAt':rows[0]['timestamp'],'pts':pts})
h=json.load(open(REPO+'/assets/data/sakuragawa_obstacles.json'))
bridges=[]
for b in h['dangerZoneBaselines']:
    if b['kind']=='bridge':
        p=b['points']; bridges.append({'name':b['name'],'lat':sum(x['lat'] for x in p)/len(p),'lng':sum(x['lng'] for x in p)/len(p)})
cls=[{'name':c['name'],'pts':[[x['lat'],x['lng']] for x in c['points']]} for c in h['channelCenterlines']]
haz=[]
for b in h['dangerZoneBaselines']:
    haz.append({'type':'line','kind':b['kind'],'name':b['name'],'pts':[[x['lat'],x['lng']] for x in b['points']]})
for o in h['obstacles']:
    haz.append({'type':'poly' if len(o['points'])>=3 else 'point','kind':o['kind'],'name':o['name'],'pts':[[x['lat'],x['lng']] for x in o['points']]})
lanes=[{'name':n['name'],'pts':[[x['lat'],x['lng']] for x in n['points']]} for n in h['navigableWaters']]
js='window.SESSIONS='+json.dumps(out,ensure_ascii=False,separators=(',',':'))+';\nwindow.BRIDGES='+json.dumps(bridges,ensure_ascii=False)+';\nwindow.CENTERLINES='+json.dumps(cls,ensure_ascii=False)+';\nwindow.HAZARDS='+json.dumps(haz,ensure_ascii=False)+';\nwindow.LANES='+json.dumps(lanes,ensure_ascii=False)+';\n'
open(os.path.join(HERE,'data.js'),'w').write(js)
print(len(js), [len(s['pts']) for s in out])
