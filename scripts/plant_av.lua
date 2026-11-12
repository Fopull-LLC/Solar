-- PLANT_AV — what a base sounds and looks like when it runs and when it goes
-- wrong: the alarms (klaxons and beacons) and the machinery (its hum, its
-- whine, its stress). Playtest 2026-11-11:
--   "the alarms don't make any sound or have lights it seems"
--   "make sure reactors and big machinery can generate sounds and particles
--    accurate to the scenario, so going into the reactor room has a purpose:
--    you can inspect and visually and auditorily see if things are stressed
--    or starting to go wrong"
--
-- On the Build Kit node (scenes/system.ron), after room_air.
--
-- ── ALARMS ──────────────────────────────────────────────────────────────────
-- An alarm is { key, sid, kind, level (1 caution, 2 warning), text, uid (the
-- piece it sounds from) }. Found every POLL s from what the systems already
-- know, and raised or cleared here:
--   depress   room_air.alarms(): a room that held air venting (the klaxon, at
--             the door it goes through or the room's first door)
--   air       room_air.airAlarms(): a sealed room's air gone bad (the bell)
--   reactor   reactor.alarms() of every plant: its annunciator's red (the
--             klaxon) or amber (the bell) lines, at the vessel
--   fire      raise(key, { kind = "fire", … }) for any script that has one
-- Each sounds a recorded loop at its piece (audio/plant/alarm_klaxon, the
-- submarine dive alarm; alarm_buzzer, a mechanical fire bell), following the
-- piece's node (nothing kept in the world), the nearest MAX_ALARM_SND within
-- ALARM_R. The structure's ceiling lights turn rotating beacons while it lasts
-- (kit_live, from alarmLevel). SILENCE (silence(sid)): the terminal's ALARMS
-- and STATUS pages, the menu of any piece of the structure, stops the sound of
-- the alarms standing now; the beacons stay lit till the cause is gone, and a
-- new alarm sounds again. The base log records both.
--
-- ── MACHINERY ───────────────────────────────────────────────────────────────
-- The pieces that run (a reactor's vessel, pumps, pressuriser, turbine, tower;
-- scrubbers and O2 generators; the refinery's machines; process pumps) each
-- have a loop tied to their state, at their node: the core's hum with its
-- power, the coolant pumps' whine with their flow (they coast down), the
-- turbine's whine with its load, the fans, a crusher's grinding and dust, a
-- furnace's roar. STRESS is heard and seen: steam leaking off the pressuriser
-- as the primary nears boiling, its relief valve lifting (a hiss and a plume)
-- when it boils, the vessel shaking the floor at high fuel temperature or low
-- margin, a pump rattling when it cavitates (the primary near boiling) or is
-- knocked askew, or when a script says its bearing is going (stress(sid, uid,
-- "bearing", 0..1): Graveyard's FW-2).
--
-- COST: nothing with no structure within NEAR_R of the crew (one distance per
-- structure every SCAN s). Near: the emitters' states every SCAN s, at most
-- MAX_LOOPS loops (the loudest nearest), each on its piece's node; the puffs
-- and the shake only within a few metres. No per-frame work but the shake's.
--
-- Pure (luajit, tests/smoke_plant_av.lua): reactorCues(M, S, o, RX),
-- pickLoops(cands, n), alarmKindOf(kind).
-- Probes: alarms(), alarmLevel(sid), silence(sid, by), raise(key, a),
-- clear(key), stress(sid, uid, kind, v), emitters(), loops(), PROF.

defaults = {
  --@range 0.1 1 --@units s
  scan = 0.25,
}

POLL = 0.5             -- s between looks at the systems' alarms
NEAR_R = 60.0          -- structures this near the crew are heard
ALARM_R = 70.0
MAX_ALARM_SND = 3
MAX_LOOPS = 8
SHAKE_R = 12.0
PUFF_R = 30.0

SND = {
  klaxon = "audio/plant/alarm_klaxon.ogg", bell = "audio/plant/alarm_buzzer.ogg",
  hum = "audio/plant/transformer_hum.ogg", whine = "audio/plant/pump_whine.ogg", motor = "audio/plant/pump_motor.ogg",
  turbine = "audio/plant/turbine_whine.ogg", steam = "audio/plant/steam_leak.ogg", relief = "audio/plant/relief_valve.ogg",
  rattle = "audio/plant/bearing_rattle.ogg", fan = "audio/plant/fan_loop.ogg", crusher = "audio/plant/crusher_loop.ogg",
  furnace = "audio/plant/furnace_roar.ogg", silence = "audio/foley/switch_2.ogg",
}

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function valid(n) return n ~= nil and n.valid ~= false end
local function now() return time or 0 end
local function wall() return (app and app.wallClock) and app.wallClock() or nil end
local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end

PROF = { scan_ms = 0, loops = 0, emitters = 0, near = 0 }

-- ── pure ────────────────────────────────────────────────────────────────────
-- What a reactor plant sounds and looks like now, from its state:
--   hum      0..1 the core's hum (its power, a floor while it is warm)
--   pri, sec 0..1 the loops' pump speeds (they coast down)
--   load     0..1 the turbine's share of its rating
--   steam    0..1 steam leaking: the primary within 25 K of boiling
--   relief   bool the pressuriser's relief valve open (it boils off)
--   cav      0..1 the primary pumps cavitating (within 12 K of boiling, flowing)
--   shake    0..1 the vessel shaking (fuel near its trip, or a boiling core)
function reactorCues(M, S, o, RXC)
  RXC = RXC or {}
  local c = { hum = 0, pri = 0, sec = 0, load = 0, steam = 0, relief = false, cav = 0, shake = 0 }
  if not (M and S and o) then return c end
  local P = math.max(0, o.P or 0)
  local warm = clamp(((o.Tf or 288) - 300) / 400, 0, 1)
  c.hum = clamp(0.12 * warm + 0.88 * math.sqrt(math.min(1.2, P) / 1.2), 0, 1)
  local y = S.y or {}
  c.pri = clamp(y[20] or 0, 0, 1.2)
  c.sec = clamp(y[21] or 0, 0, 1.2)
  local rated = (M.turb_kwe or 100) * 1000
  c.load = clamp((o.Pe or 0) / math.max(1, rated), 0, 1.2)
  local tsat = M.tsat or 618
  local margin = tsat - (o.Tp or 288)
  c.steam = clamp((25 - margin) / 25, 0, 1)
  c.relief = (o.Qboil or 0) > 0.002 * (M.Pr or 1) or (S.melt == true)
  if c.relief then c.steam = 1 end
  c.cav = (c.pri > 0.2) and clamp((12 - margin) / 12, 0, 1) or 0
  local tripTf = RXC.trip_Tf or 1250
  c.shake = clamp(((o.Tf or 0) - (tripTf - 150)) / 250, 0, 1)
  if c.relief then c.shake = math.max(c.shake, 0.5) end
  c.shake = math.max(c.shake, 0.6 * c.cav)
  return c
end
-- The loops to play: the n candidates { k, gain } loudest at the crew (gain:
-- volume over distance), ties by key. → set k → true
function pickLoops(cands, n)
  table.sort(cands, function(a, b) if a.gain ~= b.gain then return a.gain > b.gain end return tostring(a.k) < tostring(b.k) end)
  local keep = {}
  for i = 1, math.min(n, #cands) do if cands[i].gain > 0.001 then keep[cands[i].k] = true end end
  return keep
end
-- an alarm kind's sound: the klaxon for a warning that empties a room or a
-- core, the bell for air and fire and a caution
function alarmKindOf(kind, level)
  if kind == "depress" or (kind == "reactor" and (level or 2) >= 2) then return "klaxon" end
  return "bell"
end

-- ── alarms ──────────────────────────────────────────────────────────────────
local AL = {}            -- key → alarm
local LV = {}            -- sid → the highest level standing
local poll_t = -10
function alarms() return AL end
function alarmLevel(sid) return LV[sid] end
local function blog(sid, k, txt) local BL = ref("base_log"); if BL and BL.add then pcall(BL.add, sid, k, txt) end end
local function stop_snd(h) if type(h) == "table" or type(h) == "userdata" then pcall(function() h:stop() end) end end
-- raise or refresh alarm `key`: a = { sid, kind, level, text, uid }
function raise(key, a)
  local e = AL[key]
  if not e then
    e = { key = key, t0 = now() }
    AL[key] = e
    if a.text then blog(a.sid, "alarm", string.format("ALARM %s", tostring(a.text))) end
  end
  e.sid, e.kind, e.level, e.text, e.uid = a.sid, a.kind or "fire", a.level or 2, a.text, a.uid or e.uid
  e.seen = now()
  return e
end
function clear(key)
  local e = AL[key]
  if not e then return end
  stop_snd(e.snd)
  AL[key] = nil
end
-- SILENCE: the sound of the alarms of structure sid standing now (nil: every
-- one). They stay on the boards and the beacons stay lit. → n silenced
function silence(sid, by)
  local n = 0
  for _, e in pairs(AL) do
    if (sid == nil or e.sid == sid) and not e.silenced then
      e.silenced = true
      stop_snd(e.snd); e.snd = nil
      n = n + 1
    end
  end
  if n > 0 then
    if audio and audio.play then pcall(audio.play, SND.silence, { track = "UI", volume = 0.45 }) end
    if sid then blog(sid, "alarm", string.format("%d alarm%s silenced%s", n, n == 1 and "" or "s", by == "hand" and " by hand" or "")) end
  end
  lastSilence = { sid = sid, n = n, t = now() }
  return n
end
function standing(sid)
  local n, loud = 0, 0
  for _, e in pairs(AL) do if e.sid == sid then n = n + 1; if not e.silenced then loud = loud + 1 end end end
  return n, loud
end

-- the piece a room's alarm sounds from: the door it vents through, else its first door
local function room_piece(sid, rid, cause)
  local RA = ref("room_air")
  local s = RA and RA.state and RA.state(sid)
  local r = s and s.R and s.R.byId and s.R.byId[rid]
  if not r then return nil end
  local best = nil
  for _, u in ipairs(r.doors or {}) do
    local d = s.R.doors[u]
    if not best then best = u end
    if cause and d and d.label and tostring(cause):find(d.label, 1, true) then best = u end
  end
  if not best then
    for _, L in ipairs(s.life or {}) do if L.rid == rid then best = L.uid break end end
  end
  return best
end
local function poll_alarms()
  local t = now()
  local seen = {}
  local RA = ref("room_air")
  if RA and RA.alarms then
    for k, al in pairs(RA.alarms()) do
      local key = "dp:" .. tostring(k)
      seen[key] = true
      raise(key, { sid = al.sid, kind = "depress", level = 2, uid = room_piece(al.sid, al.rid, al.cause),
        text = string.format("DEPRESSURISATION Room %s: %s", tostring(al.rid), tostring(al.cause or "a leak")) })
    end
  end
  if RA and RA.airAlarms then
    for _, al in ipairs(RA.airAlarms()) do
      local key = "air:" .. tostring(al.sid) .. ":" .. tostring(al.rid)
      seen[key] = true
      raise(key, { sid = al.sid, kind = "air", level = 1, uid = room_piece(al.sid, al.rid),
        text = string.format("AIR Room %s: %s", tostring(al.rid), tostring(al.why or "unbreathable")) })
    end
  end
  local RP, R = ref("reactor_plant"), ref("reactor")
  if RP and RP.plants and R and R.alarms then
    for k, e in pairs(RP.plants()) do
      if e.M and e.S and e.o then
        local ok, A = pcall(R.alarms, e.M, e.S, e.o)
        local lv, txt = 0, nil
        for _, a in ipairs(ok and A or {}) do
          -- (PROTECTION BYPASSED alone is a state the crew chose, not an alarm to sound)
          if not tostring(a[1]):find("BYPASSED", 1, true) and a[2] > lv then lv, txt = a[2], a[1] end
        end
        if lv > 0 then
          local key = "rx:" .. tostring(k) .. ":" .. lv
          seen[key] = true
          raise(key, { sid = e.sid, kind = "reactor", level = lv, uid = e.uid, text = "REACTOR " .. tostring(txt) })
        end
      end
    end
  end
  for key, e in pairs(AL) do
    -- (a script's own alarm stays until it clears it, or 10 s without a refresh)
    local mine = key:match("^dp:") or key:match("^air:") or key:match("^rx:")
    if (mine and not seen[key]) or (not mine and t - (e.seen or 0) > 10) then clear(key) end
  end
  LV = {}
  for _, e in pairs(AL) do LV[e.sid] = math.max(LV[e.sid] or 0, e.level or 1) end
end
-- the alarms' sound: the nearest MAX_ALARM_SND not silenced, on their pieces
local function alarm_sound(a)
  local ST = ref("structures")
  if not ST then return end
  local cands = {}
  for key, e in pairs(AL) do
    local n = (not e.silenced) and e.uid and ST.nodeOf and ST.nodeOf(e.sid, e.uid) or nil
    local d = 1e9
    if valid(n) and a then
      local w = n.worldPos
      d = math.sqrt((w.x - a.x) ^ 2 + (w.y - a.y) ^ 2 + (w.z - a.z) ^ 2)
    end
    e.node_ = n
    cands[#cands + 1] = { k = key, gain = (d < ALARM_R) and (1 - d / ALARM_R) * (e.level or 1) or 0 }
  end
  local keep = pickLoops(cands, MAX_ALARM_SND)
  for key, e in pairs(AL) do
    if keep[key] then
      if not e.snd and audio and audio.play then
        local path = SND[alarmKindOf(e.kind, e.level)]
        local ok, h = pcall(audio.play, path, e.node_, { loop = true, minDistance = 3, maxDistance = ALARM_R, track = "SFX",
          volume = (e.level or 1) >= 2 and 0.75 or 0.55 })
        e.snd = ok and h or nil
      end
    elseif e.snd then stop_snd(e.snd); e.snd = nil end
  end
end

-- ── machinery ───────────────────────────────────────────────────────────────
local EM = {}            -- sid → { ver, list = { { uid, kind, px, py, pz } }, b }
local LOOPS = {}         -- "sid:uid:slot" → { h, path }
local STRESS = {}        -- "sid:uid" → { kind → { v, t } }
local scan_t, st_ver = -10, nil
local shake_amt = 0
function emitters() return EM end
function loops() return LOOPS end
-- (a script, a scenario's hook) piece (sid, uid) is under stress of `kind`
-- ("bearing": a pump's bearing going, 0..1); held `ttl` s (10) unless renewed
function stress(sid, uid, kind, v, ttl)
  local k = tostring(sid) .. ":" .. tostring(uid)
  STRESS[k] = STRESS[k] or {}
  STRESS[k][kind or "bearing"] = { v = clamp(tonumber(v) or 0, 0, 1), t = now() + (ttl or 10) }
end
local function stress_of(sid, uid, kind)
  local s = STRESS[tostring(sid) .. ":" .. tostring(uid)]
  local e = s and s[kind]
  if e and now() <= e.t then return e.v end
  return 0
end
local function defs(id) local pb = ref("parts_base"); return pb and pb.partInfo(id) or nil end
local function kind_of(d)
  if not d then return nil end
  if d.nuclear and d.nuclear.role == "vessel" then return "core" end
  if d.turbine then return "turbine" end
  if d.press then return "press" end
  if d.reject and d.reject.kind == "tower" then return "tower" end
  if d.pump then return "pump" end
  if d.life and not d.life.store and not d.life.receiver then return "life" end
  if d.it and d.it.m then
    if d.it.m == "crusher" then return "crusher" end
    if d.it.m == "furnace" or d.it.m == "kiln" then return "furnace" end
    if d.it.m == "electrolyser" then return "electro" end
    return "mill"
  end
  if d.it and d.it.kind == "fab" then return "mill" end
  return nil
end
local function build_emitters(rec)
  local ST = ref("structures")
  local list = {}
  for _, p in ipairs(rec.bp or {}) do
    local d = defs(p.id)
    local k = kind_of(d)
    if k and ST and ST.partPose then
      local x, y, z = ST.partPose(rec, p, 0)
      list[#list + 1] = { uid = p.uid, kind = k, px = x, py = y, pz = z, top = (d.box and d.box[4]) or 1.5 }
    end
  end
  return list
end
-- the reactor plant a piece is part of, and its role there
local function plant_role(sid, uid)
  local RP = ref("reactor_plant")
  if not (RP and RP.plants) then return nil end
  for _, e in pairs(RP.plants()) do
    if e.sid == sid and e.pl then
      if e.uid == uid then return e, "core" end
      for _, pu in ipairs(e.pl.pri and e.pl.pri.pumps or {}) do if pu.uid == uid then return e, "pri" end end
      for _, pu in ipairs(e.pl.sec and e.pl.sec.pumps or {}) do if pu.uid == uid then return e, "sec" end end
      if e.pl.pri and e.pl.pri.press and e.pl.pri.press.uid == uid then return e, "press" end
      if e.M and e.M.turb_uid == uid then return e, "turbine" end
      for _, r in ipairs(e.pl.sec and e.pl.sec.rejects or {}) do if r.uid == uid then return e, "tower" end end
    end
  end
  return nil
end
local cues_cache = {}
local function cues(e)
  local c = cues_cache[e.key]
  if c and c.t == now() then return c.c end
  local R = ref("reactor")
  local M = e.M
  if M and not M.turb_kwe and M.turb_uid then
    local ST = ref("structures")
    local p = ST and ST.getPart and ST.getPart(e.sid, M.turb_uid)
    local d = p and defs(p.id)
    M.turb_kwe = d and d.turbine and d.turbine.kwe or 100
  end
  local cc = reactorCues(M, e.S, e.o, R and R.RX)
  cues_cache[e.key] = { t = now(), c = cc }
  return cc
end
-- one emitter's sound now: → { { slot, path, vol, pitch, r } … }, cues
local function voice(sid, em)
  local out = {}
  local function add(slot, path, vol, pitch, r) if vol > 0.01 then out[#out + 1] = { slot = slot, path = path, vol = vol, pitch = pitch or 1, r = r or 30 } end end
  local e, role = plant_role(sid, em.uid)
  local c = e and cues(e)
  local ST = ref("structures")
  local part = ST and ST.getPart and ST.getPart(sid, em.uid)
  local askew = part and part.wr
  if role == "core" then
    add("a", SND.hum, 0.18 + 0.55 * c.hum, 0.92 + 0.12 * c.hum, 30)
    return out, c, role
  elseif role == "pri" or role == "sec" then
    local on = e.pumpsOn[em.uid] ~= false
    local f = role == "pri" and c.pri or c.sec
    if not on then f = f * 0.6 end
    add("a", role == "pri" and SND.whine or SND.motor, 0.6 * math.min(1, f), 0.6 + 0.4 * math.min(1.1, f), 28)
    local rat = math.max(stress_of(sid, em.uid, "bearing"), (role == "pri") and c.cav or 0, (askew and f > 0.1) and 0.8 or 0)
    if f > 0.05 then add("b", SND.rattle, 0.75 * rat * math.min(1, f + 0.3), 0.85 + 0.3 * f, 24) end
    return out, c, role
  elseif role == "turbine" then
    local on = e.turbOn ~= false
    add("a", SND.turbine, on and (0.12 + 0.6 * math.min(1, c.load)) or 0, 0.75 + 0.35 * math.min(1.1, c.load), 35)
    return out, c, role
  elseif role == "press" then
    add("a", SND.steam, 0.75 * c.steam, 0.9 + 0.2 * c.steam, 26)
    return out, c, role
  elseif role == "tower" then
    add("a", SND.fan, (e.towerOn ~= false) and 0.4 or 0, 1.0, 30)
    return out, c, role
  end
  -- not a plant's: a machine by its owner's draw
  local RA, RF, FN = ref("room_air"), ref("refinery"), ref("fluid_net")
  if em.kind == "life" then
    local on = RA and RA.machineOn and RA.machineOn(sid, em.uid)
    local s = RA and RA.state and RA.state(sid)
    add("a", SND.fan, (on and s and s.pow) and 0.28 or 0, 1.15, 14)
  elseif em.kind == "pump" then
    local kw = FN and FN.gridAux and FN.gridAux(sid, em.uid) or 0
    add("a", SND.motor, kw > 0 and 0.4 or 0, 1.05, 18)
    if kw > 0 then
      local rat = math.max(stress_of(sid, em.uid, "bearing"), askew and 0.8 or 0)
      add("b", SND.rattle, 0.7 * rat, 1.0, 20)
    end
  elseif em.kind == "crusher" or em.kind == "furnace" or em.kind == "mill" or em.kind == "electro" then
    local busy = RF and RF.isBusy and RF.isBusy(sid, em.uid)
    local run = RF and RF.isRun and RF.isRun(sid, em.uid)
    local path = (em.kind == "crusher" and SND.crusher) or (em.kind == "furnace" and SND.furnace) or (em.kind == "electro" and SND.hum) or SND.motor
    add("a", path, busy and 0.55 or ((run and em.kind == "furnace") and 0.2 or 0), em.kind == "electro" and 1.2 or 1.0, 30)
    if askew and busy then add("b", SND.rattle, 0.6, 0.9, 22) end
    return out, { busy = busy }, em.kind
  end
  return out, nil, em.kind
end

local function crew_rel(b)
  local a = find and find("Astronaut")
  if not (valid(a) and b) then return nil end
  return a.x - b.x, a.y - b.y, a.z - b.z, a
end
local puff_t = {}
local relief_t = {}
-- a puff off the top of piece node n (`top` m up its axis: the structure's up)
local function puff(key, n, up, sc, inten, top)
  local w = n.worldPos
  local V = ref("vfx")
  local ux, uy, uz = up.x, up.y, up.z
  local h = (top or 1.2) + 0.1
  if V and V.emit then pcall(V.emit, key, w.x + ux * h, w.y + uy * h, w.z + uz * h, { normal = vec3(ux, uy, uz), scale = sc, intensity = inten, dust = key == "MachineDust" })
  elseif spawnEffect then pcall(spawnEffect, key, vec3(w.x, w.y, w.z), {}) end
  lastPuff = { key = key, t = now() }
end
GAUGE_R = 7.0
local gauge, gauge_new = nil, nil
local function scan_machinery()
  local ST = ref("structures")
  if not (ST and ST.list) then return end
  local t = now()
  if ST.version ~= st_ver then
    st_ver = ST.version
    for sid in pairs(EM) do EM[sid].ver = nil end
  end
  local cands, wants = {}, {}
  local shake = 0
  local nearN, nem = 0, 0
  local bodies = {}
  for _, rec in ipairs(ST.list()) do
    local b = bodies[rec.b]
    if b == nil then b = (space and space.body and space.body(rec.b)) or false; bodies[rec.b] = b end
    local cx, cy, cz, a = crew_rel(b or nil)
    if cx and (cx - rec.x) ^ 2 + (cy - rec.y) ^ 2 + (cz - rec.z) ^ 2 < (NEAR_R + 40) ^ 2 then
      local E = EM[rec.id]
      if not E or E.ver == nil then E = { ver = st_ver, list = build_emitters(rec) }; EM[rec.id] = E end
      nearN = nearN + 1
      for _, em in ipairs(E.list) do
        local d = math.sqrt((cx - em.px) ^ 2 + (cy - em.py) ^ 2 + (cz - em.pz) ^ 2)
        if d < NEAR_R then
          nem = nem + 1
          local vs, c, role = voice(rec.id, em)
          for _, v in ipairs(vs) do
            local k = tostring(rec.id) .. ":" .. tostring(em.uid) .. ":" .. v.slot
            if d < v.r then
              cands[#cands + 1] = { k = k, gain = v.vol * (1 - d / v.r) }
              wants[k] = { sid = rec.id, uid = em.uid, v = v }
            end
          end
          -- the stress you can see and feel, close to it
          local n = (d < PUFF_R) and ST.nodeOf and ST.nodeOf(rec.id, em.uid) or nil
          if valid(n) and c then
            local key = tostring(rec.id) .. ":" .. tostring(em.uid)
            local _, _, _, up = ST.partPose(rec, { x = 0, y = 0, z = 0 }, 0)
            if role == "press" and c.steam > 0.05 and t - (puff_t[key] or -10) > (c.relief and 0.25 or (1.4 - c.steam)) then
              puff_t[key] = t
              puff("SteamJet", n, up, c.relief and 1.4 or (0.5 + 0.6 * c.steam), c.steam, em.top)
            end
            if role == "press" and c.relief and t - (relief_t[key] or -10) > 3.5 and audio and audio.play then
              relief_t[key] = t
              pcall(audio.play, SND.relief, n, { maxDistance = 45, minDistance = 3, track = "SFX", volume = 0.8 })
            end
            if role == "crusher" and c.busy and t - (puff_t[key] or -10) > 1.2 then
              puff_t[key] = t
              puff("MachineDust", n, up, 0.9, 0.6, em.top)
            end
            if role == "core" and c.shake > 0 and d < SHAKE_R then shake = math.max(shake, c.shake * (1 - d / SHAKE_R)) end
            if role == "core" and d < GAUGE_R and (not gauge_new or d < gauge_new.d) then
              local e = plant_role(rec.id, em.uid)
              gauge_new = { sid = rec.id, uid = em.uid, e = e, d = d }
            end
            if (role == "pri" or role == "sec" or em.kind == "pump") and d < 6 then
              local rat = math.max(stress_of(rec.id, em.uid, "bearing"), role == "pri" and c.cav or 0)
              if rat > 0.3 then shake = math.max(shake, 0.25 * rat * (1 - d / 6)) end
            end
          end
        end
      end
    end
  end
  PROF.near, PROF.emitters = nearN, nem
  gauge, gauge_new = gauge_new, nil
  local keep = pickLoops(cands, MAX_LOOPS)
  for k, L in pairs(LOOPS) do
    if not keep[k] then stop_snd(L.h); LOOPS[k] = nil end
  end
  local n = 0
  for k in pairs(keep) do
    local w = wants[k]
    local L = LOOPS[k]
    if L and L.path ~= w.v.path then stop_snd(L.h); LOOPS[k] = nil; L = nil end
    if not L then
      local node = ST.nodeOf and ST.nodeOf(w.sid, w.uid)
      if valid(node) and audio and audio.play then
        local ok, h = pcall(audio.play, w.v.path, node, { loop = true, minDistance = 2, maxDistance = w.v.r, track = "SFX", volume = w.v.vol, pitch = w.v.pitch })
        if ok and h then LOOPS[k] = { h = h, path = w.v.path, vol = w.v.vol, pitch = w.v.pitch } end
      end
    else
      if math.abs((L.vol or 0) - w.v.vol) > 0.02 and L.h.setVolume then pcall(L.h.setVolume, L.h, w.v.vol); L.vol = w.v.vol end
      if math.abs((L.pitch or 1) - w.v.pitch) > 0.01 and L.h.setPitch then pcall(L.h.setPitch, L.h, w.v.pitch); L.pitch = w.v.pitch end
    end
    if LOOPS[k] then n = n + 1 end
  end
  PROF.loops = n
  shake_amt = shake
end

-- ── the menu: silence the alarms from any piece of an alarmed structure ─────
local function provider(t, ctx)
  if not (t and t.node) then return {} end
  local ST = ref("structures")
  if not (ST and ST.partOfNode) then return {} end
  local rec = ST.partOfNode(t.node)
  if not rec then return {} end
  local n, loud = standing(rec.id)
  if n == 0 then return {} end
  local out = {}
  out[#out + 1] = { id = "pa_alarms", type = "info", label = "Alarms", group = "Alarms",
    value = function()
      local l = {}
      for _, e in pairs(AL) do if e.sid == rec.id then l[#l + 1] = tostring(e.text) .. (e.silenced and " (silenced)" or "") end end
      table.sort(l)
      return table.concat(l, " · ")
    end, warn = function() return true end }
  if loud > 0 then
    out[#out + 1] = { id = "pa_silence", type = "action", label = string.format("Silence the alarm%s (%d)", loud == 1 and "" or "s", loud), group = "Alarms",
      act = function() silence(rec.id, "hand"); return true end }
  end
  return out
end
-- the terminal's rows (terminal_pages' ALARMS and STATUS pages)
function terminalRows(sids, col)
  local rows = {}
  local any, loud = false, 0
  for _, e in pairs(AL) do
    local mine = false
    for _, s in ipairs(sids or {}) do if s == e.sid then mine = true end end
    if mine then
      any = true
      if not e.silenced then loud = loud + 1 end
      rows[#rows + 1] = { type = "line", col = col, level = (e.level or 1) >= 2 and 2 or 1,
        text = tostring(e.text) .. (e.silenced and "  · SILENCED" or "") }
    end
  end
  if any then
    rows[#rows + 1] = { id = "pa_silence", type = "action", col = col, label = loud > 0 and string.format("SILENCE ALARMS (%d)", loud) or "ALARMS SILENCED",
      enabled = function() return loud > 0 end, why = function() return "every alarm standing is silenced" end,
      act = function() local n = 0; for _, s in ipairs(sids or {}) do n = n + silence(s, "hand") end; return n > 0, n == 0 and "nothing to silence" or nil end }
  end
  return rows, any
end

-- ── driver ──────────────────────────────────────────────────────────────────
local reg_on = false
function start(node)
  if findScripts then
    local all = findScripts("plant_av")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  AL, LV, EM, LOOPS, STRESS = {}, {}, {}, {}, {}
  scan_t, poll_t, st_ver, shake_amt = -10, -10, nil, 0
end
function update(node, dt)
  if not reg_on then
    local reg = ref("context_registry")
    if reg and reg.register then reg.register("prop", provider, { id = "plant_av", order = 4 }); reg_on = true end
  end
  local t = now()
  if t - poll_t >= POLL then
    poll_t = t
    local w0 = wall()
    poll_alarms()
    local a = find and find("Astronaut")
    if next(AL) then alarm_sound(valid(a) and a or nil) end
    if w0 then PROF.poll_ms = (wall() - w0) * 1000 end
  end
  if t - scan_t >= ((params and params.scan) or 0.25) then
    scan_t = t
    local w0 = wall()
    scan_machinery()
    if w0 then PROF.scan_ms = (wall() - w0) * 1000 end
  end
  -- the floor shaking under a stressed vessel or a rattling pump (per frame,
  -- only while there is any)
  if shake_amt > 0.01 then
    local pc = ref("planet_camera")
    if pc and pc.addShake then pcall(pc.addShake, shake_amt * 0.9 * (dt or 0)) end
  end
end
-- ── the vessel's gauges (lateUpdate: drawn poses, after the camera) ─────────
-- Two dials on the face of the nearest Reactor Vessel Base you look at, within
-- GAUGE_R: PRIMARY (its temperature from 300 K to boiling, the last 25 K red)
-- and POWER (0–120 %, red past the trip), a needle each; their numbers within
-- 4 m. Read at the vessel, not only at the console: the reactor room tells you
-- how it is.
lastGauge = nil
-- the vessel's drawn frame, read once a frame (four toWorld calls), every
-- gauge point placed from it by arithmetic (a frame's worth of the same pose)
local NO, NX, NY, NZ = nil, nil, nil, nil
local function NF(x, y, z)
  return { x = NO.x + NX.x * x + NY.x * y + NZ.x * z, y = NO.y + NX.y * x + NY.y * y + NZ.y * z, z = NO.z + NX.z * x + NY.z * y + NZ.z * z }
end
local function read_frame(n)
  local ok, o = pcall(n.toWorld, n, vec3(0, 0, 0))
  local ok1, a = pcall(n.toWorld, n, vec3(1, 0, 0))
  local ok2, b = pcall(n.toWorld, n, vec3(0, 1, 0))
  local ok3, c = pcall(n.toWorld, n, vec3(0, 0, 1))
  if not (ok and ok1 and ok2 and ok3 and o and a and b and c) then return false end
  NO = o
  NX = { x = a.x - o.x, y = a.y - o.y, z = a.z - o.z }
  NY = { x = b.x - o.x, y = b.y - o.y, z = b.z - o.z }
  NZ = { x = c.x - o.x, y = c.y - o.y, z = c.z - o.z }
  return true
end
local function face_of(n, cam)
  -- the vessel's four sides: the one most toward the camera
  local best, bd = nil, -1e9
  for _, f in ipairs({ { 1.26, 0, 1, 0 }, { -1.26, 0, -1, 0 }, { 0, 1.51, 0, 1 }, { 0, -1.51, 0, -1 } }) do
    local ok, c = true, NF(f[1], 0.62, f[2])
    local ok2, o = true, NF(f[1] + f[3], 0.62, f[2] + f[4])
    if ok and ok2 and c and o then
      local nx, ny, nz = o.x - c.x, o.y - c.y, o.z - c.z
      local dd = (cam.x - c.x) * nx + (cam.y - c.y) * ny + (cam.z - c.z) * nz
      if dd > bd then best, bd = f, dd end
    end
  end
  return best, bd
end
local function dial(n, f, off, frac, red, label, value, cam)
  -- the face's frame: centre, its right (along the face) and up, in the piece's frame
  local rx, rz = -f[4], f[3]
  local cx, cz = f[1] + f[3] * 0.012 + rx * off, f[2] + f[4] * 0.012 + rz * off
  -- (o: metres proud of the dial: the scale and the needle stand 1.5 cm off it,
  -- or the depth test hides them in the disc)
  local function W(u, v, o)
    o = o or 0
    return NF(cx + rx * u + f[3] * o, 0.62 + v, cz + rz * u + f[4] * o)
  end
  local c, nrm = W(0, 0), nil
  local ok, o = true, NF(cx + f[3], 0.62, cz + f[4])
  if not (c and ok and o) then return end
  local nx, ny, nz = o.x - c.x, o.y - c.y, o.z - c.z
  local R = 0.16
  draw.disc(c.x, c.y, c.z, nx, ny, nz, 0, R, 0.05, 0.05, 0.045, 1)
  draw.disc(c.x, c.y, c.z, nx, ny, nz, R, R + 0.015, 0.55, 0.52, 0.45, 1)
  -- the scale: 240° from lower left to lower right, ticks, the red zone
  local function at(t, r) local a = math.rad(210 - 240 * t); return W(math.cos(a) * r, math.sin(a) * r, 0.015) end
  for i = 0, 10 do
    local t = i / 10
    local p1, p2 = at(t, R * 0.82), at(t, R * 0.96)
    local hot = t >= red
    if p1 and p2 then draw.line(p1.x, p1.y, p1.z, p2.x, p2.y, p2.z, hot and 1 or 0.85, hot and 0.2 or 0.82, hot and 0.12 or 0.7) end
  end
  for i = 0, 7 do
    local t0 = red + (1 - red) * i / 8
    local t1 = red + (1 - red) * (i + 1) / 8
    local p1, p2 = at(t0, R * 0.9), at(t1, R * 0.9)
    if p1 and p2 then draw.line(p1.x, p1.y, p1.z, p2.x, p2.y, p2.z, 1, 0.18, 0.1) end
  end
  local tip = at(math.max(0, math.min(1, frac)), R * 0.8)
  local hub = W(0, 0, 0.015)
  if tip then draw.line(hub.x, hub.y, hub.z, tip.x, tip.y, tip.z, 1.0, frac >= red and 0.3 or 0.92, frac >= red and 0.2 or 0.75) end
  local d2 = (cam.x - c.x) ^ 2 + (cam.y - c.y) ^ 2 + (cam.z - c.z) ^ 2
  if d2 < 16 and camera and camera.worldToScreen then
    local lp = W(0, -R - 0.06)
    local sx, sy, _d, vis
    if lp then sx, sy, _d, vis = camera.worldToScreen(lp.x, lp.y, lp.z) end
    if sx and vis ~= false then
      local hot = frac >= red
      draw.text(sx, sy, label .. "  " .. value, 12, hot and 1 or 0.86, hot and 0.35 or 0.82, hot and 0.25 or 0.7, 1, "center")
    end
  end
end
local function late_gauges()
  local g = gauge
  if not (g and g.e and g.e.o and g.e.M) then return end
  local ST = ref("structures")
  local n = ST and ST.nodeOf and ST.nodeOf(g.sid, g.uid)
  if not valid(n) then return end
  local pc = ref("planet_camera")
  if not (pc and pc.cam_x) then return end
  local cam = { x = pc.cam_x, y = pc.cam_y, z = pc.cam_z }
  if not read_frame(n) then return end
  local f, dd = face_of(n, cam)
  if not f or dd <= 0 then return end
  local o, M = g.e.o, g.e.M
  local tsat = M.tsat or 618
  local Tp = o.Tp or 288
  local tf = (Tp - 300) / math.max(1, tsat - 300)
  local redT = 1 - 25 / math.max(1, tsat - 300)
  local P = o.P or 0
  draw.depthTest(true)
  dial(n, f, -0.45, tf, redT, "PRIMARY", string.format("%.0f K · %.0f to boil", Tp, tsat - Tp), cam)
  dial(n, f, 0.45, P / 1.2, 1.1 / 1.2, "POWER", string.format("%.0f %%", P * 100), cam)
  draw.depthTest(false)
  lastGauge = { sid = g.sid, uid = g.uid, Tp = Tp, P = P, t = now() }
end
local pc_late = nil
local function after_camera(node, dt, fn)
  if not (pc_late and pc_late.valid) then pc_late = findScript("planet_camera", { quiet = true }) end
  if pc_late and pc_late.valid and pc_late.deferLate then pc_late.deferLate(node, dt, fn) else fn(node, dt) end
end
function lateUpdate(node, dt)
  if gauge and draw and draw.disc then after_camera(node, dt, late_gauges) end
end
function onDestroy()
  for _, L in pairs(LOOPS) do stop_snd(L.h) end
  for _, e in pairs(AL) do stop_snd(e.snd) end
end
