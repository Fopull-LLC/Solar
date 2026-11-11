-- FEATS — things the player has DONE in the world (progression P1,
-- work/progression/PLAN.md §2.1). Ty, 11-11: "make solar panels unlock when
-- you set up your first base, and in general rework the whole progression to
-- involve all the new mechanics".
--
-- A feat is a thing done, never a thing bought: a base founded, a ruin found,
-- a lock opened. The systems that already know mark it, one line each where
-- the thing happens (guarded: `local F = ref("feats"); if F then F.mark(…) end`).
-- Research reads feats as a lock (`feat =`) or a grant (`featGrant =`,
-- research.lua), the programme and scenarios as a goal kind (`feat`). None of
-- them refuses anything in the world: a gate is a card line, never a no.
--
--   feats.mark(id, ctx) → n (the new count) | nil (already counted for ctx.key)
--       ctx = { key = "…" (count once per key: a ruin's id, a piece's uid),
--               b = body, n = add this many (default 1), quiet = true }
--   feats.markAtLeast(id, n, ctx)  (a running total: metres driven, kg worked)
--   feats.has(id) → bool    feats.count(id) → n    feats.when(id) → agency clock
--   feats.LABEL[id]  the lock line's words ("needs " .. LABEL)
--   feats.migrate()  once a save: what an old save already built counts
--                    (a base → base_founded), so nothing built is re-locked
--
-- SAVE: `feats` = { [id] = { n, t (first, agency clock), b (body), k = { [key] = 1 } } },
-- `feats.mig` = the migration's version. Pure (luajit, tests/smoke_feats.lua)
-- against a stand-in `save`; on the Company node in the system and builder
-- scenes. Nothing runs a frame.

defaults = {}

LABEL = {
  kit_placed     = "a Build Kit piece put down",
  wood_built     = "timber pieces standing",
  base_founded   = "a base of your own (a Base Station Tower, or a claimed ruin)",
  grid_served    = "a base grid that carries its load",
  night_held     = "a grid held through a night",
  room_sealed    = "a sealed room",
  room_breathable = "a room with air you made",
  fluid_moved    = "a pump that moved something",
  logic_fired    = "a sensor that switched something",
  ruin_found     = "an abandoned base found",
  ruin_stripped  = "pieces stripped from a ruin",
  core_read      = "a ruin's Data Core read",
  ruin_claimed   = "a ruin claimed",
  lock_opened    = "a lock opened (its code, or forced)",
  ore_studied    = "an ore studied at the lab",
  machine_worked = "a refinery run",
  part_fabricated = "a part fabricated",
  cave_kinds     = "a cave explored",
  cave_cache     = "a cave cache found",
  run_cycle      = "a run flown and unloaded",
  reactor_critical = "a reactor brought critical",
}
MIG = 1          -- the migration's version (feats.mig)

version = 0

local function sget(k) return save and save.get and save.get(k) or nil end
local function sset(k, v) if save and save.set then save.set(k, v) end end

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind, { quiet = true }) or nil; refs[kind] = r end
  return r
end
local function agency_now()
  local dp = ref("deployables")
  if dp and dp.agencyClock then local ok, t = pcall(dp.agencyClock); if ok and type(t) == "number" then return t end end
  return tonumber(sget("agency.clock")) or 0
end

-- ── pure: over a feats table ────────────────────────────────────────────────
-- (research.lua reads the save's table through these rules too: the builder
-- scene must answer the same as the system scene)
function countIn(t, id)
  local e = type(t) == "table" and t[id] or nil
  return type(e) == "table" and (tonumber(e.n) or 0) or 0
end
function hasIn(t, id, n) return countIn(t, id) >= (n or 1) end

-- ── the API ─────────────────────────────────────────────────────────────────
function all()
  local t = sget("feats")
  return type(t) == "table" and t or {}
end
function count(id) return countIn(all(), id) end
function has(id, n) return hasIn(all(), id, n) end
function when(id)
  local e = all()[id]
  return type(e) == "table" and e.t or nil
end
function labelOf(id) return LABEL[id] or (tostring(id):gsub("_", " ")) end

-- What the first mark of a feat unlocks (research.TECH featGrant), as labels.
local function grants_of(id)
  local rs = ref("research")
  local out = {}
  if not (rs and rs.TECH) then return out end
  for tid, t in pairs(rs.TECH) do
    if t.featGrant == id then out[#out + 1] = t.label or tid end
  end
  table.sort(out)
  return out
end

-- One radio line when a feat opens something (an unlock is news; the feat
-- itself is not: the player just did it, few popups).
local function tell_grants(id)
  local g = grants_of(id)
  if #g == 0 then return end
  local line = string.format("That's on the books: %s. The Depot will ship you %s now.", LABEL[id] or id, table.concat(g, " and "))
  if log then log("FEAT: " .. id .. " unlocks " .. table.concat(g, ", ")) end
  local strip = ref("ops_strip")
  if strip and strip.say then pcall(strip.say, line, "Ops")
  elseif caption then pcall(caption, "Ops: " .. line) end
end

function mark(id, ctx)
  if type(id) ~= "string" or id == "" then return nil end
  ctx = type(ctx) == "table" and ctx or {}
  local t = all()
  local e = t[id]
  if type(e) ~= "table" then e = { n = 0 } end
  if ctx.key ~= nil then
    e.k = type(e.k) == "table" and e.k or {}
    local k = tostring(ctx.key)
    if e.k[k] then return nil end
    e.k[k] = 1
  end
  local first = (tonumber(e.n) or 0) == 0
  e.n = (tonumber(e.n) or 0) + math.max(1, math.floor(tonumber(ctx.n) or 1))
  if first then e.t = agency_now(); e.b = ctx.b end
  t[id] = e
  sset("feats", t)
  version = version + 1
  if first then
    if log then log(string.format("feats: %s (first)", id)) end
    if not ctx.quiet then tell_grants(id) end
  end
  return e.n
end

-- A running total: the feat's count raised to `n` (never lowered).
function markAtLeast(id, n, ctx)
  n = math.floor(tonumber(n) or 0)
  local c = count(id)
  if n <= c then return nil end
  ctx = type(ctx) == "table" and ctx or {}
  return mark(id, { n = n - c, b = ctx.b, quiet = ctx.quiet })
end

-- (scenarios: start.feats) set a feat as already done: { "id" | { id, n } … }
function seed(list)
  local n = 0
  for _, f in ipairs(type(list) == "table" and list or {}) do
    local id, k = f, 1
    if type(f) == "table" then id, k = f.id or f[1], f.n or f[2] or 1 end
    if type(id) == "string" and markAtLeast(id, k, { quiet = true }) then n = n + 1 end
  end
  return n
end

-- ONCE A SAVE: what an old save already built counts, so nothing is
-- re-locked by a feat it could not have marked (bases founded before feats
-- existed, a claimed ruin, a core read). → the feats marked
function migrate()
  if (tonumber(sget("feats.mig")) or 0) >= MIG then return 0 end
  local n = 0
  local function m(id, cond) if cond and count(id) == 0 then mark(id, { quiet = true }); n = n + 1 end end
  local B = ref("bases")
  local nb = 0
  if B and B.count then local ok, c = pcall(B.count); nb = ok and tonumber(c) or 0
  else
    local list = sget("bases.list")
    nb = type(list) == "table" and #list or 0
  end
  m("base_founded", nb > 0)
  local rs = sget("ruins.s")
  local claimed, read, found = false, false, false
  for _, e in pairs(type(rs) == "table" and rs or {}) do
    if type(e) == "table" then
      if e.cl then claimed = true end
      if e.read then read = true end
      if e.dsc then found = true end
    end
  end
  m("ruin_claimed", claimed)
  m("core_read", read)
  m("ruin_found", found)
  sset("feats.mig", MIG)
  if log and n > 0 then log(string.format("feats: an old save: %d feats it had already done", n)) end
  return n
end

-- ── the scene ───────────────────────────────────────────────────────────────
local mig_t = -10
local migrated = false
function start(node) migrated = false end
function update(node, dt)
  if migrated then return end
  local t = time or 0
  if t - mig_t < 2.0 then return end
  mig_t = t
  -- (after the save is loaded and the bases are read: the game manager says)
  local gm = ref("game_manager")
  if gm and gm.loading then return end
  if not (save and save.get and save.get("system.home")) then return end
  migrated = true
  pcall(migrate)
end
