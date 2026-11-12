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
--   * (worlds W5) cave ruins: half the camps on a world with caves camp in a
--     sink; a mine head with a cave under it gets a shaft (flights, landings,
--     a cache at the foot), dug once and stamped again; the sink camp's hut on
--     the chamber's floor; a shaft's crate looted; the core names the ore;
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
  -- (Ty 11-12) the context menu's actor on foot is id "astro": the member
  -- you are is asked, so an Engineer is one
  do
    local roles = { [3] = "engineer", [4] = "pilot" }
    local act = 4
    SCRIPTS.crew = { activeId = function() return act end, role = function(id) return roles[id] end }
    local okp = S2.claim(s.id, { actor = { kind = "crew", id = "astro", pack = "astro" } })
    check("a Pilot on foot (actor astro) may not claim", not okp)
    act = 3
    local oke, whye = S2.claim(s.id, { actor = { kind = "crew", id = "astro", pack = "astro" } })
    check("an Engineer on foot (actor astro) claims the site", oke, tostring(whye))
    SCRIPTS.crew = nil
    okc = oke
  end
  if not okc then okc = S2.claim(s.id, nil, true) end
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

-- ── CAVE RUINS (worlds W5): the mine shaft and the sinkhole camp ───────────
do
  -- pure: which camps camp in a sink
  local sinks, n = 0, 600
  for i = 1, n do
    local s = { kind = "camp", seed = i * 7717 + 3, id = "S#" .. i }
    if RU.caveKindOf(s, { caves = true }) == "sinkcamp" then sinks = sinks + 1 end
  end
  check("about half the survey camps on a world with caves camp in a sink", sinks > n * 0.4 and sinks < n * 0.6, sinks)
  local s0 = { kind = "camp", seed = 5, id = "S#0" }
  local a1, a2 = RU.caveKindOf(s0, { caves = true }), RU.caveKindOf(s0, { caves = true })
  check("…the same every time (the seed)", a1 == a2)
  check("…never a camp already stamped as a camp, nor one on a world without caves, nor a mine",
    RU.caveKindOf(s0, { caves = true, keep = true }) == nil and RU.caveKindOf(s0, { caves = false }) == nil
    and RU.caveKindOf({ kind = "mine", seed = 5 }, { caves = true }) == nil)
  -- flights: from the floor to the collar, a landing at each turn
  local P, lost = RU.flightPieces(0, 0, -20, 0, nil, 0)
  local flights, landings, good = 0, 0, true
  for _, p in ipairs(P) do
    if p.id == "ladder.steel" then flights = flights + 1 end
    if p.id == "floor.steel" then landings = landings + 1 end
    if not def(p.id) then good = false end
  end
  check("a 20 m shaft: 9 flights of a ship's ladder, 8 landings", flights == 9 and landings == 8 and lost == 0, flights .. "/" .. landings)
  check("…every piece real", good)
  local top = -1e9
  for _, p in ipairs(P) do if p.id == "ladder.steel" then top = math.max(top, p.y + RU.FLIGHT_H) end end
  check("…the last flight tops out at the collar or over it", top >= 0 and top < RU.FLIGHT_H)
  local same_end = true
  for k = 1, #P do
    local p = P[k]
    if p.id == "ladder.steel" and P[k + 2] and P[k + 2].id == "ladder.steel" then
      -- (this flight tops out where the next one starts: the same z end, one tread up)
      local tz = p.z + ((p.yaw == 0) and -1.1 or 1.1)
      local q = P[k + 2]
      local bz = q.z + ((q.yaw == 0) and 1.1 or -1.1)
      if math.abs(tz - bz) > 1e-9 or math.abs(q.y - (p.y + RU.FLIGHT_H)) > 1e-9 then same_end = false end
    end
  end
  check("…each flight starts where the last tops out (a switchback)", same_end)
  local r = RU.rng(9)
  local P2, lost2 = RU.flightPieces(0, 0, -40, 0, r, 0.9)
  local first, last_ = false, false
  for _, p in ipairs(P2) do
    if p.id == "ladder.steel" and p.y == -40 then first = true end
    if p.id == "ladder.steel" and p.y + RU.FLIGHT_H >= 0 then last_ = true end
  end
  check("an old shaft has lost flights, never its first or its last", lost2 > 0 and first and last_, lost2)
  -- the shaft's cache
  local site = { kind = "mine", seed = 31, age = 3000, co = 2, id = "M#1", body = "X", name = "Varro Mine Head 3" }
  local sh = { x = 20, z = -4, d = 34, s0 = -0.6 }
  local SP = RU.shaftPieces(site, sh)
  local loot_, store_, real, deep = 0, 0, true, true
  for _, p in ipairs(SP) do
    if p.rl == "loot" then loot_ = loot_ + 1 end
    if p.rl == "store" then store_ = store_ + 1 end
    if not def(p.id) then real = false end
    if p.y > 0.01 then deep = false end
  end
  check("a mine shaft: crates and a store cabinet at its foot, every piece real", loot_ >= 2 and store_ >= 1 and real)
  check("…nothing above the collar", deep)
  local kept = RU.caveKept(site, { sh = sh }, RU.decay(RU.blueprintOf(site), site))
  local cave_ri, min_ri = 0, 1e9
  for _, p in ipairs(kept) do if (p.ri or 0) > RU.CAVE_RI then cave_ri = cave_ri + 1; min_ri = math.min(min_ri, p.ri) end end
  check("the stamp carries the shaft's pieces, indexed past " .. RU.CAVE_RI .. " (the loot's keys)", cave_ri == #SP and min_ri == RU.CAVE_RI + 1)
  local kept0 = RU.caveKept(site, {}, RU.decay(RU.blueprintOf(site), site))
  check("…and none before the cave is found", #kept0 == #RU.decay(RU.blueprintOf(site), site))
  local line = RU.shaftLine(site, sh, "galena")
  check("a shaft's core names the ore they sank it for", line:find("galena", 1, true) and line:find("34", 1, true))
  site.caveLine = line
  check("…the log carries that line", RU.lore(site)[2] == line)
  site.caveLine = nil
  -- the sink camp
  local sc = { kind = "sinkcamp", seed = 44, age = 1500, co = 1, id = "C#1", body = "X", name = "Pell Sink Camp 2" }
  local BP = RU.blueprintOf(sc)
  local held = RU.caveKept(sc, {}, RU.decay(BP, sc))
  local core_held = false
  for _, p in ipairs(held) do if p.rl == "core" then core_held = true end end
  check("a sink camp before its floor is known: only the rim stands (no core yet)", not core_held)
  local k2 = RU.caveKept(sc, { sh = { x = 0, z = 0, d = 22, s0 = 0, nat = true } }, RU.decay(BP, sc))
  local core_y, tower_y, fl = nil, nil, 0
  for _, p in ipairs(k2) do
    if p.rl == "core" then core_y = p.y end
    if p.rl == "tower" then tower_y = p.y end
    if p.id == "ladder.steel" then fl = fl + 1 end
  end
  check("…on a 22 m floor: the terminal down there, the tower on the rim, flights down the side",
    core_y and math.abs(core_y - (-22 + 0.2 + 0.74)) < 1e-9 and tower_y == 0 and fl >= 7, string.format("%s %s %d", tostring(core_y), tostring(tower_y), fl))

  -- the scene: a world with a cave 20–26 m under all its ground
  store = {}
  local R = 900
  local function V(x, y, z) return { x = x, y = y, z = z } end
  local body = { name = "Draethos", x = 1000, y = -500, z = 300, radius = R }
  local space = { body = function(nm) return nm == "Draethos" and body or nil end, dominant = function() return "Draethos" end }
  local function sdf(x, y, z)
    local r = math.sqrt((x - body.x) ^ 2 + (y - body.y) ^ 2 + (z - body.z) ^ 2)
    local v
    if r >= R then v = r - R
    elseif r <= R - 20 and r >= R - 26 then v = math.min(r - (R - 26), (R - 20) - r)
    else v = -math.min(math.abs(r - R), math.abs(r - (R - 20)), math.abs(r - (R - 26))) end
    return math.max(-6, math.min(6, v))
  end
  local digs, flats = 0, 0
  local terrain = {
    query = sdf,
    ready = function() return true end,
    raycast = function(o, d, max)
      local t, prev = 0, sdf(o.x, o.y, o.z)
      while t < (max or 100) do
        t = t + 0.05
        local v = sdf(o.x + d.x * t, o.y + d.y * t, o.z + d.z * t)
        if prev > 0 and v <= 0 then return { pos = V(o.x + d.x * t, o.y + d.y * t, o.z + d.z * t), distance = t, exact = true } end
        prev = v
      end
      return nil, "air"
    end,
    dig = function() digs = digs + 1; return digs end,
    sculpt = function() flats = flats + 1; return flats end,
  }
  local astro = V(0, 0, 0)
  local SCRIPTS = {}
  local env = { save = SAVE, space = space, terrain = terrain, vec3 = V, time = 0,
                find = function(nm) return nm == "Astronaut" and astro or nil end,
                findScript = function(k) return SCRIPTS[k] end, log = function() end }
  local ST = loadlib("structures.lua", { save = SAVE })
  local inv_store = {}
  local INV = {
    addItem = function(c, id, k) inv_store[c] = inv_store[c] or { items = {}, mats = {} }; inv_store[c].items[id] = (inv_store[c].items[id] or 0) + k; return k end,
    itemCount = function(c, id) local b = inv_store[c]; return b and b.items[id] or 0 end,
    add = function(c, m, k) inv_store[c] = inv_store[c] or { items = {}, mats = {} }; inv_store[c].mats[m] = (inv_store[c].mats[m] or 0) + k; return k end,
    itemList = function() return {} end, isEmpty = function() return true end,
  }
  INV.moveAllItems = function(f, t) local b = inv_store[f]; local k = 0; if b then for id, v in pairs(b.items) do if v > 0 then k = k + v; INV.addItem(t, id, v); b.items[id] = 0 end end end return k end
  INV.transferAll = function(f, t) local b = inv_store[f]; local k = 0; if b then for m, v in pairs(b.mats) do if v > 0 then k = k + v; INV.add(t, m, v); b.mats[m] = 0 end end end return k end
  SCRIPTS = { structures = ST, bases = loadlib("bases.lua", { save = SAVE }), inventory = INV, parts_base = PB,
              deployables = { agencyClock = function() return 5e6 end },
              survey = { SWATH_N = 400, swathOf = function() return { mask = {}, n = 0 } end, creditNow = function() end },
              climate = { worldOf = function() return { atmo = 0.6, seed = 4242, radius = R, relief = 40, sea = 0 } end },
              materials = { bodyOres = function() return { { mat = "galena", w = 3 }, { mat = "iron", w = 1 } } end } }
  store["system.home"] = { bodies = { { name = "Draethos", radius = R } } }
  store["base.body"] = "Draethos"
  local S4 = loadlib("ruins.lua", env)
  local list = S4.sites("Draethos")
  local sm, ss = nil, nil
  for _, x in ipairs(list) do if not x.pending then if not sm then sm = x elseif not ss then ss = x end end end
  check("the scene world has two sites for the cave ruins", sm ~= nil and ss ~= nil)
  S4.forceCaveKind(sm.id, "mine")
  S4.forceCaveKind(ss.id, "sinkcamp")
  check("a probe can make a site a mine head or a sink camp", S4.site(sm.id).kind == "mine" and S4.site(ss.id).kind == "sinkcamp"
    and S4.site(ss.id).name:find("Sink Camp", 1, true))
  local function put_crew(s, dist)
    local e1x, e1y, e1z = S4.tangent(s.ux, s.uy, s.uz)
    local a = dist / R
    local ux, uy, uz = s.ux * math.cos(a) + e1x * math.sin(a), s.uy * math.cos(a) + e1y * math.sin(a), s.uz * math.cos(a) + e1z * math.sin(a)
    astro.x, astro.y, astro.z = body.x + ux * (R + 1.8), body.y + uy * (R + 1.8), body.z + uz * (R + 1.8)
  end
  local function tick() env.time = env.time + 1.1; S4.update(nil, 1.1) end
  -- the mine: stamped at 500 m without a shaft; at 150 m the cave is found and dug
  put_crew(sm, 500)
  tick()
  local e = S4.state(sm.id)
  local n_before = e.n
  check("the mine stamped far off, no shaft yet", e.sid ~= nil and e.sh == nil)
  put_crew(sm, 150)
  tick()
  e = S4.state(sm.id)
  check("near: the cave under the head is found (a chamber 20–26 m down)", type(e.sh) == "table" and e.sh.nat and math.abs(e.sh.d - 26) < 0.3,
    e.sh and e.sh.d)
  check("…the shaft is dug, once", digs >= 10 and flats >= 2 and e.sh.dug ~= nil, digs .. " digs, " .. flats .. " flattens")
  local r = ST.get(e.sid)
  local cave_loot, foot = nil, nil
  for _, p in ipairs(r.bp) do
    if (p.ri or 0) > S4.CAVE_RI and p.rl == "loot" then cave_loot = p end
    if p.id == "ladder.steel" and p.y < -20 then foot = p end
  end
  check("…stamped again with its flights and its cache", e.n > n_before and cave_loot ~= nil and foot ~= nil, e.n .. " vs " .. tostring(n_before))
  local dg = digs
  put_crew(sm, 120)
  tick()
  check("…and never dug twice", digs == dg)
  local got = S4.searchCrate(sm.id, cave_loot.ri, "astro")
  check("a crate at the shaft's foot is looted", got > 0, got)
  check("the shaft's core names the world's ore", S4.site(sm.id).caveLine and S4.site(sm.id).caveLine:find("galena", 1, true))
  -- the sink camp: no chamber here at its middle? (there is: the shell) — the camp on its floor
  put_crew(ss, 150)
  tick()
  tick()
  local es = S4.state(ss.id)
  check("the sink camp: its chamber found, the sink dug into it", type(es.sh) == "table" and es.sh.nat and es.sh.dug ~= nil)
  local rs = ST.get(es.sid)
  local core = nil
  for _, p in ipairs(rs and rs.bp or {}) do if p.rl == "core" then core = p end end
  check("…its terminal on the chamber's floor", core ~= nil and math.abs(core.y - (-es.sh.d + 0.2 + 0.74)) < 1e-6, core and core.y)
  -- a reload: the kinds and the shaft's line come back from the save
  local S5 = loadlib("ruins.lua", env)
  check("a reload keeps the cave ruins' kinds and the shaft's line", S5.site(sm.id).kind == "mine" and S5.site(ss.id).kind == "sinkcamp"
    and S5.site(sm.id).caveLine ~= nil)
end

-- ── (progression R1) THE RUIN NEAR HOME ──────────────────────────────────────
-- the site: camp or relay, young, its own name, the next site named; the
-- ring placement on 50 worlds (330–400 m, flattest of 16 bearings), never
-- dropped on steep ground (relaxed, then further out, then the flattest),
-- never on the player's structures, bases or the Tracking Station; the yard
-- (two arrays, one knocked, a flat bank), the locked locker, no locked door;
-- the log; the crate (shift note, crated Solar Panel, Repair Kit); and the
-- scene: sited near the pad, stamped, found only up close, Ops's one line
-- after First Steps, an old save's site near home pointed at instead.
do
  -- the site
  local kinds, ages_ok, names_ok = {}, true, true
  for i = 1, 300 do
    local others = RU.sitesFor("N" .. i, { atmo = 0.5, seed = i * 31, radius = 800 }, true, 800)
    local s = RU.nearSite("N" .. i, { seed = i * 31 }, others)
    kinds[s.kind] = (kinds[s.kind] or 0) + 1
    if s.age < 400 or s.age > 900 then ages_ok = false end
    for _, o in ipairs(others) do if o.name == s.name then names_ok = false end end
    if i == 1 then
      local first = nil
      for _, o in ipairs(others) do if not o.pending then first = o break end end
      check("the near site names the world's first real site", s.other == first.id and s.otherName == first.name and s.near == true)
      check("…its id is <home>#near", s.id == "N1#near")
    end
  end
  check("the near site is a survey camp or a relay post, never anything else", (kinds.camp or 0) + (kinds.relay or 0) == 300, (kinds.camp or 0) .. "/" .. (kinds.relay or 0))
  check("…camps about 3 in 5", (kinds.camp or 0) > 150 and (kinds.camp or 0) < 210, kinds.camp)
  check("…empty 400–900 days (younger than the others)", ages_ok)
  check("…its name is never another site's", names_ok)

  -- the plan
  local P = RU.nearPlan(7)
  local ph1, ring_ok = 0, true
  for _, p in ipairs(P) do
    if p.ph == 1 then ph1 = ph1 + 1; if p.d ~= RU.NEAR_MID then ring_ok = false end end
    if p.ph == 2 and (p.d < RU.NEAR_RING[1] or p.d > RU.NEAR_RING[2]) then ring_ok = false end
    if p.ph == 3 and p.d <= RU.NEAR_RING[2] then ring_ok = false end
  end
  check("the plan: 16 bearings at the ring's middle, then 108 spots in the ring, then further out", ph1 == 16 and ring_ok and #P == 16 + 108 + 36 * #RU.NEAR_FAR)

  -- the placement over a fixture world: spread(ux,uy,uz) and wet(ux,uy,uz) from the test
  local function unitv(x, y, z) local l = math.sqrt(x * x + y * y + z * z); return x / l, y / l, z / l end
  local function place(seed, R, spread, wet, wv, budget)
    local r = RU.rng(seed)
    local fx, fy, fz = unitv(r() - 0.5, r() - 0.5, r() - 0.5)
    local fp = { x = fx * R, y = fy * R, z = fz * R }
    wv = wv or {}
    wv.R, wv.fp = R, fp
    local st = { seed = seed, clear = function(gx, gy, gz) return RU.nearClear(wv, gx, gy, gz) end }
    local probe = function(p)
      local ux, uy, uz = RU.ringDir(fx, fy, fz, p.b, p.d, R)
      return { spread = spread(ux, uy, uz, p), dry = not wet(ux, uy, uz, p), gx = ux * R, gy = uy * R, gz = uz * R, ux = ux, uy = uy, uz = uz }
    end
    local k, why
    for _ = 1, 200 do
      k, why = RU.nearStep(st, probe, budget or 1e9)
      if why ~= "more" then break end
    end
    local d = k and RU.groundDist(R, fp.x, fp.y, fp.z, st.res[k].gx, st.res[k].gy, st.res[k].gz) or nil
    return k, why, d, st, fp
  end
  local function noise(ux, uy, uz, k) return 0.5 + 0.5 * math.sin(ux * k * 13.1 + uy * k * 7.3 + uz * k * 5.7) end
  local in_ring, flat_pick, n = 0, 0, 50
  for i = 1, n do
    local R = 600 + (i * 37) % 350
    local k, why, d, st = place(i * 101, R, function(ux, uy, uz) return 0.3 + 1.6 * noise(ux, uy, uz, 9) end, function() return false end)
    if k and d >= RU.NEAR_RING[1] - 0.5 and d <= RU.NEAR_RING[2] + 0.5 then in_ring = in_ring + 1 end
    if k then
      -- the flattest of the 16 when one passes
      local best = math.huge
      for j = 1, 16 do local rr = st.res[j]; if rr and rr.spread <= RU.FLAT_SPREAD then best = math.min(best, rr.spread) end end
      if best == math.huge or math.abs(st.res[k].spread - best) < 1e-9 then flat_pick = flat_pick + 1 end
    end
  end
  check("50 worlds: the near site always in the 330–400 m ring", in_ring == n, in_ring)
  check("…on the flattest of the 16 bearings when one is flat enough", flat_pick == n, flat_pick)
  -- steep in the ring (2.4 m over 11 m everywhere): relaxed, still in the ring
  local k, why, d, st = place(5, 800, function() return 2.4 end, function() return false end)
  check("steep ring: relaxed to 3 m, still in the ring", k and d >= 329 and d <= 401 and st.res[k].spread == 2.4, why)
  -- the whole ring a cliff, flat further out: further out
  k, why, d = place(6, 800, function(_, _, _, p) return p.d <= 400 and 9 or 0.5 end, function() return false end)
  check("a cliff ring: sited further out, never dropped", k and d > 400 and d <= 820, why)
  -- steep everywhere (a pad on a mountain): the flattest of all, never dropped
  k, why, d, st = place(7, 800, function(ux, uy, uz) return 6 + noise(ux, uy, uz, 5) * 4 end, function() return false end)
  local minall = math.huge
  for j = 1, 124 do local rr = st.res[j]; if rr then minall = math.min(minall, rr.spread) end end
  check("steep everywhere: the flattest spot in the ring, never dropped", k and d >= 329 and d <= 401 and st.res[k].spread == minall, why)
  -- the ring all under water, an island further out: there
  k, why, d = place(8, 800, function() return 0.4 end, function(_, _, _, p) return p.d < 600 end)
  check("a pad on a small island: sited on the first dry ring", k and d >= 599 and d <= 601, why)
  -- all sea: the one honest failure (tries again next session)
  k, why = place(9, 800, function() return 0.4 end, function() return true end)
  check("all sea round the pad: no room (the scene tries again next session)", k == nil and why == "no room")
  -- the player's structures and bases in the ring: clear of all of them
  do
    local R = 800
    local r = RU.rng(11)
    local fx, fy, fz = unitv(r() - 0.5, r() - 0.5, r() - 0.5)
    local wv = { structs = {}, bases = {} }
    -- a structure every 20° on the ring's middle, a base and the station on two more bearings
    for a = 0, 17 do
      local ux, uy, uz = RU.ringDir(fx, fy, fz, a * math.pi / 9, 365, R)
      wv.structs[#wv.structs + 1] = { x = ux * R, y = uy * R, z = uz * R }
    end
    local bx, by, bz = RU.ringDir(fx, fy, fz, 1.0, 380, R)
    wv.bases[1] = { x = bx * R, y = by * R, z = bz * R }
    local sx, sy, sz = RU.ringDir(fx, fy, fz, 2.0, 60, R)
    wv.station = { x = sx * R, y = sy * R, z = sz * R }
    -- (re-seed the same footprint in place())
    local k2, why2, d2, st2, fp = place(11, R, function() return 0.5 end, function() return false end, wv)
    local g = k2 and st2.res[k2]
    local okc = g ~= nil
    if g then
      for _, p in ipairs(wv.structs) do if RU.groundDist(R, g.gx, g.gy, g.gz, p.x, p.y, p.z) < RU.BUILT_MIN then okc = false end end
      for _, p in ipairs(wv.bases) do if RU.groundDist(R, g.gx, g.gy, g.gz, p.x, p.y, p.z) < RU.BASE_MIN then okc = false end end
      if RU.groundDist(R, g.gx, g.gy, g.gz, wv.station.x, wv.station.y, wv.station.z) < RU.BASE_MIN then okc = false end
    end
    check("never on the player's structures, bases or the Tracking Station", okc, why2)
    check("…the structures pushed it out of the ring, it was not dropped", k2 ~= nil and d2 > 0, d2)
  end
  -- the budget: 24 spots a tick, the same answer as all at once
  local ka = place(12, 800, function(ux, uy, uz) return 1.2 + 1.5 * noise(ux, uy, uz, 11) end, function() return false end)
  local kb = place(12, 800, function(ux, uy, uz) return 1.2 + 1.5 * noise(ux, uy, uz, 11) end, function() return false end, nil, 24)
  check("24 spots a tick: the same spot as all at once", ka ~= nil and ka == kb, tostring(ka) .. " " .. tostring(kb))

  -- compass
  check("compass: +Y from the equator is north, +Z east", RU.compass(1, 0, 0, 1, 1, 0) == "north" and RU.compass(1, 0, 0, 1, 0, 1) == "east"
    and RU.compass(1, 0, 0, 1, -1, -1) == "south-west")

  -- the yard
  local yard_ok, knocked_ok, flat_ok, locks_ok, doors_ok = true, true, true, true, true
  for i = 1, 40 do
    local s = RU.nearSite("Y" .. i, { seed = i }, RU.sitesFor("Y" .. i, { atmo = 0.5, seed = i, radius = 800 }, true, 800))
    local full = RU.blueprintOf(s)
    local na, nb = 0, 0
    for _, p in ipairs(full) do
      if p.id == "solarArray" then na = na + 1 end
      if p.id == "batteryBank" then nb = nb + 1; if p.fill ~= 0 then flat_ok = false end end
      if not def(p.id) then yard_ok = false end
    end
    if na ~= 2 or nb ~= 1 then yard_ok = false end
    local kept = RU.decay(full, s)
    local sound, knock = 0, 0
    for _, e in ipairs(kept) do if e.id == "solarArray" then if e.wr then knock = knock + 1 else sound = sound + 1 end end end
    if sound ~= 1 or knock ~= 1 then knocked_ok = false end
    local lp = RU.lockPlan(s, kept)
    local lockers = 0
    for kk, e in ipairs(kept) do
      local nm = e.id:match("^([%w]+)")
      if nm == "locker" then lockers = lockers + 1; if not lp[kk] then locks_ok = false end end
      if RU.isLockDoor(e.id) and lp[kk] then doors_ok = false end
    end
    if lockers < 1 then locks_ok = false end
  end
  check("the yard: two Solar Arrays and a Battery Bank, every piece real", yard_ok)
  check("…one array stands, one is knocked over (a Repair Kit once claimed)", knocked_ok)
  check("…the bank arrives flat", flat_ok)
  check("…its locker is always on a code", locks_ok)
  check("…and never a door (the way in is never sealed)", doors_ok)

  -- the log
  local s = RU.nearSite("L", { seed = 3 }, RU.sitesFor("L", { atmo = 0.5, seed = 3, radius = 800 }, true, 800))
  local l = RU.lore(s)
  check("the near site's log: three entries, the last names the next site", #l == 3 and l[3]:find(s.otherName, 1, true) ~= nil, l[3])
  check("…the same each time", RU.lore(s)[1] == l[1])

  -- the crate (loot.planSite, siteLogs)
  local LO = loadlib("loot.lua")
  local kept = RU.decay(RU.blueprintOf(s), s)
  local lp = RU.lockPlan(s, kept)
  local conts, locks = {}, {}
  for kk, e in ipairs(kept) do
    local d = def(e.id)
    if d and d.container then conts[#conts + 1] = { uid = kk, piece = LO.pieceName(e.id), key = e.ri, locked = lp[kk] ~= nil } end
    if lp[kk] then locks[#locks + 1] = { uid = kk, code = lp[kk], label = "Personnel Locker" } end
  end
  local others = { { id = "X#2", name = "Wrong Camp", where = "1° N" }, { id = s.other, name = s.otherName, where = "12° N, 40° E" } }
  local logs = LO.siteLogs(s, { kind = s.kind, age = s.age, locks = locks, others = others })
  local survey = nil
  for _, lg in ipairs(logs) do if lg.coords then survey = lg end end
  check("its survey note is always there, and names the site its log names", survey ~= nil and survey.coords == s.other)
  local plan = LO.planSite(s, conts, { "iron" }, logs, function() return true end)
  local crate = nil
  for _, c in ipairs(conts) do if c.piece == "crate" and not c.locked then crate = c break end end
  local it = crate and plan[crate.uid].items or {}
  local has_codes = false
  for id in pairs(it) do
    local key = id:match("^datalog:(.+)$")
    for _, lg in ipairs(logs) do if lg.key == key and lg.codes then has_codes = true end end
  end
  check("the outside crate: the shift note with the locker's code", has_codes)
  check("…a crated Solar Panel and a Repair Kit", (it["part:vab.solar"] or 0) >= 1 and (it.repairkit or 0) >= 1)
  check("…a crated Solar Panel is a real part", PB.partInfo("vab.solar") ~= nil)
end

-- ── (R1) the scene: sited near the pad, found up close, Ops's one line ─────
do
  store = {}
  local R = 850
  local function V(x, y, z) return { x = x, y = y, z = z } end
  local body = { name = "Draethos", x = -2000, y = 400, z = 900, radius = R }
  local space = { body = function(n) return n == "Draethos" and body or nil end, dominant = function() return "Draethos" end }
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
  local fu = { x = 0.6, y = 0.64, z = 0.48 }
  local fl = math.sqrt(fu.x ^ 2 + fu.y ^ 2 + fu.z ^ 2)
  fu = { x = fu.x / fl, y = fu.y / fl, z = fu.z / fl }
  local fp = { body = "Draethos", x = fu.x * R, y = fu.y * R, z = fu.z * R, radius = 175 }
  local said = {}
  local SCRIPTS = {}
  local env = { save = SAVE, space = space, terrain = terrain, vec3 = V, time = 0,
                find = function(n) return n == "Astronaut" and astro or nil end,
                findScript = function(k) return SCRIPTS[k] end, log = function() end }
  local ST = loadlib("structures.lua", { save = SAVE })
  local B = loadlib("bases.lua", { save = SAVE })
  SCRIPTS = { structures = ST, bases = B, parts_base = PB, base_facilities = { footprint = fp },
              ops_strip = { say = function(t, who) said[#said + 1] = { t = t, who = who } end },
              deployables = { agencyClock = function() return 5e6 end },
              climate = { worldOf = function(n) return { atmo = 0.6, seed = 777, radius = R, relief = 40, sea = 0 } end } }
  store["system.home"] = { bodies = { { name = "Draethos", radius = R } } }
  store["base.body"] = "Draethos"
  local function crew_at(ux, uy, uz) astro.x, astro.y, astro.z = body.x + ux * (R + 1.8), body.y + uy * (R + 1.8), body.z + uz * (R + 1.8) end
  local function tick() env.time = env.time + 1.1; SCRIPTS.ruins.update(nil, 1.1) end
  local S6 = loadlib("ruins.lua", env)
  SCRIPTS.ruins = S6
  local ns = S6.nearOf("Draethos")
  check("a home world has a near site in the scene (an old save gets it too: nothing was saved)", ns ~= nil and ns.pending == true)
  crew_at(fu.x, fu.y, fu.z)
  tick()
  local e = S6.state(ns.id)
  local d = e.g and RU.groundDist(R, fp.x, fp.y, fp.z, e.g.x, e.g.y, e.g.z) or -1
  check("the crew at the pad: the near site sited 330–400 m out", d >= 329.5 and d <= 400.5, d)
  check("…its door faces the pad", e.g and (function()
    local dx, dy, dz = fp.x - e.g.x, fp.y - e.g.y, fp.z - e.g.z
    local l = math.sqrt(dx * dx + dy * dy + dz * dz)
    return (dx * e.g.fx + dy * e.g.fy + dz * e.g.fz) / l > 0.95
  end)())
  tick()
  e = S6.state(ns.id)
  check("…and stamped from the first minute (within 600 m)", e.sid ~= nil and ST.get(e.sid) ~= nil and ST.get(e.sid).ru == ns.id)
  check("…not found from the pad (it is walked to)", not S6.discovered(ns.id))
  check("…no word from Ops before First Steps", #said == 0)
  store["prog.done"] = { first_steps = true }
  tick()
  check("First Steps done: Ops says where it is, once, on the radio", #said == 1 and said[1].who == "Ops" and said[1].t:find(" m ", 1, true) ~= nil
    and said[1].t:find(RU.LABEL[ns.kind], 1, true) ~= nil, said[1] and said[1].t)
  tick(); tick()
  check("…only once", #said == 1)
  -- walk to 80 m of it
  local gl = math.sqrt(e.g.x ^ 2 + e.g.y ^ 2 + e.g.z ^ 2)
  local gu = { x = e.g.x / gl, y = e.g.y / gl, z = e.g.z / gl }
  local ux, uy, uz = RU.ringDir(gu.x, gu.y, gu.z, 0.3, 80, R)
  crew_at(ux, uy, uz)
  tick()
  check("walked to 80 m: found", S6.discovered(ns.id))
  -- a reload: the same near site, sited where it was
  local S7 = loadlib("ruins.lua", env)
  SCRIPTS.ruins = S7
  local ns2 = S7.nearOf("Draethos")
  check("a reload: the same near site, where it stands", ns2 and ns2.id == ns.id and not ns2.pending and math.abs(ns2.ux - gu.x) < 1e-9)

  -- an OLD save whose structures fill the ring: clear of them
  store = {}
  store["system.home"] = { bodies = { { name = "Draethos", radius = R } } }
  store["base.body"] = "Draethos"
  said = {}
  ST.reloadFromSave()
  local recs = {}
  for a = 0, 23 do
    local sx, sy, sz = RU.ringDir(fu.x, fu.y, fu.z, a * math.pi / 12, 365, R)
    local rec = ST.newRecord(nil, "Draethos", sx * R, sy * R, sz * R, V(sx, sy, sz), V(0, 0, 1), "wall.steel", { by = "player" })
    recs[#recs + 1] = ST.add(rec)
  end
  local S8 = loadlib("ruins.lua", env)
  SCRIPTS.ruins = S8
  crew_at(fu.x, fu.y, fu.z)
  for _ = 1, 12 do tick() end
  local n8 = S8.nearOf("Draethos")
  local e8 = S8.state(n8.id)
  local clear8 = e8.g ~= nil
  for _, sid in ipairs(recs) do
    local r = ST.get(sid)
    if e8.g and RU.groundDist(R, e8.g.x, e8.g.y, e8.g.z, r.x, r.y, r.z) < RU.BUILT_MIN then clear8 = false end
  end
  check("an old save with its structures round the ring: the site added, clear of every one", clear8,
    e8.g and RU.groundDist(R, fp.x, fp.y, fp.z, e8.g.x, e8.g.y, e8.g.z))

  -- an OLD save with a site already within 450 m of the pad: that one is pointed at, no second site
  store = {}
  store["system.home"] = { bodies = { { name = "Draethos", radius = R } } }
  store["base.body"] = "Draethos"
  ST.reloadFromSave()
  local S9 = loadlib("ruins.lua", env)
  SCRIPTS.ruins = S9
  local first = nil
  for _, x in ipairs(S9.sites("Draethos")) do if not x.pending then first = x break end end
  local ax, ay, az = RU.ringDir(fu.x, fu.y, fu.z, 1.0, 420, R)
  store["ruins.s"] = { [first.id] = { g = { x = ax * (R - 0.15), y = ay * (R - 0.15), z = az * (R - 0.15), ux = ax, uy = ay, uz = az, fx = 1, fy = 0, fz = 0 } } }
  S9 = loadlib("ruins.lua", env)
  SCRIPTS.ruins = S9
  said = {}
  store["prog.done"] = { first_steps = true }
  crew_at(fu.x, fu.y, fu.z)
  tick(); tick()
  local n9 = S9.nearOf("Draethos")
  check("an old save with a site 420 m out: no second near site (alias)", S9.state(n9.id).alias == first.id and S9.state(n9.id).g == nil)
  check("…Ops points at that one", #said == 1 and said[1].t:find("400 m", 1, true) ~= nil, said[1] and said[1].t)

  -- a scenario save: no near site
  store = { ["game.mode"] = "scenario", ["system.home"] = { bodies = { { name = "Draethos", radius = R } } }, ["base.body"] = "Draethos" }
  local S10 = loadlib("ruins.lua", env)
  check("a scenario's world: no near site (the author's world is the author's)", S10.nearOf("Draethos") == nil)
end

if failed == 0 then
  print(string.format("RUINS SMOKE OK — %d checks passed", count))
  os.exit(0)
end
print(string.format("RUINS SMOKE: %d of %d checks failed", failed, count))
os.exit(1)
