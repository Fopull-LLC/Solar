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
--   PLANNING A BURN, WITH THE MOUSE. Hover your orbit and click it: a node
--   goes there (a click on a line is nothing the stick uses, so no mode is
--   needed). Its gizmo has six handles in the burn frame — prograde and
--   retrograde, normal and anti-normal, radial out and in: drag one to change
--   Δv along it (the longer the drag, the faster), drag the node's disc to
--   slide it along the orbit, scroll on either for fine steps (SHIFT halves,
--   CTRL ×5), and right-click it for Delete, ±1 orbit, Warp here, Zero ΔV and
--   Lock. A CRT tag beside it reads the Δv, the time to it, the burn's
--   length and the orbit it leaves you on.
--
--   PLANNING A BURN, WITH THE KEYS. `N` enters PLAN mode, which is a mode precisely because
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
  --@header Maneuver node
  -- Width of the node gizmo's rings, in pixels (its stalks are the map's
  -- 1-pixel lines until the engine's line layer takes a width).
  --@range 1 4 --@units px
  gizmo_stroke = 1,
  -- Size of the node gizmo (disc, stalks, knobs, hit areas) × the design sizes.
  --@range 0.6 2.0
  gizmo_size = 1.0,
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
-- The map's two densities (docs/tracking-station.md §0): "chart" (M: the
-- legend, the conics, the node) or "station" (F2: the Tracking Station —
-- scripts/tracking_station.lua draws its icons, tags and panels in this pass).
mode = "chart"
-- The station's hooks, kept in one global table (update_map3d is near Lua's
-- upvalue ceiling): fn = the focus provider (this frame's point), ex/ey/ez =
-- the focus ease (an offset that decays to zero), last = last frame's focus.
ST = { fn = nil, ex = 0, ey = 0, ez = 0, last = nil, ease = false, ts = nil, miss = -10 }
local function station_ref()
  local t = ST.ts
  if t and t.valid ~= false then return t end
  if (time or 0) - ST.miss < 2.0 then return nil end
  t = findScript and findScript("tracking_station") or nil
  ST.ts = t
  if not t then ST.miss = time or 0 end
  return t
end
STATION_REF = station_ref
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
-- A node is { t0 = absolute sim time, pro, nor, rad = Δv m/s in the burn
-- frame at the node, locked, burned, mark = the gizmo's place until the next
-- walk }. The node is stored as a LIST (MNV.nodes, ordered by time) so that
-- several nodes (proposal F7) is a cap change and a loop; `mnv` is the one
-- being flown and edited: MNV.nodes[1].
local mnv = nil
-- The patched-conic walk is heavy (hundreds of two-body evals across SOI
-- changes), so it's recomputed at ~8 Hz and the resulting world polyline +
-- encounter markers are cached here and redrawn every frame (draw.line is
-- immediate mode). `traj_now` = the path you're on; `traj_mnv` = the post-burn
-- path (nil unless a node exists).
local traj_t = -10.0
local traj_now, traj_mnv = nil, nil

-- ── THE NODE, CLICK AND DRAG: the rules as numbers (deep-space proposal §7,
-- F1–F6, F8). Pure: no scene, no input — tests/smoke_mnvnode.lua holds them.
MNV = {
  nodes = {},          -- every planned node, by time (MNV.CAP of them)
  CAP = 1,             -- one for now; several nodes (F7) raise it
  DRAG_K = 0.006,      -- Δv per pixel dragged along a handle, × orbital speed
  VORB_MIN = 50.0,     -- (m/s: the floor under that speed, so a crawl still edits)
  SCROLL_DV = 0.01,    -- Δv per wheel notch over a handle, × orbital speed
  SCROLL_T = 0.01,     -- node time per wheel notch over the disc, × the period
  LEAD_MIN = 1.0,      -- a node never slides closer than now + this (s)
  WARP_LEAD = 10.0,    -- warp to node lands this long before the burn starts (s)
  WARP_REAL = 0.5,     -- …stepping down while less than this much REAL time is left at a rung
}
-- Set (or clear, nil) THE node: the list and the edited node agree.
function mnvSet(n)
  mnv = n
  MNV.nodes = n and { n } or {}
  return n
end
-- How a drag speeds up the longer it goes (KSP's rule): ×1 for the first
-- half second, ×3 at 1 s, ×8 from 2 s — eased between, so the rate never jumps.
function MNV.ramp(held)
  held = held or 0
  if held <= 0.5 then return 1.0 end
  if held <= 1.0 then return 1.0 + (held - 0.5) * 4.0 end
  if held <= 2.0 then return 3.0 + (held - 1.0) * 5.0 end
  return 8.0
end
-- SHIFT halves, CTRL ×5 (both: ×2.5).
function MNV.mods(shift, ctrl)
  local k = 1.0
  if shift then k = k * 0.5 end
  if ctrl then k = k * 5.0 end
  return k
end
-- Δv for `px` pixels dragged along a handle, `held` s into the drag.
function MNV.dragDv(px, held, vorb, k)
  return px * MNV.DRAG_K * math.max(vorb or 0, MNV.VORB_MIN) * MNV.ramp(held) * (k or 1.0)
end
function MNV.scrollDv(notches, vorb, k)
  return notches * MNV.SCROLL_DV * math.max(vorb or 0, MNV.VORB_MIN) * (k or 1.0)
end
-- A node time kept ahead of now (and inside the path it slides on).
function MNV.clampT(t, now, tmax)
  if tmax and t > tmax then t = tmax end
  return math.max(t, now + MNV.LEAD_MIN)
end
-- The burn frame at a state relative to its body: prograde, orbit normal,
-- radial out (each a unit; world axes, since celestial frames only translate).
function MNV.basis(rx, ry, rz, vx, vy, vz)
  local px, py, pz = norm(vx, vy, vz)
  local nx, ny, nz = norm(cross(rx, ry, rz, vx, vy, vz))
  local ox, oy, oz = cross(px, py, pz, nx, ny, nz)
  return { px = px, py = py, pz = pz, nx = nx, ny = ny, nz = nz, rx = ox, ry = oy, rz = oz }
end
-- Δv components in a frame → the world vector, and back. A node slid along
-- its orbit keeps its components, so the burn turns with the new frame.
function MNV.burnWorld(B, pro, nor, rad)
  return B.px * pro + B.nx * nor + B.rx * rad,
         B.py * pro + B.ny * nor + B.ry * rad,
         B.pz * pro + B.nz * nor + B.rz * rad
end
function MNV.components(B, x, y, z)
  return B.px * x + B.py * y + B.pz * z, B.nx * x + B.ny * y + B.nz * z, B.rx * x + B.ry * y + B.rz * z
end
-- The conic a state is on: periapsis radius, apoapsis radius (nil on an
-- escape) and the period (nil on an escape).
function MNV.conic(rx, ry, rz, vx, vy, vz, mu)
  if not mu or mu <= 0 then return nil end
  local r = math.sqrt(rx * rx + ry * ry + rz * rz)
  if r < 1e-6 then return nil end
  local v2 = vx * vx + vy * vy + vz * vz
  local hx, hy, hz = cross(rx, ry, rz, vx, vy, vz)
  local h2 = hx * hx + hy * hy + hz * hz
  local en = v2 / 2 - mu / r
  local e = math.sqrt(math.max(0, 1 + 2 * en * h2 / (mu * mu)))
  local p = h2 / mu
  local pe = p / (1 + e)
  if e >= 1 or en >= 0 then return pe, nil, nil end
  local a = -mu / (2 * en)
  return pe, p / (1 - e), 2 * math.pi * math.sqrt(a * a * a / mu)
end
-- ±n orbits (F6): the node one period later or earlier, or nil + why.
function MNV.shiftOrbits(t0, period, n, now)
  if not period or period ~= period or period <= 0 or period == math.huge then
    return nil, "not on a closed orbit"
  end
  local t = t0 + n * period
  if t < now + MNV.LEAD_MIN then return nil, "less than an orbit away" end
  return t
end
-- Seconds at full throttle for `dv` on the engines lit now (the flight HUD's
-- Tsiolkovsky: exhaust speed = thrust over the propellant's mass flow).
-- `t` is the vessel's telemetry (thrust, mass, fuel_t, burn_s); nil = no engine.
function MNV.burnSecs(t, dv)
  local F, m = t and t.thrust or 0, t and t.mass or 0
  if F <= 0 or m <= 0 then return nil end
  local ve = ((t.fuel_t or 0) > 0 and (t.burn_s or 0) > 0) and F * t.burn_s / t.fuel_t or nil
  if ve and ve > 1 then return m * ve / F * (1 - math.exp(-dv / ve)) end
  return dv * m / F
end
-- Warp to node (F8) lands here: half the burn before the node, less a margin.
-- `lead`: the margin (s), MNV.WARP_LEAD unless a level-3 Pilot is aboard (J4).
function MNV.landing(t0, burn, lead)
  return t0 - (burn or 0) / 2 - (lead or MNV.WARP_LEAD)
end
-- The rung of the warp ladder to sit on with `remaining` sim seconds to go:
-- the highest one (under `cap`) that still has more than WARP_REAL seconds of
-- real time left at it (and four frames of `dt`). 1 means "arrived: stop".
function MNV.warpStep(remaining, steps, cap, dt)
  local best = 1
  local real = math.max(MNV.WARP_REAL, 4 * (dt or 0))
  for _, w in ipairs(steps) do
    if w <= (cap or math.huge) + 0.001 and remaining > w * real and w > best then best = w end
  end
  return best
end
-- The point of segment a→b nearest to m, on the screen: → u (0..1), d².
function MNV.segNearest(ax, ay, bx, by, mx, my)
  local dx, dy = bx - ax, by - ay
  local l2 = dx * dx + dy * dy
  local u = 0
  if l2 > 1e-9 then u = math.max(0, math.min(1, ((mx - ax) * dx + (my - ay) * dy) / l2)) end
  local qx, qy = ax + dx * u - mx, ay + dy * u - my
  return u, qx * qx + qy * qy
end
-- "+2:14", "+1:02:09", "−0:03" — a lead a person reads.
function MNV.clock(s)
  local sg = s < 0 and "−" or "+"
  s = math.floor(math.abs(s) + 0.5)
  local h, m, sec = math.floor(s / 3600), math.floor(s / 60) % 60, s % 60
  if h > 0 then return string.format("%s%d:%02d:%02d", sg, h, m, sec) end
  return string.format("%s%d:%02d", sg, m, sec)
end

-- THE GIZMO's look, in one place (screen pixels at the 720-line design
-- height; the map scales them with the interface). `stroke` is the line and
-- ring width: 1 until the engine's line layer takes a width (card EN6), then
-- one number to raise. Colours are the Flight Hardware palette, one per axis.
GIZMO = {
  disc = 12, stalk = 36, knob = 9, hit = 11, line_hit = 24, stroke = 1,
  pro = { 0.97, 0.55, 0.22 },   -- accent: prograde / retrograde
  nor = { 0.66, 0.80, 0.86 },   -- signal: normal / anti-normal
  rad = { 0.55, 0.85, 0.42 },   -- done: radial out / in
  ink = { 0.92, 0.89, 0.81 }, dim = { 0.56, 0.55, 0.50 },
  phos = { 0.64, 0.93, 0.56 }, phosDim = { 0.38, 0.56, 0.34 },
  sunken = { 0.028, 0.040, 0.032 }, bezel = { 0.70, 0.67, 0.59 },
}
-- The six handles: which component, which way, which colour, filled or open.
GIZMO.HANDLES = {
  { id = "pro+", comp = "pro", sign = 1, col = "pro", fill = true, name = "prograde" },
  { id = "pro-", comp = "pro", sign = -1, col = "pro", fill = false, name = "retrograde" },
  { id = "nor+", comp = "nor", sign = 1, col = "nor", fill = true, name = "normal" },
  { id = "nor-", comp = "nor", sign = -1, col = "nor", fill = false, name = "anti-normal" },
  { id = "rad+", comp = "rad", sign = 1, col = "rad", fill = true, name = "radial out" },
  { id = "rad-", comp = "rad", sign = -1, col = "rad", fill = false, name = "radial in" },
}

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
  -- `ta` is the ABSOLUTE sim instant of point 0 (the frozen ref's), so a pick
  -- on the path reads an exact time, never one a recompute stale.
  traj_now = { rpts = rpts, anch = anch, enc = enc, t0 = toff, ta = traj_ref.t, step = span / segs }

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
    -- (MNV.basis: the gizmo's six handles are drawn along these same axes)
    local B = MNV.basis(nrx, nry, nrz, nvx, nvy, nvz)
    local bx, by, bz = MNV.burnWorld(B, mnv.pro, mnv.nor, mnv.rad)
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
    -- For the node's readout (F5): the orbit the burn leaves you on, about the
    -- node's own body; and the period of the orbit it sits on (±1 orbit, F6).
    local pe_r, ap_r = MNV.conic(nrx, nry, nrz, bvx, bvy, bvz, ns.mu)
    local _, _, pre_T = MNV.conic(nrx, nry, nrz, nvx, nvy, nvz, ns.mu)
    local nrad = (bodies[ndb] and bodies[ndb].radius) or 0
    traj_mnv = {
      rpts = mrpts, anch = manch, enc = menc,
      m_anchor = ndb, m_rx = nrx, m_ry = nry, m_rz = nrz, -- node marker (its body's frame)
      bx = bx, by = by, bz = bz, B = B,
      dv = dv, t0 = t_node, step = mspan / segs,
      tabs = mnv.t0, node = mnv,    -- the node and the instant this walk was made for
      vnode = math.sqrt(nvx * nvx + nvy * nvy + nvz * nvz), period = pre_T,
      pe = pe_r and (pe_r - nrad), ap = ap_r and (ap_r - nrad),
      body = bodies[ndb] and bodies[ndb].name,
    }
  else
    traj_mnv = nil
  end
end

-- ── THE NODE GIZMO, each frame ──────────────────────────────────────────────
-- Hover an orbit and a soft ring shows where a click would put a node, with
-- its time; a click places one (no PLAN mode needed: a click on a line is
-- nothing the stick uses). The node is a disc with six handles on stalks in
-- the burn frame there: drag a handle to change Δv along it, drag the disc to
-- slide the node along its orbit, the wheel over either for fine steps,
-- right-click for the menu. Everything is placed against THIS frame's body
-- read (the node is stored relative to its body, never as a world point) and
-- picked with the very projection it is drawn with, so the gizmo stays on the
-- line while the planet carries it. Globals, not locals: update_map3d is near
-- the upvalue ceiling.
GZ = { hot = nil, drag = nil, lmb = false, rmb = nil, geo = nil, hover = nil,
       note = nil, note_t = -10, mx = 0, my = 0 }
-- Published: while true, vessel_controller keeps SHIFT/CTRL (the drag's fine
-- and coarse keys) off the throttle — the cursor is on the node or dragging it.
gizmoBusy = false

-- The nearest point of a cached path to a screen pixel, segment by segment
-- (each point at its anchor body's LIVE position: the path as drawn), or nil
-- past `maxpx`. The path runs 1.6 orbits, so its loops lie on each other on
-- the screen: of the points within a pixel and a half of the nearest, the
-- EARLIEST wins (the orbit you mean is the next one), and `tlo`..`thi` (sim
-- times, optional) keep a slide on the loop it is on. → { t = absolute sim
-- time, anchor, rx, ry, rz (body-relative), dx, dy, dz (the chord's
-- direction: the motion there), d = pixels }.
local PICK_U, PICK_D = {}, {}   -- per-segment scratch, reused every frame
local function pick_path(traj, bodies, mx, my, maxpx, tlo, thi)
  if not traj or not camera or not camera.exists() then return nil end
  local n = math.floor(#traj.rpts / 3)
  local ta, step = traj.ta or 0, traj.step or 0
  local dmin = maxpx and maxpx * maxpx or math.huge
  local pa, psx, psy, pon = nil, 0, 0, false
  local R, A = traj.rpts, traj.anch
  for k = 0, n - 1 do
    local a = A[k + 1]
    local wx, wy, wz = rel_world(bodies, a, R[k * 3 + 1], R[k * 3 + 2], R[k * 3 + 3])
    local sx, sy, on = 0, 0, false
    if wx then
      local _d
      sx, sy, _d, on = camera.worldToScreen(wx, wy, wz)
    end
    PICK_D[k] = nil
    if on and pon and pa == a then
      local t1 = ta + k * step   -- the segment spans t1 − step .. t1
      if (not tlo or t1 >= tlo) and (not thi or t1 - step <= thi) then
        local u, d2 = MNV.segNearest(psx, psy, sx, sy, mx, my)
        PICK_U[k - 1], PICK_D[k - 1] = u, d2
        if d2 < dmin then dmin = d2 end
      end
    end
    pa, psx, psy, pon = a, sx, sy, on
  end
  PICK_D[n - 1] = nil
  if dmin == math.huge or (maxpx and dmin > maxpx * maxpx) then return nil end
  local lim = (math.sqrt(dmin) + 1.5) ^ 2
  local bk, bu, bd = nil, 0, 0
  for k = 0, n - 2 do
    local d2 = PICK_D[k]
    if d2 and d2 <= lim and (not maxpx or d2 <= maxpx * maxpx) then bk, bu, bd = k, PICK_U[k], d2 break end
  end
  if not bk then return nil end
  local i0, i1 = bk * 3, (bk + 1) * 3
  local dx, dy, dz = R[i1 + 1] - R[i0 + 1], R[i1 + 2] - R[i0 + 2], R[i1 + 3] - R[i0 + 3]
  return { t = (traj.ta or 0) + (bk + bu) * (traj.step or 0), anchor = A[bk + 1],
           rx = R[i0 + 1] + dx * bu, ry = R[i0 + 2] + dy * bu, rz = R[i0 + 3] + dz * bu,
           dx = dx, dy = dy, dz = dz, d = math.sqrt(bd) }
end
-- The last instant a cached path reaches (a node can't slide past it).
local function path_end(traj)
  if not traj then return nil end
  return (traj.ta or 0) + (math.floor(#traj.rpts / 3) - 1) * (traj.step or 0)
end

-- Where the node is drawn this frame, and its burn frame: the walk's own
-- node state once it is for this node at this instant, else the point the
-- click or the slide put it on (until the next walk catches up).
local function node_place(bodies)
  local m = mnv
  if not m then return nil end
  local T = traj_mnv
  if T and T.node == m and T.tabs == m.t0 and T.B then
    local x, y, z = rel_world(bodies, T.m_anchor, T.m_rx, T.m_ry, T.m_rz)
    if x then m.mark = nil return x, y, z, T.B end
  end
  local K = m.mark
  if K then
    local x, y, z = rel_world(bodies, K.anchor, K.rx, K.ry, K.rz)
    if x then return x, y, z, K.B end
  end
  if T and T.node == m and T.B then
    local x, y, z = rel_world(bodies, T.m_anchor, T.m_rx, T.m_ry, T.m_rz)
    if x then return x, y, z, T.B end
  end
  return nil
end
local function gz_axis(B, comp)
  if comp == "pro" then return B.px, B.py, B.pz end
  if comp == "nor" then return B.nx, B.ny, B.nz end
  return B.rx, B.ry, B.rz
end
-- This frame's gizmo on the screen: the disc, and each handle's knob at the
-- end of its stalk (a stalk is GIZMO.stalk px long wherever the node is).
local function gizmo_geo(bodies, px_at, lk)
  if not (camera and camera.worldToScreen) then return nil end
  local x, y, z, B = node_place(bodies)
  if not (x and B) then return nil end
  local sx, sy, _d, on = camera.worldToScreen(x, y, z)
  if not on then return nil end
  local sz = (params.gizmo_size or 1.0) * lk
  local L = px_at(x, y, z, GIZMO.stalk * sz)
  local G = { x = x, y = y, z = z, sx = sx, sy = sy, B = B, sz = sz, h = {} }
  for i, H in ipairs(GIZMO.HANDLES) do
    local ax, ay, az = gz_axis(B, H.comp)
    local ex, ey, ez = x + ax * H.sign * L, y + ay * H.sign * L, z + az * H.sign * L
    local kx, ky, _k, kon = camera.worldToScreen(ex, ey, ez)
    G.h[i] = { H = H, ex = ex, ey = ey, ez = ez, kx = kx, ky = ky, on = kon == true }
  end
  return G
end
-- What of the gizmo is under a screen pixel: "disc", a handle's index, or nil.
-- The nearest wins, the disc by a few pixels: a handle seen nearly end-on
-- (its axis toward the camera) sits close to the disc and must stay reachable
-- on its own side, while the disc's middle is always the disc.
local function gizmo_hit(G, mx, my)
  if not G then return nil end
  local best, bd = nil, GIZMO.hit * G.sz
  local dd = math.sqrt((mx - G.sx) ^ 2 + (my - G.sy) ^ 2)
  if dd <= (GIZMO.disc * 0.5 + 3) * G.sz then best, bd = "disc", dd - 3 * G.sz end
  for i, h in ipairs(G.h) do
    if h.on then
      local d = math.sqrt((mx - h.kx) ^ 2 + (my - h.ky) ^ 2)
      if d < bd then best, bd = i, d end
    end
  end
  return best
end
-- (targeting.lua asks before it opens a world's menu for the same right-click)
function mnvAt(sx, sy)
  return map_view and gizmo_hit(GZ.geo, sx, sy) ~= nil or false
end
local function gz_note(msg)
  GZ.note, GZ.note_t = msg, time or 0
end
-- A cached findScript (a scene scan: a miss is asked again after 2 s).
local gz_refs, gz_miss = {}, {}
local function gz_ref(kind)
  local r = gz_refs[kind]
  if not (r and r.valid ~= false) then
    if (time or 0) - (gz_miss[kind] or -10) < 2.0 then return nil end
    r = findScript and findScript(kind) or nil
    gz_refs[kind] = r
    if not r then gz_miss[kind] = time or 0 end
  end
  return r
end
-- The node's period (the orbit it sits on) and the orbital speed there.
local function node_period(m, oe)
  local T = traj_mnv
  if T and T.node == m and T.period then return T.period end
  return oe and oe.period or nil
end
local function node_vorb(m, vref)
  local T = traj_mnv
  if T and T.node == m and T.vnode then return T.vnode end
  return vref
end
-- Put the node at a picked point of the path (a click, or the slide).
local function node_to(m, pk, now, tmax)
  local t = MNV.clampT(pk.t, now, tmax)
  m.t0, m.burned = t, 0.0
  if t == pk.t then
    m.mark = { anchor = pk.anchor, rx = pk.rx, ry = pk.ry, rz = pk.rz,
               B = MNV.basis(pk.rx, pk.ry, pk.rz, pk.dx, pk.dy, pk.dz) }
  else
    m.mark = nil  -- clamped off the cursor: the next walk places it
  end
end

-- Input for the gizmo and the path, then this frame's geometry for drawing.
-- `vref` = the craft's orbital speed now, `oe` its conic.
function mnvFrame(bodies, px_at, lk, oe, vref)
  local mx, my = input.mouse()
  local cm = gz_ref("context_menu")
  local ui_busy = (cm and cm.ownsMouse and cm.ownsMouse()) or false
  if not ui_busy and mode == "station" then
    local ts = STATION_REF()
    ui_busy = (ts and ts.pointerBusy and ts.pointerBusy()) or false
  end
  local now = space.time()
  local G = gizmo_geo(bodies, px_at, lk)
  local hot = (not ui_busy) and gizmo_hit(G, mx, my) or nil
  local lmb = input.button(0) == true
  local rmb = input.button(1) == true
  local press = lmb and not GZ.lmb
  GZ.lmb = lmb
  local m = mnv
  local tmax = path_end(traj_now)
  if GZ.drag and (not lmb or not m) then GZ.drag = nil end
  local D = GZ.drag
  -- the soft ring on the orbit under the cursor (where a click plans a burn)
  GZ.hover = nil
  if not D and not hot and not ui_busy and not rmb then
    -- (only ahead of the craft: the path starts a little in the past)
    GZ.hover = pick_path(traj_now, bodies, mx, my, GIZMO.line_hit * lk, now + MNV.LEAD_MIN, nil)
  end
  if press and not ui_busy then
    if hot and m and m.locked then
      gz_note("LOCKED · right-click to unlock")
    elseif hot == "disc" then
      GZ.drag = { kind = "slide", t = time }
    elseif hot then
      local h = G.h[hot]
      local ddx, ddy = h.kx - G.sx, h.ky - G.sy
      local l = math.sqrt(ddx * ddx + ddy * ddy)
      if l < 1 then ddx, ddy, l = 0, -1, 1 end
      GZ.drag = { kind = "dv", i = hot, H = h.H, t = time, mx = mx, my = my, dx = ddx / l, dy = ddy / l }
    elseif GZ.hover then
      -- a click on the orbit: the node goes there (one node for now: a click
      -- with one planned moves it, its Δv kept)
      if not m then m = mnvSet({ t0 = now, pro = 0.0, nor = 0.0, rad = 0.0, burned = 0.0 }) end
      if m.locked then gz_note("LOCKED · right-click the node to unlock")
      else node_to(m, GZ.hover, now, tmax) end
      GZ.hover = nil
    end
    D = GZ.drag
  end
  if D and m then
    if D.kind == "dv" then
      -- along the handle's screen direction, read again each frame (the view
      -- can turn); a handle seen end-on keeps the direction it had
      local h = G and G.h[D.i]
      if h and h.on then
        local ddx, ddy = h.kx - G.sx, h.ky - G.sy
        local l = math.sqrt(ddx * ddx + ddy * ddy)
        if l > 4 then D.dx, D.dy = ddx / l, ddy / l end
      end
      local px = (mx - D.mx) * D.dx + (my - D.my) * D.dy
      D.mx, D.my = mx, my
      if px ~= 0 then
        local k = MNV.mods(input.key("shift"), input.key("ctrl"))
        m[D.H.comp] = m[D.H.comp] + D.H.sign * MNV.dragDv(px, time - D.t, node_vorb(m, vref), k)
      end
    elseif D.kind == "slide" then
      -- within half an orbit of where the node is: it slides along the loop
      -- it sits on, never jumping to the same spot one orbit on (or back
      -- across the craft onto the end of the path)
      local T = node_period(m, oe) or (tmax and (tmax - now) / 1.6) or 600
      local pk = pick_path(traj_now, bodies, mx, my, nil, m.t0 - 0.5 * T, m.t0 + 0.5 * T)
      if pk then node_to(m, pk, now, tmax) end
    end
  end
  -- the wheel over the gizmo is the node's, not the zoom's (update_map3d
  -- reads GZ.hot from the frame before)
  local sc = input.scroll()
  if sc and sc ~= 0 and hot and m and not D then
    if m.locked then
      gz_note("LOCKED · right-click to unlock")
    elseif hot == "disc" then
      local T = node_period(m, oe) or (tmax and (tmax - now) / 1.6)
      if T then
        m.t0, m.burned, m.mark = MNV.clampT(m.t0 + sc * MNV.SCROLL_T * T, now, nil), 0.0, nil
      end
    else
      local H = GIZMO.HANDLES[hot]
      local k = MNV.mods(input.key("shift"), input.key("ctrl"))
      m[H.comp] = m[H.comp] + H.sign * MNV.scrollDv(sc, node_vorb(m, vref), k)
    end
  end
  -- a right-button TAP on the node opens its menu (a held or dragged right
  -- button is still the view's). Pressed where the cursor was the frame
  -- before: the press itself locks the pointer for the view.
  local R = GZ.rmb
  if rmb and not R then
    GZ.rmb = { x = GZ.mx, y = GZ.my, t = time, moved = 0, on = GZ.hot ~= nil and m ~= nil }
  elseif rmb and R then
    local dx, dy = input.mouse_delta()
    R.moved = R.moved + math.abs(dx or 0) + math.abs(dy or 0)
  elseif R then
    GZ.rmb = nil
    if R.on and time - R.t <= 0.35 and R.moved <= 6 and mnv then mnvMenu(R.x, R.y) end
  end
  GZ.mx, GZ.my = mx, my
  GZ.hot = hot
  gizmoBusy = GZ.drag ~= nil or hot ~= nil
  -- this frame's geometry after the edits (a slide moved the disc)
  GZ.geo = gizmo_geo(bodies, px_at, lk)
  GZ.t = time   -- (probes: which frame the geometry is from)
end

-- The node's CRT tag (F5) and the gizmo, in the map's pass. `vc` = the craft
-- flown (its telemetry gives the burn time).
function mnvDraw(bodies, px_at, lk, vc)
  local s = (params.gizmo_stroke or 1)
  local now = space.time()
  local hidden = cineHidden()
  -- the hover ring and its time tag
  local Hv = GZ.hover
  local cm0 = gz_ref("context_menu")
  if cm0 and cm0.open then Hv = nil end   -- (not over an open menu)
  if Hv and not hidden then
    local wx, wy, wz = rel_world(bodies, Hv.anchor, Hv.rx, Hv.ry, Hv.rz)
    local sx, sy, _d, on
    if wx then sx, sy, _d, on = camera.worldToScreen(wx, wy, wz) end
    if on then
      local c = GIZMO.nor
      draw.circleOutline(sx, sy, 8 * lk, c[1], c[2], c[3], 0.85, s)
      local txt = MNV.clock(Hv.t - now)
      local fs = 12 * lk
      local w = (#txt * 0.62 + 1) * fs
      draw.rect(sx + 10 * lk, sy - 24 * lk, w, fs * 1.45, 0.028, 0.040, 0.032, 0.85, 2 * lk)
      draw.text(sx + 10 * lk + fs * 0.5, sy - 24 * lk + fs * 0.18, txt, fs, c[1], c[2], c[3], 1.0, "left", "fonts/SolarMono.ttf")
    end
  end
  local G = GZ.geo
  local m = mnv
  if not (G and m) then return end
  local a = m.locked and 0.45 or 1.0
  -- the stalks: world lines from the node along the burn frame (drawn
  -- through the planet: the gizmo is a control, it is never hidden)
  depth(false)
  for _, h in ipairs(G.h) do
    local c = GIZMO[h.H.col]
    draw.line(G.x, G.y, G.z, h.ex, h.ey, h.ez, c[1], c[2], c[3], a)
  end
  if hidden then return end
  -- the knobs: filled for the + way, open for the − way; the hot one larger
  local D = GZ.drag
  for i, h in ipairs(G.h) do
    if h.on then
      local c = GIZMO[h.H.col]
      local hi = (GZ.hot == i) or (D and D.i == i)
      local r = GIZMO.knob * 0.5 * G.sz * (hi and 1.35 or 1.0)
      draw.circle(h.kx, h.ky, r + 1.5 * G.sz, 0.0, 0.0, 0.0, 0.55 * a)
      if h.H.fill then
        draw.circle(h.kx, h.ky, r, c[1], c[2], c[3], a)
      else
        draw.circleOutline(h.kx, h.ky, r - s * 0.5, c[1], c[2], c[3], a, s + 1)
      end
      if hi then draw.circleOutline(h.kx, h.ky, r + 2.5 * G.sz, 1.0, 0.80, 0.58, 0.9, s) end
    end
  end
  -- the disc
  local rd = GIZMO.disc * 0.5 * G.sz
  local ink = GIZMO.ink
  draw.circle(G.sx, G.sy, rd + 1.5 * G.sz, 0.0, 0.0, 0.0, 0.6)
  draw.circle(G.sx, G.sy, rd, 0.028, 0.040, 0.032, 0.9)
  draw.circleOutline(G.sx, G.sy, rd, ink[1], ink[2], ink[3], a, s + 1)
  local ac = GIZMO.pro
  draw.circle(G.sx, G.sy, rd * 0.35, ac[1], ac[2], ac[3], a)
  if GZ.hot == "disc" or (D and D.kind == "slide") then
    draw.circleOutline(G.sx, G.sy, rd + 3 * G.sz, 1.0, 0.80, 0.58, 0.9, s)
  end
  -- THE READOUT (F5): a small CRT beside the node (not while a menu is up:
  -- screen drawing lands over the interface, and the node's menu reads the
  -- same numbers)
  local cm = gz_ref("context_menu")
  if cm and cm.open then return end
  local dv = math.sqrt(m.pro ^ 2 + m.nor ^ 2 + m.rad ^ 2)
  local lead = m.t0 - now
  local tb = vc and MNV.burnSecs(vc.tele, dv)
  local T = traj_mnv
  local orbit = "—"
  if T and T.node == m then
    if T.pe and T.ap then
      orbit = string.format("Pe %s  Ap %s", (T.pe < 0 and "−" or "") .. fmt_dist(T.pe), fmt_dist(T.ap))
    elseif T.pe then
      orbit = string.format("Pe %s  ESCAPE", (T.pe < 0 and "−" or "") .. fmt_dist(T.pe))
    end
  end
  local burn
  if dv < 0.05 then burn = "—" elseif tb then burn = MNV.clock(tb):sub(2) else burn = "no engine" end
  local rows = {
    { "ΔV", string.format("%.1f m/s", dv) },
    { "NODE", (lead >= 0 and "T−" or "T+") .. MNV.clock(lead):sub(2) },
    { "BURN", burn },
    { "", orbit },
  }
  if m.locked then rows[#rows + 1] = { "", "LOCKED" } end
  if GZ.note and (time or 0) - GZ.note_t < 2.5 then rows[#rows + 1] = { "", GZ.note } end
  local fs = 11.5 * lk
  local rh = fs * 1.3
  local W, Hh = 168 * lk, rh * #rows + 8 * lk
  local x0, y0 = G.sx + 18 * G.sz, G.sy + 14 * G.sz
  if camera.screenRect then
    local vx, vy, vw, vh = camera.screenRect()
    if vw and vw > 0 then
      if x0 + W > vx + vw - 4 then x0 = G.sx - 18 * G.sz - W end
      if y0 + Hh > vy + vh - 4 then y0 = G.sy - 14 * G.sz - Hh end
    end
  end
  local bz, sk = GIZMO.bezel, GIZMO.sunken
  draw.rect(x0 - 1.5 * lk, y0 - 1.5 * lk, W + 3 * lk, Hh + 3 * lk, bz[1] * 0.5, bz[2] * 0.5, bz[3] * 0.5, 0.9, 3 * lk)
  draw.rect(x0, y0, W, Hh, sk[1], sk[2], sk[3], 0.94, 2 * lk)
  local ph, pd = GIZMO.phos, GIZMO.phosDim
  for i, r in ipairs(rows) do
    local yy = y0 + 4 * lk + (i - 1) * rh
    if r[1] ~= "" then
      draw.text(x0 + 6 * lk, yy, r[1], fs * 0.85, pd[1], pd[2], pd[3], a, "left", "fonts/SolarMono.ttf")
      draw.text(x0 + 46 * lk, yy, r[2], fs, ph[1], ph[2], ph[3], a, "left", "fonts/SolarMono.ttf")
    else
      draw.text(x0 + 6 * lk, yy, r[2], fs, ph[1], ph[2], ph[3], a, "left", "fonts/SolarMono.ttf")
    end
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
  local typing_ = mode == "station" and ST.ts and ST.ts.valid ~= false and ST.ts.typing and ST.ts.typing()
  if input.pressed("tab") and not typing_ then
    ST.fn = nil
    map_focus = map_focus % nf + 1
    zoom_target = nil -- re-fit, and ease there from where the view is now
    map_offx, map_offy, map_offz = 0.0, 0.0, 0.0
  end
  if map_focus > nf then map_focus = 1 end
  if not typing_ then
    if input.pressed("1") then map_show.orbits = not map_show.orbits end
    if input.pressed("2") then map_show.soi = not map_show.soi end
    if input.pressed("3") then map_show.markers = not map_show.markers end
    if input.pressed("4") then map_show.links = not map_show.links end
  end

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
  local sfx_, sfy_, sfz_, sfn_ = nil, nil, nil, nil
  if map_focus == 1 and ST.fn and mode == "station" then sfx_, sfy_, sfz_, sfn_ = ST.fn(bodies) end
  if sfx_ then
    focus = { x = sfx_, y = sfy_, z = sfz_ }
    fname = sfn_ or "SELECTED"
    fradius = 6
  elseif map_focus == 1 and focus_override then
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
  -- The station's focus EASES to a new selection: the jump becomes an offset
  -- (this frame's two points) that decays to nothing (rule 7: smooth the
  -- offset, never a world point).
  local ek = math.exp(-7 * dt)
  ST.ex, ST.ey, ST.ez = ST.ex * ek, ST.ey * ek, ST.ez * ek
  if ST.ease and ST.last then
    ST.ex, ST.ey, ST.ez = ST.last.x - focus.x, ST.last.y - focus.y, ST.last.z - focus.z
    -- (a jump across worlds is a cut, not a glide: rule 7's snap)
    if math.sqrt(ST.ex ^ 2 + ST.ey ^ 2 + ST.ez ^ 2) > (map_zoom or 1e9) * 4 then ST.ex, ST.ey, ST.ez = 0, 0, 0 end
  end
  ST.ease = false
  if math.abs(ST.ex) + math.abs(ST.ey) + math.abs(ST.ez) > 1e-3 then
    focus = { x = focus.x + ST.ex, y = focus.y + ST.ey, z = focus.z + ST.ez, name = focus.name, radius = focus.radius,
              soi = focus.soi, mu = focus.mu }
  end
  ST.last = { x = focus.x, y = focus.y, z = focus.z }
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
  -- (the wheel over the node's gizmo is the node's: mnvFrame, GZ.hot)
  local st_busy = mode == "station" and ST.ts and ST.ts.valid ~= false and ST.ts.ownsPointer and ST.ts.ownsPointer()
  if sc and sc ~= 0 and not GZ.hot and not st_busy then zoom_target = zoom_target * math.exp(-sc * 0.12) end
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
  -- (and the Tracking Station's plates, in its mode: draw.* paints over the UI)
  if mode == "station" then
    local ts = station_ref()
    if ts and ts.panelRects then
      for _, r in ipairs(ts.panelRects()) do blocked[#blocked + 1] = { r[1] - 4, r[2] - 4, r[3] + 8, r[4] + 8 } end
    end
  end
  -- (and an open right-click menu: a world's tag drew over its rows)
  do
    local cm = gz_ref("context_menu")
    local x, y, w, h = nil, nil, nil, nil
    if cm and cm.open and cm.screenRect then x, y, w, h = cm.screenRect() end
    if x then blocked[#blocked + 1] = { x - 6, y - 6, w + 12, h + 12 } end
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
  local picked_ = focus_override
  -- (In STATION mode the station draws the craft's lines itself, only the
  -- ones that matter: tracking_station.lua draw_tracks.)
  if mode ~= "station" then drawCraftTracks(craft_flying and vc or nil, picked_, px_at, label, lk, map_show) end
  if map_show.markers then
    draw_cross(node.x, node.y, node.z, px_at(node.x, node.y, node.z, 6), 0.6, 1.0, 0.7)
  end
  -- The COMMS NETWORK: every craft, the ground station, and every usable link,
  -- coloured by its strength (bright where a path home runs through it).
  mapComms(node, px_at, label, lk, map_show)
  -- THE TARGET (scripts/targeting.lua): its ring, distance, closest approach.
  if map_show.markers then mapTarget(node, px_at, label, lk) end
  if mode == "station" then
    local ts = station_ref()
    if ts and ts.drawMap then
      local sw_ = camera and camera.screenSize and select(1, camera.screenSize()) or 1280
      ts.drawMap({ bodies = bodies, px_at = px_at, ppu = ppu, cam = { x = ccx, y = ccy, z = ccz }, lk = lk,
                   look = { x = focus.x + map_offx, y = focus.y + map_offy, z = focus.z + map_offz }, tanh = TANH,
                   sw = sw_, sh = sh, placed = placed, blocked = blocked, yaw = map_yaw2, pitch = map_pitch2,
                   ppuFocus = ppu(map_zoom), show = map_show, drawTrack = drawTrack, TRAJ = TRAJ, label = label,
                   cine = cineHidden(), busy = gizmoBusy or (input.button(1) == true) })
    end
  end

  -- ---- maneuver-node planning (KSP) --------------------------------------
  -- Plan a burn and watch the resulting orbit — and where it drops you into
  -- another body's sphere of influence.
  local oe = db and space.elements(node.x, node.y, node.z, node.vx, node.vy, node.vz)
  if craft_flying and db and not node.grounded then
    local pidx = parent_indices(bodies)
    local vref = math.sqrt(node.vx ^ 2 + node.vy ^ 2 + node.vz ^ 2)
    local dvrate = math.max(0.5, vref * 0.12)
    MNV.lastPeriod = oe and oe.period or nil

    -- THE MOUSE plans burns in any mode: hover the orbit, click it, drag the
    -- node's handles and its disc (mnvFrame, above). PLAN mode is the keyboard
    -- way to do the same.
    mnvFrame(bodies, px_at, lk, oe, vref)

    -- PLANNING IS A MODE, and it has to be. A craft flies from the map — that
    -- is the point of flying on instruments — so the stick owns W/S/A/D/Q/E,
    -- and the burn tuner wants exactly those six keys. They cannot both have
    -- them. `N` swaps which one is listening, `planning` says so out loud (the
    -- vessel reads it and freezes), and the HUD prints the mode every frame.
    --
    -- The old answer was to give planning to the scout ship and nothing else,
    -- which meant the craft you actually built could never plan a burn.
    if planning then
      -- (A click on the orbit places or moves the node in this mode too:
      -- mnvFrame. The node is an ABSOLUTE instant, so it stays fixed on the
      -- orbit as you coast toward it instead of running ahead.)

      -- Entering the mode with nothing planned puts a node a quarter-orbit
      -- ahead, so plan mode always has something to tune. A mode that needs a
      -- second, undiscoverable action before it does anything is a mode people
      -- conclude is broken.
      if not mnv then
        local lead = (oe and oe.period and oe.period * 0.25) or 60.0
        mnvSet({ t0 = space.time() + lead, pro = 0.0, nor = 0.0, rad = 0.0, burned = 0.0 })
      end
      -- BACKSPACE abandons the burn outright (X only zeroes its ΔV).
      if input.pressed("backspace") then
        mnvDelete()
        planning = false
      end
      -- A locked node (its menu's Lock) holds still for the keys as for the mouse.
      if mnv and mnv.locked then
        if input.key("w") or input.key("s") or input.key("a") or input.key("d") or input.key("q")
          or input.key("e") or input.key("left") or input.key("right") or input.pressed("x") then
          GZ.note, GZ.note_t = "LOCKED · right-click to unlock", time
        end
      elseif mnv then
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
          mnv.mark = nil -- (the walk places it: the clicked point is behind it now)
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
    mnvSet(nil)
    traj_now, traj_mnv = nil, nil
    GZ.drag, GZ.geo, GZ.hover, GZ.hot, gizmoBusy = nil, nil, nil, nil, false
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
  if traj_mnv then
    if map_show.orbits then
      draw_rel_polyline(traj_mnv.rpts, traj_mnv.anch, bodies, 1.0, 0.55, 0.15, 0.95) -- post-burn (amber)
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
  -- The node's gizmo, its readout and the hover ring (drawn last: on top).
  if craft_flying then mnvDraw(bodies, px_at, lk, vc) end

  -- Focused-body info panel (the flight HUD stands down while the map is open).
  -- (In STATION mode the legend's keys live on the station's bottom strip.)
  if mode == "station" then
    if map_hud_t > -5 then set_hud(nil, nil); map_hud_t = -10.0 end
  elseif time - map_hud_t >= 0.1 then
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
        or  "Drag a handle  ΔV   ·   drag the node  slide it   ·   scroll on either  fine   ·   right-click it  menu   ·   N  keys"
    elseif craft_flying and not node.grounded then
      if traj_now and #traj_now.enc > 0 then
        local e = traj_now.enc[1]
        local verb = e.kind == "enter" and "ENCOUNTER" or (e.kind == "impact" and "IMPACT" or "SOI exit")
        lines[#lines + 1] = string.format("%s %s in %.0f s", verb, e.name, e.t)
      end
      lines[#lines + 1] = "Click an orbit to plan a burn  ·  drag its handles   ·   N  plan with the keys"
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

-- The target's marks, drawn by scripts/targeting.lua in this pass (global: no
-- upvalue for update_map3d; looked up again if the library respawns).
TGT_MAP = { ref = nil, miss = -10.0 }
function mapTarget(node, px_at, label, lk)
  local H = TGT_MAP
  if not (H.ref and H.ref.valid ~= false) then
    if (time or 0) - H.miss < 2.0 then return end
    H.ref = findScript and findScript("targeting") or nil
    if not H.ref then H.miss = time or 0 return end
  end
  if H.ref.drawMap then pcall(H.ref.drawMap, node, px_at, label, lk) end
end

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

-- THE BURN, for the flight view (flight_hud's maneuver readout, 2026-11-03:
-- "show the important things you need to know outside the map, like KSP").
-- burnApply(dvx, dvy, dvz) adds the Δv the engines gave the craft (world
-- vector, m/s, the HUD integrates thrust over mass); burnInfo() → nil, or
--   { dv = planned m/s, lead = s to the node, dir = world unit or nil,
--     left = m/s still to burn, lx/ly/lz = its world vector, done = 0..1 }
-- Editing the node (time or Δv) starts the count again.
local function burn_key(m)
  return string.format("%.3f|%.4f|%.4f|%.4f", m.t0, m.pro, m.nor, m.rad)
end
function burnApply(dvx, dvy, dvz)
  if not mnv then return end
  local k = burn_key(mnv)
  if mnv.apk ~= k then mnv.apk, mnv.ax, mnv.ay, mnv.az = k, 0, 0, 0 end
  mnv.ax, mnv.ay, mnv.az = mnv.ax + dvx, mnv.ay + dvy, mnv.az + dvz
end
-- (probes: plan a burn `lead` s ahead with these Δv components, m/s; the map
-- works its direction out on its next recompute while it is open)
function planBurn(lead, pro, nor, rad)
  mnvSet({ t0 = space.time() + (lead or 60), pro = pro or 0, nor = nor or 0, rad = rad or 0, burned = 0.0 })
  return true
end

-- ── the node's own actions (its right-click menu, F6; probes) ──────────────
-- Each answers ok [, why] as a context-menu action does.
function mnvDelete()
  if WARPTO then warpCancel("Warp to node · the node is gone") end
  mnvSet(nil)
  traj_mnv = nil
  GZ.drag = nil
  return true
end
function mnvZero()
  if not mnv then return false, "no burn planned" end
  if mnv.locked then return false, "the node is locked" end
  mnv.pro, mnv.nor, mnv.rad = 0.0, 0.0, 0.0
  return true
end
function mnvLock(on)
  if not mnv then return false, "no burn planned" end
  mnv.locked = on and true or nil
  GZ.drag = nil
  return true, on and "locked: the handles hold still" or "unlocked"
end
-- One orbit later (n = 1) or earlier (−1): the period of the orbit the node
-- sits on (the walk's), else the craft's own.
function mnvOrbits(n)
  if not mnv then return false, "no burn planned" end
  if mnv.locked then return false, "the node is locked" end
  local T = traj_mnv
  local per = (T and T.node == mnv and T.period) or MNV.lastPeriod
  local t, why = MNV.shiftOrbits(mnv.t0, per, n, space.time())
  if not t then return false, why end
  mnv.t0, mnv.burned, mnv.mark = t, 0.0, nil
  return true
end
-- Probes and the menu: the node as it is ({ t0, lead, pro, nor, rad, locked,
-- dv, period, pe, ap }), and the gizmo where it is drawn this frame ({ sx, sy,
-- handles = { [id] = { x, y, on } } }).
function mnvState()
  local m = mnv
  if not m then return nil end
  local T = traj_mnv
  local mine = T and T.node == m
  return { t0 = m.t0, lead = m.t0 - space.time(), pro = m.pro, nor = m.nor, rad = m.rad,
           locked = m.locked == true, dv = math.sqrt(m.pro ^ 2 + m.nor ^ 2 + m.rad ^ 2),
           period = mine and T.period or nil, pe = mine and T.pe or nil, ap = mine and T.ap or nil,
           fresh = mine and T.tabs == m.t0 or false, n = #MNV.nodes }
end
function mnvGizmo()
  local G = GZ.geo
  if not G then return nil end
  local out = { sx = G.sx, sy = G.sy, hot = GZ.hot, drag = GZ.drag and GZ.drag.kind or nil, handles = {}, t = GZ.t }
  for _, h in ipairs(G.h) do out.handles[h.H.id] = { x = h.kx, y = h.ky, on = h.on } end
  if GZ.hover then out.hover = { t = GZ.hover.t, d = GZ.hover.d } end
  return out
end
-- (probes: a body-relative node point, to check it rides the planet)
function mnvRel()
  local T = traj_mnv
  if not (T and mnv and T.node == mnv) then return nil end
  return { anchor = T.m_anchor, x = T.m_rx, y = T.m_ry, z = T.m_rz }
end

-- (tests: seat the cached paths the gizmo picks on, as a walk would leave them)
function mnvPaths(now_path, post_path)
  traj_now, traj_mnv = now_path, post_path
end

-- The right-click menu on the node (context_registry kind "mnvnode").
local function mnv_rows(_, _ctx)
  local m = mnv
  if not m then return {} end
  local unlocked = function() return mnv ~= nil and not mnv.locked end
  local out = {
    { type = "info", id = "dv", label = "ΔV", value = function()
        local n = mnv
        return n and string.format("%.1f m/s", math.sqrt(n.pro ^ 2 + n.nor ^ 2 + n.rad ^ 2)) or "—"
      end },
    { type = "info", id = "lead", label = "Node in", value = function()
        return mnv and MNV.clock(mnv.t0 - space.time()) or "—"
      end },
    { type = "action", id = "warp", label = WARPTO and "Stop the warp" or "Warp here", hint = "▸▸",
      act = function()
        if WARPTO then warpCancel("Warp to node · stopped") return true end
        return warpToNode()
      end },
    { type = "action", id = "orbit_up", label = "+1 orbit", keep = true, enabled = unlocked, why = "the node is locked",
      act = function() return mnvOrbits(1) end },
    { type = "action", id = "orbit_down", label = "−1 orbit", keep = true, enabled = unlocked, why = "the node is locked",
      act = function() return mnvOrbits(-1) end },
    { type = "action", id = "zero", label = "Zero ΔV", keep = true, enabled = unlocked, why = "the node is locked",
      act = function() return mnvZero() end },
    { type = "toggle", id = "lock", label = "Lock", on = function() return mnv ~= nil and mnv.locked == true end,
      act = function(want) return mnvLock(want) end },
    { type = "action", id = "delete", label = "Delete", danger = true, act = function() return mnvDelete() end },
  }
  return out, "MANEUVER NODE", "the planned burn"
end
local mnv_reg_with, mnv_reg_t = nil, -10.0
function mnvRegister(now)
  if mnv_reg_with and mnv_reg_with.valid ~= false then return true end
  -- (findScript is a scene scan: asked again at most every two seconds)
  if not now and (time or 0) - mnv_reg_t < 2.0 then return false end
  mnv_reg_t = time or 0
  local r = findScript and findScript("context_registry")
  if not (r and r.register) then return false end
  r.register("mnvnode", mnv_rows, { id = "orbit_map", order = 5 })
  mnv_reg_with = r
  return true
end
function mnvMenu(sx, sy)
  mnvRegister(true)
  local cm = findScript and findScript("context_menu")
  if not (cm and cm.openFor and cm.actorNow) then return false end
  local who = cm.actorNow()
  if not who then return false end
  return cm.openFor({ kind = "mnvnode", map = true, label = "Maneuver node" }, who, sx, sy)
end

-- ── WARP TO NODE (F8) ────────────────────────────────────────────────────────
-- Rails warp up the ladder and back down, to land half the burn and
-- MNV.WARP_LEAD seconds before the node. The craft's own warp rules hold:
-- refused while the throttle is open or anyone is on EVA in space, and any
-- control that drops the warp (the stick, the warp keys) ends it.
local WARP_LADDER = { 1, 5, 10, 50, 100, 1000, 10000 } -- vessel_controller's WARP_STEPS
WARPTO = nil   -- { t = landing sim time, set = the warp we last asked for, vc }
local function warp_vc()
  for _, s in ipairs(findScripts("vessel_controller")) do
    if s.piloting and s.node and s.node.valid then return s end
  end
  return nil
end
-- A notice said in the log and on the warp chip (vessel_controller.warpSay).
local function warp_say(vc, msg)
  if vc and vc.warpSay then pcall(vc.warpSay, msg) elseif log then log(msg) end
end
-- …and the running status, on the chip only, every frame. A warp request
-- lands on the next tick, and frames can outrun ticks: warp_chip calls any
-- drop nobody "said" in the frame it shows up "stopped by the physics", so
-- warp to node keeps saying what it is doing until the warp reads what it
-- asked for.
local function warp_status(msg)
  local wc = gz_ref("warp_chip")
  if wc and wc.say then pcall(wc.say, msg) end
end
-- End it: back to ×1, saying why until the warp reads ×1 (warpDrive).
function warpCancel(msg)
  local W = WARPTO
  if not W or W.settle then return end
  if space.warp() > 1.001 then space.warp(1) end
  msg = msg or "Warp to node · stopped"
  warp_say(W.vc, msg)
  WARPTO = { settle = true, msg = msg, vc = W.vc, t_end = (time or 0) + 1.0 }
end
-- Why the warp may not run now, or nil.
local function warp_refusal(vc)
  if not vc then return "nobody is flying" end
  if (vc.throttle or 0) > 0.01 then return "cut the throttle first" end
  local ok, eva = pcall(function() return vc.evaBlocksWarp and vc.evaBlocksWarp() end)
  if ok and eva then return "crew on EVA in space" end
  return nil
end
-- J4 L3, the Pilot's countdown: the margin warp to node lands at for craft
-- `vc` (crew.bestPerk "node_lead" over its crew) → s | nil (no such Pilot).
-- Asked by the HUD every frame, so it is looked up once a second.
NODE_LEAD = { t = -10, v = nil, id = nil }
function nodeLead(vc)
  vc = vc or warp_vc()
  if not vc then return nil end
  local L = NODE_LEAD
  local id = vc.node and vc.node.id
  if L.id == id and (time or 0) - L.t < 1.0 then return L.v end
  L.t, L.id, L.v = time or 0, id, nil
  local cl = findScript and findScript("crew")
  if cl and cl.bestPerk then
    local ok, v = pcall(cl.bestPerk, vc, "node_lead")
    if ok and type(v) == "number" then L.v = v end
  end
  return L.v
end

function warpToNode()
  local m = mnv
  if not m then return false, "no burn planned" end
  if WARPTO and not WARPTO.settle then return true end
  local vc = warp_vc()
  local why = warp_refusal(vc)
  if why then warp_say(vc, "Warp to node · " .. why) return false, why end
  local dv = math.sqrt(m.pro ^ 2 + m.nor ^ 2 + m.rad ^ 2)
  local land = MNV.landing(m.t0, MNV.burnSecs(vc.tele, dv) or 0, nodeLead(vc))
  if land - space.time() < 1.0 then
    warp_say(vc, "Warp to node · the burn starts in under " .. math.floor(MNV.WARP_LEAD) .. " s")
    return false, "the burn is about to start"
  end
  WARPTO = { t = land, node = m, set = space.warp(), vc = vc }
  warp_say(vc, string.format("Warp to node · %s to go", MNV.clock(land - space.time()):sub(2)))
  return true
end
-- Each frame, map open or not.
function warpDrive(dt)
  local W = WARPTO
  if not W then return end
  local cur = space.warp()
  -- settling at ×1 (arrived, or called off): say so until it reads ×1
  if W.settle then
    if cur > 1.001 and (time or 0) < W.t_end then
      space.warp(1)
      warp_status(W.msg)
      return
    end
    WARPTO = nil
    if W.final then warp_say(W.vc, W.final) end
    return
  end
  if mnv ~= W.node then warpCancel("Warp to node · the node is gone") return end
  if not (W.vc and W.vc.valid ~= false and W.vc.piloting) then warpCancel("Warp to node · stopped") return end
  local why = warp_refusal(W.vc)
  if why then warpCancel("Warp to node · " .. why) return end
  -- dropped by someone else (the stick, the , key, the galaxy's ceiling): a
  -- fall we did not ask for ends it — the warp is theirs now
  if W.last and cur < W.last - 0.001 and W.set >= W.last - 0.001 then
    WARPTO = nil
    warp_say(W.vc, "Warp to node · stopped")
    return
  end
  W.last = cur
  local cap = math.huge
  local gx = gz_ref("galaxy")
  if gx and gx.maxWarp then
    local ok, lim = pcall(gx.maxWarp)
    if ok and type(lim) == "number" then cap = lim end
  end
  local left = W.t - space.time()
  local w = MNV.warpStep(left, WARP_LADDER, cap, dt)
  if w <= 1 then
    -- arrived: ×1, then the burn's countdown in the log and on the chip
    if cur > 1.001 then space.warp(1) end
    local msg = string.format("Warp ×1 · the burn starts in %.0f s", left + MNV.WARP_LEAD)
    WARPTO = { settle = true, msg = msg, final = msg, vc = W.vc, t_end = (time or 0) + 1.0, arrived = true }
    warp_status(msg)
    if cur <= 1.001 then WARPTO = nil warp_say(W.vc, msg) end
    return
  end
  if math.abs(w - W.set) > 0.001 or math.abs(w - cur) > 0.001 then space.warp(w) end
  W.set = w
  warp_status(string.format("Warp to node · ×%d · %s to go", w, MNV.clock(left):sub(2)))
end
-- True while warping toward the node (not while settling back to ×1).
function warpingToNode() return WARPTO ~= nil and not WARPTO.settle end
-- True until the warp is back at ×1 after warp to node (probes).
function warpSettling() return WARPTO ~= nil end
function burnInfo()
  if not mnv then return nil end
  local dv = math.sqrt(mnv.pro ^ 2 + mnv.nor ^ 2 + mnv.rad ^ 2)
  local out = { dv = dv, lead = mnv.t0 - space.time(), left = dv, done = 0 }
  if mnv.bwx then
    out.dir = { x = mnv.bwx, y = mnv.bwy, z = mnv.bwz }
    local ax, ay, az = 0, 0, 0
    if mnv.apk == burn_key(mnv) then ax, ay, az = mnv.ax, mnv.ay, mnv.az end
    out.lx, out.ly, out.lz = mnv.bwx * dv - ax, mnv.bwy * dv - ay, mnv.bwz * dv - az
    out.left = math.sqrt(out.lx ^ 2 + out.ly ^ 2 + out.lz ^ 2)
    out.done = dv > 1e-4 and math.max(0, math.min(1, 1 - out.left / dv)) or 0
  end
  return out
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
-- HELD ground (linked for 75 % of the sustained window: what the sky goals
-- count) wears a pale gold ring round its disc; the biggest patch of ground
-- NOT held is ringed in amber, with a marker at its centre — where the next
-- relay satellite should pass over.
local function map_coverage(net, px_at)
  if not (cov_body and net.coverageGrid) then return nil end
  local g = net.coverageGrid(cov_body)
  local b = space.body(cov_body)
  if not (g and b) then return nil end
  local n = #g.dirs
  local spot = (b.radius or 100) * math.sqrt(4 * math.pi / math.max(1, n)) * 0.28
  local was = draw.depthTest()
  draw.depthTest(true)
  local held = g.held
  local gap = g.gaps and g.gaps.clusters and g.gaps.clusters[1]
  local in_gap = {}
  if gap and gap.idx and held then for _, i in ipairs(gap.idx) do in_gap[i] = true end end
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
    if held and held[i] then
      draw.disc(x, y, z, u[1], u[2], u[3], spot * 1.12, spot * 1.32, 1.0, 0.86, 0.45, 0.8)
    elseif in_gap[i] then
      draw.disc(x, y, z, u[1], u[2], u[3], spot * 1.12, spot * 1.32, 1.0, 0.62, 0.18, 0.75)
    end
  end
  -- the biggest gap's centre: a ring the size of the patch and a cross
  if gap and held and gap.n >= 2 then
    local R = (b.radius or 100) + 3
    local ux, uy, uz = gap.x, gap.y, gap.z
    local ang = math.acos(math.max(-1, 1 - 2 * gap.n / math.max(1, n)))
    local cx, cy, cz = b.x + ux * R * math.cos(ang), b.y + uy * R * math.cos(ang), b.z + uz * R * math.cos(ang)
    draw.ring(cx, cy, cz, ux, uy, uz, R * math.sin(ang), 1.0, 0.62, 0.18, 0.9)
    local px, py, pz = b.x + ux * R, b.y + uy * R, b.z + uz * R
    local s = spot * 1.6
    -- two strokes across the ground at the centre
    local ax, ay, az = 1 - ux * ux, -ux * uy, -ux * uz
    if ax * ax + ay * ay + az * az < 1e-4 then ax, ay, az = -uy * ux, 1 - uy * uy, -uy * uz end
    local al = math.sqrt(ax * ax + ay * ay + az * az)
    ax, ay, az = ax / al, ay / al, az / al
    local bx2, by2, bz2 = uy * az - uz * ay, uz * ax - ux * az, ux * ay - uy * ax
    draw.line(px - ax * s, py - ay * s, pz - az * s, px + ax * s, py + ay * s, pz + az * s, 1.0, 0.62, 0.18, 1)
    draw.line(px - bx2 * s, py - by2 * s, pz - bz2 * s, px + bx2 * s, py + by2 * s, pz + bz2 * s, 1.0, 0.62, 0.18, 1)
  end
  draw.depthTest(was and true or false)
  return g
end

-- THE RELAY SATELLITES round the coverage world (comms.relaySats): each one's
-- FOOTPRINT — the ground that can hear it, a ring on the surface (blue with a
-- path home, red without) — and, from the satellite, its hop home drawn
-- solid, or a red cross and "NO LINK HOME" when it has none. `at` moves a
-- live craft's end onto the craft.
local function map_relay_sats(net, px_at, label, lk, at)
  if not (cov_body and net.relaySats) then return end
  local b = space.body(cov_body)
  if not b then return end
  local was = draw.depthTest()
  for _, e in ipairs(net.relaySats(cov_body)) do
    local x, y, z = at(e.id, e.x, e.y, e.z)
    local ux, uy, uz = x - b.x, y - b.y, z - b.z
    local l = math.sqrt(ux * ux + uy * uy + uz * uz)
    if l > 1e-6 then
      ux, uy, uz = ux / l, uy / l, uz / l
      local R = (b.radius or 100) + 3
      local f = e.foot or 0
      local cr, cg, cb = 0.35, 0.62, 1.0
      if not e.linked then cr, cg, cb = 1.0, 0.35, 0.3 end
      if f > 0.01 then
        draw.depthTest(true)
        local c = math.cos(f)
        draw.ring(b.x + ux * R * c, b.y + uy * R * c, b.z + uz * R * c, ux, uy, uz, R * math.sin(f), cr, cg, cb, 0.85)
        -- the point under it
        draw.disc(b.x + ux * R, b.y + uy * R, b.z + uz * R, ux, uy, uz, 0, px_at(x, y, z, 3), cr, cg, cb, 0.9)
      end
      draw.depthTest(false)
      if e.linked and e.px then
        local ex, ey, ez = at(e.parent, e.px, e.py, e.pz)
        draw.line(x, y, z, ex, ey, ez, 0.35, 0.95, 0.6, 1)
      elseif not e.linked then
        local s = px_at(x, y, z, 9)
        draw.line(x - s, y - s, z, x + s, y + s, z, 1.0, 0.3, 0.25, 1)
        draw.line(x - s, y + s, z, x + s, y - s, z, 1.0, 0.3, 0.25, 1)
        if label and camera and camera.worldToScreen then
          local sx, sy, _, on = camera.worldToScreen(x, y, z)
          if on then label(sx, sy + 18 * (lk or 1), "NO LINK HOME", 11 * (lk or 1)) end
        end
      end
    end
  end
  draw.depthTest(was and true or false)
end

-- THE BASES (deep-space M5): each Base Station Tower from base_tower.bases()
-- (the hook the Tracking Station's list reads too): a beacon's ring and mast,
-- bigger, with its dish tipped off the mast head and its name; a second ring
-- round the foot when it is powered (a ground station). Teal with a path
-- home, red without. The home base (#0) is the station's own ring.
local bases_ref = nil
local function map_bases(px_at, label, lk, show)
  if not (bases_ref and bases_ref.valid ~= false) then bases_ref = findScript and findScript("base_tower") or nil end
  local bt = bases_ref
  if not (bt and bt.bases and camera and camera.worldToScreen) then return end
  local ok, list = pcall(bt.bases, { brief = true })
  if not ok or type(list) ~= "table" then return end
  for _, e in ipairs(list) do
    if not e.home and e.gx then
      local ux, uy, uz = e.ux or 0, e.uy or 1, e.uz or 0
      local s = px_at(e.gx, e.gy, e.gz, 10)
      local c = e.linked and { 0.35, 1.0, 0.8 } or { 1.0, 0.45, 0.35 }
      draw.ring(e.gx, e.gy, e.gz, ux, uy, uz, s, c[1], c[2], c[3], 1)
      if e.powered then draw.ring(e.gx, e.gy, e.gz, ux, uy, uz, s * 1.55, c[1], c[2], c[3], 0.8) end
      local tx, ty, tz = e.gx + ux * s * 3.2, e.gy + uy * s * 3.2, e.gz + uz * s * 3.2
      draw.line(e.gx, e.gy, e.gz, tx, ty, tz, c[1], c[2], c[3], 1)
      -- the dish: a small ring off the mast head, tipped between up and a tangent
      local ax, ay, az = 1 - ux * ux, -ux * uy, -ux * uz
      if ax * ax + ay * ay + az * az < 1e-4 then ax, ay, az = -uy * ux, 1 - uy * uy, -uy * uz end
      local al = math.sqrt(ax * ax + ay * ay + az * az)
      ax, ay, az = ax / al, ay / al, az / al
      local nx, ny, nz = ax * 0.82 + ux * 0.57, ay * 0.82 + uy * 0.57, az * 0.82 + uz * 0.57
      draw.ring(tx + ax * s * 0.5, ty + ay * s * 0.5, tz + az * s * 0.5, nx, ny, nz, s * 0.75, c[1], c[2], c[3], 1)
      if label and (show.markers or show.links) then
        local px, py, _, on = camera.worldToScreen(tx, ty, tz)
        if on then
          label(px, py - 16 * (lk or 1), string.format("%s · %s", e.name or "Base", e.powered and "ground station" or "mast"),
            11 * (lk or 1))
        end
      end
    end
  end
end
mapBases = map_bases   -- (probes; the station's map)

local function mmss(s)
  s = math.max(0, math.floor((s or 0) + 0.5))
  return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

function mapComms(subject, px_at, label, lk, show)
  if not show.links and not show.markers then return end
  local station = mode == "station"   -- (the station draws craft, relays and flags itself)
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
  local cov = (show.links and not station) and map_coverage(net, px_at) or nil
  if show.links and not station then map_relay_sats(net, px_at, label, lk, at) end
  if cov and label and not station and camera and camera.screenSize then
    local sw, sh = camera.screenSize()
    if sw then
      local held = ""
      if cov.held then
        held = cov.full and string.format("  ·  held %d%% over a %s window", math.floor(cov.sustained * 100 + 1e-6), mmss(cov.window))
          or string.format("  ·  held %d%% · %s / %s window", math.floor(cov.sustained * 100 + 1e-6),
            mmss(math.min(cov.heldS or 0, cov.window or 0)), mmss(cov.window))
      end
      label(sw * 0.5, (sh or 720) - 64 * (lk or 1), string.format(
        "%s coverage  ·  ground network %d%%  ·  with satellites %d%%%s",
        cov_body, math.floor(cov.ground * 100 + 0.5), math.floor(cov.sky * 100 + 0.5), held), 13 * (lk or 1))
      label(sw * 0.5, (sh or 720) - 46 * (lk or 1),
        "teal ground · blue sky · red none · gold ring held · amber the biggest gap: where the next relay should pass",
        11 * (lk or 1))
      local gp = cov.gaps and cov.gaps.clusters and cov.gaps.clusters[1]
      if gp and cov.held and camera.worldToScreen then
        local b = space.body(cov_body)
        if b then
          local R = (b.radius or 100) + 3
          local px, py, _, on = camera.worldToScreen(b.x + gp.x * R, b.y + gp.y * R, b.z + gp.z * R)
          if on then
            label(px, py - 16 * (lk or 1), string.format("GAP · %d%% of the ground · %d°%s",
              math.floor(gp.n / math.max(1, #cov.dirs) * 100 + 0.5), math.floor(math.abs(gp.lat) + 0.5),
              gp.lat >= 0 and "N" or "S"), 11 * (lk or 1))
          end
        end
      end
    end
  end
  -- RELAY BEACONS: a small upright triangle each, teal with a path home,
  -- red without, and its name.
  if not station and (show.markers or show.links) and net.beaconList and camera and camera.worldToScreen then
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
  -- (in STATION mode the station draws the base's icon and tag: the glyph only)
  if show.markers or show.links then map_bases(px_at, (not station) and label or nil, lk, show) end
  -- THE AGENCY'S FLAGS (scripts/deployables.lua): a short pole with a pennant
  -- in signal orange, and its name — the Tracking Station's MAP lands here.
  local dep = findScript and findScript("deployables")
  if show.markers and not station and dep and dep.list and camera and camera.worldToScreen then
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
      if not flown[id] and not station then
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
-- `fade` (optional, default 1) scales its alpha: the Tracking Station fades
-- the lines that do not matter in and out.
local TRACK_HI = { 0.35, 0.85, 1.0, 1.0 }       -- the craft you fly: the map's own trajectory cyan
local TRACK_LO = { 0.55, 0.68, 0.74, 0.38 }     -- every other craft: a quiet grey-blue
local TRACK_F = { 0, 0, 0, 0 }
function drawTrack(t, b, hi, px_at, label, lk, show, name, fade)
  if not t or t.kind == "landed" then return end
  local c = hi and TRACK_HI or TRACK_LO
  if fade and fade ~= 1 then
    TRACK_F[1], TRACK_F[2], TRACK_F[3], TRACK_F[4] = c[1], c[2], c[3], math.min(1, c[4] * fade)
    c = TRACK_F
  end
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
  local a = (hi and 1.0 or 0.45) * math.min(1, fade or 1)
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

-- THE STATION (F2, the pause menu, the dish): the map in STATION mode,
-- opened if it is shut. setMode swaps the density with the map up.
function openStation()
  if not map_view then toggle() end
  setMode("station")
end
function setMode(m)
  m = (m == "station") and "station" or "chart"
  if m == mode then return end
  mode = m
  planning = planning and m == "chart"
  if m == "chart" then ST.fn = nil; map_hud_t = -10.0 else set_hud(nil, nil) end
  local ts = STATION_REF and STATION_REF()
  if ts and ts.modeChanged then pcall(ts.modeChanged, m == "station") end
end
function close() if map_view then toggle() end end
-- Focus the view on whatever `fn(bodies)` answers this frame (x, y, z, name),
-- easing there from where it is now.
function focusOn(fn)
  ST.fn = fn
  ST.ease = true
  map_focus = 1
  map_offx, map_offy, map_offz = 0.0, 0.0, 0.0
end

-- Open or close. Called by the M key and by anything that needs the screen
-- back (a scene change, ending a flight).
function toggle()
  focus_override = nil
  ST.fn, ST.ex, ST.ey, ST.ez, ST.last, ST.ease = nil, 0, 0, 0, nil, false
  if map_view and mode == "station" then
    mode = "chart"
    local ts = STATION_REF and STATION_REF()
    if ts and ts.modeChanged then pcall(ts.modeChanged, false) end
  end
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
  GZ.drag, GZ.geo, GZ.hover, GZ.hot, GZ.rmb, gizmoBusy = nil, nil, nil, nil, nil, false
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

escTakenAt = -1
function start(_)
  map_view = false
  planning = false
  mode = "chart"
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
  -- warp to node runs with the map shut too (the flight readout's WARP key)
  warpDrive(dt)
  mnvRegister()
  -- (a name being typed into the station's field is not a key press)
  local ts = mode == "station" and map_view and STATION_REF() or nil
  local typing = ts and ts.typing and ts.typing() or false
  local gm_busy = gm_ref and (gm_ref.loading or gm_ref.curtain)
  if not typing then
    -- M: the chart (and M while the station is up closes it); F2: the station
    -- (F2 again closes it, F2 over the chart swaps to it)
    -- (the Build Kit with a kit piece in hand: M is its material key)
    local fbk = findScript("field_builder")
    if input.pressed("m") and not (fbk and fbk.materialKey == true) then toggle() end
    if input.pressed("f2") and not gm_busy then
      if map_view and mode == "station" then toggle()
      elseif map_view then setMode("station")
      else openStation() end
    end
  end
  if not map_view then return end
  -- ESC backs out one rung (pause_menu's ladder sees the map open and leaves
  -- the press to us): a right-click menu first, then the station's field and
  -- arming, then PLAN mode, then the map itself.
  if input.pressed("escape") then
    local cm = gz_ref("context_menu")
    if cm and cm.isOpen and (cm.isOpen() or cm.escTakenAt == time) then
      -- the menu's
    elseif ts and ts.escape and ts.escape() then
      escTakenAt = time
    elseif planning then
      planning = false
      escTakenAt = time
    else
      escTakenAt = time
      toggle()
      return
    end
  end
  -- N enters and leaves PLAN mode, but only for a craft that has a trajectory
  -- to plan on: on foot there is nothing to burn.
  if not typing and input.pressed("n") and subject_vessel() then planning = not planning end
  depth(true)
  update_map3d(node, dt)
  depth(false)
end
