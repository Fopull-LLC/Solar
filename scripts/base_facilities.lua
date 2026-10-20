-- BASE FACILITIES — the permanent colony buildings at the home base. Unlike the
-- launchpad (which the vessel_spawner drops only for a launch), these stand at the
-- base for the whole session: a command centre, a vehicle-assembly hangar, a power
-- plant, the tracking station (the comms dish the facilities menu reads the
-- `comms.ships` registry through), and the commerce depot.
--
-- Placement mirrors vessel_spawner: planets are ROUND and ORBIT, so each facility
-- is positioned RELATIVE to the dominant body, seated on the surface by a downward
-- raycast, tilted to the local surface normal, and spawned PARENTED to the planet
-- node — it rides the orbit through the transform hierarchy and the engine keeps
-- its baked Static collider glued to the moving ground.

-- THE BASE IS A PLACE. It is sited ONCE — at the crew's landing site, and only
-- after the loading screen has handed the world over — and then remembered
-- body-relative in the save (`base.body` + `base.x/y/z`). Every later session
-- rebuilds it on the same ground.
--
-- Before that the ring was cut around wherever the astronaut happened to be when
-- the terrain first answered, and on a loaded save that is the LOADING HOVER:
-- game_manager parks the crew 60 m over the spawn planet's north pole while the
-- field streams, THEN teleports them to their saved position. The colony went up
-- at the pole and the player woke up hundreds of metres away.

-- THE RING IS DRAWN ON THE SPHERE, NOT ON A FLAT MAP. This is the bug that made
-- the base misbehave in a GENERATED system while the little test planet looked
-- fine. The ring used to be `centre + tangent × radius` — a chord across the
-- tangent PLANE — and each site was then probed from only 12 m up.
--
-- On a body of radius r, a facility `d` metres away sits d/r radians round the
-- curve: 36 m on a 214 m planet is 9.6°. Two things break at once. The building
-- inherits the BASE's up instead of its own, so it leans ten degrees out of the
-- ground. And the tangent point floats ~3 m above the sphere before relief is
-- even counted — so on a world with 18 m of dune relief the 12 m probe starts
-- INSIDE the hill. A ray that begins underground reports nothing (the facility
-- is never placed) or reports zero (it is placed at the probe height, buried or
-- hanging). Either way you walk to a building that is not where the game thinks.
--
-- So: rotate the up vector round the great circle by `d / r`, probe straight down
-- the LOCAL radial from well above the highest terrain, and seat and tilt each
-- building in its own frame.

-- angle = bearing around the base (deg); radius = ground distance from the base
-- site; seat = how far the prefab's ORIGIN sits above the ground (= |mesh y-min| ×
-- prefab scale, so the building's base rests on the surface); yaw = spin about the
-- local up for facing variety.
--
-- The three SHEDS (command centre, assembly hangar, depot) are walk-in buildings:
-- their prefabs carry a SHELL collider built from the model's own geometry rather
-- than one box around the whole thing, so the doorways the mesh has are doorways
-- you can use. The power plant and the tracking dish are machines and stay solid.
-- Bearings dodge 0° (where the launchpad drops during a launch) and the radii
-- keep the buildings clear of each other at their current sizes — the command
-- centre alone is 12 × 18 m on the ground now.
local FACILITIES = {
  { prefab = "FacCommand",  angle = 40,  radius = 36, seat = 3.00, yaw = 215 },
  { prefab = "FacHangar",   angle = 145, radius = 36, seat = 5.00, yaw = 330 },
  { prefab = "FacPower",    angle = 250, radius = 30, seat = 1.53, yaw = 70 },
  { prefab = "FacTracking", angle = 320, radius = 40, seat = 2.46, yaw = 130 },
  -- The Commerce Depot: cargo comes off a landed craft here and materials are
  -- sold from here. Sited between the command centre and the hangar, on the
  -- side you walk back to from the pad.
  { prefab = "FacDepot",    angle = 90,  radius = 32, seat = 2.00, yaw = 250 },
}

-- Published so the objectives HUD can point at the base and the debug keys can
-- send you home. World coordinates, refreshed every frame the base exists.
sited = false
baseX, baseY, baseZ = 0, 0, 0
baseBody = nil

local want_spawn = false
local wait_t = 0.0
local last_note = 0.0
local done = {}      -- prefab -> true once placed
local placed = 0

-- The body whose SOI we're inside (nearest wins when SOIs nest).
-- Cross-script singletons, resolved once and kept: `findScript` walks the whole
-- scene (floptle/0063), and asking every frame is what made this project do a
-- hundred scans a frame. A handle stays good until the scene changes, and
-- `.valid` is how you find out that it has.
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

local function dominant_at(x, y, z)
  local best, bd = nil, nil
  for _, b in ipairs(space.bodies()) do
    local dx, dy, dz = x - b.x, y - b.y, z - b.z
    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
    if (b.soi or -1) > 0 and d < b.soi and (not best or d < bd) then
      best, bd = b, d
    end
  end
  return best
end

-- Ground each building stands on is levelled first: without it a 12 m shed on
-- a slope floats off the downhill side and buries the uphill one.
--
-- The radius has to reach the CORNERS. It was half the longer side plus a bit
-- (11 m for the command centre), but a 12 × 18 m building's corners are 10.8 m
-- out and the sculpt brush falls off toward its rim, so the ground at every
-- corner stayed humped and came up through the floor. Now: the half-diagonal
-- of the building's ground footprint (metres, from its prefab) plus 4 m.
local SIZE = {             -- ground footprint, metres (x × z at prefab scale)
  FacCommand  = { 12.0, 18.0 },
  FacHangar   = { 10.0, 10.0 },
  FacPower    = { 4.5, 5.85 },
  FacTracking = { 5.04, 4.44 },
  FacDepot    = { 8.0, 8.0 },
}
local FOOTPRINT = {}
for name, wz in pairs(SIZE) do
  FOOTPRINT[name] = math.sqrt(wz[1] * wz[1] + wz[2] * wz[2]) / 2 + 4.0
end
-- Passes of the flatten brush: each one moves the ground only part of the way
-- to the plane, and three left a visible lip on anything but gentle ground.
local FLATTEN_PASSES = 5

-- The engine's flatten levels to the planet's radial up at the op point
-- (0.102), which is the up each building is seated along, so a pad is level
-- under its floor at any latitude. Since 0.102.0 an op costs a few ms rather
-- than a couple of hundred (floptle/0320), so five passes a building are cheap;
-- a grid of small ones is still pointless, the big disc already lies flat.

function start(node)
  -- Wait for the crew + terrain to exist, then place the base once.
  want_spawn = true
  log("base: siting facilities — waiting for the base terrain…")
end

-- Which world the base belongs to. Once sited it is THAT planet's colony: if the
-- crew is off visiting another world nothing is built (and nothing tries to stream
-- a planet's terrain from across the system to do it) — the base is waiting for
-- them at home.
local function site_body(crew)
  local home = save.get("base.body")
  local here = dominant_at(crew.x, crew.y, crew.z)
  if home then
    if not here or here.name ~= home then return nil end
    return space.body(home) or here
  end
  return here
end

-- The base's centre, in WORLD coordinates, recomputed from the body's live
-- position every attempt (the planet is orbiting while we work). Returns the site,
-- its up vector, and whether it came from the save.
local function site_point(body, crew)
  local hx, hy, hz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  if save.get("base.body") == body.name and hx and hy and hz then
    local px, py, pz = body.x + hx, body.y + hy, body.z + hz
    local d = math.sqrt(hx * hx + hy * hy + hz * hz)
    if d > 1e-3 then return px, py, pz, hx / d, hy / d, hz / d, true end
  end
  local dx, dy, dz = crew.x - body.x, crew.y - body.y, crew.z - body.z
  local d = math.sqrt(dx * dx + dy * dy + dz * dz)
  if d < 1e-3 then return crew.x, crew.y, crew.z, 0, 1, 0, false end
  return crew.x, crew.y, crew.z, dx / d, dy / d, dz / d, false
end

-- How far above the body's centre a probe must start to be guaranteed OUTSIDE the
-- terrain: the surface radius plus every metre of relief the generator could have
-- piled on, plus margin. A probe that starts underground is the whole reason the
-- old ring failed on a real world.
local function probe_altitude(body)
  local w = save.get("world." .. (body.name or ""))
  local r = (w and w.radius) or body.radius or 100
  local relief = (w and w.relief) or 0
  return r + relief * 2.0 + 120.0
end

-- Drop a ray straight down the local radial at the direction `n` (a unit vector
-- from the body centre) and return the world ground point, or nil. `ignore` is a
-- node the ray passes through — the crew, because the probe comes down on the
-- exact spot they are standing on and a colony sited on the astronaut's head is
-- a colony two metres in the air.
local function ground_along(body, nx, ny, nz, alt, ignore)
  local ox = body.x + nx * alt
  local oy = body.y + ny * alt
  local oz = body.z + nz * alt
  local hit = raycast(ox, oy, oz, -nx, -ny, -nz, alt * 1.2, ignore)
  if not (hit and hit.distance) then return nil end
  return ox - nx * hit.distance, oy - ny * hit.distance, oz - nz * hit.distance
end

local function try_place()
  -- Nothing is sited while the loading screen is up: the crew is parked over the
  -- north pole then, not standing where they live.
  local gm = ref("game_manager")
  if gm and gm.loading then return false end

  -- Base site = the crew spawn (the Astronaut).
  local crew = find("Astronaut")
  if not crew then return false end

  local body = site_body(crew)
  if not body then return false end
  if body.name and body.name ~= "" then terrain.warm(body.name) end
  local px, py, pz, ux, uy, uz, from_save = site_point(body, crew)

  -- Pin the site to the GROUND under it before anything is built: the probe
  -- doubles as the "is the terrain actually here yet?" gate, and a crew still
  -- falling out of a restore doesn't drag the colony down with them.
  local alt = probe_altitude(body)
  local gx, gy, gz = ground_along(body, ux, uy, uz, alt, crew)
  if not gx then return false end
  px, py, pz = gx, gy, gz
  if not from_save then
    -- Remember it body-relative — absolute coordinates go stale the moment the
    -- planet moves on its orbit.
    save.set("base.body", body.name)
    save.set("base.x", px - body.x)
    save.set("base.y", py - body.y)
    save.set("base.z", pz - body.z)
    log(string.format("base: colony sited on %s (this is home now)", body.name))
  end
  baseBody, baseX, baseY, baseZ = body.name, px, py, pz

  -- Two tangents spanning the ground plane at the base: s = world-X projected out
  -- of up, t = up × s. Facilities ring the base along these.
  local sx, sy, sz = 1 - ux * ux, -ux * uy, -ux * uz
  local sl = math.sqrt(sx * sx + sy * sy + sz * sz)
  if sl < 1e-3 then sx, sy, sz, sl = 0, 0, 1, 1 end
  sx, sy, sz = sx / sl, sy / sl, sz / sl
  local tx = uy * sz - uz * sy
  local ty = uz * sx - ux * sz
  local tz = ux * sy - uy * sx

  -- No planet node, no base. A facility that fails to parent keeps WORLD
  -- coordinates: it never rides the orbit (the ground slides out from under it)
  -- and it reads in a different frame from everything that measures against it.
  -- The rails snapshot and the scene mirror can disagree for a frame right after
  -- the generator rolls a system, so this waits rather than building wrong.
  local planet_node = find(body.name)
  if not planet_node then return false end

  -- The base's own radius from the body centre — the arc length → angle
  -- conversion below is measured against it.
  local site_r = math.sqrt((px - body.x) ^ 2 + (py - body.y) ^ 2 + (pz - body.z) ^ 2)
  if site_r < 1e-3 then return false end

  for _, f in ipairs(FACILITIES) do
    if not done[f.prefab] then
      local a = math.rad(f.angle)
      -- Bearing in the base's ground plane…
      local dx = math.cos(a) * sx + math.sin(a) * tx
      local dy = math.cos(a) * sy + math.sin(a) * ty
      local dz = math.cos(a) * sz + math.sin(a) * tz
      -- …then walked AROUND the sphere by radius/site_r radians, so the site's
      -- own up is the real local up there and the probe drops down IT.
      local th = f.radius / site_r
      local c, s = math.cos(th), math.sin(th)
      local nx = ux * c + dx * s
      local ny = uy * c + dy * s
      local nz = uz * c + dz * s
      local nl = math.sqrt(nx * nx + ny * ny + nz * nz)
      nx, ny, nz = nx / nl, ny / nl, nz / nl
      local fgx, fgy, fgz = ground_along(body, nx, ny, nz, alt, crew)
      if fgx and terrain.sculpt then
        local foot = FOOTPRINT[f.prefab] or 8
        for _ = 1, FLATTEN_PASSES do terrain.sculpt(fgx, fgy, fgz, foot, 1.0, "flatten") end
        local gx2, gy2, gz2 = ground_along(body, nx, ny, nz, alt, crew)
        if gx2 then fgx, fgy, fgz = gx2, gy2, gz2 end
      end
      if fgx then
        -- Origin seated above the ground point, expressed body-relative for the
        -- planet-local coordinates the parent expects.
        local ox = fgx + nx * f.seat
        local oy = fgy + ny * f.seat
        local oz = fgz + nz * f.seat
        local rel = { x = ox - body.x, y = oy - body.y, z = oz - body.z }
        -- Facing: toward the middle of the colony, turned by the authored
        -- yaw (degrees) about the building's own up.
        local cx, cy, cz = px - fgx, py - fgy, pz - fgz
        local ya = math.rad(f.yaw)
        local kx, ky, kz = ny * cz - nz * cy, nz * cx - nx * cz, nx * cy - ny * cx
        local cyaw, syaw = math.cos(ya), math.sin(ya)
        local fx, fy, fz = cx * cyaw + kx * syaw, cy * cyaw + ky * syaw, cz * cyaw + kz * syaw
        spawn(f.prefab, vec3(ox, oy, oz), function(inst)
          -- +Y on the local up, +Z toward `f` (setUp's forward is the node's
          -- -Z). One whole-rotation write: Euler angles solved for a normal
          -- were written field by field and re-canonicalised in between,
          -- which tipped buildings on a planet's lower half (engine 0403).
          inst:setUp(vec3(nx, ny, nz), vec3(-fx, -fy, -fz))
          -- Parent-local coords: for a facility parented to its planet, local IS
          -- the body-relative offset (never add the body position — that flings
          -- it to the far side of the system).
          inst.x, inst.y, inst.z = rel.x, rel.y, rel.z
        end, planet_node)
        done[f.prefab] = true
        placed = placed + 1
        log("base: " .. f.prefab .. " sited (" .. placed .. "/" .. #FACILITIES .. ")")
      end
    end
  end
  return placed >= #FACILITIES
end

-- Tear the colony down and forget where it was, so the next tick re-sites it
-- wherever the crew is standing. The debug key (`cheats.lua`, F6) calls this —
-- "put the base HERE" is the single most useful thing to be able to do while
-- testing anything that happens at a base.
function resite()
  for _, f in ipairs(FACILITIES) do
    local n = find(f.prefab)
    if n and n.valid then n:destroy() end
  end
  save.set("base.body", false)
  save.set("base.x", false)
  save.set("base.y", false)
  save.set("base.z", false)
  done, placed, sited = {}, 0, false
  want_spawn, wait_t, last_note = true, 0.0, 0.0
  log("base: colony cleared — re-siting where you stand")
end

-- WHICH WORLDS HAVE A TRACKING STATION. A craft at rest on such a world can be
-- RECOVERED from the Tracking Station screen, wherever on it it came down
-- (scripts/tracking_station.lua). Today that is the home world only: the
-- colony's own dish. Building a station on another world is meant to add that
-- world here — set `otherStations[bodyName] = true` (and keep it in the save)
-- and recovery opens up there with no change to the screen.
otherStations = {}

function trackingStationOn(body)
  if not body then return false end
  if sited and baseBody == body then return true end
  return otherStations[body] == true
end

local function finish_siting()
  sited = true
  -- How far you are from your own front door, said out loud: a base that is
  -- half a planet away is a fact worth knowing before you go looking for it.
  local crew = find("Astronaut")
  if crew then
    local dx, dy, dz = crew.x - baseX, crew.y - baseY, crew.z - baseZ
    log(string.format("base: all facilities standing — %.0f m from the crew",
      math.sqrt(dx * dx + dy * dy + dz * dz)))
  else
    log("base: all facilities standing")
  end
end

function update(node, dt)
  -- Keep the published base position live: the body is orbiting, so a world
  -- coordinate cached once is a world coordinate that is wrong a minute later.
  if sited and baseBody then
    local b = space.body(baseBody)
    local hx, hy, hz = save.get("base.x"), save.get("base.y"), save.get("base.z")
    if b and hx then baseX, baseY, baseZ = b.x + hx, b.y + hy, b.z + hz end
  end
  -- The frame after siting (the flattens land at the end of the frame that
  -- sent them): the ground is done.
  if not want_spawn and not sited and placed >= #FACILITIES then finish_siting() end
  if not want_spawn then return end
  wait_t = wait_t + dt
  if try_place() then
    want_spawn = false
  elseif wait_t - last_note > 5.0 then
    last_note = wait_t
    log(string.format("base: waiting for terrain… (%.0fs, %d/%d placed)", wait_t, placed, #FACILITIES))
  end
end
