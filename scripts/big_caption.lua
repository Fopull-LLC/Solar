-- BIG CAPTION — the few moments that deserve the middle of the screen.
--
-- Losing a vessel used to be one line in the log: the pod failed, the crew was
-- put down beside the wreck, and the game carried on as if a panel had closed.
-- It is the single biggest thing that can happen on a flight, and nothing on
-- screen said it had.
--
-- One title and one line under it, upper third, fading in and out. Drawn into
-- its own UI layer (the node this rides on), so it never shares a container
-- with a HUD script that reconciles its own children. A second `show` replaces
-- the first rather than stacking.
--
--   local bc = findScript("big_caption")
--   if bc then bc.show("VESSEL LOST", "The craft is gone.", 5) end
--
-- Under reduced motion it still fades — a fade is not motion — but does not
-- drift.

local title, sub = nil, nil
local shown_at, life = -1, 0
local clock = 0.0
local drawn = false

-- Published for probes: what is up right now, or nil.
current = nil

function show(t, s, secs)
  title, sub = t, s
  shown_at, life = clock, secs or 4.0
  current = t
end

function hide()
  life = 0
end

local FADE_IN, FADE_OUT = 0.35, 0.9

function update(node, dt)
  clock = clock + (dt or 0)
  local age = clock - shown_at
  if not title or age > life + FADE_OUT then
    if drawn then ui.make(node, {}); drawn = false end
    title, current = nil, nil
    return
  end
  local a = math.min(1, age / FADE_IN)
  if age > life then a = math.max(0, 1 - (age - life) / FADE_OUT) end
  local still = access and access.reducedMotion and access.reducedMotion()
  local lift = still and 0 or math.floor((1 - math.min(1, age / FADE_IN)) * 10)
  ui.make(node, {
    { "col", key = "big", pin = "top", y = 150 + lift, w = 680, h = "fit", pad = 18, gap = 6,
      align = "center", fill = { 0.03, 0.02, 0.025, 0.78 }, radius = 10, border = 1,
      borderColor = { 1.0, 0.42, 0.36, 0.55 }, opacity = a,
      { "text", key = "t", w = "100%", h = "fit", textAlign = "center", textSize = 40,
        tracking = 8, textColor = { 1.0, 0.50, 0.42 }, text = title },
      sub and { "text", key = "s", w = "100%", h = "fit", textAlign = "center", textSize = 15,
        wrap = true, textColor = { 0.86, 0.90, 0.93 }, text = sub } or nil,
    },
  })
  drawn = true
end
