-- CAVE FLARES — a red road flare, struck and thrown (worlds W4, items.lua
-- `flare`; docs/worlds-and-caves.md §3.6).
--
-- Rationed light is the cheapest dread there is: the helmet torch's battery
-- runs down, the spare cells are counted, and a flare is the light you leave
-- behind you. G on foot, with a flare in the pack, strikes one and throws it
-- the way you look: it arcs under the world's gravity, lands where the rock
-- stops it (terrain rays along its path, a few a frame) and lies there
-- burning for 90 s, a red point light that gutters and flickers, its burning
-- end glowing (node:setTint's emissive on the model's emissive map), a wisp
-- of smoke off it now and then. Then it goes dark and, a minute later, goes.
--
-- POOLED: at most MAX_LIT burn at once (the engine's sixteen lights are
-- shared with the base's floodlights and the lamps); a seventh thrown burns
-- the oldest out early. Each flare is a child of the planet's node, its point
-- held BODY-LOCAL (docs/positions-and-frames.md rule 1: the planet moves
-- metres a tick), its flight integrated in that frame.
--
-- Published (probes): `lit` (count), `thrown` (total), `list()` → the flares'
-- { x, y, z (world), t, lit, landed }; `sim = { throw = true }` throws one.

defaults = {
  --- Throw speed (m/s) along the view, and the extra lift up.
  --@range 2 20
  speed = 9.0,
  --@range 0 8
  lift = 2.5,
  --- Seconds a spent flare lies dark before it is cleared.
  --@range 0 600
  linger = 60.0,
}

MAX_LIT = 6
lit, thrown = 0, 0
sim = nil

local sqrt, max, min = math.sqrt, math.max, math.min
local flares = {}   -- { body, x,y,z, vx,vy,vz, t0, landed, node, light, ux,uy,uz, fx,fy,fz, out }

local refs = {}
local function ref(k)
  local r = refs[k]
  if r and r.valid ~= false then return r end
  r = findScript and findScript(k, { quiet = true }) or nil
  refs[k] = r
  return r
end
local function len(x, y, z) return sqrt(x * x + y * y + z * z) end
local function def()
  local I = ref("items")
  local d = I and I.def and I.def("flare")
  return (d and d.flare) or { secs = 90, range = 14, intensity = 2.6, color = { 1.0, 0.28, 0.12 } }
end
local function pack()
  local C = ref("crew")
  local id = C and C.activeId and C.activeId()
  return id and ("crew:" .. id) or "astro"
end
local function say(s)
  local fx = ref("sfx")
  if fx and fx.caption then pcall(fx.caption, s) elseif caption then pcall(caption, s) end
end

function count()
  local inv = ref("inventory")
  if not (inv and inv.itemCount) then return 0 end
  local ok, n = pcall(inv.itemCount, pack(), "flare")
  return ok and (n or 0) or 0
end

-- as flashlight.lua: on foot, nothing open, not building (G is the Build
-- Kit's symmetry key while it is in the hands)
local function free_hands()
  local pw = ref("planet_walker")
  if not (pw and pw.onFoot == true) then return false end
  local gm = ref("game_manager")
  if gm and (gm.loading or gm.inputOwner == "builder") then return false end
  local pm = ref("pause_menu")
  if pm and pm.open then return false end
  for _, k in ipairs({ "facility_menu", "ops_board", "orbit_map", "context_menu" }) do
    local s = ref(k)
    if s and s.isOpen and s.isOpen() then return false end
  end
  local ip = ref("inventory_panel")
  if ip and ip.open then return false end
  local tb = ref("tool_belt")
  if tb and tb.toolId and tb.toolId() == "buildkit" then return false end
  return true
end

local function burn_out(f)
  f.out = true
  if f.light and f.light.valid then pcall(f.light.destroy, f.light) end
  f.light = nil
  if f.node and f.node.valid and f.node.setTint then pcall(f.node.setTint, f.node, { emissiveStrength = 0 }) end
end
local function clear(i)
  local f = flares[i]
  if f.light and f.light.valid then pcall(f.light.destroy, f.light) end
  if f.node and f.node.valid then pcall(f.node.destroy, f.node) end
  table.remove(flares, i)
end

function throw()
  if count() <= 0 then say("no flares in the pack (the depot sells them)") return false end
  local a = find and find("Astronaut")
  if not (a and a.valid ~= false) then return false end
  local name = space.dominant(a.x, a.y, a.z)
  local b = name and space.body(name)
  local planet = name and find(name)
  if not (b and planet and planet.valid) then return false end
  local inv = ref("inventory")
  if not (inv and inv.removeItem) or (inv.removeItem(pack(), "flare", 1) or 0) < 1 then return false end
  local lx, ly, lz = a.x - b.x, a.y - b.y, a.z - b.z
  local l = len(lx, ly, lz)
  local ux, uy, uz = lx / l, ly / l, lz / l
  local pc = ref("planet_camera")
  local fx, fy, fz = (pc and pc.fwd_x) or 0, (pc and pc.fwd_y) or 0, (pc and pc.fwd_z) or 0
  if len(fx, fy, fz) < 0.5 then fx, fy, fz = 1, 0, 0 end
  local P = params or defaults
  local sp, lift = P.speed or defaults.speed, P.lift or defaults.lift
  local f = { body = name, x = lx + ux * 1.45 + fx * 0.4, y = ly + uy * 1.45 + fy * 0.4, z = lz + uz * 1.45 + fz * 0.4,
              vx = fx * sp + ux * lift, vy = fy * sp + uy * lift, vz = fz * sp + uz * lift, t0 = time, spin = math.random() * 6.28 }
  flares[#flares + 1] = f
  thrown = thrown + 1
  -- the pool: the oldest still burning goes out
  local burning = {}
  for _, g in ipairs(flares) do if not g.out then burning[#burning + 1] = g end end
  if #burning > MAX_LIT then burn_out(burning[1]) end
  createNode("Flare", planet, function(n)
    if f.gone then pcall(n.destroy, n) return end
    f.node = n
    n.model = "models/cave/flare_l0.gltf"
    n.x, n.y, n.z = f.x, f.y, f.z
    n.castShadow = false
    n.tags = { "flare" }
    local d = def()
    if n.setTint then pcall(n.setTint, n, { emissive = d.color, emissiveStrength = 6.0 }) end
    createNode("Flare Light", n, function(ln)
      if f.out or f.gone then pcall(ln.destroy, ln) return end
      f.light = ln
      ln.x, ln.y, ln.z = 0, 0.12, 0
      pcall(ln.setPointLight, ln, { color = d.color, intensity = d.intensity, range = d.range })
    end)
  end)
  if audio and audio.play then pcall(audio.play, "audio/foley/toggle_on.ogg", { track = "SFX", volume = 0.25, pitch = 0.6 }) end
  local n = count()
  say(string.format("flare thrown (%d left)", n))
  return true
end

-- Its flight, body-local: gravity toward the centre, a ray along each step.
local function fly(f, b, dt)
  local g = (b.mu or 0) / max(1, (f.x * f.x + f.y * f.y + f.z * f.z))
  local r = len(f.x, f.y, f.z)
  local steps = 2
  local h = dt / steps
  for _ = 1, steps do
    f.vx, f.vy, f.vz = f.vx - f.x / r * g * h, f.vy - f.y / r * g * h, f.vz - f.z / r * g * h
    local dx, dy, dz = f.vx * h, f.vy * h, f.vz * h
    local d = len(dx, dy, dz)
    if d > 1e-4 then
      local ok, hit = pcall(terrain.raycast, vec3(b.x + f.x, b.y + f.y, b.z + f.z), vec3(dx / d, dy / d, dz / d), d + 0.05)
      if ok and hit and hit.pos then
        local n = hit.normal or vec3(f.x / r, f.y / r, f.z / r)
        f.x, f.y, f.z = hit.pos.x - b.x + n.x * 0.03, hit.pos.y - b.y + n.y * 0.03, hit.pos.z - b.z + n.z * 0.03
        f.landed = true
        f.nx, f.ny, f.nz = n.x, n.y, n.z
        return
      end
      f.x, f.y, f.z = f.x + dx, f.y + dy, f.z + dz
    end
  end
  -- lost (fell off the world or flew for ever): put it out
  if time - f.t0 > 8 then f.landed = true; f.nx, f.ny, f.nz = f.x / r, f.y / r, f.z / r end
end

local function pose(f)
  local n = f.node
  if not (n and n.valid) then return end
  n.x, n.y, n.z = f.x, f.y, f.z
  if not n.setUp then return end
  if f.landed then
    -- lying on its side on the rock: its axis along the surface
    local nx, ny, nz = f.nx, f.ny, f.nz
    local ax, ay, az = 0, 1, 0
    if math.abs(ny) > 0.9 then ax, ay, az = 1, 0, 0 end
    local tx, ty, tz = ay * nz - az * ny, az * nx - ax * nz, ax * ny - ay * nx
    local tl = len(tx, ty, tz)
    tx, ty, tz = tx / tl, ty / tl, tz / tl
    local bx, by, bz = ny * tz - nz * ty, nz * tx - nx * tz, nx * ty - ny * tx
    local c, s = math.cos(f.spin), math.sin(f.spin)
    n:setUp(vec3(tx * c + bx * s, ty * c + by * s, tz * c + bz * s), vec3(nx, ny, nz))
  else
    -- tumbling end over end along its flight
    local v = len(f.vx, f.vy, f.vz)
    if v > 0.1 then
      local k = (time - f.t0) * 9
      local dx, dy, dz = f.vx / v, f.vy / v, f.vz / v
      local r = len(f.x, f.y, f.z)
      local ux, uy, uz = f.x / r, f.y / r, f.z / r
      n:setUp(vec3(dx * math.cos(k) + ux * math.sin(k), dy * math.cos(k) + uy * math.sin(k), dz * math.cos(k) + uz * math.sin(k)), vec3(ux, uy, uz))
    end
  end
end

function list()
  local out = {}
  for _, f in ipairs(flares) do
    local b = space.body(f.body)
    if b then out[#out + 1] = { x = b.x + f.x, y = b.y + f.y, z = b.z + f.z, t = time - f.t0, lit = not f.out, landed = f.landed == true } end
  end
  return out
end

function update(node, dt)
  dt = dt or 0
  local press = false
  if sim and sim.throw then sim.throw = nil; press = true end
  if not press and input and input.pressed and input.pressed("g") and free_hands() then press = true end
  if press then throw() end
  local d = def()
  local secs = d.secs or 90
  lit = 0
  for i = #flares, 1, -1 do
    local f = flares[i]
    local b = space.body(f.body)
    local age = time - f.t0
    if not b or age > secs + ((params and params.linger) or defaults.linger) then
      f.gone = true
      clear(i)
    else
      if not f.landed then fly(f, b, dt) end
      pose(f)
      if not f.out then
        if age > secs then
          burn_out(f)
        else
          lit = lit + 1
          -- it gutters: a flicker on a slow sputter, and it dies over its last 6 s
          local fade = min(1, (secs - age) / 6)
          local k = (0.78 + 0.22 * math.sin(age * 23.0 + f.spin) * math.sin(age * 7.3)) * fade
          if math.random() < 0.04 then k = k * 0.55 end
          local l = f.light and f.light.valid and f.light:getcomponent("PointLight")
          if l then
            pcall(function() l.intensity = (d.intensity or 2.6) * k end)
            if not f.shadowed then f.shadowed = true; pcall(function() l.shadows = 0 end) end
          end
          if f.node and f.node.valid and f.node.setTint then pcall(f.node.setTint, f.node, { emissiveStrength = 6.0 * k }) end
          if spawnEffect and f.landed and time - (f.puff or 0) > 1.3 then
            f.puff = time
            pcall(spawnEffect, "SmokePuff", vec3(b.x + f.x, b.y + f.y, b.z + f.z),
              { normal = vec3(f.nx or 0, f.ny or 1, f.nz or 0), intensity = 0.25, scale = 0.35, tint = { 1.0, 0.55, 0.5 } })
          end
        end
      end
    end
  end
end

function onDestroy(node)
  for i = #flares, 1, -1 do clear(i) end
end
