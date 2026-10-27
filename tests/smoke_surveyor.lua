-- SMOKE: the TL-5 Surveyor plasma rifle (scripts/surveyor.lua, items.lua
-- `surveyor`) and the wound path it uses (crew.hurt, crew_alerts_hud):
--
--   * the item: a two-handed tool, 9 kg / 16 L (heavier and bulkier than the
--     laser), sold at the depot's BUY counter, not standard issue, an energy
--     cell (a 100-unit fill) whose level reads as a percent;
--   * the tempo: the charge curve (0 → 1 over 0.9 s, most of it early), the
--     minimum charge, the cell's cost per bolt (5 … 10) and the flat cell;
--   * damage: falloff (whole to 60 m, 0.45 at the 450 m range, nothing past
--     it), armour by zone and helmet, two full-charge body hits at 30 m and
--     three at 150 m, a head hit worse, a bare head worse still, a weak bolt
--     less; part damage;
--   * the capsule test: a hit, a miss, the head zone, a ray starting inside;
--   * crew.hurt: hp down with the HIT alert (and the HUD's chip and sound),
--     death at 0 with cause "shot" and the shooter in the detail (the
--     memorial), rescue instead with death off, nobody at base hurt;
--   * the cells: a shot draws from the fullest rifle; recharge caps at 100.
--
--   luajit solar/tests/smoke_surveyor.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, e) return math.abs((a or 0) - (b or 0)) < (e or 1e-6) end
local function vec3(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
local function path(p) return io.open("solar/" .. p) and ("solar/" .. p) or p end

-- ── the rifle's rules, alone ───────────────────────────────────────────────
local store = {}
local scripts = {}
local function load(p, kind, extra)
  local E = setmetatable({
    time = 0, vec3 = vec3, log = function() end,
    save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
    findScript = function(k) return scripts[k] end,
    findScripts = function() return {} end,
    find = function() return nil end,
  }, { __index = _G })
  for k, v in pairs(extra or {}) do E[k] = v end
  local f = assert(loadfile(path(p)))
  setfenv(f, E)
  f()
  E.params = {}
  for k, v in pairs(E.defaults or {}) do E.params[k] = v end
  E.valid = true
  scripts[kind] = E
  return E
end

local I = load("scripts/items.lua", "items")
local S = load("scripts/surveyor.lua", "surveyor")

-- the item
local d = I.def("surveyor")
check(d and d.kind == "tool" and d.hold.grip == "two" and d.hold.prefab == "ToolSurveyor", "a two-handed tool with its own model")
check(d.kg == 9.0 and d.L == 16 and d.kg > I.def("laser").kg and d.L > I.def("laser").L, "9 kg / 16 L: heavier and bulkier than the laser")
check(d.shop and d.cost >= 2000 and not d.issue, "sold at the BUY counter ($" .. tostring(d.cost) .. "), not standard issue")
local on_shop = false
for _, e in ipairs(I.shopList()) do if e.id == "surveyor" then on_shop = true end end
check(on_shop, "the depot's shop list has it")
check(I.fillCap("surveyor") == 100 and I.isWeapon("surveyor") and not I.isWeapon("laser"), "an energy cell of 100; a weapon")
check(select(1, I.fillText("surveyor", 84)) == "84%" and select(1, I.fillText("o2tank", 600)) == "10",
  "levels read as a cell's percent and a tank's minutes")
local belt = I.belt(function(id) return (id == "surveyor" or id == "laser") and 1 or 0 end)
check(belt[1].id == "laser" and belt[2].id == "surveyor", "on the belt after the laser")

-- the tempo
check(S.chargeAt(0) == 0 and near(S.chargeAt(0.9), 1) and near(S.chargeAt(5), 1), "the charge: 0 → 1 over 0.9 s")
check(S.chargeAt(0.45) > 0.7, "most of the charge comes early (" .. S.chargeAt(0.45) .. " at half time)")
check(near(S.shotCost(0), 5) and near(S.shotCost(1), 10), "a bolt costs 5 … 10 of the cell")
check(not S.canFire(100, 0.1) and S.canFire(100, 0.3) and not S.canFire(4, 1.0) and S.canFire(10, 1.0),
  "no bolt under the minimum charge, nor from a flat cell")

-- damage
check(S.falloff(30) == 1 and S.falloff(60) == 1 and near(S.falloff(450), 0) and S.falloff(500) == 0
  and near(S.falloff(449.999), 0.45, 1e-3), "falloff: whole to 60 m, 0.45 at the range, nothing past it")
local d30, d150 = S.crewDamage(1, 30, "body", true), S.crewDamage(1, 150, "body", true)
check(near(d30, S.params.dmg * 0.8, 1e-9) and d30 > 0.5, "a full-charge body hit at 30 m: " .. d30)
check(S.hitsToKill(30) == 2 and S.hitsToKill(150) == 3, "two body hits at 30 m, three at 150 m (" ..
  S.hitsToKill(30) .. ", " .. S.hitsToKill(150) .. ")")
check(S.crewDamage(1, 30, "head", true) > d30 and S.crewDamage(1, 30, "head", false) > S.crewDamage(1, 30, "head", true),
  "the head is worse, a bare head worse still")
check(S.crewDamage(0.25, 30, "body", true) < d30 * 0.5, "a weak bolt does less than half")
check(near(S.partDamage(1, 30), 0.25) and S.partDamage(1, 300) < 0.25, "a part: 0.25 hp a full bolt, less far off")
check(S.zoneAt(0.9) == "head" and S.zoneAt(0.5) == "body" and S.zoneAt(0.8, true) == "head", "zones by height")

-- the capsule (a standing suit: soles at y=0 .. crown at 1.9, r 0.3)
local t, s = S.rayCapsule(-10, 1.0, 0, 1, 0, 0, 0, 0.3, 0, 0, 1.6, 0, 0.3)
check(t and near(t, 9.7, 1e-6) and s > 0.4 and s < 0.6, "straight at the chest: in at 9.7 m, mid-body (" .. tostring(t) .. ")")
t = S.rayCapsule(-10, 1.0, 0.5, 1, 0, 0, 0, 0.3, 0, 0, 1.6, 0, 0.3)
check(t == nil, "0.5 m to the side: a miss")
t, s = S.rayCapsule(-10, 1.82, 0, 1, 0, 0, 0, 0.3, 0, 0, 1.6, 0, 0.3)
check(t and s == 1 and S.zoneAt(s) == "head", "over the top segment: the crown cap, the head")
t = S.rayCapsule(-10, 1.0, 0, -1, 0, 0, 0, 0.3, 0, 0, 1.6, 0, 0.3)
check(t == nil, "pointing away: a miss")

-- ── crew.hurt ──────────────────────────────────────────────────────────────
local function crew_env(store2)
  local astro = { name = "Astronaut", valid = true, visible = true, id = 99, x = 0, y = 101, z = 0, vx = 0, vy = 0, vz = 0 }
  local L = { caps = {}, drops = 0 }
  local sc = {
    salvage = { valid = true, drop = function() L.drops = L.drops + 1; return 40 end },
    deployables = { valid = true, place = function() return 70 end, dateOf = function() return "Day 3" end },
    company = { valid = true, addRep = function() end, afford = function() return true end, spend = function() return true end },
    big_caption = { valid = true, show = function(t, s) L.caps[#L.caps + 1] = t .. ": " .. s end },
    flight_ops = { valid = true, crewHome = function() return 5, 102, 5 end },
    planet_walker = { valid = true, breath = 1.0, airLeft = 1200, airCap = 1200 },
  }
  local E = setmetatable({
    time = 10.0, vec3 = vec3,
    save = { get = function(k) return store2[k] end, set = function(k, v) store2[k] = v end },
    findScript = function(k) return sc[k] end,
    findScripts = function() return {} end,
    find = function(n) if n == "Astronaut" then return astro end end,
    space = { dominant = function() return "Vever" end, body = function() return { name = "Vever", x = 0, y = 0, z = 0 } end,
              time = function() return 500 end },
    overlapSphere = function() return {} end,
    log = function() end,
  }, { __index = _G })
  local f = assert(loadfile(path("scripts/crew.lua")))
  setfenv(f, E)
  f()
  E.params = {}
  for k, v in pairs(E.defaults) do E.params[k] = v end
  E.start()
  return E, L
end

local st2 = { g_seed = 3 }
local C, L = crew_env(st2)
C.patch(2, { status = "afoot", body = "Vever", x = 30, y = 100, z = 0 })
local hp = C.hurt(2, S.crewDamage(1, 30, "body", true), "shot", "by Dana Okafor, 30 m", { by = "Dana Okafor" })
check(hp and near(hp, 1 - d30, 1e-9) and C.get(2).hp == hp, "a hit: hp down to " .. tostring(hp))
local al = C.alerts(2)
check(al.hit and al.hit.cause == "shot" and al.hit.by == "Dana Okafor", "the HIT alert is up")
C.time = C.time + 2.0
check(C.alerts(2).hit == nil, "…for 1.6 s")
local H = load("scripts/crew_alerts_hud.lua", "crew_alerts_hud")
local chips = H.chipsOf({ hp = 0.5, hit = { amount = 0.5, t = 1 } })
check(chips[1][1]:find("^HIT") and chips[1][2] == "danger" and chips[2][1] == "HP 50%", "the HUD: a red HIT chip, then HP")
local snd = H.soundsOf({}, { hit = { amount = 0.5, t = 1 } }, 1)
check(snd[1] == "hit", "…and the hit sound, once")
hp = C.hurt(2, 0.6, "shot", "by Dana Okafor, 30 m", { by = "Dana Okafor", x = 30, y = 100, z = 0 })
local r = C.get(2)
check(hp == 0 and r.status == "dead" and r.died.cause == "shot" and r.died.detail == "by Dana Okafor, 30 m",
  "the second hit kills: cause shot, " .. tostring(r.died and r.died.detail))
local m = C.memorial()
check(#m == 1 and m[1].died.cause == "shot", "the memorial has them")
check(L.caps[#L.caps]:find("killed: shot by Dana Okafor, 30 m") ~= nil, "the caption: " .. tostring(L.caps[#L.caps]))
check(C.hurt(2, 0.5) == nil, "the dead aren't hurt again")
check(C.hurt(3, 0.5) == nil and C.get(3).hp == 1, "a member at base is out of reach")
-- death off: the rescue
local st3 = { g_seed = 4 }
local C3 = crew_env(st3)
C3.setDeath(false)
C3.patch(2, { status = "afoot", body = "Vever", x = 30, y = 100, z = 0 })
C3.hurt(2, 0.7, "shot", "by X, 10 m")
hp = C3.hurt(2, 0.7, "shot", "by X, 10 m")
check(hp == 0 and C3.get(2).status == "base" and C3.get(2).hp == 1 and #C3.memorial() == 0,
  "death off: rescued to the base, whole, no memorial")

-- ── the cells ──────────────────────────────────────────────────────────────
local cstore = {}
store = cstore
scripts = {}
I = load("scripts/items.lua", "items")
local inv = load("scripts/inventory.lua", "inventory")
S = load("scripts/surveyor.lua", "surveyor")
inv.addItem("astro", "surveyor", 2, { force = true })
check(#inv.fills("astro", "surveyor") == 2 and inv.fills("astro", "surveyor")[1] == 100, "two rifles, full cells")
local tf = cstore["inv.fill.astro"] or {}
tf.surveyor = { 40, 100 }
cstore["inv.fill.astro"] = tf
local add = S.recharge("astro", 30)
local f = inv.fills("astro", "surveyor")
check(near(add, 30) and near(f[1], 70) and near(f[2], 100), "recharge tops up, capped at 100")

print(string.format("smoke_surveyor: %d passed, %d failed", passed, #failures))
for _, msg in ipairs(failures) do print("  FAIL " .. msg) end
os.exit(#failures == 0 and 0 or 1)
