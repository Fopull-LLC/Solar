-- CREW TASK — jobs a crew member is HELD at: the repair lock
-- (docs/crew-and-items.md §6.3). Rides the CrewLib node with crew.lua.
--
-- A task is plain data on the crew record (crew.setTask / cancelTask); this
-- script runs it. While a member is held at a job:
--
--   * they are KINEMATIC, placed every tick at a work spot stored in the
--     PART's frame (vessel_controller.partPointNow: this tick's pose, clear of
--     the rails carry) and moving at that point's velocity — so they ride a
--     tumbling station, an orbit or a planet moving 6 m a tick exactly, and
--     nothing can knock them off;
--   * they slide in to the spot over `slide` seconds from where they stood;
--   * movement keys do nothing (planet_walker and eva_pack stand down while
--     `isHeld`); cancel is explicit (crew.cancelTask, from the context menu);
--   * forced stops: the part breaks or leaves, the craft is gone, it fires
--     its engines, or the crew runs out of air;
--   * on release they become a body again at the PART's velocity (at rest
--     relative to it): set down on the ground, or in space with the RCS
--     Pack's HOLD on for 2 s against that craft.
--
-- No weld joint: the suit's mass never joins the craft's dynamics (§6.3).
--
-- The task (saved on the record):
--   { kind = "repair", craft = <vessel node id>, uid = <part uid>,
--     lx, ly, lz = the hit point (part frame), sx, sy, sz = the work spot
--     (suit centre, part frame), secs, done, item = "repairkit", name }
--
-- API: validate(id, t) → ok, why · attach(id) → ok, why · release(id, why)
--      isHeld(id) → bool · repairTask(vc, uid, hx,hy,hz, nx,ny,nz, opts) → task|nil, why
--      spotNow(id) → wx,wy,wz (the work spot this tick) · aimNow(id) → the hit point, drawn pose
--      progress(id) → done, secs · onDone[kind] = fn(id, task, vc) (WS3 may replace "repair")

defaults = {
  slide = 0.4,       -- s to slide in to the work spot
  standoff = 0.5,    -- m off the surface to the suit's centre (side-on): the
                     -- hands reach the hit point for the work pose
  reach = 2.6,       -- m: the crew's reach, plus the part's half size
  max_rel = 1.0,     -- m/s relative to the part, to start
  hold_secs = 2.0,   -- the RCS Pack's HOLD after a release in space
  half_h = 1.0,      -- the suit capsule's half height (planet_walker's 2 m)
}

local function P(k) return (params and params[k]) or defaults[k] end

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not (r and r.valid ~= false) then
    r = findScript and findScript(kind) or nil
    refs[kind] = r
  end
  return r
end

-- id → the live hold: { vid, uid, s0x.. (start, part frame), t, save_t }
local H = {}
-- the last tick's numbers, for probes: { err (m), id }
lastTick = nil

local function astro() return find and find("Astronaut") or nil end

local function vessel(vid)
  for _, v in ipairs(findScripts and findScripts("vessel_controller") or {}) do
    if v.node and v.node.valid ~= false and v.node.id == vid then return v end
  end
  return nil
end

local function set_kinematic(a, on)
  local getc = a and (a.getComponent or a.getcomponent)
  local rb = getc and getc(a, "RigidBody")
  if not rb then return end
  local is = rb.kinematic == true or rb.kinematic == 1
  if is ~= on then rb.kinematic = on and 1 or 0 end
end

-- Standing along gravity (the walker's default). Off while a repair holds the
-- crew in space, where the hull can be over their head or under their feet.
local function set_align(a, on)
  local getc = a and (a.getComponent or a.getcomponent)
  local rb = getc and getc(a, "RigidBody")
  if rb and rb.alignUp ~= on then rb.alignUp = on end
end

local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end

-- ── the repair rules (items.lua's when WS3's library is there) ─────────────
function repairSecs(hp)
  local I = ref("items")
  if I and I.repairSecs then return I.repairSecs(hp) end
  hp = math.max(0, math.min(1, hp or 1))
  return 6 + 16 * (1 - hp)
end

local function repairable(hp)
  local I = ref("items")
  if I and I.repairable then return I.repairable(hp) end
  if hp == nil then return false, "that part isn't on this craft" end
  if hp <= 0 then return false, "it is wrecked — beyond a field repair" end
  if hp >= 0.999 then return false, "it is sound" end
  return true, nil
end

-- What ends a job this tick (movement is not on the list: keys never end it).
-- `s` = { craft, hp, throttle, accel, o2 } → why | nil
function stopWhy(s)
  local I = ref("items")
  if I and I.repairStop then return I.repairStop(s) end
  if not s.craft then return "the craft is gone" end
  if s.hp == nil then return "the part left the craft" end
  if s.hp <= 0 then return "the part broke" end
  if (s.throttle or 0) > 1e-6 or (s.accel or 0) > 0.5 then return "the engines fired — pushed off the hull" end
  if s.o2 ~= nil and s.o2 <= 0 then return "out of air" end
  return nil
end

local function kept(rprog, now, secs)
  local I = ref("items")
  if I and I.keptProgress then return I.keptProgress(rprog, now, secs) end
  if type(rprog) ~= "table" or not rprog.s then return 0 end
  if now - (rprog.t or -1e9) > 120 then return 0 end
  return math.max(0, math.min(secs or rprog.s, rprog.s))
end

local function clock() return (space and space.time and space.time()) or time or 0 end

-- ── building a task from a pick ────────────────────────────────────────────
-- A Repair task for part `uid` of craft `vc` (a controller handle), from a
-- world hit point and its surface normal (a ray off the screen: `opts.rendered`
-- = true reads the drawn pose). The work spot is `standoff` off the surface
-- along the normal — further where the normal is near the suit's own up, so
-- the 2 m capsule clears the hull — and, on the ground, at the crew's own
-- height. → task, or nil and why.
function repairTask(vc, uid, hx, hy, hz, nx, ny, nz, opts)
  opts = opts or {}
  if not (vc and vc.partLocalNow and vc.node) then return nil, "not a craft" end
  local hp = vc.partHp and vc.partHp(uid)
  local ok, why = repairable(hp)
  if not ok then return nil, why end
  local nl = len(nx or 0, ny or 0, nz or 0)
  local a = astro()
  if nl < 1e-6 then
    -- no normal: from the hit point toward the crew
    if not a then return nil, "no crew" end
    nx, ny, nz, nl = a.x - hx, a.y - hy, a.z - hz, len(a.x - hx, a.y - hy, a.z - hz)
    if nl < 1e-6 then nx, ny, nz, nl = 0, 1, 0, 1 end
  end
  nx, ny, nz = nx / nl, ny / nl, nz / nl
  -- the suit's up: away from the body it falls toward
  local ux, uy, uz = 0, 1, 0
  local d = space and space.dominant and space.dominant(hx, hy, hz)
  local b = d and space.body(d)
  if b then
    local l = len(hx - b.x, hy - b.y, hz - b.z)
    if l > 1e-6 then ux, uy, uz = (hx - b.x) / l, (hy - b.y) / l, (hz - b.z) / l end
  end
  local st = vc.evaState and vc.evaState() or nil
  local sx, sy, sz
  if st and st.surface and a then
    -- on the ground: in front of the part, standing at the crew's height
    local hu = nx * ux + ny * uy + nz * uz
    local fx, fy, fz = nx - ux * hu, ny - uy * hu, nz - uz * hu
    local fl = len(fx, fy, fz)
    if fl < 1e-3 then
      fx, fy, fz = a.x - hx, a.y - hy, a.z - hz
      local au = fx * ux + fy * uy + fz * uz
      fx, fy, fz = fx - ux * au, fy - uy * au, fz - uz * au
      fl = math.max(1e-6, len(fx, fy, fz))
    end
    fx, fy, fz = fx / fl, fy / fl, fz / fl
    local off = P("standoff")
    sx, sy, sz = hx + fx * off, hy + fy * off, hz + fz * off
    local h = (a.x - sx) * ux + (a.y - sy) * uy + (a.z - sz) * uz
    sx, sy, sz = sx + ux * h, sy + uy * h, sz + uz * h
  else
    local along = math.abs(nx * ux + ny * uy + nz * uz)
    local off = P("standoff") + (P("half_h") - 0.33) * along
    sx, sy, sz = hx + nx * off, hy + ny * off, hz + nz * off
  end
  local lx, ly, lz = vc.partLocalNow(uid, hx, hy, hz, opts.rendered)
  local px, py, pz = vc.partLocalNow(uid, sx, sy, sz, opts.rendered)
  if not lx then return nil, "that part isn't on this craft" end
  local secs = repairSecs(hp)
  local name = nil
  local rec = vc.partRec and vc.partRec(uid)
  if rec then name = rec.label or rec.name or rec.id end
  return { kind = "repair", craft = vc.node.id, uid = uid, lx = lx, ly = ly, lz = lz,
           sx = px, sy = py, sz = pz, secs = secs, done = 0, item = "repairkit", name = name }
end

-- ── may it start ───────────────────────────────────────────────────────────
function validate(id, t)
  if t.kind ~= "repair" then return true, nil end -- other kinds: their owner's rules
  local v = vessel(t.craft)
  if not v then return false, "that craft isn't here" end
  local ok, why = repairable(v.partHp and v.partHp(t.uid))
  if not ok then return false, why end
  local c = ref("crew")
  if c and c.craftOf and c.craftOf(id) then return false, "from outside: step out first" end
  if (v.throttle or 0) > 1e-6 then return false, "cut the engines first" end
  local a = astro()
  if a and v.partPointNow then
    local hx, hy, hz = v.partPointNow(t.uid, t.lx, t.ly, t.lz)
    local _, _, _, pvx, pvy, pvz = v.partPointNow(t.uid, t.sx, t.sy, t.sz)
    if hx then
      local reach = P("reach") + 1.5
      local ax, ay, az = a.x, a.y, a.z
      if v.physPosOf then ax, ay, az = v.physPosOf(a) end
      if len(ax - hx, ay - hy, az - hz) > reach then return false, "out of reach" end
      local rel = len((a.vx or 0) - pvx, (a.vy or 0) - pvy, (a.vz or 0) - pvz)
      if rel > P("max_rel") then
        local st = v.evaState and v.evaState() or nil
        local sp = st ~= nil and not st.surface
        return false, sp and "slow down first (X holds)" or "stand still first"
      end
    end
  end
  return true, nil
end

-- ── the lock ───────────────────────────────────────────────────────────────
function isHeld(id)
  return id ~= nil and H[id] ~= nil
end

function progress(id)
  local h = H[id]
  if not h then return nil end
  return h.task.done or 0, h.task.secs or 0
end

function attach(id)
  local c = ref("crew")
  local t = c and c.task and c.task(id)
  if not t then return false, "no task" end
  local v = vessel(t.craft)
  if not v then return false, "that craft isn't here" end
  local a = c.bodyOf and c.bodyOf(id) or astro()
  if not a then return false, "no body" end
  -- progress kept on the part from an earlier start (≤ 120 s ago)
  if (t.done or 0) <= 0 and v.partSt then
    t.done = kept(v.partSt(t.uid, "rprog"), clock(), t.secs)
  end
  -- where the body is in the physics frame (its tick pose, card 0543)
  local ax, ay, az = a.x, a.y, a.z
  if v.physPosOf then ax, ay, az = v.physPosOf(a) end
  local s0x, s0y, s0z = v.partLocalNow(t.uid, ax, ay, az)
  if not s0x then return false, "that part isn't on this craft" end
  H[id] = { vid = t.craft, task = t, s0x = s0x, s0y = s0y, s0z = s0z, t = 0, save_t = time or 0 }
  set_kinematic(a, true)
  local pw = ref("planet_walker")
  if pw and pw.holdStart then pcall(pw.holdStart) end
  log(string.format("crew %s: held at %s (part %s) — %.0f s of work, %.1f done",
    tostring(id), tostring(t.kind), tostring(t.uid), t.secs or 0, t.done or 0))
  return true, nil
end

local function caption(text)
  local fx = ref("sfx")
  if fx and fx.caption then fx.caption(text) end
end

-- Let go: done, cancelled, or a forced stop (`why`). The body is dynamic
-- again at the part's velocity: at rest relative to it. Asked between ticks
-- (a menu click), it lands on the next tick: every write to the body is a
-- tick's (a kinematic body moved between ticks stands a rails carry behind).
local in_tick = false
local do_release
function release(id, why)
  local h = H[id]
  if not h then return false end
  if not in_tick then
    h.pending = why or "cancelled"
    local c = ref("crew")
    if c and c.patch then c.patch(id, { task = false }) end
    return true
  end
  return do_release(id, why)
end

do_release = function(id, why)
  local h = H[id]
  if not h then return false end
  H[id] = nil
  local t = h.task
  local v = vessel(h.vid)
  local a = astro()
  local in_space = false
  if a then
    set_kinematic(a, false)
    set_align(a, true)
    if v and v.partPointNow then
      local wx, wy, wz, vx, vy, vz = v.partPointNow(t.uid, t.sx, t.sy, t.sz)
      if wx then a.vx, a.vy, a.vz = vx, vy, vz end
    end
    local st = v and v.evaState and v.evaState() or nil
    in_space = not (st and st.surface)
  end
  -- the work done so far stays on the part for a while (a re-click resumes)
  if why ~= "done" and v and v.partSt then
    v.partSt(t.uid, "rprog", { s = t.done or 0, t = clock() }, true)
  end
  local c = ref("crew")
  if c and c.patch then c.patch(id, { task = false }) end
  local pw = ref("planet_walker")
  if pw and pw.holdEnd then pcall(pw.holdEnd) end
  if in_space then
    local ep = ref("eva_pack")
    if ep and ep.holdFor and v then pcall(ep.holdFor, P("hold_secs"), v.node) end
  end
  if why ~= "done" then
    caption(why == "cancelled" and "repair cancelled — progress kept" or ("repair stopped: " .. tostring(why)))
  end
  log(string.format("crew %s: released (%s) — %.1f of %.1f s", tostring(id), tostring(why), t.done or 0, t.secs or 0))
  return true
end

-- What finishes a job of each kind. WS3 may replace "repair" (effects,
-- consumption); this default mends the part and uses up the kit.
onDone = {}
onDone.repair = function(id, t, v)
  if v and v.repairPart then v.repairPart(t.uid, 1.0) end
  if v and v.partSt then v.partSt(t.uid, "rprog", false, true) end
  local c, inv = ref("crew"), ref("inventory")
  local pack = c and c.packOf and c.packOf(id) or "astro"
  if inv then
    if inv.removeItem then pcall(inv.removeItem, pack, t.item or "repairkit", 1)
    elseif inv.removeGear then pcall(inv.removeGear, pack, t.item or "repairkit", 1) end
  end
  local r = c and c.get and c.get(id)
  if r and c.patch then c.patch(id, { repairs = (r.repairs or 0) + 1 }) end
  local bc = ref("big_caption")
  local label = t.name or "part"
  if bc and bc.show then bc.show("REPAIRED", label .. " — 100%", 3.0) else caption(label .. " repaired — 100%") end
end

-- The work spot this tick (for probes and the walker), and the hit point in
-- the drawn pose (hands and facing, lateUpdate).
function spotNow(id)
  local h = H[id]
  local v = h and vessel(h.vid)
  if not (v and v.partPointNow) then return nil end
  return v.partPointNow(h.task.uid, h.task.sx, h.task.sy, h.task.sz)
end
function aimNow(id)
  local h = H[id]
  local v = h and vessel(h.vid)
  if not (v and v.partPointNow) then return nil end
  return v.partPointNow(h.task.uid, h.task.lx, h.task.ly, h.task.lz, true)
end

local resume_t = -10
-- A task saved on the record with no hold (a reload, or the body was out of
-- range): attach again once the craft is here.
local function resume()
  if (time or 0) - resume_t < 1.0 then return end
  resume_t = time or 0
  local c = ref("crew")
  if not (c and c.activeId and c.task) then return end
  local id = c.activeId()
  if id and not H[id] and c.task(id) then
    local t = c.task(id)
    if vessel(t.craft) then attach(id) end
  end
end

function fixedUpdate(node, dt)
  if next(H) == nil then resume() return end
  in_tick = true
  local ok, err = pcall(holdTick, dt)
  in_tick = false
  if not ok then log("crew_task: " .. tostring(err)) end
end

-- In space the body turns to the work, not just its heading: its front
-- swings onto the hit point (eased, about a third of a second), its up kept as
-- near as that allows to where it was, so the hands reach the hull whichever
-- side of the crew it is on.
local function face_work(a, h, v, wx, wy, wz, dt)
  if not (a.worldForward and a.worldUp and a.setUp) then return end
  local t = h.task
  local hx, hy, hz = v.partPointNow(t.uid, t.lx, t.ly, t.lz)
  if not hx then return end
  local fx, fy, fz = hx - wx, hy - wy, hz - wz
  local l = len(fx, fy, fz)
  if l < 1e-4 then return end
  fx, fy, fz = fx / l, fy / l, fz / l
  set_align(a, false)
  local cf = a:worldForward()
  local e = 1 - math.exp(-dt / 0.12)
  fx, fy, fz = cf.x + (fx - cf.x) * e, cf.y + (fy - cf.y) * e, cf.z + (fz - cf.z) * e
  l = len(fx, fy, fz)
  if l < 1e-4 then return end
  fx, fy, fz = fx / l, fy / l, fz / l
  local u = a:worldUp()
  local d = u.x * fx + u.y * fy + u.z * fz
  local ux, uy, uz = u.x - fx * d, u.y - fy * d, u.z - fz * d
  l = len(ux, uy, uz)
  if l < 1e-3 then return end
  a:setUp(vec3(ux / l, uy / l, uz / l), vec3(fx, fy, fz))
end

function holdTick(dt)
  local a = astro()
  local pw = ref("planet_walker")
  for id, h in pairs(H) do
    local t = h.task
    local v = vessel(h.vid)
    if h.pending and v and a and h.lx then
      -- a release asked between ticks: placed in the physics frame, then let go
      local wx, wy, wz = v.partPointNow(t.uid, h.lx, h.ly, h.lz)
      if wx then a.x, a.y, a.z = wx, wy, wz end
    end
    local hp = v and v.partHp and v.partHp(t.uid) or nil
    local o2 = nil
    if pw and pw.downed then o2 = 0 end
    local why = h.pending or stopWhy({ craft = v ~= nil and not (v.isLost and v.isLost()), hp = hp,
                          throttle = v and v.throttle or 0, accel = 0, o2 = o2 })
    if why then
      release(id, why)
    elseif a then
      local err = nil
      h.t = h.t + dt
      local k = math.min(1, h.t / math.max(1e-3, P("slide")))
      k = k * k * (3 - 2 * k)
      local lx = h.s0x + (t.sx - h.s0x) * k
      local ly = h.s0y + (t.sy - h.s0y) * k
      local lz = h.s0z + (t.sz - h.s0z) * k
      local wx, wy, wz, vx, vy, vz = v.partPointNow(t.uid, lx, ly, lz)
      if wx then
        set_kinematic(a, true)
        -- In the PHYSICS frame (this tick's pose, past the rails carry), and
        -- only here in fixedUpdate: the engine carries a kinematic body
        -- placed in a tick with its world, and draws it with the hull.
        a.x, a.y, a.z = wx, wy, wz
        a.vx, a.vy, a.vz = vx, vy, vz
        h.lx, h.ly, h.lz = lx, ly, lz
        if h.space == nil then
          local st = v.evaState and v.evaState() or nil
          h.space = not (st and st.surface)
        end
        if h.space then face_work(a, h, v, wx, wy, wz, dt) end
        lastTick = { id = id, t = h.t, k = k, err = err }
      end
      t.done = math.min(t.secs, (t.done or 0) + dt)
      if t.done >= t.secs then
        local fin = onDone[t.kind]
        if fin then pcall(fin, id, t, v) end
        release(id, "done")
      elseif (time or 0) - h.save_t > 1.0 then
        h.save_t = time or 0
        local c = ref("crew")
        if c and c.patch then c.patch(id, { task = t }) end
      end
    end
  end
end
