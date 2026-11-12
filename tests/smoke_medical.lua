-- SMOKE: THE MEDICAL BAY, SURVIVORS AND CARRYING (missions plan M1, N1).
-- Pure, against stubs.
--
--   * medical.lua: the drive-in box (inBayLocal) and the room; the talk as
--     beats (no menu when nothing is wrong; "Patch me up" when hurt; "See to"
--     a hurt member at the base); the treatment's beats (a say, a sound, a
--     shot, the hook); what she says after (the cause, the dose);
--   * crew.lua: medTreat clears hp, dose, a downed wound and the heat and
--     reports the cause; the CAUSE_TEXT gaps; Recall refuses the downed
--     (the bleed-out bug) and the one you are; a member brought home downed
--     by an old save is stabilised, never bled out; survivors are off the
--     roster (living, the roster panel's list) yet have records; a survivor's
--     death has no memorial and costs rep only by crew.deathRep;
--   * carrying: the load at 60 / 30 kg through the walker's curve, the
--     refusals, carry → seat / set down, the follow point;
--   * base_facilities: the bay's lot test and the site picked clear of the
--     player's structures; the lab's zones reach down the Med link.
--
--   luajit solar/tests/smoke_medical.lua

local failed, count = 0, 0
local function check(desc, ok, detail)
  count = count + 1
  if not ok then
    failed = failed + 1
    print("✗ " .. desc .. (detail ~= nil and ("   [" .. tostring(detail) .. "]") or ""))
  end
end
local function vec3(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
local function loadlib(path, env)
  env = env or {}
  if not getmetatable(env) then setmetatable(env, { __index = _G }) end
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, env)
  f()
  if env.defaults then env.params = env.params or {}; for k, v in pairs(env.defaults) do if env.params[k] == nil then env.params[k] = v end end end
  return env
end

-- ── medical.lua (pure) ──────────────────────────────────────────────────────
local MD = loadlib("medical.lua", { save = { get = function() return nil end, set = function() end } })
local c = { x = 2.9, y = -3.3, z = 2.2 }
check("the bay floor's middle is in the drive-in box", MD.inBayLocal(2.9, -2.0, 2.2, c))
check("a rover's middle a metre up, at the stop line, is in", MD.inBayLocal(2.9, -2.3, -2.8, c))
check("past the side line is out", not MD.inBayLocal(2.9 + 3.3, -2.0, 2.2, c))
check("out the door (6 m south) is out", not MD.inBayLocal(2.9, -2.0, 2.2 + 6.0, c))
check("on the roof is out", not MD.inBayLocal(2.9, -3.3 + 5.0, 2.2, c))
check("the treatment area is in the room", MD.inRoomLocal(-4.0, 1.0, -6.0))
check("the alley outside is not in the room", not MD.inRoomLocal(2.75, 1.0, 10.5))
-- the talk
local healthy = MD.talkBeats({ name = "Dana", needs = { any = false, hp = 1 }, seed = 1 })
check("nothing wrong: a line and no menu", #healthy == 1 and healthy[1].say and not healthy[2])
check("…said to you (with = player)", healthy[1].say.with == "player")
local hurt = MD.talkBeats({ name = "Dana", needs = { any = true, hp = 0.4 }, seed = 2 })
local ch = hurt[2] and hurt[2].choice
check("hurt: she asks, and Patch me up is first", ch and ch.options[1].text == "Patch me up" and ch.options[1].hook == "treat_self")
check("…with a way out that is a line, not a menu", ch and ch.options[#ch.options].beats and ch.options[#ch.options].beats[1].say)
local mem = MD.talkBeats({ name = "Dana", needs = { any = false }, member = { id = 3, name = "Theo Ito" }, seed = 3 })
check("a member hurt at the base: See to them", mem[2] and mem[2].choice.options[1].text == "See to Theo Ito")
local tb = MD.treatBeats(1)
local kinds = {}
for _, b in ipairs(tb) do kinds[#kinds + 1] = next(b) end
check("the treatment: a say, a sound, a shot, the hook", table.concat(kinds, ",") == "say,sound,shot,hook", table.concat(kinds, ","))
check("…the sound is a real recording on disk", io.open("solar/" .. tb[2].sound, "rb") ~= nil)
check("…the shot looks at her head", tb[3].shot.look == "med:head" and tb[3].shot.secs >= 3)
local rl = MD.resultLines({ cause = "impact", dose = 0.3 }, 1)
check("after: the cause named", rl[1]:find("fell", 1, true) ~= nil, rl[1])
check("…and the dose", rl[2] == MD.LINES.dose)
check("an unknown cause: the general words", MD.resultLines({ cause = "weird" }, 1)[1] == MD.LINES.cause_none)
for _, l in ipairs({ "hello", "hello_hurt", "bed", "done", "bye", "admit" }) do
  for _, s in ipairs(MD.LINES[l]) do check("a line is a sentence: " .. l, #s > 8 and s:sub(-1):find("[%.!%?]") ~= nil, s) end
end

-- ── crew.lua: treatment, recall, survivors, carrying ────────────────────────
local function make_crew(store)
  local astro = { name = "Astronaut", valid = true, visible = true, id = 99, x = 0, y = 101, z = 0, vx = 0, vy = 0, vz = 0 }
  local log = { rep = 0, caps = {}, pw = { valid = true, extraLoad = 0, onFoot = true }, inv = {} }
  local scripts = {
    company = { valid = true, addRep = function(d) log.rep = log.rep + d end, afford = function() return true end, spend = function() return true end },
    big_caption = { valid = true, show = function(t, s) log.caps[#log.caps + 1] = t .. ": " .. s end },
    planet_walker = log.pw,
    inventory = { valid = true, itemCount = function(cid, id) return (log.inv[cid] or {})[id] or 0 end },
    planet_camera = { valid = true, fwd_x = 0, fwd_y = 0, fwd_z = 1 },
  }
  local spawned = {}
  local E = setmetatable({
    time = 10.0, vec3 = vec3,
    save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end, delete = function(k) store[k] = nil end },
    findScript = function(k) return scripts[k] end, findScripts = function() return {} end,
    find = function(n) if n == "Astronaut" then return astro end end,
    spawn = function(prefab, p, cb) spawned[#spawned + 1] = prefab; return true end,
    space = { dominant = function() return "Vever" end, body = function() return { name = "Vever", x = 0, y = 0, z = 0 } end,
              time = function() return 500 end },
    overlapSphere = function() return {} end, log = function() end,
  }, { __index = _G })
  local f = assert(loadfile("solar/scripts/crew.lua"))
  setfenv(f, E)
  f()
  E.params = {}
  for k, v in pairs(E.defaults) do E.params[k] = v end
  E.ensure()
  return E, astro, log, spawned
end
local store = { g_seed = 5 }
local C, astro, L = make_crew(store)
local ids = {}
for _, r in ipairs(C.roster()) do ids[#ids + 1] = r.id end
check("three starters", #ids == 3)
local me, other = C.activeId(), nil
for _, id in ipairs(ids) do if id ~= me then other = other or id end end
-- the gaps in the death words
for _, k in ipairs({ "air", "hypoxia", "gas", "cold", "hotair" }) do check("CAUSE_TEXT has " .. k, type(C.CAUSE_TEXT[k]) == "string") end
-- treatment
C.patch(me, { status = "afoot", body = "Vever", x = 0, y = 101, z = 0, hp = 0.4, dose = 0.35, heat = 0.3 })
C.hurt(me, 0.1, "impact")
check("hurt keeps the cause on the record", C.get(me).hurtBy == "impact")
local n = C.medNeeds(C.get(me))
check("medNeeds sees the wound and the dose", n.any and n.hp < 0.5 and n.dose > 0.3)
local before = C.medTreat(me, "Dr Rao")
local r = C.get(me)
check("treated: hp full", r.hp == 1.0)
check("…the dose gone", (r.dose or 0) == 0)
check("…the heat gone", (r.heat or 0) == 0)
check("…and it says what it was", before and before.cause == "impact" and before.hp < 0.5 and before.dose > 0.3, before and before.cause)
check("…free", L.rep == 0)
check("nothing left to treat", not C.medNeeds(C.get(me)).any)
C.patch(other, { status = "afoot", body = "Vever", x = 30, y = 101, z = 0, hp = 0, downed = { left = 60, secs = 120, cause = "shot" } })
local b2 = C.medTreat(other, "Dr Rao")
check("a downed member: up, and the cause is the wound's", C.get(other).downed == nil and C.get(other).hp == 1 and b2.cause == "shot" and b2.downed)
-- recall
C.patch(other, { downed = { left = 60, secs = 120, cause = "impact" }, hp = 0 })
local ok, why = C.recall(other)
check("Recall refuses someone down (the bleed-out bug)", ok == false and tostring(why):find("carry them", 1, true), why)
check("…and they stay where they lie", C.get(other).status == "afoot")
check("Recall refuses the one you are", C.recallWhyNot(me) ~= nil)
C.patch(other, { downed = false, hp = 0.8 })
ok = C.recall(other)
check("Recall brings an able member home", ok and C.get(other).status == "base" and C.get(other).x == nil)
-- an old save's member brought home still bleeding: stabilised
C.patch(other, { status = "base", downed = { left = 5, secs = 120, cause = "impact" }, hp = 0 })
for _ = 1, 120 do C.time = C.time + 0.1; C.fixedUpdate(nil, 0.1) end
check("a member at the base never bleeds out", C.get(other).status == "base" and C.get(other).downed == nil and (C.get(other).hp or 0) >= 0.3,
  C.get(other).status)
-- survivors
local liv0 = C.living()
local s1 = C.newClient("Ines Barrow", { client = "c-17", body = "Vever", x = 4, y = 101, z = 0, hp = 0.3, downed = true })
check("a survivor has a record", C.get(s1) and C.get(s1).client == "c-17" and C.isClient(s1))
check("…off the roster", (function() for _, x in ipairs(C.roster()) do if x.id == s1 then return false end end return true end)())
check("…not counted living (the hire fee)", C.living() == liv0)
check("…but one of everyone (bodies, air)", (function() for _, x in ipairs(C.everyone()) do if x.id == s1 then return true end end return false end)())
-- carrying
check("the load: 60 kg, 30 on a stretcher", C.carryLoad(false) == 60 and C.carryLoad(true) == 30)
local PW = loadlib("planet_walker.lua", { vec3 = vec3, save = { get = function() end, set = function() end } })
local e60 = PW.encumbranceOf(20 + 60, 15, 90)
local e30 = PW.encumbranceOf(20 + 30, 15, 90)
local w60, _, j60 = PW.loadMults(e60, PW.defaults)
local w30 = PW.loadMults(e30, PW.defaults)
check("carried on your back you walk slower", w60 < 0.85 and w60 < w30, string.format("%.2f vs %.2f", w60, w30))
check("…and jump less", j60 < 0.85)
check("refused: a rope up", C.carryRefusal("rope", "up", false) ~= nil)
check("a stretcher lets you down a rope", C.carryRefusal("rope", "down", true) == nil)
check("refused: a ladder to a high hatch", C.carryRefusal("ladder", 2.5) ~= nil and C.carryRefusal("ladder", 0.9) == nil)
check("refused: a jump over 0.4 m", C.carryRefusal("jump", 0.8) ~= nil and C.carryRefusal("jump", 0.2) == nil)
C.patch(me, { status = "afoot" })
astro.x = 3.0
local okc, whyc = C.carry(s1)
check("carry a survivor within reach", okc, whyc)
check("…carried, by you", C.get(s1).status == "carried" and C.get(s1).carriedBy == me and C.carrying() == s1)
check("…the walker bears 60 kg more", L.pw.extraLoad == 60, L.pw.extraLoad)
check("you can't pick up a second", C.carryWhyNot(other) ~= nil)
astro.x = 50
for _ = 1, 10 do C.time = C.time + 0.1; C.update(nil, 0.1) end
check("the carried record rides the carrier", math.abs((C.get(s1).x or 0) - 50) < 1e-6, C.get(s1).x)
check("set them down", C.putDown() and C.get(s1).status == "afoot" and not C.carrying())
check("…the load is off", L.pw.extraLoad == 0)
L.inv["crew:" .. me] = { stretcher = 1 }
astro.x = (C.get(s1).x or 0)
C.carry(s1)
check("on a stretcher: 30 kg", L.pw.extraLoad == 30, L.pw.extraLoad)
local seated = nil
local v = { node = { id = 7, x = 0, y = 0, z = 0, valid = true }, craftName = "Rover",
            freeSeat = function() return 11, 2 end, seatMember = function(uid, slot, id) seated = { uid, slot, id }; return true end }
check("boarding seats them", C.seatCarried(v) and seated and seated[3] == s1 and C.get(s1).status == "aboard")
check("…and the load is off", L.pw.extraLoad == 0 and not C.carrying())
-- following
local fp = C.followPoint(0, 0, 0, 0, 0, 1, 0, 0, -10)
check("a follower heads 2.5 m behind you", fp and math.abs(fp.z + 2.5) < 1e-9)
check("…and stops when close", C.followPoint(0, 0, 0, 0, 0, 1, 0, 0, -2.0) == nil)
C.patch(s1, { status = "afoot", body = "Vever", x = 1, y = 101, z = 0, hp = 0.2, downed = false })
check("too hurt to follow: carry them", C.followWhyNot(s1) ~= nil)
C.patch(s1, { hp = 0.8 })
check("able: they follow", C.follow(s1, true) and C.get(s1).follow == true)
-- a survivor dies: no memorial; rep only with crew.deathRep
local rep0 = L.rep
store["crew.deathRep"] = false
C.kill(s1, "air")
check("a survivor's death: dead, no memorial", C.get(s1).status == "dead" and #(C.memorial() or {}) == 0)
check("…and no rep with deaths-cost-rep off", L.rep == rep0)
local s2 = C.newClient(nil, { client = "c-18", body = "Vever", x = 2, y = 101, z = 0 })
store["crew.deathRep"] = true
C.kill(s2, "cold")
check("…−2 rep with it on", L.rep == rep0 - 2, L.rep)
check("a rolled name for a nameless survivor", type(C.get(s2).name) == "string" and #C.get(s2).name > 2)
C.removeClient(s2)
check("removeClient forgets them", C.get(s2) == nil)

-- ── base_facilities: the lot and the site ──────────────────────────────────
local BF = loadlib("base_facilities.lua", { save = { get = function() end, set = function() end } })
local f = nil
for _, x in ipairs(BF.FACILITIES) do if x.prefab == "FacMedical" then f = x end end
check("the Medical Bay is a facility row", f and f.interior == "MedInterior" and f.extra == "MedLink" and f.site == "medical")
check("…between the lab and the VAB", f and f.u > -46.4 + 6 and f.u < -25.7 - 6 and f.face == "S")
check("its lot holds its own middle", BF.lotHolds(f, -34, 34, "S", -34 + (f.ox or 0), 34 - (f.oz or 0), 0))
check("…not the lab's", not BF.lotHolds(f, -34, 34, "S", -58, 34, 0))
local i1 = BF.pickSite(f, BF.MEDICAL_SITES, {}, BF.MEDICAL_CLEAR)
check("nothing there: the first lot", i1 == 1)
local i2, by = BF.pickSite(f, BF.MEDICAL_SITES, { { u = -33, v = 36, name = "Dana's shed" } }, BF.MEDICAL_CLEAR)
check("the player's shed on it: the next lot, and what was in the way", i2 == 2 and by == "Dana's shed", tostring(i2) .. " " .. tostring(by))
local i3 = BF.pickSite(f, BF.MEDICAL_SITES, { { u = -43, v = 34.2, name = "a fence" } }, BF.MEDICAL_CLEAR)
check("something on the link's run counts too", i3 == 2)
local alley = nil
for _, s in ipairs(BF.STRIPS) do if s[1] == "Medical Alley" then alley = s end end
check("the alley meets Road West's north edge", alley and alley[3] == -4.0 and alley[6] == 4.0)
check("…and the drive-in door is on it", alley and math.abs((-34 + 2.75) - alley[2]) + 2.2 <= alley[6])

-- ── the lab: the Med Door's zones ───────────────────────────────────────────
local LB = loadlib("lab.lua", {})
local function z(gx, gy, gz) return LB.inZone(gx, gy + LB.GROUND_Y, gz - LB.GROUND_Z, 0) end
check("the Med link is a lab zone", z(14, 1.0, 0.1))
check("the Medical Bay shows the lab down the link", z(24, 1.0, 0))
check("but the VAB beyond does not", not z(40, 1.0, 0))

print(string.format("medical: %d/%d passed", count - failed, count))
if failed > 0 then os.exit(1) end
