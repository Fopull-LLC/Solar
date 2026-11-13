-- BASE_ECONOMY — what a part placed in the world costs (deep-space addendum
-- N1, Q16, Q18, Q22; docs/base-building.md).
--
-- A pure rulebook on the Build Kit node: no scene access; its globals are its
-- API and it loads from disk in a luajit test (tests/smoke_base_build.lua).
--
-- THE ONE SENTENCE: on the home world a part is BOUGHT and TRUCKED OUT;
-- anywhere else it is made from what you dug up (N2, step 13).
--
--   HOME   the part's price (the same REG cost the VAB charges at launch)
--          plus SHIPPING, 10 % + $50, paid AT PLACEMENT (Q18) to the section's
--          supplier, and in the ledger as "shipped by <supplier>". The VAB
--          keeps charging at launch with no fee: that is the agency's yard.
--   UNDO   for 60 s after it was placed, taking a part back refunds all of it,
--          fee included (Q18). Later it is a deconstruct (step 5, K10): the
--          part's price back, the fee kept (the truck already drove out).
--   FOOTING a part set on sloping ground stands on a cast concrete footing
--          (step 5, K7): its concrete is billed with the part, FOOTING_RATE a
--          cubic metre (ready-mix, poured). Taking the part down later returns
--          the part's price only: the fee and the concrete are kept.
--   AWAY   (expansion X4, N2/N8) a part is a CRATED PART, an item of kind
--          "part" (items.lua, recipes.lua), drawn from any container within
--          30 m of the Engineer, nearest first, the pack last (Q16,
--          `containersInReach`); nothing to pay but a footing's concrete. No
--          crated part in reach: the card says what a Fabricator would make
--          it from (recipes.recipeFor: refined materials + fittings, Q22) and
--          placing is refused with the reason. Fabricators are X6.
--   CRATED (X4) on the home world a part can be ordered CRATED instead of
--          placed (K in the Build Kit): the same price + shipping, and the
--          crate is loaded into the nearest container in reach with room.

SHIP = { rate = 0.10, flat = 50 }
local R_ref = nil
UNDO_SECS = 60
FOOTING_RATE = 160      -- $ a cubic metre of footing concrete, poured
FITTINGS = 0.20
REACH = 30.0

-- One supplier per section (flavour, in the ledger and on the card).
SUPPLIERS = {
  PROPULSION = "Marrow & Vance Propulsion", COMMAND = "Marrow & Vance Propulsion",
  STRUCTURE = "Halden Structural", FRAME = "Halden Structural", PAYLOAD = "Teller Tankage",
  ELECTRICAL = "Orbis Electrics", NUCLEAR = "Orbis Electrics", AIRCRAFT = "Kestrel Airframes",
  ROVER = "Burrow Automotive", ROBOTICS = "Lindqvist Robotics", BASE = "Pell Groundworks",
}
function supplierOf(section) return SUPPLIERS[section or ""] or "Halden Structural" end

function money(v)
  v = math.floor((v or 0) + 0.5)
  local s, out = tostring(math.abs(v)), ""
  while #s > 3 do out = "," .. s:sub(-3) .. out; s = s:sub(1, -4) end
  return (v < 0 and "−$" or "$") .. s .. out
end

function shipping(cost)
  cost = math.max(0, cost or 0)
  return math.floor(cost * SHIP.rate + SHIP.flat + 0.5)
end

-- What placing part `def` (of `section`) on `body` costs, when `home` is the
-- home world's name. `opts` (off the home world): { crated = n crated parts
-- in reach, from = the nearest one's container label, recipe = its recipe }.
-- → quote:
--   { mode = "money", cost, ship, total, supplier }       on the home world
--   { mode = "item", n, from, foot, total = foot }        off it, a crate in reach
--   { mode = "away", why, fittings, recipe }              off it, none in reach
function quote(def, section, body, home, footVol, opts)
  if not def then return { mode = "none", why = "no such part" } end
  local cost = math.floor(def.cost or 0)
  local foot = footingCost(footVol)
  if body ~= nil and home ~= nil and body ~= home then
    local n = opts and opts.crated or 0
    local r = opts and opts.recipe or nil
    if n > 0 then
      return { mode = "item", n = n, from = opts.from, cost = 0, ship = 0, foot = foot, total = foot, recipe = r }
    end
    local fit = (r and r.fittings) or math.floor(cost * FITTINGS + 0.5)
    return { mode = "away", fittings = fit, cost = cost, recipe = r,
             why = string.format("no crated %s within %.0f m: order one crated at home (K with it in hand) and bring it in a hold",
               def.label or "part", REACH) }
  end
  -- (playtest 11-12b: "I don't want to … buy everything with money") AT HOME
  -- TOO a crate in reach is what gets placed: a part made at a Workbench or
  -- a Fabricator, or shipped in, costs nothing more than its footing
  if opts and (opts.crated or 0) > 0 then
    return { mode = "item", n = opts.crated, from = opts.from, cost = 0, ship = 0, foot = foot, total = foot, recipe = opts.recipe, own = true }
  end
  -- (progression W1) a timber piece at home: the warehouse's planks pay for
  -- its wood when it holds enough (`opts.planks` kg), and only its fittings
  -- and hardware are bought (parts_kit `fit`: nails, bolts, brackets, a
  -- mast's whip): no truck drives out. With too few it ships ready-cut.
  if def.planks and def.fit and opts and (opts.planks or 0) >= def.planks then
    return { mode = "money", cost = def.fit, ship = 0, foot = foot, total = def.fit + foot, planks = def.planks,
             supplier = "your own planks" }
  end
  local ship = shipping(cost)
  return { mode = "money", cost = cost, ship = ship, foot = foot, total = cost + ship + foot, supplier = supplierOf(section) }
end

-- What a footing of `vol` cubic metres costs (0 for none).
function footingCost(vol)
  if not vol or vol <= 0 then return 0 end
  return math.floor(vol * FOOTING_RATE + 0.5)
end

-- The card's two lines: the price ("$990") and the breakdown
-- ("$900 + $140 shipping · Pell Groundworks").
function cardLines(q)
  if not q then return nil, nil end
  if q.mode == "money" and q.planks then
    return money(q.total), string.format("%d kg of your planks + %s fittings%s", q.planks, money(q.cost),
      (q.foot or 0) > 0 and (" + " .. money(q.foot) .. " footing") or "")
  end
  if q.mode == "money" then
    return money(q.total), string.format("%s + %s shipping · %s", money(q.cost), money(q.ship), q.supplier)
  end
  if q.mode == "item" then
    return string.format("%d crated", q.n or 0), "in reach" .. (q.from and (" · " .. q.from) or "") ..
      ((q.foot or 0) > 0 and (" · " .. money(q.foot) .. " footing") or "")
  end
  if q.mode == "away" then
    -- (kept: every card of the column asks, and findScript walks the scene)
    if not (R_ref and R_ref.valid ~= false) then R_ref = findScript and findScript("recipes") or nil end
    local R = R_ref
    local line = (q.recipe and R and R.lineOf) and R.lineOf(q.recipe) or ("materials + " .. money(q.fittings) .. " fittings")
    return "no crate", (q.recipe and q.recipe.shipOnly) and ("made at home only · " .. q.recipe.shipOnly) or ("made of " .. line)
  end
  return nil, q.why
end

-- (X4) What ordering part `def` CRATED at home costs: the price + shipping,
-- as placing it would (no footing: it isn't set down). → quote (mode "money")
function crateQuote(def, section)
  if not def then return { mode = "none", why = "no such part" } end
  local cost = math.floor(def.cost or 0)
  local ship = shipping(cost)
  return { mode = "money", cost = cost, ship = ship, foot = 0, total = cost + ship, supplier = supplierOf(section) }
end
function crateLedgerWhy(label, q)
  return string.format("%s, crated · %s + %s shipping (shipped by %s)", label or "part", money(q.cost), money(q.ship), q.supplier)
end

-- The ledger's line for a placement.
function ledgerWhy(label, q)
  local foot = (q.foot or 0) > 0 and (" + " .. money(q.foot) .. " footing") or ""
  if q.planks then
    return string.format("%s · %s fittings%s (%d kg of the warehouse's planks)", label or "part", money(q.cost), foot, q.planks)
  end
  return string.format("%s · %s + %s shipping%s (shipped by %s)", label or "part", money(q.cost), money(q.ship), foot, q.supplier)
end

-- May the placement `rec` (a structure record with `paid` = { total, t }) be
-- undone at agency time `now` for a full refund? → amount | nil, why
function undoRefund(rec, now)
  local p = rec and rec.paid
  if type(p) ~= "table" then return nil, "nothing was paid for it" end
  local age = (now or 0) - (p.t or -1e9)
  if age > UNDO_SECS + 1e-6 then
    return nil, string.format("placed %.0f s ago: only the last %d s can be undone (deconstruct it instead)", age, UNDO_SECS)
  end
  if age < -1 then return nil, "placed in the future (a clock reset)" end
  return math.floor(p.total or 0), nil
end

-- K10: what taking a placed part down returns, from its `paid` record at
-- agency time `now`: within UNDO_SECS all of it (the undo rule), later the
-- part's price only (the shipping fee and the footing are kept: the truck
-- drove out, the concrete is broken up). → amount, rule ("full" | "price")
function deconstructRefund(paid, now)
  if type(paid) ~= "table" then return 0, "price" end
  local age = (now or 0) - (paid.t or -1e9)
  if age <= UNDO_SECS + 1e-6 and age >= -1 then return math.floor(paid.total or 0), "full" end
  return math.floor(paid.cost or 0), "price"
end

-- Q16: the containers within REACH of (x, y, z), nearest first, the pack
-- last. `list` = { { id, x, y, z, pack = bool } … } (world points, same
-- read), or { { id, d } … } with the distance already measured (X4: the
-- field builder measures node to node, `node:distanceTo`). → { id … }
function containersInReach(list, x, y, z, reach)
  reach = reach or REACH
  local near, pack = {}, {}
  for _, c in ipairs(list or {}) do
    if c.pack then pack[#pack + 1] = c.id
    else
      local d = c.d or math.sqrt((c.x - x) ^ 2 + (c.y - y) ^ 2 + (c.z - z) ^ 2)
      if d <= reach then near[#near + 1] = { id = c.id, d = d } end
    end
  end
  table.sort(near, function(a, b) if a.d ~= b.d then return a.d < b.d end return tostring(a.id) < tostring(b.id) end)
  local out = {}
  for _, e in ipairs(near) do out[#out + 1] = e.id end
  for _, id in ipairs(pack) do out[#out + 1] = id end
  return out
end
