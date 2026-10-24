-- VESSEL SWITCHER — `[` and `]` step through what you can control nearby.
--
-- The list is the crew (on foot, or the craft they're sitting in) and every
-- craft with a command part — a crew pod or a probe core — within the physics
-- range of whatever you're controlling now. The crew is always on it, however
-- far away you've flown a probe: `[` / `]` is also the way home.
--
-- Switching takes the controls and nothing else: the crew stay where they are
-- (flight_ops.switchToVessel / switchToCrew). So stepping onto a probe from a
-- crewed lander leaves the crew in the lander's seat, and stepping onto an empty
-- crew pod shows it to you with its controls dark (NO CREW) — to fly that one,
-- walk over and climb in (F), or use the Tracking Station's crew transfer.
--
-- The craft you leave keeps coasting (or sitting) where it was; flight_ops
-- gives a craft its orbital velocity back if it comes out of the engine's LOD
-- at rest (floptle/0402).

defaults = {
  --@header Switching
  -- How far a craft can be and still be switched to with [ ] (the physics
  -- range the engine keeps loaded around the camera).
  --@range 100 20000 --@units m
  range = 2500.0,
}

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end

-- What you control now: the piloted craft's controller, or "crew".
local function current()
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.piloting and v.node and v.node.valid then return v end
  end
  return "crew"
end

local function pos_of(t)
  if t == "crew" then
    local a = find("Astronaut")
    if a then return a.x, a.y, a.z end
    return nil
  end
  local n = t.node
  return n.x, n.y, n.z
end

-- Everything `[ ]` can land on, in a stable order (the crew first, then craft
-- by name). Global so the HUD and the harness read the same list.
function targets()
  local cur = current()
  local cx, cy, cz = pos_of(cur)
  local out = {}
  local seat = nil
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.crewAboard and v.node and v.node.valid then seat = v end
  end
  if not seat then out[#out + 1] = { kind = "crew", name = "Crew" } end
  local craft = {}
  for _, v in ipairs(findScripts("vessel_controller")) do
    local n = v.node
    if n and n.valid and v.controlState then
      local cs = v.controlState()
      if (cs.pod or cs.probe) and not cs.lost then
        local near = true
        local is_cur = cur ~= "crew" and cur.node.id == n.id
        local is_seat = seat ~= nil and seat.node.id == n.id
        if cx and not is_cur and not is_seat then
          near = len(n.x - cx, n.y - cy, n.z - cz) <= params.range
        end
        if near then
          craft[#craft + 1] = { kind = "vessel", v = v, name = v.craftName or n.name or "Vessel", id = n.id,
                                crew = cs.crew, can = cs.can, why = cs.why }
        end
      end
    end
  end
  table.sort(craft, function(a, b) return a.name < b.name or (a.name == b.name and a.id < b.id) end)
  for _, c in ipairs(craft) do out[#out + 1] = c end
  return out, cur
end

local function index_of(list, cur)
  for i, t in ipairs(list) do
    -- (by node id: every findScripts call hands back fresh handles)
    if (cur == "crew" and t.kind == "crew")
      or (t.kind == "vessel" and cur ~= "crew" and t.v.node.id == cur.node.id) then return i end
  end
  -- flying nothing but the crew sits in a seat: that craft is "you"
  return nil
end

-- Step `dir` (+1 / −1) along the list. Returns the new target's name.
function step(dir)
  local list, cur = targets()
  if #list < 2 then
    caption("nothing else in range to switch to")
    return nil
  end
  local i = index_of(list, cur) or 0
  local j = ((i - 1 + dir) % #list) + 1
  local t = list[j]
  local fo = ref("flight_ops")
  if not fo then return nil end
  if t.kind == "crew" then
    fo.switchToCrew()
    caption("switched to the crew")
    log("switch: crew")
  else
    if not fo.switchToVessel(t.v) then return nil end
    local how = t.crew and "crew aboard" or (t.can and "remote" or ("no control — " .. tostring(t.why or "")))
    caption("switched to " .. t.name .. " · " .. how:lower())
    log("switch: " .. t.name .. " (" .. how .. ")")
  end
  local s = ref("sfx")
  if s and s.play then s.play("click") end
  return t.name
end

-- Panels that own the keyboard: no switching from behind them.
local function busy()
  local gm = ref("game_manager")
  if gm and gm.loading then return true end
  for _, k in ipairs({ "pause_menu", "facility_menu", "ops_board", "inventory_panel" }) do
    local s = ref(k)
    if s and ((s.open == true) or (s.isOpen and s.isOpen())) then return true end
  end
  local om = ref("orbit_map")
  if om and om.planning then return true end
  return false
end

function update(node, dt)
  local gm = ref("game_manager")
  if gm and gm.inputOwner == "builder" then return end -- the VAB builder has the keys
  if input.pressed("]") and not busy() then step(1) end
  if input.pressed("[") and not busy() then step(-1) end
end
