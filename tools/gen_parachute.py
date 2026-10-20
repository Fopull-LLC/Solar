#!/usr/bin/env python3
"""Generate the parachute rig: models/parts/parachute.glb.

One SKINNED mesh holds the whole parachute so it costs one draw: a round
canopy of 12 gores (alternating orange and white, with seam tapes, a vent
hole at the apex and a reinforcing hem at the skirt), 12 suspension lines
that run from the skirt to a confluence point, the riser from there to the
canister, a small pilot chute on a bridle above the vent, and the canister
lid. scripts/parachute.lua moves the bones every frame; the bind pose is the
FULLY OPEN canopy streaming along +Y with the riser foot at the origin.

Bones (glTF joints, in this order):
  0 Root    the riser foot, at the canister (origin)
  1 Riser   the confluence point where the lines meet
  2 Apex    the vent centre (the bridle's foot)
  3 Pilot   the pilot chute
  4 Lid     the canister lid
  5 + col*K + k   canopy bone in column col (0..2G-1: even = seam, odd =
                  gore centre) at ring k (0 = vent edge .. K-1 = skirt).
  5 + 2G*K + g    L<g>: the middle of suspension line g (from the confluence
                  to seam 2g's skirt point). In flight it sits on the straight
                  line; on the ground it lets a slack line hang off the craft
                  and lie along the terrain instead of spanning it taut.

Every canopy vertex is blended from the four bones around it (two columns x
two rings), so moving those bones re-shapes the canopy smoothly: collapsed
streamer, reefed "squid", full canopy, draped on the ground.

The engine RECENTERS a rigged model on its rest bounds (gltf_rig.rs: center
is subtracted as a placement offset). A degenerate triangle mirrors the top of
the rig below the origin so the bounds centre IS the origin, and the node sits
exactly at the riser foot.

Writes spec-compliant glTF 2.0 by hand (no dependencies) and prints the rest
profile the Lua side needs.  Run from the Floptle repo root:
    python3 solar/tools/gen_parachute.py
"""
import json, math, os, struct

G = 12            # gores
K = 4             # bone rings along a meridian (vent edge .. skirt)
LR = 1.0          # riser length (canister -> confluence), m
LL = 7.0          # suspension line length (confluence -> skirt), m
EA, EB = 3.6, 2.3 # inflated profile: ellipse half-width (radial), half-height
VENT_R = 0.32     # vent hole radius, m
T1 = math.radians(100.0)  # skirt sits a little below the ellipse's equator
BULGE = 0.05      # extra outward bulge of a gore's middle over the circle
PILOT_UP = 1.7    # bridle length, vent centre -> pilot chute
LINE_W = 0.035    # suspension line width (two crossed ribbons)
RISER_W = 0.07

ORANGE = (0.93, 0.34, 0.07, 1.0)
WHITE = (0.93, 0.92, 0.88, 1.0)
TAPE = (0.80, 0.77, 0.70, 1.0)
LINE = (0.86, 0.85, 0.80, 1.0)
RISER = (0.22, 0.22, 0.25, 1.0)
LID = (0.95, 0.44, 0.13, 1.0)   # the canister's orange mortar cap (PartChute)

# ---- the inflated meridian profile, sampled by arc length -------------------
T0 = math.asin(VENT_R / EA)
def ell(t):
    return EA * math.sin(t), EB * math.cos(t)
N_ARC = 4000
arc = [0.0]
pts = [ell(T0)]
for i in range(1, N_ARC + 1):
    t = T0 + (T1 - T0) * i / N_ARC
    p = ell(t)
    arc.append(arc[-1] + math.hypot(p[0] - pts[-1][0], p[1] - pts[-1][1]))
    pts.append(p)
S_TOTAL = arc[-1]
def prof(u):
    """(rho, y_rel) at arc fraction u in [0,1] (0 = vent edge, 1 = skirt)."""
    s = u * S_TOTAL
    lo, hi = 0, N_ARC
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if arc[mid] < s: lo = mid
        else: hi = mid
    f = 0 if arc[hi] == arc[lo] else (s - arc[lo]) / (arc[hi] - arc[lo])
    return (pts[lo][0] + (pts[hi][0] - pts[lo][0]) * f,
            pts[lo][1] + (pts[hi][1] - pts[lo][1]) * f)
RHO_SKIRT, YREL_SKIRT = prof(1.0)
Y_SKIRT = LR + math.sqrt(LL * LL - RHO_SKIRT * RHO_SKIRT)
Y0 = Y_SKIRT - YREL_SKIRT            # ellipse centre height in model space
def surf(u, a, g):
    """Rest position of canopy point: arc fraction u, gore g, across-gore a."""
    rho, yr = prof(u)
    th = (g + a) * 2 * math.pi / G
    r = rho * (1.0 + BULGE * math.sin(math.pi * a))
    return (r * math.sin(th), Y0 + yr, r * math.cos(th))

ring_rho = [prof(k / (K - 1))[0] for k in range(K)]
ring_y = [Y0 + prof(k / (K - 1))[1] for k in range(K)]
APEX = (0.0, ring_y[0] + 0.05, 0.0)
PILOT = (0.0, APEX[1] + PILOT_UP, 0.0)

# ---- skeleton ---------------------------------------------------------------
bones = []  # (name, translation, rotation quat xyzw)
def qy(th):
    return (0.0, math.sin(th / 2), 0.0, math.cos(th / 2))
bones.append(("Root", (0.0, 0.0, 0.0), (0, 0, 0, 1)))
bones.append(("Riser", (0.0, LR, 0.0), (0, 0, 0, 1)))
bones.append(("Apex", APEX, (0, 0, 0, 1)))
bones.append(("Pilot", PILOT, (0, 0, 0, 1)))
bones.append(("Lid", (0.0, 0.0, 0.0), (0, 0, 0, 1)))
def bone_index(col, k):
    return 5 + (col % (2 * G)) * K + k
for col in range(2 * G):
    th = col * math.pi / G
    for k in range(K):
        rho = ring_rho[k] * (1.0 + (BULGE if col % 2 else 0.0))
        bones.append(("C%d_%d" % (col, k), (rho * math.sin(th), ring_y[k], rho * math.cos(th)), qy(th)))
LINE_MID = 0.5    # where along a line its middle bone sits (confluence 0 .. skirt 1)
def line_mid(g):
    th = g * 2 * math.pi / G
    sk = (ring_rho[K - 1] * math.sin(th), ring_y[K - 1], ring_rho[K - 1] * math.cos(th))
    return tuple(LR * (1 - LINE_MID) * (i == 1) + sk[i] * LINE_MID for i in range(3))
def mid_index(g):
    return 5 + 2 * G * K + g
for g in range(G):
    bones.append(("L%d" % g, line_mid(g), (0, 0, 0, 1)))

def mat_from(t, q):
    x, y, z, w = q
    r = [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
         [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
         [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]]
    return r, t
def inv_bind(t, q):
    r, _ = mat_from(t, q)
    rt = [[r[j][i] for j in range(3)] for i in range(3)]  # transpose
    tt = [-(rt[i][0] * t[0] + rt[i][1] * t[1] + rt[i][2] * t[2]) for i in range(3)]
    # column-major 4x4
    return [rt[0][0], rt[1][0], rt[2][0], 0.0,
            rt[0][1], rt[1][1], rt[2][1], 0.0,
            rt[0][2], rt[1][2], rt[2][2], 0.0,
            tt[0], tt[1], tt[2], 1.0]

# ---- geometry ----------------------------------------------------------------
P, N, C, J, W, IDX = [], [], [], [], [], []
def vert(p, n, c, joints, weights):
    P.append(p); N.append(n); C.append(c)
    js = list(joints) + [0] * (4 - len(joints))
    ws = list(weights) + [0.0] * (4 - len(weights))
    s = sum(ws) or 1.0
    J.append(js[:4]); W.append([x / s for x in ws[:4]])
    return len(P) - 1
def norm(v):
    l = math.sqrt(v[0] ** 2 + v[1] ** 2 + v[2] ** 2) or 1.0
    return (v[0] / l, v[1] / l, v[2] / l)
def sub(a, b): return (a[0] - b[0], a[1] - b[1], a[2] - b[2])
def cross(a, b): return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
def dot(a, b): return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
def tri(a, b, c, outward=None):
    if outward is not None:
        n = cross(sub(P[b], P[a]), sub(P[c], P[a]))
        if dot(n, outward) < 0: b, c = c, b
    IDX.extend([a, b, c])

# canopy: one strip of vertices per gore (seams duplicated, so colours and
# the crease between gores stay crisp)
AS = [0.0, 0.025, 0.06, 0.2, 0.35, 0.5, 0.65, 0.8, 0.94, 0.975, 1.0]
US = [0.0, 0.02, 0.045] + [0.045 + (0.955 - 0.045) * i / 16 for i in range(1, 16)] + [0.955, 0.98, 1.0]
for g in range(G):
    body = ORANGE if g % 2 == 0 else WHITE
    grid = []
    for u in US:
        row = []
        for a in AS:
            p = surf(u, a, g)
            e = 1e-3
            du = sub(surf(min(1, u + e), a, g), surf(max(0, u - e), a, g))
            da = sub(surf(u, min(1, a + e), g), surf(u, max(0, a - e), g))
            n = norm(cross(du, da))
            out = norm((p[0], 0.6 * (p[1] - Y0) + 0.4, p[2]))
            if dot(n, out) < 0: n = (-n[0], -n[1], -n[2])
            tape = a < 0.03 or a > 0.97 or u < 0.03 or u > 0.97
            col = TAPE if tape else body
            # bilinear skin weights: columns (seam/centre) x rings
            if a <= 0.5:
                c0, c1, fa = 2 * g, 2 * g + 1, a / 0.5
            else:
                c0, c1, fa = 2 * g + 1, 2 * g + 2, (a - 0.5) / 0.5
            x = u * (K - 1)
            k0 = min(K - 2, int(x))
            fu = x - k0
            js = [bone_index(c0, k0), bone_index(c1, k0), bone_index(c0, k0 + 1), bone_index(c1, k0 + 1)]
            ws = [(1 - fa) * (1 - fu), fa * (1 - fu), (1 - fa) * fu, fa * fu]
            row.append(vert(p, n, col, js, ws))
        grid.append(row)
    for i in range(len(US) - 1):
        for j in range(len(AS) - 1):
            a, b, c, d = grid[i][j], grid[i][j + 1], grid[i + 1][j + 1], grid[i + 1][j]
            pc = P[a]
            out = norm((pc[0], 0.6 * (pc[1] - Y0) + 0.4, pc[2]))
            tri(a, b, c, out); tri(a, c, d, out)

def ribbon(p0, p1, j0, j1, width, col, side):
    """Two crossed quads from p0 (skinned to j0) to p1 (skinned to j1)."""
    axis = norm(sub(p1, p0))
    s1 = norm(side)
    s2 = norm(cross(axis, s1))
    for s in (s1, s2):
        h = (s[0] * width / 2, s[1] * width / 2, s[2] * width / 2)
        n = norm(cross(axis, s))
        q = [vert((p0[0] - h[0], p0[1] - h[1], p0[2] - h[2]), n, col, [j0], [1.0]),
             vert((p0[0] + h[0], p0[1] + h[1], p0[2] + h[2]), n, col, [j0], [1.0]),
             vert((p1[0] + h[0], p1[1] + h[1], p1[2] + h[2]), n, col, [j1], [1.0]),
             vert((p1[0] - h[0], p1[1] - h[1], p1[2] - h[2]), n, col, [j1], [1.0])]
        tri(q[0], q[1], q[2], n); tri(q[0], q[2], q[3], n)

# suspension lines: confluence (Riser) -> line middle -> each seam's skirt
# point (two straight runs, so a slack line can bend at its middle)
conf = (0.0, LR, 0.0)
for g in range(G):
    th = g * 2 * math.pi / G
    sk = (ring_rho[K - 1] * math.sin(th), ring_y[K - 1], ring_rho[K - 1] * math.cos(th))
    mid = line_mid(g)
    side = (math.cos(th), 0.0, -math.sin(th))
    ribbon(conf, mid, 1, mid_index(g), LINE_W, LINE, side)
    ribbon(mid, sk, mid_index(g), bone_index(2 * g, K - 1), LINE_W, LINE, side)
# riser: canister -> confluence
ribbon((0.0, 0.0, 0.0), conf, 0, 1, RISER_W, RISER, (1.0, 0.0, 0.0))
# bridle: vent centre -> pilot chute
ribbon(APEX, (PILOT[0], PILOT[1] - 0.3, PILOT[2]), 2, 3, 0.03, LINE, (1.0, 0.0, 0.0))

# pilot chute: a small dome on the Pilot bone, mouth facing down the bridle
PR, PH = 0.45, 0.32
NPA, NPU = 16, 5
pg = []
for i in range(NPU + 1):
    row = []
    phi = (math.pi / 2) * i / NPU          # 0 at the crown .. 90 deg at the mouth
    for j in range(NPA + 1):
        th = 2 * math.pi * j / NPA
        r = PR * math.sin(phi) + 0.02
        y = PILOT[1] + PH * math.cos(phi) - 0.3
        p = (r * math.sin(th), y, r * math.cos(th))
        n = norm((math.sin(phi) * math.sin(th) / PR, math.cos(phi) / PH, math.sin(phi) * math.cos(th) / PR))
        col = ORANGE if (j // 2) % 2 == 0 else WHITE
        row.append(vert(p, n, col, [3], [1.0]))
    pg.append(row)
for i in range(NPU):
    for j in range(NPA):
        a, b, c, d = pg[i][j], pg[i][j + 1], pg[i + 1][j + 1], pg[i + 1][j]
        out = N[a]
        tri(a, b, c, out); tri(a, c, d, out)

# canister lid: a shallow disc on the Lid bone
LRAD, LTH, NL = 0.2, 0.05, 16
top = vert((0.0, LTH, 0.0), (0, 1, 0), LID, [4], [1.0])
bot = vert((0.0, 0.0, 0.0), (0, -1, 0), LID, [4], [1.0])
rim_t, rim_b, side_t, side_b = [], [], [], []
for j in range(NL):
    th = 2 * math.pi * j / NL
    x, z = LRAD * math.sin(th), LRAD * math.cos(th)
    rim_t.append(vert((x, LTH, z), (0, 1, 0), LID, [4], [1.0]))
    rim_b.append(vert((x, 0.0, z), (0, -1, 0), LID, [4], [1.0]))
    side_t.append(vert((x, LTH, z), (math.sin(th), 0, math.cos(th)), LID, [4], [1.0]))
    side_b.append(vert((x, 0.0, z), (math.sin(th), 0, math.cos(th)), LID, [4], [1.0]))
for j in range(NL):
    k = (j + 1) % NL
    tri(top, rim_t[j], rim_t[k], (0, 1, 0))
    tri(bot, rim_b[k], rim_b[j], (0, -1, 0))
    o = N[side_t[j]]
    tri(side_t[j], side_b[j], side_b[k], o); tri(side_t[j], side_b[k], side_t[k], o)

# bounds balancer: a degenerate (zero-area, never drawn) triangle mirroring the
# rig's top below the origin, so the engine's recentring offset is zero.
ymax = max(p[1] for p in P)
xmax = max(abs(p[0]) for p in P)
zmax = max(abs(p[2]) for p in P)
d = vert((0.0, -ymax, 0.0), (0, 1, 0), LID, [0], [1.0])
IDX.extend([d, d, d])
# x/z are symmetric by construction; check
assert abs(max(p[0] for p in P) + min(p[0] for p in P)) < 1e-3
assert abs(max(p[2] for p in P) + min(p[2] for p in P)) < 0.2

# ---- write the GLB -------------------------------------------------------------
def pack(fmt, rows):
    flat = [x for r in rows for x in (r if isinstance(r, (list, tuple)) else [r])]
    return struct.pack('<%d%s' % (len(flat), fmt), *flat)
def pad4(b): return b + b'\x00' * ((4 - len(b) % 4) % 4)
blobs = [pad4(pack('f', P)), pad4(pack('f', N)), pad4(pack('f', C)),
         pad4(pack('H', J)), pad4(pack('f', W)), pad4(pack('I', IDX)),
         pad4(pack('f', [inv_bind(b[1], b[2]) for b in bones]))]
views, off = [], 0
for i, b in enumerate(blobs):
    v = {"buffer": 0, "byteOffset": off, "byteLength": len(b)}
    if i < 5: v["target"] = 34962
    elif i == 5: v["target"] = 34963
    views.append(v)
    off += len(b)
bin_blob = b''.join(blobs)
nv = len(P)
pmin = [min(p[i] for p in P) for i in range(3)]
pmax = [max(p[i] for p in P) for i in range(3)]
accessors = [
    {"bufferView": 0, "componentType": 5126, "count": nv, "type": "VEC3", "min": pmin, "max": pmax},
    {"bufferView": 1, "componentType": 5126, "count": nv, "type": "VEC3"},
    {"bufferView": 2, "componentType": 5126, "count": nv, "type": "VEC4"},
    {"bufferView": 3, "componentType": 5123, "count": nv, "type": "VEC4"},
    {"bufferView": 4, "componentType": 5126, "count": nv, "type": "VEC4"},
    {"bufferView": 5, "componentType": 5125, "count": len(IDX), "type": "SCALAR"},
    {"bufferView": 6, "componentType": 5126, "count": len(bones), "type": "MAT4"},
]
nodes = [{"name": "Canopy", "mesh": 0, "skin": 0}]
root_i = len(nodes)
nodes.append({"name": "Root", "children": []})
for (name, t, q) in bones[1:]:
    nodes[root_i]["children"].append(len(nodes))
    nodes.append({"name": name, "translation": list(t), "rotation": list(q)})
gltf = {
    "asset": {"version": "2.0", "generator": "solar gen_parachute"},
    "scene": 0, "scenes": [{"nodes": [0, root_i]}],
    "nodes": nodes,
    "skins": [{"joints": list(range(root_i, root_i + len(bones))), "inverseBindMatrices": 6,
               "skeleton": root_i}],
    "meshes": [{"name": "Parachute", "primitives": [{
        "attributes": {"POSITION": 0, "NORMAL": 1, "COLOR_0": 2, "JOINTS_0": 3, "WEIGHTS_0": 4},
        "indices": 5, "material": 0}]}],
    "materials": [{"name": "Nylon", "doubleSided": True, "pbrMetallicRoughness": {
        "baseColorFactor": [1, 1, 1, 1], "metallicFactor": 0.0, "roughnessFactor": 0.85}}],
    "buffers": [{"byteLength": len(bin_blob)}],
    "bufferViews": views, "accessors": accessors,
}
json_blob = json.dumps(gltf).encode('utf-8')
json_blob += b' ' * ((4 - len(json_blob) % 4) % 4)
here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, "..", "models", "parts", "parachute.glb")
with open(out, 'wb') as f:
    f.write(b'glTF'); f.write(struct.pack('<II', 2, 12 + 8 + len(json_blob) + 8 + len(bin_blob)))
    f.write(struct.pack('<I', len(json_blob))); f.write(b'JSON'); f.write(json_blob)
    f.write(struct.pack('<I', len(bin_blob))); f.write(b'BIN\x00'); f.write(bin_blob)
print("wrote %s: %d verts, %d tris, %d bones" % (os.path.normpath(out), nv, len(IDX) // 3, len(bones)))

# ---- the rest profile, for scripts/parachute.lua ----------------------------
def f(x): return "%.4f" % x
print("-- generated by tools/gen_parachute.py")
print("local G, K = %d, %d" % (G, K))
print("local LR, LL = %s, %s" % (f(LR), f(LL)))
print("local RHO_OPEN = { %s }" % ", ".join(f(x) for x in ring_rho))
print("local Y_OPEN = { %s }" % ", ".join(f(x) for x in ring_y))
print("local BULGE = %s" % f(BULGE))
print("local APEX_UP, PILOT_UP = %s, %s" % (f(APEX[1] - ring_y[0]), f(PILOT_UP)))
print("local LINE_MID = %s" % f(LINE_MID))
