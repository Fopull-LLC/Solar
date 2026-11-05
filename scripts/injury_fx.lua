-- INJURY FX — what being hurt looks like from inside the suit (playtest
-- 2026-11-05: "not great immersiveness with blood effects on screen with
-- injuries so hard to tell certain things").
--
-- Drawn for the crew member you control, from crew.lua's record and its
-- `lastHit`, the walker's air and crew heat — this only shows; the rules are
-- crew.lua's. Four full-screen images on their own layer under the alert
-- chips (scenes/system.ron "Injury FX"), built once and never rebuilt: each
-- frame only their opacity (and the flash's tint) is written, and only when
-- it moved. The saturation of the post grade is the fifth dial.
--
--   HURT (hp under 85%)  a dark red edge (blood loss), growing as hp falls;
--                        under 55% blood on the visor's rim; under 45% the
--                        colour drains (post saturation) and under 40% the
--                        edges close in, dark.
--   NEAR DEATH (< 35%)   all of it pulses with a heartbeat — lub-dub, faster
--                        as hp falls (70 → 130 a minute).
--   A HIT                a flash at the edges in the colour of what did it,
--                        its strength the hp it took, gone in under a second,
--                        and the camera's shake (planet_camera.addShake):
--                          fall (impact)  a dark jolt, brown-black, heavy shake
--                          shot           red, and blood thrown on the rim
--                          heat / burn    orange       crush   deep red
--                          blast          hot white-orange
--   HEAT (crew heat ≥ 0.2)  an orange glow at the edges while it lasts.
--   AIR (under 25%)      the edges close in dark and the colour drains
--                        (hypoxia), with the existing O2 chip saying why.
-- The chips (crew_alerts_hud) name the cause in words: "HIT −24% · FALL".
-- All of it eases (in at 4/s, out at 1/s; the blood clears over ~3 s after a
-- heal), and when there is nothing to show the layer is hidden and the grade
-- is put back: a healthy crew costs one table read a frame.
--
-- Published: `state` { blood, splat, dark, flash, heat, desat, beat } (probes),
-- describe() → one line of it.

defaults = { enabled = 1 }

local VIG = "textures/ui/injury_vignette.png"
local BLOOD = "textures/ui/injury_blood.png"

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not (r and r.valid ~= false) then
    r = findScript and findScript(kind) or nil
    refs[kind] = r
  end
  return r
end

-- The flash colour of each cause (crew.lastHit's `cause`).
FLASH = {
  impact = { 0.16, 0.10, 0.07 },
  shot = { 0.62, 0.03, 0.02 },
  crush = { 0.45, 0.02, 0.02 },
  heat = { 1.00, 0.42, 0.08 },
  blast = { 1.00, 0.78, 0.50 },
  explosion = { 1.00, 0.78, 0.50 },
}
-- How hard the camera shakes for a hit of each cause, per unit of hp taken.
SHAKE = { impact = 1.6, shot = 0.9, crush = 1.2, heat = 0.3, blast = 2.0, explosion = 2.0 }

local function smoothstep(a, b, x)
  local t = (x - a) / (b - a)
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  return t * t * (3 - 2 * t)
end

-- The heartbeat's shape at phase p (0..1 of a beat): a lub, then a softer dub.
function heartbeat(p)
  local function bump(c, w) local d = (p - c) / w; return math.exp(-d * d) end
  return bump(0.06, 0.05) + 0.6 * bump(0.30, 0.06)
end

-- What hp, heat and air ask for (pure: tests/smoke_injury_fx.lua).
-- → blood, splat, dark, desat, heat glow (0..1 each), heartbeat depth, rate (beats/s)
function targets(hp, heat, oxygen)
  hp, heat, oxygen = hp or 1, heat or 0, oxygen or 1
  local blood = 0.75 * smoothstep(0.85, 0.10, hp)
  local splat = 0.85 * smoothstep(0.55, 0.12, hp)
  local dark = 0.50 * smoothstep(0.40, 0.05, hp)
  local desat = 0.65 * smoothstep(0.45, 0.08, hp)
  local hyp = smoothstep(0.25, 0.0, oxygen)
  dark = math.max(dark, 0.6 * hyp)
  desat = math.max(desat, 0.5 * hyp)
  local glow = 0.55 * smoothstep(0.2, 0.9, heat)
  local beat = smoothstep(0.35, 0.10, hp)
  local rate = (70 + 60 * smoothstep(0.35, 0.05, hp)) / 60
  return blood, splat, dark, desat, glow, beat, rate
end

state = { blood = 0, splat = 0, dark = 0, flash = 0, heat = 0, desat = 0, beat = 0 }
local S = state
local el, root
local E = {}            -- name → UiElement handle
local built = false
local sent = {}         -- name → last opacity written
local hit_t = nil       -- the last hit seen (its time), so each flashes once
local flash_c = { 1, 1, 1 }
local splat_kick = 0.0  -- blood thrown by a fresh hit, over the hp's own
local phase = 0.0
local rec = { t = -1, hp = 1, heat = 0 }
local post, base_sat, sat_sent = nil, nil, nil

local function build(node)
  local function img(name, tex, tint)
    return { "image", key = name, name = name, texture = tex, pin = "center", w = "100%", h = "100%",
             imageFit = "stretch", opacity = 0, tint = tint }
  end
  ui.make(node, { { "box", key = "inj", name = "InjuryRoot", pin = "center", w = "100%", h = "100%",
    img("InjuryDark", VIG, { 0, 0, 0, 1 }),
    img("InjuryBlood", VIG, { 0.30, 0.012, 0.008, 1 }),
    img("InjurySplat", BLOOD, { 1, 1, 1, 1 }),
    img("InjuryHeat", VIG, { 1.0, 0.45, 0.1, 1 }),
    img("InjuryFlash", VIG, { 1, 1, 1, 1 }) } })
  built = true
end

local function handle(node, name)
  local h = E[name]
  if h then return h end
  local n = node.find and node:find(name)
  h = n and n:getcomponent("UiElement") or nil
  E[name] = h
  return h
end

local function set_op(node, name, a)
  if a < 0.004 then a = 0 end
  if sent[name] and math.abs(sent[name] - a) < 0.004 then return end
  local h = handle(node, name)
  if h then h.opacity = a; sent[name] = a end
end

local function grade(desat)
  if not post then
    local pn = find and find("Post Processing")
    post = pn and pn:getcomponent("PostProcess") or nil
    if not post then return end
  end
  if desat <= 0.003 then
    if base_sat and sat_sent then post.saturation = base_sat; sat_sent = nil end
    return
  end
  if not base_sat then base_sat = post.saturation or 1.0 end
  local want = base_sat * (1 - desat)
  if not sat_sent or math.abs(sat_sent - want) > 0.004 then post.saturation = want; sat_sent = want end
end

-- in at 4/s, out at 1/s
local function ease(cur, want, dt)
  local k = want > cur and 4.0 or 1.0
  return cur + (want - cur) * (1 - math.exp(-k * dt))
end

function describe()
  return string.format("blood %.2f splat %.2f dark %.2f flash %.2f heat %.2f desat %.2f beat %.2f",
    S.blood, S.splat, S.dark, S.flash, S.heat, S.desat, S.beat)
end

function start(node)
  el = node.getcomponent and node:getcomponent("UiElement") or nil
  if el then el.visible = false end
end

function lateUpdate(node, dt)
  if not el then el = node:getcomponent("UiElement") end
  if not el or (params.enabled or 1) < 0.5 then return end
  local C = ref("crew")
  local pw = ref("planet_walker")
  local pc = ref("planet_camera")
  local id = C and C.activeId and C.activeId()
  local t = time or 0
  -- the record a few times a second (save.get builds a table)
  if id and t - rec.t > 0.2 then
    rec.t = t
    local r = C.get and C.get(id)
    rec.hp = (r and r.status ~= "dead" and r.hp) or 1
    rec.heat = (r and r.heat) or 0
    if C.invincible and C.invincible() then rec.hp, rec.heat = 1, 0 end
  end
  local oxy = (pw and pw.onFoot and pw.oxygen) or 1
  -- a fresh hit: its flash, its blood, its shake
  local lh = id and C.lastHit and C.lastHit[id]
  if lh and lh.t ~= hit_t then
    local first = hit_t == nil and (t - (lh.t or 0)) > 1.0
    hit_t = lh.t
    if not first then
      local amt = math.max(0, lh.amount or 0)
      local c = FLASH[lh.cause or ""] or FLASH.shot
      flash_c[1], flash_c[2], flash_c[3] = c[1], c[2], c[3]
      S.flash = math.min(0.95, 0.4 + amt * 1.6)
      if lh.cause == "shot" or lh.cause == "impact" or lh.cause == "crush" then
        splat_kick = math.min(0.9, splat_kick + 0.25 + amt * 1.5)
      end
      local h = handle(node, "InjuryFlash")
      if h then h.tintR, h.tintG, h.tintB = c[1], c[2], c[3] end
      if pc and pc.addShake then pc.addShake(math.min(1.0, (SHAKE[lh.cause or ""] or 1.0) * (0.15 + amt))) end
    end
  end
  local tb, ts, td, tdes, tg, beat, rate = targets(rec.hp, rec.heat, oxy)
  S.blood, S.dark, S.desat, S.heat = ease(S.blood, tb, dt), ease(S.dark, td, dt), ease(S.desat, tdes, dt), ease(S.heat, tg, dt)
  -- (blood a hit threw stays a few seconds; a healed crew wipes it off quickly)
  splat_kick = splat_kick * math.exp(-(rec.hp >= 0.99 and 2.0 or 0.6) * dt)
  S.splat = ease(S.splat, math.max(ts, splat_kick), dt)
  S.flash = S.flash * math.exp(-4.5 * dt)
  S.beat = ease(S.beat, beat, dt)
  local b = 0
  if S.beat > 0.01 then
    phase = (phase + dt * rate) % 1
    b = heartbeat(phase) * S.beat
  end
  local cine = pc and (pc.cinematic or pc.freecam)
  local any = S.blood + S.splat + S.dark + S.flash + S.heat > 0.01
  if not any or cine then
    if el.visible then el.visible = false end
    grade(cine and 0 or S.desat)
    return
  end
  if not built then build(node) end
  if not el.visible then el.visible = true end
  set_op(node, "InjuryDark", math.min(1, S.dark * (1 + 0.45 * b)))
  set_op(node, "InjuryBlood", math.min(1, S.blood * (1 + 0.55 * b)))
  set_op(node, "InjurySplat", math.min(1, S.splat))
  set_op(node, "InjuryHeat", math.min(1, S.heat * (0.85 + 0.15 * math.sin(t * 7.0))))
  set_op(node, "InjuryFlash", math.min(1, S.flash))
  grade(S.desat * (1 + 0.25 * b))
end
