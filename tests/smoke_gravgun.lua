-- SMOKE HARNESS for THE GRAVITY GUN — the belt's main tool (scripts/tool_belt.lua).
--
-- What has to hold for it to feel like a gravity gun rather than a teleport:
--   * the catch is a POINT on the object, where the aim hit it, and the pull
--     is a spring-damper force applied AT that point (assembly.forceAt), not
--     through the centre of mass — so an off-centre grab swings and torques;
--   * light things snap to the aim, heavy things can't be lifted: the force is
--     capped by the gun's power budget, and the strain says so;
--   * the scroll wheel sets the hold distance, R throws (an impulse capped by
--     the same budget), and letting go of the trigger drops it;
--   * aimed at a plant, it uproots it (the harvest) instead.
--
-- The physics is a little point-mass integrator below: gravity, the held
-- force, and a floor. Enough to say whether the pull lifts, holds and lets go.
--
--   luajit solar/tests/smoke_gravgun.lua

local T = 0.0
local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end

-- ── the world: a flat patch of a round planet, g = 9.81 at the surface ─────
local R = 1000.0
local G = 9.81
local BODY = { name = "Home", x = 0, y = -R, z = 0, radius = R, mu = G * R * R }

local V = {}
V.__index = V
local function vec3(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, V) end

local store = {}
local API = {
  vec3 = vec3,
  save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
  space = { dominant = function() return BODY.name end,
            body = function(n) return n == BODY.name and BODY or nil end },
  log = function() end, print = function() end,
  audio = { play = function() return { stop = function() end, setVolume = function() end,
                                       setPitch = function() end } end },
  draw = { line = function() end, ring = function() end, disc = function() end, quad = function() end,
           polyline = function() end, circle = function() end, circleOutline = function() end },
  ui = { make = function() end },
  spawnEffect = function() end,
  terrain = { query = function() return 0.5 end, dig = function() end, sculpt = function() end },
}

-- ── the rock: a one-part assembly, a point mass with a grab offset ─────────
local function make_rock(mass, x, y, z)
  local root = { name = "LooseRock", valid = true, id = 50 + math.floor(mass * 100) }
  local part = { name = "Rock", valid = true, parent = root, id = root.id + 1 }
  root.pos = { x = x, y = y, z = z }
  root.vel = { x = 0, y = 0, z = 0 }
  root.mass = mass
  root.forces = {}
  function root:hasTag(t) return t == "loose_rock" end
  function root:toLocal(p) return vec3(p.x - self.pos.x, p.y - self.pos.y, p.z - self.pos.z) end
  function root:toWorld(p) return vec3(self.pos.x + p.x, self.pos.y + p.y, self.pos.z + p.z) end
  root.worldPos = root.pos
  return root, part
end
local ROCKS = {}
local function rock_info(n)
  for _, r in ipairs(ROCKS) do
    if r.root == n then
      local p = n.pos
      return { mass = n.mass, com = vec3(p.x, p.y, p.z), origin = vec3(p.x, p.y, p.z),
               vel = vec3(n.vel.x, n.vel.y, n.vel.z), angVel = vec3(0, 0, 0),
               inertia = { vec3(0.01, 0, 0), vec3(0, 0.01, 0), vec3(0, 0, 0.01) } }
    end
  end
  return nil
end
local forced_at, impulses = {}, {}
API.assembly = {
  info = rock_info,
  forceAt = function(n, f, at)
    n.forces[#n.forces + 1] = { f = f, at = at }
    forced_at[#forced_at + 1] = { n = n, f = f, at = at }
  end,
  torque = function() end,
  impulseAt = function(n, j, at)
    impulses[#impulses + 1] = { n = n, j = j, at = at }
    n.vel.x, n.vel.y, n.vel.z = n.vel.x + j.x / n.mass, n.vel.y + j.y / n.mass, n.vel.z + j.z / n.mass
  end,
}
local function step_physics(dt)
  for _, r in ipairs(ROCKS) do
    local n = r.root
    local fx, fy, fz = 0, -G * n.mass, 0
    for _, f in ipairs(n.forces) do fx, fy, fz = fx + f.f.x, fy + f.f.y, fz + f.f.z end
    n.forces = {}
    n.vel.x = n.vel.x + fx / n.mass * dt
    n.vel.y = n.vel.y + fy / n.mass * dt
    n.vel.z = n.vel.z + fz / n.mass * dt
    n.pos.x, n.pos.y, n.pos.z = n.pos.x + n.vel.x * dt, n.pos.y + n.vel.y * dt, n.pos.z + n.vel.z * dt
    if n.pos.y < 0.3 then                -- the floor (and its friction)
      n.pos.y = 0.3
      if n.vel.y < 0 then n.vel.y = 0 end
      local fr = math.max(0, 1 - 6 * dt)
      n.vel.x, n.vel.z = n.vel.x * fr, n.vel.z * fr
    end
  end
end

-- A ray hits a rock if it passes within 0.35 m of its centre, else the floor.
API.raycast = function(ox, oy, oz, dx, dy, dz, maxd)
  local best, bt = nil, maxd or 1e9
  for _, r in ipairs(ROCKS) do
    local p = r.root.pos
    local t = (p.x - ox) * dx + (p.y - oy) * dy + (p.z - oz) * dz
    if t > 0 and t < bt then
      local qx, qy, qz = ox + dx * t - p.x, oy + dy * t - p.y, oz + dz * t - p.z
      if math.sqrt(qx * qx + qy * qy + qz * qz) < 0.35 then
        best, bt = { x = ox + dx * t, y = oy + dy * t, z = oz + dz * t, nx = 0, ny = 1, nz = 0,
                     distance = t, node = r.part }, t
      end
    end
  end
  if best then return best end
  if dy < -1e-6 then
    local t = -oy / dy
    if t <= (maxd or 1e9) then
      return { x = ox + dx * t, y = 0, z = oz + dz * t, nx = 0, ny = 1, nz = 0, distance = t, node = nil }
    end
  end
  return nil
end

-- ── the crew and the camera ─────────────────────────────────────────────────
local ASTRO = { name = "Astronaut", valid = true, id = 1, x = 0, y = 0.9, z = 0,
                vel = vec3(0, 0, 0), up_x = 0, up_y = 1, up_z = 0 }
ASTRO.tickPos = vec3(0, 0.9, 0)
local CAM = { cam_x = 0, cam_y = 1.8, cam_z = 3.0, fwd_x = 0, fwd_y = 0, fwd_z = -1, valid = true }

-- ── the flora field: one plant to uproot ────────────────────────────────────
local harvested = 0
local FLORA = { valid = true,
  nearestPlant = function(ox, oy, oz, dx, dy, dz)
    -- only when aimed at the plant at (3, 0, -4)
    local px, py, pz = 3, 0.5, -4
    local t = (px - ox) * dx + (py - oy) * dy + (pz - oz) * dz
    local qx, qy, qz = ox + dx * t - px, oy + dy * t - py, oz + dz * t - pz
    if t > 0 and math.sqrt(qx * qx + qy * qy + qz * qz) < 0.6 then
      return { pid = "s:1", x = 3, y = 0, z = -4, ax = px, ay = py, az = pz, height = 1.0, ux = 0, uy = 1, uz = 0,
               rec = { sp = { name = "Ulmash Blade", work = 1.0 } } }
    end
  end,
  harvest = function() harvested = harvested + 1; return { { mat = "fiber", n = 1 } }, 0 end,
}

local GEAR = { gravgun = 1, laser = 1 }
local envs = {
  planet_walker = { valid = true, onFoot = true },
  planet_camera = CAM,
  inventory = { valid = true, gearCount = function(_, id) return GEAR[id] or 0 end, ensureKit = function() end,
                line = function() return "0 / 90 kg" end },
  flora_field = FLORA,
  materials = { valid = true, label = function(m) return m end },
}
API.findScript = function(k) return envs[k] end
API.find = function(n) if n == "Astronaut" then return ASTRO end end

local KEYS = {}
API.input = { button = function() return false end, pressed = function(k) return KEYS[k] == true end,
              scroll = function() return 0 end }

local env = setmetatable({}, { __index = function(_, k)
  if k == "time" then return T end
  return API[k] or _G[k]
end })
local chunk = assert(loadfile("solar/scripts/tool_belt.lua"))
setfenv(chunk, env)
chunk()
env.params = {}
for k, v in pairs(env.defaults) do env.params[k] = v end
local belt = env
belt.start(ASTRO)

local DT = 1 / 60
local function frame(n)
  for _ = 1, (n or 1) do
    T = T + DT
    belt.update(ASTRO, DT)
    belt.fixedUpdate(ASTRO, DT)
    step_physics(DT)
    belt.lateUpdate(ASTRO, DT)
  end
end
local function aim_at(x, y, z)
  local ox, oy, oz = CAM.cam_x, CAM.cam_y, CAM.cam_z
  belt.sim.aim = { ox, oy, oz, x - ox, y - oy, z - oz }
end

belt.sim = { btn = {}, pressed = {} }
frame(2)
ok(belt.toolId() == "gravgun", "the belt opens on the gravity gun [" .. belt.toolId() .. "]")

-- ── 1. A LIGHT ROCK SNAPS UP TO THE AIM ─────────────────────────────────────
local rock, part = make_rock(0.09, 0, 0.3, -5)
ROCKS[1] = { root = rock, part = part }
-- Grab it off-centre: aimed 0.2 m above its middle.
aim_at(0, 0.5, -5)
frame(2)
ok(belt.prompt:find("hold LMB to grab", 1, true) ~= nil, "aimed at a loose rock, the gun offers to grab it [" .. belt.prompt .. "]")
belt.sim.btn[0] = true
frame(1)
ok(belt.holding ~= nil and belt.holding.name == "Loose Rock", "the click catches it")
forced_at = {}
frame(1)
local f1 = forced_at[1]
ok(f1 and math.abs(f1.at.y - (rock.pos.y + 0.2)) < 0.05,
  "the pull is applied AT the grab point, not through the centre [" .. (f1 and string.format("%.2f vs com %.2f", f1.at.y, rock.pos.y) or "none") .. "]")
-- Lift: aim 2 m up.
for _ = 1, 120 do aim_at(0, 2.3, -5); frame(1) end
local hold_y = rock.pos.y + 0.2
ok(math.abs(hold_y - 2.3) < 0.35, string.format("a 90 kg rock is held up at the aim (grab point at %.2f m, aimed at 2.3)", hold_y))
ok(belt.strain < 0.6, string.format("...without straining the gun (strain %.2f)", belt.strain))
-- Swing it sideways: it follows, with a lag, and settles.
for _ = 1, 10 do aim_at(2, 2.3, -5); frame(1) end
local mid_x = rock.pos.x
for _ = 1, 90 do aim_at(2, 2.3, -5); frame(1) end
ok(mid_x > 0.1 and mid_x < 1.9, string.format("swung, it lags behind the aim (%.2f m of 2 after 1/6 s)", mid_x))
ok(math.abs(rock.pos.x - 2) < 0.3, string.format("...and catches up (%.2f)", rock.pos.x))
local speed = math.sqrt(rock.vel.x ^ 2 + rock.vel.y ^ 2 + rock.vel.z ^ 2)
ok(speed < 0.5, string.format("...and settles rather than oscillating (%.2f m/s)", speed))

-- ── 2. SCROLL SETS THE DISTANCE ─────────────────────────────────────────────
local d0 = belt.holding and belt.wantsScroll and true
ok(d0, "holding something, the gun takes the wheel (the camera leaves it alone)")
belt.sim.scroll = 3
frame(1)
local before = math.sqrt((rock.pos.x - ASTRO.x) ^ 2 + (rock.pos.z - ASTRO.z) ^ 2)
for _ = 1, 120 do aim_at(2, 2.3, -5); frame(1) end
local after = math.sqrt((rock.pos.x - ASTRO.x) ^ 2 + (rock.pos.z - ASTRO.z) ^ 2)
ok(after > before + 1.5, string.format("scrolling out pushes it further away (%.1f → %.1f m)", before, after))
belt.sim.scroll = -40
frame(60)
local near = math.sqrt((rock.pos.x - ASTRO.x) ^ 2 + (rock.pos.z - ASTRO.z) ^ 2)
ok(near >= belt.params.grav_min - 0.6, string.format("...and in no nearer than grav_min (%.1f m)", near))

-- ── 3. R THROWS, WITH A CAPPED KICK ─────────────────────────────────────────
impulses = {}
belt.sim.pressed.r = true
frame(1)
ok(#impulses == 1, "R throws: one impulse")
local j = impulses[1] and math.sqrt(impulses[1].j.x ^ 2 + impulses[1].j.y ^ 2 + impulses[1].j.z ^ 2) or 0
ok(math.abs(j - 0.09 * belt.params.grav_throw) < 1e-6, string.format("...of the rock's mass × the throw speed (%.2f)", j))
ok(belt.holding == nil, "...and lets go of it")
frame(5)
ok(belt.holding == nil, "a held trigger after a throw doesn't snatch it straight back")
belt.sim.btn[0] = false
frame(3)

-- ── 4. A HEAVY ONE STRAINS AND STAYS DOWN ───────────────────────────────────
ROCKS = {}
local heavy, hpart = make_rock(2.0, 0, 0.3, -5)
ROCKS[1] = { root = heavy, part = hpart }
aim_at(0, 0.4, -5)
frame(2)
ok(belt.prompt:find("too heavy", 1, true) ~= nil, "aimed at 2 t of rock, the gun says it's too heavy [" .. belt.prompt .. "]")
belt.sim.btn[0] = true
frame(1)
forced_at = {}
for _ = 1, 120 do aim_at(0, 2.3, -5); frame(1) end
ok(heavy.pos.y < 0.35, string.format("2 t is not lifted (%.2f m)", heavy.pos.y))
ok(belt.strain > 1.0, string.format("...the gauge reads overload (%.2f)", belt.strain))
ok(belt.prompt:find("OVERLOAD", 1, true) ~= nil, "...and says so [" .. belt.prompt .. "]")
local worst = 0
for _, f in ipairs(forced_at) do
  worst = math.max(worst, math.sqrt(f.f.x ^ 2 + f.f.y ^ 2 + f.f.z ^ 2))
end
ok(worst <= belt.params.grav_force + 1e-6, string.format("...and the force never passes the power budget (%.2f ≤ %.2f)", worst, belt.params.grav_force))
impulses = {}
belt.sim.pressed.r = true
frame(1)
local jh = impulses[1] and math.sqrt(impulses[1].j.x ^ 2 + impulses[1].j.y ^ 2 + impulses[1].j.z ^ 2) or 0
ok(math.abs(jh - belt.params.grav_throw_max) < 1e-6, string.format("a throw of something heavy is capped (%.2f)", jh))
belt.sim.btn[0] = false
frame(2)

-- ── 5. LETTING GO DROPS IT ──────────────────────────────────────────────────
ROCKS = {}
local r2, p2 = make_rock(0.09, 0, 0.3, -5)
ROCKS[1] = { root = r2, part = p2 }
aim_at(0, 0.4, -5)
frame(30)
belt.sim.btn[0] = true
frame(1)
for _ = 1, 60 do aim_at(0, 2.3, -5); frame(1) end
ok(belt.holding ~= nil and r2.pos.y > 1.2, "picked up again")
belt.sim.btn[0] = false
frame(1)
ok(belt.holding == nil and belt.lastRelease == "trigger up", "releasing the trigger drops it [" .. tostring(belt.lastRelease) .. "]")
frame(90)
ok(r2.pos.y < 0.35, string.format("...and it falls (%.2f m)", r2.pos.y))

-- ── 6. A PLANT IS UPROOTED ──────────────────────────────────────────────────
ROCKS = {}
aim_at(3, 0.5, -4)
frame(2)
ok(belt.prompt:find("uproot", 1, true) ~= nil, "aimed at a plant, the gun offers to uproot it [" .. belt.prompt .. "]")
belt.sim.btn[0] = true
frame(20)
ok(harvested == 0 and belt.progress > 0.1, "holding works it loose, a bit at a time")
frame(60)
ok(harvested == 1, "...and pulls it up: one harvest [" .. harvested .. "]")
frame(30)
ok(harvested == 1, "...and the same held click doesn't take the next one")
belt.sim.btn[0] = false
frame(2)

-- ── 7. AIMED AT THE GROUND, IT SAYS SO ──────────────────────────────────────
aim_at(0, 0, -6)
frame(2)
ok(belt.prompt:find("part of the ground", 1, true) ~= nil, "aimed at bare ground, it says there's nothing loose [" .. belt.prompt .. "]")

if #failures == 0 then
  print("GRAVITY GUN SMOKE OK — " .. checks .. " checks passed")
  os.exit(0)
end
print("GRAVITY GUN SMOKE FAILURES:")
for _, f in ipairs(failures) do print("  \xe2\x9c\x97 " .. f) end
os.exit(1)
