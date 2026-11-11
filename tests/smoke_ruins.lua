-- SMOKE: ABANDONED BASES (expansion X8; scripts/ruins.lua, the ruin entry in
-- fleet_view.lua, the paced and distance-streamed ruins in structures.lua,
-- the held tower in base_tower.lua). Pure and against stubs.
--
--   * sites per world by trait: inhabited worlds 1–3 (and one pending, kept
--     for the life system), once-habitable 1–2 (about a fifth of the rocky
--     airless worlds), the rest a tenth of one camp; the same list every time
--     (a reload rolls nothing new), sites apart;
--   * every kind's build is real kit pieces (each id resolves), one tower,
--     one terminal (the core), crates; a piece hangs only on one before it;
--   * decay: roofs first (30–60 %, more with age), 10–30 % of the walls,
--     never a slab, floor, door, the tower, the terminal, a crate or the
--     silo; what hangs on a lost piece goes with it; deterministic;
--   * the stamp is a valid structure record (structures.lua takes it, every
--     piece poses finite on the site's frame), `ru` kept by the store,
--     back-dated for dust, its lights off, a relay's battery flat; missing()
--     lists exactly what the decay took;
--   * Data Core rewards by kind and multiplier, the log from ≥ 40 fragments;
--     occupant() is nil (the life seam);
--   * THE SCENE HALF over stubs (a smooth world for the field's raycasts):
--     a site is sited, stamped near and taken out far when untouched, kept
--     when touched; found by the crew, by a scanner's swath and by a
--     telescope; the tower is held until claimed (base_tower's question);
--     claim, restore (every missing piece back), repair (the lean undone);
--     a crate searched once into the pack; the core pulled and read (RP, the
--     log, the blueprint); an old save without ruins.s loads unchanged;
--   * fleet_view: a found ruin is an entry (STRUCTURES, ▣, "abandoned · …"),
--     an unclaimed ruin's records are not a second "structure" entry.
--
--   luajit solar/tests/smoke_ruins.lua

local failed, count = 0, 0
local function check(desc, ok, detail)
  count = count + 1
  if not ok then
    failed = failed + 1
    print("✗ " .. desc .. (detail ~= nil and ("   [" .. tostring(detail) .. "]") or ""))
  end
end
local function loadlib(path, extra)
  local e = setmetatable(extra or {}, { __index = _G })
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, e)
  f()
  return e
end

local RU = loadlib("ruins.lua")
local KIT = loadlib("parts_kit.lua")
local PB = loadlib("parts_base.lua", { findScript = function(k) return k == "parts_kit" and KIT or nil end })
local function def(id) return PB.partInfo(id) end

-- ── sites ───────────────────────────────────────────────────────────────────
do
  check("air over 0.15 is an inhabited world", RU.worldClass("A", { atmo = 0.4, seed = 3 }) == "inhabited")
  check("the home world is inhabited, air or not", RU.worldClass("H", { atmo = 0, seed = 3 }, true) == "inhabited")
  check("a lava world never had a warm past", RU.worldClass("L", { atmo = 0, seed = 3, geo = { family = "lava" } }) == "none")
  local past, n = 0, 400
  for i = 1, n do
    if RU.worldClass("W" .. i, { atmo = 0, seed = i * 7919, geo = { family = "barren" } }) == "past" then past = past + 1 end
  end
  check("about a fifth of the barren worlds were once habitable", past > n * 0.13 and past < n * 0.28, past)
  local counts = { inhabited = {}, past = {}, none = {} }
  local pend_ok, none_one = true, 0
  for i = 1, 300 do
    for _, c in ipairs({ { "inhabited", { atmo = 0.5, seed = i, radius = 900 } }, { "none", { atmo = 0, seed = i, radius = 300, geo = { family = "lava" } } } }) do
      local list = RU.sitesFor("B" .. i, c[2], false, c[2].radius)
      local real, pend = 0, 0
      for _, s in ipairs(list) do if s.pending then pend = pend + 1 else real = real + 1 end end
      counts[c[1]][real] = (counts[c[1]][real] or 0) + 1
      if c[1] == "inhabited" and pend ~= 1 then pend_ok = false end
      if c[1] == "none" and pend ~= 0 then pend_ok = false end
      if c[1] == "none" and real == 1 then none_one = none_one + 1 end
    end
  end
  check("an inhabited world has 1–3 sites", (counts.inhabited[0] or 0) == 0 and (counts.inhabited[4] or 0) == 0
    and (counts.inhabited[1] or 0) > 0 and (counts.inhabited[3] or 0) > 0)
  check("one pending site an inhabited world, none elsewhere", pend_ok)
  check("a world that never had life: a tenth have one camp", none_one > 12 and none_one < 55, none_one)
  -- once-habitable: 1–2
  local pc = {}
  for i = 1, 2000 do
    local w = { atmo = 0, seed = i * 31, radius = 400, geo = { family = "frost" } }
    if RU.worldClass("P" .. i, w) == "past" then
      local n2 = #RU.sitesFor("P" .. i, w, false, 400)
      pc[n2] = (pc[n2] or 0) + 1
    end
  end
  check("a once-habitable world has 1–2 sites", (pc[1] or 0) > 0 and (pc[2] or 0) > 0 and (pc[0] or 0) == 0 and (pc[3] or 0) == 0)
  -- deterministic, apart, named
  local w = { atmo = 0.6, seed = 4242, radius = 900 }
  local a, b = RU.sitesFor("Draethos", w, true, 900), RU.sitesFor("Draethos", w, true, 900)
  local same = #a == #b
  for i = 1, #a do
    local x, y = a[i], b[i]
    same = same and x.id == y.id and x.kind == y.kind and x.ux == y.ux and x.seed == y.seed and x.name == y.name and x.age == y.age
  end
  check("the same world rolls the same sites (a reload adds nothing)", same and #a >= 2)
  local apart = true
  for i = 1, #a do for j = i + 1, #a do
    if a[i].ux * a[j].ux + a[i].uy * a[j].uy + a[i].uz * a[j].uz > math.cos(300 / 900) + 1e-9 then apart = false end
  end end
  check("sites stand 300 m apart along the ground", apart)
  check("a site has a company's name and a number", a[1].name:match("^%a+ [%a ]+ %d$") ~= nil, a[1].name)
  check("ages: an inhabited world's 400–2,500 days", a[1].age >= 400 and a[1].age <= 2500, a[1].age)
  check("occupant() is nil (no planet life yet)", RU.occupant(a[1]) == nil and a[1].life == nil)
end

-- ── builds ──────────────────────────────────────────────────────────────────
do
  for _, k in ipairs(RU.kinds()) do
    local s = { kind = k, co = 1, seed = 99, age = 1000, id = "X#1", body = "X", name = "Test" }
    local P = RU.blueprintOf(s)
    local bad, towers, cores, loot, depok = {}, 0, 0, 0, true
    for i, p in ipairs(P) do
      if not def(p.id) then bad[#bad + 1] = p.id end
      if p.rl == "tower" then towers = towers + 1 end
      if p.rl == "core" then cores = cores + 1 end
      if p.rl == "loot" then loot = loot + 1 end
      if p.dep and not (p.dep < i) then depok = false end
    end
    check(k .. ": every piece is a real part", #bad == 0, table.concat(bad, ", "))
    check(k .. ": one tower, one terminal, crates", towers == 1 and cores == 1 and loot >= 1, string.format("%d/%d/%d", towers, cores, loot))
    check(k .. ": a piece hangs only on one placed before it", depok)
    check(k .. ": 20–150 pieces (the S11 budget)", #P >= 20 and #P <= 150, #P)
    -- (Ty 11-10: "abandoned bases have too tight of doorways and things blocking them") every
    -- doorway's opening, a metre out on both sides, is clear of the loose things and fittings
    -- standing on its storey (its own steps, ladders and rails aside)
    local OPEN = { doorWall = { -0.92, 0 }, doorWallM = { 0, 0.92 }, airlockWall = { -0.92, 0 }, bulkhead = { -0.92, 0 },
                   doubleDoor = { -0.9, 0.9 }, openFrame = { -0.86, 0.86 } }
    local PATH = { steps = true, ladder = true, stairs = true, rail = true, ramp = true }
    local blocked = {}
    for _, dp in ipairs(P) do
      local o = OPEN[dp.id:match("^[^.]+")]
      if o then
        local c, s = math.cos(dp.yaw or 0), math.sin(dp.yaw or 0)
        for _, q in ipairs(P) do
          local d = def(q.id)
          local name = q.id:match("^[^.]+")
          if d and d.box and not q.dep and not PATH[name] and (q.rl == "prop" or q.rl == "loot" or q.rl == "fix" or q.rl == "core" or q.rl == "store"
              or q.rl == "silo" or q.rl == "power" or q.rl == "array") and math.abs((q.y or 0) - dp.y) < 0.6 then
            local b = d.box
            local qc, qs = math.cos(q.yaw or 0), math.sin(q.yaw or 0)
            local lo, hi = { 1e9, 1e9 }, { -1e9, -1e9 }
            for _, cx in ipairs({ b[1], b[2] }) do for _, cz in ipairs({ b[5], b[6] }) do
              -- the corner in the site's frame (local +x → (cos, -sin), +z → (sin, cos)), then the door's
              local wx, wz = q.x + cx * qc + cz * qs - dp.x, q.z - cx * qs + cz * qc - dp.z
              local lx, lz = wx * c - wz * s, wx * s + wz * c
              lo[1], hi[1] = math.min(lo[1], lx), math.max(hi[1], lx)
              lo[2], hi[2] = math.min(lo[2], lz), math.max(hi[2], lz)
            end end
            if hi[1] > o[1] + 0.03 and lo[1] < o[2] - 0.03 and hi[2] > -1.0 and lo[2] < 1.0 then
              blocked[#blocked + 1] = q.id .. " at " .. dp.id
            end
          end
        end
      end
      -- steps: their top tread is the slab's top (0.2 m), not a step up into a doorway
      if dp.id:match("^steps") then
        local top = dp.y + def(dp.id).h
        if math.abs(top - 0.2) > 0.01 then blocked[#blocked + 1] = string.format("steps top %.2f m, the sill 0.20", top) end
      end
    end
    check(k .. ": every doorway clear a metre each side, steps flush with the sill", #blocked == 0, table.concat(blocked, "; "))
  end
end

-- ── decay ───────────────────────────────────────────────────────────────────
do
  local KEEP = { slab = true, floor = true, door = true, tower = true, core = true, loot = true, silo = true }
  local kept_ok, dep_ok, det_ok = true, true, true
  local roofF, wallF, nR, nW = 0, 0, 0, 0
  local young, old = 0, 0
  for seed = 1, 60 do
    for _, k in ipairs(RU.kinds()) do
      for _, age in ipairs({ 400, 6000 }) do
        local s = { kind = k, co = seed % 10 + 1, seed = seed * 101, age = age }
        local full = RU.blueprintOf(s)
        local kept, st = RU.decay(full, s)
        local kept2 = RU.decay(RU.blueprintOf(s), s)
        if #kept ~= #kept2 then det_ok = false end
        local have = {}
        for _, e in ipairs(kept) do if e.ri > 0 then have[e.ri] = true end end
        for i, p in ipairs(full) do
          if KEEP[p.rl] and not have[i] then kept_ok = false end
          if p.dep and not have[p.dep] and have[i] then dep_ok = false end
        end
        if st.roofs > 0 then roofF = roofF + st.roofsGone / st.roofs; nR = nR + 1 end
        if st.walls > 0 then wallF = wallF + st.wallsGone / st.walls; nW = nW + 1 end
        if st.roofs > 0 then if age == 400 then young = young + st.roofsGone / st.roofs else old = old + st.roofsGone / st.roofs end end
      end
    end
  end
  roofF, wallF = roofF / nR, wallF / nW
  check("decay never takes a slab, a floor, a door, the tower, the terminal, a crate or the silo", kept_ok)
  check("what hangs on a lost piece goes with it", dep_ok)
  check("decay is the same every time for a site", det_ok)
  check("roofs go first: 30–60 % of them", roofF >= 0.30 and roofF <= 0.60, roofF)
  check("…then 10–30 % of the walls", wallF >= 0.08 and wallF <= 0.32, wallF)
  check("roofs first: more of the roof goes than of the walls", roofF > wallF + 0.1)
  check("an old ruin has lost more of its roof than a young one", old > young, string.format("%.2f vs %.2f", old, young))
end

-- ── the record, structures.lua's store ──────────────────────────────────────
local store = {}
local SAVE = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end, delete = function(k) store[k] = nil end }
do
  local ST = loadlib("structures.lua", { save = SAVE })
  local s = { kind = "relay", co = 2, seed = 777, age = 2000, id = "Golver#1", body = "Golver", name = "Halden Relay Post 4" }
  local kept = RU.decay(RU.blueprintOf(s), s)
  local g = { x = 0, y = 600, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1 }
  local rec = RU.recordOf(s, g, kept, 1e6)
  check("the record is a ruin's (ru, by ruin)", rec.ru == "Golver#1" and rec.by == "ruin")
  check("back-dated by its age: instant dust", math.abs(rec.t - (1e6 - 2000 * 86400)) < 1e-6)
  local sid = ST.add(rec)
  local r2 = ST.get(sid)
  check("structures takes it, ids in order", r2 and #r2.bp == #kept and r2.bp[1].uid == 1)
  ST.reloadFromSave()
  r2 = ST.get(sid)
  check("the store keeps `ru` across a reload", r2 and r2.ru == "Golver#1")
  local finite = true
  for _, p in ipairs(r2.bp) do
    local x, y, z, U, F = ST.partPose(r2, p, (def(p.id) or {}).seat or 0)
    for _, v in ipairs({ x, y, z, U.x, U.y, U.z, F.x, F.y, F.z }) do if v ~= v or math.abs(v) > 1e6 then finite = false end end
  end
  check("every piece poses finite on the site's frame", finite)
  local flat, lights_off = false, true
  for _, p in ipairs(r2.bp) do
    if p.id == "batteryBank" then flat = p.fill == 0 end
    if p.rl == "light" and not (r2.st[tostring(p.uid)] and r2.st[tostring(p.uid)].off) then lights_off = false end
  end
  check("a relay's battery arrives flat", flat)
  check("every light is off (dead power)", lights_off)
  local miss = RU.missing(RU.blueprintOf(s), r2.bp)
  local full = RU.blueprintOf(s)
  local stand = 0
  for _, p in ipairs(r2.bp) do if (p.ri or 0) > 0 then stand = stand + 1 end end
  check("missing() lists exactly what the decay took", #miss + stand == #full, string.format("%d + %d vs %d", #miss, stand, #full))
  -- an old record without `ru` loads as before
  store["struct.900"] = { id = 900, b = "Draethos", x = 1, y = 2, z = 3, bp = { { uid = 1, id = "wall.steel", x = 0, y = 0, z = 0 } } }
  store["struct.list"] = { sid, 900 }
  ST.reloadFromSave()
  check("an old structure record (no ru) loads unchanged", ST.get(900) and ST.get(900).ru == nil and #ST.get(900).bp == 1)
end

-- ── the core ────────────────────────────────────────────────────────────────
do
  local s = { kind = "reactor", co = 3, seed = 5, age = 3000 }
  check("a power hall's core: 300 RP", RU.coreReward(s, 1).rp == 300)
  check("…read by a ×1.5 Scientist: 450", RU.coreReward(s, 1.5).rp == 450)
  check("a camp's core: 60 RP, a mine's 120, a hab's 150", RU.coreReward({ kind = "camp", seed = 1 }).rp == 60
    and RU.coreReward({ kind = "mine", seed = 1 }).rp == 120 and RU.coreReward({ kind = "hab", seed = 1 }).rp == 150)
  local l = RU.lore(s)
  check("the log is three lines", #l == 3 and #l[1] > 10)
  check("…from at least 40 fragments", #RU.LORE_A + #RU.LORE_B + #RU.LORE_C >= 40)
  local l2 = RU.lore(s)
  check("…the same each time", l[1] == l2[1] and l[2] == l2[2] and l[3] == l2[3])
  check("a mine's core maps the resources", RU.coreReward({ kind = "mine", seed = 1 }).layer.res == 0.6)
end

-- ── the scene half, over stubs ──────────────────────────────────────────────
do
  store = {}
  local R = 900
  local function V(x, y, z) return { x = x, y = y, z = z } end
  local body = { name = "Draethos", x = 1000, y = -500, z = 300, radius = R }
  local space = { body = function(n) return n == "Draethos" and body or nil end, dominant = function() return "Draethos" end }
  -- a smooth sphere of radius R: the field's raycast meets it exactly
  local terrain = { raycast = function(o, d, max)
    local ox, oy, oz = o.x - body.x, o.y - body.y, o.z - body.z
    local b = ox * d.x + oy * d.y + oz * d.z
    local c = ox * ox + oy * oy + oz * oz - R * R
    local disc = b * b - c
    if disc < 0 then return nil, "air" end
    local t = -b - math.sqrt(disc)
    return { pos = V(o.x + d.x * t, o.y + d.y * t, o.z + d.z * t), distance = t, exact = true }
  end }
  local astro = V(0, 0, 0)
  local inv_store = {}
  local INV
  INV = {
    addItem = function(c, id, n) inv_store[c] = inv_store[c] or { items = {}, mats = {} }; inv_store[c].items[id] = (inv_store[c].items[id] or 0) + n; return n end,
    removeItem = function(c, id, n) local b = inv_store[c]; if not b or (b.items[id] or 0) < n then return 0 end b.items[id] = b.items[id] - n; return n end,
    itemCount = function(c, id) local b = inv_store[c]; return b and b.items[id] or 0 end,
    add = function(c, m, n) inv_store[c] = inv_store[c] or { items = {}, mats = {} }; inv_store[c].mats[m] = (inv_store[c].mats[m] or 0) + n; return n end,
    moveAllItems = function(f, t) local b = inv_store[f]; local n = 0; if b then for id, k in pairs(b.items) do if k > 0 then n = n + k; INV.addItem(t, id, k); b.items[id] = 0 end end end return n end,
    transferAll = function(f, t) local b = inv_store[f]; local n = 0; if b then for m, k in pairs(b.mats) do if k > 0 then n = n + k; INV.add(t, m, k); b.mats[m] = 0 end end end return n end,
    isEmpty = function(c) local b = inv_store[c]; if not b then return true end for _, k in pairs(b.mats) do if k > 0 then return false end end return true end,
    itemList = function(c) local b, out = inv_store[c], {}; if b then for id, k in pairs(b.items) do if k > 0 then out[#out + 1] = { id = id, n = k } end end end return out end,
  }
  local SCRIPTS = {}
  local env = { save = SAVE, space = space, terrain = terrain, vec3 = V, time = 0,
                find = function(n) return n == "Astronaut" and astro or nil end,
                findScript = function(k) return SCRIPTS[k] end, log = function() end }
  local ST = loadlib("structures.lua", { save = SAVE })
  local B = loadlib("bases.lua", { save = SAVE })
  local co = { spent = 0 }
  co.spend = function(n) co.spent = co.spent + n; return true end
  local SV = { mask = {}, n = 0 }
  SV.swathCells = function() return RU.swathCellsStub end
  local research = 0
  SCRIPTS = { structures = ST, bases = B, inventory = INV, parts_base = PB, company = co,
              deployables = { agencyClock = function() return 5e6 end },
              survey = { SWATH_N = 400, swathOf = function() return SV end, swathCells = nil, creditNow = function() end },
              climate = { worldOf = function(n) return { atmo = 0.6, seed = 4242, radius = R, relief = 40, sea = 0 } end },
              materials = { bodyOres = function() return { { mat = "iron", w = 3 }, { mat = "copper", w = 1 } } end },
              blueprints = { saved = {}, saveBp = function(bp) SCRIPTS.blueprints.saved[#SCRIPTS.blueprints.saved + 1] = bp; return "slug" end } }
  store["system.home"] = { bodies = { { name = "Draethos", radius = R } } }
  store["base.body"] = "Draethos"
  local S2 = loadlib("ruins.lua", env)
  -- the survey's 400 cells (the real function)
  local SVL = loadlib("survey.lua", { save = SAVE })
  SCRIPTS.survey.swathCells = SVL.swathCells
  local list = S2.sites("Draethos")
  local s = nil
  for _, x in ipairs(list) do if not x.pending then s = x; break end end
  check("the home world has its sites in the scene", s ~= nil and #list >= 2)
  -- the crew 2 km away: nothing happens
  local function put_crew(dist)
    local e1x, e1y, e1z, e2x, e2y, e2z = S2.tangent(s.ux, s.uy, s.uz)
    local a = dist / R
    local ux, uy, uz = s.ux * math.cos(a) + e1x * math.sin(a), s.uy * math.cos(a) + e1y * math.sin(a), s.uz * math.cos(a) + e1z * math.sin(a)
    astro.x, astro.y, astro.z = body.x + ux * (R + 1.8), body.y + uy * (R + 1.8), body.z + uz * (R + 1.8)
  end
  local function tick() env.time = env.time + 1.1; S2.update(nil, 1.1) end
  put_crew(1500)
  tick()
  check("far away: not found, not stamped", not S2.discovered(s.id) and not (S2.state(s.id).sid))
  put_crew(500)
  tick()
  local e = S2.state(s.id)
  check("within 600 m: stamped (sited on flat ground)", e.sid ~= nil and ST.get(e.sid) ~= nil, e.drop)
  check("…sited on the ground (the field's raycast)", e.g and math.abs(math.sqrt(e.g.x ^ 2 + e.g.y ^ 2 + e.g.z ^ 2) - (R - 0.15)) < 1e-6)
  check("…not found yet at 500 m", not S2.discovered(s.id))
  local r = ST.get(e.sid)
  check("the stamp is the site's (ru, its name)", r.ru == s.id and r.n == s.name)
  check("the tower is held: no base founded from an unclaimed ruin", S2.towerHeld(r) == true)
  put_crew(300)
  tick()
  check("within 420 m: found (proximity)", S2.discovered(s.id) and S2.state(s.id).dsc == "proximity")
  put_crew(1200)
  tick()
  check("far again and untouched: out of the records", S2.state(s.id).sid == nil and ST.get(e.sid) == nil)
  check("…its site keeps the ground it was sited on", S2.state(s.id).g ~= nil)
  put_crew(100)
  tick()
  e = S2.state(s.id)
  r = ST.get(e.sid)
  check("back near: stamped again, the same pieces", r ~= nil and #r.bp == e.n)
  -- a crate, then far away: kept
  local crate = nil
  for _, p in ipairs(r.bp) do if p.rl == "loot" then crate = p end end
  local got = S2.searchCrate(s.id, crate.ri, "astro")
  check("a crate searched: its things in the pack", got > 0 and (inv_store.astro.mats.iron or 0) + (inv_store.astro.mats.copper or 0) > 0, got)
  local again = S2.searchCrate(s.id, crate.ri, "astro")
  check("…and only once", again == 0 and S2.crateEmpty(s.id, crate.ri))
  put_crew(1200)
  tick()
  check("touched: kept in the records when far", S2.state(s.id).sid ~= nil and ST.get(S2.state(s.id).sid) ~= nil)
  put_crew(50)
  tick()
  -- the core
  local ok = S2.pullCore(s.id, "astro")
  check("the Data Core pulled into the pack", ok and INV.itemCount("astro", "datacore") == 1)
  check("…the terminal is empty after", not S2.pullCore(s.id, "astro"))
  store["res.pts"] = 10
  local n = S2.readCores("astro")
  check("read at the lab: RP by kind", n == 1 and store["res.pts"] == 10 + S2.RP[s.kind], store["res.pts"])
  check("…the blueprint saved to the library", #SCRIPTS.blueprints.saved == 1 and SCRIPTS.blueprints.saved[1].name:find("recovered") ~= nil)
  check("…the core is gone from the pack", INV.itemCount("astro", "datacore") == 0)
  -- claim, restore, repair
  check("an unclaimed ruin is no base", #B.list() == 0)
  local okc, why = S2.claim(s.id, nil)
  check("only an Engineer claims a site", not okc and why ~= nil)
  okc = S2.claim(s.id, nil, true)
  r = ST.get(S2.state(s.id).sid)
  check("claimed: the tower is no longer held", okc and S2.towerHeld(r) == false)
  local q = S2.restoreQuote(s.id)
  check("a restore quote: the missing pieces and their price", q.n > 0 and q.cost > 0, string.format("%d · $%d", q.n, q.cost))
  local nr = S2.restore(s.id)
  check("restore puts back every missing piece and charges once", nr == q.n and co.spent == q.cost and S2.restoreQuote(s.id).n == 0)
  local worn = nil
  for _, p in ipairs(r.bp) do if p.wr and (p.o_p or p.o_r) then worn = p; break end end
  if worn then
    local before = (worn.o_p ~= nil) and worn.o_p or worn.o_r
    check("repair straightens a knocked piece", S2.repairPiece(r.id, worn.uid) and (ST.getPart(r.id, worn.uid).pitch == before or ST.getPart(r.id, worn.uid).roll == before)
      and ST.getPart(r.id, worn.uid).wr == nil)
  else
    check("a ruin has a knocked piece to repair", false)
  end
  -- scanner and telescope on the other sites
  local s2, s3 = nil, nil
  for _, x in ipairs(list) do if not x.pending and x.id ~= s.id then if not s2 then s2 = x elseif not s3 then s3 = x end end end
  if s2 then
    local cells = SVL.swathCells(400)
    SV.mask[RU.cellOf(cells, s2.ux, s2.uy, s2.uz)] = true
    SV.n = 1
    env.time = env.time + 6
    S2.update(nil, 6)
    check("an orbital scanner's swath over its cell finds a site", S2.discovered(s2.id) and S2.state(s2.id).dsc == "scanner")
  end
  local pend = nil
  for _, x in ipairs(list) do if x.pending then pend = x end end
  local nt = S2.telescopeSwept("Draethos", "tel100")
  check("a 1 m telescope finds every site still hidden", s3 == nil or S2.discovered(s3.id), nt)
  check("…never the pending one (kept for the life system)", pend and not S2.discovered(pend.id))
  -- fleet_view: the ruin entry
  local FV = loadlib("fleet_view.lua", { save = SAVE, space = space, findScript = function(k) if k == "ruins" then return S2 end return SCRIPTS[k] end })
  check("fleet_view: a ruin is a STRUCTURES entry with ▣", FV.groupOf({ kind = "ruin" }) == "STRUCTURES" and FV.GLYPHS.ruin == "▣")
  check("…its line says abandoned, its kind and age", FV.situation({ kind = "ruin", ruinKind = "survey camp", age = 2100 }) == "abandoned · survey camp · 2100 days")
  check("…it is infrastructure (the kind key)", FV.kindClass({ kind = "ruin" }) == "infra")
  -- an old save: no ruins.s at all
  store["ruins.s"] = nil
  local S3 = loadlib("ruins.lua", env)
  check("an old save without ruins.s: nothing found, nothing claimed", not S3.discovered(s.id) and not S3.claimed(s.id))
end

if failed == 0 then
  print(string.format("RUINS SMOKE OK — %d checks passed", count))
  os.exit(0)
end
print(string.format("RUINS SMOKE: %d of %d checks failed", failed, count))
os.exit(1)
