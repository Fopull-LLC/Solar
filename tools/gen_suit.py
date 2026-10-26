#!/usr/bin/env python3
"""Generate the crew's EVA SUIT on the existing astronaut rig.

    python3 tools/gen_suit.py            # textures, both suits and their helmets
    python3 tools/gen_suit.py --scene    # … and the AstroModel's materials and
                                         #   helmet nodes in scenes/system.ron
    python3 tools/gen_suit.py --dry      # print the budget, write nothing

The geometry is MODELLED in Blender (tools/gen_suit_blender.py, run headless
from here: Blender is found through $BLENDER, then the Steam install, then
PATH); this file makes the textures, takes Blender's pieces back to the rig's
bind space, colours the wear into them, and writes the files.

Writes
    models/astronaut/astronaut_{male,female}.glb   the suit, skinned to each rig
    models/astronaut/helmet_{male,female}.glb      the helmet: bubble, EVVA
                                                   shell, ring, lamp housings
    models/astronaut/visor_{male,female}.glb       the gold sun visor
    models/astronaut/lamps_{male,female}.glb       the helmet lamps' lenses
    textures/suit/fabric_{albedo,normal,orm}.png   the TMG's ortho-fabric (512²)
    textures/suit/shell_{albedo,normal,orm}.png    the hard parts' paint (256²)
    textures/suit/decals.png                       patches, tapes, plates (512×256)
    textures/suit/visor.png                        the gold visor (128²)
    textures/suit/head.png                         the face under the cap (256²)

LOOK. An ISS EMU with Apollo A7L touches, grounded and worn: a cast hard upper
torso (HUT) — chest full, back flat for the pack, shoulders sloping to a
forward-tilted neck ring, scye bearings set into canted housings at its upper
corners — a display-and-control module on the lower chest with its control
face tipped up to the eyes; the PLSS high on the back, its top level with the
neck ring, a rounded top housing and the SOP under it; an EVVA over a clear
bubble with a gold visor, twin lamps and a camera at the temples; bearings at
the neck, waist, scyes, upper arms, thighs, wrists and ankles; gathered cloth
at the shoulders, pleats at the elbows and knees, a brief that hangs; gloves
with four fingers and RTV grip pads; boots that are one cast-looking shoe on a
dark sole. Signal orange three times only: the purge valve, the pack's grab
handles and the commander's thigh bands. Wear is coloured in per vertex
(`wear`): regolith on the boots, shins, knees and seat, grime on the gloves'
grips, scuffs on the hard parts. Under the helmet: a plain head in a comm cap
with its ear cups and mic booms.

THE HELMET COMES OFF. The helmet, its visor and its lamps are separate static
models, not part of the skinned suit: the scene hangs them on the Back bone
(an `attachment`, which is how the engine rides a node on a bone), so a script
hides or shows them (scripts/suit.lua). Each is written in the rig's bind
space; the engine centres a static model on its bounding box, so the scene's
attachment offset is the Back bone's inverse bind matrix times that centre
(`helmet_nodes`), and the visor's and lamps' nodes sit at their own centres
relative to the helmet's.

THE RIG IS NOT TOUCHED. The skeleton, its node tree, the rest pose (MaleArm's
½ scale included) and the inverse bind matrices are copied byte for byte from
the file being replaced — so every clip (tools/gen_astronaut_anims.py), the
leg and arm IK (scripts/planet_walker.lua, scripts/tool_belt.lua) and the
command seat's pose work unchanged. Only the mesh is new. Re-running reads
the rig back out of the suit it wrote, so the build is idempotent.

THE PLACEMENT IS NOT TOUCHED EITHER. The engine places a rigged model by the
centre of its rest-pose bounding box (gltf_rig.rs `center`), and the walker's
numbers (MA_UP, the AstroModel's −0.05 offset) were tuned against the old
body's box. Two zero-area anchor triangles pin the box's centre to the old
body's exactly (REST_CENTRE).

HOW IT BENDS: the soft suit is one skinned surface per chain, not pieces —
each arm (the cloth in the scye bearing, sleeve, elbow, gauntlet, palm, four
fingers and the thumb) one subdivided cage, the waist, brief and both legs one
mesh split at a shared crotch line — weight-painted by falloffs about each
joint, asymmetric (narrow on the crease, broad on the outside), and modelled
with the elbows and knees part-bent so linear blend skinning's worst bend is
halved. The gloves are skinned to the rig's finger chain and thumb bones. See
tools/gen_suit_blender.py's soft-suit notes. tools/suit_posecheck.py renders
the suit through the joints' ranges (and the hands open, in a fist, the wrist
bent) in Blender.

BUDGET. About 15,400 triangles for the suit (the head under the helmet
included; the two arms 3,000 each, the lower body 1,900) and 2,150 for the
helmet, visor and lamps; five materials on the
suit (SuitFabric, SuitShell, SuitMetal, SuitHead, SuitDecal) and four on the
helmet's models (SuitShell, SuitMetal, SuitBubble; SuitVisor; SuitLamp).
Textures: the cloth set 512², the shell set 256², decals 512×256, the face
256², the visor 128². Colour
within a material is a vertex colour (glTF COLOR_0), as the base's buildings
do it.

LICENCE. The rig (bones, rest pose, bind matrices) comes from Clint
Bellanger's "human.blend" (CC-BY-SA / GPL); the suit's geometry, weights and
textures are new. The suit files carry the rig, so they stay CC-BY-SA — see
models/astronaut/CREDITS.txt.
"""
import json
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_part_meshes import ROOT  # noqa: E402
from gen_part_textures import normal_from_height, smoothstep, spectral  # noqa: E402
import base_tex  # noqa: E402

TAU = 2 * math.pi
MODELS = os.path.join(ROOT, "models", "astronaut")
TEXDIR = os.path.join(ROOT, "textures", "suit")
TEX = "textures/suit/"
FONT_LABEL = os.path.join(ROOT, "fonts", "SolarLabel.ttf")
FONT_MONO = os.path.join(ROOT, "fonts", "SolarMono.ttf")
BLENDER_STEAM = "/mnt/disks/3tb/SteamLibrary/steamapps/common/Blender/blender"

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

CLOTH_RGB = (205, 200, 190)
REGOLITH = np.array([0.50, 0.45, 0.38])   # what the ground leaves on white cloth (a multiplier)

# Decal atlas regions (u0, v0, u1, v1), v down the image — gen_suit_blender.py
# maps its patches onto the same rectangles.
DECAL_W, DECAL_H = 512, 256
REG = {
    "emblem":  (0 / 512, 0 / 256, 128 / 512, 128 / 256),
    "placard": (128 / 512, 0 / 256, 384 / 512, 64 / 256),
    "display": (128 / 512, 64 / 256, 320 / 512, 160 / 256),
    "plss":    (320 / 512, 64 / 256, 512 / 512, 160 / 256),
    "flag":    (384 / 512, 0 / 256, 512 / 512, 64 / 256),
    "cuff":    (0 / 512, 128 / 256, 128 / 512, 256 / 256),
}


# ═════════════════════════════════════════════════════════════════════════════
# textures
# ═════════════════════════════════════════════════════════════════════════════

def save_rgb(arr, name):
    a = np.clip(arr, 0, 1)
    Image.fromarray((a * 255 + 0.5).astype(np.uint8), "RGB").save(os.path.join(TEXDIR, name), optimize=True)


def tex_fabric(n=512):
    """The TMG's outer ortho-fabric on a 0.25 m tile: a fine ripstop grid, the
    pillowed quilting of the insulation stitched through it on a 3 cm
    diamond, a double-stitched seam down the tile's edge (a loft's u = 0, which
    the builder turns to the inside of each limb), and the tired look of a
    suit that has been used: uneven bleaching, faint stains, fibres raised."""
    rng = np.random.default_rng(31)
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float32)
    mott = spectral(n, n, rng, beta=2.2, lo=1.5)
    stain = smoothstep(0.62, 0.92, spectral(n, n, rng, beta=2.4, lo=2))
    fib = spectral(n, n, rng, beta=0.6, sx=1.0, sy=0.25, lo=60)
    # ripstop: a heavier thread every 8 px (4 mm), both ways
    rip = np.maximum(np.exp(-((xx % 8) - 0) ** 2 / 0.8), np.exp(-((yy % 8) - 0) ** 2 / 0.8))
    weave = 0.5 + 0.5 * np.sin(xx * TAU / 2.0) * np.sin(yy * TAU / 2.0)
    # quilting: diamonds 64 px across (3 cm), stitched lines sunk, pillows up
    q = 64.0
    d1 = ((xx + yy) % q) / q
    d2 = ((xx - yy) % q) / q
    line = np.minimum(np.minimum(d1, 1 - d1), np.minimum(d2, 1 - d2)) * q
    pillow = smoothstep(0.0, 7.0, line)
    stitch_q = (line < 1.0) * (np.sin((xx + yy) * TAU / 5.0) > -0.2)
    # the seam at u = 0: a raised double row of stitches and a fold beside it
    du = np.minimum(xx, n - 1 - xx)
    fold = np.exp(-(du / 5.0) ** 2)
    stitch = ((np.abs(du - 6.0) < 0.9) | (np.abs(du - 10.0) < 0.9)) * (np.sin(yy * TAU / 7.0) > 0.0)
    v = 0.94 + (mott - 0.5) * 0.07 + (fib - 0.5) * 0.04 + (weave - 0.5) * 0.012 - rip * 0.018
    v -= (1 - pillow) * 0.012 + stitch_q * 0.012 + fold * 0.04 + stitch * 0.05
    alb = np.stack([v, v * 0.985, v * 0.955], -1)
    alb -= stain[..., None] * np.array([0.05, 0.06, 0.075])          # tea-coloured stains
    hgt = (pillow - 0.5) * 0.55 + (fib - 0.5) * 0.5 + (weave - 0.5) * 0.18 - rip * 0.25 - fold * 1.5 \
        - stitch * 0.5 - stitch_q * 0.15 + (mott - 0.5) * 1.4
    ao = 1 - (1 - pillow) * 0.08 - fold * 0.25
    rough = 0.90 + (fib - 0.5) * 0.06
    save_rgb(alb, "fabric_albedo.png")
    save_rgb(normal_from_height(hgt, 1.6), "fabric_normal.png")
    save_rgb(np.stack([ao, rough, np.zeros_like(v)], -1), "fabric_orm.png")


def tex_shell(n=256):
    """The hard parts: painted composite on a 0.5 m tile — orange-peel, a
    mottled bloom, scuffs and scratches through to a grey primer, and chips."""
    rng = np.random.default_rng(47)
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float32)
    mott = spectral(n, n, rng, beta=2.0, lo=2)
    peel = spectral(n, n, rng, beta=1.0, lo=30)
    scuff = smoothstep(0.78, 0.95, spectral(n, n, rng, beta=1.2, sx=1.0, sy=0.3, lo=8))
    chips = smoothstep(0.86, 0.93, spectral(n, n, rng, beta=0.4, lo=40)) * smoothstep(0.5, 0.8, mott)
    scr = np.zeros((n, n), np.float32)
    for _ in range(14):                  # scratches: thin straight lines
        x0, y0 = rng.uniform(0, n, 2)
        a = rng.uniform(0, math.pi)
        L = rng.uniform(10, 60)
        t = (xx - x0) * math.cos(a) + (yy - y0) * math.sin(a)
        dd = np.abs(-(xx - x0) * math.sin(a) + (yy - y0) * math.cos(a))
        scr = np.maximum(scr, (dd < 0.6) * (t > 0) * (t < L) * rng.uniform(0.4, 1.0))
    v = 0.94 + (mott - 0.5) * 0.05 - scuff * 0.06 - scr * 0.06 - chips * 0.25
    alb = np.stack([v, v * 0.99, v * 0.97], -1)
    hgt = (peel - 0.5) * 0.5 - scuff * 0.3 - scr * 0.6 - chips * 0.8
    rough = 0.48 + (mott - 0.5) * 0.10 + scuff * 0.22 + chips * 0.2
    save_rgb(alb, "shell_albedo.png")
    save_rgb(normal_from_height(hgt * 0.5, 0.9), "shell_normal.png")
    save_rgb(np.stack([np.ones_like(v) - chips * 0.2, rough, np.zeros_like(v)], -1), "shell_orm.png")


def tex_visor(n=128):
    """The gold sun visor. It reflects the world, so the world is painted in:
    warm sky over a darker ground with the horizon's bright band across the
    middle, a soft window highlight up and to the left, and the haze of fine
    scratches a used visor has."""
    rng = np.random.default_rng(5)
    yy, xx = (np.mgrid[0:n, 0:n] + 0.5) / n * 2 - 1
    gold = np.array([0.86, 0.60, 0.22])
    sky = np.clip(1.0 - (yy + 1) * 0.45, 0, 1)
    ground = smoothstep(0.02, 0.25, yy)
    band = np.exp(-((yy - 0.06) / 0.07) ** 2)
    curve = 0.75 + 0.25 * (1 - np.clip(xx * xx + yy * yy, 0, 1))
    lum = (0.55 + 0.35 * sky) * (1 - 0.55 * ground) + 0.35 * band
    lum *= curve
    hi = np.exp(-(((xx + 0.38) / 0.16) ** 2 + ((yy + 0.42) / 0.10) ** 2))
    haze = spectral(n, n, rng, beta=0.8, sx=1.0, sy=0.2, lo=20)
    alb = lum[..., None] * gold + hi[..., None] * np.array([0.45, 0.40, 0.30])
    alb *= (0.93 + 0.07 * haze)[..., None]
    save_rgb(alb, "visor.png")


def tex_head(n=256):
    """The face under the comm cap, painted in the head's own angles (the
    builder's projection: u = ½ + φ·0.2546, v = ½ − θ/2, φ the azimuth from
    straight ahead and θ the elevation, in radians — the same angles
    gen_suit_blender.py's FACE shapes the head with): an even, plain adult
    face — skin with its own unevenness, the eyes in their sockets' shadow,
    brows, the lip line, a day's stubble. Nothing stylised: most of what makes
    it a face is the geometry's light."""
    rng = np.random.default_rng(71)
    vv, uu = (np.mgrid[0:n, 0:n] + 0.5) / n
    phi = (uu - 0.5) / 0.2546
    th = (0.5 - vv) * 2.0
    skin = np.array([0.72, 0.55, 0.45])
    mott = spectral(n, n, rng, beta=2.0, lo=3)
    pores = spectral(n, n, rng, beta=0.3, lo=80)
    alb = skin[None, None] * (1.0 + (mott - 0.5) * 0.08 + (pores - 0.5) * 0.03)[..., None]

    def g(p, t, sp, st):
        return np.exp(-(((phi - p) / sp) ** 2 + ((th - t) / st) ** 2))

    def tint(mask, rgb, amt):
        alb[:] = alb * (1 - amt * mask[..., None]) + np.asarray(rgb)[None, None] * (amt * mask[..., None])
    # a little warmth on the cheeks and nose, the eye sockets' shadow
    tint(g(0.55, -0.12, 0.2, 0.12) + g(-0.55, -0.12, 0.2, 0.12) + g(0, -0.17, 0.08, 0.1),
         (0.74, 0.47, 0.40), 0.25)
    for sp in (-1, 1):
        tint(g(sp * 0.38, 0.10, 0.16, 0.07), (0.45, 0.33, 0.29), 0.35)
        # the eye: an almond of white-ish with the iris in it, lids above
        e = ((phi - sp * 0.40) / 0.105) ** 2 + ((th - 0.095) / 0.030) ** 2
        tint((e < 1.0).astype(float), (0.70, 0.66, 0.62), 0.85)
        ir = ((phi - sp * 0.392) / 0.034) ** 2 + ((th - 0.093) / 0.030) ** 2
        tint((ir < 1.0).astype(float), (0.24, 0.18, 0.14), 0.95)
        tint(((ir < 0.25)).astype(float), (0.05, 0.04, 0.04), 0.9)
        lid = (np.abs(e - 1.0) < 0.35) & (th > 0.093)
        tint(lid.astype(float), (0.30, 0.22, 0.19), 0.7)
        # the brow: a soft band, thicker inside, over the socket
        bt = 0.205 - 0.06 * ((phi - sp * 0.36) / 0.3) ** 2
        brow = np.exp(-((th - bt) / 0.018) ** 2) * np.exp(-((phi - sp * 0.36) / 0.20) ** 4)
        tint(brow * (0.6 + 0.4 * pores), (0.24, 0.19, 0.16), 0.75)
    # nostrils and the shadow under the nose
    for sp in (-1, 1):
        tint(g(sp * 0.07, -0.265, 0.03, 0.02), (0.25, 0.17, 0.15), 0.7)
    tint(g(0, -0.30, 0.10, 0.03), (0.55, 0.40, 0.34), 0.3)
    # the lips and their line
    lips = np.exp(-((phi / 0.20) ** 4 + ((th + 0.462) / 0.045) ** 2))
    tint(lips, (0.62, 0.40, 0.36), 0.35)
    tint(np.exp(-((phi / 0.18) ** 4 + ((th + 0.475) / 0.008) ** 2)), (0.30, 0.20, 0.18), 0.7)
    # stubble: the jaw, chin and upper lip
    stub = smoothstep(-0.36, -0.60, th) * np.exp(-(phi / 1.05) ** 4) * (1 - lips)
    tint(np.clip(stub, 0, 1) * (0.6 + 0.4 * pores), (0.46, 0.37, 0.32), 0.18)
    # the corner the comm cap samples: plain cloth (its colour is per vertex)
    alb[:8, :8] = 0.92
    save_rgb(alb, "head.png")


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
    # The name tape: printed capitals on an off-white tape, an orange tab.
    x0, y0, x1, y1 = px(REG["placard"])
    d.rectangle([x0, y0, x1 - 1, y1 - 1], fill=(222, 216, 200))
    d.rectangle([x0, y0, x0 + 30, y1 - 1], fill=(226, 128, 50))
    d.rectangle([x0 + 2, y0 + 2, x1 - 3, y1 - 3], outline=(60, 58, 52), width=2)
    f, b = _fit(d, "SOLAR  CDR  01", FONT_LABEL, x1 - x0 - 56, 40)
    d.text((x0 + 42 - b[0], y0 + (y1 - y0 - (b[3] - b[1])) / 2 - b[1]), "SOLAR  CDR  01", font=f, fill=(34, 32, 30))
    # The agency's flag (the right shoulder): a navy field, a pale disc for
    # the world and a band of signal orange under it — the emblem's colours.
    x0, y0, x1, y1 = px(REG["flag"])
    fl = Image.new("RGB", (x1 - x0, y1 - y0), CLOTH_RGB)
    fd = ImageDraw.Draw(fl)
    w_, h_ = fl.size
    fd.rectangle([4, 6, w_ - 5, h_ - 7], fill=(34, 42, 66))
    fd.rectangle([4, h_ - 20, w_ - 5, h_ - 13], fill=(214, 120, 52))
    fd.ellipse([w_ // 2 - 15, 12, w_ // 2 + 15, 42], fill=(208, 210, 204))
    fd.rectangle([2, 4, w_ - 3, h_ - 5], outline=(52, 52, 50), width=2)
    img.paste(fl, (x0, y0))
    # The chest display: green phosphor on green-black in a grey bezel.
    x0, y0, x1, y1 = px(REG["display"])
    d.rectangle([x0, y0, x1 - 1, y1 - 1], fill=(96, 96, 92))
    d.rectangle([x0 + 10, y0 + 10, x1 - 11, y1 - 11], fill=(10, 18, 12))
    fm = ImageFont.truetype(FONT_MONO, 20)
    for k, line in enumerate(("O2  4.31 PSI", "CO2 0.02  OK", "H2O  87 %  FAN")):
        d.text((x0 + 18, y0 + 16 + k * 22), line, font=fm, fill=(150, 226, 132) if k != 2 else (98, 150, 88))
    # The PLSS's back plate: a stencilled serial.
    x0, y0, x1, y1 = px(REG["plss"])
    d.rectangle([x0, y0, x1 - 1, y1 - 1], fill=(214, 208, 192))
    d.rectangle([x0 + 4, y0 + 4, x1 - 5, y1 - 5], outline=(70, 68, 62), width=2)
    f, b = _fit(d, "PLSS  S/N 0001", FONT_LABEL, x1 - x0 - 30, 22)
    d.text((x0 + 14 - b[0], y0 + 12 - b[1]), "PLSS  S/N 0001", font=f, fill=(40, 38, 34))
    f, b = _fit(d, "SOLAR SPACEFLIGHT", FONT_LABEL, x1 - x0 - 30, 18)
    d.text((x0 + 14 - b[0], y0 + 44 - b[1]), "SOLAR SPACEFLIGHT", font=f, fill=(90, 86, 78))
    # The cuff checklist's open page: a ruled card with numbered steps.
    x0, y0, x1, y1 = px(REG["cuff"])
    d.rectangle([x0, y0, x1 - 1, y1 - 1], fill=(226, 224, 214))
    d.rectangle([x0, y0, x1 - 1, y0 + 14], fill=(200, 120, 56))
    fs = ImageFont.truetype(FONT_MONO, 9)
    for k in range(10):
        yk = y0 + 20 + k * 10
        d.text((x0 + 6, yk), f"{k + 1:>2} ", font=fs, fill=(60, 58, 54))
        d.line([x0 + 24, yk + 6, x0 + 24 + int(40 + 50 * ((k * 37) % 10) / 10), yk + 6], fill=(90, 88, 82), width=2)
    for k in range(7):                   # the spiral binding at the top
        d.ellipse([x0 + 10 + k * 16, y0 + 3, x0 + 18 + k * 16, y0 + 11], outline=(70, 70, 70))
    img = base_tex.wear(img, 5, amount=0.10)
    img.save(os.path.join(TEXDIR, "decals.png"), optimize=True)


def textures():
    os.makedirs(TEXDIR, exist_ok=True)
    tex_fabric()
    tex_shell()
    tex_visor()
    tex_head()
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
        self.ibm = {n: m.astype(np.float64) for n, m in zip([j["nodes"][k]["name"] for k in skin["joints"]], ibm)}
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

    def add(self, mat, P, N, UV, C, J, W, I):
        e = self.parts.setdefault(mat, {"P": [], "N": [], "UV": [], "C": [], "J": [], "W": [], "I": [], "n": 0})
        P = np.asarray(P, float).reshape(-1, 3)
        e["P"].append(P); e["N"].append(np.asarray(N, float).reshape(-1, 3))
        e["UV"].append(np.asarray(UV, float).reshape(-1, 2)); e["C"].append(np.asarray(C, float).reshape(-1, 3))
        e["J"].append(np.asarray(J).reshape(-1, 4)); e["W"].append(np.asarray(W, float).reshape(-1, 4))
        e["I"].append(np.asarray(I, np.int64).reshape(-1, 3) + e["n"])
        e["n"] += len(P)

    def tris(self):
        return sum(len(self.faces(m)) for m in self.parts)

    def faces(self, mat):
        """The material's triangles less the zero-area ones (the anchors):
        the engine's box reads vertices, so the anchors' vertices still count
        without a triangle."""
        e = self.parts[mat]
        P = np.vstack(e["P"]); I = np.vstack(e["I"])
        a = np.linalg.norm(np.cross(P[I[:, 1]] - P[I[:, 0]], P[I[:, 2]] - P[I[:, 0]]), axis=1)
        return I[a > 1e-12]

    def bounds(self):
        P = np.vstack([np.vstack(e["P"]) for e in self.parts.values()])
        return P.min(0), P.max(0)


def unpose(P, N, Jn, W, D):
    """Everything was modelled in the AUTHORING pose, where joint i has moved
    by D[i] (a 4×4) from the bind pose. Take each vertex back to bind space
    through the inverse of its own blended transform, so that skinning with
    the rig's bind matrices draws it exactly as modelled when the bones are in
    the authoring pose."""
    M = np.einsum("nk,nkij->nij", W, D[Jn])
    P1 = np.hstack([P, np.ones((len(P), 1))])
    Pb = np.linalg.solve(M, P1[..., None])[..., 0][:, :3]
    Nb = np.einsum("nji,nj->ni", M[:, :3, :3], N)
    Nb /= np.maximum(np.linalg.norm(Nb, axis=1, keepdims=True), 1e-12)
    return Pb, Nb


# ── wear: dirt, grime and scuffs, coloured into the vertices ───────────────

def _noise(P, seed, freq):
    """Smooth 3-D value noise in [0, 1]."""
    P = np.asarray(P, float) * freq
    i = np.floor(P).astype(np.int64)
    f = P - i
    f = f * f * (3 - 2 * f)

    def h(ix, iy, iz):
        n = (ix * 73856093) ^ (iy * 19349663) ^ (iz * 83492791) ^ (seed * 2654435761)
        n = (n ^ (n >> 13)) * 1274126177
        return ((n ^ (n >> 16)) & 0xFFFF) / 65535.0
    out = 0.0
    for dx in (0, 1):
        for dy in (0, 1):
            for dz in (0, 1):
                w = (f[:, 0] if dx else 1 - f[:, 0]) * (f[:, 1] if dy else 1 - f[:, 1]) * (f[:, 2] if dz else 1 - f[:, 2])
                out = out + w * h(i[:, 0] + dx, i[:, 1] + dy, i[:, 2] + dz)
    return out


def wear(C, P, N, kind, rig):
    """How used the suit looks, per vertex, in BIND space (T-pose: y up, the
    feet at 0). Regolith rises from the boots up the shins, gathers on the
    knees' fronts and the seat, grime sits in the gloves' grips, the hard
    parts are scuffed; nothing is clean, nothing is filthy."""
    if kind in ("none", "decal"):
        return C
    k = rig.p("Head")[1] / 1.575
    y = P[:, 1] / k
    n1 = _noise(P, 3, 9.0)
    n2 = _noise(P, 7, 23.0)
    blot = np.clip((n1 * 0.7 + n2 * 0.3 - 0.45) * 2.2, 0, 1)
    a = np.zeros(len(P))
    if kind in ("leg", "boot", "seat", "body", "arm", "cap"):
        a += 0.10 * blot                                         # general grime
    if kind in ("leg", "boot"):
        a += np.clip((0.62 - y) / 0.62, 0, 1) ** 1.3 * (0.65 + 0.45 * blot)     # up the shins
        knee = (rig.p("Shin.Left")[1] + rig.p("Shin.Right")[1]) / 2 / k
        a += 0.65 * np.exp(-((y - knee) / 0.08) ** 2) * np.clip(N[:, 2] * 1.5 + 0.2, 0, 1) * (0.5 + 0.5 * n2)
    if kind == "boot":
        a = np.clip(a + 0.35 + 0.30 * n2, 0, 1)
    if kind == "seat":
        a += 0.35 * np.clip(-N[:, 2], 0, 1) * np.clip((1.10 - y) / 0.20, 0, 1) * (0.4 + 0.6 * blot)
    if kind == "glove":
        a += 0.25 + 0.35 * blot
    if kind == "arm":
        a += 0.12 * blot * np.clip(N[:, 1] * -1 + 0.3, 0, 1)
        # the arm is one surface down to the fingertips: the glove's grime
        # past each wrist (the Hand bone's head, along its axis)
        for side in ("Left", "Right"):
            B = rig.bind["Hand." + side]
            ax = B[:3, 1] / np.linalg.norm(B[:3, 1])
            g = np.clip(((P - B[:3, 3]) @ ax + 0.035 * k) / 0.03, 0, 1)
            a += g * (0.25 + 0.35 * blot)
    if kind in ("hut", "pack", "hard", "evva", "metal"):
        sc = np.clip((n2 - 0.62) * 4, 0, 1)
        a += 0.25 * sc + (0.08 * blot if kind != "metal" else 0)
        if kind == "pack":
            a += 0.20 * np.clip((1.10 - y) / 0.15, 0, 1)
    a = np.clip(a, 0, 0.85)
    tint = 1 - a[:, None] * (1 - REGOLITH[None, :])
    if kind in ("hut", "pack", "hard", "evva", "metal"):
        tint = 1 - a[:, None] * (1 - np.array([0.62, 0.60, 0.57]))[None, :]
    var = 1 + (n1 - 0.5)[:, None] * 0.05                         # the cloth's own unevenness
    return np.clip(C * tint * var, 0, 1)


# ═════════════════════════════════════════════════════════════════════════════
# Blender, and back
# ═════════════════════════════════════════════════════════════════════════════

def blender_bin():
    for b in (os.environ.get("BLENDER"), BLENDER_STEAM, shutil.which("blender")):
        if b and os.path.exists(b):
            return b
    sys.exit("gen_suit: Blender not found (set $BLENDER)")


def run_blender(rig_path, out):
    cmd = [blender_bin(), "--background", "--factory-startup", "--python",
           os.path.join(ROOT, "tools", "gen_suit_blender.py"), "--", rig_path, out]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(out):
        sys.stderr.write(r.stdout[-4000:] + r.stderr[-4000:])
        sys.exit("gen_suit: the Blender stage failed")


def assemble(rig, npz):
    """The pieces back in bind space: the suit as a Skin, the helmet's three
    static models as {part: {mat: (P, N, UV, C, I)}}."""
    z = np.load(npz)
    D = z["D"]
    man = json.loads(bytes(z["manifest"]).decode())
    suit = Skin(rig)
    statics = {}
    for i, m in enumerate(man):
        P, N, UV, C = z[f"{i}_P"], z[f"{i}_N"], z[f"{i}_UV"], z[f"{i}_C"]
        Jn, W, I = z[f"{i}_J"], z[f"{i}_W"], z[f"{i}_I"]
        P, N = unpose(P, N, Jn, W, D)
        C = wear(C, P, N, m["dirt"], rig)
        if m["part"] == "suit":
            suit.add(m["mat"], P, N, UV, C, Jn, W, I)
        else:
            e = statics.setdefault(m["part"], {}).setdefault(m["mat"], {"P": [], "N": [], "UV": [], "C": [], "I": [],
                                                                        "n": 0})
            e["P"].append(P); e["N"].append(N); e["UV"].append(UV); e["C"].append(C)
            e["I"].append(I + e["n"]); e["n"] += len(P)
    return suit, statics, man


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
    J = np.tile([sk.rig.index["Back"], 0, 0, 0], (6, 1))
    W = np.tile([1.0, 0, 0, 0], (6, 1))
    sk.add("SuitShell", P, np.tile([0, 1, 0], (6, 1)), np.zeros((6, 2)), np.ones((6, 3)), J, W,
           np.array([[0, 1, 2], [3, 4, 5]]))
    mn2, mx2 = sk.bounds()
    return (mn2 + mx2) / 2


# ═════════════════════════════════════════════════════════════════════════════
# writing
# ═════════════════════════════════════════════════════════════════════════════

MAT_ORDER = ["SuitFabric", "SuitShell", "SuitMetal", "SuitHead", "SuitDecal", "SuitBubble", "SuitVisor", "SuitLamp"]


class GlbWriter:
    def __init__(self):
        self.bin = bytearray()
        self.views, self.accs, self.prims, self.mats = [], [], [], []

    def view(self, data, target=None):
        while len(self.bin) % 4:
            self.bin += b"\0"
        off = len(self.bin)
        self.bin += data
        v = {"buffer": 0, "byteOffset": off, "byteLength": len(data)}
        if target:
            v["target"] = target
        self.views.append(v)
        return len(self.views) - 1

    def prim(self, mat, P, N, UV, C, I, J=None, W=None):
        P = np.asarray(P, np.float32)
        N = np.asarray(N, float)
        N = (N / np.maximum(np.linalg.norm(N, axis=1, keepdims=True), 1e-9)).astype(np.float32)
        UV = np.asarray(UV, np.float32)
        # colours and weights as normalised bytes: a quarter of the size, and
        # a byte is finer than the palette needs
        Cb = np.round(np.hstack([np.clip(C, 0, 1), np.ones((len(P), 1))]) * 255).astype(np.uint8)
        cols = [("POSITION", P, 5126, "VEC3"), ("NORMAL", N, 5126, "VEC3"), ("TEXCOORD_0", UV, 5126, "VEC2"),
                ("COLOR_0", Cb, 5121, "VEC4")]
        if J is not None:
            Wb = np.round(np.asarray(W) * 255).astype(np.int32)
            Wb[np.arange(len(Wb)), Wb.argmax(1)] += 255 - Wb.sum(1)      # each row sums to exactly 255
            cols += [("JOINTS_0", np.asarray(J).astype(np.uint8), 5121, "VEC4"),
                     ("WEIGHTS_0", Wb.astype(np.uint8), 5121, "VEC4")]
        attrs = {}
        for name, arr, ct, ty in cols:
            a = {"bufferView": self.view(arr.tobytes(), 34962), "componentType": ct, "count": len(arr), "type": ty}
            if name in ("COLOR_0", "WEIGHTS_0"):
                a["normalized"] = True
            if name == "POSITION":
                a["min"] = P.min(0).tolist(); a["max"] = P.max(0).tolist()
            self.accs.append(a)
            attrs[name] = len(self.accs) - 1
        I = np.asarray(I).reshape(-1)
        if len(P) < 65536:
            self.accs.append({"bufferView": self.view(I.astype(np.uint16).tobytes(), 34963), "componentType": 5123,
                              "count": len(I), "type": "SCALAR"})
        else:
            self.accs.append({"bufferView": self.view(I.astype(np.uint32).tobytes(), 34963), "componentType": 5125,
                              "count": len(I), "type": "SCALAR"})
        self.mats.append({"name": mat, "pbrMetallicRoughness": {"baseColorFactor": [1, 1, 1, 1],
                                                                "metallicFactor": 0.0, "roughnessFactor": 0.8}})
        self.prims.append({"attributes": attrs, "indices": len(self.accs) - 1, "material": len(self.mats) - 1})

    def write(self, path, gl):
        gl.update({"materials": self.mats, "accessors": self.accs, "bufferViews": self.views,
                   "buffers": [{"byteLength": len(self.bin)}]})
        js = json.dumps(gl, separators=(",", ":")).encode()
        while len(js) % 4:
            js += b" "
        while len(self.bin) % 4:
            self.bin += b"\0"
        total = 12 + 8 + len(js) + 8 + len(self.bin)
        with open(path, "wb") as f:
            f.write(struct.pack("<III", 0x46546C67, 2, total))
            f.write(struct.pack("<II", len(js), 0x4E4F534A)); f.write(js)
            f.write(struct.pack("<II", len(self.bin), 0x004E4942)); f.write(bytes(self.bin))


COPYRIGHT = "Rig: Clint Bellanger 2009, CC-BY-SA 3.0. Suit: Solar, CC-BY-SA 3.0."


def write_suit(sk, rig, path):
    src = rig.json
    g = GlbWriter()
    for mat in MAT_ORDER:
        if mat not in sk.parts:
            continue
        e = sk.parts[mat]
        g.prim(mat, np.vstack(e["P"]), np.vstack(e["N"]), np.vstack(e["UV"]), np.vstack(e["C"]), sk.faces(mat),
               np.vstack(e["J"]), np.vstack(e["W"]))
    g.accs.append({"bufferView": g.view(rig.ibm_bytes), "componentType": 5126, "count": len(rig.ibm_bytes) // 64,
                   "type": "MAT4"})
    nodes = json.loads(json.dumps(src["nodes"]))
    skin = dict(src["skins"][0])
    skin["inverseBindMatrices"] = len(g.accs) - 1
    nodes[rig.mesh_node]["mesh"] = 0
    g.write(path, {"asset": {"version": "2.0", "generator": "Solar tools/gen_suit.py", "copyright": COPYRIGHT},
                   "scene": src.get("scene", 0), "scenes": src["scenes"], "nodes": nodes,
                   "meshes": [{"name": "EVASuit", "primitives": g.prims}], "skins": [skin]})


def write_static(parts, path, name):
    """A plain (unskinned) model in the rig's bind space; returns its box centre
    (where the engine will put its origin)."""
    g = GlbWriter()
    allP = []
    for mat in MAT_ORDER:
        if mat not in parts:
            continue
        e = parts[mat]
        P = np.vstack(e["P"])
        allP.append(P)
        g.prim(mat, P, np.vstack(e["N"]), np.vstack(e["UV"]), np.vstack(e["C"]), np.vstack(e["I"]))
    g.write(path, {"asset": {"version": "2.0", "generator": "Solar tools/gen_suit.py", "copyright": COPYRIGHT},
                   "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"name": name, "mesh": 0}],
                   "meshes": [{"name": name, "primitives": g.prims}]})
    P = np.vstack(allP).astype(np.float32).astype(np.float64)
    return (P.min(0) + P.max(0)) / 2, sum(len(np.vstack(parts[m]["I"])) for m in parts)


# ── the scene: the AstroModel's materials and the helmet's nodes ────────────

def _set(name, normal=1.0, rough=1.0, metal=1.0):
    t = TEX + name
    return (f'(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("{t}_albedo.png"),\n'
            f'                normal_map: Some("{t}_normal.png"),\n                normal_strength: {normal},\n'
            f'                roughness_map: Some("{t}_orm.png"),\n                roughness: {rough},\n'
            f'                metallic_map: Some("{t}_orm.png"),\n                metallic: {metal},\n'
            f'                ao_map: Some("{t}_orm.png"),\n                shading: Physical,\n            )')


SUIT_MATS = {
    "SuitFabric": lambda: _set("fabric", normal=1.0),
    "SuitShell":  lambda: _set("shell", normal=0.7),
    "SuitMetal":  lambda: ('(\n                color: (1.0, 1.0, 1.0),\n'
                           '                texture: Some("textures/parts/metal_albedo.png"),\n'
                           '                normal_map: Some("textures/parts/metal_normal.png"),\n'
                           '                roughness_map: Some("textures/parts/metal_orm.png"),\n'
                           '                roughness: 0.7,\n'
                           '                metallic_map: Some("textures/parts/metal_orm.png"),\n'
                           '                metallic: 0.6,\n'
                           '                shading: Physical,\n            )'),
    "SuitHead":   lambda: (f'(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("{TEX}head.png"),\n'
                           '                roughness: 0.7,\n                metallic: 0.0,\n'
                           '                shading: Physical,\n            )'),
    "SuitDecal":  lambda: (f'(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("{TEX}decals.png"),\n'
                           '                roughness: 0.8,\n                metallic: 0.0,\n'
                           '                shading: Physical,\n            )'),
    "SuitBubble": lambda: ('(\n                color: (0.86, 0.90, 0.94),\n                alpha: 0.16,\n'
                           '                roughness: 0.06,\n                metallic: 0.0,\n'
                           '                blend: Some(Blend),\n                shading: Physical,\n            )'),
    "SuitVisor":  lambda: (f'(\n                color: (1.0, 1.0, 1.0),\n                texture: Some("{TEX}visor.png"),\n'
                           '                roughness: 0.14,\n                metallic: 0.6,\n'
                           '                shading: Physical,\n            )'),
    "SuitLamp":   lambda: ('(\n                color: (1.0, 0.95, 0.86),\n'
                           '                texture: Some("textures/base/lens.png"),\n'
                           '                unlit: true,\n                fog: false,\n            )'),
}
SUIT_ONLY = ["SuitFabric", "SuitShell", "SuitMetal", "SuitHead", "SuitDecal"]
HELMET_PARTS = {   # part: (node name, materials)
    "helmet": ("Helmet", ["SuitShell", "SuitMetal", "SuitBubble"]),
    "visor": ("Helmet Visor", ["SuitVisor"]),
    "lamps": ("Helmet Lamps", ["SuitLamp"]),
}


def mats_block(names, indent="            "):
    """object_materials for a node at `indent` in scenes/system.ron (the
    material strings are written for a prefab's depth, four spaces shallower)."""
    def deeper(t):
        return t.replace("\n", "\n    ")
    body = ",\n".join(f'{indent}    "{n}": {deeper(SUIT_MATS[n]())}' for n in names)
    return f"{indent}object_materials: {{\n{body},\n{indent}}},\n"


def helmet_offset(rig, centre):
    """The Helmet node's bone-local offset on Back: the bone's inverse bind
    matrix times the model's box centre, as translation, rotation (x, y, z, w)
    and a uniform scale (the armature's ½ undone)."""
    M = rig.ibm["Back"] @ np.array([[1, 0, 0, centre[0]], [0, 1, 0, centre[1]], [0, 0, 1, centre[2]], [0, 0, 0, 1.0]])
    s = float(np.cbrt(np.linalg.det(M[:3, :3])))
    R = M[:3, :3] / s
    # rotation matrix → quaternion
    tr = R[0, 0] + R[1, 1] + R[2, 2]
    if tr > 0:
        q = math.sqrt(tr + 1.0) * 2
        w, x, y, z = 0.25 * q, (R[2, 1] - R[1, 2]) / q, (R[0, 2] - R[2, 0]) / q, (R[1, 0] - R[0, 1]) / q
    elif R[0, 0] > R[1, 1] and R[0, 0] > R[2, 2]:
        q = math.sqrt(1.0 + R[0, 0] - R[1, 1] - R[2, 2]) * 2
        w, x, y, z = (R[2, 1] - R[1, 2]) / q, 0.25 * q, (R[0, 1] + R[1, 0]) / q, (R[0, 2] + R[2, 0]) / q
    elif R[1, 1] > R[2, 2]:
        q = math.sqrt(1.0 + R[1, 1] - R[0, 0] - R[2, 2]) * 2
        w, x, y, z = (R[0, 2] - R[2, 0]) / q, (R[0, 1] + R[1, 0]) / q, 0.25 * q, (R[1, 2] + R[2, 1]) / q
    else:
        q = math.sqrt(1.0 + R[2, 2] - R[0, 0] - R[1, 1]) * 2
        w, x, y, z = (R[1, 0] - R[0, 1]) / q, (R[0, 2] + R[2, 0]) / q, (R[1, 2] + R[2, 1]) / q, 0.25 * q
    return M[:3, 3].tolist(), [x, y, z, w], s


def _f(v):
    return repr(float(round(v, 7)))


def write_scene(rig, centres, path=os.path.join(ROOT, "scenes", "system.ron")):
    """The AstroModel's object_materials, and its helmet's three nodes (the
    Helmet on the Back bone, the Visor and the Lamps under it) — those nodes
    only; nothing else in the scene is touched."""
    r = open(path).read()
    i = r.index('name: "AstroModel"')
    end = r.index("            scripts: [", i)
    a = r.find("            object_materials: {", i, end)
    a = end if a < 0 else a
    r = r[:a] + mats_block(SUIT_ONLY) + r[end:]
    # the AstroModel's scene id, for the helmet's parent link
    blk = r[i:r.index("\n        ),\n", i)]
    astro_id = int(blk.split("id: Some(")[1].split(")")[0])
    names = [n.split('"')[1] for n in r.split("\n        (\n            name: ")[1:]]
    astro_idx = names.index("AstroModel")
    # drop old helmet nodes (keeping their ids), then append fresh ones at the
    # end of the node list
    old_ids = {}
    for part, (nm, _) in HELMET_PARTS.items():
        s = r.find(f'\n        (\n            name: "{nm}",')
        if s >= 0:
            e = r.index("\n        ),", s) + len("\n        ),")
            old_ids[part] = int(r[s:e].split("            id: Some(")[1].split(")")[0])
            r = r[:s] + r[e:]
    names = [n.split('"')[1] for n in r.split("\n        (\n            name: ")[1:]]
    used = [int(x.split(")")[0]) for x in r.split("            id: Some(")[1:]]
    # a block of ids of their own, clear of the scene's (other tools append
    # theirs one past the highest)
    nid = max(600, max(used) + 1)
    ids = {}
    t, q, s = helmet_offset(rig, centres["helmet"])
    nodes = []
    for part, (nm, mats) in HELMET_PARTS.items():
        if part in old_ids and old_ids[part] not in used:
            ids[part] = old_ids[part]
        else:
            ids[part] = nid
            nid += 1
        if part == "helmet":
            parent_idx, parent_id = astro_idx, astro_id
            tr = (0.0, 0.0, 0.0)
            att = (f'            attachment: Some((\n                bone: "Back",\n                offset: (\n'
                   f'                    translation: ({_f(t[0])}, {_f(t[1])}, {_f(t[2])}),\n'
                   f'                    rotation: ({_f(q[0])}, {_f(q[1])}, {_f(q[2])}, {_f(q[3])}),\n'
                   f'                    scale: ({_f(s)}, {_f(s)}, {_f(s)}),\n                ),\n            )),\n')
        else:
            parent_idx, parent_id = len(names), ids["helmet"]
            d = np.asarray(centres[part]) - np.asarray(centres["helmet"])
            tr = tuple(d.tolist())
            att = ""
        nodes.append(
            f'        (\n            name: "{nm}",\n            transform: (\n'
            f'                translation: ({_f(tr[0])}, {_f(tr[1])}, {_f(tr[2])}),\n'
            f'                rotation: (0.0, 0.0, 0.0, 1.0),\n                scale: (1.0, 1.0, 1.0),\n            ),\n'
            f'            matter: Mesh(\n                asset_path: "models/astronaut/{part}_male.glb",\n            ),\n'
            + mats_block(mats) +
            f'            scripts: [],\n            id: Some({ids[part]}),\n'
            f'            parent_id: Some({parent_id}),\n            parent: Some({parent_idx}),\n'
            + att + '        ),')
    # the node list ends at the scene's closing "    ],"
    close = r.rindex("\n    ],")
    r = r[:close] + "\n" + "\n".join(nodes) + r[close:]
    # the Astronaut's scripts: suit.lua (the helmet) after tool_belt, so its
    # hands go to the neck ring over the tool's hold
    i = r.index('\n            name: "Astronaut",')
    j = r.index("            rigidbody:", i)
    if 'kind: "suit",' not in r[i:j]:
        tb = r.index('kind: "tool_belt",', i, j)
        e = r.index("                ),\n", tb) + len("                ),\n")
        r = r[:e] + ('                (\n                    kind: "suit",\n                    enabled: true,\n'
                     '                    params: [],\n                ),\n') + r[e:]
    with open(path, "w") as f:
        f.write(r)
    print("scenes/system.ron: the AstroModel's object_materials and the helmet's nodes written")


def main():
    dry = "--dry" in sys.argv
    if not dry:
        textures()
    tmp = tempfile.mkdtemp(prefix="gen_suit_")
    centres = {}
    rig_male = None
    try:
        for sex in ("male", "female"):
            path = os.path.join(MODELS, f"astronaut_{sex}.glb")
            rig = Rig(path)
            if sex == "male":
                rig_male = rig
            npz = os.path.join(tmp, f"{sex}.npz")
            run_blender(path, npz)
            suit, statics, man = assemble(rig, npz)
            c = pin_centre(suit, REST_CENTRE[sex])
            mn, mx = suit.bounds()
            per = {m: len(suit.faces(m)) for m in suit.parts}
            print(f"{sex:6s} suit tris {suit.tris()} {per} box {np.round(mn, 3).tolist()}..{np.round(mx, 3).tolist()} "
                  f"centre {np.round(c, 5).tolist()} (want {np.round(REST_CENTRE[sex], 5).tolist()})")
            if "--pieces" in sys.argv:
                for m in sorted(man, key=lambda m: -m["tris"]):
                    print(f"    {m['tris']:6d}  {m['name']:24s} {m['mat']:11s} {m['part']}")
            if not dry:
                write_suit(suit, rig, path)
            for part in HELMET_PARTS:
                out = os.path.join(MODELS, f"{part}_{sex}.glb")
                if dry:
                    continue
                cen, n = write_static(statics[part], out, HELMET_PARTS[part][0])
                print(f"       {part:7s} tris {n} centre {np.round(cen, 4).tolist()}")
                if sex == "male":
                    centres[part] = cen
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if "--scene" in sys.argv and not dry:
        write_scene(rig_male, centres)


if __name__ == "__main__":
    main()
