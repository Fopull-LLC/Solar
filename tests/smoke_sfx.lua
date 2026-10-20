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
-- The things sfx.lua listens to, as the plain published values they are.
local pm = { valid = true, open = false }
local ip = { valid = true, open = false }
local map_open = false
local om = { valid = true, isOpen = function() return map_open end }
local fo = { valid = true, mode = nil }
local astro = { valid = true, __id = 7, up_x = 0, up_y = 1, up_z = 0, vx = 0, vy = 0, vz = 0 }
local wk = { valid = true, onFoot = true, swimming = false, node = astro,
             swimState = { vf = 0, vs = 0, vu = 0, under = false } }
local hushed, shown = nil, nil
local ss = { valid = true, hush = function(s) hushed = s end }
local bc = { valid = true, show = function(t, sub) shown = t end }
local captions = {}
local SCRIPTS = { objectives = ob, pause_menu = pm, inventory_panel = ip, orbit_map = om,
                  flight_ops = fo, planet_walker = wk, soundscape = ss, big_caption = bc }
local API = {
  audio = {
    -- audio.play(clip [, node] [, opts]): record which, so "follows the crew"
    -- is checkable.
    play = function(clip, a, b)
      local node, opts = nil, a
      if type(a) == "table" and a.__id then node, opts = a, b end
      played[#played + 1] = { clip = clip, opts = opts, node = node }
    end,
    preload = function() end,
  },
  findScript = function(kind) return SCRIPTS[kind] end,
  caption = function(t) captions[#captions + 1] = t end,
  -- The crew is what marks a game scene (sfx.lua listens only where there is one).
  find = function(name) if name == "Astronaut" then return astro end end,
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

-- ── what the review found mute ──────────────────────────────────────────────
local function last_clip() return played[#played] and played[#played].clip or "" end
local function heard(needle, n0)
  for i = (n0 or 0) + 1, #played do if played[i].clip:find(needle, 1, true) then return true end end
  return false
end

-- The pause menu, the bag and the map are HEARD: their published state flips
-- and the edge makes the sound, with no audio line in any of those scripts.
local n = #played
pm.open = true; tick(0.05)
ok(heard("maximize_002", n), "opening the pause menu makes a sound")
n = #played
pm.open = false; tick(0.05)
ok(heard("minimize_002", n), "...and closing it another")
n = #played
ip.open = true; tick(0.05); ip.open = false; tick(0.05)
ok(heard("open_001", n) and heard("close_001", n), "the bag opens and closes audibly")
n = #played
map_open = true; tick(0.05); map_open = false; tick(0.05)
ok(heard("maximize_006", n) and heard("minimize_006", n), "the map opens and closes audibly")
n = #played
tick(0.5)
ok(#played == n, "...and nothing repeats while nothing changes")

-- The flight card coming up, once — not again as it flips recover ↔ leave.
fo.mode = "flying"; tick(0.05)
n = #played
fo.mode = "recover"; tick(0.05)
ok(heard("question_002", n), "the flight card coming up is heard")
n = #played
fo.mode = "leave"; tick(0.05); fo.mode = "recover"; tick(0.05)
ok(#played == n, "...but not the card changing its mind at the base's edge")
env.flightEnded("recover")
ok(last_clip():find("confirmation_003"), "a recovery has its own confirmation")
env.play("cash")
ok(last_clip():find("confirmation_003"), "...and swallows the refund's cash clink")
tick(1.0)
env.flightEnded("leave")
ok(last_clip():find("back_002"), "leaving the craft where it sits has its own sound")

-- The crew: jump and land follow the astronaut on the SFX bus, and a run of
-- the same sound is not one clip on a loop.
n = #played
env.playAt("jump", astro)
local p = played[#played]
ok(p and p.node == astro and p.opts.track == "SFX", "a jump follows the astronaut on the SFX bus")
local clips = {}
for _ = 1, 6 do tick(0.2); env.playAt("land", astro, 0.8); clips[#clips + 1] = last_clip() end
local repeats = 0
for i = 2, #clips do if clips[i] == clips[i - 1] then repeats = repeats + 1 end end
ok(repeats == 0, "landings never play the same variant twice running")
ok(played[#played].opts.volume <= 0.6, "...at a footstep's level, not a UI blast")
ok(pcall(env.playAt, "no-such", astro), "an unknown world sound is silent, not an error")

-- Swimming: wading in splashes softly, strokes come round while moving, and
-- under the surface there are bubbles.
n = #played
wk.swimming = true; tick(0.05)
ok(heard("audio/water/splash_", n), "wading into the sea is heard")
n = #played
wk.swimState.vf = 1.4
tick(3.0)
local strokes = 0
for i = n + 1, #played do if played[i].clip:find("swim_stroke") then strokes = strokes + 1 end end
ok(strokes >= 2 and strokes <= 6, "swimming at 1.4 m/s strokes every second or so (" .. strokes .. " in 3 s)")
n = #played
wk.swimState.vf = 0; tick(2.0)
ok(not heard("swim_stroke", n), "...and treading water is quiet")
n = #played
wk.swimState.under = true; tick(7.0)
ok(heard("bubbles_", n), "under the surface, bubbles")
wk.swimming, wk.swimState.under = false, false; tick(0.1)

-- VESSEL LOST: the sting, a caption, the music out of the way, the big words —
-- and none of it for a wreck nobody was flying.
n = #played
env.vesselLost(false, "Debris")
ok(#played == n and shown == nil, "a wreck nobody was flying is not 'vessel lost'")
env.vesselLost(true, "Kestrel II")
ok(last_clip():find("vessel_lost"), "losing your craft plays the sting")
ok(captions[#captions] and captions[#captions]:find("lost"), "...captions it for a player with the sound off")
ok(hushed and hushed > 5, "...hushes the music")
ok(shown == "VESSEL LOST", "...and puts VESSEL LOST in the middle of the screen")
ok(env.played and env.played.lost == 1, "the probe counter saw it once")

if #failures == 0 then
  print(string.format("SFX SMOKE OK — %d checks passed", checks))
  os.exit(0)
end
print("SFX SMOKE FAILURES:")
for _, f in ipairs(failures) do print("  ✗ " .. f) end
os.exit(1)
