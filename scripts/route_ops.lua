-- ROUTE_OPS — the scene half of RUNS (expansion X3; docs/base-building.md §21).
-- The rules are scripts/routes.lua (pure); this script:
--
--   * RECORDS THE FLIGHT LOG of every craft commissioned on a Build Stand
--     (craft_stand calls onCommission / onRelease / onReturn / onGone). Events,
--     not telemetry, at 1 Hz while such a craft is out: where it STOPS (down
--     and still for STOP_SECS, away from the stand), the fuel then, who rides
--     it, a few map samples, and every transfer into or out of its hold
--     (inventory's move ring, traced through the crew's packs: routes.ledger).
--     Body-relative points only (docs/positions-and-frames.md rule 1). The log
--     of a craft out in the field is kept in the save by its name (its hold is
--     keyed the same way), so a save and reload mid-flight keeps it.
--   * When the craft is returned to its stand, closes the log
--     (`rlog.<sid>.<uid>`) and judges it (routes.fromLog + check). The first
--     automatable one in a save gets Ops' caption: the discovery hint.
--   * AUTOMATE (the stand's right-click; craft_stand asks standRows): the run is
--     made, the stand holds the craft for it (state "run"), the crew who flew
--     it go with it. Runs are saved as `run.<id>` (JSON: a run is deeper than
--     the save's four tables) and listed in `runs.ids`.
--   * STEPS EVERY RUN at 1 Hz on the agency clock (routes.advance, closed
--     form: catch-up on load is one call), through the world adapter W:
--     the real containers (inventory.transfer), the Intake's path for an
--     unload there (the warehouse, freight, research.study, the lab's capsule:
--     material_intake take()), the crew.
--   * Publishes the runs for the Tracking Station (entries, NEXT events, the
--     card's numbers) and draws the craft on its stand during the dwell (the
--     stand's display copy, untinted: no body, no script).
--
-- COST: nothing a frame while no craft is logged and no run exists; one
-- advance per run a second (≤ 0.02 ms) otherwise. Measured in kitprobe runs.

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not (r and r.valid ~= false) then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function agency_now()
  local dp = ref("deployables")
  if dp and dp.agencyClock then local ok, t = pcall(dp.agencyClock); if ok and type(t) == "number" then return t end end
  return tonumber(save.get("agency.clock")) or 0
end
agencyNow = agency_now
local function say(s, secs)
  if caption then pcall(caption, s, secs) end
  if log then log("runs: " .. s) end
end
local function enc(t)
  if not (json and json.encode) then return nil end
  local ok, s = pcall(json.encode, t)
  return ok and s or nil
end
local function dec(s)
  if type(s) == "table" then return s end
  if type(s) ~= "string" or not (json and json.decode) then return nil end
  local ok, t = pcall(json.decode, s)
  return ok and type(t) == "table" and t or nil
end
local function R() return ref("routes") end
local function mat_label(m) local M = ref("materials"); return (M and M.label and M.label(m)) or tostring(m) end
local function store_name(cid)
  if cid == "base" then return "the warehouse" end
  local sc = ref("supply_crates")
  if sc and sc.labelOf and type(cid) == "string" and cid:sub(1, 6) == "crate:" then
    local ok, l = pcall(sc.labelOf, cid)
    if ok and l then return l end
  end
  if type(cid) == "string" and cid:sub(1, 7) == "locker:" then return "locker " .. cid:sub(8) end
  -- (X5) a hopper, a silo, a quarry drive's bin: its label on the map
  local lx = ref("logistics")
  if lx and lx.storeLabel and type(cid) == "string" then local l = lx.storeLabel(cid); if l then return l end end
  return tostring(cid)
end
storeName = store_name

STOP_SECS = 5.0          -- down and still this long (game s) is a stop
STOP_LEAVE = 25.0        -- m from the stop's point (or moving > 1 m/s) ends it
PATH_EVERY = 15.0        -- game s between map samples while moving
version = 0              -- bumped on every change the station shows
stats = { tick_ms = 0, advance_ms = 0, runs = 0, logs = 0 }

-- ── THE STORE ───────────────────────────────────────────────────────────────
local runs = nil         -- id → run
local ids = {}
local live = nil         -- craft name → log (out in the field)
local closed = {}        -- "sid:uid" → closed log (read through)
local leds = {}          -- craft name → the pack ledger (this session)
local ctl = {}           -- craft name → controller handle (cached)
local move_seq = nil
local hinted = nil

local function wall() return (app and app.wallClock and app.wallClock()) or os.clock() end

local function load_runs()
  if runs then return end
  runs, ids = {}, {}
  local l = save.get("runs.ids")
  for _, id in ipairs(type(l) == "table" and l or {}) do
    local r = dec(save.get("run." .. tostring(id)))
    if r then r.id = id; runs[id] = r; ids[#ids + 1] = id end
  end
end
local function save_run(r)
  local s = enc(r)
  if s then save.set("run." .. tostring(r.id), s) end
  version = version + 1
end
local function save_ids() save.set("runs.ids", ids) end
local function drop_run(id)
  runs[id] = nil
  for i, x in ipairs(ids) do if x == id then table.remove(ids, i) break end end
  if save.delete then save.delete("run." .. tostring(id)) else save.set("run." .. tostring(id), false) end
  save_ids()
  version = version + 1
end

local function load_live()
  if live then return end
  live = dec(save.get("rlog.live")) or {}
end
local function save_live() load_live(); save.set("rlog.live", enc(live) or "{}") end
local function key(sid, uid) return tostring(sid) .. ":" .. tostring(uid) end
function closedLog(sid, uid)
  local k = key(sid, uid)
  if closed[k] == nil then closed[k] = dec(save.get("rlog." .. tostring(sid) .. "." .. tostring(uid))) or false end
  return closed[k] or nil
end
local function set_closed(sid, uid, L)
  closed[key(sid, uid)] = L or false
  save.set("rlog." .. tostring(sid) .. "." .. tostring(uid), L and enc(L) or false)
end

function list() load_runs(); local out = {}; for _, id in ipairs(ids) do out[#out + 1] = runs[id] end; return out end
function get(id) load_runs(); return runs[id] end
function liveLog(name) load_live(); return live[name] end

-- ── THE WORLD ADAPTER (routes' W) ───────────────────────────────────────────
local function home_body() return save.get("base.body") end
local W = {}
W.label = mat_label
W.storeName = store_name
W.count = function(cid, mat) local inv = ref("inventory"); return inv and inv.count(cid, mat) or 0 end
W.room = function(cid, mat) local inv = ref("inventory"); return inv and inv.roomFor(cid, mat, 1e9) or 0 end
W.exists = function(cid)
  if cid == "base" or cid == "intake" or cid == "hand" then return true end
  if type(cid) ~= "string" then return false end
  if cid:sub(1, 6) == "crate:" then
    local sc = ref("supply_crates")
    return not (sc and sc.layoutOf) or sc.layoutOf(tonumber(cid:sub(7))) ~= nil
  end
  -- (X5) a silo or a hopper (a quarry drive's bin too) stands while its piece does
  if cid:sub(1, 5) == "silo:" or cid:sub(1, 7) == "hopper:" then
    local lx = ref("logistics")
    return lx ~= nil and lx.storeExists ~= nil and lx.storeExists(cid)
  end
  local inv = ref("inventory")
  return inv ~= nil and (inv.cap(cid) or 0) > 0
end
W.move = function(a, b, mat, n) local inv = ref("inventory"); return inv and inv.transfer(a, b, mat, n) or 0 end
W.add = function(cid, mat, n, origin) local inv = ref("inventory"); return inv and inv.add(cid, mat, n, origin) or 0 end
-- THE INTAKE'S PATH (material_intake take(), a "mat" body): into the
-- warehouse with its origin, counted as freight, studied by the lab (RP, a
-- first-kind bonus), the capsule up the lab's tube when the lab is there.
W.intake = function(hold, mat, n)
  local inv = ref("inventory")
  if not inv then return 0 end
  local origin = nil
  local o = inv.origins and inv.origins(hold, mat) or {}
  for b in pairs(o or {}) do origin = origin or b end
  local took = inv.transfer(hold, "base", mat, n)
  if took <= 0 then return 0 end
  local fr = save.get("depot.freight") or {}
  fr[mat] = (fr[mat] or 0) + took
  save.set("depot.freight", fr)
  local rp, first = 0, false
  local rs = ref("research")
  if rs and rs.study then
    local ok, g, f = pcall(rs.study, mat, took, origin)
    if ok then rp, first = g or 0, f == true end
  end
  local lab = ref("lab")
  if lab and lab.receive then pcall(lab.receive, mat, took, rp, first) end
  if log then log(string.format("runs: the Intake took %d %s off a run (+%d RP)", took, mat_label(mat), rp)) end
  return rp
end
local function mid(id) return tonumber(id) or id end
W.crewOk = function(id)
  id = mid(id)
  local C = ref("crew")
  local r = C and C.get and C.get(id)
  if not r then return false, "a member of its crew is gone" end
  if r.status == "dead" then return false, tostring(r.name) .. " who flew it is lost" end
  if C.activeId and C.activeId() == id then
    return false, string.format("%s flew it and goes with the run, and you're playing %s: switch to someone else first (CREW ▸)", tostring(r.name), tostring(r.name))
  end
  return true
end
W.crewReady = function(id)
  id = mid(id)
  local C = ref("crew")
  local r = C and C.get and C.get(id)
  if not r or r.status == "dead" then return false, "its crew is lost" end
  if r.downed then return false, tostring(r.name) .. " is down" end
  if C.activeId and C.activeId() == id then return false, string.format("%s is needed aboard (you're playing them)", tostring(r.name)) end
  return true
end
W.isPilot = function(id) local C = ref("crew"); return C and C.role and C.role(mid(id)) == "pilot" or false end
W.standOk = function(run)
  local ST = ref("structures")
  if ST and ST.get and not ST.get(run.sid) then return false, "its stand is gone" end
  return true
end

local function judge(L, live_check)
  local Rm = R()
  if not Rm then return nil, "the routes rulebook isn't in this scene" end
  W.home = home_body()
  local run, why = Rm.fromLog(L, { label = mat_label })
  if not run then return nil, why end
  if live_check ~= false then
    local ok, w = Rm.check(run, W)
    if not ok then return nil, w, run end
  end
  return run
end
judgeLog = judge

-- ── RECORDING ───────────────────────────────────────────────────────────────
local function bag(cid)
  local inv = ref("inventory")
  local out = {}
  if not inv then return out end
  for _, it in ipairs(inv.items(cid) or {}) do out[it.mat] = (out[it.mat] or 0) + (it.n or 0) end
  return out
end
local function controller(name)
  local v = ctl[name]
  if v and v.valid ~= false and v.node and v.node.valid ~= false and v.craftName == name then return v end
  ctl[name] = nil
  for _, c in ipairs(findScripts and findScripts("vessel_controller") or {}) do
    if c.craftName == name and c.node and c.node.valid ~= false and not (c.isLost and c.isLost()) then ctl[name] = c; return c end
  end
  return nil
end

-- craft_stand: a craft commissioned on stand (sid, uid) from blueprint bp.
function onCommission(sid, uid, bp, name)
  load_live()
  local CS = ref("craft_stand")
  local fp = CS and CS.framePose and CS.framePose(sid, uid)
  if not (fp and name) then return end
  local n = 0
  for _, d in pairs(bp.parts or {}) do if d.prefab then n = n + 1 end end
  local home = home_body()
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  local Rm = R()
  local near = fp.body == home and bx ~= nil and len(fp.top.x - bx, fp.top.y - by, fp.top.z - bz) <= ((Rm and Rm.INTAKE_R) or 3000)
  local L = Rm and Rm.newLog({ sid = sid, uid = uid, body = fp.body, name = name, n = n, fuel = (bp.fuel or 0) * 10,
    hold = bag("hold:" .. name), t = agency_now(), home = fp.body == home, intake = near,
    stand = { body = fp.body, x = fp.top.x, y = fp.top.y, z = fp.top.z } })
  if not L then return end
  live[name] = L
  leds[name] = {}
  local inv = ref("inventory")
  -- (only the moves from now on are this flight's: whatever the ring held before is not)
  L.seq0 = (inv and inv.moveSeq) or 0
  if not move_seq or move_seq < L.seq0 then move_seq = L.seq0 end
  save_live()
  stats.logs = 0
  for _ in pairs(live) do stats.logs = stats.logs + 1 end
end

function onRelease(sid, uid, name)
  load_live()
  local L = name and live[name]
  if not (L and L.sid == sid and L.uid == uid) or L.tDep then return end
  L.tDep = agency_now()
  local Rm = R()
  if Rm and L.stand then Rm.addPath(L, { body = L.stand.body, x = L.stand.x, y = L.stand.y, z = L.stand.z, t = L.tDep }) end
  save_live()
end

-- The held craft went before it was released (recovered, wrecked, cleared).
function onGone(sid, uid, name)
  load_live()
  local L = name and live[name]
  if L and not L.tDep then live[name] = nil; leds[name] = nil; save_live() end
end

-- Where a hold change belongs now: an open stop, "dep" before it left,
-- "arr" back by the stand after its stops, or a stop opened here.
local function place_now(L, rec)
  if not L.tDep then return "dep" end
  if L.open then return L.open end
  if rec and rec.nearStand and #L.stops > 0 then return "arr" end
  if rec and rec.nearStand then return "dep" end
  local Rm = R()
  if rec and Rm then
    local k = Rm.addStop(L, { body = rec.body, x = rec.x, y = rec.y, z = rec.z, t = agency_now(), fuel = rec.fuel, home = rec.body == home_body() })
    if k then L.open = k; return k end
  end
  return #L.stops > 0 and #L.stops or "dep"
end

-- The craft's state now (tick poses: assembly.info), body-relative.
local function sample(L, v)
  local i = v and v.node and assembly and assembly.info(v.node)
  if not (i and i.origin) then return nil end
  local o = i.origin
  local bn = space.dominant(o.x, o.y, o.z)
  local b = bn and space.body(bn)
  if not b then return nil end
  local x, y, z = o.x - b.x, o.y - b.y, o.z - b.z
  local vel = i.vel or { x = 0, y = 0, z = 0 }
  local s = { body = bn, x = x, y = y, z = z, speed = len(vel.x, vel.y, vel.z), fuel = (v.fuel or 0) * 10,
              down = i.grounded == true or (v.r2OnWheels and v.r2OnWheels()) == true or (v.isSplashed and v.isSplashed()) == true }
  local st = L.stand
  s.nearStand = st and st.body == bn and len(x - st.x, y - st.y, z - st.z) <= ((R() and R().STAND_NEAR) or 30) or false
  return s
end

local function crew_of(v)
  local C = ref("crew")
  if not (C and C.aboard and v and v.crewCount and v.crewCount() > 0) then return {} end
  local out = {}
  for _, s in ipairs(C.aboard(v)) do out[#out + 1] = s.id end
  return out
end

local function record_tick(now)
  load_live()
  if next(live) == nil then return end
  local inv = ref("inventory")
  local Rm = R()
  if not (inv and Rm) then return end
  local dirty = false
  local recs = {}
  for name, L in pairs(live) do
    local v = controller(name)
    local s = v and sample(L, v)
    recs[name] = s
    if s and L.tDep and not L.ended then
      for _, id in ipairs(crew_of(v)) do L.crew[tostring(id)] = true end
      if L.open then
        local st = L.stops[L.open]
        if s.speed > 1.0 or s.body ~= st.body or len(s.x - st.x, s.y - st.y, s.z - st.z) > STOP_LEAVE then
          st.tL, st.fuelL = now, s.fuel
          L.open, L.still = nil, nil
          dirty = true
        end
      elseif s.down and s.speed < 0.5 and not s.nearStand then
        L.still = L.still or now
        if now - L.still >= STOP_SECS then
          local k = Rm.addStop(L, { body = s.body, x = s.x, y = s.y, z = s.z, t = L.still, fuel = s.fuel, home = s.body == home_body() })
          if k then L.open = k end
          L.still = nil
          dirty = true
        end
      else
        L.still = nil
      end
      if not L.open and s.speed > 0.5 and (now - (L.pathT or -1e9) >= PATH_EVERY or s.body ~= L.pathB) then
        Rm.addPath(L, { body = s.body, x = s.x, y = s.y, z = s.z, t = now })
        L.pathT, L.pathB = now, s.body
        dirty = true
      end
    end
  end
  -- the hold's transfers since the last look (inventory's move ring)
  local seq = inv.moveSeq or 0
  if move_seq and seq > move_seq and inv.movesSince then
    local mv = inv.movesSince(move_seq) or {}
    for _, m in ipairs(mv) do
      for name, L in pairs(live) do
        if not L.ended and (m.seq or 0) > (L.seq0 or 0) then
          local hold = "hold:" .. name
          leds[name] = leds[name] or {}
          Rm.ledger(leds[name], m, function(c) return c == hold end,
            function(c) return type(c) == "string" and (c == "astro" or c:sub(1, 5) == "crew:") end,
            function(mat, n, peer)
              Rm.addXfer(L, place_now(L, recs[name]), mat, n, peer)
              dirty = true
            end)
        end
      end
    end
  end
  move_seq = seq
  if dirty then save_live() end
end

-- craft_stand: the craft was returned to stand (sid, uid). fp = its
-- fleetParts (fuel in units, parts).
function onReturn(sid, uid, name, fp, cmd)
  load_live()
  local L = name and live[name]
  if not L then return end
  record_tick(agency_now())
  local now = agency_now()
  if L.open then
    -- (the stop it ended in by the stand is its arrival there)
    local st = L.stops[L.open]
    local Lst = L.stand
    if Lst and st and st.body == Lst.body and len(st.x - Lst.x, st.y - Lst.y, st.z - Lst.z) <= ((R() and R().STAND_NEAR) or 30) then
      for _, x in ipairs(L.xfers) do if x.at == L.open then x.at = "arr" end end
      table.remove(L.stops, L.open)
    else
      st.tL, st.fuelL = now, (fp and fp.fuel or 0) * 10
    end
    L.open = nil
  end
  local n = 0
  for _, d in ipairs(fp and fp.parts or {}) do if d.prefab then n = n + 1 end end
  L.ended = { t = now, fuel = (fp and fp.fuel or 0) * 10, n = n, cmd = cmd ~= false, hold = bag("hold:" .. name), sid = sid, uid = uid }
  live[name] = nil
  leds[name] = nil
  save_live()
  set_closed(sid, uid, L)
  local run, why = judge(L)
  version = version + 1
  if run then
    if not hinted then hinted = save.get("runs.hinted") == true end
    if not hinted then
      hinted = true
      save.set("runs.hinted", true)
      say("Ops: That's a route now. Put it on the stand and I can run it for you (right-click the stand: Automate).", 9)
    else
      say(string.format("%s can be automated: right-click the stand", tostring(name)), 5)
    end
  elseif log then
    log("runs: this flight can't be automated: " .. tostring(why))
  end
  return run, why
end

-- ── RUNS ────────────────────────────────────────────────────────────────────
local function stand_show(r)
  local CS = ref("craft_stand")
  if CS and CS.showRunCraft then pcall(CS.showRunCraft, r.sid, r.uid, r.state ~= "cancelled" and R().onStand(r)) end
end

-- AUTOMATE the closed log on stand (sid, uid). → ok, why
function automate(sid, uid)
  load_runs()
  local CS = ref("craft_stand")
  local st = CS and CS.stateOf(sid, uid)
  if not (st and st.s == "built") then return false, "the craft has to be on the stand (returned, not commissioned)" end
  local L = closedLog(sid, uid)
  if not L or L.name ~= st.name then return false, "no flight was recorded for this craft: commission it here and fly it" end
  local run, why = judge(L)
  if not run then return false, why end
  for _, r in pairs(runs) do
    if r.sid == sid and r.uid == uid then return false, "a run already uses this stand" end
  end
  local n = (save.get("runs.next") or 0) + 1
  save.set("runs.next", n)
  local Rm = R()
  W.home = home_body()
  Rm.begin(run, W, agency_now(), n)
  run.created = agency_now()
  runs[n] = run
  ids[#ids + 1] = n
  save_ids()
  save_run(run)
  -- the crew go with it: home from wherever they stand, and busy
  local C = ref("crew")
  for _, id in ipairs(run.crew or {}) do
    local mid = tonumber(id) or id
    if C and C.noteHome then pcall(C.noteHome, mid) end
  end
  if CS.setRun then CS.setRun(sid, uid, n) end
  stand_show(run)
  set_closed(sid, uid, nil)
  say(string.format("%s automated: %s", run.name, Rm.summary(run, mat_label)), 6)
  return true, run
end

function pauseRun(id)
  local r = get(id)
  if not r then return false, "no such run" end
  local ok = R().pause(r, agency_now())
  if ok then save_run(r) end
  return ok, ok and nil or "it isn't running"
end
function resumeRun(id)
  local r = get(id)
  if not r then return false, "no such run" end
  local ok = R().resume(r, agency_now())
  if ok then save_run(r) end
  return ok, ok and nil or "it isn't paused"
end

-- CANCEL: on the stand now, the craft is the stand's again at once; on the
-- way, at the end of this cycle (it comes back first).
local function finish_cancel(r)
  local CS = ref("craft_stand")
  if CS and CS.setRun then CS.setRun(r.sid, r.uid, nil) end
  drop_run(r.id)
  say(string.format("%s: the run is over; the craft is on its stand", tostring(r.name)), 5)
end
function cancelRun(id)
  local r = get(id)
  if not r then return false, "no such run" end
  if R().onStand(r) then finish_cancel(r) return true, "now" end
  r.cancel = true
  if r.state == "paused" then R().resume(r, agency_now()) end
  save_run(r)
  return true, "at the end of this cycle"
end

-- Is member `id` away on a run? → the words for the pickers, or nil.
function memberBusy(id)
  if not runs then load_runs() end
  for _, r in pairs(runs) do
    for _, m in ipairs(r.crew or {}) do
      if tostring(m) == tostring(id) then
        return string.format("on an automated run (%s)", tostring(r.name))
      end
    end
  end
  return nil
end

-- The run a stand serves, or nil.
function runOfStand(sid, uid)
  load_runs()
  for _, r in pairs(runs) do if r.sid == sid and r.uid == uid then return r end end
  return nil
end
function standShows(sid, uid)
  local r = runOfStand(sid, uid)
  return r ~= nil and R() ~= nil and R().onStand(r)
end

local last_ph = {}
local function run_tick(now)
  load_runs()
  if #ids == 0 then return end
  local Rm = R()
  if not Rm then return end
  W.home = home_body()
  local t0 = wall()
  for _, id in ipairs(ids) do
    local r = runs[id]
    if r and (r.t0 or 0) > now + 1 then
      -- (the agency clock came back behind the run's schedule — a save taken
      -- between two of its writes: carry on from here rather than stand still)
      r.t0 = now
    end
    if r then
      local st0, ph0, cy0 = r.state, r.ph, r.cycles or 0
      local n, done = Rm.advance(r, W, now)
      -- (X7) what the run moved in and out of each base, and its cycles (base_roles stats)
      if n > 0 then
        local BR = ref("base_roles")
        if BR and BR.creditRun then pcall(BR.creditRun, r, done, (r.cycles or 0) - cy0) end
      end
      if r.state == "cancelled" then finish_cancel(r) break end
      if n > 0 or r.state ~= st0 or r.ph ~= ph0 or (r.state == "waiting" and r.why ~= last_ph[id]) then
        last_ph[id] = r.why
        save_run(r)
        if (Rm.onStand(r) and true or false) ~= (ph0 and r.phases[ph0] and r.phases[ph0].k == "dwell" or false) or n > 0 then stand_show(r) end
      end
    end
  end
  local ms = (wall() - t0) * 1000
  stats.advance_ms = stats.advance_ms * 0.8 + ms * 0.2
  stats.runs = #ids
end

-- ── FOR THE TRACKING STATION ────────────────────────────────────────────────
-- poseNow(run) → body, x, y, z (body-relative, now: the map places it
-- against this frame's body read).
function poseNow(r) local Rm = R(); if not (Rm and r) then return nil end return Rm.poseAt(r, agency_now()) end
function situationOf(r) local Rm = R(); return Rm and Rm.situation(r, agency_now(), mat_label) or "" end
-- NEXT: { {t, id, glyph, name, what}… }
function events()
  load_runs()
  local Rm = R()
  local out = {}
  if not Rm then return out end
  local now = agency_now()
  for _, id in ipairs(ids) do
    local r = runs[id]
    for _, e in ipairs(r and Rm.events(r, now) or {}) do
      out[#out + 1] = { t = e.t, id = "R:" .. tostring(id), glyph = "⇄", name = r.name, what = e.what }
    end
  end
  return out
end
function manifestOf(r) local Rm = R(); return Rm and Rm.manifest(r, mat_label, store_name) or {} end
function summaryOf(r) local Rm = R(); return Rm and Rm.summary(r, mat_label) or "" end
function fmtTime(s) local Rm = R(); return Rm and Rm.fmtTime(s) or tostring(s) end
function crewNames(r)
  local C = ref("crew")
  local out = {}
  for _, id in ipairs(r.crew or {}) do
    local m = C and C.get and C.get(tonumber(id) or id)
    out[#out + 1] = m and m.name or ("#" .. tostring(id))
  end
  return out
end

-- ── THE STAND'S ROWS (craft_stand's menu asks) ──────────────────────────────
local function wrap(s, w)
  local out, line = {}, ""
  for word in tostring(s):gmatch("%S+") do
    if #line + #word + 1 > w and line ~= "" then out[#out + 1] = line; line = word
    else line = line == "" and word or (line .. " " .. word) end
  end
  if line ~= "" then out[#out + 1] = line end
  return out
end
wrapText = wrap

function standRows(sid, uid, st, ctx)
  local rows = {}
  local function toast(m, bad) if ctx and ctx.toast then ctx.toast(m, bad) end end
  local r = runOfStand(sid, uid)
  if r then
    rows[#rows + 1] = { id = "rn_what", type = "info", label = "RUN", group = "Run", value = function() return situationOf(get(r.id) or r) end }
    rows[#rows + 1] = { id = "rn_cyc", type = "info", label = "CYCLES", group = "Run", value = function()
      local x = get(r.id) or r
      local moved = {}
      for m, n in pairs(x.moved or {}) do moved[#moved + 1] = string.format("%d %s", n, mat_label(m)) end
      table.sort(moved)
      return string.format("%d done%s", x.cycles or 0, #moved > 0 and (" · " .. table.concat(moved, ", ") .. " moved") or "")
    end }
    local paused = r.state == "paused"
    rows[#rows + 1] = { id = paused and "rn_resume" or "rn_pause", type = "action", group = "Run",
      label = paused and "Resume the run" or "Pause the run", hint = paused and "▸" or "‖",
      act = function()
        local ok, w = (paused and resumeRun or pauseRun)(r.id)
        toast(ok and (paused and "the run goes on" or "the run is paused") or tostring(w), not ok)
        return ok
      end }
    rows[#rows + 1] = { id = "rn_cancel", type = "action", group = "Run", danger = true, label = "Cancel the run",
      value = function() local x = get(r.id) or r; return R().onStand(x) and "the craft stays on the stand" or "at the end of this cycle" end,
      act = function()
        local ok, w = cancelRun(r.id)
        toast(ok and ("the run ends " .. (w == "now" and "now" or "when it is back on the stand")) or tostring(w), not ok)
        return ok
      end }
    return rows
  end
  if not (st and st.s == "built") then return rows end
  local L = closedLog(sid, uid)
  if not (L and L.name == st.name) then
    if st.ret then
      rows[#rows + 1] = { id = "rn_nolog", type = "info", label = "FLIGHT LOG", group = "Run", value = "none: commission it here and fly it to make a run" }
    end
    return rows
  end
  local run, why = judge(L)
  if run then
    -- (the menu's info rows show about 22 characters of a value: short words)
    rows[#rows + 1] = { id = "rn_can", type = "info", label = "FLIGHT LOG", group = "Run", value = "can be automated ▸", lit = true }
    rows[#rows + 1] = { id = "rn_cycle", type = "info", label = "A CYCLE", group = "Run",
      value = string.format("%s · %d kg fuel", R().fmtTime(run.dur), math.floor((run.fuel or 0) + 0.5)) }
    local dl = {}
    for m, n in pairs(run.delivers or {}) do dl[#dl + 1] = string.format("%d %s", n, mat_label(m)) end
    table.sort(dl)
    rows[#rows + 1] = { id = "rn_moves", type = "info", label = "MOVES", group = "Run", value = table.concat(dl, ", ") }
  else
    rows[#rows + 1] = { id = "rn_why", type = "sub", label = "Why it can't be automated", group = "Run", hint = "▸",
      title = "NOT REPEATABLE",
      sub = function()
        local list = {}
        for i, l in ipairs(wrap(why, 24)) do list[#list + 1] = { type = "info", id = "w" .. i, label = l, value = "" } end
        return list, "WHY IT CAN'T BE AUTOMATED"
      end }
  end
  local Rm = R()
  rows[#rows + 1] = { id = "rn_auto", type = "action", group = "Run", hint = "⇄",
    label = "Automate",
    value = function() return run and Rm.summary(run, mat_label) or "not repeatable" end,
    enabled = function() return run ~= nil end,
    why = function() return why or "" end,
    act = function()
      local ok, w = automate(sid, uid)
      toast(ok and ("automated · " .. tostring(w and w.name or "")) or tostring(w), not ok)
      return ok, ok and nil or w
    end }
  return rows
end

-- ── THE SCRIPT ──────────────────────────────────────────────────────────────
local tick_t, rec_t = -10, -10
function start(node)
  -- (it rides the research node: never destroy that one for a duplicate)
  runs, live, closed, leds, ctl, move_seq, hinted = nil, nil, {}, {}, {}, nil, nil
  tick_t, rec_t = -10, -10
end

function update(node, dt)
  local t = time or 0
  -- (nothing a frame while nothing is logged and nothing runs: two table looks)
  if live == nil then load_live() end
  if runs == nil then load_runs() end
  local rec = next(live) ~= nil
  if not rec and #ids == 0 then return end
  local w0 = wall()
  if rec and t - rec_t >= 0.25 then
    rec_t = t
    if move_seq == nil then local inv = ref("inventory"); move_seq = inv and inv.moveSeq or 0 end
    record_tick(agency_now())
  end
  if t - tick_t >= 1.0 then
    tick_t = t
    run_tick(agency_now())
  end
  stats.tick_ms = stats.tick_ms * 0.95 + (wall() - w0) * 1000 * 0.05
end
