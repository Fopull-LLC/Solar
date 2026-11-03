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
--   * SECTIONS (2026-11: "a ship that deploys a rover ... a jet that drops a
--     ship?"): a craft is cut into sections at decouplers and docking ports,
--     and Auto and the choice are per section, read from the command part
--     flown: a rocket carrying a rover is a rocket, the rover away (or flown
--     from its own body) a rover; a jet carrying a rocket an aircraft, the
--     rocket away a rocket; a rover on a rocket booster a rover; a shuttle's
--     orbiter on its tank a rocket until the tank goes; a choice made on one
--     section stays there; an old craft's single choice (bp.ctrl copied on
--     every command part) stays with the main section only;
--   * vessel_controller: at launch the ROOT section's command part commands
--     (r2PickCommand): a probe ship carrying a crewed rover is a Rocket on the
--     pad, its crew passengers in the rover's seat, and the rover away is a
--     Rover commanded from that seat;
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
              fuel_t = d.fuel and 0.01 or 0, kind = d.kind, seat = d.seat and 1 or 0, front = d.front and 1 or 0,
              thrust = d.thrust or 0, decouple = d.decouple and 1 or 0, dock = d.dock and 1 or 0, label = d.label }
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

-- ── SECTIONS: crafts made of crafts ────────────────────────────────────────
-- A TREE: each entry { id, parent index (0 = root), overrides }; uids = index.
local function tree(list)
  uid = 0
  local out = {}
  for _, e in ipairs(list) do
    local r = rec(e[1], e[3])
    r.parent = e[2] or 0
    out[r.uid] = r
  end
  return out
end
-- the pieces a split leaves: the set that departs at decoupler `dec`, and the
-- rest, each re-rooted at the seam (what r2SplitCraft / undock hand over)
local function split(recs, dep)
  local a, b = {}, {}
  for u, d in pairs(recs) do
    local c = {}
    for k, v in pairs(d) do c[k] = v end
    local into = dep[u] and a or b
    if not (into == a and dep[c.parent] or into == b and not dep[c.parent]) then c.parent = 0 end
    into[u] = c
  end
  return a, b
end
local function below(recs, from)   -- from and everything hanging off it
  local set, grew = { [from] = true }, true
  while grew do
    grew = false
    for u, d in pairs(recs) do if not set[u] and set[d.parent] then set[u] = true; grew = true end end
  end
  return set
end

-- 1. A ROCKET CARRYING A ROVER: probe core on top, tanks, an engine; a
-- decoupler on the side holds a rover (body, four wheels).
local rr = tree({
  { "probe", 0 }, { "tankS", 1 }, { "tankS", 2 }, { "engineS", 3 },   -- 1-4
  { "radialDec", 2 },                                                  -- 5
  { "roverBody", 5 }, { "wheelM", 6 }, { "wheelM", 6 }, { "wheelM", 6 }, { "wheelM", 6 }, -- 6-10
})
local S = M.sections(rr)
check("the rocket and its rover are two sections", S.of[1] ~= S.of[6] and S.of[1] == S.of[4] and S.of[6] == S.of[10],
  string.format("%s %s %s %s", tostring(S.of[1]), tostring(S.of[4]), tostring(S.of[6]), tostring(S.of[10])))
local mo, st, au, wy = M.resolve(rr, 1)
check("a rocket carrying a rover flies as a rocket (from its probe core)", mo == "rocket", tostring(mo) .. " / " .. tostring(wy))
check("…though the whole stack has four wheels", M.autoOf(rr) == "rover")
mo, st, au, wy = M.resolve(rr, 6)
check("flown from the rover's own body while aboard: a rover", mo == "rover", tostring(mo) .. " / " .. tostring(wy))
local rover_away, ship_left = split(rr, below(rr, 5))
check("the rover away: a rover", M.resolve(rover_away, 6) == "rover", M.resolve(rover_away, 6))
check("the ship left: a rocket", M.resolve(ship_left, 1) == "rocket", M.resolve(ship_left, 1))
local secs = M.perSection(rr, nil, 1)
check("perSection: the ship first, then the rover",
  #secs == 2 and secs[1].cmd == 1 and secs[1].auto == "rocket" and secs[2].cmd == 6 and secs[2].auto == "rover",
  string.format("%d %s %s", #secs, secs[1] and tostring(secs[1].auto) or "-", secs[2] and tostring(secs[2].auto) or "-"))
check("short() reads Auto (Rocket)", M.short(nil, "rocket") == "Auto (Rocket)" and M.short("rover", "rocket") == "Rover")
check("notice() says the keys", M.notice("rover") == "Mode: Rover — W/S drive, A/D steer", M.notice("rover"))

-- 2. AN EXPLICIT CHOICE STAYS ON ITS SECTION. "Rocket" on the ship doesn't
-- touch the rover's body; "Aircraft" on the rover doesn't touch the ship.
local n = M.setSection(rr, 1, "rocket")
check("a choice on the ship writes the ship's command parts only", n == 1 and rr[1].ctrl == "rocket" and rr[6].ctrl == nil,
  string.format("n %d ship %s rover %s", n, tostring(rr[1].ctrl), tostring(rr[6].ctrl)))
check("…the rover still Auto (Rover)", M.resolve(rr, 6) == "rover" and select(2, M.resolve(rr, 6)) == nil)
rover_away = split(rr, below(rr, 5))
check("…and the rover away drives as a rover", M.resolve(rover_away, 6) == "rover")
M.setSection(rr, 6, "aircraft")
check("a choice on the rover stays on the rover", rr[6].ctrl == "aircraft" and rr[1].ctrl == "rocket"
  and M.resolve(rr, 1) == "rocket" and M.resolve(rr, 6) == "aircraft")
M.setSection(rr, 6, "auto")
check("Auto again clears only that section", rr[6].ctrl == nil and rr[1].ctrl == "rocket")
rr[1].ctrl = nil
-- an old craft: one choice copied onto every command part (bp.ctrl)
rr[1].ctrl, rr[6].ctrl = "rocket", "rocket"
M.legacy(rr, "rocket", 1)
check("an old craft's one choice stays with the main section only", rr[1].ctrl == "rocket" and rr[6].ctrl == nil,
  tostring(rr[6].ctrl))
rr[1].ctrl = nil

-- 3. A JET CARRYING A ROCKET under its belly on a decoupler (a probe core
-- on the rocket): the jet is an aircraft, the rocket away is a rocket.
local jr = tree(join({ { "cockpit", 0 }, { "fuseTank", 1 }, { "jet", 2 } },
  { { "wingL", 2 }, { "wingL", 2 }, { "wingTip", 4 }, { "wingTip", 5 }, { "elevon", 2 }, { "elevon", 2 },
    { "intake", 1 }, { "intake", 1 }, { "tailFin", 2 }, { "gearM", 2 }, { "gearM", 2 }, { "gearS", 1 } },
  { { "radialDec", 2 }, { "probe", 16 }, { "tankS", 17 }, { "engineS", 18 } }))   -- 16-19
mo, st, au, wy = M.resolve(jr, 1)
check("a jet carrying a rocket is an aircraft", mo == "aircraft", tostring(mo) .. " / " .. tostring(wy))
local rocket_away, jet_left = split(jr, below(jr, 16))
check("the released rocket is a rocket", M.resolve(rocket_away, 17) == "rocket", M.resolve(rocket_away, 17))
check("the jet left is an aircraft", M.resolve(jet_left, 1) == "aircraft")
-- the carried mass counts against the wings: a big rocket under a small
-- jet's wings is no aircraft (it can't lift it)
local _, _, fig = M.autoOf(jr, nil, M.sectionOf(jr, 1))
check("the jet's wings lift the rocket's mass too", fig.carried > fig.mass,
  string.format("%.2f t of %.2f", fig.mass, fig.carried))

-- 4. A ROVER WITH A ROCKET BOOSTER (a decoupler under its body, a tank and an
-- engine): a rover; the booster away is no craft at all (no command part)
local rb = tree({
  { "roverBody", 0 }, { "wheelM", 1 }, { "wheelM", 1 }, { "wheelM", 1 }, { "wheelM", 1 },
  { "decoupler", 1 }, { "tankS", 6 }, { "engineS", 7 },
})
check("a rover with a rocket booster is a rover", M.resolve(rb, 1) == "rover", select(4, M.resolve(rb, 1)))
check("…and its booster section can't be flown", #M.perSection(rb) == 1)
-- the rover with the rocket engine bolted on (no decoupler): still a rover
local rb2 = tree({ { "roverBody", 0 }, { "wheelM", 1 }, { "wheelM", 1 }, { "wheelM", 1 }, { "wheelM", 1 }, { "engineS", 1 } })
check("a rover with an engine bolted on is a rover", M.resolve(rb2, 1) == "rover")

-- 5. A SHUTTLE: a winged orbiter (cockpit, wings) on a big tank and engines
-- through a radial decoupler. On the tank its wings can't lift the stack: a
-- rocket; the tank gone, the orbiter is an aircraft.
local sh = tree(join({ { "cockpit", 0 }, { "fuseTank", 1 } },
  { { "wingL", 2 }, { "wingL", 2 }, { "elevon", 2 }, { "elevon", 2 }, { "tailFin", 2 } },
  { { "radialDec", 2 }, { "tankM", 8 }, { "tankM", 9 }, { "skipper", 10 }, { "skipper", 10 } }))
mo, st, au, wy = M.resolve(sh, 1)
check("a shuttle on its tank is a rocket", mo == "rocket", tostring(mo) .. " / " .. tostring(wy))
local _, orbiter = split(sh, below(sh, 8))
mo, st, au, wy = M.resolve(orbiter, 1)
check("…the orbiter alone an aircraft", mo == "aircraft", tostring(mo) .. " / " .. tostring(wy))

-- 6. DOCKING PORTS cut sections too: a ship and a rover mated port to port
local dk = tree({
  { "probe", 0 }, { "tankS", 1 }, { "engineS", 2 }, { "dockPort", 1 },        -- 1-4
  { "dockPort", 4 }, { "roverBody", 5 }, { "wheelM", 6 }, { "wheelM", 6 }, { "wheelM", 6 }, -- 5-9
})
check("a docked rover is its own section", M.resolve(dk, 1) == "rocket" and M.resolve(dk, 6) == "rover")
-- a separating part at the tree's root cuts every joint to its children
local rt = tree({ { "decoupler", 0 }, { "probe", 1 }, { "tankS", 2 }, { "roverBody", 1 },
  { "wheelM", 4 }, { "wheelM", 4 }, { "wheelM", 4 } })
local RS = M.sections(rt)
check("a root decoupler parts both sides", RS.of[2] ~= RS.of[4] and RS.of[1] ~= RS.of[2] and RS.of[4] == RS.of[7])
-- a gone part still holds its section together
local gs = M.sections(rr, { [2] = true })
check("a gone part still holds the stack together", gs.of[1] == gs.of[4])
-- a rover with a robotic hinge carrying an arm is one section
local hz = tree({ { "roverBody", 0 }, { "wheelM", 1 }, { "wheelM", 1 }, { "wheelM", 1 }, { "hinge", 1 }, { "probe", 5 } })
local HS = M.sections(hz)
check("a hinge is no cut", HS.of[1] == HS.of[6])
check("…both command parts fly it as a rover", M.resolve(hz, 6) == "rover" and #M.perSection(hz) == 1)

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

-- ── vessel_controller: who commands at launch (r2PickCommand) ─────────────
-- A probe-core ship carrying a CREWED rover (a seat on it): the probe core in
-- the root section commands, so it flies as a Rocket on the pad; the crew
-- ride the rover's seat as passengers. Once the rover is away, its seat
-- commands it and it drives as a Rover.
local cr = tree({
  { "probe", 0 }, { "tankS", 1 }, { "tankS", 2 }, { "engineS", 3 },   -- 1-4
  { "radialDec", 3 },                                                  -- 5
  { "roverBody", 5 }, { "wheelM", 6 }, { "wheelM", 6 }, { "wheelM", 6 }, { "wheelM", 6 }, -- 6-10
  { "seat", 6 },                                                       -- 11
})
local cmd, crew = venv.r2PickCommand(cr, cr)
check("a probe ship with a crewed rover is commanded from its probe core", cmd and cmd.uid == 1,
  cmd and tostring(cmd.uid))
check("…the crew ride the rover's seat", crew and crew.uid == 11, crew and tostring(crew.uid))
check("…so it is a Rocket on the pad", cmd and M.resolve(cr, cmd.uid) == "rocket", cmd and M.resolve(cr, cmd.uid))
local crover = split(cr, below(cr, 5))
local rcmd, rcrew = venv.r2PickCommand(crover, crover)
check("the crewed rover away is commanded from its seat", rcmd and rcmd.uid == 11 and rcrew == rcmd, rcmd and tostring(rcmd.uid))
check("…and is a Rover", rcmd and M.resolve(crover, rcmd.uid) == "rover", rcmd and M.resolve(crover, rcmd.uid))
-- a crewed pod ship with a crewed rover: the ship's pod commands and seats them
local cp = tree({ { "pod", 0 }, { "tankS", 1 }, { "engineS", 2 }, { "radialDec", 2 },
  { "roverBody", 4 }, { "wheelM", 5 }, { "wheelM", 5 }, { "wheelM", 5 }, { "seat", 5 } })
cmd, crew = venv.r2PickCommand(cp, cp)
check("a crewed ship commands from its own pod, crew in it", cmd and cmd.uid == 1 and crew == cmd)
-- a seat in the ROOT section beats the rover body there (crewed first)
local rs = tree({ { "roverBody", 0 }, { "wheelM", 1 }, { "wheelM", 1 }, { "wheelM", 1 }, { "seat", 1 } })
cmd = venv.r2PickCommand(rs, rs)
check("a crewed rover commands from its seat", cmd and cmd.uid == 5)
-- no command part in the root section: the best one anywhere
local nr = tree({ { "tankS", 0 }, { "decoupler", 1 }, { "probe", 2 } })
cmd = venv.r2PickCommand(nr, nr)
check("with none in the root section, the payload's commands", cmd and cmd.uid == 3)

if #failures > 0 then
  print("smoke_craft_mode: " .. #failures .. " FAILED, " .. passes .. " passed")
  for _, f in ipairs(failures) do print("  FAIL " .. f) end
  os.exit(1)
end
print("smoke_craft_mode: all " .. passes .. " checks passed")
