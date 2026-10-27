-- CREW — the agency's astronauts: who they are, where they are, what they
-- carry and what they are doing (docs/crew-and-items.md §2, §3, §4, §6.3).
--
-- One save key per member, `crew.m.<id>`, plus a few roster keys:
--
--   crew.roster    ids in hire order, the dead included (the memorial reads it)
--   crew.seq       the last id issued
--   crew.active    the id the `Astronaut` node is now (see "the avatar")
--   crew.offers    the applicants on the board
--   crew.version   the migration stamp (VERSION below)
--   crew.safety    "death" (permadeath) | "rescue" (rescued instead, for a
--                  fee) | "invincible" (no harm at all); the new-save panel's
--                  CREW SAFETY. A save without it reads the older boolean
--   crew.death     true: death is real; false: "rescue instead" (kept in step)
--
-- Each member's pack is an ordinary inventory container, `crew:<id>`;
-- inventory's `"astro"` alias resolves to the active member's (WS3).
--
-- This file is a manager on the CrewLib node (spawned by game_manager and
-- build_host when the scene has none) and, at the same time, a rulebook that
-- loads in luajit: everything it touches is `save`, `findScript`, `find` and
-- `time`, which a test stubs.
--
-- ── THE AVATAR (§4.1, as built) ─────────────────────────────────────────────
-- The `Astronaut` node is ALWAYS bound to one living member, `crew.active`:
-- their suit, pack and hand. On foot it is them; aboard a craft it is them,
-- hidden, riding the craft as today (vessel_controller `crewAboard` = "the
-- avatar rides this craft"). (The design's "unbound" avatar while flying is
-- folded into this: the member at the controls IS the active one, so the
-- inventory alias, the suit and the HUD never lose their owner.)
-- Everyone else is a CrewBody (on foot, in range: prefabs/CrewBody,
-- scripts/crew_body.lua), a CrewDoll (seated in a craft: prefabs/CrewDoll,
-- placed here every lateUpdate) or a record (at base, or out of range).
--
-- ── SEATS (§3.1, §3.2) ──────────────────────────────────────────────────────
-- Who sits where lives ON THE PART: `st.crew<k> = memberId` for slot k
-- (st.crew1, st.crew2, …). Plain numbers, so electronics.packRecord keeps
-- them through a fleet record, a staging split, a docking, a revert and a
-- reload with no extra code (a nested table would be dropped by encodeState).
-- Seat geometry is SEATS below (mirrors parts_registry/parts_aero `seats`;
-- smoke_crew_seats checks they agree).
--
-- THE INTERFACE (other workstreams code against this; keep it stable):
--   roster() → {rec…}            get(id) → rec|nil         activeId() → id|nil
--   living() → n                 packOf(id) → "crew:"..id  where(id) → status, detail
--   hire(i) → id|nil, why        offers() → {{name, cost, free}…}   hireFee() → $
--   rename(id, s) → ok, why
--   control(id) → ok, why        take control of member `id` (on foot: their
--                                CrewBody; aboard: their craft, at their seat)
--   takeCraft(v, id?) → ok, why  fly craft `v` as member `id` (default its commander)
--   eva(id, {stay, confirmed}) → ok, why, warn   (stay: out as a CrewBody, you keep the craft)
--   board(id, v, uid?, slot?) → ok, why
--   quickSwap() → ok, why        switchList() → {{kind="crew"|"vessel", id|v, name, dist, crew}…}
--   step(dir) → name|nil         `[`/`]` along switchList (vessel_switcher calls it)
--   aboard(v) → {{id, name, uid, slot, open, command, commander, hp, o2}…}  (portraits: WS2)
--   seatMap(v) → {{uid, slot, open, command, taken = id|nil, label}…}
--   craftOf(id) → v|nil          dollOf(id) → node|nil    bodyOf(id) → node|nil
--   setTask(id, task) → ok, why  task(id) → task|nil   cancelTask(id, why) → ok
--   held(id) → bool              (locked at a task: movement code stands down)
--   alerts(id) → {o2, air_s, breath, hp, heat, fall, pinned, blackout, cabin, cabin_tol}
--   lastDeath → {id, name, cause, text, t, x, y, z} | nil   (the death camera hold, WS2)
--   airSource(helmet, headUnder, breathable) → "suit"|"hold"|"ambient"
--   tanksOf(pack) / drawAir(o2, dt, tanks)   the suit air rule (built-in + O2 tanks)
--   evaCheck(id) → ok, why, warn (warn: allowed, but ask first — no RCS Pack in space)
--   memorial() → {…}             deathOn() → bool          setDeath(on)
--   safety() → "death"|"rescue"|"invincible"   setSafety(mode)   invincible() → bool
--   kill(id, cause, detail) → ok   (death on: dies; off: rescued; invincible:
--                                nothing, but a lost cabin sets them down beside it)
--   hurt(id, amount, cause, detail, {by, x,y,z}) → hp|nil, why   a wound from
--                                outside (the TL-5 Surveyor; later animals): hp
--                                down, the HIT alert, death or rescue at 0
--   lastHit[id] → {t, amount, cause, by, hp}   (alerts().hit while fresh)
--   blackoutGrace(src) → secs    blackoutEnd(src) → handled (planet_walker asks)
--   downRule(cause, over) → bool  bleedSecs(cause, over) → s   (pure: who goes DOWNED)
--   rec.downed = {left, secs, cause, detail, by}   bleeding out on the ground
--   downedList() → {{id, name, left, dist}…}   lastDown → {id, name, cause, secs, t}
--   treatWhyNot(target) → why|nil   treat(target) → ok, why   cancelTreat(why)
--   treating() → {by, target, kind = "revive"|"heal", secs, done, frac}|nil
--                                the Medkit's work (items.MEDKIT); lastTreat for probes
--   patch(id, fields)            merge fields into a record (false clears; bumps version)
--   onEvaInSpace() → bool, id    (rails warp is refused while true)
--   seatDef(rec|partId) → {seats, hatch, command, open}|nil   slotCount(rec)
--   memberAt(rec, k) / setMemberAt(rec, k, id)   the part-state slot accessors
--   launchPlan(parts, plan, avail, active) → { {uid, slot, id}… }, commanderId   (the VAB seat plan)
--   validatePlan(parts, plan) → ok, why   (WS2's CREW tab: no double booking, someone at the controls)
--   current() → {kind="crew", id} | {kind="vessel", v}   switchTo(entry) → ok, why
--   avatarCraft() → v|nil        the craft the avatar rides
--   dollPose(id) / dollAt(vid, uid)   where a doll goes (crew_body) / an open seat's doll (command_seat)
--   setDown(id, x,y,z)           a member on foot at a world point (a wreck they walked from)
--   launchAs(id, craft)          the launch's commander becomes the avatar (vessel_controller)
--   noteAboard / noteAfoot / noteHome(id)   status bookkeeping the controller calls
--   showInterior                 WS2 sets true to draw the dolls in closed pods (crew cams, IVA)
--   version                      bumps on any change (panels poll it)
--
-- vessel_controller's side (globals): seatsOf(), crewIds(), crewCount(),
-- commander(), seatMember(uid, slot, id), memberSlot(id), freeSeat(prefer),
-- unseatMember(id), hatchWorld(uid), hatchSpot(uid), avatarBoard(id),
-- setStationOf(id), boardPrompt(st). docs/crew-and-items.md §10 "WS1 as built".

defaults = {
  -- One-time hire fee: base + step × (living roster − 3), capped.
  -- (2026-10-26: was 1,500 / 600 / 6,000 — a crew lost with a rocket should be
  -- a setback the ground game can pay for, not a wall.)
  hire_base = 1000,
  hire_step = 400,
  hire_cap = 4000,
  starters = 3,
  -- DEATH (§2.3). Impact: the fall speed a landing takes away, m/s. Generous
  -- on purpose (playtest 2026-10-27, "too easy to have damaging or fatal
  -- falls … makes exploring annoying"): a 4 m drop is free, a 10 m one hurts
  -- badly, about 20 m kills (Earth-like g).
  impact_injure = 9.0,
  impact_kill = 20.0,
  walk_dv = 10.0,         -- m/s of sideways Δv the walker makes itself (a run stopped)
  crush_secs = 0.4,       -- s of something solid in the suit's middle
  crush_r = 0.15,         -- m, the sphere at the capsule's centre
  heat_gain = 2.0,        -- heat += craft heating × this × dt, while exposed
  heat_cool = 0.1,        -- per second once out of the heat
  grace_suit = 15.0,      -- s of blackout on an empty suit before death
  grace_water = 10.0,     -- s of blackout under water
  hold_secs = 2.0,        -- the camera holds on the fallen this long
  heal_per_min = 0.02,    -- hp back a minute aboard or at base
  cabin_tol = 9.0,        -- m/s a crewed pod survives (the strip's "hold under")
  -- DOWNED (Permadeath only): a survivable lethal wound — a fall under
  -- down_over × impact_kill, a shot that isn't overkill — leaves the member
  -- bleeding out on the ground for bleed_secs (down to bleed_min the further
  -- past lethal it was); a Medkit in time revives them. Everything else
  -- (crushed, a lost cabin, re-entry heat, an explosion, out of air) kills
  -- outright.
  down_over = 1.6,
  shot_over = 0.5,        -- hp past zero a shot may go and still leave them down
  -- Three minutes at just-lethal, one at the edge (playtest 2026-10-27: 90 s
  -- was too short to fetch a Medkit from the depot or a crewmate's pack —
  -- a rescue should be a run, not a lottery).
  bleed_secs = 180.0,
  bleed_min = 60.0,
  -- CREW BODIES (§4.1)
  body_range = 2500.0,    -- m from the focus: further, a record only
  body_spawn = 2000.0,    -- m: a record comes back as a body inside this
}

VERSION = 2
version = 0
-- The last death (WS2's camera hold and caption read it; probes too).
lastDeath = nil
-- WS2 sets this true while a crew cam or V's IVA wants the dolls in closed
-- pods drawn; otherwise they stay hidden inside the hull (a 2 m suit in a
-- 1 m capsule shows through it).
showInterior = false

local function P(k) return (params and params[k]) or defaults[k] end
local function bump() version = (version or 0) + 1 end
local go_down, down_monitor, treat_tick, cancel_treat   -- (the downed and the Medkit, below)

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not (r and r.valid ~= false) then
    r = findScript and findScript(kind) or nil
    refs[kind] = r
  end
  return r
end

local function now() return time or 0 end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end

local function copy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = copy(v) end
  return o
end

local function caption(text)
  local fx = ref("sfx")
  if fx and fx.caption then pcall(fx.caption, text) end
end

-- ── names ───────────────────────────────────────────────────────────────────
-- Deterministic from the save's seed and the id, so the same save always
-- hires the same people, and two saves don't.
FIRST = { "Dana", "Jonah", "Mira", "Theo", "Rina", "Tomas", "Ada", "Kofi", "Lena", "Ravi",
          "Iris", "Mateo", "Noor", "Elias", "Saga", "Ken", "Hana", "Owen", "Yara", "Felix",
          "June", "Arjun", "Talia", "Bram", "Imani", "Leo", "Wren", "Sami", "Elif", "Nils" }
LAST = { "Okafor", "Reyes", "Hale", "Vance", "Ito", "Lindqvist", "Moreau", "Adeyemi", "Kowalski", "Nakamura",
         "Brennan", "Castillo", "Haddad", "Sorensen", "Achebe", "Varga", "Pillai", "Duarte", "Kerr", "Mendel",
         "Osei", "Falk", "Quinn", "Tanaka", "Rasmussen", "Abara", "Novak", "Halloran", "Ivers", "Bauer" }

local function mix(a)
  -- a small integer hash (xorshift-style, kept inside 2^31 for luajit doubles)
  a = math.floor(a) % 2147483647
  for _ = 1, 3 do
    a = (a * 48271) % 2147483647
  end
  return a
end

function nameFor(seed, n)
  local h = mix((seed or 0) + (n or 0) * 7919 + 13)
  local f = FIRST[(h % #FIRST) + 1]
  local l = LAST[(math.floor(h / #FIRST) % #LAST) + 1]
  return f .. " " .. l
end

-- ── seats (§3.1) ───────────────────────────────────────────────────────────
-- Per part id: the slots (part frame, the blueprint's x,y,z frame; yaw = the
-- way the doll faces, about the part's +Y, 0 = the part's +X), the hatch
-- (point + outward normal), whether the slots COMMAND the craft (a cabin
-- carries people and flies nothing) and whether they are OPEN (a seat is
-- its own exit; the rider shows). Mirrors parts_registry / parts_aero.
SEATS = {
  pod     = { command = true,
              seats = { { x = 0.0, y = -0.22, z = 0.16, yaw = 1.5708 } },
              hatch = { x = 0.47, y = -0.02, z = 0.0, nx = 1, ny = 0, nz = 0 } },
  podMk2  = { command = true,
              seats = { { x = 0.0, y = -0.28, z = 0.22, yaw = 1.5708 },
                        { x = -0.66, y = -0.28, z = 0.16, yaw = 1.8708 },
                        { x = 0.66, y = -0.28, z = 0.16, yaw = 1.2708 } },
              hatch = { x = 0.49, y = -0.06, z = 0.0, nx = 1, ny = 0, nz = 0 } },
  cabin   = { command = false,
              seats = { { x = -0.44, y = -0.3, z = 0.64, yaw = 1.5708 }, { x = 0.44, y = -0.3, z = 0.64, yaw = 1.5708 },
                        { x = 0.44, y = -0.3, z = -0.64, yaw = -1.5708 }, { x = -0.44, y = -0.3, z = -0.64, yaw = -1.5708 } },
              hatch = { x = 0.51, y = -0.1, z = 0.0, nx = 1, ny = 0, nz = 0 } },
  seat    = { command = true, open = true, seats = { { x = 0, y = 0, z = 0, yaw = 0 } } },
  saddle  = { command = true, open = true, seats = { { x = 0, y = 0, z = 0, yaw = 0 } } },
  cockpit = { command = true,
              seats = { { x = 0.0, y = 0.1, z = 0.05, yaw = 0 } },
              hatch = { x = 0.0, y = 0.2, z = -0.55, nx = 0, ny = 0, nz = -1 } },
}

-- A part record (or a part id) → its seat definition, or nil (no seats).
-- Any other crewed part (a modded one) gets one slot like the Pod Mk1, or
-- an open seat when it says `seat`.
function seatDef(rec)
  local id = type(rec) == "table" and rec.id or rec
  local d = SEATS[id or ""]
  if d then return d end
  if type(rec) == "table" and rec.kind == "crewed" then
    return ((rec.seat or 0) == 1 or rec.seat == true) and SEATS.seat or SEATS.pod
  end
  return nil
end

function slotCount(rec)
  local d = seatDef(rec)
  return d and #d.seats or 0
end

local function st_of(rec)
  local st = rec and rec.st
  if type(st) == "string" then
    local E = ref("electronics")
    if E and E.decodeState then st = E.decodeState(st); rec.st = st end
  end
  return type(st) == "table" and st or nil
end

function memberAt(rec, k)
  local st = st_of(rec)
  local v = st and st["crew" .. tostring(k)]
  if type(v) == "number" and v > 0 then return v end
  return nil
end

function setMemberAt(rec, k, id)
  if type(rec) ~= "table" then return end
  local st = st_of(rec)
  if not st then st = {}; rec.st = st end
  st["crew" .. tostring(k)] = id or nil
end

-- Everyone seated across a part list (a blueprint, a fleet record's parts,
-- a live craft's records): { {id, uid, slot, open, command} … } in part
-- order then slot. `alive(uid)` (optional) skips parts that are gone.
function seatedIn(parts, alive)
  local out = {}
  local list = {}
  for _, d in pairs(parts or {}) do list[#list + 1] = d end
  table.sort(list, function(a, b) return (a.uid or 0) < (b.uid or 0) end)
  for _, d in ipairs(list) do
    local def = seatDef(d)
    if def and (not alive or alive(d.uid)) then
      for k = 1, #def.seats do
        local id = memberAt(d, k)
        if id then
          out[#out + 1] = { id = id, uid = d.uid, slot = k, open = def.open == true, command = def.command == true }
        end
      end
    end
  end
  return out
end

-- Where member `id` sits in `parts`: uid, slot (nil, nil if not there).
function slotOf(parts, id)
  for _, d in pairs(parts or {}) do
    local def = seatDef(d)
    if def then
      for k = 1, #def.seats do
        if memberAt(d, k) == id then return d.uid, k end
      end
    end
  end
  return nil, nil
end

-- The command rank of a part (lower flies): a pod over a seat, then the
-- part nearest the root, then uid — vessel_controller's own ranking.
local function cmd_rank(d, depth)
  return (depth or 0) * 1e6 + (d.uid or 0) + ((((d.seat or 0) == 1) or d.seat == true) and 1e9 or 0)
end

-- The member at the controls: the one in the best-ranked COMMAND slot.
-- `depth(uid)` (optional) gives the part's tree depth.
function commanderOf(parts, depth, alive)
  local best, rank = nil, nil
  for _, d in pairs(parts or {}) do
    local def = seatDef(d)
    if def and def.command and (not alive or alive(d.uid)) then
      for k = 1, #def.seats do
        local id = memberAt(d, k)
        if id then
          local r = cmd_rank(d, depth and depth(d.uid)) * 16 + k
          if not rank or r < rank then best, rank = id, r end
        end
      end
    end
  end
  return best
end

-- The free slot boarding fills: in `prefer_uid` if it has one, else the
-- best command slot, else any. → uid, slot | nil
function freeSlot(parts, prefer_uid, alive)
  local cand = {}
  for _, d in pairs(parts or {}) do
    local def = seatDef(d)
    if def and (not alive or alive(d.uid)) then
      for k = 1, #def.seats do
        if not memberAt(d, k) then
          local r = (d.uid == prefer_uid and 0 or 1) * 1e12 + (def.command and 0 or 1e11) + cmd_rank(d) * 16 + k
          cand[#cand + 1] = { uid = d.uid, slot = k, r = r }
        end
      end
    end
  end
  table.sort(cand, function(a, b) return a.r < b.r end)
  if cand[1] then return cand[1].uid, cand[1].slot end
  return nil, nil
end

-- ── the VAB seat plan (§3.2, §5.6; WS2 draws the CREW tab) ─────────────────
-- A plan is a list { {uid, slot, id} … } (the blueprint's `crew`, or the
-- save key `shipyard.crew` the CREW tab writes). Checked, not trusted:
function validatePlan(parts, plan)
  local by = {}
  for _, d in pairs(parts or {}) do by[d.uid] = d end
  local seen, slots, cmd = {}, {}, false
  for _, e in ipairs(plan or {}) do
    local d = by[e.uid]
    local def = d and seatDef(d)
    if not def then return false, "no seat there" end
    if (e.slot or 0) < 1 or e.slot > #def.seats then return false, "no such seat" end
    local key = tostring(e.uid) .. "/" .. tostring(e.slot)
    if slots[key] then return false, "two crew in one seat" end
    if seen[e.id] then return false, "one crew member in two seats" end
    slots[key], seen[e.id] = true, true
    if def.command then cmd = true end
  end
  if #(plan or {}) > 0 and not cmd then return false, "nobody at the controls" end
  return true, nil
end

-- The seats at launch. `avail(id)` says who may fly (alive, at base or the
-- avatar standing at the base); `active` is the avatar's member. Bad
-- entries are dropped. With no plan (or none left) the active member takes
-- the best command slot: today's single-crew launch. → list, commanderId
function launchPlan(parts, plan, avail, active)
  local by = {}
  for _, d in pairs(parts or {}) do by[d.uid] = d end
  local out, seen, slots = {}, {}, {}
  for _, e in ipairs(plan or {}) do
    local d = by[e.uid]
    local def = d and seatDef(d)
    local key = tostring(e.uid) .. "/" .. tostring(e.slot)
    if def and e.id and (e.slot or 0) >= 1 and e.slot <= #def.seats and not slots[key] and not seen[e.id]
      and (not avail or avail(e.id)) then
      out[#out + 1] = { uid = e.uid, slot = e.slot, id = e.id }
      seen[e.id], slots[key] = true, true
    end
  end
  local tmp = {}
  for _, d in pairs(parts or {}) do
    local st = {}
    tmp[#tmp + 1] = { uid = d.uid, id = d.id, kind = d.kind, seat = d.seat, st = st }
  end
  local tby = {}
  for _, d in ipairs(tmp) do tby[d.uid] = d end
  for _, e in ipairs(out) do setMemberAt(tby[e.uid], e.slot, e.id) end
  local cmdr = commanderOf(tmp)
  if not cmdr and active and (not avail or avail(active)) and not seen[active] then
    -- nobody at the controls: the avatar takes the best command slot
    local best, rank, slot = nil, nil, nil
    for _, d in ipairs(tmp) do
      local def = seatDef(d)
      if def and def.command then
        for k = 1, #def.seats do
          if not memberAt(d, k) then
            local r = cmd_rank(d) * 16 + k
            if not rank or r < rank then best, rank, slot = d, r, k end
          end
        end
      end
    end
    if best then
      out[#out + 1] = { uid = best.uid, slot = slot, id = active }
      setMemberAt(best, slot, active)
      cmdr = active
    end
  end
  return out, cmdr
end

-- ── records ────────────────────────────────────────────────────────────────
local function key(id) return "crew.m." .. tostring(id) end

function newRecord(id, name, fields)
  local r = { id = id, name = name, hired = 0, cost = 0, starter = false, status = "base",
              o2 = 1.0, breath = 1.0, hp = 1.0, heat = 0.0, helmet = true, rcs = nil,
              hand = nil, task = nil, flights = 0, eva_s = 0, flags = 0, repairs = 0 }
  for k, v in pairs(fields or {}) do r[k] = v end
  return r
end

local function put(rec)
  save.set(key(rec.id), rec)
  bump()
end

local function ids()
  local r = save.get("crew.roster")
  return type(r) == "table" and r or {}
end

-- ── migration (runs once per save; docs §2.4) ──────────────────────────────
-- Writes `crew.version`; running it again is a no-op. The pack moves only
-- when the inventory alias is in (inventory.resolve exists): before that,
-- moving it would empty the pack every "astro" caller still reads. A save
-- migrated before the alias landed moves the pack the first time it can.
--   version 1: member #1 from the single astronaut (slice 1)
--   version 2: the three-astronaut start — #2 and #3 join at base (slice 2);
--              a v1 save keeps its member #1, their pack and progress.
local ensured = false

local function move_bag(from, to)
  local a = save.get(from)
  if type(a) ~= "table" or next(a) == nil then return false end
  local b = save.get(to)
  b = type(b) == "table" and b or {}
  for k, n in pairs(a) do b[k] = (b[k] or 0) + n end
  save.set(to, b)
  if save.delete then save.delete(from) else save.set(from, {}) end
  return true
end

-- Move today's suit pack onto member #1. Global for tests and probes.
function movePack(id)
  id = id or 1
  local moved
  local inv = ref("inventory")
  if inv and inv.adoptPack then
    -- inventory's own move: the bags, the tank fills and the issue stamp
    moved = inv.adoptPack("astro", "crew:" .. id)
    if save.delete then save.delete("inv.astro"); save.delete("inv.gear.astro") end
  else
    moved = move_bag("inv.astro", "inv.crew:" .. id)
    moved = move_bag("inv.gear.astro", "inv.gear.crew:" .. id) or moved
  end
  save.set("crew.packMoved", true)
  return moved
end

local function alias_ready()
  local inv = ref("inventory")
  return inv ~= nil and type(inv.resolve) == "function"
end

-- Where the existing astronaut is: aboard a fleet craft (crew = true), or on
-- foot at game_manager's saved position.
local function place_member_one(rec)
  local f = save.get("fleet.craft")
  if type(f) == "table" then
    local fids = {}
    for fid in pairs(f) do fids[#fids + 1] = fid end
    table.sort(fids)
    for _, fid in ipairs(fids) do
      local c = f[fid]
      if type(c) == "table" and c.crew == true and type(c.parts) == "table" then
        local target = nil
        for _, d in ipairs(c.parts) do
          if c.station and d.uid == c.station then target = d end
        end
        if not target then
          for _, d in ipairs(c.parts) do
            if not target and (d.kind == "crewed" or d.id == "pod") then target = d end
          end
        end
        if target then
          setMemberAt(target, 1, rec.id)
          save.set("fleet.craft", f)
        end
        rec.status, rec.craft = "aboard", c.name
        return
      end
    end
  end
  rec.status = "afoot"
  rec.body = save.get("p_body")
  rec.x, rec.y, rec.z = save.get("p_x"), save.get("p_y"), save.get("p_z")
end

-- The starters a save is owed (v2): members up to `starters`, free, at base.
local function add_starters()
  local seed = save.get("g_seed") or 0
  local r = ids()
  local seq = save.get("crew.seq") or 0
  local starters = 0
  for _, id in ipairs(r) do
    local rec = save.get(key(id))
    if type(rec) == "table" and rec.starter then starters = starters + 1 end
  end
  local added = 0
  while starters < P("starters") do
    seq = seq + 1
    local rec = newRecord(seq, nameFor(seed, seq), { hired = 0, starter = true, cost = 0, status = "base" })
    put(rec)
    r[#r + 1] = seq
    starters, added = starters + 1, added + 1
    local inv = ref("inventory")
    if inv and inv.ensureKit then pcall(inv.ensureKit, "crew:" .. seq) end
  end
  save.set("crew.roster", r)
  save.set("crew.seq", seq)
  return added
end

function migrate()
  local v = save.get("crew.version")
  if v ~= nil and v >= VERSION then return false end
  if v == nil then
    local old = save.get("g_played") ~= nil
    local seq = save.get("crew.seq") or 0
    local id = 1
    local seed = save.get("g_seed") or 0
    local rec = newRecord(id, nameFor(seed, id), { hired = 0, starter = true, cost = 0 })
    if old then
      place_member_one(rec)
    else
      rec.status = "afoot"
    end
    -- The tool in hand (tool_belt's key) is the record's hand from now on.
    local tid = save.get("tool.id")
    if type(tid) == "string" then rec.hand = tid end
    put(rec)
    save.set("crew.roster", { id })
    save.set("crew.seq", math.max(seq, id))
    save.set("crew.active", id)
    if save.get("crew.death") == nil then save.set("crew.death", true) end
  end
  -- v2: the three-astronaut start (a v1 save keeps member #1 as they are)
  local added = add_starters()
  if v ~= nil and added > 0 then
    save.set("crew.notice", string.format("%d more astronauts have joined the agency. They wait at the base.", added))
  end
  save.set("crew.version", VERSION)
  return true
end

-- Make the store current. Cheap after the first call in a scene; every
-- public function calls it, so nothing reads a half-made roster.
function ensure()
  if ensured then return end
  if not save then return end
  migrate()
  if save.get("crew.packMoved") ~= true and alias_ready() then
    movePack(save.get("crew.active") or 1)
  end
  -- Not done until the pack has moved: while inventory's alias is missing,
  -- every call asks again (one save read).
  ensured = save.get("crew.packMoved") == true
end

-- Tests: forget the cached state (a new store).
function reset()
  ensured = false
  version = 0
end

-- ── lookups ────────────────────────────────────────────────────────────────
function get(id)
  ensure()
  if id == nil then return nil end
  local r = save.get(key(id))
  return type(r) == "table" and r or nil
end

function roster()
  ensure()
  local out = {}
  for _, id in ipairs(ids()) do
    local r = get(id)
    if r then out[#out + 1] = r end
  end
  return out
end

function activeId()
  ensure()
  local a = save.get("crew.active")
  if type(a) == "number" then return a end
  return nil
end

local function set_active(id)
  save.set("crew.active", id or false)
  bump()
end

function packOf(id)
  return "crew:" .. tostring(id or activeId() or 1)
end

-- Merge fields into a record (other crew scripts use this; panels poll
-- `version`). `nil` can't be merged, so a field is cleared with `false`.
local CLEAR = { task = true, hand = true, craft = true, died = true, body = true, x = true, y = true, z = true,
                yaw = true, anchor = true, face = true, downed = true }
function patch(id, fields)
  local r = get(id)
  if not r then return false end
  for k, v in pairs(fields or {}) do
    if v == false and CLEAR[k] then r[k] = nil else r[k] = v end
  end
  put(r)
  return true
end

function rename(id, s)
  if type(s) ~= "string" then return false, "not a name" end
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  if #s < 1 or #s > 32 then return false, "1–32 characters" end
  return patch(id, { name = s }), nil
end

-- status, detail: "afoot", body | "aboard", craft | "base", nil | "dead", cause
function where(id)
  local r = get(id)
  if not r then return nil, nil end
  if r.status == "aboard" then return "aboard", r.craft end
  if r.status == "afoot" then return "afoot", r.body end
  if r.status == "dead" then return "dead", r.died and r.died.cause end
  return r.status, nil
end

-- ── hiring (§2.2) ──────────────────────────────────────────────────────────
function living()
  local n = 0
  for _, r in ipairs(roster()) do if r.status ~= "dead" then n = n + 1 end end
  return n
end

function hireFee(alive)
  alive = alive or living()
  local fee = P("hire_base") + P("hire_step") * math.max(0, alive - 3)
  return math.min(P("hire_cap"), fee)
end

function offers()
  ensure()
  local o = save.get("crew.offers")
  if type(o) ~= "table" or #o < 3 then
    o = type(o) == "table" and o or {}
    local seed, n = save.get("g_seed") or 0, (save.get("crew.offerSeq") or 100)
    while #o < 3 do
      n = n + 1
      o[#o + 1] = { name = nameFor(seed, n) }
    end
    save.set("crew.offerSeq", n)
    save.set("crew.offers", o)
  end
  local fee = hireFee()
  local free = living() == 0
  local out = {}
  for i, a in ipairs(o) do
    out[i] = { name = a.name, cost = (free and i == 1) and 0 or fee, free = (free and i == 1) or nil }
  end
  return out
end

-- Hire applicant i. opts.free: no fee and the kit is free (the newbie).
function hire(i, opts)
  opts = opts or {}
  local list = offers()
  local a = list[i or 1]
  if not a then return nil, "no such applicant" end
  local cost = opts.free and 0 or a.cost
  if cost > 0 then
    local co = ref("company")
    if co and co.spend then
      if not co.spend(cost, "crew hire: " .. a.name) then return nil, "not enough money" end
    end
  end
  local id = (save.get("crew.seq") or 0) + 1
  save.set("crew.seq", id)
  local rec = newRecord(id, a.name, { hired = (space and space.time and space.time()) or 0, cost = cost })
  put(rec)
  local r = ids()
  r[#r + 1] = id
  save.set("crew.roster", r)
  local o = save.get("crew.offers") or {}
  table.remove(o, i or 1)
  save.set("crew.offers", o)
  -- the standard issue (§5.1): whatever the inventory offers for it
  local inv = ref("inventory")
  if inv and inv.ensureKit then pcall(inv.ensureKit, packOf(id), cost == 0 and { free = true } or nil) end
  log_(string.format("crew: hired %s (#%d) for $%d", a.name, id, cost))
  return id, nil
end

function log_(s) if log then log(s) end end

-- ── death settings (§2.3): CREW SAFETY ─────────────────────────────────────
-- "death": permadeath (the default); "rescue": whoever would die is brought
-- home for a fee; "invincible": nothing hurts the crew at all — no hp lost to
-- an impact, a shot, a crush, re-entry heat or an empty suit (the air still
-- runs down on the gauge; it just never blacks anyone out), and the alert
-- chips stay quiet. A save from before the three-way switch has only the
-- boolean `crew.death`, read as death / rescue.
SAFETY = { "death", "rescue", "invincible" }
function safety()
  ensure()
  local s = save.get("crew.safety")
  if s == "death" or s == "rescue" or s == "invincible" then return s end
  return save.get("crew.death") == false and "rescue" or "death"
end

function setSafety(mode)
  if mode ~= "rescue" and mode ~= "invincible" then mode = "death" end
  save.set("crew.safety", mode)
  save.set("crew.death", mode == "death")
  bump()
end

-- THE one check every harm path asks.
function invincible() return safety() == "invincible" end

function deathOn() return safety() == "death" end

function setDeath(on) setSafety(on and "death" or "rescue") end

function memorial()
  local out = {}
  for _, r in ipairs(roster()) do
    if r.status == "dead" then
      out[#out + 1] = { id = r.id, name = r.name, hired = r.hired, died = r.died, flights = r.flights,
                        eva_s = r.eva_s, flags = r.flags, home = r.died and r.died.home == true or false }
    end
  end
  return out
end

-- ── the death rules, pure (§2.3; smoke_crew_death) ─────────────────────────
-- Impact: Δv this tick → "ok" | "injure", hp lost | "kill"
function impactRule(dv)
  if dv >= P("impact_kill") then return "kill", 1.0 end
  if dv > P("impact_injure") then return "injure", (dv - P("impact_injure")) / (P("impact_kill") - P("impact_injure")) end
  return "ok", 0
end

-- Crush: seconds pinned so far → new seconds, dead?
function crushStep(t, pinned, dt)
  if not pinned then return 0, false end
  t = (t or 0) + dt
  return t, t >= P("crush_secs")
end

-- Re-entry exposure: heat, the craft's heating rate, exposed? → new heat, dead?
function heatStep(heat, rate, exposed, dt)
  heat = heat or 0
  if exposed and (rate or 0) > 0 then
    heat = heat + rate * P("heat_gain") * dt
  else
    heat = math.max(0, heat - P("heat_cool") * dt)
  end
  return heat, heat >= 1.0
end

-- The warning level of a reserve 0..1 with `secs` left: nil | "low" (25%)
-- | "crit" (10%) | "min" (a minute or less).
function airLevel(frac, secs)
  if secs and secs <= 60 then return "min" end
  if frac <= 0.10 then return "crit" end
  if frac <= 0.25 then return "low" end
  return nil
end

function blackoutGrace(src)
  return src == "hold" and P("grace_water") or P("grace_suit")
end

-- The handoff order when the controlled member dies (§2.3), pure: the
-- candidates → the pick.
--   onfoot = { {id, dist} … } living members on foot in range
--   craft  = the craft they were in (a handle) if it still carries crew
--   crafts = { {v, dist} … } other crewed craft in range
--   base   = { id … } living members at base
-- → kind, what: "crew", id | "craft", v | "base", id | "newbie", nil
function handoffPick(onfoot, craft, crafts, base)
  local best, bd = nil, nil
  for _, c in ipairs(onfoot or {}) do
    if not bd or (c.dist or 0) < bd then best, bd = c.id, c.dist or 0 end
  end
  if best then return "crew", best end
  if craft then return "craft", craft end
  local bv, bvd = nil, nil
  for _, c in ipairs(crafts or {}) do
    if not bvd or (c.dist or 0) < bvd then bv, bvd = c.v, c.dist or 0 end
  end
  if bv then return "craft", bv end
  if base and base[1] then return "base", base[1] end
  return "newbie", nil
end

-- ── where the crew physically is ───────────────────────────────────────────
local bodies = {}      -- id → CrewBody node (on foot, in range)
local bodyWant = {}    -- id → true while a spawn is queued
local dolls = {}       -- id → { node, vid, uid, slot, open }
local dollWant = {}

local function astro()
  if not find then return nil end
  local a = find("Astronaut")
  if a and a.valid ~= false then return a end
  return nil
end

local function vessels()
  return findScripts and findScripts("vessel_controller") or {}
end

local function vessel_by_id(nid)
  for _, v in ipairs(vessels()) do
    if v.node and v.node.valid ~= false and v.node.id == nid then return v end
  end
  return nil
end

-- The craft the avatar rides (its `crewAboard`), or nil.
function avatarCraft()
  for _, v in ipairs(vessels()) do
    if v.crewAboard and v.node and v.node.valid ~= false then return v end
  end
  return nil
end

-- Seats of a live craft (its `seatsOf`), or {} for an older controller.
local function seats_of(v)
  if v and v.seatsOf then
    local ok, s = pcall(v.seatsOf)
    if ok and type(s) == "table" then return s end
  end
  return {}
end

function bodyOf(id)
  if id == nil then return nil end
  if id == activeId() then
    local v = avatarCraft()
    if not v then return astro() end
    return nil
  end
  local b = bodies[id]
  if b and b.valid ~= false then return b end
  return nil
end

function dollOf(id)
  local d = dolls[id]
  if d and d.node and d.node.valid ~= false then return d.node end
  return nil
end

-- The craft carrying member `id` right now (its controller handle), or nil.
function craftOf(id)
  if id == nil then return nil end
  for _, v in ipairs(vessels()) do
    if v.node and v.node.valid ~= false then
      for _, s in ipairs(seats_of(v)) do
        if s.taken == id then return v, s.uid, s.slot end
      end
      -- an older controller (no seats): the avatar's craft
      if not v.seatsOf and v.crewAboard and id == activeId() then return v end
    end
  end
  return nil
end

-- The crew aboard craft `v`, slot order, commander first: the portraits.
function aboard(v)
  local out = {}
  if not v then return out end
  local cmd = v.commander and v.commander() or nil
  for _, s in ipairs(seats_of(v)) do
    local r = s.taken and get(s.taken)
    if r and r.status ~= "dead" then
      out[#out + 1] = { id = s.taken, name = r and r.name or ("#" .. s.taken), uid = s.uid, slot = s.slot,
                        open = s.open == true, command = s.command == true, commander = s.taken == cmd,
                        hp = r and r.hp or 1, o2 = r and r.o2 or 1, label = s.label,
                        avatar = (v.crewAboard and s.taken == activeId()) or false }
    end
  end
  table.sort(out, function(a, b)
    if a.commander ~= b.commander then return a.commander end
    if a.uid ~= b.uid then return a.uid < b.uid end
    return a.slot < b.slot
  end)
  if #out == 0 and v.crewAboard and not v.seatsOf then
    local id = activeId()
    if id then out[1] = { id = id, uid = v.stationUid, slot = 1, commander = true } end
  end
  return out
end

function seatMap(v)
  return seats_of(v)
end

-- ── EVA in space (§5.7) ────────────────────────────────────────────────────
-- Is anyone on EVA in space (off the ground, nothing under them for 50 m)?
-- Rails warp is refused while they are (§5.7). eva_pack keeps the answer.
function onEvaInSpace()
  local id = activeId()
  if not id or avatarCraft() then return false, nil end
  local ep = ref("eva_pack")
  if ep and ep.inSpace then
    local ok, v = pcall(ep.inSpace)
    if ok and v then return true, id end
  end
  return false, nil
end

-- Has member `id` got an RCS Pack in their pack?
function hasPack(id)
  local inv = ref("inventory")
  if not inv then return false end
  local cid = packOf(id)
  if inv.itemCount then
    local ok, n = pcall(inv.itemCount, cid, "rcspack")
    if ok and (n or 0) > 0 then return true end
  end
  if inv.gearCount then
    local ok, n = pcall(inv.gearCount, cid, "rcspack")
    if ok and (n or 0) > 0 then return true end
  end
  return false
end

NO_PACK = "%s has no RCS Pack. Out there they can't steer or stop: they'll keep the craft's speed " ..
  "and can only grab the hatch while it's still within reach. If they drift away, the way back is " ..
  "a billed pickup."

-- ok, why, warn — `warn` set means "allowed, but ask first".
function evaCheck(id)
  id = id or activeId()
  local r = get(id)
  if not r then return false, "no such crew member", nil end
  if r.status == "dead" then return false, "dead", nil end
  local v = craftOf(id)
  if not v then return false, "not aboard a craft", nil end
  -- (a hatch blocked by the stack falls back to the clear spot round the
  -- hull, vessel_controller hatchSpot: nobody is ever shut in)
  local st = v.evaState and v.evaState() or nil
  if not st then return true, nil, nil end
  if st.surface then
    if st.speed > 1.0 then return false, string.format("moving %.0f m/s", st.speed), nil end
    return true, nil, nil
  end
  if (st.throttle or 0) > 0.001 then return false, "engines firing", nil end
  if (st.accel or 0) > 0.2 then return false, "accelerating", nil end
  if st.space and not hasPack(id) then
    return true, nil, string.format(NO_PACK, r.name)
  end
  return true, nil, nil
end

-- ── suit state on the avatar (§4.1 step 1–2) ───────────────────────────────
-- The avatar's suit (o2, helmet, hand) into member `id`'s record.
local function suit_out(id)
  if not id then return end
  local f = {}
  local pw = ref("planet_walker")
  if pw and type(pw.suitO2) == "number" then f.o2 = pw.suitO2 end
  local su = ref("suit")
  if su and su.helmetOn then
    local ok, h = pcall(su.helmetOn)
    if ok then f.helmet = h == true end
  end
  local tb = ref("tool_belt")
  if tb and tb.toolId then
    local ok, t = pcall(tb.toolId)
    if ok then f.hand = t or false end
  end
  patch(id, f)
end

-- Member `id`'s suit onto the avatar.
local function suit_in(id)
  local r = get(id)
  if not r then return end
  local pw = ref("planet_walker")
  if pw and pw.reloadSuit then pcall(pw.reloadSuit) end
  local su = ref("suit")
  if su and su.setHelmet and su.helmetOn then
    local ok, h = pcall(su.helmetOn)
    if ok and (h == true) ~= (r.helmet ~= false) then pcall(su.setHelmet, r.helmet ~= false, { quiet = true, force = true }) end
  end
  local tb = ref("tool_belt")
  if tb and tb.hold then pcall(tb.hold, r.hand) end
  -- the gravity gun lets go of whatever the last member held
  local gg = ref("gravity_gun")
  if gg and gg.drop then pcall(gg.drop) end
end

-- The body frame: name and body-relative position of a world point.
local function rel(x, y, z)
  if not (space and space.dominant) then return nil end
  local d = space.dominant(x, y, z)
  local b = d and space.body(d)
  if not b then return nil end
  return d, x - b.x, y - b.y, z - b.z
end

local function world_of(r)
  if not (r and r.body and space and space.body) then return nil end
  local b = space.body(r.body)
  if not b then return nil end
  return b.x + (r.x or 0), b.y + (r.y or 0), b.z + (r.z or 0)
end

-- ── CrewBody spawn/despawn (§4.1) ──────────────────────────────────────────
-- A record on foot becomes a body: kinematic, standing where its record says
-- (crew_body.lua keeps it there, in its planet's frame).
local function spawn_body(id, x, y, z)
  if bodies[id] or bodyWant[id] or not spawn then return end
  bodyWant[id] = true
  local ok = pcall(spawn, "CrewBody", vec3 and vec3(x, y, z) or { x = x, y = y, z = z }, function(n)
    bodyWant[id] = nil
    local r = get(id)
    if not (r and r.status == "afoot") or bodies[id] then
      if n and n.valid ~= false then destroy(n) end
      return
    end
    bodies[id] = n
  end)
  if not ok then bodyWant[id] = nil end
end

local function despawn_body(id)
  local b = bodies[id]
  bodies[id] = nil
  if b and b.valid ~= false and destroy then destroy(b) end
end

-- Leave the avatar's member where they stand: a CrewBody at the avatar's
-- pose, the record on foot there.
local function park_avatar_member(id)
  local a = astro()
  if not (a and id) then return end
  suit_out(id)
  local d, x, y, z = rel(a.x, a.y, a.z)
  -- the way they face: the suit model's (the rig looks along its node's +Z)
  local face = false
  for _, ch in ipairs(a.children and a:children() or {}) do
    if ch.name == "AstroModel" and ch.worldForward then
      local f = ch:worldForward()
      face = { x = -f.x, y = -f.y, z = -f.z }
    end
  end
  patch(id, { status = "afoot", craft = false, body = d, x = x, y = y, z = z, face = face, anchor = false })
  spawn_body(id, a.x, a.y, a.z)
end

-- ── dolls (§3.4) ───────────────────────────────────────────────────────────
local function spawn_doll(id, v, s)
  if dolls[id] or dollWant[id] or not spawn then return end
  dollWant[id] = true
  local vid = v.node.id
  local ok = pcall(spawn, "CrewDoll", vec3 and vec3(v.node.x, v.node.y, v.node.z) or nil, function(n)
    dollWant[id] = nil
    if dolls[id] then if n and n.valid ~= false then destroy(n) end return end
    dolls[id] = { node = n, vid = vid, uid = s.uid, slot = s.slot, open = s.open }
  end)
  if not ok then dollWant[id] = nil end
end

local function despawn_doll(id)
  local d = dolls[id]
  dolls[id] = nil
  if d and d.node and d.node.valid ~= false and destroy then destroy(d.node) end
end

-- Who should be a doll right now: every seated member except the avatar in
-- the craft it rides. Spawns what is missing, drops what is not.
local doll_t = -10
function dollSync(force)
  if not force and now() - doll_t < 0.25 then return end
  doll_t = now()
  local want = {}
  local active = activeId()
  for _, v in ipairs(vessels()) do
    if v.node and v.node.valid ~= false and not (v.isLost and v.isLost()) then
      for _, s in ipairs(seats_of(v)) do
        local r = s.taken and get(s.taken)
        if r and r.status ~= "dead" and not (v.crewAboard and s.taken == active) and not want[s.taken] then
          want[s.taken] = { v = v, s = s }
        end
      end
    end
  end
  for id, d in pairs(dolls) do
    local w = want[id]
    if not w or not (d.node and d.node.valid ~= false) or d.vid ~= w.v.node.id then
      despawn_doll(id)
    else
      d.uid, d.slot, d.open = w.s.uid, w.s.slot, w.s.open
    end
  end
  for id, w in pairs(want) do
    if not dolls[id] then spawn_doll(id, w.v, w.s) end
  end
end

-- Where doll `id` goes this frame (crew_body.lua asks in its lateUpdate):
-- → x,y,z, the part's up and forward (+X) and the doll's yaw, open, vessel
function dollPose(id)
  local d = dolls[id]
  if not d then return nil end
  local v = vessel_by_id(d.vid)
  if not (v and v.partFrameNow) then return nil end
  -- A closed part's crew sit in its interior (iva.lua: a human-scale room kept
  -- in a space of its own, docs/crew-and-items.md §3.4): ask it first.
  if not d.open then
    local I = ref("iva")
    if I and I.dollPose then
      local ok, p = pcall(I.dollPose, v, d.uid, d.slot)
      if ok and p then return p end
    end
  end
  local ok, F = pcall(v.partFrameNow, d.uid, true)
  if not ok or not F then return nil end
  local rec = v.partRec and v.partRec(d.uid)
  local def = seatDef(rec)
  local s = def and def.seats[d.slot] or { x = 0, y = 0, z = 0, yaw = 0 }
  local x = F.ox + F.rx * s.x + F.ux * s.y + F.zx * s.z
  local y = F.oy + F.ry * s.x + F.uy * s.y + F.zy * s.z
  local z = F.oz + F.rz * s.x + F.uz * s.y + F.zz * s.z
  local c, sn = math.cos(s.yaw or 0), math.sin(s.yaw or 0)
  -- facing: the part's +X turned by yaw about its +Y
  local fx, fy, fz = F.rx * c - F.zx * sn, F.ry * c - F.zy * sn, F.rz * c - F.zz * sn
  return { x = x, y = y, z = z, ux = F.ux, uy = F.uy, uz = F.uz, fx = fx, fy = fy, fz = fz,
           open = d.open == true, v = v, uid = d.uid, visible = d.open == true or showInterior == true }
end

-- Which member a spawned CrewBody / CrewDoll node is (crew_body.lua asks:
-- a spawn callback runs before the new node's scripts do, so the binding
-- can't be pushed into them). → id, "doll"|"body" | nil
function memberOfNode(n)
  if not n then return nil end
  for id, d in pairs(dolls) do if d.node == n then return id, "doll" end end
  for id, b in pairs(bodies) do if b == n then return id, "body" end end
  return nil
end

-- Command Seats pose their own rider (command_seat.lua): the doll in the
-- seat of craft node `vid`, part `uid`, if there is one.
function dollAt(vid, uid)
  for id, d in pairs(dolls) do
    if d.vid == vid and d.uid == uid and d.node and d.node.valid ~= false then return d.node, id end
  end
  return nil
end

-- ── who the controls go to ─────────────────────────────────────────────────
-- What you control now: { kind = "crew", id } on foot, or { kind = "vessel", v }.
function current()
  for _, v in ipairs(vessels()) do
    if v.piloting and v.node and v.node.valid ~= false then return { kind = "vessel", v = v, id = v.node.id } end
  end
  return { kind = "crew", id = activeId() }
end

local prev = nil  -- the last thing controlled before the current one (quickSwap)
local function remember()
  local c = current()
  if c.kind == "vessel" then prev = { kind = "vessel", nid = c.v.node.id }
  else prev = { kind = "crew", id = c.id } end
end

-- Let go of whatever the avatar is doing before it becomes someone else:
-- a ridden craft keeps its member seated (a doll from now on); a member on
-- foot is left standing there (a CrewBody).
local function free_avatar(keep_v)
  local id = activeId()
  local ride = avatarCraft()
  if ride then
    suit_out(id)
    if not (keep_v and ride.node.id == keep_v.node.id) then
      if ride.releaseControl then pcall(ride.releaseControl) end
      if ride.crewLeave then pcall(ride.crewLeave) end
    end
  else
    for _, v in ipairs(vessels()) do
      if v.piloting and v.releaseControl and not (keep_v and v.node.id == keep_v.node.id) then pcall(v.releaseControl) end
    end
    local r = get(id)
    if r and r.status ~= "dead" then park_avatar_member(id) end
  end
end

-- Switching requests run in the physics tick (an avatar moved outside it on
-- a moving world stands a rails carry from where it was put).
local queue = {}

-- TAKE CONTROL of member `id` (§4.1).
function control(id)
  local r = get(id)
  if not r then return false, "no such crew member" end
  if r.status == "dead" then return false, r.name .. " is dead" end
  if r.status == "base" then return false, r.name .. " is at the base" end
  if r.downed then return false, r.name .. " is down — bring a Medkit" end
  local v = craftOf(id)
  if v then return takeCraft(v, id) end
  if id == activeId() and not avatarCraft() then
    -- already them on foot: just take the controls back from a craft
    for _, w in ipairs(vessels()) do if w.piloting and w.releaseControl then pcall(w.releaseControl) end end
    return true, nil
  end
  if not bodies[id] then return false, r.name .. " is out of range" end
  queue[#queue + 1] = { kind = "control", id = id }
  return true, nil
end

-- FLY craft `v` as member `id` (default: its commander, else anyone aboard).
function takeCraft(v, id)
  if not (v and v.node and v.node.valid ~= false) then return false, "no craft" end
  local seated = aboard(v)
  if #seated == 0 then return false, "nobody aboard" end
  if not id then id = seated[1].id end
  local found = false
  for _, s in ipairs(seated) do if s.id == id then found = true end end
  if not found then return false, "not aboard that craft" end
  queue[#queue + 1] = { kind = "craft", nid = v.node.id, id = id }
  return true, nil
end

-- EVA member `id` out of their craft's hatch (§3.5, §4.3). opts.stay: out
-- as a CrewBody, you keep flying. opts.confirmed: past the no-pack warning.
function eva(id, opts)
  id = id or activeId()
  opts = opts or {}
  local ok, why, warn = evaCheck(id)
  if not ok then return false, why end
  if warn and not opts.confirmed then return false, "confirm", warn end
  local v, uid = craftOf(id)
  if not v then return false, "not aboard a craft" end
  if not v.seatsOf then
    -- an older controller: the single astronaut
    if not v.evaNow then return false, "no hatch" end
    if not v.evaNow() then return false, "no clear spot outside" end
    return true, nil
  end
  if not opts.stay then remember() end
  queue[#queue + 1] = { kind = "eva", id = id, nid = v.node.id, uid = uid, stay = opts.stay == true }
  return true, nil
end

-- Board craft `v`: the avatar (today's F), or an idle CrewBody ("Board").
function board(id, v, uid, slot)
  if not (v and v.node) then return false, "not a craft" end
  if id == activeId() and not avatarCraft() then
    if not v.boardNow then return false, "not a craft" end
    if v.boardNow() then return true, nil end
    return false, "out of reach"
  end
  local b = bodies[id]
  if not b then return false, "not on foot nearby" end
  if not v.seatMember then return false, "can't seat a second crew member" end
  local s_uid, s_slot = uid, slot
  if not s_uid and v.freeSeat then
    s_uid, s_slot = v.freeSeat(nil)
  end
  if not s_uid then return false, "no free seat" end
  local ok, why = v.seatMember(s_uid, s_slot, id)
  if not ok then return false, why end
  despawn_body(id)
  patch(id, { status = "aboard", craft = v.craftName or false, body = false, x = false, y = false, z = false })
  return true, nil
end

-- Back to the last thing you controlled (`).
function quickSwap()
  if not prev then return false, "nothing to swap back to" end
  local p = prev
  if p.kind == "vessel" then
    local v = vessel_by_id(p.nid)
    if not v then prev = nil return false, "that craft is gone" end
    return switchTo({ kind = "vessel", v = v })
  end
  return switchTo({ kind = "crew", id = p.id })
end

-- ── the switch list (§4.2) ─────────────────────────────────────────────────
-- Everything [ ] steps through: each member on foot in range (by name), and
-- every craft with a command part in range. Range from what you control now.
local function pos_of_current(c)
  if c.kind == "vessel" then local n = c.v.node return n.x, n.y, n.z end
  local a = astro()
  if a then return a.x, a.y, a.z end
  return nil
end

function switchList(range)
  range = range or P("body_range")
  local cur = current()
  local cx, cy, cz = pos_of_current(cur)
  local out = {}
  local active = activeId()
  local ride = avatarCraft()
  if active and not ride then
    local r = get(active)
    if r and r.status ~= "dead" then out[#out + 1] = { kind = "crew", id = active, name = r.name, dist = 0 } end
  end
  for id, b in pairs(bodies) do
    if b.valid ~= false then
      local r = get(id)
      local d = cx and len(b.x - cx, b.y - cy, b.z - cz) or 0
      if r and r.status == "afoot" and d <= range then
        out[#out + 1] = { kind = "crew", id = id, name = r.name, dist = d }
      end
    end
  end
  table.sort(out, function(a, b) return a.name < b.name or (a.name == b.name and a.id < b.id) end)
  local craft = {}
  for _, v in ipairs(vessels()) do
    local n = v.node
    if n and n.valid ~= false and v.controlState then
      local cs = v.controlState()
      if (cs.pod or cs.probe) and not cs.lost then
        local d = cx and len(n.x - cx, n.y - cy, n.z - cz) or 0
        local mine = (cur.kind == "vessel" and cur.v.node.id == n.id) or (ride and ride.node.id == n.id)
        if mine or d <= range then
          local nc = #aboard(v)
          craft[#craft + 1] = { kind = "vessel", v = v, name = v.craftName or n.name or "Vessel", id = n.id,
                                dist = d, crew = nc, can = cs.can or nc > 0, why = cs.why }
        end
      end
    end
  end
  table.sort(craft, function(a, b) return a.name < b.name or (a.name == b.name and a.id < b.id) end)
  for _, c in ipairs(craft) do out[#out + 1] = c end
  return out, cur
end

-- Go to a switch-list target.
function switchTo(t)
  if not t then return false, "nothing there" end
  if t.kind == "crew" then
    remember()
    return control(t.id)
  end
  local v = t.v
  if not (v and v.node and v.node.valid ~= false) then return false, "that craft is gone" end
  remember()
  local ride = avatarCraft()
  if #aboard(v) > 0 and not (ride and ride.node.id == v.node.id) then
    return takeCraft(v)
  end
  local fo = ref("flight_ops")
  if fo and fo.switchToVessel then
    if fo.switchToVessel(v) then return true, nil end
    return false, "it would not answer"
  end
  if v.remoteControl and v.remoteControl() then return true, nil end
  return false, "it would not answer"
end

-- Step `dir` (+1/−1) along the list. → the target's caption, or nil.
function step(dir)
  local list, cur = switchList()
  if #list < 2 then return nil, "nothing else in range to switch to" end
  local i = 0
  local ride = avatarCraft()
  for k, t in ipairs(list) do
    if cur.kind == "crew" and t.kind == "crew" and t.id == cur.id then i = k end
    if cur.kind == "vessel" and t.kind == "vessel" and t.v.node.id == cur.v.node.id then i = k end
  end
  if i == 0 and ride then
    for k, t in ipairs(list) do if t.kind == "vessel" and t.v.node.id == ride.node.id then i = k end end
  end
  local j = ((i - 1 + dir) % #list) + 1
  local t = list[j]
  local ok, why = switchTo(t)
  if not ok then return nil, why end
  if t.kind == "crew" then return t.name .. " · on foot" end
  if (t.crew or 0) > 0 then return string.format("%s · %d aboard", t.name, t.crew) end
  return t.name .. " · " .. (t.can and "remote" or ("no control — " .. tostring(t.why or ""))):lower()
end

-- ── the queued switches (run in fixedUpdate) ───────────────────────────────
local hold_imp = 0       -- the impact monitor waits after a teleport
-- (a switch: half a second; a set-down at the base, `secs`: the crew's
-- home is a couple of metres over the ground and the drop is not a fall)
local function quiet_monitors(secs) hold_imp = math.max(hold_imp, now() + (secs or 0.5)) end
-- Teleports (the walker's ground net and field floor) say so: the snap is no fall.
function quietMonitors(secs) quiet_monitors(secs) end

local function do_control(q)
  local id = q.id
  local b = bodies[id]
  local a = astro()
  if not (b and b.valid ~= false and a) then return end
  local bx, by, bz = b.x, b.y, b.z
  local bvx, bvy, bvz = 0, 0, 0
  local cb = b.getScript and b:getScript("crew_body") or nil
  if cb and cb.velocityNow then bvx, bvy, bvz = cb.velocityNow() end
  -- standing on a planet: where the record says, this tick (the body node
  -- was written a tick ago, a rails carry behind)
  local r0 = get(id)
  if r0 and not r0.anchor then
    local wx, wy, wz = world_of(r0)
    if wx then bx, by, bz = wx, wy, wz end
  end
  free_avatar(nil)
  despawn_body(id)
  a.x, a.y, a.z = bx, by, bz
  a.vx, a.vy, a.vz = bvx, bvy, bvz
  a.visible = true
  set_active(id)
  patch(id, { status = "afoot", craft = false, anchor = false })
  suit_in(id)
  quiet_monitors()
  local r = get(id)
  caption((r and r.name or "crew") .. " · on foot")
  log_(string.format("crew: control → %s (#%d) on foot", r and r.name or "?", id))
end

local function do_craft(q)
  local v = vessel_by_id(q.nid)
  if not (v and v.avatarBoard) then
    -- an older controller: fly it as before
    if v and v.takeControl then v.takeControl() end
    return
  end
  local id = q.id
  local old = activeId()
  local ride = avatarCraft()
  if ride and ride.node.id == v.node.id and old == id then
    if not v.piloting and v.remoteControl then v.remoteControl() end
    return
  end
  free_avatar(v)
  set_active(id)
  v.avatarBoard(id)
  patch(id, { status = "aboard", craft = v.craftName or false })
  suit_in(id)
  quiet_monitors()
  dollSync(true)
  local r = get(id)
  caption(string.format("%s · %s", v.craftName or "craft", r and r.name or "crew"))
  log_(string.format("crew: control → %s (#%d) aboard %s", r and r.name or "?", id, tostring(v.craftName)))
end

local function do_eva(q)
  local v = vessel_by_id(q.nid)
  if not v then return end
  local id = q.id
  if q.stay then
    -- out as a CrewBody beside the hatch; you keep the craft
    local x, y, z = nil, nil, nil
    if v.hatchSpot then x, y, z = v.hatchSpot(q.uid) end
    if not x then return end
    v.seatMember(q.uid, select(2, v.memberSlot(id)), nil)
    local d, rx, ry, rz = rel(x, y, z)
    -- off the ground: they wait beside the craft, in its part frame
    local anchor = false
    local st = v.evaState and v.evaState() or nil
    if st and not st.surface and v.partLocalNow then
      local lx, ly, lz = v.partLocalNow(q.uid, x, y, z)
      if lx then anchor = { vid = v.node.id, uid = q.uid, x = lx, y = ly, z = lz } end
    end
    patch(id, { status = "afoot", craft = false, body = d, x = rx, y = ry, z = rz, anchor = anchor, face = false })
    spawn_body(id, x, y, z)
    dollSync(true)
    log_(string.format("crew: #%d steps out of %s and waits by the hatch", id, tostring(v.craftName)))
    return
  end
  local old = activeId()
  local ride = avatarCraft()
  if not (ride and ride.node.id == v.node.id) then
    -- the avatar is elsewhere: it comes to this craft first
    free_avatar(v)
    v.avatarBoard(id)
  elseif old ~= id then
    suit_out(old)
  end
  set_active(id)
  suit_in(id)
  if v.setStationOf then v.setStationOf(id) end
  if v.evaNow then v.evaNow(true) end
  quiet_monitors()
  dollSync(true)
end

local function run_queue()
  if #queue == 0 then return end
  local q = table.remove(queue, 1)
  if q.kind == "control" then do_control(q)
  elseif q.kind == "craft" then do_craft(q)
  elseif q.kind == "eva" then do_eva(q) end
end

-- ── status bookkeeping the controller calls ────────────────────────────────
function noteAboard(id, craft)
  patch(id, { status = "aboard", craft = craft or false, body = false, x = false, y = false, z = false })
end
function noteAfoot(id)
  local a = astro()
  local f = { status = "afoot", craft = false }
  if a and space and space.dominant then
    local d = space.dominant(a.x, a.y, a.z)
    local b = d and space.body(d)
    if b then f.body, f.x, f.y, f.z = d, a.x - b.x, a.y - b.y, a.z - b.z end
  end
  patch(id, f)
end
-- A craft came home (recovered): everyone in it goes back to base.
function noteHome(id)
  local r = get(id)
  if r and r.status ~= "dead" then
    patch(id, { status = "base", craft = false, body = false, x = false, y = false, z = false,
                flights = (r.flights or 0) + 1 })
  end
end

-- A member set down on foot at a world point (a wreck they walked away
-- from): a CrewBody there, the record on foot.
function setDown(id, x, y, z)
  local r = get(id)
  if not (r and r.status ~= "dead") then return false end
  if id == activeId() and not avatarCraft() then return false end
  local d, rx, ry, rz = rel(x, y, z)
  patch(id, { status = "afoot", craft = false, body = d, x = rx, y = ry, z = rz })
  despawn_doll(id)
  spawn_body(id, x, y, z)
  return true
end

-- The launch seats a commander who isn't the avatar's member: the avatar
-- flies as them, and the member it was goes back into the building.
function launchAs(id, craft)
  local old = activeId()
  if old == id then return end
  if old then
    suit_out(old)
    local r = get(old)
    -- (seated in this craft too: they stay aboard as a doll)
    local seated = false
    for _, v in ipairs(vessels()) do
      for _, s in ipairs(seats_of(v)) do if s.taken == old then seated = true end end
    end
    if r and r.status ~= "dead" and not seated then
      patch(old, { status = "base", craft = false, body = false, x = false, y = false, z = false })
    end
  end
  set_active(id)
  noteAboard(id, craft)
  suit_in(id)
  quiet_monitors()
end

-- ── tasks (§6.3) ───────────────────────────────────────────────────────────
-- `task` is plain data (saved on the record); crew_task.lua runs it.
function task(id)
  local r = get(id)
  return r and r.task or nil
end

function setTask(id, t)
  local r = get(id)
  if not r then return false, "no such crew member" end
  if r.status == "dead" then return false, "dead" end
  if type(t) ~= "table" or type(t.kind) ~= "string" then return false, "not a task" end
  if r.task then return false, "busy: " .. tostring(r.task.kind) end
  local ct = ref("crew_task")
  if ct and ct.validate then
    local ok, why = ct.validate(id, t)
    if not ok then return false, why end
  end
  r.task = t
  put(r)
  if ct and ct.attach then
    local ok, why = ct.attach(id)
    if not ok then
      r.task = nil
      put(r)
      return false, why
    end
  end
  return true, nil
end

-- Explicit cancel (the menu's "Cancel repair"), or a forced stop with its
-- reason. Progress is kept on the part (crew_task).
function cancelTask(id, why)
  local r = get(id)
  if not (r and r.task) then return false end
  local ct = ref("crew_task")
  if ct and ct.release then ct.release(id, why or "cancelled") end
  r = get(id)
  if r and r.task then
    r.task = nil
    put(r)
  end
  return true
end

function held(id)
  if TREAT and TREAT.by == (id or activeId()) then return true end
  local ct = ref("crew_task")
  if ct and ct.isHeld then return ct.isHeld(id or activeId()) == true end
  return false
end

-- ── air (§2.3, §5.8) ───────────────────────────────────────────────────────
-- Two reserves keep a crew member breathing on foot:
--   held breath  bare-headed under water (planet_walker's 60 s meter,
--                drained `breath_hold` × faster per suit.lua);
--   suit air     the suit's built-in supply (SUIT_AIR_SECS) PLUS every
--                Oxygen Tank in the pack (items.o2Reserve/drawO2, WS3).
--                Used with the helmet on wherever the air outside can't be
--                breathed: vacuum, poison, thin air, and under water.
-- With the helmet on in breathable air the suit vents the air outside (no
-- drain): 20 minutes is an EVA budget, not a clock on the home meadow.
SUIT_AIR_SECS = 1200

-- What the crew breathes now: "suit" | "hold" | "ambient".
function airSource(helmet, headUnder, breathable)
  if headUnder then return helmet and "suit" or "hold" end
  if helmet and not breathable then return "suit" end
  return "ambient"
end

-- The tanks in `pack` (a container id) through items.lua; with no items
-- library (a harness, or before WS3) there are none and this is today's
-- suit. → reserve(): seconds, draw(secs): seconds drawn, refill(): seconds
function tanksOf(pack)
  local I = ref("items")
  local has = I and I.o2Reserve and I.drawO2
  return {
    reserve = function()
      if not has then return 0 end
      local ok, t = pcall(I.o2Reserve, pack)
      return ok and (t or 0) or 0
    end,
    draw = function(secs)
      if not has or secs <= 0 then return 0 end
      local ok, got = pcall(I.drawO2, pack, secs)
      return ok and math.max(0, math.min(secs, got or 0)) or 0
    end,
    refill = function()
      if not (I and I.refillO2) then return 0 end
      local ok, n = pcall(I.refillO2, pack)
      return ok and (n or 0) or 0
    end,
  }
end

-- Breathe `dt` seconds of suit air: from the tanks first (WS3's order), the
-- rest from the built-in supply `o2` (0..1 of SUIT_AIR_SECS). → new o2,
-- seconds left in all (built-in + tanks).
function drawAir(o2, dt, tanks)
  local secs = SUIT_AIR_SECS
  local got = tanks and tanks.draw(dt) or 0
  local rest = dt - got
  if rest > 0 then o2 = math.max(0, (o2 or 1) - rest / secs) end
  local left = (o2 or 0) * secs + (tanks and tanks.reserve() or 0)
  return o2, left
end

-- ── the death monitor's live state (the avatar on foot) ────────────────────
local MON = { vx = nil, vy = nil, vz = nil, x = nil, y = nil, z = nil, dom = nil, bx = nil, by = nil, bz = nil,
              fall = 0, pinned = false, crush_t = 0, injured_t = -10, dying = nil }

-- ── warnings as state (§2.3; WS2 draws them) ───────────────────────────────
function alerts(id)
  id = id or activeId()
  local r = get(id) or {}
  local is_avatar = id == activeId()
  local pw = is_avatar and ref("planet_walker") or nil
  local breath = (pw and pw.breath) or 1.0
  -- o2: the suit's air in all, built-in + tanks, as a share of their capacity
  local o2 = r.o2 or 1.0
  local air_s = nil
  if pw and pw.airLeft and pw.airCap and pw.airCap > 0 then o2, air_s = pw.airLeft / pw.airCap, pw.airLeft end
  local cabin, tol = nil, nil
  local v, uid = craftOf(id)
  if v and uid and v.partHp then
    local ok, hp = pcall(v.partHp, uid)
    if ok and hp then cabin, tol = hp, P("cabin_tol") end
  end
  local blackout = nil
  if pw and pw.downed then blackout = pw.downLeft or 1.0 end
  if MON.dying and MON.dying.id == id then blackout = math.max(0, MON.dying.t1 - now()) end
  local lh = lastHit and lastHit[id]
  local hit = (lh and now() - lh.t < (HIT_SHOW or 1.6)) and lh or nil
  if invincible() then
    -- nothing can hurt them, so nothing to warn of: the chips stay quiet
    -- (the walker's own air gauge still shows the suit running down)
    return { o2 = 1.0, air_s = nil, breath = 1.0, hp = r.hp or 1.0, heat = 0.0, hit = nil, fall = 0.0,
             pinned = false, blackout = nil, cabin = nil, cabin_tol = nil, o2_level = nil, breath_level = nil,
             safe = true }
  end
  -- DOWN: this member's own bleed-out, and the nearest other member down
  -- within 600 m (the HUD's "<NAME> DOWN · 74 s" chip)
  local own = r.downed and (r.downed.left or 0) or nil
  local near = nil
  if is_avatar and down_monitor then
    for _, d in ipairs(downedList()) do
      if d.id ~= id and d.dist and d.dist < 600 then near = d break end
    end
  end
  return { o2 = o2, air_s = air_s, breath = breath, hp = r.hp or 1.0, heat = r.heat or 0.0, hit = hit,
           downed = own, down = near,
           fall = is_avatar and MON.fall or 0.0, pinned = is_avatar and MON.pinned or false,
           blackout = blackout, cabin = cabin, cabin_tol = tol,
           o2_level = airLevel(o2, air_s), breath_level = (breath < 1) and airLevel(breath, nil) or nil }
end

-- ── death (§2.3) ───────────────────────────────────────────────────────────
-- Ground under a world point (for remains): a ray down the local vertical.
local function ground_under(d, x, y, z)
  local b = space and space.body and space.body(d)
  if not (b and raycast) then return x, y, z end
  local ux, uy, uz = x - b.x, y - b.y, z - b.z
  local l = len(ux, uy, uz)
  if l < 1e-6 then return x, y, z end
  ux, uy, uz = ux / l, uy / l, uz / l
  local a = astro()
  local ok, h = pcall(raycast, x + ux * 0.5, y + uy * 0.5, z + uz * 0.5, -ux, -uy, -uz, 60, a)
  if ok and h and h.x then return h.x, h.y, h.z end
  return x, y, z
end

-- Where member `id` is in the world now (avatar, body, doll or record).
local function world_pos(id)
  if id == activeId() then
    local ride = avatarCraft()
    local a = astro()
    if a and not ride then return a.x, a.y, a.z end
  end
  local b = bodies[id]
  if b and b.valid ~= false then return b.x, b.y, b.z end
  local d = dolls[id]
  if d and d.node and d.node.valid ~= false then return d.node.x, d.node.y, d.node.z end
  local v = craftOf(id)
  if v and v.node then return v.node.x, v.node.y, v.node.z end
  return world_of(get(id))
end

-- The pack drops as a salvage crate, the remains stay where they fell.
local function leave_behind(id, r, x, y, z, ignore)
  local d = space and space.dominant and space.dominant(x, y, z)
  local crate, rem = nil, nil
  local sv = ref("salvage")
  if sv and sv.drop and d then
    local ok, cid = pcall(sv.drop, d, x, y, z, ignore, { from = packOf(id), items = true,
      label = (r.name or "crew") .. "'s pack" })
    if ok then crate = cid end
  end
  local dep = ref("deployables")
  if not dep and spawn and find and not find("DeployLib") then pcall(spawn, "DeployLib", vec3(0, 0, 0)) end
  if dep and dep.place and d then
    local gx, gy, gz = ground_under(d, x, y, z)
    local ok, rid = pcall(dep.place, "remains", d, gx, gy, gz, { by = id, name = r.name })
    if ok then rem = rid end
  end
  return crate, rem, d
end

CAUSE_TEXT = {
  impact = "impact", cabin = "the cabin failed", oxygen = "out of oxygen", drowned = "drowned",
  crushed = "crushed", heat = "burned on re-entry", lost = "lost with the craft", shot = "shot",
  explosion = "caught in an explosion",
}

-- The control handoff when the controlled member is gone.
local function handoff(dead_id, from_v)
  local a = astro()
  local ax, ay, az = a and a.x, a and a.y, a and a.z
  local onfoot = {}
  for id, b in pairs(bodies) do
    local r = get(id)
    if r and r.status == "afoot" and not r.downed and b.valid ~= false and id ~= dead_id then
      local d = ax and len(b.x - ax, b.y - ay, b.z - az) or 0
      if d <= P("body_range") then onfoot[#onfoot + 1] = { id = id, dist = d } end
    end
  end
  local craft = nil
  if from_v and from_v.node and from_v.node.valid ~= false and #aboard(from_v) > 0 then craft = from_v end
  local crafts = {}
  for _, v in ipairs(vessels()) do
    if v.node and v.node.valid ~= false and #aboard(v) > 0 then
      crafts[#crafts + 1] = { v = v, dist = ax and len(v.node.x - ax, v.node.y - ay, v.node.z - az) or 0 }
    end
  end
  local base = {}
  for _, r in ipairs(roster()) do if r.status == "base" then base[#base + 1] = r.id end end
  local kind, what = handoffPick(onfoot, craft, crafts, base)
  if kind == "crew" then
    queue[#queue + 1] = { kind = "control", id = what }
    return
  end
  if kind == "craft" then
    queue[#queue + 1] = { kind = "craft", nid = what.node.id, id = aboard(what)[1].id }
    return
  end
  local id = what
  if kind == "newbie" then
    id = hire(1, { free = true })
    local r = get(id)
    local bc = ref("big_caption")
    if bc and bc.show and r then bc.show("A NEW VOLUNTEER", "The agency has a new volunteer: " .. r.name, 6.0) end
  end
  if not id then return end
  -- out of the Command Centre as the avatar
  local fo = ref("flight_ops")
  local hx, hy, hz = nil, nil, nil
  if fo and fo.crewHome then hx, hy, hz = fo.crewHome() end
  set_active(id)
  if a and hx then
    a.x, a.y, a.z = hx, hy, hz
    a.vx, a.vy, a.vz = 0, 0, 0
  end
  if a then a.visible = true end
  noteAfoot(id)
  suit_in(id)
  quiet_monitors(2.5)
  local r = get(id)
  caption((r and r.name or "crew") .. " walks out of the Command Centre")
end

-- Rescue instead (death off): blacked out, they wake at base for the fee.
local function rescue(id, cause, free)
  local r = get(id)
  local is_avatar = id == activeId() and not avatarCraft()
  local co = ref("company")
  local fo = ref("flight_ops")
  local fee = free and 0 or 250
  if co and co.afford and co.afford(fee) and co.spend then co.spend(fee, "crew rescue") end
  local v, uid, slot = craftOf(id)
  if v and v.seatMember then v.seatMember(uid, slot, nil) end
  despawn_body(id)
  despawn_doll(id)
  patch(id, { hp = 1.0, heat = 0, o2 = 1.0 })
  if is_avatar then
    local a = astro()
    local hx, hy, hz = nil, nil, nil
    if fo and fo.crewHome then hx, hy, hz = fo.crewHome() end
    if a and hx then a.x, a.y, a.z = hx, hy, hz; a.vx, a.vy, a.vz = 0, 0, 0; a.visible = true end
    noteAfoot(id)
    quiet_monitors(2.5)
  else
    patch(id, { status = "base", craft = false, body = false, x = false, y = false, z = false })
  end
  local bc = ref("big_caption")
  if bc and bc.show and r then bc.show("CREW RESCUED", string.format("%s blacked out (%s). The agency brought them back to the base.",
    r.name, CAUSE_TEXT[cause] or cause), 6.0) end
  log_(string.format("crew: #%d rescued (%s)", id, tostring(cause)))
  return true
end

-- Invincible, and their cabin broke up round them: out of the seat and set
-- down on foot beside the wreck (the avatar's own stand-down is the
-- controller's), or home for nothing when there is no wreck point.
local function walk_away(id, cause, opts)
  local v, uid, slot = craftOf(id)
  if v and v.seatMember and uid then v.seatMember(uid, slot, nil) end
  for _, w in ipairs(vessels()) do if w.unseatMember then pcall(w.unseatMember, id) end end
  despawn_doll(id)
  if opts.x and id ~= activeId() and setDown(id, opts.x, opts.y, opts.z) then
    log_(string.format("crew: #%d walked away from the wreck (invincible)", id))
    bump()
    return true
  end
  return rescue(id, cause, true)
end

-- KILL member `id` (death on), or rescue them (death off); invincible, nothing
-- happens (a lost cabin sets them down beside the wreck). `detail` is the
-- caption's figure ("17 m/s"). Returns true when something happened.
function kill(id, cause, detail, opts)
  opts = opts or {}
  local r = get(id)
  if not r or r.status == "dead" then return false end
  if invincible() then
    if cause == "cabin" then return walk_away(id, cause, opts) end
    return false
  end
  if not deathOn() then return rescue(id, cause) end
  if opts.over and not r.downed and not craftOf(id) and downRule(cause, opts.over) then
    return go_down(id, cause, detail, opts)
  end
  if TREAT and (TREAT.target == id or TREAT.by == id) then cancel_treat(id == TREAT.target and "they died" or "you died") end
  if r.downed then r.downed = nil; put(r) end
  local ride = avatarCraft()
  local is_avatar = id == activeId()
  local v, uid, slot = craftOf(id)
  local x, y, z = opts.x, opts.y, opts.z
  if not x then x, y, z = world_pos(id) end
  if is_avatar and not ride then suit_out(id) end
  -- out of their seat (a doll; any stale seat elsewhere too), off their feet (a body)
  if v and v.seatMember and uid then v.seatMember(uid, slot, nil) end
  for _, w in ipairs(vessels()) do if w.unseatMember then pcall(w.unseatMember, id) end end
  despawn_body(id)
  despawn_doll(id)
  local crate, rem, d = nil, nil, nil
  if x then crate, rem, d = leave_behind(id, r, x, y, z, astro()) end
  local st = (space and space.time and space.time()) or 0
  local dep = ref("deployables")
  local date = dep and dep.dateOf and dep.dateOf(st) or nil
  r = get(id)
  r.status = "dead"
  r.task = nil
  r.died = { st = st, date = date, cause = cause, detail = detail, body = d,
             craft = (v and v.craftName) or opts.craft, remains = rem, crate = crate, bled = opts.bled or nil }
  if d and x then
    local b = space.body(d)
    if b then r.died.x, r.died.y, r.died.z = x - b.x, y - b.y, z - b.z end
  end
  put(r)
  local co = ref("company")
  if co and co.addRep then pcall(co.addRep, -2, "astronaut lost: " .. r.name) end
  -- (a detail that names who did it reads on: "shot by Dana Okafor, 30 m")
  local text = string.format("%s was killed: %s%s", r.name, CAUSE_TEXT[cause] or cause,
    detail and ((tostring(detail):sub(1, 3) == "by " and " " or ", ") .. detail) or "")
  lastDeath = { id = id, name = r.name, cause = cause, text = text, t = now(), x = x, y = y, z = z }
  local bc = ref("big_caption")
  if bc and bc.show then bc.show("ASTRONAUT LOST", text, 6.0) end
  log_("crew: " .. text)
  -- the controlled one: the camera holds 2 s, then control passes on
  if is_avatar then
    local a = astro()
    if ride then
      if ride.releaseControl then pcall(ride.releaseControl) end
      if ride.crewLeave then pcall(ride.crewLeave) end
    end
    if a then
      a.visible = false
      a.vx, a.vy, a.vz = 0, 0, 0
    end
    local rd, rx, ry, rz = nil, nil, nil, nil
    if x then rd, rx, ry, rz = rel(x, y, z) end
    MON.dying = { id = id, t1 = now() + P("hold_secs"), v = v, d = rd, x = rx, y = ry, z = rz }
  end
  bump()
  return true
end

-- planet_walker asks at the end of its blackout grace (src "suit" | "hold"):
-- true = handled here (death), false = do today's rescue.
function blackoutEnd(src)
  if not deathOn() then return false end
  local id = activeId()
  if not id then return false end
  return kill(id, src == "hold" and "drowned" or "oxygen")
end

-- A crewed part broke (vessel_controller): its occupants die (death on) or
-- are rescued. `x,y,z` the wreck point.
function cabinLost(v, uid, ids_, x, y, z)
  for _, id in ipairs(ids_ or {}) do
    kill(id, "cabin", nil, { x = x, y = y, z = z, craft = v and v.craftName })
  end
end

-- ── wounds from outside (a weapon; later an animal) ───────────────────────
-- HURT member `id`: hp down by `amount` (a share of a healthy body, 0..1),
-- the HIT alert for a moment (alerts().hit: the HUD's chip and its flash),
-- and at 0 the death with `cause` and `detail` (the memorial reads "Shot (by
-- Dana Okafor, 150 m)") — or, with death off, the rescue (kill's rule). Only
-- someone out in the world can be hurt: on foot, or in an open seat. A
-- record at base, or a member inside a closed cabin (the hull takes the
-- hit), is out of reach. `opts`: by (a name, for the record), x,y,z (where
-- it happened: the remains go there). → the new hp (0: dead or rescued), or
-- nil and why.
lastHit = {}
HIT_SHOW = 1.6
function hurt(id, amount, cause, detail, opts)
  opts = opts or {}
  local r = get(id)
  if not r or r.status == "dead" then return nil, "nobody to hurt" end
  if r.status == "base" then return nil, "at the base" end
  if invincible() then return r.hp or 1, "invincible" end
  amount = math.max(0, amount or 0)
  local hp = math.max(0, (r.hp or 1) - amount)
  lastHit[id] = { t = now(), amount = amount, cause = cause or "shot", by = opts.by, hp = hp }
  log_(string.format("crew: #%d hit (%s%s): -%.2f, hp %.2f", id, tostring(cause or "shot"),
    detail and (", " .. detail) or "", amount, hp))
  bump()
  if hp <= 1e-6 then
    local o = {}
    for k, v in pairs(opts) do o[k] = v end
    o.over = amount - (r.hp or 1)
    kill(id, cause or "shot", detail, o)
    return 0
  end
  patch(id, { hp = hp })
  return hp
end

-- ── DOWNED: bleeding out on the ground (Permadeath) ────────────────────────
-- Pure: does a lethal wound leave them down rather than dead? `over` is how
-- far past lethal it was: an impact's Δv ÷ impact_kill (1.0 = just lethal),
-- a shot's hp past zero. Only those two causes: a fall or a bolt is a wound a
-- medic can work on; a crush, a lost cabin, re-entry heat or an explosion is
-- not, and out of air the blackout's own grace already is the timer (a Medkit
-- can't give them air).
function downRule(cause, over)
  if cause == "impact" then return (over or 99) < P("down_over") end
  if cause == "shot" then return (over or 99) < P("shot_over") end
  return false
end
-- Pure: the bleed-out time, shorter the worse the wound.
function bleedSecs(cause, over)
  local f = 0
  if cause == "impact" then f = ((over or 1) - 1) / math.max(0.01, P("down_over") - 1)
  elseif cause == "shot" then f = (over or 0) / math.max(0.01, P("shot_over")) end
  f = math.max(0, math.min(1, f))
  return P("bleed_secs") - (P("bleed_secs") - P("bleed_min")) * f
end

lastDown = nil
TREAT = nil
lastTreat = nil

go_down = function(id, cause, detail, opts)
  local r = get(id)
  local secs = bleedSecs(cause, opts.over)
  local is_avatar = id == activeId() and not avatarCraft()
  if r.task then cancelTask(id, "down") end
  if TREAT and TREAT.by == id then cancel_treat("you went down") end
  patch(id, { hp = 0, downed = { left = secs, secs = secs, cause = cause, detail = detail, by = opts.by } })
  r = get(id)
  lastDown = { id = id, name = r.name, cause = cause, secs = secs, t = now() }
  local bc = ref("big_caption")
  if bc and bc.show then
    bc.show("ASTRONAUT DOWN", string.format("%s is down (%s%s) and bleeding out: %d s. A Medkit can save them.",
      r.name, CAUSE_TEXT[cause] or cause, detail and (", " .. detail) or "", math.floor(secs + 0.5)), 6.0)
  end
  log_(string.format("crew: #%d DOWN (%s, %s): %.0f s to bleed out", id, tostring(cause), tostring(detail), secs))
  if is_avatar then
    -- they lie where they fell (a CrewBody); control passes on as at a death
    park_avatar_member(id)
    local a = astro()
    if a then a.visible = false; a.vx, a.vy, a.vz = 0, 0, 0 end
    handoff(id, nil)
    quiet_monitors(2.5)
  end
  bump()
  return true
end

-- The downed, nearest the avatar first (the HUD's chip, the strip).
function downedList()
  local out = {}
  local a = astro()
  for _, r in ipairs(roster()) do
    if r.downed and r.status ~= "dead" then
      local x, y, z = world_pos(r.id)
      local d = (a and x) and len(x - a.x, y - a.y, z - a.z) or nil
      out[#out + 1] = { id = r.id, name = r.name, left = r.downed.left or 0, secs = r.downed.secs, dist = d,
                        treated = TREAT ~= nil and TREAT.target == r.id }
    end
  end
  table.sort(out, function(p, q) return (p.dist or 1e18) < (q.dist or 1e18) end)
  return out
end

local down_t = 0
down_monitor = function(dt)
  down_t = down_t + dt
  if down_t < 0.25 then return end
  local step_ = down_t
  down_t = 0
  for _, r in ipairs(roster()) do
    local dn = r.downed
    if dn and r.status ~= "dead" then
      if r.id == activeId() and not avatarCraft() and #queue == 0 and not MON.dying then
        -- (a save loaded with the avatar's member down: lie down, pass on)
        park_avatar_member(r.id)
        handoff(r.id, nil)
      end
      if not (TREAT and TREAT.target == r.id) then
        dn.left = (dn.left or 0) - step_
        if dn.left <= 0 then
          local how = dn.cause == "impact" and "after a fall" or (dn.cause == "shot" and "after a shot" or "")
          local det = "bled out " .. how .. (dn.detail and ((tostring(dn.detail):sub(1, 3) == "by " and " " or ", ") .. dn.detail) or "")
          r.downed = nil
          put(r)
          kill(r.id, dn.cause, det, { by = dn.by, bled = true })
        else
          put(r)
        end
      end
    end
  end
end

-- ── THE MEDKIT: treating the injured and the downed ───────────────────────
-- The member you control, on foot, a Medkit in hand, within reach of someone
-- injured or down (or hurt themselves): held at the work (the walker stands
-- down, as at a repair) for the kit's time; the bleed-out clock stops while
-- they work. Done: one Medkit used, a heal of +MEDKIT.heal hp, or a revive to
-- MEDKIT.revive_hp. Walking off, the patient dying, or Cancel stops it (the
-- kit is kept).
local function medkit_rules()
  local I = ref("items")
  return (I and I.MEDKIT) or { heal = 0.5, heal_secs = 4.0, revive_hp = 0.25, revive_secs = 6.0, reach = 2.6 }
end
local function kit_count(id)
  local inv = ref("inventory")
  if not (inv and inv.itemCount) then return 0 end
  local ok, n = pcall(inv.itemCount, packOf(id), "medkit")
  return ok and n or 0
end
-- (asked in the FRAME — treat_tick runs in update — where the avatar and
-- the body nodes are both as drawn: in a physics tick they read a rails
-- carry apart, metres on a moving planet)
local function dist_to(by, target)
  if by == target then return 0 end
  local a = astro()
  local x, y, z = world_pos(target)
  if not (a and x) then return nil end
  return len(x - a.x, y - a.y, z - a.z)
end

function treatWhyNot(target)
  local by = activeId()
  local r = get(target)
  if not (by and r) then return "nobody there" end
  if r.status == "dead" then return r.name .. " is dead — a Medkit can't help" end
  if r.status ~= "afoot" then return "only someone on foot" end
  if not r.downed and (r.hp or 1) >= 0.995 then return r.name .. " isn't hurt" end
  if avatarCraft() then return "step out first" end
  local pw = ref("planet_walker")
  if pw and pw.onFoot == false then return "on foot only" end
  if TREAT then return "already treating someone" end
  if kit_count(by) < 1 then return "needs a Medkit — the depot sells them" end
  local H = ref("item_hand")
  if H and H.held and H.held() ~= "medkit" then return "hold the Medkit" end
  local d = dist_to(by, target)
  if not d then return "out of range" end
  if d > medkit_rules().reach then return string.format("walk up to them (%.0f m away)", d) end
  return nil
end

function treat(target)
  local why = treatWhyNot(target)
  if why then return false, why end
  local M = medkit_rules()
  local r = get(target)
  local revive = r.downed and true or false
  TREAT = { by = activeId(), target = target, kind = revive and "revive" or "heal",
            secs = revive and M.revive_secs or M.heal_secs, done = 0, t0 = now() }
  caption(string.format("%s %s — right-click → Cancel", revive and "REVIVING" or "TREATING", r.name))
  log_(string.format("crew: #%d treats #%d (%s, %.0f s)", TREAT.by, target, TREAT.kind, TREAT.secs))
  bump()
  return true
end

cancel_treat = function(why)
  if not TREAT then return false end
  lastTreat = { by = TREAT.by, target = TREAT.target, kind = TREAT.kind, done = false, why = why or "cancelled", t = now() }
  log_(string.format("crew: treatment of #%d stopped (%s)", TREAT.target, tostring(why)))
  TREAT = nil
  bump()
  return true
end
function cancelTreat(why) return cancel_treat(why or "cancelled") end

function treating()
  if not TREAT then return nil end
  local t = {}
  for k, v in pairs(TREAT) do t[k] = v end
  t.frac = math.min(1, TREAT.done / math.max(0.1, TREAT.secs))
  return t
end

treat_tick = function(dt)
  local T = TREAT
  if not T then return end
  local r = get(T.target)
  if not r or r.status == "dead" then return cancel_treat("they died") end
  if activeId() ~= T.by or avatarCraft() then return cancel_treat("control changed") end
  local d = dist_to(T.by, T.target)
  if not d or d > medkit_rules().reach + 1.0 then
    log_(string.format("crew: the medic is %s m from #%d", d and string.format("%.1f", d) or "?", T.target))
    return cancel_treat("walked away")
  end
  if kit_count(T.by) < 1 then return cancel_treat("the Medkit is gone") end
  T.done = T.done + dt
  if T.done < T.secs then return end
  local inv = ref("inventory")
  if inv and inv.removeItem then pcall(inv.removeItem, packOf(T.by), "medkit", 1) end
  local M = medkit_rules()
  local hp
  if T.kind == "revive" then
    hp = M.revive_hp
    patch(T.target, { downed = false, hp = hp })
  else
    hp = math.min(1, (r.hp or 1) + M.heal)
    patch(T.target, { hp = hp })
  end
  lastTreat = { by = T.by, target = T.target, kind = T.kind, done = true, hp = hp, t = now() }
  TREAT = nil
  local bc = ref("big_caption")
  if T.kind == "revive" and bc and bc.show then
    bc.show("ASTRONAUT REVIVED", string.format("%s is back on their feet (%d%%). Get them home to heal.", r.name, math.floor(hp * 100 + 0.5)), 5.0)
  else
    caption(string.format("%s treated — %d%%", r.name, math.floor(hp * 100 + 0.5)))
  end
  log_(string.format("crew: #%d %s by #%d, hp %.2f", T.target, T.kind == "revive" and "revived" or "healed", T.by, hp))
  bump()
end

-- ── the monitor: impact, crush, heat (the avatar on foot; heat aboard) ─────
local function avatar_monitor(dt)
  local a = astro()
  local id = activeId()
  if not (a and id) then return end
  local ride = avatarCraft()
  if MON.dying then
    -- the hold on the fallen: the avatar waits hidden where they fell
    local m = MON.dying
    if m.d and space and space.body then
      local b = space.body(m.d)
      if b then a.x, a.y, a.z = b.x + m.x, b.y + m.y, b.z + m.z; a.vx, a.vy, a.vz = 0, 0, 0 end
    end
    if now() >= m.t1 then
      MON.dying = nil
      -- (the suit's parts come back; the walker re-shows the root)
      for _, ch in ipairs(MON.hid or {}) do if ch.valid ~= false then ch.visible = true end end
      MON.hid = nil
      handoff(m.id, m.v)
    end
    return
  end
  -- not while the world loads (the avatar is put where the save says, a
  -- craft is rebuilt around it), nor for 3 s after the reveal
  local gm = ref("game_manager")
  if gm and (gm.loading or gm.curtain) then quiet_monitors(3.0) end
  -- out of a hatch or a seat (EVA, a recovery, END FLIGHT): the step down
  -- from a pod on the pad is not a fall
  if MON.rode and not ride then quiet_monitors(1.5) end
  MON.rode = ride ~= nil
  if ride or now() < hold_imp or held(id) then
    MON.vx = nil
    MON.fall, MON.pinned, MON.crush_t = 0, false, 0
    MON.air, MON.peak = 0, 0
    return
  end
  local vx, vy, vz = a.vx or 0, a.vy or 0, a.vz or 0
  local d = space and space.dominant and space.dominant(a.x, a.y, a.z) or nil
  local b = d and space.body(d)
  -- (velocities are in the planet's rails frame: the ground is at rest)
  local gvx, gvy, gvz = 0, 0, 0
  local jumped = MON.x and len(a.x - MON.x, a.y - MON.y, a.z - MON.z) > math.max(30, len(vx, vy, vz) * dt * 4 + 10)
  -- a teleport (a switch, a pickup, a probe) is no part of a fall: the
  -- airborne peak starts again from here
  if jumped then MON.air, MON.peak = 0, 0 end
  if MON.vx and MON.dom == d and not jumped then
    -- Δv this tick: all of it along the vertical (a fall, a landing), and
    -- sideways only past what the walker itself does in a tick (a run
    -- stopped dead is 9.4 m/s and hurts nobody; a rover at 25 m/s does)
    -- A FALL is judged when it ends: the fastest the body fell while it was
    -- off the ground (at least 0.2 s of it), taken away by the landing. Tick-to-tick wobble while walking (steps,
    -- slopes, the capsule riding bumpy voxels, the ground pushing back after
    -- a dig) is never a fall: it bled hp from crew who were only walking.
    -- Sideways, only a crash counts: speed lost past what a run stopped dead
    -- makes (a rover's crew thrown off), which a walker never reaches.
    local pw = ref("planet_walker")
    local on_ground = pw and (pw.grounded or pw.onGround) or false
    local dv = 0
    if b then
      local ux, uy, uz = a.x - b.x, a.y - b.y, a.z - b.z
      local l = len(ux, uy, uz)
      if l > 1e-6 then
        ux, uy, uz = ux / l, uy / l, uz / l
        local r0 = MON.vx * ux + MON.vy * uy + MON.vz * uz
        local r1 = vx * ux + vy * uy + vz * uz
        local down = 0
        if not on_ground then
          MON.air = (MON.air or 0) + dt
          MON.peak = math.max(MON.peak or 0, -r1)
        else
          -- (the touchdown tick still carries the fall: the ground stops it
          -- after, so the whole fall speed is what the landing takes away)
          if (MON.air or 0) >= 0.2 then down = math.max(0, MON.peak or 0, -r1) end
          MON.air, MON.peak = 0, 0
        end
        local h0x, h0y, h0z = MON.vx - ux * r0, MON.vy - uy * r0, MON.vz - uz * r0
        local h1x, h1y, h1z = vx - ux * r1, vy - uy * r1, vz - uz * r1
        local side = math.max(0, len(h0x, h0y, h0z) - len(h1x, h1y, h1z) - P("walk_dv"))
        dv = math.sqrt(down * down + side * side)
      end
    end
    local verdict, loss = impactRule(dv)
    if verdict ~= "ok" and invincible() then verdict = "ok" end
    if verdict == "kill" then
      MON.vx = nil
      kill(id, "impact", string.format("%.0f m/s", dv), { over = dv / P("impact_kill") })
      return
    elseif verdict == "injure" and now() - MON.injured_t > 0.3 then
      MON.injured_t = now()
      local r = get(id)
      local hp = math.max(0, (r and r.hp or 1) - loss)
      patch(id, { hp = hp })
      log_(string.format("crew: #%d hurt (%.1f m/s), hp %.2f", id, dv, hp))
      if hp <= 0 then kill(id, "impact", string.format("%.0f m/s", dv), { over = 1.0 }) return end
    end
  end
  MON.vx, MON.vy, MON.vz = vx, vy, vz
  MON.x, MON.y, MON.z = a.x, a.y, a.z
  -- Knocks mend: 20 s after the last hurt, hp comes back 1% every 4 s
  -- (written once a second, not every tick).
  local hit = lastHit[id]
  local calm = now() - math.max(MON.injured_t or -1e9, hit and hit.t or -1e9)
  if calm > 20 then
    MON.mend = (MON.mend or 0) + dt / 400
    if MON.mend >= 0.0025 then
      local r = get(id)
      if r and r.status ~= "dead" and (r.hp or 1) < 1 then patch(id, { hp = math.min(1, (r.hp or 1) + MON.mend) }) end
      MON.mend = 0
    end
  else
    MON.mend = 0
  end
  MON.dom = d
  if b then MON.bx, MON.by, MON.bz = b.x, b.y, b.z end
  -- the fall speed against the ground (the fall chip)
  local pw = ref("planet_walker")
  local grounded = pw and (pw.grounded or pw.onGround)
  if b and not grounded then
    local ux, uy, uz = a.x - b.x, a.y - b.y, a.z - b.z
    local l = len(ux, uy, uz)
    if l > 1e-6 then
      MON.fall = math.max(0, -((vx - gvx) * ux + (vy - gvy) * uy + (vz - gvz) * uz) / l)
    end
  else
    MON.fall = 0
  end
  -- crushed: something solid in the suit's middle
  if overlapSphere then
    local hits = overlapSphere(vec3(a.x, a.y, a.z), P("crush_r"), { ignore = { a } })
    local pinned = false
    for _, h in ipairs(hits or {}) do
      local n = h.node
      if n and n.valid ~= false and n.id ~= a.id then
        local p = n.parent
        local nm = n.name or ""
        if nm:match("^Loose") or nm:match("^Debris") or nm == "Vessel"
          or (p and p.valid ~= false and (p.name == "Vessel" or (p.getScript and p:getScript("vessel_controller")))) then
          pinned = true
          break
        end
      end
    end
    local dead
    MON.crush_t, dead = crushStep(MON.crush_t, pinned, dt)
    MON.pinned = pinned
    if dead then kill(id, "crushed") return end
  end
end

-- Re-entry heat on everyone exposed (an open seat; anyone on EVA rides no
-- craft's heating). Runs at 4 Hz.
local heat_t = 0
local function heat_monitor(dt)
  heat_t = heat_t + dt
  if heat_t < 0.25 then return end
  local step_ = heat_t
  heat_t = 0
  local safe = invincible()
  for _, v in ipairs(vessels()) do
    if v.node and v.node.valid ~= false then
      local rate = v.heating or 0
      for _, s in ipairs(seats_of(v)) do
        if s.taken then
          local r = get(s.taken)
          if r then
            local h, dead = heatStep(r.heat or 0, rate, s.open == true and not safe, step_)
            if math.abs(h - (r.heat or 0)) > 1e-4 then
              r.heat = h
              save.set(key(r.id), r)
            end
            if dead then kill(r.id, "heat") end
          end
        end
      end
    end
  end
end

-- ── CrewBody range: records out of range, bodies back in range ─────────────
local range_t = -10
local function body_sync()
  if now() - range_t < 1.0 then return end
  range_t = now()
  local fx, fy, fz = nil, nil, nil
  local cam = find and (find("Camera 1") or find("Camera"))
  local c = current()
  if c.kind == "vessel" then fx, fy, fz = c.v.node.x, c.v.node.y, c.v.node.z
  else local a = astro() if a then fx, fy, fz = a.x, a.y, a.z end end
  if not fx and cam then fx, fy, fz = cam.x, cam.y, cam.z end
  if not fx then return end
  local active = activeId()
  for _, r in ipairs(roster()) do
    if r.status == "afoot" and r.id ~= active then
      local b = bodies[r.id]
      if b and b.valid ~= false then
        if len(b.x - fx, b.y - fy, b.z - fz) > P("body_range") then
          local d, x, y, z = rel(b.x, b.y, b.z)
          patch(r.id, { body = d, x = x, y = y, z = z })
          despawn_body(r.id)
        end
      else
        bodies[r.id] = nil
        local x, y, z = world_of(r)
        if x and len(x - fx, y - fy, z - fz) < P("body_spawn") then spawn_body(r.id, x, y, z) end
      end
    elseif bodies[r.id] then
      despawn_body(r.id)
    end
  end
end

-- Heal 0.02/min aboard or at base.
local heal_t = 0
local function heal(dt)
  heal_t = heal_t + dt
  if heal_t < 5 then return end
  local s = heal_t
  heal_t = 0
  for _, r in ipairs(roster()) do
    if (r.status == "base" or r.status == "aboard") and (r.hp or 1) < 1 then
      r.hp = math.min(1, (r.hp or 1) + P("heal_per_min") * s / 60)
      save.set(key(r.id), r)
    end
  end
end

-- ── the manager ────────────────────────────────────────────────────────────
function start(node)
  ensure()
  quiet_monitors(3.0)
  local n = save.get("crew.notice")
  if type(n) == "string" and n ~= "" then
    local bc = ref("big_caption")
    if bc and bc.show then
      bc.show("THE CREW", n, 7.0)
      save.set("crew.notice", false)
    end
  end
end

-- A save migrated while inventory's alias was missing moves its pack the
-- first frame the alias is there (then this costs one flag test).
function update(node, dt)
  if not ensured then ensure() end
  -- the Medkit's work: in the frame, where the avatar and the bodies are
  -- read at the same moment (a physics tick sees them a rails carry apart)
  treat_tick(dt or 0.016)
  -- ` : back to the last thing you controlled
  if input and input.pressed and input.pressed("`") then
    local gm = ref("game_manager")
    if not (gm and (gm.loading or gm.inputOwner == "builder")) then
      local ok, why = quickSwap()
      if not ok and why then caption(why) end
    end
  end
end

local dead_t = 0
function fixedUpdate(node, dt)
  if not save then return end
  -- a save left with its avatar's member dead (quit during the hold): pass on
  dead_t = dead_t + (dt or 0)
  if dead_t > 1.0 and not MON.dying and #queue == 0 then
    dead_t = 0
    local r = get(activeId())
    if (not r or r.status == "dead") and living() > 0 then handoff(activeId(), nil)
    elseif not r and living() == 0 and #roster() > 0 then handoff(nil, nil) end
  end
  run_queue()
  avatar_monitor(dt or 0.016)
  heat_monitor(dt or 0.016)
  down_monitor(dt or 0.016)
end

function lateUpdate(node, dt)
  if not save then return end
  -- the hold on the fallen: the walker and the camera show the avatar again
  -- each frame; its suit stays hidden here, in the last pass (the remains
  -- lie where they fell)
  if MON.dying then
    local a = astro()
    if a and a.children then
      MON.hid = MON.hid or {}
      for _, ch in ipairs(a:children()) do
        if ch.visible ~= false then ch.visible = false; MON.hid[#MON.hid + 1] = ch end
      end
    end
  end
  dollSync(false)
  body_sync()
  heal(dt or 0.016)
end

-- Probes and tests: the module's live tables.
function _debug() return { bodies = bodies, dolls = dolls, queue = queue, mon = MON, prev = prev } end
