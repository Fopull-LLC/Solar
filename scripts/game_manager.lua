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
  -- Regenerate THIS slot's galaxy. Deterministic per seed + the parameters the
  -- player picked when they created the save (nil = the generator's default).
  -- A save that has checkpointed before (g_played) skips the spawn planet's
  -- eager regeneration: its terrain streams back from the slot's saved field,
  -- so digs survive; a brand-new save generates it first — and alone.
  first_load = save.get("g_played") == nil
  gen.regenerate(seed, {
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
-- the water. Now the pole is only the preference: the search walks directions
-- spread evenly over the world, nearest the pole first, and takes the first
-- one standing clear of the sea with a colony's worth of dry, not-too-steep
-- ground around it (the buildings sit 30–40 m out). A world with no sea uses
-- the same search to stay off cliffs and out of pits.

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

-- Returns the chosen up direction, the ground radius there, and the sea radius.
local function dry_site(cx, cy, cz)
  local cl = findScript("climate")
  local sea = (cl and spawn_body) and cl.seaRadius(spawn_body) or 0
  local floor = sea > 0 and sea or -1e9
  local top = math.max(spawn_r, sea) + 12
  -- Fibonacci directions, sorted pole-first.
  local N, dirs = 180, {}
  local ga = math.pi * (3 - math.sqrt(5))
  for i = 0, N - 1 do
    local y = 1 - (i + 0.5) / N * 2
    local rr = math.sqrt(1 - y * y)
    dirs[#dirs + 1] = { math.cos(ga * i) * rr, y, math.sin(ga * i) * rr }
  end
  local best, best_score = nil, -1e9
  for _, d in ipairs(dirs) do
    local g = ground_r(cx, cy, cz, d[1], d[2], d[3], top)
    if g and g - floor > 2.5 then
      -- The colony ring: every sample dry, and the ground not a cliff.
      local worst, spread = g - floor, 0
      for ring = 1, 2 do
        local arc = ring == 1 and 22 or 42
        for k = 0, 7 do
          local ox, oy, oz = arc_dir(d[1], d[2], d[3], g, arc, k * math.pi / 4)
          local gg = ground_r(cx, cy, cz, ox, oy, oz, top)
          if not gg then worst = -1; break end
          worst = math.min(worst, gg - floor)
          spread = math.max(spread, math.abs(gg - g))
        end
        if worst < 1.0 then break end
      end
      local ok = worst >= 1.0 and spread < 14
      -- Pole-first among the good ones; the least-bad otherwise.
      local score = (ok and 1000 or 0) + math.min(worst, 20) - spread * 0.5 + d[2] * 40
      if ok then return d[1], d[2], d[3], g, sea end
      if score > best_score then best, best_score = { d[1], d[2], d[3], g }, score end
    end
  end
  if best then return best[1], best[2], best[3], best[4], sea end
  return 0, 1, 0, spawn_r, sea
end

-- The loading screen's words. `surface` is the step in progress (nil once the
-- ground is done, when the colony is what is being waited for).
local REVEAL_MAX = 12.0   -- seconds the curtain may wait on the colony

local function loading_text(el, surface)
  local launch = (save.get("shipyard.pilot") or 0) == 1
  local dots = string.rep(".", 1 + math.floor(el * 2) % 3)
  local where = spawn_body or "a new world"
  local lines = {
    (launch and ("Rolling out to the pad on " .. where) or ("Landing on " .. where)) .. dots,
    "",
    "✓  Charting the system",
    surface and ("›  " .. surface) or "✓  The surface",
    surface and "    Raising the colony" or "›  Raising the colony",
  }
  if first_load then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "A world is built from scratch the first time you land — give it a minute."
  end
  if el > 10 then
    lines[#lines + 1] = string.format("%d:%02d", math.floor(el / 60), math.floor(el) % 60)
  end
  return table.concat(lines, "\n")
end

-- Is the colony still going up where the crew is? The loading screen waits for
-- it: the base is five buildings and a flattened plaza arriving over a few
-- frames, and that is better watched from behind the curtain. A crew restored
-- on some OTHER world has no base to wait for.
local function base_pending(astro)
  local bf = findScript("base_facilities")
  if not bf or bf.sited then return false end
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
    local ttl = find("Loading Text")
    if ttl then
      local el = time - load_t
      local busy = terrain.busy and terrain.busy() or false
      ttl.text = loading_text(el, busy and "Shaping the surface" or "Bringing the surface in")
    end
    -- Ready = the spawn planet's SURFACE answers: the signed distance at its
    -- (live) north-pole surface point is small only once ITS field has
    -- collision.
    local d = terrain.query(sx, sy + spawn_r, sz)
    if d and math.abs(d) < spawn_r * 0.5 and time - load_t > 1.0 then
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
        local ux, uy, uz, g, sea = dry_site(sx, sy, sz)
        astro.x, astro.y, astro.z = sx + ux * (g + 2.5), sy + uy * (g + 2.5), sz + uz * (g + 2.5)
        astro.vx, astro.vy, astro.vz = 0, 0, 0
        print(string.format("spawn: %s, %.0f° from the pole",
          sea > 0 and string.format("%.1f m above the sea", g - sea) or "no sea",
          math.deg(math.acos(math.max(-1, math.min(1, uy))))))
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
    local ttl = find("Loading Text")
    if ttl then ttl.text = loading_text(time - load_t, nil) end
    -- A beat after ready at the least (the scatter hitch), then as soon as the
    -- colony is up.
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
