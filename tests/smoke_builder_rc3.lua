-- SMOKE (builder rc3): shaped fairings, the command seat, actuator keys and
-- wheel settings — the builder (builder.lua) and the rulebook (electronics.lua).
--
--   * axis go-to presets; actuators on keys of their own in the standard set;
--     an open seat commands with no wheel or battery;
--   * fairing profiles: what a shell holds, its skin area, 2/3 clamshell
--     pieces, an old fitted record unchanged;
--   * the builder: an unshaped fairing keeps its fitted shell; ring snapping;
--     a drawn, closed, 3-piece shape saves (profile, rings, mass, payload
--     faired), reloads, and a payload sticking out isn't shielded;
--   * the Command Seat in the catalogue and launchable; wheel roll / steer
--     plan, settings clamp, flip, apply to the pair, `wcfg` with defaults left
--     out (and `wheel` still the size), reload; actuators given keys.
--
--   luajit solar/tests/smoke_builder_rc3.lua

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

local T = 0
local nodes = {}
local function make_node(name, x, y, z)
  local n = { id = #nodes + 1, name = name, valid = true, visible = true, x = x or 0, y = y or 0, z = z or 0,
              pitch = 0, roll = 0, yaw = 0, text = "", components = {} }
  n.getcomponent = function(self, k) return self.components[k] end
  n.uiRect = function() return 0, 0, 0, 0 end
  nodes[#nodes + 1] = n
  return n
end
local store = {}
local stub = setmetatable({}, { __index = function() return function() end end })
local API = {
  vec3 = function(x, y, z) return { x = x, y = y, z = z } end,
  destroy = function(n) n.valid = false end,
  find = function(name) for _, n in ipairs(nodes) do if n.valid and n.name == name then return n end end end,
  print = function() end, log = function() end,
  spawn = function(prefab, pos, cb) local n = make_node(prefab, pos.x, pos.y, pos.z) if cb then cb(n) end end,
  save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end, flush = function() end },
  findScript = function(k) if k == "electronics" then return E end return nil end,
  findScripts = function() return {} end,
  input = { key = function() return false end, pressed = function() return false end, button = function() return false end,
            mouse = function() return 0, 0 end },
  camera = { worldToScreen = function() return 0, 0, 1, true end, screenSize = function() return 1280, 720 end,
             screenToRay = function() return 0, 10, 0, 0, -1, 0 end },
  draw = stub, audio = stub, scene = { load = function() end }, raycast = function() return nil end,
}
make_node("BuildStats"); make_node("BuildHint")
local env = setmetatable({}, { __index = function(_, k)
  if k == "time" then return T end
  return API[k] or _G[k]
end })

local function P(t)
  local d = { yaw = 0, pitch = 0, roll = 0, parent = 0, att = "", sym = 0, stage = 0 }
  for k, v in pairs(t) do d[k] = v end
  return d
end
local HP = math.pi / 2

-- ── 1. the rulebook ─────────────────────────────────────────────────────────
do
  local hinge = { uid = 1, mods = { { type = "hinge" } } }
  local mx = E.actionOf(hinge, "angle.max")
  check(mx and mx.kind == "axis" and mx.dir == 0 and mx.center == 90, "hinge offers Angle → +90° (a dir-0 go-to)")
  local st = E.stateOf(hinge)
  E.applyAction(st, mx)
  check(st.angle == 90, "…which sends the setpoint straight there")
  E.applyAction(st, E.actionOf(hinge, "angle.min"))
  check(st.angle == -90, "Angle → −90° too")
  check(E.actionOf({ uid = 2, mods = { { type = "piston" } } }, "extension.max").center == 0.8, "piston → full extension")
  check(E.actionOf(hinge, "speed.max") == nil, "a speed setting has no go-to presets")

  -- actuators get keys of their own in the standard set; a ring is one actuator
  local recs = {
    [3] = { uid = 3, mods = { { type = "piston" } }, sym = 4 },
    [4] = { uid = 4, mods = { { type = "piston" } }, sym = 4 },
    [5] = { uid = 5, mods = { { type = "hinge" } } },
    [6] = { uid = 6, mods = { { type = "drill" } } },
    [7] = { uid = 7, legs = 1 },
  }
  local g = E.defaultGroups(recs)
  check(E.isBound(g, "gear", 7, "deployed.toggle"), "legs still on Gear")
  check(E.isBound(g, "1", 3, "extended.toggle") and E.isBound(g, "1", 4, "extended.toggle") and g["1"].name == "Piston",
    "the piston ring shares key 1, named Piston")
  check(E.isBound(g, "2", 5, "angle.inc") and E.isBound(g, "3", 5, "angle.dec"), "the hinge gets two keys: + and −")
  check(E.isBound(g, "4", 6, "drilling.toggle") and E.isBound(g, "4", 6, "deployed.toggle"), "the drill lowers and runs on one key")
  local many = {}
  for u = 1, 12 do many[u] = { uid = u, mods = { { type = "rotor" } } } end
  local g2 = E.defaultGroups(many)
  local used = 0
  for _, k in ipairs(E.CUSTOM_KEYS) do if g2[k] then used = used + 1 end end
  check(used == 10 and not E.isBound(g2, "0", 11, "spin.toggle"), "ten keys at most; the rest stay unbound")

  -- the open seat commands but carries no wheel or battery
  local sm = E.deriveMods({ kind = "crewed", seat = true }, nil)
  local ty = {}
  for _, m in ipairs(sm) do ty[m.type] = true end
  check(ty.command and not ty.wheel and not ty.battery, "an open seat is a command part with no wheel or battery")

  -- fairing geometry
  local prof = E.fairingSectionsProfile(0.6, 0.1, { { r = 0.8, h = 0.3 }, { r = 0.8, h = 1.5 } }, true)
  check(prof[#prof][1] == 0 and prof[#prof][2] > 1.6, "a closed shape ends in a nose apex")
  check(E.fairingHolds(prof, 0.5, 1.5, 0.7) and not E.fairingHolds(prof, 0.5, 1.5, 0.9),
    "it holds what fits and not what is wider")
  check(not E.fairingHolds(prof, 0.5, 3.5, 0.3), "nor what is taller than the shell")
  local area = E.fairingStats(prof)
  check(area > 9 and area < 14, string.format("skin area from the profile (%.2f m²)", area))
  for _, n in ipairs({ 2, 3 }) do
    for k = 1, n do
      local m = E.fairingPiece(prof, k, n, 24)
      local nv = #m.positions / 3
      local ok = #m.normals == #m.positions and #m.uvs / 2 == nv
      for _, i in ipairs(m.indices) do if i < 1 or i > nv then ok = false end end
      check(ok, string.format("piece %d of %d: valid lists", k, n))
    end
  end
  local pi = E.fairingPieceInfo(prof, 2, 3)
  check(math.abs(pi.dx * pi.dx + pi.dz * pi.dz - 1) < 1e-9 and pi.hy > 0.5, "a piece knows where it is and which way it leaves")
  -- an old record (fitted shell only) still builds the same halves
  local old = { fr = 0.8, fy0 = 0.1, fhc = 2.0, fhn = 0.9 }
  local a, b = E.fairingMeshOf(old, 1, 24), E.fairingShell(0.8, 0.1, 2.0, 0.9, 0, 24)
  check(#a.positions == #b.positions and a.positions[10] == b.positions[10], "an old fitted record flies the same shell")
end

-- ── 2. the builder ──────────────────────────────────────────────────────────
store["shipyard.blueprint"] = { parts = {
  P{ uid = 1, id = "engineS", x = 0, y = 0.65, z = 0 },
  P{ uid = 2, id = "tankM", x = 0, y = 2.05, z = 0, parent = 1, att = "top" },
  P{ uid = 3, id = "fairingS", x = 0, y = 2.9, z = 0, parent = 2, att = "top", stage = 1 },
  P{ uid = 4, id = "probe", x = 0, y = 3.21, z = 0, parent = 3, att = "top" },
  P{ uid = 5, id = "battery", x = 0, y = 3.92, z = 0, parent = 4, att = "top" },
} }
local chunk = assert(loadfile("solar/scripts/builder.lua"))
setfenv(chunk, env)
chunk()
env.params = {}
for k, v in pairs(env.defaults or {}) do env.params[k] = v end
env.start(make_node("Builder"))
local function rec_of(bp, uid) for _, d in ipairs(bp.parts) do if d.uid == uid then return d end end end

-- an old craft: no shape, the fitted shell
env.doSave()
local f0 = rec_of(store["shipyard.blueprint"], 3)
check((f0.fr or 0) >= 0.625 and f0.fprof == nil and f0.fsec == nil, "an unshaped fairing keeps its fitted shell")
check(rec_of(store["shipyard.blueprint"], 4).faired == 3, "…and its payload rides inside")

-- snapping
local r, h, ok = env.shapeSnap({}, 0.625, 0.83, 0.31, false)
check(ok and math.abs(r - 0.85) < 1e-9 and math.abs(h - 0.3) < 1e-9, "a ring snaps to 5 cm")
r, h, ok = env.shapeSnap({ { r = 0.75, h = 0.3 } }, 0.625, 0.79, 1.2, false)
check(ok and r == 0.75, "near the last ring's radius it makes a straight wall")
r, h, ok = env.shapeSnap({ { r = 0.75, h = 0.3 } }, 0.625, 0.79, 0.2, false)
check(not ok, "a ring below the last one is refused")

-- shape it: three rings, closed, three pieces
env.fairingProbe(3, 5)
check(env.shapingUid() == nil, "closing ends shaping")
env.doSave()
local bp = store["shipyard.blueprint"]
local f = rec_of(bp, 3)
check(type(f.fprof) == "table" and #f.fprof >= 8 and f.fsplit == 3 and (f.shellm or 0) > 0.05,
  "the record carries the drawn profile, three pieces and a shell mass from its area")
check(type(f.fsec) == "table" and #f.fsec == 6 and f.fclosed == 1, "…and the rings themselves, to edit again")
check(rec_of(bp, 4).faired == 3 and rec_of(bp, 5).faired == 3, "the payload rides inside the drawn shell")
env.start(make_node("Builder"))
check(env.fshapes[3] and #env.fshapes[3].secs == 3 and env.fshapes[3].split == 3 and env.fshapes[3].closed,
  "reloaded, the shape comes back as drawn")
-- a shell too narrow: the payload sticks out and is not shielded
env.fshapes[3] = { secs = { { r = 0.3, h = 0.2 }, { r = 0.3, h = 1.6 } }, closed = true, split = 2 }
env.doSave()
check(rec_of(store["shipyard.blueprint"], 4).faired == nil, "a part sticking out of the shell isn't shielded")
-- undo puts a whole shaping session back
env.fshapes[3] = nil
env.shapeStart(3)
env.fshapes[3].secs[1] = { r = 0.7, h = 0.4 }
env.shapeStop(true)
check(env.fshapes[3] and #env.fshapes[3].secs == 1, "a one-ring shape")
API.KEYS = nil

-- ── 3. seat, actuator keys and wheels ───────────────────────────────────────
store["shipyard.blueprint"] = { parts = {
  P{ uid = 1, id = "plate", x = 0, y = 0.62, z = 0 },
  P{ uid = 2, id = "wheelM", x = 0.66, y = 0.42, z = 0.7, yaw = -HP, parent = 1, att = "surface", sym = 1, mir = "z" },
  P{ uid = 3, id = "wheelM", x = 0.66, y = 0.42, z = -0.7, yaw = HP, parent = 1, att = "surface", sym = 1, mir = "z" },
  P{ uid = 4, id = "wheelM", x = -0.66, y = 0.42, z = 0.7, yaw = -HP, parent = 1, att = "surface", sym = 2, mir = "z" },
  P{ uid = 5, id = "wheelM", x = -0.66, y = 0.42, z = -0.7, yaw = HP, parent = 1, att = "surface", sym = 2, mir = "z" },
  P{ uid = 6, id = "seat", x = 0.1, y = 1.32, z = 0, parent = 1, att = "top" },
  P{ uid = 7, id = "piston", x = -0.3, y = 0.92, z = 0, parent = 1, att = "surface" },
} }
env.start(make_node("Builder"))
local seat = env.partInfo("seat")
check(seat and seat.kind == "crewed" and seat.seat, "the catalogue has the Command Seat")
local cmd = false
for _, s in ipairs(env.catalogue()) do for _, id in ipairs(s.ids) do if id == "seat" then cmd = s.title end end end
check(cmd == "COMMAND", "…in the COMMAND section")
check(not env.launchCheck().block, "a seat alone is enough to launch")
-- wheels: the plan, settings, the record
local plan = env.wheelPlan()
local by = {}
for _, w in ipairs(plan) do by[w.uid] = w end
check(by[2].roll and by[2].roll[1] > 0.99 and by[3].roll[1] > 0.99, "both front wheels roll the craft toward its front (+X)")
check(by[2].steers and by[3].steers and not by[4].steers, "auto steer: the front pair steers, the rear doesn't")
env.wheelSet(4, "drive", "invert")
env.wheelSet(2, "steerMax", 35)
env.wheelSet(2, "spring", 9)
env.wheelSet(2, "motor", 1)
check(env.wheelCfg(2).spring == 4 and env.wheelCfg(2).steerMax == 35, "settings clamp to their ranges")
plan = env.wheelPlan()
for _, w in ipairs(plan) do by[w.uid] = w end
check(by[4].roll[1] < -0.99, "an inverted wheel pushes the other way")
env.wheelFlip(4)
check(env.wheelCfg(4).drive == "auto", "Flip direction puts it back")
env.wheelApply(2, "sym")
check(env.wheelCfg(3).steerMax == 35 and env.wheelCfg(4).steerMax == 25, "apply to the pair copies only onto the partner")
env.doSave()
local wb = store["shipyard.blueprint"]
check(rec_of(wb, 2).wcfg and rec_of(wb, 2).wcfg.steerMax == 35 and rec_of(wb, 2).wcfg.motor == nil,
  "the wheel record carries wcfg with the defaults left out")
check(rec_of(wb, 5).wcfg == nil and rec_of(wb, 2).wheel == "M", "an untouched wheel carries none; `wheel` stays the size")
check(rec_of(wb, 6).seat == 1, "the seat is marked in the record")
env.start(make_node("Builder"))
check(env.wheelCfg(2).spring == 4, "reloaded, the wheel keeps its settings")
-- actuators get keys from the panel's one click
env.groupsClear("1")
local n = env.groupsAutoActuators()
local g = env.groupsNow()
check(n >= 1 and #E.bindsOfPart(g, 7) > 0, "Give the actuators keys binds the piston")

if #failures == 0 then
  print(string.format("BUILDER RC3 SMOKE OK — %d checks passed", passed))
  os.exit(0)
end
print("BUILDER RC3 SMOKE FAILURES:")
for _, f2 in ipairs(failures) do print("  ✗ " .. f2) end
os.exit(1)
