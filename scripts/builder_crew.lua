-- BUILDER_CREW — the VAB's CREW tab (docs/crew-and-items.md §5.6; WS2).
--
-- Who flies the craft on the stand, and what they and its lockers carry.
-- builder_inspector hosts it as its fifth tab (after CRAFT) and calls
-- describe(B, out); everything else here is plain rules over plain tables,
-- so it loads in luajit (tests/smoke_builder_crew.lua).
--
--   SEATS     one box per slot of every crewed part, in stack order (top
--             first). Drag a roster card onto a box (or click the card: it
--             takes the picked box, else the first free one). ★ marks the
--             commander: the member in the highest-ranked command slot
--             (pod or cockpit over an open seat, then the lowest slot; a
--             cabin carries people but commands nothing, §3.3). [AUTO]
--             fills every slot from who is at base, the avatar first.
--   ROSTER    every member. Greyed: aboard another craft, away on foot,
--             or dead. [+ HIRE…] lists the applicants inline.
--   LOADOUT   a seated member's pack (click a seat card to pick whose), one
--             box per locker part's PLAN, and the base STOCK. Drag an item
--             between boxes, or click it and then click the box. BUY ▸ lists
--             the depot's shop and buys into the stock.
--
-- THE PLANS (save keys; vessel_spawner applies them at launch, WS1):
--
--   shipyard.crew        { { uid = <uid>, slot = k, id = memberId }, … }
--                        the seat plan, in crew.lua's launchPlan/validatePlan
--                        shape (WS1): builder uids (the blueprint keeps them,
--                        bp.parts[i].uid). seatPlan() hands it over as
--                        { [uid] = { [slot] = id } }, the shape this file's
--                        rules work in.
--   shipyard.lockerPlan  { ["<uid>"] = { [itemId] = n } }
--                        what each locker part should carry. Lockers have no
--                        container until launch (vessel_controller
--                        lockerRegister assigns st.locker), so this is a plan:
--                        at launch move n of each item from "base" into
--                        "locker:<st.locker>" (buy the shortfall, itemised on
--                        the launch cost). lockerPlanMap() → number keys.
--
-- Packs are real containers ("crew:<id>"), so pack moves happen at once
-- through inventory.moveItem; only lockers are planned.
--
-- THE RULES (also the API the builder's launch check calls):
--   launchBlock(parts?, plan?) → why | nil   crewed command parts with nobody
--                         at the controls and no probe core: "nobody can fly
--                         it: put someone in the Pod Mk1"
--   launchWarn(parts?, plan?, lplan?) → { line… }   > 30 parts and nobody
--                         (pack or locker plan) carries a Repair Kit
--   canSeat(plan, cparts, roster, active, id, uid, slot, from) → ok, why
--   seat(plan, id, uid, slot, from) · unseat(plan, uid, slot)
--   slotsOf(def) → n, "command"|"cabin"|nil, rank
--   crewedParts(parts) → { {uid, label, slots, command, rank, open}… }
--   commanderOf(cparts, plan) → id, uid, slot
--   defaultPlan(plan, cparts, roster, active) → plan, changed
--   autoPlan(cparts, roster, active) → plan
--   prune(plan, cparts, roster, active) → plan, changed
--   available(rec, active) → ok, why
--
-- `parts` everywhere is a list of { uid, id, def, y } (def = the registry
-- entry: kind, label, mods, seats, store, seat).

version = 0
local function bump() version = (version or 0) + 1 end

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end

local function call(obj, fn, ...)
  if not (obj and type(obj[fn]) == "function") then return nil end
  local ok, a, b, c = pcall(obj[fn], ...)
  if ok then return a, b, c end
  return nil
end

-- ── slots, ranks and the crewed parts ───────────────────────────────────────
-- Slot count: the part's `seats` list (WS1, §3.1); before that lands, the
-- command or cabin module's `crew`; a "crewed" part with neither seats one.
-- Rank: 2 a closed command part (pod, cockpit), 1 an open command seat,
-- 0 a cabin (passengers only).
function slotsOf(def)
  if type(def) ~= "table" then return 0, nil, 0 end
  local n, kind, seatlike = nil, nil, def.seat == true
  for _, m in ipairs(def.mods or {}) do
    if m.type == "command" and (m.crew or 0) > 0 then
      n, kind = m.crew, "command"
      if m.seat then seatlike = true end
    elseif m.type == "cabin" and (m.crew or 0) > 0 and not kind then
      n, kind = m.crew, "cabin"
    end
  end
  if type(def.seats) == "table" and #def.seats > 0 then
    n = #def.seats
    if not kind then kind = (def.kind == "crewed") and "command" or "cabin" end
    if def.seats[1].open then seatlike = true end
  end
  if not n and def.kind == "crewed" then n, kind = 1, "command" end
  if not n or n <= 0 then return 0, nil, 0 end
  local rank = kind == "cabin" and 0 or (seatlike and 1 or 2)
  return math.floor(n), kind, rank
end

function isProbe(def)
  if type(def) ~= "table" then return false end
  if def.kind == "probe" then return true end
  for _, m in ipairs(def.mods or {}) do
    if m.type == "command" and (m.crew or 0) == 0 then return true end
  end
  return false
end

function lockerCap(def)
  return type(def) == "table" and tonumber(def.store) or 0
end

-- Stack order: the top of the craft first, then by uid (stable).
local function stack_sort(a, b)
  local ya, yb = a.y or 0, b.y or 0
  if math.abs(ya - yb) > 1e-3 then return ya > yb end
  return a.uid < b.uid
end

function crewedParts(parts)
  local out = {}
  for _, p in ipairs(parts or {}) do
    local n, kind, rank = slotsOf(p.def)
    if n > 0 then
      out[#out + 1] = { uid = p.uid, id = p.id, label = (p.def and p.def.label) or p.id or "part",
                        slots = n, command = kind == "command", rank = rank, y = p.y or 0,
                        open = rank == 1 }
    end
  end
  table.sort(out, stack_sort)
  return out
end

function lockerParts(parts)
  local out = {}
  for _, p in ipairs(parts or {}) do
    local cap = lockerCap(p.def)
    if cap > 0 then
      out[#out + 1] = { uid = p.uid, label = (p.def and p.def.label) or p.id or "Locker", cap = cap, y = p.y or 0 }
    end
  end
  table.sort(out, stack_sort)
  for i, l in ipairs(out) do l.n = i end
  return out
end

-- Everything on the craft that carries kit: its Stowage Lockers (each its own
-- container in flight, "locker:<n>") and its Cargo Bays (pooled in flight into
-- the craft's hold, 250 kg and 1000 L a bay). Stack order, numbered per kind.
--   { uid, label, kind = "locker"|"hold", cap (kg), vol (L), n, y }
function storageParts(parts, vol)
  vol = vol or { locker = 120, bay = 1000 }
  local out = {}
  for _, p in ipairs(parts or {}) do
    local d = p.def or {}
    local cap = lockerCap(d)
    if cap > 0 then
      out[#out + 1] = { uid = p.uid, label = d.label or p.id or "Locker", kind = "locker", cap = cap,
                        vol = tonumber(d.vol) or vol.locker or 120, y = p.y or 0 }
    elseif (tonumber(d.cargo) or 0) > 0 then
      out[#out + 1] = { uid = p.uid, label = d.label or p.id or "Cargo Bay", kind = "hold", cap = tonumber(d.cargo),
                        vol = (vol.bay or 1000) * math.max(1, math.ceil(tonumber(d.cargo) / 250 - 1e-9)), y = p.y or 0 }
    end
  end
  table.sort(out, stack_sort)
  local n = { locker = 0, hold = 0 }
  for _, l in ipairs(out) do n[l.kind] = n[l.kind] + 1; l.n = n[l.kind] end
  return out
end
function storageTitle(l)
  return string.format("%s #%d", l.kind == "hold" and "CARGO BAY" or "LOCKER", l.n or 1)
end

-- Command slots in the order the controller ranks them: highest rank, then
-- stack order, then the lowest slot.
function commandSlots(cparts)
  local by = { [2] = {}, [1] = {} }
  for _, c in ipairs(cparts or {}) do
    if c.command then
      local r = by[c.rank] or {}
      by[c.rank] = r
      for s = 1, c.slots do r[#r + 1] = { uid = c.uid, slot = s, rank = c.rank, label = c.label } end
    end
  end
  local out = {}
  for _, rk in ipairs({ 2, 1 }) do for _, e in ipairs(by[rk] or {}) do out[#out + 1] = e end end
  return out
end

-- ── the seat plan (pure: number keys) ───────────────────────────────────────
function seatAt(plan, uid, slot)
  local p = plan and plan[uid]
  return p and p[slot] or nil
end

function whereSeated(plan, id)
  for uid, slots in pairs(plan or {}) do
    for s, m in pairs(slots) do if m == id then return uid, s end end
  end
  return nil
end

function seatedIds(plan)
  local out = {}
  for _, slots in pairs(plan or {}) do for _, m in pairs(slots) do if m then out[#out + 1] = m end end end
  table.sort(out)
  return out
end

function commanderOf(cparts, plan)
  for _, s in ipairs(commandSlots(cparts)) do
    local m = seatAt(plan, s.uid, s.slot)
    if m then return m, s.uid, s.slot end
  end
  return nil
end

-- Who can be planned onto THIS craft: at base, or the avatar itself (on foot
-- here, at the VAB). Aboard another craft, away on foot, or dead: no.
function available(rec, active)
  if type(rec) ~= "table" then return false, "no such crew member" end
  if rec.status == "dead" then return false, "dead" end
  if rec.status == "aboard" then
    return false, "aboard " .. tostring(rec.craft or "another craft")
  end
  if rec.status == "afoot" and rec.id ~= active then
    return false, "away on foot" .. (rec.body and (" on " .. tostring(rec.body)) or "")
  end
  return true, nil
end

local function find_rec(roster, id)
  for _, r in ipairs(roster or {}) do if r.id == id then return r end end
  return nil
end

local function part_of(cparts, uid)
  for _, c in ipairs(cparts or {}) do if c.uid == uid then return c end end
  return nil
end

-- `from` = { uid, slot } when the card was dragged out of a seat (a move),
-- nil when it came from the roster.
function canSeat(plan, cparts, roster, active, id, uid, slot, from)
  local c = part_of(cparts, uid)
  if not c then return false, "not a crewed part" end
  if slot < 1 or slot > c.slots then return false, "no such seat" end
  local rec = find_rec(roster, id)
  local ok, why = available(rec, active)
  if not ok then return false, (rec and rec.name or "they") .. " is " .. why end
  local su, ss = whereSeated(plan, id)
  if su and not (from and from.uid == su and from.slot == ss) then
    if su == uid and ss == slot then return false, "already there" end
    local sp = part_of(cparts, su)
    return false, string.format("%s is already in the %s, seat %d — drag them from there",
      rec.name or "they", sp and sp.label or "craft", ss)
  end
  return true, nil
end

-- Seat `id` at uid/slot. Whoever sat there goes back to the roster, or, when
-- the card came from another seat, swaps into it.
function seat(plan, id, uid, slot, from)
  plan = plan or {}
  local prev = seatAt(plan, uid, slot)
  if from then
    local f = plan[from.uid]
    if f then f[from.slot] = nil end
  end
  plan[uid] = plan[uid] or {}
  plan[uid][slot] = id
  if prev and prev ~= id and from then
    plan[from.uid] = plan[from.uid] or {}
    plan[from.uid][from.slot] = prev
  end
  return plan
end

function unseat(plan, uid, slot)
  if plan and plan[uid] then
    plan[uid][slot] = nil
    if next(plan[uid]) == nil then plan[uid] = nil end
  end
  return plan
end

-- Drop what no longer fits the craft: parts gone, slots past the count,
-- members no longer available, a member in two places (the later goes).
function prune(plan, cparts, roster, active)
  local changed = false
  local out, seen = {}, {}
  for _, c in ipairs(cparts or {}) do
    local slots = plan and plan[c.uid]
    if slots then
      for s = 1, c.slots do
        local m = slots[s]
        if m then
          local ok = available(find_rec(roster, m), active)
          if ok and not seen[m] then
            seen[m] = true
            out[c.uid] = out[c.uid] or {}
            out[c.uid][s] = m
          else
            changed = true
          end
        end
      end
      for s in pairs(slots) do if type(s) ~= "number" or s > c.slots then changed = true end end
    end
  end
  for uid in pairs(plan or {}) do if not part_of(cparts, uid) then changed = true end end
  return out, changed
end

-- Who gets the commander slot by default: the avatar, else the member who
-- most recently flew or was hired (highest id), if available.
function defaultMember(roster, active)
  local r = find_rec(roster, active)
  if r and available(r, active) then return active end
  local best
  for _, x in ipairs(roster or {}) do
    if available(x, active) and (not best or x.id > best) then best = x.id end
  end
  return best
end

function defaultPlan(plan, cparts, roster, active)
  plan = plan or {}
  if #seatedIds(plan) > 0 then return plan, false end
  local slots = commandSlots(cparts)
  if #slots == 0 then return plan, false end
  local m = defaultMember(roster, active)
  if not m then return plan, false end
  return seat(plan, m, slots[1].uid, slots[1].slot), true
end

-- Every slot filled from who is available: command slots first (the avatar
-- in the commander's), then the rest in stack order.
function autoPlan(cparts, roster, active)
  local plan, queue, used = {}, {}, {}
  local first = defaultMember(roster, active)
  if first then queue[1] = first; used[first] = true end
  for _, r in ipairs(roster or {}) do
    if not used[r.id] and available(r, active) then queue[#queue + 1] = r.id; used[r.id] = true end
  end
  local order = commandSlots(cparts)
  for _, c in ipairs(cparts) do
    if not c.command then for s = 1, c.slots do order[#order + 1] = { uid = c.uid, slot = s } end end
  end
  for i, s in ipairs(order) do
    if not queue[i] then break end
    seat(plan, queue[i], s.uid, s.slot)
  end
  return plan
end

-- ── the plans in the save (string keys there, number keys here) ─────────────
function encodeSeats(plan)
  local out = {}
  for uid, slots in pairs(plan or {}) do
    for s, m in pairs(slots) do
      if m then out[#out + 1] = { uid = uid, slot = s, id = m } end
    end
  end
  table.sort(out, function(a, b) if a.uid ~= b.uid then return a.uid < b.uid end return a.slot < b.slot end)
  return out
end

function decodeSeats(t)
  local out = {}
  if type(t) ~= "table" then return out end
  for _, e in ipairs(t) do
    local uid, s, m = tonumber(e.uid), tonumber(e.slot), e.id
    if uid and s and m then out[uid] = out[uid] or {}; out[uid][s] = m end
  end
  return out
end

local function encode_lockers(lp)
  local out = {}
  for uid, items in pairs(lp or {}) do
    local t = {}
    for id, n in pairs(items) do if n > 0 then t[id] = n end end
    if next(t) then out[tostring(uid)] = t end
  end
  return out
end

local function decode_lockers(t)
  local out = {}
  if type(t) ~= "table" then return out end
  for k, items in pairs(t) do
    local uid = tonumber(k)
    if uid and type(items) == "table" then
      out[uid] = {}
      for id, n in pairs(items) do if (tonumber(n) or 0) > 0 then out[uid][id] = math.floor(n) end end
    end
  end
  return out
end

function seatPlan() return decodeSeats(save and save.get("shipyard.crew")) end
function lockerPlanMap() return decode_lockers(save and save.get("shipyard.lockerPlan")) end

-- ── items in a planned locker ───────────────────────────────────────────────
local function item_def(id)
  local I = ref("items")
  if I and I.ITEMS then return I.ITEMS[id] end
  return nil
end

-- (a piece that weighs its fill, the Gas Can, is planned full: the most it weighs)
local function plan_kg(d)
  return (d.kg or 1) + ((d.fill and d.fill.kg) and (d.fill.cap or 0) * d.fill.kg or 0)
end
function lockerLoad(items, defOf)
  defOf = defOf or item_def
  local kg, L = 0, 0
  for id, n in pairs(items or {}) do
    local d = defOf(id) or {}
    kg = kg + plan_kg(d) * n
    L = L + (d.L or 1) * n
  end
  return kg, L
end

-- Room for one more `id` in a locker plan? → ok, why
function lockerRoom(items, id, cap, volCap, defOf)
  defOf = defOf or item_def
  local d = defOf(id) or {}
  local kg, L = lockerLoad(items, defOf)
  if kg + plan_kg(d) > cap + 1e-6 then return false, string.format("no room: %.0f kg free", math.max(0, cap - kg)) end
  if volCap and L + (d.L or 1) > volCap + 1e-6 then
    return false, string.format("no room: %.0f L free", math.max(0, volCap - L))
  end
  return true, nil
end

-- ── the launch check ────────────────────────────────────────────────────────
local CUR = { parts = nil, cparts = {}, lockers = {}, cv = nil }

function launchBlock(parts, plan)
  local cparts
  if parts then
    cparts = crewedParts(parts)
  else
    -- the craft on the stand; with no roster in this scene (a bare builder)
    -- there is nobody to plan, and today's behaviour stands: no block
    if not (ref("crew") and ref("crew").roster) then return nil end
    sync(false)
    cparts, parts = CUR.cparts, CUR.parts
  end
  if not parts then return nil end
  plan = plan or seatPlan()
  local probe = false
  for _, p in ipairs(parts) do if isProbe(p.def) then probe = true end end
  if probe then return nil end
  local slots = commandSlots(cparts)
  if #slots == 0 then return nil end
  if commanderOf(cparts, plan) then return nil end
  -- No plan at all: the crew member who walked into the VAB takes the first
  -- command seat at launch, as before seat planning existed. Only a plan that
  -- seats people and leaves the controls empty is refused.
  if #seatedIds(plan) == 0 then return nil end
  return "nobody can fly it: put someone in the " .. tostring(slots[1].label)
end

-- packCount(id, itemId) → n: how many the member's pack holds.
function launchWarn(parts, plan, lplan, packCount)
  if not parts then parts = CUR.parts end
  if not parts then return {} end
  plan = plan or seatPlan()
  lplan = lplan or lockerPlanMap()
  packCount = packCount or function(id, item)
    local inv = ref("inventory")
    return call(inv, "itemCount", "crew:" .. tostring(id), item) or 0
  end
  local out = {}
  if #parts > 30 then
    local kit = false
    for _, m in ipairs(seatedIds(plan)) do if (packCount(m, "repairkit") or 0) > 0 then kit = true end end
    for _, items in pairs(lplan) do if (items.repairkit or 0) > 0 then kit = true end end
    if not kit and #seatedIds(plan) > 0 then
      out[#out + 1] = string.format("%d parts and nobody carries a Repair Kit — put one in a pack or a locker", #parts)
    end
  end
  return out
end

-- ── the live craft (the builder's API) ──────────────────────────────────────
local function roster_now()
  local c = ref("crew")
  local r = call(c, "roster")
  return type(r) == "table" and r or {}
end
local function active_now() return call(ref("crew"), "activeId") end

local st = { sel = nil, pick = nil, pickItem = nil, drag = nil, over = nil, hiring = false, buying = false,
             msg = nil, msgT = -1e9, seenCrewed = false, session = false }

local function say(msg)
  st.msg, st.msgT = msg, time or 0
  local B = ref("builder")
  if B and B.hint then pcall(B.hint, msg, 3.0) end
  bump()
end

local function write_plan(plan)
  if save then save.set("shipyard.crew", encodeSeats(plan)) end
  bump()
end
local function write_lockers(lp)
  if save then save.set("shipyard.lockerPlan", encode_lockers(lp)) end
  bump()
end

-- Read the craft on the stand (only when it changed).
function sync(force)
  local B = ref("builder")
  if not (B and B.partUids) then return false end
  local cv = B.craftVersion
  if not force and cv == CUR.cv then return false end
  CUR.cv = cv
  local parts = {}
  for _, uid in ipairs(B.partUids() or {}) do
    local id = B.partIdOf and B.partIdOf(uid) or nil
    local def = id and B.partInfo and B.partInfo(id) or nil
    if not def then
      local r = B.partRec(uid)
      id, def = r and r.id, r and r.def
    end
    local y = 0
    if def and (slotsOf(def) > 0 or lockerCap(def) > 0 or (tonumber(def.cargo) or 0) > 0) then
      local r = B.partRec(uid)
      y = r and r.y or 0
    end
    parts[#parts + 1] = { uid = uid, id = id, def = def or {}, y = y }
  end
  CUR.parts = parts
  CUR.cparts = crewedParts(parts)
  local I = ref("items")
  CUR.lockers = storageParts(parts, I and I.VOL or nil)
  -- the plan follows the craft
  local roster, active = roster_now(), active_now()
  local plan, changed = prune(seatPlan(), CUR.cparts, roster, active)
  -- THE DEFAULT: the craft's first crewed part (or the first look at a
  -- crewed craft this session) puts the avatar in the commander's slot
  local crewed = #CUR.cparts > 0
  if crewed and (not st.seenCrewed or not st.session) and #roster > 0 then
    local p2, did = defaultPlan(plan, CUR.cparts, roster, active)
    if did then plan, changed = p2, true end
  end
  st.seenCrewed, st.session = crewed, true
  if changed then write_plan(plan) end
  local lp, lchanged = lockerPlanMap(), false
  for uid in pairs(lp) do
    local ok = false
    for _, l in ipairs(CUR.lockers) do if l.uid == uid then ok = true end end
    if not ok then lp[uid] = nil; lchanged = true end
  end
  if lchanged then write_lockers(lp) end
  bump()
  return true
end

function update(node, dt)
  sync(false)
  if booth_tick then pcall(booth_tick) end
end
-- the portrait booth's camera is aimed after everything is placed (rule 6)
function lateUpdate(node, dt)
  if booth_aim then booth_aim() end
end

function sig() return tostring(version) .. ":" .. tostring(call(ref("crew"), "version") or (ref("crew") or {}).version) end

-- ── moves (the tab's actions) ───────────────────────────────────────────────
function seatMember(id, uid, slot, from)
  sync(false)
  local plan = seatPlan()
  local ok, why = canSeat(plan, CUR.cparts, roster_now(), active_now(), id, uid, slot, from)
  if not ok then say("can't seat them — " .. why) return false, why end
  write_plan(seat(plan, id, uid, slot, from))
  st.sel = id
  return true
end

function unseatMember(id)
  local plan = seatPlan()
  local u, s = whereSeated(plan, id)
  if not u then return false end
  write_plan(unseat(plan, u, s))
  if st.sel == id then st.sel = nil end
  return true
end

-- A roster card clicked: into the picked box, else the first free command
-- slot, else the first free slot.
function seatFirstFree(id)
  sync(false)
  local plan = seatPlan()
  if st.pick then
    local p = st.pick
    st.pick = nil
    return seatMember(id, p.uid, p.slot)
  end
  local order = commandSlots(CUR.cparts)
  for _, c in ipairs(CUR.cparts) do
    if not c.command then for s = 1, c.slots do order[#order + 1] = { uid = c.uid, slot = s } end end
  end
  for _, s in ipairs(order) do
    if not seatAt(plan, s.uid, s.slot) then return seatMember(id, s.uid, s.slot) end
  end
  say("every seat is taken — drag a card out to the roster first")
  return false
end

function auto()
  sync(false)
  write_plan(autoPlan(CUR.cparts, roster_now(), active_now()))
end

local function base_free(id, lp)
  local inv = ref("inventory")
  local have = call(inv, "itemCount", "base", id) or 0
  local planned = 0
  for _, items in pairs(lp or lockerPlanMap()) do planned = planned + (items[id] or 0) end
  return have - planned
end

local function locker_of(uid)
  for _, l in ipairs(CUR.lockers) do if l.uid == uid then return l end end
  return nil
end

-- Move one `item` between "pack" (the selected member's), "stock" and a
-- locker part's uid (a number). → ok, why
function moveOne(item, from, to)
  if from == to then return false, "it's already there" end
  local inv = ref("inventory")
  if not inv then return false, "no inventory" end
  local pack = st.sel and ("crew:" .. tostring(st.sel)) or nil
  if (from == "pack" or to == "pack") and not pack then return false, "pick a seated member first" end
  local lp = lockerPlanMap()
  local why
  -- take it out of where it is
  if from == "pack" then
    if to == "stock" then
      local n, w = inv.moveItem(pack, "base", item, 1)
      if (n or 0) < 1 then return false, w or "can't" end
      bump(); return true
    end
    -- pack → locker: back to the base stock, then planned into the locker
    local l = locker_of(to)
    if not l then return false, "no such locker" end
    local ok, w = lockerRoom(lp[to], item, l.cap, l.vol)
    if not ok then return false, w end
    local n, w2 = inv.moveItem(pack, "base", item, 1)
    if (n or 0) < 1 then return false, w2 or "can't" end
    lp[to] = lp[to] or {}
    lp[to][item] = (lp[to][item] or 0) + 1
    write_lockers(lp)
    return true
  elseif from == "stock" then
    if base_free(item, lp) < 1 then return false, "none free in stock — BUY ▸ first" end
    if to == "pack" then
      local n, w = inv.moveItem("base", pack, item, 1)
      if (n or 0) < 1 then return false, w or "can't" end
      bump(); return true
    end
    local l = locker_of(to)
    if not l then return false, "no such locker" end
    local ok, w = lockerRoom(lp[to], item, l.cap, l.vol)
    if not ok then return false, w end
    lp[to] = lp[to] or {}
    lp[to][item] = (lp[to][item] or 0) + 1
    write_lockers(lp)
    return true
  else
    -- from a locker plan
    local items = lp[from]
    if not (items and (items[item] or 0) > 0) then return false, "none planned there" end
    if to == "pack" then
      if (call(inv, "itemCount", "base", item) or 0) < 1 then return false, "none in stock to hand over" end
      local n, w = inv.moveItem("base", pack, item, 1)
      if (n or 0) < 1 then return false, w or "can't" end
    elseif to ~= "stock" then
      local l = locker_of(to)
      if not l then return false, "no such locker" end
      local ok, w = lockerRoom(lp[to], item, l.cap, l.vol)
      if not ok then return false, w end
      lp[to] = lp[to] or {}
      lp[to][item] = (lp[to][item] or 0) + 1
    end
    items[item] = items[item] - 1
    if items[item] <= 0 then items[item] = nil end
    write_lockers(lp)
    return true
  end
  return false, why
end

-- BUY INTO STORAGE: one `item` planned straight into storage part `uid`
-- from the shop. What the base stock has free goes from there at launch; the
-- rest is bought then (kitForLaunch). → ok, why
function addToStorage(uid, item)
  sync(false)
  local l = locker_of(uid)
  if not l then return false, "no such locker" end
  local d = item_def(item)
  if not d then return false, "no such item" end
  local lp = lockerPlanMap()
  local ok, w = lockerRoom(lp[uid], item, l.cap, l.vol)
  if not ok then return false, w end
  lp[uid] = lp[uid] or {}
  lp[uid][item] = (lp[uid][item] or 0) + 1
  write_lockers(lp)
  return true
end
function removeFromStorage(uid, item)
  local lp = lockerPlanMap()
  local items = lp[uid]
  if not (items and (items[item] or 0) > 0) then return false, "none planned there" end
  items[item] = items[item] - 1
  if items[item] <= 0 then items[item] = nil end
  write_lockers(lp)
  return true
end

-- THE KIT AT LAUNCH. Every planned item, storage by storage in stack order:
-- what the base stock holds goes from there, the rest is bought at the shop
-- price. → { cost, take = {id = n}, buy = {id = n}, per = {[uid] = {cost, buy = {id = n}}},
--            pending = { lockers = {["uid"] = {id = n}}, holds = {["uid"] = true} } | nil }
-- (`pending` is what the builder hands the rollout: shipyard.kit.)
function kitForLaunch(lp)
  sync(false)
  lp = lp or lockerPlanMap()
  local inv = ref("inventory")
  local left, out = {}, { cost = 0, take = {}, buy = {}, per = {}, pending = nil }
  local pend = { lockers = {}, holds = {} }
  local any = false
  for _, l in ipairs(CUR.lockers) do
    local items = lp[l.uid]
    if items then
      local ids = {}
      for id, n in pairs(items) do if (n or 0) > 0 then ids[#ids + 1] = id end end
      table.sort(ids)
      local per = { cost = 0, buy = {} }
      local t = {}
      for _, id in ipairs(ids) do
        local n = items[id]
        if left[id] == nil then left[id] = math.max(0, call(inv, "itemCount", "base", id) or 0) end
        local take = math.min(left[id], n)
        left[id] = left[id] - take
        local buy = n - take
        local c = buy * ((item_def(id) or {}).cost or 0)
        out.cost, per.cost = out.cost + c, per.cost + c
        if take > 0 then out.take[id] = (out.take[id] or 0) + take end
        if buy > 0 then out.buy[id] = (out.buy[id] or 0) + buy; per.buy[id] = buy end
        t[id] = n
        any = true
      end
      out.per[l.uid] = per
      if next(t) then
        pend.lockers[tostring(l.uid)] = t
        if l.kind == "hold" then pend.holds[tostring(l.uid)] = true end
      end
    end
  end
  if any then out.pending = pend end
  return out
end

local function do_move(item, from, to)
  local ok, why = moveOne(item, from, to)
  if not ok and why then say("can't move it — " .. why) end
  local sfx = ref("sfx")
  if ok and sfx and sfx.play then pcall(sfx.play, "click") end
  return ok
end

-- ── the tab ─────────────────────────────────────────────────────────────────
-- Playtest 2026-11: "no reading required". Every member is a CARD you can
-- see — their face (PORTRAITS below), their name and what they are like —
-- and you put them aboard by dragging the card onto a seat. Seats light up
-- while a card is in your hand (orange rim: it can go there; the one under
-- the pointer warms), and a ghost of the card rides the pointer. Clicking
-- still works: a card into the picked seat, else the first free one.
function shortName(name)
  if type(name) ~= "string" then return "?" end
  local first, rest = name:match("^(%S+)%s+(.+)$")
  if not first then return name:upper() end
  return (first:sub(1, 1) .. "." .. rest):upper()
end

local function initials(name)
  if type(name) ~= "string" then return "?" end
  local a, b = name:match("^(%S)%S*%s+(%S)")
  return ((a or name:sub(1, 1)) .. (b or "")):upper()
end

-- What a member is like, in a few words: their nerve and their appetite for
-- risk (crew_faces' courage and thrill — the faces they pull come from the
-- same numbers), then their record. → "Steady · daring · 3 flights"
function traitsOf(r, look)
  local out = {}
  if look then
    local c, t = tonumber(look.courage), tonumber(look.thrill)
    if c then out[#out + 1] = c >= 0.66 and "Fearless" or (c <= 0.33 and "Nervy" or "Steady") end
    if t then out[#out + 1] = t >= 0.66 and "daring" or (t <= 0.33 and "careful" or nil) end
  end
  local f = tonumber(r and r.flights) or 0
  out[#out + 1] = f == 0 and "rookie" or string.format("%d flight%s", f, f == 1 and "" or "s")
  return table.concat(out, " · ")
end

local function rule(k) return { "box", key = k, style = "panel/rule", w = "100%", h = 1 } end
local function label(k, t) return { "text", key = k, style = "panel/label", w = "grow", h = 18, text = t, textValign = "center",
  maxLines = 1, overflow = "ellipsis" } end
local function hint(k, t, warn) return { "text", key = k, style = warn and "panel/hintWarn" or "panel/hint", w = "100%", h = "fit",
  wrap = true, text = t } end

-- A load in kg: whole as "6", a fraction to a decimal (a medkit is 1.5 kg, not "2").
local function kgs(x) local f = x % 1; return string.format((f < 0.05 or f > 0.95) and "%.0f" or "%.1f", x) end

local function mass_line(inv, cid)
  local kg = call(inv, "mass", cid) or 0
  local cap = call(inv, "cap", cid) or 0
  local L = call(inv, "volume", cid) or 0
  local vc = call(inv, "volCap", cid) or 60
  return string.format("%s/%.0f kg  %.0f/%.0f L", kgs(kg), cap, L, vc)
end

local function money(v)
  local co = ref("company")
  return (co and co.money) and co.money(v) or string.format("$%d", math.floor((v or 0) + 0.5))
end

-- ── PORTRAITS ───────────────────────────────────────────────────────────────
-- Each member photographed ONCE in a little booth of the builder's own: one
-- CrewDoll (helmet off, wearing the member's look from crew_faces) on the
-- "viewmodel" render layer 2.4 km up the build frame and 60 m off the parts
-- preview's stand, a camera, a key and a fill light and a slate backdrop, all
-- children of the doll — so every pose is in the doll's own frame and nothing
-- keeps a world point (docs/positions-and-frames.md). camera.captureTexture
-- takes a 128² picture; build_host keeps it for the session with the look it
-- was taken of, so the next VAB entry starts with every face. A new hire, or
-- a look that changed, is photographed again. While a picture is missing the
-- card shows the member's initials on a dark well.
PORTRAITS = {}            -- member id → "img:N"
portraitsTaken = 0        -- published for probes
local PB = { x = 60.0, alt = 2400.0, bit = 3, layer = "viewmodel", px = 128, fov = 0.36, dist = 0.62,
             settle = 1.1, first = 1.8 }
local pb = { doll = nil, dmaking = false, cam = nil, cmaking = false, lights = {}, lmaking = 0, back = nil,
             bmaking = false, id = nil, key = nil, t = 0, busy = false, failed = {}, keys = {}, face = nil,
             fs = nil, on = false, aimed = 0, tries = 0, started = nil }
local function pvalid(n) return n ~= nil and n.valid ~= false end
local function portrait_store()
  local bh = ref("build_host")
  return (bh and bh.crewPortrait and bh.keepCrewPortrait) and bh or nil
end
local function look_of(id)
  local F = ref("crew_faces")
  local l = F and call(F, "lookOf", id)
  if type(l) ~= "table" then return nil, nil end
  return tostring(l.key or "") .. ":" .. tostring(l.head) .. ":" .. tostring(l.hairStyle), l
end
function portraitOf(id) return PORTRAITS[id] end

local function pb_layer(n, depth)
  depth = depth or 0
  pcall(function() n.layer = PB.layer end)
  if depth < 6 and n.children then
    local ok, kids = pcall(function() return n:children() end)
    if ok and type(kids) == "table" then for _, c in ipairs(kids) do pb_layer(c, depth + 1) end end
  end
end
local function pb_parent()
  local B = ref("builder")
  return B and B.frameNodeOrNil and B.frameNodeOrNil() or nil
end
local function pb_show(on)
  pb.on = on
  local function sw(n) if pvalid(n) and n.enabled ~= on then n.enabled = on end end
  sw(pb.doll)
end

-- The next member whose picture is missing or of an old look.
local function booth_want()
  if not ref("crew_faces") then return nil end
  local S = portrait_store()
  for _, r in ipairs(roster_now()) do
    if r.status ~= "dead" and not pb.failed[r.id] then
      local k, l = look_of(r.id)
      if k and (PORTRAITS[r.id] == nil or pb.keys[r.id] ~= k) then
        local tex, sk = nil, nil
        if S then tex, sk = S.crewPortrait(r.id) end
        if tex and sk == k then
          PORTRAITS[r.id], pb.keys[r.id] = tex, k
          bump()
        else
          return r.id, k, l
        end
      end
    end
  end
  return nil
end

-- Make the booth (a node a call; their callbacks finish it).
local function booth_make()
  if not (spawn and createNode) then return false end
  if not pvalid(pb.doll) then
    if pb.dmaking then return false end
    pb.dmaking = true
    local ok = pcall(spawn, "CrewDoll", nil, function(n)
      pb.dmaking = false
      if not pvalid(n) then return end
      local par = pb_parent()
      if par and n.setParent then n:setParent(par, { keepWorld = false }) end
      n.x, n.y, n.z = PB.x, PB.alt, 0
      pb.doll, pb.face, pb.fs, pb.cam, pb.back, pb.lights = n, nil, nil, nil, nil, {}
      n.enabled = pb.on
    end)
    if not ok then pb.dmaking = false end
    return false
  end
  local d = pb.doll
  if not pvalid(pb.face) then
    for _, m in ipairs(d:children() or {}) do
      if m.name == "AstroModel" then
        for _, c in ipairs(m:children() or {}) do
          if c.name == "Face" then pb.face = c end
          if c.name == "Helmet" or c.name == "Visor" then c.visible = false end
        end
      end
    end
    if not pb.face then return false end
    pb_layer(d)
  end
  if not pb.fs then
    pb.fs = pb.face.getScript and pb.face:getScript("face") or nil
    if not (pb.fs and pb.fs.setLook) then pb.fs = nil; return false end
    pb.fs.still, pb.fs.forceHelmet = true, false
  end
  if not pvalid(pb.cam) then
    if not pb.cmaking then
      pb.cmaking = true
      createNode("CrewPortraitCam", d, function(n)
        pb.cmaking = false
        pb.cam = n
        pcall(function()
          n:setCamera { fovY = PB.fov, active = false, cullMask = 2 ^ PB.bit }
          n:setCamera { shadows = false, terrain = false, fog = false }
        end)
      end)
    end
    return false
  end
  local LIGHTS = { { "CrewPortraitKey", { 1.00, 0.94, 0.84 }, 2.6, 3.0 }, { "CrewPortraitFill", { 0.82, 0.88, 1.00 }, 1.1, 3.0 } }
  for i, L in ipairs(LIGHTS) do
    if not pvalid(pb.lights[i]) then
      if pb.lmaking == 0 then
        pb.lmaking = pb.lmaking + 1
        createNode(L[1], d, function(n)
          pb.lmaking = pb.lmaking - 1
          pb.lights[i] = n
          pcall(function() n:setPointLight { color = L[2], intensity = L[3], range = L[4] } end)
        end)
      end
      return false
    end
  end
  if not pvalid(pb.back) then
    if not pb.bmaking then
      pb.bmaking = true
      createNode("CrewPortraitBack", d, function(n)
        pb.bmaking = false
        pb.back = n
        pcall(function()
          n:setPrimitive("Cube", { 0.25, 0.25, 0.24 })
          n:setMaterial { color = { 0.25, 0.25, 0.24 }, unlit = true }
        end)
        pcall(function() n.layer = PB.layer end)
      end)
    end
    return false
  end
  return true
end

-- Each frame (update): who is in the booth, and the picture once they have
-- settled and the camera has been aimed (lateUpdate) on two frames.
function booth_tick()
  if pb.busy then return end
  local id, k, l = booth_want()
  if not id then
    if pb.on then pb_show(false) end
    pb.id = nil
    return
  end
  pb.started = pb.started or (time or 0)
  if not pb.on then pb_show(true) end
  if not booth_make() then
    -- a booth that never stands (no CrewDoll prefab, no face script): give up quietly
    if (time or 0) - pb.started > 20 then for _, r in ipairs(roster_now()) do pb.failed[r.id] = true end end
    return
  end
  if pb.id ~= id or pb.key ~= k then
    pb.id, pb.key, pb.t, pb.aimed, pb.tries = id, k, time or 0, 0, 0
    pcall(pb.fs.setLook, l)
    return
  end
  local wait = (portraitsTaken == 0) and PB.first or PB.settle
  if (time or 0) - pb.t < wait or pb.aimed < 2 then
    if (time or 0) - pb.t > 12 then pb.failed[id] = true; pb.id = nil end
    return
  end
  if not (camera and camera.captureTexture) then pb.failed[id] = true; return end
  pb.busy = true
  local ok = pcall(camera.captureTexture, pb.cam, { w = PB.px, h = PB.px }, function(tex)
    pb.busy = false
    if tex then
      PORTRAITS[id], pb.keys[id] = tex, k
      portraitsTaken = portraitsTaken + 1
      local S = portrait_store()
      if S then S.keepCrewPortrait(id, k, tex) end
      bump()
    else
      pb.tries = pb.tries + 1
      if pb.tries > 2 then pb.failed[id] = true end
    end
    pb.id = nil
  end)
  if not ok then pb.busy = false; pb.failed[id] = true end
end

-- Aim the booth at the face as it is drawn THIS frame: the eyes and the face
-- root read from the face's bones, taken into the doll's frame, and the
-- camera and lights placed in that frame (they are the doll's children).
function booth_aim()
  if not (pb.on and pvalid(pb.doll) and pvalid(pb.cam) and pvalid(pb.face) and vec3) then return end
  local ok = pcall(function()
    local a = pb.face:animator()
    local r, el, er = a and a:boneWorld("FaceRoot"), a and a:boneWorld("EyeL"), a and a:boneWorld("EyeR")
    if not (r and el and er) then return end
    local mid = vec3((el.x + er.x) * 0.5, (el.y + er.y) * 0.5, (el.z + er.z) * 0.5)
    local m = pb.doll:toLocal(mid)
    local o = pb.doll:toLocal(vec3(r.x, r.y, r.z))
    local fx, fz = m.x - o.x, m.z - o.z
    local fl = math.sqrt(fx * fx + fz * fz)
    if fl < 1e-4 then return end
    fx, fz = fx / fl, fz / fl
    local rx, rz = -fz, fx                 -- the sitter's side, level
    local cy = m.y - 0.035                 -- a little under the eyes: the face, not the brow
    local D = PB.dist
    pb.cam.x, pb.cam.y, pb.cam.z = m.x + fx * D + rx * 0.08, cy + 0.03, m.z + fz * D + rz * 0.08
    pb.cam:lookAt(pb.doll:toWorld(vec3(m.x, cy, m.z)))
    local k, f = pb.lights[1], pb.lights[2]
    if pvalid(k) then k.x, k.y, k.z = m.x + fx * 0.75 + rx * 0.55, m.y + 0.45, m.z + fz * 0.75 + rz * 0.55 end
    if pvalid(f) then f.x, f.y, f.z = m.x + fx * 0.70 - rx * 0.70, m.y - 0.05, m.z + fz * 0.70 - rz * 0.70 end
    if pvalid(pb.back) then
      pb.back.x, pb.back.y, pb.back.z = m.x - fx * 1.25, m.y, m.z - fz * 1.25
      pb.back.scale_x, pb.back.scale_y, pb.back.scale_z = 1.5, 1.5, 1.5
    end
    pb.aimed = pb.aimed + 1
  end)
  if not ok then pb.aimed = 0 end
end
function portraitBooth() return pb end   -- probes

-- The face on a card: the picture, or the member's initials on a dark well.
local function face_el(k, id, name, size, opacity)
  local tex = id and PORTRAITS[id]
  if tex then return { "image", key = k, texture = tex, w = size, h = size, opacity = opacity } end
  return { "box", key = k, style = "menu/slot", w = size, h = size, opacity = opacity,
    text = id and initials(name) or "+", textAlign = "center", textValign = "center" }
end

-- ── the drag ────────────────────────────────────────────────────────────────
-- The card in your hand (builder_inspector draws it at the pointer): what it
-- shows. nil when nothing of ours is being dragged.
function dragGhost()
  local d = st.drag
  if not d then return nil end
  if d.kind == "member" then
    local r
    for _, x in ipairs(roster_now()) do if x.id == d.id then r = x end end
    return { kind = "member", id = d.id, name = r and shortName(r.name) or "?", tex = PORTRAITS[d.id],
             initials = r and initials(r.name) or "?", sub = d.from and "move seat" or "drop on a seat" }
  end
  if d.kind == "item" then
    local it = item_def(d.id) or {}
    return { kind = "item", name = it.name or d.id, sub = "drop in a box" }
  end
  return nil
end

-- Can the member in hand go to uid/slot? (the highlight on every seat)
local function drop_ok(plan, roster, active, uid, slot)
  local d = st.drag
  if not (d and d.kind == "member") then return false end
  if d.from and d.from.uid == uid and d.from.slot == slot then return false end
  return (canSeat(plan, CUR.cparts, roster, active, d.id, uid, slot, d.from)) == true
end

-- one item tile: drag it, or click it then click a box
local function tile(k, it, from)
  local picked = st.pickItem and st.pickItem.id == it.id and st.pickItem.from == from
  return { "button", key = k, style = "panel/choice", selected = picked, w = "fit", h = 20, pad = 5,
    text = string.format(" %s%s%s ", it.name, (it.n or 1) > 1 and (" ×" .. it.n) or "", it.buy and " $" or ""),
    textValign = "center", draggable = true,
    tooltip = it.buy and string.format("%d bought at launch (%s) — drag it out to take it off", it.buy, money(it.buyCost or 0))
      or "Drag to another box, or click it and then click the box",
    onDragStart = function() st.drag = { kind = "item", id = it.id, from = from }; bump() end,
    onDragCancel = function() st.drag = nil; bump() end,
    onClicked = function()
      if picked then st.pickItem = nil else st.pickItem = { id = it.id, from = from } end
      bump()
    end }
end

-- a box items can be dropped on (and clicked, to take the picked item)
local function itembox(k, to, head, tiles, empty)
  local box = { "col", key = k, name = "CrewBox_" .. tostring(to),
    style = (st.drag and st.drag.kind == "item") and "panel/rowActive" or "panel/row",
    w = "100%", h = "fit", gap = 3, pad = 4, align = "stretch", dropTarget = true,
    button = st.pickItem ~= nil or nil,
    onDropped = function()
      local d = st.drag
      st.drag = nil
      if d and d.kind == "item" then do_move(d.id, d.from, to) end
      bump()
    end,
    onClicked = function()
      local p = st.pickItem
      if p then st.pickItem = nil; do_move(p.id, p.from, to); bump() end
    end }
  box[#box + 1] = head
  local row = { "row", key = "t", w = "100%", h = "fit", gap = 3, pad = 0, wrap = true }
  for i, t in ipairs(tiles) do row[#row + 1] = t end
  if #tiles == 0 then
    row[#row + 1] = { "text", key = "e", style = "panel/cellMuted", w = "grow", h = 18, text = empty, textValign = "center" }
  end
  box[#box + 1] = row
  return box
end

local function seat_rows(out, plan, roster, active)
  local cmd_id, cmd_uid, cmd_slot = commanderOf(CUR.cparts, plan)
  local byId = {}
  for _, r in ipairs(roster) do byId[r.id] = r end
  local dragging = st.drag ~= nil and st.drag.kind == "member"
  for i, c in ipairs(CUR.cparts) do
    out[#out + 1] = { "text", key = "pl" .. c.uid, style = "panel/cellStrong", w = "100%", h = 16, textValign = "center",
      maxLines = 1, overflow = "ellipsis",
      text = c.label .. (c.command and (c.open and "  · open seat" or "") or "  · passengers") }
    local row = { "row", key = "ps" .. c.uid, w = "100%", h = "fit", gap = 3, pad = 0, wrap = true }
    for s = 1, c.slots do
      local m = seatAt(plan, c.uid, s)
      local r = m and byId[m]
      local star = (m and m == cmd_id and c.uid == cmd_uid and s == cmd_slot) and "★" or ""
      local picked = st.pick and st.pick.uid == c.uid and st.pick.slot == s
      local skey = string.format("%d_%d", c.uid, s)
      local can = dragging and drop_ok(plan, roster, active, c.uid, s)
      local over = can and st.over == skey
      local text = r and (shortName(r.name) .. star) or (picked and "▸ pick a card" or (can and "drop here" or "empty seat"))
      local style = r and ((st.sel == m) and "panel/rowActive" or "panel/row") or (can and "panel/row" or "menu/slot")
      if over then style = "panel/rowActive" end
      row[#row + 1] = { "button", key = "s" .. s, name = "CrewSeat" .. skey, style = style,
        selected = (can and not over) or picked or nil,
        w = c.slots == 1 and "100%" or 116, h = 40, dir = "row", gap = 5, pad = 3, align = "center",
        dropTarget = true, draggable = m ~= nil,
        tooltip = r and (r.name .. (star ~= "" and " · commander" or "") .. " — click for their pack, drag to move")
          or "Empty seat — drag a crew card here, or click it and then a card",
        onDragStart = function() if m then st.drag = { kind = "member", id = m, from = { uid = c.uid, slot = s } }; bump() end end,
        onDragCancel = function() st.drag = nil; st.over = nil; bump() end,
        onDragEnter = function() if st.over ~= skey then st.over = skey; bump() end end,
        onDragLeave = function() if st.over == skey then st.over = nil; bump() end end,
        onDropped = function()
          local d = st.drag
          if d and d.kind == "member" and not (d.from and d.from.uid == c.uid and d.from.slot == s) then
            st.drag, st.over = nil, nil
            if seatMember(d.id, c.uid, s, d.from) then
              local sfx = ref("sfx")
              if sfx and sfx.play then pcall(sfx.play, "click") end
            end
          end
          bump()
        end,
        onClicked = function()
          if m then st.sel = m; st.pick = nil
          elseif picked then st.pick = nil
          else st.pick = { uid = c.uid, slot = s } end
          bump()
        end,
        face_el("f", m, r and r.name, 32, r and 1.0 or 0.6),
        { "col", key = "t", w = "grow", h = "fit", gap = 0, pad = 0,
          { "text", key = "n", style = r and "panel/cellStrong" or "panel/cellMuted", w = "100%", h = 16, text = text,
            textValign = "center", maxLines = 1, overflow = "ellipsis" },
          r and { "text", key = "x", style = "panel/cellMuted", w = "100%", h = 14, textValign = "center",
            maxLines = 1, overflow = "ellipsis", text = star ~= "" and "commander" or (c.command and "crew" or "passenger") } or nil } }
    end
    out[#out + 1] = row
  end
end

local function roster_rows(out, plan, roster, active)
  local cards = { "col", key = "rcards", w = "100%", h = "fit", gap = 3, pad = 0, align = "stretch" }
  local back = st.drag and st.drag.kind == "member" and st.drag.from
  local box = { "col", key = "rbox", name = "CrewRosterBox", style = back and "panel/rowActive" or nil,
    w = "100%", h = "fit", gap = 3, pad = back and 3 or 0, align = "stretch", dropTarget = true,
    tooltip = "Drop a seated card here to take them off the craft",
    onDropped = function()
      local d = st.drag
      st.drag = nil
      if d and d.kind == "member" and d.from then unseatMember(d.id) end
      bump()
    end }
  local living = 0
  for _, r in ipairs(roster) do
    if r.status ~= "dead" then
      living = living + 1
      local ok, why = available(r, active)
      local su = whereSeated(plan, r.id)
      local _, look = look_of(r.id)
      local tag = su and " ✓" or ""
      local op = ok and 1.0 or 0.45
      local where = (not ok and why) or (su and "aboard this craft" or (r.id == active and "you" or "at base"))
      local inhand = st.drag and st.drag.kind == "member" and st.drag.id == r.id and not st.drag.from
      cards[#cards + 1] = { "button", key = "m" .. r.id, name = "CrewCard" .. r.id,
        style = su and "panel/rowActive" or "panel/row", selected = inhand or nil,
        w = "100%", h = 50, dir = "row", gap = 6, pad = 4, align = "center",
        opacity = op, draggable = (ok and not su) or nil,
        tooltip = string.format("%s — %s · %d flight%s%s", r.name, where, r.flights or 0, (r.flights or 0) == 1 and "" or "s",
          (ok and not su) and " · drag onto a seat, or click to seat them" or ""),
        onDragStart = function() if ok and not su then st.drag = { kind = "member", id = r.id }; bump() end end,
        onDragCancel = function() st.drag = nil; st.over = nil; bump() end,
        onClicked = function()
          if not ok then say(r.name .. " is " .. why) return end
          if su then st.sel = r.id; bump() return end
          seatFirstFree(r.id)
        end,
        face_el("f", r.id, r.name, 42, op),
        { "col", key = "t", w = "grow", h = "fit", gap = 1, pad = 0,
          { "text", key = "n", style = "panel/cellStrong", w = "100%", h = 16, textValign = "center", opacity = op,
            maxLines = 1, overflow = "ellipsis", text = shortName(r.name) .. tag },
          { "text", key = "x", style = "panel/cellMuted", w = "100%", h = 14, textValign = "center",
            maxLines = 1, overflow = "ellipsis", text = traitsOf(r, look) },
          { "text", key = "w", style = "panel/cellMuted", w = "100%", h = 14, textValign = "center",
            maxLines = 1, overflow = "ellipsis", text = where } } }
    end
  end
  box[#box + 1] = cards
  out[#out + 1] = { "row", key = "rhd", w = "100%", h = 18, gap = 4, pad = 0, align = "center",
    label("l", "CREW"),
    { "text", key = "n", style = "panel/cellMuted", w = "fit", h = 18, textValign = "center",
      text = string.format("%d living", living) },
    { "button", key = "hire", style = "panel/secondary", w = 52, h = 18,
      text = st.hiring and "− HIRE" or "+ HIRE", textAlign = "center", textValign = "center", selected = st.hiring,
      tooltip = "The applicants on the board: a one-time fee, no wages",
      onClicked = function() st.hiring = not st.hiring; bump() end } }
  if back then out[#out + 1] = hint("rback", "Drop here to take them off the craft.") end
  out[#out + 1] = box
  if st.hiring then
    local c = ref("crew")
    local offers = call(c, "offers") or {}
    for i, a in ipairs(offers) do
      out[#out + 1] = { "row", key = "ap" .. i, w = "100%", h = 22, gap = 4, pad = 0, align = "center",
        { "text", key = "n", style = "panel/cell", w = "grow", h = 22, text = a.name, textValign = "center",
          maxLines = 1, overflow = "ellipsis" },
        { "text", key = "c", style = "panel/cellMuted", w = "fit", h = 22, textValign = "center",
          text = (a.free or (a.cost or 0) <= 0) and "FREE" or money(a.cost) },
        { "button", key = "h", style = "panel/choice", w = 44, h = 20, text = "HIRE", textAlign = "center", textValign = "center",
          onClicked = function()
            local id, why = call(c, "hire", i)
            if id then say((a.name or "they") .. " joins the agency"); st.hiring = false
            else say("can't hire — " .. tostring(why or "no answer")) end
          end } }
    end
    if #offers == 0 then out[#out + 1] = hint("apn", "Nobody on the board right now.") end
  end
end

-- The shop's list (inventory.shopList answers registry rows; an id list is
-- taken too) → { {id, name, cost} … }
local function shop_rows()
  local out = {}
  for _, e in ipairs(call(ref("inventory"), "shopList") or {}) do
    local id = type(e) == "table" and e.id or e
    local d = item_def(id) or (type(e) == "table" and e) or {}
    if id then out[#out + 1] = { id = id, name = d.name or id, cost = d.cost or 0 } end
  end
  return out
end

-- BUY ▸ on a storage box: the shop, one key a line; +1 plans it in
-- (stock first, bought at launch otherwise).
local function shop_lines(out, k, uid)
  for _, e in ipairs(shop_rows()) do
    out[#out + 1] = { "row", key = k .. e.id, w = "100%", h = 20, gap = 4, pad = 0, align = "center",
      { "text", key = "n", style = "panel/cell", w = "grow", h = 20, text = e.name, textValign = "center",
        maxLines = 1, overflow = "ellipsis" },
      { "text", key = "c", style = "panel/cellMuted", w = "fit", h = 20, text = money(e.cost), textValign = "center" },
      { "button", key = "b", name = "CrewBuy_" .. tostring(uid) .. "_" .. e.id, style = "panel/choice", w = 36, h = 18,
        text = "+1", textAlign = "center", textValign = "center",
        tooltip = uid == "stock" and "Buy one into the base stock now"
          or "Put one in — from the stock if there is one, otherwise bought at launch",
        onClicked = function()
          if uid == "stock" then
            local ok, why = call(ref("inventory"), "buyItem", "base", e.id, 1)
            if ok then say("bought a " .. e.name) else say("can't buy — " .. tostring(why or "no answer")) end
          else
            local ok, why = addToStorage(uid, e.id)
            if not ok then say("can't put it in — " .. tostring(why)) end
          end
          bump()
        end } }
  end
end

local function loadout_rows(out, plan, roster)
  local inv = ref("inventory")
  local byId = {}
  for _, r in ipairs(roster) do byId[r.id] = r end
  if st.sel and not whereSeated(plan, st.sel) then st.sel = nil end
  if not st.sel then st.sel = commanderOf(CUR.cparts, plan) or seatedIds(plan)[1] end
  local who = st.sel and byId[st.sel]
  local lp = lockerPlanMap()
  -- the pack
  if who then
    local cid = "crew:" .. tostring(who.id)
    local tiles = {}
    for i, it in ipairs(call(inv, "itemList", cid) or {}) do tiles[#tiles + 1] = tile("pk" .. it.id, it, "pack") end
    out[#out + 1] = itembox("pack", "pack",
      { "row", key = "h", w = "100%", h = 18, gap = 4, pad = 0, align = "center",
        { "text", key = "l", style = "panel/label", w = "grow", h = 18, textValign = "center", maxLines = 1, overflow = "ellipsis",
          text = "LOADOUT ▾ " .. shortName(who.name) },
        { "button", key = "off", style = "panel/secondary", w = 40, h = 16, text = "OFF", textAlign = "center", textValign = "center",
          tooltip = "Take " .. who.name .. " off the craft", onClicked = function() unseatMember(who.id) end } },
      tiles, "an empty pack")
    out[#out + 1] = { "text", key = "pkm", style = "panel/cellMuted", w = "100%", h = 14, text = mass_line(inv, cid) }
  else
    out[#out + 1] = label("ldh", "LOADOUT")
    out[#out + 1] = hint("ldn", "Seat someone, then click their card to pack for them.")
  end
  -- the craft's storage: lockers and cargo bays
  local kit = kitForLaunch(lp)
  for _, l in ipairs(CUR.lockers) do
    local items = lp[l.uid] or {}
    local per = kit.per[l.uid] or { cost = 0, buy = {} }
    local tiles = {}
    local ids = {}
    for id in pairs(items) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local d = item_def(id) or {}
      local nb = per.buy[id]
      tiles[#tiles + 1] = tile("lk" .. id, { id = id, name = d.name or id, n = items[id], buy = nb,
        buyCost = nb and nb * (d.cost or 0) or nil }, l.uid)
    end
    local kg, L = lockerLoad(items)
    local shopping = st.buying == l.uid
    out[#out + 1] = itembox("lk" .. l.uid, l.uid,
      { "row", key = "h", w = "100%", h = 18, gap = 4, pad = 0, align = "center",
        { "text", key = "l", style = "panel/label", w = "grow", h = 18, textValign = "center", maxLines = 1, overflow = "ellipsis",
          text = string.format("%s  %s/%.0f kg  %.0f/%.0f L", storageTitle(l), kgs(kg), l.cap, L, l.vol) },
        { "button", key = "buy", name = "CrewShop_" .. tostring(l.uid), style = "panel/secondary", w = 52, h = 16,
          text = shopping and "BUY ▾" or "BUY ▸", textAlign = "center", textValign = "center", selected = shopping or nil,
          tooltip = "Buy kit for this " .. (l.kind == "hold" and "cargo bay" or "locker") .. ": it flies with the craft",
          onClicked = function() st.buying = (st.buying ~= l.uid) and l.uid or false; bump() end } },
      tiles, "empty — BUY ▸ or drag kit in")
    if per.cost > 0 then
      out[#out + 1] = { "text", key = "lkc" .. l.uid, style = "panel/cellMuted", w = "100%", h = 14,
        text = string.format("$ marks kit bought at launch: %s", money(per.cost)) }
    end
    if shopping then shop_lines(out, "by" .. l.uid .. "_", l.uid) end
  end
  if #CUR.lockers == 0 then
    out[#out + 1] = hint("lkn", "No storage on this craft. A Stowage Locker or a Cargo Bay carries kit (medkits, beacons, repair kits) that flies with it.")
  end
  -- the stock
  local tiles = {}
  for _, it in ipairs(call(inv, "itemList", "base") or {}) do
    local free = base_free(it.id, lp)
    if free > 0 then tiles[#tiles + 1] = tile("st" .. it.id, { id = it.id, name = it.name, n = free }, "stock") end
  end
  local shopping = st.buying == "stock"
  out[#out + 1] = itembox("stock", "stock",
    { "row", key = "h", w = "100%", h = 18, gap = 4, pad = 0, align = "center",
      label("l", "STOCK (base)"),
      { "button", key = "buy", style = "panel/secondary", w = 52, h = 16, text = shopping and "BUY ▾" or "BUY ▸",
        textAlign = "center", textValign = "center", selected = shopping or nil,
        tooltip = "Buy items into the base stock",
        onClicked = function() st.buying = (st.buying ~= "stock") and "stock" or false; bump() end } },
    tiles, "nothing in the warehouse")
  if shopping then shop_lines(out, "by", "stock") end
  if kit.cost > 0 then
    out[#out + 1] = { "text", key = "kitc", style = "panel/hint", w = "100%", h = "fit", wrap = true,
      text = string.format("At launch: %s of kit is bought for the craft's storage (added to the launch cost).", money(kit.cost)) }
  end
end

function describe(B, out)
  sync(false)
  local roster, active = roster_now(), active_now()
  local plan = seatPlan()
  out[#out + 1] = { "row", key = "shd", w = "100%", h = 22, gap = 4, pad = 0, align = "center",
    label("l", "SEATS"),
    { "button", key = "auto", style = "panel/secondary", w = 52, h = 20, text = "AUTO", textAlign = "center", textValign = "center",
      disabled = #CUR.cparts == 0, tooltip = "Fill every seat from the crew at base, you in command",
      onClicked = function() auto() end } }
  if #CUR.cparts == 0 then
    out[#out + 1] = hint("snone", "No seats on this craft. A Pod, a Command Seat or a Crew Cabin carries crew; a Probe Core flies it with nobody aboard.")
  else
    seat_rows(out, plan, roster, active)
    if st.drag and st.drag.kind == "member" then
      out[#out + 1] = hint("sdrag", "Drop the card on a lit seat.")
    end
  end
  local why = launchBlock(nil, plan)
  if why then out[#out + 1] = hint("blk", "⚠ " .. why, true) end
  for i, w in ipairs(launchWarn(nil, plan)) do out[#out + 1] = hint("wn" .. i, w, true) end
  out[#out + 1] = rule("r1")
  roster_rows(out, plan, roster, active)
  out[#out + 1] = rule("r2")
  loadout_rows(out, plan, roster)
  if st.msg and (time or 0) - st.msgT < 4.0 then out[#out + 1] = hint("msg", st.msg) end
  return out
end

-- Tests and probes.
function state() return st end
function touch() bump() end
function current() return CUR end
function reset()
  st = { sel = nil, pick = nil, pickItem = nil, drag = nil, hiring = false, buying = false,
         msg = nil, msgT = -1e9, seenCrewed = false, session = false }
  CUR = { parts = nil, cparts = {}, lockers = {}, cv = nil }
  refs = {}
end
