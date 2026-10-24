-- BUILDER ORIENTATION SMOKE (2026-10-23 playtest): the pure math behind the
-- builder's bounds, surface attach, symmetry and rotation, then the real
-- builder.lua driven through a stubbed engine to check what the player sees:
--
--   * outlines are the part's OWN oriented box (they were drawn 90° off a
--     turned part: an AABB that was already rotated, then yawed again)
--   * yaw/pitch/roll ⇄ basis round-trips, so composing turns is exact
--   * a round hull is round: a fin dropped ANYWHERE on a tank stands out along
--     the radius, flush, with the same roll as every other fin (the box
--     colliders used to hand back one of four box normals)
--   * symmetry copies only while symmetry is ON now, rotated whole about the
--     host's axis; placing on a ring member with symmetry OFF places ONE part
--   * the keys and the rotate gizmo turn the way they say, a ring turns as a
--     ring, a mirror pair as a mirror, and SPACE resets
--
--   luajit solar/tests/smoke_builder_orient.lua   (from the Floptle repo root)

local T, TICK = 0.0, 1 / 60

local nodes, next_id = {}, 1
local function make_node(name, x, y, z)
  local n = { id = next_id, name = name, valid = true, visible = true, x = x or 0, y = y or 0,
              z = z or 0, pitch = 0, roll = 0, yaw = 0, text = "", components = {} }
  n.getcomponent = function(self, kind) return self.components[kind] end
  n.uiRect = function() return 0, 0, 0, 0 end
  next_id = next_id + 1
  nodes[#nodes + 1] = n
  return n
end

local API, save_store = {}, {}
function API.vec3(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
function API.destroy(n) n.valid = false end
function API.find(name)
  for _, n in ipairs(nodes) do if n.valid and n.name == name then return n end end
end
API.print = function() end
API.log = API.print
function API.spawn(prefab, pos, cb)
  local n = make_node(prefab, pos.x, pos.y, pos.z)
  if cb then cb(n) end
end
API.KEYS = { down = {}, edge = {} }
local MOUSE = { x = 5000, y = 5000, lmb = false }
API.input = {
  key = function(k) return API.KEYS.down[k] or false end,
  pressed = function(k) return API.KEYS.edge[k] or false end,
  button = function(b) return b == 0 and MOUSE.lmb or false end,
  mouse = function() return MOUSE.x, MOUSE.y end,
  mouse_delta = function() return 0, 0 end,
  scroll = function() return 0 end,
}
-- A camera straight above the pad looking down (screen x = world x, screen y
-- = world z), unless AIM holds a ray: then every cursor ray is AIM (how the
-- test points at a spot on a tank's flank without a perspective camera).
local AIM = nil
API.camera = {
  worldToScreen = function(x, y, z) return x * 100 + 500, z * 100 + 500, 20 - y, true end,
  screenSize = function() return 1920, 1080 end,
  screenToRay = function(mx, my)
    if AIM then return AIM[1], AIM[2], AIM[3], AIM[4], AIM[5], AIM[6] end
    return (mx - 500) / 100, 20.0, (my - 500) / 100, 0.0, -1.0, 0.0
  end,
}
function API.raycast() return nil end
API.draw = setmetatable({}, { __index = function() return function() end end })
API.save = { get = function(k) return save_store[k] end, set = function(k, v) save_store[k] = v end,
             flush = function() end }
API.scene = { load = function() end }
-- The part registry (scripts/parts_registry.lua) is its own pure script now,
-- reached with findScript("parts_registry"): load it from disk.
local REGENV = setmetatable({}, { __index = _G })
do
  local rc = assert(loadfile("solar/scripts/parts_registry.lua"))
  setfenv(rc, REGENV)
  rc()
end
function API.findScript(kind)
  if kind == "parts_registry" then return REGENV end
  return nil
end
function API.findScripts() return {} end
API.audio = setmetatable({}, { __index = function()
  return function() return setmetatable({}, { __index = function() return function() end end }) end
end })

local env = setmetatable({}, { __index = function(_, k)
  if k == "time" then return T end
  return API[k] or _G[k]
end })
local chunk = assert(loadfile("solar/scripts/builder.lua"))
setfenv(chunk, env)
chunk()
env.params = {}
for k, v in pairs(env.defaults or {}) do env.params[k] = v end
local builder_node = make_node("Builder", 0, 0, 0)
env.start(builder_node)

local failures, checks = {}, 0
local function check(cond, what)
  checks = checks + 1
  if not cond then failures[#failures + 1] = what end
end
local function step(n)
  for _ = 1, n or 1 do
    T = T + TICK
    local ok, err = xpcall(env.update, debug.traceback, builder_node, TICK)
    if not ok then failures[#failures + 1] = "update: " .. err end
    API.KEYS.edge = {}
  end
end
local function press(k) API.KEYS.edge[k] = true; step(1) end
local function click()
  MOUSE.lmb = true; step(1); MOUSE.lmb = false; step(14)
end
local function near(a, b, eps) return math.abs(a - b) < (eps or 1e-6) end
local function vnear(a, b, eps)
  return near(a.x, b.x, eps) and near(a.y, b.y, eps) and near(a.z, b.z, eps)
end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end

-- ── 1. pure math ─────────────────────────────────────────────────────────────
do -- euler ⇄ basis round trip, everywhere including gimbal lock
  local worst = 0
  for i = 0, 400 do
    local y, p, r = (i * 0.731) % 6.28 - 3.14, (i * 0.377) % 3.14 - 1.57, (i * 1.113) % 6.28 - 3.14
    if i % 50 == 0 then p = math.pi / 2 end
    local B = env.basisOf(y, p, r)
    local B2 = env.basisOf(env.basisEuler(B))
    for _, k in ipairs({ "X", "Y", "Z" }) do
      for _, c in ipairs({ "x", "y", "z" }) do worst = math.max(worst, math.abs(B[k][c] - B2[k][c])) end
    end
  end
  check(worst < 1e-6, string.format("yaw/pitch/roll ⇄ basis round-trips (worst %.2e)", worst))
end

do -- the OUTLINE is the part's own oriented box (the 90° bounds bug)
  -- A 2 m beam lying flat (pitch 90°) turned 35°: its long axis is local Y.
  local B = env.basisOf(math.rad(35), math.rad(90), 0)
  local c = env.obbCorners(0, 0, 0, B, 0.12, 1.0, 0.07)
  local span = { x = 0, y = 0, z = 0 }
  local function proj(v, k) return v.x * k.x + v.y * k.y + v.z * k.z end
  local lo, hi = math.huge, -math.huge
  local lox, hix = math.huge, -math.huge
  for _, p in ipairs(c) do
    lo, hi = math.min(lo, proj(p, B.Y)), math.max(hi, proj(p, B.Y))
    lox, hix = math.min(lox, proj(p, B.X)), math.max(hix, proj(p, B.X))
  end
  check(near(hi - lo, 2.0, 1e-6) and near(hix - lox, 0.24, 1e-6),
    string.format("the outline runs 2 m along the beam and 0.24 m across it (%.3f, %.3f)", hi - lo, hix - lox))
  -- The old outline: world AABB extents, then drawn yawed AGAIN. At yaw 90°
  -- that swapped the box onto the wrong axes; the oriented box can't.
  local B90 = env.basisOf(math.pi / 2, 0, 0)
  local c90 = env.obbCorners(0, 0, 0, B90, 0.45, 0.65, 0.30) -- the seat
  local mx, mz = 0, 0
  for _, p in ipairs(c90) do mx = math.max(mx, math.abs(p.x)); mz = math.max(mz, math.abs(p.z)) end
  check(near(mx, 0.30, 1e-6) and near(mz, 0.45, 1e-6),
    string.format("a seat yawed 90° outlines 0.30 wide on X and 0.45 on Z (%.2f, %.2f)", mx, mz))
end

do -- a round hull is round: ray at a tank's flank from any bearing
  local tank = { id = "tankM", def = env.partInfo("tankM"), x = 0, y = 1, z = 0, yaw = 0.3, pitch = 0, roll = 0 }
  for _, deg in ipairs({ 0, 20, 45, 75, 160, 250, 333 }) do
    local a = math.rad(deg)
    local d = { x = -math.cos(a), y = 0, z = math.sin(a) }
    local o = { x = math.cos(a) * 4, y = 1.2, z = -math.sin(a) * 4 }
    local t, P, n = env.rayPart(tank, o, d)
    local r = P and math.sqrt(P.x * P.x + P.z * P.z) or -1
    check(t and near(r, 0.5, 1e-6) and near(n.y, 0, 1e-6) and near(n.x, math.cos(a), 1e-6),
      string.format("ray at %d° meets the tank ON its round hull with a radial normal (r=%.3f)", deg, r))
  end
  -- a nose cone's flank tilts its normal up the way the cone does
  local nose = { id = "nose", def = env.partInfo("nose"), x = 0, y = 0, z = 0, yaw = 0, pitch = 0, roll = 0 }
  local _, _, nn = env.rayPart(nose, { x = 3, y = 0.1, z = 0 }, { x = -1, y = 0, z = 0 })
  check(nn and nn.y > 0.2 and nn.x > 0.5, "a nose cone's surface normal leans up the cone")
end

do -- attach frames: a fin stands +X out along the normal, +Y up the host
  local fin = env.partInfo("fins")
  local ok = true
  for deg = 0, 350, 10 do
    local a = math.rad(deg)
    local n = { x = math.cos(a), y = 0, z = -math.sin(a) }
    local A = env.attachBasis(fin, "surface", n, env.IDENT)
    if not (vnear(A.X, n, 1e-9) and near(A.Y.y, 1, 1e-9)) then ok = false end
  end
  check(ok, "every fin round a tank has +X out and the SAME roll (+Y up the tank)")
  -- on a tipped host the reference is the host's own axis, not the world's
  local hostB = env.basisOf(0.4, 1.2, 0.0)
  local n = hostB.X
  local A = env.attachBasis(fin, "surface", n, hostB)
  check(vnear(A.Y, hostB.Y, 1e-9), "a fin on a tipped tank keeps +Y along the TANK's axis")
end

-- ── 2. the builder, driven ───────────────────────────────────────────────────
step(2)
local function parts_now()
  env.doSave()
  local out = {}
  for _, d in pairs(save_store["shipyard.blueprint"].parts) do out[#out + 1] = d end
  return out
end
local function of(id)
  local out = {}
  for _, d in ipairs(parts_now()) do if d.id == id then out[#out + 1] = d end end
  return out
end
local function aim_at_tank(deg, y, tank_y)
  local a = math.rad(deg)
  AIM = { math.cos(a) * 4, tank_y + y, -math.sin(a) * 4, -math.cos(a), 0, math.sin(a) }
end

-- the tank, free on the pad at the origin
env.pick("tankM")
step(12)
MOUSE.x, MOUSE.y = 500, 500
click()
check(env.partCount == 1, "tank placed")
local tank_node = API.find("PartTankM")
local TY = tank_node.y
MOUSE.x, MOUSE.y = 5000, 5000 -- far from every node: only AIM's surface can snap

-- outward check for a fin record relative to the tank record
local function fin_ok(f, tank)
  local B = env.basisOf(f.yaw, f.pitch, f.roll)
  local ox, oz = f.x - tank.x, f.z - tank.z
  local r = math.sqrt(ox * ox + oz * oz)
  local out = { x = ox / r, y = 0, z = oz / r }
  return dot(B.X, out) > 0.9999 and B.Y.y > 0.9999 and near(r, 0.5 + 0.35, 1e-3), r
end

-- 2a. four fins at arbitrary spots, symmetry OFF: every one faces outward
for _, deg in ipairs({ 20, 75, 160, 250 }) do
  env.pick("fins")
  step(12)
  aim_at_tank(deg, (deg % 3) * 0.2 - 0.2, TY)
  step(2)
  click()
end
AIM = nil
do
  local tank = of("tankM")[1]
  local fins = of("fins")
  check(#fins == 4, "four separate fins placed (" .. #fins .. ")")
  local all = #fins == 4
  for _, f in ipairs(fins) do
    local ok, r = fin_ok(f, tank)
    if not ok then all = false end
    check(f.sym == 0, "a fin placed with symmetry off is in no ring")
  end
  check(all, "each fin dropped anywhere on the tank stands straight out of it, flush, same roll")
end
-- clear them (select + DEL each)
for _ = 1, 4 do
  local fins = of("fins")
  if #fins == 0 then break end
  env.selectPart(fins[1].uid)
  press("delete")
end
check(#of("fins") == 0, "fins cleared")

-- 2b. ×4 symmetry from an arbitrary bearing: a ring of four, 90° apart, out
press("x"); press("x"); press("x")
env.pick("fins")
step(12)
aim_at_tank(37, 0.1, TY)
step(2)
click()
AIM = nil
do
  local tank = of("tankM")[1]
  local fins = of("fins")
  check(#fins == 4, "×4 places a ring of four (" .. #fins .. ")")
  local angs, all, gid = {}, true, fins[1] and fins[1].sym
  for _, f in ipairs(fins) do
    if not fin_ok(f, tank) then all = false end
    if f.sym ~= gid or gid == 0 then all = false end
    angs[#angs + 1] = math.deg(math.atan2(-(f.z - tank.z), f.x - tank.x)) % 360
  end
  table.sort(angs)
  check(all, "every ring copy faces outward with the same roll, one group")
  local spaced = #angs == 4
  for i = 1, #angs do
    -- WP3's attach rules snap a bearing round a hull to 15° (§5.2): 37° → 30°
    local base = (env.attachRules() == "wp3") and 30 or 37
    local want = (base + (i - 1) * 90) % 360
    local got = false
    for _, a in ipairs(angs) do if near(a, want, 0.01) then got = true end end
    if not got then spaced = false end
  end
  check(spaced, "the ring sits at the snapped bearing and every 90° on (" .. table.concat(angs, ", ") .. ")")
end

-- 2c. ROTATE a ring member: every counterpart turns the same way RELATIVE TO
--     THE HULL (the ring stays a ring) — PART frame, W = pitch about local X
local function rel_frames()
  local tank = of("tankM")[1]
  local out = {}
  for _, f in ipairs(of("fins")) do
    local a = math.atan2(-(f.z - tank.z), f.x - tank.x)
    local R = env.basisRot({ x = 0, y = 1, z = 0 }, -a)
    out[#out + 1] = env.basisMul(R, env.basisOf(f.yaw, f.pitch, f.roll))
  end
  return out
end
local function frames_match(fr)
  for i = 2, #fr do
    for _, k in ipairs({ "X", "Y", "Z" }) do
      if not vnear(fr[i][k], fr[1][k], 1e-6) then return false end
    end
  end
  return #fr > 1
end
do
  local fins = of("fins")
  env.selectPart(fins[1].uid)
  press("3") -- the ROTATE gizmo
  press("l") -- LOCAL gizmo space (§4.3: L, was C)
  check(env.ROT_FRAME == "part" and env.gizmoSpace() == "local", "L switches the gizmo space to LOCAL (the part)")
  local B0 = env.basisOf(fins[1].yaw, fins[1].pitch, fins[1].roll)
  API.KEYS.down.shift = true
  press("w")
  API.KEYS.down.shift = false
  local f1
  for _, f in ipairs(of("fins")) do if f.uid == fins[1].uid then f1 = f end end
  local B1 = env.basisOf(f1.yaw, f1.pitch, f1.roll)
  -- W = −15° about the part's own X: X stays, Y tips toward −Z·sin
  check(vnear(B1.X, B0.X, 1e-6), "SHIFT+W pitches about the part's own X (X unchanged)")
  check(near(dot(B1.Y, B0.Y), math.cos(math.rad(15)), 1e-6), "…by exactly 15°")
  check(near(dot(B1.Y, B0.Z), -math.sin(math.rad(15)), 1e-6), "…in the W direction (top tips toward −Z)")
  check(frames_match(rel_frames()), "the whole ring turned the same way relative to the hull")
  press("a")
  check(frames_match(rel_frames()), "…and after a 90° yaw too")
  press("space")
  local fr = rel_frames()
  local reset = true
  for _, Bf in ipairs(fr) do
    if not (near(Bf.X.x, 1, 1e-6) and near(Bf.Y.y, 1, 1e-6)) then reset = false end
  end
  check(reset, "SPACE stands every ring fin back the way its mount holds it")
  press("l") -- back to WORLD
end

-- 2d. symmetry OFF, placing ON a ring member places ONE part
press("x"); press("x"); press("x") -- 4 → 6 → 8 → off
check(not env.symActive(), "symmetry is off after cycling past ×8")
do
  local before = #of("fins")
  local f = of("fins")[1]
  local tank = of("tankM")[1]
  env.pick("light")
  step(12)
  -- straight down onto the top edge of that fin (world coords: blueprint is
  -- centred on the craft, the nodes are not)
  local fn
  for _, n in ipairs(nodes) do
    if n.valid and n.name == "PartFins" then
      local dx, dz = n.x - tank_node.x, n.z - tank_node.z
      if near(dx, f.x - tank.x, 1e-4) and near(dz, f.z - tank.z, 1e-4) then fn = n end
    end
  end
  AIM = { fn.x, fn.y + 5, fn.z, 0, -1, 0 }
  step(2)
  click()
  AIM = nil
  check(#of("light") == 1, "with symmetry OFF a part placed on a ring member is ONE part (" .. #of("light") .. ")")
  check(#of("fins") == before, "…and the ring is untouched")
  -- 2e. …and with symmetry ON (×2 — any mode), it follows the whole ring
  env.selectPart(of("light")[1].uid)
  press("delete")
  press("x")
  env.pick("light")
  step(12)
  AIM = { fn.x, fn.y + 5, fn.z, 0, -1, 0 }
  step(2)
  click()
  AIM = nil
  check(#of("light") == 4, "with symmetry ON it copies onto every ring member (" .. #of("light") .. ")")
  press("x"); press("x"); press("x"); press("x"); press("x") -- off again
end

-- 2f. MIRROR: a pair, and rotating one turns the other as its reflection
do
  for _ = 1, 6 do
    local fs = of("fins")
    if #fs == 0 then break end
    env.selectPart(fs[1].uid)
    press("delete")
  end
  env.toggleMirror()
  env.pick("fins")
  step(12)
  aim_at_tank(30, 0, TY)
  step(2)
  click()
  AIM = nil
  local fins = of("fins")
  check(#fins == 2, "mirror places a pair (" .. #fins .. ")")
  if #fins == 2 then
    env.selectPart(fins[1].uid)
    press("3")
    API.KEYS.down.shift = true
    press("d") -- 15° about world up (CAMERA frame)
    press("w")
    API.KEYS.down.shift = false
    local a, b = of("fins")[1], of("fins")[2]
    local tank = of("tankM")[1]
    -- the mirror plane: the tank's X or Z plane — the partner's frame must be
    -- the reflection of the first's (X, Y reflected; Z = X × Y)
    local Ba, Bb = env.basisOf(a.yaw, a.pitch, a.roll), env.basisOf(b.yaw, b.pitch, b.roll)
    local function refl(v, ax) local r = { x = v.x, y = v.y, z = v.z }; r[ax] = -r[ax]; return r end
    local ax = near(a.x - tank.x, -(b.x - tank.x), 1e-4) and "x" or "z"
    check(vnear(Bb.X, refl(Ba.X, ax), 1e-6) and vnear(Bb.Y, refl(Ba.Y, ax), 1e-6),
      "the mirror partner turned as the reflection of its twin")
  end
  env.toggleMirror()
end

-- 2g. the rotate GIZMO goes the way the mouse goes, and notches 15°
do
  local fins = of("fins")
  local uid = fins[1].uid
  env.selectPart(uid)
  local fnode
  for _, n in ipairs(nodes) do
    if n.valid and n.name == "PartFins" then fnode = fnode or n end
  end
  -- find the node of the selected part by position (blueprint is centred)
  local tank = of("tankM")[1]
  for _, n in ipairs(nodes) do
    if n.valid and n.name == "PartFins" and near(n.x - tank_node.x, fins[1].x - tank.x, 1e-4)
      and near(n.z - tank_node.z, fins[1].z - tank.z, 1e-4) then fnode = n end
  end
  local p = { x = fnode.x, y = fnode.y, z = fnode.z }
  local B0 = env.basisOf(fins[1].yaw, fins[1].pitch, fins[1].roll)
  local cx, cy = API.camera.worldToScreen(p.x, p.y, p.z)
  local gd = { uid = uid, k = { x = 0, y = 1, z = 0 }, rad = 1.0 }
  -- the camera looks DOWN: the Y ring faces it. Drag the cursor from the
  -- ring's right, counter-clockwise on screen (towards screen-up) by 37°.
  local r = 120
  local mx, my = cx + r, cy
  local total = 0
  for i = 1, 37 do
    local a = -math.rad(i)
    local nx, ny = cx + math.cos(a) * r, cy + math.sin(a) * r
    total = env.gizmoTurn(p, gd, nx, ny, nx - mx, ny - my)
    mx, my = nx, ny
  end
  check(near(total, math.rad(30), 1e-9), string.format("a 37° drag notches to 30° (%.2f°)", math.deg(total)))
  local f1
  for _, f in ipairs(of("fins")) do if f.uid == uid then f1 = f end end
  local B1 = env.basisOf(f1.yaw, f1.pitch, f1.roll)
  -- counter-clockwise seen from above is +about Y: X turns toward −Z
  local want = env.basisApply(env.basisRot({ x = 0, y = 1, z = 0 }, math.rad(30)), B0.X)
  check(vnear(B1.X, want, 1e-6), "dragging counter-clockwise on screen turns it counter-clockwise (seen from above)")
  -- SHIFT: free
  API.KEYS.down.shift = true
  gd = { uid = uid, k = { x = 0, y = 1, z = 0 }, rad = 1.0 }
  mx, my = cx + r, cy
  for i = 1, 7 do
    local a = math.rad(i)
    local nx, ny = cx + math.cos(a) * r, cy + math.sin(a) * r
    total = env.gizmoTurn(p, gd, nx, ny, nx - mx, ny - my)
    mx, my = nx, ny
  end
  API.KEYS.down.shift = false
  check(near(total, -math.rad(7), 1e-9), string.format("SHIFT drags free, and clockwise is the other way (%.2f°)", math.deg(total)))
end

if #failures == 0 then
  print(string.format("BUILDER ORIENT SMOKE OK — %d checks passed", checks))
  os.exit(0)
else
  print("BUILDER ORIENT SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
