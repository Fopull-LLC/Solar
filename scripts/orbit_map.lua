-- ORBIT MAP — the 3D map screen: every body's conic, your own trajectory, and
-- the maneuver node you plan on it.
--
-- `M` opens it, from the pod or on foot. Navigation is BLENDER-style, not
-- KSP's: the mouse does nothing until you hold RIGHT-CLICK, and then dragging
-- orbits the selection. CTRL+RIGHT-drag pans the view off the focus, scroll or
-- ↑/↓ zooms, TAB cycles focus (you first, then every body). `1` `2` `3` toggle
-- orbit lines, SOI rings and markers.
--
-- The engine's line layer draws the conics, so they are occluded by the bodies
-- themselves rather than painted over them.
--
--   FLYING FROM THE MAP. A piloted craft keeps full control while the map is
--   open — throttle, stick, SAS and staging all stay live, because watching the
--   trajectory bend as you burn is the whole reason to fly on instruments.
--
--   PLANNING A BURN. `N` enters PLAN mode, which is a mode precisely because
--   the flight stick and the burn tuner want the same six keys. In plan mode
--   W/S/A/D/Q/E move ΔV instead of the craft, ←/→ slide the node along the
--   orbit, and the vessel's stick is frozen (vessel_controller reads
--   `planning`). Left-click the orbit line to place the node, X zeroes it, N
--   leaves. The HUD says which mode you are in, every frame, because a mode
--   you cannot see is a mode you will be surprised by.
--
-- This used to live inside the scout ship's controller, which meant the map
-- only existed because a debug vehicle did, and a built vessel had to borrow
-- it. The scout is gone; the map is its own screen now, and planning works for
-- the craft you actually fly — which it never did before.
--
-- Cross-script:  local map = findScript("orbit_map")
--                map.map_view   map.planning   map.toggle()   map.isOpen()

defaults = {
  --@header Planning
  -- How often the patched-conic walk is recomputed, in seconds. The walk is
  -- hundreds of two-body evaluations across SOI changes; the result is cached
  -- and redrawn every frame (draw.line is immediate mode).
  --@range 0.05 1.0 --@units s
  recompute = 0.15,
  -- Points per trajectory walk. More is smoother and costs linearly.
  --@range 40 400
  segments = 140,
}

-- Published: planet_camera stands down while the map owns the screen, and
-- vessel_controller freezes its stick while `planning` is true.
planning = false

local astronaut

-- "860 m", "1.4 km", "2,300 km" — a distance a person reads.
local function fmt_dist(m)
  m = math.abs(m or 0)
  if m < 1000 then return string.format("%.0f m", m) end
  if m < 100000 then return string.format("%.1f km", m / 1000) end
  return string.format("%.0f km", m / 1000)
end

local function norm(x, y, z)
  local l = math.sqrt(x * x + y * y + z * z)
  if l < 1e-6 then return 0, 0, 0 end
  return x / l, y / l, z / l
end

local function cross(ax, ay, az, bx, by, bz)
  return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
end

-- The map paints into the same HUD block the flight readout uses — one text
-- panel, whoever owns the screen. `nil` hides the backing frame with it.
local hud, hud_panel
-- Orbits and trajectories hide behind the planets in front of them; markers
-- (Pe/Ap, encounters) stay on top so they can always be found.
local function depth(on)
  if draw.depthTest then draw.depthTest(on) end
end

local function set_hud(_, text)
  if not hud then hud = find("Ship HUD Text") end
  if not hud_panel then hud_panel = find("HUD Panel") end
  local panel = hud_panel or hud
  if panel then
    local el = panel:getcomponent("UiElement")
    if el then el.visible = text ~= nil end
  end
  if hud and text then hud.text = text end
end

-- The instrument cluster stands down while the map owns the screen; closing
-- hands it back to whatever craft is being flown (which repaints its own HUD).
local instruments
local function set_instruments(on)
  if not instruments then
    instruments = {}
    for _, nm in ipairs({ "Navball", "Speed Tape", "Alt Tape", "Speed Readout",
                          "Alt Readout", "Heading Readout" }) do
      local n = find(nm)
      if n then instruments[#instruments + 1] = n end
    end
  end
  for _, inst in ipairs(instruments) do
    local el = inst:getcomponent("UiElement")
    if el then el.visible = on and 1 or 0 end
  end
end

-- One-shot map diagnostics: if the subject hand-off ever breaks in the wild,
-- the Console says WHICH link failed instead of the map silently going empty.
local map_diag = false

-- THE craft being flown, or nil. Every instance is scanned rather than taking
-- findScript's first: once several craft are alive — landed stages, parked
-- ships, satellites — "first in scene order" is arbitrary, and the map has to
-- follow the one with a pilot in it. Cached per frame by the caller; the scan
-- only runs while the map is open.
local function subject_vessel()
  for _, s in ipairs(findScripts("vessel_controller")) do
    if s.piloting then
      if s.node and s.node.valid then return s end
      if not map_diag then
        map_diag = true
        print("map: a piloted vessel has an invalid node — showing the system view")
      end
      return nil
    end
  end
  return nil
end

map_view = false -- published: planet_camera stands down while this is true
local map_focus, map_zoom = 1, nil -- focus 1 = THE SHIP, 2.. = bodies
local map_hud_t = -10.0
-- The SOI ring that is on but bigger than the view this frame (the legend says so).
local soi_off = nil
local map_yaw2, map_pitch2 = 0.6, 0.45
local map_offx, map_offy, map_offz = 0.0, 0.0, 0.0 -- CTRL-drag pan offset
local map_show = { orbits = true, soi = true, markers = true, links = true }
-- The map can be opened ON a craft other than the one being flown (the
-- Tracking Station's MAP button): focus slot 1 follows this node while it lives.
local focus_override = nil
-- far_bodies (the far-world impostors), told which world the map frames
-- (looked up once; false when the scene has none).
local fb_ref = nil
local cam_node
-- THE MAP'S LENS. The game camera is a wide 66° (vertical) — right for walking,
-- wrong for a map: a sphere near the edge of a wide rectilinear view is drawn
-- stretched along the radius, and the star came out as an egg. While the map is
-- open the camera narrows to this, and every auto-fit distance is scaled by
-- FOV_K so the framing stays what it was. The old lens is put back on close.
local MAP_FOV = 0.70
local TANH = math.tan(MAP_FOV * 0.5)
local FOV_K = math.tan(1.1519173 * 0.5) / TANH
local saved_fov = nil
local function map_lens(on)
  cam_node = cam_node or find("Camera 1")
  local c = cam_node and cam_node.getcomponent and cam_node:getcomponent("Camera")
  if not c then return end
  if on then
    if not saved_fov then saved_fov = c.fovY end
    c.fovY = MAP_FOV
  elseif saved_fov then
    c.fovY = saved_fov
    saved_fov = nil
  end
end
-- Zoom eases toward where the wheel asked, in log space: a wheel tick is a
-- 12% step that takes ~0.2 s to arrive, not a jump. Every jump landed the
-- camera in a new terrain LOD state at once, which is most of what "laggy
-- zoom" felt like.
local zoom_target = nil
local ZOOM_MAX = 3.0e6
-- …times the save's galaxy sector scale (system_generator SCALES): a bigger
-- universe puts the neighbour stars further out, and the map must reach them.
local zoom_gen = nil
local function zoom_max()
  if not (zoom_gen and zoom_gen.valid) then zoom_gen = findScript("system_generator") end
  local sc = zoom_gen and zoom_gen.scale
  return ZOOM_MAX * ((sc and sc.sector) or 1.0)
end
-- Parents re-inferred when the body list changes, or once a second (the SOI
-- tree only changes when the galaxy streams a system in or out).
local map_pidx, pidx_n, pidx_t = {}, -1, -10.0
-- The craft being flown, re-scanned twice a second rather than every frame.
local subj_cache, subj_t = nil, -10.0

-- Maneuver node (KSP planning): a single planned burn at `t` seconds ahead of
-- now, split into prograde / normal / radial ΔV. Nil until you press N in the
-- map. Editing it re-projects the resulting orbit and re-walks the patched
-- conic for SOI encounters, all game-side on top of `space.propagate`.
local mnv = nil -- { t, pro, nor, rad }
-- The patched-conic walk is heavy (hundreds of two-body evals across SOI
-- changes), so it's recomputed at ~8 Hz and the resulting world polyline +
-- encounter markers are cached here and redrawn every frame (draw.line is
-- immediate mode). `traj_now` = the path you're on; `traj_mnv` = the post-burn
-- path (nil unless a node exists).
local traj_t = -10.0
local traj_now, traj_mnv = nil, nil

-- Orbital-plane basis + conic from a relative state vector: returns
-- has_orbit, p, ecc, ê1 (periapsis dir), ê2 (in-plane, motion side).
local function orbit_basis(rx, ry, rz, vx, vy, vz, mu)
  local rlen = math.sqrt(rx * rx + ry * ry + rz * rz)
  local hx, hy, hz = cross(rx, ry, rz, vx, vy, vz)
  local h2 = hx * hx + hy * hy + hz * hz
  if h2 < 1e-3 or rlen < 1e-3 then
    return false, 0, 0, 1, 0, 0, 0, 0, 1
  end
  local p = h2 / mu
  local cx2, cy2, cz2 = cross(vx, vy, vz, hx, hy, hz)
  local evx = cx2 / mu - rx / rlen
  local evy = cy2 / mu - ry / rlen
  local evz = cz2 / mu - rz / rlen
  local ecc = math.sqrt(evx * evx + evy * evy + evz * evz)
  local e1x, e1y, e1z
  if ecc > 1e-5 then
    e1x, e1y, e1z = evx / ecc, evy / ecc, evz / ecc
  else
    e1x, e1y, e1z = rx / rlen, ry / rlen, rz / rlen
  end
  local hl = math.sqrt(h2)
  local e2x, e2y, e2z = cross(hx / hl, hy / hl, hz / hl, e1x, e1y, e1z)
  return true, p, ecc, e1x, e1y, e1z, e2x, e2y, e2z
end

-- Draw r = p/(1+e·cosθ) around a world center in the ê1/ê2 plane, in one
-- engine call. Ellipses close; a hyperbola stops at 50·p, where the old
-- per-segment loop gave up too.
local function draw_conic(cx, cy, cz, e1x, e1y, e1z, e2x, e2y, e2z, p, ecc, r, g, b, a, segs)
  draw.conic(vec3(cx, cy, cz), vec3(e1x, e1y, e1z), vec3(e2x, e2y, e2z),
    p, ecc, segs or 128, r, g, b, a, p * 50)
end

-- ── EVERY CRAFT'S TRAJECTORY ────────────────────────────────────────────────
-- The playtest: "show trajectory of your crafts when looking at them on the
-- map". Every craft gets the conic it is on about its dominant body, worked
-- out from its own state (position and velocity relative to that body), and
-- drawn as what it means for that craft:
--
--   landed       nothing (the map's marker says where it is)
--   orbit        the whole ellipse, with its periapsis and apoapsis marked
--   suborbital   the arc from the craft forward to where it meets the
--                ground, with an impact mark (and its apoapsis, if still ahead)
--   escape       the open arc out to the edge of the body's sphere of
--                influence, periapsis marked if still ahead
--
-- One two-body conic per craft — cheap enough for every craft every frame.
-- The piloted craft's patched-conic walk (SOI changes, encounters, the
-- maneuver node) is drawn on top of its own, as before.
--
-- Plain maths, global (TRAJ), so tests/smoke_trajectory.lua can hold it.
TRAJ = { HOP_MIN = 50.0 }

-- Orbital elements in the body's frame: has, p, e, ê1 (towards periapsis),
-- ê2 (in-plane, the way the craft moves). The same as `orbit_basis`.
function TRAJ.basis(rx, ry, rz, vx, vy, vz, mu)
  return orbit_basis(rx, ry, rz, vx, vy, vz, mu)
end

-- r(ν) on the conic.
function TRAJ.radius(p, e, nu) return p / (1 + e * math.cos(nu)) end

-- The positive true anomaly where the conic is `R` from the focus, or nil
-- when it never is (a circle at another radius, an ellipse entirely inside
-- or outside R).
function TRAJ.anomalyAt(p, e, R)
  if e < 1e-9 or R <= 0 then return nil end
  local c = (p / R - 1) / e
  if c > 1 or c < -1 then return nil end
  return math.acos(c)
end

-- What the craft at relative state (r, v) is doing about a body of `mu`,
-- radius `R`, sphere of influence `soi` (≤ 0: unbounded). Returns
--   { kind = "landed"|"orbit"|"suborbital"|"escape"|"falling",
--     p, e, e1 = {x,y,z}, e2 = {x,y,z}, nu0,
--     closed = true            (orbit: the whole ellipse)
--     a0, a1                   (an arc, true anomalies, a1 > a0, may pass π)
--     pe, ap, impact           (true anomalies of the marks to draw, or nil)
--     peR, apR                 (their distances from the centre) }
function TRAJ.track(rx, ry, rz, vx, vy, vz, mu, R, soi, grounded)
  if grounded then return { kind = "landed" } end
  local r = math.sqrt(rx * rx + ry * ry + rz * rz)
  if r < 1e-6 or not mu or mu <= 0 then return { kind = "landed" } end
  if R and r < R * 0.999 then return { kind = "landed" } end
  local has, p, e, e1x, e1y, e1z, e2x, e2y, e2z = orbit_basis(rx, ry, rz, vx, vy, vz, mu)
  if not has then
    -- No angular momentum: straight up or straight down. Falling (or about
    -- to) is a line to the ground below.
    return { kind = "falling", r = r }
  end
  local t = { p = p, e = e, e1 = { e1x, e1y, e1z }, e2 = { e2x, e2y, e2z } }
  t.nu0 = math.atan2(rx * e2x + ry * e2y + rz * e2z, rx * e1x + ry * e1y + rz * e1z)
  local lim = (soi and soi > 0) and soi or p * 50
  local rpe = p / (1 + e)
  local rap = e < 1 and p / (1 - e) or nil
  t.peR, t.apR = rpe, rap
  local nlim = TRAJ.anomalyAt(p, e, lim)          -- where the path leaves the SOI
  if rpe > (R or 0) then
    if rap and rap < lim then
      t.kind, t.closed, t.pe, t.ap = "orbit", true, 0.0, math.pi
      return t
    end
    -- Leaving: from here out to the edge of the sphere of influence.
    t.kind = "escape"
    t.a0, t.a1 = t.nu0, nlim or t.nu0
    if t.nu0 < 1e-6 then t.pe = 0.0 end
    return t
  end
  -- Periapsis under the ground: the path meets the surface at ±nc.
  local nc = TRAJ.anomalyAt(p, e, R)
  if not nc then return { kind = "landed" } end
  if t.nu0 >= nc then
    if e >= 1 then
      t.kind, t.a0, t.a1 = "escape", t.nu0, nlim or t.nu0   -- outbound on a hyperbola
      return t
    end
    t.a0, t.a1 = t.nu0, 2 * math.pi - nc                    -- up over the apoapsis and down
  elseif t.nu0 <= -nc then
    t.a0, t.a1 = t.nu0, -nc                                 -- coming down
  else
    return { kind = "landed" }                              -- below the surface
  end
  -- An arc that leaves the sphere of influence first is an escape, not a fall.
  if nlim and t.a0 < nlim and t.a1 > nlim then
    t.kind, t.a1 = "escape", nlim
    return t
  end
  t.kind, t.impact = "suborbital", t.a1
  if e < 1 and t.a0 < math.pi and t.a1 > math.pi then t.ap = math.pi end
  -- A hop that never gets HOP_MIN off the ground (a rover over a bump, a
  -- craft settling on its legs) is not worth an arc and an impact mark on a
  -- map drawn in kilometres.
  local top = t.ap and rap or r
  if top - R < TRAJ.HOP_MIN then return { kind = "landed" } end
  return t
end

-- The point at true anomaly ν, relative to the body's centre.
function TRAJ.point(t, nu)
  local r = TRAJ.radius(t.p, t.e, nu)
  local c, s = math.cos(nu), math.sin(nu)
  return (t.e1[1] * c + t.e2[1] * s) * r, (t.e1[2] * c + t.e2[2] * s) * r, (t.e1[3] * c + t.e2[3] * s) * r
end

-- An arc as a flat point list in WORLD space about a body centre (cx,cy,cz).
function TRAJ.arc(t, cx, cy, cz, segs)
  local out = {}
  local n = math.max(2, segs or 48)
  for i = 0, n do
    local nu = t.a0 + (t.a1 - t.a0) * i / n
    local x, y, z = TRAJ.point(t, nu)
    out[#out + 1], out[#out + 2], out[#out + 3] = cx + x, cy + y, cz + z
  end
  return out
end

local function draw_cross(x, y, z, s, r, g, b)
  depth(false)
  draw.line(x - s, y, z, x + s, y, z, r, g, b, 1)
  draw.line(x, y - s, z, x, y + s, z, r, g, b, 1)
  draw.line(x, y, z - s, x, y, z + s, r, g, b, 1)
  depth(true)
end

-- Parent INDEX of every body: the OTHER body with the smallest SOI still
-- containing it (patched conics — the same rule the engine uses for
-- dominance), so the walkers can climb/descend the hierarchy by index.
local function parent_indices(bodies)
  local pidx = {}
  for i, b in ipairs(bodies) do
    local best, bs = nil, nil
    for j, o in ipairs(bodies) do
      if j ~= i then
        local dx, dy, dz = b.x - o.x, b.y - o.y, b.z - o.z
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        local soi = o.soi < 0 and math.huge or o.soi
        if d <= soi and (bs == nil or soi < bs) then best, bs = j, soi end
      end
    end
    pidx[i] = best
  end
  return pidx
end

-- World position AND velocity of body `i` at `tt` seconds from now — walk the
-- parent chain, propagating each link about its parent's µ and summing (a moon
-- rides its planet rides the star). The root is fixed. Exact, drift-free.
local function body_state_at(bodies, pidx, i, tt)
  local pi = pidx[i]
  local b = bodies[i]
  if not pi then return b.x, b.y, b.z, 0, 0, 0 end
  local px, py, pz, pvx, pvy, pvz = body_state_at(bodies, pidx, pi, tt)
  local par = bodies[pi]
  local rx, ry, rz, rvx, rvy, rvz = space.propagate(
    b.x - par.x, b.y - par.y, b.z - par.z,
    b.vx - par.vx, b.vy - par.vy, b.vz - par.vz, par.mu, tt)
  return px + rx, py + ry, pz + rz, pvx + rvx, pvy + rvy, pvz + rvz
end

-- A body's own orbital period around its parent (vis-viva), or nil if unbound
-- or a root. Sets the transfer timescale for an escape burn's walk.
local function body_period(bodies, pidx, i)
  local pi = pidx[i]
  if not pi then return nil end
  local b, par = bodies[i], bodies[pi]
  local rx, ry, rz = b.x - par.x, b.y - par.y, b.z - par.z
  local vx, vy, vz = b.vx - par.vx, b.vy - par.vy, b.vz - par.vz
  local rlen = math.sqrt(rx * rx + ry * ry + rz * rz)
  local v2 = vx * vx + vy * vy + vz * vz
  local a = 1.0 / (2.0 / rlen - v2 / par.mu)
  if a <= 0 then return nil end
  return 2 * math.pi * math.sqrt(a * a * a / par.mu)
end

-- The world state of the bodies at `tt` seconds from now, worked out LAZILY:
-- indexing s[i] propagates body i once about its parent's (also lazy) state
-- and keeps it. A walk step only ever reads the body it is in, that body's
-- chain and its children, so a galaxy of a hundred streamed-in bodies costs a
-- handful of Kepler solves per step instead of the whole galaxy re-walked.
local function all_body_states(bodies, pidx, tt)
  return setmetatable({}, { __index = function(s, i)
    local b = bodies[i]
    if not b then return nil end
    local pi, st = pidx[i], nil
    if not pi then
      st = { x = b.x, y = b.y, z = b.z, vx = 0, vy = 0, vz = 0 }
    else
      local ps, par = s[pi], bodies[pi]
      local rx, ry, rz, rvx, rvy, rvz = space.propagate(
        b.x - par.x, b.y - par.y, b.z - par.z,
        b.vx - par.vx, b.vy - par.vy, b.vz - par.vz, par.mu, tt)
      st = { x = ps.x + rx, y = ps.y + ry, z = ps.z + rz,
             vx = ps.vx + rvx, vy = ps.vy + rvy, vz = ps.vz + rvz }
    end
    rawset(s, i, st)
    return st
  end })
end

-- Walk a ship's future path as a real patched conic: advance the state within
-- the current dominant body's frame, and when it leaves that SOI drop to the
-- parent, or when it falls inside a child's SOI capture that child. Returns the
-- world-space polyline and the SOI-change / impact events found along it. This
-- is what turns "pretty orbit lines" into "you encounter Draol in 3m12s".
local function walk_trajectory(bodies, pidx, wx, wy, wz, wvx, wvy, wvz, cur, t0, span, segs)
  -- Points are stored RELATIVE TO their attractor + the attractor index, NOT in
  -- absolute world space. Drawn at attractor.LIVE + rel, so the whole path lives
  -- in the dominant body's REST FRAME (the KSP map): your orbit is a static
  -- ellipse around the planet's CURRENT position, not smeared along the planet's
  -- own orbit into wherever it will be in 180 s. That smear is what flung the
  -- node way out across the system.
  local rpts, anch, enc = {}, {}, {}
  local step = span / segs
  local tt = t0
  local start_states = all_body_states(bodies, pidx, tt)
  local s0 = start_states[cur]
  rpts[1], rpts[2], rpts[3] = wx - s0.x, wy - s0.y, wz - s0.z
  anch[1] = cur
  for _ = 1, segs do
    -- Ship relative to the current attractor at the START of this step.
    local cs = start_states[cur]
    local nrx, nry, nrz, nrvx, nrvy, nrvz = space.propagate(
      wx - cs.x, wy - cs.y, wz - cs.z, wvx - cs.vx, wvy - cs.vy, wvz - cs.vz,
      bodies[cur].mu, step)
    tt = tt + step
    -- One snapshot at the step END, reused for the recompose + every SOI test.
    local es = all_body_states(bodies, pidx, tt)
    local ec = es[cur]
    wx, wy, wz = ec.x + nrx, ec.y + nry, ec.z + nrz
    wvx, wvy, wvz = ec.vx + nrvx, ec.vy + nrvy, ec.vz + nrvz
    -- store REL to the current attractor (nr* IS wx-ec.x) + which body it is
    rpts[#rpts + 1] = nrx
    rpts[#rpts + 1] = nry
    rpts[#rpts + 1] = nrz
    anch[#anch + 1] = cur
    -- Capture a child SOI we've fallen into (deeper body wins).
    for j, o in ipairs(bodies) do
      if pidx[j] == cur and o.soi > 0 then
        local d = es[j]
        local dx, dy, dz = wx - d.x, wy - d.y, wz - d.z
        if dx * dx + dy * dy + dz * dz < o.soi * o.soi then
          enc[#enc + 1] = { t = tt, name = o.name, anchor = j, rx = dx, ry = dy, rz = dz, kind = "enter" }
          cur = j
          break
        end
      end
    end
    -- Or climb out of the current SOI into the parent's frame.
    local pc = pidx[cur]
    if pc and bodies[cur].soi > 0 then
      local d = es[cur]
      local dx, dy, dz = wx - d.x, wy - d.y, wz - d.z
      if dx * dx + dy * dy + dz * dz > bodies[cur].soi * bodies[cur].soi then
        enc[#enc + 1] = { t = tt, name = bodies[cur].name, anchor = cur, rx = dx, ry = dy, rz = dz, kind = "exit" }
        cur = pc
      end
    end
    -- Terrain impact ends the walk (the conic would dive underground).
    local sb = bodies[cur]
    local d = es[cur]
    local dx, dy, dz = wx - d.x, wy - d.y, wz - d.z
    if dx * dx + dy * dy + dz * dz < sb.radius * sb.radius then
      enc[#enc + 1] = { t = tt, name = sb.name, anchor = cur, rx = dx, ry = dy, rz = dz, kind = "impact" }
      break
    end
    start_states = es -- this step's END is the next step's START
  end
  return rpts, anch, enc
end

-- Walk the CURRENT patched conic forward to `t_target`, crossing every SOI in
-- between, and return the ship's state THERE — the dominant body it's under plus
-- its position AND velocity relative to that body (and the absolute world state).
-- THIS is what makes a maneuver node placed BEYOND an SOI crossing land on the
-- real path and apply its burn in the right frame: true across-SOI planning,
-- not a single two-body arc around the starting planet.
local function patched_state_at(bodies, pidx, wx, wy, wz, wvx, wvy, wvz, cur, t_start, t_target, steps)
  steps = math.max(1, steps)
  local step = (t_target - t_start) / steps
  local tt = t_start
  local start_states = all_body_states(bodies, pidx, tt)
  for _ = 1, steps do
    local cs = start_states[cur]
    local nrx, nry, nrz, nrvx, nrvy, nrvz = space.propagate(
      wx - cs.x, wy - cs.y, wz - cs.z, wvx - cs.vx, wvy - cs.vy, wvz - cs.vz,
      bodies[cur].mu, step)
    tt = tt + step
    local es = all_body_states(bodies, pidx, tt)
    local ec = es[cur]
    wx, wy, wz = ec.x + nrx, ec.y + nry, ec.z + nrz
    wvx, wvy, wvz = ec.vx + nrvx, ec.vy + nrvy, ec.vz + nrvz
    for j, o in ipairs(bodies) do -- fall into a child SOI
      if pidx[j] == cur and o.soi > 0 then
        local d = es[j]
        local dx, dy, dz = wx - d.x, wy - d.y, wz - d.z
        if dx * dx + dy * dy + dz * dz < o.soi * o.soi then cur = j break end
      end
    end
    local pc = pidx[cur] -- climb out to the parent
    if pc and bodies[cur].soi > 0 then
      local d = es[cur]
      local dx, dy, dz = wx - d.x, wy - d.y, wz - d.z
      if dx * dx + dy * dy + dz * dz > bodies[cur].soi * bodies[cur].soi then cur = pc end
    end
    start_states = es
  end
  local d = start_states[cur]
  return {
    anchor = cur, mu = bodies[cur].mu,
    wx = wx, wy = wy, wz = wz, wvx = wvx, wvy = wvy, wvz = wvz,
    rx = wx - d.x, ry = wy - d.y, rz = wz - d.z,
    rvx = wvx - d.vx, rvy = wvy - d.vy, rvz = wvz - d.vz,
  }
end

-- A stored (anchor, rel) → its LIVE world position (attractor's current pos + rel).
local function rel_world(bodies, anchor, rx, ry, rz)
  local b = bodies[anchor]
  if not b then return nil end
  return b.x + rx, b.y + ry, b.z + rz
end

-- Draw a rest-frame polyline: each point rides its own anchor body's live pos.
-- A point whose anchor is gone breaks the line, so each unbroken run is one
-- draw.polyline call.
local function draw_rel_polyline(rpts, anch, bodies, r, g, b, a)
  local n = math.floor(#rpts / 3)
  local run, m = {}, 0
  for k = 0, n - 1 do
    local wx, wy, wz = rel_world(bodies, anch[k + 1], rpts[k * 3 + 1], rpts[k * 3 + 2], rpts[k * 3 + 3])
    if wx then
      run[m + 1], run[m + 2], run[m + 3] = wx, wy, wz
      m = m + 3
    else
      if m >= 6 then draw.polyline(run, r, g, b, a) end
      run, m = {}, 0
    end
  end
  if m >= 6 then draw.polyline(run, r, g, b, a) end
end

-- The trajectory point nearest the cursor in SCREEN space (KSP click-on-line).
-- Projects each rest-frame point at its anchor's LIVE position (so you click the
-- orbit you SEE). Returns index k (0-based), the live world point, and its
-- time-from-now, or nil if nothing is within the pixel threshold / no camera.
local function pick_traj_point(traj, bodies)
  if not traj or not camera or not camera.exists() then return nil end
  local mx, my = input.mouse()
  local n = math.floor(#traj.rpts / 3)
  local bk, bd, bx, by, bz
  for k = 0, n - 1 do
    local px, py, pz = rel_world(bodies, traj.anch[k + 1],
      traj.rpts[k * 3 + 1], traj.rpts[k * 3 + 2], traj.rpts[k * 3 + 3])
    if px then
      local sx, sy, _, on = camera.worldToScreen(px, py, pz)
      if on then
        local d = (sx - mx) ^ 2 + (sy - my) ^ 2
        if not bd or d < bd then bd, bk, bx, by, bz = d, k, px, py, pz end
      end
    end
  end
  if bd and bd < (24 * 24) then
    return bk, bx, by, bz, (traj.t0 or 0) + bk * (traj.step or 0)
  end
  return nil
end

-- A little 3D diamond marker (used for the node + encounter points).
local function draw_diamond(x, y, z, s, r, g, b)
  depth(false)
  draw.line(x - s, y, z, x, y + s, z, r, g, b, 1)
  draw.line(x, y + s, z, x + s, y, z, r, g, b, 1)
  draw.line(x + s, y, z, x, y - s, z, r, g, b, 1)
  draw.line(x, y - s, z, x - s, y, z, r, g, b, 1)
  draw.line(x, y, z - s, x, y + s, z, r, g, b, 1)
  draw.line(x, y + s, z, x, y, z + s, r, g, b, 1)
  draw.line(x, y, z + s, x, y - s, z, r, g, b, 1)
  draw.line(x, y - s, z, x, y, z - s, r, g, b, 1)
  depth(true)
end

-- FROZEN COAST REFERENCE: while the ship coasts its orbit is analytically
-- fixed, so every trajectory walk + the node projection starts from this
-- frozen (state, time) — the walks sample the SAME absolute instants every
-- recompute, so the drawn path and the maneuver node are rock-steady. (They
-- used to re-derive from the live sim state every 0.15 s: sim noise + step
-- re-quantization made the node hop and the post-burn path flicker even in a
-- perfectly stable orbit.) Re-seeded when: thrusting or grounded, the
-- dominant body changed, the live state drifted off the reference conic
-- (RCS puffs, collisions, burns), or the ref aged past the walk window.
local traj_ref = nil -- { t, rx..rz, rvx..rvz (dominant-frame), dbname, span }
-- What the cached walks were computed from. While coasting the reference is
-- frozen, so an unchanged key means the walks would come out identical — the
-- recompute is skipped instead of re-solving thousands of conics to redraw
-- the same line (it showed as a hitch every 0.15 s while zooming).
local traj_key = nil

-- Recompute the maneuver-node projection + both trajectory walks (throttled).
-- `db` is the ship's dominant body; `o` its current conic (space.elements).
local function recompute_trajectories(node, db, bodies, pidx, o, thr)
  -- Find the dominant body's index for the walkers.
  local dbi
  for i, b in ipairs(bodies) do
    if b.name == db.name then dbi = i break end
  end
  if not dbi then traj_now, traj_mnv = nil, nil return end

  local now = space.time()
  local rx0, ry0, rz0 = node.x - db.x, node.y - db.y, node.z - db.z
  -- `thr` = the subject craft's throttle. Coasting is what lets the reference
  -- conic be frozen; under thrust the orbit is changing and must be re-read.
  local coasting = (thr or 0) < 0.005 and not node.grounded
  local stale = not coasting or not traj_ref or traj_ref.dbname ~= db.name
  if not stale then
    local dtb = now - traj_ref.t
    if dtb > traj_ref.span * 0.35 then
      stale = true -- the walk window has drifted behind us: re-anchor
    else
      -- Drift gate: where the ref conic says we are now vs the live sim.
      -- Catches anything that actually changed the orbit (RCS, a bump).
      local prx, pry, prz = space.propagate(traj_ref.rx, traj_ref.ry, traj_ref.rz,
        traj_ref.rvx, traj_ref.rvy, traj_ref.rvz, db.mu, dtb)
      local ex, ey, ez = prx - rx0, pry - ry0, prz - rz0
      local tol = math.max(4.0, (rx0 * rx0 + ry0 * ry0 + rz0 * rz0) * 4e-6)
      if ex * ex + ey * ey + ez * ez > tol then stale = true end
    end
  end
  if stale then
    -- Timescale: your own year if bound, else the planet's year (transfer clock).
    local span
    if o and o.period then
      span = o.period * 1.6
    else
      local yp = body_period(bodies, pidx, dbi)
      span = (yp and yp * 1.2) or 20000.0
    end
    traj_ref = { t = now, rx = rx0, ry = ry0, rz = rz0,
      rvx = node.vx, rvy = node.vy, rvz = node.vz, dbname = db.name, span = span }
  end
  local span = traj_ref.span
  local segs = math.floor(params.segments)
  local toff = traj_ref.t - now -- ≤ 0: walks start at the frozen ref instant
  local key = mnv and string.format("%s|%.6f|%.6f|%.6f|%.6f", tostring(traj_ref), mnv.t0,
    mnv.pro, mnv.nor, mnv.rad) or tostring(traj_ref)
  if key == traj_key and traj_now and (traj_mnv ~= nil) == (mnv ~= nil) then
    traj_now.t0 = toff -- the same path, one recompute later: only its clock moves
    return
  end
  traj_key = key

  -- Ship WORLD state AT THE REF INSTANT: the dominant body's state then + the
  -- frozen relative state (node.vx/vy/vz are frame-relative by convention).
  local dsx, dsy, dsz, dsvx, dsvy, dsvz = body_state_at(bodies, pidx, dbi, toff)
  local swx, swy, swz = dsx + traj_ref.rx, dsy + traj_ref.ry, dsz + traj_ref.rz
  local swvx, swvy, swvz = dsvx + traj_ref.rvx, dsvy + traj_ref.rvy, dsvz + traj_ref.rvz

  local rpts, anch, enc = walk_trajectory(bodies, pidx, swx, swy, swz, swvx, swvy, swvz, dbi, toff, span, segs)
  -- Rest-frame cache: rpts are RELATIVE to per-point anchor bodies (anch), drawn
  -- at each anchor's LIVE position. `step`/`t0` give each point a TIME (offset
  -- from now), which is what click-to-place reads to drop the node at the
  -- right spot on the orbit.
  traj_now = { rpts = rpts, anch = anch, enc = enc, t0 = toff, step = span / segs }

  if mnv then
    -- Walk the CURRENT patched conic to the node time, CROSSING any SOI between
    -- now and then, so the node's state (position, velocity, and which body it
    -- orbits) is the true one — not a single two-body arc around the start.
    -- `mnv.t0` is an ABSOLUTE sim-time instant; the LEAD (seconds until the burn)
    -- is `t0 − now`, which counts down ON ITS OWN as you coast — so the node stays
    -- PINNED to its point on the orbit while you close on it. (It used to store a
    -- fixed lead-from-now, so the walk always advanced the same span from an
    -- ever-advancing start → the node marched forever ahead and you never reached it.)
    -- Walk from the FROZEN ref instant to the node's absolute time: both ends
    -- are constants while coasting, so the step count and every SOI-crossing
    -- decision quantize identically each recompute — the node state (and the
    -- whole post-burn path) is bit-stable instead of hopping every 0.15 s.
    local t_node = math.max(mnv.t0 - now, 0)
    local nsteps = math.max(8, math.ceil((t_node - toff) / (span / segs)))
    local ns = patched_state_at(bodies, pidx, swx, swy, swz,
      swvx, swvy, swvz, dbi, toff, t_node, nsteps)
    local ndb = ns.anchor -- the body the node orbits (may DIFFER from the start db!)
    local nrx, nry, nrz = ns.rx, ns.ry, ns.rz
    local nvx, nvy, nvz = ns.rvx, ns.rvy, ns.rvz
    -- Burn basis at the node, IN ITS dominant body's frame: prograde / normal /
    -- radial-out (world axes — celestial frames only translate).
    local px, py, pz = norm(nvx, nvy, nvz)
    local hnx, hny, hnz = norm(cross(nrx, nry, nrz, nvx, nvy, nvz))
    local rdx, rdy, rdz = cross(px, py, pz, hnx, hny, hnz)
    local bx = px * mnv.pro + hnx * mnv.nor + rdx * mnv.rad
    local by = py * mnv.pro + hny * mnv.nor + rdy * mnv.rad
    local bz = pz * mnv.pro + hnz * mnv.nor + rdz * mnv.rad
    -- Post-burn seed: node WORLD position unchanged, WORLD velocity += the burn.
    local mwvx, mwvy, mwvz = ns.wvx + bx, ns.wvy + by, ns.wvz + bz
    -- Post-burn timescale about the node's body (bound → its year; escape → the
    -- transfer clock).
    local bvx, bvy, bvz = nvx + bx, nvy + by, nvz + bz
    local v2 = bvx * bvx + bvy * bvy + bvz * bvz
    local rlen = math.sqrt(nrx * nrx + nry * nry + nrz * nrz)
    local a2 = 1.0 / (2.0 / rlen - v2 / ns.mu)
    local mspan
    if a2 > 0 then
      mspan = 2 * math.pi * math.sqrt(a2 * a2 * a2 / ns.mu) * 1.6
    else
      local yp = body_period(bodies, pidx, ndb)
      mspan = (yp and yp * 1.2) or 20000.0
    end
    local mrpts, manch, menc =
      walk_trajectory(bodies, pidx, ns.wx, ns.wy, ns.wz, mwvx, mwvy, mwvz, ndb, t_node, mspan, segs)
    local dv = math.sqrt(mnv.pro ^ 2 + mnv.nor ^ 2 + mnv.rad ^ 2)
    -- Cache the burn's WORLD direction so the SAS "node" hold can point at it in
    -- flight (where recompute doesn't run).
    if dv > 1e-4 then mnv.bwx, mnv.bwy, mnv.bwz = norm(bx, by, bz) else mnv.bwx = nil end
    traj_mnv = {
      rpts = mrpts, anch = manch, enc = menc,
      m_anchor = ndb, m_rx = nrx, m_ry = nry, m_rz = nrz, -- node marker (its body's frame)
      bx = bx, by = by, bz = bz,
      dv = dv, t0 = t_node, step = mspan / segs,
    }
  else
    traj_mnv = nil
  end
end

local function update_map3d(node, dt)
  if not map_view then return end
  soi_off = nil
  -- The map's SUBJECT is the craft being flown, and its kinematics come from
  -- the SIM (assembly.info) — position, velocity AND grounded — never the
  -- node-pose mirror, so the map can't go dark if the mirror lags or misses.
  if time - subj_t > 0.5 or (subj_cache and not (subj_cache.node and subj_cache.node.valid)) then
    subj_cache, subj_t = subject_vessel(), time
  end
  local vc = subj_cache
  local craft_flying = vc ~= nil
  if craft_flying then
    local vi = assembly.info(vc.node)
    if vi then
      node = { x = vi.origin.x, y = vi.origin.y, z = vi.origin.z,
               vx = vi.vel.x, vy = vi.vel.y, vz = vi.vel.z,
               grounded = vi.grounded }
    else
      node = vc.node -- parts still assembling: the node pose is all there is
      if not map_diag then
        map_diag = true
        print("map: piloted vessel has no physics assembly yet — showing its node pose")
      end
    end
  elseif astronaut and astronaut.valid then
    -- Nobody flying: the map is a system view centred on the crew.
    node = astronaut
  end
  local subj_throttle = craft_flying and (vc.throttle or 0) or 0
  if not cam_node then cam_node = find("Camera 1") end
  local bodies = space.bodies()
  local nf = #bodies + 1 -- focus slots: the SHIP first, then every body
  if input.pressed("tab") then
    map_focus = map_focus % nf + 1
    zoom_target = nil -- re-fit, and ease there from where the view is now
    map_offx, map_offy, map_offz = 0.0, 0.0, 0.0
  end
  if map_focus > nf then map_focus = 1 end
  if input.pressed("1") then map_show.orbits = not map_show.orbits end
  if input.pressed("2") then map_show.soi = not map_show.soi end
  if input.pressed("3") then map_show.markers = not map_show.markers end
  if input.pressed("4") then map_show.links = not map_show.links end

  -- Focusing a body (TAB) used to stream ITS real terrain in (terrain.warm),
  -- a full background generation for a look. far_bodies' impostor now draws
  -- the framed world as one mesh in its own shape and colours, so the map no
  -- longer warms anything. (The comms coverage tint does not need it either:
  -- its ground radii fall back to the nominal radius until that world has
  -- been resident once, and are kept in the save after.)
  local fbody = (map_focus > 1 and bodies[map_focus - 1]) and bodies[map_focus - 1].name or nil
  -- far_bodies draws a far world as one mesh in its own shape and colours;
  -- the world the map frames gets its finest one.
  if fb_ref == nil then fb_ref = findScript("far_bodies") or false end
  if fb_ref and fb_ref.valid ~= false and fb_ref.focus then fb_ref.focus(fbody) end
  local focus, fname, fradius
  if focus_override and not focus_override.valid then focus_override = nil end
  if map_focus == 1 and focus_override then
    focus = { x = focus_override.x, y = focus_override.y, z = focus_override.z }
    fname = focus_override.name or "CRAFT"
    fradius = 6
  elseif map_focus == 1 then
    if craft_flying or not astronaut then
      focus = { x = node.x, y = node.y, z = node.z }
      fname = "SHIP"
    else
      focus = { x = astronaut.x, y = astronaut.y, z = astronaut.z }
      fname = "YOU"
    end
    fradius = 6
  else
    focus = bodies[map_focus - 1]
    fname, fradius = focus.name, focus.radius
  end
  -- The world the comms coverage tint is drawn on: the focused body, else the
  -- one the focus (you, your craft) is in.
  if map_focus > 1 then
    cov_body = fname
  else
    cov_body = space.dominant(focus.x, focus.y, focus.z)
  end
  if not zoom_target then
    -- Auto-fit: opening on the ship/astronaut frames the WHOLE current orbit
    -- (apoapsis + body), not a close-up of the hull.
    if map_focus == 1 then
      local dn0 = space.dominant(focus.x, focus.y, focus.z)
      local b0 = dn0 and space.body(dn0)
      if b0 then
        local rr = math.sqrt((focus.x - b0.x) ^ 2 + (focus.y - b0.y) ^ 2 + (focus.z - b0.z) ^ 2)
        zoom_target = math.max(rr * 2.2, b0.radius * 3.5)
        local o = space.elements(node.x, node.y, node.z, node.vx, node.vy, node.vz)
        if o and o.apoapsis then zoom_target = math.max(zoom_target, o.apoapsis * 1.5) end
        -- On foot there is no orbit to frame: show the world whole, inside its
        -- sphere of influence. (Framed on the planet alone, the SOI ring — on
        -- by default — sat entirely off screen and looked like it never drew.)
        if not craft_flying and b0.soi and b0.soi > 0 then
          zoom_target = math.max(zoom_target, b0.soi * 1.2 / TANH / FOV_K)
        end
      else
        zoom_target = 400
      end
    else
      zoom_target = math.max(fradius * 6, 80)
    end
    zoom_target = zoom_target * FOV_K
    map_zoom = map_zoom or zoom_target -- opening: start framed, no fly-in
  end

  -- Blender-style navigation: the mouse is free (and does nothing) unless
  -- RIGHT CLICK is held — drag then ORBITS the selection; CTRL+RIGHT-drag
  -- PANS the view offset in the camera plane instead. Scroll / ↑↓ zooms.
  local dragging = input.button(1)
  input.setMouseLocked(dragging)
  local cp, sp2 = math.cos(map_pitch2), math.sin(map_pitch2)
  local cy3, sy3 = math.cos(map_yaw2), math.sin(map_yaw2)
  if dragging then
    local mdx, mdy = input.mouse_delta()
    if input.key("ctrl") then
      -- Pan: move the offset along the camera's right/up axes, scaled by zoom.
      local rx3, rz3 = cy3, -sy3 -- camera right (horizontal)
      local uxx = -sp2 * sy3
      local uyy = cp
      local uzz = -sp2 * cy3 -- camera up
      local k = map_zoom * 0.0016
      map_offx = map_offx + (-mdx * rx3 + mdy * uxx) * k
      map_offy = map_offy + (mdy * uyy) * k
      map_offz = map_offz + (-mdx * rz3 + mdy * uzz) * k
    else
      map_yaw2 = map_yaw2 - mdx * 0.0035
      map_pitch2 = math.max(-1.45, math.min(1.45, map_pitch2 - mdy * 0.0035))
      cp, sp2 = math.cos(map_pitch2), math.sin(map_pitch2)
      cy3, sy3 = math.cos(map_yaw2), math.sin(map_yaw2)
    end
  end
  local sc = input.scroll()
  if sc and sc ~= 0 then zoom_target = zoom_target * math.exp(-sc * 0.12) end
  if input.key("up") then zoom_target = zoom_target * math.exp(-1.5 * dt) end
  if input.key("down") then zoom_target = zoom_target * math.exp(1.5 * dt) end
  zoom_target = math.max(fradius * 1.6, math.min(zoom_target, zoom_max()))
  local lz0 = math.log(map_zoom)
  map_zoom = math.exp(lz0 + (math.log(zoom_target) - lz0) * (1 - math.exp(-12 * dt)))
  if cam_node then
    local dx3, dy3, dz3 = cp * sy3, sp2, cp * cy3
    local lx = focus.x + map_offx
    local ly = focus.y + map_offy
    local lz = focus.z + map_offz
    cam_node.x = lx + dx3 * map_zoom
    cam_node.y = ly + dy3 * map_zoom
    cam_node.z = lz + dz3 * map_zoom
    cam_node.yaw = math.atan2(dx3, dz3)
    cam_node.pitch = -map_pitch2
    cam_node.roll = 0
  end

  -- Everything below is sized and culled on SCREEN: a marker is so many
  -- pixels wherever it sits, and an orbit too small to see is not drawn.
  local ccx, ccy, ccz = cam_node and cam_node.x or focus.x, cam_node and cam_node.y or focus.y,
    cam_node and cam_node.z or focus.z
  local sh = 720
  if camera and camera.screenSize then sh = select(2, camera.screenSize()) or 720 end
  local function cam_dist(x, y, z)
    return math.max(1e-3, math.sqrt((x - ccx) ^ 2 + (y - ccy) ^ 2 + (z - ccz) ^ 2))
  end
  -- World size of `px` screen pixels at a point (the map's lens, MAP_FOV).
  local function px_at(x, y, z, px) return cam_dist(x, y, z) * px * 2 * TANH / sh end
  -- Screen pixels per world unit at a distance.
  local function ppu(d) return sh / (2 * TANH * d) end

  if #bodies ~= pidx_n or time - pidx_t > 1.0 then
    map_pidx, pidx_n, pidx_t = parent_indices(bodies), #bodies, time
  end
  -- The SOI rings worth seeing: the ones the subject is inside, and the focus.
  local ring_for = {}
  local dn0 = space.dominant(node.x, node.y, node.z)
  for i, b in ipairs(bodies) do
    if b.name == dn0 or i == map_focus - 1 then
      local k = i
      while k do ring_for[k] = true; k = map_pidx[k] end
    end
  end

  -- Labels already placed this frame: a far pair of worlds projects to nearly
  -- one point, and two names drawn over each other read as neither.
  local placed = {}
  local lk = sh / uiDesignH()   -- name tags follow the interface size
  -- The screen the map does not own: the legend panel top-left and the menu
  -- button top-right. A label that lands under either is skipped — a far
  -- system's name used to float in the middle of the legend.
  local blocked = {}
  for _, nm in ipairs({ "HUD Panel", "Menu Btn" }) do
    local n = find(nm)
    if n and n.uiRect then
      local x, y, w, h = n:uiRect()
      if x then blocked[#blocked + 1] = { x - 6, y - 6, w + 12, h + 12 } end
    end
  end
  local function covered(x, y, w, h)
    for _, r in ipairs(blocked) do
      if x < r[1] + r[3] and x + w > r[1] and y < r[2] + r[4] and y + h > r[2] then return true end
    end
    return false
  end
  local function name_w(text, fs)
    local _, n = text:gsub("[^\128-\191]", "")
    return n * fs * 0.56 + fs
  end
  -- A name on the map is a small enamel tag (docs/ui-style.md): a dark cut
  -- edge, the plate, and the name printed in the label face in warm ink.
  -- Every tag keeps clear of the ones placed before it this frame (worlds
  -- first, then craft, markers and stations): one that would land on another
  -- moves up a row, twice at most, and is left out after that.
  local function label(x, y, text, fs)
    if cineHidden() then return false end   -- cinematic mode (F4): lines only, no tags
    local w, h = name_w(text, fs), fs * 1.5
    local spot = nil
    for row = 0, 2 do
      local ty = y - row * h * 1.1
      local clear = not covered(x - w / 2, ty - h / 2, w, h)
      for _, q in ipairs(placed) do
        if not clear then break end
        if math.abs(q[1] - x) < (q[3] + w) / 2 and math.abs(q[2] - ty) < (q[4] + h) / 2 then clear = false end
      end
      if clear then spot = ty break end
    end
    if not spot then return false end
    y = spot
    placed[#placed + 1] = { x, y, w, h }
    draw.rect(x - w / 2 - 1, y - h / 2 - 1, w + 2, h + 2, 0.0, 0.0, 0.0, 0.7, fs * 0.15)
    draw.rect(x - w / 2, y - h / 2, w, h, 0.12, 0.124, 0.112, 0.86, fs * 0.12)
    draw.text(x, y - fs * 0.62, text, fs, 0.92, 0.89, 0.81, 1.0, "center", "fonts/SolarLabel.ttf")
    return true
  end
  -- Orbit lines around each body's parent, and the names of what's in view.
  for i, b in ipairs(bodies) do
    local pi = map_pidx[i]
    local par = pi and bodies[pi]
    local shown = false
    if par then
      local has, p, ecc, e1x, e1y, e1z, e2x, e2y, e2z = orbit_basis(
        b.x - par.x, b.y - par.y, b.z - par.z,
        b.vx - par.vx, b.vy - par.vy, b.vz - par.vz, par.mu)
      if has then
        local reach = ecc < 1 and p / (1 - ecc) or p * 2
        local span_px = reach / cam_dist(par.x, par.y, par.z) * sh
        shown = span_px > 4
        if shown and map_show.orbits then
          local segs = math.max(24, math.min(128, math.floor(span_px / 5)))
          draw_conic(par.x, par.y, par.z, e1x, e1y, e1z, e2x, e2y, e2z,
            p, ecc, 0.55, 0.62, 0.72, 0.8, segs)
        end
      end
    else
      shown = true -- a star
    end
    if map_show.soi and b.soi > 0 and ring_for[i] then
      local vx, vy, vz = norm(ccx - b.x, ccy - b.y, ccz - b.z)
      -- Drawn through the planets in front of it: a ring is a boundary, not an
      -- object, and depth-testing it against a world it encloses lost it.
      depth(false)
      draw.ring(b.x, b.y, b.z, vx, vy, vz, b.soi, 0.45, 0.78, 0.95, 0.85)
      depth(true)
      -- Bigger than the view: say so in the legend rather than show nothing.
      local spx = b.soi * ppu(cam_dist(b.x, b.y, b.z))
      if spx > sh * 0.55 and b.name == dn0 then soi_off = b end
    end
    if shown and map_show.markers and camera and camera.worldToScreen then
      local sx, sy, _, on = camera.worldToScreen(b.x, b.y, b.z)
      if on then
        -- Just above the body's disc, on a dark backing so a name reads over
        -- the star's white glare as well as over black sky.
        local rpx = b.radius * ppu(cam_dist(b.x, b.y, b.z))
        local fs = 15 * lk
        local ly = sy - math.max(8 * lk, rpx) - fs * 1.1
        label(sx, ly, b.name, fs)
      end
    end
  end

  -- The ship's own conic + Pe/Ap markers + a position cross.
  local dn = space.dominant(node.x, node.y, node.z)
  local db = dn and space.body(dn)
  local info_orbit = nil
  if db then
    -- node velocity is ALREADY in the dominant body's carried frame (the
    -- engine's SOI frame convention) — subtracting db's world velocity again
    -- bent the drawn conic once the planet itself started orbiting the star.
    local has, p, ecc, e1x, e1y, e1z, e2x, e2y, e2z = orbit_basis(
      node.x - db.x, node.y - db.y, node.z - db.z,
      node.vx, node.vy, node.vz, db.mu)
    if has then
      info_orbit = { body = db.name, p = p, ecc = ecc, radius = db.radius }
    end
  end
  -- Every craft's own conic: the one flown (or opened from the Tracking
  -- Station) bright, the rest dimmed.
  drawCraftTracks(craft_flying and vc or nil, focus_override, px_at, label, lk, map_show)
  if map_show.markers then
    draw_cross(node.x, node.y, node.z, px_at(node.x, node.y, node.z, 6), 0.6, 1.0, 0.7)
  end
  -- The COMMS NETWORK: every craft, the ground station, and every usable link,
  -- coloured by its strength (bright where a path home runs through it).
  mapComms(node, px_at, label, lk, map_show)

  -- ---- maneuver-node planning (KSP) --------------------------------------
  -- Plan a burn and watch the resulting orbit — and where it drops you into
  -- another body's sphere of influence.
  local oe = db and space.elements(node.x, node.y, node.z, node.vx, node.vy, node.vz)
  local hover_x, hover_y, hover_z -- the orbit point under the cursor (draw below)
  if craft_flying and db and not node.grounded then
    local pidx = parent_indices(bodies)
    local vref = math.sqrt(node.vx ^ 2 + node.vy ^ 2 + node.vz ^ 2)
    local dvrate = math.max(0.5, vref * 0.12)

    -- PLANNING IS A MODE, and it has to be. A craft flies from the map — that
    -- is the point of flying on instruments — so the stick owns W/S/A/D/Q/E,
    -- and the burn tuner wants exactly those six keys. They cannot both have
    -- them. `N` swaps which one is listening, `planning` says so out loud (the
    -- vessel reads it and freezes), and the HUD prints the mode every frame.
    --
    -- The old answer was to give planning to the scout ship and nothing else,
    -- which meant the craft you actually built could never plan a burn.
    if planning then
      -- CLICK-ON-ORBIT placement (KSP): hover the current-orbit line, LEFT-click or
      -- drag to create/move the burn at that exact point (RMB is the camera, so LMB
      -- is free). Picks against the cached forward path, whose points carry a time —
      -- so the click lands the node at the right spot on the orbit.
      local pk_k, px, py, pz, pk_t = pick_traj_point(traj_now, bodies)
      if pk_k then hover_x, hover_y, hover_z = px, py, pz end
      if pk_t and input.button(0) then
        -- Store the node as an ABSOLUTE instant (now + the clicked point's lead) so it
        -- stays fixed on the orbit as you coast toward it instead of running ahead.
        local t0 = space.time() + pk_t
        if mnv then mnv.t0, mnv.burned = t0, 0.0
        else mnv = { t0 = t0, pro = 0.0, nor = 0.0, rad = 0.0, burned = 0.0 } end
      end

      -- Entering the mode with nothing planned puts a node a quarter-orbit
      -- ahead, so plan mode always has something to tune. A mode that needs a
      -- second, undiscoverable action before it does anything is a mode people
      -- conclude is broken.
      if not mnv then
        local lead = (oe and oe.period and oe.period * 0.25) or 60.0
        mnv = { t0 = space.time() + lead, pro = 0.0, nor = 0.0, rad = 0.0, burned = 0.0 }
      end
      -- BACKSPACE abandons the burn outright (X only zeroes its ΔV).
      if input.pressed("backspace") then
        mnv = nil
        planning = false
      end
      if mnv then
        -- ←/→ fine-tune the node time; W/S/A/D/Q/E tune the ΔV; X zeroes it.
        local tref = (oe and oe.period) or 600.0
        local horizon = (oe and oe.period and oe.period * 1.5) or (tref * 6)
        local sliding = input.key("left") or input.key("right")
        if input.key("left") then mnv.t0 = mnv.t0 - tref * 0.15 * dt end
        if input.key("right") then mnv.t0 = mnv.t0 + tref * 0.15 * dt end
        -- Clamp ONLY while actively sliding (keep the handle ahead of you and inside
        -- the horizon) — never during the passive countdown, so the lead can fall to
        -- 0 and past as you coast up to the node.
        if sliding then
          local now = space.time()
          mnv.t0 = math.max(now + 1.0, math.min(mnv.t0, now + horizon))
        end
        if input.key("w") then mnv.pro = mnv.pro + dvrate * dt end
        if input.key("s") then mnv.pro = mnv.pro - dvrate * dt end
        if input.key("d") then mnv.rad = mnv.rad + dvrate * dt end
        if input.key("a") then mnv.rad = mnv.rad - dvrate * dt end
        if input.key("q") then mnv.nor = mnv.nor + dvrate * dt end
        if input.key("e") then mnv.nor = mnv.nor - dvrate * dt end
        if input.pressed("x") then mnv.pro, mnv.nor, mnv.rad = 0, 0, 0 end
      end
    end
    if time - traj_t >= params.recompute then
      traj_t = time
      recompute_trajectories(node, db, bodies, pidx, oe, subj_throttle)
    end
  else
    mnv = nil
    traj_now, traj_mnv = nil, nil
  end

  -- Draw the cached walks in the dominant body's REST FRAME: every point rides
  -- its anchor body's LIVE position, so the orbit is a static ellipse around the
  -- planet where you SEE it, not smeared along the planet's own orbit.
  local function enc_diamond(e, px, r, g, b)
    local ex, ey, ez = rel_world(bodies, e.anchor, e.rx, e.ry, e.rz)
    if ex then draw_diamond(ex, ey, ez, px_at(ex, ey, ez, px), r, g, b) end
  end
  if traj_now and map_show.markers then
    for _, e in ipairs(traj_now.enc) do
      if e.kind == "impact" then
        enc_diamond(e, 8, 1.0, 0.4, 0.3)
      else
        enc_diamond(e, 8, 0.4, 0.9, 1.0)
      end
    end
  end
  -- The orbit point under the cursor (a soft ring) — where a click drops the node.
  if hover_x and not mnv then
    draw_diamond(hover_x, hover_y, hover_z, px_at(hover_x, hover_y, hover_z, 7), 0.7, 0.95, 1.0)
  end
  if traj_mnv then
    if map_show.orbits then
      draw_rel_polyline(traj_mnv.rpts, traj_mnv.anch, bodies, 1.0, 0.55, 0.15, 0.95) -- post-burn (amber)
    end
    local mx, my, mz = rel_world(bodies, traj_mnv.m_anchor, traj_mnv.m_rx, traj_mnv.m_ry, traj_mnv.m_rz)
    if mx then
      draw_diamond(mx, my, mz, px_at(mx, my, mz, 9), 1.0, 0.7, 0.2)
      if traj_mnv.dv > 1e-4 then
        local bnx, bny, bnz = norm(traj_mnv.bx, traj_mnv.by, traj_mnv.bz)
        local bl = px_at(mx, my, mz, 36)
        draw.line(mx, my, mz, mx + bnx * bl, my + bny * bl, mz + bnz * bl, 1.0, 0.85, 0.3, 1.0)
      end
    end
    if map_show.markers then
      for _, e in ipairs(traj_mnv.enc) do
        if e.kind == "enter" then
          enc_diamond(e, 10, 0.4, 1.0, 0.5)
        elseif e.kind == "impact" then
          enc_diamond(e, 10, 1.0, 0.4, 0.3)
        else
          enc_diamond(e, 10, 0.9, 0.9, 0.5)
        end
      end
    end
  end

  -- Focused-body info panel (the flight HUD stands down while the map is open).
  if time - map_hud_t >= 0.1 then
    map_hud_t = time
    local lines = {}
    -- Which mode has the stick, said first and said plainly. In FLY the six
    -- attitude keys move the craft; in PLAN they move the burn. Nothing else
    -- on screen distinguishes them, so this line is the whole affordance.
    -- A legend, not a status dump: what you are looking at, how to move the
    -- view, and what the number keys switch. (It read "MAP · VIEW · focus YOU
    -- [TAB]… 1 orbits ON", which is a debug line.)
    local focus_name = map_focus == 1 and (craft_flying and "your craft" or "you") or fname
    local mode = planning and "PLANNING A BURN" or (craft_flying and "FLYING" or "ORBIT MAP")
    lines[1] = string.format("%s  —  centred on %s", mode, focus_name)
    lines[2] = "Right-drag  turn   ·   Ctrl + right-drag  pan   ·   Scroll  zoom   ·   Tab  next world   ·   M  close"
    if map_focus > 1 then
      local b = bodies[map_focus - 1]
      local dx4, dy4, dz4 = node.x - b.x, node.y - b.y, node.z - b.z
      local dd = math.sqrt(dx4 * dx4 + dy4 * dy4 + dz4 * dz4)
      lines[#lines + 1] = string.format("%s   ·   radius %s   ·   SOI %s   ·   %s from you",
        b.name, fmt_dist(b.radius), b.soi < 0 and "the whole system" or fmt_dist(b.soi),
        fmt_dist(dd))
    end
    -- The orbit, only for a craft in the air: on foot the "orbit" is the
    -- ground you are standing on, and a periapsis two hundred metres under it
    -- is true and useless.
    if info_orbit and craft_flying and not node.grounded then
      local o = info_orbit
      local pe = o.p / (1 + o.ecc) - o.radius
      if pe < 0 and o.ecc < 1 then
        -- Periapsis underground: not an orbit, a hop. Say so, and where.
        lines[#lines + 1] = string.format("Suborbital over %s   ·   Ap %s   ·   comes down at the red mark",
          o.body, fmt_dist(o.p / (1 - o.ecc) - o.radius))
      elseif o.ecc < 1 then
        lines[#lines + 1] = string.format("Orbiting %s   ·   Pe %s   ·   Ap %s",
          o.body, (pe < 0 and "−" or "") .. fmt_dist(pe), fmt_dist(o.p / (1 - o.ecc) - o.radius))
      else
        lines[#lines + 1] = string.format("Escaping %s   ·   Pe %s",
          o.body, (pe < 0 and "−" or "") .. fmt_dist(pe))
      end
    end
    -- Maneuver node + encounter readout.
    if mnv then
      local dv = math.sqrt(mnv.pro ^ 2 + mnv.nor ^ 2 + mnv.rad ^ 2)
      local lead = mnv.t0 - space.time()
      lines[#lines + 1] = string.format(
        "Burn %s %.0f s   ·   ΔV %.1f m/s   (prograde %+.1f · radial %+.1f · normal %+.1f)",
        lead >= 0 and "in" or "overdue by", math.abs(lead), dv, mnv.pro, mnv.rad, mnv.nor)
      if traj_mnv and #traj_mnv.enc > 0 then
        local e = traj_mnv.enc[1]
        local verb = e.kind == "enter" and "ENCOUNTER" or (e.kind == "impact" and "IMPACT" or "exit")
        lines[#lines + 1] = string.format("   then %s %s in %.0f s", verb, e.name, e.t)
      end
      lines[#lines + 1] = planning
        and "Click the orbit  move it  ·  W/S prograde  ·  A/D radial  ·  Q/E normal  ·  ← →  slide  ·  X  zero  ·  ⌫  delete  ·  N  fly"
        or  "N  plan the burn — until you do, the stick flies the craft"
    elseif craft_flying and not node.grounded then
      if traj_now and #traj_now.enc > 0 then
        local e = traj_now.enc[1]
        local verb = e.kind == "enter" and "ENCOUNTER" or (e.kind == "impact" and "IMPACT" or "SOI exit")
        lines[#lines + 1] = string.format("%s %s in %.0f s   ·   N  plan a burn", verb, e.name, e.t)
      else
        lines[#lines + 1] = "N  plan a burn on this orbit"
      end
    end
    local function sw(on) return on and "●" or "○" end
    lines[#lines + 1] = string.format("1 %s orbits     2 %s SOI rings     3 %s labels & markers     4 %s comms links",
      sw(map_show.orbits), sw(map_show.soi), sw(map_show.markers), sw(map_show.links))
    -- The comms network, in a line: how many craft can hear home.
    if map_show.links then
      local net = findScript("comms")
      if net and net.linkLines then
        local n_used = 0
        for _, l in ipairs(net.linkLines()) do if l.used then n_used = n_used + 1 end end
        lines[#lines + 1] = string.format("Comms: %d transmitter%s · %d link%s in use   (green strong · amber weak · red at the edge)",
          net.transmitters or 0, (net.transmitters or 0) == 1 and "" or "s", n_used, n_used == 1 and "" or "s")
      end
    end
    if soi_off then
      lines[#lines + 1] = string.format("   %s's SOI ring is %s across — scroll out to see it",
        soi_off.name, fmt_dist(soi_off.soi * 2))
    end
    set_hud(node, table.concat(lines, "\n"))
  end
end

-- ── driver ──────────────────────────────────────────────────────────────────

function isOpen() return map_view end

-- The planned burn's WORLD direction, or nil when there is no burn to point
-- at. `recompute_trajectories` caches it because it only knows the direction
-- while the map is doing its walk, and the SAS that wants it runs in flight —
-- where the walk isn't running at all. This is what the `node` hold aims down.
function burnDirection()
  if not (mnv and mnv.bwx) then return nil end
  return mnv.bwx, mnv.bwy, mnv.bwz
end

-- Seconds until the planned burn (negative once it has passed), or nil.
function burnLead()
  if not mnv then return nil end
  return mnv.t0 - space.time()
end

-- Ease the view to `z` metres from the focus, as the wheel does.
function setZoom(z)
  zoom_target = math.max(1, math.min(z, zoom_max()))
  -- Asked before the map's first frame (no view yet to ease from): start there.
  if not map_zoom then map_zoom = zoom_target end
end

-- THE COMMS LAYER (key 4): each link a line from red (at the edge of range) to
-- green, solid where it carries someone's path home and faint where it is only
-- possible; every other craft a small diamond with its name; the ground station
-- a ring at the base. Global so `update_map3d` spends no upvalue on it.
local comms_ref = nil
cov_body = nil   -- set by update_map3d: the world the coverage tint is drawn on

-- COVERAGE TINT: the comms coverage grid (comms.coverageGrid) on the chosen
-- world, one small disc per sample lying on the ground — teal where the ground
-- network (station + relay beacons) reaches, blue where only a satellite does,
-- a faint red where nothing does. Depth-tested, so the far side hides.
local function map_coverage(net, px_at)
  if not (cov_body and net.coverageGrid) then return nil end
  local g = net.coverageGrid(cov_body)
  local b = space.body(cov_body)
  if not (g and b) then return nil end
  local n = #g.dirs
  local spot = (b.radius or 100) * math.sqrt(4 * math.pi / math.max(1, n)) * 0.28
  local was = draw.depthTest()
  draw.depthTest(true)
  for i, u in ipairs(g.dirs) do
    local r = (g.r and g.r[i] or b.radius) + 2
    local x, y, z = b.x + u[1] * r, b.y + u[2] * r, b.z + u[3] * r
    local c = g.cov[i]
    if c == 2 then
      draw.disc(x, y, z, u[1], u[2], u[3], 0, spot, 0.25, 0.95, 0.78, 0.55)
    elseif c == 1 then
      draw.disc(x, y, z, u[1], u[2], u[3], 0, spot, 0.35, 0.62, 1.0, 0.5)
    else
      draw.disc(x, y, z, u[1], u[2], u[3], 0, spot * 0.45, 1.0, 0.35, 0.3, 0.35)
    end
  end
  draw.depthTest(was and true or false)
  return g
end

function mapComms(subject, px_at, label, lk, show)
  if not show.links and not show.markers then return end
  if not comms_ref or not comms_ref.valid then comms_ref = findScript("comms") end
  local net = comms_ref
  if not net then return end
  local E = findScript("electronics")
  -- live craft move between solves: put line ends where the craft are now
  local live, flown, names = {}, {}, {}
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.node and v.node.valid then
      live[v.node.id] = v.node
      names[v.node.id] = v.craftName
      if v.piloting then flown[v.node.id] = true end
    end
  end
  local function at(id, x, y, z)
    local n = live[id]
    if n then return n.x, n.y, n.z end
    return x, y, z
  end
  if show.links and net.linkLines then
    depth(false)
    for _, l in ipairs(net.linkLines()) do
      local r, g, b = 0.4, 0.8, 0.5
      if E and E.strengthColor then r, g, b = E.strengthColor(l.strength) end
      local ax, ay, az = at(l.a, l.ax, l.ay, l.az)
      local bx, by, bz = at(l.b, l.bx, l.by, l.bz)
      draw.line(ax, ay, az, bx, by, bz, r, g, b, l.used and 0.95 or 0.28)
    end
    depth(true)
  end
  local cov = show.links and map_coverage(net, px_at) or nil
  if cov and label and camera and camera.screenSize then
    local sw, sh = camera.screenSize()
    if sw then
      label(sw * 0.5, (sh or 720) - 64 * (lk or 1), string.format(
        "%s coverage  ·  ground network %d%%  ·  with satellites %d%%   (teal ground · blue sky · red none)",
        cov_body, math.floor(cov.ground * 100 + 0.5), math.floor(cov.sky * 100 + 0.5)), 13 * (lk or 1))
    end
  end
  -- RELAY BEACONS: a small upright triangle each, teal with a path home,
  -- red without, and its name.
  if (show.markers or show.links) and net.beaconList and camera and camera.worldToScreen then
    for _, e in ipairs(net.beaconList()) do
      if e.x then
        local s = px_at(e.x, e.y, e.z, 6)
        local gb = space.body(e.body)
        local ux, uy, uz = 0, 1, 0
        if gb then
          ux, uy, uz = e.x - gb.x, e.y - gb.y, e.z - gb.z
          local l = math.sqrt(ux * ux + uy * uy + uz * uz)
          ux, uy, uz = ux / l, uy / l, uz / l
        end
        local c = e.linked and { 0.35, 1.0, 0.8 } or { 1.0, 0.45, 0.35 }
        draw.ring(e.x, e.y, e.z, ux, uy, uz, s, c[1], c[2], c[3], 1)
        draw.line(e.x, e.y, e.z, e.x + ux * s * 2.2, e.y + uy * s * 2.2, e.z + uz * s * 2.2, c[1], c[2], c[3], 1)
        if show.markers and label then
          local px, py, _, on = camera.worldToScreen(e.x, e.y, e.z)
          if on then label(px, py - 16 * (lk or 1), e.name, 11 * (lk or 1)) end
        end
      end
    end
  end
  -- THE AGENCY'S FLAGS (scripts/deployables.lua): a short pole with a pennant
  -- in signal orange, and its name — the Tracking Station's MAP lands here.
  local dep = findScript and findScript("deployables")
  if show.markers and dep and dep.list and camera and camera.worldToScreen then
    for _, f in ipairs(dep.list("flag")) do
      if f.gx then
        local gb = space.body(f.b)
        local ux, uy, uz = 0, 1, 0
        if gb then
          local l = math.sqrt(f.x * f.x + f.y * f.y + f.z * f.z)
          if l > 1e-6 then ux, uy, uz = f.x / l, f.y / l, f.z / l end
        end
        local s = px_at(f.gx, f.gy, f.gz, 6)
        local tx, ty, tz = f.gx + ux * s * 2.6, f.gy + uy * s * 2.6, f.gz + uz * s * 2.6
        draw.line(f.gx, f.gy, f.gz, tx, ty, tz, 0.97, 0.55, 0.22, 1)
        draw.ring(tx, ty, tz, ux, uy, uz, s * 0.55, 0.97, 0.55, 0.22, 1)
        if label then
          local px, py, _, on = camera.worldToScreen(tx, ty, tz)
          if on then label(px, py - 14 * (lk or 1), f.n or "Flag", 11 * (lk or 1)) end
        end
      end
    end
  end
  if show.markers and camera and camera.worldToScreen then
    -- (Not `net.station and net.station()`: an `and` keeps only the first of
    -- the three values, and the ring was drawn at (x, nil, nil).)
    local sx, sy, sz
    if net.station then sx, sy, sz = net.station() end
    if sx then
      draw.ring(sx, sy, sz, 0, 1, 0, px_at(sx, sy, sz, 7), 0.35, 0.95, 0.85, 1.0)
    end
    for id, n in pairs(live) do
      if not flown[id] then
        local s = px_at(n.x, n.y, n.z, 5)
        local st = net.statusOf and net.statusOf(id)
        local c = (st and st.connected) and { 0.55, 0.95, 0.85 } or { 1.0, 0.55, 0.45 }
        draw.line(n.x - s, n.y, n.z, n.x, n.y + s, n.z, c[1], c[2], c[3], 1)
        draw.line(n.x, n.y + s, n.z, n.x + s, n.y, n.z, c[1], c[2], c[3], 1)
        draw.line(n.x + s, n.y, n.z, n.x, n.y - s, n.z, c[1], c[2], c[3], 1)
        draw.line(n.x, n.y - s, n.z, n.x - s, n.y, n.z, c[1], c[2], c[3], 1)
        local px, py, _, on = camera.worldToScreen(n.x, n.y, n.z)
        if on and label then label(px, py - 18 * (lk or 1), names[id] or n.name or "craft", 12 * (lk or 1)) end
      end
    end
  end
end

-- The interface's design height (settings.lua: 720 at 100%, 847 at 85%).
local set_ref, set_miss = nil, -10.0
function uiDesignH()
  if not (set_ref and set_ref.valid) then
    if time - set_miss < 2.0 then return 720 end
    set_ref = findScript("settings")
    if not set_ref then set_miss = time return 720 end
  end
  return (set_ref.designHeight and set_ref.designHeight()) or 720
end

-- Cinematic mode hides the map's name tags (planet_camera, F4). Cached handle,
-- asked again at most every two seconds when the scene has no such camera.
local cine_ref, cine_miss = nil, -10.0
function cineHidden()
  if not (cine_ref and cine_ref.valid) then
    if time - cine_miss < 2.0 then return false end
    cine_ref = findScript("planet_camera")
    if not cine_ref then cine_miss = time return false end
  end
  return cine_ref.cinematic == true
end

-- Draw one craft's track (TRAJ.track) about body `b`. `hi` = emphasised.
local TRACK_HI = { 0.35, 0.85, 1.0, 1.0 }       -- the craft you fly: the map's own trajectory cyan
local TRACK_LO = { 0.55, 0.68, 0.74, 0.38 }     -- every other craft: a quiet grey-blue
function drawTrack(t, b, hi, px_at, label, lk, show, name)
  if not t or t.kind == "landed" then return end
  local c = hi and TRACK_HI or TRACK_LO
  local cx, cy, cz = b.x, b.y, b.z
  if t.kind == "falling" then return end
  if show.orbits then
    if t.closed then
      local reach = t.apR or t.p
      local segs = math.max(32, math.min(160, math.floor(reach / px_at(cx, cy, cz, 1) / 6)))
      draw.conic(vec3(cx, cy, cz), vec3(t.e1[1], t.e1[2], t.e1[3]), vec3(t.e2[1], t.e2[2], t.e2[3]),
        t.p, t.e, segs, c[1], c[2], c[3], c[4], t.p * 50)
    elseif t.a1 > t.a0 then
      local span = t.a1 - t.a0
      draw.polyline(TRAJ.arc(t, cx, cy, cz, math.max(12, math.floor(span / (2 * math.pi) * 128))),
        c[1], c[2], c[3], c[4])
    end
  end
  if not show.markers then return end
  local a = hi and 1.0 or 0.45
  local function mark(nu, px, r, g, bb, text)
    local x, y, z = TRAJ.point(t, nu)
    x, y, z = cx + x, cy + y, cz + z
    if depth then depth(false) end
    draw_cross(x, y, z, px_at(x, y, z, px), r * a, g * a, bb * a)
    if hi and text and label and camera and camera.worldToScreen then
      local sx, sy, _, on = camera.worldToScreen(x, y, z)
      if on then label(sx, sy - 16 * (lk or 1), text, 11 * (lk or 1)) end
    end
  end
  local alt = function(r) return fmt_dist(r - (b.radius or 0)) end
  if t.pe then mark(t.pe, hi and 7 or 5, 1.0, 0.8, 0.25, "Pe " .. alt(t.peR)) end
  if t.ap then mark(t.ap, hi and 7 or 5, 0.4, 1.0, 0.6, "Ap " .. alt(t.apR)) end
  if t.impact then
    local x, y, z = TRAJ.point(t, t.impact)
    x, y, z = cx + x, cy + y, cz + z
    draw_diamond(x, y, z, px_at(x, y, z, hi and 8 or 6), 1.0 * a, 0.4 * a, 0.3 * a)
    if hi and label and camera and camera.worldToScreen then
      local sx, sy, _, on = camera.worldToScreen(x, y, z)
      if on then label(sx, sy - 16 * (lk or 1), "Impact", 11 * (lk or 1)) end
    end
  end
end

-- Every live craft's track. `flown` is the piloted vessel's script (or nil),
-- `picked` a craft node the map was opened on (the Tracking Station).
function drawCraftTracks(flown, picked, px_at, label, lk, show)
  if not (show.orbits or show.markers) then return end
  for _, v in ipairs(findScripts("vessel_controller")) do
    local n = v.node
    if n and n.valid then
      local info = assembly and assembly.info and assembly.info(n)
      local px, py, pz, vx, vy, vz, gr
      if info and info.origin then
        px, py, pz = info.origin.x, info.origin.y, info.origin.z
        vx, vy, vz, gr = info.vel.x, info.vel.y, info.vel.z, info.grounded
      else
        px, py, pz, vx, vy, vz, gr = n.x, n.y, n.z, n.vx or 0, n.vy or 0, n.vz or 0, n.grounded
      end
      local dn = space.dominant(px, py, pz)
      local b = dn and space.body(dn)
      if b then
        -- (velocity is already in the dominant body's carried frame — the
        -- engine's convention, see the subject's own conic above)
        local t = TRAJ.track(px - b.x, py - b.y, pz - b.z, vx, vy, vz, b.mu, b.radius, b.soi, gr)
        local hi = (flown ~= nil and flown.node and flown.node.id == n.id)
          or (picked ~= nil and picked.valid and picked.id == n.id)
        drawTrack(t, b, hi, px_at, label, lk, show, v.craftName)
      end
    end
  end
end

-- Open the map on a particular craft (the Tracking Station's MAP button).
function focusNode(n)
  if not map_view then toggle() end
  focus_override = n
  map_focus = 1
  zoom_target = nil
  map_offx, map_offy, map_offz = 0.0, 0.0, 0.0
end

-- Open or close. Called by the M key and by anything that needs the screen
-- back (a scene change, ending a flight).
function toggle()
  focus_override = nil
  if not astronaut or not astronaut.valid then astronaut = find("Astronaut") end
  map_view = not map_view
  map_zoom, zoom_target = nil, nil -- re-fit to the focus every time it opens
  map_focus = 1    -- always open on yourself
  map_offx, map_offy, map_offz = 0.0, 0.0, 0.0
  map_diag = false -- each opening may report one subject anomaly
  -- Terrain detail follows whoever you are while the map flies the camera
  -- thousands of km off, so closing it finds the ground still meshed.
  if terrain.lodAnchor then
    local sv = map_view and subject_vessel()
    local who = sv and sv.node or (map_view and astronaut and astronaut.valid and astronaut) or nil
    terrain.lodAnchor(who)
  end
  -- Map lines at the window's own resolution, crisp at any render scale.
  if draw.nativeLines then draw.nativeLines(map_view) end
  map_lens(map_view)
  if not map_view then
    planning = false
    if fb_ref and fb_ref.valid ~= false and fb_ref.focus then fb_ref.focus(nil) end
    -- Hand the instruments back to a craft that is still being flown; if
    -- nobody is flying, the HUD block goes away with the map.
    local flying = subject_vessel() ~= nil
    set_instruments(flying)
    if not flying then set_hud(nil, nil) end
  else
    set_instruments(false)
  end
end

function start(_)
  map_view = false
  planning = false
end

-- The map runs in lateUpdate — the CAMERA pass. Driven from fixedUpdate it
-- sampled tick poses while the world rendered interpolated ones, which showed
-- as constant back-and-forth jitter on every line.
local gm_ref = nil
function lateUpdate(node, dt)
  if not astronaut or not astronaut.valid then astronaut = find("Astronaut") end
  -- (not while the VAB builder has the keys: M is its mirror there)
  if not gm_ref or not gm_ref.valid then gm_ref = findScript("game_manager") end
  if gm_ref and gm_ref.inputOwner == "builder" then return end
  if input.pressed("m") then toggle() end
  if not map_view then return end
  -- N enters and leaves PLAN mode, but only for a craft that has a trajectory
  -- to plan on: on foot there is nothing to burn.
  if input.pressed("n") and subject_vessel() then planning = not planning end
  depth(true)
  update_map3d(node, dt)
  depth(false)
end
