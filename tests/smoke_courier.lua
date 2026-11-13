-- smoke_courier: SHIPPING BETWEEN BASES (courier.lua; playtest 11-12b,
-- work/baseloop/DESIGN.md phase 6).
--
--   • the bill: by weight and distance on one world, a flat rate and two
--     days between worlds; what stops a pod (empty, over 2 t, one already
--     flying, the sender's tower dark, no money)
--   • the scene half on real inventory and structures: the sources (the
--     warehouse, a base's containers within 150 m of its tower), their
--     stock; a request takes the goods and the fee at once; nothing lands
--     before its time; on time the pod is set down by the tower with every
--     crate and kilogram in it; the save carries a pod in flight
--
--   luajit solar/tests/smoke_courier.lua          (from the Floptle repo root)
local failures, passed = {}, 0
local function check(ok, msg) if ok then passed = passed + 1 else failures[#failures + 1] = msg end end
local function near(a, b, e) return math.abs(a - b) <= (e or 1e-6) end
local store, SCR, T = {}, {}, { t = 50 }
local function env(extra)
  local E = setmetatable({
    save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end, delete = function(k) store[k] = nil end },
    findScript = function(k) return SCR[k] end, findScripts = function() return {} end, find = function() return nil end, log = function() end,
  }, { __index = function(_, k) if k == "time" then return T.t end return _G[k] end })
  for k, v in pairs(extra or {}) do E[k] = v end
  return E
end
local function load_script(path, E)
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, E); f()
  E.params = {}
  for k, v in pairs(E.defaults or {}) do E.params[k] = v end
  return E
end
local CR0 = load_script("courier.lua", env())

-- ── the bill ────────────────────────────────────────────────────────────────
local q = CR0.quote(500, 3000, true)
check(q.fee == 60 + 40 * 0.5 * 3 and near(q.secs, 300 + 3000 / 25), string.format("500 kg over 3 km: $%d, %.0f s", q.fee, q.secs))
q = CR0.quote(2000, 40000, true)
check(q.fee == 60 + 40 * 2 * 40 and near(q.secs, 300 + 1600), string.format("a full pod 40 km round the world: $%d in %s", q.fee, CR0.etaLine(q.secs)))
q = CR0.quote(1000, 0, false)
check(q.fee == 2500 + 400 and q.secs == 2 * 86400, string.format("a tonne to another world: $%d, %s", q.fee, CR0.etaLine(q.secs)))
check(CR0.whyNot({}, false, true, 1e6, 10):find("empty", 1, true), "an empty manifest goes nowhere")
check(CR0.whyNot({ { kg = 2500 } }, false, true, 1e6, 10):find("2000 kg", 1, true), "over 2 t is refused")
check(CR0.whyNot({ { kg = 10 } }, true, true, 1e6, 10):find("one at a time", 1, true), "one pod in flight to a base")
check(CR0.whyNot({ { kg = 10 } }, false, false, 1e6, 10):find("no power", 1, true), "a dark tower dispatches nothing")
check(CR0.whyNot({ { kg = 10 } }, false, true, 5, 10):find("afford", 1, true), "no money, no pod")
check(CR0.whyNot({ { kg = 10 } }, false, nil, 50, 10) == nil, "the warehouse (no tower to ask) sends")
check(CR0.etaLine(90) == "2 min" and CR0.etaLine(7200) == "2.0 h" and CR0.etaLine(172800) == "2.0 days", "the arrival reads in minutes, hours, days")

-- ── the scene half ──────────────────────────────────────────────────────────
do
  local KIT = load_script("parts_kit.lua", env())
  SCR.parts_kit = KIT
  local PB = load_script("parts_base.lua", env())
  SCR.parts_base = PB
  SCR.materials = load_script("materials.lua", env())
  SCR.items = load_script("items.lua", env())
  SCR.recipes = load_script("recipes.lua", env())
  local inv = load_script("inventory.lua", env())
  SCR.inventory = inv
  local R = 800
  local bodies = { X = { name = "X", x = 5000, y = 0, z = 0, radius = R } }
  local X = { space = { body = function(n) return bodies[n] end, dominant = function() return "X" end } }
  local ST = load_script("structures.lua", env(X))
  SCR.structures = ST
  local clock = { a = 1000 }
  SCR.deployables = { agencyClock = function() return clock.a end }
  local bal = 5000
  SCR.company = { balance = function() return bal end, spend = function(v) if v > bal then return false end bal = bal - v; return true end, money = function(v) return "$" .. v end }
  local powered = { [1] = true, [2] = true }
  SCR.base_tower = { power = function(bid) return { powered = powered[bid] == true } end }
  SCR.base_facilities = { footprint = { body = "X", x = R, y = 0, z = 0 } }
  local drops = {}
  SCR.salvage = { drop = function(body, x, y, z, ign, o)
    local it, gear = inv.items(o.from), inv.itemList(o.from)
    local kg = inv.mass(o.from)
    inv.setCap("salvage:" .. (#drops + 1), kg + 1)
    for _, e in ipairs(it) do inv.transfer(o.from, "salvage:" .. (#drops + 1), e.mat, e.n) end
    for _, g in ipairs(gear) do inv.moveItem(o.from, "salvage:" .. (#drops + 1), g.id, g.n, { force = true }) end
    drops[#drops + 1] = { body = body, x = x, y = y, z = z, label = o.label, kg = kg }
    return #drops, kg
  end }
  SCR.feats = { marks = {}, mark = function(id) SCR.feats.marks[id] = true end }
  -- two bases 6 km apart round the equator, each a tower and a locker
  local function at(d) local th = d / R return R * math.cos(th), R * math.sin(th), 0 end
  local function struct(d, part)
    local x, y, z = at(d)
    local l = math.sqrt(x * x + y * y + z * z)
    return ST.add(ST.newRecord(nil, "X", x, y, z, { x = x / l, y = y / l, z = z / l }, { x = 0, y = 0, z = 1 }, part)), x, y, z
  end
  local s1, x1, y1, z1 = struct(1000, "tower")
  local l1 = ST.addPart(s1, { id = "locker.steel", x = 4, y = 0, z = 0 })
  local s2, x2, y2, z2 = struct(1600, "tower")
  local l2 = ST.addPart(s2, { id = "locker.steel", x = 4, y = 0, z = 0 })
  local sfar = struct(1000 + 400, "locker.steel")
  SCR.bases = { list = function() return { { id = 1, b = "X", x = x1, y = y1, z = z1, n = "Kestrel Flats", sid = s1, uid = 1 },
                                            { id = 2, b = "X", x = x2, y = y2, z = z2, n = "Leeward", sid = s2, uid = 1 } } end,
                groundDist = function(Rr, ax, ay, az, bx, by, bz)
                  local la, lb = math.sqrt(ax * ax + ay * ay + az * az), math.sqrt(bx * bx + by * by + bz * bz)
                  return math.acos(math.max(-1, math.min(1, (ax * bx + ay * by + az * bz) / (la * lb)))) * Rr
                end,
                byTower = function(sid, uid) for _, r in ipairs(SCR.bases.list()) do if r.sid == sid and r.uid == uid then return r end end end }
  local CR = load_script("courier.lua", env(X))
  CR.start({ id = 3 })
  local c1 = "piece:" .. s1 .. ":" .. l1
  inv.setCap(c1, 2000); inv.setCap("piece:" .. s2 .. ":" .. l2, 2000); inv.setCap("piece:" .. sfar .. ":1", 2000)
  local wall = SCR.recipes.partItemId("wall.steel")
  inv.addItem(c1, wall, 3, { force = true })
  inv.add(c1, "steel", 300)
  inv.add("piece:" .. sfar .. ":1", "steel", 999)
  inv.add("base", "glass", 40)
  local src = CR.sources()
  check(#src == 3 and src[1].key == "home" and src[2].key == "b1" and #src[2].cids == 1 and src[2].cids[1] == c1,
    "the sources: the warehouse and the two bases; a base's stock is the containers within 150 m of its tower (" .. #src .. ")")
  local stock = CR.stockOf("b1")
  local by = {}
  for _, e in ipairs(stock) do by[e.key] = e end
  check(by["i:" .. wall] and by["i:" .. wall].n == 3 and by["m:steel"] and by["m:steel"].n == 300 and stock[1].kind == "item",
    "Kestrel Flats holds 3 crated walls and 300 kg of steel (the locker 400 m off is not its stock)")
  local lines = { { key = "i:" .. wall, n = 2 }, { key = "m:steel", n = 100 } }
  local B, why = CR.bill(2, "b1", lines)
  check(B ~= nil and near(B.dist, 600, 1) and B.same and near(B.kg, 100 + 2 * by["i:" .. wall].each, 1e-6) and B.fee == CR.quote(B.kg, B.dist, true).fee,
    B and string.format("the bill: %.0f kg over %.0f m: $%d, %s", B.kg, B.dist, B.fee, CR.etaLine(B.secs)) or tostring(why))
  local Bx, whyx = CR.bill(2, "b1", { { key = "m:steel", n = 900 } })
  check(Bx == nil and whyx:find("900 asked, 300 there", 1, true), "more than is there: " .. tostring(whyx))
  check(select(2, CR.bill(2, "b2", lines)) == "that is this base", "a base can't ship to itself")
  powered[1] = false
  local id0, w0 = CR.request(2, "b1", lines)
  check(id0 == nil and w0:find("no power", 1, true) and inv.count(c1, "steel") == 300, "the sender's tower dark: refused, nothing taken")
  powered[1] = true
  local bal0 = bal
  local id, w = CR.request(2, "b1", lines)
  check(id ~= nil and bal0 - bal == B.fee and inv.count(c1, "steel") == 200 and inv.itemCount(c1, wall) == 1,
    "sent: the fee paid, the goods out of the sender's locker at once (" .. tostring(w) .. ")")
  check(CR.inFlight(2) ~= nil and CR.inFlight(1) == nil and inv.count("courier:" .. id, "steel") == 100 and inv.itemCount("courier:" .. id, wall) == 2,
    "the pod is in flight to Leeward with 100 kg of steel and 2 crates aboard")
  local id2, w2 = CR.request(2, "home", { { key = "m:glass", n = 10 } })
  check(id2 == nil and w2:find("one at a time", 1, true), "a second pod to the same base waits: " .. tostring(w2))
  clock.a = clock.a + B.secs - 5
  check(CR.tick() == 0 and #drops == 0, "five seconds before its time: nothing lands")
  -- the save carries it
  local CR2 = load_script("courier.lua", env(X))
  CR2.start({ id = 4 })
  check(CR2.inFlight(2) ~= nil and near(CR2.inFlight(2).eta, 1000 + B.secs), "a pod in flight reads back from the save")
  clock.a = clock.a + 10
  check(CR2.tick() == 1 and #drops == 1 and CR2.inFlight(2) == nil, "on time: the pod is set down")
  local d = drops[1]
  local off = math.sqrt((d.x - 5000 - x2) ^ 2 + (d.y - y2) ^ 2 + (d.z - z2) ^ 2)
  check(d.body == "X" and off > 20 and off < 40 and d.label:find("Kestrel Flats", 1, true) and near(d.kg, B.kg, 1e-6),
    string.format("...by Leeward's tower (8 m off, dropped from 30 m: %.1f m), labelled from Kestrel Flats, %.0f kg", off, d.kg))
  check(inv.count("salvage:1", "steel") == 100 and inv.itemCount("salvage:1", wall) == 2 and SCR.feats.marks.shipment_received, "every kilogram and crate is in the crate; the feat is marked")
  -- RUNS CARRY CRATED PARTS (route_ops): a crate's move is in inventory's
  -- move ring as "@<item id>", traced through a pack like any cargo; a
  -- tool's is not (a crew's kit changing hands is not cargo)
  do
    local RT = load_script("routes.lua", env())
    inv.setCap("hold:Mule", 2000); inv.setCap("crew:1", 500)
    inv.addItem(c1, "repairkit", 1, { force = true })
    local s0 = inv.moveSeq
    inv.moveItem(c1, "crew:1", wall, 1, { force = true })
    inv.moveItem(c1, "crew:1", "repairkit", 1, { force = true })
    inv.moveItem("crew:1", "hold:Mule", wall, 1, { force = true })
    local mv = inv.movesSince(s0)
    check(#mv == 2 and mv[1].mat == "@" .. wall and mv[2].to == "hold:Mule", "a crated wall into a hold through the pack: two moves in the ring, the Repair Kit's none (" .. #mv .. ")")
    local got, led = {}, {}
    for _, m in ipairs(mv) do
      RT.ledger(led, m, function(c) return c == "hold:Mule" end, function(c) return c:sub(1, 5) == "crew:" end,
        function(mat, n, peer) got[#got + 1] = string.format("%+d %s %s", n, mat, peer) end)
    end
    check(got[1] == "+1 @" .. wall .. " " .. c1 and #got == 1, "...the flight log reads it as a load from the locker: " .. table.concat(got, " | "))
    SCR.crew = { get = function() return nil end }
    local RO = load_script("route_ops.lua", env(X))
    check(RO.itemOf("@" .. wall) == wall and RO.itemOf("iron") == nil, "route_ops knows a crated part from a material")
  end
  -- from the warehouse, between-worlds rate when the base is on another body
  local id3 = CR2.request(2, "home", { { key = "m:glass", n = 40 } })
  check(id3 ~= nil and inv.count("base", "glass") == 0, "the warehouse ships too (no tower to power)")
end

if #failures > 0 then
  print("smoke_courier FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print("smoke_courier: " .. passed .. " passed")
