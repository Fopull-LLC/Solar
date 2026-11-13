-- smoke_wired_grid: THE WIRING RULE (W2, playtest 11-12b; base_grid.lua,
-- base_cable.lua). "Everything on a grid must be connected to a power source
-- with power cables. Nothing should be part of the grid automatically."
--
--   • what is equipment (its own terminal) and what is a building's circuit
--   • nothing shares power by standing close: a tower, an array and a bank
--     40 m apart are three dead islands until cables join them
--   • two parts of ONE structure can be cabled (an array to the bank beside
--     it); two pieces of one building's circuit cannot (they are joined)
--   • a building's lights come on when a cable lands on any of its pieces;
--     a machine inside wants its own lead to the building
--   • why a dead part is dead (powerWhy), and what it is wired to (wiring)
--   • a save from before the rule: every structure marked `aw` keeps the old
--     grid; a structure built afterwards wants its cables; `rewire` drops
--     the mark
--
--   luajit solar/tests/smoke_wired_grid.lua       (from the Floptle repo root)
local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function env(store, scripts, extra)
  local E = setmetatable({
    time = 5.0,
    save = {
      get = function(k) return store[k] end,
      set = function(k, v) store[k] = v end,
      delete = function(k) local had = store[k] ~= nil; store[k] = nil; return had end,
    },
    findScript = function(k) return scripts[k] end,
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

local MU, RS = 9.75e10, 2.0e5
local V = math.sqrt(MU / RS)
local R = 800
local bodies = {
  { name = "Sun", x = 0, y = 0, z = 0, vx = 0, vy = 0, vz = 0, radius = 1.0e4, mu = MU, soi = -1, star = true },
  { name = "Vever", x = RS, y = 0, z = 0, vx = 0, vy = V, vz = 0, radius = R, mu = 1e5, soi = 5e4 },
}
local SPACE = {
  body = function(n) for _, b in ipairs(bodies) do if b.name == n then return b end end return nil end,
  bodies = function() return bodies end,
  dominant = function() return "Vever" end,
}

-- one world of scripts on store `s`
local function world(s)
  local clock = { a = 1000 }
  local scripts = {}
  local PB = load_script("parts_base.lua", env({}, {}))
  local PK = load_script("parts_kit.lua", env({}, {}))
  local EXTRA = {
    o2gen = { label = "O2 Generator", h = 1, rx = 0.4, rz = 0.4, half = { x = 0.4, y = 0.5, z = 0.4 }, snap = "prop", power = { kind = "load", use = 1.5 } },
    lamp = { label = "Strip Light", h = 0.1, rx = 0.3, rz = 0.1, half = { x = 0.3, y = 0.05, z = 0.1 }, snap = "mount", power = { kind = "load", use = 0.03 } },
    wall = { label = "Wall", h = 2.2, rx = 1, rz = 0.1, half = { x = 1, y = 1.1, z = 0.1 }, snap = "wall" },
    lockWall = { label = "Airlock Wall", h = 2.2, rx = 1, rz = 0.1, half = { x = 1, y = 1.1, z = 0.1 }, snap = "wall", power = { kind = "aux", use = 2.5 } },
  }
  local function defs(id) return EXTRA[id] or PB.partInfo(id) or PK.partInfo(id) end
  scripts.parts_base = { partInfo = defs }
  scripts.parts_kit = PK
  scripts.electronics = load_script("electronics.lua", env({}, {}))
  scripts.deployables = { agencyClock = function() return clock.a end, dateOf = function() return "Day 9, Y1" end }
  scripts.base_economy = load_script("base_economy.lua", env(s, scripts))
  local money = { bal = 1e7 }
  scripts.company = { spend = function(v) if v > money.bal then return false end money.bal = money.bal - v; return true end,
                      refund = function(v) money.bal = money.bal + v end, earn = function(v) money.bal = money.bal + v end,
                      afford = function(v) return v <= money.bal end }
  scripts.crew = { activeId = function() return 2 end, credit = function() end, roster = function() return {} end,
                   hasRole = function() return true end }
  scripts.field_builder = { pushHistory = function() end }
  local terrain = { query = function(x, y, z) local b = bodies[2]; return math.sqrt((x - b.x) ^ 2 + (y - b.y) ^ 2 + (z - b.z) ^ 2) - R end }
  local X = { space = SPACE, terrain = terrain }
  scripts.bases = load_script("bases.lua", env(s, scripts))
  local ST = load_script("structures.lua", env(s, scripts, X))
  scripts.structures = ST
  local CB = load_script("base_cable.lua", env(s, scripts, X))
  scripts.base_cable = CB
  scripts.base_power = load_script("base_power.lua", env(s, scripts, X))
  local BG = load_script("base_grid.lua", env(s, scripts, X))
  scripts.base_grid = BG
  scripts.base_facilities = { setGuards = function() end }
  local BT = load_script("base_tower.lua", env(s, scripts, X))
  scripts.base_tower = BT
  BT.start({ id = 1 }); BG.start({ id = 2 }); CB.start({ id = 3 })
  local W = { ST = ST, CB = CB, BG = BG, BT = BT, defs = defs, scripts = scripts, clock = clock, money = money }
  function W.struct(x, y, z, part, opts)
    local l = math.sqrt(x * x + y * y + z * z)
    local U = { x = x / l, y = y / l, z = z / l }
    local F = { x = -U.y, y = U.x, z = 0 }
    return ST.add(ST.newRecord(nil, "Vever", x, y, z, U, F, part, opts))
  end
  function W.at(d) local th = d / R return -R * math.cos(th), R * math.sin(th), 0 end
  function W.tick() BT.update({}, 0.016); BG.update({}, 0.016); BG.rebuildNow() end
  return W
end

-- ── 1. what is equipment ────────────────────────────────────────────────────
local s1 = { ["base.body"] = "Vever" }
local W = world(s1)
local BG, ST, CB = W.BG, W.ST, W.CB
check(BG.WIRED == true, "the wiring rule is on")
local function eq(id) return BG.isEquipment(W.defs(id)) end
check(eq("solarArray") and eq("isotopeSkid") and eq("batteryBank") and eq("tower"), "sources, the Battery Bank and the tower each have their own terminal")
check(eq("o2gen") and not eq("lamp") and not eq("wall"), "a 1.5 kW machine is equipment; a strip light and a wall are the building's")
check(not eq("lockWall"), "a structural piece with a pump (the Airlock Wall) is on the building's circuit")
check(not eq("padPlate") and not eq("shieldWall"), "a plate and a shield wall are not electrical")

-- ── 2. nothing shares power by standing close ───────────────────────────────
local tsid = W.struct(-R, 0, 0, "tower")
W.BT.update({}, 0.016)
local bid = ST.getPart(tsid, 1).base
check(bid ~= nil, "the tower founds its base")
local ax, ay, az = W.at(40)
local s_arr = W.struct(ax, ay, az, "solarArray")
local u_bat = ST.addPart(s_arr, { id = "batteryBank", x = 4, y = 0, z = 0 })   -- the bank beside it, ONE structure
W.tick()
local tp = BG.towerPower(bid)
check(tp.powered == false and (tp.sources or 0) == 0, "an array and a bank 40 m from the tower: the tower has no power (no ring any more)")
local ga, gb, gt = BG.gridOfStruct(s_arr, 1), BG.gridOfStruct(s_arr, u_bat), BG.gridOfStruct(tsid, 1)
check(ga and gb and gt and ga ~= gb and ga ~= gt and gb ~= gt, "the array, the bank beside it and the tower are three islands")
local wa = BG.wiring(s_arr, 1)
check(wa.equipment and wa.cables == 0 and not wa.legacy, "the array reads NOT WIRED")
check(BG.nodeKeyOf(s_arr, 1) ~= BG.nodeKeyOf(s_arr, u_bat), "two terminals in one structure")

-- ── 3. the cables ───────────────────────────────────────────────────────────
local v = CB.validity({ sid = s_arr, uid = 1 }, { rec = ST.get(s_arr), part = ST.getPart(s_arr, u_bat) }, "Vever", "lv16")
check(v.bad == nil, "an array may be cabled to the bank beside it (one structure, two terminals): " .. tostring(v.bad))
local c1, why1 = CB.lay({ sid = s_arr, uid = 1 }, { sid = s_arr, uid = u_bat })
check(c1 ~= nil, "...and the cable lays: " .. tostring(why1))
W.tick()
check(BG.gridOfStruct(s_arr, 1) == BG.gridOfStruct(s_arr, u_bat), "array and bank: one grid")
check(BG.towerPower(bid).powered == false, "...the tower still dark")
local c2, why2 = CB.lay({ sid = s_arr, uid = u_bat }, { sid = tsid, uid = 1 })
check(c2 ~= nil, "a 40 m cable from the bank to the tower: " .. tostring(why2))
W.tick()
tp = BG.towerPower(bid)
check(tp.powered == true and tp.sources == 1 and tp.cap == 4000, string.format("the tower is served: %d source, %d EC of storage", tp.sources or -1, tp.cap or -1))
local wt = BG.wiring(tsid, 1)
check(wt.cables == 1 and wt.live and wt.to and wt.to[1].sid == s_arr and wt.to[1].uid == u_bat, "the tower reads: wired to the Battery Bank, live")
v = CB.validity({ sid = s_arr, uid = 1 }, { rec = ST.get(tsid), part = ST.getPart(tsid, 1) }, "Vever", "lv16")
check(v.bad and v.bad:find("already on one grid"), "a second path with no network gear is still refused: " .. tostring(v.bad))

-- ── 4. a building ───────────────────────────────────────────────────────────
local hx, hy, hz = W.at(70)
local hab = W.struct(hx, hy, hz, "wall")
local u_w2 = ST.addPart(hab, { id = "wall", x = 2, y = 0, z = 0 })
local u_l1 = ST.addPart(hab, { id = "lamp", x = 0, y = 2, z = 0 })
local u_l2 = ST.addPart(hab, { id = "lamp", x = 2, y = 2, z = 0 })
local u_o2 = ST.addPart(hab, { id = "o2gen", x = 1, y = 0, z = 1 })
local u_lw = ST.addPart(hab, { id = "lockWall", x = 4, y = 0, z = 0 })
W.tick()
check(BG.nodeKeyOf(hab, u_l1) == BG.nodeKeyOf(hab, u_w2) and BG.nodeKeyOf(hab, u_l1) == BG.nodeKeyOf(hab, u_lw),
  "the walls, the lights and the Airlock Wall are one circuit")
check(BG.nodeKeyOf(hab, u_o2) ~= BG.nodeKeyOf(hab, u_l1), "the O2 generator has its own terminal")
check(BG.partServed(hab, u_l1) ~= true, "the lights are dark: no cable reaches the building")
local pw = BG.powerWhy(hab, u_l1)
check(pw and pw:find("no cable reaches this building"), "...and say why: " .. tostring(pw))
pw = BG.powerWhy(hab, u_o2)
check(pw and pw:find("NOT WIRED"), "the machine says NOT WIRED: " .. tostring(pw))
v = CB.validity({ sid = hab, uid = u_l1 }, { rec = ST.get(hab), part = ST.getPart(hab, u_w2) }, "Vever", "lv16")
check(v.bad and v.bad:find("same circuit"), "two pieces of one building's circuit can't be cabled: " .. tostring(v.bad))
local c3, why3 = CB.lay({ sid = s_arr, uid = u_bat }, { sid = hab, uid = u_w2 })
check(c3 ~= nil, "a cable from the bank to a wall of the building: " .. tostring(why3))
W.tick()
check(BG.partServed(hab, u_l1) == true and BG.partServed(hab, u_l2) == true, "both lights are served")
check(BG.powerWhy(hab, u_l1) == nil, "...with nothing to complain of")
check(BG.partServed(hab, u_o2) ~= true, "the O2 generator beside them is still dead")
local c4, why4 = CB.lay({ sid = hab, uid = u_o2 }, { sid = hab, uid = u_w2 })
check(c4 ~= nil, "a lead from the machine to the wall: " .. tostring(why4))
W.tick()
check(BG.partServed(hab, u_o2) == true and BG.powerWhy(hab, u_o2) == nil, "...and it runs")
local g = BG.gridOfStruct(hab)
local M = BG.model(g.id)
check(g == BG.gridOfStruct(tsid, 1) and #g.nodes >= 5 and math.abs(M.need - (W.BT.drawOf and W.BT.drawOf(bid) or 2.0) - 0.06 - 1.5) < 1e-6,
  string.format("one grid of %d terminals drawing %.2f kW (tower, two lights, the machine)", #g.nodes, M.need))
-- take the building's feed up: its lights and the machine's lead go dark together
CB.remove(c3)
W.tick()
check(BG.partServed(hab, u_l1) ~= true and BG.partServed(hab, u_o2) ~= true, "the feed taken up: the building and its machine go dark")
pw = BG.powerWhy(hab, u_o2)
check(pw and pw:find("reach no source"), "the machine: wired, but to nothing that makes power: " .. tostring(pw))
check(BG.towerPower(bid).powered == true, "...the tower keeps its power")

-- ── 5. a save from before the rule ──────────────────────────────────────────
local s2 = { ["base.body"] = "Vever" }
local W2 = world(s2)
W2.BG.WIRED = false   -- (built under the old rule)
local t2 = W2.struct(-R, 0, 0, "tower")
W2.BT.update({}, 0.016)
local b2 = W2.ST.getPart(t2, 1).base
local x2, y2, z2 = W2.at(40)
local a2 = W2.struct(x2, y2, z2, "solarArray")
W2.ST.addPart(a2, { id = "batteryBank", x = 4, y = 0, z = 0 })
W2.tick()
check(W2.BG.towerPower(b2).powered == true, "an old base: the tower served by the array 40 m off, no cable")
-- …saved, and loaded by the game with the rule
s2["grid.wv"] = nil
local W3 = world(s2)
check(W3.BG.WIRED == true and #W3.ST.list() == 2, "the same save, loaded under the wiring rule")
W3.BG.update({}, 0.016)
check(s2["grid.wv"] == W3.BG.WIRE_VERSION and W3.ST.get(t2).aw == 1 and W3.ST.get(a2).aw == 1, "both structures are marked as wired before")
W3.tick()
check(W3.BG.towerPower(b2).powered == true, "...and the tower is still served: nothing the player built goes dark")
check(W3.BG.wiring(a2, 1).legacy == true, "...the array reads as wired before")
local x3, y3, z3 = W3.at(60)
local n3 = W3.struct(x3, y3, z3, "isotopeSkid")
W3.tick()
check(W3.ST.get(n3).aw == nil and W3.BG.gridOfStruct(n3, 1) ~= W3.BG.gridOf(b2), "a skid built now wants its cable")
check(W3.BG.migrate() == 0, "the save is migrated once")
check(W3.BG.rewire(a2) == true, "Rewire by hand drops the mark")
W3.tick()
check(W3.BG.towerPower(b2).powered == false, "...and the tower goes dark until the array is cabled")
-- a reload keeps the marks
local W4 = world(s2)
W4.BG.update({}, 0.016)
check(W4.ST.get(t2).aw == 1 and W4.ST.get(a2).aw == nil and W4.ST.get(n3).aw == nil, "the marks survive a reload; nothing new is marked")

-- ── 6. off the home world: a cable is cut from your own stock ───────────────
do
  local s5 = { ["base.body"] = "Homeworld" }      -- (Vever is not home here)
  local W5 = world(s5)
  local bag = { locker = { wiring = 2, steel = 500 } }
  W5.scripts.inventory = {
    count = function(cid, mat) return (bag[cid] and bag[cid][mat]) or 0 end,
    remove = function(cid, mat, n) local h = (bag[cid] and bag[cid][mat]) or 0; n = math.min(n, h); bag[cid][mat] = h - n; return n end,
    add = function(cid, mat, n) bag[cid] = bag[cid] or {}; bag[cid][mat] = (bag[cid][mat] or 0) + n; return n end,
  }
  W5.scripts.recipes = load_script("recipes.lua", env({}, {}))
  W5.scripts.field_builder = { pushHistory = function() end,
    reachScan = function() return { order = { "locker" }, mats = { wiring = bag.locker.wiring, steel = bag.locker.steel } } end }
  local x5, y5, z5 = W5.at(0)
  local sa = W5.struct(x5, y5, z5, "solarArray")
  local ub5 = W5.ST.addPart(sa, { id = "batteryBank", x = 30, y = 0, z = 0 })
  W5.tick()
  local need = W5.CB.stockNeed(40, "lv16")
  check(#need == 2 and need[1].kg == 28 and need[2].kg == 28, string.format("40 m of 16 mm² is %s", W5.CB.stockLine(need)))
  local v5 = W5.CB.validity({ sid = sa, uid = 1 }, { rec = W5.ST.get(sa), part = W5.ST.getPart(sa, ub5) }, "Vever", "lv16")
  check(v5.bad and v5.bad:find("cut from your own stock", 1, true) and v5.bad:find("2 kg of", 1, true), "short of Wiring: refused, with the numbers: " .. tostring(v5.bad))
  bag.locker.wiring = 60
  local bal0 = W5.money.bal
  v5 = W5.CB.validity({ sid = sa, uid = 1 }, { rec = W5.ST.get(sa), part = W5.ST.getPart(sa, ub5) }, "Vever", "lv16")
  check(v5.bad == nil and v5.quote.mode == "stock" and v5.quote.total == 0, "with the stock in reach it may be laid: no bill (" .. tostring(v5.bad) .. ")")
  local c5, why5 = W5.CB.lay({ sid = sa, uid = 1 }, { sid = sa, uid = ub5 })
  local r5 = c5 and W5.CB.get(c5)
  local used = r5 and r5.paid and r5.paid.mats or {}
  check(c5 ~= nil and W5.money.bal == bal0 and #used == 2 and bag.locker.wiring == 60 - used[1].kg and bag.locker.steel == 500 - used[2].kg,
    string.format("laid off-world (%s): no money, %s out of the locker", tostring(why5), W5.CB.stockLine(used)))
  W5.CB.takeUp(c5)
  check(bag.locker.wiring == 60 and bag.locker.steel == 500, "taken up: coiled back into the stock")
end

if #failures > 0 then
  print("smoke_wired_grid FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print("smoke_wired_grid: " .. passed .. " passed")
