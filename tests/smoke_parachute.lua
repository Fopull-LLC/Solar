-- SMOKE HARNESS: parachute.lua — the canopy a chute part opens. Drives the
-- real script against a stub engine (an animator that records every bone
-- write, a vessel_controller handle publishing chute_fill) and checks the
-- picture's geometry: the lines stay taut at their length, an open canopy is
-- the rig's rest shape, a collapsed one is a long thin bundle, the canopy
-- streams DOWN the relative airflow and swings there, it falls over and lies
-- on the ground (on the terrain under it, nothing left hovering, the lines
-- slack) when the air stops, and it flies free when its chute is cut or torn
-- away — and lies down where a loose canopy lands.
--
--   luajit solar/tests/smoke_parachute.lua

local T = 0.0
local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end

local function vec3(x, y, z) return { x = x, y = y, z = z } end

-- ── stubs ───────────────────────────────────────────────────────────────────
local bones, writes = {}, 0
-- 0.117's batch calls: a bone's number (only once the rig has posed: nil on
-- the first frame, as in the engine), many bones in one call, and a held pose.
local posed, held_pose, batches = false, false, 0
local bone_ids, bone_names = {}, {}
local animator = {
  boneIndex = function(_, name)
    if not posed then return nil end
    local i = bone_ids[name]
    if not i then
      i = #bone_names + 1
      bone_ids[name], bone_names[i] = i, name
    end
    return i
  end,
  setBones = function(_, list, pos, rot)
    batches = batches + 1
    for i, id in ipairs(list) do
      local name = assert(bone_names[id], "setBones: unknown bone number " .. tostring(id))
      local b = bones[name] or {}
      if pos then
        b.x, b.y, b.z = pos[3 * i - 2], pos[3 * i - 1], pos[3 * i]
        assert(b.z, "setBones: positions shorter than the bone list")
        writes = writes + 1
      end
      if rot then
        b.yaw, b.pitch, b.roll = rot[3 * i - 2], rot[3 * i - 1], rot[3 * i]
        assert(b.roll == b.roll, "setBones: NaN or missing rotation on " .. name)
        writes = writes + 1
      end
      bones[name] = b
    end
    assert(not pos or #pos == 3 * #list, "setBones: positions list is not 3 per bone")
    assert(not rot or #rot == 3 * #list, "setBones: rotations list is not 3 per bone")
  end,
  holdPose = function(_, on) held_pose = on end,
  setBonePos = function(_, name, v)
    writes = writes + 1
    local b = bones[name] or {}
    b.x, b.y, b.z = v.x, v.y, v.z
    bones[name] = b
  end,
  setBoneRot = function(_, name, y, p, r)
    writes = writes + 1
    assert(y == y and p == p and r == r, "NaN rotation on " .. name)
    local b = bones[name] or {}
    b.yaw, b.pitch, b.roll = y, p, r
    bones[name] = b
  end,
}
local destroyed = false
local canopy_node = {
  id = 77, x = 0, y = 0, z = 0, visible = false, valid = true,
  animator = function() return animator end,
  destroy = function() destroyed = true end,
}
-- The vessel: a hull at (0, 100, 0) on a flat world whose ground is y = 0.
local hull = {
  valid = true, x = 0, y = 100, z = 0, vx = 0, vy = -40, vz = 0,
  up = vec3(0, 1, 0), right = vec3(1, 0, 0), forward = vec3(0, 0, 1),
}
function hull:toWorld(v) return vec3(self.x + v.x, self.y + v.y, self.z + v.z) end
local chute = { x = 0, y = 3.4, z = 0, uid = 9, canopy = 77 }
local vc = {
  valid = true, node = hull, chutes = { chute },
  chute_fill = { t = 0, stretch = 0, area = 0, dens = 1, spd = 40, grounded = false },
}
local API = {
  vec3 = vec3,
  findScripts = function(kind) return kind == "vessel_controller" and { vc } or {} end,
  space = {
    dominant = function() return "Flat" end,
    body = function() return { x = 0, y = -1e6, z = 0, radius = 1e6 } end,
  },
  -- the ground: y = GROUND(x, z) (flat unless a test tilts it); rays here
  -- are cast straight down
  raycast = function(ox, oy, oz, dx, dy, dz, maxd)
    if dy >= -1e-6 then return nil end
    local g = GROUND(ox, oz)
    local d = (oy - g) / -dy
    if d < 0 or d > (maxd or 1e9) then return nil end
    return { x = ox + dx * d, y = g, z = oz + dz * d, distance = d }
  end,
}
function GROUND(x, z) return 0 end
local env = setmetatable({}, { __index = function(_, k)
  if k == "time" then return T end
  return API[k] or _G[k]
end })
local chunk = assert(loadfile("solar/scripts/parachute.lua"))
setfenv(chunk, env)
chunk()
env.params = {}
for k, v in pairs(env.defaults) do env.params[k] = v end
env.start(canopy_node)

local DT = 1 / 60
total_writes = 0
local function frame(n)
  for _ = 1, n or 1 do
    T = T + DT
    writes = 0
    -- A pose write lasts one frame and unwritten bones hold their rest, unless
    -- the pose is held and this frame wrote nothing.
    local last = bones
    bones = {}
    local ok2, err = xpcall(env.lateUpdate, debug.traceback, canopy_node, DT)
    if not ok2 then failures[#failures + 1] = "lateUpdate: " .. err; return end
    if held_pose and writes == 0 then bones = last end
    total_writes = total_writes + writes
    posed = true
  end
end
-- The rig's rest pose (tools/gen_parachute.py): what an unwritten bone holds.
local RHO = { 0.3200, 1.8712, 3.1760, 3.5453 }
local YO = { 9.7261, 9.4001, 8.5180, 7.0358 }
local REST = { Root = { 0, 0, 0 }, Riser = { 0, 1, 0 }, Apex = { 0, YO[1] + 0.05, 0 },
               Pilot = { 0, YO[1] + 0.05 + 1.7, 0 }, Lid = { 0, 0, 0 } }
for col = 0, 23 do
  for k = 1, 4 do
    local r = RHO[k] * ((col % 2 == 1) and 1.05 or 1)
    local th = col * math.pi / 12
    REST[string.format("C%d_%d", col, k - 1)] = { r * math.sin(th), YO[k], r * math.cos(th) }
  end
end
for g = 0, 11 do -- the line middles, halfway from the confluence to the skirt
  local th = g * math.pi / 6
  REST["L" .. g] = { RHO[4] * math.sin(th) * 0.5, (1 + YO[4]) * 0.5, RHO[4] * math.cos(th) * 0.5 }
end
-- A bone's world position: its local (written, or rest) turned by the node's
-- yaw/pitch/roll (YXZ) and moved to the node.
local function wpos(name)
  local b = bones[name]
  local x, y, z
  if b and b.x then x, y, z = b.x, b.y, b.z else x, y, z = REST[name][1], REST[name][2], REST[name][3] end
  local cy, sy = math.cos(canopy_node.yaw or 0), math.sin(canopy_node.yaw or 0)
  local cp, sp = math.cos(canopy_node.pitch or 0), math.sin(canopy_node.pitch or 0)
  local cr, sr = math.cos(canopy_node.roll or 0), math.sin(canopy_node.roll or 0)
  x, y = x * cr - y * sr, x * sr + y * cr          -- Rz
  y, z = y * cp - z * sp, y * sp + z * cp          -- Rx
  x, z = x * cy + z * sy, -x * sy + z * cy         -- Ry
  return x + canopy_node.x, y + canopy_node.y, z + canopy_node.z
end
local function dist(ax, ay, az, bx, by, bz)
  return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2 + (az - bz) ^ 2)
end
-- Distance of a bone from the canopy's axis (the line riser → apex).
local function off_axis(name)
  local rx, ry, rz = wpos("Riser")
  local ax, ay, az = wpos("Apex")
  local px, py, pz = wpos(name)
  local dx, dy, dz = ax - rx, ay - ry, az - rz
  local l = math.sqrt(dx * dx + dy * dy + dz * dz)
  dx, dy, dz = dx / l, dy / l, dz / l
  local vx, vy, vz = px - rx, py - ry, pz - rz
  local d = vx * dx + vy * dy + vz * dz
  return math.sqrt(math.max(0, vx * vx + vy * vy + vz * vz - d * d))
end
-- A deploy, driven the way vessel_controller drives chute_fill.
local function fill(stretch, area) vc.chute_fill.stretch, vc.chute_fill.area = stretch, area end

-- ── 1. line stretch: a thin bundle, the pilot chute leading ────────────────
fill(0.4, 0.01)
frame(2)
ok(canopy_node.visible, "the canopy shows itself once its bones are placed")
ok(writes >= 2 * 24 * 4, "an opening canopy writes every canopy bone (" .. writes .. ")")
ok(math.abs(canopy_node.y - 103.7) < 1e-6, "the node sits at the canister top (riser foot)")
local ax, ay, az = wpos("Apex")
ok(ay > canopy_node.y + 2 and ay < canopy_node.y + 6.5,
  string.format("paying out: the bagged canopy is part-way up its lines (apex %.1f m up)", ay - canopy_node.y))

-- ── 2. fully open, falling straight down: the rig's rest shape ─────────────
fill(1, 1)
frame(90)
local rx, ry, rz = wpos("Riser")
local taut = true
for g = 0, 11 do
  local sx, sy, sz = wpos(string.format("C%d_3", 2 * g))
  local l = dist(sx, sy, sz, rx, ry, rz)
  if math.abs(l - 7.0) > 0.1 then taut = false end -- (the breathing skirt pulses ±4 %)
end
ok(taut, "every suspension line is taut at its 7 m length")
ax, ay, az = wpos("Apex")
ok(ay > canopy_node.y + 9.0, string.format("falling: the canopy streams straight up the airflow (apex +%.1f m)", ay - canopy_node.y))
local skirt_r = off_axis("C0_3")
ok(math.abs(skirt_r - 3.5453) < 0.2, string.format("full: the skirt is open to the rig's rest radius (%.2f m)", skirt_r))
local open_len = ay - canopy_node.y
ok(writes <= 2 * 24 + 4, string.format("a full canopy costs only its breathing skirt (%d bone writes)", writes))

-- ── 3. collapsed: longer and thinner than open, the gores folded in ───────
fill(1, 0)
vc.chute_fill.spd = 40
frame(60)
ax, ay, az = wpos("Apex")
ok(ay - canopy_node.y > open_len + 0.5, "collapsed, the cloth lies longer than the open canopy stood")
ok(off_axis("C0_3") < 0.6, string.format("collapsed, the skirt is a narrow bundle (%.2f m)", off_axis("C0_3")))
ok(off_axis("C1_1") < off_axis("C0_1"), "collapsed, a gore's middle folds in between its seams")

-- ── 4. streaming: down the relative airflow, swinging there ───────────────
fill(1, 1)
hull.vx, hull.vy, hull.vz = 30, -30, 0 -- falling and drifting +X
local peak = 0
for _ = 1, 120 do
  frame(1)
  ax, ay, az = wpos("Apex")
  peak = math.min(peak, ax - canopy_node.x)
end
local lean = (ax - canopy_node.x) / (ay - canopy_node.y)
ok(math.abs(lean + 1) < 0.15, string.format("the canopy trails opposite the motion: up and back (-X) at 45° (%.2f)", lean))
ok(peak < ax - canopy_node.x - 0.05, "it swings past the airflow line on the way (a damped spring, not a snap)")

-- ── 5. a cluster splays: a canopy on a radial chute leans outward ─────────
hull.vx, hull.vy, hull.vz = 0, -30, 0
chute.x = 1.0
frame(120)
ax, ay, az = wpos("Apex")
ok(ax - canopy_node.x > 0.8, string.format("a chute off the centreline leans its canopy away from the others (%.2f m)", ax - canopy_node.x))
chute.x = 0

-- ── 6. landed: the air stops, it collapses and drapes to the ground ───────
hull.y = 0 -- on the ground: the canister top 3.7 m up
hull.vx, hull.vy, hull.vz = 0, 0, 0
vc.chute_fill.grounded = true
fill(1, 0)
frame(300)
ax, ay, az = wpos("Apex")
ok(ay < 0.6, string.format("draped: the canopy lies on the ground (apex %.2f m up)", ay))
ok(dist(ax, ay, az, canopy_node.x, 0, canopy_node.z) > 4, "...laid out downwind of the craft, not in a heap on it")
-- Nothing hovers: every piece of cloth (canopy, line middles, apex, pilot
-- chute) is down on the ground under it.
local function highest()
  local worst, who = -1e9, ""
  for name in pairs(REST) do
    if name ~= "Root" and name ~= "Lid" and name ~= "Riser" then
      local x, y, z = wpos(name)
      local h = y - GROUND(x, z)
      if h > worst then worst, who = h, name end
    end
  end
  return worst, who
end
local hi, hiwho = highest()
ok(hi < 0.6, string.format("draped: no part of it hovers (highest: %s, %.2f m up)", hiwho, hi))
local lowest = 1e9
for name in pairs(REST) do
  if name:sub(1, 1) == "C" then
    local x, y, z = wpos(name)
    lowest = math.min(lowest, y - GROUND(x, z))
  end
end
ok(lowest > 0, string.format("...and none of it is under the ground (lowest %.2f m)", lowest))
-- The lines are slack: the riser hangs off the canister toward the canopy,
-- the line middles lie on the ground near the craft's foot.
local rx2, ry2, rz2 = wpos("Riser")
ok(ry2 < canopy_node.y - 0.5 and ry2 > 0, string.format("the riser hangs down off the canister (%.2f m up)", ry2))
local lx, ly, lz = wpos("L0")
ok(ly < 0.2 and dist(lx, 0, lz, canopy_node.x, 0, canopy_node.z) < dist(ax, 0, az, canopy_node.x, 0, canopy_node.z),
  string.format("the slack lines lie along the ground between the craft and the canopy (L0 %.2f m up)", ly))
-- It stays where it lies, in the planet's frame, whatever the world does.
frame(120)
local ax2, ay2, az2 = wpos("Apex")
ok(dist(ax, ay, az, ax2, ay2, az2) < 0.05, "...and stays put once down")
-- Lying still costs nothing: the rig holds the pose and the script re-sends
-- none of it.
ok(held_pose and writes == 0, string.format("a canopy lying still holds its pose and writes nothing (%d)", writes))
ok(batches > 0, "the bone writes go to the engine in batches (anim:setBones)")

-- ── 6a. a slope: it lies on the terrain under it, not on a plane ─────────
vc.chute_fill.grounded = false
hull.vy = -6
frame(150) -- back in the air: it gets up again
ok(env.canopy.drape == 0, "back in moving air it stands up again")
GROUND = function(x, z) return 0.35 * x + 0.2 * z end
hull.vy = 0
vc.chute_fill.grounded = true
frame(300)
hi, hiwho = highest()
ok(hi < 0.6, string.format("on a slope: every piece lies on the ground under it (highest: %s, %.2f m up)", hiwho, hi))
lowest = 1e9
for name in pairs(REST) do
  if name:sub(1, 1) == "C" then
    local x, y, z = wpos(name)
    lowest = math.min(lowest, y - GROUND(x, z))
  end
end
ok(lowest > 0, string.format("...and none of it sinks into the slope (lowest %.2f m)", lowest))

-- ── 6b'. lying on its side: the canister near the ground ─────────────────
vc.chute_fill.grounded = false
hull.vy = -6
frame(120)
GROUND = function() return 0 end
hull.y = -3.2 -- the canister top 0.5 m off the ground
hull.vy = 0
vc.chute_fill.grounded = true
frame(300)
rx2, ry2, rz2 = wpos("Riser")
ok(ry2 > 0, string.format("a canister by the ground: the riser rests on it, not under it (%.2f m)", ry2))
hi, hiwho = highest()
ok(hi < 0.6, string.format("...and the canopy lies flat (highest: %s, %.2f m up)", hiwho, hi))
hull.y = 0
vc.chute_fill.grounded = false

-- ── 6b. far from the eye: hidden, and it writes nothing ───────────────────
local cam = { valid = true, cam_x = 0, cam_y = 5, cam_z = 400 }
API.findScript = function(kind) return kind == "planet_camera" and cam or nil end
frame(40)
ok(canopy_node.visible == false and writes == 0,
  string.format("a draped canopy 400 m from the eye is hidden and costs no writes (%d)", writes))
cam.cam_z = 30
local before_back = total_writes
frame(40)
ok(canopy_node.visible == true and total_writes > before_back and bones.Apex,
  "...and comes back when the eye does, its pose sent again")

-- ── 7. cut or torn away: it flies free, sinks, and is cleared ─────────────
hull.y = 300
hull.vx, hull.vy, hull.vz = 0, -20, 0
fill(1, 1)
frame(120)
chute.canopy = nil -- cut: the chute part stays, its canopy is let go
frame(2)
ok(env.canopy.free == true, "a canopy whose chute has gone flies free")
local y0 = canopy_node.y
frame(60)
ok(canopy_node.y < y0 and y0 - canopy_node.y < 15,
  string.format("...drifting down slowly on its own (%.1f m in 1 s)", y0 - canopy_node.y))
ok(env.canopy.crown < 0.6, "...collapsing as it goes")
frame(60 * 14)
ok(destroyed, "...and is cleared once it is well gone")

-- ── 7b. cut close to the ground: the loose canopy lands and lies down ─────
do
  local saved = { canopy_node = canopy_node, env = env }
  destroyed = false
  local node2 = {
    id = 78, x = 0, y = 0, z = 0, visible = false, valid = true,
    animator = function() return animator end,
    destroy = function() destroyed = true end,
  }
  local chute2 = { x = 0, y = 3.4, z = 0, uid = 10, canopy = 78 }
  vc.chutes = { chute2 }
  hull.x, hull.y, hull.z, hull.vx, hull.vy, hull.vz = 0, 6, 0, 0, -5, 0
  local env2 = setmetatable({}, { __index = function(_, k)
    if k == "time" then return T end
    return API[k] or _G[k]
  end })
  local chunk2 = assert(loadfile("solar/scripts/parachute.lua"))
  setfenv(chunk2, env2)
  chunk2()
  env2.params = {}
  for k, v in pairs(env2.defaults) do env2.params[k] = v end
  env2.start(node2)
  env, canopy_node = env2, node2
  fill(1, 1)
  frame(90)
  chute2.canopy = nil -- cut 9 m up
  frame(60 * 6)
  ok(env.canopy.free == true and not destroyed, "a canopy cut near the ground comes down and stays a while")
  local hi2, who2 = highest()
  ok(hi2 < 0.6, string.format("...lying on the ground where it landed (highest: %s, %.2f m up)", who2, hi2))
  canopy_node, env = saved.canopy_node, saved.env
end

-- ── cost: this stub has no engine behind the calls, so it is a floor ──────
ok(env.canopy.ms < 0.5, string.format("script cost per frame (stub engine) %.3f ms", env.canopy.ms))

if #failures > 0 then
  print("SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print(string.format("parachute smoke OK (%d checks, %.3f ms/frame script floor)", checks, env.canopy.ms))
