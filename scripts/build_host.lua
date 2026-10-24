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
-- fadeThrough(atBlack [, ready]), fading().

defaults = {
  fade = 0.35,        -- seconds to black (and back) round a rollout
  hold = 8.0,         -- the most a rollout waits at black for the craft
  autosave = 2.0,     -- seconds a changed craft must sit still before it is saved
}

OVERLAY = "builder_overlay"
FRAME_Y = 2.73        -- VabBuildPoint (2.84 over the slab centre) − the builder's floor_y 0.11
STANDALONE_Y = -2.73  -- the VAB's origin in builder.ron: the deck top lands on y = 0.11

building = false      -- the overlay is up (world) / the stand is up (standalone)
mode = nil            -- "world" | "standalone"
state = "idle"        -- idle · frame · loading · building · rollout
enterMs = nil         -- E to the builder's first frame, ms (probes)

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

-- The vab_fade controller on VabInterior's root.
local function fader() return ref("vab_fade") end

-- Feed the fade the craft: its box from the builder camera (frame-local),
-- turned into the world through the frame (the identity in standalone).
local function drive_fade(on)
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
    pcall(b.craftSave, name, true)
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

local function park_crew()
  local a = astronaut()
  if not a then return end
  local d = space.dominant(a.x, a.y, a.z)
  local b = d and space.body(d)
  if not b then return end
  park = { body = d, x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }
  a.vx, a.vy, a.vz = 0, 0, 0
  a.visible = false
end

local function pin_crew()
  local a = astronaut()
  if not (a and park) then return end
  local b = space.body(park.body)
  if not b then return end
  a.x, a.y, a.z = b.x + park.x, b.y + park.y, b.z + park.z
  a.vx, a.vy, a.vz = 0, 0, 0
  if a.visible then a.visible = false end
end

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
local function make_frame(cb)
  if valid(frame) then frame:destroy() end
  frame = nil
  createNode("BuildFrame", vab, function(n)
    n.x, n.y, n.z = 0, FRAME_Y, 0
    n.yaw, n.pitch, n.roll = 0, 0, 0
    frame = n
    cb(n)
  end)
end

-- Take the overlay down and give the world its keys, camera and crew back.
-- `show_crew` false keeps the astronaut hidden (a rollout seats them).
local function teardown(show_crew)
  if scene and scene.unload then pcall(scene.unload, OVERLAY) end
  if valid(frame) then frame:destroy() end
  frame = nil
  drive_fade(false)
  local bc = find("Builder Camera")
  if valid(bc) then set_active(bc, false) end
  set_active(world_camera(), true)
  push_ctx(false)
  set_owner(nil)
  unpark_crew(show_crew)
  building = false
  save_v = nil
end

-- E AT THE VAB. True when the builder is on its way (facility_menu then
-- closes its own panel); false when it can't open here, and facility_menu
-- falls back to the separate builder scene.
function enter()
  if mode ~= "world" or state ~= "idle" or fx then return false end
  local gm = ref("game_manager")
  if gm and gm.loading then return false end
  vab = find("VabInterior")
  if not valid(vab) then
    note("no VabInterior standing — the builder opens as its own scene")
    return false
  end
  enter_t = time
  enterMs = nil
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
function leave()
  if mode ~= "world" or state == "idle" or state == "rollout" then return false end
  teardown(true)
  state = "idle"
  local s = ref("sfx")
  if s and s.play then s.play("close") end
  note("left the builder")
  return true
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
      if vs and vs.launchNow then ok, why = vs.launchNow(ro.site) end
      if not ok and why == "blocked" then
        -- The site is taken (vessel_spawner has said so on screen, refunded
        -- the hull and brought the crew home): fade back in on the world.
        note("the " .. ro.site .. " is blocked — rollout called off")
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
    if (st == "ready" and seated) or k > (params.hold or 8.0) then
      if k > (params.hold or 8.0) then note("the craft took too long — showing it as it stands (" .. tostring(st) .. ")") end
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
    standalone_start()
  end
end

function update(node, dt)
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
      enterMs = (time - enter_t) * 1000
      note(string.format("building in the VAB (%.0f ms from E)", enterMs))
    elseif time - enter_t > 5.0 then
      note("the builder overlay never arrived — back to the world")
      teardown(true)
      state = "idle"
    end
    return
  end
  if state == "building" then
    -- The overlay went away under us (unloaded by someone else): clean up.
    local bn = find("Builder")
    if not valid(bn) then
      teardown(true)
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
