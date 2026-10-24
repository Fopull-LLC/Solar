-- PARACHUTE — the canopy you see. One per chute part, spawned by
-- vessel_controller when the chutes are staged (prefabs/Parachute.prefab.ron).
--
-- The physics lives in vessel_controller (update_chutes: the deploy sequence
-- and the inflated area the drag uses, published as `chute_fill`). This
-- script only DRAWS that state, so what you see is what is slowing you:
--
--   1. the lid pops off the canister and tumbles away down the airflow;
--   2. the pilot chute pulls the bagged canopy out along the airflow;
--   3. the suspension lines pay out and go taut (`stretch` 0 → 1);
--   4. the canopy inflates through a reefed "squid" to fully open, then
--      breathes; in thin air it stays partly collapsed.
--
-- The rig (models/parts/parachute.glb, tools/gen_parachute.py) is ONE skinned
-- mesh — canopy, 12 lines, riser, pilot chute, lid — so a chute is one draw.
-- Its bones are placed each frame from a handful of numbers (stretch, crown
-- and mouth inflation, the streaming direction, a breathing phase, a drape
-- blend): no cloth simulation. The node sits at the riser foot with no
-- rotation, so bone positions are plain world offsets from the canister.
--
-- The canopy streams down the relative airflow (opposite the craft's velocity
-- through the air) on a damped spring, so it lags and swings. When the air
-- stops (landed, or slowed to nothing) it spills, falls over downwind and
-- lies on the ground: every canopy bone is laid on the terrain under it (one
-- batch of rays, down toward the planet's centre), the riser hangs off the
-- canister and the slack lines run down the craft and along the ground. That
-- layout is kept in the PLANET's frame (offsets from its centre), because the
-- planet races along its rails ~1.45 m a tick in world space. When its part
-- is torn off or cut away the canopy flies free (also in the planet's frame),
-- sinks, lies down where it lands and is cleared.

defaults = {
  demo = 0,          -- 1: run the deploy on its own (a test scene, no vessel)
  demoSpeed = 40.0,  -- demo: airspeed, m/s
  demoDens = 1.0,    -- demo: air density factor (1 = sea level)
  demoLand = 0.0,    -- demo: seconds after deploy at which the air stops (0 = never)
}

-- ── the rig's rest profile (printed by tools/gen_parachute.py) ──────────────
local G, K = 12, 4
local LR, LL = 1.0000, 7.0000
local RHO_OPEN = { 0.3200, 1.8712, 3.1760, 3.5453 }
local Y_OPEN = { 9.7261, 9.4001, 8.5180, 7.0358 }
local BULGE = 0.0500
local APEX_UP, PILOT_UP = 0.0500, 1.7000
local LINE_MID = 0.5000
-- Collapsed (a bundle streaming behind the craft): each ring's radius.
local RHO_SHUT = { 0.10, 0.20, 0.26, 0.22 }
-- A gore's middle against its seams: bulging out when full, folded IN when
-- collapsed (a deflated canopy is a fluted star, not a smaller dome).
local FOLD_SHUT = 0.55

local NCOL = 2 * G
local TWO_PI = math.pi * 2
local sqrt, sin, cos, atan2, asin = math.sqrt, math.sin, math.cos, math.atan2, math.asin
local min, max, abs = math.min, math.max, math.abs

-- Rest chords between rings and rest normal elevations (β): the solver keeps
-- the chords (the fabric does not stretch), and each bone turns by how far its
-- ring's normal has tilted from rest.
local CHORD, BETA_REST = {}, {}
for k = 1, K - 1 do
  CHORD[k] = sqrt((RHO_OPEN[k + 1] - RHO_OPEN[k]) ^ 2 + (Y_OPEN[k + 1] - Y_OPEN[k]) ^ 2)
end
local function betas(rho, y, out)
  for k = 1, K do
    local a, b = max(1, k - 1), min(K, k + 1)
    out[k] = atan2(rho[b] - rho[a], -(y[b] - y[a]))
  end
  return out
end
betas(RHO_OPEN, Y_OPEN, BETA_REST)

-- Bone names and each column's azimuth, built once.
local NAME, SIN_T, COS_T = {}, {}, {}
for col = 0, NCOL - 1 do
  local th = col * math.pi / G
  SIN_T[col], COS_T[col] = sin(th), cos(th)
  NAME[col] = {}
  for k = 1, K do NAME[col][k] = string.format("C%d_%d", col, k - 1) end
end

-- ── small vector helpers (plain numbers; nothing allocates per frame) ───────
local function norm3(x, y, z)
  local l = sqrt(x * x + y * y + z * z)
  if l < 1e-9 then return 0, 1, 0, 0 end
  return x / l, y / l, z / l, l
end
local function cross(ax, ay, az, bx, by, bz)
  return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
end

-- YXZ Euler angles (node.yaw/pitch/roll convention) of the rotation whose
-- columns are the bone's local X, Y, Z axes in model space.
local function euler(xx, xy, xz, yx, yy, yz, zx, zy, zz)
  local p = asin(max(-1, min(1, -zy)))
  return atan2(zx, zz), p, atan2(xy, yy)
end

-- ── the canopy shape: rings from (crown, mouth, stretch) ────────────────────
-- crown 0..1: how full the top of the canopy is; mouth 0..1: how open the
-- skirt is (a reefed canopy has a full-ish crown over a small mouth).
-- Solved along the meridian from the skirt up, keeping every chord's length,
-- so a collapsed canopy is LONGER than an open one, as cloth is.
local rho, ry, beta = { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 }
local wk = { 0, 0, 0, 0 }
local function solve(crown, mouth, stretch)
  wk[1], wk[2], wk[3], wk[4] = crown, crown, 0.5 * (crown + mouth), mouth
  for k = 1, K do rho[k] = RHO_SHUT[k] + (RHO_OPEN[k] - RHO_SHUT[k]) * wk[k] end
  ry[K] = LR + sqrt(max(0.0, LL * LL - rho[K] * rho[K]))
  for k = K - 1, 1, -1 do
    local dr = rho[k] - rho[k + 1]
    local c2 = CHORD[k] * CHORD[k]
    ry[k] = ry[k + 1] + sqrt(max(0.04 * c2, c2 - dr * dr))
  end
  betas(rho, ry, beta)
  -- lines and canopy pay out together during extraction
  if stretch < 1 then
    for k = 1, K do ry[k] = ry[k] * stretch end
  end
end

-- ── state ───────────────────────────────────────────────────────────────────
local vc, chute, vnode = nil, nil, nil   -- owner script, its chute entry, hull
local seek_t = -1e9
local born = nil
-- Once cut loose: { dom, rx,ry,rz (offset from that planet's centre),
-- vx,vy,vz, t, landed, landed_t }. Integrated in the planet's frame: a world
-- position would be left behind by the planet's own motion.
local free = nil
-- The canopy's frame between frames: axis a (unit, riser foot → canopy), its
-- rate of change w (the swing) and e1, a reference across the axis (no twist).
local spring = { ax = 0, ay = 1, az = 0, wx = 0, wy = 0, wz = 0, e1x = 1, e1y = 0, e1z = 0 }
local lid0 = nil              -- lid launch direction
local fall_t = 0.0            -- seconds the canopy has been falling over / lying
local lay = nil               -- the ground layout (see build_layout)
local last_fill = { stretch = 0, area = 0, dens = 1, t = 0 }
local down_x, down_y, down_z, down_t, down_dom = 0, -1, 0, -10, nil
local phase = math.random() * TWO_PI
local cost = { n = 0, ms = 0.0 }
local tmp = { x = 0, y = 0, z = 0 }
local cam = { ref = nil, t = -10, far = false } -- the eye, checked twice a second
-- The bone writes of a frame go to the engine in one batch (anim:setBones):
-- each bone's number, looked up once (anim:boneIndex answers once the rig has
-- posed), then flat lists of positions and of rotations. The first frame,
-- before the numbers exist, writes bone by bone.
-- A canopy lying still re-sends nothing: the rig holds its last pose
-- (anim:holdPose) until something it is drawn from moves (`held`).
local bat = {
  ids = nil,
  pb = {}, pv = {}, np_was = 0, -- position writes: bones, then x, y, z each
  rb = {}, rv = {}, nr_was = 0, -- rotation writes: bones, then yaw, pitch, roll
  held = nil,
}

-- Published for probes: what the canopy is doing.
canopy = { crown = 0, mouth = 0, stretch = 0, drape = 0, free = false, ms = 0 }

-- Which vessel owns this canopy: the one whose chute entry names this node.
local function find_owner(node)
  for _, v in ipairs(findScripts("vessel_controller")) do
    local list = v.chutes
    if list then
      for _, c in ipairs(list) do
        if c.canopy == node.id then return v, c end
      end
    end
  end
  return nil, nil
end

local function still_attached(node)
  if not (vc and vc.valid) or not (vnode and vnode.valid) then return false end
  local list = vc.chutes
  if not list then return false end
  for _, c in ipairs(list) do
    if c.canopy == node.id then chute = c; return true end -- (a cut clears it)
  end
  return false
end

local function update_down(x, y, z)
  if time - down_t < 0.5 then return end
  down_t = time
  local dom = space.dominant(x, y, z)
  local b = dom and space.body(dom)
  if b then
    down_x, down_y, down_z = norm3(b.x - x, b.y - y, b.z - z)
    down_dom = dom
  end
end

-- The planet's centre this frame (the frame the ground layout and a loose
-- canopy live in), or 0,0,0 when there is none.
local function body_pos(dom)
  local b = dom and space.body(dom)
  if b then return b.x, b.y, b.z end
  return 0, 0, 0
end

function start(node)
  born = time
end

-- The demo deploy (params.demo = 1): the same sequence on a clock, for a
-- test scene with no vessel. The real numbers come from vessel_controller.
local demo = { stretch = 0, area = 0, t = 0, ls = nil }
local function demo_fill(dt)
  demo.t = demo.t + dt
  local spd = params.demoSpeed
  local air = params.demoLand <= 0 or demo.t < params.demoLand
  if demo.stretch < 1 then
    demo.stretch = min(1, demo.stretch + dt * max(10, 1.5 * spd) / 12.5)
  else
    demo.ls = demo.ls or demo.t
    local target = (demo.t - demo.ls < 0.4) and 0.2 or 1.0
    local hold = 0.3 + 0.7 * min(1, max(0, (params.demoDens - 0.03) / 0.37))
    target = air and min(target, hold) or 0
    local rate = max(0.8, min(6, spd / 17.75 * (0.2 + 0.8 * sqrt(params.demoDens))))
    if target > demo.area then
      demo.area = demo.area + (target - demo.area) * min(1, dt * rate * 2.2) + dt * 0.02
      demo.area = min(demo.area, target)
    else
      demo.area = demo.area + (target - demo.area) * min(1, dt * 3)
    end
  end
  return demo.stretch, demo.area, params.demoDens, air and spd or 0
end

-- ── the ground layout ───────────────────────────────────────────────────────
-- The rays pass the craft and its crew in one ignore list (floptle/0473,
-- 0.117.0-rc7: until rc6 a query took one node, so the seated crew was hit).
-- A ray that still strikes either is cast again from just past it: only the
-- ground (terrain, a pad, a building) may hold the cloth up.
function craft_and_crew()
  local l = { vnode }
  local a = find and find("Astronaut")
  if a and a.valid then l[2] = a end
  return l
end
local function is_craft(n)
  if not (n and n.valid) then return false end
  if n.name == "Astronaut" then return true end
  if vnode and vnode.valid then
    if n.id == vnode.id then return true end
    local p = n.parent
    if p and p.id == vnode.id then return true end
  end
  return false
end
local function ground_hit(hit, ox, oy, oz, dx, dy, dz, maxd, opts)
  local tries = 0
  while hit and is_craft(hit.node) and tries < 3 do
    tries = tries + 1
    local d = hit.distance + 0.05
    ox, oy, oz, maxd = ox + dx * d, oy + dy * d, oz + dz * d, maxd - d
    hit = maxd > 0 and raycast(ox, oy, oz, dx, dy, dz, maxd, opts) or nil
  end
  if hit and is_craft(hit.node) then return nil end
  return hit
end

-- Rotate vector v about unit axis k by angle (Rodrigues).
local function rotate(vx, vy, vz, kx, ky, kz, ca, sa)
  local cx, cy, cz = cross(kx, ky, kz, vx, vy, vz)
  local d = (kx * vx + ky * vy + kz * vz) * (1 - ca)
  return vx * ca + cx * sa + kx * d, vy * ca + cy * sa + ky * d, vz * ca + cz * sa + kz * d
end

-- A fixed pseudo-random number in [-1, 1] per (bone, salt): the crumple.
local function hash(i, salt)
  local x = sin(i * 12.9898 + salt * 78.233 + phase * 3.7) * 43758.5453
  return (x - math.floor(x)) * 2 - 1
end

-- How wide (half, m) and how deep each ring lies once it is down: the canopy
-- falls over onto its side and flattens into a long crumpled tongue, its
-- skirt gathered in by the lines, its crown spread in a loose heap.
local LIE_W = { 0.45, 1.60, 1.55, 0.95 }
local LIE_T = { 0.14, 0.34, 0.36, 0.18 }

-- Lay the canopy down: where every bone ends up, as offsets from the planet's
-- centre. The canopy falls over as one piece (its axis turned onto the
-- downwind level `h`), so each gore keeps its side and nothing crosses over;
-- then each bone is put on the terrain under it.
local function build_layout(cx, cy, cz, ax, ay, az, e1x, e1y, e1z, e2x, e2y, e2z, dom, opts)
  local ux, uy, uz = -down_x, -down_y, -down_z
  -- downwind: the way the canopy leans (the last airflow), else across it
  local hx, hy, hz = ax, ay, az
  local d = hx * ux + hy * uy + hz * uz
  hx, hy, hz = hx - ux * d, hy - uy * d, hz - uz * d
  local _, _, _, hl = norm3(hx, hy, hz)
  if hl < 0.2 then
    hx, hy, hz = e1x, e1y, e1z
    d = hx * ux + hy * uy + hz * uz
    hx, hy, hz = hx - ux * d, hy - uy * d, hz - uz * d
    _, _, _, hl = norm3(hx, hy, hz)
    if hl < 0.2 then hx, hy, hz = e2x - ux * (e2x * ux + e2y * uy + e2z * uz), e2y - uy * (e2x * ux + e2y * uy + e2z * uz), e2z - uz * (e2x * ux + e2y * uy + e2z * uz) end
  end
  hx, hy, hz = norm3(hx, hy, hz)
  -- a little wander: no two canopies fall exactly the same way
  local yaw = 0.25 * hash(1, 7)
  local sx, sy, sz = cross(ux, uy, uz, hx, hy, hz)
  hx, hy, hz = norm3(hx * cos(yaw) + sx * sin(yaw), hy * cos(yaw) + sy * sin(yaw), hz * cos(yaw) + sz * sin(yaw))
  sx, sy, sz = cross(ux, uy, uz, hx, hy, hz) -- side (level, across)
  -- the flying frame turned so its axis lies along h
  local kx, ky, kz = cross(ax, ay, az, hx, hy, hz)
  local kx2, ky2, kz2, sn = norm3(kx, ky, kz)
  local cs = ax * hx + ay * hy + az * hz
  local f1x, f1y, f1z, f2x, f2y, f2z
  if sn < 1e-6 then
    if cs > 0 then
      f1x, f1y, f1z, f2x, f2y, f2z = e1x, e1y, e1z, e2x, e2y, e2z
    else -- turned right round: about the side axis
      f1x, f1y, f1z = rotate(e1x, e1y, e1z, sx, sy, sz, -1, 0)
      f2x, f2y, f2z = rotate(e2x, e2y, e2z, sx, sy, sz, -1, 0)
    end
  else
    f1x, f1y, f1z = rotate(e1x, e1y, e1z, kx2, ky2, kz2, cs, sn)
    f2x, f2y, f2z = rotate(e2x, e2y, e2z, kx2, ky2, kz2, cs, sn)
  end

  local L = { dom = dom, hx = hx, hy = hy, hz = hz, sx = sx, sy = sy, sz = sz,
              ux = ux, uy = uy, uz = uz, pos = {}, rot = {}, t0 = time }
  -- Where each piece lies, as (along h, across, height above the ground),
  -- measured from the canister's foot. The skirt is a few metres out (the
  -- lines are slack), the canopy runs on downwind, crumpled.
  local drift = 3.6 + 0.8 * (hash(2, 3) * 0.5 + 0.5)
  local along = {}
  along[K] = drift
  for k = K - 1, 1, -1 do along[k] = along[k + 1] + CHORD[k] * 0.72 end
  local bend = 0.35 * hash(3, 5) -- the heap lies on a gentle curve
  local items = {}
  local function add(name, a, s, h, col, k)
    items[#items + 1] = { name = name, a = a, s = s + bend * (a / 6) ^ 2, h = h, col = col, k = k }
  end
  for col = 0, NCOL - 1 do
    local st, ct = SIN_T[col], COS_T[col]
    local rx, ry, rz = f1x * st + f2x * ct, f1y * st + f2y * ct, f1z * st + f2z * ct
    local rs = rx * sx + ry * sy + rz * sz -- across
    local rv = rx * ux + ry * uy + rz * uz -- up (top layer) or down (under it)
    for k = 1, K do
      local i = col * K + k
      local crumple = 0.5 + 0.5 * hash(i, 11)
      local h = 0.03 + LIE_T[k] * max(0, rv) * (0.5 + 0.5 * crumple)
      if col % 2 == 1 then h = h + 0.08 * crumple * max(0, rv + 0.3) end -- a gore's slack billows up
      add(NAME[col][k], along[k] + 0.32 * hash(i, 13) + 0.15 * max(0, rv),
        rs * LIE_W[k] * (0.8 + 0.2 * crumple) + 0.14 * hash(i, 17), h, col, k)
    end
  end
  -- the line middles: off the craft's foot, splayed toward their seams
  for g = 0, G - 1 do
    local st, ct = SIN_T[2 * g], COS_T[2 * g]
    local rs = (f1x * st + f2x * ct) * sx + (f1y * st + f2y * ct) * sy + (f1z * st + f2z * ct) * sz
    add("L" .. g, 1.25 + 0.35 * (hash(g, 19) * 0.5 + 0.5), rs * LIE_W[K] * 0.35 + 0.08 * hash(g, 23), 0.025)
  end
  local apex_a = along[1] + 0.35
  add("Apex", apex_a, 0, 0.12)
  add("Pilot", apex_a + 0.9, 0.5 * hash(4, 29), 0.27) -- mouth down on the ground
  add("Conf", 0.55, 0, 0.05) -- the ground under where the riser hangs

  -- one batch of rays, down from well above the canister's height (the
  -- ground it lies on may be higher than the canister: a craft on its side,
  -- in a dip or a crater)
  local origins, dirs = {}, {}
  local rise = 8.0
  for n, it in ipairs(items) do
    origins[n] = vec3(cx + hx * it.a + sx * it.s + ux * rise, cy + hy * it.a + sy * it.s + uy * rise,
      cz + hz * it.a + sz * it.s + uz * rise)
    dirs[n] = vec3(down_x, down_y, down_z)
  end
  local reach = 60.0
  local hits = raycastMany and raycastMany(origins, dirs, reach, opts) or nil
  local bx, by, bz = body_pos(dom)
  local fallback = nil -- a ray that found nothing lies at the level of its neighbours
  local gp = {}
  for n, it in ipairs(items) do
    local o = origins[n]
    local hit = hits and hits[n] or nil
    if hits == nil then hit = raycast(o.x, o.y, o.z, down_x, down_y, down_z, reach, opts) end
    hit = ground_hit(hit or nil, o.x, o.y, o.z, down_x, down_y, down_z, reach, opts)
    local gd = hit and hit.distance or nil
    if gd then fallback = gd end
    gp[n] = gd
  end
  -- On a sea the cloth floats: nothing lies below the water's surface.
  local w = dom and save and save.get and save.get("world." .. dom)
  local sea = type(w) == "table" and tonumber(w.sea) or 0
  for n, it in ipairs(items) do
    local gd = gp[n] or fallback or (rise + 3.0)
    local o = origins[n]
    local h = gd - it.h
    local qx, qy, qz = o.x + down_x * h - bx, o.y + down_y * h - by, o.z + down_z * h - bz
    if sea > 0 then
      local rx, ry, rz, r = norm3(qx, qy, qz)
      local top = sea + 0.02 + it.h * 0.3
      if r < top then qx, qy, qz = rx * top, ry * top, rz * top end
    end
    L.pos[it.name] = { qx, qy, qz, col = it.col, k = it.k }
  end
  -- Each canopy bone's frame once down: the flying one, turned over (the
  -- same turn the layout used). Kept as world directions.
  for col = 0, NCOL - 1 do
    local st, ct = SIN_T[col], COS_T[col]
    local rx, ry, rz = f1x * st + f2x * ct, f1y * st + f2y * ct, f1z * st + f2z * ct
    local tx, ty, tz = f1x * ct - f2x * st, f1y * ct - f2y * st, f1z * ct - f2z * st
    L.rot[col] = { tx, ty, tz, rx, ry, rz }
  end
  return L
end

-- How far along its fall a piece is (0 standing .. 1 lying), from the time
-- since the air stopped.
local function fall_u(t, delay, dur)
  return max(0, min(1, (t - delay) / dur))
end

function lateUpdate(node, dt)
  if dt <= 0 then return end
  local ax, ay, az, wx, wy, wz = spring.ax, spring.ay, spring.az, spring.wx, spring.wy, spring.wz
  local e1x, e1y, e1z = spring.e1x, spring.e1y, spring.e1z
  local t0 = os.clock()
  local anim = node:animator()
  if not anim then return end

  -- ---- where the riser foot is, and the air it sits in --------------------
  local px, py, pz            -- riser foot (world)
  local vx, vy, vz = 0, 0, 0  -- velocity through the air
  local stretch, area, dens
  local grounded = false
  if params.demo == 1 then
    px, py, pz = node.x, node.y, node.z
    local s
    stretch, area, dens, s = demo_fill(dt)
    vy = -s
    down_x, down_y, down_z = 0, -1, 0
    grounded = s < 0.5
  else
    if not free then
      if not vc and time - seek_t > 0.25 then
        seek_t = time
        vc, chute = find_owner(node)
        vnode = vc and vc.node
        if not vc and born and time - born > 2.0 then
          -- nobody claims this canopy (its vessel reloaded): let it go
          update_down(node.x, node.y, node.z)
          local bx, by, bz = body_pos(down_dom)
          free = { dom = down_dom, rx = node.x - bx, ry = node.y - by, rz = node.z - bz,
                   vx = 0, vy = 0, vz = 0, t = 0 }
        end
      end
      if vc and not still_attached(node) then
        local fx0, fy0, fz0 = last_fill.px or node.x, last_fill.py or node.y, last_fill.pz or node.z
        update_down(fx0, fy0, fz0)
        local bx, by, bz = body_pos(down_dom)
        free = { dom = down_dom, rx = fx0 - bx, ry = fy0 - by, rz = fz0 - bz,
                 vx = last_fill.vx or 0, vy = last_fill.vy or 0, vz = last_fill.vz or 0, t = 0 }
        canopy.free = true
        -- (vnode is kept: the craft it left is not ground to land on)
      end
    end
    if free then
      free.t = free.t + dt
      local bx, by, bz = body_pos(free.dom)
      update_down(bx + free.rx, by + free.ry, bz + free.rz)
      -- A loose canopy is all drag and no weight: it sheds the craft's speed
      -- in a fraction of a second and settles to a slow sinking drift.
      if not free.landed then
        local k = min(1, dt / 0.45)
        free.vx = free.vx + (down_x * 3.0 - free.vx) * k
        free.vy = free.vy + (down_y * 3.0 - free.vy) * k
        free.vz = free.vz + (down_z * 3.0 - free.vz) * k
        free.rx, free.ry, free.rz = free.rx + free.vx * dt, free.ry + free.vy * dt, free.rz + free.vz * dt
        -- Down yet? Asked from a little above, so a step that carries it
        -- past the surface between two asks still finds the ground (and it
        -- is set back on top of it).
        if (free.ray or -1) < time - 0.1 then
          free.ray = time
          local up = 1.5
          local ox, oy, oz = bx + free.rx - down_x * up, by + free.ry - down_y * up, bz + free.rz - down_z * up
          local opts = vnode and vnode.valid and { ignore = craft_and_crew() } or nil
          local hit = ground_hit(raycast(ox, oy, oz, down_x, down_y, down_z, up + 2.0, opts),
            ox, oy, oz, down_x, down_y, down_z, up + 2.0, opts)
          if hit and hit.distance < up + 0.6 then
            free.landed, free.landed_t = true, time
            local lift = min(0, hit.distance - up - 0.4) -- (negative: it went under)
            free.rx, free.ry, free.rz = free.rx + down_x * lift, free.ry + down_y * lift, free.rz + down_z * lift
          end
        end
      end
      px, py, pz = bx + free.rx, by + free.ry, bz + free.rz
      vx, vy, vz = free.landed and 0 or free.vx, free.landed and 0 or free.vy, free.landed and 0 or free.vz
      grounded = free.landed
      stretch = last_fill.stretch
      area = max(0, (last_fill.area or 0) * (1 - free.t / 0.7))
      dens = last_fill.dens or 1
      -- cleared once well gone: still sinking after 14 s, or lying a while
      if (not free.landed and free.t > 14.0) or (free.landed and time - free.landed_t > 60.0) then
        node:destroy(); return
      end
    else
      if not (vc and chute and vnode and vnode.valid) then return end
      local f = vc.chute_fill
      if not f then return end
      local up = vnode.up
      local w = vnode:toWorld(vec3(chute.x, chute.y, chute.z))
      if not w then return end
      -- the riser foot: the canister's top (half the part's stack height up)
      local hh = chute.h and chute.h * 0.5 or 0.3
      px, py, pz = w.x + up.x * hh, w.y + up.y * hh, w.z + up.z * hh
      vx, vy, vz = vnode.vx or 0, vnode.vy or 0, vnode.vz or 0
      stretch, area, dens = f.stretch or 0, f.area or 0, f.dens or 1
      grounded = f.grounded or false
      update_down(px, py, pz)
      last_fill.stretch, last_fill.area, last_fill.dens = stretch, area, dens
      last_fill.px, last_fill.py, last_fill.pz = px, py, pz
      last_fill.vx, last_fill.vy, last_fill.vz = vx, vy, vz
    end
  end
  node.x, node.y, node.z = px, py, pz

  -- Out of sight, out of cost: a canopy far from the eye (planet_camera's
  -- cam_x/y/z) is hidden and writes nothing — any farther than a few pixels
  -- in flight, and sooner once it lies draped on the ground.
  if time - cam.t > 0.5 then
    cam.t = time
    if not cam.ref or not cam.ref.valid then cam.ref = findScript and findScript("planet_camera") end
    local r = cam.ref
    local cx = r and r.valid and r.cam_x
    cam.far = false
    if cx then
      local _, _, _, d = norm3(px - cx, py - r.cam_y, pz - r.cam_z)
      local down_now = grounded or vx * vx + vy * vy + vz * vz < 2.25
      cam.far = d > ((lay and down_now and fall_t > 3) and 250 or 1500)
    end
  end
  if cam.far then
    if node.visible then node.visible = false end
    bat.held = nil
    return
  end

  -- ---- the streaming direction: down the relative airflow, on a spring ----
  local fx, fy, fz, spd = norm3(-vx, -vy, -vz)
  local still = spd < 1.5 or grounded
  if spd < 0.3 then fx, fy, fz = -down_x, -down_y, -down_z end
  -- Once the air has stopped nothing holds the canopy up: it keeps the lean
  -- it had (the layout lays it down from there) instead of standing up.
  if still then fx, fy, fz = ax, ay, az end
  -- A cluster splays: each canopy leans away from the hull's centreline.
  if not still and not free and chute and (chute.x ~= 0 or chute.z ~= 0) and vnode and vnode.valid then
    local r, f2 = vnode.right, vnode.forward
    local ox = r.x * chute.x + f2.x * chute.z
    local oy = r.y * chute.x + f2.y * chute.z
    local oz = r.z * chute.x + f2.z * chute.z
    local d = ox * fx + oy * fy + oz * fz
    ox, oy, oz = norm3(ox - fx * d, oy - fy * d, oz - fz * d)
    fx, fy, fz = norm3(fx + ox * 0.35, fy + oy * 0.35, fz + oz * 0.35)
  end
  -- a slow wander: the canopy is never quite still in moving air
  local tt = time + phase
  local wob = 0.05 * min(1, spd / 8)
  local cx, cy, cz = cross(fx, fy, fz, e1x, e1y, e1z)
  fx = fx + (e1x * sin(tt * 0.61) + cx * sin(tt * 0.47 + 1.3)) * wob
  fy = fy + (e1y * sin(tt * 0.61) + cy * sin(tt * 0.47 + 1.3)) * wob
  fz = fz + (e1z * sin(tt * 0.61) + cz * sin(tt * 0.47 + 1.3)) * wob
  fx, fy, fz = norm3(fx, fy, fz)
  -- Stiffer in thick fast air (the canopy is held hard), loose in thin air.
  local wn = 1.6 + 2.4 * min(1, sqrt(dens) * spd / 20)
  local zeta = still and 1.0 or 0.35
  local h = min(dt, 1 / 30)
  wx = wx + (wn * wn * (fx - ax) - 2 * zeta * wn * wx) * h
  wy = wy + (wn * wn * (fy - ay) - 2 * zeta * wn * wy) * h
  wz = wz + (wn * wn * (fz - az) - 2 * zeta * wn * wz) * h
  ax, ay, az = norm3(ax + wx * dt, ay + wy * dt, az + wz * dt)
  if born and time - born < 0.05 then
    ax, ay, az, wx, wy, wz = fx, fy, fz, 0, 0, 0
  end
  -- carry the across-axis reference along (parallel transport), with the
  -- slow turn a real canopy has about its axis
  local d1 = e1x * ax + e1y * ay + e1z * az
  e1x, e1y, e1z = norm3(e1x - ax * d1, e1y - ay * d1, e1z - az * d1)
  if abs(e1x) + abs(e1y) + abs(e1z) < 0.5 then e1x, e1y, e1z = norm3(cross(ax, ay, az, 0.3, 0.1, 0.95)) end
  local spin = 0.12 * area * dt
  local s2x, s2y, s2z = cross(e1x, e1y, e1z, ax, ay, az) -- e2 = e1 × axis
  e1x, e1y, e1z = norm3(e1x + s2x * spin, e1y + s2y * spin, e1z + s2z * spin)
  local e2x, e2y, e2z = cross(e1x, e1y, e1z, ax, ay, az)
  spring.ax, spring.ay, spring.az, spring.wx, spring.wy, spring.wz = ax, ay, az, wx, wy, wz
  spring.e1x, spring.e1y, spring.e1z = e1x, e1y, e1z

  -- ---- inflation → shape, with breathing -----------------------------------
  local a = max(0, min(1, area))
  local mouth = sqrt(a)
  local crown = min(1, sqrt(a) * 1.4)
  -- A full canopy breathes: its skirt pulses in and out (the skirt alone, so
  -- the crown keeps its rest pose and costs nothing).
  local breath = 1 + min(1, max(0, (a - 0.3) / 0.5)) * 0.04 * sin(tt * 5.2)
  -- An unfilled canopy in moving air still flutters at the skirt.
  local flutter = (1 - min(1, a * 2)) * min(1, spd / 15) * 0.25
  solve(crown, mouth, max(0.03, stretch))

  -- ---- down: the air has stopped, the canopy falls over and lies ----------
  -- (capped: every piece is down by 3 s, and a canopy picked up again by
  -- moving air stands back up in under two)
  if still then fall_t = min(3.5, fall_t + dt) else fall_t = max(0, fall_t - 2 * dt) end
  if fall_t > 0 and not lay then
    local opts = vnode and vnode.valid and { ignore = craft_and_crew() } or nil
    lay = build_layout(px, py, pz, ax, ay, az, e1x, e1y, e1z, e2x, e2y, e2z,
      free and free.dom or down_dom, opts)
  elseif fall_t <= 0 and lay then
    lay = nil
  end
  local drape = lay and min(1, fall_t / 2.6) or 0
  canopy.crown, canopy.mouth, canopy.stretch, canopy.drape = crown, mouth, stretch, drape

  -- ---- bones ---------------------------------------------------------------
  -- The node turns with the canopy (its +Y is the axis), so the bones live in
  -- the canopy's own frame, where a full canopy IS the rig's rest pose: those
  -- bones need no write at all (an unwritten bone holds its rest pose). Only
  -- what differs from rest costs a call — the breathing skirt, a canopy that
  -- is opening or collapsing, one lying down.
  node.yaw, node.pitch, node.roll = euler(e1x, e1y, e1z, ax, ay, az, e2x, e2y, e2z)
  local ids = bat.ids
  if not ids and anim.boneIndex and anim:boneIndex("Apex") then
    ids = {}
    bat.ids = ids
    for _, row in pairs(NAME) do for _, n in ipairs(row) do ids[n] = anim:boneIndex(n) end end
    for g = 0, G - 1 do ids["L" .. g] = anim:boneIndex("L" .. g) end
    for _, n in ipairs({ "Riser", "Apex", "Pilot", "Lid" }) do ids[n] = anim:boneIndex(n) end
    anim:holdPose(true)
  end

  -- Lying still (every piece down, the canopy's frame and its place on the
  -- planet as they were at the last write): the held pose is this frame's.
  local lid_u = vnode and vnode.valid and vnode.up
  local sig_x, sig_y, sig_z = 0, 0, 0
  if lay then
    local bx0, by0, bz0 = body_pos(lay.dom)
    sig_x, sig_y, sig_z = px - bx0, py - by0, pz - bz0
  end
  local h = bat.held
  if h and lay and fall_t >= 3.5
      and abs(h[1] - ax) + abs(h[2] - ay) + abs(h[3] - az) < 1e-5
      and abs(h[4] - e1x) + abs(h[5] - e1y) + abs(h[6] - e1z) < 1e-5
      and abs(h[7] - sig_x) + abs(h[8] - sig_y) + abs(h[9] - sig_z) < 1e-4
      and (not lid_u or abs(h[10] - lid_u.x) + abs(h[11] - lid_u.y) + abs(h[12] - lid_u.z) < 1e-5) then
    canopy.writes = 0
    if not node.visible then node.visible = true end
    local ms = (os.clock() - t0) * 1000
    cost.n, cost.ms = cost.n + 1, cost.ms + ms
    canopy.ms = cost.ms / cost.n
    canopy.ms_now = (canopy.ms_now or ms) + (ms - (canopy.ms_now or ms)) * 0.05
    return
  end

  local function lp(x, y, z) -- world offset → canopy frame
    return x * e1x + y * e1y + z * e1z, x * ax + y * ay + z * az, x * e2x + y * e2y + z * e2z
  end
  local nw = 0
  local np, nr = 0, 0
  local pb, pv, rb, rv = bat.pb, bat.pv, bat.rb, bat.rv
  local function put(name, x, y, z)
    nw = nw + 1
    if ids then
      np = np + 1
      pb[np] = ids[name]
      local j = 3 * np
      pv[j - 2], pv[j - 1], pv[j] = x, y, z
    else
      tmp.x, tmp.y, tmp.z = x, y, z
      anim:setBonePos(name, tmp)
    end
  end
  local function rot(name, yaw, pitch, roll)
    nw = nw + 1
    if ids then
      nr = nr + 1
      rb[nr] = ids[name]
      local j = 3 * nr
      rv[j - 2], rv[j - 1], rv[j] = yaw, pitch, roll
    else
      anim:setBoneRot(name, yaw, pitch, roll)
    end
  end
  local function turn(name, xx, xy, xz, yx, yy, yz, zx, zy, zz)
    rot(name, euler(xx, xy, xz, yx, yy, yz, zx, zy, zz))
  end

  -- Lying down: a bone's place on the ground, in the canopy frame, and the
  -- planet's up there. (The layout is kept from the planet's centre.)
  local bx, by, bz, ulx, uly, ulz = 0, 0, 0, 0, 1, 0
  if lay then
    bx, by, bz = body_pos(lay.dom)
    bx, by, bz = bx - px, by - py, bz - pz
    ulx, uly, ulz = lp(lay.ux, lay.uy, lay.uz)
  end
  local function ground(name)
    local q = lay.pos[name]
    return lp(q[1] + bx, q[2] + by, q[3] + bz)
  end
  -- Falling over: the canopy topples about the canister like a pole (slowly
  -- at first, then faster) toward where it will lie, and each piece eases
  -- onto its place on the ground as it comes down.
  local tkx, tky, tkz, tmax = 1, 0, 0, 0
  if lay then
    local gx, gy, gz = ground("Apex")
    local sx2, sy2, sz2 = ground(NAME[0][K])
    local dx, dy, dz = norm3(gx + sx2, gy + sy2, gz + sz2) -- toward the heap
    local kx, ky, kz, sn = norm3(cross(0, 1, 0, dx, dy, dz))     -- (the axis is +Y here)
    if sn > 1e-4 then tkx, tky, tkz, tmax = kx, ky, kz, atan2(sn, dy) end
  end
  local function settle(name, fx2, fy2, fz2, u)
    local ph = tmax * u * u
    if ph > 1e-5 then fx2, fy2, fz2 = rotate(fx2, fy2, fz2, tkx, tky, tkz, cos(ph), sin(ph)) end
    local w = max(0, min(1, (u - 0.5) / 0.5))
    w = w * w * (3 - 2 * w)
    local gx, gy, gz = ground(name)
    return fx2 + (gx - fx2) * w, fy2 + (gy - fy2) * w, fz2 + (gz - fz2) * w
  end

  -- riser foot → confluence. Down, it hangs off the canister toward the
  -- canopy and comes to rest on whatever is under it.
  local cs = LR * max(0.03, stretch)
  local rcx, rcy, rcz = 0, cs, 0
  if lay then
    local wa = fall_u(fall_t, 0, 0.9)
    wa = wa * wa * (3 - 2 * wa)
    local hx, hy, hz = lp(lay.hx, lay.hy, lay.hz)
    local tx, ty, tz = hx * 0.55 - ulx * 0.8, hy * 0.55 - uly * 0.8, hz * 0.55 - ulz * 0.8
    -- not below the ground under it (a craft lying on its side)
    local gx, gy, gz = ground("Conf")
    local above = (tx - gx) * ulx + (ty - gy) * uly + (tz - gz) * ulz
    if above < 0 then tx, ty, tz = tx - ulx * above, ty - uly * above, tz - ulz * above end
    rcx, rcy, rcz = tx * wa, cs + (ty - cs) * wa, tz * wa
    -- (the pull straight down is the riser's own weight: no separate drop)
    put("Riser", rcx, rcy, rcz)
  elseif cs < LR - 1e-4 then
    put("Riser", 0, cs, 0)
  end

  -- the canopy, ring by ring
  local skirt_x, skirt_y, skirt_z = {}, {}, {} -- seam skirt points (for the lines)
  for k = 1, K do
    local ck, rk = ry[k], rho[k]
    local db = BETA_REST[k] - beta[k]
    local fold = FOLD_SHUT + (1 + BULGE - FOLD_SHUT) * wk[k]
    local same_y = abs(ck - Y_OPEN[k]) < 1e-4
    local same_b = abs(db) < 1e-4
    -- lying down: the skirt lands first, the crown last
    local ring_u = lay and fall_u(fall_t, 0.05 * (K - k), 1.6 + 0.12 * (K - k)) or 0
    local cdb, sdb = cos(db), sin(db)
    for col = 0, NCOL - 1 do
      local r = rk
      if col % 2 == 1 then r = r * fold end
      if k == K then r = r * breath * (1 + flutter * sin(tt * 9.0 + col * 1.7)) end
      local st, ct = SIN_T[col], COS_T[col]
      local fx2, fy2, fz2 = r * st, ck, r * ct
      if not lay then
        local rest = RHO_OPEN[k] * ((col % 2 == 1) and (1 + BULGE) or 1)
        if not (same_y and abs(r - rest) < 1e-4) then put(NAME[col][k], fx2, fy2, fz2) end
        if not same_b then rot(NAME[col][k], col * math.pi / G, db, 0) end
      else
        fx2, fy2, fz2 = settle(NAME[col][k], fx2, fy2, fz2, ring_u)
        put(NAME[col][k], fx2, fy2, fz2)
        -- the bone's frame: from its flying one (yaw θ, pitch db) to the
        -- canopy's turned-over one
        local q = lay.rot[col]
        local Yx, Yy, Yz = lp(lay.hx, lay.hy, lay.hz)
        local Zx, Zy, Zz = lp(q[4], q[5], q[6])
        local u = max(0, min(1, (ring_u - 0.4) / 0.6))
        local yx = st * sdb + (Yx - st * sdb) * u
        local yy = cdb + (Yy - cdb) * u
        local yz = ct * sdb + (Yz - ct * sdb) * u
        yx, yy, yz = norm3(yx, yy, yz)
        local zx = st * cdb + (Zx - st * cdb) * u
        local zy = -sdb + (Zy + sdb) * u
        local zz = ct * cdb + (Zz - ct * cdb) * u
        local dd = zx * yx + zy * yy + zz * yz
        zx, zy, zz = norm3(zx - yx * dd, zy - yy * dd, zz - yz * dd)
        local xx, xy, xz = cross(yx, yy, yz, zx, zy, zz)
        turn(NAME[col][k], xx, xy, xz, yx, yy, yz, zx, zy, zz)
      end
      if k == K and col % 2 == 0 then
        skirt_x[col], skirt_y[col], skirt_z[col] = fx2, fy2, fz2
      end
    end
  end

  -- the line middles: on the straight line in flight (written only when the
  -- line has moved off its rest place), slack on the ground when down
  local lw_u = lay and fall_u(fall_t, 0, 1.6) or 0 -- (with the skirt, so no kink)
  for g = 0, G - 1 do
    local col = 2 * g
    local mx = rcx + (skirt_x[col] - rcx) * LINE_MID
    local my = rcy + (skirt_y[col] - rcy) * LINE_MID
    local mz = rcz + (skirt_z[col] - rcz) * LINE_MID
    if lay then
      put("L" .. g, settle("L" .. g, mx, my, mz, lw_u))
    else
      local rx0 = RHO_OPEN[K] * SIN_T[col] * LINE_MID
      local ry0 = LR + (Y_OPEN[K] - LR) * LINE_MID
      local rz0 = RHO_OPEN[K] * COS_T[col] * LINE_MID
      -- (a breathing skirt moves a middle by a few cm: not worth a write)
      if abs(mx - rx0) + abs(my - ry0) + abs(mz - rz0) > 0.08 then put("L" .. g, mx, my, mz) end
    end
  end

  -- apex (vent centre) and the pilot chute above it on its bridle
  local apy = ry[1] + APEX_UP
  local pl = PILOT_UP * min(1, 0.4 + stretch)
  if lay then
    local u = fall_u(fall_t, 0.1, 2.0)
    put("Apex", settle("Apex", 0, apy, 0, u))
    put("Pilot", settle("Pilot", 0, apy + pl, 0, u))
    -- the pilot chute ends up mouth-down on the ground, a little tipped
    local Yx, Yy, Yz = norm3(ulx * u, 1 + (uly - 1) * u, ulz * u)
    local hx, hy, hz = lp(lay.hx, lay.hy, lay.hz)
    local zx, zy, zz = norm3(cross(hx, hy, hz, Yx, Yy, Yz))
    local xx, xy, xz = cross(Yx, Yy, Yz, zx, zy, zz)
    turn("Pilot", xx, xy, xz, Yx, Yy, Yz, zx, zy, zz)
  elseif abs(apy - (Y_OPEN[1] + APEX_UP)) > 1e-4 or pl < PILOT_UP - 1e-4 then
    put("Apex", 0, apy, 0)
    put("Pilot", 0, apy + pl, 0)
  end

  -- the lid: blown off down the airflow, tumbling, then gone (parked inside
  -- the canister once it is well clear)
  local age = born and (time - born) or 0
  if not lid0 then lid0 = { fx, fy, fz } end
  if age < 1.6 then
    local sl = 9.0 * age + 7.0 * age * age
    put("Lid", lp(lid0[1] * sl + e1x * age * 1.5 + down_x * 2.0 * age * age,
      lid0[2] * sl + e1y * age * 1.5 + down_y * 2.0 * age * age,
      lid0[3] * sl + e1z * age * 1.5 + down_z * 2.0 * age * age))
    rot("Lid", age * 7.0, age * 11.0, age * 3.0)
  else
    local u = vnode and vnode.valid and vnode.up
    if u then put("Lid", lp(-u.x * 0.2, -u.y * 0.2, -u.z * 0.2)) else put("Lid", lp(down_x * 0.2, down_y * 0.2, down_z * 0.2)) end
  end
  if ids then
    -- (the lists are reused: what a busier frame left past this one's end goes)
    for i = np + 1, bat.np_was do pb[i] = nil end
    for i = 3 * np + 1, 3 * bat.np_was do pv[i] = nil end
    for i = nr + 1, bat.nr_was do rb[i] = nil end
    for i = 3 * nr + 1, 3 * bat.nr_was do rv[i] = nil end
    bat.np_was, bat.nr_was = np, nr
    if np > 0 then anim:setBones(pb, pv, nil) end
    if nr > 0 then anim:setBones(rb, nil, rv) end
    if lay and fall_t >= 3.5 then
      h = bat.held or {}
      bat.held = h
      h[1], h[2], h[3], h[4], h[5], h[6] = ax, ay, az, e1x, e1y, e1z
      h[7], h[8], h[9] = sig_x, sig_y, sig_z
      if lid_u then h[10], h[11], h[12] = lid_u.x, lid_u.y, lid_u.z end
    else
      bat.held = nil
    end
  end
  canopy.writes = nw
  if not node.visible then node.visible = true end
  local ms = (os.clock() - t0) * 1000
  cost.n, cost.ms = cost.n + 1, cost.ms + ms
  canopy.ms = cost.ms / cost.n                       -- over its life
  canopy.ms_now = (canopy.ms_now or ms) + (ms - (canopy.ms_now or ms)) * 0.05 -- lately
end
