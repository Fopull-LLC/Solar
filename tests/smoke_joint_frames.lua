-- SMOKE: parts a joint has moved keep their interaction points ON the part
-- (vessel_controller partPosed / posedPoint / posedDir, partFrameNow, the
-- docking port faces, the crew position), and the seated crew weigh on the
-- craft (crewMassScan, massSync, trueMass). Against stubs.
--
--   * a craft with no joints, or every joint at rest: the blueprint pose,
--     exactly as before (partPosed answers nil: no extra work);
--   * a Servo Hinge turned 90° about the craft's X: the seat and the docking
--     port beyond it are where the joint has them, the part frame's axes
--     turned with it (a point or axis kept in the part's frame rides the
--     joint), the port's face turned, the crew position (podLX) on the seat;
--   * the pose is cached until a joint moves (R2.roboGen) or the part set
--     changes;
--   * the crew aboard add CREW_T to the part they sit in, and come off it the
--     tick they step off.
--
--   luajit solar/tests/smoke_joint_frames.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, tol) return math.abs((a or 1e9) - (b or -1e9)) <= (tol or 1e-9) end
local function vec3(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end

local astro = { name = "Astronaut", valid = true, visible = true, x = 0, y = 0, z = 0, id = 99 }
-- pod 1 (the command part) | hinge 2 on its flank (axis = the craft's X) |
-- a Command Seat 3 and a Docking Port 4 beyond the hinge
local BP = { parts = {
  { uid = 1, id = "pod", kind = "crewed", x = 0, y = 1.0, z = 0, mass = 1.2 },
  { uid = 2, id = "hinge", kind = "structural", x = 0, y = 1.0, z = 0.6, parent = 1, mass = 0.05 },
  { uid = 3, id = "seat", kind = "crewed", seat = 1, x = 0, y = 1.0, z = 1.2, parent = 2, mass = 0.025 },
  { uid = 4, id = "dockPort", kind = "structural", dock = 1, x = 0, y = 1.0, z = 1.6, parent = 2, mass = 0.1 },
} }
local store = { ["shipyard.blueprint"] = BP }
local info = { origin = vec3(10, 20, 30), right = vec3(1, 0, 0), up = vec3(0, 1, 0), vel = vec3(0, 0, 0),
               angVel = vec3(0, 0, 0), com = vec3(10, 21, 30), parts = {}, mass = 1.375 }
local VE
VE = setmetatable({
  vec3 = vec3, time = 10.0,
  find = function(n) if n == "Astronaut" then return astro end end,
  findScripts = function() return {} end,
  save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
  overlapSphere = function() return {} end,
  assembly = { info = function() return info end, rebuild = function() end, syncColliders = function() end },
  log = function() end,
}, { __index = function(_, k)
  if _G[k] ~= nil then return _G[k] end
  return function() end
end })
local vc = assert(loadfile("solar/scripts/vessel_controller.lua"))
setfenv(vc, VE)
vc()
VE.params = {}
for k, v in pairs(VE.defaults) do VE.params[k] = v end
local node = { id = 5, valid = true, x = 10, y = 20, z = 30, yaw = 0, pitch = 0, roll = 0, name = "Vessel",
               children = function() return {} end }
VE.start(node)
local R2 = VE.R2

-- ── no joints: the blueprint pose, and nothing computed ────────────────────
local F = VE.partFrameNow(3)
check(F and near(F.ox, 10) and near(F.oy, 21) and near(F.oz, 31.2), "no joint: the seat's frame is its blueprint point")
check(VE.partPosed(3) == nil, "no joint: partPosed answers nil")
local px, py, pz = VE.posedPoint(3, 0.1, 0.2, 0.3)
check(px == 0.1 and py == 0.2 and pz == 0.3, "no joint: posedPoint hands the point back unchanged")

-- ── the hinge's chain, as r2_scan lays it ──────────────────────────────────
local function rest(d, X, Y, Z)
  return { x = d.x, y = d.y, z = d.z, X = X or { 1, 0, 0 }, Y = Y or { 0, 1, 0 }, Z = Z or { 0, 0, 1 } }
end
local byu = {}
for _, d in ipairs(BP.parts) do byu[d.uid] = d end
R2.rest = { [1] = rest(byu[1]), [3] = rest(byu[3]), [4] = rest(byu[4]),
            -- the hinge turns about its own Z: here the craft's X
            [2] = rest(byu[2], { 0, 1, 0 }, { 0, 0, 1 }, { 1, 0, 0 }) }
local hinge = { uid = 2, d = byu[2], kind = "hinge", cur = 0, sign = 1, set = { [3] = true, [4] = true } }
R2.robo = { hinge }
R2.chain = { [3] = { hinge }, [4] = { hinge } }
R2.gen = VE.partsGen()
R2.roboGen = 1

check(VE.partPosed(3) == nil, "a joint at rest: partPosed answers nil (the blueprint pose)")
F = VE.partFrameNow(3)
check(F and near(F.oz, 31.2) and near(F.ux, 0) and near(F.uy, 1), "a joint at rest: the frame is the blueprint's")

-- turned 90°: (0,0,0.6) off the hinge about +X → (0,-0.6,0)
hinge.cur = 90
R2.roboGen = 2
local P = VE.partPosed(3)
check(P and near(P.x, 0, 1e-9) and near(P.y, 0.4, 1e-9) and near(P.z, 0.6, 1e-9),
  string.format("90°: the seat where the hinge has it (%.3f, %.3f, %.3f)", P and P.x or -1, P and P.y or -1, P and P.z or -1))
check(VE.partPosed(3) == P, "the pose is cached until a joint moves")
F = VE.partFrameNow(3)
check(F and near(F.ox, 10, 1e-9) and near(F.oy, 20.4, 1e-9) and near(F.oz, 30.6, 1e-9), "partFrameNow: the seat's origin as posed")
-- the craft's up turned 90° about X is +Z; its right stays +X
check(F and near(F.ux, 0, 1e-9) and near(F.uy, 0, 1e-9) and near(F.uz, 1, 1e-9), "partFrameNow: the part's up turned with it")
check(F and near(F.rx, 1, 1e-9) and near(F.ry, 0, 1e-9), "partFrameNow: the axis of the hinge is unchanged")
local wx, wy, wz = VE.partPointNow(3, 0, 0.5, 0)
check(near(wx, 10, 1e-9) and near(wy, 20.4, 1e-9) and near(wz, 31.1, 1e-9), "partPointNow: a point in the part's frame rides the joint")
local lx, ly, lz = VE.partLocalNow(3, wx, wy, wz)
check(near(lx, 0, 1e-9) and near(ly, 0.5, 1e-9) and near(lz, 0, 1e-9), "partLocalNow inverts it")
-- the pod (no joint moves it) is untouched
F = VE.partFrameNow(1)
check(F and near(F.oy, 21) and near(F.uy, 1), "the command part is not moved by a joint beyond it")
local dx, dy, dz = VE.posedDir(4, 0, 1, 0)
check(near(dx, 0, 1e-9) and near(dy, 0, 1e-9) and near(dz, 1, 1e-9), "posedDir: an axis on the port turned with it")

-- ── the docking port's face (dock_world through dockFaces) ─────────────────
VE.dockRescan()
local faces = VE.dockFaces()
local f4
for _, f in ipairs(faces) do if f.uid == 4 then f4 = f end end
check(f4 ~= nil, "the port beyond the hinge is a free face")
if f4 then
  check(near(f4.x, 10, 1e-9) and near(f4.y, 20.0, 1e-9) and near(f4.z, 30.6, 1e-9),
    string.format("the port's face where the hinge has it (%.3f, %.3f, %.3f)", f4.x, f4.y, f4.z))
  check(near(f4.ay, 0, 1e-9) and math.abs(f4.az) > 0.999, string.format("its face turned with it (%.2f, %.2f, %.2f)", f4.ax, f4.ay, f4.az))
end

-- ── the crew position on the seat ──────────────────────────────────────────
check(VE.setStation(3) == true, "the crew can take the seat")
check(near(VE.podLX, 0, 1e-9) and near(VE.podLY, 0.4, 1e-9) and near(VE.podLZ, 0.6, 1e-9),
  string.format("podL is the seat as posed (%.3f, %.3f, %.3f): command_seat finds its rider", VE.podLX, VE.podLY, VE.podLZ))
-- the joint moves back: roboFlight republishes it
hinge.cur = 0
VE.roboFlight()
check(near(VE.podLY, 1.0, 1e-9) and near(VE.podLZ, 1.2, 1e-9), "the joint back at rest: podL back on the blueprint point")
check(VE.partPosed(3) == nil, "...and partPosed nil again")
-- a stale chain (the part set changed, no rescan yet) is never used
hinge.cur = 45
R2.roboGen = 9
R2.gen = -1
check(VE.partPosed(3) == nil, "a chain from before the part set changed is not used")
R2.gen = VE.partsGen()
check(VE.partPosed(3) ~= nil, "...and is again once it is rescanned")

-- ── the crew's weight ──────────────────────────────────────────────────────
VE.crewAboard = false
VE.crewMassScan(node, info)
check(VE.CREW_TT == 0 and next(VE.CREW_TU) == nil, "nobody aboard: no crew mass")
local dry0 = VE.trueMass()
VE.crewAboard = true
VE.time = VE.time + 1
check(VE.crewMassScan(node, info) == true, "boarding is read at once")
check(near(VE.CREW_TU[3], VE.CREW_T) and near(VE.CREW_TT, VE.CREW_T), string.format("aboard: CREW_T on the seat they sit in (%s)", tostring(VE.CREW_TU[3])))
check(near(VE.CREW_T, 0.1), "CREW_T is the suit and its wearer, 100 kg")
check(near(VE.trueMass() - dry0, VE.CREW_T), "trueMass carries the crew")
check(R2.holdoff >= 0.1 - 1e-9, "tyres still in wait for the re-weigh before they come out")
check(VE.crewMassScan(node, info) == false, "nothing changed: nothing written")
-- …onto the seat part's body (massSync), so the compound re-weighs with them
local kids, rbs = {}, {}
for _, d in ipairs(BP.parts) do
  local rb = { mass = d.mass }
  rbs[d.uid] = rb
  kids[#kids + 1] = { id = 100 + d.uid, name = "Part" .. d.id, valid = true, x = d.x, y = d.y, z = d.z,
                      getcomponent = function(_, k) if k == "RigidBody" then return rb end end }
end
node.children = function() return kids end
VE.time = VE.time + 20
VE.massSync(node, info)
check(near(rbs[3].mass, 0.025 + VE.CREW_T, 1e-9) and near(rbs[1].mass, 1.2, 1e-9),
  string.format("massSync: the seat's body carries its rider (%.3f t), the pod its own mass (%.3f t)", rbs[3].mass, rbs[1].mass))
-- …and in the plan's centre of mass (a bike's ends and wheelie limit): two
-- wheels either side of the craft, the rider on the seat at +Z
local function plan_com()
  local ws = { { uid = 91, cx = 0, cy = 0.3, cz = -2, r = 0.3, d = {} }, { uid = 92, cx = 0, cy = 0.3, cz = 2, r = 0.3, d = {} } }
  local bpu = {}
  for _, d in ipairs(BP.parts) do bpu[d.uid] = d end
  VE.r2SteerPlan(ws, { x = 0, z = 1 }, bpu, {})
  return ws[1].a, VE.R2.plan.hcg
end
local a1, h1 = plan_com()
VE.crewAboard = false
check(VE.crewMassScan(node, info) == true and VE.CREW_TT == 0, "stepping off takes the mass off at once")
local a0, h0 = plan_com()
local m0, z0 = 0, 0
for _, d in ipairs(BP.parts) do m0, z0 = m0 + d.mass, z0 + d.mass * d.z end
local zc0, zc1 = z0 / m0, (z0 + VE.CREW_T * 1.2) / (m0 + VE.CREW_T)
check(near(a0, -2 - zc0, 1e-9) and near(a1, -2 - zc1, 1e-9),
  string.format("the plan's centre of mass carries the rider: wheel lever %.3f -> %.3f m (want %.3f -> %.3f)", a0, a1, -2 - zc0, -2 - zc1))
check(near(h1, h0, 1e-9), "…its height the same (rider and parts all at 1.0 m here)")
VE.massSync(node, info)
check(near(rbs[3].mass, 0.025, 1e-9), string.format("massSync: the seat's body back to its own mass (%.3f t)", rbs[3].mass))

if #failures > 0 then
  print("SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print(string.format("SMOKE OK — %d checks", passed))
