-- CONTROLS — the builder's keymap tab (docs/builder-design.md §6.3 C, WP5).
--
-- It draws in the right plate's body under WP2's CTRLS tab
-- (builder_inspector.rightPlate(); the inspector shrinks to its tabs there).
-- A selected wheel's settings are INSPECT's (builder_inspector).
--
-- One row per key in use, Besiege style, then the axes:
--
--   ┌ CONTROLS ── TEST [T] ─────────────────────────────┐
--   │ [G]  Gear          Landing Legs ×4           ⇅    │
--   │ [Y]  Lights        Floodlight ×2             ⇅    │
--   │ [P]  Claw          Landing Claw              ⇅    │
--   │ ── AXES ───────────────────────────────────────── │
--   │ PITCH W/S   Hinge ×2   pos  gain ▬▬▬  trim ▬▬     │
--   │ C1   ↑/↓    Crane boom  rate                      │
--   │ [Arm][Rover][Plane][Rocket]       [clear all]     │
--   └───────────────────────────────────────────────────┘
--
--   · hovering a row outlines its parts; clicking it selects them;
--   · ✎ renames a key (the label the flight shows), ✕ empties it;
--   · a key that two different things use is caution yellow;
--   · each axis line has its mode (rate / position), a gain fader (−1…1:
--     negative inverts) and, in position mode, a trim fader;
--   · the selected part's actions are listed with their keycaps; a keycap
--     opens the B placard for that action (builder_bind.beginFor);
--   · presets: Arm (the selection, or every joint), Rover, Plane, Rocket.
--
-- The rules are controls.lua's; edits go through the builder's commands
-- (cmd "bind" / "unbind" / "bindAxis", one undo step each). Shown on the
-- builder's CONTROLS tab (tool "groups"), or by setOpen(true).

local el
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end

local W = 300
local open_flag = false
local hover = nil         -- uids of the row under the cursor
local renaming = nil      -- gid being renamed
local armed_clear = false
local last_v, last_sel, last_hover, last_ren, last_arm = nil, nil, nil, nil, nil

function setOpen(on) open_flag = on and true or false end
function isOpen() return open_flag end

-- Is the panel up, and is the cursor over it? (registerPanel)
local PLATE_TOP = 84       -- the inspector's tabs and its one line, above us
local area = nil          -- where we draw, design units { x, y, w, h }

-- The mouse in design units (as builder_inspector reads it).
local function mouse_du(H)
  if not (camera and camera.screenSize and input and input.mouse) then return nil end
  local _, sh = camera.screenSize()
  if not (sh and sh > 0) then return nil end
  local mx, my = input.mouse()
  local ox, oy = 0, 0
  if camera.screenRect then ox, oy = camera.screenRect() end
  return (mx - (ox or 0)) * H / sh, (my - (oy or 0)) * H / sh
end

function ownsMouse()
  if not (el and el.visible and area) then return false end
  local x, y = mouse_du(area.H)
  return x ~= nil and x >= area.x and x <= area.x + area.w and y >= area.y and y <= area.y + area.h
end

local function primary(B)
  if B.selectionPrimary then return B.selectionPrimary() end
  local s = B.selection and B.selection() or {}
  return s[#s]
end

local function cmd(B, C, name, args)
  local r = B.cmd(name, args)
  if not r and C.lastError and B.placard then B.placard(C.lastError, "warn") end
  return r
end

local function chips_text(parts)
  local t = {}
  for _, p in ipairs(parts) do t[#t + 1] = p.label .. (p.n > 1 and (" ×" .. p.n) or "") end
  return table.concat(t, ", ")
end

local function all_uids(parts)
  local out = {}
  for _, p in ipairs(parts) do for _, u in ipairs(p.uids) do out[#out + 1] = u end end
  return out
end

-- A key row: [cap]  name  parts  mode  ✎ ✕
local function key_row(B, C, E, r, i)
  local uids = all_uids(r.parts)
  local name
  if renaming == r.gid then
    name = { "field", key = "nf", style = "menu/field", w = "grow", h = 22, text = r.name, maxLen = 24,
      onSubmitted = function(n)
        cmd(B, C, "unbind", { gid = r.gid, rename = (n and n.text) or r.name })
        renaming = nil
      end,
      onCancelled = function() renaming = nil end }
  else
    name = { "text", key = "n", style = "panel/cellStrong", w = "grow", h = "fit", maxLines = 1, overflow = "ellipsis",
             text = r.name }
  end
  return { "col", key = "k" .. i, w = "100%", h = "fit", gap = 1, pad = 0, button = true,
    tooltip = table.concat(r.acts, " · ") .. (r.conflict and "  ·  ⚠ an axis uses this key too" or ""),
    onHoverStart = function() hover = uids end,
    onHoverEnd = function() if hover == uids then hover = nil end end,
    onClicked = function() if B.select then B.select(uids, "set") end end,
    { "row", key = "top", w = "100%", h = 22, gap = 5, pad = 0, align = "center",
      { "box", key = "cap", style = r.conflict and "hud/chipWarn" or "hud/key", w = 30, h = 20, text = r.cap,
        textAlign = "center", textValign = "center" },
      name,
      { "text", key = "m", style = "panel/cellMuted", w = 30, h = "fit", textAlign = "end", text = r.mode },
      { "button", key = "ren", style = "panel/secondary", w = 22, h = 20, text = "✎", textAlign = "center",
        textValign = "center", tooltip = "Rename — the label the flight shows on this key",
        onClicked = function() renaming = r.gid end },
      { "button", key = "x", style = "panel/secondary", w = 22, h = 20, text = "✕", textAlign = "center",
        textValign = "center", tooltip = "Take everything off this key",
        onClicked = function()
          local acts = {}
          local g = B.groupsNow and B.groupsNow() or {}
          for _, b in ipairs((g[r.gid] or {}).binds or {}) do acts[b.act] = true end
          local list = {}
          for a in pairs(acts) do list[#list + 1] = a end
          cmd(B, C, "unbind", { uids = uids, acts = list, gid = r.gid })
        end } },
    { "text", key = "p", style = "panel/cellMuted", w = "100%", h = "fit", maxLines = 1, overflow = "ellipsis",
      text = "      " .. chips_text(r.parts) } }
end

local function fader(key, v, lo, hi, show, on_set)
  return { "row", key = key, w = "100%", h = 20, gap = 6, pad = 0, align = "center",
    { "text", key = "l", style = "panel/cellMuted", w = 34, h = "fit", text = key:upper() },
    { "slider", key = "s", style = "ctl/track", w = "grow", h = 12, min = lo, max = hi, value = v, interact = true,
      onChanged = function(n)
        local sl = n and n:getcomponent("UiSlider")
        if sl and sl.value then on_set(sl.value) end
      end,
      { "box", key = "f", style = "ctl/fill", part = "fill", w = "100%", h = "100%" },
      { "box", key = "h", style = "ctl/handle", part = "handle", w = 10, h = 16 } },
    { "text", key = "v", style = "ctl/value", w = 44, h = "fit", textAlign = "end", text = show(v) } }
end

-- An axis source and its bound parts, each with mode, gain and trim.
local function axis_rows(B, C, E, a, i, recs)
  local out = {}
  out[#out + 1] = { "row", key = "a" .. i, w = "100%", h = 22, gap = 6, pad = 0, align = "center",
    { "box", key = "cap", style = a.conflict and "hud/chipWarn" or "hud/key", w = 54, h = 20, text = a.keys,
      textAlign = "center", textValign = "center" },
    { "text", key = "n", style = "panel/cellStrong", w = "grow", h = "fit", maxLines = 1, overflow = "ellipsis",
      text = a.custom and (a.name or a.src:upper()) or a.label } }
  for j, b in ipairs(a.binds) do
    local key = "a" .. i .. "b" .. j
    local uids = b.uids
    local rec = recs[b.uid]
    local C2 = C
    local spec = rec and C.axisSpec(rec, b.act, E)
    local half = spec and (spec.max - spec.min) / 2 or 1
    local unit = spec and spec.unit or ""
    local function tune(field, value)
      cmd(B, C2, "bindAxis", { uids = uids, act = b.act, field = field, value = value, merge = key .. field })
    end
    out[#out + 1] = { "col", key = key, w = "100%", h = "fit", gap = 2, pad = 0,
      onHoverStart = function() hover = uids end,
      onHoverEnd = function() if hover == uids then hover = nil end end,
      { "row", key = "h", w = "100%", h = 22, gap = 4, pad = 0, align = "center",
        { "text", key = "p", style = "panel/cell", w = "grow", h = "fit", maxLines = 1, overflow = "ellipsis",
          text = "  " .. b.label .. (b.n > 1 and (" ×" .. b.n) or "") .. " · " .. b.act },
        { "button", key = "rate", style = "panel/choice", selected = b.mode == "rate", w = 44, h = 20, text = "rate",
          textAlign = "center", textValign = "center", tooltip = "Moves while held, stays where it stops",
          onClicked = function() tune("mode", "rate") end },
        { "button", key = "pos", style = "panel/choice", selected = b.mode == "position", w = 44, h = 20, text = "pos",
          textAlign = "center", textValign = "center", tooltip = "Follows the input and springs back to the trim",
          onClicked = function() tune("mode", "position") end },
        { "button", key = "x", style = "panel/secondary", w = 22, h = 20, text = "✕", textAlign = "center",
          textValign = "center", tooltip = "Take this part off the axis",
          onClicked = function() cmd(B, C2, "unbind", { uids = uids, axis = b.act }) end } },
      fader("gain", b.gain or 1, -1, 1, function(v) return string.format("%+.2f", v) end,
        function(v) tune("gain", math.floor(v * 20 + 0.5) / 20) end) }
    if b.mode == "position" then
      local col = out[#out]
      col[#col + 1] = fader("trim", b.trim or 0, -half, half,
        function(v) return string.format(unit == "m" and "%+.2f" or "%+.0f", v) .. (unit == "m" and "m" or unit) end,
        function(v) tune("trim", v) end)
    end
  end
  return out
end

-- The selected part's actions with their keycaps.
local function part_rows(B, C, E, bind)
  local uid = primary(B)
  local rows = {}
  if not uid then
    rows[1] = { "text", key = "pick", style = "panel/cellMuted", w = "100%", h = "fit", wrap = true,
      text = "Select a part and press B to give it a key — or click a keycap below." }
    return rows
  end
  local r = B.partRec and B.partRec(uid)
  local list = {}
  if r then
    local d = r.def or {}
    local rec = { uid = uid, id = r.id, label = d.label, kind = d.kind, mods = E.deriveMods and E.deriveMods(d, d.mods) or d.mods,
                  sym = r.sym }
    list = C.partControls(B.groupsNow and B.groupsNow() or {}, B.controlsData and B.controlsData() or nil, rec, E)
  end
  rows[#rows + 1] = { "text", key = "pl", style = "panel/cellStrong", w = "100%", h = "fit",
    text = ((r and r.def and r.def.label) or "part") .. ((r and r.sym and r.sym ~= 0) and "  (ring — binds every member)" or "") }
  if #list == 0 then
    rows[#rows + 1] = { "text", key = "noact", style = "panel/cellMuted", w = "100%", h = "fit", wrap = true,
      text = "Nothing to switch on this part — it's structure." }
    return rows
  end
  local sc = { "scroll", key = "acts", w = "100%", h = "fit", maxH = 150, gap = 2, pad = 0, dir = "column" }
  for i, a in ipairs(list) do
    local keys = #a.keys > 0 and table.concat(a.keys, " ") or "—"
    sc[#sc + 1] = { "row", key = "r" .. i, w = "100%", h = 22, gap = 6, pad = 0, align = "center",
      { "text", key = "t", style = a.primary and "panel/cellStrong" or "panel/cell", w = "grow", h = "fit",
        maxLines = 1, overflow = "ellipsis", text = a.label .. (a.axis and "  ±" or "") },
      { "button", key = "k", style = "panel/secondary", w = 64, h = 20, text = keys, textAlign = "center",
        textValign = "center", tooltip = "Press to bind (the B placard for this action)",
        onClicked = function() if bind and bind.beginFor then bind.beginFor(uid, a.id) end end },
      { "button", key = "x", style = "panel/secondary", w = 22, h = 20, text = "✕", textAlign = "center",
        textValign = "center", disabled = #a.keys == 0, tooltip = "Take it off every key",
        onClicked = function()
          if a.axis then
            if #C.axesOfPart(C.live(B.controlsData and B.controlsData() or nil), uid) > 0 then
              cmd(B, C, "unbind", { uids = { uid }, axis = a.axis })
            else
              cmd(B, C, "unbind", { uids = { uid }, acts = { a.axis .. ".inc", a.axis .. ".dec" } })
            end
          else
            cmd(B, C, "unbind", { uids = { uid }, acts = a.acts })
          end
        end } }
  end
  rows[#rows + 1] = sc
  return rows
end

local function describe(B, E, C)
  local groups, recs = {}, {}
  if B.groupsNow then groups, recs = B.groupsNow() end
  groups, recs = groups or {}, recs or {}
  local data = B.controlsData and B.controlsData() or nil
  local km = C.keymap(groups, data, recs, E)
  local bind = ref("builder_bind")
  local testing = B.testMode and B.testMode() or false
  local body = {}
  local function add(x) body[#body + 1] = x end
  add({ "row", key = "head", w = "100%", h = "fit", gap = 8, pad = 0, align = "center",
    { "text", key = "t", style = "panel/heading", w = "grow", h = "fit", text = "CONTROLS" },
    { "button", key = "test", style = "panel/choice", selected = testing, w = 74, h = 24, text = "TEST  T",
      textAlign = "center", textValign = "center",
      tooltip = "Drive the craft from these keys on the stand — joints move, nothing is edited",
      onClicked = function() if B.setTestMode then B.setTestMode(not testing) end end } })
  add({ "text", key = "lead", style = "panel/hint", w = "100%", h = "fit", wrap = true,
    text = "Select a part, press B, press a key. A joint takes two keys (+ then −) or the stick (W/S A/D Q/E)." })
  local sc = { "scroll", key = "map", w = "100%", h = "fit", maxH = math.max(120, (area and area.h or 480) - 250),
               gap = 3, pad = 0, dir = "column" }
  if #km.keys == 0 then
    sc[#sc + 1] = { "text", key = "nokeys", style = "panel/cellMuted", w = "100%", h = "fit", text = "No keys yet." }
  end
  for i, r in ipairs(km.keys) do sc[#sc + 1] = key_row(B, C, E, r, i) end
  local any_surf = #km.surfaces.pitch + #km.surfaces.yaw + #km.surfaces.roll > 0
  if #km.axes > 0 or any_surf then
    sc[#sc + 1] = { "text", key = "axl", style = "panel/label", w = "100%", h = "fit", text = "AXES" }
  end
  for i, a in ipairs(km.axes) do
    for _, x in ipairs(axis_rows(B, C, E, a, i, recs)) do sc[#sc + 1] = x end
  end
  for _, ax in ipairs({ "pitch", "yaw", "roll" }) do
    local list = km.surfaces[ax]
    if #list > 0 then
      sc[#sc + 1] = { "row", key = "sf" .. ax, w = "100%", h = 22, gap = 6, pad = 0, align = "center",
        { "box", key = "cap", style = "hud/key", w = 54, h = 20, text = C.sourceKeys(nil, ax), textAlign = "center",
          textValign = "center" },
        { "text", key = "n", style = "panel/cell", w = "grow", h = "fit", maxLines = 1, overflow = "ellipsis",
          text = chips_text(list) .. " (auto)" } }
    end
  end
  add(sc)
  add({ "box", key = "r1", style = "panel/rule", w = "100%", h = 1 })
  add({ "text", key = "sl", style = "panel/label", w = "100%", h = "fit", text = "SELECTED PART" })
  for _, r in ipairs(part_rows(B, C, E, bind)) do add(r) end
  add({ "box", key = "r2", style = "panel/rule", w = "100%", h = 1 })
  local pr = { "row", key = "presets", w = "100%", h = 26, gap = 4, pad = 0, align = "center" }
  for _, p in ipairs(C.PRESETS) do
    pr[#pr + 1] = { "button", key = p.id, style = "panel/secondary", w = "grow", h = 26, text = p.label,
      textAlign = "center", textValign = "center", tooltip = p.tip,
      onClicked = function()
        local sel = (p.id == "arm" and B.selection) and B.selection() or nil
        if cmd(B, C, "bind", { preset = p.id, uids = (sel and #sel > 1) and sel or nil }) and B.hint then
          B.hint(p.label .. " preset applied — undo with Ctrl+Z", 2.5)
        end
      end }
  end
  add(pr)
  add({ "row", key = "btns", w = "100%", h = 26, gap = 6, pad = 0,
    { "button", key = "bind", style = "panel/secondary", w = "grow", h = 26, textAlign = "center", textValign = "center",
      text = "Bind selected  B", disabled = primary(B) == nil,
      onClicked = function() if bind and bind.begin then bind.begin(B.selection()) end end },
    { "button", key = "clear", style = "panel/danger", selected = armed_clear, w = "grow", h = 26, textAlign = "center",
      textValign = "center", text = armed_clear and "Sure? clear all" or "Clear all",
      tooltip = "Every key and axis off this craft (one undo step)",
      onClicked = function()
        if armed_clear then cmd(B, C, "unbind", { all = true }); armed_clear = false else armed_clear = true end
      end } })
  local A = area or { h = 600 }
  return { "col", key = "groups", style = "panel/frame", w = "100%", h = "fit", maxH = A.h, gap = 5, pad = 10,
           align = "start", items = body, function(x) return x end }
end

-- Outline the hovered row's parts (orange: the one accent marks "this one").
local function draw_hover(B)
  if not (hover and B.partRec and B.drawObb and B.visHalf) then return end
  for _, u in ipairs(hover) do
    local r = B.partRec(u)
    if r then
      local hx, hy, hz = B.visHalf(r.id, r.def)
      B.drawObb(r.x, r.y, r.z, r.B, hx + 0.05, hy + 0.05, hz + 0.05, 0.97, 0.55, 0.22, 1.0)
    end
  end
end

function start(node)
  el = node:getcomponent("UiElement")
  refs.self_node = node
  if el then el.visible = false end
end

local function tab_open(B)
  if open_flag then return true end
  local ins = ref("builder_inspector")
  if ins and ins.tab then return ins.tab() == "CONTROLS" end
  if B.tool then return B.tool() == "groups" end
  return B.groupsTool and B.groupsTool() or false
end

-- Where to draw: the right plate's body under the inspector's tabs (design
-- units), and where our host sits, so a child pinned to the host lands there.
local function place(node)
  local tb, ins = ref("builder_toolbar"), ref("builder_inspector")
  local Wl, H = 1280, 720
  if tb and tb.layerSize then Wl, H = tb.layerSize() end
  local r = ins and ins.rightPlate and ins.rightPlate() or { x = Wl - 264, y = 80, w = 256, h = H - 138 }
  -- the host itself moves there (it is pinned to the layer's top right and
  -- stacks its one child): x from the right edge, y from the top
  local A = { x = r.x, y = r.y + PLATE_TOP, w = r.w, h = r.h - PLATE_TOP, H = H }
  if el then
    if math.abs((el.width or 0) - A.w) > 0.5 then el.width = A.w end
    local px, py = A.x + A.w - Wl, A.y
    if math.abs((el.posX or 0) - px) > 0.5 then el.posX = px end
    if math.abs((el.posY or 0) - py) > 0.5 then el.posY = py end
  end
  return A
end

function update(node, dt)
  if not el then el = node:getcomponent("UiElement") end
  refs.self_node = node
  local B, E, C = ref("builder"), ref("electronics"), ref("controls")
  if not (B and E and C) then return end
  if not refs.registered and B.registerPanel then refs.registered = B.registerPanel(ref("groups_panel")) end
  local show = tab_open(B)
  if not show then
    if el and el.visible then el.visible = false end
    hover, last_v, area = nil, nil, nil
    return
  end
  local A = place(node)
  if el and el.visible ~= true then el.visible = true end
  draw_hover(B)
  -- re-describe only when something it shows moved
  local sel = primary(B)
  local v = table.concat({ tostring(B.craftVersion), tostring(B.testMode and B.testMode()),
    math.floor(A.x), math.floor(A.y), math.floor(A.h) }, "|")
  area = A
  if v == last_v and sel == last_sel and hover == last_hover and renaming == last_ren and armed_clear == last_arm then
    return
  end
  last_v, last_sel, last_hover, last_ren, last_arm = v, sel, hover, renaming, armed_clear
  ui.make(node, describe(B, E, C))
end
