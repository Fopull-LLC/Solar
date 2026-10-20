-- SMOKE: what the Tracking Station says about a craft that is NOT in the scene
-- (a saved fleet record), and why a craft has no link.
--
-- The bug this holds: a saved record keeps each part's state as a string
-- ("charge=0"), and reading `st.charge` off a string is nil — which the board
-- took as "full". A flat probe showed 50 / 50 EC next to "no power".
--
--   * a saved probe with flat batteries reads 0 EC and NO POWER;
--   * a saved probe whose core is switched off reads PROBE CORE OFF;
--   * a saved probe in contact reads its charge and is commandable;
--   * a saved probe out of reach says how far, and one behind a world says which;
--   * a craft with no antenna, or a dead radio, says so.
--
--   luajit solar/tests/smoke_fleet_readout.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end

local Eenv = setmetatable({}, { __index = _G })
local ec = assert(loadfile("solar/scripts/electronics.lua"))
setfenv(ec, Eenv)
ec()
local E = Eenv
E.valid = true

-- ── noLinkWhy ───────────────────────────────────────────────────────────────
local world = { name = "Vever", x = 0, y = 0, z = 0, radius = 300 }
local home = { id = "home", home = true, x = 0, y = 305, z = 0, power = 4e5 }
local far = { id = "far", x = 0, y = 31000, z = 0, any = 100 }
local behind = { id = "behind", x = 0, y = -600, z = 0, any = 100 }
local silent = { id = "s", x = 0, y = 600, z = 0, any = 0, silent = "no power for its radio" }
local st = E.solveNetwork({ home, far, behind, silent }, { world })
check(not st.far.connected and st.far.why == "out of range: 31 km > 6.3 km", "out of reach says how far: " .. tostring(st.far.why))
check(st.behind.why == "blocked by Vever", "behind a world says which: " .. tostring(st.behind.why))
check(st.s.why == "no power for its radio", "a dead radio says so: " .. tostring(st.s.why))

-- ── flight_ops.fleetList on saved records ───────────────────────────────────
local function probe_rec(name, st_str, x)
  local core = E.packRecord({ uid = 1, id = "probe", kind = "probe",
    mods = { { type = "command", crew = 0, draw = 0.06 }, { type = "battery", ec = 50 },
             { type = "antenna", power = 100, rate = 1, draw = 0.02 } } })
  core.st = st_str
  return { name = name, body = "Vever", x = x or 0, y = 600, z = 0, vx = 0, vy = 0, vz = 0,
           landed = false, probe = true, pod = false, parts = { core }, charge = 0, stime = 0 }
end
local store = { ["fleet.craft"] = {
  c1 = probe_rec("Flat", "charge=0"),
  c2 = probe_rec("Sleepy", "charge=40,hibernate=t"),
  c3 = probe_rec("Talker", "charge=37.5"),
  c4 = probe_rec("Lost", "charge=50"),
} }
local NET = { valid = true, statusOf = function(id)
  if id == "f:c3" then return { connected = true, strength = 0.9, hops = 1, names = { "Ground station" } } end
  if id == "f:c4" then return { connected = false, why = "out of range: 31 km > 6.3 km" } end
  return { connected = false, why = "no power for its radio" }
end }
local env = setmetatable({
  time = 0, params = {},
  save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end, flush = function() end },
  findScript = function(k)
    if k == "electronics" then return E end
    if k == "comms" then return NET end
    return nil
  end,
  findScripts = function() return {} end,
  space = { body = function() return { name = "Vever", x = 0, y = 0, z = 0, radius = 300, mu = 7e5, soi = 3800 } end,
            elements = function() return nil end, time = function() return 0 end },
  log = function() end, print = function() end,
}, { __index = _G })
local chunk = assert(loadfile("solar/scripts/flight_ops.lua"))
setfenv(chunk, env)
chunk()
for k, v in pairs(env.defaults or {}) do env.params[k] = v end
local rows = {}
for _, e in ipairs(env.fleetList()) do rows[e.name] = e end
check(rows.Flat and rows.Flat.charge == 0 and rows.Flat.cap == 50, "a flat saved probe reads 0 / 50 EC (not full)")
check(rows.Flat.control == false and rows.Flat.why:find("NO POWER", 1, true), "...and NO POWER: " .. tostring(rows.Flat.why))
check(rows.Sleepy.why and rows.Sleepy.why:find("CORE OFF", 1, true), "a switched-off core reads PROBE CORE OFF")
check(rows.Talker.charge == 37.5 and rows.Talker.control == true and rows.Talker.link, "a saved probe in contact: its charge, commandable")
check(rows.Lost.control == false and rows.Lost.linkWhy == "out of range: 31 km > 6.3 km"
  and rows.Lost.why:find("out of range", 1, true), "out of contact says why: " .. tostring(rows.Lost.why))

if #failures == 0 then
  print(string.format("FLEET READOUT SMOKE OK — %d checks passed", passed))
  os.exit(0)
end
print("FLEET READOUT SMOKE FAILURES:")
for _, f in ipairs(failures) do print("  ✗ " .. f) end
os.exit(1)
