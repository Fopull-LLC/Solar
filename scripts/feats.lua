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
--   feats.once(id, ctx)            mark only if not done yet (no save churn)
--   feats.addAmount(id, x)         a running total in fractions (kg worked,
--                                  metres driven): whole units go to the save
--   feats.accrue(id, dt, secs)     a feat after `secs` of something (a dose read)
--
-- THE DETECTORS (progression P2, PLAN §2.1). The systems that know call one
-- line each; the rules live here, so a shared file carries one line:
--   gridTick (base_grid, after each advance)  grid_served, night_held,
--            rtg_night, slept_in
--   roomsSolved (room_air, after a structure's rooms are solved)  room_sealed
--   airStep (room_air, after a structure's air is advanced)  room_breathable
--   fluidStep (fluid_net, after a network's step)  fluid_moved
--   reactorTick (reactor_plant.publish)  reactor_critical, scram_seen
--   cacheOpened (loot.prepare)  cave_cache
--   and single marks: cable_laid (base_cable.lay), logic_fired (logic_net
--   apply), machine_worked / part_fabricated (refinery.after), dose_taken
--   (cave_hazards), drive_km and bulk_hauled (missions)
-- None of them scans per frame: each runs on its system's own slow clock.
--
-- SAVE: `feats` = { [id] = { n, t (first, agency clock), b (body), k = { [key] = 1 } } },
-- `feats.mig` = the migration's version, `feats.gn` = { [grid id] = { ph,
-- ok, ns, out } } (a night under way: its phase, held, when it fell, the crew
-- out of doors). Pure (luajit, tests/smoke_feats.lua) against a stand-in
-- `save`; on the Company node in the system and builder scenes.

defaults = {}

LABEL = {
  kit_placed     = "a Build Kit piece put down",
  wood_built     = "timber pieces standing",
  base_founded   = "a base of your own (a Camp Mast, a Base Station Tower, or a claimed ruin)",
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
  ruin_repaired  = "a claimed ruin whose rooms hold air again",
  lock_opened    = "a lock opened (its code, or forced)",
  ore_studied    = "an ore studied at the lab",
  machine_worked = "a refinery run",
  part_fabricated = "a part fabricated",
  cave_kinds     = "a cave explored",
  cave_cache     = "a cave cache found",
  run_cycle      = "a run flown and unloaded",
  reactor_critical = "a reactor brought critical",
  -- (P2)
  cable_laid     = "a power cable run of 40 m or more",
  source_wired   = "a source cabled to a battery or a load",
  part_crafted   = "a part made by hand at a Workbench",
  shipment_received = "a courier pod set down at one of your bases",
  slept_in       = "a night spent in a sealed room",
  rtg_night      = "an Isotope Skid that carried a grid through a night",
  scram_seen     = "a reactor tripped (a SCRAM, or a meltdown lived through)",
  dose_taken     = "a minute of radiation dose read on the suit",
  drive_km       = "a kilometre driven",
  bulk_hauled    = "a bulk haul delivered",
  storm_held     = "a grid held through a storm",
  medevac        = "a survivor brought to the Medical Bay",     -- (missions M1, medical.admit)
}
-- A counted feat's words at a count (the lock line: "needs 1 km driven").
UNIT = { drive_km = { k = 1000, u = "km driven" }, machine_worked = { k = 1, u = "kg refined" } }
MIG = 2          -- the migration's version (feats.mig): 2 = the P2 arc's
SERVED_S = 60    -- (grid_served) a grid carrying its load this long, agency s
BREATHE_S = 3600 -- (room_breathable) a sealed room's own air, a scrubber running
DOSE_S = 60      -- (dose_taken) seconds of dose read on the suit
CABLE_M = 40     -- (cable_laid) a run this long
ROOM_M3 = 8      -- (room_sealed) a room this big

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
function labelOf(id, n)
  local u = UNIT[id]
  if u and n and n > 1 then
    local v = n / u.k
    return (v == math.floor(v) and string.format("%d", v) or string.format("%.1f", v)) .. " " .. u.u
  end
  return LABEL[id] or (tostring(id):gsub("_", " "))
end

-- What the first mark of a feat unlocks (research.TECH featGrant), as labels.
local function grants_of(id)
  local rs = ref("research")
  local out = {}
  if not (rs and rs.TECH) then return out end
  local K = ref("parts_kit")
  for tid, t in pairs(rs.TECH) do
    -- (a gate left open for want of its piece was never shut: no news)
    local open = t.openWithout and K and type(K.PIECES) == "table" and K.PIECES[t.openWithout] == nil
    -- (the label without its parenthesis: the strip holds two lines)
    if t.featGrant == id and not open then out[#out + 1] = ((t.label or tid):gsub("%s*%b()", "")) end
  end
  table.sort(out)
  return out
end

-- One radio line when a feat opens something (an unlock is news; the feat
-- itself is not: the player just did it, few popups).
local function tell_grants(id)
  local g = grants_of(id)
  if #g == 0 then return end
  local line = string.format("Logged. The Depot ships %s now.", table.concat(g, " and "))
  if log then log("FEAT: " .. id .. " unlocks " .. table.concat(g, ", ")) end
  -- (gy3) a scenario's run is its own story: the Depot's news waits (silent)
  local sr = ref("scenario_run")
  if sr and sr.isActive and sr.isActive() and not (sr.phaseNow and sr.phaseNow() == "freeplay") then return end
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

-- Take back `n` (default 1) of a count: a piece undone or taken down is not
-- standing any more (Ty 11-12: "Build 8 timber pieces" was met by placing one
-- and undoing it eight times). Never below 0; the first mark's date and its
-- grants stay (an unlock is never taken back). → the new count
function unmark(id, n)
  local t = all()
  local e = t[id]
  if type(e) ~= "table" then return 0 end
  local c = tonumber(e.n) or 0
  local d = math.max(1, math.floor(tonumber(n) or 1))
  if c <= 0 then return 0 end
  e.n = math.max(0, c - d)
  t[id] = e
  sset("feats", t)
  version = version + 1
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
  local was = tonumber(sget("feats.mig")) or 0
  if was >= MIG then return 0 end
  local n = 0
  -- m(id, cond[, k]): the feat if cond (to a count of k: a running total)
  local function m(id, cond, k)
    if not cond then return end
    if k then
      if count(id) < k then markAtLeast(id, k, { quiet = true }); n = n + 1 end
    elseif count(id) == 0 then mark(id, { quiet = true }); n = n + 1 end
  end
  if was < 1 then migrate1(m) end
  if was < 2 then migrate2(m) end
  sset("feats.mig", MIG)
  if log and n > 0 then log(string.format("feats: an old save: %d feats it had already done", n)) end
  return n
end
function migrate1(m)
  local mm = m
  local B = ref("bases")
  local nb = 0
  if B and B.count then local ok, c = pcall(B.count); nb = ok and tonumber(c) or 0
  else
    local list = sget("bases.list")
    nb = type(list) == "table" and #list or 0
  end
  mm("base_founded", nb > 0)
  local rs = sget("ruins.s")
  local claimed, read, found = false, false, false
  for _, e in pairs(type(rs) == "table" and rs or {}) do
    if type(e) == "table" then
      if e.cl then claimed = true end
      if e.read then read = true end
      if e.dsc then found = true end
    end
  end
  mm("ruin_claimed", claimed)
  mm("core_read", read)
  mm("ruin_found", found)
end

-- (P2) What the P2 arc gates that an older save could already build. Before
-- P2 the Build Kit came at the Relay Network's 10 % and every kit piece was
-- open; a save that had the kit keeps every piece it could place (the arc's
-- grants written as researched). The Relay Network, which now follows Lights
-- On, stays open where First Steps is done (`prog.open`). And the feats its
-- records prove: a power source on a grid, a store or an Isotope Skid, a
-- refinery machine, a Fabricator, an ore studied, the metres a contract's
-- odometer kept.
P2_GATES = { "tower", "power2", "life", "fluids", "logic", "quarry", "shoring" }
function migrate2(m)
  local mm = m
  local pd = sget("prog.done")
  pd = type(pd) == "table" and pd or {}
  local pm = sget("prog.perm")
  pm = type(pm) == "table" and pm or {}
  local rn = type(pm.relay_net) == "table" and pm.relay_net or {}
  local rd = sget("res.done")
  rd = type(rd) == "table" and rd or {}
  local had_kit = pd.relay_net == true or rn[1] == true or rn["1"] == true or rd.buildkit == true
  if had_kit then
    for _, t in ipairs(P2_GATES) do rd[t] = true end
    sset("res.done", rd)
  end
  if pd.first_steps and not pd.relay_net then
    local po = sget("prog.open")
    po = type(po) == "table" and po or {}
    po.relay_net = true
    sset("prog.open", po)
  end
  -- the records: what stands, owned (not an unclaimed ruin's)
  local ST, pb = ref("structures"), ref("parts_base")
  local has = {}
  if ST and ST.list and pb and pb.partInfo then
    for _, rec in ipairs(ST.list()) do
      if owned(rec) then
        for _, p in ipairs(rec.bp or {}) do
          local d = pb.partInfo(p.id)
          local pw = d and d.power
          if pw and (pw.kind == "solar" or pw.kind == "rtg" or pw.kind == "plant") then has.src = true end
          if pw and pw.kind == "store" then has.store = true end
          if pw and pw.kind == "rtg" then has.rtg = true end
          local pc = d and d.piece
          if pc == "mcCrusher" or pc == "mcFurnace" or pc == "mcKiln" or pc == "mcMixer" or pc == "mcElectro" then has.mach = true end
          if pc == "mcFab" then has.fab = true end
        end
        if rec.bases or rec.base then has.base = true end
      end
    end
  end
  local B = ref("bases")
  if B and B.count then local ok, c = pcall(B.count); if ok and (tonumber(c) or 0) > 0 then has.base = true end end
  mm("grid_served", has.src and has.base)
  mm("night_held", has.src and has.base and (has.store or has.rtg))
  mm("rtg_night", has.rtg and has.base)
  mm("machine_worked", has.mach, 200)
  mm("part_fabricated", has.fab)
  -- an ore studied at the lab
  local mats = ref("materials")
  local st = sget("res.studied")
  local ore = false
  if mats and mats.class and type(st) == "table" then
    for mat in pairs(st) do local ok, c = pcall(mats.class, mat); if ok and c == "ore" then ore = true end end
  end
  mm("ore_studied", ore)
  -- metres a contract's odometer kept (mission.odo.by: craft → m)
  local odo = sget("mission.odo")
  local dm = 0
  if type(odo) == "table" and type(odo.by) == "table" then for _, v in pairs(odo.by) do dm = dm + (tonumber(v) or 0) end end
  mm("drive_km", dm >= 1, math.floor(dm))
end

-- ── (P2) small marks ────────────────────────────────────────────────────────
-- Mark only if not done: a detector that fires often writes the save once.
function once(id, ctx)
  if count(id) > 0 then return nil end
  return mark(id, ctx)
end
-- A running total in fractions: whole units go to the save (a kg worked, a
-- metre driven), the rest is kept here till it makes one.
local frac = {}
function addAmount(id, x, ctx)
  x = tonumber(x) or 0
  if x <= 0 or x ~= x or x == math.huge then return nil end
  local f = (frac[id] or 0) + x
  local whole = math.floor(f)
  frac[id] = f - whole
  if whole < 1 then return nil end
  ctx = type(ctx) == "table" and ctx or {}
  return mark(id, { n = whole, b = ctx.b, quiet = ctx.quiet })
end
-- A feat after `secs` of something (in this session: a dose read on the suit).
local acc = {}
function accrue(id, dt, secs)
  if count(id) > 0 then return nil end
  acc[id] = (acc[id] or 0) + (tonumber(dt) or 0)
  if acc[id] >= (secs or 60) then acc[id] = nil; return mark(id) end
  return nil
end

-- A structure the agency owns: anything but an unclaimed ruin's.
function owned(rec)
  if type(rec) ~= "table" then return false end
  if not rec.ru then return true end
  local R = ref("ruins")
  return R ~= nil and R.claimed ~= nil and R.claimed(rec.ru) == true
end

-- ── (P2) the grid: served, a night held, a night indoors ────────────────────
-- base_grid calls gridTick(G.list, G.models, G.status, a, self) after every
-- advance (every 2 s, and on a rebuild). A grid counts when it holds at least
-- one owned structure (a ruin's yard lighting itself is not the player's).
-- NIGHT: base_grid's light profile (M.prof: the arrays' output in each slot of
-- the year); a grid with no arrays gets a stand-in, an upward cell at its
-- first part, worked out once per model. A night is a dark slot run from dusk
-- to dawn crossed with the loads served throughout (s.short, the seconds shed
-- in the step, is zero): an advance that crosses a whole night at warp counts
-- it as one step does. Held by an Isotope Skid (M.rtg) it is also rtg_night;
-- the active crew member inside a sealed room from dusk to dawn, slept_in.
local served_at = {}                 -- grid id → agency time it began carrying its load
local dark_of = setmetatable({}, { __mode = "k" })   -- model → { [1..N] bool }
local gn = nil                       -- grid id → { ph, ok, ns, out } (save feats.gn)
local function gn_load()
  if gn then return gn end
  local t = sget("feats.gn")
  gn = type(t) == "table" and t or {}
  return gn
end
local function gn_save() sset("feats.gn", gn or {}) end
local function grid_owned(g)
  for _, e in ipairs(g.parts or {}) do if owned(e.rec) then return true end end
  return false
end
local function dark_profile(g, M, BG)
  local d = dark_of[M]
  if d ~= nil then return d or nil end
  d = false
  local N = M.N or 0
  if M.prof and N > 1 then
    d = {}
    for j = 1, N do d[j] = (M.prof[j] or 0) <= 1e-6 end
  elseif N > 1 and BG and BG.slotLight and BG.slotInfo then
    local sl = BG.slotInfo()
    local ST = ref("structures")
    local e = g.parts and g.parts[1]
    if sl and ST and ST.partPose and e and e.rec.b == (sl.body and sl.body.name) then
      local ok, gx, gy, gz, U, F = pcall(ST.partPose, e.rec, e.p, 1.0)
      if ok and gx and U and F then
        local arr = { gen = 1, x = gx, y = gy, z = gz,
                      ax = U.y * F.z - U.z * F.y, ay = U.z * F.x - U.x * F.z, az = U.x * F.y - U.y * F.x }
        local ok2, prof = pcall(BG.slotLight, arr, sl)
        if ok2 and type(prof) == "table" then
          d = {}
          for j = 1, N do d[j] = (prof[j] or 0) <= 1e-6 end
        end
      end
    end
  end
  dark_of[M] = d
  return d or nil
end
-- the active member in a sealed room now (room_air's view)
local function indoors()
  local RA = ref("room_air")
  if not (RA and RA.crewRoom and RA.airOf) then return false end
  local sid, rid = RA.crewRoom()
  if not (sid and rid) then return false end
  local ok, st = pcall(RA.airOf, sid, rid)
  return ok and type(st) == "table" and st.sealed == true and not st.leaky
end
function gridTick(list, models, status, a, BG)
  if type(list) ~= "table" or not a then return end
  gn_load()
  local dirty = false
  for _, g in ipairs(list) do
    local M, s = models and models[g.id], status and status[g.id]
    if M and s and grid_owned(g) then
      local short = (s.short or 0) > 1e-6
      -- grid_served: carrying a real load from a real source for SERVED_S
      if (M.sources or 0) > 0 and (M.need or 0) > 0 and s.powered and not short then
        served_at[g.id] = served_at[g.id] or (a - (s.dt or 0))
        if a - served_at[g.id] >= SERVED_S then once("grid_served", { b = M.body }) end
      else
        served_at[g.id] = nil
      end
      -- the night
      local dk = dark_profile(g, M, BG)
      if dk and M.L and M.A0 and M.N and BG and BG.slotOf then
        local k1 = BG.slotOf(M, a)
        local e = gn[g.id]
        if type(e) ~= "table" then
          -- first sight: a grid seen first at night waits for the next dusk
          e = { ph = dk[(k1 % M.N) + 1] and "late" or "day", a = a }
          gn[g.id] = e
          dirty = true
        else
          local k0 = BG.slotOf(M, tonumber(e.a) or (a - (s.dt or 0)))
          if k1 - k0 > 2 * M.N then k0 = k1 - 2 * M.N end
          for k = k0 + 1, k1 do
            local d = dk[(k % M.N) + 1]
            if d and e.ph == "day" then
              e.ph, e.ok, e.ns, e.out = "night", (M.need or 0) > 0 and not short, M.A0 + k * M.L, not indoors()
              dirty = true
            elseif not d and e.ph ~= "day" then
              if e.ph == "night" then
                if short then e.ok = false end
                if e.ok then
                  once("night_held", { b = M.body })
                  if (M.rtg or 0) > 0 then once("rtg_night", { b = M.body }) end
                  if not e.out then once("slept_in", { b = M.body }) end
                end
              end
              e.ph, e.ok, e.ns, e.out = "day", nil, nil, nil
              dirty = true
            end
          end
          if e.ph == "night" then
            if short and e.ok then e.ok = false; dirty = true end
            if not e.out and not indoors() then e.out = true; dirty = true end
          end
          e.a = a
        end
      end
    end
  end
  if dirty then gn_save() end
end
function resetGrid() served_at, gn = {}, nil; dark_of = setmetatable({}, { __mode = "k" }) end

-- ── (P2) rooms and air ──────────────────────────────────────────────────────
-- room_air calls roomsSolved(sid, s) when a structure's rooms are solved: a
-- sealed room of ROOM_M3 or more in an owned structure is shelter.
function roomsSolved(sid, s)
  if count("room_sealed") > 0 or type(s) ~= "table" or not (s.R and s.R.rooms) then return end
  if not owned(s.rec) then return end
  for _, r in ipairs(s.R.rooms) do
    if r.sealed and not r.leaky and (r.m3 or 0) >= ROOM_M3 then once("room_sealed", { b = s.rec and s.rec.b }) return end
  end
end
-- room_air calls airStep(sid, s, nets, dt, statusOf) after each step of a
-- structure's air: a sealed network (no opening, ROOM_M3 or more) whose air
-- is breathable counts its time while a scrubber in it runs (n.S > 0: on and
-- powered), BREATHE_S in all: air you made. A brownout pauses the count (the
-- air is still the room's); the air going bad, or the room opening, resets it.
local breathed = {}
airLast = nil     -- (probes) the last step looked at: { sid, why, t (s of air counted) }
function airStep(sid, s, nets, dt, statusOf)
  if count("room_breathable") > 0 or type(nets) ~= "table" or not (dt and dt > 0) or not statusOf then return end
  if not (s and owned(s.rec)) then return end
  airLast = { sid = sid, why = "no sealed room of 8 m³ with breathable air", t = breathed[sid] or 0, n = #nets }
  local held = false
  for _, n in ipairs(nets) do
    if n.tau == nil and (n.V or 0) >= ROOM_M3 then
      local N, x, c = 0, 0, 0
      for _, id in ipairs(n.rooms or {}) do
        local A = s.air and s.air[id]
        if A then N, x, c = N + (A.N or 0), x + (A.x or 0), c + (A.c or 0) end
      end
      local ok, st = pcall(statusOf, { N = N, x = x, c = c }, n.V)
      if ok and st and st.breathable then
        held = true
        if (n.S or 0) > 0 then
          airLast.why = "breathable, a scrubber running"
          breathed[sid] = (breathed[sid] or 0) + dt
          if breathed[sid] >= BREATHE_S then once("room_breathable", { b = s.rec and s.rec.b }) end
          return
        end
        airLast.why = "breathable, no scrubber running (the count waits)"
      elseif not ok then
        airLast.why = "statusOf: " .. tostring(st)
      end
    end
  end
  if not held then breathed[sid] = nil end
end

-- ── (P2) fluids, the reactor, a cave's cache ────────────────────────────────
-- fluid_net calls fluidStep(e, E) after a network's step (E.x0 the contents
-- before, E.st.x after): with a pump running, what moved counts.
local pumped = {}
function fluidStep(e, E)
  if count("fluid_moved") > 0 or type(E) ~= "table" or not (E.net and E.st and E.x0) then return end
  if not (e and owned(e.rec)) then return end
  local running = false
  for k, el in ipairs(E.net.els or {}) do
    if el.kind == "pump" and el.on ~= false and (E.st.em or {})[k] ~= "stall" then running = true end
  end
  if not running then return end
  local up, down = 0, 0
  for i, x in pairs(E.st.x or {}) do
    local dx = (tonumber(x) or 0) - (tonumber(E.x0[i]) or 0)
    if dx > 0 then up = up + dx else down = down - dx end
  end
  local key = tostring(e.sid)
  pumped[key] = (pumped[key] or 0) + math.max(up, down)
  if pumped[key] >= 100 then once("fluid_moved", { b = e.rec and e.rec.b }) end
end
-- reactor_plant calls reactorTick(e) when it publishes a plant's state:
-- critical (k at 1 with power), then a trip seen after it (a SCRAM, a melt).
function reactorTick(e)
  local o, S = type(e) == "table" and e.o or nil, type(e) == "table" and e.S or nil
  if not (o and S) then return end
  if (o.k or 0) >= 0.9995 and (o.P or 0) > 1e-3 then once("reactor_critical", { b = e.rec and e.rec.b }) end
  if (S.scram or S.melt) and count("reactor_critical") > 0 then once("scram_seen") end
end
-- loot.prepare calls cacheOpened(sid, uid) when a container is opened: one
-- standing in a cave under a ruin (a mine head's cache, a sink camp's) counts.
CAVE_RI = 1000   -- ruins.CAVE_RI: a cave piece's index starts past this
function cacheOpened(sid, uid)
  if count("cave_cache") > 0 then return end
  local ST = ref("structures")
  local rec = ST and ST.get and ST.get(sid)
  if not (rec and rec.ru) then return end
  for _, p in ipairs(rec.bp or {}) do
    if p.uid == uid and (p.cv or (tonumber(p.ri) or 0) >= CAVE_RI) then once("cave_cache", { key = rec.ru, b = rec.b }) return end
  end
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
