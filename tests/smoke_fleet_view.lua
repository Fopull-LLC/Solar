-- SMOKE: the Tracking Station's snapshot rules (scripts/fleet_view.lua), pure.
--
--   * kindOf over part lists: rocket, lander, probe, plane, rover, bike,
--     station (in orbit only), debris (no command part, or lost);
--   * attention: power under 10 % / flat, a probe out of contact (red) and a
--     crewed craft out of contact (amber), a member's O2 and HP, DOWN;
--   * situation and the key number, in words;
--   * orbitTimes: Pe/Ap/period from a state, an impact on a sub-orbital arc,
--     nil on an escape; nextEvents soonest first, carried to now;
--   * the snapshot decodes a record once per write (`t`), keeps body-relative
--     offsets only, and groups ATTENTION first.
--
--   luajit solar/tests/smoke_fleet_view.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, eps) return a and b and math.abs(a - b) <= (eps or 1e-6) end

local env = setmetatable({ time = 0 }, { __index = _G })
local chunk = assert(loadfile("solar/scripts/fleet_view.lua"))
setfenv(chunk, env)
chunk()
local FV = env

-- ── kinds ───────────────────────────────────────────────────────────────────
local function P(...) local o = {} for i, id in ipairs({ ... }) do
  local kind = (id == "pod" or id == "podMk2" or id == "cockpit") and "crewed" or ((id == "probe" or id == "roverBody") and "probe" or "structural")
  o[i] = { uid = i, id = id, kind = kind } end return o end
check(FV.kindOf(P("pod", "tankS", "engineS")) == "rocket", "pod + tank + engine: a rocket")
check(FV.kindOf(P("podMk2", "tankM", "engineM", "legs")) == "rocket", "a lander is drawn as a rocket (◆)")
check(FV.kindOf(P("probe", "battery", "antenna")) == "probe", "a probe core: a probe")
check(FV.kindOf(P("cockpit", "wingL", "wingL", "jet", "gearS")) == "plane", "cockpit and wings: a plane")
check(FV.kindOf(P("roverBody", "wheelS", "wheelS", "wheelS", "wheelS")) == "rover", "four wheels: a rover")
check(FV.kindOf(P("probe", "wheelB", "wheelB", "saddle", "forkT")) == "bike", "two moto wheels and a saddle: a bike")
check(FV.kindOf(P("podMk2", "dockPort", "pod", "tankM"), { orbit = true }) == "station", "docked command parts in orbit: a station")
check(FV.kindOf(P("podMk2", "dockPort", "pod", "tankM"), {}) == "rocket", "...the same on the ground is not")
check(FV.kindOf(P("tankS", "engineS")) == "debris", "no command part: debris")
check(FV.kindOf(P("pod", "tankS"), { lost = true }) == "debris", "a lost craft: debris")
for _, k in ipairs({ "crew", "rocket", "probe", "plane", "rover", "bike", "station", "debris", "relay", "flag", "remains", "structure", "base" }) do
  check(type(FV.GLYPHS[k]) == "string" and FV.PRIO[k] ~= nil or k == "crew" and FV.GLYPHS[k], "a glyph and a priority for " .. k)
end
check(FV.PRIO.crew > FV.PRIO.probe and FV.PRIO.probe > FV.PRIO.relay and FV.PRIO.relay > FV.PRIO.debris,
  "priority: crew > probes > relays > debris")

-- ── attention ───────────────────────────────────────────────────────────────
check(FV.attention({ craft = true, cap = 100, charge = 50, comms = true, link = true }) == nil, "a healthy craft: nothing")
local a = FV.attention({ craft = true, cap = 100, charge = 6, comms = true, link = true })
check(a and a.level == "warn" and a.text == "POWER 6 %", "power under 10 %: POWER 6 % (amber)")
a = FV.attention({ craft = true, cap = 100, charge = 0, comms = true, link = true })
check(a and a.level == "danger" and a.text == "NO POWER", "flat: NO POWER (red)")
a = FV.attention({ craft = true, cap = 0, comms = true, link = false, probe = true })
check(a and a.level == "danger" and a.text:find("NO SIGNAL"), "a probe with no path home: red")
a = FV.attention({ craft = true, cap = 0, comms = true, link = false, probe = false, crewed = true })
check(a and a.level == "warn", "a crewed craft out of contact: amber")
check(FV.attention({ craft = true, cap = 0, comms = false, link = false, crewed = true }) == nil, "no antenna at all: not an alert")
a = FV.attention({ kind = "crew", o2 = 0.18, hp = 1 })
check(a and a.level == "warn" and a.text == "O2 18 %", "a member's suit at 18 %: amber")
a = FV.attention({ kind = "crew", o2 = 0.05, hp = 1 })
check(a and a.level == "danger", "under 10 %: red")
a = FV.attention({ kind = "crew", o2 = 1, hp = 0.42 })
check(a and a.text == "HP 42 %", "HP under half")
a = FV.attention({ kind = "crew", o2 = 1, hp = 0.1, downed = 74 })
check(a and a.level == "danger" and a.text == "DOWN · 74 s", "DOWN with the seconds left")
a = FV.attention({ craft = true, cap = 100, charge = 5, comms = true, link = false, probe = true })
check(a and a.level == "danger" and #a.all == 2, "two alerts: the worst leads, both listed")

-- ── words ───────────────────────────────────────────────────────────────────
check(FV.situation({ craft = true, body = "Naolol", pe = 98000, ap = 412000 }) == "orbiting Naolol", "orbiting")
check(FV.situation({ craft = true, body = "Naolol", landed = true, homeWorld = true, dist = 4100 }) == "landed · 4.1 km from base", "landed near home")
check(FV.situation({ craft = true, body = "Iru", landed = true }) == "landed on Iru", "landed elsewhere")
check(FV.situation({ craft = true, body = "Naolol", pe = -2000, ap = 9000 }) == "sub-orbital over Naolol", "sub-orbital")
check(FV.situation({ craft = true, body = "Naolol", escaping = true }) == "escaping Naolol", "escaping")
check(FV.situation({ kind = "crew", status = "base" }) == "at the base", "a member at base")
check(FV.keyNumber({ craft = true, ap = 412000, pe = 98100 }) == "Ap 412 km · Pe 98.1 km", "the key number in orbit")
check(FV.groupOf({ craft = true, crewed = true, attn = { level = "warn" } }) == "ATTENTION", "an alert lifts it into ATTENTION")
check(FV.groupOf({ craft = true, landed = true }) == "LANDED" and FV.groupOf({ craft = true }) == "PROBES"
  and FV.groupOf({ craft = true, crewed = true }) == "CREWED", "craft groups")

-- ── the orbit's clock ───────────────────────────────────────────────────────
local mu, R = 3.986e14, 6.371e6
local r0 = R + 400e3
local v0 = math.sqrt(mu / r0) * 1.05                -- a little faster than circular: Pe here, Ap opposite
local T = FV.orbitTimes(r0, 0, 0, 0, 0, v0, mu, R)
check(T and T.period > 5000 and T.period < 7000, "period of a low orbit (" .. tostring(T and T.period) .. ")")
check(T and (T.tPe < 1.0 or T.tPe > T.period - 1.0), "at periapsis now: the next Pe is now (or a period on)")
check(T and near(T.tAp, T.period / 2, 1.0), "the apoapsis is half a period away")
check(T and (near(T.inc, 0, 1e-6) or near(T.inc, math.pi, 1e-6)), "an orbit in the X-Z plane is equatorial (Y is up)")
local Tp = FV.orbitTimes(r0, 0, 0, 0, v0, 0, mu, R)
check(Tp and near(Tp.inc, math.pi / 2, 1e-6), "a polar orbit's inclination: 90°")
local Ts = FV.orbitTimes(R + 1000, 0, 0, 0, 200, 0, mu, R)
check(Ts and Ts.tImpact and Ts.tImpact > 0 and Ts.tImpact < 120, "a hop over the ground comes down (impact in " .. tostring(Ts and Ts.tImpact) .. " s)")
check(FV.orbitTimes(r0, 0, 0, 0, 0, math.sqrt(2 * mu / r0) * 1.1, mu, R) == nil, "an escape has no clock")
check(FV.clockText(252) == "T−04:12" and FV.clockText(3780) == "T−1h 03m", "countdowns read like a clock")
local ev = FV.nextEvents({
  { craft = true, id = "a", name = "A", glyph = "◇", body = "E", rx = r0, ry = 0, rz = 0, vx = 0, vy = 0, vz = v0, st = 0 },
  { craft = true, id = "b", name = "B", glyph = "◇", body = "E", landed = true },
}, 100, { E = { mu = mu, radius = R } }, { { t = 30, id = "n", name = "Node", what = "maneuver node" } }, 4)
check(#ev == 3 and ev[1].id == "n" and ev[1].t == 30, "NEXT: the node first (soonest)")
check(ev[2].t <= ev[3].t and math.abs(ev[2].t - (T.period / 2 - 100)) < 2 and ev[2].what:find("^Ap"),
  "...then Ap and Pe, carried to now (" .. tostring(ev[2] and ev[2].t) .. ")")

-- ── the snapshot ────────────────────────────────────────────────────────────
local REC = { name = "Sat", body = "E", x = 1000, y = 0, z = 0, vx = 0, vy = 50, vz = 0, t = 7, stime = 3,
              parts = { { uid = 1, id = "probe", kind = "probe" } } }
local FO = { valid = true, fleetVersion = 1,
  fleetList = function() return { { fid = "c1", name = "Sat", body = "E", status = "in orbit", pe = 100, ap = 200, live = false,
    link = true, comms = true, probe = true, cap = 10, charge = 10 } } end,
  fleetRecords = function() return { c1 = REC } end, liveOf = function() return nil end }
env.findScript = function(k) if k == "flight_ops" then return FO end end
env.findScripts = function() return {} end
env.space = { body = function() return { x = 0, y = 0, z = 0, radius = 100 } end, time = function() return 10 end }
FV.reset()
local S = FV.snapshot(true)
check(S.byId.c1 and S.byId.c1.kind == "probe" and S.byId.c1.rx == 1000 and S.byId.c1.conic == true,
  "a record becomes an entry: body-relative, riding its conic")
check(S.byId.c1.wx == nil and S.byId.c1.x == nil, "no world point kept on an entry")
local d0 = FV.decodes
env.time = 1; FV.snapshot(true); env.time = 2; FV.snapshot(true)
check(FV.decodes == d0, "an unchanged record is never decoded again (" .. FV.decodes - d0 .. ")")
REC.t = 8
env.time = 3; FV.snapshot(true)
check(FV.decodes == d0 + 1, "...and a rewritten one is, once")
env.time = 3.05
local v1 = FV.snapshot().version
check(FV.snapshot().version == v1, "within its cadence the snapshot is the same table")
FO.fleetVersion = 2
env.time = 3.2
local calls = 0
repeat calls = calls + 1; env.time = env.time + 0.016 until FV.snapshot().version == v1 + 1 or calls > 10
check(FV.snapshot().version == v1 + 1 and calls <= 4,
  "a fleet write rebuilds it at once, the build spread over a few frames (" .. calls .. " calls)")
check(FV.snapshot(true).version == v1 + 2, "force builds it to the end in one call")

if #failures == 0 then
  print(string.format("FLEET VIEW SMOKE OK — %d checks passed", passed))
  os.exit(0)
end
print("FLEET VIEW SMOKE FAILURES:")
for _, f in ipairs(failures) do print("  ✗ " .. f) end
os.exit(1)
