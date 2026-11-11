-- SMOKE: a wall's inside face is not drawn from outside it (builderperf, 11-10;
-- scripts/kit_live.lua "a wall's inside, seen from outside it").
--
-- The real kit_live against the real parts_kit defs and structures.partPose,
-- with stub nodes (each piece a root with a "MeshIn" child whose `visible` the
-- script writes), a stub camera (camera.screenToRay answers its eye) and a
-- body that moves between frames (positions are kept body-relative).
--
--   * the camera on a wall's outer side (+Z) past the margin hides its MeshIn;
--     on its inner side, or in the margin, shows it; turned walls (yaw, a
--     quarter pitch) by their own front;
--   * a near wall flips the frame the camera crosses its plane; a far one
--     within a cycle of slices;
--   * a camera that jumps (a cut) hides nothing on that frame;
--   * a wall gone, or spawned again, is never written; floors, hab cans and
--     pieces with no MeshIn are not walls;
--   * setWallCull(false) shows every inside again.
--
--   luajit solar/tests/smoke_wall_cull.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end

local BODY = { x = 1000, y = -200, z = 50 }
local EYE = { x = 0, y = 0, z = 0 }   -- body-relative
local T = 1.0
local scripts = {}
local function env(extra)
  local E = setmetatable({
    findScript = function(k) return scripts[k] end,
    findScripts = function() return {} end,
    find = function() return nil end,
    log = function() end,
    save = { get = function() return nil end, set = function() end },
    space = { body = function(n) return n == "Home" and BODY or nil end },
    camera = { screenToRay = function() return BODY.x + EYE.x, BODY.y + EYE.y, BODY.z + EYE.z, 0, 0, 1 end },
  }, { __index = function(_, k) if k == "time" then return T end return _G[k] end })
  for k, v in pairs(extra or {}) do E[k] = v end
  return E
end
local function load_script(path, E)
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, E)
  f()
  E.params = {}
  for k, v in pairs(E.defaults or {}) do E.params[k] = v end
  return E
end

local K = load_script("parts_kit.lua", env())
scripts.parts_kit = K
scripts.parts_base = { partInfo = function(id) return K.partInfo(id) end }
local ST = load_script("structures.lua", env())
scripts.structures = ST
local KL = load_script("kit_live.lua", env())

-- a stub piece: a root, a MeshIn child (if the def is two-faced), and the writes counted
local writes = 0
local function piece(with_in)
  local mi = with_in and setmetatable({ name = "MeshIn", _vis = true }, {
    __newindex = function(t, k, v) if k == "visible" then rawset(t, "_vis", v); writes = writes + 1 else rawset(t, k, v) end end,
    __index = function(t, k) if k == "visible" then return rawget(t, "_vis") end end }) or nil
  local root = { name = "Root", valid = true, x = 0, y = 0, z = 0, worldPos = { x = 0, y = 0, z = 0 } }
  function root.getChild(_, nm) if nm == "MeshIn" then return mi end return nil end
  function root.children() return { mi } end
  return root, mi
end
-- a structure on Home at the body's origin, its frame the world's axes
local rec = { id = 7, b = "Home", x = 0, y = 0, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1, bp = {} }
local function spawn(uid, id, x, y, z, yaw, pitch)
  local part = { uid = uid, id = id, x = x, y = y, z = z, yaw = yaw or 0, pitch = pitch or 0, roll = 0 }
  local d = K.partInfo(id)
  local root, mi = piece(d and d.faces2)
  KL.spawned(rec, part, root)
  return mi, part
end
local function frame(eye)
  EYE = eye
  T = T + 1 / 60
  -- the planet moves on: nothing kept in the world
  BODY.x, BODY.y, BODY.z = BODY.x + 3.1, BODY.y - 0.7, BODY.z + 1.9
  KL.lateUpdate({}, 1 / 60)
end
local function settle(eye, n) for _ = 1, n or 12 do frame(eye) end end

-- a wall at the origin facing +Z (its outside), another turned a quarter facing +X
local w1 = spawn(1, "wall.steel", 0, 0, 0, 0)
local w2 = spawn(2, "doorWall.concrete", 4, 0, 0, math.pi / 2)
local flo = spawn(3, "floor.steel", 0, 0, 2)
local hab = spawn(4, "habSeg.steel", 0, 0, 20)
local n, hid = KL.wallStats()
check(n == 2, "two walls with an inside face are tracked (floors and hab cans are not): " .. tostring(n))

settle({ x = 0, y = 1.6, z = 5 })
check(w1.visible == false, "outside the wall (+Z, 5 m): its inside face is not drawn")
check(w2.visible == true, "...the quarter-turned wall (front +X, at x 4) from its inner side: drawn")
settle({ x = 0, y = 1.6, z = -5 })
check(w1.visible == true, "inside the wall (-Z): drawn")
settle({ x = 8, y = 1.6, z = 0 })
check(w2.visible == false, "the quarter-turned wall from its outer side (+X): not drawn")
settle({ x = 0, y = 1.6, z = 0.2 })
check(w1.visible == true, "in the margin (0.2 m out of the plane): drawn")

-- crossing a near wall's plane flips it on that very frame
settle({ x = 0.5, y = 1.6, z = 1.0 })
check(w1.visible == false, "1 m out: hidden")
frame({ x = 0.5, y = 1.6, z = -0.05 })
check(w1.visible == true, "the frame the camera crosses the plane (walking through a doorway): drawn")

-- a cut: the camera jumps 50 m to the outside; nothing hidden on that frame
settle({ x = 0, y = 1.6, z = -5 })
frame({ x = 0, y = 1.6, z = 45 })
check(w1.visible == true, "a cut: nothing is hidden on the frame the camera jumps")
settle({ x = 0, y = 1.6, z = 45 })
check(w1.visible == false, "...and it is the next frames")

-- a pitched wall (laid flat a quarter: a deck panel) goes by its own front
local wp = spawn(5, "wall.steel", 0, 3, -6, 0, math.pi / 2)
settle({ x = 0, y = 10, z = -6 })
local up_hidden = wp.visible
settle({ x = 0, y = -10, z = -6 })
check(up_hidden ~= wp.visible, "a wall laid flat: hidden from one side, drawn from the other")

-- far walls: 300 of them 40-60 m off, all decided within a cycle of slices
local far = {}
for i = 1, 300 do far[i] = spawn(100 + i, "wall.steel", (i % 20) * 2, 0, 40 + math.floor(i / 20) * 2, 0) end
settle({ x = 10, y = 1.6, z = 100 }, 12)
local shown = 0
for _, m in ipairs(far) do if m.visible then shown = shown + 1 end end
check(shown == 0, "300 far walls seen from outside: every inside hidden within a cycle (" .. shown .. " still drawn)")
settle({ x = 10, y = 1.6, z = 10 }, 12)
shown = 0
for _, m in ipairs(far) do if m.visible then shown = shown + 1 end end
check(shown == 300, "...and every one drawn again from their inner side (" .. shown .. ")")
n, hid = KL.wallStats()
check(hid >= 0 and n == 303, "the count: " .. n .. " walls, " .. hid .. " hidden")

-- a wall gone is never written again; one spawned again is tracked as its new self
local had = w1.visible
KL.gone(7, 1)
settle({ x = 0, y = 1.6, z = 5 }, 12)
settle({ x = 0, y = 1.6, z = -5 }, 12)
check(w1.visible == had, "a wall gone is not written again")
local w1b = spawn(1, "wall.steel", 0, 0, 0, 0)
settle({ x = 0, y = 1.6, z = 5 }, 12)
check(w1b.visible == false, "the same part spawned again: its new node is the one hidden")

-- the cost: a frame's work is the near cells and a slice, not every wall
local t0 = os.clock()
for _ = 1, 100 do frame({ x = 10, y = 1.6, z = 30 }) end
local per = (os.clock() - t0) * 1000 / 100
check(per < 0.5, string.format("a frame with 303 walls costs %.3f ms here (stub engine)", per))

-- a plain wall reaches kit_live through structures' wallSpawned / wallGone (it has no script)
do
  local root, mi = piece(true)
  KL.wallSpawned(rec, { uid = 900, id = "wall.concrete", x = 30, y = 0, z = 0, yaw = 0, pitch = 0, roll = 0 }, root)
  settle({ x = 30, y = 1.6, z = 6 })
  check(mi.visible == false, "a plain wall told by wallSpawned: hidden from outside")
  KL.wallGone(7, 900)
  settle({ x = 30, y = 1.6, z = -6 })
  check(mi.visible == false, "...and after wallGone it is never written again")
end

KL.setWallCull(false)
shown = 0
for _, m in ipairs(far) do if m.visible then shown = shown + 1 end end
check(shown == 300 and w1b.visible == true, "setWallCull(false): every inside drawn again")

if #failures == 0 then
  print(string.format("WALL CULL SMOKE OK — %d checks passed", passed))
  os.exit(0)
end
print("WALL CULL SMOKE FAILURES:")
for _, f in ipairs(failures) do print("  ✗ " .. f) end
os.exit(1)
