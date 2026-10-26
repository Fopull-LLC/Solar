-- SMOKE HARNESS for the right-click menus: scripts/context_registry.lua (the
-- provider registry), scripts/context_providers.lua (the game's providers)
-- and scripts/context_menu.lua (the pick, the actor, the panel's presses).
--
--   * providers merge in order, a provider's error drops its rows and never
--     the menu, an entry that can't be used says why;
--   * the menu is opened BY an actor (a crew member on foot, or a craft) and
--     every provider sees that actor — reach is the actor's, not a global
--     astronaut's;
--   * the helmet goes through the suit's API and its refusal reason is shown;
--   * a tank lists its own propellant and pumps to another tank;
--   * a locker lists its contents read-only (no transfer UI: that is the
--     item work's, through the same contract);
--   * the builder's part rows: figures, mount, ring;
--   * a hit names the right target (the crew, a part by its node, a crate,
--     a prop) and the menu presses, backs out and closes.
--
--   luajit solar/tests/smoke_context.lua

local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end

local T = 0
local API = {}
local envs = {}
API.findScript = function(kind) return envs[kind] end
API.log = function() end
API.vec3 = function(x, y, z) return { x = x, y = y, z = z } end
API.save = (function()
  local store = {}
  return { get = function(k) return store[k] end, set = function(k, v) store[k] = v end }
end)()

local function load_script(path, kind)
  local env = setmetatable({}, { __index = function(_, k)
    if k == "time" then return T end
    return API[k] or _G[k]
  end })
  local f = io.open("solar/" .. path) and ("solar/" .. path) or path
  local chunk = assert(loadfile(f))
  setfenv(chunk, env)
  chunk()
  env.params = {}
  for k, v in pairs(env.defaults or {}) do env.params[k] = v end
  env.valid = true
  envs[kind] = env
  return env
end

local M = load_script("scripts/materials.lua", "materials")
local inv = load_script("scripts/inventory.lua", "inventory")
local R = load_script("scripts/context_registry.lua", "context_registry")
local PR = load_script("scripts/context_providers.lua", "context_providers")

-- ── the registry ────────────────────────────────────────────────────────────
do
  local calls = {}
  R.register("thing", function(t) calls[#calls + 1] = "b" return { { label = "B row", value = "2" } } end, { id = "b", order = 20 })
  R.register("thing", function(t, c) calls[#calls + 1] = "a"
    return { { id = "x", type = "action", label = "Do", act = function() return true end, group = "G" },
             { type = "toggle", id = "t", label = "Lamp", on = false, act = function(w) calls.want = w return true end, group = "G" } },
      "THE THING", "sub" end, { id = "a", order = 10 })
  R.register("thing", function() error("boom") end, { id = "bad", order = 15 })
  local list, errs, title, sub = R.entriesFor({ kind = "thing" }, {})
  ok(title == "THE THING" and sub == "sub", "the first provider that names a title gives it")
  ok(#errs == 1 and errs[1]:match("^bad"), "a failing provider is reported")
  ok(list[1].type == "header" and list[1].label == "G", "a group gets its header")
  ok(list[2].id == "a.x" and list[3].type == "toggle", "ids are prefixed with the provider")
  ok(list[4].label == "B row" and list[4].type == "info", "a row without act is info, in order after the first provider")
  ok(R.press(list[3]) == true and calls.want == true, "a toggle press asks for the other state")
  ok(R.byId(list, "x") == list[2], "an entry is found by its tail id")
  -- replace by id, and unregister
  R.register("thing", function() return { { label = "B2" } } end, { id = "b", order = 20 })
  local l2 = R.entriesFor({ kind = "thing" }, {})
  ok(l2[#l2].label == "B2", "re-registering an id replaces it")
  ok(R.unregister("thing", "bad") and #R.providers("thing") == 2, "unregister drops a provider")
  local dis = R.normalize({ type = "action", label = "No", enabled = false, why = "because", act = function() end }, "p", 1)
  local okp, why = R.press(dis)
  ok(not okp and why == "because", "a disabled entry says why")
  local job = { secs = 2 }
  local _, _, j = R.press(R.normalize({ type = "action", label = "Long", job = job }, "p", 2))
  ok(j == job, "a timed entry hands its job to the menu")
  local sv = 0.5
  local sl = R.normalize({ type = "slider", get = function() return sv end, set = function(v) sv = v end, min = 0, max = 1, step = 0.25 }, "p", 3)
  R.press(sl, 1); R.press(sl, 1); R.press(sl, 1)
  ok(sv == 1, "a slider steps and clamps")
end

-- providers register into the registry
ok(PR.registerAll(R), "the providers register")
ok(#R.providers("part") >= 6 and #R.providers("astro") == 2, "the part and suit providers are there (the suit, and the task's cancel)")
ok(R.byId(R.entriesFor({ kind = "part" }, {}), "repair") == nil, "no repair entry on a part that isn't damaged")

-- ── actors ──────────────────────────────────────────────────────────────────
local function node(name, x, y, z)
  local n = { name = name, x = x or 0, y = y or 0, z = z or 0, valid = true, id = math.random(1e6) }
  function n:distanceTo(o)
    local ox, oy, oz = o.x, o.y, o.z
    if o.worldPos then ox, oy, oz = o.worldPos.x, o.worldPos.y, o.worldPos.z end
    return math.sqrt((self.x - ox) ^ 2 + (self.y - oy) ^ 2 + (self.z - oz) ^ 2)
  end
  n.worldPos = n
  function n:children() return self.kids or {} end
  return n
end
local crewA = node("Astronaut", 0, 0, 0)
local function ctx_for(actor) return { actor = actor, ref = function(k) return envs[k] end, toast = function() end } end

-- ── the suit ────────────────────────────────────────────────────────────────
do
  envs.planet_walker = { oxygen = 0.5, headUnder = true, o2Left = 30, onFoot = true, valid = true }
  local actor = { kind = "crew", node = crewA, id = "astro", pack = "astro" }
  local list, _, title = R.entriesFor({ kind = "astro", node = crewA, pack = "astro" }, ctx_for(actor))
  local h = R.byId(list, "helmet")
  ok(title == "EVA SUIT", "the suit menu is titled")
  ok(h and not R.usable(h), "without the suit's API the helmet row is there, dimmed")
  local air = R.byId(list, "air")
  ok(air and R.live(air.value) == "30 s left", "the air reads seconds left under water")
  -- the suit's API: refuses in water, takes the helmet off in air
  local on, refuse = true, "not under water"
  envs.suit = { valid = true, helmetOn = function() return on end,
    helmetRefusal = function(want) if not want then return refuse end end,
    setHelmet = function(w) if not w and refuse then return false, refuse end on = w return true end }
  list = R.entriesFor({ kind = "astro", node = crewA, pack = "astro" }, ctx_for(actor))
  h = R.byId(list, "helmet")
  local u, why = R.usable(h)
  ok(not u and why == "not under water", "the suit's refusal is the row's reason")
  refuse = nil
  list = R.entriesFor({ kind = "astro", node = crewA, pack = "astro" }, ctx_for(actor))
  h = R.byId(list, "helmet")
  ok(h.label == "Remove helmet" and R.press(h) and on == false, "Remove helmet takes it off")
  list = R.entriesFor({ kind = "astro", node = crewA, pack = "astro" }, ctx_for(actor))
  h = R.byId(list, "helmet")
  ok(h.label == "Put on helmet" and R.press(h) and on == true, "Put on helmet puts it back")
  envs.inventory_panel = { valid = true, open = false, openCounters = function() envs.inventory_panel.open = true end }
  list = R.entriesFor({ kind = "astro", node = crewA, pack = "astro" }, ctx_for(actor))
  ok(R.press(R.byId(list, "openpack")) and envs.inventory_panel.open, "Open pack opens the pack")
end

-- ── a craft ─────────────────────────────────────────────────────────────────
local E = { valid = true }
local ST = {}
function E.stateOf(rec) ST[rec.uid] = ST[rec.uid] or { charge = 30, lit = false }; return ST[rec.uid] end
function E.modOf(rec, ty) if ty == "battery" and rec.ec and rec.ec > 0 then return { ec = rec.ec } end end
function E.actionsOf(rec)
  if rec.id == "light" then
    return { { id = "lit.on", kind = "on", state = "lit", label = "Lights on" },
             { id = "lit.toggle", kind = "toggle", state = "lit", label = "Light" } }
  end
  if rec.id == "decoupler" then return { { id = "decouple", kind = "trigger", label = "Decouple" } } end
  return {}
end
envs.electronics = E

local craftNode = node("Vessel", 100, 0, 0)
local recs = {
  [1] = { uid = 1, id = "tankM", label = "FT-M Tank", kind = "tank", mass = 0.35, fuel = 160, fuel_t = 0.01, h = 1.5, rx = 0.5, rz = 0.5 },
  [2] = { uid = 2, id = "tankS", label = "FT-S Tank", kind = "tank", mass = 0.2, fuel = 80, fuel_t = 0.01 },
  [3] = { uid = 3, id = "engineM", label = "Anvil", kind = "engine", mass = 0.9, thrust = 85, ve = 173, asl = 0.8, burn = 0.5 },
  [4] = { uid = 4, id = "battery", label = "Battery", kind = "structural", mass = 0.1, ec = 150 },
  [5] = { uid = 5, id = "locker", label = "Stowage Locker", kind = "structural", mass = 0.08, store = 80, st = { locker = 7 } },
  [6] = { uid = 6, id = "light", label = "Floodlight", kind = "structural", mass = 0.01 },
}
local tanks = { { uid = 2, left = 10, cap = 80 }, { uid = 1, left = 150, cap = 160 } }
local hp = { [1] = 0.6 }
local acted = {}
local V = { valid = true, node = craftNode, craftName = "Kestrel", crewAboard = false, throttle = 0.5,
  LOCKER_T = { [5] = 0.012 },
  partHp = function(u) return recs[u] and (hp[u] or 1) or nil end,
  partRec = function(u) return recs[u] end,
  aboardRecs = function() return recs end,
  tankLeft = function(u) for _, t in ipairs(tanks) do if t.uid == u then return t.left end end end,
  tankFuelT = function(u) for _, t in ipairs(tanks) do if t.uid == u then return t.left * 0.01 end end return 0 end,
  tankList = function() return tanks end,
  lockerOf = function(u) if u == 5 then return "locker:7", 80 end end,
  partAction = function(u, id) acted[#acted + 1] = id return true end }
function V.tankTransfer(from, to, units)
  local a, b
  for _, t in ipairs(tanks) do if t.uid == from then a = t end if t.uid == to then b = t end end
  local m = math.min(units or 1e9, a.left, b.cap - b.left)
  a.left, b.left = a.left - m, b.left + m
  return m
end
inv.setCap("locker:7", 80)
inv.add("locker:7", "iron", 4)

local near = { kind = "crew", node = node("Astronaut", 101, 0, 0), id = "astro", pack = "astro" }
local far = { kind = "crew", node = node("Astronaut", 160, 0, 0), id = "astro", pack = "astro" }
local craftActor = { kind = "craft", vessel = V, node = craftNode, id = "craft:1" }

local function part(u) return { kind = "part", vessel = V, uid = u, rec = recs[u], node = craftNode } end

do
  local list, _, title, sub = R.entriesFor(part(1), ctx_for(near))
  ok(title == "FT-M Tank" and sub:match("Kestrel"), "a part's title is its label, under the craft's name")
  local hpr = R.byId(list, "health")
  ok(hpr and R.live(hpr.value):match("^60%%") and R.live(hpr.frac) == 0.6, "health reads the damage model")
  local f = R.byId(list, "fuel")
  ok(f and R.live(f.value):match("^150%.0 / 160 u"), "the tank reads its OWN propellant, not the pool")
  ok(R.live(R.byId(list, "pool").value):match("160 / 240 u in 2"), "and the pool beside it")
  local pump = R.byId(list, "pump")
  ok(pump and pump.type == "sub", "a pump opens a sub-panel")
  local sl = pump.sub()
  local into = R.byId(sl, "out2")
  ok(into and R.press(into), "Pump into it moves propellant")
  ok(tanks[1].left == 80 and tanks[2].left == 80, "…as much as the other tank takes")
  -- the engine and the battery
  list = R.entriesFor(part(3), ctx_for(near))
  ok(R.live(R.byId(list, "thrust").value) == "85 kN" and R.live(R.byId(list, "thrust_sl").value) == "68 kN", "an engine shows vacuum and sea-level thrust")
  list = R.entriesFor(part(4), ctx_for(near))
  ok(R.live(R.byId(list, "charge").value) == "30 / 150 EC", "a battery shows its charge")
  -- the locker: contents, read-only
  list = R.entriesFor(part(5), ctx_for(far))
  local lk = R.byId(list, "locker")
  ok(lk and R.live(lk.value):match("^%d"), "a locker shows its load")
  local cs = R.byId(list, "open")
  local rows = cs.sub()
  local found = false
  for _, e in ipairs(rows) do
    if e.label:match("4 × ") then found = true end
    ok(e.type == "info" or e.type == "meter", "locker contents are read-only rows")
  end
  ok(found, "the locker lists what is in it")
  ok(R.live(R.byId(list, "mass").value) == "92 kg", "a locker's load weighs on the part")
  -- the Take…/Put… sub-panels' titles fit the menu's heading (QA 2026-10-26:
  -- "TAKE FROM THE LOCK…" was cut off)
  for _, id in ipairs({ "take_locker:7", "put_locker:7" }) do
    local e = R.byId(list, id)
    ok(e and e.title and #e.title <= 16, "the " .. id .. " sub-panel's title fits (" .. tostring(e and e.title) .. ")")
  end
  -- actions
  list = R.entriesFor(part(6), ctx_for(near))
  local lt = R.byId(list, "act_lit.toggle")
  ok(lt and lt.type == "toggle" and R.press(lt) and acted[#acted] == "lit.on", "a toggle action sets the part's state through partAction")
  ok(R.byId(list, "act_lit.on") == nil, "the on/off halves are not listed twice")
end

-- ── reach is the actor's ────────────────────────────────────────────────────
do
  local t = part(1)
  local a, d = PR.actorReach(ctx_for(near), t)
  ok(a == "near" and d < 2, "a crew member beside the part is near")
  a, d = PR.actorReach(ctx_for(far), t)
  ok(a == nil and d > 50, "one 60 m away is not, and the distance is given")
  a = PR.actorReach(ctx_for(craftActor), t)
  ok(a == "aboard", "the craft itself is aboard")
  local otherCraft = { kind = "craft", vessel = { node = node("Other") }, node = node("Other"), id = "craft:2" }
  ok(PR.actorReach(ctx_for(otherCraft), t) == nil, "another craft is not")
  ok(PR.actorReach({ ref = function() end }, t) == nil, "no actor, no reach")
  -- the actor reaches every provider
  local seen
  R.register("part", function(tg, c) seen = c.actor return {} end, { id = "spy", order = 99 })
  R.entriesFor(t, ctx_for(craftActor))
  ok(seen == craftActor, "providers are handed the actor")
  R.unregister("part", "spy")
end

-- ── the builder ─────────────────────────────────────────────────────────────
do
  local P = {
    [1] = { uid = 1, id = "tankM", parent = 0, def = { label = "FT-M Tank", mass = 0.35, cost = 220, fuel = 160, strength = 650 } },
    [2] = { uid = 2, id = "fins", parent = 1, att = "radial", sym = 3, def = { label = "Aero Fin", mass = 0.04, cost = 35, strength = 200 } },
    [3] = { uid = 3, id = "fins", parent = 1, att = "radial", sym = 3, def = { label = "Aero Fin", mass = 0.04, cost = 35 } },
  }
  local sel
  local B = { valid = true, FUEL_T_PER_UNIT = 0.01, partRec = function(u) return P[u] end,
    partUids = function() return { 1, 2, 3 } end, selectConnected = function(u, s) sel = s end }
  local list = R.entriesFor({ kind = "builder_part", B = B, uid = 2, rec = P[2] }, ctx_for({ kind = "builder" }))
  ok(R.live(R.byId(list, "att").value) == "on the flank of FT-M Tank", "a part says what it hangs off")
  ok(R.live(R.byId(list, "ring").value) == "ring of 2", "…and its ring")
  ok(R.press(R.byId(list, "selring")) and sel == "ring", "Select symmetry group selects the ring")
  list = R.entriesFor({ kind = "builder_part", B = B, uid = 1, rec = P[1] }, ctx_for({ kind = "builder" }))
  ok(R.live(R.byId(list, "mass").value) == "350 kg dry  ·  1.95 t full", "a tank's mass dry and full")
end

-- ── the menu: picking and pressing ──────────────────────────────────────────
do
  local keys, btn = {}, {}
  local mouse = { 640, 360 }
  local made
  API.input = { pressed = function(k) return keys[k] == true end, button = function(i) return btn[i] == true end,
    mouse = function() return mouse[1], mouse[2] end, mouse_delta = function() return 0, 0 end,
    setMouseLocked = function() end, action = function() return false end }
  API.ui = { make = function(_, t) made = t end, focus = function() end }
  API.find = function(n) if n == "Astronaut" then return near.node end end
  API.camera = { screenRect = function() return 0, 0, 1280, 720 end, worldToScreen = function() return 600, 300, 5, true end }
  local craftHandles = { V }
  API.findScripts = function(k) if k == "vessel_controller" then return craftHandles end return {} end
  envs.planet_walker.onFoot = true
  envs.inventory_panel.open = false   -- (the pack the suit test opened)
  local CM = load_script("scripts/context_menu.lua", "context_menu")
  -- resolving hits
  local partNode = node("PartTankM", 0, 1, 0); partNode.parent = craftNode
  partNode.worldPos = { x = 100, y = 1, z = 0 }
  V.uidOfNode = function(c) return c == partNode and 1 or nil end
  local t = CM.resolve({ node = partNode, x = 100, y = 1, z = 0 })
  ok(t and t.kind == "part" and t.uid == 1 and t.vessel == V, "a hit on a part names the part and its craft")
  t = CM.resolve({ node = near.node, x = 0, y = 0, z = 0 })
  ok(t and t.kind == "astro", "a hit on the crew names the crew")
  local rock = node("LooseRock"); rock.getcomponent = function() return { mass = 0.3 } end
  t = CM.resolve({ node = rock, x = 0, y = 0, z = 0 })
  ok(t and t.kind == "prop" and t.mass == 0.3, "anything else with a body is a prop")
  ok(CM.resolve({ x = 0 }) == nil, "the ground is nothing")
  -- the actor
  local who = CM.actorNow()
  ok(who and who.kind == "crew" and who.id == "astro", "on foot, the crew member is the actor")
  V.piloting = true
  who = CM.actorNow()
  ok(who and who.kind == "craft" and who.vessel == V, "flying, the craft is the actor")
  V.piloting = false
  -- open, press, back out, close
  local node0 = { getcomponent = function() return { visible = false } end }
  CM.start(node0)
  ok(CM.openFor(CM.resolve({ node = partNode, x = 100, y = 1, z = 0 }), CM.actorNow()), "the menu opens on a part")
  T = T + 0.2
  CM.update(node0, 0.016)
  ok(made and made[1] and made[1].style == "panel/frame", "it is drawn as a screwed plate")
  local okp = CM.press("pump")
  ok(okp, "a sub-panel opens")
  local list = CM.entries()
  ok(R.byId(list, "in2") ~= nil, "the sub-panel's rows are showing")
  keys.escape = true
  CM.update(node0, 0.016)
  keys.escape = nil
  ok(CM.isOpen() and CM.escTakenAt == T, "Esc backs out of the sub-panel first (and keeps the press)")
  T = T + 0.01
  keys.escape = true
  CM.update(node0, 0.016)
  keys.escape = nil
  ok(not CM.isOpen(), "a second Esc closes it")
  -- walking away closes it
  CM.openFor(CM.resolve({ node = partNode, x = 100, y = 1, z = 0 }), CM.actorNow())
  near.node.x = 300
  T = T + 0.2
  CM.update(node0, 0.016)
  ok(not CM.isOpen(), "the menu closes when its actor walks away")
  near.node.x = 101
  -- a right TAP opens; a drag doesn't
  API.raycast = function() return { node = partNode, x = 100, y = 1, z = 0 } end
  API.camera.screenToRay = function() return 0, 0, 0, 1, 0, 0 end
  btn[1] = true; CM.update(node0, 0.016); T = T + 0.1
  btn[1] = false; CM.update(node0, 0.016)
  ok(CM.isOpen() and CM.target.uid == 1, "a right tap on a part opens its menu")
  CM.close()
  API.input.mouse_delta = function() return 20, 0 end
  btn[1] = true; CM.update(node0, 0.016); T = T + 0.1
  CM.update(node0, 0.016); T = T + 0.1
  btn[1] = false; CM.update(node0, 0.016)
  ok(not CM.isOpen(), "a right drag (the camera's look) opens nothing")
end

if #failures > 0 then
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  print(string.format("CONTEXT SMOKE FAILED — %d of %d checks", #failures, checks))
  os.exit(1)
end
print(string.format("CONTEXT SMOKE OK — %d checks passed", checks))
