-- SMOKE HARNESS for objectives.lua — the card that tells a new player what to
-- do next. Drives the whole opening flow past the step machine and reads back
-- what the card would say:
--
--   colony going up  →  sign your first contract  →  build a craft
--     →  fly it  →  sell what you brought home
--
-- The step is DERIVED from the same state the game runs on, so the thing this
-- harness is really checking is that no state the player can reach leaves the
-- card blank, pointing at a building that isn't there, or telling them to do
-- something they have already done.
--
--   luajit solar/tests/smoke_objectives.lua

local checks = 0
local function ok(cond, msg)
  checks = checks + 1
  if not cond then
    print("✗ CHECK FAILED: " .. msg)
    os.exit(1)
  end
end

_G.time = 0.0

-- ── the world ───────────────────────────────────────────────────────────────
-- Offset, orbiting planet; facilities planet-parented (their coords are
-- body-relative); astronaut top-level (world). Exactly the two frames the real
-- scene has, so a card that measured them raw would read hundreds of metres out.
local planet = { name = "Ryilex", x = 4800, y = 0, z = -1200, radius = 214, soi = 9000 }
local planet_node = { name = planet.name, x = planet.x, y = planet.y, z = planet.z }

local nodes = {}
local function add(n) nodes[n.name] = n; return n end

local astro = add({ name = "Astronaut", visible = true,
  x = planet.x, y = planet.y + planet.radius, z = planet.z })
add(planet_node)
-- The ring, body-relative: command centre 36 m out along +Z, hangar along -Z.
add({ name = "FacCommand", parent = planet_node, x = 0, y = planet.radius, z = 36 })
add({ name = "FacHangar",  parent = planet_node, x = 0, y = planet.radius, z = -36 })
add({ name = "FacDepot",   parent = planet_node, x = 32, y = planet.radius, z = 0 })

local card = add({ name = "Objectives", __el = { visible = false },
  getcomponent = function(self) return self.__el end })

_G.find = function(n) return nodes[n] end
_G.space = {
  dominant = function() return planet.name end,
  body = function(n) if n == planet.name then return planet end end,
}
local KEYS = {}
_G.input = { pressed = function(k) return KEYS[k] == true end }
_G.log = function() end
local STORE = {}
_G.save = { get = function(k) return STORE[k] end, set = function(k, v) STORE[k] = v end }

-- What the card was last told to draw.
local drawn = nil
_G.ui = { make = function(_, tree) drawn = tree end }
local function lines()
  local out = {}
  for _, row in ipairs((drawn or {}).items or {}) do out[#out + 1] = row.text or "" end
  return out
end
local function says(needle)
  for _, l in ipairs(lines()) do if l:find(needle, 1, true) then return true end end
  return false
end

-- ── the scripts it reads ────────────────────────────────────────────────────
local base = { sited = false }
local co = {
  money = function(v) return "$" .. tostring(math.floor(v or 0)) end,
}
local missions = {
  active = nil,
  catalogue = {
    firstflight = { id = "firstflight", title = "First Flight", reward = 4500,
      brief = "Get something off the pad.",
      goals = { { kind = "altitude", value = 2000, label = "Reach 2,000 m" },
                { kind = "land", label = "Land intact" } } },
    prospect = { id = "prospect", title = "Prospector", reward = 8000,
      brief = "Mine ore and put 30 units through the depot.",
      goals = { { kind = "deliver", class = "ore", value = 30,
                  label = "30 units of ore in the warehouse" } } },
  },
  done = {},
}
function missions.byId(id) return missions.catalogue[id] end
function missions.goalLines()
  local m = missions.active and missions.byId(missions.active)
  if not m then return {} end
  local out = {}
  for i, g in ipairs(m.goals) do
    out[#out + 1] = ((missions.ticked or {})[i] and "✓ " or "○ ") .. g.label
  end
  return out
end
function missions.completed() return missions.done end

local pack = 0.0
local inv = {
  mass = function(_) return pack end,
  totalValue = function(_) return pack * 20 end,
}
-- The camera the bearing is measured against: looking along +Z (towards the
-- command centre) from the astronaut.
local cam = { fwd_x = 0, fwd_y = 0, fwd_z = 1 }
local fleet = {}

-- The walker is the ONE place that decides whether the crew is out and about:
-- it watches the fleet and the loading flag, publishes `onFoot`, and every
-- panel in the game asks it rather than re-deriving the answer. Modelled here
-- the same way, so this test drives the gate the game actually uses.
local walker = { onFoot = true }

_G.findScript = function(kind)
  if kind == "planet_walker" then return walker end
  if kind == "base_facilities" then return base end
  if kind == "missions" then return missions end
  if kind == "company" then return co end
  if kind == "inventory" then return inv end
  if kind == "planet_camera" then return cam end
  return nil
end
_G.findScripts = function(kind)
  if kind == "vessel_controller" then return fleet end
  return {}
end

-- ── load ────────────────────────────────────────────────────────────────────
local chunk = assert(loadfile("solar/scripts/objectives.lua"))
chunk()
_G.params = { enabled = 1, arrived = 24.0 }
start(card)
ok(card.__el.visible == false, "the card starts hidden")

-- 1. The colony is still going up.
update(card, 1 / 60)
ok(card.__el.visible == true, "the card shows once the world is up")
ok(says("base is going up"), "step 1 should say the colony is being sited: " ..
  table.concat(lines(), " | "))

-- 2. Sited, nothing signed: go and sign the first contract.
base.sited = true
update(card, 1 / 60)
ok(says("Sign your first contract"), "step 2 should send you to sign a contract")
ok(says("Command Centre"), "step 2 should name the Command Centre")
ok(says("36 m"), "step 2 should say how far it is: " .. table.concat(lines(), " | "))
ok(says("straight ahead"), "step 2 should say which way — the camera is facing it")

-- Turn around: the same target, the other bearing. A card that always says
-- "ahead" is a card that is not actually pointing at anything.
cam.fwd_z = -1
update(card, 1 / 60)
ok(says("directly behind you"), "the bearing must follow where you're looking: " ..
  table.concat(lines(), " | "))
cam.fwd_z = 1

-- LEFT AND RIGHT. The engine is right-handed and Y-up: a camera looking down
-- -Z has +X on the right of the screen, so screen-right is FORWARD × UP. The
-- card used UP × FORWARD — screen-left — and told a new player the Command
-- Centre was "ahead and to your left" while it stood on the right of the
-- screen. Facing +X, the centre (+Z of us) is on the right; facing -X, the left.
cam.fwd_x, cam.fwd_z = 1, 0
update(card, 1 / 60)
ok(says("to your right") and not says("left"),
  "facing +X the command centre at +Z is on your RIGHT: " .. table.concat(lines(), " | "))
cam.fwd_x = -1
update(card, 1 / 60)
ok(says("to your left") and not says("right"),
  "facing -X the command centre at +Z is on your LEFT: " .. table.concat(lines(), " | "))
-- Half-way round: ahead-and-right, then behind-and-left.
cam.fwd_x, cam.fwd_z = 1, 1
update(card, 1 / 60)
ok(says("ahead and to your right"), "45° off, to the right: " .. table.concat(lines(), " | "))
cam.fwd_x, cam.fwd_z = -1, -1
update(card, 1 / 60)
ok(says("behind you, to the left"), "135° off, to the left: " .. table.concat(lines(), " | "))
-- The bearing has its own row: run on after the distance it wrapped, and the
-- last word of it sat alone on a line.
local where_row
for _, r in ipairs((drawn or {}).items or {}) do if r.key == "where" then where_row = r.text end end
ok(where_row and not where_row:find("behind", 1, true),
  "the name-and-distance row carries no bearing: " .. tostring(where_row))
cam.fwd_x, cam.fwd_z = 0, 1

-- 3. Standing at it: stop giving directions, start giving the verb.
astro.z = planet.z + 30
update(card, 1 / 60)
ok(says("press E"), "at the door the card should say press E, not a distance")
astro.z = planet.z

-- 4. Contract signed, no craft: go and build one.
missions.active = "firstflight"
update(card, 1 / 60)
ok(says("Build a craft"), "step 4 should send you to the hangar")
ok(says("Vehicle Assembly"), "step 4 should name the Vehicle Assembly")
ok(says("Reach 2,000 m"), "step 4 should list the contract's goals")
ok(says("$4500"), "step 4 should say what the contract pays")

-- 5. A craft exists: the card gets out of the way and just tracks the flight.
fleet = { { node = { valid = true } } }
update(card, 1 / 60)
ok(says("First Flight"), "step 5 should be the contract itself")
ok(not says("Build a craft"), "step 5 must not still be telling you to build one")

-- 6. A contract you can do on foot never sends you to the hangar — it says
-- how to get what it wants, which is the only place the card teaches mining.
missions.active = "prospect"
update(card, 1 / 60)
ok(not says("Build a craft"), "a delivery contract is not a reason to build a rocket")
ok(says("30 units of ore"), "a delivery contract should show its delivery goal")
ok(says("Terrain Laser") and says("LEFT MOUSE"),
  "a delivery contract should say how to mine: " .. table.concat(lines(), " | "))

-- …and once there is ore in the pack, where to take it.
pack = 12.5
update(card, 1 / 60)
ok(says("Commerce Depot"), "carrying ore for a delivery should point at the depot: " ..
  table.concat(lines(), " | "))
ok(says("30 units of ore"), "...still showing the contract's goal")

-- 7. A handful of cargo does NOT take over from the contract you're flying.
missions.active = "firstflight"
fleet = { { node = { valid = true } } }
update(card, 1 / 60)
ok(says("First Flight") and not says("Sell what you're carrying"),
  "a few kilos in the pack must not replace the contract's guidance: " ..
  table.concat(lines(), " | "))
-- A pack most of the way full does: that IS the next thing to do.
pack = 60.0
update(card, 1 / 60)
ok(says("Sell what you're carrying"), "a full pack should send you to the depot")
ok(says("Commerce Depot"), "step 7 should name the depot")
ok(says("$1200"), "step 7 should price the pack: " .. table.concat(lines(), " | "))
-- …and so does any cargo with no contract on the books.
missions.active = nil
pack = 12.5
update(card, 1 / 60)
ok(says("Sell what you're carrying"), "with no contract, any cargo is worth selling")
pack = 0.0

-- 7b. No rocket and not the money for one: the card sends you mining.
missions.active = "firstflight"
fleet = {}
co.balance = function() return 200 end
update(card, 1 / 60)
ok(says("Raise money") and says("Terrain Laser"),
  "broke with no rocket, the card should send you mining: " .. table.concat(lines(), " | "))
co.balance = nil
missions.active = nil

-- 8. Every contract flown: the card asks for the next one, not the first.
missions.active = nil
missions.done = { missions.catalogue.firstflight }
update(card, 1 / 60)
ok(says("Sign your next contract"), "after one contract it should ask for the NEXT one")

-- 9. It gets out of the way. A facility panel and the ops board each own the
-- screen while they're up, and so does being in a pod.
--
-- FLYING IS MODELLED AS `piloting`, NOT AS A HIDDEN ASTRONAUT. The card used to
-- ask `astro.visible`, and so did this check — and the camera hides the body any
-- time it ends up close to it, which includes standing inside a building. That
-- made the card (and the facility prompt, and the mining laser) blink out
-- exactly where a player needed them.
walker.onFoot = false          -- the walker's answer: we're in a pod
astro.visible = false          -- the pod hides the body too; must not be what decides
update(card, 1 / 60)
ok(card.__el.visible == false, "the card hides while you're flying")

-- ...unless the cockpit is up and there's a contract on the books. The flight
-- HUD used to print the goals into its own text dump; now the card IS the
-- contract while you fly it, and only the contract — no directions, no brief.
local was_active = missions.active
local plain_find = _G.findScript
_G.findScript = function(kind)
  if kind == "flight_hud" then return { layout = { topLeft = 334 } } end
  return plain_find(kind)
end
missions.active = "firstflight"
update(card, 1 / 60)
ok(card.__el.visible == true and says("First Flight") and says("Reach 2,000 m"),
  "in the cockpit the card shows the contract: " .. table.concat(lines(), " | "))
ok(not says("Vehicle Assembly") and not says("off the pad"),
  "...and nothing but the contract: " .. table.concat(lines(), " | "))
missions.active = nil
update(card, 1 / 60)
ok(card.__el.visible == false, "...and with no contract, nothing at all")
missions.active = was_active
_G.findScript = plain_find
walker.onFoot = true
astro.visible = false          -- still hidden — but now only by the CAMERA
update(card, 1 / 60)
ok(card.__el.visible == true,
  "...but a camera that hid the body up close does NOT count as flying")
astro.visible = true
astro.visible = true

-- 10. And the hotkey.
KEYS["o"] = true
update(card, 1 / 60)
KEYS["o"] = false
ok(card.__el.visible == false, "O hides the card")
KEYS["o"] = true
update(card, 1 / 60)
KEYS["o"] = false
ok(card.__el.visible == true, "O shows it again")

-- 11. THE REWARD. A contract pays itself the moment its last goal ticks — there
-- is no counter to walk to and no clerk to see — and the only announcement was a
-- Console line the player is not looking at. So a contract flown correctly and
-- paid in full looked exactly like a contract that had quietly failed: "nothing
-- indicated anywhere where to claim my reward".
missions.active = nil
missions.lastPaid = { id = "firstflight", title = "First Flight",
                      reward = 4500, at = _G.time }
update(card, 1 / 60)
ok(says("CONTRACT COMPLETE"), "a paid contract announces itself: " ..
  table.concat(lines(), " | "))
ok(says("First Flight"), "...and names which one")
ok(says("4500"), "...and how much it paid")
ok(says("Ops Board"), "...and what to do next")

-- It has to reach you MID-FLIGHT: the last goal of a flight contract is "land
-- intact", which ticks while you are still in the seat, with the card otherwise
-- stood down because the flight HUD owns the screen.
walker.onFoot = false
update(card, 1 / 60)
ok(card.__el.visible == true and says("CONTRACT COMPLETE"),
  "...and it still shows while you are flying, which is when it happens")
walker.onFoot = true

-- And then it gets out of the way.
_G.time = _G.time + 30.0
update(card, 1 / 60)
ok(not says("CONTRACT COMPLETE"), "...then stands down and the card carries on")
ok(says("Sign your next contract"), "...back to the next step: " ..
  table.concat(lines(), " | "))

-- ── CONTRACTS THAT NAME ANOTHER WORLD ───────────────────────────────────────
-- Generated contracts (missions.lua genSpec) send you to a named body. The card
-- used to answer every delivery with "Mine ore for the contract" — wrong when
-- the crystal a haul wants grows on Nami and not under your feet.
missions.lastPaid = nil
missions.catalogue["g1-haul-Nami"] = { id = "g1-haul-Nami", gen = true, kind = "haul", body = "Nami",
  title = "Haul: Crystal from Nami", reward = 9000, brief = "Nami has crystal.",
  goals = { { kind = "flag", body = "Nami", label = "Set foot on Nami" },
            { kind = "deliver", mat = "crystal", kg = 40, after = 1,
              label = "40 kg of Crystal in the warehouse" } } }
missions.catalogue["g2-survey-Nami"] = { id = "g2-survey-Nami", gen = true, kind = "survey", body = "Nami",
  title = "Survey: Nami", reward = 2600, brief = "Fly by.",
  goals = { { kind = "soi", body = "Nami", label = "Enter Nami's sphere of influence" } } }
_G.findScript = (function(prev)
  local mats = { label = function(m) return m == "crystal" and "Crystal" or m end }
  return function(kind) if kind == "materials" then return mats end return prev(kind) end
end)(_G.findScript)
local held = 0
inv.count = function(_, mat) return mat == "crystal" and held or 0 end
pack = 0.0
missions.ticked = {}
fleet = { { node = { valid = true } } }

missions.active = "g2-survey-Nami"
update(card, 1 / 60)
ok(says("Fly to Nami"), "a survey says where to fly: " .. table.concat(lines(), " | "))

missions.active = "g1-haul-Nami"
update(card, 1 / 60)
ok(says("Land on Nami and step out"), "a haul starts with getting there: " .. table.concat(lines(), " | "))
ok(not says("Mine ore"), "...not with mining at home")

missions.ticked = { true }
update(card, 1 / 60)
ok(says("Bring 40 kg of Crystal from Nami"), "then it names what to bring and from where: "
  .. table.concat(lines(), " | "))

local plain_dominant = space.dominant
space.dominant = function() return "Nami" end
update(card, 1 / 60)
ok(says("Collect Crystal here on Nami"), "standing on Nami, it says to collect it: "
  .. table.concat(lines(), " | "))
space.dominant = plain_dominant

held = 12
update(card, 1 / 60)
ok(says("Sell the Crystal at the depot") and says("Commerce Depot"),
  "home with it, it sends you to the depot: " .. table.concat(lines(), " | "))
held = 0

fleet = {}
missions.ticked = {}
update(card, 1 / 60)
ok(says("Build a craft that can reach Nami") and says("Vehicle Assembly"),
  "with no craft, it sends you to build one that can get there: " .. table.concat(lines(), " | "))
missions.active = nil

print(string.format("OBJECTIVES SMOKE OK — %d checks passed", checks))
