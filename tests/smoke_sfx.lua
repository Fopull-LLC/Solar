-- SMOKE HARNESS: sfx.lua — the interface's sounds. Quiet on purpose, so the
-- things held here are the ones that make a UI sound cheap: a clip stacking on
-- itself, a cash clink under the contract jingle, and a chime for news that
-- isn't news.
--
--   luajit solar/tests/smoke_sfx.lua

local T = 0.0
local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end

local played = {}
local ob = { valid = true, headline = "" }
local API = {
  audio = {
    play = function(clip, opts) played[#played + 1] = { clip = clip, opts = opts } end,
    preload = function() end,
  },
  findScript = function(kind) if kind == "objectives" then return ob end end,
}
local env = setmetatable({}, { __index = function(_, k)
  if k == "time" then return T end
  return API[k] or _G[k]
end })
local chunk = assert(loadfile("solar/scripts/sfx.lua"))
setfenv(chunk, env)
chunk()
env.start({})
local function tick(s)
  local n = math.floor((s or 0) * 60 + 0.5)
  for _ = 1, math.max(1, n) do T = T + 1 / 60; env.update({}, 1 / 60) end
end

-- A key plays its clip on the UI bus, quietly.
env.play("click")
ok(#played == 1 and played[1].clip:find("click"), "a key plays its clip")
ok(played[1].opts.track == "UI" and played[1].opts.volume <= 0.6, "…on the UI bus, quietly")
ok(pcall(env.play, "no-such-sound") and #played == 1, "an unknown key is silent, not an error")

-- The same key twice in one frame (a sale AND its discovery premium) is one clink.
env.play("cash"); env.play("cash")
ok(#played == 2, "two identical clips in one frame play once")
tick(0.5)
env.play("cash")
ok(#played == 3, "…and again once the moment has passed")

-- A payout's jingle swallows the cash clink the ledger makes under it.
tick(1.0)
env.play("jingle"); env.play("cash")
ok(#played == 4 and played[4].clip:find("confirmation_004"), "the jingle swallows the cash clink")

-- The objectives card changing step chimes — but not for the first step after
-- a load, and not while the world is still settling.
tick(1.0)
local n0 = #played
ob.headline = "Your base is going up around you."
tick(0.1)
ob.headline = "Sign your first contract."
tick(0.1)
ok(#played == n0, "no chime for the first steps after a load")
tick(4.0)
ob.headline = "Build a craft that can do the job."
tick(0.1)
ok(#played == n0 + 1 and played[#played].clip:find("glass"), "a new step chimes")
tick(1.0)
ok(#played == n0 + 1, "…once")

if #failures == 0 then
  print(string.format("SFX SMOKE OK — %d checks passed", checks))
  os.exit(0)
end
print("SFX SMOKE FAILURES:")
for _, f in ipairs(failures) do print("  ✗ " .. f) end
os.exit(1)
