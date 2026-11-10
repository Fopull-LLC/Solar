-- FLUID NET — the scene half of the base's pipes and tanks (sandbox plan S7;
-- docs/base-building.md §17). The rules are fluids.lua's (pure).
--
-- On the Build Kit node (scenes/system.ron) beside room_air and reactor_plant.
--
--   NETWORKS  found in each structure's records (fluids.build: union-find on
--             the ports), re-found when the records change (debounced
--             SOLVE_WAIT), never in a frame. A tank's contents, a bottle's
--             charge are kept by part across a rebuild and in the save.
--   THE CLOCK every network is stepped on the agency clock at EVERY s (5 Hz)
--             and at once on a change (a valve, a pump, a fill). A load
--             catches it up: in CHUNK s pieces, the rooms' air advanced to
--             the same moment between them (the O2 Generators' water cells
--             are filled by the network and drained by the air).
--   COUPLINGS an O2 Generator's water cell (room_air.cellOf / fillCell, its
--             draw genDraw; its hydrogen to the bottles piped to its H2
--             nozzle, else vented), a reactor's primary through the
--             pressuriser's makeup nozzle (reactor_plant.primaryOf: its
--             pressure, its inventory, what it boils off and loses at a
--             break; makeupTo gives it what flowed in), a Room Gas Outlet
--             (room_air.setInject), the base grid (the pumps: gridAux)
--   READOUTS  the menus on every piece, the FLUIDS overlay (F7 with the kit
--             open): each pipe by its substance with chevrons the way it
--             flows, tank levels, gauges, pumps, the reactor loops'
--             inventory and any break, and each network's card with its
--             LIMITED BY line
--
-- SAVE: fl.<sid> = { a (agency clock), x = { { u, x } … } } (lists, not keyed by uid)
--
-- Probes: nets(sid), stepNow(), content(sid, uid), setContent(sid, uid, kg),
-- setOn(sid, uid, on), readout(sid, uid), overlay, overlayAlways, drawn, PROF.

EVERY = 0.2
SOLVE_WAIT = 0.5
CHUNK = 3600
SAVE_EVERY = 5.0
PROF = { build_ms = 0, step_ms = 0, nets = 0, segs = 0 }
PRICE = { water = 0.6, coolant = 4.0, fuel = 1.1 }     -- $ a kg from the base stores (fuel: $11 a unit)
GAS_PRICE = { o2 = 3.0, n2 = 1.5, h2 = 9.0 }           -- $ a kg to recharge a rack

overlay = false
overlayAlways = false
drawn = { lines = 0, labels = 0 }

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function valid(n) return n ~= nil and n.valid ~= false end
local function now() return time or 0 end
local function agency_now()
  local dp = ref("deployables")
  if dp and dp.agencyClock then local ok, t = pcall(dp.agencyClock); if ok and type(t) == "number" then return t end end
  return tonumber(save and save.get and save.get("agency.clock")) or 0
end
local function wall() return (app and app.wallClock) and app.wallClock() or nil end
local function defs(id) local pb = ref("parts_base"); return pb and pb.partInfo(id) or nil end
local function FL() return ref("fluids") end

local N = {}          -- sid → { built, nets = { { net, st, rep } }, a, content = { [uid] = kg }, rec }
local ver, pending = -1, {}
local tick_t, save_t = -10, -10

function nets(sid) local e = N[sid]; return e and e.nets or nil end
function entry(sid) return N[sid] end

local function part_state(sid, uid)
  local ST = ref("structures")
  return ST and ST.partState and ST.partState(sid, uid) or nil
end
local function set_part_state(sid, uid, k, v)
  local ST = ref("structures")
  if not (ST and ST.partState and ST.setPartState) then return end
  local st = ST.partState(sid, uid) or {}
  local t = {}
  for a, b in pairs(st) do t[a] = b end
  t[k] = v
  ST.setPartState(sid, uid, next(t) and t or nil)
end

-- the room a piece stands in, and its pressure (Pa) — room_air's
local function room_of(sid, p, d)
  local RA, RL = ref("room_air"), ref("rooms")
  local s = RA and RA.state and RA.state(sid)
  if not (s and s.R and RL) then return nil end
  local b = d.box or { 0, 0, 0, 1, 0, 0 }
  local r = RL.roomAt(s.R, p.x or 0, (p.y or 0) + 0.5 * (b[3] + b[4]), p.z or 0)
  if not r then return nil end
  local a = RA.airOf(sid, r.id)
  return r, a
end

-- What the scene knows of a piece now (fluids.build's ext).
local function ext_for(e)
  return function(kind, p, d, ent)
    local sid = e.sid
    local st = part_state(sid, p.uid) or {}
    local F = FL()
    if kind == "element" then
      local fl = d.fl or {}
      if fl.kind == "pump" then
        local BG = ref("base_grid")
        local served = BG and BG.partServed and BG.partServed(sid, p.uid)
        return { on = (not st.off) and served ~= false }
      elseif fl.kind == "valve" then return { on = not st.shut }
      elseif fl.kind == "reg" then return { pset = tonumber(st.pset) } end
      return {}
    elseif kind == "tank" or kind == "bottle" then
      return { x = e.content[p.uid] }
    elseif kind == "consumer" then
      if d.fl and d.fl.hose then
        return { x = e.content[p.uid], r = e.hoseRate and e.hoseRate[p.uid] or 0 }
      end
      -- (X6) a mixer's or an electrolyser's water cell: its draw is the machine's (refinery.lua)
      if d.it and (d.it.kind == "machine" or d.it.kind == "electro") then
        local RF, MC = ref("refinery"), ref("machines")
        local M = MC and MC.MACH and MC.MACH[d.it.m]
        return { x = e.content[p.uid] or 0, cap = (M and M.cell) or 40, r = RF and RF.waterDraw and RF.waterDraw(sid, p.uid) or 0 }
      end
      local RA = ref("room_air")
      local w, cap = nil, nil
      if RA and RA.cellOf then w, cap = RA.cellOf(sid, p.uid) end
      local r = (RA and RA.genDraw) and RA.genDraw(sid, p.uid) or 0
      return { x = w or 0, cap = cap or 20, r = r }
    elseif kind == "primary" then
      local RP = ref("reactor_plant")
      local q = RP and RP.primaryOf and RP.primaryOf(sid, p.uid)
      if q then return { x = q.inv * q.mass, cap = q.mass, p = q.p, r = q.drain } end
      return { x = 0, cap = 0.001, p = F and F.P_ATM or 101325, r = 0 }
    elseif kind == "outlet" then
      local r, a = room_of(sid, p, d)
      local pa = a and a.p or 0
      return { p = pa * 101325, room = r and r.id or nil, on = r ~= nil and r.sealed and pa < 0.995 and not a.venting }
    elseif kind == "vent" then
      local RA = ref("room_air")
      local s = RA and RA.state and RA.state(sid)
      local pout = s and s.out and s.out.p or 0
      return { p = pout * 101325 }
    end
    return {}
  end
end

-- (re)build structure sid's networks from its records
local function build(sid)
  local F, ST = FL(), ref("structures")
  local rec = ST and ST.get(sid)
  if not (F and rec) then N[sid] = nil return end
  local w0 = wall()
  local old = N[sid]
  local e = old or { sid = sid, content = {}, a = nil, hoseRate = {} }
  e.rec = rec
  if not old then
    local sv = save and save.get and save.get("fl." .. tostring(sid))
    if type(sv) == "table" then
      e.a = tonumber(sv.a)
      for _, q in ipairs(type(sv.x) == "table" and sv.x or {}) do
        if type(q) == "table" and tonumber(q.u) then e.content[tonumber(q.u)] = tonumber(q.x) end
      end
    end
  end
  -- keep what the old networks held, by part
  if old and old.nets then
    for _, E in ipairs(old.nets) do
      for i, node in ipairs(E.net.nodes) do
        if node.kind == "tank" and node.uid and (node.tk == "tank" or node.tk == "bottle") then e.content[node.uid] = E.st.x[i] end
      end
    end
  end
  local B = F.build(rec, defs, ext_for(e))
  e.built = B
  e.nets = {}
  for _, net in ipairs(B.nets) do
    local st = F.newState(net)
    e.nets[#e.nets + 1] = { net = net, st = st, rep = nil }
  end
  -- (contents now known for every tank: kept in e.content)
  for _, E in ipairs(e.nets) do
    for i, node in ipairs(E.net.nodes) do
      if node.kind == "tank" and node.uid and (node.tk == "tank" or node.tk == "bottle") then e.content[node.uid] = E.st.x[i] end
    end
    -- the readouts at once
    E.rep = F.advance(E.net, E.st, 0)
  end
  if not e.a then e.a = agency_now() end
  N[sid] = e
  if #e.nets == 0 then N[sid] = nil end
  if w0 then PROF.build_ms = (wall() - w0) * 1000 end
  local BG = ref("base_grid")
  if BG and BG.markDirty then BG.markDirty() end
end

-- refresh the live figures of the nodes and elements before a step
local function refresh(e, E)
  local ext = ext_for(e)
  local net = E.net
  for i, node in ipairs(net.nodes) do
    if node.uid then
      local p, d = nil, nil
      for _, q in ipairs(e.rec.bp or {}) do if q.uid == node.uid then p = q end end
      d = p and defs(p.id)
      if p and d then
        if node.kind == "tank" and node.tk == "consumer" then
          local L = ext("consumer", p, d)
          E.st.x[i] = math.max(0, math.min(node.cap or 1e9, L.x or E.st.x[i] or 0))
          node.r = L.r or 0
          if E.st.tm[i] ~= "N" and E.st.x[i] < (node.cap or 0) - 1e-9 and E.st.tm[i] == "F" then E.st.tm[i] = "N" end
        elseif node.kind == "tank" and node.tk == "primary" then
          local L = ext("primary", p, d)
          node.c, node.cap, node.r = L.p + (node.zh or 0), math.max(L.cap or 1, 1e-3), L.r or 0
          E.st.x[i] = math.max(0, math.min(node.cap, L.x or 0))
          if E.st.tm[i] == "F" and E.st.x[i] < node.cap - 1e-6 then E.st.tm[i] = "N" end
        elseif node.kind == "fixed" and node.out then
          local L = ext(node.out, p, d)
          node.p = (L.p or node.p) + (node.zh or 0)
          node.room = L.room
        end
      end
    end
  end
  for _, el in ipairs(net.els) do
    if el.uid and (el.kind == "pump" or el.kind == "valve" or el.kind == "reg" or el.kind == "switch") then
      local p = nil
      for _, q in ipairs(e.rec.bp or {}) do if q.uid == el.uid then p = q end end
      local d = p and defs(p.id)
      if p and d then
        if el.kind == "switch" then
          local L = ext(d.fl and d.fl.kind or "vent", p, d)
          if d.fl and d.fl.kind == "outlet" then el.on = L.on ~= false end
        elseif not net.mixed then
          local L = ext("element", p, d)
          if el.kind == "reg" then el.pset = L.pset or (d.fl and d.fl.pset) or el.pset else el.on = L.on ~= false end
        end
      end
    end
  end
end

-- after a step: what flowed into the couplings
local function couple(e, E, dt)
  local F = FL()
  local RA, RP = ref("room_air"), ref("reactor_plant")
  local net, st, rep = E.net, E.st, E.rep
  for i, node in ipairs(net.nodes) do
    if node.kind == "tank" and node.tk == "consumer" and node.uid then
      local d = defs((function() for _, q in ipairs(e.rec.bp) do if q.uid == node.uid then return q.id end end end)() or "")
      if d and d.fl and d.fl.hose then
        e.content[node.uid] = st.x[i]
        e.hoseServed = e.hoseServed or {}
        e.hoseServed[node.uid] = (rep.served and rep.served[i] or 0)
      elseif d and d.it and (d.it.kind == "machine" or d.it.kind == "electro") then
        -- (X6) what the machine drew from its cell this step
        e.content[node.uid] = st.x[i]
        local RF = ref("refinery")
        if RF and RF.waterServed then RF.waterServed(e.sid, node.uid, rep.served and rep.served[i] or 0, dt, st.x[i]) end
      elseif RA and RA.fillCell then
        -- what came in = what it holds more + what the generator drew meanwhile
        local x0 = E.x0 and E.x0[i] or st.x[i]
        local came = (st.x[i] - x0) + (rep.served and rep.served[i] or 0)
        if came > 1e-12 then RA.fillCell(e.sid, node.uid, came) end
      end
    elseif node.kind == "tank" and node.tk == "primary" and node.uid and RP and RP.makeupTo then
      local x0 = E.x0 and E.x0[i] or st.x[i]
      local came = (st.x[i] - x0) + (rep.served and rep.served[i] or 0)
      RP.makeupTo(e.sid, node.uid, math.max(0, came) / math.max(dt, 1e-9))
    elseif node.kind == "tank" and node.uid then
      e.content[node.uid] = st.x[i]
    elseif node.kind == "fixed" and node.out == "outlet" and node.room and RA and RA.setInject then
      -- the gas into the room, by the flow through its switch
      local q = 0
      for k, el in ipairs(net.els) do if el.v == i and el.kind == "switch" then q = q + math.max(0, rep.q and rep.q[k] or 0) end end
      E.inj = E.inj or {}
      E.inj[node.room] = (E.inj[node.room] or 0) + q
    end
  end
  -- the rooms' gas: one figure per room and substance
  if RA and RA.setInject then
    for rid, q in pairs(E.inj or {}) do
      RA.setInject(e.sid, rid, net.sub == "o2" and q or 0, net.sub == "n2" and q or 0)
    end
    E.inj = nil
  end
  -- (X6) what a machine made into this network (the electrolyser's propellant): into its tanks
  local RF = ref("refinery")
  if RF and RF.takeMade then
    for _, h in ipairs(net.src or {}) do
      local made = RF.takeMade(e.sid, h.part.uid)
      if made > 0 then
        local left = made
        for j, node in ipairs(net.nodes) do
          if node.kind == "tank" and node.tk == "tank" and node.sub == "fuel" and left > 0 then
            local put = math.min(left, (node.cap or 0) - (st.x[j] or 0))
            if put > 0 then st.x[j] = st.x[j] + put; left = left - put; e.content[node.uid] = st.x[j]; if st.tm[j] ~= "N" then st.tm[j] = "N" end end
          end
        end
        if left > 1e-9 and RF.noteLost then RF.noteLost(e.sid, h.part.uid, left) end
      end
    end
  end
  -- the hydrogen the generators made: into the bottles on their H2 line, else vented
  if RA and RA.takeH2 then
    for _, h in ipairs(net.h2 or {}) do
      local made = RA.takeH2(e.sid, h.part.uid)
      if made > 0 then
        local left = made
        if net.sub == "h2" then
          for j, node in ipairs(net.nodes) do
            if node.kind == "tank" and node.tk == "bottle" and left > 0 then
              local put = math.min(left, (node.cap or 0) - (st.x[j] or 0))
              if put > 0 then st.x[j] = st.x[j] + put; left = left - put; e.content[node.uid] = st.x[j]; if st.tm[j] ~= "N" then st.tm[j] = "N" end end
            end
          end
        end
        e.h2vented = (e.h2vented or 0) + left
        e.h2kept = (e.h2kept or 0) + (made - left)
      end
    end
  end
end

local function step_struct(e, a)
  local F = FL()
  if not (F and e.nets) then return end
  if not e.a then e.a = a end
  local dt = math.min(a - e.a, F.CATCH_MAX)
  if dt <= 0 then return end
  local RA = ref("room_air")
  -- (a catch-up in hour-long pieces, the rooms' air brought to each moment)
  local t0 = a - dt
  local left = dt
  while left > 1e-9 do
    local h = math.min(left, CHUNK)
    if dt > CHUNK and RA and RA.advanceTo then RA.advanceTo(e.sid, t0 + (dt - left)) end
    for _, E in ipairs(e.nets) do
      refresh(e, E)
      E.x0 = {}
      for i, x in pairs(E.st.x) do E.x0[i] = x end
      E.rep = F.advance(E.net, E.st, h, { events = {}, segs = 0 })
      PROF.segs = PROF.segs + (E.rep.segs or 0)
      couple(e, E, h)
    end
    left = left - h
  end
  e.a = a
end

function stepNow()
  local a = agency_now()
  for _, e in pairs(N) do step_struct(e, a) end
end

-- ── the grid's view: a pump draws its kW while switched on and served ─────
function gridAux(sid, uid)
  local e = N[sid]
  if not e then return 0 end
  for _, E in ipairs(e.nets) do
    for _, el in ipairs(E.net.els) do
      if el.uid == uid and el.kind == "pump" then
        local st = part_state(sid, uid)
        if st and st.off then return 0 end
        local d = nil
        for _, q in ipairs(e.rec.bp) do if q.uid == uid then d = defs(q.id) end end
        return d and d.fl and d.fl.kw or 0
      end
    end
  end
  return 0
end

-- ── controls and probes ─────────────────────────────────────────────────────
local function touch(sid) local e = N[sid]; if e then step_struct(e, agency_now()); e.dirty = true; tick_t = -10 end end
function setOn(sid, uid, on)
  local d = nil
  local ST = ref("structures")
  local rec = ST and ST.get(sid)
  for _, q in ipairs(rec and rec.bp or {}) do if q.uid == uid then d = defs(q.id) end end
  if not (d and d.fl) then return false end
  touch(sid)
  if d.fl.kind == "pump" then set_part_state(sid, uid, "off", (not on) or nil)
  elseif d.fl.kind == "valve" then set_part_state(sid, uid, "shut", (not on) or nil) end
  local BG = ref("base_grid")
  if BG and BG.markDirty then BG.markDirty() end
  if audio and audio.play then pcall(audio.play, "audio/foley/switch_2.ogg", { track = "UI", volume = 0.4 }) end
  return true
end
function isOn(sid, uid)
  local st = part_state(sid, uid)
  return not (st and (st.off or st.shut))
end
function setPset(sid, uid, pa) touch(sid); set_part_state(sid, uid, "pset", pa) end
-- the node or element of part uid: → E, kind, index
local function find_part(sid, uid)
  local e = N[sid]
  if not e then return nil end
  for _, E in ipairs(e.nets) do
    for i, node in ipairs(E.net.nodes) do if node.uid == uid and node.kind ~= "junction" then return E, "node", i end end
    for k, el in ipairs(E.net.els) do if el.uid == uid and not el.nozzle then return E, "el", k end end
  end
  return nil
end
function content(sid, uid)
  local E, kind, i = find_part(sid, uid)
  if E and kind == "node" then return E.st.x[i], E.net.nodes[i].cap end
  return nil
end
function setContent(sid, uid, kg)
  local E, kind, i = find_part(sid, uid)
  if not (E and kind == "node") then return false end
  local node = E.net.nodes[i]
  step_struct(N[sid], agency_now())
  E.st.x[i] = math.max(0, math.min(node.cap or kg, kg))
  E.st.tm[i] = "N"
  N[sid].content[uid] = E.st.x[i]
  N[sid].dirty = true
  return true
end
-- A piece's numbers now: → { p (Pa), q (kg/s), x, cap, mode, sub, lim }
function readout(sid, uid)
  local E, kind, i = find_part(sid, uid)
  if not E then return nil end
  local rep, net, st = E.rep or {}, E.net, E.st
  local F = FL()
  local o = { sub = net.sub, mixed = net.mixed, lim = F and F.limitedBy(net, st, rep) or nil, why = net.why }
  if kind == "node" then
    local node = net.nodes[i]
    o.x, o.cap, o.p, o.mode, o.r = st.x[i], node.cap, rep.p and rep.p[i] and (rep.p[i] - (node.zh or 0)), st.tm[i], node.r
    o.inflow = rep.inflow and rep.inflow[i]
  else
    local el = net.els[i]
    o.q, o.mode = rep.q and rep.q[i], st.em[i]
    -- (static pressures: the piezometric less ρgy)
    o.pu = rep.p and rep.p[el.u] and (rep.p[el.u] - (net.nodes[el.u].zh or 0))
    o.pv = rep.p and rep.p[el.v] and (rep.p[el.v] - (net.nodes[el.v].zh or 0))
    o.p = o.pu
    o.on = el.on
  end
  return o
end
function netOf(sid, uid) local E = find_part(sid, uid); return E end

-- ── save ────────────────────────────────────────────────────────────────────
local function save_struct(e)
  if not (save and save.set) then return end
  local xs = {}
  for u, x in pairs(e.content) do xs[#xs + 1] = { u = u, x = x } end
  save.set("fl." .. tostring(e.sid), { a = e.a, x = xs })
end
function saveNow() for _, e in pairs(N) do save_struct(e) end end

-- ── the menus ───────────────────────────────────────────────────────────────
local function bar(p) return string.format("%.2f bar", (p or 0) / 1e5) end
local function kgs(q) q = q or 0; if math.abs(q) < 0.01 then return string.format("%.1f g/s", q * 1000) end return string.format("%.2f kg/s", q) end
local function provider(t, ctx)
  if not (t and t.node) then return {} end
  local ST = ref("structures")
  if not (ST and ST.partOfNode) then return {} end
  local FB = ref("field_builder")
  local rec, part
  if FB and FB.pickTarget then rec, part = FB.pickTarget(t) else rec, part = ST.partOfNode(t.node) end
  if not part then return {} end
  local d = defs(part.id) or {}
  if not d.fl then return {} end
  local sid, uid = rec.id, part.uid
  local fl = d.fl
  local F = FL()
  local out = {}
  local G = "Fluids"
  out[#out + 1] = { id = "fl_net", type = "info", label = "Network", group = G, value = function()
    local o = readout(sid, uid)
    if not o then return "not piped to anything yet" end
    if o.mixed then return tostring(o.why[1]) end
    local s = o.sub and F.SUB[o.sub] and F.SUB[o.sub].label or "empty: no tank on it"
    return s .. ((o.why and o.why[1]) and (" · " .. o.why[1]) or "")
  end }
  if fl.kind == "tank" or fl.kind == "bottle" or fl.kind == "consumer" then
    out[#out + 1] = { id = "fl_level", type = "info", label = (fl.kind == "bottle") and "Charge" or "Level", group = G, value = function()
      local o = readout(sid, uid)
      if not o then return "—" end
      local sub = F.SUB[fl.sub or "water"]
      if fl.kind == "bottle" then return string.format("%.1f of %.1f kg · %s", o.x or 0, o.cap or 0, bar(o.p)) end
      local L = (o.x or 0) / (sub.rho or 1000) * 1000
      return string.format("%.0f L (%.0f %%) · %.0f kg · outlet %s", L, 100 * (o.x or 0) / math.max(o.cap or 1, 1e-9), o.x or 0, bar(o.p))
    end }
    local price = (fl.kind == "bottle") and (GAS_PRICE[fl.sub] or 3) or (PRICE[fl.sub] or 1)
    out[#out + 1] = { id = "fl_fill", type = "action", group = G, keep = true,
      label = (fl.kind == "bottle") and ((fl.sub == "h2") and "Empty it (vent the hydrogen)" or "Recharge from the base stores") or "Fill from the base stores",
      hint = function() local x, cap = content(sid, uid); if not x then return nil end
        if fl.sub == "h2" then return string.format("%.1f kg", x) end
        return string.format("$%d", math.floor((cap - x) * price + 0.5)) end,
      act = function()
        local x, cap = content(sid, uid)
        if not x then return false, "not piped" end
        if fl.sub == "h2" then setContent(sid, uid, 0); return true end
        local cost = math.floor((cap - x) * price + 0.5)
        if cap - x < 0.01 then return false, "already full" end
        local co = ref("company")
        if co and co.spend and cost > 0 and not co.spend(cost, "fluids: " .. tostring(fl.sub)) then return false, "can't afford it" end
        setContent(sid, uid, cap)
        if audio and audio.play then pcall(audio.play, "audio/foley/hiss_cylinder.ogg", { track = "SFX", volume = 0.35 }) end
        return true
      end }
    if fl.hose then
      out[#out + 1] = { id = "fl_hose", type = "action", group = G, label = "Fuel the nearest craft (30 m of hose)",
        hint = function() local c = hoseTarget(sid, uid); return c and string.format("%s · %.0f units of room", c.label or "craft", c.room) or "no craft in reach" end,
        act = function() local c = hoseTarget(sid, uid); if not c then return false, "no craft within 30 m" end
          N[sid].hoseOn = N[sid].hoseOn or {}; N[sid].hoseOn[uid] = c.node; touch(sid); return true end }
    end
  elseif fl.kind == "pump" or fl.kind == "valve" then
    out[#out + 1] = { id = "fl_on", type = "toggle", label = (fl.kind == "pump") and "Pump running" or "Valve open", group = G, keep = true,
      on = function() return isOn(sid, uid) end, act = function(want) setOn(sid, uid, want) end,
      hint = function() local BG = ref("base_grid"); return (fl.kind == "pump" and BG and BG.partServed and BG.partServed(sid, uid) == false) and "no power" or nil end }
    out[#out + 1] = { id = "fl_flow", type = "info", label = "Flow", group = G, value = function()
      local o = readout(sid, uid)
      if not o then return "—" end
      if fl.kind == "pump" and o.mode == "stall" then return string.format("STALLED: %s against its %.1f bar head", bar((o.pv or 0) - (o.pu or 0)), (fl.H0 or 0) / 1e5) end
      return string.format("%s · in %s · out %s", kgs(o.q), bar(o.pu), bar(o.pv))
    end }
  elseif fl.kind == "reg" then
    out[#out + 1] = { id = "fl_reg", type = "info", label = "Set", group = G, value = function()
      local st = part_state(sid, uid); local ps = tonumber(st and st.pset) or fl.pset
      local o = readout(sid, uid)
      return string.format("%s · %s · %s", bar(ps), o and (o.mode == "T" and "throttling" or (o.mode == "O" and "wide open (inlet under its set)" or "shut")) or "—", o and kgs(o.q) or "") end }
    out[#out + 1] = { id = "fl_regup", type = "action", label = "Set +1 bar", group = G, keep = true,
      act = function() local st = part_state(sid, uid); setPset(sid, uid, math.min(40e5, (tonumber(st and st.pset) or fl.pset) + 1e5)); return true end }
    out[#out + 1] = { id = "fl_regdn", type = "action", label = "Set −1 bar", group = G, keep = true,
      act = function() local st = part_state(sid, uid); setPset(sid, uid, math.max(1.1e5, (tonumber(st and st.pset) or fl.pset) - 1e5)); return true end }
  elseif fl.kind == "gauge" or fl.kind == "pipe" or fl.kind == "check" or fl.kind == "outlet" or fl.kind == "vent" then
    out[#out + 1] = { id = "fl_read", type = "info", label = (fl.kind == "gauge") and "Gauge" or "Line", group = G, value = function()
      local o = readout(sid, uid)
      if not o then return "—" end
      return string.format("%s · %s", bar(o.p), kgs(o.q)) end }
  end
  out[#out + 1] = { id = "fl_lim", type = "info", label = "Limited by", group = G, value = function()
    local o = readout(sid, uid); return (o and o.lim) or "nothing: it flows as piped" end }
  return out, d.label
end
providerFn = provider
local reg_on = false

-- ── the fuel hose: the nearest craft within reach (not one held on a stand,
-- which the stand fuels) ────────────────────────────────────────────────────
-- (X6) kg of room in the Fuel Tanks on a machine's source nozzle (the
-- electrolyser's), or 0 when none is piped to it
function srcRoom(sid, uid)
  local e = N[sid]
  if not e then return 0 end
  for _, E in ipairs(e.nets or {}) do
    for _, h in ipairs(E.net.src or {}) do
      if h.part.uid == uid then
        if E.net.sub ~= "fuel" or E.net.mixed then return 0 end
        local room = 0
        for j, node in ipairs(E.net.nodes) do
          if node.kind == "tank" and node.tk == "tank" and node.sub == "fuel" then room = room + math.max(0, (node.cap or 0) - (E.st.x[j] or 0)) end
        end
        return room
      end
    end
  end
  return 0
end
function hoseTarget(sid, uid)
  local ST = ref("structures")
  local rec = ST and ST.get(sid)
  if not (rec and findScripts and space and space.body) then return nil end
  local p = nil
  for _, q in ipairs(rec.bp) do if q.uid == uid then p = q end end
  if not (p and ST.partPose) then return nil end
  local bx, by, bz = ST.partPose(rec, p, 0)
  local b = space.body(rec.b)
  if not (b and bx) then return nil end
  local best, bd = nil, 30
  for _, v in ipairs(findScripts("vessel_controller") or {}) do
    local n = v.node
    if valid(n) and not v.structureMode and v.fuelRoom then
      local d = math.sqrt((n.x - b.x - bx) ^ 2 + (n.y - b.y - by) ^ 2 + (n.z - b.z - bz) ^ 2)
      local ok, room = pcall(v.fuelRoom)
      if d < bd and ok and (room or 0) > 0.01 then best, bd = { node = n, v = v, room = room, label = v.craftName or "craft", d = d }, d end
    end
  end
  return best
end
local FUEL_KG = 10      -- a fuel unit (builder.FUEL_T_PER_UNIT: 0.01 t)
local HOSE_Q = 2.0      -- kg/s down the hose
local function hose_tick(e)
  for uid, n in pairs(e.hoseOn or {}) do
    local served = e.hoseServed and e.hoseServed[uid] or 0
    e.hoseServed = e.hoseServed or {}
    e.hoseServed[uid] = 0
    local c = hoseTarget(e.sid, uid)
    if not (c and c.node == n) then e.hoseOn[uid] = nil; e.hoseRate[uid] = 0
    else
      e.hoseRate[uid] = math.min(HOSE_Q, c.room * FUEL_KG)
      if served > 0 and c.v.fuelFill then pcall(c.v.fuelFill, (c.v.fuel or 0) + served / FUEL_KG) end
    end
  end
end

-- ── the FLUIDS overlay (lateUpdate: drawn poses, this frame's body read) ───
OVERLAY_R = 200
LABEL_R = 30          -- labels only this near the crew (the lines further)
local function overlay_on()
  if not overlay then return false end
  if overlayAlways then return true end
  local fb = ref("field_builder")
  return fb and fb.isOpen and fb.isOpen() or false
end
local AMBER, RED, DIM = { 1.0, 0.75, 0.25 }, { 1.0, 0.32, 0.25 }, { 0.55, 0.6, 0.62 }
function drawOverlay()
  drawn = { lines = 0, labels = 0, rings = 0 }
  if not (draw and draw.line) then return drawn end
  local KS, F = ref("kit_snap"), FL()
  local a = find and find("Astronaut")
  if not (KS and F and valid(a)) then return drawn end
  local placed = {}
  local function label(x, y, z, t1, t2, col)
    if not (camera and camera.worldToScreen and draw.text) then return end
    if (x - a.x) ^ 2 + (y - a.y) ^ 2 + (z - a.z) ^ 2 > LABEL_R * LABEL_R then return end
    local sx, sy, _, on = camera.worldToScreen(x, y, z)
    if not on then return end
    local w = math.max(#t1 * 9.5, #(t2 or "") * 7.6) + 16
    for _ = 1, 6 do
      local hit = false
      for _, b in ipairs(placed) do if math.abs(b[1] - sx) < (b[3] + w) / 2 and math.abs(b[2] - sy) < 40 then hit = true end end
      if not hit then break end
      sy = sy + 42
    end
    placed[#placed + 1] = { sx, sy, w }
    if draw.rect then draw.rect(sx - w / 2, sy - 4, w, t2 and 40 or 22, 0.02, 0.03, 0.04, 0.66, 4) end
    draw.text(sx, sy, t1, 16, col[1], col[2], col[3], 1, "center")
    if t2 then draw.text(sx, sy + 19, t2, 13, col[1], col[2], col[3], 0.9, "center") end
    drawn.labels = drawn.labels + 1
  end
  local RP = ref("reactor_plant")
  if RP and RP.drawFluids then RP.drawFluids(label) end
  for sid, e in pairs(N) do
    local rec = e.rec
    local b = space.body(rec.b)
    if b then
      local fr = KS.frameOf(rec)
      local ox, oy, oz = b.x + fr.O.x, b.y + fr.O.y, b.z + fr.O.z
      local R, U, Fw = fr.R, fr.U, fr.F
      local function W(x, y, z) return ox + R.x * x + U.x * y + Fw.x * z, oy + R.y * x + U.y * y + Fw.y * z, oz + R.z * x + U.z * y + Fw.z * z end
      local cx, cy, cz = W(0, 0, 0)
      if (cx - a.x) ^ 2 + (cy - a.y) ^ 2 + (cz - a.z) ^ 2 < OVERLAY_R ^ 2 then
        for _, E in ipairs(e.nets) do
          local net, rep, st = E.net, E.rep or {}, E.st
          local sub = net.sub and F.SUB[net.sub]
          local col = net.mixed and RED or (sub and sub.col or DIM)
          for _, sg in ipairs(net.segs) do
            local q = rep.q and rep.q[sg.el] or 0
            local x1, y1, z1 = W(sg.a[1], sg.a[2] + 0.12, sg.a[3])
            local x2, y2, z2 = W(sg.b[1], sg.b[2] + 0.12, sg.b[3])
            local el = net.els[sg.el]
            local off = el and ((el.kind == "valve" and not el.on) or (el.kind == "pump" and (not el.on or st.em[sg.el] == "stall")))
            local c = off and AMBER or col
            draw.line(x1, y1, z1, x2, y2, z2, c[1], c[2], c[3], 0.95)
            drawn.lines = drawn.lines + 1
            -- chevrons the way it flows (more of them the more it carries)
            if math.abs(q) > 1e-7 then
              local dx, dy, dz = x2 - x1, y2 - y1, z2 - z1
              if q < 0 then x1, y1, z1, x2, y2, z2 = x2, y2, z2, x1, y1, z1; dx, dy, dz = -dx, -dy, -dz end
              local L = math.sqrt(dx * dx + dy * dy + dz * dz)
              if L > 0.2 then
                local ux, uy, uz = dx / L, dy / L, dz / L
                local sx, sy_, sz = U.y * uz - U.z * uy, U.z * ux - U.x * uz, U.x * uy - U.y * ux
                local n = math.max(1, math.floor(L / 0.5))
                local ph = ((now() * 0.8) % 1)
                for k = 0, n - 1 do
                  local f = (k + ph) / n
                  local px, py, pz = x1 + dx * f, y1 + dy * f, z1 + dz * f
                  local h = 0.09
                  draw.line(px, py, pz, px - ux * h + sx * h, py - uy * h + sy_ * h, pz - uz * h + sz * h, c[1], c[2], c[3], 1)
                  draw.line(px, py, pz, px - ux * h - sx * h, py - uy * h - sy_ * h, pz - uz * h - sz * h, c[1], c[2], c[3], 1)
                  drawn.lines = drawn.lines + 2
                end
              end
            end
          end
          -- the nodes: tanks' levels, gauges, pumps, the network's card
          local first = nil
          for i, node in ipairs(net.nodes) do
            if node.uid and node.kind == "tank" then
              local x, y, z = W(node.x, node.y + 1.6, node.z)
              local p = (rep.p and rep.p[i] or 0) - (node.zh or 0)
              local t1, t2
              if node.tk == "primary" then
                t1 = nil      -- (reactor_plant.drawFluids labels the primary)
              elseif node.tk == "consumer" then
                t1 = string.format("%s · cell %.1f of %.0f kg", node.label or "consumer", st.x[i] or 0, node.cap or 0)
                t2 = (st.tm[i] == "S" or st.tm[i] == "D") and "STARVED" or string.format("draws %s", kgs(node.r))
              else
                t1 = string.format("%s · %.0f %%", node.label or "tank", 100 * (st.x[i] or 0) / math.max(node.cap or 1, 1e-9))
                t2 = string.format("%.1f kg · %s", st.x[i] or 0, bar(p))
              end
              if t1 then label(x, y, z, t1, t2, (st.tm[i] == "S" or st.tm[i] == "D") and RED or col) end
              first = first or { x, y, z }
            end
          end
          for k, el in ipairs(net.els) do
            if (el.kind == "pump" or (el.kind == "cond" and el.uid and not el.nozzle and el.len and el.len <= 0.31)) and el.uid then
              local node = net.nodes[el.u]
              if node and node.x then
                local x, y, z = W(node.x, node.y + 0.5, node.z)
                local q = rep.q and rep.q[k] or 0
                if el.kind == "pump" then
                  local t = (not el.on) and "PUMP OFF" or (st.em[k] == "stall" and "PUMP STALLED" or string.format("PUMP %s", kgs(q)))
                  local pu = (rep.p and rep.p[el.u] or 0) - (net.nodes[el.u].zh or 0)
                  local pv = (rep.p and rep.p[el.v] or 0) - (net.nodes[el.v].zh or 0)
                  label(x, y, z, t, string.format("in %s · out %s", bar(pu), bar(pv)), (not el.on or st.em[k] == "stall") and AMBER or col)
                else
                  label(x, y, z, "GAUGE " .. bar((rep.p and rep.p[el.u] or 0) - (net.nodes[el.u].zh or 0)), kgs(q), col)
                end
              end
            end
          end
          if first then
            local lim = F.limitedBy(net, st, rep)
            label(first[1], first[2] + 0.9, first[3], string.format("NETWORK · %s", sub and sub.label:upper() or "EMPTY"),
                  "LIMITED BY " .. (lim or "nothing"), lim and AMBER or col)
          end
        end
      end
    end
  end
  return drawn
end

-- ── the driver ──────────────────────────────────────────────────────────────
function start(node)
  if findScripts then
    local all = findScripts("fluid_net")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  N, ver, pending = {}, -1, {}
  tick_t, save_t = -10, -10
end

function update(node, dt)
  if not reg_on then
    local reg = ref("context_registry")
    if reg and reg.register then reg.register("prop", provider, { id = "fluid_net", order = 8 }); reg_on = true end
  end
  local ST = ref("structures")
  if not (ST and FL()) then return end
  local t = now()
  if ST.version ~= ver then
    ver = ST.version
    local seen = {}
    for _, rec in ipairs(ST.list()) do
      local has = false
      for _, p in ipairs(rec.bp or {}) do
        local d = defs(p.id)
        if d and d.ports and (d.fl or (function() for _, pt in ipairs(d.ports) do if pt.fluid then return true end end end)()) then has = true break end
      end
      if has then seen[rec.id] = true; pending[rec.id] = pending[rec.id] or t end
    end
    for sid in pairs(N) do if not seen[sid] then N[sid] = nil; if save and save.set then save.set("fl." .. tostring(sid), false) end end end
  end
  for sid, t0 in pairs(pending) do
    if t - t0 >= SOLVE_WAIT then
      pending[sid] = nil
      local e = N[sid]
      if e then step_struct(e, agency_now()) end
      build(sid)
    end
  end
  if next(N) == nil then return end
  if t - tick_t >= EVERY then
    tick_t = t
    local w0 = wall()
    local a = agency_now()
    for _, e in pairs(N) do step_struct(e, a); hose_tick(e) end
    if w0 then PROF.step_ms = (wall() - w0) * 1000 end
    PROF.nets = 0
    for _, e in pairs(N) do PROF.nets = PROF.nets + #e.nets end
  end
  if t - save_t >= SAVE_EVERY then save_t = t; saveNow() end
end

-- Drawn over the world: after the camera has placed this frame's view
-- (planet_camera.deferLate; docs/positions-and-frames.md rule 2)
local pc_late = nil
local function after_camera(node, dt, fn)
  if not (pc_late and pc_late.valid) then pc_late = findScript("planet_camera", { quiet = true }) end
  if pc_late and pc_late.valid and pc_late.deferLate then pc_late.deferLate(node, dt, fn) else fn(node, dt) end
end
local function late_overlay() if overlay_on() then drawOverlay() end end
function lateUpdate(node, dt)
  after_camera(node, dt, late_overlay)
end
