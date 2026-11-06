-- SMOKE: the Build Kit's rules (deep-space addendum step 4: K1, K3, K8, K13,
-- N1; docs/base-building.md), against a stub save and the real crew roster.
--
--   * parts_base: the BASE section, three world parts, every one fieldOnly
--     with a prefab on disk, a real mass, a seat and a footprint;
--   * base_economy (N1): shipping is 10 % + $50; a home-world quote is price
--     + shipping from the section's supplier; off the home world nothing is
--     shipped (fittings at 20 %, Q22); the card's lines; the 60 s full
--     refund (Q18); the containers in reach, nearest first, the pack last
--     (Q16);
--   * structures (K13): a record is in its body's frame with an orthonormal
--     facing; a part's pose adds its seat along up and turns with the
--     structure; add / get / list / remove round-trip through the save as
--     plain values, a reload reads the same, ids are never reused;
--   * field_builder (K1, K8): the Engineer gate on the real crew.lua (a
--     new save's Engineer gets the one Build Kit, the Pilot and the Scientist
--     none, and only once); open() refuses a non-Engineer with the sentence
--     the B key says; place() charges price + shipping at placement and
--     writes the record; undo() within 60 s refunds every dollar through
--     company.refund, after 60 s it refuses; a refused spend changes nothing;
--   * items: the Build Kit is a held device whose line is field_builder's.
--
--   luajit solar/tests/smoke_base_build.lua

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
local function deep_plain(v, seen)
  local t = type(v)
  if t == "number" or t == "string" or t == "boolean" or t == "nil" then return true end
  if t ~= "table" then return false end
  seen = seen or {}
  if seen[v] then return false end
  seen[v] = true
  for k, x in pairs(v) do if not deep_plain(k, seen) or not deep_plain(x, seen) then return false end end
  return true
end

-- ── parts_base ──────────────────────────────────────────────────────────────
local PB = load_script("parts_base.lua", env({}, {}))
local cat = PB.catalogue()
check(#cat == 1 and cat[1].title == "BASE" and #cat[1].ids == 13, "one BASE section with thirteen parts (the stand: step 6; the tower and its two sources: step 7; the Battery Bank, the Shield Wall and the Power Cable: step 8; three more cable drums: S5)")
for _, id in ipairs(cat[1].ids) do
  local d = PB.partInfo(id)
  check(d and d.fieldOnly == true, id .. ": fieldOnly (the VAB never lists it)")
  local f = d and io.open("solar/prefabs/" .. d.prefab .. ".prefab.ron")
  check(f ~= nil, id .. ": its prefab " .. tostring(d and d.prefab) .. " is on disk")
  if f then f:close() end
  if d and d.cable then
    -- (a cable is a run, not a part set down: its numbers are a metre's)
    check(d.cable.max > 0 and d.cable.kgm > 0 and d.cable.perm > 0 and type(d.seat) == "number", id .. ": a run's length limit, mass and price a metre")
  else
    check(d and d.mass >= 0.15 and d.cost > 0 and type(d.seat) == "number" and d.half and d.half.x > 0, id .. ": mass, cost, seat, footprint")
  end
end
check(near(PB.partInfo("padPlate").mass, 4 * 4 * 0.30 * 2.4, 0.05), "the Pad Plate weighs its concrete (4 x 4 x 0.30 m at 2.4 t/m³)")
check(PB.partInfo("shed").hull == "subShape" and PB.partInfo("hab").hull == "shell", "flat walls → subShapes, the curved can → a shell")
local REG, CATL = {}, {}
check(PB.register(REG, CATL) == 13 and REG.padPlate and CATL[1][1] == "BASE", "register() adds the BASE section to a registry")

-- ── base_economy ────────────────────────────────────────────────────────────
local EC = load_script("base_economy.lua", env({}, {}))
check(EC.shipping(900) == 140 and EC.shipping(0) == 50 and EC.shipping(6500) == 700, "shipping = 10 % + $50")
local pad = PB.partInfo("padPlate")
local q = EC.quote(pad, "BASE", "Vever", "Vever")
check(q.mode == "money" and q.cost == 900 and q.ship == 140 and q.total == 1040 and q.supplier == "Pell Groundworks",
  "home world: $900 + $140 shipping = $1,040 from Pell Groundworks")
local p1, p2 = EC.cardLines(q)
check(p1 == "$1,040" and p2 == "$900 + $140 shipping · Pell Groundworks", "the card's lines (" .. tostring(p1) .. " / " .. tostring(p2) .. ")")
local qa = EC.quote(pad, "BASE", "Nami", "Vever")
check(qa.mode == "away" and qa.fittings == 180 and qa.why ~= nil, "off the home world: not shipped, fittings 20 % (Q22)")
check(EC.supplierOf("PROPULSION") == "Marrow & Vance Propulsion" and EC.supplierOf("nonsense") == "Halden Structural", "a supplier per section")
check(EC.ledgerWhy("Pad Plate", q):find("shipped by Pell Groundworks", 1, true) ~= nil, "the ledger names the supplier")
local rec = { paid = { total = 1040, t = 100 } }
check(EC.undoRefund(rec, 100) == 1040 and EC.undoRefund(rec, 160) == 1040, "within 60 s: the full $1,040 back")
local none, why = EC.undoRefund(rec, 160.5)
check(none == nil and why and why:find("deconstruct", 1, true), "after 60 s: no undo, a deconstruct instead")
check(EC.undoRefund({}, 0) == nil, "nothing paid: nothing to refund")
local order = EC.containersInReach({ { id = "crew:1", pack = true }, { id = "far", x = 40, y = 0, z = 0 },
  { id = "crate:2", x = 12, y = 0, z = 0 }, { id = "hold:5", x = 0, y = 5, z = 0 } }, 0, 0, 0)
check(#order == 3 and order[1] == "hold:5" and order[2] == "crate:2" and order[3] == "crew:1",
  "Q16: containers within 30 m, nearest first, the pack last (" .. table.concat(order, ",") .. ")")

-- ── structures ──────────────────────────────────────────────────────────────
local store = {}
local ST = load_script("structures.lua", env(store, {}))
local up = { x = 0.6, y = 0.8, z = 0 }
local r1 = ST.newRecord(nil, "Vever", 300, 400, 0, up, { x = 0.3, y = 0.1, z = 1 }, "shed", { by = 3, t = 10, paid = { total = 1590, t = 10 } })
local ux, uy, uz, fx, fy, fz, rx, ry, rz = ST.frame(r1)
check(near(ux * fx + uy * fy + uz * fz, 0) and near(rx * ux + ry * uy + rz * uz, 0) and near(fx * fx + fy * fy + fz * fz, 1),
  "a record's frame is orthonormal (front flattened onto the ground)")
local x, y, z, U, F = ST.partPose(r1, r1.bp[1], 1.30)
check(near(x, 300 + 0.6 * 1.30) and near(y, 400 + 0.8 * 1.30) and near(z, 0), "a part's origin = ground point + seat along up")
check(near(F.x, fx) and near(F.z, fz) and near(U.y, 0.8), "a part with no yaw faces the structure's front")
local _, _, _, _, F2 = ST.partPose(r1, { x = 0, y = 0, z = 0, yaw = math.pi / 2 }, 0)
check(near(F2.x, rx) and near(F2.y, ry) and near(F2.z, rz), "yaw 90° turns a part's front to the structure's right")
local _, _, _, _, F3 = ST.partPose(r1, { x = 2, y = 0, z = 0 }, 0)
local x4 = ST.partPose(r1, { x = 2, y = 0, z = 0 }, 0)
check(near(x4, 300 + 2 * rx), "a part 2 m along +X stands 2 m to the structure's right")
local id1 = ST.add(r1)
local r2 = ST.newRecord(nil, "Vever", -50, 10, 7, { x = 0, y = 1, z = 0 }, { x = 0, y = 0, z = 1 }, "padPlate", { t = 20 })
local id2 = ST.add(r2)
check(id1 == 1 and id2 == 2 and ST.count() == 2, "ids from struct.seq, in order")
check(type(store["struct.1"]) == "table" and store["struct.1"].b == "Vever" and store["struct.list"][2] == 2, "written to the save")
check(deep_plain(store["struct.1"]) and deep_plain(store["struct.2"]), "the save holds plain values only")
check(store["struct.1"].x == 300 and store["struct.1"].bp[1].id == "shed", "body-relative ground point and the blueprint part")
local nr, nd = ST.near("Vever", 301, 400, 0, 5)
check(nr and nr.id == 1 and near(nd, 1), "near() finds it by its body-relative point")
check(ST.near("Nami", 300, 400, 0, 5) == nil, "...only on its own body")
-- a reload (a new script on the same save)
local ST2 = load_script("structures.lua", env(store, {}))
local g1 = ST2.get(1)
check(g1 and g1.x == 300 and g1.y == 400 and g1.ux == r1.ux and g1.paid.total == 1590 and #ST2.list() == 2,
  "a reload reads the same records, in the body's frame")
ST2.remove(1)
check(store["struct.1"] == nil and #store["struct.list"] == 1 and ST2.get(1) == nil, "remove() drops the record and its key")
local r3 = ST2.newRecord(nil, "Vever", 0, 1, 0, { x = 0, y = 1, z = 0 }, { x = 0, y = 0, z = 1 }, "hab")
check(ST2.add(r3) == 3, "an id is never reused")

-- ── the Engineer gate and the placement, with the real crew roster ─────────
local s = { g_seed = 99, ["base.body"] = "Vever", ["agency.clock"] = 1000 }
local scripts = {}
local CLOCK = { t = 1000 }
scripts.deployables = { agencyClock = function() return CLOCK.t end, dateOf = function() return "Day 1, Y1" end }
local C = load_script("crew.lua", env(s, { inventory = { resolve = function(c) return c end },
  deployables = scripts.deployables }))
C.start()
scripts.crew = C
local bag = {}
scripts.inventory = {
  itemCount = function(cid, id)
    if cid == "astro" then cid = C.packOf(C.activeId()) end
    return (bag[cid] or {})[id] or 0
  end,
  addItem = function(cid, id, n) bag[cid] = bag[cid] or {}; bag[cid][id] = (bag[cid][id] or 0) + n; return n end,
}
local hand = { id = nil }
scripts.item_hand = { held = function() return hand.id end,
  hold = function(id) if id and scripts.inventory.itemCount("astro", id) < 1 then return false, "none" end hand.id = id; return true end,
  busy = function() return false end }
local ledger = {}
local funds = { v = 5000 }
scripts.company = {
  afford = function(a) return funds.v >= a end,
  spend = function(a, why) if funds.v < a then return false end funds.v = funds.v - a; ledger[#ledger + 1] = { -a, why }; return true end,
  refund = function(a, why) funds.v = funds.v + a; ledger[#ledger + 1] = { a, why } end,
  earn = function(a, why) funds.v = funds.v + a; ledger[#ledger + 1] = { a, why, "earn" } end,
}
scripts.parts_base = PB
scripts.base_economy = EC
scripts.base_snap = load_script("base_snap.lua", env({}, {}))
scripts.builder_history = load_script("builder_history.lua", env({}, {}))
local sstore = s
scripts.structures = load_script("structures.lua", env(sstore, {}))
local FB = load_script("field_builder.lua", env(s, scripts, { input = { pressed = function() return false end } }))
scripts.field_builder = FB
local eng, pil
for _, r in ipairs(C.roster()) do
  if C.role(r) == "engineer" then eng = r.id elseif C.role(r) == "pilot" then pil = r.id end
end
check(eng and pil, "the new save has an Engineer and a Pilot")
check(FB.isEngineer(eng) and not FB.isEngineer(pil), "isEngineer reads crew.hasRole")
FB.issueNow()
local kits = 0
for _, r in ipairs(C.roster()) do kits = kits + scripts.inventory.itemCount(C.packOf(r.id), "buildkit") end
check(kits == 1 and scripts.inventory.itemCount(C.packOf(eng), "buildkit") == 1, "one Build Kit, issued to the Engineer only")
FB.issueNow()
check(scripts.inventory.itemCount(C.packOf(eng), "buildkit") == 1, "...once: a second check issues nothing")
s["crew.active"] = pil
local ok, w = FB.open()
check(not ok and w == "Build Kit: Engineers only", "the Pilot's B: \"Build Kit: Engineers only\"")
s["crew.active"] = eng
ok = FB.open()
check(ok and hand.id == "buildkit", "the Engineer's B takes the kit out")
-- a placement: charged at placement, then undone within the minute
local pose = { body = "Vever", x = 120, y = 800, z = -40, up = { x = 0.148, y = 0.987, z = -0.05 }, fwd = { x = 0, y = 0.05, z = 1 } }
local sid, why2, qq = FB.place(nil, "padPlate", pose, "money")
check(sid ~= nil and funds.v == 5000 - 1040 and qq.total == 1040, "placing a Pad Plate charges $1,040 at placement (" .. tostring(why2) .. ")")
check(ledger[1] and ledger[1][2]:find("shipped by Pell Groundworks", 1, true), "the ledger line names the supplier")
local srec = scripts.structures.get(sid)
check(srec and srec.b == "Vever" and srec.x == 120 and srec.paid.total == 1040 and srec.by == eng, "the structure record: body frame, paid, by the Engineer")
check(C.get(eng).built == 1, "the Engineer is credited one built")
CLOCK.t = CLOCK.t + 59
local back = FB.undo()
check(back == 1040 and funds.v == 5000 and scripts.structures.get(sid) == nil, "undo within 60 s: all $1,040 back, the structure gone")
check(ledger[#ledger][3] == nil, "...through company.refund, not as income")
check(C.get(eng).built == 0, "...and the credit taken back")
local sid2 = FB.place(nil, "shed", pose, "money")
CLOCK.t = CLOCK.t + 61
local none2, why3 = FB.undo()
check(none2 == nil and why3 and scripts.structures.get(sid2) ~= nil and funds.v == 5000 - 1590, "after 60 s: no undo, the shed stays")
funds.v = 100
local f0 = funds.v
local n0 = scripts.structures.count()
local sid3, why4 = FB.place(nil, "hab", pose, "money")
check(sid3 == nil and why4:find("afford", 1, true) and funds.v == f0 and scripts.structures.count() == n0, "can't afford it: nothing charged, nothing built")
local sid4, why5 = FB.place(nil, "padPlate", { body = "Nami", x = 0, y = 1, z = 0, up = { x = 0, y = 1, z = 0 }, fwd = { x = 0, y = 0, z = 1 } }, "money")
check(sid4 == nil and why5 ~= nil, "off the home world: refused with the reason (" .. tostring(why5) .. ")")

-- ════ STEP 5 (K5–K7, K9–K10) ═══════════════════════════════════════════════

-- ── base_economy: footings and deconstruct refunds ──────────────────────────
check(EC.footingCost(0) == 0 and EC.footingCost(2.5) == 400, "a footing: $160 a cubic metre of concrete")
local qf = EC.quote(pad, "BASE", "Vever", "Vever", 2.5)
check(qf.foot == 400 and qf.total == 900 + 140 + 400, "a quote with a footing adds its concrete (" .. tostring(qf.total) .. ")")
check(EC.ledgerWhy("Pad Plate", qf):find("$400 footing", 1, true) ~= nil, "the ledger names the footing")
local paidx = { cost = 900, ship = 140, foot = 400, total = 1440, t = 100 }
local a1, r1x = EC.deconstructRefund(paidx, 150)
local a2, r2x = EC.deconstructRefund(paidx, 161)
check(a1 == 1440 and r1x == "full" and a2 == 900 and r2x == "price", "deconstruct: all of it within 60 s, the price after (fee and footing kept)")

-- ── base_snap: frames, edges, decks, the grid, the ground ───────────────────
local SN = scripts.base_snap
local function defs(id) return PB.partInfo(id) end
local recA = { id = 7, b = "Vever", x = 0, y = 600, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1,
               bp = { { uid = 1, id = "padPlate", x = 0, y = 0, z = 0, yaw = 0 } } }
local frA = SN.frameOf(recA)
local bx_, by_, bz_ = SN.toBody(frA, 1.5, 0.2, -2)
local lx_, ly_, lz_ = SN.toLocal(frA, bx_, by_, bz_)
check(near(lx_, 1.5) and near(ly_, 0.2) and near(lz_, -2) and near(bx_, 1.5) and near(bz_, -2), "a structure's frame: local ↔ body round trip (+X right, +Z front)")
local UP = { x = 0, y = 1, z = 0 }
local TOW = { x = 0, y = 0, z = -1 }
-- EDGE: a plate aimed at the ground just past the first plate's +X edge
local e1 = SN.snap({ def = pad, P = { x = 4.6, y = 600.1, z = 0.3 }, U = UP, toward = TOW,
  near = { { rec = recA, part = recA.bp[1], d = 4.6 } }, defs = defs })
check(e1.mode == "edge" and e1.rec == recA and near(e1.lx, 4) and near(e1.lz, 0) and near(e1.ly, 0) and near(e1.y, 600),
  string.format("a plate beside a plate snaps edge to edge, level (%s %.2f %.2f %.2f)", tostring(e1.mode), e1.lx or -1, e1.lz or -1, e1.ly or -1))
check(near(e1.fwd.z, 1) and near(e1.up.y, 1), "...square to it")
recA.bp[2] = { uid = 2, id = "padPlate", x = 4, y = 0, z = 0, yaw = 0 }
local e2 = SN.snap({ def = pad, P = { x = 4.6, y = 600.1, z = 0.3 }, U = UP, toward = TOW,
  near = { { rec = recA, part = recA.bp[1], d = 4.6 }, { rec = recA, part = recA.bp[2], d = 0.7 } }, defs = defs })
check(e2.mode ~= "edge" or not (near(e2.lx, 4) and near(e2.lz, 0)), "a taken slot is never offered again")
local e3 = SN.snap({ def = pad, P = { x = 7.0, y = 600, z = 0.2 }, U = UP, toward = TOW,
  near = { { rec = recA, part = recA.bp[2], d = 3.0 }, { rec = recA, part = recA.bp[1], d = 7.0 } }, defs = defs })
check(e3.mode == "edge" and near(e3.lx, 8) and near(e3.lz, 0), "...the next free one along the row is")
local e4 = SN.snap({ def = pad, P = { x = 4.6, y = 600.1, z = 6.3 }, U = UP, toward = TOW, free = true,
  near = { { rec = recA, part = recA.bp[1], d = 6 } }, defs = defs })
check(e4.mode == "free" and e4.rec == nil and near(e4.x, 4.6) and near(e4.z, 6.3), "Shift frees it: no snap, no grid")
-- DECK: a shed aimed at the plate's top
local shed = PB.partInfo("shed")
local d1 = SN.snap({ def = shed, P = { x = 0.37, y = 600.2, z = -0.2 }, U = UP, toward = { x = 0.2, y = 0, z = -1 },
  hit = { rec = recA, part = recA.bp[1] }, defs = defs })
check(d1.mode == "deck" and d1.rec == recA and near(d1.ly, 0.20) and near(d1.lx, 0.5) and near(d1.lz, 0),
  string.format("a shed on a plate stands on its deck, on the 0.5 m grid (%.2f %.2f %.2f)", d1.lx, d1.ly, d1.lz))
check(near(math.abs(d1.yaw), math.pi) or near(d1.yaw, math.pi), "...square to the plate, its front turned toward you (yaw " .. string.format("%.2f", d1.yaw) .. ")")
local d2 = SN.snap({ def = shed, P = { x = 0.37, y = 600.2, z = -0.2 }, U = UP, toward = { x = 0.2, y = 0, z = -1 },
  hit = { rec = recA, part = recA.bp[1] }, defs = defs, yawOff = math.rad(15) })
check(near(SN.wrap(d2.yaw - d1.yaw), math.rad(15)), "...and turns by the 15° steps dialled")
local ok9, n9 = SN.supported(recA, defs, shed, 0, 0.20, 0, 0)
check(ok9 == 9 and n9 == 9, "a shed on a plate: every footprint sample on the deck")
local hab = PB.partInfo("hab")
local okh = SN.supported({ bp = { recA.bp[1] } }, defs, hab, 0, 0.20, 0, 0)
check(okh < 9, "a hab on ONE plate hangs off it (" .. okh .. "/9)")
local okh2 = SN.supported(recA, defs, hab, 2, 0.20, 0, 0)
check(okh2 == 9, "a hab across two plates edge to edge stands on them")
check(SN.supported(recA, defs, hab, 2, 0.50, 0, 0) == 0, "...but not at another height")
-- dependents: what stands on a plate comes down with it
recA.bp[3] = { uid = 3, id = "shed", x = 0, y = 0.20, z = 0, yaw = 0 }
recA.bp[4] = { uid = 4, id = "hab", x = 2, y = 0.20, z = 0, yaw = 0 }
local dep1 = SN.dependents(recA, defs, 1)
check(#dep1 == 2, "a plate takes the shed and the hab standing on it down with it (" .. #dep1 .. ")")
local dep3 = SN.dependents(recA, defs, 3)
check(#dep3 == 0, "a shed takes nothing with it")
recA.bp[3], recA.bp[4] = nil, nil
-- GRID: a new structure square to the layout, on its 0.5 m grid
local refF = SN.frameOf({ x = 0, y = 600, z = 0, ux = 0, uy = 1, uz = 0, fx = 1, fy = 0, fz = 0 })
local g1 = SN.snap({ def = shed, P = { x = 30.13, y = 600.3, z = 40.41 }, U = UP, toward = { x = -0.3, y = 0, z = -1 }, near = {}, defs = defs, ref = refF })
check(g1.mode == "grid" and g1.rec == nil and near(g1.x, 30.0) and near(g1.z, 40.5), string.format("the ground grid: 0.5 m in the layout's frame (%.2f, %.2f)", g1.x, g1.z))
check(near(math.abs(g1.fwd.x) + math.abs(g1.fwd.z), 1) and near(g1.fwd.z, -1), "...its front square to the layout, toward you")
local g2 = SN.snap({ def = shed, P = { x = 30.13, y = 600.3, z = 40.41 }, U = UP, toward = { x = -0.3, y = 0, z = -1 }, near = {}, defs = defs, ref = refF, yawOff = math.rad(30) })
check(near(math.deg(math.acos(g2.fwd.x * g1.fwd.x + g2.fwd.z * g1.fwd.z)), 30, 1e-4), "...turned by the 30° dialled")
local g3 = SN.snap({ def = shed, P = { x = 6.2, y = 600, z = 9.9 }, U = UP, toward = TOW, defs = defs, ref = refF,
  near = { { rec = recA, part = recA.bp[1], d = 11.8 } } })
check(g3.mode == "grid" and near(g3.x, 6.0) and near(g3.z, 10.0), "near a structure the grid is that structure's")
-- THE GROUND
local flat = { 0, 0.01, -0.01, 0, 0.02, 0, 0, -0.02, 0 }
local f1 = SN.foundation(shed, flat, nil, 0)
check(f1.ok and near(f1.base, 0, 0.01) and f1.footing == nil, "flat ground: no footing")
local slope = { -0.6, -0.6, -0.6, 0, 0, 0, 0.6, 0.6, 0.6 }
local f2 = SN.foundation(shed, slope, nil, 0)
check(f2.ok and near(f2.base, 0) and f2.level and f2.footing and near(f2.footing.d, 0.9) and f2.vol > 0,
  "a slope: levelled to the mean, a footing down to the low side and 0.3 m in (" .. tostring(f2.footing and f2.footing.d) .. ")")
local f3 = SN.foundation(shed, { -2.5, 0, 2.5, -2.5, 0, 2.5, -2.5, 0, 2.5 }, nil, 0)
check(not f3.ok and f3.why:find("1.6 m at most", 1, true), "too steep to grade: refused with why (" .. tostring(f3.why) .. ")")
local f4 = SN.foundation(pad, { -0.3, -0.3, -0.2, -0.1, 0, 0, 0, 0.1, 0.1 }, 0, 0)
check(f4.ok and f4.base == 0 and f4.footing == nil, "a plate joining a structure sits at its level; its own 0.40 m skirt takes a 0.3 m fall")
local f5 = SN.foundation(shed, flat, nil, 1.0)
check(f5.ok and near(f5.base, 1.0, 0.01) and f5.footing and near(f5.footing.d, 1.3, 0.03), "raised 1 m: stands on a 1.3 m footing")
check(not SN.foundation(shed, { false, false, false, false, 0, false, false, false, false }).ok, "no ground under most of it: refused")
local discs, drad = SN.gradeDiscs(hab)
local covered = true
for _, q in ipairs(SN.footPoints(hab, 0, 0, 0, 0)) do
  local inside = false
  for _, dd in ipairs(discs) do if (dd.x - q.x) ^ 2 + (dd.z - q.z) ^ 2 <= (drad * 0.75) ^ 2 then inside = true end end
  covered = covered and inside
end
check(covered and #discs <= 8, "the flatten discs' full-strength cores cover the whole footprint (" .. #discs .. " discs)")

-- ── structures: parts join and leave, the index ─────────────────────────────
local st5 = {}
local ST5 = load_script("structures.lua", env(st5, { parts_base = PB }))
local rr = ST5.newRecord(nil, "Vever", 100, 600, 0, { x = 0, y = 1, z = 0 }, { x = 0, y = 0, z = 1 }, "padPlate",
  { paid = { total = 1040, t = 1 } })
rr.bp[1].ft = { d = 0.9, hx = 2.15, hz = 2.15 }
local s5 = ST5.add(rr)
local u2 = ST5.addPart(s5, { id = "padPlate", x = 4, y = 0, z = 0, paid = { total = 1040, t = 2 } })
local u3 = ST5.addPart(s5, { id = "shed", x = 0, y = 0.2, z = 0, paid = { total = 1590, t = 3 } })
check(u2 == 2 and u3 == 3 and #ST5.get(s5).bp == 3 and #st5["struct." .. s5].bp == 3, "addPart joins parts, uids in order, written to the save")
check(deep_plain(st5["struct." .. s5]) and st5["struct." .. s5].bp[1].ft.d == 0.9, "...plain values, the footing with them")
local nearL = ST5.partsNear("Vever", 104.5, 600, 0.5, 3)
check(#nearL == 1 and nearL[1].part.uid == 2, "partsNear: the cell index finds the plate under the point")
check(#ST5.partsNear("Vever", 300, 600, 0, 10) == 0 and #ST5.partsNear("Nami", 104, 600, 0, 10) == 0, "...and nothing far away or on another body")
local ST5b = load_script("structures.lua", env(st5, { parts_base = PB }))
check(#ST5b.get(s5).bp == 3 and #ST5b.partsNear("Vever", 100, 600, 0, 6) == 3, "a reload reads the parts and rebuilds the index")
local gone = ST5b.removeParts(s5, { 3 })
check(#gone == 1 and gone[1].id == "shed" and #ST5b.get(s5).bp == 2, "removeParts takes one out")
ST5b.removeParts(s5, { 1, 2 })
check(ST5b.get(s5) == nil and st5["struct." .. s5] == nil and #ST5b.partsNear("Vever", 100, 600, 0, 10) == 0, "...and the record goes with its last part")

-- ── field_builder: joining, the ring, deconstruct ───────────────────────────
funds.v = 50000
CLOCK.t = 5000
local base_pose = { body = "Vever", x = 0, y = 600, z = 50, up = { x = 0, y = 1, z = 0 }, fwd = { x = 0, y = 0, z = 1 } }
local sA = FB.place(nil, "padPlate", base_pose, "money")
local f6 = funds.v
local sB, _, qB, uB = FB.place(sA, "padPlate", { body = "Vever", lx = 4, ly = 0, lz = 0, yaw = 0, mode = "edge" }, "money")
check(sB == sA and uB == 2 and f6 - funds.v == 1040 and #scripts.structures.get(sA).bp == 2, "a plate placed edge to edge joins the structure, charged as any")
local sC, _, _, uC = FB.place(sA, "shed", { body = "Vever", lx = 0, ly = 0.2, lz = 0, yaw = 0, mode = "deck" }, "money")
check(sC == sA and uC == 3 and scripts.structures.getPart(sA, 3).y == 0.2, "a shed on its deck joins at the deck's height")
local sF = FB.place(nil, "shed", { body = "Vever", x = 30, y = 600, z = 50, up = { x = 0, y = 1, z = 0 }, fwd = { x = 0, y = 0, z = 1 },
  base = 0.3, plan = { ok = true, base = 0.3, vol = 2.5, level = true, footing = { d = 0.9, hx = 1.75, hz = 1.45 } } }, "money")
local rF = scripts.structures.get(sF)
check(rF and near(rF.y, 600.3) and rF.bp[1].ft and rF.bp[1].ft.d == 0.9 and rF.bp[1].paid.foot == 400,
  "a ground part on a slope: set at its base, its footing recorded and billed ($400)")
-- THE RING: four placements, undone newest first
local fU = funds.v
local back1 = FB.undo()
check(back1 == 1590 + 400 and scripts.structures.get(sF) == nil and funds.v == fU + 1990, "Ctrl+Z: the footed shed back, all $1,990")
local back2 = FB.undo()
check(back2 == 1590 and scripts.structures.getPart(sA, 3) == nil, "Ctrl+Z again: the shed on the deck")
local back3 = FB.undo()
check(back3 == 1040 and #scripts.structures.get(sA).bp == 1, "...and again: the second plate (a ring, not one step)")
local fR = funds.v
local again = FB.redo()
check(again == 1040 and #scripts.structures.get(sA).bp == 2 and fR - funds.v == 1040, "Ctrl+Shift+Z: the plate again, bought again")
CLOCK.t = CLOCK.t + 70
local no5, why5b = FB.undo()
check(no5 == nil and why5b:find("deconstruct", 1, true) and #scripts.structures.get(sA).bp == 2, "older than 60 s: refused, deconstruct it instead")
-- DECONSTRUCT
FB.place(sA, "shed", { body = "Vever", lx = 0, ly = 0.2, lz = 0, yaw = 0, mode = "deck" }, "money")
local amtQ, nQ, fullQ = FB.deconstructQuote(sA, 1)
check(nQ == 2 and not fullQ and amtQ == 900 + 1590, "the menu's quote: the plate's price, and the shed (still in its minute) whole")
local fD = funds.v
local got, uids = FB.deconstruct(sA, 1)
check(got == 900 + 1590 and #uids == 2 and funds.v == fD + got and scripts.structures.getPart(sA, 1) == nil
  and scripts.structures.getPart(sA, 3) == nil and #scripts.structures.get(sA).bp == 1,
  "deconstruct: the plate's price back (fee kept), the shed on it comes down too (" .. tostring(got) .. ")")
check(ledger[#ledger][3] == nil and ledger[#ledger][2]:find("fee kept", 1, true), "...a refund, saying the fee was kept")
local fP = funds.v
local put = FB.undo()
check(put == got and scripts.structures.getPart(sA, 1) ~= nil and scripts.structures.getPart(sA, 3) ~= nil and fP - funds.v == got,
  "Ctrl+Z on a deconstruct: both back, the refund taken back")
CLOCK.t = CLOCK.t + 70
local last = FB.deconstruct(sA, 2)
check(last == 900 and scripts.structures.getPart(sA, 2) == nil, "a lone plate after its minute: $900, fee kept")
FB.deconstruct(sA, 1)
check(scripts.structures.get(sA) == nil, "the last part down: the structure is gone")
local H = FB.history()
check(H and H.cap == 50 and H:size() <= 50, "the ring is builder_history's, 50 deep")

-- ── items ───────────────────────────────────────────────────────────────────
local IT = load_script("items.lua", env({}, {}))
local d = IT.def("buildkit")
check(d and d.kind == "device" and IT.holdable("buildkit") and d.hintFrom == "field_builder", "the Build Kit is a held device")
local b = IT.belt(function(id) return id == "buildkit" and 1 or (id == "laser" and 1 or 0) end)
check(#b == 2 and b[1].id == "laser" and b[2].id == "buildkit", "on the belt after the tools")

if #failures > 0 then
  for _, m in ipairs(failures) do print("FAIL: " .. m) end
  print(string.format("smoke_base_build: %d passed, %d FAILED", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_base_build: all %d checks passed", passed))
