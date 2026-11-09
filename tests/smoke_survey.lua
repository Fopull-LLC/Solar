-- SMOKE: THE SURVEY (expansion X1; scripts/survey.lua), pure and against stubs.
--
--   * each SOURCE fills its layers (soi, orbit, landing, telescopes 0.3 m and
--     1 m, the orbital scanner, the survey station), a value only rises, and
--     RP come for the rise only: a layer filled to 1 earns RP[layer] × 2 off
--     the home world, once, × the Scientist's study_mult on a sweep;
--   * the scanner's coverage: one long step equals many short (1e-6), three
--     orbits reach 95 % of what the orbit's tilt reaches (an equatorial orbit
--     a band, 40° all of it); its altitude band;
--   * telescopes: the Scientist, the power, night or no air, the horizon;
--   * the BODY card's words: a band that narrows as a layer fills, the number
--     when it is full; SURVEYED when every layer is; the home starts known;
--   * THE SCENE HALF: visiting, a full orbit and a landing (with the FIRST
--     LANDING caption) credit the world and the lab's RP (whole points, the
--     fraction carried); a satellite with the scanner part maps the ground in
--     orbit, one with the telescope part sweeps the least-known world; a kit
--     telescope needs a Scientist and finishes on the agency clock; the
--     Survey Station's readings fill over a day; the record survives a reload;
--   * THE STATION: the worlds are entries in a WORLDS group, in roster order,
--     with their survey summary.
--
--   luajit solar/tests/smoke_survey.lua

local failed, count = 0, 0
local function check(desc, ok, detail)
  count = count + 1
  if not ok then
    failed = failed + 1
    print("✗ " .. desc .. (detail ~= nil and ("   [" .. tostring(detail) .. "]") or ""))
  end
end
local function near(a, b, e) return a and b and math.abs(a - b) <= (e or 1e-9) end
local function loadlib(path, extra)
  local e = setmetatable(extra or {}, { __index = _G })
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, e)
  f()
  return e
end

local SV = loadlib("survey.lua")

-- ── sources and RP ──────────────────────────────────────────────────────────
do
  local r = SV.newRec()
  local g = SV.apply(r, "soi")
  check("soi: gravity known, 10 RP × 2 off home", r.L.grav == 1 and near(g, 20), g)
  check("…and again: nothing", SV.apply(r, "soi") == 0)
  g = SV.apply(r, "orbit")
  check("orbit: temp 0.5, atmo 0.4, res 0.1", near(r.L.temp, 0.5) and near(r.L.atmo, 0.4) and near(r.L.res, 0.1))
  check("…RP for the rise only", near(g, 2 * (15 * 0.5 + 25 * 0.4 + 60 * 0.1)), g)
  g = SV.apply(r, "tel30")
  check("a 0.3 m sweep after an orbit adds nothing (it knows less)", g == 0 and near(r.L.temp, 0.5))
  g = SV.apply(r, "tel100", nil, { mult = 1.5 })
  check("a 1 m sweep: temp and atmo to 0.6, × the Scientist's 1.5", near(r.L.temp, 0.6) and near(r.L.atmo, 0.6)
    and near(g, 2 * 1.5 * (15 * 0.1 + 25 * 0.2)), g)
  local _, rose, full = SV.apply(r, "land")
  check("a landing: temp 1 (full), atmo 0.8, comp 0.3", r.L.temp == 1 and near(r.L.atmo, 0.8) and near(r.L.comp, 0.3)
    and #full == 1 and full[1] == "temp", table.concat(rose, ","))
  check("not yet surveyed", not SV.surveyed(r))
  -- filling everything earns exactly RP × 2 in all
  local r2, total = SV.newRec(), 0
  for _, src in ipairs({ "soi", "orbit", "tel30", "land", "scanner" }) do total = total + SV.apply(r2, src) end
  total = total + SV.apply(r2, "station", { comp = 1, temp = 1, atmo = 1, mag = 1 })
  total = total + SV.apply(r2, "scanner", { res = 1 })
  local want = 0
  for _, l in ipairs(SV.LAYERS) do want = want + SV.RP[l] * 2 end
  check("every layer to 1: surveyed", SV.surveyed(r2))
  check(string.format("…for exactly the layers' RP × 2 (%.1f)", total), near(total, want, 1e-6), want)
  local r3 = SV.newRec()
  check("on the home world no × 2", near(SV.apply(r3, "soi", nil, { home = true }), 10))
  check("who filled each layer is kept", r2.by.res == "orbital scanner" and r2.by.grav == "visit", r2.by.res)
end

-- ── the scanner's coverage ──────────────────────────────────────────────────
do
  local P = 1200
  local one = SV.coverageStep(0, 3 * P, P, 1)
  local many = 0
  for _ = 1, 3000 do many = SV.coverageStep(many, 3 * P / 3000, P, 1) end
  check("coverage: one step equals 3,000 to 1e-6", near(one, many, 1e-6), string.format("%.9f %.9f", one, many))
  check("three orbits: 95 % of the ground", near(one, 1 - math.exp(-3), 1e-9), one)
  check("an equatorial orbit reaches a band (35 %)", near(SV.reachOf(0), 0.35))
  check("40° reaches it all", SV.reachOf(math.rad(40)) >= 0.99, SV.reachOf(math.rad(40)))
  check("equatorial: coverage stops at its reach", SV.coverageStep(0, 50 * P, P, SV.reachOf(0)) <= 0.35 + 1e-9)
  check("coverage never falls", SV.coverageStep(0.8, 10, P, 0.35) == 0.35 or SV.coverageStep(0.8, 10, P, 0.35) >= 0.35)
  check("the band: 0.1–1.5 radii up", SV.inScanBand(100, 800) and not SV.inScanBand(50, 800) and not SV.inScanBand(1300, 800))
end

-- ── telescopes ──────────────────────────────────────────────────────────────
do
  local base = { ap = 0.3, crewed = true, scientist = true, powered = true, night = true, airless = false, above = true }
  local function with(k, v) local c = {} for a, b in pairs(base) do c[a] = b end c[k] = v return c end
  check("a Scientist at a powered telescope at night, the target up: yes", SV.telescopeCan(base))
  local ok, why = SV.telescopeCan(with("scientist", false))
  check("no Scientist: no (" .. tostring(why) .. ")", not ok and why:find("Scientist"))
  ok, why = SV.telescopeCan(with("powered", false))
  check("no power: no", not ok and why:find("power"))
  ok, why = SV.telescopeCan(with("night", false))
  check("daylight under air: no", not ok and why:find("night"))
  check("daylight on an airless world: yes", SV.telescopeCan({ ap = 0.3, crewed = true, scientist = true, powered = true, night = false, airless = true, above = true }))
  ok, why = SV.telescopeCan(with("above", false))
  check("below the horizon: no", not ok and why:find("horizon"))
  check("the 1 m sweep yields more than the 0.3 m", select(2, SV.sweepYield(1.0)) == "tel100" and select(2, SV.sweepYield(0.3)) == "tel30")
  local recs = { A = { L = { temp = 0.6, atmo = 0.6 } }, B = { L = { temp = 0.0, atmo = 0.0 } }, C = { L = { temp = 0.3, atmo = 0.1 } } }
  check("an automatic sweep takes the least-known world", SV.nextTarget({ "A", "B", "C" }, function(n) return recs[n] end, SV.SOURCES.tel30) == "B")
  recs.B.L.temp, recs.B.L.atmo, recs.C.L.temp, recs.C.L.atmo = 0.3, 0.3, 0.3, 0.3
  check("…and none once the 0.3 m has nothing left to add", SV.nextTarget({ "A", "B", "C" }, function(n) return recs[n] end, SV.SOURCES.tel30) == nil)
end

-- ── the card's words ────────────────────────────────────────────────────────
do
  local A = loadlib("atmo.lua")
  local w = { atmo = 0.75, air = A.roll({ type = "verdant", atmo = 0.75, home = true }), bio = { tempK = 288 },
              geo = { label = "Verdant wetland" }, kind = "canyon", mag = 46 }
  local t = SV.truthOf("Naolol", w, { mu = 9.81 * 800 * 800, radius = 800 }, { { mat = "iron", w = 3 }, { mat = "copper", w = 1 } }, A)
  check("gravity full: the number", SV.layerText("grav", t, 1):find("1.00 g", 1, true) ~= nil, SV.layerText("grav", t, 1))
  local a = SV.layerText("grav", t, 0.3)
  local b = SV.layerText("grav", t, 0.8)
  local function width(s) local lo, hi = s:match("about ([%d%.]+)–([%d%.]+)"); return tonumber(hi) - tonumber(lo) end
  check("gravity partly known: a band that narrows as it fills (" .. a .. " → " .. b .. ")", width(a) > width(b))
  check("nothing known: no text", SV.layerText("temp", t, 0) == nil)
  check("air full: pressure, verdict, gases", SV.layerText("atmo", t, 1):find("BREATHABLE", 1, true) ~= nil, SV.layerText("atmo", t, 1))
  check("temperature full: K and °C", SV.layerText("temp", t, 1):find("288 K", 1, true) ~= nil)
  check("magnetosphere full: µT", SV.layerText("mag", t, 1):find("46 µT", 1, true) ~= nil)
  check("resources full: the ores by share", SV.layerText("res", t, 1):find("iron 75 %", 1, true) ~= nil, SV.layerText("res", t, 1))
  check("composition: the type and its ores", SV.layerText("comp", t, 1):find("Verdant", 1, true) == 1)
end

-- ── the scene half against stubs ────────────────────────────────────────────
local store = {}
local clockT = 1000
local points, captions, credits = 0, {}, {}
local bodies = {
  { name = "Home", x = 0, y = 0, z = 0, radius = 800, mu = 9.81 * 800 * 800, soi = 30000 },
  { name = "Moon", x = 60000, y = 0, z = 0, radius = 200, mu = 1.6 * 200 * 200, soi = 4000 },
  { name = "Far", x = 400000, y = 0, z = 0, radius = 600, mu = 7 * 600 * 600, soi = 20000 },
}
local B = {}
for _, b in ipairs(bodies) do B[b.name] = b end
store["system.home"] = { star = "Sun", bodies = { { name = "Home" }, { name = "Moon", parent = "Home" }, { name = "Far" } } }
store["base.body"] = "Home"
local astro = { name = "Astronaut", x = 0, y = 801, z = 0 }
local walker = { onFoot = true, valid = true }
local fleet, recs, live = {}, {}, {}
local ST = { valid = true, version = 1, list = function() return {} end }
local SCR = {
  deployables = { valid = true, agencyClock = function() return clockT end },
  research = { valid = true, addPoints = function(n) points = points + n; return n end },
  big_caption = { valid = true, show = function(t, s) captions[#captions + 1] = t .. " · " .. s end },
  crew = { valid = true, activeId = function() return 7 end, credit = function(id, c) credits[#credits + 1] = c end,
           role = function() return "scientist" end, perk = function() return 2.0 end },
  planet_walker = walker,
  flight_ops = { valid = true, fleetList = function() return fleet end, fleetRecords = function() return recs end,
                 liveOf = function(fid) return live[fid] end },
  structures = ST,
  climate = { valid = true, worldOf = function(n) return { atmo = n == "Home" and 0.75 or 0 } end },
  base_grid = { valid = true, gridOfStruct = function() return { id = 1, bases = { 1 } } end, model = function() return {} end,
                status = function() return {} end },
}
local E = loadlib("survey.lua", {
  save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
  findScript = function(k) return SCR[k] end,
  find = function(n) return n == "Astronaut" and astro or nil end,
  space = { bodies = function() return bodies end, body = function(n) return B[n] end,
            dominant = function(x, y, z)
              for _, b in ipairs(bodies) do
                if math.sqrt((x - b.x) ^ 2 + (y - b.y) ^ 2 + (z - b.z) ^ 2) < b.soi then return b.name end
              end
            end },
  log = function() end,
})
local function tick(gsecs, n)
  for _ = 1, (n or 1) do
    E.time = (E.time or 0) + 1.01
    clockT = clockT + (gsecs or 1)
    E.update(nil, 1)
  end
end
E.time = 5
tick(1)
local home = E.record("Home")
check("the home world starts SURVEYED", E.isSurveyed("Home") and home.L.res == 1)
check("…and is saved", type(store["survey.Home"]) == "table")
check("a far world starts unknown", E.record("Far").L.grav == 0)
-- a craft in orbit round the Moon with the scanner part, linked and powered
local R = 200 + 150
local v = math.sqrt(bodies[2].mu / R)
local P = 2 * math.pi * R / v
fleet[1] = { fid = "c1", body = "Moon", landed = false, pe = 150, ap = 150, link = true, cap = 100, charge = 80 }
-- (an orbit inclined 60° from the Moon's equator: y is the spin axis)
local inc = math.rad(60)
recs.c1 = { t = 1, parts = { { id = "probe" }, { id = "scanner" } }, x = R, y = 0, z = 0,
            vx = 0, vy = v * math.sin(inc), vz = v * math.cos(inc) }
astro.x, astro.y = 0, 801
points = 0
tick(P / 10, 10)
local moon = E.record("Moon")
check("the Moon: visited by the craft (gravity known)", moon.L.grav == 1 and moon.visited ~= nil)
check("…a full orbit: temp, atmo, orbited", moon.orbited ~= nil and moon.L.temp >= 0.5, moon.L.temp)
check("…the scanner maps it: comp 0.7, atmo 0.9", near(moon.L.comp, 0.7) and near(moon.L.atmo, 0.9), moon.L.comp)
check(string.format("…res %.2f after one orbit (1 − e^−1 = 0.63)", moon.L.res), near(moon.L.res, 1 - math.exp(-1), 0.02), moon.L.res)
tick(P / 10, 20)
check(string.format("…and %.2f after three (0.95)", moon.L.res), near(moon.L.res, 1 - math.exp(-3), 0.02), moon.L.res)
check("the lab got whole RP for it", points > 50 and points == math.floor(points), points)
check("…and the fraction is carried", moon.rf >= 0 and moon.rf < 1)
-- no link: the scanner waits
local r0 = moon.L.res
fleet[1].link = false
tick(P / 10, 10)
check("no link home: the scanner adds nothing", moon.L.res == r0)
fleet[1].link = true
-- a landing: FIRST LANDING
fleet[1].landed = true
tick(1)
check("a landing: temp 1, comp kept at least 0.3", moon.L.temp == 1 and moon.landed ~= nil)
check("…with the FIRST LANDING caption", #captions > 0 and captions[#captions]:find("FIRST LANDING · Moon", 1, true) ~= nil, captions[#captions])
-- the telescope part on a craft near home sweeps Far
fleet[1] = nil
recs.c1 = nil
fleet[1] = { fid = "c2", body = "Home", landed = false, pe = 2000, ap = 2000, link = true, cap = 100, charge = 100 }
recs.c2 = { t = 1, parts = { { id = "probe" }, { id = "telescopeS" } }, x = 0, y = 0, z = 2800, vx = 0, vy = 0, vz = 0 }
local far0 = E.record("Far").L.atmo
tick(60, 11)
check("the space telescope sweeps the least-known world (Far) in ten minutes", E.record("Far").L.atmo > far0 and near(E.record("Far").L.atmo, 0.3),
  E.record("Far").L.atmo)
check("…and Far is now seen", E.record("Far").seen ~= nil)
-- a kit telescope: a Scientist, and the agency clock
fleet[1] = nil
local trec = { id = 9, b = "Home", x = 0, y = 800, z = 0, bp = { { uid = 1, id = "telescope.steel" } } }
local it = { sid = 9, uid = 1, b = "Home", kind = "telescope", ap = 1.0, crewed = true, rec = trec, part = trec.bp[1] }
ST.partPose = function(r, p) return 800, 0, 0 end
-- night at home: the star is at the origin, so stand on the far side of it
B.Home.x, B.Home.y, B.Home.z = 0, 0, 0
bodies[1].x = 100000
B.Home = bodies[1]
astro.x, astro.y, astro.z = 100801, 0, 0
local ok, why = E.canSweep(it, "Far")
check("a kit telescope at night with a Scientist beside it may sweep Far", ok, why)
walker.onFoot = false
ok, why = E.canSweep(it, "Far")
check("…not without the Scientist there", not ok and why:find("Scientist"), why)
walker.onFoot = true
check("…start it", E.startSweep(it, "Far") == true)
check("…not twice", select(1, E.startSweep(it, "Far")) == false)
local before = E.record("Far").L.atmo
tick(60, 5)
check("…not done after five minutes", E.record("Far").L.atmo == before)
tick(60, 6)
check("…done after ten: the 1 m spectrograph, atmo 0.6", near(E.record("Far").L.atmo, 0.6), E.record("Far").L.atmo)
check("…credited to the Scientist", credits[#credits] == "studied")
check("…and the job is gone", #store["survey.jobs"] == 0)
-- the Survey Station on the Moon
ST.version = 2
ST.list = function() return { { id = 11, b = "Moon", x = 0, y = 200, z = 0, bp = { { uid = 1, id = "surveyStation.steel" } } } } end
SCR.parts_base = { valid = true, partInfo = function(id) if id == "surveyStation.steel" then return { label = "Survey Station", survey = { kind = "station" } } end end }
tick(600, 1)
check("the Survey Station: the interior after ten minutes (comp 1)", moon.L.comp == 1, moon.L.comp)
tick(3600, 24)
check("…and the field after a day (mag 1)", moon.L.mag == 1 and moon.L.atmo == 1, moon.L.mag)
check("the Moon is SURVEYED now? (res still short of 1)", not E.isSurveyed("Moon") and moon.L.res < 1)
E.creditNow("Moon", "scanner", { res = 1 })
check("…and with the ground mapped it is", E.isSurveyed("Moon") and captions[#captions]:find("SURVEYED", 1, true) ~= nil)
-- a reload: the record comes back from the save
local saved_moon = store["survey.Moon"]
E.reset()
check("a reload keeps the record", E.record("Moon").L.mag == 1 and E.isSurveyed("Moon") and saved_moon ~= nil)
-- the card's rows
local rows = E.rows("Moon")
check("six rows for the card", #rows == 6 and rows[1].layer == "grav" and rows[1].learn ~= nil)

-- ── the station: the WORLDS group ───────────────────────────────────────────
do
  local FVE = loadlib("fleet_view.lua", {
    time = 0,
    save = { get = function(k) return store[k] end, set = function() end },
    findScript = function(k) return k == "survey" and E or nil end,
    space = { time = function() return 0 end, body = function(n) return B[n] end, bodies = function() return bodies end },
  })
  local S = FVE.snapshot(true)
  local w = {}
  for _, e in ipairs(S.entries) do if e.kind == "body" then w[#w + 1] = e end end
  check("three worlds in the snapshot", #w == 3, #w)
  check("…in the WORLDS group, in roster order", w[1] and w[1].group == "WORLDS" and w[1].name == "Home" and w[2].name == "Moon" and w[3].name == "Far")
  check("…the home: surveyed", w[1].surveyed and w[1].sub:find("surveyed", 1, true) ~= nil, w[1].sub)
  check("…a moon: 'moon of Home'", w[2].sub:find("moon of Home", 1, true) ~= nil, w[2].sub)
  check("…Far: how much is known", w[3].sub:find("% known", 1, true) ~= nil and w[3].num:find("%", 1, true) ~= nil, w[3].sub)
  check("…a body's class is its own (no kind key hides it but All)", FVE.kindClass(w[1]) == "world"
    and not FVE.passes(w[1], { kind = "craft" }) and FVE.passes(w[1], { kind = "all" }))
  check("…a glyph", FVE.GLYPHS.body ~= nil)
end

if failed == 0 then
  print(string.format("✓ survey: %d checks — sources and RP, scanner coverage, telescopes, the card, the scene half, the WORLDS group", count))
  os.exit(0)
else
  print(string.format("✗ %d of %d checks failed", failed, count))
  os.exit(1)
end
