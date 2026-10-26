-- SMOKE HARNESS: a craft's control mode (scripts/craft_mode.lua, and the
-- wheel flags vessel_controller.lua flies by).
--
-- "sometimes i may want to use landing gear as a rover wheel however whenever
-- i add one it thinks my vehicle is no longer a rover ... and if on a jet craft
-- i add a rover wheel i should be able to use that as the wheels on my plane"
-- (playtest 2026-10-26). One landing gear anywhere made the whole craft a
-- plane (R2.gear). Now the craft has a MODE, read from the whole craft or
-- chosen by the player, and the wheels follow it. This holds that:
--
--   * AUTO reads what carries the craft: the stock rover, a rover with a
--     landing gear on it and a rover on landing gear alone are rovers; the
--     27-part jet, and the jet on rover wheels, are aircraft; the starter
--     rocket is a rocket; a decorative wing doesn't make a rover a plane;
--   * the player's choice (a command part's `ctrl`) wins, the command part
--     the craft is flown from first, a part that is gone never counts;
--   * describe() says "Auto: Rover" or the chosen mode;
--   * vessel_controller: an aircraft's and a rocket's wheels never get the
--     rover's air-lean; a folded gear is no wheel (r2Stowed), and only when
--     every wheel is folded are there none (r2AllStowed); the fold signature
--     changes when a gear folds.
--
--   luajit solar/tests/smoke_craft_mode.lua

local failures, passes = {}, 0
local function check(name, ok, detail)
  if ok then passes = passes + 1
  else failures[#failures + 1] = name .. (detail and ("  (" .. detail .. ")") or "") end
end

local function load_env(path)
  local env = setmetatable({}, { __index = _G })
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  return env
end
local M = load_env("solar/scripts/craft_mode.lua")
local REG = load_env("solar/scripts/parts_registry.lua").REG
local AIR = load_env("solar/scripts/parts_aero.lua").PARTS

-- blueprint-shaped records, as builder make_blueprint writes them
local uid = 0
local function rec(id, o)
  local d = REG[id] or AIR[id]
  assert(d, "no part " .. id)
  uid = uid + 1
  local r = { uid = uid, id = id, af = d.af, wheel = d.wheel or "", mass = d.mass, fuel = d.fuel or 0,
              fuel_t = d.fuel and 0.01 or 0, kind = d.kind, seat = d.seat and 1 or 0, front = d.front and 1 or 0 }
  for k, v in pairs(o or {}) do r[k] = v end
  return r
end
local function craft(list)
  uid = 0
  local out = {}
  for _, e in ipairs(list) do
    local r = rec(e[1], e[2])
    out[r.uid] = r
  end
  return out
end
local function rep(id, n) local t = {} for i = 1, n do t[i] = { id } end return t end
local function join(...)
  local out = {}
  for _, t in ipairs({ ... }) do for _, e in ipairs(t) do out[#out + 1] = e end end
  return out
end

-- the stock rover (perfbench ROVER): a rover body, four Wheel M, a seat
local rover = craft(join({ { "roverBody" } }, rep("wheelM", 4), { { "seat" } }))
check("the stock rover is a rover", M.autoOf(rover) == "rover", M.autoOf(rover))
-- …with one landing gear added: still a rover (the playtest's complaint)
local rover_gear = craft(join({ { "roverBody" } }, rep("wheelM", 4), { { "seat" }, { "gearS" } }))
local m, why = M.autoOf(rover_gear)
check("a rover with one landing gear is still a rover", m == "rover", tostring(m) .. " / " .. tostring(why))
-- a rover on landing gear alone
local gear_rover = craft(join({ { "roverBody" } }, rep("gearM", 4)))
check("a rover on landing gear only is a rover", M.autoOf(gear_rover) == "rover", M.autoOf(gear_rover))

-- the 27-part jet (perfbench plane): cockpit, fuselage tank, Wasp, two Wing
-- Panel L, two tips, two elevons, two intakes, tail fin, three gears
local jet_list = join({ { "cockpit" }, { "fuseTank" }, { "jet" } }, rep("wingL", 2), rep("wingTip", 2),
  rep("elevon", 2), rep("intake", 2), { { "tailFin" } }, rep("gearM", 2), { { "gearS" } })
local jet = craft(jet_list)
local jm, jwhy, jf = M.autoOf(jet)
check("the jet is an aircraft", jm == "aircraft", tostring(jm) .. " / " .. tostring(jwhy))
check("the jet's lifting area reads sensibly", jf and jf.lift > 4 and jf.lift < 12, jf and string.format("%.2f m²/t", jf.lift))
-- …on rover wheels instead: still an aircraft
local jet_wheels = craft(join({ { "cockpit" }, { "fuseTank" }, { "jet" } }, rep("wingL", 2), rep("wingTip", 2),
  rep("elevon", 2), rep("intake", 2), { { "tailFin" } }, rep("wheelM", 2), { { "wheelS" } }))
check("the jet on rover wheels is an aircraft", M.autoOf(jet_wheels) == "aircraft", M.autoOf(jet_wheels))
-- mixed: two rover wheels and a nose gear
local jet_mixed = craft(join({ { "cockpit" }, { "fuseTank" }, { "jet" } }, rep("wingL", 2), rep("wingTip", 2),
  rep("elevon", 2), rep("intake", 2), { { "tailFin" } }, rep("wheelM", 2), { { "gearS" } }))
check("mixed wheel kinds don't flip the jet", M.autoOf(jet_mixed) == "aircraft", M.autoOf(jet_mixed))

-- the starter rocket (perfbench rocket_bp(2))
local rocket = craft({ { "engineS" }, { "tankS" }, { "tankS" }, { "pod" }, { "chute" } })
check("the starter rocket is a rocket", M.autoOf(rocket) == "rocket", M.autoOf(rocket))
-- a rocket with a single wheel on it: too few wheels to drive on
local rocket1 = craft({ { "engineS" }, { "tankS" }, { "pod" }, { "wheelS" } })
check("a rocket with one wheel is still a rocket", M.autoOf(rocket1) == "rocket", M.autoOf(rocket1))
-- a rover with a decorative wing: its area is far under the craft's need
local rover_wing = craft(join({ { "roverBody" } }, rep("wheelM", 4), { { "seat" }, { "wingS" } }))
check("a decorative wing doesn't make a rover a plane", M.autoOf(rover_wing) == "rover", M.autoOf(rover_wing))
-- a bike: two wheels and a seat
local bike = craft({ { "seat" }, { "wheelM" }, { "wheelM" } })
check("two wheels and a seat is a rover", M.autoOf(bike) == "rover", M.autoOf(bike))

-- ── the player's choice wins ───────────────────────────────────────────────
check("no choice anywhere: Auto", M.setOf(rover, 1) == nil)
rover[1].ctrl = "aircraft"
local mode, set, auto = M.resolve(rover, 1)
check("the command part's choice wins over Auto", mode == "aircraft" and set == "aircraft" and auto == "rover",
  string.format("%s %s %s", tostring(mode), tostring(set), tostring(auto)))
check("…and is said as chosen", M.describe(set, auto) == "Aircraft", M.describe(set, auto))
rover[1].ctrl = nil
check("Auto is said as what it reads", M.describe(nil, "rover") == "Auto: Rover", M.describe(nil, "rover"))
-- the craft is flown from the seat (uid 6): its choice, then any command part's
rover[6].ctrl = "rocket"
check("another command part's choice counts", M.setOf(rover, 1) == "rocket")
rover[1].ctrl = "rover"
check("the flying command part's choice comes first", M.setOf(rover, 1) == "rover")
check("…a gone part's never", M.setOf(rover, 1, { [1] = true }) == "rocket")
rover[1].ctrl, rover[6].ctrl = nil, nil
-- a wheel is no command part: its `ctrl` is no choice
rover[2].ctrl = "aircraft"
check("a non-command part's ctrl is ignored", M.setOf(rover, 1) == nil)
rover[2].ctrl = nil
check("junk is no mode", M.normalize("boat") == nil and M.normalize("auto") == nil and M.normalize("rover") == "rover")
check("a lost wing changes Auto's reading", M.autoOf(jet, (function()
  local g = {}
  for u, d in pairs(jet) do if d.af and d.af:find("^wing") then g[u] = true end end
  return g
end)()) == "rover")

-- ── vessel_controller: the wheel flags ─────────────────────────────────────
local stub = setmetatable({}, { __index = function() return function() end end,
                                __call = function() return nil end })
local venv = setmetatable({}, { __index = function(_, k)
  local g = _G[k]
  if g ~= nil then return g end
  return stub
end })
local chunk = assert(loadfile("solar/scripts/vessel_controller.lua"))
setfenv(chunk, venv)
local ok, err = pcall(chunk)
check("vessel_controller loads in a stub world", ok, tostring(err))
local R2 = venv.R2
venv.time = 10
R2.wheels = { { uid = 1 }, { uid = 2 }, { uid = 3, gear = true } }
R2.driving, R2.onWheels, R2.ground_t = false, false, 9.5
R2.gear, R2.passive = false, false
check("a rover just off the ground leans on the rover's keys", venv.r2AirMode({}) == true)
R2.passive = true
check("a rocket's wheels never take the rover's keys in the air", venv.r2AirMode({}) == false)
R2.passive, R2.gear = false, true
check("…nor an aircraft's", venv.r2AirMode({}) == false)
R2.gear = false
local up = {}
venv.gearIsUp = function(u) return up[u] == true end
check("a gear down is a wheel", not venv.r2Stowed(R2.wheels[3]) and not venv.r2AllStowed())
local s0 = venv.r2StowSig()
up[3] = true
check("a folded gear is no wheel", venv.r2Stowed(R2.wheels[3]))
check("a rover wheel never folds", not venv.r2Stowed(R2.wheels[1]))
check("…so a rover with its gear folded still has wheels", not venv.r2AllStowed())
check("the fold signature changes with the gear", venv.r2StowSig() ~= s0)
R2.wheels = { { uid = 3, gear = true } }
check("a plane with every gear folded has none", venv.r2AllStowed())

if #failures > 0 then
  print("smoke_craft_mode: " .. #failures .. " FAILED, " .. passes .. " passed")
  for _, f in ipairs(failures) do print("  FAIL " .. f) end
  os.exit(1)
end
print("smoke_craft_mode: all " .. passes .. " checks passed")
