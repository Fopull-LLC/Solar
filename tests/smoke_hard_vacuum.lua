-- SMOKE: HARD VACUUM's freighter and its numbers (scenarios/hard_vacuum),
-- against the real cabin_air graph, damage.holeArea, thermal's dose cone and
-- scenario.lua's validator:
--   * ansel.json is the launch format (tools/perf/vacprobe.sh anselbuild) and
--     carries the uids the scenario names: the Ember (4, critical at 40 %, a
--     rod in), the shadow shield (9), the stores (10, 11), hatch B (12/13),
--     the hab (14), hatch A (15/16), the flight deck (17), both hatches open;
--   * three cabin modules: the stores (two cans), the hab, the flight deck,
--     joined by two docking hatches;
--   * the hole: hp 0.38 is a 7 cm² class hole whose τ on the stores is over
--     the regulator's 60 s, so the stores' bottles feed it (the clock), and
--     run out inside ten minutes;
--   * the dose: every seat sits in the shield's shadow (2 %), and a suit a
--     metre out from the stores' hull is in front of the core (the EVA's
--     dose is real, and staying tight to the hull is the answer);
--   * the framework pieces it brought (craft crew seats, the craft `state`
--     beat, `craft:<name>@<uid>` refs, `cabin.*` meters, `#<uid>` modules)
--     validate, and their mistakes are refused with the field named.
--
--   luajit solar/tests/smoke_hard_vacuum.lua   (from the Floptle checkout)
local failures, passed = {}, 0
local VERBOSE = os.getenv("VERBOSE")
local function check(ok, msg) if VERBOSE then print((ok and "ok    " or "FAIL  ") .. tostring(msg)) end if ok then passed = passed + 1 else failures[#failures + 1] = msg end return ok end
local function env(store, scripts)
  return setmetatable({ time = 5.0, save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end, delete = function(k) store[k] = nil end },
    findScript = function(k) return scripts[k] end, findScripts = function() return {} end, find = function() return nil end, log = function() end }, { __index = _G })
end
local function load_script(path, E) local f = assert(loadfile("solar/scripts/" .. path)); setfenv(f, E); f(); E.params = {}; for k, v in pairs(E.defaults or {}) do E.params[k] = v end; return E end
local function slurp(p) local f = io.open(p, "rb"); if not f then return nil end local t = f:read("*a"); f:close(); return t end

-- a small JSON reader: the builder's library encoding (exact doubles are
-- "\u0000d:<mantissa>:<exponent>")
local function jdecode(s)
  local i = 1
  local function ws() i = s:find("[^ \t\r\n]", i) or #s + 1 end
  local val
  local function str()
    local out, j = {}, i + 1
    while true do
      local c = s:sub(j, j)
      if c == '"' then break end
      if c == "\\" then
        local n = s:sub(j + 1, j + 1)
        if n == "u" then out[#out + 1] = string.char(tonumber(s:sub(j + 2, j + 5), 16) % 256); j = j + 6
        else out[#out + 1] = ({ n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" })[n] or n; j = j + 2 end
      else out[#out + 1] = c; j = j + 1 end
    end
    i = j + 1
    local t = table.concat(out)
    local m, e = t:match("^%z?d:(%-?%d+):(%-?%d+)$")
    if m then return tonumber(m) * 2 ^ tonumber(e) end
    return t
  end
  val = function()
    ws()
    local c = s:sub(i, i)
    if c == "{" then
      local t = {}; i = i + 1; ws()
      if s:sub(i, i) == "}" then i = i + 1 return t end
      while true do
        ws(); local k = str(); ws(); i = i + 1
        t[k] = val(); ws()
        local d = s:sub(i, i); i = i + 1
        if d == "}" then return t end
      end
    elseif c == "[" then
      local t = {}; i = i + 1; ws()
      if s:sub(i, i) == "]" then i = i + 1 return t end
      while true do
        t[#t + 1] = val(); ws()
        local d = s:sub(i, i); i = i + 1
        if d == "]" then return t end
      end
    elseif c == '"' then return str()
    elseif s:sub(i, i + 3) == "true" then i = i + 4 return true
    elseif s:sub(i, i + 4) == "false" then i = i + 5 return false
    elseif s:sub(i, i + 3) == "null" then i = i + 4 return nil
    else
      local n = s:match("^-?[%d%.eE%+%-]+", i); i = i + #n; return tonumber(n)
    end
  end
  return val()
end

local store = { ["agency.clock"] = 1000 }
local S = {}
S.room_air = load_script("room_air.lua", env(store, S))
S_RA = S.room_air
local CR = load_script("crew.lua", env(store, S))
S.damage = load_script("damage.lua", env(store, S))
local CA = load_script("cabin_air.lua", env(store, S))
local TH = load_script("thermal.lua", env(store, S))

local J = jdecode(slurp("solar/scenarios/hard_vacuum/ansel.json") or "{}")
local bp = J and J.bp
check(J and J.fmt == 1 and bp and type(bp.parts) == "table", "ansel.json is the launch format")
local by = {}
for _, d in ipairs(bp and bp.parts or {}) do by[d.uid] = d end
local want = { [4] = "ember", [9] = "shadowShield", [10] = "cabin", [11] = "cabin", [12] = "dockPort", [13] = "dockPort",
               [14] = "cabin", [15] = "dockPort", [16] = "dockPort", [17] = "podMk2" }
local okids = true
for u, id in pairs(want) do if not (by[u] and by[u].id == id) then okids = false; check(false, "uid " .. u .. " is a " .. id .. " (it is " .. tostring(by[u] and by[u].id) .. ")") end end
check(okids, "the uids the scenario names are the parts it means")
local e = by[4] and by[4].st or {}
check(e.critical == true and e.output == 40 and (e.rods or 0) >= 1, "the Ember is critical at 40 % with a rod in")
local hopen = true
for _, u in ipairs({ 12, 13, 15, 16 }) do if not (by[u] and by[u].st and by[u].st.ph == "open") then hopen = false end end
check(hopen, "both hatches start open (a ship in normal running: one air)")

-- the modules: from the parent links and the bolted port pairs (as cabin_air reads a craft)
do
  local recs, ports = {}, {}
  for _, d in ipairs(bp.parts) do
    recs[d.uid] = { uid = d.uid, id = d.id, parent = d.parent or 0, kind = d.kind, dock = d.dock, label = d.label }
  end
  -- bolted pairs: a port whose parent is a port
  for _, d in ipairs(bp.parts) do
    if d.id == "dockPort" and by[d.parent] and by[d.parent].id == "dockPort" then
      ports[#ports + 1] = { uid = d.parent, mate = d.uid }
      ports[#ports + 1] = { uid = d.uid, mate = d.parent }
    end
  end
  local G = CA.buildModules(recs, ports, { seatDef = CR.seatDef, lost = {} })
  local mods = {}
  for i, m in ipairs(G.mods) do mods[#mods + 1] = string.format("%s %.0f m³", m.label, m.V) end
  check(#G.mods == 3, "three cabin modules: " .. table.concat(mods, " / "))
  check(G.mods[G.modOf[10]].label == "Crew Cabin ×2" and G.mods[G.modOf[14]].label == "Crew Cabin",
    "the stores reads \"Crew Cabin ×2\", not the hab's \"Crew Cabin\": " .. G.mods[G.modOf[10]].label)
  check(G.modOf[10] and G.modOf[10] == G.modOf[11] and G.modOf[14] ~= G.modOf[10] and G.modOf[17] ~= G.modOf[14],
    "the stores is the two cans; the hab and the flight deck are their own")
  local pd = 0
  for _, d in ipairs(G.doors) do if d.kind == "port" and (d.b or 0) > 0 then pd = pd + 1 end end
  check(pd == 2, string.format("two docking hatches between them (%d)", pd))
  -- the hole and the clock
  local A = S.damage.holeArea(0.38)
  local V = G.mods[G.modOf[10]].V
  local tau = V / (CA.LEAK_K * A)
  local q = CA.CABIN.cabin.q * 2
  local feed = (CA.CABIN.cabin.F or 0.05) * 2
  local out_at_1 = CA.LEAK_K * A * 0.97
  local mins = q / math.min(feed, out_at_1) / 60
  check(A > 5e-4 and A < 1e-3, string.format("hp 0.38: a %.1f cm² hole", A * 1e4))
  check(tau > 60, string.format("τ %.0f s on the %.0f m³ stores: over 60 s, so its regulator feeds the hole", tau, V))
  check(mins > 4 and mins < 10, string.format("the stores' bottles (%.0f atm·m³) last about %.1f min into the hole", q, mins))
  -- the reading says so: hatch B sealed, the stores holding on its bottles is
  -- not "unbreathable in 40 s" (the scn_vacuum fix); with its regulator off it is
  local S = {}
  for k, d in ipairs(G.doors) do S[k] = (d.kind == "port") and ((d.uids and (d.uids[1] == 12 or d.uids[2] == 12 or d.uids[1] == 13)) and "sealed" or "open") or "sealed" end
  local function reading(regoff)
    local nets, netOf = CA.networksOf(G, S, { hp = function(u) return u == 10 and 0.38 or 1 end,
      regOff = function() return regoff end })
    local i = G.modOf[10]
    local A, Q = {}, {}
    for j, m in ipairs(G.mods) do A[j] = CA.freshAir(m.V); Q[j] = m.qcap end
    return CA.netStatus(S_RA, G, nets[netOf[i]], A, Q, { pout = 0, xout = 0 })
  end
  local on, off = reading(false), reading(true)
  check(on.venting and on.holding and on.untilBad > 360, string.format("the regulator holding it: unbreathable in %.0f s (bottles, then the bleed)", on.untilBad or -1))
  check(off.venting and not off.holding and off.untilBad < 120, string.format("the regulator off: unbreathable in %.0f s", off.untilBad or -1))
end

-- the dose: the shadow over the seats, the hull outside it
do
  local axis = { x = 0, y = 1, z = 0 }
  local core = { x = 0, y = by[4].y, z = 0, ax = 0, ay = 1, az = 0, rad = 0.5, share = 0.4 }
  local sh = by[9]
  local blk = { { uid = 9, x = 0, y = sh.y, z = 0, hx = sh.rx or 0.5, hy = (sh.h or 0.18) / 2, hz = sh.rz or 0.5, k = 0.02 } }
  local worst = 0
  for _, u in ipairs({ 14, 17 }) do
    local def = CR.seatDef(by[u])
    for _, s in ipairs(def and def.seats or {}) do
      local r = TH.doseRate(core, s.x, by[u].y + s.y, s.z, blk, { [u] = true })
      local bare = select(2, TH.coneAt(core, s.x, by[u].y + s.y, s.z))
      if bare > 0 then worst = math.max(worst, r / bare) end
    end
  end
  check(worst > 0 and worst <= 0.021, string.format("every seat is in the shield's shadow (worst %.1f %% of the bare rate)", worst * 100))
  local y10 = by[10].y
  local near = TH.doseRate(core, 0.6, y10, 0, blk)
  local out = TH.doseRate(core, 1.4, y10, 0, blk)
  local msv_min = out * 5000 * 60
  check(out > near * 10, string.format("a suit 1.4 m out from the stores' axis is past the shadow: %.1f mSv a minute at 40 %% (0.6 m out: %.2f)",
    msv_min, near * 5000 * 60))
  check(msv_min > 2 and msv_min < 10, "so three minutes out there is the gold medal's 20 mSv")
end

-- the scenario, and the framework's new fields refused when wrong
do
  local SCN = load_script("scenario.lua", env({}, {}))
  local sc = SCN.load("hard_vacuum")
  check(sc ~= nil and sc.title == "Hard Vacuum", "the scenario loads")
  local ok, errs = SCN.validate(sc, { readJson = function() return { bp = { parts = {} } } end })
  check(ok, "it validates: " .. table.concat(errs or {}, " | "))
  local function deep(t) if type(t) ~= "table" then return t end local o = {}; for k, v in pairs(t) do o[k] = deep(v) end return o end
  local function bad(mut, field)
    local s2 = deep(sc)
    mut(s2)
    local ok2, e2 = SCN.validate(s2, {})
    local hit = false
    for _, m in ipairs(e2 or {}) do if m:find(field, 1, true) then hit = true end end
    check(not ok2 and hit and #e2 == 1, "refused, naming " .. field .. ": " .. table.concat(e2 or {}, " | "))
  end
  bad(function(s2) s2.start.craft[1].crew[1].who = "Nobody" end, "start.craft[1].crew[1].who")
  bad(function(s2) s2.start.craft[1].crew[2].uid = nil end, "start.craft[1].crew[2]")
  bad(function(s2) s2.sequences.core_ten[1].state.st = nil end, "state.st")
  bad(function(s2) s2.meters[2].craft = nil end, "meters[2].craft")
  bad(function(s2) s2.steps[6].mark = "craft:Ansel@aft" end, "steps[6].mark")
  bad(function(s2) s2.steps[2].goals[1].module = "#hab" end, "module")
  -- the builder's library encoding reads back as numbers (the craft file's exact doubles)
  local D = SCN.libDecode({ y = "\0d:4935079412799720:-49", n = 3, s = "x", ["\0n:7"] = "\0f:inf" })
  check(math.abs(D.y - 8.7671) < 1e-3 and D.n == 3 and D.s == "x" and D[7] == math.huge,
    string.format("scenario.libDecode: \"\\0d:m:e\" is m × 2^e (%.4f), keys and specials too", D.y or -1))
  local hints = true
  for _, st in ipairs(sc.steps) do if not st.hint then hints = false end end
  check(hints, "every step has a hint")
end

for _, f in ipairs(failures) do print("FAIL  " .. f) end
print(string.format("smoke_hard_vacuum: %s", #failures == 0 and ("all " .. passed .. " checks passed") or (passed .. " passed, " .. #failures .. " failed")))
if #failures > 0 then os.exit(1) end
