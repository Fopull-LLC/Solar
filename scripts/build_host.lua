-- BUILD HOST — the craft builder inside the real Vehicle Assembly Building
-- (docs/builder-design.md §9, WP6).
--
-- The builder used to be a scene of its own: a grey box with a static sky, a
-- world reload on the way in, on the way out and on every launch. Now it is an
-- ADDITIVE OVERLAY on the live system scene (`scenes/builder_overlay.ron`, the
-- builder's own nodes only, generated from `scenes/builder.ron` by
-- tools/gen_builder_overlay.lua). The parts stand on the VAB's mobile launcher
-- as children of a BuildFrame node, so they ride the planet's orbit and spin,
-- and the doors show the real sky, the real time of day and the real weather.
--
-- ONE SCRIPT, TWO HOSTS.
--   world       on the system scene's "Build Host" node. E at the VAB
--               (facility_menu) calls enter(); LEAVE and LAUNCH in the builder
--               call leave() and rollout(site).
--   standalone  on builder.ron's own "Build Host" node (the fallback and the
--               test host). It stands the VAB up round the stand at the origin
--               — VabInterior + FacHangar at (0, STANDALONE_Y, 0), so the ML-1
--               deck is the builder's floor (y 0.11), exactly as the in-world
--               BuildFrame puts it — and drives the fade. Leaving and launching
--               there are the old scene loads (builder.lua does them).
--
-- THE BUILDFRAME. An Empty child of VabInterior (itself parented to the planet
-- by base_facilities), at (0, FRAME_Y, 0): +Y the building's up, +Z its front
-- (the south door, the apron and the runway). The builder's coordinates are
-- this node's local ones (frameNode(), builder_space.newFrame). It is made on
-- enter and destroyed on leave, which takes every part spawned under it along:
-- the overlay's unload only removes the overlay's own nodes.
--
-- THE KEYS. While building, `game_manager.inputOwner = "builder"`: the walker,
-- the tool belt, the planet camera, the pause menu, the flight HUD and the
-- facility menu stand down (one-line gates in each), and an input context
-- swallows every mapped action. The astronaut is parked where they pressed E:
-- hidden, pinned body-relative (the planet moves), breathing (the walker's
-- aboard branch).
--
-- LAUNCH ROLLS OUT WITHOUT A RELOAD. rollout(site) fades to black, takes the
-- overlay down, and hands the saved blueprint to vessel_spawner.launchNow():
-- the same spaceport path a scene start takes — Launch Complex 1's hold-downs
-- or the runway threshold, the pilot seated by the new craft's controller —
-- then fades back in on the craft. (A crawler drive out through the door is
-- the option the design leaves open; the fade is the robust first cut.)
--
-- Published (findScript("build_host")): building, mode, state, enterMs,
-- inWorld(), frameNode(), enter(), leave(), rollout(site), standaloneReady(),
-- fadeThrough(atBlack [, ready]), fading(), partIcon(id), keepPartIcon(id, tex).

defaults = {
  fade = 0.35,        -- seconds to black (and back) round a rollout
  hold = 8.0,         -- the most a rollout waits at black for the craft
  autosave = 2.0,     -- seconds a changed craft must sit still before it is saved
  lean = 1,           -- 1: the world outside does only what the doors show while you build
}

OVERLAY = "builder_overlay"
FRAME_Y = 2.73        -- VabBuildPoint (2.84 over the slab centre) − the builder's floor_y 0.11
STANDALONE_Y = -2.73  -- the VAB's origin in builder.ron: the deck top lands on y = 0.11

building = false      -- the overlay is up (world) / the stand is up (standalone)
mode = nil            -- "world" | "standalone"
state = "idle"        -- idle · frame · loading · building · rollout
enterMs = nil         -- E to the builder's first frame, ms (probes)

-- The catalogue's tile icons (part id → "img:N"), kept here for the session:
-- the overlay's own scripts start afresh on every entry, and photographing
-- every part again took half a minute each time.
-- The engine keeps a captured texture until assets.release or Stop, not until
-- the scene goes: a picture replaced, and every one at onDestroy (a menu round
-- trip or a load), is given back, or each load photographed a new set over the
-- last one's.
local function release_tex(t) if t and assets and assets.release then pcall(assets.release, t) end end
local part_icons = {}
function partIcon(id) return part_icons[id] end
function keepPartIcon(id, tex)
  local old = part_icons[id]
  if old and old ~= tex then release_tex(old) end
  part_icons[id] = tex
end
-- The CREW tab's portraits (member id → "img:N", with the look they were
-- taken of: a changed look is photographed again), kept the same way.
local crew_portraits = {}
function crewPortrait(id)
  local e = crew_portraits[id]
  if e then return e.tex, e.key end
  return nil
end
function keepCrewPortrait(id, key, tex)
  local old = crew_portraits[id]
  if old and old.tex and old.tex ~= tex then release_tex(old.tex) end
  crew_portraits[id] = { tex = tex, key = key }
end

local host = nil      -- this script's node
local frame = nil     -- the BuildFrame node
local vab = nil       -- VabInterior
local cam_world = nil -- the world's camera node ("Camera 1")
local park = nil      -- { body = name, x, y, z } the parked astronaut, body-relative
local enter_t = 0
local ctx_pushed = false
local fade_el = nil
local ro = nil        -- the rollout in progress: { t, site, phase }
local fx = nil        -- a fadeThrough in progress: { t, phase, atBlack, ready }
local save_v, save_t = nil, 0
local pending_save = false

-- Cross-script singletons, resolved once and kept (findScript walks the scene).
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript(kind); refs[kind] = r end
  return r
end

local function valid(n) return n ~= nil and n.valid ~= false end

local function note(msg) log("build host: " .. msg) end

-- ── shared helpers ───────────────────────────────────────────────────────────

-- ── THE LEAN VAB (playtest 2026-10-26: "we do not need to simulate the whole
-- world in the vab, only the nearby terrain … so that the view resembles what
-- you would see") ────────────────────────────────────────────────────────────
-- While the builder is up (world mode) the world keeps its sky, sun, time of
-- day, weather fronts and the ground and flora round the building — what the
-- south doors show — and stops the rest, each through a switch the system
-- already has, every value put back exactly on the way out (lean_restore):
--   * weather: no rain or snow particles round the camera (they fell INSIDE
--     the hall; the fronts, the sky's gloom and the lightning go on);
--   * flora: the crew is parked, so the field's planting pass every 0.15 s
--     finds nothing new — once every 2 s instead (what is planted stays);
--   * the base behind the VAB (north of its south door: the tracking dish,
--     the fuel farm, the pad and its floodlights) is hidden — no wall of the
--     hall lets it be seen, and its lamps no longer light the fog.
-- setLean(on) switches it live (the bench's A/B).
LEAN_HIDE = { "FacTracking", "BaseFuel", "BasePad", "Pad Flood 1", "Pad Flood 2", "Pad Flood 3", "Pad Flood 4" }
leanOn = false
local lean = nil      -- what was changed: { w_particles, fl_interval, hidden = { node… } }
-- WHO HOSTS THE BUILDER NOW: "vab" (E at the Vehicle Assembly) or "stand"
-- (Build here on a Build Stand, work/standeditor/PLAN.md); nil when idle.
hostKind = nil
local stand = nil     -- the stand session (see enter_stand)
local function lean_apply()
  if lean or mode ~= "world" or (params.lean or 1) == 0 or hostKind == "stand" then return end
  lean = { hidden = {} }
  local w = ref("weather")
  if w and w.params then lean.w = w; lean.w_particles = w.params.particles; w.params.particles = false end
  local fl = ref("flora_field")
  if fl and fl.params then
    lean.fl = fl; lean.fl_interval = fl.params.interval
    fl.params.interval = math.max(fl.params.interval or 0.15, 2.0)
  end
  for _, nm in ipairs(LEAN_HIDE) do
    for _, n in ipairs(findAll and findAll(nm) or {}) do
      if valid(n) and n.visible ~= false then n.visible = false; lean.hidden[#lean.hidden + 1] = n end
    end
  end
  leanOn = true
  note(string.format("lean VAB on: weather particles off, flora every 2 s, %d nodes behind the hall hidden", #lean.hidden))
end
local function lean_restore()
  if not lean then return end
  local L = lean
  lean = nil
  if L.w and L.w.valid ~= false and L.w.params then L.w.params.particles = L.w_particles end
  if L.fl and L.fl.valid ~= false and L.fl.params then L.fl.params.interval = L.fl_interval end
  for _, n in ipairs(L.hidden) do if valid(n) then n.visible = true end end
  leanOn = false
end
function setLean(on)
  if on then params.lean = 1; if state == "building" then lean_apply() end
  else lean_restore(); params.lean = 0 end
  return leanOn
end

-- The vab_fade controller on VabInterior's root.
local function fader() return ref("vab_fade") end

-- Feed the fade the craft: its box from the builder camera (frame-local),
-- turned into the world through the frame (the identity in standalone).
local function drive_fade(on)
  -- (at a stand there is no hall to fade: a stand beside the VAB must not
  -- start fading its walls toward a craft 40 m away)
  if hostKind == "stand" and on then return end
  local f = fader()
  if not f then return end
  if not on then
    f.occlude, f.target = false, nil
    return
  end
  f.enabled, f.occlude = true, true
  f.near0, f.near1, f.rate = 1.0, 5.0, 6.0
  local bc = ref("builder_camera")
  local bx = bc and bc.bounds and bc.bounds() or nil
  if bx and bx.centre and bx.size then
    local c = bx.centre
    local wx, wy, wz = c.x, c.y, c.z
    if valid(frame) and frame.toWorld then
      local w = frame:toWorld(vec3(c.x, c.y, c.z))
      wx, wy, wz = w.x, w.y, w.z
    end
    f.target = vec3(wx, wy, wz)
    f.radius = math.max(bx.size.x, bx.size.z) * 0.5
    f.halfHeight = bx.size.y * 0.5
  else
    f.target, f.radius, f.halfHeight = nil, 2.0, 2.0
  end
end

-- THE AUTOSAVE: the stand goes to the craft library once it has sat still
-- for `autosave` seconds after a change (builder.craftSave, WP1's library), so
-- a crash or a quit mid-build loses nothing. Quiet: no hint.
local stand_autosave
local function autosave_tick()
  local b = ref("builder")
  if not (b and b.craftVersion and b.craftSave) then return end
  local v = b.craftVersion
  if save_v == nil then save_v, save_t = v, time return end
  if v ~= save_v then
    save_v, save_t = v, time
    pending_save = true
  elseif pending_save and time - save_t >= (params.autosave or 2.0) then
    pending_save = false
    local name = b.craftName and b.craftName() or nil
    -- (at a stand the work in progress is the stand's, not the library's:
    -- SAVE / Ctrl+S still puts it in the library)
    if hostKind == "stand" then pcall(stand_autosave, b) else pcall(b.craftSave, name, true) end
  end
end

-- ── standalone (builder.ron) ─────────────────────────────────────────────────

local stand_spawned = false
function standaloneReady() return mode == "standalone" and valid(vab) end

local function standalone_start()
  if stand_spawned then return end
  stand_spawned = true
  -- The shell and the high bay share one origin and rotation (tools/gen_vab.py).
  spawn("FacHangar", vec3(0, STANDALONE_Y, 0), function(n) n.x, n.y, n.z = 0, STANDALONE_Y, 0 end)
  spawn("VabInterior", vec3(0, STANDALONE_Y, 0), function(n)
    n.x, n.y, n.z = 0, STANDALONE_Y, 0
    vab = n
  end)
end

-- ── world (system.ron) ───────────────────────────────────────────────────────

local function astronaut() return find("Astronaut") end

local function world_camera()
  if not valid(cam_world) then cam_world = find("Camera 1") end
  return cam_world
end

local function set_active(n, on)
  if not valid(n) then return end
  local c = n:getcomponent("Camera")
  if c then c.active = on end
end

-- `show` keeps them in view (at a stand there is no console to vanish into:
-- they stand where they were, and the orbit camera sees the spot).
local function park_crew(show)
  local a = astronaut()
  if not a then return end
  local d = space.dominant(a.x, a.y, a.z)
  local b = d and space.body(d)
  if not b then return end
  park = { body = d, x = a.x - b.x, y = a.y - b.y, z = a.z - b.z, show = show == true }
  a.vx, a.vy, a.vz = 0, 0, 0
  a.visible = show == true
end

local function pin_crew()
  local a = astronaut()
  if not (a and park) then return end
  local b = space.body(park.body)
  if not b then return end
  a.x, a.y, a.z = b.x + park.x, b.y + park.y, b.z + park.z
  a.vx, a.vy, a.vz = 0, 0, 0
  if a.visible and not park.show then a.visible = false end
end
-- The parked astronaut (body-relative), for probes and the stand's checks.
function parkPoint() return park end

local function unpark_crew(show)
  local a = astronaut()
  if a then
    pin_crew()
    if show then a.visible = true end
  end
  park = nil
end

local function push_ctx(on)
  if not (input and input.pushContext) then return end
  if on and not ctx_pushed then
    ctx_pushed = pcall(input.pushContext, "builder", { priority = 100, consume = true, enabled = {} })
  elseif not on and ctx_pushed then
    pcall(input.popContext, "builder")
    ctx_pushed = false
  end
end

local function set_owner(o)
  local gm = ref("game_manager")
  if gm then gm.inputOwner = o end
end

-- The BuildFrame under VabInterior. Made fresh on every enter (the last one
-- went with its parts); `cb` runs once it exists.
local function make_frame(cb, parent)
  if valid(frame) then frame:destroy() end
  frame = nil
  createNode("BuildFrame", parent or vab, function(n)
    if not parent then
      n.x, n.y, n.z = 0, FRAME_Y, 0
      n.yaw, n.pitch, n.roll = 0, 0, 0
    end
    frame = n
    cb(n)
  end)
end

-- Take the overlay down and give the world its keys, camera and crew back.
-- `show_crew` false keeps the astronaut hidden (a rollout seats them).
local function teardown(show_crew)
  -- the builder's cursor never outlives it (an RMB fly-look held as the
  -- overlay goes; builder_camera's onDestroy says the same); the world's
  -- cameras assert their own wish next frame
  if input and input.setMouseLocked then input.setMouseLocked(false) end
  if scene and scene.unload then pcall(scene.unload, OVERLAY) end
  if valid(frame) then frame:destroy() end
  frame = nil
  drive_fade(false)
  local bc = find("Builder Camera")
  if valid(bc) then set_active(bc, false) end
  set_active(world_camera(), true)
  push_ctx(false)
  set_owner(nil)
  lean_restore()
  unpark_crew(show_crew)
  building = false
  save_v = nil
end

-- E AT THE VAB. True when the builder is on its way (facility_menu then
-- closes its own panel); false when it can't open here, and facility_menu
-- falls back to the separate builder scene.
local enter_stand
function enter(opts)
  if type(opts) == "table" and opts.stand then return enter_stand(opts.stand) end
  if mode ~= "world" or state ~= "idle" or fx then return false end
  local gm = ref("game_manager")
  if gm and gm.loading then return false end
  hostKind = "vab"
  vab = find("VabInterior")
  if not valid(vab) then
    note("no VabInterior standing — the builder opens as its own scene")
    hostKind = nil
    return false
  end
  enter_t = time
  enterMs = nil
  -- a kit that never found its craft is not carried into the next one
  if type(save.get("shipyard.kit")) == "table" then save.set("shipyard.kit", false) end
  -- The cursor comes into the VAB FREE: the first-person look (or a held
  -- RMB orbit) had it locked, and the camera that locked it stands down
  -- now, so nothing else would ever let go (builder_camera then owns it).
  if input and input.setMouseLocked then input.setMouseLocked(false) end
  set_owner("builder")
  push_ctx(true)
  park_crew()
  state = "frame"
  make_frame(function()
    state = "loading"
    scene.load(OVERLAY, { additive = true, replicate = false })
  end)
  return true
end

function inWorld() return mode == "world" and state ~= "idle" end
function frameNode() if mode == "world" and valid(frame) then return frame end return nil end

-- LEAVE: the builder has saved the craft; take the overlay away. Instant: no
-- loading screen, the astronaut stands where they pressed E.
local leave_stand
function leave()
  if mode ~= "world" or state == "idle" or state == "rollout" then return false end
  if hostKind == "stand" then return leave_stand(false) end
  hostKind = nil
  teardown(true)
  state = "idle"
  local s = ref("sfx")
  if s and s.play then s.play("close") end
  note("left the builder")
  return true
end

-- ═══ THE EDITOR AT A BUILD STAND (work/standeditor/PLAN.md) ════════════════
--
-- enter{ stand = { sid, uid } } is the VAB flow with the frame elsewhere: the
-- BuildFrame is a child of the stand's PLANET, posed every frame from
-- craft_stand.framePose (body frame: the planet only translates), so the
-- whole builder — camera, parts column, inspector, staging, CHECK, symmetry,
-- undo, the library — runs on the deck. Its +X (the builder's craft front)
-- is the stand's front, its +Y the stand's up, and its floor (frame y 0.11)
-- is set so that the craft's BELLY rests on the deck as Commission will seat
-- it: floor = deck top − (belly − lowest) + clear. The deck raises itself as
-- the craft grows (≤ 2 Hz, never during a drag). The astronaut stays in view,
-- pinned where they stood; a hit saves and exits. ESC (with nothing to back
-- out of) or LEAVE saves the work on the stand and charges the DIFF since the
-- last commit (craft_stand.commitQuote: one truck); COMMISSION does the same
-- and then makes it a live, held craft. The VAB's own save keys
-- (shipyard.current / blueprint / lockerPlan / site / kit) are put back
-- exactly as they were.
FLOOR_Y_BUILDER = 0.11
STASH_KEYS = { "shipyard.current", "shipyard.blueprint", "shipyard.lockerPlan", "shipyard.site", "shipyard.kit" }
lastStandExit = nil   -- { quote, paid, ok, why, commission, t } (probes)

local function deepc(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = deepc(v) end
  return o
end
local function agency_now()
  local CS = ref("craft_stand")
  return (CS and CS.agencyNow and CS.agencyNow()) or time or 0
end
local function say(msg)
  note(msg)
  if caption then pcall(caption, msg) end
end

-- The frame on the deck: origin = G + U·(h + clear − fo − 0.11), +Y = U,
-- +X = F (craft_stand.vesselAxes with the builder's front +X).
local function pin_frame()
  if not (stand and valid(frame)) then return end
  local CS = ref("craft_stand")
  local fp = CS and CS.framePose(stand.sid, stand.uid)
  if not fp then return end
  local X, U, Z = CS.vesselAxes(fp.R, fp.U, fp.F, 1, 0)
  local off = fp.h + (stand.clear or 0.02) - (stand.fo or 0) - FLOOR_Y_BUILDER
  frame:setUp(vec3(U.x, U.y, U.z), vec3(-Z.x, -Z.y, -Z.z))
  frame.x, frame.y, frame.z = fp.G.x + U.x * off, fp.G.y + U.y * off, fp.G.z + U.z * off
  stand.h = fp.h
  stand.U, stand.X, stand.Z = U, X, Z
  -- (the camera's floor: 0.3 m over the stand's ground plane, frame y −off)
  local bc = state == "building" and ref("builder_camera") or nil
  if bc and bc.setWorldClip then bc.setWorldClip(true, -off + 0.3) end
end

-- The world the stand stands on, for the builder's launchWorld().
local function stand_world(name)
  local b = name and space.body(name)
  if not b then return nil end
  local r = b.radius or 0
  local mu = b.mu or 0
  local g = (r > 0 and mu > 0) and mu / (r * r) or (b.gravity or 9.8)
  return { name = name, g = g, r = r, soi = (b.soi or 0) > r and b.soi or r * 7.5 }
end

-- THE HOST CONTEXT the builder reads (builder.hostContext()).
-- The stand session as it stands (probes): { sid, uid, h, fo, info, … } | nil
function standState() return stand end
-- The frame's planet-local origin the session wants now (probes compare it).
function standFrameWant()
  if not stand then return nil end
  local CS = ref("craft_stand")
  local fp = CS and CS.framePose(stand.sid, stand.uid)
  if not fp then return nil end
  local off = fp.h + (stand.clear or 0.02) - (stand.fo or 0) - FLOOR_Y_BUILDER
  return { x = fp.G.x + fp.U.x * off, y = fp.G.y + fp.U.y * off, z = fp.G.z + fp.U.z * off, body = fp.body }
end
function standContext()
  if hostKind ~= "stand" or not stand then return nil end
  return stand.ctx
end

enter_stand = function(sp)
  if mode ~= "world" then return false, "the builder isn't in this scene" end
  if state ~= "idle" or fx then return false, "the builder is busy" end
  local gm = ref("game_manager")
  if gm and gm.loading then return false, "still loading" end
  local CS, ST = ref("craft_stand"), ref("structures")
  if not (CS and ST and sp and sp.sid and sp.uid) then return false, "no stand there" end
  local fp = CS.framePose(sp.sid, sp.uid)
  if not fp then return false, "no stand there" end
  local sn = (CS.standNodeOf and CS.standNodeOf(sp.sid, sp.uid)) or ST.nodeOf(sp.sid, sp.uid)
  if not (sn and sn.valid ~= false) then return false, "walk closer" end
  local st = CS.stateOf(sp.sid, sp.uid)
  if st and st.s == "held" then return false, "release the craft first" end
  local planet = find(fp.body)
  if not valid(planet) then return false, "no world there" end
  -- (any VabInterior from an earlier session's frame is not ours)
  vab = nil
  local bp = CS.blueprint(sp.sid, sp.uid)
  local committed = deepc(CS.committedOf(sp.sid, sp.uid))
  local base = 0
  for _, c in pairs(committed) do base = base + (c or 0) end
  local cr = ref("crew")
  local aid = cr and cr.activeId and cr.activeId() or nil
  local lh = cr and cr.lastHit and aid and cr.lastHit[aid]
  stand = { sid = sp.sid, uid = sp.uid, body = fp.body, h0 = fp.h, clear = 0.02, fo = 0,
            stash = {}, committed = committed, baseline = base,
            paid = st and { cost = st.cost or 0, ship = st.ship or 0, total = st.total or 0, t = st.t } or { cost = 0, ship = 0, total = 0 },
            name = (st and st.name) or (bp and bp.name) or string.format("Stand %s craft", tostring(sp.sid)),
            hit0 = lh and lh.t or nil, fit_v = nil, fit_t = -10, info_t = -10, v = 0, info = nil, t0 = time }
  for _, k in ipairs(STASH_KEYS) do stand.stash[k] = { v = deepc(save.get(k)) } end
  local load = bp and deepc(bp) or { parts = {}, v = 2 }
  load.name = stand.name
  save.set("shipyard.blueprint", load)
  save.set("shipyard.current", stand.name)
  save.set("shipyard.lockerPlan", type(load.lockers) == "table" and deepc(load.lockers) or {})
  save.set("shipyard.kit", false)
  local S = stand
  S.ctx = {
    kind = "stand", sid = sp.sid, uid = sp.uid, body = fp.body, world = stand_world(fp.body),
    baseline = base,
    -- what the diff would cost with `delta` more of parts on it (the placement guard)
    afford = function(delta)
      local co, E = ref("company"), ref("base_economy")
      local b = ref("builder")
      local hull = (b and b.build_cost and b.build_cost()) or 0
      local add = math.max(0, hull + (delta or 0) - S.baseline)
      local ship = (add > 0 and E and E.shipping) and E.shipping(add) or 0
      if co and co.afford and not co.afford(add + ship) then
        return false, string.format("can't afford this build — the parts on the stand cost %s with shipping and the budget is %s",
          co.money and co.money(add + ship) or tostring(add + ship), co.money and co.money(co.balance()) or "?")
      end
      return true
    end,
    escape = function() return leave_stand(false) end,
    commission = function() return leave_stand(true) end,
    info = function() return S.info end,
    version = function() return S.v end,
    release = function() return S.info and S.info.wheeled and "roll" or "lift" end,
  }
  CS.setEditing(sp.sid, sp.uid)
  enter_t = time
  enterMs = nil
  hostKind = "stand"
  if input and input.setMouseLocked then input.setMouseLocked(false) end
  set_owner("builder")
  push_ctx(true)
  park_crew(true)
  state = "frame"
  make_frame(function()
    pin_frame()
    state = "loading"
    scene.load(OVERLAY, { additive = true, replicate = false })
  end, planet)
  note(string.format("Build here: stand %s on %s, deck %.1f m", tostring(sp.sid), fp.body, fp.h))
  return true
end

-- The craft's records as craft_orient reads them (the builder's, frame coords).
local function recs_now(b)
  return (b and b.orientRecs and b.orientRecs()) or {}
end

-- THE DECK AND THE SITE, ≤ 2 Hz and only when the craft changed (never during
-- a drag): how far the belly sits over the lowest part (the frame's floor),
-- the deck height the craft needs (raised, never lowered while building), and
-- the stand's CHECK figures (ctx.stand).
local function stand_fit(b)
  if not stand then return end
  local CS, CO = ref("craft_stand"), ref("craft_orient")
  if not (CS and CO) then return end
  if b.editBusy and b.editBusy() then return end
  local v = b.craftVersion
  if v == stand.fit_v and time - stand.info_t < 2.0 then return end
  if time - stand.fit_t < 0.5 then return end
  stand.fit_t = time
  local recs = recs_now(b)
  local rec, p, def = nil, nil, nil
  local ST = ref("structures")
  if ST then rec = ST.get(stand.sid); p = rec and ST.getPart(stand.sid, stand.uid) end
  local pb = ref("parts_base")
  def = pb and p and pb.partInfo(p.id)
  if not def then return end
  local S = def.stand
  local list = {}
  for _, d in pairs(recs) do list[#list + 1] = d end
  local fit = CO.deckFit(list, S, CS)
  local need, why = nil, fit.why
  if #list > 0 and fit.belly then
    need, why = CS.needFor(stand.sid, stand.uid, { parts = list }, astronaut())
  end
  if v ~= stand.fit_v then
    stand.fit_v = v
    local fo = (#list > 0) and CO.floorOffset(list, S, CS) or 0
    if math.abs(fo - (stand.fo or 0)) > 0.005 then stand.fo = fo end
    if need and need > (stand.h or 0) + 1e-6 then
      local ok = CS.setHeight(stand.sid, stand.uid, need)
      if ok then note(string.format("the deck rises to %.1f m for the craft", need)) end
    end
    pin_frame()
  end
  -- the site's figures (ctx.stand), what the CHECK's stand rows read
  stand.info_t = time
  local fp = CS.framePose(stand.sid, stand.uid)
  local info = { body = stand.body, home = save.get("base.body"), h = fp and fp.h, need = need, needWhy = why,
                 deckR = S.deck, wheeled = CS.wheeled({ parts = list }) }
  local w = stand.ctx.world
  info.g = w and w.g
  local wr = save.get("world." .. tostring(stand.body))
  info.air = type(wr) == "table" and wr.atmo or nil
  local hull = 0
  for _, d in ipairs(list) do
    hull = hull + (d.cost or 0)
    if (d.thrust or 0) > 0 then info.thrust = true end
  end
  info.added = math.max(0, hull - stand.baseline)
  info.away = info.home ~= nil and stand.body ~= info.home
  local bb = space.body(stand.body)
  if fp and bb and raycast then
    -- S1: the ground's slope at the stand (a ray past the stand)
    local skip = {}
    local sn = CS.standNodeOf and CS.standNodeOf(stand.sid, stand.uid)
    if sn then skip[#skip + 1] = sn; for _, c in ipairs(sn:children() or {}) do skip[#skip + 1] = c; for _, c2 in ipairs(c:children() or {}) do skip[#skip + 1] = c2 end end end
    local a = astronaut()
    if a then skip[#skip + 1] = a end
    local U, F, R = fp.U, fp.F, fp.R
    local gx, gy, gz = bb.x + fp.G.x, bb.y + fp.G.y, bb.z + fp.G.z
    local okh, h = pcall(raycast, gx + U.x * 6, gy + U.y * 6, gz + U.z * 6, -U.x, -U.y, -U.z, 14, { ignore = skip })
    if okh and h and h.nx then
      local c = h.nx * U.x + h.ny * U.y + h.nz * U.z
      info.slope = math.deg(math.acos(math.max(-1, math.min(1, c))))
      local tx, tz = h.nx * R.x + h.ny * R.y + h.nz * R.z, h.nx * F.x + h.ny * F.y + h.nz * F.z
      if info.slope > 1 then
        local dirs = { "front", "right", "back", "left" }
        local ang = math.atan2(-tx, -tz)
        info.slopeDir = dirs[(math.floor((ang + math.pi / 4) / (math.pi / 2)) % 4) + 1]
      end
    end
    -- S3: the release path ahead (the craft's front is the stand's front)
    if info.wheeled and spherecast then
      local top = fp.h + 0.5
      local ox, oy, oz = gx + U.x * top + F.x * 1.5, gy + U.y * top + F.y * 1.5, gz + U.z * top + F.z * 1.5
      local okc, hc = pcall(spherecast, vec3(ox, oy, oz), vec3(F.x, F.y, F.z), 0.4, 10.0, { ignore = skip })
      if okc and hc and hc.node and hc.distance then
        local nm = hc.node.name
        local _, part = ST.partOfNode(hc.node)
        if part then nm = (pb.partInfo(part.id) or {}).label or nm end
        local terr = false
        pcall(function() terr = hc.node.terrain ~= nil and hc.node.terrain ~= false end)
        if not terr and hc.node.name ~= stand.body then info.front = { name = "the " .. tostring(nm), d = hc.distance + 1.5 } end
      end
    end
    -- S4: anything built within 6 m of a craft that lifts off
    if not info.wheeled and info.thrust then
      for _, e in ipairs(ST.partsNear(stand.body, fp.G.x, fp.G.y, fp.G.z, 6.0)) do
        if not (e.rec.id == stand.sid and e.part.uid == stand.uid) then
          info.plume = { name = "The " .. tostring((pb.partInfo(e.part.id) or {}).label or "structure"), d = e.d }
          break
        end
      end
    end
    -- S5: the Engineer in the craft's box
    if #list > 0 and CS.inTheWay then
      local w2 = CS.inTheWay(stand.sid, stand.uid, { parts = list })
      info.standing = w2 ~= nil and w2:find("you're standing", 1, true) ~= nil
      info.inWay = w2
    end
  end
  local key = string.format("%s|%s|%s|%s|%s|%s", tostring(info.need), tostring(info.standing), tostring(info.front and info.front.name),
    tostring(info.plume and info.plume.name), tostring(info.slope and math.floor(info.slope)), tostring(info.added > 0))
  if key ~= stand.info_key then
    stand.info_key = key
    stand.v = stand.v + 1
    if b.checkRefresh then pcall(b.checkRefresh) end
  end
  stand.info = info
end

-- Save the editor's craft on the stand as it stands (no charge).
stand_autosave = function(b)
  if not stand then return end
  local CS = ref("craft_stand")
  local bp = b.blueprintNow and b.blueprintNow()
  if not (CS and bp) then return end
  CS.saveWip(stand.sid, stand.uid, bp, { committed = stand.committed, paid = stand.paid, name = b.craftName and b.craftName() or stand.name,
    wip = true, noDisplay = true })
end

-- LEAVE / ESC / COMMISSION at a stand: the craft saved on the stand, the
-- diff charged, the VAB's keys back, the world back; `commission` then makes
-- it a live craft. → ok, why
leave_stand = function(commission)
  if not stand then return false, "not at a stand" end
  local S = stand
  local CS, E = ref("craft_stand"), ref("base_economy")
  local b = ref("builder")
  local bp = b and b.blueprintNow and b.blueprintNow() or nil
  local name = (b and b.craftName and b.craftName()) or S.name
  if name == "Untitled" then name = S.name end
  local now = agency_now()
  local q, ok, why = nil, true, nil
  if CS and bp then
    q = CS.commitQuote(S.committed, bp, E, now, S.paid)
    q.name = name
    ok, why = CS.payFor(S.sid, S.uid, q)
    local committed, paid
    if ok then
      committed = q.committed
      local moved = q.total ~= 0 or q.n_add > 0 or q.n_rem > 0
      paid = { cost = q.cost, ship = (S.paid.ship or 0) + q.ship, total = (S.paid.total or 0) + q.total,
               t = moved and now or S.paid.t }
    else
      committed, paid = S.committed, S.paid
    end
    CS.setEditing(nil)
    local wip = (not ok) or (CS.commandWhy(bp) ~= nil)
    local sok = CS.saveWip(S.sid, S.uid, bp, { committed = committed, paid = paid, name = name, wip = wip })
    if not sok then CS.saveWip(S.sid, S.uid, bp, { committed = committed, paid = paid, name = name, wip = true }) end
  elseif CS then
    CS.setEditing(nil)
  end
  -- the VAB's keys, exactly as they were
  for k, e in pairs(S.stash) do
    if e.v == nil then if save.delete then save.delete(k) else save.set(k, false) end else save.set(k, e.v) end
  end
  teardown(true)
  state = "idle"
  hostKind = nil
  stand = nil
  -- the deck's colliders where the deck now is
  local fp = CS and CS.framePose(S.sid, S.uid)
  if fp and math.abs((fp.h or 0) - (S.h0 or 0)) > 1e-6 and CS.respawnStand then CS.respawnStand(S.sid, S.uid) end
  local co = ref("company")
  local m = function(v) return (co and co.money) and co.money(v) or ("$" .. tostring(v)) end
  local msg
  if not ok then msg = "not paid: " .. tostring(why) .. " — it stays on the stand, unfinished"
  elseif q and q.total > 0 then msg = string.format("on the stand · %s charged (%s of parts + %s shipping)", m(q.total), m(q.added), m(q.ship))
  elseif q and q.total < 0 then msg = string.format("on the stand · %s back for the parts taken off", m(-q.total))
  else msg = "on the stand · $0 — nothing changed" end
  local cok, cwhy = nil, nil
  if commission and ok and CS then
    cok, cwhy = CS.commission(S.sid, S.uid)
    msg = cok and (msg .. " · commissioned: held on the stand, Release lets it go") or (msg .. " · not commissioned: " .. tostring(cwhy))
  end
  say(msg)
  lastStandExit = { quote = q, ok = ok, why = why, commission = commission, commissioned = cok, cwhy = cwhy, t = time, sid = S.sid, uid = S.uid }
  local s = ref("sfx")
  if s and s.play then s.play("close") end
  return ok, why
end

-- The overlay has landed at a stand: the builder learns where it is, the
-- camera starts from where the Engineer stood looking at the deck, clipped by
-- the world, and the CHECK tab is up with the stand's rows.
function stand_landed(bcn)
  if not stand then return end
  local bc = ref("builder_camera")
  local CS = ref("craft_stand")
  local fp = CS and CS.framePose(stand.sid, stand.uid)
  if bc and fp then
    if bc.setWorldClip then bc.setWorldClip(true, -((stand.h or fp.h) + 0.02 - (stand.fo or 0) - FLOOR_Y_BUILDER) + 0.3) end
    -- the Engineer's bearing in the frame (+X = F, +Z = −R)
    local a = astronaut()
    local bb = space.body(fp.body)
    local yaw = 0.35
    if a and bb then
      local dx, dy, dz = a.x - bb.x - fp.G.x, a.y - bb.y - fp.G.y, a.z - bb.z - fp.G.z
      local lx = dx * fp.F.x + dy * fp.F.y + dz * fp.F.z
      local lz = -(dx * fp.R.x + dy * fp.R.y + dz * fp.R.z)
      -- builder_camera.viewBasis: forward = (−sin yaw, ·, −cos yaw); the camera
      -- sits behind the pivot, so it looks from (sin yaw, cos yaw)
      -- (a little to one side, so the Engineer is in the picture and not in front of the deck)
      if lx * lx + lz * lz > 0.01 then yaw = math.atan2(lx, lz) + 0.65 end
    end
    if bc.setCamState then bc.setCamState({ P = { x = 0, y = 0.9, z = 0 }, yaw = yaw, pitch = -0.32, d = 6.5 }) end
  end
  local b = ref("builder")
  local CO = ref("craft_orient")
  if b and CO and b.checkHook then b.checkHook("stand", CO.standRules) end
  if b and b.hint then pcall(b.hint, string.format("Build Stand %s  ·  ESC saves and steps back  ·  COMMISSION makes it a craft", tostring(stand.sid)), 5.0) end
  local ins = ref("builder_inspector")
  if ins and ins.setTab then pcall(ins.setTab, "INSPECT") end
end

-- (each frame while building at a stand)
local function stand_tick(dt)
  pin_frame()
  local b = ref("builder")
  if b then stand_fit(b) end
  -- a hit while building: the work is saved and the Engineer is back
  local cr = ref("crew")
  local aid = cr and cr.activeId and cr.activeId() or nil
  local lh = cr and cr.lastHit and aid and cr.lastHit[aid]
  if stand and lh and lh.t ~= stand.hit0 then
    stand.hit0 = lh.t
    note("the Engineer was hit while building (" .. tostring(lh.cause) .. ") — out of the editor")
    leave_stand(false)
    say("you were hit (" .. tostring(lh.cause or "something") .. ") — the work is saved on the stand")
  end
end

-- The full-screen black for the rollout ("Build Host" is a UI node on the
-- HUD layer, drawn over the builder's own layer).
local function fade_box()
  if fade_el then return fade_el end
  fade_el = host and host:getcomponent("UiElement") or nil
  return fade_el
end

local function set_black(a)
  local el = fade_box()
  if not el then return end
  el.opacity = math.max(0, math.min(1, a))
  el.visible = a > 0.001
end

-- WHERE THE CREW WAITS while the craft rolls out: on the launch site, 3 m up
-- (game_manager's launch_site rule), hidden; the craft's controller seats them.
local function crew_to_site(site)
  local bf = ref("base_facilities")
  local st = bf and bf.launchSite and bf.launchSite(site)
  local b = st and space.body(st.body)
  local a = astronaut()
  if not (a and b) then return end
  a.x, a.y, a.z = b.x + st.x + st.up.x * 3.0, b.y + st.y + st.up.y * 3.0, b.z + st.z + st.up.z * 3.0
  a.vx, a.vy, a.vz = 0, 0, 0
  a.visible = false
end

-- LAUNCH. The builder has charged the hull, saved the blueprint and set
-- shipyard.launch / site / pilot as it always did; instead of reloading the
-- world it calls this.
function rollout(site)
  if mode ~= "world" or state ~= "building" then return false end
  site = (site == "runway") and "runway" or "pad"
  save.set("shipyard.site", site)
  save.set("shipyard.pilot", 1)
  ro = { t = time, site = site, phase = "out" }
  state = "rollout"
  note("rolling out to the " .. site)
  return true
end

-- The words on the black while a rollout waits (nil takes them down).
local words_up = nil
local function wait_words(text)
  if text == words_up then return end
  words_up = text
  if not (host and ui and ui.make) then return end
  ui.make(host, text and {
    { "text", key = "wait", pin = "center", w = 900, h = "fit", textAlign = "center", textSize = 22,
      textColor = { 0.74, 0.82, 0.90 }, text = text },
  } or {})
end

local function rollout_tick(dt)
  local f = params.fade or 0.35
  local k = time - ro.t
  if ro.phase == "out" then
    set_black(k / f)
    if k >= f then
      set_black(1)
      teardown(false)
      crew_to_site(ro.site)
      local vs = ref("vessel_spawner")
      local ok, why = false, nil
      -- (the blueprint LAUNCH just stored, as the builder made it: reading
      -- it back out of the save was 10 ms at 1,000 parts)
      local b = ref("builder")
      local lbp = b and b.launchBlueprint and b.launchBlueprint() or nil
      if vs and vs.launchNow then ok, why = vs.launchNow(ro.site, lbp and { bp = lbp } or nil) end
      if not ok and why == "blocked" then
        -- The site is taken (vessel_spawner has said so on screen, refunded
        -- the hull and brought the crew home): fade back in on the world.
        note("the " .. ro.site .. " is blocked — rollout called off")
        save.set("shipyard.kit", false)
        ro.phase, ro.t = "in", time
        return
      end
      if not ok then
        note("vessel_spawner can't launch in place — the old way (a scene load)")
        save.set("shipyard.launch", 1)
        save.flush()
        scene.load("system")
        return
      end
      ro.phase, ro.t = "wait", time
    end
  elseif ro.phase == "wait" then
    set_black(1)
    local vs = ref("vessel_spawner")
    local st = vs and vs.launchState and vs.launchState()
    local seated = false
    for _, v in ipairs(findScripts("vessel_controller")) do
      if v.piloting then seated = true break end
    end
    -- While the spawner is still WAITING for the site (the pad not down, the
    -- runway's ground not final) the black stays up with its words on it:
    -- fading in then showed an empty pad, and the craft that turned up later
    -- could be one assembled over nothing. The spawner calls the launch off
    -- itself (refunded) if the site never comes (SITE_WAIT_BASE at most).
    local hold = params.hold or 8.0
    if st == "waiting" then hold = math.max(hold, (vs.SITE_WAIT_BASE or 90.0) + 5.0) end
    local words = st == "waiting" and k > 1.0 and vs.waitingFor or nil
    wait_words(words)
    if (st == "ready" and seated) or (st == nil and k > 0.2) or k > hold then
      if k > hold then note("the craft took too long — showing it as it stands (" .. tostring(st) .. ")") end
      if st == nil then
        note("the launch was called off — fading back in")
        if not kit_craft_ready() then save.set("shipyard.kit", false) end
      end
      wait_words(nil)
      ro.phase, ro.t = "in", time
    end
  elseif ro.phase == "in" then
    set_black(1 - k / f)
    if k >= f then
      set_black(0)
      ro = nil
      state = "idle"
      note("rolled out")
    end
  end
end

-- THE KIT (docs/crew-and-items.md §5.6; the CREW tab's BUY ▸ on a storage
-- part). LAUNCH leaves `shipyard.kit` = { lockers = { ["<uid>"] = { [item] = n } },
-- holds = { ["<uid>"] = true } } — what each Stowage Locker or Cargo Bay of the
-- blueprint carries. When the craft has come out (its controller has numbered
-- its lockers, vessel_controller.lockerRegister) each item goes in: from the
-- base stock while it has one, bought at the shop price (inventory.buyItem,
-- which charges) for the rest. A launch called off clears it, so nothing is
-- charged for a craft that never flew. Published: kitFill(vc, kit) → loaded,
-- bought, spent, lines (probes), lastKit (what the last fill did).
lastKit = nil
local kit_seen = nil
function kitFill(vc, kit)
  local inv = ref("inventory")
  if not (inv and vc and type(kit) == "table" and type(kit.lockers) == "table") then return 0, 0, 0, {} end
  local loaded, bought, spent, lines = 0, 0, 0, {}
  local keys = {}
  for k in pairs(kit.lockers) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
  for _, k in ipairs(keys) do
    local uid = tonumber(k)
    local cid = uid and vc.lockerOf and vc.lockerOf(uid) or nil
    if not cid and type(kit.holds) == "table" and kit.holds[k] then cid = vc.holdId end
    if cid then
      local ids = {}
      for id in pairs(kit.lockers[k]) do ids[#ids + 1] = id end
      table.sort(ids)
      for _, id in ipairs(ids) do
        local n = math.floor(tonumber(kit.lockers[k][id]) or 0)
        local took = 0
        if n > 0 then
          local have = inv.itemCount("base", id) or 0
          if have > 0 then took = inv.moveItem("base", cid, id, math.min(have, n)) or 0 end
          local rest = n - took
          if rest > 0 then
            local ok, why = inv.buyItem(cid, id, rest)
            if ok then
              bought = bought + rest
              local I = ref("items")
              local d = I and I.def and I.def(id)
              spent = spent + rest * ((d and d.cost) or 0)
              took = took + rest
            else
              lines[#lines + 1] = string.format("%s: %d %s not loaded (%s)", cid, rest, id, tostring(why))
            end
          end
          loaded = loaded + took
          lines[#lines + 1] = string.format("%s ← %d %s", cid, took, id)
        end
      end
    else
      lines[#lines + 1] = "no storage for part " .. tostring(k) .. " on the craft"
    end
  end
  if vc.holdApplyMass then pcall(vc.holdApplyMass, vc.node) end
  lastKit = { loaded = loaded, bought = bought, spent = spent, lines = lines }
  return loaded, bought, spent, lines
end

-- The craft just launched — still on its launch spot (vessel_controller's
-- `leftPad` is false only for a craft rolled out and not yet gone; a parked
-- or restored craft has left it by definition) and whose storage has every
-- planned part: the one being flown first, else a probe nobody rides.
local function kit_craft(kit)
  local list = findScripts and findScripts("vessel_controller") or {}
  local function fits(v)
    if not v.lockerOf then return false end
    for k in pairs(kit.lockers) do
      local held = type(kit.holds) == "table" and kit.holds[k]
      if held then if not v.holdId then return false end
      elseif not v.lockerOf(tonumber(k)) then return false end
    end
    return true
  end
  for _, v in ipairs(list) do if v.leftPad == false and v.piloting and fits(v) then return v end end
  for _, v in ipairs(list) do if v.leftPad == false and fits(v) then return v end end
  return nil
end

local function kit_tick()
  local kit = save.get("shipyard.kit")
  if type(kit) ~= "table" or type(kit.lockers) ~= "table" then kit_seen = nil return end
  if state == "rollout" and ro and ro.phase == "out" then return end
  kit_seen = kit_seen or time
  local vc = kit_craft(kit)
  if not vc then
    if time - kit_seen > 90 then
      note("the kit found no craft to go into — it stays in the stock")
      save.set("shipyard.kit", false)
      kit_seen = nil
    end
    return
  end
  save.set("shipyard.kit", false)
  kit_seen = nil
  local loaded, bought, spent = kitFill(vc, kit)
  local co = ref("company")
  local msg = string.format("kit loaded: %d item%s%s", loaded, loaded == 1 and "" or "s",
    bought > 0 and string.format(" (%d bought, %s)", bought, (co and co.money) and co.money(spent) or ("$" .. spent)) or "")
  note(msg)
  local wc = ref("warp_chip")
  if wc and wc.say then pcall(wc.say, msg) end
end

-- FADE THROUGH BLACK, for anyone (a revert to launch): fadeThrough(atBlack
-- [, ready]) fades to black over `fade` s, calls atBlack() there, holds
-- until ready() is true (at most `hold` s; no ready = at once) and fades
-- back in. The rollout's own black, so the world is never seen being moved.
-- false when this host can't (not the world's, or a builder / rollout /
-- fade is under way): do the thing without the fade.
function fadeThrough(atBlack, ready)
  if mode ~= "world" or state ~= "idle" or fx or type(atBlack) ~= "function" then return false end
  fx = { t = time, phase = "out", atBlack = atBlack, ready = ready }
  return true
end
function fading() return fx ~= nil end

local function fx_tick()
  local f = params.fade or 0.35
  local k = time - fx.t
  if fx.phase == "out" then
    set_black(k / f)
    if k >= f then
      set_black(1)
      local ok, err = pcall(fx.atBlack)
      if not ok then note("fade: the work at black failed: " .. tostring(err)) end
      fx.phase, fx.t = "wait", time
    end
  elseif fx.phase == "wait" then
    set_black(1)
    local done = true
    if fx.ready then
      local ok, r = pcall(fx.ready)
      done = not ok or r == true
    end
    if done or k > (params.hold or 8.0) then
      if not done then note("fade: still not ready — fading in anyway") end
      fx.phase, fx.t = "in", time
    end
  else
    set_black(1 - k / f)
    if k >= f then set_black(0) fx = nil end
  end
end

-- ── the hooks ────────────────────────────────────────────────────────────────

function start(node)
  host = node
  -- The world host is the one with a game manager beside it.
  -- (by node name: a findScript that finds nothing is a console warning)
  if find("Game Manager") or find("Base Facilities") then
    mode = "world"
    set_black(0)
  else
    mode = "standalone"
    building = true
    -- the crew library (crew.lua: the roster the loadout reads); in the
    -- world scene game_manager spawns it
    if not find("CrewLib") and spawn then pcall(spawn, "CrewLib", vec3(0, 0, 0)) end
    standalone_start()
  end
end

-- the scene goes: the session's pictures with it (see release_tex)
function onDestroy()
  for id, t in pairs(part_icons) do release_tex(t); part_icons[id] = nil end
  for id, e in pairs(crew_portraits) do release_tex(e.tex); crew_portraits[id] = nil end
end

function kit_craft_ready()
  local kit = save.get("shipyard.kit")
  return type(kit) == "table" and type(kit.lockers) == "table" and kit_craft(kit) ~= nil
end

function update(node, dt)
  if mode == "world" and (state == "idle" or state == "rollout") then kit_tick() end
  if mode == "standalone" then
    if not valid(vab) then vab = find("VabInterior") end
    if valid(vab) then drive_fade(true) end
    return
  end
  if state == "idle" then
    if fx then fx_tick() end
    return
  end
  if state == "rollout" then
    if ro then rollout_tick(dt) end
    return
  end
  pin_crew()
  if hostKind == "stand" then stand_tick(dt) if state == "idle" then return end end
  if state == "loading" then
    -- The overlay is in once its builder node is: hand it the view.
    local bn = find("Builder")
    local bc = find("Builder Camera")
    if valid(bn) and valid(bc) then
      -- (a Camera component's `active = true` does not clear the other
      -- camera's on rc6: both read active and the world's camera kept the
      -- view, parked in space while the planet moved on. Off first.)
      set_active(world_camera(), false)
      set_active(bc, true)
      state = "building"
      building = true
      lean_apply()
      enterMs = (time - enter_t) * 1000
      if hostKind == "stand" then stand_landed(bc) end
      note(string.format("building %s (%.0f ms from E)", hostKind == "stand" and "at a Build Stand" or "in the VAB", enterMs))
    elseif time - enter_t > 5.0 then
      note("the builder overlay never arrived — back to the world")
      if hostKind == "stand" then leave_stand(false) else teardown(true) end
      state = "idle"
    end
    return
  end
  if state == "building" then
    -- The overlay went away under us (unloaded by someone else): clean up.
    local bn = find("Builder")
    if not valid(bn) then
      if hostKind == "stand" then leave_stand(false) else teardown(true) end
      state = "idle"
      return
    end
    -- (the builder camera keeps the view; another camera taking it back
    -- would leave the player looking at the parked crew)
    local bc = find("Builder Camera")
    local c = bc and bc:getcomponent("Camera")
    if c and c.active ~= true and c.active ~= 1 then set_active(world_camera(), false); c.active = true end
    autosave_tick()
  end
end

function lateUpdate(node, dt)
  if mode == "world" and state == "building" then drive_fade(true) end
end
