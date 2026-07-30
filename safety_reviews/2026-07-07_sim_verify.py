"""
collision_risk_evaluator_service.dart(改善版)のPython忠実移植による検証。
Flutter SDKが使えない環境での代替検証として、
test/services/collision_risk_evaluator_test.dart の全シナリオを再現する。
"""
import math

# ---------------- config ----------------
EVAL_INTERVAL = 2
WARNING_TIME = 10.0
PROX_CAUTION = 15.0
STALE_TIMEOUT = 30
ASSUMED_GPS = 5.0
GPS_WEIGHT = 0.5
AGING_RATE = 0.5
MAX_UNCERT = 8.0
MAX_STEPS = 500

CONFIGS = {
    '1x': dict(body=(8.2, 6, 4), excl=(11.2, 9, 5.8), k=3.45),
    '2x': dict(body=(10.4, 6, 5), excl=(13.4, 9, 5.6), k=3.10),
    '4x': dict(body=(13.4, 6, 8.5), excl=(16.4, 9, 9.6), k=3.18),
    '8p': dict(body=(19.9, 7.5, 16), excl=(22.9, 10.5, 18.88), k=4.65),
}
R = 6378137.0

def compute_offset(lat, lng, dist, heading):
    ang = dist / R
    b = math.radians(heading)
    la, lo = math.radians(lat), math.radians(lng)
    la2 = math.asin(math.sin(la)*math.cos(ang) + math.cos(la)*math.sin(ang)*math.cos(b))
    lo2 = lo + math.atan2(math.sin(b)*math.sin(ang)*math.cos(la), math.cos(ang)-math.sin(la)*math.sin(la2))
    return math.degrees(la2), math.degrees(lo2)

def domain_points(lat, lng, heading, h, w, s):
    hh, hw, hs = h/2, w/2, s/2
    diag = math.hypot(hs, hw)
    a = math.degrees(math.atan2(hs, hw))
    offs = [(hh, heading), (diag, heading+90-a), (diag, heading+90+a),
            (hh, heading+180), (diag, heading-90-a), (diag, heading-90+a)]
    return [compute_offset(lat, lng, d, ang) for d, ang in offs]

# ---- triangulation (ear clipping, faithful port incl. exceptions) ----
def _ccw(poly):
    ssum = 0
    for i in range(len(poly)):
        c, n = poly[i], poly[(i+1) % len(poly)]
        ssum += (n[0]-c[0]) * (n[1]+c[1])
    return list(reversed(poly)) if ssum > 0 else poly

def _in_tri(p, a, b, c):
    v0 = (c[0]-a[0], c[1]-a[1]); v1 = (b[0]-a[0], b[1]-a[1]); v2 = (p[0]-a[0], p[1]-a[1])
    d00 = v0[0]*v0[0]+v0[1]*v0[1]; d01 = v0[0]*v1[0]+v0[1]*v1[1]; d02 = v0[0]*v2[0]+v0[1]*v2[1]
    d11 = v1[0]*v1[0]+v1[1]*v1[1]; d12 = v1[0]*v2[0]+v1[1]*v2[1]
    den = d00*d11 - d01*d01
    if den == 0: return False
    inv = 1/den
    u = (d11*d02 - d01*d12)*inv; v = (d00*d12 - d01*d02)*inv
    return u >= 0 and v >= 0 and u+v < 1

def _is_ear(poly, i):
    prev, nxt = (i-1) % len(poly), (i+1) % len(poly)
    a, b, c = poly[prev], poly[i], poly[nxt]
    cross = (b[0]-a[0])*(c[1]-b[1]) - (b[1]-a[1])*(c[0]-b[0])
    if cross <= 0: return False
    for j in range(len(poly)):
        if j in (prev, i, nxt): continue
        if _in_tri(poly[j], a, b, c): return False
    return True

def triangulate(poly):
    if len(poly) < 3: raise Exception("Polygon must have at least 3 vertices.")
    poly = _ccw(list(poly))
    tris, rem = [], list(poly)
    while len(rem) > 3:
        found = False
        for i in range(len(rem)):
            if _is_ear(rem, i):
                tris.append([rem[(i-1) % len(rem)], rem[i], rem[(i+1) % len(rem)]])
                rem.pop(i); found = True; break
        if not found: raise Exception("No ear found.")
    tris.append(rem[:3])
    return tris

def _project(poly, ax):
    vals = [p[0]*ax[0]+p[1]*ax[1] for p in poly]
    return min(vals), max(vals)

def _sat(p1, p2):
    for poly in (p1, p2):
        for i in range(len(poly)):
            e = (poly[(i+1) % len(poly)][0]-poly[i][0], poly[(i+1) % len(poly)][1]-poly[i][1])
            ax = (-e[1], e[0])
            a1, b1 = _project(p1, ax); a2, b2 = _project(p2, ax)
            if b1 < a2 or b2 < a1: return False
    return True

def polygons_overlap(pts1, pts2):
    t1 = triangulate(pts1); t2 = triangulate(pts2)
    return any(_sat(a, b) for a in t1 for b in t2)

# ---- distances ----
def min_dist_to_poly(lat, lng, poly):
    if not poly: return math.inf
    lat0 = math.radians(lat)
    def xy(p): return (math.radians(p[1]-lng)*math.cos(lat0)*R, math.radians(p[0]-lat)*R)
    if len(poly) == 1:
        x, y = xy(poly[0]); return math.hypot(x, y)
    if len(poly) >= 3 and _point_in_poly(lat, lng, poly): return 0.0
    edges = 1 if len(poly) == 2 else len(poly)
    best = math.inf
    for i in range(edges):
        ax, ay = xy(poly[i]); bx, by = xy(poly[(i+1) % len(poly)])
        dx, dy = bx-ax, by-ay
        L = dx*dx+dy*dy
        t = 0 if L == 0 else max(0.0, min(1.0, (-ax*dx - ay*dy)/L))
        best = min(best, math.hypot(ax+t*dx, ay+t*dy))
    return best

def _point_in_poly(lat, lng, poly):
    wn = 0
    for i in range(len(poly)):
        s, e = poly[i], poly[(i+1) % len(poly)]
        left = (e[1]-s[1])*(lat-s[0]) - (lng-s[1])*(e[0]-s[0])
        if s[0] <= lat:
            if e[0] > lat and left > 0: wn += 1
        elif e[0] <= lat and left < 0: wn -= 1
    return wn != 0

def dist_m(a, b):
    lat0 = math.radians((a[0]+b[0])/2)
    dx = math.radians(b[1]-a[1])*math.cos(lat0)
    dy = math.radians(b[0]-a[0])
    return R*math.hypot(dx, dy)

# ---- boat / evaluator ----
class Boat:
    def __init__(self, bid, btype, lat, lng, heading, speed, age=0.0, accuracy=None):
        self.bid, self.btype = bid, btype
        self.lat, self.lng, self.heading, self.speed = lat, lng, heading, speed
        self.age, self.accuracy = age, accuracy
    def copy_pos(self, lat, lng):
        return Boat(self.bid, self.btype, lat, lng, self.heading, self.speed, self.age, self.accuracy)

def usable(b):
    if not (math.isfinite(b.lat) and math.isfinite(b.lng) and abs(b.lat) <= 90 and abs(b.lng) <= 180):
        return None
    h = b.heading if math.isfinite(b.heading) else 0.0
    s = b.speed if (math.isfinite(b.speed) and b.speed > 0) else 0.0
    if h == b.heading and s == b.speed: return b
    return Boat(b.bid, b.btype, b.lat, b.lng, h, s, b.age, b.accuracy)

def uncert(b):
    gps = b.accuracy if (b.accuracy and math.isfinite(b.accuracy) and b.accuracy > 0) else ASSUMED_GPS
    age = min(max(b.age, 0), STALE_TIMEOUT)
    return min(gps*GPS_WEIGHT + age*AGING_RATE, MAX_UNCERT)

def pair_uncert(a, b):
    ma, mb = uncert(a), uncert(b)
    return math.hypot(ma, mb)

def stopping(b):
    s = b.speed if (math.isfinite(b.speed) and b.speed > 0) else 0.0
    return (3.5 + CONFIGS[b.btype]['k']) * s

def domains(b, inflate=0.0):
    cfg = CONFIGS[b.btype]
    def infl(p): return (p[0]+2*inflate, p[1]+2*inflate, p[2]+2*inflate) if inflate > 0 else p
    body = infl(cfg['body']); excl = infl(cfg['excl'])
    return (domain_points(b.lat, b.lng, b.heading, *body),
            domain_points(b.lat, b.lng, b.heading, *excl))

def bounding_radius(p): return 0.5*math.hypot(p[0], p[1])

def predict(b, t):
    s = b.speed if math.isfinite(b.speed) else 0.0
    d = s*t
    if not math.isfinite(d): d = 0.0
    la, lo = compute_offset(b.lat, b.lng, d, b.heading)
    return b.copy_pos(la, lo)

def find_threat(my_raw, others, obstacles):
    my = usable(my_raw)
    if my is None: return None
    my_margin = uncert(my)
    my_body, my_excl = domains(my)
    _, my_excl_infl = domains(my, my_margin)
    my_excl_r = bounding_radius(CONFIGS[my.btype]['excl'])
    uncertain = None
    for ob in obstacles:  # ob: list of (lat,lng)
        if not ob: continue
        geometry_ok = False
        if len(ob) >= 3:
            try:
                if polygons_overlap(my_excl, ob): return ('obstacle', 'definite')
                if polygons_overlap(my_excl_infl, ob):
                    uncertain = uncertain or ('obstacle', 'uncertain')
                geometry_ok = True
            except Exception:
                pass
        if not geometry_ok:
            d = min_dist_to_poly(my.lat, my.lng, ob)
            if d <= my_excl_r + my_margin:
                uncertain = uncertain or ('obstacle', 'uncertain')
    for o_raw in others:
        o = usable(o_raw)
        if o is None: continue
        pm = pair_uncert(my, o)
        try:
            o_body, o_excl = domains(o)
            if polygons_overlap(my_excl, o_body) or polygons_overlap(o_excl, my_body):
                return ('boat', 'definite')
            o_body_i, o_excl_i = domains(o, pm)
            if polygons_overlap(my_excl, o_body_i) or polygons_overlap(o_excl_i, my_body):
                uncertain = uncertain or ('boat', 'uncertain')
        except Exception:
            d = dist_m((my.lat, my.lng), (o.lat, o.lng))
            r = my_excl_r + bounding_radius(CONFIGS[o.btype]['body']) + pm
            if d <= r:
                uncertain = uncertain or ('boat', 'uncertain')
    return uncertain

def proximity(my_raw, obstacles):
    my = usable(my_raw)
    if my is None: return 0
    m = uncert(my)
    for ob in obstacles:
        if not ob: continue
        if min_dist_to_poly(my.lat, my.lng, ob) <= PROX_CAUTION + m:
            return 1
    return 0

def assess(my_raw, others_raw, obstacles):
    my = usable(my_raw)
    if my is None: return 0
    others = [b for b in (usable(o) for o in others_raw) if b is not None]
    level = 0
    # my loop
    speed = my.speed
    stop_d = stopping(my)
    warn_d = stop_d + speed*WARNING_TIME
    max_other = max([b.speed for b in others], default=0.0)
    rel = speed + max_other
    dt = EVAL_INTERVAL/rel if (speed > 0 and rel > 0) else -1.0
    t, steps = 0.0, 0
    while steps < MAX_STEPS:
        steps += 1
        dist = speed*t
        if dist > warn_d: break
        fm = predict(my, t)
        fo = [predict(b, t) for b in others]
        th = find_threat(fm, fo, obstacles)
        if th:
            definite = th[1] == 'definite'
            if dist <= stop_d: level = max(level, 3 if definite else 2)
            else: level = max(level, 2 if definite else 1)
        if level == 3: break
        if dt <= 0: break
        t += dt
    # other loop
    for o in others:
        if level == 3: break
        os_, ostop = o.speed, stopping(o)
        owarn = ostop + os_*WARNING_TIME
        rel2 = os_ + my.speed
        dt2 = EVAL_INTERVAL/rel2 if (os_ > 0 and rel2 > 0) else -1.0
        t, steps = 0.0, 0
        while steps < MAX_STEPS:
            steps += 1
            dist = os_*t
            if dist > owarn: break
            fm = predict(my, t); fo = predict(o, t)
            th = find_threat(fm, [fo], [])
            if th:
                definite = th[1] == 'definite'
                if dist <= ostop: level = max(level, 2 if definite else 1)
                else: level = max(level, 1)
            if dt2 <= 0: break
            t += dt2
    level = max(level, proximity(my, obstacles))
    return level

# ---------------- scenarios ----------------
LAT, LNG = 36.0670, 140.2045
def mk(bid='t', btype='1x', lat=LAT, lng=LNG, heading=0.0, speed=0.0, accuracy=None, age=0.0):
    return Boat(bid, btype, lat, lng, heading, speed, age, accuracy)

def sq_obstacle(center, half):
    c = center
    return [compute_offset(*compute_offset(*c, half, 0), half, 90),
            compute_offset(*compute_offset(*c, half, 0), half, 270),
            compute_offset(*compute_offset(*c, half, 180), half, 270),
            compute_offset(*compute_offset(*c, half, 180), half, 90)]

results = []
def check(name, actual, expected_desc, ok):
    results.append((name, actual, expected_desc, ok))

# 既存テスト
check('停止距離: 速度比例', stopping(mk(speed=4.0)), '> v1', stopping(mk(speed=4.0)) > stopping(mk(speed=1.0)))
check('停止距離: 停止=0', stopping(mk(speed=0.0)), '0', stopping(mk(speed=0.0)) == 0.0)
check('停止距離: NaN→0', stopping(mk(speed=float("nan"))), '0', stopping(mk(speed=float("nan"))) == 0.0)
lv = assess(mk(speed=3.0), [], []); check('何もなければlv0', lv, '0', lv == 0)
oc = compute_offset(LAT, LNG, 30, 0.0)
lv = assess(mk(speed=3.0), [], [sq_obstacle(oc, 10)]); check('前方危険区域→lv3', lv, '3', lv == 3)
oc = compute_offset(LAT, LNG, 20, 90.0)
lv = assess(mk(speed=0.0), [], [sq_obstacle(oc, 10)]); check('停止中10m危険区域→lv1+', lv, '>=1', lv >= 1)
oc = compute_offset(LAT, LNG, 110, 90.0)
lv = assess(mk(speed=0.0), [], [sq_obstacle(oc, 10)]); check('100m離れ→lv0', lv, '0', lv == 0)
op = compute_offset(LAT, LNG, 40, 0.0)
lv = assess(mk(speed=3.0), [mk('o', lat=op[0], lng=op[1], heading=180.0, speed=3.0)], [])
check('正面接近→lv1+', lv, '>=1', lv >= 1)

# 新規: 不正ポリゴン
p1 = compute_offset(LAT, LNG, 10, 90.0)
deg = [p1, compute_offset(*p1, 20, 0.0)]
lv = assess(mk(speed=0.0), [], [deg]); check('頂点2点区域10m→lv1+', lv, '>=1', lv >= 1)
c = compute_offset(LAT, LNG, 8, 0.0)
bowtie = [compute_offset(*compute_offset(*c, 5, 0), 5, 270),
          compute_offset(*compute_offset(*c, 5, 0), 5, 90),
          compute_offset(*compute_offset(*c, 5, 180), 5, 270),
          compute_offset(*compute_offset(*c, 5, 180), 5, 90)]
lv = assess(mk(speed=3.0), [], [bowtie]); check('自己交差区域8m前方→lv1+', lv, '>=1', lv >= 1)

# 新規: NaN
fp = compute_offset(LAT, LNG, 300, 90.0)
lv = assess(mk(speed=3.0), [mk('b', lat=fp[0], lng=fp[1], speed=float('nan'), heading=float('nan'))], [])
check('speed=NaN他艇(遠方)→lv0・完了', lv, '0', lv == 0)
lv = assess(mk(speed=3.0), [mk('b', lat=float('nan'), lng=float('nan'), speed=3.0)], [])
check('lat=NaN他艇→lv0・完了', lv, '0', lv == 0)

# 新規: GPS誤差
op = compute_offset(LAT, LNG, 12, 90.0)
lv = assess(mk(speed=3.0, accuracy=10.0), [mk('o', lat=op[0], lng=op[1], heading=0.0, speed=3.0, accuracy=10.0)], [])
check('並走12m・誤差10m→lv1+', lv, '>=1', lv >= 1)
op = compute_offset(LAT, LNG, 8, 90.0)
lv = assess(mk(speed=3.0), [mk('o', lat=op[0], lng=op[1], heading=0.0, speed=3.0)], [])
check('並走8m・誤差なし→lv2(lv3にしない)', lv, '2', lv == 2)
op = compute_offset(LAT, LNG, 12, 90.0)
lv = assess(mk(speed=3.0), [mk('o', lat=op[0], lng=op[1], heading=0.0, speed=3.0)], [])
check('並走12m・誤差なし→lv0', lv, '0', lv == 0)

# 新規: すり抜け
cross = compute_offset(LAT, LNG, 1.0, 0.0)
ostart = compute_offset(*cross, 5.5*3.335, 90.0)
lv = assess(mk(speed=0.3), [mk('8', btype='8p', lat=ostart[0], lng=ostart[1], heading=270.0, speed=5.5)], [])
check('1x0.3m/s×8+5.5m/s交差→lv3', lv, '3', lv == 3)

# 旧アルゴリズム比較(すり抜け): 自艇速度基準の刻み+マージンなし
def assess_old_myloop(my, other):
    speed = my.speed
    stop_d = stopping(my); warn_d = stop_d + speed*WARNING_TIME
    dt = EVAL_INTERVAL/speed if speed != 0 else -1
    t = 0.0; found_lv = 0
    while True:
        dist = speed*t
        if dist > warn_d: break
        fm = predict(my, t); fo = predict(other, t)
        mb, me = domains(fm); ob, oe = domains(fo)
        hit = polygons_overlap(me, ob) or polygons_overlap(oe, mb)
        if hit:
            found_lv = max(found_lv, 3 if dist <= stop_d else 2)
        if speed == 0.0: break
        t += dt
    return found_lv
old_lv = assess_old_myloop(mk(speed=0.3), mk('8', btype='8p', lat=ostart[0], lng=ostart[1], heading=270.0, speed=5.5))
check('[旧コード比較] 同交差シナリオの自艇ループ', old_lv, '旧=0または2(lv3を逃す)', old_lv < 3)

# データ経過時間マージン(停止艇の漂流吸収)
op = compute_offset(LAT, LNG, 13, 90.0)
lv_fresh = assess(mk(speed=3.0), [mk('o', lat=op[0], lng=op[1], heading=0.0, speed=0.4, age=0.0)], [])
lv_aged = assess(mk(speed=3.0), [mk('o', lat=op[0], lng=op[1], heading=0.0, speed=0.4, age=10.0)], [])
check('13m先の停止艇: 受信直後', lv_fresh, '0(マージン内に届かない)', lv_fresh == 0)
check('13m先の停止艇: 受信後10秒(漂流マージン+5m)', lv_aged, '>=1', lv_aged >= 1)

print(f"{'PASS' if all(r[3] for r in results) else 'FAIL'}  {sum(r[3] for r in results)}/{len(results)}")
for name, actual, exp, ok in results:
    print(f"  {'✅' if ok else '❌'} {name}: actual={actual} expected={exp}")
