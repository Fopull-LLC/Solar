"""The crew's gloved hands for the first-person view models (playtest 2026-11-04:
"the fingers are very clearly capsule-shaped blobs").

    import fp_hands as H
    m = H.glove(side="R", place=H.on_cylinder(...), elbow=..., pose=...)

A hand is modelled the way a hand is built, then meshed as one skin:

  * the PALM from its four metacarpals (round cones from the carpus to the
    knuckles, which therefore stand out on the back of the hand), the carpus,
    a palmar pad under them, the pads under the knuckles, the thenar mass at
    the thumb's root and the hypothenar along the little-finger edge;
  * four FINGERS of three phalanges each, anatomical lengths (middle longest,
    the little finger short and set back on an arched knuckle line), tapering,
    a little flatter than wide, the joints a touch fuller than the shafts, a
    fleshy pad under each fingertip;
  * the THUMB from the base of the palm (its metacarpal inside the thenar
    mass), turned to oppose the fingers;
  * the GLOVE over it (an EVA glove, tools/gen_suit.py): cloth a couple of
    millimetres thick, a padded knuckle bar across the back, creases at the
    flexed joints, dark RTV grip on the palm and finger pads and over the
    fingertips, the gauntlet flaring to the wrist bearing.

The parts are signed-distance primitives joined with smooth minima (each
finger blends into the palm, never into its neighbour), the field is meshed
with surface nets, decimated in Blender (headless) to a few thousand
triangles, put back on the surface, given the field's own gradient as normals,
and the dark grip is cut along a smooth line (not a triangle staircase).

Frames. A hand is built in its own frame and then placed: origin at the wrist
(the middle of the carpus' proximal edge), +Y distal (toward the fingertips),
+Z dorsal (the back of the hand) and, for the RIGHT hand, +X ulnar (toward the
little finger; the thumb is on -X). The left hand is its mirror (x negated).

Posing: `Pose` holds per-finger (spread, mcp, pip, dip) flexion in radians and
the thumb's angles; `wrap()` closes the fingers round a cylinder (a grip, a
handle, a pole) until each joint touches it, the way a hand closes on a bar.
`on_cylinder()` gives the placement that sets a power grip's palm on a
cylinder in the model's frame.
"""
import json
import math
import os
import subprocess
import tempfile

import numpy as np

from gen_part_meshes import Model, tube

BLENDER = os.environ.get("BLENDER", "/mnt/disks/3tb/SteamLibrary/steamapps/common/Blender/blender")

# ── the hand's dimensions (metres, a man's hand in a fitted EVA glove) ──────
GLOVE_T = 0.0018            # the glove's cloth and bladder over the skin

FINGERS = ("index", "middle", "ring", "little")
# knuckle (MCP) centres in the hand frame: an arched line, the middle highest
# and furthest out, the little finger set back and dropped toward the palm
MCP = {"index": (-0.0285, 0.0880, -0.0020), "middle": (-0.0080, 0.0930, 0.0005),
       "ring": (0.0120, 0.0895, -0.0015), "little": (0.0300, 0.0805, -0.0055)}
# where each metacarpal leaves the carpus
CMC = {"index": (-0.0150, 0.0230, 0.0000), "middle": (-0.0040, 0.0225, 0.0020),
       "ring": (0.0075, 0.0240, 0.0005), "little": (0.0180, 0.0280, -0.0025)}
# phalanx lengths joint to joint (the last to the end of the bone)
PHAL = {"index": (0.0400, 0.0235, 0.0165), "middle": (0.0450, 0.0275, 0.0175),
        "ring": (0.0420, 0.0262, 0.0170), "little": (0.0330, 0.0190, 0.0155)}
# skin radii at the MCP, PIP, DIP and the fingertip
RAD = {"index": (0.0098, 0.0090, 0.0079, 0.0069), "middle": (0.0100, 0.0093, 0.0081, 0.0071),
       "ring": (0.0094, 0.0087, 0.0076, 0.0066), "little": (0.0084, 0.0077, 0.0069, 0.0061)}
# the rest splay of each finger in the palm's plane (rad, + toward the thumb)
SPLAY = {"index": 0.07, "middle": 0.0, "ring": -0.06, "little": -0.13}
FLAT = 0.86                 # a finger's depth over its width

# the thumb: the carpometacarpal joint low on the palm's radial edge, its
# metacarpal (inside the thenar mass), proximal and distal phalanges
THUMB_CMC = (-0.0190, 0.0215, -0.0090)
THUMB_LEN = (0.0440, 0.0310, 0.0255)
THUMB_RAD = (0.0125, 0.0108, 0.0098, 0.0088, 0.0076)    # base, MCP, IP, distal mid, tip


def _n(v):
    v = np.asarray(v, float)
    return v / max(float(np.linalg.norm(v)), 1e-12)


def _rot(axis, ang):
    """Rodrigues: the rotation matrix of `ang` about `axis`."""
    k = _n(axis)
    K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]])
    return np.eye(3) + math.sin(ang) * K + (1 - math.cos(ang)) * (K @ K)


class Pose:
    """Joint angles (rad). fingers[name] = [spread, mcp, pip, dip] (flexion
    positive, toward the palm); thumb = dict(abd, flex, rot, mcp, ip):
    abd lifts the thumb off the palm's plane (palmar abduction), flex swings
    it across the palm toward the little finger, rot turns it on its own axis
    to face the fingers (opposition), mcp/ip bend its two joints."""

    def __init__(self, curl=0.25, thumb=None, wrist=(0.0, 0.0)):
        self.fingers = {f: [0.0, curl, curl * 1.1, curl * 0.7] for f in FINGERS}
        self.thumb = dict(abd=0.35, flex=0.15, rot=0.55, mcp=0.15, ip=0.15)
        if thumb:
            self.thumb.update(thumb)
        self.wrist = wrist          # (flex, deviation): the forearm's turn off the hand (unused by the solver)

    def copy(self):
        p = Pose()
        p.fingers = {k: list(v) for k, v in self.fingers.items()}
        p.thumb = dict(self.thumb)
        p.wrist = tuple(self.wrist)
        return p


# ── the skeleton: joint positions and frames from a pose ───────────────────

def finger_chain(name, ang):
    """[(p0, p1, r0, r1, dorsal, lateral)] for the three phalanges, in the
    hand frame, plus the tip point."""
    spread, mcp, pip, dip = ang
    p = np.asarray(MCP[name], float)
    # (right hand: +X ulnar; a + turn about +Z swings +Y toward -X, the thumb)
    ax = _rot((0, 0, 1), SPLAY[name] + spread) @ np.array([0.0, 1.0, 0.0])
    dor = np.array([0.0, 0.0, 1.0])
    # the knuckle arch: the outer fingers' backs roll a little outward
    roll = {"index": 0.10, "middle": 0.0, "ring": -0.08, "little": -0.18}[name]
    dor = _rot(ax, roll) @ dor
    segs = []
    r = RAD[name]
    for k, (L, fl) in enumerate(zip(PHAL[name], (mcp, pip, dip))):
        lat = np.cross(ax, dor)
        R = _rot(lat, -fl)
        ax, dor = R @ ax, R @ dor
        q = p + ax * L
        segs.append((p.copy(), q.copy(), r[k] + GLOVE_T, r[k + 1] + GLOVE_T, dor.copy(), _n(np.cross(ax, dor))))
        p = q
    return segs


def thumb_chain(t):
    """The thumb's metacarpal and two phalanges: [(p0, p1, r0, r1, pad_dir)]."""
    # the rest frame at the CMC: along the metacarpal (out to the radial
    # side, distal, a little palmar) and the direction its pad faces
    ax = _n((-0.60, 0.74, -0.30))
    pad = _n((0.62, 0.20, -0.76))
    pad = _n(pad - ax * (pad @ ax))
    # palmar abduction: off the palm's plane toward the palm side
    a_abd = _n(np.cross(ax, (0, 0, -1)))
    R = _rot(a_abd, t["abd"])
    ax, pad = R @ ax, R @ pad
    # flexion across the palm toward the little finger (+X), about the dorsal axis
    R = _rot((0, 0, 1), -t["flex"])
    ax, pad = R @ ax, R @ pad
    # opposition: the thumb turns on its own axis, its pad toward the fingers
    R = _rot(ax, t["rot"])
    pad = R @ pad
    p = np.asarray(THUMB_CMC, float)
    out = []
    rr = THUMB_RAD
    radii = ((rr[0], rr[1]), (rr[1], rr[2]), (rr[2], rr[4]))
    for k, L in enumerate(THUMB_LEN):
        if k >= 1:
            fl = t["mcp"] if k == 1 else t["ip"]
            lat = np.cross(pad, ax)          # (a + turn about it swings ax away from the pad)
            R = _rot(lat, -fl)
            ax, pad = R @ ax, R @ pad
        q = p + ax * L
        out.append((p.copy(), q.copy(), radii[k][0] + GLOVE_T, radii[k][1] + GLOVE_T, pad.copy()))
        p = q
    return out


# ── signed distances (vectorised over an (N, 3) array of points) ───────────

def sd_round_cone(P, a, b, r1, r2):
    a, b = np.asarray(a, float), np.asarray(b, float)
    ba = b - a
    l2 = float(ba @ ba)
    rr = r1 - r2
    a2 = l2 - rr * rr
    il2 = 1.0 / l2
    pa = P - a
    y = pa @ ba
    z = y - l2
    x2v = pa * l2 - y[:, None] * ba
    x2 = np.einsum("ij,ij->i", x2v, x2v)
    y2 = y * y * l2
    z2 = z * z * l2
    k = math.copysign(1.0, rr) * rr * rr * x2
    d3 = (np.sqrt(np.maximum(x2 * a2 * il2, 0)) + y * rr) * il2 - r1
    d1 = np.sqrt(x2 + z2) * il2 - r2
    d2 = np.sqrt(x2 + y2) * il2 - r1
    d = np.where(np.sign(y) * a2 * y2 < k, d2, d3)
    d = np.where(np.sign(z) * a2 * z2 > k, d1, d)
    return d


def sd_flat_cone(P, a, b, r1, r2, n, f):
    """A round cone squashed to `f` of its depth along the unit vector n
    (a finger: a little flatter than wide)."""
    a = np.asarray(a, float)
    n = _n(n)
    Q = P - a
    Q = Q + np.outer(Q @ n, n) * (1.0 / f - 1.0)
    return sd_round_cone(Q, np.zeros(3), np.asarray(b, float) - a, r1, r2) * (0.5 + 0.5 * f)


def sd_ellipsoid(P, c, r, M=None):
    Q = P - np.asarray(c, float)
    if M is not None:
        Q = Q @ np.asarray(M)          # rows: the local axes
    r = np.asarray(r, float)
    k0 = np.linalg.norm(Q / r, axis=1)
    k1 = np.linalg.norm(Q / (r * r), axis=1)
    return k0 * (k0 - 1.0) / np.maximum(k1, 1e-12)


def smin(a, b, k):
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0.0, 1.0)
    return b + (a - b) * h - k * h * (1.0 - h)


def _frame_rows(x, y):
    """Rows: a local frame whose y is `y` and x as near `x` as allows."""
    y = _n(y)
    x = _n(np.asarray(x, float) - y * (np.asarray(x, float) @ y))
    return np.vstack([x, y, np.cross(x, y)])


class HandField:
    """The posed hand as a signed-distance field (right hand's frame), with
    the per-part data the materials need."""

    def __init__(self, pose, forearm=(0.0, -1.0, 0.0), cuff=0.050):
        self.pose = pose
        self.fingers = {f: finger_chain(f, pose.fingers[f]) for f in FINGERS}
        self.thumb = thumb_chain(pose.thumb)
        self.forearm = _n(forearm)
        self.cuff = cuff

    # -- the parts --
    def palm(self, P):
        g = GLOVE_T
        d = None
        for f in FINGERS:
            a, b = np.asarray(CMC[f], float), np.asarray(MCP[f], float)
            r1 = 0.0085 + g
            r2 = RAD[f][0] * 1.06 + g
            # the head of the metacarpal stands a little to the back (the knuckle)
            e = sd_round_cone(P, a, b + np.array([0, -0.002, 0.0025]), r1, r2)
            d = e if d is None else smin(d, e, 0.009)
        # the carpus: a broad oval block at the wrist
        d = smin(d, sd_ellipsoid(P, (0.0010, 0.0150, -0.0045), (0.0265 + g, 0.0190 + g, 0.0125 + g)), 0.010)
        # the palm's flesh under the metacarpals
        d = smin(d, sd_ellipsoid(P, (0.0010, 0.0560, -0.0085), (0.0330 + g, 0.0350 + g, 0.0105 + g)), 0.008)
        # the pads under the knuckles (the distal palm), a ridge along the arch
        d = smin(d, sd_round_cone(P, (-0.0270, 0.0800, -0.0105), (0.0290, 0.0730, -0.0120), 0.0078 + g, 0.0072 + g), 0.006)
        # the hypothenar: the fleshy little-finger edge of the palm
        M = _frame_rows((1, 0, 0), (0.12, 1.0, 0.0))
        d = smin(d, sd_ellipsoid(P, (0.0250, 0.0420, -0.0100), (0.0115 + g, 0.0300 + g, 0.0105 + g), M), 0.008)
        # the thenar mass round the thumb's metacarpal
        t0 = self.thumb[0]
        mid = t0[0] * 0.55 + t0[1] * 0.45 + np.array([0.004, 0.0, -0.004])
        M = _frame_rows((0, 0, 1), t0[1] - t0[0])
        d = smin(d, sd_ellipsoid(P, mid, (0.0150 + g, 0.0270 + g, 0.0130 + g), M), 0.009)
        d = smin(d, sd_round_cone(P, t0[0], t0[1], t0[2], t0[3]), 0.008)
        # the wrist and the glove's gauntlet back along the forearm, flaring
        u = self.forearm
        w0 = np.array([0.0, 0.006, -0.001])
        M = _frame_rows((1, 0, 0), u)
        L = self.cuff
        # an elliptical tube that widens toward the cuff (as two cones)
        Q = (P - w0) @ M.T                   # local: x across, y along the forearm, z depth
        sx = np.interp(Q[:, 1], [0.0, L * 0.35, L], [1.0, 1.06, 1.38])
        Qs = Q.copy()
        Qs[:, 0] /= sx
        Qs[:, 2] /= sx * 0.80
        dc = sd_round_cone(Qs, np.zeros(3), np.array([0.0, L, 0.0]), 0.0300 + g, 0.0310 + g) * (0.5 + 0.5 * 0.8)
        d = smin(d, dc, 0.012)
        # the knuckle bar: a padded restraint across the back of the knuckles
        kb0 = np.asarray(MCP["index"], float) + np.array([-0.002, -0.0085, 0.0098])
        kb1 = np.asarray(MCP["little"], float) + np.array([0.001, -0.0080, 0.0088])
        kbm = np.asarray(MCP["middle"], float) + np.array([0.0, -0.0090, 0.0108])
        e = np.minimum(sd_round_cone(P, kb0, kbm, 0.0042, 0.0045), sd_round_cone(P, kbm, kb1, 0.0045, 0.0040))
        d = smin(d, e, 0.0035)
        return d

    def finger(self, P, f):
        segs = self.fingers[f]
        d = None
        for k, (a, b, r0, r1, dor, lat) in enumerate(segs):
            e = sd_flat_cone(P, a, b, r0, r1, dor, FLAT)
            d = e if d is None else smin(d, e, 0.0025)
            # the joint at the segment's base, a touch fuller and to the back
            if k >= 1:
                d = smin(d, sd_flat_cone(P, a + dor * r0 * 0.12, a + (b - a) * 0.08, r0 * 1.04, r0, dor, FLAT * 0.98), 0.002)
        # the fingertip's pad: fleshy under the last phalanx, flatter on top
        a, b, r0, r1, dor, lat = segs[2]
        ax = _n(b - a)
        c = a + (b - a) * 0.66 - dor * r1 * 0.28
        M = np.vstack([lat, ax, dor])
        d = smin(d, sd_ellipsoid(P, c, (r1 * 0.98, r1 * 1.30, r1 * 0.78), M), 0.0025)
        return d

    def thumb_d(self, P):
        d = None
        for k, (a, b, r0, r1, pad) in enumerate(self.thumb[1:]):
            e = sd_flat_cone(P, a, b, r0, r1, np.cross(pad, _n(b - a)) * 0 + pad, 0.90)
            d = e if d is None else smin(d, e, 0.0025)
        a, b, r0, r1, pad = self.thumb[2]
        ax = _n(b - a)
        c = a + (b - a) * 0.60 + pad * r1 * 0.30
        M = _frame_rows(np.cross(ax, pad), ax)
        d = smin(d, sd_ellipsoid(P, c, (r1 * 1.05, r1 * 1.35, r1 * 0.82), M), 0.0025)
        return d

    def creases(self, P):
        """How far each point sinks for the creases: across the palm side of
        each flexed finger joint, the glove folds in."""
        out = np.zeros(len(P))
        for f in FINGERS:
            segs = self.fingers[f]
            for k in range(1, 3):
                a, b, r0, r1, dor, lat = segs[k]
                pa, pb, pr0, pr1, pdor, plat = segs[k - 1]
                J = a
                A = _n(_n(b - a) + _n(pb - pa))
                pal = -_n(dor + pdor)
                Q = P - J
                s = Q @ A
                rad = Q - np.outer(s, A)
                rl = np.linalg.norm(rad, axis=1)
                dp = (rad @ pal) / np.maximum(rl, 1e-9)
                w = np.exp(-(s / 0.0020) ** 2) * np.clip(dp, 0, 1) ** 1.5 * np.exp(-((rl - r0) / 0.004) ** 2)
                out += 0.0011 * w
                # and a shallow fold over the back of the joint
                w2 = np.exp(-((s + 0.0030) / 0.0016) ** 2) * np.clip(-dp, 0, 1) ** 2 * np.exp(-((rl - r0) / 0.004) ** 2)
                out += 0.00045 * w2
        return out

    def parts(self, P):
        """Each part's distance: palm, the four fingers, the thumb."""
        pd = self.palm(P)
        out = {"palm": pd}
        for f in FINGERS:
            out[f] = smin(pd, self.finger(P, f), 0.0042)
        out["thumb"] = smin(pd, self.thumb_d(P), 0.0055)
        return out, pd

    def __call__(self, P):
        P = np.asarray(P, float).reshape(-1, 3)
        parts, _ = self.parts(P)
        d = np.min(np.vstack([parts[k] for k in ("index", "middle", "ring", "little", "thumb")]), axis=0)
        return d + self.creases(P)

    def grad(self, P, e=1e-4):
        P = np.asarray(P, float)
        g = np.zeros_like(P)
        for i in range(3):
            o = np.zeros(3)
            o[i] = e
            g[:, i] = (self(P + o) - self(P - o)) / (2 * e)
        return g

    # -- the grip material: a smooth field, > 0 where the glove is dark --
    def grip_field(self, P, N):
        g = GLOVE_T
        scores, ds = [], []
        # palm side of the palm: facing -Z, inside the palm's outline
        pd = self.palm(P)
        s_palm = (N @ np.array([0, 0, -1.0])) - 0.42
        s_palm = np.minimum(s_palm, (P[:, 1] - 0.020) * 60.0)     # not on the wrist and gauntlet
        s_palm = np.minimum(s_palm, (0.088 - P[:, 1]) * 120.0)
        scores.append(s_palm)
        ds.append(pd)
        for f in FINGERS:
            segs = self.fingers[f]
            for k, (a, b, r0, r1, dor, lat) in enumerate(segs):
                d = sd_flat_cone(P, a, b, r0, r1, dor, FLAT)
                s = (N @ -dor) - 0.30
                if k == 2:
                    # the rubber tip cap over the end of the finger
                    ax = _n(b - a)
                    h = ((P - a) @ ax) / max(float(np.linalg.norm(b - a)), 1e-9)
                    s = np.maximum(s, (h - 0.62) * 6.0 + (N @ -dor) * 0.4)
                scores.append(s)
                ds.append(d)
        for k, (a, b, r0, r1, pad) in enumerate(self.thumb):
            d = sd_round_cone(P, a, b, r0, r1)
            s = (N @ pad) - 0.45 if k else np.full(len(P), -0.6)
            if k == 2:
                ax = _n(b - a)
                h = ((P - a) @ ax) / max(float(np.linalg.norm(b - a)), 1e-9)
                s = np.maximum(s, (h - 0.58) * 6.0 + (N @ pad) * 0.4)
            scores.append(s)
            ds.append(d)
        D = np.vstack(ds)
        S = np.vstack(scores)
        W = np.exp(-(D - D.min(0)) / 0.0035)
        return (W * S).sum(0) / W.sum(0)


# ── meshing: surface nets on a grid, then Blender's decimation ─────────────

_EDGES = [((0, 0, 0), (1, 0, 0)), ((0, 1, 0), (1, 1, 0)), ((0, 0, 1), (1, 0, 1)), ((0, 1, 1), (1, 1, 1)),
          ((0, 0, 0), (0, 1, 0)), ((1, 0, 0), (1, 1, 0)), ((0, 0, 1), (0, 1, 1)), ((1, 0, 1), (1, 1, 1)),
          ((0, 0, 0), (0, 0, 1)), ((1, 0, 0), (1, 0, 1)), ((0, 1, 0), (0, 1, 1)), ((1, 1, 0), (1, 1, 1))]


def surface_nets(f, lo, hi, h):
    lo, hi = np.asarray(lo, float), np.asarray(hi, float)
    n = np.ceil((hi - lo) / h).astype(int) + 1
    xs = [lo[i] + np.arange(n[i]) * h for i in range(3)]
    G = np.stack(np.meshgrid(*xs, indexing="ij"), -1).reshape(-1, 3)
    D = np.empty(len(G))
    for s in range(0, len(G), 200000):
        D[s:s + 200000] = f(G[s:s + 200000])
    D = D.reshape(n)
    D[D == 0] = 1e-9
    inside = D < 0
    nc = n - 1
    acc = np.zeros(tuple(nc) + (3,))
    cnt = np.zeros(tuple(nc))
    for (a, b) in _EDGES:
        sa = tuple(slice(o, o + nc[i]) for i, o in enumerate(a))
        sb = tuple(slice(o, o + nc[i]) for i, o in enumerate(b))
        da, db = D[sa], D[sb]
        m = (da < 0) != (db < 0)
        t = np.where(m, da / np.where(m, da - db, 1.0), 0.0)
        for i in range(3):
            acc[..., i] += np.where(m, a[i] + t * (b[i] - a[i]), 0.0)
        cnt += m
    act = cnt > 0
    idx = -np.ones(tuple(nc), np.int64)
    idx[act] = np.arange(int(act.sum()))
    ijk = np.argwhere(act)
    V = lo + (ijk + acc[act] / cnt[act][:, None]) * h
    quads = []
    for ax in range(3):
        o1, o2 = [(1, 2), (0, 2), (0, 1)][ax]
        sl = [slice(0, n[0]), slice(0, n[1]), slice(0, n[2])]
        sl[ax] = slice(0, n[ax] - 1)
        s0 = inside[tuple(sl)]
        sl2 = list(sl)
        sl2[ax] = slice(1, n[ax])
        s1 = inside[tuple(sl2)]
        e = np.argwhere(s0 != s1)
        e = e[(e[:, o1] >= 1) & (e[:, o2] >= 1) & (e[:, o1] < n[o1] - 1) & (e[:, o2] < n[o2] - 1)]
        flip = s0[tuple(e.T)]
        c = []
        for d1, d2 in ((1, 1), (0, 1), (0, 0), (1, 0)):
            q = e.copy()
            q[:, o1] -= d1
            q[:, o2] -= d2
            c.append(idx[tuple(q.T)])
        Q = np.stack(c, 1)
        Q[flip] = Q[flip][:, ::-1]
        quads.append(Q)
    Q = np.vstack(quads)
    Q = Q[(Q >= 0).all(1)]
    # split along the shorter diagonal
    d02 = np.linalg.norm(V[Q[:, 0]] - V[Q[:, 2]], axis=1)
    d13 = np.linalg.norm(V[Q[:, 1]] - V[Q[:, 3]], axis=1)
    a = d02 <= d13
    T = np.vstack([np.where(a[:, None], Q[:, [0, 1, 2]], Q[:, [0, 1, 3]]),
                   np.where(a[:, None], Q[:, [0, 2, 3]], Q[:, [1, 2, 3]])])
    return V, T


def project(f, V, iters=3):
    for _ in range(iters):
        d = f(V)
        g = f.grad(V)
        gl = np.einsum("ij,ij->i", g, g)
        V = V - (d / np.maximum(gl, 1e-12))[:, None] * g
    return V


_BL_DECIMATE = r'''
import sys, bpy, bmesh, numpy as np
src, dst, ratio = sys.argv[-3], sys.argv[-2], float(sys.argv[-1])
z = np.load(src)
V, T = z["V"], z["T"]
me = bpy.data.meshes.new("h")
me.from_pydata(V.tolist(), [], T.tolist())
me.validate()
ob = bpy.data.objects.new("h", me)
bpy.context.scene.collection.objects.link(ob)
bpy.context.view_layer.objects.active = ob
bm = bmesh.new(); bm.from_mesh(me)
bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-6)
bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
bm.to_mesh(me); bm.free()
mod = ob.modifiers.new("d", "DECIMATE")
mod.decimate_type = "COLLAPSE"
mod.ratio = ratio
mod.use_collapse_triangulate = True
dg = bpy.context.evaluated_depsgraph_get()
ev = ob.evaluated_get(dg)
m2 = ev.to_mesh()
m2.calc_loop_triangles()
V2 = np.array([v.co[:] for v in m2.vertices])
T2 = np.array([t.vertices[:] for t in m2.loop_triangles])
np.savez(dst, V=V2, T=T2)
'''


def decimate(V, T, tris):
    if len(T) <= tris:
        return V, T
    with tempfile.TemporaryDirectory() as d:
        src, dst, scr = os.path.join(d, "in.npz"), os.path.join(d, "out.npz"), os.path.join(d, "dec.py")
        np.savez(src, V=V, T=T)
        open(scr, "w").write(_BL_DECIMATE)
        r = subprocess.run([BLENDER, "--background", "--factory-startup", "--python", scr, "--", src, dst,
                            str(tris / len(T))], capture_output=True, text=True)
        if r.returncode != 0 or not os.path.exists(dst):
            raise RuntimeError("blender decimate failed:\n" + r.stdout[-2000:] + r.stderr[-2000:])
        z = np.load(dst)
        return z["V"], z["T"].astype(np.int64)


def split_by(V, T, s):
    """Cut the triangles along the zero line of the per-vertex scalar s:
    returns V', s', and the triangles of each side (s < 0, s >= 0)."""
    s = np.where(np.abs(s) < 1e-6, 1e-6, s)
    V = list(V)
    s = list(s)
    cache = {}

    def cut(i, j):
        key = (min(i, j), max(i, j))
        if key not in cache:
            t = s[i] / (s[i] - s[j])
            V.append(V[i] + (V[j] - V[i]) * t)
            s.append(0.0)
            cache[key] = len(V) - 1
        return cache[key]

    neg, pos = [], []
    for tri in T:
        sg = [s[k] >= 0 for k in tri]
        if all(sg):
            pos.append(tri)
            continue
        if not any(sg):
            neg.append(tri)
            continue
        # rotate so the lone vertex is first
        lone = [k for k in range(3) if sum(sg) == 1 and sg[k] or sum(sg) == 2 and not sg[k]][0]
        a, b, c = tri[lone], tri[(lone + 1) % 3], tri[(lone + 2) % 3]
        ab, ac = cut(a, b), cut(a, c)
        side_lone, side_other = (pos, neg) if s[a] >= 0 else (neg, pos)
        side_lone.append((a, ab, ac))
        side_other.append((ab, b, c))
        side_other.append((ab, c, ac))
    return np.asarray(V), np.asarray(s), np.asarray(neg, np.int64).reshape(-1, 3), np.asarray(pos, np.int64).reshape(-1, 3)


def box_uv(P, N, uv_m=4.0):
    ax = np.argmax(np.abs(N), axis=1)
    U = np.where(ax == 0, P[:, 1], P[:, 0])
    W = np.where(ax == 2, P[:, 1], P[:, 2])
    return np.stack([U * uv_m, -W * uv_m], 1)


def mesh_hand(field, tris=4200, h=0.0013):
    """The field as triangles: (V, T, N, grip score) in the hand's frame."""
    pts = [np.asarray(MCP[f]) for f in FINGERS]
    for f in FINGERS:
        for a, b, *_ in field.fingers[f]:
            pts += [a, b]
    for a, b, *_ in field.thumb:
        pts += [a, b]
    pts.append(np.array([0.0, 0.006, 0.0]) + field.forearm * field.cuff)
    pts.append(np.array([0.0, 0.0, 0.0]))
    pts = np.array(pts)
    lo = pts.min(0) - 0.05
    hi = pts.max(0) + 0.05
    V, T = surface_nets(field, lo, hi, h)
    V, T = decimate(V, T, tris)
    V = project(field, V, 2)
    N = field.grad(V)
    N /= np.maximum(np.linalg.norm(N, axis=1, keepdims=True), 1e-12)
    # the cuff end is open (the bearing covers it): drop what lies past it
    s = field.grip_field(V, N)
    return V, T, N, s


# ── placing a hand ─────────────────────────────────────────────────────────

# A power grip's bar in the hand frame (right hand): across the palm at the
# distal crease, running from the hypothenar up to the index knuckle, its axis
# a bar's radius under the palm's skin.
GRIP_Q = np.array([-0.002, 0.0715, -0.0200])
GRIP_U = _n((-0.92, 0.36, 0.0))          # toward the thumb / index side


def frame(R, t):
    M = np.eye(4)
    M[:3, :3] = R
    M[:3, 3] = t
    return M


def on_cylinder(c, u, dorsal, r, side="R", slide=0.0, q=None, roll=0.0, forearm=None):
    """The hand frame → model matrix that lays a power grip's palm on a
    cylinder: axis through c along u (u points to where the thumb and index
    are, up a pistol grip), radius r, the back of the hand toward `dorsal`.
    slide moves the hand along the bar; roll turns it round the bar.
    forearm (a direction from the wrist toward the elbow): instead of
    `dorsal`, turn the hand round the bar until its own line points that way
    as nearly as it can, so the wrist stays straight."""
    if forearm is not None:
        best, bd = None, -2.0
        u_ = _n(u)
        a = np.cross(u_, (0.0, 0.0, 1.0) if abs(u_[2]) < 0.9 else (1.0, 0.0, 0.0))
        for k in range(360):
            dl = _rot(u_, math.radians(k)) @ _n(a)
            M = on_cylinder(c, u_, dl, r, side, slide, q, 0.0)
            back = -M[:3, 1]
            d = float(back @ _n(forearm))
            if d > bd:
                best, bd = dl, d
        dorsal = best
    Q = (GRIP_Q if q is None else np.asarray(q, float)).copy()
    Q[2] -= r
    Uh = GRIP_U.copy()
    if side == "L":
        Q[0] = -Q[0]
        Uh[0] = -Uh[0]
    u = _n(u)
    dl = _n(np.asarray(dorsal, float) - u * (u @ np.asarray(dorsal, float)))
    dl = _rot(u, roll) @ dl
    Zh = np.array([0.0, 0.0, 1.0])
    Zh = _n(Zh - Uh * (Uh @ Zh))
    Fh = np.stack([Uh, Zh, np.cross(Uh, Zh)], 1)
    Fw = np.stack([u, dl, np.cross(u, dl)], 1)
    R = Fw @ Fh.T
    t = np.asarray(c, float) + u * slide - R @ Q
    return frame(R, t)


def wrap(pose, M, c, u, r, side="R", fingers=FINGERS, gap=0.0, limits=(1.62, 1.85, 1.35), extra=0.0, thumb=False):
    """Close each finger round the cylinder (axis through c along u, radius r,
    in the model's frame) the way a hand closes on a bar: each joint in turn
    bends until the next joint touches. Returns the pose (changed in place)."""
    Mi = np.linalg.inv(M)
    ch = Mi[:3, :3] @ np.asarray(c, float) + Mi[:3, 3]
    uh = _n(Mi[:3, :3] @ np.asarray(u, float))
    if side == "L":
        ch[0], uh[0] = -ch[0], -uh[0]

    def dist(p):
        v = p - ch
        return float(np.linalg.norm(v - uh * (v @ uh)))

    for f in fingers:
        ang = pose.fingers[f]
        for j in range(3):
            target = r + RAD[f][j + 1] + GLOVE_T + gap

            def end(th):
                a = list(ang)
                a[1 + j] = th
                segs = finger_chain(f, a)
                return segs[j][1]

            best, found = 0.0, None
            prev = dist(end(0.0))
            for th in np.linspace(0.0, limits[j], 90):
                dd = dist(end(th))
                if dd <= target and found is None:
                    found = th
                    break
                if dd < prev:
                    best = th
                prev = dd
            th = found if found is not None else best
            if found is not None and th > 0:
                lo_, hi_ = max(0.0, th - limits[j] / 89), th
                for _ in range(20):
                    mid = 0.5 * (lo_ + hi_)
                    if dist(end(mid)) <= target:
                        hi_ = mid
                    else:
                        lo_ = mid
                th = hi_
            ang[1 + j] = th + (extra if j == 2 else 0.0)
    if thumb:
        # the thumb closes the same way over the other side of the bar
        t = pose.thumb
        for j, key in ((1, "mcp"), (2, "ip")):
            target = r + (THUMB_RAD[2] if j == 1 else THUMB_RAD[4]) + GLOVE_T + gap

            def tend(th):
                tt = dict(t)
                tt[key] = th
                return thumb_chain(tt)[j][1]

            found = None
            best, bd = 0.0, 1e9
            for th in np.linspace(-0.2, 1.4, 81):
                dd = dist(tend(th))
                if dd < bd:
                    best, bd = th, dd
                if dd <= target and th >= 0:
                    found = th
                    break
            t[key] = float(found if found is not None else best)
    return pose


def _apply(M, side, V, N):
    if side == "L":
        V = V * np.array([-1.0, 1.0, 1.0])
        N = N * np.array([-1.0, 1.0, 1.0])
    V2 = V @ M[:3, :3].T + M[:3, 3]
    N2 = N @ M[:3, :3].T
    return V2, N2


_CACHE = {}


def _ring_loft(m, mat, c0, u, prof_t, rad, segs, ref=None, tile=0.25):
    """A tube along u from c0 through stations prof_t (metres along u), each
    ring's radius rad(t, a) (a the angle round it), smooth normals from the
    surface itself, UVs in `tile`-metre tiles (u round, v along)."""
    u = _n(u)
    if ref is None:
        ref = np.array([0.0, 0.0, 1.0]) if abs(u[2]) < 0.9 else np.array([1.0, 0.0, 0.0])
    e1 = _n(ref - u * (ref @ u))
    e2 = np.cross(u, e1)
    T = np.asarray(prof_t, float)
    A = np.linspace(0, 2 * math.pi, segs + 1)
    R = np.array([[rad(t, a) for a in A] for t in T])
    P = (c0[None, None, :] + T[:, None, None] * u[None, None, :]
         + R[..., None] * (np.cos(A)[None, :, None] * e1 + np.sin(A)[None, :, None] * e2))
    dt = np.gradient(P, axis=0)
    da = np.gradient(P, axis=1)
    da[:, 0] = da[:, -1] = (P[:, 1] - P[:, -2]) * 0.5
    N = np.cross(da, dt)
    out = P - (c0[None, None, :] + T[:, None, None] * u[None, None, :])
    flip = (N * out).sum(-1) < 0
    N[flip] *= -1
    N /= np.maximum(np.linalg.norm(N, axis=-1, keepdims=True), 1e-12)
    circ = 2 * math.pi * float(R.mean())
    UV = np.stack(np.meshgrid(A / (2 * math.pi) * max(1, round(circ / tile)), T / tile), -1)
    nt, na = len(T), segs + 1
    I = []
    for i in range(nt - 1):
        for j in range(segs):
            a, b, c, d = i * na + j, i * na + j + 1, (i + 1) * na + j + 1, (i + 1) * na + j
            I += [(a, b, c), (a, c, d)]
    m.add(mat, P.reshape(-1, 3), N.reshape(-1, 3), UV.reshape(-1, 2), np.array(I))


def _wnoise(t, a, seed):
    """A cheap smooth noise of the station and the angle (both periodic in a)."""
    return (0.5 * math.sin(3 * a + seed + 7.1 * t) + 0.3 * math.sin(5 * a - 1.3 * seed + 13.7 * t)
            + 0.2 * math.sin(2 * a + 2.1 * seed - 23.0 * t))


def wrist_bearing(m, b0, u_m, side):
    """The wrist disconnect as the third-person suit has it (gen_suit_blender
    ring_piece): two anodised races with chamfered edges, a sunk groove
    between, the outer race coloured by side (blue left, red right), and the
    bore's lip rolled toward the glove."""
    from gen_part_meshes import lathe, frame_to
    ri, ro, w = 0.041, 0.0505, 0.026
    cw, g, gw = 0.0022, 0.0016, 0.0018
    sub = Model()
    lathe(sub, "SuitMetal", [(ri - 0.0015, cw), (ri + cw, 0.0), (ro - cw, 0.0), (ro, cw), (ro, w / 2 - gw),
                             (ro - g, w / 2 - gw * 0.4)], segs=40, uv_m=4.0)
    lathe(sub, "WristBlue" if side == "L" else "WristRed",
          [(ro - g, w / 2 - gw * 0.4), (ro, w / 2 + gw), (ro, w - cw), (ro - cw, w)], segs=40, uv_m=4.0)
    lathe(sub, "SuitMetal", [(ro - cw, w), (ri + cw, w), (ri - 0.0015, w - cw)], segs=40, uv_m=4.0)
    m.merge(sub, frame_to(u_m), b0)
    return b0 + u_m * w


def folded_sleeve(m, start, elbow, u_m, side):
    """The suit's sleeve from the wrist disconnect back past the elbow, as the
    third-person suit's (gen_suit_blender arm_disp): bunched in rings above
    the disconnect, long shallow diagonals down the forearm, never quite
    round; then on toward the shoulder, out of the view's frame."""
    e = np.asarray(elbow, float)
    L = float(np.linalg.norm(e - start))
    sd = 1.7 if side == "L" else 4.3

    def rad(t, a):
        base = 0.0445 + (0.060 - 0.0445) * min(1.0, t / L) ** 1.3
        bun = max(0.0, 1.0 - t / 0.11) ** 0.8 * min(1.0, t / 0.012)
        r = base + 0.0034 * bun * math.sin(2 * math.pi * t / 0.019 + 1.6 * _wnoise(t, a, sd))
        dr = math.sin(2 * math.pi * t / 0.085 + 1.6 * a + 2.0 * _wnoise(t, a, sd + 1))
        r += 0.0022 * (math.copysign(abs(dr) ** 1.6, dr)) * min(1.0, t / 0.06)
        r += 0.0012 * _wnoise(t * 0.5, a, sd + 2)
        return r
    ts = list(np.arange(0.0, 0.12, 0.0035)) + list(np.arange(0.12, L + 0.01, 0.008))
    _ring_loft(m, "Suit", start, u_m, ts, rad, 32)
    # on past the elbow toward the shoulder (plain: out of frame)
    tube(m, "Suit", e - u_m * 0.01, e + u_m * 0.40, 0.060, segs=18, r1=0.066)


def wrist_of(M):
    """The wrist's point in the model's frame for a hand placed by M."""
    return M[:3, :3] @ np.array([0.0, 0.006, -0.001]) + M[:3, 3]


def glove(m, M, pose, side="R", elbow=None, tris=4200, sleeve=True, cuff=0.050, bearing=True):
    """Add a gloved hand (and its wrist bearing and sleeve to `elbow`) to the
    Model m: M the hand frame → model matrix (on_cylinder), pose its joints.
    Materials: "Glove" (the cloth), "Palm" (the dark grip), and for the
    bearing and sleeve "SuitMetal", "WristBlue" / "WristRed", "Suit". Returns
    the wrist point."""
    wrist_m = M[:3, :3] @ np.array([0.0, 0.006, -0.001]) + M[:3, 3]
    if isinstance(elbow, (int, float)):
        # the elbow a forearm's length down the hand's own line, the wrist in
        # its natural set on a grip: a little ulnar deviation and extension
        dh = _n((0.17 if side == "R" else -0.17, -1.0, 0.10))
        elbow = wrist_m + (M[:3, :3] @ dh) * float(elbow)
    if elbow is not None:
        u_m = _n(np.asarray(elbow, float) - wrist_m)
    else:
        u_m = M[:3, :3] @ np.array([0.0, -1.0, 0.0])
    u_h = M[:3, :3].T @ u_m
    if side == "L":
        u_h = u_h * np.array([-1.0, 1.0, 1.0])
    u_h = _n(u_h)
    if os.environ.get("FP_HANDS_DEBUG"):
        print(f"fp_hands: {side} wrist bend {math.degrees(math.acos(max(-1.0, min(1.0, -u_h[1])))):.0f} deg,"
              f" forearm (hand frame) {np.round(u_h, 2).tolist()}")
    key = json.dumps([pose.fingers, pose.thumb, np.round(u_h, 4).tolist(), cuff, tris], sort_keys=True)
    if key not in _CACHE:
        field = HandField(pose, forearm=u_h, cuff=cuff)
        _CACHE[key] = mesh_hand(field, tris)
    V, T, N, s = _CACHE[key]
    V, s2, Tn, Tp = split_by(V, T, s)
    # the new cut vertices take their neighbours' normal from the field again
    if len(V) > len(N):
        field = HandField(pose, forearm=u_h, cuff=cuff)
        extra = field.grad(V[len(N):])
        extra /= np.maximum(np.linalg.norm(extra, axis=1, keepdims=True), 1e-12)
        N = np.vstack([N, extra])
    V2, N2 = _apply(M, side, V, N)
    # cut away what lies past the cuff's end (the bearing sits there)
    cut_c = wrist_m + u_m * cuff
    for mat, TT in (("Glove", Tn), ("Palm", Tp)):
        if not len(TT):
            continue
        keep = ((V2[TT].mean(1) - cut_c) @ u_m) < 0.0
        TT = TT[keep]
        P = V2[TT].reshape(-1, 3)
        Nn = N2[TT].reshape(-1, 3)
        fn = np.cross(V2[TT[:, 1]] - V2[TT[:, 0]], V2[TT[:, 2]] - V2[TT[:, 0]])
        UV = box_uv(P, np.repeat(fn, 3, axis=0))
        m.add(mat, P, Nn, UV, np.arange(len(P)).reshape(-1, 3))
    if bearing:
        # the wrist disconnect (the suit's: two races, the outer one blue on
        # the left, red on the right), then the suit's folded sleeve back past
        # the elbow (2026-11-09: the third-person suit's revamp)
        b0 = cut_c - u_m * 0.004
        top = wrist_bearing(m, b0, u_m, side)
        if sleeve and elbow is not None:
            folded_sleeve(m, top - u_m * 0.006, elbow, u_m, side)
    return wrist_m


def stats(m):
    return {k: sum(len(i) for i in v[3]) for k, v in m.parts.items()}
