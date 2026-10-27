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
  -- `presets` on an axis adds "go to" actions: `.max` / `.min` send the
  -- setpoint straight to that end stop on a press (a hinge to +90°, a piston
  -- all the way out), the way `.center` sends it home.
  hinge = {
    label = "Hinge",
    toggles = { { state = "locked", on = "Lock", off = "Unlock", toggle = "Lock / unlock", default = false } },
    axes = { { id = "angle", label = "Angle", min = -90, max = 90, rate = 30, unit = "°", presets = true },
             { id = "speed", label = "Speed", min = 10, max = 100, rate = 50, unit = "%", default = 100, center = 100 } },
    readouts = { "angle" },
    pri = 4,
  },
  piston = {
    label = "Piston",
    toggles = { { state = "extended", on = "Extend", off = "Retract", toggle = "Extend / retract", default = false },
                { state = "locked", on = "Lock", off = "Unlock", toggle = "Lock / unlock", default = false } },
    axes = { { id = "extension", label = "Extension", min = 0, max = 0.8, rate = 0.3, unit = "m", presets = true },
             { id = "speed", label = "Speed", min = 10, max = 100, rate = 50, unit = "%", default = 100, center = 100 } },
    readouts = { "extension" },
    pri = 4,
  },
  rotor = {
    label = "Rotor",
    toggles = { { state = "spin", on = "Motor on", off = "Motor off", toggle = "Motor on / off", default = false },
                { state = "locked", on = "Lock", off = "Unlock", toggle = "Lock / unlock", default = false } },
    axes = { { id = "rpm", label = "Speed", min = -60, max = 60, rate = 30, unit = "rpm", default = 20, center = 0, presets = true } },
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
  -- GRAZING: how far (as a fraction of the world's radius, held between the
  -- two limits in metres) a link may dip below the LOWER of its two ends'
  -- own ground before the world counts as in the way. Radio bends a little
  -- round a horizon and the ground is not a polished sphere: a link that only
  -- skims the surface is a link. On Vever (r 807) that is 8 m: a rover
  -- talks to the base dish from ~0.25 km of ground away, an orbiter a few
  -- degrees under the geometric horizon, and a ray through the planet's
  -- body is still blocked.
  graze = 0.01, grazeMin = 3.0, grazeMax = 40.0,
  refresh = 0.25,       -- seconds between network solves
  -- THE RELAY BEACON: the cheap ground relay the crew carries and plants
  -- (scripts/comms.lua keeps them, tool_belt places them). Its one antenna
  -- both relays and reaches with `power`. Sized to the home world (r ~800 m):
  -- the horizon (occlude + graze, above, with the grazing measured from the
  -- GROUND under the mast — segmentBlocked's `ha`/`hb`) stops one beacon
  -- seeing another past ~430 m of ground at the datum and ~270 m in a basin
  -- 30 m deep; at 1500 two beacons 400 m apart still link at ~80 %, and a
  -- probe core's own antenna (100) hears one from sqrt(100·1500) ≈ 390 m
  -- (over gentle ground the horizon, 250-415 m, comes first). The 4 m mast
  -- is worth ~20 m of reach over a 2 m one. It runs ALWAYS ON: a long-life cell and a solar
  -- trickle are the story, but these worlds don't turn, so a beacon on the
  -- night side would never charge — an outage nobody could fix. `mast` is
  -- how far above the ground its antenna stands (the model is `height` tall).
  -- (Its price and weight in the pack are inventory.GEAR.beacon.)
  beacon = { power = 1500, rate = 2, mast = 4.0, height = 4.2 },
  -- COVERAGE (comms.coverage): a body's surface is sampled on a fixed grid
  -- of `coverSamples` points, each a reference receiver `coverLift` m above
  -- the ground with a probe core's antenna (`coverRx`): a point is covered
  -- when that receiver could link straight to a relay with a path home (or
  -- to the ground station).
  coverSamples = 200, coverRx = 100, coverLift = 1.0,
  -- SUSTAINED COVERAGE (the sky goals; comms keeps the history, the rules
  -- are below under "sustained coverage"). A ground sample is HELD when it
  -- had a link home for at least `hold` of the window. The window is the
  -- longest orbital period among the connected relay satellites round the
  -- world, never under `minWindow` and never over `maxWindow` game seconds
  -- (the clamp: a relay parked far out — a period of hours — would otherwise
  -- ask the player to watch the map for hours; half an hour of game time is
  -- about two minutes at ×10 warp). Snapshots are taken on a game-time grid
  -- at least `perWindow` to a window and `perPeriod` to the FASTEST relay's
  -- orbit, but never more than `maxPerWindow` (cost) or closer than `minStep`
  -- seconds; `retain` windows of history are kept, so a window that grows
  -- back (a satellite lost, then replaced) finds its history still there.
  sustain = { hold = 0.75, minWindow = 300, maxWindow = 1800, perWindow = 48, perPeriod = 24,
              maxPerWindow = 240, minStep = 1.0, retain = 2.0 },
}

-- The grazing allowance for a world of radius r (see COMMS.graze).
function grazeOf(r)
  return math.max(COMMS.grazeMin, math.min(COMMS.grazeMax, (r or 0) * COMMS.graze))
end

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
-- A part with no `mods` of its own has them derived from its flags — asked
-- for dozens of times per part when a craft rolls out (every device test,
-- every action group pattern), and each derivation built its tables afresh:
-- ~20 ms of a 1,000-part rollout frame. So the derived list is kept per
-- record, and rebuilt only when one of the flags it reads has changed. Like a
-- decoded `mods` string's (decodeMods), the list is shared: read it, never
-- write into it.
DERIVE_KEYS = { "kind", "seat", "thrust", "decouple", "chute", "legs", "rcs", "dock", "power", "solar", "comms" }
derived_cache = setmetatable({}, { __mode = "k" })
PASS_MODS = nil   -- inside one pass over a craft (defaultGroups): rec → its modules
function modsOf(rec)
  if type(rec) ~= "table" then return {} end
  local pm = PASS_MODS
  if pm then
    local v = pm[rec]
    if v then return v end
    PASS_MODS = nil
    v = modsOf(rec)
    PASS_MODS = pm
    pm[rec] = v
    return v
  end
  if type(rec.mods) == "table" then return rec.mods end
  if type(rec.mods) == "string" and rec.mods ~= "" then return decodeMods(rec.mods) end
  local keys = DERIVE_KEYS
  local c = derived_cache[rec]
  local now = time
  -- (looked at once a frame: a record's flags are not rewritten mid-frame)
  if c and now ~= nil and c.t == now then return c.out end
  if c then
    local v, same = c.v, true
    for i = 1, #keys do
      if v[i] ~= rec[keys[i]] then same = false break end
    end
    if same then c.t = now; return c.out end
  end
  local out = deriveMods(rec)
  local v = {}
  for i = 1, #keys do v[i] = rec[keys[i]] end
  derived_cache[rec] = { v = v, out = out, t = now }
  return out
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
  if def.kind == "crewed" and flag("seat") then
    -- An OPEN SEAT commands like a pod (the crew in it is the pilot) but has
    -- no reaction wheel and no battery of its own: it's a chair with a stick.
    add({ type = "command", crew = 1, draw = 0.0, seat = true })
  elseif def.kind == "crewed" then
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
          if a.presets then
            -- "go to" a stop: dir 0 with the stop as its target, so the flight
            -- (which sends a dir-0 axis to `center` on the press) needs nothing new.
            local u = a.unit or ""
            if u ~= "°" and u ~= "%" and u ~= "" then u = " " .. u end
            local function fmt(v)
              local m = math.abs(v)
              return (v > 0 and "+" or (v < 0 and "−" or "")) .. string.format(m == math.floor(m) and "%d" or "%.1f", m) .. u
            end
            out[#out + 1] = { id = a.id .. ".max", label = a.label .. " → " .. fmt(a.max), module = m.type, kind = "axis", axis = a.id,
                              dir = 0, preset = "max", min = lim.min, max = lim.max, rate = lim.rate, center = a.max }
            out[#out + 1] = { id = a.id .. ".min", label = a.label .. " → " .. fmt(a.min), module = m.type, kind = "axis", axis = a.id,
                              dir = 0, preset = "min", min = lim.min, max = lim.max, rate = lim.rate, center = a.min }
          end
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

-- The groups a craft flies with when nobody has edited them: landing legs on
-- Gear, panels and antennas on Deploy, lights on Lights, brakes on Brakes.
-- The custom 1–0 start empty — they are yours.
function defaultGroups(parts)
  -- (one pass: nothing about a part's modules changes inside it, so each
  -- part's are looked up once)
  local outer = PASS_MODS
  PASS_MODS = outer or {}
  local ok, res = pcall(default_groups, parts)
  PASS_MODS = outer
  if not ok then error(res, 0) end
  return res
end
function default_groups(parts)
  local groups = {}
  local list = {}
  for _, d in pairs(parts or {}) do list[#list + 1] = d end
  table.sort(list, function(a, b) return (a.uid or 0) < (b.uid or 0) end)
  -- (a pattern "act@tag" matches a part that offers `act` and has a module
  -- of type `tag`, a deploy of that anim, or — tag antenna — a dish or whip.
  -- Each part's actions are listed once rather than once per
  -- pattern: at 1,000 parts that was 5,000 action lists built and thrown
  -- away on the rollout frame. The same matches, bound in the same order.)
  local ids = {}
  for i, d in ipairs(list) do
    local have = {}
    for _, a in ipairs(actionsOf(d)) do have[a.id] = true end
    ids[i] = have
  end
  local pats = {}
  for _, g in ipairs(STANDARD_GROUPS) do
    for _, pat in ipairs(g.auto) do
      if not pats[pat] then
        local act, tag = pat:match("^([^@]+)@?(.*)$")
        pats[pat] = { act = act, tag = tag }
      end
    end
  end
  for _, g in ipairs(STANDARD_GROUPS) do
    for i, d in ipairs(list) do
      for _, pat in ipairs(g.auto) do
        local pp = pats[pat]
        local act = nil
        if pp.act and ids[i][pp.act] then
          if pp.tag == "" then act = pp.act
          else
            local tag = pp.tag
            for _, m in ipairs(modsOf(d)) do
              if m.type == tag or (m.type == "deploy" and m.anim == tag)
                or (m.type == "deploy" and tag == "antenna" and (m.anim == "dish" or m.anim == "whip")) then
                act = pp.act
                break
              end
            end
          end
        end
        if act then bind(groups, g.id, d.uid, act) end
      end
    end
  end
  actuatorGroups(groups, list)
  return groups
end

-- ACTUATORS GET KEYS OF THEIR OWN. A piston, hinge, rotor, drill or claw on a
-- craft nobody has set up used to have no key at all — "my action groups didn't
-- show me the electronics to control". The standard set now hands them the
-- custom groups 1–0 in build order, one per actuator (a symmetry ring is one
-- actuator), named for what the key does:
--
--   piston   one key  Extend / retract
--   hinge    two keys Hinge + and Hinge −, HELD to swing it (continuous)
--   rotor    one key  Motor on / off
--   drill    one key  Lower and run / raise and stop
--   claw     one key  Arm / disarm
--
-- Anything left over when the ten keys run out simply isn't bound; the editor
-- binds it by hand. `ACTUATOR_KEYS` is that plan, as data.
ACTUATOR_KEYS = {
  { module = "piston", keys = { { name = "Piston", acts = { "extended.toggle" } } } },
  { module = "hinge",  keys = { { name = "Hinge +", acts = { "angle.inc" } }, { name = "Hinge −", acts = { "angle.dec" } } } },
  { module = "rotor",  keys = { { name = "Rotor", acts = { "spin.toggle" } } } },
  { module = "drill",  keys = { { name = "Drill", acts = { "deployed.toggle", "drilling.toggle" } } } },
  { module = "claw",   keys = { { name = "Claw", acts = { "armed.toggle" } } } },
}

-- Is this record an actuator the player drives (rather than a switch)?
function actuatorOf(rec)
  for _, a in ipairs(ACTUATOR_KEYS) do
    if modOf(rec, a.module) then return a end
  end
  return nil
end

-- Bind every actuator in `list` (records in build order) to the next free
-- custom groups. Returns how many keys it used.
function actuatorGroups(groups, list)
  local free = {}
  for _, k in ipairs(CUSTOM_KEYS) do
    local g = groups[k]
    if not g or #(g.binds or {}) == 0 then free[#free + 1] = k end
  end
  local used, rings, n = {}, {}, 0
  for _, d in ipairs(list) do
    local a = actuatorOf(d)
    local ring = d.sym and d.sym ~= 0 and ("s" .. tostring(d.sym)) or nil
    if a then
      local slot = ring and rings[ring]
      if not slot then
        if n + #a.keys > #free then break end
        slot = {}
        for i, key in ipairs(a.keys) do
          n = n + 1
          slot[i] = free[n]
          local g = group(groups, free[n], true)
          g.name = key.name
        end
        if ring then rings[ring] = slot end
      end
      for i, key in ipairs(a.keys) do
        for _, act in ipairs(key.acts) do
          if actionOf(d, act) then bind(groups, slot[i], d.uid, act) end
        end
      end
      used[#used + 1] = d.uid
    end
  end
  return n
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
-- `graze` (true, or metres) lets the line dip that far under the lower end's
-- own ground before it counts — COMMS grazing (grazeOf the body's radius) for
-- `true`, 2 m when absent (sunlight: a shadow is a shadow).
-- `ha`, `hb` (metres, optional): how far each end's antenna stands above its
-- own ground — a relay beacon's mast. The grazing is measured from the GROUND
-- under that end, so a mast lifts the antenna over the horizon by its height;
-- an end without one (a craft, the station) is its own ground, as before.
-- Returns the blocking body's name, or nil.
function segmentBlocked(ax, ay, az, bx, by, bz, bodies, shrink, skip, graze, ha, hb)
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
      -- either end (less the grazing allowance), so a link between two points
      -- on the same ground is blocked only when the line between them runs
      -- meaningfully UNDER that ground: past the horizon, not the datum.
      local g = graze == true and grazeOf(b.radius) or tonumber(graze) or 2.0
      local da = math.sqrt((ax - b.x) ^ 2 + (ay - b.y) ^ 2 + (az - b.z) ^ 2)
      local db = math.sqrt((bx - b.x) ^ 2 + (by - b.y) ^ 2 + (bz - b.z) ^ 2)
      r = math.min(r, da - (ha or 0) - g, db - (hb or 0) - g)
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

-- How squarely a panel's CELLS face the sun: max(0, cos(incidence)), the
-- incidence measured between the sun and the cells' normal IN THE WORLD.
--   `ax..az`    the panel's long axis in world space — the mount's outward axis
--               (the part's +X after the part's own rotation AND the craft's).
--   `deployed`  0..1, how far the wing is open (nil = open).
-- OPEN, the wing TRACKS about its long axis (it turns its cells to the sun
-- the way a real array's drive does), so the best normal it can reach is
-- the sun direction with its along-axis part removed: cos(incidence) =
-- sqrt(1 − (a·s)²) — full when the sun is square to the axis, nothing when
-- the axis points straight at the sun or straight away from it.
-- STOWED, the wing lies flat along the hull with its cells OUT (the prefab's
-- folded pose): a fixed plate whose normal is the mount's outward axis, so
-- cos(incidence) = max(0, a·s) — lit from outside, dark from behind.
-- Part-way, a blend of the two.
function panelExposure(ax, ay, az, sx, sy, sz, deployed)
  local f = deployed
  if f == nil then f = 1 end
  if f < 0 then f = 0 elseif f > 1 then f = 1 end
  local c = (ax or 0) * sx + (ay or 0) * sy + (az or 0) * sz
  local open = math.sqrt(math.max(0, 1 - c * c))
  local stowed = math.max(0, c)
  return f * open + (1 - f) * stowed
end

-- Output of one panel: `gen` EC/s at reference sunlight, scaled by
--   exposure  how squarely the cells face the sun (panelExposure, above);
--   flux      the inverse square of the distance to the star, relative to the
--             home world's orbit (capped at 4× in close);
--   shadow    0 when a planet or moon stands between the panel and the star
--             (its full radius, less 2 m of grazing from the panel's own ground).
-- Every position must be from the SAME instant: these worlds move hundreds of
-- metres a second on their rails, and a panel set against where its planet
-- was half a second ago sits tens of metres off its own ground (a shadow at
-- noon, sunshine after dark — see powerTick's notes).
-- Returns output, exposure, flux, blocker.
function solarOutput(gen, x, y, z, ax, ay, az, bodies, ref, deployed)
  local sun, flux = sunOf(x, y, z, bodies, ref)
  if not sun then return 0, 0, 0, nil end
  local sx, sy, sz = sun.x - x, sun.y - y, sun.z - z
  local sl = math.sqrt(sx * sx + sy * sy + sz * sz)
  if sl < 1e-6 or sl ~= sl then return 0, 0, 0, nil end
  sx, sy, sz = sx / sl, sy / sl, sz / sl
  local exposure = panelExposure(ax, ay, az, sx, sy, sz, deployed)
  local blocker = segmentBlocked(x, y, z, sun.x, sun.y, sun.z, bodies, 1.0, sun.name)
  flux = math.min(4.0, flux)
  local out = blocker and 0 or (gen or 0) * exposure * flux
  return out, exposure, flux, blocker
end

-- ── sunlight over a time step (warp) ────────────────────────────────────────
--
-- The electrical tick runs ten times a REAL second; under time warp each one
-- spans warp/10 seconds of the world's time. Two things follow:
--
--   1. The step is GAME time (space.time()'s advance), not the frame's dt —
--      at 100× a battery must fill 100× as fast per real second. gameStep.
--   2. Over a long step the light changes: a non-rotating world's "day" is its
--      year round its star (Vever's is under half an hour), so at 1000× a
--      tick is a fifth of a day; an orbiting probe can circle its world
--      several times inside one. Sampling the sun once per tick would hand the
--      whole step to whatever the light was at its start. solarOverStep
--      integrates the output over the step instead: the craft's and its
--      world's motion on their two-body conics (exact, drift-free), the light
--      sampled at enough points to resolve both (midpoint rule, ≤ 64).

-- Seconds of game time an electrical tick covers. `t0`, `t1`: space.time() at
-- the last tick and now; `realDt`, `warp`: the fallback when the clock jumped
-- (a scene load restarts it) or isn't there. Never negative.
function gameStep(t0, t1, realDt, warp)
  realDt = math.max(0, realDt or 0)
  warp = math.max(1, warp or 1)
  local guess = realDt * warp
  if type(t0) == "number" and type(t1) == "number" then
    local d = t1 - t0
    -- the clock is believed unless it ran backwards or ran away from what
    -- the frame and the warp could possibly account for (a scene load)
    if d >= 0 and d <= guess * 4 + 1.0 then return d end
  end
  return guess
end

-- Two-body propagation: the state (x,y,z, vx,vy,vz) relative to a point mass
-- `mu`, `dt` seconds on. Universal variables (elliptic, parabolic and
-- hyperbolic alike); a non-finite input or no mass coasts in a straight line.
-- (space.propagate does this in the engine; this copy keeps the rulebook
-- pure and testable.)
local function stumpff(z)
  if z > 1e-6 then
    local s = math.sqrt(z)
    return (1 - math.cos(s)) / z, (s - math.sin(s)) / (s * s * s)
  elseif z < -1e-6 then
    local s = math.sqrt(-z)
    return (math.cosh(s) - 1) / -z, (math.sinh(s) - s) / (s * s * s)
  end
  return 0.5 - z / 24, 1 / 6 - z / 120
end
function kepler(x, y, z, vx, vy, vz, mu, dt)
  local r0 = math.sqrt(x * x + y * y + z * z)
  if not mu or mu <= 0 or r0 < 1e-9 or r0 ~= r0 or dt == 0 then
    return x + vx * dt, y + vy * dt, z + vz * dt, vx, vy, vz
  end
  local v2 = vx * vx + vy * vy + vz * vz
  local vr0 = (x * vx + y * vy + z * vz) / r0
  local alpha = 2 / r0 - v2 / mu
  local sq = math.sqrt(mu)
  local chi = sq * math.abs(alpha) * dt
  if alpha <= 1e-12 or chi ~= chi then chi = sq * dt / r0 end
  for _ = 1, 60 do
    local zz = alpha * chi * chi
    local C, S = stumpff(zz)
    local F = r0 * vr0 / sq * chi * chi * C + (1 - alpha * r0) * chi ^ 3 * S + r0 * chi - sq * dt
    local dF = r0 * vr0 / sq * chi * (1 - zz * S) + (1 - alpha * r0) * chi * chi * C + r0
    if dF == 0 or dF ~= dF then break end
    local step = F / dF
    chi = chi - step
    if math.abs(step) < 1e-9 * math.max(1, math.abs(chi)) then break end
  end
  local zz = alpha * chi * chi
  local C, S = stumpff(zz)
  local f = 1 - chi * chi / r0 * C
  local g = dt - chi ^ 3 / sq * S
  local nx, ny, nz = f * x + g * vx, f * y + g * vy, f * z + g * vz
  local r = math.sqrt(nx * nx + ny * ny + nz * nz)
  if r < 1e-9 or r ~= r then return x + vx * dt, y + vy * dt, z + vz * dt, vx, vy, vz end
  local fd = sq / (r * r0) * (zz * S - 1) * chi
  local gd = 1 - chi * chi / r * C
  return nx, ny, nz, fd * x + gd * vx, fd * y + gd * vy, fd * z + gd * vz
end

-- The body a point is bound to: the smallest sphere of influence holding it
-- (soi < 0 = the star's, infinite). nil in empty space with no star.
function boundBody(x, y, z, bodies)
  local best, bs = nil, math.huge
  for _, b in ipairs(bodies or {}) do
    local soi = (b.soi or -1) < 0 and math.huge or b.soi
    local d = math.sqrt((x - b.x) ^ 2 + (y - b.y) ^ 2 + (z - b.z) ^ 2)
    if d <= soi and (soi < bs or (soi == bs and not best)) then best, bs = b, soi end
  end
  return best
end

-- The mean output of a set of panels over a step of `dt` game seconds that
-- STARTS now. `panels` = { { gen, ax, ay, az, deployed, ox, oy, oz } }: each
-- panel's axis in the world and its offset from the craft point (both held
-- fixed through the step — a craft on the rails keeps its attitude, and a
-- landed one turns with a world that doesn't turn). `S` describes the craft:
--   x,y,z, vx,vy,vz   where it is and how it moves now (world space)
--   landed            true: it rides its world (its offset from the world's
--                     centre is fixed); false: it coasts on its own conic
--   bodies            space.bodies() read THIS tick (positions from the same
--                     instant as x,y,z); `ref` the home-orbit flux
-- Returns the mean EC/s, the share of the step in sunlight (0..1) and the
-- number of samples it took. A step under ~2 s is one sample at its middle
-- (normal play): nothing moves far enough in it to matter.
function solarOverStep(panels, S, dt, ref)
  local bodies = S.bodies or {}
  if #panels == 0 then return 0, 0, 0 end
  local x0, y0, z0 = S.x, S.y, S.z
  local function at_once(bl, x, y, z)
    local sum, lit = 0, false
    for _, p in ipairs(panels) do
      local o = solarOutput(p.gen or p[1] or 0, x + (p.ox or 0), y + (p.oy or 0), z + (p.oz or 0),
        p.ax, p.ay, p.az, bl, ref, p.deployed)
      sum = sum + o
      if o > 0 then lit = true end
    end
    return sum, lit
  end
  dt = math.max(0, dt or 0)
  local home = boundBody(x0, y0, z0, bodies)
  local sun = sunOf(x0, y0, z0, bodies, nil)
  if dt <= 2.0 or not home or not sun or home == sun then
    local s, lit = at_once(bodies, x0, y0, z0)
    return s, lit and 1 or 0, 1
  end
  -- How fast the light can change: the world round its star, and the craft
  -- round its world (a landed craft rides its world). One sample per 1/96 of
  -- a turn of the faster of the two, at least one, at most 64.
  local function rate(rx, ry, rz, wx, wy, wz)
    local r2 = rx * rx + ry * ry + rz * rz
    if r2 < 1e-9 then return 0 end
    -- |r × v| / r²
    local cx, cy, cz = ry * wz - rz * wy, rz * wx - rx * wz, rx * wy - ry * wx
    return math.sqrt(cx * cx + cy * cy + cz * cz) / r2
  end
  local hx, hy, hz = home.x - sun.x, home.y - sun.y, home.z - sun.z
  local hvx, hvy, hvz = (home.vx or 0) - (sun.vx or 0), (home.vy or 0) - (sun.vy or 0), (home.vz or 0) - (sun.vz or 0)
  local cx, cy, cz = x0 - home.x, y0 - home.y, z0 - home.z
  local cvx, cvy, cvz = (S.vx or 0) - (home.vx or 0), (S.vy or 0) - (home.vy or 0), (S.vz or 0) - (home.vz or 0)
  local w = rate(hx, hy, hz, hvx, hvy, hvz)
  if not S.landed then w = math.max(w, rate(cx, cy, cz, cvx, cvy, cvz)) end
  local n = math.max(1, math.min(64, math.ceil(dt * w / (2 * math.pi / 96))))
  local sum, litn = 0, 0
  -- each sample: the bodies as they are now, the world (and anything bound to
  -- it — its moons) moved to where its conic has it, the craft with it
  local kids = {}
  for i, b in ipairs(bodies) do
    if b ~= sun and (b == home or boundBody(b.x, b.y, b.z, bodies) == home) then kids[i] = true end
  end
  for k = 1, n do
    local t = (k - 0.5) / n * dt
    local px, py, pz = kepler(hx, hy, hz, hvx, hvy, hvz, sun.mu or 0, t)
    local sxt, syt, szt = sun.x + (sun.vx or 0) * t, sun.y + (sun.vy or 0) * t, sun.z + (sun.vz or 0) * t
    local dx, dy, dz = sxt + px - home.x, syt + py - home.y, szt + pz - home.z
    local bl = {}
    for i, b in ipairs(bodies) do
      if kids[i] then
        bl[i] = { name = b.name, x = b.x + dx, y = b.y + dy, z = b.z + dz, radius = b.radius, mu = b.mu, soi = b.soi, star = b.star }
      elseif b == sun then
        bl[i] = { name = b.name, x = sxt, y = syt, z = szt, radius = b.radius, mu = b.mu, soi = b.soi, star = b.star }
      else
        bl[i] = b
      end
    end
    local qx, qy, qz = cx, cy, cz
    if not S.landed then qx, qy, qz = kepler(cx, cy, cz, cvx, cvy, cvz, home.mu or 0, t) end
    local s, lit = at_once(bl, home.x + dx + qx, home.y + dy + qy, home.z + dz + qz)
    sum = sum + s
    if lit then litn = litn + 1 end
  end
  return sum / n, litn / n, n
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
    return segmentBlocked(a.x, a.y, a.z, b.x, b.y, b.z, bodies, COMMS.occlude, nil, true, a.agl, b.agl) == nil
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
  local blk = segmentBlocked(nd.x, nd.y, nd.z, home.x, home.y, home.z, bodies, COMMS.occlude, nil, true, nd.agl, home.agl)
  if d > range then
    return string.format("out of range: %s > %s", fmt_km(d), fmt_km(range))
  end
  if blk then
    -- On the station's own world, say how far round it the craft is: "blocked
    -- by Vever" alone reads like a fault when it is the horizon.
    for _, b in ipairs(bodies or {}) do
      if b.name == blk and (b.radius or 0) > 0 then
        local hx, hy, hz = home.x - b.x, home.y - b.y, home.z - b.z
        local cx, cy, cz = nd.x - b.x, nd.y - b.y, nd.z - b.z
        local hl = math.sqrt(hx * hx + hy * hy + hz * hz)
        local cl = math.sqrt(cx * cx + cy * cy + cz * cz)
        if hl < b.radius * 1.2 and hl > 0 and cl > 0 then
          local c = math.max(-1, math.min(1, (hx * cx + hy * cy + hz * cz) / (hl * cl)))
          return string.format("blocked by %s — the ground station is below the horizon (%s round the world)",
            blk, fmt_km(math.acos(c) * b.radius))
        end
      end
    end
    return "blocked by " .. blk
  end
  return "no path home"
end

-- ── ground relays and coverage ──────────────────────────────────────────────

-- A relay beacon as a network node (solveNetwork's shape), from where its
-- antenna stands in the world.
function beaconNode(id, name, x, y, z)
  local b = COMMS.beacon
  return { id = id, name = name, x = x, y = y, z = z, any = b.power, relay = b.power, rate = b.rate,
           beacon = true, agl = b.mast }
end

-- `n` unit vectors spread evenly over a sphere (a Fibonacci lattice): the
-- fixed grid coverage is sampled on. Deterministic, so a body's samples are
-- the same points every time and a coverage number moves only when the
-- network does.
local grid_cache = {}
function surfaceGrid(n)
  n = n or COMMS.coverSamples
  local g = grid_cache[n]
  if g then return g end
  g = {}
  local ga = math.pi * (3 - math.sqrt(5))
  for i = 0, n - 1 do
    local y = 1 - (i + 0.5) * 2 / n
    local r = math.sqrt(math.max(0, 1 - y * y))
    local a = ga * i
    g[#g + 1] = { math.cos(a) * r, y, math.sin(a) * r }
  end
  grid_cache[n] = g
  return g
end

-- Can a receiver at P (antenna power `rx`) link straight to any of `relays`
-- ({ x,y,z, power [, agl] }, each already known to have a path home)? Range by the
-- link budget, line of sight by segmentBlocked with grazing. Returns the
-- strongest such link's strength (0 = none). `rxAgl`: the receiver's own
-- mast, if it has one (a probe receiver doesn't).
function hears(px, py, pz, rx, relays, bodies, rxAgl)
  local best = 0
  for _, r in ipairs(relays) do
    local range = linkRange(rx, r.power or 0)
    local d = math.sqrt((px - r.x) ^ 2 + (py - r.y) ^ 2 + (pz - r.z) ^ 2)
    if d < range then
      local s = linkStrength(d, range)
      if s > math.max(best, 1e-4)
        and segmentBlocked(px, py, pz, r.x, r.y, r.z, bodies, COMMS.occlude, nil, true, rxAgl, r.agl) == nil then
        best = s
      end
    end
  end
  return best
end

-- The fraction (0..1) of `points` ({ {x,y,z}… } in world space) that hear one
-- of `relays`. The coverage number.
function coverageFraction(points, relays, bodies, rx)
  if #points == 0 then return 0 end
  if #relays == 0 then return 0 end
  rx = rx or COMMS.coverRx
  local n = 0
  for _, p in ipairs(points) do
    if hears(p[1], p[2], p[3], rx, relays, bodies) > 0 then n = n + 1 end
  end
  return n / #points
end

-- How far over the ground (metres of arc) a receiver of power `rx` standing
-- `lift` m up hears an antenna `mast` m up, both on a world of radius `r` at
-- its datum: the smaller of the link budget's range and the horizon. What the
-- placement ring draws. Pure; `bodyR` names the sphere the horizon is
-- measured against (defaults to r).
function groundReach(r, mast, lift, rx, power)
  local range = linkRange(rx, power)
  if range <= 0 or r <= 0 then return 0 end
  local body = { { name = "w", x = 0, y = 0, z = 0, radius = r } }
  local ra, rb = r + mast, r + lift
  local function ok(arc)
    local th = arc / r
    local bx, by = math.sin(th) * rb, math.cos(th) * rb
    local d = math.sqrt(bx * bx + (by - ra) ^ 2)
    if d >= range then return false end
    return segmentBlocked(0, ra, 0, bx, by, 0, body, COMMS.occlude, nil, true, mast, 0) == nil
  end
  local lo, hi = 0, math.min(range * 1.05, math.pi * r)
  if ok(hi) then return hi end
  for _ = 1, 30 do
    local mid = (lo + hi) * 0.5
    if ok(mid) then lo = mid else hi = mid end
  end
  return lo
end

-- ── sustained coverage (pure; comms.lua keeps one history per world) ────────
--
-- A snapshot of coverage is a lie while satellites move: a lucky instant with
-- three relays bunched over the right hemisphere reads 80 % and then 30 %
-- ten minutes later. The sky goals ask instead how much of the ground was
-- HELD: linked for at least COMMS.sustain.hold of a rolling window, the
-- window being one orbit of the highest relay satellite (see COMMS.sustain).
--
-- THE HISTORY (`tr`): snapshots { t, w, f } in time order — `t` the game
-- time it was taken (space.time()), `w` the seconds it stands for (the grid
-- step, or the share of a span it was picked to represent under heavy warp),
-- `f` the per-sample flags (1 linked, 0 not; a flags table is never written
-- after it is added, so one table may be shared by many snapshots). Each
-- sample's linked fraction is the time-weighted mean of its flags over the
-- window; nothing in the history is about WHICH relay linked it, so a
-- satellite lost or added never wipes it — it is what the ground experienced.

-- The period (s) of the orbit a craft is on round a mass mu, from its state
-- relative to that mass; nil on an escape (or no mass).
function orbitPeriod(x, y, z, vx, vy, vz, mu)
  if not mu or mu <= 0 then return nil end
  local r = math.sqrt(x * x + y * y + z * z)
  if r < 1e-6 then return nil end
  local v2 = vx * vx + vy * vy + vz * vz
  local inv_a = 2 / r - v2 / mu
  if inv_a <= 1e-15 then return nil end
  local a = 1 / inv_a
  return 2 * math.pi * math.sqrt(a * a * a / mu), a
end

-- The window and the grid step from the periods of the connected relay
-- satellites round the world (any order; empty = none up). S defaults to
-- COMMS.sustain. Returns W, h (game seconds).
function sustainWindow(periods, S)
  S = S or COMMS.sustain
  local maxP, minP = 0, math.huge
  for _, p in ipairs(periods or {}) do
    if p and p > 0 and p == p then
      if p > maxP then maxP = p end
      if p < minP then minP = p end
    end
  end
  local W = math.max(maxP, S.minWindow)
  if W > S.maxWindow then W = S.maxWindow end
  local h = W / S.perWindow
  if minP < math.huge then h = math.min(h, minP / S.perPeriod) end
  h = math.max(h, W / S.maxPerWindow, S.minStep)
  return W, h
end

-- Which instants to take now. `last` = the game time of the last snapshot
-- (nil: none yet), `now` = the game time now, `h` the step, `W` the window,
-- `budget` the most instants this call may take. Returns the list
-- { { t, w }… } (oldest first) and the new `last`.
--
-- Normally that is every grid instant since `last`, each standing for `h`.
-- Under warp the clock can run past many of them in one frame (at ×1000 a
-- 60 fps frame is 16 s of game time; at ×10000 it is minutes — whole orbits
-- of a low satellite). Instants older than a window would be forgotten at
-- once, so they are skipped; if more are due than the budget allows, the
-- budget's worth are spread EVENLY over the span due, each standing for its
-- share of it, so the fraction stays an honest time average of the orbit
-- rather than a few bunched moments.
function sustainPlan(last, now, h, W, budget)
  budget = math.max(1, math.floor(budget or 4))
  if not last then return { { t = now, w = h } }, now end
  if now - last < h then return {}, last end
  local k = math.floor((now - last) / h)
  local stop = last + k * h
  local start = last
  if stop - start > W then start = stop - W end
  local span = stop - start
  local m = math.floor(span / h + 0.5)
  local out = {}
  if m <= budget then
    for j = 1, m do out[#out + 1] = { t = stop - (m - j) * h, w = h } end
  else
    local w = span / budget
    for j = 1, budget do out[#out + 1] = { t = start + w * j, w = w } end
  end
  return out, stop
end

function sustainNew(n)
  return { n = n or COMMS.coverSamples, snaps = {} }
end

-- Add a snapshot (taken at game time t, standing for w seconds). A snapshot
-- at or before the last one's time is ignored (the history stays ordered).
function sustainAdd(tr, t, w, flags)
  local s = tr.snaps
  local last = s[#s]
  if last and t <= last.t + 1e-9 then return false end
  s[#s + 1] = { t = t, w = w, f = flags }
  tr.stats = nil
  return true
end

-- Forget snapshots that ended before game time `from`.
function sustainPrune(tr, from)
  local s = tr.snaps
  local k = 0
  while s[k + 1] and s[k + 1].t <= from do k = k + 1 end
  if k > 0 then
    local out = {}
    for i = k + 1, #s do out[#out + 1] = s[i] end
    tr.snaps = out
    tr.stats = nil
  end
end

-- Move the whole history by dt (the game clock restarted: a scene load).
function sustainShift(tr, dt)
  for _, sn in ipairs(tr.snaps) do sn.t = sn.t + dt end
  tr.stats = nil
end

-- The numbers at game time `now` over a window W:
--   sustained  0..1 the share of samples held (linked ≥ `hold` of the window)
--   held       seconds of history inside the window (W once it is full)
--   full       held reached the window: a goal may latch
--   frac[i]    each sample's linked fraction; ok[i] true when it is held
--   count      snapshots in the window
-- The history may be shorter than the window (just started): the fraction is
-- over what there is, and `full` says it is not a verdict yet.
function sustainStats(tr, now, W, hold)
  hold = hold or COMMS.sustain.hold
  local n = tr.n
  local from = now - W
  local wsum, held, count = 0, 0, 0
  local acc = {}
  for i = 1, n do acc[i] = 0 end
  for _, sn in ipairs(tr.snaps) do
    if sn.t > from and sn.t <= now + 1e-9 then
      local w = sn.w
      local inside = sn.t - from
      if w > inside then w = inside end
      if w > 0 then
        wsum = wsum + w
        count = count + 1
        local f = sn.f
        for i = 1, n do
          if (f[i] or 0) > 0 then acc[i] = acc[i] + w end
        end
      end
    end
  end
  held = math.min(W, wsum)
  local frac, ok, nok = {}, {}, 0
  for i = 1, n do
    local v = wsum > 0 and acc[i] / wsum or 0
    frac[i] = v
    ok[i] = wsum > 0 and v >= hold - 1e-9
    if ok[i] then nok = nok + 1 end
  end
  return { sustained = n > 0 and nok / n or 0, held = held, window = W, full = held >= W - 1e-6,
           frac = frac, ok = ok, count = count, hold = hold }
end

-- Does a sustained goal of `frac` latch on these stats? Only on a full window.
function sustainMeets(st, frac)
  return st ~= nil and st.full == true and (st.sustained or 0) >= frac - 1e-6
end

-- THE SAVE: one string per world, "S1|n|age,w,bits;…" — ages and weights in
-- tenths of a second before the moment it was written, the flags 6 to a
-- character. The game clock restarts every session, so times are kept as
-- ages and set back against the clock that reads them. ~40 characters a
-- snapshot; 96 snapshots (two 5-minute windows) is under 4 kB.
local SB64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function bits_enc(f, n)
  local out = {}
  for i = 1, n, 6 do
    local v = 0
    for k = 0, 5 do
      if i + k <= n and (f[i + k] or 0) > 0 then v = v + 2 ^ k end
    end
    out[#out + 1] = SB64:sub(v + 1, v + 1)
  end
  return table.concat(out)
end
local function bits_dec(s, n)
  local f = {}
  for c = 1, #s do
    local v = SB64:find(s:sub(c, c), 1, true)
    if not v then return nil end
    v = v - 1
    for k = 0, 5 do
      local i = (c - 1) * 6 + k + 1
      if i <= n then f[i] = (math.floor(v / 2 ^ k) % 2 == 1) and 1 or 0 end
    end
  end
  if #f ~= n then return nil end
  return f
end

function sustainEncode(tr, now)
  local parts = { "S1", tostring(tr.n) }
  local body = {}
  local last_f, last_s = nil, nil
  for _, sn in ipairs(tr.snaps) do
    local s
    if sn.f == last_f then s = last_s else s = bits_enc(sn.f, tr.n); last_f, last_s = sn.f, s end
    body[#body + 1] = string.format("%d,%d,%s", math.floor((now - sn.t) * 10 + 0.5), math.floor(sn.w * 10 + 0.5), s)
  end
  parts[#parts + 1] = table.concat(body, ";")
  return table.concat(parts, "|")
end

-- nil when the string isn't a history (or is for another grid size).
function sustainDecode(str, now, n)
  if type(str) ~= "string" then return nil end
  local ver, ns, body = str:match("^(S1)|(%d+)|(.*)$")
  if not ver then return nil end
  ns = tonumber(ns)
  if n and ns ~= n then return nil end
  local tr = sustainNew(ns)
  local cache = {}
  for age, w, bits in body:gmatch("(%-?%d+),(%d+),([^;]+)") do
    local f = cache[bits]
    if not f then f = bits_dec(bits, ns); cache[bits] = f end
    if not f then return nil end
    sustainAdd(tr, now - tonumber(age) / 10, tonumber(w) / 10, f)
  end
  return tr
end

-- THE GAPS: the samples not held, gathered into patches of neighbouring
-- ground (two samples are neighbours within ~1.7 grid spacings). Returns
-- { n, share, idx = { i… }, clusters = { { n, x,y,z (unit, the patch's
-- centre), lat (deg, +y up), lon (deg), idx = { its samples } }… } biggest
-- first, at most `top` }.
-- Where the next satellite should pass over is the biggest patch's centre.
local nbr_cache = {}
local function grid_neighbours(dirs)
  local n = #dirs
  local nb = nbr_cache[n]
  if nb and nb.dirs == dirs then return nb end
  nb = { dirs = dirs }
  local lim = math.cos(math.sqrt(4 * math.pi / math.max(1, n)) * 1.7)
  for i = 1, n do
    local a, l = dirs[i], {}
    for j = 1, n do
      if j ~= i then
        local b = dirs[j]
        if a[1] * b[1] + a[2] * b[2] + a[3] * b[3] >= lim then l[#l + 1] = j end
      end
    end
    nb[i] = l
  end
  nbr_cache[n] = nb
  return nb
end

function sustainGaps(dirs, ok, top)
  top = top or 3
  local n = #dirs
  local idx = {}
  for i = 1, n do if not ok[i] then idx[#idx + 1] = i end end
  local out = { n = #idx, share = n > 0 and #idx / n or 0, idx = idx, clusters = {} }
  if #idx == 0 then return out end
  local nb = grid_neighbours(dirs)
  local seen = {}
  for _, i in ipairs(idx) do
    if not seen[i] then
      local q, qi = { i }, 1
      seen[i] = true
      local sx, sy, sz, c = 0, 0, 0, 0
      while q[qi] do
        local k = q[qi]
        qi = qi + 1
        local d = dirs[k]
        sx, sy, sz, c = sx + d[1], sy + d[2], sz + d[3], c + 1
        for _, j in ipairs(nb[k]) do
          if not ok[j] and not seen[j] then seen[j] = true; q[#q + 1] = j end
        end
      end
      local l = math.sqrt(sx * sx + sy * sy + sz * sz)
      if l < 1e-6 then sx, sy, sz, l = dirs[i][1], dirs[i][2], dirs[i][3], 1 end
      sx, sy, sz = sx / l, sy / l, sz / l
      out.clusters[#out.clusters + 1] = { n = c, x = sx, y = sy, z = sz, idx = q,
        lat = math.deg(math.asin(math.max(-1, math.min(1, sy)))), lon = math.deg(math.atan2(sz, sx)) }
    end
  end
  table.sort(out.clusters, function(a, b) return a.n > b.n end)
  while #out.clusters > top do out.clusters[#out.clusters] = nil end
  return out
end

-- THE FOOTPRINT: how far round a world of radius R (central angle, radians)
-- a probe receiver (power rx, `lift` m up) hears a relay of `power` at
-- distance d from the world's centre: the smaller of the link budget's reach
-- and the horizon, with the same occlusion and grazing as `hears`. The map
-- draws it as a ring on the ground.
function footprintAngle(R, d, power, rx, lift)
  rx, lift = rx or COMMS.coverRx, lift or COMMS.coverLift
  local range = linkRange(rx, power)
  if range <= 0 or R <= 0 or d <= R then return 0 end
  local body = { { name = "w", x = 0, y = 0, z = 0, radius = R } }
  local rr = R + lift
  local function ok(th)
    local px, py = math.sin(th) * rr, math.cos(th) * rr
    local dd = math.sqrt(px * px + (py - d) ^ 2)
    if dd >= range then return false end
    return segmentBlocked(px, py, 0, 0, d, 0, body, COMMS.occlude, nil, true) == nil
  end
  if not ok(0) then return 0 end
  local lo, hi = 0, math.pi
  if ok(hi) then return hi end
  for _ = 1, 40 do
    local mid = (lo + hi) * 0.5
    if ok(mid) then lo = mid else hi = mid end
  end
  return lo
end

-- One instant's flags: 1 where a receiver on the ground under each grid
-- direction hears one of `relays` (each { x,y,z, power, agl }, already known
-- to have a path home), else 0. `radii[i]` is the ground under direction i
-- (nil: `R`). Returns the flags and how many are linked.
function coverFlags(bx, by, bz, R, grid, radii, relays, bodies, rx, lift)
  rx, lift = rx or COMMS.coverRx, lift or COMMS.coverLift
  local flags, n = {}, 0
  for i, u in ipairs(grid) do
    local r = ((radii and radii[i]) or R) + lift
    local f = 0
    if #relays > 0 and hears(bx + u[1] * r, by + u[2] * r, bz + u[3] * r, rx, relays, bodies) > 0 then
      f = 1
      n = n + 1
    end
    flags[i] = f
  end
  return flags, n
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
-- A shell is a PROFILE lathed round the base ring's axis: a list of { r, y } in
-- the base part's own frame, bottom to top (y never falls), r = 0 at a closed
-- apex. It comes from one of two places:
--
--   fitted  no shape drawn: a cylinder of radius `r` from the ring's top `y0`
--           up to `hc`, then an ogive nose `hn` tall, sized to the payload by
--           builder.fairingEnvelope. Every fairing was this before shaping, and
--           a record with only fr / fy0 / fhc / fhn still flies as it.
--   shaped  the rings the player drew in the builder (each a radius and a
--           height above the base ring), closed by `fairingNose`. The record
--           carries it flat as `fprof` = { r1, y1, r2, y2, … }.
--
-- The builder and the flight both build from these, so the shell you fly is
-- the one you saw.

FAIRING_NOSE_K = 1.1     -- an ogive nose is this many times its ring's radius tall
FAIRING_NOSE_SEGS = 8

-- The ogive from a ring of radius r at height y up to its apex, appended.
local function ogive(prof, r, y, hn)
  for k = 1, FAIRING_NOSE_SEGS do
    local t = k / FAIRING_NOSE_SEGS
    local rr = r * math.sqrt(math.max(0, 1 - t * t)) * (1 - 0.15 * t)
    if k == FAIRING_NOSE_SEGS then rr = 0.0 end
    prof[#prof + 1] = { rr, y + hn * t }
  end
  return prof
end

function fairingAutoProfile(r, y0, hc, hn)
  return ogive({ { r, y0 }, { r, hc } }, r, hc, hn)
end

-- Close an open profile over the top: an ogive from its last ring. A profile
-- that already ends in a point is left as it is.
function fairingNose(prof)
  local last = prof[#prof]
  if not last or last[1] <= 0.02 then return prof end
  return ogive(prof, last[1], last[2], math.max(0.15, last[1] * FAIRING_NOSE_K))
end

-- A drawn shape as a profile: the base ring (radius R0 at y0), then each
-- section { r, h } (h above y0), then — once closed — the nose.
function fairingSectionsProfile(R0, y0, secs, closed)
  local prof = { { R0, y0 } }
  for _, sc in ipairs(secs or {}) do
    prof[#prof + 1] = { sc.r or sc[1], y0 + (sc.h or sc[2]) }
  end
  if closed then fairingNose(prof) end
  return prof
end

-- Profile ↔ the flat number list a record carries (one table deep).
function fairingFlat(prof)
  local out = {}
  for _, p in ipairs(prof or {}) do out[#out + 1] = p[1]; out[#out + 1] = p[2] end
  return out
end

function fairingUnflat(flat)
  local out = {}
  if type(flat) ~= "table" then return out end
  for i = 1, #flat - 1, 2 do out[#out + 1] = { flat[i], flat[i + 1] } end
  return out
end

-- A record's shell profile: the drawn one, else the fitted one, else nil.
function fairingProfileOf(d)
  if type(d) ~= "table" then return nil end
  if type(d.fprof) == "table" and #d.fprof >= 4 then return fairingUnflat(d.fprof) end
  if (d.fr or 0) > 0 and (d.fhc or 0) > 0 then
    return fairingAutoProfile(d.fr, d.fy0 or 0.1, d.fhc, d.fhn or d.fr * FAIRING_NOSE_K)
  end
  return nil
end

-- The shell's radius at height y (straight between rings); nil above or below it.
function fairingRadiusAt(prof, y)
  local n = #prof
  if n < 2 or y < prof[1][2] - 1e-6 or y > prof[n][2] + 1e-6 then return nil end
  for i = 1, n - 1 do
    local a, b = prof[i], prof[i + 1]
    if y <= b[2] + 1e-9 then
      local dy = b[2] - a[2]
      if dy <= 1e-9 then return math.min(a[1], b[1]) end
      local t = math.max(0, math.min(1, (y - a[2]) / dy))
      return a[1] + (b[1] - a[1]) * t
    end
  end
  return prof[n][1]
end

-- Does the shell hold something reaching `rad` out from the axis between the
-- heights y0 and y1? (Checked at both ends and at every ring in between —
-- the radius is straight between rings, so that is exact.)
function fairingHolds(prof, y0, y1, rad)
  local n = #prof
  if n < 2 or y0 < prof[1][2] - 0.05 or y1 > prof[n][2] + 1e-6 then return false end
  local function fits(y)
    local r = fairingRadiusAt(prof, math.max(prof[1][2], y))
    return r ~= nil and r >= rad - 1e-3
  end
  if not (fits(y0) and fits(y1)) then return false end
  for _, p in ipairs(prof) do
    if p[2] > y0 and p[2] < y1 and p[1] < rad - 1e-3 then return false end
  end
  return true
end

-- Skin area (m², the outside), widest radius and height of a profile. The
-- shell's mass is its area times the composite's tonnes per square metre, and
-- its frontal area (π · rmax²) is what it shows the air.
function fairingStats(prof)
  local area, rmax = 0.0, 0.0
  for i = 1, #prof - 1 do
    local r1, y1, r2, y2 = prof[i][1], prof[i][2], prof[i + 1][1], prof[i + 1][2]
    area = area + math.pi * (r1 + r2) * math.sqrt((r2 - r1) ^ 2 + (y2 - y1) ^ 2)
  end
  for _, p in ipairs(prof) do rmax = math.max(rmax, p[1]) end
  local h = #prof > 0 and (prof[#prof][2] - prof[1][2]) or 0
  return area, rmax, h
end

-- One CLAMSHELL piece: piece k (1-based) of n (2 or 3) round the axis, as
-- mesh.build's lists, outer skin and inner lining both, UVs in metres of skin.
-- Piece k spans the angles 2π(k−1)/n … 2πk/n (x = r·cos a, z = r·sin a).
function fairingPiece(prof, k, n, segs)
  n = math.max(2, math.min(3, n or 2))
  segs = math.max(6, math.floor((segs or 24) * 2 / n + 0.5))
  local L = { 0 }
  for i = 2, #prof do
    L[i] = L[i - 1] + math.sqrt((prof[i][1] - prof[i - 1][1]) ^ 2 + (prof[i][2] - prof[i - 1][2]) ^ 2)
  end
  local _, rmax = fairingStats(prof)
  local P, N, UV, I = {}, {}, {}, {}
  local span = 2 * math.pi / n
  local a0 = (k - 1) * span
  local function vert(x, y, z, nx, ny, nz, u, v)
    P[#P + 1] = x; P[#P + 1] = y; P[#P + 1] = z
    N[#N + 1] = nx; N[#N + 1] = ny; N[#N + 1] = nz
    UV[#UV + 1] = u; UV[#UV + 1] = v
    return #P / 3
  end
  local np = #prof
  for side = 1, 2 do                           -- 1 outer skin, 2 inner lining
    local sg = side == 1 and 1 or -1
    local base = #P / 3
    for i = 0, segs do
      local a = a0 + span * i / segs
      local c, s = math.cos(a), math.sin(a)
      for j = 1, np do
        local jj = math.max(1, math.min(np - 1, j))
        local dr = prof[jj + 1][1] - prof[jj][1]
        local dy = prof[jj + 1][2] - prof[jj][2]
        local l = math.max(1e-9, math.sqrt(dr * dr + dy * dy))
        local nr, ny = dy / l, -dr / l
        local rr = math.max(0, prof[j][1] - (side == 2 and 0.01 or 0))
        vert(rr * c, prof[j][2], rr * s, nr * c * sg, ny * sg, nr * s * sg, (a - a0) * rmax, -L[j])
      end
    end
    for i = 0, segs - 1 do
      for j = 1, np - 1 do
        local a = base + i * np + j
        local b = base + (i + 1) * np + j
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
  return { positions = P, normals = N, uvs = UV, indices = I }
end

-- Where piece k of n sits and how big a body it makes falling away, in the
-- base frame: its centre (ox, oy, oz), the way it leaves (dx, dz, outward),
-- box half-extents (hx along the base's X, hy, hz along its Z) and its share of
-- the skin.
function fairingPieceInfo(prof, k, n)
  n = math.max(2, math.min(3, n or 2))
  local area, rmax = fairingStats(prof)
  local ac = (k - 0.5) * 2 * math.pi / n
  local dx, dz = math.cos(ac), math.sin(ac)
  local y0, y1 = prof[1][2], prof[#prof][2]
  local reach = rmax * 0.5
  local hx, hz = rmax * 0.8, rmax * 0.4
  if n == 2 then
    -- halves leave along ±Z: thin that way, wide across
    hx, hz = rmax * 0.8, rmax * 0.4
  else
    hx, hz = rmax * 0.55, rmax * 0.55
  end
  return { ox = dx * reach, oy = (y0 + y1) * 0.5, oz = dz * reach, dx = dx, dz = dz,
           hx = hx, hy = math.max(0.1, (y1 - y0) * 0.5), hz = hz, rmax = rmax, area = area / n }
end

-- The fitted shell's half (0 or 1), as before shaping existed.
function fairingShell(r, y0, hc, hn, half, segs)
  return fairingPiece(fairingAutoProfile(r, y0, hc, hn), (half or 0) + 1, 2, segs)
end

-- A record's piece k of its n (`fsplit`, default 2): what the flight builds.
function fairingMeshOf(d, k, segs)
  local prof = fairingProfileOf(d)
  if not prof then return nil end
  return fairingPiece(prof, k, d.fsplit or 2, segs)
end
