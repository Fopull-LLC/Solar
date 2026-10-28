#!/usr/bin/env python3
"""neck_check.py — does any neck show where it must not? (tools/gen_faces.py)

The crew's head hangs rigid on the suit's Head bone; the suit keeps a short
neck of its own, skinned between its Back and Head bones, and the head brings
its own neck down into the ring. This sweeps the head through its range
(yaw, pitch, roll about the Head bone) and the face through its expressions
(jaw open to the full), and casts rays the way a viewer sees:

  * into an OPEN MOUTH from in front: the first thing hit must be the mouth's
    lining, the teeth or the tongue (or the lips' own front) — never the
    head's outer skin seen from inside (the neck or the throat showing
    through the mouth's floor) nor the suit's neck;
  * up at the JAW from below and in front: the first thing hit must be the
    head's skin, never the suit's neck poking out through the chin or throat.

    python3 tools/perf/neck_check.py [--heads 1,5] [--quick]

Prints one line per (head, pose, expression) with a fault, then a summary;
exits 1 if anything showed.
"""
import json
import math
import os
import struct
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import gen_faces as GF  # noqa: E402
from gen_suit import Rig  # noqa: E402

ROOT = os.path.join(HERE, "..", "..")


def read_glb(path):
    b = open(path, "rb").read()
    jl = struct.unpack("<I", b[12:16])[0]
    j = json.loads(b[20:20 + jl])
    off = 20 + jl
    bl = struct.unpack("<I", b[off:off + 4])[0]
    return j, b[off + 8:off + 8 + bl]


def acc(j, B, i):
    a = j["accessors"][i]
    v = j["bufferViews"][a["bufferView"]]
    o = v.get("byteOffset", 0) + a.get("byteOffset", 0)
    dt = {5126: np.float32, 5123: np.uint16, 5125: np.uint32, 5121: np.uint8}[a["componentType"]]
    n = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}[a["type"]]
    arr = np.frombuffer(B[o:o + a["count"] * n * np.dtype(dt).itemsize], dt).reshape(a["count"], n)
    return arr


def suit_neck():
    """The suit's neck (SuitHead): bind positions, triangles, its Head share."""
    path = os.path.join(ROOT, "models", "astronaut", "astronaut_male.glb")
    j, B = read_glb(path)
    rig = Rig(path)
    for p in j["meshes"][0]["primitives"]:
        if j["materials"][p["material"]]["name"] != "SuitHead":
            continue
        P = acc(j, B, p["attributes"]["POSITION"]).astype(float)
        I = acc(j, B, p["indices"]).reshape(-1, 3).astype(int)
        Jt = acc(j, B, p["attributes"]["JOINTS_0"]).astype(int)
        Wt = acc(j, B, p["attributes"]["WEIGHTS_0"]).astype(float) / 255.0
        hi = rig.index["Head"]
        w_head = (Wt * (Jt == hi)).sum(1)
        return P, I, w_head, rig
    raise SystemExit("no SuitHead in the suit")


def rot(yaw, pitch, roll):
    cy, sy = math.cos(yaw), math.sin(yaw)
    cp, sp = math.cos(pitch), math.sin(pitch)
    cr, sr = math.cos(roll), math.sin(roll)
    Ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    Rx = np.array([[1, 0, 0], [0, cp, -sp], [0, sp, cp]])
    Rz = np.array([[cr, -sr, 0], [sr, cr, 0], [0, 0, 1]])
    return Ry @ Rx @ Rz


def rays_first_hit(O, D, tris):
    """Möller–Trumbore, every ray against every triangle: (distance, index)."""
    v0, v1, v2 = tris[:, 0], tris[:, 1], tris[:, 2]
    e1, e2 = v1 - v0, v2 - v0
    best_t = np.full(len(D), np.inf)
    best_i = np.full(len(D), -1)
    for k in range(len(D)):
        d = D[k]
        p = np.cross(d, e2)
        det = (e1 * p).sum(1)
        ok = np.abs(det) > 1e-14
        inv = np.where(ok, 1.0 / np.where(ok, det, 1), 0)
        s = O[k] - v0
        u = (s * p).sum(1) * inv
        q = np.cross(s, e1)
        v = (q @ d) * inv
        t = (e2 * q).sum(1) * inv
        hit = ok & (u >= 0) & (v >= 0) & (u + v <= 1) & (t > 1e-6)
        if hit.any():
            i = np.argmin(np.where(hit, t, np.inf))
            best_t[k], best_i[k] = t[i], i
    return best_t, best_i


def posed_head(parts, hd, channels):
    """Head-local points per material with the expression's channels (summed
    morph offsets, as face.lua's adapter places the bones)."""
    out = {}
    for mat in ("FaceSkin", "FaceMouth"):
        e = parts[mat]
        P = np.vstack(e["P"])
        Jw, Ww = GF.top4(np.vstack(e["W"]))
        Q = P.copy()
        for ch, w in channels.items():
            if ch in GF.channel_entries() and w:
                Q += w * GF.bake_channel(hd, ch, P, Jw, Ww)
        out[mat] = (Q, np.vstack(e["I"]), np.vstack(e["C"]))
    return out


EXPRS = {
    "neutral": {},
    "jaw_full": {"jaw_open": 1.0, "lip_down": 1.0},
    "excited": {"smile_L": 1, "smile_R": 1, "cheek_L": 1, "cheek_R": 1, "jaw_open": 0.5, "lip_up": 0.6, "lip_down": 0.15,
                "stretch_L": 0.3, "stretch_R": 0.3},
    "panic": {"jaw_open": 0.8, "lip_down": 0.85, "lip_up": 0.5, "stretch_L": 0.9, "stretch_R": 0.9},
}


def main():
    heads = [int(x) for x in (sys.argv[sys.argv.index("--heads") + 1].split(",") if "--heads" in sys.argv else
                                 "1,2,3,4,5,6,7,8".split(","))]
    quick = "--quick" in sys.argv
    NP, NI, w_head, rig = suit_neck()
    pivot = rig.p("Head")
    HC = GF.HC
    poses = [(0, 0, 0)]
    for yw in (-55, -30, 30, 55):
        poses.append((yw, 0, 0))
    for pt in (-40, -20, 20, 40):
        poses.append((0, pt, 0))
    for rl in (-25, 25):
        poses.append((0, 0, rl))
    poses += [(40, 30, 15), (-40, -30, -15), (40, -35, 0), (-40, 35, 0)]
    if quick:
        poses = poses[:1] + poses[3:4] + poses[6:9:2]
    faults = 0
    checks = 0
    for hn in heads:
        parts, hd = GF.build_head(GF.HEADS[hn - 1])
        lm = hd["lm"]
        my = lm["mouth_y"]
        zf = GF.GB._surface_z(hd["P"], 0.0, my, r=0.003)
        for ename, ch in EXPRS.items():
            ph = posed_head(parts, hd, ch)
            S, SI, SC = ph["FaceSkin"]
            M, MI, _ = ph["FaceMouth"]
            lining = SC[:, 3] < 0.8                           # the mouth's lining (alpha 0.55..1 encodes it)
            for (yw, pt, rl) in poses:
                R = rot(math.radians(yw), math.radians(pt), math.radians(rl))
                # the head, rigid on the Head bone (bind space)
                def head_to_world(Pl):
                    return (Pl + HC - pivot) @ R.T + pivot
                Sw = head_to_world(S)
                Mw = head_to_world(M)
                # the suit's neck: Back fixed, Head turned, blended by weight
                Nw = NP + (w_head[:, None] * ((NP - pivot) @ R.T + pivot - NP))
                tris = np.concatenate([Sw[SI], Mw[MI], Nw[NI]])
                kind = np.concatenate([np.where(lining[SI].sum(1) >= 2, 1, 0),   # 1 lining
                                       np.full(len(MI), 2),                      # 2 teeth / tongue
                                       np.full(len(NI), 3)])                     # 3 suit neck
                # outer skin that has no business being seen through the mouth:
                # the throat and the neck (well behind the lips, below them)
                rest = np.vstack(parts["FaceSkin"]["P"])
                deep_outer = (rest[SI][:, :, 2].mean(1) < zf - 0.02) & (rest[SI][:, :, 1].mean(1) < my + 0.01)
                skin_is_front = np.concatenate([~deep_outer, np.zeros(len(MI) + len(NI), bool)])
                # into the mouth: from 15 cm in front, aimed at points behind the lips
                origin = head_to_world(np.array([[0.0, my - 0.006, zf + 0.15]]))[0]
                targets = []
                for tx in np.linspace(-0.016, 0.016, 5):
                    for ty in np.linspace(my - 0.016, my + 0.002, 5):
                        targets.append([tx, ty, zf - 0.03])
                T = head_to_world(np.array(targets))
                D = T - origin
                D /= np.linalg.norm(D, axis=1, keepdims=True)
                O = np.repeat(origin[None], len(D), 0)
                _, idx = rays_first_hit(O, D, tris)
                bad_mouth = 0
                for i in idx:
                    if i < 0:
                        continue
                    k = kind[i]
                    if k == 3 or (k == 0 and not skin_is_front[i]):
                        bad_mouth += 1
                        if os.environ.get("NECK_DEBUG") and k == 0:
                            print("   hit rest tri centre", np.round(rest[SI][i].mean(0), 4), "alpha", SC[SI][i][:, 3].round(2),
                                  "my", round(my, 4), "zf", round(zf, 4))
                # from below and in front of the chin, up at the jaw's underside and the throat
                # (from in front, a little below the chin: a viewer's eye, not
                # inside the suit; only what is above the neck ring's top counts)
                o2 = np.array([0.0, 0.0, 0.0]) + pivot + np.array([0.0, (lm["chin_low"] - 0.03) + HC[1] - pivot[1], lm["chin"][2] + 0.18 + HC[2] - pivot[2]])
                targets = []
                for tx in np.linspace(-0.035, 0.035, 5):
                    for tz in np.linspace(-0.02, lm["chin"][2], 5):
                        targets.append([tx, lm["chin_low"] - 0.005, tz])
                T2 = head_to_world(np.array(targets))
                D2 = T2 - o2
                D2 /= np.linalg.norm(D2, axis=1, keepdims=True)
                t2, idx2 = rays_first_hit(np.repeat(o2[None], len(D2), 0), D2, tris)
                ring_top = pivot[1] + 0.024                      # the HUT's neck ring (gen_suit_blender neck_top)
                hitp = o2 + D2 * np.where(np.isfinite(t2), t2, 0)[:, None]
                bad_chin = int(sum(1 for i, hp in zip(idx2, hitp) if i >= 0 and kind[i] == 3 and hp[1] > ring_top + 0.004))
                checks += 1
                if bad_mouth or bad_chin:
                    faults += 1
                    print(f"FAULT head {hn} {ename:8s} pose yaw {yw:+4d} pitch {pt:+4d} roll {rl:+4d}: "
                          f"mouth rays hitting neck/outer skin {bad_mouth}/25, chin rays hitting the suit's neck {bad_chin}/25")
    print(f"neck_check: {checks} (head, expression, pose) checks, {faults} with a fault")
    sys.exit(1 if faults else 0)


if __name__ == "__main__":
    main()
