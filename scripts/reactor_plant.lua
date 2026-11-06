-- REACTOR PLANT — the scene half of reactors built from components (sandbox
-- plan S6; docs/heat-and-nuclear.md §8). The rules are reactor.lua's (pure).
--
-- On the Build Kit node (scenes/system.ron) beside base_grid and base_power.
--
--   PLANTS     found in the structures' records: a Reactor Vessel Base and
--              what its ports and lattice reach (reactor.layout), re-found
--              when the records change (debounced), never in a frame
--   THE CLOCK  every plant is stepped on the agency clock at 5 Hz (`every`)
--              and at once on a change (a pump stopped, the rods asked for);
--              a load catches it up the same way, a bounded number of solver
--              steps a tick (STEPS), the rest carried to the next
--   THE GRID   the turbine's output is a source on base_grid (`gridGen`), the
--              pumps, heaters and fans are its loads (`gridAux`); a pump on a
--              grid short and flat stops (base_grid.partServed). The grid is
--              rebuilt when what the plant publishes moves (3 % or 0.5 kW)
--   DOSE       the vessel is a base_shield source at its core's centre, as
--              strong as the heat the core makes (`radOf`), walls counted by
--              record (the step-3 rule); a damaged core's release adds to it
--   READOUTS   the Reactor Control Console's screen (1 Hz, crew within 25 m),
--              the menus on every piece (the controls, refuelling), the
--              NUCLEAR overlay (F3 with the kit open): the loops by
--              temperature with their flow, each component's heat, the plant's
--              card and the dose field round the core
--
-- SAVE: rx.list (plant keys), rx.<sid>:<uid> = the plant (its state y, the
-- controls, its events, its trend), rx.ch.<sid> = the structure's fuel
-- channels' rods (by uid). An old save has none: no plant, nothing stepped.
--
-- Probes: plants(), plant(key), keyOf(sid, uid), stepNow(), loadRods(sid,
-- uid, item, n), setPump(sid, uid, on), startUp(key, set), scram(key),
-- resetTrip(key), consoleText(sid, uid), overlay, drawn, PROF.

defaults = {
  --@range 0.05 1 --@units s
  every = 0.2,
}

STEPS = 300             -- solver steps a tick may take (a catch-up carries the rest)
SAVE_EVERY = 10         -- s (real) between writes of a running plant
REL_K = 30              -- lethal shares an hour at 5 m per unit of fuel damage released (vented)
REL_HALF = 8 * 86400    -- the release's half-life (I-131's)
HIST_DT = 300           -- game s between trend samples
HIST_N = 288            -- 24 h of them

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
local function say(s) if caption then pcall(caption, s) end if log then log("reactor: " .. s) end end
function keyOf(sid, uid) return tostring(sid) .. ":" .. tostring(uid) end

local PL = {}            -- key → plant entry
local CH = {}            -- sid → { [uid] = { rods = { … } } }
local CONS = {}          -- "sid:uid" → console entry { sid, uid, node, screen, img, tex, t }
local st_ver, dirty_t = nil, -10
local tick_t, save_t = -10, -10
local grid_pub_t = -10
PROF = { tick_ms = 0, find_ms = 0, steps = 0, plants = 0 }

-- ── save ────────────────────────────────────────────────────────────────────
local function copy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = copy(v) end
  return o
end
local function ch_of(sid)
  local c = CH[sid]
  if c then return c end
  c = {}
  local s = save and save.get and save.get("rx.ch." .. tostring(sid))
  if type(s) == "table" then
    for k, v in pairs(s) do
      local u = tonumber(k) or k
      if type(v) == "table" and type(v.rods) == "table" then c[u] = { rods = copy(v.rods) } end
    end
  end
  CH[sid] = c
  return c
end
local function write_ch(sid)
  if not (save and save.set) then return end
  local out = {}
  for uid, v in pairs(CH[sid] or {}) do out[tostring(uid)] = { rods = copy(v.rods) } end
  save.set("rx.ch." .. tostring(sid), out)
end
local function write_plant(e)
  if not (save and save.set) then return end
  local S = e.S
  save.set("rx." .. e.key, { y = copy(S.y), mode = S.mode, set = S.set, xt = S.xt, scram = S.scram, cause = S.cause, prot = S.prot,
    melt = S.melt, h = S.h, ev = copy(S.ev), bursts = S.bursts, cooldown = S.cooldown, t = e.t, rel = e.rel, relT = e.relT,
    pumps = copy(e.pumpsOn), press = e.pressOn, tower = e.towerOn, turbine = e.turbOn, hist = copy(e.hist), pe = e.pe })
end
local function write_index()
  if not (save and save.set) then return end
  local l = {}
  for k in pairs(PL) do l[#l + 1] = k end
  table.sort(l)
  save.set("rx.list", l)
end
local function read_plant(key)
  local s = save and save.get and save.get("rx." .. key)
  return type(s) == "table" and s or nil
end

-- ── the environment of a structure (its world's air and its temperature) ───
local function env_of(rec)
  local CL = ref("climate")
  local tamb, atm = 288, 1
  if CL and CL.worldOf then
    local ok, w = pcall(CL.worldOf, rec.b)
    if ok and w then
      atm = tonumber(w.atmo) or atm
      if CL.sampleRel then
        local ok2, s = pcall(CL.sampleRel, w, rec.x, rec.y, rec.z)
        if ok2 and type(s) == "table" and tonumber(s.t) then tamb = 210 + 120 * s.t end
      end
    end
  end
  return { tamb = tamb, atm = atm, sun = 0 }
end

-- ── the plants from the records ─────────────────────────────────────────────
local function RX() return ref("reactor") end
local function run_of(e)
  -- what runs: the pumps switched on and powered, the heaters, the fans, the turbine
  local BG = ref("base_grid")
  local run = { pumps = {}, press = e.pressOn ~= false, tower = e.towerOn ~= false, turbine = e.turbOn ~= false, trim = e.trim or 0 }
  for _, L in ipairs({ e.pl.pri, e.pl.sec }) do
    for _, pu in ipairs(L.pumps or {}) do
      local on = e.pumpsOn[pu.uid] ~= false
      local served = BG and BG.partServed and BG.partServed(e.sid, pu.uid)
      run.pumps[pu.uid] = on and served ~= false
    end
  end
  if e.pl.pri.press then
    local s = BG and BG.partServed and BG.partServed(e.sid, e.pl.pri.press.uid)
    run.press = run.press and s ~= false
  end
  return run
end
local function run_sig(run)
  local t = {}
  for uid, on in pairs(run.pumps) do t[#t + 1] = tostring(uid) .. (on and "+" or "-") end
  table.sort(t)
  return table.concat(t, ",") .. (run.press and "P" or "p") .. (run.tower and "T" or "t") .. (run.turbine and "G" or "g")
end
local function rebuild_model(e, why)
  local R = RX()
  local ST = ref("structures")
  local rec = ST and ST.get(e.sid)
  if not (R and rec) then return end
  local run = run_of(e)
  e.runSig = run_sig(run)
  e.M = R.model(e.pl, ch_of(e.sid), e.env, run)
  e.o = R.derive(e.M, e.S, e.S.y, nil, {})
end

local function find_plants()
  local R, ST = RX(), ref("structures")
  if not (R and ST and ST.list) then return end
  local w0 = wall()
  local seen = {}
  local tnow = agency_now()
  for _, rec in ipairs(ST.list()) do
    local has = false
    for _, p in ipairs(rec.bp or {}) do
      local d = defs(p.id)
      if d and d.nuclear and d.nuclear.role == "vessel" then has = true break end
    end
    if has then
      local L = R.layout(rec, defs)
      for _, pl in ipairs(L.plants) do
        local key = keyOf(rec.id, pl.uid)
        seen[key] = true
        local e = PL[key]
        if not e then
          local env = env_of(rec)
          local s = read_plant(key)
          local S = R.newState(env.tamb)
          e = { key = key, sid = rec.id, uid = pl.uid, env = env, pumpsOn = {}, hist = {}, t = tnow, rel = 0, relT = tnow, pe = 0,
                aux = {}, consoles = L.consoles, b = rec.b }
          if s then
            if type(s.y) == "table" and #s.y == R.NY then S.y = copy(s.y) end
            S.mode, S.set, S.xt, S.scram, S.cause = s.mode or S.mode, s.set or S.set, s.xt or S.xt, s.scram == true, s.cause
            S.prot = s.prot ~= false
            S.melt, S.h, S.ev, S.bursts, S.cooldown = s.melt == true, s.h or S.h, copy(s.ev or {}), s.bursts or 0, s.cooldown == true
            e.t, e.rel, e.relT = tonumber(s.t) or tnow, s.rel or 0, s.relT or tnow
            for k, v in pairs(s.pumps or {}) do e.pumpsOn[tonumber(k) or k] = v end
            e.pressOn, e.towerOn, e.turbOn = s.press, s.tower, s.turbine
            e.hist = copy(s.hist or {})
            e.pe = s.pe or 0
          end
          e.S = S
          PL[key] = e
        end
        e.pl = pl
        e.consoles = L.consoles
        e.b = rec.b
        -- (L3 Engineer who founded it: the turbine's trim)
        local cl = ref("crew")
        e.trim = (cl and cl.perk and rec.by) and (tonumber(cl.perk(rec.by, "plant_trim")) or 0) or 0
        rebuild_model(e, "layout")
      end
    end
  end
  for key, e in pairs(PL) do
    if not seen[key] then PL[key] = nil end
  end
  write_index()
  st_ver = ST.version
  local BG = ref("base_grid")
  if BG and BG.markDirty then BG.markDirty() end
  if w0 then PROF.find_ms = (wall() - w0) * 1000 end
end

-- ── the grid's view ─────────────────────────────────────────────────────────
local function plant_of_turbine(sid, uid)
  for _, e in pairs(PL) do if e.sid == sid and e.M and e.M.turb_uid == uid then return e end end
  return nil
end
-- kW a turbine-generator gives the grid now
function gridGen(sid, uid)
  local e = plant_of_turbine(sid, uid)
  return e and e.pe or 0
end
-- kW a plant's pump, pressuriser heaters or tower fan draws now
function gridAux(sid, uid)
  for _, e in pairs(PL) do
    if e.sid == sid and e.aux[uid] then return e.aux[uid] end
  end
  -- (a pump, heater or fan of no plant yet draws nothing)
  return 0
end
local function publish(e)
  local R = RX()
  local o = e.o or {}
  e.pe = math.max(0, (o.Pe or 0) / 1000)
  local aux = {}
  local M = e.M
  for _, L in ipairs({ e.pl.pri, e.pl.sec }) do
    for _, pu in ipairs(L.pumps or {}) do
      if e.pumpsOn[pu.uid] ~= false then aux[pu.uid] = (pu.def.pump.kw or 1.5) * (1 + 0.01 * (L.pipes or 0)) end
    end
  end
  if e.pl.pri.press and e.pressOn ~= false then aux[e.pl.pri.press.uid] = e.pl.pri.press.def.press.kw or 1.5 end
  for _, r in ipairs(e.pl.sec.rejects or {}) do
    if r.def.reject.kind == "tower" and e.towerOn ~= false then aux[r.uid] = r.def.reject.kw or 4 end
  end
  e.aux = aux
  local sig = 0
  for _, v in pairs(aux) do sig = sig + v end
  local moved = math.abs(e.pe - (e.pe_pub or 0)) > math.max(0.5, 0.03 * (e.pe_pub or 0)) or math.abs(sig - (e.aux_pub or 0)) > 0.05
  if moved and now() - grid_pub_t > 3 then
    e.pe_pub, e.aux_pub = e.pe, sig
    grid_pub_t = now()
    local BG = ref("base_grid")
    if BG and BG.markDirty then BG.markDirty() end
  end
end

-- ── dose (base_shield asks) ─────────────────────────────────────────────────
-- → rad (lethal shares an hour at 5 m at full share), share
function radOf(sid, uid)
  local e = PL[keyOf(sid, uid)]
  if not (e and e.M and e.o) then return 0, 0 end
  local R = RX()
  local rad, share = R.radOf(e.M, e.o)
  local tot = rad * share + (e.rel or 0)
  if tot <= 0 then return 0, 0 end
  return tot, 1
end

-- ── the tick ────────────────────────────────────────────────────────────────
local function tick(e, tnow)
  local R = RX()
  if not (R and e.M) then return end
  -- the pumps' power may have changed (the grid short, a breaker)
  local run = run_of(e)
  local sig = run_sig(run)
  if sig ~= e.runSig then rebuild_model(e, "run") end
  local dt = tnow - (e.t or tnow)
  if dt < 0 then dt = 0; e.t = tnow end
  if dt > R.RX.catch_max then e.t = tnow - R.RX.catch_max; dt = R.RX.catch_max end
  if dt <= 0 then return end
  local saved = R.RX.MAXSTEPS
  R.RX.MAXSTEPS = STEPS
  local dmg0 = e.S.y[R.IDX.dmg]
  local ok, rep = pcall(R.advance, e.S, e.M, dt, e.t)
  R.RX.MAXSTEPS = saved
  if not ok then if log then log("reactor: advance failed: " .. tostring(rep)) end return end
  PROF.steps = PROF.steps + rep.steps
  e.t = e.t + (dt - rep.left)
  e.o = R.derive(e.M, e.S, e.S.y, nil, {})
  -- the release: fuel damage vented by the relief valve, decaying
  local dd = math.max(0, e.S.y[R.IDX.dmg] - dmg0)
  local took = dt - rep.left
  if (e.rel or 0) > 0 then e.rel = e.rel * 0.5 ^ (took / REL_HALF) end
  if dd > 0 then
    local vented = (e.o.Qboil or 0) > 0 or e.S.melt
    e.rel = (e.rel or 0) + math.min(dd, 1) * REL_K * (vented and 1 or 0.05)
  end
  -- the trend
  local h = e.hist
  local last = h[#h]
  if not last or e.t - last[1] >= HIST_DT then
    h[#h + 1] = { e.t, e.o.P or 0, R.xenonWorth(e.M, e.S.y), (e.o.Pe or 0) / 1000 }
    while #h > HIST_N do table.remove(h, 1) end
  end
  for _, ev in ipairs(rep.events) do
    say(ev.text)
    e.dirty_save = true
    lastEvents[#lastEvents + 1] = { key = e.key, t = ev.t, text = ev.text, kind = ev.kind, cause = ev.cause }
    while #lastEvents > 20 do table.remove(lastEvents, 1) end
    if audio and audio.play and now() > 2 then
      pcall(audio.play, ev.kind == "trip" and "audio/foley/switch_3.ogg" or "audio/foley/switch_3.ogg", { track = "UI", volume = 0.7 })
    end
  end
  -- burnt rods into the save now and then
  if rep.steps > 0 then e.ch_dirty = true end
  publish(e)
end
lastEvents = {}

function stepNow()
  local tnow = agency_now()
  for _, e in pairs(PL) do tick(e, tnow) end
end

-- ── controls (the menus and probes call these) ──────────────────────────────
local function entry(key) return PL[key] end
function plants() return PL end
function plant(key) return PL[key] end
local function touch(e) e.dirty_save = true; e.touched = now(); e.next_t = 0; stepNow() end
function startUp(key, set)
  local e, R = entry(key), RX()
  if not (e and R and e.M) then return false, "no plant" end
  local why = R.startWhyNot(e.M, e.S, e.o or {})
  if why then return false, why end
  R.startUp(e.S, set or 0.5)
  touch(e)
  say(string.format("Reactor: start-up on the automatic controller to %d %%", math.floor((set or 0.5) * 100 + 0.5)))
  return true
end
function setPoint(key, set)
  local e, R = entry(key), RX()
  if not (e and R) then return false end
  e.S.set = math.max(0.02, math.min(1.1, set))
  if e.S.mode ~= "auto" and not e.S.scram then e.S.mode = "auto" end
  touch(e)
  return true
end
function manualRods(key, dx)
  local e = entry(key)
  if not e then return false end
  local S = e.S
  if S.scram then return false, "tripped" end
  if S.mode == "auto" then S.mode = "manual"; S.xt = e.o and e.o.x or S.y[3] end
  S.xt = math.max(0, math.min(1, (S.xt or 1) + dx))
  touch(e)
  return true
end
function scram(key)
  local e, R = entry(key), RX()
  if not (e and R) then return false end
  local ok = R.scram(e.S, e.t)
  if ok then say("SCRAM: the rods are dropping") end
  touch(e)
  return ok
end
function resetTrip(key)
  local e, R = entry(key), RX()
  if not (e and R) then return false end
  local why = R.resetWhyNot(e.M, e.S, e.o or {})
  if why then return false, why end
  R.resetTrip(e.S)
  touch(e)
  return true
end
function setProtection(key, on) local e = entry(key); if e then e.S.prot = on and true or false; touch(e) end end
function setCooldown(key, on) local e = entry(key); if e then e.S.cooldown = on and true or nil; touch(e) end end
function setTurbine(key, on) local e = entry(key); if e then e.turbOn = on and true or false; rebuild_model(e, "turbine"); touch(e) end end
function setPump(sid, uid, on)
  for _, e in pairs(PL) do
    if e.sid == sid then
      local found = false
      for _, L in ipairs({ e.pl.pri, e.pl.sec }) do for _, pu in ipairs(L.pumps or {}) do if pu.uid == uid then found = true end end end
      if found then
        e.pumpsOn[uid] = on and true or false
        rebuild_model(e, "pump")
        publish(e)
        local BG = ref("base_grid")
        if BG and BG.markDirty then BG.markDirty() end
        touch(e)
        return true
      end
    end
  end
  return false
end
function pumpOn(sid, uid)
  for _, e in pairs(PL) do if e.sid == sid and e.pumpsOn[uid] ~= nil then return e.pumpsOn[uid] ~= false end end
  return true
end

-- The plant a piece of structure `sid` belongs to (its vessel's, or the first).
function plantOfPart(sid, uid)
  local first = nil
  for _, e in pairs(PL) do
    if e.sid == sid then
      first = first or e
      if e.uid == uid then return e end
      for _, c in ipairs(e.M and e.M.core.channels or {}) do if c.uid == uid then return e end end
      for _, L in ipairs({ e.pl.pri, e.pl.sec }) do if L.parts and L.parts[uid] then return e end end
    end
  end
  return first
end

-- Load n rods of `item` into channel `uid` of structure `sid`. The refuelling
-- rule (reactor.loadWhyNot) and the plant's state decide. `from` = an
-- inventory container ("base": the stores) or nil (free: probes, Creative).
-- → n loaded, why
function loadRods(sid, uid, item, n, from)
  local R = RX()
  local e = plantOfPart(sid, uid)
  if not (R and e) then return 0, "no reactor here" end
  if not (e.S.scram or (e.o and (e.o.x or 0) > 0.99)) and (e.o and (e.o.P or 0) > 1e-4) then return 0, "shut the reactor down first" end
  local ch = ch_of(sid)
  local inv = ref("inventory")
  local got = 0
  local why = nil
  for _ = 1, n or 1 do
    why = R.loadWhyNot(e.pl, ch, uid, item, e.env)
    if why then break end
    if from and inv then
      if (inv.itemCount(from, item) or 0) < 1 then why = "no " .. item .. " in the stores" break end
      inv.removeItem(from, item, 1)
    end
    ch[uid] = ch[uid] or { rods = {} }
    ch[uid].rods[#ch[uid].rods + 1] = R.newRod(item)
    got = got + 1
  end
  if got > 0 then
    write_ch(sid)
    rebuild_model(e, "fuel")
    touch(e)
  end
  return got, why
end
-- Take a channel's rods out (spent ones as Spent Rods, the rest as what
-- they went in as) into container `to`. → n, why
function unloadRods(sid, uid, to)
  local R = RX()
  local e = plantOfPart(sid, uid)
  if not (R and e) then return 0, "no reactor here" end
  if not e.S.scram and (e.o and (e.o.P or 0) > 1e-4) then return 0, "shut the reactor down first" end
  local ch = ch_of(sid)
  local c = ch[uid]
  if not (c and #c.rods > 0) then return 0, "the channel is empty" end
  local inv = ref("inventory")
  local n = #c.rods
  for _, r in ipairs(c.rods) do
    local id = (r.phi or 0) > 1e18 and "spentRod" or (r.id or "fuelRod")
    if to and inv then inv.addItem(to, id, 1, { force = true }) end
  end
  c.rods = {}
  write_ch(sid)
  rebuild_model(e, "fuel")
  touch(e)
  return n
end
function channelRods(sid, uid) local c = ch_of(sid)[uid]; return c and c.rods or {} end

-- ── the readouts: one page for the console, the menus and the probes ────────
local function kw(w) w = (w or 0) / 1000; if math.abs(w) >= 100 then return string.format("%.0f kW", w) end return string.format("%.1f kW", w) end
local function pcm(r) return string.format("%+.0f pcm", (r or 0) * 1e5) end
-- → { title, lines = { { text, level } }, alarms, trend }
function page(e)
  local R = RX()
  if not (R and e and e.M) then return { title = "REACTOR", lines = { { "no plant", 1 } } } end
  local M, S, o = e.M, e.S, e.o or R.derive(e.M, e.S, e.S.y, nil, {})
  local L = {}
  local function add(t, lv) L[#L + 1] = { t, lv or 0 } end
  local mode = S.melt and "MELTED" or (S.scram and "TRIPPED" or (S.mode == "auto" and string.format("AUTO %d %%", math.floor((S.set or 0) * 100 + 0.5)) or "MANUAL"))
  local per = (o.P or 0) > 1e-8 and R.period(M, S, S.y) or nil
  local state = (o.k or 0) > 1.0005 and "SUPERCRITICAL" or ((o.k or 0) > 0.9995 and "CRITICAL" or "subcritical")
  add(string.format("k %.5f  ρ %s  %s  period %s", o.k or 0, pcm(o.rho), state, per and (math.abs(per) < 1e5 and string.format("%.0f s", per)) or "∞"),
    (per and per > 0 and per < 30) and 2 or 0)
  add(string.format("POWER %.1f %%  %s th  (fission %s, decay %s)", (o.P or 0) * 100, kw(o.Qcore), kw(o.Qfis), kw(o.Qdec)))
  add(string.format("RODS %d %% in  ·  shutdown margin %.1f %%", math.floor((o.x or 0) * 100 + 0.5), R.shutdownMargin(M) * 100), R.shutdownMargin(M) < 0.02 and 2 or 0)
  local xw, smw = R.xenonWorth(M, S.y), R.samariumWorth(M, S.y)
  local h = e.hist
  local trend = ""
  if #h >= 2 then
    local d = (h[#h][3] or 0) - (h[math.max(1, #h - 6)][3] or 0)
    trend = (d > 1e-4) and " ▲" or ((d < -1e-4) and " ▼" or " ·")
  end
  local bu = R.burnup(M)
  add(string.format("XENON −%.2f %%%s  ·  Sm −%.2f %%  ·  burnup %.2f %% FIMA", xw * 100, trend, smw * 100, bu * 100))
  -- (an Engineer at level 2 reads the forecast)
  local cl = ref("crew")
  local fore = cl and cl.bestPerk and cl.roster and cl.bestPerk(cl.roster(), "xe_forecast")
  if (S.scram or (o.P or 0) < 0.01) and fore then
    local hr, pk, tpk = R.xenonForecast(M, S, S.y)
    add(hr and (hr == 0 and "RESTART: the rods can make it critical now" or string.format("RESTART in ~%d h (xenon peaks at +%d h)", hr, tpk or 0)) or "RESTART: not in four days (xenon)", hr == 0 and 0 or 1)
  end
  add(string.format("FUEL %.0f K  ·  PRIMARY %.0f K, %.1f kg/s%s  ·  boils at %.0f K", o.Tf or 0, o.Tp or 0, o.mpe or 0,
    (o.mnc or 0) > 0.5 * (o.mpe or 0) and " (natural)" or "", M.tsat), (o.Tp or 0) > M.tsat - 25 and 2 or 0)
  add(string.format("SECONDARY %.0f K, %.1f kg/s  ·  CONDENSER %.0f K", o.Ts or 0, o.ms or 0, o.Tk or 0), (o.Tk or 0) > 420 and 1 or 0)
  local aux = 0
  for _, v in pairs(e.aux or {}) do aux = aux + v end
  local eff = (o.Qcore or 0) > 1 and (o.Pe or 0) / o.Qcore or 0
  add(string.format("TURBINE %s(e)  ·  %.1f %% of the heat (Carnot %.0f %%)  ·  pumps %.1f kW  ·  net %.1f kW",
    kw(o.Pe), eff * 100, (o.carnot or 0) * 100, aux, (o.Pe or 0) / 1000 - aux), (M.turb and not M.turb_on) and 1 or 0)
  local rad, share = R.radOf(M, o)
  local dose = rad * share + (e.rel or 0)
  add(string.format("DOSE at 5 m, unshielded: %.1f %% of lethal an hour%s", dose * 100, (e.rel or 0) > 0 and string.format(" (release %.1f %%)", e.rel * 100) or ""), dose > 1 and 1 or 0)
  local lim = R.limitedBy(M, S, o)
  add("LIMITED BY " .. tostring(lim), 1)
  for _, w in ipairs(M.warn or {}) do add(w, 1) end
  local A = R.alarms(M, S, o)
  return { title = string.format("REACTOR %s · %s", tostring(e.uid), mode), lines = L, alarms = A, trend = h, o = o }
end
function consoleText(sid, uid)
  local c = CONS[keyOf(sid, uid)]
  return c and c.text or nil
end

-- ── the console's screen (CRT green on black, 1 Hz while crew is near) ─────
local SW, SH = 1024, 576
local F_MONO, F_LABEL = "fonts/SolarMono.ttf", "fonts/SolarLabel.ttf"
local GREEN, AMBER, RED, DIM = { 0.45, 1.0, 0.55 }, { 1.0, 0.75, 0.25 }, { 1.0, 0.32, 0.25 }, { 0.20, 0.45, 0.25 }
local function paint_console(c)
  if not (image and image.new and valid(c.screen)) then return end
  local e = plantOfPart(c.sid, c.uid)
  local pg = page(e)
  local img = c.img
  if not img then
    local ok, im = pcall(image.new, SW, SH, 0.01, 0.03, 0.015, 1)
    if not ok or not im then return end
    img, c.img = im, im
  end
  pcall(img.fill, img, 0, 0, SW, SH, 0.01, 0.03, 0.015, 1)
  -- the bezel line and the header
  pcall(img.fill, img, 0, 0, SW, 54, 0.02, 0.08, 0.04, 1)
  pcall(img.fill, img, 0, 54, SW, 2, DIM[1], DIM[2], DIM[3], 1)
  local hcol = (pg.alarms and #pg.alarms > 0 and pg.alarms[1][2] == 2) and RED or GREEN
  pcall(img.text, img, 18, 12, pg.title, 30, hcol[1], hcol[2], hcol[3], 1, "left", F_LABEL)
  local t = { pg.title }
  local y = 66
  for _, l in ipairs(pg.lines) do
    if y > SH - 196 then break end
    local col = l[2] == 2 and RED or (l[2] == 1 and AMBER or GREEN)
    pcall(img.text, img, 18, y, l[1], 20, col[1], col[2], col[3], 1, "left", F_MONO)
    t[#t + 1] = l[1]
    y = y + 26
  end

  -- the annunciator: a band of tiles over the trend, two rows of three
  -- (the desk's lamp strip stands in front of the screen's bottom 64 px: nothing drawn there)
  local ax0, ay0 = 18, SH - 178
  local ax, ay = ax0, ay0
  for i, a in ipairs(pg.alarms or {}) do
    if i > 6 then break end
    ax, ay = ax0 + ((i - 1) % 3) * 330, ay0 + math.floor((i - 1) / 3) * 32
    local col = a[2] == 2 and RED or AMBER
    pcall(img.fill, img, ax, ay, 322, 28, col[1] * 0.25, col[2] * 0.25, col[3] * 0.25, 1)
    pcall(img.text, img, ax + 6, ay + 4, a[1]:sub(1, 36), 16, col[1], col[2], col[3], 1, "left", F_MONO)
    t[#t + 1] = "ALARM " .. a[1]

  end
  if #(pg.alarms or {}) == 0 then pcall(img.text, img, ax + 6, ay + 4, "NO ALARMS", 16, DIM[1] * 2, DIM[2] * 1.6, DIM[3] * 2, 1, "left", F_MONO) end
  -- the 24 h trend: power (green) and xenon's worth (amber), along the bottom
  local gx, gy, gw, gh = 18, SH - 110, SW - 36, 44
  pcall(img.fill, img, gx, gy, gw, gh, 0.02, 0.06, 0.03, 1)
  pcall(img.text, img, gx + 4, gy + 2, "24 h · POWER", 12, GREEN[1], GREEN[2], GREEN[3], 0.8, "left", F_MONO)
  pcall(img.text, img, gx + 150, gy + 2, "XENON", 12, AMBER[1], AMBER[2], AMBER[3], 0.8, "left", F_MONO)
  local h = pg.trend or {}
  local n = #h
  if n >= 2 then
    local xmax = 0.001
    for _, s in ipairs(h) do if (s[3] or 0) > xmax then xmax = s[3] end end
    for i, s in ipairs(h) do
      local x = gx + math.floor((i - 1) / math.max(1, HIST_N - 1) * (gw - 3))
      local py = gy + gh - 3 - math.floor(math.min(1.2, s[2] or 0) / 1.2 * (gh - 16))
      local xy = gy + gh - 3 - math.floor((s[3] or 0) / xmax * (gh - 16))
      pcall(img.fill, img, x, py, 3, 3, GREEN[1], GREEN[2], GREEN[3], 1)
      pcall(img.fill, img, x, xy, 3, 3, AMBER[1], AMBER[2], AMBER[3], 1)
    end
  end
  -- scan lines: a CRT's
  -- (no scan-line pass: 144 blends a repaint cost more than the page)
  c.text = table.concat(t, " | ")
  local ok, tex = pcall(img.texture, img)
  if ok and tex and c.tex ~= tex then
    c.tex = tex
    pcall(c.screen.setMaterial, c.screen, { texture = tex, unlit = true, color = { 1, 1, 1 } })
  end
end

-- structures' hooks (the console piece names this script)
function spawned(rec, part, node)
  local d = defs(part.id)
  if not (d and d.console and valid(node)) then return end
  local ok, s = pcall(node.getChild, node, "Screen")
  local c = { sid = rec.id, uid = part.uid, node = node, screen = ok and s or nil, t = -10, b = rec.b }
  local ST = ref("structures")
  if ST and ST.partPose then c.px, c.py, c.pz = ST.partPose(rec, part, 0) end
  CONS[keyOf(rec.id, part.uid)] = c
end
function gone(sid, uid)
  local c = CONS[keyOf(sid, uid)]
  if c and c.tex and assets and assets.release then pcall(assets.release, c.tex) end
  CONS[keyOf(sid, uid)] = nil
end

-- ── the menus ───────────────────────────────────────────────────────────────
local ROD_SECS = 6
local function provider(t, ctx)
  if not (t and t.node) then return {} end
  local ST = ref("structures")
  local R = RX()
  if not (ST and R and ST.partOfNode) then return {} end
  local FB = ref("field_builder")
  local rec, part
  if FB and FB.pickTarget then rec, part = FB.pickTarget(t) else rec, part = ST.partOfNode(t.node) end
  if not part then return {} end
  local d = defs(part.id) or {}
  if not (d.nuclear or d.ports or d.console or d.turbine or d.pump) then return {} end
  local sid, uid = rec.id, part.uid
  local e = plantOfPart(sid, uid)
  local out = {}
  if not e then
    out[#out + 1] = { id = "rx_none", type = "info", label = "Reactor", group = "Reactor", value = "no Reactor Vessel Base in this structure" }
    return out, d.label
  end
  local key = e.key
  local nu = d.nuclear
  local cl = ref("crew")
  local a = ctx and ctx.actor
  local function engineer() return a and a.id and cl and cl.hasRole and cl.hasRole(a.id, "engineer") end
  -- the plant's state, on every piece of it
  out[#out + 1] = { id = "rx_state", type = "info", label = "Reactor", group = "Reactor", value = function()
    local pg = page(e)
    return pg.title .. " · " .. (pg.lines[2] and pg.lines[2][1] or "") end }
  out[#out + 1] = { id = "rx_core", type = "info", label = "Core", group = "Reactor", value = function() return page(e).lines[1][1] end }
  out[#out + 1] = { id = "rx_lim", type = "info", label = "Limited by", group = "Reactor", value = function() return tostring(R.limitedBy(e.M, e.S, e.o or {})) end }
  if d.console or (nu and nu.role == "vessel") then
    if e.S.scram then
      out[#out + 1] = { id = "rx_reset", type = "action", label = "Reset the trip", group = "Reactor",
        enabled = function() return R.resetWhyNot(e.M, e.S, e.o or {}) == nil end,
        why = function() return R.resetWhyNot(e.M, e.S, e.o or {}) end,
        act = function() return resetTrip(key) end }
    else
      out[#out + 1] = { id = "rx_scram", type = "action", label = "SCRAM", group = "Reactor", hint = "rods in",
        act = function() return scram(key) end }
      if e.S.mode ~= "auto" then
        out[#out + 1] = { id = "rx_start", type = "action", label = "Start up (automatic, 50 %)", group = "Reactor",
          enabled = function() return R.startWhyNot(e.M, e.S, e.o or {}) == nil end,
          why = function() return R.startWhyNot(e.M, e.S, e.o or {}) end,
          act = function() return startUp(key, 0.5) end }
      end
      out[#out + 1] = { id = "rx_up", type = "action", label = "Setpoint +10 %", group = "Reactor", keep = true,
        act = function() return setPoint(key, (e.S.set or 0.5) + 0.1) end }
      out[#out + 1] = { id = "rx_dn", type = "action", label = "Setpoint −10 %", group = "Reactor", keep = true,
        act = function() return setPoint(key, (e.S.set or 0.5) - 0.1) end }
      out[#out + 1] = { id = "rx_out", type = "action", label = "Rods out 2 % (manual)", group = "Reactor", keep = true,
        act = function() return manualRods(key, -0.02) end }
      out[#out + 1] = { id = "rx_in", type = "action", label = "Rods in 5 % (manual)", group = "Reactor", keep = true,
        act = function() return manualRods(key, 0.05) end }
    end
    out[#out + 1] = { id = "rx_prot", type = "toggle", label = "Protection (automatic trips)", group = "Reactor", keep = true,
      on = function() return e.S.prot ~= false end, act = function(want) setProtection(key, want) end }
    out[#out + 1] = { id = "rx_cool", type = "toggle", label = "Cool down (steam dump open)", group = "Reactor", keep = true,
      on = function() return e.S.cooldown == true end, act = function(want) setCooldown(key, want) end }
    if e.M and e.M.turb then
      out[#out + 1] = { id = "rx_turb", type = "toggle", label = "Turbine online", group = "Reactor", keep = true,
        on = function() return e.turbOn ~= false end, act = function(want) setTurbine(key, want) end }
    end
  end
  if d.pump then
    out[#out + 1] = { id = "rx_pump", type = "toggle", label = "Pump running", group = "Pump", keep = true,
      on = function() return pumpOn(sid, uid) end, act = function(want) setPump(sid, uid, want) end,
      hint = function() local BG = ref("base_grid"); return (BG and BG.partServed and BG.partServed(sid, uid) == false) and "no power" or nil end }
  end
  if d.turbine then
    out[#out + 1] = { id = "rx_turbinfo", type = "info", label = "Generator", group = "Turbine",
      value = function() local o = e.o or {}; return string.format("%s(e) · steam %.0f K · condenser %.0f K", kw(o.Pe), o.Ts or 0, o.Tk or 0) end }
  end
  if nu and nu.role == "fuel" then
    local inv = ref("inventory")
    local function secs()
      local p = (cl and cl.perk and a and a.id) and tonumber(cl.perk(a.id, "refuel_time")) or 1
      return ROD_SECS * (p or 1)
    end
    out[#out + 1] = { id = "rx_rods", type = "info", label = "Rods", group = "Fuel Channel", value = function()
      local rods = channelRods(sid, uid)
      if #rods == 0 then return "empty · eight slots" end
      local by = {}
      local f = 0
      for _, r in ipairs(rods) do by[r.id] = (by[r.id] or 0) + 1; f = f + (r.fp or 0) end
      local parts = {}
      for id, n in pairs(by) do parts[#parts + 1] = string.format("%d × %s", n, R.ROD_LABEL[id] or id) end
      return string.format("%s · burnup %.2f %% FIMA", table.concat(parts, ", "), f / #rods * 100) end }
    for _, item in ipairs({ "fuelRod", "fuelRodNU", "fuelRodHALEU" }) do
      local have = inv and inv.itemCount and inv.itemCount("base", item) or 0
      if have > 0 then
        local function why()
          if not engineer() then return "only an Engineer refuels a reactor" end
          local rods = channelRods(sid, uid)
          local w = R.loadWhyNot(e.pl, ch_of(sid), uid, item, e.env)
          if w then return w end
          if #rods >= 8 then return "the channel is full" end
          return nil
        end
        local nfit = math.min(have, 8 - #channelRods(sid, uid))
        out[#out + 1] = { id = "rx_load_" .. item, type = "action", group = "Fuel Channel",
          label = string.format("Load %d %s rod%s from the stores", nfit, R.ROD_LABEL[item] or item, nfit == 1 and "" or "s"),
          hint = string.format("%.0f s", secs() * nfit),
          enabled = function() return why() == nil end, why = why,
          act = function() local w = why(); if w then return false, w end return true end,
          job = { secs = secs() * nfit, label = "Loading the fuel channel",
            check = function() local w = why(); return w == nil, w end,
            done = function()
              local n, w = loadRods(sid, uid, item, nfit, "base")
              if n == 0 then return false, w end
              if cl and cl.credit and a and a.id then pcall(cl.credit, a.id, "crafted", n) end
              say(string.format("%d rod%s in the channel%s", n, n == 1 and "" or "s", w and (" · " .. w) or ""))
              return true
            end } }
      end
    end
    if #channelRods(sid, uid) > 0 then
      out[#out + 1] = { id = "rx_unload", type = "action", group = "Fuel Channel", label = "Unload the rods to the stores", hint = "hot",
        enabled = function() return engineer() == true end, why = function() return (not engineer()) and "only an Engineer refuels a reactor" or nil end,
        act = function() return engineer() == true end,
        job = { secs = secs() * #channelRods(sid, uid), label = "Unloading the fuel channel",
          check = function() return engineer() == true, "only an Engineer" end,
          done = function() local n, w = unloadRods(sid, uid, "base"); if n == 0 then return false, w end return true end } }
    end
  end
  return out, d.label
end
providerFn = provider
local reg_on = false

-- ── the NUCLEAR overlay (lateUpdate: drawn poses, this frame's body read) ──
overlay = false
overlayAlways = false
drawn = { lines = 0, labels = 0, rings = 0 }
OVERLAY_R = 300
local function overlay_on()
  if not overlay then return false end
  if overlayAlways then return true end
  local fb = ref("field_builder")
  return fb and fb.isOpen and fb.isOpen() or false
end
-- temperature to the CRT's palette: cool phosphor green → amber → red
local function tcol(T)
  local f = math.max(0, math.min(1, ((T or 300) - 300) / 320))
  if f < 0.5 then local g = f / 0.5; return 0.35 + 0.65 * g, 1.0 - 0.2 * g, 0.55 - 0.35 * g end
  local g = (f - 0.5) / 0.5
  return 1.0, 0.8 - 0.5 * g, 0.2
end
-- (a structure-frame point to body coordinates)
local function framed(rec)
  local ST = ref("structures")
  local ux, uy, uz, fx, fy, fz, rx, ry, rz = ST.frame(rec)
  return function(lx, ly, lz)
    return rec.x + rx * lx + ux * ly + fx * lz, rec.y + ry * lx + uy * ly + fy * lz, rec.z + rz * lx + uz * ly + fz * lz
  end, { x = ux, y = uy, z = uz }, { x = fx, y = fy, z = fz }, { x = rx, y = ry, z = rz }
end
-- the dose field's rays: per direction, the walls it crosses (entry fraction, k)
local function seg_entry(ax, ay, az, bx, by, bz, box)
  local X, Y, Z = box.X, box.Y, box.Z
  local ox, oy, oz = ax - box.x, ay - box.y, az - box.z
  local dx, dy, dz = bx - ax, by - ay, bz - az
  local t0, t1 = 0, 1
  for _, A in ipairs({ { X, box.hx }, { Y, box.hy }, { Z, box.hz } }) do
    local u, h = A[1], A[2]
    local o = ox * u.x + oy * u.y + oz * u.z
    local d = dx * u.x + dy * u.y + dz * u.z
    if math.abs(d) < 1e-12 then
      if math.abs(o) > h then return nil end
    else
      local ta, tb = (-h - o) / d, (h - o) / d
      if ta > tb then ta, tb = tb, ta end
      if ta > t0 then t0 = ta end
      if tb < t1 then t1 = tb end
      if t0 > t1 then return nil end
    end
  end
  return t0
end
DOSE_LEVELS = { { 1.0, RED }, { 0.1, AMBER }, { 0.01, GREEN } }  -- lethal shares an hour
DOSE_R = 300
DOSE_RAYS = 72
local function dose_field(e, rec)
  local BS, ST = ref("base_shield"), ref("structures")
  local key = tostring(ST.version)
  if e.field and e.field.key == key then return e.field end
  local to, U, F, Rv = framed(rec)
  local cx, cy, cz = to(e.pl.vx, e.pl.vy + e.pl.top + 1.2, e.pl.vz)
  local hy = e.pl.vy + 1.4
  local rays = {}
  local walls = BS and BS.walls and BS.walls() or {}
  for k = 0, DOSE_RAYS - 1 do
    local a = k / DOSE_RAYS * math.pi * 2
    local lx, lz = e.pl.vx + math.sin(a) * DOSE_R, e.pl.vz + math.cos(a) * DOSE_R
    local bx, by, bz = to(lx, hy, lz)
    local hits = {}
    for _, w in ipairs(walls) do
      if w.b == rec.b and (w.x - cx) ^ 2 + (w.y - cy) ^ 2 + (w.z - cz) ^ 2 < (DOSE_R + 3) ^ 2 then
        local t0 = seg_entry(cx, cy, cz, bx, by, bz, w)
        if t0 then hits[#hits + 1] = { t0 * DOSE_R, w.k or 0.05 } end
      end
    end
    table.sort(hits, function(p, q) return p[1] < q[1] end)
    rays[k + 1] = { a = a, hits = hits }
  end
  e.field = { key = key, rays = rays, hy = hy }
  return e.field
end
-- the radius on ray `ray` where a source of `rad` (lethal shares an hour at 5 m) falls to `lvl`
local function dose_radius(ray, rad, lvl)
  local f = 1
  local hi = 1
  local r = 1
  while r <= DOSE_R do
    while ray.hits[hi] and ray.hits[hi][1] <= r do f = f * ray.hits[hi][2]; hi = hi + 1 end
    local d = rad * (5 / math.max(r, 1)) ^ 2 * f
    if d < lvl then return r end
    r = r + ((r < 30) and 0.5 or 2)
  end
  return nil
end
function drawOverlay()
  drawn = { lines = 0, labels = 0, rings = 0 }
  if not (draw and draw.line) then return drawn end
  local R, ST = RX(), ref("structures")
  if not (R and ST) then return drawn end
  local a = find and (find("Camera 1") or find("Astronaut"))
  local ax, ay, az = 0, 0, 0
  if valid(a) then local w = a.worldPos or a; ax, ay, az = w.x, w.y, w.z end
  local bodies = {}
  local function body(nm) local b = bodies[nm]; if b == nil then b = (space and space.body and space.body(nm)) or false; bodies[nm] = b end return b or nil end
  local placed = {}
  local function text(x, y, z, s, col, dy, size)
    if not (camera and camera.worldToScreen and draw.text) then return end
    local sx, sy, _, on = camera.worldToScreen(x, y, z)
    if not on then return end
    size = size or 14
    local w = #s * size * 0.52 + 12
    sy = sy + (dy or 0)
    for _ = 1, 8 do
      local hit = false
      for _, p in ipairs(placed) do if math.abs(p[1] - sx) < (p[3] + w) / 2 and math.abs(p[2] - sy) < size + 8 then hit = true end end
      if not hit then break end
      sy = sy + size + 9
    end
    placed[#placed + 1] = { sx, sy, w }
    if draw.rect then draw.rect(sx - w / 2, sy - 3, w, size + 7, 0.01, 0.04, 0.02, 0.72, 3) end
    draw.text(sx, sy, s, size, col[1], col[2], col[3], 1, "center")
    drawn.labels = drawn.labels + 1
  end
  for _, e in pairs(PL) do
    local rec = ST.get(e.sid)
    local b = rec and body(rec.b)
    if b and e.M and (rec.x + b.x - ax) ^ 2 + (rec.y + b.y - ay) ^ 2 + (rec.z + b.z - az) ^ 2 < OVERLAY_R * OVERLAY_R then
      local to = framed(rec)
      local o = e.o or {}
      -- the loops: each piece's run from its inlet to its outlet, by temperature, chevrons the way they flow
      for li, L in ipairs({ { e.pl.graph.pri, o.Tp, o.mpe or 0 }, { e.pl.graph.sec, o.Ts, o.ms or 0 } }) do
        local cr, cg, cb = tcol(L[2])
        for _, sg in ipairs(L[1] or {}) do
          local x0, y0, z0 = to(sg.a[1], sg.a[2] + 0.18, sg.a[3])
          local x1, y1, z1 = to(sg.b[1], sg.b[2] + 0.18, sg.b[3])
          local xc, yc, zc = to(sg.c[1], sg.c[2] + 0.18, sg.c[3])
          draw.line(b.x + x0, b.y + y0, b.z + z0, b.x + xc, b.y + yc, b.z + zc, cr, cg, cb, 0.95)
          draw.line(b.x + xc, b.y + yc, b.z + zc, b.x + x1, b.y + y1, b.z + z1, cr, cg, cb, 0.95)
          drawn.lines = drawn.lines + 2
          if L[3] > 0.05 then
            local dx, dy, dz = x1 - x0, y1 - y0, z1 - z0
            local l = math.sqrt(dx * dx + dy * dy + dz * dz)
            if l > 0.3 then
              dx, dy, dz = dx / l, dy / l, dz / l
              local Ux, Uy, Uz = rec.ux or 0, rec.uy or 1, rec.uz or 0
              local sx, sy, sz = Uy * dz - Uz * dy, Uz * dx - Ux * dz, Ux * dy - Uy * dx
              local s = 0.22
              local px, py, pz = b.x + xc, b.y + yc, b.z + zc
              draw.line(px, py, pz, px - dx * s + sx * s * 0.7, py - dy * s + sy * s * 0.7, pz - dz * s + sz * s * 0.7, cr, cg, cb, 1)
              draw.line(px, py, pz, px - dx * s - sx * s * 0.7, py - dy * s - sy * s * 0.7, pz - dz * s - sz * s * 0.7, cr, cg, cb, 1)
            end
          end
        end
      end
      -- the components' heat
      local function at_part(uid, up)
        local p = ST.getPart(e.sid, uid)
        if not p then return nil end
        local d = defs(p.id)
        local x, y, z = to(p.x or 0, (p.y or 0) + (d and d.h or 1) + (up or 0.4), p.z or 0)
        return b.x + x, b.y + y, b.z + z
      end
      local vx, vy, vz = at_part(e.uid, 3.0)
      if vx then
        local cr, cg, cb = tcol(o.Tf)
        text(vx, vy, vz, string.format("CORE %s · fuel %.0f K · k %.4f", kw(o.Qcore), o.Tf or 0, o.k or 0), { cr, cg, cb }, 0, 15)
        local pg = page(e)
        local lim = R.limitedBy(e.M, e.S, o)
        text(vx, vy, vz, string.format("%s · %s(e) · %.1f %% · limited by %s", pg.title, kw(o.Pe), 100 * (o.Pe or 0) / math.max(o.Qcore or 1, 1), lim), (e.S.scram and RED) or GREEN, -26, 15)
      end
      for _, sg in ipairs(e.pl.pri.sgs or {}) do
        local x, y, z = at_part(sg.uid, 0.3)
        if x then text(x, y, z, string.format("STEAM GENERATOR %s · Δ %.0f K", kw(o.Qhx), (o.Tp or 0) - (o.Ts or 0)), { tcol(o.Ts) }, 0, 14) end
      end
      for _, L in ipairs({ e.pl.pri, e.pl.sec }) do
        for _, pu in ipairs(L.pumps or {}) do
          local x, y, z = at_part(pu.uid, 0.3)
          if x then text(x, y, z, string.format("PUMP %s · %.1f kg/s", pumpOn(e.sid, pu.uid) and "ON" or "OFF", L == e.pl.pri and (o.mpe or 0) or (o.ms or 0)),
            pumpOn(e.sid, pu.uid) and GREEN or AMBER, 0, 14) end
        end
      end
      for _, tb in ipairs(e.pl.sec.turbines or {}) do
        local x, y, z = at_part(tb.uid, 0.3)
        if x then text(x, y, z, string.format("TURBINE %s(e) · Carnot %.0f %%", kw(o.Pe), (o.carnot or 0) * 100), GREEN, 0, 14) end
      end
      for _, rj in ipairs(e.pl.sec.rejects or {}) do
        local x, y, z = at_part(rj.uid, 0.3)
        if x then text(x, y, z, string.format("%s · %.0f K", rj.def.reject.kind == "tower" and "TOWER" or "RADIATOR", o.Tk or 0), { tcol(o.Tk) }, 0, 13) end
      end
      if e.pl.pri.press then
        local x, y, z = at_part(e.pl.pri.press.uid, 0.3)
        if x then text(x, y, z, string.format("PRESSURISER · boils at %.0f K", e.M.tsat), (o.Tp or 0) > e.M.tsat - 25 and RED or GREEN, 0, 13) end
      end
      -- the dose field at chest height: where it falls to a lethal dose an
      -- hour (red), a tenth (amber), a hundredth (green), walls by record
      local rad, share = radOf(e.sid, e.uid)
      if rad * share > 1e-4 and draw.line then
        local fld = dose_field(e, rec)
        for _, lv in ipairs(DOSE_LEVELS) do
          -- (neighbouring rays are joined only where the contour is
          -- continuous: across a wall's shadow edge it jumps, and a join
          -- there would be a spike, not the field)
          local prev, first = nil, nil
          local function join(a, c)
            if a and c and math.max(a.r, c.r) < 1.8 * math.min(a.r, c.r) then
              draw.line(a[1], a[2], a[3], c[1], c[2], c[3], lv[2][1], lv[2][2], lv[2][3], 0.9); drawn.lines = drawn.lines + 1
            end
          end
          for k, ray in ipairs(fld.rays) do
            local r = dose_radius(ray, rad * share, lv[1])
            local pt = nil
            if r then
              local x, y, z = to(e.pl.vx + math.sin(ray.a) * r, fld.hy, e.pl.vz + math.cos(ray.a) * r)
              pt = { b.x + x, b.y + y, b.z + z, r = r }
            end
            join(prev, pt)
            if k == 1 then first = pt end
            prev = pt
          end
          join(prev, first)
          drawn.rings = drawn.rings + 1
        end
      end
    end
  end
  return drawn
end

-- ── the driver ──────────────────────────────────────────────────────────────
function start(node)
  if findScripts then
    local all = findScripts("reactor_plant")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  PL, CH, CONS, lastEvents = {}, {}, {}, {}
  st_ver, dirty_t, tick_t, save_t = nil, -10, -10, -10
  overlay, overlayAlways = false, false
end

local function save_all(force)
  for _, e in pairs(PL) do
    if force or e.dirty_save or (e.S and not e.S.scram and (e.o and (e.o.P or 0) > 1e-6)) then
      write_plant(e)
      if e.ch_dirty then write_ch(e.sid); e.ch_dirty = false end
      e.dirty_save = false
    end
  end
end
function saveNow() save_all(true) end

function update(node, dt)
  if not reg_on then
    local reg = ref("context_registry")
    if reg and reg.register then reg.register("prop", provider, { id = "reactor_plant", order = 7 }); reg_on = true end
  end
  local ST = ref("structures")
  if not ST then return end
  local t = now()
  if ST.version ~= st_ver then
    if dirty_t < 0 then dirty_t = t end
    if t - dirty_t >= 0.5 or st_ver == nil then find_plants(); dirty_t = -10 end
  end
  if next(PL) == nil then return end
  local every = (params and params.every) or 0.2
  if t - tick_t >= every then
    tick_t = t
    local w0 = wall()
    local tnow = agency_now()
    PROF.steps = 0
    local n = 0
    for _, e in pairs(PL) do
      -- (a quiet plant, tripped or subcritical and not just touched, ticks at 1 Hz)
      local quiet = (e.S.scram or e.S.melt or (e.o and (e.o.P or 0) < 1e-5)) and t - (e.touched or -10) > 5
      if t >= (e.next_t or 0) then tick(e, tnow); n = n + 1; e.next_t = t + (quiet and 1.0 or every) end
    end
    PROF.plants = n
    if w0 then PROF.tick_ms = (wall() - w0) * 1000 end
  end
  if t - save_t >= SAVE_EVERY then save_t = t; save_all(false) end
  -- the consoles' screens, 1 Hz while crew is within 25 m
  local a = find and find("Astronaut")
  if a and next(CONS) then
    for k, c in pairs(CONS) do
      if not valid(c.node) then CONS[k] = nil
      elseif t - c.t >= 2.0 then
        local w = c.node.worldPos
        if w and (w.x - a.x) ^ 2 + (w.y - a.y) ^ 2 + (w.z - a.z) ^ 2 < 25 * 25 then c.t = t; paint_console(c) end
      end
    end
  end
end
function paintConsoles() for _, c in pairs(CONS) do paint_console(c) end end

function lateUpdate(node, dt)
  if overlay_on() then drawOverlay() end
end
