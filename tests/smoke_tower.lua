-- SMOKE: the Base Station Tower and the bases (deep-space addendum step 7:
-- M1–M3, M5, M8–M9; docs/base-building.md §11), against a stub save, the real
-- parts_base / bases / structures / base_tower / electronics / research /
-- items, and stand-ins for the scene's other scripts.
--
--   * parts_base: the tower (a script, its mast, draw, spacing and radius),
--     the Solar Array and the Isotope Skid (their power), their prefabs on
--     disk with collider boxes, the skid behind the Isotope Cell's research;
--   * bases: founding (ids from bases.seq, "Outpost <n>"), names (trimmed,
--     clipped, an empty one refused, two bases never share one), the ground
--     distance, towers 1 km apart (the Tracking Station too), which base a
--     point belongs to (150 m), down and up again, the save round trip,
--     plain values within the save's depth;
--   * base_tower: a tower part founds a base and keeps its id on the part;
--     the name field opens for the one the player just placed; taken down,
--     its base goes down under its name, and put back (an undo, or a redo's
--     copy without the id) it stands again as the same base;
--   * power from the tower's own structure: none (a mast), an Isotope Skid
--     (2 EC/s: a ground station), a Solar Array in the sun and at night;
--   * the relay tiers (Q20): a mast is a beacon-class relay (1500), a powered
--     tower on the home world a second home root at the station's 4.0e5, off
--     the home world a 4.0e5 relay; with the real solveNetwork, a far-side
--     probe has no path home past the horizon, has one through a powered
--     tower, none through a lone mast, and one through a mast chained to the
--     station by beacons;
--   * M4's row: the share of a smooth world's ground that hears the station,
--     and the station with a powered far-side tower;
--   * M8: dig guards under every structure, synced as parts come and go;
--   * M3: the Build Kit is granted, not bought (the 10 % goal's grant list),
--     the Depot stocks it only once it is, a save past the goal has it;
--   * the cost: update() with nothing changed looks nothing up.
--
--   luajit solar/tests/smoke_tower.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, e) return math.abs(a - b) <= (e or 1e-6) end

local LOOKUPS = { n = 0 }
local function env(store, scripts, extra)
  local E = setmetatable({
    time = 5.0,
    save = {
      get = function(k) return store[k] end,
      set = function(k, v) store[k] = v end,
      delete = function(k) local had = store[k] ~= nil; store[k] = nil; return had end,
    },
    findScript = function(k) LOOKUPS.n = LOOKUPS.n + 1; return scripts[k] end,
    findScripts = function() return {} end,
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
local function depth(v)
  if type(v) ~= "table" then return 0 end
  local d = 0
  for _, x in pairs(v) do d = math.max(d, depth(x)) end
  return d + 1
end
local function plain(v, seen)
  local t = type(v)
  if t == "number" or t == "string" or t == "boolean" or t == "nil" then return true end
  if t ~= "table" then return false end
  seen = seen or {}
  if seen[v] then return false end
  seen[v] = true
  for k, x in pairs(v) do if not plain(k, seen) or not plain(x, seen) then return false end end
  return true
end
local function slurp(p) local f = io.open(p); if not f then return nil end local s = f:read("*a"); f:close(); return s end

-- ── parts_base ──────────────────────────────────────────────────────────────
local PB = load_script("parts_base.lua", env({}, {}))
local T = PB.partInfo("tower")
check(T and T.script == "base_tower" and T.onDeck and T.fieldOnly and T.tower and T.tower.draw == 2.0 and T.tower.spacing == 1000
  and T.tower.radius == 150 and T.tower.mast > 10, "the tower: a BASE part with a script; 2 EC/s, 1 km apart, a 150 m base")
check(near(T.mass, 1.5) and T.cost == 4000, "1.5 t, $4,000 (the addendum's)")
local ron = slurp("solar/prefabs/BaseTower.prefab.ron") or ""
check(ron:find("models/base/parts/tower.glb", 1, true) and ron:find('name: "Wall 1"', 1, true) and ron:find('name: "Wall 4"', 1, true),
  "its prefab: the 1:1 model and its collider boxes (frame, mast, cabinet, platform)")
local SA, SK = PB.partInfo("solarArray"), PB.partInfo("isotopeSkid")
check(SA and SA.power and SA.power.kind == "solar" and SA.power.gen > 0 and SA.onDeck, "the Solar Array: a solar source that stands on a deck")
check(SK and SK.power and SK.power.kind == "rtg" and near(SK.power.gen, 2.0) and SK.onDeck, "the Isotope Skid: four cells, 2 EC/s, always")
check(slurp("solar/prefabs/BaseSolar.prefab.ron") and slurp("solar/prefabs/BaseIsotope.prefab.ron"), "...their prefabs on disk")
check(slurp("solar/prefabs/BaseNamePrompt.prefab.ron") ~= nil, "the name field's UI node is a prefab")

-- ── bases (pure) ────────────────────────────────────────────────────────────
local store = {}
local B = load_script("bases.lua", env(store, {}))
local R = 800
check(B.defaultName() == "Outpost 1", "a new base's name: Outpost 1")
local id1 = B.found("Vever", 0, R, 0, 7, 1, { t = 100, d = "Day 3, Y1", by = 2 })
check(id1 == 1 and store["bases.seq"] == 1 and store["bases.list"][1] == 1 and B.get(1).n == "Outpost 1", "founded: id 1 from bases.seq, Outpost 1")
check(B.defaultName() == "Outpost 2", "...and the next would be Outpost 2")
check(plain(store["bases.1"]) and depth(store["bases.1"]) <= 1, "the record is plain values, one table deep")
check(B.cleanName("  Far   Side ") == "Far Side", "names are trimmed and their spaces folded")
check(B.cleanName("") == nil and B.cleanName("   ") == nil, "an empty name is refused")
check(#B.cleanName(string.rep("x", 50)) == B.NAME_MAX, "a long name is clipped to " .. B.NAME_MAX)
local ok, nm = B.rename(1, " Far Side ")
check(ok and nm == "Far Side" and store["bases.1"].n == "Far Side", "renamed, and saved")
local id2 = B.found("Vever", 0, -R, 0, 9, 1)
local ok2, why2 = B.rename(id2, "Far Side")
check(not ok2 and tostring(why2):find("another base", 1, true), "two bases never share a name: " .. tostring(why2))
check(near(B.groundDist(R, 0, R, 0, R, 0, 0), math.pi / 2 * R, 1e-6), "groundDist: a quarter of the way round is πR/2")
check(near(B.groundDist(nil, 0, 0, 0, 3, 4, 0), 5), "...no radius: the straight line")
-- spacing: the home base's station, and the other towers
local home = { b = "Vever", x = R, y = 0, z = 0 }
local a = 0.9 * 1000 / R
local w = B.spacingWhy("Vever", R * math.cos(a), R * math.sin(a), 0, R, home)
check(w and w:find("Tracking Station", 1, true), "a tower 900 m from the spaceport's station is refused: " .. tostring(w))
local a2 = 1.2 * 1000 / R
check(B.spacingWhy("Vever", R * math.cos(a2), 0, R * math.sin(a2), R, home) == nil
  or B.spacingWhy("Vever", R * math.cos(a2), 0, R * math.sin(a2), R, home):find("Far Side") == nil,
  "...1.2 km from it the station doesn't stand in the way")
local w2 = B.spacingWhy("Vever", 0, R * math.cos(0.5 / R * 1000), R * math.sin(0.5 / R * 1000), R, nil)
check(w2 and w2:find("Far Side", 1, true), "a tower 500 m from Far Side's is refused: " .. tostring(w2))
check(B.spacingWhy("Nami", 0, R, 0, R, home) == nil, "...on another world nothing is near")
local br, bd = B.baseAt("Vever", 0, R * math.cos(0.1), R * math.sin(0.1), R)
check(br and br.id == 1 and near(bd, 80, 1e-6), "a structure 80 m off belongs to Far Side")
check(B.baseAt("Vever", 0, R * math.cos(0.2), R * math.sin(0.2), R) == nil, "...one 160 m off to no base")
B.setDown(1, true)
check(#B.list() == 1 and #B.list(true) == 2 and B.spacingWhy("Vever", 0, R * math.cos(0.5 / R * 1000), R * math.sin(0.5 / R * 1000), R, nil) == nil,
  "a base whose tower is down leaves the list and the spacing rule")
B.setDown(1, false)
local B2 = load_script("bases.lua", env(store, {}))
check(B2.count() == 2 and B2.get(1).n == "Far Side" and B2.get(1).sid == 7 and B2.get(2).b == "Vever", "a reload reads the same bases")
B2.forget(2)
check(store["bases.2"] == nil and #store["bases.list"] == 1, "forget() drops a record and its key")

-- ── base_tower: founding, names, down and up again ──────────────────────────
local s = { ["base.body"] = "Vever", ["agency.clock"] = 500 }
local scripts = {}
local bodies = { { name = "Vever", x = 1000, y = 0, z = 0, radius = R, mu = 1e5 }, { name = "Sun", x = -1e9, y = 0, z = 0, radius = 1e6, mu = 1e12 } }
local SPACE = {
  body = function(n) for _, b in ipairs(bodies) do if b.name == n then return b end end return nil end,
  bodies = function() return bodies end,
}
local E = load_script("electronics.lua", env({}, {}))
scripts.electronics = E
scripts.parts_base = PB
scripts.deployables = { agencyClock = function() return 500 end, dateOf = function() return "Day 9, Y1" end }
scripts.bases = load_script("bases.lua", env(s, scripts))
local ST = load_script("structures.lua", env(s, scripts, { space = SPACE }))
scripts.structures = ST
local guards = {}
scripts.base_facilities = { baseBody = "Vever", setGuards = function(owner, body, list) guards[owner] = list and #list > 0 and { body = body, list = list } or nil end }
local lastPlace = nil
scripts.field_builder = setmetatable({}, { __index = function(_, k) if k == "lastPlace" then return lastPlace end end })
local BT = load_script("base_tower.lua", env(s, scripts, { space = SPACE }))
scripts.base_tower = BT
BT.start({ id = 1 })
-- (step 8: the tower's power is its base grid's)
local BG = load_script("base_grid.lua", env(s, scripts, { space = SPACE }))
scripts.base_grid = BG
BG.start({ id = 2 })
local BS = scripts.bases
local up, fwd = { x = 0, y = 0, z = 1 }, { x = 1, y = 0, z = 0 }   -- the far side: Vever's +Z pole
local rec = ST.newRecord(nil, "Vever", 0, 0, R, up, fwd, "padPlate", { by = 2 })
local sid = ST.add(rec)
local tuid = ST.addPart(sid, { id = "tower", x = 0, y = 0.2, z = 0, paid = { by = 2, total = 4450 } })
lastPlace = { sid = sid, uid = tuid }
BT.update({}, 0.016)
local tp = ST.getPart(sid, tuid)
local b1 = tp and tp.base and BS.get(tp.base)
check(b1 and b1.sid == sid and b1.uid == tuid and b1.n == "Outpost 1" and b1.d == "Day 9, Y1" and b1.by == 2,
  "a tower part founds a base: its id on the part, Outpost 1, dated, by its builder")
check(s["struct." .. sid].bp[2].base == b1.id, "...the id is kept in the structure's save")
check(near(b1.z, R + 0.2, 1e-9) and near(b1.x, 0, 1e-9), "the base's point is the tower's ground point (on the plate's deck), body-relative")
check(BT.prompting() and BT.prompt.bid == b1.id, "the name field opens for the tower just placed")
local okc = BT.commitName("  Far Side ")
check(okc and BS.get(b1.id).n == "Far Side" and not BT.prompting(), "Found it: the base is called Far Side, the field closes")
local bid = b1.id
-- taken down (a deconstruct or the undo), and put back
local saved_part = {}
for k, v in pairs(tp) do saved_part[k] = v end
ST.removeParts(sid, { tuid })
BT.update({}, 0.016)
check(BS.get(bid).down == true and #BS.list() == 0 and BT.towerOf(bid) == nil, "the tower taken down: its base goes down (kept, under its name)")
ST.addPart(sid, saved_part)
BT.update({}, 0.016)
check(not BS.get(bid).down and #BS.list() == 1 and BS.get(bid).n == "Far Side" and not BT.prompting(),
  "put back (an undo): the same base stands again, no name field")
-- a redo's copy taken before the base was founded (no `base` on it)
ST.removeParts(sid, { tuid })
BT.update({}, 0.016)
saved_part.base = nil
ST.addPart(sid, saved_part)
BT.update({}, 0.016)
check(not BS.get(bid).down and #BS.list(true) == 1 and ST.getPart(sid, tuid).base == bid,
  "a placement's redo (a copy with no base id): the base standing down there is its own")

-- ── power from its base grid (step 8: base_grid.lua) ────────────────────────
local pw = BT.power(bid, nil, true)
check(pw.supply == 0 and pw.need == 2.0 and not pw.powered, "a tower alone: 0 / 2 EC/s, a mast")
local by = {}
for _, b in ipairs(bodies) do by[b.name] = b end
local nodes = BT.commsNodes(by, bodies, E)
local n1 = nodes[1]
check(#nodes == 1 and n1.id == "t:" .. bid and not n1.home and n1.beacon and near(n1.any, E.COMMS.beacon.power) and near(n1.relay, E.COMMS.beacon.power),
  "unpowered: a beacon-class relay (" .. tostring(n1 and n1.relay) .. ")")
check(n1.frame == "Vever" and near(n1.rz, R + 0.2 + T.tower.mast, 1e-6) and near(n1.z, n1.rz, 1e-6) and near(n1.x, 1000, 1e-6) and n1.agl == T.tower.mast,
  "its antenna 11.6 m up the mast, pinned to its world (placed against the solve's read)")
ST.addPart(sid, { id = "isotopeSkid", x = 0, y = 0.2, z = 1.4 })   -- (a second plate would carry it; the record is what counts)
BT.update({}, 0.016)
pw = BT.power(bid, nil, true)
check(near(pw.supply, 2.0) and pw.powered and #pw.src == 1 and pw.src[1].label == "Isotope Skid", "an Isotope Skid on its grid: 2 / 2 EC/s, a ground station")
local nodes2 = BT.commsNodes(by, bodies, E)
check(nodes2[1].home == true and near(nodes2[1].power, E.COMMS.station) and nodes2[1].tower, "powered on the home world: a second home root at 4.0e5")
s["base.body"] = "Elsewhere"
BT.power(bid, nil, true)
local nodes3 = BT.commsNodes(by, bodies, E)
check(not nodes3[1].home and near(nodes3[1].relay, E.COMMS.station) and nodes3[1].landed, "off the home world: a 4.0e5 relay, home only through a path")
s["base.body"] = "Vever"
-- solar: an array's light slot by slot (base_grid.slotLight), against a
-- stand-in for the sun's answer (electronics.solarOutput) and the real one
local sun_says = { o = 3.0, blk = nil }
local Esun = setmetatable({ solarOutput = function(gen) return sun_says.blk and 0 or gen, 1, 1, sun_says.blk end,
  sunOf = function() return bodies[2], 1 end }, { __index = E })
local srec = ST.newRecord(nil, "Vever", R, 0, 0, { x = 1, y = 0, z = 0 }, { x = 0, y = 0, z = 1 }, "solarArray")
local arr = BG.gridModel({ bases = {}, parts = { { rec = srec, p = srec.bp[1], def = SA } } }, ST.partPose, 2.0).arrays[1]
local ctx = { E = Esun, body = bodies[1], sun = bodies[2], ref = 1, L = 10, N = 4, lead = 0 }
local lit = BG.slotLight(arr, ctx)
check(near(lit[1], 3.0) and near(lit[4], 3.0), "a Solar Array in the sun: 3 EC/s in every slot")
sun_says.blk = "Vever"
lit = BG.slotLight(arr, ctx)
check(lit[1] == 0 and lit[3] == 0, "...at night: nothing")
ctx.E = E
local lit3 = BG.slotLight(arr, ctx)
check(type(lit3[1]) == "number" and lit3[1] >= 0 and lit3[1] <= 3.0 * 4, "the real solarOutput answers for an array on the ground (" .. string.format("%.2f", lit3[1]) .. ")")

-- ── the network (the real solveNetwork) ─────────────────────────────────────
local W = { { name = "Vever", x = 0, y = 0, z = 0, radius = R } }
local function solve(list) return E.solveNetwork(list, W) end
local station = { id = "home", name = "Ground station", x = 0, y = R + 6, z = 0, home = true, power = E.COMMS.station }
local probe = { id = "p", name = "Probe", x = 30, y = -R - 1, z = 0, any = 100, relay = 0 }
local st = solve({ station, probe })
check(not st.p.connected, "a probe on the far side has no path home past the horizon (" .. tostring(st.p.why) .. ")")
local mastH = T.tower.mast
local towerP = { id = "t:1", name = "Far Side", x = 0, y = -R - mastH, z = 0, home = true, power = E.COMMS.station, agl = mastH, tower = true }
st = solve({ station, probe, towerP })
check(st.p.connected and st.p.path[#st.p.path] == "t:1", "...through a powered tower it is home: a second root")
local towerM = E.beaconNode("t:1", "Far Side", 0, -R - mastH, 0); towerM.agl = mastH
st = solve({ station, probe, towerM })
check(st.p.connected == false and st["t:1"].connected == false, "...a lone mast is only a relay: no path for either")
-- a mast chained to the station by beacons round the world (each sees the last)
local chain = { station, probe, towerM }
local nb = 10
for i = 1, nb do
  local th = math.pi * i / (nb + 1)
  chain[#chain + 1] = E.beaconNode("b:" .. i, "Relay " .. i, (R + 4) * math.sin(th), (R + 4) * math.cos(th), 0)
end
st = solve(chain)
check(st["t:1"].connected and st.p.connected and (st.p.hops or 0) >= 2, string.format("...chained to the station by %d beacons the mast relays the probe home (%d hops)", nb, st.p.hops or -1))
-- the nearest home root says why (noLinkWhy)
local far = { id = "q", name = "Lost", x = 0, y = 0, z = -R - 1, any = 100, relay = 0 }
st = solve({ station, towerP, far })
check(st.q.connected or tostring(st.q.why):find("horizon", 1, true) or tostring(st.q.why):find("range", 1, true) or tostring(st.q.why):find("blocked", 1, true),
  "a craft out of both roots' sight says why: " .. tostring(st.q.why))

-- ── M4: two stations on a smooth world ──────────────────────────────────────
local grid = E.surfaceGrid(E.COMMS.coverSamples)
local pts = {}
for i, u in ipairs(grid) do pts[i] = { u[1] * (R + E.COMMS.coverLift), u[2] * (R + E.COMMS.coverLift), u[3] * (R + E.COMMS.coverLift) } end
local st_only = E.coverageFraction(pts, { { x = 0, y = R + 6, z = 0, power = E.COMMS.station, agl = 6 } }, W, E.COMMS.coverRx)
local both = E.coverageFraction(pts, { { x = 0, y = R + 6, z = 0, power = E.COMMS.station, agl = 6 },
  { x = 0, y = -R - mastH, z = 0, power = E.COMMS.station, agl = mastH } }, W, E.COMMS.coverRx)
local mast_only = E.coverageFraction(pts, { { x = 0, y = R + 6, z = 0, power = E.COMMS.station, agl = 6 },
  { x = 0, y = -R - mastH, z = 0, power = E.COMMS.beacon.power, agl = mastH } }, W, E.COMMS.coverRx)
print(string.format("smoke_tower: M4 smooth world r %d: the station alone %.1f %%, with a far-side powered tower %.1f %%, (a linked mast there %.1f %%)",
  R, st_only * 100, both * 100, mast_only * 100))
check(both >= 1.8 * st_only and both > st_only, string.format("M4: a powered far-side tower roughly doubles the ground covered (%.0f %% → %.0f %%)", st_only * 100, both * 100))
check(both >= mast_only, "...and covers at least what a mast there would")

-- ── M8: dig guards under every structure ────────────────────────────────────
check(guards["struct:" .. sid] and #guards["struct:" .. sid].list == #ST.get(sid).bp and guards["struct:" .. sid].body == "Vever",
  "a dig guard under every part of a structure")
local g1 = guards["struct:" .. sid].list[2]
check(g1 and g1.lo < -1.9 and g1.hi > 13 and g1.ht > T.half.x and tostring(g1.why):find("foundations", 1, true),
  "...the tower's from under the ground to over its mast, wider than its footprint")
ST.remove(sid)
BT.update({}, 0.016)
check(guards["struct:" .. sid] == nil and BS.get(bid).down, "the structure gone: its guards and its base go with it")

-- ── the cost: nothing changed, nothing looked at ────────────────────────────
BT.update({}, 0.016)
local n0 = LOOKUPS.n
for _ = 1, 100 do BT.update({}, 0.016) end
check(LOOKUPS.n - n0 <= 2, "an idle frame looks nothing up (" .. tostring(LOOKUPS.n - n0) .. " lookups in 100 frames)")

-- ── M3: the Build Kit is the 10 % unlock ────────────────────────────────────
local rs_store = {}
local RS = load_script("research.lua", env(rs_store, {}))
check(not RS.isUnlocked("buildkit") and RS.blockedBy("buildkit"):find("10%", 1, true), "the Build Kit is locked: " .. tostring(RS.blockedBy("buildkit")))
local uok = RS.unlock("buildkit")
check(not uok and not RS.isUnlocked("buildkit"), "...and can't be bought")
check(RS.grant("buildkit", "Relay Network") and RS.isUnlocked("buildkit"), "...a grant opens it")
local rs2 = {}
local RS2 = load_script("research.lua", env(rs2, {}))
rs2["prog.perm"] = { relay_net = { true } }
check(RS2.isUnlocked("buildkit"), "a save already past the 10 % goal has it")
check(not RS2.isUnlocked("isotopeSkid") and RS2.labelOf("isotopeSkid") == "Isotope Cell", "the Isotope Skid is behind the Isotope Cell's research")
RS2.grant("rtg")
check(RS2.isUnlocked("isotopeSkid"), "...open with it")
-- the Depot's counter
local I_store = {}
local IT_scripts = { research = load_script("research.lua", env(I_store, {})) }
local IT = load_script("items.lua", env({}, IT_scripts))
local function on_counter() for _, g in ipairs(IT.shopList()) do if g.id == "buildkit" then return true end end return false end
check(not on_counter(), "the Depot doesn't stock the Build Kit before the unlock")
IT_scripts.research.grant("buildkit")
check(on_counter(), "...and does after it")
-- the goal's grant list
local MI = loadfile("solar/scripts/missions.lua")
local menv = env({}, {})
setfenv(MI, menv)
local okm = pcall(MI)
local goal = nil
for _, m in ipairs(okm and menv.PROGRAMME or {}) do
  if m.id == "relay_net" then goal = m.goals[1] end
end
check(goal and type(goal.grant) == "table" and goal.grant[1] == "probe" and goal.grant[2] == "buildkit" and goal.frac == 0.10 and goal.ops,
  "the Relay Network's 10 % goal grants { probe, buildkit } and has Ops' line")

-- the station's FLEET column: a BASES group (fleet_view)
local FV = load_script("fleet_view.lua", env({}, {}))
check(FV.groupOf({ kind = "outpost" }) == "BASES" and FV.situation({ kind = "outpost", tier = "ground station" }) == "base · ground station"
  and FV.GLYPHS.outpost ~= nil, "the station lists a base under BASES: \"base · ground station\"")
local gi = {}
for i, g in ipairs(FV.GROUPS) do gi[g] = i end
check(gi.BASES and gi.STRUCTURES and gi.BASES < gi.STRUCTURES, "...the BASES group before STRUCTURES")

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL: " .. f) end
  print(string.format("smoke_tower: %d passed, %d FAILED", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_tower: %d passed", passed))
