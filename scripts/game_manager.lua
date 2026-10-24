-- GAME MANAGER — the save-slot player flow (main menu → slot → loading → play).
--
-- The menu scene picks a save slot (save.slot("slotN")) and loads this scene.
-- On start, if a slot is active, this script:
--   1. points terrain persistence at the slot (terrain.saveDir) — digs persist
--      per slot, and previously visited worlds reload from fast slot files,
--   2. reads the slot's galaxy seed (rolling + storing one on first play),
--   3. shows the LOADING overlay and regenerates the whole system from that
--      seed (deterministic — the same slot always gets the same galaxy),
--   4. holds the player safely above the spawn planet until its terrain is
--      actually solid (terrain.query at the surface), then places them —
--      at their saved position if the slot has one, else at the north pole,
--   5. autosaves (position + terrain flush) every few seconds and on the
--      HUD's ☰ MENU button, which returns to the main menu.
--
-- Played DIRECTLY in the editor (no slot selected — save.slot() == "main"),
-- it does nothing: the authored scene behaves exactly as before.

defaults = {
  autosave = 12.0, -- seconds between checkpoint saves
}

-- Published: the menu button + other scripts read/act on these.
loading = false
-- Is the loading curtain still up (true from the start of a slot's load to
-- the end of the reveal)? base_facilities grades the spaceport's ground
-- flat out behind it, and gently once the world can be seen.
curtain = false
-- WHO HAS THE KEYS. nil = the world (the walker, the belt, the camera, the
-- pause menu, the map). "builder" while the craft builder runs in the real VAB
-- over this scene (scripts/build_host.lua sets and clears it): the world's
-- scripts that read raw keys stand down — W walks nothing, M opens no map, Esc
-- never pauses — and the builder's own scripts take them.
inputOwner = nil

local gen, overlay, overlay_text
local slot = nil
-- Is this the first entry into this save? The same fact `pregen` is decided
-- from, kept because the loading screen has to say so and `g_played` is written
-- before the screen goes away.
local first_load = false
local seed = 0
local spawn_x, spawn_y, spawn_z, spawn_r = 0, 0, 0, 0
local spawn_body = nil
local next_save = 0
local load_t = 0
-- The overlay comes down once the world is live AND the colony stands, or at
-- `reveal_by` whichever is first (see the ready branch in update).
local revealing = false
local reveal_by = nil
local ready_t = nil

local function ui_of(name)
  local n = find(name)
  return n, n and n:getcomponent("UiElement")
end

-- Position saved RELATIVE to the dominant body: absolute coordinates go stale
-- (orbital phases restart with the sim clock), but "standing here on Golil"
-- doesn't. Restores place the node at the body's LIVE position + the offset.
local function save_pos_of(node, prefix)
  local d = space.dominant(node.x, node.y, node.z)
  local b = d and space.body(d)
  if not b then return end
  save.set(prefix .. "_body", d)
  save.set(prefix .. "_x", node.x - b.x)
  save.set(prefix .. "_y", node.y - b.y)
  save.set(prefix .. "_z", node.z - b.z)
end

local function restore_pos_of(node, prefix)
  local bodyname = save.get(prefix .. "_body")
  if not bodyname then return false end
  local b = space.body(bodyname)
  if not b then return false end
  node.x = b.x + (save.get(prefix .. "_x") or 0)
  node.y = b.y + (save.get(prefix .. "_y") or 0)
  node.z = b.z + (save.get(prefix .. "_z") or 0)
  node.vx, node.vy, node.vz = 0, 0, 0
  return true
end

-- The full checkpoint: where the crew is standing and every dug field → the slot.
function saveGame()
  if not slot then return end
  local astro = find("Astronaut")
  if astro then save_pos_of(astro, "p") end
  save.set("g_played", (save.get("g_played") or 0) + 1)
  terrain.flush()
end

-- The ☰ MENU button calls this through a script handle.
function exitToMenu()
  saveGame()
  scene.load("menu")
end

-- THE SAVE'S WORLD SCALE (system_generator SCALES): written once, when a save
-- first enters play, and never again — a world keeps the size it was made at.
--
-- The new-save panel writes it on CREATE. A slot without one is either from
-- before scale versions existed — it has played, or has a base, a fleet, a
-- frozen parts catalogue — and is version 1, or it is genuinely fresh (a probe
-- or a tool that only stored a seed) and gets the current scale.
function worldScale()
  local v = save.get("g_scale")
  if v then return v end
  local gen = findScript("system_generator")
  local current = (gen and gen.CURRENT_SCALE) or 3
  local old = save.get("g_played") ~= nil or save.get("base.body") ~= nil
    or save.get("parts.rating") ~= nil or save.get("fleet.next") ~= nil
    or save.get("system.home") ~= nil
  v = old and 1 or current
  save.set("g_scale", v)
  return v
end

function start(node)
  local s = save.slot()
  if s == "main" then return end -- direct editor play: stay out of the way
  slot = s
  terrain.saveDir("saves/" .. slot .. "/terrain")
  gen = findScript("system_generator")
  if not gen then
    print("game_manager: no System Generator in the scene — slot flow disabled")
    slot = nil
    return
  end
  seed = save.get("g_seed") or 0
  loading = true
  curtain = true
  load_t = time
  -- Nothing simulates until the world is actually there: physics is paused
  -- for the whole loading screen (scripts, rails and terrain streaming keep
  -- running), so nothing can fall through half-streamed terrain or get
  -- ejected before the ground exists. Resumed when the crew is placed.
  physics.pause(true)
  for _, nm in ipairs({ "Loading Screen", "Loading Text" }) do
    local _, el = ui_of(nm)
    if el then el.visible = true end
  end
  -- A save whose spaceport is already sited has made its spawn world and
  -- graded it, even if it never reached a checkpoint (`g_played`): a scene
  -- change flushes the slot's terrain, so the ground streams back from there.
  -- Generating it again from the seed threw the grade away while the base
  -- (its grade recorded) stood on it: the runway came back 1-1.7 m out of true
  -- (perfbench: launch from the standalone builder 20 s into a new save).
  first_load = save.get("g_played") == nil and save.get("base.body") == nil
  -- The world is made once the heavy shaders are built (or WARM_MAX passes):
  -- the sea spawns with the galaxy, and a shader that is still building when
  -- it first draws is built again on that frame.
  if warm_assets() then world_pending = true; return end
  begin_world()
end

-- WARMED BEHIND THE CURTAIN (assets.warm, engine 0.117.0-rc12). The first frame
-- that draws a material shader builds its GPU pipeline right there: on a cold
-- driver cache 0.5-1.3 s each for the sea's (ocean, sea_ice) and the parts'
-- (hullPanels), the longest frames of a load and of the first rollout.
-- Pictures decode and upload on first use too, a few to tens of milliseconds
-- each (perf.hitches names them all).
--   * Pictures first, WARM_BATCH at a time, then the shaders; the world waits
--     for both (at most WARM_MAX seconds): the sea spawns with the galaxy,
--     and a shader still building when it first draws is built again on that
--     frame. Pictures warmed all at once (a decode thread each), or alongside
--     the shader builds, held the main thread for 150-370 ms on an empty
--     scene and up to a second in a load (rc12); one after the other, none.
-- (UI shaders — navball, tape, map — are not material shaders; assets.warm
-- refuses them on rc12.)
WARM_SHADERS = { "shaders/ocean.flsl", "shaders/sea_ice.flsl", "shaders/river.flsl", "shaders/hullPanels.flsl" }
WARM_TEXTURE_DIRS = { "textures/parts", "textures/base", "textures/vab", "textures/flora", "textures/water",
                      "textures/vfx", "textures/VFXTEX", "textures/ui" }
WARM_MAX = 8.0
WARM_BATCH = 8
world_pending = false    -- the world waits for the shaders
shaders_ready = false
local warm_t, warm_t0, pics_started = nil, nil, false
local function warm_ms() return ((app and app.wallClock and app.wallClock() or os.clock()) - (warm_t0 or 0)) * 1000 end
local function failed_note(failed)
  return (failed and #failed > 0) and (" (not prepared: " .. table.concat(failed, ", ") .. ")") or ""
end

-- Every picture under WARM_TEXTURE_DIRS, by the project-relative name the game
-- draws with (rc12's assets.getContents answers full paths on disk).
function warmPictureList()
  local pics = {}
  if not assets.getContents then return pics end
  for _, dir in ipairs(WARM_TEXTURE_DIRS) do
    local ok, list = pcall(assets.getContents, dir)
    for _, p in ipairs(ok and type(list) == "table" and list or {}) do
      local i = type(p) == "string" and p:find(dir .. "/", 1, true)
      if i and p:lower():match("%.png$") then pics[#pics + 1] = p:sub(i) end
    end
  end
  return pics
end

local function warm_shaders()
  assets.warm(WARM_SHADERS, function(failed)
    print(string.format("game_manager: shaders warmed by %.0f ms%s", warm_ms(), failed_note(failed)))
    shaders_ready = true
  end)
end

-- The pictures, a batch at a time; then the shaders.
local function warm_pictures()
  if pics_started then return end
  pics_started = true
  local pics = warmPictureList()
  local bad = {}
  local function batch(s)
    if s > #pics then
      if #pics > 0 then
        print(string.format("game_manager: %d pictures warmed by %.0f ms%s", #pics, warm_ms(), failed_note(bad)))
      end
      warm_shaders()
      return
    end
    local sub = {}
    for k = s, math.min(#pics, s + WARM_BATCH - 1) do sub[#sub + 1] = pics[k] end
    assets.warm(sub, function(failed)
      for _, f in ipairs(failed or {}) do bad[#bad + 1] = f end
      batch(s + WARM_BATCH)
    end)
  end
  batch(1)
end

-- Starts the warm; true while the world should wait for it.
function warm_assets()
  shaders_ready, pics_started = true, false
  if not (assets and assets.warm) then return false end
  warm_t0 = app and app.wallClock and app.wallClock() or os.clock()
  shaders_ready, warm_t = false, time
  warm_pictures()
  return not shaders_ready
end

-- Regenerate THIS slot's galaxy. Deterministic per seed + the parameters the
-- player picked when they created the save (nil = the generator's default).
-- A save that has checkpointed before (g_played) or sited its base skips the spawn planet's
-- eager regeneration: its terrain streams back from the slot's saved field,
-- so digs survive; a brand-new save generates it first — and alone.
function begin_world()
  world_pending = false
  load_t = time
  gen.regenerate(seed, {
    scale = worldScale(),
    pregen = first_load,
    planets = save.get("g_planets"),
    moonChance = save.get("g_moonchance"),
    atmoChance = save.get("g_atmo"),
    caveScale = save.get("g_caves"),
    minOrbit = save.get("g_minorbit"),
    spacing = save.get("g_spacing"),
    radiusMin = save.get("g_radmin"),
    radiusMax = save.get("g_radmax"),
    gravityMin = save.get("g_gravmin"),
    gravityMax = save.get("g_gravmax"),
    starScale = save.get("g_star"),
  })
  if seed <= 0 then
    seed = gen.lastSeed
    save.set("g_seed", seed)
  end
  spawn_body = gen.lastSpawnBody
  spawn_x, spawn_y, spawn_z = gen.lastSpawnX, gen.lastSpawnY, gen.lastSpawnZ
  spawn_r = gen.lastSpawnRadius
end

-- The spawn planet ORBITS while the loading screen runs (rails advance with
-- sim time), so its roll-time coordinates go stale within seconds — holding
-- or dropping the crew at those stranded them in empty space while the planet
-- sailed away. Every spawn-relative position must come from the body's LIVE
-- rails position; the roll numbers are only the fallback for the first frames
-- before the generated body registers with the rails system.
local function spawn_live()
  local b = spawn_body and space.body(spawn_body)
  if b then return b.x, b.y, b.z end
  return spawn_x, spawn_y, spawn_z
end

-- WHERE A NEW SAVE STARTS. It used to be the spawn world's north pole, always,
-- and the colony is sited wherever the crew is first put down — so on a world
-- whose pole was under its sea, the player and all five buildings started in
-- the water. Then the pole became only a preference: the first direction,
-- pole-first, standing clear of the sea with a colony's worth of dry,
-- not-too-steep ground around it (the buildings sit 30–40 m out).
--
-- THE POLE WAS THE WRONG PREFERENCE. It is the coldest place on the world:
-- climate.lua reads it as Snowfield (flora ×0.08), so a new save started with
-- nothing to harvest in sight — and on a dune world, under a "Snowfield −30 °C"
-- label over red sand, because the terrain only paints ice caps on ice and
-- frost worlds. Now every candidate is scored by the CLIMATE the player will
-- stand in (climate.sampleRel, the same model the flora field grows from):
-- how much grows there, how temperate it is, and a penalty for high latitude.
-- The dry-and-flat ring test then runs on the best-scored directions first, and
-- the pole-first order survives only as the tie-break and the fallback.
--
-- This only ever runs for a save with NO base: a loaded save puts the crew back
-- where they were, and a save whose crew position is missing but whose colony
-- is sited goes home to the colony (see `base_spawn`) — an existing base is
-- never re-sited and never re-flattened by this.

-- Ground radius along the direction (dx,dy,dz) from the centre: marched down
-- the terrain's distance field from above the tallest relief. The field is a
-- true distance, so stepping by it along any ray never passes through ground.
local function ground_r(cx, cy, cz, dx, dy, dz, top)
  local r = top
  for _ = 1, 64 do
    local d = terrain.query(cx + dx * r, cy + dy * r, cz + dz * r)
    if not d then return nil end
    if d < 0.12 then return r - math.max(d, 0) end
    r = r - math.max(d * 0.9, 0.08)
    if r < top * 0.25 then return nil end
  end
  return r
end

-- A direction (arc metres, angle) away from (dx,dy,dz) on a sphere of radius r.
local function arc_dir(dx, dy, dz, r, arc, ang)
  local ax, ay, az = 0, 1, 0
  if math.abs(dy) > 0.9 then ax, ay, az = 1, 0, 0 end
  local t1x, t1y, t1z = dy * az - dz * ay, dz * ax - dx * az, dx * ay - dy * ax
  local l = math.sqrt(t1x * t1x + t1y * t1y + t1z * t1z)
  t1x, t1y, t1z = t1x / l, t1y / l, t1z / l
  local t2x, t2y, t2z = dy * t1z - dz * t1y, dz * t1x - dx * t1z, dx * t1y - dy * t1x
  local k = math.tan(arc / r)
  local ox = dx + (t1x * math.cos(ang) + t2x * math.sin(ang)) * k
  local oy = dy + (t1y * math.cos(ang) + t2y * math.sin(ang)) * k
  local oz = dz + (t1z * math.cos(ang) + t2z * math.sin(ang)) * k
  l = math.sqrt(ox * ox + oy * oy + oz * oz)
  return ox / l, oy / l, oz / l
end

-- How good a place to live this is, by the climate: what grows, how mild it
-- is, how far from the pole. nil when there is no climate model to ask.
local function climate_score(cl, w, dx, dy, dz, g)
  if not (cl and w and cl.sampleRel) then return nil end
  local ok, s = pcall(cl.sampleRel, w, dx * g, dy * g, dz * g)
  if not ok or not s then return nil end
  local mild = 1.0 - math.min(1.0, math.abs((s.temp or 0.5) - 0.55) / 0.35)
  local polar = math.max(0, (s.lat or 0) - 0.6) * 2.5
  return (s.density or 0) * 1.6 + mild * 0.8 - polar
end

-- Returns the chosen up direction, the ground radius there, and the sea radius.
local function dry_site(cx, cy, cz)
  local cl = findScript("climate")
  local sea = (cl and spawn_body) and cl.seaRadius(spawn_body) or 0
  local w = (cl and spawn_body and cl.worldOf) and cl.worldOf(spawn_body) or nil
  local floor = sea > 0 and sea or -1e9
  local top = math.max(spawn_r, sea) + 12
  -- Fibonacci directions, pole-first (the tie-break and the fallback order).
  local N, dirs = 180, {}
  local ga = math.pi * (3 - math.sqrt(5))
  for i = 0, N - 1 do
    local y = 1 - (i + 0.5) / N * 2
    local rr = math.sqrt(1 - y * y)
    dirs[#dirs + 1] = { math.cos(ga * i) * rr, y, math.sin(ga * i) * rr, order = i }
  end
  -- Pass 1: the ground under each direction, and the climate there. Cheap —
  -- one march per direction — and it drops the drowned ones up front.
  local cands = {}
  for _, d in ipairs(dirs) do
    local g = ground_r(cx, cy, cz, d[1], d[2], d[3], top)
    -- A lake (scale 3) is water too, though its surface is not built yet.
    local wl = g and cl and cl.waterLevelAt and cl.waterLevelAt(spawn_body, d[1], d[2], d[3], g)
    if g and g - floor > 2.5 and not (wl and g - wl < 2.5) then
      d.g = g
      d.climate = climate_score(cl, w, d[1], d[2], d[3], g) or 0
      cands[#cands + 1] = d
    end
  end
  table.sort(cands, function(a, b)
    if math.abs(a.climate - b.climate) > 1e-6 then return a.climate > b.climate end
    return a.order < b.order
  end)
  -- Pass 2: the colony ring, best climate first. Bounded: a world where the
  -- first sixty good-climate spots are all cliffs or coastline settles for the
  -- least-bad one rather than marching the whole sphere twice.
  local best, best_score = nil, -1e9
  local first_ok = nil
  for i, d in ipairs(cands) do
    if i > 60 then break end
    local g = d.g
    -- The colony ring: every sample dry, and the ground not a cliff.
    local worst, spread = g - floor, 0
    for ring = 1, 2 do
      local arc = ring == 1 and 22 or 42
      for k = 0, 7 do
        local ox, oy, oz = arc_dir(d[1], d[2], d[3], g, arc, k * math.pi / 4)
        local gg = ground_r(cx, cy, cz, ox, oy, oz, top)
        if not gg then worst = -1; break end
        local wl2 = cl and cl.waterLevelAt and cl.waterLevelAt(spawn_body, ox, oy, oz, gg)
        worst = math.min(worst, gg - math.max(floor, wl2 or -1e9))
        spread = math.max(spread, math.abs(gg - g))
      end
      if worst < 1.0 then break end
    end
    local ok = worst >= 1.0 and spread < 14
    -- THE SPACEPORT'S RING: the runway and the pad reach ~150 m out
    -- (base_facilities FOOTPRINT_RADIUS). A site whose far ring is dry and
    -- not much higher or lower wins outright; one that is not is only kept
    -- as a fallback (base_facilities turns the layout to dodge what it can).
    local far_ok = true
    if ok then
      for ring = 1, 2 do
        local arc = ring == 1 and 90 or 150
        for k = 0, 11 do
          local ox, oy, oz = arc_dir(d[1], d[2], d[3], g, arc, k * math.pi / 6)
          local gg = ground_r(cx, cy, cz, ox, oy, oz, top)
          local wl2 = gg and cl and cl.waterLevelAt and cl.waterLevelAt(spawn_body, ox, oy, oz, gg)
          if not gg or gg - math.max(floor, wl2 or -1e9) < 1.0 or math.abs(gg - g) > 10 then far_ok = false; break end
        end
        if not far_ok then break end
      end
    end
    if ok and far_ok then
      print(string.format("spawn: site climate score %.2f (candidate %d of %d)", d.climate, i, #cands))
      return d[1], d[2], d[3], g, sea
    end
    if ok and not first_ok then first_ok = { d[1], d[2], d[3], g } end
    local score = math.min(worst, 20) - spread * 0.5 + d.climate * 10
    if score > best_score then best, best_score = { d[1], d[2], d[3], g }, score end
  end
  if first_ok then return first_ok[1], first_ok[2], first_ok[3], first_ok[4], sea end
  if best then return best[1], best[2], best[3], best[4], sea end
  return 0, 1, 0, spawn_r, sea
end

-- A save whose colony is already sited, but with no crew position to restore
-- (an older save, or one whose crew record went missing): go home to the
-- colony rather than running the new-site search, which would put the crew
-- somewhere the base is not. Returns a world position, or nil.
local function base_spawn()
  local name = save.get("base.body")
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  if not (type(name) == "string" and bx and by and bz) then return nil end
  local b = space.body(name)
  if not b then return nil end
  local l = math.sqrt(bx * bx + by * by + bz * bz)
  if l < 1e-3 then return nil end
  return b.x + bx + bx / l * 2.5, b.y + by + by / l * 2.5, b.z + bz + bz / l * 2.5
end

-- Where a crew with no saved position is put down: home to an EXISTING colony
-- if there is one (whatever world it is on — the new-site search must never
-- move a base that already stands), else the best new site on the spawn world.
-- Global so tests/smoke_siting.lua can hold it to that.
function spawnPoint(sx, sy, sz, body, radius)
  -- (A harness names the world; the game has it from the generator already.)
  if body then spawn_body, spawn_r = body, radius or spawn_r end
  local hx, hy, hz = base_spawn()
  if hx then
    print("spawn: back at the colony on " .. tostring(save.get("base.body")))
    return hx, hy, hz
  end
  -- A home world BUILT for it (homeGen 2) has a flat equatorial plain made
  -- for the spaceport: system_generator publishes its centre. Use it when it
  -- stands dry.
  local sg = findScript("system_generator")
  local bd = sg and sg.lastBaseDir
  if bd and bd[1] then
    local l = math.sqrt(bd[1] ^ 2 + bd[2] ^ 2 + bd[3] ^ 2)
    if l > 1e-6 then
      local dx, dy, dz = bd[1] / l, bd[2] / l, bd[3] / l
      local cl = findScript("climate")
      local sea = (cl and spawn_body and cl.seaRadius) and cl.seaRadius(spawn_body) or 0
      local g = ground_r(sx, sy, sz, dx, dy, dz, math.max(spawn_r, sea) + 40)
      if g and (sea <= 0 or g > sea + 1.5) then
        print(string.format("spawn: the spaceport plain, %.0f° from the pole", math.deg(math.acos(math.max(-1, math.min(1, dy))))))
        return sx + dx * (g + 2.5), sy + dy * (g + 2.5), sz + dz * (g + 2.5)
      end
    end
  end
  local ux, uy, uz, g, sea = dry_site(sx, sy, sz)
  print(string.format("spawn: %s, %.0f° from the pole",
    sea > 0 and string.format("%.1f m above the sea", g - sea) or "no sea",
    math.deg(math.acos(math.max(-1, math.min(1, uy))))))
  return sx + ux * (g + 2.5), sy + uy * (g + 2.5), sz + uz * (g + 2.5)
end


-- The loading screen's words. `surface` is the step in progress (nil once the
-- ground is done, when the colony is what is being waited for).
local REVEAL_MAX = 12.0   -- seconds the curtain may wait on the colony
-- …or on a NEW spaceport's ground being graded. On rc7 the engine paces the
-- edits itself, and a whole first grade (1,500 ops) took ~45 s on a small
-- world: revealing mid-grade shows the ground moving under stutter, so the
-- curtain waits long enough for a grade and one re-check.
local REVEAL_GRADE = 90.0

-- Is the spawn world's ground there yet? `elapsed` is seconds on the loading
-- screen, `d` the signed distance terrain.query gives at the spawn world's
-- (live) north-pole surface point — small only once ITS field has collision —
-- and `r` that world's radius. `busy` is terrain.busy(): something is being
-- generated or streamed in right now. "ready" ends the screen; "stalled" means
-- the ground has kept us waiting long enough, with NOTHING on its way, to try
-- the fallback (a big slot file still reading in is not a stall); else "wait".
-- Global so tests/smoke_reload.lua can hold it to that.
STALL_FREE = 20.0
local stall_freed = false
function loadGate(elapsed, d, r, busy)
  if d and math.abs(d) < (r or 0) * 0.5 and elapsed > 1.0 then return "ready" end
  if elapsed > STALL_FREE and not busy then return "stalled" end
  return "wait"
end

-- Something to read while the world is made: how to play, not lore. One at a
-- time, changing every few seconds.
local TIPS = {
  "The objectives card (top right) always says what to do next and which way to walk. O hides it.",
  "Press E at the Command Centre to sign a contract on the Ops Board.",
  "The first sale of any material at the Commerce Depot pays a discovery premium.",
  "Hold LEFT MOUSE with the Terrain Laser (2) to bore into rock — the deeper, the better the ore. Q lays rock back down.",
  "The Gravity Gun (1) lifts and throws anything loose, and uproots plants: aim and hold LEFT MOUSE.",
  "TAB or I opens your suit pack. It holds 90 kg — sell at the depot when it fills.",
  "M opens the orbit map from anywhere — on foot or in flight.",
  "Land near the base and hold ENTER to recover the craft: most of its cost comes back.",
  "ESC backs out of one thing at a time. Its CONTROLS page lists every key.",
  "A pod, a tank, an engine and a parachute make a rocket. Build one at the Vehicle Assembly.",
}
local TIP_TIME = 7.0

-- How far along the load is, 0..1. The engine has no percentage to give, so it
-- is the checklist's step plus an eased guess inside the step — and it never
-- goes backwards.
local shown_progress = 0.0
local function progress_of(el, surface)
  local p
  if surface then
    local tau = first_load and 25.0 or 5.0
    p = 0.12 + 0.68 * (1 - math.exp(-el / tau))
  else
    local since = ready_t and (time - ready_t) or 0
    p = 0.80 + 0.19 * math.min(1, since / 3.0)
  end
  shown_progress = math.max(shown_progress, p)
  return shown_progress
end

local LOAD_W = 560

-- The loading screen, described: where you are going, a bar, the checklist
-- (left-aligned, so the ✓ and › line up — each line used to be centred on its
-- own), and a tip. The dots after the headline sit in a fixed-width box, so the
-- headline no longer shuffles sideways as they count.
local function loading_tree(el, surface)
  local launch = (save.get("shipyard.pilot") or 0) == 1
  local where = spawn_body or "a new world"
  local head = launch and ("Rolling out to the pad on " .. where) or ("Landing on " .. where)
  local dots = string.rep(".", 1 + math.floor(el * 2) % 3)
  local frac = progress_of(el, surface)
  local steps = {
    { done = true, text = "Charting the system" },
    { done = surface == nil, now = surface ~= nil, text = surface or "The surface" },
    { done = false, now = surface == nil, text = "Raising the colony" },
  }
  local check = {}
  for i, st in ipairs(steps) do
    check[#check + 1] = { "row", key = "s" .. i, w = "100%", h = "fit", gap = 10, pad = 0, align = "center",
      { "text", key = "m", w = 18, h = "fit", textSize = 15,
        textColor = st.done and { 0.36, 0.88, 0.52 } or (st.now and { 0.28, 0.86, 0.74 } or { 0.30, 0.38, 0.46 }),
        text = st.done and "✓" or (st.now and "›" or "·") },
      { "text", key = "t", w = "grow", h = "fit", textSize = 15,
        textColor = st.done and { 0.62, 0.72, 0.80 } or (st.now and { 0.86, 0.93, 1.0 } or { 0.40, 0.48, 0.56 }),
        text = st.text } }
  end
  local tip = TIPS[1 + math.floor(el / TIP_TIME) % #TIPS]
  local rows = {
    { "row", key = "head", w = "fit", h = "fit", gap = 0, pad = 0, align = "end",
      { "text", key = "h", w = "fit", h = "fit", textSize = 24, textColor = { 0.86, 0.93, 1.0 }, text = head },
      { "text", key = "d", w = 30, h = "fit", textSize = 24, textColor = { 0.86, 0.93, 1.0 }, text = dots } },
    { "box", key = "gap1", w = 1, h = 6 },
    { "row", key = "bar", w = LOAD_W, h = 4, pad = 0, gap = 0, radius = 2, fill = { 0.10, 0.16, 0.22 },
      { "box", key = "f", w = math.max(4, math.floor(LOAD_W * frac + 0.5)), h = 4, radius = 2,
        fill = { 0.28, 0.86, 0.74 } } },
    { "box", key = "gap2", w = 1, h = 4 },
    { "col", key = "check", w = 300, h = "fit", gap = 6, pad = 0, align = "start",
      items = check, function(x) return x end },
  }
  if first_load then
    rows[#rows + 1] = { "text", key = "first", w = LOAD_W, h = "fit", wrap = true, textSize = 13,
      textAlign = "center", textColor = { 0.46, 0.60, 0.70 },
      text = "A world is built from scratch the first time you land — give it a minute." }
  end
  rows[#rows + 1] = { "box", key = "gap3", w = 1, h = 14 }
  rows[#rows + 1] = { "text", key = "tipL", w = LOAD_W, h = "fit", textSize = 11, tracking = 2.0,
    textAlign = "center", textColor = { 0.46, 0.60, 0.70 }, text = "TIP" }
  rows[#rows + 1] = { "text", key = "tip", w = LOAD_W, h = "fit", wrap = true, textSize = 15,
    textAlign = "center", textColor = { 0.70, 0.80, 0.89 }, text = tip }
  rows[#rows + 1] = { "text", key = "clock", w = LOAD_W, h = "fit", textSize = 12, textAlign = "center",
    textColor = { 0.36, 0.46, 0.55 },
    text = el > 10 and string.format("%d:%02d", math.floor(el / 60), math.floor(el) % 60) or " " }
  return { "col", key = "load", w = "100%", h = "fit", gap = 10, pad = 0, align = "center",
           items = rows, function(x) return x end }
end

-- Paint it into the "Loading Text" node (its own one-line text is cleared: the
-- described tree is the screen now).
local function paint_loading(el, surface)
  local n, e = ui_of("Loading Text")
  if not n then return end
  -- The curtain: deep navy falling to black rather than one flat black.
  local bg = find("Loading Screen")
  if bg and bg.style ~= "load/backdrop" then bg.style = "load/backdrop" end
  if n.text ~= "" then n.text = "" end
  if e then
    if e.width ~= 720 then e.width = 720 end
    if e.height ~= 460 then e.height = 460 end
  end
  if ui and ui.make then ui.make(n, loading_tree(el, surface)) end
end

-- Is the colony still going up where the crew is? The loading screen waits for
-- it: the base is five buildings and a flattened plaza arriving over a few
-- frames, and that is better watched from behind the curtain. A crew restored
-- on some OTHER world has no base to wait for.
local function base_pending(astro)
  local bf = findScript("base_facilities")
  if not bf then return false end
  -- the ground under it is being graded: also behind the curtain
  if bf.sited and not (bf.grading and bf.grading()) then return false end
  local home = save.get("base.body")
  if home and astro and space.dominant(astro.x, astro.y, astro.z) ~= home then return false end
  return true
end

-- A quarter-second fade rather than a cut from black to the world.
local function reveal()
  revealing, reveal_by = true, nil
  local _, bg = ui_of("Loading Screen")
  local _, tx = ui_of("Loading Text")
  local function hide()
    for _, e in ipairs({ bg, tx }) do if e then e.visible = false; e.opacity = 1.0 end end
    revealing = false
    curtain = false
  end
  if not tween then hide() return end
  tween(0.25, function(a)
    for _, e in ipairs({ bg, tx }) do if e then e.opacity = 1.0 - a end end
    if a >= 1.0 then hide() end
  end, "smooth")
end

-- WHERE A LAUNCH ROLLS OUT. The colony, if this save has one — body-relative in
-- the save (`base.*`), resolved against the body's LIVE position, plus a couple
-- of metres of clearance.
--
-- It used to be the spawn planet's north pole, unconditionally, because that is
-- what `spawn_live()` hands back. On a brand-new save those are the same place
-- and it looked fine; the moment the colony was anywhere else — a reloaded save,
-- or F6 — building a rocket in the Vehicle Assembly dropped you and your
-- launchpad at the pole instead, hundreds of metres from every building in the
-- game. "im still struggling to enter buildings after launching a ship."
local function launch_site()
  -- The spaceport's own pad or runway (base_facilities), 3 m over it.
  local bf = findScript("base_facilities")
  local kind = save.get("shipyard.site") == "runway" and "runway" or "pad"
  local st = bf and bf.launchSite and bf.launchSite(kind)
  local sb = st and space.body(st.body)
  if sb then
    return sb.x + st.x + st.up.x * 3.0, sb.y + st.y + st.up.y * 3.0, sb.z + st.z + st.up.z * 3.0
  end
  local name = save.get("base.body")
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  if not (name and bx and by and bz) then return nil end
  local b = space.body(name)
  if not b then return nil end
  local x, y, z = b.x + bx, b.y + by, b.z + bz
  -- Up here is radial, and the crew wants to arrive above the ground rather than
  -- inside it — the pad's own terrain probe does the rest.
  local ux, uy, uz = x - b.x, y - b.y, z - b.z
  local l = math.sqrt(ux * ux + uy * uy + uz * uz)
  if l < 1e-3 then return x, y + 3.0, z end
  return x + ux / l * 3.0, y + uy / l * 3.0, z + uz / l * 3.0
end

function update(node, dt)
  if not slot then return end

  if world_pending then
    -- the shaders are building on workers; the world waits for them
    if not shaders_ready and time - (warm_t or time) < WARM_MAX then
      paint_loading(time - (warm_t or time), "Preparing textures and shaders")
      return
    end
    if not shaders_ready then
      print(string.format("game_manager: assets still warming after %.0f s — making the world anyway", WARM_MAX))
    end
    begin_world()
  end

  if loading then
    -- Hold the crew safely above the spawn planet (its LIVE position — it is
    -- orbiting under us right now) while its terrain streams in. Velocity
    -- pinned to zero: the world can't hurt what physics can't reach.
    local sx, sy, sz = spawn_live()
    local hover = sy + spawn_r + 60
    local n = find("Astronaut")
    if n then
      n.x, n.y, n.z = sx, hover, sz
      n.vx, n.vy, n.vz = 0, 0, 0
    end
    -- ASK FOR THE GROUND BY NAME. Under physics.pause a script's hover never
    -- reached the engine before 0.117.0-rc3, so residency still saw the crew
    -- where the scene authored it, 60 km off, and every RESUMED save sat on
    -- this screen forever. The engine now streams a cold world in around a
    -- body moved while paused (floptle/0450): Continue, a loaded save and the
    -- trip back from the Vehicle Assembly reach the base in ~1 s without this
    -- warm or the stall fallback below. Both stay as belt and braces (and
    -- tests/smoke_reload.lua holds the warm to it).
    if spawn_body and terrain.warm then terrain.warm(spawn_body) end
    -- WHAT IS IT DOING. This screen used to be the galaxy number and three
    -- cycling dots, held for as long as the work took — and on a BRAND NEW
    -- save the work is a whole planet generated from nothing, which is over a
    -- minute. A minute of dots is indistinguishable from a hang. Then it said
    -- what the LOADER was doing ("ENTERING GALAXY 48213", "reads it back from
    -- disk"), which is true and is a debug log.
    --
    -- So it names the place, and shows the steps as a checklist: the engine
    -- has no percentage to give, but a list that ticks is progress you can see.
    -- The first load of a save says it is the slow one, once, in plain words.
    local busy = terrain.busy and terrain.busy() or false
    paint_loading(time - load_t, busy and "Shaping the surface" or "Bringing the surface in")
    -- Ready = the spawn planet's SURFACE answers: the signed distance at its
    -- (live) north-pole surface point is small only once ITS field has
    -- collision.
    local d = terrain.query(sx, sy + spawn_r, sz)
    local gate = loadGate(time - load_t, d, spawn_r, busy)
    if gate == "stalled" and not stall_freed then
      -- Belt and braces: the surface has not answered in STALL_FREE seconds
      -- and nothing is streaming it in.
      -- Let the physics tick run so the parked crew is where the engine
      -- thinks it is too (the hover is re-pinned with zero velocity every
      -- frame, so nothing falls), and the world streams in around them.
      stall_freed = true
      physics.pause(false)
      print(string.format("game_manager: %s's surface has not answered in %.0f s — letting physics run so it streams in around the crew",
        tostring(spawn_body), time - load_t))
    end
    if gate == "ready" then
      loading = false
      physics.pause(false)
      local astro = find("Astronaut")
      local vp = nil
      for _, s in ipairs(findScripts("vessel_controller")) do
        if s.piloting then vp = s break end
      end
      if (save.get("shipyard.pilot") or 0) == 1 or vp then
        -- Arriving from the builder's LAUNCH: the astronaut starts IN the
        -- vessel's pod (the vessel pilot seats them the moment it spawns) —
        -- never standing on the surface next to their own rocket. But WHERE the
        -- rocket assembles is wherever the crew is put down, because that is
        -- what vessel_spawner sites the pad against — so it has to be the base.
        if astro then
          astro.visible = false
          local lx, ly, lz = launch_site()
          if lx then
            astro.x, astro.y, astro.z = lx, ly, lz
          else
            astro.x, astro.y, astro.z = sx, sy + spawn_r + 6, sz
          end
          astro.vx, astro.vy, astro.vz = 0, 0, 0
        end
      elseif astro and not restore_pos_of(astro, "p") then
        astro.x, astro.y, astro.z = spawnPoint(sx, sy, sz)
        astro.vx, astro.vy, astro.vz = 0, 0, 0
      end
      -- The overlay stays up until the colony stands: the frames right after
      -- the world goes live are the ones where the base, the flora and the rock
      -- field build (the rock scatter alone is a ~0.8 s frame), and that hitch
      -- is better spent behind the curtain than in front of the player. It
      -- used to be a flat two seconds, which on a slow first siting lifted on a
      -- half-built base. Never longer than REVEAL_MAX, whatever happens.
      ready_t = time
      reveal_by = time + REVEAL_MAX
      next_save = time + params.autosave
      print(string.format("galaxy %d ready — welcome to %s", seed, spawn_body or "?"))
    end
    return
  end

  if reveal_by and not revealing then
    paint_loading(time - load_t, nil)
    -- A beat after ready at the least (the scatter hitch), then as soon as the
    -- colony is up.
    local bf = findScript("base_facilities")
    -- a new spaceport being sited, graded and paved holds the curtain longer
    if bf and ((bf.grading and bf.grading()) or base_pending(find("Astronaut"))) and time < ready_t + REVEAL_GRADE then
      reveal_by = math.max(reveal_by, time + 0.5)
    end
    if time >= reveal_by or (time - ready_t > 1.0 and not base_pending(find("Astronaut"))) then
      reveal()
    end
  end

  -- Autosave checkpoints.
  if time >= next_save then
    next_save = time + params.autosave
    saveGame()
  end
end
