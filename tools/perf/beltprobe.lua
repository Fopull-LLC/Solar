-- BELTPROBE: loads of every shape on the MATERIALS INTAKE belt
-- (scripts/material_intake.lua; tools/perf/beltshots.sh), on a NEW Career
-- save: logs (across and along), rocks, a boulder, a crystal, a can and a
-- crate dropped on the belt at different heights and turns, two rounds.
-- Every frame each load's spin (assembly.info angVel, rad/s) and its place
-- on the belt are sampled; one LOAD line a load (peak, riding peak from 1 s
-- after it lands, mean, mean speed along, how often it touched the running
-- surface), SPIN for all of it, RESULT spin_calm on the riding peak (`peak`)
-- and all_taken. contacts = 1 also logs each load's contacts and what lies
-- under the belt; kick = 1 tests that a push through the centre of mass does
-- not turn a load.
-- Playtest 11-03c: "physics bodies can spin wildly out of control on the
-- conveyor belt".
-- Pictures (1280x720) to user://beltshots/, lines "BLP ".
defaults = { quit = 1, slot = 27, seed = 5150, scale = 4, peak = 6.0, rounds = 2, contacts = 0, kick = 0 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("BLP %7.2f " .. fmt, W() - W0, ...)) end
local NODE, CO, pending = nil, nil, 0
local FAILS = 0
local function yield() coroutine.yield() end
local function wait_for(fn, tmo, what)
  local t = W() + (tmo or 60)
  while W() < t do local r = fn(); if r then return r end; yield() end
  P("TIMEOUT %s", what or "?")
end
local function hold(secs)
  local acc, last = 0, time
  while acc < secs do
    yield()
    local d = time - last
    last = time
    if d > 0 and d < 1 then acc = acc + d end
  end
end
local function frames(n) for _ = 1, n do yield() end end
local function R(name, ok, fmt, ...)
  if not ok then FAILS = FAILS + 1 end
  P("RESULT %s: %s " .. (fmt or ""), name, ok and "PASS" or "FAIL", ...)
end
local function shot(name)
  pending = pending + 1
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://beltshots/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("SHOT %s failed %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function home() local n = save.get("base.body"); return n and space.body(n) end
local function unit(a) local l = len(a.x, a.y, a.z); return { x = a.x / l, y = a.y / l, z = a.z / l } end
local function wpos(n) return n.worldPos or vec3(n.worldX, n.worldY, n.worldZ) end
local function ground_r(b, ux, uy, uz, from)
  local r = from
  for _ = 1, 400 do
    local d = terrain.query(b.x + ux * r, b.y + uy * r, b.z + uz * r)
    if not d then return nil end
    if d < 0.05 then return r end
    r = r - math.max(d * 0.8, 0.1)
  end
  return r
end
local function face(tx, ty, tz, pitch)
  local cam = findScript("planet_camera")
  local a = find("Astronaut")
  local b = home()
  local u = unit({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z })
  local ex, ey, ez = a.x + u.x * 1.5, a.y + u.y * 1.5, a.z + u.z * 1.5
  local dx, dy, dz = tx - ex, ty - ey, tz - ez
  local v = dx * u.x + dy * u.y + dz * u.z
  local hx, hy, hz = dx - u.x * v, dy - u.y * v, dz - u.z * v
  local hl = len(hx, hy, hz)
  if cam and cam.face and hl > 1e-3 then cam.face(hx / hl, hy / hl, hz / hl, pitch or -0.18) end
end
-- The avatar onto the ground at a world point (its radial; a raycast finds
-- paving and slabs as well as the terrain).
local function stand_at(px, py, pz, top_)
  local C = findScript("crew")
  local b = home()
  local a = find("Astronaut")
  local u = unit({ x = px - b.x, y = py - b.y, z = pz - b.z })
  local top = top_ or 30
  local h = raycast(px + u.x * top, py + u.y * top, pz + u.z * top, -u.x, -u.y, -u.z, 80, { ignore = a })
  local gx, gy, gz
  if h then gx, gy, gz = h.x, h.y, h.z
  else
    local gr = ground_r(b, u.x, u.y, u.z, len(px - b.x, py - b.y, pz - b.z) + 30)
    if not gr then return false end
    gx, gy, gz = b.x + u.x * gr, b.y + u.y * gr, b.z + u.z * gr
  end
  a.x, a.y, a.z = gx + u.x * 1.1, gy + u.y * 1.1, gz + u.z * 1.1
  a.vx, a.vy, a.vz = 0, 0, 0
  if C and C.quietMonitors then C.quietMonitors(1.0) end
  return true
end

local function boot()
  local s = "slot" .. math.floor(params.slot)
  NODE.persistent = true
  terrain.deleteSaveDir("saves/" .. s .. "/terrain")
  if save.deleteSlot then save.deleteSlot(s) end
  save.slot(s)
  save.set("g_seed", math.floor(params.seed))
  for k, v in pairs({ g_planets = 3, g_moonchance = 0.6, g_atmo = 0.8, g_caves = 1.0, g_minorbit = 60000, g_spacing = 2.2,
                      g_radmin = 600, g_radmax = 950, g_gravmin = 3.5, g_gravmax = 8.5, g_star = 1.0 }) do save.set(k, v) end
  save.set("g_scale", math.floor(params.scale))
  save.set("game.mode", "career")
  scene.load("system")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
  end, 240, "the reveal")
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
end


local function rot_up(i)
  -- a few fixed tumbles, so the runs are repeatable
  local t = { {0,1,0}, {0.6,0.8,0}, {0,0.7,0.7}, {-0.5,0.5,0.7}, {0.9,0.1,0.4}, {0.3,-0.2,0.93}, {0,1,0}, {-0.7,0.7,0} }
  local v = t[(i - 1) % #t + 1]
  return v[1], v[2], v[3]
end

local loads = {}
local function drop(i, prefab, s, w, h, mat, qty, crosswise)
  local mi = find("FacIntake"):getScript("material_intake")
  local x, y, z = mi.beltWorld(s, w, h)
  local G = mi.belt()
  local got = nil
  spawn(prefab, vec3(x, y, z), function(n)
    got = n
    n.name = prefab .. " belt " .. tostring(i)
    local u, a = G.u, G.a
    local f = crosswise and a or G.w
    local ex, ey, ez = rot_up(i)
    -- the tumble in the belt's frame: ex along w, ey along u, ez along a
    local ux = G.w.x * ex + G.u.x * ey + G.a.x * ez
    local uy = G.w.y * ex + G.u.y * ey + G.a.y * ez
    local uz = G.w.z * ex + G.u.z * ey + G.a.z * ez
    local l = len(ux, uy, uz); ux, uy, uz = ux / l, uy / l, uz / l
    local d = ux * f.x + uy * f.y + uz * f.z
    local fx, fy, fz = f.x - ux * d, f.y - uy * d, f.z - uz * d
    local fl = len(fx, fy, fz)
    if fl < 0.1 then fx, fy, fz = u.x, u.y, u.z; fl = 1 end
    if n.setUp then n:setUp(vec3(ux, uy, uz), vec3(fx / fl, fy / fl, fz / fl)) end
    if mat then
      local mf, mats = findScript("mineral_field"), findScript("materials")
      if mf and mf.adoptBody then mf.adoptBody(n, prefab, mat, qty, 1.0)
      elseif mats and mats.tagResource then mats.tagResource(n, mat, qty) end
    end
    if assembly and assembly.rebuild then assembly.rebuild(n) end
  end)
  wait_for(function() return got end, 10, "the " .. prefab)
  if got then loads[#loads + 1] = { n = got, name = got.name, pf = prefab, peak = 0, sum = 0, cnt = 0, top = 0, s0 = nil, s1 = nil, path = {} } end
  return got
end

local function sample(mi)
  local G = mi.belt()
  local b = home()
  local live = 0
  for _, L in ipairs(loads) do
    if not L.gone and L.n.valid and L.n.name == L.name then
      local inf = assembly.info(L.n)
      if inf and inf.angVel and inf.com then
        local s, w, h = mi.beltLocal(G, inf.com.x - b.x, inf.com.y - b.y, inf.com.z - b.z)
        local om = len(inf.angVel.x, inf.angVel.y, inf.angVel.z)
        local va = inf.vel.x * G.a.x + inf.vel.y * G.a.y + inf.vel.z * G.a.z
        if s >= 0 and s <= G.take and math.abs(w) < 1.6 and h < 1.6 then
          L.cnt = L.cnt + 1
          L.sum = L.sum + om
          if om > L.peak then L.peak, L.peak_s, L.peak_h = om, s, h end
          -- riding: from a second after it first lands on the belt (the
          -- landing's own tumble is the drop, not the belt)
          if not L.t0 and h < 0.9 then L.t0 = time end
          if L.t0 and time - L.t0 > 1.0 then
            L.ride = math.max(L.ride or 0, om)
            L.rsum, L.rcnt = (L.rsum or 0) + om, (L.rcnt or 0) + 1
          end
          L.va = (L.va or 0) + va
          -- touching the running surface (material_intake belt_contact's test)
          for _, c in ipairs(assembly.impacts(L.n) or {}) do
            if c.x and (c.other == nil or type(c.other) == "table" and c.other.name == "FacIntake") then
              local _, cw, ch = mi.beltLocal(G, c.x - b.x, c.y - b.y, c.z - b.z)
              if ch > -0.2 and ch < 0.15 and math.abs(cw) <= G.half + 0.05 then L.touch = (L.touch or 0) + 1 break end
            end
          end
        end
        L.s1 = s
        L.top = math.max(L.top, h)
        if L.cnt % 15 == 1 then L.path[#L.path + 1] = string.format("%.1f:%.1f", s, om) end
        if params.contacts == 1 and L.cnt % 90 == 2 then
          local cs = {}
          for _, c in ipairs(assembly.impacts(L.n) or {}) do
            local o = c.other
            local on = type(o) == "table" and (o.name .. "<" .. tostring(o.parent and o.parent.name)) or tostring(o)
            local cs_, cw, ch = mi.beltLocal(G, c.x - b.x, c.y - b.y, c.z - b.z)
            cs[#cs + 1] = string.format("[%s s%.2f w%.2f h%.2f J%.3f]", on, cs_, cw, ch, c.impulse or -1)
          end
          P("CONTACT %s com h %.2f: %d %s", L.name, h, #cs, table.concat(cs, " "))
        end
        live = live + 1
      elseif not inf then
        -- a plain body (no assembly): its velocity only
        live = live + 1
      end
    elseif not L.gone then
      L.gone = time
    end
  end
  return live
end

local function belt_round(mi, r)
  local G = mi.belt()
  local base = (r - 1) * 8
  -- at the tail: across, along, a stack, from height, off-centre
  drop(base + 1, "LooseLog", 1.2, 0, 0.9, "timber", 3, true)     -- a roller across the belt
  drop(base + 2, "LooseRock", 2.6, 0.4, 0.7, "iron", 2)
  drop(base + 3, "LooseBoulder", 4.4, -0.2, 1.2, "basalt", 6)
  drop(base + 4, "LooseCrystal", 0.6, -0.7, 1.4, "crystal", 2)
  drop(base + 5, "PropCan", 3.4, 0.9, 1.0)
  drop(base + 6, "LooseRock", 5.6, -0.9, 1.5, "regolith", 2)
  drop(base + 7, "LooseLog", 1.9, 0.3, 1.6, "timber", 3, false)   -- along, dropped on the tail
  drop(base + 8, "PropCrate", 6.4, 0.2, 1.1)
end

-- (kick = 1) does assembly.impulseAt land where its point says? A push
-- through the centre of mass must not turn the load.
local function kick_test(mi)
  local G = mi.belt()
  for _, L in ipairs(loads) do
    if L.n.valid and L.n.name == L.name then
      local i0 = assembly.info(L.n)
      local m = i0.mass
      local w0 = i0.angVel
      assembly.impulseAt(L.n, vec3(G.u.x * m * 1.5, G.u.y * m * 1.5, G.u.z * m * 1.5), vec3(i0.com.x, i0.com.y, i0.com.z))
      local t0 = time
      while time == t0 do yield() end
      local i1 = assembly.info(L.n)
      P("KICK %s: up 1.5 m/s at the com: dv %.2f %.2f %.2f  w %.2f -> %.2f rad/s  carry %.2f %.2f %.2f",
        L.name, i1.vel.x - i0.vel.x, i1.vel.y - i0.vel.y, i1.vel.z - i0.vel.z,
        len(w0.x, w0.y, w0.z), len(i1.angVel.x, i1.angVel.y, i1.angVel.z), i0.carry.x, i0.carry.y, i0.carry.z)
      hold(1.0)
    end
  end
end

local function intake()
  local fac = wait_for(function() return find("FacIntake") end, 30, "the intake shed")
  if not fac then R("intake", false, "no FacIntake") return end
  local mi = wait_for(function() local s = fac:getScript("material_intake"); return s and s.belt and s.belt() and s end, 20, "the belt")
  if not mi then R("intake", false, "no belt") return end
  local G = mi.belt()
  P("belt: %.2f m, take at %.2f m", G.L, G.take)
  -- back off the belt's west side, so the crew stands clear of the view
  local sx, sy, sz = mi.beltWorld(3.2, -7.0, 0)
  stand_at(sx, sy, sz)
  hold(2.0)
  local hx, hy, hz = mi.beltWorld(4.2, 0, 0.3)
  face(hx, hy, hz, -0.30)
  hold(0.6)
  if params.contacts == 1 then
    -- what lies under the belt's running surface along its length
    local b = home()
    for _, ss in ipairs({ 0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.2 }) do
      local x, y, z = mi.beltWorld(ss, 0.4, 2.0)
      local hit = raycast(x, y, z, -G.u.x, -G.u.y, -G.u.z, 4.0)
      local hh = hit and select(3, mi.beltLocal(G, hit.x - b.x, hit.y - b.y, hit.z - b.z))
      local tx, ty, tz = mi.beltWorld(ss, 0.4, 0.0)
      local td = terrain.query(tx, ty, tz)
      P("UNDER s %.1f: hit %s h %s  terrain dist at the belt top %s", ss, hit and tostring(hit.node and hit.node.name) or "none",
        hh and string.format("%.3f", hh) or "-", td and string.format("%.3f", td) or "-")
    end
  end
  for r = 1, math.floor(params.rounds) do
    belt_round(mi, r)
    local t0 = time
    local shot_at = { 1.5, 4.0 }
    local k = 1
    while time - t0 < 22 do
      yield()
      local live = sample(mi)
      if k <= #shot_at and time - t0 >= shot_at[k] then shot(string.format("belt_r%d_%d", r, k)); k = k + 1 end
      if live == 0 and time - t0 > 3 then break end
    end
  end
  if params.kick == 1 then kick_test(mi) end
  local worst, tot, cnt, rworst, rtot, rcnt = 0, 0, 0, 0, 0, 0
  for _, L in ipairs(loads) do
    local mean = L.cnt > 0 and L.sum / L.cnt or 0
    P("LOAD %-18s peak %5.2f (riding %5.2f) rad/s at s %.1f h %.2f  mean %5.2f  va %.2f  n %d  touch %d%%  top h %.2f  end s %.1f  %s  path %s",
      L.name, L.peak, L.ride or 0, L.peak_s or -1, L.peak_h or -1, mean, L.cnt > 0 and L.va / L.cnt or 0, L.cnt,
      L.cnt > 0 and math.floor(100 * (L.touch or 0) / L.cnt) or 0, L.top, L.s1 or -1,
      L.gone and "taken" or "LEFT", table.concat(L.path, " "))
    worst = math.max(worst, L.peak)
    rworst, rtot, rcnt = math.max(rworst, L.ride or 0), rtot + (L.rsum or 0), rcnt + (L.rcnt or 0)
    tot, cnt = tot + L.sum, cnt + L.cnt
  end
  P("SPIN all: peak %.2f rad/s, mean %.2f rad/s over %d samples", worst, cnt > 0 and tot / cnt or 0, cnt)
  R("spin_calm", rworst <= params.peak, "riding (from 1 s after landing): peak %.2f rad/s, mean %.2f rad/s over %d samples",
    rworst, rcnt > 0 and rtot / rcnt or 0, rcnt)
  local taken = 0
  for _, L in ipairs(loads) do if L.gone then taken = taken + 1 end end
  R("all_taken", taken == #loads, "%d of %d taken", taken, #loads)
  local lines = {}
  for _, r in ipairs(mi.receipts or {}) do lines[#lines + 1] = r.text end
  P("receipts: %s", table.concat(lines, " | "))
end

local function main()
  boot()
  hold(3.0)
  intake()
  wait_for(function() return pending == 0 end, 10, "the pictures")
  P("DONE fails %d", FAILS)
end

function start(node)
  NODE = node
  CO = coroutine.create(main)
end

function update(node, dt)
  if not CO then return end
  if coroutine.status(CO) == "dead" then
    CO = nil
    if params.quit == 1 and app.quit then app.quit() end
    return
  end
  local ok, err = coroutine.resume(CO)
  if not ok then P("ERROR %s", tostring(err)); CO = nil; if params.quit == 1 and app.quit then app.quit() end end
end
