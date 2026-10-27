-- VFX — the effects director. Every physical effect in the game goes through
-- here, so the rules below are written once instead of at forty call sites.
--
--     local v = findScript("vfx")
--     if v then v.explode(x, y, z, vx, vy, vz, true) else spawnEffect("Explosion", x, y, z) end
--
-- Callers keep a plain `spawnEffect` fallback: a harness or a scene with no
-- VFX node is a game with plainer effects, not a broken one. The effects
-- themselves are data in vfx/*.vfx.ron, written by tools/gen_vfx.py.
--
-- ── THE FRAME ───────────────────────────────────────────────────────────────
--
-- The world you stand on orbits its star at ~90 m/s. Since engine v0.112 an
-- effect fired with `spawnEffect(key, pos, opts)` rides the planet whose
-- sphere of influence it is in: its emit point and every particle it made move
-- with the ground, on the same clock, so nothing drifts or jitters. Two rules
-- follow, and both are easy to get wrong:
--
--   * `opts.vel` is RELATIVE to that planet — and so is every velocity
--     physics reports (assembly.info's vel, node.vel): a body in a planet's
--     sphere of influence is simulated in that planet's frame and CARRIED
--     along its rails (node.carry), so its velocity never holds the planet's.
--     Taking the planet's velocity off again (as this script did until
--     2026-10-26) threw every spark, smoke puff and piece of debris off at
--     the world's orbital speed — ~180 m/s on the home world — so they were
--     gone in a frame, and pointed the reentry plasma along the orbit instead
--     of into the airflow. (Adding it, as the pre-0.112 workaround did, was
--     the same mistake the other way.)
--   * `opts.normal` is the effect's +Y: a cone fires off the surface, a ring
--     lies on it, and Field gravity still points at the planet.
--
-- What is still a node: the engine plumes (on the engine parts), the laser's
-- beam and impact, the launch blast (one looping node per planet, parented to
-- it so it rides it), the reentry plasma (follows the craft) and a few flash
-- lights.
--
-- A craft's own feedback — jet exhaust, engine and reentry heat glow, tyre
-- marks and dust, knocks and shorting parts — is scripts/vehicle_fx.lua
-- (docs/vfx-feedback.md). This script spawns its node, and hands it what
-- the vessel tells this one: each burning engine (flame), the reentry
-- heating (heat) and a scrape (scrape).

defaults = {
  --- Master switch for everything this script adds (callers fall back to
  --- their plain one-shots when it is off).
  on = true,
  --- Burn marks: 1 = decals (ride the planet since v0.112), 2 = paint them
  --- into the terrain (permanent), 0 = none.
  scorch = 1,
  --- Seconds a burn mark lasts before it fades (0 = for good).
  scorch_life = 600,
}

local sqrt = math.sqrt
local function len(x, y, z) return sqrt(x * x + y * y + z * z) end
local function norm(x, y, z)
  local l = len(x, y, z)
  if l < 1e-9 then return 0, 1, 0 end
  return x / l, y / l, z / l
end

local now = 0
local spawned = 0                -- one-shots fired (stats)
local vfx2 = { ref = nil, asked = false }   -- scripts/vehicle_fx.lua
local function vehicle_fx()
  local r = vfx2.ref
  if r and r.valid then return r end
  r = findScript and findScript("vehicle_fx") or nil
  if not r and not vfx2.asked and spawn then
    vfx2.asked = true
    pcall(spawn, "VehicleFx", vec3(0, 0, 0))
  end
  vfx2.ref = r
  return r
end
local lights = {}                -- live flashes
local engines = {}               -- flame node id → state, refreshed every frame by flame()
local smolders = {}              -- uid → last reported position and velocity
local pads = {}                  -- body name → { node, t }
local lightpool = {}             -- body name → { nodes, next }
local reentry = nil
local laser = { chip_t = 0, scorch_t = 0 }
local swim = { depth = nil, wake_t = 0, bubble_t = 0 }
local climate_ref = nil

-- ── where a point is ────────────────────────────────────────────────────────
local function body_at(x, y, z)
  if not (space and space.dominant) then return nil end
  local name = space.dominant(x, y, z)
  local b = name and space.body(name)
  if not b then return nil end
  return name, b
end

local function world_of(name)
  return name and save and save.get and save.get("world." .. name) or nil
end

-- The air at a point, 0 (vacuum) … 1 — the same reading atmosphere.lua makes.
local function air_at(x, y, z, name, b)
  if not name then name, b = body_at(x, y, z) end
  local w = world_of(name)
  if not (b and w and (w.atmo or 0) > 0.01) then return 0 end
  local alt = len(x - b.x, y - b.y, z - b.z) - (b.radius or 1)
  local h = (w.atmoHeight or 0)
  if h <= 0 then h = (b.radius or 100) * 0.35 end
  local t = 1.0 - math.max(0.0, math.min(1.0, alt / (h * 1.6)))
  return t * t * math.max(0.0, math.min(1.0, w.atmo or 0))
end

-- name, body, the planet's up at the point, the air there.
local function frame(x, y, z)
  local name, b = body_at(x, y, z)
  if not b then return nil, nil, 0, 1, 0, 0 end
  local ux, uy, uz = norm(x - b.x, y - b.y, z - b.z)
  return name, b, ux, uy, uz, air_at(x, y, z, name, b)
end

-- A velocity physics reports, for an effect: already relative to the planet
-- whose frame the body rides (see THE FRAME above), so it passes as it is.
local function rel(b, vx, vy, vz)
  if not vx then return nil end
  return vec3(vx, vy, vz)
end

-- Dust takes the colour of the ground it comes off: the generator's surface
-- colour for the world, relative to the neutral tan the effects are authored in.
local DUST = { 0.72, 0.64, 0.54 }
local tints = {}
local function dust_tint(name)
  if not name then return nil end
  if tints[name] ~= nil then return tints[name] or nil end
  local w = world_of(name)
  local g = w and w.ground
  local t = false
  if g and g[1] then
    -- Only part of the way: a dust cloud is paler than the rock it is made of.
    local r = 0.45 + 0.55 * g[1] / DUST[1]
    local gg = 0.45 + 0.55 * g[2] / DUST[2]
    local bb = 0.45 + 0.55 * g[3] / DUST[3]
    local m = math.max(r, gg, bb)
    if m > 1.25 then r, gg, bb = r * 1.25 / m, gg * 1.25 / m, bb * 1.25 / m end
    t = { r, gg, bb }
  end
  tints[name] = t
  return t or nil
end

-- THE one-shot. `o` may carry normal (default: the planet's up), vel (relative
-- to the planet — see rel()), intensity, scale, dust (tint to the ground).
local function fire(key, x, y, z, o)
  o = o or {}
  local name, b, ux, uy, uz = frame(x, y, z)
  local opts = {
    normal = o.normal or vec3(ux, uy, uz),
    intensity = o.intensity,
    scale = o.scale,
  }
  opts.vel = o.vel
  if o.dust then opts.tint = dust_tint(name) end
  spawned = spawned + 1
  spawnEffect(key, vec3(x, y, z), opts)
end

-- The same, for vehicle_fx.lua (and any other caller): a one-shot in the
-- planet's frame. `o.vel` is RELATIVE to the planet here.
function emit(key, x, y, z, o) fire(key, x, y, z, o) end
-- A world's dust colour (nil: the authored tan).
function dustTint(name) return dust_tint(name) end

-- ── light flashes: a few PointLight nodes per planet, parented to it ────────
-- A keyed envelope { {t, v}, ... } at time `t`, linear between keys, 0 outside.
local function envelope(keys, t)
  if t <= keys[1][1] or t >= keys[#keys][1] then return 0 end
  for i = 2, #keys do
    local b = keys[i]
    if t < b[1] then
      local a = keys[i - 1]
      return a[2] + (b[2] - a[2]) * (t - a[1]) / (b[1] - a[1])
    end
  end
  return 0
end

local function light_pool(name)
  local p = lightpool[name]
  if p then return p end
  p = { nodes = {}, next = 1 }
  lightpool[name] = p
  local bn = find(name)
  if bn and spawn then
    for _ = 1, 6 do
      spawn("FxLight", bn.worldPos, function(n) p.nodes[#p.nodes + 1] = n end, bn)
    end
  end
  return p
end

-- Put a node parented to planet `name` at a world point.
local function place_on(n, name, x, y, z)
  local bn = find(name)
  local w = bn and bn.worldPos
  if not w then return end
  n.x, n.y, n.z = x - w.x, y - w.y, z - w.z
end

-- `shape`, if given, is the light's envelope over its life: keys
-- { {seconds, 0..1}, ... } played linearly (weather.lua's lightning FLASH);
-- without it the light starts at full and falls off over `life`.
function flash(x, y, z, r, g, b, intensity, range, life, shape)
  local name = body_at(x, y, z)
  local p = name and light_pool(name)
  if not p or #p.nodes == 0 then return end
  local n = p.nodes[p.next]
  p.next = p.next % #p.nodes + 1
  if not (n and n.valid ~= false) then return end
  place_on(n, name, x, y, z)
  local l = n:getcomponent("PointLight")
  if not l then return end
  l.r, l.g, l.b, l.range, l.intensity = r, g, b, range, intensity
  lights[n] = { n = n, l = l, i0 = intensity, t0 = now, life = life, shape = shape }
  if shape then l.intensity = 0 end
end

-- ── burn marks ──────────────────────────────────────────────────────────────
-- A mark is a decal (decals.add). The engine keeps it on the ground: dig or
-- re-mesh the ground under it and it is laid again on the surface there, or
-- goes if nothing is left to lie on (engine 0.117.0-rc6, card 0464), and it
-- rides its planet. What is left for this script:
--   * a fade with distance, before the drawn terrain coarsens: a decal lies
--     on the collider's full-detail faces, and from far enough the drawn
--     ground is a coarser LOD, so the mark would float over or sink under
--     it. Faded by its alpha only; a mark is never lifted and laid again, so
--     it stays where the engine re-laid it;
--   * a lifetime, faded at its end.
local MARK_MAX = 160          -- tracked marks; the oldest goes first
local marks = {}              -- array of { id, body, ox, oy, oz, size, alpha, t0, life, vis }
local mark_fade_t = 0
local cam_x, cam_y, cam_z = nil, nil, nil

local function mark_world(m)
  local b = space.body(m.body)
  if not b then return nil end
  return b.x + m.ox, b.y + m.oy, b.z + m.oz, b
end

-- How much of the mark shows from the camera: 1 near, 0 past its range. The
-- range grows with the mark (a crater scar is seen further than a laser burn)
-- but stays inside the full-detail terrain ring.
local function mark_vis(m, x, y, z)
  local v = 1
  if cam_x then
    local d = len(x - cam_x, y - cam_y, z - cam_z)
    local near = math.min(140, 35 + m.size * 9)
    local far = near * 1.5
    v = 1 - math.max(0, math.min(1, (d - near) / (far - near)))
  end
  local age = now - m.t0
  if m.life and age > m.life - 15 then v = v * math.max(0, (m.life - age) / 15) end
  return math.floor(v * 8 + 0.5) / 8   -- in eighths: a set only when it steps
end

local function mark_drop(i)
  local m = marks[i]
  if m.id then decals.remove(m.id) end
  table.remove(marks, i)
end

local function scorch(x, y, z, nx, ny, nz, radius, strength, tex, life)
  local mode = params.scorch or 1
  if mode == 2 and terrain and terrain.paint then
    terrain.paint(x, y, z, radius, 0.07, 0.06, 0.05, strength or 0.5)
  elseif mode == 1 and decals and decals.add then
    local name, b = body_at(x, y, z)
    if not b then return end
    local m = { body = name, ox = x - b.x, oy = y - b.y, oz = z - b.z, size = radius * 2,
      alpha = strength or 0.8, t0 = now, life = life or params.scorch_life }
    if (m.life or 0) <= 0 then m.life = nil end
    m.vis = mark_vis(m, x, y, z)
    local ok, id = pcall(decals.add, { texture = tex or "textures/vfx/decal/scorch.png", pos = vec3(x, y, z),
      normal = vec3(nx, ny, nz), size = m.size, rotation = math.random() * 6.283, alpha = m.alpha * m.vis })
    if not (ok and id) then return end   -- nothing there to take it
    m.id = id
    while #marks >= MARK_MAX do mark_drop(1) end
    marks[#marks + 1] = m
  end
end

local function marks_tick()
  if #marks == 0 or not (decals and decals.set) then return end
  -- Distance and age fade, four times a second: a set only when a mark's
  -- eighth changes (each set re-packs that picture's batch).
  if now - mark_fade_t < 0.25 then return end
  mark_fade_t = now
  local ok, w, hh = pcall(camera.screenSize)
  if ok and w and w > 0 then
    local ok2, ox, oy, oz = pcall(camera.screenToRay, w * 0.5, hh * 0.5)
    if ok2 and ox then cam_x, cam_y, cam_z = ox, oy, oz end
  end
  local i = 1
  while i <= #marks do
    local m = marks[i]
    local x, y, z = mark_world(m)
    if (m.life and now - m.t0 > m.life) or not x then
      mark_drop(i)
    else
      local v = mark_vis(m, x, y, z)
      -- false: the engine took it (the ground under it dug away, or the
      -- decal budget pushed it out). Forget it.
      if v ~= m.vis and not decals.set(m.id, { alpha = m.alpha * v }) then
        table.remove(marks, i)
      else
        m.vis = v
        i = i + 1
      end
    end
  end
end

-- What the marks are doing, for probes.
function markStats()
  local laid, hidden = 0, 0
  for _, m in ipairs(marks) do
    if m.id then laid = laid + 1 end
    if (m.vis or 1) <= 0 then hidden = hidden + 1 end
  end
  return { tracked = #marks, laid = laid, hidden = hidden }
end

-- Every tracked mark's centre where it was LAID, for probes (the engine may
-- since have re-laid it lower, on ground dug from under it).
function markList()
  local out = {}
  for _, m in ipairs(marks) do
    local x, y, z = mark_world(m)
    if x then out[#out + 1] = { x = x, y = y, z = z, laid = m.id ~= nil, size = m.size } end
  end
  return out
end

-- ════════════════════════════════════════════════════════════════════════════
-- THE CALLS (positions are world points; velocities as physics reports them:
-- relative to the planet whose frame the body rides)
-- ════════════════════════════════════════════════════════════════════════════

-- A craft or part blowing up. `big` = a tank or engine (fuel), else a strut.
function explode(x, y, z, vx, vy, vz, big)
  local name, b, ux, uy, uz, air = frame(x, y, z)
  -- In air the fire and smoke stop with the air; in vacuum they keep the
  -- wreck's momentum, because there is nothing to stop them.
  local k = 0.25 + 0.75 * (1 - math.min(1, air * 2))
  local v = rel(b, vx, vy, vz)
  -- Born a little off the ground so the fireball is not half buried.
  local sd = terrain and terrain.query and terrain.query(x, y, z)
  local lift = (sd and sd < 1.5) and (1.5 - sd) or 0
  fire(big and "Explosion" or "ExplosionSmall", x + ux * lift, y + uy * lift, z + uz * lift,
    { vel = v and vec3(v.x * k, v.y * k, v.z * k) })
  flash(x + ux * 2, y + uy * 2, z + uz * 2, 1.0, 0.62, 0.3, big and 40 or 16, big and 45 or 22, big and 1.4 or 0.8)
  -- the part itself coming apart: shards of plate and skin (the explosion's
  -- own debris is rock, thrown out of the ground)
  fire("PartDebris", x, y, z, { vel = v, intensity = big and 1.4 or 1.0 })
  if sd and sd < (big and 7 or 4) then
    local gx, gy, gz = x - ux * sd, y - uy * sd, z - uz * sd
    fire("GroundShock", gx + ux * 0.3, gy + uy * 0.3, gz + uz * 0.3, { intensity = big and 1.3 or 0.7, dust = true })
    scorch(gx, gy, gz, ux, uy, uz, big and 4.5 or 2.4, big and 0.9 or 0.7)
  end
end

-- A decoupler, a dock latch, a joint snapping.
function separate(x, y, z, vx, vy, vz)
  local _, b, _, _, _, air = frame(x, y, z)
  -- In air the gas puff is caught by it; in vacuum it keeps the craft's motion.
  local k = 1 - math.min(1, air * 2) * 0.6
  local v = rel(b, vx, vy, vz)
  fire("SepPuff", x, y, z, { vel = v and vec3(v.x * k, v.y * k, v.z * k) })
  flash(x, y, z, 1.0, 0.85, 0.6, 5, 9, 0.25)
end

-- The chute mortar firing (rides the craft's motion).
function chute(x, y, z, vx, vy, vz)
  local _, b = body_at(x, y, z)
  fire("ChutePuff", x, y, z, { vel = rel(b, vx, vy, vz) })
end

-- A hull grinding on the ground: sparks carry the hull's motion, dust stays.
function scrape(x, y, z, vx, vy, vz)
  local _, b = body_at(x, y, z)
  fire("Sparks", x, y, z, { vel = rel(b, vx, vy, vz) })
  fire("ScrapeDust", x, y, z, { dust = true })
  -- and a gouge left where it bit (the pad as well as the ground)
  local v2 = vehicle_fx()
  if v2 and v2.scuff then v2.scuff(x, y, z, vx, vy, vz) end
end

-- Landing legs (or a hull) meeting the ground at `speed` m/s.
function touchdown(x, y, z, speed)
  fire("TouchDust", x, y, z, { intensity = math.max(0.4, math.min(2.0, (speed or 3) / 5)), dust = true })
end

-- A damaged part smouldering: refreshed every so often by the vessel; puffs
-- are laid along its path between refreshes so the trail is continuous.
function smolder(uid, x, y, z, vx, vy, vz)
  local s = smolders[uid] or { next = 0 }
  local name, b = body_at(x, y, z)
  if not b then return end
  local v = rel(b, vx or 0, vy or 0, vz or 0)
  -- Kept relative to the planet: it moves on between reports.
  s.x, s.y, s.z, s.vx, s.vy, s.vz, s.t, s.body = x - b.x, y - b.y, z - b.z, v.x, v.y, v.z, now, name
  smolders[uid] = s
end

-- Rock or ore breaking free: chunks off the face, a glint, dust.
function oreBreak(x, y, z, nx, ny, nz)
  local o = { dust = true }
  if nx then o.normal = vec3(nx, ny, nz) else nx, ny, nz = select(3, frame(x, y, z)) end
  fire("OreBreak", x + nx * 0.1, y + ny * 0.1, z + nz * 0.1, o)
  flash(x + nx * 0.4, y + ny * 0.4, z + nz * 0.4, 0.9, 0.95, 1.0, 2.5, 5, 0.2)
end

-- The spade biting: clods up off the ground.
function dig(x, y, z, raise)
  local _, _, ux, uy, uz = frame(x, y, z)
  fire("DigClods", x + ux * 0.2, y + uy * 0.2, z + uz * 0.2, { intensity = raise and 0.7 or 1.2, dust = true })
end

-- The cutter biting into a stem (every frame while cutting is fine — gated).
local cut_t = 0
function cut(x, y, z)
  if now - cut_t < 0.09 then return end
  cut_t = now
  fire("CutChips", x, y, z)
end

-- Something going into the pack from (x,y,z): a bright mote with a streak
-- thrown at the crew at (tx,ty,tz), arriving in about 0.4 s. The throw is a
-- velocity relative to the planet both stand on, so it is simply the gap.
function collect(x, y, z, tx, ty, tz)
  local dx, dy, dz = tx - x, ty - y, tz - z
  local d = len(dx, dy, dz)
  if d < 0.05 then return end
  local k = 1 / 0.42
  fire("Collect", x, y, z, { vel = vec3(dx * k, dy * k, dz * k), normal = vec3(dx / d, dy / d, dz / d) })
end

-- A plant coming down.
function harvest(x, y, z, height)
  local _, _, ux, uy, uz = frame(x, y, z)
  local h = math.min(3.0, (height or 1.5) * 0.6)
  fire("PlantFall", x + ux * h, y + uy * h, z + uz * h)
end

-- A boot hitting dusty ground (the walker's origin is ~0.62 m over its soles).
function step(x, y, z, speed)
  local name, b, ux, uy, uz = frame(x, y, z)
  local w = world_of(name)
  -- Lush worlds have soil and grass underfoot, not powder.
  if w and (w.kind == "ocean" or w.kind == "jungle") then return end
  fire("StepDust", x - ux * 0.62, y - uy * 0.62, z - uz * 0.62, { dust = true })
end

-- Spray off a breaking wave: (vx,vy,vz) is the throw, relative to the ground.
function spray(x, y, z, vx, vy, vz)
  local s = len(vx or 0, vy or 0, vz or 0)
  local o = { intensity = math.max(0.5, math.min(1.8, s / 3)) }
  if s > 0.1 then o.normal = vec3(vx / s, vy / s, vz / s) end
  fire("SeaSpray", x, y, z, o)
end

-- Something broke the water surface at (x,y,z): spray, foam ring.
function splash(x, y, z, strength)
  local _, _, ux, uy, uz = frame(x, y, z)
  fire("SeaSpray", x, y, z, { intensity = math.min(2, 0.6 + (strength or 1) * 0.6) })
  fire("WaterRing", x + ux * 0.08, y + uy * 0.08, z + uz * 0.08,
    { intensity = math.min(2, 0.6 + (strength or 1) * 0.5) })
end

-- ── the rocket engine ───────────────────────────────────────────────────────
-- Called by the vessel for every "Engine Flame" child every frame it decides
-- whether that engine burns. `pct` is the throttle.
local function vac_of(f)
  local par = f.parent
  if par then
    for _, c in ipairs(par:children()) do
      if c.name == "Engine Flame Vac" then return c end
    end
  end
  return false   -- false, not nil: looked, there is none
end

function flame(f, live, pct)
  if not (f and f.valid ~= false) then return end
  local par = f.parent
  local id = f.__id or f
  local st = engines[id]
  if not st then
    st = { f = f }
    engines[id] = st
  end
  if st.vac == nil then st.vac = vac_of(f) end
  st.live, st.pct, st.t = live, pct or 0, now
  local w = f.worldPos
  st.air = w and air_at(w.x, w.y, w.z) or 1
  local base = 0.25 + (pct or 0) * 1.25
  -- Sea-level flame by air, vacuum bell by its absence; a mix in between,
  -- which is what a rising rocket actually shows.
  local a = math.min(1, st.air * 2.5)
  local ps = f:particles()
  if ps then
    if live and a > 0.04 then
      if not ps:isPlaying() then ps:play() end
      ps:setIntensity(base * (0.35 + 0.65 * a))
    elseif ps:isPlaying() then
      ps:stop()
    end
  end
  local vac = st.vac
  local vp = vac and vac.valid ~= false and vac:particles()
  if vp then
    if live and a < 0.96 then
      if not vp:isPlaying() then vp:play() end
      vp:setIntensity(base * (1 - a))
    elseif vp:isPlaying() then
      vp:stop()
    end
  end
  -- The nozzle light breathes with the flame instead of sitting still.
  local light = f:getcomponent("PointLight")
  if light then
    light.intensity = live and (0.8 + (pct or 0) * 4.0) * (0.85 + 0.3 * math.random()) or 0.0
  end
  -- The bell's heat, its light-off and shut-down (vehicle_fx.lua).
  local v2 = vehicle_fx()
  if v2 and v2.burn and par then v2.burn(par, live, pct, st.air, f) end
end

-- Exhaust smoke left in the air, and the blast where the plume meets the ground.
local function pad_node(name)
  local p = pads[name]
  if not p then
    p = {}
    pads[name] = p
    local bn = find(name)
    if bn and spawn then spawn("FxPadBlast", bn.worldPos, function(n) p.node = n end, bn) end
  end
  return p
end

local puff_t = {}
local function engines_tick()
  local lowest = {}   -- body → the live plume nearest the ground this frame
  for id, st in pairs(engines) do
    local f = st.f
    if not (f and f.valid ~= false) or now - (st.t or 0) > 1.0 then
      engines[id] = nil
    elseif st.live and (st.pct or 0) > 0.03 and now - st.t < 0.2 then
      -- The plume's axis: the flame node sits on the nozzle axis, offset from
      -- its engine part along it.
      local w, par = f.worldPos, f.parent
      local pw = par and par.worldPos
      if w and pw and len(w.x - pw.x, w.y - pw.y, w.z - pw.z) > 1e-3 then
        local dx, dy, dz = norm(w.x - pw.x, w.y - pw.y, w.z - pw.z)
        local name, b, ux, uy, uz = frame(w.x, w.y, w.z)
        if (st.air or 0) > 0.06 and now - (puff_t[id] or 0) > 0.09 then
          puff_t[id] = now
          local s = 2.5 + 3.0 * st.pct
          fire("ExhaustPuff", w.x + dx * s, w.y + dy * s, w.z + dz * s,
            { intensity = math.min(1.6, 0.4 + st.air * 1.5) })
        end
        local sd = b and terrain and terrain.query and terrain.query(w.x, w.y, w.z)
        local down = -(dx * ux + dy * uy + dz * uz)   -- 1 = plume straight down
        if sd and sd < 26 and down > 0.35 then
          local reach = sd / down
          local cur = lowest[name]
          if not cur or reach < cur.reach then
            lowest[name] = { reach = reach, sd = sd, pct = st.pct, x = w.x + dx * reach, y = w.y + dy * reach,
              z = w.z + dz * reach, ux = ux, uy = uy, uz = uz }
          end
        end
      end
    end
  end
  for name, g in pairs(lowest) do
    local p = pad_node(name)
    local n = p.node
    if n and n.valid ~= false then
      place_on(n, name, g.x + g.ux, g.y + g.uy, g.z + g.uz)
      -- +Y up: the cloud rolls out along the ground.
      local tx, ty, tz = 0, 0, 1
      if math.abs(g.uz) > 0.9 then tx, ty, tz = 1, 0, 0 end
      n.yaw, n.pitch, n.roll = lookRotation(vec3(tx, ty, tz), vec3(g.ux, g.uy, g.uz))
      local ps = n:particles()
      if ps then
        if not ps:isPlaying() then
          ps:play()
          local t = dust_tint(name)
          if t then ps:setTint(t[1], t[2], t[3]) end
        end
        local k = math.max(0, 1 - g.sd / 26)
        ps:setIntensity((0.3 + 1.2 * g.pct) * k * k * 1.6)
      end
      p.t = now
    end
  end
  -- No engine over a blast any more: stop feeding it and let the cloud go.
  for name, p in pairs(pads) do
    local n = p.node
    if not lowest[name] and n and n.valid ~= false then
      local ps = n:particles()
      if ps and ps:isPlaying() then
        if now - (p.t or 0) < 6 then ps:setIntensity(0) else ps:stop() end
      end
    end
  end
end

-- ── reentry ─────────────────────────────────────────────────────────────────
-- The vessel reports its heating every frame it is in the hot band; the
-- plasma node is put on the craft's leading face in lateUpdate.
function heat(vnode, glow, vx, vy, vz)
  if not (vnode and vnode.valid ~= false) then return end
  -- the hull cooking and the wake behind it (vehicle_fx.lua)
  local v2 = vehicle_fx()
  if v2 and v2.reentry then v2.reentry(vnode, glow, vx, vy, vz) end
  reentry = reentry or {}
  local r = reentry
  r.v, r.glow, r.vx, r.vy, r.vz, r.t = vnode, glow, vx, vy, vz, now
  if not r.fx and not r.asked and spawn then
    r.asked = true
    spawn("FxReentry", vnode.worldPos, function(n) r.fx = n end)
  end
end

local function reentry_tick()
  local r = reentry
  if not (r and r.fx and r.fx.valid ~= false) then return end
  local ps = r.fx:particles()
  if not (now - (r.t or -9) < 0.3 and r.v and r.v.valid ~= false) then
    if ps and ps:isPlaying() then
      if now - (r.t or 0) < 1.5 then ps:setIntensity(0) else ps:stop() end
    end
    return
  end
  local w = r.v.worldPos
  local _, b = body_at(w.x, w.y, w.z)
  local a = rel(b, r.vx, r.vy, r.vz)
  local s = len(a.x, a.y, a.z)
  if s < 1 then return end
  local dx, dy, dz = a.x / s, a.y / s, a.z / s
  r.fx.x, r.fx.y, r.fx.z = w.x + dx * 1.6, w.y + dy * 1.6, w.z + dz * 1.6
  local tx, ty, tz = 0, 0, 1
  if math.abs(dz) > 0.9 then tx, ty, tz = 1, 0, 0 end
  r.fx.yaw, r.fx.pitch, r.fx.roll = lookRotation(vec3(tx, ty, tz), vec3(-dx, -dy, -dz))
  if ps then
    if not ps:isPlaying() then ps:play() end
    ps:setIntensity(math.min(2.0, 0.2 + r.glow * 2.2))
  end
end

-- ── the mining laser ────────────────────────────────────────────────────────
-- tool_belt places the Laser Impact node on the hit each frame and hands the
-- state over: power (charge), heat and focus, all 0..1.
function laserHit(impact, hit, power, hotness, focus)
  if not (impact and hit) then return end
  local _, _, ux, uy, uz = frame(hit.x, hit.y, hit.z)
  local nx, ny, nz = hit.nx or ux, hit.ny or uy, hit.nz or uz
  -- Off the surface, so the molten core is not half inside the rock, and
  -- turned so its sparks fountain off the face (gravity still pulls them down).
  local ox, oy, oz = 0, 0, 0
  local pw = impact.parent and impact.parent.worldPos
  if pw then ox, oy, oz = pw.x, pw.y, pw.z end
  impact.x, impact.y, impact.z = hit.x + nx * 0.12 - ox, hit.y + ny * 0.12 - oy, hit.z + nz * 0.12 - oz
  local tx, ty, tz = 0, 0, 1
  if math.abs(nz) > 0.9 then tx, ty, tz = 1, 0, 0 end
  impact.yaw, impact.pitch, impact.roll = lookRotation(vec3(tx, ty, tz), vec3(nx, ny, nz))
  local ps = impact:particles()
  if ps then ps:setIntensity(0.3 + power * (0.8 + 0.5 * (hotness or 0)) + 0.3 * (focus or 0)) end
  local light = impact:getcomponent("PointLight")
  if light then
    -- Hotter optics → a whiter, harder light; a flicker so it reads as fire.
    local h = hotness or 0
    light.r, light.g, light.b = 1.0, 0.6 + 0.25 * h, 0.28 + 0.4 * h
    light.intensity = (2.0 + power * 7.0) * (0.8 + 0.4 * math.random())
  end
  -- Spalled chips, faster as the cut goes in.
  if power > 0.15 and now - laser.chip_t > 0.2 - 0.12 * power then
    laser.chip_t = now
    fire("LaserChips", hit.x + nx * 0.1, hit.y + ny * 0.1, hit.z + nz * 0.1,
      { normal = vec3(nx, ny, nz), intensity = 0.7 + 0.4 * (focus or 0), dust = true })
  end
  -- A burn where it has been cutting.
  if power > 0.6 and now - laser.scorch_t > 0.45 then
    laser.scorch_t = now
    scorch(hit.x, hit.y, hit.z, nx, ny, nz, 0.35 + 0.4 * (hotness or 0), 0.5, "textures/vfx/decal/scorch_b.png", 240)
  end
end

-- ── swimming: bubbles under, wake on top ────────────────────────────────────
-- Is the crew ON FOOT? vessel_controller's `crewOnFoot` (aboard no craft), not
-- `astronaut.visible`: the camera hides the body in first person (no wake
-- while swimming in first person) and an open Command Seat keeps its rider in
-- view (a rover in a ford trailed swim bubbles). Any controller answers for
-- every craft; with none in the scene, nobody is aboard.
local onfoot = { ref = nil, t = -10.0 }
local function crew_on_foot()
  if not (onfoot.ref and onfoot.ref.valid) and time - onfoot.t > 0.5 then
    onfoot.t = time
    onfoot.ref = findScript("vessel_controller")
  end
  local r = onfoot.ref
  if r and r.valid and r.crewOnFoot then return r.crewOnFoot() == true end
  return true
end

local function swim_tick()
  local a = find("Astronaut")
  if not (a and crew_on_foot()) then return end
  local name, b = body_at(a.x, a.y, a.z)
  if not b then return end
  if not (climate_ref and climate_ref.valid) then climate_ref = findScript("climate") end
  local seaR = climate_ref and climate_ref.seaRadius and climate_ref.seaRadius(name) or 0
  local w = world_of(name)
  if not seaR or seaR <= 0 or (w and w.frozen) then swim.depth = nil; return end
  local rx, ry, rz = a.x - b.x, a.y - b.y, a.z - b.z
  local r = len(rx, ry, rz)
  local ux, uy, uz = rx / r, ry / r, rz / r
  local depth = seaR - r          -- feet below the surface
  local vx, vy, vz = a.vx or 0, a.vy or 0, a.vz or 0   -- (planet-relative, see THE FRAME)
  local vr = vx * ux + vy * uy + vz * uz
  local spd = len(vx - ux * vr, vy - uy * vr, vz - uz * vr)
  local sx, sy, sz = b.x + ux * seaR, b.y + uy * seaR, b.z + uz * seaR
  -- Climbing out: water streaming off.
  if swim.depth and swim.depth > 0.4 and depth <= 0.4 and vr > 0.8 then splash(sx, sy, sz, 0.4) end
  swim.depth = depth
  if depth > 0.4 and depth < 2.2 and spd > 0.6 and now - swim.wake_t > 0.16 then
    swim.wake_t = now
    fire("Wake", sx, sy, sz)
  end
  if depth > 1.7 and now - swim.bubble_t > (spd > 0.6 and 0.35 or 1.1) then
    swim.bubble_t = now
    fire("Bubbles", a.x + ux * 1.55, a.y + uy * 1.55, a.z + uz * 1.55)
  end
end

-- ════════════════════════════════════════════════════════════════════════════
function update(node, dt)
  now = time or (now + dt)
  if params.on == false then return end
  if not vfx2.asked then vehicle_fx() end
  engines_tick()
  -- Smouldering parts: a puff every so often along the extrapolated path
  -- (velocity relative to the planet, so the path is the one you see).
  for uid, s in pairs(smolders) do
    local age = now - s.t
    if age > 0.9 then
      smolders[uid] = nil
    elseif now >= s.next then
      s.next = now + 0.14
      local b = space.body(s.body)
      if b then
        local px, py, pz = b.x + s.x + s.vx * age, b.y + s.y + s.vy * age, b.z + s.z + s.vz * age
        if air_at(px, py, pz) > 0.03 then fire("SmokePuff", px, py, pz) end
      end
    end
  end
  swim_tick()
end

function lateUpdate(node, dt)
  if params.on == false then return end
  reentry_tick()
  marks_tick()
  for k, f in pairs(lights) do
    local u = (now - f.t0) / f.life
    if u >= 1 or not (f.n and f.n.valid ~= false) then
      if f.l then f.l.intensity = 0 end
      lights[k] = nil
    else
      f.l.intensity = f.i0 * (f.shape and envelope(f.shape, now - f.t0) or (1 - u) * (1 - u))
    end
  end
end

-- What the director is doing, for probes and the perf readout.
function stats()
  local out = { spawned = spawned, lights = 0, engines = 0 }
  for _ in pairs(lights) do out.lights = out.lights + 1 end
  for _ in pairs(engines) do out.engines = out.engines + 1 end
  return out
end
