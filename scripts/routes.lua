-- ROUTES — fly a mission once, then automate it (expansion X3, "Runs I";
-- docs/base-building.md §21, the plan's §2 with Ty's answers of 2026-11-09).
--
-- PURE. No engine calls: the scene half (scripts/route_ops.lua) records the
-- FLIGHT LOG of a craft commissioned on a Build Stand, hands it here when the
-- craft is returned to a stand, and steps the RUNS made from it on the agency
-- clock through a small world adapter `W` (inventory, the Intake, the crew).
--
-- TY'S RULES (binding, §14 of the plan):
--   * a run NEVER fails at random: there is no failure roll. It replays a
--     proven flight exactly: every cycle costs what the flight cost (its fuel,
--     its time, what it took from stores) and delivers what it delivered;
--   * only a flight that CLOSED can be automated: back on the stand it left
--     from, whole, and repeatable from what it came back with (the stand
--     refuels a craft it holds — the anchored rule, vessel_controller — and the
--     home stand trades the hold with the warehouse). Anything else is refused
--     and `fromLog` says why in plain words;
--   * crewed runs need a Pilot among the crew who flew it; the crew go with
--     the run (their air and suits restock at home, so a crewed run's stand is
--     on the home world).
--
-- THE LOG (route_ops builds it; body-relative points only, rule 1 of
-- docs/positions-and-frames.md):
--   { v, sid, uid, body, name, n (parts), fuel0, hold0 = {mat = n}, t0 (the
--     agency clock at commission), tDep (released), home (the stand is on the
--     home world), intake (it is within reach of the Intake's trucks),
--     crew = { [id] = true } (seated during the flight), full (the log hit
--     MAX_EVENTS),
--     stops = { { body, x, y, z, tA, tL, fuelA, fuelL, home } … },
--     xfers = { { at = "dep" | k | "arr", mat, n (> 0 into the hold, < 0 out),
--                 src | dst (a store's container id, "hand" = a crew pack) } },
--     path  = { { body, x, y, z, t } … } (≤ PATH_MAX, for the map only),
--     ended = { t, fuel, n, cmd (a command part aboard), hold = {mat = n},
--               sid, uid } }
--
-- THE RUN: `fromLog` folds a closed log into
--   { v, name, sid, uid, body, craft, hold (container id), stand = { body, x,y,z },
--     stops = { { body, x, y, z, label } }, phases = { { k = "dwell"|"leg"|"stop",
--     dur, to, at, path } }, acts = { [phase] = { { op, mat, n, src|dst } } },
--     fuel (kg a cycle), dur (s a cycle), crew = { ids }, crewed, pilotNeeded,
--     delivers = { mat = n } }
-- and `begin` gives it its clock: state ("run" | "waiting" | "paused"), ph
-- (the phase), t0 (the agency clock at the phase's start), cycles, moved
-- (delivered, by material), rp (research points the Intake earned), why.
--
-- advance(run, W, now) walks phases until `now`: one long call equals many
-- short ones exactly (the phases are fixed durations; the guards read only
-- stores the run itself changes). poseAt(run, now) is where the craft is
-- drawn (a stop, the stand, or the leg's recorded path interpolated in the
-- body frame — map only, never physics). events(run, now) is the NEXT list,
-- situation(run, now) the line under its name.

V = 1
MAX_EVENTS = 64          -- stops + transfers a log keeps; past that it says so
PATH_MAX = 16            -- map samples a log keeps (decimated)
DWELL = 120              -- s on the stand between cycles: unload, refuel, checks
STAND_NEAR = 30          -- m: this near the stand is "at the stand" (no stop here)
INTAKE_R = 3000          -- m: a home stand this near the spaceport trades with the Intake
MAX_STEPS = 4000         -- phases one advance() call may walk (the rest next call)

local function fmt_kg(n) return string.format("%d", math.floor((n or 0) + 0.5)) end
function fmtTime(s)
  s = math.max(0, math.floor((s or 0) + 0.5))
  if s >= 86400 then return string.format("%d d %d h", math.floor(s / 86400), math.floor(s % 86400 / 3600)) end
  if s >= 3600 then return string.format("%d h %02d m", math.floor(s / 3600), math.floor(s % 3600 / 60)) end
  if s >= 60 then return string.format("%d m %02d s", math.floor(s / 60), s % 60) end
  return string.format("%d s", s)
end
local fmt_t = fmtTime

local function copy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = copy(v) end
  return o
end
deepCopy = copy

local function sorted(t)
  local ks = {}
  for k in pairs(t or {}) do ks[#ks + 1] = k end
  table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
  return ks
end

-- A list of {mat, n} as words: "20 iron, 6 copper" (labels by `L(mat)`).
function goodsText(list, L)
  local parts = {}
  for _, g in ipairs(list or {}) do
    parts[#parts + 1] = string.format("%d %s", g.n, L and L(g.mat) or g.mat)
  end
  return table.concat(parts, ", ")
end

-- ── THE LOG: small helpers route_ops uses while it records ─────────────────

-- A new log at commission.
function newLog(o)
  return { v = V, sid = o.sid, uid = o.uid, body = o.body, name = o.name, n = o.n or 0, fuel0 = o.fuel or 0,
           hold0 = copy(o.hold or {}), t0 = o.t or 0, home = o.home == true, intake = o.intake == true,
           stand = o.stand and copy(o.stand) or nil, crew = {}, stops = {}, xfers = {}, path = {} }
end

local function events_of(L) return #L.stops + #L.xfers end

-- Keep the map path short: past PATH_MAX, drop every other interior sample.
function addPath(L, p)
  local path = L.path
  path[#path + 1] = { body = p.body, x = p.x, y = p.y, z = p.z, t = p.t }
  if #path > PATH_MAX then
    local out = { path[1] }
    for i = 2, #path - 1 do if i % 2 == 0 then out[#out + 1] = path[i] end end
    out[#out + 1] = path[#path]
    L.path = out
  end
end

-- A transfer into (n > 0) or out of (n < 0) the hold, at `at`.
function addXfer(L, at, mat, n, peer)
  if events_of(L) >= MAX_EVENTS then L.full = true return false end
  local x = { at = at, mat = mat, n = n }
  if n > 0 then x.src = peer else x.dst = peer end
  L.xfers[#L.xfers + 1] = x
  return true
end

function addStop(L, s)
  if events_of(L) >= MAX_EVENTS then L.full = true return nil end
  L.stops[#L.stops + 1] = { body = s.body, x = s.x, y = s.y, z = s.z, tA = s.t, fuelA = s.fuel, home = s.home == true }
  return #L.stops
end

-- THE PACK LEDGER: every move a crew pack makes passes through here, so a
-- load into the hold knows where its units came from (a store, or the crew's
-- own hands) and an unload knows where they went. `led` = { via = { pack =
-- { mat = { {src, n} } } }, out = { pack = { mat = n } } } (route_ops keeps
-- one a log). `isHold(cid)`, `isPack(cid)`. Calls `put(mat, n, peer)` for
-- each hold change: + a load from `peer`, − an unload to `peer`.
function ledger(led, mv, isHold, isPack, put)
  led.via, led.out = led.via or {}, led.out or {}
  local from, to, mat, n = mv.from, mv.to, mv.mat, mv.n or 0
  if n <= 0 then return end
  local fh, th, fp, tp = isHold(from), isHold(to), isPack(from), isPack(to)
  if th and fh then return end
  if th then
    if fp then
      -- out of a pack: the units it took from stores first, the rest by hand
      local q = (led.via[from] or {})[mat] or {}
      local left = n
      while left > 0 and #q > 0 do
        local e = q[1]
        local k = math.min(left, e.n)
        put(mat, k, e.src)
        e.n, left = e.n - k, left - k
        if e.n <= 0 then table.remove(q, 1) end
      end
      if left > 0 then put(mat, left, "hand") end
    else
      put(mat, n, from)
    end
  elseif fh then
    if tp then
      local o = led.out[to] or {}
      o[mat] = (o[mat] or 0) + n
      led.out[to] = o
    else
      put(mat, -n, to)
    end
  elseif tp and not fp then
    -- a store into a pack: remembered, in case it goes on into the hold
    local v = led.via[to] or {}
    local q = v[mat] or {}
    q[#q + 1] = { src = from, n = n }
    v[mat] = q
    led.via[to] = v
  elseif fp and not tp then
    -- a pack into a store: what it had taken out of the hold is unloaded there
    local o = led.out[from] or {}
    local k = math.min(n, o[mat] or 0)
    if k > 0 then
      o[mat] = o[mat] - k
      put(mat, -k, to)
    end
    -- (and what it had taken from a store goes back: no longer in the pack)
    local q = (led.via[from] or {})[mat]
    local left = n - k
    while q and left > 0 and #q > 0 do
      local e = q[1]
      local c = math.min(left, e.n)
      e.n, left = e.n - c, left - c
      if e.n <= 0 then table.remove(q, 1) end
    end
  end
end

-- ── FROM A LOG TO A RUN ─────────────────────────────────────────────────────

local function store_label(cid, Lbl)
  if cid == "base" then return "the warehouse" end
  if Lbl and Lbl(cid) then return Lbl(cid) end
  return tostring(cid)
end

local function net_into(acc, mat, n) acc[mat] = (acc[mat] or 0) + n end

-- Fold a closed log into a run. opts = { label = mat → name, store = cid →
-- name, home = name of the home world }. → run | nil, why (plain words).
function fromLog(L, opts)
  opts = opts or {}
  local LB = opts.label
  if type(L) ~= "table" then return nil, "no flight was recorded for this craft: commission it here and fly it" end
  if not L.ended then return nil, "it hasn't come back to a stand yet" end
  local E = L.ended
  if L.full then return nil, string.format("the flight log filled up (%d stops and transfers): fly a shorter route", MAX_EVENTS) end
  if E.sid ~= L.sid or E.uid ~= L.uid then
    return nil, "it came back to a different stand: a run starts and ends on the same stand, so each cycle starts where the last one did"
  end
  if not L.tDep then return nil, "it never left the stand" end
  if E.cmd == false then return nil, "it came back without its command part" end
  if (E.n or 0) < (L.n or 0) then
    return nil, string.format("it came back with %d of its %d parts: what it dropped or lost isn't rebuilt each cycle, so a run repeats only a craft that comes back whole",
      E.n or 0, L.n or 0)
  end
  if #L.stops == 0 then
    return nil, "it never stopped anywhere away from the stand: a run needs a stop to load or unload at"
  end
  -- fuel: what the cycle burns (the stand refills what it holds)
  local refuel = 0
  for k, s in ipairs(L.stops) do
    local got = (s.fuelL or s.fuelA or 0) - (s.fuelA or 0)
    if got > 0.5 then
      if not s.home then
        return nil, string.format("it took on %s kg of fuel at stop %d, off the home world: a run can't draw on a base's tanks yet; land it with what it needs, or refuel only on the stand",
          fmt_kg(got), k)
      end
      refuel = refuel + got
    end
  end
  local fuel = math.max(0, (L.fuel0 or 0) - (E.fuel or 0) + refuel)
  local crewed = next(L.crew or {}) ~= nil
  if crewed and not L.home then
    return nil, "a crewed run's air and suits restock at home: its stand has to be on the home world"
  end
  -- the transfers, by place, netted per material and peer; and the hold
  -- they would leave (from what it held at commission)
  local by = {}            -- at → { key = {op, mat, n, peer} }
  local order = {}
  local sim = copy(L.hold0 or {})
  for _, x in ipairs(L.xfers or {}) do
    local peer = x.src or x.dst or "hand"
    if (x.n or 0) < 0 and peer == "hand" then
      return nil, string.format("%d %s left the hold by hand%s and wasn't put in a store: a run can only unload into a store or the Intake",
        -x.n, LB and LB(x.mat) or x.mat, type(x.at) == "number" and (" at stop " .. x.at) or "")
    end
    if (x.n or 0) > 0 and peer == "hand" and not crewed then
      return nil, string.format("the %d %s loaded%s came out of the crew's pack (gathered by hand): a probe run can only load from a store that stays there (a supply crate, a locker, the warehouse). Fly it with the crew aboard to make a crewed run",
        x.n, LB and LB(x.mat) or x.mat, type(x.at) == "number" and (" at stop " .. x.at) or "")
    end
    local at = x.at
    if not by[at] then by[at] = {}; order[#order + 1] = at end
    local key = (x.n > 0 and "L" or "U") .. "|" .. x.mat .. "|" .. peer
    local e = by[at][key]
    if not e then e = { op = x.n > 0 and "load" or "unload", mat = x.mat, n = 0, peer = peer }; by[at][key] = e end
    e.n = e.n + math.abs(x.n)
    net_into(sim, x.mat, x.n)
  end
  -- what it came back with against what it started with: the home stand
  -- trades the difference with the Intake / the warehouse
  local surplus, deficit = {}, {}
  local hold1 = E.hold or {}
  local mats = {}
  for m in pairs(hold1) do mats[m] = true end
  for m in pairs(L.hold0 or {}) do mats[m] = true end
  for _, m in ipairs(sorted(mats)) do
    local d = (hold1[m] or 0) - ((L.hold0 or {})[m] or 0)
    if d > 0 then surplus[#surplus + 1] = { mat = m, n = d } elseif d < 0 then deficit[#deficit + 1] = { mat = m, n = -d } end
  end
  if (#surplus > 0 or #deficit > 0) and not (L.home and L.intake) then
    if #surplus > 0 then
      return nil, string.format("it came back with %s more in the hold than it left with, and this stand is out of reach of the Intake: unload it into a store before you return it to the stand",
        goodsText(surplus, LB))
    end
    return nil, string.format("it came back with %s less in the hold than it left with, and only a stand by the spaceport can restock it from the warehouse",
      goodsText(deficit, LB))
  end
  -- legs and stops, with their recorded times
  local stand = L.stand or { body = L.body, x = 0, y = 0, z = 0 }
  local run = { v = V, name = nil, sid = L.sid, uid = L.uid, body = L.body, craft = L.name, hold = "hold:" .. tostring(L.name),
                stand = copy(stand), stops = {}, phases = {}, acts = {}, fuel = fuel, crewed = crewed, crew = {},
                delivers = {}, takes = {}, n = L.n }
  for id in pairs(L.crew or {}) do run.crew[#run.crew + 1] = id end
  table.sort(run.crew, function(a, b) return tostring(a) < tostring(b) end)
  local function act_list(at)
    local out = {}
    local e = by[at]
    if not e then return out end
    for _, k in ipairs(sorted(e)) do
      local a = e[k]
      local o = { op = a.op, mat = a.mat, n = a.n }
      if a.op == "load" then o.src = a.peer else o.dst = a.peer end
      out[#out + 1] = o
    end
    return out
  end
  local function path_between(t0, t1, from, to)
    local out = { { body = from.body, x = from.x, y = from.y, z = from.z, f = 0 } }
    local span = math.max(1e-6, t1 - t0)
    for _, p in ipairs(L.path or {}) do
      if p.t > t0 + 1e-6 and p.t < t1 - 1e-6 then
        out[#out + 1] = { body = p.body, x = p.x, y = p.y, z = p.z, f = (p.t - t0) / span }
      end
    end
    out[#out + 1] = { body = to.body, x = to.x, y = to.y, z = to.z, f = 1 }
    return out
  end
  -- 1. the dwell on the stand (the arrival's trades happen as it begins,
  -- the departure's as it ends)
  run.phases[1] = { k = "dwell", dur = DWELL }
  local arr, dep = act_list("arr"), act_list("dep")
  for _, d in ipairs(surplus) do arr[#arr + 1] = { op = "unload", mat = d.mat, n = d.n, dst = "intake" } end
  for _, d in ipairs(deficit) do dep[#dep + 1] = { op = "load", mat = d.mat, n = d.n, src = "base" } end
  run.arrive = arr
  run.acts[1] = dep
  local prev, tprev = stand, L.tDep
  for k, s in ipairs(L.stops) do
    local stop = { body = s.body, x = s.x, y = s.y, z = s.z, label = "stop " .. k }
    run.stops[k] = stop
    run.phases[#run.phases + 1] = { k = "leg", to = k, dur = math.max(1, (s.tA or tprev) - tprev), path = path_between(tprev, s.tA or tprev, prev, stop) }
    local tl = s.tL or s.tA or tprev
    run.phases[#run.phases + 1] = { k = "stop", at = k, dur = math.max(1, tl - (s.tA or tl)) }
    run.acts[#run.phases] = act_list(k)
    prev, tprev = stop, tl
  end
  run.phases[#run.phases + 1] = { k = "leg", to = 0, dur = math.max(1, (E.t or tprev) - tprev), path = path_between(tprev, E.t or tprev, prev, stand) }
  -- (a dense list, one per phase: the save's JSON keeps no holes)
  for i = 1, #run.phases do run.acts[i] = run.acts[i] or {} end
  -- what a cycle moves: everything that ends in a store or the Intake
  local any = false
  for i, list in pairs(run.acts) do
    for _, a in ipairs(list) do
      if a.op == "unload" then net_into(run.delivers, a.mat, a.n); any = true else net_into(run.takes, a.mat, a.n) end
    end
  end
  for _, a in ipairs(run.arrive) do
    if a.op == "unload" then net_into(run.delivers, a.mat, a.n); any = true else net_into(run.takes, a.mat, a.n) end
  end
  if not any then
    return nil, "nothing was delivered: a run has to carry something from one place to another (load at a stop, unload at another or at the Intake)"
  end
  local dur = 0
  for _, p in ipairs(run.phases) do dur = dur + p.dur end
  run.dur = dur
  local dl = {}
  for _, m in ipairs(sorted(run.delivers)) do dl[#dl + 1] = { mat = m, n = run.delivers[m] } end
  run.name = string.format("%s run · %s", tostring(L.name or "Craft"), dl[1] and (LB and LB(dl[1].mat) or dl[1].mat) or "cargo")
  return run
end

-- The run against the world as it is now (the stores, the crew, the stand).
-- W = { count(cid, mat), exists(cid), crewOk(id) → ok, why (alive, a member,
--       not the one you play), isPilot(id), standOk() → ok, why }.
-- → ok, why
function check(run, W)
  if W.standOk then local ok, why = W.standOk(run); if not ok then return false, why end end
  if run.crewed then
    local pilot = false
    for _, id in ipairs(run.crew) do
      local ok, why = W.crewOk(id)
      if not ok then return false, why end
      if W.isPilot(id) then pilot = true end
    end
    if not pilot then return false, "no Pilot flew it: a crewed run needs a Pilot among its crew" end
  end
  local function store_ok(cid)
    if cid == "hand" or cid == "intake" or cid == "base" then return true end
    return not W.exists or W.exists(cid)
  end
  for _, list in pairs(run.acts) do
    for _, a in ipairs(list) do
      local c = a.src or a.dst
      if not store_ok(c) then return false, "the store it used (" .. tostring(c) .. ") is gone" end
    end
  end
  return true
end

-- ── THE SCHEDULE ────────────────────────────────────────────────────────────

-- Give a run its clock: it starts in the dwell, the arrival's trades done
-- now (what the recorded flight brought back is unloaded first).
function begin(run, W, now, id)
  run.id = id or run.id
  run.state, run.ph, run.t0, run.cycles, run.moved, run.rp, run.why = "run", 1, now, 0, {}, 0, nil
  run.started = now
  local log = {}
  for _, a in ipairs(run.arrive or {}) do apply(run, W, a, log) end
  run.last = log[1]
  return run
end

-- Is this action possible now? → ok, why
function guardAct(run, W, a)
  if a.op == "load" then
    if a.src == "hand" then return true end
    local have = W.count(a.src, a.mat)
    if have < a.n then
      return false, string.format("waiting for %s: %d of %d %s", W.storeName and W.storeName(a.src) or store_label(a.src), have, a.n,
        W.label and W.label(a.mat) or a.mat)
    end
    if W.room and W.room(run.hold, a.mat) < a.n then return false, "the hold is full" end
  elseif a.op == "unload" then
    if W.count(run.hold, a.mat) < a.n then
      return false, string.format("the hold has %d of the %d %s to unload", W.count(run.hold, a.mat), a.n, W.label and W.label(a.mat) or a.mat)
    end
    if a.dst ~= "intake" and W.room and W.room(a.dst, a.mat) < a.n then
      return false, string.format("%s is full", W.storeName and W.storeName(a.dst) or store_label(a.dst))
    end
  end
  return true
end

-- Do it (the guard passed). Appends a line to `log`.
function apply(run, W, a, log)
  if a.op == "load" then
    if a.src == "hand" then W.add(run.hold, a.mat, a.n, a.origin)
    else W.move(a.src, run.hold, a.mat, a.n) end
  elseif a.dst == "intake" then
    local rp = W.intake(run.hold, a.mat, a.n) or 0
    run.rp = (run.rp or 0) + rp
    net_into(run.moved, a.mat, a.n)
  else
    W.move(run.hold, a.dst, a.mat, a.n)
    net_into(run.moved, a.mat, a.n)
  end
  if log then log[#log + 1] = a end
end

-- The guard at the END of phase i: every action there possible, and the crew
-- ready to leave (a dwell's end is a departure).
local function guard(run, W, i)
  -- (a run being cancelled goes home: what can't be done on the way is skipped)
  if run.cancel then return true end
  for _, a in ipairs(run.acts[i] or {}) do
    local ok, why = guardAct(run, W, a)
    if not ok then return false, why end
  end
  local ph = run.phases[i]
  if ph.k == "dwell" and run.crewed and W.crewReady then
    for _, id in ipairs(run.crew) do
      local ok, why = W.crewReady(id)
      if not ok then return false, why end
    end
  end
  return true
end

-- Phase i is over at t: its actions, then the next phase (and the arrival's
-- trades when the next is the dwell).
local function finish(run, W, i, t, log)
  local stops = run.phases[i] and run.phases[i].at
  for _, a in ipairs(run.acts[i] or {}) do
    if a.op == "load" and a.src == "hand" and stops then
      local s = run.stops[stops]
      a.origin = s and s.body ~= (W.home or run.body) and s.body or nil
    end
    if not run.cancel or guardAct(run, W, a) then apply(run, W, a, log) end
  end
  local nxt = i + 1
  if nxt > #run.phases then
    nxt = 1
    run.cycles = (run.cycles or 0) + 1
    for _, a in ipairs(run.arrive or {}) do
      local ok = guardAct(run, W, a)
      if ok then apply(run, W, a, log) end
    end
    if run.cancel then run.state = "cancelled" end
  end
  run.ph, run.t0 = nxt, t
end

-- Walk the schedule to `now`. → n phases walked, { actions done }
function advance(run, W, now)
  local walked, log = 0, {}
  while walked < MAX_STEPS do
    if run.state == "paused" or run.state == "cancelled" then break end
    local i = run.ph
    local ph = run.phases[i]
    if not ph then break end
    if run.state == "waiting" then
      local ok, why = guard(run, W, i)
      if not ok then run.why = why break end
      run.state, run.why = "run", nil
      finish(run, W, i, math.max(run.t0 + ph.dur, now), log)
      walked = walked + 1
    else
      local t_end = run.t0 + ph.dur
      if now < t_end then break end
      local ok, why = guard(run, W, i)
      if not ok then
        run.state, run.why, run.waitT = "waiting", why, t_end
        break
      end
      finish(run, W, i, t_end, log)
      walked = walked + 1
    end
  end
  if #log > 0 then run.last = log[#log] end
  return walked, log
end

function pause(run, now)
  if run.state == "paused" or run.state == "cancelled" then return false end
  run.paused = { state = run.state, left = math.max(0, run.t0 + run.phases[run.ph].dur - now) }
  run.state = "paused"
  return true
end
function resume(run, now)
  if run.state ~= "paused" then return false end
  local p = run.paused or {}
  run.state = p.state == "waiting" and "waiting" or "run"
  run.t0 = now - (run.phases[run.ph].dur - (p.left or 0))
  run.paused = nil
  return true
end

-- On the stand now (the craft is drawn there, a cancel is immediate)?
function onStand(run) return run.phases[run.ph] ~= nil and run.phases[run.ph].k == "dwell" end

-- Where the craft is at `now`: → body, x, y, z (body-relative)
function poseAt(run, now)
  local ph = run.phases[run.ph]
  if not ph then return nil end
  if ph.k == "dwell" then local s = run.stand; return s.body, s.x, s.y, s.z end
  if ph.k == "stop" then local s = run.stops[ph.at]; return s.body, s.x, s.y, s.z end
  local f = 1
  if run.state == "run" then f = math.max(0, math.min(1, (now - run.t0) / math.max(1e-6, ph.dur))) end
  if run.state == "paused" and run.paused then f = math.max(0, math.min(1, 1 - (run.paused.left or 0) / math.max(1e-6, ph.dur))) end
  local P = ph.path or {}
  if #P == 0 then local s = run.stand; return s.body, s.x, s.y, s.z end
  for i = 1, #P - 1 do
    local a, b = P[i], P[i + 1]
    if f <= b.f + 1e-12 then
      if a.body ~= b.body then
        -- (across a change of world: the nearer sample's world)
        local q = (f - a.f) < (b.f - f) and a or b
        return q.body, q.x, q.y, q.z
      end
      local u = (b.f - a.f) > 1e-9 and (f - a.f) / (b.f - a.f) or 1
      return a.body, a.x + (b.x - a.x) * u, a.y + (b.y - a.y) * u, a.z + (b.z - a.z) * u
    end
  end
  local q = P[#P]
  return q.body, q.x, q.y, q.z
end

local function where_name(run, k)
  if k == 0 or k == nil then return "the stand" end
  local s = run.stops[k]
  return s and (s.label or ("stop " .. k)) or "?"
end

-- The line under its name in the Tracking Station.
function situation(run, now, L)
  local ph = run.phases[run.ph]
  if not ph then return "" end
  if run.state == "cancelled" then return "cancelled" end
  if run.state == "paused" then return "PAUSED · " .. (ph.k == "dwell" and "on the stand" or (ph.k == "stop" and ("at " .. where_name(run, ph.at)) or "between stops")) end
  if run.state == "waiting" then return "WAITING · " .. tostring(run.why or "") end
  local left = run.t0 + ph.dur - now
  local nlegs, legi = 0, 0
  for i, p in ipairs(run.phases) do if p.k == "leg" then nlegs = nlegs + 1; if i <= run.ph then legi = nlegs end end end
  if ph.k == "leg" then
    return string.format("Leg %d/%d · to %s · %s", legi, nlegs, where_name(run, ph.to), fmt_t(left))
  elseif ph.k == "stop" then
    local what = {}
    for _, a in ipairs(run.acts[run.ph] or {}) do what[#what + 1] = string.format("%s %d %s", a.op == "load" and "loading" or "unloading", a.n, L and L(a.mat) or a.mat) end
    return string.format("At %s · %s%s", where_name(run, ph.at), #what > 0 and (table.concat(what, ", ") .. " · ") or "", fmt_t(left))
  end
  return string.format("On the stand%s · departs in %s", run.cancel and " · cancelling" or "", fmt_t(left))
end

-- The NEXT events: up to two, { t (s from now), what }.
function events(run, now)
  local out = {}
  if run.state ~= "run" then return out end
  local i, t = run.ph, run.t0 + run.phases[run.ph].dur - now
  for _ = 1, 2 do
    local ph = run.phases[i]
    local nxt = i + 1 > #run.phases and 1 or i + 1
    local what
    if ph.k == "leg" then what = ph.to == 0 and "back on its stand" or ("arrives at " .. where_name(run, ph.to))
    elseif ph.k == "stop" then what = "leaves " .. where_name(run, ph.at)
    else what = "departs the stand" end
    out[#out + 1] = { t = t, what = what }
    i = nxt
    t = t + run.phases[i].dur
  end
  return out
end

-- The manifest as lines for the card: { { where, text } … }
function manifest(run, L, S)
  local out = {}
  local function words(list)
    local w = {}
    for _, a in ipairs(list or {}) do
      if a.op == "load" then
        w[#w + 1] = string.format("load %d %s from %s", a.n, L and L(a.mat) or a.mat,
          a.src == "hand" and "the crew's digging" or (S and S(a.src) or store_label(a.src)))
      else
        w[#w + 1] = string.format("unload %d %s %s", a.n, L and L(a.mat) or a.mat,
          a.dst == "intake" and "at the Intake" or ("into " .. (S and S(a.dst) or store_label(a.dst))))
      end
    end
    return table.concat(w, " · ")
  end
  local dep = words(run.acts[1])
  if dep ~= "" then out[#out + 1] = { where = "Leaving the stand", text = dep } end
  for i, p in ipairs(run.phases) do
    if p.k == "stop" then
      local w = words(run.acts[i])
      out[#out + 1] = { where = "At " .. where_name(run, p.at), text = w ~= "" and w or "a stop" }
    end
  end
  local arr = words(run.arrive)
  if arr ~= "" then out[#out + 1] = { where = "Back on the stand", text = arr } end
  return out
end

-- The Automate row's words: "3 m 12 s · 40 kg fuel · 20 iron a cycle"
function summary(run, L)
  local dl = {}
  for _, m in ipairs(sorted(run.delivers)) do dl[#dl + 1] = { mat = m, n = run.delivers[m] } end
  return string.format("%s · %s kg fuel · %s a cycle", fmt_t(run.dur), fmt_kg(run.fuel), goodsText(dl, L))
end
