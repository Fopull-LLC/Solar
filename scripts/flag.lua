-- FLAG — one planted flag (prefabs/Flag; docs/crew-and-items.md §7).
--
-- deployables.lua spawns the node and binds it (bind(id, entry, fresh)).
-- This script then:
--
--   * WEARS THE AGENCY'S FLAG. The cloth's texture is emblem.flagTex(); a new
--     name or emblem repaints every planted flag (emblem.version is polled).
--   * WAVES IN THE LOCAL WIND. Four times a second it samples
--     weather.windAt at the pole top, eases toward it, turns the cloth's pivot
--     round the pole so the sheet lies downwind, and hands the speed to the
--     cloth's shader (shaders/flag_cloth.flsl). On an airless world (the
--     save's world.<body>.atmo under 0.05) the cloth hangs straight from its
--     crossbar. Beyond 300 m from the camera it stops sampling.
--   * IS PLANTED. A fresh flag is driven in with two downward pulses (a puff
--     of dust and a thud each), the crew member who planted it salutes for
--     1.5 s, and during the salute a photo is taken from a camera 4 m out at
--     chest height, written to the record's user://flags/<slot>/<id>.jpg.

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end

local me = nil
local id, rec = nil, nil
local pivot, cloth = nil, nil
local base = nil              -- the root's local position when planted (planet frame)
local up_l = nil              -- its up, in the planet frame
local airless = false
local wind = { x = 0, y = 0, z = 0, spd = 0, have = false }
local wind_t = -100
local ver_seen = -1
local cere = nil              -- the planting ceremony while it runs
local settle0 = nil           -- when the airless settle wobble started
local photo_taken = false
local near_cam = true
local FLAG_ORIGIN_M = 0.9425    -- the root above the ground (deployables.FLAG_ORIGIN)

-- For probes.
state = { wind = 0, still = 0, swing = 0, sampled = 0, phase = "idle", photo = nil }

local function child(n, name)
  for _, c in ipairs((n and n.children and n:children()) or {}) do
    if c.name == name then return c end
    local d = child(c, name)
    if d then return d end
  end
  return nil
end

local function norm(x, y, z)
  local l = math.sqrt(x * x + y * y + z * z)
  if l < 1e-9 then return 0, 1, 0, 0 end
  return x / l, y / l, z / l, l
end

local function world_pos(n)
  local p = n:toWorld(vec3(0, 0, 0))
  return p.x, p.y, p.z
end

local function body_airless(b)
  local w = save and save.get and save.get("world." .. tostring(b))
  if type(w) == "table" then return (w.atmo or 0) < 0.05 end
  return false
end

-- Paint the cloth with the agency's flag (when there is one to paint).
local function paint()
  local em = ref("emblem")
  if not (em and cloth and cloth.valid) then return end
  local v = em.version or 0
  if v == ver_seen then return end
  local t = em.flagTex and em.flagTex()
  if t then
    cloth:setMaterial({ texture = t })
    ver_seen = v
  end
end

function bind(i, e, fresh)
  id, rec = i, e
  airless = body_airless(e and e.b)
  if fresh and fresh.ceremony then
    cere = { t0 = time or 0, by = fresh.by, pulses = 0 }
    state.phase = "drive"
  end
  if airless then settle0 = time or 0 end
end

function renamed(name) if rec then rec.n = name end end

local claimed = false
local function try_claim()
  if claimed or not me then return end
  local dep = ref("deployables")
  if not (dep and dep.claim) then return end
  local i, e, f = dep.claim(me)
  if i then claimed = true; bind(i, e, f) end
end

function start(node)
  me = node
  pivot = child(node, "Flag Pivot")
  cloth = child(node, "Flag Cloth")
  if findScript and not findScript("emblem") and spawn then pcall(spawn, "AgencyLib", vec3(0, 0, 0)) end
  -- a few flags never start in step with each other
  if cloth then pcall(cloth.setShaderParam, cloth, "seed", (node.id or 1) % 97 * 0.37) end
end

-- ── wind ────────────────────────────────────────────────────────────────────

local function sample_wind(px, py, pz)
  if airless then wind.have = true; return 0, 0, 0 end
  if not (weather and weather.windAt) then return 0, 0, 0 end
  local ok, v = pcall(weather.windAt, vec3(px, py, pz))
  if not ok or not v then state.windErr = tostring(v); return 0, 0, 0 end
  wind.have = true
  return v.x or 0, v.y or 0, v.z or 0
end

-- For probes: the wind this script reads at its pole top, now.
function windHere()
  if not me then return nil, "no node" end
  local o = me:toWorld(vec3(0, 0, 0))
  local u = me:toWorld(vec3(0, 1, 0)) - o
  local p = o + u:normalized() * 1.2
  local ok, v = pcall(weather.windAt, p)
  local sx, sy, sz = sample_wind(p.x, p.y, p.z)
  return ok and v or nil, tostring(ok) .. " " .. tostring(v) .. string.format(" at %.1f %.1f %.1f | sample %.2f %.2f %.2f airless %s near %s",
    p.x, p.y, p.z, sx, sy, sz, tostring(airless), tostring(near_cam))
end

local function camera_near(px, py, pz)
  local pc = ref("planet_camera")
  local cx, cy, cz = pc and pc.cam_x, pc and pc.cam_y, pc and pc.cam_z
  if not cx then
    local a = find and find("Astronaut")
    if not a then return true end
    cx, cy, cz = a.x, a.y, a.z
  end
  return (px - cx) ^ 2 + (py - cy) ^ 2 + (pz - cz) ^ 2 < 300 * 300
end

local swing_dir = nil   -- the world direction the cloth lies along (eased)

local function wave(dt)
  if not (me and pivot and cloth and pivot.valid and cloth.valid) then return end
  local t = time or 0
  local ux, uy, uz = 0, 1, 0
  do
    local o = me:toWorld(vec3(0, 0, 0))
    local u = me:toWorld(vec3(0, 1, 0)) - o
    ux, uy, uz = norm(u.x, u.y, u.z)
  end
  local px, py, pz = world_pos(me)
  local top_x, top_y, top_z = px + ux * 1.2, py + uy * 1.2, pz + uz * 1.2
  if t - wind_t >= 0.25 then
    wind_t = t
    near_cam = camera_near(px, py, pz)
    if near_cam then
      local wx, wy, wz = sample_wind(top_x, top_y, top_z)
      -- the wind across the ground (the pole is vertical; an updraft only lifts)
      state.raw = string.format("%.2f,%.2f,%.2f", wx, wy, wz)
      local d = wx * ux + wy * uy + wz * uz
      wind.tx, wind.ty, wind.tz = wx - ux * d, wy - uy * d, wz - uz * d
      state.sampled = state.sampled + 1
    end
  end
  if not near_cam then return end
  local tx, ty, tz = wind.tx or 0, wind.ty or 0, wind.tz or 0
  local k = 1 - math.exp(-2.5 * (dt or 0.016))
  wind.x = wind.x + (tx - wind.x) * k
  wind.y = wind.y + (ty - wind.y) * k
  wind.z = wind.z + (tz - wind.z) * k
  local spd = math.sqrt(wind.x ^ 2 + wind.y ^ 2 + wind.z ^ 2)
  wind.spd = spd
  -- Which way the cloth lies: downwind once there is a breeze; with none it
  -- keeps where it was (or where it was planted to face).
  local dx, dy, dz
  if spd > 0.4 and not airless then
    dx, dy, dz = norm(wind.x, wind.y, wind.z)
  end
  if dx then
    if not swing_dir then swing_dir = { dx, dy, dz } end
    local kk = 1 - math.exp(-math.min(1.0, spd / 6) * 3.0 * (dt or 0.016))
    swing_dir[1] = swing_dir[1] + (dx - swing_dir[1]) * kk
    swing_dir[2] = swing_dir[2] + (dy - swing_dir[2]) * kk
    swing_dir[3] = swing_dir[3] + (dz - swing_dir[3]) * kk
  end
  if swing_dir then
    -- keep it in the ground plane, then turn the pivot: its +X along the
    -- wind, which setUp gives with -Z = up × wind
    local sx, sy, sz = swing_dir[1], swing_dir[2], swing_dir[3]
    local d = sx * ux + sy * uy + sz * uz
    sx, sy, sz = norm(sx - ux * d, sy - uy * d, sz - uz * d)
    local fx, fy, fz = uy * sz - uz * sy, uz * sx - ux * sz, ux * sy - uy * sx
    pivot:setUp(vec3(ux, uy, uz), vec3(fx, fy, fz))
    state.swing = math.atan2(sz, sx)
  end
  local settle = 0
  if settle0 then
    local a = t - settle0
    settle = math.max(0, 1 - a / 4.0)
    if settle <= 0 then settle0 = nil end
  end
  pcall(cloth.setShaderParam, cloth, "windSpeed", airless and 0 or spd)
  pcall(cloth.setShaderParam, cloth, "still", airless and 1 or 0)
  pcall(cloth.setShaderParam, cloth, "settle", settle)
  state.wind, state.still = spd, airless and 1 or 0
end

-- ── the planting ceremony ───────────────────────────────────────────────────

local DRIVE = 0.9          -- s: the two pulses
local SALUTE = 1.5         -- s
local PHOTO_AT = 1.1       -- s into the salute (the dust has settled)
local LIFT = 0.36          -- m the pole starts above its seat

local function astro_model()
  local a = find and find("Astronaut")
  if not a then return nil end
  for _, c in ipairs((a.children and a:children()) or {}) do
    if c.name == "AstroModel" then
      return a, c, c.animator and c:animator() or nil
    end
  end
  return a, nil, nil
end

local function take_photo()
  if photo_taken or not (rec and rec.photo) then return end
  photo_taken = true
  if not (camera and camera.capture and spawn) then state.photo = "no camera" return end
  local a = find and find("Astronaut")
  local px, py, pz = world_pos(me)
  local o = me:toWorld(vec3(0, 0, 0))
  local u = me:toWorld(vec3(0, 1, 0)) - o
  local f = me:toWorld(vec3(0, 0, 1)) - o     -- the printed face's side
  local ux, uy, uz = norm(u.x, u.y, u.z)
  local fx, fy, fz = norm(f.x, f.y, f.z)
  local rx, ry, rz = fy * uz - fz * uy, fz * ux - fx * uz, fx * uy - fy * ux
  -- the ground under the flag, then a point 4 m out toward the planter,
  -- a little to the side, at chest height
  local gx, gy, gz = px - ux * FLAG_ORIGIN_M, py - uy * FLAG_ORIGIN_M, pz - uz * FLAG_ORIGIN_M
  local mx, my, mz = gx + ux * 1.25, gy + uy * 1.25, gz + uz * 1.25
  if a then
    mx, my, mz = (mx + a.x) * 0.5, (my + a.y) * 0.5 + 0, (mz + a.z) * 0.5
  end
  -- the planter stands a few metres out on this side: step back past them
  -- and to the side, so the photo has both
  local back = 4.0
  if a then
    local d = (a.x - gx) * fx + (a.y - gy) * fy + (a.z - gz) * fz
    back = math.max(4.0, d + 3.5)
  end
  local cx = gx + fx * back + rx * 2.4 + ux * 1.55
  local cy = gy + fy * back + ry * 2.4 + uy * 1.55
  local cz = gz + fz * back + rz * 2.4 + uz * 1.55
  -- planet-framed (the moving world doesn't run out of shot): spawned under
  -- the planet at its local point, aimed in world space
  local planet = me.parent
  local lx, ly, lz = cx, cy, cz
  if planet and planet.valid then
    local lp = planet:toLocal(vec3(cx, cy, cz))
    lx, ly, lz = lp.x, lp.y, lp.z
  end
  local ok = pcall(spawn, "FlagPhotoCam", vec3(cx, cy, cz), function(cam)
    cam.x, cam.y, cam.z = lx, ly, lz
    cam:lookAt(vec3(mx, my, mz), vec3(ux, uy, uz))
    local path = rec.photo
    local okc, err = pcall(camera.capture, cam, { w = 640, h = 360, format = "jpeg", quality = 88 }, function(bytes, why)
      if bytes and assets and assets.writeBytes then
        local okw, werr = assets.writeBytes(path, bytes)
        state.photo = okw and path or ("write failed: " .. tostring(werr))
        local dep = ref("deployables")
        if okw and dep and dep.setPhoto then dep.setPhoto(id, path) end
      else
        state.photo = "capture failed: " .. tostring(why)
      end
      if cam.valid then cam:destroy() end
    end)
    if not okc then state.photo = "capture refused: " .. tostring(err); cam:destroy() end
  end, (planet and planet.valid) and planet or nil)
  if not ok then state.photo = "no photo camera" end
end

local function ceremony(dt)
  if not (cere and me and base) then return end
  local t = (time or 0) - cere.t0
  local ux, uy, uz = up_l[1], up_l[2], up_l[3]
  if t < DRIVE then
    -- two strokes: up to half way, then home
    local h
    if t < 0.12 then h = LIFT
    elseif t < 0.30 then h = LIFT * (1 - 0.5 * ((t - 0.12) / 0.18) ^ 2)
    elseif t < 0.52 then h = LIFT * 0.5
    elseif t < 0.68 then h = LIFT * 0.5 * (1 - ((t - 0.52) / 0.16) ^ 2)
    else h = 0 end
    me.x, me.y, me.z = base[1] + ux * h, base[2] + uy * h, base[3] + uz * h
    local hits = (t >= 0.30 and 1 or 0) + (t >= 0.68 and 1 or 0)
    while cere.pulses < hits do
      cere.pulses = cere.pulses + 1
      local px, py, pz = world_pos(me)
      local gx, gy, gz = px - ux * 0.94, py - uy * 0.94, pz - uz * 0.94
      if spawnEffect then pcall(spawnEffect, "vfx/TouchDust", vec3(gx, gy, gz), { normal = vec3(ux, uy, uz), scale = 0.22, intensity = 0.5 }) end
      local s = ref("sfx")
      if s and s.playAt then pcall(s.playAt, "land", me, cere.pulses == 2 and 0.9 or 0.6) end
    end
    state.phase = "drive"
    return
  end
  me.x, me.y, me.z = base[1], base[2], base[3]
  if t < DRIVE + SALUTE then
    state.phase = "salute"
    if t >= DRIVE + PHOTO_AT then take_photo() end
    return
  end
  state.phase = "planted"
  cere = nil
  if airless then settle0 = time or 0 end
end

-- The salute: the right hand to the brow, elbow out, while it lasts. After
-- the clips and the walker's own pose (lateUpdate), the planter only — and
-- only if they are still beside the flag.
local function salute_pose()
  if not (cere and state.phase == "salute") then return end
  local a, m, an = astro_model()
  if not (a and m and an and an.boneWorld and an.reach) then return end
  local px, py, pz = world_pos(me)
  if (a.x - px) ^ 2 + (a.y - py) ^ 2 + (a.z - pz) ^ 2 > 25 then return end
  local head = an:boneWorld("Head")
  local sh = an:boneWorld("Upperarm.Right")
  if not (head and sh) then return end
  local o = m:toWorld(vec3(0, 0, 0))
  local U = (m:toWorld(vec3(0, 1, 0)) - o):normalized()
  local F = (m:toWorld(vec3(0, 0, 1)) - o):normalized()
  local Rt = (m:toWorld(vec3(-1, 0, 0)) - o):normalized()
  local t = (time or 0) - cere.t0 - DRIVE
  -- up in 0.3 s, held, down in the last 0.3 s
  local w = math.min(1, t / 0.3, (SALUTE - t) / 0.3)
  if w <= 0 then return end
  local brow = head + U * 0.06 + F * 0.13 + Rt * 0.07
  pcall(an.reach, an, "Hand.Right", brow, { pole = sh + Rt * 0.45 + U * 0.05, weight = w })
end

-- ── the frame ───────────────────────────────────────────────────────────────

function update(node, dt)
  if not claimed then try_claim() end
  if not base then
    base = { node.x, node.y, node.z }
    local ox, oy, oz = node.x, node.y, node.z
    local ux, uy, uz = norm(ox, oy, oz)
    up_l = { ux, uy, uz }
    -- a fresh flag starts raised for its drive
    if cere then node.x, node.y, node.z = ox + ux * LIFT, oy + uy * LIFT, oz + uz * LIFT end
  end
  paint()
  ceremony(dt)
end

-- The wind is read after every script's update: the weather may re-declare
-- its wind cell in its own update, and a read before that sees none.
function lateUpdate(node, dt)
  wave(dt)
  salute_pose()
end
