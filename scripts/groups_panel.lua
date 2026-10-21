-- ACTION GROUPS PANEL — the builder's editor for what each key does in flight.
--
-- (The same frame shows a selected WHEEL's settings outside the groups tool:
-- describe_wheel, at the bottom.)
--
-- Tool 5 in the Vehicle Assembly. Three steps, top to bottom, the way you
-- actually do it:
--
--   1. pick a GROUP — the standard ones (Gear G, Deploy U, Lights Y, Brakes B,
--      RCS R, SAS T, Abort ⌫) or a custom 1–0; each chip shows how many
--      actions it holds
--   2. pick a PART — from "Controls on this craft" (every part with a switch,
--      actuators first, each with the keys it is on) or by clicking it on the
--      craft (it outlines; parts already in the open group outline amber)
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

-- What the craft can DO, at a glance: one chip per part (a symmetry ring is one
-- chip) that has anything to switch, ACTUATORS FIRST — pistons, hinges,
-- rotors, the drill, the claw — then the rest. Each chip names the keys its
-- actions are on, so "where are my robotics?" is answered without hunting for
-- the part on the craft; clicking one selects that part below.
--
-- (It used to be click-a-part-or-nothing: a piston you couldn't find on the
-- craft, or whose twelve actions ran off the bottom of the screen, was "not in
-- my action groups".)
local function controls_rows(B, E, groups, recs)
  local list = {}
  for _, rec in pairs(recs) do list[#list + 1] = rec end
  table.sort(list, function(a, b)
    local aa, ba = E.actuatorOf and E.actuatorOf(a) ~= nil, E.actuatorOf and E.actuatorOf(b) ~= nil
    if aa ~= ba then return aa end
    return (a.uid or 0) < (b.uid or 0)
  end)
  local sel = B.selectedPart and B.selectedPart()
  local selrec = sel and recs[sel]
  local seen, chips, actuators, loose = {}, {}, 0, 0
  for _, rec in ipairs(list) do
    local ring = (rec.sym and rec.sym ~= 0) and ("s" .. rec.sym) or ("u" .. rec.uid)
    local acts = E.actionsOf(rec)
    if #acts > 0 and not seen[ring] then
      seen[ring] = { n = 0 }
      local act = E.actuatorOf and E.actuatorOf(rec)
      local keys, kseen = {}, {}
      for _, b in ipairs(E.bindsOfPart(groups, rec.uid)) do
        if not kseen[b.gid] then
          kseen[b.gid] = true
          keys[#keys + 1] = key_of(E.groupInfo(b.gid) or { key = b.gid })
        end
      end
      if act then
        actuators = actuators + 1
        if #keys == 0 then loose = loose + 1 end
      end
      local on = selrec and ((selrec.sym and selrec.sym ~= 0 and selrec.sym == rec.sym) or selrec.uid == rec.uid)
      local n = 0
      for _, r2 in pairs(recs) do if r2.sym and r2.sym ~= 0 and r2.sym == rec.sym then n = n + 1 end end
      chips[#chips + 1] = { "button", key = "p" .. rec.uid, style = "panel/choice", selected = on and true or false,
        w = "fit", h = 24, dir = "row", gap = 6, pad = 4, align = "center",
        tooltip = act and "An actuator — give it keys below, then hold or press them in flight"
          or "Click to see what this part can do",
        { "text", key = "n", style = act and "panel/cellStrong" or "panel/cell", w = "fit", h = "fit",
          text = (rec.label or rec.id or "part") .. (n > 1 and ("  ×" .. n) or "") },
        { "text", key = "k", style = (#keys > 0) and "panel/keys" or "panel/cellMuted", w = "fit", h = "fit",
          text = (#keys > 0) and table.concat(keys, " ") or "—" },
        onClicked = function() if B.selectPart then B.selectPart(rec.uid) end end }
    end
  end
  local rows = {}
  if #chips == 0 then
    rows[1] = { "text", key = "noctl", style = "panel/cellMuted", w = "100%", h = "fit", wrap = true,
      text = "Nothing on this craft has a switch yet." }
    return rows
  end
  rows[1] = { "row", key = "ctl", wrap = true, w = "100%", h = "fit", gap = 4, pad = 0 }
  for _, c in ipairs(chips) do rows[1][#rows[1] + 1] = c end
  if loose > 0 and B.groupsAutoActuators then
    rows[#rows + 1] = { "button", key = "auto", style = "panel/action", w = "100%", h = 28, textAlign = "center",
      textValign = "center",
      text = string.format("Give %s a key  (1–0)", loose == 1 and "the actuator" or ("all " .. loose .. " actuators")),
      tooltip = "Pistons extend on one key, hinges swing on two (held), rotors, drills and claws switch on one",
      onClicked = function() B.groupsAutoActuators() end }
  end
  return rows
end

-- One tickable action chip: ☐/☑ and the action's name.
local function act_chip(B, E, groups, gid, uid, a, i)
  local on = E.isBound(groups, gid, uid, a.id)
  local elsewhere = {}
  for _, g2 in ipairs(E.groupsOf(groups, uid, a.id)) do
    if g2 ~= gid then elsewhere[#elsewhere + 1] = key_of(E.groupInfo(g2) or { key = g2 }) end
  end
  return { "button", key = "a" .. i, style = "panel/row", selected = on,
    w = "fit", h = 24, dir = "row", gap = 5, pad = 4, align = "center",
    tooltip = #elsewhere > 0 and ("also on " .. table.concat(elsewhere, " ")) or nil,
    { "text", key = "c", style = on and "panel/keys" or "panel/cellMuted", w = 14, h = "fit",
      text = on and "☑" or "☐" },
    { "text", key = "t", style = "panel/cellStrong", w = "fit", h = "fit", text = a.label },
    { "text", key = "o", style = "panel/cellMuted", w = "fit", h = "fit",
      text = #elsewhere > 0 and table.concat(elsewhere, " ") or "" },
    onClicked = function() B.groupsToggle(gid, uid, a.id) end }
end

-- The selected part's actions as tick chips for the open group, one line per
-- switch (Extend · Retract · Extend / retract) and per setting (Angle + · − ·
-- centre · → +90° · → −90°), so a piston's twelve actions take four lines.
local function part_rows(B, E, groups, recs, gid)
  local uid = B.selectedPart()
  local rec = uid and recs[uid]
  local rows = {}
  if not rec then
    rows[1] = { "text", key = "pick", style = "panel/cellMuted", w = "100%", h = "fit", wrap = true,
      text = "Click a part above, or on the craft, to see what it can do." }
    return rows
  end
  local acts = E.actionsOf(rec)
  rows[#rows + 1] = { "text", key = "pl", style = "panel/cellStrong", w = "100%", h = "fit",
    text = (rec.label or rec.id or "part") .. (rec.sym and rec.sym ~= 0 and "  (ring — edits every member)" or "") }
  if #acts == 0 then
    rows[#rows + 1] = { "text", key = "noact", style = "panel/cellMuted", w = "100%", h = "fit", wrap = true,
      text = "Nothing to switch on this part — it's structure." }
    return rows
  end
  local lines, order, axes = {}, {}, false
  for i, a in ipairs(acts) do
    local lk = a.state or a.axis or ("t" .. a.id)
    if not lines[lk] then lines[lk] = {}; order[#order + 1] = lk end
    lines[lk][#lines[lk] + 1] = act_chip(B, E, groups, gid, uid, a, i)
    if a.kind == "axis" and a.dir ~= 0 then axes = true end
  end
  local list = {}
  for li, lk in ipairs(order) do
    local row = { "row", key = "l" .. li, wrap = true, w = "100%", h = "fit", gap = 4, pad = 0 }
    for _, c in ipairs(lines[lk]) do row[#row + 1] = c end
    list[#list + 1] = row
  end
  if axes then
    list[#list + 1] = { "text", key = "axhint", style = "panel/hint", w = "100%", h = "fit", wrap = true,
      text = "+ and − move it while the group's key is HELD (let go to stop there); → and centre go straight there on a press." }
  end
  local sc = { "scroll", key = "acts", w = "100%", h = "fit", maxH = 150, gap = 4, pad = 0, dir = "col" }
  for _, r in ipairs(list) do sc[#sc + 1] = r end
  rows[#rows + 1] = sc
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
    local cw = math.floor((W - 2 * 10 - (per - 1) * 4) / per)
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
    text = "A group is a key in flight. Pick one, pick a part, tick what it does. Staging is separate." })
  for _, r in ipairs(grid(std, 3, "std")) do add(r) end
  for _, r in ipairs(grid(cus, 5, "cus")) do add(r) end
  add({ "box", key = "r1", style = "panel/rule", w = "100%", h = 1 })
  local gg = groups[gid]
  add({ "text", key = "gl", style = "panel/label", w = "100%", h = "fit",
    text = string.format("%s  ·  key %s", (gg and gg.name) or info.label, key_of(info)) })
  local bl = { "scroll", key = "bound", w = "100%", h = "fit", maxH = 76, gap = 2, pad = 0, dir = "col" }
  for _, r in ipairs(bound_rows(B, E, groups, recs, gid)) do bl[#bl + 1] = r end
  add(bl)
  add({ "box", key = "r2", style = "panel/rule", w = "100%", h = 1 })
  add({ "text", key = "cl", style = "panel/label", w = "100%", h = "fit", text = "Controls on this craft" })
  for _, r in ipairs(controls_rows(B, E, groups, recs)) do add(r) end
  add({ "box", key = "r4", style = "panel/rule", w = "100%", h = 1 })
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
  return { "col", key = "groups", style = "panel/frame", w = "100%", h = "fit", gap = 5, pad = 10,
           align = "start", items = body, function(x) return x end }
end

-- ── WHEEL SETTINGS (the same frame, when a wheel is selected) ───────────────
-- How the selected wheel steers and drives, its suspension and its grip: the
-- builder's wheelCfg / wheelSet / wheelFlip / wheelApply / wheelReset hold the
-- rules (and write `wcfg` into the craft record). The arrow beside each wheel
-- on the stand shows which way it will roll the craft when W is pressed.
local MODE_TIP = {
  steer = { auto = "steers if it's ahead of the centre of mass", on = "always steers", off = "never steers",
            invert = "steers the other way (rear steer)" },
  drive = { auto = "pushes the craft forward on W", on = "always driven", off = "rolls free",
            invert = "pushes the other way" },
}

local function chips(B, uid, key, cur, label, tip_set)
  local row = { "row", key = "m" .. key, w = "100%", h = "fit", gap = 4, pad = 0, align = "center",
    { "text", key = "l", style = "panel/cell", w = 70, h = "fit", text = label } }
  for _, m in ipairs({ "auto", "on", "off", "invert" }) do
    row[#row + 1] = { "button", key = m, style = "panel/choice", selected = cur == m, w = "grow", h = 24,
      textAlign = "center", textValign = "center", text = m, tooltip = tip_set[m],
      onClicked = function() B.wheelSet(uid, key, m) end }
  end
  return row
end

local function wslider(B, uid, key, label, cur, lo, hi, show)
  return { "row", key = "s" .. key, w = "100%", h = 24, gap = 6, pad = 0, align = "center",
    { "text", key = "l", style = "panel/cell", w = 70, h = "fit", text = label },
    -- A fader ("ctl/*" styles): groove, orange strip, light cap.
    { "slider", key = "s", style = "ctl/track", w = "grow", h = 12, min = lo, max = hi, value = cur, interact = true,
      onChanged = function(n)
        local sl = n and n:getcomponent("UiSlider")
        if sl and sl.value then B.wheelSet(uid, key, sl.value, true) end
      end,
      { "box", key = "f", style = "ctl/fill", part = "fill", w = "100%", h = "100%" },
      { "box", key = "h", style = "ctl/handle", part = "handle", w = 10, h = 18 } },
    { "text", key = "v", style = "ctl/value", w = 52, h = "fit", textAlign = "end", text = show(cur) } }
end

local function pct(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end
local function times(v) return string.format("×%.2f", v) end

local function describe_wheel(B, uid)
  local c = B.wheelCfg(uid)
  local info = B.partInfo and B.partInfo(B.partIdOf(uid)) or {}
  local plan = B.wheelPlan and B.wheelPlan() or {}
  local me
  for _, w in ipairs(plan) do if w.uid == uid then me = w end end
  local status
  if not me then status = ""
  elseif me.upright then status = "⚠ its axle stands upright — it can't roll"
  elseif me.sideways then status = "⚠ its axle points along the craft's travel — it would roll sideways. Mount it on a side face."
  else
    status = (me.drives and (c.drive == "invert" and "drives (inverted)" or "drives") or "rolls free")
      .. "  ·  " .. (me.steers and string.format("steers ±%d°", math.floor(c.steerMax + 0.5)) or "doesn't steer")
  end
  local body = {}
  local function add(x) body[#body + 1] = x end
  add({ "row", key = "head", w = "100%", h = "fit", gap = 8, pad = 0, align = "center",
    { "text", key = "t", style = "panel/heading", w = "grow", h = "fit", text = "Wheel settings" },
    { "text", key = "s", style = "panel/cellMuted", w = "fit", h = "fit", text = info.label or "wheel" } })
  add({ "text", key = "lead", style = "panel/hint", w = "100%", h = "fit", wrap = true,
    text = "W/S drive, A/D steer. The arrow by each wheel is the way it rolls the craft on W; the blue arc is how far it steers." })
  add({ "text", key = "st", style = (me and (me.sideways or me.upright)) and "panel/hintWarn" or "panel/cellStrong",
    w = "100%", h = "fit", wrap = true, text = status })
  add({ "box", key = "r1", style = "panel/rule", w = "100%", h = 1 })
  local sc = { "scroll", key = "ws", w = "100%", h = "fit", maxH = 330, gap = 5, pad = 0, dir = "col" }
  local function put(x) sc[#sc + 1] = x end
  put(chips(B, uid, "steer", c.steer, "Steer", MODE_TIP.steer))
  put(wslider(B, uid, "steerMax", "Steer max", c.steerMax, 0, 45, function(v) return string.format("%d°", math.floor(v + 0.5)) end))
  put(chips(B, uid, "drive", c.drive, "Drive", MODE_TIP.drive))
  put({ "button", key = "flip", style = "panel/secondary", w = "100%", h = 26, textAlign = "center", textValign = "center",
    text = "⇄  Flip direction", tooltip = "Make this wheel push the other way (drive: invert)",
    onClicked = function() B.wheelFlip(uid) end })
  put(wslider(B, uid, "motor", "Motor", c.motor, 0, 1, pct))
  put(wslider(B, uid, "brake", "Brake", c.brake, 0, 1, pct))
  put({ "text", key = "susp", style = "panel/label", w = "100%", h = "fit", text = "Suspension and tyre" })
  put(wslider(B, uid, "spring", "Spring", c.spring, 0.25, 4, times))
  put(wslider(B, uid, "damper", "Damper", c.damper, 0.25, 4, times))
  put(wslider(B, uid, "travel", "Travel", c.travel, 0.03, 0.5, function(v) return string.format("%.2f m", v) end))
  put(wslider(B, uid, "friction", "Grip", c.friction, 0.5, 2, times))
  put({ "row", key = "skid", w = "100%", h = "fit", gap = 4, pad = 0, align = "center",
    { "text", key = "l", style = "panel/cell", w = 70, h = "fit", text = "Skid steer" },
    { "button", key = "on", style = "panel/choice", selected = c.skid == true, w = "grow", h = 24, textAlign = "center",
      textValign = "center", text = "on", tooltip = "Also turn by driving the two sides against each other (tank turn)",
      onClicked = function() B.wheelSet(uid, "skid", true) end },
    { "button", key = "off", style = "panel/choice", selected = c.skid ~= true, w = "grow", h = 24, textAlign = "center",
      textValign = "center", text = "off", onClicked = function() B.wheelSet(uid, "skid", false) end } })
  add(sc)
  add({ "box", key = "r2", style = "panel/rule", w = "100%", h = 1 })
  add({ "row", key = "apply", w = "100%", h = 28, gap = 6, pad = 0,
    { "button", key = "sym", style = "panel/secondary", w = "grow", h = 28, textAlign = "center", textValign = "center",
      text = "Apply to pair/ring", tooltip = "Copy these settings to this wheel's symmetry partners",
      onClicked = function() B.wheelApply(uid, "sym") end },
    { "button", key = "all", style = "panel/secondary", w = "grow", h = 28, textAlign = "center", textValign = "center",
      text = "Apply to all wheels", onClicked = function() B.wheelApply(uid, "all") end } })
  add({ "button", key = "reset", style = "panel/secondary", w = "100%", h = 26, textAlign = "center", textValign = "center",
    text = "Defaults", tooltip = "Back to the defaults — what a rover built the obvious way drives right with",
    onClicked = function() B.wheelReset(uid) end })
  return { "col", key = "wheel", style = "panel/frame", w = "100%", h = "fit", gap = 5, pad = 10,
           align = "start", items = body, function(x) return x end }
end

function start(node)
  el = node:getcomponent("UiElement")
  if el then el.visible = false end
end

function update(node, dt)
  if not el then el = node:getcomponent("UiElement") end
  local B, E = ref("builder"), ref("electronics")
  local groups = B ~= nil and E ~= nil and B.groupsTool and B.groupsTool()
  local wheel = B ~= nil and not groups and B.wheelSelected and B.wheelSelected() or nil
  local show = groups or wheel ~= nil
  if el and el.visible ~= (show and true or false) then el.visible = show and true or false end
  if not show then return end
  if wheel then ui.make(node, describe_wheel(B, wheel)) else ui.make(node, describe(B, E)) end
end
