-- BUILDER_CONTEXT — the part menu, on a right-click that doesn't drag
-- (docs/builder-design.md §4.5; WP2).
--
--   ┌ SERVO HINGE ×2 ───────────┐
--   │ Inspect                 ⏎ │
--   │ CONTROLS  Angle +   [ 6 ] │   a keycap opens the bind prompt (WP5)
--   │ Select  assembly ring same│
--   │ Copy  ^C     Duplicate ^D │
--   │ Make sub-assembly         │
--   │ Set as root · Detach      │
--   │ Hide                    H │
--   │ Delete                DEL │
--   └───────────────────────────┘
--
-- The click is the camera's (builder_camera.rmbClick: an RMB press that never
-- moved 4 px, with the part that was under it). The menu acts on the part and
-- the selection through the builder's API only; any entry the builder can't do
-- yet is shown dimmed rather than hidden, so the menu doesn't change shape.
-- ESC (the builder calls close()), a click elsewhere or any entry closes it.

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end

local W_MENU, ROW = 244, 22
local st = { open = false, uid = nil, x = 0, y = 0, seq = nil, rect = nil, sig = nil, built = false }

function isOpen() return st.open end
function close() st.open = false; st.sig = nil end

-- Open the menu for a part at a point in design units (probes call it too).
function openFor(uid, x, y)
  local B = ref("builder")
  if not (B and uid and B.partRec(uid)) then return false end
  -- The menu works on the selection; a click on a part outside it selects it.
  local sel = B.selection and B.selection() or {}
  local inside = false
  for _, u in ipairs(sel) do if u == uid then inside = true end end
  if not inside and B.select then B.select({ uid }, "set") end
  st.open, st.uid, st.x, st.y, st.sig = true, uid, x or 400, y or 300, nil
  return true
end

local function sel_uids(B)
  local s = B.selection and B.selection() or {}
  if #s == 0 then s = { st.uid } end
  return s
end

-- The entries, as data (the smoke test reads them): { key, label, hint,
-- enabled, act, kind = "item"|"control"|"select"|"danger" }.
function entries(B, uid)
  local rec = B.partRec(uid)
  if not rec then return {} end
  local out = {}
  local function item(k, label, hint, enabled, act, kind)
    out[#out + 1] = { key = k, label = label, hint = hint, enabled = enabled and true or false, act = act,
                      kind = kind or "item" }
  end
  item("inspect", "Inspect", "⏎", true, function()
    local ins = ref("builder_inspector")
    if ins and ins.setTab then ins.setTab("INSPECT") end
  end)
  local ins = ref("builder_inspector")
  local acts = (ins and ins.controlsOf) and ins.controlsOf(B, rec) or {}
  for i, a in ipairs(acts) do
    if i > 5 then break end
    out[#out + 1] = { key = "ctl" .. i, label = a.label, hint = a.key or "—", enabled = true, kind = "control",
      act = function()
        local bb = ref("builder_bind")
        if bb and bb.begin then bb.begin(sel_uids(B), a.id)
        elseif B.hint then B.hint("binding arrives with the Controls tab (B)", 2.5) end
      end }
  end
  item("sel", "Select", nil, B.selectConnected ~= nil, nil, "select")
  item("copy", "Copy", "CTRL+C", B.copy ~= nil, function() B.copy(sel_uids(B)) end)
  item("dup", "Duplicate", "CTRL+D", B.duplicate ~= nil, function() B.duplicate(sel_uids(B)) end)
  item("subassy", "Make sub-assembly", nil, B.makeSubAssembly ~= nil, function()
    local u = sel_uids(B)
    local nm = string.format("%s ×%d", (rec.def and rec.def.label) or "Assembly", #u)
    B.makeSubAssembly(nm, u)
    if B.hint then B.hint("sub-assembly saved — " .. nm, 2.5) end
  end)
  item("root", "Set as root", nil, B.root ~= nil, function() B.cmd("root", { uid = uid }) end)
  item("detach", "Detach (keep dependents)", nil, B.root ~= nil, function() B.cmd("detach", { uids = sel_uids(B) }) end)
  item("hide", "Hide", "H", B.hiddenUids ~= nil, function() B.cmd("hide", { uids = sel_uids(B), on = true }) end)
  item("delete", "Delete", "DEL", true, function() B.cmd("delete", { uids = sel_uids(B) }) end, "danger")
  return out, rec, acts
end

local SELECT_SCOPES = { { "assembly", "assembly" }, { "ring", "ring" }, { "same", "same part" } }

local function describe(B, L)
  local list, rec = entries(B, st.uid)
  if not rec then return nil end
  local def = rec.def or {}
  local n = #(B.selection and B.selection() or {})
  local title = (def.label or rec.id) .. (n > 1 and ("  ×" .. n) or "")
  local rows = {}
  local had_ctl = false
  for _, e in ipairs(list) do
    if e.kind == "control" and not had_ctl then
      had_ctl = true
      rows[#rows + 1] = { "text", key = "chd", style = "panel/label", w = "100%", h = 16, text = "CONTROLS", textValign = "end" }
    end
    if e.kind == "select" then
      local r = { "row", key = e.key, w = "100%", h = ROW, gap = 3, pad = 0, align = "center",
        { "text", key = "l", style = "panel/cell", w = 50, h = ROW, text = "Select", textValign = "center" } }
      for _, sc in ipairs(SELECT_SCOPES) do
        r[#r + 1] = { "button", key = sc[1], style = "panel/secondary", w = "grow", h = ROW, text = sc[2],
          textAlign = "center", textValign = "center", disabled = not e.enabled,
          onClicked = function() B.selectConnected(st.uid, sc[1]); close() end }
      end
      rows[#rows + 1] = r
    elseif e.kind == "control" then
      rows[#rows + 1] = { "row", key = e.key, w = "100%", h = ROW, gap = 4, pad = 0, align = "center",
        { "text", key = "l", style = "panel/cell", w = "grow", h = ROW, text = e.label, textValign = "center",
          maxLines = 1, overflow = "ellipsis" },
        { "button", key = "k", style = "panel/choice", selected = e.hint ~= "—", w = 36, h = ROW, text = e.hint,
          textAlign = "center", textValign = "center", tooltip = "Bind a key to this",
          onClicked = function() e.act(); close() end } }
    else
      if e.key == "copy" then rows[#rows + 1] = { "box", key = "rule1", style = "panel/rule", w = "100%", h = 1 } end
      if e.key == "delete" then rows[#rows + 1] = { "box", key = "rule2", style = "panel/rule", w = "100%", h = 1 } end
      rows[#rows + 1] = { "button", key = e.key, style = e.kind == "danger" and "panel/danger" or "panel/row",
        w = "100%", h = ROW, dir = "row", gap = 6, pad = 4, align = "center", disabled = not e.enabled,
        tooltip = (not e.enabled) and "Not in this build yet" or nil,
        onClicked = function() if e.enabled and e.act then e.act() end close() end,
        { "text", key = "l", style = "panel/cell", w = "grow", h = ROW - 4, text = e.label, textValign = "center" },
        e.hint and { "text", key = "h", style = "panel/keys", w = "fit", h = ROW - 4, text = e.hint, textValign = "center" } or nil }
    end
  end
  -- Height: rows + heading + pads; kept inside the layer.
  local h = 30 + 16
  for _, r in ipairs(rows) do h = h + ((r.h == 1) and 1 or (r.h or ROW)) + 3 end
  local x = math.max(4, math.min(st.x + 6, L.W - W_MENU - 4))
  local y = math.max(4, math.min(st.y + 6, L.H - h - 4))
  st.rect = { x = x, y = y, w = W_MENU, h = h }
  return { "col", key = "menu", style = "hud/tooltip", pin = "topLeft", x = x, y = y, w = W_MENU, h = "fit",
    gap = 3, pad = 8, align = "stretch",
    { "text", key = "title", style = "panel/title", w = "100%", h = 18, text = title, maxLines = 1, overflow = "ellipsis" },
    { "col", key = "rows", w = "100%", h = "fit", gap = 3, pad = 0, align = "stretch", items = rows,
      function(x2) return x2 end } }
end

-- ── panel plumbing ──────────────────────────────────────────────────────────
local function mouse_du(H)
  if not (camera and camera.screenSize) then return nil end
  local sw, sh = camera.screenSize()
  if not (sh and sh > 0) then return nil end
  local mx, my = input.mouse()
  local ox, oy = 0, 0
  if camera.screenRect then ox, oy = camera.screenRect() end
  return (mx - (ox or 0)) * H / sh, (my - (oy or 0)) * H / sh, sh
end
local LAST = { H = 720 }
function ownsMouse()
  if not (st.open and st.rect) then return false end
  local x, y = mouse_du(LAST.H)
  local r = st.rect
  return x ~= nil and x >= r.x - 4 and x <= r.x + r.w + 4 and y >= r.y - 4 and y <= r.y + r.h + 4
end

local el, registered = nil, false
local lmb_prev = false
function start(node) el = node.getcomponent and node:getcomponent("UiElement") or nil end

function update(node, dt)
  local B = ref("builder")
  if not (B and B.partRec) then return end
  if not registered and B.registerPanel then registered = B.registerPanel(findScript("builder_context")) end
  if not el then el = node:getcomponent("UiElement") end
  local tb = ref("builder_toolbar")
  local W, H = 1280, 720
  if tb and tb.layerSize then W, H = tb.layerSize() end
  if tb and tb.fitHost then tb.fitHost(el, W, H) end
  LAST.H = H
  -- A fresh right-click from the camera.
  local cam = ref("builder_camera")
  local c = cam and cam.rmbClick
  if c and c.seq and c.seq ~= st.seq then
    local first = st.seq == nil
    st.seq = c.seq
    if not first then
      local held = B.held and B.held()
      if c.uid and not held then
        local _, _, sh = mouse_du(H)
        local k = (sh and sh > 0) and H / sh or 1
        openFor(c.uid, c.x * k, c.y * k)
      else
        close()
      end
    end
  end
  -- A left click outside closes it; ESC too (the builder also calls close()).
  local lmb = input.button(0)
  if st.open and lmb and not lmb_prev and not ownsMouse() then close() end
  lmb_prev = lmb
  if st.open and input.pressed("escape") then close() end
  if st.open and not B.partRec(st.uid) then close() end
  local sig = st.open and table.concat({ st.uid, st.x, st.y, tostring(B.craftVersion), math.floor(W), math.floor(H),
    table.concat(B.selection and B.selection() or {}, ",") }, "|") or "closed"
  if sig == st.sig then return end
  st.sig = sig
  if not st.open then
    st.rect = nil
    ui.make(node, {})
    return
  end
  local tree = describe(B, { W = W, H = H })
  ui.make(node, tree and { tree } or {})
end
