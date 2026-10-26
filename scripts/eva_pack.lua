-- EVA PACK — the RCS Pack on a crew member's back: cold-gas thrusters for EVA
-- where there is no ground to walk on (docs/crew-and-items.md §5.7). Rides the
-- CrewLib node with crew.lua; drives the `Astronaut` body.
--
-- A WORN item (items.lua `rcspack`): having one in the pack is enough; it
-- never takes the hand. Thrust is live while the wearer is off the ground and
-- either in space (nothing under them for 50 m) or on a world whose gravity
-- is under `g_max` — on a heavier world it can't lift a suit, and the chip
-- says so.
--
--   W A S D        translate, relative to the camera's view
--   SPACE / CTRL   up / down along the camera's up
--   SHIFT (hold)   burst: 1.6× thrust, 1.6× propellant
--   X              HOLD: null the velocity relative to the nearest craft
--                  (within 200 m), then keep it there; any translation key
--                  suspends it and it resumes 1 s after you let go. On for
--                  2 s after an EVA and after a repair lets go in space.
--
-- THE PHYSICS. The suit stays the same dynamic capsule; this only ever ADDS
-- a Δv each tick (thrust / mass × dt) and never writes an absolute velocity:
-- velocities here are orbital and frame-dependent. HOLD compares the suit's
-- velocity with the reference craft's point velocity THIS tick
-- (info.vel + angVel × (suit − com)); the craft is kept as a node id, never a
-- position, so nothing goes stale while the planet moves 1.5–6 m a tick.
--
-- PROPELLANT is the craft's own (RCS thrusters draw the same pool): a full
-- pack is `prop` units, `isp_dv` m/s of Δv. The fill rides the crew record
-- (`rcs`) while it is carried; a pack in a locker or at base is full.
-- Boarding refills it from the craft (refill), costing that craft's fuel.
--
-- EVA WITHOUT A PACK IN SPACE is allowed, after a warning (§3.3): askEva
-- puts up the confirm, default CANCEL (Enter cancels; EVA anyway is a click).
--
-- API: rcsLeft(id) → units, cap · refill(id, vessel_node) → units · hold(on)
--      holdFor(secs, vessel_node) · reference() → node|nil · inSpace() → bool
--      live → bool (thrust available now) · askEva(id, text) · evaStarted(node)

defaults = {
  thrust = 90.0,     -- N
  burst = 1.6,
  prop = 4.0,        -- units of the craft's propellant in a full pack
  isp_dv = 30.0,     -- m/s from a full pack (loaded suit)
  g_max = 2.0,       -- m/s²: heavier worlds, no lift
  space_ray = 50.0,  -- m: nothing under you this far = space
  ref_range = 200.0, -- m: the reference craft for HOLD
  suit_kg = 100.0,   -- the suit and its wearer, before the pack's contents
  hold_resume = 1.0, -- s after the last translation key
  slew = 2.0,        -- rad/s: the suit turns to face the view
}

local function P(k) return (params and params[k]) or defaults[k] end
local function item_rcs()
  local I = findScript and findScript("items")
  local d = I and I.def and I.def("rcspack")
  return d and d.rcs or nil
end
-- the item's numbers when items.lua is there, these defaults otherwise
local function R(k)
  local r = item_rcs()
  if r and r[k] ~= nil then return r[k] end
  return P(k)
end

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not (r and r.valid ~= false) then
    r = findScript and findScript(kind) or nil
    refs[kind] = r
  end
  return r
end

local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function norm(x, y, z)
  local l = len(x, y, z)
  if l < 1e-9 then return 0, 0, 0 end
  return x / l, y / l, z / l
end

-- published state
live = false          -- thrust available now
present = false       -- the wearer has a pack
inSpaceNow = false    -- off the ground with nothing under them for 50 m
noLift = false        -- has a pack, off the ground, gravity too strong
holdOn = false        -- X: HOLD engaged
firing = false        -- any thruster firing this tick
relSpeed = nil        -- m/s relative to the reference craft
refName = nil
refDist = nil
used = 0.0            -- propellant used this EVA (probes)

local hold_until = nil  -- a timed HOLD (after an EVA or a release): time
local last_key_t = -10.0
local ref_id = nil      -- reference craft: node id
local rcs = nil         -- this EVA's fill (units), mirrored to the record
local rcs_saved = nil
local rcs_save_t = 0
local cache = { t = -10, space = false, g = 0 }

local function crew() return ref("crew") end
local function active_id()
  local c = crew()
  return c and c.activeId and c.activeId() or nil
end

local function has_pack(id)
  local c = crew()
  return c and c.hasPack and c.hasPack(id) or false
end

-- ── propellant ─────────────────────────────────────────────────────────────
function rcsLeft(id)
  id = id or active_id()
  local cap = R("prop")
  if not has_pack(id) then return 0, cap end
  if id == active_id() and rcs then return rcs, cap end
  local c = crew()
  local r = c and c.get and c.get(id)
  if r and type(r.rcs) == "number" then return math.min(cap, r.rcs), cap end
  return cap, cap
end

local function store_rcs(force)
  local id = active_id()
  if not (id and rcs) then return end
  if not force and (time - rcs_save_t < 2.0 or rcs_saved == rcs) then return end
  rcs_save_t, rcs_saved = time, rcs
  local c = crew()
  if c and c.patch then c.patch(id, { rcs = rcs }) end
end

-- Top the pack up from a craft's propellant (vessel_controller.fuelDraw,
-- the pool its RCS thrusters draw). → units added.
function refill(id, vnode)
  id = id or active_id()
  if not has_pack(id) then return 0 end
  local left, cap = rcsLeft(id)
  local want = cap - left
  if want <= 1e-6 then return 0 end
  local got = want
  if vnode then
    for _, v in ipairs(findScripts("vessel_controller")) do
      if v.node and v.node.id == vnode.id and v.fuelDraw then
        local f0 = v.fuel or 0
        v.fuelDraw(want)
        got = math.max(0, math.min(want, f0 - (v.fuel or 0)))
        if got <= 0 and f0 >= want then got = want end -- a pool that doesn't publish `fuel`
      end
    end
  end
  local c = crew()
  if c and c.patch then c.patch(id, { rcs = left + got }) end
  if id == active_id() then rcs = left + got; rcs_saved = rcs end
  if got > 0 then log(string.format("RCS Pack refilled: +%.2f units (%.2f / %.1f)", got, left + got, cap)) end
  return got
end

-- ── HOLD ───────────────────────────────────────────────────────────────────
function hold(on)
  holdOn = on and true or false
  if not holdOn then hold_until = nil end
end

-- HOLD for `secs` against craft `vnode` (after an EVA, after a repair
-- releases you in space).
function holdFor(secs, vnode)
  if vnode then ref_id = vnode.id end
  hold_until = time + (secs or 2.0)
end

function evaStarted(vnode)
  used = 0
  rcs = nil
  holdFor(2.0, vnode)
end

local function vessels() return findScripts and findScripts("vessel_controller") or {} end

-- The reference craft: the one HOLD named, while within range; else the
-- nearest loaded craft within `ref_range`.
local function find_ref(a)
  local best, bd = nil, nil
  for _, v in ipairs(vessels()) do
    local n = v.node
    if n and n.valid ~= false and not (v.isLost and v.isLost()) then
      local d = len(n.x - a.x, n.y - a.y, n.z - a.z)
      if n.id == ref_id and d < P("ref_range") * 1.5 then return v, d end
      if d < P("ref_range") and (not bd or d < bd) then best, bd = v, d end
    end
  end
  if best then ref_id = best.node.id end
  return best, bd
end

function reference()
  for _, v in ipairs(vessels()) do
    if v.node and v.node.id == ref_id then return v.node end
  end
  return nil
end

function inSpace() return inSpaceNow == true end

-- ── where are we ───────────────────────────────────────────────────────────
local function surroundings(a, pw)
  if time - cache.t < 0.25 then return cache.space, cache.g end
  cache.t = time
  local d = space and space.dominant and space.dominant(a.x, a.y, a.z)
  local b = d and space.body(d)
  local sp, g = true, 0
  if b then
    local ux, uy, uz = norm(a.x - b.x, a.y - b.y, a.z - b.z)
    local r = len(a.x - b.x, a.y - b.y, a.z - b.z)
    g = (b.mu or 0) / math.max(1, r * r)
    local hit = raycast and raycast(a.x, a.y, a.z, -ux, -uy, -uz, P("space_ray"), a) or nil
    sp = hit == nil
  end
  cache.space, cache.g = sp, g
  return sp, g
end

-- ── the confirm (EVA without a pack in space, §3.3) ────────────────────────
-- Immediate-mode (draw.*), centred over the view; the crew strip's portrait
-- confirm (WS2) replaces it later with the same calls.
local ask = nil   -- { id, text, t, n }
asking = false
function askEva(id, text)
  ask = { id = id, text = text or "No RCS Pack.", t = time }
  asking = true
  if input and input.setMouseLocked then pcall(input.setMouseLocked, false) end
end

-- Probes: answer the open confirm as a click would.
function answer(go)
  if not ask then return false end
  local id = ask.id
  ask, asking = nil, false
  if go then
    local c = crew()
    if c and c.eva then
      local ok, why = c.eva(id, { confirmed = true })
      if not ok then log("EVA: " .. tostring(why)) end
      return ok
    end
  end
  return true
end

local function wrap(text, n)
  local lines, line = {}, ""
  for w in tostring(text):gmatch("%S+") do
    if #line + #w + 1 > n and #line > 0 then lines[#lines + 1] = line; line = w
    else line = (#line > 0) and (line .. " " .. w) or w end
  end
  if #line > 0 then lines[#lines + 1] = line end
  return lines
end

local function draw_confirm()
  if not (ask and draw and draw.rect and camera and camera.screenSize) then return end
  local W, Hh = camera.screenSize()
  if not W or W <= 0 then return end
  local s = Hh / 720
  local w, h = 520 * s, 230 * s
  local x, y = (W - w) / 2, (Hh - h) / 2
  draw.rect(x, y, w, h, 0.07, 0.08, 0.10, 0.94, 6 * s)
  draw.rect(x, y, w, 4 * s, 0.95, 0.62, 0.12, 1.0)
  draw.text(x + 20 * s, y + 18 * s, "NO RCS PACK", 20 * s, 0.98, 0.72, 0.25, 1.0)
  local ly = y + 52 * s
  for _, l in ipairs(wrap(ask.text .. " (Pod lockers can carry one.)", 64)) do
    draw.text(x + 20 * s, ly, l, 14 * s, 0.86, 0.88, 0.9, 1.0)
    ly = ly + 19 * s
  end
  local bw, bh = 170 * s, 38 * s
  local by = y + h - bh - 18 * s
  local gx, cx = x + w - 2 * bw - 32 * s, x + w - bw - 20 * s
  local mx, my = 0, 0
  if input and input.mouse then mx, my = input.mouse() end
  local function over(bx) return mx >= bx and mx <= bx + bw and my >= by and my <= by + bh end
  -- EVA anyway: a deliberate click; Cancel: the default (Enter)
  draw.rect(gx, by, bw, bh, over(gx) and 0.55 or 0.32, 0.18, 0.12, 1.0, 4 * s)
  draw.text(gx + bw / 2, by + 10 * s, "EVA anyway", 16 * s, 1, 0.9, 0.85, 1.0, "center")
  draw.rect(cx - 3 * s, by - 3 * s, bw + 6 * s, bh + 6 * s, 0.95, 0.62, 0.12, 1.0, 5 * s)
  draw.rect(cx, by, bw, bh, over(cx) and 0.30 or 0.20, 0.24, 0.30, 1.0, 4 * s)
  draw.text(cx + bw / 2, by + 10 * s, "Cancel  (Enter)", 16 * s, 0.95, 0.95, 0.95, 1.0, "center")
  if input.clicked and input.clicked(0) then
    if over(gx) then answer(true) elseif over(cx) then answer(false) end
  elseif input.pressed and (input.pressed("enter") or input.pressed("escape")) then
    answer(false)
  end
end

-- ── the chip ───────────────────────────────────────────────────────────────
local function draw_chip(a)
  if not (draw and draw.text and camera and camera.screenSize) then return end
  local W, Hh = camera.screenSize()
  if not W or W <= 0 then return end
  local s = Hh / 720
  -- centred over the tool belt (the bottom-left corner is the flight card's)
  local x, y = W / 2 - 130 * s, Hh - 152 * s
  local left, cap = rcsLeft()
  draw.rect(x, y, 260 * s, 58 * s, 0.05, 0.06, 0.08, 0.72, 4 * s)
  draw.text(x + 10 * s, y + 6 * s, "RCS PACK", 12 * s, 0.98, 0.72, 0.25, 1.0)
  if noLift then
    draw.text(x + 90 * s, y + 6 * s, "no lift here", 12 * s, 0.9, 0.5, 0.4, 1.0)
  else
    draw.text(x + 90 * s, y + 6 * s, holdOn and "HOLD" or "free", 12 * s,
      holdOn and 0.5 or 0.8, holdOn and 0.95 or 0.8, holdOn and 0.6 or 0.8, 1.0)
  end
  local f = cap > 0 and left / cap or 0
  draw.rect(x + 10 * s, y + 24 * s, 240 * s, 6 * s, 0.2, 0.22, 0.25, 1.0)
  draw.rect(x + 10 * s, y + 24 * s, 240 * s * f, 6 * s, f < 0.25 and 0.95 or 0.4, f < 0.25 and 0.4 or 0.8, 0.5, 1.0)
  local line = refName and string.format("%s  %.0f m  %.2f m/s", refName, refDist or 0, relSpeed or 0) or "no craft within 200 m"
  draw.text(x + 10 * s, y + 36 * s, line, 12 * s, 0.85, 0.87, 0.9, 1.0)
end

-- ── input (frame) and thrust (tick) ────────────────────────────────────────
local cmd = { f = 0, s = 0, u = 0, burst = false }

local function held_now()
  local c = crew()
  return c and c.held and c.held() or false
end

function update(node, dt)
  draw_confirm()
  local pw = ref("planet_walker")
  local a = find and find("Astronaut")
  cmd.f, cmd.s, cmd.u, cmd.burst = 0, 0, 0, false
  if not (a and pw and pw.onFoot) or held_now() then live = false return end
  local id = active_id()
  present = id ~= nil and has_pack(id)
  if present and rcs == nil then rcs = rcsLeft(id) end
  if not present then live = false; noLift = false; holdOn = false return end
  if input.pressed("x") then
    hold(not holdOn)
    local fx = ref("sfx")
    if fx and fx.caption then fx.caption(holdOn and "RCS: HOLD" or "RCS: hold off") end
  end
  if input.key("w") then cmd.f = cmd.f + 1 end
  if input.key("s") then cmd.f = cmd.f - 1 end
  if input.key("d") then cmd.s = cmd.s + 1 end
  if input.key("a") then cmd.s = cmd.s - 1 end
  if input.key("space") then cmd.u = cmd.u + 1 end
  if input.key("ctrl") then cmd.u = cmd.u - 1 end
  cmd.burst = input.key("shift")
  if live and (cmd.f ~= 0 or cmd.s ~= 0 or cmd.u ~= 0) then last_key_t = time end
  if live or present then draw_chip(a) end
  store_rcs(false)
end

-- Scripted steering for probes: f/s/u in −1..1, like the keys.
local steer = nil
function steerCmd(f, s, u, burst)
  if f == nil then steer = nil else steer = { f = f, s = s or 0, u = u or 0, burst = burst == true } end
end
-- ...or a world direction (a probe flying home without a camera to aim).
local steer_w = nil
function steerWorld(x, y, z)
  if x == nil then steer_w = nil else steer_w = { norm(x, y, z) } end
end

function fixedUpdate(node, dt)
  local pw = ref("planet_walker")
  local a = find and find("Astronaut")
  firing = false
  if not (a and pw and pw.onFoot) or held_now() then live, inSpaceNow = false, false return end
  local sp, g = surroundings(a, pw)
  local grounded = pw.grounded == true
  inSpaceNow = sp and not grounded
  local id = active_id()
  present = id ~= nil and has_pack(id)
  local can = not grounded and (sp or g < R("g_max"))
  noLift = present and not grounded and not can
  live = present and can
  local v, d = find_ref(a)
  refName = v and (v.craftName or (v.node and v.node.name)) or nil
  refDist = d
  local pvx, pvy, pvz
  if v and v.node and assembly and assembly.info then
    local info = assembly.info(v.node)
    if info then
      pvx, pvy, pvz = info.vel.x, info.vel.y, info.vel.z
      if info.angVel and info.com then
        local w, c = info.angVel, info.com
        -- the suit's node lags this tick's carry as the craft's does: compare
        -- in the physics frame (vessel_controller.nodeLag)
        local kx, ky, kz = 0, 0, 0
        if info.origin then kx, ky, kz = info.origin.x - v.node.x, info.origin.y - v.node.y, info.origin.z - v.node.z end
        local qx, qy, qz = a.x + kx - c.x, a.y + ky - c.y, a.z + kz - c.z
        pvx, pvy, pvz = pvx + w.y * qz - w.z * qy, pvy + w.z * qx - w.x * qz, pvz + w.x * qy - w.y * qx
      end
      relSpeed = len(a.vx - pvx, a.vy - pvy, a.vz - pvz)
    end
  else
    relSpeed = nil
  end
  if not live then return end
  if rcs == nil then rcs = rcsLeft(id) end
  local c = steer or cmd
  if steer and (c.f ~= 0 or c.s ~= 0 or c.u ~= 0) then last_key_t = time end
  -- the inventory's mass rides the suit
  local inv = ref("inventory")
  local mass = P("suit_kg") + ((inv and inv.mass and inv.mass(crew().packOf(id))) or 30)
  local thrust = R("thrust") * (c.burst and R("burst") or 1.0)
  local amax = thrust / mass
  local per_dv = R("prop") / math.max(1, R("isp_dv"))
  local dvx, dvy, dvz = 0, 0, 0
  if steer_w then
    last_key_t = time
    local k = amax * dt
    dvx, dvy, dvz = steer_w[1] * k, steer_w[2] * k, steer_w[3] * k
  elseif c.f ~= 0 or c.s ~= 0 or c.u ~= 0 then
    -- camera-relative: forward the view, up the view's up
    local cam = ref("planet_camera")
    local fx, fy, fz = 0, 0, -1
    if cam and cam.fwd_x then fx, fy, fz = cam.fwd_x, cam.fwd_y, cam.fwd_z end
    local ux, uy, uz = a.up_x or 0, a.up_y or 1, a.up_z or 0
    local d0 = space.dominant(a.x, a.y, a.z)
    local b = d0 and space.body(d0)
    if b then ux, uy, uz = norm(a.x - b.x, a.y - b.y, a.z - b.z) end
    local rx, ry, rz = norm(fy * uz - fz * uy, fz * ux - fx * uz, fx * uy - fy * ux)
    local cux, cuy, cuz = ry * fz - rz * fy, rz * fx - rx * fz, rx * fy - ry * fx
    local mx = fx * c.f + rx * c.s + cux * c.u
    local my = fy * c.f + ry * c.s + cuy * c.u
    local mz = fz * c.f + rz * c.s + cuz * c.u
    mx, my, mz = norm(mx, my, mz)
    local k = amax * dt
    dvx, dvy, dvz = mx * k, my * k, mz * k
  elseif (holdOn or (hold_until and time < hold_until)) and pvx and time - last_key_t > P("hold_resume") then
    -- HOLD: thrust against the velocity relative to the craft, capped
    local ex, ey, ez = pvx - a.vx, pvy - a.vy, pvz - a.vz
    local e = len(ex, ey, ez)
    local k = math.min(e, amax * dt)
    if e > 0.004 and k > 0 then dvx, dvy, dvz = ex / e * k, ey / e * k, ez / e * k end
  end
  if hold_until and time >= hold_until then hold_until = nil end
  local dv = len(dvx, dvy, dvz)
  if dv > 0 then
    local cost = dv * per_dv
    if rcs <= 0 then return end
    if cost > rcs then local f = rcs / cost; dvx, dvy, dvz, cost = dvx * f, dvy * f, dvz * f, rcs end
    a.vx, a.vy, a.vz = a.vx + dvx, a.vy + dvy, a.vz + dvz
    rcs = rcs - cost
    used = used + cost
    firing = true
  end
end

-- The worn model on the back (prefabs/ItemRcsPack), shown while carried.
local worn = nil
local worn_pending = false
function lateUpdate(node, dt)
  local a = find and find("Astronaut")
  if not a then return end
  local model = nil
  for _, ch in ipairs(a.children and a:children() or {}) do
    if ch.name == "AstroModel" then model = ch end
  end
  local want = present and a.visible ~= false and model ~= nil
  if want and not worn and not worn_pending and spawn then
    worn_pending = true
    pcall(spawn, "ItemRcsPack", vec3(a.x, a.y, a.z), function(n)
      worn_pending = false
      worn = n
    end, { parent = model, body = false })
  end
  if worn and worn.valid ~= false then
    worn.visible = want and model.visible ~= false
  end
end
