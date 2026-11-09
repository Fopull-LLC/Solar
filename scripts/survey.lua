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
--             res by COVERAGE: 1 − e^(−orbits) of the ground under its
--             track, times its REACH (an orbit inclined 40° or more sees all
--             of it; an equatorial one a band): coverageStep
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
--   cov (scanner coverage 0..1) }
-- survey.jobs = { { sid, uid, b (target), t0, ap, by (member id), m (mult) } }
--
-- When it runs: a 1 Hz tick on the agency clock; the structures' instruments
-- are found again only when structures.version moves. Nothing per frame.
--
-- Pure (tests/smoke_survey.lua): LAYERS, SOURCES, RP, newRec, apply,
-- surveyed, coverageStep, reachOf, inScanBand, telescopeCan, sweepYield,
-- truthOf, layerText, nextTarget.

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
        scanner = "orbital scanner", station = "survey station", home = "home" }
-- what fills each layer (the BODY card's "learn:" line)
LEARN = {
  grav = "enter its sphere of influence",
  atmo = "telescope · orbit · orbital scanner · landing · survey station",
  temp = "telescope · orbit · landing · survey station",
  comp = "orbital scanner · landing · survey station",
  mag = "survey station",
  res = "orbital scanner (several orbits, inclined) · orbit",
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
  c = { t = rec.t, n = #(rec.parts or {}), scanner = false, telescope = false }
  for _, d in ipairs(rec.parts or {}) do
    local id = tostring(d.id or "")
    if id == "scanner" then c.scanner = true end
    if id == "telescopeS" then c.telescope = true end
  end
  part_cache[fid] = c
  return c
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
          -- THE ORBITAL SCANNER (a part; powered, in its band, heard by the ground)
          local pc = parts_of(fid, rec)
          if pc.scanner and f.link and (f.cap or 0) > 0 and (f.charge or 0) > 0 then
            local alt = len(px, py, pz) - b.radius
            if inScanBand(alt, b.radius) then
              local hx, hy, hz = py * vz - pz * vy, pz * vx - px * vz, px * vy - py * vx
              local hl = len(hx, hy, hz)
              -- (the body's spin axis is the frame's +Y: the orbit's tilt from it)
              local inc = hl > 1e-9 and math.acos(clamp(hy / hl, -1, 1)) or 0
              local r = record(body)
              local cov = coverageStep(r.cov or 0, dt, P, reachOf(inc))
              if cov > (r.cov or 0) + 1e-6 then
                r.cov = cov
                dirty[body] = true
                credit(body, "scanner", { comp = SOURCES.scanner.comp, atmo = SOURCES.scanner.atmo, res = cov })
              end
            end
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
function reset() REC = {}; dirty = {}; orbit_acc = {}; land_seen = {}; tel_acc = {}; part_cache = {}; inst = { ver = -1, list = {} } end

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
