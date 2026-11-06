-- SMOKE: the detail editor at a Build Stand (work/standeditor/PLAN.md §12.1),
-- on the real craft_orient, craft_stand, structures, field_builder,
-- base_economy, parts_registry and build_host, a stub engine and a stub
-- builder.
--
--   1. orientation: kindOf on a rover, a plane, a rocket and a bike; a rover
--      saved on its side turned wheels down (its wheel plane's normal to +Y),
--      a plane saved standing laid level with its nose to +X, a rocket that
--      stands upright left alone; four quarter turns are the identity;
--      settle puts the lowest box on the floor;
--   2. how it sits: deckFit gives step 6's 0.6 m for the rover, the floor
--      offset is the belly over the tyres, 0.6 m of ground under a corner
--      raises the need by 0.6;
--   3. the diff: commitQuote for an empty stand → six parts (one truck),
--      parts swapped within the minute (all back) and after it (the price),
--      a pure removal (a refund, no truck), nothing changed ($0); payFor
--      charges, refunds and refuses off the home world;
--   4. the work in progress: saveWip with no command part keeps it, Commission
--      refuses it with the reason, the stand can't come down, an empty WIP
--      empties the stand;
--   5. the stand's CHECK rows S1–S7 on fixtures;
--   6. the host: enter{ stand } refuses with no stand, a held craft or a stand
--      out of the scene; makes ONE BuildFrame under the planet at
--      G + U·(h + clear − fo − 0.11), up U, +X the stand's front; the
--      VAB's keys are put back on leave; the astronaut stays in view while
--      building and is unparked; leave charges the diff and keeps the craft on
--      the stand; ESC's host escape and COMMISSION go the same way;
--      hostContext.afford refuses a part the agency can't pay for.
--
--   luajit solar/tests/smoke_stand_editor.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, e) return math.abs(a - b) <= (e or 1e-6) end

local function env(store, scripts, extra)
  local E = setmetatable({
    time = 5.0,
    save = {
      get = function(k) return store[k] end,
      set = function(k, v) store[k] = v end,
      delete = function(k) local had = store[k] ~= nil; store[k] = nil; return had end,
      flush = function() end,
    },
    findScript = function(k) return scripts[k] end,
    findScripts = function(k) return {} end,
    find = function() return nil end,
    log = function() end,
  }, { __index = _G })
  for k, v in pairs(extra or {}) do E[k] = v end
  return E
end
local function load_script(path, E)
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, E)
  f()
  E.params = {}
  for k, v in pairs(E.defaults or {}) do E.params[k] = v end
  return E
end

local REGE = load_script("parts_registry.lua", env({}, {}))
local PAERO = load_script("parts_aero.lua", env({}, {}))
PAERO.register(REGE.REG, REGE.CATALOGUE)
local function part(uid, id, x, y, z, o)
  o = o or {}
  local d = REGE.REG[id]
  return { uid = uid, id = id, prefab = d.prefab, label = d.label, x = x, y = y, z = z, yaw = o.yaw or 0, pitch = o.pitch or 0,
           roll = o.roll or 0, parent = o.parent or 0, h = d.h, mass = d.mass, cost = d.cost, kind = d.kind,
           rx = d.rx or 0, rz = d.rz or 0, wheel = d.wheel or "", front = d.front and 1 or 0, seat = d.seat and 1 or 0,
           af = type(d.af) == "string" and d.af or nil, thrust = d.thrust or 0 }
end
local HP = math.pi / 2
local function rover()
  return {
    part(1, "roverBody", 0, 0.62, 0),
    part(2, "wheelM", 0.66, 0.42, 0.7, { yaw = -HP }), part(3, "wheelM", 0.66, 0.42, -0.7, { yaw = HP }),
    part(4, "wheelM", -0.66, 0.42, 0.7, { yaw = -HP }), part(5, "wheelM", -0.66, 0.42, -0.7, { yaw = HP }),
    part(6, "seat", 0, 1.42, 0),
  }
end

local CO = load_script("craft_orient.lua", env({}, {}))
local CM = load_script("craft_mode.lua", env({}, {}))
local CS0 = load_script("craft_stand.lua", env({}, {}))
local PB = load_script("parts_base.lua", env({}, {}))
local S = PB.partInfo("stand").stand

-- ── 1. orientation ──────────────────────────────────────────────────────────
local R = rover()
check(CO.kindOf(R, nil, CM) == "rover", "kindOf: a rover (craft_mode.autoOf)")
check(CO.kindOf(R, "plane") == "aircraft", "kindOf: a set kind wins (plane → aircraft)")
local up = CO.upAxis(R, "rover")
check(near(up.y, 1, 1e-9), "a rover built upright: up is +Y")
check(CO.basisFor(R, "rover") == nil, "...and AUTO leaves it alone (within 5°)")
-- the same rover saved on its side (rolled 90° about X): every point and part turned
local function turned(list, Q)
  local out = {}
  for i, d in ipairs(list) do
    local c = {}
    for k, v in pairs(d) do c[k] = v end
    local p = CO.apply(Q, { x = d.x, y = d.y, z = d.z })
    c.x, c.y, c.z = p.x, p.y, p.z
    -- the part's own axes turned too: X, Y from axesOf, rebuilt as euler (YXZ)
    local X, Y = CO.axesOf(d)
    X, Y = CO.apply(Q, X), CO.apply(Q, Y)
    local Z = { x = X.y * Y.z - X.z * Y.y, y = X.z * Y.x - X.x * Y.z, z = X.x * Y.y - X.y * Y.x }
    -- YXZ: pitch = asin(−Z.y), yaw = atan2(Z.x, Z.z), roll = atan2(X.y, Y.y)
    c.pitch = math.asin(math.max(-1, math.min(1, -Z.y)))
    c.yaw = math.atan2(Z.x, Z.z)
    c.roll = math.atan2(X.y, Y.y)
    out[i] = c
  end
  return out
end
local side = turned(R, CO.axisTurn("x", 1))
local ups = CO.upAxis(side, "rover")
check(near(math.abs(ups.z), 1, 1e-6), "a rover saved on its side: its up lies along Z")
local Q = CO.basisFor(side, "rover")
check(Q ~= nil, "AUTO turns it")
local back = turned(side, Q)
local nb = CO.upAxis(back, "rover")
check(near(nb.y, 1, 1e-6), string.format("...wheels down: the wheel plane's normal to +Y (%.4f)", nb.y))
local lowest_wheel, body_y = math.huge, nil
for _, d in ipairs(back) do
  if d.wheel ~= "" then lowest_wheel = math.min(lowest_wheel, d.y) end
  if d.id == "roverBody" then body_y = d.y end
end
check(body_y and body_y > lowest_wheel, "...the body over the wheels")
local fx = CO.noseAxis(back, "rover", { x = 0, y = 1, z = 0 })
check(fx and near(fx.x, 1, 1e-6), "...its nose (the rover body's +X) to +X, the builder's front")
-- a plane saved standing: a cockpit pointing up
-- (a level plane: the cockpit's nose (+Y) along +X, gear under it; then the
-- same craft built standing up, turned 90° about Z)
local level = { part(1, "cockpit", 0, 1.2, 0, { roll = -HP }), part(2, "gearS", 0.9, 0.3, 0), part(3, "gearS", -0.6, 0.3, 0.6),
                part(4, "gearS", -0.6, 0.3, -0.6) }
check(CO.basisFor(level, "aircraft") == nil, "a plane built level: AUTO leaves it")
local plane = turned(level, CO.axisTurn("z", 1))
local pk = CO.kindOf(plane, "plane")
local Qp = CO.basisFor(plane, pk)
if Qp then
  local laid = turned(plane, Qp)
  local cyx = select(2, CO.axesOf(laid[1]))
  check(near(cyx.x, 1, 1e-6) and math.abs(cyx.y) < 0.1, string.format("a plane saved standing: laid level, nose to +X (%.3f, %.3f)", cyx.x, cyx.y))
else
  check(false, "a plane saved standing: AUTO turns it")
end
-- a rocket standing upright: left alone
local rocket = { part(1, "engineS", 0, 0.65, 0), part(2, "tankS", 0, 1.8, 0), part(3, "pod", 0, 2.7, 0) }
check(CO.kindOf(rocket, nil, CM) == "rocket" and CO.basisFor(rocket, "rocket") == nil, "a rocket standing upright: left alone")
-- a bike: two wheels in line
local bike = { part(1, "roverBody", 0, 0.62, 0), part(2, "wheelM", 0.7, 0.42, 0, { yaw = HP }), part(3, "wheelM", -0.7, 0.42, 0, { yaw = HP }) }
local ub = CO.upAxis(bike, "rover")
check(near(ub.y, 1, 1e-6), "a bike: up is square to its wheel line, toward its mass")
-- four quarter turns
local I = CO.axisTurn("y", 1)
for _ = 1, 3 do I = CO.mul(CO.axisTurn("y", 1), I) end
check(near(I.X.x, 1, 1e-12) and near(I.Y.y, 1, 1e-12) and near(I.Z.z, 1, 1e-12), "four ↻Y are the identity")
local QxQx = CO.mul(CO.axisTurn("x", 1), CO.axisTurn("x", -1))
check(near(QxQx.Y.y, 1, 1e-12) and near(QxQx.Z.z, 1, 1e-12), "↻X then SHIFT+↻X: back where it was")
check(near(CO.settle(R, 0.11), 0.11 - 0.02, 1e-9), "settle: the lowest box (the tyres, 0.02) onto the floor 0.11")

-- ── 2. how it sits ──────────────────────────────────────────────────────────
local fit = CO.deckFit(R, S, CS0)
check(fit.need and near(fit.need, 0.6, 1e-9), "deckFit: the rover needs step 6's 0.6 m (" .. tostring(fit.need) .. ")")
check(near(CO.floorOffset(R, S, CS0), 0.45, 1e-9), "the floor offset: its belly 0.45 m over its tyres")
local fit2 = CO.deckFit(R, S, CS0, 0.10, 0.6)
check(near(fit2.need, 1.2, 1e-9), "0.6 m of ground under a corner: 0.6 m more")
check(CO.deckFit({}, S, CS0).need == nil, "nothing on the deck: no need")

-- ── 3. the diff ─────────────────────────────────────────────────────────────
local EC = load_script("base_economy.lua", env({}, {}))
local bp6 = { parts = rover() }
local hull = 0
for _, d in ipairs(bp6.parts) do hull = hull + d.cost end
local q1 = CS0.commitQuote({}, bp6, EC, 100, {})
check(q1.added == hull and q1.ship == EC.shipping(hull) and q1.total == hull + EC.shipping(hull) and q1.n_add == 6 and q1.removed == 0,
  string.format("empty stand → six parts: $%d + one truck $%d", q1.added, q1.ship))
local committed = q1.committed
local paid = { cost = q1.cost, ship = q1.ship, total = q1.total, t = 100 }
-- swap the seat for a probe core within the minute
local bp7 = { parts = rover() }
bp7.parts[6] = part(7, "probe", 0, 1.0, 0)
local q2 = CS0.commitQuote(committed, bp7, EC, 130, paid)
local seat_cost, probe_cost = REGE.REG.seat.cost, REGE.REG.probe.cost
check(q2.added == probe_cost and q2.removed == seat_cost and q2.refund > seat_cost and q2.ship == EC.shipping(probe_cost),
  string.format("a swap within the minute: the seat back with its share of the truck ($%d), the probe bought ($%d)", q2.refund, q2.added))
local q3 = CS0.commitQuote(committed, bp7, EC, 200, paid)
check(q3.refund == seat_cost, "after the minute: the seat's price back, shipping kept")
local bp5 = { parts = rover() }
bp5.parts[6] = nil
local q4 = CS0.commitQuote(committed, bp5, EC, 300, paid)
check(q4.added == 0 and q4.ship == 0 and q4.total == -seat_cost, "a part taken off: a refund, no truck")
local q5 = CS0.commitQuote(committed, bp6, EC, 300, paid)
check(q5.total == 0 and q5.n_add == 0 and q5.n_rem == 0, "nothing changed: $0")
local bpc = { parts = rover() }
bpc.parts[1].cost = bpc.parts[1].cost + 25
local q6 = CS0.commitQuote(committed, bpc, EC, 300, paid)
check(q6.n_add == 1 and q6.n_rem == 1 and q6.total == 25 + EC.shipping(bpc.parts[1].cost), "a part whose price changed: off and on again")

-- ── 4. the work in progress, with the real structures and field_builder ────
local s = { ["base.body"] = "Vever", ["agency.clock"] = 1000 }
local CLOCK = { t = 1000 }
local scripts = {}
scripts.deployables = { agencyClock = function() return CLOCK.t end, dateOf = function() return "Day 1, Y1" end }
local ledger = {}
local funds = { v = 50000 }
scripts.company = {
  afford = function(a) return funds.v >= a end,
  balance = function() return funds.v end,
  money = function(v) return "$" .. tostring(v) end,
  spend = function(a, why) if funds.v < a then return false end funds.v = funds.v - a; ledger[#ledger + 1] = { -a, why }; return true end,
  refund = function(a, why) funds.v = funds.v + a; ledger[#ledger + 1] = { a, why } end,
  earn = function(a, why) funds.v = funds.v + a; ledger[#ledger + 1] = { a, why, "earn" } end,
}
scripts.parts_base = PB
scripts.base_economy = EC
scripts.base_snap = load_script("base_snap.lua", env({}, {}))
scripts.builder_history = load_script("builder_history.lua", env({}, {}))
scripts.crew = { activeId = function() return 7 end, hasRole = function(id, r) return r == "engineer" end, credit = function() end, lastHit = {} }
scripts.structures = load_script("structures.lua", env(s, scripts))
local FB = load_script("field_builder.lua", env(s, scripts, { input = { pressed = function() return false end } }))
scripts.field_builder = FB
local CS = load_script("craft_stand.lua", env(s, scripts, { assembly = { info = function() return nil end } }))
scripts.craft_stand = CS
scripts.craft_orient = CO
local ST = scripts.structures
local sid = FB.place(nil, "stand", { body = "Vever", x = 0, y = 600, z = 0, up = { x = 0, y = 1, z = 0 }, fwd = { x = 0, y = 0, z = 1 } }, "money")
check(sid ~= nil, "a stand to edit on")
local f0 = funds.v
local headless = { parts = { part(1, "roverBody", 0, 0.62, 0) } }
headless.parts[1].kind = "structural"
check(CS.saveWip(sid, 1, headless, { committed = {}, paid = { cost = 0, ship = 0, total = 0, t = 1000 }, name = "WIP" }) and funds.v == f0,
  "saveWip: a headless craft kept on the stand, nothing charged")
local st = CS.stateOf(sid, 1)
check(st and st.s == "built" and st.wip == true and st.name == "WIP", "...state built, a work in progress")
check(type(s[CS.STAND_KEY(sid, 1)].committed) == "table", "...with what is paid for (committed) beside it")
local okc, wc = CS.commission(sid, 1)
check(not okc and wc:find("command", 1, true), "Commission refuses it: " .. tostring(wc))
check(FB.removalBlocked(sid, { 1 }) ~= nil, "the stand can't come down with the WIP on it")
check(CS.saveWip(sid, 1, { parts = {} }) and CS.stateOf(sid, 1) == nil and s[CS.STAND_KEY(sid, 1)] == nil, "an empty WIP empties the stand")
local okp = CS.payFor(sid, 1, { total = 500, added = 450, ship = 50, removed = 0, refund = 0, name = "x" })
check(okp and funds.v == f0 - 500, "payFor: the diff charged")
local okr = CS.payFor(sid, 1, { total = -200, added = 0, ship = 0, removed = 200, refund = 200, name = "x" })
check(okr and funds.v == f0 - 300, "payFor: a refund for parts taken off")
s["base.body"] = "Elsewhere"
local oko, wo = CS.payFor(sid, 1, { total = 100, added = 90, ship = 10, removed = 0, refund = 0 })
check(not oko and wo:find("Fabricator", 1, true), "payFor off the home world: refused (" .. tostring(wo) .. ")")
s["base.body"] = "Vever"

-- ── 5. the stand's CHECK rows ───────────────────────────────────────────────
local function rows(st5)
  local out = {}
  CO.standRules({ stand = st5 }, out, {})
  local by = {}
  for _, r in ipairs(out) do by[r.id] = r end
  return by, out
end
local base5 = { body = "Vever", home = "Vever", need = 0.6, wheeled = true, slope = 2 }
local r0 = rows(base5)
check(next(r0) == nil, "a level stand, a rover that fits: no stand rows")
check(rows({ body = "Vever", home = "Vever", need = 0.6, slope = 6, wheeled = false }).S1 ~= nil, "S1: a rocket on 6° of slope")
check(rows({ body = "Vever", home = "Vever", need = 0.6, slope = 2, wheeled = false }).S1 == nil, "...not on 2°")
check(rows({ body = "Vever", home = "Vever", need = 0.6, wheeled = true, front = { name = "the Equipment Shed", d = 3.2 } }).S3.text:find("Equipment Shed", 1, true),
  "S3: the shed in the release path is named")
check(rows({ body = "Vever", home = "Vever", need = 0.6, thrust = true, plume = { name = "The Surface Hab", d = 4 } }).S4 ~= nil, "S4: a hab near the plume")
check(rows({ body = "Vever", home = "Vever", need = 0.6, wheeled = true, plume = { name = "The Surface Hab", d = 4 } }).S4 == nil, "...not for a rover")
check(rows({ body = "Vever", home = "Vever", need = 0.6, standing = true }).S5.rank == 0, "S5: you're standing where it goes")
check(rows({ body = "Vever", home = "Vever", need = nil, needWhy = "it hangs 4.3 m" }).S6.sev == "block", "S6: the stand can't hold it (a block)")
check(rows({ body = "Nami", home = "Vever", need = 0.6, away = true, added = 100 }).S7.sev == "block", "S7: off-world parts block")
check(rows({ body = "Nami", home = "Vever", need = 0.6, away = true, added = 0 }).S7 == nil, "...only when the diff adds parts")
check(rows({ body = "Nami", home = "Vever", need = 0.6, g = 6.1 }).S2.sev == "note", "S2: another world is a note")

-- ── 6. the host ─────────────────────────────────────────────────────────────
local function V(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
local function node(name, extra)
  local n = { name = name, valid = true, x = 0, y = 0, z = 0, vx = 0, vy = 0, vz = 0, visible = true, comps = {}, kids = {} }
  function n:getcomponent(k) return self.comps[k] end
  function n:destroy() self.valid = false end
  function n:toWorld(p) return V(p.x, p.y, p.z) end
  function n:setUp(u, f) self.up, self.fwd = u, f end
  function n:children() return self.kids end
  function n:getChild() return nil end
  for k, v in pairs(extra or {}) do n[k] = v end
  return n
end
local BODY = { x = 5000, y = 0, z = 0 }
local nodes = { ["Astronaut"] = node("Astronaut", { x = 5003, y = 601, z = 0 }), ["Camera 1"] = node("Camera 1"),
                ["Game Manager"] = node("Game Manager"), ["Vever"] = node("Vever") }
nodes["Camera 1"].comps.Camera = { active = true }
local loads, frames = {}, {}
local gm = { loading = false, inputOwner = nil }
-- the stand's node is in the scene (structures sets it via craft_stand.spawned)
local stand_node = node("BaseStand")
CS.spawned(ST.get(sid), ST.getPart(sid, 1), stand_node)
-- a stub builder: what the host reads
local BLD = { craftVersion = 1, parts = rover() }
local builder = {
  craftVersion = 1,
  blueprintNow = function() return { parts = BLD.parts, name = "Dune Bug", v = 2 } end,
  craftName = function() return "Dune Bug" end,
  build_cost = function() local c = 0; for _, d in ipairs(BLD.parts) do c = c + d.cost end; return c end,
  orientRecs = function() local o = {}; for _, d in ipairs(BLD.parts) do o[d.uid] = d end; return o end,
  editBusy = function() return false end,
  checkHook = function(n, fn) BLD.hook = { n, fn } end,
  hint = function() end,
}
scripts.game_manager = gm
local host_scripts = setmetatable({ builder = nil }, { __index = scripts })
local Henv = env(s, host_scripts, {
  params = { fade = 0.35, hold = 8.0, autosave = 2.0 },
  find = function(n) local x = nodes[n]; if x and x.valid ~= false then return x end return nil end,
  findAll = function() return {} end,
  createNode = function(name, parent, cb) local n = node(name, { parent = parent }); nodes[name] = n; frames[#frames + 1] = n; cb(n) end,
  scene = { load = function(n, o) loads[#loads + 1] = { n, o } end, unload = function() end },
  space = { dominant = function() return "Vever" end, body = function() return { x = BODY.x, y = BODY.y, z = BODY.z, radius = 600, mu = 3.6e6, soi = 5000 } end },
  input = {},
  vec3 = V,
})
local H = load_script("build_host.lua", Henv)
H.start(node("Build Host"))
check(H.mode == "world", "the world's host")
-- refusals
check(not H.enter({ stand = { sid = 99, uid = 1 } }), "enter{ stand }: no stand there, refused")
local held_state = CS.stateOf(sid, 1)
-- the VAB's keys before
s["shipyard.current"] = "My Rocket"
s["shipyard.blueprint"] = { parts = { { uid = 1, id = "pod" } }, name = "My Rocket" }
s["shipyard.lockerPlan"] = { ["1"] = { food = 2 } }
local okE, wE = H.enter({ stand = { sid = sid, uid = 1 } })
check(okE, "Build here: the host opens the builder on the stand (" .. tostring(wE) .. ")")
local fr = nil
for _, n in ipairs(frames) do if n.name == "BuildFrame" and n.valid then fr = n end end
local nfr = 0
for _, n in ipairs(frames) do if n.name == "BuildFrame" and n.valid then nfr = nfr + 1 end end
check(fr and nfr == 1 and fr.parent == nodes["Vever"], "ONE BuildFrame, a child of the stand's planet")
local fp = CS.framePose(sid, 1)
check(fr and near(fr.y, fp.G.y + (fp.h + 0.02 - 0 - 0.11), 1e-9) and near(fr.x, fp.G.x, 1e-9),
  string.format("...at the deck: G + U·(h + clear − 0.11) (y %.3f)", fr and fr.y or -1))
check(fr and fr.up and near(fr.up.y, 1, 1e-9) and fr.fwd and near(fr.fwd.x, 1, 1e-9) and near(fr.fwd.z, 0, 1e-9),
  "...up the stand's up, its +X (the builder's front) the stand's front (setUp(U, R): −Z = R)")
check(loads[#loads] and loads[#loads][1] == "builder_overlay" and loads[#loads][2].additive, "the overlay loads additively")
check(gm.inputOwner == "builder", "the builder has the keys")
check(nodes["Astronaut"].visible == true, "the astronaut stays in view")
check(s["shipyard.current"] == "Dune Bug" or s["shipyard.current"] == "Stand " .. tostring(sid) .. " craft", "the builder opens the stand's craft, not the VAB's")
check(H.enter({ stand = { sid = sid, uid = 1 } }) == false, "a second enter while building: refused")
-- the overlay lands
host_scripts.builder = builder
nodes["Builder"] = node("Builder")
nodes["Builder Camera"] = node("Builder Camera")
nodes["Builder Camera"].comps.Camera = { active = false }
H.update(nil, 0.016)
check(H.state == "building" and H.hostKind == "stand", "building at a stand")
check(BLD.hook and BLD.hook[1] == "stand" and BLD.hook[2] == CO.standRules, "the stand's CHECK rows are hooked in")
local hcx = H.standContext()
check(hcx and hcx.kind == "stand" and hcx.world and hcx.world.name == "Vever" and near(hcx.world.g, 3.6e6 / 600 ^ 2, 1e-9),
  "hostContext: a stand, its world's g for TWR")
-- the deck rises for the rover (needFor's rays aren't here: the bounds alone)
Henv.time = 6.0
H.update(nil, 0.016)
-- (nothing raises a 1.0 m deck for a rover that needs 0.6)
check(near(CS.framePose(sid, 1).h, 1.0, 1e-9), "the deck stays: 1.0 m is enough for the rover")
-- the floor offset: the frame drops by the belly over the tyres
check(fr and near(fr.y, fp.G.y + (fp.h + 0.02 - 0.45 - 0.11), 1e-6), string.format("the floor shifts so its belly rests on the deck (y %.3f)", fr and fr.y or -1))
-- afford
funds.v = 100
local okA = hcx.afford(50)
check(not okA, "the placement guard: the parts and their truck would pass the budget")
funds.v = 50000
check(hcx.afford(50), "...and with money, it goes")
-- leave: the diff charged, the craft on the stand, the VAB's keys back
local fL = funds.v
local okL = H.leave()
local stL = CS.stateOf(sid, 1)
check(okL and stL and stL.s == "built" and stL.name == "Dune Bug" and funds.v == fL - (hull + EC.shipping(hull)),
  string.format("LEAVE: on the stand, %s charged (the hull + one truck)", tostring(fL - funds.v)))
check(s["shipyard.current"] == "My Rocket" and s["shipyard.blueprint"].name == "My Rocket" and s["shipyard.lockerPlan"]["1"].food == 2,
  "...the VAB's own keys exactly as they were")
check(gm.inputOwner == nil and H.state == "idle" and H.hostKind == nil, "...the keys back to the world")
check(H.lastStandExit and H.lastStandExit.quote.n_add == 6, "...six parts committed")
-- again: nothing changed → $0; ESC's escape goes the same way
local okE2 = H.enter({ stand = { sid = sid, uid = 1 } })
nodes["Builder"].valid = true
H.update(nil, 0.016)
local f2 = funds.v
local hc2 = H.standContext()
check(okE2 and hc2 and near(hc2.baseline, hull, 1e-9), "Build here again: what was paid for is the baseline")
hc2.escape()
check(funds.v == f2 and H.lastStandExit.quote.total == 0, "ESC with nothing changed: $0")
-- a part taken off within the minute: refunded with its share of the truck
local okE3 = H.enter({ stand = { sid = sid, uid = 1 } })
H.update(nil, 0.016)
BLD.parts[6] = nil
local f3 = funds.v
H.leave()
check(okE3 and funds.v > f3 + seat_cost - 1 and CS.stateOf(sid, 1).n == 5, string.format("the seat taken off: %s back", tostring(funds.v - f3)))
-- a held craft: Build here refused
CS.stateOf(sid, 1).s = "held"
local okH, wH = H.enter({ stand = { sid = sid, uid = 1 } })
check(not okH and tostring(wH):find("release", 1, true), "a commissioned, held craft: release it first (" .. tostring(wH) .. ")")
CS.stateOf(sid, 1).s = "built"
-- a stand out of the scene: walk closer
CS.gone(sid, 1)
stand_node.valid = false
local okW, wW = H.enter({ stand = { sid = sid, uid = 1 } })
check(not okW and tostring(wW):find("walk closer", 1, true), "a stand not in the scene: walk closer")

if #failures > 0 then
  for _, m in ipairs(failures) do print("FAIL: " .. m) end
  print(string.format("smoke_stand_editor: %d passed, %d FAILED", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_stand_editor: all %d checks passed", passed))
