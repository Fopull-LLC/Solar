-- SFX — the interface's voice. Every panel, payout and contract in the game
-- used to happen in silence: money arrived as a number changing, a contract
-- signed as a row changing colour, and a panel opened with nothing to say it
-- had. The world had engines and footsteps; the company had nothing.
--
-- One small table of Kenney CC0 clips on the UI mixer bus, kept QUIET — these
-- are confirmations, not events, and a click louder than a footstep is a click
-- the player learns to hate.
--
--     local s = findScript("sfx")
--     if s then s.play("cash") end
--
-- Callers always allow for a nil handle: a harness (or a scene) with no sfx
-- node is a silent game, not a broken one.

-- key → { clip, volume }
local CLIPS = {
  click  = { "audio/kenney/interface/click_002.ogg",        0.45 },
  open   = { "audio/kenney/interface/open_002.ogg",         0.40 },
  close  = { "audio/kenney/interface/close_002.ogg",        0.35 },
  cash   = { "audio/kenney/interface/confirmation_002.ogg", 0.45 },
  jingle = { "audio/kenney/interface/confirmation_004.ogg", 0.60 },
  sign   = { "audio/kenney/interface/select_003.ogg",       0.50 },
  chime  = { "audio/kenney/interface/glass_002.ogg",        0.30 },
  arm    = { "audio/kenney/interface/question_001.ogg",     0.40 },
  denied = { "audio/kenney/interface/error_003.ogg",        0.35 },
}

-- A sale that also pays a discovery premium is two ledger entries in one
-- frame; two identical clicks stacked on top of each other just sound louder.
-- And a contract payout is its own jingle — the cash clink under it is noise.
local REPEAT = 0.12
local HUSH = { cash = "jingle", chime = "jingle" }   -- key → the clip that swallows it
local last = {}

function play(key, vol)
  local c = CLIPS[key]
  if not (c and audio and audio.play) then return end
  local now = time or 0
  if last[key] and now - last[key] < REPEAT then return end
  local over = HUSH[key]
  if over and last[over] and now - last[over] < 0.6 then return end
  last[key] = now
  audio.play(c[1], { track = "UI", volume = c[2] * (vol or 1.0) })
end

-- The objectives card changing its step is the game saying "that worked, here
-- is what's next" — worth a soft chime. Watched from here rather than rung from
-- inside the card so the card stays a pure read of the world's state.
local step_seen = nil
local step_ready_at = nil

function start(node)
  local list = {}
  for _, c in pairs(CLIPS) do list[#list + 1] = c[1] end
  if audio and audio.preload then audio.preload(list) end
end

-- Resolved once and kept: `findScript` walks the whole scene (floptle/0063).
local ob_ref = nil

function update(node, dt)
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
