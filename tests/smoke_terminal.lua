-- SMOKE: the base terminals and the base log (work/interact/PLAN.md §4,
-- slices S3 and S4), against the real structures / bases / base_tower /
-- base_cable / base_power / base_grid / thermal / reactor / reactor_plant /
-- fluid_net / room_air / kit_live / logic_net / context_registry /
-- part_info, with stubs for the engine:
--
--   * terminal's pure rules: the page registry (scopes, order, a page put
--     first on one kind of console), what a piece is to a terminal, the
--     reach (wired structures only), the column split, row types;
--   * base_log: the ring (dedupe, cap, newest first), the save shape and
--     back, merged logs, the clock stamp, who did it (and at which console),
--     the breaker hook's TRIP line;
--   * a reactor console's scope on a real plant on a real tower grid: its
--     pages; every operate path through the same whyNot / warnOf as the
--     part menus (context_registry.press): SCRAM, protection bypass (said,
--     never refused), a coolant pump stopped (the warning), the setpoint
--     dimmed while tripped, a breaker opened, trip-tested, refused closing
--     into its trip, reset; a pump and a valve (a knocked valve won't open,
--     a cable has the pump until Local control on the LOGIC page); a door
--     locked; a scrubber; a dark console's keys dim with the reason;
--   * the plate never hands ui.make a function; the LOG page reads back.
--
--   luajit solar/tests/smoke_terminal.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
  return ok
end

local function env(store, scripts, extra)
  local E = setmetatable({
    time = 5.0,
    save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end,
             delete = function(k) local had = store[k] ~= nil; store[k] = nil; return had end },
    findScript = function(k) return scripts[k] end,
    findScripts = function() return {} end,
    find = function() return nil end,
    log = function() end,
    vec3 = function(x, y, z) return { x = x, y = y, z = z } end,
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
  E.valid = true
  return E
end

-- ── terminal: the pure rules ────────────────────────────────────────────────
local TMP = load_script("terminal.lua", env({}, {}))
do
  local f = function() return {} end
  TMP.registerPage("A", f, { order = 30, scopes = { desk = true } })
  TMP.registerPage("B", f, { order = 10, scopes = { desk = true, plc = true } })
  TMP.registerPage("C", f, { order = 60, scopes = { desk = true, plc = true }, orderFor = { plc = 1 } })
  TMP.registerPage("D", f, { order = 5 })
  local function ids(kind) local o = {}; for _, p in ipairs(TMP.pagesFor(kind)) do o[#o + 1] = p.id end return table.concat(o, ",") end
  check(ids("desk") == "D,B,A,C", "a desk's pages in order (a page with no scopes is on every kind): " .. ids("desk"))
  check(ids("plc") == "C,D,B", "on a PLC's desk its LOGIC-like page comes first (orderFor): " .. ids("plc"))
  check(ids("screen") == "D", "a kind with no pages of its own gets only the general ones: " .. ids("screen"))
  check(TMP.unregisterPage("D") and ids("screen") == "", "a page can be taken away")
  check(TMP.registerPage(nil, f) == nil and TMP.registerPage("X", nil) == nil, "a page needs an id and a function")
  -- what a piece is
  local K = TMP.consoleKind
  check(K({ console = { w = 1 } }) == "reactor" and K({ lg = { kind = "plc" } }) == "plc" and K({ lz = { kind = "console" } }) == "fire"
    and K({ piece = "monitor" }) == "desk" and K({ screen = { w = 1 } }) == "screen", "the console pieces: reactor, plc, fire, desk, screen")
  check(K({ piece = "wall" }) == nil and K({ lg = { kind = "lever" } }) == nil and K(nil) == nil, "a wall, a lever, nothing: not terminals")
  check(K({ piece = "monitor" }, {}, { ru = "r1" }) == "ruin" and K({ console = {} }, {}, { ru = "r1" }) == "ruin", "any of them in a ruin is a ruin's terminal")
  -- the reach
  local scope = { sid = 4, sids = { 4, 9 } }
  check(TMP.linked(scope, 9) and TMP.linked(scope, 4) and not TMP.linked(scope, 5) and not TMP.linked(nil, 4), "a console reaches its own and its wired structures only")
  -- columns
  local rows = {}
  for i = 1, 24 do rows[i] = { type = (i == 1 or i == 13) and "header" or "info", label = tostring(i) } end
  local L, R = TMP.splitColumns(rows)
  check(#L == 12 and #R == 12 and R[1].type == "header", "a long page splits at the header nearest its middle")
  local L2, R2 = TMP.splitColumns({ { type = "info", col = 2 }, { type = "info" }, { type = "info", col = 1 } })
  check(#L2 == 2 and #R2 == 1, "rows that name a column go there")
  local L3, R3 = TMP.splitColumns({ { type = "info" }, { type = "info" } })
  check(#L3 == 2 and #R3 == 0, "a short page stays in one column")
  check(TMP.stepPage(1, 5, -1) == 5 and TMP.stepPage(5, 5, 1) == 1 and TMP.stepPage(2, 5, 1) == 3, "TAB and the bumpers wrap over the pages")
  check(TMP.tabLabel(3, "POWER") == "3  POWER", "a page key reads its number")
  check(TMP.normalize({ type = "line", text = "x" }, 1, "P").type == "line" and TMP.normalize({ type = "image" }, 2, "P").id == "P.2"
    and TMP.normalize({ type = "bogus" }, 3) == nil and TMP.normalize({ act = function() end }).type == "action", "row types: the menus' plus line and image; a typo is dropped")
end

-- ── base_log: the ring ──────────────────────────────────────────────────────
local BLP = load_script("base_log.lua", env({}, {}))
do
  local r = BLP.newRing()
  check(BLP.push(r, { t = 10, k = "power", x = "B-1 opened" }) and not BLP.push(r, { t = 11, k = "power", x = "B-1 opened" })
    and BLP.push(r, { t = 13, k = "power", x = "B-1 opened" }) and #r.items == 2, "a repeat within 2 s is one entry; later it is another")
  for i = 1, 260 do BLP.push(r, { t = 100 + i * 3, k = "note", x = "n" .. i }) end
  check(#r.items == BLP.RING_N and r.items[#r.items].x == "n260" and r.items[1].x == "n61", "the ring keeps the newest 200")
  local nw = BLP.newest(r, 3)
  check(#nw == 3 and nw[1].x == "n260" and nw[3].x == "n258", "newest first")
  local back = BLP.unpack_(BLP.pack(r))
  check(#back.items == 200 and back.items[200].x == "n260" and back.items[1].t == r.items[1].t, "the save shape reads back")
  local junk = BLP.unpack_({ { t = 1, x = "ok" }, "nonsense", { t = 2 }, { t = 3, k = "trip", x = "TRIP", w = "auto" } })
  check(#junk.items == 2 and junk.items[1].k == "note" and junk.items[2].w == "auto", "a damaged save keeps what it can")
  local a, b = BLP.newRing(), BLP.newRing()
  BLP.push(a, { t = 5, k = "note", x = "a5" }); BLP.push(b, { t = 7, k = "note", x = "b7" }); BLP.push(a, { t = 9, k = "note", x = "a9" })
  local m = BLP.merged({ [1] = a, [2] = b }, 10)
  check(#m == 3 and m[1].x == "a9" and m[2].x == "b7" and m[2].sid == 2 and m[3].x == "a5", "two structures' logs merge, newest first")
  check(BLP.stamp(0) == "D1 00:00:00" and BLP.stamp(86400 + 3600 + 61) == "D2 01:01:01", "the agency clock: day and time")
  check(BLP.lineOf({ t = 3600, x = "B-1 tripped", w = "Halloran" }) == "D1 01:00:00  B-1 tripped · Halloran", "a log line")
  check(BLP.levelOf("trip") == 2 and BLP.levelOf("warn") == 1 and BLP.levelOf("fluid") == 0, "trips are red, warnings amber, the rest green")
end

-- ── the scene: a tower grid, a reactor plant, a console ─────────────────────
local MU, RS = 9.75e10, 2.0e5
local V = math.sqrt(MU / RS)
local RAD = 800
local bodies = {
  { name = "Sun", x = 0, y = 0, z = 0, vx = 0, vy = 0, vz = 0, radius = 1.0e4, mu = MU, soi = -1, star = true },
  { name = "Vever", x = RS, y = 0, z = 0, vx = 0, vy = V, vz = 0, radius = RAD, mu = 1e5, soi = 5e4 },
}
local SPACE = {
  body = function(n) for _, b in ipairs(bodies) do if b.name == n then return b end end return nil end,
  bodies = function() return bodies end,
  dominant = function() return "Vever" end,
  time = function() return 0 end,
}
local s = { ["base.body"] = "Vever" }
local clock = { a = 1000 }
local scripts = {}
local X = { space = SPACE, terrain = { query = function(x, y, z) local b = bodies[2]; return math.sqrt((x - b.x) ^ 2 + (y - b.y) ^ 2 + (z - b.z) ^ 2) - RAD end } }
scripts.thermal = load_script("thermal.lua", env({}, scripts))
local PK = load_script("parts_kit.lua", env({}, scripts)); scripts.parts_kit = PK
local PB = load_script("parts_base.lua", env({}, scripts)); scripts.parts_base = PB
scripts.electronics = load_script("electronics.lua", env({}, {}))
scripts.deployables = { agencyClock = function() return clock.a end, dateOf = function() return "Day 9, Y1" end }
scripts.base_economy = load_script("base_economy.lua", env(s, scripts))
scripts.company = { spend = function() return true end, refund = function() end, earn = function() end, afford = function() return true end }
local STORE = { base = { fuelRod = 40 } }
scripts.inventory = {
  itemCount = function(c, id) return (STORE[c] or {})[id] or 0 end,
  removeItem = function(c, id, n) local h = (STORE[c] or {})[id] or 0; local k = math.min(h, n); STORE[c][id] = h - k; return k end,
  addItem = function(c, id, n) STORE[c] = STORE[c] or {}; STORE[c][id] = (STORE[c][id] or 0) + n; return n end,
}
local ROSTER = { { id = 2, name = "Mara Halloran", status = "afoot", role = "engineer" }, { id = 3, name = "Dana Kowalczyk", status = "base", role = "scientist" } }
scripts.crew = { activeId = function() return 2 end, credit = function() end, roster = function() return ROSTER end,
                 get = function(id) for _, r in ipairs(ROSTER) do if r.id == id then return r end end end,
                 hasRole = function() return true end, perk = function() return nil end, bestPerk = function() return nil end,
                 roleName = function(r) return r.role == "engineer" and "Engineer" or "Scientist" end, doseOf = function() return 0 end }
scripts.field_builder = { pushHistory = function() end }
scripts.bases = load_script("bases.lua", env(s, scripts))
local ST = load_script("structures.lua", env(s, scripts, X)); scripts.structures = ST
local CB = load_script("base_cable.lua", env(s, scripts, X)); scripts.base_cable = CB
local BPw = load_script("base_power.lua", env(s, scripts, X)); scripts.base_power = BPw
local BG = load_script("base_grid.lua", env(s, scripts, X)); scripts.base_grid = BG
BG.WIRED = false   -- (this test is of the grid as wired before W2: the tower's 150 m, a structure one bus; smoke_wired_grid.lua has the wiring rule)
scripts.base_facilities = { setGuards = function() end }
local BT = load_script("base_tower.lua", env(s, scripts, X)); scripts.base_tower = BT
local RXs = load_script("reactor.lua", env(s, scripts, X)); scripts.reactor = RXs
local RP = load_script("reactor_plant.lua", env(s, scripts, X)); scripts.reactor_plant = RP
scripts.fluids = load_script("fluids.lua", env(s, scripts, X))
local FN = load_script("fluid_net.lua", env(s, scripts, X)); scripts.fluid_net = FN
local LN = load_script("logic_net.lua", env(s, scripts, X)); scripts.logic_net = LN
local KL = load_script("kit_live.lua", env(s, scripts, X)); scripts.kit_live = KL
local RA = load_script("room_air.lua", env(s, scripts, X)); scripts.room_air = RA
local REG = load_script("context_registry.lua", env({}, {})); scripts.context_registry = REG
local PI = load_script("part_info.lua", env(s, scripts, X)); scripts.part_info = PI
local BL = load_script("base_log.lua", env(s, scripts, X)); scripts.base_log = BL
local TM = load_script("terminal.lua", env(s, scripts, X)); scripts.terminal = TM
local TP = load_script("terminal_pages.lua", env(s, scripts, X)); scripts.terminal_pages = TP
BT.start({ id = 1 }); BG.start({ id = 2 }); CB.start({ id = 3 }); BPw.start({ id = 4 }); RP.start({ id = 6 })
BL.start({ id = 8 }); TM.start({ id = 9 }); TP.start({ id = 10 })
local F = dofile("solar/tests/lib/reactor_fixture.lua")

local function struct(x, y, z, part)
  local l = math.sqrt(x * x + y * y + z * z)
  local U = { x = x / l, y = y / l, z = z / l }
  local Fv = { x = -U.y, y = U.x, z = 0 }
  return ST.add(ST.newRecord(nil, "Vever", x, y, z, U, Fv, part))
end
local function settime(dt_real)
  for _, sc in ipairs({ BG, RP, BL, TP }) do local e = getfenv(sc.update); e.time = e.time + dt_real end
end
local function frame(dt_real, dt_game)
  clock.a = clock.a + (dt_game or dt_real)
  settime(dt_real)
  RP.update({}, dt_real)
  BG.update({}, dt_real)
  BL.update({}, dt_real)
  TP.update({}, dt_real)
end
local function run(seconds_game, ticks) for _ = 1, ticks do frame(0.6, seconds_game / ticks) end end

local tA = struct(-RAD, 0, 0, "tower")
BT.update({}, 0.016)
for k = 1, 8 do ST.addPart(tA, { id = "batteryBank", x = -20 - 3 * k, y = 0, z = 0 }) end
local rows0 = { ".RWR.", "WFFFW", "WFRFW", "WFFFW", ".RWR." }
local rec0, U0, cells0 = F.plant(rows0, {})
local map = {}
for _, p in ipairs(rec0.bp) do map[p.uid] = ST.addPart(tA, { id = p.id, x = p.x + 14, y = p.y, z = p.z + 8, yaw = p.yaw, pitch = 0, roll = 0 }) end
local cU = ST.addPart(tA, { id = "reactorConsole.steel", x = 6, y = 0, z = -6 })
local mU = ST.addPart(tA, { id = "monitor.steel", x = 9, y = 0.74, z = -6 })
local sU = ST.addPart(tA, { id = "wallScreen.steel", x = 9, y = 1.6, z = -8 })
local bU = ST.addPart(tA, { id = "breaker63.steel", x = 4, y = 1.2, z = -8 })
local pU = ST.addPart(tA, { id = "flPump.steel", x = -4, y = 0, z = -10 })
local vU = ST.addPart(tA, { id = "flValve.steel", x = -6, y = 0, z = -10 })
local lU = ST.addPart(tA, { id = "liLever.steel", x = -8, y = 1.0, z = -10 })
local dU = ST.addPart(tA, { id = "doorWall.steel", x = 0, y = 0, z = -14 })
local scU = ST.addPart(tA, { id = "scrubber.steel", x = 3, y = 0, z = -14 })
run(10, 4)
local key = RP.keyOf(tA, map[U0.vessel])
for _, c in ipairs(cells0) do if c.ch == "F" then RP.loadRods(tA, map[c.uid], "fuelRod", 4, "base") end end
local okS = RP.startUp(key, 0.5)
run(1800, 300)
local e = RP.plant(key)
check(okS and e and math.abs((e.o.P or 0) - 0.5) < 0.05, string.format("the plant runs at 50 %% (%.3f)", e and e.o.P or -1))

-- ── the console's scope and pages ───────────────────────────────────────────
TP.update({}, 0.016)
local scope = TM.scopeFor(tA, cU)
check(scope and scope.kind == "reactor" and scope.dark == nil and TM.linked(scope, tA), "the reactor console: its scope, on the tower's grid (not dark)")
local function ids(kind) local o = {}; for _, p in ipairs(TM.pagesFor(kind)) do o[#o + 1] = p.id end return table.concat(o, ",") end
check(ids("reactor") == "REACTOR,ALARMS,STATUS,POWER,FLUIDS,DOORS,AIR,LOGIC,CREW,LOG", "the reactor's desk: " .. ids("reactor"))
check(ids("desk") == "STATUS,POWER,FLUIDS,DOORS,AIR,LOGIC,CREW,LOG", "a desk monitor, the base's terminal: " .. ids("desk"))
check(ids("screen") == "STATUS,LOG", "a wall screen reads: " .. ids("screen"))
check(ids("plc") == "LOGIC,STATUS,POWER,LOG", "a PLC's desk, LOGIC first: " .. ids("plc"))
check(ids("ruin") == "RUINLOG,DATA,STATUS,POWER", "a ruin's terminal: its log, its data, what its dead base answers: " .. ids("ruin"))
local sm = TM.scopeFor(tA, mU)
check(sm and sm.kind == "desk" and TM.scopeFor(tA, sU).kind == "screen" and TM.scopeFor(tA, sU).readonly, "the monitor is a desk; the wall screen reads only")
check(TM.scopeFor(tA, bU) == nil, "a breaker panel is not a console")

local function rowsOf(id)
  local r = TM.rows()
  local by = {}
  for _, q in ipairs(r) do by[q.id] = q; local tail = tostring(q.id):match("%.([^%.]+)$"); if tail then by[tail] = by[tail] or q end end
  return r, by
end
local function texts(list)
  local out = {}
  for _, q in ipairs(list) do
    local v = REG.live(q.value) or REG.live(q.text) or ""
    out[#out + 1] = tostring(REG.live(q.label) or "") .. "=" .. tostring(v)
  end
  return table.concat(out, " | ")
end
local function faults(list) for _, q in ipairs(list) do local t = REG.live(q.text); if type(t) == "string" and t:find("PAGE FAULT", 1, true) then return t end end return nil end
local function bad_texts(tree)
  local bad = {}
  local function walk(t)
    if type(t) ~= "table" then return end
    if t.text ~= nil and type(t.text) ~= "string" then bad[#bad + 1] = tostring(t.key) .. "=" .. type(t.text) end
    if t.tooltip ~= nil and type(t.tooltip) ~= "string" then bad[#bad + 1] = "tooltip " .. tostring(t.key) end
    if t.texture ~= nil and type(t.texture) ~= "string" then bad[#bad + 1] = "texture " .. tostring(t.key) end
    for _, v in pairs(t) do if type(v) == "table" then walk(v) end end
  end
  walk(tree)
  return bad
end

local ok = TM.openAt(tA, cU)
check(ok and TM.isOpen() and TM.state().page == "REACTOR", "E at the console opens it on REACTOR")
-- every page builds, without a fault, and its plate is plain text for ui.make
for _, p in ipairs(TM.pagesFor("reactor")) do
  TM.page(p.id)
  local list = TM.rows()
  local tr = TM.treeNow()
  local bad = bad_texts(tr)
  check(#list > 0 and faults(list) == nil and #bad == 0, string.format("page %s builds (%d rows) and hands ui.make only words: %s %s", p.id, #list, tostring(faults(list)), table.concat(bad, ",")))
end

-- REACTOR (S4)
TM.page("REACTOR")
local list, by = rowsOf()
local txt = texts(list)
check(by.rx_scram and by.rx_scram.danger and by.rx_set and by.rx_prot and by.rx_cool, "the desk's keys: SCRAM (red), the setpoint, protection, cool-down")
check(txt:find("Power=", 1, true) and txt:find("Period=", 1, true) and txt:find("Primary flow=", 1, true) and txt:find("Pressuriser=", 1, true)
  and txt:find("ARMED", 1, true), "the live readings: power, period, rods, flow, temperatures, pressuriser, protection: " .. txt:sub(1, 300))
local npump = 0
for _, q in ipairs(list) do if tostring(q.id):find("rxp_", 1, true) then npump = npump + 1 end end
check(npump >= 1, "the coolant pumps are keys on the desk (" .. npump .. ")")
local img = nil
for _, q in ipairs(list) do if q.type == "image" then img = q end end
check(img ~= nil, "a trend picture row (painted in the engine; nil texture in a test: drawn as a dark box)")
-- the setpoint, by the slider
local set0 = e.S.set
TM.press("rx_set", 1)
check(math.abs(e.S.set - (set0 + 0.05)) < 1e-9, string.format("Setpoint + steps it 5 %% (%.2f → %.2f)", set0, e.S.set))
-- protection bypassed: said, never refused
local okP, whyP = TM.press("rx_prot")
check(okP and e.S.prot == false and whyP and whyP:find("nothing will stop a meltdown", 1, true), "protection bypassed from the desk: done, and the warning toasts: " .. tostring(whyP))
list, by = rowsOf()
check(texts(list):find("BYPASSED", 1, true) and REG.live(by.rx_prot.warn) == true, "…the desk shows BYPASSED loud")
TM.press("rx_prot")
check(e.S.prot == true, "…and restores it")
-- SCRAM
local okSc = TM.press("rx_scram")
check(okSc and e.S.scram, "SCRAM from the desk")
local E1 = BL.entries({ tA }, 10)
local saw = false
for _, q in ipairs(E1) do if q.k == "scram" and q.x:find("SCRAM by hand", 1, true) and tostring(q.w):find("Halloran at", 1, true) then saw = true end end
check(saw, "…logged, with who and at which console: " .. (E1[1] and BL.lineOf(E1[1]) or "nothing"))
list, by = rowsOf()
check(by.rx_reset and not by.rx_scram, "tripped: Reset the trip replaces SCRAM")
local okR, whyR = TM.press("rx_set", 1)
check(okR == false and whyR and whyR:find("tripped", 1, true), "the setpoint dims while tripped, with the reason: " .. tostring(whyR))
-- a coolant pump stopped from the desk: allowed, its consequence said
local pkey
for _, q in ipairs(list) do if tostring(q.id):find("rxp_", 1, true) then pkey = q.id break end end
local okp, whyp = TM.press(pkey)
check(okp and RP.pumpOn(tA, tonumber(pkey:match("_(%d+)$"))) == false, "a coolant pump stopped from the desk: " .. tostring(whyp))
TM.press(pkey)
run(30, 30)

-- POWER: a breaker opened, trip-tested, refused closing into its trip, reset
TM.page("POWER")
local bid = "br_" .. tA .. "_" .. bU
list, by = rowsOf()
check(by[bid] ~= nil and REG.live(by[bid].on) == true, "the breaker is a key on POWER, closed")
local okb = TM.press(bid)
check(okb and BPw.breakerState(tA, bU) == "open", "opened from the console")
TM.press(bid)
check(BPw.breakerState(tA, bU) == "closed", "…closed again")
BL.update({}, 0.016)
local okt, wht = TM.press("brt_" .. tA .. "_" .. bU)
check(okt and BPw.breakerState(tA, bU) == "tripped", "a trip test opens it as a fault does")
list, by = rowsOf()
local okc, whyc = TM.press(bid)
check(okc == false and whyc and whyc:find("Reset it first", 1, true), "closing into its trip is refused (a physical reason): " .. tostring(whyc))
local okr = TM.press("brr_" .. tA .. "_" .. bU)
check(okr and BPw.breakerState(tA, bU) == "closed", "Reset closes it")
local trip = false
for _, q in ipairs(BL.entries({ tA }, 20)) do if q.k == "trip" and q.x:find("TRIP", 1, true) then trip = true end end
check(trip, "the trip is in the log (base_power.onBreaker → base_log)")

-- FLUIDS: the pump and the valve, the cable's authority, a knocked valve
TM.page("FLUIDS")
local fv, fp = "fl_" .. tA .. "_" .. vU, "fl_" .. tA .. "_" .. pU
list, by = rowsOf()
check(by[fv] and by[fp], "the pump and the valve are keys on FLUIDS (unpiped, they still switch)")
local okv = TM.press(fv)
check(okv and not FN.isOn(tA, vU), "the valve shut from the console")
local Ev = BL.entries({ tA }, 5)
check(Ev[1] and Ev[1].x:find("shut", 1, true), "…logged: " .. tostring(Ev[1] and Ev[1].x))
ST.getPart(tA, vU).wr = true
local okk, whyk = TM.press(fv)
check(okk == false and whyk and whyk:find("knocked askew", 1, true) and not FN.isOn(tA, vU), "a knocked valve won't open (physical): " .. tostring(whyk))
ST.getPart(tA, vU).wr = nil
TM.press(fv)
check(FN.isOn(tA, vU), "…repaired, it opens")
-- a lever's cable on the pump's RUN terminal: the cable has it
s["lg.wires"] = { { id = 1, a = { sid = tA, uid = lU, pin = "Q" }, z = { sid = tA, uid = pU, pin = "run" } } }
LN.reloadFromSave()
list, by = rowsOf()
local okd, whyd = TM.press(fp)
check(okd == false and whyd and whyd:find("Signal Cable", 1, true), "a pump on a cable: the console is refused, and told how: " .. tostring(whyd))
TM.page("LOGIC")
list, by = rowsOf()
local lid = "loc_" .. tA .. "_" .. pU
check(by[lid] ~= nil, "LOGIC lists the cable-driven pump's Local control (its bypass)")
TM.press(lid)
check(LN.localControl(tA, pU), "…Local control on from the console")
TM.page("FLUIDS")
local okd2 = TM.press(fp)
check(okd2 and not FN.isOn(tA, pU), "…and the pump stops by hand")
s["lg.wires"] = {}
LN.reloadFromSave()

-- DOORS: lock, unlock
TM.page("DOORS")
local dl = "dl_" .. tA .. "_" .. dU
list, by = rowsOf()
check(by[dl] ~= nil, "the door's Lock key")
TM.press(dl)
check(KL.doorHold(tA, dU) == "lock", "locked from the console (kit_live's bolt)")
TM.press(dl)
check(KL.doorHold(tA, dU) == nil and ST.partState(tA, dU) == nil, "…unlocked, no state left behind")

-- AIR: the scrubber
TM.page("AIR")
local sc = "lf_" .. tA .. "_" .. scU
list, by = rowsOf()
TM.press(sc)
check(not RA.machineOn(tA, scU), "the scrubber stopped from the console")
ST.getPart(tA, scU).wr = true
local oks, whys = TM.press(sc)
check(oks == false and whys:find("knocked", 1, true), "a knocked scrubber won't start: " .. tostring(whys))
ST.getPart(tA, scU).wr = nil
TM.press(sc)
check(RA.machineOn(tA, scU), "…repaired, it starts")

-- a dark console: every base key dims with the reason (never the reactor's own desk)
local dark = { sid = tA, uid = mU, kind = "desk", sids = { tA }, dark = "no power: test" }
local en, why = TP.gateOf(dark, function() return nil end)
check(en() == false and why() == "no power: test", "a dark console's keys dim with why it is dark")
local en2, why2 = TP.gateOf({ sid = tA, sids = { tA } }, function() return "a physical reason" end)
check(en2() == false and why2() == "a physical reason", "…a lit one's dim only for the system's own reason")

-- LOG: newest first, a note
TM.page("LOG")
list, by = rowsOf()
local lines = {}
for _, q in ipairs(list) do if q.type == "line" then lines[#lines + 1] = REG.live(q.text) end end
check(#lines >= 6 and by.log_note ~= nil, string.format("the LOG page reads %d entries, and takes a note", #lines))
BL.saveNow()
check(type(s["log." .. tA]) == "table" and #s["log." .. tA] >= 6, "the log is saved per structure")
local BL2 = load_script("base_log.lua", env(s, scripts, X))
BL2.start({ id = 11 })
check(#BL2.entries({ tA }, 100) == #BL.entries({ tA }, 100), "…and read back by a fresh base_log")

-- the plate's signature: the same plate twice is one make; a changed number is another
do
  local a = TMP.treeSig({ "col", key = "x", { "text", key = "t", text = "POWER 2.0 %" } })
  local b = TMP.treeSig({ "col", key = "x", { "text", key = "t", text = "POWER 2.0 %" } })
  local c = TMP.treeSig({ "col", key = "x", { "text", key = "t", text = "POWER 2.1 %" } })
  check(table.concat(a, "|") == table.concat(b, "|") and table.concat(a, "|") ~= table.concat(c, "|"), "the plate's signature tells a changed number from the same plate")
end

-- the walk away and Esc are scene matters; close is clean
TM.close()
check(not TM.isOpen() and TM.state() == nil, "closed")

-- cost: a page built in this test (luajit, no engine)
TM.openAt(tA, cU)
local t0 = os.clock()
for _ = 1, 50 do TM.page("REACTOR"); TM.rows(); TM.treeNow() end
local ms = (os.clock() - t0) * 1000 / 50
check(ms < 5, string.format("the REACTOR page builds in %.2f ms (luajit, rows + tree)", ms))
print(string.format("smoke_terminal: the REACTOR page builds in %.2f ms here", ms))
TM.close()

-- the scenario rulebook's `terminal` goal: a console open, at a structure, on a page
do
  local SR = load_script("scenario.lua", env({}, { terminal = TM }))
  local Wt = { structId = function(n) return n == "Kerne Station" and tA or nil end }
  local g = { kind = "terminal", struct = "struct:Kerne Station", page = "REACTOR" }
  local met, rd = SR.evalGoal(g, Wt, {}, {})
  check(met == false and rd == "not at a console", "the terminal goal: not met while no console is open (" .. tostring(rd) .. ")")
  TM.openAt(tA, cU)
  met, rd = SR.evalGoal(g, Wt, {}, {})
  check(met == true, "…met with the reactor's desk open on REACTOR (" .. tostring(rd) .. ")")
  TM.page("LOG")
  met, rd = SR.evalGoal(g, Wt, {}, {})
  check(met == false and tostring(rd):find("LOG", 1, true), "…not on another page (" .. tostring(rd) .. ")")
  met = SR.evalGoal(g, { structId = Wt.structId, terminal = function() return { sid = tA, page = "REACTOR" } end }, {}, {})
  check(met == true and SR.goalLabel({ kind = "terminal" }) == "Use the console (E)", "…the runner's W.terminal is read first; its label")
  TM.close()
end

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL " .. f) end
  print(string.format("smoke_terminal: %d passed, %d FAILED", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_terminal: %d checks passed", passed))
