-- FLIGHT HUD — the cockpit, drawn as instruments rather than as a text dump.
--
-- The flight readout used to be one 600-wide block of wrapped text: ASCII
-- gauges ("THR [|||·······]"), every number, the warp limit, the contract, a
-- key legend and the next thing to press, all in one size and one colour. Ty:
-- "the ui is all honestly ugly and does not resemble ship controls". This is
-- the panel it was standing in for:
--
--   top centre     the ORBIT STRIP (body, apoapsis, periapsis, period, orbital
--                  and escape speed) and under it a fixed row of ANNUNCIATORS
--                  that are dark until something is true
--   top right      FUEL and CHARGE as real bars, under the ☰ button
--   bottom centre  the CONSOLE: throttle, the autopilot holds, the speed tape,
--                  the navball in its bezel, the altitude tape, vertical speed
--                  and the thrust figures, on one plate, with time warp on its
--                  top edge
--   bottom right   the STAGE STACK: one card per SPACE, the next one lit
--
-- The contract lives on the objectives card and the way to end a flight on the
-- flight ops card, so neither is repeated here; every key is on the pause
-- menu's controls page and in each control's tooltip.
--
-- vessel_controller MEASURES (its `tele` table, 10 Hz, plus the globals it
-- already published) and this script DRAWS. The split is load-bearing: the
-- controller's fixedUpdate sits at LuaJIT's 60-upvalue ceiling, so nothing
-- that only exists to be looked at belongs in it.
--
-- The navball, the two tapes and their value windows are scene nodes the
-- controller drives through setShaderParam; this script only places them on
-- the console. They keep their names, because the orbit map hides and shows
-- them by name. This node draws UNDER them (`order: -1` in the scene) and its
-- overlay sibling draws over them (the tooltip).
--
--   Published:  layout   where the console and the corner blocks are, in
--                        design units, for status_hud to stack cards around

defaults = {
  --@header HUD
  --@range 0 1
  enabled = 1,
  --- Most times a second the HUD is re-described in flight (0 = every frame).
  --- ui.make keeps what it built, so between rebuilds the HUD stays as it
  --- was; re-describing it every frame cost 2.4 ms a frame while flying.
  rate = 30,
}

local made_t, made_v = -1, nil

layout = nil
warning = nil     -- the LEAVING banner's description while it's up (leaveWarning)

-- ── geometry (design units: the layer is 720 tall) ──────────────────────────
local M = 16                          -- screen margin
local CW, CH, CB = 612, 172, 12       -- console plate: width, height, lift
local LAMP_W, LAMP_H, LAMP_GAP = 52, 18, 4
local STRIP_W, STRIP_H = 12 * LAMP_W + 11 * LAMP_GAP, 40   -- as wide as the lamp row
local RES_W = 232                     -- fuel / charge block
local STAGE_W = 168                   -- stage stack

-- Where each piece sits on the console plate: x, y, w, h from its top-left.
-- The ball rides high, so its bezel and the heading box stand proud of the top
-- edge — the one shape on the panel that tells you what it is from across the
-- room.
local P = {
  thr     = { 24, 30, 16, 108 },
  sas     = { 62, 10, 72 },
  spd     = { 176, 30, 46, 126 },
  spdWin  = { 170, 81, 58, 24 },
  bezel   = { 212, -22, 188, 188 },
  ball    = { 220, -14, 172, 172 },
  hdgWin  = { 275, -32, 62, 20 },
  alt     = { 412, 30, 46, 126 },
  altWin  = { 406, 81, 58, 24 },
  vs      = { 505, 30, 14, 108 },
}

-- The autopilot, as a 2 × 5 grid of holds in the navball's own symbols, the
-- way KSP pairs them. `key` is the chord that selects it (ALT + the number in
-- vessel_controller's SAS_KEYS — the bare numbers are the action groups); the
-- last cell is the RCS bus.
local HOLDS = {
  { mode = "stability",  glyph = "◎", name = "Stability — hold this attitude", key = "ALT+1" },
  { mode = "node",       glyph = "◆", name = "Maneuver — point down the planned burn", key = "ALT+9" },
  { mode = "prograde",   glyph = "⊕", name = "Prograde — along the direction of travel", key = "ALT+2" },
  { mode = "retrograde", glyph = "⊗", name = "Retrograde — against it (slow down)", key = "ALT+3" },
  { mode = "normal",     glyph = "△", name = "Normal — up out of the orbit plane", key = "ALT+4" },
  { mode = "antinormal", glyph = "▽", name = "Anti-normal — down out of the orbit plane", key = "ALT+5" },
  { mode = "radialout",  glyph = "⇡", name = "Radial out — away from the planet", key = "ALT+7" },
  { mode = "radialin",   glyph = "⇣", name = "Radial in — toward the planet", key = "ALT+6" },
  { mode = "dock",       glyph = "⊡", name = "Dock align — square up to the target port", key = "ALT+8" },
  { rcs = true },
}

local WARP_STEPS = { 1, 5, 10, 50, 100, 1000, 10000 }

-- Colours the styles can't carry, because they depend on the value. They are
-- the tokens' (ui/solar.tokens.ron): a meter is a phosphor bar on the CRT, the
-- accent is signal orange, and the state colours are caution yellow and red.
local ACCENT = { 0.97, 0.55, 0.22 }
local PHOS = { 0.55, 0.86, 0.48 }
local WARN = { 1.0, 0.80, 0.28 }
local DANGER = { 0.97, 0.34, 0.25 }
local NEUTRAL = { 0.64, 0.93, 0.56 }
local DIM = { 0.56, 0.55, 0.50 }

-- ── plumbing ────────────────────────────────────────────────────────────────

local el, overlay, overlay_el
local tip_made = false
local sas_prev = "stability"   -- the hold the SAS button turns back on

-- Cross-script singletons, resolved once (floptle/0063: findScript walks the
-- scene). Vessels are NOT cached: craft spawn and despawn at runtime.
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

local function flown()
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.piloting then return v end
  end
  return nil
end

local nodes = {}
local function comp(name)
  local n = nodes[name]
  if n == nil or (n and n.valid == false) then
    n = find(name) or false
    nodes[name] = n
  end
  return n and n:getcomponent("UiElement") or nil
end

local function set(e, k, v)
  if e and math.abs((e[k] or -1e9) - v) > 0.25 then e[k] = v end
end

local function design_width()
  if camera and camera.screenSize then
    local w, h = camera.screenSize()
    if w and h and h > 0 then return 720 * w / h end
  end
  return 1280
end

-- ── formatting ──────────────────────────────────────────────────────────────

-- Whole numbers that don't print as "-0" when they wobble either side of zero.
local function whole(x) return math.abs(x) < 0.5 and 0 or x end

local function dist(m)
  if not m then return "—" end
  m = whole(m)
  local a = math.abs(m)
  if a < 10000 then return string.format("%.0f m", m) end
  if a < 1e7 then return string.format("%.1f km", m / 1000) end
  return string.format("%.0f km", m / 1000)
end

local function duration(s)
  if not s or s ~= s or s == math.huge then return "—" end
  if s < 60 then return string.format("%.0f s", s) end
  if s < 3600 then return string.format("%dm %02ds", math.floor(s / 60), math.floor(s % 60)) end
  return string.format("%dh %02dm", math.floor(s / 3600), math.floor(s / 60) % 60)
end

-- A tape's scale number: short enough to fit beside the ticks.
local function tick_label(v)
  v = whole(v)   -- a tape's zero tick is computed as ceil(-x)·major: "-0"
  if math.abs(v) >= 10000 then return string.format("%.1fk", v / 1000) end
  return string.format("%.0f", v)
end

local function pct(x) return math.floor(math.max(0, math.min(1, x)) * 100 + 0.5) end

-- ── live values (every frame: the tapes scroll, so their numbers must too) ──

local function live(v)
  local n = v.node
  if not (n and n.valid) then return nil end
  local d = space.dominant(n.x, n.y, n.z)
  local b = d and space.body(d)
  if not b then return nil end
  local rx, ry, rz = n.x - b.x, n.y - b.y, n.z - b.z
  local r = math.sqrt(rx * rx + ry * ry + rz * rz)
  if r < 1e-3 then return nil end
  return {
    alt = r - b.radius,
    spd = math.sqrt(n.vx ^ 2 + n.vy ^ 2 + n.vz ^ 2),
    vspd = (n.vx * rx + n.vy * ry + n.vz * rz) / r,
  }
end

-- ── pieces ──────────────────────────────────────────────────────────────────

local function micro(key, text, x, y, w, align)
  return { "text", key = key, style = "hud/micro", x = x, y = y, w = w, h = 12,
           text = text, textAlign = align or "center" }
end

-- A number. `tone` picks its colour through a style ("accent", "warn",
-- "danger"): a style's colour wins over an element's own, so a plain
-- `textColor` here would be painted over.
local TONE = { accent = "hud/valueAccent", warn = "hud/valueWarn", danger = "hud/valueDanger",
               dim = "hud/valueDim" }
local function value(key, text, x, y, w, align, tone)
  return { "text", key = key, style = TONE[tone] or "hud/value", x = x, y = y, w = w, h = 16,
           text = text, textAlign = align or "center" }
end

-- A vertical meter: a channel with a fill rising from the bottom (or, for a
-- centred one, from the middle).
local function vmeter(key, r, frac, color, centred)
  local x, y, w, h = r[1], r[2], r[3], r[4]
  local fill
  if centred then
    local half = h / 2
    local len = math.floor(math.abs(frac) * (half - 1) + 0.5)
    local top = frac >= 0 and (half - len) or half
    fill = { "box", key = "f", x = 2, y = top, w = w - 4, h = math.max(0, len),
             radius = 1, fill = color }
  else
    local len = math.floor(math.max(0, math.min(1, frac)) * (h - 4) + 0.5)
    fill = { "box", key = "f", x = 2, y = h - 2 - len, w = w - 4, h = len, radius = 1, fill = color }
  end
  local kids = { fill }
  if centred then
    kids[#kids + 1] = { "box", key = "z", x = -3, y = h / 2 - 0.5, w = w + 6, h = 1,
                        fill = { NEUTRAL[1], NEUTRAL[2], NEUTRAL[3], 0.5 } }
  end
  return { "box", key = key, style = "hud/track", x = x, y = y, w = w, h = h,
           items = kids, function(k) return k end }
end

-- The scale numbers down a tape's outer side, at the same majors its shader
-- draws: `span` is the half-window shown, `major` the labelled spacing.
local function tape_scale(key, r, val, span, major, left)
  local x, y, h = r[1], r[2], r[4]
  local labels = {}
  local lo = math.ceil((val - span) / major) * major
  for m = lo, val + span, major do
    local cy = y + (1 - (m - val) / span) * h / 2
    -- The window covers the middle, and the tape stops at zero.
    if m >= 0 and cy > y + 4 and cy < y + h - 4 and math.abs(cy - (y + h / 2)) > 14 then
      labels[#labels + 1] = { "text", key = key .. m, style = "hud/valueMuted",
        x = left and (x - 32) or (x + r[3] + 4), y = cy - 6, w = 28, h = 12,
        text = tick_label(m), textAlign = left and "end" or "start" }
    end
  end
  return labels
end

-- The autopilot grid.
local function sas_block(v, t)
  local on = v.sas_mode and v.sas_mode ~= "off"
  local x0, y0 = P.sas[1], P.sas[2]
  local kids = {
    { "button", key = "sas", style = "hud/sasWord", x = x0, y = y0, w = P.sas[3], h = 18,
      text = "SAS", textAlign = "center", textValign = "center", selected = on, focusable = false,
      tooltip = on and "Autopilot on — click or T to let go" or "Autopilot off — click or T to hold",
      onClicked = function()
        if v.setSAS then v.setSAS(on and "off" or sas_prev) end
      end },
  }
  for i, h in ipairs(HOLDS) do
    local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
    local x, y = x0 + col * 38, y0 + 24 + row * 26
    if h.rcs then
      local has = t.has_rcs
      kids[#kids + 1] = { "button", key = "rcs", style = "hud/sasWord", x = x, y = y, w = 34, h = 22,
        text = "RCS", textAlign = "center", textValign = "center",
        selected = has and t.rcs_on or false, disabled = not has, focusable = false,
        tooltip = has and string.format("RCS thrusters (×%d) — R", t.rcs_blocks)
          or "No RCS blocks on this craft",
        onClicked = function()
          if has and v.setPeripheral then v.setPeripheral("rcs") end
        end }
    else
      kids[#kids + 1] = { "button", key = h.mode, style = "hud/sas", x = x, y = y, w = 34, h = 22,
        text = h.glyph, textAlign = "center", textValign = "center", focusable = false,
        selected = v.sas_mode == h.mode,
        tooltip = h.name .. "   [" .. h.key .. "]",
        onClicked = function()
          if not v.setSAS then return end
          -- The lit hold is the off switch too: the grid never needs an OFF cell.
          if v.sas_mode == h.mode then v.setSAS("off") else v.setSAS(h.mode) end
        end }
    end
  end
  return kids
end

-- The warp pill on the console's top edge: one chevron per step of the ladder,
-- lit up to where you are, and the rate. Why it will go no higher is the
-- tooltip — a limit the pilot can't see reads as a broken key.
local function warp_pill(t)
  local w = t.warp or 1
  local idx = 1
  for i, s in ipairs(WARP_STEPS) do if w >= s - 0.5 then idx = i end end
  local kids = {}
  for i = 2, #WARP_STEPS do
    local capped = WARP_STEPS[i] > (t.warp_cap or math.huge) + 0.001
    kids[#kids + 1] = { "text", key = "c" .. i, w = 8, h = 14, text = "▸", textSize = 14,
      textAlign = "center", textValign = "center",
      textColor = i <= idx and ACCENT or (capped and { DIM[1], DIM[2], DIM[3], 0.18 }
        or { DIM[1], DIM[2], DIM[3], 0.55 }) }
  end
  kids[#kids + 1] = { "text", key = "x", style = w > 1.001 and "hud/valueAccent" or "hud/value",
    w = 52, h = 14, text = string.format("×%d", math.floor(w + 0.5)), textAlign = "end",
    textValign = "center" }
  local tip = "Time warp — . faster, , slower (coasting only; any input drops to ×1)"
  if t.warp_cap and t.warp_cap < math.huge then
    tip = tip .. string.format("\nLimited to ×%d%s", math.floor(t.warp_cap),
      t.warp_why and (": " .. t.warp_why) or "")
  end
  return { "row", key = "warp", style = "hud/warp", x = 12, y = -11, w = "fit", h = 22,
           pad = 0, gap = 1, align = "center", button = true, tooltip = tip,
           { "box", key = "l", w = 6, h = 1 },
           { "text", key = "lbl", style = "hud/micro", w = 36, h = 12, text = "WARP",
             textAlign = "start" },
           { "row", key = "ch", w = "fit", h = 14, pad = 0, gap = 0,
             items = kids, function(k) return k end },
           { "box", key = "r", w = 8, h = 1 } }
end

local function console(v, t, lv, shift)
  local thr = v.throttle or 0
  local kids = {
    -- Throttle.
    micro("thrL", "THR", 12, 12, 40),
    vmeter("thr", P.thr, thr, PHOS),
    value("thrV", string.format("%d%%", pct(thr)), 8, 144, 48),
    -- Speed / altitude captions (the tapes and their windows are scene nodes).
    micro("spdL", "SPEED", 160, 12, 78),
    micro("altL", "ALTITUDE", 396, 12, 78),
    -- The ball's rim.
    { "box", key = "bezel", style = "hud/bezel", x = P.bezel[1], y = P.bezel[2],
      w = P.bezel[3], h = P.bezel[4] },
  }
  for _, k in ipairs(sas_block(v, t)) do kids[#kids + 1] = k end
  if lv then
    -- The tapes' windows follow the world's scale (system_generator SCALES):
    -- the same spans vessel_controller hands the tape shader.
    local sk, ak = 1.0, 1.0
    if v.worldScaleK then sk, ak = v.worldScaleK() end
    local sspan = sk > 1.2 and 60 or 40
    local aspan, amaj = 150, 125
    if ak > 1.5 then aspan, amaj = 300, 250 end
    for _, k in ipairs(tape_scale("s", P.spd, lv.spd, sspan, 25, true)) do kids[#kids + 1] = k end
    for _, k in ipairs(tape_scale("a", P.alt, lv.alt, aspan, amaj, false)) do kids[#kids + 1] = k end
  end

  -- Vertical speed: a centred meter on a log scale (1, 10, 100 m/s all read),
  -- amber when you are coming down fast close to the ground.
  local vs = lv and lv.vspd or 0
  local vfrac = math.min(1, math.log10(1 + math.abs(vs)) / math.log10(301)) * (vs < 0 and -1 or 1)
  local hot = lv and vs < -8 and lv.alt < 400
  kids[#kids + 1] = micro("vsL", "V/S", 490, 12, 44)
  kids[#kids + 1] = vmeter("vs", P.vs, vfrac, hot and WARN or (vs >= 0 and PHOS or { 0.38, 0.56, 0.34 }), true)
  kids[#kids + 1] = value("vsV", string.format("%+.0f", whole(vs)), 486, 144, 52, "center",
    hot and "warn" or nil)

  -- Thrust figures, right column: what the stack can do and where it points.
  -- These are what the engines are DOING: 0 on the clamps, at idle and with
  -- dry tanks. The HUD used to print the stack's full-throttle figures at all
  -- times ("TWR 1.38 / THRUST 55 kN" at 0% with empty tanks), against 9.81
  -- rather than this world's gravity. The full-throttle TWR is on the Launch
  -- card while the clamps hold, where it matches the builder's figure.
  local rows = {
    { "TWR", string.format("%.2f", t.twr or 0) },
    { "THRUST", string.format("%d kN", math.floor((t.thrust_now or 0) + 0.5)) },
    { "PITCH", string.format("%+.0f°", whole(t.nose or 0)) },
  }
  for i, r in ipairs(rows) do
    local y = 12 + (i - 1) * 46
    kids[#kids + 1] = micro("fl" .. i, r[1], 540, y, 62, "start")
    kids[#kids + 1] = value("fv" .. i, r[2], 540, y + 14, 62, "start")
  end

  kids[#kids + 1] = warp_pill(t)

  return { "box", key = "console", style = "hud/instrument", pin = "bottom", x = shift, y = -CB,
           w = CW, h = CH, items = kids, function(k) return k end }
end

-- The orbit strip: what the orbit IS, as label-over-value pairs.
local function strip(t, tx)
  local cells
  if t.grounded or t.anchored or t.splashed then
    -- Standing on the ground (or afloat) the conic is the planet's rotation read as an
    -- orbit (apoapsis -1 m, periapsis deep underground): true, and noise.
    cells = {
      { "BODY", t.body or "—" },
      { "APOAPSIS", "—", "dim" },
      { "PERIAPSIS", "—", "dim" },
      { "PERIOD", "—", "dim" },
      { "V ORB / ESC", t.vorb and string.format("%.0f / %.0f", t.vorb, t.vesc) or "—" },
    }
  elseif t.ap then
    cells = {
      { "BODY", t.body or "—" },
      { "APOAPSIS", dist(t.ap) },
      { "PERIAPSIS", dist(t.pe), (t.pe or 0) < 0 and "dim" or nil },
      { "PERIOD", duration(t.period) },
      { "V ORB / ESC", t.vorb and string.format("%.0f / %.0f", t.vorb, t.vesc) or "—" },
    }
  else
    cells = {
      { "BODY", t.body or "—" },
      { "TRAJECTORY", "ESCAPE", "warn" },
      { "PERIAPSIS", dist(t.pe) },
      { "V ORB / ESC", t.vorb and string.format("%.0f / %.0f", t.vorb, t.vesc) or "—" },
    }
  end
  local kids = {}
  for i, c in ipairs(cells) do
    if i > 1 then
      kids[#kids + 1] = { "box", key = "rule" .. i, style = "panel/rule", w = 1, h = 24 }
    end
    kids[#kids + 1] = { "col", key = "c" .. i, w = "grow", h = STRIP_H, pad = 0, gap = 1,
      align = "center", justify = "center",
      { "text", key = "l", style = "hud/micro", w = "100%", h = 12, text = c[1], textAlign = "center" },
      { "text", key = "v", style = TONE[c[3]] or "hud/value", w = "100%", h = 16, text = c[2],
        textAlign = "center" } }
  end
  return { "row", key = "strip", style = "hud/instrument", pin = "top", x = tx, y = M,
           w = STRIP_W, h = STRIP_H, pad = 0, gap = 0, align = "center",
           items = kids, function(k) return k end }
end

-- The annunciator row: the same lamps in the same places, every flight.
-- level: 0 dark, 1 on, 2 caution, 3 warning.
local function lamps(v, t, lv, tx)
  local fuel_f = (t.fuel_cap or 0) > 0 and (v.fuel or 0) / t.fuel_cap or nil
  local ec_f = (t.ec_cap or 0) > 0 and t.ec / t.ec_cap or nil
  local heat = v.heating or 0
  local d = v.dock
  local L = {
    { "CLAMPED", t.anchored and 1 or 0,
      t.anchored and (t.ready and "Launch clamps holding — SPACE releases them"
        or string.format("Clamps hold while the craft assembles (%d / %d parts)",
          t.parts or 0, t.parts_total or 0)) or "Launch clamps" },
    t.splashed and { "SPLASHED", 1, "Afloat on the water" }
      or { "LANDED", (t.grounded and not t.anchored) and 1 or 0, "On the ground" },
    { "GEAR", t.has_gear and (v.gear_deployed and 1 or
        ((lv and lv.vspd < -2 and lv.alt < 300) and 2 or 0)) or 0,
      t.has_gear and ("Landing gear " .. (v.gear_deployed and "down" or "up") .. " — G")
        or "No landing gear" },
    { "CHUTES", v.chutes_deployed and 1 or 0,
      v.chutes_deployed and string.format("Parachutes open %d%%", pct(t.chute_open or 0))
        or "Parachutes packed" },
    { "RCS", (t.has_rcs and t.rcs_on) and 1 or 0,
      t.has_rcs and ("RCS " .. (t.rcs_on and "on" or "off")
        .. " — R · H/N fore-aft · J/L strafe · I/K up-down") or "No RCS on this craft" },
    { "HEAT", heat > 0.12 and 3 or (heat > 0.02 and 2 or 0),
      heat > 0.02 and "Reentry heating — slow down or climb" or "Hull temperature normal" },
    { "FUEL", fuel_f and (fuel_f <= 0 and 3 or (fuel_f < 0.15 and 2 or 0)) or 0,
      fuel_f and (fuel_f <= 0 and "Tanks empty" or string.format("Fuel %d%%", pct(fuel_f)))
        or "No tanks" },
    { "BATT", ec_f and (ec_f <= 0 and 3 or (ec_f < 0.15 and 2 or 0)) or 0,
      ec_f and (ec_f <= 0 and "Battery flat — probe cores, reaction wheels and radios go dark"
        or string.format("Charge %d%%%s", pct(ec_f), t.brownout and " — not enough power for everything" or ""))
        or "No batteries" },
    -- The comms link home: lit while there is one; amber for a crewed craft out
    -- of contact (it flies on), red for a probe out of contact (it can't).
    { "LINK", t.link and 1 or ((t.comms or t.probe) and ((t.probe and not t.crew) and 3 or 2) or 0),
      t.link and string.format("Link home %d%% · %s", pct(t.signal or 0),
        (t.hops or 1) <= 1 and "direct" or string.format("%d hops via %s", t.hops,
          table.concat(t.path or {}, " → ")))
        or ((t.comms or t.probe) and "No path home — extend an antenna, or put a relay overhead"
          or "No antenna aboard") },
    { "ESCAPE", (not t.ap and t.pe) and 2 or 0,
      (not t.ap and t.pe) and ("On an escape trajectory from " .. (t.body or "this body"))
        or "Bound to " .. (t.body or "the body below") },
    { "DAMAGE", t.hp and (t.hp < 0.35 and 3 or 2) or 0,
      t.hp and string.format("%s at %d%%", t.hp_part, pct(t.hp)) or "No damage" },
    { "DOCK", (d and (d.target or (d.latched or 0) > 0)) and 1 or 0,
      (d and d.target) and ("Approaching " .. d.target.name)
        or ((d and (d.latched or 0) > 0) and string.format("%d port%s latched — P for the console",
          d.latched, d.latched == 1 and "" or "s") or "No port in reach") },
  }
  local styles = { [0] = "hud/lamp", "hud/lampOn", "hud/lampWarn", "hud/lampDanger" }
  return { "row", key = "lamps", pin = "top", x = tx, y = M + STRIP_H + 6, w = "fit", h = LAMP_H,
           pad = 0, gap = LAMP_GAP, items = L,
           function(l)
             return { "button", key = l[1], style = styles[l[2]], w = LAMP_W, h = LAMP_H, focusable = false,
                      text = l[1], textAlign = "center", textValign = "center", tooltip = l[3] }
           end }
end

-- The approach readout while a port is in reach: the capture checklist, one
-- line, each condition ticked as it is met.
local function dock_line(v, tx)
  local d = v.dock
  local tg = d and d.target
  if not tg then return nil end
  -- (" ok", not a tick: this line is in the mono face, which has no ✓)
  local function ok(b) return b and " ok" or "" end
  local text = string.format("%s%s   %.2f m%s   align %d%%%s   lateral %.2f   %+.2f m/s%s%s",
    tg.locked and "◎ " or "", tg.name,
    tg.range, ok(tg.range < d.captureR),
    math.floor(tg.align * 100 + 0.5), ok(tg.align > d.alignMin),
    tg.lateral, tg.closing, ok(tg.drift < d.driftMax),
    (d.assist and "   MAG" or "") .. (d.auto and "   AUTO" or "")
      .. (v.sas_mode == "dock" and "   ALIGN" or ""))
  return { "row", key = "dockline", style = "hud/instrument", pin = "top", x = tx,
           y = M + STRIP_H + 6 + LAMP_H + 6, w = "fit", h = 24, pad = 0, gap = 8, align = "center",
           { "box", key = "l", w = 2, h = 1 },
           { "text", key = "k", style = "hud/micro", w = "fit", h = 12, text = "DOCK" },
           { "text", key = "v", style = "hud/value", w = "fit", h = 16, text = text },
           { "box", key = "r", w = 2, h = 1 } }
end

-- ── LEAVING <BODY> ───────────────────────────────────────────────────────────
--
-- The worlds here are a couple of hundred metres across and their pull ends a
-- kilometre or so out, so the difference between a high hop and never coming
-- back is a few seconds of throttle. The orbit strip did say ESCAPE, in the
-- same small type as the period — after the fact. This is the shout before it:
--
--   caution   apoapsis past half of the way to the edge of this world's pull
--   warning   apoapsis past 85 % of it, or already on an escape trajectory
--
-- It says what to do about it: cut the throttle while the engines are lit, burn
-- retrograde if there's fuel to come back with, and if there isn't, the pause
-- menu's Abort Flight brings the crew home.
LEAVE_CAUTION, LEAVE_WARNING = 0.5, 0.85

-- Global and pure (a telemetry table and a body in, a description out) so the
-- smoke test can ask it directly. nil = nothing to say.
function leaveWarning(t, b, throttle, fuel)
  if not (t and b) or t.grounded or t.anchored then return nil end
  local soi = b.soi or 0
  if not (soi > (b.radius or 0)) or soi > 1e9 then return nil end
  local frac, escaping
  if t.ap then
    frac = (t.ap + b.radius) / soi
  elseif t.pe then
    escaping, frac = true, math.huge
  else
    return nil
  end
  if frac < LEAVE_CAUTION then return nil end
  local name = string.upper(t.body or b.name or "THIS WORLD")
  local burning = (throttle or 0) > 0.02 and (fuel or 0) > 0
  local level = (escaping or frac >= LEAVE_WARNING) and 3 or 2
  local head, sub
  if level == 3 then
    head = "LEAVING " .. name .. (burning and " — CUT THROTTLE" or "")
  else
    head = "HIGH ARC" .. (burning and " — EASE OFF THE THROTTLE" or "")
  end
  local pct_out = math.floor(math.min(frac, 9.99) * 100 + 0.5)
  if burning then
    sub = escaping and "Already past escape speed: X cuts the engines, then burn retrograde (SAS 3)."
      or string.format("Apoapsis %d%% of the way to the edge of %s's pull.  X cuts the engines.",
        pct_out, t.body or "this world")
  elseif escaping then
    sub = (fuel or 0) > 0 and "On an escape trajectory — burn retrograde (SAS 3) to stay."
      or "No fuel to turn back with — ESC ▸ Abort flight brings the crew home."
  else
    sub = string.format("Apoapsis %d%% of the way out — it falls back. Chutes before you land.", pct_out)
  end
  return { level = level, head = head, sub = sub, frac = frac, escaping = escaping or false }
end

local LEAVE_H = 52
local function leave_banner(w, tx, y)
  local danger = w.level >= 3
  local edge = danger and DANGER or WARN
  return { "col", key = "leaving", pin = "top", x = tx, y = y, w = STRIP_W, h = LEAVE_H,
           pad = 6, gap = 2, align = "center", justify = "center", radius = 2, border = 2,
           borderColor = edge,
           fill = danger and { 0.30, 0.05, 0.04, 0.94 } or { 0.24, 0.14, 0.03, 0.92 },
           { "text", key = "h", w = "100%", h = 22, text = w.head, textAlign = "center",
             textSize = 19, tracking = 1.5, font = "fonts/SolarStencil.ttf",
             textColor = danger and { 1.0, 0.78, 0.74, 1 } or WARN },
           { "text", key = "s", w = "100%", h = 14, text = w.sub, textAlign = "center",
             textSize = 11.5, textColor = { 0.92, 0.88, 0.84, 1 } } }
end

-- Signal bars 0–4 (electronics.bars, kept here so a harness needs no rulebook).
local function bars_of(s)
  if not s or s <= 0 then return 0 end
  if s > 0.75 then return 4 end
  if s > 0.45 then return 3 end
  if s > 0.2 then return 2 end
  return 1
end

-- NO CONTROL: a probe out of contact or dark, a pod with nobody in it. Said
-- across the top in the same place as the LEAVING banner, with what to do.
function controlWarning(t)
  if not t or t.control ~= false then return nil end
  local why = t.ctl_why or "NO CONTROL"
  local sub
  if why:find("SIGNAL", 1, true) then
    sub = "Out of contact: no command reaches it. Extend an antenna (U) or bring a relay overhead.  [ / ] back to the crew."
  elseif why:find("POWER", 1, true) then
    sub = "The batteries are flat. Panels charge them in sunlight — the controls come back with the power."
  elseif why:find("CREW", 1, true) then
    sub = "Nobody in the seat. Walk over and climb in (F), or send the crew from the Tracking Station."
  elseif why:find("OFF", 1, true) then
    sub = "The probe core is asleep. Its Wake action (an action group) brings it back."
  else
    sub = "[ / ] switch to something you can fly."
  end
  return { level = 3, head = why, sub = sub }
end

-- THE ACTION GROUPS, mid-left: every group with something in it, its key, and
-- whether it's on. Click a row to fire it, same as the key.
local function group_strip(v, t)
  local list = v.groupStrip and v.groupStrip() or {}
  local rows = {}
  local mode = t.crew and "CREW ABOARD" or (t.probe and (t.control and "PROBE · REMOTE" or "PROBE · NO CONTROL")) or nil
  local craft = (v.craftName and v.craftName ~= "Vessel") and v.craftName or nil
  for _, g in ipairs(list) do
    local key = g.key == "backspace" and "⌫" or tostring(g.key):upper()
    rows[#rows + 1] = { "row", key = "g" .. g.id, w = "100%", h = 20, pad = 0, gap = 6, align = "center",
      button = true, tooltip = string.format("%s — %d action%s · %s", g.label, g.n, g.n == 1 and "" or "s",
        g.on and "on" or "off"),
      onClicked = function() if v.activateGroup then v.activateGroup(g.id) end end,
      { "box", key = "k", style = g.on and "hud/keyActive" or "hud/key", w = 22, h = 18, text = key,
        textAlign = "center", textValign = "center" },
      { "text", key = "l", style = "hud/value", w = "grow", h = 14, text = g.label, maxLines = 1,
        overflow = "ellipsis" },
      { "text", key = "o", style = g.on and "hud/valueAccent" or "hud/valueMuted", w = 26, h = 14,
        text = g.on and "ON" or "off", textAlign = "end" } }
  end
  if #rows == 0 and not mode then return nil end
  local kids = {
    { "text", key = "hd", style = "hud/micro", w = "100%", h = 12, text = "ACTION GROUPS", textAlign = "start" },
  }
  if craft then
    kids[#kids + 1] = { "text", key = "craft", style = "hud/value", w = "100%", h = 14, text = craft,
      maxLines = 1, overflow = "ellipsis" }
  end
  if mode then
    kids[#kids + 1] = { "text", key = "mode", style = t.control and "hud/valueAccent" or "hud/valueDanger",
      w = "100%", h = 14, text = mode, maxLines = 1, overflow = "ellipsis" }
  end
  for _, r in ipairs(rows) do kids[#kids + 1] = r end
  if #rows == 0 then
    kids[#kids + 1] = { "text", key = "none", style = "hud/valueMuted", w = "100%", h = 14,
      text = "none — set them in the builder (5)" }
  end
  return { "col", key = "groups", style = "hud/instrument", pin = "left", x = M, y = 0, w = 196, h = "fit",
           pad = 10, gap = 4, items = kids, function(k) return k end }
end

-- Fuel and charge, top right.
local function resources(v, t)
  local rows = {}
  if (t.fuel_cap or 0) > 0 then
    local f = (v.fuel or 0) / t.fuel_cap
    rows[#rows + 1] = { key = "fuel", label = "FUEL", frac = f,
      color = f <= 0 and DANGER or (f < 0.15 and WARN or PHOS),
      tone = f <= 0 and "danger" or (f < 0.15 and "warn" or nil),
      -- What the fuel is WORTH: Δv on the engines lit now (Tsiolkovsky, the
      -- builder's figure) and how long it lasts at full throttle.
      tip = t.refueling and "Refuelling from the pad" or (string.format("%.0f / %.0f units",
        v.fuel or 0, t.fuel_cap)
        .. (((t.fuel_t or 0) > 0) and string.format(" (%.2f t)", t.fuel_t) or "")
        .. (((t.dv or 0) > 0) and string.format(" · Δv %.0f m/s · %.1f s at full throttle",
          t.dv, t.burn_s or 0) or "")) }
  end
  if (t.ec_cap or 0) > 0 or t.comms or (t.ec_gen or 0) > 0 then
    local f = (t.ec_cap or 0) > 0 and t.ec / t.ec_cap or 0
    local notes = {}
    if t.solar then notes[#notes + 1] = "solar charging" end
    if t.link then notes[#notes + 1] = "comms link up"
    elseif t.comms and not t.dish_up then notes[#notes + 1] = "dish stowed — U deploys it" end
    -- The flow: what comes in, what goes out, and where that leaves you.
    local net = t.ec_net or 0
    local flow = string.format("in +%.2f/s · out −%.2f/s", t.ec_supply or 0, t.ec_demand or 0)
    if net < -1e-3 and (t.ec or 0) > 0 then
      flow = flow .. string.format(" · flat in %s", duration((t.ec or 0) / -net))
    elseif net > 1e-3 and (t.ec_cap or 0) > (t.ec or 0) then
      flow = flow .. string.format(" · full in %s", duration(((t.ec_cap or 0) - (t.ec or 0)) / net))
    end
    if (t.panels or 0) > 0 and not t.sunlit then notes[#notes + 1] = "panels in shadow" end
    rows[#rows + 1] = { key = "ec", label = "CHARGE", frac = f,
      color = f <= 0 and DANGER or (f < 0.15 and WARN or PHOS),
      tone = f <= 0 and "danger" or (f < 0.15 and "warn" or nil),
      tip = string.format("%.0f / %.0f EC · %s", t.ec or 0, t.ec_cap or 0, flow)
        .. (#notes > 0 and (" · " .. table.concat(notes, " · ")) or "") }
  end
  if t.comms or t.probe then
    local sgl = t.link and (t.signal or 0) or 0
    rows[#rows + 1] = { key = "sig", label = "SIGNAL", frac = sgl,
      color = sgl <= 0 and DANGER or (sgl < 0.25 and WARN or PHOS),
      tone = sgl <= 0 and "danger" or (sgl < 0.25 and "warn" or nil),
      value = t.link and (string.rep("▮", bars_of(sgl)) .. string.rep("▯", 4 - bars_of(sgl))) or "none",
      tip = t.link and string.format("%d%% · %s · via %s", pct(sgl),
          (t.hops or 1) <= 1 and "direct to the ground station" or string.format("%d hops", t.hops),
          table.concat(t.path or { "Ground station" }, " → "))
        or "No path home — extend an antenna (U), or get a relay overhead" }
  end
  if #rows == 0 then return nil, 0 end
  local BAR = RES_W - 20 - 50 - 44 - 12
  local h = 20 + #rows * 18 + (#rows - 1) * 6
  return { "col", key = "res", style = "hud/instrument", pin = "topRight", x = -M, y = M + 28 + 8,
           w = RES_W, h = h, pad = 10, gap = 6, items = rows,
           function(r)
             local len = math.floor(math.max(0, math.min(1, r.frac)) * (BAR - 2) + 0.5)
             return { "row", key = r.key, w = "100%", h = 18, pad = 0, gap = 6, align = "center",
                      button = true, tooltip = r.tip,
                      { "text", key = "l", style = "hud/micro", w = 50, h = 12, text = r.label,
                        textAlign = "start" },
                      { "box", key = "t", style = "hud/track", w = BAR, h = 8,
                        { "box", key = "f", x = 1, y = 1, w = len, h = 6, radius = 1,
                          fill = r.color } },
                      { "text", key = "v", style = TONE[r.tone] or "hud/value", w = 44, h = 16,
                        text = r.value or string.format("%d%%", pct(r.frac)), textAlign = "end" } }
           end }, h
end

-- The stage stack: one card per SPACE, the next at the bottom. While the
-- clamps hold, releasing them IS the next stage.
local function stage_stack(t, lift)
  local cards = {}
  local n = #(t.stages or {})
  for i = n, 1, -1 do
    local st = t.stages[i]
    local title, sub
    if st.kind == "ring" then
      title = string.format("Boosters ×%d", st.n or 0)
      sub = st.eng > 0 and string.format("drops %d eng · %d kN", st.eng, st.kn) or "separate"
    elseif st.kind == "chute" then
      title = string.format("Chutes ×%d", st.n or 0)
      sub = "deploy"
    elseif st.kind == "fairing" then
      title, sub = "Fairing", "jettison"
    else
      title = "Decouple"
      sub = st.eng > 0 and string.format("then %d eng · %d kN", st.eng, st.kn) or "then coast"
    end
    cards[#cards + 1] = { key = "s" .. i, num = i, title = title, sub = sub,
                          next = (i == 1) and not t.anchored }
  end
  if t.anchored then
    cards[#cards + 1] = { key = "clamps", num = 0, title = "Launch",
      -- The builder's two figures, as the pad measures them (wet mass, local g).
      -- Short enough for the card beside its SPACE key at 168 units wide.
      sub = t.ready and string.format("TWR %.2f  Δv %.0f", t.twr_max or 0, t.dv or 0)
        or string.format("assembling %d / %d", t.parts or 0, t.parts_total or 0),
      next = true, blocked = not t.ready }
  end
  if #cards == 0 then return nil end
  return { "col", key = "stages", pin = "bottomRight", x = -M, y = -lift, w = STAGE_W, h = "fit",
           pad = 0, gap = 6, align = "stretch",
           -- Over the world, not on a display: printed ink with a shadow.
           { "text", key = "hd", style = "hud/label", w = "100%", h = 12, text = "STAGES",
             textAlign = "end" },
           { "col", key = "list", w = "100%", h = "fit", pad = 0, gap = 6, items = cards,
             function(c)
               local kids = {
                 { "text", key = "n", style = "hud/valueMuted", w = 14, h = 16,
                   text = c.num > 0 and tostring(c.num) or "", textAlign = "center",
                   textValign = "center" },
                 { "col", key = "t", w = "grow", h = "fit", pad = 0, gap = 1,
                   { "text", key = "a", style = c.next and "hud/stageTitleNext" or "hud/stageTitle",
                     w = "100%", h = 14, text = c.title, maxLines = 1, overflow = "ellipsis" },
                   { "text", key = "b", style = "hud/valueMuted", w = "100%", h = 12,
                     text = c.sub, maxLines = 1, overflow = "ellipsis" } },
               }
               if c.next then
                 kids[#kids + 1] = { "box", key = "k", style = c.blocked and "hud/key" or "hud/keyActive",
                   w = 42, h = 18, text = "SPACE", textAlign = "center", textValign = "center" }
               end
               table.insert(kids, 1, { "box", key = "l", w = 2, h = 1 })
               kids[#kids + 1] = { "box", key = "r", w = 2, h = 1 }
               return { "row", key = c.key, style = c.next and "hud/stageNext" or "hud/stage",
                        w = "100%", h = 38, pad = 0, gap = 6, align = "center",
                        items = kids, function(k) return k end }
             end } }
end

-- ── the scene's instruments, placed on the console ──────────────────────────

-- The navball, tapes and windows are pinned to the bottom centre, so their
-- offsets are measured from there: x from the centre line, y up from the bottom.
local function place(name, r, shift)
  local e = comp(name)
  if not e then return end
  set(e, "posX", shift - CW / 2 + r[1] + r[3] / 2)
  set(e, "posY", -(CB + CH - (r[2] + r[4])))
end

local function place_instruments(shift)
  place("Navball", P.ball, shift)
  place("Speed Tape", P.spd, shift)
  place("Alt Tape", P.alt, shift)
  place("Speed Readout", P.spdWin, shift)
  place("Alt Readout", P.altWin, shift)
  place("Heading Readout", P.hdgWin, shift)
end

-- ── driver ──────────────────────────────────────────────────────────────────

function start(node)
  el = node:getcomponent("UiElement")
  if el then el.visible = false end
end

local function show(on)
  if el and el.visible ~= on then el.visible = on end
  if not overlay or not overlay.valid then
    overlay = find("Flight HUD Overlay")
    overlay_el = overlay and overlay:getcomponent("UiElement") or nil
  end
  if overlay_el and overlay_el.visible ~= on then overlay_el.visible = on end
end

function update(node, dt)
  if not el then el = node:getcomponent("UiElement") end
  local v = params.enabled >= 0.5 and flown() or nil
  local om, gm = ref("orbit_map"), ref("game_manager")
  local t = v and v.tele
  if not t or (om and om.map_view) or (gm and gm.loading) then
    show(false)
    layout, warning, made_v = nil, nil, nil
    return
  end
  show(true)
  -- At most `rate` rebuilds a second; a new craft is drawn at once.
  local rate = params.rate or 0
  -- (By the craft's node id: each findScripts call hands out a new handle.)
  local vid = v.node and v.node.id
  if rate > 0 and vid and vid == made_v and time > made_t and time - made_t < 1 / rate - 0.002 then return end
  made_t, made_v = time, vid
  -- The old text block is the map's now; in flight it stays down.
  local hp = comp("HUD Panel")
  if hp and hp.visible then hp.visible = false end
  if v.sas_mode and v.sas_mode ~= "off" then sas_prev = v.sas_mode end

  -- Width: the console centres unless the stage stack needs the room (5:4 and
  -- narrower), in which case it slides left rather than under the cards.
  local dw = design_width()
  local right_limit = dw - M - STAGE_W - 8
  local shift = math.min(0, right_limit - (dw / 2 + CW / 2))
  place_instruments(shift)

  -- The debug badge shares the bottom-right corner; the stack stands on it.
  local lift = M
  local dbg = comp("Debug")
  if dbg and dbg.visible and nodes["Debug"].uiRect and camera and camera.screenSize then
    local _, _, _, bh = nodes["Debug"]:uiRect()
    local _, sh = camera.screenSize()
    if bh and bh > 1 and sh and sh > 0 then lift = M + bh * 720 / sh + 8 end
  end

  -- The top stack centres too, unless the fuel block in the corner needs the
  -- room — then it slides left, the same way the console does.
  local lv = live(v)
  local res, res_h = resources(v, t)
  local top_limit = res and (dw - M - RES_W - 8) or (dw - M)
  local top_left = math.max(M, math.min(dw / 2 - STRIP_W / 2, top_limit - STRIP_W))
  local tx = top_left - (dw / 2 - STRIP_W / 2)
  local dline = dock_line(v, tx)
  local tree = {
    strip(t, tx), lamps(v, t, lv, tx),
    console(v, t, lv, shift),
  }
  if dline then tree[#tree + 1] = dline end
  local below = M + STRIP_H + 6 + LAMP_H + (dline and (6 + 24) or 0)
  local lw = controlWarning(t) or leaveWarning(t, t.body and space.body(t.body), v.throttle, v.fuel)
  warning = lw
  if lw then
    tree[#tree + 1] = leave_banner(lw, tx, below + 8)
    below = below + 8 + LEAVE_H
  end
  local gs = group_strip(v, t)
  if gs then tree[#tree + 1] = gs end
  if res then tree[#tree + 1] = res end
  local stack = stage_stack(t, lift)
  if stack then tree[#tree + 1] = stack end
  ui.make(node, tree)

  -- The tooltip lives on the overlay so it draws over the ball and tapes. Made
  -- ONCE: the engine owns its text and visibility from then on, and describing
  -- it again every frame would put both back.
  if overlay and not tip_made then
    tip_made = true
    ui.make(overlay, { "box", key = "tip", style = "hud/tooltip", tooltipBox = true,
                       w = "fit", h = "fit", pad = 7,
                       { "text", key = "t", w = "fit", h = "fit", text = "" } })
  end

  local left = dw / 2 + shift - CW / 2
  layout = {
    consoleLeft = left, consoleRight = left + CW,
    consoleTop = 720 - CB - CH + P.hdgWin[2],   -- the heading box is the highest point
    topBottom = below,
    topLeft = top_left,
    rightBottom = M + 28 + 8 + res_h,
  }
end
