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
--   * INTERFACE — Kenney CC0 clips on the UI bus, kept QUIET. These are
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
--     if s then s.playAt("jump", node) end         -- planet_walker, the jump
--     if s then s.flightEnded("recover") end       -- flight_ops, it worked
--     if s then s.vesselLost(piloting, name) end   -- vessel_controller
--
-- Callers always allow for a nil handle: a harness (or a scene) with no sfx
-- node is a silent game, not a broken one.

local I = "audio/kenney/interface/"
local K = "audio/kenney/impact/"

-- key → { clip, volume }  (flat, UI bus)
local CLIPS = {
  click  = { I .. "click_002.ogg",        0.45 },
  open   = { I .. "open_002.ogg",         0.40 },
  close  = { I .. "close_002.ogg",        0.35 },
  cash   = { I .. "confirmation_002.ogg", 0.45 },
  jingle = { I .. "confirmation_004.ogg", 0.60 },
  sign   = { I .. "select_003.ogg",       0.50 },
  chime  = { I .. "glass_002.ogg",        0.30 },
  arm    = { I .. "question_001.ogg",     0.40 },
  denied = { I .. "error_003.ogg",        0.35 },
  -- The pause menu: the world stopping, and starting again.
  pause_open  = { I .. "maximize_002.ogg", 0.32 },
  pause_close = { I .. "minimize_002.ogg", 0.28 },
  -- The suit pack. Its own pair, so the bag doesn't sound like a building.
  bag_open  = { I .. "open_001.ogg",  0.36 },
  bag_close = { I .. "close_001.ogg", 0.30 },
  bag_move  = { I .. "drop_002.ogg",  0.42 },
  -- The orbit map: a softer, longer swell than a panel.
  map_open  = { I .. "maximize_006.ogg", 0.28 },
  map_close = { I .. "minimize_006.ogg", 0.24 },
  -- The flight card coming up, and the three ways out of it.
  card    = { I .. "question_002.ogg",     0.36 },
  recover = { I .. "confirmation_003.ogg", 0.55 },
  leave   = { I .. "back_002.ogg",         0.45 },
  pickup  = { I .. "confirmation_001.ogg", 0.50 },
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
      5.0)
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
    local m = fo.mode or "none"
    local was = seen.flight
    seen.flight = m
    -- The card coming UP: down and stopped, from flying (or from nothing — a
    -- craft that settles on the pad). Not recover ↔ leave as you drift past
    -- the base's edge, which is the same card changing its mind.
    if was and DOWN[m] and not DOWN[was] then play("card") end
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
