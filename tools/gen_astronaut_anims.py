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
  Swim      back-scull / tread / stroke by `swimF` (-1, 0, +1): a crawl at
          the surface (swim_surface), a breaststroke under it (swim_under)
  SwimSide  side stroke right / left by `swimS` (-1, +1)
  SwimVert  dive / haul up by `swimV` (-1, +1)
          The swim layers play free; the walker sets their weights from how
          the body really moves and their speed from SWIMS' metres a cycle.
          The clips are authored upright; the walker tips the whole rig.
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
        # Hanging legs can also open sideways (`leg_out`, abduction) and turn
        # out about their own length (`leg_yaw`); `foot_rel`, when set, points
        # the foot relative to the SHIN (a swimmer's pointed toes) instead of
        # keeping it level in the character's frame.
        self.leg_out = {s: 0.0 for s in SIDES}
        self.leg_yaw = {s: 0.0 for s in SIDES}
        self.foot_rel = {s: None for s in SIDES}
        # Arms by IK instead of angles (the swims: a stroke is a path the HAND
        # draws). `hand` is the wrist's target from the shoulder, in the torso's
        # frame; `pole` the way the elbow points; `palm` the way the palm faces.
        # All three in the torso's frame, so a body roll carries the stroke.
        self.hand = {s: None for s in SIDES}
        self.pole = {s: None for s in SIDES}
        self.palm = {s: None for s in SIDES}

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
        if pose.hand[side] is not None:
            arm_ik(pose, side, sg, P["Back"], T, W)
        else:
            arm_angles(pose, side, sg, a, T, W)
        # Legs.
        leg(pose, side, sg, hip, W)
    return to_local(W, P)

def arm_angles(pose, side, sg, a, T, W):
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

LEN_UPPER = length(sub(P0["Forearm.Left"], P0["Upperarm.Left"]))
LEN_FORE = length(sub(P0["Hand.Left"], P0["Forearm.Left"]))

def perp(v, axis):
    """v with its component along the unit `axis` taken out, normalised."""
    return unit(sub(v, mul(axis, dot(v, axis))))

def frame_rot(a0, b0, a1, b1):
    """The rotation taking the orthonormal pair (a0, b0) onto (a1, b1)."""
    c0, c1 = cross(a0, b0), cross(a1, b1)
    m = [[a1[i] * a0[j] + b1[i] * b0[j] + c1[i] * c0[j] for j in range(3)] for i in range(3)]
    tr = m[0][0] + m[1][1] + m[2][2]
    if tr > 0:
        k = math.sqrt(tr + 1.0) * 2
        q = ((m[2][1] - m[1][2]) / k, (m[0][2] - m[2][0]) / k, (m[1][0] - m[0][1]) / k, 0.25 * k)
    elif m[0][0] > m[1][1] and m[0][0] > m[2][2]:
        k = math.sqrt(1.0 + m[0][0] - m[1][1] - m[2][2]) * 2
        q = (0.25 * k, (m[0][1] + m[1][0]) / k, (m[0][2] + m[2][0]) / k, (m[2][1] - m[1][2]) / k)
    elif m[1][1] > m[2][2]:
        k = math.sqrt(1.0 + m[1][1] - m[0][0] - m[2][2]) * 2
        q = ((m[0][1] + m[1][0]) / k, 0.25 * k, (m[1][2] + m[2][1]) / k, (m[0][2] - m[2][0]) / k)
    else:
        k = math.sqrt(1.0 + m[2][2] - m[0][0] - m[1][1]) * 2
        q = ((m[0][2] + m[2][0]) / k, (m[1][2] + m[2][1]) / k, 0.25 * k, (m[1][0] - m[0][1]) / k)
    return qnorm(q)

def arm_ik(pose, side, sg, back, T, W):
    """An arm placed by where its hand goes: two-bone IK from the shoulder to
    the wrist target, the elbow toward its pole, then the forearm and hand
    rolled about the forearm so the palm faces where it is told to. A stroke
    is a path drawn by the hand, and this is how one is drawn without the
    angle chain's 180° flip of the upper arm at the top of a crawl."""
    a = pose.arm[side]
    sh = add(back, qrot(T, sub(P0["Upperarm." + side], P0["Back"])))
    tgt = add(sh, qrot(T, pose.hand[side]))
    hint = qrot(T, pose.pole[side] or (sg * 1.0, 0.0, -0.4))
    v = sub(tgt, sh); d = max(0.08, min(length(v), LEN_UPPER + LEN_FORE - 1e-4))
    vn = unit(v)
    a1 = (LEN_UPPER ** 2 - LEN_FORE ** 2 + d * d) / (2 * d)
    h = math.sqrt(max(0.0, LEN_UPPER ** 2 - a1 * a1))
    pk = perp(hint, vn)
    elbow = add(add(sh, mul(vn, a1)), mul(pk, h))
    wrist = add(sh, mul(vn, d))
    # Rest: the upper arm along a0, bending (as the angle chain bends it)
    # toward the character's front, b0. The hinge's axis is kept through the
    # bend, so the forearm's frame is its direction plus that axis.
    a0 = unit(sub(P0["Forearm." + side], P0["Upperarm." + side]))
    b0 = perp((0.0, 0.0, 1.0), a0)
    f0 = unit(sub(P0["Hand." + side], P0["Forearm." + side]))
    au = unit(sub(elbow, sh))
    fu = unit(sub(wrist, elbow))
    bu = sub(fu, mul(au, dot(fu, au)))
    bu = unit(bu) if length(bu) > 1e-4 else perp(mul(pk, -1.0), au)
    up = frame_rot(a0, b0, au, bu)
    n0 = cross(a0, b0)
    n1 = cross(au, bu)
    fore = frame_rot(f0, perp(n0, f0), fu, perp(n1, fu))
    # Palm: in the T-pose it faces down (−Y). Roll it about the forearm toward
    # the asked-for facing — half in the forearm, all of it at the hand, so the
    # wrist doesn't wring.
    roll = 0.0
    if pose.palm[side] is not None:
        want = perp(qrot(T, pose.palm[side]), fu)
        have = perp(qrot(fore, (0.0, -1.0, 0.0)), fu)
        roll = math.atan2(dot(cross(have, want), fu), dot(have, want))
    W["Upperarm." + side] = qmul(up, W0["Upperarm." + side])
    W["Forearm." + side] = qmul(qmul(qaxis(fu, roll * 0.5), fore), W0["Forearm." + side])
    hand = qmul(qaxis(fu, roll), qmul(fore, rz(-sg * a["wrist"])))
    W["Hand." + side] = qmul(hand, W0["Hand." + side])
    W["Fingers1." + side] = qmul(qmul(hand, rz(-sg * a["curl"] * D(50))), W0["Fingers1." + side])
    W["Fingers2." + side] = qmul(qmul(hand, rz(-sg * a["curl"] * D(115))), W0["Fingers2." + side])

def leg(pose, side, sg, hip, W):
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
        # Flex forward, open sideways, then turn out: the order a hip
        # takes them in, so an open, bent leg (eggbeater, frog kick) opens
        # the knee to the side rather than spinning the thigh.
        qd = qmul(pose.pelvis, qmul(ry(sg * pose.leg_yaw[side]),
                                    qmul(rz(sg * pose.leg_out[side]), rx(-pose.hip[side]))))
        knee = add(th, mul(unit(qrot(qd, sub(P0["Shin." + side], P0["Thigh." + side]))), LEN_THIGH))
        kd = qmul(qd, rx(pose.knee[side]))
        ankle = add(knee, mul(unit(qrot(kd, sub(P0["Foot." + side], P0["Shin." + side]))), LEN_SHIN))
    dq = qmul(arc(rest_th, sub(knee, th)), pose.pelvis)
    W["Thigh." + side] = qmul(dq, W0["Thigh." + side])
    rest_sh = qrot(dq, sub(P0["Foot." + side], P0["Shin." + side]))
    sq = qmul(arc(rest_sh, sub(ankle, knee)), dq)
    W["Shin." + side] = qmul(sq, W0["Shin." + side])
    # The foot keeps to the character frame (flat on the ground unless
    # pitched), turned only with the pelvis — or, for a swimmer, rides the
    # shin with the toes pointed.
    if pose.foot_rel[side] is not None:
        W["Foot." + side] = qmul(qmul(sq, rx(-pose.foot_rel[side])), W0["Foot." + side])
    else:
        W["Foot." + side] = qmul(qmul(pose.pelvis, rx(-pose.foot_pitch[side])), W0["Foot." + side])

def to_local(W, P):
    """World rotations (and Back's position) → the bones' local TRS."""
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

# ── swimming ────────────────────────────────────────────────────────────────
# Every swim is authored UPRIGHT, in the same frame as the walk: +Y is the way
# the head points, +Z the way the chest faces. The walker tips the whole rig
# at run time (MaleArm, the root no clip keys) — level for a crawl, head-down
# for a dive, upright to tread — so one clip serves every attitude and two
# clips blend without the body swinging through each other. In the crawl's
# frame that means: "overhead" (+Y) is the way you swim, and "in front" (+Z)
# is the sea floor under a swimmer lying face down.
#
# A stroke is the path the HAND draws (`arm_ik`), keyed at a few phases and
# run through a closed Catmull-Rom spline, so it has no corners. The legs hang
# from angles. Everything is keyed against the cycle's phase, and limbs are
# offset in phase from each other (overlapping action): the hips roll after
# the chest, the head after the hips, the knee whips after the thigh.
#
# STROKE (metres a full cycle covers) is what the walker reads to scale each
# layer's playback rate to the speed you are really moving — the swim's
# equivalent of the gaits' stride, so a hand that is pulling holds the water
# instead of sliding through it.
SWIMS = {
    # name: (seconds per cycle, metres a cycle covers — 0 for a hold)
    "tread": (2.4, 0.0), "hover": (3.0, 0.0),
    "crawl": (1.4, 3.0), "breast": (1.8, 2.6), "back_scull": (2.0, 2.0),
    "side_left": (1.8, 2.4), "side_right": (1.8, 2.4),
    "ascend": (1.6, 2.2), "descend": (1.6, 2.4),
}

def cr(p0, p1, p2, p3, u):
    u2, u3 = u * u, u * u * u
    return tuple(0.5 * (2 * b + (c - a) * u + (2 * a - 5 * b + 4 * c - d) * u2 + (3 * b - a - 3 * c + d) * u3)
                 for a, b, c, d in zip(p0, p1, p2, p3))

def loop(keys, ph):
    """A closed Catmull-Rom spline through [(phase, value-tuple)], phases in
    [0, 1) ascending: no corner anywhere, the end flowing into the start."""
    n = len(keys); ph %= 1.0
    i = n - 1
    for j in range(n):
        if keys[j][0] <= ph: i = j
    t0 = keys[i][0]
    t1 = keys[(i + 1) % n][0] + (1.0 if i + 1 >= n else 0.0)
    if ph < t0: ph += 1.0
    u = (ph - t0) / max(1e-6, t1 - t0)
    return cr(keys[(i - 1) % n][1], keys[i][1], keys[(i + 1) % n][1], keys[(i + 2) % n][1], u)

def mirror_x(v, sg): return (v[0] * sg, v[1], v[2])

def bump(ph, a, b, edge=0.08):
    """1 between phases a and b, eased in and out over `edge`, 0 elsewhere."""
    ph %= 1.0
    return smooth((ph - a + edge) / edge) * (1 - smooth((ph - b) / edge))

def stroke(p, side, sg, ph, hand, pole, palm, wrist=D(8), curl=0.2):
    """Key one arm from spline tables written for the LEFT arm (+X); the right
    is its mirror."""
    p.hand[side] = mirror_x(loop(hand, ph), sg)
    p.pole[side] = mirror_x(loop(pole, ph), sg)
    p.palm[side] = mirror_x(loop(palm, ph), sg)
    p.arm[side]["wrist"], p.arm[side]["curl"] = wrist, curl

def hang(p, side, hip, knee, out=0.0, yaw=0.0, foot=-D(60)):
    p.hip[side], p.knee[side] = hip, knee
    p.leg_out[side], p.leg_yaw[side], p.foot_rel[side] = out, yaw, foot
    p.ankle[side] = None

def tread_pose(ph, under=False):
    """Treading water: sculling hands drawing a flat figure-eight in front of
    the chest, palms tilted into each sweep; an eggbeater kick, the legs
    circling half a cycle apart, so the body bobs twice a cycle. Underwater
    (`hover`) it is wider and lower and the legs paddle slowly."""
    p = Pose()
    w = 2 * math.pi * ph
    bob = math.cos(2 * w)
    p.pelvis_off = (0.008 * math.sin(w), 0.016 * bob, 0.0)
    lean = D(14) if under else D(9)
    p.torso = qmul(ry(D(4) * math.sin(w + 0.7)), rx(lean + D(1.5) * math.cos(2 * w - 0.6)))
    p.pelvis = qmul(ry(-D(3) * math.sin(w + 0.3)), rx(D(4) if under else 0.0))
    # The head holds level (the torso leans forward under it), glances about,
    # and nods with the bob a beat after it.
    p.head = qmul(ry(D(9) * math.sin(w + 1.3)), rx((D(6) if under else -D(2)) + D(1.5) * math.cos(2 * w - 1.2)))
    for side, sg in SIDES.items():
        a = w + (0.18 if side == "Right" else 0.0)       # the right a beat behind
        sweep = math.sin(a)
        if under:
            hand = (sg * (0.34 + 0.15 * sweep), -0.30 + 0.025 * math.cos(2 * a), 0.20 + 0.05 * math.cos(a))
        else:
            hand = (sg * (0.28 + 0.13 * sweep), -0.24 + 0.03 * math.cos(2 * a), 0.27 + 0.05 * math.cos(a))
        p.hand[side] = hand
        p.pole[side] = (sg * 1.0, -0.25, -0.55)
        # The palm faces down, tipped toward where the hand is going (its
        # leading edge up) — the pitch that makes a scull lift.
        p.palm[side] = (sg * 0.65 * math.cos(a), -1.0, 0.15)
        p.arm[side]["wrist"], p.arm[side]["curl"] = D(4), 0.15
        l = w + (math.pi if side == "Right" else 0.0)
        if under:
            hang(p, side, D(22) + D(10) * math.sin(l), D(32) + D(24) * (0.5 + 0.5 * math.sin(l + 1.3)),
                 D(8) + D(3) * math.cos(l), D(4), -D(48) + D(10) * math.sin(l + 0.8))
        else:
            hang(p, side, D(52) + D(9) * math.sin(l), D(78) + D(26) * math.sin(l + 1.2),
                 D(24) + D(7) * math.cos(l), -D(16), D(2) + D(12) * math.sin(l + 0.6))
    return p

# The crawl's left hand, from the shoulder in the torso's frame (the right is
# its mirror, half a cycle later): enter in front of the head, reach, catch
# with the elbow high, pull under the chest, push past the hip, slice out by
# the thigh, then swing forward ABOVE the back (−Z) with the elbow leading.
CRAWL_HAND = [(0.00, (0.11, 0.44, 0.08)), (0.10, (0.08, 0.53, 0.10)), (0.22, (0.13, 0.41, 0.27)),
              (0.36, (0.03, 0.09, 0.33)), (0.50, (0.10, -0.31, 0.21)), (0.60, (0.16, -0.46, 0.02)),
              (0.70, (0.34, -0.22, -0.10)), (0.82, (0.35, 0.12, -0.12)), (0.92, (0.22, 0.38, -0.02))]
CRAWL_POLE = [(0.00, (0.7, 0.0, -0.7)), (0.22, (1.0, 0.1, -0.3)), (0.40, (1.0, -0.2, -0.2)),
              (0.56, (0.7, -0.3, -0.6)), (0.70, (1.0, 0.0, -0.8)), (0.86, (0.8, 0.2, -0.8))]
CRAWL_PALM = [(0.00, (0.5, 0.2, 1.0)), (0.22, (0.1, -0.6, 1.0)), (0.36, (0.0, -1.0, 0.4)),
              (0.50, (0.2, -1.0, 0.0)), (0.62, (-1.0, -0.2, 0.0)), (0.75, (-0.6, 0.2, -0.6)),
              (0.88, (0.2, 0.0, 1.0))]

def crawl_pose(ph):
    """Front crawl. A six-beat flutter kick, the body rolling ~40° onto the
    pulling arm's side with the hips following, and a breath to the right
    every cycle: the head turns out with the roll as the right arm recovers
    and is back down before that hand enters."""
    p = Pose()
    roll = -D(38) * math.sin(2 * math.pi * (ph - 0.11))         # − : left shoulder down
    hroll = -D(26) * math.sin(2 * math.pi * (ph - 0.15))
    p.torso = qmul(ry(roll), rx(-D(3)))
    p.pelvis = ry(hroll)
    breath = bump(ph, 0.24, 0.44, 0.1)
    p.head = qmul(ry(lerp(roll * 0.55, roll - D(42), breath)), rx(lerp(-D(16), -D(4), breath)))
    for side, sg in SIDES.items():
        sp = ph + (0.0 if side == "Left" else 0.5)
        under = bump(sp, 0.0, 0.6, 0.06)
        stroke(p, side, sg, sp, CRAWL_HAND, CRAWL_POLE, CRAWL_PALM,
               wrist=D(10) * under + D(18) * (1 - under), curl=0.12 * under + 0.4 * (1 - under))
        th = 6 * 2 * math.pi * ph + (math.pi if side == "Right" else 0.0)
        # Hip drives the kick; the knee bends at the top of the upkick and
        # whips straight through the downkick; the ankle trails, floppy.
        hang(p, side, D(3) + D(10) * math.sin(th),
             D(5) + D(24) * (0.5 + 0.5 * math.cos(th + math.pi / 2)) ** 2,
             -D(2), -D(5), -D(62) + D(9) * math.sin(th - 0.9))
    return p

# Breaststroke, underwater: pull — breathe — kick — glide. Hands sweep out
# into a wide catch, scull in under the chin, and shoot forward together; the
# heels draw up as the hands come in, the kick fires as they reach, and then
# nothing moves for the glide.
BREAST_HAND = [(0.00, (0.05, 0.53, 0.06)), (0.06, (0.16, 0.51, 0.08)), (0.16, (0.36, 0.34, 0.16)),
               (0.25, (0.22, 0.04, 0.27)), (0.31, (0.07, -0.06, 0.24)), (0.39, (0.05, 0.28, 0.16)),
               (0.47, (0.05, 0.53, 0.06)), (0.75, (0.05, 0.535, 0.05))]
BREAST_POLE = [(0.00, (0.7, 0.0, -0.7)), (0.16, (1.0, 0.1, -0.4)), (0.27, (0.8, -0.5, 0.2)),
               (0.35, (0.5, -0.6, 0.3)), (0.47, (0.7, 0.0, -0.7))]
BREAST_PALM = [(0.00, (0.0, 0.0, 1.0)), (0.10, (0.8, -0.2, 0.5)), (0.20, (0.4, -0.8, 0.4)),
               (0.27, (-0.6, -0.8, 0.2)), (0.33, (-0.5, 0.0, 1.0)), (0.40, (0.0, 0.2, 1.0)),
               (0.47, (0.0, 0.0, 1.0))]
# Frog kick: (hip flex, knee, out, yaw, foot) — heels to the seat with the
# feet hooked and turned out, a whip out, back and together, toes pointed.
FROG = [(0.00, (0, 3, 2, 0, -70)), (0.28, (0, 3, 2, 0, -70)), (0.36, (22, 70, 10, -8, -40)),
        (0.44, (38, 112, 14, -20, 12)), (0.50, (24, 62, 26, -14, 0)), (0.56, (5, 14, 16, -4, -50)),
        (0.64, (0, 2, 2, 0, -72))]

def frog(p, ph):
    for side in SIDES:
        h, k, o, y, f = (D(c) for c in loop(FROG, ph))
        hang(p, side, h, k, o, y, f)

def breast_pose(ph):
    p = Pose()
    lift = bump(ph, 0.14, 0.34, 0.1)                 # the chest rises on the in-sweep
    kick = bump(ph, 0.38, 0.52, 0.06)
    p.torso = rx(-D(9) * lift + D(3) * kick)
    p.pelvis = rx(D(7) * bump(ph, 0.34, 0.48, 0.06))
    p.pelvis_off = (0.0, 0.0, -0.02 * kick)
    p.head = rx(lerp(-D(6), -D(20), lift) + D(4) * kick)
    for side, sg in SIDES.items():
        under = 1 - bump(ph, 0.3, 0.42, 0.05)
        stroke(p, side, sg, ph, BREAST_HAND, BREAST_POLE, BREAST_PALM, wrist=D(6), curl=0.12 + 0.1 * (1 - under))
    frog(p, ph)
    return p

# Swimming backwards, facing forward: an upright back-scull. The hands press
# forward from the chest, palms leading, open out and slice back in; the legs
# flutter gently from a seated hip.
BACK_HAND = [(0.00, (0.14, -0.20, 0.12)), (0.30, (0.22, -0.27, 0.45)), (0.48, (0.42, -0.24, 0.32)),
             (0.70, (0.34, -0.22, 0.10)), (0.88, (0.20, -0.18, 0.07))]
BACK_POLE = [(0.00, (1.0, -0.3, -0.6)), (0.30, (1.0, -0.4, -0.1)), (0.60, (1.0, -0.1, -0.6))]
BACK_PALM = [(0.00, (0.0, -0.3, 1.0)), (0.30, (0.2, -0.3, 1.0)), (0.48, (1.0, -0.4, 0.2)),
             (0.70, (0.6, -1.0, -0.2)), (0.88, (0.0, -0.6, 0.8))]

def back_pose(ph):
    p = Pose()
    w = 2 * math.pi * ph
    push = bump(ph, 0.05, 0.4, 0.1)
    p.torso = rx(-D(5) + D(5) * push)
    p.head = rx(D(8) - D(3) * push)
    p.pelvis_off = (0.0, 0.012 * math.cos(2 * w), 0.0)
    for side, sg in SIDES.items():
        stroke(p, side, sg, ph + (0.03 if side == "Right" else 0.0), BACK_HAND, BACK_POLE, BACK_PALM,
               wrist=D(-12) * push + D(6), curl=0.12)
        l = 2 * w + (math.pi if side == "Right" else 0.0)
        hang(p, side, D(26) + D(10) * math.sin(l), D(34) + D(18) * (0.5 + 0.5 * math.cos(l + 1.4)),
             D(5), -D(4), -D(42) + D(8) * math.sin(l - 0.8))
    return p

# Sideways (toward the character's LEFT; side_right is its mirror): the
# leading hand reaches out and hauls down to the hip, the trailing hand pushes
# from the chest out the other way, and the legs scissor open sideways during
# the reach and snap shut for the glide. The body leans into the way it goes.
SIDE_LEAD = [(0.00, (0.50, 0.08, 0.06)), (0.30, (0.36, -0.30, 0.10)), (0.48, (0.18, -0.40, 0.12)),
             (0.66, (0.16, -0.08, 0.20)), (0.84, (0.34, 0.08, 0.14))]
SIDE_LEAD_PALM = [(0.00, (-0.6, -0.5, 0.3)), (0.30, (-1.0, -0.3, 0.0)), (0.48, (-0.6, 0.2, 0.4)),
                  (0.66, (0.0, -0.4, 1.0)), (0.84, (0.2, -0.8, 0.5))]
SIDE_TRAIL = [(0.00, (0.12, -0.05, 0.22)), (0.35, (0.46, -0.30, 0.06)), (0.50, (0.30, -0.42, 0.02)),
              (0.75, (0.14, -0.20, 0.18))]
SIDE_TRAIL_PALM = [(0.00, (1.0, -0.2, 0.3)), (0.35, (1.0, -0.4, 0.0)), (0.50, (0.3, -0.5, 0.6)),
                   (0.75, (0.0, -0.5, 1.0))]
SIDE_POLE = [(0.00, (1.0, -0.2, -0.5)), (0.50, (1.0, -0.5, -0.3))]

def side_pose(ph, dsg):
    p = Pose()
    open_ = smooth((ph - 0.45) / 0.35) * (1 - smooth((ph - 0.86) / 0.12))
    p.torso = qmul(rz(-dsg * D(9)), qmul(ry(dsg * D(5) * math.sin(2 * math.pi * ph)), rx(D(6))))
    p.pelvis = rz(dsg * D(4) * (1 - open_))
    p.pelvis_off = (0.0, 0.01 * math.cos(4 * math.pi * ph), 0.0)
    p.head = qmul(ry(dsg * D(24)), rx(D(2)))
    for side, sg in SIDES.items():
        lead = (sg == dsg)
        stroke(p, side, sg, ph, SIDE_LEAD if lead else SIDE_TRAIL, SIDE_POLE,
               SIDE_LEAD_PALM if lead else SIDE_TRAIL_PALM, wrist=D(6), curl=0.14)
        # Never standing: the hips stay soft and the knees bent, and the legs
        # drift a little between kicks.
        drift = D(4) * math.sin(2 * math.pi * ph * 2 + (0.0 if lead else math.pi))
        if lead:
            hang(p, side, D(16) + D(10) * open_ + drift, D(24) + D(38) * open_, D(28) * open_ + D(3), D(8) * open_,
                 -D(50) + D(25) * open_)
        else:
            hang(p, side, D(12) - D(16) * open_ - drift, D(22) + D(24) * open_, -D(4) * open_ + D(2), 0.0, -D(55))
    return p

# Going UP: both hands reach overhead and haul down to the hips (palms
# pressing the water down), recover close along the front, while a frog kick
# drives on the reach. The head looks up to the light.
UP_HAND = [(0.00, (0.16, 0.52, 0.04)), (0.14, (0.40, 0.30, 0.08)), (0.32, (0.36, -0.20, 0.06)),
           (0.42, (0.20, -0.46, 0.04)), (0.60, (0.12, -0.12, 0.20)), (0.80, (0.10, 0.30, 0.16))]
UP_POLE = [(0.00, (1.0, 0.0, -0.5)), (0.40, (1.0, -0.2, -0.3)), (0.60, (0.7, -0.5, 0.4)), (0.85, (0.8, 0.0, -0.2))]
UP_PALM = [(0.00, (0.3, -0.6, 0.6)), (0.14, (0.4, -1.0, 0.0)), (0.32, (0.2, -1.0, 0.0)),
           (0.45, (-0.8, -0.2, 0.0)), (0.60, (-1.0, 0.0, 0.4)), (0.80, (-0.4, 0.4, 0.8))]

def ascend_pose(ph):
    p = Pose()
    haul = bump(ph, 0.1, 0.42, 0.08)
    p.torso = rx(-D(4) + D(6) * haul)
    p.head = rx(-D(26) + D(6) * haul)
    p.pelvis_off = (0.0, 0.02 * haul, 0.0)
    for side, sg in SIDES.items():
        stroke(p, side, sg, ph, UP_HAND, UP_POLE, UP_PALM, wrist=D(8), curl=0.14)
    frog(p, ph - 0.46)
    return p

# Going DOWN, head first (the walker turns the body over for it): a duck-dive
# — a keyhole pull right through to the thighs, the hands sliding back up
# under the body to a streamline, and a dolphin kick, the hips piking and the
# wave running down to the toes.
DOWN_HAND = [(0.00, (0.06, 0.53, 0.06)), (0.12, (0.30, 0.38, 0.14)), (0.26, (0.16, 0.02, 0.30)),
             (0.38, (0.14, -0.44, 0.14)), (0.48, (0.14, -0.46, 0.06)), (0.62, (0.10, -0.05, 0.24)),
             (0.76, (0.06, 0.40, 0.14))]
DOWN_POLE = [(0.00, (0.7, 0.0, -0.7)), (0.20, (1.0, 0.0, -0.3)), (0.40, (0.8, -0.3, -0.5)),
             (0.62, (0.6, -0.5, 0.4)), (0.80, (0.7, 0.0, -0.6))]
DOWN_PALM = [(0.00, (0.0, 0.0, 1.0)), (0.12, (0.6, -0.6, 0.5)), (0.26, (0.0, -1.0, 0.4)),
             (0.40, (-0.6, -0.6, 0.0)), (0.55, (-1.0, 0.0, 0.2)), (0.70, (0.0, 0.0, 1.0))]

def descend_pose(ph):
    p = Pose()
    w = 2 * math.pi * ph
    wave = 2 * w
    p.pelvis = rx(D(10) * math.sin(wave))
    p.torso = rx(-D(6) * math.sin(wave - 1.0) + D(4))
    p.head = rx(D(10) - D(5) * math.sin(wave - 1.6))
    for side, sg in SIDES.items():
        stroke(p, side, sg, ph, DOWN_HAND, DOWN_POLE, DOWN_PALM, wrist=D(8), curl=0.12)
        hang(p, side, D(6) + D(16) * math.sin(wave + 0.6),
             D(6) + D(34) * (0.5 + 0.5 * math.cos(wave + 0.6 + math.pi / 2)) ** 2,
             D(1), -D(4), -D(66) + D(12) * math.sin(wave - 0.3))
    return p

SWIM_POSES = {
    "tread": lambda ph: tread_pose(ph), "hover": lambda ph: tread_pose(ph, True),
    "crawl": crawl_pose, "breast": breast_pose, "back_scull": back_pose,
    "side_left": lambda ph: side_pose(ph, 1.0), "side_right": lambda ph: side_pose(ph, -1.0),
    "ascend": ascend_pose, "descend": descend_pose,
}

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

    for name, (period, _) in SWIMS.items():
        cycle(name, SWIM_POSES[name], period, 32, fix=False)

    write_controller()

def write_controller():
    def state(name, speed, looped, fade=None, blend=None, clip=None):
        s = ["                (", '                    name: "%s",' % name,
             '                    clip: "%s/%s",' % (OUT, clip or name),
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
    # Swimming: three layers over the gaits, all at weight 0 until the walker
    # puts you in the water. Their clocks run free (unlike the Gait's), and the
    # walker sets each layer's SPEED from how fast you are really going along
    # its axis, so a stroke covers the water it should (SWIMS' metres).
    #   Swim      along the body: back-scull (-1) · tread (0) · stroke (+1) by
    #             `swimF`; a crawl at the surface, breaststroke under it.
    #   SwimSide  across it: side_right (-1) · side_left (+1) by `swimS`,
    #             weighted by how much of the motion is sideways.
    #   SwimVert  up and down: descend (-1) · ascend (+1) by `swimV`,
    #             weighted by how much of it is vertical.
    lines += layer("Swim", 0.0, [
        ("swim_surface", 1.0, True, None, ("swimF", [("back_scull", -1.0), ("tread", 0.0), ("crawl", 1.0)]), "crawl"),
        ("swim_under", 1.0, True, None, ("swimF", [("back_scull", -1.0), ("hover", 0.0), ("breast", 1.0)]), "breast"),
    ], "swim_surface", [("swim_surface", "swim_under", 0.6), ("swim_under", "swim_surface", 0.6)])
    lines += layer("SwimSide", 0.0, [
        ("swim_side", 1.0, True, None, ("swimS", [("side_right", -1.0), ("side_left", 1.0)]), "side_left")], "swim_side")
    lines += layer("SwimVert", 0.0, [
        ("swim_vert", 1.0, True, None, ("swimV", [("descend", -1.0), ("ascend", 1.0)]), "ascend")], "swim_vert")
    lines += ["    ],", ")", ""]
    open(os.path.join(ROOT, "animation_controllers/character.actl.ron"), "w").write("\n".join(lines))

if __name__ == "__main__":
    main()
    for name, g in GAITS.items():
        print("%-7s stride %.2f m per cycle, %.2f s, authored at %.1f m/s" % (name, g["speed"] * g["period"], g["period"], g["speed"]))
    for name, (period, metres) in SWIMS.items():
        print("%-10s %.1f s a cycle%s" % (name, period, ", %.1f m" % metres if metres else ""))
