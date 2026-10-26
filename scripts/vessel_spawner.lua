-- VESSEL SPAWNER — when the scene loads with `shipyard.launch` set, rebuild
-- the saved blueprint as a LIVE compound assembly on a real launchpad: pad
-- down first, then one Vessel root (RigidBody assembly) + every blueprint part
-- as its child, then `assembly.rebuild` gathers them into the physics compound
-- and CLAMPS it (anchored) until the pilot releases. The blueprint is
-- self-contained — no builder registry here.
--
-- WHERE. A save with a spaceport (base_facilities layout 2) launches from
-- it: `shipyard.site` (the builder's choice) is "pad" — Launch Complex 1's
-- mount, where the hold-down posts (PadClamps) go down on the deck — or
-- "runway" — the threshold of the runway, the craft's front turned down it,
-- standing on the ground. A save without one (or a launch from anywhere the
-- base is not) keeps the old way: a Launchpad dropped beside the crew.
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
-- One part's reach below its centre along the vessel's up, in metres (the
-- prefab box from its live RigidBody, turned by the blueprint rotation).
local function part_reach(e)
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
  return math.abs(Xy) * hx + math.abs(Yy) * hy + math.abs(Zy) * hz
end

local function lowest_collider(placed)
  local low = nil
  for _, e in ipairs(placed) do
    local bottom = (e.d.y or 0) - part_reach(e)
    if not low or bottom < low then low = bottom end
  end
  return low or 0.0
end

-- SEATED ON THE GROUND THAT IS THERE (playtest 2026-10-26: "this just made
-- the entire jet sink into the ground and explode"). A runway craft was put
-- at the SITE point's height — the gate only asks that the ground read
-- within 2.5 m of it — and, launched while the base was still grading its
-- ground, the grade then raised the runway under the clamped craft: on
-- release its hull started inside the rock, where the terrain's surface has
-- nothing to push it out with, and it fell through the planet. (probe
-- SCRATCH/craft run "before2": the jet assembled 2.4 s before the regrade
-- finished, then fell at ~g from the moment it was let go, no tyre ever
-- touching.) So the craft is seated on the ground under its own feet: the
-- ground straight under the bottom of every part that hangs within
-- SEAT_BAND of the lowest one is found by a ray from above, and the clamp pin
-- is moved along up so the part nearest the ground clears it by `clear` —
-- up out of a raised grade, down onto a lowered one (never more than
-- SEAT_DROP down: a ray that found a ditch is not a reason to sink a craft).
-- Done when it is assembled and every SEAT_EVERY s while it stays clamped.
SEAT_BAND, SEAT_DROP, SEAT_EVERY, SEAT_UP = 1.0, 2.0, 0.5, 4.0
-- `pin` = the vessel origin's place (world, now), `rxv, upv, rzv` its axes.
-- Returns the shift along up (m; + = lift), or nil when no ray found ground.
function seatShift(placed, pin, rxv, upv, rzv, clear, ignore)
  local low = lowest_collider(placed)
  local need = nil
  for _, e in ipairs(placed) do
    local d = e.d
    local by = (d.y or 0) - part_reach(e)
    if by <= low + SEAT_BAND then
      local px = pin.x + rxv.x * (d.x or 0) + upv.x * by + rzv.x * (d.z or 0)
      local py = pin.y + rxv.y * (d.x or 0) + upv.y * by + rzv.y * (d.z or 0)
      local pz = pin.z + rxv.z * (d.x or 0) + upv.z * by + rzv.z * (d.z or 0)
      local hit = raycast(px + upv.x * SEAT_UP, py + upv.y * SEAT_UP, pz + upv.z * SEAT_UP,
                          -upv.x, -upv.y, -upv.z, SEAT_UP + SEAT_DROP + 1.0, ignore)
      if hit and hit.distance then
        local gap = SEAT_UP - hit.distance          -- the ground over this part's bottom (+ = buried)
        if not need or gap > need then need = gap end
      end
    end
  end
  if not need then return nil end
  return math.max(-SEAT_DROP, need + (clear or 0.02))
end
local seat_t = 0.0
local seat_placed = nil   -- the parts of the craft being held (for the re-seat)
SEAT_DECK = nil           -- the site has a deck (pad) or not (runway); set as it spawns

-- Move the clamp pin so the held craft sits `clear` over the ground under it.
function reseat(tag)
  if not (vessel_node and vessel_node.valid and relv and body_name and seat_placed) then return end
  local b = space.body(body_name)
  if not b then return end
  local rxv, upv, rzv = basis_of(vessel_node)
  local pin = { x = b.x + relv.x, y = b.y + relv.y, z = b.z + relv.z }
  local skip = { vessel_node }
  local crew = find("Astronaut")
  if crew then skip[#skip + 1] = crew end
  local sh = seatShift(seat_placed, pin, rxv, upv, rzv, params.clear, { ignore = skip })
  if not sh or math.abs(sh) < 0.01 then return end
  relv.x, relv.y, relv.z = relv.x + upv.x * sh, relv.y + upv.y * sh, relv.z + upv.z * sh
  log(string.format("launch: %s — seated on the ground under it: %s %.2f m", tag or "held",
    sh > 0 and "lifted" or "lowered", math.abs(sh)))
end

-- builder_proc (the drawn parts' meshes), on the BuilderProc manager node.
local proc_ref = nil
function proc_lib()
  if not (proc_ref and proc_ref.valid) then proc_ref = findScript and findScript("builder_proc") or nil end
  return proc_ref
end

-- EVERY PART A LAUNCH PUTS DOWN CARRIES TWO TAGS: `CRAFT_TAG` (a part of some
-- craft — what a pad check finds lying about, whatever split it off) and its
-- flight's own tag (what a revert takes away). A split keeps the part nodes, so
-- a spent stage or a wing torn off still says where it came from. (flight_ops
-- tags a craft it rebuilds from the fleet with CRAFT_TAG too.)
CRAFT_TAG = "craftpart"
local spawn_tag = nil       -- the flight tag the parts being spawned now get

-- A BIG CRAFT IS PUT TOGETHER OVER SEVERAL FRAMES. Every part is a prefab
-- the engine instantiates on the frame it is asked for, and a 1,000-part craft
-- asked for all at once was one 170 ms frame (perfbench g_launch_rollout,
-- rc10). Parts are asked for SPAWN_BATCH a frame (`spawn_drain`, from update);
-- the craft is held still the whole time — the root is made a compound and
-- anchored before the first part is asked for, and the anchored compound is
-- pinned to the pad every tick as before — and `assembly.rebuild` still runs
-- once, when the last part has landed. Each part is set at its blueprint pose
-- in the vessel's frame in its callback, so a part that lands a few frames
-- after the first (the planet moving on under it) is exactly where it belongs.
--
-- On an engine with a spawn budget (0.117 rc16, floptle/0518) every part is
-- asked for at once and the ENGINE spreads the making over frames,
-- SPAWN_BUDGET_MS of each frame, each callback running as its part is made;
-- the budget is put back when the last part is in (`spawnDone`). The hold,
-- the per-part pose fix and the one rebuild are the same either way.
SPAWN_BATCH = 150
SPAWN_BUDGET_MS = 4.0
local spawn_q = nil          -- { vessel, list = { d, ... }, i, placed, total, tag, all }

local function spawn_drain()
  local q = spawn_q
  if not q then return end
  local vessel = q.vessel
  if not (vessel and vessel.valid ~= false) then spawn_q = nil return end
  local rxv, upv, rzv = basis_of(vessel)
  local vx, vy, vz = vessel.x, vessel.y, vessel.z
  local placed, total, tag = q.placed, q.total, q.tag
  local last = q.all and #q.list or math.min(#q.list, q.i + SPAWN_BATCH - 1)
  for k = q.i, last do
    local d = q.list[k]
    local wx = vx + rxv.x * d.x + upv.x * d.y + rzv.x * d.z
    local wy = vy + rxv.y * d.x + upv.y * d.y + rzv.y * d.z
    local wz = vz + rxv.z * d.x + upv.z * d.y + rzv.z * d.z
    spawn(d.prefab, vec3(wx, wy, wz), function(part)
      -- Asked for all at once, a part can be made after its craft is gone (a
      -- revert mid-build): the engine then makes it unparented, in the open.
      if q.all and vessel.valid == false then part:destroy() return end
      -- (the blueprint pose in the vessel's frame, whatever the vessel did
      -- between the ask and the landing)
      if q.fix then part.x, part.y, part.z = d.x, d.y, d.z end
      -- The engine parents a spawned part by converting its WORLD pose into
      -- the vessel's local frame — which leaves inv(vessel tilt) baked into
      -- the part's local rotation (the "misrotated parts" of every sloped
      -- launch). Parts are authored in the VESSEL frame: overwrite with the
      -- blueprint's exact local rotation (v1.2 builds sideways parts too).
      part:setAngles(d.yaw or 0, d.pitch or 0, d.roll or 0)
      if part.addTag then
        part:addTag(CRAFT_TAG)
        if tag then part:addTag(tag) end
      end
      -- DRAWN PARTS (builder overhaul WP3): a drawn member, panel or brace is
      -- one prefab for every size. builder_proc gives it the mesh for its
      -- blueprint `size` and writes its collider's half-extents NOW, before
      -- the assembly.rebuild below, so the compound has its real box. Its
      -- joint plates (gussets, splice plates, clamps) ride on it as `joints`.
      if d.size and d.proc then
        local P = proc_lib()
        if P then
          P.dress(part, { def = d, size = d.size })
          for _, j in ipairs(d.joints or {}) do P.dressJoint(part, j) end
        end
      elseif d.joints then
        local P = proc_lib()
        if P then for _, j in ipairs(d.joints) do P.dressJoint(part, j) end end
      end
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
        -- off a deck (the runway, the old dropped pad), seat it on the ground
        -- actually under it (seatShift)
        seat_placed = (SEAT_DECK == false) and placed or nil
        seat_t = 0.0
        if seat_placed then reseat("assembled") end
      end
    end, vessel)
  end
  q.i = last + 1
  assemble_t = time
  if q.i > #q.list then spawn_q = nil end
end

local function spawn_parts(vessel, bp)
  local list = {}
  for _, d in pairs(bp.parts) do list[#list + 1] = d end
  pending = pending + #list
  local spread = #list > SPAWN_BATCH
  local paced = spread and spawnBudget ~= nil and spawnDone ~= nil
  spawn_q = { vessel = vessel, list = list, i = 1, placed = {}, total = #list, tag = spawn_tag,
              fix = spread, all = paced }
  -- Held from the start: the root alone is a compound, anchored, until the
  -- last part lands and the whole craft is rebuilt (and anchored again).
  if spread then
    assembly.rebuild(vessel)
    assembly.setAnchored(vessel, true)
  end
  assemble_t = time
  if paced then
    local prev = spawnBudget(SPAWN_BUDGET_MS)
    spawn_drain()
    spawnDone(function() spawnBudget(prev) end)
  else
    spawn_drain()
  end
end

-- The spawn WAITS for solid ground: at scene start the pad's terrain may not
-- be streamed in yet — spawning early drops the vessel through the world.
local want_spawn = false
local bp = nil
local site_kind = "pad"
local wait_t = 0.0
local last_note = 0.0
local site_wait = 0.0       -- seconds the spaceport launch has looked at its site and found it not ready
local site_note = nil       -- the caption put up while it waits (taken down when it goes)
local force_site = false    -- this launch skips the site check (a revert cleared it)
local pins = {}             -- earlier in-place rollouts still in their clamps (see launchNow)
local pad_clamps = {}       -- every PadClamps a pad launch has put down (taken up when the pad is next used)

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end

local function deep(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = deep(v) end
  return o
end

-- ═══ IS THE SITE CLEAR? ═════════════════════════════════════════════════════
--
-- A launch used to go wherever the site was, whatever was standing there: the
-- new craft assembled INSIDE the one left on the pad, and the two blew each
-- other apart on the first physics tick. A launch now looks first, and when
-- the pad (or the runway threshold) is taken it is called off with a notice
-- that names what is in the way. Nothing is deleted for you: the craft you
-- left there may be the one you wanted.
--
-- What counts: any craft (a controller, live, or a fleet record not rebuilt
-- yet), any piece a craft shed (a part carrying CRAFT_TAG whose root is not a
-- craft), and the crew on foot. Within the site's footprint — `SITE_R`, or the
-- new craft's own reach, whichever is wider — and from a little under the
-- deck to well over the new craft's top: a craft flying high over the pad is
-- not in the way. The pad and the runway threshold are 100 m apart, so a
-- craft parked on one never blocks the other.
local SITE_R = { pad = 7.0, runway = 10.0 }

-- The blueprint's reach from its own axis (horizontal) and its height.
local function bp_size(b)
  local reach, top = 0.0, 0.0
  for _, d in pairs((b and b.parts) or {}) do
    local r = math.sqrt((d.x or 0) ^ 2 + (d.z or 0) ^ 2) + math.max(d.rx or 0.5, d.rz or 0.5)
    if r > reach then reach = r end
    local t = (d.y or 0) + (d.h or 1) * 0.5
    if t > top then top = t end
  end
  return reach, top
end

local function wpos(n)
  local w = n.worldPos
  if w then return w.x, w.y, w.z end
  return n.x, n.y, n.z
end

-- The site in world space: centre, up, the radius and height window to test.
local function site_box(kind, b)
  local bf = ref("base_facilities")
  local st = bf and bf.launchSite and bf.launchSite(kind)
  local body = st and space.body(st.body)
  if not body then return nil end
  local reach, top = bp_size(b)
  return { kind = st.kind, body = st.body,
           cx = body.x + st.x, cy = body.y + st.y, cz = body.z + st.z,
           ux = st.up.x, uy = st.up.y, uz = st.up.z,
           r = math.max(SITE_R[st.kind] or 8.0, reach + 1.5),
           lo = -4.0, hi = math.max(25.0, top + 8.0) }
end

local function in_box(S, x, y, z, pad)
  local rx, ry, rz = x - S.cx, y - S.cy, z - S.cz
  local h = rx * S.ux + ry * S.uy + rz * S.uz
  if h < S.lo or h > S.hi then return false end
  local hx, hy, hz = rx - S.ux * h, ry - S.uy * h, rz - S.uz * h
  return hx * hx + hy * hy + hz * hz <= (S.r + (pad or 0)) ^ 2
end

local tag_names = {}        -- flight tag → the craft's name, for naming its debris

local function tag_name(n)
  for _, t in ipairs(n.tags or {}) do
    if tag_names[t] then return tag_names[t] end
  end
  return nil
end

-- What is on the launch site, or nil when it is clear:
--   { what = "craft" | "parked" | "debris" | "crew", name = …, dist = m }
-- `ignore` is a set of node ids to look past (a revert's own craft, going).
-- Global: the builder asks before it charges for a hull, and probes ask.
function siteBlocker(kind, b, ignore)
  local S = site_box(kind == "runway" and "runway" or "pad", b or save.get("shipyard.blueprint"))
  if not S then return nil end
  ignore = ignore or {}
  local craft_ids = {}
  -- Craft in the scene: any of its parts in the box.
  for _, v in ipairs(findScripts("vessel_controller")) do
    local n = v.node
    if n and n.valid ~= false then
      craft_ids[n.id] = true
      if not ignore[n.id] then
        local hit = in_box(S, wpos(n))
        if not hit and n.children then
          for _, c in ipairs(n:children()) do
            if in_box(S, wpos(c)) then hit = true break end
          end
        end
        if hit then
          local lost = v.isLost and v.isLost()
          local nm = v.craftName
          if not nm or nm == "" or nm == "Vessel" then nm = tag_name(n) or "a craft" end
          return { what = lost and "debris" or "craft", name = nm, node = n }
        end
      end
    end
  end
  -- Pieces shed by any craft (spent stages, a wing that came off, a wreck).
  if findTagged then
    for _, p in ipairs(findTagged(CRAFT_TAG)) do
      local root = p.parent
      local rid = root and root.id
      if p.valid ~= false and not (rid and (craft_ids[rid] or ignore[rid])) and not ignore[p.id]
         and in_box(S, wpos(p)) then
        return { what = "debris", name = tag_name(p), node = root or p }
      end
    end
  end
  -- Craft the fleet will rebuild here (a scene that has just loaded puts the
  -- fleet back only after a launch has seated its crew).
  local fo = ref("flight_ops")
  if fo and fo.fleetOffline then
    for _, r in ipairs(fo.fleetOffline()) do
      local reach = 0.0
      for _, d in ipairs(r.parts or {}) do
        local q = math.sqrt((d.x or 0) ^ 2 + (d.z or 0) ^ 2)
        if q > reach then reach = q end
      end
      if in_box(S, r.wx, r.wy, r.wz, reach) then
        return { what = "parked", name = r.name or "a craft" }
      end
    end
  end
  -- The crew, out on foot on the site (not the one being sent out to board).
  local a = find("Astronaut")
  local pw = ref("planet_walker")
  if a and a.visible ~= false and pw and pw.onFoot and (save.get("shipyard.pilot") or 0) ~= 1
     and in_box(S, wpos(a)) then
    return { what = "crew", name = "the crew" }
  end
  return nil
end

local function site_label(kind)
  return kind == "runway" and "the runway" or "Launch Complex 1"
end

-- The notice, as one sentence the player can act on.
function blockSentence(kind, info)
  local where = site_label(kind)
  if not info then return nil end
  if info.what == "unready" then
    return string.format("%s did not come in: %s. Nothing was launched and the hull is refunded. Launch again in a moment.",
      kind == "runway" and "The runway" or "The launch pad", info.name or "its ground never answered")
  elseif info.what == "debris" then
    return string.format("Debris%s is lying on %s. Move it off (the gravity gun can shift it) and launch again.",
      info.name and (" from " .. info.name) or "", where)
  elseif info.what == "crew" then
    return string.format("The crew is standing on %s. Walk clear and launch again.", where)
  end
  return string.format("%s is standing on %s. Recover it at the Tracking Station, or fly or drive it off, then launch again.",
    info.name or "A craft", where)
end

-- For the builder's LAUNCH: nil when the site is clear, else the sentence.
function launchBlockedWhy(kind, b)
  kind = (kind == "runway") and "runway" or "pad"
  local info = siteBlocker(kind, b)
  return info and blockSentence(kind, info) or nil, info
end

local function caption(title, text, secs)
  local bc = ref("big_caption")
  if bc and bc.show then bc.show(title, text, secs or 6.0) end
end

-- CALLED OFF. Nothing was launched, so the hull that was charged at rollout
-- comes back, and the crew who were sent out to board are brought home.
local function refuse(kind, info)
  local msg = blockSentence(kind, info) or "The launch site is blocked."
  log("launch: REFUSED — " .. msg)
  local title = kind == "runway" and "RUNWAY BLOCKED" or "PAD BLOCKED"
  if info and info.what == "unready" then title = kind == "runway" and "RUNWAY NOT READY" or "PAD NOT READY" end
  caption(title, msg, 7.0)
  local spent = save.get("shipyard.spent") or 0
  local co = ref("company")
  if spent > 0 and co and co.earn then
    co.earn(spent, "rollout called off — " .. site_label(kind) .. " is blocked")
  end
  save.set("shipyard.spent", 0)
  save.set("shipyard.pilot", 0)
  save.set("shipyard.launch", 0)
  local a = find("Astronaut")
  if a and a.visible == false then
    local fo = ref("flight_ops")
    local hx, hy, hz
    if fo and fo.crewHome then hx, hy, hz = fo.crewHome() end
    if hx then a.x, a.y, a.z = hx, hy, hz end
    a.vx, a.vy, a.vz = 0, 0, 0
    a.visible = true
  end
  lastRefusal = { kind = kind, what = info and info.what, name = info and info.name, text = msg, t = time }
end
lastRefusal = nil   -- published for probes and the builder: the last launch called off

-- ═══ REVERT ═════════════════════════════════════════════════════════════════
--
-- KSP's "Revert to launch": the flight you are on is undone and you are back
-- in the seat on the pad as you rolled out — the same design, the same money,
-- the same hold and contracts — so a mission that went wrong is a restart, not
-- a recovery run. And "Revert to the builder", which also hands back the hull.
--
-- What is snapshotted at the launch is the small game state that a flight can
-- change (REVERT_KEYS, the inventories, the design), not the save: dug
-- terrain runs to hundreds of MB and the ground you dug stays dug. Every craft
-- and piece the flight put in the world carries its flight's tag, and a revert
-- takes away exactly those.
--
-- FRESH. Revert is only there while the flight is still the one you launched
-- (KSP takes it away once you go back to the space centre). It goes for good
-- when the flight's rewards are banked — a contract or a milestone paid, a
-- recovery, any money coming in — when you fly another craft, end the flight
-- (END FLIGHT, ABORT, a pickup), or go into the builder.
local REVERT_KEYS = {
  "co.funds", "co.rep", "co.ledger", "co.standingNews",
  "res.done", "res.spent",
  "mission.active", "mission.activeSpec", "mission.board", "mission.seen", "mission.perm",
  "mission.gdone", "mission.gcount", "mission.done", "mission.flags", "mission.visited",
  "mission.recovered", "mission.charterPaid", "mission.genSeq",
  "prog.done", "prog.perm",
  "inv.cap", "inv.seen", "depot.sold", "names.n",
  -- the crew (scripts/crew.lua): the roster's own keys; each member's record
  -- and pack are taken by snap_state from the roster
  "crew.roster", "crew.seq", "crew.active", "crew.offers", "crew.offerSeq",
  "inv.vcap",                -- the containers' litre capacities (WS3)
}
-- Rewards: a change in any of these means the flight has been paid for.
local BANKED_KEYS = { "mission.done", "mission.gcount", "prog.done", "mission.charterPaid", "mission.recovered" }

local flight = nil          -- the launch a revert would go back to
local flight_seq = 0
revertArmedAt, revertArmedKind = nil, nil
REVERT_CONFIRM = 5.0
revertGone = nil            -- why the last flight stopped being revertable (probes)

local function inv_cids(caps)
  local out = { astro = true, base = true }
  for cid in pairs(type(caps) == "table" and caps or {}) do out[cid] = true end
  return out
end

-- { names = every key taken (in order), [key] = its value or nil }
local function snap_state()
  local keys, names = {}, {}
  local function take(k) names[#names + 1] = k; keys[k] = deep(save.get(k)) end
  for _, k in ipairs(REVERT_KEYS) do take(k) end
  local cids = inv_cids(keys["inv.cap"])
  -- every crew member's record (status, suit air, RCS fill, task) and pack
  for _, id in ipairs(type(keys["crew.roster"]) == "table" and keys["crew.roster"] or {}) do
    take("crew.m." .. tostring(id))
    cids["crew:" .. tostring(id)] = true
  end
  for cid in pairs(cids) do
    take("inv." .. cid)
    take("inv.gear." .. cid)
    take("inv.fill." .. cid)   -- the Oxygen Tanks' fill levels (WS3)
    take("inv.issued." .. cid) -- the standard issue stamp (WS3)
  end
  keys.names = names
  -- the relay beacons (comms keeps them): one planted in flight is the pack's
  local net = ref("comms")
  keys.beacons = net and net.beaconSnapshot and net.beaconSnapshot() or nil
  -- flags and other deployables (deployables.lua keeps them), the same way
  local dep = ref("deployables")
  keys.deployables = dep and dep.snapshot and dep.snapshot() or nil
  return keys
end

local function same(a, b)
  if type(a) ~= type(b) then
    -- nil, false and an empty table all mean "nothing yet" in these keys
    local function empty(x) return x == nil or x == false or (type(x) == "table" and next(x) == nil) end
    return empty(a) and empty(b)
  end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not same(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil and not same(nil, b[k]) then return false end end
  return true
end

-- Take the snapshot: called as a launch begins (the hull already paid for).
local function snapshot(kind, b)
  flight_seq = flight_seq + 1
  local pre = {}
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.node and v.node.valid ~= false then pre[v.node.id] = true end
  end
  flight = {
    tag = string.format("flight%d_%d", flight_seq, math.floor((time or 0) * 1000)),
    kind = kind, bp = deep(b), keys = snap_state(), t0 = time or 0,
    spent = save.get("shipyard.spent") or 0, pre = pre, name = b and b.name,
    check_t = time or 0,
  }
  tag_names[flight.tag] = (b and b.name) or "your last launch"
  spawn_tag = flight.tag
  revertArmedAt, revertArmedKind, revertGone = nil, nil, nil
end

-- The flight is no longer revertable (`why` for the log and probes).
function flightClosed(why)
  if not flight then return end
  flight = nil
  revertArmedAt, revertArmedKind = nil, nil
  revertGone = why or "closed"
  log("revert: no longer available — " .. revertGone)
end

-- Does this controller fly (part of) the flight?
local function ours(v)
  local n = v and v.node
  if not (flight and n and n.valid ~= false and n.children) then return false end
  if flight.root_id and n.id == flight.root_id then return true end
  for _, c in ipairs(n:children()) do
    if c.hasTag and c:hasTag(flight.tag) then return true end
  end
  return false
end

-- Has the flight been paid for, or left behind? Asked twice a second.
local function freshness_tick()
  if not flight or (time or 0) - flight.check_t < 0.5 then return end
  flight.check_t = time or 0
  local gm = ref("game_manager")
  if gm and gm.inputOwner == "builder" then return flightClosed("you went into the builder") end
  for _, k in ipairs(BANKED_KEYS) do
    if not same(flight.keys[k], save.get(k)) then return flightClosed("the flight's rewards are banked (" .. k .. ")") end
  end
  for _, e in ipairs(save.get("co.ledger") or {}) do
    if type(e) == "table" and (e.amount or 0) > 0 and (e.t or -1) > flight.t0 then
      return flightClosed("money came in since the launch (" .. tostring(e.why) .. ")")
    end
  end
  -- (not while the craft is still being put together: its parts arrive a
  -- frame or two after its controller)
  if want_spawn or not rebuilt then return end
  -- Off the craft before it ever left the launch site (a revert would only
  -- put back what stands there): the offer goes. A craft that has flown
  -- keeps it through an EVA, as KSP's does.
  local bf = ref("base_facilities")
  local st = bf and bf.launchSite and bf.launchSite(flight.kind)
  local body = st and space.body(st.body)
  local aboard = false
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.piloting and not ours(v) then return flightClosed("you are flying another craft") end
    if ours(v) then
      if v.piloting then aboard = true end
      local n = v.node
      if body and n and n.valid ~= false then
        local dx, dy, dz = n.x - (body.x + st.x), n.y - (body.y + st.y), n.z - (body.z + st.z)
        if dx * dx + dy * dy + dz * dz > 60 * 60 then flight.flew = true end
      end
    end
  end
  if aboard then flight.boarded = true
  elseif flight.boarded and not flight.flew then return flightClosed("the crew got off on the launch site") end
end

-- What a revert would do now: nil when there is no fresh flight; otherwise
-- { ok, why, builder } — `why` when it can't (docked to an older craft).
function revertQuote()
  if not flight then return nil end
  local q = { ok = true, name = flight.name, kind = flight.kind }
  local bh = ref("build_host")
  q.builder = bh ~= nil and bh.mode == "world" and bh.state == "idle"
  for _, v in ipairs(findScripts("vessel_controller")) do
    if ours(v) then
      if flight.pre[v.node.id] then q.ok, q.why = false, "it is docked to a craft that was there before the launch" end
      if v.dock and (v.dock.latched or 0) > 0 then q.ok, q.why = false, "it is docked to another craft" end
    end
  end
  return q
end

function canRevert() return flight ~= nil end
-- The tag this flight's parts carry (probes and the smoke harness).
function flightTag() return flight and flight.tag end

-- Every root the flight put in the world: its craft and what they shed.
local function flight_roots()
  local roots, crafts = {}, {}
  if findTagged then
    for _, p in ipairs(findTagged(flight.tag)) do
      if p.valid ~= false then
        -- A craft or a piece of one is a top-level root (a Vessel, or what a
        -- split made). Anything else a part has come to hang under — a world
        -- it was parented to — is never taken away: only the part goes.
        local r = p.parent
        if not r or r.parent ~= nil or (r.name and space.body(r.name)) then r = p end
        if r.valid ~= false then roots[r.id] = r end
      end
    end
  end
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.node and roots[v.node.id] then crafts[#crafts + 1] = v end
  end
  return roots, crafts
end

local function restore_state(keys)
  local now_cids = inv_cids(save.get("inv.cap"))   -- (before inv.cap goes back)
  -- every key taken, put back as it was — or taken away, if it wasn't there
  for _, k in ipairs(keys.names) do
    local v = keys[k]
    if v == nil then
      if save.get(k) ~= nil then save.delete(k) end
    else
      save.set(k, deep(v))
    end
  end
  -- An inventory opened since the launch (the new craft's hold) is put away.
  local had = inv_cids(keys["inv.cap"])
  for cid in pairs(now_cids) do
    if not had[cid] then save.delete("inv." .. cid); save.delete("inv.gear." .. cid) end
  end
  -- Scripts that keep a copy in memory read it again.
  local ms = ref("missions")
  if ms then
    if ms.reloadFromSave then ms.reloadFromSave() elseif ms.start then pcall(ms.start, ms.node) end
  end
  local rs = ref("research")
  if rs then rs.spent = save.get("res.spent") or 0 end
  local net = ref("comms")
  if keys.beacons and net and net.beaconRestore then net.beaconRestore(keys.beacons) end
  local dep = ref("deployables")
  if keys.deployables and dep and dep.restore then dep.restore(keys.deployables) end
end

-- Clear the flight off the world: crew out of the seat, every craft and piece
-- gone, the launch's hold-downs taken up, the fleet board forgets them.
local function clear_flight()
  local roots, crafts = flight_roots()
  for _, v in ipairs(crafts) do
    if (v.piloting or v.crewAboard) and v.standDown then v.standDown(v.node)
    elseif v.releaseControl then v.releaseControl() end
  end
  local ids = {}
  for id, r in pairs(roots) do
    ids[#ids + 1] = id
    -- The root takes its parts with it, a shed stage's bare split root too
    -- (since engine 0.117.0-rc11; rc8-rc10 left that root and its parts
    -- behind, so they went one by one here).
    if r.valid ~= false then destroy(r) end
  end
  if flight.clamps and flight.clamps.valid ~= false then destroy(flight.clamps) end
  local fo = ref("flight_ops")
  if fo and fo.forgetNodes then fo.forgetNodes(ids) end
  -- the clamp pins of anything just removed
  local keep = {}
  for _, p in ipairs(pins) do if not roots[p.node.id] then keep[#keep + 1] = p end end
  pins = keep
  if vessel_node and roots[vessel_node.id] then vessel_node, relv, seat_placed = nil, nil, nil end
  if space.warp and (space.warp() or 1) > 1.001 then pcall(space.warp, 1) end
  return #ids
end

local function crew_to(x, y, z, hidden)
  local a = find("Astronaut")
  if not a then return end
  a.x, a.y, a.z = x, y, z
  a.vx, a.vy, a.vz = 0, 0, 0
  a.visible = not hidden
end

function revertToLaunch()
  local q = revertQuote()
  if not (q and q.ok) then return false, q and q.why or "nothing to revert" end
  if want_spawn then return false, "a launch is already under way" end
  local f = flight
  local bf = ref("base_facilities")
  local st = bf and bf.launchSite and bf.launchSite(f.kind)
  local body = st and space.body(st.body)
  if not body then return false, "no launch site to go back to" end
  local n = clear_flight()
  restore_state(f.keys)
  save.set("shipyard.blueprint", deep(f.bp))
  save.set("shipyard.site", f.kind)
  save.set("shipyard.spent", f.spent)
  save.set("shipyard.pilot", 1)
  -- the crew waits on the site to board, the way a rollout leaves them
  crew_to(body.x + st.x + st.up.x * 3.0, body.y + st.y + st.up.y * 3.0, body.z + st.z + st.up.z * 3.0, true)
  flight = nil
  revertArmedAt, revertArmedKind = nil, nil
  log(string.format("revert: back to the launch of %s (%d piece(s) cleared)", tostring(f.name or "the craft"), n))
  local ok = launchNow(f.kind, { force = true, bp = f.bp })
  if not ok then return false, "the relaunch would not start" end
  caption("REVERTED TO LAUNCH", "Back on " .. site_label(f.kind) .. " as you rolled out. Everything since the launch is undone.", 4.0)
  return true
end

function revertToBuilder()
  local q = revertQuote()
  if not (q and q.ok) then return false, q and q.why or "nothing to revert" end
  if not q.builder then return false, "the builder is not available here" end
  local f = flight
  local vab = find("VabInterior")
  if not vab then return false, "no Vehicle Assembly Building standing" end
  local n = clear_flight()
  restore_state(f.keys)
  -- …and the hull goes back on the books: nothing was launched.
  local co = ref("company")
  if co and co.earn and (f.spent or 0) > 0 then co.earn(f.spent, "reverted to the builder — hull refunded") end
  save.set("shipyard.blueprint", deep(f.bp))
  save.set("shipyard.site", f.kind)
  save.set("shipyard.spent", 0)
  save.set("shipyard.pilot", 0)
  save.set("shipyard.launch", 0)
  -- the crew stands inside the VAB's south door, where LEAVE will let them out
  if vab.toWorld then
    local p = vab:toWorld(vec3(0, 1.4, 14))
    crew_to(p.x, p.y, p.z, false)
  end
  flight = nil
  revertArmedAt, revertArmedKind = nil, nil
  log(string.format("revert: back to the builder with %s (%d piece(s) cleared, hull refunded)", tostring(f.name or "the craft"), n))
  local bh = ref("build_host")
  local ok = bh and bh.enter and bh.enter()
  if not ok then return false, "the builder would not open" end
  return true
end

-- The pause menu's and the HUD's rows: text, armed, and the click (the first
-- arms, the second within REVERT_CONFIRM seconds goes).
function revertArmed(kind)
  return revertArmedAt ~= nil and revertArmedKind == kind and (time or 0) - revertArmedAt <= REVERT_CONFIRM
end

function revertLabel(kind)
  if kind == "builder" then
    return revertArmed("builder") and "Revert to the builder? Progress since launch is lost"
      or "Revert to the builder (hull refunded)"
  end
  return revertArmed("launch") and "Revert to launch? Progress since launch is lost"
    or "Revert to launch"
end

-- Returns true once the revert has happened.
function revertClick(kind)
  kind = kind == "builder" and "builder" or "launch"
  local q = revertQuote()
  if not (q and q.ok) then return false end
  if revertArmed(kind) then
    local ok, why
    if kind == "builder" then
      ok, why = revertToBuilder()
    else
      -- Through the rollout's black (build_host.fadeThrough): the world is
      -- not seen being cleared and the craft put back; it fades in on the
      -- craft seated on the clamps. Without the host, at once.
      local bh = ref("build_host")
      if bh and bh.fading and bh.fading() then return false end
      revertArmedAt, revertArmedKind = nil, nil
      local failed = false
      if bh and bh.fadeThrough and bh.fadeThrough(function()
          local done, w = revertToLaunch()
          if not done then failed = true; log("revert: " .. tostring(w)) end
        end, function()
          if failed then return true end
          if launchState() ~= "ready" then return false end
          for _, v in ipairs(findScripts("vessel_controller")) do if v.piloting then return true end end
          return false
        end) then
        return true
      end
      ok, why = revertToLaunch()
    end
    if not ok then log("revert: " .. tostring(why)) end
    return ok
  end
  revertArmedAt, revertArmedKind = time or 0, kind
  return false
end

function start(node)
  if save.get("shipyard.launch") ~= 1 then
    save.set("shipyard.pilot", 0) -- a stale handoff flag must not park the walker
    return
  end
  save.set("shipyard.launch", 0)
  site_wait, waitingFor = 0.0, nil
  site_kind = save.get("shipyard.site") == "runway" and "runway" or "pad"
  bp = save.get("shipyard.blueprint")
  if not bp or not bp.parts then
    save.set("shipyard.pilot", 0)
    return
  end
  want_spawn = true
  force_site = false
  snapshot(site_kind, bp)
  log("launch: vessel blueprint aboard — waiting for the pad terrain…")
end

-- LAUNCH IN PLACE. The builder now runs inside the real VAB over this very
-- scene (scripts/build_host.lua), so a launch no longer reloads the world to
-- get here: build_host calls this behind its fade, with the blueprint saved
-- and `shipyard.pilot` set exactly as the builder always left them, and the
-- same spaceport path as a scene start puts the craft on the pad or the
-- runway threshold and seats the pilot. A craft from an earlier rollout that
-- is still clamped keeps its pin (`pins`).
--
-- The site is looked at first (siteBlocker): a launch onto a craft, its
-- debris or the crew is called off — false, "blocked", what is there — with
-- the notice, the hull refunded and the crew brought home. `opts.force` (a
-- revert, which has just cleared its own craft away) skips the look.
function launchNow(kind, opts)
  opts = opts or {}
  if want_spawn then return false, "busy" end
  local b = opts.bp or save.get("shipyard.blueprint")
  if not b or not b.parts then return false, "no blueprint" end
  local k = (kind == "runway" or (kind == nil and save.get("shipyard.site") == "runway")) and "runway" or "pad"
  if not opts.force then
    local info = siteBlocker(k, b)
    if info then
      refuse(k, info)
      return false, "blocked", info
    end
  end
  save.set("shipyard.launch", 0)
  bp = b
  site_kind = k
  if vessel_node and vessel_node.valid and relv and body_name then
    pins[#pins + 1] = { node = vessel_node, rel = relv, body = body_name }
  end
  pending, vessel_node, relv, assemble_t, rebuilt = 0, nil, nil, nil, false
  seat_placed = nil
  wait_t, last_note, site_wait = 0.0, 0.0, 0.0
  want_spawn = true
  force_site = true -- looked at just now
  snapshot(site_kind, bp)
  log("launch: rolling out from the VAB (" .. site_kind .. ")")
  return true
end

-- Where an in-place launch has got to: "waiting" (for the site's ground),
-- "assembling" (parts landing), "ready" (assembled and clamped), or nil.
function launchState()
  if want_spawn then return "waiting" end
  if vessel_node and vessel_node.valid then return rebuilt and "ready" or "assembling" end
  return nil
end


-- The craft's FRONT in its own frame (level, x–z), the rule vessel_controller
-- drives by (r2FrontOf): a rover body's or a seat's +X, else the command
-- part's +X, else the vessel's +X.
local function craft_front(parts)
  local best, bu
  local function level(d)
    local cy, sy = math.cos(d.yaw or 0), math.sin(d.yaw or 0)
    local cx, sx = math.cos(d.pitch or 0), math.sin(d.pitch or 0)
    local cz, sz = math.cos(d.roll or 0), math.sin(d.roll or 0)
    local X1, X3 = cy * cz + sy * sx * sz, -sy * cz + cy * sx * sz
    local l = math.sqrt(X1 * X1 + X3 * X3)
    if l < 0.5 then return nil end
    return X1 / l, X3 / l
  end
  -- A PLANE rolls out nose first: a cockpit (its aero spec says "cockpit")
  -- flies along its own +Y, so that is the front the runway turns down.
  for _, d in pairs(parts or {}) do
    if type(d.af) == "string" and (" " .. d.af .. " "):find(" cockpit ") then
      local cy, sy = math.cos(d.yaw or 0), math.sin(d.yaw or 0)
      local cx, sx = math.cos(d.pitch or 0), math.sin(d.pitch or 0)
      local cz, sz = math.cos(d.roll or 0), math.sin(d.roll or 0)
      local Y1, Y3 = -cy * sz + sy * sx * cz, sy * sz + cy * sx * cz
      local l = math.sqrt(Y1 * Y1 + Y3 * Y3)
      if l > 0.5 then return Y1 / l, Y3 / l end
    end
  end
  for _, d in pairs(parts or {}) do
    if (d.front or 0) == 1 or (d.seat or 0) == 1 or d.seat == true then
      if not bu or (d.uid or 0) < bu then
        local fx, fz = level(d)
        if fx then best, bu = { fx, fz }, d.uid or 0 end
      end
    end
  end
  if best then return best[1], best[2] end
  for _, d in pairs(parts or {}) do
    if d.kind == "pod" or d.kind == "probe" or d.kind == "command" then
      local fx, fz = level(d)
      if fx then return fx, fz end
    end
  end
  return 1, 0
end

-- The node's −Z (setUp's forward) that turns a craft whose front is (fx, fz)
-- in its own frame to face world direction D, standing on `up`: the vessel's
-- +X goes along D rotated back by the front's own angle about up.
local function facing_for(up, D, fx, fz)
  local a = math.atan2(fz, fx)            -- the front's angle from +X toward +Z
  -- in the vessel frame +Z = X × up; a world direction rotated about `up` by
  -- −a from D is where +X must point
  local ux, uy, uz = up.x, up.y, up.z
  local function rot(vx, vy, vz, ang)
    local c, s = math.cos(ang), math.sin(ang)
    local kx, ky, kz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
    local k = ux * vx + uy * vy + uz * vz
    return vx * c + kx * s + ux * k * (1 - c), vy * c + ky * s + uy * k * (1 - c), vz * c + kz * s + uz * k * (1 - c)
  end
  for _, sg in ipairs({ 1, -1 }) do
    local xx, xy, xz = rot(D.x, D.y, D.z, sg * a)
    -- +Z = X × up
    local zx, zy, zz = xy * uz - xz * uy, xz * ux - xx * uz, xx * uy - xy * ux
    local fwx, fwy, fwz = xx * fx + zx * fz, xy * fx + zy * fz, xz * fx + zz * fz
    if fwx * D.x + fwy * D.y + fwz * D.z > 0.999 then
      return vec3(-zx, -zy, -zz)          -- setUp's forward is the node's −Z
    end
  end
  return vec3(-D.x, -D.y, -D.z)
end

-- ═══ IS THE SITE THERE? ═════════════════════════════════════════════════════
--
-- A craft is only put together over the thing it is meant to stand on. The
-- old gate asked for "something under the deck point, and the terrain near
-- it": the terrain 1.9 m under the pad answered that before base_facilities
-- had put Launch Complex 1 down (the base waits for its own ground, and the
-- two waits race after a scene load), so the 1,002-part craft was assembled
-- over no deck — in one bigpark run of five the pad never came in under it
-- and on release it fell 15 m into the sea. Now:
--   * the PAD: rays down through the craft's footprint (the centre and four
--     points round it) must strike the pad's own structure (SITE_NODE, the
--     BasePad base_facilities places) at its deck height;
--   * the RUNWAY: a ray at the threshold must strike ground within a couple
--     of metres of the site point, and that ground must be final
--     (terrain.ready over the craft's reach — not a stand-in).
-- Until then the launch WAITS (the caption says so; build_host holds its
-- black). If the site still is not there after SITE_WAIT s (SITE_WAIT_BASE
-- while the base has not put its pad down at all), the launch is CALLED OFF
-- the way a blocked pad is: nothing assembled, the hull refunded, the crew
-- home. A launch never drops a craft and never waits for ever.
--
-- A NEW SAVE'S FIRST LAUNCH must never be refused: the base is still going
-- up and grading its ground then (the runway read 4.9 m off its site and the
-- pad "not down yet" in WS3's probe, called off after 30 s). The base counts
-- as BUSY while it is not sited or while base_facilities.grading() owes
-- ground work; a busy base gets SITE_WAIT_BASE,
-- and the plain SITE_WAIT counts only from the moment the base stopped being
-- busy (`calm`). A sited base that has finished its ground work and still
-- shows no pad is not going to: that waits SITE_WAIT, as before. The guarantee is unchanged: nothing is assembled until the
-- site answers, and the wait ends.
SITE_NODE = "BasePad"
SITE_WAIT, SITE_WAIT_BASE = 30.0, 180.0
SITE_CALM = { t = 0.0 }   -- seconds since the base was last busy (a global: no new chunk local)
DECK_TOP = { lo = 1.5, hi = 3.5 }   -- the deck's top over the site point (Shell 3 reads 2.49)

-- "go", "wait" or "refuse": `waited` s of looking, `ready` the site answered,
-- `base_busy` the base has not put its pad down yet. Global for the tests.
function siteGate(waited, ready, base_busy, calm)
  if ready then return "go" end
  if base_busy then return waited < SITE_WAIT_BASE and "wait" or "refuse" end
  if math.min(waited, calm or waited) < SITE_WAIT then return "wait" end
  return "refuse"
end

-- The ancestor chain of a hit node holds a node named `name`?
local function under_named(n, name)
  for _ = 1, 8 do
    if not (n and n.valid ~= false) then return false end
    if n.name == name then return true end
    n = n.parent
  end
  return false
end

-- Is the launch site's surface there under the craft's footprint? true, or
-- false and why (for the log and the refusal).
function siteReady(st, body, b)
  local up = st.up
  local gx, gy, gz = body.x + st.x, body.y + st.y, body.z + st.z
  -- (looked past: the crew waiting on the site, and the hold-downs an earlier
  -- launch left on the deck, taken up once the craft goes ahead)
  local skip = {}
  local crew0 = find("Astronaut")
  if crew0 then skip[#skip + 1] = crew0 end
  for _, c in ipairs(pad_clamps) do if c.valid ~= false then skip[#skip + 1] = c end end
  local ign = #skip > 0 and { ignore = skip } or nil
  local reach = bp_size(b)
  -- two level directions across the site: its forward, and up × forward
  local fx, fy, fz = st.fwd.x, st.fwd.y, st.fwd.z
  local rx, ry, rz = up.y * fz - up.z * fy, up.z * fx - up.x * fz, up.x * fy - up.y * fx
  if st.deck then
    local want = st.node or SITE_NODE
    local off = math.max(1.0, math.min(3.0, reach))
    local pts = { { 0, 0 }, { off, 0 }, { -off, 0 }, { 0, off }, { 0, -off } }
    for i, p in ipairs(pts) do
      local px = gx + fx * p[1] + rx * p[2]
      local py = gy + fy * p[1] + ry * p[2]
      local pz = gz + fz * p[1] + rz * p[2]
      -- (from 2 m over the deck: a gantry arm overhead is not the deck)
      local top = DECK_TOP.hi + 2.0
      local hit = raycast(px + up.x * top, py + up.y * top, pz + up.z * top, -up.x, -up.y, -up.z, top + 8.0, ign)
      if not (hit and hit.distance) then return false, "nothing under the deck" end
      if not (hit.node and under_named(hit.node, want)) then
        return false, i == 1 and "the pad is not down yet" or "the pad does not reach under the craft"
      end
      local h = top - hit.distance
      if h < DECK_TOP.lo or h > DECK_TOP.hi then
        return false, string.format("the pad's deck reads %.1f m over the site", h)
      end
    end
    return true
  end
  -- the runway: final ground at the threshold, where the site says it is
  if terrain.ready and not terrain.ready(gx, gy, gz, math.max(10.0, reach + 2.0)) then
    return false, "the ground there is not final yet"
  end
  local hit = raycast(gx + up.x * 40, gy + up.y * 40, gz + up.z * 40, -up.x, -up.y, -up.z, 120.0, ign)
  if not (hit and hit.distance) then return false, "nothing under the threshold" end
  local h = 40 - hit.distance
  if h < -2.5 or h > 2.5 then return false, string.format("the ground reads %.1f m off the site", h) end
  return true
end

local function site_caption(kind, on)
  local bc = ref("big_caption")
  if not (bc and bc.show) then return end
  local title = kind == "runway" and "WAITING FOR THE RUNWAY" or "WAITING FOR THE LAUNCH PAD"
  if on and site_note ~= title then
    site_note = title
    bc.show(title, kind == "runway" and "Waiting for the runway…" or "Waiting for the launch pad…", SITE_WAIT_BASE)
  elseif not on and site_note then
    if bc.current == site_note and bc.hide then bc.hide() end
    site_note = nil
  end
end

-- What a waiting launch is waiting for, or nil (build_host shows it on its
-- black; probes read it).
waitingFor = nil

-- LAUNCH FROM THE SPACEPORT. Returns true once the craft is on its way (or
-- the launch is called off), false to wait (the site not ready yet), nil when
-- this save has no spaceport here.
local function try_spaceport(dt)
  local bf = findScript("base_facilities")
  local st = bf and bf.launchSite and bf.launchSite(site_kind)
  if not st then return nil end
  local body = space.body(st.body)
  if not body then return nil end
  local crew = find("Astronaut")
  if crew then
    local dx, dy, dz = crew.x - body.x, crew.y - body.y, crew.z - body.z
    if dx * dx + dy * dy + dz * dz > (body.soi or 1e9) ^ 2 then return nil end
  end
  terrain.warm(st.body)
  local up = st.up
  local gx, gy, gz = body.x + st.x, body.y + st.y, body.z + st.z
  local ok, why = siteReady(st, body, bp)
  if not ok then
    site_wait = site_wait + (dt or 0)
    local base_busy = (not bf.sited) or (bf.grading ~= nil and bf.grading() == true)
    if base_busy or site_wait <= (dt or 0) then SITE_CALM.t = 0.0 else SITE_CALM.t = SITE_CALM.t + (dt or 0) end
    local gate = siteGate(site_wait, false, base_busy, SITE_CALM.t)
    waitingFor = st.kind == "runway" and "Waiting for the runway…" or "Waiting for the launch pad…"
    if site_wait > 1.0 then site_caption(st.kind, true) end
    if gate == "refuse" then
      log(string.format("launch: the %s never came in (%s) after %.0f s — called off", st.kind, why or "?", site_wait))
      waitingFor = nil
      site_caption(st.kind, false)
      refuse(st.kind, { what = "unready", name = why })
      flightClosed("the launch was called off")
      return true
    end
    if site_wait - (last_note or 0) > 5.0 then
      last_note = site_wait
      log(string.format("launch: waiting for the %s… (%s, %.0fs)", st.kind == "runway" and "runway" or "launch pad", why or "?", site_wait))
    end
    return false
  end
  if site_wait > 0 then
    log(string.format("launch: the %s is there — %.1f s after the launch first looked", st.kind, site_wait))
  end
  waitingFor = nil
  site_caption(st.kind, false)
  -- (a scene that loaded with a launch aboard looks here; launchNow looked
  -- before it set off)
  if not force_site then
    local info = siteBlocker(st.kind, bp)
    if info then
      refuse(st.kind, info)
      flightClosed("the launch was called off")
      return true
    end
  end
  force_site = false
  body_name = st.body
  local planet_node = find(body_name)
  local deck = st.deck and 1.24 or 0.0
  SEAT_DECK = st.deck and true or false
  local relg = { x = st.x, y = st.y, z = st.z }
  local fo = findScript("flight_ops")
  if fo and fo.rerateAtPad then
    local cm, mt = 0.0, 0.0
    for _, d in pairs(bp.parts or {}) do
      local m = d.mass or 0
      cm, mt = cm + m * (d.y or 0), mt + m
    end
    local h = deck * 2.0 + params.clear + (mt > 0 and math.max(0, cm / mt) or 0)
    local rb = fo.rerateAtPad(bp, body_name, gx + up.x * h, gy + up.y * h, gz + up.z * h)
    if rb then bp = rb; save.set("shipyard.blueprint", bp) end
  end
  local fwd = nil
  if st.kind == "runway" then
    local fx, fz = craft_front(bp.parts)
    fwd = facing_for(up, st.fwd, fx, fz)
  end
  local function vessel()
    local b2 = space.body(body_name) or body
    local h = deck * 2.0 + params.clear
    local vx, vy, vz = b2.x + relg.x + up.x * h, b2.y + relg.y + up.y * h, b2.z + relg.z + up.z * h
    relv = { x = vx - b2.x, y = vy - b2.y, z = vz - b2.z }
    spawn("Vessel", vec3(vx, vy, vz), function(v)
      if fwd then v:setUp(vec3(up.x, up.y, up.z), fwd) else v:setUp(vec3(up.x, up.y, up.z)) end
      vessel_node = v
      if flight then flight.root_id = v.id end
      spawn_parts(v, bp)
    end)
  end
  if st.deck then
    -- The pad is clear (looked at above), so the hold-downs an earlier launch
    -- put down are nobody's now: take them up rather than stack another set
    -- in the same place every launch.
    for _, old in ipairs(pad_clamps) do
      if old.valid ~= false then destroy(old) end
    end
    pad_clamps = {}
    local fl = flight
    -- the hold-down posts on the mount: the same deck box the Launchpad had
    spawn("PadClamps", vec3(gx + up.x * deck, gy + up.y * deck, gz + up.z * deck), function(lp)
      pad_clamps[#pad_clamps + 1] = lp
      if fl then fl.clamps = lp end
      lp:setUp(vec3(up.x, up.y, up.z), vec3(-st.fwd.x, -st.fwd.y, -st.fwd.z))
      if planet_node then lp.x, lp.y, lp.z = relg.x + up.x * deck, relg.y + up.y * deck, relg.z + up.z * deck end
      vessel()
    end, planet_node)
    log("launch: Launch Complex 1 — the hold-downs are on, vessel assembling")
  else
    vessel()
    log("launch: rolled out to the runway threshold, vessel assembling")
  end
  return true
end

local function try_spawn(dt)
  -- Not while the loading screen is up: the crew is parked over the spawn
  -- world's NORTH POLE then, and that is the first ground to answer the
  -- terrain probe below — the pad went down there, a quarter of the world
  -- (1.1 km on Vever) round from the base, out of the base dish's sight, so
  -- every probe craft on it read "NO SIGNAL — blocked by Vever". The crew is
  -- moved to the base (game_manager launch_site) the frame loading ends.
  local gm = findScript("game_manager")
  if gm and gm.loading then return false end
  local sp = try_spaceport(dt)
  if sp ~= nil then return sp end
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
  SEAT_DECK = true   -- (the dropped pad is the deck it stands on)
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
      if flight then flight.root_id = v.id end
      spawn_parts(v, bp)
    end)
  end, planet_node)
  log("launch: pad down, vessel assembling")
  return true
end

function update(node, dt)
  freshness_tick()
  spawn_drain()
  if want_spawn then
    wait_t = wait_t + dt
    if try_spawn(dt) then want_spawn = false end
    return
  end

  -- Stall self-heal: a part whose spawn never lands (bad prefab name in an
  -- old blueprint) must not wedge the whole launch — build the compound from
  -- whatever DID arrive and say so.
  if not rebuilt and assemble_t and pending > 0 and time - assemble_t > 8.0
    and not (spawnPending and spawnPending() > 0)
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
      -- (the ground under a held runway craft can still move: a base grade)
      if seat_placed then
        seat_t = seat_t + (dt or 0)
        if seat_t >= SEAT_EVERY then seat_t = 0.0; reseat("held") end
      end
      local b = space.body(body_name)
      if b then
        assembly.teleport(vessel_node,
          vec3(b.x + relv.x, b.y + relv.y, b.z + relv.z))
      end
    elseif info then
      relv, seat_placed = nil, nil -- released: the pin's job is done
    end
  end
  -- (the pins of earlier in-place rollouts, the same rule)
  local i = 1
  while i <= #pins do
    local p = pins[i]
    local info = p.node.valid and assembly.info(p.node) or nil
    if info and info.anchored then
      local b = space.body(p.body)
      if b then assembly.teleport(p.node, vec3(b.x + p.rel.x, b.y + p.rel.y, b.z + p.rel.z)) end
      i = i + 1
    else
      table.remove(pins, i)
    end
  end
end
