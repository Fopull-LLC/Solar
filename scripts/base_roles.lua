-- BASE ROLES — what each base is FOR, read off what is built in it (expansion
-- X7, PLAN §1; docs/base-building.md §25). A role is never chosen: a base with
-- an Electrolyser is a FUEL base, one with a Quarry Drive a MINE, one whose
-- grid makes 10 kW more than it uses a POWER base. Ty 11-09: "purposeful
-- bases encourage expanding far: refuelling stations, resource pipelines
-- shipping home, mining/quarry bases, energy bases, refineries, science labs,
-- defense bases".
--
--   PORT      ⇆  a run starts, ends or stops here (a Build Stand alone is not enough)
--   FUEL      ⛁  an Electrolyser, or a Fuel Hose Stand with 500 kg in its tanks
--   MINE      ⚒  a Quarry Drive (strongest while it digs)
--   POWER     ⚡  the grid's sources exceed its loads by 10 kW
--   REFINERY  ⚙  a Crusher, Furnace, Kiln, Mixer or Fabricator (strongest while it works)
--   SCIENCE   ✦  a telescope or a Survey Station (strongest with a Scientist there or a sweep running)
--   DEPOT     ▤  hoppers and silos holding 2 t, or 4 t of room
--   DEFENCE   ✚  a Beam Director (X9's lasers; X10's launch rails later): a part with `defence`
--   OUTPOST   ⌂  none of the above
--
-- Each role has a STRENGTH 0..1. A role shows from SHOW (0.5). Strength rises
-- at once and DECAYS over DECAY (3 game days), so a quarry idle for a day
-- does not stop being a MINE base (PLAN §1.1's hysteresis).
--
-- BASE STATS (PLAN §1.2): what each base moved, credited by the systems that
-- move things: runs (route_ops: what a run loads here is OUT, what it unloads
-- IN, a cycle through it a RUN), the quarries (MINED kg), the machines
-- (WORKED kg) and the loading chute (OUT). Totals, today's and yesterday's
-- (agency days), so the station shows a rolling 24 h line.
--
-- SAVE: bases.<id>.roles = { fuel = 0.6, … }, bases.<id>.stats = { … } (the
-- base record, bases.lua); the spaceport's (base 0) in `bases.home`. An old
-- save has neither: its bases are OUTPOSTs until the first census, a second
-- after loading. Nothing else is saved.
--
-- WHEN IT RUNS: a census when structures.version, bases.version or the runs
-- change, and once a game hour (at most once every 2 s of real time under
-- warp). Nothing per frame: update compares three numbers. The stats are
-- written to the save at most every 5 s.
--
-- Pure (tests/smoke_base_roles.lua): ROLES, ORDER, GLYPH, LABEL, targetsOf,
-- decay, step, shown, strongest, roleLine, statsAdd, stats24.

ORDER = { "port", "fuel", "mine", "power", "refinery", "science", "depot", "defence" }
LABEL = { port = "PORT", fuel = "FUEL", mine = "MINE", power = "POWER", refinery = "REFINERY", science = "SCIENCE",
          depot = "DEPOT", defence = "DEFENCE", outpost = "OUTPOST" }
NAME = { port = "Port", fuel = "Fuel", mine = "Mine", power = "Power", refinery = "Refinery", science = "Science",
         depot = "Depot", defence = "Defence" }
-- (every glyph is in SolarLabel and SolarUI: smoke_ui_font)
GLYPH = { port = "⇆", fuel = "⛁", mine = "⚒", power = "⚡", refinery = "⚙", science = "✦", depot = "▤", defence = "✚",
          outpost = "⌂" }
-- what makes each (the card's line for a role the base does not have)
HOW = {
  port = "a run that starts, stops or ends here (fly it once from a Build Stand, then Automate)",
  fuel = "an Electrolyser, or a Fuel Hose Stand with 500 kg in its Fuel Tanks",
  mine = "a Quarry Drive and four Quarry Posts",
  power = "a grid making 10 kW more than it uses",
  refinery = "a Crusher, Furnace, Kiln, Regocrete Mixer or Fabricator",
  science = "a telescope or a Survey Station, and a Scientist",
  depot = "hoppers and silos: 4 t of room, or 2 t held",
  defence = "a Beam Director at the end of a laser (Laser Emitter, Capacitor Banks on a Pulse Bus)",
}
SHOW = 0.5
DECAY = 3 * 86400        -- game s a role takes to fade from 1 to 0
FUEL_KG = 500            -- kg in a hose stand's tanks that make it a FUEL base
POWER_KW = 10            -- kW of surplus that make a POWER base
DEPOT_CAP = 4000         -- kg of hopper and silo room
DEPOT_KG = 2000          -- kg held
CENSUS_EVERY = 3600      -- game s between censuses when nothing changes
CENSUS_GAP = 2.0         -- real s, at least, between two
FLUSH_EVERY = 5.0        -- real s between stats writes

local function clamp(x, lo, hi) if x < lo then return lo elseif x > hi then return hi end return x end

-- ── pure rules ──────────────────────────────────────────────────────────────
-- c (a base's census) = { stands, runs, hoses, fuelTanks, fuelKg, electro, drives,
--   mined24, machines, worked24, supply, need, survey, scientist, sweeping,
--   storeCap, storeKg, defence } → { role = target strength }, { role = why }
function targetsOf(c)
  c = c or {}
  local t, why = {}, {}
  local function set(r, v, w) if v > (t[r] or 0) then t[r] = v; why[r] = w end end
  if (c.runs or 0) > 0 then
    set("port", (c.stands or 0) > 0 and 1 or 0.6, string.format("%d run%s through here", c.runs, c.runs == 1 and "" or "s"))
  elseif (c.stands or 0) > 0 then
    set("port", 0.4, "a Build Stand, no run yet")
  end
  if (c.electro or 0) > 0 then set("fuel", 1, "an Electrolyser makes propellant") end
  if (c.hoses or 0) > 0 then
    if (c.fuelKg or 0) >= FUEL_KG then set("fuel", 1, string.format("a hose stand · %.0f kg in its tanks", c.fuelKg))
    elseif (c.fuelTanks or 0) > 0 then set("fuel", 0.6, string.format("a hose stand · %.0f kg in its tanks", c.fuelKg or 0))
    else set("fuel", 0.3, "a hose stand, no Fuel Tank") end
  end
  if (c.drives or 0) > 0 then
    if (c.mined24 or 0) > 0 then set("mine", 1, string.format("a quarry · %.0f kg in 24 h", c.mined24))
    else set("mine", 0.6, "a quarry, idle") end
  end
  local surplus = (c.supply or 0) - (c.need or 0)
  if surplus >= POWER_KW then set("power", 1, string.format("%.0f kW spare", surplus))
  elseif surplus > 0 then set("power", clamp(surplus / (2 * POWER_KW), 0, 0.49), string.format("%.1f kW spare", surplus)) end
  if (c.machines or 0) > 0 then
    if (c.worked24 or 0) > 0 then set("refinery", 1, string.format("%d machine%s · %.0f kg worked in 24 h", c.machines, c.machines == 1 and "" or "s", c.worked24))
    else set("refinery", 0.6, string.format("%d machine%s, idle", c.machines, c.machines == 1 and "" or "s")) end
  end
  if (c.survey or 0) > 0 then
    if c.scientist or c.sweeping then set("science", 1, c.sweeping and "a telescope sweeping" or "an instrument and a Scientist")
    else set("science", 0.6, "an instrument, no Scientist") end
  end
  if (c.storeKg or 0) >= DEPOT_KG then set("depot", 1, string.format("%.1f t held", (c.storeKg or 0) / 1000))
  elseif (c.storeCap or 0) >= DEPOT_CAP then set("depot", 0.5, string.format("%.0f t of room", (c.storeCap or 0) / 1000)) end
  if (c.defence or 0) > 0 then set("defence", 1, string.format("%d defence piece%s", c.defence, c.defence == 1 and "" or "s")) end
  return t, why
end

-- A strength `dt` game s after it was `s`, toward `target`: up at once, down
-- by 1/DECAY a second (one long step equals many short ones).
function decay(s, target, dt)
  s, target = s or 0, target or 0
  if target >= s then return target end
  return math.max(target, s - math.max(0, dt or 0) / DECAY)
end

-- The roles after a census: prev (saved) toward targets over dt. Strengths
-- under 0.01 are dropped (the save stays small). → roles, changed
function step(prev, targets, dt)
  prev = type(prev) == "table" and prev or {}
  local out, changed = {}, false
  for _, r in ipairs(ORDER) do
    local v = decay(prev[r], targets[r], dt)
    v = math.floor(v * 1000 + 0.5) / 1000
    if v >= 0.01 then out[r] = v end
    if math.abs((out[r] or 0) - (prev[r] or 0)) > 1e-9 then changed = true end
  end
  return out, changed
end

function shown(roles, r) return type(roles) == "table" and (roles[r] or 0) >= SHOW end

-- The shown roles, strongest first (ties in ORDER). → { role… }
function strongest(roles)
  local out = {}
  for _, r in ipairs(ORDER) do if shown(roles, r) then out[#out + 1] = r end end
  local rank = {}
  for i, r in ipairs(ORDER) do rank[r] = i end
  table.sort(out, function(a, b)
    if math.abs(roles[a] - roles[b]) > 1e-9 then return roles[a] > roles[b] end
    return rank[a] < rank[b]
  end)
  return out
end

-- "⛁ FUEL · ⚒ MINE" (at most n; "⌂ OUTPOST" when none shows)
function roleLine(roles, n)
  local s = strongest(roles)
  if #s == 0 then return GLYPH.outpost .. " " .. LABEL.outpost end
  local bits = {}
  for i = 1, math.min(#s, n or 3) do bits[#bits + 1] = GLYPH[s[i]] .. " " .. LABEL[s[i]] end
  return table.concat(bits, " · ")
end
function glyphOf(roles) local s = strongest(roles); return GLYPH[s[1] or "outpost"] end

-- STATS: st = { i, o, m, w, r (totals: kg in, kg out, kg mined, kg worked,
-- run cycles), day (agency day), di, do, dm, dw (today), pi, po, pm, pw
-- (yesterday) }. field ∈ i | o | m | w | r.
local DAYF = { i = "di", o = "do", m = "dm", w = "dw" }
local PREVF = { i = "pi", o = "po", m = "pm", w = "pw" }
local function roll(st, t)
  local d = math.floor((t or 0) / 86400)
  if st.day == d then return end
  local yesterday = st.day ~= nil and d == st.day + 1
  for f, k in pairs(DAYF) do
    st[PREVF[f]] = yesterday and (st[k] or 0) or 0
    st[k] = 0
  end
  st.day = d
end
function statsAdd(st, field, amount, t)
  st = type(st) == "table" and st or {}
  if not amount or amount <= 0 then return st end
  roll(st, t)
  st[field] = (st[field] or 0) + amount
  local k = DAYF[field]
  if k then st[k] = (st[k] or 0) + amount end
  return st
end
-- The last 24 h of a field at t: today so far plus the part of yesterday
-- still inside the window.
function stats24(st, field, t)
  if type(st) ~= "table" or not st.day then return 0 end
  local d = math.floor((t or 0) / 86400)
  local today, prev = st[DAYF[field]] or 0, st[PREVF[field]] or 0
  if d == st.day + 1 then today, prev = 0, today
  elseif d ~= st.day then return 0 end
  local frac = ((t or 0) % 86400) / 86400
  return today + prev * (1 - frac)
end

-- ── the scene half ──────────────────────────────────────────────────────────
version = 0              -- bumped when any base's roles change (the station, the map)
stats = { ms = 0, census = 0, bases = 0, parts = 0, credits = 0 }
census = {}              -- id → the last census (the card's numbers; 0 = the spaceport)
why = {}                 -- id → { role = why }

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function wall() return (app and app.wallClock) and app.wallClock() or os.clock() end
local function agency_now()
  local dp = ref("deployables")
  if dp and dp.agencyClock then local ok, t = pcall(dp.agencyClock); if ok and type(t) == "number" then return t end end
  return tonumber(save and save.get and save.get("agency.clock")) or 0
end
local function radius_of(b) local w = space and space.body and space.body(b); return w and w.radius or nil end
local function defs(id) local pb = ref("parts_base"); return pb and pb.partInfo and pb.partInfo(id) or nil end
local function kg_of(m) local M = ref("materials"); return (M and M.kg and M.kg(m)) or 1 end

-- The places: { id, b, x, y, z (body-relative), rec (bases record or nil) },
-- the spaceport first (id 0).
local function home_rec()
  local h = save and save.get and save.get("bases.home")
  return type(h) == "table" and h or {}
end
local home_pt = nil
local function places()
  local out = {}
  local net, bf = ref("comms"), ref("base_facilities")
  if net and net.station and bf and bf.baseBody then
    local sx, sy, sz = net.station()
    local b = space.body(bf.baseBody)
    if sx and b then
      home_pt = { id = 0, b = bf.baseBody, x = sx - b.x, y = sy - b.y, z = sz - b.z, home = true }
    end
  end
  if home_pt then out[#out + 1] = home_pt end
  local B = ref("bases")
  if B and B.list then
    for _, r in ipairs(B.list()) do out[#out + 1] = { id = r.id, b = r.b, x = r.x, y = r.y, z = r.z, rec = r } end
  end
  return out
end
local place_list, place_ver = {}, nil
local function places_now()
  local B = ref("bases")
  local v = B and B.version or -1
  if v ~= place_ver or not home_pt then place_list = places(); place_ver = v end
  return place_list
end

-- The place a body-relative point belongs to (within bases.RADIUS) → place
function placeAt(body, x, y, z)
  local B = ref("bases")
  local RAD = (B and B.RADIUS) or 150
  local R = radius_of(body)
  local best, bd = nil, RAD
  for _, p in ipairs(places_now()) do
    if p.b == body then
      local d
      if B and B.groundDist then d = B.groundDist(R, x, y, z, p.x, p.y, p.z)
      else d = math.sqrt((x - p.x) ^ 2 + (y - p.y) ^ 2 + (z - p.z) ^ 2) end
      if d <= bd then best, bd = p, d end
    end
  end
  return best
end

-- the roles and stats of place id (0 = the spaceport)
function rolesOf(id)
  if id == 0 then return home_rec().roles or {} end
  local B = ref("bases")
  local r = B and B.get and B.get(id)
  return (r and r.roles) or {}
end
function statsOf(id)
  if id == 0 then return home_rec().stats or {} end
  local B = ref("bases")
  local r = B and B.get and B.get(id)
  return (r and r.stats) or {}
end

-- ── stats, credited by the systems that move things ─────────────────────────
local pending = {}       -- id → stats table not yet written
local function stats_table(id)
  local st = pending[id]
  if st then return st end
  local cur = statsOf(id)
  st = {}
  for k, v in pairs(cur) do st[k] = v end
  pending[id] = st
  return st
end
-- Credit `amount` (kg, or cycles for "r") to field i | o | m | w | r of the
-- base at a body-relative point (nothing when it is in no base).
function creditAt(body, x, y, z, field, amount, t)
  if not (body and x and amount and amount > 0) then return nil end
  local p = placeAt(body, x, y, z)
  if not p then return nil end
  statsAdd(stats_table(p.id), field, amount, t or agency_now())
  stats.credits = stats.credits + 1
  return p.id
end
function credit(id, field, amount, t)
  if id == nil or not amount or amount <= 0 then return end
  statsAdd(stats_table(id), field, amount, t or agency_now())
  stats.credits = stats.credits + 1
end
function flush()
  if not next(pending) then return end
  local B = ref("bases")
  for id, st in pairs(pending) do
    if id == 0 then
      local h = home_rec()
      h.stats = st
      if save and save.set then save.set("bases.home", h) end
    elseif B and B.setStats then
      B.setStats(id, st)
    end
  end
  pending = {}
end

-- logistics' step (X5/X6): what the quarries made (MINED), what the machines
-- worked (WORKED), what went down a loading chute (OUT). `w` its world entry,
-- `rep` item_net.advance's report.
local key_place = {}     -- piece key → place id | false (until the bases change)
local key_ver = nil
local function piece_place(w, P)
  local B = ref("bases")
  local v = (B and B.version or -1)
  if v ~= key_ver then key_place, key_ver = {}, v end
  local k = w.body .. "|" .. tostring(P.key)
  local id = key_place[k]
  if id == nil then
    local p = placeAt(w.body, P.gx, P.gy, P.gz)
    id = p and p.id or false
    key_place[k] = id
  end
  return id or nil
end
function creditStep(w, rep)
  if not (w and rep and w.net) then return end
  local t = agency_now()
  local nodes = w.net.nodes
  for i, made in pairs(rep.made or {}) do
    local P = nodes[i] and w.byKey[nodes[i].key]
    local id = P and piece_place(w, P)
    if id then for _, kg in pairs(made) do credit(id, "m", kg, t) end end
  end
  for i, worked in pairs(rep.conv or {}) do
    local P = nodes[i] and w.byKey[nodes[i].key]
    local id = P and piece_place(w, P)
    if id then for _, kg in pairs(worked) do credit(id, "w", kg, t) end end
  end
  for k, kg in pairs(rep.moved or {}) do
    if kg > 0 then
      local u, d = k:match("^(%d+)|(%d+)|")
      d = tonumber(d)
      if d and nodes[d] and nodes[d].kind == "chute" then
        local P = w.byKey[nodes[d].key]
        local id = P and piece_place(w, P)
        if id then credit(id, "o", kg, t) end
      end
    end
  end
end

-- route_ops (X3): a run's actions done in one advance, and the cycles it
-- completed. A load from a store is OUT for the base it stands in, an unload
-- IN (the Intake's is the spaceport's); a cycle is a RUN for every base it
-- touches.
local function phase_where(run, a)
  for i, acts in pairs(run.acts or {}) do
    for _, x in ipairs(acts) do
      if x == a then
        local ph = run.phases and run.phases[tonumber(i) or i]
        if ph and ph.k == "stop" and run.stops[ph.at] then return run.stops[ph.at] end
        return run.stand
      end
    end
  end
  return run.stand
end
function creditRun(run, log, cycles)
  if not run then return end
  local t = agency_now()
  for _, a in ipairs(log or {}) do
    local kg = (a.n or 0) * kg_of(a.mat)
    if a.op == "load" then
      local s = phase_where(run, a)
      if s then creditAt(s.body, s.x, s.y, s.z, "o", kg, t) end
    elseif a.dst == "intake" then
      credit(0, "i", kg, t)
    else
      local s = phase_where(run, a)
      if s then creditAt(s.body, s.x, s.y, s.z, "i", kg, t) end
    end
  end
  if (cycles or 0) > 0 then
    local seen = {}
    local function touch(s)
      local p = s and placeAt(s.body, s.x, s.y, s.z)
      if p and not seen[p.id] then seen[p.id] = true; credit(p.id, "r", cycles, t) end
    end
    touch(run.stand)
    for _, s in ipairs(run.stops or {}) do touch(s) end
  end
end

-- ── the census ──────────────────────────────────────────────────────────────
local function blank() return { stands = 0, runs = 0, hoses = 0, fuelTanks = 0, fuelKg = 0, electro = 0, drives = 0, machines = 0,
                                survey = 0, storeCap = 0, storeKg = 0, defence = 0, parts = 0, structures = 0, sweeping = false } end
local function scientists_at(p, R)
  local C = ref("crew")
  if not (C and C.roster) then return false end
  local B = ref("bases")
  local RAD = (B and B.RADIUS) or 150
  for _, c in ipairs(C.roster()) do
    local role = c.role or (C.role and C.role(c.id))
    if role == "scientist" then
      if p.home and c.status == "base" then return true end
      if c.status == "afoot" and c.body == p.b and tonumber(c.x) then
        local d = B and B.groundDist and B.groundDist(R, c.x, c.y, c.z, p.x, p.y, p.z) or RAD + 1
        if d <= RAD then return true end
      end
    end
  end
  return false
end

function runCensus()
  local w0 = wall()
  local ST, B = ref("structures"), ref("bases")
  if not (ST and ST.list and B) then return 0 end
  local RAD = B.RADIUS or 150
  local list = places_now()
  local C = {}
  local by_body = {}
  for _, p in ipairs(list) do
    C[p.id] = blank()
    by_body[p.b] = by_body[p.b] or {}
    table.insert(by_body[p.b], p)
  end
  local FN, LX, SV = ref("fluid_net"), ref("logistics"), ref("survey")
  local inv = ref("inventory")
  local nparts = 0
  local Rcache = {}
  for _, rec in ipairs(ST.list()) do
    local cand = by_body[rec.b]
    if cand then
      local R = Rcache[rec.b]
      if R == nil then R = radius_of(rec.b) or false; Rcache[rec.b] = R end
      -- (a structure far from every base on its world is skipped whole)
      local near = false
      for _, p in ipairs(cand) do
        if math.sqrt((rec.x - p.x) ^ 2 + (rec.y - p.y) ^ 2 + (rec.z - p.z) ^ 2) <= RAD + 400 then near = true break end
      end
      if near then
        local counted = {}
        for _, part in ipairs(rec.bp or {}) do
          local d = defs(part.id)
          if d then
            local px, py, pz = ST.partPose(rec, part, 0)
            local p, bd = nil, RAD
            for _, q in ipairs(cand) do
              local dd = B.groundDist(R or nil, px, py, pz, q.x, q.y, q.z)
              if dd <= bd then p, bd = q, dd end
            end
            if p then
              local c = C[p.id]
              nparts = nparts + 1
              c.parts = c.parts + 1
              if not counted[p.id] then counted[p.id] = true; c.structures = c.structures + 1 end
              local it, fl = d.it, d.fl
              if d.stand then c.stands = c.stands + 1 end
              if fl and fl.hose then c.hoses = c.hoses + 1 end
              if fl and fl.kind == "tank" and fl.sub == "fuel" then
                c.fuelTanks = c.fuelTanks + 1
                local kg = FN and FN.content and FN.content(rec.id, part.uid)
                c.fuelKg = c.fuelKg + (tonumber(kg) or 0)
              end
              if it then
                if it.kind == "electro" then c.electro = c.electro + 1
                elseif it.kind == "drive" then c.drives = c.drives + 1
                elseif it.kind == "machine" or it.kind == "fab" then c.machines = c.machines + 1 end
                if it.kind == "hopper" or it.kind == "silo" then
                  c.storeCap = c.storeCap + (it.kg or 0)
                  local cid = LX and LX.storeCid and LX.storeCid(it, rec.id, part.uid)
                  if cid and inv and inv.mass then c.storeKg = c.storeKg + (inv.mass(cid) or 0) end
                end
              end
              if d.survey then
                c.survey = c.survey + 1
                if SV and SV.jobOf and SV.jobOf(rec.id, part.uid) then c.sweeping = true end
              end
              if d.defence then c.defence = c.defence + 1 end
            end
          end
        end
      end
    end
  end
  -- the runs that touch each base
  local RO = ref("route_ops")
  if RO and RO.list then
    for _, r in ipairs(RO.list() or {}) do
      if r.state ~= "cancelled" then
        local seen = {}
        local function touch(s)
          local p = s and placeAt(s.body, s.x, s.y, s.z)
          if p and C[p.id] and not seen[p.id] then seen[p.id] = true; C[p.id].runs = C[p.id].runs + 1 end
        end
        touch(r.stand)
        for _, s in ipairs(r.stops or {}) do touch(s) end
      end
    end
  end
  -- power, the crew, the last 24 h; then the roles
  local BT = ref("base_tower")
  local t = agency_now()
  local any = false
  for _, p in ipairs(list) do
    local c = C[p.id]
    if not p.home and BT and BT.power then
      local ok, pw = pcall(BT.power, p.id)
      if ok and pw then c.supply, c.need = pw.supply or 0, pw.need or 0 end
    end
    c.scientist = scientists_at(p, radius_of(p.b))
    local st = pending[p.id] or statsOf(p.id)
    c.mined24 = stats24(st, "m", t)
    c.worked24 = stats24(st, "w", t)
    local tg, wy = targetsOf(c)
    why[p.id] = wy
    census[p.id] = c
    local prev, prevT
    if p.home then local h = home_rec(); prev, prevT = h.roles, h.rt
    else prev, prevT = p.rec and p.rec.roles, p.rec and p.rec.rt end
    local roles, changed = step(prev, tg, prevT and math.max(0, t - prevT) or 0)
    if p.home then
      local h = home_rec()
      if changed or not h.rt or t - h.rt >= 3600 then
        h.roles, h.rt = roles, t
        if pending[0] then h.stats = pending[0]; pending[0] = nil end
        if save and save.set then save.set("bases.home", h) end
      end
    elseif B.setRoles and (changed or not (p.rec and p.rec.rt) or t - (p.rec.rt or 0) >= 3600) then
      B.setRoles(p.id, roles, t)
    end
    if changed then any = true end
  end
  if any then version = version + 1 end
  stats.ms = (wall() - w0) * 1000
  stats.census = stats.census + 1
  stats.bases = #list
  stats.parts = nparts
  return #list
end

-- ── for the contracts and the PROGRAMME (missions.lua) ──────────────────────
-- The bases on `body` (nil = any) carrying role `r` (nil = any base),
-- `offHome` = not on the home world. → { place… }
function basesWith(r, body, offHome)
  local out = {}
  local hb = save and save.get and save.get("base.body")
  for _, p in ipairs(places_now()) do
    if (not body or p.b == body) and not (offHome and (p.home or p.b == hb)) then
      if not r or shown(rolesOf(p.id), r) then out[#out + 1] = p end
    end
  end
  return out
end
-- kg of `mat` in the hoppers and silos (and machine and Fabricator stores) of base id
local stock_cache = {}
local function stock_now(id, mat)
  local LX, inv = ref("logistics"), ref("inventory")
  if not (LX and LX.worlds and inv and inv.count) then return 0 end
  local p = nil
  for _, q in ipairs(places_now()) do if q.id == id then p = q end end
  if not p then return 0 end
  local w = LX.worlds[p.b]
  if not w then return 0 end
  local n = 0
  for _, P in ipairs(w.pieces or {}) do
    if P.cid and piece_place(w, P) == id then n = n + (inv.count(P.cid, mat) or 0) end
  end
  return n * kg_of(mat)
end
-- (the contract's goal asks every frame: read at most twice a second)
function stockOf(id, mat)
  local k = tostring(id) .. "|" .. tostring(mat)
  local c = stock_cache[k]
  local now = time or 0
  if c and now - c.t < 0.5 and now >= c.t then return c.v end
  local v = stock_now(id, mat)
  stock_cache[k] = { t = now, v = v }
  return v
end
-- run cycles completed through base id (its stats: every cycle credited)
function cyclesOf(id) local st = pending[id] or statsOf(id); return st.r or 0 end
-- kg worked by machines in bases off the home world, ever
function workedOffHome()
  local n = 0
  for _, p in ipairs(basesWith(nil, nil, true)) do
    local st = pending[p.id] or statsOf(p.id)
    n = n + (st.w or 0)
  end
  return n
end

-- (probes) a census now
function censusNow() return runCensus() end

-- ── frame ───────────────────────────────────────────────────────────────────
local seen_st, seen_b, seen_r = nil, nil, nil
local last_wall, last_agency, flush_t = -1e9, nil, 0
function start(node)
  if findScripts then
    local all = findScripts("base_roles")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  census, why, pending = {}, {}, {}
  seen_st, seen_b, seen_r, last_agency = nil, nil, nil, nil
  place_ver, home_pt = nil, nil
end

local look_t = -1e9
function update(node, dt)
  local now = time or 0
  -- (one compare a frame: the versions are looked at twice a second, a
  -- census at most every CENSUS_GAP)
  if now - look_t < 0.5 and now >= look_t then return end
  look_t = now
  if now - flush_t >= FLUSH_EVERY then flush_t = now; flush() end
  if now - last_wall < CENSUS_GAP then return end
  local ST, B, RO = ref("structures"), ref("bases"), ref("route_ops")
  if not (ST and B and save and save.get and save.get("system.home")) then return end
  -- (the runs by their count: a run's phases move its version every leg)
  local sv, bv, rv = ST.version, B.version, RO and RO.list and #(RO.list() or {}) or 0
  local a = agency_now()
  if sv ~= seen_st or bv ~= seen_b or rv ~= seen_r or not last_agency or a - last_agency >= CENSUS_EVERY then
    last_wall = now
    seen_st, seen_b, seen_r, last_agency = sv, bv, rv, a
    local ok, err = pcall(runCensus)
    if not ok and log then log("base_roles: census failed — " .. tostring(err)) end
  end
end
