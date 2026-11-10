-- SURVEY — what the agency knows about each world (expansion plan X1, PLAN
-- §7; docs/tracking-station.md §6, docs/crew-and-items.md §11).
--
-- Per body, six LAYERS, each known from 0 (nothing) to 1 (measured):
--   grav   gravity            (mu / R², the surface g)
--   atmo   atmosphere         (world.<name>.air: pressure, gases, verdict)
--   temp   temperature        (bio.tempK)
--   comp   composition        (the planet type, the ores in its rock)
--   mag    magnetosphere      (world.<name>.mag, µT: a generated trait)
--   res    resources          (where the ores lie: bodyOres by weight)
-- A layer at 1 shows the number; below it a BAND, as wide as what is not yet
-- known ("about 0.3–0.5 g"), and the instruments that would fill it.
--
-- HOW THEY FILL (SOURCES; each a thing you fly, build or carry):
--   soi       entering its sphere of influence: grav 1 (you feel it)
--   orbit     one full orbit round it: temp 0.5, atmo 0.4, res 0.1
--   land      a craft landed, or the crew on foot there: temp 1, atmo 0.8,
--             comp 0.3 (the FIRST LANDING caption with its RP)
--   tel30     a 0.3 m telescope sweep: temp 0.3, atmo 0.3
--   tel100    a 1 m telescope with its spectrograph: temp 0.6, atmo 0.6
--   scanner   the Orbital Scanner part in orbit 0.1–1.5 R up, powered and
--             heard by the ground: comp 0.7, atmo 0.9 (a limb sounder), and
--             res by SWATH (X7): the share of the world's 400-cell grid its
--             swath has passed over (swathTrack along the conic, swathMark;
--             30° either side of nadir, so a higher orbit maps a wider band;
--             the worlds do not turn, so each orbital plane maps one band).
--             (X1's closed-form coverageStep is kept for old callers; an old
--             save's res stays what it was: a layer only rises.)
--   gravimeter (X7) the Gravimeter part, in the same band: grav 1 at once,
--             mag over three orbits (GRAV_ORBITS)
--   station   the Survey Station kit piece standing on the world: comp 1
--             after 10 min (the seismometer), temp and atmo 1 after 6 h of
--             weather, mag 1 after a day (the magnetometer)
--   home      the home world is known (an old save's too): every layer 1
-- A value only ever rises (the larger of what was known and what is new).
--
-- TELESCOPES (the kit's Telescope 0.3 m / 1 m, a VAB Space Telescope on a
-- satellite): a SWEEP is ten game minutes on one target (SWEEP_S). On the
-- ground it needs a SCIENTIST at the eyepiece (right-click it → Sweep), the
-- base grid's power, NIGHT or no air (the sky; the home system's star is at
-- the origin), and the target above the horizon. In space the part sweeps by
-- itself, one body after another, while it has power and a link home.
--
-- RP FOR NEW DATA: every rise of a layer earns RP[layer] × the rise, × 2 off
-- the home world, × the running Scientist's study_mult (crew.lua's J5 perk,
-- which now does something); research.addPoints credits it (whole points,
-- the fraction carried per body). A body full in every layer is SURVEYED.
-- (Spending RP is X6.)
--
-- SAVE: survey.<body> = { seen, visited, orbited, landed (agency-clock s),
--   L = { grav, atmo, temp, comp, mag, res }, by = { <layer> = "how" },
--   rp (RP earned here), rf (its fraction), sta (Survey Station seconds),
--   cov (X1's scanner coverage 0..1), sw (X7: the swath grid's marked
--   cells, 4 a hex digit), gm (X7: the gravimeter's field 0..1) }
-- survey.jobs = { { sid, uid, b (target), t0, ap, by (member id), m (mult) } }
--
-- When it runs: a 1 Hz tick on the agency clock; the structures' instruments
-- are found again only when structures.version moves. Nothing per frame.
--
-- Pure (tests/smoke_survey.lua): LAYERS, SOURCES, RP, newRec, apply,
-- surveyed, coverageStep, reachOf, inScanBand, telescopeCan, sweepYield,
-- truthOf, layerText, nextTarget; X7 swathCells, swathHalf, swathMark,
-- maskCount, maskEncode, maskDecode, swathTrack.
--
-- THE RES_MAP (X7): resMap(name, budget) → the mapped cells with the ore
-- their patch holds most of (mineral_field.patchOres, from the seed), read a
-- few a call while the station shows the world; swathShare(name).

LAYERS = { "grav", "atmo", "temp", "comp", "mag", "res" }
LABEL = { grav = "GRAVITY", atmo = "ATMOSPHERE", temp = "TEMPERATURE", comp = "COMPOSITION", mag = "MAGNETOSPHERE",
          res = "RESOURCES" }
RP = { grav = 10, temp = 15, atmo = 25, comp = 40, res = 60, mag = 30 }
RP_OFF_HOME = 2
SOURCES = {
  soi     = { grav = 1.0 },
  orbit   = { grav = 1.0, temp = 0.5, atmo = 0.4, res = 0.1 },
  land    = { grav = 1.0, temp = 1.0, atmo = 0.8, comp = 0.3 },
  tel30   = { temp = 0.3, atmo = 0.3 },
  tel100  = { temp = 0.6, atmo = 0.6 },
  scanner = { comp = 0.7, atmo = 0.9 },
  home    = { grav = 1, atmo = 1, temp = 1, comp = 1, mag = 1, res = 1 },
}
HOW = { soi = "visit", orbit = "orbit", land = "landing", tel30 = "telescope 0.3 m", tel100 = "telescope 1 m",
        scanner = "orbital scanner", station = "survey station", home = "home", gravimeter = "gravimeter" }
-- what fills each layer (the BODY card's "learn:" line)
LEARN = {
  grav = "enter its sphere of influence",
  atmo = "telescope · orbit · orbital scanner · landing · survey station",
  temp = "telescope · orbit · landing · survey station",
  comp = "orbital scanner · landing · survey station",
  mag = "survey station · gravimeter (3 orbits)",
  res = "orbital scanner: each orbital plane maps a band, a higher orbit a wider one · orbit",
}
SWEEP_S = 600                -- game s a telescope sweep takes
STATION = { comp = 600, temp = 6 * 3600, atmo = 6 * 3600, mag = 24 * 3600 }
SCAN_BAND = { 0.1, 1.5 }     -- the scanner's altitude band, × the body's radius
TICK = 1.0

local function clamp(x, lo, hi) if x < lo then return lo elseif x > hi then return hi end return x end

-- ── pure rules ──────────────────────────────────────────────────────────────
function newRec()
  return { L = { grav = 0, atmo = 0, temp = 0, comp = 0, mag = 0, res = 0 }, by = {}, rp = 0, rf = 0 }
end

-- Fill `rec` from a source: vals = { layer = value } (or SOURCES[src]).
-- opts = { home (the home world: no off-world bonus), mult (the Scientist's
-- study_mult) } → RP gained (float), the layers that rose, the layers that
-- reached 1 now.
function apply(rec, src, vals, opts)
  opts = opts or {}
  vals = vals or SOURCES[src] or {}
  rec.L = rec.L or {}
  rec.by = rec.by or {}
  local gained, rose, full = 0, {}, {}
  local k = (opts.home and 1 or RP_OFF_HOME) * (opts.mult or 1)
  for _, l in ipairs(LAYERS) do
    local v = vals[l]
    if v then
      v = clamp(v, 0, 1)
      local old = rec.L[l] or 0
      if v > old + 1e-9 then
        rec.L[l] = v
        rec.by[l] = HOW[src] or src
        gained = gained + (RP[l] or 0) * (v - old) * k
        rose[#rose + 1] = l
        if v >= 1 - 1e-9 and old < 1 - 1e-9 then full[#full + 1] = l end
      end
    end
  end
  return gained, rose, full
end

function surveyed(rec)
  if not (rec and rec.L) then return false end
  for _, l in ipairs(LAYERS) do if (rec.L[l] or 0) < 1 - 1e-9 then return false end end
  return true
end

-- The share of a world's ground an orbit's ground track can pass over: all of
-- it from 40° of inclination, a band from an equatorial one.
function reachOf(inc)
  return clamp(0.35 + math.abs(math.sin(inc or 0)), 0, 1)
end
-- Coverage after `dt` more seconds on an orbit of `period`: 1 − e^(−orbits)
-- of what its reach allows (one long step equals many short ones).
function coverageStep(cov, dt, period, reach)
  if not (period and period > 0) or dt <= 0 then return cov or 0 end
  local cap = clamp(reach or 1, 0, 1)
  local c = math.min(cov or 0, cap)
  local left = cap - c
  return cap - left * math.exp(-dt / period)
end
function inScanBand(alt, R) return alt >= SCAN_BAND[1] * R and alt <= SCAN_BAND[2] * R end

-- ── SURVEY II: THE SWATH GRID (expansion X7, PLAN §7.2) ─────────────────────
-- The orbital scanner maps the ground UNDER ITS TRACK: SWATH_N cells (a
-- Fibonacci sphere, the comms coverage grid's layout, body-relative), each
-- marked once a pass carries the swath's edge over its centre. RES is the
-- share marked. The worlds do not turn (the engine's rails bodies only
-- translate), so an orbit's track is one great circle and its swath one band:
-- more of the world takes another orbital plane (a plane change, or a second
-- scanner), or a higher orbit, whose swath is wider. A craft's track is
-- sampled along its conic (closed form: one long step marks what many short
-- ones do), at most one revolution a step (after that it repeats).
SWATH_N = 400
SWATH_ETA = math.rad(30)     -- the instrument's half-angle off nadir, across the track
SWATH_PAD = 0.5 * math.sqrt(4 * math.pi / 400)   -- half a cell: a band covers whole cells
GRAV_ORBITS = 3              -- orbits a Gravimeter needs for the field (mag) to be known

local cell_cache = {}
function swathCells(n)
  n = n or SWATH_N
  local g = cell_cache[n]
  if g then return g end
  g = {}
  local ga = math.pi * (3 - math.sqrt(5))
  for i = 0, n - 1 do
    local y = 1 - (i + 0.5) * 2 / n
    local r = math.sqrt(math.max(0, 1 - y * y))
    local a = ga * i
    g[i + 1] = { math.cos(a) * r, y, math.sin(a) * r }
  end
  cell_cache[n] = g
  return g
end
-- The ground half-width of the swath (central angle, radians) at alt over a
-- world of radius R: the instrument's edge ray meets the ground, or the
-- horizon when it would miss.
function swathHalf(alt, R)
  if not (R and R > 0) or alt <= 0 then return 0 end
  local k = (R + alt) / R * math.sin(SWATH_ETA)
  if k >= 1 then return math.acos(R / (R + alt)) end
  return math.asin(k) - SWATH_ETA
end
-- Mark the cells within `lam` (radians) of the unit direction u. mask[i] =
-- true; → the number newly marked.
function swathMark(mask, ux, uy, uz, lam, n)
  n = n or SWATH_N
  local cells = swathCells(n)
  local s = math.min(2, lam)
  local lo = math.max(0, math.floor((1 - (uy + s)) * n / 2 - 0.5))
  local hi = math.min(n - 1, math.ceil((1 - (uy - s)) * n / 2 - 0.5))
  local c = math.cos(lam)
  local got = 0
  for i = lo, hi do
    if not mask[i + 1] then
      local p = cells[i + 1]
      if p[1] * ux + p[2] * uy + p[3] * uz >= c then mask[i + 1] = true; got = got + 1 end
    end
  end
  return got
end
function maskCount(mask, n)
  local k = 0
  for i = 1, n or SWATH_N do if mask[i] then k = k + 1 end end
  return k
end
-- The mask as hex (4 cells a digit) for the save, and back.
function maskEncode(mask, n)
  n = n or SWATH_N
  local out = {}
  for i = 1, n, 4 do
    local v = 0
    for b = 0, 3 do if mask[i + b] then v = v + 2 ^ b end end
    out[#out + 1] = string.format("%x", v)
  end
  return table.concat(out)
end
function maskDecode(s, n)
  n = n or SWATH_N
  local mask = {}
  if type(s) ~= "string" then return mask end
  for k = 1, #s do
    local v = tonumber(s:sub(k, k), 16) or 0
    for b = 0, 3 do
      local i = (k - 1) * 4 + 1 + b
      if i <= n and math.floor(v / 2 ^ b) % 2 == 1 then mask[i] = true end
    end
  end
  return mask
end

-- Carry a body-relative state (x..vz) along its conic for dt game s, calling
-- visit(ux, uy, uz, alt) at points no more than `step` radians of true
-- anomaly apart (both ends included; at most one revolution: the track
-- repeats after that, the worlds do not turn). Ellipses only (nil else).
-- → the state at the end: x, y, z, vx, vy, vz
function swathTrack(x, y, z, vx, vy, vz, mu, dt, R, step, visit)
  local r0 = math.sqrt(x * x + y * y + z * z)
  if not (mu and mu > 0) or r0 < 1e-9 then return nil end
  local v2 = vx * vx + vy * vy + vz * vz
  local inv_a = 2 / r0 - v2 / mu
  if inv_a <= 0 then return nil end
  local a = 1 / inv_a
  local hx, hy, hz = y * vz - z * vy, z * vx - x * vz, x * vy - y * vx
  local h = math.sqrt(hx * hx + hy * hy + hz * hz)
  if h < 1e-12 then return nil end
  local rv = x * vx + y * vy + z * vz
  local ex, ey, ez = ((v2 - mu / r0) * x - rv * vx) / mu, ((v2 - mu / r0) * y - rv * vy) / mu, ((v2 - mu / r0) * z - rv * vz) / mu
  local e = math.sqrt(ex * ex + ey * ey + ez * ez)
  local Px, Py, Pz
  if e > 1e-9 then Px, Py, Pz = ex / e, ey / e, ez / e else Px, Py, Pz = x / r0, y / r0, z / r0; e = 0 end
  local Qx, Qy, Qz = (hy * Pz - hz * Py) / h, (hz * Px - hx * Pz) / h, (hx * Py - hy * Px) / h
  local p = h * h / mu
  local nu0 = math.atan2(x * Qx + y * Qy + z * Qz, x * Px + y * Py + z * Pz)
  local function E_of(nu) return 2 * math.atan2(math.sqrt(1 - e) * math.sin(nu / 2), math.sqrt(1 + e) * math.cos(nu / 2)) end
  local nmo = math.sqrt(mu / (a * a * a))
  local E0 = E_of(nu0)
  local M0 = E0 - e * math.sin(E0)
  local M1 = M0 + nmo * math.max(0, dt)
  local E1 = M1
  for _ = 1, 30 do
    local f = E1 - e * math.sin(E1) - M1
    local d = f / (1 - e * math.cos(E1))
    E1 = E1 - d
    if math.abs(d) < 1e-12 then break end
  end
  -- the anomaly walked (unwrapped): E1 − E0 revolutions turn into ν the same number of times
  local revs = math.floor((E1 - E0) / (2 * math.pi))
  local frac = (E1 - E0) - revs * 2 * math.pi
  local nu1 = 2 * math.atan2(math.sqrt(1 + e) * math.sin((E0 + frac) / 2), math.sqrt(1 - e) * math.cos((E0 + frac) / 2))
  local span = nu1 - nu0
  while span < 0 do span = span + 2 * math.pi end
  if revs >= 1 then span = 2 * math.pi end
  local function at(nu)
    local r = p / (1 + e * math.cos(nu))
    local c, s = math.cos(nu), math.sin(nu)
    return r * (c * Px + s * Qx), r * (c * Py + s * Qy), r * (c * Pz + s * Qz), r
  end
  if visit then
    local k = math.max(1, math.ceil(span / math.max(step or 0.05, 1e-3)))
    for i = 0, k do
      local px, py, pz, r = at(nu0 + span * i / k)
      visit(px / r, py / r, pz / r, r - (R or 0))
    end
  end
  local fx, fy, fz = at(nu1)
  local sv = math.sqrt(mu / p)
  local c1, s1 = math.cos(nu1), math.sin(nu1)
  return fx, fy, fz, sv * (-s1 * Px + (e + c1) * Qx), sv * (-s1 * Py + (e + c1) * Qy), sv * (-s1 * Pz + (e + c1) * Qz)
end

-- What a sweep fills: by aperture.
function sweepYield(ap)
  if (ap or 0) >= 0.9 then return SOURCES.tel100, "tel100" end
  return SOURCES.tel30, "tel30"
end

-- May this telescope sweep now? ctx = { ap, scientist (a Scientist is at
-- it), crewed (it needs one), powered, night, airless, above } → ok, why
function telescopeCan(ctx)
  if ctx.crewed and not ctx.scientist then return false, "A Scientist has to be at the eyepiece" end
  if ctx.powered == false then return false, "No power: put it on the base grid" end
  if not (ctx.night or ctx.airless) then return false, "Too bright: wait for night (or work from an airless world)" end
  if not ctx.above then return false, "Below the horizon from here" end
  return true, nil
end

-- What is true about a world (the numbers a full layer shows). w = its
-- world record, b = { mu, radius }, ores = bodyOres' list, A = atmo.lua or nil.
function truthOf(name, w, b, ores, A)
  w = type(w) == "table" and w or {}
  local R = (b and b.radius) or w.radius or 1
  local g = (b and b.mu and R > 0) and b.mu / (R * R) or 0
  local t = { name = name, g = g, gEarth = g / 9.81, R = R }
  local air = w.air
  t.air = air
  t.p0 = type(air) == "table" and air.p0 or ((w.atmo or 0) > 0.005 and (w.atmo or 0) / 0.75 or 0)
  t.verdict = A and A.verdict and A.verdict(air) or ((w.atmo or 0) > 0.005 and "AIR" or "NONE")
  t.gases = A and A.gasesText and A.gasesText(air, 3) or nil
  t.tempK = type(w.bio) == "table" and w.bio.tempK or nil
  t.type = type(w.geo) == "table" and w.geo.label or w.kind
  t.family = w.kind
  t.mag = tonumber(w.mag)
  t.ores = ores or {}
  return t
end

local function band(v, lo, hi, known)
  -- the band round v as wide as (1 − known) of [lo, hi] (never past them)
  local w = (hi - lo) * (1 - known) * 0.5
  return clamp(v - w, lo, hi), clamp(v + w, lo, hi)
end
-- A layer in words: → value text (the number, or the band), or nil when
-- nothing is known.
function layerText(l, t, v, oreLabel)
  v = v or 0
  if v <= 1e-6 then return nil end
  local full = v >= 1 - 1e-9
  if l == "grav" then
    if full then return string.format("%.2f g · %.1f m/s²", t.gEarth, t.g) end
    local a, b = band(t.gEarth, 0, 3, v)
    return string.format("about %.1f–%.1f g", a, b)
  elseif l == "atmo" then
    if t.verdict == "NONE" then return full and "none" or "no air seen" end
    if full then
      return string.format("%.2f bar · %s · %s", t.p0 or 0, t.verdict or "", t.gases or "")
    end
    if v >= 0.8 then return string.format("%.2f bar · %s", t.p0 or 0, t.gases or "") end
    if v >= 0.55 then return string.format("about %.1f bar · %s", t.p0 or 0, t.gases or "") end
    local a, b = band(t.p0 or 0, 0, 3, v)
    return string.format("air · about %.1f–%.1f bar", a, b)
  elseif l == "temp" then
    if not t.tempK then return "—" end
    if full then return string.format("%d K · %d °C", math.floor(t.tempK + 0.5), math.floor(t.tempK - 273.15 + 0.5)) end
    local a, b = band(t.tempK, 30, 800, v)
    return string.format("about %d–%d K", math.floor(a / 10 + 0.5) * 10, math.floor(b / 10 + 0.5) * 10)
  elseif l == "comp" then
    local n = #(t.ores or {})
    local show = full and n or math.floor(n * v)
    local names = {}
    local list = {}
    for _, o in ipairs(t.ores or {}) do list[#list + 1] = o end
    table.sort(list, function(a, b) return (a.w or 0) > (b.w or 0) end)
    for i = 1, math.min(show, 4) do names[#names + 1] = oreLabel and oreLabel(list[i].mat) or list[i].mat end
    local head = t.type or "rock"
    if #names == 0 then return head end
    return head .. " · " .. table.concat(names, ", ")
  elseif l == "mag" then
    if not t.mag then return "—" end
    if full then return t.mag > 0.5 and string.format("%.0f µT", t.mag) or "none to speak of" end
    local a, b = band(t.mag, 0, 70, v)
    return string.format("about %d–%d µT", math.floor(a), math.floor(b + 0.5))
  elseif l == "res" then
    local list = {}
    for _, o in ipairs(t.ores or {}) do list[#list + 1] = o end
    table.sort(list, function(a, b) return (a.w or 0) > (b.w or 0) end)
    local total = 0
    for _, o in ipairs(list) do total = total + (o.w or 0) end
    local n = math.max(1, math.floor(#list * v + 0.5))
    local out = {}
    for i = 1, math.min(n, 4, #list) do
      local o = list[i]
      out[#out + 1] = string.format("%s %d %%", oreLabel and oreLabel(o.mat) or o.mat,
        total > 0 and math.floor(100 * o.w / total + 0.5) or 0)
    end
    if #out == 0 then return "nothing found" end
    return table.concat(out, " · ") .. (full and "" or " …")
  end
  return nil
end

-- The next body an automatic telescope sweeps: the one it knows least about
-- (atmo + temp under what its aperture gives), among `cands` (names), with
-- `rec_of(name)`. → name | nil
function nextTarget(cands, rec_of, yield)
  local best, bs = nil, math.huge
  for _, n in ipairs(cands) do
    local r = rec_of(n)
    local L = (r and r.L) or {}
    local gap = math.max(0, (yield.temp or 0) - (L.temp or 0)) + math.max(0, (yield.atmo or 0) - (L.atmo or 0))
    if gap > 1e-6 then
      local s = (L.temp or 0) + (L.atmo or 0)
      if s < bs then best, bs = n, s end
    end
  end
  return best
end

-- ── the scene half ──────────────────────────────────────────────────────────
version = 0                  -- bumped on every change (the station's card, the lab)
stats = { ms = 0, ticks = 0, instruments = 0 }
lastCaption = nil            -- (probes)

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function wall() return (app and app.wallClock) and app.wallClock() or os.clock() end
local function clock()
  local dp = ref("deployables")
  if dp and dp.agencyClock then local ok, t = pcall(dp.agencyClock); if ok and type(t) == "number" then return t end end
  return (space and space.time and space.time()) or (time or 0)
end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end

local REC = {}               -- name → record (the save's, cached)
local dirty = {}
local function home_name()
  local h = save and save.get and save.get("system.home")
  local b = type(h) == "table" and type(h.bodies) == "table" and h.bodies[1]
  return (save and save.get and save.get("base.body")) or (b and b.name) or nil
end
function bodies()
  local h = save and save.get and save.get("system.home")
  local out = {}
  for _, b in ipairs(type(h) == "table" and type(h.bodies) == "table" and h.bodies or {}) do
    if type(b.name) == "string" then out[#out + 1] = b end
  end
  return out
end

-- The record of a world (made when first asked; the home world starts known).
function record(name)
  if not name then return nil end
  local r = REC[name]
  if r then return r end
  r = save and save.get and save.get("survey." .. name)
  if type(r) ~= "table" then
    r = newRec()
    if name == home_name() then
      apply(r, "home", nil, { home = true })
      r.seen, r.visited, r.landed = 0, 0, 0
    end
    dirty[name] = true
  end
  r.L = r.L or {}
  r.by = r.by or {}
  REC[name] = r
  return r
end
function isSurveyed(name) return surveyed(record(name)) end

local function flush()
  for name in pairs(dirty) do
    if save and save.set and REC[name] then save.set("survey." .. name, REC[name]) end
  end
  dirty = {}
end

local function caption(title, line)
  lastCaption = title .. " · " .. (line or "")
  -- (the first ticks after a load credit what the fleet already did, an old
  -- save's landers on other worlds among it: quietly, not a burst of captions)
  if stats.ticks < 3 then return end
  local bc = ref("big_caption")
  if bc and bc.show then pcall(bc.show, title, line or "", 4.0) end
end

-- Credit a world from a source. → RP gained (whole)
function credit(name, src, vals, opts)
  local r = record(name)
  if not r then return 0 end
  -- (X8) a telescope's sweep may see a regular shape on the ground: an
  -- abandoned base (ruins.lua), whatever the layers it adds
  if src == "tel30" or src == "tel100" then
    local RU = ref("ruins")
    if RU and RU.telescopeSwept then pcall(RU.telescopeSwept, name, src) end
  end
  opts = opts or {}
  local home = name == home_name()
  local g, rose = apply(r, src, vals, { home = home, mult = opts.mult })
  if #rose == 0 then return 0 end
  local tot = g + (r.rf or 0)
  local whole = math.floor(tot)
  r.rf = tot - whole
  r.rp = (r.rp or 0) + g
  dirty[name] = true
  version = version + 1
  if whole > 0 then
    local rs = ref("research")
    if rs and rs.addPoints then pcall(rs.addPoints, whole, string.format("survey of %s: %s", name, HOW[src] or src)) end
  end
  local C = ref("crew")
  if opts.by and C and C.credit then pcall(C.credit, opts.by, "studied", 1, { body = name }) end
  if log then log(string.format("survey: %s %s → %s (+%.1f RP)", name, HOW[src] or src, table.concat(rose, ","), g)) end
  if surveyed(r) and not r.done then
    r.done = clock()
    if not home then caption("SURVEYED", string.format("%s: every layer known", name)) end
  end
  return whole, g
end

-- ── where the agency is ──
local orbit_acc = {}         -- fid → { body, t }  (session: a full orbit, once)
local land_seen = {}         -- fid → body landed on (session)
local tel_acc = {}           -- fid → { target, t }
local part_cache = {}        -- fid → { t, scanner, telescope }
local function parts_of(fid, rec)
  local c = part_cache[fid]
  if c and c.t == rec.t and c.n == #(rec.parts or {}) then return c end
  c = { t = rec.t, n = #(rec.parts or {}), scanner = false, telescope = false, gravimeter = false }
  for _, d in ipairs(rec.parts or {}) do
    local id = tostring(d.id or "")
    if id == "scanner" then c.scanner = true end
    if id == "telescopeS" then c.telescope = true end
    if id == "gravimeter" then c.gravimeter = true end
  end
  part_cache[fid] = c
  return c
end

-- ── X7: the swath grid of each world, and the scanners' tracks ──
local SW = {}                -- name → { mask, n (marked) } (the save's r.sw, decoded once)
local sw_state = {}          -- fid → { body, x, y, z, vx, vy, vz } body-relative (session)
function swathOf(name)
  local s = SW[name]
  if s then return s end
  local r = record(name)
  local mask = maskDecode(r and r.sw, SWATH_N)
  s = { mask = mask, n = maskCount(mask, SWATH_N) }
  SW[name] = s
  return s
end
-- The share of `name`'s ground the scanners have mapped (0..1).
function swathShare(name) return swathOf(name).n / SWATH_N end
stats.swath_ms, stats.swath_pts = 0, 0
scan_tick = function(fid, body, b, px, py, pz, vx, vy, vz, dt, P, pc, live, recT)
  local w0 = wall()
  local R = b.radius
  local st = sw_state[fid]
  -- (a new pass, another world, or a live craft: start from where it is now)
  if not st or st.body ~= body or st.t ~= recT then
    st = { body = body, x = px, y = py, z = pz, vx = vx, vy = vy, vz = vz, t = recT }
    sw_state[fid] = st
  end
  local r = record(body)
  local S = swathOf(body)
  local got, pts = 0, 0
  local function visit(ux, uy, uz, alt)
    pts = pts + 1
    if pc.scanner and inScanBand(alt, R) then got = got + swathMark(S.mask, ux, uy, uz, swathHalf(alt, R) + SWATH_PAD, SWATH_N) end
  end
  local lam0 = swathHalf(math.max(len(st.x, st.y, st.z) - R, SCAN_BAND[1] * R), R) + SWATH_PAD
  local nx, ny, nz, nvx, nvy, nvz = swathTrack(st.x, st.y, st.z, st.vx, st.vy, st.vz, b.mu, dt, R, math.max(0.03, math.min(0.25, lam0 * 0.8)), visit)
  if live or not nx then
    -- (a live craft: the engine's pose is the truth for the next tick)
    st.x, st.y, st.z, st.vx, st.vy, st.vz = px, py, pz, vx, vy, vz
  else
    st.x, st.y, st.z, st.vx, st.vy, st.vz = nx, ny, nz, nvx, nvy, nvz
  end
  if got > 0 then
    S.n = S.n + got
    r.sw = maskEncode(S.mask, SWATH_N)
    dirty[body] = true
    credit(body, "scanner", { comp = SOURCES.scanner.comp, atmo = SOURCES.scanner.atmo, res = S.n / SWATH_N })
    resmap_drop(body)
  end
  -- THE GRAVIMETER: gravity at once, the field over GRAV_ORBITS orbits in its band
  if pc.gravimeter and P and P > 0 and inScanBand(len(px, py, pz) - R, R) then
    local g0 = r.gm or 0
    local g1 = math.min(1, g0 + dt / (GRAV_ORBITS * P))
    if g1 > g0 + 1e-6 then
      r.gm = g1
      dirty[body] = true
      credit(body, "gravimeter", { grav = 1, mag = g1 })
    end
  end
  stats.swath_pts = pts
  stats.swath_ms = (wall() - w0) * 1000
end

-- ── X7: THE RES_MAP — what the scanner found in each mapped cell ──
-- The veins of the patch under each marked cell (mineral_field.patchOres,
-- from the world's seed: what is really there), worked out a few cells a
-- call while the station shows the world, and kept for the session.
local RM = {}                -- name → { cells = { [i] = { ore, n } | false }, todo = { i… }, k, ver }
resmap_drop = function(name) local m = RM[name]; if m then m.stale = true end end
RESMAP_PER_CALL = 12
-- (a categorical palette for the map's discs and the card's key, in the
-- order of how many cells each ore holds: hues apart on a dark world)
RESMAP_COLORS = { { 1.00, 0.62, 0.22 }, { 0.30, 0.88, 0.84 }, { 0.78, 0.52, 1.00 }, { 1.00, 0.90, 0.30 },
                  { 1.00, 0.42, 0.42 }, { 0.52, 0.95, 0.42 }, { 0.46, 0.64, 1.00 }, { 1.00, 0.56, 0.82 } }
stats.resmap_ms = 0
-- → { { i, x, y, z (unit), ore, n (veins), c (colour) } … } for the cells
-- mapped so far, counts = { ore = cells }, done (every marked cell read),
-- colours = { ore = { r, g, b } }, order = { ore… } (most cells first)
function resMap(name, budget)
  local w0 = wall()
  local S = swathOf(name)
  local m = RM[name]
  if not m or m.stale then
    local old = m and m.cells or {}
    m = { cells = old, list = {}, counts = {}, todo = {} }
    for i = 1, SWATH_N do if S.mask[i] and old[i] == nil then m.todo[#m.todo + 1] = i end end
    m.k = 1
    m.rebuild = true
    RM[name] = m
  end
  local MF = ref("mineral_field")
  local cells = swathCells(SWATH_N)
  local n = budget or RESMAP_PER_CALL
  while n > 0 and m.k <= #m.todo do
    local i = m.todo[m.k]
    m.k = m.k + 1
    n = n - 1
    local best, bn = false, 0
    if MF and MF.patchOres then
      local ok, ores = pcall(MF.patchOres, name, cells[i][1], cells[i][2], cells[i][3])
      if ok and type(ores) == "table" then
        for ore, c in pairs(ores) do if c > bn or (c == bn and best and ore < best) then best, bn = ore, c end end
      end
    end
    m.cells[i] = best and { best, bn } or false
    m.rebuild = true
  end
  if m.rebuild then
    m.rebuild = false
    m.list, m.counts = {}, {}
    for i = 1, SWATH_N do
      local c = m.cells[i]
      if c and S.mask[i] then
        local p = cells[i]
        m.list[#m.list + 1] = { i = i, x = p[1], y = p[2], z = p[3], ore = c[1], n = c[2] }
        m.counts[c[1]] = (m.counts[c[1]] or 0) + 1
      end
    end
    m.order = {}
    for ore in pairs(m.counts) do m.order[#m.order + 1] = ore end
    table.sort(m.order, function(a, b) if m.counts[a] ~= m.counts[b] then return m.counts[a] > m.counts[b] end return a < b end)
    m.colours = {}
    for k, ore in ipairs(m.order) do m.colours[ore] = RESMAP_COLORS[(k - 1) % #RESMAP_COLORS + 1] end
    for _, e in ipairs(m.list) do e.c = m.colours[e.ore] end
  end
  stats.resmap_ms = (wall() - w0) * 1000
  return m.list, m.counts, m.k > #m.todo, m.colours or {}, m.order or {}
end

local function visit(name, t)
  local r = record(name)
  if not r then return end
  if not r.seen then r.seen = t; dirty[name] = true end
  if not r.visited then r.visited = t; dirty[name] = true; version = version + 1 end
  credit(name, "soi")
end

local function landed_on(name, t, by)
  local r = record(name)
  if not r then return end
  local first = not r.landed
  if first then r.landed = t; dirty[name] = true end
  local whole, g = credit(name, "land", nil, { by = by })
  if first and name ~= home_name() then
    caption("FIRST LANDING", string.format("%s · +%d RP", name, math.floor((g or 0) + 0.5)))
  end
end

-- The home system's star sits at the world origin (system_generator rolls
-- every planet's orbit round it), so the sunward way from a point is −p.
local function night_at(px, py, pz, ux, uy, uz)
  local l = len(px, py, pz)
  if l < 1e-6 then return false end
  return (ux * -px + uy * -py + uz * -pz) / l < -0.05
end
local function above(sx, sy, sz, ux, uy, uz, tb)
  local dx, dy, dz = tb.x - sx, tb.y - sy, tb.z - sz
  local l = len(dx, dy, dz)
  if l < 1e-6 then return false end
  return (dx * ux + dy * uy + dz * uz) / l > 0.05
end
-- Is target body tb hidden from world point (sx,sy,sz) by body ob's sphere?
local function occluded(sx, sy, sz, tb, ob)
  if not ob then return false end
  local dx, dy, dz = tb.x - sx, tb.y - sy, tb.z - sz
  local L = len(dx, dy, dz)
  if L < 1e-6 then return false end
  dx, dy, dz = dx / L, dy / L, dz / L
  local ox, oy, oz = ob.x - sx, ob.y - sy, ob.z - sz
  local tca = ox * dx + oy * dy + oz * dz
  if tca < 0 or tca > L then return false end
  local d2 = ox * ox + oy * oy + oz * oz - tca * tca
  return d2 < (ob.radius or 0) ^ 2
end

local function bodyMap()
  local B = {}
  for _, b in ipairs(space.bodies and space.bodies() or {}) do B[b.name] = b end
  return B
end

-- the active crew or craft: credit its world's SOI (and its ground)
local function presence(t)
  local wk = ref("planet_walker")
  local gm = ref("game_manager")
  -- (only once the world is up and the crew stands in it: the loading
  -- screen's camera sweep carries the avatar past other worlds)
  if not (wk and wk.onFoot) or (gm and (gm.loading or gm.curtain)) then return end
  local a = find and find("Astronaut")
  if a and space and space.dominant then
    local dom = space.dominant(a.x, a.y, a.z)
    if dom then
      visit(dom, t)
      if wk and wk.onFoot then
        local C = ref("crew")
        landed_on(dom, t, C and C.activeId and C.activeId() or nil)
      end
    end
  end
end

local function fleet_tick(t, dt, B)
  local fo = ref("flight_ops")
  if not (fo and fo.fleetList) then return end
  local recs = (fo.fleetRecords and fo.fleetRecords()) or {}
  local cands = {}
  for _, b in ipairs(bodies()) do cands[#cands + 1] = b.name end
  local seen_f = {}
  for _, f in ipairs(fo.fleetList()) do
    local fid = f.fid
    seen_f[fid] = true
    local rec = recs[fid] or {}
    local body = f.body
    local v = fo.liveOf and fo.liveOf(fid) or nil
    local px, py, pz, vx, vy, vz
    if v and v.node and v.node.valid ~= false and space.dominant then
      local n = v.node
      body = space.dominant(n.x, n.y, n.z) or body
      local b = B[body]
      if b then px, py, pz, vx, vy, vz = n.x - b.x, n.y - b.y, n.z - b.z, n.vx or 0, n.vy or 0, n.vz or 0 end
    elseif rec.x then
      px, py, pz, vx, vy, vz = rec.x, rec.y, rec.z, rec.vx or 0, rec.vy or 0, rec.vz or 0
    end
    local b = body and B[body]
    if body and b then
      visit(body, t)
      if f.landed then
        if land_seen[fid] ~= body then land_seen[fid] = body; landed_on(body, t) end
        orbit_acc[fid] = nil
        sw_state[fid] = nil
      else
        land_seen[fid] = nil
        -- a full orbit round it, once (a closed conic above the ground)
        if f.pe and f.pe > 0 and f.ap and px then
          local a = b.radius + (f.pe + f.ap) / 2
          local P = 2 * math.pi * math.sqrt(a * a * a / math.max(b.mu or 1, 1e-9))
          local acc = orbit_acc[fid]
          if not acc or acc.body ~= body then acc = { body = body, t = 0 }; orbit_acc[fid] = acc end
          acc.t = acc.t + dt
          if acc.t >= P and not acc.done then
            acc.done = true
            local r = record(body)
            if r and not r.orbited then r.orbited = t; dirty[body] = true end
            credit(body, "orbit")
          end
          -- THE ORBITAL SCANNER and THE GRAVIMETER (parts; powered, in their
          -- band, heard by the ground). X7: the scanner marks the swath grid
          -- under its track (swathTrack, carried along the conic from where
          -- it was a tick ago); the gravimeter learns the field in 3 orbits.
          local pc = parts_of(fid, rec)
          local powered = f.link and (f.cap or 0) > 0 and (f.charge or 0) > 0
          if (pc.scanner or pc.gravimeter) and powered then
            scan_tick(fid, body, b, px, py, pz, vx, vy, vz, dt, P, pc, v ~= nil, rec.t)
          else
            sw_state[fid] = nil
          end
        end
      end
      -- THE SPACE TELESCOPE (a part): sweeps the least-known world in its sky
      local pc = parts_of(fid, rec)
      if pc.telescope and px and f.link and (f.cap or 0) > 0 and (f.charge or 0) > 0 and (not f.landed or (b and (B[body] and true))) then
        local sx, sy, sz = b.x + px, b.y + py, b.z + pz
        local acc = tel_acc[fid]
        local others = {}
        for _, n in ipairs(cands) do if n ~= body and B[n] and not occluded(sx, sy, sz, B[n], b) then others[#others + 1] = n end end
        local y = SOURCES.tel30
        if not acc or not acc.target or not B[acc.target] then
          local tg = nextTarget(others, record, y)
          acc = { target = tg, t = 0 }
          tel_acc[fid] = acc
        end
        if acc.target and B[acc.target] and not occluded(sx, sy, sz, B[acc.target], b) then
          acc.t = acc.t + dt
          if acc.t >= SWEEP_S then
            credit(acc.target, "tel30", y)
            local r = record(acc.target)
            if r and not r.seen then r.seen = t end
            tel_acc[fid] = nil
          end
        end
      end
    end
  end
  for fid in pairs(orbit_acc) do if not seen_f[fid] then orbit_acc[fid] = nil end end
  for fid in pairs(sw_state) do if not seen_f[fid] then sw_state[fid] = nil end end
end

-- ── the kit's instruments (structures) ──
local inst = { ver = -1, list = {} }
local function defs(id) local pb = ref("parts_base"); return pb and pb.partInfo and pb.partInfo(id) or nil end
local function instruments()
  local ST = ref("structures")
  if not (ST and ST.list) then return inst.list end
  if ST.version == inst.ver then return inst.list end
  inst.ver = ST.version
  local out = {}
  for _, rec in ipairs(ST.list()) do
    for _, p in ipairs(rec.bp or {}) do
      local d = defs(p.id)
      if d and d.survey then out[#out + 1] = { sid = rec.id, uid = p.uid, b = rec.b, kind = d.survey.kind, ap = d.survey.ap,
                                               crewed = d.survey.crew, label = d.label, rec = rec, part = p } end
    end
  end
  inst.list = out
  stats.instruments = #out
  return out
end

local function grid_powered(sid)
  local BG = ref("base_grid")
  local g = BG and BG.gridOfStruct and BG.gridOfStruct(sid)
  if not g then return false end
  local M = BG.model and BG.model(g.id)
  local real = #(g.bases or {}) > 0 or (M and ((M.sources or 0) > 0 or (M.C or 0) > 0))
  if not real then return false end
  local s = BG.status and BG.status(g.id)
  return not (s and (s.short or 0) > 0 and (s.stored or 0) <= 0)
end

local function stations_tick(t, dt)
  local per = {}
  for _, it in ipairs(instruments()) do
    if it.kind == "station" and it.b then per[it.b] = true end
  end
  for name in pairs(per) do
    local r = record(name)
    if r then
      r.sta = (r.sta or 0) + dt
      dirty[name] = true
      credit(name, "station", { comp = r.sta / STATION.comp, temp = r.sta / STATION.temp, atmo = r.sta / STATION.atmo,
                                mag = r.sta / STATION.mag })
    end
  end
end

-- A kit telescope's world pose and up (this frame's body read).
local function site_of(it, B)
  local ST = ref("structures")
  local b = B[it.b]
  if not (ST and ST.partPose and b) then return nil end
  local ok, x, y, z = pcall(ST.partPose, it.rec, it.part)
  if not ok or not x then
    x, y, z = it.rec.x or 0, it.rec.y or 0, it.rec.z or 0
  elseif type(x) == "table" then
    x, y, z = x.x or x[1], x.y or x[2], x.z or x[3]
  end
  -- (partPose answers body-relative; its up is the radial)
  local l = len(x, y, z)
  if l < 1e-6 then return nil end
  return b.x + x, b.y + y, b.z + z, x / l, y / l, z / l, b
end

-- Can kit telescope `it` sweep body `target` now? → ok, why
function canSweep(it, target, B)
  B = B or bodyMap()
  local sx, sy, sz, ux, uy, uz, b = site_of(it, B)
  if not sx then return false, "It isn't standing anywhere" end
  local tb = B[target]
  if not tb then return false, "No such world" end
  local wk, C = ref("planet_walker"), ref("crew")
  local a = find and find("Astronaut")
  local sci = false
  if a and wk and wk.onFoot and len(a.x - sx, a.y - sy, a.z - sz) <= 5 and C and C.role and C.activeId then
    local okr, role = pcall(C.role, C.activeId())
    sci = okr and role == "scientist"
  end
  local cl = ref("climate")
  local w = cl and cl.worldOf and cl.worldOf(it.b)
  return telescopeCan({ ap = it.ap, crewed = it.crewed, scientist = sci, powered = grid_powered(it.sid),
    night = night_at(sx, sy, sz, ux, uy, uz), airless = not (type(w) == "table" and (w.atmo or 0) >= 0.05),
    above = above(sx, sy, sz, ux, uy, uz, tb) })
end

local function jobs() local j = save and save.get and save.get("survey.jobs"); return type(j) == "table" and j or {} end
function startSweep(it, target)
  local B = bodyMap()
  local ok, why = canSweep(it, target, B)
  if not ok then return false, why end
  local J = jobs()
  for _, j in ipairs(J) do if j.sid == it.sid and j.uid == it.uid then return false, "It is already sweeping " .. tostring(j.b) end end
  local C = ref("crew")
  local id = C and C.activeId and C.activeId() or nil
  local m = (C and C.perk and id) and (C.perk(id, "study_mult") or 1) or 1
  J[#J + 1] = { sid = it.sid, uid = it.uid, b = target, t0 = clock(), ap = it.ap or 0.3, by = id, m = m }
  save.set("survey.jobs", J)
  version = version + 1
  local r = record(target)
  if r and not r.seen then r.seen = clock(); dirty[target] = true end
  return true
end
local function jobs_tick(t)
  local J = jobs()
  if #J == 0 then return end
  local keep, changed = {}, false
  for _, j in ipairs(J) do
    if t - (j.t0 or t) >= SWEEP_S then
      local y, src = sweepYield(j.ap)
      credit(j.b, src, y, { mult = j.m, by = j.by })
      changed = true
    else
      keep[#keep + 1] = j
    end
  end
  if changed then save.set("survey.jobs", keep); version = version + 1 end
end
function jobOf(sid, uid)
  for _, j in ipairs(jobs()) do if j.sid == sid and j.uid == uid then return j end end
  return nil
end

-- ── the right-click rows on a kit telescope ──
local function provider(t, ctx)
  if not (t and t.node) then return {} end
  local ST = ref("structures")
  if not (ST and ST.partOfNode) then return {} end
  local FB = ref("field_builder")
  local rec, part
  if FB and FB.pickTarget then rec, part = FB.pickTarget(t) else rec, part = ST.partOfNode(t.node) end
  if not part then return {} end
  local d = defs(part.id)
  if not (d and d.survey) then return {} end
  local it = { sid = rec.id, uid = part.uid, b = rec.b, kind = d.survey.kind, ap = d.survey.ap, crewed = d.survey.crew,
               rec = rec, part = part }
  local out, G = {}, "Survey"
  if it.kind == "station" then
    out[#out + 1] = { id = "sv_sta", type = "info", label = "Survey Station", group = G, value = function()
      local r = record(rec.b)
      local s = r and r.sta or 0
      return string.format("%s · %.1f h of readings", rec.b or "?", s / 3600)
    end }
    return out
  end
  out[#out + 1] = { id = "sv_job", type = "info", label = "Sweep", group = G, value = function()
    local j = jobOf(it.sid, it.uid)
    if not j then return "idle" end
    return string.format("%s · %d %%", j.b, math.floor(100 * math.min(1, (clock() - j.t0) / SWEEP_S)))
  end }
  local B = bodyMap()
  for _, b in ipairs(bodies()) do
    if b.name ~= rec.b then
      local name = b.name
      out[#out + 1] = { id = "sv_" .. name, type = "action", group = G, label = "Sweep " .. name,
        hint = function()
          local ok, why = canSweep(it, name)
          if not ok then return why end
          local r = record(name)
          return string.format("atmo %d %% · temp %d %%", math.floor(100 * (r.L.atmo or 0)), math.floor(100 * (r.L.temp or 0)))
        end,
        act = function() return startSweep(it, name) end }
    end
  end
  return out
end

-- ── the record for panels ──
-- One row per layer: { layer, label, v (0..1), text (or nil), learn, by }
local ROWC = {}              -- name → { v, t, out, truth } (the card asks 5 times a second)
function rows(name)
  local r = record(name)
  if not r then return {} end
  local c = ROWC[name]
  local now = time or 0
  if c and c.v == version and now - c.t < 2.0 then return c.out, r, c.truth end
  local cl = ref("climate")
  local w = (cl and cl.worldOf and cl.worldOf(name)) or (save and save.get and save.get("world." .. name)) or {}
  local b = space and space.body and space.body(name)
  local M = ref("materials")
  local ores = (M and M.bodyOres) and M.bodyOres(name) or {}
  local A = ref("atmo")
  local t = truthOf(name, w, b, ores, A)
  local lbl = M and M.label and function(m) local ok, s = pcall(M.label, m); return ok and s or m end or nil
  local out = {}
  for _, l in ipairs(LAYERS) do
    local v = r.L[l] or 0
    out[#out + 1] = { layer = l, label = LABEL[l], v = v, text = layerText(l, t, v, lbl), learn = LEARN[l], by = r.by[l] }
  end
  ROWC[name] = { v = version, t = now, out = out, truth = t }
  return out, r, t
end

-- (probes) credit a source by hand
function creditNow(name, src, vals) return credit(name, src, vals) end
function reset() REC = {}; dirty = {}; orbit_acc = {}; land_seen = {}; tel_acc = {}; part_cache = {}; inst = { ver = -1, list = {} }; SW = {}; sw_state = {}; RM = {} end

local tick_t, tick_c = -10, nil
local reg_on = false
function update(node, dt)
  if not reg_on then
    local reg = ref("context_registry")
    if reg and reg.register then reg.register("prop", provider, { id = "survey", order = 9 }); reg_on = true end
  end
  local now = time or 0
  if now - tick_t < TICK then return end
  tick_t = now
  if not (save and save.get and save.get("system.home")) then return end
  local w0 = wall()
  local c = clock()
  local gdt = tick_c and math.max(0, math.min(c - tick_c, 86400)) or 0
  tick_c = c
  local B = bodyMap()
  pcall(presence, c)
  pcall(fleet_tick, c, gdt, B)
  if gdt > 0 then pcall(stations_tick, c, gdt) end
  pcall(jobs_tick, c)
  flush()
  stats.ms = (wall() - w0) * 1000
  stats.ticks = stats.ticks + 1
end
