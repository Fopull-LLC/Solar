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
--   role(m) / roleName / roleLetter / level(m) / levelWhy(m) / hasRole(who, role, minLevel?)
--   credit(id, counter, n?, {body}?) / busy(id) / training(id) / retrain(id, role) / retrainWhyNot
--                                the crew roles (J1–J3, J8): see "roles" below
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
  -- RESCUE (CREW SAFETY "rescue"): whoever would have died is knocked out
  -- and wakes at the base hurt — hp at most rescue_hp, mending as any knock
  -- does — for rescue_fee. Not invincible: the craft still breaks, the
  -- injury shows, and the flight is over for them.
  rescue_hp = 0.35,
  rescue_fee = 250,
  -- CREW BODIES (§4.1)
  body_range = 2500.0,    -- m from the focus: further, a record only
  body_spawn = 2000.0,    -- m: a record comes back as a body inside this
}

VERSION = 3
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
local is_role, assign_missing                            -- (roles, below)

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

local engine_caption = caption
local function caption(text)
  local fx = ref("sfx")
  if fx and fx.caption then pcall(fx.caption, text)
  -- (graveyard2: sfx has no caption; the engine's own bottom-centre line)
  elseif engine_caption then pcall(engine_caption, text) end
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
              hatch = { x = 0.47, y = -0.02, z = 0.0, nx = 1, ny = 0, nz = 0 },
              ladder = { a = { x = 0.3930, y = -0.30, z = 0.3930 }, b = { x = 0.2383, y = 0.22, z = 0.2383 }, n = { x = 0.7071, y = 0, z = 0.7071 }, half = 0.11 } },
  podMk2  = { command = true,
              seats = { { x = 0.0, y = -0.28, z = 0.22, yaw = 1.5708 },
                        { x = -0.66, y = -0.28, z = 0.16, yaw = 1.8708 },
                        { x = 0.66, y = -0.28, z = 0.16, yaw = 1.2708 } },
              hatch = { x = 0.49, y = -0.06, z = 0.0, nx = 1, ny = 0, nz = 0 },
              ladder = { a = { x = 0.3990, y = -0.46, z = 0.3990 }, b = { x = 0.2659, y = 0.30, z = 0.2659 }, n = { x = 0.7071, y = 0, z = 0.7071 }, half = 0.11 } },
  cabin   = { command = false,
              seats = { { x = -0.44, y = -0.3, z = 0.64, yaw = 1.5708 }, { x = 0.44, y = -0.3, z = 0.64, yaw = 1.5708 },
                        { x = 0.44, y = -0.3, z = -0.64, yaw = -1.5708 }, { x = -0.44, y = -0.3, z = -0.64, yaw = -1.5708 } },
              hatch = { x = 0.51, y = -0.1, z = 0.0, nx = 1, ny = 0, nz = 0 },
              ladder = { a = { x = 0.4002, y = -0.58, z = -0.4002 }, b = { x = 0.4002, y = 0.05, z = -0.4002 }, n = { x = 0.7071, y = 0, z = -0.7071 }, half = 0.11 } },
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

-- A docking merges two crafts' records, and the seats ride the records: a
-- member seated in BOTH (which no game path makes, but a cloned fleet record
-- or an old save can) would sit twice in the merged craft. `keep` are the
-- host's records, `incoming` the module's; a seat in `incoming` whose member
-- is already seated in `keep` (or earlier in `incoming`) is emptied. → how
-- many seats were emptied.
function dedupeSeats(keep, incoming)
  local seen = {}
  for _, s in ipairs(seatedIn(keep)) do seen[s.id] = true end
  local list = {}
  for _, d in pairs(incoming or {}) do list[#list + 1] = d end
  table.sort(list, function(a, b) return (a.uid or 0) < (b.uid or 0) end)
  local n = 0
  for _, d in ipairs(list) do
    local def = seatDef(d)
    if def then
      for k = 1, #def.seats do
        local id = memberAt(d, k)
        if id then
          if seen[id] then setMemberAt(d, k, nil); n = n + 1 else seen[id] = true end
        end
      end
    end
  end
  return n
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
      and (not avail or avail(e.id)) and not busy(e.id) then
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
  if not cmdr and active and (not avail or avail(active)) and not seen[active] and not busy(active) then
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
              hand = nil, task = nil, flights = 0, eva_s = 0, flags = 0, repairs = 0,
              landings = 0, dockings = 0, built = 0, crafted = 0, studied = 0, dose = 0 }
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
--   version 3: crew roles (J8). A member without a role gets one from the
--              service record (assignRoles), once, with a one-line notice;
--              a new save's starters are one of each.
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
  -- v3: roles. An old save hears about it; a new one's starters just have them.
  assign_missing(v ~= nil or save.get("g_played") ~= nil)
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
                hurtBy = true, carriedBy = true, follow = true, admitted = true,
                yaw = true, anchor = true, face = true, downed = true, retrain = true, leftAt = true, blackout = true,
                pose = true, title = true, gesture = true, npc = true }
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
  -- every applicant has a role, and the board holds one of each (J2): a
  -- board from before roles, or one an applicant just left, fills in the
  -- roles it lacks
  if fillOfferRoles(o) then save.set("crew.offers", o) end
  local fee = hireFee()
  local free = living() == 0
  local out = {}
  for i, a in ipairs(o) do
    out[i] = { name = a.name, cost = (free and i == 1) and 0 or fee, free = (free and i == 1) or nil, role = a.role }
  end
  return out
end

-- Pure: give the applicants in `o` without a role (or with a role a second
-- one holds while another is missing) the roles the board lacks, ROLES order.
-- → changed
function fillOfferRoles(o)
  local have, changed = {}, false
  for _, a in ipairs(o) do
    if is_role(a.role) and not have[a.role] then have[a.role] = true
    elseif a.role ~= nil then a.role = nil; changed = true end
  end
  for _, a in ipairs(o) do
    if not a.role then
      for _, k in ipairs(ROLES) do
        if not have[k] then a.role, have[k], changed = k, true, true; break end
      end
      if not a.role then a.role, changed = ROLES[1], true end
    end
  end
  return changed
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
  local rec = newRecord(id, a.name, { hired = (space and space.time and space.time()) or 0, cost = cost,
                                      role = a.role })
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
  log_(string.format("crew: hired %s (#%d), %s, for $%d", a.name, id, tostring(a.role), cost))
  return id, nil
end

function log_(s) if log then log(s) end end

-- ── roles (deep-space addendum §1, J1–J3, J8) ──────────────────────────────
-- Every member has exactly one ROLE: "pilot", "scientist" or "engineer"
-- (`rec.role`). The founding three are one of each; the applicants' board
-- always holds one of each; a role changes only by a paid RETRAIN at the
-- Command Centre (the Astronaut Complex): retrain_cost, the member out of
-- service retrain_secs of the agency's clock, once per retrain_every.
-- LEVEL 1–3 is derived from the service record, never stored: level 2 at the
-- first of lvl2_flights flights · lvl2_bodies bodies landed on ·
-- lvl2_built structures · lvl2_studied samples studied; level 3 at a first
-- (a landing, a build, a study) on a world other than the home one.
--
-- THE HOOKS other code calls (the pilot's SAS gate and perks J4, the
-- Engineer's Build Kit, repairs and perks J6 — built at step 9; the
-- scientist's devices J5 at step 16):
--   role(m) → "pilot"|"scientist"|"engineer"   m = a record or an id
--   roleName(m|role) → "Pilot"…   roleLetter(m|role) → "P"|"S"|"E"
--   level(m) → 1..3               levelWhy(m) → level, "5 flights" (what earned it)
--   hasRole(who, role, minLevel?) → bool, rec   who = a craft (vessel_controller:
--                                 its crewIds(), or aboard(v)), a list of ids or
--                                 records, a record, or an id
--   credit(id, counter, n?, {body}?) → new count   counter = "landings" |
--                                 "dockings" | "built" | "crafted" | "studied" |
--                                 "flights" | "repairs" | "flags" | "eva_s";
--                                 with a body, landings/built/studied also
--                                 note the world (level 2's bodies, level 3's
--                                 first away from home)
--   busy(id) → why|nil            out of service (retraining); nobody seats them
--   training(id) → {to, left}|nil
--   retrainWhyNot(id, role) → why|nil   retrain(id, role) → ok, why
--   retrainCost() → $
--   perk(m, name) → value|nil     what their role and level give (PERKS)
--   bestPerk(who, name) → value, rec   the best over a crew
--   onDuty(role) → id|nil         the member on duty for it at the base
--   sasAllows(mode, {crew, pilot, probe}) → ok, why   the pilot's gate (Q14)
-- Pure, for tests: levelOf(rec, home) · assignRoles(recs) → {[id] = role} ·
-- perkOf(role, level, name)
ROLES = { "pilot", "engineer", "scientist" }       -- also the order a tie is filled in
ROLE_NAME = { pilot = "Pilot", scientist = "Scientist", engineer = "Engineer" }
ROLE_LETTER = { pilot = "P", scientist = "S", engineer = "E" }
COUNTERS = { landings = true, dockings = true, built = true, crafted = true, studied = true,
             flights = true, repairs = true, flags = true, eva_s = true }
-- (tuning lives in `defaults` so a scene's params can change it; read with P)
defaults.retrain_cost = 2000
defaults.retrain_secs = 86400          -- one game day out of service
defaults.retrain_every = 30 * 86400    -- one retrain per member per 30 days
defaults.lvl2_flights = 5
defaults.lvl2_bodies = 3
defaults.lvl2_built = 20
defaults.lvl2_studied = 10

is_role = function(r) return r == "pilot" or r == "scientist" or r == "engineer" end

-- The agency's clock (game seconds since the save began, warp included;
-- deployables keeps it). The sim clock restarts every session, so a
-- retrain's day is counted on this one.
local function clock()
  local dp = ref("deployables")
  if dp and dp.agencyClock then
    local ok, t = pcall(dp.agencyClock)
    if ok and type(t) == "number" then return t end
  end
  return tonumber(save and save.get and save.get("agency.clock")) or 0
end

local function rec_of(m)
  if type(m) == "table" then return m end
  if m == nil or not (save and save.get) then return nil end
  -- (the context menu's on-foot actor is "astro": the member you are. Read
  -- as a record id it was nobody, so role/perk/hasRole said no role at all:
  -- Ty 11-12, an Engineer told a ruin "needs an Engineer".)
  if m == "astro" then m = activeId() end
  return get(m)
end

-- A record's leaning, from what they have done (J8's rule): more repairs
-- than flights → engineer; more flights → pilot; otherwise none.
local function lean(r)
  local f, rp = tonumber(r.flights) or 0, tonumber(r.repairs) or 0
  if rp > f then return "engineer" end
  if f > rp then return "pilot" end
  return nil
end

-- The role with the fewest holders in `count`; `prefer` wins among the
-- fewest, then ROLES order.
local function least_held(count, prefer)
  local lo = math.huge
  for _, k in ipairs(ROLES) do lo = math.min(lo, count[k] or 0) end
  if prefer and (count[prefer] or 0) == lo then return prefer end
  for _, k in ipairs(ROLES) do if (count[k] or 0) == lo then return k end end
  return ROLES[1]
end

-- J8, pure: roles for the members of `recs` that have none, from the
-- service record. The living are weighed together: the one with the most
-- repairs is the Engineer and the one with the most flights the Pilot (only
-- when they lead outright, and a member who leads both takes the one they
-- lean to); everyone else, in id order, takes the role the roster has
-- fewest of (their own leaning breaks a tie) — so a three-member roster
-- whose record is a tie ends up one of each. The dead take their leaning,
-- else Scientist, and count for nothing. Members that already have a role
-- keep it and count. → { [id] = role }
function assignRoles(recs)
  local out, count, pend = {}, { pilot = 0, scientist = 0, engineer = 0 }, {}
  for _, r in ipairs(recs or {}) do
    if type(r) == "table" and r.id ~= nil then
      if is_role(r.role) then
        if r.status ~= "dead" then count[r.role] = count[r.role] + 1 end
      elseif r.status == "dead" then
        out[r.id] = lean(r) or "scientist"
      else
        pend[#pend + 1] = r
      end
    end
  end
  table.sort(pend, function(a, b) return (tonumber(a.id) or 0) < (tonumber(b.id) or 0) end)
  local function leader(field, skip)
    local best, n, tie = nil, 0, false
    for _, r in ipairs(pend) do
      if not out[r.id] and r.id ~= skip then
        local v = tonumber(r[field]) or 0
        if v > n then best, n, tie = r, v, false elseif v == n and v > 0 then tie = true end
      end
    end
    if tie then return nil end
    return best
  end
  if count.engineer == 0 or count.pilot == 0 then
    local eng = count.engineer == 0 and leader("repairs") or nil
    local pil = count.pilot == 0 and leader("flights") or nil
    if eng and pil and eng == pil then
      -- one member leads both: they take what they lean to, the other role
      -- goes to the next leader
      if lean(eng) == "pilot" then eng = leader("repairs", pil.id) else pil = leader("flights", eng.id) end
    end
    if eng then out[eng.id] = "engineer"; count.engineer = count.engineer + 1 end
    if pil and not out[pil.id] then out[pil.id] = "pilot"; count.pilot = count.pilot + 1 end
  end
  for _, r in ipairs(pend) do
    if not out[r.id] then
      local k = least_held(count, lean(r))
      out[r.id] = k
      count[k] = count[k] + 1
    end
  end
  return out
end

-- Give every member without a role one (J8). `announce`: a one-line news
-- item (the crew notice, shown as THE CREW caption on the next scene).
-- → the number assigned to the living.
assign_missing = function(announce)
  local recs = {}
  for _, id in ipairs(ids()) do
    local r = save.get(key(id))
    if type(r) == "table" then recs[#recs + 1] = r end
  end
  local got = assignRoles(recs)
  local parts, n = {}, 0
  for _, r in ipairs(recs) do
    local k = got[r.id]
    if k then
      r.role = k
      put(r)
      if r.status ~= "dead" then
        n = n + 1
        parts[#parts + 1] = string.format("%s %s", tostring(r.name), ROLE_NAME[k])
      end
    end
  end
  if announce and n > 0 then
    local line = "Crew roles, from the service record: " .. table.concat(parts, ", ") .. "."
    local prev = save.get("crew.notice")
    save.set("crew.notice", (type(prev) == "string" and prev ~= "") and (prev .. " " .. line) or line)
    log_("crew: " .. line)
  end
  return n
end

function role(m)
  local r = rec_of(m)
  if not r then return nil end
  local t = r.retrain
  if type(t) == "table" and is_role(t.to) and clock() >= (tonumber(t.done) or 0) then return t.to end
  if is_role(r.role) then return r.role end
  return lean(r) or "scientist"      -- (a record J8 has not seen yet: never nil)
end

function roleName(m)
  local k = is_role(m) and m or role(m)
  return k and ROLE_NAME[k] or nil
end

function roleLetter(m)
  local k = is_role(m) and m or role(m)
  return k and ROLE_LETTER[k] or nil
end

-- (graveyard2) What they are, in words, for the strip, the picker and the
-- tag over a member you look at: the record's `title` when something gave
-- them one (a scenario's start.crew `title`, "Night engineer"), else the
-- role's name. Ty 2026-11-10: "no indicators for what roles everyone has".
function roleTitle(m)
  local r = rec_of(m)
  if r and type(r.title) == "string" and r.title ~= "" then return r.title end
  return roleName(m)
end

local function bodies_of(r)
  local b = type(r.worlds) == "table" and r.worlds or {}
  local n = 0
  for _ in pairs(b) do n = n + 1 end
  return n
end

-- Pure: the level a record has earned, and why. `home` = the home world's
-- name (a first anywhere else is level 3).
function levelOf(r, home)
  if type(r) ~= "table" then return 1, nil end
  local away = type(r.away) == "table" and r.away or nil
  if away and away.body and away.body ~= home then
    return 3, string.format("first %s on %s", tostring(away.kind or "visit"), tostring(away.body))
  end
  if type(r.worlds) == "table" and home then
    for b, _ in pairs(r.worlds) do
      if b ~= home then return 3, "landed on " .. tostring(b) end
    end
  end
  local f = tonumber(r.flights) or 0
  if f >= P("lvl2_flights") then return 2, string.format("%d flights", f) end
  local nb = bodies_of(r)
  if nb >= P("lvl2_bodies") then return 2, string.format("landed on %d worlds", nb) end
  local b = tonumber(r.built) or 0
  if b >= P("lvl2_built") then return 2, string.format("%d structures built", b) end
  local s = tonumber(r.studied) or 0
  if s >= P("lvl2_studied") then return 2, string.format("%d samples studied", s) end
  return 1, nil
end

local function home_body() return save and save.get and save.get("base.body") or nil end

function level(m)
  local lv = levelOf(rec_of(m), home_body())
  return lv
end

function levelWhy(m) return levelOf(rec_of(m), home_body()) end

-- Does anyone in `who` hold `role_` (at minLevel or better)? `who` is a
-- craft (a vessel_controller: crewIds(), or aboard(v)), a list of ids or
-- records, one record or one id. A member out of service doesn't count.
function hasRole(who, role_, minLevel)
  if not is_role(role_) then return false, nil end
  local list
  if type(who) == "table" and (type(who.crewIds) == "function" or who.node ~= nil) then
    list = {}
    if type(who.crewIds) == "function" then
      local ok, l = pcall(who.crewIds)
      if ok and type(l) == "table" then list = l end
    end
    if #list == 0 then
      for _, a in ipairs(aboard and aboard(who) or {}) do list[#list + 1] = a.id end
    end
  elseif type(who) == "table" and who.id ~= nil and who.name ~= nil then
    list = { who }
  elseif type(who) == "table" then
    list = who
  else
    list = { who }
  end
  for _, m in ipairs(list) do
    local r = rec_of(m)
    if r and r.status ~= "dead" and not busy(r) and role(r) == role_
       and (not minLevel or levelOf(r, home_body()) >= minLevel) then
      return true, r
    end
  end
  return false, nil
end

-- ── what a role gives (J4 Pilot, J6 Engineer; J5 Scientist's hook) ─────────
-- PERKS[name][role] = { level 1, level 2, level 3 }; anyone without the role
-- (or out of service) gets PERK_NONE[name]. `false` in a row means "none".
-- Pure: tests read the table and perkOf; the scripts ask perk(m, name).
PERKS = {
  -- J6: × a repair's seconds (crew_task / items.repairSecs)
  repair_time = { engineer = { 0.5, 0.35, 0.35 } },
  -- J6: the WEAR tag over a damaged part under the cursor (context_menu)
  wear_read   = { engineer = { false, true, true } },
  -- J6: × the Power Cable's price a metre (base_cable.quote): less spoil
  cable_cost  = { engineer = { 1.0, 0.9, 0.8 } },
  -- J6: + a Battery Bank's charge efficiency, for the one who set it up
  battery_eff = { engineer = { 0.0, 0.03, 0.05 } },
  -- J6 L3 (step 13's hook, off-world deconstruct): share of the materials back
  salvage     = { engineer = { 0.8, 0.8, 1.0 } },
  -- J4: × the RCS Pack's Δv (eva_pack): steady hands
  rcs_dv      = { pilot = { 1.0, 1.25, 1.25 } },
  -- J4: × the range the docking ladder shows from (targeting)
  dock_ladder = { pilot = { 1.0, 4.0, 4.0 } },
  -- J4 L3: warp to node lands this many s before the burn starts (orbit_map),
  -- and the burn readout counts IGNITE IN
  node_lead   = { pilot = { false, false, 5.0 } },
  -- J5 (step 16): × the RP of a lot a Scientist studies at a bench
  study_mult  = { scientist = { 1.5, 2.0, 3.0 } },
  -- S6: × the seconds a fuel rod takes in or out of a reactor's channel
  refuel_time = { engineer = { 1.0, 0.7, 0.5 } },
  -- S6 L2: the console's xenon forecast (when a restart can reach critical)
  xe_forecast = { engineer = { false, true, true } },
  -- S6 L3: + the share of Carnot a turbine makes, for the plant they set up
  plant_trim  = { engineer = { 0.0, 0.0, 0.03 } },
}
PERK_NONE = { repair_time = 1.0, wear_read = false, cable_cost = 1.0, battery_eff = 0.0, salvage = 0.8,
              rcs_dv = 1.0, dock_ladder = 1.0, node_lead = false, study_mult = 1.0,
              refuel_time = 1.0, xe_forecast = false, plant_trim = 0.0 }
-- Which way is better, for bestPerk over a crew: "low" (a time, a price) or
-- "high" (everything else; true beats false).
PERK_LOW = { repair_time = true, cable_cost = true, refuel_time = true }

-- Pure: the perk `name` for `role_` at `lvl`. → value (nil for "none")
function perkOf(role_, lvl, name)
  local row = PERKS[name] and PERKS[name][role_]
  local v
  if row then
    lvl = math.max(1, math.min(3, math.floor(tonumber(lvl) or 1)))
    v = row[lvl]
  else
    v = PERK_NONE[name]
  end
  if v == false then return nil end
  return v
end

-- A member's perk (m = an id or a record). Out of service or dead: none.
function perk(m, name)
  local r = rec_of(m)
  if not r or r.status == "dead" or busy(r) then
    local v = PERK_NONE[name]
    if v == false then return nil end
    return v
  end
  return perkOf(role(r), levelOf(r, home_body()), name)
end

local function better(name, a, b)
  if a == nil then return false end
  if b == nil then return true end
  if type(a) == "boolean" or type(b) == "boolean" then return a == true and b ~= true end
  if PERK_LOW[name] then return a < b end
  return a > b
end

-- The best of `name` over a crew (`who` as hasRole takes it). → value, rec
function bestPerk(who, name)
  local list
  if type(who) == "table" and (type(who.crewIds) == "function" or who.node ~= nil) then
    list = {}
    if type(who.crewIds) == "function" then
      local ok, l = pcall(who.crewIds)
      if ok and type(l) == "table" then list = l end
    end
  elseif type(who) == "table" and who.id ~= nil and who.name ~= nil then
    list = { who }
  elseif type(who) == "table" then
    list = who
  else
    list = { who }
  end
  local best, br = nil, nil
  local none = PERK_NONE[name]
  if none == false then none = nil end
  for _, m in ipairs(list) do
    local r = rec_of(m)
    if r then
      local v = perk(r, name)
      if br == nil or better(name, v, best) then best, br = v, r end
    end
  end
  if br == nil then return none, nil end
  return best, br
end

-- The member on duty for a role at the base: the one being played if they
-- hold it, else the senior living member of it at the base (status base or
-- on foot), lowest id on a tie. Out of service members don't count.
-- → id | nil (J3's "studied" credit at the Intake; J5's bench)
function onDuty(role_)
  local a = activeId and activeId() or nil
  if a and hasRole(a, role_) then return a end
  local best, bl = nil, 0
  for _, id in ipairs(ids()) do
    local r = get(id)
    if r and (r.status == "base" or r.status == "afoot" or r.status == nil) and r.status ~= "dead"
       and not busy(r) and role(r) == role_ then
      local lv = levelOf(r, home_body())
      if lv > bl then best, bl = id, lv end
    end
  end
  return best
end

-- J4, PURE: may a craft hold SAS mode `mode`? Q14 (Ty, 2026-11-05): crew at
-- the controls without a Pilot or a probe core aboard get stability and
-- prograde / retrograde only; every other hold (normal, radial, TARGET, DOCK,
-- NODE) needs a Pilot or a probe core. A probe core flying, or no crew
-- library, is never gated. Nothing is impossible: docking is just harder.
-- ctx = { crew = bool (crew fly it), pilot = bool, probe = bool (a live core
-- aboard) }. → ok, why
SAS_BASIC = { off = true, stability = true, prograde = true, retrograde = true }
SAS_NEEDS = "needs a Pilot or a probe core aboard"
function sasAllows(mode, ctx)
  if SAS_BASIC[mode] then return true, nil end
  if not (ctx and ctx.crew) then return true, nil end
  if ctx.pilot or ctx.probe then return true, nil end
  return false, SAS_NEEDS
end

-- Count something a member did. → the new count (nil: no such member).
function credit(id, counter, n, opts)
  if not COUNTERS[counter] then return nil end
  local r = get(id)
  if not r or r.status == "dead" then return nil end
  r[counter] = (tonumber(r[counter]) or 0) + (n or 1)
  local body = opts and opts.body
  if body and (counter == "landings" or counter == "built" or counter == "studied") then
    if counter == "landings" then
      r.worlds = type(r.worlds) == "table" and r.worlds or {}
      r.worlds[body] = true
    end
    local home = home_body()
    if home and body ~= home and not (type(r.away) == "table" and r.away.body) then
      local kind = counter == "landings" and "landing" or (counter == "built" and "build" or "study")
      r.away = { kind = kind, body = body, t = clock() }
    end
  end
  put(r)
  return r[counter]
end

-- ── retraining (J2) ──
function retrainCost() return P("retrain_cost") end

function training(id)
  local r = rec_of(id)
  local t = r and r.retrain
  if type(t) ~= "table" then return nil end
  local left = (tonumber(t.done) or 0) - clock()
  if left <= 0 then return nil end
  return { to = t.to, from = t.from, left = left }
end

function busy(m)
  local t = training(m)
  if t then
    local h = math.ceil(t.left / 3600)
    return string.format("retraining as %s (%d h left)", ROLE_NAME[t.to] or "?", h)
  end
  -- (expansion X3: a member who goes with an automated run is away on it)
  local ro = ref("route_ops")
  if ro and ro.memberBusy then
    local r = rec_of(m)
    local ok, b = pcall(ro.memberBusy, r and r.id or m)
    if ok and b then return b end
  end
  return nil
end

-- Why member `id` can't retrain as `to` now, or nil.
function retrainWhyNot(id, to)
  local r = rec_of(id)
  if not r then return "no such crew member" end
  if not is_role(to) then return "no such role" end
  if r.status == "dead" then return "dead" end
  if role(r) == to then return "already a " .. ROLE_NAME[to] end
  if training(r) then return busy(r) end
  if r.status ~= "base" then return "only at base" end
  local last = tonumber(r.retrained)
  if last then
    local wait = last + P("retrain_every") - clock()
    if wait > 0 then return string.format("retrained lately: again in %d days", math.ceil(wait / 86400)) end
  end
  local co = ref("company")
  if co and co.afford and not co.afford(P("retrain_cost")) then return "not enough money" end
  return nil
end

-- Retrain: pay, and the member is out of service for a day; the new role
-- is theirs when it ends (role() reads it from then on; finish_retrains
-- writes it down).
function retrain(id, to)
  local why = retrainWhyNot(id, to)
  if why then return false, why end
  local r = get(id)
  local co = ref("company")
  if co and co.spend then
    if not co.spend(P("retrain_cost"), "crew retrain: " .. tostring(r.name) .. " → " .. ROLE_NAME[to]) then
      return false, "not enough money"
    end
  end
  local t0 = clock()
  r.retrain = { from = role(r), to = to, t0 = t0, done = t0 + P("retrain_secs") }
  r.retrained = t0
  put(r)
  log_(string.format("crew: %s retrains as %s", tostring(r.name), ROLE_NAME[to]))
  return true, nil
end

-- A finished retrain becomes the record's role (and the record forgets it).
function finish_retrains()
  local now_c = clock()
  for _, id in ipairs(ids()) do
    local r = save.get(key(id))
    local t = type(r) == "table" and r.retrain
    if type(t) == "table" and now_c >= (tonumber(t.done) or 0) then
      if is_role(t.to) then r.role = t.to end
      r.retrain = nil
      put(r)
    end
  end
end
rolesTick = finish_retrains   -- (tests and probes)
roles_t = 0

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

-- DEATHS COST REPUTATION (career missions PLAN §5; Ty 2026-11-11: "it's really
-- easy to kill astronauts which sucks for reputation, so let's make a setting
-- for whether killing astronauts reduces your reputation"). Per save, default
-- ON (a save without the key costs, as every save did). Off spares the
-- company's standing only: permadeath, the memorial and the lost pack stand.
-- Governs every death `kill` records, our crew's and a client's (a rescue's
-- survivor). Abandoning a contract is not a life and stays outside it.
function deathRep()
  return save.get("crew.deathRep") ~= false
end

function setDeathRep(on)
  save.set("crew.deathRep", on ~= false)
  bump()
end

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

-- The craft controllers, kept for a quarter second: alerts, aboard and
-- switchList walk them every frame, and a fresh findScripts per call grew
-- with every craft left in the world (perf pass 2026-11-02). Callers already
-- skip a controller whose node is gone; a craft split off this instant shows
-- up within 0.25 s.
local VESSELS = { list = nil, t = -1 }
local function vessels()
  local t = now()
  if VESSELS.list and t >= VESSELS.t and t - VESSELS.t < 0.25 then return VESSELS.list end
  VESSELS.list = findScripts and findScripts("vessel_controller") or {}
  VESSELS.t = t
  return VESSELS.list
end

local function vessel_by_id(nid)
  for pass = 1, 2 do
    for _, v in ipairs(vessels()) do
      if v.node and v.node.valid ~= false and v.node.id == nid then return v end
    end
    -- (a craft spawned since the list was kept: look once more, fresh)
    if pass == 1 then VESSELS.list = nil end
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

-- (graveyard2) A switch made with a click leaves the button focused, and the
-- engine's UiSubmit (Space, Enter) clicks a focused button again: Ty jumped
-- after a switch and switched back. Every switching verb drops the focus.
local function drop_focus()
  if ui and ui.focus then pcall(ui.focus, nil) end
end

-- (graveyard2) A FREE SPOT for a standing capsule near world point x,y,z (its
-- centre): never inside a wall, a console or a bunk (Ty: "npcs got stuck in
-- the wall when switching"). Two spheres at the knees and the chest, crew and
-- the Astronaut not counted; the first free spot on rings of 0.35–1.4 m, or
-- the point itself when nothing is free. In the physics tick (tick poses).
local function spot_clear(x, y, z, ux, uy, uz, ign)
  if not (overlapSphere and vec3) then return true end
  for _, h in ipairs({ -0.33, 0.35 }) do
    local ok, hits = pcall(overlapSphere, vec3(x + ux * h, y + uy * h, z + uz * h), 0.28, { ignore = ign })
    if ok and type(hits) == "table" then
      for _, hit in ipairs(hits) do
        local n = hit.node
        local nm = n and n.name
        if n and not (type(nm) == "string" and (nm:sub(1, 4) == "Door" or nm == "CrewBody" or nm == "Astronaut")) then return false end
      end
    end
  end
  return true
end
function freeSpot(x, y, z)
  if not (space and space.dominant) then return x, y, z end
  local d = space.dominant(x, y, z)
  local b = d and space.body(d)
  if not b then return x, y, z end
  local ux, uy, uz = x - b.x, y - b.y, z - b.z
  local l = math.sqrt(ux * ux + uy * uy + uz * uz)
  if l < 1e-6 then return x, y, z end
  ux, uy, uz = ux / l, uy / l, uz / l
  local ign = {}
  local a = astro and astro()
  if a then ign[#ign + 1] = a end
  for _, n in pairs(bodies) do if n and n.valid ~= false then ign[#ign + 1] = n end end
  if spot_clear(x, y, z, ux, uy, uz, ign) then return x, y, z, true end
  local ax, ay, az = 0, 1, 0
  if math.abs(uy) > 0.9 then ax, ay, az = 1, 0, 0 end
  local ex, ey, ez = ay * uz - az * uy, az * ux - ax * uz, ax * uy - ay * ux
  local el = math.sqrt(ex * ex + ey * ey + ez * ez)
  ex, ey, ez = ex / el, ey / el, ez / el
  local nx, ny, nz = uy * ez - uz * ey, uz * ex - ux * ez, ux * ey - uy * ex
  for _, rr in ipairs({ 0.35, 0.7, 1.05, 1.4 }) do
    for k = 0, 11 do
      local t = k * math.pi / 6
      local c, s = math.cos(t) * rr, math.sin(t) * rr
      local px, py, pz = x + ex * c + nx * s, y + ey * c + ny * s, z + ez * c + nz * s
      if spot_clear(px, py, pz, ux, uy, uz, ign) then return px, py, pz, true end
    end
  end
  return x, y, z, false
end

-- The nodes of the bodies on foot (kit_live opens doors for a walking one).
function bodyNodes() local out = {} for id, n in pairs(bodies) do if n and n.valid ~= false then out[id] = n end end return out end

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
  -- (graveyard2) out of the way first: the destroy lands at the end of the
  -- frame, and the Astronaut set down in the same spot this tick was pushed
  -- out of the kinematic capsule, up into the ceiling (Ty: "npcs got stuck in
  -- the wall when switching, and clipped through"; a probe caught the
  -- capsule 1.3 m up). 50 m under the ground until it goes.
  if b and b.valid ~= false and space and space.dominant then
    local p = b.tickPos or b
    local d = p and p.x and space.dominant(p.x, p.y, p.z)
    local pb = d and space.body(d)
    if pb then
      local ux, uy, uz = p.x - pb.x, p.y - pb.y, p.z - pb.z
      local l = math.sqrt(ux * ux + uy * uy + uz * uz)
      if l > 1 then
        local nx, ny, nz = p.x - ux / l * 50, p.y - uy / l * 50, p.z - uz / l * 50
        -- (its script stops placing it from the record first: crew_body.retire)
        local cb = b.getScript and b:getScript("crew_body") or nil
        if cb and cb.retire then pcall(cb.retire, nx, ny, nz) end
        if b.tickPos ~= nil and vec3 then pcall(function() b.tickPos = vec3(nx, ny, nz) end) end
        pcall(function() b.x, b.y, b.z = nx, ny, nz end)
      end
    end
  end
  if b and b.valid ~= false and destroy then destroy(b) end
end

-- Leave the avatar's member where they stand: a CrewBody at the avatar's
-- pose, the record on foot there.
local function park_avatar_member(id)
  local a = astro()
  if not (a and id) then return end
  suit_out(id)
  -- (this runs in the physics tick: the TICK pose against the tick's body
  -- read — node.x is the drawn pose, a rails carry behind; frames doc rule 3)
  local ax, ay, az = a.x, a.y, a.z
  local tp = a.tickPos
  if tp and tp.x then ax, ay, az = tp.x, tp.y, tp.z end
  local d, x, y, z = rel(ax, ay, az)
  -- the way they face: the suit model's (the rig looks along its node's +Z)
  local face = false
  for _, ch in ipairs(a.children and a:children() or {}) do
    if ch.name == "AstroModel" and ch.worldForward then
      local f = ch:worldForward()
      face = { x = -f.x, y = -f.y, z = -f.z }
    end
  end
  -- (graveyard2: the capsule you leave stands where you stood, which is free;
  -- a pose is cleared — you got up)
  local fx, fy, fz = freeSpot(ax, ay, az)
  if fx ~= ax or fy ~= ay or fz ~= az then d, x, y, z = rel(fx, fy, fz); ax, ay, az = fx, fy, fz end
  patch(id, { status = "afoot", craft = false, body = d, x = x, y = y, z = z, face = face, anchor = false,
              leftAt = clock(), pose = false })
  spawn_body(id, ax, ay, az)
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
  local nid = n.id
  for id, d in pairs(dolls) do if d.node == n or (nid and d.node and d.node.id == nid) then return id, "doll" end end
  for id, b in pairs(bodies) do if b == n or (nid and b and b.id == nid) then return id, "body" end end
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

-- (gy3, Ty 2026-11-11: "I can control Dana as one of the crew members") a
-- record with `npc` (a scenario's cast member the player does not play) is
-- never taken: not by a click, a key, a picker, a quick swap or a craft.
NOT_YOURS = "not yours to play"
function playable(id)
  local r = type(id) == "table" and id or get(id)
  return r ~= nil and not r.npc
end

-- TAKE CONTROL of member `id` (§4.1).
function control(id)
  drop_focus()
  local r = get(id)
  if not r then return false, "no such crew member" end
  if r.npc and id ~= activeId() then return false, r.name .. " is " .. NOT_YOURS end
  if r.client then return false, "not one of ours" end     -- (missions N1) a survivor (newClient sets npc too)
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
  drop_focus()
  if not (v and v.node and v.node.valid ~= false) then return false, "no craft" end
  local seated = aboard(v)
  if #seated == 0 then return false, "nobody aboard" end
  if not id then
    -- (gy3) the first one aboard the player may play
    for _, s in ipairs(seated) do if playable(s.id) then id = s.id break end end
    if not id then return false, "nobody aboard is yours to play" end
  end
  if not playable(id) and id ~= activeId() then return false, NOT_YOURS end
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
  queue[#queue + 1] = { kind = "eva", id = id, nid = v.node.id, uid = uid, stay = opts.stay == true, k = opts.k }
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
      -- (not the downed: control() refuses them, so the strip's CONTROL chip
      -- and [ ] would offer what can't be done; the DOWN chip lists them)
      -- (missions N1: nor a survivor, who is not ours to play)
      if r and r.status == "afoot" and not r.downed and not r.npc and not r.client and d <= range then
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


-- ── SWITCH TO ANY MEMBER (docs/tracking-station.md §2) ─────────────────────
-- One verb for the crew strip's CREW ▸ picker, the pause menu, the roster's
-- Go to and the Tracking Station's card:
--   canSwitch(id) → ok, why, mode, detail
--       mode "near"   on foot within body_range: control() (instant)
--            "craft"  seated in a craft in the scene: takeCraft()
--            "base"   at the base, the base within body_range: spawnAtBase()
--            "travel" anywhere else (out of range, another world, a craft
--                     not rebuilt): goTo() behind the travel curtain
--   switchToMember(id) → ok, why | true, "travel"
--   spawnAtBase(id) / goTo(id) → ok, why
--   switchTargets() → { {id, name, role, mode, ok, why, label, where}… }
--   recordStep(rec, dt, amb) (pure) / recordTick()   the left-behind's air

-- The fleet record that has member `id` in a seat: fid, record.
local function seated_record(id)
  local fo = ref("flight_ops")
  local recs = fo and fo.fleetRecords and fo.fleetRecords() or (save.get("fleet.craft") or {})
  for fid, rec in pairs(recs) do
    if type(rec) == "table" and rec.parts then
      for _, s in ipairs(seatedIn(rec.parts)) do if s.id == id then return fid, rec end end
    end
  end
  return nil, nil
end
seatedRecord = seated_record

local function focus_pos()
  return pos_of_current(current())
end

-- Where a far place is, said short: "4.1 km" on the world you are on, else
-- the world's name.
local function far_label(body, wx, wy, wz)
  local fx, fy, fz = focus_pos()
  local here = fx and space and space.dominant and space.dominant(fx, fy, fz)
  if here == body and wx and fx then
    local d = len(wx - fx, wy - fy, wz - fz)
    if d >= 1000 then return string.format("%.1f km", d / 1000) end
    return string.format("%.0f m", d)
  end
  return tostring(body or "far")
end

-- The base's crew home, body-relative (the station's own rule).
local function home_spot()
  local ts = ref("tracking_station")
  local x, y, z = nil, nil, nil
  if ts and ts.crewHome then x, y, z = ts.crewHome() end
  if not x then return nil end
  local d, rx, ry, rz = rel(x, y, z)
  if not d then return nil end
  return d, rx, ry, rz
end

function canSwitch(id)
  local r = get(id)
  if not r then return false, "no such crew member" end
  if r.client then return false, "not one of ours" end     -- (missions N1) a survivor
  if r.status == "dead" then return false, (r.name or "they") .. " is lost" end
  local active = activeId()
  local ride = avatarCraft()
  if id == active then
    if ride then return false, "that's you" end
    if current().kind == "vessel" then return true, nil, "near", "on foot" end
    return false, "that's you"
  end
  if r.downed then return false, r.name .. " is down — bring a Medkit" end
  if r.npc then return false, NOT_YOURS end
  local b = busy(r)
  if b then return false, b end
  if r.status == "aboard" then
    local v = craftOf(id)
    if v then
      if v.isLost and v.isLost() then return false, "lost with " .. tostring(v.craftName or r.craft or "their craft") end
      return true, nil, "craft", v.craftName or r.craft
    end
    local fid, rec = seated_record(id)
    if not fid then return false, (r.craft and (tostring(r.craft) .. " is not on the board")) or "their craft is gone" end
    return true, nil, "travel", tostring(rec.body or "far")
  end
  if r.status == "afoot" then
    local bd = bodies[id]
    if bd and bd.valid ~= false then
      -- (a body is "near" only within range of what you control now: one
      -- left standing by a craft that has since flown off is a trip)
      local fx, fy, fz = focus_pos()
      local d = fx and len(bd.x - fx, bd.y - fy, bd.z - fz) or nil
      -- (and on the same world: a member on a moon you are flying past is a
      -- trip, so the curtain brings their ground in before you stand on it)
      local same = fx and space and space.dominant and space.dominant(fx, fy, fz) == r.body
      if d and d <= P("body_range") and same then return true, nil, "near", string.format("%.0f m", d) end
    end
    local wx, wy, wz = world_of(r)
    if not wx then return false, "nowhere to be found" end
    return true, nil, "travel", far_label(r.body, wx, wy, wz)
  end
  if r.status == "base" then
    local bf = ref("base_facilities")
    if not (bf and bf.sited) then return false, "there is no base" end
    local fx, fy, fz = focus_pos()
    if fx and len(bf.baseX - fx, bf.baseY - fy, bf.baseZ - fz) <= P("body_range") then
      return true, nil, "base", "the base"
    end
    return true, nil, "travel", far_label(bf.baseBody, bf.baseX, bf.baseY, bf.baseZ)
  end
  return false, "not available"
end

-- A member at the base stands up at the crew home and you are them.
function spawnAtBase(id)
  local r = get(id)
  if not (r and r.status == "base") then return false, "not at the base" end
  local d, rx, ry, rz = home_spot()
  if not d then return false, "the base isn't there yet" end
  queue[#queue + 1] = { kind = "base", id = id, body = d, x = rx, y = ry, z = rz }
  return true, nil
end

-- THE FAR SWITCH: the one you are is left where they stand, a travel
-- curtain goes up (game_manager.travelTo), the world under the member comes
-- in (and their craft is rebuilt, when they are seated), then you are them.
-- The destination is a body and an offset: nothing world-positioned is kept
-- across the wait.
function goTo(id)
  local r = get(id)
  if not r then return false, "no such crew member" end
  local gm = ref("game_manager")
  if not (gm and gm.travelTo) then return false, "no travel from here" end
  local item = { kind = "leave", id = id, name = r.name }
  if r.status == "aboard" then
    local fid, rec = seated_record(id)
    if not (fid and rec and rec.body) then return false, "their craft is not on the board" end
    item.body, item.x, item.y, item.z, item.fid, item.where = rec.body, rec.x or 0, rec.y or 0, rec.z or 0, fid, rec.name
  elseif r.status == "afoot" then
    if not (r.body and r.x) then return false, "nowhere to be found" end
    item.body, item.x, item.y, item.z, item.where = r.body, r.x, r.y, r.z, r.body
  elseif r.status == "base" then
    local bf = ref("base_facilities")
    local fp = bf and bf.footprint
    if not fp then return false, "there is no base" end
    item.body, item.x, item.y, item.z, item.base, item.where = fp.body, fp.x, fp.y, fp.z, true, "the base"
  else
    return false, "not available"
  end
  queue[#queue + 1] = item
  return true, "travel"
end

function switchToMember(id)
  drop_focus()
  local ok, why, mode = canSwitch(id)
  if not ok then return false, why end
  remember()
  if mode == "near" then return control(id) end
  if mode == "craft" then
    local v = craftOf(id)
    if not v then return false, "their craft is gone" end
    return takeCraft(v, id)
  end
  if mode == "base" then return spawnAtBase(id) end
  return goTo(id)
end

-- Everyone, for a picker: what pressing their row does, or why not.
function switchTargets()
  local out = {}
  for _, r in ipairs(roster()) do
    -- (gy3) a scenario's cast member you don't play is not on the picker
    if r.status ~= "dead" and not r.npc then
      local ok, why, mode, detail = canSwitch(r.id)
      local label
      if r.id == activeId() and not ok then label = "YOU"
      elseif not ok then label = why
      elseif mode == "near" then label = "SWITCH" .. (detail and (" · " .. detail) or "")
      elseif mode == "craft" then label = "FLY · " .. tostring(detail or "their craft")
      elseif mode == "base" then label = "AT BASE · SWITCH"
      else label = "GO TO · " .. tostring(detail or "far") end
      local st, det = where(r.id)
      local wtxt = (st == "aboard" and ("aboard " .. tostring(det or "a craft"))) or (st == "afoot" and ("on foot · " .. tostring(det or "?")))
        or (st == "base" and "at the base") or tostring(st or "")
      out[#out + 1] = { id = r.id, name = r.name, role = roleLetter(r), title = roleTitle(r), mode = mode, ok = ok, why = why, label = label,
                        where = wtxt, o2 = r.o2 or 1, hp = r.hp or 1, you = r.id == activeId(),
                        alert = recordAlerts and recordAlerts[r.id] or nil }
    end
  end
  return out
end

-- ── the one left behind, out of range (§2.2) ───────────────────────────────
-- A record on foot with no body breathes too, coarsely: at 1 Hz, by the
-- agency clock (game seconds, warp included), in CLOSED FORM, so a 10,000x
-- warp lands where 1x would. Pure: recordStep(rec, dt, amb) →
--   { o2, hp, tank (seconds drawn from the pack's tanks), blackout (s left)
--     | nil, dead = cause | nil }
--   amb: breathable (the air there), helmet, tanks (s of reserve in the pack),
--        rest (aboard or at the base: heals)
function recordStep(rec, dt, amb)
  amb = amb or {}
  local o2, hp = rec.o2 or 1.0, rec.hp or 1.0
  local out = { o2 = o2, hp = hp, tank = 0, blackout = rec.blackout }
  if dt <= 0 then return out end
  if amb.rest then
    out.hp = math.min(1.0, hp + P("heal_per_min") * dt / 60)
    out.blackout = nil
    return out
  end
  if airSource(amb.helmet ~= false, false, amb.breathable == true) ~= "suit" then
    out.blackout = nil
    return out
  end
  local left = dt
  if out.blackout then
    out.blackout = out.blackout - left
    if out.blackout <= 0 then out.blackout, out.dead = 0, "air" end
    return out
  end
  -- tanks first (drawAir's order), then the suit's own supply
  local tk = math.min(left, amb.tanks or 0)
  out.tank, left = tk, left - tk
  local secs = o2 * SUIT_AIR_SECS
  if left < secs then
    out.o2 = o2 - left / SUIT_AIR_SECS
    return out
  end
  out.o2 = 0
  local over = left - secs
  local grace = P("grace_suit")
  if over >= grace then out.blackout, out.dead = 0, "air"
  else out.blackout = grace - over end
  return out
end

local rt_t = -10
recordAlerts = {}    -- id → { level, text } (the station and the picker read these)
function recordTick(force)
  if not force and now() - rt_t < 1.0 then return end
  rt_t = now()
  local t = clock()
  local su = ref("suit")
  local active = activeId()
  for _, r in ipairs(everyone()) do
    if r.status == "afoot" and r.id ~= active and not (bodies[r.id] and bodies[r.id].valid ~= false) then
      local dt = t - (tonumber(r.leftAt) or t)
      if dt >= 1.0 or (force and dt > 0) then
        local wx, wy, wz = world_of(r)
        local breathable = false
        if su and su.breathableAt and wx then
          local ok, b = pcall(su.breathableAt, wx, wy, wz)
          breathable = ok and b == true
        end
        local tanks = tanksOf(packOf(r.id))
        local st = recordStep(r, dt, { breathable = breathable, helmet = r.helmet ~= false, tanks = tanks.reserve() })
        if st.tank > 0 then tanks.draw(st.tank) end
        r.o2, r.hp, r.blackout, r.leftAt = st.o2, st.hp, st.blackout, t
        save.set(key(r.id), r)
        bump()
        if st.o2 < 0.10 or st.blackout then
          recordAlerts[r.id] = { level = "danger", text = st.blackout and "LAST AIR" or string.format("O2 %d %%", math.floor(st.o2 * 100 + 0.5)) }
        elseif st.o2 < 0.25 then
          recordAlerts[r.id] = { level = "warn", text = string.format("O2 %d %%", math.floor(st.o2 * 100 + 0.5)) }
        else
          recordAlerts[r.id] = nil
        end
        if st.dead and r.client then clientDied(r.id, "air")
        elseif st.dead then kill(r.id, "air", "the suit ran out where they were left") end
      elseif not r.leftAt then
        patch(r.id, { leftAt = t })
      end
    end
  end
end

-- ── the queued switches (run in fixedUpdate) ───────────────────────────────
local hold_imp = 0       -- the impact monitor waits after a teleport
-- (a switch: half a second; a set-down at the base, `secs`: the crew's
-- home is a couple of metres over the ground and the drop is not a fall)
local function quiet_monitors(secs) hold_imp = math.max(hold_imp, now() + (secs or 0.5)) end
-- Teleports (the walker's ground net and field floor) say so: the snap is no fall.
function quietMonitors(secs) quiet_monitors(secs) end

-- Put the avatar at a world point in the physics tick: its TICK pose (frames
-- doc rule 3; planet_walker does the same), at rest.
local function place_avatar(a, x, y, z)
  if a.tickPos ~= nil and vec3 then a.tickPos = vec3(x, y, z) else a.x, a.y, a.z = x, y, z end
  a.vx, a.vy, a.vz = 0, 0, 0
end

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
    -- (graveyard2) a body mid-walk is where its walk has it, not where the
    -- record was last written; one lying on a bunk gets up where they stood
    -- (the record), clear of the bunk; and never into a wall
    local wb, wpx, wpy, wpz = nil, nil, nil, nil
    if cb and cb.walkPoint then wb, wpx, wpy, wpz = cb.walkPoint() end
    local sb = wb and space.body(wb)
    if sb and wb == r0.body then wx, wy, wz = sb.x + wpx, sb.y + wpy, sb.z + wpz end
    if wx then
      local fx, fy, fz = freeSpot(wx, wy, wz)
      bx, by, bz = fx, fy, fz
    end
  end
  free_avatar(nil)
  despawn_body(id)
  -- the view blends there (a swept move under 60 m, a short fade past it)
  local pc = ref("planet_camera")
  if pc and pc.handoff then pcall(pc.handoff, a.x, a.y, a.z, bx, by, bz) end
  place_avatar(a, bx, by, bz)
  a.vx, a.vy, a.vz = bvx, bvy, bvz
  a.visible = true
  set_active(id)
  patch(id, { status = "afoot", craft = false, anchor = false, pose = false })
  suit_in(id)
  quiet_monitors()
  drop_focus()
  local r = get(id)
  caption((r and r.name or "crew") .. " · on foot" .. (roleTitle and roleTitle(id) and (" · " .. roleTitle(id)) or ""))
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
    if v.hatchSpot then x, y, z = v.hatchSpot(q.uid, q.k) end
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


-- A base member stands up at the crew home (spawnAtBase).
local function do_base(q)
  local a = astro()
  local b = space and space.body and space.body(q.body)
  if not (a and b) then return end
  free_avatar(nil)
  despawn_body(q.id)
  local pc = ref("planet_camera")
  if pc and pc.handoff then pcall(pc.handoff, a.x, a.y, a.z, b.x + q.x, b.y + q.y, b.z + q.z) end
  place_avatar(a, b.x + q.x, b.y + q.y, b.z + q.z)
  a.visible = true
  set_active(q.id)
  patch(q.id, { status = "afoot", craft = false, body = q.body, x = q.x, y = q.y, z = q.z, anchor = false })
  suit_in(q.id)
  quiet_monitors(2.5)
  local r = get(q.id)
  caption((r and r.name or "crew") .. " · at the base")
  log_(string.format("crew: control → %s (#%d) at the base", r and r.name or "?", q.id))
end

-- Arrived behind the travel curtain: become them where they are.
local function do_arrive(q)
  local r = get(q.id)
  if not r then return end
  if q.fid then
    local fo = ref("flight_ops")
    local v = fo and fo.liveOf and fo.liveOf(q.fid)
    if v then
      queue[#queue + 1] = { kind = "craft", nid = v.node.id, id = q.id }
    else
      caption(tostring(q.where or "their craft") .. " could not be put back yet")
    end
    return
  end
  if r.status == "base" then
    local d, rx, ry, rz = home_spot()
    if d then do_base({ id = q.id, body = d, x = rx, y = ry, z = rz }) end
    return
  end
  local a = astro()
  local wx, wy, wz = world_of(r)
  if not (a and wx) then return end
  despawn_body(q.id)
  place_avatar(a, wx, wy, wz)
  a.visible = true
  set_active(q.id)
  patch(q.id, { status = "afoot", craft = false, anchor = false })
  suit_in(q.id)
  hold_imp = now() + 3.0
  caption((r.name or "crew") .. " · on foot")
  log_(string.format("crew: arrived as %s (#%d) on %s", r.name or "?", q.id, tostring(r.body)))
end

-- Leave for a far member: the one you are stays where they stand, then the curtain.
local function do_leave(q)
  local gm = ref("game_manager")
  if not (gm and gm.travelTo) then return end
  free_avatar(nil)
  hold_imp = now() + 120.0
  local fo = ref("flight_ops")
  if q.fid and fo and fo.requestRestore then pcall(fo.requestRestore, q.fid) end
  local wait = nil
  if q.fid then wait = function() return fo ~= nil and fo.liveOf ~= nil and fo.liveOf(q.fid) ~= nil end end
  local label = string.format("%s · %s", tostring(q.name or "crew"), tostring(q.where or q.body))
  local ok, why = gm.travelTo(q.body, q.x, q.y, q.z, label, function(arrived)
    queue[#queue + 1] = { kind = "arrive", id = q.id, fid = q.fid, where = q.where }
    if not arrived then caption("The ground there never came in · " .. label) end
  end, { wait = wait, base = q.base })
  if not ok then caption("Can't travel: " .. tostring(why)); hold_imp = now() + 1.0 end
end

local function run_queue()
  if #queue == 0 then return end
  local q = table.remove(queue, 1)
  if q.kind == "control" then do_control(q)
  elseif q.kind == "craft" then do_craft(q)
  elseif q.kind == "eva" then do_eva(q)
  elseif q.kind == "base" then do_base(q)
  elseif q.kind == "leave" then do_leave(q)
  elseif q.kind == "arrive" then do_arrive(q) end
end

-- ── status bookkeeping the controller calls ────────────────────────────────
function noteAboard(id, craft)
  patch(id, { status = "aboard", craft = craft or false, body = false, x = false, y = false, z = false })
end
function noteAfoot(id)
  local a = astro()
  local f = { status = "afoot", craft = false, leftAt = clock() }
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
  patch(id, { status = "afoot", craft = false, body = d, x = rx, y = ry, z = rz, pose = false })
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

-- ON A ROPE (scripts/rope_climb.lua): the member clipped on is held by the
-- line (kinematic, placed every tick), so the walker, the RCS Pack and the
-- impact monitor stand down as they do for a job.
local rope_by = nil
function setRopeHold(id) rope_by = id end
function held(id)
  if TREAT and TREAT.by == (id or activeId()) then return true end
  if rope_by ~= nil and rope_by == (id or activeId()) then return true end
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
  local ds = doseSeen[id]
  return { o2 = o2, air_s = air_s, breath = breath, hp = r.hp or 1.0, heat = r.heat or 0.0, hit = hit,
           downed = own, down = near,
           dose = tonumber(r.dose) or 0, dose_rising = (ds and now() - ds.t < 3.0 and (ds.rate or 0) > 0) or false,
           dose_rate = (ds and now() - ds.t < 3.0) and ds.rate or 0, dose_src = ds and ds.src or nil,
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
  explosion = "caught in an explosion", radiation = "radiation sickness",
  -- (missions M1) the causes the air, the caves and the weather hurt with
  air = "out of air", hypoxia = "hypoxia (air too thin to breathe)", gas = "bad air (a gas pocket)",
  cold = "exposure to the cold", hotair = "scalded by hot air",
}

-- ── RADIATION DOSE (deep-space A4; scripts/thermal.lua) ────────────────────
-- `rec.dose`: 0 none … 1 a lethal dose (the seventh cause, "radiation"). An
-- old record has none, and reads as 0: nothing is migrated. A reactor's cone
-- (vessel_thermal, twice a second) and a spent rod in someone's pack add to
-- it; the base heals it slowly (thermal.doseStep: half in two game days).
-- Shown on the HUD only once it is above zero (crew_alerts_hud's DOSE chip).
doseSeen = {}   -- id → { t (real), rate (a game second), src }: the chip's ▲
function doseOf(id)
  local r = get(id)
  return r and (tonumber(r.dose) or 0) or 0
end
-- (scn_vacuum) the suit's dosimeter: → rate (a game second, share of a
-- lethal dose; 0 unless a source dosed them in the last 3 s), dose so far, src
function doseNow(id)
  id = id or activeId()
  local ds = doseSeen[id]
  local live = ds and now() - ds.t < 3.0
  return live and (ds.rate or 0) or 0, doseOf(id), live and ds.src or nil
end
function addDose(id, amount, src, rate)
  local r = get(id)
  if not r or r.status == "dead" or (amount or 0) <= 0 then return nil end
  local d = (tonumber(r.dose) or 0) + amount
  doseSeen[id] = { t = now(), rate = rate or 0, src = src }
  if invincible() then d = math.min(d, 0.99) end
  r.dose = d
  put(r)
  if d >= 1 then
    kill(id, "radiation", src)
    local r2 = get(id)
    -- rescued, not killed (CREW SAFETY): they wake at the base past the worst of it
    if r2 and r2.status ~= "dead" and (tonumber(r2.dose) or 0) >= 1 then r2.dose = 0.7; put(r2) end
  end
  return d
end

-- The dose step for every member, over `gs` game seconds (crew's heal pass):
-- healing at the base, a spent rod in a pack dosing whoever carries it.
local function dose_tick(gs)
  if gs <= 0 then return end
  local TH = ref("thermal")
  local inv = ref("inventory")
  if not TH then return end
  for _, r in ipairs(roster()) do
    if r.status ~= "dead" then
      local d = tonumber(r.dose) or 0
      local hot = 0
      if inv and inv.itemCount and r.status ~= "base" then hot = inv.itemCount(packOf(r.id), "spentRod") or 0 end
      if hot > 0 then
        local rate = hot * (TH.SPENT_DOSE or 0)
        addDose(r.id, rate * gs, "a spent rod in the pack", rate)
      elseif d > 0 and r.status == "base" then
        local nd = TH.doseStep(d, 0, true, gs)
        if math.abs(nd - d) > 1e-6 or nd == 0 then
          r.dose = nd
          save.set(key(r.id), r)
          bump()
        end
      end
    end
  end
end

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
    if bc and bc.show and r then bc.show("A NEW VOLUNTEER", "The agency has a new volunteer: " .. r.name, 6.0, "quiet") end
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

-- Rescue instead (death off): blacked out, they wake at base, hurt (hp at
-- most rescue_hp), for the fee. `free` (invincible, with no wreck to stand
-- by): home for nothing, unhurt.
function rescueHp(hp, free)
  if free then return 1.0 end
  return math.max(0.05, math.min(hp or 1.0, P("rescue_hp")))
end
lastRescue = nil
local function rescue(id, cause, free)
  local r = get(id)
  -- the controlled member, still riding (heat in an open seat): out of the
  -- seat first, so they come home rather than the record going on ahead
  local ride = id == activeId() and avatarCraft() or nil
  if ride and ride.standDown then pcall(ride.standDown, ride.node) end
  local is_avatar = id == activeId() and not avatarCraft()
  local co = ref("company")
  local fo = ref("flight_ops")
  local fee = free and 0 or math.floor(P("rescue_fee"))
  local paid = fee > 0 and co and co.afford and co.afford(fee) and co.spend and co.spend(fee, "crew rescue") or false
  local hp = rescueHp(r and r.hp, free)
  if TREAT and (TREAT.target == id or TREAT.by == id) then cancel_treat(id == TREAT.target and "they were rescued" or "you were rescued") end
  if r and r.downed then r.downed = nil; put(r) end
  local v, uid, slot = craftOf(id)
  if v and v.seatMember then v.seatMember(uid, slot, nil) end
  despawn_body(id)
  despawn_doll(id)
  patch(id, { hp = hp, heat = 0, o2 = 1.0 })
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
  if bc and bc.show and r then
    local text = free and string.format("%s is unhurt (%s). The agency brought them back to the base.", r.name, CAUSE_TEXT[cause] or cause)
      or string.format("%s was knocked out (%s) and is hurt: %d%% health. The agency brought them back to the base%s.",
        r.name, CAUSE_TEXT[cause] or cause, math.floor(hp * 100 + 0.5),
        paid and string.format(" (rescue: %s)", (co and co.money) and co.money(fee) or ("$" .. fee)) or "")
    bc.show("CREW RESCUED", text, 6.0, "result")
  end
  lastRescue = { id = id, cause = cause, hp = hp, fee = paid and fee or 0, t = now() }
  log_(string.format("crew: #%d rescued (%s): hp %.2f, fee %s", id, tostring(cause), hp, paid and ("$" .. fee) or "none"))
  bump()
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
  if r.client then return clientDied(id, cause, detail) end     -- (missions N1) a survivor: not one of ours
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
  local was_client = r.status == "client" or r.client ~= nil
  r.status = "dead"
  r.task = nil
  r.died = { st = st, date = date, cause = cause, detail = detail, body = d,
             craft = (v and v.craftName) or opts.craft, remains = rem, crate = crate, bled = opts.bled or nil }
  if d and x then
    local b = space.body(d)
    if b then r.died.x, r.died.y, r.died.z = x - b.x, y - b.y, z - b.z end
  end
  put(r)
  -- (the setting: Settings ▸ Agency / the new-save panel, `deathRep`)
  local co = ref("company")
  if deathRep() and co and co.addRep then
    pcall(co.addRep, -2, (was_client and "client lost: " or "astronaut lost: ") .. r.name)
  end
  -- (a detail that names who did it reads on: "shot by Dana Okafor, 30 m")
  local text = string.format("%s was killed: %s%s", r.name, CAUSE_TEXT[cause] or cause,
    detail and ((tostring(detail):sub(1, 3) == "by " and " " or ", ") .. detail) or "")
  lastDeath = { id = id, name = r.name, cause = cause, text = text, t = now(), x = x, y = y, z = z }
  local bc = ref("big_caption")
  if bc and bc.show then bc.show("ASTRONAUT LOST", text, 6.0, "alarm") end
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
  -- the suit taking it: a visor crack and a hiss where it happened (sfx), on
  -- top of the HUD's HIT warning
  local fx = amount >= 0.05 and ref("sfx")
  if fx and fx.fail then
    local a = (id == activeId()) and astro() or nil
    pcall(fx.fail, "suit_damage", { node = (not opts.x) and a or nil, x = opts.x, y = opts.y, z = opts.z })
  end
  bump()
  if hp <= 1e-6 then
    local o = {}
    for k, v in pairs(opts) do o[k] = v end
    o.over = amount - (r.hp or 1)
    kill(id, cause or "shot", detail, o)
    return 0
  end
  patch(id, { hp = hp, hurtBy = cause or "shot" })     -- (M1: the medic names it)
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
      r.name, CAUSE_TEXT[cause] or cause, detail and (", " .. detail) or "", math.floor(secs + 0.5)), 6.0, "alarm")
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
    -- (missions M1) at the base someone is looking after them: an old save's
    -- Recall brought members home still bleeding, and they died there
    if dn and r.status == "base" then
      r.downed = nil
      r.hp = math.max(r.hp or 0, P("rescue_hp"))
      put(r)
      log_(string.format("crew: #%d is at the base: stabilised (%d%%)", r.id, math.floor(r.hp * 100 + 0.5)))
      dn = nil
    end
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
    bc.show("ASTRONAUT REVIVED", string.format("%s is back on their feet (%d%%). Get them home to heal.", r.name, math.floor(hp * 100 + 0.5)), 5.0, "result")
  else
    caption(string.format("%s treated — %d%%", r.name, math.floor(hp * 100 + 0.5)))
  end
  log_(string.format("crew: #%d %s by #%d, hp %.2f", T.target, T.kind == "revive" and "revived" or "healed", T.by, hp))
  bump()
end

-- ── the monitor: impact, crush, heat (the avatar on foot; heat aboard) ─────
-- (the death curtain's numbers, s; frames under calm_ms in a row, calm_n,
-- say the world has caught up)
-- Is the controlled member dead and still on screen (the hold on the fallen,
-- before control passes on)? (playtest 11-12b: "on the death screen you can
-- recover your own pack": the pack crate dropped at their feet offered E to
-- the dead, and taking it put the pack in the dead member's container, lost.
-- salvage asks this; the crate waits for someone alive.)
function dying()
  if MON and MON.dying then return true end
  local id = activeId and activeId()
  local r = id and get(id) or nil
  return r ~= nil and r.status == "dead"
end
DEATH_FADE = { out = 0.5, hold_min = 0.5, hold_max = 3.5, inn = 0.5, calm_ms = 45, calm_n = 4 }
deathCurtain = nil   -- { phase = "black" | "in", t0, calm, text } while it is up
-- (the game clock: a paused or loading game holds the curtain where it is)
local function wall() return now() end
-- How black the picture is now (0..1), and the death's line to show on it.
function curtainAlpha()
  local m = MON.dying
  local w = wall()
  local function ease(k) k = math.max(0, math.min(1, k)) return k * k * (3 - 2 * k) end
  if m and m.fade then return ease((w - m.fade) / DEATH_FADE.out), lastDeath and lastDeath.text end
  local c = deathCurtain
  if not c then return 0, nil end
  if c.phase == "black" then return 1, c.text end
  return 1 - ease((w - c.t0) / DEATH_FADE.inn), c.text
end
-- Each FRAME (lateUpdate, its dt the frame's): frames under calm_ms in a
-- row say the world has caught up; a fixed tick can't see a long frame (it
-- runs several of them inside it).
local function curtain_calm(fdt)
  local c = deathCurtain
  if not (c and c.phase == "black") then return end
  if (fdt or 0) * 1000 < DEATH_FADE.calm_ms then c.calm = c.calm + 1 else c.calm = 0 end
end
-- Each tick: black until calm (or hold_max), then the fade back in.
local function curtain_tick()
  local c = deathCurtain
  if not c then return end
  local w = wall()
  if c.phase == "black" then
    local age = w - c.t0
    if (age >= DEATH_FADE.hold_min and c.calm >= DEATH_FADE.calm_n) or age >= DEATH_FADE.hold_max then
      c.phase, c.t0 = "in", w
      c.held = age
    end
  elseif w - c.t0 >= DEATH_FADE.inn then
    deathCurtain = nil
  end
end
local function curtain_draw()
  local a, text = curtainAlpha()
  if a <= 0.001 or not (draw and draw.rect and camera and camera.screenRect) then return end
  -- (scnfix) a scenario's fail screen owns the black once it is up: it took
  -- over from this curtain at the curtain's own black (scenario_ui
  -- failAgeFor), so the two fades never stack
  local su = ref("scenario_ui")
  if su and su.failScreenUp and su.failScreenUp() then return end
  local vx, vy, vw, vh = camera.screenRect()
  if not vw then return end
  draw.rect(vx - 2, vy - 2, vw + 4, vh + 4, 0, 0, 0, a)
  if text and draw.text then
    draw.text(vx + vw * 0.5, vy + vh * 0.44, "ASTRONAUT LOST", 30, 0.92, 0.36, 0.30, a, "center")
    draw.text(vx + vw * 0.5, vy + vh * 0.44 + 44, text, 18, 0.88, 0.86, 0.82, a, "center")
  end
end

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
    -- THE DEATH CURTAIN (playtest 2026-11-12: "the game often freezes when an
    -- astronaut dies"). The control passing on puts the next member at the
    -- Command Centre (or on another body): the view jumps there, and the
    -- world catching up with it — ground and props streamed in round the
    -- base, the origin following the camera — held one frame for 0.2-0.7 s
    -- (physfixprobe deaths: 207 ms near the base, 699 ms from 1.5 km out,
    -- the rest of untimed, no script in it). So after the hold the picture
    -- fades to black, the handoff happens behind it, and it stays black
    -- until the frames are calm again; then it fades back in.
    if now() >= m.t1 and not m.fade then m.fade = wall() end
    if m.fade and wall() - m.fade >= DEATH_FADE.out then
      MON.dying = nil
      -- (the suit's parts come back; the walker re-shows the root)
      for _, ch in ipairs(MON.hid or {}) do if ch.valid ~= false then ch.visible = true end end
      MON.hid = nil
      local w = wall()
      deathCurtain = { phase = "black", t0 = w, calm = 0, text = lastDeath and lastDeath.text or nil }
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
  -- the walker's own impacts (planet_walker impactSeq/impactSpeed): one
  -- judged per touchdown, the speed INTO the ground met
  local pw0 = ref("planet_walker")
  local wseq = pw0 and pw0.impactSeq
  if ride or now() < hold_imp or held(id) then
    MON.vx = nil
    MON.hs1 = nil
    MON.fall, MON.pinned, MON.crush_t = 0, false, 0
    MON.air, MON.peak = 0, 0
    MON.imp_seq = wseq
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
        if wseq ~= nil then
          -- THE IMPACT, AS THE WALKER MEASURED IT (playtest 2026-11-05: "fall
          -- damage extremely annoying and dangerous"): the velocity of the
          -- last frame before the first ground contact against the normal of
          -- the ground met. The rule below it judged the fastest the body had
          -- fallen while the walker's probe called it airborne, so a slide
          -- down a steep face counted as a drop of its whole height, and a
          -- landing on a slope as one on the flat.
          if MON.imp_seq ~= nil and wseq ~= MON.imp_seq then down = pw0.impactSpeed or 0 end
          MON.imp_seq = wseq
          MON.air, MON.peak = 0, 0
        elseif not on_ground then
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
        -- (the speed HELD the two frames before, not one frame's: a single
        -- frame's spike along the ground — a seam's push at a touchdown, a
        -- stalled frame's catch-up — then back to a walk, read as a crash;
        -- a crash is speed carried in, and lost)
        local hs0 = len(h0x, h0y, h0z)
        local had = math.min(hs0, MON.hs1 or hs0)
        MON.hs1 = hs0
        local side = math.max(0, had - len(h1x, h1y, h1z) - P("walk_dv"))
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
      -- (the hit the screen and the chips show, and what it was)
      lastHit[id] = { t = now(), amount = loss, cause = "impact", hp = hp, dv = dv }
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
  for _, r in ipairs(everyone()) do
    if r.status == "afoot" and r.id ~= active then
      local b = bodies[r.id]
      if b and b.valid ~= false then
        if len(b.x - fx, b.y - fy, b.z - fz) > P("body_range") then
          local d, x, y, z = rel(b.x, b.y, b.z)
          patch(r.id, { body = d, x = x, y = y, z = z, leftAt = clock() })
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
local dose_st = nil   -- the game clock at the last dose pass
local function heal(dt)
  heal_t = heal_t + dt
  if heal_t < 5 then return end
  local s = heal_t
  heal_t = 0
  -- (dose by GAME time: warp heals and doses faster, as it ages everything)
  local gst = space and space.time and space.time() or nil
  if gst then
    if dose_st and gst > dose_st then dose_tick(math.min(gst - dose_st, 86400)) end
    dose_st = gst
  end
  for _, r in ipairs(roster()) do
    if (r.status == "base" or r.status == "aboard") and (r.hp or 1) < 1 then
      r.hp = math.min(1, (r.hp or 1) + P("heal_per_min") * s / 60)
      save.set(key(r.id), r)
    end
  end
end

-- ── (missions M1) THE MEDICAL BAY: treatment, and the roster's Recall ───────
-- (pure) what a record needs from a medic: { hp, dose, downed, heat, o2, any }
function medNeeds(r)
  if type(r) ~= "table" or r.status == "dead" then return nil end
  local n = { hp = tonumber(r.hp) or 1, dose = tonumber(r.dose) or 0, downed = r.downed ~= nil,
              heat = tonumber(r.heat) or 0, o2 = tonumber(r.o2) or 1 }
  n.any = n.downed or n.hp < 0.995 or n.dose > 0.005 or n.heat > 0.05
  return n
end
-- The cause a medic names: the wound they went down with, the last hit, the
-- record's own (hurt keeps it), a dose, the heat. nil: nothing to name.
function lastCause(id)
  local r = get(id)
  if not r then return nil end
  if type(r.downed) == "table" and r.downed.cause then return r.downed.cause end
  local lh = lastHit[id]
  if lh and lh.cause then return lh.cause end
  if r.hurtBy then return r.hurtBy end
  if (tonumber(r.dose) or 0) > 0.05 then return "radiation" end
  if (tonumber(r.heat) or 0) > 0.2 then return "heat" end
  return nil
end
-- MEDICAL TREATMENT (scripts/medical.lua; Ty 2026-11-11: "when you go in
-- there and talk to them they heal you for free"): everything back — hp, the
-- radiation dose, a downed wound, the heat, a blackout, a full suit. Free,
-- whatever the CREW SAFETY. → before = { hp, dose, downed, heat, cause, any }
-- | nil, why. (The passive heal at the base, `heal`, stays for the field.)
lastMed = nil
function medTreat(id, by)
  local r = get(id)
  if not r then return nil, "nobody there" end
  if r.status == "dead" then return nil, (r.name or "they") .. " is dead" end
  local n = medNeeds(r)
  local before = { hp = n.hp, dose = n.dose, downed = n.downed, heat = n.heat, cause = lastCause(id), any = n.any }
  r.hp, r.dose, r.heat, r.downed, r.blackout, r.hurtBy = 1.0, 0, 0, nil, nil, nil
  r.o2, r.breath = 1.0, 1.0
  put(r)
  lastHit[id], doseSeen[id] = nil, nil
  if TREAT and TREAT.target == id then cancel_treat("the medic took over") end
  lastMed = { id = id, by = by, before = before, t = now() }
  log_(string.format("crew: #%d treated at the Medical Bay%s (hp %.2f, dose %.2f%s, %s)", id, by and (" by " .. tostring(by)) or "",
    before.hp, before.dose, before.downed and ", down" or "", tostring(before.cause)))
  return before
end

-- THE RECALL (the roster panel's Recall: a shuttle fetches someone on foot).
-- The panel called crew.recall, which did not exist, and fell back on a bare
-- patch to status "base": a DOWNED member came home still bleeding (down_
-- monitor ticks every record) and died at the base. Someone who can't walk
-- to a pickup isn't recalled; the reason is a sentence.
function recallWhyNot(id)
  local r = get(id)
  if not r then return "no such crew member" end
  if r.status == "dead" then return (r.name or "they") .. " is dead" end
  if r.client then return "not one of ours: the client's own people fetch them" end
  if r.status ~= "afoot" then return (r.name or "they") .. " is not out on foot" end
  if id == activeId() then return "you are " .. (r.name or "them") .. ": walk or fly home" end
  if r.downed then return (r.name or "they") .. " can't walk to a pickup: carry them home, or treat them with a Medkit first" end
  return nil
end
function recall(id)
  local why = recallWhyNot(id)
  if why then return false, why end
  local r = get(id)
  if r.task then cancelTask(id, "recalled") end
  despawn_body(id)
  patch(id, { status = "base", craft = false, body = false, x = false, y = false, z = false, anchor = false,
              pose = false, gesture = false, follow = false })
  log_(string.format("crew: #%d recalled to the base", id))
  return true, nil
end

-- ── (missions N1) SURVIVORS AND CARRYING ────────────────────────────────────
-- A SURVIVOR is a crew record with `client` (the contract's id, or true),
-- kept OFF the roster in `crew.clients`: not on the roster panel, not
-- counted by living() or hireFee, never chosen by handoff or the switcher.
-- On foot they are a CrewBody like anyone (body_sync), they breathe from
-- their suit (recordTick), a Medkit treats them (treatWhyNot reads any
-- record), and lying downed they do not bleed out (down_monitor walks the
-- roster: a rescue's clock is the contract's). A survivor who dies goes by
-- clientDied: no memorial, the death-rep rule of crew.deathRep.
-- CARRIED (Ty: "strap them on your back which weighs you down"):
-- `status = "carried"`, `carriedBy`, no body; the carrier's walk takes
-- CARRY.kg more (planet_walker.extraLoad through its encumbrance curve), half
-- with a Stretcher in the pack. E (the context menu) sets them down in front;
-- F at a craft with a free seat seats them (seatCarried). FOLLOWING: a
-- survivor who can walk (hp ≥ CARRY.follow_hp, not down) walks 2.5 m behind
-- the avatar (crew_body.steerSelf re-aimed at 2 Hz) and boards when you do.
CARRY = { kg = 60, stretcher_kg = 30, reach = 2.2, follow_hp = 0.35, behind = 2.5, follow_far = 40 }
local function client_ids() local t = save.get("crew.clients"); return type(t) == "table" and t or {} end
function clients()
  local out = {}
  for _, id in ipairs(client_ids()) do local r = get(id); if r then out[#out + 1] = r end end
  return out
end
-- the roster and the survivors (what has a body, breathes, is drawn)
function everyone()
  local out = roster()
  for _, r in ipairs(clients()) do out[#out + 1] = r end
  return out
end
function isClient(id) local r = get(id); return r ~= nil and r.client ~= nil end
-- a survivor: a name (or one rolled), and fields (client = contract id,
-- body/x/y/z on foot, hp, downed = { cause } …) → id
function newClient(name, fields)
  ensure()
  fields = fields or {}
  local id = (save.get("crew.seq") or 0) + 1
  save.set("crew.seq", id)
  -- (npc: gy3's scenario cast flag, which the switcher and the picker honour too)
  local rec = newRecord(id, name or nameFor(id * 7919 + 13, 1), { status = "afoot", role = "civilian", client = true, npc = true,
                                                           title = "Survivor" })   -- (the tag over them: roleTitle)
  for k, v in pairs(fields) do rec[k] = v end
  if rec.downed == true then rec.downed = { cause = "impact", left = 0, secs = 0 } end
  put(rec)
  local t = client_ids()
  t[#t + 1] = id
  save.set("crew.clients", t)
  log_(string.format("crew: survivor %s (#%d) for %s", rec.name, id, tostring(rec.client)))
  return id
end
function removeClient(id)
  if carrying() == id then save.set("crew.carrying", false) end
  despawn_body(id)
  local keep = {}
  for _, x in ipairs(client_ids()) do if x ~= id then keep[#keep + 1] = x end end
  save.set("crew.clients", keep)
  save.set(key(id), false)
  bump()
  return true
end
lastClientDeath = nil
function clientDied(id, cause, detail)
  local r = get(id)
  if not (r and r.client) or r.status == "dead" then return false end
  if carrying() == id then save.set("crew.carrying", false) end
  despawn_body(id)
  patch(id, { status = "dead", died = { cause = cause, detail = detail, t = clock() }, downed = false, carriedBy = false, follow = false })
  lastClientDeath = { id = id, name = r.name, cause = cause, client = r.client, t = now() }
  -- (D1) a client lost costs the company as one of ours does, when it does
  local co = ref("company")
  if deathRep() and co and co.addRep then co.addRep(-2, "client lost: " .. tostring(r.name)) end
  local bc = ref("big_caption")
  if bc and bc.show then bc.show("SURVIVOR LOST", string.format("%s died: %s", tostring(r.name), CAUSE_TEXT[cause] or tostring(cause)), 5.0, "alarm") end
  log_(string.format("crew: survivor #%d died (%s)", id, tostring(cause)))
  return true
end

-- (pure) the load a carried person puts on the carrier, kg
function carryLoad(stretcher) return stretcher and CARRY.stretcher_kg or CARRY.kg end
-- (pure) what a carry refuses, as a sentence (nil: allowed). action "rope"
-- (climbing a rope; a Stretcher allows a slow descent), "ladder" (v = how
-- high the craft's hatch is: the hatch only within 1.2 m of a floor), "jump"
-- (v = the height, m: nothing over 0.4)
function carryRefusal(action, v, stretcher)
  if action == "rope" then
    if v == "down" and stretcher then return nil end
    return stretcher and "with someone on a stretcher, only down a rope (slowly)" or "you can't climb a rope with someone on your back"
  end
  if action == "ladder" then
    if (tonumber(v) or 99) > 1.2 then return "no ladder with someone on your back: their hatch must be within 1.2 m of the ground" end
    return nil
  end
  if action == "jump" then
    if (tonumber(v) or 0) > 0.4 then return "not with someone on your back" end
    return nil
  end
  return nil
end
function carrying() local c = save.get("crew.carrying"); return type(c) == "number" and c or nil end
local function stretcher_on(id)
  local inv = ref("inventory")
  if not (inv and inv.itemCount and id) then return false end
  local ok, n = pcall(inv.itemCount, packOf(id), "stretcher")
  return ok and (n or 0) > 0
end
local carry_load_set = false
local function apply_load()
  local pw = ref("planet_walker")
  if not pw then return end
  local who = carrying()
  local kg = who and carryLoad(stretcher_on(activeId())) or 0
  if (pw.extraLoad or 0) ~= kg then pw.extraLoad = kg end
  carry_load_set = kg > 0
end
function carryWhyNot(who)
  local by = activeId()
  local r = get(who)
  if not (by and r) then return "nobody there" end
  if who == by then return "you can't carry yourself" end
  if r.status == "dead" then return (r.name or "they") .. " is dead" end
  if r.status ~= "afoot" then return "only someone on the ground" end
  if carrying() then return "you are carrying someone already" end
  if avatarCraft() then return "step out first" end
  local pw = ref("planet_walker")
  if pw and pw.onFoot == false then return "on foot only" end
  if not (r.downed or r.client or (r.hp or 1) < CARRY.follow_hp) then return (r.name or "they") .. " can walk" end
  local d = dist_to(by, who)
  if not d then return "out of range" end
  if d > CARRY.reach then return string.format("walk up to them (%.0f m away)", d) end
  return nil
end
function carry(who)
  local why = carryWhyNot(who)
  if why then return false, why end
  local r = get(who)
  despawn_body(who)
  if TREAT and TREAT.target == who then cancel_treat("picked up") end
  patch(who, { status = "carried", carriedBy = activeId(), pose = false, gesture = false, follow = false })
  save.set("crew.carrying", who)
  apply_load()
  caption(string.format("CARRYING %s — right-click yourself to set them down", string.upper(r.name or "")))
  log_(string.format("crew: #%s carries #%d", tostring(activeId()), who))
  return true
end
-- Set the carried person down in front of the avatar (on the ground, lying
-- if they are down). → true | false, why
function putDown()
  local who = carrying()
  if not who then return false, "carrying nobody" end
  local a = astro()
  local r = get(who)
  save.set("crew.carrying", false)
  if not (a and r) then apply_load() return false, "nowhere to set them" end
  local pc = ref("planet_camera")
  local fx, fy, fz = 0, 0, 0
  if pc and pc.fwd_x then fx, fy, fz = pc.flat_x or pc.fwd_x, pc.flat_y or pc.fwd_y, pc.flat_z or pc.fwd_z end
  local x, y, z = a.x + fx * 1.0, a.y + fy * 1.0, a.z + fz * 1.0
  if freeSpot then x, y, z = freeSpot(x, y, z) end
  local d, rx, ry, rz = rel(x, y, z)
  patch(who, { status = "afoot", carriedBy = false, body = d, x = rx, y = ry, z = rz, leftAt = clock() })
  spawn_body(who, x, y, z)
  apply_load()
  log_(string.format("crew: #%d set down", who))
  return true
end
-- F at a craft with someone on your back: they take its free seat.
function seatCarried(v)
  local who = carrying()
  if not who then return false, "carrying nobody" end
  if not (v and v.seatMember) then return false, "not a craft" end
  local uid, slot = nil, nil
  if v.freeSeat then uid, slot = v.freeSeat(nil) end
  if not uid then return false, "no free seat" end
  local ok, why = v.seatMember(uid, slot, who)
  if not ok then return false, why end
  save.set("crew.carrying", false)
  patch(who, { status = "aboard", craft = v.craftName or false, carriedBy = false, body = false, x = false, y = false, z = false })
  apply_load()
  return true
end
function followWhyNot(who)
  local r = get(who)
  if not r then return "nobody there" end
  if r.status ~= "afoot" then return "only someone on foot" end
  if r.downed or (r.hp or 1) < CARRY.follow_hp then return (r.name or "they") .. " can't walk: carry them" end
  if not r.client then return "crew go where you send them" end
  return nil
end
function follow(who, on)
  if on == false then return patch(who, { follow = false }) end
  local why = followWhyNot(who)
  if why then return false, why end
  return patch(who, { follow = true })
end
-- (pure) where a follower heads: `behind` m back along the avatar's flat
-- facing (fx, fz in its ground plane), or nil when they are close enough
function followPoint(ax, ay, az, fx, fy, fz, bx, by, bz, behind)
  behind = behind or CARRY.behind
  local tx, ty, tz = ax - fx * behind, ay - fy * behind, az - fz * behind
  local d = len(bx - ax, by - ay, bz - az)
  if d < behind + 0.8 then return nil, d end
  return { x = tx, y = ty, z = tz }, d
end
local carry_t = 0
function carry_tick(dt)
  local who = carrying()
  if not who and carry_load_set then apply_load() end
  carry_t = carry_t + dt
  if carry_t < 0.5 then return end
  carry_t = 0
  if who then
    local r = get(who)
    if not r or r.status ~= "carried" then save.set("crew.carrying", false); apply_load()
    elseif avatarCraft() and r.carriedBy == activeId() then
      -- boarded with them on your back: they take a free seat (F at the hatch), else down outside
      local ok = seatCarried(avatarCraft())
      if not ok then putDown() end
    elseif r.carriedBy ~= activeId() then putDown()       -- the carrier is not the avatar now
    else
      -- the record rides the carrier: refs, the bay's admit and a save find them
      local a = astro()
      if a then
        local d, x, y, z = rel(a.x, a.y, a.z)
        if d then r.body, r.x, r.y, r.z = d, x, y, z; save.set(key(who), r) end
      end
      apply_load()
    end
  end
  -- followers: 2 Hz, a point behind the avatar; aboard with you when you board
  local a = astro()
  local v = avatarCraft()
  for _, r in ipairs(clients()) do
    if r.follow and r.status == "afoot" then
      local b = bodies[r.id]
      local cb = b and b.valid ~= false and b.getScript and b:getScript("crew_body") or nil
      if v and b then
        if len(b.x - v.node.x, b.y - v.node.y, b.z - v.node.z) < 25 then
          local ok = board(r.id, v)
          if ok then patch(r.id, { follow = false }) end
        end
      elseif a and cb and cb.steerSelf and not (ref("planet_walker") and ref("planet_walker").onFoot == false) then
        local pc = ref("planet_camera")
        local fx, fy, fz = 0, 0, 0
        if pc and pc.fwd_x then fx, fy, fz = pc.flat_x or pc.fwd_x, pc.flat_y or pc.fwd_y, pc.flat_z or pc.fwd_z end
        local p, d = followPoint(a.x, a.y, a.z, fx, fy, fz, b.x, b.y, b.z)
        if d and d > CARRY.follow_far then patch(r.id, { follow = false })
        elseif p then
          local dn, rx, ry, rz = rel(p.x, p.y, p.z)
          if dn then pcall(cb.steerSelf, dn, rx, ry, rz, { arrive = 0.6 }) end
        elseif cb.steerStop and cb.walking and cb.walking() then pcall(cb.steerStop) end
      end
    end
  end
end

-- ── the manager ────────────────────────────────────────────────────────────
-- WHAT A DEATH AND A HANDOFF FIRST DRAW, loaded ahead (playtest 2026-11-12:
-- "the game often freezes when an astronaut dies"). The next member's face
-- is put on the avatar as the control passes (face.lua swaps the head and
-- hair models), the fallen's Remains and their pack's crate are spawned:
-- a model drawn for the first time is read and imported on that frame, and
-- one head took 2.15 s of frameSettle in one frame (physfixprobe deaths,
-- bled-out: "imported models/astronaut/faces/head_2.glb"). In the
-- background, once a world is up: every head and hair style the roster
-- can wear, the Remains, the crate.
PRELOAD = { "models/astronaut/faces/cap.glb", "models/astronaut/astronaut_male_lod1.glb", "models/parts/cargo.glb" }
for i = 1, 8 do PRELOAD[#PRELOAD + 1] = "models/astronaut/faces/head_" .. i .. ".glb" end
for _, h in ipairs({ "braid", "bun", "buzz", "crop", "curls", "halfup", "long", "lowtail", "receding", "shoulder",
                     "side", "swept", "tail", "wavy" }) do
  PRELOAD[#PRELOAD + 1] = "models/astronaut/faces/hair_" .. h .. ".glb"
end
preloaded = nil      -- nil | "pending" | "done" (probes)
local function preload_faces()
  if preloaded or not (assets and assets.preload) then return end
  preloaded = "pending"
  pcall(assets.preload, PRELOAD, function(failed)
    preloaded = "done"
    if failed and #failed > 0 then log_("crew: could not preload " .. tostring(failed[1])) end
  end)
end

function start(node)
  ensure()
  quiet_monitors(3.0)
  preload_faces()
  local n = save.get("crew.notice")
  if type(n) == "string" and n ~= "" then
    local bc = ref("big_caption")
    if bc and bc.show then
      bc.show("THE CREW", n, 7.0, "info")
      save.set("crew.notice", false)
    end
  end
end

-- A save migrated while inventory's alias was missing moves its pack the
-- first frame the alias is there (then this costs one flag test).
function update(node, dt)
  if not ensured then ensure() end
  -- a retrain that has run its day becomes the member's role
  roles_t = (roles_t or 0) + (dt or 0.016)
  if roles_t > 2.0 then roles_t = 0; finish_retrains() end
  -- the Medkit's work: in the frame, where the avatar and the bodies are
  -- read at the same moment (a physics tick sees them a rails carry apart)
  treat_tick(dt or 0.016)
  carry_tick(dt or 0.016)       -- (missions N1)
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
  recordTick()
  curtain_tick()
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
  curtain_calm(dt)
  curtain_draw()
end

-- Probes and tests: the module's live tables.
function _debug() return { bodies = bodies, dolls = dolls, queue = queue, mon = MON, prev = prev } end
