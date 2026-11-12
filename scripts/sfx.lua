-- SFX — the interface's voice, and the crew's.
--
-- Every panel, payout and contract in the game used to happen in silence:
-- money arrived as a number changing, a contract signed as a row changing
-- colour, and a panel opened with nothing to say it had. A player review found
-- the rest: the pause menu, the bag, the map and the end of a flight were mute,
-- a jump made no sound and neither did landing from it, swimming was silent
-- and a lost vessel was a line in the log.
--
-- Two kinds of sound live here:
--
--   * INTERFACE — real CC0 switch, relay and printer recordings on the UI bus
--     (audio/foley, see CLIPS), kept QUIET. These are
--     confirmations, not events, and a click louder than a footstep is a click
--     the player learns to hate. `play(key)`.
--   * THE CREW — jump, landing, swim strokes, bubbles, wading in. On the SFX
--     bus, following the astronaut, so they sit in the world with the
--     footsteps. `playAt(key, node, vol)`.
--
-- Most of it is HEARD, not called. Panels publish whether they are open
-- (pause_menu.open, inventory_panel.open, orbit_map.isOpen(), flight_ops.mode,
-- planet_walker.swimming) and `update` listens for the edges, so a panel never
-- has to remember to make its own noise and none of those scripts carries an
-- audio line. The few things that cannot be heard from outside call in:
--
--     local s = findScript("sfx")
--     if s then s.play("cash") end                 -- company.lua, a payout
--     if s then s.play("select") end               -- the VAB, a part picked up
--     if s then s.play("place") end                -- the VAB, a part attached
--     if s then s.playAt("jump", node) end         -- planet_walker, the jump
--     if s then s.flightEnded("recover") end       -- flight_ops, it worked
--     if s then s.vesselLost(piloting, name) end   -- vessel_controller
--
-- Callers always allow for a nil handle: a harness (or a scene) with no sfx
-- node is a silent game, not a broken one.

local K = "audio/kenney/impact/"
local F = "audio/foley/"

-- key → { clip, volume }  (flat, UI bus)
--
-- The interface sounds like a company's hardware, not a game's: real switch
-- and relay clicks, a calculator printing its ticket when money moves, a
-- typewriter key for a signature, a lock buzzer for "no", and the Apollo
-- Quindar tone — the radio chirp at the end of a transmission — kept for the
-- two moments the radio would speak (the flight card, the next step). All CC0
-- recordings, cut and levelled by tools/build_sfx.py; sources in
-- audio/SOURCES.md. No tonal bleeps: a click louder than a footstep is a
-- click the player learns to hate.
local CLIPS = {
  click  = { F .. "switch_1.ogg",      0.50 },
  open   = { F .. "rocker_on.ogg",     0.80 },
  close  = { F .. "rocker_off.ogg",    0.90 },
  cash   = { F .. "ticket_short.ogg",  0.50 },
  jingle = { F .. "ticket_print.ogg",  1.00 },
  sign   = { F .. "key_strike.ogg",    1.00 },
  chime  = { F .. "quindar_out.ogg",   0.16 },
  arm    = { F .. "toggle_on.ogg",     0.90 },
  denied = { F .. "buzz_denied.ogg",   0.45 },
  -- The pause menu: the world stopping, and starting again — the big switch.
  pause_open  = { F .. "latch_clunk.ogg", 0.70 },
  pause_close = { F .. "clamp_clunk.ogg", 0.60 },
  -- The suit pack. Its own pair, so the bag doesn't sound like a building.
  bag_open  = { F .. "hiss_seal.ogg",  0.35 },
  bag_close = { K .. "impactPlate_light_002.ogg", 0.45 },
  bag_move  = { K .. "impactSoft_medium_001.ogg", 0.25 },
  -- The orbit map: the tracking console coming up, a breath of radio.
  map_open  = { F .. "radio_squelch.ogg", 0.45 },
  map_close = { F .. "toggle_off.ogg",    0.75 },
  -- The flight card coming up, and the three ways out of it.
  card    = { F .. "quindar_in.ogg",   0.18 },
  recover = { F .. "ticket_print.ogg", 0.70 },
  leave   = { F .. "toggle_off.ogg",   0.90 },
  pickup  = { F .. "latch_clunk.ogg",  0.90 },
  -- The VAB: a part lifted off the floor (`select`), and set onto the craft
  -- (`place`) — the clamp letting go, and the clamp biting.
  select  = { F .. "hiss_cylinder.ogg", 0.40 },
  place   = { F .. "clamp_clunk.ogg",   0.50 },
  -- VESSEL LOST (audio/sfx/vessel_lost.ogg, tools/gen_soundscape_audio.py):
  -- a low boom and a falling three-note figure. The one loud thing here.
  lost   = { "audio/sfx/vessel_lost.ogg", 0.85 },
}

-- key → { {clips…}, volume, minDistance, maxDistance }  (SFX bus, follows a node)
local function seq(prefix, from, to, ext)
  local t = {}
  for i = from, to do t[#t + 1] = string.format("%s%03d%s", prefix, i, ext or ".ogg") end
  return t
end
local WORLD = {
  jump    = { seq(K .. "impactSoft_medium_", 0, 4), 0.30, 3, 40 },
  land    = { seq(K .. "impactSoft_heavy_", 0, 4),  0.55, 3, 50 },
  stroke  = { { "audio/sfx/swim_stroke_1.ogg", "audio/sfx/swim_stroke_2.ogg",
                "audio/sfx/swim_stroke_3.ogg", "audio/sfx/swim_stroke_4.ogg" }, 0.42, 3, 40 },
  bubbles = { { "audio/sfx/bubbles_1.ogg", "audio/sfx/bubbles_2.ogg", "audio/sfx/bubbles_3.ogg" },
              0.38, 2, 25 },
  wade    = { { "audio/water/splash_1.ogg", "audio/water/splash_2.ogg", "audio/water/splash_3.ogg" },
              0.22, 3, 50 },
  -- Older hooks, kept for callers that name them: a torn-up part shorting out
  -- (a real arc, not the radio crackle it was), a knock on the hull (a light
  -- metal knock, not the steel bar dropped on a path that was every hit), a
  -- tyre meeting the ground. vehicle_fx asks `impact` and `fail` now.
  zap     = { { "audio/impact/zap_1.ogg", "audio/impact/zap_2.ogg", "audio/impact/zap_5.ogg" }, 0.30, 2, 30 },
  knock   = { { "audio/impact/metal_light_1.ogg", "audio/impact/metal_light_2.ogg",
                "audio/impact/metal_light_3.ogg" }, 0.45, 4, 60 },
  tyre    = { { "audio/impact/tyre_1.ogg", "audio/impact/tyre_2.ogg", "audio/impact/tyre_3.ogg" }, 0.45, 3, 50 },
}

-- A sale that also pays a discovery premium is two ledger entries in one
-- frame; two identical clicks stacked on top of each other just sound louder.
-- And a contract payout is its own jingle — the cash clink under it is noise,
-- and so is the cash clink under a recovery's own confirmation.
local REPEAT = 0.12
local HUSH = { cash = "jingle", chime = "jingle" }   -- key → the clip that swallows it
local HUSH2 = { cash = "recover" }
local last = {}

-- Published for probes: how many times each key has played this session.
played = {}

local function count(key) played[key] = (played[key] or 0) + 1 end

function play(key, vol)
  local c = CLIPS[key]
  if not (c and audio and audio.play) then return end
  local now = time or 0
  if last[key] and now - last[key] < REPEAT then return end
  for _, h in ipairs({ HUSH, HUSH2 }) do
    local over = h[key]
    if over and last[over] and now - last[over] < 0.6 then return end
  end
  last[key] = now
  count(key)
  audio.play(c[1], { track = "UI", volume = c[2] * (vol or 1.0) })
end

-- A world sound on the SFX bus, following `node` (or flat, without one). Picks
-- a different variant from last time, so a run of strokes is not a loop.
local pick_last = {}
function playAt(key, node, vol, opts)
  local w = WORLD[key]
  if not (w and audio and audio.play) then return end
  local now = time or 0
  if last[key] and now - last[key] < 0.08 then return end
  last[key] = now
  local list = w[1]
  local i = math.random(1, #list)
  if #list > 1 and i == pick_last[key] then i = i % #list + 1 end
  pick_last[key] = i
  count(key)
  local o = { track = "SFX", volume = w[2] * (vol or 1.0), minDistance = w[3], maxDistance = w[4],
              pitch = 0.94 + math.random() * 0.12 }
  for k, v in pairs(opts or {}) do o[k] = v end
  if node and node.valid ~= false then
    audio.play(list[i], node, o)
  else
    o.minDistance, o.maxDistance = nil, nil
    audio.play(list[i], o)
  end
end

-- ── called in ───────────────────────────────────────────────────────────────

-- A script that is not in this scene (the main menu has no bag) is asked for
-- again every two seconds, not every frame: each ask is a scene walk.
local refs, missed = {}, {}
local function ref(kind)
  local r = refs[kind]
  if r and r.valid then return r end
  local now = time or 0
  if missed[kind] and now - missed[kind] < 2.0 then return nil end
  r = findScript and findScript(kind) or nil
  refs[kind], missed[kind] = r, (r == nil) and now or nil
  return r
end

-- ── IMPACTS, FAILURES AND FOOTSTEPS: what met what ─────────────────────────
--
-- Ty, 2026-11-12: "impacts and damage sound odd because the same sound effect
-- gets reused and doesn't fit the context". A hull knocking the ground was one
-- sheet steel bar dropped on a path whatever it hit, a part grinding along the
-- ground was a bird scarer's gunshot, a torn part shorting out was radio
-- interference, and every footstep on every world was concrete. Now a sound is
-- picked by WHAT MET WHAT (metal, rock, soil, sand, ice, glass, plastic, wood,
-- the suit, a tyre), HOW HEAVY and HOW FAST, out of banks of real recordings
-- (audio/impact, tools/build_impact_audio.py, audio/SOURCES.md), several takes
-- each, never the same take twice running, with pitch and level jitter.
--
--     local s = findScript("sfx")
--     s.impact{ a = "metal", b = "terrain", speed = 9, mass = 2400, x = .., y = .., z = .. }
--     s.fail("part_break", { node = part })          -- see FAIL for the kinds
--     s.step(s.surfaceAt(x, y, z), node, vol, maxd)  -- planet_walker
--
-- `b = "terrain"` (or a = ...) asks the ground at the point what it is made of
-- (terrain.slotAt → materials.ofSlot). Everything lands in `history` (newest
-- last) and, with `sfxLog = true`, in the Console as "SFX <event> <bank> <clip>"
-- — so probes check which sound played by log, never by listening.

local IM = "audio/impact/"
local function takes(name, n, dir)
  local t = {}
  for i = 1, n do t[i] = (dir or IM) .. name .. "_" .. i .. ".ogg" end
  return t
end
local function kenney(name, from, to) return seq(K .. name .. "_", from, to) end

-- bank → { clips, volume, minDistance, maxDistance, pitch jitter (±) }
BANKS = {
  metal_light = { takes("metal_light", 4), 0.60, 3, 70, 0.06 },
  metal_dull  = { takes("metal_dull", 6), 0.85, 4, 140, 0.05 },
  metal_rock  = { takes("metal_rock", 3), 0.85, 4, 160, 0.06 },
  metal_metal = { takes("metal_metal", 4), 0.80, 4, 140, 0.06 },
  metal_heavy = { takes("metal_heavy", 4), 1.00, 6, 320, 0.05 },
  crash       = { takes("crash", 3), 1.00, 8, 500, 0.05 },
  part_break  = { takes("part_break", 5), 0.95, 5, 260, 0.06 },
  scrape      = { takes("scrape", 5), 0.55, 3, 90, 0.08 },
  explode     = { takes("explode", 1), 1.00, 10, 2500, 0.10 },
  blast       = { { F .. "pyro_bang.ogg" }, 0.70, 6, 900, 0.06 },
  soil_light  = { takes("soil_light", 4), 0.60, 3, 50, 0.06 },
  soil_heavy  = { takes("soil_heavy", 3), 0.85, 4, 120, 0.05 },
  rock_light  = { takes("rock_light", 6), 0.55, 3, 50, 0.07 },
  rock_soil   = { takes("rock_soil", 4), 0.75, 3, 90, 0.06 },
  rock_heavy  = { { "audio/ambience/cave_slab_hit_1.ogg", "audio/ambience/cave_slab_hit_2.ogg" }, 0.9, 5, 200, 0.06 },
  suit_fall   = { { IM .. "suit_fall_1.ogg", IM .. "soil_light_2.ogg", IM .. "soil_light_3.ogg" }, 0.70, 3, 50, 0.05 },
  glass_knock = { { IM .. "glass_knock_1.ogg", K .. "impactGlass_light_000.ogg", K .. "impactGlass_light_002.ogg" }, 0.50, 2, 40, 0.06 },
  glass_break = { takes("glass_break", 2), 0.85, 3, 90, 0.05 },
  visor_crack = { takes("visor_crack", 1), 0.80, 1, 15, 0.05 },
  plastic     = { takes("plastic", 5), 0.50, 2, 40, 0.07 },
  tyre        = { takes("tyre", 5), 0.60, 3, 60, 0.06 },
  wood_light  = { kenney("impactWood_light", 0, 4), 0.50, 2, 40, 0.05 },
  wood_heavy  = { kenney("impactWood_heavy", 0, 4), 0.75, 3, 80, 0.05 },
  zap         = { takes("zap", 5), 0.30, 2, 30, 0.08 },
  fire_flare  = { { IM .. "fire_flare.ogg" }, 0.70, 3, 60, 0.05 },
  breach      = { takes("breach", 2), 0.90, 4, 120, 0.05 },
  hiss        = { { F .. "hiss_short.ogg", F .. "hiss_cylinder.ogg" }, 0.50, 2, 30, 0.06 },
  relay       = { { F .. "latch_clunk.ogg", F .. "clamp_clunk.ogg" }, 0.70, 3, 40, 0.04 },
  step_grit   = { takes("step_grit", 6), 0.50, 3, 60, 0.05 },
  step_soil   = { takes("step_soil", 6), 0.50, 3, 60, 0.05 },
  step_sand   = { takes("step_sand", 6), 0.45, 3, 55, 0.05 },
  step_snow   = { takes("step_snow", 6), 0.45, 3, 55, 0.05 },
  step_metal  = { takes("step_metal", 6), 0.45, 3, 60, 0.04 },
  step_wood   = { kenney("footstep_wood", 0, 4), 0.50, 3, 60, 0.05 },
  step_grass  = { kenney("footstep_grass", 0, 4), 0.50, 3, 60, 0.05 },
  step_concrete = { kenney("footstep_concrete", 0, 4), 0.50, 3, 60, 0.05 },
}

-- What the ground is made of → (surface for a foot, class for an impact).
local ROCKY = { regolith = 1, gravel = 1, rustrock = 1, basalt = 1, slate = 1, granite = 1, onyx = 1,
  veinstone = 1, magma = 1, crystal = 1, shale = 1, hematite = 1, limestone = 1, sandstone = 1,
  sulfur = 1, obsidian = 1 }
local SANDY = { sand = 1, ash = 1, salt = 1 }
local SOFT = { soil = 1, clay = 1 }
local ICY = { ice = 1, ammonia_ice = 1, clathrate = 1 }
function groundOf(mat)
  if SOFT[mat] then return "soil", "soil" end
  if SANDY[mat] then return "sand", "sand" end
  if ICY[mat] then return "snow", "ice" end
  return "grit", "rock"                      -- the rock and regolith of most worlds
end
-- The palette slot under a world point → its material name (nil: no terrain).
function materialAt(x, y, z)
  if not (terrain and terrain.slotAt and x) then return nil end
  local ok, s = pcall(terrain.slotAt, x, y, z)
  if not ok or type(s) ~= "number" or s <= 0 or s == 255 then return "regolith" end
  local m = ref("materials")
  return (m and m.ofSlot and m.ofSlot(s)) or "regolith"
end
-- The ground at a world point, as a foot hears it: "grit" | "soil" | "sand" | "snow".
function surfaceAt(x, y, z)
  local s = groundOf(materialAt(x, y, z) or "regolith")
  return s
end

-- An impact's two materials → a bank, by energy (J): light, medium, heavy.
-- Order does not matter. Unknown materials read as metal (most things built).
local NORM = { terrain = "rock", ground = "rock", sand = "soil", snow = "soil", ice = "rock",
  crew = "suit", body = "suit", rubber = "tyre", steel = "metal", aluminium = "metal", hull = "metal",
  timber = "wood", stone = "rock", dirt = "soil" }
local function norm(m) m = m or "metal"; return NORM[m] or m end
local KNOWN = { metal = 1, rock = 1, soil = 1, glass = 1, plastic = 1, wood = 1, suit = 1, tyre = 1 }
local FAMILY = {
  -- family → { light, medium, heavy } banks
  glass       = { "glass_knock", "glass_break", "glass_break" },
  suit_hard   = { "metal_light", "suit_fall", "suit_fall" },
  suit        = { "soil_light", "suit_fall", "suit_fall" },
  tyre        = { "tyre", "tyre", "tyre" },
  plastic     = { "plastic", "plastic", "plastic" },
  wood        = { "wood_light", "wood_heavy", "wood_heavy" },
  metal_metal = { "metal_light", "metal_metal", "metal_heavy" },
  metal_rock  = { "metal_light", "metal_rock", "metal_heavy" },
  metal_soil  = { "metal_light", "metal_dull", "metal_dull" },
  rock_rock   = { "rock_light", "rock_soil", "rock_heavy" },
  rock_soil   = { "rock_light", "rock_soil", "rock_heavy" },
  soil        = { "soil_light", "soil_heavy", "soil_heavy" },
}
function familyOf(a, b)
  a, b = norm(a), norm(b)
  if not KNOWN[a] then a = "metal" end
  if not KNOWN[b] then b = "metal" end
  local has = function(m) return a == m or b == m end
  if has("glass") then return "glass" end
  if has("suit") then return (has("metal") or has("plastic") or has("wood") or a == b) and "suit_hard" or "suit" end
  if has("tyre") then return "tyre" end
  if has("plastic") then return "plastic" end
  if has("wood") then return "wood" end
  if a == "metal" and b == "metal" then return "metal_metal" end
  if has("metal") then return has("rock") and "metal_rock" or "metal_soil" end
  if has("rock") then return (a == b) and "rock_rock" or "rock_soil" end
  return "soil"
end
-- Energy tiers (J): a crew member stepping off a ledge (100 kg at 3 m/s) is
-- 450 J, a rover bouncing (2 t at 4 m/s) 16 kJ, a lander coming down hard
-- (6 t at 12 m/s) 430 kJ.
-- Glass gives way long before a hull notices (a visor, a window: 50 J).
TIER_J = { 3000, 120000 }
FAMILY_J = { glass = { 50, 2000 } }
function tierOf(speed, mass, fam)
  local e = 0.5 * math.max(1, mass or 100) * (speed or 0) ^ 2
  local J = (fam and FAMILY_J[fam]) or TIER_J
  return (e < J[1] and 1) or (e < J[2] and 2) or 3, e
end
function bankFor(a, b, speed, mass)
  local fam = familyOf(a, b)
  local tier, e = tierOf(speed, mass, fam)
  return FAMILY[fam][tier], fam, tier, e
end

-- Published for probes and tests: the last sounds picked, newest last.
history = {}
sfxLog = false
local HISTORY_N = 48
local bank_last = {}
local bank_t = {}

-- Play one take of `bank` at `where` (a node, or x,y,z): never the take it
-- played last, the volume and pitch jittered. `o`: vol (×), pitch (×), event
-- (the name history and the log give it), maxd (×), lowpass, gap (s: the
-- shortest time between two of this bank, default 0.05).
function playBank(bank, node, x, y, z, o)
  local B = BANKS[bank]
  if not B then return nil end
  o = o or {}
  local now = time or 0
  if bank_t[bank] and now - bank_t[bank] < (o.gap or 0.05) then return nil end
  bank_t[bank] = now
  local list = B[1]
  local i = math.random(1, #list)
  if #list > 1 and i == bank_last[bank] then i = i % #list + 1 end
  bank_last[bank] = i
  local clip = list[i]
  count(bank)
  local ev = o.event or bank
  history[#history + 1] = { t = now, event = ev, bank = bank, clip = clip }
  while #history > HISTORY_N do table.remove(history, 1) end
  if sfxLog and log then log(string.format("SFX %s %s %s", ev, bank, clip)) end
  if not (audio and audio.play) then return clip end
  local j = B[5] or 0.05
  local opts = { track = "SFX", volume = math.min(1.0, B[2] * (o.vol or 1.0) * (0.9 + math.random() * 0.2)),
                 pitch = (o.pitch or 1.0) * (1 - j + math.random() * 2 * j),
                 mode = "Spatial", falloff = "Inverse",
                 minDistance = B[3], maxDistance = B[4] * (o.maxd or 1.0), lowpass = o.lowpass }
  if node and node.valid ~= false then pcall(audio.play, clip, node, opts)
  elseif x then pcall(audio.play, clip, x, y, z, opts)
  else
    opts.mode, opts.minDistance, opts.maxDistance = "Flat", nil, nil
    pcall(audio.play, clip, opts)
  end
  return clip
end

-- An impact. `s`: a, b (materials; "terrain" asks the ground at the point),
-- speed (m/s, closing), mass (kg), node or x,y,z, vol (×), event (a name for
-- the log). → the bank it played. Louder and lower the more energy it carried;
-- past a megajoule a crash rides on top.
function impact(s)
  if type(s) ~= "table" then return nil end
  local a, b = s.a, s.b
  if (a == "terrain" or b == "terrain") and s.x then
    local _, cls = groundOf(materialAt(s.x, s.y, s.z) or "regolith")
    if a == "terrain" then a = cls end
    if b == "terrain" then b = cls end
  end
  local bank, fam, tier, e = bankFor(a, b, s.speed, s.mass)
  local m = math.max(1, s.mass or 100)
  local lg = math.log(math.max(e, 10)) / math.log(10)            -- log10 J: 2 (a tap) .. 7 (a crash)
  local vol = math.max(0.25, math.min(1.0, 0.25 + 0.15 * (lg - 2))) * (s.vol or 1.0)
  local pitch = math.max(0.72, math.min(1.18, 1.10 - 0.06 * (math.log(m / 100) / math.log(10))))
  local maxd = 0.7 + 0.3 * tier
  local o = { vol = vol, pitch = pitch, maxd = maxd, event = s.event or ("impact " .. fam), gap = s.gap }
  playBank(bank, s.node, s.x, s.y, s.z, o)
  if e > 1e6 and tier == 3 and fam ~= "soil" and fam ~= "suit" then
    playBank("crash", s.node, s.x, s.y, s.z, { vol = vol, pitch = pitch, event = o.event })
  end
  return bank
end

-- Failures and alarms: each its own sound, never a dropped can.
--   part_break   a part giving way (metal bending, tearing, crunching)
--   explode      an explosive part going off (a real blast, a close bang on it)
--   crash        the whole airframe failing
--   scrape       a part grinding along the ground
--   short        a torn part shorting out (an electric arc)
--   battery_fire a battery or cell catching fire (a flare of flame and an arc)
--   hull_breach  a pressure hull bursting (a plate going, a blast of air)
--   suit_damage  the suit or visor taking a hit (a crack and a hiss)
--   breaker_trip a breaker opening under fault (a heavy clack and a snap)
--   scram        a reactor's protection dropping the rods (the big contactor)
FAIL = {
  part_break   = { { "part_break", 1.0 }, { "metal_rock", 0.55 } },
  explode      = { { "explode", 1.0 }, { "blast", 0.8 } },
  crash        = { { "crash", 1.0 }, { "metal_heavy", 0.9 } },
  scrape       = { { "scrape", 1.0 } },
  short        = { { "zap", 1.0 } },
  battery_fire = { { "fire_flare", 1.0 }, { "zap", 0.8 } },
  hull_breach  = { { "breach", 1.0 }, { "hiss", 0.9 } },
  suit_damage  = { { "visor_crack", 1.0 }, { "hiss", 0.6 } },
  breaker_trip = { { "relay", 0.9 }, { "zap", 0.5 } },
  scram        = { { "relay", 1.0 } },
}
-- `s`: node or x,y,z, vol (×), pitch (×). → the first bank played.
function fail(kind, s)
  local L = FAIL[kind]
  if not L then return nil end
  s = s or {}
  local first = nil
  for _, layer in ipairs(L) do
    local clip = playBank(layer[1], s.node, s.x, s.y, s.z,
      { vol = layer[2] * (s.vol or 1.0), pitch = s.pitch, event = kind, gap = s.gap, maxd = s.maxd })
    first = first or (clip and layer[1])
  end
  return first
end

-- A footstep on `surface` ("grit" | "soil" | "sand" | "snow" | "metal" |
-- "wood" | "grass" | "concrete"), following `node`.
function step(surface, node, vol, maxd)
  local bank = "step_" .. (surface or "grit")
  if not BANKS[bank] then bank = "step_grit" end
  return playBank(bank, node, nil, nil, nil, { vol = vol, maxd = maxd, event = "step " .. (surface or "grit"), gap = 0.12 })
end

-- flight_ops, after a flight actually ended: which of the three ways out.
function flightEnded(how)
  if how == "recover" then play("recover")
  elseif how == "pickup" then play("pickup")
  else play("leave") end
end

-- vessel_controller, the moment the pod is gone. The sting, a caption for a
-- player with the sound off, the music getting out of the way, and the words in
-- the middle of the screen. Only for the craft you were flying: a wreck nobody
-- was in (a parked craft, a spent stage) breaking up is not this moment.
function vesselLost(was_piloting, craft)
  if was_piloting == false then return end
  play("lost")
  if caption then caption("the vessel is lost") end
  local ss = ref("soundscape")
  if ss and ss.hush then ss.hush(12.0) end
  local bc = ref("big_caption")
  if bc and bc.show then
    bc.show("VESSEL LOST", (craft and craft ~= "" and craft ~= "Vessel")
      and (craft .. " is gone. You walked away from it.") or "The craft is gone. You walked away from it.",
      5.0, "alarm")
  end
end

-- ── heard ───────────────────────────────────────────────────────────────────

-- The objectives card changing its step is the game saying "that worked, here
-- is what's next" — worth a soft chime. Watched from here rather than rung from
-- inside the card so the card stays a pure read of the world's state.
local step_seen = nil
local step_ready_at = nil

-- Each watched thing's last state; nil = not seen yet, so the first frame of a
-- scene (a panel that starts open, a crew that loads in the sea) is not news.
local seen = {}
local function edge(key, now_v)
  local was = seen[key]
  seen[key] = now_v
  if was == nil then return nil end
  if was ~= now_v then return now_v end
  return nil
end

-- Swimming: a stroke each time the arms come round, and bubbles under water.
local stroke_t, bubble_t = 0.0, 0.0

local DOWN = { recover = true, leave = true, pickup = true }
-- the flight card's debounce: seconds down, seconds flying, may it sound
local card_t = { down = 0, fly = 0, armed = false }

local function listen(dt)
  -- Only where there is a crew to be heard: in the main menu and the builder
  -- none of these scripts exist, and asking for each would put a "found
  -- nothing" line in the Console per name. `find` is O(1) and silent.
  if not (find and find("Astronaut")) then return end
  local pm = ref("pause_menu")
  if pm then
    local e = edge("pause", pm.open == true)
    if e == true then play("pause_open") elseif e == false then play("pause_close") end
  end
  local ip = ref("inventory_panel")
  if ip then
    local e = edge("bag", ip.open == true)
    if e == true then play("bag_open") elseif e == false then play("bag_close") end
  end
  local om = ref("orbit_map")
  if om and om.isOpen then
    local e = edge("map", om.isOpen() == true)
    if e == true then play("map_open") elseif e == false then play("map_close") end
  end
  local fo = ref("flight_ops")
  if fo then
    -- The card coming UP: down and stopped after a real flight. Not recover ↔
    -- leave as you drift past the base's edge (the same card changing its
    -- mind), and not a rover creeping to a stop: flight_ops' mode flickers
    -- flying ↔ recover at walking pace, and on each flicker the card's chirp
    -- rang — 20 times in 15 s at the end of a probe drive. So the card is
    -- heard once it has been down for a second, and again only after the
    -- craft has really flown (3 s on the move) since.
    if DOWN[fo.mode or "none"] then
      card_t.fly = 0
      card_t.down = card_t.down + dt
      if card_t.armed and card_t.down >= 1.0 then play("card"); card_t.armed = false end
    elseif fo.mode == "flying" then
      card_t.down = 0
      card_t.fly = card_t.fly + dt
      if card_t.fly >= 3.0 then card_t.armed = true end
    else
      card_t.down, card_t.fly = 0, 0   -- on foot, on the pad: no flight to end
    end
  end

  local wk = ref("planet_walker")
  if not wk then return end
  local swim = wk.swimming == true
  local e = edge("swim", swim)
  local astro = wk.node
  if e == true and wk.onFoot then
    -- Wading or sliding in. A fall into the sea is ocean.lua's splash; this is
    -- the quiet one for walking in, so only when the crew is not dropping.
    local vr = 0
    if astro and astro.valid ~= false then
      local up_x, up_y, up_z = astro.up_x or 0, astro.up_y or 1, astro.up_z or 0
      vr = (astro.vx or 0) * up_x + (astro.vy or 0) * up_y + (astro.vz or 0) * up_z
    end
    if vr > -2.0 then playAt("wade", astro, 1.0) end
    stroke_t, bubble_t = 0.4, 2.5
  end
  if swim and wk.onFoot then
    local ss = wk.swimState or {}
    local v = math.abs(ss.vf or 0) + math.abs(ss.vs or 0) + math.abs(ss.vu or 0)
    if v > 0.35 then
      -- One stroke per cycle: quicker strokes when swimming harder, the same
      -- range the swim layers' own clocks run at.
      stroke_t = stroke_t - dt
      if stroke_t <= 0 then
        local under = ss.under == true
        playAt("stroke", astro, under and 0.6 or 1.0, under and { lowpass = 900 } or nil)
        stroke_t = math.max(0.55, 1.35 - v * 0.22) * (0.9 + math.random() * 0.2)
      end
    else
      stroke_t = math.min(stroke_t, 0.3)
    end
    if ss.under then
      bubble_t = bubble_t - dt
      if bubble_t <= 0 then
        playAt("bubbles", astro, 1.0, { lowpass = 2200 })
        bubble_t = 2.5 + math.random() * 3.5
      end
    end
  end
end

function start(node)
  local list = {}
  for _, c in pairs(CLIPS) do list[#list + 1] = c[1] end
  for _, w in pairs(WORLD) do for _, c in ipairs(w[1]) do list[#list + 1] = c end end
  -- the banks heard every few seconds; the rare ones (a crash, a breach) load
  -- on their first play, a frame late
  for _, b in ipairs({ "step_grit", "step_soil", "step_sand", "step_snow", "step_metal",
                       "metal_light", "soil_light", "tyre", "zap" }) do
    for _, c in ipairs(BANKS[b][1]) do list[#list + 1] = c end
  end
  if audio and audio.preload then audio.preload(list) end
end

-- Resolved once and kept: `findScript` walks the whole scene (floptle/0063).
local ob_ref = nil

function update(node, dt)
  listen(dt or 0)
  if not ob_ref or not ob_ref.valid then ob_ref = findScript("objectives") end
  local ob = ob_ref
  if not ob then return end
  local h = ob.headline
  if type(h) ~= "string" or h == "" then return end
  -- The first step after a load is not news, and neither is the first few
  -- seconds of a world settling (the siting step clears itself).
  if step_seen == nil then
    step_seen, step_ready_at = h, (time or 0) + 3.0
    return
  end
  if h ~= step_seen then
    step_seen = h
    if (time or 0) >= step_ready_at then play("chime") end
  end
end
