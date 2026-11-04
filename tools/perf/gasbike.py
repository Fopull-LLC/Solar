#!/usr/bin/env python3
"""gasbike.py — the player's dirt bike (bike1.json) rebuilt on a gas engine,
for jumpprobe vhill (playtest 2026-11-03c).

    python3 tools/perf/gasbike.py IN.json OUT.json [--engine gasE250] [--pure]

The engine takes the Balance Gyro's place under the saddle (stacked on its
bottom), the swing arm moves onto the engine's rear face (a real bike's arm
pivots on the engine cases), the gyro goes onto the engine's front face, a
4 L Gas Tank sits on the gyro in front of the saddle, and a Drive Chain runs
from the engine's sprocket to the rear wheel's hub (the same geometry as
builder_attach chainBetween). --pure sets the front wheel's Drive off, so
only the gas engine drives (no hub motor). Reads the part figures from
scripts/parts_auto.lua by a light parse.
"""
import json
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SOL = os.path.dirname(os.path.dirname(HERE))


def dec(v):
    if isinstance(v, str) and v.startswith("\x00d:"):
        _, m, e = v.split(":")
        return int(m) * 2.0 ** int(e)
    return v


def rot_basis(yaw, pitch, roll):
    cy, sy = math.cos(yaw), math.sin(yaw)
    cx, sx = math.cos(pitch), math.sin(pitch)
    cz, sz = math.cos(roll), math.sin(roll)
    X = (cy * cz + sy * sx * sz, cx * sz, -sy * cz + cy * sx * sz)
    Y = (-cy * sz + sy * sx * cz, cx * cz, sy * sz + cy * sx * cz)
    Z = (sy * cx, -sx, cy * cx)
    return X, Y, Z


def euler(X, Y, Z):
    pitch = math.asin(max(-1, min(1, -Z[1])))
    yaw = math.atan2(Z[0], Z[2])
    roll = math.atan2(X[1], Y[1])
    return yaw, pitch, roll


def sub(a, b): return tuple(x - y for x, y in zip(a, b))
def add(a, b): return tuple(x + y for x, y in zip(a, b))
def mul(a, s): return tuple(x * s for x in a)
def dot(a, b): return sum(x * y for x, y in zip(a, b))
def norm(a):
    l = math.sqrt(dot(a, a))
    return mul(a, 1 / l)
def cross(a, b): return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def part_entry(pid):
    src = open(os.path.join(SOL, "scripts", "parts_auto.lua")).read()
    i = src.index(f"\n  {pid} ") + 1
    nxt = re.search(r"\n  (\w+\s+= \{|-- )", src[i + 4:])
    body = src[i:i + 4 + nxt.start()] if nxt else src[i:]
    def num(k):
        m = re.search(r"\b" + k + r" = (-?[0-9.]+)", body)
        return float(m.group(1)) if m else None
    lab = re.search(r'label = "([^"]+)"', body).group(1)
    pre = re.search(r'prefab = "([^"]+)"', body).group(1)
    out = dict(label=lab, prefab=pre, h=num("h"), rx=num("rx"), rz=num("rz"), mass=num("mass"), cost=num("cost"),
               strength=num("strength"))
    mods = []
    mm = re.search(r"mods = \{ \{ (.*?) \} \}", body, re.S)
    if mm:
        d = {}
        for k, v in re.findall(r'(\w+) = ("[^"]*"|-?[0-9.]+)', mm.group(1)):
            d[k] = v.strip('"') if v.startswith('"') else float(v)
        mods.append(d)
    out["mods"] = mods
    af = re.search(r'\baf = "([^"]*)"', body)
    out["af"] = af.group(1) if af else None
    return out


def record(base, uid, pid, x, y, z, yaw, pitch, roll, parent, att, extra=None):
    e = part_entry(pid)
    r = {k: 0 for k in ("fuel", "ec", "ve", "aero", "cargo", "radial", "burn", "fairing", "maxq", "chute", "thrust", "seat",
                        "decouple", "store", "fuel_t", "rcs_thrust", "rcs", "dock", "gen", "power", "solar", "comms", "legs",
                        "front", "claw", "stage", "sym")}
    r.update(dict(uid=uid, id=pid, prefab=e["prefab"], label=e["label"], h=e["h"], rx=e["rx"], rz=e["rz"], mass=e["mass"],
                  cost=e["cost"], strength=e["strength"], kind="structural", x=x, y=y, z=z, yaw=yaw, pitch=pitch, roll=roll,
                  parent=parent, att=att, mir="", wheel="", robo=""))
    if e["mods"]:
        r["mods"] = e["mods"]
    if e["af"]:
        r["af"] = e["af"]
    if extra:
        r.update(extra)
    return r


def main():
    a = sys.argv[1:]
    src, dst = a[0], a[1]
    eng = a[a.index("--engine") + 1] if "--engine" in a else "gasE250"
    pure = "--pure" in a
    d = json.load(open(src))
    bp = d["bp"]
    P = {p["uid"]: p for p in bp["parts"]}
    for p in bp["parts"]:
        for k in ("x", "y", "z", "yaw", "pitch", "roll"):
            p[k] = dec(p[k])
        # (the registry's aero spec, as the VAB's rollout gives it: the
        # library file predates it)
        try:
            af = part_entry(p["id"])["af"]
        except ValueError:
            af = None
        if af and not p.get("af"):
            p["af"] = af
    sad, gy, arm, rw, fw = P[3], P[6], P[8], P[9], P[5]
    E = part_entry(eng)
    m = E["mods"][0]
    hy = E["h"] / 2
    # the engine on the saddle's bottom, where the gyro was
    ey = sad["y"] - sad["h"] / 2 - hy
    # (set back by its length past the 250's, so the gyro on its front face
    # sits where it does on the 250 and clears the fork: on the 500, 3 cm
    # further forward, the builder's launch check called the gyro buried in
    # the fork)
    ex = sad["x"] - (E["rx"] - 0.18)
    EU = 20
    engine = record(bp, EU, eng, ex, ey, sad["z"], 0.0, 0.0, 0.0, 3, "bottom")
    # the gyro on the engine's front face
    gy["x"], gy["y"], gy["parent"], gy["att"] = ex + E["rx"] + gy["rx"], ey, EU, "surface"
    # the swing arm onto the engine's rear face, the wheel with it
    rear_face = ex - E["rx"]
    old_face = sad["x"] - 0.2      # the gyro's rear face
    dx = rear_face - old_face
    arm["x"] += dx
    arm["parent"] = EU
    rw["x"] += dx
    # the 4 L tank on the gyro
    TU, CU = 21, 22
    T = part_entry("gasTankS")
    tank = record(bp, TU, "gasTankS", gy["x"], ey + gy["h"] / 2 + T["h"] / 2, sad["z"], 0.0, 0.0, 0.0, 6, "top")
    # the chain: the engine's sprocket to the rear hub (chainBetween)
    a_ = (ex + m["sx"], ey + m["sy"], sad["z"] + m["sz"])
    X, _, _ = rot_basis(rw["yaw"], rw["pitch"], rw["roll"])
    c = (rw["x"], rw["y"], rw["z"])
    off = max(-0.18, min(0.18, dot(sub(a_, c), X)))
    b_ = add(c, mul(X, off))
    dd = sub(b_, a_)
    L = math.sqrt(dot(dd, dd))
    Y = norm(dd)
    Xc = norm(sub(X, mul(Y, dot(X, Y))))
    Z = cross(Xc, Y)
    yaw, pitch, roll = euler(Xc, Y, Z)
    mid = add(a_, mul(Y, L / 2))
    chain = record(bp, CU, "chain", mid[0], mid[1], mid[2], yaw, pitch, roll, EU, "surface",
                   dict(proc="chain", prof="chain", size=dict(len=L, prof="chain", e=EU, w=rw["uid"], teeth=48, front=int(m["front"]),
                                                               hubx=round(-off * dot(X, Xc), 3)),
                        h=L, mass=0.0016 * L, cost=int(4 * L + 6.5)))
    bp["parts"] = [p for p in bp["parts"]] + [engine, tank, chain]
    if pure:
        fw["wcfg"] = {"drive": "off"}
    links = [l for l in bp.get("links", []) if not (l.get("b") in (6, 8))]
    links += [dict(a=3, b=EU, k="stack", sa="bottom", sb="top", prim=1, pa=dict(x=ex - sad["x"], y=-sad["h"] / 2, z=0), pb=dict(x=0, y=hy, z=0), n=dict(x=0, y=-1, z=0)),
              dict(a=EU, b=6, k="surface", sa="surface", sb="surface", prim=1, pa=dict(x=E["rx"], y=0, z=0), pb=dict(x=-gy["rx"], y=0, z=0), n=dict(x=1, y=0, z=0)),
              dict(a=EU, b=8, k="surface", sa="surface", sb="surface", prim=1, pa=dict(x=-E["rx"], y=arm["y"] - ey, z=0), pb=dict(x=-arm["rx"], y=0, z=0), n=dict(x=-1, y=0, z=0)),
              dict(a=6, b=TU, k="stack", sa="top", sb="bottom", prim=1, pa=dict(x=0, y=gy["h"] / 2, z=0), pb=dict(x=0, y=-T["h"] / 2, z=0), n=dict(x=0, y=1, z=0)),
              dict(a=EU, b=CU, k="brace", sa="surface", sb="a", prim=1, pa=dict(x=m["sx"], y=m["sy"], z=m["sz"]), pb=dict(x=0, y=-L / 2, z=0), n=dict(x=0, y=0, z=-1)),
              dict(a=rw["uid"], b=CU, k="brace", sa="surface", sb="b", pa=dict(x=0, y=0, z=0), pb=dict(x=0, y=L / 2, z=0), n=dict(x=1, y=0, z=0))]
    bp["links"] = links
    bp["name"] = (bp.get("name") or "bike") + "-" + eng + ("-pure" if pure else "")
    json.dump(d, open(dst, "w"), indent=1)
    print(f"{dst}: {eng}{' (pure gas)' if pure else ''}; engine at ({ex:.3f}, {ey:.3f}), chain {L:.3f} m "
          f"from ({a_[0]:.3f}, {a_[1]:.3f}, {a_[2]:.3f}) to ({b_[0]:.3f}, {b_[1]:.3f}, {b_[2]:.3f})")


if __name__ == "__main__":
    main()
