-- REFINERY — the scene half of the refineries and the Fabricator (expansion
-- X6; work/expansion/PLAN.md §3.4, N4/N7; docs/base-building.md §24). The
-- rules are machines.lua (pure); the material through a machine is item_net's
-- (logistics.lua builds and steps the network; it calls `built`, `prepare`
-- and `after` here).
--
-- On the Build Kit node (scenes/system.ron) beside logistics and fluid_net.
--
--   DUTY      before each network step, each machine's power is its rated kW
--             × its duty (machines.duty): its switch (menu or RUN terminal),
--             the grid (base_grid.partServed: a short grid stops it), its
--             COOLING (a furnace or a kiln: the loop on its heat port, found
--             per structure by machines.coolLoops over the heat ports of the
--             machines, Radiator Panels, Jacket Radiators, coolant pipes and
--             Cooling Towers; a loop that holds a reactor's piece is the
--             reactor's), its WATER (a mixer's or an electrolyser's cell, a
--             consumer on fluid_net) and, an electrolyser, room in the Fuel
--             Tanks on its fuel nozzle.
--   THE ELECTROLYSER is not on the belts: fluid_net drains its water cell at
--             the rate it asks (waterDraw), tells it what it drew
--             (waterServed), and takes the propellant it made into the Fuel
--             Tanks on its nozzle (takeMade). The closed form is fluid_net's.
--   FABRICATORS run their queue (machines.fabAdvance) on the network's clock
--             after each step: a job takes its materials from the store when
--             it starts (and its fittings in money), runs recipes' time at
--             the Fabricator's duty, and its crate goes into the store, where
--             the Build Kit's reach finds it (field_builder.reachScan).
--   READOUTS  menus on every machine (State · LIMITED BY, works, outlet,
--             cooling, Running; a Fabricator's queue and its RECIPE panel,
--             fab_panel.lua), the LOGISTICS overlay's machine labels, the
--             logic terminals (RUN in, BUSY out).
--
-- SAVE: fabq.<sid>.<uid> = JSON { q = { { id, n, t, started, done } } }; a
-- machine's `off` in its part state. The inlets, outlets and stores are
-- containers (inventory). An old save has none of these: nothing changes.
--
-- Probes: state(sid, uid), queue(sid, uid, id, n), cancel(sid, uid, k),
-- setRun, isBusy, coolOf(sid, uid), PROF.

PROF = { prep_ms = 0, after_ms = 0, cool_ms = 0, fab_made = 0 }
ENV_EVERY = 30          -- s: a structure's air and temperature re-read

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function now() return time or 0 end
local function wall() return (app and app.wallClock) and app.wallClock() or nil end
local function defs(id) local pb = ref("parts_base"); return pb and pb.partInfo(id) or nil end
local function keyOf(sid, uid) return tostring(sid) .. "." .. tostring(uid) end
local function enc(t) if not (json and json.encode) then return nil end local ok, s = pcall(json.encode, t); return ok and s or nil end
local function dec(s)
  if type(s) == "table" then return s end
  if type(s) ~= "string" or not (json and json.decode) then return nil end
  local ok, t = pcall(json.decode, s)
  return ok and type(t) == "table" and t or nil
end
local function mat_label(m) local M = ref("materials"); return (M and M.label and M.label(m)) or tostring(m) end
local function kg_of(m) local M = ref("materials"); return (M and M.kg and M.kg(m)) or 1 end
local function fmt_kg(v) v = v or 0; if v >= 10000 then return string.format("%.1f t", v / 1000) end if v < 10 then return string.format("%.1f kg", v) end return string.format("%.0f kg", v) end
local function say(s, secs) if caption then pcall(caption, s, secs or 5) end if log then log("refinery: " .. s) end end

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

-- per machine (key "sid.uid"): { duty, why, cool, water, made (electrolyser
-- kg waiting for its tanks), served, need, lost, q (kg/s worked), fab = { q } }
local S = {}
state = S
local function st_of(key) local s = S[key]; if not s then s = {}; S[key] = s end return s end
function stateOf(sid, uid) return S[keyOf(sid, uid)] end

-- ── COOLING: the loops on the hot machines' heat ports, per structure ───────
local function rot(yaw, x, z) local c, s = math.cos(yaw or 0), math.sin(yaw or 0); return x * c + z * s, -x * s + z * c end
local REACTOR_BITS = { "nuclear", "hx", "turbine", "press", "pump" }
local function env_of(rec)
  local env = { air = false, tamb = 288 }
  local RA = ref("room_air")
  local s = RA and RA.state and RA.state(rec.id)
  if s and s.out and s.out.p then env.air = (s.out.p or 0) > 0.05
  else
    local M = ref("materials")
    local tr = M and M.bodyTraits and M.bodyTraits(rec.b)
    if tr then env.air = not tr.airless end
  end
  local M = ref("materials")
  local tr = M and M.bodyTraits and M.bodyTraits(rec.b)
  if tr and tr.temp then env.tamb = 200 + 150 * tr.temp end
  return env
end
local function cool_struct(rec)
  local MC = ref("machines")
  if not MC then return {} end
  local env = env_of(rec)
  local pieces = {}
  for _, p in ipairs(rec.bp or {}) do
    local d = defs(p.id)
    if d and d.ports and math.abs(p.pitch or 0) < 1e-3 then
      local hot = d.it and d.it.kind == "machine" and MC.MACH[d.it.m] and (MC.MACH[d.it.m].heat or 0) > 0
      local reactor = false
      for _, k in ipairs(REACTOR_BITS) do if d[k] then reactor = true end end
      if hot or d.reject or d.pipe or reactor then
        local ports = {}
        for _, pt in ipairs(d.ports) do
          -- (the coolant side only: no bore means DN100, a belt's or a fluid's port isn't one)
          if not pt.fluid and not pt.bore and (not hot or pt.heat) then
            local dx, dz = rot(p.yaw, pt.x, pt.z)
            local nx, nz = rot(p.yaw, pt.nx or 0, pt.nz or 0)
            ports[#ports + 1] = { x = (p.x or 0) + dx, y = (p.y or 0) + (pt.y or 0.6), z = (p.z or 0) + dz, nx = nx, nz = nz }
          end
        end
        local sink = d.reject and MC.rejectKW(d.reject, env) or nil
        pieces[#pieces + 1] = { key = keyOf(rec.id, p.uid), ports = ports, heat = hot and MC.MACH[d.it.m].heat or nil, sink = sink, reactor = reactor }
      end
    end
  end
  return MC.coolLoops(pieces), env
end

-- ── built: logistics found the world's pieces ───────────────────────────────
local function fab_load(P)
  local s = st_of(P.key)
  if s.fab then return s.fab end
  local t = dec(save and save.get and save.get("fabq." .. P.key)) or {}
  s.fab = { q = type(t.q) == "table" and t.q or {} }
  return s.fab
end
local function fab_save(P)
  local s = S[P.key]
  if not (s and s.fab and save and save.set) then return end
  save.set("fabq." .. P.key, (#s.fab.q > 0) and (enc({ q = s.fab.q }) or false) or false)
end
function built(w)
  local w0 = wall()
  w.cool, w.env = {}, {}
  local seen = {}
  for _, P in ipairs(w.machines or {}) do
    local sid = P.sid
    if not seen[sid] and P.rec then
      seen[sid] = true
      local L, env = cool_struct(P.rec)
      for k, v in pairs(L) do w.cool[k] = v end
      w.env[sid] = env
    end
    if P.fab then fab_load(P) end
  end
  w.coolT = now()
  if w0 then PROF.cool_ms = (wall() - w0) * 1000 end
end

-- ── prepare: each machine's power for the coming step ───────────────────────
local function ctx_of(w, P)
  local MC = ref("machines")
  local st = part_state(P.sid, P.uid) or {}
  local BG = ref("base_grid")
  local served = BG and BG.partServed and BG.partServed(P.sid, P.uid)
  local c = { on = not st.off, served = served }
  local M = MC.MACH[P.m or (P.fab and "fabricator") or ""]
  local s = st_of(P.key)
  if M and (M.heat or 0) > 0 then
    local L = w.cool and w.cool[P.key]
    c.cool = L and L.cool or MC.PASSIVE
  end
  if P.m == "mixer" or P.m == "electrolyser" then
    -- water: a cell with water in it runs; a dry one runs on what the pipe brings
    local cell = s.cell or 0
    local FN = ref("fluid_net")
    local E = FN and FN.netOf and FN.netOf(P.sid, P.uid)
    if not (E and E.net and E.net.sub == "water" and not E.net.mixed) then c.water = 0
    elseif cell > 0.05 then c.water = 1
    elseif (s.need or 0) > 1e-12 then c.water = math.max(0, math.min(1, (s.served or 0) / s.need))
    else c.water = (s.cell == nil) and 1 or 0 end
  end
  if P.m == "electrolyser" then
    local FN = ref("fluid_net")
    local room = FN and FN.srcRoom and FN.srcRoom(P.sid, P.uid) or 0
    c.room = room > 0.5
  end
  return c
end
function prepare(w, dt)
  local MC, N = ref("machines"), ref("item_net")
  if not (MC and N and w.net) then return end
  local w0 = wall()
  if now() - (w.coolT or -1e9) > ENV_EVERY then built(w) end
  for _, P in ipairs(w.machines or {}) do
    local kind = P.m or (P.fab and "fabricator")
    local d, why = MC.duty(kind, ctx_of(w, P))
    local s = st_of(P.key)
    s.duty, s.why = d, why
    if P.kind == "machine" then
      local i = N.nodeOf(w.net, P.key)
      if i then w.net.nodes[i].kw = MC.MACH[P.m].kw * MC.SPEED * d end
    end
  end
  if w0 then PROF.prep_ms = (wall() - w0) * 1000 end
end

-- ── after: what was worked; the Fabricators' queues ─────────────────────────
local function fab_env(w, P)
  local inv, FB, co = ref("inventory"), ref("field_builder"), ref("company")
  return {
    recipe = function(id)
      local r = FB and FB.recipeOf and FB.recipeOf(id) or nil
      if r and r.shipOnly then return nil end
      return r
    end,
    have = function(m) return inv and inv.count(P.cid, m) or 0 end,
    take = function(mats) for _, e in ipairs(mats) do inv.remove(P.cid, e.mat, math.ceil(e.kg - 1e-9)) end return true end,
    pay = function(f)
      if (f or 0) <= 0 then return true end
      if save and save.get and save.get("game.mode") == "sandbox" then return true end
      if not (co and co.spend) then return true end
      return co.spend(f, "Fabricator fittings") == true
    end,
    put = function(id)
      local R = ref("recipes")
      local item = R and R.partItemId(id) or ("part:" .. tostring(id))
      local n = inv and inv.addItem(P.cid, item, 1) or 0
      return (n or 0) > 0
    end,
  }
end
function after(w, rep, dt)
  local MC, N = ref("machines"), ref("item_net")
  if not (MC and N) then return end
  local w0 = wall()
  for _, P in ipairs(w.machines or {}) do
    local s = st_of(P.key)
    if P.kind == "machine" then
      local i = N.nodeOf(w.net, P.key)
      local q, mat = 0, nil
      if i and rep then q, mat = N.convFlow(rep, i) end
      s.q, s.qmat = q, mat
      if (q or 0) > 0 and (dt or 0) > 0 then local FT = ref("feats"); if FT and FT.addAmount then pcall(FT.addAmount, "machine_worked", q * dt) end end   -- (progression P2)
      if P.m == "mixer" then s.need = MC.waterFor("mixer", q) end
    elseif P.fab then
      local F = fab_load(P)
      if #F.q > 0 then
        local before = MC.queued(F)
        local why, made = MC.fabAdvance(F, dt, s.duty or 0, fab_env(w, P))
        s.fwhy = why
        if made > 0 then
          local FT = ref("feats"); if FT and FT.mark then pcall(FT.mark, "part_fabricated", { n = made }) end   -- (progression P2)
          PROF.fab_made = PROF.fab_made + made
          say(string.format("%s: a crate is ready in its store (%d left in the queue)", P.label, MC.queued(F)))
        end
        if MC.queued(F) ~= before or made > 0 then
          fab_save(P)
          if #F.q == 0 then local BG = ref("base_grid"); if BG and BG.markDirty then BG.markDirty() end end
        end
      else s.fwhy = nil end
    end
  end
  if w0 then PROF.after_ms = (wall() - w0) * 1000 end
end
function busy(w)
  for _, P in ipairs(w.machines or {}) do
    local s = S[P.key]
    -- (a Fabricator with a job it can run: powered, and not waiting on its store)
    if P.fab and s and s.fab and #s.fab.q > 0 and (s.duty or 0) > 0 and s.fwhy == nil then return true end
  end
  return false
end

-- ── the fluid couplings (fluid_net calls these) ─────────────────────────────
local function machine_of(sid, uid)
  local ST = ref("structures")
  local p = ST and ST.getPart and ST.getPart(sid, uid)
  local d = p and defs(p.id)
  return d and d.it, d
end
-- kg/s a machine draws from its water cell now
function waterDraw(sid, uid)
  local it = machine_of(sid, uid)
  if not it then return 0 end
  local s = st_of(keyOf(sid, uid))
  if it.m == "electrolyser" then
    local MC = ref("machines")
    local qw = MC and MC.electrolysis() or 0
    local st = part_state(sid, uid) or {}
    local BG = ref("base_grid")
    if st.off or (BG and BG.partServed and BG.partServed(sid, uid) == false) then s.need = 0; return 0 end
    local FN = ref("fluid_net")
    if FN and FN.srcRoom and FN.srcRoom(sid, uid) <= 0.5 then s.need = 0; return 0 end
    s.need = qw
    return qw
  end
  return s.need or 0
end
-- what it drew over dt (kg), and its cell now
function waterServed(sid, uid, kg, dt, cell)
  local it = machine_of(sid, uid)
  if not it then return end
  local s = st_of(keyOf(sid, uid))
  s.cell = cell
  s.served = (dt and dt > 0) and (kg or 0) / dt or 0
  if it.m == "electrolyser" then
    local MC = ref("machines")
    local y = MC and MC.MACH.electrolyser.yield or 0.78
    s.made = (s.made or 0) + (kg or 0) * y
    s.madeTotal = (s.madeTotal or 0) + (kg or 0) * y
    s.q = s.served
  end
end
-- the propellant waiting for the tanks (taken)
function takeMade(sid, uid)
  local s = S[keyOf(sid, uid)]
  if not s or (s.made or 0) <= 0 then return 0 end
  local m = s.made
  s.made = 0
  return m
end
function noteLost(sid, uid, kg) local s = st_of(keyOf(sid, uid)); s.lost = (s.lost or 0) + (kg or 0) end

-- ── the grid: a machine draws its kW while switched on and in use ───────────
function gridAux(sid, uid)
  local it, d = machine_of(sid, uid)
  if not it then return 0 end
  local MC = ref("machines")
  local M = MC and MC.MACH[it.m or (it.kind == "fab" and "fabricator") or ""]
  if not M then return 0 end
  local st = part_state(sid, uid) or {}
  if st.off then return 0 end
  local s = S[keyOf(sid, uid)]
  if it.kind == "fab" then
    -- (a Fabricator draws while its queue holds a job)
    return (s and s.fab and #s.fab.q > 0) and M.kw or 0
  end
  return M.kw
end

-- ── controls ────────────────────────────────────────────────────────────────
local function touch(sid)
  local LX = ref("logistics")
  if LX and LX.stepNow then LX.stepNow() end
  local BG = ref("base_grid")
  if BG and BG.markDirty then BG.markDirty() end
end
function setRun(sid, uid, on) touch(sid); set_part_state(sid, uid, "off", (not on) or nil); return true end
function isRun(sid, uid) local st = part_state(sid, uid); return not (st and st.off) end
function isBusy(sid, uid)
  local s = S[keyOf(sid, uid)]
  if not s then return false end
  if s.fab then return #s.fab.q > 0 and (s.duty or 0) > 0 and s.fwhy == nil end
  return (s.q or 0) > 1e-9 and (s.duty or 0) > 0
end

local function world_and_piece(sid, uid)
  local LX, ST = ref("logistics"), ref("structures")
  local rec = ST and ST.get(sid)
  local w = rec and LX and LX.worldOf(rec.b)
  if not w then return nil end
  local key = keyOf(sid, uid)
  for _, P in ipairs(w.machines or {}) do if P.key == key then return w, P end end
  return w, nil
end
-- The Fabricator's queue: add n of part `id`. → ok, why
function queue(sid, uid, id, n)
  local MC = ref("machines")
  local w, P = world_and_piece(sid, uid)
  if not (P and P.fab and MC) then return false, "not a Fabricator" end
  local F = fab_load(P)
  local FB, rs = ref("field_builder"), ref("research")
  local r = FB and FB.recipeOf and FB.recipeOf(id)
  if not r then return false, "it has no recipe" end
  if r.shipOnly then return false, "made at home only: " .. tostring(r.shipOnly) end
  if r.perMetre then return false, "a cable is laid by the metre, not fabricated" end
  local d0 = FB.partInfo and FB.partInfo(id)
  local rid = d0 and (d0.vab or d0.tech) or id
  if rs and rs.isUnlocked and not rs.isUnlocked(rid) then return false, "not researched: " .. tostring(rs.lockLine and rs.lockLine(rid) or rid) end
  n = math.max(1, math.floor(n or 1))
  for _, j in ipairs(F.q) do
    if j.id == id and not j.started then j.n = (j.n or 1) + n; fab_save(P); touch(sid); return true end
  end
  if #F.q >= MC.FAB_QUEUE then return false, string.format("the queue is full (%d jobs)", MC.FAB_QUEUE) end
  F.q[#F.q + 1] = { id = id, n = n, t = 0 }
  fab_save(P)
  touch(sid)
  return true
end
-- Cancel job k (its materials go back to the store when it had started).
function cancel(sid, uid, k)
  local w, P = world_and_piece(sid, uid)
  if not (P and P.fab) then return false end
  local F = fab_load(P)
  local j = F.q[k]
  if not j then return false end
  if j.started and not j.done then
    local FB, inv = ref("field_builder"), ref("inventory")
    local r = FB and FB.recipeOf and FB.recipeOf(j.id)
    for _, e in ipairs((r and r.mats) or {}) do inv.add(P.cid, e.mat, math.ceil(e.kg - 1e-9)) end
  end
  table.remove(F.q, k)
  fab_save(P)
  touch(sid)
  return true
end
function fabOf(sid, uid)
  local w, P = world_and_piece(sid, uid)
  if not (P and P.fab) then return nil end
  return fab_load(P), P, S[P.key]
end
function coolOf(sid, uid)
  local w = world_and_piece(sid, uid)
  return w and w.cool and w.cool[keyOf(sid, uid)] or nil
end

-- A machine's numbers now (logistics.readout's `machine`).
function machineReadout(w, P)
  local MC, inv = ref("machines"), ref("inventory")
  local s = S[P.key] or {}
  local kind = P.m or (P.fab and "fabricator")
  local M = MC and MC.MACH[kind] or {}
  local o = { label = P.label, kind = kind, duty = s.duty or 0, why = s.why, kw = M.kw, heat = M.heat, q = s.q or 0, qmat = s.qmat,
              cool = w.cool and w.cool[P.key], cell = s.cell, made = s.madeTotal, lost = s.lost }
  if P.cid and inv then o.inlet = { kg = inv.mass(P.cid) or 0, cap = P.capIn or P.cap, items = inv.items(P.cid) or {}, cid = P.cid } end
  if P.ocid and inv then o.outlet = { kg = inv.mass(P.ocid) or 0, cap = P.capOut, items = inv.items(P.ocid) or {}, cid = P.ocid } end
  if P.fab then o.fab = s.fab; o.fwhy = s.fwhy; o.parts = inv and inv.itemList and inv.itemList(P.cid) or {} end
  -- the item-side reason (its feed, its outlet) after the duty's
  local N = ref("item_net")
  if not o.why and P.kind == "machine" and N and w.net then
    local i = N.nodeOf(w.net, P.key)
    if i then o.why = N.machineWhy(w.net, w.st, w.rep, i, function(j) local Pj = w.byKey[w.net.nodes[j].key]; return Pj and Pj.label or "a store" end) end
  end
  if not o.why and P.fab then o.why = s.fwhy end
  return o
end
function readout(sid, uid)
  local w, P = world_and_piece(sid, uid)
  if not P then return nil end
  return machineReadout(w, P)
end

-- ── the LOGISTICS overlay's machine labels (logistics.drawOverlay) ──────────
function overlayLabels(w, b, label, L)
  local KS = ref("kit_snap")
  local GREEN, AMBER, DIM = { 0.45, 0.95, 0.55 }, { 1.0, 0.75, 0.25 }, { 0.62, 0.66, 0.68 }
  for _, P in ipairs(w.machines or {}) do
    local fr = KS and KS.frameOf and KS.frameOf(P.rec)
    if fr then
      local o = machineReadout(w, P)
      local h = (P.def and P.def.h or 2.4) + 0.5
      local c, s = math.cos(P.part.yaw or 0), math.sin(P.part.yaw or 0)
      local lx, lz = P.part.x or 0, P.part.z or 0
      local x = fr.O.x + fr.R.x * lx + fr.U.x * ((P.part.y or 0) + h) + fr.F.x * lz
      local y = fr.O.y + fr.R.y * lx + fr.U.y * ((P.part.y or 0) + h) + fr.F.y * lz
      local z = fr.O.z + fr.R.z * lx + fr.U.z * ((P.part.y or 0) + h) + fr.F.z * lz
      local t1
      if P.fab then
        local F = o.fab or { q = {} }
        local j = F.q[1]
        t1 = string.format("%s · %s", P.label:upper(), j and string.format("%s ×%d", tostring(j.id), j.n or 1) or "idle")
      elseif P.kind == "electro" then
        t1 = string.format("%s · %d %% · %.1f kg/h propellant", P.label:upper(), math.floor((o.duty or 0) * 100 + 0.5), (o.q or 0) * 3600 * 0.78)
      else
        t1 = string.format("%s · %d %% · %.3f kg/s%s", P.label:upper(), math.floor((o.duty or 0) * 100 + 0.5), o.q or 0, o.qmat and (" " .. mat_label(o.qmat)) or "")
      end
      local t2 = o.why and ("LIMITED BY " .. o.why) or ((o.q or 0) > 0 and "running" or "idle")
      label(b.x + x, b.y + y, b.z + z, t1, t2, o.why and AMBER or ((o.q or 0) > 0 and GREEN or DIM))
    end
  end
end

-- ── the menus ───────────────────────────────────────────────────────────────
local function items_text(items)
  local parts = {}
  for _, itx in ipairs(items or {}) do parts[#parts + 1] = string.format("%s %s", mat_label(itx.mat), fmt_kg((itx.n or 0) * kg_of(itx.mat))) end
  return #parts > 0 and table.concat(parts, ", ") or "empty"
end
local function provider(t, ctx)
  if not (t and t.node) then return {} end
  local ST = ref("structures")
  if not (ST and ST.partOfNode) then return {} end
  local FB = ref("field_builder")
  local rec, part
  if FB and FB.pickTarget then rec, part = FB.pickTarget(t) else rec, part = ST.partOfNode(t.node) end
  if not part then return {} end
  local d = defs(part.id) or {}
  local it = d.it
  local sid, uid = rec.id, part.uid
  local G = "Refinery"
  local out = {}
  if d.reject and d.piece == "mcJacket" then
    out[#out + 1] = { id = "rf_jacket", type = "info", label = "Sheds", group = G, value = function()
      local MC = ref("machines")
      local env = env_of(rec)
      return string.format("%.1f kW at %d °C (%s)", MC.rejectKW(d.reject, env), MC.JACKET_T - 273, env.air and "in air" or "in vacuum")
    end }
    return out, d.label
  end
  if not (it and (it.kind == "machine" or it.kind == "fab" or it.kind == "electro")) then return {} end
  out[#out + 1] = { id = "rf_state", type = "info", label = "State", group = G, value = function()
    local o = readout(sid, uid)
    if not o then return "—" end
    if it.kind == "fab" then
      local F = o.fab or { q = {} }
      local j = F.q[1]
      if not j then return string.format("idle · %g kW while it works", o.kw or 0) end
      local FB2 = ref("field_builder")
      local r = FB2 and FB2.recipeOf and FB2.recipeOf(j.id)
      return string.format("%s ×%d · %s", tostring(j.id), j.n or 1, j.started and string.format("%.0f of %.0f s", j.t or 0, r and r.secs or 0) or "waiting")
    end
    if it.kind == "electro" then
      return string.format("%d %% · %.2f kg/h of propellant · %s of water in its cell", math.floor((o.duty or 0) * 100 + 0.5), (o.q or 0) * 3600 * 0.78, fmt_kg(o.cell or 0))
    end
    return string.format("%d %% · %.3f kg/s%s · %g kW", math.floor((o.duty or 0) * 100 + 0.5), o.q or 0, o.qmat and (" of " .. mat_label(o.qmat)) or "", (o.kw or 0) * (o.duty or 0))
  end }
  if it.kind == "machine" then
    out[#out + 1] = { id = "rf_in", type = "info", label = "Inlet", group = G, value = function()
      local o = readout(sid, uid); local x = o and o.inlet
      return x and string.format("%s of %s · %s", fmt_kg(x.kg), fmt_kg(x.cap), items_text(x.items)) or "—"
    end }
    out[#out + 1] = { id = "rf_out", type = "info", label = "Outlet", group = G, value = function()
      local o = readout(sid, uid); local x = o and o.outlet
      return x and string.format("%s of %s · %s", fmt_kg(x.kg), fmt_kg(x.cap), items_text(x.items)) or "—"
    end }
    local MC = ref("machines")
    if MC and MC.MACH[it.m] and (MC.MACH[it.m].heat or 0) > 0 then
      out[#out + 1] = { id = "rf_cool", type = "info", label = "Cooling", group = G, value = function()
        local L = coolOf(sid, uid)
        if not L then return string.format("nothing on its heat port: its shell sheds %d %%", math.floor(MC.PASSIVE * 100)) end
        if L.reactor then return "its heat port is on a reactor's loop: part them" end
        return string.format("%.1f kW of sinks (%d) for %.1f kW of heat (%d machine%s) → %d %%", L.C, L.sinks, L.H, L.n, L.n == 1 and "" or "s", math.floor(L.cool * 100 + 0.5))
      end }
    end
    out[#out + 1] = { id = "rf_take", type = "action", label = "Take its outlet into your pack", group = G, keep = true,
      act = function()
        local inv = ref("inventory")
        local o = readout(sid, uid)
        if not (inv and o and o.outlet) then return false, "nothing" end
        local moved = 0
        for _, itx in ipairs(o.outlet.items) do moved = moved + inv.transfer(o.outlet.cid, "astro", itx.mat, itx.n) end
        if moved <= 0 then return false, "nothing in it, or no room in your pack" end
        return true
      end }
  elseif it.kind == "fab" then
    out[#out + 1] = { id = "rf_recipe", type = "action", label = "RECIPE panel — make a part", group = G, hint = "E",
      act = function() local FP = ref("fab_panel"); if FP and FP.open then FP.open(sid, uid) end return true end }
    out[#out + 1] = { id = "rf_store", type = "info", label = "Store", group = G, value = function()
      local inv = ref("inventory")
      local cid = "fab:" .. keyOf(sid, uid)
      if not inv then return "—" end
      local parts = {}
      for _, itx in ipairs(inv.items(cid) or {}) do parts[#parts + 1] = string.format("%s %s", mat_label(itx.mat), fmt_kg((itx.n or 0) * kg_of(itx.mat))) end
      local nc = 0
      for _, g in ipairs(inv.itemList and inv.itemList(cid) or {}) do if type(g.id) == "string" and g.id:sub(1, 5) == "part:" then nc = nc + (g.n or 0) end end
      return string.format("%s · %s%s", fmt_kg(inv.mass(cid) or 0), #parts > 0 and table.concat(parts, ", ") or "no materials", nc > 0 and string.format(" · %d crated", nc) or "")
    end }
  elseif it.kind == "electro" then
    out[#out + 1] = { id = "rf_tank", type = "info", label = "Fuel nozzle", group = G, value = function()
      local FN = ref("fluid_net")
      local room = FN and FN.srcRoom and FN.srcRoom(sid, uid) or 0
      local o = readout(sid, uid) or {}
      return string.format("%s of room in its Fuel Tanks · %s made", fmt_kg(room), fmt_kg(o.made or 0))
    end }
  end
  out[#out + 1] = { id = "rf_run", type = "toggle", label = "Running", group = G, keep = true,
    on = function() return isRun(sid, uid) end, act = function(want) setRun(sid, uid, want) end }
  out[#out + 1] = { id = "rf_lim", type = "info", label = "Limited by", group = G, value = function()
    local o = readout(sid, uid); return (o and o.why) or "nothing: it runs as laid" end }
  return out, d.label
end
providerFn = provider
local reg_on = false

function start(node)
  if findScripts then
    local all = findScripts("refinery")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  S = {}
  state = S
end

-- (logistics.update calls this: refinery has no update of its own, so it
-- costs nothing a frame)
function tick()
  if not reg_on then
    local reg = ref("context_registry")
    if reg and reg.register then reg.register("prop", provider, { id = "refinery", order = 9 }); reg_on = true end
  end
end
