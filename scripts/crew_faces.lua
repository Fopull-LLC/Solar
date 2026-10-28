-- CREW FACES — what each crew member looks like, and how they feel.
--
-- On the CrewLib node beside crew.lua (prefabs/CrewLib); scripts/face.lua
-- reads it for every head drawn. Loads in luajit (tests/smoke_faces.lua):
-- the looks and the emotion model are pure functions of their inputs.
--
-- ── LOOKS ───────────────────────────────────────────────────────────────────
-- lookFor(seed, id, name) → look, deterministic: the same save's member #4 is
-- always the same person, and no two in a roster are alike (the structure,
-- the hair and the skin are drawn apart from the ones already taken). A look
-- is stored on the record (crew.patch(id, { look = … })), so it survives a
-- rename and a reload; members from before this (and every hire) get theirs
-- the first time they are seen (`ensure`).
--   { v, key, head = 1..8, fem, skin = {r,g,b}, hair = {r,g,b}, hairStyle,
--     grey, eye = {r,g,b}, lip = {r,g,b}, stubble, freckles, age (0 = 25 y ..
--     1 = 58 y), brow (thickness), scar (0 none, 1 brow, 2 cheek, 3 chin),
--     courage, thrill (KSP's courage and stupidity: who keeps a straight face
--     and who whoops), rest = { brow, mouth, lid } (a resting face: −1..1) }
--
-- ── FEELINGS ────────────────────────────────────────────────────────────────
-- Each member aboard a craft or on foot has DRIVES, 0..1, eased toward what
-- they live through (`sense`): strain (g-load), fear (alarms, a lurch, a
-- fall, an explosion near), excite (the roar of a launch, speed piling up,
-- the first seconds weightless), joy (a landing, reaching orbit; relief when
-- it follows fear), pain (a wound), tired (a long time aboard, little air),
-- bored (a long quiet coast) and out (blacked out, downed, or g-LOC). Courage
-- scales fear; thrill scales excitement. `step` is pure.
-- The drives mix EXPRESSIONS (EXPR, named poses over face.lua's CHANNELS),
-- and the mix is eased again so a face never flickers.
--
-- API:
--   lookFor(seed, id, name [, taken]) → look      lookOf(id) → look (ensured)
--   channels(id) → { channel = weight }          moodOf(id) → "happy" | …
--   drives(id) → the drives table                featured(id) → bool (a portrait films them)
--   step(st, inp, dt, look) → st                 mix(st) → channels, mood   (pure)
--   note(id, event)                              "landed" | "orbit" | "boom" | "stage" (probes)
--   force(id, name, weight, secs)                hold an expression (probes, tests)

defaults = {
  sense_hz = 10.0,      -- how often the world is read for each member
}
local function P(k) return (params and params[k]) or defaults[k] end

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not (r and r.valid ~= false) then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function now() return time or 0 end
local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end

-- ═════════════════════════════════════════════════════════════════════════════
-- looks
-- ═════════════════════════════════════════════════════════════════════════════

-- a hash in [0, 1) from integers (kept inside 2^31 for luajit doubles)
local function h01(...)
  local a = 2166136261 % 2147483647
  for _, v in ipairs({ ... }) do
    a = (a * 16777619 + math.floor(v) % 2147483647) % 2147483647
    a = (a * 48271) % 2147483647
  end
  a = (a * 48271) % 2147483647
  return a / 2147483647
end

local function str_hash(s)
  local a = 7
  s = tostring(s or "")
  for i = 1, #s do a = (a * 31 + s:byte(i)) % 2147483647 end
  return a
end

-- first names read as one or the other (crew.lua's FIRST); anything else by hash
FEM_NAMES = { Dana = true, Mira = true, Rina = true, Ada = true, Lena = true, Iris = true, Noor = true, Saga = true,
              Hana = true, Yara = true, June = true, Talia = true, Imani = true, Wren = true, Elif = true }
MASC_NAMES = { Jonah = true, Theo = true, Tomas = true, Kofi = true, Ravi = true, Mateo = true, Elias = true, Ken = true,
               Owen = true, Felix = true, Arjun = true, Bram = true, Leo = true, Sami = true, Nils = true }

-- Skin tones, light to deep (sRGB 0..1): a realistic spread.
SKIN = {
  { 0.93, 0.78, 0.68 }, { 0.89, 0.71, 0.60 }, { 0.84, 0.65, 0.52 }, { 0.78, 0.58, 0.44 }, { 0.70, 0.50, 0.37 },
  { 0.60, 0.42, 0.30 }, { 0.50, 0.34, 0.24 }, { 0.41, 0.27, 0.19 }, { 0.33, 0.21, 0.15 }, { 0.26, 0.17, 0.12 },
}
-- Where a surname leans (a prior, not a rule): the centre of the skin range and its spread.
REGION = {
  Okafor = { 8, 1.2 }, Adeyemi = { 8.5, 1.0 }, Achebe = { 8.5, 1.0 }, Osei = { 8.5, 1.0 }, Abara = { 8, 1.2 },
  Reyes = { 4.5, 1.8 }, Castillo = { 4.5, 1.8 }, Duarte = { 4, 1.8 },
  Ito = { 3.5, 1.0, asian = true }, Nakamura = { 3.5, 1.0, asian = true }, Tanaka = { 3.5, 1.0, asian = true },
  Pillai = { 6.8, 1.2 }, Haddad = { 4.5, 1.3 },
}
HAIR = {
  black = { 0.06, 0.05, 0.045 }, dark = { 0.13, 0.09, 0.07 }, brown = { 0.25, 0.16, 0.10 },
  chestnut = { 0.36, 0.21, 0.12 }, auburn = { 0.45, 0.20, 0.10 }, blond = { 0.62, 0.48, 0.30 },
  ash = { 0.45, 0.40, 0.33 }, red = { 0.55, 0.24, 0.10 },
}
EYES = {
  brown = { 0.30, 0.18, 0.09 }, dark = { 0.16, 0.10, 0.06 }, hazel = { 0.42, 0.33, 0.16 },
  green = { 0.30, 0.42, 0.26 }, blue = { 0.32, 0.46, 0.62 }, grey = { 0.46, 0.50, 0.53 },
}
MASC_STYLES = { "buzz", "crop", "side", "swept", "curls", "receding" }
FEM_STYLES = { "bun", "tail", "crop", "side", "curls", "swept" }

local function pick(list, u) return list[math.floor(u * #list) % #list + 1] end
local function lerp3(a, b, t) return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t } end

local function skin_at(x)
  x = clamp(x, 1, #SKIN)
  local i = math.floor(x)
  local j = math.min(#SKIN, i + 1)
  return lerp3(SKIN[i], SKIN[j], x - i)
end

-- `taken` (optional): { heads = {[n]=count}, styles = {[s]=count}, skins = {x…} }
-- of the members already looked; the new face is drawn away from them.
function lookFor(seed, id, name, taken)
  seed, id = math.floor(seed or 0), math.floor(id or 0)
  name = tostring(name or "")
  local first, last = name:match("^(%S+)%s+(%S+)")
  first, last = first or name, last or ""
  local nh = str_hash(name)
  local function u(k) return h01(seed, id, k) end
  local fem
  if FEM_NAMES[first] then fem = true elseif MASC_NAMES[first] then fem = false else fem = h01(nh, 3) < 0.5 end
  local reg = REGION[last]
  -- skin: the name's lean, or anywhere in the range
  local sx
  if reg then sx = reg[1] + (u(1) * 2 - 1) * reg[2] else sx = 1 + u(1) * (#SKIN - 1) end
  if taken and taken.skins then
    for _ = 1, 3 do                     -- not within half a step of someone already aboard
      local close = false
      for _, o in ipairs(taken.skins) do if math.abs(o - sx) < 0.5 then close = true end end
      if not close then break end
      sx = sx + 1.3
      if sx > #SKIN then sx = sx - (#SKIN - 1) end
    end
  end
  sx = clamp(sx, 1, #SKIN)
  local skin = skin_at(sx)
  -- the structure: four of each, the least used first
  local base = fem and 5 or 1
  local order = { 0, 1, 2, 3 }
  local sh = math.floor(u(2) * 4)
  local best, bestn = nil, math.huge
  for i = 0, 3 do
    local hd = base + (order[(i + sh) % 4 + 1])
    local n = taken and taken.heads and taken.heads[hd] or 0
    if n < bestn then best, bestn = hd, n end
  end
  local headN = best
  if reg and reg.asian and u(12) < 0.6 then headN = fem and 6 or 3 end
  -- hair colour: dark for most; light colours only on lighter skin
  local hc
  local r = u(4)
  if sx >= 5.5 then hc = (r < 0.75) and "black" or "dark"
  elseif sx >= 4 then hc = (r < 0.45) and "dark" or (r < 0.8 and "black" or (r < 0.93 and "brown" or "chestnut"))
  else hc = pick({ "dark", "brown", "brown", "chestnut", "blond", "ash", "auburn", "red", "black" }, r) end
  local hair = HAIR[hc]
  local styles = fem and FEM_STYLES or MASC_STYLES
  local st
  do
    local k = math.floor(u(5) * #styles)
    local bestn2 = math.huge
    for i = 0, #styles - 1 do
      local s = styles[(k + i) % #styles + 1]
      local n = taken and taken.styles and taken.styles[s] or 0
      if n < bestn2 then st, bestn2 = s, n end
    end
  end
  if (sx >= 7.5 and u(13) < 0.5) then st = fem and "curls" or (u(14) < 0.5 and "buzz" or "curls") end
  -- eyes: brown for most; light ones on lighter skin
  local ec
  local e = u(6)
  if sx >= 5 then ec = e < 0.7 and "dark" or "brown"
  elseif sx >= 3.5 then ec = pick({ "brown", "brown", "dark", "hazel", "green" }, e)
  else ec = pick({ "blue", "blue", "grey", "green", "hazel", "brown", "brown" }, e) end
  if hc == "red" or hc == "auburn" then ec = (e < 0.5) and "green" or "blue" end
  local age = u(7) ^ 1.3
  if st == "receding" then age = math.max(age, 0.55) end
  local look = {
    v = 1, key = string.format("%d.%d.%d", seed % 100000, id, nh % 100000),
    head = headN, fem = fem, skin = skin, hair = hair, hairName = hc, hairStyle = st,
    grey = clamp((age - 0.62) * 1.8, 0, 0.6) * (0.5 + 0.5 * u(8)),
    eye = EYES[ec], eyeName = ec,
    lip = lerp3(skin, { 0.55, 0.28, 0.27 }, 0.45 - 0.15 * (sx - 1) / (#SKIN - 1)),
    stubble = fem and 0 or (u(9) < 0.6 and (0.25 + 0.6 * u(10)) or 0.05),
    freckles = (sx < 3.5 and u(11) < 0.45) and (0.4 + 0.6 * u(15)) or 0.05 * u(15),
    age = age,
    brow = (fem and 0.30 or 0.48) + 0.25 * u(16),
    scar = (u(17) < 0.22) and (1 + math.floor(u(18) * 3)) or 0,
    courage = clamp(0.15 + 0.85 * u(19), 0, 1),
    thrill = clamp(u(20) ^ 0.8, 0, 1),
    rest = { brow = u(21) * 2 - 1, mouth = (u(22) * 2 - 1) * 0.8, lid = u(23) * 0.6 },
    skinX = sx, seed = math.floor(u(24) * 1000),
  }
  return look
end

-- ═════════════════════════════════════════════════════════════════════════════
-- expressions (over face.lua's CHANNELS; _L/_R written once as "x_")
-- ═════════════════════════════════════════════════════════════════════════════
EXPR = {
  neutral = {},
  -- calm attention: brows a touch down, lids a touch narrowed
  focus = { brow_down_ = 0.5, squint_ = 0.3, frown_ = 0.1 },
  -- a closed-mouth smile that reaches the eyes
  happy = { smile_ = 0.9, cheek_ = 0.75, squint_ = 0.35, lip_up = 0.15, brow_out_up_ = 0.1, flush = 0.12 },
  -- a broad open smile: corners up and back, cheeks up into the eyes,
  -- the upper teeth showing, the lower lip pulled down and wide
  excited = { smile_ = 1.0, cheek_ = 1.0, squint_ = 0.45, jaw_open = 0.5, lip_up = 0.6, lip_down = 0.15,
              stretch_ = 0.3, brow_out_up_ = 0.3, flush = 0.3 },
  -- the breath out: a soft smile, inner brows still up, lids heavy
  relief = { smile_ = 0.6, cheek_ = 0.45, brow_in_up_ = 0.55, blink_ = 0.25, jaw_open = 0.06 },
  -- floating free: an open-mouthed wondering smile, eyes wide
  delight = { smile_ = 0.85, cheek_ = 0.6, wide_ = 0.3, brow_out_up_ = 0.6, brow_in_up_ = 0.3, jaw_open = 0.3,
              lip_up = 0.6, stretch_ = 0.15 },
  -- inner brows up and knit, the mouth's corners down
  worried = { brow_in_up_ = 1.0, brow_down_ = 0.2, frown_ = 0.7, stretch_ = 0.2, wide_ = 0.15, lip_down = 0.1, pale = 0.15 },
  -- wide eyes under raised brows; the mouth open and tense, pulled wide
  scared = { brow_in_up_ = 1.0, brow_out_up_ = 0.7, wide_ = 0.9, jaw_open = 0.4, stretch_ = 0.85, lip_down = 0.35,
             lip_up = 0.25, pale = 0.5, pupil = 0.7 },
  -- shouting in fear: wider still
  panic = { brow_in_up_ = 1.0, brow_out_up_ = 0.9, wide_ = 1.0, stretch_ = 0.9, jaw_open = 0.8, lip_down = 0.85,
            lip_up = 0.5, pale = 0.75, pupil = 1.0 },
  pain = { brow_down_ = 0.7, brow_in_up_ = 0.45, squint_ = 0.85, blink_ = 0.45, stretch_ = 0.55, lip_up = 0.65,
           jaw_open = 0.1, flush = 0.35, cheek_ = 0.4 },
  strain = { brow_down_ = 0.85, squint_ = 0.75, blink_ = 0.2, lip_up = 0.55, lip_down = 0.3, stretch_ = 0.75, frown_ = 0.3,
             cheek_ = 0.45, flush = 0.85 },
  tired = { blink_ = 0.5, brow_in_up_ = 0.25, frown_ = 0.25, jaw_open = 0.04, pale = 0.15 },
  bored = { blink_ = 0.32, frown_L = 0.05, frown_R = 0.3, smile_L = 0.1, look_y = -0.15 },
  out = { blink_ = 1.0, jaw_open = 0.18, pale = 0.35 },
  dead = { blink_L = 0.82, blink_R = 0.88, jaw_open = 0.14, pale = 1.0 },
}
-- expand "x_" keys to x_L and x_R
for _, e in pairs(EXPR) do
  local add = {}
  for k, v in pairs(e) do
    if k:sub(-1) == "_" then add[k .. "L"], add[k .. "R"] = v, v; e[k] = nil end
  end
  for k, v in pairs(add) do e[k] = v end
end

-- ═════════════════════════════════════════════════════════════════════════════
-- the model (pure)
-- ═════════════════════════════════════════════════════════════════════════════
DRIVES = { "strain", "fear", "excite", "joy", "relief", "delight", "pain", "tired", "bored", "out", "focus" }
-- seconds to rise / to fall back
TAU = {
  strain = { 0.35, 0.9 }, fear = { 0.25, 3.5 }, excite = { 0.8, 5.0 }, joy = { 0.4, 10.0 }, relief = { 0.4, 9.0 },
  delight = { 0.8, 6.0 }, pain = { 0.15, 4.0 }, tired = { 20.0, 30.0 }, bored = { 30.0, 2.0 }, out = { 0.3, 2.5 },
  focus = { 1.0, 3.0 },
}

function newState()
  local st = { d = {}, mix = {}, quiet = 0, weightless = 0, fear_peak = 0, gloc = 0, lastHp = nil, t = 0, events = {} }
  for _, k in ipairs(DRIVES) do st.d[k] = 0 end
  return st
end

local function ease(cur, want, dt, tau)
  local t = want > cur and tau[1] or tau[2]
  return cur + (want - cur) * (1 - math.exp(-dt / math.max(0.01, t)))
end

-- inp = { g (proper acceleration, gees), jerk (|dg/dt|, gees/s), roar (0..1: engines lit × throttle),
--   flying (bool), speed (m/s), weightless (bool), alarm (0..1, worst alert), hurt (0..1, a fresh wound),
--   hp (0..1), o2 (0..1), out (bool: blackout / downed), aboard (bool), piloting (bool),
--   events = { "landed" | "orbit" | "boom" | "stage" … } }
function step(st, inp, dt, look)
  st = st or newState()
  inp = inp or {}
  look = look or {}
  local c = look.courage or 0.5
  local th = look.thrill or 0.5
  local d = st.d
  st.t = st.t + dt
  local g = inp.g or 1
  -- what the moment asks for
  local want = {}
  want.strain = clamp((g - 1.6) / 3.2, 0, 1)
  -- fear: alarms (a brave one less), a lurch, a fall; stays while it lasts
  local lurch = clamp(((inp.jerk or 0) - 3) / 10, 0, 1) * (1.1 - c)
  local alarm = (inp.alarm or 0) * (1.35 - 0.7 * c)
  want.fear = clamp(math.max(alarm, lurch, (inp.hurt or 0) * 0.5 * (1.2 - c)), 0, 1)
  -- excitement: the roar, scaled by how much they love it, dulled by fear
  local roar = (inp.roar or 0) * (inp.flying and 1 or 0.6)
  want.excite = clamp(roar * (0.35 + 0.75 * th) + clamp(((inp.speed or 0) - 150) / 900, 0, 0.3) * th, 0, 1)
  want.pain = clamp((inp.hurt or 0) + (1 - (inp.hp or 1)) * 0.7, 0, 1)
  local o2low = clamp((0.25 - (inp.o2 or 1)) / 0.25, 0, 1)
  want.tired = clamp(o2low * 0.8 + math.max(0, (st.t - 1800) / 7200), 0, 0.8)
  -- weightless: delight for the first while (more for a thrill seeker)
  if inp.weightless then st.weightless = st.weightless + dt else st.weightless = 0 end
  want.delight = inp.weightless and clamp(1 - st.weightless / (25 + 40 * th), 0, 1) * (0.4 + 0.6 * th) or 0
  -- quiet: nothing happening for a long while
  local busy = (inp.roar or 0) > 0.05 or (inp.alarm or 0) > 0.05 or g > 1.4 or (inp.jerk or 0) > 1.5
  if busy then st.quiet = 0 else st.quiet = st.quiet + dt end
  want.bored = clamp((st.quiet - 45) / 120, 0, 0.75) * (inp.aboard and 1 or 0.4)
  want.focus = inp.piloting and clamp(0.35 + roar * 0.4 + (inp.alarm or 0) * 0.3, 0, 0.8) or 0.15
  -- out cold: a blackout, downed, or too many gees for too long (g-LOC)
  if g > 7.5 then st.gloc = st.gloc + dt * (g - 7) / 2 else st.gloc = math.max(0, st.gloc - dt) end
  want.out = (inp.out or st.gloc > 3 - 2 * c) and 1 or 0
  -- events: joy now (relief if they were afraid a moment ago), a jolt of fear
  st.fear_peak = math.max(d.fear, st.fear_peak - dt * 0.008)   -- a fright is remembered for a minute or so
  for _, ev in ipairs(inp.events or {}) do
    if ev == "landed" or ev == "orbit" then
      if st.fear_peak > 0.35 then d.relief = math.max(d.relief, 0.9) end
      d.fear = d.fear * 0.3              -- it's over
      d.joy = math.max(d.joy, ev == "orbit" and 1.0 or 0.8 + 0.2 * th)
      st.fear_peak = 0
    elseif ev == "boom" then
      d.fear = math.max(d.fear, 0.9 * (1.2 - c))
    elseif ev == "stage" then
      d.excite = math.max(d.excite, 0.35 + 0.4 * th)
      d.fear = math.max(d.fear, 0.25 * (1 - c))
    end
  end
  for _, k in ipairs(DRIVES) do
    if want[k] ~= nil then
      if k == "joy" or k == "relief" then
        d[k] = ease(d[k], 0, dt, TAU[k])
      else
        d[k] = ease(d[k], math.max(want[k], (k == "excite" or k == "fear") and 0 or 0), dt, TAU[k])
      end
    else
      d[k] = ease(d[k], 0, dt, TAU[k])
    end
  end
  -- a forced expression (probes): held as a drive of its own
  if st.force then
    st.force.left = st.force.left - dt
    if st.force.left <= 0 then st.force = nil end
  end
  return st
end

-- The expression weights from the drives, then the channels. Smoothed per
-- channel in `mix` so a change of mood crosses over, never jumps.
function weights(st, look)
  local d = st.d
  local c = (look and look.courage) or 0.5
  local w = {}
  if st.dead then return { dead = 1 }, "dead" end
  w.strain = d.strain
  local fear = d.fear * (1 - 0.5 * d.out)
  w.panic = clamp((fear - 0.6) / 0.4, 0, 1) * (1.2 - c)
  w.scared = clamp(fear * 1.4, 0, 1) * (1 - w.panic)
  w.worried = clamp(fear * 2.5, 0, 1) * (1 - clamp(fear * 1.6, 0, 1)) * 0.9
  local calm = 1 - clamp(fear * 1.5, 0, 1)
  w.excited = d.excite * calm * (1 - d.strain * 0.6)
  w.happy = d.joy * calm * (1 - d.relief)
  w.relief = d.relief * calm
  w.delight = d.delight * calm
  w.pain = d.pain
  w.tired = d.tired * (1 - d.excite)
  w.bored = d.bored * calm * (1 - d.excite)
  w.focus = d.focus * (1 - clamp(d.joy + d.excite + fear, 0, 1)) * 0.8
  if d.out > 0.3 then
    for k, v in pairs(w) do if k ~= "out" then w[k] = v * (1 - d.out) end end
    w.out = d.out
  end
  if st.force then w = { [st.force.name] = st.force.w } end
  local best, bw = "neutral", 0.12
  for k, v in pairs(w) do if v > bw then best, bw = k, v end end
  return w, best
end

function mix(st, look, dt)
  local w, mood = weights(st, look)
  local total = 0
  for _, v in pairs(w) do total = total + v end
  local scale = total > 1 and 1 / total or 1
  local want = {}
  for name, v in pairs(w) do
    local e = EXPR[name]
    if e and v > 0 then
      for ch, x in pairs(e) do want[ch] = (want[ch] or 0) + x * v * scale end
    end
  end
  -- a whoop: the jaw goes with the excitement
  if (w.excited or 0) > 0.55 then
    want.jaw_open = (want.jaw_open or 0) + 0.25 * (w.excited - 0.55) * (0.5 + 0.5 * math.sin((st.t or 0) * 7))
  end
  -- panic: the eyes dart (face.lua's saccades widen with wide_); breathing hard
  if (w.panic or 0) > 0.3 then
    want.jaw_open = (want.jaw_open or 0) + 0.1 * w.panic * math.sin((st.t or 0) * 9)
  end
  local m = st.mix
  local k = 1 - math.exp(-(dt or 0.1) / 0.18)
  for ch, v in pairs(want) do m[ch] = (m[ch] or 0) + (math.min(1.2, v) - (m[ch] or 0)) * k end
  for ch, v in pairs(m) do
    if want[ch] == nil then m[ch] = v + (0 - v) * k end
  end
  st.mood = mood
  return m, mood
end

-- ═════════════════════════════════════════════════════════════════════════════
-- the live side
-- ═════════════════════════════════════════════════════════════════════════════
local states = {}       -- [id] = st
local crafts = {}       -- [node id] = { vx, vy, vz, t, g, jerk, parts, pe, landed_t, maxspd, airborne }
local looks = {}        -- [id] = look (cache of the record's)
local sense_t = {}
local pending = {}      -- [id] = { events }

local function crewlib() return ref("crew") end

local function taken_by(roster, except)
  local t = { heads = {}, styles = {}, skins = {} }
  for _, r in ipairs(roster or {}) do
    local l = r.look
    if r.id ~= except and type(l) == "table" and l.head then
      t.heads[l.head] = (t.heads[l.head] or 0) + 1
      if l.hairStyle then t.styles[l.hairStyle] = (t.styles[l.hairStyle] or 0) + 1 end
      if l.skinX then t.skins[#t.skins + 1] = l.skinX end
    end
  end
  return t
end

local function seed()
  return (save and save.get and save.get("g_seed")) or 0
end

-- Every member gets a look once, stored on the record.
function ensure()
  local C = crewlib()
  if not (C and C.roster) then return end
  local roster = C.roster() or {}
  for _, r in ipairs(roster) do
    local l = r.look
    if type(l) ~= "table" or (l.v or 0) < 1 then
      l = lookFor(seed(), r.id, r.name, taken_by(roster, r.id))
      if C.patch then C.patch(r.id, { look = l }) end
      r.look = l
    end
    looks[r.id] = l
  end
end

function lookOf(id)
  if looks[id] then return looks[id] end
  local C = crewlib()
  local r = C and C.get and C.get(id)
  if not r then return nil end
  if type(r.look) ~= "table" then ensure() return looks[id] end
  looks[id] = r.look
  return r.look
end

function note(id, ev)
  pending[id] = pending[id] or {}
  table.insert(pending[id], ev)
end

function force(id, name, w, secs)
  states[id] = states[id] or newState()
  states[id].force = name and { name = name, w = w or 1, left = secs or 1e9 } or nil
end

function drives(id) return states[id] and states[id].d or nil end
function moodOf(id) return states[id] and states[id].mood or "neutral" end
function channels(id) return states[id] and states[id].mix or nil end

-- Is a crew-strip portrait filming member id? (aboard the craft you fly,
-- the strip up)
function featured(id)
  local C = crewlib()
  local S = ref("crew_strip")
  if not (C and S and S.strip and (S.strip.live or 0) > 0) then return false end
  local v = C.craftOf and C.craftOf(id)
  return v ~= nil and v.piloting == true
end

local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end

-- One craft's motion, read once per sense tick for everyone aboard: proper
-- acceleration (what the crew feels), its rate, events.
local function craft_motion(v, dt)
  local n = v.node
  if not (n and n.valid ~= false) then return nil end
  local k = crafts[n.id]
  local t = now()
  if not k then
    k = { vx = n.vx, vy = n.vy, vz = n.vz, t = t, g = 1, jerk = 0, maxspd = 0, still = 0, parts = nil, orbit = false }
    crafts[n.id] = k
    return k
  end
  local dtt = t - k.t
  if dtt < 0.05 then return k end
  local ax, ay, az = (n.vx - k.vx) / dtt, (n.vy - k.vy) / dtt, (n.vz - k.vz) / dtt
  -- gravity is not felt: take it out
  local dom = space and space.dominant and space.dominant(n.x, n.y, n.z)
  local b = dom and space.body and space.body(dom)
  local gl = 9.81
  if b then
    local rx, ry, rz = n.x - b.x, n.y - b.y, n.z - b.z
    local r = len(rx, ry, rz)
    if r > 1 and b.mu then
      local ga = b.mu / (r * r)
      ax, ay, az = ax + rx / r * ga, ay + ry / r * ga, az + rz / r * ga
      gl = math.max(1, (b.mu / ((b.radius or r) ^ 2)))
    end
  end
  local g = len(ax, ay, az) / 9.81
  if g > 40 then g = k.g end                      -- a teleport, a rails hop: not a feeling
  local gs = k.g + (g - k.g) * (1 - math.exp(-dtt / 0.25))
  k.jerk = k.jerk + (math.abs(gs - k.g) / dtt - k.jerk) * (1 - math.exp(-dtt / 0.3))
  k.g = gs
  k.vx, k.vy, k.vz, k.t = n.vx, n.vy, n.vz, t
  local spd = len(n.vx - (b and b.vx or 0), n.vy - (b and b.vy or 0), n.vz - (b and b.vz or 0))
  local tele = v.tele
  if tele and tele.spd then spd = tele.spd end
  k.spd = spd
  k.events = {}
  -- landed: still on the ground after a flight
  k.maxspd = math.max(k.maxspd, spd)
  if spd < 0.8 and gs > 0.5 then k.still = k.still + dtt else k.still = 0 end
  if k.still > 1.5 and k.maxspd > 12 then
    k.events[#k.events + 1] = "landed"
    k.maxspd = 0
  end
  -- orbit: the periapsis comes up out of the air
  if tele and tele.pe and b then
    local inorbit = tele.pe > 0.35 * (b.radius or 1000) and (tele.ap or 0) > 0
    if inorbit and not k.orbit then k.events[#k.events + 1] = "orbit" end
    k.orbit = inorbit
  end
  -- parts gone: staging (fired) or a part lost (a bang)
  local np = tele and tele.parts
  if np and k.parts and np < k.parts then
    k.events[#k.events + 1] = (k.staged_t and t - k.staged_t < 1.0) and "stage" or "boom"
  end
  if np then k.parts = np end
  k.weightless = gs < 0.12 and spd > 5
  k.gl = gl
  return k
end

-- What member id lives through now: the inputs to step().
local function sense(id, dt)
  local C = crewlib()
  local r = C and C.get and C.get(id)
  if not r then return nil end
  if r.status == "dead" then return { dead = true } end
  local inp = { g = 1, jerk = 0, roar = 0, events = pending[id] or {}, hp = r.hp or 1, o2 = r.o2 or 1 }
  pending[id] = nil
  local a = C.alerts and C.alerts(id) or {}
  local alarm = 0
  local function worse(x) if x > alarm then alarm = x end end
  if a.o2 and a.o2 < 0.25 then worse(a.o2 < 0.1 and 1.0 or 0.6) end
  if (a.heat or 0) >= 0.2 then worse(clamp(a.heat, 0, 1)) end
  if (a.fall or 0) > 0 then worse(clamp((a.fall or 0) / 12, 0, 1)) end
  if a.pinned then worse(0.8) end
  if a.cabin and a.cabin < 0.6 then worse(clamp((0.6 - a.cabin) / 0.4, 0.3, 1)) end
  if a.downed then worse(0.7) end
  if a.down then worse(0.5) end
  if a.breath and a.breath < 0.5 then worse(0.7) end
  inp.alarm = alarm
  inp.hp = a.hp or inp.hp
  inp.o2 = a.o2 or inp.o2
  inp.hurt = a.hit and clamp((a.hit.amount or 0.2) * 3, 0.4, 1) or 0
  inp.out = (a.blackout ~= nil) or (a.downed ~= nil) or (r.downed ~= nil)
  local v = C.craftOf and C.craftOf(id)
  if v then
    inp.aboard = true
    inp.piloting = v.piloting == true and C.activeId and C.activeId() == id
    local k = craft_motion(v, dt)
    if k then
      inp.g, inp.jerk, inp.speed, inp.weightless = k.g, k.jerk, k.spd, k.weightless
      inp.flying = (k.spd or 0) > 2
      for _, e in ipairs(k.events or {}) do inp.events[#inp.events + 1] = e end
    end
    local tele = v.tele
    local lit = tele and (tele.thrust_now or 0) > 0
    inp.roar = lit and clamp((v.throttle or 0) * math.min(1, (tele.twr or 1) / 1.2), 0, 1) or 0
  end
  return inp
end

local function share_events(v)
  -- one craft's events go to everyone aboard (sense pulls them per member)
  return v
end

local ensured_v = -1
local ros = {}          -- the roster, read again only when crew.version moves
function update(node, dt)
  local C = crewlib()
  if not C then return end
  if C.version ~= ensured_v then
    ensured_v = C.version
    ensure()
    looks = {}
    ros = C.roster() or {}
    for _, r in ipairs(ros) do looks[r.id] = r.look end
  end
  local hz = P("sense_hz")
  local t = now()
  for _, r in ipairs(ros) do
    local id = r.id
    local st = states[id]
    if not st then st = newState(); states[id] = st end
    if r.status == "dead" then
      st.dead = true
    elseif r.status == "aboard" or r.status == "afoot" then
      st.dead = false
      local last = sense_t[id] or 0
      if t - last >= 1 / hz then
        local sdt = math.min(0.5, t - last)
        sense_t[id] = t
        local inp = sense(id, sdt)
        if inp then step(st, inp, sdt, looks[id]) end
      end
    end
    mix(st, looks[id], dt)
  end
  -- craft samples shared: forget crafts gone
  for nid, k in pairs(crafts) do
    if t - (k.t or 0) > 30 then crafts[nid] = nil end
  end
  share_events(nil)
end
