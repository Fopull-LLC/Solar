-- REPAIR BAY — the base's drive-in service shed (playtest 2026-11-02: "a
-- repair station building: park a craft inside, pay a cheap fee — it's your
-- own base — and get a full repair").
--
-- Runs on the FacRepair prefab's root (tools/gen_base.py, base_buildings
-- repair_bay()): an 11 × 15 m bay off Road East with an 8.4 m roll-up door,
-- lifts, a hoist, a tyre rack, a propellant dispenser and a charger, and the
-- service console just inside the door.
--
-- HOW IT GOES. Drive in, stop, get out. At the console (or anywhere in the
-- bay on foot) the prompt names the craft and the price; E (or a right-click
-- on the building) opens the work order — every line priced before anything
-- is spent:
--   * MEND: every worn part back to whole, wheels (the tyres) included —
--     `rate` of the part's price per unit of wear (vessel_controller
--     repairPart: the damage model's own mend, which repaints the wear);
--   * PROPELLANT: every tank topped up (tankList / fuelFill), `fuel_price` a
--     unit;
--   * CHARGE: the batteries filled (controlState / elecSetCharge),
--     `charge_price` an EC;
--   * GAS: the gas engines' tanks filled (gasState / gasFill), `gas_price`
--     a litre;
--   * REFIT: every part the craft LOST TO DAMAGE (broken off, torn away, or
--     shed with the mount that broke: vessel_controller lostParts) is built
--     again where its launch blueprint has it, in the craft's own frame, and
--     attached as a reload attaches it (refitParts), at `refit_rate` of the
--     part's price, each one on its own line. A stage you STAGED away is not
--     missing and is not refit; a part whose mount left with a stage or an
--     undock can't be, and the order says so. A refit part is new: whole, its
--     seats empty, its locker empty, its tanks and batteries EMPTY — and the
--     same order fills them, on the propellant and charge lines below.
-- Pressing "Service" runs the work as a timed job in the menu (sparks and the
-- clank of tools on the worn parts, a progress bar); walking away or driving
-- off calls it off, and only a finished job is paid for. Cheap on purpose:
-- this is the company's own shed, and a dented rover should cost a fraction
-- of its price to put right. (What is missing rides the fleet record, so a
-- craft brought in after a reload is refit the same.)
--
-- FRAMES (docs/positions-and-frames.md): which craft is in the bay is asked
-- in drawn poses only — the craft's origin by its node's toWorld, put into
-- the bay's frame by the bay node's toLocal, both this frame — and nothing
-- world is kept across frames. The prompt is a screen line, not a marker.
--
-- THE GAS PUMP (playtest 2026-11-03c) stands against the west wall: with a
-- Gas Can in hand, hold E at it to fill the can, `gas_price` a litre, paid
-- as each dollar's worth goes in (pumpTick; the cents carry over).
--
-- Pure parts (luajit, tests/smoke_base_works.lua): quote(work, prices),
-- inBay(lx, lz, …), orderLines(q), pumpTick(st, dt, room, funds, prices).

defaults = {
  --- the share of a part's price one full unit of wear costs to mend
  --@range 0 1
  rate = 0.12,
  --- $ per unit of propellant
  --@range 0 5
  fuel_price = 0.3,
  --- $ per EC of charge
  --@range 0 1
  charge_price = 0.02,
  --- $ per litre of gas (the work order and the pump)
  --@range 0 5
  gas_price = 0.6,
  --- litres a second the pump runs at
  --@range 0.2 5
  pump_rate = 1.2,
  --- how near the pump (m) a can is filled
  --@range 0.5 4 --@units m
  pump_reach = 1.4,
  --- the share of a part's price a REFIT costs (a part that broke off, built again)
  --@range 0 1
  refit_rate = 0.5,
  --- the most refit parts the order names one by one (the rest are summed on one line)
  --@range 1 20
  refit_lines = 6,
  --- the least an order costs when there is work at all ($)
  --@range 0 100
  min_fee = 10,
  --- EC/s the bay's charger feeds a serviced craft while it stays in the bay
  --@range 0 20
  float_rate = 5.0,
  --- the job's length: base seconds plus this per worn part, at most `secs_max`
  --@range 1 20
  secs = 4.0,
  --@range 0 5
  secs_part = 0.7,
  --@range 0 10
  secs_refit = 1.5,
  --@range 2 60
  secs_max = 14.0,
  --- how near the console (m) the prompt comes up (anywhere on the bay floor counts too)
  --@range 1 6 --@units m
  reach = 3.0,
}

-- The bay's floor in its own frame: x across, z along (the door at +z).
BAY = { hx = 5.25, hz = 7.30, top = 4.5 }

-- ── pure rules ──────────────────────────────────────────────────────────────

-- Is a point (bay-local) on the bay floor? lx, ly, lz relative to the floor
-- marker.
function inBay(lx, ly, lz, slack)
  slack = slack or 0
  return math.abs(lx) <= BAY.hx + slack and math.abs(lz) <= BAY.hz + slack and ly > -1.5 and ly < BAY.top
end

-- The work order. `work` = { parts = { { uid, hp, cost, label } }, fuel =
-- units short, charge = EC short, gas = litres short, refit = { { uid, cost, label, fuel, ec } }
-- (broken off, can go back on), lost = n (broken off, can't) }; `p` the
-- prices. A refit part's tanks and batteries come empty, so its `fuel` and
-- `ec` are added to the propellant and charge lines.
-- → { parts = n, mend = $, refit = n, refitCost = $, refits = { { uid,
--     label, cost } }, refitUids = { uid… }, fuel = units, fuelCost = $,
--     charge = EC, chargeCost = $, total = $, nothing = bool }
function quote(work, p)
  p = p or defaults
  local q = { parts = 0, mend = 0, fuel = 0, fuelCost = 0, charge = 0, chargeCost = 0, gas = 0, gasCost = 0, lost = work.lost or 0,
              refit = 0, refitCost = 0, refits = {}, refitUids = {} }
  local add_fuel, add_ec = 0, 0
  -- THE WRECK'S crewed part, rebuilt: its whole price (it is a new part)
  if work.wreck then q.wreck = { label = work.wreck.label or "crewed part", cost = work.wreck.cost or 20 } end
  for _, e in ipairs(work.refit or {}) do
    local c = (e.cost or 20) * (p.refit_rate or 0.5)
    q.refit = q.refit + 1
    q.refitCost = q.refitCost + c
    q.refits[#q.refits + 1] = { uid = e.uid, label = e.label or "part", cost = c }
    q.refitUids[#q.refitUids + 1] = e.uid
    add_fuel, add_ec = add_fuel + math.max(0, e.fuel or 0), add_ec + math.max(0, e.ec or 0)
  end
  local wheels = 0
  for _, e in ipairs(work.parts or {}) do
    local wear = math.max(0, 1 - (e.hp or 1))
    if wear > 0.001 then
      q.parts = q.parts + 1
      q.mend = q.mend + (e.cost or 20) * (p.rate or 0.12) * wear
      if e.wheel then wheels = wheels + 1 end
    end
  end
  q.wheels = wheels
  q.fuel = math.max(0, math.floor((work.fuel or 0) + add_fuel + 0.5))
  q.fuelCost = q.fuel * (p.fuel_price or 0.3)
  q.charge = math.max(0, math.floor((work.charge or 0) + add_ec + 0.5))
  q.chargeCost = q.charge * (p.charge_price or 0.02)
  -- gas to the tenth of a litre (a bike's tank is 4 L)
  q.gas = math.max(0, math.floor((work.gas or 0) * 10 + 0.5) / 10)
  q.gasCost = q.gas * (p.gas_price or 0.6)
  local sum = q.mend + q.refitCost + q.fuelCost + q.chargeCost + q.gasCost + (q.wreck and q.wreck.cost or 0)
  q.nothing = q.parts == 0 and q.refit == 0 and q.fuel < 1 and q.charge < 1 and q.gas < 0.1 and not q.wreck
  q.total = q.nothing and 0 or math.max(p.min_fee or 10, math.floor(sum + 0.5))
  return q
end

-- The order as rows of { label, value } for the menu and the probes.
function orderLines(q, money, most)
  money = money or function(v) return "$" .. tostring(math.floor(v + 0.5)) end
  most = most or defaults.refit_lines or 6
  local out = {}
  if q.wreck then out[#out + 1] = { "Rebuild  " .. q.wreck.label, money(q.wreck.cost) } end
  -- every refit part on its own line, the most costly first; past `most`, the
  -- rest summed on one
  local rs = {}
  for _, r in ipairs(q.refits or {}) do rs[#rs + 1] = r end
  table.sort(rs, function(a, b) if a.cost ~= b.cost then return a.cost > b.cost end return (a.uid or 0) < (b.uid or 0) end)
  local named = (#rs > most) and (most - 1) or #rs
  for i = 1, named do out[#out + 1] = { "Refit  " .. rs[i].label, money(rs[i].cost) } end
  if #rs > named then
    local c = 0
    for i = named + 1, #rs do c = c + rs[i].cost end
    out[#out + 1] = { string.format("Refit  %d more parts", #rs - named), money(c) }
  end
  if q.parts > 0 then
    out[#out + 1] = { string.format("Mend %d worn part%s%s", q.parts, q.parts == 1 and "" or "s",
      q.wheels > 0 and string.format(" (%d wheel%s)", q.wheels, q.wheels == 1 and "" or "s") or ""), money(q.mend) }
  end
  if q.fuel >= 1 then out[#out + 1] = { string.format("Propellant  %d u", q.fuel), money(q.fuelCost) } end
  if q.charge >= 1 then out[#out + 1] = { string.format("Charge  %d EC", q.charge), money(q.chargeCost) } end
  if (q.gas or 0) >= 0.1 then out[#out + 1] = { string.format("Gas  %.1f L", q.gas), money(q.gasCost) } end
  if (q.lost or 0) > 0 then
    out[#out + 1] = { string.format("%d lost part%s with no mount aboard: rebuild at the VAB", q.lost, q.lost == 1 and "" or "s"), "—" }
  end
  return out
end

-- THE PUMP's tick (pure): `st` = { owed = $ not yet paid }, held for dt with
-- `room` litres free in the cans in hand, `funds` the balance (nil: no
-- company). → litres to put in, whole dollars to pay now, and why it stops
-- (nil while it runs).
function pumpTick(st, dt, room, funds, p)
  p = p or defaults
  if (room or 0) <= 1e-6 then return 0, 0, "full" end
  local price = p.gas_price or 0.6
  local L = math.min(room, (p.pump_rate or 1.2) * math.max(0, dt or 0))
  if funds and funds < (st.owed or 0) + L * price then
    L = math.max(0, (funds - (st.owed or 0)) / math.max(price, 1e-9))
    if L <= 1e-6 then return 0, 0, "not enough funds" end
  end
  st.owed = (st.owed or 0) + L * price
  local pay = math.floor(st.owed)
  st.owed = st.owed - pay
  return L, pay, nil
end

-- ── in the world ────────────────────────────────────────────────────────────
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function valid(n) return n ~= nil and n.valid ~= false end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end

local ROOT = nil
local floor_l, console_l, pump_l = nil, nil, nil   -- marker points in the bay's own frame
pumped = 0            -- (probes) litres the pump has put in cans
pumping = false       -- (published) E held at the pump, filling
sim_pump = nil        -- (probes) true: E is held at the pump
atPump = false        -- (published) the crew is at the pump (its prompt is up)
inside = nil          -- (published) the craft in the bay: its controller handle
insideName = nil
lastQuote = nil       -- (probes) the order last priced
dbg = "idle"          -- (probes) where the update got to
lastJob = nil         -- (probes) "done $86" | "called off: …"
jobs = 0
-- THE FLOAT CHARGE. A serviced craft stays plugged into the bay's charger
-- until it leaves: its own parked draw (a probe core, idling wheel motors, a
-- radio: ~0.07 EC/s on the refit probe's rover) is fed from the shed, as a
-- real charger floats a battery, so the service leaves it full for as long
-- as it stands there, and the work order does not come back as a $10
-- minimum fee for a fraction of an EC a few seconds later. It feeds at most
-- `float_rate` EC/s over the time since it last fed (the bay is only
-- scanned with the crew within 300 m; the charger ran all along). It ends
-- when the craft is seen out of the bay.
float_id, float_t = nil, nil
floatFed = 0          -- (probes) EC the float charge has put in

local function child(n, name)
  for _, c in ipairs(n:children() or {}) do if c.name == name then return c end end
  return nil
end

-- THE BAY'S FRAME, built from the planet: the shed is parented to its
-- planet, so node.x/y/z ARE body-relative, and its axes are the same in any
-- pose (planets only translate). A world point is placed against the body
-- read in the same pass (space.body: this tick's), never kept. (node:toWorld
-- on a planet-parented node read ~a radius off on .1374: only its
-- DIFFERENCES are used, for the axes.)
local AX = nil
local function axes(node)
  if AX then return AX end
  local w0 = node:toWorld(vec3(0, 0, 0))
  local function d(x, y, z)
    local p = node:toWorld(vec3(x, y, z))
    local dx, dy, dz = p.x - w0.x, p.y - w0.y, p.z - w0.z
    local l = len(dx, dy, dz)
    return { x = dx / l, y = dy / l, z = dz / l }
  end
  AX = { x = d(1, 0, 0), y = d(0, 1, 0), z = d(0, 0, 1) }
  return AX
end
local function body_of(node)
  local p = node.parent
  return p and p.name and space.body(p.name) or nil
end
-- (probes too) a point in the shed's own frame → the world, now
function worldOf(lx, ly, lz)
  local node, b = ROOT, ROOT and body_of(ROOT)
  if not b then return nil end
  local A = axes(node)
  return b.x + node.x + A.x.x * lx + A.y.x * ly + A.z.x * lz,
         b.y + node.y + A.x.y * lx + A.y.y * ly + A.z.y * lz,
         b.z + node.z + A.x.z * lx + A.y.z * ly + A.z.z * lz
end
-- …and back: a world point (read this pass) → the shed's frame
function localOf(x, y, z)
  local node, b = ROOT, ROOT and body_of(ROOT)
  if not b then return nil end
  local A = axes(node)
  local dx, dy, dz = x - b.x - node.x, y - b.y - node.y, z - b.z - node.z
  return dx * A.x.x + dy * A.x.y + dz * A.x.z, dx * A.y.x + dy * A.y.y + dz * A.y.z, dx * A.z.x + dy * A.z.y + dz * A.z.z
end
-- A world point in the bay floor's frame.
local function bay_local(node, p)
  if not floor_l then return nil end
  local x, y, z = localOf(p.x, p.y, p.z)
  if not x then return nil end
  return x - floor_l[1], y - floor_l[2], z - floor_l[3]
end
-- Where a body is THIS TICK (the same tick as space.body): an assembly's
-- origin, else the body's tickPos.
local function tick_pos(n)
  local inf = assembly and assembly.info and assembly.info(n)
  if inf and inf.origin then return inf.origin end
  return n.tickPos or n.worldPos
end

-- The craft standing in the bay now, nearest its middle.
local function craft_in_bay(node)
  local best, bd = nil, math.huge
  for _, v in ipairs(findScripts and findScripts("vessel_controller") or {}) do
    local vn = v.node
    -- (a wreck counts when its crewed part is all it lost: vessel_controller
    -- wreckMendable; playtest 2026-11-12b, a crashed bike the bay ignored)
    if valid(vn) and (not (v.isLost and v.isLost()) or (v.wreckMendable and v.wreckMendable())) then
      local p = tick_pos(vn)
      local lx, ly, lz
      if p then lx, ly, lz = bay_local(node, p) end
      if lx and inBay(lx, ly, lz) then
        local d = lx * lx + lz * lz
        if d < bd then best, bd = v, d end
      end
    end
  end
  return best
end

-- How fast it is going over the ground.
local function ground_speed(v)
  local inf = assembly and assembly.info and assembly.info(v.node)
  if not (inf and inf.vel) then return 0 end
  -- (already in its SOI body's frame: a parked craft reads ~0)
  return len(inf.vel.x, inf.vel.y, inf.vel.z)
end

-- What the craft needs, read off its controller.
local function work_of(v)
  local w = { parts = {}, fuel = 0, charge = 0, lost = 0, refit = {} }
  -- a wreck: its broken crewed part rebuilt (unwreck), at its whole price
  local wm = v.isLost and v.isLost() and v.wreckMendable and v.wreckMendable()
  if wm then w.wreck = { uid = wm.uid, label = wm.label, cost = wm.cost } end
  for _, e in ipairs(v.damagedParts and v.damagedParts() or {}) do
    local rec = v.partRec and v.partRec(e.uid) or {}
    local id = tostring(rec.id or "")
    w.parts[#w.parts + 1] = { uid = e.uid, hp = e.hp, cost = rec.cost or 20, label = rec.label,
                              wheel = id:match("^wheel") ~= nil }
  end
  for _, t in ipairs(v.tankList and v.tankList() or {}) do w.fuel = w.fuel + math.max(0, (t.cap or 0) - (t.left or 0)) end
  local cs = v.controlState and v.controlState()
  if cs and cs.cap and cs.charge then w.charge = math.max(0, cs.cap - cs.charge) end
  local gs = v.gasState and v.gasState()
  if gs and (gs.cap or 0) > 0 then w.gas = math.max(0, gs.cap - (gs.left or 0)) end
  -- what broke off and can go back on; and what can't (its mount is gone too)
  if v.lostParts then
    local list, stuck = v.lostParts()
    local E = ref("electronics")
    for _, d in ipairs(list or {}) do
      local ec = 0
      for _, m in ipairs(E and E.modsOf and E.modsOf(d) or {}) do
        if m.type == "battery" then ec = ec + (m.ec or 0) end
      end
      w.refit[#w.refit + 1] = { uid = d.uid, cost = d.cost or 20, label = d.label or d.id or "part",
                                fuel = d.fuel or 0, ec = ec }
    end
    w.lost = stuck or 0
  end
  return w
end

-- Is `v` still the craft in the bay? (by its node: a controller handle from
-- findScripts is a fresh table each scan)
local function still_in(v)
  return inside ~= nil and valid(v.node) and valid(inside.node) and inside.node.id == v.node.id
end

local function money(v)
  local co = ref("company")
  return (co and co.money and co.money(v)) or ("$" .. math.floor(v + 0.5))
end

function quoteFor(v)
  if not v then return nil end
  local q = quote(work_of(v), params)
  lastQuote = q
  return q
end

-- Do the work (the job's end): mend, fill, charge, and pay. → ok, why
function service(v)
  if not (v and valid(v.node)) then return false, "the craft has gone" end
  local q = quoteFor(v)
  if q.nothing then return false, (v.craftName or "it") .. " needs nothing" end
  local co = ref("company")
  if co and co.afford and not co.afford(q.total) then return false, "not enough funds: " .. money(q.total) end
  if co and co.spend and not co.spend(q.total, "repair bay: " .. (v.craftName or "craft")) then
    return false, "not enough funds"
  end
  -- a wreck first: its crewed part rebuilt, and it is a craft again (the
  -- mend, refit and fills below refuse a lost craft)
  if q.wreck then
    local ok, why = v.unwreck and v.unwreck()
    if not ok then
      if co and co.earn then co.earn(q.total, "repair bay: wreck rebuild called off") end
      return false, "rebuild: " .. tostring(why or "this wreck can't be mended")
    end
  end
  local mended = 0
  for _, e in ipairs(v.damagedParts and v.damagedParts() or {}) do
    if v.repairPart and v.repairPart(e.uid, 1.0) then mended = mended + 1 end
  end
  -- the propellant and the charge last: a refit part's tanks and batteries
  -- are filled with the rest, once it is aboard
  local function fill(refit)
    if not valid(v.node) then return end
    local cap = 0
    for _, t in ipairs(v.tankList and v.tankList() or {}) do cap = cap + (t.cap or 0) end
    if cap > 0 and v.fuelFill then v.fuelFill(cap) end
    if v.gasFill then v.gasFill(math.huge) end
    -- FULL, by the batteries themselves: elecSetCharge shares what it is
    -- given over the batteries aboard by capacity and clamps each at full.
    -- Not by controlState().cap: that is the last 10 Hz power tick's sum, and
    -- a refit's rebuild (vessel_controller refitFinish → load_bp) zeroes it
    -- until the next tick, so after every refit the charge on the order was
    -- paid for and never put in, and the craft left the bay short: the
    -- "$10 top-up" offered again the moment the service finished. (Without
    -- the electronics rulebook a craft has no batteries to share: its pooled
    -- charge is set to the cap it reports.)
    if v.elecSetCharge then
      if ref("electronics") then
        v.elecSetCharge(math.huge)
      else
        local cs = v.controlState and v.controlState()
        if cs and cs.cap and cs.cap > 0 then v.elecSetCharge(cs.cap) end
      end
    end
    -- …and the charger stays on it while it sits in the bay (`float`)
    float_id, float_t = v.node.id, time or 0
    jobs = jobs + 1
    lastJob = string.format("done %s: %d parts mended, %d refit, %d u, %d EC, %.1f L gas", money(q.total), mended, refit, q.fuel, q.charge, q.gas or 0)
    if log then log("repair bay: " .. (v.craftName or "craft") .. " — " .. lastJob) end
    local fx = ref("sfx")
    if fx and fx.play then pcall(fx.play, "recover") end
  end
  if q.refit > 0 then
    local ok, why = false, "this craft can't be refit"
    if v.refitParts then ok, why = v.refitParts(q.refitUids, function(n) fill(n or 0) end) end
    if not ok then
      -- nothing was refit: the money goes back
      if co and co.earn then co.earn(q.total, "repair bay: refit called off") end
      lastJob = "refit refused: " .. tostring(why)
      return false, "refit: " .. tostring(why)
    end
    return true, string.format("%s serviced  ·  %d part%s refit  ·  %s", v.craftName or "Craft", q.refit,
      q.refit == 1 and "" or "s", money(q.total))
  end
  fill(0)
  return true, string.format("%s serviced  ·  %s", v.craftName or "Craft", money(q.total))
end

-- ── the work order (context_registry "prop": the bay building) ─────────────
local function is_ours(n)
  local k = 0
  while valid(n) and k < 4 do
    if ROOT and n.id == ROOT.id and n.name == ROOT.name then return true end
    n = n.parent
    k = k + 1
  end
  return false
end

local function near_ok(ctx)
  local a = ctx and ctx.actor
  if not (a and a.kind == "crew" and valid(a.node) and ROOT) then return false, "on foot, in the bay" end
  local lx, ly, lz = bay_local(ROOT, tick_pos(a.node))
  if lx and inBay(lx, ly, lz, 1.5) then return true end
  return false, "walk into the bay"
end

local function provider(t, ctx)
  if not (t and is_ours(t.node)) then return {} end
  local out = {}
  local v = inside
  if not (v and valid(v.node)) then
    out[#out + 1] = { type = "info", id = "bay", label = "BAY", value = "empty — drive a craft in and stop" }
    return out, "REPAIR BAY", "the base's service shed"
  end
  local q = quoteFor(v)
  out[#out + 1] = { type = "info", id = "craft", label = "CRAFT", value = v.craftName or "craft" }
  local worst = 1
  for _, e in ipairs(v.damagedParts and v.damagedParts() or {}) do worst = math.min(worst, e.hp) end
  out[#out + 1] = { type = "meter", id = "cond", label = "WORST PART", frac = worst,
    value = q.parts > 0 and string.format("%d%%  ·  %d worn", math.floor(worst * 100 + 0.5), q.parts) or "all whole",
    warn = worst < 0.5 }
  if q.wreck then
    out[#out + 1] = { type = "info", id = "wreck", label = "WRECKED", warn = true,
      value = q.wreck.label .. " broken: the bay rebuilds it" }
  end
  if q.refit + (q.lost or 0) > 0 then
    out[#out + 1] = { type = "info", id = "missing", label = "MISSING", warn = true,
      value = string.format("%d part%s broken off", q.refit + q.lost, q.refit + q.lost == 1 and "" or "s") }
  end
  if q.nothing then
    out[#out + 1] = { type = "info", id = "ok", label = "", value = "in good order: nothing to do" }
    return out, "REPAIR BAY", "work order"
  end
  for i, l in ipairs(orderLines(q, money, params.refit_lines)) do
    out[#out + 1] = { type = "info", id = "line" .. i, group = "WORK ORDER", label = l[1], value = l[2] }
  end
  out[#out + 1] = { type = "info", id = "total", group = "WORK ORDER", label = "TOTAL", value = money(q.total) }
  local secs = math.min(params.secs_max, params.secs + params.secs_part * q.parts + params.secs_refit * (q.refit + (q.wreck and 2 or 0)))
  local spark_t = 0
  out[#out + 1] = { type = "action", id = "service", group = "WORK ORDER",
    label = string.format("Service  ·  %s", money(q.total)), hint = string.format("%.0f s", secs),
    enabled = function()
      local co = ref("company")
      if co and co.afford and not co.afford(q.total) then return false end
      return (near_ok(ctx)) and still_in(v) and ground_speed(v) < 0.6
    end,
    why = function()
      local co = ref("company")
      if co and co.afford and not co.afford(q.total) then return "not enough funds: " .. money(q.total) end
      local ok, why = near_ok(ctx)
      if not ok then return why end
      if not still_in(v) then return "the craft has left the bay" end
      return "stop the craft first"
    end,
    job = { secs = secs, label = "Servicing " .. (v.craftName or "the craft"),
      check = function()
        if not (valid(v.node) and still_in(v)) then return false, "the craft left the bay" end
        if ground_speed(v) > 0.8 then return false, "the craft moved" end
        local ok, why = near_ok(ctx)
        if not ok then return false, why end
        return true
      end,
      tick = function(dt, frac)
        spark_t = spark_t - (dt or 0)
        if spark_t > 0 then return end
        spark_t = 0.45
        local list = v.damagedParts and v.damagedParts() or {}
        local gone = v.lostParts and (v.lostParts()) or {}
        local x, y, z
        local k = math.random(1, math.max(1, #list + #gone))
        if k > #list and gone[k - #list] and v.commandUid and v.partPointNow then
          -- where a missing part goes: its blueprint point, through the
          -- command part's frame this tick (the craft's axes)
          local d, cu = gone[k - #list], v.commandUid()
          local c = cu and v.partRec and v.partRec(cu)
          if c then x, y, z = v.partPointNow(cu, (d.x or 0) - (c.x or 0), (d.y or 0) - (c.y or 0), (d.z or 0) - (c.z or 0)) end
        else
          local e = list[k]
          if e and v.partPointNow then x, y, z = v.partPointNow(e.uid, 0, 0, 0) end
        end
        if not x and valid(v.node) then local p = tick_pos(v.node); x, y, z = p.x, p.y, p.z end
        if x and spawnEffect then pcall(spawnEffect, "Sparks", x, y, z) end
        local fx = ref("sfx")
        if fx and fx.playAt then pcall(fx.playAt, "knock", v.node, 0.6) end
      end,
      done = function()
        local ok, why = service(v)
        if ctx and ctx.toast then ctx.toast(why, not ok) end
        return ok, why
      end,
      cancel = function() lastJob = "called off" end } }
  return out, "REPAIR BAY", "work order  ·  " .. (v.craftName or "craft")
end

-- ── the prompt and E ────────────────────────────────────────────────────────
local function crew_afoot()
  local pw = ref("planet_walker")
  if not (pw and pw.onFoot == true) then return nil end
  local a = find and find("Astronaut")
  return valid(a) and a or nil
end
local function blocked()
  for _, k in ipairs({ "pause_menu", "inventory_panel" }) do
    local s = ref(k)
    if s and s.open then return true end
  end
  local cm = ref("context_menu")
  if cm and cm.isOpen and cm.isOpen() then return true end
  local fm = ref("facility_menu")
  if fm and fm.isOpen and fm.isOpen() then return true end
  return false
end
local function interact_pressed()
  if input.pressed("e") then return true end
  return input.justPressed ~= nil and input.justPressed("Interact") == true
end

prompt = nil          -- (published) the line on screen, or nil
function prompting() return prompt ~= nil end

-- THE GAS PUMP: the crew at it (bay-floor frame lx, ly, lz) → true when it
-- has the prompt. With a Gas Can in hand, E held fills it.
local pump_st, pump_snd_t = nil, 0
function pumpAt(lx, ly, lz, dt)
  local px, py, pz = pump_l[1] - floor_l[1], pump_l[2] - floor_l[2], pump_l[3] - floor_l[3]
  if len(lx - px, (ly - py) * 0.5, lz - pz) > (params.pump_reach or 1.4) then return false end
  atPump = true
  local H, V = ref("item_hand"), ref("inventory")
  local price = params.gas_price or 0.6
  local tag = string.format("GAS PUMP  ·  $%.2f a litre", price)
  local n = V and V.itemCount and V.itemCount("astro", "gascan") or 0
  if n <= 0 then
    prompt = tag .. "  ·  no Gas Can in the pack (the depot sells them)"
    return true
  end
  if not (H and H.held and H.held() == "gascan") then
    prompt = tag .. "  ·  take the Gas Can in hand to fill it"
    return true
  end
  local fl = V.fills and V.fills("astro", "gascan") or {}
  local have, cap = 0, 0
  local I = ref("items")
  local fc = (I and I.fillCap and I.fillCap("gascan")) or 10
  for _, f in ipairs(fl) do have, cap = have + f, cap + fc end
  local held_e = sim_pump == true or (input.key and input.key("e") == true)
  if held_e then
    pump_st = pump_st or { owed = tonumber(save.get("repair.pumpOwed")) or 0 }
    local co = ref("company")
    local funds = (co and co.balance) and co.balance() or nil
    local L, pay, why = pumpTick(pump_st, dt or 0, cap - have, funds, params)
    if pay > 0 and co and co.spend then co.spend(pay, "gas pump") end
    if L > 0 and V.addFill then
      local put = V.addFill("astro", "gascan", L)
      pumped = pumped + put
      have = have + put
      pumping = true
    end
    save.set("repair.pumpOwed", pump_st.owed)
    if why == "full" then prompt = string.format("GAS PUMP  ·  the can%s full  ·  %.1f / %.0f L", n > 1 and "s are" or " is", have, cap)
    elseif why then prompt = "GAS PUMP  ·  " .. why
    else prompt = string.format("GAS PUMP  ·  filling  ·  %.1f / %.0f L", have, cap) end
  else
    prompt = string.format("E (hold)   Fill the Gas Can  ·  %.1f / %.0f L  ·  $%.2f a litre", have, cap, price)
  end
  -- the pump's motor while it runs
  if pumping and audio and audio.play and pump_snd_t < (time or 0) then
    pump_snd_t = (time or 0) + 0.9
    pcall(audio.play, "audio/foley/servo_short.ogg", { track = "SFX", volume = 0.35, pitch = 0.7 })
  end
  return true
end

-- Open the work order (E at the console; probes).
function openOrder()
  local cm = ref("context_menu")
  if not (cm and cm.openFor and ROOT) then return false end
  local x, y, z = worldOf(console_l and console_l[1] or 0, (console_l and console_l[2] or 0) + 1.4, console_l and console_l[3] or 0)
  return cm.openFor({ kind = "prop", node = ROOT, label = "Repair Bay", wx = x, wy = y, wz = z })
end

local provider_on = false
local look_t, scan_t = -10, -10

function start(node)
  ROOT = node
  floor_l, console_l = nil, nil
end

function update(node, dt)
  ROOT = node
  if not provider_on then
    local reg = ref("context_registry")
    if reg and reg.register then
      reg.register("prop", provider, { id = "repair_bay", order = 4 })
      provider_on = true
    end
  end
  if not floor_l and (time or 0) - look_t > 0.5 then
    look_t = time or 0
    local f, c, g = child(node, "Bay Floor"), child(node, "Repair Console"), child(node, "Gas Pump")
    if f then floor_l = { f.x, f.y, f.z } end
    if c then console_l = { c.x, c.y, c.z } end
    if g then pump_l = { g.x, g.y, g.z } end
  end
  if not floor_l then dbg = "no floor marker" return end
  local a = crew_afoot()
  -- which craft is in, four times a second (and only with someone about)
  local any = a or (findScripts and #findScripts("vessel_controller") > 0)
  if any and (time or 0) - scan_t > 0.25 then
    scan_t = time or 0
    local near = true
    local who = a or find and find("Astronaut")
    if valid(who) then
      local p = tick_pos(who)
      local lx, ly, lz = localOf(p.x, p.y, p.z)
      near = lx ~= nil and len(lx, ly, lz) < 300
    end
    inside = near and craft_in_bay(node) or nil
    insideName = inside and inside.craftName or nil
    if float_id and near then
      local v = inside
      if v and valid(v.node) and v.node.id == float_id then
        local now = time or 0
        local cs = v.controlState and v.controlState()
        local short = (cs and cs.cap and cs.charge and cs.cap > 0) and (cs.cap - cs.charge) or 0
        if short > 1e-3 and v.elecSetCharge then
          local put = math.min(short, (params.float_rate or 5) * math.max(0, now - (float_t or now)))
          if put > 0 then v.elecSetCharge(cs.charge + put); floatFed = floatFed + put end
        end
        float_t = now
      else
        float_id, float_t = nil, nil    -- it has left the bay
      end
    end
    dbg = string.format("scan: near %s, %d craft, inside %s", tostring(near),
      #(findScripts and findScripts("vessel_controller") or {}), tostring(insideName))
  end
  prompt = nil
  pumping = false
  atPump = false
  if not a or blocked() then return end
  local lx, ly, lz = bay_local(node, tick_pos(a))
  if not lx then return end
  if pump_l and pumpAt(lx, ly, lz, dt) then return end
  local at_console = false
  if console_l then
    local cx, cy, cz = lx - (console_l[1] - floor_l[1]), ly - (console_l[2] - floor_l[2]), lz - (console_l[3] - floor_l[3])
    at_console = len(cx, cy * 0.5, cz) < params.reach
  end
  if not (at_console or inBay(lx, ly, lz, 0.5)) then return end
  if inside and valid(inside.node) then
    local q = quoteFor(inside)
    if q.nothing then
      prompt = string.format("REPAIR BAY  ·  %s is in good order", inside.craftName or "the craft")
    elseif ground_speed(inside) > 0.6 then
      prompt = string.format("REPAIR BAY  ·  %s  ·  stop the craft to service it", inside.craftName or "craft")
    else
      prompt = string.format("E   Service %s  ·  %s", inside.craftName or "the craft", money(q.total))
    end
  else
    prompt = "REPAIR BAY  ·  drive a craft in and stop to service it"
  end
  if at_console or inside then
    if interact_pressed() then openOrder() end
  end
end

-- ── the line on screen ──────────────────────────────────────────────────────
local function uiH()
  local st = ref("settings")
  return (st and st.designHeight and st.designHeight()) or 720
end
local function chars(s)
  local _, n = s:gsub("[^\128-\191]", "")
  return n
end
function lateUpdate(node, dt)
  if not (prompt and camera and camera.screenRect and draw and draw.text) then return end
  local pc = ref("planet_camera")
  if pc and pc.cinematic == true then return end
  local vx, vy, vw, vh = camera.screenRect()
  if not vw or vw <= 0 then return end
  local k = vh / uiH()
  local size = 16 * k
  local w = chars(prompt) * size * 0.5 + size
  local h = size * 1.5
  local x, y = vx + vw * 0.5, vy + vh * 0.70
  draw.rect(x - w / 2, y - h / 2, w, h, 0.05, 0.03, 0.02, 0.66, size * 0.35)
  draw.text(x, y - size * 0.62, prompt, size, 1.0, 0.86, 0.62, 1.0, "center")
end
