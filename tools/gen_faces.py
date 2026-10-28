#!/usr/bin/env python3
"""Generate the crew's FACES: heads with a face rig, hair, the comm cap.

    python3 tools/gen_faces.py           # models, textures, the Lua rig block
    python3 tools/gen_faces.py --dry     # print the budget, write nothing
    python3 tools/gen_faces.py --scene   # the Face / Hair / Cap nodes into the prefabs and system.ron
    python3 tools/gen_faces.py --morphs DIR   # heads with the channels as named morph
                                         #   targets (for engine card 0572; not shipped)

Writes
    models/astronaut/faces/head_<n>.glb   eight skinned heads (the structures)
    models/astronaut/faces/hair_<s>.glb   the hair styles (static, rigid on the head)
    models/astronaut/faces/cap.glb        the comm cap ("Snoopy cap"), worn under the helmet
    textures/faces/skin_detail.png        R lip line, G stubble, B brows, A wrinkles     (512²)
    textures/faces/skin_normal.png        pores and wrinkles                           (512²)
    textures/faces/hair_cards.png         the hair cards' strands (alpha-cut)            (512²)
    scripts/face.lua                      the block between the "face rig" markers:
                                          bone names, lid angles, the channel map, the
                                          per-head rest pose

THE HEADS (tools/gen_faces_base.py): Blender Studio's CC0 "Human Base Meshes"
realistic head (animation topology, tools/faces_base/head_base.npz), placed
on the suit's neck, and deformed into eight structures by soft fields about
the face's landmarks. Same topology for all eight.

THE LAYOUT. The textures are painted once in CANONICAL angles about the
head's centre (s across, t up): each head's vertices are mapped there through
its own landmarks (eyes, mouth corners, nose, chin, brow), so the brows, the
stubble and the lip colour land on every face. The skin's COLOR_0 carries R
lips, G warmth, B where freckles go, A the cavities (the mouth's inside, the
nostrils, behind the lids).

THE RIG (bones of the head model itself; the head hangs on the suit's Head
bone as an attachment, scripts/face.lua drives these):
    FaceRoot ─ Jaw ─ LipLower
             ├ LipUpper, MouthL, MouthR, CheekL, CheekR
             ├ BrowInL, BrowInR, BrowOutL, BrowOutR
             ├ LidUpL, LidUpR, LidLoL, LidLoR   (pivots at the eyes' centres)
             └ EyeL, EyeR
All rest rotations identity, so a script turns them about the head's own axes.
Weights are painted from the landmarks (gen_faces_base.weights).

HAIR (tools/gen_faces_hair.py): cards — alpha-cut strip clumps — over a thin
solid layer, per style; the comm cap fitted to the scalp.

PLACEMENT. The engine centres a model on its rest bounding box; every model
here carries two zero-area anchor triangles pinning its box to the same box
about the head's centre (BOX; a model outside it is refused), so the Face
node's attachment offset is shared and Hair and Cap sit at its origin.

Licence: the base head CC0 (Blender Studio); everything else here new, CC0.
"""
import json
import math
import os
import struct
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_part_meshes import ROOT  # noqa: E402
from gen_part_textures import normal_from_height, spectral  # noqa: E402
import gen_faces_base as GB  # noqa: E402
from gen_faces_base import BI, BONES, HEADS, PARENT  # noqa: E402
import gen_faces_hair as GH  # noqa: E402
from gen_faces_hair import STYLES  # noqa: E402

MODELS = os.path.join(ROOT, "models", "astronaut", "faces")
TEXDIR = os.path.join(ROOT, "textures", "faces")
LUA = os.path.join(ROOT, "scripts", "face.lua")

# The suit's Head bone in bind space (tools/gen_suit.py's Rig on
# astronaut_male.glb) and the head's centre above it (gen_suit_blender's hc).
HEAD_BONE = np.array([-0.49989322, 1.57475442, -0.03309519])
HC = HEAD_BONE + np.array([0.0, 0.150, 0.020])
BOX = np.array([0.20, 0.30, 0.20])        # the shared anchor box's half size (holds every model here)

def smooth(a, b, x):
    t = np.clip((np.asarray(x, float) - a) / (b - a), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def unit(v):
    v = np.asarray(v, float)
    return v / np.maximum(np.linalg.norm(v, axis=-1, keepdims=True), 1e-12)


def dirs(phi, th):
    return np.stack([np.cos(th) * np.sin(phi), np.sin(th), np.cos(th) * np.cos(phi)], -1)


# ═════════════════════════════════════════════════════════════════════════════
# the structures
# ═════════════════════════════════════════════════════════════════════════════
# Canonical landmarks (s, t): the lattice and the textures are laid out on
# these; each head moves them to its own (φ, θ).
C_EYE_S, C_EYE_T = 0.33, 0.095
C_BROW_T = 0.215
C_NOSE_T = -0.215
C_MOUTH_T = -0.475
C_CHIN_T = -0.80
C_MOUTH_W = 0.25
EYE_HW, EYE_HT, EYE_HB = 0.140, 0.046, 0.036   # the almond: half width, half height above / below

def uv_of(s, t):
    u = np.interp(s, [-np.pi, -1.0, 1.0, np.pi], [0.0, 0.15, 0.85, 1.0])
    v = np.interp(t, [-np.pi / 2, -1.2, 1.2, np.pi / 2], [0.98, 0.884, 0.116, 0.02])
    return u, v


def st_of_uv(u, v):
    s = np.interp(u, [0.0, 0.15, 0.85, 1.0], [-np.pi, -1.0, 1.0, np.pi])
    t = np.interp(-v, [-0.98, -0.884, -0.116, -0.02], [-np.pi / 2, -1.2, 1.2, np.pi / 2])
    return s, t


def almond(s, t, side):
    """The eye opening's normalised radius (1 on the rim) about eye `side`."""
    ds = (s - side * C_EYE_S) / EYE_HW
    dt = t - C_EYE_T
    ht = np.where(dt > 0, EYE_HT, EYE_HB)
    # a little pointed at the corners: the height shrinks toward them
    return np.sqrt(ds ** 2 + (dt / (ht * (1 - 0.15 * ds ** 2))) ** 2)


def orient(P, F, centre):
    """Wind every face outward, away from `centre`."""
    out = []
    for f in F:
        a, b, c = P[f[0]], P[f[1]], P[f[2]]
        n = np.cross(b - a, c - a)
        if np.linalg.norm(n) < 1e-14 and len(f) == 4:
            n = np.cross(c - a, P[f[3]] - a)
        out.append(f if n @ ((a + b + c) / 3 - centre) >= 0 else tuple(reversed(f)))
    return out


# ── the eyes ────────────────────────────────────────────────────────────────

# ═════════════════════════════════════════════════════════════════════════════
# the rig
# ═════════════════════════════════════════════════════════════════════════════
JAW_MAX = 0.34
CHANNEL_MAP = {
    "jaw_open": [("Jaw", 0, 0, 0, 0, JAW_MAX)],
    "lip_down": [("LipLower", 0, -0.0065, 0.0012, 0, 0)],
    "lip_up": [("LipUpper", 0, 0.0058, 0.0008, 0, 0)],
    "smile_L": [("MouthL", 0.0060, 0.0088, -0.0022, 0, 0), ("LipUpper", 0, 0.0008, 0, 0, 0)],
    "frown_L": [("MouthL", 0.0008, -0.0060, -0.0004, 0, 0)],
    "stretch_L": [("MouthL", 0.0060, -0.0022, -0.0012, 0, 0)],
    "cheek_L": [("CheekL", 0.0010, 0.0055, 0.0012, 0, 0), ("LidLoL", 0, 0, 0, 0, -0.06)],
    "brow_in_up_L": [("BrowInL", 0, 0.0085, 0, 0, 0), ("BrowOutL", 0, 0.0015, 0, 0, 0), ("LidUpL", 0, 0, 0, 0, -0.04)],
    "brow_out_up_L": [("BrowOutL", 0, 0.0078, 0, 0, 0)],
    "brow_down_L": [("BrowInL", -0.0024, -0.0058, 0.0008, 0, 0), ("BrowOutL", 0, -0.0028, 0, 0, 0),
                    ("LidUpL", 0, 0, 0, 0, 0.08)],
    "blink_L": [("LidUpL", 0, 0, 0, 0, 1.06, "up"), ("LidLoL", 0, 0, 0, 0, -0.5, "lo")],
    "wide_L": [("LidUpL", 0, 0, 0, 0, -0.20)],
    "squint_L": [("LidUpL", 0, 0, 0, 0, 0.10), ("LidLoL", 0, 0, 0, 0, -0.75, "lo")],
    "look_x": [("EyeL", 0, 0, 0, 0.45, 0), ("EyeR", 0, 0, 0, 0.45, 0)],
    "look_y": [("EyeL", 0, 0, 0, 0, -0.45), ("EyeR", 0, 0, 0, 0, -0.45)],
}


def channel_entries():
    """CHANNEL_MAP with every _L channel mirrored into its _R twin."""
    out = {}
    for ch, ents in CHANNEL_MAP.items():
        out[ch] = ents
        if ch.endswith("_L"):
            out[ch[:-2] + "_R"] = [(b[:-1] + "R" if b.endswith("L") and b not in ("Jaw",) else b, -dx, dy, dz, -yaw, pitch)
                                   + tuple(e[6:]) for (b, dx, dy, dz, yaw, pitch, *_), e in ((x, x) for x in ents)]
    return out


def top4(W):
    """Root takes what is left; the four largest kept, normalised."""
    W = W.copy()
    tot = W[:, 1:].sum(1)
    over = tot > 1
    W[over, 1:] /= tot[over, None]
    W[:, 0] = np.clip(1 - W[:, 1:].sum(1), 0, 1)
    J = np.argsort(-W, axis=1)[:, :4]
    Wt = np.take_along_axis(W, J, 1)
    Wt /= Wt.sum(1, keepdims=True)
    return J, Wt


def sphere(c, r, ax, nu=20, nv=14, inward=False, scale=(1, 1, 1)):
    """A UV sphere about c, its pole along ax; uv the front's projection
    (0.5, 0.5 at the pole, the radius as 0.5)."""
    ax = unit(ax)
    up = np.array([0, 1.0, 0])
    xa = unit(np.cross(up, ax))
    ya = np.cross(ax, xa)
    P, UV, F = [], [], []
    for i in range(nv + 1):
        a = math.pi * i / nv                       # 0 at the front pole
        for j in range(nu):
            b = 2 * math.pi * j / nu
            lx, ly, lz = math.sin(a) * math.cos(b), math.sin(a) * math.sin(b), math.cos(a)
            p = c + (xa * lx * scale[0] + ya * ly * scale[1] + ax * lz * scale[2]) * r
            P.append(p)
            UV.append((0.5 + 0.5 * lx, 0.5 - 0.5 * ly))
    for i in range(nv):
        for j in range(nu):
            jj = (j + 1) % nu
            F.append((i * nu + j, i * nu + jj, (i + 1) * nu + jj, (i + 1) * nu + j))
    P = np.array(P)
    F = orient(P, F, c)
    if inward:
        F = [tuple(reversed(f)) for f in F]
    return P, F, UV


def normals(P, F):
    N = np.zeros_like(P)
    for f in F:
        tris = [(f[0], f[1], f[2])] + ([(f[0], f[2], f[3])] if len(f) == 4 else [])
        for a, b, c in tris:
            n = np.cross(P[b] - P[a], P[c] - P[a])
            N[a] += n
            N[b] += n
            N[c] += n
    return unit(N)


def tris(F):
    out = []
    for f in F:
        out.append((f[0], f[1], f[2]))
        if len(f) == 4:
            out.append((f[0], f[2], f[3]))
    return np.array(out, np.int64)


def bezier(pts, n):
    pts = [np.asarray(p, float) for p in pts]
    out = []
    for i in range(n + 1):
        u = i / n
        q = list(pts)
        while len(q) > 1:
            q = [q[k] * (1 - u) + q[k + 1] * u for k in range(len(q) - 1)]
        out.append(q[0])
    return out


def tube(path, r, segs, flat=1.0):
    P, F = [], []
    for i, p in enumerate(path):
        d = unit(path[min(i + 1, len(path) - 1)] - path[max(i - 1, 0)])
        a = unit(np.cross(d, np.array([0, 1.0, 0.0])) if abs(d[1]) < 0.9 else np.cross(d, np.array([1.0, 0, 0])))
        b = np.cross(d, a)
        for j in range(segs):
            t = 2 * math.pi * j / segs
            P.append(p + (a * math.cos(t) * flat + b * math.sin(t)) * r)
    for i in range(len(path) - 1):
        for j in range(segs):
            jj = (j + 1) % segs
            F.append((i * segs + j, i * segs + jj, (i + 1) * segs + jj, (i + 1) * segs + j))
    P = np.array(P)
    F = [f if np.cross(P[f[1]] - P[f[0]], P[f[2]] - P[f[0]]) @ (P[f[0]] - path[f[0] // segs]) >= 0 else tuple(reversed(f))
         for f in F]
    return P, F


def cylinder(a, b, r0, r1, segs):
    a, b = np.asarray(a, float), np.asarray(b, float)
    d = unit(b - a)
    x = unit(np.cross(d, np.array([0, 1.0, 0])) if abs(d[1]) < 0.9 else np.cross(d, np.array([1.0, 0, 0])))
    y = np.cross(d, x)
    P = []
    for c, r in ((a, r0), (b, r1)):
        for j in range(segs):
            t = 2 * math.pi * j / segs
            P.append(c + (x * math.cos(t) + y * math.sin(t)) * r)
    P.append(a)
    P.append(b)
    F = []
    for j in range(segs):
        jj = (j + 1) % segs
        F.append((j, jj, segs + jj, segs + j))
        F.append((2 * segs, jj, j))
        F.append((2 * segs + 1, segs + j, segs + jj))
    P = np.array(P)
    ctr = (a + b) / 2
    F = [f if np.cross(P[f[1]] - P[f[0]], P[f[2]] - P[f[0]]) @ (np.mean(P[list(f)], 0) - ctr) >= 0 else tuple(reversed(f))
         for f in F]
    return P, F


# ═════════════════════════════════════════════════════════════════════════════
# a head
# ═════════════════════════════════════════════════════════════════════════════
CANON = dict(eye=C_EYE_T, eye_s=C_EYE_S, brow=C_BROW_T, nose=C_NOSE_T, mouth=C_MOUTH_T, chin=C_CHIN_T,
             mouth_w=C_MOUTH_W)


def mouth_parts(hd):
    """The teeth and the tongue behind the lips (the base's own mouth bag
    is the cavity). (positions, faces, colours, bone per point)"""
    out = []
    lm, P = hd["lm"], hd["P"]
    my = lm["mouth_y"]
    zf = GB._surface_z(P, 0.0, my, r=0.003) - 0.0125
    # teeth one by one along each arch: a front face each, a dark gap between
    # (an even band reads as a plank), the lower set short (the lip hides it)
    for nm, ytop, ybot, bone in (("upper", my + 0.0115, my - 0.0012, "FaceRoot"), ("lower", my - 0.0045, my - 0.0100, "Jaw")):
        Pt, Ft, Ct = [], [], []
        widths = [0.0042, 0.0034, 0.0038, 0.0034, 0.0034]        # incisors, lateral, canine, premolars
        xs = []
        x = 0.0
        for w in widths:
            xs.append((x, x + w))
            x += w + 0.0003
        rr = 0.024
        for sd in (-1, 1):
            for k, (x0, x1) in enumerate(xs):
                base = len(Pt)
                for xx in (x0, (x0 + x1) / 2, x1):
                    a_ = sd * xx / rr
                    px, pz = math.sin(a_) * rr, zf - (1 - math.cos(a_)) * rr * 1.25 - k * 0.0004
                    tip = ybot if nm == "upper" else ytop
                    root = ytop if nm == "upper" else ybot
                    # incisors longest; the edge rounded at the corners
                    edge = tip + (0.0006 if nm == "upper" else -0.0006) * (k / 4)
                    # the gum above (below, for the lower set), then the crown
                    gum = root
                    root = (tip + (root - tip) * 0.62)
                    Pt.append(np.array([px, gum, pz - 0.0008]))
                    Ct.append((0.30, 0.10, 0.10))
                    for yy, sh in ((root, 0.62), (edge, 1.0)):
                        Pt.append(np.array([px, yy, pz]))
                        # each tooth's sides dark: the gaps between them are
                        # what makes a row of teeth read as teeth
                        side = 0.32 if xx in (x0, x1) else 1.0
                        v = sh * side * (1.0 - 0.07 * k) * (1.0 if nm == "upper" else 0.7)
                        Ct.append((0.97 * v, 0.95 * v, 0.88 * v))
                for j in range(2):
                    q = base + 3 * j
                    Ft.append((q, q + 1, q + 4, q + 3))          # gum → crown root
                    Ft.append((q + 1, q + 2, q + 5, q + 4))      # crown
        Pt = np.array(Pt)
        out.append(("FaceMouth", Pt, orient(Pt, Ft, np.array([0, my, zf - 0.03])), Ct, [bone] * len(Pt)))
    # the tongue: low and well back on the floor of the mouth, in its shadow
    # (forward and lit it reads as a tongue hanging out)
    Pq, Fq, _ = sphere(np.array([0, my - 0.0175, zf - 0.030]), 1.0, np.array([0, 0, 1.0]), nu=12, nv=8,
                       scale=(0.0135, 0.0045, 0.016))
    out.append(("FaceMouth", np.array(Pq), Fq, [(0.20, 0.06, 0.06)] * len(Pq), ["Jaw"] * len(Pq)))
    # the back of the mouth: a dark mass filling the cavity behind the teeth,
    # its lower half on the jaw, so however wide the mouth opens nothing behind
    # it shows — not the throat's skin seen from inside, not the suit's neck
    # (tools/perf/neck_check.py sweeps for exactly that)
    Pb, Fb, _ = sphere(np.array([0, my - 0.010, zf - 0.040]), 1.0, np.array([0, 0, 1.0]), nu=16, nv=10,
                       scale=(0.023, 0.020, 0.024))
    Pb = np.array(Pb)
    out.append(("FaceMouth", Pb, Fb, [(0.05, 0.012, 0.012)] * len(Pb),
                ["Jaw" if p[1] < my - 0.010 else "FaceRoot" for p in Pb]))
    return out


def enclosed(P, Q, N, idx, reach=0.09):
    """Of the points idx, those whose outward ray (along the normal) hits the
    mesh within `reach`: surfaces facing into a cavity, not the open air."""
    T = np.array([(q[0], q[1], q[2]) for q in Q] + [(q[0], q[2], q[3]) for q in Q])
    v0, v1, v2 = P[T[:, 0]], P[T[:, 1]], P[T[:, 2]]
    e1, e2 = v1 - v0, v2 - v0
    out = np.zeros(len(P), bool)

    def hits(o, d):
        p = np.cross(d, e2)
        det = (e1 * p).sum(1)
        ok = np.abs(det) > 1e-14
        inv = np.where(ok, 1.0 / np.where(ok, det, 1), 0)
        s_ = o - v0
        u = (s_ * p).sum(1) * inv
        q = np.cross(s_, e1)
        v = (q @ d) * inv
        t = (e2 * q).sum(1) * inv
        return bool((ok & (u >= 0) & (v >= 0) & (u + v <= 1) & (t > 1e-5) & (t < reach)).any())
    for i in idx:
        n = N[i]
        a = unit(np.cross(n, [0.0, 1.0, 0.0]) if abs(n[1]) < 0.9 else np.cross(n, [1.0, 0.0, 0.0]))
        b = np.cross(n, a)
        o = P[i] + n * 2e-4
        # five rays (the normal and four tipped 30°): a thin seam (the lips'
        # meeting line) lets one through, not most
        dirs_ = [n] + [unit(n + 0.58 * w) for w in (a, -a, b, -b)]
        out[i] = sum(hits(o, d) for d in dirs_) >= 3
    return out


def build_head(h):
    """Structure h: the parts (per material: positions, normals, uvs, colours,
    raw weights, triangles) and the head's data (landmarks, bones, lids)."""
    hd = GB.head(h)
    hd["lid"] = GB.lid_geometry(hd)
    hd["lid_split"] = {n: hd["lid"][n]["split"] for n in ("L", "R")}
    P, Q, lm = hd["P"], [tuple(q) for q in hd["Q"]], hd["lm"]
    hd["J"] = GB.bone_points(hd)
    W = GB.weights(hd)
    N = normals(P, Q)
    s, t = GB.canonical(P, lm, CANON)
    u, v = uv_of(s, t)
    # the cavities (the mouth's inside, the nostrils, behind the lids) darken;
    # only in the face, where the depth measure means that
    facezone = smooth(-0.005, 0.03, P[:, 2]) * smooth(lm["chin_low"] - 0.005, lm["chin_low"] + 0.01, P[:, 1]) \
        * smooth(0.055, 0.045, np.abs(P[:, 0]))
    dp = GB.depth(P)
    # (only where a cavity really is: the nostrils; the mouth is below. On
    # the open face a deep crease is the sculpt's own shading, and darkening
    # it painted smudges on the more lined heads)
    ny_ = lm["nose"][1]
    nostrils = (np.abs(P[:, 0]) < 0.016) & (P[:, 1] > ny_ - 0.016) & (P[:, 1] < ny_ + 0.004) & (P[:, 2] > lm["nose"][2] - 0.03)
    occ = 1 - 0.9 * smooth(0.016, 0.034, dp) * facezone * nostrils
    # inside the lips: the mouth's wet dark lining — every surface in the
    # mouth's zone behind the lips' front that faces back or across, from
    # just behind where the lips meet
    my_, mw_ = lm["mouth_y"], lm["mouth_w"]
    zfront = GB._surface_z(P, 0.0, my_, r=0.003)
    zone = (np.abs(P[:, 0]) < mw_ + 0.004) & (P[:, 1] > my_ - 0.035) & (P[:, 1] < my_ + 0.03)
    inner = zone & (P[:, 2] < zfront - 0.0025 - 0.15 * (P[:, 0] / max(mw_, 1e-3)) ** 2 * 0.02) & (N[:, 2] < 0.35)

    # …and every surface in the mouth's box that is INSIDE the head: a ray
    # out along its normal hits the head again (the bag's walls, its back,
    # the throat's inside), where the outer skin's ray escapes. (The depth
    # measure is blind straight down, where the neck runs on under them.)
    box = (np.abs(P[:, 0]) < 0.040) & (P[:, 1] > my_ - 0.045) & (P[:, 1] < my_ + 0.035) & (P[:, 2] < zfront - 0.004)
    inside = enclosed(P, Q, N, np.where(box)[0])
    # (an outer surface under an overhang — the chin under the lower lip, the
    # lip under the nose — also sends its ray into the head: those are near
    # the outer skin and in front, so they are left out)
    inside = inside & ((N[:, 2] < 0.5) | (P[:, 2] < zfront - 0.022))
    inner = inner | inside
    # the lips' meeting surfaces: at rest they press together (the lower
    # lip's faces up, the upper's down); open, they are the wet inside of the
    # lips — dark, never the lip's own colour (else a jaw drop shows a pink
    # slab that reads as a tongue)
    contact = (np.abs(P[:, 0]) < mw_ + 0.003) & (np.abs(P[:, 1] - my_) < 0.012) & (P[:, 2] > zfront - 0.03) & \
        (((P[:, 1] < my_ + 0.0005) & (N[:, 1] > 0.22)) | ((P[:, 1] > my_ - 0.0005) & (N[:, 1] < -0.22)))
    occ = np.where(inner, np.minimum(occ, 0.08), occ)
    occ = np.where(contact & ~inner, np.minimum(occ, 0.12), occ)
    inner = inner | contact
    # (A is stored as 0.55 + 0.45 × open: the engine cuts a hole where a
    # vertex's alpha is under 0.5 on an opaque surface, so a dark mouth
    # lining at alpha 0.1 was not drawn at all — the far side showed through)
    C = np.hstack([vertex_masks(s, t), (0.55 + 0.45 * occ)[:, None]])
    # the lips' colour from the head itself, in millimetres about the mouth's
    # line (the canonical layout put it a lip's height too low on some heads,
    # so an open mouth showed a tall pink "lower lip" that read as a tongue)
    xr = np.clip(np.abs(P[:, 0]) / max(mw_, 1e-3), 0, 1.2)
    up_h = (0.0075 + 0.0012 * np.exp(-(P[:, 0] / 0.004) ** 2)) * np.clip(1 - xr ** 2, 0, 1) ** 0.5
    lo_h = 0.0095 * np.clip(1 - xr ** 2, 0, 1) ** 0.6
    dy = P[:, 1] - my_
    lipv = np.where(dy >= 0, smooth(up_h + 0.0012, up_h - 0.0012, dy), smooth(lo_h + 0.0015, lo_h - 0.0015, -dy))
    lipv = lipv * smooth(1.08, 0.92, xr) * smooth(zfront - 0.016, zfront - 0.010, P[:, 2]) * smooth(0.1, 0.45, N[:, 2])
    C[:, 0] = np.where(inner, 0.0, lipv)
    C[inner, 0] = 0.0                       # no lip colour on the lining
    parts = {}

    def put(mat, P_, N_, UV_, C_, Wraw, F_):
        e = parts.setdefault(mat, dict(P=[], N=[], UV=[], C=[], W=[], I=[], n=0))
        C_ = np.asarray(C_, float)
        if C_.shape[1] == 3:
            C_ = np.hstack([C_, np.ones((len(C_), 1))])
        e["P"].append(np.asarray(P_))
        e["N"].append(np.asarray(N_))
        e["UV"].append(np.asarray(UV_, float))
        e["C"].append(C_)
        e["W"].append(np.asarray(Wraw))
        e["I"].append(tris(F_) + e["n"])
        e["n"] += len(P_)
    put("FaceSkin", P, N, np.stack([u, v], 1), C, W, Q)
    for sd, nm in ((1, "L"), (-1, "R")):
        c = hd["eyes"][nm]
        re = lm["re"] * 0.985
        Pe, Fe, UVe = sphere(c, re, unit(np.array([sd * 0.03, 0.0, 1.0])), nu=24, nv=16)
        Pe = np.array(Pe)
        We = np.zeros((len(Pe), len(BONES)))
        We[:, BI["Eye" + nm]] = 1
        put("FaceEye", Pe, unit(Pe - c), UVe, np.ones((len(Pe), 3)), We, Fe)
    for mat, Pm, Fm, Cm, bones in mouth_parts(hd):
        Wm = np.zeros((len(Pm), len(BONES)))
        for i, b in enumerate(bones):
            Wm[i, BI[b]] = 1
        put(mat, Pm, normals(Pm, Fm), np.zeros((len(Pm), 2)), Cm, Wm, Fm)
    return parts, hd


# ═════════════════════════════════════════════════════════════════════════════
# textures (canonical space: one set for every head)
# ═════════════════════════════════════════════════════════════════════════════

def g2(s, t, p, q, sp, sq, sym=True):
    e = np.exp(-(((s - p) / sp) ** 2 + ((t - q) / sq) ** 2))
    if sym and p != 0:
        e = e + np.exp(-(((s + p) / sp) ** 2 + ((t - q) / sq) ** 2))
    return e


def lips_mask(s, t):
    a = np.abs(s)
    mt = C_MOUTH_T
    bow = 0.010 * np.exp(-(s / 0.04) ** 2) - 0.008 * np.exp(-((a - 0.06) / 0.04) ** 2)
    up_h = (0.030 + bow) * np.clip(1 - (s / (C_MOUTH_W + 0.01)) ** 2, 0, 1) ** 0.6
    lo_h = 0.042 * np.clip(1 - (s / (C_MOUTH_W - 0.005)) ** 2, 0, 1) ** 0.7
    m = np.where(t >= mt, smooth(up_h + 0.004, up_h - 0.006, t - mt), smooth(lo_h + 0.005, lo_h - 0.008, mt - t))
    return m * smooth(C_MOUTH_W + 0.02, C_MOUTH_W - 0.01, a)


def warm_mask(s, t):
    w = 0.8 * g2(s, t, 0.50, -0.18, 0.18, 0.12) + 0.6 * g2(s, t, 0.0, C_NOSE_T, 0.06, 0.06) \
        + 0.7 * g2(s, t, 1.52, -0.03, 0.12, 0.15) + 0.4 * g2(s, t, 0.0, C_MOUTH_T, 0.24, 0.06) \
        + 0.25 * g2(s, t, 0.0, 0.32, 0.4, 0.15)
    return np.clip(w, 0, 1)


def freckle_zone(s, t):
    z = g2(s, t, 0.0, C_NOSE_T + 0.05, 0.12, 0.08) + g2(s, t, 0.45, -0.10, 0.22, 0.12)
    return np.clip(0.25 + 0.75 * z, 0, 1) * smooth(-0.9, -0.6, t)


def vertex_masks(s, t):
    """COLOR_0 on the skin: R lips, G warmth, B freckles' zone, A 1."""
    return np.stack([lips_mask(s, t), warm_mask(s, t), freckle_zone(s, t)], 1)


def scalp_field(s, t):
    """Canonical (s, t) → the base head's (φ, θ) (the inverse of
    gen_faces_base.canonical above the brow) → distance from the hairline."""
    b = GB.base()
    lm = b["lm"]
    P = b["P"]
    pe, te = GB.angles(np.array([lm["eyeL"]]))
    pm, tm = GB.angles(np.array([lm["cornerL"]]))
    _, tn = GB.angles(np.array([lm["nose"]]))
    _, tc = GB.angles(np.array([lm["chin"]]))
    _, tb = GB.angles(np.array([[0.02, lm["eye_y"] + 0.022, GB._surface_z(P, 0.02, lm["eye_y"] + 0.022)]]))
    pe, te, pm, tm, tn, tc, tb = (float(x[0]) for x in (pe, te, pm, tm, tn, tc, tb))
    th = np.interp(t, [-np.pi / 2, C_CHIN_T, C_MOUTH_T, C_NOSE_T, C_EYE_T, C_BROW_T, np.pi / 2],
                   [-np.pi / 2, tc, tm, tn, te, tb, np.pi / 2])
    k_e, k_m = C_EYE_S / pe, C_MOUTH_W / pm
    k0 = np.interp(th, [tm, te], [k_m, k_e])
    phi = s / k0
    for _ in range(8):
        a = np.abs(phi)
        k = np.where(a < 0.8, k0, k0 + (1 - k0) * smooth(0.8, 1.4, a))
        phi = s / k
    d = th - GH.hairline_edge(phi)
    return np.clip(0.5 + d / 0.35, 0, 1)


def textures(n=512):
    rng = np.random.default_rng(1969)
    vv, uu = (np.mgrid[0:n, 0:n] + 0.5) / n
    s, t = st_of_uv(uu, vv)
    a = np.abs(s)

    def g(p, q, sp, sq, sym=True):
        e = np.exp(-(((s - p) / sp) ** 2 + ((t - q) / sq) ** 2))
        if sym and p != 0:
            e = e + np.exp(-(((s + p) / sp) ** 2 + ((t - q) / sq) ** 2))
        return e
    fine = spectral(n, n, rng, beta=0.4, lo=90)
    mid = spectral(n, n, rng, beta=1.4, lo=20)
    low = spectral(n, n, rng, beta=2.2, lo=4)
    mt = C_MOUTH_T
    # ── R: cavity / AO (1 flat) ──
    cav = np.ones((n, n))
    rimL = np.minimum(almond(s, t, 1), almond(s, t, -1))
    cav -= 0.50 * smooth(1.6, 1.0, rimL)                         # the lash line and the socket's edge
    cav -= 0.18 * smooth(3.2, 1.3, rimL) * (t > C_EYE_T - 0.02)  # under the brow
    cav -= 0.25 * g(C_EYE_S - EYE_HW, C_EYE_T, 0.03, 0.02)       # the inner corners
    cav -= 0.12 * g(C_EYE_S, C_EYE_T - 0.07, 0.10, 0.025)        # under the eyes
    cav -= 0.55 * g(0.075, C_NOSE_T - 0.035, 0.022, 0.012)       # nostrils
    cav -= 0.25 * g(0.0, C_NOSE_T - 0.06, 0.07, 0.02)            # under the nose
    # nasolabial folds: from beside the nose's wings to past the mouth's corners
    for sd in (-1, 1):
        x0, y0, x1, y1 = sd * 0.13, C_NOSE_T - 0.02, sd * 0.27, mt - 0.06
        u = np.clip(((s - x0) * (x1 - x0) + (t - y0) * (y1 - y0)) / ((x1 - x0) ** 2 + (y1 - y0) ** 2), 0, 1)
        dist = np.hypot(s - (x0 + u * (x1 - x0)), t - (y0 + u * (y1 - y0)))
        cav -= 0.16 * np.exp(-(dist / 0.014) ** 2) * (1 - u * 0.5)
    cav -= 0.6 * np.exp(-((t - mt) / 0.006) ** 2) * smooth(C_MOUTH_W + 0.02, C_MOUTH_W - 0.03, a)   # the lip line
    cav -= 0.25 * g(C_MOUTH_W + 0.005, mt, 0.02, 0.02)          # the corners
    cav -= 0.15 * g(0.0, mt - 0.09, 0.12, 0.018)                 # under the lower lip
    cav -= 0.25 * g(1.52, -0.03, 0.08, 0.12)                     # the ear's bowl
    cav -= 0.08 * (mid - 0.5)
    cav = np.clip(cav, 0, 1)
    # ── G: stubble (density) ──
    beard = smooth(-0.33, -0.48, t) * smooth(1.55, 1.25, a)
    beard = np.maximum(beard, g(0.0, mt + 0.055, 0.17, 0.035) * 1.0)        # moustache
    beard = np.maximum(beard, smooth(-0.20, -0.33, t) * smooth(0.5, 0.75, a) * smooth(1.45, 1.2, a))  # cheeks
    beard *= 1 - np.exp(-((t - mt) / 0.012) ** 2 - (s / 0.2) ** 6)          # not on the lips
    beard *= 1 - 0.85 * g(0.0, mt - 0.030, 0.17, 0.022)
    beard *= smooth(-1.45, -1.15, t)                                         # fades down the throat
    dots = (fine > 0.52).astype(float)
    stub = np.clip(beard * (0.35 + 0.65 * dots) * (0.8 + 0.4 * mid), 0, 1)
    # ── B: freckles / spots ──
    fz = 0.35 + 0.65 * (g(0.0, C_NOSE_T + 0.05, 0.12, 0.08) + g(0.45, -0.10, 0.22, 0.12))
    spots = smooth(0.62, 0.70, spectral(n, n, rng, beta=0.5, lo=60))
    frk = np.clip(spots * np.clip(fz, 0, 1) * smooth(-0.9, -0.6, t), 0, 1)
    frk = np.maximum(frk, 0.25 * (low - 0.5) + 0.0)
    frk = np.clip(frk, 0, 1)
    # ── A: wrinkles (soft: the sculpt has the folds; these are age's fine lines) ──
    wr = np.zeros((n, n))
    for k, y in enumerate((0.36, 0.43, 0.50)):
        wave = y + 0.015 * np.sin(s * 4 + k * 1.7) + 0.006 * (mid - 0.5)
        wr += 0.35 * np.exp(-((t - wave) / 0.011) ** 2) * smooth(0.65, 0.2, a) * (0.5 + 0.5 * mid)
    for sd in (-1, 1):
        ox = sd * (C_EYE_S + EYE_HW + 0.015)
        for k in range(3):
            ang = -0.45 + 0.4 * k
            dx, dy = math.cos(ang), math.sin(ang)
            u = ((s - ox) * sd * dx + (t - C_EYE_T) * dy)
            perp = np.abs(-(s - ox) * sd * dy + (t - C_EYE_T) * dx)
            wr += 0.25 * np.exp(-(perp / 0.008) ** 2) * smooth(0.0, 0.015, u) * smooth(0.09, 0.03, u)
    wr += 0.25 * g(0.05, C_BROW_T - 0.02, 0.012, 0.04)             # frown lines between the brows
    wr += 0.15 * g(C_EYE_S, C_EYE_T - 0.075, 0.08, 0.015)          # under the eyes
    wr = np.clip(wr, 0, 1)
    # ── marks R: lips ──
    bow = 0.010 * np.exp(-(s / 0.04) ** 2) - 0.008 * np.exp(-((a - 0.06) / 0.04) ** 2)
    up_h = (0.030 + bow) * np.clip(1 - (s / (C_MOUTH_W + 0.01)) ** 2, 0, 1) ** 0.6
    lo_h = 0.042 * np.clip(1 - (s / (C_MOUTH_W - 0.005)) ** 2, 0, 1) ** 0.7
    lips = np.where(t >= mt, smooth(up_h + 0.004, up_h - 0.006, t - mt), smooth(lo_h + 0.005, lo_h - 0.008, mt - t))
    lips *= smooth(C_MOUTH_W + 0.02, C_MOUTH_W - 0.01, a)
    # ── marks G: brows (a density field: 1 in the thick of it, falling off) ──
    brows = np.zeros((n, n))
    for sd in (-1, 1):
        x = (s * sd - 0.13) / 0.42                                  # 0 at the inner end .. 1 the tail
        arc = C_BROW_T + 0.020 * np.sin(np.clip(x, 0, 1) * math.pi * 0.85) - 0.012 * np.clip(x, 0, 1)
        thick = 0.034 * (1 - 0.55 * np.clip(x, 0, 1))
        core = np.exp(-((t - arc) / thick) ** 2) * smooth(-0.08, 0.04, x) * smooth(1.12, 0.92, x)
        brows = np.maximum(brows, core)
    hairs = spectral(n, n, rng, beta=0.6, sx=1.0, sy=0.25, lo=40)
    brows = np.clip(brows * (0.7 + 0.6 * hairs), 0, 1)
    # soft edges: a brow is hairs on skin, not a line
    for _ in range(2):
        brows = (brows * 4 + np.roll(brows, 1, 0) + np.roll(brows, -1, 0) + np.roll(brows, 1, 1) + np.roll(brows, -1, 1)) / 8
    # ── marks B: scars, each in its own column of u (face.lua picks one) ──
    scar = np.zeros((n, n))
    # 1: through the left brow (u < 0.45)
    scar += np.exp(-(((s + 0.30) + (t - 0.20) * 0.35) / 0.008) ** 2) * smooth(0.10, 0.13, t) * smooth(0.30, 0.27, t)
    # 2: across the right cheek (u > 0.6)
    scar += np.exp(-(((t + 0.20) - (s - 0.62) * 0.45) / 0.007) ** 2) * smooth(0.52, 0.56, s) * smooth(0.78, 0.74, s)
    # 3: the chin (|s| < 0.12)
    scar += np.exp(-(((s - 0.03) - (t + 0.74) * 0.6) / 0.007) ** 2) * smooth(-0.80, -0.77, t) * smooth(-0.66, -0.69, t)
    scar = np.clip(scar, 0, 1)
    # ── marks A: warmth (blood under the skin: cheeks, nose, ears, lips) ──
    warm = 0.8 * g(0.50, -0.18, 0.18, 0.12) + 0.6 * g(0.0, C_NOSE_T, 0.06, 0.06) + 0.7 * g(1.52, -0.03, 0.12, 0.15)
    warm += 0.4 * g(0.0, mt, 0.24, 0.06) + 0.25 * g(0.0, 0.32, 0.4, 0.15)
    warm = np.clip(warm * (0.8 + 0.4 * low), 0, 1)
    os.makedirs(TEXDIR, exist_ok=True)

    def save4(chs, name):
        arr = np.stack([np.clip(c, 0, 1) for c in chs], -1)
        Image.fromarray((arr * 255 + 0.5).astype(np.uint8), "RGBA").save(os.path.join(TEXDIR, name), optimize=True)
    # (the creases are the sculpt's own and the cavities are in the vertex
    # colour: the painted cavity is only a breath of the lip line now)
    # R: the scalp, as a distance from the (normal) hairline: 0.5 on it, up
    # under the hair, down on the forehead — face_skin.flsl shades the scalp
    # under the hair and the fine hairs at its edge from it (per style: a
    # shift for a high or a low line)
    cav = scalp_field(s, t)
    save4([cav, stub, brows, wr], "skin_detail.png")
    del frk, lips, scar, warm
    hgt = (fine - 0.5) * 0.35 + (mid - 0.5) * 0.25 - wr * 0.9 - (1 - cav) * 0.4
    nm = normal_from_height(hgt, 2.0)
    Image.fromarray((np.clip(nm, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB").save(os.path.join(TEXDIR, "skin_normal.png"),
                                                                                 optimize=True)
    # the hair cards' atlas (tools/gen_faces_hair.py)
    hc = GH.hair_texture()
    Image.fromarray((np.clip(hc, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA").save(os.path.join(TEXDIR, "hair_cards.png"),
                                                                                optimize=True)
    # the scars, as segments in uv (face.lua hands one to the shader)
    out = []
    for (s0, t0), (s1, t1) in (((-0.335, 0.29), (-0.27, 0.12)), ((0.54, -0.236), (0.76, -0.137)),
                               ((-0.006, -0.80), (0.078, -0.66))):
        u0, v0 = uv_of(np.array(s0), np.array(t0))
        u1, v1 = uv_of(np.array(s1), np.array(t1))
        out.append((float(u0), float(v0), float(u1), float(v1)))
    return out


# ═════════════════════════════════════════════════════════════════════════════
# writing
# ═════════════════════════════════════════════════════════════════════════════

class Glb:
    def __init__(self):
        self.bin = bytearray()
        self.views, self.accs, self.prims, self.mats = [], [], [], []

    def view(self, data, target=None):
        while len(self.bin) % 4:
            self.bin += b"\0"
        v = {"buffer": 0, "byteOffset": len(self.bin), "byteLength": len(data)}
        self.bin += data
        if target:
            v["target"] = target
        self.views.append(v)
        return len(self.views) - 1

    def acc(self, arr, ct, ty, norm=False, minmax=False):
        a = {"bufferView": self.view(arr.tobytes(), 34962), "componentType": ct, "count": len(arr), "type": ty}
        if norm:
            a["normalized"] = True
        if minmax:
            a["min"] = arr.min(0).tolist()
            a["max"] = arr.max(0).tolist()
        self.accs.append(a)
        return len(self.accs) - 1

    def prim(self, mat, P, N, UV, C, I, J=None, W=None):
        P = np.asarray(P, np.float32)
        attrs = {"POSITION": self.acc(P, 5126, "VEC3", minmax=True),
                 "NORMAL": self.acc(unit(np.asarray(N, float)).astype(np.float32), 5126, "VEC3"),
                 "TEXCOORD_0": self.acc(np.asarray(UV, np.float32), 5126, "VEC2"),
                 "COLOR_0": self.acc(np.round((np.clip(C, 0, 1) if np.shape(C)[1] == 4 else
                                               np.hstack([np.clip(C, 0, 1), np.ones((len(P), 1))])) * 255).astype(np.uint8),
                                     5121, "VEC4", norm=True)}
        if J is not None:
            Wb = np.round(np.asarray(W) * 255).astype(np.int32)
            Wb[np.arange(len(Wb)), Wb.argmax(1)] += 255 - Wb.sum(1)
            attrs["JOINTS_0"] = self.acc(np.asarray(J).astype(np.uint8), 5121, "VEC4")
            attrs["WEIGHTS_0"] = self.acc(Wb.astype(np.uint8), 5121, "VEC4", norm=True)
        I = np.asarray(I).reshape(-1)
        self.accs.append({"bufferView": self.view(I.astype(np.uint16 if len(P) < 65536 else np.uint32).tobytes(), 34963),
                          "componentType": 5123 if len(P) < 65536 else 5125, "count": len(I), "type": "SCALAR"})
        self.mats.append({"name": mat, "pbrMetallicRoughness": {"baseColorFactor": [1, 1, 1, 1], "metallicFactor": 0.0,
                                                                "roughnessFactor": 0.7}})
        self.prims.append({"attributes": attrs, "indices": len(self.accs) - 1, "material": len(self.mats) - 1})

    def write(self, path, gl):
        gl.update({"materials": self.mats, "accessors": self.accs, "bufferViews": self.views,
                   "buffers": [{"byteLength": len(self.bin)}]})
        js = json.dumps(gl, separators=(",", ":")).encode()
        while len(js) % 4:
            js += b" "
        while len(self.bin) % 4:
            self.bin += b"\0"
        with open(path, "wb") as f:
            f.write(struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(self.bin)))
            f.write(struct.pack("<II", len(js), 0x4E4F534A))
            f.write(js)
            f.write(struct.pack("<II", len(self.bin), 0x004E4942))
            f.write(bytes(self.bin))


COPYRIGHT = "Solar crew faces (tools/gen_faces.py), CC0."


def anchor(e, weighted=False):
    """Two zero-area triangles pinning the box to HC ± BOX (everything else
    must be inside it, or the engine's centring moves the model)."""
    allP = np.vstack(e["P"])
    assert np.all(np.abs(allP) <= BOX), f"outside the anchor box: {np.abs(allP).max(0)}"
    A = np.array([-BOX, -BOX + [1e-4, 0, 0], -BOX + [0, 1e-4, 0], BOX, BOX - [1e-4, 0, 0], BOX - [0, 1e-4, 0]])
    A = A * np.array([1, 1, 1])
    n = e["n"]
    e["P"].append(A)
    e["N"].append(np.tile([0, 1.0, 0], (6, 1)))
    e["UV"].append(np.zeros((6, 2)))
    e["C"].append(np.ones((6, 4 if e["C"] and np.shape(e["C"][0])[1] == 4 else 3)))
    if weighted:
        e["W"].append(np.zeros((6, len(BONES))))
    e["I"].append(np.array([[n, n + 1, n + 2], [n + 3, n + 5, n + 4]]))
    e["n"] += 6


def write_head(parts, hd, path):
    g = Glb()
    anchor(parts["FaceSkin"], weighted=True)
    J = hd["J"]
    for mat in ("FaceSkin", "FaceEye", "FaceMouth"):
        e = parts[mat]
        P = np.vstack(e["P"]) + HC
        Jw, Ww = top4(np.vstack(e["W"]))
        g.prim(mat, P, np.vstack(e["N"]), np.vstack(e["UV"]), np.vstack(e["C"]), np.vstack(e["I"]), Jw, Ww)
    # the skeleton: FaceRoot at HC, the rest under it (LipLower under Jaw)
    nodes = []
    for b in BONES:
        par = PARENT.get(b)
        loc = (J[b] - (J[par] if par else -HC)) if par else HC
        if par:
            loc = J[b] - J[par]
        nodes.append({"name": b, "translation": [float(x) for x in loc]})
        del loc
    for b in BONES:
        kids = [BI[c] for c in BONES if PARENT.get(c) == b]
        if kids:
            nodes[BI[b]]["children"] = kids
    ibm = np.zeros((len(BONES), 4, 4), np.float32)
    for i, b in enumerate(BONES):
        M = np.eye(4)
        M[:3, 3] = -(J[b] + HC)
        ibm[i] = M.T                                            # column-major
    g.accs.append({"bufferView": g.view(ibm.tobytes()), "componentType": 5126, "count": len(BONES), "type": "MAT4"})
    mesh_node = len(nodes)
    nodes.append({"name": "FaceHead", "mesh": 0, "skin": 0})
    g.write(path, {"asset": {"version": "2.0", "generator": "Solar tools/gen_faces.py", "copyright": COPYRIGHT},
                   "scene": 0, "scenes": [{"nodes": [0, mesh_node]}], "nodes": nodes,
                   "meshes": [{"name": "FaceHead", "primitives": g.prims}],
                   "skins": [{"joints": list(range(len(BONES))), "inverseBindMatrices": len(g.accs) - 1,
                              "skeleton": 0}]})
    return sum(len(np.vstack(parts[m]["I"])) for m in parts)


def write_static(parts, path, name):
    g = Glb()
    for e in parts.values():
        assert np.all(np.abs(np.vstack(e["P"])) <= BOX), f"{name}: outside the anchor box"
    first = next(iter(parts))
    anchor(parts[first])
    for mat, e in parts.items():
        g.prim(mat, np.vstack(e["P"]) + HC, np.vstack(e["N"]), np.vstack(e["UV"]), np.vstack(e["C"]), np.vstack(e["I"]))
    g.write(path, {"asset": {"version": "2.0", "generator": "Solar tools/gen_faces.py", "copyright": COPYRIGHT},
                   "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"name": name, "mesh": 0}],
                   "meshes": [{"name": name, "primitives": g.prims}]})
    return sum(len(np.vstack(e["I"])) for e in parts.values())


def _rot(yaw, pitch):
    """The engine's yaw (about y) then pitch (about x), as face.lua writes them."""
    cy, sy, cp, sp = math.cos(yaw), math.sin(yaw), math.cos(pitch), math.sin(pitch)
    Ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    Rx = np.array([[1, 0, 0], [0, cp, -sp], [0, sp, cp]])
    return Ry @ Rx


def bake_channel(hd, ch, P, Jw, Ww, lid_sign=1.0, jaw_sign=1.0):
    """Vertices P (head-local) skinned (Jw, Ww) with channel `ch` at weight 1:
    the per-vertex offsets (a morph target), by the same data face.lua uses."""
    J = hd["J"]
    lc = (hd["lid"]["L"]["close_up"], hd["lid"]["L"]["close_lo"])
    loc = {b: np.eye(4) for b in BONES}
    for e in channel_entries()[ch]:
        b, dx, dy, dz, yaw, pitch = e[:6]
        k = pitch * ({"up": lc[0], "lo": lc[1]}.get(e[6], 1.0) if len(e) > 6 else 1.0)
        k *= lid_sign if b.startswith("Lid") else (jaw_sign if b == "Jaw" else 1.0)
        M = np.eye(4)
        M[:3, :3] = _rot(yaw, k)
        M[:3, 3] = [dx, dy, dz]
        loc[b] = loc[b] @ M
    world = {}
    for b in BONES:                                   # parents come first in BONES
        par = PARENT.get(b)
        T = np.eye(4)
        T[:3, 3] = J[b] - (J[par] if par else 0)
        base = world[par] if par else np.eye(4)
        world[b] = base @ T @ loc[b]
    skin = np.stack([world[b] @ np.linalg.inv(np.block([[np.eye(3), J[b][:, None]], [np.zeros((1, 3)), np.ones((1, 1))]]))
                     for b in BONES])
    Ph = np.hstack([P, np.ones((len(P), 1))])
    out = np.zeros_like(P)
    for k in range(4):
        Mk = skin[Jw[:, k]]
        out += Ww[:, k:k + 1] * np.einsum("nij,nj->ni", Mk, Ph)[:, :3]
    return out - P


def write_morphs(outdir):
    """Heads with every channel as a named morph target (glTF targets and
    mesh.extras.targetNames), for when the engine imports blend shapes (card
    0572): written to `outdir`, not shipped."""
    os.makedirs(outdir, exist_ok=True)
    names = list(channel_entries())
    for i, h in enumerate(HEADS, start=1):
        parts, hd = build_head(h)
        g = Glb()
        for mat in ("FaceSkin", "FaceEye", "FaceMouth"):
            e = parts[mat]
            P = np.vstack(e["P"])
            Jw, Ww = top4(np.vstack(e["W"]))
            g.prim(mat, P + HC, np.vstack(e["N"]), np.vstack(e["UV"]), np.vstack(e["C"]), np.vstack(e["I"]))
            tg = []
            for ch in names:
                d = bake_channel(hd, ch, P, Jw, Ww).astype(np.float32)
                tg.append({"POSITION": g.acc(d, 5126, "VEC3", minmax=True)})
            g.prims[-1]["targets"] = tg
        g.write(os.path.join(outdir, f"head_{i}_morphs.glb"),
                {"asset": {"version": "2.0", "generator": "Solar tools/gen_faces.py --morphs", "copyright": COPYRIGHT},
                 "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"name": "FaceHead", "mesh": 0}],
                 "meshes": [{"name": "FaceHead", "primitives": g.prims, "weights": [0.0] * len(names),
                             "extras": {"targetNames": names}}]})
        print("morphs", i, len(names), "targets")


def write_lua(heads_meta, scar_u):
    src = open(LUA).read()
    a = src.index("-- @face-rig BEGIN")
    b = src.index("-- @face-rig END")
    lines = ["-- @face-rig BEGIN (tools/gen_faces.py writes this block; don't edit it by hand)"]
    lines.append("RIG = {")
    lines.append("  bones = { " + ", ".join(f'"{b_}"' for b_ in BONES) + " },")
    lines.append("  heads = {")
    for m in heads_meta:
        lines.append(f'    {{ name = "{m["name"]}", fem = {m["fem"]}, model = "models/astronaut/faces/head_{m["i"]}.glb", '
                     f'lidUp = {m["up"]:.4f}, lidLo = {m["lo"]:.4f},')
        lines.append("      rest = { " + ", ".join(f"{x:.5f}" for x in m["rest"]) + " } },")
    lines.append("  },")
    lines.append("  hair = { " + ", ".join(f'"{k}"' for k in STYLES) + " },")
    lines.append("  -- channel = { { bone, dx, dy, dz, yaw, pitch [, scale] } … } (see CHANNEL_MAP)")
    lines.append("  map = {")
    for ch, ents in channel_entries().items():
        es = []
        for e in ents:
            bn, dx, dy, dz, yaw, pitch = e[:6]
            sc = f', "{e[6]}"' if len(e) > 6 else ""
            es.append(f'{{ "{bn}", {dx:g}, {dy:g}, {dz:g}, {yaw:g}, {pitch:g}{sc} }}')
        lines.append(f"    {ch} = {{ " + ", ".join(es) + " },")
    lines.append("  },")
    lines.append("  scars = { " + ", ".join("{ " + ", ".join(f"{x:.4f}" for x in sc) + " }" for sc in scar_u) + " },")
    lines.append("}")
    src = src[:a] + "\n".join(lines) + "\n" + src[b:]
    with open(LUA, "w") as f:
        f.write(src)


# ── the nodes: Face (on the suit's Head bone), Hair and Cap under it ────────
# The attachment offset: the Head bone's inverse bind matrix times the box
# centre (HC), as tools/gen_suit.py's helmet_offset does for the helmet.
FACE_T = (0.0, 0.3024299, 0.0116693)
FACE_Q = (-0.0469754, 2.788e-07, -1.1e-09, 0.998896)
FACE_S = 2.0

MATS = {
    "FaceSkin": ('(\n color: (1.0, 1.0, 1.0),\n texture: Some("textures/faces/skin_detail.png"),\n normal_map: Some("textures/faces/skin_normal.png"),\n'
                 ' normal_strength: 0.5,\n roughness: 0.7,\n metallic: 0.0,\n'
                 ' shader: Some("shaders/face_skin.flsl"),\n shading: Physical,\n)'),
    "FaceEye": ('(\n color: (1.0, 1.0, 1.0),\n roughness: 0.08,\n metallic: 0.0,\n'
                ' shader: Some("shaders/face_eye.flsl"),\n shading: Physical,\n)'),
    "FaceMouth": ('(\n color: (1.0, 1.0, 1.0),\n roughness: 0.4,\n metallic: 0.0,\n'
                  ' shader: Some("shaders/face_mouth.flsl"),\n shading: Physical,\n)'),
    "Hair": ('(\n color: (0.2, 0.15, 0.1),\n texture: Some("textures/faces/hair_cards.png"),\n roughness: 0.78,\n'
             ' metallic: 0.0,\n shading: Physical,\n)'),
    "CapCloth": ('(\n color: (1.0, 1.0, 1.0),\n texture: Some("textures/suit/fabric_albedo.png"),\n'
                 ' roughness: 0.9,\n metallic: 0.0,\n shading: Physical,\n)'),
    "CapShell": '(\n color: (1.0, 1.0, 1.0),\n roughness: 0.45,\n metallic: 0.1,\n shading: Physical,\n)',
}


def _mats(names, ind):
    out = [f"{ind}object_materials: {{"]
    for n in names:
        body = MATS[n].replace("\n ", "\n" + ind + "        ").replace("\n)", "\n" + ind + "    )")
        out.append(f'{ind}    "{n}": {body},')
    out.append(f"{ind}}},")
    return "\n".join(out) + "\n"


def _f(v):
    return repr(float(round(v, 7)))


def face_nodes(parent, first, ind="        ", ids=None):
    """The Face, Hair and Cap nodes as RON at a prefab's depth (`ind` the
    field indent); `parent` the AstroModel's index, `first` the Face's own.
    `ids` (scene): (face id, hair id, cap id, parent id)."""
    o = ind[:-4]
    t, q, s = FACE_T, FACE_Q, FACE_S
    ident = (f"{ind}transform: (\n{ind}    translation: (0.0, 0.0, 0.0),\n{ind}    rotation: (0.0, 0.0, 0.0, 1.0),\n"
             f"{ind}    scale: (1.0, 1.0, 1.0),\n{ind}),\n")
    def idl(k, par_id):
        return (f"{ind}id: Some({ids[k]}),\n{ind}parent_id: Some({par_id}),\n") if ids else ""
    r = (f"{o}// the crew member's face on the suit's Head bone: scripts/face.lua,\n"
         f"{o}// tools/gen_faces.py (its hair, and the comm cap under a helmet)\n"
         f"{o}(\n{ind}name: \"Face\",\n" + ident +
         f"{ind}matter: Mesh(\n{ind}    asset_path: \"models/astronaut/faces/head_1.glb\",\n{ind}),\n" +
         _mats(["FaceSkin", "FaceEye", "FaceMouth"], ind) +
         f"{ind}scripts: [\n{ind}    (\n{ind}        kind: \"face\",\n{ind}        enabled: true,\n"
         f"{ind}        params: [],\n{ind}    ),\n{ind}],\n" + idl(0, ids[3] if ids else 0) +
         f"{ind}parent: Some({parent}),\n"
         f"{ind}attachment: Some((\n{ind}    bone: \"Head\",\n{ind}    offset: (\n"
         f"{ind}        translation: ({_f(t[0])}, {_f(t[1])}, {_f(t[2])}),\n"
         f"{ind}        rotation: ({_f(q[0])}, {_f(q[1])}, {_f(q[2])}, {_f(q[3])}),\n"
         f"{ind}        scale: ({_f(s)}, {_f(s)}, {_f(s)}),\n{ind}    ),\n{ind})),\n{o}),\n")
    for k, (nm, model, mats) in enumerate((("Hair", "hair_crop", ["Hair"]), ("Cap", "cap", ["CapCloth", "CapShell"])), 1):
        r += (f"{o}(\n{ind}name: \"{nm}\",\n" + ident +
              f"{ind}matter: Mesh(\n{ind}    asset_path: \"models/astronaut/faces/{model}.glb\",\n{ind}),\n" +
              _mats(mats, ind) + f"{ind}scripts: [],\n" + idl(k, ids[0] if ids else 0) +
              f"{ind}parent: Some({first}),\n{o}),\n")
    return r


FACE_MARK = "// the crew member's face on the suit's Head bone"


def write_prefabs():
    """Face nodes into the prefabs whose model is the suit (idempotent: an
    earlier block is replaced)."""
    import re
    for pf, model in (("CrewDoll", "AstroModel"), ("CrewBody", "AstroModel"), ("Remains", "Remains Suit")):
        path = os.path.join(ROOT, "prefabs", pf + ".prefab.ron")
        src = open(path).read()
        if FACE_MARK in src:
            src = src[:src.index(FACE_MARK)].rstrip()
            src = src[:src.rindex("\n") + 1] if src.endswith("//") else src
            src = src.rstrip() + "\n]\n"
        names = re.findall(r'^    \(\n        name: "([^"]+)"', src, flags=re.M)
        parent = names.index(model)
        body = src.rstrip()
        assert body.endswith("]"), pf
        body = body[:-1].rstrip()
        if not body.endswith(","):
            body += ","
        open(path, "w").write(body + "\n" + face_nodes(parent, len(names)) + "]\n")
        print(pf, "face nodes under", model, "at", len(names))


def write_scene(path=os.path.join(ROOT, "scenes", "system.ron")):
    import re
    src = open(path).read()
    ind = "            "
    keep_ids = None
    if FACE_MARK in src:
        a = src.index("        " + FACE_MARK)
        e = src.index('name: "Cap",', a)
        e = src.index("\n        ),\n", e) + len("\n        ),\n")
        keep_ids = [int(x.split(")")[0]) for x in src[a:e].split("            id: Some(")[1:]]
        src = src[:a] + src[e:]
    names = [n.split('"')[1] for n in src.split("\n        (\n            name: ")[1:]]
    astro = names.index("AstroModel")
    i = src.index('\n            name: "AstroModel",')
    blk = src[i:src.index("\n        ),\n", i)]
    astro_id = int(blk.split("id: Some(")[1].split(")")[0])
    used = [int(x.split(")")[0]) for x in src.split("            id: Some(")[1:]]
    nid = max(used) + 1
    if keep_ids and len(keep_ids) == 3 and not set(keep_ids) & set(used) and keep_ids == list(range(keep_ids[0], keep_ids[0] + 3)):
        nid = keep_ids[0]              # the nodes keep their ids
    close = src.rindex("\n    ],")
    first = len(names)
    block = face_nodes(astro, first, ind, ids=(nid, nid + 1, nid + 2, astro_id))
    if os.environ.get("FACE_IDS"):
        b0 = int(os.environ["FACE_IDS"])
        block = face_nodes(astro, first, ind, ids=(b0, b0 + 1, b0 + 2, astro_id))
        nid = b0
    src = src[:close] + "\n" + block.rstrip("\n") + src[close:]
    open(path, "w").write(src)
    print("system.ron face nodes, ids", nid, nid + 1, nid + 2, "Face at index", first)


def main():
    if "--morphs" in sys.argv:
        write_morphs(sys.argv[sys.argv.index("--morphs") + 1])
        return
    if "--scene" in sys.argv:
        write_prefabs()
        write_scene()
        return
    dry = "--dry" in sys.argv
    os.makedirs(MODELS, exist_ok=True)
    meta = []
    for i, h in enumerate(HEADS, start=1):
        parts, hd = build_head(h)
        lid = hd["lid"]["L"]
        n = 0
        if not dry:
            n = write_head(parts, hd, os.path.join(MODELS, f"head_{i}.glb"))
        print(f"head_{i} {h['name']:8s} verts {sum(e['n'] for e in parts.values())} tris {n} "
              f"lids up {lid['close_up']:.3f} lo {lid['close_lo']:.3f}")
        J = hd["J"]
        rest = []
        for b in BONES:
            par = PARENT.get(b)
            rest += list(J[b] - J[par]) if par else list(HC)
        meta.append(dict(i=i, name=h["name"], fem=h["fem"], up=lid["close_up"], lo=lid["close_lo"], rest=rest))
    for name in STYLES:
        P, N, UV, F = GH.hair_mesh(name)
        parts = {"Hair": dict(P=[P], N=[N], UV=[UV], C=[np.ones((len(P), 3))], I=[tris(F)], n=len(P))}
        n = 0 if dry else write_static(parts, os.path.join(MODELS, f"hair_{name}.glb"), "Hair")
        print(f"hair_{name} tris {n}")
    parts = GH.cap_mesh(tube, cylinder, bezier, normals, tris, orient)
    n = 0 if dry else write_static(parts, os.path.join(MODELS, "cap.glb"), "Cap")
    print(f"cap tris {n}")
    if not dry:
        scar_u = textures()
        if os.path.exists(LUA):
            write_lua(meta, scar_u)
    print("face centre (bind space)", np.round(HC, 7).tolist())


if __name__ == "__main__":
    main()
