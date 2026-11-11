-- SMOKE: WHAT HOLLIS LEFT and F8 (scenarios2 SC-4): authored ruins and Data
-- Cores (scripts/ruins.lua AUTHORED, scripts/scenario.lua core_read / ruin /
-- coreLines / coreReadable, scenarios/hollis/, tools/gen_hollis_camp.lua).
-- Pure and against stubs.
--
--   * camp.bp.txt is the generator's output; the scenario's decay lists and
--     lots are the generator's uids (core hosts, the block, the door, the
--     breaker named where the scenario says);
--   * the author's decay: exactly the `gone` pieces missing, `broken`
--     windows open frames, `knocked` pieces tipped and repairable, nothing
--     else taken; the dice only rust, grime and topple (deterministic);
--   * the rooms: as built four sealed; as decayed none; the bunks lot back:
--     the bunk room (54 m³) seals and nothing else does;
--   * THE SCENE HALF over stubs with the real structures.lua: stampAuthored
--     makes a ruin's record (ru, back-dated, lights off, found, touched),
--     registers the site (ruins.x) so a fresh ruins script rebuilds it; the
--     claim, the lots' quotes at the author's prices and the restore of one
--     lot only; an authored crate's manifest; the LOG is the author's;
--   * the rulebook: core_read (read, sealed, any, ids/count), ruin (claimed,
--     restored, afford), coreLines (sentences, ≤ 150 characters),
--     coreReadable (power, air, needs, the author's why); the validator
--     refuses a bad start.ruins / start.cores / core beat by field.
--
--   luajit solar/tests/smoke_hollis.lua
local failed, count = 0, 0
local function check(desc, ok, detail)
  count = count + 1
  if not ok then
    failed = failed + 1
    print("✗ " .. desc .. (detail ~= nil and ("   [" .. tostring(detail) .. "]") or ""))
  end
end
local function loadlib(path, extra)
  local e = extra or {}
  if not getmetatable(e) then setmetatable(e, { __index = _G }) end
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, e)
  f()
  return e
end
local function slurp(p) local f = io.open(p, "rb"); if not f then return nil end local t = f:read("*a"); f:close(); return t end

local SCN = loadlib("scenario.lua")
local KIT = loadlib("parts_kit.lua")
local PB = loadlib("parts_base.lua", { findScript = function(k) return k == "parts_kit" and KIT or nil end })
local BPS = loadlib("blueprints.lua")
local RL = loadlib("rooms.lua")
local defs = function(id) return PB.partInfo(id) end
local G = dofile("solar/tools/gen_hollis_camp.lua")
local P, U = G.build()
local D = G.decay(U)
local sc = SCN.load("hollis")
local R0 = sc and sc.start.ruins[1]

-- ── the camp is the generator's, the scenario names its uids ──
do
  local bp = BPS.decode(slurp("solar/scenarios/hollis/camp.bp.txt") or "")
  check("camp.bp.txt is the generator's output", bp ~= nil and BPS.same(bp, { pieces = P }), bp and bp.n)
  for _, p in ipairs(P) do if not defs(p.id) then check("every piece is a part: " .. p.id, false) end end
  check("the scenario loads", sc ~= nil)
  local function same(a, b) if #a ~= #b then return false end for i = 1, #a do if a[i] ~= b[i] then return false end end return true end
  check("its gone list is the generator's", same(R0.gone, D.gone))
  check("its broken and knocked lists are the generator's", same(R0.broken, D.broken) and same(R0.knocked, D.knocked))
  for _, l in ipairs(R0.lots) do check("lot " .. l.id .. " is the generator's", same(l.uids, D.lots[l.id])) end
  local cores = {}
  for _, c in ipairs(sc.start.cores) do cores[c.id] = c.uid end
  check("the cores sit in the mess monitor, the bench monitor, Agnes's bunk and the block",
    cores.c1 == U.core1 and cores.c2 == U.core2 and cores.c3 == U.bunkA and cores.c4 == U.block,
    string.format("%s %s %s %s", tostring(cores.c1), tostring(cores.c2), tostring(cores.c3), tostring(cores.c4)))
  check("the hosts are what they should be", P[U.core1].id == "monitor.steel" and P[U.core2].id == "monitor.steel"
    and P[U.bunkA].id == "bunk.steel" and P[U.block].id == "shieldBlock.concrete")
  check("the door and the breaker the scenario names", P[U.bunkDoor].id == "doorWall.steel" and P[U.breaker].id == "breaker63.steel"
    and sc.on_start[1].state.uid == U.bunkDoor and sc.on_start[2].breaker.uid == U.breaker)
  local sum, allowance = 0, sc.start.funds
  for _, l in ipairs(R0.lots) do sum = sum + l.price end
  local price = {}
  for _, l in ipairs(R0.lots) do price[l.id] = l.price end
  check("the allowance covers the bunk room and one more, not every roof", allowance >= price.bunks and allowance < sum)
  check("…and spent on the wrong roofs first it does not cover the bunk room",
    allowance - price.shed < price.bunks and allowance - price.mess - price.shop < price.bunks)
end

-- ── the author's decay ──
local RU = loadlib("ruins.lua")
local site = RU.authoredSite(R0, P, "Home", { x = 0, y = 600, z = 0 })
local kept, ds = RU.decayAuthored(site.full, site)
do
  check("an authored site: id, its own blueprint, its name", site.id == "scn:Lindqvist Camp" and RU.blueprintOf(site) == site.full and site.authored)
  check("roles: the tower, the roofs, the walls, the lights", site.full[U.tower].rl == "tower" and site.full[U.roofBunk[1]].rl == "roof"
    and site.full[U.bunkDoor].rl == "wall" and site.full[U.lightBunk].rl == "light")
  local have = {}
  for _, e in ipairs(kept) do if e.ri and e.ri > 0 then have[e.ri] = e end end
  local gone = {}
  for _, u in ipairs(R0.gone) do gone[u] = true end
  local okg = true
  for i = 1, #P do if (have[i] == nil) ~= (gone[i] == true) then okg = false end end
  check("exactly the gone pieces are missing", okg and ds.gone == #R0.gone, ds.gone)
  check("the broken windows are open frames (their glass remembered)", have[U.messWinS].id == "openFrame.steel" and have[U.messWinS].o_id == "windowWall.steel")
  local b = have[U.block]
  check("the block is tipped over (70°) and repairable", b.wr ~= nil and math.abs(b.pitch - math.rad(70)) < 1e-6 and b.o_p == 0)
  local k2 = RU.decayAuthored(site.full, site)
  check("deterministic", #k2 == #kept)
  check("the dice rust and grime, nothing structural", ds.rust > 0 and ds.grime > 0 and ds.knocked == 1 and ds.broken == 3)
  local miss = RU.missing(site.full, kept)
  check("missing() is the gone list", #miss == #R0.gone)
  check("a lot's pieces, the rest", #RU.lotMissing(site, R0.lots[1], miss) == 5 and #RU.restMissing(site, miss) == 0)
  local items = RU.crateManifest({ loot = { { uid = 9, items = { repairkit = 2 }, mats = { iron = 3 } } } }, 9, {})
  check("an authored crate holds what its author packed", items.repairkit == 2)
  check("the LOG is the author's", RU.lore(site)[1] == R0.lore[1])
end

-- ── the rooms ──
do
  local function sealed(bp)
    local rec = { id = 7, b = "Home", x = 0, y = 600, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1, bp = bp, st = {} }
    local Rm = RL.solve(rec, defs, os.clock)
    local out = {}
    for _, r in ipairs(Rm.rooms) do if r.sealed then out[#out + 1] = math.floor(r.m3 + 0.5) end end
    return out
  end
  local s0 = sealed(P)
  check("as built: four sealed rooms", #s0 == 4, #s0)
  local bp = {}
  for i, e in ipairs(kept) do local p = {}; for k, v in pairs(e) do p[k] = v end; p.uid = i; bp[i] = p end
  check("as decayed: no room holds", #sealed(bp) == 0)
  local miss = RU.missing(site.full, bp)
  for _, m in ipairs(RU.lotMissing(site, R0.lots[1], miss)) do
    local p = {}; for k, v in pairs(m.piece) do p[k] = v end; p.ri = m.ri; p.uid = #bp + 1; bp[#bp + 1] = p
  end
  local s1 = sealed(bp)
  check("the bunks lot back: the bunk room alone seals (54 m³)", #s1 == 1 and s1[1] >= 50 and s1[1] <= 56, table.concat(s1, ","))
end

-- ── the scene half over stubs ──
do
  local store = {}
  local SAVE = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end }
  local body = { x = 1000, y = -200, z = 50, radius = 600 }
  local space = { body = function() return body end, dominant = function() return "Home" end, bodies = function() return { body } end }
  local ST = loadlib("structures.lua", { save = SAVE })
  local co = { bal = 2400 }
  co.balance = function() return co.bal end
  co.spend = function(n) if n > co.bal then return false end co.bal = co.bal - n; return true end
  local SCRIPTS = { structures = ST, company = co, parts_base = PB }
  local env = { save = SAVE, space = space, time = 0, findScript = function(k) return SCRIPTS[k] end, log = function() end }
  store["system.home"] = { bodies = { { name = "Home", radius = 600 } } }
  store["base.body"] = "Home"
  local S2 = loadlib("ruins.lua", env)
  local g = { body = "Home", x = 0, y = 600, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1 }
  local sid, s = S2.stampAuthored(R0, P, g, 4e8)
  local r = sid and ST.get(sid)
  check("stamped: a ruin's record", r ~= nil and r.ru == "scn:Lindqvist Camp" and r.by == "ruin" and r.n == "Lindqvist Camp")
  check("…back-dated by its age", r and math.abs(r.t - (4e8 - 4015 * 86400)) < 1)
  check("…its strip lights off", r and r.st[tostring(1)] == nil and (function() for _, p in ipairs(r.bp) do if p.rl == "light" and not (r.st[tostring(p.uid)] or {}).off then return false end end return true end)())
  check("…found, touched, its generic core withheld", S2.discovered(s.id) and S2.state(s.id).tc == 1 and S2.state(s.id).core ~= nil)
  check("…a piece's uid is its blueprint line (the scenario's uids hold)", ST.getPart(sid, U.core1) and ST.getPart(sid, U.core1).id == "monitor.steel"
    and ST.getPart(sid, U.bunkA).id == "bunk.steel" and ST.getPart(sid, U.roofBunk[1]) == nil)
  check("…registered (ruins.x) and in the sites list", type(store["ruins.x"]) == "table" and #store["ruins.x"] == 1 and S2.site(s.id) == s)
  check("…the tower held until it is claimed", S2.towerHeld(r) == true)
  local again = S2.stampAuthored(R0, P, g, 4e8)
  check("a second stamp of the same ruin is the same structure", again == sid)
  -- a fresh ruins script (a reload) rebuilds the site from the save
  local S3 = loadlib("ruins.lua", { save = SAVE, space = space, time = 0, findScript = function(k) return SCRIPTS[k] end, log = function() end })
  local s3 = S3.site("scn:Lindqvist Camp")
  check("a reload rebuilds the authored site", s3 ~= nil and s3.authored and #S3.blueprintOf(s3) == #P)
  local q = S2.restoreQuote(s.id, "bunks")
  check("the bunks lot: five pieces at the author's $1,300", q.n == 5 and q.cost == 1300 and q.name == "the bunk room roof")
  check("the whole bill: every gone piece", S2.restoreQuote(s.id).n == #R0.gone)
  check("the rest (no lot names): nothing", S2.restoreQuote(s.id, "rest").n == 0)
  check("a claim needs an Engineer (no role: refused)", S2.claim(s.id, nil) == false)
  check("forced, it is claimed", S2.claim(s.id, nil, true) == true and S2.claimed(s.id))
  local n = S2.restore(s.id, false, "shed")
  check("the shed's roof: nine pieces, $1,700 spent", n == 9 and co.bal == 700)
  local n2, why = S2.restore(s.id, false, "bunks")
  check("…then the bunk room is out of reach of the allowance", n2 == 0 and tostring(why):find("1300") ~= nil, why)
  co.bal = co.bal + 1300
  check("with an advance it goes back on", S2.restore(s.id, false, "bunks") == 5 and S2.restoreQuote(s.id, "bunks").n == 0)
  check("…each restored piece back on its own line", ST.getPart(sid, U.roofBunk[1]) ~= nil and ST.getPart(sid, U.roofBunk[1]).id == "floor.steel")
  check("…and the shop and mess lots are still missing", S2.restoreQuote(s.id, "shop").n == 3 and S2.restoreQuote(s.id, "mess").n == 5)
  local bp = ST.get(sid).bp
  local blk = ST.getPart(sid, U.block)
  check("the block can be righted (repairPiece)", blk and S2.repairPiece(sid, blk.uid) == true and (ST.getPart(sid, blk.uid).pitch or 0) == 0)
end

-- ── flat ground for the camp (ruins.flatSpot over a stub field) ──
do
  local R = 600
  local function V(x, y, z) return { x = x, y = y, z = z } end
  -- a sphere with a 6 m hill whose foot is 30 m round the north pole's +x side
  local function height(ux, uy, uz) local d = math.sqrt((ux * R - 0) ^ 2 + (uz * R) ^ 2); return R + (d < 30 and 6 * (1 - d / 30) or 0) end
  local terrain = { raycast = function(o, dir, len)
    local l = math.sqrt(o.x * o.x + o.y * o.y + o.z * o.z)
    local ux, uy, uz = o.x / l, o.y / l, o.z / l
    local h = height(ux, uy, uz)
    return { pos = V(ux * h, uy * h, uz * h), exact = true }
  end }
  local body = { x = 0, y = 0, z = 0, radius = R }
  local space = { body = function() return body end }
  local S4 = loadlib("ruins.lua", { save = { get = function() return nil end, set = function() end }, space = space, terrain = terrain, vec3 = V,
    time = 0, findScript = function(k) return k == "climate" and { worldOf = function() return { radius = R, relief = 10 } end } or nil end, log = function() end })
  local x, y, z, sp = S4.flatSpot("Home", 0, R + 6, 0, 14, 1.0)
  check("flatSpot: off the hill to flat ground", x ~= nil and sp <= 1.0 and math.sqrt(x * x + z * z) > 30, string.format("%s spread %s", tostring(x), tostring(sp)))
end

-- ── the rulebook ──
do
  local states = { c1 = "read", c2 = "sealed" }
  local W = { coreState = function(id) return states[id] end }
  local function ev(g) local ok, rd = SCN.evalGoal(g, W, {}, { now = 0 }); return ok, rd end
  check("core_read: read", (ev({ kind = "core_read", id = "c1" })))
  check("core_read: sealed is not read", not ev({ kind = "core_read", id = "c2" }))
  check("core_read: sealed = true", (ev({ kind = "core_read", id = "c2", sealed = true })))
  check("core_read: any", (ev({ kind = "core_read", id = "c2", any = true })))
  local ok, rd = ev({ kind = "core_read", ids = { "c1", "c2", "c3" }, count = 2 })
  check("core_read: ids/count", not ok and rd == "1 of 2", rd)
  local RW = { structId = function() return 4 end, ruin = function(sid, lot) return { claimed = true, missing = lot == "bunks" and 5 or 0, cost = 1300, funds = 700 } end }
  local function evr(g) return SCN.evalGoal(g, RW, {}, { now = 0 }) end
  check("ruin: claimed", (evr({ kind = "ruin", struct = "X", claimed = true })))
  check("ruin: a lot not restored", not evr({ kind = "ruin", struct = "X", lot = "bunks", restored = true }))
  local oka, rda = evr({ kind = "ruin", struct = "X", lot = "bunks", afford = false })
  check("ruin: can't afford it", oka, rda)
  local L = SCN.coreLines("One. Two is longer than one? Three! " .. string.rep("word ", 60) .. "end.", 150)
  local okL = #L >= 2
  for _, l in ipairs(L) do if #l > 150 and not l:find("word word") then okL = false end end
  check("coreLines: cut at sentences", okL and L[1]:sub(1, 4) == "One.", L[1])
  check("coreReadable: free", SCN.coreReadable({}, {}) == true)
  local okp, whyp = SCN.coreReadable({ power = true }, { power = false })
  check("coreReadable: power", not okp and whyp:find("powered") ~= nil)
  local oka2, whya = SCN.coreReadable({ air = true, why = "author" }, { air = false })
  check("coreReadable: air, the author's why", not oka2 and whya == "author")
  local oks, whys = SCN.coreReadable({ air = "sealed" }, { air = false })
  check("coreReadable: air = sealed (a sealed room round it)", not oks and whys:find("sealed room") ~= nil, whys)
  check("core 3 opens only in a sealed room (the world's air is thin: never breathable)", sc.start.cores[3].air == "sealed")
  check("coreReadable: needs", SCN.coreReadable({ needs = { kind = "var" } }, { needs = true }) == true and SCN.coreReadable({ needs = { kind = "var" } }, { needs = false, needsWhy = "x" }) == false)
  -- the validator
  local CTX = { partExists = function(id) return PB.partInfo(id) ~= nil end, readFile = function(p) return slurp("solar/" .. p) end,
                decodeBp = function(code) return BPS.decode(code) end }
  local okv, errs = SCN.validate(sc, CTX)
  check("hollis validates", okv, table.concat(errs or {}, " | "))
  local function bad(mut, want)
    local s2 = SCN.load("hollis", true)
    mut(s2)
    local ok2, e2 = SCN.validate(s2, CTX)
    local hit = false
    for _, e in ipairs(e2 or {}) do if e:find(want, 1, true) then hit = true end end
    check("refused: " .. want, not ok2 and hit, table.concat(e2 or {}, " | "))
  end
  bad(function(s2) s2.start.ruins[1].gone[1] = 999 end, "start.ruins[1].gone[1]")
  bad(function(s2) s2.start.ruins[1].bp = "hollis/nope.bp.txt" end, "start.ruins[1].bp")
  bad(function(s2) s2.start.ruins[1].lots[2].id = "bunks" end, "start.ruins[1].lots[2].id")
  bad(function(s2) s2.start.cores[2].pages = {} end, "start.cores[2].pages")
  bad(function(s2) s2.start.cores[1].struct = "Nowhere" end, "start.cores[1].struct")
  bad(function(s2) s2.start.cores[3].who = "nobody" end, "start.cores[3].who")
  bad(function(s2) s2.start.cores[4].open = "nosuch" end, "start.cores[4].open")
  bad(function(s2) s2.steps[2].goals[1].id = "c9" end, "steps[2].goals[1].id")
  bad(function(s2) s2.sequences.after_c4[1] = { core = { read = "c9" } } end, "core.read")
end

print(string.format("smoke_hollis: %d checks, %d failed", count, failed))
if failed > 0 then os.exit(1) end
