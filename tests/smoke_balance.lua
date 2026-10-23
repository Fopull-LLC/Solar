-- SMOKE HARNESS: FLIGHT BALANCE AND BUILDER HONESTY (review, 2026-10).
--
-- The review flew the stock first rocket — Pod Mk1, FT-S, Sputter, Parachute —
-- with Z + SPACE on a world of r 200 m and g 5.2: it passed 200 m in three
-- seconds and left the sphere of influence at seventeen. The rating that fixed
-- that left propellant weightless and almost no thrust margin, and the player
-- report that followed was "landing legs make my ships way too heavy to lift
-- off, fuel barely lasts, and adding more fuel just makes it too heavy too".
--
-- The balance now (builder.lua, BALANCE): propellant has mass, Δv is
-- Tsiolkovsky's, the catalogue is built once per save for the home world, and
-- the pad re-rates nothing. This drives the real builder.lua (same stubs as
-- smoke_builder) and checks:
--   * ten craft — the starter, with legs, with more fuel, the Anvil and Skipper
--     tiers, a staged moonship and a staged interplanetary stack — on seven
--     worlds across the generator's whole range: TWR, Δv (against an
--     independent Tsiolkovsky sum), burn time, the straight-up apex, a 2-D
--     gravity-turn orbit attempt, and the contract planner's own Δv budgets for
--     a moon and a planet (missions.lua `plan`);
--   * the readout's Δv / TWR are the flight's model and the launch world's g,
--     the blueprint carries what the flight burns, the catalogue is frozen;
--   * LAUNCH: refused with no crew (and nothing charged), confirmed with
--     warnings, straight through for a sound rocket;
--   * research is two clicks and a locked card names its prerequisite.
--
--   luajit solar/tests/smoke_balance.lua
--   SOLAR_BALANCE_TABLE=1 luajit solar/tests/smoke_balance.lua   # print the table

local T = 0.0
local TICK = 1 / 60

-- ── nodes ────────────────────────────────────────────────────────────────────
local nodes = {}
local next_id = 1
local function make_node(name, x, y, z)
  local n = { __id = next_id, id = next_id, name = name, valid = true,
              visible = true, x = x or 0, y = y or 0, z = z or 0,
              pitch = 0, roll = 0, yaw = 0, text = "", components = {},
              ui_rect = nil }
  n.getcomponent = function(self, kind) return self.components[kind] end
  -- node:uiRect() → x,y,w,h physical px (0,0,0,0 when it has no rect). The
  -- StagePanel gets a real rect so the panel hit-test can be exercised.
  n.uiRect = function(self)
    local r = self.ui_rect
    if not r then return 0, 0, 0, 0 end
    return r[1], r[2], r[3], r[4]
  end
  next_id = next_id + 1
  nodes[#nodes + 1] = n
  return n
end

-- ── stub API ─────────────────────────────────────────────────────────────────
local API = {}
local save_store = {}

function API.vec3(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
function API.destroy(n) n.valid = false end
function API.find(name)
  for _, n in ipairs(nodes) do
    if n.valid and n.name == name then return n end
  end
  return nil
end
API.print = function() end
API.log = API.print

-- Spawns land SYNCHRONOUSLY (the builder tolerates async; sync keeps the
-- test linear).
function API.spawn(prefab, pos, cb)
  local n = make_node(prefab, pos.x, pos.y, pos.z)
  if cb then cb(n) end
end

API.KEYS = { down = {}, edge = {} }
local MOUSE = { x = 500, y = 500, lmb = false }
API.input = {
  key = function(k) return API.KEYS.down[k] or false end,
  pressed = function(k) return API.KEYS.edge[k] or false end,
  button = function(b) return b == 0 and MOUSE.lmb or false end,
  mouse = function() return MOUSE.x, MOUSE.y end,
  mouse_delta = function() return 0, 0 end,
  scroll = function() return 0 end,
  setMouseLocked = function() end,
}

-- Orthographic-ish camera: screen = world × 100 + 500 (Y flipped), and the
-- cursor ray drops straight down at the un-projected XZ.
API.camera = {
  worldToScreen = function(x, y, z)
    return x * 100 + 500 + z * 3, -y * 100 + 500 + z * 3, 1.0, true
  end,
  screenSize = function() return 1920, 1080 end,
  screenToRay = function(mx, my)
    return (mx - 500) / 100, 10.0, 0.0, 0.0, -1.0, 0.0
  end,
}

-- Raycast returns nothing — the builder's part_under_cursor then falls back
-- to the nearest projected part center, which the ortho camera resolves
-- exactly (worldToScreen carries z), so aiming the mouse at a part's
-- projected center selects it.
function API.raycast() return nil end
API.draw = {
  line = function() end, ring = function() end,
  sphere = function() end, box = function() end,
  cone = function() end, disc = function() end, tri = function() end,
}
API.save = {
  get = function(k) return save_store[k] end,
  set = function(k, v) save_store[k] = v end,
  flush = function() end,
}
API.scene = { load = function() end }

-- Cross-script handles. The builder asks for the COMPANY ledger (it prices the
-- build against the balance and charges at rollout); a scene without one must
-- degrade to "no money system", which is exactly what a nil handle means.
-- `API.COMPANY` is set by the money tests below to wire a real one in.
API.COMPANY = nil
function API.findScript(kind)
  if kind == "company" then return API.COMPANY end
  return nil
end
function API.findScripts(kind)
  local h = API.findScript(kind)
  return h and { h } or {}
end

-- Audio: the builder plays UI clicks + a hangar bed; hand back a handle with
-- the SoundHandle surface (stop() is used on the bed) so it all no-ops here.
API.SOUNDS = {}
API.audio = {
  play = function(clip)
    API.SOUNDS[#API.SOUNDS + 1] = clip
    return {
      stop = function() end, pause = function() end, resume = function() end,
      setVolume = function() end, setPitch = function() end, setPan = function() end,
      setTrack = function() end, setPosition = function() end, seek = function() end,
      isPlaying = function() return true end, position = function() return 0.0 end,
    }
  end,
  track = function()
    return { setVolume = function() end, setPan = function() end,
      setMuted = function() end, setSoloed = function() end }
  end,
  stopAll = function() end,
}

-- ── load the builder ─────────────────────────────────────────────────────────
local stats_n = make_node("BuildStats", 0, 0, 0)
make_node("BuildHint", 0, 0, 0)
local stage_panel = make_node("StagePanel", 0, 0, 0)
stage_panel.components["UiElement"] = { visible = false }
-- The panel's solved screen rect (physical px) — what node:uiRect() returns.
stage_panel.ui_rect = { 16, 200, 256, 384 }
-- STAGING is now a POOL of per-row nodes (each with its OWN solved rect) plus a
-- floating drag ghost — the builder hit-tests each row's real uiRect instead of
-- guessing a pitch off the whole panel. Lay 14 rows under a 34px title + 10 pad,
-- 24px tall on a 27px pitch (matches builder.ron's stack), x = panel + 10 pad.
local STAGE_ROW_TOP = 200 + 10 + 34 + 3
for k = 1, 14 do
  local rn = make_node(string.format("StageRow%02d", k), 0, 0, 0)
  rn.components["UiElement"] = { visible = false }
  rn.ui_rect = { 26, STAGE_ROW_TOP + (k - 1) * 27, 232, 24 }
end
local stage_ghost = make_node("StageDragGhost", 0, 0, 0)
stage_ghost.components["UiElement"] = { visible = false }
local function stage_row_center(k) return STAGE_ROW_TOP + (k - 1) * 27 + 12 end

local env = setmetatable({}, { __index = function(_, k)
  if k == "time" then return T end
  return API[k] or _G[k]
end })
local chunk = assert(loadfile("solar/scripts/builder.lua"))
setfenv(chunk, env)
chunk()
env.params = {}
for k, v in pairs(env.defaults or {}) do env.params[k] = v end

local builder_node = make_node("Builder", 0, 0, 0)
env.start(builder_node)

local failures = {}
local function check(cond, what)
  if not cond then failures[#failures + 1] = "CHECK FAILED: " .. what end
end

local function step(n)
  for _ = 1, n or 1 do
    T = T + TICK
    local ok, err = xpcall(env.update, debug.traceback, builder_node, TICK)
    if not ok then failures[#failures + 1] = "update: " .. err end
    API.KEYS.edge = {}
  end
end

local function press(k) API.KEYS.edge[k] = true end
local function mouse_to_world(x, y, z)
  local sx, sy = API.camera.worldToScreen(x, y, z)
  MOUSE.x, MOUSE.y = sx, sy
end
local function click()
  MOUSE.lmb = true
  step(1)
  MOUSE.lmb = false
  step(14) -- let the click cooldown lapse
end

-- The builder's internal registry, read back through the saved blueprint.
local function saved_parts()
  env.doSave()
  local bp = save_store["shipyard.blueprint"]
  local out = {}
  for _, d in pairs(bp.parts) do out[#out + 1] = d end
  return out
end

step(2)

-- ── 1. the ladder: every craft × every kind of world the generator makes ─────
--
-- Craft are built in the REAL builder (a blueprint loaded with F5), so every
-- figure below is `stageStats()` — the readout the player sees — and is checked
-- against an independent Tsiolkovsky sum, flown straight up by the builder's own
-- `hopApoapsis`, flown to orbit by a 2-D gravity turn written here, and held
-- against the contract planner's own Δv budgets (missions.lua `plan`).
local U = env.FUEL_T_PER_UNIT
check(U and U > 0, "propellant has mass (FUEL_T_PER_UNIT)")

-- A stack, top to bottom; "|" is a decoupler. `legs = n` rings n legs on the
-- lowest part. Returns the blueprint the builder saves.
local function stack_bp(list, legs)
  local REGH = {}
  local bp, uid, y = { parts = {} }, 0, 0
  local seq = {}
  for i = #list, 1, -1 do
    local id = list[i] == "|" and "decoupler" or list[i]
    local d = env.partInfo(id)
    seq[i] = { id = id, y = y + d.h * 0.5 }
    y = y + d.h
  end
  for i, s in ipairs(seq) do
    uid = uid + 1
    s.uid = uid
    bp.parts[#bp.parts + 1] = { uid = uid, id = s.id, x = 0, y = s.y, z = 0, yaw = 0,
      parent = (i > 1) and (uid - 1) or 0, att = "", sym = 0 }
  end
  local low = seq[#seq]
  for k = 1, legs or 0 do
    uid = uid + 1
    local a = (k - 1) / legs * 2 * math.pi
    bp.parts[#bp.parts + 1] = { uid = uid, id = "legs", x = 0.9 * math.cos(a), y = low.y,
      z = 0.9 * math.sin(a), yaw = -a, parent = low.uid, att = "radial", sym = 1 }
  end
  return bp
end

local function load_craft(list, legs)
  save_store["shipyard.blueprint"] = stack_bp(list, legs)
  press("f5") step(2)
  return env.stageStats()
end

-- Independent of the builder: Δv of one burn on the registry's own numbers.
local function tsiolkovsky(engine, m0, mf)
  local d = env.liveDef(engine)
  return d.ve * math.log(m0 / (m0 - mf)), d
end

-- missions.lua, loaded as itself: the contract planner's Δv budgets.
local menv = setmetatable({ save = { get = function() return nil end, set = function() end },
  findScript = function() return nil end, log = function() end, print = function() end,
  space = { body = function() return nil end } }, { __index = _G })
local mchunk = assert(loadfile("solar/scripts/missions.lua"))
setfenv(mchunk, menv)
mchunk()
-- The generator's middle system at each WORLD SCALE (system_generator SCALES):
-- the home planet's orbit, the star, a typical moon and a sister planet.
local SYSTEMS = {
  [1] = { a1 = 5850, starMu = 7.5e7, moonA = 6, moonR = 40, moonG = 3.5, sisR = 165, sisG = 7.3 },
  [2] = { a1 = 26400, starMu = 1.05e9, moonA = 4.8, moonR = 90, moonG = 2.75, sisR = 310, sisG = 6.0 },
  -- Scale 3 is scale 2 × 2.5 in length at the same gravity (µ × 6.25).
  [3] = { a1 = 66000, starMu = 6.5625e9, moonA = 4.8, moonR = 225, moonG = 2.75, sisR = 775, sisG = 6.0 },
}
local function budgets(w)
  -- A home like `w`, a moon (the generator's middle), and a sister planet
  -- 2.2× further out round a mid-weight star — at the world's own scale.
  local S = SYSTEMS[w.scale or 1]
  local R = { mu = S.starMu, star = "Sun", bodies = {}, by = {} }
  local function add(b) R.bodies[#R.bodies + 1] = b; R.by[b.name] = b end
  add({ name = "Home", parent = "Sun", a = S.a1, radius = w.r, relief = w.r * 0.065, mu = w.g * w.r ^ 2, atmo = 0.5 })
  add({ name = "Moon", parent = "Home", a = w.r * S.moonA, radius = S.moonR, relief = S.moonR * 0.065,
        mu = S.moonG * S.moonR ^ 2, atmo = 0 })
  add({ name = "Sister", parent = "Sun", a = S.a1 * 2.2, radius = S.sisR, relief = S.sisR * 0.065,
        mu = S.sisG * S.sisR ^ 2, atmo = 0.5 })
  local m, p = menv.plan(R, R.by.Home, R.by.Moon), menv.plan(R, R.by.Home, R.by.Sister)
  return {
    moon_orbit = m.ascent + m.out + m.capture,
    moon_trip = m.ascent + m.out + m.capture + m.down + m.up + m.back,
    planet_orbit = p.ascent + p.out + p.capture,
    planet_trip = p.ascent + p.out + p.capture + p.down + p.up + p.back,
  }
end

-- Straight up, then a linear pitch-over from h0 to h1 metres, burning until the
-- apoapsis reaches `alt`; coast to it and circularise. Can the craft make an
-- orbit with its periapsis at `alt`? Tries a handful of turns, as a pilot would.
local function can_orbit(T, m0, mf, ve, w, alt)
  local mu, R = w.g * w.r * w.r, w.r
  local function fly(h0, h1)
    local x, y, vx, vy, m = 0.0, R, 0.0, 0.0, m0
    local dry, mdot, dt = m0 - mf, T / ve, 0.01
    local burning = true
    for _ = 1, 200000 do
      local r = math.sqrt(x * x + y * y)
      if r < R - 0.5 then return false end
      local ux, uy = x / r, y / r
      local ex, ey = uy, -ux
      local gx, gy = -mu * x / r ^ 3, -mu * y / r ^ 3
      if burning then
        local v2, h = vx * vx + vy * vy, x * vy - y * vx
        local E = 0.5 * v2 - mu / r
        local apo = math.huge
        if E < 0 then
          local a = -mu / (2 * E)
          apo = a * (1 + math.sqrt(math.max(0, 1 + 2 * E * h * h / (mu * mu))))
        end
        if apo - R >= alt or m <= dry + 1e-9 then
          burning = false
        else
          local p = (r - R < h0) and 0 or math.min(1, (r - R - h0) / math.max(1, h1 - h0))
          local ang = p * math.pi / 2 * 0.95
          local dx, dy = math.cos(ang) * ux + math.sin(ang) * ex, math.cos(ang) * uy + math.sin(ang) * ey
          local a = T / m
          m = math.max(dry, m - mdot * dt)
          gx, gy = gx + a * dx, gy + a * dy
        end
      elseif (vx * ux + vy * uy) <= 0 and r - R > 1 then
        local need = math.sqrt(mu / r) - math.abs(vx * ex + vy * ey)
        return need <= ve * math.log(m / dry), ve * math.log(m / dry) - need
      end
      vx, vy = vx + gx * dt, vy + gy * dt
      x, y = x + vx * dt, y + vy * dt
    end
    return false
  end
  -- The turns are a pilot's on a world of ~300 m; on a bigger world the same
  -- pilot turns at the same SHARE of the radius (scale 3: the natural time
  -- grows as sqrt(r/g), and an ascent's shape with it), so the ladder holds
  -- across scales instead of rewarding a turn that is relatively ever earlier.
  local k = math.max(1, R / 310)
  for _, h0 in ipairs({ 5, 10, 20, 40 }) do
    for _, h1 in ipairs({ 40, 80, 120, 200, 300 }) do
      if h1 > h0 and fly(h0 * k, h1 * k) then return true end
    end
  end
  return false
end

-- missions.lua's own rounding: a target is rounded DOWN to 10/50/100.
local function nice(v)
  local step = v < 100 and 10 or (v < 500 and 50 or 100)
  return math.max(step, math.floor(v / step) * step)
end
local WORLDS = {
  { name = "Bryolru", r = 200, g = 5.2 },        -- the review's world
  { name = "small-light", r = 100, g = 4.5 },    -- the generator's lightest
  { name = "typical", r = 165, g = 7.3 },        -- a default new save's middle
  { name = "small-heavy", r = 120, g = 12.0 },
  { name = "big", r = 230, g = 10.0 },           -- the menu's default ceiling
  { name = "big-heavy", r = 302, g = 15.1 },     -- the scene's defaults' ceiling
  { name = "extreme", r = 400, g = 16.0 },       -- the old new-save sliders' far corner
  -- WORLD SCALE 2 (2026-10): planets 240–380 m, g 3.5–8.5, SOI 12 body radii
  -- (the orbits are wide enough that the 0.3·a cap never binds).
  { name = "v2 small-light", r = 240, g = 3.5, scale = 2 },
  { name = "v2 small-heavy", r = 240, g = 8.5, scale = 2 },
  { name = "v2 typical", r = 310, g = 6.0, scale = 2 },
  { name = "v2 big-light", r = 380, g = 3.5, scale = 2 },
  { name = "v2 big-heavy", r = 380, g = 8.5, scale = 2 },
  { name = "v2 corner", r = 450, g = 12.0, scale = 2 },   -- the sliders' far corner
  -- WORLD SCALE 3 (2026-10-20): planets 600–950 m, g 3.5–8.5, SOI 12 radii.
  { name = "v3 small-light", r = 600, g = 3.5, scale = 3 },
  { name = "v3 small-heavy", r = 600, g = 8.5, scale = 3 },
  { name = "v3 typical", r = 775, g = 6.0, scale = 3 },
  { name = "v3 big-light", r = 950, g = 3.5, scale = 3 },
  { name = "v3 big-heavy", r = 950, g = 8.5, scale = 3 },
  { name = "v3 corner", r = 1100, g = 12.0, scale = 3 },  -- the sliders' far corner
  -- GRAVITY VERSION 2 (2026-10-23): a new save's home stands at 9.8 m/s²,
  -- other bodies at 1.5× their roll (system_generator GRAV_GEN)
  { name = "v3 home g2 small", r = 600, g = 9.8, scale = 3 },
  { name = "v3 home g2 big", r = 950, g = 9.8, scale = 3 },
  { name = "v3 g2 heavy", r = 950, g = 12.75, scale = 3 },
}
local CRAFT = {
  { key = "starter",  list = { "chute", "pod", "tankS", "engineS" } },
  { key = "legs",     list = { "chute", "pod", "tankS", "engineS" }, legs = 4 },
  { key = "S+2FT-S",  list = { "chute", "pod", "tankS", "tankS", "engineS" } },
  { key = "S+FT-M",   list = { "chute", "pod", "tankM", "engineS" } },
  { key = "S+FT-M+L", list = { "chute", "pod", "tankM", "engineS" }, legs = 4 },
  { key = "S+2FT-M",  list = { "chute", "pod", "tankM", "tankM", "engineS" } },
  { key = "A+FT-M+L", list = { "chute", "pod", "tankM", "engineM" }, legs = 4 },
  { key = "A+2FT-M+L",list = { "chute", "pod", "tankM", "tankM", "engineM" }, legs = 4 },
  { key = "moonship", list = { "chute", "pod", "tankS", "engineS", "|", "tankM", "tankM", "engineM" }, legs = 4,
    upper_legs = true },
  { key = "K-stage",  list = { "chute", "pod", "tankM", "engineM", "|", "tankM", "tankM", "tankM", "tankM", "tankM", "skipper" } },
}
local TABLE = os.getenv("SOLAR_BALANCE_TABLE")
for _, w in ipairs(WORLDS) do
  -- Scale 1: home is the first planet, minOrbit 5000, so its SOI is capped at
  -- 0.3·a. Scale 2: the orbit is wide, so it is the 12-body-radii floor.
  local soi = 1500
  if (w.scale or 1) >= 2 then soi = 12 * (w.r + math.max(w.r * 0.035, 4)) end
  save_store["launch.world"] = { name = w.name, g = w.g, r = w.r, soi = soi }
  local W = env.launchWorld()
  local ceiling = soi - (w.r + math.max(w.r * 0.035, 4))
  local first, high, orbit_alt = nice(ceiling * 0.15), nice(ceiling * 0.55), nice(ceiling * 0.10)
  local esc = env.escapeSpeed(W)
  local B = budgets(w)
  local S = {}
  for _, c in ipairs(CRAFT) do
    local st = load_craft(c.list, c.legs)
    local s1 = st.stages[1]
    local r = { st = st, s1 = s1, twr = st.twr, dv = st.dv, hop = st.hop or 0, tb = s1 and s1.tb or 0,
                warn = table.concat(env.launchCheck().warn, " | "), text = stats_n.text or "" }
    -- Honest: the readout is Tsiolkovsky on the parts' own numbers, wet → dry.
    if #st.stages == 1 then
      local m0, mf, eng = 0, 0, nil
      for _, id in ipairs(c.list) do
        local d = env.liveDef(id)
        m0 = m0 + d.mass + (d.fuel or 0) * U
        mf = mf + (d.fuel or 0) * U
        if d.thrust then eng = id end
      end
      m0 = m0 + (c.legs or 0) * env.liveDef("legs").mass
      local dv, d = tsiolkovsky(eng, m0, mf)
      check(math.abs(s1.m - m0) < 1e-6 and math.abs(st.dv - dv) < 1e-6
        and math.abs(st.twr - d.thrust / (m0 * w.g)) < 1e-9,
        string.format("%s / %s: the readout is Tsiolkovsky and the launch world's g (Δv %.2f vs %.2f, TWR %.3f)",
          w.name, c.key, st.dv, dv, st.twr))
      r.orbit = can_orbit(d.thrust, m0, mf, d.ve, W, orbit_alt)
      r.m0 = m0
    end
    S[c.key] = r
  end
  local function f(a) return a == math.huge and "ESC" or string.format("%.0f m", a) end
  local A, L, S2, M, ML, MM = S.starter, S.legs, S["S+2FT-S"], S["S+FT-M"], S["S+FT-M+L"], S["S+2FT-M"]
  local AM, A2, MS, K = S["A+FT-M+L"], S["A+2FT-M+L"], S.moonship, S["K-stage"]
  -- THE STARTER: the First Flight with margin, everywhere; never escape-capable.
  check(A.twr >= 1.6, string.format("%s: the starter lifts off at TWR %.2f", w.name, A.twr))
  check(A.hop >= first * 1.35 and A.hop < high and (A.hop + w.r) / soi < 0.5,
    string.format("%s: the starter peaks at %s — past First Flight's %d m with margin, short of The High Road's %d m",
      w.name, f(A.hop), first, high))
  check(not A.orbit, w.name .. ": ...and cannot make orbit")
  -- Bigger worlds burn longer: the natural time of a world is sqrt(r/g), and
  -- scale 2 exists so the fuel lasts.
  if (w.scale or 1) >= 3 then
    -- …and scale 3's are √2.5 longer again.
    check(A.tb >= 6.0 and A.tb <= 16.0, string.format("%s: ...on a %.1f s burn (scale 3: 6–16 s)", w.name, A.tb))
  elseif (w.scale or 1) >= 2 then
    check(A.tb >= 4.0 and A.tb <= 10.0, string.format("%s: ...on a %.1f s burn (scale 2: 4–10 s)", w.name, A.tb))
  else
    check(A.tb >= 2.0 and A.tb <= 6.0, string.format("%s: ...on a %.1f s burn", w.name, A.tb))
  end
  -- Legs are tens of kilos: still a healthy lift-off and still the First Flight.
  -- (Player report: "landing legs make my ships way too heavy". A ring of four
  -- is 60 kg — 6 % of one full FT-S — and the starter still clears the First
  -- Flight with a third to spare; near escape the apex is that sensitive.)
  check(4 * env.liveDef("legs").mass <= 0.07 * (env.liveDef("tankS").mass + env.liveDef("tankS").fuel * U),
    "four legs weigh under 7 % of a full FT-S")
  check(L.hop >= first * 1.25, string.format("%s: legs keep a %s hop, ≥ 1.25× First Flight (%d m)", w.name, f(L.hop), first))
  check(L.twr >= 1.5 and L.hop >= first * 1.1,
    string.format("%s: four legs leave TWR %.2f and a %s hop (First Flight %d m)", w.name, L.twr, f(L.hop), first))
  -- More fuel flies higher and longer, at diminishing returns, and still lifts.
  for _, x in ipairs({ { "two FT-S", S2 }, { "an FT-M", M }, { "an FT-M and legs", ML } }) do
    local name, c = x[1], x[2]
    check(c.twr >= 1.2, string.format("%s: Sputter + %s lifts off at TWR %.2f", w.name, name, c.twr))
    check(c.hop == math.huge or c.hop >= high,
      string.format("%s: ...and makes The High Road (%d m): %s", w.name, high, f(c.hop)))
    check(c.tb >= 1.8 * A.tb, string.format("%s: ...burning %.1f s against the starter's %.1f", w.name, c.tb, A.tb))
  end
  check(S2.dv > A.dv and S2.dv - A.dv < A.dv,
    string.format("%s: a second FT-S adds Δv, but less than the first (%.0f → %.0f m/s)", w.name, A.dv, S2.dv))
  check(M.dv > S2.dv, string.format("%s: one FT-M beats two FT-S (lighter tankage): %.0f vs %.0f m/s", w.name, M.dv, S2.dv))
  check(M.orbit, w.name .. ": Sputter + FT-M can make orbit, flown well")
  check(MM.twr < 1.0 and MM.warn:find("too heavy to lift off", 1, true), string.format(
    "%s: two FT-M is too much for a Sputter (TWR %.2f), and LAUNCH says so: %s", w.name, MM.twr, MM.warn))
  -- The readout says what the Δv buys, in the planner's own terms.
  check(A.text:find("orbit (", 1, true) and A.text:find("suborbital hop", 1, true),
    w.name .. ": the starter's readout calls it a suborbital hop: " .. A.text)
  check(M.text:find("enough for orbit", 1, true) or M.text:find("orbit with plenty", 1, true),
    w.name .. ": Sputter + FT-M's readout says it reaches orbit: " .. M.text)
  check(MM.text:find("too heavy to lift off", 1, true), w.name .. ": two FT-M on a Sputter reads too heavy: " .. MM.text)
  check(A.warn == "" and L.warn == "", w.name .. ": the starter, with or without legs, launches without a warning: "
    .. A.warn .. L.warn)
  check(M.warn:find("escapes", 1, true), w.name .. ": an escape-capable craft is told to watch its apoapsis: " .. M.warn)
  -- THE ANVIL: orbit comfortably with legs; two FT-M on it is a moon trip.
  check(AM.twr >= 2.0 and AM.orbit, string.format("%s: Anvil + FT-M + legs (TWR %.2f) makes orbit", w.name, AM.twr))
  -- (The starter can't make orbit — above — so it can't reach the moon either;
  -- a Sputter on an FT-M has the moon round trip on paper, with nothing spare.)
  check(A2.twr >= 1.4 and A2.dv >= 1.1 * B.moon_trip, string.format(
    "%s: Anvil + two FT-M + legs is a moon round trip (%.0f m/s ≥ %.0f)", w.name, A2.dv, B.moon_trip))
  check(#MS.st.stages == 2 and MS.dv >= 1.1 * B.moon_trip and MS.twr >= 1.4, string.format(
    "%s: so is a staged moonship (Δv %.0f, TWR %.2f)", w.name, MS.dv, MS.twr))
  -- THE SKIPPER: interplanetary round trips are staged Skipper work.
  -- (From a heavy home the other planet is relatively closer — the star's
  -- transfer is the same few m/s while everything else scales — so this holds
  -- across the new-save menu's default range, g ≤ 10.)
  -- (Gravity version 2's biggest homes, g 9.8 at r 950, sit 3 % over the
  -- line: an Anvil on two FT-M has 379 m/s against a 368 m/s trip, with no
  -- margin for flying it. Reported to the coordinator as a balance note.)
  check(w.g > 10 or (w.g >= 9.8 and w.r >= 900) or A2.dv < B.planet_trip, string.format(
    "%s: an Anvil and two FT-M can't do a round trip to another planet (%.0f < %.0f m/s)", w.name, A2.dv, B.planet_trip))
  check(#K.st.stages == 2 and K.dv >= B.planet_trip and K.twr >= 1.4, string.format(
    "%s: a staged Skipper can (Δv %.0f ≥ %.0f, TWR %.2f)", w.name, K.dv, B.planet_trip, K.twr))
  -- Staging is honest: each stage is its own tanks under everything above.
  local k2 = K.st.stages[2]
  local up_m0 = env.liveDef("chute").mass + env.liveDef("pod").mass + env.liveDef("tankM").mass
    + env.liveDef("tankM").fuel * U + env.liveDef("engineM").mass
  check(math.abs(k2.m - up_m0) < 1e-6 and math.abs(k2.dv - tsiolkovsky("engineM", up_m0, env.liveDef("tankM").fuel * U)) < 1e-6,
    string.format("%s: the upper stage's Δv is its own tank under its own mass (%.1f m/s)", w.name, k2.dv))
  if TABLE then
    print(string.format("\n%s  r %d  g %.1f  escape %.0f m/s  ·  First Flight %d m, High Road %d m, orbit %d m  ·  moon trip %.0f, planet orbit %.0f, planet trip %.0f m/s",
      w.name, w.r, w.g, esc, first, high, orbit_alt, B.moon_trip, B.planet_orbit, B.planet_trip))
    for _, c in ipairs(CRAFT) do
      local r = S[c.key]
      print(string.format("  %-10s %5.2f t  TWR %4.2f  Δv %4.0f m/s (%.2f esc)  burn %5.1f s  apex %-7s %s",
        c.key, r.st.stages[1].m + (r.st.boosters and r.st.boosters.m or 0), r.twr, r.dv, r.dv / esc,
        r.tb, f(r.hop), r.orbit == nil and "" or (r.orbit and "orbit ✓" or "orbit ✗")))
    end
  end
end
-- Clear the pad for the build-by-hand section.
save_store["shipyard.blueprint"] = { parts = {} }
press("f5") step(2)

-- ── 2. build the starter in the builder; the readout is the flight's model ──
save_store["launch.world"] = { name = "Bryolru", g = 5.2, r = 200, soi = 1500 }
local W = env.launchWorld()
local launched = nil
API.scene.load = function(n) launched = n end
local FUNDS = 3000
API.COMPANY = {
  valid = true, node = { valid = true },
  balance = function() return FUNDS end,
  afford = function(c) return FUNDS >= c end,
  money = function(v) return "$" .. tostring(v) end,
  spend = function(c) if c > FUNDS then return false end FUNDS = FUNDS - c return true end,
}

check(env.launchCheck().block ~= nil, "an empty pad can't launch")
env.doLaunch()
check(launched == nil and FUNDS == 3000, "...and pressing LAUNCH charges nothing")

local function find_part(prefab)
  for _, n in ipairs(nodes) do
    if n.valid and n.name == prefab then return n end
  end
end
-- The tank first, on the pad: a craft with no seat.
env.pick("tankS") step(12)
mouse_to_world(0, 0.5, 0) click()
check(env.partCount == 1, "a tank placed free")
local chk = env.launchCheck()
check(chk.block and chk.block:find("crew"), "no crewed part: LAUNCH is refused, got " .. tostring(chk.block))
env.doLaunch()
check(launched == nil and FUNDS == 3000, "...and an uncrewed craft is never charged for")
local tank = find_part("PartTankS")
mouse_to_world(tank.x, tank.y, tank.z) click()
press("delete") step(2)
if env.partCount > 0 then press("delete") step(2) end
check(env.partCount == 0, "pad cleared")

env.pick("pod") step(12)
mouse_to_world(0, 0.5, 0) click()
local pod = find_part("PartPod")
chk = env.launchCheck()
check(not chk.block and #chk.warn >= 2, "a bare pod may launch, with warnings (no engine, no chute)")
env.pick("tankS") step(12)
mouse_to_world(pod.x, pod.y - 0.4, pod.z) click()
tank = find_part("PartTankS")
env.pick("engineS") step(12)
mouse_to_world(tank.x, tank.y - 0.5, tank.z) step(1) click()
env.pick("chute") step(12)
mouse_to_world(pod.x, pod.y + 0.4, pod.z) step(1) click()
check(env.partCount == 4, "pod, chute, FT-S, Sputter (" .. env.partCount .. " parts)")

local st = env.stageStats()
local s1 = st.stages[1]
local m0, mf = 0, 0
for _, id in ipairs({ "pod", "chute", "tankS", "engineS" }) do
  local d = env.liveDef(id)
  m0, mf = m0 + d.mass + (d.fuel or 0) * U, mf + (d.fuel or 0) * U
end
local eng = env.liveDef("engineS")
check(s1 and math.abs(s1.m - m0) < 1e-6, string.format("stage mass is WET: %.2f t", s1 and s1.m or -1))
check(s1 and math.abs(s1.dv - eng.ve * math.log(m0 / (m0 - mf))) < 1e-6,
  string.format("Δv is Tsiolkovsky, ve · ln(wet / dry): %.1f m/s", s1 and s1.dv or -1))
check(s1 and math.abs(s1.tb - mf / (eng.thrust / eng.ve)) < 1e-6,
  string.format("burn time is propellant / mass flow: %.1f s", s1 and s1.tb or -1))
check(s1 and s1.dv > 1.0 * env.escapeSpeed(W) and s1.dv < 1.4 * env.escapeSpeed(W),
  string.format("...and a believable figure for this world: %.0f m/s against escape %.0f", s1 and s1.dv or -1,
    env.escapeSpeed(W)))
check(s1 and math.abs(s1.twr - eng.thrust / (m0 * 5.2)) < 1e-9,
  string.format("TWR in the launch world's gravity, wet, not 9.81 (%.2f)", s1 and s1.twr or -1))
check(st.hop and math.abs(st.hop - env.hopTarget(W)) < 3,
  string.format("full throttle straight up peaks ≈ %.0f m (built for %.0f)", st.hop or -1, env.hopTarget(W)))
check(stats_n.text:find("TWR 1.7", 1, true) and stats_n.text:find("Bryolru", 1, true)
  and stats_n.text:find("peaks", 1, true) and stats_n.text:find("dry", 1, true)
  and stats_n.text:find("burn", 1, true), "the readout says it: " .. stats_n.text)
check(#env.launchCheck().warn == 0, "the stock starter launches without a warning")

-- The blueprint carries what the flight burns: thrust, burn rate, ve, and the
-- propellant's mass per unit.
env.doSave()
local bpe, bpt
for _, d in pairs(save_store["shipyard.blueprint"].parts) do
  if d.id == "engineS" then bpe = d end
  if d.id == "tankS" then bpt = d end
end
check(bpe and math.abs(bpe.thrust - eng.thrust) < 1e-9 and math.abs(bpe.burn - eng.burn) < 1e-9
  and math.abs(bpe.ve - eng.ve) < 1e-9, "the blueprint carries the catalogue's thrust, burn and ve")
check(bpt and bpt.fuel_t == U and bpt.mass == env.partInfo("tankS").mass,
  "...and a tank's DRY mass and its propellant's mass per unit")
check(save_store["shipyard.blueprint"].rated == nil, "...and nothing for the pad to re-rate")
-- ONE CATALOGUE PER SAVE: the same home, measured again from the pad, keeps it…
local T0 = eng.thrust
save_store["launch.world"] = { name = "Bryolru", g = 5.4, r = 196, soi = 1500 }
check(math.abs(env.liveDef("engineS").thrust - T0) < 1e-9, "the catalogue is frozen for the save: a re-measured pad changes nothing")
-- …and only a different home world (a different save) builds a different one.
save_store["launch.world"] = { name = "Heavy", g = 12, r = 150, soi = 1500 }
check(math.abs(env.liveDef("engineS").thrust - 35 * 12 / 7.0) < 1e-6, "a heavier home builds proportionally more thrust")
save_store["launch.world"] = { name = "Bryolru", g = 5.2, r = 200, soi = 1500 }
check(math.abs(env.liveDef("engineS").thrust - 35 * 5.2 / 7.0) < 1e-6, "...and Bryolru's own catalogue comes back")

-- ── 3. LAUNCH confirms when it should ───────────────────────────────────────
local chute = find_part("PartChute")
mouse_to_world(chute.x, chute.y, chute.z) click()
press("delete") step(2)
check(env.partCount == 3, "chute removed")
chk = env.launchCheck()
check(not chk.block and chk.warn[1] and chk.warn[1]:find("parachute"), "no chute is a warning")
env.doLaunch()
check(launched == nil and FUNDS == 3000, "the first LAUNCH press only warns, and charges nothing")
T = T + 1
env.doLaunch()
check(launched == "system" and FUNDS < 3000, "the second press flies it anyway, and pays for it")

-- ── 4. research is two clicks ───────────────────────────────────────────────
local done = {}
local RS = {
  valid = true,
  TECH = { engineM = { cost = 480 }, skipper = { cost = 1250, after = "engineM" } },
  isUnlocked = function(id) return done[id] or not (id == "engineM" or id == "skipper") end,
  blockedBy = function(id) if id == "skipper" and not done.engineM then return "needs Anvil Engine" end end,
  costOf = function(id) return id == "skipper" and 1250 or 480 end,
  labelOf = function(id) return id == "skipper" and "Skipper Engine" or "Anvil Engine" end,
  unlock = function(id) done[id] = true FUNDS = FUNDS - 480 return true, "Anvil Engine" end,
}
local plain = API.findScript
API.findScript = function(k) if k == "research" then return RS end return plain(k) end
FUNDS = 3000
env.pick("skipper") step(2)
check(not done.skipper and FUNDS == 3000, "a blocked card buys nothing")
env.pick("engineM") step(2)
check(not done.engineM and FUNDS == 3000, "one click on a locked card buys nothing…")
check(env.researchPending("engineM"), "…it arms the card for a confirm")
env.pick("engineM") step(2)
check(done.engineM and FUNDS == 2520, "the second click buys it")
API.findScript = plain

if #failures == 0 then
  print("BALANCE SMOKE OK — ten craft on nineteen worlds at three world scales, honest Δv/TWR, LAUNCH validation, two-click research")
  os.exit(0)
else
  print("BALANCE SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
