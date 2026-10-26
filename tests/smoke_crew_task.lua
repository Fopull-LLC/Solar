-- SMOKE: the held repair lock (scripts/crew_task.lua with scripts/crew.lua;
-- docs/crew-and-items.md §6.2, §6.3), against a stub craft that spins.
--
--   * starting: out of reach, too fast relative to the part, from the seat,
--     or with the engines on is refused with the reason;
--   * held: the body is kinematic and written at the work spot (in the part's
--     frame, converted this tick) every tick, sliding in first; the craft
--     tumbles and the body follows it exactly;
--   * movement input never cancels: the lock reads no input at all;
--   * only cancelTask and the forced stops end it: the part broken, the craft
--     gone, engines firing, out of air — each with its reason;
--   * a cancel between ticks lands on the next tick, the body let go at the
--     part's point velocity; the progress is kept on the part and a new start
--     resumes from it;
--   * finishing mends the part, uses the kit, clears the kept progress.
--
--   luajit solar/tests/smoke_crew_task.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end

-- ── the world ──────────────────────────────────────────────────────────────
local store = { g_seed = 3 }
local logs = {}
local rb = { kinematic = 0 }
local astro = { id = 99, valid = true, x = 0, y = 0, z = 0, vx = 0, vy = 0, vz = 0,
                getComponent = function(_, k) return k == "RigidBody" and rb or nil end }

-- A craft spinning about +Y at w rad/s round the origin, moving at V.
local craft = { t = 0, w = 0.1, V = { 5, 0, 0 }, hp = { [5] = 0.4 }, st = { [5] = {} }, throttle = 0, lost = false,
                repaired = nil }
local function frame()
  local a = craft.w * craft.t
  local c, s = math.cos(a), math.sin(a)
  -- axes: right (c,0,-s), up (0,1,0), z (s,0,c); the part's origin at (2,0,0) in the craft
  local ox, oy, oz = craft.V[1] * craft.t, 0, 0
  return { ox = ox + 2 * c, oy = oy, oz = oz - 2 * s, rx = c, ry = 0, rz = -s, ux = 0, uy = 1, uz = 0, zx = s, zy = 0, zz = c,
           cx = ox, cy = oy, cz = oz, vx = craft.V[1], vy = 0, vz = 0, wx = 0, wy = craft.w, wz = 0 }
end
local vc = {
  valid = true, node = { id = 7, valid = true }, craftName = "Station", throttle = 0, crewAboard = false,
  partHp = function(u) return craft.hp[u] end,
  isLost = function() return craft.lost end,
  partRec = function(u) return { id = "pod", label = "Pod" } end,
  nodeLag = function() return 0, 0, 0 end,
  evaState = function() return { surface = false, space = true, speed = 0, throttle = craft.throttle } end,
  partSt = function(u, k, v, w)
    if w then if v == false then craft.st[u][k] = nil else craft.st[u][k] = v end end
    return craft.st[u][k]
  end,
  repairPart = function(u, to) craft.hp[u] = to; craft.repaired = u; return to end,
}
function vc.partFrameNow(u) if not craft.hp[u] or craft.hp[u] <= 0 then return nil end return frame() end
function vc.partPointNow(u, lx, ly, lz)
  local F = vc.partFrameNow(u)
  if not F then return nil end
  local px = F.ox + F.rx * lx + F.ux * ly + F.zx * lz
  local py = F.oy + F.ry * lx + F.uy * ly + F.zy * lz
  local pz = F.oz + F.rz * lx + F.uz * ly + F.zz * lz
  local qx, qy, qz = px - F.cx, py - F.cy, pz - F.cz
  return px, py, pz, F.vx + F.wy * qz - F.wz * qy, F.vy + F.wz * qx - F.wx * qz, F.vz + F.wx * qy - F.wy * qx
end
function vc.partLocalNow(u, wx, wy, wz)
  local F = vc.partFrameNow(u)
  if not F then return nil end
  local qx, qy, qz = wx - F.ox, wy - F.oy, wz - F.oz
  return qx * F.rx + qy * F.ry + qz * F.rz, qx * F.ux + qy * F.uy + qz * F.uz, qx * F.zx + qy * F.zy + qz * F.zz
end
setmetatable(vc, { __index = function(_, k) if k == "throttle" then return craft.throttle end end })
vc.throttle = nil

local removed = {}
local inv = { valid = true, resolve = function(c) return c end,
  removeItem = function(cid, id, n) removed[#removed + 1] = cid .. ":" .. id; return 1 end,
  itemCount = function() return 1 end }
local walker = { valid = true, downed = false }
local scripts = { inventory = inv, planet_walker = walker }

local function env()
  return setmetatable({
    time = 0,
    save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end,
             delete = function(k) store[k] = nil end },
    findScript = function(k) return scripts[k] end,
    findScripts = function(k) if k == "vessel_controller" then return { vc } end return {} end,
    find = function(n) if n == "Astronaut" then return astro end end,
    log = function(m) logs[#logs + 1] = m end,
    -- the lock must never read the keys: any use of input fails the test
    input = setmetatable({}, { __index = function(_, k) error("crew_task read input." .. k) end }),
  }, { __index = _G })
end
local function load(path)
  local E = env()
  local f = assert(loadfile(path))
  setfenv(f, E)
  f()
  E.params = {}
  for k, v in pairs(E.defaults or {}) do E.params[k] = v end
  return E
end
local C = load("solar/scripts/crew.lua")
local T = load("solar/scripts/crew_task.lua")
scripts.crew, scripts.crew_task = C, T
C.valid, T.valid = true, true

local DT = 1 / 60
local function step(n)
  for _ = 1, n or 1 do
    craft.t = craft.t + DT
    T.time = (T.time or 0) + DT
    C.time = T.time
    -- the step: a kinematic body moves with the velocity it was given
    astro.x, astro.y, astro.z = astro.x + astro.vx * DT, astro.y + astro.vy * DT, astro.z + astro.vz * DT
    T.fixedUpdate(nil, DT)
  end
end

local function place_near(dist)
  local px, py, pz, vx, vy, vz = vc.partPointNow(5, 0.62 + dist, 0, 0)
  astro.x, astro.y, astro.z, astro.vx, astro.vy, astro.vz = px, py, pz, vx, vy, vz
end
local function task()
  local F = frame()
  local hx, hy, hz = F.ox + F.rx * 0.62, F.oy + F.ry * 0.62, F.oz + F.rz * 0.62
  return T.repairTask(vc, 5, hx, hy, hz, F.rx, F.ry, F.rz)
end

-- ── starting ───────────────────────────────────────────────────────────────
C.start()
place_near(9)
local t1 = task()
check(t1 and math.abs(t1.secs - (6 + 16 * 0.6)) < 1e-6, "the duration: 6 + 16 × (1 − hp)")
check(math.abs(t1.sx - (0.62 + T.params.standoff)) < 1e-6 and math.abs(t1.sy) < 1e-6,
  "the work spot: " .. T.params.standoff .. " m off the hull along the normal (arm's reach), in the part's frame")
local ok, why = C.setTask(1, t1)
check(not ok and why == "out of reach", "too far: refused (" .. tostring(why) .. ")")
place_near(1.2)
astro.vx = astro.vx + 2.0
ok, why = C.setTask(1, task())
check(not ok and why:match("slow down"), "coming in fast in space: 'slow down first' (" .. tostring(why) .. ")")
place_near(1.2)
craft.throttle = 0.5
ok, why = C.setTask(1, task())
check(not ok and why:match("engines"), "engines on: refused (" .. tostring(why) .. ")")
craft.throttle = 0
vc.crewAboard = true
ok, why = C.setTask(1, task())
check(not ok and why:match("step out"), "from the seat: refused (" .. tostring(why) .. ")")
vc.crewAboard = false

-- ── held ───────────────────────────────────────────────────────────────────
place_near(1.2)
local tk = task()
ok, why = C.setTask(1, tk)
check(ok, "beside the part, at rest relative to it: Repair starts (" .. tostring(why) .. ")")
check(C.held(1) and (rb.kinematic == 1), "held: kinematic")
step(30) -- the slide (0.4 s) and a little more
local maxerr = 0
for _ = 1, 300 do
  step(1)
  local sx, sy, sz = vc.partPointNow(5, tk.sx, tk.sy, tk.sz)
  maxerr = math.max(maxerr, len(astro.x - sx, astro.y - sy, astro.z - sz))
end
check(maxerr < 1e-6, string.format("every tick at the work spot on a tumbling, moving craft (max %.2e m)", maxerr))
local d0 = T.progress(1)
check(d0 > 5.4 and d0 < 5.6, string.format("progress runs on (%.2f s after 330 ticks)", d0))

-- ── cancel (between ticks) ─────────────────────────────────────────────────
C.cancelTask(1, "cancelled")
check(C.task(1) == nil, "cancel clears the record's task at once")
check(T.isHeld(1), "...and the body is let go on the next tick, not between ticks")
step(1)
check(not T.isHeld(1) and rb.kinematic == 0, "released: a body again")
local _, _, _, pvx, pvy, pvz = vc.partPointNow(5, tk.sx, tk.sy, tk.sz)
check(len(astro.vx - pvx, astro.vy - pvy, astro.vz - pvz) < 1e-3, "released at the part's point velocity")
local kept = craft.st[5].rprog
check(kept and math.abs(kept.s - d0) < 0.05, "progress kept on the part (" .. tostring(kept and kept.s) .. ")")

-- ── resume and finish ──────────────────────────────────────────────────────
place_near(1.2)
local tk2 = task()
ok = C.setTask(1, tk2)
local resumed = T.progress(1)
check(ok and resumed > 5.3, string.format("a re-click resumes from the kept progress (%.2f s)", resumed or -1))
step(math.ceil((tk2.secs - resumed) / DT) + 2)
check(craft.hp[5] == 1.0 and craft.repaired == 5, "finished: the part is whole")
check(#removed == 1 and removed[1] == "crew:1:repairkit", "the kit is used (" .. tostring(removed[1]) .. ")")
check(craft.st[5].rprog == nil, "the kept progress is cleared")
check(not C.held(1) and C.task(1) == nil, "released when done")

-- ── forced stops ───────────────────────────────────────────────────────────
local function forced(setup, undo, want)
  craft.hp[5] = 0.5
  place_near(1.2)
  local okf = C.setTask(1, task())
  step(5)
  setup()
  step(1)
  local stopped = not T.isHeld(1)
  local said = logs[#logs] or ""
  undo()
  if T.isHeld(1) then C.cancelTask(1, "test"); step(1) end
  check(okf and stopped and said:match(want), "forced stop: " .. want .. " (" .. said .. ")")
end
forced(function() craft.hp[5] = 0 end, function() craft.hp[5] = 0.5 end, "broke")
forced(function() craft.throttle = 0.3 end, function() craft.throttle = 0 end, "engines")
forced(function() walker.downed = true end, function() walker.downed = false end, "out of air")
forced(function() vc.node.valid = false end, function() vc.node.valid = true end, "gone")

if #failures > 0 then
  for _, m in ipairs(failures) do print("FAIL: " .. m) end
  print(string.format("smoke_crew_task: %d passed, %d FAILED", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_crew_task: all %d checks passed", passed))
