-- ROPE CLIMB — a Rope Kit's line: clipping on, climbing it, stepping off.
--
-- A Rope Kit (items.lua `rope`) is planted by the deploy mode like a flag: a
-- galvanised edge davit (prefabs/RopePylon, deployables kind "rope") with its
-- boom out over the drop, -Z away from whoever planted it. Its line runs over
-- the sheave and falls: straight down, along any rock face it meets, until it
-- lies on the ground or runs out (30 m). That fall is the LAYOUT, worked out
-- once from the terrain's own field and kept in the save beside the record
-- (`rope.<id>`), so a reload hangs the same rope without asking the ground
-- again. scripts/rope.lua draws it; this library climbs it.
--
-- CLIMBING. E within reach of the line clips the crew on (at the davit: a
-- tap clips on at the top, over the edge; holding E takes the kit down).
-- Clipped on, the crew is HELD (crew.held(), so the walker, the RCS Pack and
-- the impact monitor stand down) and KINEMATIC: placed every tick at a point
-- of the line, in the planet's frame, from that tick's pose. W hauls up on the
-- kit's powered ascender, S lets out through the descender (SHIFT: a fast
-- rappel), E unclips: at the top the crew steps off onto the ledge behind the
-- davit, at the bottom onto the ground, and anywhere between they let go and
-- fall — the crew's impact rules judge the landing.
--
-- THE PHYSICS. The ascender is a motor: `power` watts against the weight of
-- crew, suit and pack in the local gravity, capped at its line speed. On the
-- home world (9.8 m/s², ~135 kg) that is about 0.8 m/s; on a light moon the
-- cap. The way down is the descender's friction: a steady 1.6 m/s whatever
-- the gravity. The climb comes in strokes (the ascender's cam bites, slips,
-- bites): the speed pulses with a stroke of `stroke` metres, and each bite
-- clicks.
--
-- FRAMES (docs/positions-and-frames.md). Everything kept is body-relative:
-- the layout, the climber's place on it (an arc length `s`), the slide in and
-- the step off. fixedUpdate places the body from space.body() read in that
-- tick; lateUpdate puts the hands on the line and the feet on the wall from
-- the davit node's DRAWN pose. Nothing world-frame outlives a frame.
--
-- The rules at the top are pure (tests/smoke_rope.lua loads this file in
-- luajit): layouts, positions along the line, the ends, speeds, the stroke.
--
-- API (findScript("rope_climb")):
--   layoutOf(id) → L          climbing() → bool       state() → table
--   clipOn(id [, s]) → ok, why    unclip() → kind      takeDown(id) → ok, why
--   prompting() → bool (E is the rope's)                sim = { move, fast }
--   faceDir() → dx,dy,dz (the walker faces the wall while held)
--   guardGroups(recs), guardCount: the dig guards under the davits (base_facilities)

defaults = {
  --@header Ascender
  -- The powered ascender's motor, at the rope (W). 1.1 kW lifts ~135 kg at
  -- 0.8 m/s on a 9.8 m/s² world.
  --@range 100 3000 --@units W
  power = 1100.0,
  -- Its top line speed (m/s), whatever the load.
  --@range 0.2 4 --@units m/s
  line_max = 1.2,
  --@header Descender
  --@range 0.2 5 --@units m/s
  down = 1.6,
  -- SHIFT held: a fast rappel.
  --@range 0.2 6 --@units m/s
  down_fast = 2.8,
}

-- ── the numbers (tools/gen_rope.py prints the davit's) ─────────────────────
ROPE = {
  length = 30.0,       -- m of 11 mm static line in the kit
  radius = 0.0055,
  origin = 0.75,       -- the davit's root over its ground point (deployables)
  drop_y = 1.42,       -- the line leaves the sheave this high over the ground point
  drop_out = 0.885,    -- … and this far out over the drop (along -Z)
  power = 1100.0, line_max = 1.2, down = 1.6, down_fast = 2.8,
  accel = 5.0,         -- 1/s: how fast the line speed follows the keys
  stroke = 0.32,       -- m of line per ascender stroke
  body_kg = 120.0,     -- crew and suit; the pack's contents are added
  hang = 0.65,         -- m: the suit's centre under the upper hand
  away = 0.38,         -- m: … and out from the line, away from the wall
  feet_max = 0.55,     -- m: a wall this far from the line is out of the feet's reach
  foot = 1.0,          -- m: the suit's centre over its soles
  top = 0.45,          -- m of line from the sheave to the upper hand, at the top
  knot = 0.35,         -- m of tail under a stopper knot at a free end
  gap = 0.015,         -- m: the line's skin over the surface it lies on (its centre radius + gap out)
  floor = 0.70,        -- a hit facing up past this (≈45°) is ground the line lies on
  wall_max = 1.6,      -- m: how far from the line a wall is looked for (feet)
  step = 1.0,          -- m: the drape's step along a face
  clip_reach = 1.4,    -- m from the suit's centre to its hang point on the line
  pylon_reach = 2.2,   -- m from the suit to the davit's mast
  slide = 0.45,        -- s to slide onto the line
  step_secs = 0.85,    -- s to step off onto the ledge
  tap = 0.3,           -- s: E released sooner at the davit is a tap (clip on)
  take_secs = 1.4,     -- s of held E to take the kit down
  back = 1.2,          -- m behind the mast: where the crew stands after stepping off
}

local function P(k)
  local v = params and params[k]
  if v == nil then v = ROPE[k] end
  return v
end

local sqrt, floor, min, max, abs = math.sqrt, math.floor, math.min, math.max, math.abs
local function len3(x, y, z) return sqrt(x * x + y * y + z * z) end
local function norm3(x, y, z)
  local l = len3(x, y, z)
  if l < 1e-9 then return 0, 0, 0, 0 end
  return x / l, y / l, z / l, l
end
local function smooth(k) k = max(0, min(1, k)); return k * k * (3 - 2 * k) end

-- The horizontal part of a direction against `u`, unit, or nil.
local function horiz(x, y, z, ux, uy, uz)
  local d = x * ux + y * uy + z * uz
  local hx, hy, hz, l = norm3(x - ux * d, y - uy * d, z - uz * d)
  if l < 0.05 then return nil end
  return hx, hy, hz
end

-- The way a planted davit faces, exactly as deployables stands its node
-- (facing_of): `f` toward the planter, flattened; its -Z (the boom) is -f.
function facing(x, y, z, fx, fy, fz)
  local ux, uy, uz = norm3(x, y, z)
  local d = fx * ux + fy * uy + fz * uz
  fx, fy, fz = fx - ux * d, fy - uy * d, fz - uz * d
  if len3(fx, fy, fz) < 1e-4 then
    fx, fy, fz = 1 - ux * ux, -ux * uy, -ux * uz
    if fx * fx + fy * fy + fz * fz < 1e-4 then fx, fy, fz = 0, 0, 1 end
  end
  fx, fy, fz = norm3(fx, fy, fz)
  return ux, uy, uz, fx, fy, fz
end

-- ── a layout ────────────────────────────────────────────────────────────────
-- L = { p = {x,y,z …} the line's points from the sheave down (body-relative),
--       a = {…} per point, the way AWAY from the wall (horizontal, unit),
--       u = {ux,uy,uz}, g = grounded (the end lies on the ground),
--       wd = {…} the wall's distance from the line each metre (-1: none),
--       len = the line's length }
-- finished with: n, cum (arc length per point), total, s_top, s_max.

-- Where along the line: → x,y,z (the line), ax,ay,az (away), dx,dy,dz (down it)
function at(L, s)
  local p, a, cum, n = L.p, L.a, L.cum, L.n
  if s < 0 then s = 0 elseif s > L.total then s = L.total end
  local i = 1
  while i < n - 1 and cum[i + 1] < s do i = i + 1 end
  local seg = cum[i + 1] - cum[i]
  local f = seg > 1e-9 and (s - cum[i]) / seg or 0
  if f < 0 then f = 0 elseif f > 1 then f = 1 end
  local j = 3 * (i - 1)
  local x = p[j + 1] + (p[j + 4] - p[j + 1]) * f
  local y = p[j + 2] + (p[j + 5] - p[j + 2]) * f
  local z = p[j + 3] + (p[j + 6] - p[j + 3]) * f
  local ax, ay, az = norm3(a[j + 1] + (a[j + 4] - a[j + 1]) * f, a[j + 2] + (a[j + 5] - a[j + 2]) * f,
                           a[j + 3] + (a[j + 6] - a[j + 3]) * f)
  local dx, dy, dz = 0, 0, 0
  if seg > 1e-9 then dx, dy, dz = (p[j + 4] - p[j + 1]) / seg, (p[j + 5] - p[j + 2]) / seg, (p[j + 6] - p[j + 3]) / seg end
  return x, y, z, ax, ay, az, dx, dy, dz
end

-- The height of a point along the line's up.
local function height(L, x, y, z) return x * L.u[1] + y * L.u[2] + z * L.u[3] end

-- Arc lengths and the two ends a climber can reach: the top (hands just under
-- the sheave) and the bottom (soles on the ground, or the stopper knot).
function finish(L)
  local p = L.p
  local n = floor(#p / 3)
  L.n = n
  L.cum = { 0 }
  for i = 2, n do
    local j = 3 * (i - 1)
    L.cum[i] = L.cum[i - 1] + len3(p[j + 1] - p[j - 2], p[j + 2] - p[j - 1], p[j + 3] - p[j])
  end
  L.total = L.cum[n] or 0
  local st = min(ROPE.top, L.total)
  local smax = st
  if L.g then
    local hend = height(L, p[3 * n - 2], p[3 * n - 1], p[3 * n])
    local need = ROPE.hang + ROPE.foot
    local s = L.total
    while s > st do
      local x, y, z = at(L, s)
      if height(L, x, y, z) - hend >= need then smax = s break end
      s = s - 0.05
    end
  else
    smax = max(st, L.total - ROPE.knot)
  end
  L.s_top, L.s_max = st, smax
  return L
end

-- Can anyone climb it? (A davit set back from any edge drops its line
-- straight onto the ground under the boom.)
function climbable(L) return L ~= nil and L.s_max - L.s_top > 0.25 end

-- The suit's centre for a climber at `s` (hands at `s`): out from the line,
-- below the hands.
function bodyAt(L, s)
  local x, y, z, ax, ay, az = at(L, s)
  local u = L.u
  return x + ax * ROPE.away - u[1] * ROPE.hang, y + ay * ROPE.away - u[2] * ROPE.hang,
         z + az * ROPE.away - u[3] * ROPE.hang
end

-- The wall's distance from the line at `s` (m), or nil (none within reach).
function wallAt(L, s)
  local wd = L.wd
  if not wd or #wd == 0 then return nil end
  local k = floor(s + 0.5) + 1
  if k < 1 then k = 1 elseif k > #wd then k = #wd end
  local d = wd[k]
  if not d or d < 0 then return nil end
  return d
end

-- … blended between the metres where both have a wall (else the nearest).
function wallSmooth(L, s)
  local wd = L.wd
  if not wd or #wd == 0 then return nil end
  local f = max(0, s)
  local k = floor(f)
  f = f - k
  local a, b = wd[min(#wd, k + 1)], wd[min(#wd, k + 2)]
  if a and b and a >= 0 and b >= 0 then return a * (1 - f) + b * f end
  return wallAt(L, s)
end

-- The climbable point nearest a suit centre (body-relative): → s, distance.
function nearestS(L, x, y, z)
  if not climbable(L) then return nil end
  local best, bd = nil, 1e18
  local s = L.s_top
  while s <= L.s_max + 1e-6 do
    local bx, by, bz = bodyAt(L, s)
    local d = (bx - x) ^ 2 + (by - y) ^ 2 + (bz - z) ^ 2
    if d < bd then best, bd = s, d end
    s = s + 0.2
  end
  -- refine round the best sample
  local lo, hi = max(L.s_top, best - 0.2), min(L.s_max, best + 0.2)
  for _ = 1, 12 do
    local m1, m2 = lo + (hi - lo) / 3, hi - (hi - lo) / 3
    local ax, ay, az = bodyAt(L, m1)
    local bx, by, bz = bodyAt(L, m2)
    if (ax - x) ^ 2 + (ay - y) ^ 2 + (az - z) ^ 2 < (bx - x) ^ 2 + (by - y) ^ 2 + (bz - z) ^ 2 then hi = m2 else lo = m1 end
  end
  best = (lo + hi) / 2
  local bx, by, bz = bodyAt(L, best)
  return best, len3(bx - x, by - y, bz - z)
end

-- What E does at `s`: "top" (step off onto the ledge), "bottom" (onto the
-- ground) or "fall" (let go).
function unclipKind(L, s)
  if s <= L.s_top + 0.05 then return "top" end
  if L.g and s >= L.s_max - 0.05 then return "bottom" end
  return "fall"
end

-- How far the soles are over the ground the line lies on (m), or nil when the
-- line hangs free (its end is in the air: the ground is further than 30 m).
function dropAt(L, s)
  if not L.g then return nil end
  local p, n = L.p, L.n
  local x, y, z = at(L, s)
  return max(0, height(L, x, y, z) - ROPE.hang - ROPE.foot - height(L, p[3 * n - 2], p[3 * n - 1], p[3 * n]))
end

-- The line speeds (m/s): up on the ascender's motor against the weight, down
-- at the descender's rate. `g` m/s², `kg` the whole load.
function speeds(g, kg, fast, pr)
  pr = pr or ROPE
  local line_max = pr.line_max or ROPE.line_max
  local up = line_max
  if g and g > 0.01 then up = min(line_max, (pr.power or ROPE.power) / (max(1, kg or ROPE.body_kg) * g)) end
  local down = fast and (pr.down_fast or ROPE.down_fast) or (pr.down or ROPE.down)
  return up, down
end

-- One step of the climb. `st` = { s, v (ds/dt: + is down the line), phase };
-- `want` +1 up, -1 down, 0 hold. → st, "top" | "bottom" | nil (an end
-- reached under the keys), true when an ascender stroke bit.
function move(st, want, dt, up, down, L)
  local tv = 0
  if want > 0 then tv = -up elseif want < 0 then tv = down end
  st.v = st.v + (tv - st.v) * (1 - math.exp(-ROPE.accel * dt))
  if tv == 0 and abs(st.v) < 0.01 then st.v = 0 end
  -- the ascender's strokes: slow as the cam bites, fast as it pulls through
  -- (the phase runs with distance, so the pulse's harmonic mean is 1: ×1.25
  -- keeps the average speed the line speed)
  local pulse = 1
  if st.v < 0 then pulse = 1.25 * (1 - 0.6 * math.cos(2 * math.pi * st.phase)) end
  local s0 = st.s
  st.s = st.s + st.v * pulse * dt
  local ended = nil
  if st.s <= L.s_top then
    st.s = L.s_top
    if st.v < 0 then st.v = 0 end
    if want > 0 then ended = "top" end
  elseif st.s >= L.s_max then
    st.s = L.s_max
    if st.v > 0 then st.v = 0 end
    if want < 0 then ended = "bottom" end
  end
  local ph0 = st.phase
  st.phase = st.phase + abs(st.s - s0) / ROPE.stroke
  return st, ended, s0 > st.s and floor(st.phase) > floor(ph0)
end

-- THE CHORDS CLEARED. The drape's points lie on the surface, but the straight
-- line between two of them can cut through the rock between: a bulge on a
-- face the 1 m steps stepped over, the round of a lip (playtest 2026-11-11:
-- "ropes can clip through walls"). Each segment is cast along, end to end;
-- where it meets something short of its end, a point goes in on the surface
-- there (R2 out along its normal) and both halves are checked again, so the
-- line wraps a bulge the way a loaded rope does. At most CLEAR.most points
-- (a line's worth of 1 m steps over a rough face), none on a piece shorter
-- than CLEAR.min_seg. → points added [, "unknown"]
CLEAR = { most = 64, min_seg = 0.1, skin = 0.004 }
function clearPath(Pp, A, cast, R2, u)
  local i, added = 1, 0
  local ux, uy, uz = u[1], u[2], u[3]
  while i < #Pp / 3 do
    local j = 3 * (i - 1)
    local x0, y0, z0 = Pp[j + 1], Pp[j + 2], Pp[j + 3]
    local dx, dy, dz, l = norm3(Pp[j + 4] - x0, Pp[j + 5] - y0, Pp[j + 6] - z0)
    local h = nil
    if l > CLEAR.min_seg and added < CLEAR.most then
      local why
      h, why = cast(x0, y0, z0, dx, dy, dz, l)
      if why == "unknown" then return added, "unknown" end
    end
    if h and h.d > CLEAR.skin and h.d < l - CLEAR.skin and h.d < CLEAR.min_seg and i > 1 then
      -- the rock rises right in front of a point the line lies on: that
      -- point is lifted off it (a new point there would be no piece at all)
      Pp[j + 1], Pp[j + 2], Pp[j + 3] = x0 + h.nx * R2, y0 + h.ny * R2, z0 + h.nz * R2
      added = added + 1
    elseif h and h.d > CLEAR.skin and h.d < l - CLEAR.skin then
      local mx, my, mz = h.x + h.nx * R2, h.y + h.ny * R2, h.z + h.nz * R2
      local ax, ay, az = horiz(h.nx, h.ny, h.nz, ux, uy, uz)
      if not ax then ax, ay, az = A[j + 1], A[j + 2], A[j + 3] end
      table.insert(Pp, j + 4, mz); table.insert(Pp, j + 4, my); table.insert(Pp, j + 4, mx)
      table.insert(A, j + 4, az); table.insert(A, j + 4, ay); table.insert(A, j + 4, ax)
      added = added + 1
    else
      i = i + 1
    end
  end
  return added
end

-- The tail's points (body-relative, flat x,y,z…) from the line's grounded
-- end: TAIL m out along the way away from the wall, the last a little to
-- the side, each set down on what is under it; cut short where the run
-- meets something or there is no ground under it.
TAIL = { { 0.35, 0 }, { 0.75, 0.25 } }
function layTail(L, cast, R2)
  local p, a, u = L.p, L.a, L.u
  local n = L.n
  local ex, ey, ez = p[3 * n - 2], p[3 * n - 1], p[3 * n]
  local ax, ay, az = a[3 * n - 2], a[3 * n - 1], a[3 * n]
  local sx, sy, sz = norm3(u[2] * az - u[3] * ay, u[3] * ax - u[1] * az, u[1] * ay - u[2] * ax)
  local out = {}
  local px, py, pz = ex, ey, ez
  for _, k in ipairs(TAIL) do
    local qx = ex + ax * k[1] + sx * k[2]
    local qy = ey + ay * k[1] + sy * k[2]
    local qz = ez + az * k[1] + sz * k[2]
    local h, why = cast(qx + u[1] * 0.4, qy + u[2] * 0.4, qz + u[3] * 0.4, -u[1], -u[2], -u[3], 0.8)
    if why == "unknown" or not h then break end
    qx, qy, qz = h.x + h.nx * R2, h.y + h.ny * R2, h.z + h.nz * R2
    local dx, dy, dz, l = norm3(qx - px, qy - py, qz - pz)
    if l > 0.02 then
      local hb = cast(px, py, pz, dx, dy, dz, l)
      if hb and hb.d > 0.004 and hb.d < l - 0.004 then break end
    end
    out[#out + 1], out[#out + 2], out[#out + 3] = qx, qy, qz
    px, py, pz = qx, qy, qz
  end
  return #out > 0 and out or nil
end

-- THE DRAPE. From the sheave (`G` the ground point, `u` up, `out` the boom's
-- way, all body-relative), the line falls straight down; where it meets rock
-- facing up it lies there (grounded), where it meets a face it runs down the
-- face in `step`s, and where the face falls away it hangs free again. `cast`
-- (x,y,z, dx,dy,dz, max) → { x,y,z, nx,ny,nz, d } | nil [, "unknown"]
-- (body-relative). → L (finished), or nil and why ("unknown": the ground
-- there isn't made yet — ask again later).
FACE_BACK = 0.6   -- m: how far off a face a step's end looks back for it
-- Ground facing up under the line at (x,y,z): does it carry on LEDGE m out
-- the way away from the wall (a)? → nil (it holds the line), the distance
-- out to its lip (it doesn't), or "unknown".
LEDGE = 0.4
function ledgeLip(x, y, z, ax, ay, az, u, cast)
  local function under(k)
    local qx, qy, qz = x + ax * k + u[1] * 0.25, y + ay * k + u[2] * 0.25, z + az * k + u[3] * 0.25
    local h, why = cast(qx, qy, qz, -u[1], -u[2], -u[3], 0.6)
    if why == "unknown" then return "unknown" end
    return h ~= nil
  end
  local far = under(LEDGE)
  if far == "unknown" then return "unknown" end
  if far then return nil end
  local lo, hi = 0, LEDGE
  for _ = 1, 5 do
    local m = (lo + hi) / 2
    local on = under(m)
    if on == "unknown" then return "unknown" end
    if on then lo = m else hi = m end
  end
  return math.max(0.03, hi)
end
function buildLayout(G, u, out, length, cast)
  local ux, uy, uz = u[1], u[2], u[3]
  local ox, oy, oz = out[1], out[2], out[3]
  local R2 = ROPE.radius + ROPE.gap
  local cx = G[1] + ux * ROPE.drop_y + ox * ROPE.drop_out
  local cy = G[2] + uy * ROPE.drop_y + oy * ROPE.drop_out
  local cz = G[3] + uz * ROPE.drop_y + oz * ROPE.drop_out
  local Pp, A = { cx, cy, cz }, { ox, oy, oz }
  local ax, ay, az = ox, oy, oz
  local function push(x, y, z)
    Pp[#Pp + 1], Pp[#Pp + 2], Pp[#Pp + 3] = x, y, z
    A[#A + 1], A[#A + 2], A[#A + 3] = ax, ay, az
  end
  local left = length
  local grounded = false
  for _ = 1, 80 do
    if left <= 0.02 then break end
    local h, why = cast(cx, cy, cz, -ux, -uy, -uz, left)
    if why == "unknown" then return nil, "unknown" end
    if not h then
      push(cx - ux * left, cy - uy * left, cz - uz * left)
      left = 0
      break
    end
    local nx, ny, nz = h.nx, h.ny, h.nz
    local px, py, pz = h.x + nx * R2, h.y + ny * R2, h.z + nz * R2
    local seg = len3(px - cx, py - cy, pz - cz)
    local hx, hy, hz = horiz(nx, ny, nz, ux, uy, uz)
    if hx then ax, ay, az = hx, hy, hz end
    push(px, py, pz)
    left = left - seg
    local nu = nx * ux + ny * uy + nz * uz
    if nu >= ROPE.floor then
      -- ground facing up: it holds the line only if it carries on beyond
      -- it (a boulder's top or a narrow ledge in a shaft does not: the
      -- line runs over its lip, away from the wall, and falls on)
      local lip = ledgeLip(px, py, pz, ax, ay, az, u, cast)
      if lip == "unknown" then return nil, "unknown" end
      if not lip then grounded = true break end
      local lx, ly, lz = px + ax * lip, py + ay * lip, pz + az * lip
      push(lx, ly, lz)
      left = left - lip
      cx, cy, cz = lx + ax * 0.04, ly + ay * 0.04, lz + az * 0.04
    else
      -- a face: down along it (−u with its normal part taken out)
      local tx, ty, tz, tl = norm3(-ux + nx * nu, -uy + ny * nu, -uz + nz * nu)
      if tl < 0.05 then grounded = true break end
      local stp = min(left, ROPE.step)
      if stp <= 0.02 then break end
      local h2, w2 = cast(px + nx * 0.02, py + ny * 0.02, pz + nz * 0.02, tx, ty, tz, stp)
      if w2 == "unknown" then return nil, "unknown" end
      local qx, qy, qz
      local hq = h2
      if h2 then
        -- a face that turns toward the line (concave) or a ledge: it meets it
        qx, qy, qz = h2.x + h2.nx * R2, h2.y + h2.ny * R2, h2.z + h2.nz * R2
      else
        -- the face under the step's end, looked for back along the face's
        -- normal: a face that rounds away (convex) still carries the line (a
        -- loaded rope lies on it; the step's end was out in the air, and the
        -- line was drawn in a sawtooth standing off the rock)
        local ex, ey, ez = px + tx * stp, py + ty * stp, pz + tz * stp
        local h3, w3 = cast(ex + nx * FACE_BACK, ey + ny * FACE_BACK, ez + nz * FACE_BACK, -nx, -ny, -nz, 2 * FACE_BACK)
        if w3 == "unknown" then return nil, "unknown" end
        if h3 and h3.d > 0.01 and (h3.nx * nx + h3.ny * ny + h3.nz * nz) > 0.3 then
          hq = h3
          qx, qy, qz = h3.x + h3.nx * R2, h3.y + h3.ny * R2, h3.z + h3.nz * R2
        end
      end
      if qx then
        local hx2, hy2, hz2 = horiz(hq.nx, hq.ny, hq.nz, ux, uy, uz)
        if hx2 then ax, ay, az = hx2, hy2, hz2 end
        local seg2 = len3(qx - px, qy - py, qz - pz)
        push(qx, qy, qz)
        left = left - seg2
        if (hq.nx * ux + hq.ny * uy + hq.nz * uz) >= ROPE.floor then grounded = true break end
        nx, ny, nz = hq.nx, hq.ny, hq.nz
        cx, cy, cz = qx + nx * 0.02, qy + ny * 0.02, qz + nz * 0.02
      else
        -- the face falls away under the step (an overhang, the lip of a
        -- drop): the line leaves it here and hangs straight down
        cx, cy, cz = px + nx * 0.03, py + ny * 0.03, pz + nz * 0.03
      end
    end
  end
  -- the chords between the points cleared of the rock they cut through
  local added, wc = clearPath(Pp, A, cast, R2, u)
  if wc == "unknown" then return nil, "unknown" end
  local L = finish({ p = Pp, a = A, u = { ux, uy, uz }, g = grounded, len = length, out = { ox, oy, oz } })
  L.cleared = added
  -- THE TAIL: a line that lies on the ground ends in a short run across it
  -- (rope.lua draws it), laid on the ground there, not on a plane through
  -- the end (on a slope or a rough floor that plane ran through the rock)
  if grounded then L.tail = layTail(L, cast, R2) end
  -- the wall for the feet, every metre: along −away from the line
  local wd = {}
  for k = 0, floor(L.total) do
    local x, y, z, bx, by, bz = at(L, k)
    local h = cast(x, y, z, -bx, -by, -bz, ROPE.wall_max)
    wd[k + 1] = h and h.d or -1
  end
  L.wd = wd
  return L
end

-- THE DIG GUARD. The ground under a planted davit can't be dug (base_facilities
-- setGuards / digClamp, which the laser, craters, the drill and the surveyor
-- ask): a box round its plate and its two staked back stays (tools/gen_rope.py:
-- the plate at the mast, the stakes 0.42 m to each side and 0.52 m back, +Z
-- toward the planter), DIG_GUARD.depth under the ground. The box is in the body's
-- frame from the record (ground point, facing): body-relative, never world.
-- Davits are grouped by body and a DIG_GUARD.cell grid, one guard owner per
-- group ("rope:<body>:<cell>"), so a dig far from any davit costs one sphere
-- test a group, and a dig near a few tests only those few boxes.
DIG_GUARD = { side = 0.60, back = 0.70, front = 0.45, depth = 1.1, height = 0.5, cell = 250,
              why = "The rope davit's footing — can't dig under it" }

function guardBox(e)
  local ux, uy, uz, fx, fy, fz = facing(e.x, e.y, e.z, e.fx or 0, e.fy or 0, e.fz or 0)
  local mid = (DIG_GUARD.back - DIG_GUARD.front) / 2
  -- side = up × toward-the-planter
  local sx, sy, sz = norm3(uy * fz - uz * fy, uz * fx - ux * fz, ux * fy - uy * fx)
  return { c = { x = e.x + fx * mid, y = e.y + fy * mid, z = e.z + fz * mid },
           t = { x = sx, y = sy, z = sz }, up = { x = ux, y = uy, z = uz }, n = { x = fx, y = fy, z = fz },
           ht = DIG_GUARD.side, hn = (DIG_GUARD.back + DIG_GUARD.front) / 2, lo = -DIG_GUARD.depth, hi = DIG_GUARD.height,
           why = DIG_GUARD.why }
end

-- The guard owners for a list of davit records { b, x, y, z, fx, fy, fz }:
-- → { [owner] = { body = name, list = { box … } } }
function guardGroups(recs)
  local out = {}
  local C = DIG_GUARD.cell
  for _, e in ipairs(recs) do
    if e.b and e.x and e.y and e.z then
      local key = string.format("rope:%s:%d:%d:%d", e.b, floor(e.x / C), floor(e.y / C), floor(e.z / C))
      local g = out[key]
      if not g then g = { body = e.b, list = {} }; out[key] = g end
      g.list[#g.list + 1] = guardBox(e)
    end
  end
  return out
end

-- The save's copy (plain numbers; save.set keeps four tables deep). v 2: laid
-- on what the player sees (solid_cast) with the chords cleared; a v 1 line,
-- laid on the field alone, is laid again once the crew comes near.
SAVE_V = 2
local function r4(v) return floor(v * 1e4 + 0.5) / 1e4 end
function toSave(L)
  local p, a, wd = {}, {}, {}
  for i, v in ipairs(L.p) do p[i] = r4(v) end
  for i, v in ipairs(L.a) do a[i] = r4(v) end
  for i, v in ipairs(L.wd or {}) do wd[i] = r4(v) end
  local tl = nil
  if L.tail then tl = {}; for i, v in ipairs(L.tail) do tl[i] = r4(v) end end
  return { v = SAVE_V, p = p, a = a, wd = wd, tl = tl, u = { L.u[1], L.u[2], L.u[3] }, g = L.g and 1 or 0, len = L.len,
           out = L.out and { L.out[1], L.out[2], L.out[3] } or nil }
end
function fromSave(t)
  if type(t) ~= "table" or type(t.p) ~= "table" or #t.p < 6 or type(t.u) ~= "table" then return nil end
  local L = { p = {}, a = {}, wd = {}, u = { t.u[1], t.u[2], t.u[3] }, g = t.g == 1 or t.g == true,
              len = t.len or ROPE.length, out = t.out }
  for i, v in ipairs(t.p) do L.p[i] = v end
  for i, v in ipairs(t.a or {}) do L.a[i] = v end
  for i, v in ipairs(t.wd or {}) do L.wd[i] = v end
  if type(t.tl) == "table" and #t.tl >= 3 then L.tail = {}; for i, v in ipairs(t.tl) do L.tail[i] = v end end
  if #L.a ~= #L.p then return nil end
  return finish(L)
end

-- ══ the engine side ════════════════════════════════════════════════════════

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not (r and r.valid ~= false) then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function astro() return find and find("Astronaut") or nil end
local function now() return time or 0 end

local layouts = {}     -- id → finished layout
local retry = {}       -- id → when a layout was last tried
version = 0            -- bumps when a layout is made or dropped (rope.lua rebuilds)

local function dep_entry(id)
  local dep = ref("deployables")
  local e = dep and dep.get and dep.get(id)
  if e and e.k == "rope" then return e end
  return nil
end

-- A ray against the ground's own field, body-relative. terrain.raycast
-- first; where it answers "air" the ray is sphere-traced on terrain.query as
-- well (the same field the walker's floor and the probes stand on): on engine
-- 0.117.1-dev.1415 a raycast down a freshly dug pit was seen to miss its floor
-- and the line hung 30 m down through the rock. → { x,y,z, nx,ny,nz, d } |
-- nil [, "unknown"]
castMisses = 0   -- probes: rays the raycast missed and the trace found
function field_cast(b, x, y, z, dx, dy, dz, mx)
  local ox, oy, oz = b.x + x, b.y + y, b.z + z
  local h, why = terrain.raycast(vec3(ox, oy, oz), vec3(dx, dy, dz), mx)
  if h then
    if h.exact == false then return nil, "unknown" end
    local n = h.normal
    return { x = h.pos.x - b.x, y = h.pos.y - b.y, z = h.pos.z - b.z, nx = n.x, ny = n.y, nz = n.z, d = h.distance }
  end
  if why == "unknown" then return nil, "unknown" end
  if not terrain.query then return nil, why end
  local t = 0
  local hit = false
  for _ = 1, 400 do
    local q = terrain.query(ox + dx * t, oy + dy * t, oz + dz * t)
    if not q then return nil, "air" end
    if q < 0.02 then hit = true break end
    t = t + max(q * 0.8, 0.03)
    if t >= mx then break end
  end
  if not hit then return nil, "air" end
  local px, py, pz = ox + dx * t, oy + dy * t, oz + dz * t
  local e = 0.15
  local gx = terrain.query(px + e, py, pz) - terrain.query(px - e, py, pz)
  local gy = terrain.query(px, py + e, pz) - terrain.query(px, py - e, pz)
  local gz = terrain.query(px, py, pz + e) - terrain.query(px, py, pz - e)
  local nx, ny, nz, nl = norm3(gx, gy, gz)
  if nl < 1e-9 then nx, ny, nz = -dx, -dy, -dz end
  castMisses = castMisses + 1
  return { x = px - b.x, y = py - b.y, z = pz - b.z, nx = nx, ny = ny, nz = nz, d = t }
end

-- WHAT THE PLAYER SEES (playtest 2026-11-11: "ropes can clip through walls
-- (seems like it's not following the meshed terrain, more like the SDF
-- field)"). The ground drawn is the mesh the field is cut into, and the
-- colliders are that mesh; kit pieces and props are colliders of their own,
-- which the field knows nothing of. So the line is laid by the physics ray
-- (raycast: the terrain's meshed colliders, every static collider), and the
-- field answers only where that ray has nothing there yet: ground whose
-- collider is not built (the field's hit SOLID.tol nearer than the mesh's, or
-- the mesh's missing), and "unknown" ground still holds the layout back.
-- Moving things (a craft not anchored, a body on the move) and the crew are
-- passed through: the line is laid once and kept, and they move on.
SOLID = { tol = 0.5, passes = 4 }
solidStats = { rays = 0, mesh = 0, field = 0, through = 0, nearer = 0, dmax = 0 }   -- probes
local function moving(n)
  -- a craft (an assembly that is not anchored, as a base's kit structure is),
  -- or a loose body on the move; a crate at rest is ground for the line
  local k, first = 0, n
  while n and n.valid ~= false and k < 8 do
    local inf = assembly and assembly.info and assembly.info(n)
    if inf and inf.mass then return not inf.anchored end
    n = n.parent
    k = k + 1
  end
  local v = first and first.valid ~= false and first.vel
  return v ~= nil and (v.x * v.x + v.y * v.y + v.z * v.z) > 0.04
end
function solid_cast(b, x, y, z, dx, dy, dz, mx, ign)
  local fh, why = field_cast(b, x, y, z, dx, dy, dz, mx)
  if why == "unknown" then return nil, "unknown" end
  if not raycast then return fh, why end
  solidStats.rays = solidStats.rays + 1
  local ox, oy, oz = b.x + x, b.y + y, b.z + z
  local opts = (ign and #ign > 0) and { ignore = ign, ignoreChildren = true } or nil
  local t0, ph, pd = 0, nil, nil
  for _ = 1, SOLID.passes do
    local ok, h = pcall(raycast, ox + dx * t0, oy + dy * t0, oz + dz * t0, dx, dy, dz, mx - t0, opts)
    if not ok or not h then break end
    local d = t0 + (h.distance or 0)
    if h.node and moving(h.node) then
      solidStats.through = solidStats.through + 1
      t0 = d + 0.05
      if t0 >= mx then break end
    else
      ph, pd = h, d
      break
    end
  end
  if ph and fh then
    local e = fh.d - pd
    if abs(e) > solidStats.dmax then solidStats.dmax = abs(e) end
    if e > 0.02 then solidStats.nearer = solidStats.nearer + 1 end
  end
  -- (a ray starting a hair inside the field, outside the mesh — the mesh cuts
  -- the field's corners — has the field's hit at its start: the mesh's then)
  if ph and (not fh or pd <= fh.d + SOLID.tol or fh.d < 0.02) then
    solidStats.mesh = solidStats.mesh + 1
    local nx, ny, nz, nl = norm3(ph.nx or 0, ph.ny or 0, ph.nz or 0)
    if nl < 1e-6 then nx, ny, nz = -dx, -dy, -dz end
    return { x = ph.x - b.x, y = ph.y - b.y, z = ph.z - b.z, nx = nx, ny = ny, nz = nz, d = pd, mesh = true }
  end
  if fh then solidStats.field = solidStats.field + 1 end
  return fh, why
end

-- The cast a layout of rope `id` is laid with: the physics ray past the
-- davit itself and the crew (solid_cast), body-relative. nil until the
-- davit's node is out (its own box would read as a wall beside the sheave).
local function cast_for(id, b)
  local dep = ref("deployables")
  local pn = dep and dep.nodeOf and dep.nodeOf(id)
  if not pn then return nil end
  local ign = { pn }
  local a = astro()
  if a and a.valid ~= false then ign[2] = a end
  return function(x, y, z, dx, dy, dz, mx) return solid_cast(b, x, y, z, dx, dy, dz, mx, ign) end
end

-- A layout worked out now from what is there. → L | nil, why
local function lay(id)
  local e = dep_entry(id)
  if not e then return nil, "gone" end
  local b = space and space.body and space.body(e.b)
  if not (b and terrain and terrain.raycast) then return nil, "no ground" end
  local cast = cast_for(id, b)
  if not cast then return nil, "no davit" end
  local ux, uy, uz, fx, fy, fz = facing(e.x, e.y, e.z, e.fx or 0, e.fy or 0, e.fz or 0)
  return buildLayout({ e.x, e.y, e.z }, { ux, uy, uz }, { -fx, -fy, -fz }, ROPE.length, cast)
end

local stale = {}       -- id → true: a layout from an older save (laid on the field alone): laid again when near

-- The line's layout, from the save, or worked out now from the ground (and
-- kept). nil while the ground there isn't made, or for no such rope.
function layoutOf(id)
  if id == nil then return nil end
  local L = layouts[id]
  if L then return L end
  if not save then return nil end
  local t = save.get("rope." .. tostring(id))
  L = fromSave(t)
  if L then
    layouts[id] = L
    if type(t) == "table" and (tonumber(t.v) or 1) < SAVE_V then stale[id] = true end
    return L
  end
  if now() - (retry[id] or -10) < 1.0 then return nil end
  retry[id] = now()
  L = lay(id)
  if not L then return nil end
  layouts[id] = L
  save.set("rope." .. tostring(id), toSave(L))
  version = version + 1
  if log then
    log(string.format("rope: #%d's line falls %.1f m (%s), climbable %.1f–%.1f m, %d points (%d round the rock)", id, L.total,
      L.g and "on the ground" or "hanging free", L.s_top, L.s_max, L.n, L.cleared or 0))
  end
  return L
end

-- A record gone (taken down, a revert): its layout goes from the save too.
local function prune()
  local dep = ref("deployables")
  if not (dep and dep.get) then return end
  for id in pairs(layouts) do
    if not dep_entry(id) then
      layouts[id] = nil
      if save.delete then save.delete("rope." .. tostring(id)) else save.set("rope." .. tostring(id), false) end
      version = version + 1
    end
  end
end

-- The dig guards under every davit, set again only when the records change
-- (deployables.version: a plant, a take-down, a revert, a load) or the base's
-- library is a new one (a scene load).
local guard_owners, guard_ver, guard_bf = {}, nil, nil
guardCount = 0   -- probes: davits guarded
local function sync_guards()
  local dep, bf = ref("deployables"), ref("base_facilities")
  if not (dep and dep.list and bf and bf.setGuards) then return end
  local v = dep.version
  if v == guard_ver and bf == guard_bf then return end
  guard_ver, guard_bf = v, bf
  local groups = guardGroups(dep.list("rope"))
  for owner in pairs(guard_owners) do
    if not groups[owner] then pcall(bf.setGuards, owner, nil) end
  end
  guard_owners = {}
  local n = 0
  for owner, g in pairs(groups) do
    pcall(bf.setGuards, owner, g.body, g.list)
    guard_owners[owner] = true
    n = n + #g.list
  end
  guardCount = n
end

-- For probes: forget the cached layouts (they are read from the save again).
function reloadLayouts() layouts, retry, stale = {}, {}, {}; if settleReset then settleReset() end; version = version + 1 end

local function set_kinematic(a, on)
  local getc = a and (a.getComponent or a.getcomponent)
  local rb = getc and getc(a, "RigidBody")
  if not rb then return end
  local is = rb.kinematic == true or rb.kinematic == 1
  if is ~= on then rb.kinematic = on and 1 or 0 end
end

local function crew_id()
  local c = ref("crew")
  return c and c.activeId and c.activeId() or nil
end
local function set_hold(id)
  local c = ref("crew")
  if c and c.setRopeHold then pcall(c.setRopeHold, id) end
end

local function load_kg()
  local inv = ref("inventory")
  local ok, m = false, 0
  if inv and inv.mass then ok, m = pcall(inv.mass, "astro") end
  return ROPE.body_kg + ((ok and type(m) == "number") and m or 0)
end

local function sound(path, vol, node)
  if not (audio and audio.play) then return end
  local a = node or astro()
  local o = { track = "SFX", volume = vol or 0.4, minDistance = 2, maxDistance = 30, pitch = 0.95 + math.random() * 0.1 }
  if a and a.valid ~= false then pcall(audio.play, path, a, o) else pcall(audio.play, path, o) end
end

local function caption(text)
  if not text then return end
  local fx = ref("sfx")
  if fx and fx.caption then pcall(fx.caption, text) elseif _G.caption then pcall(_G.caption, text) end
  if log then log("rope: " .. text) end
end

-- ── the climb ───────────────────────────────────────────────────────────────
-- C = { id, member, body, s, v, phase, mode = "slide" | "on" | "step",
--       t, p0, last, want, fast, pend, prev_hand, spot }
local C = nil
sim = nil              -- probes: { move = -1..1, fast = bool } in place of the keys
lastRelease = nil      -- probes: { kind, s, v, at = {x,y,z} body-relative }
strokes = 0            -- probes: ascender bites so far

function climbing() return C ~= nil end
function state()
  if not C then return nil end
  local L = layoutOf(C.id)
  return { id = C.id, mode = C.mode, s = C.s, v = C.v, s_top = L and L.s_top, s_max = L and L.s_max,
           kind = L and unclipKind(L, C.s), drop = C.drop or (L and dropAt(L, C.s)), total = L and L.total }
end

-- The way the walker faces while held: at the wall (−away).
function faceDir()
  if not C then return nil end
  local L = layoutOf(C.id)
  if not L then return nil end
  local _, _, _, ax, ay, az = at(L, C.s)
  return -ax, -ay, -az
end

function clipOn(id, s)
  if C then return false, "already on a line" end
  local pw = ref("planet_walker")
  if not (pw and pw.onFoot) then return false, "not on foot" end
  if pw.downed then return false, "out cold" end
  local c = ref("crew")
  if c and c.held and c.held() then return false, "the hands are at the work" end
  local e = dep_entry(id)
  if not e then return false, "no rope there" end
  local L = layoutOf(id)
  if not L then return false, "the line is still settling" end
  if not climbable(L) then return false, "the line lies on the ground here: set the davit at an edge" end
  local H = ref("item_hand")
  local prev = H and H.held and H.held() or nil
  C = { id = id, member = crew_id(), body = e.b, s = math.max(L.s_top, math.min(L.s_max, s or L.s_top)), v = 0,
        phase = 0, mode = "slide", t = 0, want = 0, fast = false, prev_hand = prev }
  set_hold(C.member)
  if H and H.stow and prev then pcall(H.stow) end
  -- the view swings round onto the wall: the camera behind the climber, out
  -- over the drop. (Left where it was — facing the edge from the davit — its
  -- boom ran into the ledge the climber now faces, and planet_camera hid the
  -- suit as a body it stood inside.) The player can orbit away freely after.
  local pc = ref("planet_camera")
  if pc and pc.face then
    local _, _, _, ax, ay, az = at(L, C.s)
    pcall(pc.face, -ax, -ay, -az, -0.15)
  end
  sound("audio/foley/switch_3.ogg", 0.55)
  log(string.format("rope: clipped on to #%d at %.1f m (%s)", id, C.s, C.s <= L.s_top + 0.05 and "the top" or "the line"))
  return true
end

-- E while clipped on: → the kind it will be ("top" | "bottom" | "fall").
function unclip()
  if not C then return nil end
  if C.mode ~= "on" then return nil end
  local L = layoutOf(C.id)
  local kind = L and unclipKind(L, C.s) or "fall"
  C.pend = kind
  return kind
end

-- Let go (in a tick: every write to the body is a tick's).
local function release(kind, why)
  local c = C
  if not c then return end
  C = nil
  local a = astro()
  local vel = c.vel or { 0, 0, 0 }
  if a then
    set_kinematic(a, false)
    if kind == "fall" then a.vx, a.vy, a.vz = vel[1], vel[2], vel[3] else a.vx, a.vy, a.vz = 0, 0, 0 end
  end
  set_hold(nil)
  local cr = ref("crew")
  if kind ~= "fall" and cr and cr.quietMonitors then pcall(cr.quietMonitors, 0.6) end
  if kind ~= "fall" and c.prev_hand then
    local H = ref("item_hand")
    if H and H.hold then pcall(H.hold, c.prev_hand) end
  end
  sound("audio/foley/switch_2.ogg", 0.45)
  lastRelease = { kind = kind, s = c.s, v = vel, at = c.last, why = why }
  if why then caption(why) end
  log(string.format("rope: unclipped from #%d at %.1f m — %s%s", c.id, c.s or 0, kind, why and (" (" .. why .. ")") or ""))
end

-- Where the crew stands after stepping off at the top: behind the mast, on
-- the ground (body-relative, the suit's centre).
local function step_spot(e, b)
  local ux, uy, uz, fx, fy, fz = facing(e.x, e.y, e.z, e.fx or 0, e.fy or 0, e.fz or 0)
  local sx, sy, sz = e.x + fx * ROPE.back, e.y + fy * ROPE.back, e.z + fz * ROPE.back
  if terrain and terrain.raycast then
    local h = field_cast(b, sx + ux * 2, sy + uy * 2, sz + uz * 2, -ux, -uy, -uz, 5)
    if h then sx, sy, sz = h.x, h.y, h.z end
  end
  return { sx + ux * (ROPE.foot + 0.03), sy + uy * (ROPE.foot + 0.03), sz + uz * (ROPE.foot + 0.03) }
end

local function gravity(b, x, y, z)
  local r2 = x * x + y * y + z * z
  if not (b and b.mu and r2 > 1) then return 9.8 end
  return b.mu / r2
end

function fixedUpdate(node, dt)
  if not C or not dt or dt <= 0 then return end
  local a = astro()
  local b = space.body(C.body)
  local L = layoutOf(C.id)
  local e = dep_entry(C.id)
  if not (a and b and L and e) then release("fall", "the line is gone") return end
  local pw = ref("planet_walker")
  if crew_id() ~= C.member or (pw and (pw.downed or not pw.onFoot)) then release("fall") return end
  -- (as crew_task does: the body's place read and written through node.x in
  -- the tick, against space.body() of the same tick; a tickPos write left a
  -- kinematic suit at a fixed world point while the planet moved on)
  local cur = { a.x - b.x, a.y - b.y, a.z - b.z }
  if not C.p0 then C.p0, C.last = cur, cur end
  local u = L.u
  if C.pend then
    local k = C.pend
    C.pend = nil
    if k == "top" then
      C.mode, C.t, C.p0, C.spot = "step", 0, cur, step_spot(e, b)
    else
      release(k)
      return
    end
  end
  local px, py, pz
  if C.mode == "slide" then
    C.t = C.t + dt
    local k = smooth(C.t / ROPE.slide)
    local tx, ty, tz = bodyAt(L, C.s)
    px, py, pz = C.p0[1] + (tx - C.p0[1]) * k, C.p0[2] + (ty - C.p0[2]) * k, C.p0[3] + (tz - C.p0[3]) * k
    if C.t >= ROPE.slide then C.mode = "on" end
  elseif C.mode == "step" then
    C.t = C.t + dt
    local k = smooth(C.t / ROPE.step_secs)
    local lift = 0.55 * math.sin(math.pi * k)
    local s = C.spot
    px = C.p0[1] + (s[1] - C.p0[1]) * k + u[1] * lift
    py = C.p0[2] + (s[2] - C.p0[2]) * k + u[2] * lift
    pz = C.p0[3] + (s[3] - C.p0[3]) * k + u[3] * lift
  else
    local up, down = speeds(gravity(b, cur[1], cur[2], cur[3]), load_kg(), C.fast,
      { power = P("power"), line_max = P("line_max"), down = P("down"), down_fast = P("down_fast") })
    local _, _, bit = move(C, C.want or 0, dt, up, down, L)
    if bit then
      strokes = strokes + 1
      sound(string.format("audio/foley/ratchet_%d.ogg", (strokes % 5) + 1), 0.22)
    end
    px, py, pz = bodyAt(L, C.s)
  end
  set_kinematic(a, true)
  a.x, a.y, a.z = b.x + px, b.y + py, b.z + pz
  local l = C.last
  C.vel = { (px - l[1]) / dt, (py - l[2]) / dt, (pz - l[3]) / dt }
  a.vx, a.vy, a.vz = C.vel[1], C.vel[2], C.vel[3]
  C.last = { px, py, pz }
  if C.mode == "step" and C.t >= ROPE.step_secs then
    C.vel = { 0, 0, 0 }
    release("top")
  end
end

-- ── the line settles again ──────────────────────────────────────────────────
-- (playtest 2026-11-11: "I'd like the ability to mine near my ropes and
-- they'll move to rebalance where they should be, without having to pick up
-- and replace them"). A laid line is asleep: nothing of it runs. The engine
-- keeps a FEED of the terrain edits that landed (engine card 0689,
-- terrain.editSerial / editsSince: whoever made them, a dig, a fill, a crater,
-- a drill, a scenario, a mod), each with its centre and how far it can have
-- reached (r). Every SETTLE.every s the field asks for what landed since it
-- last looked (nothing at all when the serial has not moved) and wakes the
-- lines whose path, or the ground under whose davit plate, is within
-- r + SETTLE.margin of an edit. A paint edit changes no shape and wakes
-- nothing. A caller more than the feed's 1,024 edits behind is told "too old"
-- and wakes every line once. A base's kit structure changing
-- (structures.version) wakes the lines near the crew too. A woken line near
-- the crew (SETTLE.near m) is laid again from what is there once the ground
-- has been quiet SETTLE.quiet s (no edits pending, none near it since), and
-- swapped in only if it moved; a woken line far from the crew waits until the
-- crew comes near (its colliders may not be built there). A line is also laid
-- again once when the crew first comes near it in a session (an edit made in
-- an earlier session the line missed is read then). Ground gone from under
-- the davit's plate (an edit the dig guard did not stop) drops the davit to
-- the ground below it, and the line falls with it.
-- (Until 0689 this read the field at a SIGNATURE, a point every 0.5 m along
-- one line every 0.25 s, ropebike bcb0afa.)
SETTLE = { near = 90, every = 0.25, quiet = 0.6, moved = 0.03, margin = 1.5 }
settles = 0            -- probes: lines laid again after the ground changed
settleChecks = 0       -- probes: edit-feed reads (editsSince calls) and plate reads
settleMs = 0           -- probes: the dearest check or re-lay so far (ms)
falls = 0              -- probes: davits dropped with their ground
feedWakes = 0          -- probes: lines woken by an edit in the feed
feedTooOld = 0         -- probes: times the feed answered "too old" (every line woken)
local seen = {}        -- id → true once laid again this session (or first looked at)
local woke = {}        -- id → when the line was woken (its ground changed)
local settle_t = -10
local struct_ver = nil
local edit_serial = nil   -- the feed's serial when it was last read (nil: not yet)
function settleReset() seen, woke = {}, {} end

-- Does an edit at (cx, cy, cz) (body-relative) reaching `reach` m come
-- near the line L or its plate's ground point G? The closest distance from
-- the centre to each straight piece of the line, and to G.
function editReaches(L, G, cx, cy, cz, reach)
  local r2 = reach * reach
  if G then
    local dx, dy, dz = cx - G[1], cy - G[2], cz - G[3]
    if dx * dx + dy * dy + dz * dz <= r2 then return true end
  end
  local p, n = L and L.p, L and L.n or 0
  if not p then return false end
  for i = 1, max(n - 1, 1) do
    local j = 3 * (i - 1)
    local ax, ay, az = p[j + 1], p[j + 2], p[j + 3]
    if not ax then break end
    local bx, by, bz = p[j + 4] or ax, p[j + 5] or ay, p[j + 6] or az
    local ex, ey, ez = bx - ax, by - ay, bz - az
    local ll = ex * ex + ey * ey + ez * ez
    local f = 0
    if ll > 1e-12 then
      f = ((cx - ax) * ex + (cy - ay) * ey + (cz - az) * ez) / ll
      if f < 0 then f = 0 elseif f > 1 then f = 1 end
    end
    local dx, dy, dz = cx - (ax + ex * f), cy - (ay + ey * f), cz - (az + ez * f)
    if dx * dx + dy * dy + dz * dz <= r2 then return true end
  end
  return false
end

-- How far apart two layouts are (m): the largest gap between points the same
-- arc length along each, the difference in length, 1 m if one lies on the
-- ground and the other not.
function layoutGap(A, B)
  if not (A and B) then return math.huge end
  local g = abs((A.total or 0) - (B.total or 0))
  if (A.g and true or false) ~= (B.g and true or false) then g = max(g, 1) end
  local n = max(A.n or 0, B.n or 0, 2) * 2
  local tot = min(A.total, B.total)
  for k = 0, n do
    local s = tot * k / n
    local ax, ay, az = at(A, s)
    local bx, by, bz = at(B, s)
    g = max(g, len3(ax - bx, ay - by, az - bz))
  end
  return g
end

-- The ground under the plate: the field 0.2 and 0.6 m below it (> 0.1 both:
-- air, the footing is gone). nil when the field is not known there.
local function plate_air(e, b, u)
  local q1 = terrain.query(b.x + e.x - u[1] * 0.2, b.y + e.y - u[2] * 0.2, b.z + e.z - u[3] * 0.2)
  local q2 = terrain.query(b.x + e.x - u[1] * 0.6, b.y + e.y - u[2] * 0.6, b.z + e.z - u[3] * 0.6)
  settleChecks = settleChecks + 1
  if q1 == nil or q2 == nil then return nil end
  return q1 > 0.1 and q2 > 0.1
end

-- The ground under the plate is gone: the davit drops to the ground below.
local function fall_davit(id, e, b)
  local dep = ref("deployables")
  if not (dep and dep.place and dep.remove) then return end
  local ux, uy, uz = norm3(e.x, e.y, e.z)
  local h = field_cast(b, e.x + ux * 0.5, e.y + uy * 0.5, e.z + uz * 0.5, -ux, -uy, -uz, 60)
  if C and C.id == id and release then release("fall", "the rope's footing gave way") end
  local by, name = e.by, e.n
  pcall(dep.remove, id)
  layouts[id], seen[id], woke[id], stale[id] = nil, nil, nil, nil
  if save.delete then save.delete("rope." .. tostring(id)) else save.set("rope." .. tostring(id), false) end
  version = version + 1
  falls = falls + 1
  if h then
    local nid = dep.place("rope", e.b, b.x + h.x, b.y + h.y, b.z + h.z, { by = by, name = name, fx = e.fx, fy = e.fy, fz = e.fz })
    caption("The ground gave way under the rope's davit: it fell with it")
    log(string.format("rope: #%d's footing dug away, the davit fell %.1f m (now #%s)", id, h.d - 0.5, tostring(nid)))
  else
    caption("The ground gave way under the rope's davit: it fell out of sight")
    log(string.format("rope: #%d's footing dug away, nothing under it for 60 m", id))
  end
end

-- One woken line near the crew: laid again once its ground is quiet.
local function settle_one(id, a)
  local e = dep_entry(id)
  local L = layouts[id]
  if not (e and L and e.gx) then return end
  local b = space.body(e.b)
  if not b then return end
  if len3(e.gx - a.x, e.gy - a.y, e.gz - a.z) > SETTLE.near then return end
  local w = woke[id]
  if not w or now() - w < SETTLE.quiet then return end
  if terrain.pending and terrain.pending() > 0 then return end
  seen[id] = true
  -- the plate's ground: both points under it in the air → gone
  local gone = plate_air(e, b, L.u)
  if gone == nil then return end
  if gone then fall_davit(id, e, b) return end
  local L2, why = lay(id)
  if not L2 then
    if why ~= "unknown" and why ~= "no davit" then woke[id] = nil end
    return
  end
  local was_stale = stale[id]
  woke[id], stale[id] = nil, nil
  local gap = layoutGap(L, L2)
  if gap > SETTLE.moved or was_stale then
    layouts[id] = L2
    save.set("rope." .. tostring(id), toSave(L2))
    if gap > SETTLE.moved then
      version = version + 1
      settles = settles + 1
      log(string.format("rope: #%d's ground changed: the line settled again (moved up to %.2f m; falls %.1f m, %s, %d points)",
        id, gap, L2.total, L2.g and "on the ground" or "hanging free", L2.n))
    end
  end
end

-- What landed in the ground since the feed was last read: the lines it came
-- near wake. (The centres are in the terrain node's own frame, which for a
-- planet is its body-relative frame, the frame the layouts are in: no world
-- point is kept or mixed.)
local function read_feed(list)
  if not (terrain.editSerial and terrain.editsSince) then return end
  local s = terrain.editSerial()
  if edit_serial == nil then edit_serial = s return end
  if s == edit_serial then return end
  local recs, why = terrain.editsSince(edit_serial)
  settleChecks = settleChecks + 1
  edit_serial = s
  if recs == nil then
    -- further behind than the feed keeps: every line looks again once
    feedTooOld = feedTooOld + 1
    log("rope: the terrain edit feed says " .. tostring(why) .. ": every line looks at its ground again")
    for _, e in ipairs(list) do woke[e.id] = now() end
    return
  end
  for _, r in ipairs(recs) do
    if (r.serial or 0) > edit_serial then edit_serial = r.serial end
    if r.kind ~= "paint" then
      local reach = (r.r or 0) + SETTLE.margin
      for _, e in ipairs(list) do
        local L = layouts[e.id]
        if L and (r.body == nil or e.b == nil or r.body == e.b)
          and editReaches(L, { e.x, e.y, e.z }, r.x, r.y, r.z, reach) then
          if not woke[e.id] then feedWakes = feedWakes + 1 end
          woke[e.id] = now()
        end
      end
    end
  end
end

local function settle_tick()
  if now() - settle_t < SETTLE.every then return end
  settle_t = now()
  local a = astro()
  local dep = ref("deployables")
  if not (a and dep and dep.list and terrain and terrain.query) then return end
  local list = dep.list("rope")
  if #list == 0 then return end
  local t0 = os.clock()
  read_feed(list)
  -- a kit structure changed: the lines near the crew wake
  local st = ref("structures")
  local sv = st and st.version
  if sv ~= nil and struct_ver ~= nil and sv ~= struct_ver then
    for _, e in ipairs(list) do
      if e.gx and len3(e.gx - a.x, e.gy - a.y, e.gz - a.z) < SETTLE.near then woke[e.id] = now() end
    end
  end
  struct_ver = sv
  -- one line a check: a woken line near the crew, else one first come near
  -- this session (laid again once)
  local pick, first = nil, nil
  for _, e in ipairs(list) do
    if layouts[e.id] and e.gx and len3(e.gx - a.x, e.gy - a.y, e.gz - a.z) <= SETTLE.near then
      if woke[e.id] then pick = e.id break end
      if not first and not seen[e.id] then first = e.id end
    end
  end
  if not pick and first then
    pick = first
    if not woke[pick] then woke[pick] = -10 end
  end
  if pick then settle_one(pick, a) end
  local ms = (os.clock() - t0) * 1000
  if ms > settleMs then settleMs = ms end
end

-- ── taking it down ──────────────────────────────────────────────────────────
function takeDown(id)
  if C and C.id == id then return false, "unclip first" end
  local inv, dep = ref("inventory"), ref("deployables")
  if not (inv and dep and dep.remove) then return false, "no store here" end
  if not dep_entry(id) then return false, "no rope there" end
  local room, why = inv.roomForItem("astro", "rope", 1)
  if (room or 0) < 1 then return false, why or "no room in the pack" end
  if inv.addItem("astro", "rope", 1) < 1 then return false, "no room in the pack" end
  local ok = pcall(dep.remove, id)
  if not ok then inv.removeItem("astro", "rope", 1) return false, "it wouldn't come up" end
  layouts[id] = nil
  if save.delete then save.delete("rope." .. tostring(id)) else save.set("rope." .. tostring(id), false) end
  version = version + 1
  sound("audio/foley/latch_clunk.ogg", 0.6)
  caption("Rope Kit taken down and packed")
  log(string.format("rope: #%d taken down, back in the pack", id))
  return true
end

-- ── E and the keys ──────────────────────────────────────────────────────────
local function interact_pressed()
  if input.pressed("e") then return true end
  return input.justPressed ~= nil and input.justPressed("Interact") == true
end
local function interact_held()
  if input.key("e") == true then return true end
  return input.action ~= nil and input.action("Interact") == true
end

local function blocked()
  for _, k in ipairs({ "pause_menu", "inventory_panel" }) do local s = ref(k); if s and s.open then return true end end
  for _, k in ipairs({ "facility_menu", "orbit_map", "context_menu", "ops_board" }) do
    local s = ref(k)
    if s and s.isOpen and s.isOpen() then return true end
  end
  local pc = ref("planet_camera")
  if pc and pc.freecam == true then return true end
  return false
end
-- Someone else's E (a door, a crate, the repair bay)?
local function e_elsewhere()
  local fm = ref("facility_menu")
  if fm and fm.prompting and fm.prompting() then return true end
  local sv = ref("salvage")
  if sv and sv.prompting and sv.prompting() then return true end
  return false
end

local near = nil       -- { id, kind = "pylon" | "rope", s, d, L }
local near_t = -10
local eh = nil         -- E held at a davit: { id, t0 }
promptText = nil       -- what the tag under the crosshair says (probes)
local readout = nil

function prompting() return near ~= nil or C ~= nil end

local function find_near(a)
  local dep = ref("deployables")
  if not (dep and dep.list) then return nil end
  local dom = space.dominant and space.dominant(a.x, a.y, a.z)
  local pylon, rope = nil, nil
  for _, e in ipairs(dep.list("rope")) do
    if e.b == dom and e.gx and len3(e.gx - a.x, e.gy - a.y, e.gz - a.z) < 45 then
      local b = space.body(e.b)
      local L = layoutOf(e.id)
      local x, y, z = a.x - b.x, a.y - b.y, a.z - b.z
      local ux, uy, uz = norm3(e.x, e.y, e.z)
      local mx, my, mz = e.x + ux * ROPE.origin, e.y + uy * ROPE.origin, e.z + uz * ROPE.origin
      local dp = len3(x - mx, y - my, z - mz)
      if dp < ROPE.pylon_reach and (not pylon or dp < pylon.d) then
        pylon = { id = e.id, kind = "pylon", d = dp, L = L }
      end
      if L then
        local s, d = nearestS(L, x, y, z)
        if s and d < ROPE.clip_reach and (not rope or d < rope.d) then
          rope = { id = e.id, kind = "rope", s = s, d = d, L = L }
        end
      end
    end
  end
  return pylon or rope
end

local function fmt_m(d) return string.format(d < 10 and "%.1f m" or "%.0f m", d) end

-- ONE LIBRARY: a second RopeLib (a spawn racing another) stands down; asked
-- once a second (findScripts walks the scene).
local sole_t, sole_ok = -10, true
local prune_t = -10
local function sole(node)
  if not findScripts then return true end
  if now() - sole_t < 1.0 then return sole_ok end
  sole_t = now()
  local all = findScripts("rope_climb") or {}
  sole_ok = #all <= 1 or all[1].node == nil or all[1].node.id == node.id
  return sole_ok
end

function update(node, dt)
  if not sole(node) then
    if C == nil then node:destroy() end
    return
  end
  settle_tick()
  if now() - prune_t > 1.0 then
    prune_t = now(); prune(); sync_guards()
  elseif guard_ver ~= nil then
    -- a plant or a take-down is guarded that frame
    local dep = ref("deployables")
    if dep and dep.version ~= guard_ver then sync_guards() end
  end
  promptText, readout = nil, nil
  local pw = ref("planet_walker")
  local a = astro()
  if C then
    local L = layoutOf(C.id)
    if sim then
      C.want, C.fast = sim.move or 0, sim.fast == true
    elseif blocked() then
      C.want, C.fast = 0, false
    else
      local w = 0
      if input.key("w") then w = w + 1 end
      if input.key("s") then w = w - 1 end
      C.want, C.fast = w, input.key("shift") == true
      if interact_pressed() then unclip() end
    end
    -- the hands are on the line: nothing else in them
    local H = ref("item_hand")
    if H and H.held and H.held() and H.stow then pcall(H.stow) end
    if L then
      local kind = unclipKind(L, C.s)
      -- the drop under the soles, from the ground there (the line's own end
      -- can lie lower than the ground under a suit hanging out from it)
      if now() - (C.drop_t or -10) > 0.25 then
        C.drop_t = now()
        local b = space.body(C.body)
        local bx, by, bz = bodyAt(L, C.s)
        local u = L.u
        local h = b and terrain and terrain.raycast and field_cast(b, bx - u[1] * ROPE.foot, by - u[2] * ROPE.foot,
          bz - u[3] * ROPE.foot, -u[1], -u[2], -u[3], 60)
        C.drop = h and h.d or nil
      end
      local drop = C.drop or dropAt(L, C.s)
      if C.mode ~= "on" then
        promptText = C.mode == "step" and "stepping off…" or "clipping on…"
      elseif kind == "top" then
        promptText = "E   step off onto the ledge  ·  S   lower away"
      elseif kind == "bottom" then
        promptText = "E   unclip  ·  W   climb"
      else
        local fall = drop and string.format("a %s fall", fmt_m(drop)) or "a long fall: the line ends in the air"
        promptText = string.format("W   climb  ·  S   lower away (SHIFT fast)  ·  E   let go — %s", fall)
      end
      local down = C.s - L.s_top
      readout = string.format("ROPE  %s down  ·  %s", fmt_m(max(0, down)),
        drop and (fmt_m(drop) .. " to the ground") or (fmt_m(L.total - C.s) .. " of line left"))
      if abs(C.v) > 0.05 then
        readout = readout .. string.format("  ·  %s %.1f m/s", C.v < 0 and "▲" or "▼", abs(C.v))
      end
    end
    near, eh = nil, nil
    return
  end
  if not (a and pw and pw.onFoot) or pw.downed or blocked() or e_elsewhere() then near, eh = nil, nil return end
  if now() - near_t > 0.1 then
    near_t = now()
    near = find_near(a)
  end
  if not near then eh = nil return end
  local pressed = interact_pressed()
  if near.kind == "pylon" then
    local L = near.L
    local can = climbable(L)
    if pressed then eh = { id = near.id, t0 = now() } end
    if eh and eh.id == near.id then
      local held_for = now() - eh.t0
      if interact_held() then
        if held_for >= ROPE.take_secs then
          local ok, why = takeDown(near.id)
          if not ok then caption(why) end
          eh, near = nil, nil
          return
        end
        if held_for > ROPE.tap then
          promptText = string.format("taking down the rope…  %d%%", floor(100 * held_for / ROPE.take_secs))
          return
        end
      else
        if held_for < ROPE.tap and can then
          local ok, why = clipOn(near.id, L.s_top)
          if not ok then caption(why) end
        elseif held_for < ROPE.tap and L and not can then
          caption("the line lies on the ground here: set the davit at an edge")
        end
        eh = nil
      end
    end
    if can then
      local drop = dropAt(L, L.s_top)
      promptText = string.format("E   clip on and go over the edge%s  ·  hold E   take the rope down",
        drop and string.format(" (%s down)", fmt_m(drop + ROPE.foot)) or "")
    elseif L then
      promptText = "the line lies on the ground: set the davit at an edge  ·  hold E   take the rope down"
    else
      promptText = "hold E   take the rope down"
    end
  else
    if pressed then
      local ok, why = clipOn(near.id, near.s)
      if not ok then caption(why) end
      return
    end
    promptText = "E   clip on to the rope"
  end
end

-- ── the pose (lateUpdate: drawn poses) and the tag ─────────────────────────
local model_n, anim_n = nil, nil
local function model()
  local a = astro()
  if not a then return nil end
  if not (model_n and model_n.valid) then
    model_n, anim_n = nil, nil
    for _, c in ipairs(a.children and a:children() or {}) do if c.name == "AstroModel" then model_n = c end end
  end
  if model_n and not anim_n and model_n.animator then anim_n = model_n:animator() end
  return model_n, anim_n
end

poseInfo = nil   -- probes: { gripR/gripL (the fists' miss off the line, m), curlR/curlL, feet (on the wall?), wall, lean, lead }

-- THE GRIP. Both fists closed round the line, thumbs up, the right hand above
-- the left: each hand to the right / left of the rope, its fingers reaching
-- forward round it toward the wall, the palm on the rope. The rig's hand
-- (models/astronaut): +Y wrist → knuckles, +Z the knuckle line toward the
-- index (the thumb's side), the palm −X on the right hand and +X on the left;
-- the fingers curl about Z (GRIP.curl1/curl2, signed per hand). `reach` places the
-- WRIST, so the fist's centre — GRIP.into of the way to the knuckles and
-- GRIP.palm off the palm — is measured from the bones once the hand is
-- placed and turned, and the wrist moved by the miss (a second reach, the
-- same frame: nothing kept).
GRIP = { into = 0.85, palm = 0.022, curl1 = 1.25, curl2 = 1.15, thumb = 0.55, upper = 0.02, lower = 0.30,
         lean_wall = 0.30, lean_free = 0.06, leg = 0.80, hip = 0.10, sole = 0.10, bend = 0.08 }

local function bw(an, bone)
  local ok, p = pcall(an.boneWorld, an, bone)
  if ok and p and p.x then return p end
  return nil
end

-- The fist's centre from the bones (world), and its palm's way.
local function fist(an, nm, sg)
  local H, F1, T1 = bw(an, "Hand." .. nm), bw(an, "Fingers1." .. nm), bw(an, "Thumb1." .. nm)
  if not (H and F1 and T1) then return nil end
  local yx, yy, yz, yl = norm3(F1.x - H.x, F1.y - H.y, F1.z - H.z)
  if yl < 1e-4 then return nil end
  local tx, ty, tz = T1.x - H.x, T1.y - H.y, T1.z - H.z
  local d = tx * yx + ty * yy + tz * yz
  local zx, zy, zz = norm3(tx - yx * d, ty - yy * d, tz - yz * d)
  -- X = Y × Z; the palm is −X on the right hand, +X on the left
  local px, py, pz = yy * zz - yz * zy, yz * zx - yx * zz, yx * zy - yy * zx
  px, py, pz = -sg * px, -sg * py, -sg * pz
  local k = GRIP.into * yl
  return vec3(H.x + yx * k + px * GRIP.palm, H.y + yy * k + py * GRIP.palm, H.z + yz * k + pz * GRIP.palm), H,
         { px, py, pz }
end

-- One hand onto the line at `p` (world vec3): curl, reach, turn, measure,
-- reach again by the miss. → the fist's miss from the line (m), first and last.
local function grip(an, nm, sg, p, pole, w, ax, ay, az, sx, sy, sz, ux, uy, uz)
  local hand = "Hand." .. nm
  -- a fist (bone writes run before the reaches)
  pcall(an.addBoneRot, an, "Fingers1." .. nm, 0, 0, sg * GRIP.curl1, w)
  pcall(an.addBoneRot, an, "Fingers2." .. nm, 0, 0, sg * GRIP.curl2, w)
  pcall(an.addBoneRot, an, "Thumb1." .. nm, 0, 0, sg * GRIP.thumb, w)
  -- first guess: the wrist behind the rope (toward the body) and to its side
  local g = vec3(p.x + ax * 0.09 + sx * sg * 0.03, p.y + ay * 0.09 + sy * sg * 0.03, p.z + az * 0.09 + sz * sg * 0.03)
  local function turn(at)
    -- the fingers forward round the rope (toward the wall), the knuckle line up it
    pcall(an.lookAt, an, { hand }, vec3(at.x - ax, at.y - ay, at.z - az), { axis = vec3(0, 1, 0), limit = 170, weight = w })
    pcall(an.lookAt, an, { hand }, vec3(at.x + ux, at.y + uy, at.z + uz), { axis = vec3(0, 0, 1), limit = 170, weight = w })
  end
  pcall(an.reach, an, hand, g, { pole = pole, weight = w })
  if an.lookAt then turn(g) end
  local c = fist(an, nm, sg)
  if not c then return nil end
  local e0 = len3(c.x - p.x, c.y - p.y, c.z - p.z)
  local g2 = vec3(g.x + (p.x - c.x) * w, g.y + (p.y - c.y) * w, g.z + (p.z - c.z) * w)
  pcall(an.reach, an, hand, g2, { pole = pole, weight = w })
  if an.lookAt then turn(g2) end
  local c2, _, palm = fist(an, nm, sg)
  -- (probes) how far the fingers close toward the palm: + curled, − bent back
  local F1, F2 = bw(an, "Fingers1." .. nm), bw(an, "Fingers2." .. nm)
  local cu = nil
  if palm and F1 and F2 then
    local fx, fy, fz = norm3(F2.x - F1.x, F2.y - F1.y, F2.z - F1.z)
    cu = fx * palm[1] + fy * palm[2] + fz * palm[3]
  end
  return e0, c2 and len3(c2.x - p.x, c2.y - p.y, c2.z - p.z) or nil, cu
end

local function pose(dt)
  local L = layoutOf(C.id)
  local m, an = model()
  if not (L and m and an and an.reach) then return end
  -- the planet's drawn place: the davit's drawn pose less its local offset
  local dep = ref("deployables")
  local pn = dep and dep.nodeOf and dep.nodeOf(C.id)
  local ox, oy, oz
  if pn and pn.valid ~= false and pn.worldPos then
    local wp = pn.worldPos
    ox, oy, oz = wp.x - pn.x, wp.y - pn.y, wp.z - pn.z
  else
    local b = space.body(C.body)
    if not b then return end
    ox, oy, oz = b.x, b.y, b.z
  end
  local w = 1
  if C.mode == "slide" then w = smooth(C.t / ROPE.slide) elseif C.mode == "step" then w = 1 - smooth(C.t / ROPE.step_secs) end
  if w <= 0.01 then return end
  local u = L.u
  local s = C.s
  local sw = 0.06 * math.sin(2 * math.pi * (C.phase or 0))
  local W = function(x, y, z) return vec3(ox + x, oy + y, oz + z) end
  local _, _, _, ax, ay, az = at(L, s)
  -- the side (right as the crew faces the wall): up × away
  local sx, sy, sz = norm3(u[2] * az - u[3] * ay, u[3] * ax - u[1] * az, u[1] * ay - u[2] * ax)
  local bx, by, bz = bodyAt(L, s)
  -- the feet: on the wall where there is one in reach, else hanging
  -- (the legs near straight: the ankles a leg's length from the hips, which
  -- are GRIP.hip under the suit's centre, as low on the wall as that puts them)
  local fs = s + ROPE.hang + 0.55
  local wd = wallSmooth(L, fs)
  if wd and wd < ROPE.feet_max then
    local h = ROPE.away + wd - GRIP.sole
    fs = s + ROPE.hang + GRIP.hip + sqrt(max(0.25 * 0.25, GRIP.leg * GRIP.leg - h * h))
    wd = wallSmooth(L, fs) or wd
  end
  local on_wall = wd ~= nil and wd < ROPE.feet_max and C.s < L.s_max - 0.05
  local free = not on_wall and C.s < L.s_max - 0.05
  -- the body: leant back off the line, legs out to the wall (an L: the
  -- harness takes the weight, the soles flat on the rock); hanging free,
  -- nearly plumb. (Back is the rig's root: the bone writes come first.)
  local lean = on_wall and GRIP.lean_wall or (free and GRIP.lean_free or 0)
  C.lean = (C.lean or lean) + (lean - (C.lean or lean)) * (1 - math.exp(-6 * (dt or 0.016)))
  if C.lean > 0.005 then pcall(an.addBoneRot, an, "Back", 0, -C.lean * w, 0, w) end
  -- the hands: the right above, the left below, fists on the line
  local hx, hy, hz = at(L, s - GRIP.upper - sw)
  local lx, ly, lz = at(L, s + GRIP.lower + sw)
  -- where the line bends over a lip under the upper hand, the rope between
  -- the fists is taut off the rock (the climber's weight): the lower fist
  -- stays within GRIP.bend of plumb under the upper one, never out of reach
  do
    local dx, dy, dz = lx - hx, ly - hy, lz - hz
    local d = dx * u[1] + dy * u[2] + dz * u[3]
    dx, dy, dz = dx - u[1] * d, dy - u[2] * d, dz - u[3] * d
    local l = len3(dx, dy, dz)
    if l > GRIP.bend then
      local k = 1 - GRIP.bend / l
      lx, ly, lz = lx - dx * k, ly - dy * k, lz - dz * k
    end
  end
  local elbow = function(sg) return W(bx + sx * 0.45 * sg - u[1] * 0.25 + ax * 0.05, by + sy * 0.45 * sg - u[2] * 0.25 + ay * 0.05,
                                      bz + sz * 0.45 * sg - u[3] * 0.25 + az * 0.05) end
  local r0, r1, rc = grip(an, "Right", 1, W(hx, hy, hz), elbow(1), w, ax, ay, az, sx, sy, sz, u[1], u[2], u[3])
  local l0, l1, lc = grip(an, "Left", -1, W(lx, ly, lz), elbow(-1), w, ax, ay, az, sx, sy, sz, u[1], u[2], u[3])
  if on_wall then
    local fx, fy, fz, fax, fay, faz = at(L, fs)
    -- the ankles a sole's depth off the rock, shoulder-width apart
    local px, py, pz = fx - fax * (wd - GRIP.sole), fy - fay * (wd - GRIP.sole), fz - faz * (wd - GRIP.sole)
    for _, sg in ipairs({ -1, 1 }) do
      local t = W(px + sx * 0.17 * sg, py + sy * 0.17 * sg, pz + sz * 0.17 * sg)
      local pole = W(px + sx * 0.22 * sg + fax * 0.7 + u[1] * 0.35, py + sy * 0.22 * sg + fay * 0.7 + u[2] * 0.35,
                     pz + sz * 0.22 * sg + faz * 0.7 + u[3] * 0.35)
      pcall(an.reach, an, sg < 0 and "Foot.Left" or "Foot.Right", t, { pole = pole, weight = w })
    end
  elseif free then
    -- hanging free: knees a little bent, toes toward the line
    for _, sg in ipairs({ -1, 1 }) do
      local t = W(bx - u[1] * 0.92 - ax * 0.10 + sx * 0.11 * sg, by - u[2] * 0.92 - ay * 0.10 + sy * 0.11 * sg,
                  bz - u[3] * 0.92 - az * 0.10 + sz * 0.11 * sg)
      local pole = W(bx - u[1] * 0.5 - ax * 0.6 + sx * 0.12 * sg, by - u[2] * 0.5 - ay * 0.6 + sy * 0.12 * sg,
                     bz - u[3] * 0.5 - az * 0.6 + sz * 0.12 * sg)
      pcall(an.reach, an, sg < 0 and "Foot.Left" or "Foot.Right", t, { pole = pole, weight = 0.7 * w })
    end
  end
  -- the head looks up the line
  local tx, ty, tz = at(L, s - 1.2)
  if an.lookAt then pcall(an.lookAt, an, { "Head" }, W(tx, ty, tz), { limit = 40, weight = 0.6 * w }) end
  -- (probes) the lean: the head's lead over the hips, out from the wall
  local hd, hp = bw(an, "Head"), bw(an, "Hip")
  local lead = hd and hp and ((hd.x - hp.x) * ax + (hd.y - hp.y) * ay + (hd.z - hp.z) * az) or nil
  poseInfo = { lead = lead, gripR = r1, gripL = l1, gripR0 = r0, gripL0 = l0, curlR = rc, curlL = lc, feet = on_wall,
               wall = wd, s = s, w = w, lean = C.lean }
end

local function uiH()
  local st = ref("settings")
  return (st and st.designHeight and st.designHeight()) or 720
end
local function chars(s2)
  local _, n = s2:gsub("[^\128-\191]", "")
  return n
end
local function tag(x, y, text, size, r, g, b, a)
  local wdt = chars(text) * size * 0.5 + size
  local h = size * 1.5
  draw.rect(x - wdt / 2, y - h / 2, wdt, h, 0.05, 0.03, 0.02, 0.66 * a, size * 0.35)
  draw.text(x, y - size * 0.62, text, size, r, g, b, a, "center")
end

function lateUpdate(node, dt)
  if C then pcall(pose, dt or 0.016) end
  if not (promptText and camera and camera.screenRect and draw and draw.text) then return end
  local pc = ref("planet_camera")
  if pc and pc.cinematic == true then return end
  local vx, vy, vw, vh = camera.screenRect()
  if not vw or vw <= 0 then return end
  local k = vh / uiH()
  tag(vx + vw * 0.5, vy + vh * 0.70, promptText, 16 * k, 1.0, 0.86, 0.62, 1.0)
  if readout then tag(vx + vw * 0.5, vy + vh * 0.70 + 30 * k, readout, 14 * k, 0.92, 0.89, 0.81, 0.9) end
end

function start(node)
  if findScripts then
    local all = findScripts("rope_climb")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
end
