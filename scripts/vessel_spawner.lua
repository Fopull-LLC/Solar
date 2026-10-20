-- VESSEL SPAWNER — when the scene loads with `shipyard.launch` set, rebuild
-- the saved blueprint as a LIVE compound assembly on a real launchpad: pad
-- down first, then one Vessel root (RigidBody assembly) + every blueprint part
-- as its child, then `assembly.rebuild` gathers them into the physics compound
-- and CLAMPS it (anchored) until the pilot releases. The blueprint is
-- self-contained — no builder registry here.
--
-- Planets are ROUND and they ORBIT: everything here is positioned RELATIVE to
-- the dominant body's live rails position. The launchpad spawns PARENTED to
-- the planet node (it rides the orbit through the transform hierarchy; the
-- engine carries its static collider), and while the vessel is clamped it is
-- re-pinned to the pad deck every tick — nothing can drift apart while the
-- planet sails along its orbit.

defaults = {
  offset = 14.0,   -- sideways distance from the pad
  -- Gap between the lowest COLLIDER and the deck at spawn. It used to be 0.4 m
  -- under the assumption that the stack's lowest point was the blueprint's
  -- y = 0, so every release dropped the craft 40 cm onto the pad (and a craft
  -- standing on landing legs, whose collider reaches 0.4 m below that, was
  -- clamped half-buried in the deck instead). The real lowest collider point is
  -- now measured once the parts have spawned (see `lowest_collider`), so this
  -- is a true hairline: release sets the craft down 2 cm, at rest.
  clear = 0.02,
}

-- Radius of ground levelled under the pad: the deck is 5.1 × 4.3 m (half-
-- diagonal 3.4), plus room to stand beside it.
local PAD_FLAT = 6.0

local pending = 0
local vessel_node = nil
local body_name = nil       -- the dominant body we spawned against
local relv = nil            -- vessel origin, body-relative (the clamp pin)
local assemble_t = nil      -- when part spawning began (stall self-heal)
local rebuilt = false

-- The body whose SOI we're inside (nearest wins when SOIs nest — a moon
-- close-by beats its planet).
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

-- Standing on the ground: the pad and the vessel are turned with
-- `node:setUp(up)` (engine 0.117, floptle/0403), which puts +Y along a WORLD
-- direction whatever the hemisphere and whatever the parent's rotation. (It
-- replaced a solve for canonical Euler angles: written one field at a time, a
-- pad in the planet's lower hemisphere came out 20–70° off vertical.) The
-- vessel frame the parts are laid out in is then read back off the node.
local function basis_of(node)
  local f = node:worldForward()
  return node:worldRight(), node:worldUp(), vec3(-f.x, -f.y, -f.z)
end

-- How far below the vessel origin the craft's lowest COLLIDER reaches, in the
-- vessel frame (so a negative number is below the origin). Each part's box is
-- read off its live RigidBody (the prefab's half-extents, which is what the
-- physics compound is built from) and turned by the part's blueprint rotation,
-- so a sideways tank or a splayed leg counts at its real reach. Parts without a
-- readable box fall back to the blueprint's stack height, which is what the
-- builder used to put y = 0 at the bottom of the stack in the first place.
local function lowest_collider(placed)
  local low = nil
  for _, e in ipairs(placed) do
    local part, d = e.part, e.d
    local hx, hy, hz = d.rx or 0.5, (d.h or 1.0) * 0.5, d.rz or 0.5
    local getc = part.getComponent or part.getcomponent
    local rb = getc and getc(part, "RigidBody")
    if rb and rb.half_y and rb.half_y > 0 then
      -- The engine scales the box by the part node's scale; the component
      -- reports the unscaled prefab numbers.
      hx = (rb.half_x or hx) * math.abs(part.scale_x or 1)
      hy = rb.half_y * math.abs(part.scale_y or 1)
      hz = (rb.half_z or hz) * math.abs(part.scale_z or 1)
    end
    -- The part's local X/Y/Z axes in the vessel frame (YXZ, as everywhere in
    -- this project); only their vessel-up (y) components matter here.
    local cy, sy = math.cos(d.yaw or 0), math.sin(d.yaw or 0)
    local cx, sx = math.cos(d.pitch or 0), math.sin(d.pitch or 0)
    local cz, sz = math.cos(d.roll or 0), math.sin(d.roll or 0)
    local Xx, Xy, Xz = cy * cz + sy * sx * sz, cx * sz, -sy * cz + cy * sx * sz
    local Yx, Yy, Yz = -cy * sz + sy * sx * cz, cx * cz, sy * sz + cy * sx * cz
    local Zy = Xz * Yx - Xx * Yz
    local reach = math.abs(Xy) * hx + math.abs(Yy) * hy + math.abs(Zy) * hz
    local bottom = (d.y or 0) - reach
    if not low or bottom < low then low = bottom end
  end
  return low or 0.0
end

local function spawn_parts(vessel, bp)
  local rxv, upv, rzv = basis_of(vessel)
  local vx, vy, vz = vessel.x, vessel.y, vessel.z
  local total = 0
  local placed = {}
  for _, d in pairs(bp.parts) do
    total = total + 1
    pending = pending + 1
    local wx = vx + rxv.x * d.x + upv.x * d.y + rzv.x * d.z
    local wy = vy + rxv.y * d.x + upv.y * d.y + rzv.y * d.z
    local wz = vz + rxv.z * d.x + upv.z * d.y + rzv.z * d.z
    spawn(d.prefab, vec3(wx, wy, wz), function(part)
      -- The engine parents a spawned part by converting its WORLD pose into
      -- the vessel's local frame — which leaves inv(vessel tilt) baked into
      -- the part's local rotation (the "misrotated parts" of every sloped
      -- launch). Parts are authored in the VESSEL frame: overwrite with the
      -- blueprint's exact local rotation (v1.2 builds sideways parts too).
      part:setAngles(d.yaw or 0, d.pitch or 0, d.roll or 0)
      placed[#placed + 1] = { part = part, d = d }
      pending = pending - 1
      if pending == 0 and vessel_node then
        rebuilt = true
        assembly.rebuild(vessel_node)
        -- CLAMPED from the first physics tick: anchored (no gravity, no
        -- contacts, rides the planet's frame) until the pilot releases —
        -- nothing can fling a vessel that is not yet simulating.
        assembly.setAnchored(vessel_node, true)
        -- SEAT IT ON THE DECK. The origin was placed `clear` above the deck on
        -- the assumption that nothing reaches below y = 0; lift (or lower) the
        -- clamp pin by however far the real lowest collider is from that, so
        -- the craft is clamped a hairline above the deck — never inside it
        -- (a release from inside the pad is a depenetration kick) and never
        -- 40 cm over it (a release from up there is a drop).
        local low = lowest_collider(placed)
        if relv and math.abs(low) > 1e-3 then
          relv.x, relv.y, relv.z = relv.x - upv.x * low, relv.y - upv.y * low, relv.z - upv.z * low
        end
        log(string.format("vessel assembled: %d parts — clamped to the pad "
          .. "(lowest collider %.2f m below the origin, seated %.2f m above the deck)",
          total, -low + 0.0, params.clear)) -- (+0.0: never print "-0.00")
      end
    end, vessel)
  end
  assemble_t = time
end

-- The spawn WAITS for solid ground: at scene start the pad's terrain may not
-- be streamed in yet — spawning early drops the vessel through the world.
local want_spawn = false
local bp = nil
local wait_t = 0.0
local last_note = 0.0

function start(node)
  if save.get("shipyard.launch") ~= 1 then
    save.set("shipyard.pilot", 0) -- a stale handoff flag must not park the walker
    return
  end
  save.set("shipyard.launch", 0)
  bp = save.get("shipyard.blueprint")
  if not bp or not bp.parts then
    save.set("shipyard.pilot", 0)
    return
  end
  want_spawn = true
  log("launch: vessel blueprint aboard — waiting for the pad terrain…")
end

local function try_spawn()
  -- Not while the loading screen is up: the crew is parked over the spawn
  -- world's NORTH POLE then, and that is the first ground to answer the
  -- terrain probe below — the pad went down there, a quarter of the world
  -- (1.1 km on Vever) round from the base, out of the base dish's sight, so
  -- every probe craft on it read "NO SIGNAL — blocked by Vever". The crew is
  -- moved to the base (game_manager launch_site) the frame loading ends.
  local gm = findScript("game_manager")
  if gm and gm.loading then return false end
  -- Site reference read FRESH each attempt: the crew's own position, which is
  -- where a launch rolls out from.
  local pad = find("Astronaut")
  local px, py, pz = 0, 20, 0
  if pad then px, py, pz = pad.x, pad.y, pad.z end

  -- Local up: radial from the dominant body (fallback: world +Y). Keep its
  -- terrain WARM so the ground actually streams in under us.
  local ux, uy, uz = 0, 1, 0
  local body = dominant_at(px, py, pz)
  if body then
    if body.name and body.name ~= "" then terrain.warm(body.name) end
    local dx, dy, dz = px - body.x, py - body.y, pz - body.z
    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
    if d > 1e-3 then ux, uy, uz = dx / d, dy / d, dz / d end
  end
  -- A sideways direction perpendicular to up (project world X out of up).
  local sx, sy, sz = 1 - ux * ux, -ux * uy, -ux * uz
  local sl = math.sqrt(sx * sx + sy * sy + sz * sz)
  if sl < 1e-3 then sx, sy, sz, sl = 0, 0, 1, 1 end
  sx, sy, sz = sx / sl, sy / sl, sz / sl

  -- THE SITE. Candidates ring the crew — `offset` metres out first, then
  -- further, eight bearings each — and the first whose DECK would stand clear
  -- of any sea wins. A pad in the shallows put the engine skirt half a metre
  -- under water: buoyancy on that box (36 kN against the starter's 32 kN of
  -- weight on Ryiaeth) floated the rocket off the deck before it lit, an extra
  -- 2–5 m/s at release that the flight plan could not explain. UP IS UP AT
  -- THE SITE too: the pad, its seating and the vessel are aimed at the radial
  -- through the site's own ground point, not the crew's — 14 m away on a
  -- small world that is 3.9° (Bryolru, r 207), and a pad tilted that much (18°
  -- in one First Flight) launched the rocket off sideways into a near-orbit.
  local tx, ty, tz = uy * sz - uz * sy, uz * sx - ux * sz, ux * sy - uy * sx -- up × side
  local deck_top = 2.0 * 1.24 + 0.05
  local function site(dist, bearing)
    local c, sn = math.cos(bearing), math.sin(bearing)
    local dx, dy, dz = sx * c + tx * sn, sy * c + ty * sn, sz * c + tz * sn
    local qx = px + dx * dist + ux * 8
    local qy = py + dy * dist + uy * 8
    local qz = pz + dz * dist + uz * 8
    local h = raycast(qx, qy, qz, -ux, -uy, -uz, 260.0)
    if not (h and h.distance) then return nil end
    local g = { x = qx - ux * h.distance, y = qy - uy * h.distance, z = qz - uz * h.distance }
    g.ux, g.uy, g.uz = ux, uy, uz
    if body then
      local rx, ry, rz = g.x - body.x, g.y - body.y, g.z - body.z
      local rl = math.sqrt(rx * rx + ry * ry + rz * rz)
      if rl > 1e-3 then g.ux, g.uy, g.uz = rx / rl, ry / rl, rz / rl end
    end
    local w = water and water.at and water.at(vec3(g.x + g.ux * deck_top,
      g.y + g.uy * deck_top, g.z + g.uz * deck_top))
    g.wet = w and (w.depth or 0) or 0
    return g
  end
  -- The first candidate doubles as the terrain-ready check; WAIT (warming)
  -- until it answers.
  local best = site(params.offset, 0)
  if not best then
    if wait_t - (last_note or 0) > 5.0 then
      last_note = wait_t
      log(string.format("launch: waiting for terrain… (%.0fs)", wait_t))
    end
    return false
  end
  local lifted = false
  if best.wet > 0 then
    local first = best
    best = nil
    for _, dist in ipairs({ params.offset, params.offset + 8, params.offset + 16 }) do
      for k = 0, 7 do
        local g = site(dist, k * math.pi / 4)
        if g and g.wet <= 0 then best = g break end
      end
      if best then break end
    end
    if best then
      log("launch: the first pad site was awash — moved to dry ground")
    else
      -- Nowhere dry within reach: stand the pad up out of the water.
      best = first
      local lift = best.wet + 0.3
      best.x, best.y, best.z = best.x + best.ux * lift, best.y + best.uy * lift, best.z + best.uz * lift
      lifted = true
      log(string.format("launch: no dry ground near — the pad stands %.1f m up out of the sea", lift))
    end
  end
  local gx, gy, gz = best.x, best.y, best.z
  ux, uy, uz = best.ux, best.uy, best.uz
  local ax, ay, az = gx + ux * 8, gy + uy * 8, gz + uz * 8

  -- Level the pad's ground first, the way base_facilities levels a building's:
  -- on a slope the deck floated off the downhill side and the uphill rim
  -- buried it, and a rocket standing on a tilted pad leans before it lifts.
  -- Then probe again — the deck seats on the ground as it is now.
  if terrain.sculpt and not lifted then -- (a lifted pad stands on its own height)
    -- Three passes, a few ms each. The flatten levels to the planet's up
    -- right here, so the pad is level at any latitude.
    for _ = 1, 3 do terrain.sculpt(gx, gy, gz, PAD_FLAT, 1.0, "flatten") end
    local again = raycast(ax, ay, az, -ux, -uy, -uz, 260.0)
    if again and again.distance then
      gx, gy, gz = ax - ux * again.distance, ay - uy * again.distance, az - uz * again.distance
    end
  end

  -- Everything below is BODY-RELATIVE: the ground point as an offset from the
  -- planet's center right now. World positions recompute from the LIVE body
  -- each time they're needed — the planet is orbiting while we work.
  local relg = body and { x = gx - body.x, y = gy - body.y, z = gz - body.z } or nil
  body_name = body and body.name or nil
  local deck = 1.24

  -- Rate the engines for THIS pad (flight_ops.rerateAtPad): the builder only
  -- had an estimate of the launch radius. Before the vessel exists, because its
  -- controller reads the blueprint when it starts.
  local fo = findScript("flight_ops")
  if fo and fo.rerateAtPad and body then
    -- Rated at the craft's CENTRE OF MASS, not the deck: on a 130 m world a
    -- full-burn hop is near escape energy and every metre of launch radius is
    -- 10–13 % of apex. Rated at the deck, the starter (CoM 1.9 m up the stack)
    -- felt 5 % less gravity than the solve assumed and flew 244–308 m against
    -- a 230 m quote on four seeds.
    local cm, mt = 0.0, 0.0
    for _, d in pairs(bp.parts or {}) do
      local m = d.mass or 0
      cm, mt = cm + m * (d.y or 0), mt + m
    end
    local h = deck * 2.0 + params.clear + (mt > 0 and math.max(0, cm / mt) or 0)
    local rb = fo.rerateAtPad(bp, body.name, gx + ux * h, gy + uy * h, gz + uz * h)
    if rb then bp = rb; save.set("shipyard.blueprint", bp) end
  end

  -- The LAUNCHPAD spawns PARENTED to the planet node: it rides the orbit
  -- through the transform hierarchy, and the engine keeps its baked static
  -- collider glued to the moving surface. Its local position is set exact in
  -- the callback (body-relative — no tick-of-drift error).
  local planet_node = body_name and find(body_name) or nil
  spawn("Launchpad", vec3(gx + ux * deck, gy + uy * deck, gz + uz * deck), function(lp)
    lp:setUp(vec3(ux, uy, uz))
    if planet_node and relg then
      -- Node coordinates are PARENT-LOCAL: for a pad parented to its planet,
      -- local IS the body-relative offset. (Adding the planet position here
      -- put the pad on the far side of the star system — round 7's missing
      -- launchpad.)
      lp.x = relg.x + ux * deck
      lp.y = relg.y + uy * deck
      lp.z = relg.z + uz * deck
    end
    -- The vessel assembles on the deck (deck top ~1.24 above the pad center),
    -- positioned from the LIVE body so no orbit-drift creeps in between the
    -- raycast tick and this one.
    local b2 = body_name and space.body(body_name)
    local bx, by, bz = gx, gy, gz
    if b2 and relg then bx, by, bz = b2.x + relg.x, b2.y + relg.y, b2.z + relg.z end
    local vx = bx + ux * (deck * 2.0 + params.clear)
    local vy = by + uy * (deck * 2.0 + params.clear)
    local vz = bz + uz * (deck * 2.0 + params.clear)
    if b2 then relv = { x = vx - b2.x, y = vy - b2.y, z = vz - b2.z } end
    spawn("Vessel", vec3(vx, vy, vz), function(v)
      v:setUp(vec3(ux, uy, uz))
      vessel_node = v
      spawn_parts(v, bp)
    end)
  end, planet_node)
  log("launch: pad down, vessel assembling")
  return true
end

function update(node, dt)
  if want_spawn then
    wait_t = wait_t + dt
    if try_spawn() then want_spawn = false end
    return
  end

  -- Stall self-heal: a part whose spawn never lands (bad prefab name in an
  -- old blueprint) must not wedge the whole launch — build the compound from
  -- whatever DID arrive and say so.
  if not rebuilt and assemble_t and pending > 0 and time - assemble_t > 8.0
    and vessel_node and vessel_node.valid then
    rebuilt = true
    assembly.rebuild(vessel_node)
    assembly.setAnchored(vessel_node, true)
    log(string.format("launch: %d part(s) never spawned — assembled without them", pending))
  end

  -- While CLAMPED, the vessel is re-pinned to its pad-deck spot every tick
  -- (body-relative): the anchored compound and the planet-parented pad both
  -- ride the orbit, and the pin closes any residual drift between the two
  -- carrying mechanisms. Stops the moment the pilot releases the clamps.
  if vessel_node and vessel_node.valid and relv and body_name then
    local info = assembly.info(vessel_node)
    if info and info.anchored then
      local b = space.body(body_name)
      if b then
        assembly.teleport(vessel_node,
          vec3(b.x + relv.x, b.y + relv.y, b.z + relv.z))
      end
    elseif info then
      relv = nil -- released: the pin's job is done
    end
  end
end
