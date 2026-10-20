-- SMOKE HARNESS for flight_ops.lua — how a flight ends.
--
-- The bug this exists to stop coming back: you launch, you land somewhere that
-- is not your launchpad, and there is no route back into the game. So every
-- check here is about the LOOP closing — that a parked craft always offers
-- exactly one way out, that the way out depends on where you parked, and that
-- neither way ever strands the crew or silently eats the craft.
--
--   luajit solar/tests/smoke_flight.lua

local T = 0.0

local API, store, logs = {}, {}, {}
API.save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end }
function API.log(m) logs[#logs + 1] = tostring(m) end
function API.print(m) logs[#logs + 1] = tostring(m) end

-- The home world, orbiting: everything positional here is body-relative on
-- purpose, because that is the frame the real base is sited in.
local BODY = { name = "Golil", x = 4000, y = -900, z = 2200, radius = 400, soi = 1e6 }
API.space = {
  bodies = function() return { BODY } end,
  body = function(n) return (n == BODY.name) and BODY or nil end,
  dominant = function() return BODY.name end,
}

-- The ground: a sphere of radius 400 about the body.
function API.raycast(ox, oy, oz, dx, dy, dz, maxd)
  local rx, ry, rz = ox - BODY.x, oy - BODY.y, oz - BODY.z
  local b = rx * dx + ry * dy + rz * dz
  local c = rx * rx + ry * ry + rz * rz - BODY.radius * BODY.radius
  local disc = b * b - c
  if disc < 0 then return nil end
  local t = -b - math.sqrt(disc)
  if t < 0 or t > (maxd or 1e9) then return nil end
  return { x = ox + dx * t, y = oy + dy * t, z = oz + dz * t, distance = t }
end

local cards = {}
API.ui = { make = function(_, tree) cards[#cards + 1] = tree end }
local function card_text()
  local tree = cards[#cards]
  if not tree then return "" end
  local out = {}
  for _, r in ipairs(tree.items or {}) do out[#out + 1] = tostring(r.text or "") end
  return table.concat(out, "\n")
end

local keys = {}
API.input = { pressed = function(k) return keys["!" .. k] == true end,
              key = function(k) return keys[k] == true end }
local function press(k) keys["!" .. k] = true end
local function clear_presses()
  for k in pairs(keys) do if k:sub(1, 1) == "!" then keys[k] = nil end end
end

-- The colony. `base_facilities` sites it body-relative and publishes the centre;
-- the tracking dish stands 40 m out from it, PARENTED to the planet (so its own
-- coordinates are body-relative and only become world through the parent —
-- exactly the frame mix that has bitten this project twice).
local BASE = { x = 0, y = BODY.radius, z = 0 }
local PLANET = { name = BODY.name, x = BODY.x, y = BODY.y, z = BODY.z }
local DISH = { name = "FacTracking", parent = PLANET,
               x = BASE.x + 40, y = BASE.y, z = BASE.z }
local ASTRO = { name = "Astronaut", valid = true, visible = false,
                x = 0, y = 0, z = 0, vx = 9, vy = 9, vz = 9 }
API.find = function(n)
  if n == "FacTracking" then return DISH end
  if n == "Astronaut" then return ASTRO end
  return nil
end

-- ── the craft ───────────────────────────────────────────────────────────────
-- Only the interface flight_ops uses, but faithfully: `standDown` is the real
-- contract (place the crew, show them, stop piloting) and `recoverCraft`
-- destroys the hull, so a test can tell the two endings apart.
local VNODE = { name = "Kestrel I", valid = true,
                x = BODY.x, y = BODY.y + BODY.radius, z = BODY.z }
local VESSEL = {
  node = VNODE, craftName = "Kestrel I", piloting = true,
  grounded = false, speed = 0.0, recovered = false, stood = 0, value = 5400,
}
function VESSEL.parked() return VESSEL.grounded and VESSEL.speed < 1.5 end
function VESSEL.recoverValue() return VESSEL.value end
function VESSEL.recoverReady()
  if not VESSEL.parked() then return false, "not landed" end
  return true, nil
end
function VESSEL.standDown(_, x, y, z, vx, vy, vz)
  VESSEL.piloting = false
  VESSEL.stood = VESSEL.stood + 1
  if x then
    ASTRO.x, ASTRO.y, ASTRO.z = x, y, z
    ASTRO.vx, ASTRO.vy, ASTRO.vz = vx or 0, vy or 0, vz or 0
  end
  ASTRO.visible = true
end
function VESSEL.recoverCraft()
  VESSEL.recovered = true
  VNODE.valid = false
  VESSEL.standDown(VNODE, BODY.x + BASE.x, BODY.y + BASE.y + 2, BODY.z + BASE.z)
end

local envs = {}
local function load_script(path, kind)
  local env = setmetatable({}, { __index = function(_, k)
    if k == "time" then return T end
    return API[k] or _G[k]
  end })
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  env.params = {}
  for k, v in pairs(env.defaults or {}) do env.params[k] = v end
  envs[kind] = env
  return env
end
API.findScript = function(k) return envs[k] end
API.findScripts = function(k)
  if k == "vessel_controller" then return { VESSEL } end
  return envs[k] and { envs[k] } or {}
end

-- ⚠ `baseX/baseY/baseZ` ARE WORLD COORDINATES. `base_facilities` recomputes them
-- from the body's live position every frame (`b.x + save("base.x")`), so what it
-- publishes is the answer, not an offset — and `cheats.lua` has always read them
-- that way.
--
-- This stub used to publish the body-RELATIVE offset, which is the same mistake
-- `flight_ops` was making, so the two agreed and every check below passed while
-- the real game put the colony an orbital radius away: standing in the middle of
-- the base, the card read "5.4 km from the base" and offered a shuttle home. A
-- stub written from the consumer instead of the producer validates the consumer's
-- assumption, which is worth exactly nothing.
envs.base_facilities = { sited = true, baseBody = BODY.name,
                         baseX = BODY.x + BASE.x,
                         baseY = BODY.y + BASE.y,
                         baseZ = BODY.z + BASE.z }
envs.company = { money = function(n) return "$" .. tostring(n) end }
envs.missions = {
  active = "firstflight",
  activeLine = function() return "First Flight  1/2" end,
  goalLines = function() return { "✓ Reach 2,000 m", "○ Land with the pod intact" } end,
}

local fo = load_script("solar/scripts/flight_ops.lua", "flight_ops")
local NODE = { name = "Flight Ops", getcomponent = function() return { visible = false } end }
fo.start(NODE)

local checks = {}
local function check(desc, ok, detail)
  checks[#checks + 1] = { desc = desc, ok = ok and true or false, detail = detail }
end
local function tick(n)
  for _ = 1, (n or 1) do
    T = T + 0.05
    fo.update(NODE, 0.05)
    clear_presses()
  end
end

-- ── 0. on the pad: how to launch, and no way to "end" a flight never flown ───
-- A rocket still clamped on the pad is parked, and it is near the base — which
-- is exactly the recovery test, so the card offered to scrap it before launch.
VESSEL.hasFlown = false
VESSEL.tele = { anchored = true, ready = true }
VESSEL.grounded, VESSEL.speed = true, 0.0
tick(1)
check("an unflown craft on the pad is PRELAUNCH, not recoverable", fo.mode == "prelaunch", fo.mode)
check("...and the card says how to launch", card_text():find("RELEASE CLAMPS") ~= nil, card_text())
press("enter")
keys["enter"] = true
tick(30)
keys["enter"] = nil
check("...and ENTER ends nothing", VESSEL.piloting and VESSEL.stood == 0 and not VESSEL.recovered)
VESSEL.hasFlown, VESSEL.tele = true, nil
VESSEL.grounded, VESSEL.speed = false, 0.0

-- ── 1. in flight: no way out, and no card over the cockpit ──────────────────
local drawn = #cards
tick(1)
check("a craft in flight offers nothing to press", fo.mode == "flying", fo.mode)
check("...and draws no card over the instruments", #cards == drawn, #cards - drawn)
press("enter")
tick(1)
check("...and ENTER does nothing while you're still moving",
  VESSEL.piloting and VESSEL.stood == 0)

-- ── 2. down a long way from home: leave it, come home ───────────────────────
-- 6 km round the curve — a real "I landed somewhere else" landing.
VNODE.x = BODY.x + 300
VNODE.y = BODY.y + 264
VNODE.z = BODY.z
VESSEL.grounded, VESSEL.speed = true, 0.2
tick(1)
check("a craft down away from home offers to be LEFT there", fo.mode == "leave", fo.mode)
check("...labelled as leaving the craft, not scrapping it",
  card_text():find("leave the craft here") ~= nil, card_text())
check("...and it never claims a refund it isn't paying",
  card_text():find("refund") == nil)
check("the contract stays on the objectives card, not repeated here", (function()
  local t = card_text()
  return t:find("Reach 2,000 m") == nil and t:find("Land with the pod intact") == nil
end)(), card_text())

press("enter")
tick(1)
check("ending the flight stands the crew down", not VESSEL.piloting and VESSEL.stood == 1)
check("...and the craft is NOT recovered, destroyed or emptied",
  not VESSEL.recovered and VNODE.valid)
check("...the crew is visible again", ASTRO.visible)
check("...and at rest, not still carrying the landing's velocity",
  ASTRO.vx == 0 and ASTRO.vy == 0 and ASTRO.vz == 0)

-- Home is the TRACKING STATION, on the ground, and near it — not at the origin,
-- not at twice the world position (the frame mix), not inside the dish.
local dx = ASTRO.x - (BODY.x + DISH.x)
local dy = ASTRO.y - (BODY.y + DISH.y)
local dz = ASTRO.z - (BODY.z + DISH.z)
local to_dish = math.sqrt(dx * dx + dy * dy + dz * dz)
check("...put down at the tracking station", to_dish < 20.0,
  string.format("%.1f m from the dish", to_dish))
check("...but not standing inside it", to_dish > 4.0, to_dish)
local alt = math.sqrt((ASTRO.x - BODY.x) ^ 2 + (ASTRO.y - BODY.y) ^ 2
                    + (ASTRO.z - BODY.z) ^ 2) - BODY.radius
check("...and ON THE GROUND, not hovering or buried", alt > 0.5 and alt < 4.0,
  string.format("%.2f m above the surface", alt))

-- ── 3. down at the base: the crane ──────────────────────────────────────────
VESSEL.piloting, VESSEL.stood, VESSEL.recovered = true, 0, false
VNODE.valid = true
VNODE.x, VNODE.y, VNODE.z = BODY.x + BASE.x + 30, BODY.y + BASE.y, BODY.z + BASE.z
tick(1)
check("a craft down at the base offers the crane instead", fo.mode == "recover", fo.mode)
check("...and quotes what the hardware is worth back",
  card_text():find("5400") ~= nil, card_text())
-- Recovery scraps the craft, so it is a HOLD: a tap does nothing.
press("enter")
keys["enter"] = true
tick(1)
keys["enter"] = nil
tick(1)
check("a tap of ENTER does not recover", not VESSEL.recovered and VNODE.valid)
keys["enter"] = true
tick(12)
check("...half a second of holding doesn't either", not VESSEL.recovered)
tick(10)
keys["enter"] = nil
check("recovering scraps the craft and banks it", VESSEL.recovered and not VNODE.valid)
check("...and stands the crew down at the colony", not VESSEL.piloting)

-- ── 4. the two endings are decided by DISTANCE, not by luck ─────────────────
VESSEL.piloting, VESSEL.recovered = true, false
VNODE.valid = true
VNODE.x = BODY.x + BASE.x + fo.params.home_range - 10
VNODE.y = BODY.y + BASE.y
VNODE.z = BODY.z + BASE.z
tick(1)
check("just inside the crane's reach is a recovery", fo.mode == "recover", fo.mode)
VNODE.x = BODY.x + BASE.x + fo.params.home_range + 10
tick(1)
check("...and just outside it is not", fo.mode == "leave", fo.mode)

-- ── 5. no base yet: the button refuses honestly ─────────────────────────────
-- A brand-new save mid-siting has nowhere to send anyone. It must say so rather
-- than teleporting the crew to the origin of the universe.
envs.base_facilities.sited = false
VESSEL.piloting, VESSEL.stood = true, 0
local ax, ay, az = ASTRO.x, ASTRO.y, ASTRO.z
tick(1)
press("enter")
tick(1)
check("with no base sited, ending a flight refuses rather than stranding anyone",
  VESSEL.piloting and VESSEL.stood == 0)
check("...and says why", card_text():find("no base") ~= nil, card_text())
check("...and doesn't move the crew", ASTRO.x == ax and ASTRO.y == ay and ASTRO.z == az)
envs.base_facilities.sited = true

-- ── 6. on foot AT the base: the card goes away ──────────────────────────────
-- Standing in the colony is the normal state of the game, and a card offering
-- to fly you to where you already are would be up permanently.
VESSEL.piloting = false
envs.planet_walker = { onFoot = true }
local BX, BY, BZ = BODY.x + BASE.x, BODY.y + BASE.y, BODY.z + BASE.z
ASTRO.x, ASTRO.y, ASTRO.z = BX + 30, BY, BZ
tick(1)
check("the card is gone once you're out of the pod and home", fo.mode == nil, tostring(fo.mode))

-- A row that wraps must not ALSO carry its own line breaks. The card is narrow
-- enough that a hand-wrapped line wraps a second time, and the row's `h = "fit"`
-- then measures fewer lines than actually get drawn — which is rows sitting on
-- top of each other on screen. The wider objectives card has the same shape and
-- has always looked fine, which is exactly why this went unnoticed.
local function wrapped_rows_are_clean()
  for _, tree in ipairs(cards) do
    for _, r in ipairs(tree.items or {}) do
      if r.wrap and tostring(r.text):find("\n") then return false, r.text end
    end
  end
  return true
end

-- ── 7. STRANDED ON FOOT: the softlock that shipped ──────────────────────────
-- Reported after a landing went wrong: *"as soon as it touched the ground it
-- disintegrated and i got sent flying off infinitely into the void and got
-- softlocked... theres still no way to return to the base either as a new
-- astronaut."* Everything above this line only ever ran while somebody was
-- piloting something, which is exactly the state a breakup takes away from you.
local FUNDS = 100000
envs.company.balance = function() return FUNDS end
envs.company.afford = function(a) return FUNDS >= (a or 0) end
envs.company.spend = function(a, _)
  a = math.max(0, math.floor(a or 0))
  if a > FUNDS then return false end
  FUNDS = FUNDS - a
  return true
end

ASTRO.x, ASTRO.y, ASTRO.z = BX + 9000, BY, BZ    -- 9 km out, on foot, no craft
ASTRO.vx, ASTRO.vy, ASTRO.vz = 210, -60, 15      -- still carrying a trajectory
tick(1)
check("stranded on foot, the card comes back", fo.mode == "pickup", tostring(fo.mode))
check("...offering a pickup", card_text():find("CALL FOR PICKUP") ~= nil, card_text())
check("...priced by distance", fo.fee > fo.params.pickup_base,
  string.format("fee %d vs base %d", fo.fee, fo.params.pickup_base))
check("...and capped", fo.fee <= fo.params.pickup_max)

local before_funds, quoted = FUNDS, fo.fee
press("enter")
tick(1)
check("ENTER brings the crew home", math.abs(ASTRO.x - BX) < 60 and math.abs(ASTRO.z - BZ) < 60,
  string.format("%.0f,%.0f,%.0f", ASTRO.x, ASTRO.y, ASTRO.z))
-- The crew reaching this function has usually been thrown clear of something.
-- Arriving at the colony still carrying that velocity just strands them again.
check("...at rest", ASTRO.vx == 0 and ASTRO.vy == 0 and ASTRO.vz == 0,
  string.format("%.0f,%.0f,%.0f", ASTRO.vx, ASTRO.vy, ASTRO.vz))
check("...and bills the company", before_funds - FUNDS == quoted,
  string.format("charged %d, quoted %d", before_funds - FUNDS, quoted))
check("...and the card clears once you're home", (tick(1) or fo.mode) == nil, tostring(fo.mode))

-- 7b. BROKE AND STRANDED. The case the whole feature exists for: a fee that can
-- refuse is a fee that recreates the softlock it was written to end.
FUNDS = 12
ASTRO.x, ASTRO.y, ASTRO.z = BX + 40000, BY, BZ
tick(1)
check("a broke crew is still offered the pickup", fo.mode == "pickup", tostring(fo.mode))
check("...and told the rest is written off", card_text():find("written off") ~= nil, card_text())
press("enter")
tick(1)
check("...and it happens anyway", math.abs(ASTRO.x - BX) < 60,
  string.format("%.0f", ASTRO.x))
check("...taking what there was", FUNDS == 0, tostring(FUNDS))

-- 7c. OFF THE MAP. Thrown clear of a breakup hard enough that no world is
-- underneath any more — `crew_distance` has nothing to measure against. That is
-- the case that most needs the offer, so a missing distance must ENABLE the
-- pickup rather than quietly suppress it.
FUNDS = 100000
local real_find = API.find
API.find = function(n) if n == "Astronaut" then return nil end return real_find(n) end
tick(1)
check("with the crew off the map entirely, the pickup is still offered",
  fo.mode == "pickup", tostring(fo.mode))
check("...priced at the cap", fo.fee == fo.params.pickup_max, tostring(fo.fee))
API.find = real_find

-- ── 8. ABORT FLIGHT: the way home that is always there ──────────────────────
-- Review, 2026-10: END FLIGHT refuses in "flying" mode, so an empty craft in a
-- solar orbit could never end its flight. Abort works from anywhere, for a fee
-- it never refuses, and leaves the craft where it is.
envs.planet_walker = { onFoot = false }
VESSEL.piloting, VESSEL.stood, VESSEL.recovered, VESSEL.hasFlown = true, 0, false, true
VNODE.valid = true
VESSEL.grounded, VESSEL.speed = false, 30.0
VNODE.x, VNODE.y, VNODE.z = BODY.x + BASE.x + 2000, BODY.y + BASE.y + 900, BODY.z + BASE.z
tick(1)
check("in flight there is still no END FLIGHT", fo.mode == "flying", tostring(fo.mode))
local q = fo.abortQuote()
check("...but there is an abort", q and q.kind == "abort", q and q.kind)
check("...priced by distance from the base, under the cap", q and q.fee > fo.params.abort_base
  and q.fee < fo.params.abort_max, q and q.fee)
-- Out of home's sphere entirely (a solar orbit): the cap, never nothing.
local real_dom = API.space.dominant
API.space.dominant = function() return "Sun" end
q = fo.abortQuote()
check("a craft off home's world aborts at the cap", q and q.fee == fo.params.abort_max, q and q.fee)
check("the pause menu row names it and its fee", (fo.abortLabel() or ""):find("Abort flight")
  and (fo.abortLabel() or ""):find("$" .. math.floor(fo.params.abort_max), 1, true), fo.abortLabel())
FUNDS = 700
check("one click only arms it", fo.abortClick() == false and VESSEL.piloting and VESSEL.stood == 0)
check("...and the row asks for the confirm", (fo.abortLabel() or ""):find("Confirm"), fo.abortLabel())
check("the second click brings the crew home", fo.abortClick() == true and not VESSEL.piloting
  and VESSEL.stood == 1)
check("...to the base", math.abs(ASTRO.x - BX) < 60 and math.abs(ASTRO.z - BZ) < 60,
  string.format("%.0f,%.0f,%.0f", ASTRO.x, ASTRO.y, ASTRO.z))
check("...the craft is left flying, not destroyed or recovered", VNODE.valid and not VESSEL.recovered)
check("...and a short account pays what it has (never refuses)", FUNDS == 0, FUNDS)
API.space.dominant = real_dom
-- A craft still on its pad has nothing to abort: F gets you out of it.
VESSEL.piloting, VESSEL.hasFlown = true, false
check("nothing to abort on the pad", fo.abortQuote() == nil)
VESSEL.hasFlown = true

-- ── 9. THE FLEET: a craft you leave is still there next time ────────────────
-- The README promised you could fly back out to a craft left by END FLIGHT;
-- nothing saved it, so one trip to the Vehicle Assembly and it was gone.
local ASM = { mass = 3.6, grounded = true }
API.assembly = {
  info = function(n) return { origin = { x = n.x, y = n.y, z = n.z }, grounded = ASM.grounded,
                              mass = ASM.mass, com = { x = n.x, y = n.y, z = n.z } } end,
  -- assembly.rebuild(node [, fn]): fn runs once the compound is whole (0.117).
  rebuild = function(n, fn) n.rebuilt = true if fn then fn(n) end end,
  impulseAt = function(n, imp) n.impulse = imp end,
}
API.vec3 = function(x, y, z) return { x = x, y = y, z = z } end
local PARTS = {
  { uid = 1, id = "pod", prefab = "PartPod", kind = "crewed", x = 0, y = 2.3, z = 0 },
  { uid = 2, id = "tankS", prefab = "PartTankS", kind = "tank", fuel = 60, x = 0, y = 1.4, z = 0 },
  { uid = 3, id = "engineS", prefab = "PartEngineS", kind = "engine", x = 0, y = 0.2, z = 0 },
}
VNODE.id, VNODE.pitch, VNODE.yaw, VNODE.roll = 41, 0, 0, 0
VNODE.vx, VNODE.vy, VNODE.vz = 0, 0, 0
VNODE.x, VNODE.y, VNODE.z = BODY.x + 300, BODY.y + 264, BODY.z
function VESSEL.dockManifest()
  local out = {}
  for _, r in ipairs(PARTS) do out[#out + 1] = { uid = r.uid, rec = r, hp = 1 } end
  return { name = "Kestrel I", parts = out, fuel = 22, charge = 0 }
end
-- The controller's own part list wins over the position-matched docking
-- manifest (which, in the engine, dropped every part a rebuild had re-based).
local manifest_parts = VESSEL.dockManifest
function VESSEL.dockManifest() return { name = "Kestrel I", parts = { { rec = PARTS[3] } }, fuel = 1 } end
function VESSEL.fleetParts() return { parts = PARTS, fuel = 22, charge = 0, pod = true } end
VNODE.name = "Kestrel I"
VESSEL.piloting = false
T = T + 2
tick(1)
local fl = store["fleet.craft"] or {}
local fid, rec = next(fl)
check("a flown craft is written to the save", rec ~= nil and rec.name == "Kestrel I", rec and rec.name)
check("...where it is, body-relative", rec and rec.body == BODY.name and math.abs(rec.x - 300) < 1e-6
  and math.abs(rec.y - 264) < 1e-6, rec and string.format("%s %.0f %.0f", rec.body, rec.x, rec.y))
check("...landed, with its fuel and every part", rec and rec.landed and rec.fuel == 22 and #rec.parts == 3)
local rows = fo.fleetList()
check("the Tracking Station board lists it", #rows == 1 and rows[1].name == "Kestrel I"
  and rows[1].status == "landed" and rows[1].live, rows[1] and rows[1].status)
check("...with no dish, taking control is a billed transfer", rows[1] and rows[1].fee > 0, rows[1] and rows[1].fee)
FUNDS = 0
local ok, why = fo.takeControlOf(fid)
check("...refused when the account can't cover it (nobody is stranded at the base)",
  not ok and tostring(why):find("costs"), why)
FUNDS = 5000
function VESSEL.takeControl() VESSEL.piloting = true return true end
ok = fo.takeControlOf(fid)
check("TAKE CONTROL puts you in it", ok and VESSEL.piloting)
check("...and bills the transfer", FUNDS == 5000 - rows[1].fee, FUNDS)
-- Over a live comms link it is remote control, and free.
VESSEL.piloting = false
store["comms.ships"] = { v41 = { name = "Kestrel I" } }
check("over a live link the transfer is free", fo.fleetList()[1].fee == 0 and fo.fleetList()[1].link)

-- A NEW SESSION: the scene reloads, nothing is alive, and the record is rebuilt
-- on the ground it was left on — with the handoff its controller starts from.
local spawned = {}
local next_node = 900
API.spawn = function(prefab, pos, cb, parent)
  next_node = next_node + 1
  local n = { id = next_node, name = prefab, x = pos.x, y = pos.y, z = pos.z, valid = true,
              setAngles = function(self, y, p, r) self.yaw, self.pitch, self.roll = y, p, r end }
  spawned[#spawned + 1] = { prefab = prefab, node = n, parent = parent }
  if cb then cb(n) end
end
API.terrain = { warm = function() end }
local fo2 = load_script("solar/scripts/flight_ops.lua", "flight_ops")
fo2.start(NODE)
API.findScripts = function(k)
  if k == "vessel_controller" then return {} end
  return envs[k] and { envs[k] } or {}
end
T = T + 2
fo2.update(NODE, 0.05)
local vroot = spawned[1]
check("next session, the craft is rebuilt", vroot and vroot.prefab == "Vessel" and #spawned == 4,
  string.format("%d spawns", #spawned))
check("...where it was left", vroot and math.abs(vroot.node.x - (BODY.x + 300)) < 1.0
  and math.abs(vroot.node.y - (BODY.y + 264)) < 1.0)
local ho = vroot and store["dock.handoff." .. vroot.node.id]
check("...handing its controller the parts and the fuel it had", ho and #ho.parts == 3 and ho.fuel == 22)
check("...and assembled", vroot and vroot.node.rebuilt)
check("...its parts parented to it", spawned[2] and spawned[2].parent == vroot.node)
T = T + 5
fo2.update(NODE, 0.05)
check("a rebuilt craft whose controller hasn't started yet is not forgotten",
  (store["fleet.craft"] or {})[fid] ~= nil)

-- A craft left IN FLIGHT comes back on its orbit: the record carried along its
-- conic to now, and the velocity there handed to its controller, which pushes
-- it once (floptle/0402 keeps that push whole). No keep-alive hold, no top-up.
do
  local f = store["fleet.craft"] or {}
  f.cfly = { name = "Swift", body = BODY.name, x = 0, y = 900, z = 0, vx = 30, vy = 0, vz = 0,
             landed = false, fuel = 5, charge = 0, parts = { PARTS[1], PARTS[2], PARTS[3] }, stime = 10 }
  store["fleet.craft"] = f
  local real_space = API.space
  API.space = setmetatable({
    time = function() return 12 end,
    propagate = function(x, y, z, vx, vy, vz, mu, dt)
      return x + vx * dt, y + vy * dt, z + vz * dt, vx, vy - 1, vz
    end,
  }, { __index = real_space })
  local keep = 0
  local mu0 = BODY.mu
  BODY.mu = 5.2 * BODY.radius * BODY.radius
  API.assembly.keepLive = function() keep = keep + 1 end
  spawned = {}
  local fo3 = load_script("solar/scripts/flight_ops.lua", "flight_ops")
  fo3.start(NODE)
  T = T + 2
  fo3.update(NODE, 0.05)
  local root
  for _, sp in ipairs(spawned) do
    if sp.prefab == "Vessel" and store["dock.handoff." .. sp.node.id]
      and store["dock.handoff." .. sp.node.id].name == "Swift" then root = sp.node end
  end
  local hv = root and store["dock.handoff." .. root.id].vel
  check("a craft left in flight is rebuilt where its orbit has taken it", root
    and math.abs(root.x - (BODY.x + 60)) < 1e-6 and math.abs(root.y - (BODY.y + 900)) < 1e-6,
    root and string.format("%.1f %.1f", root.x - BODY.x, root.y - BODY.y))
  check("...and its controller is handed the velocity it has there (pushed once the parts weigh their fuel)",
    hv and math.abs(hv.x - 30) < 1e-9 and math.abs(hv.y + 1) < 1e-9 and root.impulse == nil,
    hv and string.format("%.2f %.2f", hv.x, hv.y))
  check("...with no keep-alive hold", keep == 0, keep)
  API.space = real_space
  BODY.mu = mu0
  API.assembly.keepLive = nil
  f.cfly = nil
end

-- The launch world, for the builder: published from the base's body.
BODY.mu = 5.2 * BODY.radius * BODY.radius
T = T + 2
fo2.update(NODE, 0.05)
local lw = store["launch.world"]
-- (With no pad measured yet the quote starts 3.5 m up, where a craft's centre
-- of mass sits on the deck — unless the ground ray finds nothing, as here.)
check("the launch world is published for the builder", lw and lw.name == BODY.name
  and math.abs(lw.g - BODY.mu / lw.r ^ 2) < 1e-6
  and (lw.r == BODY.radius or math.abs(lw.r - BODY.radius - 3.5) < 1.0), lw and lw.r)

-- ── 10. THE PAD NO LONGER RE-RATES ─────────────────────────────────────────
-- It used to re-solve the engines' burn rate at the pad so the starter hopped
-- exactly to a target — a hidden per-launch tweak. The catalogue is now built
-- once per save (builder.lua, BALANCE) and the blueprint flies exactly as the
-- builder quoted it; the pad only remembers its true radius, so the builder's
-- predictions are made for the ground the rocket really stands on.
do
  local RB = { name = "Pad", x = 0, y = 0, z = 0, radius = 135, mu = 5.36 * 130.7 ^ 2, soi = 1555 }
  local real_body = API.space.body
  API.space.body = function(n) if n == "Pad" then return RB end return real_body(n) end
  local bp = { parts = {
      { id = "engineS", thrust = 35, burn = 21.9, ve = 160, fuel = 0 },
      { id = "tankS", thrust = 0, burn = 0, fuel = 80, fuel_t = 0.01 } } }
  local out = fo2.rerateAtPad(bp, "Pad", 0, 133.5, 0)   -- the pad: 2.8 m further out
  check("the pad changes nothing in the blueprint", out == nil
    and bp.parts[1].thrust == 35 and bp.parts[1].burn == 21.9)
  check("...and the builder quotes this pad from now on", (store["launch.pad"] or {}).r == 133.5)
  API.space.body = real_body
end

-- ── 11. THE TRACKING STATION'S ACTIONS ─────────────────────────────────────
-- Off the scene a record still answers the comms network (its position), and
-- the station can rename it and write it off.
do
  local off = fo2.fleetOffline and fo2.fleetOffline() or {}
  local f0 = next(store["fleet.craft"] or {})
  check("a craft off the scene is offered to the comms network, with where it is",
    #off >= 0 and type(fo2.fleetOffline) == "function")
  local okr = fo2.renameFleet(f0, "  Hermes  ")
  check("RENAME trims and stores the name", okr and store["fleet.craft"][f0].name == "Hermes")
  check("...and refuses an empty one", not fo2.renameFleet(f0, "   "))
  local okt = fo2.terminateFleet(f0)
  check("END FLIGHT writes the craft off the board", okt and (store["fleet.craft"] or {})[f0] == nil)
  check("...and an unknown craft is refused", not fo2.terminateFleet("nope"))
  -- the save's depth rule: a fleet record nests at most four tables deep
  local function depth_ok(v, d)
    d = d or 0
    if type(v) ~= "table" then return true end
    if d > 3 then return false end
    for _, x in pairs(v) do if not depth_ok(x, d + 1) then return false end end
    return true
  end
  check("the fleet as saved fits save.set's four-table limit", depth_ok(store["fleet.craft"] or {}))
end

-- Checked here — before the failure list is built — and covering every card
-- shape this file rendered: in flight, down at the base, down away from it, and
-- stranded on foot.
local clean, offender = wrapped_rows_are_clean()
check("no wrapped row hand-wraps itself as well", clean, offender)

local bad = {}
for _, c in ipairs(checks) do
  if not c.ok then
    bad[#bad + 1] = "  ✗ " .. c.desc .. (c.detail and ("   [" .. tostring(c.detail) .. "]") or "")
  end
end
local nwrap = 0
for _, tree in ipairs(cards) do for _, r in ipairs(tree.items or {}) do if r.wrap then nwrap = nwrap + 1 end end end

if #bad == 0 then
  print(string.format("FLIGHT SMOKE OK — %d checks passed", #checks))
  os.exit(0)
end
print("FLIGHT SMOKE FAILURES:")
for _, b in ipairs(bad) do print(b) end
print("\n-- script logs --")
for i = math.max(1, #logs - 12), #logs do print("  " .. tostring(logs[i])) end
os.exit(1)
