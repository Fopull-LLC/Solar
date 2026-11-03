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
COAT = (0.88, 0.885, 0.875)
COAT_SH = (0.80, 0.805, 0.795)
KNIT = (0.74, 0.745, 0.74)
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
LAB_RB = 0.046                       # the sleeve head's dome (radius, m)


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
         """    for t, r, col in ((0.070, 0.045, CLOTH), (0.115, 0.047, CLOTH), (0.165, 0.047, CLOTH), (0.212, 0.046, CLOTH),
                      (0.250, 0.045, CLOTH)):"""),
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

    # ── THE COAT: hem to the band collar, one surface ──────────────────────
    zn = -0.055 * k                                   # the neck's centre, front to back
    N_ = 40
    RINGS = [  # y, half-width, front, back, centre z, squareness, back rise
        (0.800, 0.193, 0.140, 0.136, zc, 2.2, 0.0),     # the hem's turned-up inside
        (0.742, 0.212, 0.150, 0.146, zc, 2.2, 0.0),     # the inner edge of the hem
        (0.735, 0.215, 0.152, 0.148, zc, 2.2, 0.0),     # the hem
        (0.800, 0.209, 0.147, 0.145, zc, 2.2, 0.0),
        (0.900, 0.201, 0.140, 0.143, zc, 2.25, 0.0),
        (1.000, 0.195, 0.132, 0.143, zc, 2.3, 0.0),     # the seat
        (1.100, 0.185, 0.125, 0.133, zc, 2.3, 0.0),
        (1.200, 0.173, 0.118, 0.121, zc, 2.35, 0.0),    # the waist
        (1.280, 0.173, 0.122, 0.118, zc, 2.4, 0.0),
        (1.360, 0.178, 0.130, 0.119, zc, 2.5, 0.0),     # the chest
        (1.420, 0.182, 0.128, 0.117, zc, 2.6, 0.0),
        (1.470, 0.192, 0.116, 0.110, zc - 0.002, 2.9, 0.0),
        (1.505, 0.193, 0.101, 0.098, zc - 0.004, 3.4, 0.0),
        (1.526, 0.180, 0.092, 0.090, zc - 0.006, 3.4, 0.0),   # the shoulder line
        (1.541, 0.138, 0.084, 0.084, zn + 0.001, 2.8, 0.0),
        (1.553, 0.096, 0.075, 0.081, zn, 2.4, 0.0),           # the collar's root
        (1.560, 0.089, 0.070, 0.079, zn, 2.4, 0.008),         # the band collar
        (1.568, 0.087, 0.069, 0.078, zn, 2.4, 0.022),
        (1.574, 0.0865, 0.0690, 0.0775, zn, 2.4, 0.034),     # its top edge (front 1.574, back 1.608)
        (1.5755, 0.0835, 0.0662, 0.0745, zn, 2.4, 0.035),    # rolled over
        (1.570, 0.0800, 0.0632, 0.0715, zn, 2.4, 0.032),     # the inside face
        (1.554, 0.0790, 0.0622, 0.0705, zn, 2.4, 0.012),
    ]
    rings = [body_ring(y * k, hw * k, f * k, b * k, z, sq, N_, dyb * k) for (y, hw, f, b, z, sq, dyb) in RINGS]
    V, F = quads(rings)
    y_collar = 1.553 * k

    def coat_w(P):
        out = []
        for p in P:
            y = p[1]
            if y > y_collar - 0.004 * k:
                # the band collar: its top a third onto the head
                h = float(smooth01(y_collar, 1.600 * k, y)) * 0.34
                out.append(blend("Back", "Head", h))
                continue
            back_ = float(smooth01(1.17 * k, 1.33 * k, y))
            sd = float(smooth01(X0 - 0.06 * k, X0 + 0.06 * k, p[0]))
            th = float(smooth01(0.98 * k, 0.74 * k, y)) * 0.30    # the skirt follows the thighs a little
            lw = wsum((1 - th, {"Hip": 1.0}), (th * sd, {"Thigh.Left": 1.0}), (th * (1 - sd), {"Thigh.Right": 1.0}))
            out.append(wsum((back_, {"Back": 1.0}), (1 - back_, lw)))
        return out

    def coat_col(P, N):
        n1 = _noise_b(P, 3, 11.0)
        C = np.tile(COAT, (len(P), 1)) * (0.975 + 0.05 * n1)[:, None]
        # a pristine coat, but worn: the cuffs' and the hem's edge a shade greyer
        C *= (1 - 0.06 * smooth01(0.80 * k, 0.735 * k, P[:, 1]))[:, None]
        return C
    # (the loft's quads are wound however its rings run: made consistent and
    # outward before the subdivision, or half the coat shades as its inside)
    coat = Piece("Coat", "LabCloth", V, F, coat_w, coat_col, tile=0.30, dirt="none", mods=[("recalc",), ("subsurf", 1)])
    tree = bvh(coat)

    # the snap placket down the front, and its snaps
    def front(x, y):
        hit, nrm = surf_point(tree, (x, y, 0.6), (0, 0, -1), (x, y, zc + 0.13 * k))
        return hit, nrm
    pl = []
    ys = np.linspace(0.745 * k, 1.546 * k, 34)
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
    for y in np.arange(0.86, 1.52, 0.096) * k:
        h, nrm = front(X0 + 0.012 * k, y)
        nrm = unit(nrm)
        V, F = cyl_mesh(h + nrm * 0.002 * k, h + nrm * 0.0055 * k, 0.0062 * k, segs=10)
        Piece("Snap", "LabPlastic", V, F, coat_w, SNAP, tile=0.1, dirt="none", smooth=False, sharp=40)

    # the pockets: one on the left breast (pens, the badge on its lip), two low
    def pocket(name, xc, y0, y1, w):
        V, F = slab_on(tree, lambda s_, t_: (xc - w / 2 + w * s_, y0 + (y1 - y0) * t_, 0.0), 4, 4, 0.0015 * k,
                       0.0022 * k, (0, 0, 1))
        Piece(name, "LabCloth", V, F, coat_w, COAT_SH, tile=0.3, dirt="none", smooth=False, sharp=50)
    pocket("PocketBreast", X0 + 0.085 * k, 1.330 * k, 1.448 * k, 0.110 * k)
    pocket("PocketLowL", X0 + 0.110 * k, 0.905 * k, 1.075 * k, 0.150 * k)
    pocket("PocketLowR", X0 - 0.110 * k, 0.905 * k, 1.075 * k, 0.150 * k)
    # pens in the breast pocket, their clips over its lip
    for dx, col in ((0.058, PEN_BLUE), (0.072, PEN_BLACK)):
        x = X0 + dx * k
        h, nrm = front(x, 1.448 * k)
        nrm = unit(nrm)
        b0 = h + nrm * 0.006 * k - Y * 0.030 * k
        V, F = cyl_mesh(b0, b0 + Y * 0.062 * k, 0.0046 * k, segs=10, r1=0.0042 * k)
        Piece("Pen", "LabPlastic", V, F, {"Back": 1}, col, tile=0.1, dirt="none")
        V, F = box_mesh(b0 + Y * 0.044 * k + nrm * 0.0058 * k, (0.0028 * k, 0.034 * k, 0.0016 * k))
        Piece("PenClip", "LabPlastic", V, F, {"Back": 1}, CLIP, tile=0.1, dirt="none", smooth=False)
    # the ID badge, clipped to the pocket's lip and hanging over it
    bx = X0 + 0.110 * k
    h, nrm = front(bx, 1.405 * k)
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

    # the neck under the collar (SuitHead: the wearer's skin, face.lua)
    nr = []
    for y, r, w in ((1.500, 0.050, {"Back": 1}), (1.530, 0.049, blend("Back", "Head", 0.3)),
                    (1.560, 0.047, blend("Back", "Head", 0.6)), (1.585, 0.045, blend("Back", "Head", 0.8))):
        nr.append(dict(c=(X0, y * k, zn + 0.004 * k), e1=X, e2=Z, r1=r * k * 1.12, r2=r * k * 0.96, w=w))
    V, F, UVc, W, C = loft(nr, 16, tile=0.25)
    npc = Piece("Neck", "SuitHead", V, F, W, (1, 1, 1), dirt="none")
    npc.uvmode = "plain"

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
