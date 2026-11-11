-- SMOKE HARNESS for the part interaction slices S0–S2 (work/interact/PLAN.md):
--
--   * the right-click TAP rule (context_menu.tapAccepts): a locked pointer's
--     movement is the look, never a drag; a free pointer's slack scales with
--     the screen; a long press is never a tap;
--   * a hit on anything under the actor resolves to the actor, never a prop;
--     from the eyes the actor is never picked (no silent suit fallback) and
--     the ray passes the actor's whole subtree;
--   * every system's whyNot(sid, uid, want): logic_net's authority (a cable
--     on the RUN terminal, Local control), base_grid's breaker trip,
--     room_air's machines, reactor_plant's coolant pumps (not plumbed,
--     knocked: physical reasons only), heat sinks, kit_live's lights; and
--     warnOf: the consequence said, never a refusal (Ty 2026-11-10);
--     each setX(..., "hand") refuses with that sentence and works without it;
--   * a light switched off draws nothing on the grid (base_grid.gridModel);
--   * part_info: designations, the title/subtitle, the condition, WHY, the
--     identity provider on a kit piece and on a ruin's piece; start.tags
--     validated by the scenario rulebook.
--
--   luajit solar/tests/smoke_interact.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end

local T = 0
local function env(store, scripts, extra)
  local E = setmetatable({
    save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
    findScript = function(k) return scripts[k] end,
    findScripts = function() return {} end,
    find = function() return nil end,
    log = function() end,
    vec3 = function(x, y, z) return { x = x, y = y, z = z } end,
  }, { __index = function(_, k) if k == "time" then return T end return _G[k] end })
  for k, v in pairs(extra or {}) do E[k] = v end
  return E
end
local function load_script(path, E)
  local f = io.open("solar/scripts/" .. path) and ("solar/scripts/" .. path) or ("scripts/" .. path)
  local chunk = assert(loadfile(f))
  setfenv(chunk, E)
  chunk()
  E.params = {}
  for k, v in pairs(E.defaults or {}) do E.params[k] = v end
  E.valid = true
  return E
end

-- ── a structure stub shared by the systems ──────────────────────────────────
local DEFS = {
  flPump = { label = "Transfer Pump", fl = { kind = "pump", kw = 1.5 }, power = { kind = "aux", use = 1.5 },
             lg = { kind = "device", dev = "pump", pins = { { n = "run", io = "in" } } } },
  flValve = { label = "Gate Valve", fl = { kind = "valve" }, lg = { kind = "device", dev = "valve", pins = { { n = "open", io = "in" } } } },
  lightFitting = { label = "Light Fitting", light = { draw = 0.12 }, power = { kind = "load", use = 0.12 },
                   lg = { kind = "device", dev = "light", pins = { { n = "on", io = "in" } } } },
  breaker63 = { label = "Breaker 63 A", power = { kind = "breaker", amps = 63 },
                lg = { kind = "device", dev = "breaker", pins = { { n = "close", io = "in" }, { n = "tripped", io = "out" } } } },
  scrubber = { label = "CO2 Scrubber", life = { co2 = 1 }, power = { kind = "load", use = 0.4 },
               lg = { kind = "device", dev = "machine", pins = { { n = "run", io = "in" } } } },
  airRack = { label = "Air Rack", life = { store = 12 } },
  coolantPump = { label = "Coolant Pump", pump = { kw = 1.5 }, power = { kind = "aux", use = 1.5 },
                  lg = { kind = "device", dev = "rxpump", pins = { { n = "run", io = "in" } } } },
  coolTower = { label = "Cooling Tower", reject = { kind = "tower", g = 14, kw = 2 }, power = { kind = "aux", use = 2 } },
  radPanel = { label = "Radiator Panel", reject = { kind = "rad", area = 16, eps = 0.88 } },
  loSensor = { label = "Level Sensor", lg = { kind = "sensor", pins = { { n = "Q", io = "out" } } } },
  wallS = { label = "Wall (steel)", matLabel = "Steel", kit = true, exterior = true },
}
local function new_struct()
  local bp = {
    { uid = 1, id = "flPump" }, { uid = 2, id = "flValve" }, { uid = 3, id = "lightFitting" }, { uid = 4, id = "breaker63" },
    { uid = 5, id = "scrubber" }, { uid = 6, id = "airRack" }, { uid = 7, id = "coolantPump" }, { uid = 8, id = "coolantPump" },
    { uid = 9, id = "coolTower" }, { uid = 10, id = "radPanel" }, { uid = 11, id = "loSensor" }, { uid = 12, id = "wallS" },
    { uid = 13, id = "coolantPump" },
  }
  local rec = { id = 7, b = "Home", bp = bp, st = {}, n = "Kerne Station" }
  local ST = { version = 1, list = function() return { rec } end, get = function(id) return id == 7 and rec or nil end }
  function ST.getPart(sid, u) if sid ~= 7 then return nil end for _, p in ipairs(bp) do if p.uid == u then return p end end end
  function ST.partState(sid, u) return rec.st[tostring(u)] end
  function ST.setPartState(sid, u, t) if not ST.getPart(sid, u) then return false end rec.st[tostring(u)] = t; return true end
  return ST, rec
end
local ST, REC = new_struct()
local PB = { partInfo = function(id) return DEFS[id] end }
local STORE = {}
local SCR = { structures = ST, parts_base = PB }

-- ── context_menu: the tap rule and the actor's subtree ──────────────────────
do
  local CM = load_script("context_menu.lua", env({}, {}, {}))
  local h = 1440
  check(CM.tapAccepts(0.2, 0, false, 720) == true, "a still, short press is a tap")
  check(CM.tapAccepts(0.5, 0, false, 720) == false, "a long press is the look, not a tap")
  check(CM.tapAccepts(0.5, 0, true, 720) == true and CM.tapAccepts(0.9, 0, true, 720) == false,
    "locked (first person, no look to protect): a slow 0.5 s click is still a tap, a 0.9 s hold is not")
  check(CM.tapAccepts(0.2, 9, false, 720) == true and CM.tapAccepts(0.2, 11, false, 720) == false, "a free pointer: 10 px of slack at 720 lines")
  check(CM.tapAccepts(0.2, 19, false, h) == true and CM.tapAccepts(0.2, 21, false, h) == false, "…20 px at 1440 lines (the hand is the same)")
  check(CM.tapAccepts(0.3, 400, true, h) == true, "a LOCKED pointer (first person): 400 px of head look in the press is still a tap")
  check(CM.tapAccepts(0.2, 10, true, 720) == true, "the plan's fp_tap: a 10 px drift in first person is a tap")
  -- the actor's subtree
  local astro = { id = 14, name = "Astronaut" }
  local model = { id = 90, name = "AstroModel", parent = astro }
  local helmet = { id = 91, name = "Helmet", parent = model }
  local tool = { id = 92, name = "ToolCollider", parent = helmet }
  local wall = { id = 300, name = "kit:wallS", parent = { id = 299, name = "Structure 7" } }
  check(CM.underActor(tool, astro) and CM.underActor(astro, astro), "a collider 3 levels under the crew is the crew")
  check(not CM.underActor(wall, astro), "a wall is not the crew")
  local t = CM.resolve({ node = tool, x = 0, y = 0, z = 0 }, astro)
  check(t and t.kind == "astro" and t.node == astro, "a hit on the crew's helmet tool resolves as the crew, not a prop")
  local t2 = CM.resolve({ node = wall, x = 0, y = 0, z = 0 }, astro)
  check(t2 and t2.kind == "prop" and t2.node == wall, "a hit on a wall is a prop (the kit's providers read it)")
  -- the pick from the eyes: the ray is told to pass the actor's whole subtree;
  -- a hit on the actor at the lens is cast past; nothing → nil and a reason
  local casts = {}
  local hits = { { node = helmet, x = 0, y = 0, z = 0.1, distance = 0.1 }, { node = wall, x = 0, y = 0, z = 2, distance = 1.9 } }
  CM.camera = { screenToRay = function() return 0, 0, 0, 0, 0, 1 end, screenRect = function() return 0, 0, 1280, 720 end }
  CM.raycast = function(ox, oy, oz, dx, dy, dz, range, opts) casts[#casts + 1] = { oz = oz, opts = opts }; return table.remove(hits, 1) end
  local pc = { firstPerson = true }
  CM.findScript = function(k) if k == "planet_camera" then return pc end end
  local who = { kind = "crew", node = astro, id = "astro" }
  local tp, why, info = CM.pick(640, 360, who)
  check(casts[1] and casts[1].opts and casts[1].opts.ignore == astro and casts[1].opts.ignoreChildren == true,
    "from the eyes the ray passes the actor AND its subtree (ignoreChildren)")
  check(#casts == 2 and casts[2].oz >= 0.6 - 1e-9 and tp and tp.kind == "prop" and tp.node == wall and info.recast == "Helmet",
    string.format("a hit on the crew's own helmet at the lens is cast past from %.2f m: the wall behind (%s)", casts[2] and casts[2].oz or -1, tostring(tp and tp.kind)))
  hits = {}
  casts = {}
  local tn, whyn = CM.pick(640, 360, who)
  check(tn == nil and whyn == "nothing in reach", "nothing under the crosshair in first person: no menu (no silent EVA-suit fallback), and why: " .. tostring(whyn))
  hits = { { node = astro, x = 0, y = 0, z = 0.05, distance = 0.05 } }
  local ta = CM.pick(640, 360, who)
  check(ta == nil, "from the eyes the crew never pick themselves (hold the Context key for the suit)")
  -- seated aboard without the controls (Ty's slot1: Talia in "Untitled"'s
  -- seat): the craft asks, a tap is never silently nothing
  local seatV = { node = { id = 77, valid = true }, crewAboard = true }
  CM.findScript = function(k)
    if k == "planet_walker" then return { onFoot = false } end
    if k == "crew" then return { avatarCraft = function() return seatV end } end
  end
  CM.find = function(n) if n == "Astronaut" then return astro end end
  local wseat = CM.actorNow()
  check(wseat and wseat.kind == "craft" and wseat.vessel == seatV and wseat.seated, "seated aboard, not flying: the craft is the actor (not nil)")
  CM.findScript = function(k) if k == "planet_camera" then return pc end end
  local st = CM.selfTarget(who)
  check(st and st.kind == "astro" and st.node == astro, "the suit's own menu has its own gesture (selfTarget)")
end

-- ── the plate never hands ui.make a function (the console's blank menu) ────
do
  local made
  local REG = load_script("context_registry.lua", env({}, {}, {}))
  REG.register("prop", function()
    return { { id = "pg", type = "action", label = "Console: next page", hint = function() return "POISONS" end, act = function() end, group = "Reactor" },
             { id = "lv", type = "action", label = function() return "Search the crate" end, act = function() end },
             { id = "inf", type = "info", label = "Why", value = function() return "a long reason that has to wrap over several lines of the plate" end },
             { id = "sb", type = "sub", label = "Inspect…", sub = function() return {} end } }, function() return "Reactor Control Console" end
  end, { id = "t", order = 1 })
  local scripts = { context_registry = REG, planet_walker = { onFoot = true } }
  local astro = { id = 14, name = "Astronaut", valid = true, distanceTo = function() return 1 end }
  local CM = load_script("context_menu.lua", env({}, scripts, {
    input = { pressed = function() return false end, button = function() return false end, mouse = function() return 0, 0 end,
              mouse_delta = function() return 0, 0 end, setMouseLocked = function() end, action = function() return false end },
    ui = { make = function(_, t) made = t end, focus = function() end },
    camera = { screenRect = function() return 0, 0, 1280, 720 end },
    find = function(n) if n == "Astronaut" then return astro end end }))
  local node = { getcomponent = function() return { visible = false } end }
  CM.start(node)
  local wall = { id = 5, name = "Wall", valid = true }
  CM.openFor({ kind = "prop", node = wall, label = "Wall" }, { kind = "crew", node = astro, id = "astro" }, 640, 360)
  T = T + 1
  CM.update(node, 0.016)
  local bad, texts = {}, {}
  local function walk(t)
    if type(t) ~= "table" then return end
    if t.text ~= nil then
      if type(t.text) ~= "string" then bad[#bad + 1] = tostring(t.key) .. "=" .. type(t.text) else texts[#texts + 1] = t.text end
    end
    if t.tooltip ~= nil and type(t.tooltip) ~= "string" then bad[#bad + 1] = "tooltip " .. type(t.tooltip) end
    for _, v in pairs(t) do if type(v) == "table" then walk(v) end end
  end
  walk(made)
  local all = table.concat(texts, "|")
  check(made ~= nil and #bad == 0, "every text and tooltip the plate gives ui.make is a string (no function): " .. table.concat(bad, ", "))
  check(all:find("POISONS", 1, true) and all:find("Search the crate", 1, true) and all:find("Reactor Control Console", 1, true),
    "…a live hint, label and title are resolved into their words")
end

-- ── the open menu asks its providers once, then reads live values (Ty 11-11:
-- every provider asked 8 times a second took a base part's menu to 1 fps) ──
do
  local makes, asked, reads, reading = 0, 0, 0, 1.0
  local REG = load_script("context_registry.lua", env({}, {}, {}))
  REG.register("prop", function()
    asked = asked + 1
    return { { id = "rd", type = "info", label = "Reading", value = function() reads = reads + 1; return string.format("%.1f", reading) end },
             { id = "sw", type = "toggle", label = "Switch", on = function() return true end, act = function() return true end } }, "Piece"
  end, { id = "t", order = 1 })
  local STR = { version = 1 }
  local scripts = { context_registry = REG, planet_walker = { onFoot = true }, structures = STR }
  local astro = { id = 14, name = "Astronaut", valid = true, distanceTo = function() return 1 end }
  local CM = load_script("context_menu.lua", env({}, scripts, {
    input = { pressed = function() return false end, button = function() return false end, mouse = function() return 0, 0 end,
              mouse_delta = function() return 0, 0 end, setMouseLocked = function() end, action = function() return false end },
    ui = { make = function() makes = makes + 1 end, focus = function() end },
    camera = { screenRect = function() return 0, 0, 1280, 720 end },
    find = function(n) if n == "Astronaut" then return astro end end }))
  local node = { getcomponent = function() return { visible = false } end }
  CM.start(node)
  CM.openFor({ kind = "prop", node = { id = 6, name = "Pump", valid = true }, label = "Pump" }, { kind = "crew", node = astro, id = "astro" }, 640, 360)
  local function run(secs) for _ = 1, math.floor(secs * 60) do T = T + 1 / 60; CM.update(node, 1 / 60) end end
  run(0.02)
  check(asked == 1 and makes == 1, "opening: the providers asked once, the plate made once (" .. asked .. ", " .. makes .. ")")
  local r0 = reads
  run(1.5)
  check(asked == 1, "held 1.5 s: the providers are not asked again (" .. asked .. ")")
  check(reads - r0 >= 4 and reads - r0 <= 8, "…its live value read at the refresh rate, 4 Hz (" .. (reads - r0) .. " reads)")
  check(makes == 1, "…nothing changed: the engine is not handed the plate again (" .. makes .. " makes)")
  reading = 2.0
  run(0.3)
  check(makes == 2 and asked == 1, "a live value changed: the plate made again from the kept rows (" .. makes .. " makes, " .. asked .. " asks)")
  STR.version = 2
  run(0.02)
  check(asked == 2, "the structures changed: the providers asked again at once (" .. asked .. ")")
  run(2.1)
  check(asked == 3, "…and every rows_keep (2 s) anyway (" .. asked .. ")")
  CM.press("sw")
  run(0.02)
  check(asked >= 4, "a press asks them again at once (" .. asked .. ")")
  local P = CM.PROF
  check(P.rows == asked - 1 or P.rows == asked, "PROF counts the provider passes (" .. tostring(P.rows) .. ")")
end

-- ── logic_net: the authority ────────────────────────────────────────────────
local LN
do
  STORE["lg.wires"] = {
    { id = 1, a = { sid = 7, uid = 11, pin = "Q" }, z = { sid = 7, uid = 1, pin = "run" } },   -- a sensor drives the pump
  }
  LN = load_script("logic_net.lua", env(STORE, SCR, {}))
  SCR.logic_net = LN
  local w, from = LN.drivenBy(7, 1)
  check(w and from == "Level Sensor Q", "the pump's RUN has a cable: driven by " .. tostring(from))
  check(LN.drivenBy(7, 11) == nil, "the sensor itself (its cable is an OUT) is driven by nothing")
  check(LN.drivenBy(7, 2) == nil, "the valve with no cable is the hand's")
  local why = LN.whyNot(7, 1, false)
  check(why and why:find("driven by the Signal Cable from Level Sensor Q", 1, true) and why:find("Local control", 1, true), "the hand is refused, and told how: " .. tostring(why))
  LN.setLocal(7, 1, true)
  check(LN.localControl(7, 1) and LN.whyNot(7, 1, false) == nil, "Local control on: the hand has it")
  LN.setLocal(7, 1, false)
  check(not LN.localControl(7, 1) and REC.st["1"] == nil, "Local control off again leaves no state behind")
end

-- ── fluid_net: the hand refused by the cable, then Local control ──────────
do
  local FN = load_script("fluid_net.lua", env(STORE, SCR, {}))
  SCR.fluid_net = FN
  local ok, why = FN.setOn(7, 1, false, "hand")
  check(ok == false and why and why:find("Signal Cable", 1, true), "fluid_net.setOn by hand on a driven pump: refused, " .. tostring(why))
  check(FN.setOn(7, 1, false, "logic") == true and not FN.isOn(7, 1), "…the cable itself still drives it (by = logic)")
  LN.setLocal(7, 1, true)
  check(FN.setOn(7, 1, true, "hand") == true and FN.isOn(7, 1), "…Local control on: the hand starts it")
  LN.setLocal(7, 1, false)
  local okw, ww = FN.setOn(7, 12, true, "hand")
  check(okw == false and ww == "the Wall (steel) is not on a fluid network", "a wall answers in a sentence: " .. tostring(ww))
  local okv = FN.setOn(7, 2, false, "hand")
  check(okv == true and not FN.isOn(7, 2) and FN.setOn(7, 2, true, "hand") == true and FN.isOn(7, 2), "the valve shuts and opens again by hand")
end

-- ── base_grid: a breaker can't close into its trip; a light off draws nothing
do
  local trip = { [4] = "tripped" }
  SCR.base_power = { breakerState = function(sid, uid) return trip[uid] or "closed" end }
  local BG = load_script("base_grid.lua", env(STORE, SCR, {}))
  SCR.base_grid = BG
  local why = BG.whyNot(7, 4, true)
  check(why and why:find("tripped: Reset it first", 1, true), "a tripped breaker won't close by hand: " .. tostring(why))
  check(BG.whyNot(7, 4, false) == nil, "…it can always be opened")
  trip[4] = "open"
  check(BG.whyNot(7, 4, true) == nil, "an open (untripped) breaker closes")
  check(BG.whyNot(7, 3, false) == nil, "a light's switch is never refused by the grid")
  check(BG.powerWhy(7, 3) and BG.powerWhy(7, 3):find("not on a base grid", 1, true), "a load with no grid says why it has no power: " .. tostring(BG.powerWhy(7, 3)))
  -- the model: the light off is not a load
  local function model_need(off)
    REC.st["3"] = off and { off = true } or nil
    local g = { parts = { { rec = REC, p = REC.bp[3], def = DEFS.lightFitting } }, sids = { 7 }, bus = {}, bases = {} }
    local M = BG.gridModel(g, function() return 0, 0, 0, { x = 0, y = 1, z = 0 }, { x = 0, y = 0, z = 1 } end, 0, {})
    return M.need, #M.loads, M.loads[1]
  end
  local n_on, c_on, l_on = model_need(false)
  local n_off, c_off = model_need(true)
  check(c_on == 1 and math.abs(n_on - 0.12) < 1e-9 and l_on.uid == 3, string.format("a light on draws its %.2f kW (a load with its uid)", n_on))
  check(c_off == 0 and n_off == 0, "a light switched off draws nothing")
  REC.st["3"] = nil
end

-- ── kit_live: the light's switch and the cable ──────────────────────────────
do
  STORE["lg.wires"][2] = { id = 2, a = { sid = 7, uid = 11, pin = "Q" }, z = { sid = 7, uid = 3, pin = "on" } }
  LN = load_script("logic_net.lua", env(STORE, SCR, {}))
  SCR.logic_net = LN
  local dirty = 0
  SCR.base_grid = setmetatable({ markDirty = function() dirty = dirty + 1 end }, { __index = SCR.base_grid })
  local KL = load_script("kit_live.lua", env(STORE, SCR, {}))
  local ok, why = KL.setLight(7, 3, false, "hand")
  check(ok == false and why and why:find("Level Sensor Q", 1, true), "a light on a cable: the hand is refused, " .. tostring(why))
  check(KL.setLight(7, 3, false) == true and REC.st["3"] and REC.st["3"].off and dirty == 1, "the cable (no `by`) switches it, and the grid is told (it stops drawing)")
  KL.setLight(7, 3, true)
  table.remove(STORE["lg.wires"], 2)
  LN = load_script("logic_net.lua", env(STORE, SCR, {}))
  SCR.logic_net = LN
  SCR.base_grid = getmetatable(SCR.base_grid).__index
end

-- ── room_air: the machines' switch ──────────────────────────────────────────
do
  local RA = load_script("room_air.lua", env(STORE, SCR, {}))
  check(RA.whyNot(7, 5, false) == nil, "a scrubber switches off by hand")
  check(RA.whyNot(7, 6, true) == "the Air Rack has no switch", "an air rack (a vessel, not a machine) has no switch: " .. tostring(RA.whyNot(7, 6, true)))
  REC.bp[5].wr = true
  local ok, why = RA.setMachine(7, 5, true, "hand")
  check(ok == false and why:find("knocked askew", 1, true), "a knocked scrubber won't start: " .. tostring(why))
  check(RA.setMachine(7, 5, false, "hand") == true and REC.st["5"].off == true, "…but it switches off")
  REC.bp[5].wr = nil
  check(RA.runWhy(7, 5) == "switched off", "switched off, its WHY says so")
  RA.setMachine(7, 5, true, "hand")
  check(RA.runWhy(7, 5) and RA.runWhy(7, 5):find("not in a sealed room", 1, true), "switched on in no room: " .. tostring(RA.runWhy(7, 5)))
end

-- ── reactor_plant: coolant pumps, the interlock, the heat sinks ────────────
do
  local RP = load_script("reactor_plant.lua", env(STORE, SCR, {}))
  local e = { sid = 7, uid = 99, key = "7:99", pumpsOn = {}, S = { prot = true, scram = false }, o = { P = 0.4 },
              pl = { pri = { pumps = { { uid = 7 }, { uid = 8 } } }, sec = { pumps = {}, rejects = { { uid = 9, def = DEFS.coolTower }, { uid = 10, def = DEFS.radPanel } } } } }
  local plant = e
  RP.plantOfPart = function(sid, uid) return plant end
  check(RP.whyNot(7, 7, false) == nil, "two primary pumps running: one may stop")
  e.pumpsOn[8] = false
  -- (Ty 2026-11-10: never refuse the dangerous thing; say what it does)
  check(RP.whyNot(7, 7, false) == nil, "the last primary pump at 40 % may still be stopped by hand (no interlock refusal)")
  local wn = RP.warnOf(7, 7, false)
  check(wn and wn:find("no forced flow at 40 %", 1, true) and wn:find("protection will trip", 1, true), "…its warning says what follows: " .. tostring(wn))
  e.S.prot = false
  wn = RP.warnOf(7, 7, false)
  check(wn and wn:find("BYPASSED: nothing will stop a meltdown", 1, true), "…protection bypassed, the warning says so: " .. tostring(wn))
  e.S.prot = true
  check(RP.warnOf(7, 7, true) == nil, "starting a pump warns of nothing")
  e.pumpsOn[8] = nil
  check(RP.warnOf(7, 7, false):find("without", 1, true), "one of two pumps stopped: less margin, said")
  check(RP.warnOf(7, 9, false) and RP.warnOf(7, 9, false):find("natural draught", 1, true), "the tower's fan off at power: " .. tostring(RP.warnOf(7, 9, false)))
  e.o.P = 0.02
  check(RP.warnOf(7, 9, false) == nil, "…at 2 % it matters little: no warning")
  e.o.P = 0.4
  check(RP.whyNot(7, 13, true) and RP.whyNot(7, 13, true):find("not plumbed to a loop", 1, true), "a coolant pump not on a loop says so: " .. tostring(RP.whyNot(7, 13, true)))
  REC.bp[8].wr = true
  check(RP.whyNot(7, 8, true) and RP.whyNot(7, 8, true):find("knocked askew", 1, true), "a knocked coolant pump won't start (a physical reason): " .. tostring(RP.whyNot(7, 8, true)))
  REC.bp[8].wr = nil
  check(RP.whyNot(7, 9, false) == nil and RP.whyNot(7, 10, false) == nil, "a cooling tower's fan and a radiator's louvres switch")
  check(RP.whyNot(7, 12, true) == "the Wall (steel) has no switch", "a wall in a plant has no switch")
  plant = nil
  check(RP.whyNot(7, 7, true):find("no Reactor Vessel Base", 1, true), "no plant: it has nothing to serve")
end

-- ── part_info: designations, condition, why, the provider ──────────────────
do
  local scn_active, scn = false, nil
  SCR.scenario_run = { isActive = function() return scn_active end, scenario = function() return scn end,
    pieceOf = function(t) if t.uid then return 7, t.uid end return nil end }
  local PI = load_script("part_info.lua", env(STORE, SCR, {}))
  SCR.part_info = PI
  check(PI.cleanTag("  P-3 ") == "P-3" and PI.cleanTag("") == nil and PI.cleanTag("a very long designation") == "a very long " and PI.cleanTag("<b>") == "b",
    "a designation is cleaned: trimmed, 12 characters, no markup")
  check(PI.titleWith("P-3", "Transfer Pump") == "P-3 · Transfer Pump" and PI.titleWith(nil, "Wall (steel)") == "Wall (steel)", "the title: designation · label, or the label")
  check(PI.calledWith(nil, "Gate Valve") == "the Gate Valve" and PI.calledWith("MU-1", "Gate Valve") == "MU-1", "a refusal names it: MU-1, or the Gate Valve")
  check(PI.composeWhy({ nil, "", "no power", "later" }) == "no power" and PI.composeWhy({}) == nil, "WHY is the first reason given")
  local c, w = PI.conditionOf({ wr = true, wrl = "bearing seized" }, nil, {}, 0)
  check(c == "KNOCKED askew: bearing seized" and w == true, "knocked, with the scenario's words: " .. c)
  c, w = PI.conditionOf({ o_p = 0, pitch = math.rad(7), o_c = "" }, { brk = 0.15 }, {}, 0.4)
  check(c == "leaning 7° · rusted · BROKEN: 15 % of its bore open · dust 40 %" and w == true, "a ruin's piece: " .. c)
  check(PI.conditionOf({}, nil, {}, 0) == "sound", "a piece in order is sound")
  -- (2026-11-11) wear on a piece, a craft part's wear, a wreck by its craft
  c, w = PI.conditionOf({ wr = true }, { hp = 0.4 }, {}, 0)
  check(c == "KNOCKED askew · WORN to 40 %" and w == true, "knocked and worn, both said: " .. c)
  check(PI.craftCondition(0.42) == "WORN to 42 % · a Repair Kit mends it" and select(2, PI.craftCondition(0.42)) == true, "a worn craft part: what and the cure")
  check(PI.craftCondition(1) == "sound" and PI.craftCondition(0) == "BROKEN" and PI.craftCondition(nil) == nil, "…sound, broken, none")
  local wc = PI.wreckCondition("Kestrel 2", { dist = 1.24 }, nil, 1.24)
  check(wc == "TORN OFF Kestrel 2 · 1.2 m from its mount · a Repair Kit puts it back on", "a wreck by its craft: " .. wc)
  wc = PI.wreckCondition("Kestrel 2", nil, "it lies 6.0 m from its mount: bring it back (within 3 m)", 6.0)
  check(wc:find("TORN OFF Kestrel 2 · 6.0 m from its mount · it lies", 1, true) ~= nil, "…too far: and why: " .. wc)
  check(PI.wreckCondition("K", { dist = 0.5, broke = true }):find("it broke: it goes back worn", 1, true) ~= nil, "…a broken one goes back worn")
  check(PI.subtitleWith("Kerne Station", 109, 148, "Steel", nil) == "Kerne Station · piece 109 of 148 · Steel", "the subtitle of your own piece")
  check(PI.subtitleWith("Kerne Station", 1, 2, nil, { name = "Ashfall Camp", kind = "survey camp", age = 212 }) == "Ashfall Camp · Abandoned · survey camp · 212 days",
    "a ruin's piece: the site's name is the subtitle")
  -- designations: the part state's, then a running scenario's start.tags
  check(PI.designate(7, 1) == "Transfer Pump" and PI.called(7, 1) == "the Transfer Pump", "no tag: the label")
  scn_active, scn = true, { start = { tags = { { struct = "Kerne Station", uid = 1, name = "P-3" }, { struct = "Kerne Station", uid = 2, name = "MU-1" } } } }
  T = T + 3
  check(PI.designate(7, 1) == "P-3" and PI.called(7, 2) == "MU-1", "a scenario's start.tags name its pieces while it runs")
  check(PI.setTag(7, 2, "V-9") and PI.designate(7, 2) == "V-9", "the player's own name wins")
  PI.setTag(7, 2, "")
  check(PI.designate(7, 2) == "MU-1" and REC.st["2"] == nil, "cleared, the scenario's comes back and no state is left")
  -- …and every refusal says it (the systems ask part_info.called)
  local FN = load_script("fluid_net.lua", env(STORE, SCR, {}))
  REC.bp[2].wr = true
  check(FN.whyNot(7, 2, true) == "MU-1 is knocked askew: repair it first (a Repair Kit, 4 s)", "the refusal names the piece: " .. tostring(FN.whyNot(7, 2, true)))
  -- WHY: knocked first, then the cable, …
  check(PI.whyOf(7, 2) == "knocked askew: a Repair Kit puts it back", "WHY on a knocked valve: " .. tostring(PI.whyOf(7, 2)))
  REC.bp[2].wr = nil
  check(PI.whyOf(7, 1) == "driven by the Signal Cable from Level Sensor Q", "WHY on a pump a cable drives: " .. tostring(PI.whyOf(7, 1)))
  scn_active = false
  T = T + 3
  -- the provider on a kit piece (the menu's own target: a node, the pick)
  local node = { id = 500 }
  SCR.field_builder = { pickTarget = function(t) return REC, REC.bp[12] end }
  ST.partOfNode = function() return REC, REC.bp[12] end
  local rows, title, sub = PI.providerFn({ kind = "prop", node = node }, {})
  local ids = {}
  for _, r in ipairs(rows) do ids[r.id] = r end
  check(title == "Wall (steel)" and sub == "Kerne Station · piece 12 of 13 · Steel", "a wall's own title and subtitle: " .. tostring(title) .. " / " .. tostring(sub))
  check(ids.pi_cond and ids.pi_cond.value() == "sound" and ids.pi_tag and ids.pi_tag.label == "Name this piece…", "its condition and the name row")
  check(ids.pi_why == nil, "a sound wall has no WHY line")
  -- …and on a ruin's piece: its own title, the site as the subtitle
  REC.ru = "ru1"
  SCR.ruins = { site = function() return { name = "Ashfall Camp", kind = "camp", age = 212 } end, peekState = function() return nil end,
    LABEL = { camp = "survey camp" } }
  REC.bp[12].wr, REC.bp[12].wrl = true, nil
  rows, title, sub = PI.providerFn({ kind = "prop", node = node }, {})
  ids = {}
  for _, r in ipairs(rows) do ids[r.id] = r end
  check(title == "Wall (steel)" and sub == "Ashfall Camp · Abandoned · survey camp · 212 days", "a ruin's wall: its own title (not the site's name): " .. tostring(title) .. " / " .. tostring(sub))
  check(ids.pi_cond.value() == "KNOCKED askew" and ids.pi_why and ids.pi_tag == nil, "…knocked, WHY says so, and an unclaimed ruin's piece takes no name")
  REC.ru, REC.bp[12].wr = nil, nil
  -- a non-kit prop (a rock) gets nothing from part_info: its title stays its own
  SCR.field_builder.valid = false
  SCR.field_builder = { pickTarget = function() return nil end }
  local r2, t2 = PI.providerFn({ kind = "prop", node = { id = 501 } }, {})
  check(#r2 == 0 and t2 == nil, "a loose rock is not a piece: part_info stays out of its menu")
end

-- ── the registry: a menu reads IDENTITY → OPERATE → readings → wiring → SALVAGE
do
  local R = load_script("context_registry.lua", env({}, {}, {}))
  R.register("prop", function() return { { id = "d", type = "action", label = "Deconstruct", group = "Base", act = function() end } } end, { id = "fb", order = 6 })
  R.register("prop", function() return { { id = "s", type = "info", label = "Reactor", value = "2 %", group = "Reactor" } } end, { id = "rp", order = 7 })
  R.register("prop", function() return { { id = "t", type = "toggle", label = "Pump running", group = "Fluids", on = true, act = function() end } } end, { id = "fl", order = 8 })
  R.register("prop", function() return { { id = "w", type = "info", label = "Cables", value = "1", group = "Logic" } } end, { id = "lg", order = 6 })
  R.register("prop", function() return { { id = "c", type = "info", label = "Condition", value = "sound", group = "Piece" } }, "P-3 · Process Pump" end, { id = "pi", order = 1 })
  local list, _, title = R.entriesFor({ kind = "prop" }, {})
  local seq = {}
  for _, e in ipairs(list) do if e.type == "header" then seq[#seq + 1] = e.label end end
  check(table.concat(seq, ",") == "Piece,Fluids,Reactor,Logic,Base" and title == "P-3 · Process Pump",
    "the menu reads Piece, the switch's group, the readings, the wiring, salvage: " .. table.concat(seq, ","))
end

-- ── the scenario rulebook validates start.tags ─────────────────────────────
do
  local R = load_script("scenario.lua", env({}, {}, {}))
  local function errs_of(tags)
    local ok, errs = R.validate({ id = "t", title = "T", world = "any", start = { structures = { { bp = "x.bp.txt", name = "Kerne Station" } }, tags = tags } }, {})
    local out = {}
    for _, e in ipairs(errs or {}) do if e:find("start.tags", 1, true) then out[#out + 1] = e end end
    return out
  end
  check(#errs_of({ { struct = "Kerne Station", uid = 116, name = "P-3" }, { struct = "struct:Kerne Station", part = "flValve", name = "MU-1" } }) == 0,
    "good tags pass (by uid, by part, with or without struct:)")
  local e = errs_of({ { struct = "Nowhere", uid = 1, name = "A" }, { struct = "Kerne Station", name = "B" }, { struct = "Kerne Station", uid = 1.5, name = "C" },
    { struct = "Kerne Station", uid = 2, name = "" }, { struct = "Kerne Station", uid = 3, name = "P-3" }, { struct = "Kerne Station", uid = 4, name = "P-3" } })
  check(#e == 5, "bad tags are each named (no structure, no piece, a fractional uid, an empty name, a duplicate): " .. table.concat(e, " | "))
end

if #failures > 0 then
  print("FAIL smoke_interact: " .. #failures .. " of " .. (#failures + passed))
  for _, m in ipairs(failures) do print("  - " .. m) end
  os.exit(1)
end
print(string.format("smoke_interact: %d checks passed", passed))
