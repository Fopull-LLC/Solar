-- SMOKE: a part aimed at a node, a hub or a face lands EXACTLY there with the
-- grid on (playtest 2026-10-26: "its also hard to snap the parts together
-- without turning the grid off to make it precise otherwise it makes stuff
-- slightly offset weird when designing bikes"). builder_attach, pure.
--
--   luajit solar/tests/smoke_snap.lua
--
-- The grid used to run from a face's CORNER, so on a Strut Hub (0.24 m) the
-- hull grid's 25 cm left only the face's edges, and a part could not be put
-- in the middle of a hub block at all; a wheel near a fork had to be within
-- a dozen pixels of the hub to clamp in it. Each case: the GRID ON (5 cm,
-- hull 25 cm), the cursor a few centimetres off the spot, and no slop in the
-- answer (1e-9 m).

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function load(path)
  local env = setmetatable({}, { __index = _G })
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  return env
end
local A = load("solar/scripts/builder_attach.lua")
local R = load("solar/scripts/parts_registry.lua")
local PA = load("solar/scripts/parts_auto.lua")
local REG = R.REG
PA.register(REG, { { "ROVER", {} } })
local V = A.vec
local I = A.IDENT
local EX, EY, EZ = V.v(1, 0, 0), V.v(0, 1, 0), V.v(0, 0, 1)
local EPS = 1e-9

local recs = {}
local function add(uid, id, x, y, z, B)
  recs[uid] = { uid = uid, id = id, def = REG[id], x = x, y = y, z = z, B = B or I }
  return recs[uid]
end
local function get(u) return recs[u] end
local function nearAll() local t = {} for u in pairs(recs) do t[#t + 1] = u end table.sort(t) return t end
local function reset() recs = {} end
local function held(id) return { def = REG[id], id = id, off = I } end
-- a camera 4 m off, looking at the origin: the cursor is put FAR_PX from
-- every node, so only a part's own hub, or the face, can answer
local function project(x, y, z)
  local d = V.sub(V.v(x, y, z), V.v(2.5, 1.5, 3.0))
  return 640 + d.x * 300, 360 - d.y * 300, true
end
local FAR_PX = { x = 5, y = 5 }
local function q(h, hit)
  return { held = h, hit = hit, get = get, links = function() return {} end, near = nearAll(), grid = 0.05, gridHull = 0.25,
           project = project, mouse = FAR_PX }
end
local function hit(uid, x, y, z, nx, ny, nz) return { uid = uid, x = x, y = y, z = z, nx = nx, ny = ny, nz = nz } end
local function exact(a, b) return math.abs(a - b) <= EPS end
local function toWorld(r, p) return V.add(V.v(r.x, r.y, r.z), V.apply(r.B, p)) end
local function ptOf(r, t) return toWorld(r, V.v(t[1], t[2], t[3])) end

-- 1. a part on a HUB BLOCK's face, aimed 3–4 cm off its middle: centred
reset()
add(1, "hub", 0, 1, 0)
local c = A.best(q(held("packB"), hit(1, 0.12, 1.04, -0.035, 1, 0, 0)))
check(c and c.kind == "surface", "a battery aimed at a hub block's face takes the face")
check(c and exact(c.at.y, 1) and exact(c.at.z, 0), string.format("…centred on it exactly (face point %.4f %.4f; the corner grid put it on an edge)",
  c and c.at.y or -1, c and c.at.z or -1))
-- …and on its top face, the saddle stacked on a block: centred whatever the aim
local cs = A.best(q(held("saddle"), hit(1, 0.045, 1.12, 0.03, 0, 1, 0)))
check(cs and exact(cs.x, 0) and exact(cs.z, 0), string.format("a saddle on a block's top sits on its centre line (%.4f %.4f)", cs and cs.x or -1, cs and cs.z or -1))

-- 2. a big face keeps a grid, now from its centre: the middle always on it
reset()
add(1, "roverBody", 0, 0.68, 0)
local c1 = A.best(q(held("seat"), hit(1, 0.04, 0.83, 0.06, 0, 1, 0)))
check(c1 and exact(c1.at.x, 0) and exact(c1.at.z, 0), string.format("a seat aimed near a rover body's middle sits on it (%.4f %.4f)", c1 and c1.at.x or -1, c1 and c1.at.z or -1))
local c2 = A.best(q(held("seat"), hit(1, 0.31, 0.83, 0.0, 0, 1, 0)))
check(c2 and exact(c2.at.x, 0.25), string.format("…and further along, on the 25 cm hull grid from the middle (%.4f)", c2 and c2.at.x or -1))

-- 3. THE FORK on a head block's front face, aimed off: its head bracket on the face's centre
reset()
add(1, "hub", 0, 1.068, 0)
local cf = A.best(q(held("forkT"), hit(1, 0.12, 1.10, 0.04, 1, 0, 0)))
check(cf and exact(cf.at.y, 1.068) and exact(cf.at.z, 0), string.format("a fork aimed off a head block's front face mounts on its centre (%.4f %.4f)",
  cf and cf.at.y or -1, cf and cf.at.z or -1))
local fork = add(2, "forkT", cf.x, cf.y, cf.z, cf.B)

-- 4. THE WHEEL anywhere on the fork: clamped on its hub, centred, axle on the hub's
local cw = A.best(q(held("wheelB"), hit(2, cf.x + 0.1, cf.y + 0.3, cf.z + 0.2, 0, 0, 1)))
local hubW = ptOf(fork, REG.forkT.hubpt)
check(cw and cw.side == "hub", "a wheel aimed anywhere on a fork goes on its hub (got " .. tostring(cw and cw.side) .. ")")
check(cw and exact(cw.x, hubW.x) and exact(cw.y, hubW.y) and exact(cw.z, hubW.z),
  string.format("…centred on it exactly (off by %.2e m)", cw and V.len(V.sub(V.v(cw.x, cw.y, cw.z), hubW)) or -1))
check(cw and math.abs(math.abs(V.dot(cw.B.X, EZ)) - 1) < EPS, "…its axle along the fork's")

-- 5. THE SWING ARM on a rear face, its wheel in its jaws
reset()
add(1, "hub", 0, 0.48, 0)
local ca = A.best(q(held("swingArm"), hit(1, -0.12, 0.45, -0.02, -1, 0, 0)))
check(ca and exact(ca.at.y, 0.48) and exact(ca.at.z, 0), "a swing arm aimed off a rear face sits on its centre")
local arm = add(2, "swingArm", ca.x, ca.y, ca.z, ca.B)
local cw2 = A.best(q(held("wheelB"), hit(2, ca.x - 0.1, ca.y + 0.05, ca.z + 0.15, 0, 0, 1)))
local hubA = ptOf(arm, REG.swingArm.hubpt)
check(cw2 and cw2.side == "hub" and exact(cw2.x, hubA.x) and exact(cw2.y, hubA.y) and exact(cw2.z, hubA.z),
  "a wheel aimed anywhere on a swing arm is centred in its jaws")

-- 6. A STRUT on a rover body's flank, a wheel on its FLANGE (not the strut's face centre)
reset()
add(1, "roverBody", 0, 0.68, 0)
local ct = A.best(q(held("strutS"), hit(1, 0.53, 0.70, 0.5, 0, 0, 1)))
check(ct and exact(ct.at.y, 0.68), string.format("a strut aimed at a body's flank sits on its centre line (y %.4f)", ct and ct.at.y or -1))
check(ct and exact(ct.at.x, 0.5), string.format("…on the 25 cm grid from the middle along it (x %.4f)", ct and ct.at.x or -1))
local strut = add(2, "strutS", ct.x, ct.y, ct.z, ct.B)
local cw3 = A.best(q(held("wheelM"), hit(2, ct.x + 0.05, ct.y + 0.2, ct.z + 0.12, 0, 0, 1)))
local fl = ptOf(strut, REG.strutS.hubs[1].p)
check(cw3 and cw3.node and exact(cw3.at.x, fl.x) and exact(cw3.at.y, fl.y) and exact(cw3.at.z, fl.z),
  string.format("a wheel aimed anywhere on a strut bolts to its flange (off by %.2e m)", cw3 and V.len(V.sub(cw3.at, fl)) or -1))

-- 7. the grid still applies to free placement on a long member, from its end
reset()
add(1, "beam2", 0, 1.0, 0)
local cb = A.best(q(held("packB"), hit(1, 0.12, 0.47, 0, 1, 0, 0)))
check(cb and exact(cb.at.y, 0.45), string.format("on a 2 m beam the grid runs from its end, not pulled to the middle (y %.4f)", cb and cb.at.y or -1))

if #failures > 0 then
  print("SNAP SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print(string.format("smoke_snap: all %d checks passed", passed))
