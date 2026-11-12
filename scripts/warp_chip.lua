-- WARP CHIP — time warp on foot, the warp rate while walking, and why a warp
-- was refused or dropped, wherever you are.
--
-- Playtest 2026-10-27: "I park and warp to get a time of day or a weather,
-- and nothing shows the warp on foot; I can't warp at all out of the craft."
--
--   ON FOOT   . and , step the same ladder the craft uses (1 5 10 50 100
--             1000 10000) when the crew stands still on the ground and is
--             safe: not falling, swimming, floating, on EVA in space, down,
--             short of air or under fire. Walking (W A S D, jump), or any of
--             those becoming true, drops it to ×1 and says why.
--   THE CHIP  while warping on foot: "WARP ▸▸▸ ×100", top centre, the flight
--             console's warp placard in the same style.
--   NOTICES   say(msg): one line under the chip (on foot) or over the flight
--             console (flying) for a few seconds. vessel_controller's
--             warpSay() and this script's refusals use it, so a warp is never
--             refused or dropped silently.
--
-- The rails do the rest: a body standing on the ground stays on realtime
-- physics through a warp and rides its planet's frame (the engine's landed
-- rule), so nothing moves under the crew. The galaxy's ceiling (galaxy.lua
-- maxWarp) applies on foot too; on a planet it is infinite.
--
-- Pure (luajit): footBlock(state, alerts, injure) → reason | nil,
--                stepWarp(warp, dir, cap) → next rung, ladderIndex(warp)

LADDER = { 1, 5, 10, 50, 100, 1000, 10000 }
NOTICE_SECS = 3.5
START_SPEED = 0.6    -- m/s over the ground: standing still, to start a warp
HOLD_SPEED = 2.5     -- m/s: moving faster than this drops it (a stumble isn't a walk)
AIR_GRACE = 0.35     -- s off the ground before a warp drops (a step down, a bump)

-- Published for probes: the last refusal/drop reason, and the chip's state.
lastNotice = nil
foot = { warp = 1, block = nil, shown = false }

local function ref_cache()
  local refs = {}
  return function(kind)
    local r = refs[kind]
    if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
    return r
  end
end
local ref = ref_cache()

-- ── pure ────────────────────────────────────────────────────────────────────

function ladderIndex(w)
  local idx = 1
  for i, s in ipairs(LADDER) do if (w or 1) >= s - 0.5 then idx = i end end
  return idx
end

-- The next rung `dir` (+1 / -1) from `warp`, never above `cap`.
function stepWarp(warp, dir, cap)
  local i = math.max(1, math.min(#LADDER, ladderIndex(warp) + dir))
  local nxt = LADDER[i]
  if dir > 0 and nxt > (cap or math.huge) + 0.001 then return warp, "cap" end
  return nxt, nil
end

-- Why the crew may NOT warp on foot right now, or nil when they may.
--   s: onFoot, grounded, swimming, headUnder, floating, inSpace, downed,
--      speed (m/s over the ground), speedMax (the threshold to use)
--   a: crew.alerts(id) or nil;  injure: crew.params.impact_injure (m/s)
function footBlock(s, a, injure)
  if not s.onFoot then return "not on foot" end
  if s.inSpace then return "on EVA in space" end
  if s.swimming or s.headUnder then return "swimming" end
  if s.downed then return "blacked out" end
  if s.floating or not s.grounded then return "not on the ground" end
  if (s.speed or 0) > (s.speedMax or START_SPEED) then return "moving" end
  if a and not a.safe then
    if a.blackout or a.downed then return "you are down" end
    if a.down and not a.down.treated then return "crew down nearby" end
    if a.pinned then return "pinned" end
    if a.hit then return "under fire" end
    if (a.fall or 0) >= (injure or 9) then return "falling" end
    if (a.heat or 0) >= 0.2 then return "overheating" end
    if (a.breath or 1) < 0.999 then return "holding your breath" end
    local lv = a.o2_level
    if lv == nil and a.air_s and a.air_s <= 60 then lv = "min" end
    if lv == nil and (a.o2 or 1) <= 0.10 then lv = "crit" end
    if lv == "crit" or lv == "min" then return "low on air" end
  end
  return nil
end

-- ── said on screen ──────────────────────────────────────────────────────────

local notice_t, notice_msg = -1e9, nil
local said = false   -- a notice came in since the last frame (a drop with its reason)
local clock = 0.0

function say(msg)
  if type(msg) ~= "string" or msg == "" then return end
  notice_msg, notice_t = msg, clock
  lastNotice = msg
  said = true
end

-- ── driver ──────────────────────────────────────────────────────────────────

local el
local air_t = 0.0
local drawn = false

function start(node)
  el = node.getcomponent and node:getcomponent("UiElement") or nil
end

local function piloted()
  for _, v in ipairs(findScripts and findScripts("vessel_controller") or {}) do
    if v.piloting then return v end
  end
  return nil
end

local function typing()
  local ts = ref("tracking_station")
  if ts and ts.typing and ts.typing() then return true end
  if not (ui and ui.focused) then return false end
  local f = ui.focused()
  return f ~= nil and type(f.name) == "string" and f.name:find("^Field") ~= nil
end
-- Is a name or a search being typed? (. and , are letters then, not warp keys.)
function typingNow() return typing() end

local function galaxy_cap()
  local gx = ref("galaxy")
  if not gx then return math.huge, nil end
  local ok, lim = pcall(gx.maxWarp)
  if not (ok and type(lim) == "number") then return math.huge, nil end
  local ok2, why = pcall(gx.warpNote)
  return lim, (ok2 and type(why) == "string") and why or nil
end

-- The crew's state for footBlock, read from the walker, the pack and crew.
local function foot_state(pw, speed_max)
  local a = find and find("Astronaut")
  local sp = 0
  if a and a.valid then sp = math.sqrt((a.vx or 0) ^ 2 + (a.vy or 0) ^ 2 + (a.vz or 0) ^ 2) end
  local ep = ref("eva_pack")
  local s = {
    onFoot = pw.onFoot == true, grounded = pw.grounded == true or air_t < AIR_GRACE,
    swimming = pw.swimming == true, headUnder = pw.headUnder == true,
    floating = pw.floating == true, downed = pw.downed == true,
    inSpace = ep ~= nil and ep.inSpaceNow == true,
    speed = sp, speedMax = speed_max,
  }
  local C = ref("crew")
  local al, inj = nil, nil
  if C and C.alerts then
    local ok, r = pcall(C.alerts)
    if ok then al = r end
    inj = C.params and C.params.impact_injure or nil
  end
  return s, al, inj
end

local MOVE_KEYS = { "w", "a", "s", "d", "space" }

local function foot_tick(pw, dt)
  local warp = space.warp() or 1
  air_t = (pw.grounded == true) and 0.0 or (air_t + dt)
  local cap, why = galaxy_cap()
  -- the galaxy's ceiling fell under us (rare on a planet: it is infinite there)
  if warp > cap + 0.001 then
    local down = 1
    for _, w in ipairs(LADDER) do if w <= cap + 0.001 then down = w end end
    if down < warp then
      space.warp(down)
      say(string.format("Warp ×%d · %s", down, why or "limited out here"))
      warp = down
    end
  end
  -- (playtest 11-11: "can't time warp when accessing computers") a console's
  -- terminal holds the keyboard (input_guard), so its . and , are read raw:
  -- the warp works with the screen up, and the screen stays live
  local tm = ref("terminal")
  local term = tm ~= nil and tm.isOpen ~= nil and tm.isOpen() == true
  local function pr(k)
    if term and input.rawPressed then return input.rawPressed(k) == true end
    return input.pressed(k) == true
  end
  if not typing() and (pr(".") or pr(",")) then
    local dir = pr(".") and 1 or -1
    local nxt, capped = stepWarp(warp, dir, cap)
    if capped then
      say(why and ("Warp limited · " .. why) or string.format("Warp limited to ×%d out here", math.floor(cap)))
    elseif nxt > warp then
      -- the one warp gate (request below): footBlock, said when it refuses
      if request(nxt) then warp = nxt end
      nxt = warp
    end
    if nxt ~= warp then
      space.warp(nxt)
      warp = nxt
    end
  end
  if warp > 1.001 then
    local moved = false
    for _, k in ipairs(MOVE_KEYS) do if input.key(k) then moved = true break end end
    local block = moved and "walking" or nil
    if not block then
      local s, al, inj = foot_state(pw, HOLD_SPEED)
      block = footBlock(s, al, inj)
    end
    if block then
      space.warp(1)
      warp = 1
      say("Warp ×1 · " .. block)
    end
  end
  foot.warp = warp
  return warp
end

-- The placard: one chevron per rung, lit up to where you are, and the rate.
-- (flight_hud.warp_pill's look, on its own.)
local ACCENT = { 0.97, 0.55, 0.22 }
local DIM = { 0.56, 0.55, 0.50 }
local function chip(w, cap)
  local idx = ladderIndex(w)
  local kids = {}
  for i = 2, #LADDER do
    local capped = LADDER[i] > (cap or math.huge) + 0.001
    kids[#kids + 1] = { "text", key = "c" .. i, w = 8, h = 14, text = "▸", textSize = 14,
      textAlign = "center", textValign = "center",
      textColor = i <= idx and ACCENT or (capped and { DIM[1], DIM[2], DIM[3], 0.18 }
        or { DIM[1], DIM[2], DIM[3], 0.55 }) }
  end
  kids[#kids + 1] = { "text", key = "x", style = "hud/valueAccent", w = 60, h = 14,
    text = string.format("×%d", math.floor(w + 0.5)), textAlign = "end", textValign = "center" }
  return { "row", key = "warp", style = "hud/warp", pin = "top", y = 60, w = "fit", h = 22,
           pad = 0, gap = 1, align = "center",
           { "box", key = "l", w = 6, h = 1 },
           { "text", key = "lbl", style = "hud/micro", w = 36, h = 12, text = "WARP", textAlign = "start" },
           { "row", key = "ch", w = "fit", h = 14, pad = 0, gap = 0, items = kids, function(k) return k end },
           { "box", key = "r", w = 8, h = 1 } }
end

local function notice_row(msg, pin, y, a)
  return { "row", key = "note", style = "hud/chipWarn", pin = pin, y = y, w = "fit", h = 26, pad = 6, gap = 0,
           align = "center", opacity = a,
           { "text", key = "t", style = "hud/chipWarnText", w = "fit", h = 18, text = msg } }
end

-- A drop nobody in the game asked for: the engine's own rule (a body or a
-- craft coasting near the ground, or a world's terrain still streaming in)
-- puts the warp to ×1 and tells only its debug console. Say that it happened.
local seen_warp = 1
local function watch_drop(w)
  if w < seen_warp - 0.001 and not said and not (input and input.pressed and input.pressed(",")) then
    say(w <= 1.001 and "Warp ×1 · stopped by the physics (something moving near the ground)"
      or string.format("Warp ×%d · stopped by the physics", math.floor(w + 0.5)))
  end
  seen_warp = w
  said = false
end

function update(node, dt)
  clock = clock + (dt or 0)
  if not el then el = node:getcomponent("UiElement") end
  local gm = ref("game_manager")
  local pw = ref("planet_walker")
  local pm = ref("pause_menu")
  local busy = (gm and (gm.loading or gm.curtain or gm.inputOwner == "builder")) or (pm and pm.open)
  local flying = piloted()
  local on_foot = pw ~= nil and pw.onFoot == true and not flying and not busy
  local w = space and space.warp and space.warp() or 1
  watch_drop(w)
  if warping and WARP_TO_TICK then WARP_TO_TICK(dt or 0) end
  if on_foot and space and space.warp then w = foot_tick(pw, dt or 0); seen_warp = w end
  foot.shown = false
  local pc = ref("planet_camera")
  local hidden = busy or (pc and (pc.cinematic or pc.freecam))
  local age = clock - notice_t
  local tree = { "box", key = "root", pin = "center", w = "100%", h = "100%" }
  local any = false
  if not hidden and on_foot and w > 1.001 then
    tree[#tree + 1] = chip(w, (galaxy_cap()))
    foot.shown, any = true, true
  end
  if not hidden and notice_msg and age < NOTICE_SECS then
    local a = age > NOTICE_SECS - 0.6 and math.max(0, (NOTICE_SECS - age) / 0.6) or 1.0
    if flying then
      local fh = ref("flight_hud")
      local rise = fh and fh.layout and fh.layout.consoleRise or 200
      tree[#tree + 1] = notice_row(notice_msg, "bottom", -(rise + 10), a)
    else
      tree[#tree + 1] = notice_row(notice_msg, "top", on_foot and w > 1.001 and 88 or 60, a)
    end
    any = true
  end
  if not el then return end
  if not any then
    if drawn then ui.make(node, {}); drawn = false end
    if el.visible then el.visible = false end
    return
  end
  if not el.visible then el.visible = true end
  ui.make(node, tree)
  drawn = true
end

-- ── THE ONE WARP GATE ───────────────────────────────────────────────────────
-- Every request to warp faster goes through request(w): the flight console's
-- , . keys (vessel_controller), the same keys on foot (foot_tick above), the
-- Tracking Station's rungs and its warp to the next event (warpTo below).
-- The refusals — the galaxy's ceiling, the throttle, EVA in space, the 40 m
-- rule, footBlock on foot — are said with say() so a key or a rung that does
-- nothing says why. Going DOWN is never refused. → ok, why.
function capNow() return (galaxy_cap()) end
function request(w)
  if not (space and space.warp) then return false, "no warp here" end
  local cur = space.warp() or 1
  w = math.max(1, w or 1)
  if w <= cur + 0.001 then space.warp(w) return true end
  local cap, why = galaxy_cap()
  local function no(text) say("Warp limited · " .. text) return false, "Warp limited · " .. text end
  if w > cap + 0.001 then return no(why or string.format("×%d out here", math.floor(cap))) end
  local vc = piloted()
  if vc then
    if (vc.throttle or 0) > 0.01 then return no("cut the throttle first") end
    local ok, eva = pcall(function() return vc.evaBlocksWarp and vc.evaBlocksWarp() end)
    if ok and eva then return no("crew on EVA in space") end
    local info = assembly and assembly.info and vc.node and assembly.info(vc.node)
    if vc.warpAltOk then
      local oka, alt_ok = pcall(vc.warpAltOk)
      if oka and alt_ok == false then return no("too low to coast (under 40 m)") end
    elseif info and not (info.grounded or info.anchored) and info.origin then
      local o = info.origin
      local d = space.dominant(o.x, o.y, o.z)
      local b = d and space.body(d)
      if b and math.sqrt((o.x - b.x) ^ 2 + (o.y - b.y) ^ 2 + (o.z - b.z) ^ 2) - b.radius <= 40.0 then
        return no("too low to coast (under 40 m)")
      end
    end
  else
    local pw = ref("planet_walker")
    if not (pw and pw.onFoot) then return no("nobody to warp") end
    local s, al, inj = foot_state(pw, cur > 1.001 and HOLD_SPEED or START_SPEED)
    local block = footBlock(s, al, inj)
    if block then return no(block) end
  end
  space.warp(w)
  return true
end

-- ── WARP TO A TIME (the Tracking Station's TO NEXT EVENT) ──────────────────
-- orbit_map.warpToNode's landing rule, generalised: up the ladder through the
-- gate above, then back down as the time comes, to land WARP_LEAD game
-- seconds before it. Any drop nobody here asked for (the , key, the stick, a
-- refusal, the physics) ends it: the warp is theirs then. Game time
-- (space.time), so it holds at any rung.
WARP_LEAD = 10.0     -- s of game time left when it lands
WARP_REAL = 0.5      -- s of REAL time a rung must still have to stay on it
warping = nil        -- { t, label, set, last } while it runs (published)

-- The rung to sit on with `remaining` game seconds to go: the highest one
-- (under `cap`) that still has more than WARP_REAL real seconds (and four
-- frames) at it. 1 = arrived. Pure (orbit_map's MNV.warpStep, same rule).
function warpStep(remaining, cap, dt)
  local best = 1
  local real = math.max(WARP_REAL, 4 * (dt or 0))
  for _, w in ipairs(LADDER) do
    if w <= (cap or math.huge) + 0.001 and remaining > w * real and w > best then best = w end
  end
  return best
end

-- Start: warp until `t` (game time) less WARP_LEAD. → ok, why.
function warpTo(t, label)
  if not (space and space.time and space.warp) then return false, "no warp here" end
  label = label or "the event"
  local left = (t or 0) - WARP_LEAD - space.time()
  if left < 1.0 then
    say(string.format("Warp to %s · it is under %d s away", label, math.floor(WARP_LEAD)))
    return false, "it is under " .. math.floor(WARP_LEAD) .. " s away"
  end
  local w = warpStep(left, capNow(), 1 / 60)
  if w <= 1 then return false, "it is too close to warp to" end
  local ok, why = request(w)
  if not ok then return false, why end
  warping = { t = t, label = label, set = w, last = nil }
  say(string.format("Warp to %s · ×%d", label, w))
  return true
end

function warpCancel(why)
  if not warping then return end
  local W = warping
  warping = nil
  if space.warp() > 1.001 then space.warp(1) end
  say(string.format("Warp to %s · %s", W.label, why or "stopped"))
end

-- Each frame (update): step the ladder down as the time comes.
local function warp_to_tick(dt)
  local W = warping
  if not W then return end
  local cur = space.warp() or 1
  -- dropped by someone else: a fall we did not ask for ends it
  if W.last and cur < W.last - 0.001 and W.set >= W.last - 0.001 then
    warping = nil
    say(string.format("Warp to %s · stopped", W.label))
    return
  end
  W.last = cur
  -- (our own steps down are not "stopped by the physics": watch_drop)
  said = true
  local left = W.t - WARP_LEAD - space.time()
  local w = warpStep(left, capNow(), dt)
  if w <= 1 then
    warping = nil
    if cur > 1.001 then space.warp(1) end
    say(string.format("Warp ×1 · %s in %.0f s", W.label, math.max(0, W.t - space.time())))
    return
  end
  if math.abs(w - W.set) > 0.001 then
    if w < cur then space.warp(w) else request(w) end
    W.set = w
  end
end
WARP_TO_TICK = warp_to_tick
