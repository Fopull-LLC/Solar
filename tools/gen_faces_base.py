"""The crew's heads, built on a sculpted base (tools/gen_faces.py imports this).

THE BASE. tools/faces_base/head_base.npz: Blender Studio's "Human Base
Meshes" realistic head with animation topology (CC0; tools/faces_base/
export_base.py pulls it from the bundle): a sculpted skull, brow, cheekbones,
nose, lips, ears and neck, with edge loops round the eyes and the mouth and a
mouth bag behind the lips. 12,950 vertices (its multires level 1).

PLACED on the suit: moved so the eyes sit where the suit's old head had them
and the neck runs down into the neck ring (and is drawn in below the ring's
top, so it never shows through the hard upper torso). Head-local frame:
origin HC (gen_faces.py), x the crew's left, y up, z forward, metres.

EIGHT STRUCTURES are smooth deformations of the base (`deform`), each a sum
of soft fields about the face's landmarks: the face's width and length, the
jaw's width and angle, the chin, cheekbones, brow ridge, the nose (bridge,
length, tip, width), the lips; the feminine set softer in the brow and jaw,
smaller in the nose, fuller in the lips and a few per cent smaller overall.
The topology never changes, so one texture layout and one vertex order serve
every head (and a future blend-shape rig can morph between them).
"""
import math
import os

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
BASE_NPZ = os.path.join(HERE, "faces_base", "head_base.npz")
# base (glTF axes) → head-local: the eyes 9 mm above HC and 66 mm in front
BASE_SHIFT = np.array([-1.46261, -0.75745, -0.0599])
NECK_CUT = -0.152          # head-local y: below this the neck is inside the suit (faces dropped)
NECK_TOP = -0.112          # from here down the neck is drawn in to the suit's neck
NECK_R = 0.052             # …to this radius at the cut


def smooth(a, b, x):
    t = np.clip((np.asarray(x, float) - a) / (b - a), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def unit(v):
    v = np.asarray(v, float)
    return v / np.maximum(np.linalg.norm(v, axis=-1, keepdims=True), 1e-12)


_BASE = None


def base():
    """The base head, placed: positions (head-local), quads, eye centres."""
    global _BASE
    if _BASE is not None:
        return _BASE
    d = np.load(BASE_NPZ)
    P = d["head_P"] + BASE_SHIFT
    flat, cnt = d["head_F"], d["head_N"]
    Q = flat.reshape(-1, 4) if np.all(cnt == 4) else None
    assert Q is not None, "the base is all quads"
    eyes = {"L": d["scleraL_P"].mean(0) + BASE_SHIFT, "R": d["scleraR_P"].mean(0) + BASE_SHIFT}
    re = float((d["scleraL_P"].max(0) - d["scleraL_P"].min(0)).max() / 2)
    # the neck: drawn in below NECK_TOP toward the suit's neck (its axis is
    # straight under the jaw's back), and cut off inside the suit
    y = P[:, 1]
    k = smooth(NECK_TOP, NECK_CUT, y)
    axis = np.array([0.0, 0.0, -0.032])
    v = P[:, [0, 2]] - axis[[0, 2]]
    r = np.linalg.norm(v, axis=1)
    want = np.minimum(r, NECK_R + (r - NECK_R) * 0.25)
    scale = np.where(r > 1e-6, (r + (want - r) * k) / np.maximum(r, 1e-6), 1.0)
    P[:, 0] = axis[0] + v[:, 0] * scale
    P[:, 2] = axis[2] + v[:, 1] * scale
    keep = ~np.all(P[Q][:, :, 1] < NECK_CUT, axis=1)
    Q = Q[keep]
    _BASE = dict(P=P, Q=Q, eyes=eyes, re=re)
    _BASE["lm"] = landmarks(P, eyes, re)
    return _BASE


def landmarks(P, eyes, re):
    """Where the face's parts are on the base (head-local)."""
    lm = {}
    lm["eyeL"], lm["eyeR"] = eyes["L"], eyes["R"]
    ey = (eyes["L"][1] + eyes["R"][1]) / 2
    # the midline profile: the nose's tip, the mouth's line, the chin
    mid = P[np.abs(P[:, 0]) < 0.0015]
    front = mid[mid[:, 2] > 0.035]
    tip = front[np.argmax(front[:, 2])]
    lm["nose"] = tip
    lips = front[(front[:, 1] < tip[1] - 0.02) & (front[:, 1] > tip[1] - 0.06)]
    # the mouth's line: the deepest notch between the lips, in front
    ys = np.linspace(tip[1] - 0.044, tip[1] - 0.028, 40)
    zf = [lips[np.abs(lips[:, 1] - yy) < 0.0015][:, 2].max(initial=-1) for yy in ys]
    lm["mouth_y"] = float(ys[int(np.argmin(zf))])
    below = front[front[:, 1] < lm["mouth_y"] - 0.02]
    lm["chin"] = below[np.argmax(below[:, 2])]
    lm["chin_low"] = float(front[:, 1].min())
    lm["eye_y"] = float(ey)
    lm["re"] = re
    # mouth corners: the widest lip-line points at the mouth's height, in front
    band = P[(np.abs(P[:, 1] - lm["mouth_y"]) < 0.004) & (P[:, 2] > lm["chin"][2] - 0.035)]
    cx = np.percentile(np.abs(band[:, 0]), 99)
    lm["mouth_w"] = float(min(cx, 0.03) * 0.86)
    zc = band[np.abs(np.abs(band[:, 0]) - lm["mouth_w"]) < 0.003][:, 2].max(initial=tip[2] - 0.03)
    lm["cornerL"] = np.array([lm["mouth_w"], lm["mouth_y"] + 0.001, zc])
    lm["cornerR"] = lm["cornerL"] * [-1, 1, 1]
    return lm


# ── the structures ──────────────────────────────────────────────────────────
D = dict(name="base", fem=0.0, scale=1.0, width=0.0, length=0.0, jaw=0.0, gonion=0.0, chin=0.0, chin_d=0.0,
         cheek=0.0, brow=0.0, bridge=0.0, nose_len=0.0, nose_w=0.0, tip_up=0.0, lips=0.0, mouth_w=0.0,
         eye_sp=0.0, forehead=0.0, temple=0.0)


def H(**kw):
    d = dict(D)
    d.update(kw)
    return d


# Eight people's bones. Units: metres of push (or a fraction for width,
# length, jaw, nose_w, mouth_w). Masculine 1–4, feminine 5–8.
HEADS = [
    H(name="square", width=0.03, jaw=0.10, gonion=0.004, chin=0.002, chin_d=0.002, brow=0.0025, bridge=0.001,
      nose_w=0.10, cheek=0.0015, lips=-0.0005),
    H(name="long", width=-0.035, length=0.06, jaw=-0.04, chin=0.003, chin_d=0.004, cheek=0.003, brow=0.0015,
      bridge=0.003, nose_len=0.003, nose_w=-0.08, temple=-0.002),
    H(name="round", width=0.06, length=-0.03, jaw=0.06, gonion=0.002, chin=-0.002, cheek=0.002, brow=0.0005,
      bridge=-0.002, nose_len=-0.002, nose_w=0.16, tip_up=0.001, lips=0.0012, mouth_w=0.05),
    H(name="craggy", width=0.0, length=0.02, jaw=0.04, gonion=0.003, chin=0.004, brow=0.004, cheek=0.0025,
      bridge=0.004, nose_len=0.004, nose_w=0.02, lips=-0.001, temple=-0.003),
    H(name="oval", fem=1.0, width=-0.02, jaw=-0.10, chin=-0.002, brow=-0.002, cheek=0.002,
      bridge=-0.002, nose_len=-0.003, nose_w=-0.12, tip_up=0.002, lips=0.0012, mouth_w=-0.04, forehead=0.002),
    H(name="wide", fem=1.0, width=0.045, length=-0.02, jaw=-0.03, chin=-0.002, brow=-0.0015, cheek=0.003,
      bridge=-0.003, nose_len=-0.002, nose_w=0.12, tip_up=0.0015, lips=0.002, mouth_w=0.04, eye_sp=0.0015),
    H(name="angular", fem=1.0, width=0.0, length=0.03, jaw=-0.02, gonion=0.002, chin=0.002, brow=-0.001,
      cheek=0.0035, bridge=0.0005, nose_len=0.0, nose_w=-0.08, lips=0.0005, temple=-0.002),
    H(name="heart", fem=1.0, width=0.015, length=-0.01, jaw=-0.16, chin=0.0005, chin_d=0.002, brow=-0.002,
      cheek=0.003, bridge=-0.002, nose_len=-0.003, nose_w=-0.10, tip_up=0.0025, lips=0.0015, mouth_w=-0.05,
      forehead=0.003),
]


VARIETY = 1.6             # all the fields' strength (one knob for how far apart the faces are)


def _g(P, c, s):
    d = (P - np.asarray(c, float)) / np.asarray(s, float)
    return np.exp(-(d * d).sum(1))


def field(P, h, lm):
    """The displacement structure h puts on points P (head-local)."""
    P = np.asarray(P, float)
    out = np.zeros_like(P)
    x, y, z = P[:, 0], P[:, 1], P[:, 2]
    ey, my, ny = lm["eye_y"], lm["mouth_y"], lm["nose"][1]
    front = smooth(-0.02, 0.04, z)
    # the face's width (below the brow, in front of the ears) and length
    out[:, 0] += x * h["width"] * front * smooth(ey + 0.04, ey - 0.01, y)
    out[:, 1] += (y - ey) * h["length"] * smooth(ey + 0.005, ey - 0.03, y) * front
    # the jaw: wider or narrower toward the chin; the angle out
    jz = smooth(ey - 0.04, my - 0.01, y) * smooth(-0.04, 0.0, z)
    out[:, 0] += x * h["jaw"] * jz * smooth(0.01, 0.045, np.abs(x))
    for sx in (-1, 1):
        g = _g(P, (sx * 0.058, my - 0.025, -0.005), (0.016, 0.02, 0.022))
        out[:, 0] += sx * h["gonion"] * g
    # chin: forward (chin) and down (chin_d)
    gc = _g(P, lm["chin"], (0.022, 0.016, 0.02))
    out[:, 2] += h["chin"] * gc
    out[:, 1] -= h["chin_d"] * _g(P, lm["chin"] - [0, 0.01, 0.0], (0.03, 0.02, 0.03))
    # cheekbones: out and forward
    for sx in (-1, 1):
        g = _g(P, (sx * 0.048, ey - 0.022, 0.035), (0.016, 0.013, 0.02))
        out[:, 0] += sx * h["cheek"] * g
        out[:, 2] += 0.6 * h["cheek"] * g
        # temples
        out[:, 0] += sx * h["temple"] * _g(P, (sx * 0.065, ey + 0.03, 0.01), (0.012, 0.02, 0.02))
    # brow ridge and forehead
    out[:, 2] += h["brow"] * (_g(P, (0.025, ey + 0.022, 0.07), (0.018, 0.009, 0.02)) +
                              _g(P, (-0.025, ey + 0.022, 0.07), (0.018, 0.009, 0.02)) +
                              0.8 * _g(P, (0.0, ey + 0.018, 0.075), (0.012, 0.01, 0.02)))
    out[:, 2] += h["forehead"] * _g(P, (0.0, ey + 0.045, 0.07), (0.035, 0.014, 0.03))   # under the hairline
    # the nose: bridge height, length (tip forward), tip up, width
    nb = _g(P, (0.0, (ey + ny) / 2 + 0.005, lm["nose"][2] - 0.015), (0.009, 0.016, 0.02))
    out[:, 2] += h["bridge"] * nb
    gt = _g(P, lm["nose"], (0.012, 0.012, 0.016))
    out[:, 2] += h["nose_len"] * gt
    out[:, 1] += h["tip_up"] * gt
    gn = _g(P, lm["nose"] - [0, 0.006, 0.01], (0.02, 0.014, 0.02))
    out[:, 0] += x * h["nose_w"] * gn
    # lips: fuller (forward and apart) and the mouth's width
    gl = _g(P, (0.0, my, lm["chin"][2] + 0.008), (0.022, 0.012, 0.012))
    out[:, 2] += h["lips"] * gl
    out[:, 1] += np.sign(y - my) * 0.5 * h["lips"] * gl
    out[:, 0] += x * h["mouth_w"] * _g(P, (0.0, my, lm["chin"][2]), (0.03, 0.015, 0.02))
    # the eyes' spacing (the whole orbit)
    for sx in (-1, 1):
        out[:, 0] += sx * h["eye_sp"] * _g(P, lm["eye" + ("L" if sx > 0 else "R")], (0.018, 0.016, 0.03))
    return out * VARIETY


def deform(P, h, lm):
    """Structure h's head: the field, then the overall scale (about the neck
    at the ring, so the head still sits on it)."""
    P = np.asarray(P, float)
    Q = P + field(P, h, lm)
    pivot = np.array([0.0, NECK_CUT, -0.032])
    k = h["scale"]
    # the neck's base stays where the suit is
    w = smooth(NECK_CUT, NECK_TOP + 0.02, Q[:, 1])[:, None]
    return pivot + (Q - pivot) * (1 + (k - 1) * w)


def head(h):
    """Structure h: positions, quads, eye centres, landmarks."""
    b = base()
    P = deform(b["P"], h, b["lm"])
    eyes = {s: deform(b["eyes"][s][None], h, b["lm"])[0] for s in "LR"}
    lm = dict(b["lm"])
    for k in ("nose", "chin", "cornerL", "cornerR"):
        lm[k] = deform(np.asarray(b["lm"][k])[None], h, b["lm"])[0]
    lm["eyeL"], lm["eyeR"] = eyes["L"], eyes["R"]
    lm["mouth_y"] = float((lm["cornerL"][1] + lm["cornerR"][1]) / 2 - 0.001)
    lm["eye_y"] = float((eyes["L"][1] + eyes["R"][1]) / 2)
    lm["mouth_w"] = float(lm["cornerL"][0])
    lm["re"] = b["re"] * (1 + (h["scale"] - 1) * 0.5)
    return dict(P=P, Q=b["Q"], eyes=eyes, lm=lm)


# ── the rig ─────────────────────────────────────────────────────────────────
BONES = ["FaceRoot", "Jaw", "LipLower", "LipUpper", "MouthL", "MouthR", "CheekL", "CheekR",
         "BrowInL", "BrowInR", "BrowOutL", "BrowOutR", "LidUpL", "LidUpR", "LidLoL", "LidLoR", "EyeL", "EyeR"]
PARENT = {b: "FaceRoot" for b in BONES[1:]}
PARENT["LipLower"] = "Jaw"
BI = {b: i for i, b in enumerate(BONES)}


def _surface_z(P, x, y, r=0.004):
    """The skin's front at (x, y): the largest z among points near there."""
    m = (np.abs(P[:, 0] - x) < r) & (np.abs(P[:, 1] - y) < r)
    return float(P[m, 2].max()) if m.any() else 0.0


def bone_points(hd):
    P, lm = hd["P"], hd["lm"]
    my, ey = lm["mouth_y"], lm["eye_y"]
    J = {"FaceRoot": np.zeros(3)}
    J["Jaw"] = np.array([0.0, my + 0.045, -0.012])          # the hinge, level with the ears' front
    J["LipLower"] = np.array([0.0, my - 0.008, _surface_z(P, 0.0, my - 0.008) - 0.004])
    J["LipUpper"] = np.array([0.0, my + 0.008, _surface_z(P, 0.0, my + 0.008) - 0.004])
    for sd, n in ((1, "L"), (-1, "R")):
        c = lm["corner" + n]
        J["Mouth" + n] = np.array([c[0], c[1], c[2] - 0.003])
        J["Cheek" + n] = np.array([sd * 0.036, my + 0.03, _surface_z(P, sd * 0.036, my + 0.03) - 0.005])
        J["BrowIn" + n] = np.array([sd * 0.015, ey + 0.022, _surface_z(P, sd * 0.015, ey + 0.022) - 0.004])
        J["BrowOut" + n] = np.array([sd * 0.042, ey + 0.02, _surface_z(P, sd * 0.042, ey + 0.02) - 0.004])
        e = hd["eyes"][n]
        J["LidUp" + n] = e.copy()
        J["LidLo" + n] = e.copy()
        J["Eye" + n] = e.copy()
    return J


def depth(P, O=np.array([0.0, 0.0, -0.005])):
    """How far each point is inside the head's outer surface along its ray
    from the head's centre (m): the mouth bag, the nostrils, the socket
    behind the lids are deep; the outer skin is 0."""
    v = P - O
    r = np.linalg.norm(v, axis=1)
    phi = np.arctan2(v[:, 0], v[:, 2])
    th = np.arcsin(np.clip(v[:, 1] / np.maximum(r, 1e-9), -1, 1))
    nb = 0.035
    i = np.floor((phi + np.pi) / nb).astype(int)
    j = np.floor((th + np.pi / 2) / nb).astype(int)
    rmax = {}
    for a, b_, rr in zip(i, j, r):
        k = (a, b_)
        if rr > rmax.get(k, 0):
            rmax[k] = rr
    out = np.empty(len(P))
    for n, (a, b_, rr) in enumerate(zip(i, j, r)):
        m = max(rmax.get((a + da, b_ + db), 0) for da in (-1, 0, 1) for db in (-1, 0, 1))
        out[n] = m - rr
    return out


def weights(hd):
    """Per vertex, the bones' raw shares (V × B)."""
    P, lm = hd["P"], hd["lm"]
    x, y, z = P[:, 0], P[:, 1], P[:, 2]
    W = np.zeros((len(P), len(BONES)))
    my, ey, mw = lm["mouth_y"], lm["eye_y"], lm["mouth_w"]
    ax = np.abs(x)
    dp = depth(P)
    inside = dp > 0.006
    # the mouth's split: the lips meet along y = my between the corners; the
    # line rises past the corners toward the jaw's hinge under the ears
    tb = np.where(ax < mw, my, my + (ax - mw) * 0.55)
    tb = np.minimum(tb, my + 0.04)
    below = smooth(tb + 0.004, tb - 0.012, y)
    # the jaw: below that line, the chin and the jaw's underside; not the
    # neck under it, nor the back of the jaw by the ears
    wj = below * smooth(lm["chin_low"] - 0.026, lm["chin_low"] - 0.004, y) * smooth(-0.045, -0.005, z)
    # inside the mouth: the lower half of the bag with the jaw, the upper not
    mouthbag = inside & (ax < mw + 0.01) & (y > my - 0.035) & (y < my + 0.03) & (z > -0.03)
    # which lip a point belongs to. The lips are two surfaces that only touch:
    # joined at the corners and deep in the mouth, not across the line where
    # they press together. So each is found by walking the mesh from a seed on
    # its front, inside the corners and in front of the bag; what the walk
    # from the lower lip reaches goes with the jaw, the upper lip's does not.
    # (Splitting by height alone put the lower lip's inner face, which rises a
    # little above the line, on the upper side: a jaw drop stretched it into a
    # tall pale slab that read as a tongue.)
    Q = hd["Q"]
    zfront = _surface_z(P, 0.0, my, r=0.003)
    region = (ax < mw - 0.0015) & (np.abs(y - my) < 0.022) & (z > zfront - 0.013)
    nbr = [[] for _ in range(len(P))]
    for q in Q:
        for i in range(4):
            a_, b_ = q[i], q[(i + 1) % 4]
            nbr[a_].append(b_)
            nbr[b_].append(a_)

    def walk(seed_y):
        cand = np.where(region & (np.abs(x) < 0.004))[0]
        seed = cand[np.argmin(np.abs(y[cand] - seed_y) + np.abs(z[cand] - zfront) * 0.5)]
        seen = {int(seed)}
        stack = [int(seed)]
        while stack:
            v = stack.pop()
            for w in nbr[v]:
                if w not in seen and region[w]:
                    seen.add(w)
                    stack.append(w)
        return seen
    lower_set = walk(my - 0.007)
    upper_set = walk(my + 0.007)
    both = lower_set & upper_set                 # (if the walks meet, the split is unsafe: fall back)
    lower_side = y < my - 0.0005
    if not both:
        idx = np.array(sorted(lower_set))
        lower_side[idx] = True
        idx = np.array(sorted(upper_set))
        lower_side[idx] = False
    wj = np.where(mouthbag, (y < my - 0.0005).astype(float), wj)
    wj = np.where(region, lower_side.astype(float) * np.where(region, 1.0, 0.0) + 0.0, wj)
    W[:, BI["Jaw"]] = wj
    upper = ~lower_side
    hd["lip_walk"] = (len(lower_set), len(upper_set), len(both))
    gl = np.exp(-((x / 0.022) ** 4) - ((y - my) / 0.012) ** 2) * smooth(0.04, 0.07, z)
    W[:, BI["LipUpper"]] = np.where(upper & ~mouthbag, gl * 0.85, 0)
    W[:, BI["LipLower"]] = np.where(~upper & ~mouthbag, gl * 0.85, 0)
    for sd, n in ((1, "L"), (-1, "R")):
        c = lm["corner" + n]
        W[:, BI["Mouth" + n]] = 0.95 * np.exp(-((x - c[0]) / 0.011) ** 2 - ((y - c[1]) / 0.011) ** 2 - ((z - c[2]) / 0.02) ** 2)
        W[:, BI["Cheek" + n]] = 0.8 * np.exp(-((x - sd * 0.036) / 0.014) ** 2 - ((y - (my + 0.03)) / 0.012) ** 2) * smooth(0.0, 0.03, z)
        above_lid = smooth(ey + 0.01, ey + 0.017, y)
        for nm, cx in (("BrowIn", 0.015), ("BrowOut", 0.042)):
            W[:, BI[nm + n]] = 0.9 * np.exp(-((x - sd * cx) / 0.013) ** 2 - ((y - (ey + 0.022)) / 0.011) ** 2) * above_lid * smooth(0.02, 0.05, z)
        # lids: the skin wrapped on the ball, by distance from its centre;
        # the upper above the lids' meeting line, the lower below it
        e = hd["eyes"][n]
        re = lm["re"]
        d = np.linalg.norm(P - e, axis=1)
        cf = np.clip(1 - ((x - e[0]) / 0.0165) ** 2, 0, 1) ** 0.6
        near = smooth(re * 1.95, re * 1.2, d) * cf
        ang = np.arctan2(y - e[1], z - e[2])                 # about the eye's x axis, 0 straight ahead
        split = hd["lid_split"][n]
        W[:, BI["LidUp" + n]] = np.where(ang > split, near, 0)
        W[:, BI["LidLo" + n]] = np.where(ang <= split, near * 0.9, 0)
    for n in ("L", "R"):
        lw = W[:, BI["LidUp" + n]] + W[:, BI["LidLo" + n]]
        for b_ in ("BrowIn" + n, "BrowOut" + n, "Cheek" + n):
            W[:, BI[b_]] *= np.clip(1 - lw, 0, 1)
    return W


def lid_geometry(hd):
    """Per eye: the angle (about the eye's x axis, 0 straight ahead, + up)
    of the upper and lower lid margins at the eye's middle, the line the lids
    meet on, and the turns that shut them."""
    P, lm = hd["P"], hd["lm"]
    re = lm["re"]
    out = {}
    for n in ("L", "R"):
        e = hd["eyes"][n]
        d = np.linalg.norm(P - e, axis=1)
        m = (np.abs(P[:, 0] - e[0]) < 0.0025) & (d < re * 1.35) & (P[:, 2] > e[2] + 0.2 * re)
        ang = np.arctan2(P[m, 1] - e[1], P[m, 2] - e[2])
        up = ang[ang > 0.05]
        lo = ang[ang < 0.05]
        a_up = float(up.min()) if len(up) else 0.35
        a_lo = float(lo.max()) if len(lo) else -0.35
        meet = a_lo + (a_up - a_lo) * 0.22
        out[n] = dict(up=a_up, lo=a_lo, split=(a_up + a_lo) / 2, close_up=a_up - meet, close_lo=meet - a_lo)
    return out


# ── the canonical layout (the textures' angles) ─────────────────────────────

def angles(P, O=np.array([0.0, 0.0, -0.005])):
    v = P - O
    r = np.linalg.norm(v, axis=1)
    return np.arctan2(v[:, 0], v[:, 2]), np.arcsin(np.clip(v[:, 1] / np.maximum(r, 1e-9), -1, 1))


def canonical(P, lm, C):
    """Head points → the textures' canonical (s, t): the eyes, the mouth's
    corners, the nose, the chin and the brow land where the textures are
    painted (C: gen_faces' canonical constants)."""
    phi, th = angles(P)
    pe, te = angles(np.array([lm["eyeL"]]))
    pm, tm = angles(np.array([lm["cornerL"]]))
    _, tn = angles(np.array([lm["nose"]]))
    _, tc = angles(np.array([lm["chin"]]))
    _, tb = angles(np.array([[0.02, lm["eye_y"] + 0.022, _surface_z(P, 0.02, lm["eye_y"] + 0.022)]]))
    pe, te, pm, tm, tn, tc, tb = (float(a[0]) for a in (pe, te, pm, tm, tn, tc, tb))
    # θ: piecewise linear through the landmarks
    t = np.interp(th, [-np.pi / 2, tc, tm, tn, te, tb, np.pi / 2],
                  [-np.pi / 2, C["chin"], C["mouth"], C["nose"], C["eye"], C["brow"], np.pi / 2])
    # φ: scaled so the eyes (at the eyes' height) and the mouth's corners (at
    # the mouth's) land on theirs; the scale fades back to 1 round the sides
    k_e, k_m = C["eye_s"] / pe, C["mouth_w"] / pm
    k = np.interp(th, [tm, te], [k_m, k_e])
    a = np.abs(phi)
    k = np.where(a < 0.8, k, k + (1 - k) * smooth(0.8, 1.4, a))
    return phi * k, t
