-- SMOKE: crew roles (scripts/crew.lua "roles"; deep-space addendum §1, J1–J3,
-- J8; docs/crew-and-items.md §2.6), against a stub save.
--
--   * a new save's three starters are one of each, #1 the Pilot, no notice;
--   * the applicants' board always holds one of each — a fresh board, a
--     board from before roles, and after every hire; a hire keeps the role;
--   * the level is derived from the service record (5 flights, 3 worlds,
--     20 built, 10 studied → 2; a first off the home world → 3), and
--     credit() counts and notes the world;
--   * J8: an old save's members get a role from the record, once, with one
--     line of news — the outright repairs leader is the Engineer, the flights
--     leader the Pilot, a member leading both takes their leaning, ties fill
--     what the roster lacks (three tied → one of each), the dead take their
--     leaning; a member with a role keeps it; a second load changes nothing;
--   * retrain: $2,000 from the company, a day out of service (busy: no seat
--     in a launch plan, hasRole skips them), the new role when the day ends,
--     once per 30 days, at base only, not to the role they hold;
--   * hasRole over a craft, a list of ids, records, with a minimum level;
--   * a save with roles round-trips: plain values only, a reload keeps roles,
--     retrain and counters and assigns nothing.
--
--   luajit solar/tests/smoke_crew_roles.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end

local CLOCK = { t = 0 }
local function make(store, opts)
  opts = opts or {}
  local scripts = {
    inventory = { resolve = function(c) return c end },
    deployables = { agencyClock = function() return CLOCK.t end },
    company = opts.company,
  }
  local E = setmetatable({
    time = 5.0,
    save = {
      get = function(k) return store[k] end,
      set = function(k, v) store[k] = v end,
      delete = function(k) local had = store[k] ~= nil; store[k] = nil; return had end,
    },
    findScript = function(k) return scripts[k] end,
    findScripts = function(k) return scripts["*" .. k] or {} end,
    find = function() return nil end,
  }, { __index = _G })
  local f = assert(loadfile("solar/scripts/crew.lua"))
  setfenv(f, E)
  f()
  E.params = {}
  for k, v in pairs(E.defaults) do E.params[k] = v end
  return E, scripts
end

local function roles_of(C)
  local out, n = { pilot = 0, scientist = 0, engineer = 0 }, 0
  for _, r in ipairs(C.roster()) do
    if r.status ~= "dead" then out[r.role] = (out[r.role] or 0) + 1; n = n + 1 end
  end
  return out, n
end

local function one_each(t) return t.pilot == 1 and t.scientist == 1 and t.engineer == 1 end

-- ── a new save: one of each ────────────────────────────────────────────────
local s1 = { g_seed = 99 }
local C = make(s1)
C.start()
local got = roles_of(C)
check(one_each(got), "new save: the three starters are one of each")
check(C.get(1).role == "pilot", "member #1 (the avatar) is the Pilot (" .. tostring(C.get(1).role) .. ")")
check(s1["crew.notice"] == nil or s1["crew.notice"] == false, "a new save hears no news about roles")
check(C.role(1) == C.get(1).role and C.role(C.get(2)) == C.get(2).role, "role() takes an id or a record")
check(C.roleLetter(1) == "P" and C.roleName("engineer") == "Engineer" and C.roleLetter("scientist") == "S",
  "roleLetter / roleName")
check(C.get(1).landings == 0 and C.get(1).built == 0 and C.get(1).studied == 0, "the new counters start at 0")

-- ── the applicants: one of each, always ────────────────────────────────────
local function board_one_each(C_)
  local o = C_.offers()
  local t = { pilot = 0, scientist = 0, engineer = 0 }
  for _, a in ipairs(o) do if a.role then t[a.role] = t[a.role] + 1 end end
  return #o == 3 and one_each(t), o
end
check(board_one_each(C), "a fresh board holds a Pilot, a Scientist and an Engineer")
local all_ok = true
for k = 1, 12 do
  local o = C.offers()
  local pick = (k % 3) + 1
  local want = o[pick].role
  local id = C.hire(pick)
  if not (id and C.get(id).role == want) then all_ok = false end
  if not board_one_each(C) then all_ok = false end
end
check(all_ok, "twelve hires: each keeps the applicant's role, and the board refills to one of each")
-- a board saved before roles
s1["crew.offers"] = { { name = "Old One" }, { name = "Old Two" }, { name = "Old Three" } }
local okb, ob = board_one_each(C)
check(okb and ob[1].name == "Old One", "a board from before roles gets one of each, names kept")
-- a damaged board (two of a kind)
s1["crew.offers"] = { { name = "A", role = "pilot" }, { name = "B", role = "pilot" }, { name = "C", role = "pilot" } }
check(board_one_each(C), "a board with three Pilots is mended to one of each")

-- ── levels from the record ─────────────────────────────────────────────────
local H = "Vever"
check(C.levelOf({ flights = 4 }, H) == 1, "4 flights: level 1")
check(C.levelOf({ flights = 5 }, H) == 2, "5 flights: level 2")
check(C.levelOf({ worlds = { Vever = true } }, nil) == 1, "one world (home unknown): level 1")
check(C.levelOf({ worlds = { Vever = true, Nami = true, Velm = true } }, nil) == 2, "3 worlds: level 2")
check(C.levelOf({ built = 19 }, H) == 1 and C.levelOf({ built = 20 }, H) == 2, "20 structures: level 2")
check(C.levelOf({ studied = 10 }, H) == 2, "10 samples studied: level 2")
check(C.levelOf({ away = { kind = "build", body = "Nami" } }, H) == 3, "a first build off the home world: level 3")
check(C.levelOf({ worlds = { Nami = true } }, H) == 3, "landed on another world: level 3")
check(C.levelOf({ worlds = { Vever = true }, flights = 2 }, H) == 1, "landed at home only: level 1")
local lv, why = C.levelOf({ flights = 7 }, H)
check(lv == 2 and why == "7 flights", "levelWhy says what earned it (" .. tostring(why) .. ")")
-- credit
s1["base.body"] = "Vever"
local id2 = 2
check(C.credit(id2, "landings", 1, { body = "Vever" }) == 1 and C.level(id2) == 1, "a landing at home: counted, level 1")
check(C.credit(id2, "built", 3) == 3, "credit counts")
check(C.credit(id2, "nonsense", 1) == nil, "an unknown counter is refused")
C.credit(id2, "studied", 1, { body = "Nami" })
check(C.level(id2) == 3 and C.get(id2).away.body == "Nami" and C.get(id2).away.kind == "study",
  "a first study on Nami: level 3, the first noted")
C.credit(id2, "landings", 1, { body = "Velm" })
check(C.get(id2).away.body == "Nami", "the first away stays the first")
check(C.get(id2).worlds.Velm == true and C.get(id2).worlds.Vever == true, "the worlds landed on are kept")
for _ = 1, 5 do C.credit(3, "flights", 1) end
check(C.level(3) == 2, "five flights credited: level 2")

-- ── J8: old saves ──────────────────────────────────────────────────────────
local function old_save(members, extra)
  local st = { g_played = 40, g_seed = 5, ["crew.version"] = 2, ["crew.seq"] = #members, ["crew.active"] = 1,
               ["crew.death"] = true, ["crew.packMoved"] = true }
  local r = {}
  for i, m in ipairs(members) do
    m.id = i
    m.name = m.name or ("Member " .. i)
    m.status = m.status or "base"
    m.starter = i <= 3
    st["crew.m." .. i] = m
    r[#r + 1] = i
  end
  st["crew.roster"] = r
  for k, v in pairs(extra or {}) do st[k] = v end
  return st
end

-- a tied record (three fresh starters): one of each
local o1 = old_save({ {}, {}, {} })
local J = make(o1)
J.start()
check(one_each((roles_of(J))), "J8: a tied three-member roster ends up one of each")
check(type(o1["crew.notice"]) == "string" and o1["crew.notice"]:match("roles") ~= nil,
  "J8: a one-line notice (" .. tostring(o1["crew.notice"]) .. ")")
check(not tostring(o1["crew.notice"]):find("\n"), "...on one line")
check(o1["crew.version"] == J.VERSION, "J8: stamped at the current version")

-- the record decides
local o2 = old_save({ { flights = 9, repairs = 1 }, { repairs = 4 }, { flags = 2 } })
local J2 = make(o2)
J2.start()
check(J2.get(1).role == "pilot" and J2.get(2).role == "engineer" and J2.get(3).role == "scientist",
  string.format("J8: most flights → Pilot, most repairs → Engineer, else Scientist (%s %s %s)",
    J2.get(1).role, J2.get(2).role, J2.get(3).role))

-- one member leads both: they take their leaning; the other role still filled
local o3 = old_save({ { flights = 9, repairs = 5 }, {}, {} })
local J3 = make(o3)
J3.start()
check(J3.get(1).role == "pilot" and one_each((roles_of(J3))),
  string.format("J8: the veteran leads both and flies; the roster is one of each (%s %s %s)",
    J3.get(1).role, J3.get(2).role, J3.get(3).role))
local o3b = old_save({ { flights = 2, repairs = 6 }, {}, {} })
local J3b = make(o3b)
J3b.start()
check(J3b.get(1).role == "engineer" and one_each((roles_of(J3b))), "J8: leads both, leans to repairs: Engineer")

-- a tie on repairs: nobody is the Engineer by record; the balance fills it
local o4 = old_save({ { repairs = 3 }, { repairs = 3 }, { flights = 1 } })
local J4 = make(o4)
J4.start()
check(J4.get(3).role == "pilot" and one_each((roles_of(J4))),
  string.format("J8: a tie on repairs still ends one of each (%s %s %s)", J4.get(1).role, J4.get(2).role, J4.get(3).role))
check(J4.get(1).role == "engineer", "J8: in a tie the leaning breaks it (#1 leans to repairs: Engineer)")

-- four members, one dead, one already with a role
local o5 = old_save({ { flights = 3 }, { role = "engineer" }, { repairs = 2, status = "dead" }, {}, {} })
local J5 = make(o5)
J5.start()
local t5, n5 = roles_of(J5)
check(J5.get(2).role == "engineer", "J8: a member with a role keeps it")
check(J5.get(1).role == "pilot", "J8: the flights leader is the Pilot")
check(J5.get(3).role == "engineer", "J8: the dead take their leaning")
check(n5 == 4 and t5.scientist >= 1 and t5.pilot >= 1 and t5.engineer >= 1,
  string.format("J8: four living cover every role (P%d S%d E%d)", t5.pilot, t5.scientist, t5.engineer))
check(not tostring(o5["crew.notice"]):find("Member 2 "), "J8: the notice names only who was assigned")

-- a v2 save with no roles hears it once; a second load is a no-op
local before = o1["crew.m.1"]
o1["crew.notice"] = false
local Jb = make(o1)
Jb.start()
check(o1["crew.m.1"] == before and o1["crew.notice"] == false, "J8 again: nothing reassigned, no second notice")

-- a v1 save (one member) migrates through v2 and v3 together
local o6 = old_save({ { flights = 6, eva_s = 300 } }, { ["crew.version"] = 1 })
local J6 = make(o6)
J6.start()
check(#o6["crew.roster"] == 3 and one_each((roles_of(J6))) and J6.get(1).role == "pilot",
  "v1 → v3: the veteran is the Pilot, the two new starters fill the rest")
check(o6["crew.notice"]:match("joined") and o6["crew.notice"]:match("roles"), "...both notices, one caption")

-- the pure rule, directly
local a = C.assignRoles({ { id = 1 }, { id = 2 }, { id = 3 } })
check(a[1] == "pilot" and a[2] == "engineer" and a[3] == "scientist", "assignRoles: a tie fills in ROLES order")
local a2 = C.assignRoles({ { id = 5, role = "pilot" }, { id = 6 }, { id = 7 } })
check(a2[5] == nil and a2[6] ~= "pilot" and a2[7] ~= "pilot" and a2[6] ~= a2[7], "assignRoles: counts the roles held")

-- ── retraining ─────────────────────────────────────────────────────────────
local bank = { bal = 5000, spent = {} }
local company = {
  afford = function(n) return bank.bal >= n end,
  spend = function(n, why) if bank.bal < n then return false end bank.bal = bank.bal - n; bank.spent[#bank.spent + 1] = why; return true end,
}
CLOCK.t = 1000
local s7 = { g_seed = 3, ["base.body"] = "Vever" }
local R = make(s7, { company = company })
R.start()
local sci
for _, r in ipairs(R.roster()) do if r.role == "scientist" then sci = r.id end end
check(R.retrainCost() == 2000, "a retrain costs $2,000")
check(R.retrainWhyNot(sci, "scientist") ~= nil, "not to the role they hold")
check(R.retrainWhyNot(sci, "wizard") == "no such role", "not to a role that isn't")
check(R.retrainWhyNot(1, "engineer") == "only at base", "member #1 on foot: at base only")
local ok = R.retrain(sci, "engineer")
check(ok and bank.bal == 3000 and #bank.spent == 1, "retrain pays $2,000")
check(R.role(sci) == "scientist", "...still a Scientist while they train")
check(R.busy(sci) ~= nil and R.busy(sci):match("retraining as Engineer"), "busy: " .. tostring(R.busy(sci)))
check(R.training(sci).to == "engineer" and math.abs(R.training(sci).left - 86400) < 1, "training: a full day left")
check(R.retrainWhyNot(sci, "pilot") ~= nil, "no second retrain while training")
check(not R.hasRole({ sci }, "scientist"), "hasRole skips a member out of service")
-- the launch plan leaves them on the ground
local parts = { { uid = 1, id = "podMk2", kind = "crewed" } }
local plan = R.launchPlan(parts, { { uid = 1, slot = 1, id = sci } }, nil, nil)
check(#plan == 0, "a launch plan doesn't seat a member in training")
CLOCK.t = 1000 + 86400 - 10
check(R.role(sci) == "scientist" and R.busy(sci) ~= nil, "ten seconds before the day ends: still training")
CLOCK.t = 1000 + 86400 + 1
check(R.role(sci) == "engineer" and R.busy(sci) == nil, "the day is over: an Engineer")
R.rolesTick()
check(s7["crew.m." .. sci].role == "engineer" and s7["crew.m." .. sci].retrain == nil, "the tick writes the role down")
local w = R.retrainWhyNot(sci, "pilot")
check(w ~= nil and w:match("again in 29 days"), "once per 30 days (" .. tostring(w) .. ")")
CLOCK.t = 1000 + 30 * 86400
check(R.retrainWhyNot(sci, "pilot") == nil, "30 days on: allowed again")
bank.bal = 100
check(R.retrainWhyNot(sci, "pilot") == "not enough money", "not without the money")
local okp, whyp = R.retrain(sci, "pilot")
check(okp == false and whyp == "not enough money" and R.role(sci) == "engineer", "a refused retrain changes nothing")

-- ── hasRole ────────────────────────────────────────────────────────────────
local pil, eng
for _, r in ipairs(R.roster()) do
  if r.role == "pilot" then pil = r.id end
  if r.role == "engineer" and r.id ~= sci then eng = r.id end
end
check(R.hasRole({ pil, sci }, "pilot") == true, "hasRole over a list of ids")
check(R.hasRole(R.roster(), "engineer") == true, "hasRole over records")
check(R.hasRole({ sci }, "scientist") == false, "nobody holds it: false")
local craft = { node = {}, crewIds = function() return { sci } end }
local okr, who = R.hasRole(craft, "engineer")
check(okr and who.id == sci, "hasRole over a craft (crewIds) answers the member")
check(R.hasRole(craft, "engineer", 2) == false, "...but not at level 2")
for _ = 1, 5 do R.credit(sci, "flights", 1) end
check(R.hasRole(craft, "engineer", 2) == true, "...until they have earned it")
check(R.hasRole(pil, "pilot") == true and R.hasRole(pil, "nonsense") == false, "hasRole on one id; a bad role is false")

-- ── save round-trip ────────────────────────────────────────────────────────
-- the record holds only plain values (the engine's save writes strings,
-- numbers, booleans and tables of them)
local function plain(v, depth)
  depth = depth or 0
  local t = type(v)
  if t == "string" or t == "number" or t == "boolean" then return true end
  if t ~= "table" or depth > 4 then return false end
  for k, x in pairs(v) do
    if not (type(k) == "string" or type(k) == "number") or not plain(x, depth + 1) then return false end
  end
  return true
end
local function deep(v)
  if type(v) ~= "table" then return v end
  local o = {}
  for k, x in pairs(v) do o[k] = deep(x) end
  return o
end
CLOCK.t = 50000
bank.bal = 1e6
local other
for _, r in ipairs(R.roster()) do if r.status == "base" and r.id ~= sci then other = r.id end end
R.retrain(other, "scientist")                        -- leave one mid-retrain in the save
local all_plain = true
for k, v in pairs(s7) do if k:match("^crew%.") and not plain(v) then all_plain = false end end
check(all_plain, "every crew key is plain data")
local s8 = deep(s7)
s8["crew.notice"] = false
local R2 = make(s8, { company = company })
R2.start()
local same = true
for _, r in ipairs(R.roster()) do
  local q = R2.get(r.id)
  if not (q and q.role == r.role and (q.flights or 0) == (r.flights or 0) and R2.role(r.id) == R.role(r.id)
          and R2.level(r.id) == R.level(r.id)) then same = false end
end
check(same, "a reload keeps every role, counter and level")
check(R2.training(other) and R2.training(other).to == "scientist", "a retrain in progress survives the reload")
check(R2.get(sci).retrained == s7["crew.m." .. sci].retrained, "...and the last-retrain date")
check(s8["crew.notice"] == false, "a save with roles hears no J8 news on reload")
check(board_one_each(R2), "the saved board still holds one of each")

if #failures > 0 then
  for _, m in ipairs(failures) do print("FAIL: " .. m) end
  print(string.format("smoke_crew_roles: %d passed, %d FAILED", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_crew_roles: all %d checks passed", passed))
