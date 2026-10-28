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

function lockerLoad(items, defOf)
  defOf = defOf or item_def
  local kg, L = 0, 0
  for id, n in pairs(items or {}) do
    local d = defOf(id) or {}
    kg = kg + (d.kg or 1) * n
    L = L + (d.L or 1) * n
  end
  return kg, L
end

-- Room for one more `id` in a locker plan? → ok, why
function lockerRoom(items, id, cap, volCap, defOf)
  defOf = defOf or item_def
  local d = defOf(id) or {}
  local kg, L = lockerLoad(items, defOf)
  if kg + (d.kg or 1) > cap + 1e-6 then return false, string.format("no room: %.0f kg free", math.max(0, cap - kg)) end
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

local st = { sel = nil, pick = nil, pickItem = nil, drag = nil, hiring = false, buying = false,
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
    if def and (slotsOf(def) > 0 or lockerCap(def) > 0) then
      local r = B.partRec(uid)
      y = r and r.y or 0
    end
    parts[#parts + 1] = { uid = uid, id = id, def = def or {}, y = y }
  end
  CUR.parts = parts
  CUR.cparts = crewedParts(parts)
  CUR.lockers = lockerParts(parts)
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
    local ok, w = lockerRoom(lp[to], item, l.cap, (ref("items") and ref("items").VOL or {}).locker or 120)
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
    local ok, w = lockerRoom(lp[to], item, l.cap, (ref("items") and ref("items").VOL or {}).locker or 120)
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
      local ok, w = lockerRoom(lp[to], item, l.cap, (ref("items") and ref("items").VOL or {}).locker or 120)
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

local function do_move(item, from, to)
  local ok, why = moveOne(item, from, to)
  if not ok and why then say("can't move it — " .. why) end
  local sfx = ref("sfx")
  if ok and sfx and sfx.play then pcall(sfx.play, "click") end
  return ok
end

-- ── the tab ─────────────────────────────────────────────────────────────────
function shortName(name)
  if type(name) ~= "string" then return "?" end
  local first, rest = name:match("^(%S+)%s+(.+)$")
  if not first then return name:upper() end
  return (first:sub(1, 1) .. "." .. rest):upper()
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

-- one item tile: drag it, or click it then click a box
local function tile(k, it, from)
  local picked = st.pickItem and st.pickItem.id == it.id and st.pickItem.from == from
  return { "button", key = k, style = "panel/choice", selected = picked, w = "fit", h = 20, pad = 5,
    text = string.format(" %s%s ", it.name, (it.n or 1) > 1 and (" ×" .. it.n) or ""), textValign = "center",
    draggable = true, tooltip = "Drag to another box, or click it and then click the box",
    onDragStart = function() st.drag = { kind = "item", id = it.id, from = from }; bump() end,
    onDragCancel = function() st.drag = nil; bump() end,
    onClicked = function()
      if picked then st.pickItem = nil else st.pickItem = { id = it.id, from = from } end
      bump()
    end }
end

-- a box items can be dropped on (and clicked, to take the picked item)
local function itembox(k, to, head, tiles, empty)
  local box = { "col", key = k, style = (st.drag and st.drag.kind == "item") and "panel/rowActive" or "panel/row",
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
      local text = r and (shortName(r.name) .. star) or (picked and "▸ pick" or "—")
      row[#row + 1] = { "button", key = "s" .. s, style = (m and st.sel == m) and "panel/rowActive" or "panel/choice",
        selected = picked or (st.drag ~= nil and st.drag.kind == "member"),
        w = c.slots > 2 and 74 or 112, h = 24, text = text, textAlign = "center", textValign = "center",
        maxLines = 1, overflow = "ellipsis",
        dropTarget = true, draggable = m ~= nil,
        tooltip = r and (r.name .. (star ~= "" and " · commander" or "") .. " — click for their pack, drag to move")
          or "Empty seat — drag a roster card here, or click it and then a card",
        onDragStart = function() if m then st.drag = { kind = "member", id = m, from = { uid = c.uid, slot = s } }; bump() end end,
        onDragCancel = function() st.drag = nil; bump() end,
        onDropped = function()
          local d = st.drag
          if d and d.kind == "member" and not (d.from and d.from.uid == c.uid and d.from.slot == s) then
            st.drag = nil
            seatMember(d.id, c.uid, s, d.from)
          end
          bump()
        end,
        onClicked = function()
          if m then st.sel = m; st.pick = nil
          elseif picked then st.pick = nil
          else st.pick = { uid = c.uid, slot = s } end
          bump()
        end }
    end
    out[#out + 1] = row
  end
end

local function roster_rows(out, plan, roster, active)
  local cards = { "row", key = "rcards", w = "100%", h = "fit", gap = 3, pad = 0, wrap = true }
  local box = { "col", key = "rbox", style = (st.drag and st.drag.kind == "member" and st.drag.from) and "panel/rowActive" or nil,
    w = "100%", h = "fit", gap = 3, pad = 0, align = "stretch", dropTarget = true,
    tooltip = "Drop a seated card here to take them off the craft",
    onDropped = function()
      local d = st.drag
      st.drag = nil
      if d and d.kind == "member" and d.from then unseatMember(d.id) end
      bump()
    end }
  local living = 0
  for _, r in ipairs(roster) do
    local ok, why = available(r, active)
    local su = whereSeated(plan, r.id)
    if r.status ~= "dead" then living = living + 1 end
    local tag = su and " ✓" or ""
    cards[#cards + 1] = { "button", key = "m" .. r.id, style = "panel/choice", selected = su ~= nil,
      w = "fit", h = 22, pad = 5, text = " " .. shortName(r.name) .. tag .. " ", textValign = "center",
      opacity = ok and 1.0 or 0.45, draggable = ok and not su,
      tooltip = string.format("%s — %s%s · %d flight%s", r.name, ok and (su and "planned aboard" or "at base") or why,
        "", r.flights or 0, (r.flights or 0) == 1 and "" or "s"),
      onDragStart = function() if ok and not su then st.drag = { kind = "member", id = r.id }; bump() end end,
      onDragCancel = function() st.drag = nil; bump() end,
      onClicked = function()
        if not ok then say(r.name .. " is " .. why) return end
        if su then st.sel = r.id; bump() return end
        seatFirstFree(r.id)
      end }
  end
  cards[#cards + 1] = { "button", key = "hire", style = "panel/secondary", w = "fit", h = 22, pad = 5,
    text = st.hiring and "− HIRE" or "+ HIRE", textValign = "center", selected = st.hiring,
    tooltip = "The applicants on the board: a one-time fee, no wages",
    onClicked = function() st.hiring = not st.hiring; bump() end }
  box[#box + 1] = cards
  out[#out + 1] = { "row", key = "rhd", w = "100%", h = 18, gap = 4, pad = 0, align = "center",
    label("l", "ROSTER"),
    { "text", key = "n", style = "panel/cellMuted", w = "fit", h = 18, textValign = "center",
      text = string.format("%d living", living) } }
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
  -- the lockers
  local I = ref("items")
  local volL = (I and I.VOL and I.VOL.locker) or 120
  for _, l in ipairs(CUR.lockers) do
    local items = lp[l.uid] or {}
    local tiles = {}
    local ids = {}
    for id in pairs(items) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local d = item_def(id) or {}
      tiles[#tiles + 1] = tile("lk" .. id, { id = id, name = d.name or id, n = items[id] }, l.uid)
    end
    local kg, L = lockerLoad(items)
    out[#out + 1] = itembox("lk" .. l.uid, l.uid,
      { "text", key = "h", style = "panel/label", w = "100%", h = 18, textValign = "center", maxLines = 1, overflow = "ellipsis",
        text = string.format("LOCKER #%d  %s/%.0f kg  %.0f/%.0f L", l.n, kgs(kg), l.cap, L, volL) },
      tiles, "planned empty")
  end
  -- the stock
  local tiles = {}
  for _, it in ipairs(call(inv, "itemList", "base") or {}) do
    local free = base_free(it.id, lp)
    if free > 0 then tiles[#tiles + 1] = tile("st" .. it.id, { id = it.id, name = it.name, n = free }, "stock") end
  end
  out[#out + 1] = itembox("stock", "stock",
    { "row", key = "h", w = "100%", h = 18, gap = 4, pad = 0, align = "center",
      label("l", "STOCK (base)"),
      { "button", key = "buy", style = "panel/secondary", w = 52, h = 16, text = st.buying and "BUY ▾" or "BUY ▸",
        textAlign = "center", textValign = "center", selected = st.buying,
        tooltip = "Buy items into the base stock", onClicked = function() st.buying = not st.buying; bump() end } },
    tiles, "nothing in the warehouse")
  if st.buying then
    for _, id in ipairs(call(inv, "shopList") or {}) do
      local d = item_def(id) or {}
      out[#out + 1] = { "row", key = "by" .. id, w = "100%", h = 20, gap = 4, pad = 0, align = "center",
        { "text", key = "n", style = "panel/cell", w = "grow", h = 20, text = d.name or id, textValign = "center",
          maxLines = 1, overflow = "ellipsis" },
        { "text", key = "c", style = "panel/cellMuted", w = "fit", h = 20, text = money(d.cost or 0), textValign = "center" },
        { "button", key = "b", style = "panel/choice", w = 36, h = 18, text = "+1", textAlign = "center", textValign = "center",
          onClicked = function()
            local ok, why = call(inv, "buyItem", "base", id, 1)
            if ok then say("bought a " .. (d.name or id)) else say("can't buy — " .. tostring(why or "no answer")) end
          end } }
    end
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
function current() return CUR end
function reset()
  st = { sel = nil, pick = nil, pickItem = nil, drag = nil, hiring = false, buying = false,
         msg = nil, msgT = -1e9, seenCrewed = false, session = false }
  CUR = { parts = nil, cparts = {}, lockers = {}, cv = nil }
  refs = {}
end
