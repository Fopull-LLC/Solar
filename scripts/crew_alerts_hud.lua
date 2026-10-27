-- CREW ALERTS HUD — the telegraphed warnings of docs/crew-and-items.md §2.3,
-- drawn from crew.alerts(id) (crew.lua owns the rules; this only shows them).
--
--   chips, top centre, for the member you control (on foot) or the crew at
--   the controls (flying):
--     O2 25%      amber, a chime once            O2 10%   red, the alarm every 10 s
--     O2 1 MIN    red, the alarm continuous, the screen rim pulses red
--     BREATH …    the same three steps under water (held breath)
--     HIT −43%    shot (crew.hurt): red for 1.6 s, a thud and two pips, the
--                 rim flashes red
--     HP 62%      injured (amber; red under 35%)
--     HEAT        from heat 0.2 (amber), the alarm from 0.6 (red)
--     FALL 12 m/s  airborne: amber past crew.impact_injure, red "FATAL FALL" near impact_kill
--     PINNED      a red vignette and the chip
--     CABIN FAILING · hold under 9 m/s   the crew part under 35%
--   BLACKOUT: the screen dims toward black over the grace, a heartbeat plays.
--   A DEATH: crew.lastDeath changes → a muted sting and, when it was the
--   member you control, planet_camera holds on the place for 2 s (crew.lua
--   shows the caption through big_caption).
--
-- Pure (luajit): chipsOf(alerts) → { {text, level} … }, soundsOf(prev, alerts)

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not (r and r.valid ~= false) then
    r = findScript and findScript(kind) or nil
    refs[kind] = r
  end
  return r
end

SND = {
  chime = "audio/sfx/crew_chime.ogg",
  alarm = "audio/sfx/crew_alarm.ogg",
  loop = "audio/sfx/crew_alarm_loop.ogg",
  heart = "audio/sfx/crew_heartbeat.ogg",
  sting = "audio/sfx/crew_sting.ogg",
  hit = "audio/sfx/crew_hit.ogg",
}
ALARM_EVERY = 10.0

local function pct(x) return math.floor((x or 0) * 100 + 0.5) end

-- The level of an air reserve: nil | "low" | "crit" | "min" (crew.airLevel).
function airLevel(frac, secs)
  if secs and secs <= 60 then return "min" end
  if (frac or 1) <= 0.10 then return "crit" end
  if (frac or 1) <= 0.25 then return "low" end
  return nil
end

-- The chips for one member's alerts: { {text, level = "warn"|"danger"} … }
function chipsOf(a)
  local out = {}
  if not a then return out end
  if a.hit then out[#out + 1] = { "HIT −" .. pct(a.hit.amount) .. "%", "danger" } end
  local lv = a.o2_level or airLevel(a.o2, a.air_s)
  if lv == "min" then out[#out + 1] = { "O2 1 MIN", "danger" }
  elseif lv == "crit" then out[#out + 1] = { "O2 " .. pct(a.o2) .. "%", "danger" }
  elseif lv == "low" then out[#out + 1] = { "O2 " .. pct(a.o2) .. "%", "warn" } end
  local bl = a.breath_level or ((a.breath or 1) < 1 and airLevel(a.breath, nil) or nil)
  if bl == "crit" or bl == "min" then out[#out + 1] = { "BREATH " .. pct(a.breath) .. "%", "danger" }
  elseif bl == "low" then out[#out + 1] = { "BREATH " .. pct(a.breath) .. "%", "warn" } end
  if (a.hp or 1) < 0.99 then out[#out + 1] = { "HP " .. pct(a.hp) .. "%", (a.hp or 1) < 0.35 and "danger" or "warn" } end
  if (a.heat or 0) >= 0.2 then out[#out + 1] = { "HEAT " .. pct(a.heat) .. "%", (a.heat or 0) >= 0.6 and "danger" or "warn" } end
  local f = a.fall or 0
  local cl = findScript and findScript("crew")
  local inj = cl and cl.params and cl.params.impact_injure or 9
  local kil = cl and cl.params and cl.params.impact_kill or 20
  if f >= kil * 0.9 then out[#out + 1] = { string.format("FATAL FALL %.0f m/s", f), "danger" }
  elseif f >= inj then out[#out + 1] = { string.format("FALL %.0f m/s", f), "warn" } end
  if a.pinned then out[#out + 1] = { "PINNED", "danger" } end
  if a.cabin and a.cabin < 0.35 then
    out[#out + 1] = { string.format("CABIN FAILING · hold under %.0f m/s", a.cabin_tol or 9), "warn" }
  end
  if a.blackout then out[#out + 1] = { string.format("BLACKOUT %.0f s", math.max(0, a.blackout)), "danger" } end
  -- someone DOWN nearby, bleeding out (crew.lua): who, how long, how far
  if a.down then
    local nm = (a.down.name or "CREW"):match("^(%S+)") or "CREW"
    out[#out + 1] = { string.format("%s DOWN · BLEEDING OUT %d s · %.0f m", nm:upper(),
      math.max(0, math.floor((a.down.left or 0) + 0.5)), a.down.dist or 0), a.down.treated and "warn" or "danger" }
  end
  return out
end

-- What to play this frame, from the last state `S` (mutated) and alerts `a`
-- at time t: → { one-shot keys… }, loop key | nil.
function soundsOf(S, a, t)
  local shots = {}
  if a and a.hit and a.hit.t ~= S.hit_t then
    S.hit_t = a.hit.t
    shots[#shots + 1] = "hit"
  end
  local lv = a and (a.o2_level or airLevel(a.o2, a.air_s)) or nil
  local bl = a and (a.breath_level or ((a.breath or 1) < 1 and airLevel(a.breath, nil) or nil)) or nil
  local worst = (lv == "min" or bl == "min") and "min" or ((lv == "crit" or bl == "crit") and "crit")
    or ((lv == "low" or bl == "low") and "low") or nil
  if worst == "low" and S.level == nil then shots[#shots + 1] = "chime" end
  local hot = a and (a.heat or 0) >= 0.6
  if (worst == "crit" or hot) and worst ~= "min" then
    if not S.alarm_t or t - S.alarm_t >= ALARM_EVERY or (S.level ~= "crit" and worst == "crit") then
      shots[#shots + 1] = "alarm"
      S.alarm_t = t
    end
  else
    S.alarm_t = nil
  end
  S.level = worst
  local loop = nil
  if a and a.blackout then loop = "heart"
  elseif worst == "min" then loop = "loop" end
  return shots, loop
end

-- ── runtime ────────────────────────────────────────────────────────────────
local el
local S = {}
local loop_key, loop_h = nil, nil
local death_t = nil
local dim = 0.0
hud = { chips = 0, dim = 0.0, loop = nil }   -- published for probes

local function play(key, opts)
  if not (audio and audio.play and SND[key]) then return nil end
  local ok, h = pcall(audio.play, SND[key], opts or { track = "UI", volume = 0.8 })
  return ok and h or nil
end

local function set_loop(key)
  if key == loop_key then return end
  if loop_h then pcall(function() loop_h:stop() end) end
  loop_h, loop_key = nil, key
  if key then loop_h = play(key, { track = "UI", volume = key == "heart" and 0.9 or 0.55, loop = true }) end
  hud.loop = key
end

local function who()
  local C = ref("crew")
  if not C then return nil end
  for _, v in ipairs(findScripts and findScripts("vessel_controller") or {}) do
    if v.piloting and v.node and v.node.valid ~= false then
      local cmd = v.commander and v.commander()
      return cmd or (C.activeId and C.activeId()), v
    end
  end
  return C.activeId and C.activeId(), nil
end

function start(node)
  el = node.getcomponent and node:getcomponent("UiElement") or nil
end

local function edge(key, side, a, thick)
  local d = { "box", key = key, style = "hud/lampDanger", opacity = a }
  if side == "top" then d.stretch, d.h = { 0, 0, 1, 0 }, thick
  elseif side == "bottom" then d.stretch, d.h = { 0, 1, 1, 1 }, thick
  elseif side == "left" then d.stretch, d.w = { 0, 0, 0, 1 }, thick
  else d.stretch, d.w = { 1, 0, 1, 1 }, thick end
  d.pin = ({ top = "top", bottom = "bottom", left = "left", right = "right" })[side]
  d.stretch = nil
  if side == "top" or side == "bottom" then d.w = "100%" else d.h = "100%" end
  return d
end

local function chip(i, c, flash)
  local danger = c[2] == "danger"
  return { "row", key = "c" .. i, style = danger and "hud/chip" or "hud/chipWarn", w = "fit", h = 28, pad = 6, gap = 0,
           align = "center", opacity = flash,
           { "text", key = "t" .. i, style = danger and "hud/valueDanger" or "hud/chipWarnText", w = "fit", h = 20,
             text = c[1] } }
end

function lateUpdate(node, dt)
  if not el then el = node:getcomponent("UiElement") end
  if not el then return end
  local C = ref("crew")
  local pc = ref("planet_camera")
  -- a death: the sting and the camera's hold
  local ld = C and C.lastDeath
  if ld and ld.t ~= death_t then
    death_t = ld.t
    play("sting", { track = "UI", volume = 0.9 })
    -- the camera holds on the fallen only when it was the one you control
    -- (a crew member shot dead 150 m off must not yank the view, or the
    -- scope, away from the shooter)
    local mine = C.activeId and ld.id == C.activeId()
    if pc and pc.holdOn and ld.x and mine then pc.holdOn(ld.x, ld.y, ld.z, 2.0) end
  end
  local id = who()
  local a = (C and C.alerts and id) and C.alerts(id) or nil
  local t = time or 0
  local shots, loop = soundsOf(S, a, t)
  for _, k in ipairs(shots) do play(k) end
  set_loop(loop)
  local chips = chipsOf(a)
  -- blackout dim: toward 0.85 over the grace, back up quickly
  local want = (a and a.blackout) and 0.85 or 0.0
  dim = dim + (want - dim) * math.min(1, dt * (want > dim and 0.6 or 3.0))
  hud.chips, hud.dim = #chips, dim
  local cine = pc and (pc.cinematic or pc.freecam)
  if (#chips == 0 and dim < 0.01) or cine then
    if el.visible then el.visible = false end
    return
  end
  if not el.visible then el.visible = true end
  local root = { "box", key = "alerts", pin = "center", w = "100%", h = "100%" }
  if dim > 0.01 then
    root[#root + 1] = { "box", key = "dim", style = "load/backdrop", pin = "center", w = "100%", h = "100%", opacity = dim }
  end
  local danger_rim = false
  for _, c in ipairs(chips) do
    if c[1] == "O2 1 MIN" or c[1] == "PINNED" or (c[1]:find("^BREATH") and c[2] == "danger") or c[1]:find("^HIT") then
      danger_rim = true
    end
  end
  if danger_rim then
    local pulse = 0.35 + 0.35 * math.abs(math.sin(t * 3.2))
    for _, s in ipairs({ "top", "bottom", "left", "right" }) do root[#root + 1] = edge("rim" .. s, s, pulse, 12) end
  end
  local row = { "row", key = "chips", pin = "top", y = 96, w = "fit", h = 30, gap = 8, pad = 0, align = "center" }
  for i, c in ipairs(chips) do
    local flash = c[2] == "danger" and (0.75 + 0.25 * math.abs(math.sin(t * 4))) or 1.0
    row[#row + 1] = chip(i, c, flash)
  end
  root[#root + 1] = row
  ui.make(node, root)
end
