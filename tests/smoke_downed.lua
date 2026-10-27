-- SMOKE: DOWNED and the MEDKIT (scripts/crew.lua, items.lua), against stubs.
--
--   * the rules: a fall under 1.6 × impact_kill or a shot that isn't overkill
--     leaves a member DOWN; a crush, a lost cabin, heat, an explosion, out of
--     air, or a fall past 1.6× kills outright; the bleed-out time is 180 s at
--     just-lethal, down to 60 s at the edge;
--   * a fatal fall on foot: down, hp 0, the caption, control passes on (to the
--     nearest member on foot), the downed can't be taken control of;
--   * left alone they bleed out at the timer: dead with the original cause,
--     "bled out after a fall, 26 m/s" on the memorial;
--   * a Medkit: needs it held, in the pack, within reach; held at the work;
--     the bleed-out clock stops while it runs; done → revived at 25 %, one
--     kit used; walking off stops it and keeps the kit; on the injured: +50 %
--     over 4 s; Rescue and Invincible never go down;
--   * items: the Medkit is 1.5 kg, 2 L, $150, sold at the depot.
--
--   luajit solar/tests/smoke_downed.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function vec3(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end

-- the real items.lua (its MEDKIT rules and the registry)
local IE = setmetatable({}, { __index = _G })
local fi = assert(loadfile("solar/scripts/items.lua"))
setfenv(fi, IE)
fi()

local function make(store)
  local astro = { name = "Astronaut", valid = true, visible = true, id = 99, x = 0, y = 101, z = 0, vx = 0, vy = 0, vz = 0 }
  local log = { caps = {}, spent = 0, rep = 0, kits = {}, removed = 0 }
  local hand = { id = "medkit" }
  local scripts = {
    salvage = { valid = true, drop = function() return 40 end },
    deployables = { valid = true, place = function() return 70 end, dateOf = function() return "Day 3" end },
    company = { valid = true, addRep = function(d) log.rep = log.rep + d end, afford = function() return true end,
                spend = function(n) log.spent = log.spent + n; return true end },
    big_caption = { valid = true, show = function(t, s) log.caps[#log.caps + 1] = t .. ": " .. s end },
    flight_ops = { valid = true, crewHome = function() return 5, 102, 5 end },
    planet_walker = setmetatable({ valid = true, breath = 1.0, airLeft = 1200, airCap = 1200, suitO2 = 1.0, onFoot = true },
      { __index = function(_, k) if k == "grounded" then return (astro.vy or 0) >= -0.01 end end }),
    items = IE,
    item_hand = { valid = true, held = function() return hand.id end },
    inventory = { valid = true,
                  itemCount = function(cid, id) return id == "medkit" and (log.kits[cid] or 0) or 0 end,
                  removeItem = function(cid, id, n) log.kits[cid] = (log.kits[cid] or 0) - (n or 1); log.removed = log.removed + 1; return n end },
  }
  local E = setmetatable({
    time = 10.0, vec3 = vec3,
    save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end,
             delete = function(k) store[k] = nil end },
    findScript = function(k) return scripts[k] end,
    findScripts = function(k) return {} end,
    find = function(n) if n == "Astronaut" then return astro end end,
    space = { dominant = function() return "Vever" end, body = function() return { name = "Vever", x = 0, y = 0, z = 0 } end,
              time = function() return 500 end },
    overlapSphere = function() return {} end,
    log = function() end,
  }, { __index = _G })
  local f = assert(loadfile("solar/scripts/crew.lua"))
  setfenv(f, E)
  f()
  E.params = {}
  for k, v in pairs(E.defaults) do E.params[k] = v end
  E.start()
  E.time = E.time + 4
  return E, astro, log, hand
end
local function tick(C, n, dt)
  for _ = 1, (n or 1) do C.time = C.time + (dt or 1 / 60); C.fixedUpdate(nil, dt or 1 / 60); C.update(nil, dt or 1 / 60) end
end
local function secs(C, s) tick(C, math.floor(s * 20 + 0.5), 0.05) end
local function fall(C, astro, v)
  astro.vy = 0; tick(C, 3)
  astro.vy = -v; tick(C, 15)
  astro.vy = 0; tick(C, 1)
end

-- ── the rules ──────────────────────────────────────────────────────────────
local C = make({ g_seed = 3 })
check(C.downRule("impact", 1.0) and C.downRule("impact", 1.5) and not C.downRule("impact", 1.6), "falls: down under 1.6 × lethal, dead past it")
check(C.downRule("shot", 0.2) and not C.downRule("shot", 0.6), "shots: down unless overkill")
for _, c in ipairs({ "crushed", "cabin", "heat", "explosion", "oxygen", "drowned" }) do
  check(not C.downRule(c, 1.0), c .. ": instant, never down")
end
check(C.bleedSecs("impact", 1.0) == 180 and C.bleedSecs("impact", 1.6) == 60
  and math.abs(C.bleedSecs("impact", 1.3) - 120) < 1e-6, "bleed out: 180 s just lethal, 60 s at the edge")
check(C.bleedSecs("shot", 0) == 180 and C.bleedSecs("shot", 0.5) == 60
  and math.abs(C.bleedSecs("shot", 0.25) - 120) < 1e-6, "bleed out from a bolt: 180 s grazed, 60 s at the edge")
local mk = IE.def("medkit")
check(mk and mk.kg == 1.5 and mk.L == 2 and mk.cost == 150 and mk.shop == true and mk.kind == "consumable",
  "the Medkit: 1.5 kg, 2 L, $150, at the depot")
check(IE.MEDKIT.heal == 0.5 and IE.MEDKIT.revive_hp == 0.25 and IE.MEDKIT.revive_secs == 6, "a Medkit heals +50 %, revives to 25 % in 6 s")

-- ── down, then bled out ────────────────────────────────────────────────────
local s1 = { g_seed = 3 }
local C1, a1, L1 = make(s1)
check(C1.activeId() == 1, "member #1 in control")
fall(C1, a1, 26)
local r = C1.get(1)
check(r.status == "afoot" and r.downed and r.hp == 0, "a 26 m/s fall: DOWN, not dead")
check(math.abs(r.downed.secs - C1.bleedSecs("impact", 26 / 20)) < 1e-6, "...with " .. string.format("%.0f", r.downed.secs) .. " s to live")
check(L1.caps[#L1.caps]:match("ASTRONAUT DOWN") ~= nil, "the caption: " .. tostring(L1.caps[#L1.caps]))
check(#C1.memorial() == 0 and L1.rep == 0, "nobody on the memorial yet, no reputation lost")
tick(C1, 4)
check(C1.activeId() ~= 1, "control passed on (to #" .. tostring(C1.activeId()) .. ")")
check(select(1, C1.control(1)) == false, "the downed can't be taken control of")
local dl = C1.downedList()
check(#dl == 1 and dl[1].id == 1 and dl[1].left > 0, "downedList: #1, " .. string.format("%.0f", dl[1] and dl[1].left or -1) .. " s")
-- the old 90 s clock is long gone and they are still holding on (180–60 s now)
secs(C1, 95)
check(C1.get(1).status ~= "dead" and C1.get(1).downed and C1.get(1).downed.left > 0,
  "still down, not dead, 95 s in (" .. string.format("%.0f", C1.get(1).downed and C1.get(1).downed.left or -1) .. " s left)")
secs(C1, r.downed.secs - 95 + 1)
r = C1.get(1)
check(r.status == "dead" and r.died.cause == "impact" and r.died.bled == true
  and r.died.detail == "bled out after a fall, 26 m/s", "left alone: bled out (" .. tostring(r.died and r.died.detail) .. ")")
check(C1.lastDeath.text:match("bled out after a fall, 26 m/s") ~= nil, "the death caption: " .. tostring(C1.lastDeath.text))

-- ── a 33 m/s fall and the instant causes never go down ─────────────────────
local s2 = { g_seed = 4 }
local C2, a2 = make(s2)
fall(C2, a2, 33)
check(C2.get(1).status == "dead" and not C2.get(1).died.bled, "33 m/s: dead outright")
C2.patch(2, { status = "afoot", body = "Vever", x = 3, y = 101, z = 0 })
C2.kill(2, "explosion", nil, { over = 1.0 })
check(C2.get(2).status == "dead", "an explosion: dead outright")

-- ── the Medkit revives in time ─────────────────────────────────────────────
local s3 = { g_seed = 5 }
local C3, a3, L3, hand3 = make(s3)
fall(C3, a3, 24)
check(C3.get(1).downed ~= nil, "#1 down")
tick(C3, 4)
local medic = C3.activeId()
-- the medic, a Medkit in their pack, walks over (the avatar node is them now)
local x1, y1, z1 = 0, 101, 0
local rec1 = C3.get(1)
if rec1.body then x1, y1, z1 = rec1.x, rec1.y, rec1.z end
a3.x, a3.y, a3.z = x1 + 10, y1, z1
L3.kits[C3.packOf(medic)] = 0
check(C3.treatWhyNot(1):match("Medkit") ~= nil, "no kit: " .. tostring(C3.treatWhyNot(1)))
L3.kits[C3.packOf(medic)] = 2
check(C3.treatWhyNot(1):match("walk up") ~= nil, "10 m off: " .. tostring(C3.treatWhyNot(1)))
a3.x = x1 + 1.5
hand3.id = nil
check(C3.treatWhyNot(1) == "hold the Medkit", "not in hand: " .. tostring(C3.treatWhyNot(1)))
hand3.id = "medkit"
local left0 = C3.get(1).downed.left
check(C3.treat(1) == true and C3.held(medic) == true, "Use Medkit: held at the work")
secs(C3, 3)
check(C3.get(1).downed and math.abs(C3.get(1).downed.left - left0) < 1e-6, "the bleed-out clock stops while they work")
check(C3.treating() and math.abs(C3.treating().frac - 0.5) < 0.05, "half way at 3 s of 6")
secs(C3, 3.2)
local r3 = C3.get(1)
check(r3.downed == nil and math.abs(r3.hp - 0.25) < 1e-6 and r3.status == "afoot", "revived at 25 %")
check(L3.kits[C3.packOf(medic)] == 1 and C3.lastTreat.done and C3.lastTreat.kind == "revive", "one Medkit used")
check(not C3.held(medic), "the medic is free again")
local okc, whyc = C3.control(1)
check(okc or not tostring(whyc):match("is down"), "the revived can be controlled again (" .. tostring(whyc) .. ")")

-- ── walking off stops it; the kit is kept ──────────────────────────────────
local s4 = { g_seed = 6 }
local C4, a4, L4 = make(s4)
fall(C4, a4, 22)
tick(C4, 4)
local m4 = C4.activeId()
local r4 = C4.get(1)
a4.x, a4.y, a4.z = r4.x + 1, r4.y, r4.z
L4.kits[C4.packOf(m4)] = 1
check(C4.treat(1), "treatment started")
secs(C4, 2)
a4.x = r4.x + 8
secs(C4, 0.2)
check(C4.treating() == nil and C4.lastTreat.why == "walked away" and L4.kits[C4.packOf(m4)] == 1, "walked off: stopped, kit kept")
check(C4.get(1).downed ~= nil, "...and they are still down")

-- ── healing the injured (yourself) ─────────────────────────────────────────
local s5 = { g_seed = 7 }
local C5, a5, L5 = make(s5)
C5.patch(1, { hp = 0.3 })
L5.kits[C5.packOf(1)] = 1
check(C5.treat(1), "a Medkit on yourself")
secs(C5, 4.2)
check(math.abs(C5.get(1).hp - 0.8) < 1e-6 and L5.kits[C5.packOf(1)] == 0, "+50 %: hp 0.3 → 0.8, kit used")
check(C5.treatWhyNot(1) ~= nil, "not hurt enough or no kit: refused")
-- a shot that isn't overkill downs; another one finishes them
C5.patch(2, { status = "afoot", body = "Vever", x = 4, y = 101, z = 0, hp = 0.4 })
C5.hurt(2, 0.6, "shot", "by Test, 30 m")
check(C5.get(2).downed ~= nil and C5.get(2).status == "afoot", "a shot through the last 40 % (+0.2): down")
C5.hurt(2, 0.3, "shot", "by Test, 30 m")
check(C5.get(2).status == "dead" and C5.get(2).died.cause == "shot", "shot again while down: dead")

-- ── Rescue and Invincible never go down ────────────────────────────────────
local s6 = { g_seed = 8 }
local C6, a6 = make(s6)
C6.setSafety("rescue")
fall(C6, a6, 24)
check(not C6.get(1).downed and C6.get(1).status == "afoot" and C6.get(1).hp == 1, "Rescue: rescued, never down")
C6.setSafety("invincible")
tick(C6, 200)
fall(C6, a6, 24)
check(not C6.get(1).downed and C6.get(1).hp == 1, "Invincible: never down")

if #failures > 0 then
  for _, m in ipairs(failures) do print("FAIL: " .. m) end
  print(string.format("smoke_downed: %d passed, %d FAILED", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_downed: all %d checks passed", passed))
