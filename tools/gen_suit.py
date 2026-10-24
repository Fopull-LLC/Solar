#!/usr/bin/env python3
"""Generate the crew's EVA SUIT on the existing astronaut rig.

    python3 tools/gen_suit.py            # textures and both suits
    python3 tools/gen_suit.py --scene    # … and the AstroModel's materials in scenes/system.ron
    python3 tools/gen_suit.py --dry      # print the budget, write nothing

Writes
    models/astronaut/astronaut_male.glb     the suit, skinned to the male rig
    models/astronaut/astronaut_female.glb   the same suit on the female rig
    textures/suit/fabric_{albedo,normal,orm}.png   the suit's outer cloth
    textures/suit/shell_{albedo,normal,orm}.png    the hard parts' painted composite
    textures/suit/decals.png                the agency patch, the name placard,
                                            the chest display and the PLSS plate
    textures/suit/visor.png                 the gold sun visor, with the sky and
                                            the ground it reflects painted in

and, with --scene, the AstroModel's `object_materials` (SUIT_MATS) in
scenes/system.ron.

LOOK. An EMU / A7L-like extravehicular suit in the base's language — grounded
NASA/ESA-era hardware drawn with PSX restraint: warm off-white cloth (not pure
white), a broad painted hard upper torso (HUT) with a flat display and control
module (DCM) on its chest, a backpack (PLSS) as wide as the HUT and 0.23 m
deep, a bubble helmet only a little larger than a head, sitting on the neck
ring, with a gold visor, a clear bubble rim, a visor assembly and two lamps;
metal bearings at the neck, waist, scyes, upper arms, wrists and ankles;
convolutes at the elbows, knees and waist; compact light-grey gloves with dark
palms; low, chunky boots on dark soles; the agency emblem on the left upper
arm. Signal orange is the one accent: the commander's thigh bands and crown
stripe, the PLSS handles and one tag. Proportions are the published EMU / A7L
figures (see "reference proportions" below), not inflation of a body.

HOW IT BENDS. Hard parts — HUT, helmet, PLSS, DCM, every bearing, the boots —
are rigid, 100 % on one bone (the helmet sits on the HUT's neck ring and is on
Back, as on a real suit; the head turns inside it). Soft parts are cloth tubes
between two rigid rings, and each joint is handled for linear skinning:
  * elbows and knees: convolute ridges rigid on either side, a three-ring
    blend across the pivot, a cloth ball centred ON the pivot (rotation-
    invariant, so it never moves) that rounds the outside of the bend however
    far it goes — a blend alone pinches, shrinking the mid ring by cos(θ/2) —
    and the INNER side of the blend rings weighted rigidly (loft w_in), so the
    crease tucks in instead of folding a flap out;
  * shoulders: the sleeve leaves a scye bearing on the HUT; Back blends into
    Upperarm across the shoulder fabric, and a cloth dome (rigid Back) fills
    the bearing so no swing shows the inside;
  * hips: the thigh rises narrower inside the brief (never sharing its
    surface) with a hip ball on the pivot for deep crouches; the waist is a
    convolute between the brief's waist ring (Hip) and the HUT (Back).
The ARMS are modelled in an authoring pose — the T-pose bind with the arms
40° down (AUTHOR_ABDUCT) — and taken back to bind space through each
vertex's own blended transform (Skin.unpose): the shoulders bend half as far
to reach either the T or the arms-down they are mostly seen in.
tools/suit_posecheck.py renders the suit at the joints' extremes in Blender.

THE RIG IS NOT TOUCHED. The skeleton, its node tree, the rest pose (MaleArm's
½ scale included) and the inverse bind matrices are copied byte for byte from
the file being replaced — so every clip (tools/gen_astronaut_anims.py), the
leg and arm IK (scripts/planet_walker.lua, scripts/tool_belt.lua) and the
command seat's pose work unchanged. Only the mesh is new. Re-running reads
the rig back out of the suit it wrote, so the build is idempotent.

THE PLACEMENT IS NOT TOUCHED EITHER. The engine places a rigged model by the
centre of its rest-pose bounding box (gltf_rig.rs `center`), and the walker's
numbers (MA_UP, the AstroModel's −0.05 offset) were tuned against the old
body's box. A helmet and a backpack move that centre, so two zero-area anchor
triangles pin the box's centre to the old body's exactly (REST_CENTRE).

BUDGET. About 7,100 triangles and six materials, so the crew is six draws:
SuitFabric, SuitShell, SuitMetal, SuitVisor, SuitDecal, SuitLamp. Colour
within a material is a vertex colour (glTF COLOR_0), as the base's buildings
do it. Textures: 256² cloth and shell sets, a 512×256 decal atlas, a 128²
visor.

LICENCE. The rig (bones, rest pose, bind matrices) comes from Clint
Bellanger's "human.blend" (CC-BY-SA / GPL); the suit's geometry, weights and
textures are new (no vertex of the old body is used). The files carry the rig, so they stay CC-BY-SA — see
models/astronaut/CREDITS.txt.
"""
import json
import math
import os
import struct
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_part_meshes import ROOT, Model, box, lathe, frame_to  # noqa: E402
from gen_part_textures import normal_from_height, smoothstep, spectral  # noqa: E402
import base_tex  # noqa: E402

TAU = 2 * math.pi
MODELS = os.path.join(ROOT, "models", "astronaut")
TEXDIR = os.path.join(ROOT, "textures", "suit")
TEX = "textures/suit/"
FONT_LABEL = os.path.join(ROOT, "fonts", "SolarLabel.ttf")
FONT_MONO = os.path.join(ROOT, "fonts", "SolarMono.ttf")

# The old bodies' rest-pose bounding-box centres (the accessors' min/max of the
# Blender export these files replaced). The engine places the rig by this point.
REST_CENTRE = {
    "male": ((-1.4360729455947876 + 0.43607297539711) / 2,
             (0.002859830856323242 + 1.872779130935669) / 2,
             (-0.1850365549325943 + 0.17680248618125916) / 2),
    "female": ((-0.3831951320171356 + 1.3857064247131348) / 2,
               (0.006933629512786865 + 1.7869398593902588) / 2,
               (-0.17966483533382416 + 0.1333545595407486) / 2),
}

# ── palette (linear-ish albedo multipliers, by name) ────────────────────────
# Every colour is a vertex colour on one of the six materials.
CLOTH = (0.85, 0.83, 0.78)         # warm off-white beta cloth
CLOTH_SH = (0.73, 0.71, 0.66)      # the same in a fold (the bellows' valleys)
ORANGE = (0.97, 0.50, 0.17)        # signal orange (ui accent 0.97 0.55 0.22)
GLOVE = (0.56, 0.57, 0.58)         # light grey glove
PALM = (0.20, 0.20, 0.21)          # dark grip palm
SOLE = (0.17, 0.17, 0.18)          # dark grey sole
BOOT = (0.78, 0.78, 0.76)          # boot upper, a touch greyer than the cloth
PAL = {
    "shell":   ("SuitShell", (0.97, 0.965, 0.95)),   # painted composite, off-white
    "shell_g": ("SuitShell", (0.62, 0.62, 0.60)),   # grey hardware
    "shell_d": ("SuitShell", (0.20, 0.20, 0.21)),   # dark hardware, seams
    "shell_o": ("SuitShell", ORANGE),
    "metal":   ("SuitMetal", (0.86, 0.86, 0.84)),   # anodised aluminium bearing
    "metal_d": ("SuitMetal", (0.45, 0.46, 0.48)),
    "visor":   ("SuitVisor", (1.0, 1.0, 1.0)),
    "bubble":  ("SuitVisor", (1.0, 1.0, 1.0)),
    "decal":   ("SuitDecal", (1.0, 1.0, 1.0)),
    "lamp":    ("SuitLamp", (1.0, 0.95, 0.86)),
    "cloth":   ("SuitFabric", CLOTH),
    "glove":   ("SuitFabric", GLOVE),
    "sole":    ("SuitFabric", SOLE),
    "boot":    ("SuitFabric", BOOT),
}

# Decal atlas regions (u0, v0, u1, v1), v down the image.
DECAL_W, DECAL_H = 512, 256
REG = {
    "emblem":  (0 / 512, 0 / 256, 128 / 512, 128 / 256),
    "placard": (128 / 512, 0 / 256, 384 / 512, 64 / 256),
    "display": (128 / 512, 64 / 256, 320 / 512, 160 / 256),
    "plss":    (320 / 512, 64 / 256, 512 / 512, 160 / 256),
}


# ═════════════════════════════════════════════════════════════════════════════
# textures
# ═════════════════════════════════════════════════════════════════════════════

def save_rgb(arr, name):
    a = np.clip(arr, 0, 1)
    Image.fromarray((a * 255 + 0.5).astype(np.uint8), "RGB").save(os.path.join(TEXDIR, name), optimize=True)


def tex_fabric(n=256):
    """Beta cloth: a 0.25 m tile of soft, low-contrast weave grain, gentle
    mottling, and one stitched seam down the tile's edge (a loft's u = 0, which
    the builder turns to the inside of each limb)."""
    rng = np.random.default_rng(31)
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float32)
    mott = spectral(n, n, rng, beta=2.2, lo=1.5)
    fib = spectral(n, n, rng, beta=0.6, sx=1.0, sy=0.25, lo=40)
    weave = 0.5 + 0.25 * np.sin(xx * TAU / 4.0) * np.sin(yy * TAU / 4.0)   # 1 mm, felt not seen
    v = 0.93 + (mott - 0.5) * 0.06 + (fib - 0.5) * 0.04 + (weave - 0.5) * 0.015
    # the seam: a soft fold either side of a stitched line, at u = 0
    du = np.minimum(xx, n - 1 - xx)
    fold = np.exp(-(du / 3.0) ** 2)
    stitch = (np.abs(du - 4.0) < 0.8) * (np.sin(yy * TAU / 6.0) > 0.0)
    v -= fold * 0.05 + stitch * 0.04
    # a little grime low on every tile (soft, warm)
    grime = smoothstep(0.62, 0.9, spectral(n, n, rng, beta=2.0, lo=2))
    alb = np.stack([v, v * 0.99, v * 0.965], -1)
    alb -= grime[..., None] * np.array([0.035, 0.04, 0.05])
    hgt = (fib - 0.5) * 0.6 + (weave - 0.5) * 0.25 - fold * 1.2 - stitch * 0.4 + (mott - 0.5) * 0.8
    ao = 1 - fold * 0.25
    rough = 0.88 + (fib - 0.5) * 0.06
    save_rgb(alb, "fabric_albedo.png")
    save_rgb(normal_from_height(hgt, 1.4), "fabric_normal.png")
    save_rgb(np.stack([ao, rough, np.zeros_like(v)], -1), "fabric_orm.png")


def tex_shell(n=256):
    """The hard parts: a painted composite, 0.5 m tile — orange-peel, faint
    mottling and scuffs, no panel lines (they belong to a spacecraft)."""
    rng = np.random.default_rng(47)
    mott = spectral(n, n, rng, beta=2.0, lo=2)
    peel = spectral(n, n, rng, beta=1.0, lo=30)
    scuff = smoothstep(0.80, 0.95, spectral(n, n, rng, beta=1.2, sx=1.0, sy=0.3, lo=8))
    v = 0.95 + (mott - 0.5) * 0.05 - scuff * 0.06
    alb = np.stack([v, v * 0.99, v * 0.97], -1)
    hgt = (peel - 0.5) * 0.5 - scuff * 0.3
    rough = 0.42 + (mott - 0.5) * 0.10 + scuff * 0.25
    save_rgb(alb, "shell_albedo.png")
    save_rgb(normal_from_height(hgt, 0.8), "shell_normal.png")
    save_rgb(np.stack([np.ones_like(v), rough, np.zeros_like(v)], -1), "shell_orm.png")


def tex_visor(n=128):
    """The gold sun visor. It reflects the world, so the world is painted in:
    warm sky over a darker ground with the horizon's bright band across the
    middle, a soft window highlight up and to the left — read correctly on
    any planet, in any light, because a visor is mostly what it reflects."""
    yy, xx = (np.mgrid[0:n, 0:n] + 0.5) / n * 2 - 1      # yy down the image
    gold = np.array([0.88, 0.62, 0.22])
    sky = np.clip(1.0 - (yy + 1) * 0.45, 0, 1)              # bright top, fading down
    ground = smoothstep(0.02, 0.25, yy)                       # below the horizon
    band = np.exp(-((yy - 0.06) / 0.07) ** 2)                 # the horizon's glare
    curve = 0.75 + 0.25 * (1 - np.clip(xx * xx + yy * yy, 0, 1))
    lum = (0.55 + 0.35 * sky) * (1 - 0.55 * ground) + 0.35 * band
    lum *= curve
    hi = np.exp(-(((xx + 0.38) / 0.16) ** 2 + ((yy + 0.42) / 0.10) ** 2))
    alb = lum[..., None] * gold + hi[..., None] * np.array([0.45, 0.40, 0.30])
    # the clear bubble's rim lives in the top-right corner texel block
    alb[: n // 8, -n // 8:] = np.array([0.72, 0.78, 0.80])
    save_rgb(alb, "visor.png")


def _fit(d, text, font, w, size):
    while size > 8:
        f = ImageFont.truetype(font, size)
        b = d.textbbox((0, 0), text, font=f)
        if b[2] - b[0] <= w:
            return f, b
        size -= 1
    return f, b


def tex_decals():
    img = Image.new("RGB", (DECAL_W, DECAL_H), (200, 196, 186))
    d = ImageDraw.Draw(img)

    def px(r):
        return (int(r[0] * DECAL_W), int(r[1] * DECAL_H), int(r[2] * DECAL_W), int(r[3] * DECAL_H))

    # The agency emblem, stitched on as a patch: the roundel on a cloth disc
    # with a dark embroidered border.
    x0, y0, x1, y1 = px(REG["emblem"])
    s = x1 - x0
    patch = Image.new("RGB", (s, s), CLOTH_RGB)
    pd = ImageDraw.Draw(patch)
    pd.ellipse([1, 1, s - 2, s - 2], fill=(40, 44, 58))
    em = base_tex.emblem(s - 10, seed=11)
    mask = Image.new("L", (s - 10, s - 10), 0)
    ImageDraw.Draw(mask).ellipse([0, 0, s - 11, s - 11], fill=255)
    patch.paste(em, (5, 5), mask)
    img.paste(patch, (x0, y0))
    # The name placard: printed capitals in ink on an off-white tape, an orange
    # tab at the left (the base's placard style).
    x0, y0, x1, y1 = px(REG["placard"])
    d.rectangle([x0, y0, x1 - 1, y1 - 1], fill=(226, 220, 204))
    d.rectangle([x0, y0, x0 + 34, y1 - 1], fill=(236, 140, 56))
    d.rectangle([x0 + 2, y0 + 2, x1 - 3, y1 - 3], outline=(60, 58, 52), width=2)
    f, b = _fit(d, "SOLAR  CDR  01", FONT_LABEL, x1 - x0 - 60, 40)
    d.text((x0 + 46 - b[0], y0 + (y1 - y0 - (b[3] - b[1])) / 2 - b[1]), "SOLAR  CDR  01", font=f, fill=(34, 32, 30))
    # The chest display: a small CRT window, green phosphor on green-black,
    # in a grey bezel (live numbers live on screens).
    x0, y0, x1, y1 = px(REG["display"])
    d.rectangle([x0, y0, x1 - 1, y1 - 1], fill=(120, 120, 116))
    d.rectangle([x0 + 10, y0 + 10, x1 - 11, y1 - 11], fill=(10, 18, 12))
    fm = ImageFont.truetype(FONT_MONO, 20)
    for k, line in enumerate(("O2  4.31 PSI", "CO2 0.02  OK", "H2O  87 %  FAN")):
        d.text((x0 + 18, y0 + 16 + k * 22), line, font=fm, fill=(150, 226, 132) if k != 2 else (98, 150, 88))
    # The PLSS's back plate: a stencilled serial and a hazard-free orange tag.
    x0, y0, x1, y1 = px(REG["plss"])
    d.rectangle([x0, y0, x1 - 1, y1 - 1], fill=(222, 216, 200))
    d.rectangle([x0 + 4, y0 + 4, x1 - 5, y1 - 5], outline=(70, 68, 62), width=2)
    f, b = _fit(d, "PLSS  S/N 0001", FONT_LABEL, x1 - x0 - 30, 22)
    d.text((x0 + 14 - b[0], y0 + 12 - b[1]), "PLSS  S/N 0001", font=f, fill=(40, 38, 34))
    f, b = _fit(d, "SOLAR SPACEFLIGHT", FONT_LABEL, x1 - x0 - 30, 18)
    d.text((x0 + 14 - b[0], y0 + 44 - b[1]), "SOLAR SPACEFLIGHT", font=f, fill=(90, 86, 78))
    d.rectangle([x0 + 14, y1 - 26, x0 + 70, y1 - 14], fill=(236, 140, 56))
    img = base_tex.wear(img, 5, amount=0.08)
    img.save(os.path.join(TEXDIR, "decals.png"), optimize=True)


CLOTH_RGB = tuple(int(c * 255) for c in CLOTH)


def textures():
    os.makedirs(TEXDIR, exist_ok=True)
    tex_fabric()
    tex_shell()
    tex_visor()
    tex_decals()


# ═════════════════════════════════════════════════════════════════════════════
# the rig
# ═════════════════════════════════════════════════════════════════════════════

def read_glb(path):
    b = open(path, "rb").read()
    jl = struct.unpack("<I", b[12:16])[0]
    j = json.loads(b[20:20 + jl])
    off = 20 + jl
    bl = struct.unpack("<I", b[off:off + 4])[0]
    return j, b[off + 8:off + 8 + bl]


class Rig:
    def __init__(self, path):
        j, B = read_glb(path)
        self.json = j
        skin = j["skins"][0]
        a = j["accessors"][skin["inverseBindMatrices"]]
        v = j["bufferViews"][a["bufferView"]]
        o = v.get("byteOffset", 0) + a.get("byteOffset", 0)
        self.ibm_bytes = B[o:o + 64 * a["count"]]
        ibm = np.frombuffer(self.ibm_bytes, np.float32).reshape(-1, 4, 4).transpose(0, 2, 1)
        self.names = [j["nodes"][k]["name"] for k in skin["joints"]]
        self.index = {n: i for i, n in enumerate(self.names)}
        self.bind = {n: np.linalg.inv(m.astype(np.float64)) for n, m in zip(self.names, ibm)}
        self.mesh_node = next(i for i, n in enumerate(j["nodes"]) if "mesh" in n)

    def p(self, name):
        return self.bind[name][:3, 3].copy()


# ═════════════════════════════════════════════════════════════════════════════
# the skinned mesh
# ═════════════════════════════════════════════════════════════════════════════

class Skin:
    """Per material: positions, normals, uvs, colours, joints, weights, tris."""

    def __init__(self, rig):
        self.rig = rig
        self.parts = {}

    def _w(self, wd, n):
        items = sorted(((self.rig.index[b], w) for b, w in wd.items() if w > 1e-4), key=lambda t: -t[1])[:4]
        tot = sum(w for _, w in items)
        J = [i for i, _ in items] + [0] * (4 - len(items))
        W = [w / tot for _, w in items] + [0.0] * (4 - len(items))
        return np.tile(J, (n, 1)), np.tile(W, (n, 1))

    def add(self, mat, P, N, UV, C, J, W, I):
        e = self.parts.setdefault(mat, {"P": [], "N": [], "UV": [], "C": [], "J": [], "W": [], "I": [], "n": 0})
        P = np.asarray(P, float).reshape(-1, 3)
        e["P"].append(P); e["N"].append(np.asarray(N, float).reshape(-1, 3))
        e["UV"].append(np.asarray(UV, float).reshape(-1, 2)); e["C"].append(np.asarray(C, float).reshape(-1, 3))
        e["J"].append(np.asarray(J).reshape(-1, 4)); e["W"].append(np.asarray(W, float).reshape(-1, 4))
        e["I"].append(np.asarray(I, np.int64).reshape(-1, 3) + e["n"])
        e["n"] += len(P)

    def add_model(self, model, bone, M=None, t=(0, 0, 0)):
        """A gen_part_meshes Model whose material keys are PAL names, placed by
        M, t and weighted 100 % to `bone` (dict for a blend)."""
        wd = bone if isinstance(bone, dict) else {bone: 1.0}
        for key, (Ps, Ns, UVs, Is, _) in model.parts.items():
            mat, col = PAL[key]
            P = np.vstack(Ps); N = np.vstack(Ns); UV = np.vstack(UVs); I = np.vstack(Is)
            if M is not None:
                P = P @ np.asarray(M).T
                N = N @ np.asarray(M).T
            P = P + np.asarray(t)
            J, W = self._w(wd, len(P))
            self.add(mat, P, N, UV, np.tile(col, (len(P), 1)), J, W, I)

    def tris(self):
        return sum(len(self.faces(m)) for m in self.parts)

    def faces(self, mat):
        """The material's triangles less the zero-area ones (a lathe's pole,
        the anchors): the engine's box reads vertices, so the anchors'
        vertices still count without a triangle."""
        e = self.parts[mat]
        P = np.vstack(e["P"]); I = np.vstack(e["I"])
        a = np.linalg.norm(np.cross(P[I[:, 1]] - P[I[:, 0]], P[I[:, 2]] - P[I[:, 0]]), axis=1)
        return I[a > 1e-10]

    def bounds(self):
        P = np.vstack([np.vstack(e["P"]) for e in self.parts.values()])
        return P.min(0), P.max(0)

    def unpose(self, D):
        """Everything was modelled in the AUTHORING pose, where joint i has
        moved by D[i] (a 4×4) from the bind pose. Take each vertex back to
        bind space through the inverse of its own blended transform, so that
        skinning with the rig's bind matrices draws it exactly as modelled
        when the bones are in the authoring pose."""
        for e in self.parts.values():
            P = np.vstack(e["P"]); N = np.vstack(e["N"])
            Jn = np.vstack(e["J"]); W = np.vstack(e["W"])
            M = np.einsum("nk,nkij->nij", W, D[Jn])
            P1 = np.hstack([P, np.ones((len(P), 1))])
            Pb = np.linalg.solve(M, P1[..., None])[..., 0][:, :3]
            Nb = np.einsum("nji,nj->ni", M[:, :3, :3], N)
            Nb /= np.maximum(np.linalg.norm(Nb, axis=1, keepdims=True), 1e-12)
            cnt = [len(x) for x in e["P"]]
            cut = np.cumsum(cnt)[:-1]
            e["P"] = np.split(Pb, cut)
            e["N"] = np.split(Nb, cut)


def smooth_normals(P, I):
    """Area-weighted vertex normals, shared across coincident vertices (a
    loft's u seam), so the seam does not show."""
    a, b, c = P[I[:, 0]], P[I[:, 1]], P[I[:, 2]]
    fn = np.cross(b - a, c - a)
    key = np.round(P / 1e-5).astype(np.int64)
    _, inv = np.unique(key, axis=0, return_inverse=True)
    inv = inv.reshape(-1)
    acc = np.zeros((inv.max() + 1, 3))
    for k in range(3):
        np.add.at(acc, inv[I[:, k]], fn)
    N = acc[inv]
    return N / np.maximum(np.linalg.norm(N, axis=1, keepdims=True), 1e-12)


def ring_pts(c, e1, e2, r1, r2, segs, sq=2.0, a0=0.0):
    """A closed superellipse ring (sq = 2 an ellipse, higher a rounded box),
    segs + 1 points (the last repeats the first, for the u seam)."""
    out = []
    for i in range(segs + 1):
        a = a0 + TAU * i / segs
        ca, sa = math.cos(a), math.sin(a)
        x = math.copysign(abs(ca) ** (2.0 / sq), ca)
        y = math.copysign(abs(sa) ** (2.0 / sq), sa)
        out.append(c + e1 * (r1 * x) + e2 * (r2 * y))
    return out


def loft(sk, mat, rings, segs, cap0=False, cap1=False, tile=0.25, sq=2.0, a0=0.0):
    """Rings: dicts with c (centre), e1, e2 (the cross-section's axes), r1, r2,
    w ({bone: weight}) and col (rgb, or f(angle) -> rgb). Faces point away
    from the axis. UVs in tiles of `tile` metres; u = 0 at angle a0."""
    P, UV, C, J, W, I = [], [], [], [], [], []
    vacc = 0.0
    prev = None
    circ = max(TAU * math.sqrt((r["r1"] ** 2 + r["r2"] ** 2) / 2) for r in rings)
    ut = max(1, round(circ / tile))
    for k, r in enumerate(rings):
        c = np.asarray(r["c"], float)
        pts = ring_pts(c, np.asarray(r["e1"], float), np.asarray(r["e2"], float), r["r1"], r["r2"], segs,
                       r.get("sq", sq), a0)
        if prev is not None:
            vacc += float(np.linalg.norm(c - prev))
        prev = c
        if "w_in" in r:
            # the joint's INNER side (toward r["inner"]) takes its own weights,
            # mixed in smoothly round the ring: a crease that folds rigidly
            # tucks in clean instead of folding a blended flap out
            inner = np.asarray(r["inner"], float)
            for p in pts:
                rad = p - c
                f = smooth01(-0.15, 0.55, float(rad @ inner) / max(np.linalg.norm(rad), 1e-9))
                wd = {}
                for b_, w_ in r["w"].items():
                    wd[b_] = wd.get(b_, 0.0) + (1 - f) * w_
                for b_, w_ in r["w_in"].items():
                    wd[b_] = wd.get(b_, 0.0) + f * w_
                jj, ww = sk._w(wd, 1)
                J.append(jj); W.append(ww)
        else:
            jj, ww = sk._w(r["w"], segs + 1)
            J.append(jj); W.append(ww)
        for i, p in enumerate(pts):
            P.append(p)
            UV.append((i / segs * ut, vacc / tile))
            col = r["col"]
            C.append(col(a0 + TAU * i / segs) if callable(col) else col)
    n = segs + 1
    for k in range(len(rings) - 1):
        for i in range(segs):
            a, b = k * n + i, k * n + i + 1
            I.append((a, b, b + n)); I.append((a, b + n, a + n))
    P = np.array(P)
    J = np.vstack(J); W = np.vstack(W)
    cap_ids, cap_dir = [], {}
    for which, on in ((0, cap0), (len(rings) - 1, cap1)):
        if not on:
            continue
        r = rings[which]
        ci = len(P)
        nxt = rings[1 if which == 0 else which - 1]["c"]
        d = np.asarray(r["c"], float) - np.asarray(nxt, float)
        cap_ids.append((ci, which)); cap_dir[ci] = d / np.linalg.norm(d)
        P = np.vstack([P, np.asarray(r["c"], float)[None]])
        UV.append((0.0, 0.0))
        col = r["col"]
        C.append(col(0.0) if callable(col) else col)
        jj, ww = sk._w(r["w"], 1)
        J = np.vstack([J, jj]); W = np.vstack([W, ww])
        for i in range(segs):
            I.append((ci, which * n + i, which * n + i + 1))
    I = np.array(I)
    # orient: away from the loft's axis (each vertex's ring centre); a cap's
    # triangles point out of its end
    nring = len(rings) * n
    cen = np.vstack([np.tile(np.asarray(r["c"], float), (n, 1)) for r in rings])
    cen = np.vstack([cen, P[nring:]])
    a, b, c = P[I[:, 0]], P[I[:, 1]], P[I[:, 2]]
    fn = np.cross(b - a, c - a)
    out = (a + b + c) / 3 - (cen[I[:, 0]] + cen[I[:, 1]] + cen[I[:, 2]]) / 3
    for ci, nb_ in cap_ids:
        m = I[:, 0] == ci
        out[m] = cap_dir[ci]
    flip = (fn * out).sum(1) < 0
    I[flip] = I[flip][:, [0, 2, 1]]
    N = smooth_normals(P, I)
    sk.add(mat, P, N, np.array(UV), np.array(C), J, W, I)


def lathe_on(sk, key, prof, centre, axis, ref, segs, bone, uv=None, skip=None, smooth=True):
    """A lathe of (rho, h) about `axis` through `centre`; `ref` sets where the
    angle starts. Rigid to `bone`. `uv(rho, h, ang) -> (u, v)` overrides the
    metre UVs. `skip(rho, h, ang) -> True` drops a quad (by its centre)."""
    mat, col = PAL[key]
    axis = np.asarray(axis, float); axis /= np.linalg.norm(axis)
    e1 = np.asarray(ref, float) - axis * np.dot(ref, axis); e1 /= np.linalg.norm(e1)
    e2 = np.cross(axis, e1)
    P, UV, I = [], [], []
    nb = len(prof)
    for k, (rho, h) in enumerate(prof):
        for i in range(segs + 1):
            a = TAU * i / segs
            p = np.asarray(centre) + axis * h + (e1 * math.cos(a) + e2 * math.sin(a)) * rho
            P.append(p)
            UV.append(uv(rho, h, a) if uv else (i / segs * max(1, round(TAU * rho / 0.5)), h / 0.5))
    n = segs + 1
    for k in range(nb - 1):
        for i in range(segs):
            if skip:
                rho = (prof[k][0] + prof[k + 1][0]) / 2
                h = (prof[k][1] + prof[k + 1][1]) / 2
                if skip(rho, h, TAU * (i + 0.5) / segs):
                    continue
            a, b = k * n + i, k * n + i + 1
            I.append((a, b, b + n)); I.append((a, b + n, a + n))
    P = np.array(P); I = np.array(I)
    # orient away from the axis, or along it where the surface is a face
    a_, b_, c_ = P[I[:, 0]], P[I[:, 1]], P[I[:, 2]]
    fn = np.cross(b_ - a_, c_ - a_)
    m = (a_ + b_ + c_) / 3 - np.asarray(centre)
    radial = m - np.outer(m @ axis, axis)
    rl = np.linalg.norm(radial, axis=1)
    out = np.where((rl > 1e-6)[:, None], m, axis[None] * np.sign(m @ axis)[:, None])
    flip = (fn * out).sum(1) < 0
    I[flip] = I[flip][:, [0, 2, 1]]
    if smooth:
        N = smooth_normals(P, I)
    else:
        N = np.zeros_like(P)
    jj, ww = sk._w(bone if isinstance(bone, dict) else {bone: 1.0}, len(P))
    sk.add(mat, P, N, np.array(UV), np.tile(col, (len(P), 1)), jj, ww, I)


def quad_patch(sk, key, region, pos, normal, bone, nu=1, nv=1):
    """A decal: a grid nu × nv whose point at (s, t) ∈ [0,1]² is pos(s, t),
    s across the image and t down it, mapped onto atlas `region`; it faces
    roughly `normal`."""
    mat, col = PAL[key]
    u0, v0, u1, v1 = region
    P, UV, I = [], [], []
    for j in range(nv + 1):
        for i in range(nu + 1):
            s_, t_ = i / nu, j / nv
            P.append(np.asarray(pos(s_, t_), float))
            UV.append((u0 + (u1 - u0) * s_, v0 + (v1 - v0) * t_))
    for j in range(nv):
        for i in range(nu):
            a = j * (nu + 1) + i
            I.append((a, a + 1, a + nu + 2)); I.append((a, a + nu + 2, a + nu + 1))
    P = np.array(P); I = np.array(I)
    a_, b_, c_ = P[I[:, 0]], P[I[:, 1]], P[I[:, 2]]
    fn = np.cross(b_ - a_, c_ - a_)
    flip = (fn @ np.asarray(normal, float)) < 0
    I[flip] = I[flip][:, [0, 2, 1]]
    N = smooth_normals(P, I)
    jj, ww = sk._w(bone if isinstance(bone, dict) else {bone: 1.0}, len(P))
    sk.add(mat, P, N, np.array(UV), np.tile(col, (len(P), 1)), jj, ww, I)


# ═════════════════════════════════════════════════════════════════════════════
# the suit
# ═════════════════════════════════════════════════════════════════════════════

X, Y, Z = np.eye(3)


def smooth01(a, b, x):
    t = min(1.0, max(0.0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)


def blend(a, b, t):
    """Weights {a: 1 − t, b: t}."""
    return {a: 1.0 - t, b: t} if a != b else {a: 1.0}


def tube(m, mat, p0, p1, r, segs=10, caps=True, r1=None):
    """A cylinder between two points, its caps triangle fans (gen_part_meshes'
    caps are annuli, twice the triangles)."""
    p0, p1 = np.asarray(p0, float), np.asarray(p1, float)
    d = p1 - p0
    L = float(np.linalg.norm(d))
    rr1 = r if r1 is None else r1
    sub = Model()
    prof = [(0.0, 0.0), (r, 0.0), (rr1, L), (0.0, L)] if caps else [(r, 0.0), (rr1, L)]
    lathe(sub, mat, prof, segs=segs, uv_m=4.0, u_tiles=1)
    m.merge(sub, frame_to(d / L), p0)


def ring_model(key, ri, ro, w, ch=0.004, segs=16):
    """A bearing: a flat-faced ring of inner radius ri, outer ro and width w
    about +Y, its outer edges chamfered by `ch` — crisp, flat-shaded bands."""
    m = Model()
    if ch > 0:
        prof = [(ri, -w / 2), (ro - ch, -w / 2), (ro, -w / 2 + ch), (ro, w / 2 - ch), (ro - ch, w / 2), (ri, w / 2)]
    else:
        prof = [(ri, -w / 2), (ro, -w / 2), (ro, w / 2), (ri, w / 2)]
    lathe(m, key, prof, segs=segs, uv_m=4.0)
    return m


def frames(cs, ref):
    """Per point of a path: its tangent and a cross-section frame (e1 toward
    `ref`, e2 = t × e1), free of twist as long as the path never runs along ref."""
    cs = [np.asarray(c, float) for c in cs]
    out = []
    for i in range(len(cs)):
        a, b = cs[max(0, i - 1)], cs[min(len(cs) - 1, i + 1)]
        t = b - a
        t /= np.linalg.norm(t)
        e1 = np.asarray(ref, float) - t * np.dot(ref, t)
        e1 /= np.linalg.norm(e1)
        out.append((t, e1, np.cross(t, e1)))
    return out


def limb(sk, rings, segs, ref, a0=0.0, tile=0.25, cap0=False, cap1=False, mat="SuitFabric"):
    """A soft tube along a path: rings of dict(c, r[, r2], w, col[, sq]); the
    cross-section frames come from the path (frames)."""
    fr = frames([r["c"] for r in rings], ref)
    full = []
    for r, (t, e1, e2) in zip(rings, fr):
        full.append(dict(c=r["c"], e1=e1, e2=e2, r1=r["r"], r2=r.get("r2", r["r"]), w=r["w"],
                         col=r.get("col", CLOTH), sq=r.get("sq", 2.0)))
        if "w_in" in r:
            full[-1]["w_in"], full[-1]["inner"] = r["w_in"], r["inner"]
    loft(sk, mat, full, segs, cap0=cap0, cap1=cap1, a0=a0, tile=tile)


def shell(sk, mat, rings, segs, hard=(), a0=0.0, tile=0.5, cap0=None, cap1=None):
    """A hard shell lofted through `rings`, smooth within a run and CRISP at
    each ring index in `hard` (the run is split there, so the normals are
    not shared), with flat caps facing cap0 / cap1 (vectors) if given."""
    cuts = [0] + sorted(hard) + [len(rings) - 1]
    for a, b in zip(cuts, cuts[1:]):
        if b > a:
            loft(sk, mat, rings[a:b + 1], segs, a0=a0, tile=tile)
    for ring, nrm in ((rings[0], cap0), (rings[-1], cap1)):
        if nrm is None:
            continue
        pts = ring_pts(np.asarray(ring["c"], float), np.asarray(ring["e1"], float), np.asarray(ring["e2"], float),
                       ring["r1"], ring["r2"], segs, ring.get("sq", 2.0), a0)
        c = np.asarray(ring["c"], float)
        P = np.vstack([pts, c[None]])
        n = len(pts)
        I = np.array([(n, i, i + 1) for i in range(segs)])
        a_, b_, c_ = P[I[:, 0]], P[I[:, 1]], P[I[:, 2]]
        flip = (np.cross(b_ - a_, c_ - a_) @ np.asarray(nrm, float)) < 0
        I[flip] = I[flip][:, [0, 2, 1]]
        col = ring["col"]
        J, W = sk._w(ring["w"], len(P))
        uv = np.array([[(p - c) @ np.asarray(ring["e1"], float) * 2, (p - c) @ np.asarray(ring["e2"], float) * 2]
                       for p in P])
        sk.add(mat, P, np.tile(np.asarray(nrm, float) / np.linalg.norm(nrm), (len(P), 1)), uv,
               np.tile(col, (len(P), 1)), J, W, I)


def rbox(sk, key, c, w, h, d, bone, bev=0.02, segs=16, sq=6.0):
    """A rounded block with crisp chamfered top and bottom edges, rigid on
    `bone`: a superellipse in plan, its sides one smooth run."""
    mat, col = PAL[key]
    c = np.asarray(c, float)
    y0, y1 = c[1] - h / 2, c[1] + h / 2

    def ring(y, i):
        return dict(c=(c[0], y, c[2]), e1=X, e2=Z, r1=w / 2 - i, r2=d / 2 - i, w={bone: 1}, col=col, sq=sq)
    shell(sk, mat, [ring(y0, bev), ring(y0 + bev, 0.0), ring(y1 - bev, 0.0), ring(y1, bev)], segs,
          hard=(1, 2), cap0=-Y, cap1=Y)


def lerp(a, b, t):
    return np.asarray(a) + (np.asarray(b) - np.asarray(a)) * t


def rot_about(axis, deg, pivot):
    """A 4×4 rotation by `deg` about `axis` through `pivot`."""
    a = np.asarray(axis, float) / np.linalg.norm(axis)
    th = math.radians(deg)
    K = np.array([[0, -a[2], a[1]], [a[2], 0, -a[0]], [-a[1], a[0], 0]])
    R = np.eye(3) + math.sin(th) * K + (1 - math.cos(th)) * K @ K
    M = np.eye(4)
    M[:3, :3] = R
    M[:3, 3] = np.asarray(pivot) - R @ np.asarray(pivot)
    return M


# ── reference proportions ───────────────────────────────────────────────────
# Metres, for the 1.87 m male rig (scaled by the rig's size for the other).
# From NASA's published EMU and A7L figures, rounded: hard upper torso about
# 0.42 m across the chest and 0.30 m deep, scye bearings about 0.19 m ID;
# PLSS 0.46 × 0.60 × 0.23 m; helmet bubble about 0.32 m across on a 0.23 m
# neck ring; suited upper arm 0.15 m across, forearm tapering to a 0.115 m
# wrist disconnect; suited thigh 0.21 m tapering to 0.18 m at the knee, calf
# 0.17 m, ankle 0.13 m; boots 0.32 m long, 0.125 m wide, 0.13–0.15 m high;
# gloves a hand plus a centimetre or two.
AUTHOR_ABDUCT = 40.0      # the arms are modelled 40° down from the rig's T-pose
SCYE_TILT = 58.0          # the scye bearings face this far down from the horizontal


def build_suit(rig):
    sk = Skin(rig)
    J = rig.p
    head, back, hip = J("Head"), J("Back"), J("Hip")
    x0 = back[0]
    k = head[1] / 1.575                  # the rig's size against the male's
    zc = (back[2] + hip[2]) / 2           # the torso's middle, front to back

    # The AUTHORING pose: the rig's bind pose with each arm swung down 40°
    # (a suit's own neutral, between the T it was bound in and the arms-down
    # it is mostly seen in), so the shoulders deform half as far either way.
    nb = len(rig.names)
    D = np.tile(np.eye(4), (nb, 1, 1))
    for side, s in (("Left", 1.0), ("Right", -1.0)):
        R = rot_about(Z, -s * AUTHOR_ABDUCT, J("Upperarm." + side))
        for b in ("Upperarm", "Forearm", "Hand", "Fingers1", "Fingers2", "Thumb1", "Thumb2"):
            D[rig.index[b + "." + side]] = R

    def Ja(name):
        return (D[rig.index[name]] @ np.append(J(name), 1.0))[:3]

    neck_y = head[1] + 0.040 * k          # the neck ring's base, on the HUT's yoke
    hut_y0 = hip[1] + 0.026 * k           # the HUT's lower edge, just above the waist pivot
    zh = zc + 0.008 * k                   # the HUT's middle, front to back

    # ── BRIEF and WAIST: the lower torso, rigid on Hip, and a convoluted
    # waist blending Hip into Back across the waist pivot ──────────────────
    crotch = J("Thigh.Left")[1] - 0.085 * k

    def tr(y, hw, hd, w, col=CLOTH, sq=2.6):
        return dict(c=(x0, y, zc), e1=X, e2=Z, r1=hw * k, r2=hd * k, w=w, col=col, sq=sq)
    waist_ring_y = hip[1] - 0.085 * k
    brief = [tr(crotch, 0.08, 0.07, {"Hip": 1}), tr(crotch + 0.03 * k, 0.17, 0.115, {"Hip": 1}),
             tr(crotch + 0.09 * k, 0.222, 0.138, {"Hip": 1}), tr(crotch + 0.16 * k, 0.222, 0.140, {"Hip": 1}),
             tr(waist_ring_y - 0.02 * k, 0.200, 0.132, {"Hip": 1})]
    loft(sk, "SuitFabric", brief, 16, cap0=True, a0=-math.pi / 2)
    wr = ring_model("metal", 1.0, 1.06, 0.022 / 0.2, ch=0.0, segs=16)   # unit ring, made elliptical below
    for e_ in wr.parts.values():
        for P_ in e_[0]:
            P_[:, 0] *= 0.196 * k
            P_[:, 2] *= 0.130 * k
            P_[:, 1] *= 0.2 * k
    sk.add_model(wr, "Hip", t=(x0, waist_ring_y, zc))
    waist = []
    y_a, y_b = waist_ring_y + 0.008 * k, hut_y0 + 0.006 * k
    for i in range(5):
        y = lerp(y_a, y_b, i / 4)[()]
        ridge = i % 2 == 1
        hw = (0.190 if ridge else 0.180) * k
        waist.append(dict(c=(x0, y, zc), e1=X, e2=Z, r1=hw, r2=hw * 0.68, sq=2.6,
                          w=blend("Hip", "Back", smooth01(y_a + 0.01 * k, y_b - 0.01 * k, y)),
                          col=CLOTH if ridge else CLOTH_SH))
    loft(sk, "SuitFabric", waist, 16, a0=-math.pi / 2)

    # ── HUT: the hard upper torso, rigid on Back ───────────────────────────
    HUT = [  # y over the lower edge, half-width, half-depth (a boxy shell)
        (0.000, 0.186, 0.130), (0.012, 0.196, 0.140), (0.080, 0.204, 0.148), (0.160, 0.208, 0.152),
        (0.230, 0.212, 0.152), (0.290, 0.206, 0.147), (0.330, 0.186, 0.135), (0.358, 0.152, 0.120),
        (0.372, 0.128, 0.110), (0.377, 0.118, 0.104),
    ]
    hut = [dict(c=(x0, hut_y0 + y * k, zh), e1=X, e2=Z, r1=hw * k, r2=hd * k, w={"Back": 1},
                col=PAL["shell"][1], sq=3.6) for y, hw, hd in HUT]
    shell(sk, "SuitShell", hut, 20, hard=(1,), a0=-math.pi / 2)
    hut_top = hut_y0 + HUT[-1][0] * k
    # the body seal closure: a metal band round the HUT's lower edge
    bs = []
    for y, g in ((-0.012, 0.0), (-0.004, 0.006), (0.010, 0.006), (0.016, 0.0)):
        bs.append(dict(c=(x0, hut_y0 + y * k, zh), e1=X, e2=Z, r1=(0.190 + g) * k, r2=(0.134 + g) * k,
                       w={"Back": 1}, col=PAL["metal"][1], sq=3.4))
    shell(sk, "SuitMetal", bs, 20, hard=(1, 2), a0=-math.pi / 2)

    def hut_surface(x, y, front=True):
        ys = [hut_y0 + h[0] * k for h in HUT]
        rx = np.interp(y, ys, [h[1] * k for h in HUT])
        rz = np.interp(y, ys, [h[2] * k for h in HUT])
        t = min(1.0, abs(x - x0) / rx)
        return zh + (1 if front else -1) * rz * (1 - t ** 3.6) ** (1 / 3.6)

    # the neck ring (the helmet locks onto it), on the HUT's yoke
    nr = Model()
    lathe(nr, "metal", [(0.100 * k, 0.0), (0.124 * k, 0.0), (0.128 * k, 0.005 * k), (0.128 * k, 0.020 * k),
                        (0.124 * k, 0.026 * k), (0.104 * k, 0.026 * k)], segs=20, uv_m=4.0)
    sk.add_model(nr, "Back", t=(x0, hut_top - 0.004 * k, zh))
    ring_top = hut_top + 0.022 * k

    # the display and control module: a flat plate box on the chest
    dy = hut_y0 + 0.13 * k
    dz = hut_surface(x0, dy) + 0.036 * k
    rbox(sk, "shell_g", (x0, dy, dz), 0.225 * k, 0.115 * k, 0.075 * k, "Back", bev=0.010 * k, segs=16, sq=8.0)
    dcm = Model()
    for i, dx in enumerate((-0.07, -0.025, 0.025, 0.07)):
        tube(dcm, "shell_o" if i == 3 else "metal_d", (dx * k, 0.0, 0.0), (dx * k, 0.018 * k, 0.0), 0.012 * k, segs=8)
    for s_ in (-1, 1):   # the umbilical connectors at its sides
        tube(dcm, "metal", (s_ * 0.105 * k, -0.03 * k, 0.0), (s_ * 0.135 * k, -0.03 * k, 0.0), 0.017 * k, segs=8)
    sk.add_model(dcm, "Back", t=(x0, dy + 0.0575 * k, dz))
    fz = dz + 0.0375 * k + 0.0012
    dw_, dh_ = 0.15 * k, 0.065 * k
    quad_patch(sk, "decal", REG["display"], lambda s_, t_: (x0 - dw_ / 2 + dw_ * s_, dy + 0.040 * k - dh_ * t_, fz),
               Z, "Back")

    # the name placard on the right breast, above the DCM, on the shell
    pw_, ph_ = 0.13 * k, 0.032 * k
    py = hut_y0 + 0.235 * k

    def placard(s_, t_):
        x = x0 - 0.02 * k - pw_ + pw_ * s_
        y = py + ph_ / 2 - ph_ * t_
        return (x, y, hut_surface(x, y) + 0.0025)
    quad_patch(sk, "decal", REG["placard"], placard, Z, "Back", nu=4)

    # ── PLSS: the backpack, rigid on Back — as wide as the HUT and deep ─────
    W_, H_, D_ = 0.44 * k, 0.60 * k, 0.23 * k
    pl_y = hut_y0 + 0.10 * k + H_ / 2 - 0.12 * k
    pl_z = hut_surface(x0, pl_y, front=False) - D_ / 2 + 0.01 * k
    pl_c = np.array([x0, pl_y, pl_z])
    rbox(sk, "shell", pl_c - Y * 0.04 * k, W_, H_ - 0.08 * k, D_, "Back", bev=0.03 * k, segs=16)
    seam = Model()
    box(seam, "shell_d", (0, 0, 0), (W_ - 0.03 * k, 0.012 * k, D_ - 0.03 * k))
    sk.add_model(seam, "Back", t=pl_c + Y * (H_ / 2 - 0.078 * k))
    rbox(sk, "shell", pl_c + Y * (H_ / 2 - 0.036 * k), W_ - 0.008 * k, 0.072 * k, D_ - 0.012 * k, "Back",
         bev=0.022 * k, segs=16)
    pk = Model()
    for s_ in (-1, 1):
        box(pk, "shell_g", (s_ * (W_ / 2 + 0.003 * k), -0.05 * k, 0), (0.010 * k, H_ * 0.62, D_ * 0.55))
        hx = s_ * (W_ / 2 + 0.028 * k)
        tube(pk, "shell_o", (hx, H_ * 0.16, -0.025 * k), (hx, H_ * 0.16 - 0.14 * k, -0.025 * k), 0.010 * k, segs=8)
        for yy in (H_ * 0.16, H_ * 0.16 - 0.14 * k):
            tube(pk, "shell_o", (s_ * (W_ / 2 + 0.004 * k), yy, -0.025 * k), (hx, yy, -0.025 * k), 0.008 * k,
                 segs=6, caps=False)
    box(pk, "shell_g", (0, -0.21 * k, -D_ / 2 - 0.005 * k), (0.28 * k, 0.10 * k, 0.012 * k))
    for i, dx in enumerate((-0.08, 0.0, 0.08)):
        tube(pk, "shell_o" if i == 2 else "metal_d", (dx * k, -0.21 * k, -D_ / 2 - 0.01 * k),
             (dx * k, -0.21 * k, -D_ / 2 - 0.032 * k), 0.017 * k, segs=10)
    box(pk, "shell_g", (0, -0.06 * k, -D_ / 2 - 0.004 * k), (W_ - 0.08 * k, 0.016 * k, 0.010 * k))
    tube(pk, "shell_d", (0.15 * k, H_ / 2, -0.05 * k), (0.15 * k, H_ / 2 + 0.09 * k, -0.05 * k), 0.006 * k, segs=6)
    sk.add_model(pk, "Back", t=pl_c)
    bz = pl_c[2] - D_ / 2 - 0.0015
    quad_patch(sk, "decal", REG["plss"],
               lambda s_, t_: (x0 + 0.11 * k - 0.22 * k * s_, pl_c[1] + 0.13 * k - 0.11 * k * t_, bz), -Z, "Back")

    # ── HELMET: a bubble on the neck ring, rigid on Back (as the real one is:
    # the head turns inside it) ─────────────────────────────────────────────
    R = 0.158 * k
    ring_r = 0.106 * k
    hc = np.array([x0, ring_top + math.sqrt(R * R - ring_r * ring_r), zh + 0.012 * k])
    cut = ring_top - hc[1] + 0.004 * k

    def sph(deg, r):        # (rho, h) about the forward axis
        a = math.radians(deg)
        return (r * math.sin(a), r * math.cos(a))

    def below(rho, h, ang):  # axis +Z, angle 0 = +Y: a point's y is rho·cos(ang)
        return rho * math.cos(ang) < cut

    def visor_uv(rho, h, ang):
        x, y = rho * math.sin(ang), rho * math.cos(ang)
        return (0.5 - x / (2 * R) * 0.95) * 0.875, (0.5 - y / (2 * R) * 0.95) * 0.875 + 0.0625

    lathe_on(sk, "visor", [sph(a, R * 0.99) for a in np.linspace(0, 62, 6)], hc, Z, Y, 20, "Back",
             uv=visor_uv, skip=below)
    # the clear bubble: its edge shows round the visor as a pale glossy lip
    lathe_on(sk, "bubble", [sph(62, R * 0.99), sph(62, R * 1.0), sph(90, R * 1.0), sph(124, R * 1.0)],
             hc, Z, Y, 20, "Back", uv=lambda r, h, a: (0.95, 0.05), skip=below)
    # the visor assembly (EVVA) over the top, sides and back, standing off
    # the bubble with a crisp rolled edge
    ev = [sph(66, R * 1.0), sph(66, R * 1.045), sph(70, R * 1.06)] + [sph(a, R * 1.06) for a in np.linspace(82, 180, 6)]
    lathe_on(sk, "shell", ev[:2], hc, Z, Y, 20, "Back", skip=below)
    lathe_on(sk, "shell", ev[1:], hc, Z, Y, 20, "Back", skip=below)
    lathe_on(sk, "shell_o", [sph(a, R * 1.066) for a in np.linspace(84, 172, 6)], hc, Z, Y, 48, "Back",
             skip=lambda rho, h, ang: abs(((ang + math.pi) % TAU) - math.pi) > 0.07)     # the crown stripe
    col = Model()
    lathe(col, "metal", [(0.094 * k, 0.0), (0.110 * k, 0.0), (0.110 * k, 0.012 * k), (0.104 * k, 0.016 * k),
                         (0.094 * k, 0.016 * k)], segs=16, uv_m=4.0)
    lathe(col, "shell_d", [(0.0, 0.014 * k), (0.095 * k, 0.014 * k)], segs=12)
    sk.add_model(col, "Back", t=(x0, ring_top - 0.002 * k, hc[2]))
    for s_ in (-1, 1):       # the EVVA's lamps, either side, lenses forward
        lp = Model()
        rb_c = np.zeros(3)
        box(lp, "shell_g", rb_c, (0.036 * k, 0.036 * k, 0.075 * k))
        tube(lp, "shell_d", (0, 0, 0.0375 * k), (0, 0, 0.044 * k), 0.015 * k, segs=10)
        tube(lp, "lamp", (0, 0, 0.044 * k), (0, 0, 0.046 * k), 0.011 * k, segs=10)
        sk.add_model(lp, "Back", t=hc + np.array([s_ * (R * 1.06 + 0.012 * k), 0.02 * k, 0.05 * k]))

    # ── ARMS (modelled in the authoring pose) ───────────────────────────────
    for side, s in (("Left", 1.0), ("Right", -1.0)):
        ua, fa, hd = "Upperarm." + side, "Forearm." + side, "Hand." + side
        S, E, H = Ja(ua), Ja(fa), Ja(hd)
        F1, F2 = Ja("Fingers1." + side), Ja("Fingers2." + side)
        T1, T2 = Ja("Thumb1." + side), Ja("Thumb2." + side)
        axu = (E - S) / np.linalg.norm(E - S)
        axf = (H - E) / np.linalg.norm(H - E)
        out = s * np.cross(Z, axu)             # away from the body, in the frontal plane
        out /= np.linalg.norm(out)
        L1 = float(np.linalg.norm(E - S))

        # The sleeve sits a little outboard of the arm inside it (a suit's
        # scye is wider than a shoulder), most at the shoulder, none at the
        # wrist where the hand must be.
        def off(s_):
            return 0.030 * k * (1 - smooth01(0.10 * k, L1 - 0.07 * k, s_))

        def up_c(s_):
            return S + axu * s_ + out * off(s_)

        # The scye: a bearing set into the HUT's shoulder corner, facing
        # down and out at SCYE_TILT (steeper than the arm as modelled, as on
        # a real HUT), on a short boss; rigid Back. A cloth dome fills it, so
        # however far the sleeve swings the scye shows cloth, never inside.
        th = math.radians(SCYE_TILT)
        bax = np.array([s * math.cos(th), -math.sin(th), 0.0])
        bout = np.array([s * math.sin(th), math.cos(th), 0.0])
        bc = S + bout * 0.026 * k + bax * 0.072 * k          # the bearing's centre
        boss = Model()
        lathe(boss, "shell", [(0.0, -0.05 * k), (0.094 * k, -0.05 * k), (0.094 * k, -0.012 * k)], segs=16, uv_m=2.0)
        sk.add_model(boss, "Back", M=frame_to(bax), t=bc)
        sk.add_model(ring_model("metal", 0.080 * k, 0.098 * k, 0.026 * k, ch=0.0, segs=16), "Back",
                     M=frame_to(bax), t=bc)
        dome = Model()
        lathe(dome, "cloth", [(0.0, 0.036 * k), (0.042 * k, 0.031 * k), (0.068 * k, 0.017 * k), (0.079 * k, 0.0),
                              (0.079 * k, -0.02 * k)], segs=12, smooth=True, uv_m=4.0)
        sk.add_model(dome, "Back", M=frame_to(bax), t=bc - bax * 0.008 * k)
        # the shoulder: cloth from inside the bearing, curving from its axis
        # onto the arm's, to the upper-arm bearing — Back blending into
        # Upperarm along it (the joint is behind it)
        s_ub = 0.195 * k
        p0 = bc - bax * 0.004 * k
        p2 = up_c(s_ub)
        p1 = p0 + bax * 0.45 * float(np.linalg.norm(p2 - p0))
        sh = []
        for i, t in enumerate(np.linspace(0.0, 1.0, 6)):
            c = (1 - t) ** 2 * p0 + 2 * (1 - t) * t * p1 + t * t * p2
            sh.append(dict(c=c, r=(0.078 if i != 3 else 0.081) * k, w=blend("Back", ua, smooth01(0.05, 0.95, t))))
        # the upper arm, from the bearing to the elbow's convolutes
        conv0 = L1 - 0.065 * k
        for s_ in (s_ub + 0.004 * k, (s_ub + conv0) / 2, conv0 - 0.01 * k):
            sh.append(dict(c=up_c(s_), r=(0.075 - 0.010 * (s_ - s_ub) / (conv0 - s_ub)) * k, w={ua: 1}))
        # the elbow: convolutes on either side, rigid, a short blend across
        # the joint, and a ball on the pivot that rounds the elbow however far
        # it bends (a blend alone pinches: linear skinning shrinks a ring
        # half-way between two bones by cos(θ/2), a third of it at 140°)
        for d, r, w, c_ in ((-0.046, 0.066, {ua: 1}, CLOTH), (-0.034, 0.059, {ua: 1}, CLOTH_SH),
                            (-0.022, 0.065, {ua: 1}, CLOTH), (-0.010, 0.057, blend(ua, fa, 0.25), CLOTH_SH),
                            (0.000, 0.057, blend(ua, fa, 0.5), CLOTH_SH), (0.010, 0.057, blend(ua, fa, 0.75), CLOTH_SH),
                            (0.022, 0.064, {fa: 1}, CLOTH), (0.034, 0.058, {fa: 1}, CLOTH_SH),
                            (0.046, 0.064, {fa: 1}, CLOTH)):
            c = (S + axu * (L1 + d * k) + out * off(L1 + d * k)) if d < 0 else (E + axf * d * k)
            sh.append(dict(c=c, r=r * k, w=w, col=c_, w_in={ua: 1} if d <= 0 else {fa: 1}, inner=Z))
        ball = Model()
        lathe(ball, "cloth", [(0.055 * k * math.sin(a), -0.055 * k * math.cos(a)) for a in np.linspace(0, math.pi, 5)],
              segs=10, smooth=True, uv_m=4.0)
        sk.add_model(ball, ua, M=frame_to(axu), t=E)
        # the forearm, tapering to the wrist disconnect
        L2 = float(np.linalg.norm(H - E))
        for d, r in ((0.085, 0.063), (L2 / k - 0.08, 0.057), (L2 / k - 0.035, 0.054)):
            sh.append(dict(c=E + axf * d * k, r=r * k, w={fa: 1}))
        limb(sk, sh, 10, Z, a0=math.pi / 2 * s + math.pi, tile=0.25)
        # the upper-arm bearing, and the wrist disconnect with its lock ring
        sk.add_model(ring_model("metal", 0.070 * k, 0.083 * k, 0.020 * k, ch=0.0, segs=12), ua,
                     M=frame_to(axu), t=up_c(s_ub))
        sk.add_model(ring_model("metal", 0.050 * k, 0.062 * k, 0.022 * k, ch=0.0, segs=12), fa,
                     M=frame_to(axf), t=H - axf * 0.030 * k)
        # the emblem on the left upper arm, on its outer face
        if side == "Left":
            r_p = 0.072 * k + 0.002
            ph = 0.080 * k
            span = ph / r_p
            sc_ = s_ub + 0.115 * k
            across = -Z
            across = across - axu * (across @ axu)
            across /= np.linalg.norm(across)

            def patch(su, tv, sc_=sc_, across=across, span=span, ph=ph, out=out):
                a = (su - 0.5) * span
                return up_c(sc_ + (tv - 0.5) * ph) + (out * math.cos(a) + across * math.sin(a)) * r_p
            quad_patch(sk, "decal", REG["emblem"], patch, out, ua, nu=4, nv=1)

        # the glove: a gauntlet over the disconnect, a compact padded hand
        # with a dark palm, mitt fingers and a thumb
        g = [(-0.022, 0.054), (-0.014, 0.0615), (0.010, 0.0615), (0.024, 0.052)]
        gl = [dict(c=H + axf * d * k, r=r * k, w={hd: 1}, col=GLOVE) for d, r in g]
        limb(sk, gl, 10, Z, tile=0.25)
        hax = (F2 - H) / np.linalg.norm(F2 - H)
        hup = D[rig.index[hd]][:3, :3] @ Y
        hup = hup - hax * (hup @ hax)
        hup /= np.linalg.norm(hup)
        hfw = np.cross(hax, hup)
        hz_off = ((J(hd) + J("Fingers1." + side)) / 2)[2] - 0.004 * k

        def pal(a):
            return PALM if math.sin(a) < -0.35 else GLOVE

        def gring(p, ry, rz, w):
            p = np.asarray(p, float).copy()
            p = p + Z * (hz_off - p[2])
            return dict(c=p, e1=hfw, e2=hup, r1=rz * k, r2=ry * k, w=w, col=pal, sq=2.6)
        f1, f2 = "Fingers1." + side, "Fingers2." + side
        loft(sk, "SuitFabric", [
            gring(H + hax * 0.018 * k, 0.027, 0.046, {hd: 1}),
            gring(lerp(H, F1, 0.55), 0.026, 0.049, {hd: 1}),
            gring(F1, 0.023, 0.048, blend(hd, f1, 0.5)),
            gring(lerp(F1, F2, 0.6), 0.021, 0.046, {f1: 1}),
            gring(F2, 0.020, 0.044, blend(f1, f2, 0.6)),
            gring(F2 + hax * 0.024 * k, 0.018, 0.040, {f2: 1}),
            gring(F2 + hax * 0.036 * k, 0.012, 0.031, {f2: 1}),
            gring(F2 + hax * 0.042 * k, 0.005, 0.016, {f2: 1}),
        ], 10, cap1=True, a0=0.0, tile=0.25)
        tdir = (T2 - T1) / np.linalg.norm(T2 - T1)
        t1, t2 = "Thumb1." + side, "Thumb2." + side
        limb(sk, [dict(c=T1 - tdir * 0.01 * k, r=0.019 * k, w=blend(hd, t1, 0.4), col=GLOVE),
                  dict(c=T2, r=0.017 * k, w=blend(t1, t2, 0.5), col=GLOVE),
                  dict(c=T2 + tdir * 0.032 * k, r=0.014 * k, w={t2: 1}, col=GLOVE),
                  dict(c=T2 + tdir * 0.044 * k, r=0.006 * k, w={t2: 1}, col=GLOVE)], 8, hup, cap1=True)

    # ── LEGS ───────────────────────────────────────────────────────────────
    for side, s in (("Left", 1.0), ("Right", -1.0)):
        T, K, A = J("Thigh." + side), J("Shin." + side), J("Foot." + side)
        th, sh_, ft, to = "Thigh." + side, "Shin." + side, "Foot." + side, "Toes." + side
        axt = (K - T) / np.linalg.norm(K - T)
        axs = (A - K) / np.linalg.norm(A - K)
        LT = float(np.linalg.norm(K - T))
        leg = []
        # the hip: from inside the brief, Hip blending into Thigh below the joint
        # (narrower inside the brief, so the two never share a surface)
        for d, r in ((-0.10, 0.086), (-0.04, 0.091), (0.02, 0.097), (0.08, 0.105), (0.13, 0.105)):
            leg.append(dict(c=T + axt * d * k, r=r * k, w=blend("Hip", th, smooth01(-0.05 * k, 0.09 * k, d * k))))
        hb = Model()                                         # the hip's ball, inside the brief at rest
        lathe(hb, "cloth", [(0.088 * k * math.sin(a), -0.088 * k * math.cos(a)) for a in np.linspace(0, math.pi, 5)],
              segs=10, smooth=True, uv_m=4.0)
        sk.add_model(hb, "Hip", t=T)
        # the thigh, the commander's band, tapering to the knee
        for d, r, c_ in ((0.21, 0.101, CLOTH), (0.2101, 0.101, ORANGE), (0.24, 0.100, ORANGE),
                         (0.2401, 0.100, CLOTH), (LT / k - 0.065, 0.092, CLOTH)):
            leg.append(dict(c=T + axt * d * k, r=r * k, w={th: 1}, col=c_))
        # the knee: convolutes, Thigh blending into Shin, standing proud at the front
        for d, r, w, c_ in ((-0.049, 0.090, {th: 1}, CLOTH), (-0.036, 0.081, {th: 1}, CLOTH_SH),
                            (-0.023, 0.089, {th: 1}, CLOTH), (-0.011, 0.079, blend(th, sh_, 0.25), CLOTH_SH),
                            (0.000, 0.079, blend(th, sh_, 0.5), CLOTH_SH), (0.011, 0.079, blend(th, sh_, 0.75), CLOTH_SH),
                            (0.023, 0.088, {sh_: 1}, CLOTH), (0.036, 0.080, {sh_: 1}, CLOTH_SH),
                            (0.049, 0.088, {sh_: 1}, CLOTH)):
            c = (K + axt * d * k) if d < 0 else (K + axs * d * k)
            leg.append(dict(c=c, r=r * k, w=w, col=c_, w_in={th: 1} if d <= 0 else {sh_: 1}, inner=-Z))
        kb = Model()                                         # the knee's ball, on the pivot
        lathe(kb, "cloth", [(0.077 * k * math.sin(a), -0.077 * k * math.cos(a)) for a in np.linspace(0, math.pi, 5)],
              segs=10, smooth=True, uv_m=4.0)
        sk.add_model(kb, th, t=K)
        # the calf, tapering to the ankle bearing on the boot
        LS = float(np.linalg.norm(A - K))
        for d, r in ((0.10, 0.087), (0.20, 0.084), (LS / k - 0.14, 0.068)):
            leg.append(dict(c=K + axs * d * k, r=r * k, w={sh_: 1}))
        for d, r in ((LS / k - 0.075, 0.062), (LS / k - 0.055, 0.061)):
            leg.append(dict(c=K + axs * d * k, r=r * k, w=blend(sh_, ft, smooth01(LS - 0.10 * k, LS - 0.05 * k, d * k))))
        limb(sk, leg, 10, Z, a0=math.pi if side == "Left" else 0.0, tile=0.25)

        # the boot: rigid shells — a dark lugged sole and a white upper, the
        # toe box on Toes with a flex seam at the ball of the foot
        Tp = J("Toes." + side)
        bx = A[0]
        heel_z, toe_z = A[2] - 0.090 * k, Tp[2] + 0.108 * k
        sole_t = 0.028 * k

        def bring(z, top, hw, w, y0=0.0, col=BOOT, sq=3.6):
            return dict(c=(bx, (y0 + top) / 2, z), e1=X, e2=Y, r1=hw * k, r2=(top - y0) / 2, w=w, col=col, sq=sq)
        zs = [heel_z, heel_z + 0.02 * k, A[2] + 0.02 * k, Tp[2] - 0.035 * k, Tp[2] - 0.005 * k, Tp[2] + 0.05 * k,
              toe_z - 0.02 * k, toe_z]
        hw = [0.052, 0.060, 0.064, 0.064, 0.063, 0.060, 0.050, 0.040]
        wts = [{ft: 1}, {ft: 1}, {ft: 1}, {ft: 1}, blend(ft, to, 0.5), {to: 1}, {to: 1}, {to: 1}]
        tops = [0.10, 0.145, 0.150, 0.110, 0.095, 0.082, 0.068, 0.050]
        # the sole: a slab, crisp edged
        sole = [bring(z, sole_t, h + 0.004, w, col=SOLE, sq=5.0) for z, h, w in zip(zs, hw, wts)]
        sole[0]["r1"] *= 0.9
        sole[-1]["r1"] *= 0.9
        shell(sk, "SuitFabric", sole, 8, hard=(), a0=0.0, tile=0.25,
              cap0=-Z, cap1=Z)
        upper = [bring(z, t * k, h, w, y0=sole_t - 0.002 * k) for z, h, w, t in zip(zs, hw, wts, tops)]
        shell(sk, "SuitFabric", upper, 12, a0=0.0, tile=0.25, cap0=-Z, cap1=Z)
        # the ankle bearing on the boot's collar
        sk.add_model(ring_model("metal", 0.058 * k, 0.072 * k, 0.026 * k, ch=0.0, segs=12), ft,
                     M=frame_to(-axs), t=A - axs * 0.07 * k)
        cl = Model()
        lathe(cl, "boot", [(0.068 * k, 0.0), (0.068 * k, 0.05 * k), (0.060 * k, 0.05 * k)],
              segs=12, uv_m=4.0)
        sk.add_model(cl, ft, M=frame_to(-axs), t=A - axs * 0.032 * k)

    sk.unpose(D)
    return sk


def pin_centre(sk, want):
    """Two zero-area triangles that put the rest-pose box's centre back where
    the old body's was (see the module notes)."""
    mn, mx = sk.bounds()
    want = np.asarray(want)
    lo, hi = mn.copy(), mx.copy()
    for a in range(3):
        c = (lo[a] + hi[a]) / 2
        if c < want[a]:
            hi[a] = 2 * want[a] - lo[a]
        else:
            lo[a] = 2 * want[a] - hi[a]
    P = np.array([lo, lo, lo, hi, hi, hi])
    J, W = sk._w({"Back": 1}, 6)
    sk.add("SuitShell", P, np.tile(Y, (6, 1)), np.zeros((6, 2)), np.tile(PAL["shell"][1], (6, 1)), J, W,
           np.array([[0, 1, 2], [3, 4, 5]]))
    mn2, mx2 = sk.bounds()
    return (mn2 + mx2) / 2


# ═════════════════════════════════════════════════════════════════════════════
# writing
# ═════════════════════════════════════════════════════════════════════════════

MAT_ORDER = ["SuitFabric", "SuitShell", "SuitMetal", "SuitVisor", "SuitDecal", "SuitLamp"]


def write_suit(sk, rig, path):
    src = rig.json
    bin_ = bytearray()
    views, accs, prims, mats = [], [], [], []

    def view(data, target=None):
        nonlocal bin_
        while len(bin_) % 4:
            bin_ += b"\0"
        off = len(bin_)
        bin_ += data
        v = {"buffer": 0, "byteOffset": off, "byteLength": len(data)}
        if target:
            v["target"] = target
        views.append(v)
        return len(views) - 1

    for mat in MAT_ORDER:
        if mat not in sk.parts:
            continue
        e = sk.parts[mat]
        P = np.vstack(e["P"]).astype(np.float32)
        N = np.vstack(e["N"])
        N = (N / np.maximum(np.linalg.norm(N, axis=1, keepdims=True), 1e-9)).astype(np.float32)
        UV = np.vstack(e["UV"]).astype(np.float32)
        # colours and weights as normalised bytes (glTF allows both): a
        # quarter of the size, and a byte is finer than the palette needs
        C = np.hstack([np.clip(np.vstack(e["C"]), 0, 1), np.ones((len(P), 1))])
        C = np.round(C * 255).astype(np.uint8)
        Jn = np.vstack(e["J"]).astype(np.uint8)
        W = np.round(np.vstack(e["W"]) * 255).astype(np.int32)
        W[np.arange(len(W)), W.argmax(1)] += 255 - W.sum(1)      # each row sums to exactly 255
        W = W.astype(np.uint8)
        I = sk.faces(mat).astype(np.uint32).reshape(-1)
        attrs = {}
        for name, arr, ct, ty, tgt in (("POSITION", P, 5126, "VEC3", 34962), ("NORMAL", N, 5126, "VEC3", 34962),
                                       ("TEXCOORD_0", UV, 5126, "VEC2", 34962), ("COLOR_0", C, 5121, "VEC4", 34962),
                                       ("JOINTS_0", Jn, 5121, "VEC4", 34962), ("WEIGHTS_0", W, 5121, "VEC4", 34962)):
            a = {"bufferView": view(arr.tobytes(), tgt), "componentType": ct, "count": len(arr), "type": ty}
            if name in ("COLOR_0", "WEIGHTS_0"):
                a["normalized"] = True
            if name == "POSITION":
                a["min"] = P.min(0).tolist(); a["max"] = P.max(0).tolist()
            accs.append(a)
            attrs[name] = len(accs) - 1
        if len(P) < 65536:
            accs.append({"bufferView": view(I.astype(np.uint16).tobytes(), 34963), "componentType": 5123,
                         "count": len(I), "type": "SCALAR"})
        else:
            accs.append({"bufferView": view(I.tobytes(), 34963), "componentType": 5125, "count": len(I),
                         "type": "SCALAR"})
        mats.append({"name": mat, "pbrMetallicRoughness": {"baseColorFactor": [1, 1, 1, 1],
                                                           "metallicFactor": 0.0, "roughnessFactor": 0.8}})
        prims.append({"attributes": attrs, "indices": len(accs) - 1, "material": len(mats) - 1})
    accs.append({"bufferView": view(rig.ibm_bytes), "componentType": 5126, "count": len(rig.ibm_bytes) // 64,
                 "type": "MAT4"})
    ibm_acc = len(accs) - 1
    nodes = json.loads(json.dumps(src["nodes"]))
    skin = dict(src["skins"][0])
    skin["inverseBindMatrices"] = ibm_acc
    gl = {"asset": {"version": "2.0", "generator": "Solar tools/gen_suit.py",
                    "copyright": "Rig: Clint Bellanger 2009, CC-BY-SA 3.0. Suit: Solar, CC-BY-SA 3.0."},
          "scene": src.get("scene", 0), "scenes": src["scenes"], "nodes": nodes,
          "meshes": [{"name": "EVASuit", "primitives": prims}], "skins": [skin],
          "materials": mats, "accessors": accs, "bufferViews": views,
          "buffers": [{"byteLength": len(bin_)}]}
    nodes[rig.mesh_node]["mesh"] = 0
    js = json.dumps(gl, separators=(",", ":")).encode()
    while len(js) % 4:
        js += b" "
    while len(bin_) % 4:
        bin_ += b"\0"
    total = 12 + 8 + len(js) + 8 + len(bin_)
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, total))
        f.write(struct.pack("<II", len(js), 0x4E4F534A)); f.write(js)
        f.write(struct.pack("<II", len(bin_), 0x004E4942)); f.write(bytes(bin_))


# ── the AstroModel's materials (scenes/system.ron) ──────────────────────────

def _set(name, normal=1.0, rough=1.0, metal=1.0):
    t = TEX + name
    return (f'(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("{t}_albedo.png"),\n'
            f'                normal_map: Some("{t}_normal.png"),\n                normal_strength: {normal},\n'
            f'                roughness_map: Some("{t}_orm.png"),\n                roughness: {rough},\n'
            f'                metallic_map: Some("{t}_orm.png"),\n                metallic: {metal},\n'
            f'                ao_map: Some("{t}_orm.png"),\n                shading: Physical,\n            )')


SUIT_MATS = {
    "SuitFabric": lambda: _set("fabric", normal=0.8),
    "SuitShell":  lambda: _set("shell", normal=0.6),
    "SuitMetal":  lambda: ('(\n                color: (1.0, 1.0, 1.0),\n'
                           '                texture: Some("textures/parts/metal_albedo.png"),\n'
                           '                normal_map: Some("textures/parts/metal_normal.png"),\n'
                           '                roughness_map: Some("textures/parts/metal_orm.png"),\n'
                           '                roughness: 0.7,\n'
                           '                metallic_map: Some("textures/parts/metal_orm.png"),\n'
                           '                metallic: 0.6,\n'
                           '                shading: Physical,\n            )'),
    "SuitVisor":  lambda: (f'(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("{TEX}visor.png"),\n'
                           '                roughness: 0.12,\n                metallic: 0.55,\n'
                           '                shading: Physical,\n            )'),
    "SuitDecal":  lambda: (f'(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("{TEX}decals.png"),\n'
                           '                roughness: 0.75,\n                metallic: 0.0,\n'
                           '                shading: Physical,\n            )'),
    "SuitLamp":   lambda: ('(\n                color: (1.0, 0.95, 0.86),\n'
                           '                texture: Some("textures/base/lens.png"),\n'
                           '                unlit: true,\n                fog: false,\n            )'),
}


def mats_block(indent="            "):
    """The AstroModel's object_materials, indented for its place in
    scenes/system.ron (the material strings are written for a prefab's
    depth, four spaces shallower)."""
    def deeper(t):
        return t.replace("\n", "\n    ")
    body = ",\n".join(f'{indent}    "{n}": {deeper(SUIT_MATS[n]())}' for n in MAT_ORDER)
    return f"{indent}object_materials: {{\n{body},\n{indent}}},\n"


def main():
    dry = "--dry" in sys.argv
    if not dry:
        textures()
    for sex in ("male", "female"):
        path = os.path.join(MODELS, f"astronaut_{sex}.glb")
        rig = Rig(path)
        sk = build_suit(rig)
        c = pin_centre(sk, REST_CENTRE[sex])
        mn, mx = sk.bounds()
        per = {m: len(sk.faces(m)) for m in sk.parts}
        print(f"{sex:6s} tris {sk.tris()} {per} box {np.round(mn, 3).tolist()}..{np.round(mx, 3).tolist()} "
              f"centre {np.round(c, 5).tolist()} (want {np.round(REST_CENTRE[sex], 5).tolist()})")
        if not dry:
            write_suit(sk, rig, path)
    if "--mats" in sys.argv:
        print(mats_block())
    if "--scene" in sys.argv and not dry:
        write_scene_mats()


def write_scene_mats(path=os.path.join(ROOT, "scenes", "system.ron")):
    """Put SUIT_MATS on the AstroModel in scenes/system.ron — that node's
    object_materials only; nothing else in the scene is touched."""
    r = open(path).read()
    i = r.index('name: "AstroModel"')
    end = r.index("            scripts: [", i)
    a = r.find("            object_materials: {", i, end)
    a = end if a < 0 else a
    r = r[:a] + mats_block() + r[end:]
    with open(path, "w") as f:
        f.write(r)
    print("scenes/system.ron: the AstroModel's object_materials written")


if __name__ == "__main__":
    main()
