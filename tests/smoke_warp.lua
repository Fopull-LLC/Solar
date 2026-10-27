-- SMOKE: time warp parked and on foot (scripts/galaxy.lua, scripts/warp_chip.lua).
--
--   * galaxy: a craft on a closed orbit inside a built system (parked on a
--     planet, orbiting it, or circling the star inside the built ring) has no
--     warp ceiling; the speed ceiling is in GAME seconds, so it does not fall
--     as the warp rises (the 2026-10-27 bug: a parked rover was taken down a
--     step at 50-100x because its speed round the star carried the warp);
--   * the ceiling is reported only under the top of the ladder;
--   * warp_chip: the ladder steps, the cap, and every reason on-foot warp is
--     refused (EVA in space, swimming, in the air, moving, down, crew down
--     nearby, pinned, under fire, falling, heat, breath, air) — and that
--     Invincible's quiet alerts still need the crew stood still on the ground.
--
--   luajit solar/tests/smoke_warp.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end

local function load(path)
  local E = setmetatable({ params = {} }, { __index = _G })
  local f = assert(loadfile(path))
  setfenv(f, E)
  f()
  return E
end

-- ── galaxy ──────────────────────────────────────────────────────────────────
local G = load("solar/scripts/galaxy.lua")

check(G.closedWithin({ apoapsis = 1200 }, 5000) == true, "a closed orbit inside the SOI is bound")
check(G.closedWithin({ apoapsis = 9000 }, 5000) == false, "an apoapsis past the SOI is not bound")
check(G.closedWithin({ periapsis = 900 }, 5000) == false, "an escape (no apoapsis) is not bound")
check(G.closedWithin(nil, 5000) == false, "no elements: not bound")
check(G.closedWithin({ apoapsis = 0 / 0 }, 5000) == false, "a NaN apoapsis is not bound")

local c, n = G.ceilingFor({ bound = true, pending = true, margin = 10, speed = 1e6 })
check(c == math.huge and n == nil, "bound: no ceiling, even with a ring sector pending")
c, n = G.ceilingFor({ pending = true, building = 100 })
check(c == 100 and n and n:find("charting the systems ahead"), "unbound with a sector pending: the building ceiling")
-- a ship in interstellar space at 300 m/s (game), 6e6 m from the built edge, lead 25:
-- 800× — and the same number whatever the warp is (game seconds)
c, n = G.ceilingFor({ margin = 6e6, speed = 300, lead = 25, top = 10000 })
check(math.abs(c - 800) < 1e-6 and n and n:find("800"), "the speed ceiling: margin / (lead × speed), " .. tostring(c))
c, n = G.ceilingFor({ margin = 6e9, speed = 300, lead = 25, top = 10000 })
check(c == math.huge and n == nil, "a ceiling above the ladder is not reported")
c = G.ceilingFor({ margin = 10, speed = 1e5, lead = 25, top = 10000 })
check(c == 1, "the ceiling never falls under 1×")

-- ── warp_chip ───────────────────────────────────────────────────────────────
local W = load("solar/scripts/warp_chip.lua")

check(W.ladderIndex(1) == 1 and W.ladderIndex(50) == 4 and W.ladderIndex(10000) == 7, "ladder index")
check(W.stepWarp(1, 1) == 5 and W.stepWarp(50, 1) == 100 and W.stepWarp(1000, 1) == 10000, "steps up the ladder")
check(W.stepWarp(10000, 1) == 10000 and W.stepWarp(1, -1) == 1, "the ladder's ends hold")
check(W.stepWarp(100, -1) == 50, "steps down")
local nx, why = W.stepWarp(100, 1, 100)
check(nx == 100 and why == "cap", "a cap stops the step up")
check(W.stepWarp(100, -1, 10) == 50, "a cap never stops a step down")

local function st(o)
  local s = { onFoot = true, grounded = true, swimming = false, headUnder = false, floating = false,
              downed = false, inSpace = false, speed = 0.05 }
  for k, v in pairs(o or {}) do s[k] = v end
  return s
end
local calm = { o2 = 0.9, breath = 1.0, hp = 1.0, heat = 0.0, fall = 0.0, pinned = false }
local function alerts(o)
  local a = {}
  for k, v in pairs(calm) do a[k] = v end
  for k, v in pairs(o or {}) do a[k] = v end
  return a
end

check(W.footBlock(st(), alerts(), 9) == nil, "standing still on the ground, safe: warp allowed")
check(W.footBlock(st(), nil, 9) == nil, "no crew script: the walker's state alone")
check(W.footBlock(st({ onFoot = false })) == "not on foot", "not on foot")
check(W.footBlock(st({ inSpace = true })) == "on EVA in space", "EVA in space")
check(W.footBlock(st({ swimming = true })) == "swimming", "swimming")
check(W.footBlock(st({ headUnder = true })) == "swimming", "head under water")
check(W.footBlock(st({ grounded = false })) == "not on the ground", "in the air")
check(W.footBlock(st({ floating = true })) == "not on the ground", "floating")
check(W.footBlock(st({ downed = true })) == "blacked out", "blacked out")
check(W.footBlock(st({ speed = 1.2 })) == "moving", "walking speed refuses a start")
check(W.footBlock(st({ speed = 1.2, speedMax = 2.5 })) == nil, "a stumble under the hold speed keeps a warp")
check(W.footBlock(st(), alerts({ downed = 40 })) == "you are down", "downed")
check(W.footBlock(st(), alerts({ down = { name = "Mira", left = 50 } })) == "crew down nearby", "crew down nearby")
check(W.footBlock(st(), alerts({ down = { name = "Mira", left = 50, treated = true } })) == nil, "a member being treated doesn't block")
check(W.footBlock(st(), alerts({ pinned = true })) == "pinned", "pinned")
check(W.footBlock(st(), alerts({ hit = { t = 1, amount = 0.2 } })) == "under fire", "hit")
check(W.footBlock(st(), alerts({ fall = 12 }), 9) == "falling", "falling")
check(W.footBlock(st(), alerts({ heat = 0.3 })) == "overheating", "heat")
check(W.footBlock(st(), alerts({ breath = 0.6 })) == "holding your breath", "breath")
check(W.footBlock(st(), alerts({ o2 = 0.05 })) == "low on air", "air critical")
check(W.footBlock(st(), alerts({ air_s = 40 })) == "low on air", "a minute of air")
check(W.footBlock(st(), alerts({ o2 = 0.2 })) == nil, "air low (amber) doesn't block")
check(W.footBlock(st(), alerts({ hp = 0.5 })) == nil, "injured but stable doesn't block")
check(W.footBlock(st(), { safe = true, hit = { t = 1 } }) == nil, "Invincible: alerts quiet")
check(W.footBlock(st({ grounded = false }), { safe = true }) == "not on the ground", "Invincible still needs the ground")

-- say(): the notice is kept for the probes
W.say("Warp limited · moving")
check(W.lastNotice == "Warp limited · moving", "say keeps the last notice")
W.say(nil)
check(W.lastNotice == "Warp limited · moving", "say(nil) is ignored")

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL " .. f) end
  print(string.format("smoke_warp: %d passed, %d FAILED", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_warp: %d passed", passed))
