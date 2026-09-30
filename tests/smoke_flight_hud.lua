-- SMOKE HARNESS for flight_hud.lua — the cockpit.
--
-- Draws the HUD from a stubbed piloted vessel and reads back the trees it hands
-- to `ui.make`. Two kinds of check:
--
--  * the screen says what the craft is doing: lamps, the stage stack, the
--    autopilot, the orbit strip, and that it stands down for the map;
--  * every element it describes uses only properties and values the engine's
--    `ui.make` accepts. In the engine a misspelt property RAISES, which would
--    take the whole cockpit down on the first frame; here it fails a check with
--    the name.
--
--   luajit solar/tests/smoke_flight_hud.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end

-- ── what ui.make accepts (floptle-ui make.rs ALL_PROPS / prop_values) ────────
local PROPS = {}
for p in ([[align border borderB borderColor borderL borderR borderT button case cell cols
  count dir disabled draggable dropTarget field fill fillA fillB fillG fillR flip focusable
  font frame frameSlice frameUV gap group groupA groupB groupG groupR groupTint h height image
  imageFit inset interact justify lineHeight margin mask max maxH maxLen maxLines maxW min minH
  minW numeric opacity order overflow pad part pin pivot placeholder pos posX posY radius
  radiusBL radiusBR radiusTL radiusTR rotation rows scale scaleX scaleY scrollDrag scrollSpeed
  scrollX scrollY scrollbarAxis scrollbarFor selected shader size slice sliderDir stretch style
  template text textA textAlign textB textColor textFit textG textR textSize textValign texture
  tiling tint tintA tintB tintG tintR toggle tooltip tooltipBox tracking upper value visible w
  width wrap x y navUp navDown navLeft navRight]]):gmatch("%S+") do PROPS[p] = true end
local BUILDER = { key = true, name = true, items = true }
local KINDS = { box = true, row = true, col = true, text = true, image = true, button = true,
                field = true, slider = true, scroll = true }
local ENUMS = {
  pin = { "topLeft", "top", "topRight", "left", "center", "right", "bottomLeft", "bottom",
          "bottomRight", "topCenter", "bottomCenter", "leftCenter", "rightCenter" },
  align = { "start", "left", "top", "center", "end", "right", "bottom", "stretch" },
  justify = { "start", "center", "end", "between", "spaceBetween" },
  dir = { "row", "column" },
}
ENUMS.textAlign, ENUMS.textValign = ENUMS.align, ENUMS.align
local function one_of(v, list)
  for _, x in ipairs(list) do if x == v then return true end end
  return false
end

local bad = {}
local function validate(el, path)
  if type(el) ~= "table" then return end
  if type(el[1]) == "string" and not KINDS[el[1]] then bad[#bad + 1] = path .. ": kind " .. el[1] end
  for k, v in pairs(el) do
    if type(k) == "string" then
      if not (PROPS[k] or BUILDER[k] or k:match("^on%u")) then
        bad[#bad + 1] = path .. ": property " .. k
      elseif ENUMS[k] and not one_of(v, ENUMS[k]) then
        bad[#bad + 1] = path .. ": " .. k .. " = " .. tostring(v)
      end
    end
  end
  local fn
  for i = 1, #el do
    if type(el[i]) == "table" then validate(el[i], path .. "/" .. tostring(el[i].key or i))
    elseif type(el[i]) == "function" then fn = el[i] end
  end
  -- An `items` list is expanded the way the engine does it.
  if el.items and fn then
    for i, it in ipairs(el.items) do
      local c = fn(it, i)
      if c then validate(c, path .. "/" .. tostring(c.key or i)) end
    end
  end
end

-- Flatten a tree (items expanded) for searching.
local function each(el, out)
  out = out or {}
  if type(el) ~= "table" then return out end
  out[#out + 1] = el
  local fn
  for i = 1, #el do
    if type(el[i]) == "table" then each(el[i], out)
    elseif type(el[i]) == "function" then fn = el[i] end
  end
  if el.items and fn then
    for i, it in ipairs(el.items) do each(fn(it, i), out) end
  end
  return out
end
local function by_key(tree, key)
  for _, e in ipairs(each(tree)) do if e.key == key then return e end end
end
local function has_text(tree, needle)
  for _, e in ipairs(each(tree)) do
    if type(e.text) == "string" and e.text:find(needle, 1, true) then return e end
  end
end

-- ── the engine, stubbed ─────────────────────────────────────────────────────
local SW, SH = 1280, 720
local nodes = {}
local function ui_node(name)
  local n = { name = name, valid = true, __el = { visible = false, posX = 0, posY = 0 } }
  n.getcomponent = function(self) return self.__el end
  n.uiRect = function() return 0, 0, 0, 0 end
  nodes[name] = n
  return n
end
for _, nm in ipairs({ "Navball", "Speed Tape", "Alt Tape", "Speed Readout", "Alt Readout",
                      "Heading Readout", "HUD Panel", "Debug", "Flight HUD Overlay" }) do
  ui_node(nm)
end
nodes["HUD Panel"].__el.visible = true   -- as the map leaves it

local made = {}
local body = { name = "Golil", x = 0, y = 0, z = 0, radius = 200, mu = 4.9e5 }
local map = { map_view = false }

local V = {
  piloting = true, throttle = 0.4, fuel = 30, sas_mode = "stability", heating = 0,
  chutes_deployed = false, gear_deployed = true,
  dock = { captureR = 0.55, alignMin = 0.8, driftMax = 1.5, latched = 0 },
  node = { valid = true, x = 0, y = 222, z = 0, vx = 0, vy = 0, vz = 0 },
  calls = {},
}
function V.setSAS(m) V.calls[#V.calls + 1] = "sas:" .. m; V.sas_mode = m end
function V.setPeripheral(id) V.calls[#V.calls + 1] = "dev:" .. id end

local function pad_tele()
  return {
    warp = 1, warp_cap = 1107, warp_why = "charting ahead of you",
    anchored = true, grounded = true, ready = true, parts = 6, parts_total = 6,
    twr = 1.38, fuel_cap = 60, refueling = true, ec = 0, ec_cap = 0, ec_gen = 0,
    has_gear = true, has_rcs = false, rcs_on = false, rcs_blocks = 0, chute_open = 0,
    alt = 22, spd = 0, vspd = 0, nose = 64, vorb = 30.3, vesc = 42.9,
    body = "Golil", pe = -207, ap = 22, period = 17,
    eng = 1, thrust = 55,
    stages = { { kind = "axial", eng = 0, kn = 0 }, { kind = "chute", n = 1, eng = 0, kn = 0 } },
  }
end
V.tele = pad_tele()

local env = setmetatable({}, { __index = _G })
env.find = function(n) return nodes[n] end
env.findScripts = function(k) if k == "vessel_controller" then return { V } end return {} end
env.findScript = function(k) if k == "orbit_map" then return map end return nil end
env.camera = { screenSize = function() return SW, SH end }
env.space = { dominant = function() return "Golil" end,
              body = function(n) return n == "Golil" and body or nil end }
env.ui = { make = function(node, tree) made[node.name or node] = tree end }
env.time = 0

local chunk = assert(loadfile("solar/scripts/flight_hud.lua"))
setfenv(chunk, env)
chunk()
env.params = {}
for k, v in pairs(env.defaults) do env.params[k] = v end

local HUD = ui_node("Flight HUD")
env.start(HUD)
local function frame() env.update(HUD, 1 / 60); return made["Flight HUD"] end

-- ── 1. on the pad ───────────────────────────────────────────────────────────
local tree = frame()
validate(tree, "pad")
check(HUD.__el.visible == true, "the cockpit is up while piloting")
check(nodes["Flight HUD Overlay"].__el.visible == true, "...with its overlay")
check(nodes["HUD Panel"].__el.visible == false, "the map's text block is put away in flight")
local clamp = by_key(tree, "CLAMPED")
check(clamp and clamp.style == "hud/lampOn", "the CLAMPED lamp is lit on the pad")
check(by_key(tree, "LANDED").style == "hud/lamp", "...and LANDED is not (clamped outranks it)")
check(by_key(tree, "clamps") ~= nil and has_text(by_key(tree, "clamps"), "SPACE"),
  "releasing the clamps is the next stage, with its key")
check(by_key(tree, "s1") and not has_text(by_key(tree, "s1"), "SPACE"),
  "...and the first real stage waits behind it")
check(has_text(tree, "Decouple") and has_text(tree, "Chutes ×1"), "the stage stack names each event")
check(not has_text(tree, "below y"), "...without the builder's internal coordinates")
check(has_text(tree, "40%"), "throttle reads as a percentage")
check(has_text(tree, "×1"), "time warp shows its rate")
check(by_key(tree, "warp").tooltip:find("charting ahead of you", 1, true) ~= nil,
  "...and why it is capped, on hover")
check(has_text(tree, "PERIAPSIS") and not has_text(tree, "-207 m"),
  "on the pad the orbit strip shows no orbit (the planet's spin read as one is noise)")
check(by_key(tree, "fuel") ~= nil and by_key(tree, "ec") == nil,
  "fuel is shown; charge only on a craft that has any")
check(made["Flight HUD Overlay"] and made["Flight HUD Overlay"].tooltipBox == true,
  "the overlay carries the layer's tooltip box")
check(nodes["Navball"].__el.posY < 0, "the navball is mounted on the console")

-- ── 2. the autopilot is a control, not a readout ───────────────────────────
local pro = by_key(tree, "prograde")
check(pro and pro.onClicked and pro.tooltip:find("[2]", 1, true), "prograde hold: button + key hint")
pro.onClicked()
check(V.sas_mode == "prograde", "clicking a hold engages it")
tree = frame()
check(by_key(tree, "prograde").selected == true, "...and it lights")
by_key(tree, "prograde").onClicked()
check(V.sas_mode == "off", "clicking the lit hold lets go")
tree = frame()
by_key(tree, "sas").onClicked()
check(V.sas_mode == "prograde", "the SAS switch brings back the last hold")
check(by_key(tree, "rcs").disabled == true, "RCS is disabled on a craft without thrusters")
for _, k in ipairs({ "stability", "prograde", "retrograde", "normal", "antinormal",
                     "radialin", "radialout", "dock", "node", "sas", "rcs" }) do
  check(by_key(tree, k) and by_key(tree, k).focusable == false,
    k .. " is not focusable (SPACE on a focused button would click it)")
end

-- ── 3. in flight, in trouble ────────────────────────────────────────────────
local t = pad_tele()
t.anchored, t.grounded, t.refueling = false, false, false
t.ap, t.period = nil, nil
t.hp, t.hp_part = 0.2, "Fuel Tank S"
t.warp, t.stages = 50, { { kind = "ring", n = 2, eng = 2, kn = 60 } }
V.tele, V.fuel, V.heating = t, 3, 0.3
V.dock.target = { name = "Port A", range = 0.4, align = 0.9, lateral = 0.1, closing = -0.2,
                  drift = 0.3, locked = true }
tree = frame()
validate(tree, "flight")
check(has_text(tree, "PERIAPSIS") and has_text(tree, "-207 m"), "off the pad the orbit strip reads the orbit")
check(by_key(tree, "HEAT").style == "hud/lampDanger", "severe heating is a red lamp")
check(by_key(tree, "FUEL").style == "hud/lampWarn", "low fuel is an amber lamp")
check(by_key(tree, "DAMAGE").tooltip:find("Fuel Tank S", 1, true), "the damage lamp names the part")
check(by_key(tree, "ESCAPE").style == "hud/lampWarn" and has_text(tree, "ESCAPE"),
  "an escape trajectory lights ESCAPE and says so in the strip")
check(by_key(tree, "clamps") == nil and has_text(by_key(tree, "s1"), "SPACE"),
  "once released, the first stage is next")
check(has_text(tree, "Boosters ×2") and has_text(tree, "drops 2 eng"), "a booster ring card")
check(by_key(tree, "dockline") and has_text(by_key(tree, "dockline"), "Port A"), "the docking checklist")
check(by_key(tree, "x").style == "hud/valueAccent", "warp above ×1 is lit")
V.dock.target = nil

-- ── 4. 5:4 — the console makes room for the stage stack ─────────────────────
SW, SH = 1350, 1080
tree = frame()
validate(tree, "5:4")
local L = env.layout
local dw = 720 * SW / SH
check(L and L.consoleRight <= dw - 16 - 168 - 8 + 0.01,
  string.format("at 5:4 the console clears the stage stack (%.0f vs %.0f)",
    L and L.consoleRight or -1, dw - 192))
check(L and L.consoleLeft >= 16, "...and stays on screen")
check(L and L.topLeft + 612 <= dw - 16 - 232 - 8 + 0.01 and L.topLeft >= 16,
  string.format("...and the orbit strip clears the fuel block (left edge %.0f)", L and L.topLeft or -1))

-- ── 5. the map owns the screen ──────────────────────────────────────────────
map.map_view = true
frame()
check(HUD.__el.visible == false and env.layout == nil, "the cockpit stands down under the map")
map.map_view = false
V.piloting = false
frame()
check(HUD.__el.visible == false, "...and when nobody is flying")

if #bad > 0 then
  for _, b in ipairs(bad) do failures[#failures + 1] = "ui.make would raise — " .. b end
end
if #failures > 0 then
  print("FLIGHT HUD SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print(string.format("FLIGHT HUD SMOKE OK — %d checks passed", passed))
