-- UNDERGROUND — what it is like under the rock (2026-11-10: "no creepy
-- atmospheres").
--
-- A cave in this game is any space the ground closes round you: a natural
-- one, a ravine's overhang, a tunnel the laser bored. This script decides
-- how enclosed the crew is, from the ground itself, and lets the rest of the
-- game make it feel like it:
--
--   ENCLOSURE   terrain rays from the crew's eye, a few a frame round-robin:
--               five toward the sky (straight up and four tipped 40° off it)
--               and six level ones. `sky` is the share of the sky rays the
--               rock stops within `reach`, `walls` the share of level ones that
--               meet rock within `wall`; `enclosed` (0..1, eased, published) is
--               mostly the sky, firmed up by the walls, so an overhang outdoors
--               reads a little and a chamber reads fully. `cave` turns on at
--               0.6 and off at 0.4 (hysteresis: it never flickers at a mouth).
--               Terrain only: a base building's roof is not a cave.
--   DARKNESS    no sky light reaches in. The scene's ambient (the weather's,
--               or the scene's own on an airless world) is scaled down to
--               `ambientFloor` of itself as `enclosed` rises; written only
--               while it still holds what this script last wrote, so the
--               weather's own writes stay the base. atmosphere.lua darkens the
--               haze inside and suit.lua lights the helmet lamps underground
--               whatever the hour.
--   MOTES       dust hanging in the air ahead of the eye (vfx/CaveMotes), lit
--               billboards fired with their normal turned away from the star,
--               so only the lamps light them (a lit billboard takes the sun
--               with no shadow; its effect's up decides its day side). In
--               vacuum, fewer.
--   MIST        on a world with damp air, cold mist lying along the floor
--               (vfx/CaveMist), the same trick.
--   DRIPS       on a wet world, a drop now and then from the roof near you
--               (vfx/CaveDrip) and its plink when it lands (the fall's time
--               later), in the cave's reverb.
--   SOUND       a cave's room tone (low, close), and every half minute or so a
--               creak of rock settling or a deep groan of the mountain with a
--               trickle of grit, off to one side. In vacuum there is no air to
--               carry any of it: only the groans, faint and muffled, through
--               the boots. (The suit's breathing and fans rise as the world
--               goes quiet: soundscape.lua.)
--
-- Cost: two terrain rays a frame, an ambient write, a spawnEffect every
-- second or two while underground; nothing at all on the surface but the rays.
--
-- Cross-script:
--   local ug = findScript("underground")
--   ug.enclosed   0..1, eased          ug.cave   bool (hysteresis)
--   ug.sky, ug.walls                   the raw shares (probes)

defaults = {
  on = true,
  --- How far (m) a sky ray looks for rock overhead.
  --@range 5 120
  reach = 45.0,
  --- How far (m) a level ray looks for a wall.
  --@range 2 40
  wall = 12.0,
  --- Rays cast a frame (of the eleven).
  --@range 1 11
  raysPerFrame = 2,
  --- The share of the ambient left in a full cave.
  --@range 0 1
  ambientFloor = 0.07,
  --- Motes, mist and drips.
  effects = true,
  --- The cave's sounds.
  sound = true,
  --@range 0 1
  toneGain = 0.32,
  --@range 0 1
  creakGain = 0.5,
  --@range 0 1
  dripGain = 0.45,
  debug = false,
}

enclosed, cave, sky, walls = 0.0, false, 0.0, 0.0

local sqrt, max, min = math.sqrt, math.max, math.min
local function clamp01(x) return max(0.0, min(1.0, x)) end
local function smooth(a, b, x)
  local t = clamp01((x - a) / (b - a))
  return t * t * (3 - 2 * t)
end

-- ── pure: the enclosure from the ray answers (tests/smoke_underground.lua) ──
-- skyHits/skyN: sky rays that met rock; wallHits/wallN: level rays that did.
function enclosure(skyHits, skyN, wallHits, wallN)
  local s = skyN > 0 and skyHits / skyN or 0
  local w = wallN > 0 and wallHits / wallN or 0
  return smooth(0.35, 0.95, s) * (0.45 + 0.55 * w), s, w
end
-- The cave flag with hysteresis.
function caveFlag(was, e)
  if was then return e > 0.4 end
  return e > 0.6
end
-- The ambient multiplier for an enclosure.
function ambientScale(e, floor)
  floor = floor or 0.07
  return 1.0 - (1.0 - floor) * clamp01(e)
end

-- ── the scene ───────────────────────────────────────────────────────────────
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if r and r.valid then return r end
  r = findScript and findScript(kind) or nil
  refs[kind] = r
  return r
end

-- the eleven rays in the crew's frame: (along up, along north, along east)
local DIRS = {}
do
  DIRS[1] = { 1, 0, 0 }
  local c, s = math.cos(math.rad(40)), math.sin(math.rad(40))
  for k = 0, 3 do
    local a = k * math.pi / 2 + 0.4
    DIRS[#DIRS + 1] = { c, s * math.cos(a), s * math.sin(a) }
  end
  for k = 0, 5 do
    local a = k * math.pi / 3
    DIRS[#DIRS + 1] = { 0.0, math.cos(a), math.sin(a) }
  end
end
local SKY_N = 5
local hits = {}       -- ray index → true/false (last answer)
local next_ray = 1
local amb = { base = nil, wrote = nil }
local fx_t = { motes = -10, mist = -10, drip = nil }
local snd = { tone = nil, tone_v = 0, next_creak = nil, drip_at = nil, drip_lp = 0 }
local dbg_t = -10

local function crew_eye()
  local a = find and find("Astronaut")
  if not (a and a.valid ~= false) then return nil end
  local wk = ref("planet_walker")
  if wk and wk.onFoot == false then return nil end
  local name = space.dominant(a.x, a.y, a.z)
  local b = name and space.body(name)
  if not b or (b.soi or 0) < 0 then return nil end
  local ux, uy, uz = a.x - b.x, a.y - b.y, a.z - b.z
  local l = sqrt(ux * ux + uy * uy + uz * uz)
  if l < 1 then return nil end
  ux, uy, uz = ux / l, uy / l, uz / l
  return a.x + ux * 1.6, a.y + uy * 1.6, a.z + uz * 1.6, ux, uy, uz, name, b
end

-- a tangent frame round up
local function tangents(ux, uy, uz)
  local ax, ay, az = 0, 1, 0
  if math.abs(uy) > 0.9 then ax, ay, az = 1, 0, 0 end
  local nx, ny, nz = ay * uz - az * uy, az * ux - ax * uz, ax * uy - ay * ux
  local l = sqrt(nx * nx + ny * ny + nz * nz)
  nx, ny, nz = nx / l, ny / l, nz / l
  local ex, ey, ez = uy * nz - uz * ny, uz * nx - ux * nz, ux * ny - uy * nx
  return nx, ny, nz, ex, ey, ez
end

local function cast(i, ex, ey, ez, ux, uy, uz, nx, ny, nz, wx, wy, wz)
  local d = DIRS[i]
  local dx = ux * d[1] + nx * d[2] + wx * d[3]
  local dy = uy * d[1] + ny * d[2] + wy * d[3]
  local dz = uz * d[1] + nz * d[2] + wz * d[3]
  local far = (i <= SKY_N) and (params.reach or 45) or (params.wall or 12)
  local ok, h = pcall(terrain.raycast, vec3(ex, ey, ez), vec3(dx, dy, dz), far)
  hits[i] = ok and h ~= nil and (h.distance or 0) > 0.05 or false
end

-- ── darkness: the ambient, scaled while we are the last to write it ────────
local function light()
  local ln = find and find("Lighting")
  return ln and ln:getcomponent("Light") or nil
end
local function near(a, b) return a and b and math.abs(a - b) <= 1e-5 + 1e-4 * math.abs(b) end
local function darken(k)
  local l = light()
  if not l then return end
  local r, g, b = l.ambientR or 0, l.ambientG or 0, l.ambientB or 0
  local w = amb.wrote
  if not (w and near(r, w[1]) and near(g, w[2]) and near(b, w[3])) then amb.base = { r, g, b } end
  if not amb.base then return end
  if k >= 0.9999 then
    if w then l.ambientR, l.ambientG, l.ambientB = amb.base[1], amb.base[2], amb.base[3] end
    amb.wrote = nil
    return
  end
  local nr, ng, nb = amb.base[1] * k, amb.base[2] * k, amb.base[3] * k
  l.ambientR, l.ambientG, l.ambientB = nr, ng, nb
  amb.wrote = { l.ambientR or nr, l.ambientG or ng, l.ambientB or nb }
end

-- ── the effects ────────────────────────────────────────────────────────────
local function world_of(name) return save and save.get and save.get("world." .. name) or nil end
local function damp(w)
  if not w then return 0 end
  local m = w.climMoist or ((w.sea or 0) > 0 and 0.6) or 0.25
  if w.kind == "ice" or w.kind == "frost" then m = max(m, 0.5) end
  if w.kind == "lava" or w.kind == "dune" or w.kind == "barren" then m = m * 0.4 end
  return clamp01(m)
end
-- the star's direction from a point (for the "night side" normal)
local function away_from_star(x, y, z, ux, uy, uz)
  local at = ref("atmosphere")
  local E = ref("electronics")
  local s = E and E.sunOf and E.sunOf(x, y, z, space.bodies() or {}) or nil
  if s then
    local dx, dy, dz = x - s.x, y - s.y, z - s.z
    local l = sqrt(dx * dx + dy * dy + dz * dz)
    if l > 1 then return dx / l, dy / l, dz / l end
  end
  return -ux, -uy, -uz
end

local function effects(ex, ey, ez, ux, uy, uz, name, b, air, w)
  if params.effects == false or not spawnEffect then return end
  local pc = ref("planet_camera")
  local fx, fy, fz = (pc and pc.fwd_x) or 0, (pc and pc.fwd_y) or 0, (pc and pc.fwd_z) or 0
  local nx, ny, nz = away_from_star(ex, ey, ez, ux, uy, uz)
  local vac = air < 0.03
  -- motes, a little ahead of the eye
  if time - fx_t.motes > (vac and 3.0 or 1.5) then
    fx_t.motes = time
    pcall(spawnEffect, "CaveMotes", vec3(ex + fx * 2.4, ey + fy * 2.4, ez + fz * 2.4),
      { normal = vec3(nx, ny, nz), intensity = vac and 0.6 or 1.0 })
  end
  local dm = damp(w)
  if not vac and dm > 0.3 and time - fx_t.mist > 3.2 then
    fx_t.mist = time
    pcall(spawnEffect, "CaveMist", vec3(ex - ux * 1.45 + fx * 2.5, ey - uy * 1.45 + fy * 2.5, ez - uz * 1.45 + fz * 2.5),
      { normal = vec3(nx, ny, nz), intensity = 0.6 + 0.6 * dm })
  end
  -- a drop from the roof, and its sound when it lands
  if not vac and dm > 0.35 then
    if not fx_t.drip then fx_t.drip = time + 3 + math.random() * 8 end
    if time >= fx_t.drip then
      fx_t.drip = time + (3 + math.random() * 9) / (0.5 + dm)
      local tx, ty, tz, sx, sy, sz = tangents(ux, uy, uz)
      local a, r = math.random() * 6.283, 1.0 + math.random() * 3.0
      local px = ex + (tx * math.cos(a) + sx * math.sin(a)) * r
      local py = ey + (ty * math.cos(a) + sy * math.sin(a)) * r
      local pz = ez + (tz * math.cos(a) + sz * math.sin(a)) * r
      local ok, h = pcall(terrain.raycast, vec3(px, py, pz), vec3(ux, uy, uz), 14)
      if ok and h and h.pos and (h.distance or 0) > 0.2 then
        local hx, hy, hz = h.pos.x - ux * 0.05, h.pos.y - uy * 0.05, h.pos.z - uz * 0.05
        pcall(spawnEffect, "CaveDrip", vec3(hx, hy, hz), { normal = vec3(ux, uy, uz) })
        local g = (b.mu or 0) / max(1, (b.radius or 1) ^ 2)
        local fall = (h.distance or 2) + 1.6
        snd.drip_at = time + sqrt(2 * fall / max(0.5, g))
      end
    end
  end
end

-- ── the sound ──────────────────────────────────────────────────────────────
local TONE = "audio/ambience/cave_tone.ogg"
local DRIPS = { "audio/ambience/cave_drip_1.ogg", "audio/ambience/cave_drip_2.ogg",
                "audio/ambience/cave_drip_3.ogg", "audio/ambience/cave_drip_4.ogg" }
local CREAKS = { "audio/ambience/cave_creak_1.ogg", "audio/ambience/cave_creak_2.ogg", "audio/ambience/cave_creak_3.ogg" }
local GROANS = { "audio/ambience/cave_groan_1.ogg", "audio/ambience/cave_groan_2.ogg" }
local function play(clip, o)
  if audio and audio.play then local ok, h = pcall(audio.play, clip, o); return ok and h or nil end
end
local function sounds(dt, air)
  if params.sound == false then return end
  local vac = air < 0.03
  local want = (params.toneGain or 0.32) * smooth(0.25, 0.9, enclosed) * (vac and 0.25 or 1.0)
  snd.tone_v = snd.tone_v + (want - snd.tone_v) * min(1, dt * 0.8)
  if snd.tone_v > 0.004 then
    if not snd.tone then snd.tone = play(TONE, { track = "Ambient", loop = true, volume = 0, mode = "Flat" }); snd.tone_lp = 0 end
    if snd.tone then
      snd.tone:setVolume(snd.tone_v)
      local lp = vac and 300 or 0
      if lp ~= snd.tone_lp then snd.tone_lp = lp; snd.tone:setLowpass(lp) end
    end
  elseif snd.tone then
    snd.tone:stop(); snd.tone = nil
  end
  if cave then
    if not snd.next_creak then snd.next_creak = time + 8 + math.random() * 14 end
    if time >= snd.next_creak then
      snd.next_creak = time + 18 + math.random() * 32
      local groan = vac or math.random() < 0.4
      local list = groan and GROANS or CREAKS
      play(list[math.random(1, #list)], { track = "SFX", mode = "Flat", pan = (math.random() * 2 - 1) * 0.8,
        volume = (params.creakGain or 0.5) * (vac and 0.35 or (0.6 + 0.4 * math.random())), lowpass = vac and 380 or 0 })
    end
  else
    snd.next_creak = nil
  end
  if snd.drip_at and time >= snd.drip_at then
    snd.drip_at = nil
    play(DRIPS[math.random(1, #DRIPS)], { track = "SFX", mode = "Flat", pan = (math.random() * 2 - 1) * 0.6,
      volume = (params.dripGain or 0.45) * (0.5 + 0.5 * math.random()), pitch = 0.9 + 0.2 * math.random() })
  end
end

function start(node)
  if audio and audio.preload then
    local list = { TONE }
    for _, l in ipairs({ DRIPS, CREAKS, GROANS }) do for _, c in ipairs(l) do list[#list + 1] = c end end
    pcall(audio.preload, list)
  end
end

function update(node, dt)
  dt = dt or 0
  if params.on == false then enclosed, cave = 0, false; darken(1.0); return end
  local ex, ey, ez, ux, uy, uz, name, b = crew_eye()
  local target = 0
  if ex and terrain and terrain.raycast then
    local nx, ny, nz, wx, wy, wz = tangents(ux, uy, uz)
    for _ = 1, min(#DIRS, math.floor(params.raysPerFrame or 2)) do
      cast(next_ray, ex, ey, ez, ux, uy, uz, nx, ny, nz, wx, wy, wz)
      next_ray = next_ray % #DIRS + 1
    end
    local sh, wh = 0, 0
    for i = 1, #DIRS do
      if hits[i] then if i <= SKY_N then sh = sh + 1 else wh = wh + 1 end end
    end
    target, sky, walls = enclosure(sh, SKY_N, wh, #DIRS - SKY_N)
  else
    hits = {}
  end
  -- in quickly (stepping in under the roof), out a little slower
  local k = 1 - math.exp(-(target > enclosed and 2.0 or 1.2) * dt)
  enclosed = enclosed + (target - enclosed) * k
  if enclosed < 1e-3 and target == 0 then enclosed = 0 end
  cave = caveFlag(cave, enclosed)
  local air = 0
  if name then
    local vx = ref("vfx")
    air = (vx and vx.airAt and vx.airAt(ex, ey, ez)) or 0
  end
  if cave and ex then effects(ex, ey, ez, ux, uy, uz, name, b, air, world_of(name)) end
  sounds(dt, air)
  if params.debug and time - dbg_t > 1 then
    dbg_t = time
    print(string.format("underground: enclosed %.2f (sky %.2f walls %.2f) cave %s air %.2f", enclosed, sky, walls, tostring(cave), air))
  end
end

-- After the weather has written this frame's ambient (its update).
function lateUpdate(node, dt)
  if params.on == false then return end
  darken(ambientScale(enclosed, params.ambientFloor))
end

function onDestroy(node)
  if snd.tone then snd.tone:stop() end
  darken(1.0)
end
