-- CREW BODY / CREW DOLL — the crew members you are not controlling
-- (docs/crew-and-items.md §3.4, §4.1). One script, two prefabs:
--
--   prefabs/CrewBody   a member ON FOOT in range: the Astronaut's capsule and
--                      suit, KINEMATIC. It stands where it was left, held in
--                      its planet's frame every physics tick (the planet
--                      moves 1.5–6 m a tick: the position lives body-relative
--                      in the crew record, never as a world point), upright
--                      along the local vertical, breathing the idle clip.
--                      In space beside a craft it rides that craft's part
--                      frame instead (the record's `anchor`).
--   prefabs/CrewDoll   a member SEATED in a craft: no body, no collider.
--                      Placed every lateUpdate at its seat from the part's
--                      pose this frame (crew.dollPose), legs folded onto the
--                      footrest by IK. In an open seat command_seat.lua poses
--                      it (the same pose the Astronaut gets there).
--
-- crew.lua spawns and despawns both, and binds them: bind(id) for a body,
-- bindDoll(id) for a doll. They take no input.
--
-- A BODY ON FOOT (graveyard2, Ty 2026-11-10: "npcs blocking the way",
-- "facing a wall", "feet clipping through the floor", "a real NPC for Dana"):
--   FACING     the record's `face` is the way the SUIT LOOKS (crew.lua's
--              convention: the rig looks along its node's +Z). The node's
--              -Z is turned against it (setUp(up, -face)). Before, the
--              standing pose turned -Z TO the face, so a member you switched
--              away from stood with their back to where you had looked.
--   FEET       the capsule stands on what is under it: settled by a ray
--              down from inside the capsule (never from above a ceiling),
--              and again whenever the record is moved by someone else
--              (crew.setDown, a scenario post): a post is a ground point
--              1 m up, which left the feet 0.15 m into a 0.2 m slab.
--   WALKING    steerTo/steerSelf: a point handed over BODY-RELATIVE every
--              frame (docs/positions-and-frames.md rule 1). When the
--              straight line is blocked a PATH is found: an A* over a 0.25 m
--              grid in the walker's own ground frame, each cell asked of the
--              physics world once (two spheres, the capsule's shape), lazily
--              and on a budget a tick, so a walk round a desk and through a
--              door costs a few ticks of standing still before it sets off.
--              A door's leaf ("Door…" colliders) is passable: kit_live opens
--              doors for a walking body as it does for the Astronaut. The
--              path is pulled straight where the cells allow, kept as
--              body-relative points. The walker waits for the player in its
--              way, then carries on.
--   IDLE       a body that stands: steps aside when the player walks into
--              it, steps out of a doorway, faces the most open way when it
--              has no facing, and turns its head to the player close by.
--   POSES      the record's `pose` = { kind = "lie"|"sit", x,y,z (the
--              surface point, body-relative), f = { x,y,z } (lie: the head's
--              way; sit: the way they face) }: lying on a bunk, sitting on
--              its edge (legs by IK, as a seated doll). The record's x,y,z
--              stays where they stood, so a switch or a walk starts there.

defaults = {
  half_h = 0.95,       -- the capsule's half height (planet_walker's 1.9 m suit capsule)
  model_yaw = 3.14159265,
  down_roll = 0.35,    -- downed: rad rolled from flat on the back onto a side
  down_lift = 0.38,    -- downed: the capsule's centre this far off the ground (the pack under them)
  foot_out = 0.42,     -- a seated doll's feet: forward of the hips…
  foot_down = 0.55,    -- …and below them
  foot_side = 0.12,
  hand_out = 0.18,
  hand_side = 0.26,
  lie_lift = 0.23,     -- lying (pose): the capsule's centre over the surface (the pack under them)
  sit_lift = 0.10,     -- sitting (pose): the hips over the surface
  sit_foot_out = 0.46,
  sit_foot_down = 0.52,
}

local function P(k) return (params and params[k]) or defaults[k] end

memberId = nil
doll = false
local model, anim = nil, nil
local settled = false
local vel = { x = 0, y = 0, z = 0 }

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not (r and r.valid ~= false) then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end

local function find_model(node)
  if model and model.valid then return model end
  for _, c in ipairs(node:children()) do
    if c.name == "AstroModel" then model = c end
  end
  anim = model and model.animator and model:animator() or nil
  return model
end

local seen = nil        -- the record's point as this body last saw (or wrote) it
function bind(id)
  memberId, doll = id, false
  settled, seen = false, nil
end

function bindDoll(id)
  memberId, doll = id, true
end

-- (graveyard2) crew.lua is about to destroy this body (the member was taken
-- over): it stops placing itself from the record at once, so the move out of
-- the way that crew.lua makes holds until the destroy lands. Without it the
-- next tick put the capsule back where the Astronaut had just been set down,
-- and the Astronaut was pushed up into the ceiling.
retired = false
function retire(x, y, z)
  retired = true
  local n = self_node
  if n and n.valid ~= false and x then
    pcall(function() n.tickPos = vec3(x, y, z) end)
    pcall(function() n.x, n.y, n.z = x, y, z end)
  end
end

-- The body's velocity this tick (0 standing on a planet: the rails frame;
-- a craft part's velocity when anchored beside one): the Astronaut takes it
-- over on a switch.
function velocityNow() return vel.x, vel.y, vel.z end

local sqrt, abs, min, max = math.sqrt, math.abs, math.min, math.max
local function norm3(x, y, z)
  local l = sqrt(x * x + y * y + z * z)
  if l < 1e-9 then return 0, 0, 0, 0 end
  return x / l, y / l, z / l, l
end
-- the walker's ground frame at a body-relative point: up, and two tangents
-- (any pair: the planner's grid is its own)
local function frame_at(x, y, z)
  local ux, uy, uz = norm3(x, y, z)
  local ax, ay, az = 0, 1, 0
  if abs(uy) > 0.9 then ax, ay, az = 1, 0, 0 end
  local ex, ey, ez = norm3(ay * uz - az * uy, az * ux - ax * uz, ax * uy - ay * ux)
  local nx, ny, nz = uy * ez - uz * ey, uz * ex - ux * ez, ux * ey - uy * ex
  return { ux = ux, uy = uy, uz = uz, ex = ex, ey = ey, ez = ez, nx = nx, ny = ny, nz = nz }
end
-- a vector laid flat in the ground frame at up u (→ unit, or nil)
local function flat(ux, uy, uz, x, y, z)
  local d = x * ux + y * uy + z * uz
  local fx, fy, fz, l = norm3(x - ux * d, y - uy * d, z - uz * d)
  if l < 1e-6 then return nil end
  return fx, fy, fz
end

local function astro()
  local a = refs.astro
  if not (a and a.valid ~= false) then a = find and find("Astronaut") or nil; refs.astro = a end
  return a
end
-- the player on foot, controlling someone else: their capsule's centre,
-- body-relative to `bname`, this tick (tickPos: frames doc rule 2/3)
local function player_rel(bname, b)
  local pw = ref("planet_walker")
  if pw and pw.onFoot == false then return nil end
  local C = ref("crew")
  if C and C.activeId and C.activeId() == memberId then return nil end
  local a = astro()
  if not a then return nil end
  local x, y, z = a.x, a.y, a.z
  local tp = a.tickPos
  if tp and tp.x then x, y, z = tp.x, tp.y, tp.z end
  return x - b.x, y - b.y, z - b.z
end

-- ── what the physics world says about a spot ────────────────────────────────
-- A leaf of a door, a crew member or the Astronaut is passable (a door opens
-- for a walker: kit_live); terrain (no node) is the walk's own business
-- (it steps over what it can).
local function passable(n)
  if n == nil then return true end
  local nm = n.name
  if type(nm) ~= "string" then return false end
  return nm:sub(1, 4) == "Door" or nm == "CrewBody" or nm == "Astronaut" or nm == "AstroModel"
end
CELL_R, CELL_LO, CELL_HI = 0.27, 0.62, 1.30
-- is a standing capsule free at floor point (world) wx,wy,wz with up u?
local function spot_free(wx, wy, wz, u, ign)
  if not (overlapSphere and vec3) then return true end
  for _, h in ipairs({ CELL_LO, CELL_HI }) do
    local ok, hits = pcall(overlapSphere, vec3(wx + u.ux * h, wy + u.uy * h, wz + u.uz * h), CELL_R, { ignore = ign })
    if ok and type(hits) == "table" then
      for _, hit in ipairs(hits) do if not passable(hit.node) then return false end end
    end
  end
  return true
end
-- (kept 2 s: a scene walk for the other bodies is not a per-query cost)
local ign_cache, ign_t = nil, -10
local function ignore_list(node)
  local t = time or 0
  if ign_cache and t - ign_t < 2.0 then return ign_cache end
  local out = { node }
  local a = astro()
  if a and a.valid ~= false then out[#out + 1] = a end
  for _, s in ipairs(findScripts and findScripts("crew_body") or {}) do
    local n = s.node
    if n and n.valid ~= false and n.id ~= node.id then out[#out + 1] = n end
  end
  ign_cache, ign_t = out, t
  return out
end

-- ── PATHS (pure but for `free`, tests/smoke_crew_walk.lua) ──────────────────
-- plan = newPlan(gi, gj, arrive_cells, maxEval): an A* from cell (0, 0)
-- toward (gi, gj) over 8-connected cells; planStep(plan, free, budget) asks
-- `free(i, j)` for at most `budget` new cells → "run" | "done" | "fail";
-- plan.cells is the route (start first) once done. A goal it cannot reach
-- gives the route to the nearest cell it did reach (still "done").
local function ckey(i, j) return (i + 2048) * 4096 + (j + 2048) end
local function octile(di, dj)
  di, dj = abs(di), abs(dj)
  return (di + dj) + (1.41421356 - 2) * min(di, dj)
end
function newPlan(gi, gj, arrive, maxEval)
  local p = { gi = gi, gj = gj, arrive = arrive or 1, maxEval = maxEval or 1800, free = {}, g = {}, came = {},
              heap = {}, closed = {}, evals = 0, state = "run", best = nil, bestH = math.huge }
  local k0 = ckey(0, 0)
  p.free[k0] = true
  p.g[k0] = 0
  p.heap[1] = { octile(gi, gj), 0, 0, k0 }
  return p
end
local function hpush(h, e)
  h[#h + 1] = e
  local i = #h
  while i > 1 do
    local pa = math.floor(i / 2)
    if h[pa][1] <= h[i][1] then break end
    h[pa], h[i] = h[i], h[pa]
    i = pa
  end
end
local function hpop(h)
  local top = h[1]
  local last = table.remove(h)
  if #h > 0 then
    h[1] = last
    local i, n = 1, #h
    while true do
      local l, r, s = i * 2, i * 2 + 1, i
      if l <= n and h[l][1] < h[s][1] then s = l end
      if r <= n and h[r][1] < h[s][1] then s = r end
      if s == i then break end
      h[s], h[i] = h[i], h[s]
      i = s
    end
  end
  return top
end
local NB = { { 1, 0, 1 }, { -1, 0, 1 }, { 0, 1, 1 }, { 0, -1, 1 }, { 1, 1, 1.41421356 }, { 1, -1, 1.41421356 },
             { -1, 1, 1.41421356 }, { -1, -1, 1.41421356 } }
local function cell_free(p, free, i, j)
  local k = ckey(i, j)
  local v = p.free[k]
  if v == nil then
    v = free(i, j) and true or false
    p.free[k] = v
    p.evals = p.evals + 1
  end
  return v
end
local function route(p, k)
  local out = {}
  while k do
    out[#out + 1] = k
    k = p.came[k]
  end
  local cells = {}
  for n = #out, 1, -1 do
    local kk = out[n]
    cells[#cells + 1] = { math.floor(kk / 4096) - 2048, kk % 4096 - 2048 }
  end
  return cells
end
function planStep(p, free, budget)
  if p.state ~= "run" then return p.state end
  local e0 = p.evals
  while #p.heap > 0 do
    if p.evals - e0 >= budget then return "run" end
    if p.evals >= p.maxEval then break end
    local top = hpop(p.heap)
    local k, i, j = top[4], top[2], top[3]
    if not p.closed[k] then
      p.closed[k] = true
      local h = octile(p.gi - i, p.gj - j)
      if h < p.bestH then p.bestH, p.best = h, k end
      if h <= p.arrive then
        p.cells, p.state, p.reached = route(p, k), "done", true
        return "done"
      end
      for _, d in ipairs(NB) do
        local ni, nj = i + d[1], j + d[2]
        local nk = ckey(ni, nj)
        if not p.closed[nk] then
          -- (a diagonal never cuts a blocked corner)
          local okc = true
          if d[1] ~= 0 and d[2] ~= 0 then
            okc = cell_free(p, free, i + d[1], j) and cell_free(p, free, i, j + d[2])
          end
          if okc and cell_free(p, free, ni, nj) then
            local g = p.g[k] + d[3]
            if p.g[nk] == nil or g < p.g[nk] then
              p.g[nk], p.came[nk] = g, k
              hpush(p.heap, { g + octile(p.gi - ni, p.gj - nj), ni, nj, nk })
            end
          end
        end
      end
    end
  end
  -- out of cells or out of budget: the nearest cell reached
  if p.best and p.best ~= ckey(0, 0) then
    p.cells, p.state, p.reached = route(p, p.best), "done", false
    return "done"
  end
  p.state = "fail"
  return "fail"
end
-- the route pulled straight: a corner is kept only where the line past it
-- would cross a blocked cell → { {i, j} … } without the start
function pullStraight(p, free)
  local cells = p.cells or {}
  local out = {}
  if #cells < 2 then return out end
  local function clear(a, b)
    local di, dj = b[1] - a[1], b[2] - a[2]
    local n = math.max(1, math.ceil(math.max(abs(di), abs(dj)) * 2))
    for s = 1, n - 1 do
      local t = s / n
      local i, j = math.floor(a[1] + di * t + 0.5), math.floor(a[2] + dj * t + 0.5)
      if not cell_free(p, free, i, j) then return false end
      -- (the capsule's width: both neighbours across a diagonal step)
    end
    return true
  end
  local anchor, k = cells[1], 2
  while k <= #cells do
    local far = k
    for m = #cells, k, -1 do
      if clear(anchor, cells[m]) then far = m break end
    end
    out[#out + 1] = cells[far]
    anchor, k = cells[far], far + 1
  end
  return out
end

-- ── STEERING (scenario `walk`, PLAN scenarios2 §2 F2) ───────────────────────
-- steerTo(id, body, x, y, z, { speed, arrive, auto, faceTo }) walks member
-- `id`'s body toward a point given BODY-RELATIVE (docs/positions-and-
-- frames.md rule 1): the caller hands it again every frame from its ref, and
-- a target not refreshed for half a second lets go (`auto` walks — a step
-- aside — keep their own target). The walk is along the ground (a ray down
-- each tick sets the feet), round what is in the way (the path above),
-- facing the way it goes, on the walk clip; the record is written twice a
-- second and where it stops. Any CrewBody's script routes the call to the
-- member's own (each body runs its own copy).
local steer = nil      -- { body, x, y, z, speed, arrive, t, auto, faceTo }
local wpos = nil       -- the walking point, body-relative (the record's until it stops)
local arrived_ = false
local gait_on, gait_ph = false, 0.0
local look_fn = nil
local wface = nil      -- the way the walk faces (the suit's look, smoothed)
local plan = nil       -- { body, ox,oy,oz (floor, body-rel), F, state, P (newPlan), pts, k, gx,gy,gz, t }
local wait_t = 0       -- s waited for the player in the way (this hold)
local rec_t = 0        -- the record's last write while walking
local STEER_STALE, ARRIVE_M, WALK_STRIDE = 0.5, 0.35, 1.6
local STEP_UP, STEP_DOWN = 0.45, 1.2
GRID_H, EVAL_BUDGET, MAX_EVAL, REPLAN_M = 0.25, 24, 1800, 1.0
walkStats = { ticks = 0, stops = 0, metres = 0, game = 0, plans = 0, evals = 0, paths = 0, straight = 0, waits = 0 }   -- (probes)
function steerSelf(body, x, y, z, opts)
  if doll or not memberId or type(x) ~= "number" then return false end
  if not steer then arrived_ = false end
  -- (a new target body or a far jump is a new walk)
  if steer and (steer.body ~= body or (x - steer.x) ^ 2 + (y - steer.y) ^ 2 + (z - steer.z) ^ 2 > 25) then plan = nil end
  steer = steer or {}
  steer.body, steer.x, steer.y, steer.z = body, x, y, z
  steer.speed = (opts and opts.speed) or 1.4
  steer.arrive = (opts and opts.arrive) or ARRIVE_M
  steer.auto = opts and opts.auto or nil
  steer.faceTo = opts and opts.faceTo or steer.faceTo
  steer.t = time or 0
  return true
end
function steerTo(id, body, x, y, z, opts)
  if id == memberId and not doll then return steerSelf(body, x, y, z, opts) end
  for _, s in ipairs(findScripts and findScripts("crew_body") or {}) do
    if s.memberId == id and s.doll ~= true and s.steerSelf then return s.steerSelf(body, x, y, z, opts) end
  end
  return false
end
-- stop where it stands (the record written there)
local stop_now = false
function steerStop() if steer then stop_now = true end end
function arrived() return arrived_ end
function walking() return steer ~= nil end
function planning() return plan ~= nil and plan.state == "run" end
-- the walking point, body-relative (nil when standing: the record's is right)
function walkPoint()
  if not (steer and wpos) then return nil end
  return steer.body, wpos.x, wpos.y, wpos.z
end
-- metres from the walking point to a body-relative target (nil: not on that body)
function walkDist(body, x, y, z)
  local c = ref("crew")
  local r = c and c.get and c.get(memberId)
  if not (r and r.body == body) then return nil end
  local p = wpos or r
  local dx, dy, dz = x - (p.x or 0), y - (p.y or 0), z - (p.z or 0)
  local l = math.sqrt(x * x + y * y + z * z)
  local du = l > 1e-6 and (dx * x + dy * y + dz * z) / l or 0
  -- → the straight distance, the distance along the ground, the height above the target
  return math.sqrt(dx * dx + dy * dy + dz * dz), math.sqrt(math.max(0, dx * dx + dy * dy + dz * dz - du * du)), -du
end
-- the head turned to what `fn` names THIS frame (fn() → x, y, z, weight in
-- world space, read when posed), nil lets go
function lookSelf(fn) look_fn = fn end
function lookNow() return look_fn end

local function gait(on, dt, speed)
  if not anim and model and model.valid ~= false and model.animator then anim = model:animator() end
  if not anim then return end
  if on then
    if not gait_on then pcall(anim.setLayerWeight, anim, "Gait", 1.0); pcall(anim.setParam, anim, "gait", 0.0); gait_on = true end
    gait_ph = (gait_ph + dt * (speed or 1.4) / WALK_STRIDE) % 1.0
    pcall(anim.seek, anim, gait_ph * (anim:duration("run") or 1.0), "Gait")
  elseif gait_on then
    pcall(anim.setLayerWeight, anim, "Gait", 0.0); gait_on = false
  end
end

-- the planner's free(i, j) for this tick: the cell's floor point in the world
local function plan_free(b, ign)
  local pl = plan
  local F, h = pl.F, GRID_H
  return function(i, j)
    local ox, oy, oz = pl.ox + (F.ex * i + F.nx * j) * h, pl.oy + (F.ey * i + F.ny * j) * h, pl.oz + (F.ez * i + F.nz * j) * h
    return spot_free(b.x + ox, b.y + oy, b.z + oz, F, ign)
  end
end
-- start a plan from body-relative capsule centre p toward target t
local function plan_begin(node, b, p, t)
  local F = frame_at(p.x, p.y, p.z)
  local hh = P("half_h") + 0.02
  local ox, oy, oz = p.x - F.ux * hh, p.y - F.uy * hh, p.z - F.uz * hh
  local dx, dy, dz = t.x - ox, t.y - oy, t.z - oz
  local gi = (dx * F.ex + dy * F.ey + dz * F.ez) / GRID_H
  local gj = (dx * F.nx + dy * F.ny + dz * F.nz) / GRID_H
  plan = { body = steer.body, ox = ox, oy = oy, oz = oz, F = F, gx = t.x, gy = t.y, gz = t.z, t = time or 0,
           ign = ignore_list(node), state = "straight", pts = nil, k = 1 }
  walkStats.plans = walkStats.plans + 1
  -- the straight line first: two sphere sweeps at the capsule's knees and
  -- chest (a hit on terrain, a door or a person does not count)
  local L = sqrt(gi * gi + gj * gj) * GRID_H
  local blocked = false
  if spherecast and vec3 and L > 0.3 then
    local fx, fy, fz = norm3(F.ex * gi + F.nx * gj, F.ey * gi + F.ny * gj, F.ez * gi + F.nz * gj)
    for _, hgt in ipairs({ CELL_LO, CELL_HI }) do
      local o = vec3(b.x + ox + F.ux * hgt, b.y + oy + F.uy * hgt, b.z + oz + F.uz * hgt)
      local ok, hit = pcall(spherecast, o, vec3(fx, fy, fz), CELL_R, L, { ignore = plan.ign })
      if ok and hit and not passable(hit.node) then blocked = true end
      if ok and hit and passable(hit.node) and hit.node ~= nil then blocked = true end   -- (a door ahead: a wall may stand past it)
    end
  end
  if not blocked then
    plan.state = "done"
    walkStats.straight = walkStats.straight + 1
    return
  end
  local ar = max(1, math.floor((steer.arrive or ARRIVE_M) / GRID_H))
  plan.P = newPlan(math.floor(gi + 0.5), math.floor(gj + 0.5), ar, MAX_EVAL)
  plan.state = "run"
end
-- one tick of planning; when done, the route as body-relative points
local function plan_tick(b)
  local pl = plan
  local free = plan_free(b, pl.ign)
  local st = planStep(pl.P, free, EVAL_BUDGET)
  if st == "run" then return end
  walkStats.evals = walkStats.evals + pl.P.evals
  if st == "fail" then pl.state = "done"; pl.pts = nil; return end
  local cells = pullStraight(pl.P, free)
  local pts = {}
  for n, c in ipairs(cells) do
    -- (the last cell is the target's own: the walk goes on to the target itself)
    if n < #cells or not pl.P.reached then
      local i, j = c[1], c[2]
      pts[#pts + 1] = { x = pl.ox + (pl.F.ex * i + pl.F.nx * j) * GRID_H, y = pl.oy + (pl.F.ey * i + pl.F.ny * j) * GRID_H,
                        z = pl.oz + (pl.F.ez * i + pl.F.nz * j) * GRID_H }
    end
  end
  pl.pts, pl.k, pl.state = pts, 1, "done"
  pl.P = nil
  walkStats.paths = walkStats.paths + 1
end

-- place the node standing at body-relative capsule centre p, the suit looking along f
local function place_stand(node, b, p, fx, fy, fz)
  node.x, node.y, node.z = b.x + p.x, b.y + p.y, b.z + p.z
  node.vx, node.vy, node.vz = 0, 0, 0
  vel.x, vel.y, vel.z = 0, 0, 0
  local ux, uy, uz = norm3(p.x, p.y, p.z)
  if fx then node:setUp(vec3(ux, uy, uz), vec3(-fx, -fy, -fz)) else node:setUp(vec3(ux, uy, uz)) end
end

-- one tick of a walk: → true while it walked (the node placed), false when it stopped
local function steer_tick(node, c, r, dt)
  local b = steer and space.body(steer.body or "")
  if not (b and r.body == steer.body) then steer, plan = nil, nil; return false end
  local now_ = time or 0
  local stop = stop_now or (not steer.auto and now_ - (steer.t or 0) > STEER_STALE)
  stop_now = false
  local p = wpos or { x = r.x or 0, y = r.y or 0, z = r.z or 0 }
  local l = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
  if l < 1e-6 then steer, plan = nil, nil; return false end
  local ux, uy, uz = p.x / l, p.y / l, p.z / l
  -- the final target, along the ground
  local tdx, tdy, tdz = steer.x - p.x, steer.y - p.y, steer.z - p.z
  local tdu = tdx * ux + tdy * uy + tdz * uz
  tdx, tdy, tdz = tdx - ux * tdu, tdy - uy * tdu, tdz - uz * tdu
  local td = math.sqrt(tdx * tdx + tdy * tdy + tdz * tdz)
  if stop or td < (steer.arrive or ARRIVE_M) then
    if td < (steer.arrive or ARRIVE_M) then arrived_ = true end
    walkStats.stops = walkStats.stops + 1
    local face = wface
    if steer.faceTo == "player" then
      local px, py, pz = player_rel(steer.body, b)
      if px then local fx, fy, fz = flat(ux, uy, uz, px - p.x, py - p.y, pz - p.z); if fx then face = { x = fx, y = fy, z = fz } end end
    end
    if wpos then
      c.patch(memberId, { x = wpos.x, y = wpos.y, z = wpos.z, face = face or false })
      seen = { x = wpos.x, y = wpos.y, z = wpos.z }
    elseif face then c.patch(memberId, { face = face }) end
    steer, wpos, wface, plan = nil, nil, nil, nil
    gait(false)
    return false
  end
  -- the route: planned when the walk starts, again when the target has moved
  if not plan or (plan.state == "done" and now_ - plan.t > 1.0
      and (steer.x - plan.gx) ^ 2 + (steer.y - plan.gy) ^ 2 + (steer.z - plan.gz) ^ 2 > REPLAN_M * REPLAN_M) then
    plan_begin(node, b, p, steer)
  end
  if plan.state == "run" then
    plan_tick(b)
    if plan.state == "run" or not wpos then
      -- (standing while it thinks: a few ticks)
      place_stand(node, b, p, wface and wface.x, wface and wface.y, wface and wface.z)
      gait(false)
      return true
    end
  end
  -- the point to head for: the next corner of the route, then the target
  local ax, ay, az = steer.x, steer.y, steer.z
  local pts = plan.pts
  while pts and plan.k <= #pts do
    local q = pts[plan.k]
    local qx, qy, qz = q.x - p.x, q.y - p.y, q.z - p.z
    local qu = qx * ux + qy * uy + qz * uz
    local qd = math.sqrt(math.max(0, qx * qx + qy * qy + qz * qz - qu * qu))
    if qd < 0.3 then plan.k = plan.k + 1 else ax, ay, az = q.x, q.y, q.z break end
  end
  local dx, dy, dz = ax - p.x, ay - p.y, az - p.z
  local du = dx * ux + dy * uy + dz * uz
  dx, dy, dz = dx - ux * du, dy - uy * du, dz - uz * du
  local d = math.sqrt(dx * dx + dy * dy + dz * dz)
  if d < 1e-4 then d, dx, dy, dz = td, tdx, tdy, tdz end
  -- (paced by the game clock between ticks: a slow frame still walks the metres it owes)
  local gdt = steer.lt and math.max(0, math.min(0.25, now_ - steer.lt)) or dt
  steer.lt = now_
  local fx, fy, fz = dx / d, dy / d, dz / d
  -- the player in the way: wait for them (2.5 s), then carry on
  local px, py, pz = player_rel(steer.body, b)
  if px then
    local qx, qy, qz = px - p.x, py - p.y, pz - p.z
    local qu = qx * ux + qy * uy + qz * uz
    qx, qy, qz = qx - ux * qu, qy - uy * qu, qz - uz * qu
    local qd = math.sqrt(qx * qx + qy * qy + qz * qz)
    local ahead = qd > 1e-3 and (qx * fx + qy * fy + qz * fz) / qd or 0
    if qd < 0.85 and ahead > 0.4 and wait_t < 2.5 and abs(qu) < 1.5 then
      wait_t = wait_t + gdt
      walkStats.waits = walkStats.waits + 1
      place_stand(node, b, p, wface and wface.x or fx, wface and wface.y or fy, wface and wface.z or fz)
      gait(false)
      return true
    end
    if qd > 1.4 then wait_t = 0 end
  end
  local step = math.min(d, (steer.speed or 1.4) * gdt)
  walkStats.ticks, walkStats.metres, walkStats.game = walkStats.ticks + 1, walkStats.metres + step, walkStats.game + gdt
  local nx, ny, nz = p.x + fx * step, p.y + fy * step, p.z + fz * step
  -- the feet on what is under the new point (ground, a floor), else the same height
  local nl = math.sqrt(nx * nx + ny * ny + nz * nz)
  local vx, vy, vz = nx / nl, ny / nl, nz / nl
  local hh = P("half_h") + 0.02
  -- a step up of STEP_UP at most, a step down of STEP_DOWN: the ray starts at
  -- knee height over the feet, so a platform overhead or a tank's flank is
  -- walked under or past, never climbed (a probe body went up 8 m of a tank)
  local h = nil
  if raycast then
    local o = hh - STEP_UP
    local ok, hit = pcall(raycast, b.x + nx - vx * o, b.y + ny - vy * o, b.z + nz - vz * o, -vx, -vy, -vz, STEP_UP + STEP_DOWN, node)
    if ok then h = hit end
  end
  if h and h.distance and h.distance < STEP_UP + STEP_DOWN then
    -- only how far down the ground is: the hit's own point may come from the
    -- colliders' tick pose, a planet-step (metres) off the point we cast from
    -- (docs/positions-and-frames.md rule 2)
    local up = STEP_UP - h.distance
    -- (no steeper than a stair: a rise of more than 0.8 m a metre is a wall
    -- or a tank's flank, walked at the same height, not climbed)
    if up <= step * 0.8 + 0.02 then nx, ny, nz = nx + vx * up, ny + vy * up, nz + vz * up end
  end
  wpos = { x = nx, y = ny, z = nz }
  -- the suit looks the way it goes, turned smoothly (presentation: the walk
  -- itself goes straight at the corner) — frames doc rule 7
  if not wface then wface = { x = fx, y = fy, z = fz }
  else
    local k = 1 - math.exp(-10 * gdt)
    local wx, wy, wz = norm3(wface.x + (fx - wface.x) * k, wface.y + (fy - wface.y) * k, wface.z + (fz - wface.z) * k)
    if wx * fx + wy * fy + wz * fz < -0.5 then wx, wy, wz = fx, fy, fz end
    wface = { x = wx, y = wy, z = wz }
  end
  place_stand(node, b, wpos, wface.x, wface.y, wface.z)
  gait(true, gdt, steer.speed)
  -- (the record follows twice a second: a switch, a goal or a look reads it)
  if now_ - rec_t > 0.5 then
    rec_t = now_
    c.patch(memberId, { x = nx, y = ny, z = nz })
    seen = { x = nx, y = ny, z = nz }
  end
  return true
end

function start(node)
  find_model(node)
end

-- Feet on the ground: a ray down the local vertical from inside the capsule
-- (a little over the record's centre: never from above a ceiling, which put
-- a body on the roof); the record moves to stand on what it finds.
local function settle(node, c, r, b)
  if settled or not raycast then settled = true return end
  settled = true
  local x, y, z = b.x + (r.x or 0), b.y + (r.y or 0), b.z + (r.z or 0)
  local ux, uy, uz = x - b.x, y - b.y, z - b.z
  local l = math.sqrt(ux * ux + uy * uy + uz * uz)
  if l < 1e-6 then return end
  ux, uy, uz = ux / l, uy / l, uz / l
  local ok, h = pcall(raycast, x + ux * 0.35, y + uy * 0.35, z + uz * 0.35, -ux, -uy, -uz, 4.0, node)
  if ok and h and h.distance and h.distance < 3.9 then
    -- (the distance only: the hit point may be a planet-step off, frames doc rule 2)
    local hh = P("half_h") + 0.02
    local up = hh - (h.distance - 0.35)
    local nx, ny, nz = (r.x or 0) + ux * up, (r.y or 0) + uy * up, (r.z or 0) + uz * up
    c.patch(memberId, { x = nx, y = ny, z = nz })
    seen = { x = nx, y = ny, z = nz }
  end
end

-- Who am I? (crew.lua spawned this node; its spawn callback runs before
-- this script does, so the binding is asked for here.)
local function bound(node)
  if memberId then return true end
  local c = ref("crew")
  if not (c and c.memberOfNode) then return false end
  local id, kind = c.memberOfNode(node)
  if not id then return false end
  memberId, doll = id, kind == "doll"
  return true
end

-- ── IDLE: out of the way, facing somewhere (graveyard2) ─────────────────────
local idle_t, door_t, face_t = 0, -10, -10
local near_t = 0                       -- s the player has stood within reach
local last_pp = nil                    -- the player's body-relative point at the last look (for their motion)
local cur_face = nil                   -- the standing facing, smoothed (presentation)
IDLE_EVERY = 0.25
-- the most open way from a body-relative capsule centre p (8 rays at the chest)
local function open_way(node, b, p, F)
  if not raycast then return nil end
  local best, bx, by, bz = -1, nil, nil, nil
  for k = 0, 7 do
    local a = k * math.pi / 4
    local dx = F.ex * math.cos(a) + F.nx * math.sin(a)
    local dy = F.ey * math.cos(a) + F.ny * math.sin(a)
    local dz = F.ez * math.cos(a) + F.nz * math.sin(a)
    local ok, h = pcall(raycast, b.x + p.x + F.ux * 0.5, b.y + p.y + F.uy * 0.5, b.z + p.z + F.uz * 0.5, dx, dy, dz, 6.0, node)
    local d = (ok and h and h.distance) or 6.0
    if d > best + 0.05 then best, bx, by, bz = d, dx, dy, dz end
  end
  return bx, by, bz
end
-- a spot to step to from p, away from (qx,qy,qz) (body-relative): → x,y,z body-relative or nil
local function step_spot(node, b, p, F, qx, qy, qz, dist)
  local hh = P("half_h") + 0.02
  local ign = ignore_list(node)
  local ax, ay, az = flat(F.ux, F.uy, F.uz, p.x - qx, p.y - qy, p.z - qz)
  if not ax then ax, ay, az = F.ex, F.ey, F.ez end
  local sx, sy, sz = F.uy * az - F.uz * ay, F.uz * ax - F.ux * az, F.ux * ay - F.uy * ax
  local best, bp = -1, nil
  for _, c in ipairs({ { 0, 1 }, { 0, -1 }, { 0.7, 0.7 }, { 0.7, -0.7 }, { 1, 0 }, { -0.5, 1 }, { -0.5, -1 } }) do
    local tx = p.x + (ax * c[1] + sx * c[2]) * dist
    local ty = p.y + (ay * c[1] + sy * c[2]) * dist
    local tz = p.z + (az * c[1] + sz * c[2]) * dist
    local fx, fy, fz = tx - F.ux * hh, ty - F.uy * hh, tz - F.uz * hh
    if spot_free(b.x + fx, b.y + fy, b.z + fz, F, ign) then
      local sc = (tx - qx) ^ 2 + (ty - qy) ^ 2 + (tz - qz) ^ 2
      if sc > best then best, bp = sc, { x = tx, y = ty, z = tz } end
    end
  end
  return bp
end
-- a door leaf within `rad` of the chest → its point (body-relative) or nil
local function door_near(node, b, p, F, rad)
  if not (overlapSphere and vec3) then return nil end
  local ok, hits = pcall(overlapSphere, vec3(b.x + p.x + F.ux * 0.3, b.y + p.y + F.uy * 0.3, b.z + p.z + F.uz * 0.3), rad,
    { ignore = ignore_list(node) })
  if not (ok and type(hits) == "table") then return nil end
  for _, h in ipairs(hits) do
    local n = h.node
    if n and type(n.name) == "string" and n.name:sub(1, 4) == "Door" and h.x then return { x = h.x - b.x, y = h.y - b.y, z = h.z - b.z } end
  end
  return nil
end
local function idle_tick(node, c, r, b, dt)
  idle_t = idle_t + dt
  if idle_t < IDLE_EVERY then return end
  local step_dt = idle_t
  idle_t = 0
  local p = { x = r.x or 0, y = r.y or 0, z = r.z or 0 }
  local F = frame_at(p.x, p.y, p.z)
  local now_ = time or 0
  -- the player walking into us: step aside (1 m, the side away from where
  -- they are going), then face them
  local px, py, pz = player_rel(r.body, b)
  if px then
    local qx, qy, qz = px - p.x, py - p.y, pz - p.z
    local qu = qx * F.ux + qy * F.uy + qz * F.uz
    local hx, hy, hz = qx - F.ux * qu, qy - F.uy * qu, qz - F.uz * qu
    local qd = sqrt(hx * hx + hy * hy + hz * hz)
    local towards = 0
    local vx, vy, vz = 0, 0, 0
    if last_pp and step_dt > 0 then
      vx, vy, vz = (px - last_pp.x) / step_dt, (py - last_pp.y) / step_dt, (pz - last_pp.z) / step_dt
      if qd > 1e-3 then towards = -(vx * hx + vy * hy + vz * hz) / qd end
    end
    last_pp = { x = px, y = py, z = pz }
    if qd < 0.95 and abs(qu) < 1.5 then near_t = near_t + step_dt else near_t = 0 end
    if qd < 0.95 and abs(qu) < 1.5 and (towards > 0.35 or near_t > 1.5) then
      -- (away from where the player will be in a moment)
      local ex, ey, ez = px + vx * 0.8, py + vy * 0.8, pz + vz * 0.8
      local s = step_spot(node, b, p, F, ex, ey, ez, 1.05)
      if s then
        steerSelf(r.body, s.x, s.y, s.z, { auto = true, faceTo = "player", speed = 1.6, arrive = 0.2 })
        near_t = 0
        return
      end
    end
  else
    last_pp, near_t = nil, 0
  end
  -- out of a doorway (a leaf within 0.8 m): 1.3 m away from it
  if now_ - door_t > 4.0 then
    door_t = now_
    local dp = door_near(node, b, p, F, 0.8)
    if dp then
      local s = step_spot(node, b, p, F, dp.x, dp.y, dp.z, 1.3)
      if s then steerSelf(r.body, s.x, s.y, s.z, { auto = true, speed = 1.2, arrive = 0.2 }); return end
    end
  end
  -- no facing: the most open way (never a wall a hand's width off)
  if not (type(r.face) == "table" and r.face.x) and now_ - face_t > 3.0 then
    face_t = now_
    local fx, fy, fz = open_way(node, b, p, F)
    if fx then c.patch(memberId, { face = { x = fx, y = fy, z = fz } }) end
  end
end

-- ── POSES (scenario `pose`): lying on a bunk, sitting on its edge ──────────
local function pose_place(node, r, b)
  local ps = r.pose
  local x, y, z = ps.x or r.x or 0, ps.y or r.y or 0, ps.z or r.z or 0
  local ux, uy, uz = norm3(x, y, z)
  local f = type(ps.f) == "table" and ps.f or nil
  local fx, fy, fz = nil, nil, nil
  if f then fx, fy, fz = flat(ux, uy, uz, f.x or 0, f.y or 0, f.z or 0) end
  if not fx then local F = frame_at(x, y, z); fx, fy, fz = F.ex, F.ey, F.ez end
  vel.x, vel.y, vel.z = 0, 0, 0
  node.vx, node.vy, node.vz = 0, 0, 0
  if ps.kind == "lie" then
    -- on the back, the head the pose's way: the suit's front (the node's +Z) to the ceiling
    local lift = ps.lift or P("lie_lift")
    node.x, node.y, node.z = b.x + x + ux * lift, b.y + y + uy * lift, b.z + z + uz * lift
    node:setUp(vec3(fx, fy, fz), vec3(-ux, -uy, -uz))
  else
    local lift = ps.lift or P("sit_lift")
    node.x, node.y, node.z = b.x + x + ux * lift, b.y + y + uy * lift, b.z + z + uz * lift
    node:setUp(vec3(ux, uy, uz), vec3(-fx, -fy, -fz))
  end
  gait(false)
end

local last_rec = nil   -- the record as the last tick read it (lateUpdate's presentation reads it: no second save read a frame)
function fixedUpdate(node, dt)
  self_node = node
  if retired then return end
  if not bound(node) then return end
  if doll then return end
  local c = ref("crew")
  local r = c and c.get and c.get(memberId)
  last_rec = r
  if not (r and r.status == "afoot") then return end
  -- beside a craft in space: ride its part frame
  local an = r.anchor
  if type(an) == "table" and an.vid then
    for _, v in ipairs(findScripts("vessel_controller")) do
      if v.node and v.node.valid ~= false and v.node.id == an.vid and v.partPointNow then
        local x, y, z, vx, vy, vz = v.partPointNow(an.uid, an.x, an.y, an.z)
        if x then
          node.x, node.y, node.z = x, y, z
          node.vx, node.vy, node.vz = vx, vy, vz
          vel.x, vel.y, vel.z = vx, vy, vz
          return
        end
      end
    end
  end
  local b = r.body and space.body(r.body)
  if not b then return end
  -- moved by someone else (crew.setDown, a scenario post, a restage): stand
  -- on what is there again
  if seen and not steer and ((r.x or 0) - seen.x) ^ 2 + ((r.y or 0) - seen.y) ^ 2 + ((r.z or 0) - seen.z) ^ 2 > 0.0025 then
    settled = false
  end
  if type(r.pose) == "table" and not r.downed and not steer then
    -- (the record is where they get up: settled onto the floor too)
    settle(node, c, r, b)
    r = c.get(memberId)
    seen = { x = r.x or 0, y = r.y or 0, z = r.z or 0 }
    return pose_place(node, r, b)
  end
  settle(node, c, r, b)
  r = c.get(memberId)
  seen = seen or { x = r.x or 0, y = r.y or 0, z = r.z or 0 }
  -- walking (a scenario's `walk`, a step aside): the walk places the node this tick
  if steer and not r.downed then
    if type(r.pose) == "table" then c.patch(memberId, { pose = false }); r = c.get(memberId) end
    if steer_tick(node, c, r, dt) then return end
    r = c.get(memberId)
  end
  local x, y, z = b.x + (r.x or 0), b.y + (r.y or 0), b.z + (r.z or 0)
  -- at rest on the ground: velocities are in the planet's rails frame (the
  -- engine carries everything near it), so standing still is 0
  vel.x, vel.y, vel.z = 0, 0, 0
  node.x, node.y, node.z = x, y, z
  node.vx, node.vy, node.vz = 0, 0, 0
  local ux, uy, uz = x - b.x, y - b.y, z - b.z
  local l = math.sqrt(ux * ux + uy * uy + uz * uz)
  if l > 1e-6 and r.downed then
    -- DOWN (crew.lua): lying on their back where they fell, the capsule laid
    -- along the ground, the head the way they faced
    ux, uy, uz = ux / l, uy / l, uz / l
    local f = type(r.face) == "table" and r.face or nil
    local fx, fy, fz = 1, 0, 0
    if f then fx, fy, fz = f.x, f.y, f.z end
    local d = fx * ux + fy * uy + fz * uz
    fx, fy, fz = fx - ux * d, fy - uy * d, fz - uz * d
    local fl = math.sqrt(fx * fx + fy * fy + fz * fz)
    if fl < 1e-3 then
      fx, fy, fz = uy, -ux, 0
      if math.abs(uz) > 0.9 then fx, fy, fz = 0, uz, -uy end
      fl = math.sqrt(fx * fx + fy * fy + fz * fz)
    end
    fx, fy, fz = fx / fl, fy / fl, fz / fl
    -- On the back, rolled a little onto one side: the suit's front (the
    -- model faces the node's +Z) turned to the sky. Forward = the planet's up
    -- laid them face-down, which reads as dead. The side follows the member,
    -- so two downed side by side don't mirror each other.
    local sx, sy, sz = fy * uz - fz * uy, fz * ux - fx * uz, fx * uy - fy * ux
    local roll = ((tonumber(memberId) or 0) % 2 == 0 and 1 or -1) * P("down_roll")
    local c, s = math.cos(roll), math.sin(roll)
    local drop = P("half_h") - P("down_lift")
    node.x, node.y, node.z = x - ux * drop, y - uy * drop, z - uz * drop
    node:setUp(vec3(fx, fy, fz), vec3(-ux * c + sx * s, -uy * c + sy * s, -uz * c + sz * s))
    return
  end
  if l > 1e-6 then
    ux, uy, uz = ux / l, uy / l, uz / l
    local f = r.face
    if type(f) == "table" and f.x then
      -- the suit looks along `face`: the node's -Z turned against it; a
      -- new facing is turned to smoothly (a turn beat, a step aside), a
      -- small one at once (frames doc rule 7: presentation only)
      local tx, ty, tz = flat(ux, uy, uz, f.x, f.y, f.z)
      if tx then
        if not cur_face then cur_face = { x = tx, y = ty, z = tz }
        else
          local k = 1 - math.exp(-6 * dt)
          local cx, cy, cz = norm3(cur_face.x + (tx - cur_face.x) * k, cur_face.y + (ty - cur_face.y) * k, cur_face.z + (tz - cur_face.z) * k)
          if cx * tx + cy * ty + cz * tz < -0.95 then cx, cy, cz = flat(ux, uy, uz, cur_face.x + 0.2 * (uy * tz - uz * ty), cur_face.y + 0.2 * (uz * tx - ux * tz), cur_face.z + 0.2 * (ux * ty - uy * tx)) end
          cur_face = { x = cx or tx, y = cy or ty, z = cz or tz }
        end
        node:setUp(vec3(ux, uy, uz), vec3(-cur_face.x, -cur_face.y, -cur_face.z))
      else
        node:setUp(vec3(ux, uy, uz))
      end
    else
      node:setUp(vec3(ux, uy, uz))
    end
  end
  idle_tick(node, c, r, b, dt)
end

-- the Pose layer (tools/gen_astronaut_anims.py POSE_CLIPS): sitting, lying,
-- a gesture (the record's `gesture` = { clip, t1 }: a scenario's beat), its
-- weight eased in and out (frames doc rule 7)
POSE_CLIP = { sit = "sit_idle", lie = "lie_rest" }
local pose_clip, pose_w = nil, 0
local function pose_anim(r, dt)
  if not anim then return end
  local want = nil
  if not steer and r then
    if type(r.pose) == "table" then want = POSE_CLIP[r.pose.kind]
    elseif type(r.gesture) == "table" and r.gesture.clip and (not r.gesture.t1 or (time or 0) < r.gesture.t1) then want = r.gesture.clip end
  end
  if want and want ~= pose_clip then
    pcall(anim.crossfade, anim, want, pose_clip and 0.35 or 0.0, "Pose")
    pose_clip = want
  end
  local target = want and 1 or 0
  local w = pose_w + (target - pose_w) * (1 - math.exp(-(want and 5 or 7) * dt))
  if target == 0 and w < 0.01 then w = 0 end
  if math.abs(w - pose_w) > 1e-3 or (w == 0 and pose_w ~= 0) then
    pose_w = w
    pcall(anim.setLayerWeight, anim, "Pose", w)
  end
  if w == 0 then pose_clip = nil end
end

-- (graveyard2 fix) has the body finished turning to its record's facing?
-- (a portrait taken while it eases round caught the back of the head)
function facingSettled()
  if steer or plan then return false end
  local r = last_rec
  local f = r and r.face
  if not (type(f) == "table" and f.x) then return true end
  if not cur_face then return false end
  local l = math.sqrt(f.x * f.x + f.y * f.y + f.z * f.z)
  if l < 1e-6 then return true end
  return (cur_face.x * f.x + cur_face.y * f.y + cur_face.z * f.z) / l > 0.995
end

-- the head to the player close by (no scenario look on): weight eased
local hl_w = 0
local function head_to_player(node, dt, b)
  if not anim then return end
  local pw = ref("planet_walker")
  local C = ref("crew")
  local a = astro()
  local want = 0
  local hx, hy, hz
  if b and a and a.valid ~= false and not (pw and pw.onFoot == false) and not (C and C.activeId and C.activeId() == memberId) then
    hx, hy, hz = a.x, a.y, a.z
    local dx, dy, dz = hx - node.x, hy - node.y, hz - node.z
    local d2 = dx * dx + dy * dy + dz * dz
    if d2 < 3.5 * 3.5 then
      -- (in front: the suit looks along the node's +Z)
      local fw = node.worldForward and node:worldForward()
      local front = fw and -(fw.x * dx + fw.y * dy + fw.z * dz) or 1
      if front > -0.2 * math.sqrt(d2) then want = 1 end
    end
  end
  hl_w = hl_w + (want - hl_w) * (1 - math.exp(-4 * dt))
  if hl_w > 0.02 and hx then
    -- (the player's head: drawn poses both, this frame)
    local ux, uy, uz = norm3(hx - b.x, hy - b.y, hz - b.z)
    pcall(anim.lookAt, anim, { "Head" }, vec3(hx + ux * 0.65, hy + uy * 0.65, hz + uz * 0.65), { limit = 60, weight = hl_w * 0.85 })
  end
end

function lateUpdate(node, dt)
  if retired then return end
  if not bound(node) then return end
  if not doll then
    if not anim then find_model(node) end
    local c = ref("crew")
    local r = last_rec or (c and c.get and memberId and c.get(memberId))
    local b = r and r.body and space.body(r.body)
    pose_anim(r, dt or 0)
    -- a scenario's `look`: the head to this frame's point (asked now, never kept)
    if look_fn and anim then
      local ok, x, y, z, w = pcall(look_fn)
      if ok and x then pcall(anim.lookAt, anim, { "Head" }, vec3(x, y, z), { limit = 60, weight = w or 1 }) end
    elseif not steer and not (r and type(r.pose) == "table") then
      head_to_player(node, dt or 0, b)
    end
    -- sitting (pose): feet forward and down, hands on the knees, as a seated doll
    if anim and b and r and type(r.pose) == "table" and r.pose.kind == "sit" and not steer then
      local ux, uy, uz, ul = norm3(node.x - b.x, node.y - b.y, node.z - b.z)
      local fw = node.worldForward and node:worldForward()
      if fw and ul > 0 then
        local p = { x = node.x, y = node.y, z = node.z, ux = ux, uy = uy, uz = uz, fx = -fw.x, fy = -fw.y, fz = -fw.z }
        local rx, ry, rz = p.fy * p.uz - p.fz * p.uy, p.fz * p.ux - p.fx * p.uz, p.fx * p.uy - p.fy * p.ux
        local function at(o, u, s)
          return vec3(p.x + p.fx * o + p.ux * u + rx * s, p.y + p.fy * o + p.uy * u + ry * s, p.z + p.fz * o + p.uz * u + rz * s)
        end
        for _, side in ipairs({ { "Left", -1 }, { "Right", 1 } }) do
          local nm, sg = side[1], side[2]
          pcall(anim.reach, anim, "Foot." .. nm, at(P("sit_foot_out"), -P("sit_foot_down"), sg * P("foot_side")), { pole = at(1.2, 0.0, sg * P("foot_side")) })
          pcall(anim.reach, anim, "Hand." .. nm, at(P("hand_out") + 0.1, -0.12, sg * P("hand_side")), { pole = at(-0.3, -0.1, sg * 0.6) })
        end
      end
    end
    return
  end
  local c = ref("crew")
  local p = c and c.dollPose and c.dollPose(memberId)
  local m = find_model(node)
  if not p then
    if node.visible then node.visible = false end
    return
  end
  if p.open then
    -- command_seat.lua sits them in the seat, in view
    if not node.visible then node.visible = true end
    return
  end
  if node.visible ~= p.visible then node.visible = p.visible end
  if m and m.visible ~= p.visible then m.visible = p.visible end
  node.x, node.y, node.z = p.x, p.y, p.z
  node:setUp(vec3(p.ux, p.uy, p.uz), vec3(p.fx, p.fy, p.fz))
  if m then m.yaw, m.pitch, m.roll = P("model_yaw"), 0, 0 end
  if not (p.visible and anim) then return end
  -- seated: feet forward and down, hands on the knees
  local rx, ry, rz = p.fy * p.uz - p.fz * p.uy, p.fz * p.ux - p.fx * p.uz, p.fx * p.uy - p.fy * p.ux
  local function at(o, u, s)
    return vec3(p.x + p.fx * o + p.ux * u + rx * s, p.y + p.fy * o + p.uy * u + ry * s, p.z + p.fz * o + p.uz * u + rz * s)
  end
  for _, side in ipairs({ { "Left", -1 }, { "Right", 1 } }) do
    local nm, sg = side[1], side[2]
    anim:reach("Foot." .. nm, at(P("foot_out"), -P("foot_down"), sg * P("foot_side")), { pole = at(1.2, 0.0, sg * P("foot_side")) })
    anim:reach("Hand." .. nm, at(P("hand_out"), -0.15, sg * P("hand_side")), { pole = at(-0.3, -0.1, sg * 0.6) })
  end
end
