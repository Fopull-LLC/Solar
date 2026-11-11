-- SMOKE: G4, dust on the panels (PLAN scenarios2 §2 G4): electronics'
-- soilFactor / skyFactor / dustStep, solarOutput's soil factor, and base_grid
-- keeping each solar piece's dust (a dust storm lays it, rain washes it, wind
-- scours a little, an Engineer wipes it in 10 s), reading the weather where it
-- is simulated, and feeding the grid the light times the factor. The base and
-- the small solar system are smoke_base_grid's, against the real parts_base /
-- structures / bases / base_grid / base_cable / base_tower / electronics.
--
--   luajit solar/tests/smoke_panel_dust.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, e) return math.abs(a - b) <= (e or 1e-6) end

local function env(store, scripts, extra)
  local E = setmetatable({
    time = 5.0,
    save = {
      get = function(k) return store[k] end,
      set = function(k, v) store[k] = v end,
      delete = function(k) local had = store[k] ~= nil; store[k] = nil; return had end,
    },
    findScript = function(k) return scripts[k] end,
    findScripts = function() return {} end,
    find = function() return nil end,
    log = function() end,
  }, { __index = _G })
  for k, v in pairs(extra or {}) do E[k] = v end
  return E
end
local function load_script(path, E)
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, E)
  f()
  E.params = {}
  for k, v in pairs(E.defaults or {}) do E.params[k] = v end
  return E
end
local function slurp(p) local f = io.open(p); if not f then return nil end local s = f:read("*a"); f:close(); return s end

-- ── the parts ───────────────────────────────────────────────────────────────
local PB = load_script("parts_base.lua", env({}, {}))
local BB, SW, PC = PB.partInfo("batteryBank"), PB.partInfo("shieldWall"), PB.partInfo("powerCable")
check(BB and BB.power and BB.power.kind == "store" and BB.power.cap == 4000 and BB.power.eff < 1 and BB.onDeck and near(BB.mass, 2.6),
  "the Battery Bank: a 4,000 EC store, charged at " .. tostring(BB and BB.power.eff) .. ", 2.6 t, stands on a deck")
check(SW and SW.shield and near(SW.shield.k, 0.05) and near(SW.half.x, 1.0) and near(SW.half.y, 1.0) and near(SW.half.z, 0.25) and near(SW.mass, 4.6),
  "the Shield Wall: 2 x 2 x 0.5 m, 4.6 t (2.3 t/m3), lets 5 % through")
check(PC and PC.cable and PC.cable.max == 1500 and near(PC.cable.kgm, 1.4) and near(PC.cable.perm, 3.0),
  "the Power Cable: up to 1.5 km a run, 1.4 kg and $3 a metre")
check(slurp("solar/prefabs/BaseBattery.prefab.ron") and slurp("solar/prefabs/BaseShieldWall.prefab.ron") and slurp("solar/prefabs/BaseCableDrum.prefab.ron"),
  "...their prefabs on disk")
check((slurp("solar/prefabs/BaseShieldWall.prefab.ron") or ""):find('name: "Wall 1"', 1, true) ~= nil, "the wall's collider box")
local cat = PB.catalogue()[1].ids
check(#cat == 14 and cat[5] == "baseHub" and cat[9] == "batteryBank" and cat[10] == "shieldWall" and cat[11] == "powerCable" and cat[14] == "hvCable",
  "the BASE column: ten parts, S5's three more cable drums and the Base Hub (playtest 11-09)")

-- ── a small solar system on a real conic ────────────────────────────────────
local MU, RS = 9.75e10, 2.0e5
local V = math.sqrt(MU / RS)
local R = 800
local bodies = {
  { name = "Sun", x = 0, y = 0, z = 0, vx = 0, vy = 0, vz = 0, radius = 1.0e4, mu = MU, soi = -1, star = true },
  { name = "Vever", x = RS, y = 0, z = 0, vx = 0, vy = V, vz = 0, radius = R, mu = 1e5, soi = 5e4 },
}
local SPACE = {
  body = function(n) for _, b in ipairs(bodies) do if b.name == n then return b end end return nil end,
  bodies = function() return bodies end,
  dominant = function() return "Vever" end,
}
local E = load_script("electronics.lua", env({}, {}))
local BG0 = load_script("base_grid.lua", env({}, {}))
local Y = BG0.yearOf(bodies[2], bodies[1])
check(Y and near(Y, 2 * math.pi * math.sqrt(RS ^ 3 / MU), 1e-6), string.format("the world's year from its conic: %.1f s", Y or -1))

-- the site: on Vever's equator facing the sun now (body-relative −X), the
-- array's tracking axis square to the orbit's plane
local s = { ["base.body"] = "Vever" }
local clock = { a = 1000 }
local scripts = {}
scripts.parts_base = PB
scripts.electronics = E
scripts.deployables = { agencyClock = function() return clock.a end, dateOf = function() return "Day 9, Y1" end }
scripts.base_economy = load_script("base_economy.lua", env(s, scripts))
local money = { bal = 1e6, log = {} }
scripts.company = { spend = function(v, why) if v > money.bal then return false end money.bal = money.bal - v; money.log[#money.log + 1] = { -v, why }; return true end,
                    refund = function(v, why) money.bal = money.bal + v; money.log[#money.log + 1] = { v, why } end,
                    earn = function(v) money.bal = money.bal + v end, afford = function(v) return v <= money.bal end }
local credits = {}
scripts.crew = { activeId = function() return 2 end, credit = function(id, k, n) credits[#credits + 1] = { id, k, n } end,
                 roster = function() return { { id = 2, status = "afoot", body = "Vever", x = -R - 5, y = 3, z = 0 },
                                              { id = 3, status = "base" }, { id = 4, status = "afoot", body = "Vever", x = R, y = 0, z = 0 } } end }
local hist = {}
scripts.field_builder = { pushHistory = function(e) hist[#hist + 1] = e end }
local terrain = { query = function(x, y, z) local b = bodies[2]; return math.sqrt((x - b.x) ^ 2 + (y - b.y) ^ 2 + (z - b.z) ^ 2) - R end }
local X = { space = SPACE, terrain = terrain }
scripts.bases = load_script("bases.lua", env(s, scripts))
local ST = load_script("structures.lua", env(s, scripts, X))
scripts.structures = ST
local CB = load_script("base_cable.lua", env(s, scripts, X))
scripts.base_cable = CB
local BG = load_script("base_grid.lua", env(s, scripts, X))
scripts.base_grid = BG
scripts.base_facilities = { setGuards = function() end }
local BT = load_script("base_tower.lua", env(s, scripts, X))
scripts.base_tower = BT
BT.start({ id = 1 }); BG.start({ id = 2 }); CB.start({ id = 3 })

-- each structure stands square to its own ground: up radial, front along the
-- equator (so a part's +X, the arrays' tracking axis, is −Z: square to the orbit)
local function struct(id, x, y, z, part, opts)
  local l = math.sqrt(x * x + y * y + z * z)
  local U = { x = x / l, y = y / l, z = z / l }
  local F = { x = -U.y, y = U.x, z = 0 }
  local rec = ST.newRecord(nil, "Vever", x, y, z, U, F, part, opts)
  return ST.add(rec)
end
-- along the equator: a point `d` m round from the site
local function at(d) local th = d / R return -R * math.cos(th), R * math.sin(th), 0 end
-- the base: a tower; 40 m off two Solar Arrays and a Battery Bank; 200 m off an Isotope Skid
local tsid = struct(nil, -R, 0, 0, "tower")
BT.update({}, 0.016)
local bid = ST.getPart(tsid, 1).base
check(bid ~= nil, "the tower founds its base")
local ax1, ay1, az1 = at(40)
local s_arr = struct(nil, ax1, ay1, az1, "solarArray")
ST.addPart(s_arr, { id = "solarArray", x = 3, y = 0, z = 0 })
local ax2, ay2, az2 = at(46)
local s_bat = struct(nil, ax2, ay2, az2, "batteryBank")
local ax3, ay3, az3 = at(200)
local s_far = struct(nil, ax3, ay3, az3, "isotopeSkid")
local ax4, ay4, az4 = at(260)
local s_bare = struct(nil, ax4, ay4, az4, "padPlate")

-- ══ G4: DUST ON THE PANELS (PLAN scenarios2 §2 G4) ═════════════════════════

-- ── the rules (electronics, pure) ───────────────────────────────────────────
check(near(E.soilFactor(0, 1), 1) and near(E.soilFactor(1, 1), 1 - E.DUST_LOSS) and near(E.soilFactor(0.5, 0.5), (1 - 0.5 * E.DUST_LOSS) * 0.5),
  "soilFactor: clean and clear is all of it; caked cells lose DUST_LOSS; the sky multiplies")
check(near(E.skyFactor(nil), 1) and near(E.skyFactor({ kind = "none" }), 1), "no weather, or an airless world: the whole sky")
local clear = { kind = "wet", cover = 0.08, precip = 0, storm = 0, wind = 3 }
local overcast = { kind = "wet", cover = 0.9, precip = 0, storm = 0, wind = 5 }
local rain = { kind = "wet", cover = 1, precip = 1, storm = 0, wind = 8, snow = 0 }
local snow = { kind = "wet", cover = 1, precip = 1, storm = 0, wind = 4, snow = 1 }
local duststorm = { kind = "dust", cover = 1, precip = 1, storm = 1, wind = 18 }
local dust = { kind = "dust", cover = 0.7, precip = 0.5, storm = 0, wind = 9 }
local s_clear, s_over, s_storm = E.skyFactor(clear), E.skyFactor(overcast), E.skyFactor(duststorm)
check(s_clear > 0.9 and s_over < 0.6 and s_over > 0.4, string.format("cloud cover: clear %.2f, overcast %.2f", s_clear, s_over))
check(s_storm <= 0.12 and s_storm >= E.SKY_MIN, string.format("a dust storm's sky: a trickle (%.2f)", s_storm))
local dep, clr = E.dustRates(duststorm)
check(dep > 0 and clr == 0, "a dust storm lays dust and its wind does not scour it")
check(select(2, E.dustRates(rain)) > 0 and select(1, E.dustRates(rain)) == 0, "rain washes")
check(select(2, E.dustRates(snow)) == 0, "snow does not wash (and a calm one does not scour)")
check(select(2, E.dustRates({ kind = "wet", cover = 0.1, precip = 0, storm = 0, wind = 16 })) > 0, "a strong dry wind scours a little")
-- the step is exact: one long step lands where many short ones do
local d1 = E.dustStep(0.1, duststorm, 600)
local d2 = 0.1
for _ = 1, 600 do d2 = E.dustStep(d2, duststorm, 1) end
check(near(d1, d2, 1e-9), string.format("one 600 s step = 600 one-second steps (%.6f / %.6f)", d1, d2))
check(d1 > 0.6 and d1 < 1, string.format("ten minutes of storm: %.0f %% of the cells under dust", d1 * 100))
local dw = E.dustStep(0.8, rain, 120)
check(dw < 0.2, string.format("two minutes of rain wash it to %.0f %%", dw * 100))
check(near(E.dustStep(0.5, clear, 3600), 0.5, 1e-12), "a calm clear hour leaves it as it was")
check(E.dustStep(0.3, dust, 300) > 0.3, "a lighter dust spell lays some")
-- solarOutput takes the factor
local sx = 2.0e5
local bl = { { name = "Sun", x = 0, y = 0, z = 0, radius = 1e4, mu = MU, star = true } }
local o_clean = E.solarOutput(3, sx, 0, 0, 0, 0, 1, bl, nil)
local o_soil = E.solarOutput(3, sx, 0, 0, 0, 0, 1, bl, nil, nil, 0.25)
check(o_clean > 0 and near(o_soil, o_clean * 0.25, 1e-9), string.format("solarOutput × soil: %.3f of %.3f", o_soil, o_clean))

-- ── the grid: a dusted array feeds less ─────────────────────────────────────
s["grid.a"] = nil
BG.update({}, 0.016)
local tp0 = BT.power(bid)
local a_ref = clock.a
local function tickd(dt_real, dt_agency)
  clock.a = clock.a + (dt_agency or 0)
  local e = getfenv(BG.update); e.time = e.time + dt_real; BG.update({}, 0.016)
end
-- the weather where the camera stands, by the base
local WX = { o = nil }
scripts.weather = { current = function() return WX.o end }
local Vv = bodies[2]
scripts.planet_camera = { cam_x = Vv.x + ax1, cam_y = Vv.y + ay1 + 2, cam_z = Vv.z + az1 }
local benv = getfenv(BG.update)
benv.space = SPACE
tickd(2.1, 2)
tickd(0.6, 0)
local tpA = BT.power(bid)
local solar0 = tpA.solar
check(solar0 > 2.5, string.format("no weather read yet, no dust: the arrays give %.2f kW", solar0))
-- a dust storm rolls over the base
WX.o = { kind = "dust", cover = 1, precip = 1, storm = 1, wind = 18, body = "Vever" }
tickd(2.1, 2); tickd(0.6, 0)
local tpB = BT.power(bid)
check(tpB.solar < solar0 * 0.15, string.format("under the storm the sky takes it to a trickle: %.2f of %.2f kW", tpB.solar, solar0))
local inf = BG.soilInfo(s_arr, 1)
check(inf.sky <= 0.12 and inf.k < 0.15, string.format("the array's menu numbers: sky %.2f, factor %.2f", inf.sky, inf.k))
-- ten minutes of storm (agency time; the real clock just ticks)
for _ = 1, 5 do tickd(2.1, 120) end
tickd(0.6, 0)
inf = BG.soilInfo(s_arr, 1)
check(inf.dust > 0.6, string.format("ten minutes of storm: dust %.2f on the cells", inf.dust))
-- (back to the same hour of the year as the clean reading)
local function realign() local k = math.floor((clock.a - a_ref) / Y) + 1; tickd(2.1, a_ref + 2 + k * Y - clock.a) end
-- the storm passes: the sky clears, the dust stays
BG.setDust(s_arr, 0.6)
WX.o = { kind = "wet", cover = 0.05, precip = 0, storm = 0, wind = 2, body = "Vever" }
realign(); tickd(0.6, 0)
local tpC = BT.power(bid)
inf = BG.soilInfo(s_arr, 1)
check(inf.sky > 0.9 and tpC.solar < solar0 * 0.5 and tpC.solar > solar0 * 0.2,
  string.format("clear again, but the cells are dusty: %.2f of %.2f kW (dust %.2f k %.2f sky %.2f phase %.1f)", tpC.solar, solar0, inf.dust, inf.k, inf.sky, (clock.a - a_ref) % Y))
check(s["grid.dust"] and s["grid.dust"][tostring(s_arr) .. ":1"] and s["grid.dust"][tostring(s_arr) .. ":1"] > 0.4, "the dust is in the save")
-- an Engineer wipes it (the menu row: 10 s, Engineers only)
local fake_node = {}
local stp = ST.partOfNode
ST.partOfNode = function(n) if n == fake_node then return ST.get(s_arr), ST.getPart(s_arr, 1) end return stp(n) end
local rows = BG.soilProviderFn({ node = fake_node }, {})
local wrow = nil
for _, r in ipairs(rows) do if r.id == "sg_wipe" then wrow = r end end
check(wrow and wrow.job and near(wrow.job.secs, 10), "the array's menu has a 10 s wipe row")
scripts.crew.hasRole = function(id, role) return role == "engineer" and id == 2 end
check(wrow and wrow.enabled() == true, "...open to an Engineer")
scripts.crew.hasRole = function() return false end
check(wrow and wrow.enabled() == false and wrow.why() == "Engineers only", "...not to anyone else")
scripts.crew.hasRole = function(id, role) return role == "engineer" end
wrow.job.done()
BG.wipe(s_arr, 2)     -- (the base has two arrays on that structure)
realign(); tickd(0.6, 0)
local tpD = BT.power(bid)
check(BG.soilInfo(s_arr, 1).dust == 0 and tpD.solar > solar0 * 0.95, string.format("wiped: %.2f kW again (k %.2f sky %.2f phase %.1f)", tpD.solar, BG.soilInfo(s_arr, 1).k, BG.soilInfo(s_arr, 1).sky, (clock.a - a_ref) % Y))
ST.partOfNode = stp
-- rain washes, far bases keep theirs
BG.setDust(s_arr, 0.7)
tickd(0.6, 0)
WX.o = { kind = "wet", cover = 1, precip = 1, storm = 0, wind = 6, snow = 0, body = "Vever" }
tickd(2.1, 120); tickd(0.6, 0)
check(BG.soilInfo(s_arr, 1).dust < 0.1, string.format("two minutes of rain wash it to %.2f", BG.soilInfo(s_arr, 1).dust))
BG.setDust(s_arr, 0.7)
scripts.planet_camera.cam_x = Vv.x + ax1 + 9000
tickd(2.1, 120); tickd(0.6, 0)
check(near(BG.soilInfo(s_arr, 1).dust, 0.7, 1e-4) and BG.soilInfo(s_arr, 1).sky == 1, "nine kilometres off, the weather is not simulated: the dust stays, the sky reads clear")
-- the cost: a factor step rebuilds; a steady one does not
local n0 = BG.PROF.n_rebuild
tickd(2.1, 2); tickd(2.1, 2); tickd(2.1, 2)
check(BG.PROF.n_rebuild == n0, "steady dust: no rebuilds")
print(string.format("  dust: %d factor steps, rebuild %.2f ms", BG.SOIL.n_steps, BG.PROF.rebuild_ms or 0))

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL: " .. f) end
  print(string.format("smoke_panel_dust: %d passed, %d FAILED", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_panel_dust: %d passed", passed))
