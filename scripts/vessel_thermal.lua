-- VESSEL_THERMAL — a craft's heat loop, reactors, rods, radiators and
-- radiation in flight: the thermal rulebook (scripts/thermal.lua) applied
-- to a live craft. Kept out of vessel_controller.lua (which sits at Lua's
-- local and upvalue ceilings): the controller hands this a VIEW of itself
-- inside its 10 Hz electrical tick, and only for a craft that carries a
-- reactor, an isotope cell or a radiator (elecRescan's `elec.thermal`).
-- A craft without them costs nothing new, per tick or per frame.
--
-- A library on the Electronics node (scenes/system.ron). Its state lives in
-- the VIEW's `S` (the controller's `elec.th`, one per craft) and in the
-- parts' own `st`, which rides the blueprint, the fleet save, docking and
-- revert:
--   st.T, st.ht     the loop's temperature and the game time it was read
--                   (every thermal part keeps a copy: a craft split in two
--                   keeps its heat in both halves; a load catches up from
--                   st.ht with thermal.advance, one closed-form step)
--   st.critical     a reactor is running (its toggle); st.output 10..100
--   st.rods, st.life  rods in the rack, full-power seconds left in them
--   st.scram        the game time of its last scram
--   st.born         an isotope cell's birth (its decay runs from it)
--
-- tick(V, dt) → EC/s the cores and cells give; appends the radiators'
-- pump loads to V.loads. V (vessel_controller thermalView):
--   node, recs (uid → record), hp (uid → health), anim (uid → fold 0..1),
--   gone (uid set), served (load id → 0..1, last tick), uids (thermal part
--   uids), eng (engine uids), tanks ({uid, fuel, left}), throttle, burning,
--   bodies (this tick's space.bodies), E (the electronics functions),
--   S (state), wear(uid, hp), label(uid)
--
-- RADIATION (A4) runs twice a second (staggered per craft): for every core
-- giving any, a dot product for each crew member in reach (seated in this
-- craft, or on foot) against its 30° cone; only those inside are worked out
-- (inverse square, shielding counted by part record — thermal.shieldFactor),
-- and only those on foot get a ray to the core against the terrain.
-- Positions are DRAWN poses throughout (this runs in lateUpdate): the
-- craft's node, its basis, the crew bodies (docs/positions-and-frames.md).

-- (probes: PROF_ON = true gathers ms per section of the tick into PROF)
PROF_ON = false
PROF = {}

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not (r and r.valid ~= false) then
    r = findScript and findScript(kind) or nil
    refs[kind] = r
  end
  return r
end

local function now_game() return (space and space.time and space.time()) or (time or 0) end

-- The rulebook's functions, fetched once (each `TH.x` through a script
-- handle is a call into the engine).
local TH = nil
local function thl()
  local t = TH and TH.lib
  if t and t.valid ~= false then return TH end
  local lib = ref("thermal")
  if not lib then return nil end
  TH = { lib = lib, THERMAL = lib.THERMAL, vesselModel = lib.vesselModel, advance = lib.advance,
         settle = lib.settle, coreOf = lib.coreOf, coreShare = lib.coreShare, radShare = lib.radShare,
         startWhyNot = lib.startWhyNot, startCost = lib.startCost, rtgOutput = lib.rtgOutput,
         doseRate = lib.doseRate, blockerK = lib.blockerK, coneAt = lib.coneAt,
         rodsLive = lib.rodsLive, rodsSpent = lib.rodsSpent, st_rods = lib.st_rods,
         loadRod = lib.loadRod, unloadSpent = lib.unloadSpent, shieldFactor = lib.shieldFactor }
  return TH
end

-- A part's axes in the craft's frame from its yaw/pitch/roll (the builder's
-- and the controller's YXZ convention).
local function axes(d)
  local cy, sy = math.cos(d.yaw or 0), math.sin(d.yaw or 0)
  local cx, sx = math.cos(d.pitch or 0), math.sin(d.pitch or 0)
  local cz, sz = math.cos(d.roll or 0), math.sin(d.roll or 0)
  return { x = cy * cz + sy * sx * sz, y = cx * sz, z = -sy * cz + cy * sx * sz },
         { x = -cy * sz + sy * sx * cz, y = cx * cz, z = sy * sz + cy * sx * cz },
         { x = sy * cx, y = -sx, z = cy * cx }
end
partAxes = axes

local function say(S, text, big)
  S.msg, S.msg_t = text, time or 0
  if big then
    local bc = ref("big_caption")
    if bc and bc.show then pcall(bc.show, big, text, 4.0) end
    local fx = ref("sfx")
    if fx and fx.play then pcall(fx.play, (big == "SCRAM" or big == "OVERHEAT") and "denied" or "chime", 1.0) end
  end
  if log then log("thermal: " .. text) end
end

-- The thermal parts' entries for the model (and the cores, by uid). Which
-- parts carry which modules can't change between rescans, so that list is
-- built once per part-list generation (V.gen); each tick only reads the
-- live numbers (fold, health, pump, state) into reused entry tables.
local function plan_of(V, S)
  if S.plan and S.plan_gen == V.gen then return S.plan end
  local E, P = V.E, { th = {}, eng = {} }
  for _, u in ipairs(V.uids) do
    local d = V.recs[u]
    if d then
      local st = E.stateOf(d)
      local folds = E.modOf(d, "deploy") ~= nil
      for _, m in ipairs(E.modsOf(d)) do
        local ty = m.type
        if ty == "reactor" or ty == "rtg" or ty == "radiator" then
          P.th[#P.th + 1] = { uid = u, d = d, m = m, st = st, folds = ty == "radiator" and folds,
                              e = { m = m, st = st, uid = u } }
        end
      end
    end
  end
  for _, u in ipairs(V.eng) do
    if V.recs[u] then P.eng[#P.eng + 1] = { uid = u, d = V.recs[u], e = { m = { type = "engine" } } } end
  end
  S.plan, S.plan_gen = P, V.gen
  return P
end
local function entries_of(V, S)
  local P = plan_of(V, S)
  local out, cores = {}, {}
  for _, p in ipairs(P.th) do
    local u = p.uid
    local hp = V.hp[u] or 1
    if not V.gone[u] and hp > 0 then
      local e = p.e
      -- (a record whose state table was replaced: a revert, a docking handoff)
      if type(p.d.st) == "table" and p.d.st ~= p.st then p.st, e.st = p.d.st, p.d.st end
      e.deploy = p.folds and (V.anim[u] or 0) or 1
      e.hp = hp
      e.pump = (V.served and V.served["r" .. u]) or 1
      out[#out + 1] = e
      if p.m.type == "reactor" then cores[#cores + 1] = p end
    end
  end
  local th = V.burning and V.throttle or 0
  for _, p in ipairs(P.eng) do
    local u = p.uid
    if not V.gone[u] and (V.hp[u] or 1) > 0 then
      local st = p.d.st
      p.e.throttle = (type(st) == "table" and st.running == false) and 0 or th
      out[#out + 1] = p.e
    end
  end
  return out, cores
end

-- The craft's sunlight 0..1 (the radiators shed less in it): the panels'
-- own occlusion test (electronics segmentBlocked) and flux, twice a second.
local function sun_of(V, S)
  local t = time or 0
  if S.sun_t and t - S.sun_t < 0.5 then return S.sun or 0 end
  S.sun_t = t
  local E, n = V.E, V.node
  local x, y, z = n.worldX or n.x, n.worldY or n.y, n.worldZ or n.z
  local sun, flux = E.sunOf(x, y, z, V.bodies, V.ref)
  if not sun then S.sun = 0 return 0 end
  local blk = E.segmentBlocked(x, y, z, sun.x, sun.y, sun.z, V.bodies, 1.0, sun.name)
  S.sun = blk and 0 or math.min(1, flux or 1)
  return S.sun
end

-- ── the tick ────────────────────────────────────────────────────────────────
function tick(V, dt)
  local L = thl()
  if not L then return 0 end
  local TP = L.THERMAL
  local S = V.S
  local now = now_game()
  local pf = PROF_ON and app and app.wallClock
  local t0 = pf and pf()
  local ents, cores = entries_of(V, S)
  local sun = sun_of(V, S)
  local t1 = pf and pf()
  local M = L.vesselModel(ents, sun)
  if pf then local t2 = pf(); PROF.entries = (PROF.entries or 0) + (t1 - t0) * 1000; PROF.model = (PROF.model or 0) + (t2 - t1) * 1000 end
  -- FIRST TICK: the loop's temperature from the parts, and the catch-up on
  -- the save clock since they were last read (a craft loaded, a stage come
  -- back into range): one exact step.
  if not S.init then
    S.init = true
    local T0, ht = 0, nil
    for _, e in ipairs(ents) do
      if e.st and e.m.type ~= "engine" then
        T0 = math.max(T0, tonumber(e.st.T) or 0)
        local h = tonumber(e.st.ht)
        if h and (not ht or h > ht) then ht = h end
      end
    end
    S.T, S.dir, S.on = T0, 0, {}
    for _, c in ipairs(cores) do S.on[c.uid] = c.st.critical == true end
    if ht and now - ht > 1.0 then
      local gap = math.min(now - ht, TP.catch_max)
      local rep = L.advance(S, M, gap, now - gap)
      S.caught = gap
      if rep.scram then say(S, string.format("a reactor scrammed while you were away (%d %%)", math.floor(rep.peak * 100))) end
      for _, c in ipairs(cores) do S.on[c.uid] = c.st.critical == true end
    end
  end
  -- STARTS (A6): a core switched on by its action is checked here, once.
  for _, c in ipairs(cores) do
    local st = c.st
    if st.critical and not S.on[c.uid] then
      local why = L.startWhyNot(st, S.T or 0, now)
      if why then
        st.critical = false
        say(S, (V.label and V.label(c.uid) or "Reactor") .. " won't start: " .. why)
      else
        L.startCost(st)
        say(S, (V.label and V.label(c.uid) or "Reactor") .. " critical")
      end
    end
    S.on[c.uid] = st.critical == true
  end
  -- THE STEP (game seconds: warp runs the loop as fast as the world)
  local ta = pf and pf()
  local rep = L.advance(S, M, dt, now - dt)
  if pf then PROF.advance = (PROF.advance or 0) + (pf() - ta) * 1000 end
  for i, c in ipairs(cores) do
    if rep.spent[i] then say(S, (V.label and V.label(c.uid) or "Reactor") .. ": the fuel rods are spent", "REACTOR") end
    S.on[c.uid] = c.st.critical == true
  end
  if rep.scram then
    S.scrams = (S.scrams or 0) + 1
    say(S, string.format("core at %d %% — control rods in. It can restart below %d %% after %d s.",
      math.floor(TP.scram * 100 + 0.5), math.floor(TP.restart_T * 100 + 0.5), TP.restart_s), "SCRAM")
  end
  -- 100 % SUSTAINED: the hot parts wear (the vessel's own damage model)
  if rep.over > 0 and V.wear then
    for _, e in ipairs(ents) do
      if e.uid and (e.m.type == "reactor" or e.m.type == "radiator") then
        local h = (V.hp[e.uid] or 1) - TP.damage_rate * rep.over
        V.wear(e.uid, h)
      end
    end
    if not S.hot_said then S.hot_said = true; say(S, "the core is OVER 100 % — the reactor and radiators are being damaged", "OVERHEAT") end
  elseif S.hot_said and (S.T or 0) < TP.damage - 0.05 then
    S.hot_said = nil
  end
  -- what the parts keep (the save, a split, a revert)
  for _, e in ipairs(ents) do
    if e.st then e.st.T, e.st.ht = S.T, now end
  end
  -- POWER: the cores at their share, the isotope cells by their age
  local supply, out_sum, n_live, rods, rods_cap, life = 0, 0, 0, 0, 0, 0
  for _, e in ipairs(ents) do
    if e.m.type == "rtg" then
      local st = e.st
      if tonumber(st.born) == nil then st.born = now end
      supply = supply + L.rtgOutput(e.m, now - st.born)
    end
  end
  for i, k in ipairs(M.cores) do
    local share = L.coreShare(k, S.T or 0)
    supply = supply + k.c.ec * share
    if share > 0 then n_live = n_live + 1; out_sum = out_sum + share end
    rods = rods + L.rodsLive(k.st, k.c)
    rods_cap = rods_cap + (k.c.rack or 1)
    life = life + (tonumber(k.st.life) or 0) / math.max(1, k.c.life or 3600)
  end
  -- THE PUMPS: a radiator loop draws while it is out (a fixed fin is passive)
  for _, e in ipairs(ents) do
    if e.m.type == "radiator" and (e.m.draw or 0) > 0 and (e.deploy or 0) > 0.5 then
      V.loads[#V.loads + 1] = { id = "r" .. e.uid, rate = e.m.draw, pri = 8 }
    end
  end
  -- RADIATION, twice a second, staggered across craft
  S.rad_acc = (S.rad_acc or ((V.node.id or 0) % 7) / 14) + (V.real_dt or 0.1)
  S.rad_gs = (S.rad_gs or 0) + dt
  if S.rad_acc >= 0.5 then
    S.rad_acc = 0
    local gs = S.rad_gs
    S.rad_gs = 0
    local tr = pf and pf()
    radiation(V, L, M, cores, gs)
    if pf then PROF.radiation = (PROF.radiation or 0) + (pf() - tr) * 1000; PROF.rad_n = (PROF.rad_n or 0) + 1 end
  end
  local th_ = pf and pf()
  -- THE HUD's line (vessel_controller publishes it as tele.heat)
  local cool = nil
  for _, c in ipairs(cores) do
    local sc = tonumber(c.st.scram)
    if sc and not c.st.critical and now - sc < TP.restart_s then
      cool = math.max(cool or 0, TP.restart_s - (now - sc))
    end
  end
  local scrammed = false
  for _, c in ipairs(cores) do if tonumber(c.st.scram) and not c.st.critical then scrammed = true end end
  local Q = 0
  do
    local a = M.base
    for _, k in ipairs(M.cores) do
      local sh = L.radShare(k, S.T or 0)
      a = a + k.c.heat * sh
    end
    Q = a
  end
  S.hud = { T = S.T or 0, eq = L.settle(M, S.T or 0), Q = Q, sink = M.S, sinks = M.sinks,
            cores = #M.cores, live = n_live, out = n_live > 0 and out_sum / n_live or 0,
            rods = rods, rods_cap = rods_cap, life = life, scrammed = scrammed, cool = cool,
            scram_at = TP.scram, msg = S.msg, msg_t = S.msg_t, sun = S.sun or 0, gen = supply,
            dose = S.dose_hud, scrams = S.scrams or 0 }
  if pf then PROF.hud = (PROF.hud or 0) + (pf() - th_) * 1000; PROF.n = (PROF.n or 0) + 1 end
  return supply
end

-- ── A4: the dose pass ───────────────────────────────────────────────────────
-- Blockers by part record: the shields (static) and the full tanks (their
-- fill now). Rebuilt when the part list changes (V.gen).
local function blockers_of(V, L, S)
  if S.blk and S.blk_gen == V.gen then
    -- only the tanks' shielding changes as they drain
    for _, b in ipairs(S.blk) do
      if b.tank then
        local f = 1
        local t = V.tank_fill and V.tank_fill[b.uid]
        if t then f = t end
        b.k = (f >= L.THERMAL.tank_full) and L.THERMAL.tank_k or 1
      end
    end
    return S.blk
  end
  local E, out = V.E, {}
  for u, d in pairs(V.recs) do
    if not V.gone[u] and (V.hp[u] or 1) > 0 then
      local mods = E.modsOf(d)
      local is_shield = false
      for _, m in ipairs(mods) do if m.type == "shield" then is_shield = true end end
      local is_tank = d.kind == "tank" and (d.fuel or 0) > 0
      if is_shield or is_tank then
        local X, Y, Z = axes(d)
        out[#out + 1] = { uid = u, x = d.x or 0, y = d.y or 0, z = d.z or 0, X = X, Y = Y, Z = Z,
                          hx = math.max(0.05, d.rx or 0.5), hy = math.max(0.05, (d.h or 1) * 0.5),
                          hz = math.max(0.05, d.rz or 0.5),
                          k = is_shield and L.blockerK(mods, d) or 1, tank = is_tank }
      end
    end
  end
  S.blk, S.blk_gen = out, V.gen
  return blockers_of(V, L, S)
end

function radiation(V, L, M, cores, gs)
  local S = V.S
  S.dose_hud = nil
  if gs <= 0 then return end
  local srcs = {}
  for i, k in ipairs(M.cores) do
    local share = L.radShare(k, S.T or 0)
    if share > 0 and (k.c.rad or 0) > 0 then
      local c = cores[i]
      local _, Y = axes(c.d)
      srcs[#srcs + 1] = { x = c.d.x or 0, y = c.d.y or 0, z = c.d.z or 0, ax = Y.x, ay = Y.y, az = Y.z,
                          rad = k.c.rad, share = share, uid = c.uid, label = V.label and V.label(c.uid) or "reactor" }
    end
  end
  if #srcs == 0 then return end
  local cl = ref("crew")
  if not cl then return end
  -- the crew in reach, in the craft's frame
  local who = {}
  -- who sits where and who is out on foot change seldom: read every 4 s (the
  -- roster is the save's records, not free to read twice a second)
  local tnow = time or 0
  if not S.crew_t or tnow - S.crew_t > 4.0 or S.crew_gen ~= V.gen then
    S.crew_t, S.crew_gen = tnow, V.gen
    local seats, afoot = {}, {}
    if cl.seatedIn then
      local ok, list = pcall(cl.seatedIn, V.recs, function(u) return not V.gone[u] end)
      if ok then for _, s in ipairs(list or {}) do seats[#seats + 1] = { id = s.id, uid = s.uid } end end
    end
    if cl.roster then
      for _, r in ipairs(cl.roster()) do if r.status == "afoot" then afoot[#afoot + 1] = r.id end end
    end
    S.seats, S.afoot = seats, afoot
  end
  for _, s in ipairs(S.seats or {}) do
    local d = V.recs[s.uid]
    if d and not V.gone[s.uid] then who[#who + 1] = { id = s.id, x = d.x or 0, y = d.y or 0, z = d.z or 0, seat = s.uid } end
  end
  local n = V.node
  local ox, oy, oz = n.worldX or n.x, n.worldY or n.y, n.worldZ or n.z
  local rx, up, rz = V.rx, V.up, V.rz
  if cl.bodyOf and rx then
    local R = L.THERMAL.dose_range + 20
    for _, rid in ipairs(S.afoot or {}) do
      local r = { id = rid }
      do
        local b = cl.bodyOf(r.id)
        if b and b.valid ~= false then
          local dx, dy, dz = b.x - ox, b.y - oy, b.z - oz
          if dx * dx + dy * dy + dz * dz < R * R then
            who[#who + 1] = { id = r.id, foot = true, wx = b.x, wy = b.y, wz = b.z,
                              x = dx * rx.x + dy * rx.y + dz * rx.z, y = dx * up.x + dy * up.y + dz * up.z,
                              z = dx * rz.x + dy * rz.y + dz * rz.z }
          end
        end
      end
    end
  end
  -- M6c (step 8): the cores, body-relative, for the Build Kit's cone draw, and
  -- the placed walls (base_shield, by part record) for crew on foot
  local bsh = ref("base_shield")
  local bn, bb = nil, nil
  if bsh and rx and space and space.dominant then
    bn = space.dominant(ox, oy, oz)
    bb = bn and space.body(bn)
    if bb and bsh.publish then
      local pub = {}
      for _, c in ipairs(srcs) do
        local cx = ox + rx.x * c.x + up.x * c.y + rz.x * c.z - bb.x
        local cy = oy + rx.y * c.x + up.y * c.y + rz.y * c.z - bb.y
        local cz = oz + rx.z * c.x + up.z * c.y + rz.z * c.z - bb.z
        local ax = rx.x * c.ax + up.x * c.ay + rz.x * c.az
        local ay = rx.y * c.ax + up.y * c.ay + rz.y * c.az
        local az = rx.z * c.ax + up.z * c.ay + rz.z * c.az
        pub[#pub + 1] = { x = cx, y = cy, z = cz, ax = ax, ay = ay, az = az, rad = c.rad, share = c.share, label = c.label }
      end
      pcall(bsh.publish, n.id, bn, pub)
    end
  end
  if #who == 0 then return end
  local blk = nil
  local hud = {}
  for _, w in ipairs(who) do
    local rate_sum, from = 0, nil
    for _, c in ipairs(srcs) do
      -- the cheap test first: one dot product
      local inside, bare = L.coneAt(c, w.x, w.y, w.z)
      if inside then
        blk = blk or blockers_of(V, L, S)
        local skip = { [c.uid] = true }
        if w.seat then skip[w.seat] = true end
        local rate = L.doseRate(c, w.x, w.y, w.z, blk, skip)
        -- on foot only: the placed walls between (by record), then the ground
        -- (a ray from the core to them)
        if rate > 0 and w.foot and rx then
          local cx = ox + rx.x * c.x + up.x * c.y + rz.x * c.z
          local cy = oy + rx.y * c.x + up.y * c.y + rz.y * c.z
          local cz = oz + rx.z * c.x + up.z * c.y + rz.z * c.z
          if bb and bsh and bsh.wallFactor then
            local okf, f = pcall(bsh.wallFactor, bn, cx - bb.x, cy - bb.y, cz - bb.z, w.wx - bb.x, w.wy - bb.y, w.wz - bb.z, L)
            if okf and f then rate = rate * f end
          end
          if bsh and bsh.note and bb then
            pcall(bsh.note, w.id, rate, bare or rate, c.label, bn, cx - bb.x, cy - bb.y, cz - bb.z)
          end
        end
        if rate > 0 and w.foot and terrain and terrain.raycast and rx then
          local cx = ox + rx.x * c.x + up.x * c.y + rz.x * c.z
          local cy = oy + rx.y * c.x + up.y * c.y + rz.y * c.z
          local cz = oz + rx.z * c.x + up.z * c.y + rz.z * c.z
          local ddx, ddy, ddz = w.wx - cx, w.wy - cy, w.wz - cz
          local dl = math.sqrt(ddx * ddx + ddy * ddy + ddz * ddz)
          if dl > 1.0 then
            local ok, hit = pcall(terrain.raycast, vec3(cx, cy, cz), vec3(ddx / dl, ddy / dl, ddz / dl), dl)
            if ok and hit and hit.distance and hit.distance < dl - 0.6 then rate = 0 end
          end
        end
        if rate > 0 then rate_sum = rate_sum + rate; from = c.label end
      end
    end
    if rate_sum > 0 then
      -- (gathered here, written to the record every 2 s: a record write is a save write)
      local pd = S.pending or {}
      S.pending = pd
      local e = pd[w.id] or { d = 0 }
      e.d, e.rate, e.src = e.d + rate_sum * gs, rate_sum, from and ("the " .. from .. "'s core") or "a reactor"
      pd[w.id] = e
      hud[#hud + 1] = { id = w.id, rate = rate_sum }
    end
  end
  if #hud > 0 then S.dose_hud = hud end
  flush_dose(S, cl, false)
end

-- Write the gathered dose to the crew records (every 2 s, or now).
function flush_dose(S, cl, now)
  local pd = S.pending
  if not pd or not cl or not cl.addDose then return end
  local t = time or 0
  if not now and S.flush_t and t - S.flush_t < 2.0 then return end
  S.flush_t = t
  for id, e in pairs(pd) do
    if e.d > 0 then cl.addDose(id, e.d, e.src, e.rate) end
  end
  S.pending = nil
end

-- ── the right-click on a reactor: its readout and the rods (B5) ─────────────
-- Load a fresh rod (held), take a spent one out (into the pack): a timed
-- job at the reactor, 8 s (an Engineer 4 s). Anyone may; the rods are heavy.
local ROD_SECS = 8.0
local function rods_rows(t, ctx)
  local L = thl()
  if not (L and t and t.rec) then return {} end
  local E = ref("electronics")
  local m = E and E.modOf and E.modOf(t.rec, "reactor")
  if not m then return {} end
  local c = L.coreOf(m)
  local st = (E.stateOf and E.stateOf(t.rec)) or t.rec.st or {}
  local v = t.vessel
  local hud = function()
    local ok, h = false, nil
    if v and v.thermalHud then ok, h = pcall(v.thermalHud) end
    return ok and h or nil
  end
  local out = {}
  out[#out + 1] = { type = "info", id = "core", group = "REACTOR", label = "CORE", value = function()
      local h = hud()
      local T = (h and h.T) or tonumber(st.T) or 0
      local s = string.format("%d %%", math.floor(T * 100 + 0.5))
      if h then s = s .. string.format(" · settles %d %%", math.floor((h.eq or 0) * 100 + 0.5)) end
      if st.critical then s = s .. string.format(" · critical, %d %% output", math.floor(tonumber(st.output) or 100))
      elseif tonumber(st.scram) then s = s .. " · SCRAMMED"
      else s = s .. " · shut down" end
      return s end }
  out[#out + 1] = { type = "info", id = "rods", group = "REACTOR", label = "RODS", value = function()
      local live, spent = L.rodsLive(st, c), L.rodsSpent(st, c)
      return string.format("%d / %d in the rack%s · %.0f full-power min left", live, c.rack or 1,
        spent > 0 and string.format(" + %d spent", spent) or "", (tonumber(st.life) or 0) / 60) end }
  local cp = ref("context_providers")
  local H = ref("item_hand")
  local inv = ref("inventory")
  local a = ctx and ctx.actor
  local function reach()
    if not (cp and cp.actorReach) then return nil end
    local r = cp.actorReach(ctx, t)
    return r
  end
  local function secs()
    local cl = ref("crew")
    if a and a.id and cl and cl.hasRole and cl.hasRole(a.id, "engineer") then return ROD_SECS * 0.5 end
    return ROD_SECS
  end
  local pack = a and a.pack
  -- LOAD (a rod in hand)
  local held = H and H.held and H.held() or nil
  local function load_why()
    if not a or a.kind ~= "crew" then return "only on foot or on EVA" end
    if reach() ~= "near" then return "walk up to the reactor" end
    if (H and H.held and H.held()) ~= "fuelRod" then
      local has = inv and pack and (inv.itemCount(pack, "fuelRod") or 0) > 0
      return has and "hold the Fuel Rod" or "needs a Fuel Rod — the Materials Intake fabricates them"
    end
    if L.st_rods(st) >= (c.rack or 1) then return "the rack is full" .. (L.rodsSpent(st, c) > 0 and " — take the spent rod out first" or "") end
    return nil
  end
  out[#out + 1] = { type = "action", id = "loadrod", group = "REACTOR", label = "Load fuel rod",
    hint = string.format("%.0f s", secs()),
    enabled = function() return load_why() == nil end, why = load_why,
    act = function()
      local why = load_why()
      if why then return false, why end
      return true
    end,
    job = { secs = secs(), label = "Loading the rod",
      check = function() local w = load_why(); return w == nil, w end,
      done = function()
        local w = load_why()
        if w then return false, w end
        if not (inv and pack and inv.removeItem(pack, "fuelRod", 1) == 1) then return false, "the rod is gone" end
        local ok, why = L.loadRod(st, c)
        if not ok then inv.addItem(pack, "fuelRod", 1, { force = true }); return false, why end
        if v and v.thermalTouch then pcall(v.thermalTouch) end
        if H and H.refreshHand then pcall(H.refreshHand) end
        return true
      end } }
  -- UNLOAD (a spent rod into the pack)
  local function unload_why()
    if L.rodsSpent(st, c) <= 0 then return "no spent rod in the rack" end
    if st.critical then return "shut the reactor down first" end
    if not a or a.kind ~= "crew" then return "only on foot or on EVA" end
    if reach() ~= "near" then return "walk up to the reactor" end
    if inv and pack and inv.roomForItem then
      local fit, why = inv.roomForItem(pack, "spentRod", 1)
      if (fit or 0) < 1 then return "no room in the pack (" .. tostring(why or "40 kg") .. ")" end
    end
    return nil
  end
  if L.rodsSpent(st, c) > 0 then
    out[#out + 1] = { type = "action", id = "unloadrod", group = "REACTOR", label = "Take out the spent rod",
      hint = string.format("%.0f s · hot", secs()),
      enabled = function() return unload_why() == nil end, why = unload_why,
      act = function() local w = unload_why(); if w then return false, w end return true end,
      job = { secs = secs(), label = "Pulling the spent rod",
        check = function() local w = unload_why(); return w == nil, w end,
        done = function()
          local w = unload_why()
          if w then return false, w end
          if not L.unloadSpent(st, c) then return false, "it won't come out" end
          if inv and pack then inv.addItem(pack, "spentRod", 1, { force = true }) end
          if v and v.thermalTouch then pcall(v.thermalTouch) end
          return true
        end } }
  end
  return out
end

-- An isotope cell's and a radiator's line (what it is doing now).
local function heat_rows(t, ctx)
  local L = thl()
  if not (L and t and t.rec) then return {} end
  local E = ref("electronics")
  if not (E and E.modOf) then return {} end
  local g = E.modOf(t.rec, "rtg")
  local r = E.modOf(t.rec, "radiator")
  if not (g or r) then return {} end
  local st = (E.stateOf and E.stateOf(t.rec)) or {}
  local out = {}
  if g then
    out[#out + 1] = { type = "info", id = "rtg", group = "POWER", label = "OUTPUT", value = function()
        local age = now_game() - (tonumber(st.born) or now_game())
        return string.format("%.2f EC/s · %.0f h old", L.rtgOutput(g, age), age / 3600) end }
  end
  if r then
    out[#out + 1] = { type = "info", id = "rad", group = "HEAT", label = "SHEDS", value = function()
        return string.format("up to %d heat · loop at %d %%", r.sink or 1, math.floor((tonumber(st.T) or 0) * 100 + 0.5)) end }
  end
  return out
end

local registered = nil
local function try_register()
  if registered and registered.valid ~= false then return end
  local reg = findScript and findScript("context_registry")
  if reg and reg.register then
    reg.register("part", rods_rows, { id = "thermal.rods", order = 22 })
    reg.register("part", heat_rows, { id = "thermal.heat", order = 23 })
    registered = reg
  end
end

local reg_t = 0
function update(node, dt)
  if registered and registered.valid ~= false then return end
  reg_t = reg_t + (dt or 0)
  if reg_t < 1.0 then return end
  reg_t = 0
  try_register()
end
