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
  half_h = 0.95,     -- the suit capsule's half height (planet_walker's 1.9 m)
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
-- `id`: who does it (their perk: an Engineer is faster, J6).
function repairMult(id)
  local c = ref("crew")
  if not (c and c.perk) then return 1 end
  local who = id or (c.activeId and c.activeId())
  if who == nil then return 1 end
  local ok, m = pcall(c.perk, who, "repair_time")
  return (ok and tonumber(m)) or 1
end
function repairSecs(hp, id)
  local mult = repairMult(id)
  local I = ref("items")
  if I and I.repairSecs then return I.repairSecs(hp, mult) end
  hp = math.max(0, math.min(1, hp or 1))
  return (6 + 16 * (1 - hp)) * mult
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
  local secs = repairSecs(hp, opts.id)
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
  local climb = t.kind == "climb"
  -- the work done so far stays on the part for a while (a re-click resumes)
  if why ~= "done" and v and v.partSt and not climb then
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
  if climb then
    -- (off the ladder: said only when something pulled them off it)
    if why ~= "let go" and why ~= "stepped off" and why ~= "cancelled" then caption("off the ladder: " .. tostring(why)) end
  elseif why ~= "done" then
    caption(why == "cancelled" and "repair cancelled — progress kept" or ("repair stopped: " .. tostring(why)))
  end
  log(string.format("crew %s: released (%s) — %.1f of %.1f s", tostring(id), tostring(why), t.done or 0, t.secs or 0))
  return true
end

-- Through the hatch: the hold ends with NO write to the body (the craft
-- seats them this same tick: vessel_controller.boardNow). Releasing it would
-- hand back a dynamic capsule at the hatch for the half second the seat's
-- kinematic flag waits, inside the hull.
function dropHold(id)
  local h = H[id]
  if not h then return false end
  H[id] = nil
  set_align(astro(), true)
  local c = ref("crew")
  if c and c.patch then c.patch(id, { task = false }) end
  local pw = ref("planet_walker")
  if pw and pw.holdEnd then pcall(pw.holdEnd) end
  log(string.format("crew %s: off the %s, through the hatch", tostring(id), tostring(h.task.kind)))
  return true
end

-- ── THE HATCH LADDER (Ty 2026-11-11: "they need ladders you grab onto
-- first, then you climb near the hatch, then you are able to board") ──────
-- A crewed part's ladder (crew.SEATS[..].ladder, placed for this craft by
-- vessel_controller.ladderOf, in the part's frame) is a task of its own kind:
-- the crew is HELD on it exactly as at a repair (kinematic, placed every tick
-- in the part's frame, drawn where the craft is drawn), W / S move them up
-- and down it (CLIMB speeds), SPACE lets go, and the hatch at the top is
-- the craft's to open (vessel_controller's E / F, the menu's Enter). A
-- landed craft's ladder reaches the ground: below the part's own rails the
-- line runs on down the stack, out past whatever is under it (`ext`).
--   task = { kind = "climb", craft, uid, s (the suit's centre height on the
--            line, part frame), lo, hi (its ends), a, b (the rails' centre
--            line, bottom and top), n (outward, unit), ext = { y0, step, off },
--            ground (the craft is landed), hatch = {x,y,z} }
CLIMB = { up = 0.8, down = 1.1, away = 0.40, grip = 0.45, foot = 0.95, top_drop = 0.35 }
local climb_cmd = 0          -- -1 … 1, the keys (update)
climbState = nil             -- published: { vid, uid, s, lo, hi, top, bottom, ground } while climbing

-- pure: the ladder's centre line at part-frame height y, and how far out the
-- hull under it pushes the suit there (0 on the part's own rails)
function ladderAt(t, y)
  local a, b = t.a, t.b
  local k = (b.y - a.y) ~= 0 and (y - a.y) / (b.y - a.y) or 0
  local off = 0
  if k < 0 then
    k = 0
    local e = t.ext
    if e and e.off and #e.off > 0 then
      local i = math.floor((y - e.y0) / e.step) + 1
      i = math.max(1, math.min(#e.off, i))
      off = e.off[i] or 0
    end
  elseif k > 1 then k = 1 end
  return a.x + (b.x - a.x) * k, y, a.z + (b.z - a.z) * k, off
end
-- pure: set the task's spot (suit centre) and face point for its height s
function climbSpot(t)
  local x, y, z, off = ladderAt(t, t.s)
  local n = t.n
  local away = CLIMB.away + off
  t.sx, t.sy, t.sz = x + n.x * away, t.s, z + n.z * away
  local gx, gy, gz = ladderAt(t, math.min(t.b.y, t.s + CLIMB.grip))
  t.lx, t.ly, t.lz = gx, gy, gz
  return t.sx, t.sy, t.sz
end
-- pure: the climbable range of the suit's centre on ladder L (lowest rail
-- point a.y, or the ground's `ylow` when landed; the top rung less a drop)
function climbRange(L)
  local hi = L.b.y - CLIMB.top_drop
  local lo = (L.ylow and (L.ylow + CLIMB.foot)) or (L.a.y + 0.2)
  if lo > hi then lo = hi end
  return lo, hi
end
-- pure: the board / grab rule (crew-and-items §3.5). o = { open, dSeat,
-- dHatch, ladder (the part has one), climbing (on THIS part's ladder),
-- needLadder (the hatch is out of a standing reach, or in space), dLadder }
-- → "enter" | "grab" | nil, and why not
HATCH = { seat = 3.4, reach = 1.4, grab = 1.2, fallback = 2.0 }
function hatchRule(o)
  if o.open then
    if (o.dSeat or 1e9) <= HATCH.seat then return "enter" end
    return nil, "walk up to the seat"
  end
  if o.climbing then
    if (o.dHatch or 1e9) <= HATCH.reach then return "enter" end
    return nil, "climb to the hatch"
  end
  if o.ladder then
    if not o.needLadder and (o.dHatch or 1e9) <= HATCH.reach then return "enter" end
    if (o.dLadder or 1e9) <= HATCH.grab then return "grab" end
    return nil, o.needLadder and "grab the ladder by the hatch" or "walk up to the hatch"
  end
  if (o.dHatch or 1e9) <= HATCH.fallback then return "enter" end
  return nil, "walk up to the hatch"
end

-- Onto part `uid`'s ladder of craft `v` (a controller handle), at the
-- height nearest the crew (or `s`). → ok, why
function startClimb(id, v, uid, s)
  local c = ref("crew")
  if not (c and v and v.ladderOf and v.node) then return false, "no ladder" end
  local L = v.ladderOf(uid)
  if not L then return false, "no ladder" end
  local lo, hi = climbRange(L)
  if s == nil then
    local a = c.bodyOf and c.bodyOf(id) or astro()
    if a and v.partLocalNow then
      local ax, ay, az = a.x, a.y, a.z
      if v.physPosOf then ax, ay, az = v.physPosOf(a) end
      local _, ly = v.partLocalNow(uid, ax, ay, az)
      s = ly
    end
  end
  s = math.max(lo, math.min(hi, s or lo))
  local t = { kind = "climb", craft = v.node.id, uid = uid, s = s, lo = lo, hi = hi,
              a = L.a, b = L.b, n = L.n, ext = L.ext, ground = L.ylow ~= nil, hatch = L.hatch,
              name = L.label, secs = 0, done = 0 }
  climbSpot(t)
  return c.setTask(id, t)
end

-- What finishes a job of each kind. WS3 may replace "repair" (effects,
-- consumption); this default mends the part and uses up the kit.
onDone = {}
onDone.repair = function(id, t, v)
  -- (scn_vacuum) a patch (cabin_air's "Patch the leak": t.patch, t.to =
  -- PATCH_HP) mends it to that, not to new: the patch row's job came out of
  -- here at 100 %
  local to = (t.patch and tonumber(t.to)) or 1.0
  if v and v.repairPart then v.repairPart(t.uid, to) end
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
  -- (a patch says so on the line, not in the middle of the screen: Ty 11-11)
  if t.patch then caption(label .. " patched — the leak is stopped")
  elseif bc and bc.show then bc.show("REPAIRED", label .. " — 100%", 3.0, "result") else caption(label .. " repaired — 100%") end
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

-- THE DRAWN PLACE (Ty 11-11: "repairing in space makes me jitter around like
-- crazy"). A kinematic body is drawn where its last tick put it: the engine
-- does not interpolate it between ticks, while the craft it is held to glides
-- on between them. At 144 Hz in a 753 m orbit the suit (and the view riding
-- it) jumped 0.47-0.66 m against the pod every frame (boardevaprobe jitter,
-- p95 661 mm); at 60 Hz, one frame a tick, it never showed. So each frame,
-- before the view is placed (planet_camera calls this; lateUpdate does it
-- too in a scene without one), the body goes to its spot as the craft is
-- DRAWN this frame: partPointNow(.., true), the same frame command_seat puts
-- an open seat's rider in. The tick's own placement (holdTick, the physics
-- frame) is untouched, so the hold, the release and the velocities stay the
-- simulation's.
local placed_at = -1
function beforeCamera()
  if next(H) == nil or placed_at == time then return end
  placed_at = time
  local a = astro()
  if not (a and a.valid ~= false) then return end
  for _, h in pairs(H) do
    if not h.pending and h.lx then
      local v = vessel(h.vid)
      local wx, wy, wz = nil, nil, nil
      if v and v.partPointNow then wx, wy, wz = v.partPointNow(h.task.uid, h.lx, h.ly, h.lz, true) end
      if wx then a.x, a.y, a.z = wx, wy, wz end
    end
  end
end
-- THE LADDER'S KEYS (the active member, while climbing): W / S up and down,
-- SPACE lets go, E or F at the foot of a landed craft's ladder steps off
-- (E / F at the hatch is the craft's: vessel_controller boards). Read in
-- the frame, used in the tick.
local function hatch_dist(t)
  local hp = t.hatch
  if not (hp and t.sx) then return 1e9 end
  return len(t.sx - hp.x, t.sy - hp.y, t.sz - hp.z)
end
KEYS = { e = true, s = true }   -- (held at the start: a key already down is no press)
function update(node, dt)
  climb_cmd = 0
  if next(H) == nil then climbState = nil return end
  local c = ref("crew")
  local id = c and c.activeId and c.activeId()
  local h = id and H[id]
  if not (h and h.task.kind == "climb" and not h.pending) then climbState = nil return end
  local t = h.task
  local pc = ref("planet_camera")
  local free = not (pc and pc.freecam)
  if free and input and input.key then
    if input.key("w") then climb_cmd = climb_cmd + 1 end
    if input.key("s") then climb_cmd = climb_cmd - 1 end
  end
  local dh = hatch_dist(t)
  climbState = { vid = h.vid, uid = t.uid, s = t.s, lo = t.lo, hi = t.hi, top = t.s >= t.hi - 0.05,
                 bottom = t.s <= t.lo + 0.05, ground = t.ground == true, dHatch = dh, atHatch = dh <= HATCH.reach }
  -- (edges of the held keys, kept here: input.pressed read from this node
  -- answered true for E and F every frame of a probe run)
  local kE = input.key("e") or input.key("f")
  local kS = input.key("space")
  local eE, eS = kE and not KEYS.e, kS and not KEYS.s
  KEYS.e, KEYS.s = kE, kS
  if not free or (h.t or 0) < 0.3 then return end
  if eS then
    release(id, "let go")
  elseif eE and climbState.bottom and t.ground and not climbState.atHatch then
    release(id, "stepped off")
  end
end

-- Hand over hand on the rails (in the camera pass, the drawn pose): each
-- hand on its own rail at a rung height that steps with the climb.
local function climb_hands(dt)
  local c = ref("crew")
  local id = c and c.activeId and c.activeId()
  local h = id and H[id]
  if not (h and h.task.kind == "climb") then return end
  local a = astro()
  local m = nil
  for _, ch in ipairs(a and a.children and a:children() or {}) do if ch.name == "AstroModel" then m = ch end end
  local an = m and m.animator and m:animator()
  if not (an and an.reach) then return end
  local v = vessel(h.vid)
  local t = h.task
  if not (v and v.partPointNow) then return end
  local n = t.n
  -- the rails: ±half across, the line's tangent across = up × n in the part frame
  local tx, tz = -n.z, n.x
  local half = (t.half or 0.13)
  local step = 0.25
  local base = t.s + CLIMB.grip
  for k, side in ipairs({ 1, -1 }) do
    -- one hand a rung above the other, swapping as the climb passes each rung
    local ph = math.floor(base / step + (k == 1 and 0 or 0.5))
    local gy = math.min(t.b.y, ph * step + (k == 1 and 0 or step * 0.5))
    local x, y, z = ladderAt(t, gy)
    x, z = x + tx * half * side, z + tz * half * side
    local wx, wy, wz = v.partPointNow(t.uid, x, y, z, true)
    if wx then
      pcall(an.reach, an, side == 1 and "Hand.Left" or "Hand.Right", vec3(wx, wy, wz), { weight = 1.0 })
    end
  end
end

function lateUpdate(node, dt)
  beforeCamera()
  if climbState then pcall(climb_hands, dt) end
end

-- Where the world's queries answer for the held body against where it is
-- drawn (the craft's physics frame − its drawn frame, at the spot), for a
-- sweep from a drawn point that must meet the craft's colliders (the
-- camera's wall clip). → dx, dy, dz | nil (nobody held)
function queryShift()
  for _, h in pairs(H) do
    if h.lx and not h.pending then
      local v = vessel(h.vid)
      if v and v.partPointNow then
        local px, py, pz = v.partPointNow(h.task.uid, h.lx, h.ly, h.lz)
        local dx, dy, dz = v.partPointNow(h.task.uid, h.lx, h.ly, h.lz, true)
        if px and dx then
          local sx, sy, sz = px - dx, py - dy, pz - dz
          if sx * sx + sy * sy + sz * sz < 2500 then return sx, sy, sz end
        end
      end
    end
  end
  return nil
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
      if t.kind == "climb" then
        -- up or down the ladder by the keys (crew_task.update reads them)
        local mv = climb_cmd
        if mv ~= 0 then
          t.s = math.max(t.lo, math.min(t.hi, t.s + mv * (mv > 0 and CLIMB.up or CLIMB.down) * dt))
        end
        climbSpot(t)
      end
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
      if t.kind ~= "climb" then t.done = math.min(t.secs, (t.done or 0) + dt) end
      if t.kind ~= "climb" and t.done >= t.secs then
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
