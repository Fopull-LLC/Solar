-- CONTROLS — the rulebook for what a craft's keys do: action groups on any
-- free key, analog AXES (pitch, yaw, roll, throttle, steer, drive, translate
-- and custom key pairs) driving actuator setpoints with gain and trim, the
-- reserved flight keys, presets, and the save format (docs/builder-design.md
-- §6, WP5).
--
-- A pure RULEBOOK script (no scene access, no state of its own): it rides the
-- "Controls" manager node of scenes/builder.ron and, in flight, the
-- ControlsLib prefab vessel_controller spawns when the scene has none.
-- Reach it with findScript("controls"); the smoke tests load it from disk.
-- Part actions themselves are electronics.lua's (actionsOf / applyAction):
-- every function here that needs them takes the electronics handle `E`.
--
-- ── THE MODEL ───────────────────────────────────────────────────────────────
--
--   groups   electronics' table, unchanged: gid → { name, binds = {{uid, act}} }.
--            gid is a standard id ("gear" …), a digit "1".."0", or — new — a
--            key group "k:<key>" ("k:p", "k:[") for any other free key.
--   ctl      this file's live table: {
--              axes   = { { uid, act = "angle", src = "pitch"|"c1"…, gain = −1..1,
--                           trim, mode = "position"|"rate", dead = 0..0.2,
--                           smooth = s }, … },
--              custom = { c1 = { pos = "up", neg = "down", name = "Crane" }, … },
--              rt     = runtime only (latches, smoothing; never saved) }
--   data     the saved form (`pack`): strings only, so it is safe at any
--            depth of save.set. bp.controls is a data table; the builder keeps
--            one (controlsData / setControls) and hands it to bind / unbind /
--            bindAxis below. `live(data)` reads either form.
--
--   POSITION mode: setpoint = centre + trim + gain × input × half-range — a
--                  servo that follows the stick and springs back to trim.
--   RATE mode:     setpoint += gain × input × rate × dt, held where it stops —
--                  a crane arm.
--   A custom axis with only a + key is a LATCH: each press flips its input
--   between +1 and −1 (a one-key toggle between the two presets).
--
-- The flight applies it in vessel_controller.groupKeysTick: readInputs →
-- evaluate → apply. Old crafts carry only `bp.groups`; they load unchanged and
-- simply have no axes.

lastError = nil   -- the reason the last bind / unbind / bindAxis said no

-- ── keys ────────────────────────────────────────────────────────────────────

-- Keys the flight already owns, and what for (validKey's refusal reason).
RESERVED = {
  w = "pitch (W/S)", s = "pitch (W/S)", a = "yaw (A/D)", d = "yaw (A/D)",
  q = "roll (Q/E)", e = "roll (Q/E)",
  shift = "throttle up", ctrl = "throttle down", x = "throttle cut", z = "full throttle",
  space = "staging", i = "translation", j = "translation", k = "translation", l = "translation",
  h = "translation", n = "translation", m = "the map", f = "board / step out",
  v = "the cockpit view", c = "the camera mode", ["."] = "time warp", [","] = "time warp",
  escape = "the pause menu", alt = "the autopilot holds (Alt+1…9, Alt+0 target)", tab = "the map's target",
  o = "the Controls card", ["/"] = "the objective switcher", enter = "flight ops", f4 = "photo mode", f5 = "photo mode",
  f6 = "photo mode", f12 = "screenshots", super = "the system", capslock = "the system",
}

-- Every key a bind prompt listens for (engine script names, floptle-input
-- source.rs): letters, digits, arrows, the navigation block, symbols, numpad.
CAPTURE_KEYS = {}
for c in ("abcdefghijklmnopqrstuvwxyz0123456789"):gmatch(".") do CAPTURE_KEYS[#CAPTURE_KEYS + 1] = c end
for _, k in ipairs({ "up", "down", "left", "right", "insert", "delete", "home", "end", "pageup", "pagedown",
                     "backspace", "[", "]", ";", "'", "/", "\\", "-", "=", "`", ",", ".",
                     "num0", "num1", "num2", "num3", "num4", "num5", "num6", "num7", "num8", "num9",
                     "num+", "num-", "num*", "num/", "num.", "space", "shift", "ctrl", "tab",
                     "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12" }) do
  CAPTURE_KEYS[#CAPTURE_KEYS + 1] = k
end

local KEY_LABEL = {
  up = "↑", down = "↓", left = "←", right = "→", backspace = "⌫", space = "SPACE",
  pageup = "PGUP", pagedown = "PGDN", delete = "DEL", insert = "INS", home = "HOME", ["end"] = "END",
  escape = "ESC", enter = "⏎", shift = "SHIFT", ctrl = "CTRL", tab = "TAB",
}

-- What a key cap says: "P", "↑", "NUM8", "⌫".
function keyLabel(k)
  if k == nil then return "—" end
  k = tostring(k)
  return KEY_LABEL[k] or k:upper()
end

-- May a group or a custom axis sit on this key? → ok, reason.
function validKey(k)
  if type(k) ~= "string" or k == "" then return false, "no key" end
  k = k:lower()
  local why = RESERVED[k]
  if why then return false, keyLabel(k) .. " is " .. why .. " in flight" end
  return true
end

-- ── groups on any key ───────────────────────────────────────────────────────

local STD_BY_KEY = {}   -- filled from electronics on first use
local function std_keys(E)
  if next(STD_BY_KEY) == nil and E and E.STANDARD_GROUPS then
    for _, g in ipairs(E.STANDARD_GROUPS) do STD_BY_KEY[g.key] = g.id end
  end
  return STD_BY_KEY
end
local DIGITS = { ["1"] = true, ["2"] = true, ["3"] = true, ["4"] = true, ["5"] = true,
                 ["6"] = true, ["7"] = true, ["8"] = true, ["9"] = true, ["0"] = true }

-- The group a key fires: a standard group on its key (G → gear), a digit's
-- own custom group, else a key group "k:<key>".
function gidForKey(k, E)
  k = tostring(k):lower()
  local std = std_keys(E)[k]
  if std then return std end
  if DIGITS[k] then return k end
  return "k:" .. k
end

-- The key a group sits on.
function keyOfGroup(gid, E)
  gid = tostring(gid)
  local k = gid:match("^k:(.+)$")
  if k then return k end
  if DIGITS[gid] then return gid end
  if E and E.groupKey then return E.groupKey(gid) end
  return nil
end

-- A group's display name: its own, else the standard label, else the key.
function groupName(groups, gid, E)
  local g = groups and groups[gid]
  if g and g.name and g.name ~= "" then return g.name end
  local info = E and E.groupInfo and E.groupInfo(gid)
  if info then return info.label end
  return "Key " .. keyLabel(keyOfGroup(gid, E))
end

-- The key groups ("k:*") that hold anything, for the flight's key loop (the
-- standard and digit groups are electronics.groupList's): { { id, key, label } }.
function extraGroups(groups)
  local out = {}
  for gid, g in pairs(groups or {}) do
    local k = tostring(gid):match("^k:(.+)$")
    if k and #(g.binds or {}) > 0 then out[#out + 1] = { id = gid, key = k, label = g.name or ("Key " .. keyLabel(k)) } end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

-- Every group in a fixed order: electronics' list, then the key groups.
function allGroups(groups, E)
  local out = {}
  if E and E.groupList then
    for _, g in ipairs(E.groupList()) do out[#out + 1] = { id = g.id, key = g.key, label = g.label, standard = g.standard } end
  end
  for _, g in ipairs(extraGroups(groups)) do out[#out + 1] = g end
  return out
end

-- Everything bound to anything on this part, key groups included: { { gid, act } }.
function bindsOfPart(groups, uid, E)
  local out = {}
  for _, g in ipairs(allGroups(groups, E)) do
    local gg = groups and groups[g.id]
    for _, b in ipairs(gg and gg.binds or {}) do
      if b.uid == uid then out[#out + 1] = { gid = g.id, act = b.act } end
    end
  end
  return out
end

-- A custom group left empty gets its default name back (the auto actuator
-- keys name theirs "Hinge +"; once the hinge is on an axis that name lies).
local function tidy(groups, E)
  for gid, g in pairs(groups or {}) do
    if #(g.binds or {}) == 0 then
      if tostring(gid):match("^k:") then groups[gid] = nil
      elseif DIGITS[gid] then
        local info = E and E.groupInfo and E.groupInfo(gid)
        g.name = info and info.label or g.name
      end
    end
  end
end

-- ── axes ────────────────────────────────────────────────────────────────────

-- The built-in sources. pos/neg are the flight's keys for it (display, and
-- the builder's TEST); `level` sources are read as a 0..1 lever.
AXES = {
  { id = "pitch",    label = "PITCH",    pos = "w", neg = "s" },
  { id = "yaw",      label = "YAW",      pos = "a", neg = "d" },
  { id = "roll",     label = "ROLL",     pos = "e", neg = "q" },
  { id = "throttle", label = "THROTTLE", pos = "shift", neg = "ctrl", level = true },
  { id = "steer",    label = "STEER",    pos = "a", neg = "d" },
  { id = "drive",    label = "DRIVE",    pos = "w", neg = "s" },
  { id = "tx",       label = "TRANSLATE X", pos = "l", neg = "j" },
  { id = "ty",       label = "TRANSLATE Y", pos = "i", neg = "k" },
  { id = "tz",       label = "TRANSLATE Z", pos = "h", neg = "n" },
}
local AXIS_BY_ID = {}
for _, a in ipairs(AXES) do AXIS_BY_ID[a.id] = a end
MAX_CUSTOM = 6
MAX_GROUPS = 20

function axisInfo(src) return AXIS_BY_ID[src] end

function newCtl() return { axes = {}, custom = {}, rt = {} } end

local function ensure(ctl)
  ctl = ctl or newCtl()
  ctl.axes = ctl.axes or {}
  ctl.custom = ctl.custom or {}
  ctl.rt = ctl.rt or {}
  return ctl
end

-- A source's display: "PITCH W/S", "C1 ↑/↓", "Crane P (toggle)".
function sourceLabel(ctl, src)
  local a = AXIS_BY_ID[src]
  if a then
    if a.level then return a.label end
    return a.label .. " " .. keyLabel(a.pos) .. "/" .. keyLabel(a.neg)
  end
  local c = ctl and ctl.custom and ctl.custom[src]
  if c then
    local keys = c.neg and (keyLabel(c.pos) .. "/" .. keyLabel(c.neg)) or (keyLabel(c.pos) .. " toggle")
    return (c.name and c.name ~= "" and c.name or tostring(src):upper()) .. "  " .. keys
  end
  return tostring(src)
end

-- The keys of a source: "↑/↓", "W/S", "P".
function sourceKeys(ctl, src)
  local a = AXIS_BY_ID[src]
  if a then return a.level and "THR" or (keyLabel(a.pos) .. "/" .. keyLabel(a.neg)) end
  local c = ctl and ctl.custom and ctl.custom[src]
  if c then return c.neg and (keyLabel(c.pos) .. "/" .. keyLabel(c.neg)) or keyLabel(c.pos) end
  return "—"
end

-- A custom axis on this key pair (neg nil: a one-key latch), reused if one
-- already has exactly these keys. → id ("c1"…) or nil, reason.
function customAxis(ctl, pos, neg, name)
  ctl = ensure(ctl)
  if not pos then return nil, "no key" end
  for id, c in pairs(ctl.custom) do
    if c.pos == pos and c.neg == neg then
      if name and name ~= "" and not c.name then c.name = name end
      return id
    end
  end
  for i = 1, MAX_CUSTOM do
    local id = "c" .. i
    if not ctl.custom[id] then
      ctl.custom[id] = { pos = pos, neg = neg, name = name }
      return id
    end
  end
  return nil, "all " .. MAX_CUSTOM .. " custom axes are in use — clear one first"
end

-- Drop custom axes nothing is bound to.
local function tidy_custom(ctl)
  local used = {}
  for _, b in ipairs(ctl.axes) do used[b.src] = true end
  for id in pairs(ctl.custom) do if not used[id] then ctl.custom[id] = nil end end
end

-- Set one part's axis binding (`act` = "angle" | "extension" | "rpm" …). One
-- per (uid, act): a new one replaces the old. Returns the binding.
function setAxis(ctl, b)
  ctl = ensure(ctl)
  if not (b and b.uid and b.act and b.src) then return nil end
  local nb = { uid = b.uid, act = b.act, src = b.src,
               gain = math.max(-1, math.min(1, b.gain or 1)), trim = b.trim or 0,
               mode = (b.mode == "position") and "position" or "rate",
               dead = math.max(0, math.min(0.2, b.dead or 0)), smooth = math.max(0, b.smooth or 0) }
  for i, x in ipairs(ctl.axes) do
    if x.uid == nb.uid and x.act == nb.act then
      ctl.axes[i] = nb
      tidy_custom(ctl)
      return nb
    end
  end
  ctl.axes[#ctl.axes + 1] = nb
  return nb
end

-- Take a part's axis binding off (act nil: every axis of the part).
function clearAxis(ctl, uid, act)
  if not ctl then return 0 end
  local n, keep = 0, {}
  for _, x in ipairs(ctl.axes or {}) do
    if x.uid == uid and (act == nil or x.act == act) then n = n + 1 else keep[#keep + 1] = x end
  end
  ctl.axes = keep
  tidy_custom(ctl)
  return n
end

function axisOf(ctl, uid, act)
  for _, x in ipairs(ctl and ctl.axes or {}) do
    if x.uid == uid and x.act == act then return x end
  end
  return nil
end

function axesOfPart(ctl, uid)
  local out = {}
  for _, x in ipairs(ctl and ctl.axes or {}) do if x.uid == uid then out[#out + 1] = x end end
  return out
end

-- Change a binding's tuning in place (gain, trim, mode, dead, smooth).
function tuneAxis(ctl, uid, act, field, v)
  local x = axisOf(ctl, uid, act)
  if not x then return nil end
  if field == "gain" then x.gain = math.max(-1, math.min(1, tonumber(v) or 1))
  elseif field == "trim" then x.trim = tonumber(v) or 0
  elseif field == "mode" then x.mode = (v == "position") and "position" or "rate"
  elseif field == "dead" then x.dead = math.max(0, math.min(0.2, tonumber(v) or 0))
  elseif field == "smooth" then x.smooth = math.max(0, tonumber(v) or 0)
  elseif field == "src" then x.src = v; tidy_custom(ctl) end
  return x
end

-- The axis setting an action belongs to on a record: { id, min, max, rate,
-- center, unit, module } from electronics' MODULES (nil: not an axis there).
function axisSpec(rec, act, E)
  if not (E and E.modsOf and E.MODULES) then return nil end
  for _, m in ipairs(E.modsOf(rec)) do
    local ty = E.MODULES[m.type]
    for _, a in ipairs(ty and ty.axes or {}) do
      if a.id == act then
        return { id = a.id, label = a.label, min = a.min, max = a.max, rate = m.rate or a.rate,
                 center = a.center or 0, unit = a.unit or "", module = m.type }
      end
    end
  end
  return nil
end

-- What the axes read this frame. `down(key)` and `pressed(key)` are the
-- engine's input.key / input.pressed (or a test's); `extra` carries what
-- isn't a key (extra.throttle 0..1, or any source by id, which wins).
-- → { pitch = −1..1, …, c1 = −1..1 }
function readInputs(ctl, down, pressed, extra)
  ctl = ensure(ctl)
  local out = {}
  local function pair(p, n)
    return ((p and down(p)) and 1 or 0) - ((n and down(n)) and 1 or 0)
  end
  for _, a in ipairs(AXES) do
    if not a.level then out[a.id] = pair(a.pos, a.neg) end
  end
  out.throttle = (extra and extra.throttle) and (extra.throttle * 2 - 1) or -1
  local latch = ctl.rt.latch or {}
  ctl.rt.latch = latch
  for id, c in pairs(ctl.custom) do
    if c.neg then
      out[id] = pair(c.pos, c.neg)
    else
      if pressed and pressed(c.pos) then latch[id] = not latch[id] end
      out[id] = latch[id] and 1 or -1
    end
  end
  if extra then
    for k, v in pairs(extra) do if k ~= "throttle" and type(v) == "number" then out[k] = v end end
  end
  return out
end

-- The setpoints the axes ask for: { { uid, act, value, input } }. `recs` uid →
-- the craft's records (their live `st` is read for rate mode); `dt` seconds.
function evaluate(ctl, inputs, recs, dt, E)
  ctl = ensure(ctl)
  local out = {}
  local sm = ctl.rt.smooth or {}
  ctl.rt.smooth = sm
  for _, b in ipairs(ctl.axes) do
    local rec = recs and recs[b.uid]
    local spec = rec and axisSpec(rec, b.act, E)
    if spec then
      local v = inputs[b.src] or 0
      if math.abs(v) < (b.dead or 0) then v = 0 end
      if (b.smooth or 0) > 0 then
        local key = tostring(b.uid) .. "|" .. b.act
        local cur = sm[key] or 0
        cur = cur + (v - cur) * math.min(1, (dt or 0) / b.smooth)
        sm[key] = cur
        v = cur
      end
      local val
      if b.mode == "position" then
        local half = (spec.max - spec.min) / 2
        -- a rotor's position is its speed about stop; a joint's about its middle
        local base = (spec.module == "rotor") and 0 or (spec.min + half)
        val = base + (b.trim or 0) + (b.gain or 1) * v * half
      else
        local st = E.stateOf(rec)
        local cur = st[b.act] or spec.center or 0
        val = cur + (b.gain or 1) * v * (spec.rate or 1) * (dt or 0)
      end
      val = math.max(spec.min, math.min(spec.max, val))
      out[#out + 1] = { uid = b.uid, act = b.act, value = val, input = v }
    end
  end
  return out
end

-- Write `evaluate`'s setpoints into the records' live state (what
-- vessel_controller's partAction would write): a piston past 0.4 m reads as
-- extended, and a rotor driven off zero switches its motor on.
function apply(out, recs, E)
  local n = 0
  for _, s in ipairs(out or {}) do
    local rec = recs and recs[s.uid]
    if rec and E then
      local st = E.stateOf(rec)
      if st[s.act] ~= s.value then n = n + 1 end
      st[s.act] = s.value
      if s.act == "extension" then st.extended = s.value > 0.4 end
      if s.act == "rpm" and math.abs(s.input or 0) > 0 then st.spin = true end
    end
  end
  return n
end

-- ── a part's controls (the context menu, the bind prompt) ───────────────────

local function has_mod(rec, ty, E)
  return E and E.modOf and E.modOf(rec, ty) ~= nil
end

-- The action a part's B binds by default (§6.3 A):
--   { axis = "angle" } for a hinge / piston / rotor, else { acts = {…} }.
function primaryOf(rec, E)
  if not (rec and E) then return nil end
  if has_mod(rec, "hinge", E) then return { axis = "angle", label = "Angle" } end
  if has_mod(rec, "piston", E) then return { axis = "extension", label = "Extension" } end
  if has_mod(rec, "rotor", E) then return { axis = "rpm", label = "Speed" } end
  if has_mod(rec, "drill", E) then return { acts = { "deployed.toggle", "drilling.toggle" }, label = "Lower and run" } end
  if has_mod(rec, "claw", E) then return { acts = { "armed.toggle" }, label = "Arm / disarm claw" } end
  if has_mod(rec, "light", E) then return { acts = { "lit.toggle" }, label = "Light on / off" } end
  local dm = E.modOf(rec, "deploy")
  if dm and dm.anim == "legs" then return { acts = { "deployed.toggle" }, label = "Extend / retract" } end
  if has_mod(rec, "engine", E) then return { acts = { "running.toggle" }, label = "Activate / shut down" } end
  if has_mod(rec, "decoupler", E) then return { acts = { "decouple" }, label = "Decouple" } end
  if has_mod(rec, "drive", E) then return { acts = { "brakes.toggle" }, label = "Brakes on / off" } end
  if has_mod(rec, "chute", E) then return { acts = { "chute" }, label = "Deploy chute" } end
  if dm then return { acts = { "deployed.toggle" }, label = "Extend / retract" } end
  for _, a in ipairs(E.actionsOf(rec)) do
    if a.kind == "toggle" or a.kind == "trigger" then return { acts = { a.id }, label = a.label } end
  end
  return nil
end

-- Every bindable thing on a part, the primary first: each axis as one entry
-- ({ axis }), every other action as its own ({ acts = { id } }), and a
-- drill's "Lower and run" pair. Each carries `id`.
function choicesOf(rec, E)
  local out, seen = {}, {}
  local function add(c)
    local k = c.axis and ("axis:" .. c.axis) or table.concat(c.acts, "+")
    if not seen[k] then seen[k] = true; c.id = k; out[#out + 1] = c end
  end
  local prim = primaryOf(rec, E)
  if prim then add(prim) end
  if not E then return out end
  for _, a in ipairs(E.actionsOf(rec)) do
    if a.kind == "axis" and a.dir == 1 then add({ axis = a.axis, label = (a.label:gsub(" %+$", "")) }) end
  end
  for _, a in ipairs(E.actionsOf(rec)) do
    if a.kind ~= "axis" or a.dir == 0 then add({ acts = { a.id }, label = a.label }) end
  end
  return out
end

-- The keys a choice is on now: group keys and, for an axis, its source.
function keysOfChoice(groups, ctl, uid, choice, E)
  local keys = {}
  if choice.axis then
    local b = axisOf(ctl, uid, choice.axis)
    if b then keys[#keys + 1] = sourceKeys(ctl, b.src) end
    for _, x in ipairs(bindsOfPart(groups, uid, E)) do
      if x.act == choice.axis .. ".inc" or x.act == choice.axis .. ".dec" then
        keys[#keys + 1] = keyLabel(keyOfGroup(x.gid, E)) .. (x.act:match("inc$") and "+" or "−")
      end
    end
    return keys
  end
  local want = {}
  for _, a in ipairs(choice.acts) do want[a] = true end
  local kseen = {}
  for _, x in ipairs(bindsOfPart(groups, uid, E)) do
    if want[x.act] and not kseen[x.gid] then
      kseen[x.gid] = true
      keys[#keys + 1] = keyLabel(keyOfGroup(x.gid, E))
    end
  end
  return keys
end

-- FOR WP2's CONTEXT MENU: every action of a part with the keys it is on.
--   → { { id, label, axis | acts, keys = { "P" … }, binding = axis binding|nil,
--         primary = bool } }
-- `ctl` may be the live table or the builder's controlsData().
function partControls(groups, ctl, rec, E)
  ctl = live(ctl)
  local out = {}
  if not rec then return out end
  for i, c in ipairs(choicesOf(rec, E)) do
    out[#out + 1] = { id = c.id, label = c.label, axis = c.axis, acts = c.acts, primary = i == 1,
                      keys = keysOfChoice(groups, ctl, rec.uid, c, E),
                      binding = c.axis and axisOf(ctl, rec.uid, c.axis) or nil }
  end
  return out
end

-- ── what's on a key ─────────────────────────────────────────────────────────

-- Everything a key already does on this craft: { { kind = "group", gid, name,
-- n, standard } | { kind = "axis", id, name } | { kind = "flight", why } }.
function keyUse(groups, ctl, k, E)
  ctl = live(ctl)
  local out = {}
  k = tostring(k):lower()
  local ok, why = validKey(k)
  if not ok then out[#out + 1] = { kind = "flight", why = why } end
  local gid = gidForKey(k, E)
  local g = groups and groups[gid]
  if g and #(g.binds or {}) > 0 then
    out[#out + 1] = { kind = "group", gid = gid, name = groupName(groups, gid, E), n = #g.binds,
                      standard = std_keys(E)[k] ~= nil }
  elseif std_keys(E)[k] then
    out[#out + 1] = { kind = "group", gid = gid, name = groupName(groups, gid, E), n = 0, standard = true }
  end
  for id, c in pairs(ctl.custom) do
    if c.pos == k or c.neg == k then out[#out + 1] = { kind = "axis", id = id, name = sourceLabel(ctl, id) } end
  end
  return out
end

-- ── binding (pure, on live tables) ──────────────────────────────────────────

-- Put `acts` of every uid in `uids` on key `k`. → gid or nil, reason.
function bindKey(groups, ctl, uids, acts, k, E, name)
  local ok, why = validKey(k)
  if not ok then return nil, why end
  k = k:lower()
  for id, c in pairs(ctl and ctl.custom or {}) do
    if c.pos == k or c.neg == k then return nil, keyLabel(k) .. " already drives " .. sourceLabel(ctl, id) end
  end
  local gid = gidForKey(k, E)
  local g = groups[gid]
  local fresh = not g or #(g.binds or {}) == 0
  local ngroups = 0
  for _, gg in pairs(groups) do if #(gg.binds or {}) > 0 then ngroups = ngroups + 1 end end
  if fresh and ngroups >= MAX_GROUPS then return nil, "a craft holds " .. MAX_GROUPS .. " groups — clear one first" end
  for _, u in ipairs(uids) do
    for _, a in ipairs(acts) do E.bind(groups, gid, u, a) end
  end
  g = groups[gid]
  if g and fresh and not std_keys(E)[k] and name and name ~= "" then g.name = name end
  if g and not g.name then g.name = groupName(groups, gid, E) end
  return gid
end

-- Take actions off a key (gid nil: off every key).
function unbindKey(groups, uids, acts, gid, E)
  local n = 0
  for _, u in ipairs(uids) do
    for _, a in ipairs(acts) do
      for _, g in ipairs(allGroups(groups, E)) do
        if (gid == nil or g.id == gid) and E.unbind(groups, g.id, u, a) then n = n + 1 end
      end
    end
  end
  tidy(groups, E)
  return n
end

-- Drive axis `act` of every uid from a key pair (neg nil: a one-key latch
-- between the presets) or a built-in source. Any `.inc`/`.dec` group keys the
-- parts had for that axis come off (two drivers on one joint fight).
--   spec = { pos, neg, src, mode, gain, trim, dead, smooth, name }
-- → source id or nil, reason.
function bindAxisKeys(groups, ctl, uids, act, spec, E)
  ctl = ensure(ctl)
  local src = spec.src
  if not src then
    for _, kk in ipairs({ spec.pos, spec.neg or spec.pos }) do
      local ok, why = validKey(kk)
      if not ok then return nil, why end
    end
    if spec.pos == spec.neg then return nil, "the two keys must differ" end
    local mine = {}
    for _, u in ipairs(uids) do mine[u] = true end
    for _, kk in ipairs({ spec.pos, spec.neg }) do
      local gid = gidForKey(kk, E)
      local g = groups and groups[gid]
      for _, b in ipairs(g and g.binds or {}) do
        if not mine[b.uid] then return nil, keyLabel(kk) .. " is " .. groupName(groups, gid, E) .. " already" end
      end
      if std_keys(E)[kk] then return nil, keyLabel(kk) .. " is the " .. groupName(groups, gid, E) .. " key" end
    end
    local why
    src, why = customAxis(ctl, spec.pos, spec.neg, spec.name)
    if not src then return nil, why end
  elseif not AXIS_BY_ID[src] and not ctl.custom[src] then
    return nil, "no such axis: " .. tostring(src)
  end
  local mode = spec.mode
  if not mode then mode = (ctl.custom[src] and ctl.custom[src].neg) and "rate" or "position" end
  for _, u in ipairs(uids) do
    if groups then
      -- the parts' own keys for this axis come off, and so does anything of
      -- theirs on the two keys the axis now owns
      -- every group key that drives this axis (inc, dec, centre, the stops,
      -- and a piston's Extend / retract) comes off: the axis owns it now
      for _, x in ipairs(bindsOfPart(groups, u, E)) do
        if x.act:sub(1, #act + 1) == act .. "." or (act == "extension" and x.act:match("^extended%.")) then
          E.unbind(groups, x.gid, u, x.act)
        end
      end
      local c = ctl.custom[src]
      for _, kk in ipairs(c and { c.pos, c.neg } or {}) do
        local gid = gidForKey(kk, E)
        local g = groups[gid]
        for i = #(g and g.binds or {}), 1, -1 do
          if g.binds[i].uid == u then table.remove(g.binds, i) end
        end
      end
      tidy(groups, E)
    end
    setAxis(ctl, { uid = u, act = act, src = src, mode = mode, gain = spec.gain or 1, trim = spec.trim or 0,
                   dead = spec.dead, smooth = spec.smooth })
  end
  tidy_custom(ctl)
  return src
end

-- ── presets (§6.3 D) ────────────────────────────────────────────────────────

-- recs in chain order (depth from the root through `parent`, then uid), one
-- entry per symmetry ring with every member listed: { { rec, uids = {…} } }.
local function rings(recs, filter)
  local depth = {}
  local function depth_of(u)
    if depth[u] then return depth[u] end
    local n, cur, guard = 0, u, 0
    while recs[cur] and (recs[cur].parent or 0) ~= 0 and guard < 128 do
      cur = recs[cur].parent
      n, guard = n + 1, guard + 1
    end
    depth[u] = n
    return n
  end
  local list = {}
  for _, r in pairs(recs) do if not filter or filter(r) then list[#list + 1] = r end end
  table.sort(list, function(a, b)
    local da, db = depth_of(a.uid), depth_of(b.uid)
    if da ~= db then return da < db end
    return a.uid < b.uid
  end)
  local out, by = {}, {}
  for _, r in ipairs(list) do
    local ring = (r.sym and r.sym ~= 0) and ("s" .. r.sym) or nil
    local e = ring and by[ring]
    if e then e.uids[#e.uids + 1] = r.uid
    else
      e = { rec = r, uids = { r.uid } }
      out[#out + 1] = e
      if ring then by[ring] = e end
    end
  end
  return out
end

local ARM_PAIRS = { { "1", "2" }, { "3", "4" }, { "5", "6" }, { "7", "8" }, { "9", "0" } }

-- ARM: the actuators (hinges, pistons, rotors) in chain order get key pairs
-- 1/2, 3/4, 5/6… as rate axes; the claw or drill gets P. `only` (a uid set)
-- limits it to the selection. → how many parts it set.
function presetArm(groups, ctl, recs, E, only)
  ctl = ensure(ctl)
  local function pick(r) return not only or only[r.uid] end
  local joints = rings(recs, function(r)
    return pick(r) and (has_mod(r, "hinge", E) or has_mod(r, "piston", E) or has_mod(r, "rotor", E))
  end)
  local tools = rings(recs, function(r) return pick(r) and (has_mod(r, "claw", E) or has_mod(r, "drill", E)) end)
  -- clear what those parts had (their group keys and axes), and the digit
  -- groups the arm is about to use
  for _, list in ipairs({ joints, tools }) do
    for _, e in ipairs(list) do
      for _, u in ipairs(e.uids) do
        for _, x in ipairs(bindsOfPart(groups, u, E)) do E.unbind(groups, x.gid, u, x.act) end
        clearAxis(ctl, u)
      end
    end
  end
  for i = 1, math.min(#joints, #ARM_PAIRS) do
    for _, kk in ipairs(ARM_PAIRS[i]) do if groups[kk] then groups[kk].binds = {} end end
  end
  for id, c in pairs(ctl.custom) do
    for i = 1, math.min(#joints, #ARM_PAIRS) do
      local p = ARM_PAIRS[i]
      if c.pos == p[1] or c.pos == p[2] or c.neg == p[1] or c.neg == p[2] then
        for j = #ctl.axes, 1, -1 do if ctl.axes[j].src == id then table.remove(ctl.axes, j) end end
      end
    end
  end
  tidy(groups, E)
  tidy_custom(ctl)
  local n = 0
  for i, e in ipairs(joints) do
    local pair = ARM_PAIRS[i]
    if not pair then break end
    local p = primaryOf(e.rec, E)
    if bindAxisKeys(groups, ctl, e.uids, p.axis,
      { pos = pair[1], neg = pair[2], mode = "rate", name = (e.rec.label or "Joint") .. " " .. i }, E) then
      n = n + #e.uids
    end
  end
  for _, e in ipairs(tools) do
    local p = primaryOf(e.rec, E)
    if bindKey(groups, ctl, e.uids, p.acts, "p", E, e.rec.label or "Tool") then n = n + #e.uids end
  end
  return n
end

-- ROVER: drive and steer are the wheels' own (W/S, A/D); brakes on B and
-- lights on Y.
function presetRover(groups, ctl, recs, E)
  local n = 0
  for u, r in pairs(recs) do
    if has_mod(r, "drive", E) then E.bind(groups, "brakes", u, "brakes.toggle"); n = n + 1 end
    if has_mod(r, "light", E) then E.bind(groups, "lights", u, "lit.toggle"); n = n + 1 end
  end
  return n
end

-- PLANE: control surfaces fly on auto (aero.lua mixes pitch, yaw and roll),
-- gear on G, wheel brakes on B, lights on Y.
function presetPlane(groups, ctl, recs, E)
  local n = presetRover(groups, ctl, recs, E)
  for u, r in pairs(recs) do
    local dm = E.modOf(r, "deploy")
    if dm and dm.anim == "legs" then E.bind(groups, "gear", u, "deployed.toggle"); n = n + 1 end
  end
  return n
end

-- ROCKET: the standard set (electronics.defaultGroups) and no axes.
function presetRocket(groups, ctl, recs, E)
  for k in pairs(groups) do groups[k] = nil end
  for k, v in pairs(E.defaultGroups(recs)) do groups[k] = v end
  ctl = ensure(ctl)
  ctl.axes, ctl.custom = {}, {}
  return 1
end

PRESETS = {
  { id = "arm",    label = "Arm",    tip = "Joints in chain order on 1/2, 3/4, 5/6…; claw or drill on P" },
  { id = "rover",  label = "Rover",  tip = "Drive and steer on W/S A/D, brakes B, lights Y" },
  { id = "plane",  label = "Plane",  tip = "Surfaces on auto, gear G, brakes B, lights Y" },
  { id = "rocket", label = "Rocket", tip = "The standard set: legs on G, panels on U, lights on Y; no axes" },
}

function preset(id, groups, ctl, recs, E, only)
  if id == "arm" then return presetArm(groups, ctl, recs, E, only) end
  if id == "rover" then return presetRover(groups, ctl, recs, E) end
  if id == "plane" then return presetPlane(groups, ctl, recs, E) end
  if id == "rocket" then return presetRocket(groups, ctl, recs, E) end
  return 0
end

-- PART PRESETS: copy one part's bindings, paste them onto parts of its kind.
function copyControls(groups, ctl, uid, E)
  ctl = live(ctl)
  local out = { groups = {}, axes = {} }
  for _, x in ipairs(bindsOfPart(groups, uid, E)) do out.groups[#out.groups + 1] = { gid = x.gid, act = x.act } end
  for _, x in ipairs(axesOfPart(ctl, uid)) do
    out.axes[#out.axes + 1] = { act = x.act, src = x.src, gain = x.gain, trim = x.trim, mode = x.mode,
                                dead = x.dead, smooth = x.smooth }
  end
  return out
end

function pasteControls(groups, ctl, clip, uids, E)
  ctl = ensure(ctl)
  local n = 0
  for _, u in ipairs(uids) do
    for _, x in ipairs(clip.groups or {}) do if E.bind(groups, x.gid, u, x.act) then n = n + 1 end end
    for _, x in ipairs(clip.axes or {}) do
      local b = { uid = u }
      for k, v in pairs(x) do b[k] = v end
      setAxis(ctl, b)
      n = n + 1
    end
  end
  return n
end

-- ── save format ─────────────────────────────────────────────────────────────
-- save.set keeps four tables deep at most, so bindings travel as strings:
--   bp.controls = { v = 1, axes = { "uid|act|src|gain|trim|mode|dead|smooth" },
--                   custom = { "c1|up|down|Crane" } }
-- Group bindings stay in bp.groups (electronics.packGroups), unchanged, so an
-- old flight reads a new craft's groups and a new flight an old craft's.

local function num(s, d) return tonumber(s) or d end

local function is_data(t)
  if type(t) ~= "table" then return false end
  if t.v then return true end
  return type((t.axes or {})[1]) == "string" or type((t.custom or {})[1]) == "string"
end

function pack(ctl)
  ctl = live(ctl)
  local out = { v = 1, axes = {}, custom = {} }
  for _, b in ipairs(ctl.axes or {}) do
    out.axes[#out.axes + 1] = string.format("%s|%s|%s|%.4g|%.4g|%s|%.4g|%.4g", tostring(b.uid), b.act, b.src,
      b.gain or 1, b.trim or 0, b.mode or "rate", b.dead or 0, b.smooth or 0)
  end
  local ids = {}
  for id in pairs(ctl.custom or {}) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local c = ctl.custom[id]
    out.custom[#out.custom + 1] = table.concat({ id, c.pos or "", c.neg or "", ((c.name or ""):gsub("|", "/")) }, "|")
  end
  return out
end

function unpack(t)
  local ctl = newCtl()
  if type(t) ~= "table" then return ctl end
  for _, s in ipairs(t.custom or {}) do
    if type(s) == "string" then
      local id, pos, neg, name = s:match("^([^|]*)|([^|]*)|([^|]*)|?(.*)$")
      if id and id ~= "" and pos ~= "" then
        ctl.custom[id] = { pos = pos, neg = (neg ~= "" and neg or nil), name = (name ~= "" and name or nil) }
      end
    end
  end
  for _, s in ipairs(t.axes or {}) do
    if type(s) == "string" then
      local f = {}
      for x in (s .. "|"):gmatch("([^|]*)|") do f[#f + 1] = x end
      local uid = tonumber(f[1]) or f[1]
      if uid and f[2] and f[2] ~= "" and f[3] and f[3] ~= "" then
        ctl.axes[#ctl.axes + 1] = { uid = uid, act = f[2], src = f[3], gain = num(f[4], 1), trim = num(f[5], 0),
                                    mode = (f[6] == "position") and "position" or "rate",
                                    dead = num(f[7], 0), smooth = num(f[8], 0) }
      end
    end
  end
  return ctl
end

-- Either form → a live table (a live one is returned as it is).
function live(t)
  if t == nil then return newCtl() end
  if is_data(t) then return unpack(t) end
  return ensure(t)
end

-- Write a live table back into a data table IN PLACE (the builder's
-- controlsData() is the same table before and after a command).
local function store(data, ctl)
  local p = pack(ctl)
  for k in pairs(data) do data[k] = nil end
  for k, v in pairs(p) do data[k] = v end
  return data
end

-- Drop axes on parts not in `alive` (uid → truthy), and custom axes left idle.
function prune(ctl, alive)
  local wasData = is_data(ctl)
  local c = live(ctl)
  local keep = {}
  for _, b in ipairs(c.axes) do if alive[b.uid] then keep[#keep + 1] = b end end
  c.axes = keep
  tidy_custom(c)
  if wasData then return store(ctl, c) end
  return c
end

-- Renumber (`map` old uid → new), dropping axes not in the map (docking, a
-- pasted sub-assembly). Takes and returns the same form it was given.
function remap(t, map)
  local wasData = is_data(t)
  local ctl = live(t)
  local out = newCtl()
  for id, c in pairs(ctl.custom or {}) do out.custom[id] = { pos = c.pos, neg = c.neg, name = c.name } end
  for _, b in ipairs(ctl.axes or {}) do
    local u = map[b.uid]
    if u then
      local nb = {}
      for k, v in pairs(b) do nb[k] = v end
      nb.uid = u
      out.axes[#out.axes + 1] = nb
    end
  end
  tidy_custom(out)
  if wasData then return pack(out) end
  return out
end

-- Fold `src` into `dst` (live tables): a docked module's custom axes join ours
-- on their keys (an axis on the same key pair is shared).
function merge(dst, src)
  dst = ensure(dst)
  src = src and live(src)
  if not src then return dst end
  local idmap = {}
  for id, c in pairs(src.custom or {}) do idmap[id] = customAxis(dst, c.pos, c.neg, c.name) end
  for _, b in ipairs(src.axes or {}) do
    local s = idmap[b.src] or (AXIS_BY_ID[b.src] and b.src)
    if s then
      local nb = {}
      for k, v in pairs(b) do nb[k] = v end
      nb.src = s
      setAxis(dst, nb)
    end
  end
  return dst
end

-- Only the axes on parts in `uids` (a set), for a craft splitting off.
function subset(ctl, uids)
  local c = live(ctl)
  local out = newCtl()
  for id, x in pairs(c.custom) do out.custom[id] = { pos = x.pos, neg = x.neg, name = x.name } end
  for _, b in ipairs(c.axes) do
    if uids[b.uid] then
      local nb = {}
      for k, v in pairs(b) do nb[k] = v end
      out.axes[#out.axes + 1] = nb
    end
  end
  tidy_custom(out)
  return out
end

function deepCopy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = deepCopy(v) end
  return o
end

-- ── the builder's commands (cmd "bind" / "unbind" / "bindAxis") ─────────────
-- builder.lua forwards these as f(state, args, ctx), one history step each:
--   state  its controlsData() table (the saved form), changed IN PLACE
--   ctx    { groups = the live action groups (builder groups_own()),
--            recs = craft records uid → { uid, id, label, mods, sym, parent },
--            E = electronics, members = function(uid) → ring uids }
-- Each returns a truthy result, or false with `lastError` set.

local function ctx_parts(args, ctx)
  local uids = args.uids or (args.uid and { args.uid }) or {}
  local out, seen = {}, {}
  for _, u in ipairs(uids) do
    local ring = (ctx and ctx.members) and ctx.members(u) or { u }
    for _, m in ipairs(ring) do
      if not seen[m] then seen[m] = true; out[#out + 1] = m end
    end
  end
  return out
end

local function fail(why) lastError = why return false end

-- bind { uids | uid, acts = {…}, key, name }  — actions on a key
--      { uids | uid, axis = "angle", pos, neg | src, mode, gain, trim, name } — an axis
--      { preset = "arm"|"rover"|"plane"|"rocket", uids = selection (arm only) }
--      { paste = copyControls(…), uids }
function bind(state, args, ctx)
  lastError = nil
  args = args or {}
  local E, groups = ctx and ctx.E, ctx and ctx.groups
  if not (E and groups and state) then return fail("no controls state") end
  local ctl = live(state)
  local res, why
  if args.preset then
    local only = nil
    if args.uids and #args.uids > 0 and args.preset == "arm" then
      only = {}
      for _, u in ipairs(ctx_parts(args, ctx)) do only[u] = true end
    end
    res = preset(args.preset, groups, ctl, ctx.recs or {}, E, only)
    if not res or res == 0 then why = "nothing on this craft for the " .. args.preset .. " preset" end
  elseif args.paste then
    res = pasteControls(groups, ctl, args.paste, ctx_parts(args, ctx), E)
  elseif args.axis then
    res, why = bindAxisKeys(groups, ctl, ctx_parts(args, ctx), args.axis, args, E)
  else
    local acts = args.acts or (args.act and { args.act })
    if not acts or not args.key then return fail("bind needs acts and a key") end
    res, why = bindKey(groups, ctl, ctx_parts(args, ctx), acts, args.key, E, args.name)
  end
  if not res or res == 0 then return fail(why or "nothing bound") end
  store(state, ctl)
  return res
end

-- unbind { uids | uid, acts, gid | key }  — off one key, or every key
--        { uids | uid, axis = "angle" }    — the part's axis binding
--        { all = true }                     — every group and axis (clear all)
--        { gid, rename = "Crane" }          — rename a group (the flight label)
function unbind(state, args, ctx)
  lastError = nil
  args = args or {}
  local E, groups = ctx and ctx.E, ctx and ctx.groups
  if not (E and groups and state) then return fail("no controls state") end
  local ctl = live(state)
  local n = 0
  if args.all then
    for k in pairs(groups) do groups[k] = nil end
    ctl.axes, ctl.custom = {}, {}
    n = 1
  elseif args.rename then
    local g = groups[args.gid]
    if not g then return fail("no such group") end
    g.name = args.rename
    n = 1
  elseif args.axis then
    for _, u in ipairs(ctx_parts(args, ctx)) do n = n + clearAxis(ctl, u, args.axis) end
  else
    local acts = args.acts or (args.act and { args.act })
    if not acts then return fail("unbind needs acts") end
    local gid = args.gid or (args.key and gidForKey(args.key, E))
    n = unbindKey(groups, ctx_parts(args, ctx), acts, gid, E)
  end
  if n == 0 then return fail("nothing to take off") end
  store(state, ctl)
  return n
end

-- bindAxis { uids | uid, act, src | pos, neg, mode, gain, trim, dead, smooth }
--          { uid, act, field = "gain"|"trim"|"mode"|"dead"|"smooth"|"src", value } — tune
function bindAxis(state, args, ctx)
  lastError = nil
  args = args or {}
  local E, groups = ctx and ctx.E, ctx and ctx.groups
  if not (E and state) then return fail("no controls state") end
  local ctl = live(state)
  if args.field then
    local done = false
    for _, u in ipairs(ctx_parts(args, ctx)) do
      if tuneAxis(ctl, u, args.act, args.field, args.value) then done = true end
    end
    if not done then return fail("that part has no axis binding") end
    store(state, ctl)
    return true
  end
  local res, why = bindAxisKeys(groups, ctl, ctx_parts(args, ctx), args.act or args.axis, args, E)
  if not res then return fail(why) end
  store(state, ctl)
  return res
end

-- ── the keymap (the CONTROLS tab) ───────────────────────────────────────────

local function rec_label(r) return r and (r.label or r.id) or "part" end

-- Parts collapsed by symmetry ring: { label, n, uids }.
local function part_chips(list, recs)
  local seen, order = {}, {}
  for _, u in ipairs(list) do
    local r = recs[u]
    if r then
      local k = (r.sym and r.sym ~= 0) and ("s" .. r.sym) or ("u" .. u)
      if not seen[k] then seen[k] = { label = rec_label(r), n = 0, uids = {} }; order[#order + 1] = k end
      seen[k].n = seen[k].n + 1
      seen[k].uids[#seen[k].uids + 1] = u
    end
  end
  local out = {}
  for _, k in ipairs(order) do out[#out + 1] = seen[k] end
  return out
end

-- One row per key in use and one per axis source:
--   { keys = { { key, cap, gid, name, parts = {chips}, acts = {labels}, mode, conflict, standard } },
--     axes = { { src, label, keys, custom, binds = { { uid, label, n, act, gain, trim, mode, uids } } } },
--     surfaces = { pitch = {chips}, yaw = …, roll = … } }
function keymap(groups, ctl, recs, E)
  ctl = live(ctl)
  local rows, byKey = {}, {}
  for _, g in ipairs(allGroups(groups, E)) do
    local gg = groups and groups[g.id]
    if gg and #(gg.binds or {}) > 0 then
      local k = keyOfGroup(g.id, E) or g.key
      local uids, acts, aseen, mode = {}, {}, {}, "⇅"
      for _, b in ipairs(gg.binds) do
        if recs[b.uid] then uids[#uids + 1] = b.uid end
        local r = recs[b.uid]
        local a = r and E.actionOf(r, b.act)
        if a and not aseen[a.label] then aseen[a.label] = true; acts[#acts + 1] = a.label end
        if a and a.kind == "trigger" then mode = "▸" end
        if a and a.kind == "axis" and a.dir ~= 0 then mode = "hold" end
      end
      if #uids > 0 then
        local row = { key = k, cap = keyLabel(k), gid = g.id, name = groupName(groups, g.id, E),
                      parts = part_chips(uids, recs), acts = acts, mode = mode, standard = g.standard }
        rows[#rows + 1] = row
        byKey[k] = row
      end
    end
  end
  local axes = {}
  local function axis_row(src)
    for _, a in ipairs(axes) do if a.src == src then return a end end
    local a = { src = src, label = sourceLabel(ctl, src), keys = sourceKeys(ctl, src), binds = {},
                custom = ctl.custom[src] ~= nil, name = ctl.custom[src] and ctl.custom[src].name or nil }
    axes[#axes + 1] = a
    return a
  end
  for _, b in ipairs(ctl.axes) do
    local r = recs[b.uid]
    if r then
      local a = axis_row(b.src)
      -- a ring with the same tuning is one line
      local ring = (r.sym and r.sym ~= 0) and r.sym or nil
      local line = nil
      for _, l in ipairs(a.binds) do
        if ring and l.sym == ring and l.act == b.act and l.gain == b.gain and l.trim == b.trim and l.mode == b.mode then line = l end
      end
      if line then
        line.n = line.n + 1
        line.uids[#line.uids + 1] = b.uid
      else
        a.binds[#a.binds + 1] = { uid = b.uid, uids = { b.uid }, label = rec_label(r), n = 1, act = b.act,
                                  gain = b.gain, trim = b.trim, mode = b.mode, sym = ring }
      end
      local c = ctl.custom[b.src]
      for _, kk in ipairs(c and { c.pos, c.neg } or {}) do
        if byKey[kk] then byKey[kk].conflict = true; a.conflict = true end
      end
    end
  end
  table.sort(axes, function(x, y)
    if x.custom ~= y.custom then return not x.custom end
    return x.src < y.src
  end)
  -- control surfaces on auto, by the axes their `af` says they answer (ctl=pr)
  local surf = { pitch = {}, yaw = {}, roll = {} }
  for u, r in pairs(recs) do
    local c = type(r.af) == "string" and r.af:match("ctl=(%a+)")
    if c then
      if c:find("p") then surf.pitch[#surf.pitch + 1] = u end
      if c:find("y") then surf.yaw[#surf.yaw + 1] = u end
      if c:find("r") then surf.roll[#surf.roll + 1] = u end
    end
  end
  for k, list in pairs(surf) do table.sort(list); surf[k] = part_chips(list, recs) end
  table.sort(rows, function(x, y)
    local xs, ys = x.standard and 1 or 0, y.standard and 1 or 0
    if xs ~= ys then return xs > ys end
    return tostring(x.key) < tostring(y.key)
  end)
  return { keys = rows, axes = axes, surfaces = surf }
end

-- How many custom controls the craft carries (the first-flight toast): custom
-- keys, custom axes and built-in axes driving parts.
function customCount(groups, ctl, E)
  ctl = live(ctl)
  local n = 0
  for gid, g in pairs(groups or {}) do
    if #(g.binds or {}) > 0 and (DIGITS[gid] or tostring(gid):match("^k:")) then n = n + 1 end
  end
  for _ in pairs(ctl.custom) do n = n + 1 end
  local srcs = {}
  for _, b in ipairs(ctl.axes) do if AXIS_BY_ID[b.src] and not srcs[b.src] then srcs[b.src] = true; n = n + 1 end end
  return n
end

-- ── the flight's Controls card ──────────────────────────────────────────────

-- { keys = { { id, cap, name, on, n } }, axes = { { src, cap, label, value
-- (−1..1 of the travel), text } } } for flight_hud: groups with their lamp
-- state and each axis source with the setpoint of its first part.
function card(groups, ctl, recs, E)
  ctl = live(ctl)
  local out = { keys = {}, axes = {} }
  for _, g in ipairs(allGroups(groups, E)) do
    local gg = groups and groups[g.id]
    local n = gg and #(gg.binds or {}) or 0
    if n > 0 then
      out.keys[#out.keys + 1] = { id = g.id, cap = keyLabel(keyOfGroup(g.id, E) or g.key), name = groupName(groups, g.id, E),
                                  on = E.groupState(groups, g.id, recs), n = n, standard = g.standard }
    end
  end
  local seen = {}
  for _, b in ipairs(ctl.axes) do
    local r = recs[b.uid]
    local spec = r and axisSpec(r, b.act, E)
    if spec and not seen[b.src] then
      seen[b.src] = true
      local v = E.stateOf(r)[b.act] or 0
      local frac = (spec.max > spec.min) and ((v - spec.min) / (spec.max - spec.min) * 2 - 1) or 0
      local c = ctl.custom[b.src]
      out.axes[#out.axes + 1] = {
        src = b.src, cap = sourceKeys(ctl, b.src), label = (c and c.name) or rec_label(r),
        value = math.max(-1, math.min(1, frac)),
        text = string.format((spec.unit == "m") and "%.2f m" or "%+.0f%s", v, spec.unit == "m" and "" or spec.unit) }
    end
  end
  return out
end
