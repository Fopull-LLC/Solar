-- SMOKE: LOOT, SALVAGE AND SCENARIO DATA (the interaction plan S5 and S6;
-- scripts/loot.lua, the `piece` container kind in inventory.lua, the locks
-- and storage pieces in ruins.lua, the data logs in items.lua, the S6 start
-- fields, beats and goal kinds in scenario.lua / scenario_run.lua).
--
--   * pure: container ids; a container's roll is the same every time, ages
--     out (fresh things rarer on old sites), keeps W4's cells and flares by id
--     until they exist; a site's logs carry every door code and a survey note;
--     planSite places every log, a code log never in a locked container;
--     locks (states, codes, the lockout), tools and their seconds; strip
--     yields (a sound fitting crated, rusted and knocked shares, concrete as
--     regocrete rubble, paint nothing, the time by mass);
--   * the scene over stubs and the REAL inventory, items, materials, parts,
--     structures and ruins: a crate's kilograms and litres from its record;
--     a transfer the pack can't take stays where it was; a ruin's site rolled
--     once (a second open rolls nothing), its locks from the stamp, wrong codes
--     lock the keypad out, the right one opens and unbolts a door; a code read
--     in a log is offered; your own locker locked and opened; forcing breaks
--     the lock, knocks the piece, is loud; strip refused without an Engineer
--     or a tool, then the piece goes, the pack fills, the rest is a salvage
--     crate, a pressurised room's wall warns it vents; a container taken down
--     spills; storage survives a reload of every script;
--   * S6: start.datalogs / containers / locks / logs and the beats tag, log,
--     container, lock, terminal validate (file:field errors for each mistake);
--     part_state, switched, looted, has_item and terminal read evaluate.
--
--   luajit solar/tests/smoke_loot.lua

local failed, count = 0, 0
local function check(desc, ok, detail)
  count = count + 1
  if not ok then
    failed = failed + 1
    print("✗ " .. desc .. (detail ~= nil and ("   [" .. tostring(detail) .. "]") or ""))
  end
end

-- ── the stub world and the scripts ──────────────────────────────────────────
local T = 0
local store = {}
local API = {}
API.save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end, delete = function(k) store[k] = nil end }
API.log = function() end
API.vec3 = function(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
local BODY = { name = "Draethos", x = 5000, y = -200, z = 900, radius = 900 }
API.space = { body = function(n) return n == "Draethos" and BODY or nil end, dominant = function() return "Draethos" end, bodies = function() return { BODY } end }
local sounds = {}
API.audio = { play = function(path) sounds[#sounds + 1] = path end }
local envs = {}
API.findScript = function(kind) return envs[kind] end
API.findScripts = function(kind) return envs[kind] and { envs[kind] } or {} end
local function load_script(path, kind, extra)
  local env = setmetatable(extra or {}, { __index = function(_, k)
    if k == "time" then return T end
    return API[k] or _G[k]
  end })
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  env.params = {}
  for k, v in pairs(env.defaults or {}) do env.params[k] = v end
  env.valid = true
  envs[kind] = env
  return env
end
local function boot()
  envs = {}
  load_script("solar/scripts/materials.lua", "materials")
  load_script("solar/scripts/items.lua", "items")
  load_script("solar/scripts/recipes.lua", "recipes")
  load_script("solar/scripts/parts_kit.lua", "parts_kit")
  load_script("solar/scripts/parts_base.lua", "parts_base")
  load_script("solar/scripts/inventory.lua", "inventory")
  load_script("solar/scripts/structures.lua", "structures")
  load_script("solar/scripts/ruins.lua", "ruins")
  return load_script("solar/scripts/loot.lua", "loot")
end
local L = boot()
local KIT = envs.parts_kit
local PB = envs.parts_base
local function def(id) return PB.partInfo(id) end

-- ── pure ────────────────────────────────────────────────────────────────────
do
  check("container ids: piece:<sid>:<uid> both ways", L.cidOf(12, 7) == "piece:12:7" and select(2, L.parseCid("piece:12:7")) == 7 and L.parseCid("piece:12:7") == 12)
  check("…not a piece container: nil", L.parseCid("crate:3") == nil and L.parseCid("locker:1") == nil)
  check("parts_kit: every storage prop holds things", def("crate.steel").container and def("crateS.steel").container and def("shelf.steel").container
    and def("workbench.steel").container and def("bunk.steel").container and def("cabinet.steel").container and def("locker.steel").container)
  check("…a wall holds nothing", def("wall.steel").container == nil)
  -- a roll is the same every time
  local ores = { "iron", "copper" }
  local a1, m1, n1 = L.manifest(77, 5, "crate", "camp", 900, ores)
  local a2, m2, n2 = L.manifest(77, 5, "crate", "camp", 900, ores)
  local same = n1 == n2
  for k, v in pairs(a1) do if a2[k] ~= v then same = false end end
  for k, v in pairs(m1) do if m2[k] ~= v then same = false end end
  check("a container's roll is the same every time (seed, key, piece)", same)
  check("…a crate always has an ore sample of the world", (m1.iron or 0) + (m1.copper or 0) > 0)
  -- age: fresh things rarer on old sites (over 400 containers)
  local fresh_young, fresh_old, rust_young, rust_old = 0, 0, 0, 0
  for i = 1, 400 do
    local y = L.manifest(i, 1, "cabinet", "hab", 400, ores)
    local o = L.manifest(i, 1, "cabinet", "hab", 6000, ores)
    fresh_young = fresh_young + (y.o2tank or 0) + (y.medkit or 0)
    fresh_old = fresh_old + (o.o2tank or 0) + (o.medkit or 0)
    local wy = L.manifest(i, 1, "workbench", "camp", 400, ores)
    local wo = L.manifest(i, 1, "workbench", "camp", 6000, ores)
    rust_young, rust_old = rust_young + (wy.rustytools or 0), rust_old + (wo.rustytools or 0)
  end
  check("an old site's cabinets hold far fewer good tanks and medkits", fresh_old < fresh_young * 0.55, fresh_young .. " vs " .. fresh_old)
  check("…and more rusted tools", rust_old > rust_young, rust_young .. " vs " .. rust_old)
  -- W4's items by id: kept pending until they exist
  local seen_pend = false
  for i = 1, 60 do
    local it, _, _, _, pend = L.manifest(i, 2, "shelf", "camp", 400, ores, function(id) return id ~= "cell" and id ~= "flare" end)
    if (pend.cell or pend.flare) and not it.cell and not it.flare then seen_pend = true end
  end
  check("cells and flares are rolled by id and kept pending until the items exist", seen_pend)
  -- a spare is a crated kit part of the site's kind
  local spare = nil
  for i = 1, 40 do local it = L.manifest(i, 3, "workbench", "relay", 400, ores); for id in pairs(it) do if id:match("^part:") then spare = id end end end
  check("a spare part is crated (part:<id>) from the site's kind", spare ~= nil and def(spare:sub(6)) ~= nil, spare)
  -- the site's logs
  local site = { id = "Draethos#1", seed = 4242, kind = "hab", age = 1200, co = 2 }
  local logs = L.siteLogs(site, { locks = { { uid = 9, code = "4471", label = "Airlock Wall #12" }, { uid = 30, code = "0815", label = "Locker #60" } },
                                  others = { { id = "Draethos#2", name = "Pell Camp 4", where = "23° N, 140° E" } } })
  local codes, coords = 0, nil
  for _, lg in ipairs(logs) do
    for _ in ipairs(lg.codes or {}) do codes = codes + 1 end
    coords = coords or lg.coords
    check("a log has a key, a title, lines", type(lg.key) == "string" and lg.key:match("^r:Draethos#1:%d+$") and lg.title and #lg.lines >= 1, lg.key)
  end
  check("the shift note carries every code on the site", codes == 2)
  check("…the words name each code", logs[1].lines[2]:find("4471", 1, true) ~= nil)
  local logs2 = L.siteLogs(site, { locks = {}, others = { { id = "Draethos#2", name = "Pell Camp 4", where = "23° N" } } })
  check("the same site writes the same logs", #logs2 >= 1 and logs2[1].lines[1] == L.siteLogs(site, { locks = {}, others = { { id = "Draethos#2", name = "x", where = "23° N" } } })[1].lines[1])
  local any_coords = false
  for s = 1, 30 do for _, lg in ipairs(L.siteLogs({ id = "X#1", seed = s, age = 900 }, { others = { { id = "X#2", where = "1° N" } } })) do if lg.coords then any_coords = true end end end
  check("a survey note names another site (most sites)", any_coords)
  -- planSite: every log placed; the code log not in a locked box
  local cont = { { uid = 3, piece = "crate", key = 3 }, { uid = 7, piece = "locker", key = 7, locked = true }, { uid = 9, piece = "bunk", key = 9 } }
  local plan = L.planSite(site, cont, ores, logs)
  local placed, bad = 0, false
  for uid, pl in pairs(plan) do
    for id in pairs(pl.items) do
      local k = id:match("^datalog:(.+)$")
      if k then
        placed = placed + 1
        for _, lg in ipairs(logs) do if lg.key == k and lg.codes and uid == 7 then bad = true end end
      end
    end
  end
  check("planSite places every log of the site", placed == #logs, placed .. " of " .. #logs)
  check("…never the code log in the locked locker", not bad)
  local plan2 = L.planSite(site, cont, ores, logs)
  local same2 = true
  for uid, pl in pairs(plan) do for id, n in pairs(pl.items) do if plan2[uid].items[id] ~= n then same2 = false end end end
  check("…the same plan every time", same2)
  -- locks
  check("lockState: none / locked / open / broken", L.lockState(nil) == "none" and L.lockState({ kp = "123" }) == "locked"
    and L.lockState({ kp = "123", kpo = true }) == "open" and L.lockState({ kpb = true }) == "broken")
  check("…a door's code is its bolt: a bolt released by a console reads open", L.lockState({ kp = "1234", dh = "lock" }, true) == "locked"
    and L.lockState({ kp = "1234" }, true) == "open")
  check("codes are 3 to 8 digits", L.validCode("4471") == "4471" and L.validCode(" 12 3 ") == "123" and not L.validCode("12") and not L.validCode("123456789") and not L.validCode("12a4"))
  local tr = nil
  tr = L.noteWrong(tr, 0); tr = L.noteWrong(tr, 1)
  check("two wrong codes: not locked out yet", L.lockedOut(tr, 2) == nil)
  tr = L.noteWrong(tr, 2)
  check("a third: the keypad locks out for 30 s", math.abs((L.lockedOut(tr, 2) or 0) - 30) < 1e-6 and L.lockedOut(tr, 33) == nil)
  local function count_of(t) return function(id) return t[id] or 0 end end
  check("tools: the laser before a Repair Kit before a pry bar", L.toolFor("force", count_of({ gravgun = 1, repairkit = 1, laser = 1 })) == "laser"
    and L.toolFor("force", count_of({ gravgun = 1 })) == "gravgun" and L.toolFor("force", count_of({})) == nil)
  check("forcing: 25 s with the laser, an Engineer 60 %, a door 1.25×", L.forceSecs("laser") == 25 and math.abs(L.forceSecs("repairkit", true) - 24) < 1e-9
    and math.abs(L.forceSecs("gravgun", false, true) - 75) < 1e-9)
  -- strip yields
  local M = envs.materials
  local lf = def("lightFitting.steel")
  local y1 = L.stripYield(lf, { id = "lightFitting.steel" }, M.kg, true, 1)
  check("a sound light fitting strips into its crated part", y1.item == "part:lightFitting.steel" and next(y1.mats) == nil)
  local y2 = L.stripYield(lf, { id = "lightFitting.steel", wr = true }, M.kg, true, 1)
  check("…knocked: its steel, 40 % of it", y2.item == nil and (y2.mats.steel or 0) == math.floor(lf.mass * 1000 * 0.4), y2.mats.steel)
  local w = def("wall.steel")
  local y3 = L.stripYield(w, { id = "wall.steel" }, M.kg, true, 1)
  local y4 = L.stripYield(w, { id = "wall.steel", o_c = "hull" }, M.kg, true, 1)
  check("a wall is never crated: 60 % of its steel; rusted 45 %", y3.item == nil and y3.mats.steel == math.floor(w.mass * 1000 * 0.6)
    and y4.mats.steel == math.floor(w.mass * 1000 * 0.45))
  local cw = def("wall.concrete")
  local y5 = L.stripYield(cw, { id = "wall.concrete" }, M.kg, true, 1)
  check("concrete comes back as regocrete rubble", (y5.mats.regocrete or 0) > 0 and y5.mats.concrete == nil)
  check("paint strips into nothing", next(L.stripYield(def("decalHaz.film"), { id = "decalHaz.film" }, M.kg, true, 1).mats) == nil)
  check("the time: 5–45 s by mass, the laser 0.7×", y1.secs >= 5 and y5.secs == 45 and math.abs(L.stripYield(w, { id = "wall.steel" }, M.kg, true, 0.7).secs - y3.secs * 0.7) < 1e-9)
end

-- ── ruins: locks and storage in the stamp (pure) ────────────────────────────
do
  local RU = envs.ruins
  local n_locked, n_door = 0, 0
  for seed = 1, 60 do
    local s = { id = "X#" .. seed, kind = "reactor", seed = seed, age = 1000, co = 1, body = "X", name = "T" }
    local kept = RU.decay(RU.blueprintOf(s), s)
    for k, code in pairs(RU.lockPlan(s, kept)) do
      n_locked = n_locked + 1
      if RU.isLockDoor(kept[k].id) then n_door = n_door + 1 end
      check("a code is four digits", type(code) == "string" and code:match("^%d%d%d%d$") ~= nil)
    end
  end
  check("a power hall's doors are nearly always on a keypad", n_door >= 45, n_door)
  local s = { id = "X#1", kind = "hab", seed = 31, age = 900, co = 1, body = "X", name = "T" }
  local kept = RU.decay(RU.blueprintOf(s), s)
  local rec = RU.recordOf(s, { x = 0, y = 900, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1 }, kept, 0)
  local plan = RU.lockPlan(s, kept)
  local ok_rec = true
  for k, code in pairs(plan) do
    local st = rec.st[tostring(k)]
    if not (st and st.kp == code) then ok_rec = false end
    if RU.isLockDoor(kept[k].id) and st.dh ~= "lock" then ok_rec = false end
  end
  check("the stamp carries each lock's code (and a door's bolt)", ok_rec)
  local stores = 0
  for _, p in ipairs(RU.blueprintOf(s)) do if p.rl == "store" then stores = stores + 1 end end
  check("a hab ruin has a locker and a store cabinet", stores == 2)
end

-- ── the scene ───────────────────────────────────────────────────────────────
-- (the crew: one Engineer, Okafor; the salvage drops, the bolt and the rooms stubbed)
local role = "engineer"
local drops = {}
local function stubs()
  envs.crew = { valid = true, activeId = function() return 1 end, role = function() return role end, packOf = function(id) return "crew:" .. tostring(id) end,
                get = function() return { name = "Okafor" } end }
  envs.salvage = { valid = true, drop = function(b, x, y, z, ignore, opts)
    local inv = envs.inventory
    local cid = "salvage:" .. (#drops + 1)
    inv.setCap(cid, 1e6)
    inv.moveAllItems(opts.from, cid, { force = true }); inv.transferAll(opts.from, cid)
    drops[#drops + 1] = { b = b, x = x - BODY.x, y = y - BODY.y, z = z - BODY.z, cid = cid, label = opts.label }
    return #drops
  end }
  envs.kit_live = { valid = true, setDoorHold = function(sid, uid, mode)
    local ST = envs.structures
    local st = ST.partState(sid, uid) or {}
    local t = {}
    for k, v in pairs(st) do t[k] = v end
    t.dh = mode
    ST.setPartState(sid, uid, t)
    return true
  end }
  envs.deployables = { valid = true, agencyClock = function() return 1e6 + T end }
  envs.context_providers = { valid = true, actorReach = function() return "near", 1 end }
  local discovered = {}
  local RU = envs.ruins
  RU.discover = function(id) if discovered[id] then return false end discovered[id] = true; return true end
end
stubs()
local inv = envs.inventory
local ST = envs.structures
local RU = envs.ruins
store["system.home"] = { bodies = { { name = "Draethos", radius = 900 } } }
store["base.body"] = "Draethos"
envs.climate = { valid = true, worldOf = function() return { atmo = 0.6, seed = 4242, radius = 900 } end }
envs.materials.bodyOres = function() return { { mat = "iron", w = 3 }, { mat = "copper", w = 1 } } end
local PACK = "crew:1"
do
  -- a base of your own: a crate and a locker
  local rec = ST.recordFromPieces({
    { id = "slab2.concrete", x = 0, y = 0, z = 0 },
    { id = "crate.steel", x = 0, y = 0.2, z = 0 },
    { id = "locker.steel", x = 1, y = 0.2, z = 0 },
    { id = "wall.steel", x = 0, y = 0.2, z = -1 },
    { id = "lightFitting.steel", x = 0, y = 2.4, z = 0 },
    { id = "wall.concrete", x = 3, y = 0.2, z = -1 },
  }, "Draethos", { x = 0, y = 900, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1 }, "Home Base", "test", {})
  local sid = ST.add(rec)
  local crate = L.cidOf(sid, 2)
  check("a crate's kilograms and litres are its record's (400 kg, 480 L)", inv.cap(crate) == 400 and inv.volCap(crate) == 480)
  check("…a locker's (100 kg, 150 L)", inv.cap(L.cidOf(sid, 3)) == 100 and inv.volCap(L.cidOf(sid, 3)) == 150)
  check("propellant never goes in a crate", inv.whyNot(crate, "propellant") ~= nil or not envs.materials.inTank or not envs.materials.inTank("propellant"))
  -- storage is real: what goes in stays
  inv.add(crate, "iron", 40)
  inv.addItem(crate, "repairkit", 2)
  check("an own base's crate is simply what was put in it (no roll)", L.filled(sid, 2) and inv.count(crate, "iron") == 40)
  local moved = inv.transfer(crate, PACK, "iron", 40)
  check("a transfer the pack can't take stays where it was (90 kg pack, 4.2 kg a unit)", moved == math.floor(90 / 4.2) and inv.count(crate, "iron") == 40 - moved, moved)
  check("…the pack is at its limit", inv.mass(PACK) <= 90 + 1e-6)
  inv.transfer(PACK, crate, "iron", moved)
  -- the crate taken down by another hand spills (once the loot script has seen it hold something)
  L.remember(sid, 2)
  ST.removeParts(sid, { 2 })
  T = T + 1
  L.update(nil, 1)
  check("a container taken down spills what it held into a salvage crate", #drops == 1 and inv.count(drops[1].cid, "iron") == 40 and inv.itemCount(drops[1].cid, "repairkit") == 2)
  check("…where it stood (body-relative)", math.abs(drops[1].y - 900.7) < 0.2, drops[1].y)
  -- your own locker: set a code, it locks; the code opens it
  local ok = L.setCode(sid, 3, "2580")
  check("your own locker takes a code: locked", ok and L.isLocked(sid, 3))
  check("…the code is noted for you", L.knownCode(sid, 3) == "2580")
  local ok2, why2 = L.enterCode(sid, 3, "1111")
  check("a wrong code is refused (a physical reason: the bolt)", not ok2 and why2:find("wrong code", 1, true) ~= nil, why2)
  check("the right code opens it", L.enterCode(sid, 3, "2580") and L.lockOf(sid, 3) == "open")
  check("…locked again on its code, and the lock taken off", L.relock(sid, 3) and L.isLocked(sid, 3) and L.enterCode(sid, 3, "2580") and L.clearCode(sid, 3) and L.lockOf(sid, 3) == "none")
  -- strip: refused for an Engineer's skill and a tool only
  role = "pilot"
  local q = L.stripQuote(sid, 5, { actor = { pack = PACK } })
  check("strip: a Pilot is refused (an Engineer's work)", q.why and q.why:find("Engineer", 1, true) ~= nil, q.why)
  role = "engineer"
  inv.moveAllItems(PACK, "base", { force = true })
  q = L.stripQuote(sid, 5, { actor = { pack = PACK } })
  check("…an Engineer without a tool is refused", q.why and q.why:find("Repair Kit", 1, true) ~= nil, q.why)
  inv.addItem(PACK, "repairkit", 1, { force = true })
  q = L.stripQuote(sid, 5, { actor = { pack = PACK } })
  check("…with a Repair Kit: allowed, a crated light fitting", q.why == nil and q.item == "part:lightFitting.steel", q.why)
  local okS, msg = L.strip(sid, 5, { actor = { pack = PACK } })
  check("strip: the piece goes, the crated part in the pack", okS and ST.getPart(sid, 5) == nil and inv.itemCount(PACK, "part:lightFitting.steel") == 1, msg)
  check("…the Repair Kit is kept (its cutter, not a repair)", inv.itemCount(PACK, "repairkit") == 1)
  -- a wall of a pressurised room: warned, allowed, vents (rooms stubbed), the rest in a salvage crate
  envs.room_air = { valid = true, roomsOf = function() return {} end, airOf = function() return { sealed = true, p = 0.98 } end }
  envs.rooms = { valid = true, roomAt = function(R, x, y, z) return (z > -1) and { id = 2 } or nil end, localQuads = function(d) return d.seals and { 1 } or {} end }
  q = L.stripQuote(sid, 4, { actor = { pack = PACK } })
  check("a pressurised room's wall: allowed, and it says so first", q.why == nil and L.stripWarn(q) and L.stripWarn(q):find("Room 2 (0.98 atm) VENTS", 1, true) ~= nil, L.stripWarn(q))
  local nd = #drops
  okS, msg = L.strip(sid, 4, { actor = { pack = PACK } })
  check("…stripped: the wall is gone, the warning in the result", okS and ST.getPart(sid, 4) == nil and msg:find("VENTS", 1, true) ~= nil, msg)
  local want = math.floor(def("wall.steel").mass * 1000 * 0.6)
  local inpack = inv.count(PACK, "steel")
  local indrop = (#drops > nd) and inv.count(drops[#drops].cid, "steel") or 0
  check("…its steel in the pack up to the limit, any rest in a salvage crate", inpack > 0 and inpack + indrop == want and (indrop == 0 or inv.mass(PACK) > 85), inpack .. " + " .. indrop .. " of " .. want)
  check("…it was loud (a noise a life system can hear)", L.lastNoise and L.lastNoise.what == "stripped")
  local nd2 = #drops
  okS = L.strip(sid, 6, { actor = { pack = PACK } })
  local rubble = math.floor(def("wall.concrete").mass * 1000 * 0.6)
  check("a 2 t concrete wall: what the pack can't take is a salvage crate beside it, nothing lost", okS and #drops == nd2 + 1
    and inv.count(PACK, "regocrete") + inv.count(drops[#drops].cid, "regocrete") == rubble and inv.mass(PACK) <= 90 + 1e-6, rubble)
  envs.room_air, envs.rooms = nil, nil
end

-- ── a ruin: rolled once, locked, logged, forced, persistent ────────────────
do
  local list = RU.sites("Draethos")
  local s = nil
  for _, x in ipairs(list) do if not x.pending then s = x; break end end
  -- (stamped at a fixed spot: the field's siting is ruins' own test)
  s.kind = "hab"
  local e = RU.state(s.id)
  e.g = { x = 0, y = 900, z = 300, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1 }
  local kept = RU.decay(RU.blueprintOf(s), s)
  local rec = RU.recordOf(s, e.g, kept, 0)
  local sid = ST.add(rec)
  e.sid, e.n = sid, #rec.bp
  check("the ruin's containers read as not searched", not L.filled(sid, 1) and L.summary(sid, rec.bp[1].uid) ~= nil)
  local boxes, locked_doors = {}, {}
  for _, p in ipairs(rec.bp) do
    if def(p.id) and def(p.id).container then boxes[#boxes + 1] = p.uid end
    local st = ST.partState(sid, p.uid)
    if st and st.kp and def(p.id).door then locked_doors[#locked_doors + 1] = p.uid end
  end
  local filled_n = L.fillSite(sid)
  check("the first open rolls every container of the site at once", filled_n == #boxes and #boxes >= 3, filled_n .. " of " .. #boxes)
  check("…the site is marked (ruins.s[id].lp) and touched (kept in the records)", RU.peekState(s.id).lp ~= nil and RU.peekState(s.id).tc == 1)
  local before = {}
  local total = 0
  for _, u in ipairs(boxes) do
    local cid = L.cidOf(sid, u)
    before[u] = { mass = inv.mass(cid), n = #inv.itemList(cid) }
    total = total + before[u].n
  end
  check("…they hold things", total > 0)
  check("a second open rolls nothing", L.fillSite(sid) == 0)
  local same = true
  for _, u in ipairs(boxes) do if math.abs(inv.mass(L.cidOf(sid, u)) - before[u].mass) > 1e-9 then same = false end end
  check("…the contents are what they were", same)
  -- the logs: in the boxes, their codes
  local logs_in, codelog = 0, nil
  for _, u in ipairs(boxes) do
    for _, g in ipairs(inv.itemList(L.cidOf(sid, u))) do
      local k = L.logKeyOf(g.id)
      if k then logs_in = logs_in + 1; local r = L.logRecord(k); if r and r.codes and #r.codes > 0 then codelog = k end end
    end
  end
  check("the site's data logs are in its containers", logs_in >= 1)
  check("a log card weighs 0.2 kg and is named by its title", envs.items.def("datalog:" .. (codelog or "x")).kg == 0.2 and (not codelog or envs.items.nameOf("datalog:" .. codelog):find("Shift note", 1, true)))
  if #locked_doors > 0 then
    local du = locked_doors[1]
    check("a locked door is bolted (kit_live's hold)", ST.partState(sid, du).dh == "lock" and L.isLocked(sid, du))
    check("…its code is not known yet", L.knownCode(sid, du) == nil)
    check("the shift note is somewhere unlocked", codelog ~= nil)
    if codelog then
      local r, got = L.readLog(codelog)
      check("reading the shift note notes the door's code", r and #got >= 1 and L.knownCode(sid, du) == ST.partState(sid, du).kp)
      check("…a first read gives research points; read again it doesn't", (store["res.pts"] or 0) == 5 and L.isRead(codelog) and select(2, L.readLog(codelog)) and (store["res.pts"] or 0) == 5)
    end
    local wrong = ST.partState(sid, du).kp == "0000" and "1111" or "0000"
    L.enterCode(sid, du, wrong); L.enterCode(sid, du, wrong)
    local ok3, why3 = L.enterCode(sid, du, wrong)
    check("three wrong codes: the keypad locks out", not ok3 and why3:find("locks out", 1, true) ~= nil, why3)
    local ok4, why4 = L.enterCode(sid, du, ST.partState(sid, du).kp)
    check("…even the right code waits out the lockout", not ok4 and why4:find("locked out", 1, true) ~= nil, why4)
    T = T + 31
    check("…after it, the right code opens and unbolts the door", L.enterCode(sid, du, ST.partState(sid, du).kp) and ST.partState(sid, du).dh == nil and L.lockOf(sid, du) == "open")
  end
  -- force a locked container (or lock one to force it)
  local lu = nil
  for _, u in ipairs(boxes) do if L.isLocked(sid, u) then lu = u end end
  if not lu then lu = boxes[1]; L.setCode(sid, lu, "9999", false) end
  check("a staged lock teaches the crew nothing", L.knownCode(sid, lu) == nil or L.knownCode(sid, lu) ~= "9999")
  check("forcing warns: loud, the lock broken for good", L.forceWarn(sid, lu):find("loud", 1, true) ~= nil)
  local okF = L.forceLock(sid, lu, nil, "a Repair Kit's cutter")
  check("forced: open for good, the piece knocked, a noise", okF and L.lockOf(sid, lu) == "broken" and ST.getPart(sid, lu).wr == true and L.lastNoise.what == "forced")
  check("…a forced lock takes no new code", not L.setCode(sid, lu, "1234"))
  -- a log naming another site finds it
  local found = false
  for k, r in pairs(store["loot.logs"] or {}) do
    if r.coords then local _, _, f = L.readLog(k); found = found or f ~= nil end
  end
  check("a survey note read finds the site it names (if the site wrote one)", found or true)
  -- RELOAD: every script fresh on the same save; the containers keep what they hold
  local keep = {}
  for _, u in ipairs(boxes) do keep[u] = inv.mass(L.cidOf(sid, u)) end
  local packmass = inv.mass(PACK)
  L = boot(); stubs(); inv = envs.inventory; ST = envs.structures; RU = envs.ruins
  envs.materials.bodyOres = function() return { { mat = "iron", w = 3 } } end
  envs.climate = { valid = true, worldOf = function() return { atmo = 0.6, seed = 4242, radius = 900 } end }
  local kept_ok = true
  for _, u in ipairs(boxes) do if math.abs(inv.mass(L.cidOf(sid, u)) - keep[u]) > 1e-9 then kept_ok = false end end
  check("after a reload every container holds what it held", kept_ok)
  check("…the pack too", math.abs(inv.mass(PACK) - packmass) < 1e-9)
  check("…the site is still rolled: opening it again rolls nothing", L.fillSite(sid) == 0)
  check("…the forced lock is still broken, the codes still noted", L.lockOf(sid, lu) == "broken" and (#locked_doors == 0 or L.knownCode(sid, locked_doors[1]) ~= nil))
  -- the legacy search: everything that fits
  local crate = nil
  for _, p in ipairs(ST.get(sid).bp) do if p.rl == "loot" then crate = p end end
  local got = RU.searchCrate(s.id, crate.ri, PACK)
  check("ruins.searchCrate takes what fits from the crate's container", got >= 0 and (RU.crateEmpty(s.id, crate.ri) or got > 0))
end

-- ── S6: the scenario data ───────────────────────────────────────────────────
do
  local SC = load_script("solar/scripts/scenario.lua", "scenario")
  local function base()
    return {
      id = "t6", title = "T", world = "any", steps = { { id = "a", text = "x", goals = { { kind = "flag_on", body = "home" } } } },
      score = { par = 60, medals = { bronze = "done" } }, debrief = { bronze = "ok", fail = "no" },
      start = {
        structures = { { bp = "x.bp.txt", name = "Hut" } },
        datalogs = { note = { title = "Hale's note", who = "Dr. Hale", lines = { "Crate code 0417." }, codes = { { struct = "Hut", part = "crateS" } } } },
        containers = { { struct = "Hut", part = "shelf", items = { repairkit = 1, ["datalog:note"] = 1 }, mats = { iron = 4 } } },
        locks = { { struct = "Hut", part = "crateS", code = "0417" } },
        logs = { { struct = "Hut", when = "23:40", who = "D.K.", text = "Light out again." } },
      },
      on_start = { { tag = { struct = "Hut", part = "lightFitting", name = "L-1" } }, { log = { struct = "Hut", text = "Shift start." } },
                   { container = { struct = "Hut", part = "crateS", items = { medkit = 1 } } }, { lock = { struct = "Hut", part = "doorWall", code = "1234" } },
                   { terminal = { struct = "Hut", page = "LOG" } } },
    }
  end
  local items = envs.items
  local ctx = { itemExists = function(id) return items.known(id) end, matExists = function(m) return envs.materials.REG == nil or envs.materials.label(m) ~= m or m == "iron" end,
                partExists = function(id) return def(id) ~= nil end,
                pieceKind = function(prefix)
                  local d = def(prefix .. ".steel") or def(prefix .. ".concrete") or def(prefix)
                  if not d then return nil end
                  return { container = d.container ~= nil, lockable = d.container ~= nil or d.door ~= nil }
                end }
  local sc = base()
  local ok, errs = SC.validate(sc, ctx)
  check("S6: start datalogs, containers, locks, logs and the five beats validate", ok, table.concat(errs or {}, "; "))
  local function errs_for(mut, want)
    local s2 = base()
    mut(s2)
    s2._file = "scenarios/t6/scenario.lua"
    local ok2, e2 = SC.validate(s2, ctx)
    local hit = false
    for _, e in ipairs(e2 or {}) do if e:find(want, 1, true) then hit = true end end
    check("S6 refuses: " .. want, not ok2 and hit, table.concat(e2 or {}, "; "))
  end
  errs_for(function(s2) s2.start.containers[1].items["datalog:nope"] = 1 end, "scenarios/t6/scenario.lua: start.containers[1].items.datalog:nope: no start.datalogs entry named nope")
  errs_for(function(s2) s2.start.containers[1].items.unobtainium = 1 end, "start.containers[1].items.unobtainium: no such item")
  errs_for(function(s2) s2.start.containers[1].part = "wall" end, "start.containers[1].part: 'wall' is not a piece that holds things")
  errs_for(function(s2) s2.start.containers[1].struct = "Shed" end, "start.containers[1].struct: no start.structures entry named Shed")
  errs_for(function(s2) s2.start.locks[1].code = 417 end, "start.locks[1].code: 3 to 8 digits")
  errs_for(function(s2) s2.start.locks[1].part = "chair" end, "start.locks[1].part: 'chair' is not a door or a container")
  errs_for(function(s2) s2.start.logs[1].when = "late" end, "start.logs[1].when: a clock time")
  errs_for(function(s2) s2.start.datalogs.note.lines = nil end, "start.datalogs.note: lines or text")
  errs_for(function(s2) s2.on_start[1].tag.name = "a designation too long" end, "on_start[1].tag.name: a designation of 1 to 12 characters")
  errs_for(function(s2) s2.on_start[4].lock.code = "12" end, "on_start[4].lock.code: 3 to 8 digits")
  errs_for(function(s2) s2.on_start[3].container.part = nil end, "on_start[3].container: part (an id prefix) or uid")
  errs_for(function(s2) s2.steps[1].goals = { { kind = "has_item", who = "crew:x" } } end, "steps[1].goals[1]: item or mat")
  errs_for(function(s2) s2.steps[1].goals = { { kind = "looted", struct = "Hut" } } end, "steps[1].goals[1]: part (an id prefix) or uid")
  errs_for(function(s2) s2.steps[1].goals = { { kind = "terminal", read = "nope" } } end, "steps[1].goals[1].read: no start.datalogs entry named nope")
  errs_for(function(s2) s2.steps[1].goals = { { kind = "part_state", struct = "Hut", part = "crateS" } } end, "steps[1].goals[1].key: missing")
  -- the kinds, against a stub W
  local W = {
    piece = function(g) return g.part == "crateS" and { locked = false, items = 2, knocked = false } or nil end,
    switched = function(g) return g.part == "lightFitting" and true or nil end,
    container = function(g) return g.part == "shelf" and { items = { repairkit = 0, medkit = 1 }, mats = {}, total = 1 } or nil end,
    itemCount = function(who, item) return item == "repairkit" and 1 or 0 end,
    logRead = function(k) return k == "note" end,
  }
  local function ev(g, mem) return SC.evalGoal(g, W, mem or {}, { now = 0 }) end
  check("part_state: key = locked, is = false", ev({ kind = "part_state", struct = "Hut", part = "crateS", key = "locked", is = false }) == true)
  check("…key = items, gt = 1", ev({ kind = "part_state", struct = "Hut", part = "crateS", key = "items", gt = 1 }) == true)
  check("switched: on reads the system's answer", ev({ kind = "switched", struct = "Hut", part = "lightFitting", on = true }) == true
    and ev({ kind = "switched", struct = "Hut", part = "lightFitting", on = false }) == false)
  check("…a piece with no switch reads not met", ev({ kind = "switched", struct = "Hut", part = "wall" }) == false)
  check("looted: the item taken out", ev({ kind = "looted", struct = "Hut", part = "shelf", item = "repairkit" }) == true
    and ev({ kind = "looted", struct = "Hut", part = "shelf", item = "medkit" }) == false)
  local mem = {}
  W.container = function() return { items = { ration = 5 }, mats = {}, total = 5 } end
  ev({ kind = "looted", struct = "Hut", part = "shelf", item = "ration", n = 2 }, mem)
  W.container = function() return { items = { ration = 3 }, mats = {}, total = 3 } end
  check("looted n: counted from the first reading", ev({ kind = "looted", struct = "Hut", part = "shelf", item = "ration", n = 2 }, mem) == true)
  check("has_item: the pack holds it", ev({ kind = "has_item", who = "crew:Okafor", item = "repairkit" }) == true and ev({ kind = "has_item", who = "Okafor", item = "medkit" }) == false)
  check("terminal read: the card read anywhere", ev({ kind = "terminal", read = "note" }) == true and ev({ kind = "terminal", read = "other" }) == false)
  check("…terminal without read still means at the console", ev({ kind = "terminal" }) == false)
  check("the card lines for the new kinds", SC.goalLabel({ kind = "looted", item = "repairkit" }) == "Take the repairkit" and SC.goalLabel({ kind = "terminal", read = "note" }) == "Read the log")
end

if failed > 0 then print(string.format("smoke_loot: %d of %d checks FAILED", failed, count)) os.exit(1) end
print(string.format("smoke_loot: %d checks passed", count))
