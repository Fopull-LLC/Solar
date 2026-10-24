-- BUILDER_TOOLBAR — the Vehicle Assembly's top plate (docs/builder-design.md
-- §4.4; WP2), plus the two things that hang off it:
--
--   row 1   VAB · the craft's name · NEW OPEN SAVE SUB-ASSY · 1 SEL 2 OFFSET
--           3 ROTATE 4 ROOT · ◂ LEAVE · LAUNCH ▸ with PAD | RUNWAY latched
--   row 2   SYM OFF ×2 ×3 ×4 ×6 ×8 MIR · SNAP grid, angle · SPACE · TEST ·
--           overlays · UNDO REDO · ? KEYS
--   HT      the camera height fader on the viewport's right edge
--           (builder_camera.heightFrac / setHeightFrac)
--   OPEN    the craft library, dropped under its key
--   ?       the key card (§4.3), every key with what it does
--
-- Every key here is a mouse way to do what a keyboard accelerator does; the
-- state shown is the builder's (its public API: tool(), symMode(), snapGrid()…),
-- read every frame, so a key pressed on the keyboard lights the keycap too.
--
-- THE LAYOUT: `builderLayout(W, H)` is the one place the screen is divided;
-- the catalogue, the inspector, the status strip and the context menu ask it.
-- The host node is stretched to the whole layer (W × H design units, where H
-- is settings.designHeight()), and every plate is pinned inside it.

ownsModes = true      -- the builder stops drawing its own symmetry chips
keysOpen = false
libraryOpen = false

local M, TB, SB, LW, RW, HTW, GAP = 8, 66, 44, 228, 256, 24, 6

-- The screen, divided. W and H are the layer's design units.
function builderLayout(W, H)
  W, H = W or 1280, H or 720
  local top = M + TB + GAP
  local sby = H - M - SB
  local body_h = sby - GAP - top
  local L = {
    W = W, H = H,
    toolbar = { x = M, y = M, w = W - 2 * M, h = TB },
    status = { x = M, y = sby, w = W - 2 * M, h = SB },
    left = { x = M, y = top, w = LW, h = body_h },
    right = { x = W - M - RW, y = top, w = RW, h = body_h },
  }
  L.ht = { x = L.right.x - GAP - HTW, y = top + 28, w = HTW, h = body_h - 56 }
  L.view = { x = L.left.x + LW + GAP, y = top, w = L.ht.x - GAP - (L.left.x + LW + GAP), h = body_h }
  return L
end

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end

-- The layer's size in design units: H from the interface size, W from the
-- window's aspect.
function layerSize()
  local st = ref("settings")
  local H = (st and st.designHeight and st.designHeight()) or 720
  local W = H * 16 / 9
  if camera and camera.screenSize then
    local sw, sh = camera.screenSize()
    if sw and sh and sh > 0 then W = H * sw / sh end
  end
  return W, H
end

-- The mouse in design units, or nil.
local function mouse_du()
  if not (input and input.mouse and camera and camera.screenSize) then return nil end
  local sw, sh = camera.screenSize()
  if not (sh and sh > 0) then return nil end
  local _, H = layerSize()
  local mx, my = input.mouse()
  local ox, oy = 0, 0
  if camera.screenRect then ox, oy = camera.screenRect() end
  return (mx - (ox or 0)) * H / sh, (my - (oy or 0)) * H / sh
end
local function inside(r, x, y)
  return r and x and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

-- ── what the builder says now, with the day-0 globals as a fallback ─────────
local last_tool = "select"
local function bstate(B)
  local s = {}
  s.tool = B.tool and B.tool() or last_tool
  local sm = B.symMode and B.symMode() or 1
  s.mirror = sm == "mirror"
  s.sym = type(sm) == "number" and sm or 1
  s.grid = B.snapGrid and B.snapGrid() or nil
  s.angle = B.snapAngle and B.snapAngle() or nil
  s.space = B.gizmoSpace and B.gizmoSpace() or ((B.ROT_FRAME == "part") and "local" or "world")
  s.test = B.testMode and B.testMode() or false
  s.overlay = B.overlayMode and B.overlayMode() or nil
  s.site = B.launchSite and B.launchSite() or "pad"
  s.name = B.craftName and B.craftName() or "Untitled craft"
  s.canUndo = B.canUndo and B.canUndo() or false
  s.canRedo = B.canRedo and B.canRedo() or false
  s.typing = ownsKeys()
  local st = B.stats and B.stats() or nil
  s.block = st and st.launch and st.launch.block or nil
  s.warn = st and st.launch and st.launch.warn or nil
  return s
end

local GRIDS = { 0.01, 0.05, 0.25, 1.0, 0 }
local ANGLES = { math.rad(1), math.rad(5), math.rad(15), 0 }
local function grid_label(g)
  if not g or g <= 0 then return "OFF" end
  if g < 1 then return string.format("%d cm", math.floor(g * 100 + 0.5)) end
  return string.format("%g m", g)
end
local function angle_label(a)
  if not a or a <= 0 then return "OFF" end
  return string.format("%d°", math.floor(math.deg(a) + 0.5))
end
local function next_in(list, cur)
  for i, x in ipairs(list) do
    if math.abs(x - (cur or -1)) < 1e-6 then return list[i % #list + 1] end
  end
  return list[1]
end
local OVERLAYS = { [0] = "OFF", "CoM·CoT", "+CoL", "+AERO" }

-- ── pieces ──────────────────────────────────────────────────────────────────
local function key(k, text, w, opts)
  opts = opts or {}
  return { "button", key = k, style = opts.style or "panel/choice", selected = opts.selected or false,
           disabled = opts.disabled or false, w = w, h = opts.h or 24, text = text,
           textAlign = "center", textValign = "center", tooltip = opts.tip,
           onClicked = opts.click }
end
local function label(k, text, w)
  return { "text", key = k, style = "panel/label", w = w or "fit", h = 24, text = text, textValign = "center" }
end
local function spacer(k, w) return { "box", key = k, w = w or "grow", h = 1 } end

local function say(B, msg) if B.hint then B.hint(msg, 2.5) elseif B.hintNow then B.hintNow(msg, 2.5) end end

local function row1(B, s)
  local tools = {
    { "select", "1 SEL", 54, "Select and drag parts   ·   1" },
    { "offset", "2 OFFSET", 72, "Offset gizmo on the selection   ·   2" },
    { "rotate", "3 ROTATE", 72, "Rotate gizmo on the selection   ·   3" },
    { "root", "4 ROOT", 60, "Make the clicked part the craft's root   ·   4" },
  }
  local r = { "row", key = "r1", w = "100%", h = 26, gap = 4, pad = 0, align = "center",
    { "text", key = "vab", style = "panel/heading", w = 44, h = 24, text = "VAB", textValign = "center" },
    { "field", key = "name", name = "FieldCraftName", style = "menu/field", w = 140, h = 24, textSize = 13,
      text = (not s.typing) and s.name or nil,
      placeholder = "craft name", maxLen = 40, textValign = "center", tooltip = "The craft's name — Enter saves it under this name",
      onSubmitted = function(n)
        local t = n and n.text
        if t and t ~= "" and B.craftSave then B.craftSave(t) end
      end },
    key("new", "NEW", 46, { style = "panel/secondary", disabled = not B.craftNew, tip = "A new craft   ·   CTRL+N",
      click = function() if B.craftNew then B.craftNew() end end }),
    key("open", "OPEN", 52, { style = "panel/secondary", selected = libraryOpen, disabled = not B.craftList,
      tip = "The craft library   ·   CTRL+O", click = function() openLibrary() end }),
    key("save", "SAVE", 48, { style = "panel/secondary", tip = "Save the craft   ·   CTRL+S",
      click = function()
        if B.craftSave then B.craftSave(s.name) elseif B.doSave then B.doSave() end
        say(B, "saved — " .. s.name)
      end }),
    key("sub", "SUB-ASSY", 72, { style = "panel/secondary", disabled = not B.makeSubAssembly,
      tip = "Save the selection as a sub-assembly (PARTS ▸ SUB-ASSY)",
      click = function()
        local sel = B.selection and B.selection() or {}
        if #sel == 0 then say(B, "select the parts to save as a sub-assembly first") return end
        local rec = B.partRec(sel[#sel])
        local nm = string.format("%s ×%d", (rec and rec.def and rec.def.label) or "Assembly", #sel)
        B.makeSubAssembly(nm, sel)
        say(B, "sub-assembly saved — " .. nm)
      end }),
    spacer("s1"),
  }
  for _, t in ipairs(tools) do
    r[#r + 1] = key("t" .. t[1], t[2], t[3], { selected = s.tool == t[1], tip = t[4],
      click = function() last_tool = t[1]; if B.setTool then B.setTool(t[1]) end end })
  end
  r[#r + 1] = spacer("s2")
  r[#r + 1] = key("leave", "◂ LEAVE", 68, { style = "panel/secondary",
    tip = "Save and go back to the base — buys nothing", click = function() if B.doLeave then B.doLeave() end end })
  local launch_tip = s.block and ("Can't launch — " .. s.block)
    or (s.warn and #s.warn > 0 and ("⚠ " .. table.concat(s.warn, " · ")) or "Buy the hull and roll it out")
  r[#r + 1] = key("launch", "LAUNCH ▸", 84, { style = "panel/action", disabled = s.block ~= nil, tip = launch_tip,
    click = function() if B.doLaunch then B.doLaunch() end end })
  for _, site in ipairs({ { "pad", "PAD", 40 }, { "runway", "RUNWAY", 60 } }) do
    r[#r + 1] = key("site" .. site[1], site[2], site[3], { selected = s.site == site[1],
      tip = "Launch site: " .. site[2],
      click = function()
        if s.site ~= site[1] then
          if B.setLaunchSite then B.setLaunchSite(site[1]) elseif B.toggleLaunchSite then B.toggleLaunchSite() end
        end
      end })
  end
  return r
end

local function row2(B, s)
  local r = { "row", key = "r2", w = "100%", h = 26, gap = 4, pad = 0, align = "center", label("lsym", "SYM", 28) }
  r[#r + 1] = key("sym1", "OFF", 36, { selected = s.sym <= 1 and not s.mirror, tip = "Symmetry off   ·   X cycles",
    click = function() if B.setSym then B.setSym(1) end if B.setMirror then B.setMirror(false) end end })
  for _, n in ipairs({ 2, 3, 4, 6, 8 }) do
    r[#r + 1] = key("sym" .. n, "×" .. n, 32, { selected = s.sym == n and not s.mirror,
      tip = "Radial symmetry ×" .. n .. "   ·   X / SHIFT+X",
      click = function() if B.setSym then B.setSym(n) end end })
  end
  r[#r + 1] = key("mir", "MIR", 40, { selected = s.mirror,
    tip = "Mirror symmetry   ·   M (ALT+M: the craft's centre plane)",
    click = function()
      if B.setMirror then B.setMirror(not s.mirror, input and input.key and input.key("alt") and "center" or "host")
      elseif B.toggleMirror then B.toggleMirror() end
    end })
  r[#r + 1] = spacer("g1", 8)
  r[#r + 1] = label("lsnap", "SNAP", 34)
  r[#r + 1] = key("grid", "GRID " .. grid_label(s.grid), 82, { disabled = not B.setSnapGrid,
    tip = "Grid snap   ·   G cycles 1 cm, 5 cm, 25 cm, 1 m, off",
    click = function() if B.setSnapGrid then B.setSnapGrid(next_in(GRIDS, s.grid)) end end })
  r[#r + 1] = key("ang", angle_label(s.angle), 44, { disabled = not B.setSnapAngle,
    tip = "Angle snap   ·   SHIFT+G cycles 1°, 5°, 15°, off",
    click = function() if B.setSnapAngle then B.setSnapAngle(next_in(ANGLES, s.angle)) end end })
  r[#r + 1] = spacer("g2", 8)
  r[#r + 1] = label("lspace", "SPACE", 40)
  r[#r + 1] = key("space", s.space == "local" and "LOCAL" or "WORLD", 58, { disabled = not B.setGizmoSpace,
    tip = "Gizmo space: the part's own axes or the world's   ·   L",
    click = function() if B.setGizmoSpace then B.setGizmoSpace(s.space == "local" and "world" or "local") end end })
  r[#r + 1] = spacer("g3", 8)
  r[#r + 1] = key("test", "TEST", 50, { selected = s.test == true,
    tip = "Drive the craft's controls here, with no physics   ·   T",
    click = function() if B.setTestMode then B.setTestMode(not s.test) end end })
  r[#r + 1] = key("ovl", "V " .. (OVERLAYS[s.overlay or 0] or "OFF"), 84, { selected = (s.overlay or 0) > 0,
    disabled = not B.setOverlayMode, tip = "Overlays: CoM and CoT, then CoL, then aero vectors   ·   V",
    click = function() if B.setOverlayMode then B.setOverlayMode(((s.overlay or 0) + 1) % 4) end end })
  r[#r + 1] = spacer("g4")
  r[#r + 1] = key("undo", "↶ UNDO", 60, { style = "panel/secondary", disabled = not s.canUndo, tip = "Undo   ·   CTRL+Z",
    click = function() if B.undo then B.undo() end end })
  r[#r + 1] = key("redo", "↷ REDO", 60, { style = "panel/secondary", disabled = not s.canRedo, tip = "Redo   ·   CTRL+Y",
    click = function() if B.redo then B.redo() end end })
  r[#r + 1] = key("keys", "? KEYS", 62, { selected = keysOpen, tip = "Every key in the Assembly   ·   ?",
    click = function() keysOpen = not keysOpen end })
  return r
end

-- The camera height fader (HT): top of the craft at the top.
local function ht(L)
  local C = ref("builder_camera")
  local fr = C and C.heightFrac and C.heightFrac() or 0
  local r = L.ht
  return { "col", key = "ht", pin = "topLeft", x = r.x, y = r.y - 22, w = r.w, h = r.h + 44, gap = 4, pad = 0,
    align = "center",
    { "text", key = "l", style = "panel/label", w = r.w, h = 14, text = "HT", textAlign = "center" },
    { "slider", key = "s", name = "HeightSlider", style = "ctl/track", w = 12, h = "grow", min = 0, max = 1, value = fr,
      interact = true, sliderDir = "column", flip = true,
      tooltip = "Camera height on the craft   ·   PGUP / PGDN, CTRL+wheel",
      onChanged = function(n)
        local sl = n and n:getcomponent("UiSlider")
        if sl and sl.value and C and C.setHeightFrac then C.setHeightFrac(sl.value) end
      end,
      { "box", key = "f", style = "ctl/fill", part = "fill", w = "100%", h = "100%" },
      { "box", key = "h", style = "ctl/handle", part = "handle", w = 20, h = 10 } },
    { "text", key = "v", style = "ctl/value", w = r.w + 10, h = 14, textAlign = "center",
      text = string.format("%d%%", math.floor(fr * 100 + 0.5)) },
  }
end

-- THE CRAFT LIBRARY, under OPEN.
local function library(B, L)
  local list = B.craftList and B.craftList() or {}
  local rows = {}
  for i, c in ipairs(list) do
    rows[#rows + 1] = { "row", key = "c" .. i, w = "100%", h = 30, gap = 4, pad = 0, align = "center",
      { "button", key = "o", style = "panel/row", w = "grow", h = 30, dir = "row", gap = 6, align = "center",
        tooltip = "Open it (replaces what is on the stand)",
        onClicked = function() B.craftOpen(c.name, "replace"); libraryOpen = false end,
        { "text", key = "n", style = "cat/name", w = "grow", h = 16, text = c.name, maxLines = 1, overflow = "ellipsis" },
        { "text", key = "p", style = "cat/role", w = "fit", h = 16,
          text = string.format("%d parts · %.1f t", c.parts or 0, c.mass or 0) } },
      { "button", key = "m", style = "panel/secondary", w = 56, h = 26, text = "MERGE", textAlign = "center",
        textValign = "center", tooltip = "Put it in your hand to add to this craft",
        onClicked = function() B.craftOpen(c.name, "merge"); libraryOpen = false end } }
  end
  if #rows == 0 then
    rows[1] = { "text", key = "none", style = "panel/body", w = "100%", h = "fit", wrap = true,
                text = "No saved crafts yet. SAVE keeps this one under its name." }
  end
  return { "col", key = "lib", style = "panel/frame", pin = "topLeft", x = L.toolbar.x + 190, y = L.toolbar.y + L.toolbar.h + 2,
    w = 380, h = "fit", maxH = L.H * 0.6, gap = 6, pad = 12,
    { "row", key = "hd", w = "100%", h = 22, gap = 6, pad = 0, align = "center",
      { "text", key = "t", style = "panel/heading", w = "grow", h = 22, text = "Craft library" },
      key("x", "✕", 26, { style = "panel/secondary", click = function() libraryOpen = false end }) },
    { "scroll", key = "sc", w = "100%", h = "fit", maxH = L.H * 0.6 - 60, dir = "column", gap = 4, pad = 0,
      items = rows, function(x) return x end } }
end

-- THE KEY CARD (§4.3).
local KEYS = {
  { "MOUSE", {
    { "LMB", "select · drag to move" }, { "SHIFT / CTRL+LMB", "add to / toggle in the selection" },
    { "ALT+drag", "move only the selection" }, { "double-click", "select the assembly, then the craft" },
    { "RMB drag", "orbit about the point under the cursor" }, { "RMB click", "the part's menu" },
    { "MMB / SHIFT+RMB", "pan" }, { "wheel", "zoom to the cursor" },
    { "CTRL+wheel", "camera height" }, { "ALT+wheel", "slide along the craft" },
    { "RMB+WASD QE", "fly the camera" } } },
  { "PARTS", {
    { "W/S A/D Q/E", "turn 90° (SHIFT 15°)" }, { "R", "spin on its mount" }, { "SPACE", "reset the turn" },
    { "1 2 3 4", "select · offset · rotate · root" }, { "L", "gizmo space local / world" },
    { "X / SHIFT+X", "symmetry ×1…×8" }, { "M / ALT+M", "mirror (host / centre plane)" },
    { "G / SHIFT+G", "grid / angle snap" }, { "B", "bind a key to the selection" },
    { "DEL / ALT+DEL", "delete (with / without dependents)" }, { "H / ALT+H", "hide / unhide all" } } },
  { "CRAFT", {
    { "CTRL+Z / CTRL+Y", "undo / redo" }, { "CTRL+C V D", "copy · paste · duplicate" },
    { "CTRL+S O N", "save · open · new" }, { "CTRL+F or /", "search the parts" },
    { "T", "TEST the controls" }, { "V", "overlays" }, { "TAB", "next right-panel tab" },
    { "ESC", "back out one level (never leaves)" } } },
  { "CAMERA", {
    { "F / HOME", "frame the selection / the craft" }, { "PGUP / PGDN", "height ±10 %" },
    { "NUM 1 3 7", "front · side · top" }, { "NUM 5", "long lens (near-orthographic)" },
    { "F4", "hide the interface" }, { "F6", "photo orbit" }, { "F12", "screenshot" } } },
}
local function keycard(L)
  local cols = {}
  for i, sec in ipairs(KEYS) do
    local col = { "col", key = "k" .. i, w = "grow", h = "fit", gap = 3, pad = 0, align = "stretch",
      { "text", key = "h", style = "panel/label", w = "100%", h = 18, text = sec[1] } }
    for j, kv in ipairs(sec[2]) do
      col[#col + 1] = { "row", key = "r" .. j, w = "100%", h = "fit", gap = 6, pad = 0, align = "start",
        { "text", key = "k", style = "panel/keys", w = 104, h = "fit", text = kv[1] },
        { "text", key = "d", style = "panel/body", w = "grow", h = "fit", wrap = true, text = kv[2] } }
    end
    cols[#cols + 1] = col
  end
  local w = math.min(L.W - 80, 1000)
  return { "col", key = "card", style = "panel/frame", pin = "top", y = L.toolbar.y + L.toolbar.h + 40,
    w = w, h = "fit", gap = 10, pad = 16,
    { "row", key = "hd", w = "100%", h = 24, gap = 6, pad = 0, align = "center",
      { "text", key = "t", style = "panel/heading", w = "grow", h = 24, text = "Vehicle Assembly keys" },
      key("x", "✕", 26, { style = "panel/secondary", click = function() keysOpen = false end }) },
    { "row", key = "cols", w = "100%", h = "fit", gap = 18, pad = 0, align = "start",
      items = cols, function(x) return x end } }
end

local function describe(B, L)
  local s = bstate(B)
  local tree = {
    { "col", key = "bar", style = "panel/frame", pin = "topLeft", x = L.toolbar.x, y = L.toolbar.y,
      w = L.toolbar.w, h = L.toolbar.h, gap = 4, pad = 6, align = "stretch",
      row1(B, s), row2(B, s) },
    ht(L),
  }
  if libraryOpen then tree[#tree + 1] = library(B, L) end
  if keysOpen then tree[#tree + 1] = keycard(L) end
  return tree, s
end

-- ── panel plumbing ──────────────────────────────────────────────────────────
function openLibrary() libraryOpen = not libraryOpen end
function cycleTab()
  local ins = ref("builder_inspector")
  if ins and ins.cycleTab then ins.cycleTab() end
end

local LAST = { L = nil }
function ownsMouse()
  local L = LAST.L
  if not L then return false end
  local x, y = mouse_du()
  if not x then return false end
  if inside(L.toolbar, x, y) then return true end
  if inside({ x = L.ht.x - 4, y = L.ht.y - 24, w = L.ht.w + 8, h = L.ht.h + 48 }, x, y) then return true end
  if libraryOpen and x > L.toolbar.x + 180 and x < L.toolbar.x + 580 and y < L.H * 0.75 then return true end
  if keysOpen then return true end
  return false
end
function ownsKeys()
  local f = ui and ui.focused and ui.focused()
  return f ~= nil and f.name == "FieldCraftName"
end

local el, registered = nil, false
function start(node)
  el = node.getcomponent and node:getcomponent("UiElement") or nil
end

-- Stretch the host over the whole layer (it is a 10 × 10 pin in the scene).
function fitHost(e, W, H)
  if not e then return end
  if e.visible ~= true then e.visible = true end
  if math.abs((e.width or 0) - W) > 0.5 then e.width = W end
  if math.abs((e.height or 0) - H) > 0.5 then e.height = H end
end

-- Described only when something on it changed: the state, the layer's size,
-- the fader. A described screen costs a table walk; an unchanged one nothing.
local last_sig = nil
local function signature(s, L, B)
  local C = ref("builder_camera")
  local fr = C and C.heightFrac and C.heightFrac() or 0
  return table.concat({ s.tool, tostring(s.sym), tostring(s.mirror), tostring(s.grid), tostring(s.angle),
    s.space, tostring(s.test), tostring(s.overlay), s.site, s.name, tostring(s.canUndo), tostring(s.canRedo),
    tostring(s.block), s.warn and #s.warn or 0, tostring(s.typing), math.floor(L.W), math.floor(L.H),
    math.floor(fr * 200), tostring(keysOpen), tostring(libraryOpen),
    libraryOpen and B.craftList and #B.craftList() or 0 }, "|")
end

function update(node, dt)
  local B = ref("builder")
  if not B then return end
  if not registered and B.registerPanel then registered = B.registerPanel(findScript("builder_toolbar")) end
  if not el then el = node:getcomponent("UiElement") end
  local W, H = layerSize()
  fitHost(el, W, H)
  local L = builderLayout(W, H)
  LAST.L = L
  if input.pressed("/") and input.key("shift") then keysOpen = not keysOpen end
  if (keysOpen or libraryOpen) and input.pressed("escape") then keysOpen, libraryOpen = false, false end
  local sig = signature(bstate(B), L, B)
  if sig == last_sig then return end
  last_sig = sig
  ui.make(node, (describe(B, L)))
end
