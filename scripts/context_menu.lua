-- CONTEXT MENU — right-click a thing in the world and see what you can do with it.
--
--   RMB TAP      (press and let go without dragging: a held or dragged right
--                button is still the camera's look) — the menu for what is
--                under the cursor; in first person or the pilot's seat, for
--                what is under the crosshair (there the pointer is locked and
--                RMB is not the look: any press shorter than `tap_secs` is a
--                tap, however the hand moved). On nothing in reach, no menu:
--                a caption says so (no silent fallback to your own suit)
--   U / pad Y    (the "ContextKey" action on foot, "Context" anywhere) the
--                same, at the crosshair / centre; HELD `hold_secs`: your own
--                suit's menu (and a tap on yourself in third person)
--   ↑ ↓ ENTER    move and press (the rows are keys the engine's UI focus
--                reaches); a pad's d-pad and A do the same
--   ESC          back out of a sub-panel, then close (a rung on the pause
--                menu's Esc ladder: the press is ours, it doesn't pause)
--   click away, walk away (more than `close_range` from it), or the thing
--   going away (staged off, recovered) closes it
--
-- WHAT IT SHOWS is not decided here. The pick resolves a TARGET — the crew,
-- a part of a craft (its vessel_controller and blueprint record), a salvage
-- crate, anything else with a body — and the ACTOR who asked: the crew
-- member on foot, or the craft being flown. The registry
-- (scripts/context_registry.lua: the provider contract is written there)
-- asks every provider of the target's kind for its rows; this script draws
-- them as a Flight Hardware plate at the cursor (docs/ui-style.md: a screwed
-- enamel panel, live numbers on a CRT inset in phosphor mono, rows as keys),
-- runs their presses and their timed jobs, and lights the target's rim while
-- the menu is up.
--
-- INPUT IS ONLY OURS WHILE THE MENU IS OPEN. Closed, the script reads one
-- button edge a frame and does nothing else; the walker, the belt and the
-- craft's keys are never consumed. Open, the pointer is freed (planet_camera
-- asks `isOpen()` as it does the other panels), the belt stands down
-- (tool_belt's gate, a patch for its owner), and the flight's keys still fly.
-- The VAB builder has its own menu (builder_context.lua, the same registry)
-- and this one stands down while `game_manager.inputOwner` is the builder.
--
-- Probes: `openFor(target, actor)`, `pick(sx, sy)`, `press(id)`, `entries()`.
-- DEBUG: `ctxDebug = true` logs one line per tap attempt ("context: tap …":
-- the view, the pixel, what the ray hit and how far, the target or why not)
-- and each change of what blocks the menus; `lastTap` keeps the last one.

defaults = {
  --@range 0.1 1 --@units s
  tap_secs = 0.35,        -- an RMB press longer than this is a look, not a click
  --@range 0.2 2 --@units s
  tap_secs_locked = 0.8,  -- …with the pointer locked (first person) RMB is no look: only a long hold is not a tap (a slow frame or two must not eat a click)
  --@range 1 30 --@units px
  tap_px = 10,            -- …and so is one that moved this far (third person; px at 720 lines, scaled by the screen)
  --@range 0.2 2 --@units s
  hold_secs = 0.4,        -- the Context key held this long opens your own suit's menu
  --@range 5 200 --@units m
  reach_foot = 60.0,      -- how far the pick ray goes from the crew
  --@range 20 2000 --@units m
  reach_craft = 400.0,    -- …and from a flying craft's camera
  --@range 5 200 --@units m
  close_range = 40.0,     -- the menu closes when the actor is this far from its target
  --@range 1 30 --@units Hz
  refresh = 4.0,          -- how often the open menu's live values are read again (its rows are kept)
  --@range 0.5 10 --@units s
  rows_keep = 2.0,        -- the providers are asked for the rows again this often (and at once after a press, a sub-panel, the structures changing)
}

-- Published.
open = false
target = nil
actor = nil
escTakenAt = -1
lastOpen = nil            -- { kind, label, t } of the last menu opened (probes)
ctxDebug = false          -- one log line per tap attempt, and each blocked() change
lastTap = nil             -- { t, eyes, sx, sy, hit, parent, dist, recast, kind, label, why } (probes)
lastBlocked = nil         -- the reason the menus stand down now, or nil

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end

local el = nil
local W_MENU = 272
local st = { stack = {}, x = 0, y = 0, rect = nil, desc_t = -1, msg = nil, msg_t = -10, msg_bad = false,
             job = nil, lit = {}, focus_next = false, rmb = nil, pad_prev = false, lmb_prev = false,
             lib_t = -10, list = {}, title = nil, sub = nil,
             dirty = true, rows_t = -10, rows_ver = nil, gen = 0, sig = nil }
-- What the menu costs (probes, tests/smoke_interact.lua): provider passes,
-- describes, ui.make calls and their wall milliseconds.
PROF = { rows = 0, rows_ms = 0, describes = 0, desc_ms = 0, makes = 0, make_ms = 0, worst_ms = 0 }

function isOpen() return open end

-- ── the library ─────────────────────────────────────────────────────────────
local function registry()
  local r = ref("context_registry")
  if not r and (time or 0) - st.lib_t > 2.0 and spawn then
    st.lib_t = time or 0
    pcall(spawn, "ContextLib", vec3(0, 0, 0))
  end
  return r
end

-- ── screen ↔ design units ───────────────────────────────────────────────────
local function design_h()
  local pm = ref("pause_menu")
  return (pm and pm.uiDesignH and pm.uiDesignH()) or 720
end
local function screen()
  if not (camera and camera.screenRect) then return 0, 0, 1280, 720 end
  local ox, oy, w, h = camera.screenRect()
  if not (w and h and h > 0) then return 0, 0, 1280, 720 end
  return ox, oy, w, h
end
local function to_du(px, py)
  local ox, oy, _, h = screen()
  local H = design_h()
  return (px - ox) * H / h, (py - oy) * H / h
end
local function layer_size()
  local _, _, w, h = screen()
  local H = design_h()
  return H * w / h, H
end

-- ── the tap rule (pure: tests/smoke_interact.lua) ───────────────────────────
-- A right press `dt` s long that moved `px` physical pixels in all is a TAP
-- when it is short, and — with the pointer free — when it barely moved (a
-- drag is the camera's look). With the pointer LOCKED (first person, the
-- seat, shift-lock) the movement is the head's look, not a drag: RMB is not
-- the look button there, so only the time counts, and more of it
-- (`tap_secs_locked`: an engine run under load once let a quick click span
-- past 0.35 s and dropped it). `h` = the screen's height in physical pixels:
-- the slack is `tap_px` at 720 lines, more on a bigger screen (a 1440p mouse
-- moves twice the pixels for the same hand).
function tapAccepts(dt, px, locked, h)
  if locked then return (dt or 0) <= (params.tap_secs_locked or params.tap_secs) end
  if (dt or 0) > params.tap_secs then return false end
  local lim = params.tap_px * math.max(1, (h or 720) / 720)
  return (px or 0) <= lim
end

-- ── who is asking ───────────────────────────────────────────────────────────
-- The ACTOR: the craft being flown, or the crew member on foot. (One crew
-- today; the roster will hand a node per member, and nothing below assumes
-- there is only one: the actor is passed along, never looked up again.)
local function piloted()
  for _, v in ipairs(findScripts and findScripts("vessel_controller") or {}) do
    if v.piloting and v.node and v.node.valid then return v end
  end
  return nil
end
function actorNow()
  local v = piloted()
  if v then
    return { kind = "craft", vessel = v, node = v.node, id = "craft:" .. tostring(v.node.id),
             crew = v.crewAboard and { { id = "astro", node = find and find("Astronaut") or nil } } or {} }
  end
  local pw = ref("planet_walker")
  local a = find and find("Astronaut")
  if pw and pw.onFoot == true and a then
    local tb = ref("tool_belt")
    local held = nil
    if tb and tb.toolId then
      local ok, id = pcall(tb.toolId)
      if ok and id then held = { id = id, n = 1 } end
    end
    return { kind = "crew", node = a, id = "astro", pack = "astro", held = held, aboard = false }
  end
  -- seated aboard a craft without its controls (a passenger's seat, a save
  -- loaded aboard: Ty's slot1): the craft is still who asks, so a right tap
  -- is never silently nothing
  local C = ref("crew")
  local okc, ac = false, nil
  if C and C.avatarCraft then okc, ac = pcall(C.avatarCraft) end
  if okc and ac and ac.node and ac.node.valid ~= false then
    return { kind = "craft", vessel = ac, node = ac.node, id = "craft:" .. tostring(ac.node.id), seated = true,
             crew = { { id = "astro", node = a } } }
  end
  return nil
end

-- ── the world: what is this? ────────────────────────────────────────────────
local function vessel_of(n)
  if not n then return nil end
  for _, v in ipairs(findScripts and findScripts("vessel_controller") or {}) do
    if v.node and v.node.valid and v.node.id == n.id then return v end
  end
  return nil
end

-- The part record nearest a vessel-frame point (a ray that names the root).
local function nearest_rec(v, lx, ly, lz)
  local best, bd = nil, 1e18
  for u, d in pairs(v.aboardRecs and v.aboardRecs() or {}) do
    local dx, dy, dz = (d.x or 0) - lx, (d.y or 0) - ly, (d.z or 0) - lz
    local dd = dx * dx + dy * dy + dz * dz
    if dd < bd then best, bd = u, dd end
  end
  return best
end

local function part_target(v, partNode, hx, hy, hz)
  local uid = nil
  if partNode and v.uidOfNode then uid = v.uidOfNode(partNode) end
  if not uid and partNode and v.uidNear then
    uid = v.uidNear(partNode.x or 0, partNode.y or 0, partNode.z or 0, 0.12)
  end
  if not uid and hx and v.node.toLocal then
    local l = v.node:toLocal(vec3(hx, hy, hz))
    uid = nearest_rec(v, l.x, l.y, l.z)
    partNode = nil
  end
  if not uid then return nil end
  local rec = (v.partRec and v.partRec(uid)) or (v.aboardRecs and v.aboardRecs()[uid])
  if not rec then return nil end
  return { kind = "part", vessel = v, uid = uid, rec = rec, node = partNode, label = rec.label, wx = hx, wy = hy, wz = hz }
end

-- What a hit names. nil for the ground and the sky.
-- Is node `n` the actor `a` or under it (up to 4 parents)? A collider that
-- arrives with the suit, the helmet or a tool in hand is the crew, not a prop.
function underActor(n, a)
  if not (n and a) then return false end
  local okA, aid = pcall(function() return a.id end)
  if not okA or aid == nil then return false end
  for _ = 0, 4 do
    if not n then return false end
    local ok, nid = pcall(function() return n.id end)
    if ok and nid == aid then return true end
    local okp, par = pcall(function() return n.parent end)
    n = okp and par or nil
  end
  return false
end

function resolve(hit, actorNode)
  if not (hit and hit.node) then return nil end
  local n = hit.node
  local hx, hy, hz = hit.x, hit.y, hit.z
  if n.name == "Astronaut" then
    return { kind = "astro", node = n, pack = "astro", label = "Crew", wx = hx, wy = hy, wz = hz }
  end
  local an = actorNode
  if an == nil and find then an = find("Astronaut") end
  if an and underActor(n, an) then
    return { kind = "astro", node = an, pack = "astro", label = "Crew", wx = hx, wy = hy, wz = hz }
  end
  -- another crew member on foot (a CrewBody): who they are, for the Medkit
  local cb = (n.name == "CrewBody" and n) or (n.parent and n.parent.name == "CrewBody" and n.parent) or nil
  if cb then
    local c = ref("crew")
    local id = c and c.memberOfNode and c.memberOfNode(cb)
    local r = id and c.get and c.get(id)
    if r then return { kind = "member", node = cb, id = id, pack = "crew:" .. id, label = r.name, wx = hx, wy = hy, wz = hz } end
  end
  -- a craft: the part itself (its parent is the craft's root), or the root
  local v = vessel_of(n.parent)
  if v then return part_target(v, n, hx, hy, hz) end
  v = vessel_of(n)
  if v then return part_target(v, nil, hx, hy, hz) end
  if n.name == "SalvageCrate" or (n.parent and n.parent.name == "SalvageCrate") then
    local sv = ref("salvage")
    local e = sv and sv.nearest and sv.nearest(hx, hy, hz, 4.0)
    if e then return { kind = "crate", id = e.id, entry = e, node = n, wx = hx, wy = hy, wz = hz } end
  end
  local rb = n.getcomponent and n:getcomponent("RigidBody")
  -- (the click point kept body-relative at once, as the pick's own frame read:
  -- a provider asked a frame later finds the spot on a moving planet —
  -- the kit's decals and signs, which a ray passes through to the wall)
  local body, rx, ry, rz = nil, nil, nil, nil
  if space and space.dominant and hx then
    body = space.dominant(hx, hy, hz)
    local b = body and space.body(body)
    if b then rx, ry, rz = hx - b.x, hy - b.y, hz - b.z end
  end
  return { kind = "prop", node = n, label = n.name, mass = rb and rb.mass or nil, wx = hx, wy = hy, wz = hz,
           body = body, rx = rx, ry = ry, rz = rz }
end

local function crosshair()
  local ox, oy, w, h = screen()
  return ox + w * 0.5, oy + h * 0.5
end

-- Is the view the crew's own eyes (or the pilot's seat)? Then the pick is the
-- crosshair, and the crew's own body is not in the way of it.
local function eyes()
  local pc = ref("planet_camera")
  return pc ~= nil and (pc.firstPerson == true or pc.cockpit == true)
end

-- Is the pointer locked to the view (first person, the seat, shift-lock on
-- foot)? Then the pick is the crosshair and mouse movement is the look.
local function locked_view()
  if eyes() then return true end
  local pc = ref("planet_camera")
  return pc ~= nil and pc.shiftlock == true and piloted() == nil
end
lockedView = locked_view

local function node_name(n)
  if not n then return nil end
  local ok, nm = pcall(function() return n.name end)
  return ok and nm or "?"
end
local function parent_name(n)
  if not n then return nil end
  local ok, p = pcall(function() return n.parent end)
  return ok and p and node_name(p) or nil
end

-- PICK: a ray through a screen pixel → target, or nil and why. Global for
-- probes. The third value is the instrument: { hit, parent, dist, recast }.
REACH_EYES = 0.6     -- a first-person hit nearer the eye than this, on the crew themselves, is cast past
function pick(sx, sy, who)
  who = who or actorNow()
  local info = { sx = sx, sy = sy }
  if not (who and camera and camera.screenToRay) then return nil, "no actor", info end
  local ok, ox, oy, oz, dx, dy, dz = pcall(camera.screenToRay, sx, sy)
  if not ok or not ox then return nil, "no ray", info end
  local range = who.kind == "craft" and params.reach_craft or params.reach_foot
  -- the camera can sit metres behind the crew: the reach is the crew's
  if who.node and who.node.worldPos then
    local w = who.node.worldPos
    range = range + math.sqrt((w.x - ox) ^ 2 + (w.y - oy) ^ 2 + (w.z - oz) ^ 2)
  end
  local eyes_now = eyes()
  local opts = nil
  -- from the crew's own eyes their whole body is behind the lens: the ray
  -- passes the avatar AND everything under it (suit, helmet, the tool in
  -- hand: `ignoreChildren`), so the first thing it meets is the world
  if who.kind == "crew" and eyes_now and who.node then opts = { ignore = who.node, ignoreChildren = true } end
  -- flying, the crew riding in the craft is part of the furniture: a click
  -- on the pod is the pod, not the person sitting in it
  if who.kind == "craft" then
    local ig = {}
    for _, c in ipairs(who.crew or {}) do if c.node and c.node.valid ~= false then ig[#ig + 1] = c.node end end
    if #ig > 0 then opts = { ignore = ig, ignoreChildren = true } end
  end
  local okr, hit = pcall(raycast, ox, oy, oz, dx, dy, dz, range, opts)
  if not okr then hit = nil; info.err = tostring(hit) end
  -- First person: a hit on the crew themselves, or anything of theirs right
  -- at the lens, is cast past once, from REACH_EYES along the same ray (one
  -- extra ray, on a tap only)
  if hit and who.kind == "crew" and eyes_now and hit.node and underActor(hit.node, who.node)
     and (hit.distance or 0) < 2.5 then
    info.recast = node_name(hit.node)
    local skip = math.max(REACH_EYES, (hit.distance or 0) + 0.05)
    local okr2, h2 = pcall(raycast, ox + dx * skip, oy + dy * skip, oz + dz * skip, dx, dy, dz, range - skip, opts)
    hit = okr2 and h2 or nil
    if hit and hit.distance then hit.distance = hit.distance + skip end
  end
  if hit then
    info.hit, info.parent, info.dist = node_name(hit.node) or "ground", parent_name(hit.node), hit.distance
  end
  local t = resolve(hit, who.node)
  -- (from the eyes, the crew never pick themselves: that is the held key's)
  if t and t.kind == "astro" and who.kind == "crew" and eyes_now then t = nil end
  if t then return t, nil, info end
  -- The crew themselves, by eye: a ray can slip past a capsule at a glance,
  -- so a tap within ~40 px of the crew's chest on screen counts.
  if who.kind == "crew" and camera.worldToScreen and not eyes_now and who.node and who.node.worldX then
    local a = who.node
    local up = a.up or vec3(0, 1, 0)
    local px, py, _, on = camera.worldToScreen(a.worldX + up.x * 0.3, a.worldY + up.y * 0.3, a.worldZ + up.z * 0.3)
    if on and math.abs(px - sx) < 40 and math.abs(py - sy) < 60 then
      return { kind = "astro", node = a, pack = "astro", label = "Crew" }, nil, info
    end
  end
  -- Nothing to open: say what the ray met (no silent fallback to the suit)
  if hit and hit.node == nil then return nil, "the ground", info end
  if hit then return nil, "nothing to do with " .. tostring(info.hit), info end
  return nil, "nothing in reach", info
end

-- Your own suit's menu (the Context key held; the crew strip's portrait).
function selfTarget(who)
  who = who or actorNow()
  if not (who and who.kind == "crew" and who.node) then return nil end
  return { kind = "astro", node = who.node, pack = "astro", label = "Crew" }
end

-- ── the rim light on the target ─────────────────────────────────────────────
local RIM = { rim = { 1.0, 0.62, 0.30 }, rimStrength = 0.9 }
local RIM_OFF = { rimStrength = 0.0 }
local function light(t)
  for _, n in ipairs(st.lit) do if n.valid ~= false and n.setTint then pcall(n.setTint, n, RIM_OFF) end end
  st.lit = {}
  if not t then return end
  local root = t.node
  if (t.kind == "astro" or t.kind == "member") and root then
    for _, c in ipairs(root:children()) do if c.name == "AstroModel" then root = c end end
  end
  if not (root and root.valid ~= false and root.setTint) then return end
  local list = { root }
  for _, c in ipairs(root:children() or {}) do list[#list + 1] = c end
  for _, n in ipairs(list) do
    local okt, err = pcall(n.setTint, n, RIM)
    if okt then st.lit[#st.lit + 1] = n
    elseif not st.tint_err then st.tint_err = true; log("context: the rim light didn't take: " .. tostring(err)) end
  end
end

-- ── open / close ────────────────────────────────────────────────────────────
function close()
  if st.job and st.job.spec.cancel then pcall(st.job.spec.cancel) end
  st.job = nil
  if open then
    local fx = ref("sfx")
    if fx and fx.play then pcall(fx.play, "close") end
  end
  open, target, actor = false, nil, nil
  st.stack, st.rect = {}, nil
  light(nil)
  if el then el.visible = false end
end

-- Open the menu for a target, as `who`, at a screen pixel (default: the
-- target's own spot on screen, else the middle). → true if it opened.
function openFor(t, who, sx, sy)
  who = who or actorNow()
  if not (t and who) then return false end
  if not sx and camera and camera.worldToScreen and t.wx then
    local px, py, _, on = camera.worldToScreen(t.wx, t.wy, t.wz)
    if on then sx, sy = px, py end
  end
  if not sx then sx, sy = crosshair() end
  target, actor, open = t, who, true
  st.stack, st.desc_t, st.msg, st.dirty, st.sig, st.actor_t = {}, -1, nil, true, nil, nil
  st.x, st.y = to_du(sx, sy)
  st.focus_next = true
  light(t)
  lastOpen = { kind = t.kind, label = t.label, t = time }
  local fx = ref("sfx")
  if fx and fx.play then pcall(fx.play, "click") end
  log(string.format("context: menu on %s%s for %s (rim on %d node(s))", t.kind, t.label and (" (" .. tostring(t.label) .. ")") or "", who.id, #st.lit))
  return true
end

local function toast(msg, bad)
  st.msg, st.msg_t, st.msg_bad = msg, time or 0, bad == true
  local fx = ref("sfx")
  if fx and fx.play and bad then pcall(fx.play, "denied") end
end

local function ctx()
  return {
    actor = actor, ref = ref, toast = toast, close = close,
    sparks = function(t)
      local n = t and t.node
      local w = n and n.valid ~= false and n.worldPos
      if w and spawnEffect then pcall(spawnEffect, "Sparks", w.x, w.y, w.z) end
    end,
  }
end

-- The entries now showing (the top sub-panel's, else the target's).
function entries()
  local r = registry()
  if not (open and r) then return {} end
  local top = st.stack[#st.stack]
  local c = ctx()
  if top then
    local ok, list = pcall(top.sub)
    local out = {}
    for i, e in ipairs(ok and list or {}) do
      local n = r.normalize(e, "sub", i)
      if n then out[#out + 1] = n end
    end
    return out, top.title, top.subtitle
  end
  local list, errs, title, sub = r.entriesFor(target, c)
  for _, e in ipairs(errs or {}) do
    if st.err ~= e then st.err = e; log("context: provider error " .. e) end
  end
  return list, title, sub
end

local function start_job(spec, e)
  st.job = { spec = spec, t = 0, label = spec.label or e.label }
  local fx = ref("sfx")
  if fx and fx.play then pcall(fx.play, "arm") end
end

-- Press an entry (a row's click, ENTER on a focused row, or a probe by id).
function handle(e, dir)
  local r = registry()
  if not (r and e) then return false end
  if e.type == "sub" then
    local ok, why = r.usable(e)
    if not ok then toast(why, true) return false end
    st.stack[#st.stack + 1] = { sub = e.sub, title = e.title or e.label, subtitle = e.subtitle }
    st.dirty, st.focus_next = true, true
    return true
  end
  if e.type == "info" or e.type == "meter" or e.type == "header" then return false end
  local ok, why, job = r.press(e, dir)
  if job then start_job(job, e) st.dirty = true return true end
  if not ok then toast(why or "can't do that", true)
  elseif why then toast(why) end
  if ok and not e.keep and e.type == "action" then close() else st.dirty = true end
  return ok
end

function press(id)
  local r = registry()
  local list = entries()
  local e = r and r.byId(list, id)
  if not e then return false, "no entry " .. tostring(id) end
  return handle(e)
end

-- ── drawing ─────────────────────────────────────────────────────────────────
local PHOS = { 0.64, 0.93, 0.56 }
local WARN = { 1.00, 0.80, 0.28 }
local function live(v) local r = registry(); return r and r.live(v) or v end
-- Words for a UI `text`: a provider may give a label or a hint as a function
-- (live) — the engine's ui.make takes only plain values, and ONE function in
-- one row made the whole plate fail to draw (the Reactor Control Console's
-- "Console: next page" hint: its menu came up blank, Ty's "right-click the
-- console" that did nothing). Resolved here, for every text the plate shows.
local function words(v)
  v = live(v)
  if v == nil then return nil end
  if type(v) == "string" then return v end
  if type(v) == "number" or type(v) == "boolean" then return tostring(v) end
  return nil
end
textOf = words

local LONG = 20          -- an info value longer than this wraps under its legend
local function readout(e, i)
  local val = words(e.value)
  local warn = live(e.warn) == true
  local lbl = words(e.label) or ""
  -- a sentence (part_info's WHY, a consequence, a reason) wraps on its own
  -- lines under a short legend instead of being cut off at the plate's edge
  if e.type == "info" and type(val) == "string" and #val > LONG then
    return { "col", key = "w" .. i, w = "100%", h = "fit", gap = 1, pad = 0,
      { "text", key = "l", style = "hud/micro", w = "100%", h = 14, text = lbl, maxLines = 1, overflow = "ellipsis" },
      { "text", key = "v", style = warn and "hud/valueWarn" or "hud/value", w = "100%", h = "fit", wrap = true, maxLines = 4,
        overflow = "ellipsis", text = val } }, val
  end
  local row = { "row", key = "r" .. i, w = "100%", h = "fit", gap = 6, pad = 0, align = "center",
    -- a short printed legend and a wide number; a long legend (a stack in a
    -- locker: "3 × Copper Ore") takes the width and the number fits beside it
    { "text", key = "l", style = "hud/micro", w = (#lbl > 12) and "grow" or 78, h = 16, text = lbl,
      textValign = "center", maxLines = 1, overflow = "ellipsis" },
    { "text", key = "v", style = warn and "hud/valueWarn" or "hud/value", w = (#lbl > 12) and 72 or "grow", h = 16,
      textAlign = "end", textValign = "center", text = val or "—", maxLines = 1, overflow = "ellipsis" } }
  if e.type ~= "meter" then return row, val end
  local f = math.max(0, math.min(1, tonumber(live(e.frac)) or 0))
  local GW = W_MENU - 2 * 12 - 2 * 8
  return { "col", key = "m" .. i, w = "100%", h = "fit", gap = 2, pad = 0, row,
    { "row", key = "g", w = "100%", h = 5, pad = 0, gap = 0, radius = 1, fill = { 0.01, 0.02, 0.015 },
      border = 1, borderColor = { 0, 0, 0, 0.8 },
      { "box", key = "f", w = math.max(1, math.floor(GW * f + 0.5)), h = 5, radius = 1,
        fill = warn and WARN or PHOS } } }, val
end

local function key_row(e, i, first)
  local r = registry()
  local ok, why = r.usable(e)
  local style = e.danger and "panel/danger" or "panel/row"
  local hint = words(e.hint)
  if e.type == "sub" then hint = hint or "▸" end
  local kids = {
    { "text", key = "l", style = "panel/cell", w = "grow", h = 18, text = words(e.label) or "", textValign = "center",
      maxLines = 1, overflow = "ellipsis" } }
  if e.type == "toggle" then
    local on = live(e.on) == true
    kids[#kids + 1] = { "box", key = "k", style = "panel/choice", selected = on, w = 40, h = 18,
      text = on and "ON" or "OFF", textAlign = "center", textValign = "center" }
  elseif hint then
    kids[#kids + 1] = { "text", key = "h", style = "panel/keys", w = "fit", h = 18, text = hint, textValign = "center" }
  end
  local b = { "button", key = "b" .. i, name = first and "CtxFirstRow" or nil, style = style, w = "100%", h = 26,
    dir = "row", gap = 6, pad = 4, align = "center", disabled = (not ok) or nil, opacity = (not ok) and 0.5 or nil,
    tooltip = (not ok) and words(why) or nil,
    onClicked = function() handle(e) end }
  for _, k in ipairs(kids) do b[#b + 1] = k end
  return b
end

local function describe(list, title, subtitle)
  local rows = {}
  local h = 44
  rows[#rows + 1] = { "text", key = "title", style = "panel/heading", w = "100%", h = 20, text = words(title) or "—",
    maxLines = 1, overflow = "ellipsis" }
  if subtitle then
    rows[#rows + 1] = { "text", key = "sub", style = "panel/label", w = "100%", h = 14, text = words(subtitle) or "",
      maxLines = 1, overflow = "ellipsis" }
    h = h + 16
  end
  rows[#rows + 1] = { "box", key = "rule0", style = "panel/rule", w = "100%", h = 1 }
  -- Live numbers sit on a CRT inset; keys sit on the plate.
  local screen_rows, first = nil, true
  for i, e in ipairs(list) do
    if e.type == "info" or e.type == "meter" then
      if not screen_rows then
        screen_rows = { "col", key = "crt" .. i, style = "hud/instrument", w = "100%", h = "fit", gap = 3, pad = 8 }
        rows[#rows + 1] = screen_rows
        h = h + 18
      end
      local row, val = readout(e, i)
      screen_rows[#screen_rows + 1] = row
      local v = e.type == "info" and val
      local extra = (type(v) == "string" and #v > LONG) and (15 + 17 * math.min(4, math.ceil(#v / 30))) or 0
      h = h + (e.type == "meter" and 25 or (extra > 0 and extra or 19))
    else
      screen_rows = nil
      if e.type == "header" then
        rows[#rows + 1] = { "text", key = "h" .. i, style = "panel/label", w = "100%", h = 16, text = words(e.label) or "",
          textValign = "end", maxLines = 1, overflow = "ellipsis" }
        h = h + 20
      else
        rows[#rows + 1] = key_row(e, i, first)
        first = false
        h = h + 30
      end
    end
  end
  if #list == 0 then
    rows[#rows + 1] = { "text", key = "none", style = "panel/hint", w = "100%", h = 18, text = "Nothing to do with this." }
    h = h + 22
  end
  -- the foot: a job's progress, a result, or the keys
  if st.job then
    local f = math.min(1, st.job.t / math.max(0.1, st.job.spec.secs or 1))
    local GW = W_MENU - 2 * 12
    rows[#rows + 1] = { "text", key = "jobl", style = "panel/title", w = "100%", h = 16,
      text = string.format("%s  %d%%", st.job.label or "Working", math.floor(f * 100)) }
    rows[#rows + 1] = { "row", key = "jobg", w = "100%", h = 6, pad = 0, gap = 0, radius = 1, fill = { 0.02, 0.03, 0.025 },
      border = 1, borderColor = { 0, 0, 0, 0.8 },
      { "box", key = "f", w = math.max(1, math.floor(GW * f + 0.5)), h = 6, radius = 1, fill = { 0.97, 0.55, 0.22 } } }
    h = h + 30
  end
  rows[#rows + 1] = { "box", key = "rule1", style = "panel/rule", w = "100%", h = 1 }
  local recent = st.msg and (time or 0) - st.msg_t < 3.5
  rows[#rows + 1] = { "text", key = "foot", style = (recent and st.msg_bad) and "panel/hintWarn" or "panel/hint",
    w = "100%", h = "fit", wrap = true,
    text = recent and (words(st.msg) or "") or (#st.stack > 0 and "↑ ↓ ENTER  ·  ESC back" or "↑ ↓ ENTER  ·  ESC close") }
  h = h + 24
  local W, H = layer_size()
  -- Flying, the instrument panel along the bottom is another UI layer, drawn
  -- over this one: the plate stays above it.
  local floor = (actor and actor.kind == "craft") and 196 or 6
  -- (graveyard2) a scenario's dialogue plate along the bottom: the menu keeps
  -- above it (it had drawn over the plate's lower half)
  local SG = findScript and findScript("scenario_stage")
  if SG and SG.plateBand then
    local okb, _, top = pcall(SG.plateBand)
    if okb and top then floor = math.max(floor, top + 8) end
  end
  local x = math.max(6, math.min(st.x + 14, W - W_MENU - 6))
  local y = math.max(6, math.min(st.y + 10, H - h - floor))
  st.rect = { x = x, y = y, w = W_MENU, h = h }
  return { "col", key = "ctx", style = "panel/frame", pin = "topLeft", x = x, y = y, w = W_MENU, h = "fit",
    gap = 4, pad = 12, align = "stretch", items = rows, function(r) return r end }
end

-- What the plate shows, as one string: when it is what was made last time
-- the engine is not asked to reconcile it again. (pure: tests)
local SIG_KEYS = { "text", "style", "selected", "w", "h", "x", "y", "disabled", "tooltip", "name", "opacity" }
function treeSig(t, acc)
  acc = acc or {}
  if type(t) ~= "table" then return acc end
  if type(t[1]) == "string" then acc[#acc + 1] = t[1] end
  if t.key ~= nil then acc[#acc + 1] = "#" .. tostring(t.key) end
  for _, k in ipairs(SIG_KEYS) do
    local v = t[k]
    if v ~= nil and type(v) ~= "table" and type(v) ~= "function" then acc[#acc + 1] = k .. "=" .. tostring(v) end
  end
  for _, v in ipairs(t) do if type(v) == "table" then treeSig(v, acc) end end
  if type(t.items) == "table" then for _, v in ipairs(t.items) do treeSig(v, acc) end end
  acc[#acc + 1] = "/"
  return acc
end

local function mouse_in_menu()
  if not st.rect then return false end
  local mx, my = input.mouse()
  local x, y = to_du(mx, my)
  local r = st.rect
  return x >= r.x - 4 and x <= r.x + r.w + 4 and y >= r.y - 4 and y <= r.y + r.h + 4
end
function ownsMouse() return open and mouse_in_menu() end
-- The open menu's plate in screen pixels (x, y, w, h), or nil: for screen
-- drawing that should keep off it (the orbit map's name tags).
function screenRect()
  local r = open and st.rect
  if not r then return nil end
  local ox, oy, _, h = screen()
  local k = h / design_h()
  return ox + r.x * k, oy + r.y * k, r.w * k, r.h * k
end

-- ── each frame ──────────────────────────────────────────────────────────────
-- Is something else up that owns the screen? (Then no menu, and an open one
-- closes: the pause menu, a facility's panel, the pack, the map, the builder.)
-- → the reason (a word) or nil. Logged once per change with ctxDebug.
local function blocked_why()
  local gm = ref("game_manager")
  if gm and gm.loading then return "loading" end
  if gm and gm.inputOwner == "builder" then return "builder" end
  local pm = ref("pause_menu")
  if pm and pm.open then return "pause_menu" end
  local fm = ref("facility_menu")
  if fm and fm.isOpen and fm.isOpen() then return "facility_menu" end
  local ob = ref("ops_board")
  if ob and ob.isOpen and ob.isOpen() then return "ops_board" end
  local ip = ref("inventory_panel")
  if ip and ip.open then return "inventory_panel" end
  local tm = ref("terminal")
  if tm and tm.isOpen and tm.isOpen() then return "terminal" end
  local lp = ref("loot_panel")
  if lp and lp.isOpen and lp.isOpen() then return "loot_panel" end
  -- (the map's own menus — a world or a craft right-clicked on it, opened by
  -- scripts/targeting.lua, `target.map` — are the one kind that stays up there)
  local om = ref("orbit_map")
  if om and om.isOpen and om.isOpen() then
    if open and target and target.map == true then return nil end
    return "orbit_map"
  end
  local pc = ref("planet_camera")
  if pc and pc.freecam then return "freecam" end
  if pc and pc.cinematic then return "cinematic" end
  return nil
end
local function blocked()
  local why = blocked_why()
  if why ~= lastBlocked then
    if ctxDebug and log then log("context: blocked " .. tostring(lastBlocked) .. " -> " .. tostring(why)) end
    lastBlocked = why
  end
  return why ~= nil
end
blockedWhy = blocked_why

-- Still a menu worth showing? (The target can leave; the actor can walk off.)
local function still_valid()
  if not (target and actor) then return false end
  if actor.node and actor.node.valid == false then return false end
  local t = target
  if t.map then
    local om = ref("orbit_map")
    if not (om and om.isOpen and om.isOpen()) then return false end
  end
  if t.kind == "part" then
    local v = t.vessel
    if not (v and v.node and v.node.valid) then return false end
    if v.partRec and not v.partRec(t.uid) then return false end
  elseif t.node and t.node.valid == false then
    return false
  end
  -- the actor changed (boarded, stepped out): the menu was theirs (asked
  -- four times a second: it walks every craft and the belt)
  local tn = time or 0
  if not st.actor_t or tn - st.actor_t >= 0.25 or tn < st.actor_t then
    st.actor_t = tn
    local now = actorNow()
    if not now or now.id ~= actor.id then return false end
  end
  if actor.kind == "crew" and actor.node and actor.node.distanceTo then
    local n = (t.node and t.node.valid ~= false) and t.node or nil
    if n and actor.node:distanceTo(n) > params.close_range then return false end
  end
  return true
end

-- The right button: a TAP opens, a hold or a drag is the camera's.
local function rmb_tap()
  -- a weapon in hand aims with the right button (scripts/surveyor.lua's
  -- scope): its press is never a tap (holster with H, or pad Y, for the menu)
  local sv = ref("surveyor")
  if sv and sv.ownsRmb and sv.ownsRmb() then st.rmb = nil return nil end
  -- …and so does the Build Kit with a part's ghost in hand (a tap drops it)
  local fb = ref("field_builder")
  if fb and fb.ownsRmb and fb.ownsRmb() then st.rmb = nil return nil end
  local down = input.button(1) == true
  local R = st.rmb
  if down and not R then
    local mx, my = input.mouse()
    st.rmb = { t = time or 0, x = mx, y = my, moved = 0, locked = locked_view() }
    return nil
  end
  if R and down then
    local dx, dy = input.mouse_delta()
    R.moved = R.moved + math.abs(dx or 0) + math.abs(dy or 0)
    return nil
  end
  if R and not down then
    st.rmb = nil
    local _, _, _, h = screen()
    local dt = (time or 0) - R.t
    local locked = R.locked or locked_view()
    if tapAccepts(dt, R.moved, locked, h) then return R end
    if ctxDebug and log then
      log(string.format("context: tap dropped: %.2f s, moved %.0f px (slack %.0f, %s)", dt, R.moved, params.tap_px * math.max(1, h / 720), locked and "locked" or "free"))
    end
  end
  return nil
end

-- ── J6: THE WEAR TAG ────────────────────────────────────────────────────────
-- An Engineer from level 2 (crew.perk "wear_read") on foot reads a damaged
-- part's wear at a glance: the part under the cursor (the crosshair in first
-- person or shift-lock) within `wear_range` m gets a tag, "WEAR 60% · repair
-- 8 s" at their own pace. Picked at 10 Hz while the menu is closed (one ray);
-- the tag is placed in lateUpdate at the part node's DRAWN pose, so it rides
-- the part as it is drawn. Published: wearTag = { uid, label, wear, secs } | nil.
-- Probes: wearSim = { x, y } (screen px) stands in for the cursor.
wearTag = nil
wearSim = nil
WEAR_RANGE = 15.0
local wear = { gate_t = -10, on = false, t = -10, tgt = nil }
local function wear_gate()
  local now = time or 0
  if now - wear.gate_t < 1.0 then return wear.on end
  wear.gate_t = now
  local c = ref("crew")
  local id = c and c.activeId and c.activeId()
  local ok, v = false, nil
  if c and c.perk and id ~= nil then ok, v = pcall(c.perk, id, "wear_read") end
  wear.on = ok and v == true
  return wear.on
end
local function wear_tick()
  if not wear_gate() then wear.tgt, wearTag = nil, nil return end
  local now = time or 0
  if now - wear.t < 0.1 then return end
  wear.t = now
  local who = actorNow()
  if not (who and who.kind == "crew") then wear.tgt, wearTag = nil, nil return end
  local sx, sy
  if wearSim then sx, sy = wearSim[1], wearSim[2]
  else
    local pc = ref("planet_camera")
    if eyes() or (pc and pc.shiftlock) then sx, sy = crosshair() else sx, sy = input.mouse() end
  end
  local t = sx and pick(sx, sy, who) or nil
  if not (t and t.kind == "part" and t.vessel and t.vessel.partHp) then wear.tgt, wearTag = nil, nil return end
  local hp = t.vessel.partHp(t.uid)
  local a = who.node and who.node.worldPos
  if not hp or hp >= 0.999 or hp <= 0 then wear.tgt, wearTag = nil, nil return end
  if a and t.wx and math.sqrt((t.wx - a.x) ^ 2 + (t.wy - a.y) ^ 2 + (t.wz - a.z) ^ 2) > WEAR_RANGE then
    wear.tgt, wearTag = nil, nil return
  end
  local I, CT = ref("items"), ref("crew_task")
  local secs = I and I.repairSecs and I.repairSecs(hp, CT and CT.repairMult and CT.repairMult() or 1) or nil
  wear.tgt = t
  wearTag = { uid = t.uid, label = t.label or (t.rec and t.rec.label) or "part", wear = 1 - hp, secs = secs }
end
local function wear_draw()
  local W, t = wearTag, wear.tgt
  if not (W and t and t.vessel and t.vessel.node and t.vessel.node.valid ~= false and draw and draw.text) then return end
  -- the part's drawn pose this frame: its node, else its record on the root
  local x, y, z
  local n = t.node
  if n and n.valid ~= false and n.worldPos then
    local w = n.worldPos; x, y, z = w.x, w.y, w.z
  elseif t.rec and t.vessel.node.toWorld then
    local w = t.vessel.node:toWorld(vec3(t.rec.x or 0, t.rec.y or 0, t.rec.z or 0)); x, y, z = w.x, w.y, w.z
  end
  if not x then return end
  local sx, sy, _, on = camera.worldToScreen(x, y, z)
  if not (sx and on ~= false) then return end
  local _, _, _, vh = screen()
  local k = (vh or 720) / 720
  local hp = 1 - W.wear
  local c = hp < 0.45 and { 1.0, 0.35, 0.3 } or (hp < 0.75 and { 1.0, 0.72, 0.32 } or { 0.85, 0.82, 0.62 })
  local line = string.format("WEAR %d%%%s", math.floor(W.wear * 100 + 0.5), W.secs and string.format("  ·  repair %.0f s", W.secs) or "")
  local tw = 9.0 * k * #line * 0.62 + 16 * k
  draw.rect(sx - tw / 2, sy - 34 * k, tw, 34 * k, 0.04, 0.035, 0.03, 0.78, 4 * k)
  draw.text(sx, sy - 31 * k, tostring(W.label):upper(), 10 * k, 0.75, 0.72, 0.66, 1.0, "center")
  draw.text(sx, sy - 18 * k, line, 12 * k, c[1], c[2], c[3], 1.0, "center")
end
-- Drawn over the world: after the camera has placed this frame's view
-- (planet_camera.deferLate; docs/positions-and-frames.md rule 2)
local pc_late = nil
local function after_camera(node, dt, fn)
  if not (pc_late and pc_late.valid) then pc_late = findScript("planet_camera", { quiet = true }) end
  if pc_late and pc_late.valid and pc_late.deferLate then pc_late.deferLate(node, dt, fn) else fn(node, dt) end
end
local function late_wear() if not open then wear_draw() end end
function lateUpdate(node, dt)
  if open then return end
  after_camera(node, dt, late_wear)
end

function start(node)
  el = node.getcomponent and node:getcomponent("UiElement") or nil
  if el then el.visible = false end
  registry()
end

function update(node, dt)
  if not el then el = node:getcomponent("UiElement") end
  if not el then return end
  registry()
  if blocked() then
    if open then close() end
    st.rmb = nil
    wearTag, wear.tgt = nil, nil
    return
  end
  -- the opening gestures: a right tap, or the Context key (pad Y anywhere;
  -- U on foot, "ContextKey": U is the craft's deploy key while flying).
  -- The key opens on its RELEASE when it was short; held `hold_secs` it opens
  -- your own suit's menu at once.
  local tap = rmb_tap()
  local who0 = nil
  local pad = input.action ~= nil and input.action("Context") == true
  if not pad and input.action ~= nil and input.action("ContextKey") == true then
    who0 = actorNow()
    pad = who0 ~= nil and who0.kind == "crew"
  end
  local key_tap = false
  local now_t = time or 0
  if pad and not st.pad_prev then st.pad_t, st.pad_held = now_t, false end
  if pad and st.pad_t and not st.pad_held and now_t - st.pad_t >= params.hold_secs then
    st.pad_held = true
    local who = who0 or actorNow()
    local t = selfTarget(who)
    if t and not (target and target.map) then openFor(t, who) end
  end
  if not pad and st.pad_prev and st.pad_t and not st.pad_held then key_tap = true end
  st.pad_prev = pad
  if (tap or key_tap) and not (target and target.map) then
    if not (open and tap and mouse_in_menu()) then
      local who = who0 or actorNow()
      if not who and ctxDebug and log then log("context: tap with no actor (not on foot, flying or aboard)") end
      if who then
        local sx, sy
        if key_tap or locked_view() then sx, sy = crosshair() else sx, sy = tap.x, tap.y end
        local t, why, info = pick(sx, sy, who)
        lastTap = { t = now_t, eyes = eyes(), sx = sx, sy = sy, hit = info and info.hit, parent = info and info.parent,
                    dist = info and info.dist, recast = info and info.recast, kind = t and t.kind, label = t and t.label,
                    why = why, by = key_tap and "key" or "rmb" }
        if ctxDebug and log then
          log(string.format("context: tap %s eyes=%s at %.0f,%.0f hit %s<%s %.2f m%s -> %s", lastTap.by, tostring(lastTap.eyes), sx or -1, sy or -1,
            tostring(lastTap.hit), tostring(lastTap.parent), lastTap.dist or -1, lastTap.recast and (" (cast past " .. lastTap.recast .. ")") or "",
            t and (t.kind .. " " .. tostring(t.label)) or ("nothing: " .. tostring(why))))
        end
        if t then openFor(t, who, sx, sy)
        else
          if open then close() end
          -- (said, not silent: from the eyes the crosshair was on nothing you can use)
          if locked_view() and who.kind == "crew" then
            local msg = (why == "nothing in reach") and "nothing in reach · aim at a part (hold U for your suit)"
              or (tostring(why) .. " · aim at a part (hold U for your suit)")
            if caption then pcall(caption, msg) end
            local fx = ref("sfx")
            if fx and fx.play then pcall(fx.play, "denied") end
            lastTap.said = msg
          end
        end
      end
    end
  end
  if not open then wear_tick() return end
  if not still_valid() then close() return end
  -- the pointer is the menu's while it is up
  input.setMouseLocked(false)
  if input.pressed("escape") then
    escTakenAt = time
    if st.job then
      st.job = nil
      toast("called off", true)
    elseif #st.stack > 0 then
      table.remove(st.stack)
      st.dirty, st.focus_next = true, true
    else
      close()
      return
    end
  end
  local lmb = input.button(0) == true
  if lmb and not st.lmb_prev and not mouse_in_menu() then st.lmb_prev = lmb close() return end
  st.lmb_prev = lmb
  -- a timed job: polled, ticked, finished
  local J = st.job
  if J then
    local ok, why = true, nil
    if J.spec.check then ok, why = J.spec.check() end
    if not ok then
      st.job = nil
      if J.spec.cancel then pcall(J.spec.cancel) end
      toast(why or "called off", true)
    else
      J.t = J.t + dt
      if J.spec.tick then pcall(J.spec.tick, dt, J.t / math.max(0.1, J.spec.secs or 1)) end
      if J.t >= (J.spec.secs or 1) then
        st.job = nil
        local okd, r, r2 = pcall(J.spec.done)
        if not okd then toast(tostring(r), true)
        elseif r == false then toast(r2 or "it didn't work", true) end
      end
    end
    if not st.job then st.dirty = true end
  end
  -- the plate, re-described a few times a second (live numbers)
  local W, H = layer_size()
  if el.width ~= W then el.width = W end
  if el.height ~= H then el.height = H end
  el.visible = true
  -- The plate. Its ROWS are the providers' answer, asked on opening, after a
  -- press, a sub-panel or a job, when the structures change, and every
  -- `rows_keep` s; between, only the LIVE values in them (a function for a
  -- value, a meter, a toggle, a hint) are read again, `refresh` times a
  -- second (a job's bar faster), and the engine is handed the tree only when
  -- what it shows changed. (Ty 11-11: every provider asked eight times a
  -- second — the salvage rows' support walk among them — took a base part's
  -- menu to 1 fps.)
  local now = time or 0
  local ST = ref("structures")
  local ver = ST and ST.version
  local need_rows = st.dirty or st.rows_ver ~= ver or now - st.rows_t >= (params.rows_keep or 2.0)
  local hz = st.job and 12 or params.refresh
  if need_rows or now - st.desc_t >= 1 / hz then
    st.desc_t = now
    local clock = app and app.wallClock
    local w0 = clock and clock()
    if need_rows then
      st.list, st.title, st.sub = entries()
      st.rows_t, st.rows_ver, st.dirty = now, ver, false
      st.gen = st.gen + 1
      PROF.rows = PROF.rows + 1
    end
    local w1 = w0 and clock()
    local tree = describe(st.list, st.title, st.sub)
    local sig = st.gen .. "|" .. table.concat(treeSig(tree), "|")
    local w2 = w0 and clock()
    local made = false
    if sig ~= st.sig then
      st.sig, made = sig, true
      local okm, err = pcall(ui.make, node, { tree })
      if not okm and log and st.mkerr ~= err then st.mkerr = err; log("context: ui.make failed: " .. tostring(err)) end
      PROF.makes = PROF.makes + 1
    end
    if w0 then
      local w3 = clock()
      if need_rows then PROF.rows_ms = PROF.rows_ms + (w1 - w0) * 1000 end
      PROF.describes = PROF.describes + 1
      PROF.desc_ms = PROF.desc_ms + (w2 - w1) * 1000
      if made then PROF.make_ms = PROF.make_ms + (w3 - w2) * 1000 end
      PROF.worst_ms = math.max(PROF.worst_ms, (w3 - w0) * 1000)
    end
  end
  if st.focus_next and ui and ui.focus and find then
    local f = find("CtxFirstRow")
    if f then ui.focus(f); st.focus_next = false end
  end
end
