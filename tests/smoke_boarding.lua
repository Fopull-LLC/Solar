-- SMOKE: boarding and EVA in the player's hands (Ty, playtest 2026-11-11).
--
--   * the exit picker (scripts/exit_picker.lua): a row a member aboard and
--     EVERYONE, numbered; a refused member greyed with the reason; F picks
--     you; EVERYONE sends the others first and you last, only those who may;
--   * the board / grab rule (crew_task.hatchRule): an open seat in reach;
--     on a part's ladder only at the hatch; a hatch up its ladder must be
--     climbed to; a hatch at standing height is walked up to; a part with no
--     ladder (an old save's) within 2 m of the hatch;
--   * the ladder's line (crew_task.ladderAt / climbSpot / climbRange): the
--     rails' slant, the hull under them pushing the climber out, the ends;
--   * the climb as a held task: W / S move along the line, the body held in
--     the part's frame, at rest relative to it; the hold ends with no write
--     to the body when the crew goes in (dropHold);
--   * the crew strip's EVA in the picture's corner.
--
--   luajit solar/tests/smoke_boarding.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, e) return math.abs(a - b) <= (e or 1e-6) end

local function load(path, extra)
  local E = setmetatable(extra or {}, { __index = _G })
  local f = assert(loadfile(path))
  setfenv(f, E)
  f()
  E.params = {}
  for k, v in pairs(E.defaults or {}) do E.params[k] = v end
  return E
end

-- ── the exit picker ─────────────────────────────────────────────────────────
local X = load("solar/scripts/exit_picker.lua")
local list = {
  { id = 4, name = "Dana Okafor", commander = true, label = "Pod Mk2", uid = 3 },
  { id = 7, name = "Jo Reyes", label = "Pod Mk2", uid = 3 },
  { id = 9, name = "Mae Hale", label = "Crew Cabin", uid = 5 },
}
local checks = { [4] = { ok = true }, [7] = { ok = true, warn = "no pack" }, [9] = { ok = false, why = "down" } }
local rs = X.rows(list, checks, 4)
check(#rs == 4, "three members and EVERYONE: " .. #rs .. " rows")
check(rs[1].key == "1" and rs[2].key == "2" and rs[3].key == "3" and rs[4].key == "4", "numbered 1…4")
check(rs[1].you and not rs[2].you, "the member you control is marked")
check(rs[3].ok == false and rs[3].why == "down", "a refused member: greyed with the reason")
check(rs[2].warn == "no pack", "the no-pack warning rides the row (asked first)")
check(rs[4].everyone and rs[4].ok and rs[4].n == 2, "EVERYONE: the two who may go")
check(X.keyPick(rs, "2").id == 7, "2 picks the second")
check(X.keyPick(rs, "f").id == 4, "F picks you")
check(X.keyPick(rs, "4").everyone, "the last number is EVERYONE")
check(X.keyPick(rs, "9") == nil, "a number past the rows picks nothing")
local others, you = X.order(rs, 4)
check(#others == 1 and others[1] == 7 and you == 4, "EVERYONE: the others first, you last, the refused left aboard")
local none = X.rows({ { id = 1, name = "A B" }, { id = 2, name = "C D" } }, { [1] = { ok = false, why = "x" }, [2] = { ok = false, why = "y" } }, 1)
check(none[3].everyone and not none[3].ok, "nobody may go: EVERYONE greyed")
local many = {}
for i = 1, 12 do many[i] = { id = i, name = "N " .. i } end
local mr = X.rows(many, {}, 1)
check(#mr == 9 and mr[9].everyone and mr[9].key == "9", "a big crew: eight rows and EVERYONE on 9 (digits only go to 9)")
check(X.shortName("Dana Okafor") == "D.OKAFOR", "names as the strip writes them")

-- ── the board / grab rule ───────────────────────────────────────────────────
local T = load("solar/scripts/crew_task.lua", { time = 0, log = function() end })
local H = T.HATCH
check(T.hatchRule({ open = true, dSeat = 2.0 }) == "enter", "an open seat in reach: sit")
check(T.hatchRule({ open = true, dSeat = 5.0 }) == nil, "an open seat out of reach: nothing")
check(T.hatchRule({ ladder = true, needLadder = true, dHatch = 0.5, dLadder = 0.4 }) == "grab",
  "a hatch up its ladder (or in space): grab the ladder first, even beside the hatch")
check(T.hatchRule({ ladder = true, needLadder = true, dHatch = 6, dLadder = 3 }) == nil, "far from the ladder: nothing")
local a1, w1 = T.hatchRule({ ladder = true, needLadder = true, dHatch = 6, dLadder = 3 })
check(a1 == nil and w1 and w1:find("ladder"), "…and it says to grab the ladder (" .. tostring(w1) .. ")")
check(T.hatchRule({ ladder = true, climbing = true, dHatch = 0.9 }) == "enter", "on the ladder by the hatch: enter")
check(T.hatchRule({ ladder = true, climbing = true, dHatch = 2.5 }) == nil, "on the ladder below the hatch: climb first")
check(T.hatchRule({ ladder = true, needLadder = false, dHatch = 1.0, dLadder = 0.8 }) == "enter",
  "a hatch at standing height: walk up and enter")
check(T.hatchRule({ dHatch = 1.9 }) == "enter" and T.hatchRule({ dHatch = 2.1 }) == nil,
  "no ladder (an old save's craft): within " .. H.fallback .. " m of the hatch")

-- ── the ladder's line ───────────────────────────────────────────────────────
-- the Pod Mk1's numbers (crew.SEATS.pod.ladder)
local C = load("solar/scripts/crew.lua", { save = { get = function() end, set = function() end }, log = function() end })
local L0 = C.SEATS.pod.ladder
check(L0 and L0.a.y < L0.b.y and near(L0.n.x * L0.n.x + L0.n.z * L0.n.z, 1, 1e-3), "the pod has a ladder: bottom, top, unit normal")
check(C.SEATS.podMk2.ladder and C.SEATS.cabin.ladder and not C.SEATS.cockpit.ladder and not C.SEATS.seat.ladder,
  "Pod Mk2 and Crew Cabin too; the cockpit and the open seat have none")
local t = { a = L0.a, b = L0.b, n = L0.n, s = 0 }
local x0, _, z0 = T.ladderAt(t, L0.a.y)
local x1, _, z1 = T.ladderAt(t, L0.b.y)
check(near(x0, L0.a.x) and near(z1, L0.b.z), "the line runs rail to rail")
local xm = T.ladderAt(t, (L0.a.y + L0.b.y) / 2)
check(near(xm, (L0.a.x + L0.b.x) / 2, 1e-6), "…along the wall's slant")
local xb = T.ladderAt(t, L0.a.y - 2)
check(near(xb, L0.a.x), "below the rails: straight down")
-- a landed craft: the hull under the rails pushes the climber out
local te = { a = L0.a, b = L0.b, n = L0.n, ext = { y0 = -4.3, step = 0.3, off = {} } }
for i = 1, 14 do te.ext.off[i] = 0.25 end
local _, _, _, off = T.ladderAt(te, -2.0)
check(near(off, 0.25), "the hull under the rails pushes the climber " .. off .. " m out")
te.s = -2.0
local sx, sy, sz = T.climbSpot(te)
check(near(sx, L0.a.x + L0.n.x * (T.CLIMB.away + 0.25), 1e-6) and near(sy, -2.0), "the suit's spot: out along the normal by its stand-off")
check(te.ly > te.s, "the hands' point is above the suit's centre")
local lo, hi = T.climbRange({ a = L0.a, b = L0.b, ylow = -4.3 })
check(near(lo, -4.3 + T.CLIMB.foot) and near(hi, L0.b.y - T.CLIMB.top_drop), "landed: from standing on the ground to the top rung")
local lo2, hi2 = T.climbRange({ a = L0.a, b = L0.b })
check(lo2 <= hi2 and hi2 <= L0.b.y and lo2 >= L0.a.y, "in space: on the handrail, by the hatch")
local lo3, hi3 = T.climbRange({ a = L0.a, b = L0.b, ylow = L0.a.y - 0.1 })
check(near(lo3, hi3), "a pod on the ground: no climb (the hatch is walked up to)")

-- ── the climb as a held task ────────────────────────────────────────────────
local rb = { kinematic = 0 }
local astro = { id = 99, valid = true, x = 0, y = 0, z = 0, vx = 0, vy = 0, vz = 0,
                getComponent = function(_, k) return k == "RigidBody" and rb or nil end }
local store = { g_seed = 3 }
local V = { 3, 0, 0 }
local tnow = 0
local function frame() return { ox = V[1] * tnow, oy = 0, oz = 0, rx = 1, ry = 0, rz = 0, ux = 0, uy = 1, uz = 0, zx = 0, zy = 0, zz = 1,
                                cx = 0, cy = 0, cz = 0, vx = V[1], vy = 0, vz = 0, wx = 0, wy = 0, wz = 0 } end
local vc = { valid = true, node = { id = 7, valid = true }, craftName = "Lander", throttle = 0, crewAboard = false,
  partHp = function() return 1 end, isLost = function() return false end,
  evaState = function() return { surface = true, space = false, speed = 0, throttle = 0 } end }
function vc.partFrameNow() return frame() end
function vc.partPointNow(u, lx, ly, lz)
  local F = frame()
  return F.ox + lx, ly, lz, F.vx, 0, 0
end
function vc.partLocalNow(u, wx, wy, wz) local F = frame(); return wx - F.ox, wy, wz end
function vc.ladderOf() return { a = L0.a, b = L0.b, n = L0.n, half = 0.11, hatch = { x = 0.47, y = -0.02, z = 0 }, ylow = -4.3,
                                ext = { y0 = -4.3, step = 0.3, off = { 0.2, 0.2, 0.2 } }, label = "Pod Mk1" } end
local scripts = { planet_walker = { valid = true } }
local env2 = { time = 0, log = function() end,
  save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end, delete = function(k) store[k] = nil end },
  findScript = function(k) return scripts[k] end,
  findScripts = function(k) if k == "vessel_controller" then return { vc } end return {} end,
  find = function(n) if n == "Astronaut" then return astro end end }
local C2 = load("solar/scripts/crew.lua", env2)
local env3 = {}
for k, v in pairs(env2) do env3[k] = v end
local T2 = load("solar/scripts/crew_task.lua", env3)
scripts.crew, scripts.crew_task = C2, T2
C2.valid, T2.valid = true, true
C2.start()
local id = C2.activeId()
astro.x, astro.y, astro.z = 0.9, -3.0, 0.9
local ok, why = T2.startClimb(id, vc, 3); if not ok then print("startClimb", ok, why, id) end
check(ok, "on the ladder (" .. tostring(why) .. ")")
check(C2.held(id), "held by it: the walker and the pack stand down")
local tk = C2.task(id)
check(tk and tk.kind == "climb" and near(tk.s, -3.0), "at the height they grabbed it (" .. tostring(tk and tk.s) .. ")")
local function step(n)
  for _ = 1, n do
    tnow = tnow + 1 / 60
    T2.time, C2.time = tnow, tnow
    T2.fixedUpdate(nil, 1 / 60)
  end
end
step(30)
local F = frame()
check(near(astro.x - F.ox, tk.sx, 1e-6) and near(astro.y, tk.sy, 1e-6), "held at its spot on the line, in the part's frame")
check(near(astro.vx, V[1]) and rb.kinematic == 1, "kinematic, at the craft's velocity (at rest relative to it)")
-- W: the key is the frame's; the tick moves it
T2.update = T2.update   -- (the keys are read in update: drive the command the same way)
local s0 = tk.s
local up = T2.CLIMB.up
-- (a stand-in for update's W: the tick reads the same command)
local function climb(cmd, n)
  for _ = 1, n do
    T2.input = { key = function(k) return (cmd > 0 and k == "w") or (cmd < 0 and k == "s") end, pressed = function() return false end }
    T2.update(nil, 1 / 60)
    step(1)
  end
end
climb(1, 60)
check(near(tk.s, s0 + up, 0.03), string.format("W for a second: up %.2f m (%.2f m/s)", tk.s - s0, up))
climb(1, 600)
check(near(tk.s, tk.hi), "…and no further than the top rung")
check(T2.climbState and T2.climbState.top, "at the top: climbState says so")
climb(-1, 900)
check(near(tk.s, tk.lo) and T2.climbState.bottom, "S: down to the foot, standing on the ground")
-- the hatch: no write to the body as the craft seats them
local before = { astro.x, astro.y, astro.z, astro.vx, rb.kinematic }
check(T2.dropHold(id), "through the hatch: the hold ends")
check(astro.x == before[1] and astro.vx == before[4] and rb.kinematic == before[5], "…with no write to the body (the seat takes it)")
check(not C2.held(id) and C2.task(id) == nil, "…and the task is gone")

-- ── the crew strip's corner button ──────────────────────────────────────────
local src = io.open("solar/scripts/crew_strip.lua"):read("*a")
check(src:find('key = "eva" .. i, style = "hud/button", pin = "topRight"', 1, true) ~= nil, "EVA in the picture's top-right corner on hover")
check(src:find("function portraitTex", 1, true) ~= nil, "the strip lends the picker its live pictures")

print(string.format("smoke_boarding: %d passed, %d failed", passed, #failures))
for _, f in ipairs(failures) do print("  FAIL " .. f) end
if #failures > 0 then os.exit(1) end
