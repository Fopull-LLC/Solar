-- SMOKE: the electronics rulebook (scripts/electronics.lua) — pure logic, no
-- engine. Part modules and the actions they declare, action groups (binding,
-- the save format, docking renumbering, firing a group as one), the power flow
-- (surplus, deficit, brownout order, a battery switched off), sunlight (angle,
-- shadow, distance) and the comms network (range, strength, relays, a moon in
-- the way).
--
--   luajit solar/tests/smoke_electronics.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

local env = setmetatable({}, { __index = _G })
local chunk = assert(loadfile("solar/scripts/electronics.lua"))
setfenv(chunk, env)
chunk()
local E = env

-- ── modules & actions ───────────────────────────────────────────────────────
local pod = { uid = 1, id = "pod", kind = "crewed" }
local mods = E.modsOf(pod)
local has = {}
for _, m in ipairs(mods) do has[m.type] = true end
check(has.command and has.wheel and has.battery, "a legacy crewed part reads as command + wheel + battery")

local oldDish = { uid = 2, id = "dish", comms = 1 }
local dm = E.modsOf(oldDish)
check(E.modOf(oldDish, "antenna") and E.modOf(oldDish, "antenna").relay, "a legacy comms dish is a relay antenna")
check(E.modOf(oldDish, "deploy") ~= nil, "...and it folds")

local solar = { uid = 3, id = "solar", mods = { { type = "solar", gen = 1.0 }, { type = "deploy", anim = "solar" } } }
local acts = E.actionsOf(solar)
local ids = {}
for _, a in ipairs(acts) do ids[a.id] = a end
check(ids["deployed.on"] and ids["deployed.off"] and ids["deployed.toggle"], "a folding panel has extend / retract / toggle")
check(ids["deployed.on"].label == "Extend", "the verbs come from the module type")

local st = E.stateOf(solar)
check(st.deployed == false, "panels default stowed")
local v, ch = E.applyAction(st, ids["deployed.toggle"])
check(v == true and ch and st.deployed == true, "toggle extends")
v, ch = E.applyAction(st, ids["deployed.on"])
check(v == true and not ch, "extend on an extended panel changes nothing")
v, ch = E.applyAction(st, ids["deployed.toggle"], true)
check(v == true and not ch, "a forced toggle sets, it doesn't flip")

local legs = { uid = 4, legs = 1 }
check(E.stateOf(legs).deployed == true, "legs default DOWN (the pad needs them)")

local dec = { uid = 5, decouple = 1 }
local da = E.actionOf(dec, "decouple")
check(da and da.kind == "trigger", "a decoupler has a Decouple trigger, not tied to staging")
local eng = { uid = 6, thrust = 30 }
check(E.actionOf(eng, "running.off") and E.actionOf(eng, "running.off").label == "Shut down",
  "engines can be shut down and activated by action")

-- actuators are declared (0420) with axes
local hinge = { uid = 7, mods = { { type = "hinge" } } }
local ha = E.actionOf(hinge, "angle.inc")
check(ha and ha.kind == "axis", "a hinge declares Angle +/− actions")
local hs = E.stateOf(hinge)
E.applyAction(hs, ha, nil, 5)
check(hs.angle == 5, "an axis action moves the setpoint by rate·dt")
E.applyAction(hs, E.actionOf(hinge, "angle.center"))
check(hs.angle == 0, "centre resets it")

-- ── groups ──────────────────────────────────────────────────────────────────
local L1 = { uid = 10, legs = 1 }
local L2 = { uid = 11, legs = 1 }
local P1 = { uid = 12, mods = { { type = "solar", gen = 1 }, { type = "deploy", anim = "solar" } } }
local A1 = { uid = 13, mods = { { type = "antenna", power = 3e4, draw = 0.1 }, { type = "deploy", anim = "whip" } } }
local LT = { uid = 14, mods = { { type = "light", draw = 0.2 } } }
local recs = { [10] = L1, [11] = L2, [12] = P1, [13] = A1, [14] = LT, [5] = dec }
local g = E.defaultGroups(recs)
check(E.isBound(g, "gear", 10, "deployed.toggle") and E.isBound(g, "gear", 11, "deployed.toggle"),
  "default Gear holds the landing legs")
check(E.isBound(g, "deploy", 12, "deployed.toggle") and E.isBound(g, "deploy", 13, "deployed.toggle"),
  "default Deploy holds panels and antennas")
check(not E.isBound(g, "gear", 12, "deployed.toggle"), "...and panels are not landing gear")
check(E.isBound(g, "lights", 14, "lit.toggle"), "default Lights holds the light")
check(not g["1"], "custom group 1 starts empty")

check(E.bind(g, "1", 5, "decouple"), "bind a decoupler to group 1")
check(not E.bind(g, "1", 5, "decouple"), "binding twice is a no-op")
check(E.toggleBind(g, "1", 14, "lit.on") == true and E.isBound(g, "1", 14, "lit.on"), "toggleBind adds")
check(E.toggleBind(g, "1", 14, "lit.on") == false and not E.isBound(g, "1", 14, "lit.on"), "...and removes")
local gs = E.groupsOf(g, 10, "deployed.toggle")
check(#gs == 1 and gs[1] == "gear", "groupsOf names the groups an action is in")

-- save format round trip
local packed = E.packGroups(g)
check(type(packed) == "table" and #packed >= 4, "groups pack to a list")
local back = E.unpackGroups(packed)
check(E.isBound(back, "1", 5, "decouple") and E.isBound(back, "gear", 11, "deployed.toggle"),
  "...and unpack to the same bindings")
check(type(packed[1]) == "table" and packed[1].id and type(packed[1].binds) == "table",
  "...each group a plain table (save.set keeps 16 deep since 0.117)")

-- saves written before 0.117 hold strings: they still read
local old = E.unpackGroups({ "gear|Gear|10@deployed.toggle;11@deployed.toggle", "1|Night ops|5@decouple" })
check(E.isBound(old, "gear", 11, "deployed.toggle") and old["1"].name == "Night ops",
  "an old save's group strings still unpack")
local om = E.modsOf({ mods = "antenna:power=2250,rate=4,draw=0.12,omni=t;deploy:anim=whip" })
check(#om == 2 and om[1].type == "antenna" and om[1].power == 2250 and om[1].omni == true and om[2].anim == "whip",
  "an old save's module string still decodes")
local ost = E.stateOf({ mods = {}, st = "deployed=t,charge=37.25" })
check(ost.deployed == true and ost.charge == 37.25, "an old save's state string still decodes")
local live = { uid = 3, mods = { { type = "battery", ec = 40 } }, st = { charge = 12, deployed = true, note = "x" } }
local pr = E.packRecord(live)
check(type(pr.mods) == "table" and pr.mods ~= live.mods and pr.mods[1] ~= live.mods[1] and pr.mods[1].ec == 40,
  "packRecord copies the modules as tables, sharing nothing")
check(type(pr.st) == "table" and pr.st.charge == 12 and pr.st.deployed == true and pr.st.note == nil,
  "...and the state's switches and numbers")

-- firing as one: gear starts DOWN (both legs), one press sends both UP
local ran = {}
local n = E.fireGroup(back, "gear", recs, function(uid, act, force)
  local s = E.stateOf(recs[uid])
  E.applyAction(s, act, force)
  ran[#ran + 1] = uid
end)
check(n == 2 and E.stateOf(L1).deployed == false and E.stateOf(L2).deployed == false,
  "G raises the whole gear ring")
-- desync one leg by hand, then fire: the group sets both to its state, never half
E.stateOf(L1).deployed = true
E.fireGroup(back, "gear", recs, function(uid, act, force) E.applyAction(E.stateOf(recs[uid]), act, force) end)
check(E.stateOf(L1).deployed == E.stateOf(L2).deployed, "a group toggle never leaves a ring half down")
local fired = 0
E.fireGroup(back, "1", recs, function(uid, act) if act.kind == "trigger" then fired = fired + 1 end end)
check(fired == 1, "group 1 fires the decoupler's trigger")

-- remap (docking) / prune (staging) / merge / subset
local rm = E.remapGroups(back, { [10] = 110, [5] = 105 })
check(E.isBound(rm, "gear", 110, "deployed.toggle") and not E.isBound(rm, "gear", 11, "deployed.toggle"),
  "remap renumbers and drops unmapped parts")
local pr = E.pruneGroups(E.deepCopy(back), { [11] = true })
check(#pr.gear.binds == 1 and pr.gear.binds[1].uid == 11 and #pr["1"].binds == 0,
  "prune keeps only parts still aboard")
local host = { ["1"] = { name = "Group 1", binds = { { uid = 1, act = "x" } } } }
E.mergeGroups(host, rm)
check(E.isBound(host, "1", 1, "x") and E.isBound(host, "1", 105, "decouple"), "merge unions a docked module's groups")
check(E.groupKey("gear") == "g" and E.groupKey("abort") == "backspace" and E.groupKey("0") == "0",
  "group keys: G, Backspace, 1–0")

-- ── power ───────────────────────────────────────────────────────────────────
local cells = { { cap = 100, charge = 50 }, { cap = 100, charge = 50 } }
local r = E.powerStep({ supply = 2.0, loads = { { id = "a", rate = 1.0 } }, cells = cells }, 10)
check(near(r.charge, 110) and near(cells[1].charge, 55), "a surplus charges every battery in proportion")
check(r.served.a == 1 and not r.brownout, "...and every load is served")
r = E.powerStep({ supply = 0.0, loads = { { id = "a", rate = 1.0 } }, cells = cells }, 10)
check(near(r.charge, 100), "a deficit drains the batteries")
-- brownout: 0.5 EC/s supply, no charge; the core (pri 9) keeps power before lights (pri 2)
local flat = { { cap = 100, charge = 0 } }
r = E.powerStep({ supply = 0.5, loads = { { id = "light", rate = 0.4, pri = 2 }, { id = "core", rate = 0.3, pri = 9 } },
  cells = flat }, 1)
check(r.served.core == 1 and r.served.light < 0.6 and r.brownout, "brownout sheds the lights before the core")
-- a battery switched off neither drains nor charges
local off = { { cap = 100, charge = 80, on = false }, { cap = 50, charge = 10 } }
r = E.powerStep({ supply = 0, loads = { { id = "a", rate = 5 } }, cells = off }, 10)
check(off[1].charge == 80 and off[2].charge == 0 and r.served.a < 1, "an isolated battery keeps its charge")
check(E.endurance(100, -0.5) == 200 and E.endurance(10, 1) == math.huge, "endurance")

-- ── sunlight ────────────────────────────────────────────────────────────────
local star = { name = "Sun", x = 0, y = 0, z = 0, radius = 50, mu = 1e9, soi = -1 }
local planet = { name = "P", x = 1000, y = 0, z = 0, radius = 100, mu = 1e5, soi = 300 }
local bodies = { star, planet }
local ref = star.mu / (1000 * 1000)
-- day side (between star and planet), panel axis vertical: full exposure
local out, ex, fx, blk = E.solarOutput(1.0, 850, 0, 0, 0, 1, 0, bodies, ref)
check(near(ex, 1) and blk == nil and out > 1.0, "a panel on the day side at full exposure (closer than home = brighter)")
-- axis pointing at the sun: tracking about it gains nothing
out, ex = E.solarOutput(1.0, 850, 0, 0, 1, 0, 0, bodies, ref)
check(near(ex, 0, 1e-6) and near(out, 0, 1e-6), "a panel whose axis points at the sun makes nothing")
-- night side, behind the planet
out, ex, fx, blk = E.solarOutput(1.0, 1150, 0, 0, 0, 1, 0, bodies, ref)
check(blk == "P" and out == 0, "in the planet's shadow: no power")
-- twice as far: a quarter of the light
out = E.solarOutput(1.0, 2000, 500, 0, 0, 0, 1, bodies, ref)
check(near(out, 0.25, 0.02), "inverse square: twice as far, a quarter of the power")

-- ── sunlight on a Vever-like world: incidence, occlusion, warp ──────────────
-- The playtest's home (2026-10-23): a non-rotating world r 807 m, 66 km from
-- its star, on a circular orbit at ~242 m/s (its "day" is its ~29 min year).
do
  local VERBOSE = os.getenv("ELEC_VERBOSE")
  local smu = 3.88e9
  local D = 66000
  local vorb = math.sqrt(smu / D)
  local S0 = { name = "Sol", x = 0, y = 0, z = 0, vx = 0, vy = 0, vz = 0, radius = 6934, mu = smu, soi = -1 }
  local W0 = { name = "Vever", x = D, y = 0, z = 0, vx = 0, vy = 0, vz = vorb, radius = 807.6, mu = 5.97e6, soi = 9691 }
  local BL = { S0, W0 }
  local ref0 = smu / (D * D)
  local R = 780
  -- a point on the ground at sun elevation `el` (radians) in the x–y plane
  local function ground(el)
    -- the sun lies along −X from the world: up = (−sin el, cos el, 0) puts
    -- it `el` over the local horizon
    local ux, uy = -math.sin(el), math.cos(el)
    return D + ux * R, uy * R, 0, ux, uy, 0
  end
  -- noon: sun straight overhead
  local x, y, z, ux, uy, uz = ground(math.pi / 2)
  -- panel on a flank: mount axis horizontal (+Z), square to the sun
  local out, ex, fx, blk = E.solarOutput(1.0, x, y, z, 0, 0, 1, BL, ref0)
  check(near(ex, 1, 1e-6) and blk == nil and near(out, 1, 0.03), "noon, an open panel square to the sun: full output")
  -- the same panel's axis pointing straight AWAY from the sun: a tracking wing
  -- turned edge-on can't face it
  out, ex = E.solarOutput(1.0, x, y, z, -ux, -uy, -uz, BL, ref0)
  check(near(out, 0, 1e-9), "an open panel whose axis points away from the sun: nothing")
  -- folded (cells out along the mount axis): facing the sun = full, facing away = 0
  out = E.solarOutput(1.0, x, y, z, ux, uy, uz, BL, ref0, 0)
  check(near(out, 1, 0.03), "a folded panel with its cells up at noon: full output")
  out = E.solarOutput(1.0, x, y, z, -ux, -uy, -uz, BL, ref0, 0)
  check(near(out, 0, 1e-9), "a folded panel with its cells facing away: nothing")
  -- 60° incidence on a folded panel: cos 60 = half
  out = E.solarOutput(1.0, x, y, z, ux * 0.5, uy * 0.5 + 0.8660254, uz, BL, ref0, 0)
  check(near(out, 0.5, 0.015), "a folded panel at 60° incidence: half output (cos)")
  -- the world's orientation, not the part's: the same local panel on a craft
  -- rolled upside down faces the ground
  out = E.solarOutput(1.0, x, y, z, -ux, -uy, -uz, BL, ref0, 0)
  check(out == 0, "the world orientation decides (a roof panel on an upturned craft faces the ground)")
  -- night side
  local nx, ny, nz = ground(-math.pi / 2)
  out, ex, fx, blk = E.solarOutput(1.0, nx, ny, nz, 0, 0, 1, BL, ref0)
  check(out == 0 and blk == "Vever", "midnight: the world is in the way, nothing")
  -- low sun, 5° over the horizon: lit; 5° under it: the world is in the way
  local lx, ly, lz = ground(math.rad(5))
  out, ex, fx, blk = E.solarOutput(1.0, lx, ly, lz, 0, 0, 1, BL, ref0)
  check(out > 0.9 and blk == nil, "sun 5° up: lit")
  lx, ly, lz = ground(math.rad(-5))
  out, ex, fx, blk = E.solarOutput(1.0, lx, ly, lz, 0, 0, 1, BL, ref0)
  check(out == 0 and blk == "Vever", "sun 5° down: dark")

  -- GAME TIME: ten ticks of a tenth of a real second, at 1× and at 10×.
  check(near(E.gameStep(100, 101, 0.1, 10), 1.0), "gameStep: the clock's advance at 10× (1 s per 0.1 s tick)")
  check(near(E.gameStep(100, 40, 0.1, 10), 1.0), "gameStep: a clock that ran backwards (a load) falls back to dt × warp")
  check(near(E.gameStep(nil, nil, 0.1, 1), 0.1), "gameStep: no clock, 1×: the frame's dt")
  check(near(E.gameStep(0, 5000, 0.1, 10), 1.0), "gameStep: a runaway clock jump is not believed")
  local panels = { { gen = 1.0, ax = 0, ay = 0, az = 1, deployed = 1 } }
  local function run(warp, ticks)
    local cells = { { cap = 400, charge = 10 } }
    local t = 0
    local st0 = 0
    for _ = 1, ticks do
      local st1 = st0 + 0.1 * warp
      local dt = E.gameStep(st0, st1, 0.1, warp)
      st0 = st1
      local sun = E.solarOverStep(panels, { x = x, y = y, z = z, landed = true, bodies = BL }, dt, ref0)
      E.powerStep({ supply = sun, loads = { { id = "core", rate = 0.2, pri = 9 } }, cells = cells }, dt)
      t = t + 0.1
    end
    return cells[1].charge - 10, t
  end
  local g1, real1 = run(1, 10)
  local g10, real10 = run(10, 10)
  if VERBOSE then
    print(string.format("  noon, 1 panel (1 EC/s) − 0.2 EC/s core: 1× +%.3f EC per real second, 10× +%.3f EC per real second (%.2f×)",
      g1 / real1, g10 / real10, g10 / g1))
  end
  check(near(g10 / g1, 10, 0.05), string.format("10× warp charges 10× as much per real second (%.3f vs %.3f EC)", g10, g1))

  -- CLOSED FORM over a long step: the mean output over a step equals the
  -- light integrated finely along the world's orbit (and the craft's).
  local P = 2 * math.pi * D / vorb
  local function brute(pnl, S, dt, N)
    local sum = 0
    for k = 1, N do
      local t = (k - 0.5) / N * dt
      local hx, hy, hz = E.kepler(W0.x, W0.y, W0.z, W0.vx, W0.vy, W0.vz, smu, t)
      local W = { name = "Vever", x = hx, y = hy, z = hz, radius = W0.radius, mu = W0.mu, soi = W0.soi }
      local cx, cy, cz = S.x - W0.x, S.y - W0.y, S.z - W0.z
      if not S.landed then
        cx, cy, cz = E.kepler(cx, cy, cz, S.vx - W0.vx, S.vy - W0.vy, S.vz - W0.vz, W0.mu, t)
      end
      for _, p in ipairs(pnl) do
        sum = sum + E.solarOutput(p.gen, hx + cx, hy + cy, hz + cz, p.ax, p.ay, p.az, { S0, W }, ref0, p.deployed)
      end
    end
    return sum / N
  end
  -- landed at noon, a whole year (= a whole day) in one step: half of it dark
  local Sl = { x = x, y = y, z = z, vx = W0.vx, vy = W0.vy, vz = W0.vz, landed = true, bodies = BL }
  local m1, lit1, n1 = E.solarOverStep(panels, Sl, P, ref0)
  local b1 = brute(panels, Sl, P, 4000)
  check(near(lit1, 0.5, 0.04), string.format("a whole day in one step: the craft is lit about half of it (%.3f; a little over, from its height over the horizon)", lit1))
  check(math.abs(m1 - b1) < 0.03 * math.max(b1, 0.1), string.format(
    "...and the step's mean output matches a fine integration (%.3f vs %.3f EC/s, %d samples)", m1, b1, n1))
  -- a quarter-day step from noon: still all daylight, but the sun sinks
  local m2 = E.solarOverStep(panels, Sl, P / 4, ref0)
  local b2 = brute(panels, Sl, P / 4, 2000)
  check(m2 > 0 and math.abs(m2 - b2) < 0.03 * b2, string.format("a quarter-day step: %.3f vs fine %.3f EC/s", m2, b2))
  -- a probe in a low orbit (~70 s period): a 10-minute warp step spans
  -- several orbits, each with a pass through the world's shadow
  local ro = 900
  local vo = math.sqrt(W0.mu / ro)
  local So = { x = D - ro, y = 0, z = 0, vx = W0.vx, vy = vo, vz = W0.vz, landed = false, bodies = BL }
  local pr = { { gen = 1.0, ax = 0, ay = 0, az = 1, deployed = 1 } }
  local m3, lit3 = E.solarOverStep(pr, So, 600, ref0)
  local b3 = brute(pr, So, 600, 6000)
  check(lit3 > 0.55 and lit3 < 0.85, string.format("an orbiter is in sunlight for most of each orbit (%.2f of the step)", lit3))
  check(math.abs(m3 - b3) < 0.05 * b3, string.format("...and the long step's mean matches a fine integration (%.3f vs %.3f)", m3, b3))
  if VERBOSE then
    print(string.format("  landed, one whole day: mean %.3f EC/s (fine %.3f), lit %.2f · quarter day %.3f (fine %.3f) · orbiter 600 s: %.3f (fine %.3f), lit %.2f",
      m1, b1, lit1, m2, b2, m3, b3, lit3))
  end
  -- the propagator itself: a circular orbit comes home after one period
  local kx, ky, kz = E.kepler(D, 0, 0, 0, 0, vorb, smu, P)
  check(math.abs(kx - D) < 1e-3 and math.abs(ky) < 1e-3 and math.abs(kz) < 1e-3, "kepler: a circular orbit closes after one period")
end

-- ── comms ───────────────────────────────────────────────────────────────────
check(near(E.linkRange(100, 400), 200), "range = sqrt(P1·P2)")
check(E.linkStrength(0, 100) == 1 and E.linkStrength(100, 100) == 0 and near(E.linkStrength(50, 100), 0.5),
  "strength 1 → 0, half at mid-range")

-- antennaSummary: a stowed whip doesn't count; extended does; a powered-off craft has none
local whip = { uid = 20, mods = { { type = "antenna", power = 3e4, rate = 4, draw = 0.1 }, { type = "deploy", anim = "whip" } } }
local relayDish = { uid = 21, mods = { { type = "antenna", power = 1e6, relay = true, dish = true, rate = 12, draw = 0.6 },
  { type = "deploy", anim = "dish" } } }
local core = { uid = 22, mods = { { type = "command", draw = 0.1 }, { type = "antenna", power = 2000, rate = 1 } } }
local s0 = E.antennaSummary({ whip, core })
check(near(s0.any, 2000) and s0.relay == 0, "a stowed whip doesn't count; the core's internal one does")
E.stateOf(whip).deployed = true
local s1 = E.antennaSummary({ whip, core })
check(s1.any > 3e4 and s1.relay == 0, "extended, the whip leads (and combines with the core)")
E.stateOf(relayDish).deployed = true
local s2 = E.antennaSummary({ relayDish })
check(s2.relay > 0, "a dish is a relay")
check(E.antennaSummary({ relayDish }, nil, false).any == 0, "no power, no radio")

-- Network: home on a planet surface; sat A in low orbit; sat B far out beyond
-- A's direct reach of home but within relay range of A; a moon parks between.
local home = { id = "home", x = 0, y = 100, z = 0, home = true, power = 2500 }
local world = { name = "W", x = 0, y = 0, z = 0, radius = 100, mu = 1e6, soi = 5e4 }
local moon = { name = "Moon", x = 0, y = 3000, z = 0, radius = 200, mu = 1e4, soi = 600 }
local satA = { id = "A", x = 0, y = 600, z = 0, any = 1e4, relay = 1e4, rate = 4 }
local satB = { id = "B", x = 5600, y = 600, z = 0, any = 1e4, relay = 0, rate = 4 }
local st1, links1 = E.solveNetwork({ home, satA, satB }, { world })
check(st1.A.connected and st1.A.hops == 1, "A talks to home directly")
check(st1.B.connected and st1.B.hops == 2 and st1.B.parent == "A", "B reaches home THROUGH A (relay)")
check(st1.B.strength < st1.A.strength, "a relayed path is weaker than a direct one")
local used = 0
for _, l in ipairs(links1) do if l.used then used = used + 1 end end
check(used == 2, "the two hops on the best paths are marked used")
-- A without relay capability: B is cut off
local satA2 = { id = "A", x = 0, y = 600, z = 0, any = 1e4, relay = 0, rate = 4 }
local st2 = E.solveNetwork({ home, satA2, satB }, { world })
check(not st2.B.connected, "an omni-only craft does not relay")
-- the moon occludes A–B: move B behind the moon as seen from A
local satB2 = { id = "B", x = 0, y = 5600, z = 0, any = 1e4, relay = 0, rate = 4 }
local st3 = E.solveNetwork({ home, satA, satB2 }, { world })
check(st3.B.connected, "B above A, clear sky: linked through A")
local st4 = E.solveNetwork({ home, satA, satB2 }, { world, moon })
check(not st4.B.connected, "a moon between A and B breaks the chain")
-- the planet occludes: a sat on the far side of the world can't see the station
local far = { id = "F", x = 0, y = -600, z = 0, any = 1e5, relay = 0 }
local st5 = E.solveNetwork({ home, far }, { world })
check(not st5.F.connected, "a craft behind the planet has no line of sight to home")
-- a landed craft right beside the station on the same world links fine
local nextdoor = { id = "N", x = 30, y = 99, z = 0, any = 2000 }
local st6 = E.solveNetwork({ home, nextdoor }, { world })
check(st6.N.connected, "a craft landed next to the station has a link")

-- ── the home world's horizon (scale 3: Vever, r 807, the base in a basin) ───
-- A world with craft and a station ON its ground: the occluder sits under the
-- lower end, less the grazing allowance, so near ground links and a ray that
-- would run through the planet's body does not.
do
  local R = 807.6
  local vever = { name = "Vever", x = 0, y = 0, z = 0, radius = R, mu = 4.48e6, soi = 9691 }
  local rs = R - 21.8                                  -- the dish stands in a 26 m basin
  local function ground(arc, r) local a = arc / rs; return r * math.sin(a), r * math.cos(a) end
  local st = { id = "home", x = 0, y = rs, z = 0, home = true, power = E.COMMS.station }
  check(near(E.grazeOf(R), 8.076, 1e-3), "grazing on Vever is 1 % of its radius")
  check(E.grazeOf(100) == E.COMMS.grazeMin and E.grazeOf(1e6) == E.COMMS.grazeMax, "grazing is clamped")
  local function solo(nd) return E.solveNetwork({ st, nd }, { vever })[nd.id] end
  local px, py = ground(14, rs + 0.5)
  local pad = solo({ id = "pad", x = px, y = py, z = 0, any = 100 })
  check(pad.connected, "a probe core on the pad beside the base has a link")
  local qx, qy = ground(200, rs)
  local r200 = solo({ id = "r200", x = qx, y = qy, z = 0, any = 100 })
  check(r200.connected, "a probe rover 200 m of ground away is in sight (the line dips 6 m: a grazing link)")
  local wx, wy = ground(300, rs)
  check(not solo({ id = "r300", x = wx, y = wy, z = 0, any = 100 }).connected,
    "...300 m away the line runs 14 m under the ground: blocked")
  -- the old rule (2 m under the lower end) cut that rover off
  check(E.segmentBlocked(qx, qy, 0, 0, rs, 0, { vever }, E.COMMS.occlude) == "Vever",
    "...where a 2 m allowance called it blocked")
  local fx, fy = ground(1110, rs)
  local far = solo({ id = "far", x = fx, y = fy, z = 0, any = 100 })
  check(not far.connected, "a rover 1.1 km round the world (79°) is behind the planet")
  check(far.why and far.why:find("below the horizon", 1, true) and far.why:find("1.1 km", 1, true),
    "...and says the station is below its horizon, how far round: " .. tostring(far.why))
  -- orbit 300 m up: the geometric horizon from the dish is acos(rs / (R + h))
  local h = 300
  local thh = math.acos(rs / (R + h))
  local function orb(f) local a = thh * f; return (R + h) * math.sin(a), (R + h) * math.cos(a) end
  local ax, ay = orb(0.9)
  check(solo({ id = "up", x = ax, y = ay, z = 0, any = 2250 }).connected, "an orbiter above the base's horizon is linked")
  local bx, by = orb(1.5)
  local dn = solo({ id = "dn", x = bx, y = by, z = 0, any = 2250 })
  check(not dn.connected and dn.why:find("blocked by Vever", 1, true), "an orbiter well below the horizon is blocked")
  local cx, cy = orb(-1.6)
  check(not solo({ id = "dn2", x = cx, y = cy, z = 0, any = 2250 }).connected, "...on either side")
  -- the allowance is small: just under the horizon passes, far under doesn't
  local tx, ty = orb(1.05)
  check(solo({ id = "t", x = tx, y = ty, z = 0, any = 2250 }).connected, "5 % past the geometric horizon still grazes")
  -- sunlight keeps its 2 m (a shadow is a shadow): same rover-to-dish line
  check(E.segmentBlocked(qx, qy, 0, 0, rs, 0, { vever }, 1.0) == "Vever", "segmentBlocked without graze stays strict")
end

-- summary: what the builder quotes
local sm = E.summary({ core, whip, { uid = 30, mods = { { type = "battery", ec = 100 } } },
  { uid = 31, mods = { { type = "solar", gen = 1.0 }, { type = "deploy", anim = "solar" } } } })
check(sm.store == 100 and near(sm.solar, 1.0) and sm.probe == 1 and sm.crew == 0, "summary: store, solar, command")
check(sm.reachHome > sm.reachCraft and sm.reachCraft > 3e4, "summary: reach home vs reach another craft")
check(near(sm.idle, 0.2), "summary: idle draw = core + radios")

-- ── report ──────────────────────────────────────────────────────────────────
if #failures == 0 then
  print(string.format("ELECTRONICS SMOKE OK — %d checks passed", passed))
  os.exit(0)
end
print("ELECTRONICS SMOKE FAILURES:")
for _, f in ipairs(failures) do print("  ✗ " .. f) end
os.exit(1)
