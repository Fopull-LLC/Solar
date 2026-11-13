-- smoke_workbench: PARTS BY HAND AT A WORKBENCH (workbench.lua; playtest
-- 11-12b, work/baseloop/DESIGN.md phase 5).
--
--   • what a bench makes (the kit's pieces up to 150 kg, tools), what it
--     doesn't (a cable, a heavy machine, a part made at home only)
--   • the pace: an Engineer twice a hand's, practice up to half again; the
--     waste of a hand that is not an Engineer's
--   • a job: nobody at the bench → it waits; short stock → it says what;
--     the materials taken once, from the nearest stores; the clock by hand
--     (3 × the Fabricator's); the crate into the drawers; a step of any
--     length lands where many small ones do
--   • cancel gives a started job's materials back
--   • the scene half on real records: the stock round a bench (its drawers,
--     a locker 20 m off, not one 80 m off), the worker's pack, a wall made
--     from a locker's steel by an Engineer standing at the bench, the save
--
--   luajit solar/tests/smoke_workbench.lua        (from the Floptle repo root)
local failures, passed = {}, 0
local function check(ok, msg) if ok then passed = passed + 1 else failures[#failures + 1] = msg end end
local function near(a, b, e) return math.abs(a - b) <= (e or 1e-6) end
local store = {}
local T = { t = 100 }
local SCR = {}
local function env(extra)
  local E = setmetatable({
    save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end,
             delete = function(k) store[k] = nil end },
    findScript = function(k) return SCR[k] end, findScripts = function() return {} end,
    find = function(n) return n == "Astronaut" and SCR.__astro or nil end, log = function() end,
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
local WB = load_script("workbench.lua", env())

-- ── pure: what it makes, the pace, the waste ────────────────────────────────
local wall = { kit = true, label = "Wall" }
check(WB.makes(wall, { kg = 96, total = 96, mats = {} }) == true, "a 96 kg wall is bench work")
local ok, why = WB.makes(wall, { kg = 400, total = 400 })
check(not ok and why:find("Fabricator", 1, true), "400 kg is not: " .. tostring(why))
ok, why = WB.makes(wall, { kg = 2, total = 2, perMetre = true })
check(not ok and why:find("metre", 1, true), "a cable is laid by the metre: " .. tostring(why))
ok, why = WB.makes({ label = "Engine" }, { kg = 90, total = 90 })
check(not ok, "a VAB part wants a Fabricator: " .. tostring(why))
ok, why = WB.makes(wall, { kg = 50, total = 50, shipOnly = "the reactor works" })
check(not ok and why:find("home", 1, true), "made at home only stays so")
check(near(WB.paceOf(true, 0), 2.0) and near(WB.paceOf(false, 0), 1.0), "an Engineer works at twice a hand's pace")
check(near(WB.paceOf(false, 50), 1.25) and near(WB.paceOf(true, 100), 3.0) and near(WB.paceOf(true, 5000), 3.0), "practice: +25 % at 50 parts, +50 % at 100 and no more")
local r = { mats = { { mat = "steel", kg = 60 }, { mat = "wiring", kg = 5 } }, secs = 12, fittings = 20, kg = 96, total = 65 }
local nE, nH = WB.needOf(r, true), WB.needOf(r, false)
check(nE[1].kg == 60 and nE[2].kg == 5 and nH[1].kg == 66 and nH[2].kg == 6, "an Engineer wastes nothing; a hand takes 10 % more (66 and 6 kg)")
check(near(WB.secsOf(r), 36), "by hand: three times the Fabricator's 12 s")

-- ── pure: a job ─────────────────────────────────────────────────────────────
local function world(stock, worker)
  local W = { stock = stock, paid = 0, made = {}, worker = worker, takes = 0 }
  W.env = {
    recipe = function(id) return id == "wall.steel" and r or nil end,
    have = function(m) return W.stock[m] or 0 end,
    take = function(mats) W.takes = W.takes + 1; for _, e in ipairs(mats) do W.stock[e.mat] = (W.stock[e.mat] or 0) - e.kg end return true end,
    pay = function(f) if W.broke then return false end W.paid = W.paid + f; return true end,
    put = function(id) if W.full then return false end W.made[#W.made + 1] = id; return true end,
    worker = function() return W.worker end,
  }
  return W
end
do
  local W = world({ steel = 200, wiring = 20 }, nil)
  local B = { q = { { id = "wall.steel", n = 2, t = 0 } } }
  local why1, made = WB.advance(B, 10, W.env)
  check(made == 0 and why1:find("nobody at the bench", 1, true) and W.takes == 0, "nobody at the bench: it waits, nothing taken")
  W.worker = { id = 3, engineer = true, made = 0 }
  why1, made = WB.advance(B, 10, W.env)
  check(made == 0 and why1 == nil and W.takes == 1 and W.stock.steel == 140 and W.paid == 20 and near(B.q[1].t, 20),
    "an Engineer at it: the materials and the fittings taken once, 10 s is 20 s of work")
  why1, made = WB.advance(B, 8, W.env)
  check(made == 1 and #W.made == 1 and B.q[1].n == 1 and W.takes == 2, "8 s more: the first wall is made, the second begun (" .. tostring(B.q[1] and B.q[1].t) .. ")")
  why1, made = WB.advance(B, 100, W.env)
  check(made == 1 and #B.q == 0 and W.stock.steel == 80 and W.paid == 40, "the second: the queue is empty, 120 kg of steel and $40 spent")
  -- one long step = many short
  local Wa, Wb = world({ steel = 500, wiring = 50 }, { id = 1, engineer = false, made = 0 }), world({ steel = 500, wiring = 50 }, { id = 1, engineer = false, made = 0 })
  local Ba, Bb = { q = { { id = "wall.steel", n = 3, t = 0 } } }, { q = { { id = "wall.steel", n = 3, t = 0 } } }
  local _, ma = WB.advance(Ba, 100, Wa.env)
  local mb = 0
  for _ = 1, 400 do local _, m = WB.advance(Bb, 0.25, Wb.env); mb = mb + m end
  check(ma == 2 and mb == 2 and near(Ba.q[1].t, Bb.q[1].t, 1e-6) and Wa.stock.steel == Wb.stock.steel and Wa.stock.steel == 500 - 3 * 66,
    string.format("a hand, 100 s in one step or 400: 2 made and %.2f s into the third either way; 66 kg of steel a wall", Ba.q[1].t))
  -- short, broke, full
  local Ws = world({ steel = 30, wiring = 20 }, { id = 1, engineer = true, made = 0 })
  local Bs = { q = { { id = "wall.steel", n = 1, t = 0 } } }
  why1 = WB.advance(Bs, 5, Ws.env)
  check(why1 and why1:find("short of steel: 30 of 60 kg", 1, true) and Ws.takes == 0, "short stock says what: " .. tostring(why1))
  Ws.stock.steel = 100; Ws.broke = true
  why1 = WB.advance(Bs, 5, Ws.env)
  check(why1 and why1:find("fittings", 1, true) and Ws.takes == 0, "no money for the fittings: " .. tostring(why1))
  Ws.broke = false; Ws.full = true
  why1 = WB.advance(Bs, 500, Ws.env)
  check(why1 and why1:find("no room", 1, true) and Bs.q[1].done == true, "made, but nowhere to put it: it waits on the bench")
  Ws.full = false
  local _, m2 = WB.advance(Bs, 0, Ws.env)
  check(m2 == 1 and #Bs.q == 0, "...room made: it goes in")
  check(WB.queued({ q = { { n = 2 }, { n = 3 } } }) == 5, "the queue counts parts")
end

-- ── the scene half on real records ──────────────────────────────────────────
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
  local bodies = { X = { name = "X", x = 1000, y = 0, z = 0, radius = 800 } }
  local X = { space = { body = function(n) return bodies[n] end, dominant = function() return "X" end } }
  local ST = load_script("structures.lua", env(X))
  SCR.structures = ST
  local spent = 0
  SCR.company = { spend = function(v) spent = spent + v; return true end }
  local roles = { [1] = "engineer", [2] = "pilot" }
  local act = 1
  SCR.crew = { activeId = function() return act end, hasRole = function(id, r) return roles[id] == r end, roster = function() return {} end,
               credit = function() end, packOf = function(id) return "crew:" .. id end }
  SCR.planet_walker = { onFoot = true }
  SCR.feats = { marks = {}, mark = function(id) SCR.feats.marks[id] = (SCR.feats.marks[id] or 0) + 1 end }
  local R = SCR.recipes
  SCR.field_builder = {
    partInfo = PB.partInfo,
    recipeOf = function(id) local d = PB.partInfo(id); return d and R.recipeFor(d, d.section or "KIT", id) or nil end,
  }
  local WS = load_script("workbench.lua", env(X))
  SCR.workbench = WS
  WS.start({ id = 9 })
  local U, F = { x = 1, y = 0, z = 0 }, { x = 0, y = 0, z = 1 }
  local sid = ST.add(ST.newRecord(nil, "X", 800, 0, 0, U, F, "slab2.concrete"))
  local ub = ST.addPart(sid, { id = "workbench.steel", x = 0, y = 0.2, z = 0 })
  local ul = ST.addPart(sid, { id = "locker.steel", x = 0, y = 0.2, z = 20 })
  local sfar = ST.add(ST.newRecord(nil, "X", 800, 0, 80, U, F, "locker.steel"))
  check(PB.partInfo("workbench.steel") ~= nil and PB.partInfo("locker.steel") ~= nil and PB.partInfo("locker.steel").container ~= nil, "the Workbench and a Locker are real kit pieces (the locker holds things)")
  check(WS.isBench(sid, ub) and not WS.isBench(sid, ul), "a Workbench is a bench; a locker is not")
  local list = WS.stockOf(sid, ub)
  local has = {}
  for _, c in ipairs(list) do has[c] = true end
  check(list[1] == "piece:" .. sid .. ":" .. ub and has["piece:" .. sid .. ":" .. ul] and not has["piece:" .. sfar .. ":1"],
    "the stock: its own drawers first, the locker 20 m off, not the one 80 m off (" .. #list .. " stores)")
  -- (loot.lua gives a piece its capacity in the game; here by hand)
  inv.setCap("piece:" .. sid .. ":" .. ul, 400); inv.setCap("piece:" .. sfar .. ":1", 800); inv.setCap("piece:" .. sid .. ":" .. ub, 150)
  inv.add("piece:" .. sid .. ":" .. ul, "steel", 120)
  inv.add("piece:" .. sfar .. ":1", "steel", 500)
  check(WS.have(sid, ub, "steel") == 120, "120 kg of steel in reach (the far locker's 500 does not count)")
  local rw = WS.recipeOf("wall.steel")
  check(rw ~= nil and (rw.kg or 0) <= 150 and #rw.mats >= 1, "a steel wall has a bench recipe: " .. (rw and R.lineOf(rw) or "none"))
  check(WS.recipeOf("tool:repairkit") ~= nil and WS.recipeOf("powerCable") == nil, "a Repair Kit is bench work; a cable drum is not")
  local okq, whyq = WS.queue(sid, ub, "powerCable", 1)
  check(not okq and whyq ~= nil, "a cable is refused with a reason: " .. tostring(whyq))
  okq, whyq = WS.queue(sid, ub, "wall.steel", 1)
  check(okq and store["bench.list"][1] == sid .. "." .. ub, "a wall queued; the bench is on the active list (" .. tostring(whyq) .. ")")
  -- nobody there
  SCR.__astro = { valid = true, x = 1000 + 800, y = 0, z = 40 }
  WS.step(5)
  local _, _, s = WS.benchOf(sid, ub)
  check(s.duty == 0 and (s.fwhy or ""):find("nobody", 1, true), "the Engineer 40 m away: " .. tostring(s.fwhy))
  -- at the bench, with planks in the pack too
  SCR.__astro = { valid = true, x = 1000 + 800 + 0.9, y = 0.2 + 1.0, z = 0.5 }
  inv.add("astro", "steel", 7)
  check(WS.have(sid, ub, "steel") == 127, "at the bench the worker's pack joins the stock (127 kg)")
  local need = 0
  for _, m in ipairs(rw.mats) do if m.mat == "steel" then need = m.kg end end
  WS.step(1)
  _, _, s = WS.benchOf(sid, ub)
  check(near(s.duty, 2.0) and s.fwhy == nil and WS.have(sid, ub, "steel") == 127 - math.ceil(need - 1e-9),
    string.format("an Engineer at the bench: pace ×%.1f, %d kg of steel taken (nothing wasted), from the locker first", s.duty, math.ceil(need - 1e-9)))
  check(inv.count("astro", "steel") == 7, "...the pack is the last store drawn on")
  local secs = WS.secsOf(rw)
  WS.step(secs)
  local crate = R.partItemId("wall.steel")
  check(inv.itemCount("piece:" .. sid .. ":" .. ub, crate) == 1 and store["bench.list"][1] == nil and SCR.feats.marks.part_crafted == 1 and store["bench.made.1"] == 1,
    string.format("%.0f s of hand work at ×2: a crated wall in the bench's drawers, the feat, one part to the Engineer's name", secs))
  -- a Pilot makes a Repair Kit: waste, the item itself
  act = 2
  inv.add("piece:" .. sid .. ":" .. ul, "wiring", 10)
  inv.add("piece:" .. sid .. ":" .. ul, "steel", 250)
  local s0 = WS.have(sid, ub, "steel")
  WS.queue(sid, ub, "tool:repairkit", 1)
  WS.step(0.5)
  check(s0 - WS.have(sid, ub, "steel") == 4, "a Pilot's Repair Kit takes 4 kg of steel for the recipe's 3 (" .. (s0 - WS.have(sid, ub, "steel")) .. ")")
  WS.step(200)
  local got = inv.itemCount("piece:" .. sid .. ":" .. ub, "repairkit") + inv.itemCount("astro", "repairkit")
  check(got == 1, "...and the kit itself lands in the drawers (" .. got .. ")")
  -- THE PANEL: the Fabricator's RECIPE panel with the bench as its host
  do
    local made_tree = nil
    local el = { visible = false }
    local node = { getcomponent = function() return el end }
    SCR.field_builder.catalogue = function() return { { title = "WALLS", ids = { "wall.steel", "floor.steel", "powerCable" } } } end
    local FP = load_script("fab_panel.lua", env({ ui = { make = function(n, tree) made_tree = tree end }, input = { pressed = function() return false end } }))
    FP.start(node)
    local function text_of(t, out)
      out = out or {}
      if type(t) ~= "table" then return out end
      if type(t.text) == "string" then out[#out + 1] = t.text end
      for _, v in ipairs(t) do text_of(v, out) end
      for _, v in ipairs(t.items or {}) do text_of(v, out) end
      return out
    end
    check(FP.open(sid, ul, "bench") == false, "the panel won't open on a locker")
    act = 1
    check(FP.open(sid, ub, "bench") == true and FP.isOpen() and el.visible == true and FP.view.host == "bench", "it opens on the Workbench, hosted by the bench")
    FP.pick("wall.steel")
    FP.tick(0)
    T.t = T.t + 1; FP.tick(1)
    local all = table.concat(text_of(made_tree), " | ")
    check(all:find("WORKBENCH  ·  RECIPE", 1, true) and all:find("STOCK IN REACH", 1, true) and all:find("Repair Kit", 1, true) and all:find("Wall", 1, true),
      "its left plate: the bench's title, the stock in reach, the tools and the kit pieces")
    check(not all:find("Power Cable", 1, true), "...and no cable drum on the list")
    check(all:find("by hand", 1, true) and all:find("ON THE BENCH", 1, true) and all:find("an Engineer at work, pace ×2.0", 1, true),
      "its right plate: the hand's seconds, who is at the bench and their pace")
    local okp = FP.queueSel(1)
    check(okp == true and #WS.benchOf(sid, ub).q == 1 and WS.benchOf(sid, ub).q[1].id == "wall.steel", "Queue 1 puts a wall on the bench")
    WS.cancel(sid, ub, 1)
    FP.close()
    check(not FP.isOpen() and el.visible == false, "it closes")
  end
  -- cancel gives back
  WS.queue(sid, ub, "wall.steel", 1)
  WS.step(1)
  local mid = WS.have(sid, ub, "steel")
  WS.cancel(sid, ub, 1)
  check(WS.have(sid, ub, "steel") > mid and #WS.benchOf(sid, ub).q == 0, "a started job cancelled: its materials back in the stock")
  -- the save
  WS.queue(sid, ub, "wall.steel", 2)
  local WS2 = load_script("workbench.lua", env(X))
  WS2.start({ id = 10 })
  local B2 = WS2.benchOf(sid, ub)
  check(B2 and #B2.q == 1 and B2.q[1].n == 2, "the queue reads back from the save")
  -- the bench taken down: its queue goes
  ST.removeParts(sid, { ub })
  WS2.step(1)
  check(#(store["bench.list"] or {}) == 0, "the bench deconstructed: its queue is dropped")
end

if #failures > 0 then
  print("smoke_workbench FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print("smoke_workbench: " .. passed .. " passed")
