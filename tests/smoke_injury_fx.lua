-- SMOKE: the injury screen (scripts/injury_fx.lua; playtest 2026-11-05,
-- "not great immersiveness with blood effects on screen with injuries so
-- hard to tell certain things").
--   * healthy: nothing drawn, the layer hidden, the grade untouched;
--   * the three looks scale with hp (blood loss, blood on the rim, the colour
--     draining and the edges closing in), a heartbeat under 35 %;
--   * a hit flashes once in its cause's colour and shakes the camera;
--   * healed, it fades back out and the saturation is put back.
--   luajit solar/tests/smoke_injury_fx.lua

local passed, failures = 0, {}
local function check(ok, msg) if ok then passed = passed + 1 else failures[#failures + 1] = msg end end

local T = 0
local rec = { hp = 1.0, heat = 0, status = "afoot" }
local lastHit = {}
local shakes = {}
local el = { visible = false }
local handles = {}
local function handle(name)
  handles[name] = handles[name] or { opacity = 0, tintR = 1, tintG = 1, tintB = 1 }
  return handles[name]
end
local made = 0
local post = { saturation = 1.1 }
local node = {
  getcomponent = function(_, k) if k == "UiElement" then return el end end,
  find = function(_, name) return { getcomponent = function() return handle(name) end } end,
}
local scripts = {
  crew = { valid = true, activeId = function() return 1 end, get = function() return rec end, lastHit = lastHit,
           invincible = function() return false end },
  planet_walker = { valid = true, onFoot = true, oxygen = 1.0 },
  planet_camera = { valid = true, addShake = function(a) shakes[#shakes + 1] = a end },
}
local E = setmetatable({
  findScript = function(k) return scripts[k] end,
  find = function(n) if n == "Post Processing" then return { getcomponent = function() return post end } end end,
  ui = { make = function() made = made + 1 end },
}, { __index = function(_, k) if k == "time" then return T end return _G[k] end })
local f = assert(loadfile("solar/scripts/injury_fx.lua"))
setfenv(f, E)
f()
E.params = { enabled = 1 }
E.start(node)
local function run(secs)
  local n = math.floor(secs * 60 + 0.5)
  for _ = 1, n do T = T + 1 / 60; E.lateUpdate(node, 1 / 60) end
end

-- the pure rules
local b, s, d, ds, g, beat = E.targets(1.0, 0, 1.0)
check(b == 0 and s == 0 and d == 0 and ds == 0 and g == 0 and beat == 0, "healthy: nothing asked for")
b, s, d, ds, g, beat = E.targets(0.7, 0, 1.0)
check(b > 0 and b < 0.1 and s == 0 and ds == 0 and beat == 0, "70%: a faint red edge only (" .. b .. ")")
b, s, d, ds, g, beat = E.targets(0.4, 0, 1.0)
check(b > 0.25 and s > 0.15 and ds > 0 and d == 0 and beat == 0, "40%: blood loss, blood on the rim, the colour going")
local b15, s15, d15, ds15, _, beat15, rate15 = E.targets(0.15, 0, 1.0)
check(b15 > b and s15 > s and d15 > 0.2 and ds15 > 0.4 and beat15 > 0.7, "15%: all of it, and the heartbeat")
check(rate15 > 1.5 and rate15 < 2.2, "…its heart racing (" .. rate15 * 60 .. " a minute)")
local _, _, dh, dsh = E.targets(1.0, 0, 0.05)
check(dh > 0.4 and dsh > 0.3, "out of air: the edges close in and the colour drains")
local _, _, _, _, gh = E.targets(1.0, 0.8, 1.0)
check(gh > 0.4, "heat: an orange glow at the edges")
check(E.heartbeat(0.06) > 0.9 and E.heartbeat(0.30) > 0.5 and E.heartbeat(0.65) < 0.05, "a lub, a dub, then quiet")
for _, c in ipairs({ "impact", "shot", "heat", "crush", "blast" }) do check(E.FLASH[c] ~= nil, "a flash colour for " .. c) end

-- the runtime
run(1.0)
check(el.visible == false and made == 0 and post.saturation == 1.1, "healthy: the layer stays hidden, nothing built, the grade untouched")
rec.hp = 0.3
run(3.0)
check(el.visible == true and made == 1, "hurt: shown, built once")
check(handles.InjuryBlood.opacity > 0.3 and handles.InjurySplat.opacity > 0.3, "hurt: blood loss and blood on the rim")
check(post.saturation < 1.0, "hurt: the colour drained (" .. post.saturation .. ")")
-- a fall's hit
lastHit[1] = { t = T, amount = 0.25, cause = "impact" }
run(1 / 60)
check(handles.InjuryFlash.opacity > 0.7, "a hit flashes (" .. handles.InjuryFlash.opacity .. ")")
check(math.abs(handles.InjuryFlash.tintR - E.FLASH.impact[1]) < 1e-9, "…in the colour of a fall")
check(#shakes == 1 and shakes[1] > 0.5, "…and shakes the camera once")
run(1.0)
check(handles.InjuryFlash.opacity < 0.05, "the flash is gone within a second")
run(1.0)
check(#shakes == 1 and made == 1, "the same hit flashes once; nothing rebuilt")
lastHit[1] = { t = T, amount = 0.2, cause = "shot" }
run(1 / 60)
check(math.abs(handles.InjuryFlash.tintR - E.FLASH.shot[1]) < 1e-9, "a shot flashes red")
-- healed
rec.hp = 1.0
run(8.0)
check(el.visible == false and math.abs(post.saturation - 1.1) < 1e-9, "healed: faded out, hidden, the grade put back")

if #failures > 0 then
  for _, m in ipairs(failures) do print("FAIL: " .. m) end
  print(string.format("smoke_injury_fx: %d passed, %d FAILED", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_injury_fx: all %d checks passed", passed))
