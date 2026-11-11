-- BASE LOG — what happened at a base, in order, for its terminals' LOG page.
--
-- (The interaction plan, work/interact/PLAN.md §4.1, slice S3.) One ring of
-- events per structure: breaker trips and hand switching, SCRAMs, reactor
-- trips and start-ups, pump starts and stops, valves opened and shut, doors
-- held, locked or cycled, life machines switched, air alarms. The systems
-- call
--
--     local BL = findScript("base_log")
--     BL.add(sid, kind, text, who)
--
-- and the terminals (scripts/terminal.lua) read `entries(sids, n)`. Kinds are
-- short words the LOG page colours: "trip", "alarm", "scram" (red), "warn"
-- (amber), "power", "fluid", "door", "air", "reactor", "logic", "lore",
-- "note" (green).
--
-- WHO is the hand on the switch: the active crew member's name unless the
-- caller says ("auto", "logic", "protection"); a press made at a console
-- carries the console's name too (`via`, set by the terminal around its own
-- presses): "Halloran at C-1".
--
-- SAVE: `log.<sid>` = { { t, k, x, w } … } (oldest first, at most RING_N),
-- written every SAVE_EVERY s when something was added (and on saveNow()).
-- Times are the agency clock (game seconds since the save began).
--
-- The rules are pure (the globals under PURE take plain tables:
-- tests/smoke_terminal.lua); the scene half lives on the ContextLib node and
-- does nothing a frame but check a timer, plus a 1 Hz look at the air alarms
-- and the breaker hook.

defaults = {}

RING_N = 200
SAVE_EVERY = 30
DEDUPE_S = 2.0            -- the same kind and words within this (game s) is one entry

-- ── PURE ────────────────────────────────────────────────────────────────────
function newRing() return { n = 0, items = {} } end
-- Add an entry { t, k, x, w } (oldest first, capped at RING_N). A repeat of
-- the newest (same kind and words within DEDUPE_S) is dropped. → true if added
function push(ring, e, cap)
  if type(ring) ~= "table" or type(e) ~= "table" then return false end
  cap = cap or RING_N
  local it = ring.items
  local last = it[#it]
  if last and last.k == e.k and last.x == e.x and math.abs((e.t or 0) - (last.t or 0)) < DEDUPE_S then return false end
  it[#it + 1] = e
  while #it > cap do table.remove(it, 1) end
  ring.n = (ring.n or 0) + 1
  return true
end
-- The newest `n` entries, newest first.
function newest(ring, n)
  local out = {}
  local it = ring and ring.items or {}
  for i = #it, math.max(1, #it - (n or #it) + 1), -1 do out[#out + 1] = it[i] end
  return out
end
-- The plain table the save keeps, and back.
function pack(ring)
  local o = {}
  for _, e in ipairs(ring and ring.items or {}) do o[#o + 1] = { t = e.t, k = e.k, x = e.x, w = e.w } end
  return o
end
function unpack_(t)
  local r = newRing()
  if type(t) ~= "table" then return r end
  for _, e in ipairs(t) do
    if type(e) == "table" and type(e.x) == "string" then
      r.items[#r.items + 1] = { t = tonumber(e.t) or 0, k = tostring(e.k or "note"), x = e.x, w = e.w ~= nil and tostring(e.w) or nil }
    end
  end
  while #r.items > RING_N do table.remove(r.items, 1) end
  r.n = #r.items
  return r
end
-- Several rings merged, newest first, at most n: rings = { [sid] = ring }
function merged(rings, n)
  local all = {}
  for sid, r in pairs(rings or {}) do
    for i, e in ipairs(r.items or {}) do all[#all + 1] = { e = e, sid = sid, i = i } end
  end
  table.sort(all, function(a, b)
    if (a.e.t or 0) ~= (b.e.t or 0) then return (a.e.t or 0) > (b.e.t or 0) end
    if a.sid ~= b.sid then return tostring(a.sid) < tostring(b.sid) end
    return a.i > b.i
  end)
  local out = {}
  for i = 1, math.min(n or #all, #all) do
    local q = all[i]
    out[i] = { t = q.e.t, k = q.e.k, x = q.e.x, w = q.e.w, sid = q.sid }
  end
  return out
end
-- "D3 03:12:40": the agency clock as a day and a time
function stamp(t)
  t = math.max(0, math.floor(tonumber(t) or 0))
  local d = math.floor(t / 86400) + 1
  local s = t % 86400
  return string.format("D%d %02d:%02d:%02d", d, math.floor(s / 3600), math.floor(s % 3600 / 60), s % 60)
end
-- How alarming a kind is: 2 red, 1 amber, 0 green
LEVEL = { trip = 2, alarm = 2, scram = 2, melt = 2, warn = 1, forced = 1, lore = 0 }
function levelOf(k) return LEVEL[k] or 0 end
-- One line as the LOG page prints it: "D3 03:12:40  TRIP B-1 opened on overload · protection"
function lineOf(e)
  local who = e.w and (" · " .. e.w) or ""
  return string.format("%s  %s%s", stamp(e.t), tostring(e.x), who)
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

R = {}                    -- sid → ring (loaded from the save the first time it is asked)
version = 0               -- bumped on every add (the terminal redraws its LOG page)
via = nil                 -- set by the terminal around a press made at a console: "C-1"
local dirty = {}
local save_t = -10

local function ring_of(sid)
  if sid == nil then return nil end
  local r = R[sid]
  if not r then
    r = unpack_(save and save.get and save.get("log." .. tostring(sid)))
    R[sid] = r
  end
  return r
end
ringOf = ring_of

-- The active crew member's name (the hand on the switch), or nil.
local function crew_name()
  local C = ref("crew")
  if not (C and C.activeId and C.get) then return nil end
  local ok, r = pcall(function() return C.get(C.activeId()) end)
  if not (ok and type(r) == "table" and r.name) then return nil end
  return tostring(r.name):match("(%S+)$") or tostring(r.name)
end

-- Add an event to structure sid's log. `who` nil = the active crew member
-- ("auto", "logic", "protection" for the machines themselves). → true if added
function add(sid, kind, text, who)
  if sid == nil or type(text) ~= "string" or text == "" then return false end
  local r = ring_of(sid)
  if who == nil then who = crew_name() end
  if who == false then who = nil end
  if via and who and who ~= "auto" and who ~= "logic" and who ~= "protection" then who = who .. " at " .. tostring(via) end
  local ok = push(r, { t = agency_now(), k = kind or "note", x = text, w = who })
  if ok then dirty[sid] = true; version = version + 1 end
  return ok
end
-- The newest n entries of structures `sids` (a list, or one sid), newest first
function entries(sids, n)
  if type(sids) ~= "table" then sids = { sids } end
  local rings = {}
  for _, sid in ipairs(sids) do rings[sid] = ring_of(sid) end
  return merged(rings, n or 40)
end
function count(sid) local r = ring_of(sid); return r and #r.items or 0 end

function saveNow()
  if not (save and save.set) then return end
  for sid in pairs(dirty) do
    local r = R[sid]
    if r then save.set("log." .. tostring(sid), pack(r)) end
  end
  dirty = {}
end

-- ── what the systems don't tell us themselves ───────────────────────────────
-- A breaker's every change (base_power.onBreaker: its hook list is made anew
-- when base_power starts, so the hook is checked for once a second).
local function on_breaker(sid, uid, state, by)
  local PI = ref("part_info")
  local who = "the breaker"
  if PI and PI.designate then local ok, n = pcall(PI.designate, sid, uid); if ok and n then who = n end end
  if by == "trip" then
    local BG = ref("base_grid")
    local f = BG and BG.partFlow and BG.partFlow(sid, uid) or {}
    add(sid, "trip", string.format("TRIP %s opened on overload%s", who, (f.rating and f.kW) and string.format(" (%.1f of %.1f kW)", f.kW, f.rating) or ""), "protection")
  elseif by == "logic" then
    add(sid, "power", string.format("%s %s by its control signal", who, state == "closed" and "closed" or "opened"), "logic")
  else
    add(sid, "power", string.format("%s %s", who, state == "closed" and "closed" or "opened"))
  end
end
breakerHook = on_breaker
local function hook_breakers()
  local BP = ref("base_power")
  if not (BP and type(BP.onBreaker) == "table") then return end
  for _, fn in ipairs(BP.onBreaker) do if fn == on_breaker then return end end
  BP.onBreaker[#BP.onBreaker + 1] = on_breaker
end
-- The air alarms (room_air.alarms(): key → { sid, rid, … }): a new one is logged
local seen_alarm = {}
local function look_alarms()
  local RA = ref("room_air")
  if not (RA and RA.alarms) then return end
  local ok, A = pcall(RA.alarms)
  if not (ok and type(A) == "table") then return end
  local cur = {}
  for k, al in pairs(A) do
    cur[k] = true
    if not seen_alarm[k] and type(al) == "table" and al.sid then
      add(al.sid, "alarm", string.format("ALARM DEPRESSURISATION Room %s: %s", tostring(al.rid or "?"), tostring(al.cause or "a leak")), "auto")
    end
  end
  seen_alarm = cur
end

local look_t = -10
function start(node)
  if findScripts then
    local all = findScripts("base_log")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  R, dirty, seen_alarm, version, via = {}, {}, {}, 0, nil
  save_t, look_t = now(), -10
end
-- (probes: the save read again)
function reloadFromSave() R, dirty = {}, {} end

function update(node, dt)
  local t = now()
  if t - look_t >= 1.0 then
    look_t = t
    hook_breakers()
    look_alarms()
  end
  if t - save_t >= SAVE_EVERY then
    save_t = t
    if next(dirty) then saveNow() end
  end
end
