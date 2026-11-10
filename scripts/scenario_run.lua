-- SCENARIO RUN — the scene half of a scripted mission (work/scenarios/PLAN.md
-- §1, docs/scenarios.md). On the ScenarioLib node (prefabs/ScenarioLib), which
-- game_manager spawns in every system scene as it does CrewLib; scenario.lua
-- (the pure rulebook) rides the same node.
--
-- IDLE unless the slot is `scn` and holds `g_scenario` (one boolean a frame).
-- Then, in order:
--   loading    the world comes in (game_manager); the curtain is held for us
--   staging    the start table is staged ONCE through the owning scripts'
--              published functions (company, research, crew, inventory,
--              structures, salvage, deployables, survey, vessel_spawner),
--              spread over frames by a coroutine; `scn.staged`
--   briefing   physics paused while a UI (FW-B) shows the brief; go() ends it
--   running    the open steps' goals and the fail list are evaluated at
--              EVAL_HZ on the agency clock; a step whose goals all read true
--              is latched into `scn.done` with its time; beats fire on the
--              edges (on_enter, on_done, on_fail, on_start)
--   done | failed   the score, the medal, the profile; the debrief (FW-B)
--   freeplay   the world stays, the runner stands down
--
-- RULES. Nothing here keeps a world point past the frame it was read in:
-- marks, crew spots and camera pivots are body-relative and placed against
-- this frame's space.body() each time (docs/positions-and-frames.md). Nothing
-- runs per frame while idle; while running, the evaluation is 4 Hz and the
-- beat queue is a few comparisons. Only `scn.*` and `g_scenario*` keys are
-- written here; everything else goes through its owner's API.
--
-- THE INTERFACE (FW-B, SC-1, SC-2 code against it; API.md in work/scn_fwa):
--   state() → the snapshot table (see build_state)    allows(what) → bool
--   go() wantBriefing(on) restart() retry() continueFreeplay() toMenu()
--   completeStep() hint() fail(why) finish()
--   listen(key, fn)  "ops" "sound" "alarm" "phase" "teach"
--   teachNow() → teach, step     goalKind(kind, def)     marks() → { name → {body,x,y,z} }
--   holdCurtain() (game_manager asks)   dumpStart() → path (Shift+F12)
--   overlay (bool, Ctrl+F10: the goal readings drawn on screen)

defaults = {
  --@range 1 20
  eval_hz = 4,
  --@range 0 60 --@units s
  curtain_max = 25.0,   -- the most the reveal waits for staging past game_manager's own hold
}

version = 0
overlay = false
lastStage = nil        -- what staging wrote, for probes: { ms, records = { … }, errors = { … } }
PROF = { evals = 0, eval_ms = 0, stage_ms = 0 }

local SLOT = "scn"
local active = nil     -- nil = not decided yet; false = idle this scene
local sc = nil         -- the scenario table
local R = nil          -- the rulebook (scenario.lua)
local phase = nil
local co_stage = nil
local listeners = {}
local mem = {}         -- [stepId .. ":" .. goal i] / ["fail:" .. i] → goal memory
local readings = {}    -- [stepIndex] = { { label, met, reading } … }
local fail_read = {}
local open_seen = {}   -- stepId → true once its on_enter fired
local step_t0 = {}     -- stepId → agency t when it opened
local last_eval = -1
local beatq = {}       -- queued beats { b = beat, src }
local beat_busy = nil  -- { kind, t1 } blocking the queue (a wait, a camera)
local cam = nil        -- the camera beat in progress
local want_brief = false
local st_cache, st_ver = nil, -1
local hint_shown = {}  -- stepId → 1 | 2
local progress_t = {}  -- stepId → agency t of the last goal change
local met_count = {}   -- stepId → goals met last eval
local outcome_t = nil
local fail_text = nil
local node_ref = nil
local stats_final = nil

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function bump() version = version + 1 end
local function now() return time or 0 end
local function wall() return (app and app.wallClock) and app.wallClock() or os.clock() end
local function agency_now()
  local dp = ref("deployables")
  if dp and dp.agencyClock then local ok, t = pcall(dp.agencyClock); if ok and type(t) == "number" then return t end end
  return tonumber(save and save.get and save.get("agency.clock")) or 0
end
local function say_log(s) if log then log("scenario: " .. s) end end
local function rulebook()
  if R and R.valid ~= false then return R end
  R = ref("scenario")
  if not R and loadfile and setfenv then
    local f = loadfile("scripts/scenario.lua") or loadfile("solar/scripts/scenario.lua")
    if f then local e = setmetatable({}, { __index = _G }); setfenv(f, e); f(); R = e end
  end
  return R
end
-- a game scenario's hooks: its script (sc.hooks, a kind) on its prefab,
-- spawned once; under luajit scenario.load put the table on sc._hooks
local hooks_spawned = false
function hooks_of()
  if not (sc and sc.hooks) then return nil end
  if sc._hooks then return sc._hooks end
  local h = findScript and findScript(sc.hooks) or nil
  if h and h.valid ~= false then return h end
  if not hooks_spawned and spawn and vec3 then
    hooks_spawned = true
    pcall(spawn, sc.hooksPrefab or sc.hooks, vec3(0, 0, 0))
  end
  return nil
end
local function sget(k) return save.get(k) end
local function sset(k, v) save.set(k, v) end

-- ── refs and points (body-relative, re-read every use) ──────────────────────
local function home_name() return save.get("base.body") end
local function body_name(n)
  if n == nil or n == "home" then return home_name() end
  if n == "moon" then
    local h = space.body(home_name() or "")
    if not h then return nil end
    local best, bd
    for _, b in ipairs(space.bodies() or {}) do
      if b.name ~= h.name then
        local d = math.sqrt((b.x - h.x) ^ 2 + (b.y - h.y) ^ 2 + (b.z - h.z) ^ 2)
        if (h.soi or -1) > 0 and d < h.soi and (not bd or d < bd) then best, bd = b, d end
      end
    end
    return best and best.name or nil
  end
  return n
end
bodyName = body_name

local function crew_ids() local t = sget("scn.crew"); return type(t) == "table" and t or {} end
local function member_id(name)
  if type(name) == "number" then return name end
  if name == nil then local C = ref("crew"); return C and C.activeId and C.activeId() end
  local id = crew_ids()[name]
  if id then return id end
  local C = ref("crew")
  for _, r in ipairs((C and C.roster) and C.roster() or {}) do if r.name == name then return r.id end end
  return nil
end
local function node_rel(n)
  if not (n and n.valid ~= false) then return nil end
  local x, y, z = n.x, n.y, n.z
  if n.worldPos then local p = n.worldPos; if p and p.x then x, y, z = p.x, p.y, p.z end end
  local d = space.dominant(x, y, z)
  local b = d and space.body(d)
  if not b then return nil end
  return { body = d, x = x - b.x, y = y - b.y, z = z - b.z }
end
local function vessels() return findScripts and findScripts("vessel_controller") or {} end
local function piloted() for _, v in ipairs(vessels()) do if v.piloting then return v end end return nil end
local function struct_id(name)
  local t = sget("scn.structs")
  if type(t) == "table" and t[name] then
    local ST = ref("structures")
    if ST and ST.get(t[name]) then return t[name] end
  end
  local ST = ref("structures")
  for _, r in ipairs((ST and ST.list) and ST.list() or {}) do if r.n == name then return r.id end end
  return nil
end

-- A ref → { body, x, y, z } body-relative now, or nil
local function pos_of(r)
  local R_ = rulebook()
  local k, n = R_.parseRef(r)
  if not k and type(r) == "string" then k, n = "crew", r end
  if k == "base" then
    local bx, by, bz, bn = sget("base.x"), sget("base.y"), sget("base.z"), sget("base.body")
    if type(bx) ~= "number" then return nil end
    return { body = bn, x = bx, y = by, z = bz }
  elseif k == "mark" then
    local m = (sget("scn.marks") or {})[n]
    return m and { body = m.b, x = m.x, y = m.y, z = m.z } or nil
  elseif k == "struct" then
    local sid = struct_id(n)
    local ST = ref("structures")
    local rec = sid and ST and ST.get(sid)
    return rec and { body = rec.b, x = rec.x, y = rec.y, z = rec.z } or nil
  elseif k == "craft" then
    for _, v in ipairs(vessels()) do
      if v.craftName == n and not (v.isLost and v.isLost()) then return node_rel(v.node) end
    end
    return nil
  elseif k == "body" then
    return { body = body_name(n), x = 0, y = 0, z = 0 }
  elseif k == "crew" then
    local id = member_id(n)
    local C = ref("crew")
    if not (id and C) then return nil end
    local pw = ref("planet_walker")
    if id == (C.activeId and C.activeId()) and pw and pw.onFoot then return node_rel(find("Astronaut")) end
    local rec = C.get(id)
    if not rec then return nil end
    if rec.status == "afoot" and rec.body and rec.x then return { body = rec.body, x = rec.x, y = rec.y, z = rec.z } end
    local v = C.craftOf and C.craftOf(id)
    if v then return node_rel(v.node) end
    if id == (C.activeId and C.activeId()) then return node_rel(find("Astronaut")) end
    return nil
  end
  return nil
end
posOf = pos_of
-- world point of a ref, this frame (for drawing; never kept)
function pointOf(r)
  local p = pos_of(r)
  local b = p and space.body(p.body or "")
  if not b then return nil end
  return b.x + p.x, b.y + p.y, b.z + p.z
end
function marks() return sget("scn.marks") or {} end

-- ── the world adapter (what the goal kinds read) ────────────────────────────
local W = {}
W.pos = pos_of
W.structId = struct_id
function W.rooms(sid)
  local RA = ref("room_air")
  local Rr = RA and RA.roomsOf and RA.roomsOf(sid)
  return Rr and Rr.rooms or {}
end
function W.roomOf(who)
  local RA = ref("room_air")
  if not RA then return nil end
  local C = ref("crew")
  local id = member_id(who)
  if C and id == (C.activeId and C.activeId()) then return RA.crewRoom() end
  local p = id and pos_of("crew:" .. (who or ""))
  local b = p and space.body(p.body or "")
  if not b then return nil end
  local _, _, r, sid = RA.airAt(b.x + p.x, b.y + p.y, b.z + p.z)
  return sid, r and r.id
end
function W.roomAir(sid, rid) local RA = ref("room_air"); return RA and RA.airOf and RA.airOf(sid, rid) end
function W.airlockCycles(sid) local RA = ref("room_air"); return RA and RA.cyclesOf and RA.cyclesOf(sid) or nil end
function W.helmetOff(who)
  local C, pw, su = ref("crew"), ref("planet_walker"), ref("suit")
  local id = member_id(who)
  if not (C and su and su.helmetOn) or id ~= (C.activeId and C.activeId()) then return nil end
  if pw and pw.onFoot == false then return nil end
  return su.helmetOn() == false
end
function W.grid(sid)
  local BG = ref("base_grid")
  local g = BG and BG.gridOfStruct and BG.gridOfStruct(sid)
  local s = g and BG.status(g.id)
  return s and { supply = s.supply, need = s.need, powered = s.powered, stored = s.stored } or nil
end
function W.parts(sid) local ST = ref("structures"); local r = ST and ST.get(sid); return r and r.bp or {} end
function W.partsNear(r, rad)
  local p = pos_of(r)
  local ST = ref("structures")
  if not (p and ST) then return {} end
  local out = {}
  for _, e in ipairs(ST.partsNear(p.body, p.x, p.y, p.z, rad)) do out[#out + 1] = e.part end
  return out
end
function W.flagOn(b) local dep = ref("deployables"); return dep and dep.hasFlagOn and dep.hasFlagOn(body_name(b)) == true end
function W.crewDead(who)
  local C = ref("crew")
  if not C then return false end
  if who then local r = C.get(member_id(who)); return r ~= nil and r.status == "dead" end
  for _, id in pairs(crew_ids()) do local r = C.get(id); if r and r.status == "dead" then return true end end
  return false
end
function W.suitO2(who)
  local C = ref("crew")
  local id = member_id(who)
  if not (C and id) then return nil end
  if C.alerts then local ok, a = pcall(C.alerts, id); if ok and a and a.o2 then return a.o2 end end
  local r = C.get(id)
  return r and r.o2
end
function W.craftAlive(name)
  for _, v in ipairs(vessels()) do
    if v.craftName == name then return not (v.isLost and v.isLost()) end
  end
  local FO = ref("flight_ops")
  for _, e in ipairs((FO and FO.fleetList) and FO.fleetList() or {}) do if e.name == name then return true end end
  return false
end
function W.mission(g)
  local MI = ref("missions")
  if not (MI and MI.goalNow) then return false end
  local gg = g
  if g.body and (g.body == "home" or g.body == "moon") then gg = {}; for k, v in pairs(g) do gg[k] = v end; gg.body = body_name(g.body) end
  local v = piloted()
  if v then return MI.goalNow(gg, v, assembly.info(v.node)) == true end
  return MI.goalNow(gg, { node = node_ref }, nil) == true
end
-- the reactor of structure sid (reactor_plant): its derived readouts
function W.reactor(sid)
  local RP = ref("reactor_plant")
  local e = RP and RP.plantOfPart and RP.plantOfPart(sid)
  if not (e and e.S) then return nil end
  local o = e.o or {}
  local aux = 0
  for _, v in pairs(e.aux or {}) do aux = aux + v end
  local RX = ref("reactor")
  local I = RX and RX.IDX or {}
  return { power = o.P or 0, fuelK = o.Tf, primaryK = o.Tp, flow = o.mpe, scrammed = e.S.scram == true, melted = e.S.melt == true,
           netKW = (o.Pe or 0) / 1000 - aux, key = RP.keyOf and RP.keyOf(e.sid, e.uid),
           -- (flagship) the rest of what the console shows
           genKW = (o.Pe or 0) / 1000, inventory = I.inv and e.S.y[I.inv] or 1, damage = I.dmg and e.S.y[I.dmg] or 0,
           protection = e.S.prot ~= false, setpoint = e.S.set, mode = e.S.mode, cause = e.S.cause,
           turbine = e.turbOn ~= false, cooldown = e.S.cooldown == true, breaks = #(e.breaks or {}), coreKW = (o.Qcore or 0) / 1000,
           rods = o.x, steamK = o.Ts, condK = o.Tk }
end
W.now = agency_now
worldAdapter = W

-- ── listeners and beats ─────────────────────────────────────────────────────
-- THE BEAT ENGINE. One queue of beats, run in order: a beat that takes time
-- (a line being read, a choice, a shot, a wait) blocks it until it is done.
-- `run` puts a named sequence's beats at the FRONT (inline); a sequence whose
-- first beat is `{ cutscene = true }` runs as a cutscene: the keys are held
-- (game_manager.inputOwner = "scenario", planet_walker.steer(0, 0)), the
-- interface is hidden, bars top and bottom, Esc held a second skips it (what
-- changes the world still happens, at once). Every camera pivot is a ref
-- re-read against this frame's body (docs/positions-and-frames.md).
function listen(key, fn) listeners[key] = fn end
local function emit(key, ...)
  local f = listeners[key]
  if f then local ok, err = pcall(f, ...); if not ok then say_log("listener " .. key .. ": " .. tostring(err)) end; return true end
  return false
end

local line = nil       -- the dialogue line on screen { who, name, tag, color, portrait, text, t0, secs }
local choice = nil     -- the open choice { who, name, prompt, options, opts, t0, timeout, default }
local cut = nil        -- the cutscene running { id, prev, held }
local alarm_on = false
local cs_seq = 0
local esc_t = nil

local function vars() local v = sget("scn.vars"); if type(v) ~= "table" then v = {}; for k, x in pairs((sc and sc.vars) or {}) do v[k] = x end; sset("scn.vars", v) end return v end
function var(name) return vars()[name] end
function setVar(name, v) local t = vars(); t[name] = v; sset("scn.vars", t); bump() end
W.var = function(name) return var(name) end

-- who → { name, tag, color, portrait } (the cast, a crew name, or Ops)
local function speaker(who)
  who = who or "ops"
  local c = sc and sc.cast and sc.cast[who]
  if c then return { who = who, name = c.name or who, tag = c.tag, color = c.color, portrait = c.portrait and (sc._dir .. c.portrait) or nil } end
  if who == "ops" then return { who = "ops", name = "Ops", tag = "OPS", color = { 0.55, 0.85, 1.0 } } end
  if sc and sc.cast then
    for k, cc in pairs(sc.cast) do if cc.crew == who then return { who = k, name = cc.name or who, tag = cc.tag, color = cc.color, portrait = cc.portrait and (sc._dir .. cc.portrait) or nil } end end
  end
  local C = ref("crew")
  local id = member_id(who)
  local r = C and id and C.get(id)
  return { who = who, name = r and r.name or tostring(who), tag = r and r.role and string.upper(r.role) or nil }
end
local function chirp()
  if audio and audio.play then pcall(audio.play, "audio/sfx/crew_chime.ogg", { track = "UI", volume = 0.25 }) end
end
local function show_line(who, text, secs)
  local s = speaker(who)
  s.text = tostring(text)
  s.t0 = now()
  s.secs = secs or (1.5 + 0.06 * #s.text)
  line = s
  say_log(s.name .. ": " .. s.text)
  bump()
  if not emit("say", s) then
    emit("ops", s.text, s.name)
    chirp()
  end
  return s
end
local function ops_line(text, who) return show_line(who or "ops", text) end
opsLine = ops_line
function lineDone() if beat_busy and beat_busy.kind == "line" then beat_busy = nil end; line = nil; bump() end

local function queue_beats(list, src, front, cs)
  local add = {}
  for _, b in ipairs(list or {}) do add[#add + 1] = { b = b, src = src, cs = cs } end
  if front then
    for i = #add, 1, -1 do table.insert(beatq, 1, add[i]) end
  else
    for _, e in ipairs(add) do beatq[#beatq + 1] = e end
  end
end
local function run_seq(name, front, inherit)
  local seq = sc and sc.sequences and sc.sequences[name]
  if not seq then say_log("no sequence " .. tostring(name)); return end
  local cs = inherit
  if not cs and seq[1] and seq[1].cutscene then cs_seq = cs_seq + 1; cs = cs_seq end
  queue_beats(seq, name, front ~= false, cs)
end
function runSequence(name) run_seq(name, false) end

-- The ground under a direction of `body` (radius) | nil: terrain's field.
local function ground_of(b)
  return function(dir)
    local r = b.radius + 400
    for _ = 1, 400 do
      local d = terrain.query(b.x + dir.x * r, b.y + dir.y * r, b.z + dir.z * r)
      if not d then return nil end
      if d < 0.05 then return r end
      r = r - math.max(d * 0.8, 0.1)
      if r < b.radius * 0.5 then return nil end
    end
    return r
  end
end
groundOf = ground_of

-- An `at` ref + offset → a body-relative ground point with its frame, now.
local function resolve_at(at, off, yaw)
  local p = pos_of(at or "base")
  local b = p and space.body(p.body or "")
  if not b then return nil, "no " .. tostring(at) end
  local g = rulebook().offsetPoint({ x = p.x, y = p.y, z = p.z }, off, ground_of(b), yaw)
  g.body = p.body
  return g
end
resolveAt = resolve_at

-- a ref (+ an offset in its ground frame, metres right/up/front) → world, NOW
local function world_at(r, off, lift)
  local p = pos_of(r)
  local b = p and space.body(p.body or "")
  if not b then return nil end
  local F = rulebook().groundFrame(p.x, p.y, p.z)
  off = off or {}
  local o1, o2, o3 = off[1] or 0, (off[2] or 0) + (lift or 0), off[3] or 0
  return b.x + p.x + F.rx * o1 + F.ux * o2 + F.fx * o3, b.y + p.y + F.ry * o1 + F.uy * o2 + F.fy * o3,
         b.z + p.z + F.rz * o1 + F.uz * o2 + F.fz * o3, F
end

-- THE SHOT: the camera point, the point looked at and up, all from refs read
-- this frame. orbit = ref (dist, height, turn° over secs) | from/to (dolly)
-- + look | look + from.
local function shot_fn(c, t0, secs)
  return function()
    local k = math.max(0, math.min(1, (now() - t0) / math.max(secs, 0.01)))
    local e = k * k * (3 - 2 * k)
    if c.orbit then
      local px, py, pz, F = world_at(c.orbit, nil, c.lift or 1.5)
      if not px then return nil end
      local dist, h = c.dist or 18, c.height or (c.dist or 18) * 0.45
      local a = math.rad((c.start or 0) + (c.turn or 60) * k)
      local dx = F.fx * math.cos(a) + F.rx * math.sin(a)
      local dy = F.fy * math.cos(a) + F.ry * math.sin(a)
      local dz = F.fz * math.cos(a) + F.rz * math.sin(a)
      return px - dx * dist + F.ux * h, py - dy * dist + F.uy * h, pz - dz * dist + F.uz * h, px, py, pz, F.ux, F.uy, F.uz
    end
    local ax, ay, az, F = world_at(c.from, c.offset or { 0, 2, 0 })
    if not ax then return nil end
    local cx, cy, cz = ax, ay, az
    if c.to then
      local bx, by, bz = world_at(c.to, c.toOffset or c.offset or { 0, 2, 0 })
      if bx then cx, cy, cz = ax + (bx - ax) * e, ay + (by - ay) * e, az + (bz - az) * e end
    end
    local lx, ly, lz = world_at(c.look or c.to or c.from, c.lookOffset, 1.2)
    if not lx then return nil end
    return cx, cy, cz, lx, ly, lz, F.ux, F.uy, F.uz
  end
end
local function camera_start(c)
  local pc = ref("planet_camera")
  if not (pc and pc.setShot) then return false end
  if not pos_of(c.orbit or c.from or c.look) then return false end
  local secs = c.secs or 5
  if c.look and not c.from and not c.orbit then c = { from = c.look, offset = c.offset or { 0, 3, -10 }, look = c.look, secs = secs } end
  pc.setCinematic(true)
  local gm = ref("game_manager")
  local prev = cam and cam.prev
  if not cam then prev = gm and gm.inputOwner end
  if gm and gm.inputOwner == nil then gm.inputOwner = "scenario" end
  pc.setShot(shot_fn(c, now(), secs), cam and 0.6 or (c.ease or 1.0))
  cam = { t1 = now() + secs, prev = prev }
  return true
end
local function camera_end()
  if not cam then return end
  local pc, gm = ref("planet_camera"), ref("game_manager")
  if pc then pcall(pc.clearShot, 1.0); if not cut then pcall(pc.setCinematic, false) end end
  if gm and gm.inputOwner == "scenario" and not cut then gm.inputOwner = cam.prev end
  cam = nil
end
-- a camera beat waits while the controlled craft is in the air (never in a cutscene)
local function camera_quiet()
  local v = piloted()
  if not v then return true end
  local info = assembly.info(v.node)
  return info ~= nil and (info.grounded or info.anchored) == true
end

local function cut_begin(id)
  if cut then cut.id = id return end
  local gm, pc = ref("game_manager"), ref("planet_camera")
  cut = { id = id, prev = gm and gm.inputOwner }
  if gm then gm.inputOwner = "scenario" end
  if pc and pc.setCinematic then pcall(pc.setCinematic, true) end
  emit("cutscene", true)
  bump()
end
local function cut_end()
  if not cut then return end
  local gm, pc, pw = ref("game_manager"), ref("planet_camera"), ref("planet_walker")
  local prev = cut.prev
  cut = nil
  if cam then camera_end() end
  if pc then pcall(pc.clearShot, 0.8); pcall(pc.setCinematic, false) end
  if gm and gm.inputOwner == "scenario" then gm.inputOwner = prev end
  if pw and pw.steer then pw.steer(nil) end
  esc_t = nil
  emit("cutscene", false)
  bump()
end

local function give(t)
  local inv = ref("inventory")
  if not inv then return end
  local id = member_id(t.who)
  local cid = id and ("crew:" .. tostring(id)) or "astro"
  if t.item then inv.addItem(cid, t.item, t.n or 1, { force = true }) end
  if t.part then inv.addItem(cid, "part:" .. t.part, t.n or 1, { force = true }) end
  if t.mat then
    local M = ref("materials")
    local per = (M and M.kg and M.kg(t.mat)) or 1
    inv.add(cid, t.mat, math.max(1, math.floor((t.kg or per) / per + 0.5)))
  end
end
local function set_funds(target)
  local co = ref("company")
  if not co then return end
  local b = co.balance()
  if target > b then co.earn(target - b, "scenario budget") elseif target < b then co.spend(b - target, "scenario budget") end
end

-- a piece of a structure: { struct, part = "<id prefix>" | uid = n } → sid, uid, part
local function piece_of(t)
  local sid = struct_id(tostring(t.struct or ""):gsub("^struct:", ""))
  local ST = ref("structures")
  local r = sid and ST and ST.get(sid)
  if not r then return nil end
  for _, p in ipairs(r.bp or {}) do
    if (t.uid and p.uid == t.uid) or (not t.uid and t.part and (p.id == t.part or tostring(p.id):sub(1, #t.part + 1) == t.part .. ".")) then
      if not (t.skipKnocked and p.wr) then return sid, p.uid, p end
    end
  end
  return nil
end
pieceOf = piece_of
local function machine_power(sid, uid, on)
  local RP, RA = ref("reactor_plant"), ref("room_air")
  if RP and RP.plantOfPart and RP.plantOfPart(sid, uid) and RP.setPump then pcall(RP.setPump, sid, uid, on) end
  if RA and RA.setMachine then pcall(RA.setMachine, sid, uid, on) end
end
local function knock(t)
  local sid, uid, p = piece_of({ struct = t.struct, part = t.part, uid = t.uid, skipKnocked = true })
  if not sid then say_log("knock: no piece " .. tostring(t.part or t.uid) .. " in " .. tostring(t.struct)); return end
  local ST = ref("structures")
  local r = ST.get(sid)
  -- the X8 look (a Repair Kit's "repair" puts it back: ruins.repairPiece)
  p.wr = true
  p.wrl, p.wrs = t.label, t.secs     -- (flagship) the repair's words and seconds
  p.o_p = p.o_p or p.pitch or 0
  p.pitch = (p.pitch or 0) + (t.lean or 0.12)
  ST.put(r)
  if ST.respawnPart then pcall(ST.respawnPart, sid, uid) end
  machine_power(sid, uid, false)
  say_log(string.format("knock: %s #%s in %s", tostring(p.id), tostring(uid), tostring(t.struct)))
  emit("knock", sid, uid, p)
end
W.pieceOk = function(t) local sid, uid, p = piece_of(t); if not sid then return nil end return not p.wr end

-- (flagship) a `reactor` beat: { struct, scram, reset, startup = set, setpoint,
-- protection, turbine, cooldown, pump = { part|uid, on } } on the plant of struct
function reactor_beat(v)
  local RP = ref("reactor_plant")
  local sid = struct_id(tostring(v.struct or ""):gsub("^struct:", ""))
  local e = sid and RP and RP.plantOfPart and RP.plantOfPart(sid)
  if not e then say_log("reactor: no plant in " .. tostring(v.struct)); return end
  local key = RP.keyOf(e.sid, e.uid)
  if v.reset then RP.resetTrip(key) end
  if v.scram then RP.scram(key) end
  if v.startup then RP.startUp(key, v.startup) end
  if v.setpoint then RP.setPoint(key, v.setpoint) end
  if v.protection ~= nil then RP.setProtection(key, v.protection) end
  if v.turbine ~= nil then RP.setTurbine(key, v.turbine) end
  if v.cooldown ~= nil then RP.setCooldown(key, v.cooldown) end
end

-- beats that change the world: a skipped cutscene still runs these
WORLD_BEATS = { reactor = true, knock = true, state = true, power = true, var = true, add = true, spawn = true, remove = true, walk = true,
                give = true, funds = true, unlock = true, mark = true, ["goto"] = true, objective = true, branch = true,
                run = true, alarm = true, fail = true, done = true, hook = true }
local stage_one        -- set by the staging section: (kind, entry, out)
local walks = {}       -- id → { to = ref, offset, t1 }

local function apply_choice(opt)
  if not opt then return end
  for k, v in pairs(opt.var or {}) do setVar(k, v) end
  local cs = cut and cut.id or nil
  if opt.run then run_seq(opt.run, true, cs) end
  if opt.beats then queue_beats(opt.beats, "choice", true, cs) end
  if opt.step then gotoStep(opt.step) end
end
function choose(i)
  if not choice then return false end
  local opt = choice.opts[i]
  if not opt then return false end
  say_log("choice: " .. tostring(opt.text))
  choice = nil
  if beat_busy and beat_busy.kind == "choice" then beat_busy = nil end
  apply_choice(opt)
  bump()
  return true
end

local function test(v, t)
  if t.is ~= nil then return (v == true) == (t.is == true) end
  if t.eq ~= nil and v ~= t.eq then return false end
  if t.ne ~= nil and v == t.ne then return false end
  if t.lt ~= nil and not (type(v) == "number" and v < t.lt) then return false end
  if t.gt ~= nil and not (type(v) == "number" and v > t.gt) then return false end
  if t.lte ~= nil and not (type(v) == "number" and v <= t.lte) then return false end
  if t.gte ~= nil and not (type(v) == "number" and v >= t.gte) then return false end
  return true
end

local hooks_api
local function run_beat(b, e)
  local k, v = next(b)
  local in_cut = e and e.cs ~= nil
  if k == "cutscene" then if e and e.cs then cut_begin(e.cs) end
  elseif k == "ops" then local s = ops_line(v); beat_busy = { kind = "line", t1 = now() + s.secs }
  elseif k == "say" then
    local s = show_line(v.who or v[1], v.text or v[2], v.secs)
    if v.wait ~= false then beat_busy = { kind = "line", t1 = now() + s.secs } end
  elseif k == "choice" then
    local s = speaker(v.who)
    local texts = {}
    for i, o in ipairs(v.options or {}) do texts[i] = o.text end
    choice = { who = s.who, name = s.name, color = s.color, prompt = v.prompt, options = texts, opts = v.options or {},
               t0 = now(), timeout = v.timeout, default = v.default or 1 }
    say_log("choice up: " .. tostring(v.prompt))
    bump()
    emit("choice", choice)
    beat_busy = { kind = "choice", t1 = v.timeout and (now() + v.timeout) or math.huge }
  elseif k == "run" then run_seq(v, true, e and e.cs)
  elseif k == "caption" then
    local bc = ref("big_caption")
    if bc and bc.show then bc.show(v.title or v[1] or "", v.sub or v[2] or "", v.secs or v[3] or 4.0) end
  elseif k == "camera" or k == "shot" then
    if not in_cut and not camera_quiet() then return "later" end
    if camera_start(v) and v.wait ~= false then beat_busy = { kind = "shot", t1 = cam.t1 } end
  elseif k == "wait" then beat_busy = { kind = "wait", t1 = now() + v }
  elseif k == "warp" then local wc = ref("warp_chip"); if wc and wc.request then wc.request(v) elseif space.warp then space.warp(v) end
  elseif k == "var" then for n, x in pairs(v) do setVar(n, x) end
  elseif k == "add" then for n, x in pairs(v) do setVar(n, (tonumber(var(n)) or 0) + x) end
  elseif k == "branch" then
    local ok = test(var(v.var), v)
    local cs = e and e.cs
    if ok then
      if v.run then run_seq(v.run, true, cs) end
      if v.beats then queue_beats(v.beats, "branch", true, cs) end
    else
      if v["else"] then run_seq(v["else"], true, cs) end
      if v.elseBeats then queue_beats(v.elseBeats, "branch", true, cs) end
    end
  elseif k == "goto" then gotoStep(v)
  elseif k == "objective" then
    local o = sget("scn.obj") or {}
    o[v.step or "_"] = v.text
    sset("scn.obj", o)
    bump()
  elseif k == "knock" then knock(v)
  elseif k == "reactor" then reactor_beat(v)
  elseif k == "state" then
    local sid, uid = piece_of(v)
    local ST = ref("structures")
    if sid and ST.setPartState then
      local cur = ST.partState(sid, uid) or {}
      for n, x in pairs(v.st or {}) do cur[n] = x end
      ST.setPartState(sid, uid, cur)
    end
  elseif k == "power" then local sid, uid = piece_of(v); if sid then machine_power(sid, uid, v.on ~= false) end
  elseif k == "spawn" then
    local out = {}
    for kind_, entry in pairs(v) do if stage_one then stage_one(kind_, entry, out) end end
    for _, l in ipairs(out) do say_log("spawned " .. l) end
  elseif k == "remove" then
    local sid = struct_id(tostring(v):gsub("^struct:", ""))
    local ST = ref("structures")
    if sid and ST then ST.remove(sid) end
  elseif k == "walk" then
    local id = member_id(v.who)
    if id then walks[id] = { to = v.to, offset = v.offset, t1 = now() + (v.secs or 20), who = v.who } end
  elseif k == "give" then give(v)
  elseif k == "funds" then local co = ref("company"); if co then if v >= 0 then co.earn(v, "scenario") else co.spend(-v, "scenario") end end
  elseif k == "unlock" then local rs = ref("research"); if rs and rs.grant then rs.grant(v, "scenario") end
  elseif k == "mark" then
    local m = sget("scn.marks") or {}
    if v.at then
      local g = resolve_at(v.at, v.offset)
      if g then m[v.name] = { b = g.body, x = g.x, y = g.y, z = g.z, show = v.show ~= false } end
    elseif m[v.name] then m[v.name].show = v.show ~= false end
    sset("scn.marks", m)
  elseif k == "fail" then fail(v)
  elseif k == "done" then finish()
  elseif k == "sound" then if not emit("sound", v) and audio and audio.play then pcall(audio.play, v, { track = "UI", volume = 0.6 }) end
  elseif k == "alarm" then
    alarm_on = v == true
    bump()
    if not emit("alarm", alarm_on) and alarm_on and audio and audio.play then pcall(audio.play, "audio/sfx/crew_alarm.ogg", { track = "UI", volume = 0.5 }) end
  elseif k == "hook" then
    local H = hooks_of()
    local f = H and H[v]
    if type(f) == "function" then local ok, err = pcall(f, hooks_api()); if not ok then say_log("hook " .. v .. ": " .. tostring(err)) end end
  end
  return nil
end
runBeat = run_beat

-- a walking crew member: a CrewBody is set down at the mark when the walk
-- ends (crew_body has no path steering yet); the controlled one, in a
-- cutscene, is steered there by planet_walker.steer
local function walks_tick()
  for id, w in pairs(walks) do
    local C = ref("crew")
    local p = pos_of(w.to)
    local b = p and space.body(p.body or "")
    if not (C and b) then walks[id] = nil
    else
      local x, y, z = world_at(w.to, w.offset)
      local active_ = C.activeId and C.activeId() == id
      if active_ and cut then
        local a = find("Astronaut")
        local pw, pc = ref("planet_walker"), ref("planet_camera")
        local d = a and math.sqrt((a.x - x) ^ 2 + (a.y - y) ^ 2 + (a.z - z) ^ 2) or 0
        if d < 1.2 or now() > w.t1 then
          if pw and pw.steer then pw.steer(0, 0) end
          walks[id] = nil
        elseif pw and pw.steer and pc and pc.fwd_x then
          -- forward/right in the camera's frame toward the mark
          local fx, fy, fz = pc.flat_x or pc.fwd_x, pc.flat_y or pc.fwd_y, pc.flat_z or pc.fwd_z
          local dx, dy, dz = (x - a.x) / d, (y - a.y) / d, (z - a.z) / d
          local F = rulebook().groundFrame(a.x - b.x, a.y - b.y, a.z - b.z)
          local rx, ry, rz = fy * F.uz - fz * F.uy, fz * F.ux - fx * F.uz, fx * F.uy - fy * F.ux
          local f = dx * fx + dy * fy + dz * fz
          local s = dx * rx + dy * ry + dz * rz
          local m = math.max(math.abs(f), math.abs(s), 1e-3)
          pw.steer(f / m, s / m)
        end
      elseif not active_ and now() > w.t1 - (w.instant and w.t1 or 0) then
        local l = math.sqrt((x - b.x) ^ 2 + (y - b.y) ^ 2 + (z - b.z) ^ 2)
        if C.setDown then C.setDown(id, b.x + (x - b.x) * (l + 0.5) / l, b.y + (y - b.y) * (l + 0.5) / l, b.z + (z - b.z) * (l + 0.5) / l) end
        walks[id] = nil
      end
    end
  end
end

-- Esc held a second: the cutscene ends; what changes the world happens now
function skipCutscene()
  if not cut then return false end
  local id = cut.id
  local keep = {}
  local run_now = {}
  for _, e in ipairs(beatq) do
    if e.cs == id then
      local k = next(e.b)
      if WORLD_BEATS[k] then run_now[#run_now + 1] = e end
    else keep[#keep + 1] = e end
  end
  beatq = keep
  beat_busy = nil
  line = nil
  if choice then local c = choice; choice = nil; apply_choice(c.opts[c.default or 1]) end
  for _, e in ipairs(run_now) do
    local k, v = next(e.b)
    if k == "walk" then local id2 = member_id(v.who); if id2 then walks[id2] = { to = v.to, offset = v.offset, t1 = now(), instant = true } end
    else run_beat(e.b, { cs = nil }) end
  end
  for id2, w in pairs(walks) do w.t1 = now(); w.instant = true end
  say_log("cutscene skipped")
  lastSkipped = now()
  cut_end()
  return true
end

local function cut_alive()
  if not cut then return false end
  for _, e in ipairs(beatq) do if e.cs == cut.id then return true end end
  -- (a shot that ran out only holds its last frame while more of the
  -- cutscene is queued: with nothing left and nothing in progress, it ends)
  return beat_busy ~= nil
end

local function beats_tick()
  if cam and now() >= cam.t1 and not (beat_busy and beat_busy.kind == "shot") then
    -- a shot that ran out holds its last frame inside a cutscene until the next one or the end
    if not cut then camera_end() end
  end
  if line and not (beat_busy and beat_busy.kind == "line") and now() > line.t0 + line.secs + 0.5 then line = nil; bump() end
  if beat_busy then
    if beat_busy.kind == "choice" and now() >= beat_busy.t1 and choice then choose(choice.default or 1) end
    if beat_busy and now() < beat_busy.t1 then return end
    if beat_busy and beat_busy.kind == "line" then line = nil; bump() end
    beat_busy = nil
  end
  local n = 0
  while #beatq > 0 and not beat_busy and n < 12 do
    local e = beatq[1]
    -- a cutscene begins at its first beat
    if e.cs and (not cut or cut.id ~= e.cs) then cut_begin(e.cs) end
    if not e.cs and cut and not beat_busy then cut_end() end
    table.remove(beatq, 1)
    if run_beat(e.b, e) == "later" then table.insert(beatq, 1, e); return end
    n = n + 1
  end
  if cut and not cut_alive() then cut_end() end
end

-- the keys a cutscene holds (and Esc held to skip it); the built-in choice keys
local function input_tick()
  if cut then
    local pw = ref("planet_walker")
    local walking = false
    local C = ref("crew")
    for id in pairs(walks) do if C and C.activeId and C.activeId() == id then walking = true end end
    if pw and pw.steer and not walking then pw.steer(0, 0) end
    if input and input.key and input.key("escape") then
      esc_t = esc_t or now()
      if now() - esc_t >= 1.0 then skipCutscene() end
    else esc_t = nil end
  end
  if choice and not listeners.choice and input and input.pressed then
    for i = 1, math.min(4, #choice.opts) do if input.pressed(tostring(i)) then choose(i) break end end
  end
end

-- what the screen shows without a UI listening: the bars, the line, the choice, the alarm edge
local function draw_builtin()
  if not (draw and draw.rect and draw.text and camera and camera.screenSize) then return end
  local sw, sh = camera.screenSize()
  if not sw or sw <= 0 then return end
  local k = sh / 1080
  if cut and not listeners.cutscene then
    local bar = sh * 0.11
    draw.rect(0, 0, sw, bar, 0, 0, 0, 1)
    draw.rect(0, sh - bar, sw, bar, 0, 0, 0, 1)
    if esc_t then
      local f = math.min(1, (now() - esc_t) / 1.0)
      draw.rect(sw - 260 * k, sh - bar * 0.5 - 4 * k, 200 * k * f, 8 * k, 0.9, 0.9, 0.85, 0.9)
    else
      draw.text(sw - 40 * k, sh - bar * 0.5 - 9 * k, "hold ESC to skip", 16 * k, 0.6, 0.6, 0.58, 0.7, "right")
    end
  end
  if line and not listeners.say then
    local c = line.color or { 0.9, 0.88, 0.8 }
    local y = cut and (sh * 0.89 - 110 * k) or (sh - 250 * k)
    local w = math.min(sw * 0.62, 1200 * k)
    local x = (sw - w) / 2
    draw.rect(x, y, w, 96 * k, 0.02, 0.03, 0.04, 0.78, 8 * k)
    local nm = string.upper(line.name or "")
    draw.text(x + 22 * k, y + 14 * k, nm .. ((line.tag and line.tag ~= nm) and ("  ·  " .. line.tag) or ""), 17 * k, c[1], c[2], c[3], 1)
    local shown = line.text:sub(1, math.floor((now() - line.t0) * 40) + 1)
    draw.text(x + 22 * k, y + 44 * k, shown, 22 * k, 0.94, 0.93, 0.88, 1)
  end
  if choice and not listeners.choice then
    local w = math.min(sw * 0.5, 900 * k)
    local x = (sw - w) / 2
    local y = sh * 0.52
    local c = choice.color or { 0.55, 0.85, 1.0 }
    draw.rect(x, y, w, (70 + 38 * #choice.options) * k, 0.02, 0.03, 0.04, 0.82, 8 * k)
    draw.text(x + 22 * k, y + 16 * k, string.upper(choice.name or "") .. ": " .. tostring(choice.prompt or ""), 19 * k, c[1], c[2], c[3], 1)
    for i, t in ipairs(choice.options) do
      draw.text(x + 34 * k, y + (54 + (i - 1) * 38) * k, string.format("%d   %s", i, t), 20 * k, 0.94, 0.93, 0.88, 1)
    end
  end
  if alarm_on and not listeners.alarm then
    local a = 0.18 + 0.14 * math.sin(now() * 7)
    local t = 10 * k
    draw.rect(0, 0, sw, t, 0.9, 0.1, 0.05, a)
    draw.rect(0, sh - t, sw, t, 0.9, 0.1, 0.05, a)
    draw.rect(0, 0, t, sh, 0.9, 0.1, 0.05, a)
    draw.rect(sw - t, 0, t, sh, 0.9, 0.1, 0.05, a)
  end
end

-- ── staging (once, through the owners' APIs) ────────────────────────────────
local function frames(n) for _ = 1, n or 1 do coroutine.yield() end end

local function base_ctx(b)
  local bx, by, bz = sget("base.x"), sget("base.y"), sget("base.z")
  if type(bx) ~= "number" then bx, by, bz = 0, b.radius, 0 end
  local l = math.sqrt(bx * bx + by * by + bz * bz)
  local u = { x = bx / l, y = by / l, z = bz / l }
  local a = math.abs(u.y) > 0.9 and { x = 1, y = 0, z = 0 } or { x = 0, y = 1, z = 0 }
  local function cr(p, q) return { x = p.y * q.z - p.z * q.y, y = p.z * q.x - p.x * q.z, z = p.x * q.y - p.y * q.x } end
  local function un(p) local m = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z); return { x = p.x / m, y = p.y / m, z = p.z / m } end
  local t1 = un(cr(u, a))
  local t2 = un(cr(u, t1))
  local E, cl = ref("electronics"), ref("climate")
  local sun = E and E.sunOf and E.sunOf(b.x, b.y, b.z, space.bodies() or {}) or nil
  local sd = nil
  if sun then local dx, dy, dz = sun.x - b.x, sun.y - b.y, sun.z - b.z; local m = math.sqrt(dx * dx + dy * dy + dz * dz); sd = { x = dx / m, y = dy / m, z = dz / m } end
  -- nothing built at a spot: a ray down from 40 m over it (and 8 m round
  -- it) meets the ground, not a roof, a tank or a wall (the body read now)
  local function clear(dir, r)
    if not raycast then return true end
    local F = rulebook().groundFrame(dir.x, dir.y, dir.z)
    for _, o in ipairs({ { 0, 0 }, { 8, 0 }, { -8, 0 }, { 0, 8 }, { 0, -8 } }) do
      local bb = space.body(b.name) or b
      local px = dir.x * r + F.rx * o[1] + F.fx * o[2]
      local py = dir.y * r + F.ry * o[1] + F.fy * o[2]
      local pz = dir.z * r + F.rz * o[1] + F.fz * o[2]
      local ok, hit = pcall(raycast, bb.x + px + dir.x * 40, bb.y + py + dir.y * 40, bb.z + pz + dir.z * 40, -dir.x, -dir.y, -dir.z, 80)
      if ok and hit and hit.distance and hit.distance < 40 - 2.5 then return false end
    end
    return true
  end
  -- (flagship) the world's velocity round its star (the body nearest the sun
  -- point): a spot facing along it is turning into the night
  local sv = nil
  if sun then
    local best, bd = nil, math.huge
    for _, q in ipairs(space.bodies() or {}) do
      local d = (q.x - sun.x) ^ 2 + (q.y - sun.y) ^ 2 + (q.z - sun.z) ^ 2
      if d < bd then best, bd = q, d end
    end
    local vx, vy, vz = (b.vx or 0) - (best and best.vx or 0), (b.vy or 0) - (best and best.vy or 0), (b.vz or 0) - (best and best.vz or 0)
    local m = math.sqrt(vx * vx + vy * vy + vz * vz)
    if m > 1e-9 then sv = { x = vx / m, y = vy / m, z = vz / m } end
  end
  return { R = l, u = u, t1 = t1, t2 = t2, ground = ground_of(b), sun = sd, vel = sv, clear = clear,
           wet = function(dir, r)
             if not (cl and cl.isUnderwater) then return false end
             return cl.isUnderwater(b.x + dir.x * r, b.y + dir.y * r + 0.5, b.z + dir.z * r) == true
           end }
end

-- the crew: starters renamed and given roles, extras hired; the controlled
-- member placed at the site
local function stage_crew(list, out)
  local C = ref("crew")
  if not (C and list and #list > 0) then return end
  C.ensure()
  local map = crew_ids()
  local used = {}
  for _, id in pairs(map) do used[id] = true end
  local active = C.activeId()
  local function take(want_role, control)
    if control and active and not used[active] then return active end
    for _, r in ipairs(C.roster()) do
      if not used[r.id] and r.status ~= "dead" and r.id ~= active and (not want_role or r.role == want_role) then return r.id end
    end
    for _, r in ipairs(C.roster()) do
      if not used[r.id] and r.status ~= "dead" and r.id ~= active then return r.id end
    end
    local id = C.hire(1, { free = true })
    return id
  end
  for _, c in ipairs(list) do
    local id = map[c.name] or take(c.role, c.control)
    if id then
      used[id] = true
      map[c.name] = id
      C.rename(id, c.name)
      if c.role then C.patch(id, { role = c.role }) end
      local inv = ref("inventory")
      for _, it in ipairs(c.pack or {}) do
        if inv then
          if it.item then inv.addItem("crew:" .. id, it.item, it.n or 1, { force = true })
          elseif it.part then inv.addItem("crew:" .. id, "part:" .. it.part, it.n or 1, { force = true })
          elseif it.mat then
            local M = ref("materials")
            local per = (M and M.kg and M.kg(it.mat)) or 1
            inv.add("crew:" .. id, it.mat, math.max(1, math.floor((it.kg or per) / per + 0.5)))
          end
        end
      end
      out[#out + 1] = string.format("crew %s (#%d) %s", c.name, id, tostring(c.role))
    end
  end
  sset("scn.crew", map)
  -- where they stand: a siting rule → a body-relative spot, then the world
  -- point is made from it the frame it is used
  local spots = sget("scn.spots") or {}
  for _, c in ipairs(list) do
    local id = map[c.name]
    if id and c.where and not spots[c.name] then
      local bn = body_name(c.where.body)
      local b = bn and space.body(bn)
      if b and bn == home_name() then
        local spot, why = rulebook().findSpot(c.where.site or "near_base", base_ctx(b), c.where.dist)
        if spot then
          local g = rulebook().offsetPoint({ x = spot.dir.x * spot.r, y = spot.dir.y * spot.r, z = spot.dir.z * spot.r }, c.where.offset, ground_of(b))
          spots[c.name] = { b = bn, x = g.x, y = g.y, z = g.z }
          out[#out + 1] = string.format("spot %s: %s (spread %.2f m, lit %.2f)", c.name, tostring(c.where.site), spot.spread or 0, spot.lit or 0)
        else
          out[#out + 1] = "spot " .. c.name .. " failed: " .. tostring(why)
        end
      else
        out[#out + 1] = "spot " .. c.name .. ": only the home world is sited on foot (slice 1)"
      end
      frames(1)
    end
  end
  sset("scn.spots", spots)
  -- the controlled one: the Astronaut, held on the spot until the ground there answers
  for _, c in ipairs(list) do
    local id, s = map[c.name], spots[c.name]
    if id and s then
      if id == C.activeId() then
        local a = find("Astronaut")
        for k = 1, 90 do
          local b = space.body(s.b)
          if not (a and b) then break end
          local ux, uy, uz = s.x, s.y, s.z
          local l = math.sqrt(ux * ux + uy * uy + uz * uz)
          ux, uy, uz = ux / l, uy / l, uz / l
          a.x, a.y, a.z = b.x + s.x + ux * 1.0, b.y + s.y + uy * 1.0, b.z + s.z + uz * 1.0
          a.vx, a.vy, a.vz = 0, 0, 0
          local d = terrain.query(b.x + s.x, b.y + s.y, b.z + s.z)
          if k > 20 and d and d < 0.5 then break end
          coroutine.yield()
        end
      elseif C.setDown then
        local b = space.body(s.b)
        if b then
          local l = math.sqrt(s.x * s.x + s.y * s.y + s.z * s.z)
          C.setDown(id, b.x + s.x * (l + 1) / l, b.y + s.y * (l + 1) / l, b.z + s.z * (l + 1) / l)
        end
      end
    end
  end
  -- (refresh the marks that ride crew spots: `crew:<name>` at stage time is the spot)
end

local resolve_stage
-- (twice: a mark on a structure is resolved after the structures, a mark on
-- the crew before them)
local function stage_marks(t, out, last)
  local m = sget("scn.marks") or {}
  for name, e in pairs(t or {}) do
    if not m[name] then
      local g = resolve_stage(e.at, e.offset)
      if g then m[name] = { b = g.body, x = g.x, y = g.y, z = g.z, show = e.show == true }
        out[#out + 1] = "mark " .. name
      elseif last then out[#out + 1] = "mark " .. name .. " failed" end
    end
  end
  sset("scn.marks", m)
end

-- `crew:<name>` at stage time reads the staged SPOT (the walker may not have
-- set the body down yet)
local function stage_at(at)
  local k, n = rulebook().parseRef(at)
  if k == "crew" then
    local s = (sget("scn.spots") or {})[n]
    if s then return "spot", s end
  end
  return nil
end
resolve_stage = function(at, off, yaw)
  local kind_, s = stage_at(at)
  if kind_ == "spot" then
    local b = space.body(s.b)
    if not b then return nil end
    local g = rulebook().offsetPoint({ x = s.x, y = s.y, z = s.z }, off, ground_of(b), yaw)
    g.body = s.b
    return g
  end
  return resolve_at(at, off, yaw)
end

local lived_in = {}     -- structures to power and pressurise once their rooms and grid are solved
local function stage_lived_in(out)
  local RA, BG, ST = ref("room_air"), ref("base_grid"), ref("structures")
  for _, e in ipairs(lived_in) do
    if ST and ST.spawnNow then pcall(ST.spawnNow, e.sid) end
    local t1 = now() + 12
    local aired, powered = not e.air, not e.powered
    while now() < t1 and not (aired and powered) do
      if not aired and RA then
        if RA.solveNow then pcall(RA.solveNow, e.sid) end
        local n = RA.pressurise and RA.pressurise(e.sid, type(e.air) == "number" and e.air or 1.0)
        if n then aired = true; out[#out + 1] = string.format("%s: %d room(s) at 1 atm", tostring(e.name), n) end
      end
      if not powered and BG and BG.chargeFull then
        if BG.chargeFull(e.sid) then powered = true; out[#out + 1] = string.format("%s: batteries full", tostring(e.name)) end
      end
      coroutine.yield()
    end
    if not aired then out[#out + 1] = tostring(e.name) .. ": rooms never solved (no air staged)" end
    if not powered then out[#out + 1] = tostring(e.name) .. ": no grid store to charge" end
  end
  lived_in = {}
end

-- crew at their posts (`post = ref`, after the marks and structures exist)
local function stage_posts(list, out)
  local C = ref("crew")
  local map = crew_ids()
  for _, c in ipairs(list or {}) do
    local id = map[c.name]
    local g = id and c.post and resolve_stage(c.post, c.offset)
    local b = g and space.body(g.body)
    if b then
      local l = math.sqrt(g.x * g.x + g.y * g.y + g.z * g.z)
      local k = (l + 1.0) / l
      if C and id == C.activeId() then
        local a = find("Astronaut")
        for _ = 1, 30 do
          b = space.body(g.body)
          if not (a and b) then break end
          a.x, a.y, a.z = b.x + g.x * k, b.y + g.y * k, b.z + g.z * k
          a.vx, a.vy, a.vz = 0, 0, 0
          coroutine.yield()
        end
      elseif C and C.setDown then
        C.setDown(id, b.x + g.x * k, b.y + g.y * k, b.z + g.z * k)
      end
      out[#out + 1] = string.format("post %s: %s", c.name, tostring(c.post))
    end
  end
end

local function stage_structures(list, out)
  local ST, BPs = ref("structures"), ref("blueprints")
  if not (ST and BPs) then if list and #list > 0 then out[#out + 1] = "structures: no Build Kit in this scene" end return end
  local map = sget("scn.structs") or {}
  for _, s in ipairs(list or {}) do
    if not (s.name and map[s.name] and ST.get(map[s.name])) then
      local code = rulebook().readText(sc._dir .. s.bp)
      local bp, why = nil, "no file"
      if code then bp, why = BPs.decode(code) end
      local g = bp and resolve_stage(s.at or "base", s.offset, s.yaw)
      if bp and g then
        local rec = ST.recordFromPieces(bp.pieces, g.body, g, s.name or bp.name, "scenario", { t = agency_now() })
        local sid = ST.add(rec)
        if s.name then map[s.name] = sid end
        out[#out + 1] = string.format("structure %s: %d pieces as #%s", tostring(s.name), #rec.bp, tostring(sid))
        if s.powered or s.air then lived_in[#lived_in + 1] = { sid = sid, name = s.name, powered = s.powered, air = s.air } end
      else
        out[#out + 1] = string.format("structure %s failed: %s", tostring(s.name), tostring(why or "no ground"))
      end
      frames(2)
    end
  end
  sset("scn.structs", map)
end

local function stage_crates(list, out)
  local inv, SV = ref("inventory"), ref("salvage")
  if not (inv and SV) then if list and #list > 0 then out[#out + 1] = "crates: no inventory/salvage" end return end
  for i, c in ipairs(list or {}) do
    local g = resolve_stage(c.at or "base", c.offset)
    local b = g and space.body(g.body)
    if b then
      local cid = "scnstage:" .. i
      inv.setCap(cid, 1e6)
      for id, n in pairs(c.parts or {}) do inv.addItem(cid, "part:" .. id, n, { force = true }) end
      for id, n in pairs(c.items or {}) do inv.addItem(cid, id, n, { force = true }) end
      for mat, n in pairs(c.mats or {}) do inv.add(cid, mat, n) end
      local up = 2.0
      local cx, cy, cz = b.x + g.x + g.ux * up, b.y + g.y + g.uy * up, b.z + g.z + g.uz * up
      local sid = SV.drop(g.body, cx, cy, cz, nil, { from = cid, items = true, label = c.name or "Supply drop" })
      out[#out + 1] = string.format("crate %d: salvage #%s", i, tostring(sid))
    else
      out[#out + 1] = string.format("crate %d failed: no ground", i)
    end
    frames(1)
  end
end

local function stage_flags(list, out)
  local dep = ref("deployables")
  for i, f in ipairs(list or {}) do
    local g = dep and resolve_stage(f.at or "base", f.offset)
    local b = g and space.body(g.body)
    if b then
      local id = dep.place("flag", g.body, b.x + g.x, b.y + g.y, b.z + g.z, { name = f.name, ceremony = false })
      out[#out + 1] = string.format("flag %d: #%s", i, tostring(id))
    end
  end
end

local function stage_survey(list, out)
  local SVY = ref("survey")
  for _, s in ipairs(list or {}) do
    if SVY and SVY.credit then
      pcall(SVY.credit, body_name(s.body), "scenario", s.vals or s.layers or {}, s.opts)
      out[#out + 1] = "survey " .. tostring(s.body)
    end
  end
end

-- a craft: rolled out on the pad (vessel_spawner.launchNow), and for an orbit
-- start moved to its two-body state (assembly.teleport, then impulses to the
-- velocity, as tools/perf/mnvprobe does)
local function wait_secs(s) local t1 = now() + s; while now() < t1 do coroutine.yield() end end
local function stage_craft(list, out)
  local VS = ref("vessel_spawner")
  for i, c in ipairs(list or {}) do
    local v = rulebook().readJson(sc._dir .. c.file)
    local bp = v and (v.bp or v)
    local wh = c.where or {}
    if not (bp and bp.parts) then out[#out + 1] = string.format("craft %d: unreadable %s", i, tostring(c.file))
    elseif not (VS and VS.launchNow) then out[#out + 1] = "craft: no vessel spawner"
    else
      local ok, why = VS.launchNow(wh.runway and "runway" or "pad", { bp = bp, force = true })
      out[#out + 1] = string.format("craft %d (%s): rollout %s %s", i, tostring(c.file), tostring(ok), tostring(why or ""))
      local t1 = now() + 60
      while now() < t1 and VS.launchState and VS.launchState() ~= "ready" do coroutine.yield() end
      local vc = piloted()
      if vc and c.name then if vc.setCraftName then pcall(vc.setCraftName, c.name) else vc.craftName = c.name end end
      if wh.ground and vc then
        local g = resolve_stage(wh.ground, wh.offset, wh.yaw)
        local b = g and space.body(g.body)
        if b then
          if vc.releaseClamps then pcall(vc.releaseClamps) end
          wait_secs(0.2)
          local info = assembly.info(vc.node)
          b = space.body(g.body)
          local up = wh.lift or 3.0
          assembly.teleport(vc.node, vec3(b.x + g.x + g.ux * up + (info.origin.x - info.com.x), b.y + g.y + g.uy * up + (info.origin.y - info.com.y), b.z + g.z + g.uz * up + (info.origin.z - info.com.z)))
          wait_secs(0.2)
          info = assembly.info(vc.node)
          if info and info.vel then assembly.impulseAt(vc.node, vec3(-info.vel.x * info.mass, -info.vel.y * info.mass, -info.vel.z * info.mass), info.com) end
          out[#out + 1] = string.format("craft %d set down at %s", i, tostring(wh.ground))
        end
      end
      if wh.orbit and vc then
        local o = wh.orbit
        local bn = body_name(o.body)
        local b = bn and space.body(bn)
        if b then
          if vc.releaseClamps then pcall(vc.releaseClamps) end
          wait_secs(0.3)
          local r, vel = rulebook().orbitState(b.mu, { R = b.radius, alt = o.alt or b.radius * 0.3, e = o.e, inc = o.inc, lan = o.lan, argp = o.argp, nu = o.nu })
          local info = assembly.info(vc.node)
          b = space.body(bn)
          local off = { x = info.origin.x - info.com.x, y = info.origin.y - info.com.y, z = info.origin.z - info.com.z }
          assembly.teleport(vc.node, vec3(b.x + r.x + off.x, b.y + r.y + off.y, b.z + r.z + off.z))
          wait_secs(0.3)
          local gain = 1.0
          for _ = 1, 12 do
            info = assembly.info(vc.node)
            local dv = { x = vel.x - info.vel.x, y = vel.y - info.vel.y, z = vel.z - info.vel.z }
            local dl = math.sqrt(dv.x * dv.x + dv.y * dv.y + dv.z * dv.z)
            if dl < 0.5 then break end
            local v0 = info.vel
            local s = info.mass / gain
            assembly.impulseAt(vc.node, vec3(dv.x * s, dv.y * s, dv.z * s), info.com)
            wait_secs(0.5)
            local i2 = assembly.info(vc.node)
            local got = math.sqrt((i2.vel.x - v0.x) ^ 2 + (i2.vel.y - v0.y) ^ 2 + (i2.vel.z - v0.z) ^ 2)
            if got > 1e-3 then gain = math.max(0.02, math.min(5, gain * got / dl)) end
          end
          local io = assembly.info(vc.node)
          local el = space.elements and space.elements(io.origin.x, io.origin.y, io.origin.z, io.vel.x, io.vel.y, io.vel.z)
          out[#out + 1] = string.format("craft %d in orbit of %s: pe %.0f m", i, bn, el and el.periapsis and (el.periapsis - b.radius) or -1)
        end
      end
      -- `control = false`: the craft is left there and the player is on foot
      if vc and c.control == false and vc.releaseControl then pcall(vc.releaseControl) end
    end
  end
end

-- One start-like table, staged in order. (The checkpoint fallback stages a
-- step's `stage` table with this too.)
-- (flagship) PLANTS: { struct, fuel = { item, n }, power, days, scramFor (s),
-- standby = set, hold (s), protection, turbine, fill = { { uid | part, kg } } }: the channels loaded, then a
-- history run through the plant's own catch-up (as a load after an absence):
-- days at `power`, a SCRAM, scramFor s tripped, then the start-up to the
-- standby setpoint held `hold` s. The xenon, the decay heat and the trend are
-- the history's.
local function plant_skip(RP, e, secs, out)
  e.t = (e.t or agency_now()) - secs
  local t1 = wall() + 60
  while wall() < t1 do
    if agency_now() - (e.t or 0) < 1 then return true end
    coroutine.yield()
  end
  out[#out + 1] = string.format("plant catch-up ran out (%.0f s behind)", agency_now() - (e.t or 0))
  return false
end
function stage_plants(list, out)
  local RP, ST = ref("reactor_plant"), ref("structures")
  if not (RP and ST) then return end
  for _, p in ipairs(list or {}) do
    local sid = struct_id(tostring(p.struct or ""):gsub("^struct:", ""))
    local rec = sid and ST.get(sid)
    local e
    local t1 = wall() + 10
    while rec and wall() < t1 do
      e = RP.plantOfPart(sid)
      if e and e.M then break end
      coroutine.yield()
    end
    if not (e and e.M) then out[#out + 1] = "plant " .. tostring(p.struct) .. ": no plant found"; return end
    local n = 0
    if p.fuel then
      for _, q in ipairs(rec.bp) do
        if tostring(q.id):match("^fuelChannel") then n = n + (RP.loadRods(sid, q.uid, p.fuel.item or "fuelRod", p.fuel.n or 8) or 0) end
      end
    end
    frames(2)
    e = RP.plantOfPart(sid)
    local key = RP.keyOf(e.sid, e.uid)
    if p.power and p.days then
      RP.startUp(key, p.power)
      plant_skip(RP, e, p.days * 86400, out)
    end
    if p.scramFor then RP.scram(key); frames(1); plant_skip(RP, e, p.scramFor, out); RP.resetTrip(key) end
    if p.standby then RP.startUp(key, p.standby); plant_skip(RP, e, p.hold or 600, out) end
    if p.protection ~= nil then RP.setProtection(key, p.protection) end
    if p.turbine ~= nil then RP.setTurbine(key, p.turbine) end
    -- fill = { { uid | part, kg } }: tanks of the structure's fluid networks filled
    local FN = ref("fluid_net")
    for _, f in ipairs(p.fill or {}) do
      local fs, fu = piece_of({ struct = p.struct, part = f.part, uid = f.uid })
      local ok = false
      local t2 = wall() + 5
      while fs and FN and FN.setContent and wall() < t2 do
        ok = FN.setContent(fs, fu, f.kg or 1e9)
        if ok then break end
        coroutine.yield()
      end
      out[#out + 1] = string.format("fill %s: %s", tostring(fu), ok and "full" or "no tank")
    end
    if RP.saveNow then pcall(RP.saveNow) end
    local o = e.o or {}
    out[#out + 1] = string.format("plant %s: %d rods, P %.3f, fuel %.0f K, primary %.0f K", tostring(p.struct), n, o.P or -1, o.Tf or 0, o.Tp or 0)
  end
end
-- WIRES: { struct, from = { uid | part, pin }, to = { uid | part, pin } }: a
-- Signal Cable laid free between two pins (logic_net.layWire)
function stage_wires(list, out)
  local LN = ref("logic_net")
  if not (LN and LN.layWire) then return end
  for _, w in ipairs(list or {}) do
    local sa, ua = piece_of({ struct = w.struct, part = w.from.part, uid = w.from.uid })
    local sb, ub = piece_of({ struct = w.struct, part = w.to.part, uid = w.to.uid })
    if sa and sb then
      local id = LN.layWire({ sid = sa, uid = ua, pin = w.from.pin }, { sid = sb, uid = ub, pin = w.to.pin }, { ground = false, free = true, noHistory = true })
      out[#out + 1] = string.format("wire %s.%s → %s.%s: %s", tostring(ua), w.from.pin, tostring(ub), w.to.pin, tostring(id))
    end
  end
end

local function stage_table(st, out)
  local co, rs = ref("company"), ref("research")
  if st.funds then set_funds(st.funds) end
  if st.rp and rs and rs.addPoints then rs.addPoints(st.rp, "scenario") end
  for _, id in ipairs(st.research or {}) do if rs and rs.grant then rs.grant(id, "scenario") end end
  if co and st.funds then out[#out + 1] = string.format("funds %d", co.balance()) end
  frames(1)
  stage_crew(st.crew, out)
  stage_marks(st.marks, out)
  stage_structures(st.structures, out)
  stage_marks(st.marks, out, true)
  stage_posts(st.crew, out)
  stage_lived_in(out)
  stage_plants(st.plants, out)
  stage_wires(st.wires, out)
  stage_crates(st.crates, out)
  stage_flags(st.flags, out)
  stage_survey(st.survey, out)
  if st.weather then local wx = ref("weather"); if wx and wx.force then pcall(wx.force, st.weather == "calm" and "clear" or st.weather) end end
  stage_craft(st.craft, out)
end

-- a `spawn` beat: one entry of a start table, staged by a job of its own
-- (resumed a frame at a time from update: staging yields)
local jobs = {}
stage_one = function(kind, e, out)
  jobs[#jobs + 1] = coroutine.create(function()
    local o = {}
    if kind == "structure" then stage_structures({ e }, o); stage_marks(sc.start and sc.start.marks, o, true); stage_lived_in(o)
    elseif kind == "crate" then stage_crates({ e }, o)
    elseif kind == "flag" then stage_flags({ e }, o)
    elseif kind == "craft" then stage_craft({ e }, o)
    elseif kind == "crew" then stage_crew({ e }, o); stage_posts({ e }, o)
    else o[1] = "spawn: unknown kind " .. tostring(kind) end
    for _, l in ipairs(o) do say_log("spawned " .. l) end
  end)
  out[#out + 1] = "job " .. tostring(kind)
end
local function jobs_tick()
  local i = 1
  while i <= #jobs do
    local ok, err = coroutine.resume(jobs[i])
    if not ok then say_log("spawn error " .. tostring(err)) end
    if coroutine.status(jobs[i]) == "dead" then table.remove(jobs, i) else i = i + 1 end
  end
end

local function stage_all()
  local w0 = wall()
  local out = {}
  stage_table(sc.start or {}, out)
  -- a retry from a checkpoint: its `stage` table on top
  local cp = sget("scn.retryFrom")
  if cp then
    local i = rulebook().stepIndex(sc, cp)
    local s = i and sc.steps[i]
    if s and s.stage then stage_table(s.stage, out) end
    sset("scn.retryFrom", false)
  end
  -- what the run is measured against
  local co, ST = ref("company"), ref("structures")
  local pieces = 0
  for _, r in ipairs((ST and ST.list) and ST.list() or {}) do pieces = pieces + #(r.bp or {}) end
  sset("scn.p0", pieces)
  sset("scn.f0", co and co.balance() or 0)
  sset("scn.staged", true)
  lastStage = { ms = (wall() - w0) * 1000, records = out }
  PROF.stage_ms = lastStage.ms
  for _, l in ipairs(out) do say_log("staged " .. l) end
  local gm = ref("game_manager")
  if gm and gm.saveGame then pcall(gm.saveGame) end
end

-- ── the run ─────────────────────────────────────────────────────────────────
local function set_phase(p)
  if phase == p then return end
  phase = p
  bump()
  say_log("phase " .. tostring(p))
  emit("phase", p, state())
end

local function done_tbl() local d = sget("scn.done"); return type(d) == "table" and d or {} end

local function teach_api()
  return {
    point = function(r) return pointOf(r) end,
    frame = function(r)
      local p = pos_of(r)
      if not p then return nil end
      local F = rulebook().groundFrame(p.x, p.y, p.z)
      return { body = p.body, x = p.x, y = p.y, z = p.z, ux = F.ux, uy = F.uy, uz = F.uz, fx = F.fx, fy = F.fy, fz = F.fz }
    end,
    file = function(path) return rulebook().readText(sc._dir .. path) end,
  }
end
-- THE HOOKS API: all a scenario's hooks.lua can reach (no engine, no save)
local function call_hook(name, ...)
  local H = hooks_of()
  local f = H and H[name]
  if type(f) ~= "function" then return end
  local ok, err = pcall(f, hooks_api(), ...)
  if not ok then say_log("hook " .. name .. ": " .. tostring(err)) end
end
hooks_api = function()
  return {
    reactor = function(struct)
      local sid = struct_id(tostring(struct or ""):gsub("^struct:", ""))
      local r = sid and W.reactor(sid)
      if not r then return nil end
      local c = {}
      for k, v in pairs(r) do c[k] = v end
      return c
    end,
    piece = function(struct, part)
      local sid, uid, p = piece_of({ struct = struct, part = type(part) == "string" and part or nil, uid = type(part) == "number" and part or nil })
      if not sid then return nil end
      local ST, RP = ref("structures"), ref("reactor_plant")
      local st = ST and ST.partState and ST.partState(sid, uid) or {}
      local c = { id = p.id, uid = uid, knocked = p.wr == true }
      for k, v in pairs(st) do if type(v) ~= "table" then c[k] = v end end
      if RP and RP.plantOfPart and RP.plantOfPart(sid, uid) and RP.pumpOn then c.pumpOn = RP.pumpOn(sid, uid) end
      return c
    end,
    dose = function(who)
      local C = ref("crew")
      local id = member_id(tostring(who or ""):gsub("^crew:", ""))
      return (C and id and C.doseOf) and C.doseOf(id) or 0
    end,
    say = function(who, text) queue_beats({ { say = { who = who, text = text } } }, "hook") end,
    run = function(seq) run_seq(seq, false) end,
    beat = function(b) queue_beats({ b }, "hook") end,
    var = function(n) return var(n) end,
    setVar = function(n, v) setVar(n, v) end,
    done = function(id) return done_tbl()[id] ~= nil end,
    ["goto"] = function(id) gotoStep(id) end,
    fail = function(why) fail(why) end,
    finish = function() finish() end,
    pos = function(r) local p = pos_of(r); return p and { body = p.body, x = p.x, y = p.y, z = p.z } end,
    dist = function(a, b)
      local p, q = pos_of(a), pos_of(b)
      if not (p and q) or p.body ~= q.body then return nil end
      return math.sqrt((p.x - q.x) ^ 2 + (p.y - q.y) ^ 2 + (p.z - q.z) ^ 2)
    end,
    now = function() return agency_now() end,
    log = function(s) say_log("[hook] " .. tostring(s)) end,
  }
end
W.hookGoal = function(fn, g)
  local H = hooks_of()
  local f = H and H.goals and H.goals[fn]
  if type(f) ~= "function" then return false, "no hook goal " .. tostring(fn) end
  return f(g, hooks_api())
end

local teach_open = nil
local function open_step(i)
  local s = sc.steps[i]
  if open_seen[s.id] then return end
  open_seen[s.id] = true
  step_t0[s.id] = agency_now()
  progress_t[s.id] = agency_now()
  if s.checkpoint then sset("scn.cp", s.id) end
  queue_beats(s.on_enter, s.id)
  if s.run then run_seq(s.run, false) end
  call_hook("on_step", s.id)
  if s.teach then teach_open = s.id; emit("teach", s.teach, s, teach_api()) end
  bump()
end
local function close_step(s)
  if teach_open == s.id then teach_open = nil; emit("teach", nil, s, teach_api()) end
end
function teachNow()
  if not (sc and teach_open) then return nil end
  local i = rulebook().stepIndex(sc, teach_open)
  local s = i and sc.steps[i]
  return s and s.teach, s
end

local function latch(s)
  local d = done_tbl()
  if d[s.id] then return end
  d[s.id] = agency_now()
  sset("scn.done", d)
  say_log("step done: " .. s.id)
  close_step(s)
  queue_beats(s.on_done, s.id)
  call_hook("on_done", s.id)
  bump()
end

-- jump: every required step before `id` is latched (no beats), `id` opens next
function gotoStep(id)
  if not sc then return false end
  local i = rulebook().stepIndex(sc, id)
  if not i then say_log("goto: no step " .. tostring(id)); return false end
  local d = done_tbl()
  for j = 1, i - 1 do
    local s = sc.steps[j]
    if not d[s.id] then d[s.id] = agency_now(); open_seen[s.id] = true; close_step(s) end
  end
  sset("scn.done", d)
  say_log("goto " .. id)
  last_eval = -1
  bump()
  return true
end

local function stats_now()
  local co, ST = ref("company"), ref("structures")
  local pieces = 0
  for _, r in ipairs((ST and ST.list) and ST.list() or {}) do pieces = pieces + #(r.bp or {}) end
  local t0 = tonumber(sget("scn.t0")) or agency_now()
  local safe = not W.crewDead(nil)
  return { secs = agency_now() - t0, spent = math.max(0, (tonumber(sget("scn.f0")) or 0) - (co and co.balance() or 0)),
           hints = tonumber(sget("scn.hints")) or 0, pieces = math.max(0, pieces - (tonumber(sget("scn.p0")) or pieces)),
           crewSafe = safe, vars = vars() }
end
statsNow = stats_now

local function record_profile(outcome, med, secs)
  local R_ = rulebook()
  local p = R_.profileRecord(R_.profileLoad(), sc.id, outcome, med, secs)
  R_.profileSave(p)
end

function finish()
  if not sc or phase == "done" or phase == "failed" or finishing then return end
  local st = stats_now()
  stats_final = st
  local med = rulebook().medal(sc, st)
  sset("scn.outcome", "done")
  sset("scn.medal", med)
  sset("scn.secs", st.secs)
  record_profile("done", med, st.secs)
  say_log(string.format("DONE %s in %.0f s: %s", sc.id, st.secs, med))
  -- the last step's beats (its camera orbit is the showcase) play out first
  finishing = med
  bump()
end
finishing = nil
local function finish_now()
  local med = finishing
  finishing = nil
  cut_end()
  camera_end()
  set_phase("done")
  if not listeners.phase then
    local bc = ref("big_caption")
    if bc and bc.show then bc.show(string.upper(med) .. " · " .. tostring(sc.title), (sc.debrief or {})[med] or "", 8.0) end
    if (sc.after or "freeplay") == "freeplay" then continueFreeplay() end
  end
end

function fail(why)
  if not sc or phase == "done" or phase == "failed" then return end
  fail_text = why or "The scenario failed."
  local st = stats_now()
  stats_final = st
  sset("scn.outcome", "fail")
  sset("scn.failText", fail_text)
  record_profile("fail", nil, st.secs)
  say_log("FAILED " .. sc.id .. ": " .. fail_text)
  queue_beats(sc.on_fail, "fail")
  set_phase("failed")
  if not listeners.phase then
    local bc = ref("big_caption")
    if bc and bc.show then bc.show("FAILED · " .. tostring(sc.title), fail_text, 8.0) end
  end
end

-- one evaluation of the open steps and the fail list
local function evaluate()
  local w0 = wall()
  local R_ = rulebook()
  local done = done_tbl()
  local t = agency_now()
  local ctx = { done = done, t0 = tonumber(sget("scn.t0")) or t, now = t,
                stepAt = function(id) return step_t0[id] or done[id] end }
  local open, cur = R_.openSteps(sc, done)
  for _, i in ipairs(open) do
    local s = sc.steps[i]
    open_step(i)
    ctx.stepT0 = step_t0[s.id] or t
    local all, n, rows = true, 0, {}
    for j, g in ipairs(s.goals) do
      local key = s.id .. ":" .. j
      mem[key] = mem[key] or {}
      local met, reading = R_.evalGoal(g, W, mem[key], ctx)
      rows[j] = { label = R_.goalLabel(g), met = met, reading = reading }
      if met then n = n + 1 else all = false end
    end
    readings[i] = rows
    if n ~= met_count[s.id] then met_count[s.id] = n; progress_t[s.id] = t; bump() end
    if all then latch(s) end
    -- hints: the first after HINT_SECS without progress, the second after HINT2_SECS
    if s.hint and not hint_shown[s.id] and t - (progress_t[s.id] or t) >= R_.HINT_SECS then
      hint_shown[s.id] = 1
      sset("scn.hints", (tonumber(sget("scn.hints")) or 0) + 1)
      bump()
    end
    if s.hint2 and hint_shown[s.id] == 1 and t - (progress_t[s.id] or t) >= R_.HINT2_SECS then hint_shown[s.id] = 2; bump() end
  end
  call_hook("tick", t)
  -- the scripted events
  local fired = sget("scn.ev") or {}
  for i, ev in ipairs(sc.events or {}) do
    local key = ev.id or ("ev" .. i)
    local gate = (not ev.after or done[ev.after] ~= nil) and (not ev.during or (cur and sc.steps[cur].id == ev.during))
    local again = ev.once == false and (not fired[key] or t - fired[key] >= (ev.cooldown or 10))
    if gate and (not fired[key] or again) and ev.when then
      mem["ev:" .. key] = mem["ev:" .. key] or {}
      local c2 = { done = done, t0 = ctx.t0, now = t, stepAt = ctx.stepAt, stepT0 = cur and step_t0[sc.steps[cur].id] or nil }
      local hit = R_.evalGoal(ev.when, W, mem["ev:" .. key], c2)
      if hit then
        fired[key] = t
        sset("scn.ev", fired)
        say_log("event " .. key)
        if ev.run then run_seq(ev.run, false) end
        if ev.beats then queue_beats(ev.beats, key) end
      end
    end
  end
  for i, f in ipairs(sc.fail or {}) do
    local key = "fail:" .. i
    mem[key] = mem[key] or {}
    local hit, reading = R_.evalGoal(f, W, mem[key], ctx)
    fail_read[i] = reading
    if hit then fail(f.text); break end
  end
  if phase == "running" and not finishing and R_.finished(sc, done_tbl()) then finish() end
  PROF.evals = PROF.evals + 1
  PROF.eval_ms = (wall() - w0) * 1000
end

-- ── the state surface ───────────────────────────────────────────────────────
local function build_state()
  if not (active and sc) then return { active = false, version = version } end
  local R_ = rulebook()
  local done = done_tbl()
  local open, cur = R_.openSteps(sc, done)
  local s = cur and sc.steps[cur]
  local d, n = R_.progress(sc, done)
  local t0 = tonumber(sget("scn.t0"))
  local outcome = sget("scn.outcome")
  local med = sget("scn.medal")
  local st = {
    active = true, id = sc.id, title = sc.title, teaches = sc.teaches or {}, blurb = sc.blurb, brief = sc.brief or {},
    phase = phase, step = cur or n, steps = n, done = d, stepId = s and s.id, stepText = s and s.text,
    hint = s and hint_shown[s.id] and s.hint or nil, hint2 = s and hint_shown[s.id] == 2 and s.hint2 or nil,
    goals = (cur and readings[cur]) or {}, elapsed = t0 and (agency_now() - t0) or 0,
    par = sc.score and sc.score.par, hintsUsed = tonumber(sget("scn.hints")) or 0,
    outcome = outcome or nil, medal = med or nil, failText = sget("scn.failText") or nil,
    after = sc.after or "freeplay", checkpoint = sget("scn.cp") or nil, version = version,
    mark = s and s.mark,
    line = line, choice = choice and { who = choice.who, name = choice.name, color = choice.color, prompt = choice.prompt,
                                      options = choice.options, t0 = choice.t0, timeout = choice.timeout } or nil,
    cutscene = cut ~= nil, letterbox = cut ~= nil, alarm = alarm_on, vars = vars(),
  }
  local ob = sget("scn.obj") or {}
  if s and ob[s.id] then st.stepText = ob[s.id] elseif s and s.objective then st.stepText = s.objective end
  if s and not st.hint and s.hint and phase == "running" then st.hintIn = math.max(0, R_.HINT_SECS - (agency_now() - (progress_t[s.id] or agency_now()))) end
  if outcome then
    local deb = sc.debrief or {}
    st.debrief = (outcome == "fail") and deb.fail or deb[med or "bronze"]
    st.score = R_.score(sc, stats_final or stats_now())
  end
  return st
end
function state()
  if st_cache and st_ver == version and phase ~= "running" then return st_cache end
  if st_cache and st_ver == version and now() - (st_cache._t or 0) < 0.25 then return st_cache end
  st_cache = build_state()
  st_cache._t = now()
  st_ver = version
  return st_cache
end
function isActive() return active == true end
function phaseNow() return phase end
function scenario() return sc end
function readingsNow() return readings, fail_read end
function debugQueue() return #beatq, cam ~= nil, beat_busy ~= nil, finishing end

-- What the scenario switched off ("contracts" | "programme" | "weather"):
-- true when it is allowed (and always outside a scenario, and in freeplay
-- when the author's `freeplay` table allows it).
function allows(what)
  if not (active and sc) then return true end
  local st = sc.start or {}
  if phase == "freeplay" then
    local fp = sc.freeplay or {}
    if fp[what] ~= nil then return fp[what] == true end
  end
  if st[what] == false then return false end
  return true
end

-- The objectives card's step (objectives.lua `scn:` source): → step | nil
function cardStep()
  if not (active and sc) or (phase ~= "running" and phase ~= "briefing") then return nil end
  local s = state()
  if not s.stepText then return nil end
  local goals = {}
  for _, g in ipairs(s.goals or {}) do
    goals[#goals + 1] = (g.met and "✓ " or "○ ") .. tostring(g.label) .. ((not g.met and g.reading) and ("  (" .. g.reading .. ")") or "")
  end
  local step = { key = "scn:" .. tostring(s.stepId), label = string.format("%s · %d/%d", s.title, math.min(s.step, s.steps), s.steps),
                 task = s.stepText, hint = s.hint2 or s.hint, goals = goals }
  if s.mark then
    local x, y, z = pointOf(s.mark)
    local p = pos_of(s.mark)
    if x then step.spot = { x = x, y = y, z = z, body = p and p.body, name = s.markName or tostring(s.mark):gsub("^%a+:", ""), near = "› You're there" } end
  end
  return step
end

-- ── actions ─────────────────────────────────────────────────────────────────
function wantBriefing(on) want_brief = on ~= false end
function go()
  if phase ~= "briefing" and phase ~= "staging_done" then return false end
  if physics and physics.pause and paused_by_us then physics.pause(false) end
  paused_by_us = false
  if not sget("scn.t0") then sset("scn.t0", agency_now()) end
  set_phase("running")
  if not sget("scn.started") then
    sset("scn.started", true)
    queue_beats(sc.on_start, "start")
  end
  last_eval = -1
  return true
end
paused_by_us = false

local function reload_slot(retryFrom)
  local R_ = rulebook()
  local id = sc and sc.id or sget("g_scenario")
  camera_end()
  if physics and physics.pause then physics.pause(false) end
  local ok, err = R_.prepareSlot(id)
  if not ok then say_log("restart failed: " .. tostring(err)); return false end
  if retryFrom then
    local s2 = R_.load(id)
    local d = {}
    for _, sid in ipairs(R_.beforeCheckpoint(s2, retryFrom)) do d[sid] = 0 end
    save.set("scn.done", d)
    save.set("scn.retryFrom", retryFrom)
    save.set("scn.cp", retryFrom)
  end
  scene.load("system")
  return true
end
function restart() return reload_slot(nil) end
function retry()
  local cp = sget("scn.cp")
  return reload_slot(cp or nil)
end
function continueFreeplay()
  set_phase("freeplay")
  sset("scn.freeplay", true)
  camera_end()
end
function toMenu()
  local gm = ref("game_manager")
  if gm and gm.exitToMenu then gm.exitToMenu() end
end
function completeStep()
  if phase ~= "running" then return false end
  local _, cur = rulebook().openSteps(sc, done_tbl())
  if not cur then return false end
  local s = sc.steps[cur]
  say_log("F11: step " .. s.id .. " completed by hand")
  latch(s)
  last_eval = -1
  return s.id
end
function hint()
  local _, cur = rulebook().openSteps(sc, done_tbl())
  local s = cur and sc.steps[cur]
  if not (s and s.hint) then return false end
  if not hint_shown[s.id] then
    hint_shown[s.id] = 1
    sset("scn.hints", (tonumber(sget("scn.hints")) or 0) + 1)
  elseif s.hint2 then hint_shown[s.id] = 2 end
  bump()
  return true
end
function goalKind(k, def) rulebook().KINDS[k] = def end
function holdCurtain() return active == true and (phase == "loading" or phase == "staging") end

-- ── F12: the world as a start table ─────────────────────────────────────────
function dumpStart()
  local R_ = rulebook()
  local C, co, rs, ST, BPs, PB, dep = ref("crew"), ref("company"), ref("research"), ref("structures"), ref("blueprints"), ref("parts_base"), ref("deployables")
  local n = (tonumber(sget("scn.dumps")) or 0) + 1
  sset("scn.dumps", n)
  local dir = "user://scenarios/dump_" .. n
  local st = { funds = co and co.balance() or nil, research = {}, crew = {}, structures = {}, flags = {} }
  for id in pairs(sget("res.done") or {}) do st.research[#st.research + 1] = id end
  table.sort(st.research)
  local function latlon(x, y, z)
    local l = math.sqrt(x * x + y * y + z * z)
    return string.format("lat:%.4f,lon:%.4f", math.deg(math.asin(y / l)), math.deg(math.atan2(z, x)))
  end
  if C then
    for _, r in ipairs(C.roster()) do
      if r.status ~= "dead" then
        local e = { name = r.name, role = r.role, control = (r.id == C.activeId()) or nil }
        local p = pos_of("crew:" .. r.name)
        if p and p.body then e.where = { body = (p.body == home_name()) and "home" or p.body, site = latlon(p.x, p.y, p.z) } end
        local inv = ref("inventory")
        if inv then
          e.pack = {}
          for _, g in ipairs(inv.itemList and inv.itemList("crew:" .. r.id) or {}) do e.pack[#e.pack + 1] = { item = g.id, n = g.n } end
        end
        st.crew[#st.crew + 1] = e
      end
    end
  end
  if ST and BPs and PB then
    for _, r in ipairs(ST.list()) do
      if not r.ru then
        local bp = BPs.fromParts(r, nil, function(id) return PB.partInfo(id) end, { name = r.n })
        if bp then
          local slug = (BPs.slug and BPs.slug(r.n or ("structure_" .. r.id))) or ("structure_" .. r.id)
          local path = dir .. "/" .. slug .. ".bp.txt"
          if assets and assets.writeText then pcall(assets.writeText, path, BPs.encode(bp)) end
          st.structures[#st.structures + 1] = { bp = "<id>/" .. slug .. ".bp.txt", name = r.n,
                                                at = "base", offset = { 0, 0, 0 }, _site = latlon(r.x, r.y, r.z) }
        end
      end
    end
  end
  if dep then for _, f in ipairs(dep.list("flag") or {}) do st.flags[#st.flags + 1] = { name = f.name } end end
  local text = "-- dumped " .. tostring(n) .. ": paste into a scenario's `start`; copy the .bp.txt files beside it\nreturn " .. R_.serialize(st) .. "\n"
  local path = dir .. ".lua"
  if assets and assets.writeText then pcall(assets.writeText, path, text) end
  say_log("dumped the world to " .. path)
  return path, text
end

-- ── the frame ───────────────────────────────────────────────────────────────
local function decide()
  if active ~= nil then return active end
  local id = save and save.slot and save.slot() == SLOT and save.get("g_scenario")
  if type(id) ~= "string" then active = false return false end
  -- (only in the world: the menu scene may sit on slot scn after a run)
  if not (findScript and findScript("game_manager")) then active = false return false end
  local R_ = rulebook()
  local s, err = R_ and R_.load(id)
  if not s then say_log("cannot load " .. tostring(id) .. ": " .. tostring(err)); active = false return false end
  sc = s
  hooks_of()
  active = true
  local out = sget("scn.outcome")
  if out == "done" then phase = sget("scn.freeplay") and "freeplay" or "done"
  elseif out == "fail" then phase = "failed"
  else phase = "loading" end
  -- a reload knows the steps already open: their on_enter is not fired again
  for _, s2 in ipairs(sc.steps or {}) do if done_tbl()[s2.id] then open_seen[s2.id] = true end end
  bump()
  return true
end

function start(node)
  node_ref = node
  decide()
end

-- (flagship) the right-click row on a knocked piece of any structure that is
-- not a ruin (ruins.lua has its own): repaired with a Repair Kit from the pack
local function repair_provider(t, ctx)
  if not (active and t and t.node) then return {} end
  local ST, RU, inv = ref("structures"), ref("ruins"), ref("inventory")
  if not (ST and ST.partOfNode and RU and RU.repairPiece) then return {} end
  local rec, part = ST.partOfNode(t.node)
  if not (rec and part and part.wr and not rec.ru) then return {} end
  local pack = (ctx and ctx.actor and ctx.actor.pack) or "astro"
  local pb = ref("parts_base")
  local d = pb and pb.partInfo(part.id)
  local label = part.wrl or ("Repair the " .. ((d and d.label) or tostring(part.id)))
  local secs = tonumber(part.wrs) or 8
  local function near()
    local CP = ref("context_providers")
    if CP and CP.actorReach then return CP.actorReach(ctx, t, 1.5) ~= nil end
    return true
  end
  return { { id = "scn_fix", type = "action", group = "Repair", label = label, hint = string.format("Repair Kit · %d s", secs),
    enabled = function() return inv and (inv.itemCount(pack, "repairkit") or 0) > 0 and near() end,
    why = function() return near() and "needs a Repair Kit in the pack" or "come closer" end,
    job = { secs = secs, label = label, check = function() return near(), "walked away" end,
      done = function()
        if inv and inv.removeItem then inv.removeItem(pack, "repairkit", 1) end
        local ok = RU.repairPiece(rec.id, part.uid)
        if ok then emit("repair", rec.id, part.uid) end
        return ok, nil
      end } } }, "Repair", nil
end
local repair_reg = false

function update(node, dt)
  node_ref = node
  if active == false then return end
  if active == nil and not decide() then return end
  if not repair_reg then
    local reg = ref("context_registry")
    if reg and reg.register then reg.register("prop", repair_provider, { id = "scn_repair", order = 4 }); repair_reg = true end
  end
  if phase == "loading" then
    local gm, bf = ref("game_manager"), ref("base_facilities")
    if gm and not gm.loading and bf and bf.sited and not (bf.grading and bf.grading()) then
      if sget("scn.staged") then
        -- a reload of a staged run: straight back in, no briefing
        set_phase("staging_done")
        go()
      else
        co_stage = coroutine.create(stage_all)
        set_phase("staging")
      end
    end
    return
  end
  if phase == "staging" then
    local ok, err = coroutine.resume(co_stage)
    if not ok then say_log("STAGING ERROR " .. tostring(err)); lastStage = { error = tostring(err) }; sset("scn.staged", true) end
    if coroutine.status(co_stage) == "dead" then
      co_stage = nil
      if want_brief then
        set_phase("briefing")
        if physics and physics.pause then physics.pause(true); paused_by_us = true end
      else
        set_phase("staging_done")
        go()
      end
    end
    return
  end
  if phase == "running" then
    local t = agency_now()
    local hz = params and params.eval_hz or defaults.eval_hz
    if last_eval < 0 or t - last_eval >= 1 / hz or t < last_eval then
      last_eval = t
      evaluate()
    end
  end
  if phase ~= "loading" and phase ~= "staging" then
    beats_tick()
    if next(walks) then walks_tick() end
    if #jobs > 0 then jobs_tick() end
    input_tick()
  end
  if finishing and #beatq == 0 and not cam and not beat_busy then finish_now() end
  -- Ctrl+F10: the goal readings on screen
  if input and input.pressed and input.pressed("f10") and input.key and input.key("ctrl") then overlay = not overlay end
end

function lateUpdate(node, dt)
  if active and (line or choice or cut or alarm_on) then draw_builtin() end
  if not (active and overlay and draw and draw.text and sc) then return end
  local lines = { string.format("SCENARIO %s · %s · step %s", sc.id, tostring(phase), tostring(state().stepId)) }
  local open = rulebook().openSteps(sc, done_tbl())
  for _, i in ipairs(open) do
    local s = sc.steps[i]
    lines[#lines + 1] = "[" .. s.id .. "]"
    for j, r in ipairs(readings[i] or {}) do
      lines[#lines + 1] = string.format("  %s %s: %s", r.met and "✓" or "·", tostring(r.label), tostring(r.reading))
    end
  end
  for i, f in ipairs(sc.fail or {}) do lines[#lines + 1] = string.format("  fail %s: %s", f.kind, tostring(fail_read[i])) end
  lines[#lines + 1] = string.format("eval %.3f ms · %d evals", PROF.eval_ms, PROF.evals)
  for i, l in ipairs(lines) do draw.text(24, 120 + i * 18, l, 14, 0.85, 1.0, 0.7, 0.95) end
end
