-- BUILDER_INSPECTOR — the right plate of the Vehicle Assembly (docs/builder-design.md
-- §4.4; WP2). Four tabs (TAB cycles them):
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

TABS = { "INSPECT", "STAGE", "CONTROLS", "CRAFT" }
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
-- How the craft drives in flight. AUTO reads the whole craft and says what it
-- made of it; a key wins over Auto. Shown on THIS CRAFT (nothing selected)
-- and at the top of the CRAFT tab.
local CTRL_SHORT = { auto = "Auto", rover = "Rover", aircraft = "Aircraft", rocket = "Rocket" }
local function ctrl_rows(B, out)
  if not (B.ctrlMode and B.cmd) then return end
  local c = B.ctrlMode() or {}
  local labels, tips = c.labels or CTRL_SHORT, c.tips or {}
  out[#out + 1] = sublabel("cmh", "CONTROL MODE")
  -- two keys a row: four don't fit the plate's width with their names
  local row
  for k, m in ipairs(B.CTRL_MODES or { "auto", "rover", "aircraft", "rocket" }) do
    if k % 2 == 1 then
      row = { "row", key = "cmr" .. k, w = "100%", h = 22, gap = 3, pad = 0, align = "center" }
      out[#out + 1] = row
    end
    local on = (m == "auto" and c.set == nil) or c.set == m
    row[#row + 1] = { "button", key = m, style = "panel/choice", selected = on, w = "grow", h = 22,
      text = labels[m] or m, textAlign = "center", textValign = "center",
      tooltip = tips[m], onClicked = function() B.cmd("setCtrl", { mode = m }) end }
  end
  local line
  if c.set then
    line = string.format("Flies as %s, chosen%s", (labels[c.set] or c.set):upper(),
      c.auto and c.auto ~= c.set and string.format(" (Auto would make it %s)", labels[c.auto] or c.auto) or "")
  elseif c.auto then
    line = string.format("Auto: %s — %s", (labels[c.auto] or c.auto):upper(), c.why or "")
  else
    line = "Auto: reading the craft…"
  end
  out[#out + 1] = { "text", key = "cml", style = "panel/hint", w = "100%", h = "fit", wrap = true, text = line }
end

-- ── INSPECT ─────────────────────────────────────────────────────────────────
local function inspect(B, out)
  local sel = B.selection and B.selection() or {}
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
  out[#out + 1] = { "text", key = "name", style = "panel/title", w = "100%", h = "fit", text = title,
    maxLines = 2, wrap = true }
  local ring = rec.sym and (rec.mir and "mirror pair" or "symmetry set") or nil
  out[#out + 1] = { "text", key = "sub", style = "panel/hint", w = "100%", h = 14, maxLines = 1, overflow = "ellipsis",
    text = (n > 1 and (n .. " parts selected") or role_line(def)) .. (ring and ("  ·  " .. ring) or "") }
  out[#out + 1] = figure("m", "MASS", mass_text(mass))
  out[#out + 1] = figure("c", "COST", money(cost))
  if raw.thrust and n == 1 then engine_rows(B, raw, out) end
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
local KIND_TAG = { axial = "STACK", ring = "RADIAL", chute = "CHUTE", fairing = "SHELL" }
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
      onDropped = function() if st.drag then move(st.drag, to, true) end st.drag = nil end }
  end
  if N > 0 then out[#out + 1] = newzone("ntop", N + 1, "+ NEW STAGE (fires last)") end
  for n = N, 1, -1 do
    local sg = stages[n]
    local card = { "col", key = "s" .. n, style = "panel/row", w = "100%", h = "fit", gap = 2, pad = 4, align = "stretch",
      dropTarget = true,
      onDropped = function() if st.drag then move(st.drag, n, false) end st.drag = nil end,
      onHoverStart = function() st.hover = "s" .. n end,
      onHoverEnd = function() if st.hover == "s" .. n then st.hover = nil end end }
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
        onDragStart = function() st.drag = key end,
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
    out[#out + 1] = card
  end
  if N > 0 then out[#out + 1] = newzone("nbot", 1, "+ NEW STAGE (fires first)") end
  local L = v.launch or {}
  out[#out + 1] = { "col", key = "launch", style = "panel/row", w = "100%", h = "fit", gap = 1, pad = 4, align = "stretch",
    { "text", key = "n", style = "panel/cellStrong", w = "100%", h = 18, text = "LAUNCH  ·  SPACE releases the clamps", textValign = "center" },
    { "text", key = "x", style = "panel/cellMuted", w = "100%", h = "fit", wrap = true,
      text = (L.lights and L.lights ~= "") and ("burns " .. L.lights) or "no engine lit at lift-off" } }
end

-- ── the plate ───────────────────────────────────────────────────────────────
function describe(B, L)
  local r = L.right
  local tabs = { "row", key = "tabs", w = "100%", h = 24, gap = 3, pad = 0 }
  for _, t in ipairs(TABS) do
    tabs[#tabs + 1] = { "button", key = "t" .. t, style = "panel/choice", selected = st.tab == t, w = "grow", h = 24,
      text = t == "CONTROLS" and "CTRLS" or t, textAlign = "center", textValign = "center",
      tooltip = t:sub(1, 1) .. t:sub(2):lower() .. "   ·   TAB", onClicked = function() setTab(t) end }
  end
  local body = {}
  if st.tab == "INSPECT" then inspect(B, body)
  elseif st.tab == "CRAFT" then craft(B, body)
  elseif st.tab == "STAGE" then
    stage_rows(B, body)
  else
    body[1] = { "text", key = "cx", style = "panel/body", w = "100%", h = "fit", wrap = true,
      text = "Keys and what they run. Select a part and press B to bind one." }
  end
  -- STAGE and CONTROLS hand the plate's body to the builder's and WP5's
  -- panels: the plate shrinks to its tabs and a line about them.
  local short = st.tab == "CONTROLS"
  return { "col", key = "plate", style = "panel/frame", pin = "topLeft", x = r.x, y = r.y, w = r.w,
    h = short and "fit" or r.h, gap = 6, pad = 10, align = "stretch",
    tabs,
    { "scroll", key = "body", w = "100%", h = short and "fit" or "grow", dir = "column", gap = 5, pad = 0,
      align = "stretch", items = body, function(x) return x end } }
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
  -- the STAGE tab's hovered row lights its parts in the view (for as long as it is hovered)
  if st.tab == "STAGE" and st.hover and B.stageHover then B.stageHover(st.hover) end
  local sel = B.selection()
  local sig = table.concat({ math.floor(W), math.floor(H), st.tab, tostring(B.craftVersion), table.concat(sel, ","),
    tostring(focused_name()), tostring(st.hover), tostring(st.drag) }, "|")
  if sig == st.sig and st.t < 1.0 then return end
  st.sig, st.t = sig, 0
  ui.make(node, { describe(B, st.L) })
end
