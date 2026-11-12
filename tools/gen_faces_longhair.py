#!/usr/bin/env python3
"""LONG HAIR: rigged hair-card styles that swing on spring bones (engine 0693).

    python3 tools/gen_faces_longhair.py           # models + texture
    python3 tools/gen_faces_longhair.py --dry     # print the budget, write nothing
    python3 tools/gen_faces_longhair.py --tex     # the texture only

Writes
    models/astronaut/faces/hair_<style>.glb   six long styles, rigged (bones below)
    textures/faces/hair_long.png              the long cards' strands, grey, alpha-cut (1024²)

The short styles (tools/gen_faces_hair.py) are static shells on the head;
these hang. Each is hundreds of hair cards (alpha-cut strips of strands)
grown from the scalp inside the hairline, laid along the style's combing to
where the hair leaves the head (the RELEASE: the temples, over the ears, the
occiput; or a tie), and from there along GUIDES: 24 chains of bones that the
engine's spring bones swing (the node's `spring_bones`, tools/gen_faces.py
face_nodes writes it, the same for every style). A card between two guides
is skinned to both by how near it is to each, and along each by its bones,
so the sheet bends as one and never tears.

The guides' rest shape is the hair's own drape: each is dropped from its
release under gravity against the same colliders the engine keeps it out of
(the head, the neck, the suit's collar ring, the neck dam, the shoulders and
the life-support pack), with a bending stiffness, until it settles. So the
spring bones start at rest where the model is drawn.

THE RIG (every long style has every bone; one spring spec fits them all):
    HairRoot (the head's centre)
      ├ HairBody     the body's colliders ride it (the ring, shoulders, pack)
      └ Snn_0 ─ Snn_1 ─ … ─ Snn_k   nn = 00..23: the chains, root at the release
A style that needs fewer chains (a ponytail, a braid) keeps the rest as
stubs: two bones a centimetre apart that nothing is skinned to.

STYLES
    long      long and straight, a centre parting, to below the shoulders
    wavy      long, loose waves, a side parting
    shoulder  a shoulder-length cut, a side parting
    lowtail   pulled back to a low ponytail
    braid     pulled back into one plait down the back
    halfup    the top gathered to a small knot at the crown, the rest down

THE TEXTURE (self-made, CC0): 8 columns of 128 px; v runs root → tip.
Columns 0–4 clumps of strands (different densities and waves), 5 fine
flyaways, 6 a braid's lobe, 7 the solid under-layer. The strands are grey:
face.lua tints the material (the person's colour, grey with age). (A normal
map rounding each strand was tried: on cards its highlight read as a grey
plastic sheen, so the material is rough and plain, like the short hair's.)

Vertex colour (the material multiplies it): the inner layers and the roots
darker (the light does not get in), alpha thinning the tips.

Licence: everything here new, CC0.
"""
import math
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_faces as GF  # noqa: E402
import gen_faces_hair as GH  # noqa: E402

HC = GF.HC
unit = GF.unit
smooth = GF.smooth
MODELS = GF.MODELS
TEXDIR = GF.TEXDIR
ATLAS = 8                  # columns
FINE, LOBE, SOLID = 5, 6, 7
NCH = 24                   # chains in every style
BODY_PIVOT = np.array([0.0, -0.150, -0.020])   # the suit's Head bone, head-local (the neck's pivot)
BOX = np.array([0.42, 0.62, 0.48])             # the anchor box about HC (wider than the face's: the hair hangs)
COPYRIGHT = "Solar crew long hair (tools/gen_faces_longhair.py), CC0."

# ── colliders (head-local metres; x the crew's left, y up, z forward) ───────
# (bone, centre, radius, capsule end or None). The spring spec in the prefab
# is written from this list (springs_file, one .springs.ron per model), so the drape here and the engine's
# swing use the same shapes.
HIT = 0.016                # the chains' own thickness against them


def _ring():
    out = []
    # the collar ring, fat enough to close the gap to the neck (hair rests
    # on it, never slips down inside it)
    c, R = np.array([0.0, -0.135, -0.028]), 0.128
    for k in range(6):
        a0, a1 = k / 6 * 2 * np.pi, (k + 1) / 6 * 2 * np.pi
        p0 = c + R * np.array([math.sin(a0), 0, math.cos(a0)])
        p1 = c + R * np.array([math.sin(a1), 0, math.cos(a1)])
        out.append(("HairBody", p0, 0.050, p1))
    return out


COLLIDERS = [
    ("HairRoot", np.array([0.0, 0.030, -0.020]), 0.088, None),      # the cranium
    ("HairRoot", np.array([0.0, -0.030, -0.035]), 0.070, None),     # the back of the skull, the nape
    ("HairRoot", np.array([0.0, -0.068, 0.028]), 0.058, None),      # the jaw
    ("HairRoot", np.array([0.0, -0.070, -0.030]), 0.054, np.array([0.0, -0.180, -0.025])),   # the neck
] + _ring() + [
    ("HairBody", np.array([0.0, -0.322, -0.025]), 0.205, None),     # the neck dam and the chest under it
    # the shoulders, sloping from the collar down to the arm (no dome to flare over)
    ("HairBody", np.array([0.105, -0.160, -0.050]), 0.055, np.array([0.255, -0.205, -0.055])),
    ("HairBody", np.array([-0.105, -0.160, -0.050]), 0.055, np.array([-0.255, -0.205, -0.055])),
    # the upper arms, hanging (idle; a swing forward still meets the hair)
    ("HairBody", np.array([0.215, -0.250, -0.060]), 0.065, np.array([0.235, -0.480, -0.050])),
    ("HairBody", np.array([-0.215, -0.250, -0.060]), 0.065, np.array([-0.235, -0.480, -0.050])),
    ("HairBody", np.array([-0.16, -0.256, -0.262]), 0.150, np.array([0.16, -0.256, -0.262])),   # the pack: top, back
    ("HairBody", np.array([-0.16, -0.430, -0.290]), 0.100, np.array([0.16, -0.430, -0.290])),   # its lower back
]

# the chains' spring (one spec for every style)
SPRING = dict(stiffness=2.6, gravity=1.0, drag=0.35, max_angle=45.0, hit_radius=HIT, root_stiffness=0.6)


def push_out(p, a, b, r):
    if b is None:
        d = p - a
        n = np.linalg.norm(d)
        return p if n >= r else a + (d / max(n, 1e-9)) * r
    ab = b - a
    t = np.clip(np.dot(p - a, ab) / np.dot(ab, ab), 0, 1)
    q = a + ab * t
    d = p - q
    n = np.linalg.norm(d)
    return p if n >= r else q + (d / max(n, 1e-9)) * r


_CA = np.array([c[1] for c in COLLIDERS])
_CB = np.array([c[1] if c[3] is None else c[3] for c in COLLIDERS])
_CR = np.array([c[2] for c in COLLIDERS])
_AB = _CB - _CA
_ABL = np.maximum((_AB * _AB).sum(1), 1e-12)


def collide(p, extra=0.0):
    """p pushed out of every collider (grown by the chains' thickness)."""
    t = np.clip(((p - _CA) * _AB).sum(1) / _ABL, 0, 1)
    d = np.linalg.norm(p - (_CA + _AB * t[:, None]), axis=1)
    hit = np.nonzero(d < _CR + HIT + extra)[0]
    for i in hit:
        _, a, r, b = COLLIDERS[i]
        p = push_out(p, a, b, r + HIT + extra)
    return p


def inside_any(p, margin=0.0):
    for _, a, r, b in COLLIDERS:
        if np.linalg.norm(push_out(p, a, b, r + margin) - p) > 1e-9:
            return True
    return False


# ── the drape ───────────────────────────────────────────────────────────────
def drape(root, dirs, L, bend=0.35, iters=700, g=9.81):
    """A chain of len(dirs) segments of length L from `root`, its design
    shape the segment directions `dirs`, dropped under gravity against the
    colliders with a bending stiffness toward the design (each segment pulled
    toward its parent's direction turned by the design's turn there). The
    rest positions, (n+1, 3)."""
    n = len(dirs)
    dirs = [unit(d) for d in dirs]
    P = [np.asarray(root, float)]
    for d in dirs:
        P.append(P[-1] + d * L)
    P = np.array(P)
    prev = P.copy()
    h = 1.0 / 120
    keep = 0.93
    for it in range(iters):
        V = (P - prev) * keep
        prev = P.copy()
        P[1:] += V[1:] + np.array([0.0, -g, 0.0]) * h * h
        for _ in range(2):
            par_dir = dirs[0]
            for i in range(1, n + 1):
                # the design's turn from the parent to this segment, applied to
                # the parent's solved direction (bending stiffness)
                if i == 1:
                    want = dirs[0]
                else:
                    sol = unit(P[i - 1] - P[i - 2])
                    q = _arc(dirs[i - 2], sol)
                    want = q @ dirs[i - 1]
                d = P[i] - P[i - 1]
                d = unit(d) * L
                tgt = P[i - 1] + want * L
                k = bend * (1.6 if i == 1 else 1.0)
                P[i] = P[i - 1] + unit(d * (1 - k) + (tgt - P[i - 1]) * k) * L
                P[i] = collide(P[i])
                P[i] = P[i - 1] + unit(P[i] - P[i - 1]) * L
                del par_dir
                par_dir = None
    return P


def _arc(a, b):
    """The rotation matrix turning unit a onto unit b."""
    a, b = unit(a), unit(b)
    v = np.cross(a, b)
    c = float(np.dot(a, b))
    if c < -0.9999:
        return -np.eye(3)
    K = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    return np.eye(3) + K + K @ K / (1 + c)


def resample(P, n):
    """Polyline P at n+1 points evenly by arc length."""
    d = np.r_[0, np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))]
    t = np.linspace(0, d[-1], n + 1)
    return np.stack([np.interp(t, d, P[:, k]) for k in range(3)], -1)


def along(P, s):
    """The point and tangent at arc length s along polyline P (clamped,
    extrapolated past the end along the last segment)."""
    d = np.r_[0, np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))]
    if s >= d[-1]:
        t = unit(P[-1] - P[-2])
        return P[-1] + t * (s - d[-1]), t
    i = int(np.searchsorted(d, s, side="right") - 1)
    i = max(0, min(i, len(P) - 2))
    f = (s - d[i]) / max(d[i + 1] - d[i], 1e-9)
    return P[i] + (P[i + 1] - P[i]) * f, unit(P[i + 1] - P[i])


# ── the scalp ───────────────────────────────────────────────────────────────
def scalp_pt(phi, th, lift):
    return GH.on_scalp(np.array(phi), np.array(th), lift)


def scalp_n(phi, th):
    return unit(scalp_pt(phi, th, 0.0) - GH.O)


def hairline_th(phi):
    return float(GH.hairline_edge(np.array(phi)))


def release_th(aphi):
    """θ where hanging hair leaves the head at |φ| (temples, over the ear, the occiput)."""
    return float(np.interp(aphi, [1.0, 1.25, 1.6, 2.0, 2.5, np.pi], [0.40, 0.24, 0.06, -0.06, -0.20, -0.28]))


def chain_phis(amax=np.pi):
    """The 24 chains' azimuths: 12 down each side, from the temple to `amax` (the back)."""
    a = [1.05 + (amax - 1.05) * (i + 0.5) / 12 for i in range(12)]
    return [x for x in a] + [-x for x in a]


# ── styles ──────────────────────────────────────────────────────────────────
# hang: free length of a chain (m), segs: bones; part: "centre" | "side";
# wave: amplitude of the waves at the tips (m); cards: how many; thick: the
# hair's depth (m); tips: the spread of the ends (share of the length)
LONG = {
    "long":     dict(kind="hang", part="centre", hang=0.42, segs=6, wave=0.0, cards=1000, thick=0.020, tips=0.20,
                     line="normal", front=0.8, amax=2.5, crown=240),
    "wavy":     dict(kind="hang", part="side", hang=0.38, segs=6, wave=0.010, cards=1000, thick=0.017, tips=0.22,
                     line="normal", front=0.35, amax=2.5, crown=220),
    "shoulder": dict(kind="hang", part="side", hang=0.17, segs=4, wave=0.0, cards=640, thick=0.020, tips=0.08,
                     line="normal", front=0.3, crown=180),
    # a low ponytail and a plait, tied at the nape on the left and worn
    # forward over the shoulder
    "lowtail":  dict(kind="tail", tie_at=(2.25, -0.34), hang=0.34, segs=6, cards=520, line="low"),
    "braid":    dict(kind="braid", tie_at=(2.25, -0.34), hang=0.38, segs=8, cards=480, line="low"),
    "halfup":   dict(kind="hang", part="centre", hang=0.40, segs=6, wave=0.006, cards=900, thick=0.018, tips=0.18,
                     line="normal", front=0.4, knot=(0.0, 0.050, -0.112), amax=2.5),
}


def tie_point(st):
    """A tail's tie, off the scalp at (φ, θ)."""
    if "tie" in st:
        return np.asarray(st["tie"], float)
    ph, th = st["tie_at"]
    return scalp_pt(ph, th, 0.012)


def design_dirs(phi, th, n, front=0.5, out=0.0):
    """A hanging strand's design shape from its release: down the head's
    side, turning to fall, a little forward at the temples."""
    nrm = scalp_n(phi, th)
    down = np.array([0.0, -1.0, 0.0])
    tang = unit(down - nrm * np.dot(down, nrm))
    dirs = []
    for i in range(n):
        u = i / max(n - 1, 1)
        d = unit(tang * (1 - u) + down * u + nrm * (0.25 + out) * (1 - u))
        # front locks fall a little forward, over the collarbone
        if abs(phi) < 1.5:
            d = unit(d + np.array([0, 0, 0.35 * front]) * u)
        dirs.append(d)
    return dirs


def walk(root, d0, length, pref, inertia=0.55, step=0.008, wpref=0.45):
    """A lock laid from `root`: each small step goes the way it was going,
    bent toward down (and `pref`, the side it falls to: back over the pack,
    forward over the collarbone), and any step into a collider slides out
    along it. The hair's drape against the suit without a simulation that
    lets it slip between shapes. (polyline)"""
    P = [np.asarray(root, float)]
    d = unit(d0)
    down = np.array([0.0, -1.0, 0.0])
    n = int(math.ceil(length / step))
    for i in range(n):
        # up at the suit's shoulders and the pack's top the lock is pushed
        # hard its way (over the pack, off the collarbone); below, it hangs
        y = P[-1][1]
        wp = wpref * (1 + 2.2 * smooth(-0.17, -0.11, y))
        want = unit(down + np.asarray(pref) * wp)
        # stiffer near the root: hair leaves the head the way it grew
        k = inertia + (0.93 - inertia) * (1 - smooth(0.0, 0.07, i * step))
        d = unit(d * k + want * (1 - k))
        q = P[-1] + d * step
        for _ in range(4):
            q = collide(q)
            q = P[-1] + unit(q - P[-1]) * step
        d = unit(q - P[-1])
        P.append(q)
    return np.array(P)


def hang_pref(phi, front):
    """Which way a lock at azimuth φ falls once it reaches the suit: long
    hair is worn forward, over the shoulders (behind is the life-support
    pack, and hair lying across its top reads as a shelf); a short cut
    rests on the collar ring all round."""
    a = abs(phi)
    s = 1.0 if phi > 0 else -1.0
    if a < 1.0 + 0.45 * front:
        return np.array([s * 0.06, 0.0, 0.30])          # forward, over the collarbone
    if a <= 2.6:
        return np.array([s * 0.07, 0.0, 0.60])          # over the shoulder, to the front
    return np.array([s * 0.12 * (np.pi - a), 0.0, -1.0])   # (a short cut) back onto the collar


class Guide:
    """A chain: its bones (`B`, segs+1 points, each `L` apart along the
    lock) and the lock's fine path (`F`, the drape the cards follow).
    `settle` lets the engine's own spring solver hang it first, so what is
    drawn at rest is what the engine holds at rest."""

    def __init__(self, F, segs, L, settle_it=True):
        self.F = np.asarray(F, float)
        self.L = L
        self.segs = segs
        self.B = np.array([along(self.F, j * L)[0] for j in range(segs + 1)])
        self.residual = 0.0
        if settle_it and segs > 1:
            self.B, self.residual = settle(self.B)
            self.F = fine_path(self.B)

    def __len__(self):
        return len(self.B)


# ── the engine's spring solver, ported (floptle-anim/src/spring.rs) ─────────
SPRING_STEP = 1.0 / 120


def spring_rest(B, secs=3.0, g=np.array([0.0, -9.81, 0.0])):
    """Where the engine's solver brings chain B (bones at rest, identity
    rotations) with the node still: the particles after `secs`."""
    p = SPRING
    k = (2 * np.pi * p["stiffness"]) ** 2
    keep = (1 - p["drag"]) ** (SPRING_STEP * 60)
    mx = math.radians(p["max_angle"])
    n = len(B) - 1
    rest_dir = [unit(B[i + 1] - B[i]) for i in range(n)]
    ln = [np.linalg.norm(B[i + 1] - B[i]) for i in range(n)]
    tips = [B[i + 1].copy() for i in range(n)]
    prev = [t.copy() for t in tips]
    h = SPRING_STEP
    for _ in range(int(secs / h)):
        R = np.eye(3)
        head = B[0].copy()
        for i in range(n):
            a = R @ rest_dir[i]
            # engine 0700: the aim blends from the parent's swung position
            # toward the tip's own animated place measured from the root
            aim = head + a * ln[i]
            rs = p.get("root_stiffness", 0.0)
            if rs > 0:
                aim = aim + (head + unit(B[i + 1] - head) * ln[i] - aim) * rs
            pull = (aim - tips[i]) * k + g * p["gravity"]
            nxt = tips[i] + (tips[i] - prev[i]) * keep + pull * h * h
            nxt = _constrain(head, nxt, a, ln[i], mx)
            nxt = collide_v2(nxt, head, aim)
            nxt = _constrain(head, nxt, a, ln[i], mx)
            prev[i] = tips[i]
            tips[i] = nxt
            R = _arc(a, unit(nxt - head)) @ R
            head = nxt
    return np.vstack([B[:1], np.array(tips)])


def collide_v2(p, head, aim):
    """The engine's 0700 collision: each collider pushes the particle out
    and slides it a little round toward its aim, and the segment's midpoint
    is pushed out too (the tip moving twice as far)."""
    for _, a, r, b in COLLIDERS:
        rr = r + HIT
        out = push_out(p, a, b, rr)
        if np.linalg.norm(out - p) > 1e-12:
            bb = a if b is None else b
            ab = bb - a
            t = np.clip(np.dot(out - a, ab) / max(np.dot(ab, ab), 1e-12), 0, 1) if b is not None else 0.0
            q = a + ab * t
            nrm = unit(out - q)
            tw = aim - out
            along = tw - nrm * np.dot(tw, nrm)
            la = np.linalg.norm(along)
            if la > rr * 0.25:
                along = along / la * rr * 0.25
            out = push_out(out + along, a, b, rr)
        p = out
        mid = (head + p) * 0.5
        cl = push_out(mid, a, b, rr)
        if np.linalg.norm(cl - mid) > 1e-12:
            p = p + (cl - mid) * 2.0
    return p


def _constrain(head, nxt, a, ln, mx):
    d = nxt - head
    nd = np.linalg.norm(d)
    d = d / nd if nd > 1e-9 else a
    ang = math.acos(float(np.clip(np.dot(d, a), -1, 1)))
    if ang > mx:
        ax = np.cross(a, d)
        na = np.linalg.norm(ax)
        ax = ax / na if na > 1e-9 else unit(np.cross(a, [1.0, 0, 0]))
        d = _rot(ax, mx) @ a
    return head + d * ln


def _rot(ax, t):
    K = np.array([[0, -ax[2], ax[1]], [ax[2], 0, -ax[0]], [-ax[1], ax[0], 0]])
    return np.eye(3) + math.sin(t) * K + (1 - math.cos(t)) * K @ K


def settle(B, rounds=5):
    """Hang chain B as the engine will: its rest made what the solver holds
    from it, again and again, until the solver no longer moves it (the
    drawn rest and the engine's rest agree). (bones, last move in metres)"""
    B = np.asarray(B, float)
    move = 0.0
    for _ in range(rounds):
        E = spring_rest(B)
        move = float(np.abs(E - B).max())
        B = E
        if move < 0.002:
            break
    return B, move


def fine_path(B, per=8):
    """A smooth path through the bones (Catmull-Rom), kept out of the
    colliders: what the cards follow between the joints."""
    P = [B[0]]
    n = len(B)
    for i in range(n - 1):
        p0 = B[max(i - 1, 0)]
        p1, p2 = B[i], B[i + 1]
        p3 = B[min(i + 2, n - 1)]
        for s in range(1, per + 1):
            t = s / per
            q = 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                       + (-p0 + 3 * p1 - 3 * p2 + p3) * t ** 3)
            P.append(collide(q, -HIT * 0.5) if s < per else q)
    return np.array(P)


def guides_hang(st):
    """The 24 hanging guides from each release."""
    G = []
    L = st["hang"] / st["segs"]
    for phi in chain_phis(st.get("amax", np.pi)):
        a = abs(phi)
        th = release_th(a)
        root = scalp_pt(phi, th, 0.010)
        nrm = scalp_n(phi, th)
        down = np.array([0.0, -1.0, 0.0])
        d0 = unit(down - nrm * np.dot(down, nrm) + nrm * 0.55)
        W = walk(root, d0, st["hang"] + 0.03, hang_pref(phi, st["front"]))
        G.append(Guide(W, st["segs"], L))
    return G


def guides_tail(st, n_tail=6, radius=0.009, tendrils=2):
    """A ponytail or braid: chains S00.. hang from the tie, two loose
    tendrils at the temples, the rest stubs."""
    tie = tie_point(st)
    L = st["hang"] / st["segs"]
    G = []
    n_main = n_tail
    out = unit(np.array([tie[0], 0.0, tie[2] + 0.03]))
    side = 1.0 if tie[0] >= 0 else -1.0
    for k in range(n_main):
        a = k / n_main * 2 * np.pi
        # a ring round the tail's start, square to the way it leaves the head
        u1 = unit(np.cross(out, [0, 1.0, 0]))
        off = (u1 * math.cos(a) + np.array([0, 1.0, 0]) * math.sin(a) * 0.6) * radius if n_main > 1 else np.zeros(3)
        root = tie + off + out * 0.010
        d0 = unit(np.array([0.0, -1.0, 0.0]) + out * 0.5)
        W = walk(root, d0, st["hang"] + 0.03, np.array([side * 0.55, 0.0, 0.45]), inertia=0.6)
        G.append(Guide(W, st["segs"], L))
    for side in ([1, -1][:tendrils]):
        phi = side * 1.20
        th = hairline_th(phi) - 0.03
        root = scalp_pt(phi, th, 0.004)
        nrm = scalp_n(phi, th)
        d0 = unit(np.array([0.0, -1.0, 0.05]) + nrm * 0.12)
        W = walk(root, d0, 0.16, np.array([0.0, 0.0, 0.15]), inertia=0.3)
        G.append(Guide(W, 3, 0.045))
    while len(G) < NCH:
        G.append(stub(tie))
    return G


def stub(at):
    """Two bones a centimetre apart, just off the tie: a chain that exists
    and moves nothing (nothing is skinned to it)."""
    p = np.asarray(at, float) + np.array([0, 0.0, -0.02])
    return Guide(np.array([p, p + np.array([0, -0.02, 0])]), 1, 0.01)


# ── cards ───────────────────────────────────────────────────────────────────
class Mesh:
    def __init__(self):
        self.P, self.N, self.UV, self.C, self.J, self.W, self.F = [], [], [], [], [], [], []

    def quad_strip(self, L, R, N, UV, C, JW):
        """Two rails L, R (k points each): faces between them."""
        n0 = len(self.P)
        k = len(L)
        for i in range(k):
            for side, Q in ((0, L), (1, R)):
                self.P.append(Q[i])
                self.N.append(N[i])
                self.UV.append(UV[i][side])
                self.C.append(C[i])
                j, w = JW[i]
                self.J.append(j)
                self.W.append(w)
        for i in range(k - 1):
            a = n0 + 2 * i
            self.F.append((a, a + 1, a + 3, a + 2))


def col_uv(col, i, k, v0=0.0, v1=1.0, jitter=0.0):
    u0 = (col + 0.03 + jitter) / ATLAS
    u1 = (col + 0.97 - jitter) / ATLAS
    v = v0 + (v1 - v0) * (i / max(k - 1, 1))
    return ((u0, v), (u1, v))


class Skin:
    """Bone indices by name, and how a point on a card is weighted."""

    def __init__(self, names):
        self.names = names
        self.ix = {n: i for i, n in enumerate(names)}

    def chain_w(self, c, s, L, nseg, w=1.0):
        """Weights on chain c's bones for arc length s along it (blended
        between the segments either side of a joint)."""
        b = s / L - 0.5
        j0 = int(math.floor(b))
        t = b - j0
        j0c = min(max(j0, 0), nseg - 1)
        j1c = min(max(j0 + 1, 0), nseg - 1)
        if j0 < 0:
            t = 0.0
        out = {}
        for j, ww in ((j0c, 1 - t), (j1c, t)):
            name = f"S{c:02d}_{j}"
            out[self.ix[name]] = out.get(self.ix[name], 0) + ww * w
        return out


def norm4(d):
    """A {bone: weight} dict as the four heaviest, summing to 1."""
    items = sorted(d.items(), key=lambda kv: -kv[1])[:4]
    s = sum(w for _, w in items) or 1.0
    j = [i for i, _ in items] + [0] * (4 - len(items))
    w = [x / s for _, x in items] + [0.0] * (4 - len(items))
    return (j, w)


def merge(*ds):
    out = {}
    for d in ds:
        for k, v in d.items():
            out[k] = out.get(k, 0) + v
    return out


def axis_out(p):
    """Outward from the body's axis, horizontal."""
    r = np.array([p[0], 0.0, p[2] + 0.03])
    n = np.linalg.norm(r)
    return r / n if n > 1e-6 else np.array([0, 0, -1.0])


def card_frame(p, t):
    """side (across the card) and normal (out of the hair) for a point p
    with tangent t: the side runs round the body's axis, so a lock hanging
    faces out and a lock lying over the pack lies flat."""
    ro = axis_out(p)
    side = np.array([ro[2], 0.0, -ro[0]])
    side = unit(side - t * np.dot(side, t))
    n = unit(np.cross(side, t))
    if np.dot(n, ro) + 0.5 * n[1] < 0:
        n = -n
    return side, n


def scalp_path(r_phi, r_th, e_phi, e_th, lift0, lift1, k, part_side=0.0, over_line=True):
    """Points from a root (φ, θ) to an end (φ, θ) along the scalp, lifted
    from lift0 to lift1; kept above the hairline on the way (hair combed
    back over the temple, not over the forehead)."""
    # along the great circle between them (over the crown from the front to
    # the back, never round past the face), the end eased in
    a = GH.dirs(np.array(r_phi), np.array(r_th))
    b = GH.dirs(np.array(e_phi), np.array(e_th))
    om = math.acos(float(np.clip(np.dot(a, b), -1, 1)))
    if om > 2.6:                          # nearly opposite: go over the top
        mid = unit(a + b + np.array([0, 0.6, 0]))
        b1 = mid
    pts = []
    for i in range(k + 1):
        u = i / k
        uu = u ** 1.15
        if om < 1e-4:
            d = a
        elif om > 2.6:
            d = _slerp(a, b1, min(1, uu * 2)) if uu < 0.5 else _slerp(b1, b, (uu - 0.5) * 2)
        else:
            d = _slerp(a, b, uu)
        ph = math.atan2(d[0], d[2])
        th = math.asin(max(-1, min(1, d[1])))
        if over_line and i < k:
            th = max(th, min(hairline_th(ph) + 0.04, r_th))
        pts.append(scalp_pt(ph, th, lift0 + (lift1 - lift0) * u ** 0.7))
    return np.array(pts)


def _slerp(a, b, t):
    om = math.acos(float(np.clip(np.dot(a, b), -1, 1)))
    if om < 1e-5:
        return a
    return (math.sin((1 - t) * om) * a + math.sin(t * om) * b) / math.sin(om)


def roots(n, line, rng, thin_top=False):
    out = []
    tries = 0
    while len(out) < n and tries < n * 60:
        tries += 1
        ph = rng.uniform(-np.pi, np.pi)
        th = np.arcsin(rng.uniform(np.sin(-0.5), 1.0))
        c = float(GH.hairline(np.array(ph), np.array(th), line))
        if rng.random() < c:
            out.append((ph, th, c))
    return out


def build_hang(name, st, G, skin, rng):
    """A hanging style: every card from its root over the scalp to its
    release, then down between two guides."""
    M = Mesh()
    phis = chain_phis(st.get("amax", np.pi))
    segs = st["segs"]
    L = st["hang"] / segs
    xpart = 0.0 if st["part"] == "centre" else 0.030
    left = sorted(range(12), key=lambda i: phis[i])            # +φ, ascending
    right = sorted(range(12, 24), key=lambda i: -phis[i])      # -φ, ascending |φ|
    knot = np.asarray(st["knot"], float) if st.get("knot") else None
    crown = []
    while len(crown) < st.get("crown", 0):
        # along the parting and over the crown: an outer, lighter layer that
        # breaks up the top of the head (the key light catches its sheen)
        ph = rng.uniform(-np.pi, np.pi)
        th = float(np.arcsin(rng.uniform(np.sin(0.75), 1.0)))
        c = float(GH.hairline(np.array(ph), np.array(th), st["line"]))
        if c > 0.9:
            crown.append((ph, th, c, True))
    for (ph, th, c, *outer) in [r + (False,) for r in roots(st["cards"], st["line"], rng)] + crown:
        outer = outer[0]
        p0 = scalp_pt(ph, th, 0.0)
        # which side of the parting
        side = 1.0 if p0[0] > xpart else -1.0
        if st["part"] == "side" and side < 0 and p0[2] > 0.02 and p0[1] > 0.06:
            sweep = True                     # the big side's front sweeps across
        else:
            sweep = False
        # where it leaves the head
        a = math.atan2(abs(p0[0] - xpart) + 0.004, p0[2] - 0.035)
        a = max(1.05, min(st.get("amax", np.pi), a + rng.normal(0, 0.05)))
        if sweep:
            a = max(a, 1.1 + 0.25 * rng.random())
        e_phi = side * a
        if knot is not None and th > 0.62 and abs(ph) > 0.5:
            # the top layer: up to the knot
            yield_knot_card(M, ph, th, knot, skin, rng)
            continue
        e_th = release_th(a)
        # lift: the hair from the parting lies over the hair below it
        depth = rng.uniform(0.85, 1.0) if outer else rng.random()
        top = smooth(0.2, 1.3, th)
        lift1 = 0.004 + 0.008 * top + 0.004 * depth
        ks = 5
        S = scalp_path(ph, th, e_phi, e_th, 0.0012, lift1, ks, over_line=True)
        # the hanging part: between the two guides either side of a
        order = left if side > 0 else right
        aps = [abs(phis[i]) for i in order]
        if a <= aps[0]:
            ca, cb, tb = order[0], order[0], 0.0
        elif a >= aps[-1] and st.get("amax", np.pi) < 3.0:
            ca, cb, tb = order[-1], order[-1], 0.0       # (worn forward: the back parts)
        elif a >= aps[-1]:
            # across the back: blend with the other side's last
            other = right[-1] if side > 0 else left[-1]
            span = 2 * (np.pi - aps[-1])
            tb = min(1.0, (a - aps[-1]) / span)
            ca, cb = order[-1], other
        else:
            j = int(np.searchsorted(aps, a) - 1)
            ca, cb = order[j], order[j + 1]
            tb = (a - aps[j]) / (aps[j + 1] - aps[j])
        Ga, Gb = G[ca].F, G[cb].F
        frac = st["tips"]
        hang_len = st["hang"] * (1 - frac * rng.random() ** 0.7)
        # a lock's thickness offset and its own small drift
        lay = (depth - 0.5) * st["thick"]
        drift_a, drift_b = rng.normal(0, 0.004), rng.normal(0, 0.004)
        wph = rng.uniform(0, 2 * np.pi)
        # the scalp part's end sits where the release of the blended guides is
        start = Ga[0] * (1 - tb) + Gb[0] * tb
        delta = S[-1] - start
        nf = 10 if hang_len > 0.25 else 7
        H = []
        for i in range(nf + 1):
            s = hang_len * i / nf
            pa, _ = along(Ga, s)
            pb, _ = along(Gb, s)
            p = pa * (1 - tb) + pb * tb
            fade = 1 - 0.6 * min(1.0, s / 0.12)
            H.append(p + delta * fade)
        H = np.array(H)
        # layer, drift and waves along the hanging part
        for i in range(1, nf + 1):
            s = hang_len * i / nf
            t = unit(H[min(i, nf)] - H[i - 1])
            sd, nn = card_frame(H[i], t)
            u = s / st["hang"]
            off = nn * lay * smooth(0.0, 0.15, s) + sd * (drift_a * u) + nn * (drift_b * u)
            if st["wave"] > 0:
                amp = st["wave"] * smooth(0.02, 0.18, s)
                off = off + sd * amp * math.sin(s / 0.085 * 2 * np.pi + wph) \
                    + nn * amp * 0.5 * math.cos(s / 0.085 * 2 * np.pi + wph)
            H[i] = H[i] + off
        # the hanging part must not sink into a collider (the inner layer)
        for i in range(1, nf + 1):
            H[i] = collide(H[i], -HIT + 0.003)
        path = np.vstack([S, H[1:]])
        nS = len(S)
        ln = np.r_[0, np.cumsum(np.linalg.norm(np.diff(path, axis=0), axis=1))]
        total = ln[-1]
        # layers: the inner hair dense and dark, the outer sparse, finer and
        # lighter (narrower cards at the silhouette)
        w0 = (0.009 if c < 0.8 else 0.011 + 0.003 * rng.random()) * (1.15 - 0.45 * depth)
        if c < 0.6:
            col = FINE
        elif depth < 0.4:
            col = int(rng.choice([2, 0]))
        elif depth > 0.8:
            col = int(rng.choice([4, FINE, 1]))
        else:
            col = int(rng.integers(0, 5))
        # each card its own shade: a value jitter, a little warmer or cooler
        cval = float(np.clip(rng.normal(1.0, 0.09), 0.78, 1.22))
        hj = rng.normal(0, 0.035)
        chue = (1 + hj, 1.0, 1 - hj)
        Lr, Rr, N, UV, C, JW = [], [], [], [], [], []
        for i, p in enumerate(path):
            t = unit(path[min(i + 1, len(path) - 1)] - path[max(i - 1, 0)])
            if i < nS:
                n_s = unit(p - GH.O)
                sd = unit(np.cross(n_s, t))
                nn = n_s
            else:
                sd, nn = card_frame(p, t)
            v = ln[i] / total
            hs = max(0.0, ln[i] - ln[nS - 1])
            wid = w0 * (1.0 + 0.6 * smooth(0.0, 0.10, hs)) * (1 - 0.55 * smooth(0.6, 1.0, v))
            Lr.append(p - sd * wid * 0.5)
            Rr.append(p + sd * wid * 0.5)
            shade_n = unit(nn + 0.7 * (axis_out(p) if i >= nS else unit(p - GH.O)) + np.array([0, 0.15, 0]))
            N.append(shade_n)
            UV.append(col_uv(col, ln[i], 2, 0.0, 1.0 / max(total, 1e-6) * 1.0)[0:2] if False else
                      ((((col + 0.03) / ATLAS), v), (((col + 0.97) / ATLAS), v)))
            dark = 0.50 + 0.55 * depth ** 0.8
            rootd = 0.70 + 0.30 * smooth(0.0, 0.06, ln[i])
            tipl = 1.0 + 0.22 * smooth(0.45, 1.0, v)
            k_ = dark * rootd * tipl * cval
            C.append((min(1, k_ * chue[0]), min(1, k_ * chue[1]), min(1, k_ * chue[2]),
                      1.0 - 0.35 * smooth(0.8, 1.0, v)))
            if i < nS - 1:
                JW.append(norm4({skin.ix["HairRoot"]: 1.0}))
            else:
                wr = 1.0 - smooth(0.0, 0.035, hs)
                ws = 1.0 - wr
                d = merge({skin.ix["HairRoot"]: wr},
                          skin.chain_w(ca, hs, L, segs, ws * (1 - tb)),
                          skin.chain_w(cb, hs, L, segs, ws * tb))
                JW.append(norm4(d))
        M.quad_strip(Lr, Rr, N, UV, C, JW)
    if knot is not None:
        knot_bun(M, knot, skin, rng, r=0.018)
    hairline_wisps(M, st, skin, rng)
    return M


def hairline_wisps(M, st, skin, rng, n=420):
    """Short fine wisps along the hairline, the parting and the nape,
    lying the way the hair is combed: so the edge of the hair is soft and
    broken, not the rim of a cap."""
    tie = None
    if st.get("kind") in ("tail", "braid"):
        tie = tie_point(st)
    made, tries = 0, 0
    j = norm4({skin.ix["HairRoot"]: 1.0})
    while made < n and tries < n * 80:
        tries += 1
        ph = rng.uniform(-np.pi, np.pi)
        th = float(np.arcsin(rng.uniform(np.sin(-0.55), 1.0)))
        c = float(GH.hairline(np.array(ph), np.array(th), st.get("line", "normal")))
        if not (0.03 < c < 0.65):
            continue
        if tie is not None and 0.8 < abs(ph) < 1.9 and th < 0.55:
            continue                    # (pulled back, a temple's wisps read as dashes)
        p0 = scalp_pt(ph, th, 0.0)
        if tie is not None:
            tp = GH.to_angles(tie)
            e_phi, e_th = float(tp[0]), float(tp[1])
        else:
            a = math.atan2(abs(p0[0]) + 0.004, p0[2] - 0.035)
            a = max(1.05, min(st.get("amax", np.pi), a))
            e_phi, e_th = (1 if p0[0] >= 0 else -1) * a, release_th(a)
        S = scalp_path(ph, th, e_phi, e_th, 0.0006, 0.0025, 12, over_line=False)
        ln = np.r_[0, np.cumsum(np.linalg.norm(np.diff(S, axis=0), axis=1))]
        L = 0.010 + 0.022 * rng.random() * (0.5 + c)
        k = max(2, int(np.searchsorted(ln, L)))
        Q = S[:k + 1]
        lq = ln[:k + 1]
        w = 0.005 + 0.003 * rng.random()
        col = 4                        # the sparsest clump's tip end: a few soft strands
        Lr, Rr, N, UV, C, JW = [], [], [], [], [], []
        for i, q in enumerate(Q):
            t = unit(Q[min(i + 1, len(Q) - 1)] - Q[max(i - 1, 0)])
            nrm = unit(q - GH.O)
            sd = unit(np.cross(nrm, t))
            v = lq[i] / max(lq[-1], 1e-6)
            Lr.append(q - sd * w * 0.5 * (1 - 0.5 * v))
            Rr.append(q + sd * w * 0.5 * (1 - 0.5 * v))
            N.append(nrm)
            vv = 0.62 + 0.38 * v
            UV.append((((col + 0.25) / ATLAS, vv), ((col + 0.75) / ATLAS, vv)))
            C.append((0.75, 0.75, 0.75, 0.85 - 0.45 * v))
            JW.append(j)
        M.quad_strip(Lr, Rr, N, UV, C, JW)
        made += 1


def yield_knot_card(M, ph, th, knot, skin, rng):
    """A card from a root up over the scalp to a knot (half-up, a tail's tie)."""
    kp = GH.to_angles(knot)
    k_phi, k_th = float(kp[0]), float(kp[1])
    S = scalp_path(ph, th, k_phi + rng.normal(0, 0.06), k_th + rng.normal(0, 0.04), 0.0012,
                   0.008 + 0.004 * rng.random(), 6, over_line=True)
    S[-1] = knot + rng.normal(0, 0.004, 3)
    ln = np.r_[0, np.cumsum(np.linalg.norm(np.diff(S, axis=0), axis=1))]
    col = int(rng.integers(0, 5))
    w0 = 0.012 * (0.8 + 0.4 * rng.random())
    Lr, Rr, N, UV, C, JW = [], [], [], [], [], []
    for i, p in enumerate(S):
        t = unit(S[min(i + 1, len(S) - 1)] - S[max(i - 1, 0)])
        n_s = unit(p - GH.O)
        sd = unit(np.cross(n_s, t))
        v = ln[i] / ln[-1]
        wid = w0 * (1 - 0.6 * v)
        Lr.append(p - sd * wid * 0.5)
        Rr.append(p + sd * wid * 0.5)
        N.append(unit(n_s + np.array([0, 0.15, 0])))
        UV.append((((col + 0.03) / ATLAS, v * 0.7), ((col + 0.97) / ATLAS, v * 0.7)))
        C.append((0.95, 0.95, 0.95, 1.0))
        JW.append(norm4({skin.ix["HairRoot"]: 1.0}))
    M.quad_strip(Lr, Rr, N, UV, C, JW)


def knot_bun(M, c, skin, rng, r=0.020, n=90, out=None):
    """Locks wound round a knot (a bun at the crown, a tie), on its side
    away from the head (`out`)."""
    out = unit(np.asarray(c, float) - GH.O) if out is None else unit(out)
    for k in range(n):
        a = rng.random() * 2 * np.pi
        b = rng.uniform(-1.0, 1.0)
        nrm = unit(np.array([math.cos(a) * math.cos(b), math.sin(b), math.sin(a) * math.cos(b)]) + out * 0.9)
        t = unit(np.cross(nrm, [0, 0, 1.0]) + np.cross(nrm, [0, 1.0, 0]) * (rng.random() - 0.5))
        s = unit(np.cross(nrm, t))
        segs = 5
        col = int(rng.integers(0, 5))
        rr = r * (0.85 + 0.3 * rng.random())
        Lr, Rr, N, UV, C, JW = [], [], [], [], [], []
        for i in range(segs + 1):
            ang = i / segs * 1.9
            q = c + (nrm * math.cos(ang) + t * math.sin(ang)) * rr
            nq = unit(q - c)
            Lr.append(q - s * 0.007)
            Rr.append(q + s * 0.007)
            N.append(nq)
            UV.append((((col + 0.03) / ATLAS, 0.1 + i / segs * 0.5), ((col + 0.97) / ATLAS, 0.1 + i / segs * 0.5)))
            C.append((0.9, 0.9, 0.9, 1.0))
            JW.append(norm4({skin.ix["HairRoot"]: 1.0}))
        M.quad_strip(Lr, Rr, N, UV, C, JW)


def build_tail(name, st, G, skin, rng, braid=False):
    """Pulled back: every root combed over the scalp to the tie; then a
    ponytail (cards in a bundle between the tail's chains) or a plait."""
    M = Mesh()
    tie = tie_point(st)
    tp = GH.to_angles(tie)
    t_phi, t_th = float(tp[0]), float(tp[1])
    segs = st["segs"]
    L = st["hang"] / segs
    n_main = 6 if not braid else 1
    for (ph, th, c) in roots(st["cards"], st["line"], rng):
        k = 7
        e_phi = t_phi + rng.normal(0, 0.05)
        S = scalp_path(ph, th, e_phi, t_th + rng.normal(0, 0.03), 0.0012,
                       0.004 + 0.006 * smooth(0.2, 1.4, th) + 0.002 * rng.random(), k, over_line=True)
        S[-1] = tie + rng.normal(0, 0.003, 3) + np.array([0, 0, 0.004])
        # pulled taut: no lift over the last stretch toward the tie
        ln = np.r_[0, np.cumsum(np.linalg.norm(np.diff(S, axis=0), axis=1))]
        if braid:
            path, nS = S, len(S)
        else:
            # into the tail: a place in its cross-section, between two chains
            a = rng.random() * 2 * np.pi
            rad = 0.6 + 0.4 * rng.random() ** 0.5
            j = int(a / (2 * np.pi) * n_main) % n_main
            tb = (a / (2 * np.pi) * n_main) % 1.0
            ca, cb = j, (j + 1) % n_main
            hang_len = st["hang"] * (1 - 0.22 * rng.random() ** 0.6)
            nf = 9
            H = []
            for i in range(nf + 1):
                s = hang_len * i / nf
                pa, ta = along(G[ca].F, s)
                pb, _ = along(G[cb].F, s)
                p = pa * (1 - tb) + pb * tb
                # the tail's section: tight at the tie, fuller below, a point at the tip
                u = s / st["hang"]
                R = (0.006 + 0.012 * smooth(0.0, 0.25, u) * (1 - 0.6 * smooth(0.55, 1.0, u)))
                sd, nn = card_frame(p, ta)
                p = p + (sd * math.cos(a) + nn * math.sin(a)) * R * rad
                H.append(collide(p, -HIT + 0.003) if i > 0 else p)
            path = np.vstack([S, np.array(H[1:])])
            nS = len(S)
        ln = np.r_[0, np.cumsum(np.linalg.norm(np.diff(path, axis=0), axis=1))]
        total = ln[-1]
        col = FINE if c < 0.6 else int(rng.integers(0, 5))
        w0 = 0.010 if c < 0.8 else 0.012 + 0.003 * rng.random()
        Lr, Rr, N, UV, C, JW = [], [], [], [], [], []
        depth = rng.random()
        cval = float(np.clip(rng.normal(1.0, 0.09), 0.78, 1.22))
        hj = rng.normal(0, 0.035)
        chue = (1 + hj, 1.0, 1 - hj)
        for i, p in enumerate(path):
            t = unit(path[min(i + 1, len(path) - 1)] - path[max(i - 1, 0)])
            if i < nS:
                n_s = unit(p - GH.O)
                sd = unit(np.cross(n_s, t))
                nn = n_s
            else:
                sd, nn = card_frame(p, t)
            v = ln[i] / total
            hs = max(0.0, ln[i] - ln[nS - 1])
            wid = w0 * (1 - 0.5 * smooth(0.7, 1.0, v)) * (0.7 if (i >= nS - 2 and i <= nS) else 1.0)
            Lr.append(p - sd * wid * 0.5)
            Rr.append(p + sd * wid * 0.5)
            N.append(unit(nn + 0.6 * (axis_out(p) if i >= nS else unit(p - GH.O)) + np.array([0, 0.15, 0])))
            UV.append((((col + 0.03) / ATLAS, v), ((col + 0.97) / ATLAS, v)))
            dark = (0.58 + 0.42 * depth) * cval * (0.75 + 0.25 * smooth(0.0, 0.06, ln[i])) * (1 + 0.2 * smooth(0.5, 1.0, v))
            C.append((min(1, dark * chue[0]), min(1, dark), min(1, dark * chue[2]), 1.0 - 0.35 * smooth(0.85, 1.0, v)))
            if braid or i < nS:
                JW.append(norm4({skin.ix["HairRoot"]: 1.0}))
            else:
                wr = 1.0 - smooth(0.0, 0.02, hs)
                d = merge({skin.ix["HairRoot"]: wr}, skin.chain_w(ca, hs, L, segs, (1 - wr) * (1 - tb)),
                          skin.chain_w(cb, hs, L, segs, (1 - wr) * tb))
                JW.append(norm4(d))
        M.quad_strip(Lr, Rr, N, UV, C, JW)
    # the tie: hair wrapped round it
    knot_bun(M, tie + unit(np.array([tie[0], 0.0, tie[2] + 0.03])) * 0.004, skin, rng, r=0.011, n=40)
    hairline_wisps(M, st, skin, rng, n=360)
    if braid:
        plait(M, G[0], st, skin, rng)
    # the loose tendrils at the temples (chains n_main.. n_main+1)
    for k, ci in enumerate((n_main, n_main + 1) if not braid else (1, 2)):
        tendril(M, G[ci], ci, skin, rng)
    return M


def tendril(M, Gc, ci, skin, rng, n=4):
    segs = Gc.segs
    L = Gc.L
    for k in range(n):
        ln_ = L * segs * (0.75 + 0.25 * rng.random())
        nf = 6
        off = rng.normal(0, 0.006, 3)
        Lr, Rr, N, UV, C, JW = [], [], [], [], [], []
        col = FINE if k % 2 == 0 else 4
        for i in range(nf + 1):
            s = ln_ * i / nf
            p, t = along(Gc.F, s)
            p = p + off * (0.3 + s / ln_)
            sd, nn = card_frame(p, t)
            w = 0.007 * (1 - 0.6 * i / nf)
            Lr.append(p - sd * w)
            Rr.append(p + sd * w)
            N.append(unit(nn + 0.5 * axis_out(p)))
            v = i / nf
            UV.append((((col + 0.03) / ATLAS, 0.2 + v * 0.8), ((col + 0.97) / ATLAS, 0.2 + v * 0.8)))
            C.append((0.9, 0.9, 0.9, 1.0 - 0.4 * v))
            JW.append(norm4(skin.chain_w(ci, s, L, segs)))
        M.quad_strip(Lr, Rr, N, UV, C, JW)


def plait(M, Gc, st, skin, rng):
    """A three-strand plait along chain 0: each strand a tube of hair cards
    weaving over and under, narrowing to a tie and a tuft."""
    segs = st["segs"]
    L = st["hang"] / segs
    total = st["hang"] * 0.88
    lam = 0.052                     # one crossing every lam/3 along it
    nS = 120
    for j in range(3):
        phase = j * 2 * np.pi / 3
        ring = 10
        rails = [[] for _ in range(ring)]
        meta = []
        for i in range(nS + 1):
            s = total * i / nS
            p, t = along(Gc.F, s)
            sd, nn = card_frame(p, t)
            taper = 1 - 0.45 * smooth(0.55, 1.0, s / total)
            A = 0.0095 * taper
            th = 2 * np.pi * s / lam + phase
            c = p + sd * A * math.sin(th) + nn * 0.55 * A * math.sin(2 * th)
            rad = 0.0088 * taper * (0.80 + 0.20 * abs(math.cos(3 * th)))
            for r in range(ring):
                ang = r / ring * 2 * np.pi
                rails[r].append(c + (sd * math.cos(ang) + nn * math.sin(ang)) * rad)
            meta.append((s, unit(sd * 0 + nn), c))
        for r in range(ring):
            r2 = (r + 1) % ring
            col = LOBE
            Lr, Rr, N, UV, C, JW = rails[r], rails[r2], [], [], [], []
            for i in range(nS + 1):
                s, _, c = meta[i]
                mid = (Lr[i] + Rr[i]) / 2
                N.append(unit(mid - c))
                v = (s / lam * 3) % 1.0         # each lobe one picture: v runs through it
                UV.append((((col + 0.03 + 0.47 * r / ring) / ATLAS, v), ((col + 0.03 + 0.47 * (r + 1) / ring) / ATLAS, v)))
                C.append((0.9, 0.9, 0.9, 1.0))
                JW.append(norm4(skin.chain_w(0, s, L, segs)))
            # the faces: v wraps each lobe, so split where it jumps back
            n0 = len(M.P)
            for i in range(nS + 1):
                for side, Q in ((0, Lr), (1, Rr)):
                    M.P.append(Q[i])
                    M.N.append(N[i])
                    M.UV.append(UV[i][side])
                    M.C.append(C[i])
                    M.J.append(JW[i][0])
                    M.W.append(JW[i][1])
            for i in range(nS):
                if UV[i + 1][0][1] < UV[i][0][1]:
                    continue
                a = n0 + 2 * i
                M.F.append((a, a + 1, a + 3, a + 2))
    # the tuft below the tie
    end = total
    for k in range(26):
        Lr, Rr, N, UV, C, JW = [], [], [], [], [], []
        a = rng.random() * 2 * np.pi
        ln_ = 0.05 + 0.035 * rng.random()
        col = int(rng.integers(0, 5))
        for i in range(6):
            s = end + ln_ * i / 5
            p, t = along(Gc.F, s)
            sd, nn = card_frame(p, t)
            spread = 0.004 + 0.012 * (i / 5)
            p = p + (sd * math.cos(a) + nn * math.sin(a)) * spread
            w = 0.006 * (1 - 0.5 * i / 5)
            Lr.append(p - sd * w)
            Rr.append(p + sd * w)
            N.append(unit(nn + 0.4 * axis_out(p)))
            UV.append((((col + 0.03) / ATLAS, 0.4 + 0.6 * i / 5), ((col + 0.97) / ATLAS, 0.4 + 0.6 * i / 5)))
            C.append((0.9, 0.9, 0.9, 1.0 - 0.4 * i / 5))
            JW.append(norm4(skin.chain_w(0, min(s, st["hang"] - 1e-3), L, segs)))
        M.quad_strip(Lr, Rr, N, UV, C, JW)
    # the tie round the plait's end: a dark band of wound hair
    p, t = along(Gc.F, end)
    sd, nn = card_frame(p, t)
    ring = 10
    Lr, Rr, N, UV, C, JW = [], [], [], [], [], []
    for r in range(ring + 1):
        ang = r / ring * 2 * np.pi
        d = sd * math.cos(ang) + nn * math.sin(ang)
        Lr.append(p + d * 0.0068 - t * 0.006)
        Rr.append(p + d * 0.0068 + t * 0.006)
        N.append(d)
        UV.append((((SOLID + 0.1) / ATLAS, 0.5), ((SOLID + 0.9) / ATLAS, 0.5)))
        C.append((0.25, 0.25, 0.25, 1.0))
        JW.append(norm4(skin.chain_w(0, end, L, segs)))
    M.quad_strip(Lr, Rr, N, UV, C, JW)


def under_layer(M, st, skin):
    """The solid under-layer on the scalp (no skin between the cards)."""
    rng = np.random.default_rng(3)
    Ps, Fs, UVs = GH.solid_layer(dict(line=st.get("line", "normal"), shell=0.0016), rng)
    n0 = len(M.P)
    j = norm4({skin.ix["HairRoot"]: 1.0})
    for p, uv in zip(Ps, UVs):
        M.P.append(np.asarray(p))
        M.N.append(unit(np.asarray(p) - GH.O))
        # the short atlas's solid column → this atlas's
        v = uv[1]
        uu = ((uv[0] * GH.ATLAS_COLS - GH.SOLID) * 0.94 + 0.03 + SOLID) / ATLAS
        M.UV.append((uu, v))
        M.C.append((0.45, 0.45, 0.45, 1.0))
        M.J.append(j[0])
        M.W.append(j[1])
    for f in Fs:
        M.F.append(tuple(i + n0 for i in f))


# ── the rig and the file ────────────────────────────────────────────────────
def bone_names(G):
    names = ["HairRoot", "HairBody"]
    for c, P in enumerate(G):
        names += [f"S{c:02d}_{j}" for j in range(len(P))]
    return names


def write_glb(name, M, G, path):
    names = bone_names(G)
    # world (head-local) joint positions
    Jp = {"HairRoot": np.zeros(3), "HairBody": BODY_PIVOT.copy()}
    for c, P in enumerate(G):
        for j, p in enumerate(P.B):
            Jp[f"S{c:02d}_{j}"] = np.asarray(p, float)
    parent = {"HairBody": "HairRoot"}
    for c, P in enumerate(G):
        for j in range(len(P)):
            parent[f"S{c:02d}_{j}"] = "HairRoot" if j == 0 else f"S{c:02d}_{j - 1}"
    P = np.array(M.P, float)
    assert np.all(np.abs(P) <= BOX), f"{name}: outside the anchor box: {np.abs(P).max(0)}"
    # the anchor triangles (the box about HC: the engine centres on it)
    A = np.array([-BOX, -BOX + [1e-4, 0, 0], -BOX + [0, 1e-4, 0], BOX, BOX - [1e-4, 0, 0], BOX - [0, 1e-4, 0]])
    n = len(P)
    Pall = np.vstack([P, A]) + HC
    N = np.vstack([np.array(M.N, float), np.tile([0, 1.0, 0], (6, 1))])
    UV = np.vstack([np.array(M.UV, float), np.zeros((6, 2))])
    C = np.vstack([np.array(M.C, float), np.ones((6, 4))])
    J = np.vstack([np.array(M.J, int), np.zeros((6, 4), int)])
    W = np.vstack([np.array(M.W, float), np.tile([1.0, 0, 0, 0], (6, 1))])
    I = GF.tris(M.F).reshape(-1, 3)
    I = np.vstack([I, np.array([[n, n + 1, n + 2], [n + 3, n + 5, n + 4]])])
    g = GF.Glb()
    g.prim("HairLong", Pall, N, UV, C, I, J, W)
    nodes = []
    for b in names:
        par = parent.get(b)
        loc = Jp[b] - Jp[par] if par else Jp[b] + HC
        nodes.append({"name": b, "translation": [float(x) for x in loc]})
    ix = {b: i for i, b in enumerate(names)}
    for b in names:
        kids = [ix[c] for c in names if parent.get(c) == b]
        if kids:
            nodes[ix[b]]["children"] = kids
    ibm = np.zeros((len(names), 4, 4), np.float32)
    for i, b in enumerate(names):
        Mx = np.eye(4)
        Mx[:3, 3] = -(Jp[b] + HC)
        ibm[i] = Mx.T
    g.accs.append({"bufferView": g.view(ibm.tobytes()), "componentType": 5126, "count": len(names), "type": "MAT4"})
    mesh_node = len(nodes)
    nodes.append({"name": "Hair", "mesh": 0, "skin": 0})
    g.mats[0]["doubleSided"] = True
    g.mats[0]["alphaMode"] = "MASK"
    g.mats[0]["alphaCutoff"] = 0.5
    g.write(path, {"asset": {"version": "2.0", "generator": "Solar tools/gen_faces_longhair.py", "copyright": COPYRIGHT},
                   "scene": 0, "scenes": [{"nodes": [0, mesh_node]}], "nodes": nodes,
                   "meshes": [{"name": "Hair", "primitives": g.prims}],
                   "skins": [{"joints": list(range(len(names))), "inverseBindMatrices": len(g.accs) - 1, "skeleton": 0}]})
    return len(I), len(names)


def build(name):
    st = LONG[name]
    rng = np.random.default_rng(sum(map(ord, name)) * 7 + 1)
    if st["kind"] == "hang":
        G = guides_hang(st)
    elif st["kind"] == "tail":
        G = guides_tail(st, n_tail=6)
    else:
        G = guides_tail(st, n_tail=1)
    skin = Skin(bone_names(G))
    if st["kind"] == "hang":
        M = build_hang(name, st, G, skin, rng)
    else:
        M = build_tail(name, st, G, skin, rng, braid=st["kind"] == "braid")
    under_layer(M, st, skin)
    return M, G


# ── the spring spec (tools/gen_faces.py face_nodes writes it on the Hair node)
def _v(p):
    return "(" + ", ".join(f"{float(x):.4f}" for x in p) + ")"


def springs_file(name):
    """A style's spring bones as a `.springs.ron` (engine 0700), written
    beside its model: every node wearing the model swings by it. A hanging
    style is one pattern (S??_0: a chain per strand); a tail or a plait
    names its real chains only (no stubs). Collider offsets are in their
    bone's space: HairRoot at the head's centre, HairBody at BODY_PIVOT
    (rest rotations identity)."""
    s = SPRING
    st = LONG[name]
    num = (f'stiffness: {s["stiffness"]}, gravity: {s["gravity"]}, drag: {s["drag"]}, max_angle: {s["max_angle"]}, '
           f'hit_radius: {s["hit_radius"]}, root_stiffness: {s["root_stiffness"]}')
    lines = ["// tools/gen_faces_longhair.py writes this: the spring bones of hair_%s.glb" % name, "(", "    chains: ["]
    if st["kind"] == "hang":
        lines.append(f'        (name: "S", root: "S??_0", {num}),')
    else:
        real = 6 + 2 if st["kind"] == "tail" else 1 + 2
        for c in range(real):
            lines.append(f'        (name: "S{c:02d}", root: "S{c:02d}_0", {num}),')
    lines.append("    ],")
    lines.append("    colliders: [")
    for bone, a, r, b in COLLIDERS:
        o = a - (BODY_PIVOT if bone == "HairBody" else 0)
        e = "" if b is None else f", end: Some({_v(b - (BODY_PIVOT if bone == 'HairBody' else 0))})"
        lines.append(f'        (bone: "{bone}", offset: {_v(o)}, radius: {r:.4f}{e}),')
    lines.append("    ],")
    lines.append("    gravity: (0.0, -9.81, 0.0),")
    lines.append(")")
    return "\n".join(lines) + "\n"


# ── the texture ─────────────────────────────────────────────────────────────
def texture(n=1024, seed=11):
    """The long cards' atlas (grey, alpha; the second value is unused). v = 0 is the
    root, v = 1 the tip."""
    rng = np.random.default_rng(seed)
    cw = n // ATLAS
    A = np.zeros((n, n), np.float32)          # coverage
    G = np.zeros((n, n), np.float32)          # grey (premultiplied by coverage)
    ys = np.arange(n)
    v = ys / (n - 1)
    for col in range(ATLAS):
        x0 = col * cw
        if col == SOLID:
            k = 420
        elif col == FINE:
            k = 22
        elif col == LOBE:
            k = 150
        else:
            k = [70, 55, 85, 62, 45][col]
        # a clump: narrow at the root, spreading, gathering again toward
        # the tips (hair clumps), its strands thinning out at its edges
        spread = 0.62 + 0.38 * smooth(0.0, 0.25, v) - 0.22 * smooth(0.65, 1.0, v)
        for _ in range(k):
            if col == LOBE:
                # a lobe: strands bowing round, bunched toward its ends
                cx = x0 + rng.uniform(4, cw - 4)
                ln_ = 1.0
                wav = 0.0
                bow = (cx - (x0 + cw / 2)) * 0.25
            else:
                off = rng.normal(0, cw * (0.20 if col != SOLID else 0.40))
                cx = x0 + cw / 2 + off
                ln_ = 1.0 if col == SOLID else (rng.uniform(0.45, 1.0) if col == FINE else 1 - 0.32 * rng.random() ** 1.3)
                wav = rng.uniform(0.3, 1.6) * (2.5 if col == 3 else 1.0)
                bow = 0.0
            wd = rng.uniform(0.85, 1.35) if col != FINE else rng.uniform(0.6, 0.8)
            # real variation: most strands mid, a few dark ones under, a
            # few light ones that catch the light
            r_ = rng.random()
            br = float(np.clip(rng.normal(0.78, 0.10), 0.5, 1.0)) if r_ < 0.8 else \
                (float(rng.uniform(0.45, 0.6)) if r_ < 0.9 else float(rng.uniform(0.92, 1.0)))
            fr = rng.uniform(2, 7)
            ph = rng.uniform(0, 6.3)
            drift = rng.uniform(-4, 4) if col not in (SOLID, LOBE) else 0.0
            if col in (SOLID, LOBE):
                xs = cx + wav * np.sin(v * fr + ph)
            else:
                xs = x0 + cw / 2 + off * spread + wav * np.sin(v * fr + ph) + drift * v ** 1.6
                xs = np.clip(xs, x0 + 2, x0 + cw - 3)
            if col == LOBE:
                xs = cx + bow * np.sin(v * np.pi) * 1.0 - (x0 + cw / 2 - cx) * 0.25 * (np.cos(v * np.pi * 2) - 1) * 0.3
            # soft tapered tips: the strand thins and fades over its last quarter
            tip = np.ones(n) if col in (SOLID, LOBE) else smooth(ln_, ln_ - 0.25, v)
            tip = np.where(v > ln_, 0.0, tip)
            wdv = wd * (1.0 if col in (SOLID, LOBE) else (0.55 + 0.45 * tip))
            base = np.floor(xs - wd - 1).astype(int)
            for o in range(int(2 * wd + 4)):
                x = base + o
                ok = (x >= x0) & (x < x0 + cw) & (tip > 0)
                dx = (x + 0.5 - xs) / wdv
                cov = np.clip(1 - np.abs(dx), 0, 1) * tip
                ok &= cov > 0
                yy, xx, cv, dd = ys[ok], x[ok], cov[ok], dx[ok]
                a0 = A[yy, xx]
                A[yy, xx] = a0 + (1 - a0) * cv
                G[yy, xx] = G[yy, xx] * (1 - cv) + br * cv
        if col == SOLID:
            # the under-layer: dark and low in contrast (the shadow under the hair)
            A[:, x0:x0 + cw] = 1.0
            G[:, x0:x0 + cw] = 0.30 + 0.25 * G[:, x0:x0 + cw]
        elif col != LOBE:
            # a sheen band across the clump a little way from the root (the
            # anisotropic highlight hair has, baked: strands catch it a
            # little apart from each other)
            b0 = 0.16 + 0.05 * (col % 3)
            band = np.exp(-((v - b0) / 0.05) ** 2)[:, None]
            jit = 1 + 0.5 * np.sin(np.arange(cw)[None, :] * 0.9 + col)
            G[:, x0:x0 + cw] *= 1 + 0.35 * band * jit
        if col == LOBE:
            # a lobe darkens toward its ends, where it tucks under the next
            shade = 0.45 + 0.55 * np.sin(v * np.pi) ** 0.6
            G[:, x0:x0 + cw] *= shade[:, None]
            # a plait's lobe is solid (its strands packed), dark between them
            G[:, x0:x0 + cw] = np.maximum(np.where(A[:, x0:x0 + cw] > 0.05, G[:, x0:x0 + cw], 0.0), 0.6 * shade[:, None])
            A[:, x0:x0 + cw] = 1.0
    # the strands a touch lighter toward the tips (sun-faded), darker at the roots
    G *= (0.82 + 0.18 * smooth(0.0, 0.5, v))[:, None]
    rgb = np.clip(G, 0, 1)
    img = np.zeros((n, n, 4), np.uint8)
    for k in range(3):
        img[..., k] = np.round(rgb * 255)
    # alpha: the coverage, dithered where it is partial (a blue-ish noise
    # added before the cutout breaks the cut's stair-steps into a stipple,
    # which the mips and the antialiasing soften)
    noise = rng.random((n, n)).astype(np.float32)
    noise = (noise + np.roll(noise, 1, 0) + np.roll(noise, 1, 1)) / 3 - 0.5
    partial = (A > 0.02) & (A < 0.98)
    Ad = np.where(partial, A + noise * 0.55, A)
    img[..., 3] = np.round(np.clip(Ad, 0, 1) * 255)
    # columns 0-5 from real strands rendered in Blender (tools/hair_strands_blender.py),
    # when it can be run: curves with round, tapering sections, antialiased
    # coverage, the clump's back strands and the roots in their own shade
    real = blender_strands(n)
    if real is not None:
        img[:, :6 * cw] = real[:, :6 * cw]
        # the sheen band across each clump (as the painted strands have it)
        for col in range(5):
            x0 = col * cw
            b0 = 0.16 + 0.05 * (col % 3)
            band = np.exp(-((v - b0) / 0.05) ** 2)[:, None, None]
            jit = 1 + 0.5 * np.sin(np.arange(cw)[None, :, None] * 0.9 + col)
            c3 = img[:, x0:x0 + cw, :3].astype(np.float32) * (1 + 0.35 * band * jit)
            img[:, x0:x0 + cw, :3] = np.clip(c3, 0, 255).astype(np.uint8)
    # bleed the colour out under the transparent texels (mips don't go black at the edges)
    img = _bleed(img)
    return img, None


BLENDER = "/mnt/disks/3tb/SteamLibrary/steamapps/common/Blender/blender"


def blender_strands(n):
    """The strand columns rendered from curves at twice the size and brought
    down (a box filter on premultiplied colour: the coverage stays), or None
    without Blender. HAIR_STRANDS=<png> reuses a render."""
    import subprocess
    png = os.environ.get("HAIR_STRANDS")
    if not png:
        if not os.path.exists(BLENDER):
            return None
        cache = os.path.join(os.path.expanduser("~"), ".cache", "solar_hair")
        os.makedirs(cache, exist_ok=True)
        png = os.path.join(cache, "strands.png")
        subprocess.run([BLENDER, "--background", "--python",
                        os.path.join(os.path.dirname(os.path.abspath(__file__)), "hair_strands_blender.py"),
                        "--", png, str(n * 2)], check=True, capture_output=True)
    im = np.asarray(Image.open(png).convert("RGBA"), np.float32) / 255.0
    a = im[..., 3:4]
    pre = np.concatenate([im[..., :3] * a, a], -1)
    h = pre.shape[0] // n
    pre = pre.reshape(n, h, n, h, 4).mean((1, 3))
    al = pre[..., 3:4]
    rgb = np.where(al > 1e-4, pre[..., :3] / np.maximum(al, 1e-4), 0.0)
    out = np.zeros((n, n, 4), np.uint8)
    out[..., :3] = np.round(np.clip(rgb, 0, 1) * 255)
    out[..., 3] = np.round(np.clip(al[..., 0] * 1.1, 0, 1) * 255)
    return out


def _bleed(img, rounds=6):
    rgb = img[..., :3].astype(np.float32)
    a = img[..., 3] > 8
    for _ in range(rounds):
        acc = np.zeros_like(rgb)
        cnt = np.zeros(a.shape, np.float32)
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            sh = np.roll(np.roll(a, dy, 0), dx, 1)
            acc += np.roll(np.roll(rgb, dy, 0), dx, 1) * sh[..., None]
            cnt += sh
        fill = (~a) & (cnt > 0)
        rgb[fill] = acc[fill] / cnt[fill][:, None]
        a = a | fill
    out = img.copy()
    out[..., :3] = np.round(rgb).astype(np.uint8)
    return out


def main():
    dry = "--dry" in sys.argv
    only = [a for a in sys.argv[1:] if not a.startswith("--")]
    if "--tex" in sys.argv or not (dry or only):
        img, _ = texture()
        # alpha cut to 0/255 at the material's own cutoff (HairLong 0.35): the
        # same pixels pass at full size, and an all-0/255 picture keeps its
        # coverage down the mips (engine 0701), so hair doesn't thin out at range
        img = img.copy()
        img[..., 3] = np.where(img[..., 3] >= round(0.35 * 255), 255, 0).astype(np.uint8)
        if not dry:
            Image.fromarray(img, "RGBA").save(os.path.join(TEXDIR, "hair_long.png"))
            print("texture", img.shape)
        if "--tex" in sys.argv:
            return
    for name in (only or LONG):
        M, G = build(name)
        if dry:
            print(f"hair_{name}: verts {len(M.P)} quads {len(M.F)} chains {len(G)}")
            continue
        ntri, nb = write_glb(name, M, G, os.path.join(MODELS, f"hair_{name}.glb"))
        with open(os.path.join(MODELS, f"hair_{name}.springs.ron"), "w") as f:
            f.write(springs_file(name))
        print(f"hair_{name}: verts {len(M.P)} tris {ntri} bones {nb}")


if __name__ == "__main__":
    main()
