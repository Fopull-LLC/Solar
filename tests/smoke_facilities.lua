-- SMOKE HARNESS for facility_menu.lua + facility_button.lua: stubs the engine,
-- stands the astronaut next to the Tracking Station, and drives open → read
-- registry → action/close. Catches Lua errors and the interaction logic.
--
--   luajit solar/tests/smoke_facilities.lua

_G.time = 0.0

-- Body-relative frame: planet offset from origin, astronaut top-level (world),
-- facilities planet-parented (their .x/.y/.z ARE body-relative), exactly like the
-- real scenes.
local planet = { name = "Athosil", x = 300, y = -120, z = 80, radius = 200, soi = 5000 }

local function el() return { visible = true, opacity = 1.0 } end
local function ui_node(name)
  return { name = name, text = "", __el = el(),
    getcomponent = function(self, k) if k == "UiElement" then return self.__el end end }
end

local nodes = {}
local function add(n) nodes[n.name] = n; return n end

-- The astronaut, in WORLD coords, standing 4 m from where FacTracking sits.
local astro = add({ name = "Astronaut", visible = true,
  x = planet.x + 0, y = planet.y + planet.radius, z = planet.z + 0 })

-- The facilities hang off the PLANET node, exactly as base_facilities spawns
-- them: their own coords are body-relative and only compose into world space
-- through the parent. A menu that compares them against a world-space astronaut
-- without walking that chain is off by the planet's orbital position — which is
-- the bug this models.
local planet_node = add({ name = planet.name, x = planet.x, y = planet.y, z = planet.z })
add({ name = "FacTracking", parent = planet_node, x = 0, y = planet.radius, z = 4 })
add({ name = "FacCommand",  parent = planet_node, x = 40, y = planet.radius, z = 0 })
add({ name = "FacHangar",   parent = planet_node, x = 0,  y = planet.radius, z = 40 })
add({ name = "FacPower",    parent = planet_node, x = -40, y = planet.radius, z = 0 })

-- UI nodes the script drives.
for _, nm in ipairs({ "Facility Prompt", "Facility Panel", "Facility Title", "Facility Body", "Facility Action", "Facility Exit" }) do
  add(ui_node(nm))
end

_G.find = function(name) return nodes[name] end
_G.findScripts = function() return {} end
-- The walker is the ONE place that answers "is the crew out and about" — it
-- watches the fleet and the loading flag and publishes `onFoot`, and every
-- panel asks it. Modelled here so this test drives the real gate.
local walker = { onFoot = true }
_G.space = {
  dominant = function() return planet.name end,
  body = function(n) if n == planet.name then return planet end end,
}
local SAVE = {}
_G.save = { get = function(k) return SAVE[k] end, set = function(k, v) SAVE[k] = v end }

local KEYS = {}
_G.input = { pressed = function(k) return KEYS[k] == true end, key = function() return false end }
local LOADED = nil
_G.scene = { load = function(s) LOADED = s end }
_G.log = function() end

-- Two live vessels in the tracker registry (one full battery, one half).
SAVE["comms.ships"] = {
  v1 = { name = "Odyssey", x = 1, y = 2, z = 3, alt = 1250, charge = 200, cap = 200, t = 0 },
  v7 = { name = "Scout",   x = 4, y = 5, z = 6, alt = 84,   charge = 50,  cap = 100, t = 0 },
}

-- The prompt is a ui.make row; this keeps the last label each node was given.
local made = {}
_G.ui = { make = function(node, tree)
  local function walk(t)
    if type(t) ~= "table" then return end
    if t[1] == "text" and t.text then made[node] = tostring(t.text) end
    for _, item in ipairs(t.items or {}) do walk(item) end
  end
  walk(tree)
end }
local function prompt_text() return made[nodes["Facility Prompt"]] or "" end

-- ── load both scripts under distinct script tables (findScript resolves them) ──
local menu_env = {}
local function load_into(path)
  local chunk = assert(loadfile(path))
  chunk()
  return {
    start = start, update = update, action = action, close = close,
    openMenu = openMenu, clicked = clicked, params = _G.params,
  }
end

-- facility_menu first (it defines start/update/openMenu/action/close as globals).
local menu = load_into("solar/scripts/facility_menu.lua")
-- A published value, read live from the script's globals.
function menu_escTakenAt() return _G.escTakenAt end
menu.params = { radius = 9.0 }
_G.params = menu.params
-- The command centre reads the company across a script handle. Stubbed because
-- that reach ACROSS is the fragile part: it is the code most likely to raise
-- while something reloads, and what the panel does when it raises is the last
-- test in this file.
local company
company = {
  valid = true,
  money = function(v) return "$" .. tostring(v) end,
  balance = function() return 4200 end,
  rep = function() return 3 end,
  ledgerLines = function() return {} end,
  earned = 0,
  earn = function(v) company.earned = company.earned + v end,
  addRep = function() end,
}
-- The fleet board reads flight_ops' fleet. Two craft: one parked on the ground
-- with no dish (last seen, a transfer is billed), one in orbit over a live link.
local taken = {}
local flight_ops = {
  valid = true,
  fleetList = function()
    return {
      { fid = "c1", name = "Odyssey", body = "Tarn", alt = 1250, status = "in orbit",
        pe = 300, ap = 1400, pod = true, comms = true, link = true, fee = 0, landed = false },
      { fid = "c2", name = "Scout", body = "Tarn", alt = -0.2, status = "landed",
        pod = true, comms = false, link = false, fee = 330, landed = true },
    }
  end,
  takeControlOf = function(fid) taken[#taken + 1] = fid return true, fid end,
}
_G.findScript = function(kind)
  if kind == "flight_ops" then return flight_ops end
  if kind == "planet_walker" then return walker end
  if kind == "facility_menu" then return menu end
  if kind == "company" then return company end
  if kind == "game_manager" then return { exitToMenu = function() LOADED = "menu" end } end
  return nil
end

menu.start({ name = "Facilities Menu" })
assert(nodes["Facility Prompt"].__el.visible == false, "prompt should start hidden")
assert(nodes["Facility Panel"].__el.visible == false, "panel should start hidden")

-- Tick once: astronaut is 4 m from FacTracking (< radius 9) → prompt shows.
menu.update({}, 1 / 60)
assert(nodes["Facility Prompt"].__el.visible == true, "prompt should show near a facility")
assert(prompt_text():find("Tracking Station"), "prompt should name the nearest facility, got: " .. prompt_text())

-- The pause menu owns the screen: no prompt over it, and E does not open a panel.
local pause = { open = true }
local plain_find = _G.findScript
_G.findScript = function(kind) if kind == "pause_menu" then return pause end return plain_find(kind) end
KEYS["e"] = true
menu.update({}, 1 / 60)
KEYS["e"] = false
assert(nodes["Facility Prompt"].__el.visible == false, "prompt should hide while the game is paused")
assert(nodes["Facility Panel"].__el.visible == false, "E should not open a panel from under the pause menu")
_G.findScript = plain_find
menu.update({}, 1 / 60)
assert(nodes["Facility Prompt"].__el.visible == true, "prompt should come back after unpausing")

-- An open right-click menu beside the crew: the prompt was drawn over its rows
-- (QA 2026-10-26, "Enter the Vehicle Assembly — builder · E" across IN HAND).
local cmenu = { isOpen = function() return true end }
_G.findScript = function(kind) if kind == "context_menu" then return cmenu end return plain_find(kind) end
menu.update({}, 1 / 60)
assert(nodes["Facility Prompt"].__el.visible == false, "prompt should hide under an open context menu")
_G.findScript = plain_find
menu.update({}, 1 / 60)
assert(nodes["Facility Prompt"].__el.visible == true, "prompt should come back when the context menu closes")

-- Press E → panel opens on the Tracking Station.
KEYS["e"] = true
menu.update({}, 1 / 60)
KEYS["e"] = false
assert(nodes["Facility Panel"].__el.visible == true, "panel should open on E")
assert(nodes["Facility Prompt"].__el.visible == false, "prompt hidden while panel open")
assert(nodes["Facility Title"].text == "Tracking Station", "title should be the facility")
local body = nodes["Facility Body"].text
-- THE FLEET BOARD (review, 2026-10): it listed only dish-carrying craft and
-- offered no action. Every parked craft is on it now, with where it is and what
-- it's doing, and the panel's button takes control of the selected one.
assert(body:find("2 craft"), "tracking body should count 2 craft, got: " .. body)
assert(body:find("Odyssey") and body:find("Scout"), "tracking body should list both craft")
assert(body:find("in orbit") and body:find("landed"), "each row says what the craft is doing, got: " .. body)
assert(body:find("live link") and body:find("last seen"), "the dish is what makes a row live, got: " .. body)
assert(not body:find("-0 m", 1, true), "an altitude that wobbles under zero never prints \"-0 m\", got: " .. body)
assert(nodes["Facility Action"].text:find("Take control"), "the board's action takes control, got: "
  .. tostring(nodes["Facility Action"].text))
-- ↓ selects the next craft; without a link, the button says what the transfer costs.
KEYS["down"] = true
menu.update({}, 1 / 60)
KEYS["down"] = false
assert(nodes["Facility Body"].text:find("▸ Scout"), "↓ moves the selection, got: " .. nodes["Facility Body"].text)
assert(nodes["Facility Action"].text:find("$330", 1, true), "a billed transfer names its price, got: "
  .. tostring(nodes["Facility Action"].text))
menu.action()
assert(taken[1] == "c2", "the action takes control of the SELECTED craft, got: " .. tostring(taken[1]))
assert(nodes["Facility Panel"].__el.visible == false, "taking control closes the board (the cockpit takes over)")
KEYS["e"] = true
menu.update({}, 1 / 60)
KEYS["e"] = false
assert(nodes["Facility Panel"].__el.visible == true, "...and E opens it again")

-- Press E again → closes.
KEYS["e"] = true
menu.update({}, 1 / 60)
KEYS["e"] = false
assert(nodes["Facility Panel"].__el.visible == false, "panel should close on E")

-- Esc closes too — and says it spent that frame's Esc, so the pause menu does
-- not open on the same keypress the panel closed on.
KEYS["e"] = true
menu.update({}, 1 / 60)
KEYS["e"] = false
_G.time = 12.5
KEYS["escape"] = true
menu.update({}, 1 / 60)
KEYS["escape"] = false
assert(nodes["Facility Panel"].__el.visible == false, "panel should close on Esc")
assert(menu_escTakenAt() == 12.5, "closing on Esc should publish the frame it was spent, got: "
  .. tostring(menu_escTakenAt()))

-- Empty fleet → a message that says how a craft gets on the board, no button.
local full_list = flight_ops.fleetList
flight_ops.fleetList = function() return {} end
menu.openMenu("FacTracking")
assert(nodes["Facility Body"].text:find("No craft out there"), "an empty fleet says so, got: "
  .. nodes["Facility Body"].text)
assert(nodes["Facility Action"].__el.visible == false, "...with no action to press")
menu.close()
flight_ops.fleetList = full_list

-- Hangar action → jumps to the builder.
menu.openMenu("FacHangar")
assert(nodes["Facility Action"].__el.visible == true, "hangar should show an action button")
menu.action()
assert(LOADED == "builder", "hangar action should load the builder scene, got: " .. tostring(LOADED))

-- Walking away hides the prompt; BOARDING closes the panel.
--
-- "Boarding" is a vessel reporting `piloting`, not a hidden astronaut. Those got
-- conflated, and the cost was real: planet_camera hides the body whenever the
-- camera clips within 0.7 m of it, which happens on most headings once you are
-- INSIDE the command centre — so the panel you had just opened closed itself and
-- the prompt to reopen it was gone too.
menu.openMenu("FacCommand")
walker.onFoot = false   -- the walker's answer once a vessel reports `piloting`
menu.update({}, 1 / 60)
assert(nodes["Facility Panel"].__el.visible == false, "panel closes while a vessel is being piloted")
walker.onFoot = true

-- …and the camera hiding the body up close must NOT close it. (Standing in
-- the command centre: a panel left behind by walking off closes on its own.)
local was_x, was_z = astro.x, astro.z
astro.x, astro.z = planet.x + 40, planet.z + 3
menu.openMenu("FacCommand")
astro.visible = false
menu.update({}, 1 / 60)
assert(nodes["Facility Panel"].__el.visible == true,
  "panel stays open when only the CAMERA has hidden the astronaut (standing indoors)")
menu.close()
astro.visible = true
astro.x = was_x
astro.z = planet.z + 500 -- far from every facility
menu.update({}, 1 / 60)
assert(nodes["Facility Prompt"].__el.visible == false, "prompt hidden when far from all facilities")

-- Reach scales with the BUILDING. The command centre is 12 x 18 m on the ground
-- now, so its origin is nine metres from its own far wall: a reach tuned to the
-- old 8.4 x 12.6 shed goes quiet while you are standing inside the doorway.
astro.x, astro.y, astro.z = planet.x + 40, planet.y + planet.radius, planet.z + 18
menu.update({}, 1 / 60)
assert(nodes["Facility Prompt"].__el.visible == true,
  "prompt should reach 18 m from the command centre's origin (the building is 18 m long)")
assert(prompt_text():find("Enter the Command Centre"),
  "18 m out should offer to enter the command centre, got: " .. prompt_text())
-- Standing INSIDE it, "Enter the Command Centre" is the wrong thing to say.
astro.z = planet.z + 3
menu.update({}, 1 / 60)
assert(prompt_text():find("console") and not prompt_text():find("Enter"),
  "inside the command centre the prompt should offer its console, got: " .. prompt_text())
-- …and still stop somewhere. A reach that never ends is not a reach.
astro.z = planet.z + 34
menu.update({}, 1 / 60)
assert(nodes["Facility Prompt"].__el.visible == false,
  "prompt should be gone 34 m from the command centre")

-- WALK AWAY AND IT CLOSES. A panel opened at the console and left up followed
-- you round the planet, hiding the world, for as long as you forgot it.
astro.z = planet.z + 3
menu.openMenu("FacCommand")
menu.update({}, 1 / 60)
assert(nodes["Facility Panel"].__el.visible == true, "the panel stays up while you stand at it")
astro.z = planet.z + 22        -- a step back from the counter: still in reach + grace
menu.update({}, 1 / 60)
assert(nodes["Facility Panel"].__el.visible == true, "a step back does not slam it shut")
astro.z = planet.z + 34
menu.update({}, 1 / 60)
assert(nodes["Facility Panel"].__el.visible == false, "walking away from the building closes its panel")
astro.x, astro.y, astro.z = planet.x, planet.y + planet.radius, planet.z + 500

-- E GOES WHERE YOU CAME FOR. The Command Centre's E opens the Ops Board and the
-- Vehicle Assembly's E opens the builder — no overview panel whose only real
-- content is a button to the screen you wanted.
local board = { opened = 0, open = false }
board.openBoard = function() board.opened = board.opened + 1; board.open = true end
board.isOpen = function() return board.open end
board.closeBoard = function() board.open = false end
local plain_fs = _G.findScript
_G.findScript = function(kind) if kind == "ops_board" then return board end return plain_fs(kind) end
astro.x, astro.y, astro.z = planet.x + 40, planet.y + planet.radius, planet.z + 3
menu.update({}, 1 / 60)
KEYS["e"] = true
menu.update({}, 1 / 60)
KEYS["e"] = false
assert(board.opened == 1 and board.open, "E at the Command Centre opens the Ops Board directly")
assert(nodes["Facility Panel"].__el.visible == false, "…not the overview panel")
KEYS["e"] = true
menu.update({}, 1 / 60)
KEYS["e"] = false
assert(board.open == false, "E again closes the board")
_G.findScript = plain_fs
LOADED = nil
astro.x, astro.y, astro.z = planet.x, planet.y + planet.radius, planet.z + 40 + 6
menu.update({}, 1 / 60)
assert(prompt_text():find("builder"), "the assembly's prompt says E opens the builder, got: " .. prompt_text())
KEYS["e"] = true
menu.update({}, 1 / 60)
KEYS["e"] = false
assert(LOADED == "builder", "E at the Vehicle Assembly opens the builder, got: " .. tostring(LOADED))
assert(nodes["Facility Panel"].__el.visible == false, "…with no overview panel in between")
astro.x, astro.y, astro.z = planet.x, planet.y + planet.radius, planet.z + 500

-- The Power Plant is a machine with nothing to say: no prompt at all, rather
-- than a panel that reads "Reactor ONLINE" and has no buttons.
local plant = nodes["FacPower"]
plant.parent = nil
plant.x, plant.y, plant.z = astro.x + 3, astro.y, astro.z
menu.update({}, 1 / 60)
assert(nodes["Facility Prompt"].__el.visible == false,
  "the power plant should not prompt, got: " .. prompt_text())
plant.x = astro.x + 900

-- A facility that never found its planet node is TOP-LEVEL, so its coordinates
-- are already world. The prompt must read that correctly too — measuring it in
-- the planet's frame puts it an orbit away and the prompt never fires.
local orphan = nodes["FacTracking"]
orphan.parent = nil
orphan.x, orphan.y, orphan.z = astro.x + 3, astro.y, astro.z
menu.update({}, 1 / 60)
assert(nodes["Facility Prompt"].__el.visible == true,
  "prompt should show next to an UNPARENTED facility (world coords)")
assert(prompt_text():find("Tracking Station"),
  "prompt should name the unparented facility, got: " .. prompt_text())

-- ── ONE PANEL, FIVE BUILDINGS: never a blend of two ─────────────────────────
-- Reported as "the facilities uis were often mixed up".
--
-- All five buildings share one Title/Body/Action. The title used to be written
-- FIRST, the body computed SECOND and written LAST — and every line of that
-- computation reaches across into another script (`co.balance()`, the depot's
-- inventory walk, the missions list), which is the code most likely to raise
-- while something is reloading. Anything that raised in the middle left the NEW
-- building's name sitting above the OLD building's contents.
astro.x, astro.y, astro.z = planet.x, planet.y + planet.radius, planet.z + 500
menu.openMenu("FacTracking")
local tracking_body = nodes["Facility Body"].text
assert(nodes["Facility Title"].text == "Tracking Station", "baseline title")

-- Make the NEXT building's content raise, exactly the way a half-loaded
-- cross-script handle would.
local real_balance = company.balance
company.balance = function() error("company is mid-reload") end
menu.openMenu("FacCommand")
company.balance = real_balance

local title, body = nodes["Facility Title"].text, nodes["Facility Body"].text
assert(title == "Command Centre",
  "the panel names the building you opened, got: " .. tostring(title))
assert(body ~= tracking_body,
  "a panel that cannot build its content must NOT keep the previous building's body")
assert(body:find("not responding"),
  "…it says so instead, got: " .. tostring(body))
assert(nodes["Facility Action"].__el.visible == false,
  "…and drops the previous building's action button with it")

-- …and recovers by itself the moment the content works again.
menu.openMenu("FacCommand")
assert(nodes["Facility Body"].text:find("Base world"),
  "the panel recovers once the content builds, got: " .. nodes["Facility Body"].text)
menu.close()

-- ── THE COMMERCE DEPOT, WITH CARGO IN IT ────────────────────────────────────
-- Reported from a live session: the depot panel came up saying "This console is
-- not responding", which is the atomic-write path above catching a raise inside
-- the depot's own content. Every other facility's body is a few `save` reads;
-- this one walks three registries and a landed craft's hold, so it is the one
-- with somewhere to go wrong — and it only goes there once there is cargo,
-- which is why an empty depot looked fine.
add({ name = "FacDepot", parent = planet_node, x = 0, y = planet.radius, z = -40 })

local BAGS = {
  astro = { regolith = 12, silica = 3 },
  base  = { iron = 40, crystal = 2 },
  holdA = { regolith = 60 },
}
local MATS = {
  regolith = { name = "Regolith", kg = 0.4, tier = 0, value = 3 },
  silica   = { name = "Silica",   kg = 0.5, tier = 1, value = 11 },
  iron     = { name = "Iron Ore", kg = 1.2, tier = 1, value = 18 },
  crystal  = { name = "Resonant Crystal", kg = 0.8, tier = 3, value = 140 },
}
local ORDER = { "regolith", "silica", "iron", "crystal" }
local materials = {
  valid = true,
  list = function() return ORDER end,
  -- `label`, not `name`: a script handle's `.name` is reserved by the engine.
  label = function(id) return MATS[id] and MATS[id].name or tostring(id) end,
  tier = function(id) return MATS[id] and MATS[id].tier or 0 end,
  valueOf = function(id, n) return (MATS[id] and MATS[id].value or 0) * (n or 1) end,
}
local inventory = {}
inventory = {
  valid = true,
  mass = function(cid)
    local t = 0
    for m, n in pairs(BAGS[cid] or {}) do t = t + (MATS[m] and MATS[m].kg or 0) * n end
    return t
  end,
  isEmpty = function(cid) return next(BAGS[cid] or {}) == nil end,
  items = function(cid)
    local out = {}
    for _, m in ipairs(ORDER) do
      local n = (BAGS[cid] or {})[m]
      if n and n > 0 then
        out[#out + 1] = { mat = m, n = n, kg = MATS[m].kg * n, value = MATS[m].value * n }
      end
    end
    return out
  end,
  totalValue = function(cid)
    local t = 0
    for m, n in pairs(BAGS[cid] or {}) do t = t + (MATS[m] and MATS[m].value or 0) * n end
    return t
  end,
  line = function(cid) return string.format("%.1f kg", inventory.mass(cid)) end,
  remove = function(cid, m) if BAGS[cid] then BAGS[cid][m] = nil end end,
  transferAll = function(from, to)
    local moved = 0
    for m, n in pairs(BAGS[from] or {}) do
      BAGS[to] = BAGS[to] or {}
      BAGS[to][m] = (BAGS[to][m] or 0) + n
      moved = moved + n
    end
    BAGS[from] = {}
    return moved
  end,
}
-- A landed craft within crane reach, with something in its hold. `landedHolds`
-- measures it against the depot in WORLD space and the craft is TOP-LEVEL, which
-- is the frame mix this file already exists to police.
local craft = add({ name = "Kestrel", valid = true, x = planet.x + 0,
                    y = planet.y + planet.radius, z = planet.z - 30 })
local VESSEL = { valid = true, node = craft, holdId = "holdA", craftName = "Kestrel",
                 holdApplyMass = function() end }

local prev_findScript, prev_findScripts = _G.findScript, _G.findScripts
_G.findScript = function(kind)
  if kind == "inventory" then return inventory end
  if kind == "materials" then return materials end
  return prev_findScript(kind)
end
_G.findScripts = function(kind)
  if kind == "vessel_controller" then return { VESSEL } end
  return prev_findScripts(kind)
end

astro.x, astro.y, astro.z = planet.x, planet.y + planet.radius, planet.z - 40
menu.openMenu("FacDepot")
local dbody = nodes["Facility Body"].text
assert(nodes["Facility Title"].text == "Commerce Depot", "depot title")
assert(not dbody:find("not responding"),
  "the depot panel must BUILD with cargo in it, got: " .. dbody)
assert(dbody:find("ON THE PAD") and dbody:find("Kestrel"),
  "…listing the landed craft's hold, got: " .. dbody)
assert(dbody:find("SUIT PACK"), "…and the suit pack, got: " .. dbody)
assert(dbody:find("WAREHOUSE"), "…and the warehouse, got: " .. dbody)
-- The goods themselves are ROWS, one per material, merged across the pad, the
-- pack and the warehouse — each one its own sale.
local stock = {}
for _, e in ipairs(depotStock()) do stock[e.mat] = e end
assert(stock.regolith and stock.regolith.n == 72 and stock.iron and stock.iron.n == 40,
  "…one row per material, merged across pad, pack and warehouse")
-- Nothing has been sold yet, so every row is a first sale and says so.
assert(stock.crystal.first and stock.crystal.bonus > stock.regolith.bonus,
  "…marking a first sale, with the rarer premium bigger")
assert(dbody:find("NEW"), "…and the body explains the NEW mark, got: " .. dbody)
-- ONE press sells it. It used to be two — unload, then sell — and a player
-- with a full pack pressed once, saw "12 units into the warehouse", and left
-- with no money. The label names the whole haul's price: pad + pack + shed.
-- (regolith 72×3 + silica 3×11 + iron 40×18 + crystal 2×140, standing +12%.)
-- Plus the discovery premiums, because every one of these is a first sale.
local want = math.floor(72 * 3 * 1.12) + math.floor(3 * 11 * 1.12) + math.floor(40 * 18 * 1.12)
  + math.floor(2 * 140 * 1.12) + 150 * (1 + 0) + 150 * (1 + 1) * 2 + 150 * (1 + 3)
assert(nodes["Facility Action"].text:find("Sell everything"),
  "…with a single sell action, got: " .. nodes["Facility Action"].text)
assert(nodes["Facility Action"].text:find("$" .. want, 1, true),
  "…priced at everything it will sell (" .. want .. "), got: " .. nodes["Facility Action"].text)
assert(not dbody:find("STEP"), "…and no two-step instructions, got: " .. dbody)

menu.action()
assert(next(BAGS.astro) == nil and next(BAGS.holdA) == nil and next(BAGS.base) == nil,
  "one press empties the pack, the hold and the warehouse")
assert(company.earned >= want, "…and pays for all of it, got: " .. company.earned)
assert(nodes["Facility Body"].text:find("sold for"),
  "…and the panel says so, got: " .. nodes["Facility Body"].text)
assert(nodes["Facility Action"].text:find("Nothing to sell"),
  "…leaving nothing to sell, got: " .. nodes["Facility Action"].text)

-- A delivery contract on the books keeps ITS material back: selling the ore a
-- Prospector contract is waiting for would quietly un-do the job.
BAGS.astro = { iron = 10, silica = 4 }
local missions = { valid = true, reserves = function(m) return m == "iron" end }
local with_contract = _G.findScript
_G.findScript = function(kind)
  if kind == "missions" then return missions end
  return with_contract(kind)
end
menu.close(); menu.openMenu("FacDepot")
assert(nodes["Facility Action"].text:find("Sell the rest"),
  "with contract cargo aboard the sale says it sells the rest, got: " .. nodes["Facility Action"].text)
menu.action()
assert(BAGS.base.iron == 10 and not BAGS.base.silica,
  "…the contract's iron goes into the warehouse and the silica is sold")
assert(nodes["Facility Body"].text:find("kept"),
  "…and the panel says what it kept, got: " .. nodes["Facility Body"].text)
assert(nodes["Facility Action"].text:find("contract") or nodes["Facility Action"].text:find("Nothing"),
  "…with nothing left to sell, got: " .. nodes["Facility Action"].text)
_G.findScript = with_contract
menu.close()
_G.findScript, _G.findScripts = prev_findScript, prev_findScripts

print("smoke_facilities OK — proximity (parented + world), open/close, tracking readout, hangar→builder, board/leave, atomic panel, depot with cargo")
