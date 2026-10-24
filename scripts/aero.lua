-- AERO — the air, as a force: per-part aerodynamics for every craft.
--
-- A library script (no update): it rides the AeroLib node, which
-- vessel_controller (and the builder) spawn when no scene carries one, and is
-- reached with findScript("aero"). Everything here is a pure function of its
-- arguments, so the smoke test (tests/smoke_aero.lua) flies the same maths.
--
-- THE MODEL, per part, in the craft's own frame:
--
--   * BODY DRAG. Every part is a box (its builder half-widths rx, h/2, rz)
--     moving through the air. The area it shows the flow is the box's own
--     projection along the motion, each face with its own drag coefficient: a
--     tank's flat end ~0.8, its curved side ~0.6, a nose cone's point 0.15. A
--     part in a FAIRING has no drag at all (the shell has it), and a part
--     BEHIND another in the flow — the next tank down a stack, the engine under
--     it — has its end faces hidden by however much of it the part ahead
--     covers (a simple occlusion of the two parts' discs seen along the flow).
--
--   * LIFT. A lifting surface (a wing, a fin, a control surface, a rocket's
--     tail fins) is a thin plate: span along its local +X (out from the root),
--     chord along +Y (the leading edge at +Y, which is its host's nose-ward
--     axis whatever way the craft is built), normal ±Z. Its angle of attack is
--     the flow's, in the plane across the span (spanwise flow does nothing);
--     its lift slope is the finite-wing (Helmbold) one for its aspect ratio
--     and sweep, with Prandtl–Glauert compressibility; it STALLS at ~15°,
--     where attached lift gives way to a flat plate's (sin 2α) and the drag
--     climbs to the plate's (sin²α) — a stalled wing still lifts, but at a
--     terrible price, so a stall is recoverable by lowering the nose. Induced
--     drag is CL²/(π e AR). The force acts at the quarter chord of the mean
--     aerodynamic chord.
--
--   * CONTROL SURFACES move as a whole (an all-moving elevon, a rudder): the
--     pilot's pitch, yaw and roll are mixed to each one by where it sits — the
--     moment its lift has about the centre of mass decides which way it must
--     deflect for each axis, the way KSP does it — and an optional axis mask
--     (`ctl=pr`) keeps a rudder off the roll.
--
--   * MACH. The speed of sound is the world's (see `airAt`), and every drag
--     coefficient rises through the transonic (×3 at Mach 1.05, easing to ×2
--     supersonic).
--
--   * AIR is the world's own: its density (`atmo`) and height (`atmoHeight`)
--     from the world record, thinning as the engine's sky does, (1 − h/H)²
--     — or, on a deep-air world (scale 4+, `atmoScaleH`), exponentially with
--     that scale height, tapered to nothing at the top (see airShare);
--     the wind (weather.windAt) is subtracted from the craft's velocity by the
--     caller; and OXYGEN (for jets) from what the world is.
--
-- Units: masses in tonnes, so forces are kN (dynamic pressure q in Pa × area
-- in m² / 1000), torques kN·m.
--
-- THE PART DATA. A part's aero spec is the STRING `af` on its record (a
-- string so it saves inside the blueprint at any depth: save.set holds four
-- tables deep). Space-separated `key=value` pairs and bare flags; see
-- `parse` and SCRATCH/aero/NOTES.md. Parts without one (every pre-aero part)
-- get drag from their box and kind, and the stock Aero Fin is a lifting
-- surface (`legacy`).

-- ── constants ───────────────────────────────────────────────────────────────
RHO0 = 1.225          -- kg/m³: sea-level air on a world of reference density
ATMO_REF = 0.75       -- the world record's `atmo` that means RHO0
SOUND_K = 0.9         -- the speed of sound as a share of √(g·R) (see airAt)
STALL = math.rad(15)  -- a straight wing's stall angle
STALL_W = math.rad(1.2) -- how sharp the stall is
DEFL_RATE = 3.0       -- control-surface actuators: full travel per second (×1/s)
SHIELD = 0.9          -- how much of a part's end-face drag a part fully ahead of it hides

local sqrt, abs, sin, cos, atan2, exp, max, min = math.sqrt, math.abs, math.sin, math.cos, math.atan2, math.exp, math.max, math.min
local PI = math.pi

local function clamp(x, lo, hi) if x < lo then return lo elseif x > hi then return hi end return x end
local function smooth(t) t = clamp(t, 0, 1) return t * t * (3 - 2 * t) end

-- ── the part spec ───────────────────────────────────────────────────────────
-- "wing span=3 root=1.6 tip=0.8 lsw=0.9 ctl=pr defl=18" → a table. Numbers
-- become numbers, a bare word becomes `true`. Memoised by string.
local parsed = {}
function parse(s)
  if type(s) == "table" then return s end
  if type(s) ~= "string" or s == "" then return nil end
  local hit = parsed[s]
  if hit then return hit end
  local t = {}
  for tok in s:gmatch("%S+") do
    local k, v = tok:match("^([%w_]+)=(.*)$")
    if k then
      t[k] = tonumber(v) or v
    else
      t[tok] = true
    end
  end
  parsed[s] = t
  return t
end

-- Pack a table back into the string form (the builder writes a procedural
-- wing's span/chord/sweep back this way). Keys are sorted, so equal specs are
-- equal strings.
function pack(t)
  if type(t) ~= "table" then return t end
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do
    local v = t[k]
    if v == true then out[#out + 1] = k
    elseif v ~= false and v ~= nil then
      if type(v) == "number" then v = string.format("%.4g", v) end
      out[#out + 1] = k .. "=" .. tostring(v)
    end
  end
  return table.concat(out, " ")
end

-- ── the air ─────────────────────────────────────────────────────────────────
-- Worlds with life breathe oxygen; a greenhouse or a hydrocarbon world does
-- not, and a thin dry world's air is mostly CO2 (Mars). The home world always
-- does (it is where the jets are built).
OXY = { archipelago = 1, verdant = 1, alpine = 1, steppe = 1, tundra = 1, dune = 0.8,
        greenhouse = 0, titan = 0 }
function oxygen(w)
  if type(w) ~= "table" or (w.atmo or 0) < 0.05 then return 0 end
  local geo = w.geo
  if type(geo) == "table" then
    if geo.home then return 1 end
    return OXY[geo.type or ""] or 0
  end
  -- a world from before planet types: air worth the name is breathable
  return (w.atmo or 0) > 0.3 and 1 or 0
end

-- Air at altitude `alt` (m over the body's nominal radius) on world record
-- `w` (save "world.<name>": atmo, atmoHeight, radius, geo) of surface gravity
-- g and radius R. Returns density (kg/m³), the speed of sound (m/s) and the
-- oxygen share (0…1).
--
-- THE SPEED OF SOUND IS SCALED TO THE WORLD. These worlds are a few hundred
-- metres across and low orbit is ~90 m/s, so a real 340 m/s would put Mach 1
-- at four times orbital speed and nothing would ever meet it. Sound here
-- travels at 0.9·√(g·R) — 85 m/s on a 900 m home at 9.8 m/s², where low
-- orbit is 94 — so a jet meets the transonic drag rise short of orbital
-- speed, the way KSP's planes run out of air and need rockets for the rest.
function soundSpeed(g, R)
  return clamp(SOUND_K * sqrt(max(0, (g or 9.8) * (R or 800))), 25, 340)
end

function airAt(w, alt, g, R)
  local a = soundSpeed(g, R)
  if type(w) ~= "table" or (w.atmo or 0) <= 0.005 then return 0.0, a, 0 end
  R = R or w.radius or 800
  local H = (w.atmoHeight or 0) > 0 and w.atmoHeight or 0.35 * (w.radius or R)
  if alt >= H then return 0.0, a, oxygen(w) end
  -- real ground lies below the datum in places: the air there is a little
  -- thicker, never unbounded
  local h = max(alt or 0, -0.25 * H)
  if (w.atmoScaleH or 0) > 0 then
    return RHO0 * (w.atmo / ATMO_REF) * airShare(h, H, w.atmoScaleH), a, oxygen(w)
  end
  local f = (1 - h / H)
  return RHO0 * (w.atmo / ATMO_REF) * f * f, a, oxygen(w)
end

-- The air's density at height h as a share of the ground's, under a shell of
-- top H. With no scale height (world scales 1–3) it is the engine's sky
-- curve, (1 − h/H)². With one (scale 4+, the world record's `atmoScaleH`) it
-- is the real atmosphere's e^(−h/Hs), tapered so it reaches exactly nothing
-- at the top: (e^(−h/Hs) − e^(−H/Hs)) / (1 − e^(−H/Hs)). Both are 1 at the
-- ground, a little over 1 below it, and 0 at and above H.
function airShare(h, H, Hs)
  if not H or H <= 0 or h >= H then return 0.0 end
  if Hs and Hs > 0 then
    local e0 = exp(-H / Hs)
    return (exp(-h / Hs) - e0) / (1 - e0)
  end
  local f = 1 - h / H
  return f * f
end

-- The transonic drag rise: ×1 below Mach 0.75, ×3 at 1.05, easing to ×2 by Mach 2.
function machDrag(M)
  M = M or 0
  if M < 0.75 then return 1.0 end
  if M < 1.05 then return 1.0 + 2.0 * smooth((M - 0.75) / 0.3) end
  if M < 2.0 then return 3.0 - 1.0 * smooth((M - 1.05) / 0.95) end
  return 2.0
end

-- Lift-curve slope (per radian) of a wing of aspect ratio AR and quarter-chord
-- sweep `sweep` (rad) at Mach M: Helmbold's finite-wing formula with
-- Prandtl–Glauert's β, held at its Mach 0.85 value through the transonic and
-- falling as 4/√(M²−1) once that is lower (supersonic thin-wing theory).
function liftSlope(AR, sweep, M)
  AR = max(AR or 4, 0.2)
  local t2 = math.tan(sweep or 0) ^ 2
  local function sub(m)
    local b2 = max(1 - m * m, 0.0225)
    return 2 * PI * AR / (2 + sqrt(4 + AR * AR * (b2 + t2)))
  end
  M = M or 0
  if M <= 0.85 then return sub(M) end
  local s85 = sub(0.85)
  if M < 1.2 then return s85 end
  return min(s85, 4 / sqrt(M * M - 1))
end

-- CL and CD of a lifting surface at angle of attack alpha (rad, any value):
-- attached flow (slope × sin α, induced drag) blended into a flat plate past
-- the stall. `k` = { AR, sweep, cd0, e, stall } (a surface element). Returns
-- CL, CD and how stalled it is (0…1).
function coeffs(alpha, k, M)
  local AR, cd0, e = k.AR or 4, k.cd0 or 0.008, k.e or 0.8
  local a = liftSlope(AR, k.sweep or 0, M)
  alpha = alpha + (k.a0 or 0)
  if alpha > PI then alpha = alpha - 2 * PI elseif alpha < -PI then alpha = alpha + 2 * PI end
  local sa, ca = sin(alpha), cos(alpha)
  local mk = machDrag(M)
  local st = (k.stall or STALL)
  local sig = 1 / (1 + exp(-(abs(alpha) - st) / STALL_W))
  if ca < 0 then sig = 1 end   -- flying backwards: a plate
  local cl_att = a * sa
  local cd_att = cd0 * mk + cl_att * cl_att / (PI * e * AR)
  local cl_sep = 1.9 * 0.5 * 2 * sa * ca     -- 0.95·sin 2α
  local cd_sep = cd0 * mk + 1.25 * sa * sa
  return (1 - sig) * cl_att + sig * cl_sep, (1 - sig) * cd_att + sig * cd_sep, sig
end

-- ── geometry ────────────────────────────────────────────────────────────────
-- A part's local axes in the craft frame, from its builder Euler angles (the
-- same convention as builder rot_basis / vessel_controller r2_basis).
function axes(yaw, pitch, roll)
  local cy, sy = cos(yaw or 0), sin(yaw or 0)
  local cx, sx = cos(pitch or 0), sin(pitch or 0)
  local cz, sz = cos(roll or 0), sin(roll or 0)
  return { x = cy * cz + sy * sx * sz, y = cx * sz, z = -sy * cz + cy * sx * sz },
         { x = -cy * sz + sy * sx * cz, y = cx * cz, z = sy * sz + cy * sx * cz },
         { x = sy * cx, y = -sx, z = cy * cx }
end

-- A hinged trailing-edge flap of chord share cf turns the whole section's
-- zero-lift line by τ·δ (thin-airfoil theory): 0.71 for a 35 % flap. No
-- flap (nil, 0 or ≥ 1) is an all-moving surface, τ = 1.
function flapTau(cf)
  if not cf or cf <= 0 or cf >= 1 then return 1 end
  local th = math.acos(2 * cf - 1)
  return 1 - (th - math.sin(th)) / PI
end

-- The stock Aero Fin (tools/gen_part_meshes.py part_fin): its blade, in its
-- own frame — root at x −0.30, 0.67 out, root chord 0.88 (leading edge at
-- y +0.43), tip chord 0.28, the leading edge swept 0.44 m back over the span.
LEGACY_FIN = { span = 0.67, root = 0.88, tip = 0.28, lsw = 0.44, x0 = -0.30, le = 0.43 }

-- A lifting surface's planform → area, aspect ratio, sweep and the centre of
-- pressure (quarter chord of the mean aerodynamic chord) in the part frame.
-- Planform keys: span, root (chord), tip (chord, default = root), lsw (how far
-- back the leading edge sweeps over the span, m), x0 (local x of the root,
-- default −span/2: meshes are centred), le (local y of the root's leading
-- edge, default root/2), y0 (a shift of the whole blade along y).
function planform(p)
  local s = max(p.span or 1, 0.05)
  local cr = max(p.root or p.chord or 1, 0.02)
  local ct = max(p.tip or cr, 0.0)
  local lsw = p.lsw or 0
  local x0 = p.x0 or -s / 2
  local le = (p.le or cr / 2) + (p.y0 or 0)
  local S = s * (cr + ct) / 2
  local lam = ct / cr
  local ym = s / 3 * (1 + 2 * lam) / (1 + lam)
  local cm = 2 / 3 * cr * (1 + lam + lam * lam) / (1 + lam)
  local le_m = le - lsw * ym / s
  local sweep = math.atan(abs(lsw + (ct - cr) / 4) / s)
  -- A panel's root sits on a hull (or another panel), which mirrors it like
  -- a wall: it lifts as half of a wing twice its span, so its aspect ratio is
  -- that whole wing's, 2·s²/S (a lone fin, a wing half, a tail half alike).
  return { S = S, AR = 2 * s * s / S, sweep = sweep, mac = cm, cpx = x0 + ym, cpy = le_m - cm / 4,
           span = s, root = cr, tip = ct }
end

-- The surface spec of a part record, or nil: its `af` wing, or the stock fin.
local function wing_of(d, a)
  if a and a.wing then return a end
  if (d.aero == 1 or d.aero == true) and (d.id == "fins" or (d.rz or 1) < 0.1) then return LEGACY_FIN end
  return nil
end

-- Drag coefficients for a plain part: crossflow on the sides, the two ends.
local function body_cd(d, a, round)
  local side = round and 0.6 or 1.0
  local f, b = 0.8, 0.8
  local id, kind = d.id or "", d.kind or ""
  if id == "nose" or ((d.aero == 1 or d.aero == true) and (d.top == false or id:find("nose"))) then f = 0.15
  elseif kind == "crewed" then f = 0.45
  elseif kind == "engine" then b = 0.5 end
  if a then
    side = a.cd or side
    f = a.cdF or f
    b = a.cdB or b
  end
  return side, f, b
end

-- ── the model ───────────────────────────────────────────────────────────────
-- build(parts, opts) → the craft's aero model: one element per part that
-- meets the air, in the craft frame. `parts` is a list or a uid-keyed map of
-- blueprint records (or builder parts, { def = …, x, y, z, yaw, pitch, roll }).
-- opts (all optional):
--   gone(uid) / gone[uid]   parts no longer aboard
--   faired(d)               true when the part rides inside a fairing shell
--   shell(d)                true when this fairing base's shell is up
--   gearUp(d)               a landing gear that is retracted
local function flat(p)
  if p.def then
    return setmetatable({ x = p.x, y = p.y, z = p.z, yaw = p.yaw, pitch = p.pitch, roll = p.roll,
                          uid = p.uid, id = p.id, af = p.af or p.def.af, flip = p.flip },
                        { __index = p.def })
  end
  return p
end

function build(parts, opts)
  opts = opts or {}
  local gone = opts.gone
  -- camber lifts toward the craft's TOP, whichever way up a copy was mounted
  local top = opts.top
  if not top then
    local _n
    _n, top = frameOf(parts)
  end
  local M = { bodies = {}, surfs = {}, jets = {}, intakes = {}, flow = nil, gen = (opts.gen or 0) }
  local list = {}
  for k, p in pairs(parts or {}) do list[#list + 1] = p end
  table.sort(list, function(a, b) return (a.uid or 0) < (b.uid or 0) end)
  for _, p in ipairs(list) do
    local d = flat(p)
    local gone_p = gone and ((type(gone) == "function" and gone(d.uid)) or (type(gone) == "table" and gone[d.uid]))
    local faired = opts.faired and opts.faired(d)
    if not gone_p and not faired then
      local a = parse(d.af)
      local X, Y, Z = axes(d.yaw, d.pitch, d.roll)
      local px, py, pz = d.x or 0, d.y or 0, d.z or 0
      local w = wing_of(d, a)
      if w then
        local pf = planform(w)
        -- a part whose MESH was mirrored (scale −1 along z) mirrors nothing
        -- here: a planform is symmetric across its own chord plane.
        local cx = px + X.x * pf.cpx + Y.x * pf.cpy
        local cy = py + X.y * pf.cpx + Y.y * pf.cpy
        local cz = pz + X.z * pf.cpx + Y.z * pf.cpy
        local ctl = nil
        if a and a.ctl then
          local c = tostring(a.ctl)
          ctl = { p = c:find("p") and 1 or 0, y = c:find("y") and 1 or 0, r = c:find("r") and 1 or 0,
                  max = math.rad(a.defl or 20) }
        end
        -- CAMBER: cl0 is the lift at zero angle, toward the craft's top; as a
        -- zero-lift angle it shifts the curve (and the stall with it, which is
        -- what a cambered section's higher CLmax is)
        local a0, st = 0, STALL * (1 + 0.3 * sin(pf.sweep))
        local cl0 = (a and tonumber(a.cl0)) or 0
        if cl0 ~= 0 then
          local up = Z.x * top.x + Z.y * top.y + Z.z * top.z
          a0 = cl0 / liftSlope(pf.AR, pf.sweep, 0) * up
          st = st + abs(a0)
        end
        M.surfs[#M.surfs + 1] = {
          uid = d.uid, X = X, Y = Y, Z = Z, x = cx, y = cy, z = cz,
          S = pf.S, AR = pf.AR, sweep = pf.sweep, mac = pf.mac, span = pf.span,
          cd0 = (a and a.cd0) or 0.008, e = (a and a.e) or 0.8, a0 = a0,
          stall = st, ctl = ctl, tau = flapTau(a and tonumber(a.flap)), defl = 0.0, sig = 0.0,
        }
      else
        local up = opts.gearUp and a and a.gear and opts.gearUp(d)
        local hx, hy, hz = max(d.rx or 0.25, 0.02), max((d.h or 0.5) / 2, 0.02), max(d.rz or 0.25, 0.02)
        local bx, by, bz = px, py, pz
        local sf = 1.0
        if up then sf = 0.15 end   -- a stowed gear leg: a small fairing bump
        local round = abs(hx - hz) < 0.2 * max(hx, hz) and hx > 0.15
        local side, cf, cb = body_cd(d, a, round)
        -- a fairing base with its shell up: the shell is the body
        if (d.fairing or 0) > 0 and (d.fr or 0) > 0 and opts.shell and opts.shell(d) then
          hx, hz = d.fr, d.fr
          hy = ((d.fhc or 0) + (d.fhn or 0)) / 2 + hy
          local off = hy - (d.h or 0.2) / 2
          bx, by, bz = px + Y.x * off, py + Y.y * off, pz + Y.z * off
          side, cf, cb, round = 0.55, 0.25, 0.8, true
        end
        local Ay = round and PI * hx * hz or 4 * hx * hz
        M.bodies[#M.bodies + 1] = {
          uid = d.uid, X = X, Y = Y, Z = Z, x = bx, y = by, z = bz,
          Ax = 4 * hy * hz * sf, Ay = Ay * sf, Az = 4 * hx * hy * sf,
          cdx = side, cdz = side, cdF = cf, cdB = cb, sh = 0.0,
        }
      end
      if a and a.jet then
        M.jets[#M.jets + 1] = { uid = d.uid, need = a.air or 0.1, spool = a.spool or 2.0, s = 0.0, jk = 0.0,
                                mmax = a.mmax or 1.6 }
      end
      if a and a.intake then
        M.intakes[#M.intakes + 1] = { uid = d.uid, A = tonumber(a.intake) or 0.1, Y = Y }
      end
    end
  end
  return M
end

-- ── occlusion ───────────────────────────────────────────────────────────────
-- Area of the lens two discs (radii r1, r2, centres d apart) share.
local function lens(r1, r2, d)
  if d >= r1 + r2 then return 0 end
  if d <= abs(r1 - r2) then local r = min(r1, r2) return PI * r * r end
  local a = r1 * r1 * math.acos(clamp((d * d + r1 * r1 - r2 * r2) / (2 * d * r1), -1, 1))
  local b = r2 * r2 * math.acos(clamp((d * d + r2 * r2 - r1 * r1) / (2 * d * r2), -1, 1))
  local c = 0.5 * sqrt(max(0, (-d + r1 + r2) * (d + r1 - r2) * (d - r1 + r2) * (d + r1 + r2)))
  return a + b - c
end

-- For motion along unit u (craft frame), each body's shielded share: how much
-- of its disc, seen along the flow, a part AHEAD of it covers (×SHIELD).
function shield(M, ux, uy, uz)
  local B = M.bodies
  local n = #B
  local s, qx, qy, qz, R = {}, {}, {}, {}, {}
  for i = 1, n do
    local b = B[i]
    local si = b.x * ux + b.y * uy + b.z * uz
    s[i] = si
    qx[i], qy[i], qz[i] = b.x - si * ux, b.y - si * uy, b.z - si * uz
    local A = abs(b.X.x * ux + b.X.y * uy + b.X.z * uz) * b.Ax + abs(b.Y.x * ux + b.Y.y * uy + b.Y.z * uz) * b.Ay
            + abs(b.Z.x * ux + b.Z.y * uy + b.Z.z * uz) * b.Az
    R[i] = sqrt(max(A, 1e-6) / PI)
  end
  for i = 1, n do
    local cov = 0
    for j = 1, n do
      if j ~= i and s[j] > s[i] + 0.05 then
        local dx, dy, dz = qx[i] - qx[j], qy[i] - qy[j], qz[i] - qz[j]
        local d = sqrt(dx * dx + dy * dy + dz * dz)
        if d < R[i] + R[j] then
          local c = lens(R[i], R[j], d) / (PI * R[i] * R[i])
          if c > cov then cov = c end
        end
      end
    end
    B[i].sh = SHIELD * min(1, cov)
  end
  M.flow = { ux, uy, uz }
end

-- ── forces ──────────────────────────────────────────────────────────────────
-- One surface's force (craft frame, kN) for air-relative velocity v of its
-- centre of pressure, air density rho, Mach M and deflection defl (rad).
function surfaceForce(s, vx, vy, vz, rho, M, defl)
  local X, Y, Z = s.X, s.Y, s.Z
  local Yx, Yy, Yz, Zx, Zy, Zz = Y.x, Y.y, Y.z, Z.x, Z.y, Z.z
  if defl and defl ~= 0 then
    local c, sn = cos(defl), sin(defl)
    Yx, Yy, Yz, Zx, Zy, Zz = Y.x * c + Z.x * sn, Y.y * c + Z.y * sn, Y.z * c + Z.z * sn,
                             Z.x * c - Y.x * sn, Z.y * c - Y.y * sn, Z.z * c - Y.z * sn
  end
  local vs = vx * X.x + vy * X.y + vz * X.z
  local wx, wy, wz = vx - vs * X.x, vy - vs * X.y, vz - vs * X.z
  local V2 = wx * wx + wy * wy + wz * wz
  if V2 < 1e-4 or rho <= 0 then return 0, 0, 0, 0, 0 end
  local V = sqrt(V2)
  local alpha = atan2(-(wx * Zx + wy * Zy + wz * Zz), wx * Yx + wy * Yy + wz * Yz)
  local CL, CD, sig = coeffs(alpha, s, M)
  local q = 0.5 * rho * V2 * s.S / 1000.0
  -- u: the air past the surface; lift along u × span
  local ux, uy, uz = -wx / V, -wy / V, -wz / V
  local lx, ly, lz = uy * X.z - uz * X.y, uz * X.x - ux * X.z, ux * X.y - uy * X.x
  return q * (CL * lx + CD * ux), q * (CL * ly + CD * uy), q * (CL * lz + CD * uz), alpha, sig
end

-- One body's drag (craft frame, kN) for air-relative velocity v.
function bodyForce(b, vx, vy, vz, rho, mk)
  local V2 = vx * vx + vy * vy + vz * vz
  if V2 < 1e-4 or rho <= 0 then return 0, 0, 0 end
  local V = sqrt(V2)
  local ux, uy, uz = vx / V, vy / V, vz / V
  local cx = ux * b.X.x + uy * b.X.y + uz * b.X.z
  local cy = ux * b.Y.x + uy * b.Y.y + uz * b.Y.z
  local cz = ux * b.Z.x + uy * b.Z.y + uz * b.Z.z
  local cda = abs(cx) * b.Ax * b.cdx + abs(cz) * b.Az * b.cdz
            + abs(cy) * b.Ay * (cy > 0 and b.cdF or b.cdB) * (1 - (b.sh or 0))
  local k = -0.5 * rho * V2 * cda * (mk or 1) / 1000.0
  return k * ux, k * uy, k * uz
end

-- A jet's thrust as a share of its rated (static, sea-level, reference-air)
-- thrust at Mach M: a turbojet's net thrust holds level and climbs a little
-- with ram compression, then falls away as the intake air gets too hot to burn
-- in — gone by about Mach 2 (`mmax` sets where it peaks out).
function jetMach(M, mmax)
  M = max(M or 0, 0)
  local m2 = (mmax or 1.6)
  return (1 + 0.15 * M * M) * exp(-(M / m2) ^ 4)
end

-- THE TICK. env (craft frame unless said):
--   vx,vy,vz   the centre of mass's velocity through the AIR (wind removed)
--   wx,wy,wz   angular velocity
--   cx,cy,cz   the centre of mass
--   rho, a, o2 the air (airAt), sigma = rho / RHO0
--   dt
--   ctl        { p, y, r }  −1…1 control commands (stick + trim + assist)
--   ap, ay, ar the craft's pitch / yaw / roll axes (the stick's rotation axes)
--   throttle   0…1 (jets)
-- Returns Fx,Fy,Fz, Tx,Ty,Tz (kN, kN·m about the CoM, craft frame) and fills
-- M.diag = { q, mach, lift, drag, stall } and each jet's `jk` (thrust share,
-- throttle included) and `jb` (fuel share).
function step(M, env)
  local vx, vy, vz = env.vx or 0, env.vy or 0, env.vz or 0
  local wx, wy, wz = env.wx or 0, env.wy or 0, env.wz or 0
  local cx, cy, cz = env.cx or 0, env.cy or 0, env.cz or 0
  local rho = env.rho or 0
  local V = sqrt(vx * vx + vy * vy + vz * vz)
  local Mach = V / max(env.a or 340, 1)
  local mk = machDrag(Mach)
  local dt = env.dt or 0.0167
  -- the occlusion follows the flow (re-cut when it turns more than ~4°)
  if V > 0.5 then
    local ux, uy, uz = vx / V, vy / V, vz / V
    local f = M.flow
    if not f or f[1] * ux + f[2] * uy + f[3] * uz < 0.9975 then shield(M, ux, uy, uz) end
  end
  local Fx, Fy, Fz, Tx, Ty, Tz = 0, 0, 0, 0, 0, 0
  local lift, drag = 0, 0
  local function add(fx, fy, fz, px, py, pz)
    Fx, Fy, Fz = Fx + fx, Fy + fy, Fz + fz
    local rx, ry, rz = px - cx, py - cy, pz - cz
    Tx = Tx + ry * fz - rz * fy
    Ty = Ty + rz * fx - rx * fz
    Tz = Tz + rx * fy - ry * fx
  end
  for _, b in ipairs(M.bodies) do
    local rx, ry, rz = b.x - cx, b.y - cy, b.z - cz
    local ex, ey, ez = vx + wy * rz - wz * ry, vy + wz * rx - wx * rz, vz + wx * ry - wy * rx
    local fx, fy, fz = bodyForce(b, ex, ey, ez, rho, mk)
    add(fx, fy, fz, b.x, b.y, b.z)
  end
  local ctl = env.ctl
  local Sw, Ss = 0, 0
  for _, s in ipairs(M.surfs) do
    local rx, ry, rz = s.x - cx, s.y - cy, s.z - cz
    -- the deflection this surface is asked for: each axis's command, signed by
    -- which way this surface's lift turns the craft about that axis
    local want = 0
    if s.ctl and ctl then
      local mx, my, mz = ry * s.Z.z - rz * s.Z.y, rz * s.Z.x - rx * s.Z.z, rx * s.Z.y - ry * s.Z.x
      local gp = env.ap and (mx * env.ap.x + my * env.ap.y + mz * env.ap.z) or 0
      local gy = env.ay and (mx * env.ay.x + my * env.ay.y + mz * env.ay.z) or 0
      local gr = env.ar and (mx * env.ar.x + my * env.ar.y + mz * env.ar.z) or 0
      gp, gy, gr = gp * s.ctl.p, gy * s.ctl.y, gr * s.ctl.r
      local g = max(abs(gp), abs(gy), abs(gr), 1e-6)
      want = ((ctl.p or 0) * gp + (ctl.y or 0) * gy + (ctl.r or 0) * gr) / g
      want = clamp(want, -1, 1)
    end
    local cur = s.cmd or 0
    local stepd = DEFL_RATE * dt
    if want > cur then cur = min(want, cur + stepd) else cur = max(want, cur - stepd) end
    s.cmd = cur
    s.defl = s.ctl and cur * s.ctl.max or 0
    local ex, ey, ez = vx + wy * rz - wz * ry, vy + wz * rx - wx * rz, vz + wx * ry - wy * rx
    -- a hinged flap turns the section's zero-lift line by τ of its own travel
    local fx, fy, fz, alpha, sig = surfaceForce(s, ex, ey, ez, rho, Mach, s.defl * (s.tau or 1))
    s.alpha, s.sig = alpha or 0, sig or 0
    add(fx, fy, fz, s.x, s.y, s.z)
    if not s.ctl then Sw, Ss = Sw + s.S, Ss + s.S * (sig or 0) end
  end
  if V > 1e-3 then
    drag = -(Fx * vx + Fy * vy + Fz * vz) / V
    local px, py, pz = Fx + drag * vx / V, Fy + drag * vy / V, Fz + drag * vz / V
    lift = sqrt(px * px + py * py + pz * pz)
  end
  -- JETS: spool toward the throttle; thrust by the air they get
  local supply, demand = 0, 0
  for _, it in ipairs(M.intakes) do
    local face = V > 0.5 and (it.Y.x * vx + it.Y.y * vy + it.Y.z * vz) / V or 1
    supply = supply + it.A * (0.6 + 0.4 * max(0, face)) * (1 + 0.8 * Mach)
  end
  for _, j in ipairs(M.jets) do demand = demand + j.need end
  local airf = demand > 0 and min(1, supply / demand) or 0
  local sigma = rho / RHO0
  local o2 = env.o2 or 1
  for _, j in ipairs(M.jets) do
    local lit = sigma > 0.03 and airf > 0.15 and o2 > 0.05
    local target = lit and clamp(env.throttle or 0, 0, 1) or 0
    local tau = target > j.s and j.spool or j.spool * 0.5
    j.s = j.s + (target - j.s) * min(1, dt / max(tau, 0.05))
    if not lit then j.s = max(0, j.s - dt * 2) end
    local k = lit and j.s * sigma ^ 0.7 * jetMach(Mach, j.mmax) * airf * min(1, o2) or 0
    j.jk, j.jb, j.lit = k, lit and j.s * sigma ^ 0.7 * airf or 0, lit
  end
  M.diag = { q = 0.5 * rho * V * V, mach = Mach, lift = lift, drag = drag, v = V,
             stall = Sw > 0 and Ss / Sw or 0, air = airf, rho = rho }
  return Fx, Fy, Fz, Tx, Ty, Tz
end

-- ── the builder's readouts ──────────────────────────────────────────────────
-- The craft's nose and top in its own frame: the command part's (a cockpit
-- flown nose-first: its +Y is the nose, −Z the top), else +Y and −Z — the
-- rocket's, exactly what vessel_controller flies by.
function frameOf(parts)
  local best
  for _, p in pairs(parts or {}) do
    local d = flat(p)
    local a = parse(d.af)
    if a and a.cockpit then best = d break end
    if not best and d.kind == "crewed" then best = d end
  end
  if best then
    local a = parse(best.af)
    local _, Y, Z = axes(best.yaw, best.pitch, best.roll)
    if (a and a.cockpit) or Y.y < 0.866 then
      return { x = Y.x, y = Y.y, z = Y.z }, { x = -Z.x, y = -Z.y, z = -Z.z }
    end
  end
  return { x = 0, y = 1, z = 0 }, { x = 0, y = 0, z = -1 }
end

-- The centre of mass (craft frame) of a part list, propellant included
-- (`fuel` × `fuel_t`, FUEL_T_PER_UNIT when absent).
function centerOfMass(parts, fuel_t)
  local m, x, y, z = 0, 0, 0, 0
  for _, p in pairs(parts or {}) do
    local d = flat(p)
    local dm = (d.mass or 0) + (d.fuel or 0) * (d.fuel_t or fuel_t or 0.01)
    m, x, y, z = m + dm, x + (d.x or 0) * dm, y + (d.y or 0) * dm, z + (d.z or 0) * dm
  end
  if m <= 0 then return nil end
  return x / m, y / m, z / m, m
end

-- THE CENTRE OF LIFT: where the lifting surfaces' lift acts, flying along the
-- nose at `alpha` (default 5°) nose-up — the point the builder draws, and the
-- one that must sit BEHIND the centre of mass for a craft to fly nose-first.
-- Returns x, y, z (craft frame), the lift per unit dynamic pressure (kN/Pa,
-- i.e. m²·CL / 1000) and its direction; nil when nothing lifts.
function centerOfLift(parts, opts)
  opts = opts or {}
  local M = build(parts, opts)
  local n, t = frameOf(parts)
  if opts.nose then n = opts.nose end
  if opts.top then t = opts.top end
  local al = opts.alpha or math.rad(5)
  local ca, sa = cos(al), sin(al)
  local vx, vy, vz = n.x * ca - t.x * sa, n.y * ca - t.y * sa, n.z * ca - t.z * sa
  local W, X, Y, Z, Lx, Ly, Lz = 0, 0, 0, 0, 0, 0, 0
  for _, s in ipairs(M.surfs) do
    local fx, fy, fz = surfaceForce(s, vx, vy, vz, 2000.0, 0, 0)   -- q = 1000 Pa·V²: kN per kPa
    local w = fx * t.x + fy * t.y + fz * t.z
    W, X, Y, Z = W + w, X + w * s.x, Y + w * s.y, Z + w * s.z
    Lx, Ly, Lz = Lx + fx, Ly + fy, Lz + fz
  end
  if abs(W) < 1e-6 then return nil end
  return X / W, Y / W, Z / W, W, { x = Lx, y = Ly, z = Lz }
end

-- THE CENTRE OF THRUST: thrust-weighted engine positions and the summed
-- thrust line (unit) — what the builder draws as the arrow. nil without engines.
function centerOfThrust(parts)
  local T, X, Y, Z, dx, dy, dz = 0, 0, 0, 0, 0, 0, 0
  for _, p in pairs(parts or {}) do
    local d = flat(p)
    local th = d.thrust or 0
    if th > 0 then
      local _, Ya = axes(d.yaw, d.pitch, d.roll)
      T, X, Y, Z = T + th, X + th * (d.x or 0), Y + th * (d.y or 0), Z + th * (d.z or 0)
      dx, dy, dz = dx + th * Ya.x, dy + th * Ya.y, dz + th * Ya.z
    end
  end
  if T <= 0 then return nil end
  local l = sqrt(dx * dx + dy * dy + dz * dz)
  return X / T, Y / T, Z / T, T, l > 0 and { x = dx / l, y = dy / l, z = dz / l } or { x = 0, y = 1, z = 0 }
end

-- STATIC MARGIN: how far the centre of lift sits behind the centre of mass
-- along the nose, in metres (positive = stable) and in mean chords.
function staticMargin(parts, opts)
  local lx, ly, lz = centerOfLift(parts, opts)
  local mx, my, mz = centerOfMass(parts)
  if not (lx and mx) then return nil end
  local n = frameOf(parts)
  local d = (mx - lx) * n.x + (my - ly) * n.y + (mz - lz) * n.z
  local M = build(parts, opts)
  local S, c = 0, 0
  for _, s in ipairs(M.surfs) do if not s.ctl then S, c = S + s.S, c + s.S * s.mac end end
  return d, S > 0 and d / (c / S) or nil
end

-- Wing area and the speed it stalls at for mass m (t) on a world of gravity g
-- in air of density rho, level flight: v = √(2·m·g / (ρ·S·CLmax)).
function stallSpeed(parts, m, g, rho)
  local M = build(parts)
  local _, top = frameOf(parts)
  local S, CLmax = 0, 0
  for _, s in ipairs(M.surfs) do
    -- the wings: lifting surfaces lying across the top (not fins, not tails)
    local k = abs(s.Z.x * top.x + s.Z.y * top.y + s.Z.z * top.z)
    if not s.ctl and k > 0.3 then
      local best = 0
      for i = 0, 50 do
        local cl = coeffs(math.rad(i * 0.5), s, 0)
        if cl > best then best = cl end
      end
      S, CLmax = S + s.S * k, CLmax + best * s.S * k
    end
  end
  if S <= 0 or rho <= 0 then return nil end
  CLmax = CLmax / S
  return sqrt(2 * m * 1000 * g / (rho * S * CLmax)), S, CLmax
end
