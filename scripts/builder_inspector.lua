-- BUILDER_INSPECTOR — the right plate of the Vehicle Assembly (docs/builder-design.md
-- §4.4; WP2). Five tabs (TAB cycles them):
--
--   INSPECT   the selection: its name and count, mass and cost; its position
--             and turn as numbers you can type (ENTER applies, one undo step);
--             the part's own settings (a wheel's steering, drive, suspension —
--             moved here from the groups panel); its controls, with BIND
--   STAGE     the staging stack (the builder's STAGE tool shows it)
--   CONTROLS  the keymap (WP5's groups panel, the builder's GROUPS tool)
--   CRAFT     the control mode (Auto / Rover / Aircraft / Rocket, and what
--             Auto makes of the craft), the outliner's named groups, the
--             history (click a step to go back to it) and the budget: parts,
--             islands, the builder's cost
--   CREW      who sits where, the roster and the loadout (packs, locker
--             plans, base stock): scripts/builder_crew.lua describes it
--
-- Every number shown comes from the builder's API (partRec, stats, selection)
-- and every change goes through cmd(), so it is undoable and the craft stays
-- the builder's. Described only when the craft, the selection or the tab moved.

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end

TABS = { "INSPECT", "STAGE", "CONTROLS", "CRAFT", "CREW" }
local st = { tab = "INSPECT", sig = nil, t = 0 }

function tab() return st.tab end
function setTab(t)
  local B = ref("builder")
  st.tab = t
  st.sig = nil
  if not (B and B.setTool) then return end
  local cur = B.tool and B.tool() or nil
  if t == "STAGE" then B.setTool("stage")
  elseif t == "CONTROLS" then B.setTool("groups")
  elseif cur == "stage" or cur == "groups" then B.setTool("select") end
end
function cycleTab()
  for i, t in ipairs(TABS) do
    if t == st.tab then setTab(TABS[i % #TABS + 1]) return st.tab end
  end
  setTab("INSPECT")
  return st.tab
end

-- ── rotation maths (the builder's YXZ convention, builder.lua rot_basis) ────
function basisOf(yaw, pitch, roll)
  local cy, sy = math.cos(yaw or 0), math.sin(yaw or 0)
  local cx, sx = math.cos(pitch or 0), math.sin(pitch or 0)
  local cz, sz = math.cos(roll or 0), math.sin(roll or 0)
  return { X = { x = cy * cz + sy * sx * sz, y = cx * sz, z = -sy * cz + cy * sx * sz },
           Y = { x = -cy * sz + sy * sx * cz, y = cx * cz, z = sy * sz + cy * sx * cz },
           Z = { x = sy * cx, y = -sx, z = cy * cx } }
end
local function apply(B, v)
  return { x = B.X.x * v.x + B.Y.x * v.y + B.Z.x * v.z, y = B.X.y * v.x + B.Y.y * v.y + B.Z.y * v.z,
           z = B.X.z * v.x + B.Y.z * v.y + B.Z.z * v.z }
end
-- The world turn Q that takes basis `from` to basis `to`: Q = to · fromᵀ.
function turnBetween(from, to)
  local function col(i)
    local e = { x = from.X[i], y = from.Y[i], z = from.Z[i] }   -- fromᵀ · e_i
    return apply(to, e)
  end
  return { X = col("x"), Y = col("y"), Z = col("z") }
end

-- ── helpers ─────────────────────────────────────────────────────────────────
local function layout(W, H)
  local tb = ref("builder_toolbar")
  if tb and tb.builderLayout then return tb.builderLayout(W, H) end
  return { W = W, H = H, right = { x = W - 264, y = 80, w = 256, h = H - 138 } }
end
local function focused_name()
  local f = ui and ui.focused and ui.focused()
  return f and f.name or nil
end
local function say(B, msg) if B.hint then B.hint(msg, 2.5) end end

local function money(v)
  local co = ref("company")
  return (co and co.money) and co.money(v) or string.format("$%d", math.floor((v or 0) + 0.5))
end
local function mass_text(t)
  if t < 1 then return string.format("%.0f kg", t * 1000) end
  return string.format("%.2f t", t)
end

local function figure(k, label, value)
  return { "row", key = k, w = "100%", h = 18, gap = 6, pad = 0, align = "center",
    { "text", key = "l", style = "panel/label", w = 64, h = 18, text = label, textValign = "center" },
    { "text", key = "v", style = "panel/cellStrong", w = "grow", h = 18, text = value, textValign = "center",
      maxLines = 1, overflow = "ellipsis" } }
end

-- A numeric field; ENTER calls apply(number). Its text is described only
-- while it is NOT being typed in, so a re-describe never eats a keystroke.
local function numfield(k, name, value, fmt, applyfn, tip)
  local typing = focused_name() == name
  return { "row", key = k, w = "grow", h = 24, gap = 2, pad = 0, align = "center",
    { "text", key = "l", style = "panel/label", w = 12, h = 24, text = k:sub(-1):upper(), textValign = "center" },
    { "field", key = "f", name = name, style = "menu/field", w = "grow", h = 24, numeric = true, maxLen = 10, textSize = 12,
      text = (not typing) and string.format(fmt, value) or nil, tooltip = tip,
      onSubmitted = function(n)
        local x = n and tonumber(n.text)
        if x then applyfn(x) end
        if ui and ui.focus then ui.focus(nil) end
      end } }
end

local function rule(k) return { "box", key = k, style = "panel/rule", w = "100%", h = 1 } end
local function sublabel(k, t) return { "text", key = k, style = "panel/label", w = "100%", h = 16, text = t, textValign = "end" } end

-- ── the wheel's settings (moved from groups_panel) ──────────────────────────
local MODES = { "auto", "on", "off", "invert" }
local function wheel_rows(B, uid, rec, out)
  local defs = B.WCFG_DEFAULTS or { steer = "auto", steerMax = 25, drive = "auto", motor = 1, brake = 1,
                                                    spring = 1, damper = 1, friction = 1, skid = false }
  local c = B.wheelCfg and B.wheelCfg(uid) or nil
  if not c then
    c = {}
    for k, v in pairs(defs) do c[k] = v end
    for k, v in pairs(rec.wcfg or {}) do c[k] = v end
    if c.travel == nil then c.travel = rec.def.travel or 0.15 end
  end
  local function set(key, value, quiet)
    if B.cmd then B.cmd("setWcfg", { uid = uid, key = key, value = value, quiet = quiet, merge = "wcfg" .. key .. uid }) end
  end
  local function chips(key, label)
    local row = { "row", key = "m" .. key, w = "100%", h = 22, gap = 3, pad = 0, align = "center",
      { "text", key = "l", style = "panel/cell", w = 54, h = 22, text = label, textValign = "center" } }
    for _, m in ipairs(MODES) do
      row[#row + 1] = { "button", key = m, style = "panel/choice", selected = c[key] == m, w = "grow", h = 22,
        text = m, textAlign = "center", textValign = "center", onClicked = function() set(key, m) end }
    end
    return row
  end
  local function slider(key, label, lo, hi, show)
    local v = c[key] or lo
    return { "row", key = "s" .. key, w = "100%", h = 20, gap = 4, pad = 0, align = "center",
      { "text", key = "l", style = "panel/cell", w = 54, h = 20, text = label, textValign = "center" },
      { "slider", key = "s", style = "ctl/track", w = "grow", h = 10, min = lo, max = hi, value = v, interact = true,
        onChanged = function(n)
          local sl = n and n:getcomponent("UiSlider")
          if sl and sl.value then set(key, sl.value, true) end
        end,
        { "box", key = "f", style = "ctl/fill", part = "fill", w = "100%", h = "100%" },
        { "box", key = "h", style = "ctl/handle", part = "handle", w = 8, h = 16 } },
      { "text", key = "v", style = "ctl/value", w = 42, h = 20, textAlign = "end", textValign = "center", text = show(v) } }
  end
  local function pct(x) return string.format("%d%%", math.floor(x * 100 + 0.5)) end
  local function times(x) return string.format("×%.2f", x) end
  out[#out + 1] = sublabel("whd", "WHEEL")
  out[#out + 1] = chips("steer", "Steer")
  out[#out + 1] = slider("steerMax", "Max", 0, 45, function(x) return string.format("%d°", math.floor(x + 0.5)) end)
  out[#out + 1] = chips("drive", "Drive")
  out[#out + 1] = slider("motor", "Motor", 0, 1, pct)
  out[#out + 1] = slider("brake", "Brake", 0, 1, pct)
  out[#out + 1] = slider("spring", "Spring", 0.25, 4, times)
  out[#out + 1] = slider("damper", "Damper", 0.25, 4, times)
  out[#out + 1] = slider("travel", "Travel", 0.03, 0.5, function(x) return string.format("%.2f m", x) end)
  out[#out + 1] = slider("friction", "Grip", 0.5, 2, times)
  out[#out + 1] = { "row", key = "wbtn", w = "100%", h = 22, gap = 3, pad = 0,
    { "button", key = "flip", style = "panel/secondary", w = "grow", h = 22, text = "⇄ Flip", textAlign = "center",
      textValign = "center", tooltip = "Push the other way (drive: invert)",
      onClicked = function() set("drive", c.drive == "invert" and "auto" or "invert") end },
    { "button", key = "ring", style = "panel/secondary", w = "grow", h = 22, text = "To ring", textAlign = "center",
      textValign = "center", disabled = not B.wheelApply, tooltip = "Copy to this wheel's symmetry partners",
      onClicked = function() if B.wheelApply then B.wheelApply(uid, "sym") end end },
    { "button", key = "all", style = "panel/secondary", w = "grow", h = 22, text = "To all", textAlign = "center",
      textValign = "center", disabled = not B.wheelApply, tooltip = "Copy to every wheel",
      onClicked = function() if B.wheelApply then B.wheelApply(uid, "all") end end } }
end

-- ── the part's controls (electronics actions) ───────────────────────────────
-- Shared with the context menu: { { id, label, key } … } for a part record.
function controlsOf(B, rec)
  local E = ref("electronics")
  if not (E and E.actionsOf and rec) then return {} end
  local def = rec.def or {}
  local r = { uid = rec.uid, id = rec.id, label = def.label, kind = def.kind,
              mods = E.deriveMods and E.deriveMods(def, def.mods) or def.mods,
              legs = def.legs and 1 or 0, decouple = def.decouple and 1 or 0, chute = def.chute and 1 or 0,
              rcs = def.rcs and 1 or 0, dock = def.dock and 1 or 0, thrust = def.thrust or 0 }
  local groups = B.groupsNow and B.groupsNow() or nil
  local out = {}
  for _, a in ipairs(E.actionsOf(r)) do
    if a.kind ~= "off" and a.kind ~= "on" then
      local keyname = nil
      if groups and E.groupsOf then
        for _, gid in ipairs(E.groupsOf(groups, rec.uid, a.id) or {}) do
          local k = E.groupKey and E.groupKey(gid)
          if k then keyname = (k == "backspace") and "⌫" or k:upper() break end
        end
      end
      out[#out + 1] = { id = a.id, label = a.label, key = keyname, kind = a.kind }
    end
  end
  return out
end

local function bind(uids, act)
  local bb = ref("builder_bind")
  if bb and bb.begin then bb.begin(uids, act) return true end
  return false
end

local function controls_rows(B, rec, uids, out)
  local acts = controlsOf(B, rec)
  if #acts == 0 then return end
  out[#out + 1] = sublabel("chd", "CONTROLS")
  for i, a in ipairs(acts) do
    if i > 6 then break end
    out[#out + 1] = { "row", key = "a" .. i, w = "100%", h = 22, gap = 4, pad = 0, align = "center",
      { "text", key = "l", style = "panel/cell", w = "grow", h = 22, text = a.label, textValign = "center",
        maxLines = 1, overflow = "ellipsis" },
      { "button", key = "k", style = "panel/choice", selected = a.key ~= nil, w = 34, h = 22, text = a.key or "—",
        textAlign = "center", textValign = "center", tooltip = "Press to bind a key to this",
        onClicked = function() if not bind(uids, a.id) then say(B, "binding arrives with the Controls tab") end end } }
  end
end

-- ── performance: SEA LEVEL and VACUUM ───────────────────────────────────────
-- Rating version 3 gives each engine a nozzle that loses thrust and exhaust
-- velocity in thick air (parts_registry ENGINE NICHES). Every figure that
-- depends on it reads both ways: the craft's at the launch pad's air ("pad"),
-- an engine's at reference sea level ("sea"), and both in vacuum ("vac"). A
-- save rated before nozzles (or a craft with no such engine) shows one figure.
-- `s` is builder.stats(): dv, twr (vacuum), and dv_sl, twr_sl, nozzles.
function pairText(air, vac, fmt, unit, tag)
  unit = unit or ""
  if air == nil or math.abs(air - vac) < 1e-6 then return string.format(fmt, vac) .. unit end
  return string.format(fmt .. " %s · " .. fmt .. " vac", air, tag or "pad", vac) .. unit
end
local function perf_rows(s, out)
  if (s.twr or 0) <= 0 and (s.dv or 0) <= 0 then return end
  local both = s.nozzles and s.twr_sl ~= nil
  out[#out + 1] = figure("ct", "TWR", pairText(both and s.twr_sl or nil, s.twr or 0, "%.2f"))
  out[#out + 1] = figure("cd", "Δv", pairText(both and s.dv_sl or nil, s.dv or 0, "%.0f", " m/s"))
  if both and (s.twr_sl or 0) > 0 and s.twr_sl < 1 and (s.twr or 0) >= 1 then
    out[#out + 1] = { "text", key = "cw", style = "panel/hint", w = "100%", h = "fit", wrap = true,
      text = "Too heavy to lift off in this air — it only flies in vacuum. Put a lifter (Skipper) under it." }
  end
end
-- One engine's own figures as this save builds it (liveDef: vacuum thrust
-- and ve, its sea-level share asl). `def` is the RAW registry entry.
local function engine_rows(B, def, out)
  local d = (B.liveDef and B.liveDef(def)) or def
  if not d.thrust then return end
  local k = d.asl or 1
  out[#out + 1] = figure("et", "THRUST", pairText(d.asl and d.thrust * k or nil, d.thrust, "%.0f", " kN", "sea"))
  if d.ve then out[#out + 1] = figure("ev", "EXHAUST", pairText(d.asl and d.ve * k or nil, d.ve, "%.0f", " m/s", "sea")) end
end

-- ── the control mode (builder.ctrlMode, scripts/craft_mode.lua) ─────────────
-- How the craft drives in flight. AUTO reads the section flown from and says
-- what it made of it; a key wins over Auto. A craft cut into SECTIONS by
-- decouplers or docking ports (a ship carrying a rover) has a mode per
-- section that can be flown: one summary line, then each section's keys,
-- and a click changes only that section. Shown on THIS CRAFT (nothing
-- selected) and at the top of the CRAFT tab.
local CTRL_SHORT = { auto = "Auto", rover = "Rover", aircraft = "Aircraft", rocket = "Rocket" }
local function ctrl_keys(B, out, labels, tips, set, cmd, kp)
  -- two keys a row: four don't fit the plate's width with their names
  local row
  for k, m in ipairs(B.CTRL_MODES or { "auto", "rover", "aircraft", "rocket" }) do
    if k % 2 == 1 then
      row = { "row", key = kp .. "r" .. k, w = "100%", h = 22, gap = 3, pad = 0, align = "center" }
      out[#out + 1] = row
    end
    local on = (m == "auto" and set == nil) or set == m
    row[#row + 1] = { "button", key = m, style = "panel/choice", selected = on, w = "grow", h = 22,
      text = labels[m] or m, textAlign = "center", textValign = "center",
      tooltip = tips[m], onClicked = function() B.cmd("setCtrl", { mode = m, cmd = cmd }) end }
  end
end
local function ctrl_line(labels, set, auto, why)
  if set then
    return string.format("Flies as %s, chosen%s", (labels[set] or set):upper(),
      auto and auto ~= set and string.format(" (Auto would make it %s)", labels[auto] or auto) or "")
  elseif auto then
    return string.format("Auto: %s — %s", (labels[auto] or auto):upper(), why or "")
  end
  return "Auto: reading the craft…"
end
-- ── the launch check (builder.launchCheck) on THIS CRAFT ───────────────────
-- Every warning LAUNCH would ask about, each on its own wrapped line (the
-- hint bar has room for the first two), then the hints LAUNCH doesn't ask
-- about (a twisted symmetry ring).
local function launch_rows(s, out)
  local L = s.launch
  if not L then return end
  local warn, hints = L.warn or {}, L.hints or {}
  if not L.block and #warn == 0 and #hints == 0 then return end
  out[#out + 1] = rule("rl")
  out[#out + 1] = sublabel("lch", "LAUNCH CHECK")
  if L.block then
    out[#out + 1] = { "text", key = "lb", style = "panel/hintWarn", w = "100%", h = "fit", wrap = true, text = "⚠ " .. L.block }
  end
  for i, w in ipairs(warn) do
    out[#out + 1] = { "text", key = "lw" .. i, style = "panel/hintWarn", w = "100%", h = "fit", wrap = true, text = "⚠ " .. w }
  end
  for i, h in ipairs(hints) do
    out[#out + 1] = { "text", key = "lh" .. i, style = "panel/hint", w = "100%", h = "fit", wrap = true, text = "· " .. h }
  end
end

local function ctrl_rows(B, out)
  if not (B.ctrlMode and B.cmd) then return end
  local c = B.ctrlMode() or {}
  local labels, tips = c.labels or CTRL_SHORT, c.tips or {}
  out[#out + 1] = sublabel("cmh", "CONTROL MODE")
  local secs = c.sections or {}
  if #secs > 1 then
    out[#out + 1] = { "text", key = "cms", style = "panel/hint", w = "100%", h = "fit", wrap = true,
      text = c.summary or "" }
    for i, sec in ipairs(secs) do
      out[#out + 1] = sublabel("cmh" .. i, string.upper(sec.name or ("Section " .. i)))
      ctrl_keys(B, out, labels, tips, sec.set, sec.cmd, "cm" .. i)
      out[#out + 1] = { "text", key = "cml" .. i, style = "panel/hint", w = "100%", h = "fit", wrap = true,
        text = ctrl_line(labels, sec.set, sec.auto, sec.why) }
    end
    return
  end
  ctrl_keys(B, out, labels, tips, c.set, nil, "cm")
  out[#out + 1] = { "text", key = "cml", style = "panel/hint", w = "100%", h = "fit", wrap = true,
    text = ctrl_line(labels, c.set, c.auto, c.why) }
end

-- ── ABOUT: what a part is, in words (playtest 2026-11: "clicking a part
-- should inspect it, its description in INSP" — and the one-line role was
-- cut off at the plate's side). A paragraph for the parts that need one, then
-- the part's own numbers read off the registry, in a scroll view of its own
-- (the wheel scrolls it; its clipped edges fade) so a long one never pushes
-- the position fields off the plate. It sits ABOVE the plate's own scroll,
-- not inside it: the engine lets the outermost scroll view clip everything
-- under it, so a scroll nested in one neither clips nor takes the wheel.
ABOUT = {
  pod = "A one-seat capsule: the heart of a first rocket. It commands the craft, carries a battery and a radio home, and its heat shield takes a return from orbit. Hang a parachute on its nose and it lands you.",
  podMk2 = "A three-seat capsule on a 1 m stack. Room for a crew who can repair, plant flags and walk on other worlds. Its own battery and radio; the hatch faces +X.",
  cabin = "Four passenger seats and nothing to fly with: put a pod, a cockpit or a command seat on the same craft. Crew in a cabin are safe from the air and the cold.",
  seat = "An open seat you sit in and drive from, in the open air. It faces +X. It brings no battery and no wheels: a rover needs both.",
  probe = "Flies the craft with nobody aboard, as long as it has power and a radio link home. No life support, no crew.",
  chute = "Opens on its stage (or when you press its key) and slows the landing. Wait until you are slow and low: opened too fast it tears.",
  tankS = "A small fuel tank. Engines under it, or anywhere on the same stage, draw from it. Full it is several times its empty mass.",
  tankM = "The workhorse fuel tank. Stack two under a pod for a first flight; more fuel means more Δv but a heavier lift.",
  engineS = "A light, cheap engine for landers and probes. Fine in air or in vacuum, but weak: it will not lift much off the pad.",
  engineM = "The upper-stage engine: at its best in vacuum, poor at sea level. Put a lifter under it to get off the ground.",
  skipper = "The lifter: huge thrust at sea level, heavy, and so-so in vacuum. The first stage of anything going far.",
  decoupler = "Splits the stack in two when its stage fires: everything below it falls away. The stage list shows what it drops.",
  radialDec = "Holds a side booster or a drop tank on a flank and kicks it away when its stage fires. Ring it with symmetry.",
  legs = "Landing legs: they fold out on the Gear key and take the bump of a landing on rough ground.",
  battery = "Stores power for everything aboard: probe cores, wheels, lights and radios. Charge it with solar panels.",
  solar = "Makes power in sunlight: more nearer the star, none in a planet's shadow. Deploys on its key.",
  roverBody = "A rover's chassis: a probe core, a battery and lights in one box. Its front is +X. Bolt wheels to its sides.",
  wheelS = "A small powered wheel. Steering and drive are set per wheel in INSPECT.",
  wheelM = "A medium powered wheel: the usual rover wheel. Steering, drive and suspension are set per wheel in INSPECT.",
  wheelL = "A big powered wheel for rough ground and heavy loads. It draws the most power.",
  locker = "A box with its own 80 kg and 120 L of storage. Buy kit into it in the CREW tab (medkits, beacons, repair kits): it flies with the craft, and the crew take things out of it from its right-click menu.",
  cargo = "The hold: 250 kg and 1000 L a bay, pooled across every bay aboard. Ore you mine rides home in it, and kit bought in the CREW tab rides out in it.",
  dockPort = "Two ports brought face to face capture and weld two craft into one. Its UNDOCK control splits them again at that seam.",
  rcs = "A four-way thruster block for fine moves when docking. Balance them round the hull; a craft with none cannot translate.",
  fairingS = "A shell that keeps the air off a payload. Press B to draw its shape, or let it fit what is on it. It falls away on its stage.",
  fairingM = "A shell that keeps the air off a payload. Press B to draw its shape, or let it fit what is on it. It falls away on its stage.",
  hub = "A node block with six faces. Optional: beams join flush without one, but a hub gives a clean corner to build out from.",
  hinge = "A servo hinge, ±90°. Bind its two directions to keys in CONTROLS; it holds where it stops.",
  piston = "Extends 0.8 m on its keys and holds where it stops.",
  rotor = "Spins whatever is mounted on it, up to 60 rpm.",
  drill = "Bores into the ground while the craft is landed and fills the hold with what it finds.",
}
local function fmt_m(x) return (x >= 1 or x == 0) and string.format("%.2f m", x) or string.format("%.0f cm", x * 100) end
function aboutText(B, raw, def)
  def = def or raw or {}
  local id = raw and raw.id
  local lines = {}
  local para = (id and ABOUT[id]) or nil
  if para then lines[#lines + 1] = para end
  if def.desc then lines[#lines + 1] = (def.desc:gsub("^%l", string.upper)) end
  local spec = {}
  if def.thrust and def.thrust > 0 then
    local k = def.asl or 1
    spec[#spec + 1] = def.asl and string.format("Thrust %.0f kN at sea level, %.0f kN in vacuum.", def.thrust * k, def.thrust)
      or string.format("Thrust %.0f kN.", def.thrust)
    if def.ve then spec[#spec + 1] = string.format("Exhaust %.0f m/s.", def.ve) end
  end
  if (def.fuel or 0) > 0 then
    local ft = def.fuel_t or (B and B.FUEL_T_PER_UNIT) or 0.01
    spec[#spec + 1] = string.format("Holds %d fuel: %.2f t full, %.2f t empty.", def.fuel, (def.mass or 0) + def.fuel * ft, def.mass or 0)
  end
  local crew = nil
  for _, m in ipairs(def.mods or {}) do
    if (m.type == "command" or m.type == "cabin") and (m.crew or 0) > 0 then crew = m.crew end
  end
  if type(def.seats) == "table" and #def.seats > 0 then crew = #def.seats end
  if crew then spec[#spec + 1] = string.format("Seats %d — assign crew in the CREW tab.", crew) end
  if (def.store or 0) > 0 then spec[#spec + 1] = string.format("Stores %d kg of kit.", def.store) end
  if (def.cargo or 0) > 0 then spec[#spec + 1] = string.format("Carries %d kg of cargo.", def.cargo) end
  if (def.ec or 0) > 0 then spec[#spec + 1] = string.format("Stores %d units of power.", def.ec) end
  if (def.gen or 0) > 0 then spec[#spec + 1] = string.format("Makes %.1f power/s in sunlight.", def.gen) end
  local fit = {}
  if def.top or def.bottom then fit[#fit + 1] = "stacks" end
  if def.side then fit[#fit + 1] = "takes parts on its flanks" end
  if def.radial_orient then fit[#fit + 1] = "mounts on a flank" end
  if #fit > 0 then spec[#spec + 1] = "It " .. table.concat(fit, ", ") .. "." end
  spec[#spec + 1] = string.format("%s tall, %s across.", fmt_m(def.h or 0), fmt_m(2 * (def.rx or 0)))
  if (def.strength or 0) > 0 then spec[#spec + 1] = string.format("Its joints hold %d kN.", def.strength) end
  lines[#lines + 1] = table.concat(spec, " ")
  return table.concat(lines, "\n\n")
end
ABOUT_MAX_H = 112
local function about_rows(B, raw, def, out, top)
  out = top or out
  out[#out + 1] = sublabel("abh", "ABOUT")
  out[#out + 1] = { "scroll", key = "about", name = "InspAbout", w = "100%", h = "fit", maxH = ABOUT_MAX_H,
    dir = "column", gap = 0, pad = 0, align = "stretch", scrollFade = 12, scrollSpeed = 24,
    { "text", key = "t", style = "panel/body", w = "100%", h = "fit", wrap = true, text = aboutText(B, raw, def) } }
end

-- ── INSPECT ─────────────────────────────────────────────────────────────────
-- The part in your hand (fresh from PARTS, nothing selected): what it is.
local function inspect_held(B, id, out, top)
  local raw = B.partInfo and B.partInfo(id)
  if not raw then return false end
  local def = (raw.thrust and B.liveDef and B.liveDef(raw)) or raw
  local r = {}
  for k, v in pairs(raw) do r[k] = v end
  r.id = r.id or id
  top[#top + 1] = { "text", key = "name", style = "panel/title", w = "100%", h = "fit", text = def.label or id,
    maxLines = 2, wrap = true }
  top[#top + 1] = { "text", key = "sub", style = "panel/hint", w = "100%", h = 14, maxLines = 1, overflow = "ellipsis",
    text = "IN HAND  ·  click to place it, ESC puts it back" }
  about_rows(B, r, def, out, top)
  out[#out + 1] = figure("m", "MASS", mass_text((def.mass or 0) + (def.fuel or 0) * (B.FUEL_T_PER_UNIT or 0.01)))
  out[#out + 1] = figure("c", "COST", money(def.cost))
  if raw.thrust then engine_rows(B, raw, out) end
  return true
end

local function inspect(B, out, top)
  top = top or out
  local sel = B.selection and B.selection() or {}
  local held = B.heldId and B.heldId() or nil
  if held and B.holding and B.holding() ~= "part" then held = nil end
  if held and #sel == 0 and inspect_held(B, held, out, top) then return end
  if #sel == 0 then
    out[#out + 1] = { "text", key = "none", style = "panel/body", w = "100%", h = "fit", wrap = true,
      text = "Nothing selected. Click a part to inspect it, or pick one from PARTS to build." }
    local s = B.stats and B.stats() or nil
    if s and (s.parts or 0) > 0 then
      out[#out + 1] = rule("r0")
      out[#out + 1] = sublabel("cr", "THIS CRAFT")
      out[#out + 1] = figure("cp", "PARTS", tostring(s.parts))
      out[#out + 1] = figure("cm", "MASS", mass_text(s.mass or 0))
      out[#out + 1] = figure("cc", "COST", money(s.cost))
      perf_rows(s, out)
      out[#out + 1] = rule("rc")
      ctrl_rows(B, out)
      launch_rows(s, out)
    end
    return
  end
  local uid = (B.selectionPrimary and B.selectionPrimary()) or sel[#sel]
  local rec = B.partRec(uid)
  if not rec then return end
  local raw = rec.def or {}
  local def = raw
  -- an engine's job line is the save's rating version's (liveDef)
  if raw.thrust and B.liveDef then def = B.liveDef(raw) or raw end
  local mass, cost, n = 0, 0, 0
  for _, u in ipairs(sel) do
    local r = (u == uid) and rec or B.partRec(u)
    if r and r.def then
      n = n + 1
      mass = mass + (r.def.mass or 0) + (r.def.fuel or 0) * (B.FUEL_T_PER_UNIT or 0.01)
      cost = cost + (r.def.cost or 0)
    end
  end
  local title = def.label or rec.id
  if n > 1 then title = string.format("%s +%d", title, n - 1) end
  top[#top + 1] = { "text", key = "name", style = "panel/title", w = "100%", h = "fit", text = title,
    maxLines = 2, wrap = true }
  local ring = rec.sym and (rec.mir and "mirror pair" or "symmetry set") or nil
  top[#top + 1] = { "text", key = "sub", style = "panel/hint", w = "100%", h = 14, maxLines = 1, overflow = "ellipsis",
    text = (n > 1 and (n .. " parts selected") or (def.kind or "part"):upper()) .. (ring and ("  ·  " .. ring) or "") }
  out[#out + 1] = figure("m", "MASS", mass_text(mass))
  out[#out + 1] = figure("c", "COST", money(cost))
  if raw.thrust and n == 1 then engine_rows(B, raw, out) end
  if n == 1 then
    local r = {}
    for k, v in pairs(raw) do r[k] = v end
    r.id = rec.id
    about_rows(B, r, def, out, top)
  end
  out[#out + 1] = rule("r1")

  -- Where it is, in metres in the build frame; ENTER moves it there.
  out[#out + 1] = sublabel("phd", "POSITION  m")
  local function mv(axis) return function(x)
    local a = { uid = uid }
    a[axis] = x
    if not B.cmd("move", a) then say(B, "can't move it there") end
  end end
  out[#out + 1] = { "row", key = "pos", w = "100%", h = 24, gap = 4, pad = 0,
    numfield("px", "FieldInsPX", rec.x, "%.3f", mv("x"), "X (m) — ENTER moves it"),
    numfield("py", "FieldInsPY", rec.y, "%.3f", mv("y"), "Y (m), up — ENTER moves it"),
    numfield("pz", "FieldInsPZ", rec.z, "%.3f", mv("z"), "Z (m) — ENTER moves it") }
  -- Its turn, as pitch, yaw and roll in degrees.
  out[#out + 1] = sublabel("rhd", "ROTATION  °")
  local function rt(which) return function(deg)
    local r2 = B.partRec(uid)
    if not r2 then return end
    local e = { pitch = r2.pitch or 0, yaw = r2.yaw or 0, roll = r2.roll or 0 }
    e[which] = math.rad(deg)
    local Q = turnBetween(r2.B or basisOf(r2.yaw, r2.pitch, r2.roll), basisOf(e.yaw, e.pitch, e.roll))
    B.cmd("rotate", { uid = uid, Q = Q })
  end end
  out[#out + 1] = { "row", key = "rot", w = "100%", h = 24, gap = 4, pad = 0,
    numfield("rp", "FieldInsRP", math.deg(rec.pitch or 0), "%.1f", rt("pitch"), "Pitch (°)"),
    numfield("ry", "FieldInsRY", math.deg(rec.yaw or 0), "%.1f", rt("yaw"), "Yaw (°)"),
    numfield("rr", "FieldInsRR", math.deg(rec.roll or 0), "%.1f", rt("roll"), "Roll (°)") }
  out[#out + 1] = { "row", key = "rbtn", w = "100%", h = 22, gap = 3, pad = 0,
    { "button", key = "reset", style = "panel/secondary", w = "grow", h = 22, text = "Reset turn", textAlign = "center",
      textValign = "center", tooltip = "Back to how its mount stands it   ·   SPACE",
      onClicked = function() B.cmd("rotate", { uid = uid, reset = true }) end },
    { "button", key = "frame", style = "panel/secondary", w = "grow", h = 22, text = "Frame  F", textAlign = "center",
      textValign = "center", tooltip = "Frame it in the view",
      onClicked = function() local c = ref("builder_camera"); if c and c.frameSelection then c.frameSelection() end end } }
  if def.wheel then out[#out + 1] = rule("r2"); wheel_rows(B, uid, rec, out) end
  controls_rows(B, rec, sel, out)
end

function role_line(def)
  if def.desc then return def.desc end
  if def.kind then return def.kind end
  return ""
end

-- ── CRAFT ───────────────────────────────────────────────────────────────────
local function craft(B, out)
  local s = B.stats and B.stats() or {}
  ctrl_rows(B, out)
  out[#out + 1] = rule("r0")
  out[#out + 1] = sublabel("bud", "BUDGET")
  out[#out + 1] = figure("bp", "PARTS", string.format("%d%s", s.parts or 0, (s.parts or 0) >= 1000 and "  ⚠ test it" or ""))
  if s.islands then out[#out + 1] = figure("bi", "ISLANDS", tostring(s.islands)) end
  if s.loose and s.loose > 0 then out[#out + 1] = figure("bl", "LOOSE", s.loose .. " parts not attached") end
  local ms = B.frameMs and B.frameMs() or nil
  if ms then out[#out + 1] = figure("bf", "BUILDER", string.format("%.1f ms a frame", ms)) end
  if B.outliner then
    out[#out + 1] = rule("r1")
    out[#out + 1] = sublabel("ghd", "GROUPS")
    local list = B.outliner() or {}
    if #list == 0 then
      out[#out + 1] = { "text", key = "gn", style = "panel/hint", w = "100%", h = "fit", wrap = true,
        text = "Name a selection with CTRL+G to keep it here." }
    end
    for i, g in ipairs(list) do
      if i > 8 then break end
      out[#out + 1] = { "button", key = "g" .. i, style = "panel/row", w = "100%", h = 24, dir = "row", align = "center",
        tooltip = "Select this group", onClicked = function() B.select(g.uids, "set") end,
        { "text", key = "n", style = "panel/cell", w = "grow", h = 18, text = g.name, maxLines = 1, overflow = "ellipsis" },
        { "text", key = "c", style = "panel/cellMuted", w = "fit", h = 18, text = "×" .. #(g.uids or {}) } }
    end
  end
  if B.historyList then
    out[#out + 1] = rule("r2")
    out[#out + 1] = sublabel("hhd", "HISTORY")
    local h = B.historyList() or { items = {}, index = 0 }
    local items, idx = h.items or {}, h.index or #(h.items or {})
    local first = math.max(1, #items - 9)
    for i = #items, first, -1 do
      out[#out + 1] = { "button", key = "h" .. i, style = i == idx and "panel/rowActive" or "panel/row", w = "100%", h = 22,
        text = tostring(items[i]), textValign = "center", opacity = i > idx and 0.55 or 1.0,
        tooltip = "Go back to here", onClicked = function() if B.historyJump then B.historyJump(i) end end }
    end
    if #items == 0 then
      out[#out + 1] = { "text", key = "hn", style = "panel/hint", w = "100%", h = "fit", text = "Nothing done yet." }
    end
  end
end

-- ── STAGE ───────────────────────────────────────────────────────────────────
-- The staging stack as the flight flies it (B.stageView): one card per SPACE,
-- the LAST to fire on top and stage 1 just above LAUNCH — the flight HUD's
-- stack, the same way up. Each card lists its events (a decoupler, a booster
-- ring, a fairing, the chutes): what each one throws off and what it leaves
-- burning. An event is moved by dragging its row onto another stage (or onto
-- NEW STAGE), or with its keys: ▲ fires it a stage later, ▼ a stage sooner,
-- ⇥ gives it a stage of its own. A card's ▲ ▼ move the whole stage. Hovering a
-- row lights its parts in the view; clicking it selects them.
local KIND_TAG = { axial = "STACK", ring = "RADIAL", chute = "CHUTE", fairing = "SHELL", engine = "ENGINE" }
-- An ENGINE row (2026-11-03: engines are stage items, a symmetry group one
-- row with its count): it ignites when its stage fires; on the LAUNCH card it
-- is lit when the clamps let go. Drag it to another stage or onto LAUNCH;
-- SPLIT gives each engine of the group its own row, JOIN puts them back.
local function engine_row(B, e, n, N, move, nItems)
  local key = e.key
  local split = e.grouped and (e.n or 0) > 1
  local join = (not e.grouped) and e.sym ~= nil
  local row = { "button", key = "e" .. key, style = (st.hover == key) and "panel/rowActive" or "panel/row", w = "100%", h = "fit",
    dir = "column", gap = 1, pad = 3, align = "stretch", draggable = true,
    tooltip = "Drag onto another stage, or onto LAUNCH to light it at lift-off · click to select",
    onClicked = function() B.select(e.uids, "set") end,
    onDragStart = function() st.drag = key; st.dragEngine = true end,
    onDragCancel = function() st.drag = nil; st.dragEngine = nil end,
    onHoverStart = function() st.hover = key end,
    onHoverEnd = function() if st.hover == key then st.hover = nil end end,
    { "row", key = "t", w = "100%", h = 18, gap = 3, pad = 0, align = "center",
      { "text", key = "k", style = "panel/keys", w = 50, h = 18, text = "ENGINE", textValign = "center",
        maxLines = 1, overflow = "clip" },
      { "text", key = "n", style = "panel/cell", w = "grow", h = 18, text = e.label, textValign = "center",
        maxLines = 1, overflow = "ellipsis" },
      { "button", key = "u", style = "panel/choice", w = 20, h = 16, text = "▲", textAlign = "center", textValign = "center",
        tooltip = "Ignite it a stage later",
        onClicked = function() move(key, n + 1, n == N) end },
      { "button", key = "d", style = "panel/choice", w = 20, h = 16, text = "▼", textAlign = "center", textValign = "center",
        disabled = n == 0, tooltip = n == 1 and "Light it at launch" or "Ignite it a stage sooner",
        onClicked = function() move(key, n - 1, false) end } },
    { "text", key = "x", style = "panel/cellMuted", w = "100%", h = "fit", wrap = true,
      text = n == 0 and "lit when the clamps let go" or "ignites on this SPACE" } }
  if split or join then
    table.insert(row[2], 4, { "button", key = "sp", style = "panel/choice", w = 36, h = 16, text = split and "SPLIT" or "JOIN",
      textAlign = "center", textValign = "center",
      tooltip = split and "Split the group: each engine its own row, to stage apart"
        or "Join the symmetry group back into one row, in this stage",
      onClicked = function() B.cmd("stage", { op = split and "split" or "join", key = key }) end })
  end
  return row
end
local function stage_rows(B, out)
  local v = B.stageView and B.stageView()
  if not v then return end
  local stages = v.stages or {}
  local N = #stages
  local function move(key, to, new) B.cmd("stage", { op = "item", key = key, to = to, new = new }) end
  out[#out + 1] = { "row", key = "shd", w = "100%", h = 22, gap = 4, pad = 0, align = "center",
    { "text", key = "l", style = "panel/label", w = "grow", h = 22, textValign = "center",
      maxLines = 1, overflow = "ellipsis",
      text = N > 0 and string.format("%d STAGE%s · BOTTOM FIRES FIRST", N, N == 1 and "" or "S") or "STAGES" },
    { "button", key = "rst", style = "panel/secondary", w = 62, h = 20, text = "DEFAULT", textAlign = "center", textValign = "center",
      tooltip = "Put the stages back in the default order: boosters, then decouplers bottom-up, fairings, chutes last",
      onClicked = function() B.cmd("stage", { op = "reset" }) end } }
  if N == 0 then
    out[#out + 1] = { "text", key = "sx", style = "panel/body", w = "100%", h = "fit", wrap = true,
      text = "Nothing to stage yet. Decouplers, radial decouplers, fairings and parachutes each add an event here; engines burn with the stage they sit in." }
  end
  -- NEW STAGE on top: drop an event here to fire it after everything else
  local function newzone(k, to, label)
    return { "box", key = k, style = st.drag and "panel/rowActive" or "panel/row", w = "100%", h = 18, dropTarget = true,
      text = label, textAlign = "center", textValign = "center", opacity = st.drag and 1.0 or 0.55,
      tooltip = "Drop an event here to give it a stage of its own",
      onDropped = function() if st.drag then move(st.drag, to, true) end st.drag, st.dragEngine = nil, nil end }
  end
  if N > 0 then out[#out + 1] = newzone("ntop", N + 1, "+ NEW STAGE (fires last)") end
  -- A STAGE IN YOUR HAND (its card's grip dragged): an orange line between
  -- the cards shows where it will go. Gap k lies between stage k+1 (above)
  -- and stage k (below), read off the pointer against the cards' laid-out
  -- rects (node:uiRect), so anywhere over the stack — a card, the space
  -- between two — is a place to drop it.
  local sd = st.sdrag
  local list = { "col", key = "slist", name = "StageList", w = "100%", h = "fit", gap = 3, pad = 0, align = "stretch",
    dropTarget = sd ~= nil or nil,
    onDragOver = function() stage_over(N) end,
    onDropped = function() if st.sdrag then reorder_drop(B, gap_at_mouse(N)) end end }
  local function target_of(k)                  -- the stage's new index for gap k
    if not sd then return nil end
    if k == sd or k == sd - 1 then return nil end
    return (sd <= k) and k or (k + 1)
  end
  local function gap(k)
    local t = target_of(k)
    local lit = t ~= nil and st.gap == k
    return { "box", key = "g" .. k, name = "StageGap" .. k, style = lit and "ctl/fill" or nil, w = "100%",
      h = lit and 3 or 0 }
  end
  for n = N, 1, -1 do
    local sg = stages[n]
    list[#list + 1] = gap(n)
    local lifted = sd == n
    local card = { "col", key = "s" .. n, name = "StageCard" .. n, style = lifted and "panel/rowActive" or "panel/row",
      w = "100%", h = "fit", gap = 2, pad = 4, align = "stretch", opacity = lifted and 0.6 or nil,
      dropTarget = true,
      onDragOver = function() stage_over(N) end,
      onDropped = function()
        if st.sdrag then reorder_drop(B, gap_at_mouse(N)) return end
        if st.drag then move(st.drag, n, false) end st.drag, st.dragEngine = nil, nil
      end,
      onHoverStart = function() st.hover = "s" .. n end,
      onHoverEnd = function() if st.hover == "s" .. n then st.hover = nil end end }
    -- the grip: three ridges across the card's top, a raised key you pick
    -- the whole stage up by
    card[#card + 1] = { "button", key = "grip", name = "StageGrip" .. n, style = "panel/choice", w = "100%", h = 12,
      dir = "column", justify = "center", align = "center", gap = 2, pad = 0, draggable = true, selected = lifted or nil,
      tooltip = "Drag to move this whole stage up or down the stack",
      onDragStart = function() st.sdrag, st.gap = n, nil; st.sig = nil end,
      onDragCancel = function() st.sdrag, st.gap = nil, nil; st.sig = nil end,
      { "box", key = "r1", style = "panel/rule", w = 28, h = 1 },
      { "box", key = "r2", style = "panel/rule", w = 28, h = 1 } }
    card[#card + 1] = { "row", key = "h", w = "100%", h = 20, gap = 3, pad = 0, align = "center",
      { "text", key = "n", style = "panel/cellStrong", w = "grow", h = 20, textValign = "center",
        text = string.format("STAGE %d%s", n, n == 1 and "  ·  next SPACE" or "") },
      { "button", key = "up", style = "panel/choice", w = 22, h = 18, text = "▲", textAlign = "center", textValign = "center",
        disabled = n == N, tooltip = "Fire this whole stage later",
        onClicked = function() B.cmd("stage", { op = "swap", i = n, j = n + 1 }) end },
      { "button", key = "dn", style = "panel/choice", w = 22, h = 18, text = "▼", textAlign = "center", textValign = "center",
        disabled = n == 1, tooltip = "Fire this whole stage sooner",
        onClicked = function() B.cmd("stage", { op = "swap", i = n, j = n - 1 }) end } }
    for i, e in ipairs(sg.items or {}) do
      if e.kind == "engine" then
        card[#card + 1] = engine_row(B, e, n, N, move, #sg.items)
      else
        local detail = {}
        if e.drops then detail[#detail + 1] = "drops " .. e.drops end
        if e.lights then detail[#detail + 1] = "then burns " .. e.lights end
        if e.kind == "chute" then detail[#detail + 1] = "open on this SPACE" end
        if e.kind == "fairing" then detail[#detail + 1] = "the shell falls away" end
        local key = e.key
        local row = { "button", key = "e" .. key, style = (st.hover == key) and "panel/rowActive" or "panel/row", w = "100%", h = "fit",
          dir = "column", gap = 1, pad = 3, align = "stretch", draggable = true,
          tooltip = "Drag onto another stage · click to select its parts",
          onClicked = function() B.select(e.uids, "set") end,
          onDragStart = function() st.drag = key; st.dragEngine = nil end,
          onDragCancel = function() st.drag = nil end,
          onHoverStart = function() st.hover = key end,
          onHoverEnd = function() if st.hover == key then st.hover = nil end end,
          { "row", key = "t", w = "100%", h = 18, gap = 3, pad = 0, align = "center",
            { "text", key = "k", style = "panel/keys", w = 50, h = 18, text = KIND_TAG[e.kind] or "EVENT", textValign = "center",
              maxLines = 1, overflow = "clip" },
            { "text", key = "n", style = "panel/cell", w = "grow", h = 18, text = e.label, textValign = "center",
              maxLines = 1, overflow = "ellipsis" },
            { "button", key = "u", style = "panel/choice", w = 20, h = 16, text = "▲", textAlign = "center", textValign = "center",
              tooltip = "Fire it a stage later", onClicked = function() move(key, n + 1, n == N) end },
            { "button", key = "d", style = "panel/choice", w = 20, h = 16, text = "▼", textAlign = "center", textValign = "center",
              tooltip = "Fire it a stage sooner", onClicked = function() if n == 1 then move(key, 1, true) else move(key, n - 1, false) end end },
            { "button", key = "o", style = "panel/choice", w = 20, h = 16, text = "⇥", textAlign = "center", textValign = "center",
              disabled = #sg.items < 2, tooltip = "Give it a stage of its own, right after this one",
              onClicked = function() move(key, n + 1, true) end } } }
        if #detail > 0 then
          row[#row + 1] = { "text", key = "x", style = "panel/cellMuted", w = "100%", h = "fit", wrap = true,
            text = table.concat(detail, " · ") }
        end
        card[#card + 1] = row
      end
    end
    list[#list + 1] = card
  end
  if N > 0 then list[#list + 1] = gap(0); out[#out + 1] = list end
  if N > 0 then out[#out + 1] = newzone("nbot", 1, "+ NEW STAGE (fires first)") end
  local L = v.launch or {}
  local lcard = { "col", key = "launch", name = "StageLaunch", style = (st.drag and st.dragEngine) and "panel/rowActive" or "panel/row",
    w = "100%", h = "fit", gap = 2, pad = 4, align = "stretch",
    dropTarget = true,
    onDropped = function()
      if st.drag and st.dragEngine then move(st.drag, 0, false) end
      st.drag, st.dragEngine = nil, nil
    end,
    onHoverStart = function() st.hover = "s0" end,
    onHoverEnd = function() if st.hover == "s0" then st.hover = nil end end,
    { "text", key = "n", style = "panel/cellStrong", w = "100%", h = 18, text = "LAUNCH  ·  SPACE releases the clamps", textValign = "center" } }
  for _, e in ipairs(L.items or {}) do lcard[#lcard + 1] = engine_row(B, e, 0, N, move, #L.items) end
  if #(L.items or {}) == 0 then
    lcard[#lcard + 1] = { "text", key = "x", style = "panel/cellMuted", w = "100%", h = "fit", wrap = true,
      text = "no engine lit at lift-off — drag an engine here" }
  end
  out[#out + 1] = lcard
end

-- The gap under the pointer: above the first card (top down) whose middle
-- the pointer is above, else 0 (below stage 1). uiRect and input.mouse are
-- both window pixels.
function gap_at_mouse(N)
  local _, my = input.mouse()
  for n = N, 1, -1 do
    local c = find and find("StageCard" .. n)
    local x, y, w, h
    if c and c.uiRect then x, y, w, h = c:uiRect() end
    if y and h and my < y + h * 0.5 then return n end
  end
  return 0
end
function stage_over(N)
  if not st.sdrag then return end
  local k = gap_at_mouse(N)
  if k == st.sdrag or k == st.sdrag - 1 then k = nil end
  if k ~= st.gap then st.gap = k; st.sig = nil end
end
-- A dragged stage let go over gap k: one undo step, the stack closes up.
function reorder_drop(B, k)
  local sd = st.sdrag
  st.sdrag, st.gap, st.sig = nil, nil, nil
  if not (sd and k) then return false end
  local j
  if k == sd or k == sd - 1 then return false end
  j = (sd <= k) and k or (k + 1)
  if B.cmd then B.cmd("stage", { op = "reorder", i = sd, j = j }) end
  local sfx = ref("sfx")
  if sfx and sfx.play then pcall(sfx.play, "click") end
  return true
end

-- ── THE CARD IN YOUR HAND ───────────────────────────────────────────────────
-- The engine moves nothing while a UI drag is on (docs/ui-navigation.md), so
-- the plate draws what you carry: a small card riding the pointer — a crew
-- member's face and name, a kit item, a stage. Made once a drag, then kept on
-- the pointer by ui.bind (no re-describe a frame).
local GHOST_NAME = "InspDragGhost"
local function ghost_spec(B)
  local g
  if st.sdrag then
    g = { name = "STAGE " .. st.sdrag, sub = "drop between stages" }
  else
    local bc = ref("builder_crew")
    g = bc and bc.dragGhost and bc.dragGhost() or nil
  end
  if not g then return nil end
  local kids = { "row", key = "ghost", name = GHOST_NAME, style = "panel/rowActive", pin = "topLeft", x = 0, y = 0,
    w = "fit", h = "fit", gap = 6, pad = 5, align = "center", opacity = 0.92 }
  if g.kind == "member" then
    kids[#kids + 1] = g.tex and { "image", key = "f", texture = g.tex, w = 36, h = 36 }
      or { "box", key = "f", style = "menu/slot", w = 36, h = 36, text = g.initials, textAlign = "center", textValign = "center" }
  end
  kids[#kids + 1] = { "col", key = "t", w = "fit", h = "fit", gap = 0, pad = 0,
    { "text", key = "n", style = "panel/cellStrong", w = "fit", h = 16, text = g.name, textValign = "center" },
    { "text", key = "s", style = "panel/cellMuted", w = "fit", h = 14, text = g.sub or "", textValign = "center" } }
  return kids, g
end

-- ── the plate ───────────────────────────────────────────────────────────────
function describe(B, L)
  local r = L.right
  local tabs = { "row", key = "tabs", w = "100%", h = 24, gap = 3, pad = 0 }
  for _, t in ipairs(TABS) do
    tabs[#tabs + 1] = { "button", key = "t" .. t, style = "panel/choice", selected = st.tab == t, w = "grow", h = 24,
      text = t == "CONTROLS" and "CTRLS" or (t == "INSPECT" and "INSP" or t), textAlign = "center", textValign = "center",
      tooltip = t:sub(1, 1) .. t:sub(2):lower() .. "   ·   TAB", onClicked = function() setTab(t) end }
  end
  local body, top = {}, {}
  if st.tab == "INSPECT" then inspect(B, body, top)
  elseif st.tab == "CRAFT" then craft(B, body)
  elseif st.tab == "CREW" then
    local bc = ref("builder_crew")
    if bc and bc.describe then
      local ok, err = pcall(bc.describe, B, body)
      if not ok then body[#body + 1] = { "text", key = "cerr", style = "panel/hintWarn", w = "100%", h = "fit", wrap = true,
        text = "The crew tab could not be drawn: " .. (tostring(err):gsub("^.-:%d+:%s*", "")) } end
    else
      body[1] = { "text", key = "cx", style = "panel/body", w = "100%", h = "fit", wrap = true,
        text = "No crew office in this building." }
    end
  elseif st.tab == "STAGE" then
    stage_rows(B, body)
  else
    body[1] = { "text", key = "cx", style = "panel/body", w = "100%", h = "fit", wrap = true,
      text = "Keys and what they run. Select a part and press B to bind one." }
  end
  -- STAGE and CONTROLS hand the plate's body to the builder's and WP5's
  -- panels: the plate shrinks to its tabs and a line about them.
  local short = st.tab == "CONTROLS"
  local plate = { "col", key = "plate", style = "panel/frame", pin = "topLeft", x = r.x, y = r.y, w = r.w,
    h = short and "fit" or r.h, gap = 6, pad = 10, align = "stretch", tabs }
  for _, e in ipairs(top) do plate[#plate + 1] = e end
  plate[#plate + 1] = { "scroll", key = "body", name = "InspBody", w = "100%", h = short and "fit" or "grow", dir = "column",
    gap = 5, pad = 0, align = "stretch", scrollFade = 14, items = body, function(x) return x end }
  return plate
end

-- The plate's body rectangle (design units), for panels that draw in it.
function rightPlate()
  local L = st.L
  return L and L.right or nil
end

-- ── panel plumbing ──────────────────────────────────────────────────────────
local function mouse_du(H)
  if not (camera and camera.screenSize) then return nil end
  local sw, sh = camera.screenSize()
  if not (sh and sh > 0) then return nil end
  local mx, my = input.mouse()
  local ox, oy = 0, 0
  if camera.screenRect then ox, oy = camera.screenRect() end
  return (mx - (ox or 0)) * H / sh, (my - (oy or 0)) * H / sh
end
function ownsMouse()
  local L = st.L
  if not L then return false end
  local x, y = mouse_du(L.H)
  local r = L.right
  local h = (st.tab == "CONTROLS") and 80 or r.h
  return x ~= nil and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + h
end
function ownsKeys()
  local n = focused_name()
  return n ~= nil and n:find("^FieldIns") ~= nil
end

local el, registered = nil, false
function start(node) el = node.getcomponent and node:getcomponent("UiElement") or nil end

function update(node, dt)
  local B = ref("builder")
  if not (B and B.selection and B.partRec) then return end
  if not registered and B.registerPanel then registered = B.registerPanel(findScript("builder_inspector")) end
  if not el then el = node:getcomponent("UiElement") end
  local tb = ref("builder_toolbar")
  local W, H = 1280, 720
  if tb and tb.layerSize then W, H = tb.layerSize() end
  if tb and tb.fitHost then tb.fitHost(el, W, H) end
  st.L = layout(W, H)
  -- The builder's own tool keys can change the tab (3 used to be STAGE).
  local tool = B.tool and B.tool() or nil
  if tool == "stage" and st.tab ~= "STAGE" then st.tab = "STAGE"
  elseif tool == "groups" and st.tab ~= "CONTROLS" then st.tab = "CONTROLS"
  elseif (st.tab == "STAGE" and tool ~= "stage") or (st.tab == "CONTROLS" and tool ~= "groups") then
    if tool then st.tab = "INSPECT" end
  end
  st.t = st.t + (dt or 0)
  -- A PART CLICKED IN THE VIEW, or picked from PARTS, is a part to inspect:
  -- from CRAFT or CREW the plate turns to INSPECT (STAGE and CONTROLS keep
  -- theirs: a click there stages or binds the part).
  local clicks = B.partClicks or 0
  local held = B.heldId and B.heldId() or nil
  if st.clicks == nil then st.clicks, st.held = clicks, held end
  if (clicks ~= st.clicks or (held and held ~= st.held)) and (st.tab == "CRAFT" or st.tab == "CREW") then
    setTab("INSPECT")
  end
  st.clicks, st.held = clicks, held
  -- the STAGE tab's hovered row lights its parts in the view (for as long as it is hovered)
  if st.tab == "STAGE" and st.hover and B.stageHover then B.stageHover(st.hover) end
  -- a drag let go over nothing (or outside the plate): the stage goes back
  if st.sdrag and ui and ui.dragging and not ui.dragging() then st.sdrag, st.gap, st.sig = nil, nil, nil end
  local sel = B.selection()
  local bc = ref("builder_crew")
  if bc and bc.state and ui and ui.dragging and not ui.dragging() then
    local cs = bc.state()
    if cs and cs.drag then cs.drag, cs.over = nil, nil; if bc.touch then bc.touch() end end
  end
  local _, g = ghost_spec(B)
  local sig = table.concat({ math.floor(W), math.floor(H), st.tab, tostring(B.craftVersion), table.concat(sel, ","),
    tostring(focused_name()), tostring(st.hover), tostring(st.drag), tostring(st.sdrag), tostring(st.gap),
    tostring(held), g and (g.name .. tostring(g.tex)) or "",
    st.tab == "CREW" and tostring(bc and bc.sig and bc.sig()) or "" }, "|")
  if sig == st.sig and st.t < 1.0 then return end
  st.sig, st.t = sig, 0
  local tree = { describe(B, st.L) }
  local gt = ghost_spec(B)
  if gt then tree[#tree + 1] = gt end
  ui.make(node, tree)
  if gt then
    local gn = find and find(GHOST_NAME)
    if gn and ui.bind then
      local Hh = st.L and st.L.H or H
      local function at(i)
        return function()
          local x, y = mouse_du(Hh)
          if not x then return 0 end
          -- beside the pointer, toward the middle of the screen (a card
          -- carried on the right plate rides to its left, never off the edge)
          if i == 1 then return (x > (st.L and st.L.W or 1280) * 0.5) and (x - 172) or (x + 14) end
          return y - 10
        end
      end
      ui.bind(gn, "posX", at(1))
      ui.bind(gn, "posY", at(2))
    end
  end
end
function ghostUp() return find and find(GHOST_NAME) ~= nil end   -- probes
