-- One DOCKING row in the peripherals panel. `kind` picks what this row is:
--
--   port   — one docking port, drawn with its latch state. Click a latched one
--            and it UNDOCKS: the stack cuts at that seam and the far half flies
--            off as a live craft. `slot` picks which port.
--   assist — the magnetic soft-capture toggle. On, the two ports pull
--            themselves together and damp the relative drift over the last few
--            metres, so the approach is something you fly rather than fight.
--   auto   — the docking AUTOPILOT. On, RCS flies the approach: it kills the
--            lateral miss first, then eases down the target's centreline. Your
--            own translation input always takes the stick back.
--   lock   — hold the berth you're flying to, so the readout, the guides and
--            DOCK ALIGN keep describing THAT port instead of the nearest one.
--   recover — bank this craft's remaining hardware value and go home. Only
--            offered when it's genuinely landed, stopped and near the base.
--   switch — hand the pilot to the next crewed craft. This is the button that
--            makes the whole mission work: undock the lander, click through to
--            it, take it down, come back and latch on again.
--
-- Rows with nothing to say hide themselves so the panel's stack collapses.

defaults = { slot = 1, kind = "port" }

local el, target

local function vessel()
  local panel = findScript("peripheral_panel")
  return panel and panel.pilotedVessel and panel.pilotedVessel()
end

-- Every crewed vessel in the scene, in a stable order — the ring `switch`
-- cycles around.
local function crewedCraft()
  local out = {}
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.node and v.node.valid and v.takeControl then
      out[#out + 1] = v
    end
  end
  table.sort(out, function(a, b) return (a.node.id or 0) < (b.node.id or 0) end)
  return out
end

-- A row's state is a style ("crt/*", ui/solar.uistyle.ron): a line on the
-- device console's CRT — lit phosphor when on, dim when it can't be used.
local me
local function paint(style)
  if me and me.style ~= style then me.style = style end
end

function start(node)
  el = node:getcomponent("UiElement")
  me = node
end

function update(node, dt)
  me = me or node
  if not el then el = node:getcomponent("UiElement") end
  if not el then return end
  local v = vessel()
  if not v then
    el.visible = false
    return
  end
  local kind = params.kind or "port"

  if kind == "assist" then
    local on = v.dock and v.dock.assist
    el.visible = true
    target = nil
    local text = "  MAGNETIC CAPTURE ASSIST      " .. (on and "ON" or "OFF")
    if node.text ~= text then node.text = text end
    if on then
      paint("crt/rowOn")
    else
      paint("crt/row")
    end
    return
  end

  if kind == "auto" then
    local on = v.dock and v.dock.auto
    local has = (v.dock and v.dock.target) ~= nil
    el.visible = true
    target = nil
    local text = "  DOCKING AUTOPILOT (RCS)     " .. (on and "ON" or "OFF")
    if on and not has then text = "  DOCKING AUTOPILOT (RCS)     ON · no target" end
    if node.text ~= text then node.text = text end
    if on then
      paint("crt/rowOn")
    else
      paint("crt/row")
    end
    return
  end

  if kind == "lock" then
    local t = v.dock and v.dock.target
    local locked = (v.dock and v.dock.lock) ~= nil
    el.visible = t ~= nil or locked
    target = nil
    local text
    if locked then
      text = string.format("  ◎ TARGET LOCKED  %s      release",
        (t and t.name) or "craft")
      paint("crt/rowOn")
    else
      text = string.format("  ○ lock target      %s", (t and t.name) or "")
      paint("crt/row")
    end
    if node.text ~= text then node.text = text end
    return
  end

  if kind == "recover" then
    local ok, why = v.recoverReady and v.recoverReady()
    local value = (v.recoverValue and v.recoverValue()) or 0
    el.visible = true
    target = nil
    local text
    if ok then
      text = string.format("  ⌂ RECOVER CRAFT      +$%d", value)
      paint("crt/rowOn")
    else
      text = string.format("  ⌂ recover      %s", why or "unavailable")
      paint("crt/rowDim")
    end
    if node.text ~= text then node.text = text end
    return
  end

  if kind == "switch" then
    local craft = crewedCraft()
    el.visible = #craft > 1
    target = nil
    local text = string.format("  ⇄  SWITCH CRAFT      %d in flight", #craft)
    if node.text ~= text then node.text = text end
    paint("crt/rowAlt")
    return
  end

  local ports = v.dockPorts and v.dockPorts()
  local p = ports and ports[math.floor(params.slot)]
  target = p
  el.visible = p ~= nil
  if not p then return end
  local text
  if p.mate then
    text = string.format("  PORT %d      ● DOCKED        UNDOCK", math.floor(params.slot))
    paint("crt/rowOn")
  elseif p.buried then
    -- A port with hardware on BOTH faces and no partner is a spacer, not a
    -- seam. Say why, or it reads as a broken button.
    text = string.format("  PORT %d      ▪ blocked — needs a second port",
      math.floor(params.slot))
    paint("crt/rowDim")
  else
    text = string.format("  PORT %d      ○ open — ready to mate", math.floor(params.slot))
    paint("crt/row")
  end
  if node.text ~= text then node.text = text end
end

function clicked(node)
  local v = vessel()
  if not v then return end
  local kind = params.kind or "port"
  if kind == "assist" then
    if v.dock then v.dock.assist = not v.dock.assist end
  elseif kind == "auto" then
    if v.dock then v.dock.auto = not v.dock.auto end
  elseif kind == "lock" then
    if v.dockLock then v.dockLock() end
  elseif kind == "recover" then
    if v.recoverCraft then v.recoverCraft() end
  elseif kind == "switch" then
    -- The same step as `]` (scripts/vessel_switcher.lua): the controls move,
    -- the crew stay in their seat.
    local sw = findScript("vessel_switcher")
    if sw and sw.step then sw.step(1) return end
    -- Step to the craft after the one being flown, wrapping around.
    local craft = crewedCraft()
    if #craft < 2 then return end
    local at = 1
    for i, c in ipairs(craft) do
      if c.piloting then at = i end
    end
    for i = 1, #craft do
      local c = craft[(at + i - 1) % #craft + 1]
      if not c.piloting and c.takeControl() then return end
    end
  elseif target and target.mate then
    v.undock(target.uid)
  end
end

-- Hover is the style's own `hover` block.
