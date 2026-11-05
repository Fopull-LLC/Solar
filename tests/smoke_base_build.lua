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
check(#cat == 1 and cat[1].title == "BASE" and #cat[1].ids == 3, "one BASE section with three parts")
for _, id in ipairs(cat[1].ids) do
  local d = PB.partInfo(id)
  check(d and d.fieldOnly == true, id .. ": fieldOnly (the VAB never lists it)")
  local f = d and io.open("solar/prefabs/" .. d.prefab .. ".prefab.ron")
  check(f ~= nil, id .. ": its prefab " .. tostring(d and d.prefab) .. " is on disk")
  if f then f:close() end
  check(d and d.mass > 0.5 and d.cost > 0 and type(d.seat) == "number" and d.half and d.half.x > 0, id .. ": mass, cost, seat, footprint")
end
check(near(PB.partInfo("padPlate").mass, 4 * 4 * 0.30 * 2.4, 0.05), "the Pad Plate weighs its concrete (4 x 4 x 0.30 m at 2.4 t/m³)")
check(PB.partInfo("shed").hull == "subShape" and PB.partInfo("hab").hull == "shell", "flat walls → subShapes, the curved can → a shell")
local REG, CATL = {}, {}
check(PB.register(REG, CATL) == 3 and REG.padPlate and CATL[1][1] == "BASE", "register() adds the BASE section to a registry")

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
