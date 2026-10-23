-- UI PROBE — opens one screen of the system scene so `floptle shot` can
-- photograph it at every resolution.
--
-- A TEST FIXTURE, like fps_probe: `scenes/ui_probe.ron` is the only thing that
-- names it. It creates save slot 9 (wiping its terrain), loads the system, rides
-- the swap, and once the crew is on foot stocks the pack and the account with
-- representative numbers and opens the screen named by the `panel` string:
--
--   none  pause  controls  settings  ops  inventory  map  prompt  debug
--   toast  fac:FacCommand  fac:FacDepot  fac:FacTracking  fac:FacHangar
--   flight  flightperiph  flightmap   (a small rocket is launched and flown)
--   cine  freecam                     (cinematic mode: interface hidden / free camera)
--
-- `uiScale` sets the interface size first (settings.lua; 0 leaves Auto).
-- `traj` puts the flown rocket on a path before "flightmap" opens the map:
-- "orbit" (a circular orbit 0.6 radii up), "sub" (a suborbital hop),
-- and `release = 1` then lets go of the controls, so the craft is drawn as an
-- unflown one (dimmed) and the map is centred on the crew.

defaults = {
  slot = 9,
  seed = 1911564384,
  --- Seconds on foot before the screen is opened.
  openAfter = 4.0,
  --- Accept a contract first (so the goal lines have something to show).
  contract = 1,
  --- Seconds to post-date a "toast" notice by, so it is still up at the shot.
  toastLead = 6,
  --- Which screen to open (see the list above).
  panel = "none",
  --- Seconds between frame-cost reports once the screen is open (0 = none).
  perfEvery = 0,
  --- With the map open: sweep its zoom out to 3,000 km and back, the way a
  --- player scrolling around it does, so the reports show what zooming costs.
  zoomSweep = 0,
  --- Quit this many seconds after the screen opened (0 = never; for `play`).
  quitAfter = 0,
  --- Interface size to set before opening (0 = leave it on Auto).
  uiScale = 0,
  --- flightmap: let go of the controls after placing the craft (dimmed track).
  release = 0,
  --- freecam: fly the free camera up this many metres per second (a drift check).
  freeRise = 0,
  --- flightmap with `traj`: place the craft on this frame of the whole run
  --- (0 = a second after the crew is aboard), so `shot --after` can catch a
  --- short suborbital arc in the air. The map opens 60 frames later.
  atFrame = 0,
  --- map / flightmap: hold the view this many metres from the focus (0 = auto-fit).
  mapZoom = 0,
}

local jumped, ready_t, opened = false, nil, false
local opened_t, report_t = nil, 0
local frames, acc, worst = 0, 0, 0

-- Frame cost since the last report: fps, the engine's buckets and the scripts
-- that cost most — the map's own line among them.
local function report()
  local b = {}
  for _, k in ipairs(perf.buckets()) do
    local v = perf.ms(k)
    if v > 0.05 then b[#b + 1] = string.format("%s=%.1f/%.1f", k, v, perf.worstMs(k)) end
  end
  local top = {}
  for i, s in ipairs(perf.scripts()) do
    if i > 4 then break end
    top[#top + 1] = string.format("%s=%.2f", s.name, s.ms)
  end
  print(string.format("ui probe @%.0fs: %.0f fps (worst %.0f ms) | %s | %s | chunks=%d",
    time - opened_t, frames / math.max(acc, 1e-6), worst * 1000,
    table.concat(b, " "), table.concat(top, " "), (perf.counts().chunks or 0)))
  frames, acc, worst = 0, 0, 0
end
local relaunched = false

local function flying_mode() return (params.panel or ""):sub(1, 6) == "flight" end

-- The smoke_vessel test rocket, minus the side booster: pod, tank, decoupler,
-- engine, legs and a chute, so every HUD block has something to show.
local BLUEPRINT = { parts = {
  { uid = 1, id = "pod", prefab = "PartPod", x = 0, y = 3.0, z = 0, yaw = 0,
    h = 0.8, mass = 1.2, cost = 400, kind = "crewed", thrust = 0, burn = 0, fuel = 0, decouple = 0, legs = 0 },
  { uid = 2, id = "tankS", prefab = "PartTankS", x = 0, y = 2.1, z = 0, yaw = 0, parent = 1,
    h = 1.0, mass = 1.5, cost = 120, kind = "tank", thrust = 0, burn = 0, fuel = 60, decouple = 0, legs = 0 },
  { uid = 3, id = "decoupler", prefab = "PartDecoupler", x = 0, y = 1.47, z = 0, yaw = 0, parent = 2,
    h = 0.25, mass = 0.15, cost = 60, kind = "structural", thrust = 0, burn = 0, fuel = 0, decouple = 1, legs = 0 },
  { uid = 4, id = "engineS", prefab = "PartEngineS", x = 0, y = 0.65, z = 0, yaw = 0, parent = 3,
    h = 1.3, mass = 0.8, cost = 150, kind = "engine", thrust = 55, burn = 0.9, fuel = 0, decouple = 0, legs = 0 },
  { uid = 8, id = "legs", prefab = "PartLegs", x = 0, y = 0.65, z = 0.8, yaw = 0, parent = 2,
    h = 0.7, mass = 0.3, cost = 90, kind = "structural", thrust = 0, burn = 0, fuel = 0, decouple = 0, legs = 1 },
  { uid = 9, id = "chute", prefab = "PartChute", x = 0, y = 3.57, z = 0, yaw = 0, parent = 1,
    h = 0.34, rx = 0.22, rz = 0.22, mass = 0.1, cost = 80, kind = "canvas", thrust = 0, burn = 0, fuel = 0, decouple = 0, legs = 0, chute = 1 },
} }

local function piloted()
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.piloting then return v end
  end
  return nil
end

-- ── trajectory fixtures ──────────────────────────────────────────────────────
-- The flown rocket, off its clamps and moved onto a path about the world it
-- is on: 0.6 radii up at circular speed ("orbit"), or 0.3 radii up going
-- 0.6 and 0.15 of circular speed along and up ("sub": it comes down a
-- quarter of the way round the world, half a minute later). Position by teleport, velocity by one impulse
-- (the craft's velocity is in the world's carried frame, so it is relative).
local placed, released_ctl = false, false
local push = nil      -- { node, want (relative velocity), body } while it is being given
function place_on_path(kind)
  local v = piloted()
  if not v then return end
  if v.releaseClamps then v.releaseClamps() end
  local info = assembly.info(v.node)
  if not info or info.anchored then return end
  local o = info.origin
  local d = space.dominant(o.x, o.y, o.z)
  local b = d and space.body(d)
  if not b then return end
  local up = vec3(o.x - b.x, o.y - b.y, o.z - b.z):normalized()
  local east = up:cross(vec3(0, 1, 0))
  if east:length() < 1e-3 then east = up:cross(vec3(1, 0, 0)) end
  east = east:normalized()
  -- Sized from the world (Solar's are small: a kilometre or so across).
  local r = kind == "orbit" and b.radius * 1.6 or b.radius * 1.3
  if b.soi and b.soi > 0 then r = math.min(r, b.soi * 0.5) end
  assembly.teleport(v.node, vec3(b.x, b.y, b.z) + up * r)
  local vc = math.sqrt(b.mu / r)
  local want = kind == "orbit" and east * vc or (east * (vc * 0.6) + up * (vc * 0.15))
  push = { node = v.node, want = want, body = d, t0 = time }
  placed = true
  print(string.format("ui probe: placed on a %s path, %.0f m up, giving it %.1f m/s (body %s, R %.0f m, SOI %.0f m)",
    kind, r - b.radius, want:length(), d, b.radius, b.soi or -1))
end

-- The velocity goes in a few m/s a tick, at the centre of mass where the craft
-- IS now: the vessel's safety clamp takes back more than it could have gained
-- in one tick, and an impulse at last frame's centre of mass is a spin.
function push_tick()
  -- Not on the teleport's own frame: the new place is read from the next pass.
  if not push or time - push.t0 < 0.1 then return end
  local info = push.node.valid and assembly.info(push.node)
  if not info then push = nil return end
  local have = vec3(info.vel.x, info.vel.y, info.vel.z)
  local dv = push.want - have
  if dv:length() < 0.3 then
    print(string.format("ui probe: on the path at %.1f m/s", have:length()))
    push = nil
    return
  end
  if dv:length() > 4.0 then dv = dv:normalized() * 4.0 end
  assembly.impulseAt(push.node, dv * info.mass, info.com)
end

-- The free camera, watched: where it sits from the world's centre, each
-- second (it must not drift as the world moves on its rails), and — with
-- `freeRise` — moved up at that rate, the way W or SPACE would move it.
local fw_t = 0
function freecam_watch(dt, since)
  if (params.panel or "") ~= "freecam" then return end
  local pc = findScript("planet_camera")
  local fc = pc and pc.freecamState and pc.freecamState()
  if not fc then return end
  if (params.freeRise or 0) ~= 0 and since < 6 then
    fc.rel = fc.rel + fc.rel:normalized() * (params.freeRise * dt)
  end
  if since > 7 and not shot_taken and pc.takeScreenshot then
    shot_taken = true
    pc.takeScreenshot()
  end
  if time - fw_t >= 1.0 then
    fw_t = time
    local b = space.body(fc.body or "")
    local cam = pc.node
    if b and cam then
      local rel = vec3(cam.x - b.x, cam.y - b.y, cam.z - b.z)
      print(string.format("ui probe: freecam %.1fs  |rel| %.2f  rel (%.2f %.2f %.2f)  body at (%.0f %.0f %.0f)  cinematic %s",
        since, rel:length(), rel.x, rel.y, rel.z, b.x, b.y, b.z, tostring(pc.cinematic)))
    end
  end
end

local function stock()
  local inv, co, mi = findScript("inventory"), findScript("company"), findScript("missions")
  if co and co.earn and co.balance() < 12000 then co.earn(12000 - co.balance(), "probe") end
  if inv and inv.add then
    inv.clear("astro")
    inv.add("astro", "iron", 6)
    inv.add("astro", "regolith", 9)
    inv.add("astro", "crystal", 2)
    inv.add("astro", "resin", 3)
  end
  if mi and mi.accept and (params.contract or 0) > 0 and not mi.active then
    local offers = mi.offers()
    if offers[1] then mi.accept(offers[1].id) end
  end
end

-- Panels close when the crew walks off (facility_menu `beyond`), so a probe
-- that opens one stands the crew at the building first.
local function stand_at(fac)
  local f, a = find(fac), find("Astronaut")
  if f and a and f.worldX then a.x, a.y, a.z = f.worldX, f.worldY, f.worldZ end
end

local function open(which)
  print(string.format("ui probe: opening %s at %.1fs", which, time))
  if which == "pause" then
    findScript("pause_menu").openMenu()
  elseif which == "controls" or which == "settings" then
    local pm = findScript("pause_menu")
    pm.openMenu()
    pm.showPage(which)
  elseif which == "toast" then
    local gx = findScript("graphics")
    gx.notice = "Graphics lowered from High to Medium to keep the game smooth. Change it in Settings (ESC)."
    -- Stamped on the graphics script's own clock, which is the one the toast
    -- compares against.
    gx.noticeAt = (gx.time or time) + (params.toastLead or 0)
    print(string.format("ui probe: notice set (probe t=%.1f, graphics t=%s)", time, tostring(gx.time)))
  elseif which == "ops" then
    stand_at("FacCommand")
    findScript("ops_board").openBoard()
  elseif which == "inventory" then
    findScript("inventory_panel").open = true
  elseif which == "flightperiph" then
    findScript("peripheral_panel").openPanel()
  elseif which == "map" or which == "flightmap" then
    findScript("orbit_map").toggle()
  elseif which == "cine" then
    findScript("planet_camera").setCinematic(true)
  elseif which == "freecam" then
    findScript("planet_camera").setFreecam(true)
  elseif which == "debug" then
    save.set("debug.rich", true)
  elseif which == "prompt" then
    local f, a = find("FacCommand"), find("Astronaut")
    if f and a and f.worldX then
      a.x, a.y, a.z = f.worldX, f.worldY, f.worldZ
    end
  elseif which:sub(1, 4) == "fac:" then
    stand_at(which:sub(5))
    findScript("facility_menu").openMenu(which:sub(5))
  end
end

local frame_n = 0
function update(node, dt)
  frame_n = frame_n + 1
  if not jumped then
    jumped = true
    local s = "slot" .. math.floor(params.slot or 9)
    terrain.deleteSaveDir("saves/" .. s .. "/terrain")
    save.slot(s)
    save.set("g_seed", math.floor(params.seed or 1911564384))
    node.persistent = true
    print("ui probe: created " .. s .. ", loading the system…")
    scene.load("system")
    return
  end
  if opened then
    frames, acc, worst = frames + 1, acc + dt, math.max(worst, dt)
    local since = time - opened_t
    freecam_watch(dt, since)
    if (params.mapZoom or 0) > 0 then
      local map = findScript("orbit_map")
      if map and map.setZoom then map.setZoom(params.mapZoom) end
    end
    if (params.zoomSweep or 0) > 0 then
      -- 300 m → 3,000 km over 12 s, and back over the next 12.
      local u = math.min(1, since / 12)
      if since > 12 then u = math.max(0, 1 - (since - 12) / 12) end
      local map = findScript("orbit_map")
      if map and map.setZoom then map.setZoom(300 * 10000 ^ u) end
    end
    if (params.perfEvery or 0) > 0 and time - report_t >= params.perfEvery then
      report_t = time
      report()
    end
    if (params.quitAfter or 0) > 0 and since > params.quitAfter then app.quit() end
    return
  end
  local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
  -- Flight: walk the new save in first (a launch into a world that has never
  -- been generated waits on terrain nobody is near), then launch into it.
  if flying_mode() and not relaunched and pw and pw.onFoot and bf and bf.sited
     and not (gm and gm.loading) then
    relaunched = true
    save.set("shipyard.blueprint", BLUEPRINT)
    save.set("shipyard.launch", 1)
    save.set("shipyard.pilot", 1)
    print("ui probe: base is up — launching")
    scene.load("system")
    return
  end
  local here
  if flying_mode() then here = relaunched and piloted() ~= nil else here = pw and pw.onFoot end
  if not here or (gm and gm.loading) or not (bf and bf.sited) then
    ready_t = nil
    return
  end
  if not ready_t then
    ready_t = time
    print(string.format("ui probe: on foot at %.1fs", time))
    stock()
    if (params.uiScale or 0) > 0 then
      local st = findScript("settings")
      if st then st.set("ui_scale", params.uiScale) end
      print(string.format("ui probe: interface size %.0f%%", params.uiScale * 100))
    end
    return
  end
  if time - ready_t < (params.openAfter or 4.0) then
    if flying_mode() and (params.traj or "") ~= "" and not placed and time - ready_t > 1.0
       and (params.atFrame or 0) <= 0 then
      place_on_path(params.traj)
    end
    push_tick()
    return
  end
  if (params.atFrame or 0) > 0 then
    if not placed then
      if frame_n >= params.atFrame then place_on_path(params.traj) placed_frame = frame_n end
      return
    end
    push_tick()
    if frame_n < (placed_frame or 0) + 60 then return end
  end
  if params.release == 1 and not released_ctl then
    released_ctl = true
    local v = piloted()
    if v then v.releaseControl(); print("ui probe: let go of the controls") end
  end
  opened = true
  opened_t, report_t = time, time
  if (params.perfEvery or 0) > 0 then perf.enable(true) end
  open(params.panel or "none")
end
