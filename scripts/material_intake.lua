-- MATERIAL INTAKE — the Commerce Depot's bulk feed conveyor (playtest
-- 2026-11-02: "a material processing drop-off at the base … belts run into a
-- hole in the wall; drop rocks, debris, logs onto it, it pulls them in, and
-- they are converted into resources and money").
--
-- Runs on the FacIntake prefab's root (tools/gen_base.py, base_buildings
-- intake()): a rust-red shed on the depot's west side whose feed belt runs
-- 10.9 m out of a hole in its front wall, under a steel hood hung with rubber
-- curtain strips, to a tail hopper on the Intake Yard. Anything loose that
-- lands on the belt — tipped off a truck bed, dropped or pushed with the
-- gravity gun, rolled off a hillside — is CARRIED by the belt and TAKEN as it
-- passes behind the curtain:
--
--   * a resource body (a log, a rock, a chunk, a boulder: anything tagged
--     the way docs/resources.md says, materials.resourceOf — "resource",
--     "mat:<id>", "qty:<n>") goes in as what it is:
--       - ORE, TIMBER, anything that isn't bulk → the warehouse ("base"),
--         counted as FREIGHT (facility_menu FREIGHT_RATE: it sells for 30 %
--         more than pack-carried goods, and a delivery contract counts it);
--       - BULK rock and soil (materials.grade "bulk": the spoil a tunnel
--         makes) is sold on the spot by weight, at the depot's price
--         (facility_menu.depotSell: freight, standing and contracts' holds
--         all apply) — aggregate is bought by the tonne, not stored;
--   * a body with no tags yet (an older save's loose log or rock, a knocked
--     chunk tool_belt priced) by its prefab's kind or tool_belt.worthOf;
--   * WRECKAGE (anything else the gun can lift that isn't a craft or the
--     crew: a sheared-off part, a lost craft's hull) is recycled for scrap
--     money by weight, capped (`scrap_rate`, `scrap_cap`; a lost craft's at a
--     share of what its parts were worth, so crashing a hull never pays);
--   * the base's own cargo cans and crates are returned to stores: no money
--     (they are the depot's stock, and the yard is restocked every load).
--
-- Nothing else is touched: a craft (its controller has a craftName and it is
-- not lost), the crew, a relay beacon or a flag are neither carried nor
-- taken, so a truck parked alongside — or one whose bed hangs over the belt —
-- is safe, and so is an astronaut walking on it.
--
-- THE BELT IS PHYSICAL. In fixedUpdate every loose body over the belt that
-- TOUCHES it is gripped as friction grips: the slip of its foot (the centre
-- of mass's velocity plus the spin's) is taken out at the foot through its
-- mass and inertia, limited to `accel`, with a rolling and twisting drag,
-- and eased toward the middle (grip() below); it rides, slides and tumbles
-- at a transfer like a load on a belt, and never spins up. All in TICK poses (docs/positions-and-frames.md rule
-- 2): the bodies' assembly.info against this tick's space.body, and the belt
-- itself as body-relative geometry (the shed is parented to its planet, so
-- its node.x/y/z ARE body-relative and its axes never change). The belt's
-- cleats scroll with the same speed (shaders/conveyor_belt.flsl `phase`).
--
-- THE RECEIPT. Every take is a line on the board over the hood (drawn in
-- lateUpdate at the "Intake Board" marker, placed against the planet's drawn
-- position this frame),
-- a line under the screen's middle for a few seconds, and the cash sound
-- when money comes in. `receipts` (newest first) and `totals` are published.
--
-- Pure parts (luajit, tests/smoke_intake.lua): classify, quoteScrap,
-- receiptText, beltLocal.

defaults = {
  --- belt speed (m/s, toward the hole)
  --@range 0 3 --@units m/s
  speed = 0.9,
  --- the most the belt can change a load's speed (m/s²). It must beat the
  --- solver's own friction against the (static) belt box, which the load's
  --- rubbing material sets, so it is a grip, not μg
  --@range 0.5 60
  accel = 20.0,
  --- scrap money for wreckage, $ per kg
  --@range 0 2
  scrap_rate = 0.25,
  --- the most one piece of wreckage pays ($)
  --@range 10 2000
  scrap_cap = 300,
  --- a lost craft's hull pays at most this share of its parts' worth
  --@range 0 1
  wreck_share = 0.25,
  --- the belt runs (and the board shows) while the crew is this near (m)
  --@range 50 1000 --@units m
  near = 220,
  --- 0 turns the belt off
  --@range 0 1
  enabled = 1,
}

-- ── pure rules ──────────────────────────────────────────────────────────────

-- What a body IS to the intake, from a description of it:
--   d = { tags = {…}, name, mass (t), scale, crew, craft, lost, wreckValue,
--         res = { mat, qty } (materials.resourceOf), worth = { mat, n, label }
--         (tool_belt.worthOf), grade = fn(mat) → "bulk" | …, label = fn(mat) }
-- → { kind = "mat", mat, qty, label, sell } | { kind = "scrap", kg, label } |
--   { kind = "stock", label } | nil (not ours: leave it alone)
local KEEP_OFF = { RelayBeacon = true, Flag = true, SalvageCrate = true, SupplyCrate = true }
local KIND = {   -- a body with no resource tags yet, by its prefab's kind tag
  log = { mat = "timber", qty = 3, label = "Log", cube = true },
  boulder = { mat = "basalt", qty = 6, label = "Boulder", cube = true },
  crystal = { mat = "crystal", qty = 2, label = "Crystal" },
  loose_rock = { mat = "regolith", qty = 2, label = "Rock" },
}
local function has(tags, t)
  for _, x in ipairs(tags or {}) do if x == t then return true end end
  return false
end
function classify(d)
  if not d or d.crew or (d.craft and not d.lost) then return nil end
  local tags = d.tags or {}
  local base = (d.name or ""):match("^(%a+)")
  if KEEP_OFF[base or ""] or has(tags, "RelayBeacon") or has(tags, "flag") or has(tags, "deployable") then return nil end
  local function mat_entry(mat, qty, label)
    qty = math.max(1, math.floor((qty or 1) + 0.5))
    local g = d.grade and d.grade(mat) or "ore"
    return { kind = "mat", mat = mat, qty = qty, label = label or (d.label and d.label(mat)) or mat, sell = g == "bulk" }
  end
  local kl = nil   -- the thing's own name, by its prefab's kind ("Log")
  for _, t in ipairs(tags) do if KIND[t] then kl = KIND[t].label end end
  if d.res and d.res.mat then return mat_entry(d.res.mat, d.res.qty, kl) end
  for _, t in ipairs(tags) do
    local m = t:match("^mat:(.+)$")
    if m then
      local q = 1
      for _, t2 in ipairs(tags) do q = tonumber(t2:match("^qty:(%d+)$") or "") or q end
      return mat_entry(m, q, kl)
    end
  end
  if d.worth and d.worth.mat then return mat_entry(d.worth.mat, d.worth.n, d.worth.label) end
  if has(tags, "prop") then
    return { kind = "stock", label = has(tags, "can") and "Cargo can" or (has(tags, "crate") and "Cargo crate" or "Base stock") }
  end
  for _, t in ipairs(tags) do
    local k = KIND[t]
    if k then
      local s = d.scale or 1
      return mat_entry(k.mat, k.cube and k.qty * s * s * s or k.qty, k.label)
    end
  end
  if d.craft and d.lost then
    return { kind = "scrap", kg = (d.mass or 0) * 1000, label = "Wrecked hull", cap = d.wreckValue }
  end
  return { kind = "scrap", kg = (d.mass or 0) * 1000, label = "Wreckage" }
end

-- Scrap money for `e` (a classify answer): by weight, capped.
function quoteScrap(e, rate, cap, share)
  local cash = (e.kg or 0) * (rate or 0.25)
  cash = math.min(cash, cap or 300)
  if e.cap then cash = math.min(cash, e.cap * (share or 0.25)) end
  return math.max(1, math.floor(cash + 0.5))
end

-- One receipt line: what went in and what it became.
function receiptText(r)
  if r.kind == "mat" then
    if r.cash then return string.format("%s  →  %d %s sold  +%s", r.what, r.qty, r.label, r.money or ("$" .. r.cash)) end
    local s = string.format("%s  →  +%d %s  (warehouse)", r.what, r.took or r.qty, r.label)
    if (r.over or 0) > 0 then s = s .. string.format("  ·  %d sold, warehouse full", r.over) end
    return s
  elseif r.kind == "scrap" then
    return string.format("%s · %.0f kg  →  scrap  +%s", r.what, r.kg or 0, r.money or ("$" .. (r.cash or 0)))
  end
  return string.format("%s  →  returned to stores", r.what)
end

-- A body-relative point in the belt's frame: s along it from the tail, w
-- across, h over the running surface. B = { o, a, w, u } (body-relative).
function beltLocal(B, x, y, z)
  local dx, dy, dz = x - B.o.x, y - B.o.y, z - B.o.z
  return dx * B.a.x + dy * B.a.y + dz * B.a.z,
         dx * B.w.x + dy * B.w.y + dz * B.w.z,
         dx * B.u.x + dy * B.u.y + dz * B.u.z
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
local function unit3(x, y, z)
  local l = len(x, y, z)
  if l < 1e-9 then return { x = 0, y = 1, z = 0 } end
  return { x = x / l, y = y / l, z = z / l }
end
local function clamp(x, a, b) return math.max(a, math.min(b, x)) end

local ROOT = nil           -- the shed (this script's node)
local body_name = nil      -- the planet it stands on
local G = nil              -- the belt: { o, a, w, u (body-relative), L, take, head, half, hood, local_ = {…} }
receipts = {}              -- newest first: { t, text, kind }
totals = { units = 0, cash = 0, pieces = 0 }
lastTake = nil             -- (probes) the last receipt
carried = 0                -- (probes) bodies the belt drove last tick
phase = 0.0

-- The belt from the prefab's marker nodes (their local points), turned into
-- the planet's frame through the shed's own drawn transform. Directions are
-- the same in any pose (planets only translate), and the origin is the
-- shed's parent-local position, i.e. body-relative: nothing world is kept.
local function child(n, name)
  for _, c in ipairs(n:children() or {}) do if c.name == name then return c end end
  return nil
end
local function find_belt(node)
  local parent = node.parent
  if not (parent and parent.name) then return nil end
  local b = space.body(parent.name)
  if not b then return nil end
  local tail, head, take, board = child(node, "Belt Tail"), child(node, "Belt Head"), child(node, "Belt Take"), child(node, "Intake Board")
  if not (tail and head and take) then return nil end
  local w0 = node:toWorld(vec3(0, 0, 0))
  local function dir(lx, ly, lz)
    local p = node:toWorld(vec3(lx, ly, lz))
    return p.x - w0.x, p.y - w0.y, p.z - w0.z
  end
  local function bodyrel(c)   -- a marker's local point → body-relative
    local dx, dy, dz = dir(c.x, c.y, c.z)
    return { x = node.x + dx, y = node.y + dy, z = node.z + dz }
  end
  local T, H, K = bodyrel(tail), bodyrel(head), bodyrel(take)
  local a = unit3(H.x - T.x, H.y - T.y, H.z - T.z)
  local ux, uy, uz = dir(0, 1, 0)
  local u = unit3(ux, uy, uz)
  local w = unit3(u.y * a.z - u.z * a.y, u.z * a.x - u.x * a.z, u.x * a.y - u.y * a.x)
  local B = { o = T, a = a, w = w, u = u, body = parent.name,
              loc = { tail = { tail.x, tail.y, tail.z }, board = board and { board.x, board.y, board.z } or nil,
                      take = { take.x, take.y, take.z } } }
  B.board = board and bodyrel(board) or K
  B.head = (beltLocal(B, H.x, H.y, H.z))
  B.take = (beltLocal(B, K.x, K.y, K.z))
  B.L = B.head
  B.half, B.hood = 1.30, 2.45
  return B
end

-- (probes) the belt, and a point on it in the world NOW: s along from the
-- tail, w across, h over the running surface (against this read of the body;
-- use it this frame only).
function belt() return G end
function beltWorld(s, w, h)
  if not G then return nil end
  local b = space.body(G.body)
  if not b then return nil end
  return b.x + G.o.x + G.a.x * s + G.w.x * w + G.u.x * h,
         b.y + G.o.y + G.a.y * s + G.w.y * w + G.u.y * h,
         b.z + G.o.z + G.a.z * s + G.w.z * w + G.u.z * h
end

-- The crew on foot (or the craft they ride), for "is anyone here".
local function crew_node()
  local a = find and find("Astronaut")
  return valid(a) and a or nil
end
local function near_crew(B)
  local a = crew_node()
  local b = space.body(B.body)
  if not (a and b) then return false, nil end
  local d = len(a.x - b.x - B.o.x, a.y - b.y - B.o.y, a.z - b.z - B.o.z)
  return d < (params.near or 220), d
end

-- The thing that moves when a hit node is pushed: its assembly, or the body.
local function dynamic_of(n)
  local k, first = 0, n
  while valid(n) and k < 8 do
    if body_name and n.name == body_name then break end   -- the planet itself
    if assembly and assembly.info then
      local inf = assembly.info(n)
      if inf and inf.mass then return n, "asm" end
    end
    n = n.parent
    k = k + 1
  end
  n = first
  if valid(n) and n.vel ~= nil then
    local rb = n.getcomponent and n:getcomponent("RigidBody")
    if rb and (rb.kinematic == 0 or rb.kinematic == false) and (rb.mass or 0) > 0 then return n, "body" end
  end
  return nil
end

local function describe(n, mass)
  local d = { tags = n.tags or {}, name = n.name, mass = mass, scale = n.scale_x or 1 }
  if n.name == "Astronaut" or n.name == "CrewBody" or (n.hasTag and (n:hasTag("crew") or n:hasTag("Astronaut"))) then
    d.crew = true
    return d
  end
  local v = n.getScript and n:getScript("vessel_controller")
  if v and v.craftName then
    d.craft = true
    d.lost = (v.isLost and v.isLost()) == true
    if d.lost and v.recoverValue then
      local ok, val = pcall(v.recoverValue)
      d.wreckValue = ok and val or 0
    end
  end
  local mats = ref("materials")
  if mats then
    if mats.resourceOf then
      local ok, r = pcall(mats.resourceOf, n)
      if ok and r and r.mat then d.res = { mat = r.mat, qty = r.qty } end
    end
    d.grade = mats.grade or function(m) return m == "regolith" and "bulk" or "ore" end
    d.label = mats.label
  end
  local tb = ref("tool_belt")
  if tb and tb.worthOf and not d.res then
    local ok, w = pcall(tb.worthOf, n)
    if ok and w then d.worth = w end
  end
  return d
end

-- ── taking a load ───────────────────────────────────────────────────────────
local function say(text, kind)
  table.insert(receipts, 1, { t = time or 0, text = text, kind = kind })
  while #receipts > 6 do table.remove(receipts) end
  lastTake = text
  if log then log("intake: " .. text) end
end

local function take(n, e, mass, wx, wy, wz)
  local inv, co, mats = ref("inventory"), ref("company"), ref("materials")
  local what = (e.kind == "mat" and e.label) or e.label or "Load"
  -- (a resource's own label is the material; the receipt names the thing)
  if e.kind == "mat" then
    local kindl = nil
    for _, t in ipairs(n.tags or {}) do if KIND[t] then kindl = KIND[t].label end end
    what = kindl or ((mats and mats.label and mats.label(e.mat)) or e.mat) .. " load"
  end
  local r = { kind = e.kind, what = what }
  if e.kind == "mat" then
    if not inv then return false end
    r.label = (mats and mats.label and mats.label(e.mat)) or e.mat
    r.qty = e.qty
    -- the world it was dug on rides its tags (materials.tagResource) into the
    -- warehouse with it, so an ore haul counts the lot (inventory.lua)
    local from = nil
    for _, t in ipairs(n.tags or {}) do from = t:match("^origin:(.+)$") or from end
    local took = inv.add("base", e.mat, e.qty, from)
    r.took = took
    -- it came in by the tonne, off a truck or out of the yard: freight
    if took > 0 then
      local fr = save.get("depot.freight") or {}
      fr[e.mat] = (fr[e.mat] or 0) + took
      save.set("depot.freight", fr)
    end
    local fm = ref("facility_menu")
    if (e.sell or took < e.qty) and co then
      local before = co.balance and co.balance() or 0
      if e.sell and fm and fm.depotSell and took > 0 then
        pcall(fm.depotSell, e.mat)
      end
      -- what didn't fit in a full warehouse goes at the list price
      local over = e.qty - took
      if over > 0 then
        local each = (mats and mats.value and mats.value(e.mat)) or 1
        local mult = (co.priceMult and co.priceMult()) or 1
        co.earn(math.max(1, math.floor(each * over * mult)), "intake: sold, warehouse full")
        r.over = over
      end
      local cash = (co.balance and co.balance() or before) - before
      if e.sell and cash > 0 then r.cash = cash; r.money = co.money and co.money(cash) or ("$" .. cash) end
      totals.cash = totals.cash + math.max(0, cash)
    end
    totals.units = totals.units + e.qty
  elseif e.kind == "scrap" then
    local cash = quoteScrap(e, params.scrap_rate, params.scrap_cap, params.wreck_share)
    if co and co.earn then co.earn(cash, "scrap recycled at the intake") end
    r.kg, r.cash = e.kg, cash
    r.money = co and co.money and co.money(cash) or ("$" .. cash)
    totals.cash = totals.cash + cash
  end
  totals.pieces = totals.pieces + 1
  -- A SAMPLE GOES TO THE LAB: research points for studying it (research.lua),
  -- and a capsule up the transfer tube into the Research Lab (lab.lua) that
  -- the player can watch go. The base's own stock teaches nothing.
  local rp, first = 0, false
  if e.kind ~= "stock" then
    local rs = ref("research")
    local smat, sq = e.mat, e.qty
    if e.kind == "scrap" then smat, sq = "scrap", e.kg or 0 end
    local origin = nil
    for _, t in ipairs(n.tags or {}) do
      local o = t:match("^origin:(.+)$")
      if o then origin = o end
    end
    if rs and rs.study then
      local ok, g, f = pcall(rs.study, smat, sq, origin)
      if ok then rp, first = g or 0, f == true end
    end
    local lab = ref("lab")
    if lab and lab.receive then pcall(lab.receive, smat, sq, rp, first) end
    -- J3: a sample (not scrap) studied is the duty Scientist's ("studied"),
    -- counted on the world it is studied on (the home Lab's)
    if e.kind ~= "scrap" then
      local cl = ref("crew")
      local who = cl and cl.onDuty and cl.onDuty("scientist")
      if who and cl.credit then pcall(cl.credit, who, "studied", 1, { body = save.get("base.body") }) end
    end
  end
  local line = receiptText(r)
  if rp > 0 then line = line .. string.format("  ·  +%d RP%s", rp, first and " (new)" or "") end
  say(line, e.kind)
  -- what it looks and sounds like going in: dust at the curtain, motes off
  -- to the depot, the crusher's clank
  local fx = ref("vfx")
  if fx and fx.oreBreak then pcall(fx.oreBreak, wx, wy, wz) end
  local sfx = ref("sfx")
  if sfx and sfx.play then pcall(sfx.play, e.kind == "stock" and "place" or "pickup") end
  if audio and audio.play then
    pcall(audio.play, "audio/kenney/impact/impactPlate_heavy_00" .. tostring(math.random(0, 4)) .. ".ogg",
      { track = "SFX", volume = 0.45, pitch = 0.6 + math.random() * 0.15 })
  end
  n:destroy()
  return true
end

-- ── the belt's physics (fixedUpdate, tick poses) ────────────────────────────
-- Keyed by the node's id AND name: a script's handle is the engine's slot
-- number, handed to the next node spawned (engine card 0552), so an entry is
-- only trusted while the node still answers to the name it had.
local cands = {}           -- id → { n, kind ("asm" | "body"), name }, refreshed at 10 Hz
local known = {}           -- id → { name, e } (e = the classify answer, false: not ours)
local scan_t = -10
local live = false         -- the belt runs (someone is near)

local function scan(B, b)
  scan_t = time or 0
  cands = {}
  if not overlapSphere then return end
  local cx = b.x + B.o.x + B.a.x * B.L * 0.5 + B.u.x * 0.6
  local cy = b.y + B.o.y + B.a.y * B.L * 0.5 + B.u.y * 0.6
  local cz = b.z + B.o.z + B.a.z * B.L * 0.5 + B.u.z * 0.6
  local ok, hits = pcall(overlapSphere, vec3(cx, cy, cz), B.L * 0.5 + 2.5)
  if not ok or type(hits) ~= "table" then return end
  for _, h in ipairs(hits) do
    local n = h.node
    if valid(n) and n ~= ROOT and n.parent ~= ROOT then
      local root, kind = dynamic_of(n)
      if root and root.id and not cands[root.id] then cands[root.id] = { n = root, kind = kind, name = root.name } end
    end
  end
end

-- Does the load touch the BELT this tick: one of last tick's contacts
-- (assembly.impacts, each part's hardest) against the shed, at the running
-- surface (not the hopper's plates, the skirts, the ground or another
-- load). A load riding on another load is carried by that one's friction,
-- as on a real belt. The points are last tick's: placed against this tick's
-- planet as they are, and carried with it (`carry`, metres a tick here), so
-- either pose finds them.
local function ours(n)
  local k = 0
  while valid(n) and k < 5 do
    if ROOT and n.id == ROOT.id and n.name == ROOT.name then return true end
    n = n.parent
    k = k + 1
  end
  return false
end
local function belt_contact(root, B, b, carry)
  if not (assembly and assembly.impacts) then return true end
  local ok, list = pcall(assembly.impacts, root)
  if not ok or type(list) ~= "table" then return true end
  for _, c in ipairs(list) do
    -- (the shed's static shapes are no node's: impacts gives other = nil
    -- for them on .1406; a node that is the shed's counts too)
    if c.x and (c.other == nil or (type(c.other) == "table" and ours(c.other))) then
      for k = 0, (carry and 1 or 0) do
        local x, y, z = c.x - b.x, c.y - b.y, c.z - b.z
        if k == 1 then x, y, z = x + carry.x, y + carry.y, z + carry.z end
        local _, w, h = beltLocal(B, x, y, z)
        if h > -0.2 and h < 0.15 and math.abs(w) <= B.half + 0.05 then return true end
      end
    end
  end
  return false
end

-- 3×3: rows r1..r3 ({x,y,z}) times v, and the inverse's rows.
local function mul3(M, x, y, z)
  return M[1].x * x + M[1].y * y + M[1].z * z, M[2].x * x + M[2].y * y + M[2].z * z, M[3].x * x + M[3].y * y + M[3].z * z
end
local function inv3(M)
  local a, b_, c = M[1].x, M[1].y, M[1].z
  local d, e, f = M[2].x, M[2].y, M[2].z
  local g, h, i = M[3].x, M[3].y, M[3].z
  local A, Bc, C = e * i - f * h, -(d * i - f * g), d * h - e * g
  local det = a * A + b_ * Bc + c * C
  if math.abs(det) < 1e-12 then return nil end
  local k = 1 / det
  return { { x = A * k, y = -(b_ * i - c * h) * k, z = (b_ * f - c * e) * k },
           { x = Bc * k, y = (a * i - c * g) * k, z = -(a * f - c * d) * k },
           { x = C * k, y = -(a * h - b_ * g) * k, z = (a * e - b_ * d) * k } }
end
local function cross(ax, ay, az, bx, by, bz) return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx end

-- THE BELT'S GRIP on a load that touches it, as friction does it.
--  1. The foot: the point of the running surface under the centre of mass
--     (the centre of the patch it rests on; a belt's friction acts there).
--     Its velocity is the centre's PLUS the spin's (ω × r). The impulse that
--     brings that to the belt's (along `speed`, across `tw`) is the slip over
--     the load's effective mass there, 1/m + (r×t)·I⁻¹(r×t), capped at what
--     the grip gives in a tick (m·lim). A load that lands spinning has its
--     foot sliding, so friction takes the spin out, as it takes the speed in.
--  2. Rolling and twisting drag (a rubber belt is not a rail): what spin is
--     left is let down at 5 /s about any axis, the twist about the belt's
--     normal at 8 /s, as a pure couple (two opposite kicks), no push. A load
--     at rest on a running belt has no slip and no spin: nothing is applied.
local function grip(root, inf, B, lim, speed, tw, h, cx, cy, cz, dt)
  local m = inf.mass
  if not (m and m > 0) then return end
  local Iinv = inv3(inf.inertia)
  if not Iinv then return end
  local ox, oy, oz = inf.angVel.x, inf.angVel.y, inf.angVel.z
  local px, py, pz = cx - B.u.x * h, cy - B.u.y * h, cz - B.u.z * h
  local rx, ry, rz = px - cx, py - cy, pz - cz
  local sx, sy, sz = cross(ox, oy, oz, rx, ry, rz)
  local fvx, fvy, fvz = inf.vel.x + sx, inf.vel.y + sy, inf.vel.z + sz
  -- the slip in the belt's plane (the normal is the solver's business)
  local ea = speed - (fvx * B.a.x + fvy * B.a.y + fvz * B.a.z)
  local ew = tw - (fvx * B.w.x + fvy * B.w.y + fvz * B.w.z)
  local tx, ty, tz = B.a.x * ea + B.w.x * ew, B.a.y * ea + B.w.y * ew, B.a.z * ea + B.w.z * ew
  local sl = len(tx, ty, tz)
  local ax, ay, az = 0, 0, 0
  if sl > 1e-4 then
    local nx, ny, nz = tx / sl, ty / sl, tz / sl
    local qx, qy, qz = cross(rx, ry, rz, nx, ny, nz)
    local ix, iy, iz = mul3(Iinv, qx, qy, qz)
    local kx, ky, kz = cross(ix, iy, iz, rx, ry, rz)
    local K = 1 / m + (kx * nx + ky * ny + kz * nz)
    local j = math.min(sl / math.max(K, 1e-6), m * lim)
    assembly.impulseAt(root, vec3(nx * j, ny * j, nz * j), vec3(px, py, pz))
    -- the spin that kick gives, so the drag below works on what is left
    ax, ay, az = ix * j, iy * j, iz * j
  end
  ox, oy, oz = ox + ax, oy + ay, oz + az
  -- rolling and twisting drag
  local ou = ox * B.u.x + oy * B.u.y + oz * B.u.z
  local f_roll = 1 - math.exp(-5 * dt)
  local f_twist = 1 - math.exp(-8 * dt)
  local dx = -(ox - B.u.x * ou) * f_roll - B.u.x * ou * f_twist
  local dy = -(oy - B.u.y * ou) * f_roll - B.u.y * ou * f_twist
  local dz = -(oz - B.u.z * ou) * f_roll - B.u.z * ou * f_twist
  -- no more than the grip's own twist could do in a tick (≈ lim over a
  -- 0.25 m patch), so a hard knock at a transfer still tumbles a little
  local dl = len(dx, dy, dz)
  local cap = lim / 0.25
  if dl > cap then dx, dy, dz = dx * cap / dl, dy * cap / dl, dz * cap / dl; dl = cap end
  if dl < 1e-4 then return end
  local I = inf.inertia
  local Lx, Ly, Lz = mul3(I, dx, dy, dz)
  local L = len(Lx, Ly, Lz)
  if L < 1e-9 then return end
  local lx, ly, lz = Lx / L, Ly / L, Lz / L
  -- a unit e across L; kicks ±J at com ± e·d make L = 2d (e × J)
  local ex, ey, ez = cross(lx, ly, lz, B.a.x, B.a.y, B.a.z)
  local el = len(ex, ey, ez)
  if el < 0.3 then ex, ey, ez = cross(lx, ly, lz, B.w.x, B.w.y, B.w.z); el = len(ex, ey, ez) end
  ex, ey, ez = ex / el, ey / el, ez / el
  local d = 0.5
  local jx, jy, jz = cross(lx, ly, lz, ex, ey, ez)
  local s = L / (2 * d)
  jx, jy, jz = jx * s, jy * s, jz * s
  assembly.impulseAt(root, vec3(jx, jy, jz), vec3(cx + ex * d, cy + ey * d, cz + ez * d))
  assembly.impulseAt(root, vec3(-jx, -jy, -jz), vec3(cx - ex * d, cy - ey * d, cz - ez * d))
end

function fixedUpdate(node, dt)
  if (params.enabled or 1) <= 0 or not live or not G then carried = 0 return end
  local b = space.body(G.body)
  if not b then return end
  if (time or 0) - scan_t > 0.1 then scan(G, b) end
  local n_c = 0
  for id, c in pairs(cands) do
    local root, kind = c.n, c.kind
    if not (valid(root) and root.name == c.name) then
      cands[id] = nil
    else
      local mass, cx, cy, cz, vx, vy, vz
      if kind == "asm" then
        local inf = assembly.info(root)
        if inf and inf.com then
          mass, cx, cy, cz = inf.mass, inf.com.x, inf.com.y, inf.com.z
          vx, vy, vz = inf.vel.x, inf.vel.y, inf.vel.z
        end
      else
        local p = root.tickPos or root.worldPos
        local v = root.vel
        if p and v then mass, cx, cy, cz, vx, vy, vz = 0, p.x, p.y, p.z, v.x, v.y, v.z end
      end
      if mass then
        local s, w, h = beltLocal(G, cx - b.x, cy - b.y, cz - b.z)
        -- (lazily: is it ours at all? a craft and the crew are never touched)
        if s >= -0.6 and s <= G.head + 0.4 and math.abs(w) <= G.hood + 0.1 and h >= -0.35 and h <= 2.7 then
          local kn = known[id]
          if not (kn and kn.name == c.name) then
            kn = { name = c.name, e = classify(describe(root, mass)) or false }
            known[id] = kn
          end
          local e = kn.e
          if not e then
            cands[id] = nil
          elseif s >= G.take and math.abs(w) <= G.hood and h <= 2.5 then
            cands[id], known[id] = nil, nil
            take(root, e, mass, cx, cy, cz)
          elseif math.abs(w) <= G.half + 1.1 and h <= 1.6 then
            -- ride the belt: its speed along, eased to the middle across,
            -- no more than friction gives in one tick
            -- (a body's velocity is already its SOI body's frame: a parked
            -- craft reads ~0, vessel_controller recoverReady)
            local rvx, rvy, rvz = vx, vy, vz
            local va = rvx * G.a.x + rvy * G.a.y + rvz * G.a.z
            local vw = rvx * G.w.x + rvy * G.w.y + rvz * G.w.z
            local vu = rvx * G.u.x + rvy * G.u.y + rvz * G.u.z
            if math.abs(vu) < 2.5 then
              local lim = (params.accel or 5) * dt
              -- where the belt should carry the foot of the load: its speed
              -- along, eased toward the middle across
              local tw = -0.8 * w * (math.abs(w) > G.half - 0.35 and 1 or 0.3)
              if kind == "asm" then
                -- ONLY WHILE IT TOUCHES THE BELT, and as FRICTION: the slip
                -- of the load's foot (its centre of mass's speed PLUS its
                -- spin's, ω × r) against the belt, taken out at the foot
                -- through the load's own mass and inertia, no more than
                -- `accel` allows; and a rolling and twisting drag. The push
                -- used to come every tick at the belt plane under the
                -- centre of mass whether the load touched it or not, and to
                -- look only at the centre's speed: a load in the air, or
                -- tumbling, took a twist of up to 1.6 m × the grip every
                -- tick that nothing ever took back — crates and crystals
                -- spun up to 120–340 rad/s (tools/perf/beltshots.sh).
                local inf = assembly.info(root)
                -- (impacts give each part's HARDEST contact only: a boulder
                -- half off the edge reports the ground beside the belt, so a
                -- load standing on something with its centre over the belt
                -- counts too; never one in the air)
                local on = inf and inf.angVel and inf.inertia and
                  (belt_contact(root, G, b, inf.carry) or (inf.grounded == true and math.abs(w) <= G.half and h <= 1.3))
                if on then
                  root.asleep = false
                  grip(root, inf, G, lim, (params.speed or 0.9), tw, h, cx, cy, cz, dt)
                  n_c = n_c + 1
                end
              else
                -- (a plain body, no assembly: its velocity, through the
                -- centre, no twist)
                local da = clamp((params.speed or 0.9) - va, -lim, lim)
                local dw = clamp(tw - vw, -lim * 0.6, lim * 0.6)
                root.asleep = false
                root.vel = vec3(vx + G.a.x * da + G.w.x * dw, vy + G.a.y * da + G.w.y * dw, vz + G.a.z * da + G.w.z * dw)
                n_c = n_c + 1
              end
            end
          end
        end
      end
    end
  end
  carried = n_c
end

-- ── the right-click (context_registry "prop": the shed or its belt) ────────
local function is_ours(n)
  local k = 0
  while valid(n) and k < 4 do
    if ROOT and n.id == ROOT.id and n.name == ROOT.name then return true end
    n = n.parent
    k = k + 1
  end
  return false
end
local function provider(t, ctx)
  if not (t and is_ours(t.node)) then return {} end
  local co = ref("company")
  local out = {
    { type = "info", id = "belt", label = "BELT", value = function()
        return live and string.format("running  ·  %.1f m/s", params.speed or 0.9) or "idle (nobody here)" end },
    { type = "info", id = "takes", label = "TAKES", value = "logs · rocks · ore · scrap" },
    { type = "info", id = "pays", label = "", value = "ore & timber → warehouse (freight) · rock & soil sold · scrap paid" },
    { type = "info", id = "today", label = "TODAY", value = function()
        return string.format("%d loads · %d units · %s", totals.pieces, totals.units,
          (co and co.money and co.money(totals.cash)) or ("$" .. totals.cash)) end },
  }
  for i = 1, math.min(3, #receipts) do
    out[#out + 1] = { type = "info", id = "r" .. i, group = "LAST TAKEN", label = receipts[i].text }
  end
  fab_rows(out, ctx)
  return out, "MATERIALS INTAKE", "the depot's bulk feed belt"
end

-- ── FUEL FABRICATION (deep-space B6; the rules in scripts/thermal.lua) ──────
-- The Intake's radiological wing: 20 units of uranium ore from the warehouse,
-- $400 and ten game minutes in the press make one Fuel Rod, delivered to the
-- base's stores (the VAB loads reactors from there at rollout). An Engineer
-- on foot at the shed sets each one up and is credited with it ("crafted").
-- The queue (`fab.rods`, two at most) runs on the game clock, so a rod
-- started before a long warp, or a save quit mid-press, is ready when its
-- time is up. Spent rods come back here too: the wing takes them off your
-- hands (reprocessing returns 4 units of the ore).
FAB_KEY = "fab.rods"
local function fab_queue()
  local q = save.get(FAB_KEY)
  return type(q) == "table" and q or {}
end
local function game_now() return (space and space.time and space.time()) or (time or 0) end
function fab_rows(out, ctx)
  local TH, inv, co, rs, cl = ref("thermal"), ref("inventory"), ref("company"), ref("research"), ref("crew")
  if not (TH and inv) then return end
  local F = TH.FUEL_FAB
  local unlocked = not rs or not rs.isUnlocked or rs.isUnlocked("ember")
  local a = ctx and ctx.actor
  local function engineer()
    if not (a and a.kind == "crew" and a.id) then return false end
    if not (cl and cl.hasRole) then return true end
    return cl.hasRole(a.id, "engineer") == true
  end
  local function why()
    local q = fab_queue()
    return TH.fabWhyNot(inv.count("base", F.ore) or 0, co and co.balance and co.balance() or nil, q, engineer(), unlocked)
  end
  out[#out + 1] = { type = "info", id = "fabq", group = "FUEL FABRICATION · RADIOLOGICAL", label = "PRESS", value = function()
      local q = fab_queue()
      if #q == 0 then return string.format("idle · %d units of uranium ore in the warehouse", inv.count("base", F.ore) or 0) end
      local now = game_now()
      local p = TH.fabProgress(q, now) or 0
      return string.format("%d rod(s) in the press · %d%% · %s left", #q, math.floor(p * 100),
        string.format("%.0f min", math.max(0, (q[1].t1 or now) - now) / 60))
    end }
  out[#out + 1] = { type = "action", id = "fabrod", group = "FUEL FABRICATION · RADIOLOGICAL", label = "Fabricate a fuel rod",
    hint = string.format("%d ore · $%d · %d min", F.units, F.cost, math.floor(F.secs / 60)),
    enabled = function() return why() == nil end, why = why,
    act = function()
      local w = why()
      if w then return false, w end
      if co and co.spend and not co.spend(F.cost, "fuel fabrication") then return false, "not enough funds" end
      inv.remove("base", F.ore, F.units)
      local q = fab_queue()
      TH.fabQueue(q, game_now(), a and a.id)
      save.set(FAB_KEY, q)
      say(string.format("fuel rod in the press — ready in %d min", math.floor(F.secs / 60)), "fab")
      return true
    end }
  local pack = a and a.pack
  local spent = (inv.itemCount("base", "spentRod") or 0) + ((pack and inv.itemCount(pack, "spentRod")) or 0)
  if spent > 0 then
    out[#out + 1] = { type = "action", id = "fabret", group = "FUEL FABRICATION · RADIOLOGICAL",
      label = string.format("Return %d spent rod(s)", spent), hint = "+4 ore each",
      act = function()
        local n = inv.removeItem("base", "spentRod", 99)
        if pack then n = n + inv.removeItem(pack, "spentRod", 99) end
        if n > 0 then inv.add("base", F.ore, 4 * n) end
        say(string.format("%d spent rod(s) into the cask · %d units of ore reclaimed", n, 4 * n), "fab")
        return true
      end }
  end
end

-- The press on the game clock (once a second while the shed is loaded).
local fab_t = 0
local function fab_tick(dt)
  fab_t = fab_t + (dt or 0)
  if fab_t < 1.0 then return end
  fab_t = 0
  local q = save.get(FAB_KEY)
  if type(q) ~= "table" or #q == 0 then return end
  local TH, inv = ref("thermal"), ref("inventory")
  if not (TH and inv) then return end
  local done = TH.fabTake(q, game_now())
  if #done == 0 then return end
  save.set(FAB_KEY, q)
  local cl = ref("crew")
  for _, j in ipairs(done) do
    inv.addItem("base", TH.FUEL_FAB.item, 1, { force = true })
    if j.by and cl and cl.credit then pcall(cl.credit, j.by, "crafted") end
  end
  say(string.format("%d fuel rod(s) out of the press — in the base's stores", #done), "fab")
  local bc = ref("big_caption")
  if bc and bc.show then pcall(bc.show, "FUEL ROD READY", "In the base's stores — the VAB loads reactors from there.", 4.0) end
end
local provider_on = false

-- ── the frame ───────────────────────────────────────────────────────────────
function start(node)
  ROOT = node
  G = nil
end

local look_t = -10
function update(node, dt)
  ROOT = node
  fab_tick(dt)
  if not provider_on then
    local reg = ref("context_registry")
    if reg and reg.register then
      reg.register("prop", provider, { id = "material_intake", order = 4 })
      provider_on = true
    end
  end
  if not G and (time or 0) - look_t > 0.5 then
    look_t = time or 0
    G = find_belt(node)
    if G then
      body_name = G.body
      if log then log(string.format("intake: the belt is %.1f m (take at %.1f m), on %s", G.L, G.take, G.body)) end
    end
  end
  if not G then return end
  live = near_crew(G)
  -- the cleats move with the belt
  if live and (params.enabled or 1) > 0 then
    phase = (phase + (params.speed or 0.9) * (dt or 0)) % 1000.0
    if node.setShaderParam then pcall(node.setShaderParam, node, "phase", phase) end
  end
end

-- ── the board and the line (drawn poses) ────────────────────────────────────
local function uiH()
  local st = ref("settings")
  return (st and st.designHeight and st.designHeight()) or 720
end
local function chars(s)
  local _, n = s:gsub("[^\128-\191]", "")
  return n
end
local function tag(x, y, text, size, r, g, b, a, align)
  local w = chars(text) * size * 0.52 + size
  local h = size * 1.5
  local x0 = align == "left" and x or x - w / 2
  draw.rect(x0, y - h / 2, w, h, 0.04, 0.03, 0.02, 0.70 * a, size * 0.3)
  draw.text(align == "left" and (x0 + size * 0.5) or x, y - size * 0.62, text, size, r, g, b, a, align == "left" and "left" or "center")
end

-- Drawn over the world: after the camera has placed this frame's view
-- (planet_camera.deferLate; docs/positions-and-frames.md rule 2)
local pc_late = nil
local function after_camera(node, dt, fn)
  if not (pc_late and pc_late.valid) then pc_late = findScript("planet_camera", { quiet = true }) end
  if pc_late and pc_late.valid and pc_late.deferLate then pc_late.deferLate(node, dt, fn) else fn(node, dt) end
end
local function late_draw(node, dt)
  if not (G and live and camera and camera.worldToScreen and camera.screenRect and draw and draw.text) then return end
  local pc = ref("planet_camera")
  if pc and pc.cinematic == true then return end
  local pm = ref("pause_menu")
  if pm and pm.open then return end
  local ip = ref("inventory_panel")
  if ip and ip.open then return end
  -- (indoors at the Research Lab next door the board would show through its walls)
  local lab = ref("lab")
  if lab and lab.crewInLab then return end
  local a = crew_node()
  if not a then return end
  local vx, vy, vw, vh = camera.screenRect()
  if not vw or vw <= 0 then return end
  local k = vh / uiH()
  -- the board against the planet's DRAWN place this frame (the shed rides
  -- it; its body-relative point never changes)
  local pn = node.parent
  local pw = pn and pn.worldPos
  if not pw then return end
  local p = { x = pw.x + G.board.x, y = pw.y + G.board.y, z = pw.z + G.board.z }
  local d = len(a.x - p.x, a.y - p.y, a.z - p.z)
  local now = time or 0
  -- the last take, under the screen's middle, for a few seconds
  local r0 = receipts[1]
  if r0 and now - r0.t < 4.0 and d < 80 then
    local fade = math.min(1, (4.0 - (now - r0.t)) / 0.6)
    tag(vx + vw * 0.5, vy + vh * 0.76, "INTAKE  ·  " .. r0.text, 15 * k, 0.95, 0.85, 0.55, fade)
  end
  -- the board over the hood: what it takes, and the latest receipts
  if d > 45 then return end
  local sx, sy, dep, on = camera.worldToScreen(p.x, p.y, p.z)
  if not (sx and ((dep and dep > 0) or on)) then return end
  if sx < vx or sx > vx + vw or sy < vy or sy > vy + vh then return end
  local size = clamp(16 * k * (14 / math.max(6, d)), 9 * k, 15 * k)
  local lines = { { "MATERIALS INTAKE  ·  BELT RUNNING", 0.85, 0.90, 0.95 } }
  if #receipts == 0 then
    lines[#lines + 1] = { "drop rocks, logs or scrap on the belt", 0.80, 0.78, 0.70 }
  end
  for i = 1, math.min(4, #receipts) do
    local r = receipts[i]
    local age = now - r.t
    local c = r.kind == "scrap" and { 0.95, 0.80, 0.45 } or (r.kind == "stock" and { 0.70, 0.72, 0.74 } or { 0.70, 0.92, 0.62 })
    lines[#lines + 1] = { r.text, c[1], c[2], c[3], age > 60 and 0.6 or 1.0 }
  end
  if totals.pieces > 0 then
    lines[#lines + 1] = { string.format("today: %d loads · %d units · %s", totals.pieces, totals.units,
      (ref("company") and ref("company").money and ref("company").money(totals.cash)) or ("$" .. totals.cash)), 0.80, 0.80, 0.80 }
  end
  local lh = size * 1.55
  local y0 = sy - lh * (#lines - 1)
  for i, l in ipairs(lines) do
    tag(sx, y0 + (i - 1) * lh, l[1], size, l[2], l[3], l[4], l[5] or 1.0)
  end
end

function lateUpdate(node, dt) after_camera(node, dt, late_draw) end
