-- CONTEXT MENU — right-click a thing in the world and see what you can do with it.
--
--   RMB TAP      (press and let go without dragging: a held or dragged right
--                button is still the camera's look) — the menu for what is
--                under the cursor; in first person or the pilot's seat, for
--                what is under the crosshair; on nothing at all in first
--                person, your own suit's
--   pad Y        (the "Context" action) the same, at the crosshair / centre
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

defaults = {
  --@range 0.1 1 --@units s
  tap_secs = 0.35,        -- an RMB press longer than this is a look, not a click
  --@range 1 30 --@units px
  tap_px = 6,             -- …and so is one that moved this far
  --@range 5 200 --@units m
  reach_foot = 60.0,      -- how far the pick ray goes from the crew
  --@range 20 2000 --@units m
  reach_craft = 400.0,    -- …and from a flying craft's camera
  --@range 5 200 --@units m
  close_range = 40.0,     -- the menu closes when the actor is this far from its target
  --@range 2 30 --@units Hz
  refresh = 8.0,          -- how often the open menu is re-described (live values)
}

-- Published.
open = false
target = nil
actor = nil
escTakenAt = -1
lastOpen = nil            -- { kind, label, t } of the last menu opened (probes)

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
             lib_t = -10, list = {}, title = nil, sub = nil }

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
function resolve(hit)
  if not (hit and hit.node) then return nil end
  local n = hit.node
  local hx, hy, hz = hit.x, hit.y, hit.z
  if n.name == "Astronaut" then
    return { kind = "astro", node = n, pack = "astro", label = "Crew", wx = hx, wy = hy, wz = hz }
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
  return { kind = "prop", node = n, label = n.name, mass = rb and rb.mass or nil, wx = hx, wy = hy, wz = hz }
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

-- PICK: a ray through a screen pixel → target (or nil). Global for probes.
function pick(sx, sy, who)
  who = who or actorNow()
  if not (who and camera and camera.screenToRay) then return nil end
  local ok, ox, oy, oz, dx, dy, dz = pcall(camera.screenToRay, sx, sy)
  if not ok or not ox then return nil end
  local range = who.kind == "craft" and params.reach_craft or params.reach_foot
  -- the camera can sit metres behind the crew: the reach is the crew's
  if who.node and who.node.worldPos then
    local w = who.node.worldPos
    range = range + math.sqrt((w.x - ox) ^ 2 + (w.y - oy) ^ 2 + (w.z - oz) ^ 2)
  end
  local opts = nil
  if who.kind == "crew" and eyes() then opts = { ignore = who.node } end
  -- flying, the crew riding in the craft is part of the furniture: a click
  -- on the pod is the pod, not the person sitting in it
  if who.kind == "craft" then
    local ig = {}
    for _, c in ipairs(who.crew or {}) do if c.node and c.node.valid ~= false then ig[#ig + 1] = c.node end end
    if #ig > 0 then opts = { ignore = ig } end
  end
  local okr, hit = pcall(raycast, ox, oy, oz, dx, dy, dz, range, opts)
  local t = okr and resolve(hit) or nil
  if t then return t end
  -- The crew themselves, by eye: a ray can slip past a capsule at a glance,
  -- so a tap within ~40 px of the crew's chest on screen counts.
  if who.kind == "crew" and camera.worldToScreen and not eyes() then
    local a = who.node
    local up = a.up or vec3(0, 1, 0)
    local px, py, _, on = camera.worldToScreen(a.worldX + up.x * 0.3, a.worldY + up.y * 0.3, a.worldZ + up.z * 0.3)
    if on and math.abs(px - sx) < 40 and math.abs(py - sy) < 60 then
      return { kind = "astro", node = a, pack = "astro", label = "Crew" }
    end
  end
  -- Nothing under the crosshair in first person: your own suit.
  if who.kind == "crew" and eyes() then
    return { kind = "astro", node = who.node, pack = "astro", label = "Crew" }
  end
  return nil
end

-- ── the rim light on the target ─────────────────────────────────────────────
local RIM = { rim = { 1.0, 0.62, 0.30 }, rimStrength = 0.9 }
local RIM_OFF = { rimStrength = 0.0 }
local function light(t)
  for _, n in ipairs(st.lit) do if n.valid ~= false and n.setTint then pcall(n.setTint, n, RIM_OFF) end end
  st.lit = {}
  if not t then return end
  local root = t.node
  if t.kind == "astro" and root then
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
  st.stack, st.desc_t, st.msg = {}, -1, nil
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
    st.desc_t, st.focus_next = -1, true
    return true
  end
  if e.type == "info" or e.type == "meter" or e.type == "header" then return false end
  local ok, why, job = r.press(e, dir)
  if job then start_job(job, e) st.desc_t = -1 return true end
  if not ok then toast(why or "can't do that", true)
  elseif why then toast(why) end
  if ok and not e.keep and e.type == "action" then close() else st.desc_t = -1 end
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

local function readout(e, i)
  local val = live(e.value)
  local warn = live(e.warn) == true
  local row = { "row", key = "r" .. i, w = "100%", h = "fit", gap = 6, pad = 0, align = "center",
    -- a short printed legend and a wide number; a long legend (a stack in a
    -- locker: "3 × Copper Ore") takes the width and the number fits beside it
    { "text", key = "l", style = "hud/micro", w = (#(e.label or "") > 12) and "grow" or 78, h = 16, text = e.label or "",
      textValign = "center", maxLines = 1, overflow = "ellipsis" },
    { "text", key = "v", style = warn and "hud/valueWarn" or "hud/value", w = (#(e.label or "") > 12) and 72 or "grow", h = 16,
      textAlign = "end", textValign = "center", text = val and tostring(val) or "—", maxLines = 1, overflow = "ellipsis" } }
  if e.type ~= "meter" then return row end
  local f = math.max(0, math.min(1, tonumber(live(e.frac)) or 0))
  local GW = W_MENU - 2 * 12 - 2 * 8
  return { "col", key = "m" .. i, w = "100%", h = "fit", gap = 2, pad = 0, row,
    { "row", key = "g", w = "100%", h = 5, pad = 0, gap = 0, radius = 1, fill = { 0.01, 0.02, 0.015 },
      border = 1, borderColor = { 0, 0, 0, 0.8 },
      { "box", key = "f", w = math.max(1, math.floor(GW * f + 0.5)), h = 5, radius = 1,
        fill = warn and WARN or PHOS } } }
end

local function key_row(e, i, first)
  local r = registry()
  local ok, why = r.usable(e)
  local style = e.danger and "panel/danger" or "panel/row"
  local hint = e.hint
  if e.type == "sub" then hint = hint or "▸" end
  local kids = {
    { "text", key = "l", style = "panel/cell", w = "grow", h = 18, text = e.label, textValign = "center",
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
    tooltip = (not ok) and why or nil,
    onClicked = function() handle(e) end }
  for _, k in ipairs(kids) do b[#b + 1] = k end
  return b
end

local function describe(list, title, subtitle)
  local rows = {}
  local h = 44
  rows[#rows + 1] = { "text", key = "title", style = "panel/heading", w = "100%", h = 20, text = title or "—",
    maxLines = 1, overflow = "ellipsis" }
  if subtitle then
    rows[#rows + 1] = { "text", key = "sub", style = "panel/label", w = "100%", h = 14, text = subtitle,
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
      screen_rows[#screen_rows + 1] = readout(e, i)
      h = h + (e.type == "meter" and 25 or 19)
    else
      screen_rows = nil
      if e.type == "header" then
        rows[#rows + 1] = { "text", key = "h" .. i, style = "panel/label", w = "100%", h = 16, text = e.label,
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
    text = recent and st.msg or (#st.stack > 0 and "↑ ↓ ENTER  ·  ESC back" or "↑ ↓ ENTER  ·  ESC close") }
  h = h + 24
  local W, H = layer_size()
  -- Flying, the instrument panel along the bottom is another UI layer, drawn
  -- over this one: the plate stays above it.
  local floor = (actor and actor.kind == "craft") and 196 or 6
  local x = math.max(6, math.min(st.x + 14, W - W_MENU - 6))
  local y = math.max(6, math.min(st.y + 10, H - h - floor))
  st.rect = { x = x, y = y, w = W_MENU, h = h }
  return { "col", key = "ctx", style = "panel/frame", pin = "topLeft", x = x, y = y, w = W_MENU, h = "fit",
    gap = 4, pad = 12, align = "stretch", items = rows, function(r) return r end }
end

local function mouse_in_menu()
  if not st.rect then return false end
  local mx, my = input.mouse()
  local x, y = to_du(mx, my)
  local r = st.rect
  return x >= r.x - 4 and x <= r.x + r.w + 4 and y >= r.y - 4 and y <= r.y + r.h + 4
end
function ownsMouse() return open and mouse_in_menu() end

-- ── each frame ──────────────────────────────────────────────────────────────
-- Is something else up that owns the screen? (Then no menu, and an open one
-- closes: the pause menu, a facility's panel, the pack, the map, the builder.)
local function blocked()
  local gm = ref("game_manager")
  if gm and (gm.loading or gm.inputOwner == "builder") then return true end
  local pm = ref("pause_menu")
  if pm and pm.open then return true end
  local fm = ref("facility_menu")
  if fm and fm.isOpen and fm.isOpen() then return true end
  local ob = ref("ops_board")
  if ob and ob.isOpen and ob.isOpen() then return true end
  local ip = ref("inventory_panel")
  if ip and ip.open then return true end
  local om = ref("orbit_map")
  if om and om.isOpen and om.isOpen() then return true end
  local pc = ref("planet_camera")
  if pc and (pc.freecam or pc.cinematic) then return true end
  return false
end

-- Still a menu worth showing? (The target can leave; the actor can walk off.)
local function still_valid()
  if not (target and actor) then return false end
  if actor.node and actor.node.valid == false then return false end
  local t = target
  if t.kind == "part" then
    local v = t.vessel
    if not (v and v.node and v.node.valid) then return false end
    if v.partRec and not v.partRec(t.uid) then return false end
  elseif t.node and t.node.valid == false then
    return false
  end
  -- the actor changed (boarded, stepped out): the menu was theirs
  local now = actorNow()
  if not now or now.id ~= actor.id then return false end
  if actor.kind == "crew" and actor.node and actor.node.distanceTo then
    local n = (t.node and t.node.valid ~= false) and t.node or nil
    if n and actor.node:distanceTo(n) > params.close_range then return false end
  end
  return true
end

-- The right button: a TAP opens, a hold or a drag is the camera's.
local function rmb_tap()
  local down = input.button(1) == true
  local R = st.rmb
  if down and not R then
    local mx, my = input.mouse()
    st.rmb = { t = time or 0, x = mx, y = my, moved = 0 }
    return nil
  end
  if R and down then
    local dx, dy = input.mouse_delta()
    R.moved = R.moved + math.abs(dx or 0) + math.abs(dy or 0)
    return nil
  end
  if R and not down then
    st.rmb = nil
    if (time or 0) - R.t <= params.tap_secs and R.moved <= params.tap_px then return R end
  end
  return nil
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
    return
  end
  -- the opening gestures
  local tap = rmb_tap()
  local pad = input.action ~= nil and input.action("Context") == true
  local pad_edge = pad and not st.pad_prev
  st.pad_prev = pad
  if tap or pad_edge then
    if not (open and tap and mouse_in_menu()) then
      local who = actorNow()
      if who then
        local sx, sy
        if pad_edge or eyes() then sx, sy = crosshair() else sx, sy = tap.x, tap.y end
        local t = pick(sx, sy, who)
        if t then openFor(t, who, sx, sy) elseif open then close() end
      end
    end
  end
  if not open then return end
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
      st.desc_t, st.focus_next = -1, true
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
    st.desc_t = -1
  end
  -- the plate, re-described a few times a second (live numbers)
  local W, H = layer_size()
  if el.width ~= W then el.width = W end
  if el.height ~= H then el.height = H end
  el.visible = true
  if (time or 0) - st.desc_t >= 1 / params.refresh then
    st.desc_t = time or 0
    local list, title, sub = entries()
    st.list = list
    ui.make(node, { describe(list, title, sub) })
  end
  if st.focus_next and ui and ui.focus and find then
    local f = find("CtxFirstRow")
    if f then ui.focus(f); st.focus_next = false end
  end
end
