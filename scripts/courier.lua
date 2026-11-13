-- COURIER — parts and materials shipped between bases (playtest 11-12b;
-- work/baseloop/DESIGN.md phase 6). "Part shipping between bases … I don't
-- want to go back to the main base constantly."
--
-- On the Build Kit node (scenes/system.ron) beside workbench.lua. The rules
-- are pure (tests/smoke_courier.lua); the scene half finds each base's stock,
-- keeps the pods in flight on the agency clock and puts the menu on every
-- tower.
--
-- ── WHAT A PLAYER DOES ──────────────────────────────────────────────────────
--   At the tower of the base that WANTS the goods: Request a shipment → pick
--   a source (the spaceport's warehouse, or another base: every container
--   within 150 m of its tower) → add lines to the manifest (a crated part a
--   click, a material 25 kg a click) → Send the pod. The bill is by weight
--   and distance, the arrival on the agency clock:
--
--     on one world   $60 + $40 a tonne-kilometre · 5 min + the distance at 25 m/s
--     between worlds $2,500 + $400 a tonne       · 2 days
--
--   The goods leave the source at once. When the clock comes round the pod is
--   set down 8 m from the tower as a crate (salvage.lua's: a marker, E takes
--   what fits, the context menu shows what is in it), and the Build Kit's
--   reach finds the crated parts in it where it stands.
--
-- ── WHAT MAKES IT A DECISION ────────────────────────────────────────────────
--   2 t a pod; one pod in flight to a base at a time; a base that SENDS must
--   have its tower powered (the spaceport always can); the fee is paid on
--   sending and a pod can't be recalled.
--
-- ── SAVE ────────────────────────────────────────────────────────────────────
--   courier.seq, courier.list = { id … } the pods in flight
--   courier.<id> = { id, from, fromName, to (base id), toName, b (the world it
--                    lands on), x, y, z (the tower, body-relative), t0, eta,
--                    kg, fee, n (lines) }
--   its goods wait in the container "courier:<id>"
--
-- COST: nothing while no pod flies; with one, a 1 Hz compare.
--
-- Probes: quote(kg, m, sameWorld), sources(), stockOf(key), request(bid,
-- srcKey, lines), inFlight(bid), tick(), deliverNow(id), PROF.

POD_KG = 2000
RATE_TKM = 40          -- $ a tonne-kilometre on one world
FLAT = 60
SPEED = 25             -- m/s over the ground
HANDLING = 300         -- s to load and set down
WORLD_FLAT = 2500      -- between worlds
WORLD_T = 400          -- $ a tonne between worlds
WORLD_SECS = 2 * 86400
REACH = 150            -- a base's stock: containers this near its tower
MAT_STEP = 25          -- a click adds this many kg of a material
PROF = { sent = 0, landed = 0 }

-- ── pure ────────────────────────────────────────────────────────────────────
-- → { fee ($), secs }
function quote(kg, dist_m, sameWorld)
  local t = math.max(0, kg or 0) / 1000
  if sameWorld == false then
    return { fee = math.floor(WORLD_FLAT + WORLD_T * t + 0.5), secs = WORLD_SECS }
  end
  local km = math.max(0, dist_m or 0) / 1000
  return { fee = math.floor(FLAT + RATE_TKM * t * km + 0.5), secs = HANDLING + (dist_m or 0) / SPEED }
end
-- Why a manifest can't go (or nil). lines = { { kg, n } … }.
function whyNot(lines, flying, senderPowered, funds, fee)
  if not lines or #lines == 0 then return "the manifest is empty: add something to it" end
  local kg = 0
  for _, l in ipairs(lines) do kg = kg + (l.kg or 0) end
  if kg > POD_KG + 1e-6 then return string.format("%.0f kg: a pod carries %d kg", kg, POD_KG) end
  if flying then return "a pod is already on its way here: one at a time" end
  if senderPowered == false then return "the sending base's tower has no power: nothing can be dispatched from it" end
  if funds and fee and funds + 1e-6 < fee then return string.format("can't afford it: $%d", fee) end
  return nil
end
function etaLine(secs)
  secs = math.max(0, secs or 0)
  if secs >= 86400 then return string.format("%.1f days", secs / 86400) end
  if secs >= 3600 then return string.format("%.1f h", secs / 3600) end
  return string.format("%d min", math.max(1, math.floor(secs / 60 + 0.5)))
end

-- ── the scene ───────────────────────────────────────────────────────────────
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind, { quiet = true }) or nil; refs[kind] = r end
  return r
end
local function now() return time or 0 end
local function agency_now()
  local dp = ref("deployables")
  if dp and dp.agencyClock then local ok, t = pcall(dp.agencyClock); if ok and type(t) == "number" then return t end end
  return tonumber(save and save.get and save.get("agency.clock")) or 0
end
local function defs(id) local pb = ref("parts_base"); return pb and pb.partInfo(id) or nil end
local function money(v) local co = ref("company"); return (co and co.money) and co.money(v) or ("$" .. tostring(math.floor((v or 0) + 0.5))) end

-- THE SOURCES: the spaceport's warehouse, and every standing base.
-- → { { key, label, b, x, y, z (body-relative), bid?, cids = { … } } … }
function sources()
  local out = {}
  local bf = ref("base_facilities")
  local fp = bf and bf.footprint
  if fp and fp.body then out[#out + 1] = { key = "home", label = "the spaceport's warehouse", b = fp.body, x = fp.x, y = fp.y, z = fp.z, cids = { "base" } } end
  local BS, ST, LG = ref("bases"), ref("structures"), ref("logistics")
  for _, r in ipairs((BS and BS.list) and BS.list() or {}) do
    if r.sid and ST and ST.get and ST.get(r.sid) then
      local cids, seen = {}, {}
      for _, e in ipairs(ST.partsNear and ST.partsNear(r.b, r.x, r.y, r.z, REACH) or {}) do
        local d = defs(e.part.id)
        local cid = nil
        if d and d.container then cid = "piece:" .. tostring(e.rec.id) .. ":" .. tostring(e.part.uid)
        elseif d and d.it and LG and LG.storeCid then
          local a, b2 = LG.storeCid(d.it, e.rec.id, e.part.uid)
          cid = (d.it.kind == "machine") and b2 or a
        end
        if cid and not seen[cid] then seen[cid] = true; cids[#cids + 1] = cid end
      end
      out[#out + 1] = { key = "b" .. tostring(r.id), label = tostring(r.n or ("Base " .. tostring(r.id))), b = r.b, x = r.x, y = r.y, z = r.z, bid = r.id, cids = cids }
    end
  end
  return out
end
function sourceOf(key) for _, s in ipairs(sources()) do if s.key == key then return s end end return nil end
-- What a source holds: { { key ("m:steel" | "i:part:wall.steel"), kind, id,
-- label, n, each (kg a unit) } … } crated parts first, then gear, then materials.
function stockOf(key)
  local s = type(key) == "table" and key or sourceOf(key)
  local inv, M = ref("inventory"), ref("materials")
  local out, idx = {}, {}
  if not (s and inv) then return out end
  for _, cid in ipairs(s.cids) do
    for _, g in ipairs(inv.itemList and inv.itemList(cid) or {}) do
      local k = "i:" .. tostring(g.id)
      local e = idx[k]
      if not e then e = { key = k, kind = "item", id = g.id, label = g.name or tostring(g.id), n = 0, each = (g.kg or 0) / math.max(1, g.n or 1) }; idx[k] = e; out[#out + 1] = e end
      e.n = e.n + (g.n or 0)
    end
  end
  for _, cid in ipairs(s.cids) do
    for _, it in ipairs(inv.items and inv.items(cid) or {}) do
      local k = "m:" .. tostring(it.mat)
      local e = idx[k]
      if not e then e = { key = k, kind = "mat", id = it.mat, label = (M and M.label and M.label(it.mat)) or it.mat, n = 0, each = (it.kg or 0) / math.max(1, it.n or 1) }; idx[k] = e; out[#out + 1] = e end
      e.n = e.n + (it.n or 0)
    end
  end
  return out
end

-- the pods
local function flights()
  local l = save and save.get and save.get("courier.list")
  return type(l) == "table" and l or {}
end
function get(id) local r = save.get("courier." .. tostring(id)); return type(r) == "table" and r or nil end
function inFlight(bid)
  for _, id in ipairs(flights()) do local r = get(id); if r and r.to == bid then return r end end
  return nil
end
function list()
  local out = {}
  for _, id in ipairs(flights()) do local r = get(id); if r then out[#out + 1] = r end end
  return out
end

-- A base (by id) as a destination: → rec | nil
local function base_of(bid)
  local BS = ref("bases")
  for _, r in ipairs((BS and BS.list) and BS.list() or {}) do if r.id == bid then return r end end
  return nil
end
-- The bill for `lines` ({ { key, n } … }) from source `srcKey` to base `bid`.
-- → { kg, fee, secs, dist, same, lines = { { key, kind, id, label, n, kg } … } } | nil, why
function bill(bid, srcKey, lines)
  local dst, src = base_of(bid), sourceOf(srcKey)
  if not dst then return nil, "no base here" end
  if not src then return nil, "no such source" end
  if src.bid == bid then return nil, "that is this base" end
  local stock = {}
  for _, e in ipairs(stockOf(src)) do stock[e.key] = e end
  local out, kg = {}, 0
  for _, l in ipairs(lines or {}) do
    local e = stock[l.key]
    local n = math.floor(l.n or 0)
    if not e or e.n < n then return nil, string.format("%s: %d asked, %d there", e and e.label or tostring(l.key), n, e and e.n or 0) end
    if n > 0 then
      out[#out + 1] = { key = e.key, kind = e.kind, id = e.id, label = e.label, n = n, kg = e.each * n }
      kg = kg + e.each * n
    end
  end
  local same = src.b == dst.b
  local dist = 0
  if same then
    local BS = ref("bases")
    local b = space and space.body and space.body(dst.b)
    dist = (BS and BS.groundDist) and BS.groundDist(b and b.radius, src.x, src.y, src.z, dst.x, dst.y, dst.z)
      or math.sqrt((src.x - dst.x) ^ 2 + (src.y - dst.y) ^ 2 + (src.z - dst.z) ^ 2)
  end
  local q = quote(kg, dist, same)
  return { kg = kg, fee = q.fee, secs = q.secs, dist = dist, same = same, lines = out, src = src, dst = dst }
end
-- Send it. → id | nil, why
function request(bid, srcKey, lines)
  local B, why = bill(bid, srcKey, lines)
  if not B then return nil, why end
  local co, inv, BT = ref("company"), ref("inventory"), ref("base_tower")
  if not inv then return nil, "no stores" end
  local powered = nil
  if B.src.bid and BT and BT.power then powered = BT.power(B.src.bid).powered == true end
  local sandbox = save.get("game.mode") == "sandbox"
  local w = whyNot(B.lines, inFlight(bid) ~= nil, powered, (not sandbox and co and co.balance) and co.balance() or nil, B.fee)
  if w then return nil, w end
  if not sandbox and co and co.spend and not co.spend(B.fee, string.format("courier: %.0f kg from %s to %s", B.kg, B.src.label, tostring(B.dst.n))) then
    return nil, "can't afford it: " .. money(B.fee)
  end
  local id = (tonumber(save.get("courier.seq")) or 0) + 1
  save.set("courier.seq", id)
  local cid = "courier:" .. tostring(id)
  if inv.setCap then inv.setCap(cid, 1e6) end
  -- the goods out of the source's containers, nearest the list's head first
  for _, l in ipairs(B.lines) do
    local left = l.n
    for _, c in ipairs(B.src.cids) do
      if left <= 0 then break end
      if l.kind == "mat" then
        local h = inv.count(c, l.id) or 0
        if h > 0 then left = left - (inv.transfer(c, cid, l.id, math.min(h, left)) or 0) end
      else
        local h = inv.itemCount(c, l.id) or 0
        if h > 0 then left = left - (inv.moveItem(c, cid, l.id, math.min(h, left), { force = true }) or 0) end
      end
    end
  end
  local t = agency_now()
  local rec = { id = id, from = B.src.key, fromName = B.src.label, to = bid, toName = tostring(B.dst.n or bid), b = B.dst.b,
                x = B.dst.x, y = B.dst.y, z = B.dst.z, t0 = t, eta = t + B.secs, kg = B.kg, fee = B.fee, n = #B.lines }
  save.set("courier." .. tostring(id), rec)
  local l = flights()
  l[#l + 1] = id
  save.set("courier.list", l)
  PROF.sent = PROF.sent + 1
  if log then log(string.format("courier: pod %d, %.0f kg from %s to %s, %s, arrives in %s", id, B.kg, B.src.label, rec.toName, money(B.fee), etaLine(B.secs))) end
  return id, nil, B
end
-- Set pod `id` down at its base: a crate 8 m from the tower. → true | nil, why
function deliverNow(id)
  local r = get(id)
  local sv, inv = ref("salvage"), ref("inventory")
  if not (r and sv and sv.drop and inv) then return nil, "no pod" end
  local b = space and space.body and space.body(r.b)
  if not b then return nil, "its world is not here" end
  -- 8 m from the tower along the ground (any direction square to up), 30 m up: the drop finds the ground
  local l = math.sqrt(r.x * r.x + r.y * r.y + r.z * r.z)
  local ux, uy, uz = r.x / l, r.y / l, r.z / l
  -- (u × the axis least along it)
  local ax, ay, az = 1, 0, 0
  if math.abs(ux) > 0.9 then ax, ay, az = 0, 1, 0 end
  local tx, ty, tz = uy * az - uz * ay, uz * ax - ux * az, ux * ay - uy * ax
  local tl = math.sqrt(tx * tx + ty * ty + tz * tz)
  tx, ty, tz = tx / tl, ty / tl, tz / tl
  local px, py, pz = b.x + r.x + tx * 8 + ux * 30, b.y + r.y + ty * 8 + uy * 30, b.z + r.z + tz * 8 + uz * 30
  local cid = "courier:" .. tostring(id)
  local sid, kg = sv.drop(r.b, px, py, pz, nil, { from = cid, items = true, label = "Courier pod · from " .. tostring(r.fromName) })
  if not sid then
    -- (an empty pod: nothing to set down)
    if (inv.mass(cid) or 0) > 1e-6 then return nil, "the pod could not be set down" end
  end
  if inv.setCap then inv.setCap(cid, 0) end
  local l2 = flights()
  for i = #l2, 1, -1 do if l2[i] == id then table.remove(l2, i) end end
  save.set("courier.list", l2)
  if save.delete then save.delete("courier." .. tostring(id)) else save.set("courier." .. tostring(id), false) end
  PROF.landed = PROF.landed + 1
  local FT = ref("feats")
  if FT and FT.mark then pcall(FT.mark, "shipment_received", { b = r.b }) end
  if caption and now() > 1 then pcall(caption, string.format("Courier pod down at %s: %.0f kg from %s, by the tower", r.toName, kg or r.kg or 0, tostring(r.fromName))) end
  return true
end
function tick()
  local l = flights()
  if #l == 0 then return 0 end
  local t = agency_now()
  local n = 0
  for i = #l, 1, -1 do
    local r = get(l[i])
    if not r then table.remove(l, i); save.set("courier.list", l)
    elseif t >= (r.eta or 0) then
      -- (its base gone: it sets down where the tower stood all the same)
      if deliverNow(r.id) then n = n + 1 end
    end
  end
  return n
end

-- ── the menu on a tower ─────────────────────────────────────────────────────
local MAN = {}          -- base id → { src = key, lines = { [key] = n } }
local function man_lines(bid)
  local m = MAN[bid]
  local out = {}
  for k, n in pairs(m and m.lines or {}) do if n > 0 then out[#out + 1] = { key = k, n = n } end end
  table.sort(out, function(a, b) return a.key < b.key end)
  return out, m and m.src
end
function manifest(bid) return man_lines(bid) end
function addLine(bid, srcKey, key, n)
  local m = MAN[bid]
  if not m or m.src ~= srcKey then m = { src = srcKey, lines = {} }; MAN[bid] = m end
  m.lines[key] = math.max(0, (m.lines[key] or 0) + n)
end
function clearManifest(bid) MAN[bid] = nil end
local function provider(t, ctx)
  if not (t and t.node) then return {} end
  local ST, BS = ref("structures"), ref("bases")
  if not (ST and ST.partOfNode and BS and BS.byTower) then return {} end
  local rec, part = ST.partOfNode(t.node)
  if not part then return {} end
  local d = defs(part.id)
  if not (d and d.tower) then return {} end
  local base = BS.byTower(rec.id, part.uid)
  if not base or base.down then return {} end
  local bid = base.id
  local G = "Courier"
  local out = {}
  local fl = inFlight(bid)
  if fl then
    out[#out + 1] = { id = "cr_fly", type = "info", group = G, label = "Pod on its way", value = function()
        local r = get(fl.id)
        if not r then return "set down by the tower" end
        return string.format("%.0f kg from %s · arrives in %s", r.kg or 0, tostring(r.fromName), etaLine((r.eta or 0) - agency_now()))
      end }
  end
  out[#out + 1] = { id = "cr_req", type = "sub", group = G, label = "Request a shipment…", hint = "▸",
    sub = function()
      local rows = {}
      for _, s in ipairs(sources()) do
        if s.bid ~= bid then
          local stock = stockOf(s)
          rows[#rows + 1] = { id = "cr_s_" .. s.key, type = "sub", label = string.format("From %s", s.label), hint = #stock > 0 and string.format("%d kinds ▸", #stock) or "empty",
            enabled = #stock > 0, why = "nothing in its stores",
            sub = function()
              local r2 = {}
              for i, e in ipairs(stockOf(s)) do
                if i > 40 then break end
                local step = e.kind == "mat" and math.max(1, math.floor(MAT_STEP / math.max(0.001, e.each) + 0.5)) or 1
                r2[#r2 + 1] = { id = "cr_l_" .. e.key, type = "action", keep = true,
                  label = function()
                    local m = MAN[bid]
                    local n = (m and m.src == s.key and m.lines[e.key]) or 0
                    return string.format("%s%s", e.label, n > 0 and string.format("  ·  %d on the manifest", n) or "")
                  end,
                  hint = string.format("%d there · +%d", e.n, math.min(step, e.n)),
                  act = function()
                    local m = MAN[bid]
                    local n = (m and m.src == s.key and m.lines[e.key]) or 0
                    if n >= e.n then return false, "that is all there is" end
                    addLine(bid, s.key, e.key, math.min(step, e.n - n))
                    return true
                  end }
              end
              return r2, "FROM " .. string.upper(s.label)
            end }
        end
      end
      if #rows == 0 then rows[#rows + 1] = { id = "cr_none", type = "info", label = "No other base", value = "found a second base, or stock the spaceport's warehouse" } end
      return rows, "REQUEST A SHIPMENT"
    end }
  local lines, srcKey = man_lines(bid)
  if #lines > 0 then
    out[#out + 1] = { id = "cr_man", type = "info", group = G, label = "Manifest", value = function()
        local l2, sk = man_lines(bid)
        local B, why = bill(bid, sk, l2)
        if not B then return tostring(why) end
        local names = {}
        for i, l in ipairs(B.lines) do if i <= 3 then names[#names + 1] = string.format("%d × %s", l.n, l.label) end end
        if #B.lines > 3 then names[#names + 1] = string.format("+%d more", #B.lines - 3) end
        return string.format("%s · %.0f kg from %s", table.concat(names, ", "), B.kg, B.src.label)
      end }
    out[#out + 1] = { id = "cr_send", type = "action", group = G,
      label = function()
        local l2, sk = man_lines(bid)
        local B = bill(bid, sk, l2)
        return B and string.format("Send the pod: %s, arrives in %s", money(B.fee), etaLine(B.secs)) or "Send the pod"
      end,
      hint = function()
        local l2, sk = man_lines(bid)
        local B = bill(bid, sk, l2)
        return B and (B.same and string.format("%.1f km", B.dist / 1000) or "another world") or ""
      end,
      enabled = function()
        local l2, sk = man_lines(bid)
        local B = bill(bid, sk, l2)
        if not B then return false end
        local co, BT = ref("company"), ref("base_tower")
        local powered = nil
        if B.src.bid and BT and BT.power then powered = BT.power(B.src.bid).powered == true end
        return whyNot(B.lines, inFlight(bid) ~= nil, powered, co and co.balance and co.balance() or nil, B.fee) == nil
      end,
      why = function()
        local l2, sk = man_lines(bid)
        local B, w = bill(bid, sk, l2)
        if not B then return w end
        local co, BT = ref("company"), ref("base_tower")
        local powered = nil
        if B.src.bid and BT and BT.power then powered = BT.power(B.src.bid).powered == true end
        return whyNot(B.lines, inFlight(bid) ~= nil, powered, co and co.balance and co.balance() or nil, B.fee)
      end,
      act = function()
        local l2, sk = man_lines(bid)
        local id, why, B = request(bid, sk, l2)
        if id then clearManifest(bid) end
        if ctx and ctx.toast then ctx.toast(id and string.format("pod away: %.0f kg, here in %s", B.kg, etaLine(B.secs)) or tostring(why), not id) end
        return id ~= nil, why
      end }
    out[#out + 1] = { id = "cr_clear", type = "action", group = G, label = "Clear the manifest", keep = true,
      act = function() clearManifest(bid); return true end }
  end
  return out
end
providerFn = provider

local reg_on, reg_t, tick_t = false, -10, -10
function start(node)
  if findScripts then
    local all = findScripts("courier")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  MAN, reg_on = {}, false
end
function update(node, dt)
  if not reg_on and now() - reg_t > 1.0 then
    reg_t = now()
    local reg = ref("context_registry")
    if reg and reg.register then reg.register("prop", provider, { id = "courier", order = 8 }); reg_on = true end
  end
  if now() - tick_t < 1.0 then return end
  tick_t = now()
  tick()
end
