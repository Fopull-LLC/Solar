-- SMOKE: seats and slots (docs/crew-and-items.md §3.1–3.3; crew slice 2):
-- scripts/crew.lua's seat rulebook and vessel_controller's seat API, against
-- stubs.
--
--   * crew.SEATS agrees with the registry's `seats`/`hatch` (parts_registry,
--     parts_aero), and #seats equals the command (or cabin) crew;
--   * a Pod Mk2 + Command Seat blueprint gives 4 slots; a Crew Cabin 4 more
--     that command nothing;
--   * the slot rides the part's own state as plain numbers (st.crew<k>):
--     electronics.packRecord → a fleet record → decodeState keeps it, so a
--     staging split, a docking (records merged) and a reload carry the seats;
--   * the commander is the best command slot (a pod over a seat, a cabin
--     never); boarding fills the free slot of the part you walked up to;
--   * the VAB seat plan: validatePlan refuses double booking and a plan with
--     nobody at the controls; launchPlan drops what isn't available and seats
--     the avatar at the controls when the plan leaves them empty;
--   * vessel_controller: seatsOf / crewIds / commander / seatMember /
--     freeSeat / boardNow into a free slot / a full part refuses / standDown
--     frees the avatar's seat / controlState needs someone at the controls.
--
--   luajit solar/tests/smoke_crew_seats.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function vec3(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end

-- ── the libraries ──────────────────────────────────────────────────────────
local store = { g_seed = 7 }
local scripts = {}
local function env(extra)
  local E = setmetatable({
    time = 1.0, vec3 = vec3,
    save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end,
             delete = function(k) store[k] = nil end },
    findScript = function(k) return scripts[k] end,
    findScripts = function(k) return scripts["*" .. k] or {} end,
    find = function() return nil end, log = function() end,
  }, { __index = _G })
  for k, v in pairs(extra or {}) do E[k] = v end
  return E
end
local function load(path, E)
  local f = assert(loadfile(path))
  setfenv(f, E)
  f()
  if E.defaults then E.params = {}; for k, v in pairs(E.defaults) do E.params[k] = v end end
  return E
end
local C = load("solar/scripts/crew.lua", env())
local EL = load("solar/scripts/electronics.lua", env())
scripts.crew, scripts.electronics = C, EL
local R = load("solar/scripts/parts_registry.lua", env())
local A = load("solar/scripts/parts_aero.lua", env())

-- ── SEATS mirrors the registry ─────────────────────────────────────────────
local function same_seats(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    for _, k in ipairs({ "x", "y", "z", "yaw" }) do
      if math.abs((a[i][k] or 0) - (b[i][k] or 0)) > 1e-6 then return false end
    end
  end
  return true
end
for _, id in ipairs({ "pod", "podMk2", "cabin", "seat" }) do
  local reg, def = R.REG[id], C.SEATS[id]
  check(reg and reg.seats and def and same_seats(reg.seats, def.seats), id .. ": crew.SEATS = the registry's seats")
  local crew = 0
  for _, m in ipairs(reg.mods or {}) do if (m.type == "command" or m.type == "cabin") then crew = m.crew end end
  check(#reg.seats == crew, id .. ": #seats = its crew (" .. #reg.seats .. " / " .. crew .. ")")
  if reg.hatch then
    for _, k in ipairs({ "x", "y", "z", "nx", "ny", "nz" }) do
      check(math.abs(reg.hatch[k] - def.hatch[k]) < 1e-6, id .. ": hatch." .. k .. " agrees")
    end
  end
end
check(same_seats(A.PARTS.cockpit.seats, C.SEATS.cockpit.seats), "cockpit: crew.SEATS = parts_aero's seats")
check(C.SEATS.cabin.command == false and C.SEATS.podMk2.command == true and C.SEATS.seat.open == true,
  "a cabin commands nothing; the Mk2 does; a seat is open")
check(C.seatDef({ id = "modpod", kind = "crewed" }) == C.SEATS.pod, "an unknown crewed part: one slot, like the Mk1")
check(C.seatDef({ id = "tankS", kind = "tank" }) == nil, "a tank has no seats")

-- ── slots on a blueprint ───────────────────────────────────────────────────
local BP = {
  { uid = 1, id = "roverBody", kind = "probe", x = 0, y = 0.6, z = 0 },
  { uid = 2, id = "podMk2", kind = "crewed", x = 0, y = 1.8, z = 0, parent = 1 },
  { uid = 3, id = "seat", kind = "crewed", seat = 1, x = 1.0, y = 1.4, z = 0, parent = 1 },
  { uid = 4, id = "cabin", kind = "structural", x = -1.2, y = 1.4, z = 0, parent = 1 },
}
local n = 0
for _, d in ipairs(BP) do n = n + C.slotCount(d) end
check(n == 8, "Pod Mk2 + Seat + Cabin: 3 + 1 + 4 = 8 slots (" .. n .. ")")
local cmd = 0
for _, d in ipairs(BP) do local def = C.seatDef(d); if def and def.command then cmd = cmd + #def.seats end end
check(cmd == 4, "4 of them at the controls (the Mk2's three and the seat)")
C.setMemberAt(BP[2], 2, 5)
C.setMemberAt(BP[3], 1, 6)
C.setMemberAt(BP[4], 3, 7)
check(BP[2].st.crew2 == 5 and C.memberAt(BP[2], 2) == 5 and C.memberAt(BP[2], 1) == nil, "a slot is st.crew<k>")
local seated = C.seatedIn(BP)
check(#seated == 3 and seated[1].id == 5 and seated[3].id == 7 and seated[3].command == false, "seatedIn lists them in part order")
check(C.commanderOf(BP) == 5, "the commander: the pod's member, over the seat's")
C.setMemberAt(BP[2], 2, nil)
check(C.commanderOf(BP) == 6, "the pod empty: the seat's rider commands")
C.setMemberAt(BP[3], 1, nil)
check(C.commanderOf(BP) == nil, "only a cabin passenger: nobody at the controls")
local u, k = C.freeSlot(BP, 4)
check(u == 4 and k == 1, "boarding the cabin: its first free slot")
u, k = C.freeSlot(BP, nil)
check(u == 2 and k == 1, "boarding anywhere: the best command slot first")
check(select(1, C.slotOf(BP, 7)) == 4 and select(2, C.slotOf(BP, 7)) == 3, "slotOf finds a member")

-- ── the seats ride the records ─────────────────────────────────────────────
C.setMemberAt(BP[2], 1, 5)
BP[2].st.hp = 0.6
local packed = EL.packRecord(BP[2])
check(type(packed.st) == "table" and packed.st.crew1 == 5 and packed.st.hp == 0.6, "packRecord keeps the slot (a number)")
store["fleet.craft"] = { c1 = { parts = { packed } } }
local back = store["fleet.craft"].c1.parts[1]
check(C.memberAt(back, 1) == 5, "a fleet record → reload: the member is still in slot 1")
local strform = { uid = 9, id = "pod", kind = "crewed", st = "crew1=3,hp=1" }
check(C.memberAt(strform, 1) == 3, "an old string-encoded state decodes")
-- a docking merges the two crafts' records: each part keeps its own seats
local merged = { BP[2], BP[4], strform }
local ids = {}
for _, s in ipairs(C.seatedIn(merged)) do ids[#ids + 1] = s.id end
check(#ids == 3, "docked: both crafts' crew in one list (" .. table.concat(ids, ",") .. ")")

-- ── the VAB plan ───────────────────────────────────────────────────────────
local P2 = { { uid = 1, id = "engineS", kind = "engine" }, { uid = 2, id = "podMk2", kind = "crewed", parent = 1 },
             { uid = 3, id = "cabin", kind = "structural", parent = 2 } }
check(C.validatePlan(P2, { { uid = 2, slot = 1, id = 1 }, { uid = 3, slot = 2, id = 2 } }) == true, "a good plan")
check(select(2, C.validatePlan(P2, { { uid = 2, slot = 1, id = 1 }, { uid = 2, slot = 1, id = 2 } })) == "two crew in one seat", "double booking a seat")
check(select(2, C.validatePlan(P2, { { uid = 2, slot = 1, id = 1 }, { uid = 3, slot = 1, id = 1 } })) == "one crew member in two seats", "one member twice")
check(select(2, C.validatePlan(P2, { { uid = 3, slot = 1, id = 2 } })) == "nobody at the controls", "only passengers")
check(select(2, C.validatePlan(P2, { { uid = 2, slot = 4, id = 2 } })) == "no such seat", "a slot past the part's seats")
local avail = function(id) return id ~= 9 end
local list, cmdr = C.launchPlan(P2, { { uid = 2, slot = 2, id = 3 }, { uid = 3, slot = 1, id = 9 }, { uid = 3, slot = 2, id = 2 } }, avail, 1)
check(#list == 2 and cmdr == 3, "launch: the unavailable member is dropped; #3 commands (" .. #list .. ", " .. tostring(cmdr) .. ")")
list, cmdr = C.launchPlan(P2, { { uid = 3, slot = 1, id = 2 } }, avail, 1)
check(#list == 2 and cmdr == 1, "passengers only: the avatar takes the controls")
list, cmdr = C.launchPlan(P2, nil, avail, 1)
check(#list == 1 and list[1].uid == 2 and list[1].slot == 1 and cmdr == 1, "no plan: today's launch, the avatar in the pod")

-- ── vessel_controller's seat API ───────────────────────────────────────────
store["crew.version"] = nil
local astro = { name = "Astronaut", valid = true, visible = true, x = 0, y = 0, z = 0, id = 99 }
C.reset()
C.ensure()
check(C.activeId() == 1 and #C.roster() == 3, "a new store: three starters, #1 the avatar")
local VBP = { parts = {
  { uid = 1, id = "plate", kind = "structural", x = 0, y = 0.62, z = 0 },
  { uid = 6, id = "podMk2", label = "Pod Mk2", kind = "crewed", x = -0.4, y = 1.3, z = 0, parent = 1 },
  { uid = 7, id = "seat", kind = "crewed", seat = 1, x = 0.45, y = 1.17, z = 0, parent = 1 },
} }
store["shipyard.blueprint"] = VBP
local VE
VE = setmetatable({
  vec3 = vec3, time = 10.0,
  find = function(nm) if nm == "Astronaut" then return astro end end,
  findScripts = function() return {} end,
  findScript = function(k) return scripts[k] end,
  save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
  overlapSphere = function() return {} end,
  space = { dominant = function() return nil end, body = function() return nil end },
  log = function() end,
}, { __index = function(_, k)
  if _G[k] ~= nil then return _G[k] end
  return function() end
end })
local vc = assert(loadfile("solar/scripts/vessel_controller.lua"))
setfenv(vc, VE)
vc()
VE.params = {}
for k2, v in pairs(VE.defaults) do VE.params[k2] = v end
local node = { id = 5, valid = true, x = 0, y = 0, z = 0, yaw = 0, pitch = 0, roll = 0, name = "Vessel",
               children = function() return {} end }
local info = { origin = vec3(0, 0, 0), vel = vec3(0, 0, 0), parts = {} }
VE.start(node)
local seats = VE.seatsOf()
check(#seats == 4, "the craft's slots: the Mk2's three and the seat (" .. #seats .. ")")
check(#VE.crewSeats == 2 and VE.crewSeats[1].slots == 3, "crew positions per part, with their slot counts")
check(VE.seatMember(6, 2, 2) == true and VE.crewIds()[1] == 2, "seat #2 in the Mk2: they're aboard and at the controls")
check(select(2, VE.seatMember(6, 2, 3)) == "that seat is taken", "a taken seat refuses")
check(VE.seatMember(6, 3, 3) == true and #VE.crewIds() == 2, "#3 beside them")
check(VE.commander() == 2, "the commander: the lowest command slot")
local fu, fk = VE.freeSeat(6)
check(fu == 6 and fk == 1, "free seat in the Mk2: slot 1")
-- the avatar (#1) walks up to the pod and presses F
astro.x, astro.y, astro.z = -2.0, 1.2, 0.0
check(VE.boardNow(node, info) == true, "F at the pod: aboard")
check(select(1, VE.memberSlot(1)) == 6 and select(2, VE.memberSlot(1)) == 1, "...in the Mk2's free slot 1")
check(VE.crewCount() == 3 and VE.commander() == 1, "three aboard; the avatar's slot 1 commands")
VE.standDown(node, -2.0, 1.2, 0.0, 0, 0, 0)
check(VE.memberSlot(1) == nil and VE.crewCount() == 2, "stepping out frees the avatar's seat; the others stay")
-- the Mk2 full: walk up to it again and F boards the seat instead
VE.seatMember(6, 1, 4)
VE.time = 30.0
check(VE.boardNow(node, info) == true and VE.memberSlot(1) == 7, "the pod full: F takes the free seat elsewhere aboard")
VE.standDown(node, -2.0, 1.2, 0.0, 0, 0, 0)
VE.seatMember(7, 1, 5)
VE.time = 40.0
check(VE.boardNow(node, info) == false, "every seat taken: F refuses")
check(VE.boardPrompt(VE.crewSeats[1]):match("full") ~= nil, "the prompt says so (" .. VE.boardPrompt(VE.crewSeats[1]) .. ")")
VE.seatMember(7, 1, nil)
check(VE.boardPrompt(VE.crewSeats[2]) == "F — sit in the seat", "a free seat: sit in it")
VE.seatMember(6, 1, nil)
check(VE.boardPrompt(VE.crewSeats[1]) == "F — board Pod Mk2 (1 free)", "the pod names its free slots (" .. VE.boardPrompt(VE.crewSeats[1]) .. ")")
check(VE.depHasCrew({ [6] = true }) == true and VE.depHasCrew({ [7] = true }) == false, "a departing set with crew in it leaves as a craft")
check(VE.unseatMember(2) == true and VE.memberSlot(2) == nil, "unseatMember")
-- the manifest a fleet record is made from carries the seats
local fp = VE.fleetParts()
local carried = 0
for _, r in ipairs(fp.parts) do if type(r.st) == "table" and r.st.crew3 then carried = carried + 1 end end
check(carried == 1, "the fleet manifest carries the slots")

if #failures > 0 then
  for _, m in ipairs(failures) do print("FAIL: " .. m) end
  print(string.format("smoke_crew_seats: %d passed, %d FAILED", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_crew_seats: all %d checks passed", passed))
