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
-- (missions S0) CAREER: beats run by runBeats in a save that is not a
-- scenario's (the CAREER BEATS section below); nil when none is playing
local CAREER = nil
local CRB = {}          -- (missions S0) the CAREER BEATS section's own functions and state (one local: the chunk is near Lua's 200)
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
local function sset(k, v)
  -- (missions S0) a career run never writes the scenario's keys
  if CAREER and type(k) == "string" and k:sub(1, 4) == "scn." then return end
  save.set(k, v)
end

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
  -- (missions S0) a career run's people: survivors and clients are crew
  -- records off the roster, named by the contract
  if CAREER and CAREER.crew and CAREER.crew[name] then return CAREER.crew[name] end
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
  if CAREER then local p = CRB.ref(r); if p ~= nil then return p or nil end end
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
    -- (scn_vacuum) craft:<name>@<uid>: that part, where it is drawn this
    -- frame (partFrameNow through a fresh handle: the craft's own node lags
    -- the rails carry), made body-relative against this frame's body
    local cn, pu = n:match("^(.+)@(%d+)$")
    for _, v in ipairs(vessels()) do
      if v.craftName == (cn or n) and not (v.isLost and v.isLost()) then
        if pu and v.partFrameNow then
          local F = v.partFrameNow(tonumber(pu), true)
          if not F then return nil end
          local d = space.dominant(F.ox, F.oy, F.oz)
          local b = d and space.body(d)
          return b and { body = d, x = F.ox - b.x, y = F.oy - b.y, z = F.oz - b.z } or nil
        end
        return node_rel(v.node)
      end
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
    -- (missions S0/N1) a survivor: a client record lying or standing where it is
    if rec.status == "client" and rec.body and rec.x then return { body = rec.body, x = rec.x, y = rec.y, z = rec.z } end
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
  return s and { supply = s.supply, need = s.need, powered = s.powered, stored = s.stored, cap = s.cap } or nil
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
-- (progression P1) how many times a feat is done (scripts/feats.lua)
function W.featCount(id) local F = ref("feats"); return F and F.count and F.count(id) or 0 end
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
-- (G1) a craft's cabin air: module `which` of the craft named `name`
-- (scripts/cabin_air.lua cabinOf) → status | nil
function W.cabin(name, which)
  local CA = ref("cabin_air")
  if not (CA and CA.cabinOf and CA.enabled and CA.enabled()) then return nil end
  for _, v in ipairs(vessels()) do
    if v.craftName == name and not (v.isLost and v.isLost()) then return CA.cabinOf(v, which) end
  end
  return nil
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

local function vars()
  if CAREER then return CAREER.vars end      -- (missions S0) the caller's own table
  local v = sget("scn.vars"); if type(v) ~= "table" then v = {}; for k, x in pairs((sc and sc.vars) or {}) do v[k] = x end; sset("scn.vars", v) end return v end
function var(name) return vars()[name] end
function setVar(name, v) local t = vars(); t[name] = v; sset("scn.vars", t); bump() end
W.var = function(name) return var(name) end

-- who → { name, tag, color, portrait, radio, delay, link } (the cast, a crew
-- name, or Ops). FW-C: portrait = "auto" is the booth's picture
-- (<id>/<key>.png, tools/perf/portraitbooth.sh); radio, delay and link are the
-- cast's (PLAN §2 F3).
local function cast_speaker(k, c, who)
  local pt = rulebook().portraitOf(sc, k, c)
  local tex = c.portrait == "auto" and portraitTex and portraitTex(k) or nil
  -- (storypolish) `here = "<var>"`: a radio voice who has come home: in the
  -- room with you (no radio, `hereTag`) once that variable is true
  local here = c.here ~= nil and var(c.here) == true
  return { who = k, name = c.name or who, tag = here and (c.hereTag or c.tag) or c.tag, color = c.color, portrait = tex or (pt and (sc._dir .. pt)) or nil,
           radio = (c.radio == true and not here) or nil, delay = (not here) and c.delay or nil, link = (not here) and c.link or nil, crew = c.crew }
end
local function speaker(who)
  who = who or "ops"
  local c = sc and sc.cast and sc.cast[who]
  if c then return cast_speaker(who, c, who) end
  if who == "ops" then return { who = "ops", name = "Ops", tag = "OPS", color = { 0.55, 0.85, 1.0 } } end
  if sc and sc.cast then
    for k, cc in pairs(sc.cast) do if cc.crew == who then return cast_speaker(k, cc, who) end end
  end
  local C = ref("crew")
  local id = member_id(who)
  local r = C and id and C.get(id)
  local tt = r and C.roleTitle and C.roleTitle(id)
  return { who = who, name = r and r.name or tostring(who), tag = (tt and string.upper(tt)) or (r and r.role and string.upper(r.role)) or nil }
end
speakerOf = speaker
local function chirp()
  if audio and audio.play then pcall(audio.play, "audio/sfx/crew_chime.ogg", { track = "UI", volume = 0.25 }) end
end
-- FW-C: a radio voice over a link (`link = "craft:<name>" | "crew:<name>"`):
-- false when that craft (or the craft the member rides) reads no comms path
local function link_up(ref_)
  local k, n = rulebook().parseRef(ref_)
  local net = ref("comms")
  if not (net and net.statusOf) then return true end
  local v
  if k == "craft" then
    for _, vc in ipairs(vessels()) do if vc.craftName == n and not (vc.isLost and vc.isLost()) then v = vc end end
    if not v then return false end
  elseif k == "crew" then
    local C = ref("crew")
    v = C and C.craftOf and C.craftOf(member_id(n)) or nil
    if not v then return true end      -- (on foot: the suit's own radio, line of sight)
  else return true end
  local s = v.node and net.statusOf(v.node.id)
  return s == nil or s.connected ~= false
end
linkUp = link_up
local garbled_n = 0
local function show_line(who, text, secs, opts)
  local s = speaker(who)
  s.text = tostring(text)
  if s.link and not link_up(s.link) then
    garbled_n = garbled_n + 1
    s.text = rulebook().garble(s.text, garbled_n)
    s.garbled = true
    if audio and audio.play then pcall(audio.play, "audio/foley/radio_squelch.ogg", { track = "UI", volume = 0.35 }) end
  end
  if s.radio and audio and audio.play then pcall(audio.play, "audio/foley/radio_crackle.ogg", { track = "UI", volume = 0.18 }) end
  -- the listener, dimmed on the right of the plate (say.with)
  s.header = opts and opts.header or nil      -- (F8) a Data Core entry's date, over the line
  if opts and opts.with then
    local w = speaker(opts.with)
    s.with = { who = w.who, name = w.name, tag = w.tag, color = w.color, portrait = w.portrait, radio = w.radio }
  end
  s.t0 = now()
  s.secs = secs or SC5R.lineSecs(s.text)
  line = s
  -- (gy3) the speaker looks at whoever it is said to, they look back
  if talkBegin then pcall(talkBegin, s, opts and opts.with, opts and opts.look) end
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
-- KEEPING CLEAR (Ty 2026-11-10: the camera inside Dana's face): a shot's
-- camera keeps SHOT_MIN m from the point it looks at. Everything else, out
-- of every body, piece and wall, is planet_camera's (shot_clear), on the
-- view as it is placed each frame, blend and all. The ray that was cast
-- here, ten times a second from half way out, never saw a body the camera
-- was already inside (Hollis's shot from Teodor's own mark sat 0.14 m from
-- his axis: camclear_mon), and a thin ray slipped past the rest
-- (Ty 2026-11-11: "cutscene camera still clipping inside of astronaut bodies").
SHOT_MIN = 1.1
local function keep_clear(st, cx, cy, cz, lx, ly, lz)
  local dx, dy, dz = cx - lx, cy - ly, cz - lz
  local L = math.sqrt(dx * dx + dy * dy + dz * dz)
  if L < 1e-4 or L >= SHOT_MIN then return cx, cy, cz end
  local k = SHOT_MIN / L
  return lx + dx * k, ly + dy * k, lz + dz * k
end
keepClear = keep_clear

local function shot_fn(c, t0, secs)
  local clear = {}
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
      local qx, qy, qz = keep_clear(clear, px - dx * dist + F.ux * h, py - dy * dist + F.uy * h, pz - dz * dist + F.uz * h, px, py, pz)
      return qx, qy, qz, px, py, pz, F.ux, F.uy, F.uz
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
    cx, cy, cz = keep_clear(clear, cx, cy, cz, lx, ly, lz)
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
  pc.setShot(shot_fn(c, now(), secs), cam and 0.6 or (c.ease or 1.0), { clear = true })
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
  -- (SC-5) into a craft's locker (`uid`, else its first); a negative n takes back
  if t.craft and SC5R then
    local vc = SC5R.vc(t.craft)
    cid = nil
    for _, d in ipairs((vc and vc.fleetParts and (vc.fleetParts() or {}).parts) or {}) do
      if not cid and (not t.uid or d.uid == t.uid) and vc.lockerOf then cid = vc.lockerOf(d.uid) end
    end
    if not cid then say_log("give: no locker aboard " .. tostring(t.craft)); return end
  end
  if t.item and (t.n or 1) < 0 then inv.removeItem(cid, t.item, -(t.n or 1)); return end
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
-- (gy3) is the player using piece { struct, part | uid } now: its terminal
-- open (E at it), or its menu open (a right-click)? → true, how | false, why
W.using = function(g)
  local sid, uid = piece_of(g)
  if not sid then return false, "no such piece" end
  local T = ref("terminal")
  local ts = T and T.state and T.state()
  if ts and ts.sid == sid and ts.uid == uid then return true, "at its terminal" .. (ts.page and (" · " .. tostring(ts.page)) or "") end
  local CM, ST = ref("context_menu"), ref("structures")
  local t = CM and CM.open and CM.target
  if t and t.node and ST and ST.partOfNode then
    local ok, rec, p = pcall(ST.partOfNode, t.node)
    if ok and rec and p and rec.id == sid and p.uid == uid then return true, "its menu is open" end
  end
  return false, (ts and "at another console") or "not in use"
end

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
                run = true, alarm = true, fail = true, done = true, hook = true,
                -- FW-C: what changes the world (or the light it is seen in)
                light = true, weather = true, breaker = true, wear = true, music = true,
                -- graveyard2: where a body faces and how it rests
                turn = true, pose = true, gesture = true,
                -- S6: designations, the base log, contents, keypads
                tag = true, log = true, container = true, lock = true,
                core = true,      -- (F8: a core read, sealed, placed or finished)
                -- SC-5: who drives, who sits where, where a craft stands, its charge
                drive = true, board = true, place = true, charge = true }
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

-- ── FW-C: the story framework pack (PLAN §2 F2–F4, F7) ──────────────────────
-- DELAYED LINES: { t (agency), b = a say beat } kept in `scn.dl` (a reload
-- keeps them); each is queued behind what is playing once its time comes and
-- no cutscene is on (a line from far away never cuts into one).
local delayed = nil
local function dl_list()
  if delayed == nil then local t = sget("scn.dl"); delayed = type(t) == "table" and t or {} end
  return delayed
end
function delay_line(sayb, d)
  local L = dl_list()
  local b = {}
  for k2, x in pairs(sayb) do b[k2] = x end
  b._now = true
  L[#L + 1] = { t = agency_now() + d, b = b }
  sset("scn.dl", L)
end
local function delays_tick()
  local L = delayed
  if not L or #L == 0 or cut then return end
  local t = agency_now()
  local i, changed = 1, false
  while i <= #L do
    if t >= L[i].t then
      beatq[#beatq + 1] = { b = { say = L[i].b }, src = "delay" }
      table.remove(L, i); changed = true
    else i = i + 1 end
  end
  if changed then sset("scn.dl", L) end
end
function pendingLines() return #(dl_list()) end

-- the scripts of a member's body: their CrewBody (crew_body), their Face
local function body_script(kind, id)
  for _, s in ipairs(findScripts and findScripts(kind) or {}) do
    if s.memberId == id and s.doll ~= true then return s end
  end
  return nil
end
-- a beat's `who` (a crew name, crew:<name>, or a cast key with crew =) → id
function who_id(who)
  if type(who) ~= "string" then return member_id(who) end
  who = who:gsub("^crew:", "")
  local c = sc and sc.cast and sc.cast[who]
  if c and c.crew then return member_id(c.crew) end
  return member_id(who)
end
-- FACE: { who, emotion, weight, secs } — crew_faces holds the expression
local function face_beat(v)
  local CF = ref("crew_faces")
  local id = who_id(v.who)
  if CF and CF.force and id then CF.force(id, rulebook().faceName(v.emotion), v.weight or 1, v.secs or 6) end
end
-- LOOK: { who, at = ref | false } — the head (crew_body) and the eyes (face)
-- turn to the ref, re-read every frame they are posed (never a kept point)
local function look_beat(v)
  local id = who_id(v.who)
  if not id then return end
  local fn = nil
  if v.at then
    local target = v.at
    fn = function() local x, y, z = pointOf(target); if not x then return nil end return x, y, z, 1 end
  end
  local cb = body_script("crew_body", id)
  if cb and cb.lookSelf then pcall(cb.lookSelf, fn) end
  local fc = body_script("face", id)
  if fc then fc.gaze = fn end
end

-- (graveyard2) TURN: { who, to = ref } — a body on foot turned to face the
-- ref (the record's `face`, the way the suit looks; crew_body turns to it
-- smoothly). The player is never turned.
local function turn_member(id, to)
  local C = ref("crew")
  local r = C and id and C.get(id)
  if not (r and r.status == "afoot" and r.body and r.x) then return false end
  if C.activeId and C.activeId() == id then return false end
  local p = pos_of(to)
  if not (p and p.body == r.body) then return false end
  local l = math.sqrt(r.x * r.x + r.y * r.y + r.z * r.z)
  if l < 1e-6 then return false end
  local ux, uy, uz = r.x / l, r.y / l, r.z / l
  local dx, dy, dz = p.x - r.x, p.y - r.y, p.z - r.z
  local du = dx * ux + dy * uy + dz * uz
  dx, dy, dz = dx - ux * du, dy - uy * du, dz - uz * du
  local d = math.sqrt(dx * dx + dy * dy + dz * dz)
  if d < 1e-3 then return false end
  C.patch(id, { face = { x = dx / d, y = dy / d, z = dz / d } })
  return true
end
local function turn_beat(v) return turn_member(who_id(v.who), v.to) end

-- ── TALK GAZE (gy3, Ty 2026-11-11) ──────────────────────────────────────────
-- "Dana doesn't look at me when I talk. All NPCs when talking to me should
-- look at me, and if they're speaking to someone else they should look at
-- them." Every line a crew member says in person (never a radio voice):
--   the SPEAKER's head and eyes go to whoever it is said to: say.with (a
--     cast key or crew name), else the player; say.look = ref | false
--     overrides it for one line
--   the LISTENER (a crew body) looks back at the speaker
--   BYSTANDERS within TALK_SIDE_R of the speaker turn to them after a beat
--     (0.3-0.9 s) and drift back to what they were doing after a few seconds
-- A choice is a line to the player. Laid over a scenario's `look` while it
-- holds (crew_body.talkSelf, face.talkGaze), kept a moment after the line
-- (people do not snap away at the full stop), re-asserted at 4 Hz so a body
-- that respawned keeps it. Every point is asked the frame it is drawn (the
-- head's bone, the Astronaut's node): nothing is kept (frames doc rules 1-2);
-- crew_body smooths the turn and adds the looks away, face the saccades.
TALK_R = 12.0          -- m along the ground: past this the player is not who a line is said to
TALK_SIDE_R = 6.0      -- m: bystanders this close to a speaker turn to them
TALK_LINGER = 1.4      -- s a look is held after its line
local talk = { set = {}, astro = nil, chk = 0, live = false }
talkState = talk       -- (probes)
local function talk_astro()
  local a = talk.astro
  if not (a and a.valid ~= false) then a = find and find("Astronaut") or nil; talk.astro = a end
  return a
end
-- body-relative point of member id now (the player's node, a body's record)
local function talk_pos(id)
  local C = ref("crew")
  if not (C and id) then return nil end
  if id == (C.activeId and C.activeId()) then
    local pw = ref("planet_walker")
    if pw and pw.onFoot == false then return nil end
    return node_rel(talk_astro())
  end
  local r = C.get(id)
  if r and r.status == "afoot" and r.body and r.x then return { body = r.body, x = r.x, y = r.y, z = r.z } end
  return nil
end
local function talk_near(a, b, rr)
  local p, q = talk_pos(a), talk_pos(b)
  if not (p and q and p.body == q.body) then return false end
  local d = rulebook().groundApart(p, q)
  return d <= rr
end
-- the eyes of member id, world, THIS frame (drawn poses)
local function talk_head(id)
  local C = ref("crew")
  if not (C and id) then return nil end
  if id == (C.activeId and C.activeId()) then
    local pw = ref("planet_walker")
    if pw and pw.onFoot == false then return nil end
    local a = talk_astro()
    if not a then return nil end
    local x, y, z = a.x, a.y, a.z
    local wp = a.worldPos
    if wp and wp.x then x, y, z = wp.x, wp.y, wp.z end
    local d = space.dominant(x, y, z)
    local b = d and space.body(d)
    if not b then return nil end
    local ux, uy, uz = x - b.x, y - b.y, z - b.z
    local l = math.sqrt(ux * ux + uy * uy + uz * uz)
    return x + ux / l * 0.68, y + uy / l * 0.68, z + uz / l * 0.68
  end
  local cb = body_script("crew_body", id)
  if cb and cb.headPoint then
    local ok, x, y, z = pcall(cb.headPoint)
    if ok and x then return x, y, z end
  end
  return nil
end
-- a look at member `tid` (or at ref `tref`), weight w, from wall time t0 to t1
local function talk_fn(tid, tref, w, t0, t1)
  return function()
    if t0 or t1 then
      local tw = wall()
      if (t0 and tw < t0) or (t1 and tw > t1) then return nil end
    end
    local x, y, z
    if tref then x, y, z = pointOf(tref); if x then local p = pos_of(tref); local l = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z); x, y, z = x + p.x / l * 1.2, y + p.y / l * 1.2, z + p.z / l * 1.2 end
    else x, y, z = talk_head(tid) end
    if not x then return nil end
    return x, y, z, w
  end
end
local function talk_apply(id, e)
  if portraitBusy == id then e = nil end
  local cb = body_script("crew_body", id)
  if cb and cb.talkSelf then pcall(cb.talkSelf, e and e.fn or nil, e and e.mode or nil) end
  local fc = body_script("face", id)
  if fc then fc.talkGaze = e and e.fn or nil end
  return cb
end
local function talk_release(id)
  talk_apply(id, nil)
  talk.set[id] = nil
end
-- s: the line's speaker (show_line's), withKey: say.with, lookRef: say.look
function talkBegin(s, withKey, lookRef)
  local C = ref("crew")
  if not (C and s) then return end
  local act = C.activeId and C.activeId()
  local spk = (not s.radio and not s.garbled) and who_id(s.who) or nil
  local new = {}
  if spk then
    local lid = withKey and who_id(withKey) or nil
    if not lid and not withKey then lid = act end
    if lid == spk then lid = nil end
    if lid and not talk_near(spk, lid, TALK_R) then lid = nil end
    if spk ~= act then
      if lookRef ~= nil then
        if lookRef then new[spk] = { tgt = "ref:" .. tostring(lookRef), fn = talk_fn(nil, lookRef, 1), mode = "speak" } end
      elseif lid then new[spk] = { tgt = lid, fn = talk_fn(lid, nil, 1), mode = "speak" } end
    end
    if lid and lid ~= act then new[lid] = { tgt = spk, fn = talk_fn(spk, nil, 1), mode = "listen" } end
    -- the two in the conversation square up to each other: someone more
    -- than 50 deg off (past where the head alone goes) turns to face them
    -- (a standing body, not walking, not lying or sitting)
    local function square(id, tid)
      if not (id and tid) or id == act or walks[id] then return end
      local r, rt = C.get(id), C.get(tid)
      if not (r and rt and r.status == "afoot" and r.x and type(r.pose) ~= "table") then return end
      local q = talk_pos(tid)
      if not (q and q.body == r.body) then return end
      local f = type(r.face) == "table" and r.face or nil
      if f then
        local l = math.sqrt(r.x * r.x + r.y * r.y + r.z * r.z)
        local ux, uy, uz = r.x / l, r.y / l, r.z / l
        local dx, dy, dz = q.x - r.x, q.y - r.y, q.z - r.z
        local du = dx * ux + dy * uy + dz * uz
        dx, dy, dz = dx - ux * du, dy - uy * du, dz - uz * du
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if d < 0.3 or (f.x * dx + f.y * dy + f.z * dz) / d > 0.64 then return end
      end
      turn_member(id, "crew:" .. tostring(rt.name))
    end
    if lookRef == nil then square(spk, lid) end
    square(lid, spk)
    -- bystanders: on foot near the speaker, not lying down, not busy talking
    local nodes = C.bodyNodes and C.bodyNodes() or {}
    for id in pairs(nodes) do
      if id ~= spk and id ~= lid and id ~= act and not new[id] and talk_near(spk, id, TALK_SIDE_R) then
        local r = C.get(id)
        if not (r and type(r.pose) == "table" and r.pose.kind == "lie") then
          local t0 = wall() + 0.3 + math.random() * 0.6
          new[id] = { tgt = spk, fn = talk_fn(spk, nil, 0.75, t0, t0 + 3.0 + math.random() * 3.0), mode = "glance" }
        end
      end
    end
  end
  -- those not in this line let go after a moment; a look at the same person carries on
  for id, e in pairs(talk.set) do
    local n = new[id]
    if n and n.tgt == e.tgt and (e.mode ~= "glance" or n.mode == "glance") then
      local changed = n.mode ~= e.mode
      e.t1, e.mode = nil, n.mode
      if changed then e.cb = talk_apply(id, e) end
      new[id] = nil
    elseif not n then e.t1 = e.t1 or (wall() + TALK_LINGER) end
  end
  for id, e in pairs(new) do talk.set[id] = e; e.cb = talk_apply(id, e) end
  talk.live = true
end
-- per frame while a look is held: the line's end lets them go; 4 Hz, a
-- respawned body gets its look back
local function talk_tick()
  if not talk.live then return end
  local tw = wall()
  if not line and not choice then
    for _, e in pairs(talk.set) do if not e.t1 then e.t1 = tw + TALK_LINGER end end
  end
  if tw - talk.chk < 0.25 then return end
  talk.chk = tw
  local any = false
  for id, e in pairs(talk.set) do
    if e.t1 and tw >= e.t1 then talk_release(id)
    else
      any = true
      local cb = e.cb
      if not (cb and cb.valid ~= false and cb.memberId == id and cb.talkNow and cb.talkNow() == e.fn) then e.cb = talk_apply(id, e) end
    end
  end
  talk.live = any
end
-- (probes) where member id's head looks now, and at whom: → x, y, z, w, tgt
function talkLook(id)
  local cb = body_script("crew_body", id)
  local e = talk.set[id]
  if not (cb and cb.headLookNow) then return nil end
  local x, y, z, w = cb.headLookNow()
  return x, y, z, w, e and e.tgt or nil
end
talkHead = talk_head
turnMember = turn_member
-- (graveyard2) POSE: { who, kind = "lie" | "sit" | "stand", at = ref,
-- offset, height (m over the ref's ground: a bunk's mattress), head = ref
-- (lie: where the head goes) | facing = ref (sit: the way they face) }. The
-- record keeps where they stood, so getting up (stand, a walk, a switch)
-- starts there.
-- (graveyard2) GESTURE: { who, clip = "stand_talk" | "point" | "wave" |
-- "lean_console" | "kneel_work" | false, secs } — a body plays one of the
-- crew's pose clips (held without secs; false lets go). A walk ends it.
local function gesture_beat(v)
  local id = who_id(v.who)
  local C = ref("crew")
  if not (C and id) then return false end
  if v.clip == false or v.clip == nil then C.patch(id, { gesture = false }); return true end
  C.patch(id, { gesture = { clip = v.clip, t1 = v.secs and (now() + v.secs) or false } })
  return true
end
local function pose_beat(v)
  local id = who_id(v.who)
  local C = ref("crew")
  if not (C and id) then return false end
  if C.activeId and C.activeId() == id then say_log("pose: not on the member you control"); return false end
  -- (graveyard2 fix) `struct` + `spot = { x, y, z }` (+ `toward`): the surface
  -- in the STRUCTURE's own frame (x right, y up, z front of its record), so a
  -- bunk's mattress is its mattress whatever the ground under it does. A
  -- mark is a TERRAIN point: on a site with 0.5 m of spread the "mattress
  -- height over the mark" put Dana under the lower bunk.
  if v.struct and type(v.spot) == "table" and v.kind ~= "stand" then
    local ST = ref("structures")
    local sid = struct_id(tostring(v.struct):gsub("^struct:", ""))
    local rec = sid and ST and ST.get(sid)
    if not (rec and ST.frame) then return false end
    local ux, uy, uz, fx, fy, fz, rx, ry, rz = ST.frame(rec)
    local function at(s) return rec.x + rx * s[1] + ux * s[2] + fx * s[3], rec.y + ry * s[1] + uy * s[2] + fy * s[3], rec.z + rz * s[1] + uz * s[2] + fz * s[3] end
    local x, y, z = at(v.spot)
    local f = false
    if type(v.toward) == "table" then
      local tx, ty, tz = at(v.toward)
      local dx, dy, dz = tx - x, ty - y, tz - z
      local du = dx * ux + dy * uy + dz * uz
      dx, dy, dz = dx - ux * du, dy - uy * du, dz - uz * du
      local d = math.sqrt(dx * dx + dy * dy + dz * dz)
      if d > 1e-3 then f = { x = dx / d, y = dy / d, z = dz / d } end
    end
    local fields = { pose = { kind = v.kind, x = x, y = y, z = z, f = f, lift = v.lift } }
    local sp = v.stand and pos_of(v.stand)
    if sp and sp.body == rec.b then
      local sl = math.sqrt(sp.x * sp.x + sp.y * sp.y + sp.z * sp.z)
      if sl > 1e-6 then fields.x, fields.y, fields.z = sp.x * (sl + 1) / sl, sp.y * (sl + 1) / sl, sp.z * (sl + 1) / sl end
    end
    C.patch(id, fields)
    local cb = body_script("crew_body", id)
    if cb and cb.steerStop then pcall(cb.steerStop) end
    walks[id] = nil
    return true
  end
  if v.kind == "stand" or v.kind == false or not v.at then C.patch(id, { pose = false }); return true end
  local x, y, z, F = world_at(v.at, v.offset, v.height or 0)
  local p = pos_of(v.at)
  local b = p and space.body(p.body or "")
  if not (x and b) then return false end
  x, y, z = x - b.x, y - b.y, z - b.z
  local f = nil
  local to = v.head or v.facing
  local tp = to and pos_of(to)
  if tp and tp.body == p.body then
    local dx, dy, dz = tp.x - x, tp.y - y, tp.z - z
    local du = dx * F.ux + dy * F.uy + dz * F.uz
    dx, dy, dz = dx - F.ux * du, dy - F.uy * du, dz - F.uz * du
    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
    if d > 1e-3 then f = { x = dx / d, y = dy / d, z = dz / d } end
  end
  local fields = { pose = { kind = v.kind, x = x, y = y, z = z, f = f or false, lift = v.lift } }
  -- `stand = ref`: where they get up (the record's point, 1 m over that
  -- ground; crew_body settles it onto the floor)
  local sp = v.stand and pos_of(v.stand)
  if sp and sp.body == p.body then
    local sl = math.sqrt(sp.x * sp.x + sp.y * sp.y + sp.z * sp.z)
    if sl > 1e-6 then fields.x, fields.y, fields.z = sp.x * (sl + 1) / sl, sp.y * (sl + 1) / sl, sp.z * (sl + 1) / sl end
  end
  C.patch(id, fields)
  -- (a body walking there stops: the pose is where it ends)
  local cb = body_script("crew_body", id)
  if cb and cb.steerStop then pcall(cb.steerStop) end
  walks[id] = nil
  return true
end

-- LIGHT AND TIME (PLAN §2 F4). In Stars mode the engine lights the ground
-- from the star bodies, re-read every frame (floptle-editor shading.rs
-- sun_vec / star_uniforms: Light.direction is ignored while env.stars is
-- on), so holding the time of day switches the Lighting node to its
-- directional sun for the run and points it from the site: the real star's
-- azimuth, the held elevation, the star's colour and its strength at the
-- site (star_col_at: colour × min(k/d², 4)). A world does not spin (its day
-- is its year), so the direction is re-asserted with the goals (4 Hz) and
-- every frame only while an ease runs. Ambient goes through underground.lua's
-- one multiplier (scriptAmbient), a fog bank through weather.forceMist.
local LT = { hold = false }
local function lit_comp()
  local ln = find and find("Lighting")
  return ln and ln:getcomponent("Light") or nil
end
local function star_info()
  local h = sget("system.home")
  local n = type(h) == "table" and h.star and find and find(h.star)
  local cb = n and n:getcomponent("CelestialBody")
  if not cb then return nil end
  return n, cb
end
local function ease_val(e, t)
  if not e then return nil end
  local k = math.max(0, math.min(1, (t - e.t0) / math.max(e.secs, 0.01)))
  k = k * k * (3 - 2 * k)
  return e.from + (e.to - e.from) * k, k >= 1
end
local function site_up()
  -- the controlled member's staged spot, else the spaceport: body-relative,
  -- so its direction holds while the world moves
  local spots = sget("scn.spots") or {}
  for _, c in ipairs((sc.start and sc.start.crew) or {}) do
    if c.control and spots[c.name] then local s = spots[c.name]; return s.b, s.x, s.y, s.z end
  end
  local p = pos_of("base")
  if p then return p.body, p.x, p.y, p.z end
  return nil
end
local function apply_time(el)
  local l = lit_comp()
  if not l then return end
  local bn, ux, uy, uz = site_up()
  local b = bn and space.body(bn)
  local sn, cb = star_info()
  if not b then return end
  if LT.saved == nil then
    LT.saved = { stars = l.stars, dx = l.directionX, dy = l.directionY, dz = l.directionZ, i = l.intensity,
                 r = l.colorR, g = l.colorG, b = l.colorB }
  end
  local R_ = rulebook()
  local ul = math.sqrt(ux * ux + uy * uy + uz * uz)
  local u = { x = ux / ul, y = uy / ul, z = uz / ul }
  local sun, k = nil, 4
  if sn then
    local sx, sy, sz = sn.x - (b.x + ux), sn.y - (b.y + uy), sn.z - (b.z + uz)
    local d = math.sqrt(sx * sx + sy * sy + sz * sz)
    if d > 1 then sun = { x = sx / d, y = sy / d, z = sz / d }; k = math.min((cb.luminosity or 1) * 1e6 / (d * d), 4) end
  end
  local x, y, z = R_.heldSun(u, el, sun)
  l.stars = false
  l.directionX, l.directionY, l.directionZ = x, y, z
  -- the star's own colour (weather dims it under cloud), its strength here,
  -- fading out as the held sun goes under the horizon
  local fade = math.max(0, math.min(1, (el + 3) / 5))
  if cb then l.colorR, l.colorG, l.colorB = cb.starColorR or 1, cb.starColorG or 1, cb.starColorB or 1 end
  l.intensity = k * fade * (params and params.hold_gain or 1)
  local AT = ref("atmosphere")
  if AT then AT.sunUpOverride = math.sin(math.rad(el)) end
  -- (SC-5) a held night is dark: the sky dome and its bounce stay lit by the
  -- engine with the key light out, so the picture comes down with the sun,
  -- up to NIGHT_STOPS at 23 deg under the horizon (weather adds its own)
  local WXS = ref("weather")
  if WXS then WXS.exposureBias = (el < -3) and -(params and params.night_stops or 2.6) * math.min(1, (-3 - el) / 20) or nil end
  LT.el = el
end
local function release_time()
  local l = lit_comp()
  local s = LT.saved
  if l and s then
    l.stars = s.stars ~= false
    l.directionX, l.directionY, l.directionZ, l.intensity = s.dx, s.dy, s.dz, s.i
    l.colorR, l.colorG, l.colorB = s.r, s.g, s.b
  end
  LT.saved, LT.el, LT.hold, LT.elE = nil, nil, false, nil
  local AT = ref("atmosphere")
  if AT then AT.sunUpOverride = nil end
  local WXS = ref("weather")
  if WXS then WXS.exposureBias = nil end
end
local function set_ambient(k)
  local UG = ref("underground")
  if UG then UG.scriptAmbient = k end
  LT.amb = k
end
-- per frame only while an ease runs (a `light` beat with secs); else with the goals
local function light_tick(every_frame)
  -- (scn_dust) once the run is over an ease lands at once: the debrief holds
  -- the clock, so an ease begun in the closing cutscene never reached its end
  -- and re-placed the sun every frame of the stood-down runner (0.05 ms)
  local t = (phase == "running") and now() or math.huge
  if LT.elE then
    local v, fin = ease_val(LT.elE, t)
    apply_time(v)
    if fin then LT.elE = nil end
  elseif LT.hold and not every_frame and LT.el then apply_time(LT.el) end
  if LT.ambE then
    local v, fin = ease_val(LT.ambE, t)
    set_ambient(v)
    if fin then LT.ambE = nil; if LT.amb and math.abs(LT.amb - 1) < 1e-3 then set_ambient(nil) end end
  end
end
local function light_beat(v)
  local secs = v.secs or 0
  if v.time ~= nil then
    if v.time == false then release_time()
    else
      local el = rulebook().elevationOf(v.time)
      LT.hold = true
      if secs > 0 and LT.el then LT.elE = { from = LT.el, to = el, t0 = now(), secs = secs } else LT.elE = nil; apply_time(el) end
    end
  end
  if v.ambient ~= nil then
    local to = v.ambient == false and 1 or v.ambient
    local from = LT.amb or 1
    if secs > 0 then LT.ambE = { from = from, to = to, t0 = now(), secs = secs } else LT.ambE = nil; set_ambient(v.ambient ~= false and to or nil) end
  end
  if v.fog ~= nil then
    local wx = ref("weather")
    if wx and wx.forceMist then wx.forceMist(v.fog ~= false and v.fog or nil) end
    LT.fog = v.fog ~= false and v.fog or nil
  end
end
lightState = LT

-- WEATHER: { kind, secs, k = 1 } eased in with the goals (weather.force),
-- kind = false hands the sky back
local WX = nil
local function weather_beat(v)
  local wx = ref("weather")
  if not (wx and wx.force) then return end
  if v.kind == false then WX = nil; wx.force(nil); return end
  local kind = v.kind == "calm" and "clear" or v.kind
  if (v.secs or 0) > 0 then WX = { kind = kind, k = v.k or 1, t0 = agency_now(), secs = v.secs }; wx.force(kind, 0.05)
  else WX = nil; wx.force(kind, v.k or 1) end
end
local function weather_tick()
  if not WX then return end
  local wx = ref("weather")
  local k = math.max(0, math.min(1, (agency_now() - WX.t0) / WX.secs))
  if wx and wx.force then wx.force(WX.kind, math.max(0.05, WX.k * k)) end
  if k >= 1 then WX = nil end
end

-- BREAKER: { struct, part | uid, closed, trip } through base_power.setBreaker
local function breaker_beat(v)
  local BP = ref("base_power")
  local sid, uid = piece_of(v)
  if not (BP and BP.setBreaker and sid) then say_log("breaker: no " .. tostring(v.part or v.uid)); return end
  BP.setBreaker(sid, uid, v.closed ~= false, v.trip and "trip" or "hand")
end
W.breaker = function(t)
  local BP = ref("base_power")
  local sid, uid = piece_of(t)
  if not (BP and BP.breakerState and sid) then return nil end
  return BP.breakerState(sid, uid)
end
-- (scn_dust) is a Power Cable made off at structure sid burnt through?
W.cableBurnt = function(sid)
  local CB = ref("base_cable")
  if not (CB and CB.list) then return false end
  for _, c in ipairs(CB.list()) do
    if (c.a.sid == sid or c.z.sid == sid) and c.burnt then return true end
  end
  return false
end
-- a craft's part: { craft, part (id prefix) | uid } → the controller, uid
local function craft_part(t, mem)
  local name = tostring(t.craft or ""):gsub("^craft:", "")
  local v
  for _, vc in ipairs(vessels()) do if vc.craftName == name and not (vc.isLost and vc.isLost()) then v = vc end end
  if not v then return nil end
  if t.uid then return v, t.uid end
  if mem and mem.uid and mem.vid == (v.node and v.node.id) then return v, mem.uid end
  for _, d in ipairs((v.fleetParts and v.fleetParts()) or {}) do
    local id = tostring(d.id or "")
    if id == t.part or id:sub(1, #t.part + 1) == t.part .. "." then
      if mem then mem.uid, mem.vid = d.uid, v.node and v.node.id end
      return v, d.uid
    end
  end
  return nil
end
-- WEAR: { craft, part | uid, hp } (vessel_controller.wearPart)
local function wear_beat(v)
  local vc, uid = craft_part(v)
  if not (vc and vc.wearPart) then say_log("wear: no " .. tostring(v.part or v.uid) .. " on " .. tostring(v.craft)); return end
  vc.wearPart(uid, v.hp)
end
W.partHp = function(g, mem)
  local vc, uid = craft_part(g, mem)
  return vc and vc.partHp and vc.partHp(uid) or nil
end
-- MUSIC: a piece now (soundscape hushed while it plays) | false: silence
local music_h = nil
local function music_beat(v)
  local ss = ref("soundscape")
  if music_h and music_h.stop then pcall(music_h.stop, music_h) end
  music_h = nil
  if v == false then if ss and ss.hush then ss.hush(600) end return end
  if ss and ss.hush then ss.hush(400) end
  if audio and audio.play then
    local ok, h = pcall(audio.play, v, { track = "Music", volume = 0.8, mode = "Flat" })
    if ok then music_h = h end
  end
end

-- a structure piece's live state (copies): the hooks' api.piece and the
-- piece_state goal read this
local function piece_read(struct, part, uid)
  local sid, uid_, p = piece_of({ struct = struct, part = part, uid = uid })
  if not sid then return nil end
  local ST, RP = ref("structures"), ref("reactor_plant")
  local st = ST and ST.partState and ST.partState(sid, uid_) or {}
  local c = { id = p.id, uid = uid_, knocked = p.wr == true }
  for k, v in pairs(st) do if type(v) ~= "table" then c[k] = v end end
  if RP and RP.plantOfPart and RP.plantOfPart(sid, uid_) and RP.pumpOn then c.pumpOn = RP.pumpOn(sid, uid_) end
  -- (S6) a keypad's state and what a container holds
  local LT = ref("loot")
  if LT and LT.lockOf then
    c.lock = LT.lockOf(sid, uid_)
    c.locked = c.lock == "locked"
    -- (a container's count only when a goal or a meter asks for it: `items` is read through the metatable)
    if LT.containerAt(sid, uid_) then
      setmetatable(c, { __index = function(t, k) if k == "items" then local cc = S6.contents(sid, uid_); return cc and cc.total or 0 end end })
    end
  end
  -- (scn_dust) is it fed: `served` (a load the grid serves now; a tower its
  -- base's power), and `running` (switched on and served)
  local BG = ref("base_grid")
  if p.id == "tower" and p.base then
    local BT = ref("base_tower")
    local pw = BT and BT.power and BT.power(p.base)
    if pw then c.served = pw.powered == true end
  elseif BG and BG.partServed then
    local s = BG.partServed(sid, uid_)
    if s ~= nil then c.served = s end
  end
  c.running = (not c.off) and c.served ~= false
  -- (G4) a solar piece: the dust on its cells (0..1)
  if BG and BG.soilInfo and tostring(p.id):match("^solar") then c.dust = BG.soilInfo(sid, uid_).dust end
  return c
end
W.piece = function(g) return piece_read(g.struct, g.part, g.uid) end

-- ── S6 (the interaction plan §5.3): containers, keypads, log cards, tags,
-- the base log and the console, as data (scripts/loot.lua does the work) ──
S6 = {}
local function part_def(id) local pb = ref("parts_base"); return pb and pb.partInfo and pb.partInfo(id) or nil end
-- what container (sid, uid) holds: { items = { id = n }, mats = { mat = n }, total }
function S6.contents(sid, uid)
  local inv, LT = ref("inventory"), ref("loot")
  if not (inv and LT) then return nil end
  local cid = LT.cidOf(sid, uid)
  local out = { items = {}, mats = {}, total = 0 }
  for _, g in ipairs(inv.itemList(cid) or {}) do out.items[g.id] = g.n; out.total = out.total + g.n end
  for _, it in ipairs(inv.items(cid) or {}) do out.mats[it.mat] = it.n; out.total = out.total + it.n end
  return out
end
W.container = function(g)
  local sid, uid = piece_of(g)
  local LT = ref("loot")
  if not (sid and LT and LT.containerAt(sid, uid)) then return nil end
  return S6.contents(sid, uid)
end
-- one item's (or material's) count in a container: no list built (the goals run at 4 Hz)
W.containerCount = function(g, item, mat)
  local sid, uid = piece_of(g)
  local LT, inv = ref("loot"), ref("inventory")
  if not (sid and LT and inv and LT.containerAt(sid, uid)) then return nil end
  local cid = LT.cidOf(sid, uid)
  if item then return inv.itemCount(cid, item) or 0 end
  return inv.count(cid, mat) or 0
end
-- a light, a pump, a valve, a breaker, a machine: on? (nil: no switch)
W.switched = function(g)
  local sid, uid, p = piece_of(g)
  if not sid then return nil end
  local d = part_def(p.id) or {}
  local ST, FN, RP, RA, BP = ref("structures"), ref("fluid_net"), ref("reactor_plant"), ref("room_air"), ref("base_power")
  local st = ST and ST.partState and ST.partState(sid, uid) or nil
  if d.fl and FN and FN.isOn then return FN.isOn(sid, uid) == true end
  if d.pump and RP and RP.pumpOn then return RP.pumpOn(sid, uid) == true end
  if d.reject and RP then
    if d.reject.kind == "tower" and RP.towerOn then return RP.towerOn(sid, uid) == true end
    if RP.radiatorOpen then return RP.radiatorOpen(sid, uid) == true end
  end
  if d.life and RA and RA.machineOn then return RA.machineOn(sid, uid) == true end
  if d.power and d.power.kind == "breaker" and BP and BP.breakerState then return BP.breakerState(sid, uid) == "closed" end
  if d.light or d.switch or (d.power and d.power.kind == "load") then return not (st and st.off) end
  return nil
end
-- how many of `item` (or units of `mat`) who's pack holds
W.itemCount = function(who, item, mat)
  local inv, C = ref("inventory"), ref("crew")
  if not inv then return nil end
  local id = member_id(who)
  local cid = (id and C and C.packOf) and C.packOf(id) or (id and ("crew:" .. tostring(id))) or "astro"
  if item then return inv.itemCount and inv.itemCount(cid, item) or 0 end
  if mat then return inv.count and inv.count(cid, mat) or 0 end
  return nil
end
W.logRead = function(key) local LT = ref("loot"); return LT and LT.isRead and LT.isRead(key) or false end
-- the staging: log cards, containers, keypads, base-log lines (once per piece:
-- a setback's restaging does not fill a crate twice)
local function s6_done() local t = sget("scn.s6"); return type(t) == "table" and t or {} end
function S6.stage(st, out)
  local LT, inv, ST = ref("loot"), ref("inventory"), ref("structures")
  if not (LT and inv and ST) then
    if st.containers or st.locks or st.datalogs then out[#out + 1] = "S6: no loot rules in this scene" end
    return
  end
  local done = s6_done()
  local logs = {}
  for name, lg in pairs(type(st.datalogs) == "table" and st.datalogs or {}) do
    local codes = {}
    for _, c in ipairs(lg.codes or {}) do
      local sid, uid = piece_of(c)
      local pst = sid and ST.partState(sid, uid)
      local code = c.code
      if not code then
        for _, l in ipairs(st.locks or {}) do
          local lsid, luid = piece_of(l)
          if lsid == sid and luid == uid then code = l.code end
        end
      end
      code = code or (pst and pst.kp)
      if sid and code then codes[#codes + 1] = { sid = sid, uid = uid, code = code, label = c.label } end
    end
    logs[#logs + 1] = { key = name, title = lg.title, who = lg.who, when = lg.when, lines = lg.lines, text = lg.text, codes = codes, rp = lg.rp or 0, coords = lg.coords }
  end
  if #logs > 0 then LT.registerLogs(logs); out[#out + 1] = string.format("datalogs: %d", #logs) end
  for i, c in ipairs(type(st.containers) == "table" and st.containers or {}) do
    local sid, uid = piece_of(c)
    local key = string.format("c%d:%s:%s", i, tostring(sid), tostring(uid))
    if sid and LT.containerAt(sid, uid) and not done[key] then
      S6.fill(sid, uid, c, false)
      done[key] = true
      out[#out + 1] = string.format("container %d: %s #%s", i, tostring(c.part or c.uid), tostring(uid))
    elseif not sid or not LT.containerAt(sid, uid) then
      out[#out + 1] = string.format("container %d failed: no container %s in %s", i, tostring(c.part or c.uid), tostring(c.struct))
    end
  end
  for i, l in ipairs(type(st.locks) == "table" and st.locks or {}) do
    local sid, uid = piece_of(l)
    local key = string.format("l%d:%s:%s", i, tostring(sid), tostring(uid))
    if sid and not done[key] then
      local ok, why = LT.setCode(sid, uid, l.code, false)
      if ok and l.open then LT.enterCode(sid, uid, l.code, false) end
      done[key] = true
      out[#out + 1] = string.format("lock %d: %s #%s %s", i, tostring(l.part or l.uid), tostring(uid), ok and "on its code" or tostring(why))
    end
  end
  local BL = ref("base_log")
  for i, l in ipairs(type(st.logs) == "table" and st.logs or {}) do
    local sid = struct_id(tostring(l.struct or ""):gsub("^struct:", ""))
    local key = string.format("g%d:%s", i, tostring(sid))
    if sid and BL and BL.add and not done[key] then
      BL.add(sid, l.kind or "note", (l.when and ("[" .. l.when .. "] ") or "") .. l.text, l.who or false)
      done[key] = true
    end
  end
  sset("scn.s6", done)
end
-- put a bag into container (sid, uid): items (datalog:<name> included), parts, mats
function S6.fill(sid, uid, c, clear)
  local LT, inv = ref("loot"), ref("inventory")
  local cid = LT.cidOf(sid, uid)
  if clear then
    for _, g in ipairs(inv.itemList(cid) or {}) do inv.removeItem(cid, g.id, g.n) end
    inv.clear(cid)
  end
  for id, n in pairs(c.items or {}) do inv.addItem(cid, id, n, { force = true }) end
  for id, n in pairs(c.parts or {}) do inv.addItem(cid, "part:" .. id, n, { force = true }) end
  for m, n in pairs(c.mats or {}) do inv.add(cid, m, n) end
  if LT.remember then LT.remember(sid, uid) end
end
-- the beats: tag, log, container, lock, terminal
function S6.beat(k, v)
  local LT = ref("loot")
  if k == "tag" then
    local sid, uid = piece_of(v)
    local PI = ref("part_info")
    if sid and PI and PI.setTag then PI.setTag(sid, uid, v.name ~= false and v.name or nil) end
  elseif k == "log" then
    local sid = struct_id(tostring(v.struct or ""):gsub("^struct:", ""))
    local BL = ref("base_log")
    if sid and BL and BL.add then BL.add(sid, v.kind or "note", (v.when and ("[" .. v.when .. "] ") or "") .. v.text, v.who or false) end
  elseif k == "container" then
    local sid, uid = piece_of(v)
    if sid and LT and LT.containerAt(sid, uid) then S6.fill(sid, uid, v, v.clear == true)
    else say_log("container: no container " .. tostring(v.part or v.uid) .. " in " .. tostring(v.struct)) end
  elseif k == "lock" then
    local sid, uid = piece_of(v)
    if not (sid and LT) then say_log("lock: no piece " .. tostring(v.part or v.uid)); return end
    if v.code == false then
      if LT.lockOf(sid, uid) == "locked" then local ST = ref("structures"); local st = ST.partState(sid, uid); LT.enterCode(sid, uid, st and st.kp, false) end
      LT.clearCode(sid, uid, false)
    elseif v.code then
      LT.setCode(sid, uid, v.code, false)
      if v.open then LT.enterCode(sid, uid, v.code, false) end
    elseif v.open ~= nil then
      local ST = ref("structures")
      local st = ST and ST.partState(sid, uid)
      if v.open and st and st.kp then LT.enterCode(sid, uid, st.kp, false) elseif not v.open then LT.relock(sid, uid, false) end
    end
  elseif k == "terminal" then
    local T = ref("terminal")
    if not T then return end
    if v.close then if T.close then T.close() end return end
    local sid = struct_id(tostring(v.struct or ""):gsub("^struct:", ""))
    local uid = v.uid
    if sid and not uid then
      local ST = ref("structures")
      local rec = ST and ST.get(sid)
      for _, p in ipairs(rec and rec.bp or {}) do
        local d = part_def(p.id)
        if (not v.part and d and T.consoleKind and T.consoleKind(d, p, rec)) or (v.part and (p.id == v.part or tostring(p.id):sub(1, #v.part + 1) == v.part .. ".")) then uid = p.uid break end
      end
    end
    if sid and uid and T.openAt then local ok, why = T.openAt(sid, uid, v.page); if not ok then say_log("terminal: " .. tostring(why)) end end
  end
end

-- ── F8 (scenarios2 SC-4): DATA CORES and authored ruins ─────────────────────
-- A core (start.cores, or a `core` beat) sits in a piece: { id, struct, uid |
-- part, pages = { { date, text } }, who (the voice), title, power, air,
-- needs = goal, why, run (after the first read), open (instead of reading:
-- a sequence, e.g. a choice whose options read or seal it), label }.
--   * on a CONSOLE piece it is read on that console's CORE page (a terminal
--     page: the dated entries in phosphor lines); `run` follows when the
--     terminal is closed;
--   * on any other piece E reads it there (terminal.setSpot): its pages
--     as dialogue plates with the date as the plate's header, then `run`.
-- Its state is the variable core_<id> = "read" | "sealed" (so a checkpoint
-- keeps it and a branch or a score row reads it). It is read only when it
-- can be, for a physical reason: `power` (its structure's grid has power),
-- `air` (breathable air at it: the shock case is opened only in a room;
-- room_air.airAt at the piece), `needs` (any goal; `why` the words). The
-- career Data Core (ruins.pullCore, the lab) is untouched.
local CORE = { spots = nil, page = false, pend = {}, ver = nil, mem = {}, seen = {}, busy = {} }
local function core_defs()
  local out = {}
  for _, c in ipairs((sc and sc.start and type(sc.start.cores) == "table") and sc.start.cores or {}) do out[#out + 1] = c end
  for _, c in ipairs(type(sget("scn.coresx")) == "table" and sget("scn.coresx") or {}) do out[#out + 1] = c end
  return out
end
local function core_by(id) for _, c in ipairs(core_defs()) do if c.id == id then return c end end return nil end
W.coreState = function(id) return var("core_" .. tostring(id)) end
coreState = W.coreState
-- the host piece: → sid, uid, part, def
local function core_host(c)
  local sid, uid, p = piece_of({ struct = c.struct, part = c.part, uid = c.uid })
  if not sid then return nil end
  local pb = ref("parts_base")
  return sid, uid, p, pb and pb.partInfo and pb.partInfo(p.id) or nil
end
local function core_is_console(c)
  local sid, uid, p, d = core_host(c)
  local T = ref("terminal")
  local ST = ref("structures")
  if not (sid and T and T.consoleKind) then return false end
  return T.consoleKind(d, p, ST and ST.get(sid)) ~= nil
end
-- What the physical rules read for core c now
local function core_reads(c)
  local r = {}
  local sid, uid, p, d = core_host(c)
  if c.power then
    local s = sid and W.grid(sid)
    r.power = s ~= nil and s.powered == true and ((s.supply or 0) > 0 or (s.stored or 0) > 0)
  end
  if c.air then
    local ST, RA = ref("structures"), ref("room_air")
    local rec = sid and ST and ST.get(sid)
    if rec and p and ST.partPose and RA and RA.airAt then
      local px, py, pz = ST.partPose(rec, p, 0)
      local b = space.body(rec.b)
      if b and px then
        local l = math.sqrt(px * px + py * py + pz * pz)
        local h = (d and d.box and (d.box[3] + d.box[4]) / 2) or 0.5
        local ok, _, room = RA.airAt(b.x + px + px / l * h, b.y + py + py / l * h, b.z + pz + pz / l * h)
        -- air = "sealed": a sealed room round it, whatever it holds; true: breathable air
        if c.air == "sealed" then r.air = room ~= nil and room.sealed == true and not room.leaky
        else r.air = ok == true end
      end
    end
  end
  if c.needs then
    CORE.mem[c.id] = CORE.mem[c.id] or {}
    local ok, why = rulebook().evalGoal(c.needs, W, CORE.mem[c.id], { now = agency_now() })
    r.needs, r.needsWhy = ok, why
  end
  return r
end
function coreReadable(id)
  local c = type(id) == "table" and id or core_by(id)
  if not c then return false, "no such core" end
  return rulebook().coreReadable(c, core_reads(c))
end
local function core_refuse(why)
  local bc = ref("big_caption")
  if bc and bc.show then pcall(bc.show, "DATA CORE", tostring(why), 4.5, "story") end
  if audio and audio.play then pcall(audio.play, "audio/foley/key_strike.ogg", { track = "UI", volume = 0.3 }) end
  say_log("core refused: " .. tostring(why))
end
-- its pages as plates (front: inline, from a choice), then the state and `run`
local function core_play(c, front, cs, who, again)
  local list = {}
  for _, pg in ipairs(c.pages or {}) do
    list[#list + 1] = { say = { who = who or c.who or "ops", text = pg.text, header = pg.date } }
  end
  if not again then
    list[#list + 1] = { var = { ["core_" .. c.id] = "read" } }
    if c.run then list[#list + 1] = { run = c.run } end
  end
  -- (while its entries play, E on it does nothing: never read twice at once)
  CORE.busy[c.id] = true
  list[#list + 1] = { core = { done = c.id } }
  say_log("core " .. tostring(c.id) .. (again and " read again" or " read"))
  queue_beats(list, "core:" .. c.id, front, cs)
end
-- E on the core's piece
local function core_open(c)
  if CORE.busy[c.id] then return end
  local st = W.coreState(c.id)
  if st == "sealed" then core_refuse("the case is sealed: Hendry's tape across the latch"); return end
  local ok, why = rulebook().coreReadable(c, core_reads(c))
  if not ok then core_refuse(why); return end
  if st ~= "read" and c.open then run_seq(c.open, false); return end
  core_play(c, false, nil, nil, st == "read")
end
-- The CORE page of a console (terminal.registerPage): its own core's entries
local function core_page(scope)
  local rows = {}
  local any = false
  for _, c in ipairs(core_defs()) do
    local sid, uid = core_host(c)
    if sid == scope.sid and uid == scope.uid then
      any = true
      rows[#rows + 1] = { type = "header", label = "DATA CORE · " .. tostring(c.title or c.id) }
      local st = W.coreState(c.id)
      local ok, why = rulebook().coreReadable(c, core_reads(c))
      if st == "sealed" then rows[#rows + 1] = { type = "line", text = "SEALED UNREAD", level = 2 }
      elseif not ok then rows[#rows + 1] = { type = "line", text = string.upper(tostring(why)), level = 2 }
      else
        for _, pg in ipairs(c.pages or {}) do
          if pg.date then rows[#rows + 1] = { type = "line", text = pg.date, level = 1 } end
          for _, l in ipairs(rulebook().coreLines(pg.text, 96)) do rows[#rows + 1] = { type = "line", text = l } end
        end
        -- (read once it has been on screen; the state and the reaction land
        -- when the terminal is closed, so the story never talks over the CRT)
        if st ~= "read" and not CORE.seen[c.id] then
          CORE.seen[c.id] = true
          say_log("core " .. tostring(c.id) .. " read at a console")
          CORE.pend[#CORE.pend + 1] = c
        end
      end
    end
  end
  if not any then rows[#rows + 1] = { type = "line", text = "NO DATA CORE IN THIS TERMINAL'S SLOT", level = 1 } end
  return rows
end
-- (4 Hz, with the goals) the page and the spots, the reactions held while a terminal is open
local function cores_tick()
  local defs = core_defs()
  if #defs == 0 then return end
  local T, ST = ref("terminal"), ref("structures")
  if not T then return end
  if CORE.page ~= T and T.registerPage then
    T.registerPage("CORE", core_page, { order = 4, title = "CORE", scopes = { ruin = true, desk = true } })
    CORE.page = T
    CORE.spots = nil
  end
  if T.setSpot and (CORE.spots ~= T or CORE.ver ~= #defs) then
    for _, c in ipairs(defs) do
      local sid, uid = core_host(c)
      if sid and not core_is_console(c) then
        local cc = c
        T.setSpot("core:" .. c.id, { sid = sid, uid = uid,
          label = function()
            local st = W.coreState(cc.id)
            if st == "read" then return cc.againLabel or "Read the Data Core again" end
            if st == "sealed" then return "The Data Core · sealed" end
            return cc.label or "Open the Data Core"
          end,
          on = function() return not CORE.busy[cc.id] end,
          act = function() core_open(cc) end })
      end
    end
    CORE.spots, CORE.ver = T, #defs
  end
  if #CORE.pend > 0 and not (T.isOpen and T.isOpen()) then
    local p = CORE.pend
    CORE.pend = {}
    for _, c in ipairs(p) do
      setVar("core_" .. c.id, "read")
      if c.run then run_seq(c.run, false) end
    end
  end
end
-- the `core` beat: { read = id [, who] } | { seal = id } | a whole core placed
local function core_beat(v, e)
  if v.done then CORE.busy[v.done] = nil; return end
  if v.read then
    local c = core_by(v.read)
    if c then core_play(c, true, e and e.cs, v.who, W.coreState(c.id) == "read") end
  elseif v.seal then
    setVar("core_" .. tostring(v.seal), "sealed")
    say_log("core " .. tostring(v.seal) .. " sealed")
    local bc = ref("big_caption")
    if bc and bc.show then pcall(bc.show, "DATA CORE SEALED", "unread · for Hendry Resources' counsel", 4.0, "story") end
  elseif v.id then
    local x = type(sget("scn.coresx")) == "table" and sget("scn.coresx") or {}
    x[#x + 1] = v
    sset("scn.coresx", x)
    CORE.ver = nil
  end
end
-- a ruin's state for the `ruin` goal: { claimed, missing, cost, funds }
W.ruin = function(sid, lot)
  local ST, RU, co = ref("structures"), ref("ruins"), ref("company")
  local rec = ST and ST.get(sid)
  if not (rec and rec.ru and RU and RU.restoreQuote) then return nil end
  local q = RU.restoreQuote(rec.ru, lot)
  return { claimed = RU.claimed and RU.claimed(rec.ru) or false, missing = q.n, cost = q.cost, funds = co and co.balance and co.balance() or 0 }
end

local hooks_api
local function run_beat(b, e)
  local k, v = next(b)
  local in_cut = e and e.cs ~= nil
  if k == "cutscene" then if e and e.cs then cut_begin(e.cs) end
  elseif k == "ops" then local s = ops_line(v); beat_busy = { kind = "line", t1 = now() + s.secs }
  elseif k == "say" then
    -- FW-C: a voice with a light-time (cast `delay`, or the line's own) is
    -- heard that many game seconds after its beat; the queue does not wait
    local who = v.who or v[1]
    local d = v.delay
    if d == nil then local s0 = speaker(who); d = s0.delay end
    if not v._now and type(d) == "number" and d > 0 then
      delay_line({ who = who, text = v.text or v[2], secs = v.secs, with = v.with, wait = v.wait }, d)
      return nil
    end
    local s = show_line(who, v.text or v[2], v.secs, v)
    -- (graveyard2) say.cross: the next line cuts in a second before this one
    -- ends (one voice over another: "Kovac over Hana")
    if v.wait ~= false then beat_busy = { kind = "line", t1 = now() + (v.cross and math.max(0.6, s.secs - 1.0) or s.secs) } end
  elseif k == "choice" then
    local s = speaker(v.who)
    local texts = {}
    for i, o in ipairs(v.options or {}) do texts[i] = o.text end
    choice = { who = s.who, name = s.name, color = s.color, tag = s.tag, portrait = s.portrait, radio = s.radio,
               prompt = v.prompt, options = texts, opts = v.options or {},
               t0 = now(), timeout = v.timeout, default = v.default or 1 }
    say_log("choice up: " .. tostring(v.prompt))
    -- (gy3) a question is put to the player: asked looking at them
    if talkBegin then pcall(talkBegin, { who = v.who, radio = s.radio }, nil, nil) end
    bump()
    emit("choice", choice)
    beat_busy = { kind = "choice", t1 = v.timeout and (now() + v.timeout) or math.huge }
  elseif k == "run" then run_seq(v, true, e and e.cs)
  elseif k == "caption" then
    local bc = ref("big_caption")
    -- (scn_dust) `kind`: big_caption's alarm | story | result | info | quiet (default story)
    if bc and bc.show then bc.show(v.title or v[1] or "", v.sub or v[2] or "", v.secs or v[3] or 4.0, v.kind or "story") end
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
  elseif k == "state" and v.craft then
    -- (scn_vacuum) a craft part's own state: a hatch (`hatch`, `ph`), a
    -- reactor's `output` / `critical`, a regulator (`creg`)…, as its menu sets it
    local vc, uid = craft_part(v)
    if vc and vc.partSt then
      for n, x in pairs(v.st or {}) do vc.partSt(uid, n, x, true) end
      local CA = ref("cabin_air")
      if CA and CA.touch then pcall(CA.touch, vc) end
    else say_log("state: no " .. tostring(v.part or v.uid) .. " on " .. tostring(v.craft)) end
  elseif k == "state" then
    local sid, uid = piece_of(v)
    local ST = ref("structures")
    if sid and ST.setPartState then
      local cur = ST.partState(sid, uid) or {}
      for n, x in pairs(v.st or {}) do cur[n] = x end
      ST.setPartState(sid, uid, cur)
      -- (scn_dust) a door's seal or state changed: room_air's networks again
      -- now (its valves were cached: a blown seal vented only when something
      -- else next moved a door, up to a minute later)
      local RA = ref("room_air")
      if RA and RA.doorMoved then pcall(RA.doorMoved, sid, uid) end
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
    local id = who_id(v.who)
    if id then
      walks[id] = { to = v.to, offset = v.offset, t1 = now() + (v.secs or 20), who = v.who, speed = v.speed,
                    near = v.near, face = v.face, pose = v.pose }
      -- (graveyard2) wait = true: the story holds until they get there
      if v.wait then beat_busy = { kind = "walk", id = id, t1 = now() + (v.secs or 20) + 0.5 } end
      local C = ref("crew")
      if C and C.patch then C.patch(id, { pose = false, gesture = false }) end
    end
  elseif k == "give" then give(v)
  elseif k == "funds" then local co = ref("company"); if co then if v >= 0 then co.earn(v, "scenario") else co.spend(-v, "scenario") end end
  elseif k == "unlock" then local rs = ref("research"); if rs and rs.grant then rs.grant(v, "scenario") end
  elseif k == "mark" and CAREER then
    -- (missions S0) a career mark lives in the run (the contract's own)
    if v.at then
      local g = resolve_at(v.at, v.offset)
      if g then CAREER.marks[v.name] = { b = g.body, x = g.x, y = g.y, z = g.z } end
    end
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
  -- FW-C
  elseif k == "face" then face_beat(v)
  elseif k == "look" then look_beat(v)
  elseif k == "turn" then turn_beat(v)
  elseif k == "pose" then pose_beat(v)
  elseif k == "gesture" then gesture_beat(v)
  elseif k == "light" then light_beat(v)
  elseif k == "weather" then weather_beat(v)
  elseif k == "breaker" then breaker_beat(v)
  elseif k == "wear" then wear_beat(v)
  elseif k == "music" then music_beat(v)
  elseif k == "tag" or k == "log" or k == "container" or k == "lock" or k == "terminal" then S6.beat(k, v)
  elseif k == "core" then core_beat(v, e)      -- F8
  -- SC-5
  elseif k == "drive" then SC5R.drive(v)
  elseif k == "board" then SC5R.board(v)
  elseif k == "place" then SC5R.place(v)
  elseif k == "charge" then SC5R.charge(v)
  -- storypolish: UNTIL { kind = <goal kind>, …, secs }: the queue holds until
  -- the goal holds (a rover pulled up at its mark, a member through a door),
  -- or `secs` (default 30) run out. A cutscene's skip drops it.
  -- storypolish: PORTRAIT "<cast key | crew name>": their live picture taken
  -- again, now (Beck's was taken in a dark rover seat; this, in the lit room)
  elseif k == "portrait" then
    local c = sc and sc.cast and sc.cast[v]
    local nm = (c and c.crew) or v
    if portraitFor then portraitFor(nm, true) end
  elseif k == "until" then
    beat_busy = { kind = "until", g = v, mem = {}, t1 = now() + (v.secs or 30) }
  end
  return nil
end
runBeat = run_beat

-- a walking crew member: a CrewBody is set down at the mark when the walk
-- ends (crew_body has no path steering yet); the controlled one, in a
-- cutscene, is steered there by planet_walker.steer
WALK_STUCK = 6.0      -- s a walk may go without getting 0.4 m nearer before it plans again
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
      elseif not active_ then
        -- FW-C: their CrewBody walks there (crew_body.steerTo: the target
        -- handed over body-relative, re-read from the ref every frame); a
        -- walk out of time, skipped, or with no body in range is set down
        -- (the body's script found once a walk, not a scene walk a frame)
        if not (w.cb and w.cb.valid ~= false and w.cb.memberId == id) and now() >= (w.look_t or 0) then
          w.cb = body_script("crew_body", id)
          if not w.cb then
            w.look_t = now() + 0.5
            -- (gy3) no body to walk (out of range, between spawns) for 3 s: set down now
            w.nob = w.nob or now()
            if now() - w.nob > 3.0 then w.t1 = math.min(w.t1, now()); w.instant = true end
          else w.nob = nil end
        end
        local cb = (not w.instant and now() <= w.t1) and w.cb or nil
        -- (graveyard2) arrived is asked BEFORE the target is handed over again:
        -- a steer after the stop starts a new walk and clears the flag, so
        -- the walk never ended on arrival (only on its time-out)
        if cb and w.steered and cb.arrived and cb.arrived() and not (cb.walking and cb.walking()) then
          walks[id] = nil
          if w.face then turn_member(id, w.face) end
          if w.pose then local pz = {}; for k2, x2 in pairs(w.pose) do pz[k2] = x2 end; pz.who = w.who; pose_beat(pz) end
        elseif cb and cb.steerSelf and cb.steerSelf(p.body, x - b.x, y - b.y, z - b.z, { speed = w.speed, arrive = w.near }) then
          w.steered = true
          -- (gy3, Ty: "she still doesn't go to the bedroom") a walk that stops
          -- closing on its target for WALK_STUCK s plans its route again from
          -- where it stands; after two of those it is set down there and goes
          -- on with its pose: a crew member never stands idle after their line
          if cb.walkDist then
            local d = cb.walkDist(p.body, x - b.x, y - b.y, z - b.z)
            local tn = now()
            if d and (not w.best or d < w.best - 0.4) then w.best, w.best_t = d, tn
            elseif d and w.best_t and tn - w.best_t > WALK_STUCK and not (cb.planning and cb.planning()) then
              w.replans = (w.replans or 0) + 1
              w.best_t = tn
              say_log(string.format("walk %s: stuck %.1f m short, %s", tostring(w.who), d, w.replans <= 2 and "a new route" or "set down there"))
              if w.replans <= 2 and cb.replan then cb.replan() else w.t1 = tn; w.instant = true; w.stuck = true end
            end
          end
        elseif now() > w.t1 - (w.instant and w.t1 or 0) then
          local cb2 = w.steered and w.cb or nil
          if cb2 and cb2.steerStop then cb2.steerStop() end
          local far = true
          if cb2 and cb2.walkDist then local d = cb2.walkDist(p.body, x - b.x, y - b.y, z - b.z); far = d == nil or d > 2.0 end
          -- (graveyard2) a walk up to someone (near =) is never set down on
          -- top of them; a set-down lands on a free spot, never in a wall
          if (far or w.instant) and not w.near then
            local l = math.sqrt((x - b.x) ^ 2 + (y - b.y) ^ 2 + (z - b.z) ^ 2)
            local sx, sy, sz = b.x + (x - b.x) * (l + 0.5) / l, b.y + (y - b.y) * (l + 0.5) / l, b.z + (z - b.z) * (l + 0.5) / l
            if C.freeSpot then sx, sy, sz = C.freeSpot(sx, sy, sz) end
            if C.setDown then C.setDown(id, sx, sy, sz) end
          end
          walks[id] = nil
          if w.face then turn_member(id, w.face) end
          if w.pose then local pz = {}; for k2, x2 in pairs(w.pose) do pz[k2] = x2 end; pz.who = w.who; pose_beat(pz) end
        end
      end
    end
    -- (scnfix) a walk to a craft's seat (SC5R.board) ends in the seat
    if walks[id] == nil and w.board then local bv = w.board; w.board = nil; SC5R.board(bv) end
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
    if k == "walk" then local id2 = who_id(v.who); if id2 then walks[id2] = { to = v.to, offset = v.offset, t1 = now(), instant = true, near = v.near, face = v.face, pose = v.pose, who = v.who } end
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
  if beat_busy and beat_busy.kind == "walk" and not walks[beat_busy.id] then beat_busy = nil end
  -- (storypolish) an `until` beat: its goal read every frame (one goal: cheap)
  if beat_busy and beat_busy.kind == "until" then
    local t = agency_now()
    local ok = rulebook().evalGoal(beat_busy.g, W, beat_busy.mem, { now = t, t0 = tonumber(sget("scn.t0")) or t, done = done_tbl and done_tbl() or {} })
    if ok then beat_busy = nil end
  end
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
  -- (perfmap 2026-11-11) the siting search asks this hundreds of times, five
  -- rays each, and a ray over ground still streaming costs milliseconds: a
  -- spawn beat in play (Dust Season's Beck at far_flat) ran 30-50 ms frames.
  -- Staging and spawn jobs are coroutines, so the search gives the frame back
  -- after 2 ms of rays in play, 8 behind the curtain (the body is read again each ray: rule 1).
  local ray_t0 = wall()
  local gm_ = ref("game_manager")
  local ray_ms = (gm_ and gm_.curtain) and 8.0 or 2.0   -- (behind the curtain nobody sees the frame)
  -- (and one ray over far ground was measured at 14-29 ms by itself: no ray
  -- at all where nothing is built within 80 m. What is built, body-relative,
  -- read once: the structures on this world and the craft on it.)
  local built = {}
  do
    local STr = ref("structures")
    for _, rec in ipairs((STr and STr.list) and STr.list() or {}) do
      if rec.b == b.name and rec.x then built[#built + 1] = { rec.x, rec.y, rec.z } end
    end
    local bb0 = space.body(b.name) or b
    for _, v in ipairs(findScripts and findScripts("vessel_controller") or {}) do
      local n = v.node
      if n and n.valid ~= false then built[#built + 1] = { n.x - bb0.x, n.y - bb0.y, n.z - bb0.z } end
    end
    -- (the spaceport's buildings, runway and pads: half a kilometre round it)
    local bf = ref("base_facilities")
    if bf and bf.baseBody == b.name and bf.baseX then built[#built + 1] = { bf.baseX - bb0.x, bf.baseY - bb0.y, bf.baseZ - bb0.z, 500 } end
  end
  local function near_built(px, py, pz)
    for _, q in ipairs(built) do
      local rr = q[4] or 80
      if (q[1] - px) ^ 2 + (q[2] - py) ^ 2 + (q[3] - pz) ^ 2 < rr * rr then return true end
    end
    return false
  end
  local function clear(dir, r)
    if not raycast then return true end
    if not near_built(dir.x * r, dir.y * r, dir.z * r) then return true end
    local F = rulebook().groundFrame(dir.x, dir.y, dir.z)
    for _, o in ipairs({ { 0, 0 }, { 8, 0 }, { -8, 0 }, { 0, 8 }, { 0, -8 } }) do
      if (wall() - ray_t0) * 1000 > ray_ms and coroutine.isyieldable and coroutine.isyieldable() then
        coroutine.yield()
        ray_t0 = wall()
      end
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
  -- (graveyard2) the siting search asks the ground hundreds of times; on a
  -- loaded machine it ran past the 2 s a script may run without returning
  -- ("STAGING ERROR … a loop without an exit?", seen twice). Staging is a
  -- coroutine: the ground query yields a frame every 8 calls, and the body
  -- is read again after each yield (the planet moved: frames doc rule 1).
  local g0 = ground_of(b)
  local gq = 0
  local function ground(dir)
    gq = gq + 1
    if (gq % 8 == 0 or (wall() - ray_t0) * 1000 > ray_ms) and coroutine.isyieldable and coroutine.isyieldable() then
      coroutine.yield()
      ray_t0 = wall()
      local nb = space.body(b.name or "")
      if nb then b.x, b.y, b.z = nb.x, nb.y, nb.z end
    end
    return g0(dir)
  end
  return { R = l, u = u, t1 = t1, t2 = t2, ground = ground, sun = sd, vel = sv, clear = clear,
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
      -- (gy3, Ty 2026-11-11) the record wears the cast's full name ("Dana
      -- Kowalczyk", not "Kowalczyk"), and a cast member the player does not
      -- play is no one the switcher offers (crew.lua's `npc`); refs keep the
      -- start.crew name (`crew:Kowalczyk`, through scn.crew)
      local R_ = rulebook()
      C.rename(id, R_.crewDisplayName and R_.crewDisplayName(sc, c.name) or c.name)
      C.patch(id, { npc = not (R_.playableOf and R_.playableOf(sc, c) or c.control) })
      if c.role then C.patch(id, { role = c.role }) end
      -- (graveyard2) what they are, in words: the strip, the picker, the tag
      C.patch(id, { title = type(c.title) == "string" and c.title or false })
      -- FW-C: a cast `look` seed pins this member's face (else the generator's, random)
      local CF = ref("crew_faces")
      for _, cc in pairs((sc and sc.cast) or {}) do
        if cc.crew == c.name and type(cc.look) == "number" and CF and CF.lookFor then
          local okl, L = pcall(CF.lookFor, cc.look, id, c.name)
          if okl and type(L) == "table" then C.patch(id, { look = L }) end
        end
      end
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
      local g
      if e.along then
        -- (SC-5) along the ground between two refs (scenario.alongPoint)
        -- (a crew ref at stage time reads the staged spot)
        local function rp(r)
          local k, nm = rulebook().parseRef(r)
          local s = k == "crew" and (sget("scn.spots") or {})[nm]
          if s then return { body = s.b, x = s.x, y = s.y, z = s.z } end
          return pos_of(r)
        end
        local p, q = rp(e.along[1]), rp(e.along[2])
        local b = p and q and p.body == q.body and space.body(p.body)
        if b then
          g = rulebook().alongPoint(p, q, e.frac or 0.5, e.offset, ground_of(b))
          g.body = p.body
        end
      else g = resolve_stage(e.at, e.offset) end
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
        -- (scn_dust) `powered = 0.71`: the banks at that share, not full
        local frac = type(e.powered) == "number" and e.powered or nil
        if BG.chargeFull(e.sid, frac) then powered = true; out[#out + 1] = string.format("%s: batteries %s", tostring(e.name), frac and string.format("at %d %%", math.floor(frac * 100 + 0.5)) or "full") end
      end
      coroutine.yield()
    end
    if not aired then out[#out + 1] = tostring(e.name) .. ": rooms never solved (no air staged)" end
    if not powered then out[#out + 1] = tostring(e.name) .. ": no grid store to charge" end
  end
  lived_in = {}
end

-- crew at their posts (`post = ref`, after the marks and structures exist)
POST_STAND = 1.03      -- the Astronaut's capsule centre over the floor it stands on (2.0 m tall) + a hair
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
        -- (gy3, Ty 2026-11-11: "graveyard shift spawned me in the ground")
        -- a post is a TERRAIN point, and the capsule's centre was put 1 m
        -- over it: on a station floor that stands 0.2-0.7 m over the
        -- terrain the legs were in the slab and stayed there (a switch
        -- freed them). The floor under the post is found by a ray down from
        -- inside the room (1.3 m over the terrain: over any slab, under any
        -- ceiling) and the capsule stands on it; only the ray's DISTANCE is
        -- kept (frames doc rule 2), as a height over the terrain point.
        -- (asked again every frame of the hold: a structure's colliders can
        -- come in a few frames after its record, and a first ray then met
        -- only the terrain; the highest floor found wins)
        local lift = 1.0
        local ux, uy, uz = g.x / l, g.y / l, g.z / l
        local function floor_lift()
          b = space.body(g.body)
          if not (a and b and raycast) then return end
          local o = 1.3
          local ok, h = pcall(raycast, b.x + g.x + ux * o, b.y + g.y + uy * o, b.z + g.z + uz * o, -ux, -uy, -uz, 3.0, a)
          if ok and h and h.distance and h.distance < 2.9 then lift = math.max(lift, o - h.distance + POST_STAND) end
        end
        for _ = 1, 60 do
          floor_lift()
          k = (l + lift) / l
          b = space.body(g.body)
          if not (a and b) then break end
          a.x, a.y, a.z = b.x + g.x * k, b.y + g.y * k, b.z + g.z * k
          a.vx, a.vy, a.vz = 0, 0, 0
          coroutine.yield()
        end
        out[#out + 1] = string.format("post %s: stands %.2f m over the terrain point", c.name, lift)
        -- (graveyard2) the player's view turned to their post's `face` (a
        -- direction: planet_camera flattens it onto the ground next frame)
        local fp = c.face and pos_of(c.face)
        local pc = ref("planet_camera")
        if fp and fp.body == g.body and pc and pc.face then
          pcall(pc.face, fp.x - g.x, fp.y - g.y, fp.z - g.z, 0)
        end
      elseif C and C.setDown then
        C.setDown(id, b.x + g.x * k, b.y + g.y * k, b.z + g.z * k)
        -- (graveyard2) the way they face at their post (`face = ref`);
        -- without one crew_body turns them to the most open way
        if c.face then turn_member(id, c.face) else C.patch(id, { face = false }) end
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

-- (F8) start.ruins: a blueprint stamped as a decayed ruin (ruins.stampAuthored)
-- at its mark, found and touched; a ruin of that name already standing (a
-- checkpoint's stage) is only claimed and restored (`claimed`, `restore`)
local function stage_ruins(list, out)
  if type(list) ~= "table" or #list == 0 then return end
  local ST, BPs, RU = ref("structures"), ref("blueprints"), ref("ruins")
  if not (ST and BPs and RU and RU.stampAuthored) then out[#out + 1] = "ruins: no ruins script in this scene" return end
  local map = sget("scn.structs") or {}
  for _, r in ipairs(list) do
    local sid = r.name and map[r.name]
    if sid and not ST.get(sid) then sid = nil end
    if not sid and r.bp then
      local code = rulebook().readText(sc._dir .. r.bp)
      local bp, why = nil, "no file"
      if code then bp, why = BPs.decode(code) end
      local g = bp and resolve_stage(r.at or "base", r.offset, r.yaw)
      -- `flat = radius`: the nearest ground that is flat over that circle
      -- (the author's mark, or rings out from it: a camp is never half buried)
      if g and type(r.flat) == "number" and RU.flatSpot then
        local fx, fy, fz, sp = RU.flatSpot(g.body, g.x, g.y, g.z, r.flat, r.flatSpread or 1.2)
        local b = space.body(g.body)
        if fx and b then
          local g2 = rulebook().offsetPoint({ x = fx, y = fy, z = fz }, nil, ground_of(b), r.yaw)
          if g2 then g2.body = g.body; g = g2 end
          out[#out + 1] = string.format("ruin %s: flat ground (%.2f m over %.0f m)", tostring(r.name), sp or -1, r.flat)
        end
      end
      if bp and g then
        sid, why = RU.stampAuthored(r, bp.pieces, g, agency_now())
        if sid then map[r.name] = sid; sset("scn.structs", map) end
      end
      out[#out + 1] = sid and string.format("ruin %s: structure #%s", tostring(r.name), tostring(sid))
                      or string.format("ruin %s failed: %s", tostring(r.name), tostring(why or "no ground"))
      frames(2)
    end
    local rec = sid and ST.get(sid)
    if rec and rec.ru then
      if r.claimed and not RU.claimed(rec.ru) then RU.claim(rec.ru, nil, true); out[#out + 1] = "ruin " .. tostring(r.name) .. ": claimed" end
      for _, lot in ipairs(type(r.restore) == "table" and r.restore or {}) do
        local n = RU.restore(rec.ru, true, lot)
        out[#out + 1] = string.format("ruin %s: %s restored (%s)", tostring(r.name), tostring(lot), tostring(n))
      end
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
    -- (SC-5) a landed craft: written to the fleet the right way up where it
    -- stands and rebuilt there by flight_ops, no pad, no rollout
    elseif wh.ground and SC5R then SC5R.stageGround(i, c, bp, wh, out)
    elseif not (VS and VS.launchNow) then out[#out + 1] = "craft: no vessel spawner"
    else
      -- (scn_vacuum) crew = { { who, part | uid, slot } }: the seat plan
      -- (bp.crew, vessel_controller's launch plan) by the start crew's names
      if type(c.crew) == "table" and #c.crew > 0 then
        local plan, map = {}, crew_ids()
        for _, e in ipairs(c.crew) do
          local id = map[e.who]
          local uid = e.uid
          if not uid and e.part then
            for _, d in ipairs(bp.parts) do
              local pid = tostring(d.id or "")
              if pid == e.part or pid:sub(1, #e.part + 1) == e.part .. "." then uid = d.uid; break end
            end
          end
          if id and uid then plan[#plan + 1] = { uid = uid, slot = e.slot or 1, id = id } end
        end
        local b2 = {}
        for k2, x in pairs(bp) do b2[k2] = x end
        b2.crew = plan
        bp = b2
        -- the crew launch IN it, as the builder's LAUNCH does (vessel_controller
        -- seats them on its first tick only with this flag)
        sset("shipyard.pilot", 1)
      end
      -- (scn_vacuum) the controller reads the launch's blueprint from the
      -- save, as after the builder's LAUNCH: without this it flew whatever the
      -- shipyard held last (a probe: no crew, no cabins)
      sset("shipyard.blueprint", bp)
      local ok, why = VS.launchNow(wh.runway and "runway" or "pad", { bp = bp, force = true })
      out[#out + 1] = string.format("craft %d (%s): rollout %s %s", i, tostring(c.file), tostring(ok), tostring(why or ""))
      -- (scn_vacuum) until it is assembled AND flown: "ready" can come a few
      -- frames before the controller takes the craft (piloted() was nil, so
      -- the name, the seats and the orbit were skipped). Wall clock: the
      -- game clock may stand still while the curtain is up.
      local t1 = wall() + 90
      while wall() < t1 do
        local ls = VS.launchState and VS.launchState()
        local pv = piloted()
        if ls ~= "waiting" and ls ~= "assembling" and pv and pv.node and pv.node.valid then break end
        coroutine.yield()
      end
      local vc = piloted()
      if not vc then out[#out + 1] = string.format("craft %d: never flown (launch %s)", i, tostring(VS.launchState and VS.launchState())) end
      if vc and c.name then if vc.setCraftName then pcall(vc.setCraftName, c.name) else vc.craftName = c.name end end
      -- (scn_vacuum) the launch flies as the commander; the start crew's
      -- `control` member, seated aboard elsewhere, is the one you play
      local C = ref("crew")
      if vc and C and type(c.crew) == "table" then
        for _, sc_c in ipairs((sc.start and sc.start.crew) or {}) do
          local id = sc_c.control and crew_ids()[sc_c.name]
          if id and C.activeId() ~= id and vc.memberSlot and vc.memberSlot(id) and C.takeCraft then
            pcall(C.takeCraft, vc, id)
            local t1 = now() + 5
            while now() < t1 and C.activeId() ~= id do coroutine.yield() end
            out[#out + 1] = string.format("craft %d: you are %s (%s)", i, sc_c.name, tostring(C.activeId() == id))
          end
        end
        vc = piloted() or vc
      end
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
          -- (scn_vacuum) the velocity matched for where the craft IS each
          -- time, and the impulse's yield measured net of the half second's
          -- fall: the target was the velocity at the teleport point, and the
          -- craft falls ~1-2 m/s every pass while it is matched, so the loop
          -- stopped with a radial speed in it (pe -443 m on one run, +395 on
          -- another: the Ansel hit the ground). A circular orbit (e = 0) is
          -- re-aimed along the orbit's own plane at the local circular speed.
          local hx = r.y * vel.z - r.z * vel.y
          local hy = r.z * vel.x - r.x * vel.z
          local hz = r.x * vel.y - r.y * vel.x
          local hl = math.sqrt(hx * hx + hy * hy + hz * hz)
          hx, hy, hz = hx / hl, hy / hl, hz / hl
          local circ = (o.e or 0) == 0
          local gain = 1.0
          for _ = 1, 24 do
            info = assembly.info(vc.node)
            b = space.body(bn)
            local px, py, pz = info.com.x - b.x, info.com.y - b.y, info.com.z - b.z
            local pr = math.sqrt(px * px + py * py + pz * pz)
            local want = vel
            if circ then
              local sp = math.sqrt(b.mu / pr)
              local tx, ty, tz = hy * pz - hz * py, hz * px - hx * pz, hx * py - hy * px
              local tl = math.sqrt(tx * tx + ty * ty + tz * tz)
              want = { x = tx / tl * sp, y = ty / tl * sp, z = tz / tl * sp }
            end
            local dv = { x = want.x - info.vel.x, y = want.y - info.vel.y, z = want.z - info.vel.z }
            local dl = math.sqrt(dv.x * dv.x + dv.y * dv.y + dv.z * dv.z)
            if dl < 0.2 then break end
            local v0 = info.vel
            local t0 = space.time()
            local s = info.mass / gain
            assembly.impulseAt(vc.node, vec3(dv.x * s, dv.y * s, dv.z * s), info.com)
            wait_secs(0.5)
            local i2 = assembly.info(vc.node)
            local g = b.mu / (pr * pr) * (space.time() - t0)
            local gx, gy, gz = -px / pr * g, -py / pr * g, -pz / pr * g
            local got = math.sqrt((i2.vel.x - v0.x - gx) ^ 2 + (i2.vel.y - v0.y - gy) ^ 2 + (i2.vel.z - v0.z - gz) ^ 2)
            if got > 1e-3 then gain = math.max(0.02, math.min(5, gain * got / dl)) end
          end
          local io = assembly.info(vc.node)
          local el = space.elements and space.elements(io.origin.x, io.origin.y, io.origin.z, io.vel.x, io.vel.y, io.vel.z)
          out[#out + 1] = string.format("craft %d in orbit of %s: pe %.0f m, ap %.0f m", i, bn, el and el.periapsis and (el.periapsis - b.radius) or -1,
            el and el.apoapsis and (el.apoapsis - b.radius) or -1)
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

-- (scn_dust) STATES: { struct, uid | part, st = { … } }: a piece's state as
-- the `state` beat writes it (a switch off, a breaker's dial), set as soon as
-- the structure stands, before any cable joins it to a grid
function stage_states(list, out)
  local ST = ref("structures")
  for _, e in ipairs(list or {}) do
    local sid, uid = piece_of({ struct = e.struct, part = e.part, uid = e.uid })
    if sid and ST and ST.setPartState then
      local cur = ST.partState(sid, uid) or {}
      local t = {}
      for k, v in pairs(cur) do t[k] = v end
      for k, v in pairs(e.st or {}) do t[k] = v end
      ST.setPartState(sid, uid, t)
      out[#out + 1] = string.format("state %s:%s", tostring(sid), tostring(uid))
    end
  end
end
-- (scn_dust) CABLES: { from = { struct, uid | part }, to = { … }, ty }: a
-- Power Cable already laid between two staged structures (base_cable.layFree)
function stage_cables(list, out)
  local CB = ref("base_cable")
  if not (CB and CB.layFree) then return end
  for _, c in ipairs(list or {}) do
    local sa, ua = piece_of({ struct = c.from.struct, part = c.from.part, uid = c.from.uid })
    local sb, ub = piece_of({ struct = c.to.struct, part = c.to.part, uid = c.to.uid })
    local id, why = nil, "no such piece"
    if sa and sb then
      -- (a run already there from a checkpoint's restage is kept)
      for _, r in ipairs(CB.list and CB.list() or {}) do
        if (r.a.sid == sa and r.a.uid == ua and r.z.sid == sb and r.z.uid == ub) then id, why = r.id, "kept" end
      end
      if not id then id, why = CB.layFree({ sid = sa, uid = ua }, { sid = sb, uid = ub }, { ty = c.ty or "lv16" }) end
    end
    out[#out + 1] = string.format("cable %s:%s → %s:%s %s: %s", tostring(sa), tostring(ua), tostring(sb), tostring(ub), tostring(c.ty or "lv16"), tostring(id or why))
  end
end

local function stage_table(st, out)
  local co, rs = ref("company"), ref("research")
  if st.funds then set_funds(st.funds) end
  if st.rp and rs and rs.addPoints then rs.addPoints(st.rp, "scenario") end
  for _, id in ipairs(st.research or {}) do if rs and rs.grant then rs.grant(id, "scenario") end end
  -- (progression P1) feats the story starts with (a base already founded …)
  if st.feats then local F = ref("feats"); if F and F.seed then F.seed(st.feats) end end
  if co and st.funds then out[#out + 1] = string.format("funds %d", co.balance()) end
  frames(1)
  stage_crew(st.crew, out)
  stage_marks(st.marks, out)
  stage_structures(st.structures, out)
  stage_ruins(st.ruins, out)      -- F8
  stage_marks(st.marks, out, true)
  if st.beacons and SC5R then SC5R.stageBeacons(st.beacons, out) end
  stage_posts(st.crew, out)
  stage_lived_in(out)
  stage_plants(st.plants, out)
  stage_wires(st.wires, out)
  S6.stage(st, out)
  stage_states(st.states, out)     -- (scn_dust: before the cables, so a breaker's dial and a load's switch hold from the first solve)
  stage_cables(st.cables, out)     -- (scn_dust)
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
    elseif kind == "crew" then stage_crew({ e }, o); stage_posts({ e }, o); if portraitFor and e.name then portraitFor(e.name) end
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

-- ── SC-5 (scenarios/thirty_km): rovers their crew drive, crew put aboard,
-- craft set down far away standing on their wheels, a craft's batteries ────
-- Globals in one table (the main chunk is near its local ceiling).
SC5R = {}
-- (scnfix) a line's time on screen: the plate types it out (scenario_stage
-- pacedChars: CPS and a pause at punctuation), then it is read
function SC5R.lineSecs(text)
  local stg = ref("scenario_stage")
  local typ = (stg and stg.pacedSecs) and stg.pacedSecs(text) or (#text / 36)
  return math.max(1.5 + 0.06 * #text, typ + 1.6 + 0.03 * #text)
end
-- a craft's controller by name (or "craft:<name>")
function SC5R.vc(name)
  local n = tostring(name or ""):gsub("^craft:", "")
  for _, v in ipairs(vessels()) do
    if v.craftName == n and not (v.isLost and v.isLost()) and v.node and v.node.valid ~= false then return v end
  end
  return nil
end
function SC5R.eul(X, Y, Z)
  local pitch = math.asin(math.max(-1, math.min(1, -Z[2])))
  if math.abs(Z[2]) > 1 - 1e-10 then return math.atan2(-X[3], X[1]), pitch, 0 end
  return math.atan2(Z[1], Z[3]), pitch, math.atan2(X[2], Y[2])
end
-- (flight_ops basis_of: the node's YXZ angles → its X, Y, Z in the world)
function SC5R.basis(pitch, yaw, roll)
  local cy, sy = math.cos(yaw), math.sin(yaw)
  local cx, sx = math.cos(pitch), math.sin(pitch)
  local cz, sz = math.cos(roll), math.sin(roll)
  return { cy * cz + sy * sx * sz, cx * sz, -sy * cz + cy * sx * sz },
         { -cy * sz + sy * sx * cz, cx * cz, sy * sz + cy * sx * cz },
         { sy * cx, -sx, cy * cx }
end
-- A rolled-out craft set down FAR from the pad, the right way up there: the
-- rollout's record (vessel_controller.fleetParts, as flight_ops writes it)
-- moved to the ground point and turned from the pad's ground frame into that
-- point's (its front along `heading`, a unit tangent there), written to the
-- fleet as a new record and rebuilt by flight_ops (fleetRescan: "a record
-- written from outside the flight"). A plain teleport keeps the pad's
-- orientation: 1.8 km round an 885 m world that is a rover on its roof.
-- → true when the record is written (the rebuild follows once its ground is
-- under a body: flight_ops waits for that)
function SC5R.placeFar(vc, name, g, heading, charge, out)
  local FO, E = ref("flight_ops"), ref("electronics")
  local n = vc and vc.node
  local info = n and n.valid and assembly.info(n)
  local fp = vc and vc.fleetParts and vc.fleetParts()
  if not (FO and FO.fleetRescan and info and fp and fp.parts) then return false end
  local o = info.origin
  local pn = space.dominant(o.x, o.y, o.z)
  local pb = pn and space.body(pn)
  if not (pb and space.body(g.body)) then return false end
  -- the pad's ground frame, and the craft's axes in it
  local PF = rulebook().groundFrame(o.x - pb.x, o.y - pb.y, o.z - pb.z)
  local X, Y, Z = SC5R.basis(n.pitch or 0, n.yaw or 0, n.roll or 0)
  local function loc(a) return { r = a[1] * PF.rx + a[2] * PF.ry + a[3] * PF.rz, u = a[1] * PF.ux + a[2] * PF.uy + a[3] * PF.uz,
                                 f = a[1] * PF.fx + a[2] * PF.fy + a[3] * PF.fz } end
  -- its front: the rover body's +X (else the craft's), in the world
  local front = { 1, 0, 0 }
  for _, d in ipairs(fp.parts) do
    if d.id == "roverBody" then front = SC5R.basis(d.pitch or 0, d.yaw or 0, d.roll or 0); break end
  end
  local fw = { X[1] * front[1] + Y[1] * front[2] + Z[1] * front[3], X[2] * front[1] + Y[2] * front[2] + Z[2] * front[3],
               X[3] * front[1] + Y[3] * front[2] + Z[3] * front[3] }
  local fl = loc(fw)
  local th_pad = math.atan2(fl.r, fl.f)
  -- the target's frame, and the heading wanted there
  local TF = rulebook().groundFrame(g.ux, g.uy, g.uz)
  local th_t = 0
  if heading then
    th_t = math.atan2(heading.x * TF.rx + heading.y * TF.ry + heading.z * TF.rz, heading.x * TF.fx + heading.y * TF.fy + heading.z * TF.fz)
  end
  local ps = th_t - th_pad
  local cp, sp = math.cos(ps), math.sin(ps)
  local function move(a)
    local l = loc(a)
    local r2, f2 = l.r * cp + l.f * sp, l.f * cp - l.r * sp
    return { TF.rx * r2 + TF.ux * l.u + TF.fx * f2, TF.ry * r2 + TF.uy * l.u + TF.fy * f2, TF.rz * r2 + TF.uz * l.u + TF.fz * f2 }
  end
  local yaw, pitch, roll = SC5R.eul(move(X), move(Y), move(Z))
  -- how high its origin rides over what it stands on, measured on the pad
  local hit = raycast(o.x + PF.ux * 0.2, o.y + PF.uy * 0.2, o.z + PF.uz * 0.2, -PF.ux, -PF.uy, -PF.uz, 6.0, n)
  local clear = hit and ((o.x - hit.x) * PF.ux + (o.y - hit.y) * PF.uy + (o.z - hit.z) * PF.uz) or 1.0
  local recs = {}
  for i, d in ipairs(fp.parts) do recs[i] = (E and E.packRecord) and E.packRecord(d) or d end
  local nx = (tonumber(save.get("fleet.next")) or 0) + 1
  save.set("fleet.next", nx)
  local fid = "c" .. tostring(nx)
  local up = clear + 0.15
  local rec = { name = name, body = g.body, x = g.x + g.ux * up, y = g.y + g.uy * up, z = g.z + g.uz * up, vx = 0, vy = 0, vz = 0,
                pitch = pitch, yaw = yaw, roll = roll, landed = true, fuel = fp.fuel or 0, charge = charge or fp.charge or 0,
                groups = fp.groups, controls = fp.controls, probe = fp.probe == true, crew = false, station = fp.station,
                flown = true, from = fp.from, stime = space.time and space.time() or 0, at = agency_now(), parts = recs, t = time }
  -- the rollout goes, and its own record (if flight_ops wrote one) with it
  if vc.piloting and vc.releaseControl then pcall(vc.releaseControl) end
  -- (the new record first: forgetNodes then writes the fleet through
  -- flight_ops' own copy, which the rescan reads, with it in)
  local f = save.get("fleet.craft")
  f = type(f) == "table" and f or {}
  f[fid] = rec
  save.set("fleet.craft", f)
  if FO.forgetNodes then FO.forgetNodes({ n.id }) end
  destroy(n)
  FO.fleetRescan()
  -- (flight_ops reads its own copy of the fleet for half a second: the
  -- rescan is asked again once that copy has gone)
  if after then pcall(after, 0.7, function() local F2 = ref("flight_ops"); if F2 and F2.fleetRescan then F2.fleetRescan() end end) end
  out[#out + 1] = string.format("craft %s set down far: %s (clear %.2f m, turned %.2f rad)", tostring(name), fid, clear, ps)
  return true
end

-- A craft staged LANDED (start.craft where.ground): its launch-format record
-- written straight to the fleet, standing on its wheels at the ground point
-- (its craft frame's y = 0 is its lowest point), its front (+X) along
-- `face` (a ref) or `yaw` from the ground frame's front, its batteries at
-- `charge`; flight_ops rebuilds it (fleetRescan) once the ground under it is
-- solid (a body near it), and staging waits up to `wait` s for that.
-- is something built (taller than a person: 2.2 m over the terrain) at the
-- body-relative ground point `g` or 4 m round it? Rays come down from 25 m.
function SC5R.builtNear(b, g)
  if not raycast then return false end
  local G = ground_of(b)
  local gl = math.sqrt(g.x * g.x + g.y * g.y + g.z * g.z)
  local ux, uy, uz = g.x / gl, g.y / gl, g.z / gl
  local ax, ay, az = uy, -ux, 0
  if math.abs(uz) > 0.9 then ax, ay, az = 0, uz, -uy end
  local al = math.sqrt(ax * ax + ay * ay + az * az)
  ax, ay, az = ax / al, ay / al, az / al
  local cx, cy, cz = uy * az - uz * ay, uz * ax - ux * az, ux * ay - uy * ax
  for _, o in ipairs({ { 0, 0 }, { 4, 0 }, { -4, 0 }, { 0, 4 }, { 0, -4 } }) do
    local px, py, pz = g.x + ax * o[1] + cx * o[2], g.y + ay * o[1] + cy * o[2], g.z + az * o[1] + cz * o[2]
    local pl = math.sqrt(px * px + py * py + pz * pz)
    local dx, dy, dz = px / pl, py / pl, pz / pl
    local R = G({ x = dx, y = dy, z = dz }) or pl
    local top = R + 25
    local ok, h = pcall(raycast, b.x + dx * top, b.y + dy * top, b.z + dz * top, -dx, -dy, -dz, 30)
    if ok and h and h.distance and top - h.distance > R + 2.2 then return true end
  end
  return false
end
function SC5R.stageGround(i, c, bp, wh, out)
  local FO, E = ref("flight_ops"), ref("electronics")
  local g = resolve_stage(wh.ground, wh.offset, wh.yaw)
  if not (FO and FO.fleetRescan and g) then out[#out + 1] = string.format("craft %d: no ground at %s", i, tostring(wh.ground)); return end
  local hx, hy, hz = g.fx, g.fy, g.fz
  local fq = wh.face and pos_of(wh.face)
  if fq and fq.body == g.body then
    local dx, dy, dz = fq.x - g.x, fq.y - g.y, fq.z - g.z
    local du = dx * g.ux + dy * g.uy + dz * g.uz
    dx, dy, dz = dx - g.ux * du, dy - g.uy * du, dz - g.uz * du
    local l = math.sqrt(dx * dx + dy * dy + dz * dz)
    if l > 1e-6 then hx, hy, hz = dx / l, dy / l, dz / l end
  end
  -- never set a craft down inside something built: a spot written against an
  -- older base can land on a building added since (Thirty Kilometres' Asha-1
  -- spot fell inside the Medical Bay, and the rover was thrown out of it).
  -- The spot moves on along the way the craft faces, 4 m at a time.
  local gb = space.body(g.body)
  if gb and SC5R.builtNear(gb, g) then
    local G, moved = ground_of(gb), nil
    for k = 1, 20 do
      local s = 4 * k
      local qx, qy, qz = g.x + hx * s, g.y + hy * s, g.z + hz * s
      local ql = math.sqrt(qx * qx + qy * qy + qz * qz)
      local dx, dy, dz = qx / ql, qy / ql, qz / ql
      local R = G({ x = dx, y = dy, z = dz })
      if R then
        local q = { x = dx * R, y = dy * R, z = dz * R, ux = dx, uy = dy, uz = dz }
        if not SC5R.builtNear(gb, q) then moved = { q = q, s = s }; break end
      end
    end
    if moved then
      g.x, g.y, g.z, g.ux, g.uy, g.uz = moved.q.x, moved.q.y, moved.q.z, moved.q.ux, moved.q.uy, moved.q.uz
      local du = hx * g.ux + hy * g.uy + hz * g.uz
      hx, hy, hz = hx - g.ux * du, hy - g.uy * du, hz - g.uz * du
      local l = math.sqrt(hx * hx + hy * hy + hz * hz)
      hx, hy, hz = hx / l, hy / l, hz / l
      out[#out + 1] = string.format("craft %d: its spot had something built on it; set down %d m further on", i, moved.s)
    else
      out[#out + 1] = string.format("craft %d: its spot has something built on it and no clear ground within 80 m", i)
    end
  end
  local X = { hx, hy, hz }
  local Y = { g.ux, g.uy, g.uz }
  local Z = { X[2] * Y[3] - X[3] * Y[2], X[3] * Y[1] - X[1] * Y[3], X[1] * Y[2] - X[2] * Y[1] }
  local yaw, pitch, roll = SC5R.eul(X, Y, Z)
  local recs, cap = {}, 0
  for k, d in ipairs(bp.parts) do
    local cp = {}
    for kk, vv in pairs(d) do cp[kk] = vv end
    if E and E.modsOf then for _, m in ipairs(E.modsOf(cp)) do if m.type == "battery" then cap = cap + (m.ec or 0) end end end
    recs[k] = (E and E.packRecord) and E.packRecord(cp) or cp
  end
  local nx = (tonumber(save.get("fleet.next")) or 0) + 1
  save.set("fleet.next", nx)
  local fid = "c" .. tostring(nx)
  local lift = wh.lift or 0.25
  local rec = { name = c.name or bp.name or "Rover", body = g.body, x = g.x + g.ux * lift, y = g.y + g.uy * lift, z = g.z + g.uz * lift,
                vx = 0, vy = 0, vz = 0, pitch = pitch, yaw = yaw, roll = roll, landed = true, fuel = 0,
                charge = cap * (wh.charge or 1), groups = bp.groups, controls = bp.controls, probe = true, crew = false,
                flown = true, stime = space.time and space.time() or 0, at = agency_now(), parts = recs, t = time }
  local f = save.get("fleet.craft")
  f = type(f) == "table" and f or {}
  f[fid] = rec
  save.set("fleet.craft", f)
  FO.fleetRescan()
  local t1 = now() + (wh.wait or 30)
  while now() < t1 and not SC5R.vc(rec.name) do coroutine.yield() end
  out[#out + 1] = string.format("craft %d (%s) set down landed as %s: %s (%.0f EC)", i, tostring(rec.name), fid, SC5R.vc(rec.name) and "rebuilt" or "waiting for its ground", cap * (wh.charge or 1))
end

-- DRIVE: { craft, follow = ref | to = ref, speed, gap, r } | { craft, stop = true }.
-- Kept in the save (scn.drives) and handed to the craft again whenever it
-- has no command (a reload, a member not seated yet, a setback's restage).
function SC5R.cmd(v)
  local cmd = { speed = v.speed or 5, gap = v.follow and (v.gap or 12) or nil, r = v.to and (v.r or 6) or nil }
  if v.follow then
    local k, n = rulebook().parseRef(v.follow)
    if k == "craft" then
      local t = SC5R.vc(n)
      if not (t and t.node) then return nil, "no craft " .. tostring(n) end
      cmd.follow = t.node.id
    else
      local p = pos_of(v.follow)
      if not p then return nil, "no " .. tostring(v.follow) end
      cmd.to, cmd.r, cmd.gap = { body = p.body, x = p.x, y = p.y, z = p.z }, v.gap or 12, nil
    end
  else
    local p = pos_of(v.to)
    if not p then return nil, "no " .. tostring(v.to) end
    cmd.to = { body = p.body, x = p.x, y = p.y, z = p.z }
  end
  return cmd
end
function SC5R.drive(v)
  local name = tostring(v.craft or ""):gsub("^craft:", "")
  local d = sget("scn.drives")
  d = type(d) == "table" and d or {}
  if v.stop then
    d[name] = nil
    sset("scn.drives", d)
    local vc = SC5R.vc(name)
    if vc and vc.npcDrive then vc.npcDrive(nil) end
    return
  end
  d[name] = { follow = v.follow, to = v.to, speed = v.speed, gap = v.gap, r = v.r }
  sset("scn.drives", d)
  SC5R.t = -1e9      -- (handed over at the next tick)
  -- (storypolish) a new command replaces the one it is on: the tick hands a
  -- drive over only to a craft with none, and a rover parked inside its last
  -- target's gap still counts as driving (Beck sat at the waypoint for good)
  local vc = SC5R.vc(name)
  if vc and vc.npcDrive and not vc.piloting then vc.npcDrive(nil) end
end
-- 4 Hz with the goals: every standing drive handed to its craft when it has
-- none (once a second), and a `to` that moves (a crew member) re-read
function SC5R.tick(t)
  local d = sget("scn.drives")
  if type(d) ~= "table" or next(d) == nil then return end
  local again = t - (SC5R.t or -1e9) >= 1.0
  if again then SC5R.t = t end
  for name, v in pairs(d) do
    local vc = SC5R.vc(name)
    if vc and vc.npcDrive and not vc.piloting then
      local st = vc.npcState and vc.npcState()
      local moving = (v.to and rulebook().parseRef(v.to) == "crew") or (v.follow and rulebook().parseRef(v.follow) == "crew")
      if (again and not (st and st.active)) or moving then
        local cmd, why = SC5R.cmd(v)
        if cmd then
          local ok, w2 = vc.npcDrive(cmd)
          if not ok and again then say_log("drive " .. name .. ": " .. tostring(w2)) end
        elseif again then say_log("drive " .. name .. ": " .. tostring(why)) end
      end
    end
  end
end

-- BOARD: { who, craft } a free seat; { who, craft = false } out at the seat
function SC5R.board(v)
  local C = ref("crew")
  local id = who_id(v.who)
  if not (C and id) then say_log("board: no " .. tostring(v.who)); return end
  if v.craft == false then
    if C.craftOf and C.craftOf(id) and C.eva then
      local ok, why = C.eva(id, { stay = true, confirmed = true })
      if not ok then say_log("board: " .. tostring(v.who) .. " out: " .. tostring(why)) end
    end
    return
  end
  local vc = SC5R.vc(v.craft)
  if not vc then say_log("board: no craft " .. tostring(v.craft)); return end
  local cur = C.craftOf and C.craftOf(id)
  if cur and cur.node and vc.node and cur.node.id == vc.node.id then return end
  -- (scnfix, Ty 2026-11-12: "my crewmate teleported onto the rover with me")
  -- a member on foot in sight of the craft WALKS to it and climbs in when
  -- there (the walk's end boards them: walks_tick); seated straight away
  -- only with no body near, mid-staging, in a cutscene (its author walks
  -- them), with `walk = false` (the hurt), or when the walk runs out of time
  if not v.now and v.walk ~= false and phase == "running" and not cut and not cur and C.bodyNodes and vc.node and not (C.activeId and C.activeId() == id) then
    local okb, bn = pcall(C.bodyNodes)
    local n = okb and type(bn) == "table" and bn[id] or nil
    if n and n.valid ~= false then
      local dx, dy, dz = n.x - vc.node.x, n.y - vc.node.y, n.z - vc.node.z
      local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
      if dist > 2.6 and dist < 150 then
        local bv = {}
        for k2, x2 in pairs(v) do bv[k2] = x2 end
        bv.now = true
        walks[id] = { to = "craft:" .. tostring(vc.craftName or v.craft):gsub("^craft:", ""), t1 = now() + dist / 1.1 + 20, who = v.who,
                      speed = dist > 25 and 2.3 or 1.5, near = 2.0, board = bv }
        if C.patch then C.patch(id, { pose = false, gesture = false }) end
        say_log(string.format("board: %s walks to %s (%.0f m)", tostring(v.who), tostring(v.craft), dist))
        return
      end
    end
  end
  -- (`seat`: that seat part's slot, when it is free)
  local su, sk = nil, nil
  if v.seat and vc.seatsOf then
    for _, s in ipairs(vc.seatsOf() or {}) do if s.uid == v.seat and not s.taken and not su then su, sk = s.uid, s.slot end end
  end
  local ok, why = C.board(id, vc, su, sk)
  if not ok and vc.freeSeat and vc.seatMember then
    -- (no body in reach: the record is seated straight away)
    local u, k = su, sk
    if not u then u, k = vc.freeSeat(nil) end
    if u then
      if cur and cur.unseatMember then cur.unseatMember(id) end
      ok, why = vc.seatMember(u, k, id)
      if ok then C.patch(id, { status = "aboard", craft = vc.craftName or false, body = false, x = false, y = false, z = false, pose = false }) end
    else why = "no free seat" end
  end
  if not ok then say_log("board: " .. tostring(v.who) .. " → " .. tostring(v.craft) .. ": " .. tostring(why)) end
end

-- PLACE: { craft | who, at, offset, yaw }: set down at a ref now (a
-- checkpoint's stage: the rovers back where the act begins). A craft near
-- where it stands is moved (assembly.teleport), one far away rebuilt the
-- right way up (placeFar); a member is set down (crew.setDown, or the
-- player's body).
function SC5R.place(v)
  local g = resolve_at(v.at, v.offset, v.yaw)
  local b = g and space.body(g.body)
  if not b then say_log("place: no " .. tostring(v.at)); return end
  if v.craft then
    local vc = SC5R.vc(v.craft)
    if not vc then say_log("place: no craft " .. tostring(v.craft)); return end
    local p = node_rel(vc.node)
    local far = not p or p.body ~= g.body or math.sqrt((p.x - g.x) ^ 2 + (p.y - g.y) ^ 2 + (p.z - g.z) ^ 2) > 60
    local out = {}
    if far then SC5R.placeFar(vc, vc.craftName, g, { x = g.fx, y = g.fy, z = g.fz }, nil, out)
    else
      local info = assembly.info(vc.node)
      if info then
        assembly.teleport(vc.node, vec3(b.x + g.x + g.ux * 1.2 + (info.origin.x - info.com.x), b.y + g.y + g.uy * 1.2 + (info.origin.y - info.com.y),
          b.z + g.z + g.uz * 1.2 + (info.origin.z - info.com.z)))
        if info.vel then assembly.impulseAt(vc.node, vec3(-info.vel.x * info.mass, -info.vel.y * info.mass, -info.vel.z * info.mass), info.com) end
      end
    end
    for _, l in ipairs(out) do say_log("place: " .. l) end
    return
  end
  local C = ref("crew")
  local id = who_id(v.who)
  if not (C and id) then return end
  local l = math.sqrt(g.x * g.x + g.y * g.y + g.z * g.z)
  local k = (l + 1.0) / l
  if id == (C.activeId and C.activeId()) then
    local a = find("Astronaut")
    if a then a.x, a.y, a.z = b.x + g.x * k, b.y + g.y * k, b.z + g.z * k; a.vx, a.vy, a.vz = 0, 0, 0 end
  elseif C.setDown then C.setDown(id, b.x + g.x * k, b.y + g.y * k, b.z + g.z * k) end
end

-- BEACONS (start.beacons = { { at = ref, offset } }): relay beacons planted
-- on the ground there (comms.placeBeacon), as the crew plants them: a base's
-- beacon line out to the ridge
function SC5R.stageBeacons(list, out)
  local CM = ref("comms")
  if not (CM and CM.placeBeacon) then out[#out + 1] = "beacons: no comms"; return end
  for i, e in ipairs(list or {}) do
    local g = resolve_stage(e.at, e.offset)
    local b = g and space.body(g.body)
    if b then
      local id = CM.placeBeacon(g.body, b.x + g.x, b.y + g.y, b.z + g.z)
      out[#out + 1] = string.format("beacon %d: %s", i, tostring(id))
    else out[#out + 1] = string.format("beacon %d: no %s", i, tostring(e.at)) end
  end
end

-- CHARGE: { craft, frac }: its batteries at that share of what they hold
function SC5R.charge(v)
  local vc = SC5R.vc(v.craft)
  if not (vc and vc.elecSetCharge and vc.controlState) then say_log("charge: no craft " .. tostring(v.craft)); return end
  local cs = vc.controlState()
  vc.elecSetCharge((cs.cap or 0) * math.max(0, math.min(1, v.frac or 0)))
end

-- a craft's state for the hooks and the meters (copies)
function SC5R.read(name)
  local vc = SC5R.vc(name)
  if not vc then return nil end
  local cs = vc.controlState and vc.controlState() or {}
  local info = vc.node and vc.node.valid and assembly.info(vc.node)
  local sp = 0
  if info and info.vel then sp = math.sqrt(info.vel.x ^ 2 + info.vel.y ^ 2 + info.vel.z ^ 2) end
  local out = { charge = cs.charge or 0, cap = cs.cap or 0, speed = sp, link = link_up("craft:" .. tostring(vc.craftName)) and 1 or 0,
                crew = (vc.crewCount and vc.crewCount()) or 0, control = cs.can and 1 or 0 }
  local el = vc.elecReadout and vc.elecReadout() or nil
  if el then out.supply, out.demand, out.lit = el.supply, el.demand, el.lit end
  local ns = vc.npcState and vc.npcState()
  if ns then out.npc = { active = ns.active, dist = ns.dist, vstar = ns.vstar, stuck = ns.stuck, why = ns.why } end
  return out
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
    -- (graveyard2) and its `beats`, run at once over the restaged world (a
    -- crew member back in her bunk: a pose; where someone stands: a turn)
    for _, b in ipairs((s and s.stage and s.stage.beats) or {}) do
      local okb, err = pcall(run_beat, b, { cs = nil })
      if not okb then out[#out + 1] = "stage beat: " .. tostring(err) end
    end
    sset("scn.retryFrom", false)
    retried = true      -- (a return to a checkpoint goes straight back in: no briefing)
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
  -- (interaction plan B3) a run that ends or is abandoned mid-shot never
  -- leaves planet_camera.cinematic set: that blocks every right-click menu
  -- (context_menu.blocked) until the next camera_end. A shot with
  -- `wait = false` whose sequence ends in a finish before its t1 did.
  if p == "done" or p == "failed" or p == "freeplay" then
    pcall(cut_end)
    pcall(camera_end)
    local pc = ref("planet_camera")
    if pc and pc.cinematic and pc.setCinematic then pcall(pc.setCinematic, false) end
  end
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
    -- (playtest 11-11, plant_av) a piece under stress a hook models (a bearing
    -- going, 0..1): heard and felt at the piece; renewed each tick, it lapses
    -- 10 s after the hook stops saying so
    stress = function(struct, part, kind, v)
      local sid, uid = piece_of({ struct = struct, part = type(part) == "string" and part or nil, uid = type(part) == "number" and part or nil })
      local PA = ref("plant_av")
      if sid and PA and PA.stress then PA.stress(sid, uid, kind or "bearing", v) end
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
    -- (SC-5) a craft's state (copies): charge, cap, speed, link, crew, control,
    -- supply, demand, lit, npc = { active, dist, vstar, stuck, why }
    craft = function(name) return SC5R.read(name) end,
    -- (SC-5) a craft part's health, 1 whole … 0 broken (nil: not aboard)
    partHp = function(craft, part) return W.partHp({ craft = craft, part = type(part) == "string" and part or nil, uid = type(part) == "number" and part or nil }) end,
    -- (SC-5) what member `who` carries: a count of item id
    has = function(who, item)
      local inv, id = ref("inventory"), who_id(who)
      local cid = id and ("crew:" .. tostring(id)) or "astro"
      return inv and inv.itemCount and (inv.itemCount(cid, item) or 0) or 0
    end,
    -- (S6) what a container holds (a copy), the newest base-log lines of a structure
    container = function(struct, part)
      local sid, uid = piece_of({ struct = struct, part = type(part) == "string" and part or nil, uid = type(part) == "number" and part or nil })
      return sid and S6.contents(sid, uid) or nil
    end,
    baseLog = function(struct, n)
      local sid = struct_id(tostring(struct or ""):gsub("^struct:", ""))
      local BL = ref("base_log")
      if not (sid and BL and BL.entries) then return {} end
      local out = {}
      for _, e in ipairs(BL.entries({ sid }, n or 20)) do out[#out + 1] = BL.lineOf(e) end
      return out
    end,
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
  if s.checkpoint then
    sset("scn.cp", s.id)
    -- FW-C (PLAN §2 F5): what a RETRY from here keeps of the story
    local snap = rulebook().checkpointSnap(s.id, vars(), sget("scn.ev"), sget("scn.obj"),
                                           agency_now() - (tonumber(sget("scn.t0")) or agency_now()))
    snap.mat, snap.m0 = sget("scn.mat"), sget("scn.m0")
    sset("scn.cpSnap", snap)
  end
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
           crewSafe = safe, vars = vars(), setbacks = tonumber(sget("scn.setbacks")) or 0 }
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
    if bc and bc.show then bc.show(string.upper(med) .. " · " .. tostring(sc.title), (sc.debrief or {})[med] or "", 8.0, "story") end
    if (sc.after or "freeplay") == "freeplay" then continueFreeplay() end
  end
end

-- A SETBACK (PLAN §2 F5, Ty 2026-11-10: "you can fail but it just goes
-- back to your last checkpoint"): the default for every scenario but those
-- with `failure = "end"`. A card says what happened and where you go back
-- to ("BACK TO ACT 3", the checkpoint step's `act`, else its text), then the
-- run is put back (checkpoint_restore). The DEBRIEF is only for the end.
setback = nil          -- { text, act, to, t1 } while the card is up
-- ── storypolish: THE FAIL SCREEN (Ty 2026-11-11: "dying needs its own death
-- screen that explains why you failed the mission and died in a scenario,
-- and then lets you continue whenever you're ready, then it loads back to
-- the checkpoint"). The setback carries the screen's words (scenario.lua
-- failWords: the fail entry's own title / text / hint, else the kind's, and
-- for a death who died and how), the act it goes back to and the story's
-- clock. With a "setback" listener (scenario_ui's fail screen) the run waits
-- for continueSetback(): no auto-advance. With none (luajit, a bare runner)
-- the old card shows and the restore follows after setback_secs.
local function sp_dead_member()
  local C = ref("crew")
  if not C then return nil end
  local me_ = nil
  for _, c in ipairs((sc and sc.start and sc.start.crew) or {}) do if c.control then me_ = c.name end end
  local best = nil
  for name, id in pairs(crew_ids()) do
    local r = C.get(id)
    if r and r.status == "dead" then
      local d = { name = r.name or name, cause = r.died and r.died.cause, player = (name == me_) or (r.name == me_) }
      if not best or d.player then best = d end
    end
  end
  return best
end
local function setback_start(why, f)
  local cp = sget("scn.cp")
  local i = cp and rulebook().stepIndex(sc, cp)
  local s = i and sc.steps[i]
  local act = s and (s.act or s.text) or "the start"
  local n = (tonumber(sget("scn.setbacks")) or 0) + 1
  sset("scn.setbacks", n)
  local t0 = tonumber(sget("scn.t0"))
  local clock = t0 and (agency_now() - t0) or 0
  local ent = type(f) == "table" and f or { kind = "fail", text = why }
  local dm = ent.kind == "crew_dead" and sp_dead_member() or nil
  local R_ = rulebook()
  local words = R_.failWords and R_.failWords(ent, { who = dm and dm.name, cause = dm and dm.cause, player = dm and dm.player, clock = clock })
    or { title = "MISSION FAILED", text = why }
  setback = { text = words.text or why or "That went wrong.", title = words.title, hint = words.hint, cause = words.cause, kind = words.kind,
              act = act, to = cp, n = n, clock = clock, t0 = now() }
  say_log(string.format("SETBACK %d: %s → back to %s", n, tostring(why), tostring(cp or "the start")))
  beatq, beat_busy, line, choice = {}, nil, nil, nil
  local stg = ref("scenario_stage")
  if stg and stg.dropSays then pcall(stg.dropSays) end
  if cut then cut_end() end
  camera_end()
  -- (the alarm's red edge is on the stage's layer, over the fail screen)
  if alarm_on then alarm_on = false; emit("alarm", false) end
  set_phase("setback")
  if not emit("setback", setback) then
    setback.t1 = now() + ((params and params.setback_secs) or 4.5)
    local bc = ref("big_caption")
    if bc and bc.show then bc.show("BACK TO " .. string.upper(tostring(act)), setback.text, 5.0, "story") end
  end
  bump()
end
local function setback_tick()
  if setback and setback.t1 and now() >= setback.t1 then continueSetback() end
end
-- CONTINUE on the fail screen: back to the checkpoint now. → true when it went
function continueSetback()
  if phase ~= "setback" or not setback or setback.going then return false end
  setback.going = true
  local to, n = setback.to, setback.n
  setback = nil
  checkpoint_restore(to, { setbacks = n })
  return true
end
function setbackNow() return setback end

function fail(why, f)
  if not sc or phase == "done" or phase == "failed" or phase == "setback" or phase == "freeplay" then return end   -- (storypolish: not after the story is over)
  if (sc.failure or "checkpoint") ~= "end" then setback_start(why, f); return end
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
    if bc and bc.show then bc.show("FAILED · " .. tostring(sc.title), fail_text, 8.0, "story") end
  end
end

-- FW-C: METERS and MODELS (scenario.lua stepMeter / stepModel), with the goals
local function strip_struct(n) return tostring(n or ""):gsub("^struct:", "") end
local function meter_read(m, i)
  local src, fld = tostring(m.read or ""):match("^(%a+)%.?([%w_]*)$")
  if src == "var" then return tonumber(var(fld)) end
  if src == "reactor" then
    local sid = struct_id(strip_struct(m.struct)); local r = sid and W.reactor(sid)
    return r and tonumber(r[fld]) or nil
  elseif src == "grid" then
    local sid = struct_id(strip_struct(m.struct)); local s = sid and W.grid(sid)
    if not s then return nil end
    if fld == "battery" then return (s.cap or 0) > 0 and (s.stored or 0) / s.cap or 0 end
    return tonumber(s[fld])
  elseif src == "dose" then
    -- millisieverts (a lethal dose, 1.0 of the crew's dose, is 5 Sv)
    local C, id = ref("crew"), who_id(m.who)
    local d = C and id and C.doseOf and C.doseOf(id)
    return d and d * 5000 or nil
  elseif src == "suit" then return W.suitO2(tostring(m.who or ""):gsub("^crew:", ""))
  elseif src == "room" then
    local sid = struct_id(strip_struct(m.struct))
    local r = sid and rulebook().pickRoom(W.rooms(sid), m.room or "largest")
    local a = r and W.roomAir(sid, r.id)
    return a and tonumber(a[fld]) or nil
  elseif src == "craft" then
    local c = SC5R.read(m.craft)
    return c and tonumber(c[fld]) or nil
  elseif src == "part" then
    mem["mpart:" .. i] = mem["mpart:" .. i] or {}
    return W.partHp(m, mem["mpart:" .. i])
  elseif src == "cabin" then
    -- (scn_vacuum) a craft module's air: p, o2, co2, reserve (atm·m³), res (its share)
    local a = W.cabin(tostring(m.craft or ""):gsub("^craft:", ""), m.module)
    if not a then return nil end
    if fld == "res" then return (a.qcap or 0) > 0 and (a.reserve or 0) / a.qcap or 0 end
    return tonumber(a[fld])
  elseif src == "piece" then
    local p = piece_read(m.struct, m.part, m.uid)
    local v = p and p[fld]
    if type(v) == "boolean" then return v and 1 or 0 end
    return tonumber(v)
  end
  return nil
end
local mm_last = nil
local function meters_models(t, ctx)
  -- (scn_dust: the agency clock can step in tens of seconds under warp; a
  -- 5 s cap lost most of a warped drive. A reload starts from nil anyway)
  local dt = mm_last and math.max(0, math.min(600, t - mm_last)) or 0
  mm_last = t
  if not (sc.meters or sc.models) then return end
  local R_ = rulebook()
  local m0 = sget("scn.m0") or {}
  for i, m in ipairs(sc.meters or {}) do
    local ok = true
    if m.when then mem["mw:" .. i] = mem["mw:" .. i] or {}; ok = R_.evalGoal(m.when, W, mem["mw:" .. i], ctx) end
    if ok then
      local r = meter_read(m, i)
      if type(r) == "number" then
        if m.delta and m0[tostring(i)] == nil then m0[tostring(i)] = r; sset("scn.m0", m0) end
        local cur = var(m.var)
        local nv = R_.stepMeter(m, cur, r, dt, m0[tostring(i)])
        if nv ~= cur then setVar(m.var, nv) end
      end
    end
  end
  local fired = nil
  for i, md in ipairs(sc.models or {}) do
    local act = true
    if md.active then mem["ma:" .. i] = mem["ma:" .. i] or {}; act = R_.evalGoal(md.active, W, mem["ma:" .. i], ctx) end
    if var(md.var) == nil and md.start ~= nil then setVar(md.var, md.start) end
    if act and dt > 0 then
      local rising = true
      if md.when then mem["mr:" .. i] = mem["mr:" .. i] or {}; rising = R_.evalGoal(md.when, W, mem["mr:" .. i], ctx) end
      local cur = var(md.var)
      -- (storypolish) stepped from its unrounded value while the variable
      -- still reads as that value rounded (nothing else wrote it)
      local raw = mem["mv:" .. i]
      local from = cur
      if type(raw) == "number" and type(cur) == "number" and math.abs(raw - cur) <= (md.round or 0) * 0.5 + 1e-9 then from = raw end
      local nv, crossed, rv = R_.stepModel(md, from, rising, dt)
      mem["mv:" .. i] = rv
      if nv ~= cur then setVar(md.var, nv) end
      for _, j in ipairs(crossed) do
        fired = fired or sget("scn.mat") or {}
        local key = i .. ":" .. j
        local a = md.at[j]
        if a.once == false or not fired[key] then
          fired[key] = t
          sset("scn.mat", fired)
          say_log(string.format("model %s crossed %s", md.var, tostring(a.value)))
          if a.run then run_seq(a.run, false) end
          if a.beats then queue_beats(a.beats, "model") end
        end
      end
    end
  end
end

-- ── scnfix (Ty's playtest 2026-11-12) ──────────────────────────────────────
-- SKIPPING AHEAD. "I drove past the first relay marker straight to Asha and
-- was stuck: the objective still wanted r1." A step whose only unmet goals
-- are being AT a place (a mark, a structure, a craft's part: a waypoint) is
-- passed over when a later step is already met: the steps between, if they
-- are waypoints too, latch with it. Their on_done beats do not play (what
-- they said happened did not); a step's `on_skip` beats do. Never past a
-- checkpoint or a parallel group, nor a step with `skip = false`; at most
-- SKIP_AHEAD steps ahead. `optional` steps in between are left as they are.
SKIP_AHEAD = 10
function SC5R.placeRef(r)
  if type(r) ~= "string" then return false end
  return r:sub(1, 5) == "mark:" or r:sub(1, 7) == "struct:" or r == "base" or r:find("@", 1, true) ~= nil
end
-- `rows`: the step's goals as read (met); nil reads them here (the memory
-- "ahead:", so a hold or an event's memory is never disturbed)
function SC5R.waypointish(st, rows, ctx)
  if st.skip == false or st.parallel then return false, false end
  local R_ = rulebook()
  local all, at_left = true, false
  for j, g in ipairs(st.goals or {}) do
    local met
    if rows then met = rows[j] and rows[j].met
    else
      local key = "ahead:" .. st.id .. ":" .. j
      mem[key] = mem[key] or {}
      met = R_.evalGoal(g, W, mem[key], ctx)
    end
    if not met then
      all = false
      if g.kind == "at" and SC5R.placeRef(g.at) then at_left = true else return false, false end
    end
  end
  return at_left, all
end
function SC5R.skipAhead(cur, ctx)
  local steps = sc.steps
  local s = steps[cur]
  if not (s and readings[cur]) or s.parallel or s.skip == false or s.optional then return false end
  if not SC5R.waypointish(s, readings[cur]) then return false end
  local target = nil
  -- (a later step already met when this one opened says nothing of where
  -- the player went: a flag planted before, a pump that was running. It
  -- counts once it has been seen unmet)
  local base = SC5R.aheadBase
  local first = not (base and base.id == s.id)
  if first then base = { id = s.id, met = {} }; SC5R.aheadBase = base end
  for j = cur + 1, math.min(#steps, cur + SKIP_AHEAD) do
    local st = steps[j]
    if not st.optional and not done_tbl()[st.id] then
      if st.parallel then break end
      local way, all = SC5R.waypointish(st, nil, ctx)
      all = all and #(st.goals or {}) > 0
      if first and all then base.met[st.id] = true elseif not all then base.met[st.id] = nil end
      if all and not base.met[st.id] then target = j break end
      if not way or st.checkpoint then break end
    end
  end
  if not target then return false end
  local d = done_tbl()
  for j = cur, target - 1 do
    local st = steps[j]
    if not st.optional and not d[st.id] then
      d[st.id] = agency_now(); open_seen[st.id] = true; close_step(st)
      say_log("step skipped (a later one is met): " .. st.id)
      if st.on_skip then queue_beats(st.on_skip, st.id) end
    end
  end
  sset("scn.done", d)
  last_eval = -1
  bump()
  return true
end

-- WAITING (Ty: "missions make me wait and I can't tell whether the game
-- wants something from me"). When every open step is waiting on a process
-- the state carries `wait = { label, eta (game s), frac, note }` and the HUD
-- shows a bar, the time left and "Nothing to do". A step waits when:
--   * it says so: `wait = { label, secs }` (from the step's opening), or
--     `wait = { label, var, to = 0 }` (a variable moving to `to`, timed by
--     its own rate; stalled, it is not a wait), and `note` for the line;
--   * or every unmet goal is a hold running out (hold = s), or a process
--     goal (cabin and room air, a reactor running down: scenario.lua
--     progToward) that has been moving its way for WAIT_SETTLE s; the
--     step's `waitLabel` names the process ("The stores filling"), else
--     the goal's label does, and `waitNote` replaces "Nothing to do".
-- `wait = false` never shows one. When the step latches, a warp the player
-- put on for it drops back to ×1, and a warp that would overshoot the end
-- by more than a second steps down first.
WAIT_SETTLE = 1.5
WAIT_SPAN = 10.0      -- game s of samples the rate is read over
WAIT_MAX = 900        -- game s: a process slower than this is not shown as a wait
SC5R.trk = {}
SC5R.waitNow = nil
function SC5R.track(key, p, t)
  local tr = SC5R.trk[key]
  if not tr or p < tr.p - 0.02 or t < tr.t then tr = { t = t, p = p, p0 = p, t0 = t, h = { { t, p } } }; SC5R.trk[key] = tr; return tr end
  -- (the rate over the last WAIT_SPAN s of samples, not sample to sample:
  -- a warp's uneven steps made the time left jump 22 s → 580 s → 10 s)
  if t - tr.t >= 0.5 then
    tr.t, tr.p = t, p
    local h = tr.h
    h[#h + 1] = { t, p }
    while #h > 2 and t - h[2][1] >= WAIT_SPAN do table.remove(h, 1) end
    if t - h[1][1] >= 1.0 then tr.rate = (p - h[1][2]) / (t - h[1][1]) end
  end
  return tr
end
function SC5R.stepWait(s, i, t)
  if s.wait == false then return nil end
  local a = type(s.wait) == "table" and s.wait or nil
  -- (a `secs` wait is over when its time is: the story moves then, and the
  -- step's goals say what is left, a process timed below or a job to do)
  if a and a.secs and t - (step_t0[s.id] or t) >= a.secs then a = nil end
  if a then
    if a.secs then
      local el = t - (step_t0[s.id] or t)
      return { label = a.label or s.text, eta = math.max(0, a.secs - el), frac = math.min(1, el / a.secs), note = a.note, id = s.id }
    end
    local v = a.var and tonumber(vars()[a.var])
    if not v then return nil end
    local to = a.to or 0
    local tr = SC5R.track("w:" .. s.id, -math.abs(v - to), t)
    if not (tr.rate and tr.rate > 1e-6 and t - tr.t0 >= WAIT_SETTLE) then return nil end
    local span = math.abs(tr.p0)
    return { label = a.label or s.text, eta = math.abs(v - to) / tr.rate, frac = span > 0 and math.min(1, 1 - math.abs(v - to) / span) or 1, note = a.note, id = s.id }
  end
  local rows = readings[i]
  if not rows then return nil end
  local out = nil
  for j in ipairs(s.goals or {}) do
    if not (rows[j] and rows[j].met) then
      local m = mem[s.id .. ":" .. j] or {}
      local eta, frac
      if m.holdLeft then eta, frac = m.holdLeft, m.holdFrac
      elseif m.prog then
        local tr = SC5R.track(s.id .. ":" .. j, m.prog, t)
        -- (moving for real: a percent since it started, and done inside WAIT_MAX;
        -- a cabin at 0.00 atm creeping on a leak read 20 minutes at 0 %)
        if tr.rate and tr.rate > 1e-6 and m.prog < 1 and t - tr.t0 >= WAIT_SETTLE and m.prog - tr.p0 >= 0.01
          and (1 - m.prog) / tr.rate <= WAIT_MAX then
          eta = (1 - m.prog) / tr.rate
          frac = tr.p0 < 1 and math.max(0, math.min(1, (m.prog - tr.p0) / (1 - tr.p0))) or 1
        end
      end
      if not eta then return nil end
      if not out or eta > out.eta then out = { label = s.waitLabel or rows[j].label, eta = eta, frac = frac, id = s.id, note = s.waitNote } end
    end
  end
  return out
end
function SC5R.waitTick(open, t)
  local d = done_tbl()
  local w = nil
  for _, i in ipairs(open) do
    local s = sc.steps[i]
    if not s.optional and not d[s.id] then
      local wi = SC5R.stepWait(s, i, t)
      if not wi then w = nil break end
      if not w or wi.eta > w.eta then w = wi end
    end
  end
  local wv = (space and space.warp) and space.warp() or 1
  local was = SC5R.waitNow
  if was and d[was.id] and SC5R.warped and wv > 1.001 then
    -- the wait is over: the warp the player put on for it comes off
    local wc = ref("warp_chip")
    if wc and wc.request then wc.request(1) else space.warp(1) end
    if wc and wc.say then wc.say("Warp ×1 · " .. tostring(was.label) .. ": done") end
    SC5R.warped = false
  end
  if w then
    if wv > 1.001 then
      SC5R.warped = true
      -- never overshoot: the rung that still leaves a second and a half
      if w.eta / wv < 1.5 then
        local wc = ref("warp_chip")
        local best = 1
        for _, r in ipairs((wc and wc.LADDER) or { 1, 5, 10, 50, 100, 1000, 10000 }) do if r < wv and w.eta / r >= 1.5 then best = r end end
        if wc and wc.request then wc.request(best) else space.warp(best) end
      end
    end
  elseif not (was and d[was.id]) then SC5R.warped = false end
  -- (re-described as the seconds tick, not every eval)
  local k = w and string.format("%s|%d|%d", tostring(w.label), math.floor(w.eta), math.floor((w.frac or 0) * 40)) or nil
  if k ~= SC5R.waitKey then SC5R.waitKey = k; bump() end
  SC5R.waitNow = w
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
  -- (scnfix) a later step already met passes the waypoints before it; a
  -- step only waiting on a process says so
  if cur and not done_tbl()[sc.steps[cur].id] then SC5R.skipAhead(cur, ctx) end
  SC5R.waitTick(open, t)
  call_hook("tick", t)
  SC5R.tick(t)
  meters_models(t, ctx)
  weather_tick()
  light_tick(false)
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
      -- (graveyard2) `also`: a second condition that must hold too
      if hit and ev.also then
        mem["ev2:" .. key] = mem["ev2:" .. key] or {}
        hit = R_.evalGoal(ev.also, W, mem["ev2:" .. key], c2)
      end
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
    if hit then fail(f.text, f); break end
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
    setback = setback,      -- (storypolish) the fail screen's words while it is up
    mark = s and s.mark,
    line = line, choice = choice and { who = choice.who, name = choice.name, color = choice.color, tag = choice.tag, portrait = choice.portrait, prompt = choice.prompt,
                                      options = choice.options, t0 = choice.t0, timeout = choice.timeout } or nil,
    cutscene = cut ~= nil, letterbox = cut ~= nil, alarm = alarm_on, vars = vars(),
    hintFlash = (now() - (hintFlashT or -100)) < 2.5 or nil, hasHint = (s and s.hint) and true or nil,
    wait = phase == "running" and SC5R.waitNow or nil,      -- (scnfix) { label, eta, frac, note }
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
  if not (active and sc) or (phase ~= "running" and phase ~= "briefing" and phase ~= "setback") then return nil end
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
    -- (uxpolish 11-11: a bare mark id, "front", read as a bug on the card
    -- and on the world tag; the step's own "at" goal names the place)
    local nm = s.markName
    if not nm then
      for _, g in ipairs(s.goals or {}) do
        local l = g.label and tostring(g.label)
        if l and l:match("^At ") then nm = l:gsub("^At t", "T"):gsub("^At ", "") break end
      end
    end
    if not nm then
      local raw = tostring(s.mark):gsub("^%a+:", "")
      nm = raw:match("^%l+$") and ("The " .. raw) or raw
    end
    if x then step.spot = { x = x, y = y, z = z, body = p and p.body, name = nm, near = "› You're there" } end
  end
  return step
end

-- ── actions ─────────────────────────────────────────────────────────────────
function wantBriefing(on) want_brief = on ~= false end
function go()
  if phase ~= "briefing" and phase ~= "staging_done" then return false end
  if physics and physics.pause and paused_by_us then physics.pause(false) end
  paused_by_us = false
  if not sget("scn.t0") then sset("scn.t0", agency_now() - (tonumber(sget("scn.t0off")) or 0)) end
  set_phase("running")
  start_portraits()
  -- FW-C: world.time held over the site (PLAN §2 F4)
  local wt = type(sc.world) == "table" and sc.world.time
  if type(wt) == "table" and wt.hold ~= false and not LT.hold then
    local el = rulebook().elevationOf(wt.at)
    if el then LT.hold = true; apply_time(el) end
  end
  if not sget("scn.started") then
    sset("scn.started", true)
    queue_beats(sc.on_start, "start")
  end
  last_eval = -1
  return true
end
paused_by_us = false

-- THE CHECKPOINT RESTORE (PLAN §2 F5), the one place a run is put back.
-- Today it RESTAGES: slot `scn` is wiped and staged again from the start
-- table, the checkpoint step's `stage` table on top, the steps before it
-- latched, and the story's state (variables, fired events, objective texts,
-- model crossings, the clock so far) written back from the snapshot taken
-- when the checkpoint opened; the opening is not played again. When engine
-- card 0681 lands (save.copySlot, save.slots, terrain.copySaveDir), this is
-- the function that copies `scn.cp` and its terrain back over `scn` instead.
-- retryFrom nil: from the very start (a RESTART, or a setback before any
-- checkpoint). keep = { setbacks = n } carried across.
function checkpoint_restore(retryFrom, keep)
  local R_ = rulebook()
  local id = sc and sc.id or sget("g_scenario")
  camera_end()
  release_time()
  if physics and physics.pause then physics.pause(false) end
  local snap = retryFrom and sget("scn.cpSnap") or nil
  local ok, err = R_.prepareSlot(id, { save = save, terrain = terrain })
  if not ok then say_log("restart failed: " .. tostring(err)); return false end
  if keep and keep.setbacks then save.set("scn.setbacks", keep.setbacks) end
  if retryFrom then
    local s2 = R_.load(id)
    local d = {}
    for _, sid in ipairs(R_.beforeCheckpoint(s2, retryFrom)) do d[sid] = 0 end
    save.set("scn.done", d)
    save.set("scn.retryFrom", retryFrom)
    save.set("scn.cp", retryFrom)
    if type(snap) == "table" and snap.id == retryFrom then
      save.set("scn.vars", snap.vars or {})
      if snap.ev then save.set("scn.ev", snap.ev) end
      if snap.obj then save.set("scn.obj", snap.obj) end
      if snap.mat then save.set("scn.mat", snap.mat) end
      if snap.m0 then save.set("scn.m0", snap.m0) end
      save.set("scn.t0off", snap.t or 0)
      save.set("scn.started", true)
      save.set("scn.cpSnap", snap)
    end
  end
  scene.load("system")
  return true
end
local function reload_slot(retryFrom) return checkpoint_restore(retryFrom) end
function restart() return reload_slot(nil) end
function retry()
  local cp = sget("scn.cp")
  return reload_slot(cp or nil)
end
function continueFreeplay()
  set_phase("freeplay")
  sset("scn.freeplay", true)
  camera_end()
  -- the world's own light, sky and music again
  release_time()
  if LT.amb then set_ambient(nil) end
  if LT.fog then local wx = ref("weather"); if wx and wx.forceMist then wx.forceMist(nil) end; LT.fog = nil end
  WX = nil
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
-- HINT (interact PLAN §6, S7; Ty 2026-11-10 "hint button does nothing"):
-- → ok, why, text. The first press shows the step's hint (and counts it), a
-- second shows hint2 when there is one, any later press shows it again; the
-- card's hint row is lit for a moment (state().hintFlash) and the caller
-- toasts `text`. No hint on this step: false, "no hint for this step", and
-- the step's own text to read again.
hintFlashT = -100
function hint()
  if not (active and sc) or phase ~= "running" then return false, "no scenario step open" end
  local _, cur = rulebook().openSteps(sc, done_tbl())
  local s = cur and sc.steps[cur]
  if not s then return false, "no scenario step open" end
  if not s.hint then
    local ob = sget("scn.obj") or {}
    return false, "no hint for this step", ob[s.id] or s.objective or s.text
  end
  if not hint_shown[s.id] then
    hint_shown[s.id] = 1
    sset("scn.hints", (tonumber(sget("scn.hints")) or 0) + 1)
  elseif s.hint2 and hint_shown[s.id] == 1 then hint_shown[s.id] = 2 end
  hintFlashT = now()
  bump()
  local txt = (hint_shown[s.id] == 2 and s.hint2) and (s.hint .. " " .. s.hint2) or s.hint
  return true, nil, txt
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

-- ── FW-C: PORTRAITS (PLAN §2 F1; Ty 2026-11-10: "captured since every human
-- should be random") ──────────────────────────────────────────────────────
-- A cast member with `portrait = "auto"` and `crew = <name>` is photographed
-- once, after staging, from their own body in this playthrough (the face the
-- generator gave them, or the one their `look` seed pins): a camera of our
-- own a little in front of the face, re-placed EVERY FRAME from the body's
-- pose until the capture answers (the planet moves metres a tick: a camera
-- placed once would drift off the face before the picture is drawn), then
-- camera.captureTexture → "img:N", the plate's picture for the rest of the
-- session. One member at a time, off the per-frame path (a job). A member
-- with no body in range keeps the booth's png (<id>/<key>.png), which
-- tools/perf/portraitbooth.sh bakes with the same rig (opts.bytes).
local portraits = {}      -- cast key → texture name
local pcam = nil          -- { node, target = { id | node }, back, done } while a capture runs
PROF.portrait_ms, PROF.portraits = 0, 0
function portraitTex(key) return portraits[key] end
local function body_node(id)
  local C = ref("crew")
  if not (C and id) then return nil end
  if id == (C.activeId and C.activeId()) then
    local pw = ref("planet_walker")
    if pw and pw.onFoot == false then return nil end
    return find and find("Astronaut") or nil
  end
  local n = C.bodyOf and C.bodyOf(id)
  if n and n.valid ~= false then return n end
  -- (scn_vacuum) a member seated aboard a craft is a doll in the seat: the
  -- picture is taken of that (the crew strip films the same one)
  n = C.dollOf and C.dollOf(id)
  if n and n.valid ~= false then return n end
  return nil
end
-- the body's helmet parts by name (suit.lua's attachments under the AstroModel)
local function find_named(n, names, out, depth)
  if depth > 6 or not (n and n.children) then return out end
  for _, c in ipairs(n:children() or {}) do
    if names[c.name] then out[#out + 1] = c end
    find_named(c, names, out, depth + 1)
  end
  return out
end
-- the face's point and the way the face looks, THIS frame
local function face_frame(n, id)
  local x, y, z = n.x, n.y, n.z
  if n.worldPos then local p = n.worldPos; if p and p.x then x, y, z = p.x, p.y, p.z end end
  local d = space.dominant(x, y, z)
  local b = d and space.body(d)
  if not b then return nil end
  local ux, uy, uz = x - b.x, y - b.y, z - b.z
  local l = math.sqrt(ux * ux + uy * uy + uz * uz)
  ux, uy, uz = ux / l, uy / l, uz / l
  -- the way the face looks: the suit model's +Z (crew.lua: "the rig looks
  -- along its node's +Z"), this frame
  local fx, fy, fz = nil, nil, nil
  for _, ch in ipairs(n.children and n:children() or {}) do
    if ch.name == "AstroModel" and ch.worldForward then
      local f = ch:worldForward()
      fx, fy, fz = -f.x, -f.y, -f.z
    end
  end
  -- the head itself where it can be read (the Face rides the Head bone): a
  -- head turned with the view (the player's) is met face on
  if not (params and params.portrait_face_node == false) then
    local fn = find_named(n, { Face = true }, {}, 0)[1]
    if fn and fn.worldForward and fn.worldPos then
      local f = fn:worldForward()
      local hx, hy, hz = -f.x, -f.y, -f.z
      -- (only if it agrees with the body within 100°: a rig whose axes differ is not trusted)
      if fx == nil or hx * fx + hy * fy + hz * fz > -0.17 then fx, fy, fz = hx, hy, hz end
    end
  end
  if not fx then
    local f = n.toWorld and n:toWorld(vec3(0, 0, 1)) or nil
    if f then fx, fy, fz = f.x - x, f.y - y, f.z - z else fx, fy, fz = 1, 0, 0 end
  end
  local du = fx * ux + fy * uy + fz * uz
  fx, fy, fz = fx - ux * du, fy - uy * du, fz - uz * du
  local fl = math.sqrt(fx * fx + fy * fy + fz * fz)
  if fl < 1e-6 then return nil end
  fx, fy, fz = fx / fl, fy / fl, fz / fl
  local hh = (params and params.portrait_head) or 0.70
  return x + ux * hh, y + uy * hh, z + uz * hh, fx, fy, fz, ux, uy, uz
end
local function pcam_place()
  local c = pcam
  if not (c and c.node and c.node.valid ~= false) then return end
  local n = c.target
  if not (n and n.valid ~= false) then return end
  -- (scn_vacuum) a member seated aboard: their eye in the seat, from the IVA
  -- rig (the crew strip films them the same way). face_frame takes "up" as
  -- the ground's normal, which in orbit is nowhere near the seat's up: the
  -- booth photographed the seat cushion.
  if c.seat then
    local I = ref("iva")
    local eye, right, up, back
    if I and I.eyeOf then eye, right, up, back = I.eyeOf(c.seat.v, c.seat.uid, c.seat.slot) end
    if eye then
      local d = c.dist and math.min(c.dist, 0.6) or 0.42
      local cc = c.node.getcomponent and c.node:getcomponent("Camera")
      if cc and c.fdist ~= d then c.fdist = d; pcall(function() cc.fovY = 2 * math.atan(0.2 / d) end) end
      c.node.pos = eye - back * d - up * 0.03
      c.node:lookAt(eye - up * 0.06, up)
      return
    end
  end
  local hx, hy, hz, fx, fy, fz, ux, uy, uz = face_frame(n, c.id)
  if not hx then return end
  -- head and shoulders: a little under the eyes, from a step away
  local dist, lift, aim = c.dist or 0.95, 0.0, -0.06
  -- a wall, a pipe or a console in front of the face: the camera comes in
  -- before it (the head's own body is not in the way: the ray starts clear of it)
  -- and if the way in front is shut (a console, a wall), a three-quarter
  -- view from the most open side (kept for the rest of the capture)
  if raycast then
    local function clearance(ax, ay, az)
      local ok, hit = pcall(raycast, hx + ax * 0.12, hy + ay * 0.12, hz + az * 0.12, ax, ay, az, dist - 0.12, n)
      if ok and hit and hit.distance then return 0.12 + hit.distance - 0.06 end
      return dist
    end
    local rx, ry, rz = uy * fz - uz * fy, uz * fx - ux * fz, ux * fy - uy * fx
    local best_a, best_c = c.side or 0, -1
    for _, a in ipairs(c.side and { c.side } or { 0, 35, -35, 70, -70 }) do
      local ca, sa = math.cos(math.rad(a)), math.sin(math.rad(a))
      local cl = clearance(fx * ca + rx * sa, fy * ca + ry * sa, fz * ca + rz * sa)
      if cl > best_c + 0.05 then best_a, best_c = a, cl end
      if cl >= dist - 0.01 then break end
    end
    c.side = best_a
    local ca, sa = math.cos(math.rad(best_a)), math.sin(math.rad(best_a))
    fx, fy, fz = fx * ca + rx * sa, fy * ca + ry * sa, fz * ca + rz * sa
    dist = math.max(0.3, best_c)
  end
  -- (the same head-and-shoulders frame however near: the lens widens)
  if c.fdist ~= dist then
    c.fdist = dist
    local cc = c.node.getcomponent and c.node:getcomponent("Camera")
    if cc then pcall(function() cc.fovY = 2 * math.atan(0.2 / dist) end) end
  end
  c.node.pos = vec3(hx + fx * dist + ux * lift, hy + fy * dist + uy * lift, hz + fz * dist + uz * lift)
  c.node:lookAt(vec3(hx + ux * aim, hy + uy * aim, hz + uz * aim), vec3(ux, uy, uz))
end
local HIDE_FOR_PORTRAIT = { ["Helmet Visor"] = true, ["Helmet Lamps"] = true }
-- capturePortrait(id, { look = seed, expression, bytes = true, w }, cb):
-- cb(tex | bytes | nil, why). `look` borrows the body's face for the shot.
function capturePortrait(id, opts, cb)
  opts = opts or {}
  if pcam then return false, "busy" end
  local n = body_node(id)
  if not (n and createNode and camera) then if cb then cb(nil, "no body") end return false, "no body" end
  local CF = ref("crew_faces")
  if opts.expression and CF and CF.force then CF.force(id, rulebook().faceName(opts.expression), 1, 4) end
  local fc = opts.look and body_script("face", id) or nil
  if fc and fc.setLook and CF and CF.lookFor then pcall(fc.setLook, CF.lookFor(opts.look, id, "booth")) end
  local w = opts.w or 256
  -- the gold sun visor and the lamps up for the picture (a face, not a reflection)
  -- the head square to the camera for the picture (a `look` let go, put back after)
  local cbl = body_script("crew_body", id)
  local prev_look = cbl and cbl.lookNow and cbl.lookNow() or nil
  -- (eyes and head to the portrait camera, wherever it is this frame)
  local function at_cam()
    local cn = pcam and pcam.node
    if not (cn and cn.valid ~= false) then return nil end
    local p = cn.pos
    return p.x, p.y, p.z, 1
  end
  if cbl and cbl.lookSelf then cbl.lookSelf(at_cam) end
  local fcl = body_script("face", id)
  local prev_gaze = fcl and fcl.gaze or nil
  if fcl then fcl.gaze = at_cam end
  -- (gy3) a conversation's look stands aside for the picture (talk_tick puts it back)
  portraitBusy = id
  if cbl and cbl.talkSelf then pcall(cbl.talkSelf, nil) end
  if fcl then fcl.talkGaze = nil end
  -- the player's own gold visor up (suit.lua keeps the Astronaut's helmet parts)
  local su, visor0 = ref("suit"), nil
  local C_ = ref("crew")
  if C_ and id == (C_.activeId and C_.activeId()) and su and su.visorDown and su.setVisor then
    local okv, down = pcall(su.visorDown)
    if okv and down then visor0 = true; pcall(su.setVisor, false) end
  end
  local hidden = {}
  -- (graveyard2, FW-C follow-up) the player's own picture was taken through
  -- the helmet's glass, and its reflection band crossed the face: for the
  -- member you control the whole bubble is off for the picture
  local hide = HIDE_FOR_PORTRAIT
  -- (scn_vacuum) and for a member seated in a craft: inside a pod the
  -- bubble put the face small and dark behind its ring (helmets go on when
  -- a cabin vents), not the head-and-shoulders the plate frames
  local seated_doll = C_ and C_.dollOf and C_.dollOf(id) == n
  if opts.noHelmet or seated_doll or (C_ and id == (C_.activeId and C_.activeId())) then
    hide = { Helmet = true, ["Helmet Visor"] = true, ["Helmet Lamps"] = true }
  end
  for _, h in ipairs(find_named(n, hide, {}, 0)) do
    if h.visible ~= false then h.visible = false; hidden[#hidden + 1] = h end
  end
  pcam = { target = n, id = id, making = true, fc = fc, w0 = wall(), hidden = hidden, f0 = wall(), dist = opts.dist }
  -- (scn_vacuum) seated aboard a craft: the seat it is, for the IVA eye
  if C_ and C_.craftOf and C_.dollOf and C_.dollOf(id) == n then
    local v = C_.craftOf(id)
    local u, k = nil, nil
    if v and v.memberSlot then u, k = v.memberSlot(id) end
    if u then pcam.seat = { v = v, uid = u, slot = k } end
  end
  local c = pcam
  createNode("Scenario Portrait Cam", nil, function(cn)
    c.node = cn
    pcall(function() cn:setCamera { width = w, height = w, fovY = 0.42, active = false, near = 0.05, far = 400 } end)
    pcam_place()
    local function answer(v, why)
      if c.fc and c.fc.setLook then pcall(c.fc.setLook, nil) end
      for _, h in ipairs(c.hidden or {}) do if h.valid ~= false then h.visible = true end end
      if visor0 then pcall(su.setVisor, true) end
      if cbl and cbl.lookSelf then pcall(cbl.lookSelf, prev_look) end
      if fcl then fcl.gaze = prev_gaze end
      portraitBusy = nil
      if cn.valid ~= false then pcall(cn.destroy, cn) end
      PROF.portrait_ms = PROF.portrait_ms + (wall() - c.w0) * 1000
      PROF.portraits = PROF.portraits + 1
      pcam = nil
      if cb then pcall(cb, v, why) end
    end
    local okc, err
    if opts.bytes then okc, err = pcall(camera.capture, cn, { w = w, h = w }, answer)
    else okc, err = pcall(camera.captureTexture, cn, { w = w, h = w }, answer) end
    if not okc then answer(nil, tostring(err)) end
  end)
  return true
end
-- the job: every auto cast member with a body, one after another
local function portrait_job(only, now)
  for _ = 1, now and 3 or 30 do coroutine.yield() end          -- (the bodies set down and posed first)
  local keys = {}
  for k, c in pairs(sc.cast or {}) do if c.portrait == "auto" and c.crew and (only == nil or c.crew == only) then keys[#keys + 1] = k end end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local c = sc.cast[k]
    local id = member_id(c.crew)
    -- (graveyard2) never the member you control: in first person their head
    -- is not drawn (the picture was the wall behind it), and through the
    -- helmet's glass the reflection crossed the face. They keep the booth's
    -- picture (tools/perf/portraitbooth.sh takes it from their body).
    local C_ = ref("crew")
    if id and C_ and C_.activeId and C_.activeId() == id then id = nil end
    -- a quiet moment: no cutscene (its looks and walks turn heads), not walking
    local t1q = wall() + (now and 0 or 60)
    while wall() < t1q do
      local cb = id and body_script("crew_body", id)
      -- (graveyard2 fix: and facing where it means to: a body still easing
      -- round to its post's facing was pictured from behind the head)
      if not cut and not (cb and cb.walking and cb.walking()) and not walks[id]
        and not (cb and cb.facingSettled and not cb.facingSettled()) then break end
      coroutine.yield()
    end
    -- (gy3) a gesture (Priya bent over her bench) is set aside for the
    -- picture, the body given a moment to straighten, and put back after:
    -- the plate showed the back of her head
    local gest = id and C_ and C_.get and C_.get(id)
    gest = gest and type(gest.gesture) == "table" and gest.gesture or nil
    if gest then
      C_.patch(id, { gesture = false })
      local tg = wall() + 0.9
      while wall() < tg do coroutine.yield() end
    end
    local got = false
    local ok = id and capturePortrait(id, { expression = c.expression }, function(tex) if tex then portraits[k] = tex; bump() end got = true end)
    if ok then
      local t1 = wall() + 5
      while not got and wall() < t1 do coroutine.yield() end
    end
    if gest then
      local r2 = C_.get(id)
      if r2 and r2.gesture == nil then C_.patch(id, { gesture = gest }) end
    end
    coroutine.yield()
  end
  say_log(string.format("portraits: %d captured (%.1f ms of capture waits)", PROF.portraits, PROF.portrait_ms))
end
-- (scn_dust) a cast member who joins later (a `spawn` crew beat): their own
-- face, photographed once they have arrived
function portraitFor(name, now)
  jobs[#jobs + 1] = coroutine.create(function() portrait_job(name, now) end)
end
local portraits_started = false
function start_portraits()
  if portraits_started or not (sc and sc.cast) then return end
  portraits_started = true
  for _, c in pairs(sc.cast) do
    if c.portrait == "auto" and c.crew then jobs[#jobs + 1] = coroutine.create(portrait_job); return end
  end
end

-- ── CAREER BEATS (missions S0) ──────────────────────────────────────────────
-- The beat engine above, in a career save (no `scn` slot, no scenario):
-- missions, the Medical Bay and the client stories play lines, a choice, a
-- shot, a walk or the weather from DATA (scripts/mission_story.lua).
--
--   runBeats(list, ctx) → true | false, why     stopBeats(why)     careerActive()
--   ctx = { id, cast = { key = { name, tag, color, portrait, radio, link, crew } },
--           vars = {} (the caller's table: choices and `var` beats write it;
--                      the caller saves it if it should outlive the scene),
--           refs = { name = { body, x, y, z } | fn() → that },   (a beat's ref)
--           marks = { name = { b, x, y, z } },                   (mark:<name>)
--           crew = { name = record id },     (survivors: off the roster)
--           sequences = { name = beats }, hooks = { name = fn(api) },
--           onDone = fn(vars, why) }
--
-- RULES. Only the beats in CAREER_BEATS run (a scenario's goals, steps,
-- objectives, structures and checkpoints are not there to drive): anything
-- else is dropped when the run starts and named in lastCareer.dropped.
-- Nothing writes `scn.*` while it plays (sset). One run at a time; another
-- waits its turn. A scenario save owns the runner: runBeats refuses there.
-- Dialogue goes to scenario_stage's plate (the cast's portrait, the say's
-- `with`), a radio voice (cast `radio`, or Ops) to the Ops strip, garbled
-- when its `link` reads no comms path (link_up), as in a scenario.
CAREER_BEATS = { say = true, ops = true, caption = true, choice = true, shot = true, camera = true, wait = true,
                 sound = true, var = true, add = true, branch = true, face = true, look = true, turn = true,
                 gesture = true, pose = true, walk = true, board = true, drive = true, place = true, charge = true,
                 give = true, wear = true, weather = true, mark = true, hook = true, run = true, cutscene = true }
lastCareer = nil          -- (probes, tests) { id, beats, dropped, t, done, why }
CRB.q = {}

-- (pure) a beat list made fit for a career run: what is not a career beat is
-- dropped (its name added to `dropped`); a choice's options and a branch's
-- beats are cleaned the same way; an option's `hook` runs as a beat; an
-- option's `step` (a scenario's goto) is dropped.
function careerClean(list, dropped)
  dropped = dropped or {}
  local out = {}
  for _, b in ipairs(type(list) == "table" and list or {}) do
    local k, v = next(type(b) == "table" and b or {})
    if k and CAREER_BEATS[k] then
      if k == "choice" and type(v) == "table" then
        local c = {}
        for kk, x in pairs(v) do c[kk] = x end
        c.options = {}
        for i, o in ipairs(v.options or {}) do
          local bl = {}
          if o.hook then bl[#bl + 1] = { hook = o.hook } end
          for _, x in ipairs(careerClean(o.beats, dropped)) do bl[#bl + 1] = x end
          if o.step then dropped[#dropped + 1] = "choice.step" end
          c.options[i] = { text = o.text, var = o.var, run = o.run, beats = #bl > 0 and bl or nil }
        end
        out[#out + 1] = { choice = c }
      elseif k == "branch" and type(v) == "table" then
        local c = {}
        for kk, x in pairs(v) do c[kk] = x end
        c.beats = v.beats and careerClean(v.beats, dropped) or nil
        c.elseBeats = v.elseBeats and careerClean(v.elseBeats, dropped) or nil
        out[#out + 1] = { branch = c }
      else
        out[#out + 1] = b
      end
    else
      dropped[#dropped + 1] = tostring(k)
    end
  end
  return out, dropped
end

-- a career run's own ref → { body, x, y, z }, false (its mark is not
-- there: nothing, never a scenario's), or nil (not the run's: the world's)
CRB.ref = function(r)
  local C = CAREER
  local x = C.refs[r]
  if type(x) == "function" then local ok, p = pcall(x); return (ok and type(p) == "table") and p or false end
  if type(x) == "table" then return x end
  if type(r) == "string" then
    local n = r:match("^mark:(.+)$")
    if n then
      local m = C.marks[n]
      if not m then return false end
      return { body = m.b or m.body, x = m.x, y = m.y, z = m.z }
    end
  end
  return nil
end

CRB.api = function()
  return { vars = CAREER and CAREER.vars or {}, var = var, setVar = setVar, ctx = CAREER and CAREER.ctx,
           say = function(who, text, opts)
             local b = { who = who, text = text }
             for k2, x in pairs(opts or {}) do b[k2] = x end
             queue_beats({ { say = b } }, "career", true, cut and cut.id or nil)
           end,
           beats = function(list) queue_beats(careerClean(list), "career", true, cut and cut.id or nil) end }
end

-- the plate and the strip, as scenario_ui hands them over in a scenario
-- (scenario_ui stands down in a career save)
CRB.hooked = false
CRB.listen = function()
  if CRB.hooked then return end
  CRB.hooked = true
  local function stage() return ref("scenario_stage") end
  if not listeners.say then
    listeners.say = function(l)
      local os_ = ref("ops_strip")
      local st = stage()
      if type(l) == "table" and (l.who == "ops" or l.radio) and os_ and os_.say
        and not (st and st.cutsceneOn and st.cutsceneOn()) then
        os_.say(l.text, l.name or "Ops", function() lineDone() end)
        return
      end
      if st and st.onSay then st.onSay(l) end
    end
  end
  if not listeners.choice then listeners.choice = function(c) local st = stage(); if st and st.onChoice then st.onChoice(c) end end end
  if not listeners.cutscene then listeners.cutscene = function(on) local st = stage(); if st and st.onCutscene then st.onCutscene(on) end end end
end

CRB.begin = function(list, ctx)
  local dropped = {}
  local beats = careerClean(list, dropped)
  local seqs = {}
  for nm, sq in pairs(ctx.sequences or {}) do seqs[nm] = careerClean(sq, dropped) end
  local hooks = {}
  for nm, f in pairs(ctx.hooks or {}) do
    if type(f) == "function" then hooks[nm] = function() return f(CRB.api()) end end
  end
  sc = { id = "career:" .. tostring(ctx.id or "beats"), cast = ctx.cast or {}, sequences = seqs, vars = {},
         _dir = ctx.dir or "", hooks = "career", _hooks = hooks, _career = true }
  CAREER = { ctx = ctx, id = ctx.id, vars = type(ctx.vars) == "table" and ctx.vars or {}, refs = ctx.refs or {},
             marks = ctx.marks or {}, crew = ctx.crew, t0 = now() }
  CRB.listen()
  local cs = nil
  if beats[1] and beats[1].cutscene then cs_seq = cs_seq + 1; cs = cs_seq end
  queue_beats(beats, "career", false, cs)
  lastCareer = { id = ctx.id, beats = #beats, dropped = dropped, t = now() }
  say_log(string.format("career beats %s: %d%s", tostring(ctx.id), #beats,
    #dropped > 0 and (" (dropped: " .. table.concat(dropped, ", ") .. ")") or ""))
  bump()
end

CRB.finish = function(why)
  local C = CAREER
  if not C then return end
  CAREER = nil
  sc = nil
  if lastCareer and lastCareer.id == C.id then lastCareer.done, lastCareer.why, lastCareer.t1 = true, why or "done", now() end
  say_log("career beats " .. tostring(C.id) .. " " .. tostring(why or "done"))
  bump()
  if C.ctx.onDone then local ok, err = pcall(C.ctx.onDone, C.vars, why or "done"); if not ok then say_log("onDone: " .. tostring(err)) end end
  local nxt = table.remove(CRB.q, 1)
  if nxt then CRB.begin(nxt.list, nxt.ctx) end
end

function runBeats(list, ctx)
  ctx = ctx or {}
  -- (a scenario's save owns the runner, decided or not yet)
  local scn_save = save and save.slot and save.slot() == SLOT and type(save.get("g_scenario")) == "string"
  if active == true or (active == nil and scn_save) then return false, "a scenario is running" end
  if type(list) ~= "table" or #list == 0 then return false, "no beats" end
  if CAREER then CRB.q[#CRB.q + 1] = { list = list, ctx = ctx }; return true, "queued" end
  CRB.begin(list, ctx)
  return true
end

-- the run stops where it is (a contract abandoned, the bay walked out of):
-- the line, the choice and the shot go, and `onDone(vars, why)` is told
function stopBeats(why, id)
  if not CAREER or (id and CAREER.id ~= id) then
    if id then
      local keep = {}
      for _, q in ipairs(CRB.q) do if q.ctx.id ~= id then keep[#keep + 1] = q end end
      CRB.q = keep
    end
    return false
  end
  beatq, beat_busy = {}, nil
  if choice then choice = nil end
  line = nil
  if cam then camera_end() end
  if cut then cut_end() end
  for id2 in pairs(walks) do walks[id2] = nil end
  local st = ref("scenario_stage")
  if st and st.dropSays then pcall(st.dropSays) end
  CRB.finish(why or "stopped")
  return true
end
function careerActive() return CAREER ~= nil, CAREER and CAREER.id or nil, #CRB.q end
function careerLine() return CAREER and line or nil, CAREER and choice or nil end

CRB.sync_t = 0
CRB.tick = function(dt)
  -- (a beat that throws ends the run, never the frame after frame)
  local okb, errb = pcall(beats_tick)
  if not okb then say_log("career beat error: " .. tostring(errb)); stopBeats("error") return end
  if CAREER == nil then return end
  if next(walks) then walks_tick() end
  if delayed and #delayed > 0 then delays_tick() end
  weather_tick()
  input_tick()
  -- the plate follows the runner (a line timed out, a choice answered)
  CRB.sync_t = CRB.sync_t + (dt or 0)
  if CRB.sync_t >= 0.25 then
    CRB.sync_t = 0
    local st = ref("scenario_stage")
    if st and st.sync then pcall(st.sync, { line = line, choice = choice }) end
  end
  if #beatq == 0 and not beat_busy and not choice and not cam and not cut and not line and not next(walks) then
    CRB.finish("done")
  end
end
-- ── end CAREER BEATS ────────────────────────────────────────────────────────

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
  if active == false then if CAREER then CRB.tick(dt) end return end
  if active == nil and not decide() then if CAREER then CRB.tick(dt) end return end
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
      if want_brief and not retried then
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
      cores_tick()      -- F8: the CORE page, the spots, reactions after a terminal closes
    end
  end
  if phase ~= "loading" and phase ~= "staging" then
    beats_tick()
    if delayed and #delayed > 0 then delays_tick() elseif delayed == nil and phase == "running" then dl_list() end
    if LT.elE or LT.ambE then light_tick(true) end
    if next(walks) then walks_tick() end
    if talk.live then talk_tick() end
    if #jobs > 0 then jobs_tick() end
    input_tick()
  end
  if finishing and #beatq == 0 and not cam and not beat_busy then finish_now() end
  if phase == "setback" then setback_tick() end
  -- Ctrl+F10: the goal readings on screen
  if input and input.pressed and input.pressed("f10") and input.key and input.key("ctrl") then overlay = not overlay end
end

function lateUpdate(node, dt)
  if pcam then
    pcam_place()
    -- the hitch a capture costs: the longest frame while one runs
    local t = wall()
    if pcam.f0 then PROF.portrait_worst_ms = math.max(PROF.portrait_worst_ms or 0, (t - pcam.f0) * 1000) end
    pcam.f0 = t
  end
  if (active or CAREER) and (line or choice or cut or alarm_on) then draw_builtin() end
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
