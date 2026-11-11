-- TERMINAL PAGES — what a base console shows and works (scripts/terminal.lua).
--
-- (The interaction plan §4.1–4.3, slices S3 and S4.) Every page is
-- registered as data with terminal.registerPage and returns rows in the
-- right-click menus' entry contract, so each key goes through the same
-- whyNot / warnOf as that piece's own menu: refused only for a physical
-- reason (not plumbed, knocked askew, a cable has it until Local control, a
-- tripped breaker must be reset, the console is dark), and a dangerous
-- choice is never refused, only said ("closing MU-1 cuts the makeup to the
-- primary", "protection BYPASSED: nothing will stop a meltdown").
--
--   STATUS   the base's screen lines (kit_live.screenLines), the plant, the
--            newest log lines
--   POWER    each grid (made, drawn, the store), every breaker (close, open,
--            trip test, reset), the lights (load shedding), transformers
--   FLUIDS   every network (substance, what limits it), tanks, every pump
--            and valve (run / stop, open / shut), regulators, the reactor's
--            coolant pumps
--   DOORS    every door: shut / open, its pressures, Lock, Hold open, an
--            airlock's Cycle to this door
--   AIR      every room (pressure, O2, CO2), the scrubbers and O2 generators,
--            equalise valves
--   LOGIC    the controllers (a PLC's RUN is its enable), levers, buttons,
--            readings; a cable-driven device's Local control (its bypass)
--   CREW     who is where, their roles and doses
--   LOG      the base log (scripts/base_log.lua), and a note of your own
--   REACTOR  (the reactor's desk, S4) the live readings, a painted trend at
--            2 Hz, the controls: SCRAM, reset, start-up, setpoint, rods,
--            pumps, makeup, protection, cool-down, turbine
--   ALARMS   (the reactor's desk) the annunciator, the plant's events, the
--            base's air alarms
--   LOG/DATA (a ruin's terminal) the recovered log (the site's lore), its
--            Data Core, and `lootRows` (S5 adds a ruin's loot here)
--
-- A console reaches only what is wired to it (scope.sids: its structure and
-- every structure on its grid).
--
-- On the ContextLib node beside terminal.lua. Nothing runs a frame but an
-- airlock cycle asked from a console (kept asked until its door opens).

defaults = {}

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind, { quiet = true }) or nil; refs[kind] = r end
  return r
end
local function now() return time or 0 end
local function defs(id) local pb = ref("parts_base"); return pb and pb.partInfo and pb.partInfo(id) or nil end
local function agency_now()
  local dp = ref("deployables")
  if dp and dp.agencyClock then local ok, t = pcall(dp.agencyClock); if ok and type(t) == "number" then return t end end
  return tonumber(save and save.get and save.get("agency.clock")) or 0
end
local function blog(sid, k, txt, who) local BL = ref("base_log"); if BL and BL.add then pcall(BL.add, sid, k, txt, who) end end

-- ── shared ──────────────────────────────────────────────────────────────────
-- the piece's number in its structure ("piece 109 of 148", as part_info's subtitle)
local function index_of(sid, uid)
  local ST = ref("structures")
  local rec = ST and ST.get and ST.get(sid)
  for i, q in ipairs(rec and rec.bp or {}) do if q.uid == uid then return i end end
  return nil
end
-- "P-3", or "Process Pump #37" (its piece number tells two alike apart)
local function name_of(sid, uid)
  local PI = ref("part_info")
  local tag = PI and PI.tagOf and PI.tagOf(sid, uid) or nil
  if tag then return tag end
  local ST = ref("structures")
  local p = ST and ST.getPart and ST.getPart(sid, uid)
  local d = p and defs(p.id)
  local i = index_of(sid, uid)
  return (d and d.label or "piece") .. (i and (" #" .. i) or "")
end
-- "P-3 · Process Pump" or "Process Pump #37"
local function title_of(sid, uid, d)
  local PI = ref("part_info")
  local tag = PI and PI.tagOf and PI.tagOf(sid, uid) or nil
  local lbl = d and d.label or "piece"
  if tag then return tag .. " · " .. lbl end
  local i = index_of(sid, uid)
  return lbl .. (i and (" #" .. i) or "")
end
-- What a page lists, by name (the lists are kept until the structures change:
-- a page described four times a second walks no records)
PRED = {
  breaker = function(d) return d.power and d.power.kind == "breaker" end,
  xfmr = function(d) return d.power and d.power.kind == "xfmr" end,
  fluid = function(d) return d.fl ~= nil and d.fl.kind ~= "pipe" end,
  rxpump = function(d) return d.pump ~= nil end,
  door = function(d) return d.door ~= nil end,
  machine = function(d) return d.life and not d.life.store and not d.life.receiver end,
  eqv = function(d) return d.eqv ~= nil end,
  logic = function(d) return d.lg ~= nil and d.lg.kind ~= "device" end,
  device = function(d) return d.lg ~= nil and d.lg.kind == "device" end,
  switch = function(d) return d.fl and (d.fl.kind == "pump" or d.fl.kind == "valve") end,
}
-- every piece of the console's reach of kind `name` (PRED): → { { sid, uid, p, d, rec, idx } }
local PC = { ver = nil, lists = {} }
local function pieces(scope, name, cap)
  local ST = ref("structures")
  if not ST then return {} end
  if PC.ver ~= ST.version then PC.ver, PC.lists = ST.version, {} end
  local sids = scope.sids or { scope.sid }
  local key = name .. ":" .. table.concat(sids, ",") .. ":" .. tostring(cap or 0)
  local got = PC.lists[key]
  if got then return got end
  local pred = PRED[name]
  local out = {}
  for _, sid in ipairs(sids) do
    local rec = ST.get(sid)
    for i, p in ipairs(rec and rec.bp or {}) do
      local d = defs(p.id)
      if d and pred(d, p) then
        out[#out + 1] = { sid = sid, uid = p.uid, p = p, d = d, rec = rec, idx = i }
        if cap and #out >= cap then break end
      end
    end
    if cap and #out >= cap then break end
  end
  PC.lists[key] = out
  return out
end
piecesOf = pieces
-- A key's gate: the console dark, then the system's own whyNot. → enabled, why
local function gate(scope, whyfn)
  return function()
    if scope.dark then return false end
    local ok, w = pcall(whyfn)
    return not (ok and w)
  end, function()
    if scope.dark then return scope.dark end
    local ok, w = pcall(whyfn)
    return ok and w or nil
  end
end
gateOf = gate
local function kw(v) v = v or 0; if math.abs(v) >= 100 then return string.format("%.0f kW", v) end return string.format("%.1f kW", v) end
local function pct(f) return string.format("%d %%", math.floor((f or 0) * 100 + 0.5)) end
local function T() return ref("terminal") end
local function reg(id, fn, opts) local t = T(); if t and t.registerPage then return t.registerPage(id, fn, opts) end end

local BASE = { desk = true, reactor = true, plc = true, fire = true, ruin = true }

-- ── STATUS ──────────────────────────────────────────────────────────────────
local function page_status(scope)
  local rows = {}
  local KL = ref("kit_live")
  local S = KL and KL.screenLines and KL.screenLines(scope.sid)
  rows[#rows + 1] = { type = "header", label = S and S.title or "BASE STATUS", col = 1 }
  for _, l in ipairs(S and S.lines or {}) do rows[#rows + 1] = { type = "line", text = l[1], level = l[2] and 1 or 0, col = 1 } end
  if #(scope.sids or {}) > 1 then
    local ST = ref("structures")
    local names = {}
    for i, sid in ipairs(scope.sids) do if i > 1 then local r = ST and ST.get(sid); names[#names + 1] = r and (T() and T().recName(r)) or tostring(sid) end end
    rows[#rows + 1] = { type = "header", label = "WIRED TO THIS CONSOLE", col = 2 }
    for i = 1, math.min(6, #names) do rows[#rows + 1] = { type = "line", text = names[i], col = 2 } end
    if #names > 6 then rows[#rows + 1] = { type = "line", text = string.format("and %d more", #names - 6), col = 2 } end
  end
  local RP = ref("reactor_plant")
  if RP and RP.plants then
    for _, e in pairs(RP.plants()) do
      if T().linked(scope, e.sid) then
        local pg = RP.page and RP.page(e)
        rows[#rows + 1] = { type = "header", label = "PLANT", col = 2 }
        rows[#rows + 1] = { type = "line", text = pg and pg.title or "REACTOR", level = (e.S and (e.S.scram or e.S.melt)) and 2 or 0, col = 2 }
        if pg and pg.lines and pg.lines[2] then rows[#rows + 1] = { type = "line", text = pg.lines[2][1], col = 2 } end
      end
    end
  end
  local BL = ref("base_log")
  if BL and BL.entries then
    local E = BL.entries(scope.sids, 6)
    rows[#rows + 1] = { type = "header", label = "LATEST", col = 2 }
    if #E == 0 then rows[#rows + 1] = { type = "line", text = "nothing logged yet", col = 2 } end
    for _, e in ipairs(E) do rows[#rows + 1] = { type = "line", text = BL.lineOf(e), level = BL.levelOf(e.k), col = 2 } end
  end
  return rows
end

-- ── POWER ───────────────────────────────────────────────────────────────────
local function page_power(scope)
  local rows = {}
  local BG, BP, KL = ref("base_grid"), ref("base_power"), ref("kit_live")
  if not (BG and BP) then return { { type = "line", text = "no power system", level = 1 } } end
  local g = BG.gridOfStruct and BG.gridOfStruct(scope.sid)
  rows[#rows + 1] = { type = "header", label = "GRID", col = 1 }
  if not g then
    rows[#rows + 1] = { type = "line", text = "NO BASE GRID: this structure is on no grid", level = 1, col = 1 }
  else
    local gid = g.id
    rows[#rows + 1] = { type = "info", col = 1, label = "Made / drawn", value = function()
      local s, M = BG.status(gid), BG.model(gid)
      return string.format("%s / %s", kw(s and s.supply), kw(M and M.need)) end,
      warn = function() local s = BG.status(gid); return s and (s.short or 0) > 0 end }
    rows[#rows + 1] = { type = "meter", col = 1, label = "Store", frac = function()
      local s, M = BG.status(gid), BG.model(gid); return (M and (M.C or 0) > 0) and (s and s.stored or 0) / M.C or 0 end,
      value = function() local s, M = BG.status(gid), BG.model(gid)
        if not (M and (M.C or 0) > 0) then return "no store" end
        return string.format("%.0f of %.0f EC", s and s.stored or 0, M.C) end,
      warn = function() local s, M = BG.status(gid), BG.model(gid); return M and (M.C or 0) > 0 and (s and s.stored or 0) / M.C < 0.15 end }
    rows[#rows + 1] = { type = "info", col = 1, label = "No sun", value = function()
      local left = BG.nightLeft and BG.nightLeft(gid)
      return left and string.format("%.1f h on the store", left / 3600) or "covered" end }
    rows[#rows + 1] = { type = "info", col = 1, label = "Short", value = function()
      local s = BG.status(gid); return (s and (s.short or 0) > 0) and string.format("%s: loads shed", kw(s.short)) or "none" end,
      warn = function() local s = BG.status(gid); return s and (s.short or 0) > 0 end }
    rows[#rows + 1] = { type = "info", col = 1, label = "Limited by", value = function() local s = BG.status(gid); return (s and s.limited) or "nothing" end }
  end
  -- the breakers
  local brs = pieces(scope, "breaker", 24)
  rows[#rows + 1] = { type = "header", label = string.format("BREAKERS (%d)", #brs), col = 2 }
  if #brs == 0 then rows[#rows + 1] = { type = "line", text = "no breaker panels wired here", col = 2 } end
  for _, b in ipairs(brs) do
    local sid, uid = b.sid, b.uid
    local function state() return BP.breakerState(sid, uid) end
    local en, why = gate(scope, function() return BG.whyNot and BG.whyNot(sid, uid, state() ~= "closed") end)
    rows[#rows + 1] = { id = "br_" .. sid .. "_" .. uid, type = "toggle", col = 2, keep = true, label = title_of(sid, uid, b.d),
      on = function() return state() == "closed" end,
      warn = function() return state() == "tripped" end,
      hint = function()
        local s = state()
        if s == "tripped" then return "TRIPPED" end
        if s == "open" then return "open" end
        local f = BG.partFlow and BG.partFlow(sid, uid) or {}
        return string.format("%.1f/%.0f kW", f.kW or 0, f.rating or 0)
      end,
      act = function(want)
        local wn = BG.warnOf and BG.warnOf(sid, uid, want) or nil
        BP.setBreaker(sid, uid, want, "hand")
        return true, wn
      end, enabled = en, why = why }
    if state() == "tripped" then
      local en2, why2 = gate(scope, function() return nil end)
      rows[#rows + 1] = { id = "brr_" .. sid .. "_" .. uid, type = "action", col = 2, keep = true, label = "Reset " .. name_of(sid, uid),
        hint = "closes it", act = function() BP.setBreaker(sid, uid, true, "hand"); return true end, enabled = en2, why = why2 }
    elseif state() == "closed" then
      local en2, why2 = gate(scope, function() return nil end)
      rows[#rows + 1] = { id = "brt_" .. sid .. "_" .. uid, type = "action", col = 2, keep = true, label = "Trip test " .. name_of(sid, uid),
        hint = "opens it as a fault does", danger = true,
        act = function() local wn = BG.warnOf and BG.warnOf(sid, uid, false) or nil; BP.setBreaker(sid, uid, false, "trip"); return true, wn end,
        enabled = en2, why = why2 }
    end
  end
  -- load shedding: the lights of each structure
  if KL and KL.lightsOf and KL.setLights then
    local any = false
    for _, sid in ipairs(scope.sids or {}) do
      local n = KL.lightsOf(sid)
      if n > 0 then
        if not any then rows[#rows + 1] = { type = "header", label = "LOAD SHEDDING", col = 1 }; any = true end
        local ST = ref("structures")
        local rec = ST and ST.get(sid)
        local en, why = gate(scope, function() return nil end)
        rows[#rows + 1] = { id = "lt_" .. sid, type = "toggle", col = 1, keep = true,
          label = "Lights · " .. ((rec and T() and T().recName(rec)) or tostring(sid)),
          on = function() local _, on = KL.lightsOf(sid); return on > 0 end,
          hint = function() local m, on = KL.lightsOf(sid); return string.format("%d/%d", on, m) end,
          act = function(want)
            local m = KL.setLights(sid, want)
            blog(sid, "power", string.format("%d lights switched %s", m, want and "on" or "off (load shed)"))
            return true
          end, enabled = en, why = why }
      end
    end
  end
  -- the transformers
  local xf = pieces(scope, "xfmr", 6)
  if #xf > 0 then
    rows[#rows + 1] = { type = "header", label = "TRANSFORMERS", col = 1 }
    for _, x in ipairs(xf) do
      rows[#rows + 1] = { type = "info", col = 1, label = name_of(x.sid, x.uid), value = function()
        local f = BG.partFlow and BG.partFlow(x.sid, x.uid) or {}
        return string.format("%s · loss %s", kw(f.kW), kw(f.loss)) end }
    end
  end
  return rows
end

-- ── FLUIDS ──────────────────────────────────────────────────────────────────
local function fl_toggle(scope, sid, uid, d, col)
  local FN = ref("fluid_net")
  local function on() return FN.isOn(sid, uid) end
  local en, why = gate(scope, function() return FN.whyNot(sid, uid, not on()) end)
  local pump = d.fl.kind == "pump"
  return { id = "fl_" .. sid .. "_" .. uid, type = "toggle", col = col, keep = true, label = title_of(sid, uid, d),
    on = on, onText = pump and "[ RUN ]" or "[OPEN]", offText = pump and "[STOP]" or "[SHUT]",
    hint = function()
      local o = FN.readout(sid, uid)
      if not o then return "unpiped" end
      if pump and o.mode == "stall" then return "STALLED" end
      local q = o.q or 0
      return math.abs(q) < 0.01 and string.format("%.0f g/s", q * 1000) or string.format("%.2f kg/s", q)
    end,
    warn = function() local o = FN.readout(sid, uid); return pump and o ~= nil and o.mode == "stall" end,
    tip = function() return on() and FN.warnOf(sid, uid, false) or nil end,
    act = function(want) return FN.setOn(sid, uid, want, "hand") end, enabled = en, why = why }
end
local function rx_pump_toggle(scope, sid, uid, d, col, hardwired)
  local RP = ref("reactor_plant")
  local function on() return RP.pumpOn(sid, uid) end
  local en, why = gate(hardwired and {} or scope, function() return RP.whyNot(sid, uid, not on()) end)
  local loop = "loop"
  local e = RP.plantOfPart and RP.plantOfPart(sid, uid)
  if e and e.pl then
    for _, nm in ipairs({ "pri", "sec" }) do for _, pu in ipairs(e.pl[nm] and e.pl[nm].pumps or {}) do if pu.uid == uid then loop = (nm == "pri") and "primary" or "secondary" end end end
  end
  return { id = "rxp_" .. sid .. "_" .. uid, type = "toggle", col = col, keep = true, label = title_of(sid, uid, d) .. " · " .. loop,
    on = on, onText = "[ RUN ]", offText = "[STOP]",
    hint = function() local BG = ref("base_grid"); return (BG and BG.partServed and BG.partServed(sid, uid) == false) and "NO POWER" or nil end,
    warn = function() local BG = ref("base_grid"); return BG and BG.partServed and BG.partServed(sid, uid) == false end,
    tip = function() return on() and RP.warnOf(sid, uid, false) or nil end,
    act = function(want) return RP.setPump(sid, uid, want, "hand") end, enabled = en, why = why }
end
local function page_fluids(scope)
  local rows = {}
  local FN, F = ref("fluid_net"), ref("fluids")
  if not FN then return { { type = "line", text = "no fluid system", level = 1 } } end
  local all = pieces(scope, "fluid", 80)
  -- by network: the net's index in its structure
  local groups, order = {}, {}
  for _, q in ipairs(all) do
    local E = FN.netOf(q.sid, q.uid)
    local key = E and E or ("none:" .. q.sid)
    if not groups[key] then groups[key] = { E = E, sid = q.sid, list = {} }; order[#order + 1] = key end
    local G = groups[key]
    G.list[#G.list + 1] = q
  end
  local n = 0
  for _, key in ipairs(order) do
    local G = groups[key]
    n = n + 1
    local E = G.E
    local sub = E and E.net.sub and F and F.SUB and F.SUB[E.net.sub] and F.SUB[E.net.sub].label or (E and "empty" or "not piped")
    rows[#rows + 1] = { type = "header", label = string.format("NETWORK %d · %s", n, tostring(sub):upper()) }
    if E then
      rows[#rows + 1] = { type = "line", text = function()
        local okl, lim = pcall(F.limitedBy, E.net, E.st, E.rep or {})
        if E.net.mixed then return tostring(E.net.why and E.net.why[1] or "two substances meet: nothing flows") end
        return "LIMITED BY " .. tostring(okl and lim or "nothing: it flows as piped") end,
        level = E.net.mixed and 1 or 0 }
    end
    for _, q in ipairs(G.list) do
      local k = q.d.fl.kind
      local sid, uid = q.sid, q.uid
      if k == "pump" or k == "valve" then
        rows[#rows + 1] = fl_toggle(scope, sid, uid, q.d)
      elseif k == "tank" or k == "bottle" or k == "consumer" then
        rows[#rows + 1] = { type = "meter", label = title_of(sid, uid, q.d), frac = function()
          local x, cap = FN.content(sid, uid); return (x and cap and cap > 0) and x / cap or 0 end,
          value = function()
            local o = FN.readout(sid, uid)
            if not o then return "—" end
            return string.format("%.0f kg · %.2f bar", o.x or 0, (o.p or 0) / 1e5) end }
      elseif k == "reg" then
        local en, why = gate(scope, function() return nil end)
        rows[#rows + 1] = { id = "reg_" .. sid .. "_" .. uid, type = "slider", label = title_of(sid, uid, q.d), keep = true,
          get = function() local st = ref("structures").partState(sid, uid); return (tonumber(st and st.pset) or q.d.fl.pset or 1e5) / 1e5 end,
          set = function(v) FN.setPset(sid, uid, v * 1e5); blog(sid, "fluid", string.format("%s set to %.1f bar", name_of(sid, uid), v)) end,
          min = 1.1, max = 40, step = 1, fmt = function(v) return string.format("%.1f bar", v) end, enabled = en, why = why }
      elseif k == "gauge" then
        rows[#rows + 1] = { type = "info", label = title_of(sid, uid, q.d), value = function()
          local o = FN.readout(sid, uid); return o and string.format("%.2f bar", (o.p or 0) / 1e5) or "—" end }
      end
    end
  end
  -- the reactor's coolant pumps (their loops are the plant's, not a fluid network)
  local rx = pieces(scope, "rxpump", 12)
  if #rx > 0 and ref("reactor_plant") then
    rows[#rows + 1] = { type = "header", label = "REACTOR LOOPS" }
    for _, q in ipairs(rx) do rows[#rows + 1] = rx_pump_toggle(scope, q.sid, q.uid, q.d) end
  end
  if #rows == 0 then rows[#rows + 1] = { type = "line", text = "no pumps, valves or tanks wired here" } end
  return rows
end

-- ── DOORS ───────────────────────────────────────────────────────────────────
CYC = {}                  -- airlock cycles asked from a console: { sid, uid, till }
local function page_doors(scope)
  local rows = {}
  local KL, RA = ref("kit_live"), ref("room_air")
  local doors = pieces(scope, "door", 40)
  if #doors == 0 then return { { type = "line", text = "no doors wired here" } } end
  rows[#rows + 1] = { type = "header", label = string.format("DOORS (%d)", #doors), col = 1 }
  local half = math.ceil(#doors / 2)
  if #doors > 1 then rows[#rows + 1] = { type = "header", label = "DOORS (cont.)", col = 2 } end
  for i, q in ipairs(doors) do
    local sid, uid = q.sid, q.uid
    local col = (i <= half) and 1 or 2
    local first = #rows + 1
    local function hold() return KL and KL.doorHold and KL.doorHold(sid, uid) or nil end
    rows[#rows + 1] = { type = "info", label = title_of(sid, uid, q.d), value = function()
      local o = KL and KL.doorOpen and KL.doorOpen(sid, uid)
      local s = (o == nil) and "far" or ((o > 0.99) and "OPEN" or ((o < 0.01) and "shut" or "moving"))
      local h = hold()
      if h == "lock" then s = s .. " · LOCKED" elseif h == "open" then s = s .. " · held open" end
      local st = RA and RA.state and RA.state(sid)
      local dp = st and RA.door_dp and RA.door_dp(st, uid)
      if dp and dp > 0.02 then s = s .. string.format(" · Δp %.2f atm", dp) end
      return s end,
      warn = function() return hold() == "lock" end }
    local en, why = gate(scope, function() return KL and KL.doorWhyNot and KL.doorWhyNot(sid, uid, "lock") end)
    rows[#rows + 1] = { id = "dl_" .. sid .. "_" .. uid, type = "toggle", keep = true, label = "  Lock " .. name_of(sid, uid),
      on = function() return hold() == "lock" end, onText = "[LOCKED]", offText = "[ free ]",
      act = function(want) return KL.setDoorHold(sid, uid, want and "lock" or nil, "hand") end, enabled = en, why = why }
    if RA and RA.isInterlocked and RA.isInterlocked(sid, uid) then
      local en2, why2 = gate(scope, function() return nil end)
      rows[#rows + 1] = { id = "dc_" .. sid .. "_" .. uid, type = "action", keep = true, label = "  Cycle the airlock to " .. name_of(sid, uid),
        hint = function() for _, c in ipairs(CYC) do if c.sid == sid and c.uid == uid then return "CYCLING" end end return "airlock" end,
        act = function()
          for i2 = #CYC, 1, -1 do if CYC[i2].sid == sid then table.remove(CYC, i2) end end
          CYC[#CYC + 1] = { sid = sid, uid = uid, till = now() + 60 }
          blog(sid, "door", string.format("airlock cycled to %s", name_of(sid, uid)))
          return true, "the airlock cycles: its other doors shut, the chamber matches the far side, then it opens"
        end, enabled = en2, why = why2 }
    else
      local en3, why3 = gate(scope, function() return KL and KL.doorWhyNot and KL.doorWhyNot(sid, uid, "open") end)
      rows[#rows + 1] = { id = "dh_" .. sid .. "_" .. uid, type = "toggle", keep = true, label = "  Hold " .. name_of(sid, uid) .. " open",
        on = function() return hold() == "open" end,
        act = function(want) return KL.setDoorHold(sid, uid, want and "open" or nil, "hand") end, enabled = en3, why = why3 }
    end
    for k = first, #rows do rows[k].col = col end
  end
  return rows
end

-- ── AIR ─────────────────────────────────────────────────────────────────────
local function page_air(scope)
  local rows = {}
  local RA = ref("room_air")
  if not RA then return { { type = "line", text = "no air system", level = 1 } } end
  local any = false
  for _, sid in ipairs(scope.sids or {}) do
    local R = RA.roomsOf and RA.roomsOf(sid)
    if R and #R.rooms > 0 then
      any = true
      local ST = ref("structures")
      local rec = ST and ST.get(sid)
      rows[#rows + 1] = { type = "header", label = "ROOMS · " .. tostring((rec and T() and T().recName(rec)) or sid), col = 1 }
      for _, r in ipairs(R.rooms) do
        local rid = r.id
        rows[#rows + 1] = { type = "info", col = 1, label = string.format("Room %s%s · %.0f m³", tostring(rid), r.airlock and " (airlock)" or "", r.m3 or 0),
          value = function()
            local q = RA.airOf(sid, rid)
            if not q then return "—" end
            local s = string.format("%.2f atm · O2 %.0f %% · CO2 %.1f %%", q.p or 0, 100 * (q.o2 or 0) / math.max(q.p or 0, 1e-6), 100 * (q.co2 or 0) / math.max(q.p or 0, 1e-6))
            if not r.sealed then s = s .. " · NOT SEALED" end
            if q.venting then s = s .. " · VENTING" end
            if (q.crew or 0) > 0 then s = s .. string.format(" · %d crew", q.crew) end
            return s
          end,
          warn = function() local q = RA.airOf(sid, rid); return q ~= nil and (not q.breathable or q.venting) and r.sealed end }
      end
    end
  end
  if not any then rows[#rows + 1] = { type = "line", text = "no sealed rooms wired here", col = 1 } end
  local mach = pieces(scope, "machine", 20)
  rows[#rows + 1] = { type = "header", label = "LIFE SUPPORT", col = 2 }
  if #mach == 0 then rows[#rows + 1] = { type = "line", text = "no scrubbers or O2 generators", col = 2 } end
  for _, q in ipairs(mach) do
    local sid, uid = q.sid, q.uid
    local function on() return RA.machineOn(sid, uid) end
    local en, why = gate(scope, function() return RA.whyNot(sid, uid, not on()) end)
    rows[#rows + 1] = { id = "lf_" .. sid .. "_" .. uid, type = "toggle", col = 2, keep = true, label = title_of(sid, uid, q.d),
      on = on, onText = "[ RUN ]", offText = "[STOP]",
      hint = function() local w = RA.runWhy and RA.runWhy(sid, uid); return (w and w ~= "switched off") and "IDLE" or nil end,
      warn = function() local w = RA.runWhy and RA.runWhy(sid, uid); return w ~= nil and w ~= "switched off" end,
      tip = function() return (RA.runWhy and RA.runWhy(sid, uid)) or (on() and RA.warnOf(sid, uid, false)) or nil end,
      act = function(want) return RA.setMachine(sid, uid, want, "hand") end, enabled = en, why = why }
  end
  local eq = pieces(scope, "eqv", 12)
  if #eq > 0 then
    rows[#rows + 1] = { type = "header", label = "EQUALISE VALVES", col = 2 }
    for _, q in ipairs(eq) do
      local sid, uid = q.sid, q.uid
      local en, why = gate(scope, function() return nil end)
      rows[#rows + 1] = { id = "eq_" .. sid .. "_" .. uid, type = "toggle", col = 2, keep = true, label = title_of(sid, uid, q.d),
        on = function() return RA.equaliseOpen(sid, uid) end, onText = "[OPEN]", offText = "[SHUT]",
        hint = function() local s = RA.equaliseEta and RA.equaliseEta(sid, uid); return (s and s > 0) and string.format("%.0f s", s) or nil end,
        act = function(want)
          RA.setEqualise(sid, uid, want)
          blog(sid, "air", string.format("%s %s", name_of(sid, uid), want and "opened" or "shut"))
          return true
        end, enabled = en, why = why }
    end
  end
  return rows
end

-- ── LOGIC ───────────────────────────────────────────────────────────────────
local KIND = { plc = "PLC", lever = "LEVER", button = "BUTTON", sensor = "SENSOR", timer = "TIMER", latch = "LATCH", counter = "COUNTER",
  cmp = "COMPARATOR", lamp = "LAMP", alarm = "ALARM", keypad = "KEYPAD", tx = "RADIO TX", rx = "RADIO RX" }
local function page_logic(scope)
  local rows = {}
  local LN = ref("logic_net")
  if not LN then return { { type = "line", text = "no logic network", level = 1 } } end
  local list = pieces(scope, "logic", 40)
  rows[#rows + 1] = { type = "header", label = "CONTROLLERS AND READINGS", col = 1 }
  if #list == 0 then rows[#rows + 1] = { type = "line", text = "no logic pieces wired here", col = 1 } end
  for _, q in ipairs(list) do
    local sid, uid, k = q.sid, q.uid, q.d.lg.kind
    local function ro() return LN.readout and LN.readout(sid, uid) or nil end
    if k == "plc" then
      local en, why = gate(scope, function() return nil end)
      rows[#rows + 1] = { id = "plc_" .. sid .. "_" .. uid, type = "toggle", col = 1, keep = true, label = title_of(sid, uid, q.d) .. " · RUN",
        on = function() local o = ro(); return not (o and o.stop) end, onText = "[ RUN ]", offText = "[STOP]",
        warn = function() local o = ro(); return o ~= nil and o.osc == true end,
        hint = function() local o = ro(); return o and o.osc and "NOT SETTLING" or nil end,
        act = function(want)
          LN.setRun(sid, uid, want)
          blog(sid, "logic", string.format("%s %s", name_of(sid, uid), want and "set to RUN" or "STOPPED: its outputs drop"))
          return true, (not want) and "stopped: every output of its ladder drops" or nil
        end, enabled = en, why = why }
      rows[#rows + 1] = { id = "plced_" .. sid .. "_" .. uid, type = "action", col = 1, label = "  Program its ladder…", hint = "editor",
        enabled = function() return not scope.dark end, why = function() return scope.dark end,
        act = function()
          local t = T()
          if t and t.close then t.close() end
          if LN.editorOpen then LN.editorOpen(sid, uid) end
          return true
        end }
    elseif k == "lever" then
      local en, why = gate(scope, function() return nil end)
      rows[#rows + 1] = { id = "lv_" .. sid .. "_" .. uid, type = "toggle", col = 1, keep = true, label = title_of(sid, uid, q.d),
        on = function() return LN.lever(sid, uid) end,
        act = function(want) LN.setLever(sid, uid, want); blog(sid, "logic", string.format("%s thrown %s", name_of(sid, uid), want and "on" or "off")); return true end,
        enabled = en, why = why }
    elseif k == "button" then
      local en, why = gate(scope, function() return nil end)
      rows[#rows + 1] = { id = "bt_" .. sid .. "_" .. uid, type = "action", col = 1, keep = true, label = "Press " .. title_of(sid, uid, q.d),
        act = function() LN.press(sid, uid); return true end, enabled = en, why = why }
    else
      rows[#rows + 1] = { type = "info", col = 1, label = title_of(sid, uid, q.d), value = function()
        local o = ro()
        if not o then return "—" end
        local s = (KIND[k] or k:upper()) .. "  " .. ((o.q and "ON") or "off")
        if type(o.v) == "number" then s = s .. string.format("  %.2f%s", o.v, o.unit and (" " .. o.unit) or "") end
        if o.left and o.left > 0 then s = s .. string.format("  %.0f s", o.left) end
        return s end,
        warn = function() local o = ro(); return o ~= nil and (o.osc == true) end }
      if k == "latch" then
        local en, why = gate(scope, function() return nil end)
        rows[#rows + 1] = { id = "lr_" .. sid .. "_" .. uid, type = "action", col = 1, keep = true, label = "  Reset " .. name_of(sid, uid),
          act = function() LN.resetNode(sid, uid); return true end, enabled = en, why = why }
      end
    end
  end
  -- the devices a cable drives: their bypass (Local control)
  local drv = pieces(scope, "device", 60)
  local shown = 0
  for _, q in ipairs(drv) do
    local sid, uid = q.sid, q.uid
    if LN.drivenBy and LN.drivenBy(sid, uid) then
      if shown == 0 then rows[#rows + 1] = { type = "header", label = "DRIVEN BY CABLES · LOCAL CONTROL", col = 2 } end
      shown = shown + 1
      local en, why = gate(scope, function() return nil end)
      rows[#rows + 1] = { id = "loc_" .. sid .. "_" .. uid, type = "toggle", col = 2, keep = true, label = title_of(sid, uid, q.d),
        on = function() return LN.localControl(sid, uid) end, onText = "[LOCAL]", offText = "[CABLE]",
        hint = function() local _, from = LN.drivenBy(sid, uid); return from end,
        warn = function() return LN.localControl(sid, uid) end,
        act = function(want)
          LN.setLocal(sid, uid, want)
          blog(sid, "logic", string.format("%s on %s", name_of(sid, uid), want and "LOCAL control: its cable is ignored" or "cable control again"))
          return true, want and "its cable no longer drives it: what the logic wanted is yours to do by hand" or nil
        end, enabled = en, why = why }
    end
  end
  if shown == 0 then
    rows[#rows + 1] = { type = "header", label = "DRIVEN BY CABLES", col = 2 }
    rows[#rows + 1] = { type = "line", text = "no device here is driven by a Signal Cable", col = 2 }
  end
  return rows
end

-- ── CREW ────────────────────────────────────────────────────────────────────
local function page_crew(scope)
  local rows = {}
  local C = ref("crew")
  if not (C and C.roster) then return { { type = "line", text = "no roster", level = 1 } } end
  local rec = scope.rec
  local act = C.activeId and C.activeId()
  local RA = ref("room_air")
  local csid, crid = nil, nil
  if RA and RA.crewRoom then csid, crid = RA.crewRoom() end
  rows[#rows + 1] = { type = "header", label = "ROSTER" }
  for _, r in ipairs(C.roster()) do
    if r.status ~= "dead" then
      local id = r.id
      local role = C.roleName and C.roleName(r) or (C.role and C.role(r)) or "crew"
      rows[#rows + 1] = { type = "info", label = string.format("%s%s · %s", tostring(r.name or "?"), id == act and " (you)" or "", tostring(role)),
        value = function()
          local q = C.get(id) or r
          local w
          if q.status == "afoot" then
            local here = rec and q.body == rec.b and q.x and math.sqrt((q.x - rec.x) ^ 2 + (q.y - rec.y) ^ 2 + (q.z - rec.z) ^ 2) < 150
            w = here and "here, on foot" or ("on foot · " .. tostring(q.body or "?"))
            if id == act and csid and T().linked(scope, csid) and crid then w = string.format("here · Room %s", tostring(crid)) end
          elseif q.status == "aboard" then w = "aboard " .. tostring(q.craftName or "a craft")
          else w = tostring(q.status or "at the agency") end
          local dose = C.doseOf and C.doseOf(id) or 0
          if dose > 0.0005 then w = w .. string.format(" · dose %.1f %%", dose * 100) end
          if q.downed then w = w .. " · DOWNED" end
          return w
        end,
        warn = function() local q = C.get(id) or r; return q.downed or (C.doseOf and C.doseOf(id) or 0) > 0.25 end }
    end
  end
  local dead = 0
  for _, r in ipairs(C.roster()) do if r.status == "dead" then dead = dead + 1 end end
  if dead > 0 then rows[#rows + 1] = { type = "line", text = string.format("%d on the memorial", dead) } end
  return rows
end

-- ── LOG ─────────────────────────────────────────────────────────────────────
local function page_log(scope)
  local rows = {}
  local BL = ref("base_log")
  if not BL then return { { type = "line", text = "no log", level = 1 } } end
  local E = BL.entries(scope.sids, 60)
  rows[#rows + 1] = { type = "header", label = string.format("BASE LOG · newest first · %d", #E) }
  if not scope.readonly then
    rows[#rows + 1] = { id = "log_note", type = "action", label = "Write a note in the log…", hint = "✎",
      act = function()
        local BP = ref("blueprints")
        if not (BP and BP.prompt) then return false, "no prompt" end
        BP.prompt({ title = "A note in the base log", line = "What the next shift should know.", text = "", placeholder = "Checked the north seals.",
          maxLen = 80, ok = "Log it", onOk = function(text) if text and text:match("%S") then blog(scope.sid, "note", text) end return true end })
        return true
      end }
  end
  if #E == 0 then rows[#rows + 1] = { type = "line", text = "nothing logged yet: trips, alarms, pumps, valves and doors land here" } end
  for _, e in ipairs(E) do rows[#rows + 1] = { type = "line", text = BL.lineOf(e), level = BL.levelOf(e.k) } end
  return rows
end

-- ── the ruin's terminal: its recovered log and its data ─────────────────────
lootRows = {}             -- S5: functions (scope, ctx) → rows, shown on a ruin's DATA page
local function page_ruin_log(scope)
  local rows = {}
  local RU = ref("ruins")
  local s = scope.ruin
  rows[#rows + 1] = { type = "header", label = s and ("RECOVERED LOG · " .. tostring(s.name)) or "RECOVERED LOG" }
  if s and RU and RU.lore then
    local ok, L = pcall(RU.lore, s)
    if ok and type(L) == "table" then for _, l in ipairs(L) do rows[#rows + 1] = { type = "line", text = l } end end
    rows[#rows + 1] = { type = "line", text = string.format("%s · %s · %s days without a hand on it", tostring(RU.LABEL and RU.LABEL[s.kind] or s.kind), tostring(s.body or ""), tostring(s.age or "?")), level = 1 }
  else
    rows[#rows + 1] = { type = "line", text = "the record is unreadable", level = 1 }
  end
  local BL = ref("base_log")
  local E = BL and BL.entries(scope.sids, 20) or {}
  if #E > 0 then
    rows[#rows + 1] = { type = "header", label = "SINCE YOU CAME" }
    for _, e in ipairs(E) do rows[#rows + 1] = { type = "line", text = BL.lineOf(e), level = BL.levelOf(e.k) } end
  end
  return rows
end
local function page_ruin_data(scope, ctx)
  local rows = {}
  local RU = ref("ruins")
  local s = scope.ruin
  rows[#rows + 1] = { type = "header", label = "DATA" }
  if s and RU and RU.peekState and RU.pullCore then
    local id = s.id
    local function taken() local e = RU.peekState(id); return e and e.core end
    rows[#rows + 1] = { type = "info", label = "Data Core", value = function() return taken() and "taken: the slot is empty" or "in its slot · 6 kg" end }
    rows[#rows + 1] = { id = "ru_pull", type = "action", label = "Pull the Data Core", hint = "6 kg",
      enabled = function() return not taken() end, why = "its core was taken",
      act = function()
        local pack = (ctx and ctx.actor and ctx.actor.pack) or "astro"
        local ok, why = RU.pullCore(id, pack)
        if ok then blog(scope.sid, "lore", "the Data Core was pulled from " .. tostring(s.name)) end
        return ok, ok and "Data Core in the pack: read it at the Research Lab" or why
      end }
  end
  for _, fn in ipairs(lootRows) do
    local ok, more = pcall(fn, scope, ctx)
    if ok and type(more) == "table" then for _, e in ipairs(more) do rows[#rows + 1] = e end end
  end
  return rows
end

-- ── S4: THE REACTOR'S DESK ──────────────────────────────────────────────────
-- A trend painted into one picture per plant, sampled and painted at 2 Hz
-- while the page is up: power (phosphor), primary temperature (amber),
-- primary flow (cyan) over the last minute, the 24 h power under it.
TREND_N = 120
TREND_DT = 0.5
local TR = {}             -- plant key → { s = { { P, Tp, mp } … }, t, img, tex }
local TW, TH = 560, 150
local GREEN, AMBER, CYAN, DIM, RED = { 0.55, 1.0, 0.62 }, { 1.0, 0.78, 0.28 }, { 0.55, 0.86, 0.95 }, { 0.22, 0.50, 0.28 }, { 1.0, 0.36, 0.28 }
local F_MONO = "fonts/SolarMono.ttf"
local function trend_paint(e, X)
  if not (image and image.new) then return nil end
  local img = X.img
  if not img then
    local ok, im = pcall(image.new, TW, TH, 0.008, 0.03, 0.015, 1)
    if not ok or not im then return nil end
    img, X.img = im, im
  end
  pcall(img.fill, img, 0, 0, TW, TH, 0.008, 0.03, 0.015, 1)
  local gx, gy, gw, gh = 6, 18, TW - 12, 92
  for k = 0, 4 do pcall(img.fill, img, gx, gy + math.floor(gh * k / 4), gw, 1, DIM[1] * 0.6, DIM[2] * 0.6, DIM[3] * 0.6, 1) end
  for k = 0, 6 do pcall(img.fill, img, gx + math.floor(gw * k / 6), gy, 1, gh, DIM[1] * 0.5, DIM[2] * 0.5, DIM[3] * 0.5, 1) end
  local M = e.M
  local tsat = M and M.tsat or 618
  local mpd = math.max(1, M and M.mp_design or 10)
  local S = X.s
  local n = #S
  local last = S[n] or {}
  pcall(img.text, img, gx, 1, string.format("POWER %5.1f %%", (last[1] or 0) * 100), 15, GREEN[1], GREEN[2], GREEN[3], 1, "left", F_MONO)
  pcall(img.text, img, gx + 180, 1, string.format("PRIMARY %4.0f K", last[2] or 0), 15, AMBER[1], AMBER[2], AMBER[3], 1, "left", F_MONO)
  pcall(img.text, img, gx + 370, 1, string.format("FLOW %5.1f kg/s", last[3] or 0), 15, CYAN[1], CYAN[2], CYAN[3], 1, "left", F_MONO)
  -- the boiling line on the temperature scale (300 K .. tsat + 40)
  local tlo, thi = 300, tsat + 40
  local function ty(T) return gy + gh - math.floor(math.max(0, math.min(1, ((T or tlo) - tlo) / (thi - tlo))) * gh) end
  pcall(img.fill, img, gx, ty(tsat), gw, 1, RED[1] * 0.7, RED[2] * 0.7, RED[3] * 0.7, 1)
  pcall(img.text, img, gx + gw - 4, ty(tsat) - 13, "BOILS", 11, RED[1], RED[2], RED[3], 0.9, "right", F_MONO)
  if n >= 2 then
    local function xof(i) return gx + math.floor((i - 1 + (TREND_N - n)) / (TREND_N - 1) * gw) end
    for i = 2, n do
      local a, b = S[i - 1], S[i]
      local x0, x1 = xof(i - 1), xof(i)
      local py0 = gy + gh - math.floor(math.min(1.2, a[1]) / 1.2 * gh)
      local py1 = gy + gh - math.floor(math.min(1.2, b[1]) / 1.2 * gh)
      local fy0 = gy + gh - math.floor(math.min(1.5, a[3] / mpd) / 1.5 * gh)
      local fy1 = gy + gh - math.floor(math.min(1.5, b[3] / mpd) / 1.5 * gh)
      pcall(img.line, img, x0, fy0, x1, fy1, 2, CYAN[1], CYAN[2], CYAN[3], 0.85)
      pcall(img.line, img, x0, ty(a[2]), x1, ty(b[2]), 2, AMBER[1], AMBER[2], AMBER[3], 1)
      pcall(img.line, img, x0, py0, x1, py1, 3, GREEN[1], GREEN[2], GREEN[3], 1)
    end
  end
  pcall(img.text, img, gx, gy + gh + 2, "−60 s", 11, DIM[1] * 2, DIM[2] * 1.6, DIM[3] * 2, 1, "left", F_MONO)
  pcall(img.text, img, gx + gw, gy + gh + 2, "now", 11, DIM[1] * 2, DIM[2] * 1.6, DIM[3] * 2, 1, "right", F_MONO)
  -- the 24 h strip: power, from the plant's own history (a sample every 5 game min)
  local sy, sh = gy + gh + 16, TH - (gy + gh + 16) - 3
  pcall(img.fill, img, gx, sy, gw, sh, 0.02, 0.06, 0.03, 1)
  pcall(img.text, img, gx + 4, sy + 1, "24 h", 11, GREEN[1], GREEN[2], GREEN[3], 0.8, "left", F_MONO)
  local h = e.hist or {}
  local HN = 288
  for i, s in ipairs(h) do
    local x = gx + 34 + math.floor((i - 1 + (HN - #h)) / math.max(1, HN - 1) * (gw - 36))
    local v = math.min(1.2, s[2] or 0) / 1.2
    local hh = math.max(1, math.floor(v * (sh - 2)))
    pcall(img.fill, img, x, sy + sh - 1 - hh, 2, hh, GREEN[1] * 0.8, GREEN[2] * 0.8, GREEN[3] * 0.8, 1)
  end
  local ok, tex = pcall(img.texture, img)
  if ok and tex then X.tex = tex end
  return X.tex
end
PROF = { paint_ms = 0, paints = 0 }
-- Sample plant e now (at most every TREND_DT s) and paint; → texture name
function trendOf(e)
  if not (e and e.key) then return nil end
  local X = TR[e.key]
  if not X then X = { s = {}, t = -10 }; TR[e.key] = X end
  local t = now()
  if t - X.t >= TREND_DT then
    X.t = t
    local o = e.o or {}
    X.s[#X.s + 1] = { o.P or 0, o.Tp or 0, o.mpe or 0 }
    while #X.s > TREND_N do table.remove(X.s, 1) end
    local w0 = app and app.wallClock and app.wallClock()
    trend_paint(e, X)
    if w0 then PROF.paint_ms = PROF.paint_ms + (app.wallClock() - w0) * 1000; PROF.paints = PROF.paints + 1 end
  end
  return X.tex
end
trendStore = TR

local function page_reactor(scope, ctx)
  local RP, R = ref("reactor_plant"), ref("reactor")
  if not (RP and R) then return { { type = "line", text = "no reactor system", level = 2 } } end
  local e = RP.plantOfPart(scope.sid, scope.uid)
  if not (e and e.M) then return { { type = "line", text = "NO PLANT: no Reactor Vessel Base in this structure", level = 1 } } end
  local key = e.key
  local rows = {}
  local function o() return e.o or {} end
  local hard = {}             -- the desk is hardwired to its plant: never dark
  -- ── column 1: the readings ──
  rows[#rows + 1] = { type = "header", label = "CORE", col = 1 }
  rows[#rows + 1] = { type = "info", col = 1, label = "Power", value = function()
    return string.format("%5.1f %%  ·  %s th", (o().P or 0) * 100, kw((o().Qcore or 0) / 1000)) end }
  rows[#rows + 1] = { type = "info", col = 1, label = "Period", value = function()
    local per = (o().P or 0) > 1e-8 and R.period(e.M, e.S, e.S.y) or nil
    local st = (o().k or 0) > 1.0005 and "SUPERCRITICAL" or ((o().k or 0) > 0.9995 and "CRITICAL" or "subcritical")
    return string.format("%s  ·  %s", (per and math.abs(per) < 1e5) and string.format("%+.0f s", per) or "∞", st) end,
    warn = function() local per = (o().P or 0) > 1e-8 and R.period(e.M, e.S, e.S.y) or nil; return (per and per > 0 and per < 30) and 2 or nil end }
  rows[#rows + 1] = { type = "info", col = 1, label = "Rods", value = function()
    local m = e.S.melt and "MELTED" or (e.S.scram and "TRIPPED" or (e.S.mode == "auto" and string.format("AUTO → %d %%", math.floor((e.S.set or 0) * 100 + 0.5)) or "MANUAL"))
    return string.format("%d %% in  ·  %s", math.floor((o().x or 0) * 100 + 0.5), m) end,
    warn = function() return e.S.scram and 1 or nil end }
  rows[#rows + 1] = { type = "header", label = "COOLANT", col = 1 }
  rows[#rows + 1] = { type = "info", col = 1, label = "Primary flow", value = function()
    return string.format("%.1f of %.1f kg/s%s", o().mpe or 0, e.M.mp_design or 0, (o().mnc or 0) > 0.5 * (o().mpe or 0) and " (natural)" or "") end,
    warn = function() return (e.M.mp_design or 0) > 0 and (o().mpe or 0) < 0.8 * e.M.mp_design and (o().P or 0) > 0.002 end }
  rows[#rows + 1] = { type = "info", col = 1, label = "Primary temp", value = function()
    return string.format("%.0f K  ·  %.0f K below boiling", o().Tp or 0, (e.M.tsat or 0) - (o().Tp or 0)) end,
    warn = function() local sc = (e.M.tsat or 0) - (o().Tp or 0); return sc < 10 and 2 or (sc < 25 and 1 or nil) end }
  rows[#rows + 1] = { type = "info", col = 1, label = "Fuel / steam", value = function()
    return string.format("%.0f K  ·  %.0f K, %.1f kg/s", o().Tf or 0, o().Ts or 0, o().ms or 0) end,
    warn = function() return (o().Tf or 0) > 1150 and 2 or nil end }
  rows[#rows + 1] = { type = "info", col = 1, label = "Pressuriser", value = function()
    local s
    if not e.M.press then s = "NONE: the primary boils at 373 K"
    else s = string.format("heaters %s · boils %.0f K", e.M.tsat > 600 and "on" or "OFF", e.M.tsat) end
    local inv = o().inv
    if inv then s = s .. string.format(" · water %.0f %%", inv * 100) end
    if (o().brk or 0) > 0.05 then s = s .. string.format(" · LOSING %.1f kg/s", o().brk) elseif (o().mk or 0) > 1e-3 then s = s .. string.format(" · makeup +%.2f", o().mk) end
    return s end,
    warn = function() return (not e.M.press or (o().inv or 1) < 0.6 or (o().brk or 0) > 0.05) and 2 or nil end }
  rows[#rows + 1] = { type = "header", label = "PROTECTION", col = 1 }
  rows[#rows + 1] = { type = "info", col = 1, label = "Status", value = function()
    if e.S.prot == false then return "BYPASSED · NOTHING WILL STOP A MELTDOWN" end
    if e.S.scram then return "TRIPPED · " .. tostring(R.EVENT_TEXT and R.EVENT_TEXT[e.S.cause or ""] or e.S.cause or "SCRAM") end
    return "ARMED · trips on power, fuel, subcooling, flow" end,
    warn = function() return e.S.prot == false and 2 or (e.S.scram and 1 or nil) end }
  rows[#rows + 1] = { type = "line", col = 1, text = function() return "LIMITED BY " .. tostring(R.limitedBy(e.M, e.S, o())) end, level = 1 }
  rows[#rows + 1] = { type = "image", col = 1, texture = function() return trendOf(e) end, w = 420, h = math.floor(420 * TH / TW) }
  -- ── column 2: the controls ──
  rows[#rows + 1] = { type = "header", label = "RODS", col = 2 }
  if e.S.scram then
    rows[#rows + 1] = { id = "rx_reset", type = "action", col = 2, keep = true, label = "Reset the trip",
      enabled = function() return R.resetWhyNot(e.M, e.S, o()) == nil end, why = function() return R.resetWhyNot(e.M, e.S, o()) end,
      act = function() return RP.resetTrip(key, "hand") end }
  else
    rows[#rows + 1] = { id = "rx_scram", type = "action", col = 2, keep = true, danger = true, label = "SCRAM", hint = "every rod in, 2 s",
      act = function() local ok = RP.scram(key, "hand"); return ok ~= false, nil end }
  end
  if e.S.mode ~= "auto" or e.S.scram then
    rows[#rows + 1] = { id = "rx_start", type = "action", col = 2, keep = true, label = "Start up (automatic, 50 %)",
      enabled = function() return R.startWhyNot(e.M, e.S, o()) == nil end, why = function() return R.startWhyNot(e.M, e.S, o()) end,
      act = function() return RP.startUp(key, 0.5, "hand") end }
  end
  rows[#rows + 1] = { id = "rx_set", type = "slider", col = 2, keep = true, label = "Setpoint (automatic)",
    get = function() return e.S.set or 0.5 end, set = function(v) RP.setPoint(key, v, "hand") end,
    min = 0.02, max = 1.1, step = 0.05, fmt = function(v) return string.format("%d %%", math.floor(v * 100 + 0.5)) end,
    enabled = function() return not e.S.scram end, why = "tripped: reset the trip first" }
  rows[#rows + 1] = { id = "rx_out", type = "action", col = 2, keep = true, label = "Rods out 2 % (manual)",
    enabled = function() return not e.S.scram end, why = "tripped: reset the trip first", act = function() return RP.manualRods(key, -0.02) end }
  rows[#rows + 1] = { id = "rx_in", type = "action", col = 2, keep = true, label = "Rods in 5 % (manual)",
    enabled = function() return not e.S.scram end, why = "tripped: the rods are all in", act = function() return RP.manualRods(key, 0.05) end }
  -- the pumps of both loops
  rows[#rows + 1] = { type = "header", label = "PUMPS", col = 2 }
  local np = 0
  local ST = ref("structures")
  for _, nm in ipairs({ "pri", "sec" }) do
    for _, pu in ipairs(e.pl[nm] and e.pl[nm].pumps or {}) do
      local p = ST and ST.getPart(e.sid, pu.uid)
      local d = p and defs(p.id) or {}
      rows[#rows + 1] = rx_pump_toggle(scope, e.sid, pu.uid, d, 2, true)
      np = np + 1
    end
  end
  if np == 0 then rows[#rows + 1] = { type = "line", col = 2, text = "no coolant pump plumbed to a loop", level = 1 } end
  -- the makeup: the fluid pumps and valves that feed the primary
  local FN = ref("fluid_net")
  if FN and FN.netOf then
    local mk = pieces(scope, "switch", 40)
    local shown = 0
    for _, q in ipairs(mk) do
      local E = FN.netOf(q.sid, q.uid)
      local prim = false
      for _, nd in ipairs(E and E.net.nodes or {}) do if nd.tk == "primary" then prim = true end end
      if prim then
        if shown == 0 then rows[#rows + 1] = { type = "header", label = "MAKEUP", col = 2 } end
        shown = shown + 1
        rows[#rows + 1] = fl_toggle(scope, q.sid, q.uid, q.d, 2)
      end
    end
  end
  rows[#rows + 1] = { type = "header", label = "PROTECTION AND PLANT", col = 2 }
  rows[#rows + 1] = { id = "rx_prot", type = "toggle", col = 2, keep = true, label = "Protection (automatic trips)",
    on = function() return e.S.prot ~= false end, onText = "[ARMED]", offText = "[BYPASS]",
    warn = function() return e.S.prot == false end,
    act = function(want) RP.setProtection(key, want, "hand"); return true, RP.protectionWarn and RP.protectionWarn(key, want) or nil end }
  rows[#rows + 1] = { id = "rx_cool", type = "toggle", col = 2, keep = true, label = "Cool down (steam dump open)",
    on = function() return e.S.cooldown == true end, act = function(want) RP.setCooldown(key, want, "hand"); return true end }
  if e.M.turb then
    rows[#rows + 1] = { id = "rx_turb", type = "toggle", col = 2, keep = true, label = "Turbine online",
      on = function() return e.turbOn ~= false end,
      hint = function() return string.format("%s(e)", kw((o().Pe or 0) / 1000)) end,
      act = function(want) RP.setTurbine(key, want, "hand"); return true end }
  end
  return rows, string.format("REACTOR %s", tostring(e.uid))
end

local function page_alarms(scope)
  local rows = {}
  local RP, R = ref("reactor_plant"), ref("reactor")
  local e = RP and RP.plantOfPart and RP.plantOfPart(scope.sid, scope.uid)
  rows[#rows + 1] = { type = "header", label = "ANNUNCIATOR", col = 1 }
  if e and e.M and R then
    local A = R.alarms(e.M, e.S, e.o or {})
    if #A == 0 then rows[#rows + 1] = { type = "line", text = "NO ALARMS", col = 1 } end
    for _, a in ipairs(A) do rows[#rows + 1] = { type = "line", text = a[1], level = a[2], col = 1 } end
    rows[#rows + 1] = { type = "header", label = "PLANT EVENTS", col = 1 }
    local n = 0
    for i = #(RP.lastEvents or {}), 1, -1 do
      local ev = RP.lastEvents[i]
      if ev.key == e.key then
        n = n + 1
        rows[#rows + 1] = { type = "line", col = 1, text = string.format("%s  %s", ref("base_log") and ref("base_log").stamp(ev.t) or "", tostring(ev.text)), level = ev.kind == "trip" and 2 or 0 }
        if n >= 8 then break end
      end
    end
    if n == 0 then rows[#rows + 1] = { type = "line", text = "none this session", col = 1 } end
  else
    rows[#rows + 1] = { type = "line", text = "no plant", level = 1, col = 1 }
  end
  local RA = ref("room_air")
  rows[#rows + 1] = { type = "header", label = "AIR ALARMS", col = 2 }
  local na = 0
  if RA and RA.alarms then
    for _, al in pairs(RA.alarms()) do
      if T().linked(scope, al.sid) then
        na = na + 1
        rows[#rows + 1] = { type = "line", col = 2, text = string.format("DEPRESSURISATION Room %s: %s", tostring(al.rid), tostring(al.cause or "a leak")), level = 2 }
      end
    end
  end
  if na == 0 then rows[#rows + 1] = { type = "line", text = "every sealed room holds", col = 2 } end
  return rows
end

-- ── registration ────────────────────────────────────────────────────────────
local registered = false
local function register_all()
  local t = T()
  if not (t and t.registerPage) then return false end
  reg("REACTOR", page_reactor, { order = 5, title = "REACTOR", scopes = { reactor = true } })
  reg("ALARMS", page_alarms, { order = 6, title = "ALARMS", scopes = { reactor = true } })
  reg("RUINLOG", page_ruin_log, { order = 7, title = "LOG", scopes = { ruin = true } })
  reg("DATA", page_ruin_data, { order = 8, title = "DATA", scopes = { ruin = true } })
  reg("STATUS", page_status, { order = 10, title = "STATUS", scopes = { desk = true, reactor = true, plc = true, fire = true, ruin = true, screen = true } })
  reg("POWER", page_power, { order = 20, title = "POWER", scopes = BASE })
  reg("FLUIDS", page_fluids, { order = 30, title = "FLUIDS", scopes = { desk = true, reactor = true } })
  reg("DOORS", page_doors, { order = 40, title = "DOORS", scopes = { desk = true, reactor = true } })
  reg("AIR", page_air, { order = 50, title = "AIR", scopes = { desk = true, reactor = true } })
  reg("LOGIC", page_logic, { order = 60, title = "LOGIC", scopes = { desk = true, reactor = true, plc = true, fire = true }, orderFor = { plc = 1 } })
  reg("CREW", page_crew, { order = 70, title = "CREW", scopes = { desk = true, reactor = true } })
  reg("LOG", page_log, { order = 80, title = "LOG", scopes = { desk = true, reactor = true, plc = true, fire = true, screen = true } })
  return true
end
pageFns = { STATUS = page_status, POWER = page_power, FLUIDS = page_fluids, DOORS = page_doors, AIR = page_air, LOGIC = page_logic,
  CREW = page_crew, LOG = page_log, REACTOR = page_reactor, ALARMS = page_alarms, RUINLOG = page_ruin_log, DATA = page_ruin_data }

local reg_t = -10
function start(node)
  if findScripts then
    local all = findScripts("terminal_pages")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  registered, CYC, TR = false, {}, {}
  trendStore = TR
end

function update(node, dt)
  if not registered and now() - reg_t >= 0.5 then reg_t = now(); registered = register_all() end
  -- an airlock cycle asked from a console: asked again each frame (the chamber
  -- forgets a request 0.3 s old) until its door is open or a minute passes
  if #CYC > 0 then
    local RA, KL = ref("room_air"), ref("kit_live")
    for i = #CYC, 1, -1 do
      local c = CYC[i]
      local o = KL and KL.doorOpen and KL.doorOpen(c.sid, c.uid)
      if now() > c.till or (o and o > 0.99) then table.remove(CYC, i)
      elseif RA and RA.requestDoor then RA.requestDoor(c.sid, c.uid) end
    end
  end
end
