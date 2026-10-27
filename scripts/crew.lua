-- CREW — the agency's astronauts: who they are, where they are, what they
-- carry and what they are doing (docs/crew-and-items.md §2, §4, §6.3).
--
-- One save key per member, `crew.m.<id>`, plus a few roster keys:
--
--   crew.roster    ids in hire order, the dead included (the memorial reads it)
--   crew.seq       the last id issued
--   crew.active    the id the `Astronaut` node is now (false: unbound)
--   crew.offers    the applicants on the board
--   crew.version   the migration stamp (VERSION below)
--   crew.death     true: death is real; false: "rescue instead"
--
-- Each member's pack is an ordinary inventory container, `crew:<id>`;
-- inventory's `"astro"` alias resolves to the active member's (WS3).
--
-- This file is a manager on the CrewLib node (spawned by game_manager and
-- build_host when the scene has none) and, at the same time, a rulebook that
-- loads in luajit: everything it touches is `save`, `findScript`, `find` and
-- `time`, which a test stubs.
--
-- THE INTERFACE (other workstreams code against this; keep it stable):
--   roster() → {rec…}            get(id) → rec|nil         activeId() → id|nil
--   packOf(id) → "crew:"..id     where(id) → status, detail
--   hire(i) → id|nil, why        offers() → {{name, cost}…}   rename(id, s) → ok, why
--   control(id) → ok, why        eva(id, {stay, confirmed}) → ok, why, warn
--   board(id, v, uid?, slot?) → ok, why
--   quickSwap() → ok             switchList() → {{kind, id|v, name, dist}…}
--   aboard(v) → {{id, uid, slot, commander}…}   dollOf(id) → node|nil   bodyOf(id) → node|nil
--   setTask(id, task) → ok, why  task(id) → task|nil   cancelTask(id, why) → ok
--   held(id) → bool              (locked at a task: movement code stands down)
--   alerts(id) → {o2, air_s, breath, hp, heat, fall, pinned, blackout, cabin}
--   airSource(helmet, headUnder, breathable) → "suit"|"hold"|"ambient"
--   tanksOf(pack) / drawAir(o2, dt, tanks)   the suit air rule (built-in + O2 tanks)
--   evaCheck(id) → ok, why, warn (warn: allowed, but ask first — no RCS Pack in space)
--   memorial() → {…}             deathOn() → bool          setDeath(on)
--   patch(id, fields)            merge fields into a record (false clears; bumps version)
--   onEvaInSpace() → bool, id    (rails warp is refused while true)
--   version                      bumps on any change (panels poll it)
--
-- Slice 1 / 1b run on ONE astronaut (member #1, always the avatar). The
-- multi-crew pieces (CrewBody, dolls, seats by slot, switching) answer with
-- the single-astronaut behaviour until slice 2 fills them in.

defaults = {
  -- One-time hire fee: base + step × (living roster − 3), capped.
  -- (2026-10-26: was 1,500 / 600 / 6,000 — a crew lost with a rocket should be
  -- a setback the ground game can pay for, not a wall.)
  hire_base = 1000,
  hire_step = 400,
  hire_cap = 4000,
}

VERSION = 1
version = 0

local function P(k) return (params and params[k]) or defaults[k] end
local function bump() version = (version or 0) + 1 end

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

local function copy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = copy(v) end
  return o
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
          target.st = type(target.st) == "table" and target.st or {}
          target.st.crew = { rec.id }
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

function migrate()
  if save.get("crew.version") ~= nil then return false end
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

function packOf(id)
  return "crew:" .. tostring(id or activeId() or 1)
end

-- Merge fields into a record (other crew scripts use this; panels poll
-- `version`). `nil` can't be merged, so a field is cleared with `false`.
function patch(id, fields)
  local r = get(id)
  if not r then return false end
  for k, v in pairs(fields or {}) do
    if v == false and (k == "task" or k == "hand" or k == "craft" or k == "died") then r[k] = nil else r[k] = v end
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
local function living()
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
  for i, a in ipairs(o) do out[i] = { name = a.name, cost = (free and i == 1) and 0 or fee } end
  return out
end

function hire(i)
  local list = offers()
  local a = list[i or 1]
  if not a then return nil, "no such applicant" end
  if a.cost > 0 then
    local co = ref("company")
    if co and co.spend then
      if not co.spend(a.cost, "crew hire: " .. a.name) then return nil, "not enough money" end
    end
  end
  local id = (save.get("crew.seq") or 0) + 1
  save.set("crew.seq", id)
  local rec = newRecord(id, a.name, { hired = (space and space.time and space.time()) or 0, cost = a.cost })
  put(rec)
  local r = ids()
  r[#r + 1] = id
  save.set("crew.roster", r)
  local o = save.get("crew.offers") or {}
  table.remove(o, i or 1)
  save.set("crew.offers", o)
  -- the standard issue (§5.1): whatever the inventory offers for it
  local inv = ref("inventory")
  if inv and inv.ensureKit then pcall(inv.ensureKit, packOf(id)) end
  return id, nil
end

-- ── death settings (§2.3) ──────────────────────────────────────────────────
function deathOn()
  ensure()
  return save.get("crew.death") ~= false
end

function setDeath(on)
  save.set("crew.death", on and true or false)
  bump()
end

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

-- ── where the crew physically is (single astronaut until slice 2) ──────────
function bodyOf(id)
  if id ~= nil and id == activeId() and find then
    local a = find("Astronaut")
    if a and a.valid ~= false then return a end
  end
  return nil
end

function dollOf(id) return nil end

-- The craft carrying member `id` right now (its controller handle), or nil.
function craftOf(id)
  if id ~= activeId() then return nil end
  for _, v in ipairs(findScripts and findScripts("vessel_controller") or {}) do
    if v.crewAboard and v.node and v.node.valid ~= false then return v end
  end
  return nil
end

function aboard(v)
  local out = {}
  if v and v.crewAboard then
    local id = activeId()
    if id then
      out[1] = { id = id, uid = v.stationUid, slot = 1, commander = true }
    end
  end
  return out
end

function switchList()
  local out = {}
  local id = activeId()
  local r = get(id)
  if r and not craftOf(id) then out[#out + 1] = { kind = "crew", id = id, name = r.name, dist = 0 } end
  for _, v in ipairs(findScripts and findScripts("vessel_controller") or {}) do
    if v.node and v.node.valid ~= false then
      out[#out + 1] = { kind = "vessel", v = v, name = v.craftName or "Vessel", dist = nil }
    end
  end
  return out
end

function control(id)
  if id == activeId() then return true, nil end
  return false, "only one astronaut until the crew arrives"
end

function quickSwap() return false end

-- Is anyone on EVA in space (off the ground, nothing under them for 50 m)?
-- Rails warp is refused while they are (§5.7). eva_pack keeps the answer.
function onEvaInSpace()
  local id = activeId()
  if not id or craftOf(id) then return false, nil end
  local ep = ref("eva_pack")
  if ep and ep.inSpace then
    local ok, v = pcall(ep.inSpace)
    if ok and v then return true, id end
  end
  return false, nil
end

-- ── EVA (§3.3) ─────────────────────────────────────────────────────────────
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

-- Step member `id` out. opts.confirmed goes past the no-pack warning;
-- without it a warning comes back as (false, "confirm", warn) and the
-- caller (the F key, a portrait) asks the player.
function eva(id, opts)
  id = id or activeId()
  opts = opts or {}
  local ok, why, warn = evaCheck(id)
  if not ok then return false, why end
  if warn and not opts.confirmed then return false, "confirm", warn end
  local v = craftOf(id)
  if not (v and v.evaNow) then return false, "no hatch" end
  local done = v.evaNow()
  if not done then return false, "no clear spot outside" end
  return true, nil
end

-- Board craft `v` (a controller handle). Slots arrive in slice 2.
function board(id, v, uid, slot)
  if id ~= activeId() then return false, "only the avatar boards" end
  if not (v and v.boardNow) then return false, "not a craft" end
  if v.boardNow() then return true, nil end
  return false, "out of reach"
end

-- Status bookkeeping the controller calls on EVA and boarding.
function noteAboard(id, craft)
  patch(id, { status = "aboard", craft = craft or false })
end
function noteAfoot(id)
  local a = bodyOf(id)
  local f = { status = "afoot", craft = false }
  if a and space and space.dominant then
    local d = space.dominant(a.x, a.y, a.z)
    local b = d and space.body(d)
    if b then f.body, f.x, f.y, f.z = d, a.x - b.x, a.y - b.y, a.z - b.z end
  end
  patch(id, f)
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

-- ── warnings as state (§2.3; WS2 draws them) ───────────────────────────────
function alerts(id)
  local r = get(id) or {}
  local pw = ref("planet_walker")
  local breath = (pw and pw.breath) or (pw and pw.oxygen) or 1.0
  -- o2: the suit's air in all, built-in + tanks, as a share of their capacity
  local o2 = r.o2 or 1.0
  if pw and pw.airLeft and pw.airCap and pw.airCap > 0 then o2 = pw.airLeft / pw.airCap end
  return { o2 = o2, air_s = pw and pw.airLeft or nil, breath = breath, hp = r.hp or 1.0, heat = r.heat or 0.0, fall = 0.0,
           pinned = false, blackout = (pw and pw.downed) and 1.0 or nil, cabin = nil }
end

-- ── the manager ────────────────────────────────────────────────────────────
function start(node)
  ensure()
end

-- A save migrated while inventory's alias was missing moves its pack the
-- first frame the alias is there (then this costs one flag test).
function update(node, dt)
  if not ensured then ensure() end
end
