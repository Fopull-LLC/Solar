-- One DEVICE row in the peripherals panel: a fitted peripheral (landing gear,
-- comms dish, solar panels…) with its live state, its keybind and a click that
-- toggles it. `slot` picks which entry of the vessel's device list this row
-- draws; rows past the end hide themselves so the stack collapses cleanly.
--
-- The button and the keybind are the SAME control — both go through the
-- controller's `setPeripheral`, so they can never drift out of step.

defaults = { slot = 1 }

local el, entry

-- Cross-script singletons, resolved once and kept: `findScript` walks the whole
-- scene (floptle/0063), and asking every frame is what made this project do a
-- hundred scans a frame. A handle stays good until the scene changes, and
-- `.valid` is how you find out that it has.
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

function start(node)
  el = node:getcomponent("UiElement")
end

function update(node, dt)
  if not el then el = node:getcomponent("UiElement") end
  if not el then return end
  local panel = ref("peripheral_panel")
  local v = panel and panel.pilotedVessel and panel.pilotedVessel()
  local list = v and v.peripherals and v.peripherals()
  local d = list and list[math.floor(params.slot)]
  entry = d
  el.visible = d ~= nil
  if not d then return end
  -- MOVING is the honest third state: a leg halfway down is neither up nor
  -- down, and pretending otherwise is how you land on a retracting gear.
  local moving = (d.on and d.anim < 0.99) or (not d.on and d.anim > 0.01)
  -- A thruster bus is ON/OFF and switches instantly; a folding leg has a real
  -- in-between. Only the ones that actually take time report EXTENDING.
  local state
  if moving and not d.instant then
    state = d.on and "EXTENDING" or "RETRACTING"
  else
    state = d.on and (d.verbOn or "DEPLOYED") or (d.verbOff or "STOWED")
  end
  local text = string.format("  %s  ×%d      %s   [%s]",
    d.label, d.count, state, string.upper(d.key or "?"))
  if node.text ~= text then node.text = text end
  -- The state is a style ("crt/*", ui/solar.uistyle.ron): a line on the
  -- console's CRT, lit phosphor when deployed, caution yellow while moving.
  local style = (moving and not d.instant) and "crt/rowBusy" or (d.on and "crt/rowOn" or "crt/row")
  if node.style ~= style then node.style = style end
end

function clicked(node)
  local panel = ref("peripheral_panel")
  local v = panel and panel.pilotedVessel and panel.pilotedVessel()
  if v and v.setPeripheral and entry then v.setPeripheral(entry.id) end
end

-- Hover is the style's own `hover` block.
