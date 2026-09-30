#!/usr/bin/env python3
"""Generate the astronaut's animation clips and controller.

    python3 tools/gen_astronaut_anims.py          (from the Solar project root)

Writes animations/astronaut_male/*.anim.ron and
animation_controllers/character.actl.ron. Hand-editing those files is fine for
an experiment, but this script is the source: the cycles are parametric, so a
stride, a lean or an arm swing is one number here rather than two dozen
quaternions there.

WHY IT IS BUILT THIS WAY
The rig (models/astronaut/astronaut_male.glb) is read for its rest pose, and
every clip is POSED IN THE CHARACTER'S FRAME and then converted to the bones'
local rotations. The character faces +Z with +Y up and +X on its LEFT. Legs
are solved with two-bone IK against a foot path that moves backwards at
exactly the clip's authored ground speed while the foot is down, so a cycle
played at `speed / stride` per second does not skate — the walker relies on
the STRIDES table below matching what it reads from the clip durations.

Layers the walker drives (see planet_walker.lua):
  Base    idle / jump / fall / land — ordinary crossfaded states
  Gait    one BLEND STATE mixing walk, run and sprint by the `gait` parameter
          (0 walk, 1 run, 2 sprint), frozen (speed 0) and SCRUBBED by the
          walker to its phase; every clip in a blend plays at the same
          normalised time, so a walk blending into a run keeps its feet in step
Leaning, looking and planting the feet are not clips: the walker writes them
onto the bones each frame (anim:addBoneRot, anim:lookAt, anim:reach).
Gait phase 0 is the LEFT heel strike and 0.5 the right one, in every gait.
"""
import json, math, os, struct

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL = "models/astronaut/astronaut_male.glb"
OUT = "animations/astronaut_male"

# ── quaternion / vector helpers (x, y, z, w) ────────────────────────────────
def qmul(a, b):
    ax, ay, az, aw = a; bx, by, bz, bw = b
    return (aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw,
            aw * bw - ax * bx - ay * by - az * bz)
def qinv(q): return (-q[0], -q[1], -q[2], q[3])
def qnorm(q):
    l = math.sqrt(sum(c * c for c in q)); return tuple(c / l for c in q)
def qaxis(ax, ang):
    s = math.sin(ang / 2); return (ax[0] * s, ax[1] * s, ax[2] * s, math.cos(ang / 2))
def rx(a): return qaxis((1, 0, 0), a)
def ry(a): return qaxis((0, 1, 0), a)
def rz(a): return qaxis((0, 0, 1), a)
def qrot(q, v):
    p = qmul(qmul(q, (v[0], v[1], v[2], 0.0)), qinv(q)); return (p[0], p[1], p[2])
def add(a, b): return (a[0] + b[0], a[1] + b[1], a[2] + b[2])
def sub(a, b): return (a[0] - b[0], a[1] - b[1], a[2] - b[2])
def mul(a, k): return (a[0] * k, a[1] * k, a[2] * k)
def dot(a, b): return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
def cross(a, b): return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
def length(a): return math.sqrt(dot(a, a))
def unit(a):
    l = length(a); return (a[0] / l, a[1] / l, a[2] / l)
def arc(a, b):
    """Shortest rotation taking direction a onto direction b."""
    a, b = unit(a), unit(b)
    c = cross(a, b); d = dot(a, b)
    if d < -0.99999:
        return qaxis(unit(cross(a, (1, 0, 0))), math.pi)
    return qnorm((c[0], c[1], c[2], 1.0 + d))
def lerp(a, b, t): return a + (b - a) * t
def smooth(t): t = max(0.0, min(1.0, t)); return t * t * (3 - 2 * t)
def smoother(t): t = max(0.0, min(1.0, t)); return t * t * t * (t * (t * 6 - 15) + 10)
D = math.radians

# ── the rig ─────────────────────────────────────────────────────────────────
def load_rig():
    data = open(os.path.join(ROOT, MODEL), "rb").read()
    n = struct.unpack("<I", data[12:16])[0]
    gl = json.loads(data[20:20 + n])
    nodes = gl["nodes"]
    rig = {}
    def walk(i, parent):
        nd = nodes[i]
        rig[nd["name"]] = dict(parent=parent, t=tuple(nd.get("translation", (0, 0, 0))),
                               r=tuple(nd.get("rotation", (0, 0, 0, 1))),
                               s=nd.get("scale", [1, 1, 1])[0])
        for c in nd.get("children", []): walk(c, nd["name"])
    for r in gl["scenes"][0]["nodes"]: walk(r, None)
    # Rest world transforms (the armature root carries a uniform 0.5 scale).
    for name in rig: _world(rig, name)
    return rig

def _world(rig, name):
    b = rig[name]
    if "W" in b: return
    if b["parent"] is None:
        b["W"], b["P"], b["S"] = b["r"], b["t"], b["s"]
    else:
        _world(rig, b["parent"]); p = rig[b["parent"]]
        b["W"] = qmul(p["W"], b["r"])
        b["P"] = add(p["P"], mul(qrot(p["W"], b["t"]), p["S"]))
        b["S"] = p["S"] * b["s"]

RIG = load_rig()
W0 = {k: v["W"] for k, v in RIG.items()}
P0 = {k: v["P"] for k, v in RIG.items()}
LEN_THIGH = length(sub(P0["Shin.Left"], P0["Thigh.Left"]))
LEN_SHIN = length(sub(P0["Foot.Left"], P0["Shin.Left"]))
ANKLE_Y = P0["Foot.Left"][1]                    # ankle above the sole when flat
HEEL = (0.0, -ANKLE_Y, -0.06)                   # sole points, from the ankle
TOE = (0.0, -ANKLE_Y, 0.20)
SIDES = {"Left": 1.0, "Right": -1.0}            # +X is the character's left

# ── a pose, in the character's frame ────────────────────────────────────────
class Pose:
    def __init__(self):
        self.pelvis_off = (0.0, 0.0, 0.0)       # the Hip joint, from rest
        self.pelvis = (0, 0, 0, 1)              # pelvis rotation
        self.torso = (0, 0, 0, 1)               # chest, pivoting at the pelvis
        self.head = (0, 0, 0, 1)                # ABSOLUTE in the character frame
        self.arm = {s: dict(lower=D(76), swing=0.0, out=0.0, elbow=D(12), wrist=0.0, curl=0.3) for s in SIDES}
        # Leg: ankle target (character frame) and foot pitch (+ = toes up), or
        # None to hang the leg from `hip`/`knee` angles instead.
        self.ankle = {s: None for s in SIDES}
        self.foot_pitch = {s: 0.0 for s in SIDES}
        self.hip = {s: 0.0 for s in SIDES}      # forward flex, for hanging legs
        self.knee = {s: 0.0 for s in SIDES}

def rest_ankle(side, narrow=0.0):
    p = P0["Foot." + side]
    return (p[0] - SIDES[side] * narrow, ANKLE_Y, p[2])

def foot_ankle(flat_z, pitch, x):
    """Ankle position for a foot whose sole would sit with its ankle at
    `flat_z` when flat, rolled by `pitch` about the heel (toes up) or the toe
    (heel up) — the pivot that is actually on the ground."""
    piv = HEEL if pitch > 0 else TOE
    q = rx(-pitch)
    ground = (x, 0.0, flat_z + piv[2])
    return sub(ground, qrot(q, piv))

def solve(pose):
    """World rotations/positions for a pose, then the bones' local TRS."""
    W, P = {}, {}
    T = pose.torso
    hip = add(P0["Hip"], pose.pelvis_off)
    P["Back"] = sub(hip, qrot(T, sub(P0["Hip"], P0["Back"])))
    W["Back"] = qmul(T, W0["Back"])
    W["Hip"] = qmul(pose.pelvis, W0["Hip"]); P["Hip"] = hip
    W["Head"] = qmul(pose.head, W0["Head"])
    for side, sg in SIDES.items():
        a = pose.arm[side]
        # Lower from the T-pose (about Z), open out, swing forward (about X),
        # then the elbow hinge — which the lowering has turned into the
        # character's lateral axis, so a bend carries the hand forward.
        qa = qmul(rx(-a["swing"]), qmul(rz(sg * a["out"]), rz(-sg * a["lower"])))
        up = qmul(T, qa)
        W["Upperarm." + side] = qmul(up, W0["Upperarm." + side])
        fore = qmul(up, ry(-sg * a["elbow"]))
        W["Forearm." + side] = qmul(fore, W0["Forearm." + side])
        # Wrist and fingers flex toward the palm, which faces down in the
        # T-pose and so faces the thigh once the arm is lowered.
        hand = qmul(fore, rz(-sg * a["wrist"]))
        W["Hand." + side] = qmul(hand, W0["Hand." + side])
        W["Fingers1." + side] = qmul(qmul(hand, rz(-sg * a["curl"] * D(50))), W0["Fingers1." + side])
        W["Fingers2." + side] = qmul(qmul(hand, rz(-sg * a["curl"] * D(115))), W0["Fingers2." + side])
        # Legs.
        th = add(hip, qrot(pose.pelvis, sub(P0["Thigh." + side], P0["Hip"])))
        rest_th = qrot(pose.pelvis, sub(P0["Shin." + side], P0["Thigh." + side]))
        if pose.ankle[side] is not None:
            tgt = pose.ankle[side]
            v = sub(tgt, th); d = length(v)
            d = max(0.2, min(d, LEN_THIGH + LEN_SHIN - 1e-4))
            vn = unit(v)
            a1 = (LEN_THIGH ** 2 - LEN_SHIN ** 2 + d * d) / (2 * d)
            h = math.sqrt(max(0.0, LEN_THIGH ** 2 - a1 * a1))
            # The knee bends forward: the hint is the character's +Z, bent a
            # touch outward with the hip's rotation so it tracks the toes.
            hint = qrot(pose.pelvis, (sg * 0.08, 0.0, 1.0))
            pk = unit(sub(hint, mul(vn, dot(hint, vn))))
            knee = add(add(th, mul(vn, a1)), mul(pk, h))
            ankle = add(th, mul(vn, d))
        else:
            qd = qmul(pose.pelvis, rx(-pose.hip[side]))
            knee = add(th, mul(unit(qrot(qd, sub(P0["Shin." + side], P0["Thigh." + side]))), LEN_THIGH))
            kd = qmul(qd, rx(pose.knee[side]))
            ankle = add(knee, mul(unit(qrot(kd, sub(P0["Foot." + side], P0["Shin." + side]))), LEN_SHIN))
        dq = qmul(arc(rest_th, sub(knee, th)), pose.pelvis)
        W["Thigh." + side] = qmul(dq, W0["Thigh." + side])
        rest_sh = qrot(dq, sub(P0["Foot." + side], P0["Shin." + side]))
        sq = qmul(arc(rest_sh, sub(ankle, knee)), dq)
        W["Shin." + side] = qmul(sq, W0["Shin." + side])
        # The foot keeps to the character frame (flat on the ground unless
        # pitched), turned only with the pelvis.
        W["Foot." + side] = qmul(qmul(pose.pelvis, rx(-pose.foot_pitch[side])), W0["Foot." + side])
    # World → local.
    out = {}
    Wn = {"MaleArm": RIG["MaleArm"]["W"]}
    for name in ["Back", "Hip", "Head", "Upperarm.Left", "Upperarm.Right", "Forearm.Left",
                 "Forearm.Right", "Hand.Left", "Hand.Right", "Fingers1.Left", "Fingers1.Right",
                 "Fingers2.Left", "Fingers2.Right", "Thigh.Left", "Thigh.Right",
                 "Shin.Left", "Shin.Right", "Foot.Left", "Foot.Right"]:
        par = RIG[name]["parent"]
        pw = Wn[par]
        loc = qnorm(qmul(qinv(pw), W[name]))
        Wn[name] = W[name]
        t = RIG[name]["t"]
        if name == "Back":
            m = RIG["MaleArm"]
            t = mul(qrot(qinv(m["W"]), sub(P["Back"], m["P"])), 1.0 / m["S"])
        out[name] = (t, loc)
    return out

# ── gaits ───────────────────────────────────────────────────────────────────
# speed: the ground speed the clip is authored at (m/s); period: seconds per
# full cycle (two steps); duty: the share of the cycle each foot is down.
GAITS = {
    "walk": dict(speed=1.6, period=1.0, duty=0.60, lift=0.13, heel=D(16), toe=D(28),
                 drop=0.035, bob=0.022, sway=0.025, lean=D(4), twist=D(6), roll=D(4),
                 arm=D(20), arm_fwd=D(6), elbow=D(18), elbow_sw=D(10), lower=D(79),
                 narrow=0.06, kick=0.0, head_nod=D(1.5), curl=0.55),
    "run": dict(speed=4.6, period=0.72, duty=0.32, lift=0.34, heel=D(10), toe=D(34),
                drop=0.05, bob=0.03, sway=0.012, lean=D(8), twist=D(9), roll=D(3),
                arm=D(44), arm_fwd=D(4), elbow=D(80), elbow_sw=D(14), lower=D(76),
                narrow=0.09, kick=0.10, head_nod=D(2.0), curl=0.7),
    "sprint": dict(speed=9.0, period=0.62, duty=0.20, lift=0.52, heel=D(6), toe=D(38),
                   drop=0.075, bob=0.04, sway=0.008, lean=D(16), twist=D(11), roll=D(2),
                   arm=D(58), arm_fwd=D(8), elbow=D(88), elbow_sw=D(18), lower=D(74),
                   narrow=0.10, kick=0.18, head_nod=D(2.5), curl=0.85),
}

def leg_path(g, ph, side):
    """Ankle position and foot pitch for one leg at gait phase `ph`."""
    stride = g["speed"] * g["period"]              # ground covered per cycle
    stance = stride * g["duty"]                    # ... while this foot is down
    x = rest_ankle(side, g["narrow"])[0]
    z0 = P0["Hip"][2]
    on_z, off_z = z0 + stance * 0.5, z0 - stance * 0.5
    ph = ph % 1.0
    if ph < g["duty"]:
        s = ph / g["duty"]
        flat = lerp(on_z, off_z, s)                # moving back at ground speed
        # Heel strike → flat by a third of the stance, heel rising after 60 %.
        if s < 0.3:
            pitch = g["heel"] * (1 - smooth(s / 0.3))
        elif s > 0.6:
            pitch = -g["toe"] * 0.6 * smooth((s - 0.6) / 0.4)
        else:
            pitch = 0.0
        return foot_ankle(flat, pitch, x), pitch, True
    s = (ph - g["duty"]) / (1 - g["duty"])
    a_off = foot_ankle(off_z, -g["toe"] * 0.6, x)
    a_on = foot_ankle(on_z, g["heel"], x)
    # The foot lingers behind as it lifts (the heel kicks up in a run) and
    # then the knee drives it through: z lags on an eased curve, the height
    # peaks early.
    zs = smoother(s ** 1.25)
    z = lerp(a_off[2], a_on[2], zs) - g["kick"] * math.sin(math.pi * min(1.0, s * 1.6)) * (1 - s)
    y = lerp(a_off[1], a_on[1], s) + g["lift"] * math.sin(math.pi * (s ** 0.8)) ** 1.5
    pitch = lerp(-g["toe"], g["heel"], smooth((s - 0.25) / 0.7))
    return (x, y, z), pitch, False

def gait_pose(g, ph):
    p = Pose()
    c = math.cos(2 * math.pi * ph)
    for side in SIDES:
        sp = ph if side == "Left" else ph + 0.5
        p.ankle[side], p.foot_pitch[side], _ = leg_path(g, sp, side)
    # Pelvis: low at each contact in a walk (the legs are splayed), low at
    # mid-stance in a run (the landing loads the knee); bob at twice the
    # stride frequency, sway over the standing foot.
    mid = g["duty"] * 0.5
    if g["duty"] >= 0.5:
        bob = g["bob"] * math.cos(4 * math.pi * (ph - mid))
    else:
        bob = -g["bob"] * math.cos(4 * math.pi * (ph - mid))
    sway = g["sway"] * math.cos(2 * math.pi * (ph - mid))
    p.pelvis_off = (sway, -g["drop"] + bob, 0.0)
    # Pelvis turns with the forward leg and drops on the swinging side; the
    # chest counter-twists and leans into the run.
    p.pelvis = qmul(ry(-g["twist"] * c), rz(g["roll"] * math.cos(2 * math.pi * (ph - mid))))
    p.torso = qmul(ry(g["twist"] * 1.3 * c), rx(g["lean"] + D(1.5) * math.cos(4 * math.pi * (ph - mid))))
    # Head: holds the horizon — undo most of the lean and all of the twist.
    p.head = rx(D(4) + g["lean"] * 0.35 + g["head_nod"] * math.cos(4 * math.pi * (ph - mid - 0.08)))
    # Arms opposite the legs, a little behind them in time.
    for side, sg in SIDES.items():
        a = p.arm[side]
        sw = -sg * math.cos(2 * math.pi * (ph - 0.04))   # left arm back at left contact
        a["lower"] = g["lower"]
        a["swing"] = g["arm_fwd"] + g["arm"] * sw
        a["elbow"] = g["elbow"] + g["elbow_sw"] * max(0.0, sw)
        a["out"] = D(4)
        a["wrist"] = D(8)
        a["curl"] = g["curl"]
    return p

def pelvis_reach_fix(p):
    """Lower the pelvis just enough that every planted foot is reachable."""
    lo = 0.0
    for side in SIDES:
        a = p.ankle[side]
        if a is None: continue
        th = add(add(P0["Hip"], p.pelvis_off), qrot(p.pelvis, sub(P0["Thigh." + side], P0["Hip"])))
        v = sub(a, th); reach = (LEN_THIGH + LEN_SHIN) * 0.995
        horiz = math.hypot(v[0], v[2])
        if horiz < reach and length(v) > reach:
            # Dropping the pelvis by d raises v.y by d; stop where |v| = reach.
            lo = min(lo, v[1] + math.sqrt(reach * reach - horiz * horiz))
    o = p.pelvis_off
    p.pelvis_off = (o[0], o[1] + lo, o[2])
    return p

# ── the other clips ─────────────────────────────────────────────────────────
def stand_pose(t=0.0, period=4.0):
    """Idle: breathing twice a cycle, weight rolling from foot to foot."""
    p = Pose()
    w = math.sin(2 * math.pi * t / period)              # weight shift
    br = math.sin(4 * math.pi * t / period)             # breath
    for side in SIDES:
        p.ankle[side] = rest_ankle(side, 0.055)
    p.pelvis_off = (0.022 * w, -0.018 - 0.006 * abs(w), 0.0)
    p.pelvis = rz(D(2.2) * w)
    p.torso = qmul(rz(-D(1.6) * w), rx(D(1.5) + D(1.0) * br))
    p.head = qmul(ry(D(5) * math.sin(2 * math.pi * t / period + 1.1)), rx(D(5) - D(1.0) * br))
    for side, sg in SIDES.items():
        a = p.arm[side]
        a["lower"] = D(79) - D(1.2) * br
        a["out"] = D(3) + D(1.0) * br
        a["swing"] = D(3) + D(1.5) * sg * w
        a["elbow"] = D(14) + D(2) * br
        a["wrist"] = D(8)
    return p

def air_pose(tuck, spread, flail=0.0):
    """Hanging legs and raised arms — the airborne family (jump, fall)."""
    p = Pose()
    p.pelvis_off = (0.0, 0.0, 0.0)
    p.torso = rx(D(4) - D(4) * spread)
    p.head = rx(D(4))
    for side, sg in SIDES.items():
        off = flail * sg
        p.hip[side] = D(22) * tuck + D(10) * off
        p.knee[side] = D(40) * tuck + D(12) * (1 + off)
        p.foot_pitch[side] = -D(18) + D(10) * tuck
        a = p.arm[side]
        a["lower"] = lerp(D(74), D(30), spread) + D(6) * off
        a["swing"] = D(4) + D(6) * spread - D(8) * off
        a["out"] = D(6)
        a["elbow"] = D(26) + D(10) * spread
        a["wrist"] = D(10)
    return p

def crouch_pose(depth, lean, arms_fwd):
    p = stand_pose(0.0)
    o = p.pelvis_off
    p.pelvis_off = (o[0], o[1] - depth, o[2] - depth * 0.35)
    p.torso = rx(lean)
    p.head = rx(-lean * 0.5)
    for side in SIDES:
        a = p.arm[side]
        a["swing"] = arms_fwd
        a["elbow"] = D(28)
    return p

# ── writing RON ─────────────────────────────────────────────────────────────
def fmt(v): return "(" + ", ".join("%.6f" % c for c in v) + ")"

def write_clip(name, keys, looped, mode="Smooth", events=None):
    """keys: [(t, {bone: (t, q)})]. Quaternions are kept in one hemisphere so
    the interpolation takes the short way between neighbours."""
    duration = keys[-1][0]
    bones = sorted(keys[0][1].keys())
    lines = ["(", '    name: "%s",' % name, "    duration: %.6f," % duration,
             '    source_model: "%s",' % MODEL, "    channels: ["]
    for b in bones:
        ts = [k[0] for k in keys]
        tr = [k[1][b][0] for k in keys]
        qs = []
        for k in keys:
            q = k[1][b][1]
            if qs and dot(q[:3], qs[-1][:3]) + q[3] * qs[-1][3] < 0: q = tuple(-c for c in q)
            qs.append(q)
        def lane(label, vals):
            out = ["            %s: Some((" % label,
                   "                times: [" + ", ".join("%.6f" % t for t in ts) + "],",
                   "                values: [" + ", ".join(fmt(v) for v in vals) + "],",
                   "                step: false,"]
            if mode != "Linear":
                out.append("                modes: [" + ", ".join("(t: %.6f, mode: %s)" % (t, mode) for t in ts) + "],")
            out.append("            )),")
            return out
        lines += ["        (", '            node: "%s",' % b]
        if max(length(sub(v, tr[0])) for v in tr) > 1e-6 or b in ("Back", "MaleArm"):
            lines += lane("translation", tr)
        lines += lane("rotation", qs)
        lines += ["        ),"]
    lines += ["    ],"]
    ev = events or []
    lines += ["    events: [" + ", ".join('(t: %.6f, func: "%s")' % e for e in ev) + "],", ")", ""]
    open(os.path.join(ROOT, OUT, name + ".anim.ron"), "w").write("\n".join(lines))

def cycle(name, pose_at, period, n, fix=True):
    keys = []
    for i in range(n + 1):
        ph = (i % n) / n
        p = pose_at(ph)
        if fix: pelvis_reach_fix(p)
        keys.append((period * i / n, solve(p)))
    write_clip(name, keys, True)

def blend(a, b, t):
    """Blend two poses (component-wise; rotations by normalized lerp)."""
    def ql(x, y):
        if dot(x[:3], y[:3]) + x[3] * y[3] < 0: y = tuple(-c for c in y)
        return qnorm(tuple(lerp(x[i], y[i], t) for i in range(4)))
    def vl(x, y): return tuple(lerp(x[i], y[i], t) for i in range(3))
    p = Pose()
    p.pelvis_off = vl(a.pelvis_off, b.pelvis_off)
    p.pelvis, p.torso, p.head = ql(a.pelvis, b.pelvis), ql(a.torso, b.torso), ql(a.head, b.head)
    for s in SIDES:
        p.arm[s] = {k: lerp(a.arm[s][k], b.arm[s][k], t) for k in a.arm[s]}
        p.foot_pitch[s] = lerp(a.foot_pitch[s], b.foot_pitch[s], t)
        p.hip[s], p.knee[s] = lerp(a.hip[s], b.hip[s], t), lerp(a.knee[s], b.knee[s], t)
        if a.ankle[s] is not None and b.ankle[s] is not None:
            p.ankle[s] = vl(a.ankle[s], b.ankle[s])
        else:
            p.ankle[s] = None
    return p

def hanging(p):
    """An IK pose's legs expressed as hip/knee angles, so it can blend with
    an airborne pose (whose legs hang from angles, not targets)."""
    q = Pose(); q.__dict__.update({k: (dict(v) if isinstance(v, dict) else v) for k, v in p.__dict__.items()})
    for side in SIDES:
        a = p.ankle[side]
        if a is None: continue
        th = add(add(P0["Hip"], p.pelvis_off), qrot(p.pelvis, sub(P0["Thigh." + side], P0["Hip"])))
        v = sub(a, th); d = min(length(v), LEN_THIGH + LEN_SHIN - 1e-4)
        knee = math.pi - math.acos(max(-1, min(1, (LEN_THIGH ** 2 + LEN_SHIN ** 2 - d * d) / (2 * LEN_THIGH * LEN_SHIN))))
        # Hip flex: the thigh leads the ankle line by the triangle's angle.
        line = math.atan2(v[2], -v[1])
        inner = math.acos(max(-1, min(1, (LEN_THIGH ** 2 + d * d - LEN_SHIN ** 2) / (2 * LEN_THIGH * d))))
        q.hip[side] = line + inner
        q.knee[side] = knee
        q.ankle[side] = None
    return q

def main():
    os.makedirs(os.path.join(ROOT, OUT), exist_ok=True)
    for name, g in GAITS.items():
        cycle(name, lambda ph, g=g: gait_pose(g, ph), g["period"], 24)
    cycle("idle", lambda ph: stand_pose(ph * 4.0), 4.0, 16)

    # Jump: the push-off (legs long, toes pointed, arms thrown up) folding
    # into a tuck; it hands over to `fall`, whose first key it ends on.
    push = air_pose(0.0, 0.55); push.torso = rx(D(8))
    for s in SIDES:
        push.foot_pitch[s] = -D(35)
        push.arm[s].update(swing=D(32), lower=D(78), elbow=D(28), curl=0.6)
    fall0 = air_pose(0.55, 0.45, 0.0)
    keys = [(0.0, solve(hanging(crouch_pose(0.10, D(14), -D(20))))), (0.10, solve(push)),
            (0.34, solve(blend(push, fall0, 0.7))), (0.5, solve(fall0))]
    write_clip("jump", keys, False)

    # Fall: a slow, loose pedal of the legs and arms held out for balance.
    keys = []
    for i in range(9):
        ph = (i % 8) / 8
        keys.append((1.6 * i / 8, solve(air_pose(0.55 + 0.08 * math.sin(2 * math.pi * ph), 0.45,
                                                 0.6 * math.sin(2 * math.pi * ph)))))
    write_clip("fall", keys, True)

    # Land: reach for the ground, absorb (knees, lean, arms forward), stand.
    reach = hanging(stand_pose(0.0)); reach = blend(reach, air_pose(0.25, 0.4), 0.5)
    absorb = crouch_pose(0.16, D(20), D(18))
    settle = crouch_pose(0.035, D(6), D(6))
    keys = [(0.0, solve(reach)), (0.09, solve(pelvis_reach_fix(absorb))),
            (0.30, solve(pelvis_reach_fix(settle))), (0.55, solve(pelvis_reach_fix(stand_pose(0.0))))]
    # The first key is airborne; key the others' legs by IK from the ground.
    write_clip("land", keys, False)

    write_controller()

def write_controller():
    def state(name, speed, looped, fade=None, blend=None):
        s = ["                (", '                    name: "%s",' % name,
             '                    clip: "%s/%s",' % (OUT, name),
             "                    speed: %.1f," % speed,
             "                    looped: %s," % ("true" if looped else "false")]
        if fade is not None: s.append("                    fade_in: Some(%.2f)," % fade)
        if blend is not None:
            param, points = blend
            s += ['                    blend: Some((params: ["%s"], points: [' % param]
            s += ['                        (clip: "%s/%s", at: (%.1f, 0.0)),' % (OUT, c, x) for c, x in points]
            s += ["                    ])),"]
        s += ["                    pos: (300.0, 300.0),", "                ),"]
        return s
    def layer(name, weight, states, default, transitions=()):
        l = ["        (", '            name: "%s",' % name, "            weight: %.1f," % weight,
             "            states: ["]
        for st in states: l += state(*st)
        l += ["            ],", '            default_state: Some("%s"),' % default, "            transitions: ["]
        for a, b, f in transitions:
            l += ["                (", '                    from: "%s",' % a, '                    to: "%s",' % b,
                  "                    fade: %.2f," % f, "                ),"]
        l += ["            ],", "        ),"]
        return l
    lines = ["// Generated by tools/gen_astronaut_anims.py — edit the generator, not this.",
             "(", "    default_fade: 0.18,", "    layers: ["]
    lines += layer("Base", 1.0, [("idle", 1.0, True), ("jump", 1.0, False, 0.06),
                                 ("fall", 1.0, True), ("land", 1.0, False, 0.05)], "idle",
                   [("jump", "fall", 0.25), ("fall", "land", 0.05), ("land", "idle", 0.2)])
    # The gaits: one state that never advances on its own. The walker scrubs it
    # to one shared phase and slides `gait` from walk (0) through run (1) to
    # sprint (2) by ground speed; the run clip is the state's clock.
    lines += layer("Gait", 0.0, [("run", 0.0, True, None,
                                  ("gait", [("walk", 0.0), ("run", 1.0), ("sprint", 2.0)]))], "run")
    lines += ["    ],", ")", ""]
    open(os.path.join(ROOT, "animation_controllers/character.actl.ron"), "w").write("\n".join(lines))

if __name__ == "__main__":
    main()
    for name, g in GAITS.items():
        print("%-7s stride %.2f m per cycle, %.2f s, authored at %.1f m/s" % (name, g["speed"] * g["period"], g["period"], g["speed"]))
