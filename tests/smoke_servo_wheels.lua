-- SMOKE: a Drive Chain to a wheel a servo moves (playtest 2026-11-04: "when
-- a wheel is attached to a servo joint it just doesn't work"). Pure: the
-- auto_drive rulebook loaded from disk, nothing of the engine around it.
--
--   luajit solar/tests/smoke_servo_wheels.lua
--
-- Holds (auto_drive §6):
--   * the chain's slack: CHAIN_SLACK_K of its run, at least CHAIN_SLACK_MIN;
--   * chainShare: the whole torque within the slack either way, fading to
--     none a whole slack further out, never negative;
--   * chainRange: a hinge at a swing arm's pivot beside the gearbox sprocket
--     keeps the drive over (nearly) all its ±90°; the same arm on a hinge
--     35 cm above the pivot loses it within a few tens of degrees; a run
--     already out of its slack at 0 has no range.

local fails, passes = {}, 0
local function check(name, ok, detail)
  if ok then passes = passes + 1
  else fails[#fails + 1] = name .. (detail and ("  (" .. tostring(detail) .. ")") or "") end
end
local function near(a, b, tol) return math.abs((a or 0) - (b or 0)) <= (tol or 1e-6) end

local function load(path)
  local env = setmetatable({}, { __index = _G })
  local f = io.open("solar/" .. path) and ("solar/" .. path) or path
  local chunk = assert(loadfile(f))
  setfenv(chunk, env)
  chunk()
  return env
end
local A = load("scripts/auto_drive.lua")

-- ── the slack and the share ─────────────────────────────────────────────────
check("a short chain still takes up CHAIN_SLACK_MIN", near(A.chainSlack(0.2), A.CHAIN_SLACK_MIN))
check("a long chain takes up CHAIN_SLACK_K of its run", near(A.chainSlack(1.5), 1.5 * A.CHAIN_SLACK_K))
local L = 0.6
local s = A.chainSlack(L)
check("within the slack: the whole torque", A.chainShare(0, L) == 1 and A.chainShare(s * 0.99, L) == 1 and A.chainShare(-s * 0.99, L) == 1)
check("half a slack past it: half", near(A.chainShare(1.5 * s, L), 0.5, 1e-9) and near(A.chainShare(-1.5 * s, L), 0.5, 1e-9))
check("a whole slack past it and beyond: none, never negative", A.chainShare(2 * s, L) == 0 and A.chainShare(10, L) == 0)

-- ── a swing arm on a hinge ──────────────────────────────────────────────────
-- The engine's sprocket at the origin, the rear sprocket 0.55 m behind it;
-- the hinge's axis across the bike (Z), its centre at (hx, hy).
local function run_at(hx, hy)
  local bx, by = -0.55, 0
  return function(deg)
    local t = math.rad(deg)
    local vx, vy = bx - hx, by - hy
    local rx, ry = hx + vx * math.cos(t) - vy * math.sin(t), hy + vx * math.sin(t) + vy * math.cos(t)
    return math.sqrt(rx * rx + ry * ry)
  end
end
local lo, hi = A.chainRange(run_at(-0.04, 0.02), 0.55, -90, 90, 1)
check("a hinge beside the gearbox sprocket keeps the drive over most of ±90°", lo and lo <= -60 and hi >= 60, string.format("%s..%s", tostring(lo), tostring(hi)))
local lo2, hi2 = A.chainRange(run_at(-0.3, 0.35), 0.55, -90, 90, 1)
check("a hinge 35 cm above the pivot loses it within a few tens of degrees", lo2 and lo2 > -45 and hi2 < 45 and hi2 - lo2 >= 4,
  string.format("%s..%s", tostring(lo2), tostring(hi2)))
check("a run already out of its slack at 0 has no range", A.chainRange(function() return 0.8 end, 0.55, -90, 90, 1) == nil)

-- ── the builder's warning (builder.chainJointChecks) ────────────────────────
-- A gas bike on the stand, its rear Moto Wheel on a Servo Hinge, the chain
-- fitted by the builder (chainRefit): with the hinge beside the engine's
-- sprocket there is nothing to say; with it high above, the wheel checks say
-- how much of the hinge's travel keeps the drive — and the craft may launch.
do
  local function envOf(path)
    local e = setmetatable({}, { __index = _G })
    local c = assert(loadfile("solar/" .. path))
    setfenv(c, e); c(); e.valid = true
    return e
  end
  local Eenv, REGENV, PAenv = envOf("scripts/electronics.lua"), envOf("scripts/parts_registry.lua"), envOf("scripts/parts_auto.lua")
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
    findScript = function(k)
      if k == "electronics" then return Eenv end
      if k == "parts_registry" then return REGENV end
      if k == "parts_auto" then return PAenv end
      return nil
    end,
    findScripts = function() return {} end,
    input = { key = function() return false end, pressed = function() return false end, button = function() return false end,
              mouse = function() return 0, 0 end },
    camera = { worldToScreen = function() return 0, 0, 1, true end, screenSize = function() return 1280, 720 end,
               screenToRay = function() return 0, 10, 0, 0, -1, 0 end },
    draw = stub, audio = stub, scene = { load = function() end }, raycast = function() return nil end,
  }
  make_node("BuildStats"); make_node("BuildHint")
  local function P(t)
    local d = { yaw = 0, pitch = 0, roll = 0, parent = 0, att = "", sym = 0, stage = 0 }
    for k, v in pairs(t) do d[k] = v end
    return d
  end
  local function bike(hx, hy)
    return { parts = {
      P{ uid = 1, id = "saddle", x = 0, y = 1.2, z = 0 },
      P{ uid = 2, id = "gasE500", x = 0, y = 0.75, z = 0, parent = 1, att = "bottom" },
      P{ uid = 3, id = "gasTankM", x = 0.3, y = 1.2, z = 0, parent = 1, att = "surface" },
      P{ uid = 4, id = "hinge", x = hx, y = hy, z = 0, parent = 2, att = "surface" },
      P{ uid = 5, id = "wheelB", x = -0.85, y = 0.45, z = 0, yaw = -math.pi / 2, parent = 4, att = "surface" },
      P{ uid = 6, id = "wheelB", x = 0.9, y = 0.45, z = 0, yaw = -math.pi / 2, parent = 1, att = "surface" },
      P{ uid = 7, id = "chain", x = -0.4, y = 0.55, z = 0, parent = 2, att = "surface", size = { e = 2, w = 5, teeth = 48 } },
    } }
  end
  -- the engine on the hinge instead (on the saddle), both wheels on the frame:
  -- the engine's sprocket swings, the wheel's stays
  local function engBike(hx, hy)
    local b = bike(hx, hy)
    b.parts[4].parent, b.parts[4].att = 1, "bottom"
    b.parts[2].parent, b.parts[2].att = 4, "surface"
    b.parts[5].parent = 1
    return b
  end
  local function warnings(hx, hy, mk)
    store["shipyard.blueprint"] = (mk or bike)(hx, hy)
    local env = setmetatable({}, { __index = function(_, k) if k == "time" then return 0 end return API[k] or _G[k] end })
    local chunk = assert(loadfile("solar/scripts/builder.lua"))
    setfenv(chunk, env)
    chunk()
    env.params = {}
    for k, v in pairs(env.defaults or {}) do env.params[k] = v end
    env.start(make_node("Builder"))
    env.chainRefit()
    local out, chk = env.wheelChecks(), env.launchCheck()
    local said
    for _, w in ipairs(out) do if w:find("keeps its drive only", 1, true) then said = w end end
    return said, chk, out
  end
  -- (the test frame's parts float apart, so LAUNCH is refused for that:
  -- what matters is that the chain is never the reason)
  local function ours(chk) return chk and chk.block and (chk.block:find("Chain", 1, true) or chk.block:find("Hinge", 1, true)) end
  local near_w, near_chk, all = warnings(-0.07, 0.62)
  check("a hinge on the engine's sprocket: no chain warning", near_w == nil, near_w or table.concat(all, " | "))
  check("…and nothing blocks for it", near_chk and not ours(near_chk), near_chk and near_chk.block)
  local far_w, far_chk = warnings(-0.25, 1.10)
  check("a hinge high above the sprocket: the wheel checks say how far it keeps the drive", far_w ~= nil and far_w:find("Servo Hinge", 1, true), far_w)
  check("…a warning, never a block", far_chk and not ours(far_chk), far_chk and far_chk.block)
  if far_w then print("  (" .. far_w .. ")") end
  local eng_w, eng_chk = warnings(0, 1.0, engBike)
  check("the engine on a hinge above it: the wheel checks say how far its chain keeps the drive",
    eng_w ~= nil and eng_w:find("on its joint", 1, true) and eng_w:find("Servo Hinge", 1, true), eng_w)
  check("…a warning, never a block", eng_chk and not ours(eng_chk), eng_chk and eng_chk.block)
  if eng_w then print("  (" .. eng_w .. ")") end
end

-- ── builder symmetry: a mirror pair of robotic parts ────────────────────────
-- The builder's mirror copy is a proper rotation (mirrorBasis: X and Y
-- reflected, Z = X × Y). The same hinge angle about Z and the same piston
-- push along Y are each other's mirror image; the same rotor turn about Y is
-- not, so the copy rotor turns reversed (electronics mirrorSpin).
do
  local function rot(v, k, a)
    local c, s = math.cos(a), math.sin(a)
    local d = v[1] * k[1] + v[2] * k[2] + v[3] * k[3]
    local cx, cy, cz = k[2] * v[3] - k[3] * v[2], k[3] * v[1] - k[1] * v[3], k[1] * v[2] - k[2] * v[1]
    return { v[1] * c + cx * s + k[1] * d * (1 - c), v[2] * c + cy * s + k[2] * d * (1 - c), v[3] * c + cz * s + k[3] * d * (1 - c) }
  end
  local function refl(v) return { v[1], v[2], -v[3] } end      -- across the z = 0 plane
  local function cross(a, b) return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] } end
  local X, Y = { 1, 0, 0 }, { 0, 0.6, 0.8 }
  local Z = cross(X, Y)
  local X2, Y2 = refl(X), refl(Y)
  local Z2 = cross(X2, Y2)
  local p = { 0.6, 0.5, 0.3 }                                    -- a child, from the pivot
  local function same(a, b) return near(a[1], b[1], 1e-9) and near(a[2], b[2], 1e-9) and near(a[3], b[3], 1e-9) end
  check("a mirrored hinge's swing is the mirror image at the same angle", same(refl(rot(p, Z, 0.7)), rot(refl(p), Z2, 0.7)))
  check("a mirrored rotor's turn is the mirror image only reversed", same(refl(rot(p, Y, 0.7)), rot(refl(p), Y2, -0.7))
    and not same(refl(rot(p, Y, 0.7)), rot(refl(p), Y2, 0.7)))
  local E = load("scripts/electronics.lua")
  local RM, HM = { { type = "rotor", torque = 2 } }, { { type = "hinge", torque = 3 } }
  local flip = E.mirrorSpin({
    [3] = { uid = 3, id = "rotor", mods = RM, sym = 2, mir = "z" },
    [7] = { uid = 7, id = "rotor", mods = RM, sym = 2, mir = "z" },
    [9] = { uid = 9, id = "rotor", mods = RM, sym = 0, mir = "" },
    [5] = { uid = 5, id = "hinge", mods = HM, sym = 4, mir = "z" },
    [6] = { uid = 6, id = "hinge", mods = HM, sym = 4, mir = "z" },
  })
  check("mirrorSpin: the copy rotor of a mirror pair turns reversed, the first and lone ones don't, hinges never",
    flip[7] == -1 and flip[3] == nil and flip[9] == nil and flip[5] == nil and flip[6] == nil)
end

if #fails > 0 then
  print("SERVO WHEELS SMOKE FAILURES:")
  for _, f in ipairs(fails) do print("  ✗ " .. f) end
  print(string.format("smoke_servo_wheels: %d passed, %d FAILED", passes, #fails))
  os.exit(1)
end
print(string.format("smoke_servo_wheels: all %d checks passed", passes))
