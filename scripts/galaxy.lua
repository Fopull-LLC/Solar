-- GALAXY — there is always another system out there, and you can fly to it.
--
-- The galaxy is never stored. It is a FUNCTION of the save's seed: space is cut
-- into square sectors, each sector asks a hash whether it holds a star and where
-- in itself that star sits, and the answer is the same on every machine and in
-- every session forever. Nothing is written down, nothing can drift, and a
-- galaxy of any size costs one number.
--
-- Sectors near you are BUILT (real star, real planets, real terrain genspecs);
-- sectors you leave behind are torn down again. What you dug survives anyway —
-- terrain edits live in the save slot keyed by seed, so a world you mined and
-- came back to is the world you left, and a world you never visited costs
-- nothing at all.
--
--     ┌────────┬────────┬────────┐   ● you
--     │  cold  │  BUILT │  cold  │   BUILT sectors are scene nodes
--     ├────────┼────────┼────────┤   cold sectors are a hash and nothing else
--     │  BUILT │ ● HOME │  BUILT │
--     ├────────┼────────┼────────┤
--     │  cold  │  BUILT │  cold  │
--     └────────┴────────┴────────┘
--
-- THE GALAXY IS A DISC, in the XZ plane. That is what a galaxy looks like, and
-- it is also the one layout whose maths is already proven in this project: the
-- rails place a body with `e = i = 0` at exactly `x = a·cos(m0)`, `z = a·sin(m0)`,
-- which is how every planet in `system_generator` is positioned. A sphere of
-- sectors would need an inclination convention nothing here has verified.
--
-- ── WHY YOU CANNOT WARP STRAIGHT THROUGH IT ─────────────────────────────────
--
-- Building a system is cheap but not free, and its planets' terrain is neither.
-- At 10,000× a ship crosses a sector in seconds, and a galaxy asked to build
-- twenty systems at once does not degrade — it stops.
--
-- So the warp ceiling is DERIVED rather than picked: it is the fastest you can
-- go and still have `leadTime` seconds between now and the edge of what is
-- built. Ask for more and the ladder simply does not offer it, the HUD says
-- which of the two reasons it is (`warpNote`), and the moment the ring is quiet
-- the ceiling lifts itself. There is no cooldown and nothing to wait out: it
-- reads as the galaxy having a speed limit near unexplored space, which is
-- exactly what it is.
--
-- The other half of the guard is the QUEUE: one system is built per call, never
-- a burst, and none at all while the engine's terrain generator is busy with a
-- world somebody is standing on.
--
--     local gx = findScript("galaxy")
--     gx.maxWarp()        the ceiling the warp ladder must respect
--     gx.warpNote()       why, in a few words, or nil when nothing is limiting
--     gx.systems()        the resident systems, nearest first (the map reads this)

defaults = {
  --@header Scale
  -- The side of one sector, in metres. Also the spacing between stars, so this
  -- is "how far apart are the suns" — the single number that sets how much of
  -- an expedition an interstellar trip is.
  --@range 200000 20000000 --@units m
  sector = 2400000.0,
  -- How likely a sector is to hold a star at all. Below 1 the galaxy gets
  -- voids and clusters instead of a lattice, which is the whole point.
  --@range 0.1 1
  starChance = 0.55,

  --@header Streaming
  -- How many sectors out from yours are BUILT. 1 = the 8 around you (a disc, so
  -- 3×3 minus your own). Every one of them is scene nodes that exist whether or
  -- not you ever look at them.
  --@range 1 3
  build = 1,
  -- How many out are KEPT once built. Must exceed `build`, so the system you
  -- just left is not torn down the moment you cross back over a line — that
  -- hysteresis is the whole reason there are two numbers.
  --@range 2 5
  keep = 2,
  -- The least time between two systems being built, so a fast crossing spreads
  -- its work over seconds instead of spending it all on one frame.
  --@range 0.25 10 --@units s
  interval = 1.5,

  --@header The warp ceiling
  -- How many seconds of warning the streamer is owed: warp is capped so that
  -- the edge of the built region is always at least this far ahead of you.
  --@range 5 120 --@units s
  leadTime = 25.0,
  -- The ceiling while a system is actually being built. Not 1× — being yanked
  -- to a standstill reads as a bug — but low enough that you cannot outrun it.
  --@range 1 10000
  buildingWarp = 100.0,
  --- The warp above which the ceiling stops being reported at all. Set it to
  --- the top of the ship's own warp ladder: a ceiling nobody can reach is not
  --- a ceiling, and reporting one puts a permanent line on the HUD.
  --@range 1 1000000
  freeWarp = 10000.0,
}

-- Published. `systems()` is the readable form; these are for anything that
-- wants the numbers without a call.
resident = 0
built = 0

-- sectorKey -> { star = <name>, node = <group node>, idBase = n }
local live = {}
-- Terrain-id blocks handed out. Ids are SCENE-wide and they name the .cfield on
-- disk, so two systems must never share one. A sector keeps its block for the
-- life of the session even after it is torn down, so re-entering a sector
-- re-uses the same ids and therefore the same saved terrain files.
local blocks = {}
local next_block = 1
local IDS_PER_SYSTEM = 64

local last_build = -1e9
local note = nil
local ceiling = math.huge

-- Back-pressure, asked of the engine when the engine can answer it.
--
-- `terrain.busy()` reports whether the background terrain worker already has a
-- field generating or streaming in. Fills and streaming share ONE budget, so
-- building the next system while it is busy queues that system in front of the
-- ground somebody is standing on.
--
-- Probed rather than called outright: this game has to keep running on an engine
-- build that predates the binding, and there the honest answer is "I cannot
-- know", which means fall back to the interval alone. That is slower than it
-- needs to be when the worker is idle and never wrong.
local terrain_busy = terrain and terrain.busy
local function worker_busy()
  if not terrain_busy then return false end
  local ok, v = pcall(terrain_busy)
  return ok and v == true
end

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

-- ── the hash ────────────────────────────────────────────────────────────────
--
-- A sector's coordinates in, one number in [0,1) out, with no state and no
-- allocation. This IS the galaxy: every question about a sector is asked of it,
-- so it has to mix well and it has to be exactly reproducible.
--
-- Written in plain arithmetic rather than bit twiddling because this runs on
-- LuaJIT, which is Lua 5.1: `~`, `>>` and `&` are 5.3 operators and would not
-- even parse. Every intermediate is kept under 2^53 so a double holds it
-- EXACTLY — that is what makes the result reproducible rather than merely
-- consistent, and it is why the modulus and the multiplier are the sizes they
-- are (2^24 × 2^27 = 2^51, comfortably inside a double's integer range).

local M = 16777216      -- 2^24
local A = 134775813     -- Borland's LCG multiplier, ~2^27

local function step(n)
  return (n * A + 1) % M
end

local function h01(seed, sx, sz, salt)
  -- The offsets keep negative sector indices distinct, and `seed` is folded
  -- first because a save seed can be large enough to lose bits on its own.
  local n = ((seed % M) * 7919
    + (sx + 32768) * 73856093
    + (sz + 32768) * 19349663
    + salt * 83492791) % M
  return step(step(step(n))) / M
end

-- The same hash as a whole number, for seeding a system's own roll.
local function hash(seed, sx, sz, salt)
  return math.floor(h01(seed, sx, sz, salt) * 2147483647) + 1
end

local function key(sx, sz) return sx .. ":" .. sz end

-- ── what is in a sector ─────────────────────────────────────────────────────

-- Home is sector (0,0) and is built by `system_generator.roll`, never by us.
local function is_home(sx, sz) return sx == 0 and sz == 0 end

-- Does this sector hold a star, and where? The jitter band is deliberately
-- narrow: two stars in neighbouring sectors must stay far enough apart that
-- their spheres of influence cannot overlap, because patched conics assume a
-- point is inside at most one of them. 0.35–0.65 keeps any two at least
-- 0.7 sectors apart, and `soi` below is 0.3.
local function star_of(seed, sx, sz, S)
  if is_home(sx, sz) then return nil end
  if h01(seed, sx, sz, 1) >= (params.starChance or 0.55) then return nil end
  local jx = 0.35 + h01(seed, sx, sz, 2) * 0.30
  local jz = 0.35 + h01(seed, sx, sz, 3) * 0.30
  return (sx + jx) * S, (sz + jz) * S, hash(seed, sx, sz, 4)
end

local function sector_of(x, z, S)
  return math.floor(x / S), math.floor(z / S)
end

-- ── where the player is ─────────────────────────────────────────────────────

-- The thing the galaxy streams around: whatever the player is riding. A vessel
-- under way is the honest anchor (it is the thing that can outrun the stream);
-- otherwise the crew.
local function anchor()
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.piloting and v.node and v.node.valid then return v.node end
  end
  local a = find("Astronaut")
  if a and a.valid then return a end
  return nil
end

-- ── building and tearing down ───────────────────────────────────────────────

local function block_for(k)
  if not blocks[k] then
    next_block = next_block + 1
    blocks[k] = next_block * IDS_PER_SYSTEM
  end
  return blocks[k]
end

local function build_sector(seed, sx, sz, S)
  local x, z, sseed = star_of(seed, sx, sz, S)
  if not x then return false end
  local gen = ref("system_generator")
  if not (gen and gen.buildNeighbour) then return false end
  local k = key(sx, sz)
  local a = math.sqrt(x * x + z * z)
  local m0 = math.atan2(z, x)
  local name = gen.buildNeighbour(sseed, a, m0, S * 0.3, block_for(k), "galaxysystem")
  if not name then return false end
  live[k] = { star = name, idBase = block_for(k) }
  built = built + 1
  log(string.format("galaxy: %s system built — sector %d,%d, %.2f Mm out", name, sx, sz, a / 1e6))
  return true
end

local function drop_sector(k)
  local e = live[k]
  if not e then return end
  -- Tear down by NAME through the group node: the star's system group holds
  -- every body it owns, so one subtree destroy takes the lot — the same
  -- property the generator built the group for.
  local n = find(e.star .. " System")
  if n and n.valid then n:destroy() end
  live[k] = nil
  log("galaxy: " .. e.star .. " system released")
end

-- ── the warp ceiling ────────────────────────────────────────────────────────
--
-- Two independent limits, and the tighter one wins:
--
--   1. A system is being built right now, or one is due. Nothing may move fast
--      while the ring is unfinished.
--   2. Otherwise: how fast can you go and still have `leadTime` seconds before
--      you reach ground the streamer has not covered? The distance that matters
--      is to the edge of the BUILT region, not to the nearest star — you can
--      cross empty space at any speed, and what you must not do is arrive
--      somewhere that has not been built.
--
-- Returned as a warp MULTIPLIER, which is what the ladder speaks.

function maxWarp() return ceiling end
function warpNote() return note end

local function recompute(node, S, speed)
  local pending = false
  local ax, az = node.x, node.z
  local sx, sz = sector_of(ax, az, S)
  local seed = save.get("g_seed") or 0
  local b = math.floor(params.build or 1)
  for dx = -b, b do
    for dz = -b, b do
      local k = key(sx + dx, sz + dz)
      if not live[k] and not is_home(sx + dx, sz + dz) and star_of(seed, sx + dx, sz + dz, S) then
        pending = true
      end
    end
  end
  if pending then
    ceiling = params.buildingWarp or 100.0
    note = string.format("warp %d× max · charting the systems ahead", ceiling)
    return
  end
  -- The built region reaches `build` sectors out from the one you are in, so
  -- the nearest unbuilt ground is the far edge of that ring. Measured from
  -- where you are inside your own sector, not from its centre.
  local ex = (sx + (b + 1)) * S - ax
  local wx = ax - (sx - b) * S
  local ez = (sz + (b + 1)) * S - az
  local wz = az - (sz - b) * S
  local margin = math.max(1.0, math.min(math.min(ex, wx), math.min(ez, wz)))
  local lead = math.max(1.0, params.leadTime or 25.0)
  -- speed is in metres per second of GAME time; warp multiplies game time, so
  -- the distance covered per real second is speed × warp.
  local cap = margin / (lead * math.max(speed, 1.0))
  if cap < 1.0 then cap = 1.0 end
  -- Above the top of the ladder the ceiling is moot, so say NOTHING rather
  -- than report a limit nobody can reach. A HUD line that is always there is a
  -- HUD line nobody reads, and this one has to be believed on the one occasion
  -- it drops.
  local top = math.max(1.0, params.freeWarp or 10000.0)
  if cap >= top then
    ceiling, note = math.huge, nil
  else
    ceiling = cap
    -- Phrased as a fact about the ship, not a complaint about the player:
    -- what the ladder tops out at right now, and why.
    note = string.format("warp %d× max · charting ahead of you", math.floor(cap))
  end
end

-- ── readable state (the map + the HUD) ──────────────────────────────────────

-- Every resident system, nearest first: name, distance, and whether it is home.
function systems()
  local a = anchor()
  local out = {}
  local hs = (ref("system_generator") or {}).homeStar
  if hs then out[#out + 1] = { star = hs, home = true, dist = 0 } end
  for _, e in pairs(live) do
    local b = space.body(e.star)
    local d = 0
    if b and a then
      d = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
    end
    out[#out + 1] = { star = e.star, home = false, dist = d }
  end
  if a and hs then
    local b = space.body(hs)
    if b then
      out[1].dist = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
    end
  end
  table.sort(out, function(p, q) return p.dist < q.dist end)
  return out
end

-- ── driver ──────────────────────────────────────────────────────────────────

local last_x, last_z, last_t = nil, nil, 0

function update(node, dt)
  local gen = ref("system_generator")
  -- Nothing to hang a galaxy off until home exists. `homeStar` is set by the
  -- roll, so this is also the "still loading" gate — and it is the SAME fact
  -- rather than a second flag that could disagree with it.
  if not (gen and gen.homeStar) then return end
  local a = anchor()
  if not a then return end
  -- The sector grows with the save's WORLD SCALE (system_generator SCALES):
  -- bigger systems need the stars further apart, and an old save keeps the
  -- spacing — and so the neighbours — it was made with.
  local S = math.max(1e5, (params.sector or 2400000.0) * ((gen.scale and gen.scale.sector) or 1.0))
  local seed = save.get("g_seed") or 0

  -- Speed over the last interval, in game metres per second. Measured rather
  -- than read off a vessel, so it is right for the crew, a ship, and a wreck.
  local speed = 0
  if last_x and time > last_t then
    local dtt = time - last_t
    speed = math.sqrt((a.x - last_x) ^ 2 + (a.z - last_z) ^ 2) / math.max(dtt, 1e-3)
  end
  if not last_x or time - last_t > 0.5 then
    last_x, last_z, last_t = a.x, a.z, time
  end

  local sx, sz = sector_of(a.x, a.z, S)
  local b = math.floor(params.build or 1)
  local k = math.max(b + 1, math.floor(params.keep or 2))

  -- Build at most ONE system per interval, and only when the engine's terrain
  -- generator is not already busy with a world somebody is standing on — a
  -- galaxy that queues behind the spawn planet is a galaxy that steals its
  -- cores. Nearest sector first, so what you are about to reach is what gets
  -- built.
  if time - last_build >= (params.interval or 1.5) and not worker_busy() then
    local best, bd = nil, nil
    for dx = -b, b do
      for dz = -b, b do
        local kk = key(sx + dx, sz + dz)
        if not live[kk] and not is_home(sx + dx, sz + dz) then
          local d = dx * dx + dz * dz
          if star_of(seed, sx + dx, sz + dz, S) and (not bd or d < bd) then
            best, bd = { sx + dx, sz + dz }, d
          end
        end
      end
    end
    if best and build_sector(seed, best[1], best[2], S) then
      last_build = time
    end
  end

  -- Release what is well behind us. `keep` exceeds `build` on purpose: without
  -- the gap, standing on a sector line would build and destroy the same system
  -- once a frame.
  for kk, _ in pairs(live) do
    local cx, cz = kk:match("^(-?%d+):(-?%d+)$")
    if cx then
      local dx, dz = math.abs(tonumber(cx) - sx), math.abs(tonumber(cz) - sz)
      if dx > k or dz > k then drop_sector(kk) end
    end
  end

  resident = 0
  for _ in pairs(live) do resident = resident + 1 end
  recompute(a, S, speed)
end
