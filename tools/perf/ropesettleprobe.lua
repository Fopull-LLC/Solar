-- ROPESETTLE: does a planted Rope Kit's line lie on what the player sees, and
-- does it settle again when the ground under it changes? (tools/perf/
-- ropesettle.sh; scripts/rope_climb.lua, rope.lua; playtest 2026-11-11:
-- "ropes can clip through walls (seems like it's not following the meshed
-- terrain, more like the SDF field), and I'd like the ability to mine near my
-- ropes and they'll move to rebalance where they should be")
--
--   A. a LEDGE: a 12 m pit dug 150 m from the base, a davit 0.6 m back from
--      its edge; the line runs down the wall to the floor
--   B. a CAVE MOUTH: a 2 m shaft down into a chamber 150 m the other way, a
--      davit at the shaft's rim; the line drops through the mouth
--   for each: the line checked against the colliders (a physics ray along
--   every piece of it, past the davit and the crew) and against the field
--   (terrain.query every 5 cm: inside the rock?), pictures from two angles
--   C. the ground changed under A: the floor under its foot dug 3 m deeper,
--      then a boss raised on the wall behind it; B's mouth widened by a dig
--      on the side the line runs; each time the line must settle again
--      (rope_climb.settles), with no piece inside, and pictures
--   D. the footing dug out from under A's davit (terrain.dig straight, past
--      the dig guard): the davit falls to the floor with its line
--   E. the cost: rope_climb's signature reads while nothing changes
--
-- Lines "RSP ", one RESULT a check. Pictures (1280×720) to user://ropesettle/.
defaults = { quit = 1, slot = 24, seed = 5150, scale = 4 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("RSP %7.2f " .. fmt, W() - W0, ...)) end
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
local len = function(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function unit(a) local l = len(a.x, a.y, a.z); return { x = a.x / l, y = a.y / l, z = a.z / l } end
local function cross(a, b) return { x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x } end
local function add(p, v, k) return { x = p.x + v.x * k, y = p.y + v.y * k, z = p.z + v.z * k } end
local function home() local n = save.get("base.body"); return n and space.body(n), n end
local function ground_r(b, ux, uy, uz, from)
  local r = from
  for _ = 1, 600 do
    local d = terrain.query(b.x + ux * r, b.y + uy * r, b.z + uz * r)
    if not d then return nil end
    if d < 0.03 then return r end
    r = r - math.max(d * 0.8, 0.05)
  end
  return r
end
local function settle() wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, 60, "the digs") end

-- ── pictures: a probe camera placed in lateUpdate against the davit's drawn pose
local PCAM = { node = nil, eye = nil, look = nil, id = nil, u = nil }
local function origin()
  local b = home()
  local dep = findScript("deployables")
  local ox, oy, oz = b.x, b.y, b.z
  if PCAM.id and dep then
    local pn = dep.nodeOf(PCAM.id)
    if pn and pn.worldPos then ox, oy, oz = pn.worldPos.x - pn.x, pn.worldPos.y - pn.y, pn.worldPos.z - pn.z end
  end
  return ox, oy, oz
end
function lateUpdate(node, dt)
  local c = PCAM.node
  if not (c and c.valid ~= false and PCAM.eye) then return end
  local ox, oy, oz = origin()
  local e, l = PCAM.eye, PCAM.look
  c.pos = vec3(ox + e.x, oy + e.y, oz + e.z)
  c:lookAt(vec3(ox + l.x, oy + l.y, oz + l.z), vec3(PCAM.u.x, PCAM.u.y, PCAM.u.z))
end
local function cam_at(id, eye, look, u)
  if not (PCAM.node and PCAM.node.valid ~= false) then
    local a = find("Astronaut")
    spawn("FlagPhotoCam", vec3(a.x, a.y, a.z), function(n) PCAM.node = n end)
    wait_for(function() return PCAM.node end, 5, "the probe camera")
  end
  PCAM.id, PCAM.eye, PCAM.look, PCAM.u = id, eye, look, u
end
local function shot(name)
  local cam = (PCAM.eye and PCAM.node and PCAM.node.valid ~= false) and PCAM.node or nil
  pending = pending + 1
  local cb = function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://ropesettle/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("SHOT %s failed %s", name, tostring(why)) end
  end
  local opt = { w = 1280, h = 720, ui = cam == nil, draws = true }
  local ok, err
  if cam then ok, err = pcall(camera.capture, cam, opt, cb) else ok, err = pcall(camera.capture, opt, cb) end
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
  frames(3)
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

-- A site's frame (body-relative): u up, t1 along, t2 across, the ground radius r.
local function site(km)
  local b = home()
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  local R0 = len(bx, by, bz)
  local u0 = { x = bx / R0, y = by / R0, z = bz / R0 }
  local a0 = math.abs(u0.y) > 0.9 and { x = 1, y = 0, z = 0 } or { x = 0, y = 1, z = 0 }
  local tA = unit(cross(u0, a0))
  local k = km / R0
  local dir = unit({ x = u0.x * math.cos(k) + tA.x * math.sin(k), y = u0.y * math.cos(k) + tA.y * math.sin(k),
                     z = u0.z * math.cos(k) + tA.z * math.sin(k) })
  local gr = ground_r(b, dir.x, dir.y, dir.z, R0 + 150)
  local F = { u = dir, r = gr }
  F.t1 = unit(cross(dir, math.abs(dir.y) > 0.9 and { x = 1, y = 0, z = 0 } or { x = 0, y = 1, z = 0 }))
  F.t2 = unit(cross(dir, F.t1))
  F.g = { x = dir.x * gr, y = dir.y * gr, z = dir.z * gr }
  return F
end
local function at_body(F, t1, t2, h)
  local b = home()
  local d = unit({ x = F.u.x * F.r + F.t1.x * t1 + F.t2.x * t2, y = F.u.y * F.r + F.t1.y * t1 + F.t2.y * t2,
                   z = F.u.z * F.r + F.t1.z * t1 + F.t2.z * t2 })
  local gr = ground_r(b, d.x, d.y, d.z, F.r + 20)
  if not gr then return nil end
  return { x = d.x * (gr + h), y = d.y * (gr + h), z = d.z * (gr + h) }
end
local function dig(p, r)
  local b = home()
  terrain.dig(b.x + p.x, b.y + p.y, b.z + p.z, r, 1.0, { hardness = 1.0, falloff = "sharp" })
end
local function park(F, t1, t2)
  local a = find("Astronaut")
  local p = at_body(F, t1, t2, 1.1)
  local b = home()
  if p then a.x, a.y, a.z = b.x + p.x, b.y + p.y, b.z + p.z; a.vx, a.vy, a.vz = 0, 0, 0 end
  local C = findScript("crew")
  if C and C.quietMonitors then C.quietMonitors(2.0) end
end

-- The line against what is there: → pieces the physics ray finds blocked,
-- the worst depth into the rock along them by the field, samples inside it.
local function check_line(id, tag)
  local rc, dep = findScript("rope_climb"), findScript("deployables")
  local L = rc.layoutOf(id)
  if not L then return nil end
  local b = home()
  local pn = dep.nodeOf(id)
  local ign = { pn, find("Astronaut") }
  local pts = {}
  for i = 1, #L.p, 3 do pts[#pts + 1] = { x = L.p[i], y = L.p[i + 1], z = L.p[i + 2] } end
  for i = 1, #(L.tail or {}), 3 do pts[#pts + 1] = { x = L.tail[i], y = L.tail[i + 1], z = L.tail[i + 2] } end
  local blocked, worst, inside, samples, wblk, grazes = 0, 0, 0, 0, 0, 0
  local where = {}
  for i = 1, #pts - 1 do
    local a, c = pts[i], pts[i + 1]
    local dx, dy, dz = c.x - a.x, c.y - a.y, c.z - a.z
    local l = len(dx, dy, dz)
    if l > 0.02 then
      dx, dy, dz = dx / l, dy / l, dz / l
      for _, dir in ipairs({ 1, -1 }) do
        local o = dir > 0 and a or c
        local h = raycast(b.x + o.x, b.y + o.y, b.z + o.z, dx * dir, dy * dir, dz * dir, l, { ignore = ign, ignoreChildren = true })
        if h and h.distance > 0.004 and h.distance < l - 0.004 and math.min(h.distance, l - h.distance) < 0.1 then
          grazes = grazes + 1
          break
        elseif h and h.distance > 0.004 and h.distance < l - 0.004 then
          blocked = blocked + 1
          wblk = math.max(wblk, math.min(h.distance, l - h.distance))
          where[#where + 1] = string.format("%d:%.2f", i, h.distance)
          break
        end
      end
      local k = math.max(1, math.ceil(l / 0.05))
      for j = 0, k do
        local f = j / k
        local q = terrain.query(b.x + a.x + (c.x - a.x) * f, b.y + a.y + (c.y - a.y) * f, b.z + a.z + (c.z - a.z) * f)
        samples = samples + 1
        if q and q < -0.005 then inside = inside + 1; worst = math.max(worst, -q) end
      end
    end
  end
  local st = rc.solidStats
  P("LINE %s #%d: %.2f m, %s, %d points (%d put in round the rock), climbable %.1f-%.1f; ray-blocked pieces %d [%s] (grazes within 10 cm of a point %d); field: %d of %d samples inside, worst %.3f m; casts mesh %s field %s through %s, field nearer %s, worst disagreement %.3f m",
    tag, id, L.total, L.g and "on the ground" or "hanging free", L.n, L.cleared or 0, L.s_top, L.s_max, blocked,
    table.concat(where, " "), grazes, inside, samples, worst, tostring(st and st.mesh), tostring(st and st.field), tostring(st and st.through),
    tostring(st and st.nearer), st and st.dmax or -1)
  return { L = L, blocked = blocked, inside = inside, worst = worst }
end

local function plant(F, t2)
  local dep = findScript("deployables")
  if not dep then
    pcall(spawn, "DeployLib", vec3(0, 0, 0))
    dep = wait_for(function() return findScript("deployables") end, 10, "DeployLib")
  end
  local gp = at_body(F, 0, t2, 0)
  local b, bname = home()
  -- facing toward +t2 (the planter's side): the boom over −t2
  local id = dep.place("rope", bname, b.x + gp.x, b.y + gp.y, b.z + gp.z, { fx = F.t2.x, fy = F.t2.y, fz = F.t2.z })
  return id, gp
end

local function wait_layout(id)
  local rc = wait_for(function() return findScript("rope_climb") end, 10, "RopeLib")
  local dep = findScript("deployables")
  wait_for(function() return dep.nodeOf(id) end, 10, "the davit node")
  local L = wait_for(function() return rc.layoutOf(id) end, 20, "the layout")
  frames(30)   -- (rope.lua builds the drawn line)
  return L
end

-- the settle machinery's turn: rope_climb.settles moves past n
local function wait_settle(n0, tmo)
  local rc = findScript("rope_climb")
  if not rc.settles then P("no settle machinery here (base build)"); hold(tmo or 6) return false end
  return wait_for(function() return (rc.settles or 0) > n0 end, tmo or 10, "the line settling") ~= nil
end

local function main()
  boot()
  hold(3.0)
  local rc
  -- ── A. the ledge
  local A = site(150)
  park(A, 0, 16)
  hold(1.5)
  for _, d in ipairs({ 1.0, 3.0, 5.0, 7.0, 9.0 }) do
    for _, s1 in ipairs({ -6, -3, 0, 3, 6 }) do dig(add(add(A.g, A.u, -d), A.t1, s1), 3.2) end
  end
  settle()
  hold(2.0)
  local b = home()
  local edge = nil
  for t2 = 0, 8, 0.1 do
    local p = add(add(A.g, A.u, 2), A.t2, t2)
    local h = terrain.raycast(vec3(b.x + p.x, b.y + p.y, b.z + p.z), vec3(-A.u.x, -A.u.y, -A.u.z), 6)
    if h and h.distance < 2.6 then edge = t2 break end
  end
  edge = edge or 3.4
  P("ledge: the edge %.1f m out", edge)
  park(A, 0, edge + 5)
  hold(1.0)
  local idA = plant(A, edge + 0.6)
  local LA = wait_layout(idA)
  rc = findScript("rope_climb")
  local cA = check_line(idA, "ledge")
  R("ledge_layout", LA and LA.g and LA.total > 8, "the line falls %.1f m to the floor", LA and LA.total or -1)
  R("ledge_clear", cA and cA.blocked == 0 and cA.worst < 0.03,
    "no piece of the line through a collider (%d) or more than 3 cm into the field (%.3f m)", cA and cA.blocked or -1, cA and cA.worst or -1)
  local top = { x = LA.p[1], y = LA.p[2], z = LA.p[3] }
  local foot = { x = LA.p[#LA.p - 2], y = LA.p[#LA.p - 1], z = LA.p[#LA.p] }
  local mid = add(top, A.u, -LA.total * 0.5)
  local function pics(tag)
    cam_at(idA, add(add(add(mid, A.t2, -5.5), A.t1, 3.0), A.u, -1.0), add(mid, A.t2, 0.3), A.u)
    hold(0.6); shot(tag .. "_ledge_side")
    cam_at(idA, add(add(add(foot, A.t2, -3.0), A.t1, -1.2), A.u, 1.2), add(add(foot, A.u, 4), A.t2, 0.3), A.u)
    hold(0.6); shot(tag .. "_ledge_foot")
    cam_at(idA, add(add(add(top, A.t2, -1.2), A.t1, 1.6), A.u, 0.3), add(add(top, A.u, -2.5), A.t2, 0.4), A.u)
    hold(0.6); shot(tag .. "_ledge_lip")
  end
  pics("1")

  -- ── B. the cave mouth
  local Bs = site(-150)
  park(Bs, 0, 18)
  hold(1.5)
  -- a shaft 2 m across from the ground down 9 m (along t1 = 0, t2 = 0), and a chamber under it
  for _, d in ipairs({ 0.5, 2.0, 3.5, 5.0, 6.5, 8.0 }) do dig(add(Bs.g, Bs.u, -d), 1.25) end
  for _, d in ipairs({ 11.0, 13.0 }) do
    for _, o in ipairs({ { 0, 0 }, { 2.5, 0 }, { -2.5, 0 }, { 0, 2.5 }, { 0, -2.5 } }) do
      dig(add(add(add(Bs.g, Bs.u, -d), Bs.t1, o[1]), Bs.t2, o[2]), 3.0)
    end
  end
  settle()
  hold(2.0)
  b = home()
  local rim = nil
  for t2 = 0, 4, 0.05 do
    local p = add(add(Bs.g, Bs.u, 2), Bs.t2, t2)
    local h = terrain.raycast(vec3(b.x + p.x, b.y + p.y, b.z + p.z), vec3(-Bs.u.x, -Bs.u.y, -Bs.u.z), 6)
    if h and h.distance < 2.6 then rim = t2 break end
  end
  rim = rim or 1.25
  P("shaft: the rim %.2f m out", rim)
  park(Bs, 0, rim + 5)
  hold(1.0)
  local idB = plant(Bs, rim + 0.5)
  local LB = wait_layout(idB)
  local cB = check_line(idB, "cave")
  R("cave_layout", LB and LB.total > 8, "the line drops %.1f m through the mouth (%s)", LB and LB.total or -1, LB and (LB.g and "to the floor" or "free") or "-")
  R("cave_clear", cB and cB.blocked == 0 and cB.worst < 0.03, "no piece through a collider (%d) or into the field (%.3f m)",
    cB and cB.blocked or -1, cB and cB.worst or -1)
  local btop = { x = LB.p[1], y = LB.p[2], z = LB.p[3] }
  local bfoot = { x = LB.p[#LB.p - 2], y = LB.p[#LB.p - 1], z = LB.p[#LB.p] }
  local function cave_pics(tag)
    -- from the chamber, looking up the line to the mouth; from the rim, down the shaft
    cam_at(idB, add(add(add(bfoot, Bs.t1, 2.6), Bs.t2, 1.2), Bs.u, 1.0), add(add(bfoot, Bs.u, 6.5), Bs.t2, 0.0), Bs.u)
    hold(0.6); shot(tag .. "_cave_up")
    cam_at(idB, add(add(add(btop, Bs.t1, 1.4), Bs.t2, 1.4), Bs.u, 0.8), add(add(btop, Bs.u, -5.0), Bs.t2, 0.0), Bs.u)
    hold(0.6); shot(tag .. "_cave_down")
  end
  cave_pics("1")

  -- ── E. asleep: the cost while nothing changes (both lines near the crew? A is)
  park(A, 0, edge + 5)
  hold(1.0)
  local n0c, ms0 = rc.settleChecks or 0, rc.settleMs or 0
  local s0 = rc.settles or 0
  hold(5.0)
  P("COST asleep 5 s: %d signature reads, %d settles, dearest check or re-lay so far %.3f ms", (rc.settleChecks or 0) - n0c,
    (rc.settles or 0) - s0, rc.settleMs or -1)
  R("asleep", (rc.settles or 0) == s0, "nothing changed, nothing laid again (%d)", (rc.settles or 0) - s0)

  -- ── C1. A's floor dug 3 m deeper under the foot
  local n1 = rc.settles or 0
  local v1 = rc.version
  for _, o in ipairs({ { 0, 0 }, { 1.5, 0 }, { -1.5, 0 }, { 0, 1.5 }, { 0, -1.5 } }) do
    dig(add(add(add(foot, A.u, -2.0), A.t1, o[1]), A.t2, o[2]), 2.6)
  end
  settle()
  local ok1 = wait_settle(n1, 12)
  local c1 = check_line(idA, "ledge dug")
  local L1 = rc.layoutOf(idA)
  R("dug_floor", ok1 and L1 and L1.total > LA.total + 1.5 and c1.blocked == 0 and c1.worst < 0.03,
    "the line settled again (%s): %.1f → %.1f m, %d pieces blocked, worst %.3f m in", tostring(ok1), LA.total, L1 and L1.total or -1,
    c1 and c1.blocked or -1, c1 and c1.worst or -1)
  foot = { x = L1.p[#L1.p - 2], y = L1.p[#L1.p - 1], z = L1.p[#L1.p] }
  pics("2")
  -- ── C2. a boss raised on the wall behind the line, half way down
  local n2 = rc.settles or 0
  local wall = add(add(top, A.u, -LA.total * 0.45), A.t2, 0.9)
  b = home()
  for _ = 1, 3 do terrain.sculpt(b.x + wall.x, b.y + wall.y, b.z + wall.z, 1.4, 1.0, "raise") end
  settle()
  local ok2 = wait_settle(n2, 12)
  local c2 = check_line(idA, "ledge boss")
  R("raised_wall", ok2 and c2 and c2.blocked == 0 and c2.worst < 0.03,
    "the line settled over the boss (%s): %d points (%d put in), %d pieces blocked, worst %.3f m in", tostring(ok2),
    c2 and c2.L.n or -1, c2 and c2.L.cleared or -1, c2 and c2.blocked or -1, c2 and c2.worst or -1)
  pics("3")
  -- ── C3. B's mouth: a dig in the chamber's roof beside the line
  park(Bs, 0, rim + 5)
  hold(1.0)
  local n3 = rc.settles or 0
  b = home()
  local sideB = add(add(btop, Bs.u, -4.0), Bs.t2, 0.7)   -- (0.3 m into the shaft wall the line hangs beside)
  for _ = 1, 2 do terrain.sculpt(b.x + sideB.x, b.y + sideB.y, b.z + sideB.z, 1.2, 1.0, "raise") end
  settle()
  local ok3 = wait_settle(n3, 12)
  local c3 = check_line(idB, "cave narrowed")
  R("cave_narrowed", c3 and c3.blocked == 0 and c3.worst < 0.03,
    "a fill in the shaft beside the line (%s): %d pieces blocked, worst %.3f m in", ok3 and "settled again" or "not moved",
    c3 and c3.blocked or -1, c3 and c3.worst or -1)
  cave_pics("2")

  -- ── D. the footing dug out from under A's davit (past the guard)
  park(A, 0, edge + 6)
  hold(1.0)
  local f0 = rc.falls or 0
  local dep = findScript("deployables")
  local rec = dep.get(idA)
  local gpA = { x = rec.x, y = rec.y, z = rec.z }
  for _, d in ipairs({ 0.4, 1.2, 2.2 }) do dig(add(gpA, A.u, -d), 1.3) end
  settle()
  local fell = rc.falls and wait_for(function() return (rc.falls or 0) > f0 end, 10, "the davit falling")
  local list = dep.list("rope")
  local newA = nil
  for _, e in ipairs(list) do if e.id ~= idB and e.id ~= idA then newA = e.id end end
  R("footing_gone", fell ~= nil and dep.get(idA) == nil and newA ~= nil,
    "the davit fell (%s): the old #%d %s, a new #%s on the ground below", tostring(fell ~= nil), idA,
    dep.get(idA) and "still there" or "gone", tostring(newA))
  if newA then
    local Ln = wait_layout(newA)
    local rn = dep.get(newA)
    P("the fallen davit #%d: %.1f m below where it stood; its line %.1f m (%s)", newA,
      len(gpA.x, gpA.y, gpA.z) - len(rn.x, rn.y, rn.z), Ln and Ln.total or -1, Ln and (Ln.g and "on the ground" or "free") or "-")
    PCAM.id = newA
    local gn = { x = rn.x, y = rn.y, z = rn.z }
    cam_at(newA, add(add(add(gn, A.t2, 3.5), A.t1, 2.5), A.u, 1.8), add(gn, A.u, 0.6), A.u)
    hold(0.6); shot("4_fallen_davit")
  end
  P("COST end: %d signature reads in all, dearest check or re-lay %.3f ms, %d settles, %d falls", rc.settleChecks or -1,
    rc.settleMs or -1, rc.settles or -1, rc.falls or -1)
  PCAM.eye = nil
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
