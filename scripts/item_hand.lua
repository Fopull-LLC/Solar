-- ITEM HAND — what the crew member on foot holds, and the work they do with it
-- (docs/crew-and-items.md §5.4, §5.5, §6).
--
-- ONE THING IN THE HANDS AT A TIME. The belt is the pack's holdables
-- (items.belt: tools, then deployables, then consumables); number keys pick
-- by position, picking the selected slot again (or H) empties the hands, and
-- the choice is saved (`tool.id`, the crew record's `hand` once the roster
-- owns it). The two tools are drawn and fired by tool_belt as ever: it asks
-- `held()` here. Everything else is this script's:
--
--   a case by its handle    (grip "left": the Repair Kit) hangs from the left
--                           hand and swings with the walk; the right is free
--   over the shoulder       (grip "shoulder": a stowed beacon, a furled flag)
--                           the right hand steadies it on the shoulder
--   DEPLOY MODE             whatever has `deploy` (items.lua): the ghost on
--                           the ground under the crosshair, teal where it can
--                           stand and red with the reason where it can't, the
--                           beacon's relay links; LMB kneels and sets it down
--                           (`plantAnim`), then the store's place function
--                           runs (comms for beacons, deployables for the rest)
--                           and the item leaves the pack only if that worked.
--                           Picking one back up is the right-click menu's.
--
-- THE REPAIR JOB (§6). The Repair Kit in hand brings "Repair" to a damaged
-- part's right-click menu (context_providers' held.repair). Starting it puts
-- a TASK on the crew member (crew.setTask: plain data, saved on the record);
-- this script runs it: the time, the forced stops (items.repairStop), the
-- hands on the hull, the kit clamped beside them, sparks, the ratchet and the
-- weld hiss, a ring of progress over the part, and on completion the part's
-- health (vessel_controller.repairPart) and the kit used up. Movement keys
-- never end it; only "Cancel repair" (crew.cancelTask) or a forced stop does,
-- and the progress is kept on the part (st.rprog) for two minutes.
--
-- THE LOCK (holding the body at the work, riding the part) is crew_task's
-- (WS1): crew.setTask attaches it. When the scene has no crew_task this script
-- holds the body itself — kinematic, written to the work spot every tick in
-- the part's frame, the walker's keys stood down — so the job works either way.
--
-- Probes: `hold(id)`, `held()`, `belt()`, `task()`, `startRepair(target)`,
-- `cancel(why)`, `deployAt(x,y,z)`, `sim` (a test hook: { lmb = bool }).

defaults = {
  --@range 4 60 --@units m
  deploy_reach = 24.0,     -- from the PLAYER, as the laser's
  --@range 0 1
  sound = 1.0,
}

-- Published.
prompt = ""            -- the line under the belt while a non-tool is in hand
gate = "starting up"
working = nil          -- { label, frac, part } while a job runs (HUDs read it)
lastDeploy = nil       -- { id, kind, store, t } the last thing set down (probes)
lastRepair = nil       -- { uid, hp, t, kit_before, kit_after } (probes)
lastStop = nil         -- why the last job ended
handErr, handToHit = nil, nil  -- the right hand's miss and its distance to the hit (m, drawn pose)
sim = nil
RUNS_REPAIR = true     -- this script runs the repair job's clock, stops and completion

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function now() return time or 0 end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function norm(x, y, z)
  local l = len(x, y, z)
  if l < 1e-9 then return 0, 0, 0, 0 end
  return x / l, y / l, z / l, l
end
local function say(s, bad)
  local fx = ref("sfx")
  if fx and fx.caption then pcall(fx.caption, s) elseif caption then pcall(caption, s) end
  if log then log("hand: " .. s) end
end
local function play(path, o)
  if (params.sound or 1) <= 0 then return nil end
  if audio and audio.play then
    local ok, h = pcall(audio.play, path, o)
    if ok then return h end
  end
  return nil
end
local SFX = {
  swap = "audio/kenney/interface/pluck_001.ogg",
  denied = "audio/kenney/interface/error_003.ogg",
  plant = "audio/kenney/impact/impactMetal_002.ogg",
  set = "audio/kenney/interface/confirmation_002.ogg",
  ratchet = "audio/kenney/sci-fi/impactMetal_00",   -- + 0..4
  weld = "audio/kenney/sci-fi/forceField_001.ogg",
  latch = "audio/kenney/sci-fi/doorClose_001.ogg",
  done = "audio/kenney/interface/confirmation_002.ogg",
}

-- ── who is out there ────────────────────────────────────────────────────────
local function crew() return ref("crew") end
function memberId()
  local c = crew()
  if c and c.activeId then
    local ok, id = pcall(c.activeId)
    if ok and id then return id end
  end
  return 1
end
local function items() return ref("items") end
local function inv() return ref("inventory") end
local PACK = "astro"   -- inventory resolves it to the active member's pack

local astro_n, model_n, anim_n = nil, nil, nil
local function astro()
  if not (astro_n and astro_n.valid) then astro_n, model_n, anim_n = find and find("Astronaut") or nil, nil, nil end
  return astro_n
end
local function model()
  local a = astro()
  if not a then return nil, nil end
  if not (model_n and model_n.valid) then
    model_n, anim_n = nil, nil
    for _, c in ipairs(a.children and a:children() or {}) do if c.name == "AstroModel" then model_n = c end end
  end
  if model_n and not anim_n and model_n.animator then anim_n = model_n:animator() end
  return model_n, anim_n
end
local function up_at(x, y, z)
  local d = space and space.dominant and space.dominant(x, y, z)
  local b = d and space.body(d)
  if not b then return 0, 1, 0, nil end
  local ux, uy, uz = norm(x - b.x, y - b.y, z - b.z)
  return ux, uy, uz, b, d
end

-- ── the hand ────────────────────────────────────────────────────────────────
local hand_id = false     -- false = not read yet; nil = empty hands
local function load_hand()
  if hand_id ~= false then return end
  local id = nil
  local c = crew()
  if c and c.get then
    local ok, r = pcall(c.get, memberId())
    if ok and r and r.hand then id = r.hand end
  end
  if not id then id = save.get("tool.id") end
  if id == "none" or type(id) ~= "string" then id = (id == "none") and nil or "gravgun" end
  hand_id = id
end

function belt()
  local I, V = items(), inv()
  if not (I and V) then return {} end
  return I.belt(function(id) return V.itemCount(PACK, id) end)
end

local function in_belt(id, b)
  for i, s in ipairs(b or belt()) do if s.id == id then return i end end
  return nil
end

-- The item in hand (nil = empty hands). A held item the pack no longer has
-- (the last beacon planted, a kit used up, a tool put in a locker) leaves the
-- hand: empty hands, never something picked for you.
function held()
  load_hand()
  if hand_id and not in_belt(hand_id) and inv() and items() then hand_id = nil end
  return hand_id
end

local swap_t, swap_from = -10, nil
local function set_hand(id)
  if id == hand_id then return end
  swap_from, swap_t = hand_id, now()
  hand_id = id
  save.set("tool.id", id or "none")
  local c = crew()
  if c and c.patch then pcall(c.patch, memberId(), { hand = id or false }) end
  play(SFX.swap, { track = "UI", volume = 0.45 })
end

-- Take an item in hand (nil: empty hands). → ok, why
function hold(id)
  if id == nil then set_hand(nil) return true end
  local I = items()
  if not I then return false, "no item registry in this scene" end
  if not I.def(id) then return false, "no such item" end
  if I.isWorn(id) then return false, I.nameOf(id) .. " is worn, not held — carrying it is enough" end
  if not I.holdable(id) then return false, "it can't be held" end
  if not in_belt(id) then return false, "no " .. I.nameOf(id) .. " in the pack" end
  if busy() then return false, "the hands are at the work" end
  set_hand(id)
  return true
end
function stow() return hold(nil) end
function swapState() return swap_from, swap_t end

local function label_of(id)
  local I = items()
  return I and id and I.nameOf(id) or "empty hands"
end

-- A short hint for the belt's line while something that isn't a tool is in hand.
function hint()
  local id = held()
  if not id then return "empty hands  ·  1–9 take something out  ·  H put it away" end
  local I = items()
  local d = I and I.def(id)
  if not d then return "" end
  if d.deploy then return string.format("%s  ·  LMB set it down where the ghost is teal  ·  H put it away", d.name) end
  if d.use and d.use.provider == "repair" then
    return "Repair Kit in hand  ·  walk up to a damaged part, right-click it → Repair  ·  H put it away"
  end
  return d.name
end

-- ── the task (crew.setTask when the roster is in the scene) ─────────────────
local L = { task = nil }       -- the fallback's task (no crew library)
local function crew_tasks() local c = crew(); return c and c.setTask and c or nil end
function task(id)
  id = id or memberId()
  local c = crew_tasks()
  if c then
    local ok, t = pcall(c.task, id)
    t = ok and t or nil
    -- the live clock is crew_task's (the record is written once a second)
    local ct = ref("crew_task")
    if t and ct and ct.progress then
      local d = ct.progress(id)
      if d then t.done = d end
    end
    return t
  end
  return L.task
end
function busy()
  return task() ~= nil
end
local function lock_ours()
  local ct = ref("crew_task")
  return not (ct and ct.attach)
end

local lock_attach   -- (the fallback lock, below)
local R = {}   -- the running job's runtime: { v, part, t0, last_save, fx_t, snd, ... }
local function task_write(t)
  local c = crew_tasks()
  if c and c.patch then pcall(c.patch, memberId(), { task = t }) else L.task = t end
end

-- ── part frames ─────────────────────────────────────────────────────────────
-- vessel_controller's partPointNow/partLocalNow (this tick's pose, the rails
-- carry compensated) when it has them; else the craft root's own transform,
-- carried by the same lag the seat compensates (info.origin − node).
local function vessel_of(key)
  for _, v in ipairs(findScripts and findScripts("vessel_controller") or {}) do
    if v.node and v.node.valid and v.node.id == key then return v end
  end
  return nil
end
local function to_part(v, uid, wx, wy, wz, rendered)
  if v.partLocalNow then
    local lx, ly, lz = v.partLocalNow(uid, wx, wy, wz, rendered)
    if lx then return lx, ly, lz, "part" end
  end
  local l = v.node:toLocal(vec3(wx, wy, wz))
  return l.x, l.y, l.z, "craft"
end
local function from_part(v, uid, frame, lx, ly, lz, rendered)
  if (frame == "part" or frame == nil) and v.partPointNow then
    return v.partPointNow(uid, lx, ly, lz, rendered)
  end
  local w = v.node:toWorld(vec3(lx, ly, lz))
  local vx, vy, vz = 0, 0, 0
  local info = assembly and assembly.info and assembly.info(v.node)
  local wx, wy, wz = w.x, w.y, w.z
  if info then
    if not rendered and info.origin then
      wx, wy, wz = wx + info.origin.x - v.node.x, wy + info.origin.y - v.node.y, wz + info.origin.z - v.node.z
    end
    vx, vy, vz = info.vel.x, info.vel.y, info.vel.z
    if info.angVel and info.com then
      local c, om = info.com, info.angVel
      local qx, qy, qz = wx - c.x, wy - c.y, wz - c.z
      vx, vy, vz = vx + om.y * qz - om.z * qy, vy + om.z * qx - om.x * qz, vz + om.x * qy - om.y * qx
    end
  end
  return wx, wy, wz, vx, vy, vz
end

-- The part state field (st.rprog: kept progress).
local function part_st(v, uid, k, val, write)
  if v.partSt then return v.partSt(uid, k, val, write) end
  local rec = v.partRec and v.partRec(uid)
  if not rec then return nil end
  local E = ref("electronics")
  local st = (E and E.stateOf) and E.stateOf(rec) or rec.st
  if type(st) ~= "table" then st = {}; rec.st = st end
  if write then if val == false then st[k] = nil else st[k] = val end end
  return st[k]
end
local function clock() return (space and space.time and space.time()) or now() end

-- ── starting a repair ───────────────────────────────────────────────────────
-- Why this crew member can't repair this part now (nil = they can). `t` is a
-- context-menu part target; `ctx` the menu's context (for the reach rule).
function repairWhyNot(t, ctx)
  local I = items()
  if not I then return "no item registry in this scene" end
  local v, uid = t.vessel, t.uid
  if not (v and v.partHp) then return "not a part of a craft" end
  local okr, why = I.repairable(v.partHp(uid))
  if not okr then return why end
  if held() ~= "repairkit" then return "hold the Repair Kit" end
  local V = inv()
  if not V or V.itemCount(PACK, "repairkit") < 1 then return "needs a Repair Kit" end
  if busy() then return "already at work" end
  local pw = ref("planet_walker")
  if not (pw and pw.onFoot == true) then return "only on foot or on EVA: no repairs from the seat" end
  local P = ref("context_providers")
  if ctx and P and P.actorReach then
    local acc, d = P.actorReach(ctx, t)
    if acc ~= "near" then return d and string.format("walk up to it (%.0f m away)", d) or "walk up to it" end
  end
  if (v.throttle or 0) > 0.001 then return "the craft is under power — throttle to zero" end
  local a = astro()
  if a and v.node and v.node.valid and assembly and assembly.info then
    local info = assembly.info(v.node)
    if info and a.vel then
      local dv = len(a.vel.x - info.vel.x, a.vel.y - info.vel.y, a.vel.z - info.vel.z)
      if dv > I.REPAIR.max_rel_speed then return "slow down first (X holds)" end
    end
  end
  return nil
end

-- The task for a right-clicked part (crew_task.repairTask when WS1 has it).
function repairTask(t)
  local I = items()
  local v, uid = t.vessel, t.uid
  local a = astro()
  local hx, hy, hz = t.wx, t.wy, t.wz
  local P = ref("context_providers")
  if P and P.pickNow then hx, hy, hz = P.pickNow(t) end
  if not (v and v.node and v.node.valid and a) then return nil, "nothing to work on" end
  if not hx then
    hx, hy, hz = from_part(v, uid, v.partPointNow and "part" or "craft", 0, 0, 0)
    if not hx then return nil, "the part is gone" end
  end
  -- the surface's normal at the hit: a short ray from the crew at it
  local nx, ny, nz
  local ex, ey, ez = a.x, a.y, a.z
  local dx, dy, dz, dl = norm(hx - ex, hy - ey, hz - ez)
  if raycast and dl > 0 then
    local ok, h = pcall(raycast, ex, ey, ez, dx, dy, dz, dl + 1.0, { ignore = a })
    if ok and h and h.nx then nx, ny, nz = h.nx, h.ny, h.nz; hx, hy, hz = h.x, h.y, h.z end
  end
  if not nx then nx, ny, nz = -dx, -dy, -dz end
  local ct = ref("crew_task")
  if ct and ct.repairTask then
    local ok, tk, why = pcall(ct.repairTask, v, uid, hx, hy, hz, nx, ny, nz, { rendered = true })
    if ok and type(tk) == "table" then
      tk.secs = tk.secs or I.repairSecs(v.partHp(uid))
      tk.item = tk.item or "repairkit"
      tk.label = tk.label or (t.rec and t.rec.label) or tk.name
      tk.frame = "part"
      return tk
    end
    if ok and why then return nil, why end
  end
  -- the work spot: on the ground, standing where they are slid in to arm's
  -- length of the hit along the ground; in space, 0.7 m off the hull
  local pw = ref("planet_walker")
  local sx, sy, sz
  local ux, uy, uz = up_at(ex, ey, ez)
  if pw and pw.grounded then
    local qx, qy, qz = hx - ex, hy - ey, hz - ez
    local qu = qx * ux + qy * uy + qz * uz
    local fx, fy, fz, fl = norm(qx - ux * qu, qy - uy * qu, qz - uz * qu)
    local want = I.REPAIR.standoff + 0.25
    local step = math.max(0, fl - want)
    sx, sy, sz = ex + fx * step, ey + fy * step, ez + fz * step
  else
    sx, sy, sz = hx + nx * (I.REPAIR.standoff + 0.3), hy + ny * (I.REPAIR.standoff + 0.3), hz + nz * (I.REPAIR.standoff + 0.3)
  end
  local lx, ly, lz, frame = to_part(v, uid, hx, hy, hz, true)
  local wx, wy, wz = to_part(v, uid, sx, sy, sz, true)
  local nlx, nly, nlz = to_part(v, uid, hx + nx, hy + ny, hz + nz, true)
  local hp = v.partHp(uid)
  return { kind = "repair", craft = v.node.id, uid = uid, frame = frame,
           lx = lx, ly = ly, lz = lz, sx = wx, sy = wy, sz = wz,
           nx = nlx - lx, ny = nly - ly, nz = nlz - lz,
           secs = I.repairSecs(hp), done = 0, item = "repairkit", label = (t.rec and t.rec.label) or "part",
           ground = pw and pw.grounded == true }
end

-- Start one (the menu's act). → ok, why
function startRepair(t, ctx)
  local why = repairWhyNot(t, ctx)
  if why then return false, why end
  local tk, why2 = repairTask(t)
  if not tk then return false, why2 end
  local I = items()
  local kept = I.keptProgress(part_st(t.vessel, t.uid, "rprog"), clock(), tk.secs)
  tk.done = kept
  local c = crew_tasks()
  if c then
    local ok, w = c.setTask(memberId(), tk)
    if not ok then return false, w end
  else
    L.task = tk
  end
  R = { v = t.vessel, t0 = now(), started = true, fx_t = 0, click_t = now() + 0.3, from = nil, save_t = now() }
  -- the hit in the part NODE's own frame, read with the pick in one pass:
  -- the hands and the effects are placed off the drawn node each frame
  -- (no physics-frame pose involved, so no rails-carry lag to get wrong)
  local P = ref("context_providers")
  if t.node and t.node.valid ~= false and t.node.toLocal and P and P.pickNow then
    local wx, wy, wz = P.pickNow(t)
    if wx then R.pnode, R.nl = t.node, t.node:toLocal(vec3(wx, wy, wz)) end
  end
  if lock_ours() then lock_attach() end
  local a = astro()
  if a then R.from = { a.x, a.y, a.z } end
  lastStop = nil
  play(SFX.latch, { track = "SFX", volume = 0.6 })
  say(string.format("REPAIRING %s%s — right-click → Cancel repair", tk.label or "part",
    kept > 0 and string.format(" (resumed at %d%%)", math.floor(kept / tk.secs * 100 + 0.5)) or ""))
  return true
end

-- ── the fallback lock (no crew_task in the scene) ───────────────────────────
local lock = { on = false }
local function rb_of(a) local g = a.getComponent or a.getcomponent; return g and g(a, "RigidBody") end
lock_attach = function()
  local a = astro()
  if not a then return end
  local rb = rb_of(a)
  if rb then rb.kinematic = 1 end
  lock.on = true
end
local function lock_release(v, tk)
  local a = astro()
  local pw = ref("planet_walker")
  if pw and pw.steer then pcall(pw.steer, nil) end
  if a then
    local rb = rb_of(a)
    if rb then rb.kinematic = 0 end
    if v and v.node and v.node.valid and tk then
      local _, _, _, vx, vy, vz = from_part(v, tk.uid, tk.frame, tk.sx, tk.sy, tk.sz)
      if vx then a.vel = vec3(vx, vy, vz) end
    end
  end
  lock.on = false
end

-- ── ending a job ────────────────────────────────────────────────────────────
local function snd_off()
  if R.snd then pcall(R.snd.stop, R.snd) R.snd = nil end
end
local function finish(tk, how, why)
  local v = R.v or vessel_of(tk.craft)
  if how == "done" then
    local I, V = items(), inv()
    local before = V and V.itemCount(PACK, tk.item or "repairkit") or 0
    local hp, err = nil, nil
    if v and v.repairPart then hp, err = v.repairPart(tk.uid, 1.0) end
    if hp then
      if V then V.removeItem(PACK, tk.item or "repairkit", 1) end
      if v then part_st(v, tk.uid, "rprog", false, true) end
      lastRepair = { uid = tk.uid, hp = hp, t = now(), kit_before = before, kit_after = V and V.itemCount(PACK, "repairkit") or 0 }
      play(SFX.done, { track = "UI", volume = 0.6 })
      say(string.format("%s repaired — %d%%", tk.label or "part", math.floor(hp * 100 + 0.5)))
      local c = crew()
      if c and c.get and c.patch then
        local okg, r = pcall(c.get, memberId())
        if okg and r then pcall(c.patch, memberId(), { repairs = (r.repairs or 0) + 1 }) end
      end
    else
      how, why = "stop", err or "it couldn't be mended"
    end
  end
  if how ~= "done" and v and v.node and v.node.valid then
    -- the progress stays on the part for a while (a re-click resumes it)
    part_st(v, tk.uid, "rprog", { s = tk.done or 0, t = clock() }, true)
  end
  lastStop = how == "done" and "done" or (why or "cancelled")
  if how ~= "done" then say("repair stopped: " .. lastStop .. string.format(" — %d%% kept on the part", math.floor((tk.done or 0) / math.max(0.1, tk.secs) * 100 + 0.5))) end
  snd_off()
  -- release: the lock's owner lets go
  local c = crew_tasks()
  if c then
    pcall(c.cancelTask, memberId(), lastStop)
  else
    L.task = nil
  end
  if lock.on then lock_release(v, tk) end
  R = {}
  working = nil
end

-- "Cancel repair" (the menus' entry). → ok
function cancel(why)
  local tk = task()
  if not tk then return false end
  if not lock_ours() then
    -- crew_task holds and times the job: it releases, keeps the progress
    local c = crew_tasks()
    lastStop = why or "cancelled"
    snd_off()
    R, working = {}, nil
    if c then return c.cancelTask(memberId(), lastStop) end
    return false
  end
  if tk.kind ~= "repair" then
    local c = crew_tasks()
    if c then return c.cancelTask(memberId(), why or "cancelled") end
    L.task = nil
    return true
  end
  finish(tk, "stop", why or "cancelled")
  return true
end

-- ── the job's clock (fixedUpdate) ───────────────────────────────────────────
local function o2_now()
  local pw = ref("planet_walker")
  if pw and pw.downed then return 0 end
  return nil
end

-- crew_task (WS1) runs the job's clock, its stops and its end when it is in
-- the scene; the finish is ours (onDone.repair: the effects' end, the record).
local hooked = nil
local function hook_done(ct)
  if hooked == ct or not (ct and ct.onDone) then return end
  hooked = ct
  local base = ct.onDone.repair
  ct.onDone.repair = function(id, t, v)
    local V = inv()
    local before = V and V.itemCount(PACK, t.item or "repairkit") or 0
    if base then base(id, t, v) end
    local hp = v and v.partHp and v.partHp(t.uid)
    lastRepair = { uid = t.uid, hp = hp, t = now(), kit_before = before, kit_after = V and V.itemCount(PACK, t.item or "repairkit") or 0 }
    lastStop = "done"
    play(SFX.done, { track = "UI", volume = 0.6 })
  end
end

local function run_job(dt)
  local tk = task()
  if not lock_ours() then
    hook_done(ref("crew_task"))
    if not tk or tk.kind ~= "repair" then
      if R.started then
        -- it ended under crew_task: done (onDone said so) or a forced stop,
        -- whose reason is still true this tick (items.repairStop says it)
        if lastStop == nil then
          local I, v = items(), R.v
          local okv = v and v.node and v.node.valid
          local pw = ref("planet_walker")
          lastStop = (I and I.repairStop({ craft = okv and true or false,
            hp = okv and v.partHp and v.partHp(R.uid) or nil, throttle = okv and v.throttle or 0, accel = 0,
            o2 = (pw and pw.downed) and 0 or nil })) or "stopped"
        end
        snd_off()
        R, working = {}, nil
      end
      return
    end
    if not R.started then R = { v = vessel_of(tk.craft), t0 = now(), started = true, fx_t = 0, click_t = now(), save_t = now() } end
    R.uid = tk.uid
    local ct = ref("crew_task")
    local d, secs = nil, nil
    if ct and ct.progress then d, secs = ct.progress(memberId()) end
    d, secs = d or tk.done or 0, (secs and secs > 0) and secs or tk.secs or 1
    tk.done = d
    working = { label = tk.label or tk.name, frac = d / math.max(0.1, secs), uid = tk.uid, done = d, secs = secs }
    return
  end
  if not tk or tk.kind ~= "repair" then
    if lock.on then lock_release(nil, nil) end
    working = nil
    return
  end
  local v = R.v
  if not (v and v.node and v.node.valid) then v = vessel_of(tk.craft); R.v = v end
  local I = items()
  if not I then return end
  -- a job loaded from the save (or handed over): the runtime is rebuilt
  if not R.started then R = { v = v, t0 = now(), started = true, fx_t = 0, click_t = now(), save_t = now() } end
  local stop = I.repairStop({ craft = v ~= nil and v.node ~= nil and v.node.valid,
                              hp = v and v.partHp and v.partHp(tk.uid) or nil,
                              throttle = v and v.throttle or 0, accel = 0, o2 = o2_now() })
  if stop then finish(tk, "stop", stop) return end
  -- the fallback lock: ride the work spot (the slide in over `slide` s)
  if lock_ours() then
    if not lock.on then lock_attach() end
    local a = astro()
    local wx, wy, wz, vx, vy, vz = from_part(v, tk.uid, tk.frame, tk.sx, tk.sy, tk.sz)
    if a and wx then
      local k = math.min(1, (now() - (R.t0 or now())) / I.REPAIR.slide)
      if R.from and k < 1 then
        local s = k * k * (3 - 2 * k)
        -- the start point rides with the craft too (kept relative to the spot)
        if not R.rel then R.rel = { R.from[1] - wx, R.from[2] - wy, R.from[3] - wz } end
        wx, wy, wz = wx + R.rel[1] * (1 - s), wy + R.rel[2] * (1 - s), wz + R.rel[3] * (1 - s)
      end
      a.x, a.y, a.z = wx, wy, wz
      a.vel = vec3(vx, vy, vz)
    end
  end
  tk.done = math.min(tk.secs, (tk.done or 0) + dt)
  working = { label = tk.label, frac = tk.done / math.max(0.1, tk.secs), uid = tk.uid }
  if now() - (R.save_t or 0) > 1.0 then
    R.save_t = now()
    task_write(tk)
  end
  if tk.done >= tk.secs - 1e-6 then finish(tk, "done") end
end

-- ── deploy mode ─────────────────────────────────────────────────────────────
local D = { req = nil, trig = false, plant = nil, preview = nil }
local function aim_hit()
  local pc = ref("planet_camera")
  local a = astro()
  if not (pc and pc.cam_x and pc.fwd_x and a and raycast) then return nil end
  local ox, oy, oz = pc.cam_x, pc.cam_y, pc.cam_z
  local range = (params.deploy_reach or 24) + len(a.x - ox, a.y - oy, a.z - oz)
  local ok, h = pcall(raycast, ox, oy, oz, pc.fwd_x, pc.fwd_y, pc.fwd_z, range, { ignore = a })
  if not ok or not h then return nil end
  if len(h.x - a.x, h.y - a.y, h.z - a.z) > (params.deploy_reach or 24) then return nil end
  return h
end

local function near_other(d, x, y, z)
  if d.store == "comms" then
    local net = ref("comms")
    return net and net.beaconNear and net.beaconNear(x, y, z, d.spacing) ~= nil
  end
  local dep = ref("deployables")
  if dep and dep.near then
    local ok, r = pcall(dep.near, x, y, z, d.spacing)
    return ok and r ~= nil and r ~= false and (type(r) ~= "table" or next(r) ~= nil)
  end
  return false
end

-- Where the held deployable would go, and whether it can. → req
local function deploy_check(id, h)
  local I = items()
  local d = I.deployOf(id)
  local bname = space.dominant(h.x, h.y, h.z)
  local body = bname and space.body(bname)
  if not body then return { bad = "not on a world" } end
  local ux, uy, uz = norm(h.x - body.x, h.y - body.y, h.z - body.z)
  local nx, ny, nz = h.nx or ux, h.ny or uy, h.nz or uz
  local bad = nil
  if inv().itemCount(PACK, id) < 1 then bad = "none left in the pack"
  elseif nx * ux + ny * uy + nz * uz < d.slope then bad = "too steep to stand it on"
  elseif near_other(d, h.x, h.y, h.z) then bad = "too close to another"
  end
  if not bad then
    local cl = ref("climate")
    local dep = cl and cl.seaDepth and cl.seaDepth(h.x, h.y, h.z)
    if dep and dep > 0.05 then bad = "under water" end
  end
  if not bad and d.store == "deployables" then
    local dep = ref("deployables")
    if not (dep and dep.place) then bad = "the agency's flag store isn't in this build yet" end
  end
  if not bad and d.store == "comms" then
    local net = ref("comms")
    if not (net and net.placeBeacon) then bad = "no comms network in this scene" end
  end
  return { id = id, d = d, body = bname, x = h.x - body.x, y = h.y - body.y, z = h.z - body.z,
           ux = ux, uy = uy, uz = uz, bad = bad }
end

-- Place it now (after the plant animation): the store first, then the pack.
local function deploy_place(req)
  local b = space.body(req.body)
  if not b then return nil, "the world went away" end
  local gx, gy, gz = b.x + req.x, b.y + req.y, b.z + req.z
  local d, id = req.d, req.id
  local placed = nil
  if d.store == "comms" then
    local net = ref("comms")
    placed = net and net.placeBeacon and net.placeBeacon(req.body, gx, gy, gz) or nil
  else
    local dep = ref("deployables")
    if dep and dep.place then
      local a = astro()
      local yaw = 0
      if a then
        local m = model()
        yaw = m and m.yaw or 0
      end
      local ok, r = pcall(dep.place, d.kind or id, req.body, gx, gy, gz, { by = memberId(), yaw = yaw })
      placed = ok and r or nil
    end
  end
  if not placed then return nil, "it wouldn't stand there" end
  inv().removeItem(PACK, id, 1)
  lastDeploy = { id = placed, kind = id, store = d.store, t = now() }
  local c = crew()
  if c and c.get and c.patch and id == "flag" then
    local okg, r = pcall(c.get, memberId())
    if okg and r then pcall(c.patch, memberId(), { flags = (r.flags or 0) + 1 }) end
  end
  return placed
end

-- The plant animation: kneel and set it down over `secs` (§5.5's hook; the
-- body stands still meanwhile). Probes call it directly.
function plantAnim(secs, kind)
  D.plant_anim = { t0 = now(), secs = secs or 1.0, kind = kind }
end

-- A probe's way to put the held deployable at a world point.
function deployAt(x, y, z)
  local id = held()
  local I = items()
  if not (id and I and I.deployOf(id)) then return nil, "nothing deployable in hand" end
  local req = deploy_check(id, { x = x, y = y, z = z })
  if req.bad then return nil, req.bad end
  return deploy_place(req)
end

local ghosts = {}
local function ghost_node(prefab)
  local g = ghosts[prefab]
  if g == "spawning" or g == "missing" then return nil end
  if g and g.valid then return g end
  ghosts[prefab] = "spawning"
  local ok = pcall(spawn, prefab, vec3(0, 0, 0), function(n) ghosts[prefab] = n; n.visible = false end)
  if not ok then ghosts[prefab] = "missing" end
  return nil
end
local function ghosts_off()
  for _, g in pairs(ghosts) do if type(g) == "table" and g.valid and g.visible then g.visible = false end end
end

local function deploy_tick(id, firing)
  local edge = firing and not D.trig
  D.trig = firing
  local P = D.plant
  if P then
    -- kneeling: the keys are the job's for these seconds
    local pw = ref("planet_walker")
    if pw and pw.steer then pcall(pw.steer, 0, 0, false, false, 0) end
    prompt = string.format("setting down the %s…", label_of(P.req.id))
    if now() - P.t0 >= P.secs then
      D.plant = nil
      if pw and pw.steer then pcall(pw.steer, nil) end
      local placed, why = deploy_place(P.req)
      if placed then
        play(SFX.set, { track = "UI", volume = 0.5 })
        say(string.format("%s set down%s", label_of(P.req.id), P.req.d.store == "comms" and (" — relay " .. tostring(placed)) or ""))
      else
        play(SFX.denied, { track = "UI", volume = 0.5 })
        say(why or "it wouldn't stand there", true)
      end
    end
    return
  end
  local h = aim_hit()
  if not h then
    D.req = nil
    prompt = string.format("no ground within %.0f m of the crosshair", params.deploy_reach or 24)
    return
  end
  local req = deploy_check(id, h)
  D.req = req
  -- the beacon's relay preview (the links it would make)
  if req.d and req.d.store == "comms" and not req.bad then
    local net = ref("comms")
    local p = D.preview
    if net and net.previewLinks and (not p or now() - p.t > 0.3 or len(req.x - p.x, req.y - p.y, req.z - p.z) > 0.5) then
      local b = space.body(req.body)
      local links, connected = net.previewLinks(h.x, h.y, h.z)
      for _, l in ipairs(links or {}) do l.x, l.y, l.z = l.x - b.x, l.y - b.y, l.z - b.z end
      D.preview = { x = req.x, y = req.y, z = req.z, links = links or {}, connected = connected, t = now() }
    end
    req.links = D.preview and D.preview.links or {}
    req.linked = D.preview and D.preview.connected
  end
  if req.bad then
    prompt = req.bad
  else
    prompt = string.format("LMB set down the %s (%d in the pack)%s", label_of(id), inv().itemCount(PACK, id),
      req.linked == false and "  ·  no relay with a path home in sight" or "")
  end
  if edge then
    if req.bad then
      play(SFX.denied, { track = "UI", volume = 0.5 })
      say(req.bad, true)
    else
      local secs = req.d.secs or 1.0
      D.plant = { t0 = now(), secs = secs, req = req }
      plantAnim(secs, id)
      play(SFX.plant, { track = "SFX", volume = 0.5 })
    end
  end
end

local function deploy_paint()
  local req = D.plant and D.plant.req or D.req
  if not (req and req.d and req.body) then ghosts_off() return end
  local b = space.body(req.body)
  if not b then ghosts_off() return end
  local x, y, z = b.x + req.x, b.y + req.y, b.z + req.z
  local ok = req.bad == nil
  local want_name = ok and req.d.ghost or req.d.bad
  for name, g in pairs(ghosts) do
    if type(g) == "table" and g.valid and name ~= want_name and g.visible then g.visible = false end
  end
  local g = want_name and ghost_node(want_name)
  if g then
    local half = 0
    if req.d.store == "comms" then
      local E = ref("electronics")
      half = ((E and E.COMMS and E.COMMS.beacon.height) or 4.2) * 0.5
    else
      -- the store's own origin height for its kind (deployables.KINDS)
      local dep = ref("deployables")
      local k = dep and dep.KINDS and dep.KINDS[req.d.kind or req.id]
      half = k and k.origin or 0
    end
    local ux, uy, uz = req.ux, req.uy, req.uz
    local fx, fy, fz = 1 - ux * ux, -ux * uy, -ux * uz
    if fx * fx + fy * fy + fz * fz < 1e-4 then fx, fy, fz = 0, 0, 1 end
    g:setUp(vec3(ux, uy, uz), vec3(fx, fy, fz))
    g.x, g.y, g.z = x + ux * half, y + uy * half, z + uz * half
    if not g.visible then g.visible = true end
  end
  -- the relay links it would make, from its mast
  if ok and req.links and draw and draw.line then
    local E = ref("electronics")
    local m = (E and E.COMMS and E.COMMS.beacon.mast) or 2.2
    local ax, ay, az = x + req.ux * m, y + req.uy * m, z + req.uz * m
    for _, l in ipairs(req.links) do
      local lr, lg, lb = 0.4, 0.9, 0.6
      if E and E.strengthColor then lr, lg, lb = E.strengthColor(l.hop or l.strength or 0) end
      draw.line(ax, ay, az, b.x + l.x, b.y + l.y, b.z + l.z, lr, lg, lb, 0.9)
    end
  end
end

-- ── is the hand ours this frame? ────────────────────────────────────────────
local function on_foot()
  local pw = ref("planet_walker")
  if not (pw and pw.onFoot == true) then gate = "aboard" return false end
  local gm = ref("game_manager")
  if gm and (gm.loading or gm.inputOwner == "builder") then gate = "builder" return false end
  for _, k in ipairs({ "pause_menu" }) do local s = ref(k); if s and s.open then gate = "paused" return false end end
  for _, k in ipairs({ "facility_menu", "ops_board", "orbit_map", "context_menu" }) do
    local s = ref(k)
    if s and s.isOpen and s.isOpen() then gate = k return false end
  end
  local ip = ref("inventory_panel")
  if ip and ip.open then gate = "pack" return false end
  gate = "in hand"
  return true
end

local function pressed(k)
  if sim and sim.pressed and sim.pressed[k] then sim.pressed[k] = nil return true end
  return input and input.pressed and input.pressed(k) == true
end

-- ── the visuals: the item in the hand, the work on the hull ─────────────────
local frame_of   -- (below)
local props = {}      -- key → node (spawned once, hidden when not in use)
local function prop(id, key)
  local I = items()
  local d = I and I.def(id)
  local pf = d and ((d.hold and d.hold.grip ~= "two" and d.hold.prefab) or (d.worn and d.worn.prefab))
  if not pf then return nil end
  id = key or id
  local p = props[id]
  if p == "spawning" or p == "missing" then return nil end
  if p and p.valid then return p end
  props[id] = "spawning"
  local ok = pcall(spawn, pf, vec3(0, 0, 0), function(n)
    props[id] = n
    n.visible = false
    n.castShadow = true
  end)
  if not ok then props[id] = "missing" end
  return nil
end
local function props_except(keep)
  for id, p in pairs(props) do
    if type(p) == "table" and p.valid and id ~= keep and id:sub(1, 5) ~= "worn:" and p.visible then p.visible = false end
  end
end

-- WORN: the Oxygen Tanks clipped either side of the PLSS (two at most are
-- drawn; the rest ride inside). The RCS Pack is eva_pack's (WS1).
local function pose_worn(show)
  local V = inv()
  local n = (show and V) and math.min(2, V.itemCount(PACK, "o2tank")) or 0
  local m, an = model()
  local o, U, F, Rt
  if n > 0 and m and an and an.boneWorld then o, U, F, Rt = frame_of(m) end
  local back = n > 0 and an and an.boneWorld and an:boneWorld("Back") or nil
  for i = 1, 2 do
    local key = "worn:o2tank" .. i
    local p = (i <= n and back) and prop("o2tank", key) or props[key]
    if type(p) == "table" and p.valid then
      local on = i <= n and back ~= nil
      if on then
        local side = (i == 1) and 1 or -1
        local c = back - F * 0.25 + Rt * (0.19 * side) - U * 0.10
        p:setUp(U, Rt * side)
        p.x, p.y, p.z = c.x, c.y, c.z
      end
      if p.visible ~= on then p.visible = on end
    end
  end
end

frame_of = function(m)
  local o = m:toWorld(vec3(0, 0, 0))
  local U = m:toWorld(vec3(0, 1, 0)) - o
  local F = m:toWorld(vec3(0, 0, 1)) - o
  local Rr = m:toWorld(vec3(-1, 0, 0)) - o
  return o, U:normalized(), F:normalized(), Rr:normalized()
end

-- the hand's carry (no job running)
local function pose_carry(id, dt, fp)
  local I = items()
  local grip = I.gripOf(id)
  local p = prop(id)
  props_except(id)
  if not p then return end
  local m, an = model()
  if fp or not (m and an and an.boneWorld) then if p.visible then p.visible = false end return end
  local o, U, F, Rt = frame_of(m)
  if grip == "left" then
    -- a case by its handle: the handle in the left fist, the case hanging
    -- plumb below it, its long side along the stride
    local hpos = an:boneWorld("Hand.Left")
    if not hpos then return end
    local c = hpos - U * 0.13 - Rt * 0.02
    p:setUp(U, F)
    p.x, p.y, p.z = c.x, c.y, c.z
  elseif grip == "shoulder" then
    -- over the right shoulder, slung diagonally, the right hand steadying it
    local sh = an:boneWorld("Upperarm.Right")
    if not sh then return end
    local axis = (U * 0.85 - F * 0.5):normalized()
    local c = sh + U * 0.06 - F * 0.10 - Rt * 0.02
    p:setUp(axis, (F + U * 0.5):normalized())
    p.x, p.y, p.z = c.x, c.y, c.z
    local grab = c + axis * -0.18 + F * 0.06
    pcall(an.reach, an, "Hand.Right", grab, { pole = sh - U * 0.3 + Rt * 0.4, weight = 0.9 })
  end
  if not p.visible then p.visible = true end
end

-- the work: both hands on the hull at the hit point, the kit clamped beside
local function pose_work(tk, dt)
  local v = R.v
  if not (v and v.node and v.node.valid) then v = vessel_of(tk.craft); R.v = v end
  if not (v and v.node and v.node.valid) then return end
  local hx, hy, hz = from_part(v, tk.uid, tk.frame, tk.lx, tk.ly, tk.lz, true)
  if not hx then return end
  local tnx, tny, tnz = tk.nx, tk.ny, tk.nz
  if not tnx then tnx, tny, tnz = norm((tk.sx or 0) - tk.lx, (tk.sy or 0) - tk.ly, (tk.sz or 0) - tk.lz) end
  local ex, ey, ez = from_part(v, tk.uid, tk.frame, tk.lx + tnx, tk.ly + tny, tk.lz + tnz, true)
  local nx, ny, nz = norm(ex - hx, ey - hy, ez - hz)   -- (a direction: any frame's offset cancels)
  if R.pnode and R.pnode.valid ~= false and R.nl then
    local w = R.pnode:toWorld(R.nl)
    hx, hy, hz = w.x, w.y, w.z
  end
  workX, workY, workZ = hx, hy, hz   -- (probes: the hit as drawn this frame)
  local m, an = model()
  local a = astro()
  local hit = vec3(hx, hy, hz)
  local n = vec3(nx, ny, nz)
  -- face the work: the body yaws toward the hit point
  if m and a then
    local l = a:toLocal(hit)
    if l.x * l.x + l.z * l.z > 1e-4 then m.yaw = math.atan2(l.x, l.z) end
  end
  local side
  if m then
    local o, U = frame_of(m)
    side = n:cross(U)
    if side:length() < 1e-3 then side = vec3(1, 0, 0) end
    side = side:normalized()
    if an and an.reach then
      local sh = an:boneWorld("Upperarm.Right")
      local sl = an:boneWorld("Upperarm.Left")
      -- LEAN IN: past arm's length (0.62 m from the shoulders) the back bends
      -- toward the work. Which way "forward" turns this rig's Back bone is
      -- read off the pose itself (a write is in boneWorld's answer the same
      -- pass), so the lean never throws the chest away from the hull.
      if sh and sl then
        local mid = (sh + sl) * 0.5
        local over = (mid - hit):length() - 0.62
        if over > 0.02 then
          local want = math.min(0.75, over * 1.4)
          if not R.lean_sign then
            pcall(an.addBoneRot, an, "Back", 0, 0.3, 0, 1.0)
            local s2 = an:boneWorld("Upperarm.Right")
            local s3 = an:boneWorld("Upperarm.Left")
            local d2 = (s2 and s3) and ((s2 + s3) * 0.5 - hit):length() or 1e9
            R.lean_sign = d2 < (mid - hit):length() and 1 or -1
            pcall(an.addBoneRot, an, "Back", 0, -0.3, 0, 1.0)
          end
          R.lean = (R.lean or 0) + (want - (R.lean or 0)) * math.min(1, dt * 6)
          pcall(an.addBoneRot, an, "Back", 0, R.lean * R.lean_sign, 0, 1.0)
          sh = an:boneWorld("Upperarm.Right") or sh
          sl = an:boneWorld("Upperarm.Left") or sl
        end
      end
      -- the hands work a hand's breadth apart, a little off the skin, and
      -- move: a short scrub along the seam
      local wob = math.sin(now() * 7.0) * 0.035
      local rh = hit + side * (0.07 + wob) + n * 0.03
      local lh = hit - side * (0.08 - wob * 0.5) + n * 0.035
      if sh then pcall(an.reach, an, "Hand.Right", rh, { pole = sh - U * 0.45 + side * 0.3, weight = 1.0 }) end
      if sl then pcall(an.reach, an, "Hand.Left", lh, { pole = sl - U * 0.45 - side * 0.3, weight = 1.0 }) end
      -- (probes: how far the right hand landed from where it was sent, both
      -- read in this pass, the drawn pose)
      local hr = an:boneWorld("Hand.Right")
      if hr then handErr = (hr - rh):length(); handToHit = (hr - hit):length() end
      pcall(an.lookAt, an, { "Back", "Head" }, hit, { limit = 60, weight = 0.8 })
    end
  else
    side = vec3(1, 0, 0)
  end
  -- the kit, opened and clamped to the hull beside the hands
  local p = prop("repairkit")
  props_except("repairkit")
  if p then
    local c = hit - side * 0.34 + n * 0.09
    p:setUp(n, side)
    p.x, p.y, p.z = c.x, c.y, c.z
    if not p.visible then p.visible = true end
  end
  -- sparks and the weld's flicker at the hands; the ratchet and the hiss
  if now() - (R.fx_t or 0) > 0.07 and spawnEffect then
    R.fx_t = now()
    local s = hit + n * 0.02 + side * (math.random() - 0.5) * 0.08
    pcall(spawnEffect, "Sparks", s, { normal = n, scale = 0.35 + math.random() * 0.25, intensity = 0.8 })
    if math.random() < 0.18 then pcall(spawnEffect, "CutBite", s, { normal = n, scale = 0.5 }) end
  end
  if not R.snd then R.snd = play(SFX.weld, { track = "SFX", volume = 0.18, pitch = 1.9, loop = true }) end
  if now() > (R.click_t or 0) then
    R.click_t = now() + 0.35 + math.random() * 0.45
    play(SFX.ratchet .. tostring(math.random(0, 4)) .. ".ogg", { track = "SFX", volume = 0.35, pitch = 1.3 + math.random() * 0.3 })
  end
  -- the ring of progress over the part, and the line
  if camera and camera.worldToScreen and draw and draw.circle then
    local sx, sy, _, on = camera.worldToScreen(hx + nx * 0.4, hy + ny * 0.4, hz + nz * 0.4)
    local f = working and working.frac or 0
    if on and sx then
      local N = 32
      local lit = math.floor(f * N + 0.5)
      for i = 0, N - 1 do
        local ang = -math.pi / 2 + i / N * 2 * math.pi
        local px, py = sx + math.cos(ang) * 26, sy + math.sin(ang) * 26
        if i < lit then draw.circle(px, py, 2.2, 0.97, 0.55, 0.22, 0.95)
        else draw.circle(px, py, 1.4, 0.92, 0.89, 0.81, 0.35) end
      end
    end
    if draw.text and camera.screenRect then
      local vx, vy, vw, vh = camera.screenRect()
      if vw then
        local txt = string.format("REPAIRING %s  ·  %d%%  ·  right-click → Cancel repair", string.upper(tk.label or tk.name or "part"),
          math.floor(f * 100))
        draw.text(vx + vw * 0.5, vy + vh * 0.78 + 1, txt, 16, 0, 0, 0, 0.6, "center")
        draw.text(vx + vw * 0.5, vy + vh * 0.78, txt, 16, 1.0, 0.86, 0.62, 1.0, "center")
      end
    end
  end
end

-- the plant: kneel, the right hand to the ground point
local function pose_plant()
  local P = D.plant
  if not P then return end
  local m, an = model()
  if not (m and an and an.reach) then return end
  local b = space.body(P.req.body)
  if not b then return end
  local g = vec3(b.x + P.req.x, b.y + P.req.y, b.z + P.req.z)
  local o, U, F, Rt = frame_of(m)
  local k = math.min(1, (now() - P.t0) / math.max(0.1, P.secs))
  local w = math.sin(k * math.pi)
  local sh = an:boneWorld("Upperarm.Right")
  if sh then pcall(an.reach, an, "Hand.Right", g + U * 0.12, { pole = sh + Rt * 0.4 - U * 0.2, weight = w }) end
  pcall(an.addBoneRot, an, "Back", 0, 0.5 * w, 0, w)
end

-- ── the frame ───────────────────────────────────────────────────────────────
local carrying = false
function update(node, dt)
  prompt = ""
  carrying = on_foot()
  local tk = task()
  if tk then
    -- held at the work: the walker's keys stand down (crew_task's does it
    -- when it holds the lock; the fallback's here)
    if lock_ours() then
      local pw = ref("planet_walker")
      if pw and pw.steer then pcall(pw.steer, 0, 0, false, false, 0) end
    end
    prompt = "at work  ·  right-click → Cancel repair"
    return
  end
  if not carrying then D.req = nil return end
  -- the belt: number keys by position, the same slot again or H = empty hands
  local b = belt()
  for i, s in ipairs(b) do
    if pressed(tostring(i)) then
      if s.id == held() then set_hand(nil) else set_hand(s.id) end
    end
  end
  if pressed("h") then set_hand(nil) end
  local id = held()
  local I = items()
  if id and I and I.deployOf(id) then
    local firing = (sim and sim.lmb) or (input and input.button and input.button(0) == true)
    deploy_tick(id, firing == true)
  else
    D.req, D.plant = nil, nil
    if id and I and not I.isTool(id) then prompt = hint() end
  end
end

function fixedUpdate(node, dt)
  run_job(dt)
end

-- Each piece guarded on its own: a pose that fails (a rig without a bone it
-- asks for) must not take the ghost, the work or the other props with it.
local said = {}
local function guard(tag, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok and not said[tag] then said[tag] = true; log("item_hand: " .. tag .. ": " .. tostring(err)) end
end

function lateUpdate(node, dt)
  local tk = task()
  local pc = ref("planet_camera")
  local fp = pc and pc.firstPerson == true
  local pw = ref("planet_walker")
  guard("worn", pose_worn, pw and pw.onFoot == true and not fp)
  if tk and tk.kind == "repair" then
    ghosts_off()
    guard("work", pose_work, tk, dt)
    return
  end
  if R.snd then snd_off() end
  if not carrying then props_except(nil) ghosts_off() return end
  local id = held()
  local I = items()
  if id and I and not I.isTool(id) then guard("carry", pose_carry, id, dt, fp) else props_except(nil) end
  if id and I and I.deployOf(id) then guard("ghost", deploy_paint) guard("plant", pose_plant) else ghosts_off() end
end

function start(node)
  load_hand()
end
