-- ELECTRONICS — the rulebook every electrical thing on a craft is played by.
--
-- One file, no scene access, no state of its own: the builder, the flight
-- controller, the comms network, the HUD and the Tracking Station all ask it
-- the same questions and get the same answers. It is hosted on a manager node
-- in both the builder and the system scene and reached with
-- `findScript("electronics")`; the smoke tests load it straight from disk.
--
-- ── THE MODEL ───────────────────────────────────────────────────────────────
--
-- A part's electronics are a list of MODULES on its blueprint record (`mods`):
--
--     pod   = { {type="command", crew=1, draw=0.05}, {type="wheel", torque=1, draw=0.5},
--               {type="battery", ec=40} }
--     dish  = { {type="antenna", power=1.2e6, relay=true, dish=true, rate=12, draw=0.6},
--               {type="deploy", anim="dish"} }
--
-- A MODULE TYPE (MODULES below) is data: the switches it has (`toggles`, each
-- a named STATE with an on and an off verb), the one-shot things it can do
-- (`triggers`), the continuous settings it can be driven to (`axes`, for
-- actuators), and what it reads out. From that data every part gets its
-- ACTIONS without anyone writing them by hand:
--
--     toggle state "deployed"  →  "deployed.on"  (Extend)
--                                  "deployed.off" (Retract)
--                                  "deployed.toggle"
--     trigger "decouple"       →  "decouple"
--     axis "angle"             →  "angle.inc" "angle.dec" "angle.center"
--
-- Each part keeps its live state in `rec.st` (`{ deployed = true, lit = false,
-- charge = 37 }`), which rides the blueprint record everywhere the record goes
-- — the fleet save, a docking handoff, an undock — so a dish you left extended
-- is extended when the craft is rebuilt.
--
-- ACTION GROUPS bind part actions to keys: the standard groups (Gear, Lights,
-- Brakes, Abort, SAS, RCS, Deploy) and ten custom ones on 1–0. Staging is a
-- separate, sequenced thing — nothing is locked to it: every decoupler, engine
-- and chute ALSO has actions you can bind or fire on their own.
--
-- POWER is simulated per vessel every tick from the part list (`powerStep`):
-- supplies (solar by sun angle, occlusion and distance from the star; engine
-- alternators; RTGs), stores (batteries) and loads (probe cores, pods, reaction
-- wheels, antennas, lights, and later wheels and actuators) with a priority
-- order for what browns out first.
--
-- COMMS is the KSP link budget: two antennas of power P1 and P2 reach
-- sqrt(P1·P2) metres; strength falls off smoothly to zero at that range; a
-- link through a planet or moon is no link; a relay (a craft carrying a
-- relay-capable antenna) passes the signal on; the home ground station is the
-- root (`solveNetwork`). A probe core with no path home cannot be commanded.
--
-- ── ACTUATORS (floptle/0420) ────────────────────────────────────────────────
-- Hinges, pistons, rotors, powered wheels, the landing claw, the drill and
-- fairings are modules like any other: a part declares one (builder REG
-- `mods`), the groups editor offers its actions, and the flight drives it
-- (vessel_controller's robotics, rover and claw passes).

-- ── module types ────────────────────────────────────────────────────────────
--
--   label     what the editor calls the module
--   toggles   { state, on, off, default, [launch] }  a switch; `on`/`off` are verbs
--   triggers  { id, label }                         a one-shot
--   axes      { id, label, min, max, rate, unit }   a setpoint (actuators)
--   readouts  names the HUD/console can show for this module
--   pri       brownout priority of its load: higher keeps power longer
MODULES = {
  command = {
    label = "Command",
    toggles = { { state = "hibernate", on = "Hibernate", off = "Wake", toggle = "Hibernate / wake", default = false } },
    readouts = { "control", "signal" },
    pri = 9,
  },
  wheel = {
    label = "Reaction wheel",
    toggles = { { state = "wheel", on = "Wheel on", off = "Wheel off", toggle = "Wheel on / off", default = true } },
    readouts = { "torque" },
    pri = 6,
  },
  battery = {
    label = "Battery",
    toggles = { { state = "flow", on = "Battery on", off = "Battery off", toggle = "Battery on / off", default = true } },
    readouts = { "charge" },
  },
  solar = {
    label = "Solar panel",
    readouts = { "output", "sun" },
  },
  rtg = {
    label = "Generator",
    readouts = { "output" },
  },
  antenna = {
    label = "Antenna",
    readouts = { "signal", "range" },
    pri = 7,
  },
  deploy = {
    label = "Deploy",
    toggles = { { state = "deployed", on = "Extend", off = "Retract", toggle = "Extend / retract", default = false } },
  },
  light = {
    label = "Light",
    toggles = { { state = "lit", on = "Light on", off = "Light off", toggle = "Light on / off", default = false } },
    pri = 2,
  },
  engine = {
    label = "Engine",
    toggles = { { state = "running", on = "Activate", off = "Shut down", toggle = "Activate / shut down", default = true } },
    readouts = { "thrust" },
  },
  decoupler = {
    label = "Decoupler",
    triggers = { { id = "decouple", label = "Decouple" } },
  },
  chute = {
    label = "Parachute",
    triggers = { { id = "chute", label = "Deploy chute" }, { id = "cutChute", label = "Cut chute" } },
  },
  rcs = {
    label = "RCS block",
    toggles = { { state = "rcs", on = "Thrusters on", off = "Thrusters off", toggle = "Thrusters on / off", default = true } },
  },
  dock = {
    label = "Docking port",
    triggers = { { id = "undock", label = "Undock" } },
  },
  -- ── ACTUATORS AND ROVERS (floptle/0420) ────────────────────────────────────
  -- An axis is a SETPOINT: `.inc` / `.dec` move it at `rate` a second while
  -- the group's key is held (a tap moves it one tick's worth … use a held
  -- key), `.center` puts it back to `center`. The flight drives the joint to
  -- the setpoint at the part's own speed and holds it there.
  hinge = {
    label = "Hinge",
    toggles = { { state = "locked", on = "Lock", off = "Unlock", toggle = "Lock / unlock", default = false } },
    axes = { { id = "angle", label = "Angle", min = -90, max = 90, rate = 30, unit = "°" },
             { id = "speed", label = "Speed", min = 10, max = 100, rate = 50, unit = "%", default = 100, center = 100 } },
    readouts = { "angle" },
    pri = 4,
  },
  piston = {
    label = "Piston",
    toggles = { { state = "extended", on = "Extend", off = "Retract", toggle = "Extend / retract", default = false },
                { state = "locked", on = "Lock", off = "Unlock", toggle = "Lock / unlock", default = false } },
    axes = { { id = "extension", label = "Extension", min = 0, max = 0.8, rate = 0.3, unit = "m" },
             { id = "speed", label = "Speed", min = 10, max = 100, rate = 50, unit = "%", default = 100, center = 100 } },
    readouts = { "extension" },
    pri = 4,
  },
  rotor = {
    label = "Rotor",
    toggles = { { state = "spin", on = "Motor on", off = "Motor off", toggle = "Motor on / off", default = false },
                { state = "locked", on = "Lock", off = "Unlock", toggle = "Lock / unlock", default = false } },
    axes = { { id = "rpm", label = "Speed", min = -60, max = 60, rate = 30, unit = "rpm", default = 20, center = 0 } },
    readouts = { "rpm" },
    pri = 4,
  },
  drill = {
    label = "Drill",
    toggles = { { state = "drilling", on = "Start drilling", off = "Stop drilling", toggle = "Drill on / off", default = false },
                { state = "deployed", on = "Lower drill", off = "Raise drill", toggle = "Lower / raise", default = false } },
    readouts = { "rate", "heat" },
    pri = 3,
  },
  drive = {
    label = "Wheel motor",
    toggles = { { state = "motor", on = "Motor on", off = "Motor off", toggle = "Motor on / off", default = true },
                { state = "brakes", on = "Brakes on", off = "Brakes off", toggle = "Brakes on / off", default = false } },
    readouts = { "speed" },
    pri = 5,
  },
  claw = {
    label = "Landing claw",
    toggles = { { state = "armed", on = "Arm claw", off = "Disarm claw", toggle = "Arm / disarm claw", default = false } },
    triggers = { { id = "release", label = "Release grip" } },
    readouts = { "grip" },
    pri = 4,
  },
  fairing = {
    label = "Fairing",
    triggers = { { id = "jettison", label = "Jettison fairing" } },
  },
}

-- What the Abort / SAS / RCS / Gear… keys are, and what they hold by default.
-- `key` is the flight key; `auto` lists which part actions land in the group
-- when a craft has never had its groups edited. Custom groups 1–0 follow.
STANDARD_GROUPS = {
  { id = "gear",   label = "Gear",   key = "g",         auto = { "deployed.toggle@legs" } },
  { id = "deploy", label = "Deploy", key = "u",         auto = { "deployed.toggle@solar", "deployed.toggle@antenna" } },
  { id = "lights", label = "Lights", key = "y",         auto = { "lit.toggle" } },
  { id = "brakes", label = "Brakes", key = "b",         auto = { "brakes.toggle" } },
  { id = "rcs",    label = "RCS",    key = "r",         auto = {} },
  { id = "sas",    label = "SAS",    key = "t",         auto = {} },
  { id = "abort",  label = "Abort",  key = "backspace", auto = {} },
}
CUSTOM_KEYS = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" }

-- ── link budget ─────────────────────────────────────────────────────────────
-- Antenna POWER is a distance in metres: two antennas reach sqrt(P1·P2). The
-- ground station's power is DSN-scale, so a weak craft antenna still reaches it
-- from much further than it reaches another craft.
COMMS = {
  station = 4.0e5,      -- the home ground station (base Tracking Station)
  occlude = 0.97,       -- bodies block a link inside this fraction of their radius
  refresh = 0.25,       -- seconds between network solves
}

-- ── small helpers ───────────────────────────────────────────────────────────

local function copy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = copy(v) end
  return o
end
deepCopy = copy

-- ── the save format ─────────────────────────────────────────────────────────
--
-- A part's modules (`mods`) and live state (`st`) and a craft's action groups
-- go into the save as plain tables: `save.set` keeps tables 16 deep (0.117,
-- floptle/0422), and a fleet record is six at a module's fields.
--
-- Saves written before that hold them as short strings — `save.set` was the
-- networking value format then, four tables deep — and are still read:
--
--   mods   "antenna:power=2250,rate=4,draw=0.12,omni=t;deploy:anim=whip"
--   st     "deployed=t,charge=37.25"
--   group  "gear|Gear|10@deployed.toggle;11@deployed.toggle"

local function dec_val(s)
  if s == "t" then return true end
  if s == "f" then return false end
  local n = tonumber(s)
  if n then return n end
  return s
end

-- A part's modules for the save: a copy, not shared with the live record.
-- (`encode` from when it made a string; an old string passes through.)
function encodeMods(mods)
  if type(mods) ~= "table" then return mods end
  return copy(mods)
end

-- Modules from the save: a table as it is, an old save's string parsed.
local mods_cache = {}
function decodeMods(str)
  if type(str) ~= "string" then return str end
  local c = mods_cache[str]
  if c then return c end
  local out = {}
  for part in str:gmatch("[^;]+") do
    local ty, rest = part:match("^([^:]+):?(.*)$")
    if ty then
      local m = { type = ty }
      for k, v in rest:gmatch("([^,=]+)=([^,]*)") do m[k] = dec_val(v) end
      out[#out + 1] = m
    end
  end
  mods_cache[str] = out
  return out
end

-- A part's state for the save: its switches and numbers (a battery's charge,
-- a panel's fold), copied.
function encodeState(st)
  if type(st) ~= "table" then return st end
  local out = {}
  for k, v in pairs(st) do
    if type(v) == "boolean" or type(v) == "number" then out[k] = v end
  end
  return out
end

function decodeState(str)
  if type(str) ~= "string" then return str end
  local st = {}
  for k, v in str:gmatch("([^,=]+)=([^,]*)") do st[k] = dec_val(v) end
  return st
end

-- A copy of a part record fit for `save.set`, sharing nothing with the live one.
function packRecord(rec)
  local out = {}
  for k, v in pairs(rec) do
    if k == "mods" then out.mods = encodeMods(v)
    elseif k == "st" then out.st = encodeState(v)
    elseif type(v) ~= "table" then out[k] = v end
  end
  return out
end

-- ── modules of a part ───────────────────────────────────────────────────────

-- The modules a blueprint record carries. A record written before modules
-- existed (an old save, a fleet craft from last week) has only the capability
-- flags; those are read into modules at today's figures, so an old battery is
-- a battery and an old dish is a dish.
function modsOf(rec)
  if type(rec) ~= "table" then return {} end
  if type(rec.mods) == "table" then return rec.mods end
  if type(rec.mods) == "string" and rec.mods ~= "" then return decodeMods(rec.mods) end
  return deriveMods(rec)
end

-- Modules implied by a part's flags. The builder calls this too, so the parts
-- that are only structural or propulsive (engines, decouplers, legs) never have
-- to spell out the obvious; it adds to whatever `mods` the part declared.
function deriveMods(def, declared)
  local out = {}
  local have = {}
  for _, m in ipairs(declared or {}) do
    out[#out + 1] = copy(m)
    have[m.type] = true
  end
  local function add(m) if not have[m.type] then have[m.type] = true; out[#out + 1] = m end end
  local function flag(k) return def[k] == true or def[k] == 1 end
  if def.kind == "crewed" then
    add({ type = "command", crew = 1, draw = 0.05 })
    add({ type = "wheel", torque = 1.0, draw = 0.5 })
    add({ type = "battery", ec = 40 })
  end
  if def.kind == "probe" then
    add({ type = "command", crew = 0, draw = 0.06 })
    add({ type = "wheel", torque = 0.6, draw = 0.35 })
    add({ type = "battery", ec = 50 })
    add({ type = "antenna", power = 100, rate = 1, draw = 0.02 })
  end
  if (def.thrust or 0) > 0 then add({ type = "engine", alt = 0.8 }) end
  if flag("decouple") then add({ type = "decoupler" }) end
  if flag("chute") then add({ type = "chute" }) end
  if flag("legs") then add({ type = "deploy", anim = "legs", default = true }) end
  if flag("rcs") then add({ type = "rcs" }) end
  if flag("dock") then add({ type = "dock" }) end
  if flag("power") then add({ type = "battery", ec = 150 }) end
  if flag("solar") then
    add({ type = "solar", gen = 1.0 })
    add({ type = "deploy", anim = "solar" })
  end
  if flag("comms") then
    add({ type = "antenna", power = 2.25e5, relay = true, dish = true, rate = 12, draw = 0.6 })
    add({ type = "deploy", anim = "dish" })
  end
  return out
end

-- The first module of a type on a part, or nil.
function modOf(rec, ty)
  for _, m in ipairs(modsOf(rec)) do if m.type == ty then return m end end
  return nil
end

-- A part's live state, created with every module's defaults the first time
-- it's asked for. `launch` is the state a fresh rollout starts in.
function stateOf(rec)
  if type(rec) ~= "table" then return {} end
  local st = rec.st
  if type(st) == "string" then st = decodeState(st); rec.st = st end
  if type(st) ~= "table" then st = {}; rec.st = st end
  for _, m in ipairs(modsOf(rec)) do
    local ty = MODULES[m.type]
    if ty then
      for _, t in ipairs(ty.toggles or {}) do
        if st[t.state] == nil then
          local d = t.default
          if m.default ~= nil and t.state == "deployed" then d = m.default end
          st[t.state] = d
        end
      end
      for _, a in ipairs(ty.axes or {}) do
        if st[a.id] == nil then st[a.id] = a.default or 0 end
      end
    end
    if m.type == "battery" and st.charge == nil then st.charge = m.ec or 0 end
  end
  return st
end

-- ── actions ─────────────────────────────────────────────────────────────────

-- Every action a part offers, in a stable order:
--   { id, label, module, kind = "on"|"off"|"toggle"|"trigger"|"axis", state }
function actionsOf(rec)
  local out, seen = {}, {}
  for _, m in ipairs(modsOf(rec)) do
    local ty = MODULES[m.type]
    if ty then
      for _, t in ipairs(ty.toggles or {}) do
        if not seen[t.state] then
          seen[t.state] = true
          out[#out + 1] = { id = t.state .. ".on", label = t.on, module = m.type, kind = "on", state = t.state }
          out[#out + 1] = { id = t.state .. ".off", label = t.off, module = m.type, kind = "off", state = t.state }
          out[#out + 1] = { id = t.state .. ".toggle", label = t.toggle or (t.on .. " / " .. t.off:lower()), module = m.type,
                            kind = "toggle", state = t.state }
        end
      end
      for _, tr in ipairs(ty.triggers or {}) do
        if not seen[tr.id] then
          seen[tr.id] = true
          out[#out + 1] = { id = tr.id, label = tr.label, module = m.type, kind = "trigger" }
        end
      end
      for _, a in ipairs(ty.axes or {}) do
        if not seen[a.id] then
          seen[a.id] = true
          local lim = { min = a.min, max = a.max, rate = a.rate, center = a.center or 0 }
          out[#out + 1] = { id = a.id .. ".inc", label = a.label .. " +", module = m.type, kind = "axis", axis = a.id, dir = 1,
                            min = lim.min, max = lim.max, rate = lim.rate, center = lim.center }
          out[#out + 1] = { id = a.id .. ".dec", label = a.label .. " −", module = m.type, kind = "axis", axis = a.id, dir = -1,
                            min = lim.min, max = lim.max, rate = lim.rate, center = lim.center }
          out[#out + 1] = { id = a.id .. ".center", label = a.label .. " centre", module = m.type, kind = "axis", axis = a.id, dir = 0,
                            min = lim.min, max = lim.max, rate = lim.rate, center = lim.center }
        end
      end
    end
  end
  return out
end

function actionOf(rec, id)
  for _, a in ipairs(actionsOf(rec)) do if a.id == id then return a end end
  return nil
end

-- Apply a toggle-or-axis action to a state table. Returns the new value and
-- whether it changed. Triggers return (nil, true): the caller does them.
--   `force` overrides a toggle's target (a group toggled as one sets every
--   member to the GROUP's new state rather than flipping each on its own).
function applyAction(st, act, force, dt)
  if not act then return nil, false end
  if act.kind == "trigger" then return nil, true end
  if act.kind == "axis" then
    local v = st[act.axis] or 0
    local nv = v
    -- `dt` is how far to move it: a held key passes the axis's rate × the
    -- tick (actionsOf carries `rate`); a bare call moves it one unit.
    if act.dir == 0 then nv = act.center or 0
    else nv = v + act.dir * (dt or 1) end
    if act.min then nv = math.max(act.min, nv) end
    if act.max then nv = math.min(act.max, nv) end
    st[act.axis] = nv
    return nv, nv ~= v
  end
  local cur = st[act.state] == true
  local want
  if force ~= nil then want = force
  elseif act.kind == "on" then want = true
  elseif act.kind == "off" then want = false
  else want = not cur end
  st[act.state] = want
  return want, want ~= cur
end

-- ── action groups ───────────────────────────────────────────────────────────
--
-- groups = { [gid] = { name = "...", binds = { { uid = 12, act = "deployed.toggle" }, … },
--                      on = bool } }
-- gid is a STANDARD_GROUPS id ("gear", "abort", …) or a custom key "1".."0".

function groupList()
  local out = {}
  for _, g in ipairs(STANDARD_GROUPS) do
    out[#out + 1] = { id = g.id, label = g.label, key = g.key, standard = true }
  end
  for i, k in ipairs(CUSTOM_KEYS) do
    out[#out + 1] = { id = k, label = "Group " .. (i == 10 and "10" or tostring(i)), key = k }
  end
  return out
end

function groupInfo(gid)
  for _, g in ipairs(groupList()) do if g.id == gid then return g end end
  return nil
end

-- The key that fires a group (nil for an unknown id).
function groupKey(gid)
  local g = groupInfo(gid)
  return g and g.key or nil
end

local function group(groups, gid, make)
  local g = groups[gid]
  if not g and make then
    local info = groupInfo(gid)
    g = { name = info and info.label or tostring(gid), binds = {} }
    groups[gid] = g
  end
  return g
end

function isBound(groups, gid, uid, act)
  local g = groups and groups[gid]
  if not g then return false end
  for _, b in ipairs(g.binds) do if b.uid == uid and b.act == act then return true end end
  return false
end

function bind(groups, gid, uid, act)
  if isBound(groups, gid, uid, act) then return false end
  local g = group(groups, gid, true)
  g.binds[#g.binds + 1] = { uid = uid, act = act }
  return true
end

function unbind(groups, gid, uid, act)
  local g = groups and groups[gid]
  if not g then return false end
  for i, b in ipairs(g.binds) do
    if b.uid == uid and b.act == act then table.remove(g.binds, i); return true end
  end
  return false
end

-- Bind if unbound, unbind if bound. Returns the new bound state.
function toggleBind(groups, gid, uid, act)
  if isBound(groups, gid, uid, act) then unbind(groups, gid, uid, act) return false end
  bind(groups, gid, uid, act)
  return true
end

-- Which groups a part's action is in, as a list of gids (stable order).
function groupsOf(groups, uid, act)
  local out = {}
  for _, g in ipairs(groupList()) do
    if isBound(groups, g.id, uid, act) then out[#out + 1] = g.id end
  end
  return out
end

-- Everything bound to anything on this part: { { gid, act } }.
function bindsOfPart(groups, uid)
  local out = {}
  for _, g in ipairs(groupList()) do
    local gg = groups and groups[g.id]
    if gg then
      for _, b in ipairs(gg.binds) do
        if b.uid == uid then out[#out + 1] = { gid = g.id, act = b.act } end
      end
    end
  end
  return out
end

-- Drop bindings to parts that are not in `alive` (uid → truthy). A staged or
-- broken-off part leaves its groups with it.
function pruneGroups(groups, alive)
  for _, g in pairs(groups or {}) do
    local keep = {}
    for _, b in ipairs(g.binds or {}) do
      if alive[b.uid] then keep[#keep + 1] = b end
    end
    g.binds = keep
  end
  return groups
end

-- Renumber bindings (`map` old uid → new uid), dropping any not in the map.
-- Docking renumbers the module's parts as it folds them into the host.
function remapGroups(groups, map)
  local out = {}
  for gid, g in pairs(groups or {}) do
    local ng = { name = g.name, on = g.on, binds = {} }
    for _, b in ipairs(g.binds or {}) do
      local u = map[b.uid]
      if u then ng.binds[#ng.binds + 1] = { uid = u, act = b.act } end
    end
    out[gid] = ng
  end
  return out
end

-- Fold `src` into `dst` (both group tables): a docked module brings its groups,
-- and pressing 1 then fires both craft's group 1.
function mergeGroups(dst, src)
  for gid, g in pairs(src or {}) do
    for _, b in ipairs(g.binds or {}) do bind(dst, gid, b.uid, b.act) end
    local dg = dst[gid]
    if dg and g.name and (not dg.name or dg.name == (groupInfo(gid) or {}).label) then dg.name = g.name end
  end
  return dst
end

-- Only the groups touching parts in `uids` (a set), for a craft splitting off.
function subsetGroups(groups, uids)
  local out = copy(groups or {})
  return pruneGroups(out, uids)
end

-- Does an `auto` pattern ("deployed.toggle@solar" — action id @ deploy anim or
-- module type) match this part?
local function auto_match(pat, rec)
  local act, tag = pat:match("^([^@]+)@?(.*)$")
  if not actionOf(rec, act) then return nil end
  if tag == "" then return act end
  for _, m in ipairs(modsOf(rec)) do
    if m.type == tag or (m.type == "deploy" and m.anim == tag)
      or (m.type == "deploy" and tag == "antenna" and (m.anim == "dish" or m.anim == "whip")) then
      return act
    end
  end
  return nil
end

-- The groups a craft flies with when nobody has edited them: landing legs on
-- Gear, panels and antennas on Deploy, lights on Lights, brakes on Brakes.
-- The custom 1–0 start empty — they are yours.
function defaultGroups(parts)
  local groups = {}
  local list = {}
  for _, d in pairs(parts or {}) do list[#list + 1] = d end
  table.sort(list, function(a, b) return (a.uid or 0) < (b.uid or 0) end)
  for _, g in ipairs(STANDARD_GROUPS) do
    for _, d in ipairs(list) do
      for _, pat in ipairs(g.auto) do
        local act = auto_match(pat, d)
        if act then bind(groups, g.id, d.uid, act) end
      end
    end
  end
  return groups
end

-- A group's ON/OFF state for display and for toggling it as one: its own flag
-- once fired, otherwise what most of its toggles currently read.
function groupState(groups, gid, recs)
  local g = groups and groups[gid]
  if not g then return false end
  if g.on ~= nil then return g.on end
  local on, n = 0, 0
  for _, b in ipairs(g.binds) do
    local rec = recs and recs[b.uid]
    local act = rec and actionOf(rec, b.act)
    if act and act.state then
      n = n + 1
      if stateOf(rec)[act.state] then on = on + 1 end
    end
  end
  return n > 0 and on * 2 >= n
end

-- Fire a group: `recs` uid → record (the live craft's), `run(uid, act, force)`
-- does one action. Toggles move as ONE: the group flips its own state and every
-- toggle in it is set to that, so a gear ring can never end up half down.
-- Returns how many actions ran.
function fireGroup(groups, gid, recs, run)
  local g = groups and groups[gid]
  if not g then return 0 end
  local now = not groupState(groups, gid, recs)
  g.on = now
  local n = 0
  for _, b in ipairs(g.binds) do
    local rec = recs and recs[b.uid]
    local act = rec and actionOf(rec, b.act)
    if act then
      local force = nil
      if act.kind == "toggle" then force = now end
      if run(b.uid, act, force) ~= false then n = n + 1 end
    end
  end
  return n
end

-- Group table → a list for the save, one { id, name, binds } per group that
-- holds something (or was renamed), in id order.
function packGroups(groups)
  local out = {}
  for gid, g in pairs(groups or {}) do
    if #(g.binds or {}) > 0 or (g.name and g.name ~= (groupInfo(gid) or {}).label) then
      local binds = {}
      for i, b in ipairs(g.binds or {}) do binds[i] = { uid = b.uid, act = b.act } end
      out[#out + 1] = { id = tostring(gid), name = g.name, binds = binds }
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

-- The save's list → group table. Reads this list, an old save's strings
-- ("gear|Gear|10@deployed.toggle"), or a table already keyed by group id.
function unpackGroups(list)
  local out = {}
  if type(list) ~= "table" then return out end
  -- already a table keyed by gid?
  for k, v in pairs(list) do
    if type(k) == "string" and type(v) == "table" and v.binds then
      local g = { name = v.name, binds = {} }
      for _, b in ipairs(v.binds) do g.binds[#g.binds + 1] = { uid = b.uid, act = b.act } end
      out[k] = g
    end
  end
  for _, e in ipairs(list) do
    if type(e) == "string" then
      local gid, name, rest = e:match("^([^|]*)|([^|]*)|(.*)$")
      if gid and gid ~= "" then
        local g = { name = (name ~= "" and name) or ((groupInfo(gid) or {}).label or gid), binds = {} }
        for u, a in rest:gmatch("([^;@]+)@([^;]+)") do
          g.binds[#g.binds + 1] = { uid = tonumber(u) or u, act = a }
        end
        out[gid] = g
      end
    elseif type(e) == "table" and e.id then
      local g = { name = e.name or ((groupInfo(tostring(e.id)) or {}).label or tostring(e.id)), binds = {} }
      for _, b in ipairs(e.binds or {}) do
        if b.uid and b.act then g.binds[#g.binds + 1] = { uid = b.uid, act = b.act } end
      end
      out[tostring(e.id)] = g
    end
  end
  return out
end

-- ── power ───────────────────────────────────────────────────────────────────
--
-- powerStep(sys, dt) → report
--   sys.supply   EC/s produced this tick (solar, alternators, RTGs)
--   sys.loads    { { id, rate (EC/s), pri } }  what wants power
--   sys.cells    { { cap, charge, on } }  batteries; charge is updated in place
--
-- The report: charge / cap (enabled batteries), net (EC/s into storage),
-- served[id] = 0..1 for every load, brownout = some load went short.
-- Batteries fill and drain in proportion to their capacity; a battery switched
-- off keeps what it has and takes no part. Short of power, loads are served in
-- priority order (highest first) — so the probe core keeps thinking after the
-- lights and the radio have gone dark.
function powerStep(sys, dt)
  local supply = math.max(0, sys.supply or 0)
  local demand = 0
  for _, l in ipairs(sys.loads or {}) do demand = demand + math.max(0, l.rate or 0) end
  local cap, charge = 0, 0
  for _, c in ipairs(sys.cells or {}) do
    if c.on ~= false then cap = cap + (c.cap or 0); charge = charge + (c.charge or 0) end
  end
  local rep = { supply = supply, demand = demand, served = {}, brownout = false }
  local net = supply - demand
  local avail -- EC/s the loads can have this tick
  if net >= 0 then
    avail = demand
    local room = cap - charge
    local put = math.min(room, net * dt)
    if put > 0 and cap > 0 then
      for _, c in ipairs(sys.cells or {}) do
        if c.on ~= false and (c.cap or 0) > 0 then
          c.charge = math.min(c.cap, (c.charge or 0) + put * c.cap / cap)
        end
      end
    end
    rep.net = (cap > 0) and math.min(net, room / math.max(dt, 1e-9)) or 0
  else
    local need = -net * dt
    local take = math.min(need, charge)
    if take > 0 and charge > 0 then
      for _, c in ipairs(sys.cells or {}) do
        if c.on ~= false and (c.charge or 0) > 0 then
          c.charge = math.max(0, c.charge - take * c.charge / charge)
        end
      end
    end
    avail = supply + take / math.max(dt, 1e-9)
    rep.net = -take / math.max(dt, 1e-9)
  end
  -- Serve the loads, highest priority first, ties in list order.
  local order = {}
  for i, l in ipairs(sys.loads or {}) do order[i] = { l = l, i = i } end
  table.sort(order, function(a, b)
    local pa, pb = a.l.pri or 5, b.l.pri or 5
    if pa ~= pb then return pa > pb end
    return a.i < b.i
  end)
  local left = avail + 1e-9
  for _, o in ipairs(order) do
    local r = math.max(0, o.l.rate or 0)
    local f = 1
    if r > 0 then
      f = math.max(0, math.min(1, left / r))
      left = math.max(0, left - r)
    end
    if f < 0.999 then rep.brownout = true end
    rep.served[o.l.id] = f
  end
  local c2 = 0
  for _, c in ipairs(sys.cells or {}) do if c.on ~= false then c2 = c2 + (c.charge or 0) end end
  rep.charge, rep.cap = c2, cap
  return rep
end

-- How long the batteries last at a steady draw (seconds; math.huge if they don't drain).
function endurance(charge, net)
  if net >= 0 then return math.huge end
  return charge / -net
end

-- ── sunlight ────────────────────────────────────────────────────────────────

-- Is the straight line from A to B blocked by any body? Bodies whose sphere
-- holds an endpoint (the world a station stands on, a landed craft's planet)
-- still block it — shrunk to `occlude` of their radius, so a line from the
-- surface toward the sky clears its own ground and a line through it doesn't.
-- Returns the blocking body's name, or nil.
function segmentBlocked(ax, ay, az, bx, by, bz, bodies, shrink, skip)
  shrink = shrink or COMMS.occlude
  local dx, dy, dz = bx - ax, by - ay, bz - az
  local L2 = dx * dx + dy * dy + dz * dz
  for _, b in ipairs(bodies or {}) do
    if b.name ~= skip and (b.radius or 0) > 0 then
      local r = b.radius * shrink
      -- An endpoint ON the body's ground (a rover, the ground station) can sit
      -- below `shrink` of its nominal radius — a base in a basin, a craft at
      -- the bottom of a valley — and was then "blocked" by its own planet
      -- talking to a station 20 m away. The occluder never reaches above
      -- either end (less 2 m), so a link between two points on the same
      -- ground is blocked only when the ground between them rises: the
      -- horizon, not the datum.
      local da = math.sqrt((ax - b.x) ^ 2 + (ay - b.y) ^ 2 + (az - b.z) ^ 2)
      local db = math.sqrt((bx - b.x) ^ 2 + (by - b.y) ^ 2 + (bz - b.z) ^ 2)
      r = math.min(r, da - 2.0, db - 2.0)
      local t = 0
      if L2 > 1e-12 then
        t = ((b.x - ax) * dx + (b.y - ay) * dy + (b.z - az) * dz) / L2
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
      end
      local cx, cy, cz = ax + dx * t - b.x, ay + dy * t - b.y, az + dz * t - b.z
      if cx * cx + cy * cy + cz * cz < r * r then return b.name end
    end
  end
  return nil
end

-- The star lighting a point: the body with the most µ/d² (stars are by far the
-- heaviest bodies, so this is the nearest sun). Returns the body and its flux
-- relative to `ref` (µ/d² at the reference distance; 1 = home-orbit sunlight).
function sunOf(x, y, z, bodies, ref)
  -- Stars are the heavy ones: a sun outweighs its planets by orders of
  -- magnitude, so anything within 5 % of the heaviest µ is a star (the home
  -- star and its neighbours alike), and the nearest of those in µ/d² lights us.
  local maxmu = 0
  for _, b in ipairs(bodies or {}) do
    if (b.mu or 0) > maxmu then maxmu = b.mu end
  end
  local best, bf = nil, -1
  for _, b in ipairs(bodies or {}) do
    if (b.mu or 0) >= maxmu * 0.05 or b.star == true then
      local d2 = (b.x - x) ^ 2 + (b.y - y) ^ 2 + (b.z - z) ^ 2
      local f = (b.mu or 0) / math.max(d2, 1)
      if f > bf then best, bf = b, f end
    end
  end
  if not best then return nil, 0 end
  local k = (ref and ref > 0) and bf / ref or 1
  return best, k
end

-- Output of one panel: `gen` EC/s at reference sunlight, scaled by
--   exposure  how squarely the panel faces the sun. Panels TRACK about their
--             own long axis (the mount's outward axis, `ax`), so only the angle
--             between that axis and the sun costs anything: sqrt(1 − (a·s)²);
--   flux      the inverse square of the distance to the star, relative to the
--             home world's orbit (capped at 4× in close);
--   shadow    0 when a planet or moon stands between the panel and the star.
-- Returns output, exposure, flux, blocker.
function solarOutput(gen, x, y, z, ax, ay, az, bodies, ref)
  local sun, flux = sunOf(x, y, z, bodies, ref)
  if not sun then return 0, 0, 0, nil end
  local sx, sy, sz = sun.x - x, sun.y - y, sun.z - z
  local sl = math.sqrt(sx * sx + sy * sy + sz * sz)
  if sl < 1e-6 then return 0, 0, 0, nil end
  sx, sy, sz = sx / sl, sy / sl, sz / sl
  local c = (ax or 0) * sx + (ay or 0) * sy + (az or 0) * sz
  local exposure = math.sqrt(math.max(0, 1 - c * c))
  local blocker = segmentBlocked(x, y, z, sun.x, sun.y, sun.z, bodies, 1.0, sun.name)
  flux = math.min(4.0, flux)
  local out = blocker and 0 or gen * exposure * flux
  return out, exposure, flux, blocker
end

-- ── comms ───────────────────────────────────────────────────────────────────

function linkRange(p1, p2)
  if (p1 or 0) <= 0 or (p2 or 0) <= 0 then return 0 end
  return math.sqrt(p1 * p2)
end

-- 1 at zero range, smoothly 0 at the edge (the KSP curve).
function linkStrength(d, range)
  if range <= 0 then return 0 end
  local x = 1 - d / range
  if x <= 0 then return 0 end
  if x > 1 then x = 1 end
  return x * x * (3 - 2 * x)
end

-- What a craft's antennas add up to, from its part records and their states:
--   any     its best usable antenna power (what it reaches home with)
--   relay   its best usable RELAY antenna power (0 = not a relay)
--   rate    data rate of its best antenna (bandwidth placeholder for science)
--   draw    EC/s the active antennas want
--   n       how many antennas are usable now
-- An antenna is usable when its radio is on, it is powered (`powered` ~= false),
-- and — for one that folds — extended. `gone` (uid → true) skips lost parts.
-- Several antennas COMBINE the KSP way: the strongest plus a share of the rest.
function antennaSummary(recs, gone, powered)
  local best, sum, bestR, sumR, rate, draw, n = 0, 0, 0, 0, 0, 0, 0
  for _, d in pairs(recs or {}) do
    if not (gone and gone[d.uid]) then
      local st = stateOf(d)
      for _, m in ipairs(modsOf(d)) do
        if m.type == "antenna" then
          local folds = false
          for _, m2 in ipairs(modsOf(d)) do if m2.type == "deploy" then folds = true end end
          local up = st.radio ~= false and (not folds or st.deployed == true) and powered ~= false
          if up then
            local p = m.power or 0
            n = n + 1
            sum = sum + p
            if p > best then best = p; rate = m.rate or 1 end
            if m.relay then
              sumR = sumR + p
              if p > bestR then bestR = p end
            end
            draw = draw + (m.draw or 0)
          end
        end
      end
    end
  end
  -- combination: strongest × (Σ/strongest)^0.75
  local any = best > 0 and best * (sum / best) ^ 0.75 or 0
  local relay = bestR > 0 and bestR * (sumR / bestR) ^ 0.75 or 0
  return { any = any, relay = relay, rate = rate, draw = draw, n = n }
end

-- THE NETWORK. `nodes` = { { id, x,y,z, any, relay, home = bool, rate } };
-- `bodies` = space.bodies(). Returns:
--   status[id] = { connected, strength (0..1, the path's product), hops,
--                  parent (the next node toward home), path = { ids… }, bandwidth }
--   links      = { { a, b, strength, used = bool } } every usable edge
-- A link from a craft toward home uses the craft's best antenna (`any`) and the
-- far end's RELAY power (or the station's, for home). Best path = the one with
-- the highest product of hop strengths (Dijkstra on −log s).
function solveNetwork(nodes, bodies)
  local n = #nodes
  local status, links = {}, {}
  local cost, parent, done = {}, {}, {}
  local edge = {} -- cache: i..":"..j -> strength (i child, j parent side)
  local function seg_ok(a, b)
    return segmentBlocked(a.x, a.y, a.z, b.x, b.y, b.z, bodies, COMMS.occlude) == nil
  end
  local blocked = {}
  local function pair_blocked(i, j)
    local k = i < j and (i .. ":" .. j) or (j .. ":" .. i)
    local v = blocked[k]
    if v == nil then v = not seg_ok(nodes[i], nodes[j]); blocked[k] = v end
    return v
  end
  -- strength of child i linking through j
  local function strength(i, j)
    local k = i .. ">" .. j
    local s = edge[k]
    if s then return s end
    local a, b = nodes[i], nodes[j]
    local up = b.home and (b.power or COMMS.station) or (b.relay or 0)
    s = 0
    if not a.home and (a.any or 0) > 0 and up > 0 then
      local range = linkRange(a.any, up)
      local d = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
      if d < range and not pair_blocked(i, j) then s = linkStrength(d, range) end
    end
    edge[k] = s
    return s
  end
  for i = 1, n do
    if nodes[i].home then cost[i] = 0 end
  end
  for _ = 1, n do
    local u, best = nil, math.huge
    for i = 1, n do
      if not done[i] and cost[i] and cost[i] < best then u, best = i, cost[i] end
    end
    if not u then break end
    done[u] = true
    local nu = nodes[u]
    if nu.home or (nu.relay or 0) > 0 then
      for v = 1, n do
        if not done[v] and v ~= u and not nodes[v].home then
          local s = strength(v, u)
          if s > 1e-4 then
            local c = best - math.log(s)
            if not cost[v] or c < cost[v] - 1e-12 then cost[v] = c; parent[v] = u end
          end
        end
      end
    end
  end
  for i = 1, n do
    local nd = nodes[i]
    local st = { connected = nd.home or cost[i] ~= nil, strength = 0, hops = 0, path = {} }
    if nd.home then
      st.strength = 1
    elseif cost[i] then
      st.strength = math.exp(-cost[i])
      local p, guard = i, 0
      while p and not nodes[p].home and guard < n + 1 do
        st.path[#st.path + 1] = nodes[p].id
        p = parent[p]
        guard = guard + 1
      end
      if p then st.path[#st.path + 1] = nodes[p].id end
      st.hops = #st.path - 1
      st.parent = parent[i] and nodes[parent[i]].id or nil
      st.bandwidth = (nd.rate or 1) * st.strength
    end
    if not st.connected then st.why = noLinkWhy(nd, nodes, bodies) end
    status[nd.id] = st
  end
  -- every usable edge, each pair once, flagged when it is on someone's best path
  for i = 1, n do
    for j = i + 1, n do
      local s = math.max(strength(i, j), strength(j, i))
      if s > 1e-4 then
        local used = parent[i] == j or parent[j] == i
        links[#links + 1] = { a = nodes[i].id, b = nodes[j].id, strength = s, used = used }
      end
    end
  end
  return status, links
end

-- Why a transmitter has no path home, in the player's words: its radio is
-- silent, the ground station is out of its reach ("out of range: 31 km >
-- 6 km"), or a world stands in the way ("blocked by Vever").
local function fmt_km(m)
  if m >= 1e6 then return string.format("%.0f Mm", m / 1e6) end
  if m >= 1e4 then return string.format("%.0f km", m / 1000) end
  if m >= 1000 then return string.format("%.1f km", m / 1000) end
  return string.format("%.0f m", m)
end
function noLinkWhy(nd, nodes, bodies)
  if (nd.any or 0) <= 0 then return nd.silent or "radio silent — no powered antenna" end
  local home
  for _, h in ipairs(nodes) do if h.home then home = h end end
  if not home then return "no ground station" end
  local range = linkRange(nd.any, home.power or COMMS.station)
  local d = math.sqrt((nd.x - home.x) ^ 2 + (nd.y - home.y) ^ 2 + (nd.z - home.z) ^ 2)
  local blk = segmentBlocked(nd.x, nd.y, nd.z, home.x, home.y, home.z, bodies, COMMS.occlude)
  if d > range then
    return string.format("out of range: %s > %s", fmt_km(d), fmt_km(range))
  end
  if blk then return "blocked by " .. blk end
  return "no path home"
end

-- Signal bars (0–4) from a path strength.
function bars(strength)
  if not strength or strength <= 0 then return 0 end
  if strength > 0.75 then return 4 end
  if strength > 0.45 then return 3 end
  if strength > 0.2 then return 2 end
  return 1
end

-- Colour for a link line of this strength: red → amber → green.
function strengthColor(s)
  s = math.max(0, math.min(1, s or 0))
  if s < 0.5 then
    local k = s / 0.5
    return 1.0, 0.30 + 0.45 * k, 0.25
  end
  local k = (s - 0.5) / 0.5
  return 1.0 - 0.7 * k, 0.75 + 0.2 * k, 0.25 + 0.25 * k
end

-- ── the craft as a whole ────────────────────────────────────────────────────

-- What a set of part records amounts to electrically, at rest — the numbers
-- the builder quotes and the Tracking Station shows for a craft it can't see
-- live. `sun` is the solar flux factor to assume (1 = home-orbit daylight).
--   store      battery capacity (EC)
--   solar      panel output at that sun, panels square on (EC/s)
--   idle       what the craft draws doing nothing (cores, pods, active radios)
--   peak       idle + reaction wheels flat out + lights
--   crew, probe  command parts aboard
--   antenna    antennaSummary with every antenna extended
--   relay      can relay
function summary(recs, sun)
  sun = sun or 1
  local s = { store = 0, solar = 0, alt = 0, idle = 0, peak = 0, crew = 0, probe = 0, rtg = 0 }
  local ext = {}
  for _, d in pairs(recs or {}) do
    local c = deepCopy(d)
    c.st = c.st or {}
    c.st.deployed = true
    c.st.radio = true
    ext[#ext + 1] = c
    for _, m in ipairs(modsOf(d)) do
      if m.type == "battery" then s.store = s.store + (m.ec or 0)
      elseif m.type == "solar" then s.solar = s.solar + (m.gen or 0) * sun
      elseif m.type == "rtg" then s.rtg = s.rtg + (m.gen or 0)
      elseif m.type == "engine" then s.alt = s.alt + (m.alt or 0)
      elseif m.type == "command" then
        s.idle = s.idle + (m.draw or 0)
        if (m.crew or 0) > 0 then s.crew = s.crew + 1 else s.probe = s.probe + 1 end
      elseif m.type == "wheel" then s.peak = s.peak + (m.draw or 0)
      elseif m.type == "light" then s.peak = s.peak + (m.draw or 0)
      elseif m.type == "drive" or m.type == "hinge" or m.type == "piston" or m.type == "rotor"
        or m.type == "drill" or m.type == "claw" then
        -- motors draw only while they work: peak, not idle
        s.peak = s.peak + (m.draw or 0)
        s.motors = (s.motors or 0) + (m.draw or 0)
      elseif m.type == "antenna" then s.idle = s.idle + (m.draw or 0)
      end
    end
  end
  s.peak = s.peak + s.idle
  s.antenna = antennaSummary(ext, nil, true)
  s.relay = s.antenna.relay > 0
  s.reachHome = linkRange(s.antenna.any, COMMS.station)
  s.reachCraft = s.antenna.any
  return s
end

-- ── fairing shells (shared geometry) ────────────────────────────────────────
--
-- A fairing's shell is BUILT TO FIT its payload (builder.fairingEnvelope
-- measures it; the record carries r, hc, hn, y0): a cylinder of radius `r`
-- from the base ring's top (y0) up to `hc`, then an ogive nose `hn` tall, in
-- the base part's own frame. `half` 0 or 1 picks which half (the two split
-- apart on jettison). Returned as mesh.build's lists, outer skin and inner
-- lining both, UVs in metres of skin. The builder and the flight both build
-- from this, so the shell you fly is the one you saw.
function fairingShell(r, y0, hc, hn, half, segs)
  segs = segs or 24
  local prof = { { r, y0 }, { r, hc } }
  local nb = 8
  for k = 1, nb do
    local t = k / nb
    -- tangent ogive: radius falls as the arc, apex at hc + hn
    local yy = hc + hn * t
    local rr = r * math.sqrt(math.max(0, 1 - t * t)) * (1 - 0.15 * t)
    if k == nb then rr = 0.0 end
    prof[#prof + 1] = { rr, yy }
  end
  local L = { 0 }
  for k = 2, #prof do
    L[k] = L[k - 1] + math.sqrt((prof[k][1] - prof[k - 1][1]) ^ 2 + (prof[k][2] - prof[k - 1][2]) ^ 2)
  end
  local P, N, UV, I = {}, {}, {}, {}
  local a0 = (half or 0) * math.pi
  local function vert(x, y, z, nx, ny, nz, u, v)
    P[#P + 1] = x; P[#P + 1] = y; P[#P + 1] = z
    N[#N + 1] = nx; N[#N + 1] = ny; N[#N + 1] = nz
    UV[#UV + 1] = u; UV[#UV + 1] = v
    return #P / 3
  end
  for side = 1, 2 do                           -- 1 outer skin, 2 inner lining
    local sg = side == 1 and 1 or -1
    local base = #P / 3
    for i = 0, segs do
      local a = a0 + math.pi * i / segs
      local c, s = math.cos(a), math.sin(a)
      for k = 1, #prof do
        local kk = math.max(1, math.min(#prof - 1, k))
        local dr = prof[kk + 1][1] - prof[kk][1]
        local dy = prof[kk + 1][2] - prof[kk][2]
        local l = math.sqrt(dr * dr + dy * dy)
        local nr, ny = dy / l, -dr / l
        local rr = math.max(0, prof[k][1] - (side == 2 and 0.01 or 0))
        vert(rr * c, prof[k][2], rr * s, nr * c * sg, ny * sg, nr * s * sg, (a - a0) * r, -L[k])
      end
    end
    local np = #prof
    for i = 0, segs - 1 do
      for k = 1, np - 1 do
        local a = base + i * np + k
        local b = base + (i + 1) * np + k
        if side == 1 then
          I[#I + 1] = a; I[#I + 1] = a + 1; I[#I + 1] = b + 1
          I[#I + 1] = a; I[#I + 1] = b + 1; I[#I + 1] = b
        else
          I[#I + 1] = a; I[#I + 1] = b + 1; I[#I + 1] = a + 1
          I[#I + 1] = a; I[#I + 1] = b; I[#I + 1] = b + 1
        end
      end
    end
  end
  -- the two cut edges, so a half is closed where it splits
  return { positions = P, normals = N, uvs = UV, indices = I }
end
