"""Tiny DSL that writes Floptle .vfx.ron effects."""
import os

SOLAR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _f(x):
    return f"{float(x):.4g}" if abs(float(x)) >= 1e-4 or float(x) == 0 else f"{float(x):.6f}"


def fnum(x):
    s = _f(x)
    if "." not in s and "e" not in s and "inf" not in s:
        s += ".0"
    return s


def val(v):
    if isinstance(v, (int, float)):
        return f"F32({fnum(v)})"
    if len(v) == 3:
        return "Vec3((" + ", ".join(fnum(c) for c in v) + "))"
    if len(v) == 4:
        return "Rgba((" + ", ".join(fnum(c) for c in v) + "))"
    raise ValueError(v)


class C:  # constant
    def __init__(self, v): self.v = v
    def ron(self): return f"Const({val(self.v)})"


class R:  # random range
    def __init__(self, a, b): self.a, self.b = a, b
    def ron(self): return f"Range({val(self.a)}, {val(self.b)})"


class K:  # curve over life
    def __init__(self, keys, repeat=False, interp="Linear"):
        self.keys, self.repeat, self.interp = keys, repeat, interp

    def ron(self):
        ks = ", ".join(f"(t: {fnum(t)}, v: {val(v)}, interp: {self.interp})" for t, v in self.keys)
        return f"Curve((keys: [{ks}], extrapolate: {'Repeat' if self.repeat else 'Clamp'}))"


def prop(p):
    if isinstance(p, (C, R, K, KR)):
        return p.ron()
    return C(p).ron()


# ---- emission -------------------------------------------------------------
def burst(n, t=0.0, life=1.0, jit=0.0, pulses=1, interval=0.0, cj=0.2):
    return [(t, t + life, jit, f"Burst(count: {int(n)}, count_jitter: {fnum(cj)}, pulses: {int(pulses)}, "
             f"interval: {fnum(interval)}, interval_jitter: 0.2)")]


def stream(rate, life, t0=0.0, t1=None, jit=0.0):
    """Continuous emission from t0 to t1, each particle living `life`.

    A Rate clip's length IS the particle lifetime, so a stream longer than one
    life is tiled from several back-to-back clips."""
    if t1 is None:
        t1 = t0 + life
    out = []
    t = t0
    while t < t1 - 1e-4:
        out.append((t, t + life, jit, f"Rate(rate: {fnum(rate)})"))
        t += life
    return out


# ---- shapes / forces --------------------------------------------------------
def point(): return "Point"
def cone(angle, radius=0.0): return f"Cone(angle: {fnum(angle)}, radius: {fnum(radius)})"
def sphere(r, shell=False): return f"Sphere(radius: {fnum(r)}, shell: {'true' if shell else 'false'})"
def ring(r): return f"Ring(radius: {fnum(r)})"
def edge(l): return f"Edge(length: {fnum(l)})"
def box(x, y, z): return f"Box(size: ({fnum(x)}, {fnum(y)}, {fnum(z)}))"


def push(dx, dy, dz, s): return f"Directional(dir: ({fnum(dx)}, {fnum(dy)}, {fnum(dz)}), strength: {fnum(s)})"
def turb(freq, s): return f"Turbulence(frequency: {fnum(freq)}, strength: {fnum(s)})"


def trail(time, width, tex=None, fade=True, min_d=0.05, emitter_path=False):
    t = f"Some(\"{tex}\")" if tex else "None"
    return (f"Some((time: {fnum(time)}, width: {fnum(width)}, fade: {'true' if fade else 'false'}, "
            f"texture: {t}, min_distance: {fnum(min_d)}, emitter_path: {'true' if emitter_path else 'false'}))")


LIT_TEX = ("smoke/", "debris/", "leaf/", "water/foam")


class KR:  # random between two curves (engine CurveRange): every particle its own
    def __init__(self, a, b): self.a, self.b = a, b
    def ron(self): return f"CurveRange({self.a.ron()[6:-1]}, {self.b.ron()[6:-1]})"


# Light from behind a lit smoke or dust billboard (v0.117, card 0388): the key
# light shining through its thin edges toward the camera, so smoke against a
# low sun glows at its rim and keeps a dark core. It replaces the x1.35 colour
# lift the lit tracks used to carry, which over-brightened them front-lit.
TRANSLUCENCY = 0.6
SMOKE_TEX = ("smoke/", "water/foam")


def vary_size(k, lo=0.65):
    """A size curve -> CurveRange between it and a smaller copy."""
    if not isinstance(k, K):
        return k
    return KR(k, K([(t, v * lo) for t, v in k.keys], k.repeat, k.interp))


def vary_color(k, lo=0.82):
    """A colour curve -> CurveRange between it and a slightly darker copy."""
    if not isinstance(k, K):
        return k
    return KR(k, K([(t, (v[0] * lo, v[1] * lo, v[2] * lo, v[3])) for t, v in k.keys], k.repeat, k.interp))


def T(name, tex=None, *, blend="Alpha", clips, shape="Point", vel=(0, 0, 0), size=1.0, color=(1, 1, 1, 1),
      orient=None, space="Local", gravity=0.0, drag=0.0, inherit=0.0, forces=(), rot=None, spin=None,
      squash=None, aspect=None, stretch=None, speed_stretch=None, soft=None, lit=None, mesh=None,
      beam=None, trail_=None, max_alive=None, flip=None, enabled=True, distortion=None, vary=None,
      collide=None, land_fade=False, translucency=None):
    # Smoke, dust, grit, leaves and foam take the scene's light (v0.112 lit
    # billboards): they darken over the night side instead of glowing.
    if lit is None:
        lit = bool(tex) and blend == "Alpha" and any(k in tex for k in LIT_TEX)
    # ...and vary puff to puff (CurveRange), so no two grow alike.
    if vary is None:
        vary = lit and not mesh
    # A lit puff of smoke, dust or foam lets the light through from behind.
    if translucency is None:
        translucency = TRANSLUCENCY if (lit and not mesh and any(k in (tex or "") for k in SMOKE_TEX)) else 0
    if vary:
        size, color = vary_size(size), vary_color(color)
    # A colliding chip comes to rest on the ground, so it shrinks away over its
    # last quarter instead of popping out where it lies.
    if land_fade and isinstance(size, R):
        size = KR(K([(0, size.a), (0.75, size.a), (1, 0)]), K([(0, size.b), (0.75, size.b), (1, 0)]))
    L = ["        ("]
    L.append(f'            name: "{name}",')
    if not enabled:
        L.append("            enabled: false,")
    if mesh:
        L.append(f'            render: Mesh(asset_path: "{mesh}"),')
    elif beam is not None:
        L.append(f'            render: Beam(texture: Some("{tex}")),' if tex else "            render: Beam(),")
    else:
        L.append(f'            render: Billboard(texture: Some("{tex}")),' if tex else "            render: Billboard(),")
    L.append(f"            blend: {blend},")
    if orient:
        L.append(f"            orient: {orient},")
    if aspect is not None:
        L.append(f"            aspect: {fnum(aspect)},")
    if stretch is not None:
        L.append(f"            stretch: {fnum(stretch)},")
    if speed_stretch is not None:
        L.append(f"            speed_stretch: {fnum(speed_stretch)},")
    if flip:
        cols, rows, mode, fps = flip
        L.append(f"            flipbook: Some((cols: {cols}, rows: {rows}, mode: {mode}, fps: {fnum(fps)}, blend: true)),")
    if trail_:
        L.append(f"            trail: {trail_},")
    if beam is not None:
        segs, end, amp, freq, scroll = beam
        L.append(f"            segments: {int(segs)},")
        L.append(f"            beam_end: ({fnum(end[0])}, {fnum(end[1])}, {fnum(end[2])}),")
        if amp:
            L.append(f"            wave_amplitude: {fnum(amp)},")
            L.append(f"            wave_frequency: {fnum(freq)},")
        if scroll:
            L.append(f"            scroll: {fnum(scroll)},")
    if lit:
        L.append("            lit: true,")
        if translucency:
            L.append(f"            translucency: {fnum(translucency)},")
    if distortion is not None:
        L.append(f"            distortion: {fnum(distortion)},")
    if soft is not None:
        L.append(f"            soft: {fnum(soft)},")
    L.append(f"            space: {space},")
    cl = []
    for (a, b, j, e) in clips:
        js = f", lifetime_jitter: {fnum(j)}" if j else ""
        cl.append(f"(start: {fnum(a)}, end: {fnum(b)}{js}, emit: Some({e}))")
    L.append("            clips: [" + ", ".join(cl) + "],")
    L.append("            automation: [],")
    L.append(f"            shape: {shape},")
    if max_alive:
        L.append(f"            max_alive: Some({int(max_alive)}),")
    L.append(f"            velocity: {prop(vel if isinstance(vel, (C, R, K)) else C(tuple(vel)))},")
    L.append(f"            size: {prop(size)},")
    if squash is not None:
        L.append(f"            squash: {prop(squash)},")
    L.append(f"            rotation: {prop(rot if rot is not None else C((0, 0, 0)))},")
    L.append(f"            angular_velocity: {prop(spin if spin is not None else C((0, 0, 0)))},")
    L.append(f"            color: {prop(color if isinstance(color, (C, R, K, KR)) else C(tuple(color)))},")
    L.append(f"            gravity: {fnum(gravity)},")
    L.append(f"            drag: {fnum(drag)},")
    if inherit:
        L.append(f"            inherit_velocity: {fnum(inherit)},")
    if forces:
        L.append("            forces: [" + ", ".join(forces) + "],")
    # (bounce, friction): the particles meet the level (v0.116 rc6) instead of
    # falling through the ground. A flying particle costs a ray a frame; a
    # landed one asks nothing until the level under it changes (v0.117).
    if collide:
        b, fr, die = (tuple(collide) + (False,))[:3]
        L.append(f"            collide: Some((bounce: {fnum(b)}, friction: {fnum(fr)}, die: {'true' if die else 'false'})),")
    L.append("        ),")
    return "\n".join(L)


def effect(name, lifetime, tracks, looping=False, seed=1, field=True, header=None):
    out = []
    if header:
        for line in header.strip().splitlines():
            out.append("// " + line)
    out.append("(")
    out.append(f'    name: "{name}",')
    out.append(f"    lifetime: {fnum(lifetime)},")
    out.append(f"    playback: {'Looping' if looping else 'OneShot'},")
    out.append("    end: Destroy,")
    out.append("    tracks: [")
    out.extend(tracks)
    out.append("    ],")
    out.append(f"    seed: {seed},")
    if field:
        out.append("    gravity_mode: Field,")
    out.append(")")
    path = os.path.join(SOLAR, "vfx", name + ".vfx.ron")
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")
    print("wrote", path)
