-- ACTION GROUPS PANEL — the builder's editor for what each key does in flight.
--
-- Tool 5 in the Vehicle Assembly. Three steps, top to bottom, the way you
-- actually do it:
--
--   1. pick a GROUP — the standard ones (Gear G, Deploy U, Lights Y, Brakes B,
--      RCS R, SAS T, Abort ⌫) or a custom 1–0; each chip shows how many
--      actions it holds
--   2. click a PART on the craft (it outlines; parts already in the open group
--      outline amber)
--   3. tick the ACTIONS that part should run when the key is pressed —
--      Extend, Retract, Toggle, Decouple, Shut down… whatever its modules
--      declare (scripts/electronics.lua). A symmetry ring ticks as one.
--
-- Under that, the open group's whole list, each line with its own ✕. Staging is
-- untouched by any of this: a decoupler can be in a group AND in the stack.
--
-- The rules (what's bound, the standard set, symmetry) are the builder's
-- (`groupsNow`, `groupsToggle` …); this script only draws and clicks.

local el
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

local W = 300
local KEY_LABEL = { backspace = "⌫" }

local function key_of(g)
  local k = g.key or ""
  return KEY_LABEL[k] or k:upper()
end

-- A group chip: its name and key, the count in the corner.
local function chip(B, E, g, groups, sel, w)
  local n = 0
  local gg = groups[g.id]
  if gg then n = #gg.binds end
  local label = g.standard and (g.label .. "  " .. key_of(g)) or key_of(g)
  return { "button", key = "g" .. g.id, style = "panel/choice", selected = sel == g.id,
    w = w, h = 26, textAlign = "center", textValign = "center",
    text = n > 0 and (label .. "  ·" .. n) or label,
    tooltip = string.format("%s — key %s · %d action%s", (gg and gg.name) or g.label, key_of(g), n,
      n == 1 and "" or "s"),
    onClicked = function() B.groupsSelect(g.id) end }
end

-- The open group's list, one line per (part label, action), symmetry rings
-- collapsed to ×N so a four-leg ring is one line.
local function bound_rows(B, E, groups, recs, gid)
  local gg = groups[gid]
  local rows = {}
  if not gg or #gg.binds == 0 then
    rows[1] = { "text", key = "none", style = "panel/cellMuted", w = "100%", h = "fit", wrap = true,
      text = "Nothing in this group yet — click a part on the craft, then tick its actions." }
    return rows
  end
  local seen, order = {}, {}
  for _, b in ipairs(gg.binds) do
    local rec = recs[b.uid]
    if rec then
      local act = E.actionOf(rec, b.act)
      local ring = rec.sym and ("s" .. rec.sym) or ("u" .. b.uid)
      local k = ring .. "|" .. b.act
      if not seen[k] then
        seen[k] = { label = rec.label or rec.id or "part", act = act and act.label or b.act, n = 0,
                    uid = b.uid, actid = b.act }
        order[#order + 1] = k
      end
      seen[k].n = seen[k].n + 1
    end
  end
  for i, k in ipairs(order) do
    local e = seen[k]
    rows[#rows + 1] = { "row", key = "b" .. i, w = "100%", h = 24, gap = 6, pad = 0, align = "center",
      { "text", key = "p", style = "panel/cellStrong", w = "grow", h = "fit", maxLines = 1, overflow = "ellipsis",
        text = e.label .. (e.n > 1 and ("  ×" .. e.n) or "") },
      { "text", key = "a", style = "panel/cellMuted", w = 110, h = "fit", maxLines = 1, overflow = "ellipsis",
        textAlign = "end", text = e.act },
      { "button", key = "x", style = "panel/secondary", w = 24, h = 22, text = "✕",
        textAlign = "center", textValign = "center", tooltip = "Take it out of this group",
        onClicked = function() B.groupsToggle(gid, e.uid, e.actid) end } }
  end
  return rows
end

-- The selected part's actions as tick rows for the open group.
local function part_rows(B, E, groups, recs, gid)
  local uid = B.selectedPart()
  local rec = uid and recs[uid]
  local rows = {}
  if not rec then
    rows[1] = { "text", key = "pick", style = "panel/cellMuted", w = "100%", h = "fit", wrap = true,
      text = "Click a part on the craft to see what it can do." }
    return rows
  end
  local acts = E.actionsOf(rec)
  rows[#rows + 1] = { "text", key = "pl", style = "panel/cellStrong", w = "100%", h = "fit",
    text = (rec.label or rec.id or "part") .. (rec.sym and "  (ring — edits every member)" or "") }
  if #acts == 0 then
    rows[#rows + 1] = { "text", key = "noact", style = "panel/cellMuted", w = "100%", h = "fit", wrap = true,
      text = "Nothing to switch on this part — it's structure." }
    return rows
  end
  for i, a in ipairs(acts) do
    local on = E.isBound(groups, gid, uid, a.id)
    local elsewhere = {}
    for _, g2 in ipairs(E.groupsOf(groups, uid, a.id)) do
      if g2 ~= gid then elsewhere[#elsewhere + 1] = key_of(E.groupInfo(g2) or { key = g2 }) end
    end
    rows[#rows + 1] = { "button", key = "a" .. i, style = "panel/row", selected = on,
      w = "100%", h = 26, dir = "row", gap = 8, align = "center",
      { "text", key = "c", style = on and "panel/keys" or "panel/cellMuted", w = 14, h = "fit",
        text = on and "☑" or "☐" },
      { "text", key = "t", style = "panel/cellStrong", w = "grow", h = "fit", text = a.label },
      { "text", key = "o", style = "panel/cellMuted", w = "fit", h = "fit",
        text = #elsewhere > 0 and ("also " .. table.concat(elsewhere, " ")) or "" },
      onClicked = function() B.groupsToggle(gid, uid, a.id) end }
  end
  return rows
end

local function describe(B, E)
  local groups, recs = B.groupsNow()
  groups = groups or {}
  recs = recs or {}
  local gid = B.groupsSelected() or "1"
  local info = E.groupInfo(gid) or { label = gid, key = gid }
  local list = E.groupList()
  local std, cus = {}, {}
  for _, g in ipairs(list) do
    if g.standard then std[#std + 1] = g else cus[#cus + 1] = g end
  end
  local function grid(set, per, key)
    local rows = {}
    local cw = math.floor((W - 2 * 12 - (per - 1) * 4) / per)
    for r = 1, math.ceil(#set / per) do
      local kids = {}
      for c = 1, per do
        local g = set[(r - 1) * per + c]
        if g then kids[#kids + 1] = chip(B, E, g, groups, gid, cw) end
      end
      rows[#rows + 1] = { "row", key = key .. r, w = "100%", h = 26, gap = 4, pad = 0,
                          items = kids, function(k) return k end }
    end
    return rows
  end
  local body = {}
  local function add(x) body[#body + 1] = x end
  add({ "row", key = "head", w = "100%", h = "fit", gap = 8, pad = 0, align = "center",
    { "text", key = "t", style = "panel/heading", w = "grow", h = "fit", text = "Action groups" },
    { "text", key = "s", style = "panel/cellMuted", w = "fit", h = "fit",
      text = B.groupsEdited() and "edited" or "standard set" } })
  add({ "text", key = "lead", style = "panel/hint", w = "100%", h = "fit", wrap = true,
    text = "A group is a key in flight. Pick one, click a part, tick what it does. Staging is separate — nothing here changes it." })
  for _, r in ipairs(grid(std, 3, "std")) do add(r) end
  for _, r in ipairs(grid(cus, 5, "cus")) do add(r) end
  add({ "box", key = "r1", style = "panel/rule", w = "100%", h = 1 })
  local gg = groups[gid]
  add({ "text", key = "gl", style = "panel/label", w = "100%", h = "fit",
    text = string.format("%s  ·  key %s", (gg and gg.name) or info.label, key_of(info)) })
  for _, r in ipairs(bound_rows(B, E, groups, recs, gid)) do add(r) end
  add({ "box", key = "r2", style = "panel/rule", w = "100%", h = 1 })
  add({ "text", key = "ll", style = "panel/label", w = "100%", h = "fit", text = "Selected part" })
  for _, r in ipairs(part_rows(B, E, groups, recs, gid)) do add(r) end
  add({ "box", key = "r3", style = "panel/rule", w = "100%", h = 1 })
  add({ "row", key = "btns", w = "100%", h = 30, gap = 6, pad = 0,
    { "button", key = "clear", style = "panel/secondary", w = "grow", h = 30, textAlign = "center",
      textValign = "center", text = "Clear group", disabled = not (gg and #gg.binds > 0),
      onClicked = function() B.groupsClear(gid) end },
    { "button", key = "reset", style = "panel/secondary", w = "grow", h = 30, textAlign = "center",
      textValign = "center", text = "Standard set", disabled = not B.groupsEdited(),
      tooltip = "Throw away your edits: legs on Gear, panels and antennas on Deploy, lights on Lights",
      onClicked = function() B.groupsReset() end } })
  return { "col", key = "groups", style = "panel/frame", w = "100%", h = "fit", gap = 6, pad = 12,
           align = "start", items = body, function(x) return x end }
end

function start(node)
  el = node:getcomponent("UiElement")
  if el then el.visible = false end
end

function update(node, dt)
  if not el then el = node:getcomponent("UiElement") end
  local B, E = ref("builder"), ref("electronics")
  local show = B ~= nil and E ~= nil and B.groupsTool and B.groupsTool()
  if el and el.visible ~= (show and true or false) then el.visible = show and true or false end
  if not show then return end
  ui.make(node, describe(B, E))
end
