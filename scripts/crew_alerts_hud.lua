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
--     DOSE 12% ▲  radiation (crew.addDose): shown once above zero; red while
--                 past 50 % or rising toward a lethal dose within two hours
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

-- The cause of a hit, as the chip names it (crew.lastHit's `cause`).
HIT_CAUSE = { impact = "FALL", shot = "SHOT", crush = "CRUSHED", heat = "BURN", blast = "BLAST",
              explosion = "BLAST" }

-- The chips for one member's alerts: { {text, level = "warn"|"danger"} … }
function chipsOf(a)
  local out = {}
  if not a then return out end
  -- (what hit them, said in the chip: a fall reads differently from a shot)
  if a.hit then
    local why = HIT_CAUSE[a.hit.cause or ""]
    out[#out + 1] = { "HIT −" .. pct(a.hit.amount) .. "%" .. (why and (" · " .. why) or ""), "danger" }
  end
  local lv = a.o2_level or airLevel(a.o2, a.air_s)
  if lv == "min" then out[#out + 1] = { "O2 1 MIN", "danger" }
  elseif lv == "crit" then out[#out + 1] = { "O2 " .. pct(a.o2) .. "%", "danger" }
  elseif lv == "low" then out[#out + 1] = { "O2 " .. pct(a.o2) .. "%", "warn" } end
  local bl = a.breath_level or ((a.breath or 1) < 1 and airLevel(a.breath, nil) or nil)
  if bl == "crit" or bl == "min" then out[#out + 1] = { "BREATH " .. pct(a.breath) .. "%", "danger" }
  elseif bl == "low" then out[#out + 1] = { "BREATH " .. pct(a.breath) .. "%", "warn" } end
  if (a.hp or 1) < 0.99 then out[#out + 1] = { "HP " .. pct(a.hp) .. "%", (a.hp or 1) < 0.35 and "danger" or "warn" } end
  if (a.heat or 0) >= 0.2 then out[#out + 1] = { "HEAT " .. pct(a.heat) .. "%", (a.heat or 0) >= 0.6 and "danger" or "warn" } end
  -- RADIATION (thermal.lua A4): only once there is any; ▲ while it is rising
  if (a.dose or 0) > 0 then
    local d = a.dose
    local txt = "DOSE " .. (d < 0.01 and "<1" or tostring(pct(d))) .. "%" .. (a.dose_rising and " ▲" or "")
    -- red past half, or while it rises fast enough to kill within two hours
    out[#out + 1] = { txt, (d >= 0.5 or (a.dose_rate or 0) * 7200 >= 1) and "danger" or "warn" }
  end
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

-- The flown craft, kept between frames: one read while it is still flown, not
-- a walk over every craft in the world each frame. Walked again at once when
-- it stops being flown, and four times a second while nothing is.
local pil_h, pil_t = nil, -1e9
local function flown()
  local v = pil_h
  if v and v.valid ~= false and v.piloting and v.node and v.node.valid ~= false then return v end
  if not v and (time or 0) - pil_t < 0.25 then return nil end
  pil_h, pil_t = nil, time or 0
  for _, w in ipairs(findScripts and findScripts("vessel_controller") or {}) do
    if w.piloting and w.node and w.node.valid ~= false then pil_h = w; return w end
  end
  return nil
end

local function who()
  local C = ref("crew")
  if not C then return nil end
  local v = flown()
  if v then
    local cmd = v.commander and v.commander()
    return cmd or (C.activeId and C.activeId()), v
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

-- (graveyard2, Ty 2026-11-10: "no indicators for what roles everyone has")
-- THE TAG: look at a crew member within 8 m and their name and role show
-- under the crosshair ("DANA KOWALCZYK · ENGINEER · GOING OFF SHIFT"). A
-- ray down the view ten times a second; the tag stays 0.4 s after the ray
-- leaves them, so it does not blink at an edge.
TAG_RANGE, TAG_EVERY, TAG_HOLD = 8.0, 0.1, 0.4
tagNow = nil                 -- { id, name, title } (probes)
local tag_t, tag_seen = -1, -1
local function tag_tick(C, pc)
  local t = time or 0
  if t - tag_t < TAG_EVERY then
    if tagNow and t - tag_seen > TAG_HOLD then tagNow = nil end
    return tagNow
  end
  tag_t = t
  local pw = ref("planet_walker")
  if not (raycast and pc and pc.fwd_x and pw and pw.onFoot) then tagNow = nil return nil end
  local a = find and find("Astronaut")
  -- Who is under the crosshair: of the bodies on foot (crew.bodyNodes, a
  -- handful), the nearest whose capsule (knees to head) the view's line
  -- passes within 0.4 m of, up to 8 m past the player, with nothing standing
  -- between (one ray to it). A single ray down the view missed a capsule at
  -- an edge and, from a third-person camera behind a wall, met the wall first.
  local cx, cy, cz = pc.cam_x, pc.cam_y, pc.cam_z
  local fx, fy, fz = pc.fwd_x, pc.fwd_y, pc.fwd_z
  local s0 = 0
  if a then s0 = math.max(0, (a.x - cx) * fx + (a.y - cy) * fy + (a.z - cz) * fz) end
  local dom = space.dominant and space.dominant(cx, cy, cz)
  local pb = dom and space.body(dom)
  local n, best = nil, math.huge
  tagRay = "none"
  for _, bn in pairs((pb and C.bodyNodes) and C.bodyNodes() or {}) do
    if bn and bn.valid ~= false then
      local p = bn.worldPos or bn
      local ux, uy, uz = p.x - pb.x, p.y - pb.y, p.z - pb.z
      local ul = math.sqrt(ux * ux + uy * uy + uz * uz)
      ux, uy, uz = ux / ul, uy / ul, uz / ul
      local near_off, near_along, near_d = math.huge, 0, 0
      for _, hgt in ipairs({ -0.45, 0.0, 0.4, 0.75 }) do
        local qx, qy, qz = p.x + ux * hgt - cx, p.y + uy * hgt - cy, p.z + uz * hgt - cz
        local along = qx * fx + qy * fy + qz * fz
        local ox, oy, oz = qx - fx * along, qy - fy * along, qz - fz * along
        local off = math.sqrt(ox * ox + oy * oy + oz * oz)
        if off < near_off then near_off, near_along, near_d = off, along, math.sqrt(qx * qx + qy * qy + qz * qz) end
      end
      if near_off < 0.4 and near_along > s0 and near_along < s0 + TAG_RANGE and near_along < best then
        -- a line to it: nothing nearer in the way (walls, consoles)
        local vx, vy, vz = p.x + ux * 0.4 - cx, p.y + uy * 0.4 - cy, p.z + uz * 0.4 - cz
        local d = math.sqrt(vx * vx + vy * vy + vz * vz)
        local ok, h = pcall(raycast, cx, cy, cz, vx / d, vy / d, vz / d, d, { ignore = a and { a, bn } or { bn }, ignoreChildren = true })
        local blocked = ok and h and h.distance and h.distance < d - 0.45 and h.distance > s0 + 0.3
        tagRay = blocked and tostring(h.node and h.node.name or "terrain") or "clear"
        if not blocked then n, best = bn, near_along end
      end
    end
  end
  if n and n.name == "CrewBody" and C.memberOfNode then
    local id = C.memberOfNode(n)
    local r = id and C.get(id)
    if r then
      -- (in a scenario the cast's full name: "Dana Kowalczyk", not the record's "Kowalczyk")
      local nm = r.name
      local sr = ref("scenario_run")
      if sr and sr.isActive and sr.isActive() and sr.speakerOf then
        local ok2, sp = pcall(sr.speakerOf, r.name)
        if ok2 and type(sp) == "table" and sp.name then nm = sp.name end
      end
      tagNow = { id = id, name = nm, rec = r.name, title = C.roleTitle and C.roleTitle(id) or nil }
      tag_seen = t
      return tagNow
    end
  end
  if tagNow and t - tag_seen > TAG_HOLD then tagNow = nil end
  return tagNow
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
  local tg = (C and not cine) and tag_tick(C, pc) or nil
  if (#chips == 0 and dim < 0.01 and not tg) or cine then
    S.made_key = nil
    if el.visible then el.visible = false end
    return
  end
  if not el.visible then el.visible = true end
  -- (a tag alone, or steady chips: described again only when they change)
  local still = dim <= 0.01
  for _, c in ipairs(chips) do if c[2] == "danger" or c[1] == "O2 1 MIN" or c[1] == "PINNED" or c[1]:find("^HIT") then still = false end end
  if still then
    local k = (tg and (tostring(tg.name) .. "|" .. tostring(tg.title)) or "") .. "#"
    for _, c in ipairs(chips) do k = k .. c[1] .. c[2] .. ";" end
    if k == S.made_key then return end
    S.made_key = k
  else S.made_key = nil end
  local root = { "box", key = "alerts", pin = "center", w = "100%", h = "100%" }
  if dim > 0.01 then
    root[#root + 1] = { "box", key = "dim", style = "load/backdrop", pin = "center", w = "100%", h = "100%", opacity = dim }
  end
  local danger_rim = false
  for _, c in ipairs(chips) do
    -- (a hit's flash is injury_fx's now: a vignette in the colour of what hit)
    if c[1] == "O2 1 MIN" or c[1] == "PINNED" or (c[1]:find("^BREATH") and c[2] == "danger")
      or (c[1]:find("^HIT") and not ref("injury_fx")) then
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
  if tg then
    root[#root + 1] = { "col", key = "tag", style = "hud/chip", pin = "center", y = 64, w = "fit", h = "fit", pad = 6, gap = 1, align = "center",
      { "text", key = "tn", style = "hud/chipValue", w = "fit", h = "fit", text = string.upper(tostring(tg.name or "")) },
      tg.title and { "text", key = "tr", style = "hud/chipLabel", w = "fit", h = "fit", text = string.upper(tg.title) } or nil }
  end
  ui.make(node, root)
end
