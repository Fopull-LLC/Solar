"""Model the lab scientists' clothes in Blender (headless) — the geometry half
of tools/gen_labwear.py, which runs this and writes the glb.

    blender --background --factory-startup --python tools/gen_labwear_blender.py -- RIG.glb OUT.npz

The same rig, authoring pose, cages, lofts, weights and export as the EVA
suit (tools/gen_suit_blender.py is loaded here, all but its last line), with
the clothes of a research lab in place of the suit:

  * a white cotton-twill LAB COAT to the knee, snap-fronted, with a BAND
    COLLAR standing round the neck (a high-necked splash coat, as clean labs
    wear): the crew's own head brings its neck down inside the collar, and the
    collar's inside clears every head's neck by about a centimetre at rest
    (tools/gen_labwear.py --neck measures it), so there is no join to see —
    the neck goes into the collar as a neck does. Its top edge is weighted a
    third onto the Head bone, so it follows a turn of the head the way cloth
    round a neck is pulled;
  * set-in SLEEVES: each sleeve's head is a dome centred on the shoulder
    pivot (the suit's trick, without the bearing), so the armhole holds its
    shape however the arm turns; ribbed knit CUFFS;
  * blue NITRILE GLOVES: the suit's hand cage, slimmed to a bare hand under a
    thin glove (fingers 19 mm, not a pressurised glove's 30);
  * charcoal TROUSERS out of the coat's hem, plain dark lab SHOES;
  * a breast pocket with two pens, an ID badge on a clip, two lower pockets,
    the snap placket.

Materials: LabCloth (coat, cuffs, trousers: the weave, coloured per vertex),
LabNitrile, LabShoe, LabPlastic (pens, badge, snaps) and SuitHead (the short
neck under the collar, which scripts/face.lua tints to the wearer's skin).
"""
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_SRC = os.path.join(_HERE, "gen_suit_blender.py")
_src = open(_SRC).read()
_src = _src[:_src.rindex("\nmain()")]
exec(compile(_src, _SRC, "exec"))          # noqa: S102 — our own generator's helpers

# ── palette (multipliers on the near-white weave; linear) ────────────────────
COAT = (0.83, 0.825, 0.80)        # cotton twill, off-white, laundered a hundred times
COAT_SH = (0.74, 0.735, 0.71)
KNIT = (0.66, 0.66, 0.645)
SHIRT = (0.21, 0.235, 0.30)        # a heathered navy-grey knit
SHIRT_RIB = (0.17, 0.19, 0.25)
TROUSER = (0.085, 0.090, 0.100)
NITRILE = (0.105, 0.215, 0.60)
SHOE = (0.060, 0.058, 0.056)
SHOE_SOLE = (0.16, 0.16, 0.15)
PEN_BLUE = (0.04, 0.07, 0.22)
PEN_BLACK = (0.03, 0.03, 0.03)
CLIP = (0.62, 0.63, 0.64)
BADGE = (0.86, 0.86, 0.84)
BADGE_BAND = (0.70, 0.27, 0.07)    # the agency's signal orange stripe
PHOTO = (0.20, 0.17, 0.15)
SNAP = (0.72, 0.72, 0.70)
LAB_RB = 0.043                       # the sleeve head's dome (radius, m)


def sgnpow(v, p):
    return math.copysign(abs(v) ** p, v)


def body_ring(y, hw, hdf, hdb, zc, sq, n, dyb=0.0):
    """n points round the body: a=0 at the front (+z), π/2 on the left (+x);
    the back half's depth hdb, the front's hdf; the back raised by dyb."""
    out = []
    for i in range(n):
        a = TAU * i / n
        sa, ca = math.sin(a), math.cos(a)
        x = X0 + hw * sgnpow(sa, 2.0 / sq)
        hd = hdf if ca >= 0 else hdb
        z = zc + hd * sgnpow(ca, 2.0 / sq)
        out.append(np.array([x, y + dyb * (1 - ca) / 2, z]))
    return out


def quads(rings, closed=True):
    V = np.vstack([np.array(r) for r in rings])
    n = len(rings[0])
    F = []
    for k_ in range(len(rings) - 1):
        for i in range(n if closed else n - 1):
            j = (i + 1) % n
            F.append((k_ * n + i, k_ * n + j, (k_ + 1) * n + j, (k_ + 1) * n + i))
    return V, F


def slab_on(tree, pts_fn, nu, nv, out_off, th, normal_hint):
    """A thin closed slab laid on a surface: pts_fn(s, t) gives the point to
    cast at (from the front), the surface hit + out_off along its normal is
    the slab's outer face, th thick."""
    top, bot = [], []
    for j in range(nv + 1):
        for i in range(nu + 1):
            p = np.asarray(pts_fn(i / nu, j / nv), float)
            hit, nrm = surf_point(tree, p + np.asarray(normal_hint) * 0.5, -np.asarray(normal_hint, float), p)
            nrm = unit(nrm) if np.linalg.norm(nrm) > 1e-9 else np.asarray(normal_hint, float)
            if nrm @ np.asarray(normal_hint) < 0:
                nrm = -nrm
            top.append(hit + nrm * (out_off + th))
            bot.append(hit + nrm * out_off)
    V = np.array(top + bot)
    m = (nu + 1) * (nv + 1)
    F = []

    def idx(i, j, b=0):
        return b * m + j * (nu + 1) + i
    for j in range(nv):
        for i in range(nu):
            F.append((idx(i, j), idx(i + 1, j), idx(i + 1, j + 1), idx(i, j + 1)))
            F.append((idx(i, j, 1), idx(i, j + 1, 1), idx(i + 1, j + 1, 1), idx(i + 1, j, 1)))
    edge = [(i, 0) for i in range(nu)] + [(nu, j) for j in range(nv)] + \
           [(i, nv) for i in range(nu, 0, -1)] + [(0, j) for j in range(nv, 0, -1)]
    for q in range(len(edge)):
        a, b = edge[q], edge[(q + 1) % len(edge)]
        F.append((idx(*a), idx(*b), idx(*b, 1), idx(*a, 1)))
    return V, F


def split_by_colour(pc, col, new_name, new_mat, tol=0.06):
    """Move the faces of piece `pc` whose colour is near `col` into a piece of
    their own (another material). The boundary vertices go to both, at the
    same place with the same weights, so the seam can't open."""
    pc.apply()
    ob = pc.ob
    me = ob.data
    ca = me.color_attributes.get("col")
    if ca is None:
        return None
    cc = np.zeros(len(ca.data) * 4, np.float32)
    ca.data.foreach_get("color", cc)
    cc = cc.reshape(-1, 4)[:, :3]
    want = np.asarray(col, float)
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    bpy.context.view_layer.objects.active = ob
    ob.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_mode(type="FACE")
    bpy.ops.mesh.select_all(action="DESELECT")
    bpy.ops.object.mode_set(mode="OBJECT")
    n = 0
    for p in me.polygons:
        c = cc[list(p.vertices)].mean(0)
        if np.abs(c - want).max() < tol:
            p.select = True
            n += 1
    if n == 0:
        return None
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.separate(type="SELECTED")
    bpy.ops.object.mode_set(mode="OBJECT")
    new_ob = [o for o in bpy.context.selected_objects if o != ob][0]
    new_ob.name = new_name
    q = Piece.__new__(Piece)
    q.name, q.mat, q.part, q.tile, q.dirt = new_name, new_mat, pc.part, pc.tile, pc.dirt
    q.W, q.C, q.sharp, q.ob, q.uvmode = pc.W, pc.C, pc.sharp, new_ob, pc.uvmode
    q.wg = getattr(pc, "wg", False)
    PIECES.append(q)
    return q


# ── the sleeve and the gloved hand: the suit's arm, re-cut ──────────────────
def _lab_arm_fn():
    a0 = _src.index("def arm(rig, D, Ja, J, side, s, k, sc):")
    a1 = _src.index("# ═", a0)
    s = _src[a0:a1]
    rep = [
        ("Rb = (math.sqrt((SCYE_BORE * k) ** 2 + ring_out ** 2) + 0.003 * k) / 0.985", "Rb = LAB_RB * k"),
        ("pl = 1.0 if i % 2 == 0 else 0.90", "pl = 1.0"),
        ("bump=lambda a_, i=i: 0.02 * math.sin(4 * a_ + i * 0.9)", "bump=lambda a_, i=i: 0.003 * math.sin(4 * a_ + i * 0.9)"),
        ("""    for t, r, col in ((0.104, 0.075, CLOTH), (0.138, 0.077, CLOTH), (s_ub, 0.077, CLOTH), (0.198, 0.075, CLOTH),
                      (0.240, 0.072, CLOTH)):""",
         """    for t, r, col in ((0.068, 0.042, CLOTH), (0.115, 0.045, CLOTH), (0.165, 0.046, CLOTH), (0.212, 0.045, CLOTH),
                      (0.250, 0.044, CLOTH)):"""),
        ("""    for dd, r, col in ((-0.046, 0.069, CLOTH), (-0.024, 0.063, CLOTH_SH), (0.0, 0.067, CLOTH),
                       (0.024, 0.062, CLOTH_SH), (0.046, 0.064, CLOTH)):""",
         """    for dd, r, col in ((-0.040, 0.048, CLOTH), (-0.020, 0.0455, CLOTH_SH), (0.0, 0.0475, CLOTH),
                       (0.020, 0.045, CLOTH_SH), (0.040, 0.0455, CLOTH)):"""),
        ("""    for dd, r, col in ((0.095 * k, 0.062, CLOTH), (wr - 0.042 * k, 0.057, CLOTH), (wr - 0.014 * k, 0.053, CLOTH),
                       (wr, 0.050, CLOTH), (wr + 0.012 * k, 0.063, GLOVE), (wr + 0.036 * k, 0.066, GLOVE),
                       (wr + 0.041 * k, 0.059, GLOVE_D), (L2 - 0.010 * k, 0.051, GLOVE),
                       (L2 + 0.004 * k, 0.047, GLOVE)):""",
         """    for dd, r, col in ((0.095 * k, 0.045, CLOTH), (wr - 0.062 * k, 0.0435, CLOTH), (wr - 0.040 * k, 0.0425, CLOTH),
                       (wr - 0.036 * k, 0.0385, KNIT), (wr - 0.014 * k, 0.0355, KNIT), (wr + 0.004 * k, 0.0350, KNIT),
                       (wr + 0.008 * k, 0.0300, GLOVE), (wr + 0.030 * k, 0.0290, GLOVE),
                       (L2 - 0.010 * k, 0.0300, GLOVE), (L2 + 0.004 * k, 0.0310, GLOVE)):"""),
        ("w_, t_ = 0.044 * hk, 0.0195 * hk", "w_, t_ = 0.041 * hk, 0.0150 * hk"),
        ("hw_ * hk * 1.06", "hw_ * hk * 0.74"),
        ("hh_ * hk * 1.06 + (bump * hk if sy > 0 else 0)", "hh_ * hk * 0.76 + (bump * hk * 0.5 if sy > 0 else 0)"),
        ("rx * hk * CAGE, ry * hk * CAGE, tex)", "rx * hk * 0.80, ry * hk * 0.80, tex)"),
        ('cg.piece("Arm." + side, "SuitFabric", "arm", subsurf=1)', 'cg.piece("Sleeve." + side, "LabCloth", "none", subsurf=1)'),
    ]
    for a, b in rep:
        if a not in s:
            raise SystemExit("gen_labwear: the suit's arm() changed; can't re-cut: " + a[:60])
        s = s.replace(a, b)
    cut = s.index("    # ── hardware on the arm")
    s = s[:cut] + "    return pc\n"
    s = s.replace("def arm(", "def lab_arm(")
    ns = dict(globals())
    ns.update(CLOTH=COAT, CLOTH_SH=COAT_SH, GLOVE=NITRILE, GLOVE_D=NITRILE, PALM=NITRILE, KNIT=KNIT)
    exec(compile(s, _SRC + ":arm (lab)", "exec"), ns)        # noqa: S102
    return ns["lab_arm"]


lab_arm = _lab_arm_fn()


def build_lab(rig):
    global X0
    J = rig.p
    head, back, hip = J("Head"), J("Back"), J("Hip")
    X0 = back[0]
    k = head[1] / 1.575
    zc = (back[2] + hip[2]) / 2
    nb = len(rig.names)
    D = np.tile(np.eye(4), (nb, 1, 1))
    for side, s in (("Left", 1.0), ("Right", -1.0)):
        R = rot_about(Z, -s * AUTHOR_ABDUCT, J("Upperarm." + side))
        D[rig.index["Upperarm." + side]] = R
        Ea = (R @ np.append(J("Forearm." + side), 1.0))[:3]
        Re = rot_about(unit(np.cross(unit(Ea - J("Upperarm." + side)), Z)), AUTHOR_ELBOW, Ea)
        for b in ("Forearm", "Hand", "Fingers1", "Fingers2", "Thumb1", "Thumb2"):
            D[rig.index[b + "." + side]] = Re @ R
        Kb = J("Shin." + side)
        Rk = rot_about(unit(np.cross(unit(Kb - J("Thigh." + side)), -Z)), AUTHOR_KNEE, Kb)
        for b in ("Shin", "Foot", "Toes"):
            D[rig.index[b + "." + side]] = Rk

    def Ja(name):
        return (D[rig.index[name]] @ np.append(J(name), 1.0))[:3]

    # ── THE COAT: hem to the neck, one surface, open in a V at the chest ──
    # Below Y_V the rings close round the body; above it they open into a V
    # whose edges fold back over the chest as LAPELS (the same sheet: the
    # lapel's outer edge, the fold, then the coat round the body), and a
    # notched COLLAR (its own piece) stands round the back of the neck and
    # falls over. A crew-neck knit (SHIRT) shows in the V; the head's own neck
    # rises out of its ribbed neckband with a centimetre to spare.
    zn = -0.055 * k                                   # the neck's centre, front to back
    N_ = 40
    Y_V = 1.315 * k
    RINGS = [  # y, half-width, front, back, centre z, squareness, back rise
        (0.800, 0.193, 0.140, 0.136, zc, 2.2, 0.0),     # the hem's turned-up inside
        (0.742, 0.212, 0.150, 0.146, zc, 2.2, 0.0),     # the inner edge of the hem
        (0.735, 0.215, 0.152, 0.148, zc, 2.2, 0.0),     # the hem
        (0.800, 0.209, 0.147, 0.145, zc, 2.2, 0.0),
        (0.900, 0.201, 0.140, 0.143, zc, 2.25, 0.0),
        (1.000, 0.195, 0.132, 0.143, zc, 2.3, 0.0),     # the seat
        (1.100, 0.185, 0.125, 0.133, zc, 2.3, 0.0),
        (1.200, 0.173, 0.118, 0.121, zc, 2.35, 0.0),    # the waist
        (1.260, 0.173, 0.121, 0.118, zc, 2.4, 0.0),
        (1.315, 0.176, 0.126, 0.118, zc, 2.45, 0.0),    # the V's foot
    ]
    UPPER = [  # y, half-width, front, back, centre z, squareness, V half-angle (rad), lapel width
        (1.315, 0.176, 0.126, 0.118, zc, 2.45, 0.00, 0.000),
        (1.360, 0.178, 0.130, 0.119, zc, 2.5, 0.12, 0.030),
        (1.420, 0.182, 0.128, 0.117, zc, 2.6, 0.23, 0.058),
        (1.470, 0.197, 0.116, 0.110, zc - 0.002, 2.9, 0.33, 0.070),
        (1.505, 0.198, 0.101, 0.098, zc - 0.004, 3.4, 0.42, 0.062),
        (1.526, 0.180, 0.092, 0.090, zc - 0.006, 3.4, 0.50, 0.050),   # the shoulder line
        (1.541, 0.138, 0.086, 0.086, zn + 0.001, 2.8, 0.60, 0.036),
        (1.553, 0.100, 0.080, 0.083, zn, 2.4, 0.70, 0.024),           # the collar's root
    ]

    def wrinkle(a, y):
        """Soft cloth folds as a radial ripple: across the waist where the
        coat gathers, under the arms, and a long drape down the skirt."""
        side = abs(math.sin(a))
        w = 0.0
        w += 0.010 * side * float(smooth01(1.10, 1.17, y / k) * smooth01(1.30, 1.22, y / k)) * math.sin(9 * a + y * 55)
        w += 0.008 * side ** 3 * float(smooth01(1.33, 1.38, y / k) * smooth01(1.46, 1.41, y / k)) * math.sin(14 * a + 3)
        w += 0.006 * float(smooth01(1.02, 0.85, y / k)) * math.sin(7 * a + 1.3) * (0.6 + 0.4 * math.sin(3 * a))
        return 1.0 + w

    def ring_pt(y, hw, hdf, hdb, zcc, sq, a, out=0.0):
        sa, ca = math.sin(a), math.cos(a)
        r = wrinkle(a, y)
        x = X0 + (hw * r + out) * sgnpow(sa, 2.0 / sq)
        hd = (hdf if ca >= 0 else hdb) * r + out
        z = zcc + hd * sgnpow(ca, 2.0 / sq)
        return np.array([x, y, z])

    Vl, idx = [], []
    for (y, hw, f, b, z, sq, dyb) in RINGS:
        row = []
        for i in range(N_):
            row.append(len(Vl))
            Vl.append(ring_pt(y * k, hw * k, f * k, b * k, z, sq, TAU * i / N_))
        idx.append(row)
    Fl = []
    for r0, r1 in zip(idx[:-1], idx[1:]):
        for i in range(N_):
            j = (i + 1) % N_
            Fl.append((r0[i], r0[j], r1[j], r1[i]))
    # the upper rows: [lapel edge L, fold L, arc a = h .. 2π−h (N_+1), fold R, lapel edge R]
    top = idx[-1]
    rows = []
    for ri, (y, hw, f, b, z, sq, h, lw) in enumerate(UPPER):
        y, hw, f, b, lw = y * k, hw * k, f * k, b * k, lw * k
        if ri == 0:
            row = [top[0], top[0]] + [top[j % N_] for j in range(N_ + 1)] + [top[0], top[0]]
            rows.append(row)
            continue
        row = []
        # how far round the body a lapel of width lw reaches, as an angle
        da = lw / max(1e-6, 0.5 * (hw + f))
        pts = [ring_pt(y, hw, f, b, z, sq, h + da, out=0.007 * k), ring_pt(y, hw, f, b, z, sq, h, out=0.0035 * k)]
        pts += [ring_pt(y, hw, f, b, z, sq, h + (TAU - 2 * h) * j / N_) for j in range(N_ + 1)]
        pts += [ring_pt(y, hw, f, b, z, sq, TAU - h, out=0.0035 * k), ring_pt(y, hw, f, b, z, sq, TAU - h - da, out=0.007 * k)]
        for p_ in pts:
            row.append(len(Vl))
            Vl.append(p_)
        rows.append(row)
    for r0, r1 in zip(rows[:-1], rows[1:]):
        for i in range(len(r0) - 1):
            q = [r0[i], r0[i + 1], r1[i + 1], r1[i]]
            u = []
            for v_ in q:
                if v_ not in u:
                    u.append(v_)
            if len(u) >= 3:
                Fl.append(tuple(u))
    V, F = np.array(Vl), Fl
    y_collar = 1.553 * k

    def coat_w(P):
        out = []
        for p in P:
            y = p[1]
            back_ = float(smooth01(1.17 * k, 1.33 * k, y))
            sd = float(smooth01(X0 - 0.06 * k, X0 + 0.06 * k, p[0]))
            th = float(smooth01(0.98 * k, 0.74 * k, y)) * 0.30    # the skirt follows the thighs a little
            lw = wsum((1 - th, {"Hip": 1.0}), (th * sd, {"Thigh.Left": 1.0}), (th * (1 - sd), {"Thigh.Right": 1.0}))
            out.append(wsum((back_, {"Back": 1.0}), (1 - back_, lw)))
        return out

    def coat_col(P, N):
        n1 = _noise_b(P, 3, 11.0)
        n2 = _noise_b(P, 9, 37.0)
        C = np.tile(COAT, (len(P), 1)) * (0.97 + 0.04 * n1 + 0.02 * n2)[:, None]
        # worn, not dirty: the hem's edge greyer, a shade round the hips where hands go
        C *= (1 - 0.07 * smooth01(0.80 * k, 0.735 * k, P[:, 1]))[:, None]
        sides = smooth01(0.12 * k, 0.19 * k, np.abs(P[:, 0] - X0)) * smooth01(0.85 * k, 0.95 * k, P[:, 1]) * \
            smooth01(1.12 * k, 1.02 * k, P[:, 1])
        C *= (1 - 0.05 * sides * (0.5 + 0.5 * n2))[:, None]
        return C
    # (the loft's quads are wound however its rings run: made consistent and
    # outward before the subdivision, or half the coat shades as its inside)
    coat = Piece("Coat", "LabCloth", V, F, coat_w, coat_col, tile=0.30, dirt="none", mods=[("recalc",), ("subsurf", 1)])

    # THE COLLAR: a stand round the back of the neck from notch to notch, its
    # fall turned down over it (one band folded: base, stand top, fold, edge)
    hT = 0.70 + 0.036 / 0.09
    CR = [  # y over the root, radius out from the root ring, back rise, along the arc
        (0.000, 0.000, 0.000), (0.026, -0.004, 0.012), (0.033, 0.003, 0.016),
        (0.020, 0.016, 0.008), (0.000, 0.026, -0.006)]
    hw_r, f_r, b_r = 0.100 * k, 0.080 * k, 0.083 * k
    cv, crows = [], []
    for (dy, dr, rise) in CR:
        row = []
        for j in range(N_ + 1):
            a = hT + (TAU - 2 * hT) * j / N_
            ca = math.cos(a)
            p_ = ring_pt(y_collar - 0.002 * k + dy * k, hw_r - 0.006 * k + dr * k, f_r - 0.006 * k + dr * k,
                         b_r - 0.006 * k + dr * k, zn, 2.4, a)
            p_[1] += rise * k * (1 - ca) / 2
            row.append(len(cv))
            cv.append(p_)
        crows.append(row)
    cf = []
    for r0, r1 in zip(crows[:-1], crows[1:]):
        for i in range(N_):
            cf.append((r0[i], r0[i + 1], r1[i + 1], r1[i]))

    def collar_w(P):
        return [blend("Back", "Head", float(smooth01(y_collar, 1.60 * k, p[1])) * 0.25) for p in P]
    Piece("Collar", "LabCloth", np.array(cv), cf, collar_w, COAT, tile=0.3, dirt="none", mods=[("recalc",), ("subsurf", 1)])

    # THE SHIRT: a crew-neck knit under the coat, seen in the V
    SH = [(1.280, 0.165, 0.116, 0.110, zc, 2.4), (1.360, 0.168, 0.122, 0.112, zc, 2.5),
          (1.430, 0.172, 0.118, 0.108, zc - 0.002, 2.6), (1.490, 0.170, 0.100, 0.096, zc - 0.004, 3.0),
          (1.525, 0.150, 0.086, 0.086, zn + 0.002, 2.8), (1.540, 0.100, 0.074, 0.080, zn, 2.4)]
    # a knitted mock neck (the band stands up the neck, as a lab's under-coat
    # knit does): the head's own neck flares into its shoulders below it
    NB = [(1.546, 0.0850, 0.0670, 0.0765, 0.000), (1.555, 0.0820, 0.0648, 0.0738, 0.012),
          (1.563, 0.0798, 0.0634, 0.0720, 0.026), (1.566, 0.0780, 0.0620, 0.0704, 0.029),
          (1.560, 0.0760, 0.0602, 0.0686, 0.027)]
    srings = [body_ring(y * k, hw * k, f * k, b * k, z, sq, N_) for (y, hw, f, b, z, sq) in SH]
    srings += [body_ring(y * k, hw * k, f * k, b * k, zn, 2.4, N_, dyb * k) for (y, hw, f, b, dyb) in NB]
    Vs, Fs = quads(srings)
    nsh = len(SH) * N_

    def shirt_col(P, N):
        C = np.tile(SHIRT, (len(P), 1))
        C[P[:, 1] > 1.543 * k] = SHIRT_RIB
        return C * (0.96 + 0.06 * _noise_b(P, 5, 60.0))[:, None]

    def shirt_w(P):
        return [blend("Back", "Head", float(smooth01(1.548 * k, 1.60 * k, p[1])) * 0.3) for p in P]
    Piece("Shirt", "LabKnit", Vs, Fs, shirt_w, shirt_col, tile=0.12, dirt="none", mods=[("recalc",), ("subsurf", 1)])
    tree = bvh(coat)

    # the snap placket down the front, and its snaps
    def front(x, y):
        hit, nrm = surf_point(tree, (x, y, 0.6), (0, 0, -1), (x, y, zc + 0.13 * k))
        return hit, nrm
    pl = []
    ys = np.linspace(0.745 * k, 1.310 * k, 24)
    for y in ys:
        row = []
        for dx in (-0.019, 0.019):
            h, nrm = front(X0 + dx * k + 0.012 * k, y)
            row.append(h + unit(nrm) * 0.0028 * k)
        pl.append(row)
    Vp, Fp = [], []
    for i, (a_, b_) in enumerate(pl):
        Vp += [a_, b_]
        if i:
            Fp.append((2 * i - 2, 2 * i - 1, 2 * i + 1, 2 * i))
    # its edge: a thin wall down the overlapping side (the coat's left over its right)
    n0 = len(Vp)
    for i, (a_, b_) in enumerate(pl):
        h, nrm = front(X0 - 0.007 * k, ys[i])
        Vp.append(h + unit(nrm) * 0.0002)
    for i in range(1, len(pl)):
        Fp.append((2 * (i - 1), 2 * i, n0 + i, n0 + i - 1))
    Piece("Placket", "LabCloth", np.array(Vp), Fp, coat_w, COAT_SH, tile=0.3, dirt="none")
    for y in np.arange(0.86, 1.29, 0.105) * k:
        h, nrm = front(X0 + 0.012 * k, y)
        nrm = unit(nrm)
        V, F = cyl_mesh(h + nrm * 0.002 * k, h + nrm * 0.0055 * k, 0.0062 * k, segs=10)
        Piece("Snap", "LabPlastic", V, F, coat_w, SNAP, tile=0.1, dirt="none", smooth=False, sharp=40)

    # the pockets: one on the left breast (pens, the badge on its lip), two low
    def pocket(name, xc, y0, y1, w):
        V, F = slab_on(tree, lambda s_, t_: (xc - w / 2 + w * s_, y0 + (y1 - y0) * t_, 0.0), 4, 4, 0.0015 * k,
                       0.0022 * k, (0, 0, 1))
        Piece(name, "LabCloth", V, F, coat_w, COAT_SH, tile=0.3, dirt="none", smooth=False, sharp=50)
    pocket("PocketBreast", X0 + 0.105 * k, 1.200 * k, 1.305 * k, 0.100 * k)
    pocket("PocketLowL", X0 + 0.110 * k, 0.905 * k, 1.075 * k, 0.150 * k)
    pocket("PocketLowR", X0 - 0.110 * k, 0.905 * k, 1.075 * k, 0.150 * k)
    # pens in the breast pocket, their clips over its lip
    for dx, col in ((0.080, PEN_BLUE), (0.094, PEN_BLACK)):
        x = X0 + dx * k
        h, nrm = front(x, 1.305 * k)
        nrm = unit(nrm)
        b0 = h + nrm * 0.006 * k - Y * 0.030 * k
        V, F = cyl_mesh(b0, b0 + Y * 0.062 * k, 0.0046 * k, segs=10, r1=0.0042 * k)
        Piece("Pen", "LabPlastic", V, F, {"Back": 1}, col, tile=0.1, dirt="none")
        V, F = box_mesh(b0 + Y * 0.044 * k + nrm * 0.0058 * k, (0.0028 * k, 0.034 * k, 0.0016 * k))
        Piece("PenClip", "LabPlastic", V, F, {"Back": 1}, CLIP, tile=0.1, dirt="none", smooth=False)
    # the ID badge, clipped to the pocket's lip and hanging over it
    bx = X0 + 0.128 * k
    h, nrm = front(bx, 1.262 * k)
    nrm = unit(nrm)
    Mb = np.column_stack([unit(np.cross(Y, nrm)), Y, nrm])
    bc = h + nrm * 0.0075 * k
    V, F = box_mesh(bc, (0.054 * k, 0.080 * k, 0.0018 * k), Mb)
    Piece("Badge", "LabPlastic", V, F, {"Back": 1}, BADGE, tile=0.1, dirt="none", smooth=False)
    V, F = box_mesh(bc + Y * 0.031 * k + nrm * 0.0011 * k, (0.054 * k, 0.012 * k, 0.0006 * k), Mb)
    Piece("BadgeBand", "LabPlastic", V, F, {"Back": 1}, BADGE_BAND, tile=0.1, dirt="none", smooth=False)
    V, F = box_mesh(bc + Y * 0.004 * k - Mb[:, 0] * 0.012 * k + nrm * 0.0011 * k, (0.022 * k, 0.028 * k, 0.0006 * k), Mb)
    Piece("BadgePhoto", "LabPlastic", V, F, {"Back": 1}, PHOTO, tile=0.1, dirt="none", smooth=False)
    for q in range(3):
        V, F = box_mesh(bc + Y * (0.004 - q * 0.007) * k + Mb[:, 0] * 0.013 * k + nrm * 0.0011 * k,
                        (0.020 * k, 0.0022 * k, 0.0006 * k), Mb)
        Piece("BadgeText", "LabPlastic", V, F, {"Back": 1}, (0.25, 0.25, 0.26), tile=0.1, dirt="none", smooth=False)
    V, F = box_mesh(bc + Y * 0.047 * k, (0.012 * k, 0.016 * k, 0.003 * k), Mb)
    Piece("BadgeClip", "LabPlastic", V, F, {"Back": 1}, CLIP, tile=0.1, dirt="none", smooth=False)

    # the neck under the collar (SuitHead: the wearer's skin, face.lua): the
    # HEAD'S NECK CONTINUED. Every crew head's own neck ends in a ragged edge
    # at y 1.559-1.574, level with the mock neck's rim, so this carries it on
    # down into the knit: rigid on the Head bone where it meets the head (so
    # the join never opens however the head turns), 3 mm inside the edge
    # just under it and 4-5.5 mm inside the head's neck above it (hidden), the
    # twist to the Back bone down inside the band, and a foot that flares out
    # under the knit so a look down past the neck finds skin. NECK_E/NECK_U
    # are the narrowest of the eight heads' necks (models/astronaut/faces) by
    # direction round the neck's axis (x -0.5 bind, z = zn), every 22.5°
    # from +x towards the front (+z): at the edge, and at y 1.575-1.585.
    # (Until 2026-11-04 it was an ellipse 49 mm deep in front up to 1.585:
    # it came out through every head's throat as a pale ring, its colour sRGB
    # in a linear slot.) tools/gen_labwear.py --neck checks it.
    NECK_E = (58.4, 50.9, 45.1, 47.0, 50.0, 47.0, 45.1, 50.9, 58.4, 63.7, 56.6, 51.5, 49.5, 51.5, 56.6, 63.7)
    NECK_U = (56.6, 50.8, 45.1, 47.0, 50.0, 47.0, 45.1, 50.8, 56.6, 62.1, 56.6, 51.5, 49.5, 51.5, 56.6, 62.1)

    def neck_r(tab, d_mm, scale=1.0):
        def rad(a):
            u = (a % TAU) / TAU * 16
            i = int(u) % 16
            f = u - int(u)
            return ((tab[i] * (1 - f) + tab[(i + 1) % 16] * f) * scale + d_mm) * 0.001 * k
        return rad
    nr = []
    for y, tab, d_mm, sc, w in ((1.475, NECK_E, 12.0, 1.0, {"Back": 1}),
                                (1.498, NECK_E, 0.0, 0.97, blend("Back", "Head", 0.15)),
                                (1.515, NECK_E, -3.0, 1.0, blend("Back", "Head", 0.4)),
                                (1.540, NECK_E, -3.0, 1.0, blend("Back", "Head", 0.75)),
                                (1.557, NECK_E, -3.0, 1.0, {"Head": 1}),
                                (1.575, NECK_U, -4.0, 1.0, {"Head": 1}),
                                (1.587, NECK_U, -5.5, 1.0, {"Head": 1})):
        nr.append(dict(c=(X0, y * k, zn), e1=X, e2=Z, r1=1e-5, r2=1e-5, rad=neck_r(tab, d_mm, sc), w=w))
    V, F, UVc, W, C = loft(nr, 32, tile=0.25)
    npc = Piece("Neck", "SuitHead", V, F, W, (1, 1, 1), dirt="none")
    npc.uvmode = "plain"

    # the shoulder seams: a felled seam round each armhole, where the sleeve
    # head meets the body (on the body: the dome turns inside it)
    for side, s in (("Left", 1.0), ("Right", -1.0)):
        S = J("Upperarm." + side)
        n = unit(np.array([s * 1.0, 0.25, 0.04]))
        dd = 0.017 * k
        rr = math.sqrt((LAB_RB * k) ** 2 - dd ** 2) + 0.0015 * k
        c = S + n * dd
        e1 = unit(np.cross(n, Z)); e2 = np.cross(n, e1)
        pts = [c + (e1 * math.cos(a) + e2 * math.sin(a)) * rr for a in np.linspace(0, TAU, 49)]
        sr = [dict(c=p_, r=0.0019 * k, w={"Back": 1}, col=COAT_SH) for p_ in pts]
        Vq, Fq, UVq, Wq, Cq = loft(limb(sr, n), 6, tile=0.1)
        Piece("Seam." + side, "LabCloth", Vq, Fq, Wq, Cq, UVc=UVq, dirt="none")

    # ── SLEEVES and GLOVES ────────────────────────────────────────────────
    for side, s in (("Left", 1.0), ("Right", -1.0)):
        S = Ja("Upperarm." + side)
        pc = lab_arm(rig, D, Ja, J, side, s, k, (S, unit(np.array([s * 0.74, -0.56, 0.22])), 0.040 * k))
        split_by_colour(pc, NITRILE, "Glove." + side, "LabNitrile")

    # ── TROUSERS ──────────────────────────────────────────────────────────
    for side, s in (("Left", 1.0), ("Right", -1.0)):
        th, sh_, ft = "Thigh." + side, "Shin." + side, "Foot." + side
        Tp, K_, A = Ja(th), Ja(sh_), Ja(ft)
        axt, axs = unit(K_ - Tp), unit(A - K_)
        LT, LS = float(np.linalg.norm(K_ - Tp)), float(np.linalg.norm(A - K_))
        nb_k = unit(axt + axs)
        lr = []
        prof = [(-0.020, 0.082, axt, Tp), (0.06, 0.084, axt, Tp), (0.16, 0.080, axt, Tp), (0.26, 0.073, axt, Tp),
                (LT - 0.07, 0.064, axt, Tp)]
        for dd, r, ax, o in prof:
            lr.append(dict(c=o + ax * dd * k, r=r * k, r2=r * k * 0.96, w=None, t=ax))
        for dd, r in ((-0.03, 0.061), (0.0, 0.062), (0.03, 0.059)):
            if dd < 0:
                c, t = K_ + axt * dd * k, unit(axt + nb_k)
            elif dd > 0:
                c, t = K_ + axs * dd * k, unit(axs + nb_k)
            else:
                c, t = K_, nb_k
            lr.append(dict(c=c, r=r * k, r2=r * k * 0.97, t=t))
        for dd, r in ((0.10, 0.057), (0.22, 0.054), (0.32, 0.052), (LS / k - 0.075, 0.051), (LS / k - 0.058, 0.0515)):
            lr.append(dict(c=K_ + axs * dd * k, r=r * k, r2=r * k * 0.98, t=axs))
        rr = []
        for q in lr:
            t = unit(q["t"])
            e1 = unit(Z - t * (Z @ t))
            e2 = np.cross(t, e1)
            rr.append(dict(c=q["c"], e1=e1, e2=e2, r1=q["r"], r2=q["r2"], w={"Hip": 1}, col=TROUSER,
                           rad=lambda a, c=q["c"]: 0.004 * math.sin(3 * a + c[1] * 40)))
        V, F, UVc, W, C = loft(rr, 16, cap0=True, tile=0.25)
        LL = dict(T=Tp, K=K_, A=A, axt=axt, axs=axs, nb_k=nb_k)

        def leg_w(P, L=LL, th=th, sh_=sh_, ft=ft):
            out = []
            for p in P:
                sv = float((p - L["T"]) @ L["axt"])
                wt = float(smooth01(-0.05 * k, 0.07 * k, sv))
                sk = float((p - L["K"]) @ L["nb_k"])
                wk = float(smooth01(-0.035 * k, 0.035 * k, sk))
                ha = float((L["A"] - p) @ L["axs"])
                wa = 1.0 - float(smooth01(0.045 * k, 0.09 * k, ha))
                out.append({"Hip": 1 - wt, th: wt * (1 - wk), sh_: wt * wk * (1 - wa), ft: wt * wk * wa})
            return out
        Piece("Trouser." + side, "LabCloth", V, F, leg_w, C, UVc=UVc, dirt="none", mods=[("subsurf", 1)])

    # ── SHOES ─────────────────────────────────────────────────────────────
    for side, s in (("Left", 1.0), ("Right", -1.0)):
        A, Tp = J("Foot." + side), J("Toes." + side)
        ft, to = "Foot." + side, "Toes." + side
        Mf = D[rig.index[ft]]

        def posed(V, Mf=Mf):
            V = np.asarray(V, float)
            return (np.hstack([V, np.ones((len(V), 1))]) @ Mf.T)[:, :3]
        bxx = A[0] + s * 0.003 * k
        heel_z, toe_z = A[2] - 0.072 * k, Tp[2] + 0.100 * k
        sole_t = 0.026 * k
        ty = Tp[2]
        SEC = [(heel_z, 0.032, 0.070), (heel_z + 0.012 * k, 0.043, 0.095), (heel_z + 0.040 * k, 0.047, 0.108),
               (A[2] + 0.035 * k, 0.048, 0.104), (ty - 0.045 * k, 0.050, 0.086), (ty - 0.005 * k, 0.050, 0.074),
               (ty + 0.040 * k, 0.047, 0.066), (toe_z - 0.028 * k, 0.041, 0.058), (toe_z - 0.008 * k, 0.032, 0.050),
               (toe_z, 0.017, 0.041)]

        def bw(z, ty=ty, ft=ft, to=to):
            return blend(ft, to, float(smooth01(ty - 0.030 * k, ty + 0.012 * k, z)))
        up_, so_ = [], []
        for i, (z, hw, tp) in enumerate(SEC):
            y0 = sole_t - 0.004 * k
            tp = tp * k
            up_.append(dict(c=(bxx, (y0 + tp) / 2, z), e1=X, e2=Y, r1=hw * k, r2=(tp - y0) / 2, sq=2.6, w=bw(z),
                            col=SHOE))
            so_.append(dict(c=(bxx, sole_t / 2, z), e1=X, e2=Y, r1=(hw + 0.005) * k * (0.9 if i in (0, 9) else 1.0),
                            r2=sole_t / 2, sq=6.0, w=bw(z), col=SHOE_SOLE))
        V, F, UVc, W, C = loft(up_, 14, cap0=True, cap1=True, tile=0.25)
        Piece("Shoe." + side, "LabShoe", posed(V), F, W, C, UVc=UVc, dirt="none", sharp=60)
        V, F, UVc, W, C = loft(so_, 8, cap0=True, cap1=True, tile=0.25)
        Piece("Sole." + side, "LabShoe", posed(V), F, W, C, UVc=UVc, dirt="none", sharp=45)
    return D


def _noise_b(P, seed, freq):
    P = np.asarray(P, float) * freq
    return 0.5 + 0.25 * np.sin(P[:, 0] * 1.7 + seed) * np.sin(P[:, 1] * 2.3 + seed * 0.7) \
        + 0.25 * np.sin(P[:, 2] * 3.1 + P[:, 1] * 0.9 + seed * 1.3)


X0 = 0.0


def lab_main():
    global COL
    import builtins
    bpy.ops.wm.read_factory_settings(use_empty=True)
    COL = bpy.data.collections.new("lab")
    bpy.context.scene.collection.children.link(COL)
    # the suit's helpers read COL from their own module globals: the same dict
    globals()["COL"] = COL
    rig = Rig(RIG_PATH)
    D = build_lab(rig)
    export(rig, D, OUT_PATH)


lab_main()
