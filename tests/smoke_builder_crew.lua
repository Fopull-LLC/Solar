-- SMOKE HARNESS: the VAB's CREW tab (scripts/builder_crew.lua) and the
-- Astronaut Complex (scripts/crew_roster_panel.lua), docs/crew-and-items.md
-- §5.6, §2.2, §2.3 — against a fake roster, a fake builder and a fake
-- inventory.
--
--   luajit solar/tests/smoke_builder_crew.lua

local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end

local T = 100.0

-- ── a save, a roster, an inventory ─────────────────────────────────────────
local SAVE = {}
local save = { get = function(k) return SAVE[k] end, set = function(k, v) SAVE[k] = v end }

local ROSTER = {
  { id = 1, name = "Dana Okafor", status = "afoot", flights = 4, eva_s = 1830, flags = 1, repairs = 2, hired = 0, starter = true },
  { id = 2, name = "Jonah Reyes", status = "base", flights = 1, eva_s = 60, flags = 0, repairs = 0, hired = 0, starter = true },
  { id = 3, name = "Mira Hale", status = "base", flights = 0, eva_s = 0, flags = 0, repairs = 0, hired = 86400 * 3, cost = 1000 },
  { id = 4, name = "Theo Vance", status = "aboard", craft = "Kestrel I", flights = 2, eva_s = 0, flags = 0, repairs = 0, hired = 0 },
  { id = 5, name = "Rina Ito", status = "dead", flights = 3, eva_s = 900, flags = 2, repairs = 0, hired = 86400,
    died = { st = 86400 * 41, cause = "impact", detail = "17 m/s", body = "Nami", craft = "Kestrel II" } },
  { id = 6, name = "Tomas Lind", status = "afoot", body = "Vever", x = 5000, y = 0, z = 0, flights = 1, eva_s = 0,
    flags = 0, repairs = 0, hired = 0 },
}
local OFFERS = { { name = "Ada Moreau", cost = 1400 }, { name = "Kofi Kerr", cost = 1400 }, { name = "Lena Osei", cost = 1400 } }
local hired, renamed, controlled = {}, {}, {}
local crew = { valid = true, version = 1 }
function crew.roster() return ROSTER end
function crew.activeId() return 1 end
function crew.get(id) for _, r in ipairs(ROSTER) do if r.id == id then return r end end end
function crew.offers() return OFFERS end
function crew.hire(i)
  local a = OFFERS[i]
  if not a then return nil, "no such applicant" end
  local id = #ROSTER + 1
  ROSTER[#ROSTER + 1] = { id = id, name = a.name, status = "base", flights = 0, eva_s = 0, flags = 0, repairs = 0, hired = 0 }
  table.remove(OFFERS, i)
  hired[#hired + 1] = a.name
  return id
end
function crew.rename(id, s) renamed[id] = s; crew.get(id).name = s; return true end
function crew.control(id) controlled[#controlled + 1] = id; return true end
function crew.patch(id, f) local r = crew.get(id); for k, v in pairs(f) do r[k] = v end; return true end
function crew.memorial()
  local out = {}
  for _, r in ipairs(ROSTER) do
    if r.status == "dead" then
      out[#out + 1] = { id = r.id, name = r.name, hired = r.hired, died = r.died, flights = r.flights,
                        eva_s = r.eva_s, flags = r.flags, home = false }
    end
  end
  return out
end

local ITEMS = { repairkit = { name = "Repair Kit", kg = 4, L = 6, cost = 120 },
                beacon = { name = "Relay Beacon", kg = 6, L = 18, cost = 80 },
                gravgun = { name = "Gravity Gun", kg = 6, L = 10, cost = 600 } }
local items = { valid = true, ITEMS = ITEMS, VOL = { pack = 60, locker = 120 } }
local BAGS = { base = { repairkit = 4, beacon = 6 }, ["crew:1"] = { gravgun = 1 }, ["crew:2"] = {} }
local inv = { valid = true }
local function bag(c) BAGS[c] = BAGS[c] or {}; return BAGS[c] end
function inv.itemCount(c, id) return bag(c)[id] or 0 end
function inv.moveItem(a, b, id, n)
  local have = bag(a)[id] or 0
  local m = math.min(have, n or 1)
  if m <= 0 then return 0, "none to move" end
  bag(a)[id] = have - m
  bag(b)[id] = (bag(b)[id] or 0) + m
  return m
end
function inv.itemList(c)
  local out = {}
  for _, id in ipairs({ "gravgun", "beacon", "repairkit" }) do
    local n = bag(c)[id] or 0
    if n > 0 then out[#out + 1] = { id = id, name = ITEMS[id].name, n = n } end
  end
  return out
end
function inv.mass(c) local t = 0; for id, n in pairs(bag(c)) do t = t + ITEMS[id].kg * n end; return t end
function inv.cap(c) return 106 end
function inv.volume(c) local t = 0; for id, n in pairs(bag(c)) do t = t + ITEMS[id].L * n end; return t end
function inv.volCap(c) return 60 end
function inv.shopList() return { "repairkit", "beacon" } end
local bought = {}
function inv.buyItem(c, id, n) bag(c)[id] = (bag(c)[id] or 0) + n; bought[#bought + 1] = id; return true end

local spent = {}
local co = { valid = true, money = function(v) return "$" .. tostring(v) end, balance = function() return 5000 end,
             afford = function(v) return v <= 5000 end, spend = function(v, why) spent[#spent + 1] = v; return true end }
local fo = { valid = true, pickupFee = function(d) return math.floor(math.min(2500, 400 + d / 1000 * 30)) end }

-- ── a craft on the stand ───────────────────────────────────────────────────
local REG = {
  pod = { label = "Pod Mk1", kind = "crewed", mods = { { type = "command", crew = 1 } } },
  podMk2 = { label = "Pod Mk2", kind = "crewed", mods = { { type = "command", crew = 3 } },
             seats = { {}, {}, {} } },
  seat = { label = "Command Seat", kind = "crewed", seat = true, mods = { { type = "command", crew = 1, seat = true } } },
  cabin = { label = "Crew Cabin", kind = "structural", mods = { { type = "cabin", crew = 4 } } },
  probe = { label = "Probe Core", kind = "probe", mods = { { type = "command", crew = 0 } } },
  locker = { label = "Stowage Locker", kind = "structural", store = 80 },
  tankS = { label = "Tank", kind = "tank" },
}
local PARTS = {}   -- uid → { id, y }
local B = { valid = true, craftVersion = 1 }
function B.partUids() local o = {}; for u in pairs(PARTS) do o[#o + 1] = u end; table.sort(o); return o end
function B.partIdOf(u) return PARTS[u] and PARTS[u].id end
function B.partInfo(id) return REG[id] end
function B.partRec(u) local p = PARTS[u]; return p and { uid = u, id = p.id, def = REG[p.id], y = p.y } end
local hints = {}
function B.hint(m) hints[#hints + 1] = m end
local function build(list)
  PARTS = {}
  for _, p in ipairs(list) do PARTS[p[1]] = { id = p[2], y = p[3] } end
  B.craftVersion = B.craftVersion + 1
end

local SCRIPTS = { crew = crew, items = items, inventory = inv, company = co, builder = B, flight_ops = fo,
                  planet_walker = { valid = true, onFoot = true } }
local function load(path)
  local env = setmetatable({}, { __index = function(_, k)
    if k == "time" then return T end
    if k == "save" then return save end
    if k == "findScript" then return function(kind) return SCRIPTS[kind] end end
    if k == "input" then return { pressed = function() return false end, setMouseLocked = function() end } end
    return _G[k]
  end })
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  return env
end

local C = load("solar/scripts/builder_crew.lua")

-- ── 1. slot counts from the registry ────────────────────────────────────────
ok(C.slotsOf(REG.pod) == 1, "Pod Mk1 seats one (command crew = 1)")
ok(C.slotsOf(REG.podMk2) == 3, "Pod Mk2 seats three (its seats list)")
local n, kind, rank = C.slotsOf(REG.cabin)
ok(n == 4 and kind == "cabin" and rank == 0, "a cabin seats four passengers and commands nothing")
local n2, k2, r2 = C.slotsOf(REG.seat)
ok(n2 == 1 and k2 == "command" and r2 == 1, "a command seat is an open command slot (ranked under a pod)")
ok(C.slotsOf(REG.probe) == 0, "a probe core seats nobody")
ok(C.slotsOf({ kind = "crewed" }) == 1, "a crewed part with no module seats one")
ok(C.isProbe(REG.probe) and not C.isProbe(REG.pod), "probe cores are told apart")

-- stack order: top first; commander: pod over seat
local parts = { { uid = 1, id = "seat", def = REG.seat, y = 3 }, { uid = 2, id = "pod", def = REG.pod, y = 1 },
                { uid = 3, id = "cabin", def = REG.cabin, y = 2 } }
local cp = C.crewedParts(parts)
ok(#cp == 3 and cp[1].uid == 1 and cp[2].uid == 3 and cp[3].uid == 2, "crewed parts in stack order, top first")
local cs = C.commandSlots(cp)
ok(#cs == 2 and cs[1].uid == 2 and cs[2].uid == 1, "the pod's slot ranks over the open seat; the cabin has none")

-- ── 2. the default puts the avatar in the commander slot ────────────────────
local plan, did = C.defaultPlan({}, cp, ROSTER, 1)
ok(did and C.seatAt(plan, 2, 1) == 1, "the default seats the active member in the pod (the commander slot)")
ok(C.commanderOf(cp, plan) == 1, "…and they are the commander")
local plan2, did2 = C.defaultPlan({ [3] = { [1] = 2 } }, cp, ROSTER, 1)
ok(not did2, "a craft that already has someone planned keeps its plan")
-- the avatar away: the most recent available member instead
local away = { { id = 1, name = "A", status = "aboard", craft = "X" }, { id = 2, name = "B", status = "base" },
               { id = 3, name = "C", status = "base" } }
local p3 = C.defaultPlan({}, cp, away, 1)
ok(C.seatAt(p3, 2, 1) == 3, "with the avatar aboard elsewhere, the most recent member at base takes command")

-- ── 3. no double booking ────────────────────────────────────────────────────
local okA, whyA = C.canSeat(plan, cp, ROSTER, 1, 1, 3, 2)
ok(not okA and whyA:find("already in the Pod Mk1"), "a member already seated can't be dropped on a second seat: " .. tostring(whyA))
local okB = C.canSeat(plan, cp, ROSTER, 1, 1, 3, 2, { uid = 2, slot = 1 })
ok(okB, "…but dragging their seat card moves them")
local okC, whyC = C.canSeat(plan, cp, ROSTER, 1, 4, 3, 1)
ok(not okC and whyC:find("aboard Kestrel I"), "a member aboard another craft is refused: " .. tostring(whyC))
local okD, whyD = C.canSeat(plan, cp, ROSTER, 1, 5, 3, 1)
ok(not okD and whyD:find("dead"), "the dead are refused")
local okE, whyE = C.canSeat(plan, cp, ROSTER, 1, 6, 3, 1)
ok(not okE and whyE:find("away on foot"), "a member on foot elsewhere is refused")
ok(C.canSeat(plan, cp, ROSTER, 1, 2, 3, 4), "a member at base can take a cabin seat")
ok(not C.canSeat(plan, cp, ROSTER, 1, 2, 3, 5), "there is no fifth cabin seat")
-- a seat swap keeps both
local sw = C.seat({ [2] = { [1] = 1 }, [3] = { [1] = 2 } }, 2, 2, 1, { uid = 3, slot = 1 })
ok(C.seatAt(sw, 2, 1) == 2 and C.seatAt(sw, 3, 1) == 1, "dropping a seat card on a taken seat swaps them")
-- prune: a member in two places keeps the first, the unavailable go
local pr, ch = C.prune({ [2] = { [1] = 1 }, [3] = { [1] = 1, [2] = 4 }, [99] = { [1] = 2 } }, cp, ROSTER, 1)
local ones = 0
for _, m in ipairs(C.seatedIds(pr)) do if m == 1 then ones = ones + 1 end end
ok(ch and ones == 1 and C.seatAt(pr, 3, 2) == nil and pr[99] == nil,
  "prune: no member twice, nobody unavailable, no parts that are gone")

-- ── 4. the launch block ─────────────────────────────────────────────────────
ok(C.launchBlock(parts, {}) == nil,
  "no plan at all: the avatar takes the controls at launch, as before seat planning")
ok(C.launchBlock(parts, { [3] = { [1] = 1 } }) == "nobody can fly it: put someone in the Pod Mk1",
  "crew planned only into the cabin, nobody at the controls: the launch is blocked, naming the part")
ok(C.launchBlock(parts, { [3] = { [1] = 2 } }) ~= nil, "a passenger in the cabin doesn't fly it")
ok(C.launchBlock(parts, { [1] = { [1] = 2 } }) == nil, "someone in the open seat does")
local withProbe = { parts[1], parts[2], { uid = 9, id = "probe", def = REG.probe, y = 0 } }
ok(C.launchBlock(withProbe, {}) == nil, "a probe core flies it with nobody aboard")
ok(C.launchBlock({ { uid = 1, id = "cabin", def = REG.cabin } }, {}) == nil,
  "a cabin alone is the builder's 'no command part', not this block")

-- the repair-kit nudge
local big = {}
for i = 1, 31 do big[i] = { uid = i, id = "tankS", def = REG.tankS } end
big[32] = { uid = 32, id = "pod", def = REG.pod }
local w = C.launchWarn(big, { [32] = { [1] = 1 } }, {}, function() return 0 end)
ok(#w == 1 and w[1]:find("Repair Kit"), "over 30 parts and no repair kit aboard warns")
ok(#C.launchWarn(big, { [32] = { [1] = 1 } }, { [40] = { repairkit = 1 } }, function() return 0 end) == 0,
  "a kit in a locker plan answers it")
ok(#C.launchWarn(big, { [32] = { [1] = 1 } }, {}, function(id, it) return it == "repairkit" and 1 or 0 end) == 0,
  "a kit in a seated member's pack answers it")

-- locker room
ok(C.lockerRoom({ beacon = 6 }, "beacon", 80, 120) == false, "a locker plan stops at its litres (6 beacons = 108 L)")
ok(C.lockerRoom({ repairkit = 1 }, "repairkit", 80, 120) == true, "…and lets a kit in")

-- ── 5. the live tab: builder → plan → save ──────────────────────────────────
build({ { 1, "pod", 2.0 }, { 2, "locker", 1.0 }, { 3, "tankS", 0.0 } })
C.sync(true)
local sp = C.seatPlan()
ok(sp[1] and sp[1][1] == 1, "the craft's first crewed part puts the avatar in the pod (shipyard.crew)")
ok(SAVE["shipyard.crew"][1].uid == 1 and SAVE["shipyard.crew"][1].slot == 1 and SAVE["shipyard.crew"][1].id == 1,
  "the plan is saved as crew.lua's { {uid, slot, id} } list")
-- add a cabin: AUTO fills it
build({ { 1, "pod", 2.0 }, { 4, "cabin", 1.5 }, { 2, "locker", 1.0 }, { 3, "tankS", 0.0 } })
C.sync(false)
ok(C.seatPlan()[1][1] == 1, "adding a part keeps the plan")
ok(C.seatMember(2, 4, 1), "a member at base is seated in the cabin")
ok(not C.seatMember(2, 4, 2), "…and can't be seated twice")
ok(not C.seatMember(4, 4, 2), "a member aboard another craft is refused at drop")
ok(hints[#hints]:find("Kestrel I"), "…and the builder's hint says why")
C.auto()
local ap = C.seatPlan()
ok(ap[1][1] == 1 and #C.seatedIds(ap) == 3, "AUTO: the avatar commands, everyone available is aboard (1, 2, 3)")
-- describe draws without error and shows the seat cards and the block
local out = {}
C.describe(B, out)
local function flat(t, acc)
  acc = acc or {}
  if type(t) ~= "table" then return acc end
  acc[#acc + 1] = t
  for i = 2, #t do if type(t[i]) == "table" then flat(t[i], acc) end end
  if t.items then for _, it in ipairs(t.items) do flat(it, acc) end end
  return acc
end
local all = {}
for _, r in ipairs(out) do flat(r, all) end
local function says(list, needle)
  for _, r in ipairs(list) do if r.text and tostring(r.text):find(needle, 1, true) then return r end end
end
ok(says(all, "D.OKAFOR★"), "the commander's card carries ★")
ok(says(all, "J.REYES"), "a passenger's card is drawn")
ok(says(all, "LOCKER #1"), "the locker part has its plan box")
ok(says(all, "STOCK (base)"), "the base stock is listed")
local theo = says(all, "T.VANCE")
ok(theo and theo.opacity < 1 and not theo.draggable, "a member aboard elsewhere is greyed and can't be dragged")
-- item moves: stock → locker plan, stock → pack, pack → stock
local st = C.state()
st.sel = 1
ok(C.moveOne("repairkit", "stock", 2), "a repair kit is planned into the locker")
ok(C.lockerPlanMap()[2].repairkit == 1, "…shipyard.lockerPlan carries it")
ok(BAGS.base.repairkit == 4, "…and the stock keeps it until launch")
ok(C.moveOne("repairkit", "stock", "pack"), "a kit goes from the stock into the pack")
ok(BAGS["crew:1"].repairkit == 1 and BAGS.base.repairkit == 3, "…moved at once (packs are real containers)")
for _ = 1, 3 do C.moveOne("repairkit", "stock", 2) end
local okF, whyF = C.moveOne("repairkit", "stock", 2)
ok(not okF and whyF:find("none free"), "the stock can't be planned twice over: " .. tostring(whyF))
ok(C.moveOne("repairkit", 2, "stock"), "a planned kit goes back to the stock")
ok(C.moveOne("gravgun", "pack", "stock"), "a tool goes from the pack to the stock")
-- the launch block reads the live plan
SAVE["shipyard.crew"] = {}
ok(C.launchBlock() == nil, "the live launch block, with the plan emptied: the avatar flies it")
-- a part removed: its plan goes
build({ { 1, "pod", 2.0 }, { 3, "tankS", 0.0 } })
C.moveOne("repairkit", "stock", 2)
C.sync(false)
ok(C.lockerPlanMap()[2] == nil, "a locker part taken off takes its plan with it")

-- ── 6. the Astronaut Complex ────────────────────────────────────────────────
local P = load("solar/scripts/crew_roster_panel.lua")
local el = { visible = false }
local made
P.ui = nil
local node = { getcomponent = function() return el end }
P.start(node)
P.openPanel("ROSTER")
ok(P.isOpen(), "openPanel shows it")
local tree = P.describe()
local rows = flat(tree)
ok(says(rows, "Astronaut Complex"), "the heading")
ok(says(rows, "Dana Okafor") and says(rows, "On foot (you)"), "the roster: name and status")
ok(says(rows, "Aboard Kestrel I"), "…where a member aboard is")
ok(says(rows, "4 flights · 30 min on EVA · 1 flag · 2 repairs"), "…and the service record")
ok(not says(rows, "Rina Ito"), "the dead are not on the roster")
-- Go to / Recall for the member on foot elsewhere
local function btn(list, parentKey, key)
  for _, r in ipairs(list) do
    if r.key == parentKey then
      for _, x in ipairs(flat(r)) do if x[1] == "button" and x.key == key then return x end end
    end
  end
end
local go = btn(rows, "m6", "go")
ok(go and not go.disabled, "Go to is offered for someone on foot elsewhere")
go.onClicked()
ok(controlled[1] == 6, "…and calls crew.control")
P.openPanel("ROSTER")
rows = flat(P.describe())
ok(btn(rows, "m1", "go").disabled, "…but not for yourself")
local rc = btn(rows, "m6", "rc")
rc.onClicked()
ok(#spent == 0, "the first Recall press only arms")
rows = flat(P.describe())
ok(btn(rows, "m6", "rc").text:find("Confirm"), "…and says what it costs")
btn(rows, "m6", "rc").onClicked()
ok(#spent == 1 and crew.get(6).status == "base", "the second press pays the pickup fee and brings them home")
-- applicants: hire
P.openPanel("APPLICANTS")
rows = flat(P.describe())
ok(says(rows, "Ada Moreau") and says(rows, "$1400"), "the applicants with their fee")
local h = btn(rows, "o1", "h")
h.onClicked()
ok(hired[1] == "Ada Moreau", "HIRE hires through crew.hire")
-- the free volunteer when everyone is dead
local saved = ROSTER
ROSTER = { { id = 5, name = "Rina Ito", status = "dead", died = { cause = "o2", body = "Vever" } } }
OFFERS[1].cost = 0
rows = flat(P.describe())
ok(says(rows, "FREE · a volunteer"), "with everyone dead the first applicant is FREE")
ok(says(rows, "Every astronaut is lost"), "…and the tab says why")
ROSTER = saved
-- the memorial
P.openPanel("MEMORIAL")
rows = flat(P.describe())
ok(says(rows, "† Rina Ito"), "the memorial lists the dead")
ok(says(rows, "Killed on impact (17 m/s), Day 42, Y1 on Nami."), "…the cause in plain words, the date and the place")
ok(says(rows, "craft Kestrel II"), "…the craft")
ok(says(rows, "3 flights · 15 min on EVA · 2 flags planted"), "…the service record")
ok(says(rows, "Remains on Nami"), "…and where the remains are")
ok(P.causeText({ cause = "heat" }) == "burned on re-entry" and P.causeText({ cause = "drown" }) == "drowned",
  "every cause has plain words")
P.close()
ok(not P.isOpen(), "close hides it")

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL: " .. f) end
  print(string.format("%d/%d checks failed", #failures, checks))
  os.exit(1)
end
print(string.format("smoke_builder_crew: %d checks passed", checks))
