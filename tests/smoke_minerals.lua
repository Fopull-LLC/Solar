-- SMOKE HARNESS for mineral_field.lua — the rock lying on a planet's surface.
--
-- This is the first thing in the project built on `scatter.*` rather than on
-- scene nodes, so what it guards is mostly the contract with that API:
--
--   * a source per rock type, each with its OWN seed. One seed for all of them
--     would stack four meshes in the same place and call it a field.
--   * placement is declared, not built: no `createNode` anywhere in it.
--   * `scatter.near` is the aim test, because scattered props have no colliders
--     and a raycast goes straight through them.
--   * a break that pays NOTHING must not also destroy the rock — a full pack
--     costs you the swing, not the boulder.
--   * losses are saved as INSTANCE IDS. That is the whole reason permanence is
--     affordable here and isn't for the flora field: save values are capped
--     around a kilobyte, and an id list is integers.
--   * changing worlds tears the old planet's sources down. A source left
--     standing is a planet's worth of rock drawn around a body you left.
--
--   luajit solar/tests/smoke_minerals.lua

local checks = 0
local failures = {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end

_G.time = 0.0
_G.vec3 = function(x, y, z) return { x = x, y = y, z = z } end
-- The engine's own noise, near enough for a density rule to be exercised.
_G.math.saturate = function(v) return math.max(0, math.min(1, v)) end
_G.math.fbm = function(x, y, z, _)
  return (math.sin(x * 1.7) + math.cos(y * 2.3) + math.sin(z * 1.1)) / 3.0
end

-- `scatter.create` rejects an option it doesn't recognise (v0.29.0), and that
-- is load-bearing: it is the only reason a dead option could not hide. The stub
-- enforces the same list, so a typo here fails the test rather than the game.
local KNOWN = {
  asset = true, lod = true, seed = true, center = true, radius = true,
  halfX = true, halfZ = true, perChunk = true, chunk = true, align = true,
  scaleMin = true, scaleMax = true, range = true, fade = true,
  density = true, densityRows = true, parent = true,
}

-- ── a stubbed scatter engine ────────────────────────────────────────────────
-- Faithful to the documented contract: instances are derived from the seed, an
-- id is stable, `removed` returns the sorted loss list, `restore` puts them all
-- back and answers how many.
local next_source = 0
local SOURCES = {}
local created = {}

-- The engine's rule, as of v0.31.0: a square sweep whose side follows the
-- outermost LOD distance, and which STOPS AT THE BODY — because 700 metres of
-- reach on a 214-metre world is 700 metres of nothing. (The real one also culls
-- the square's corners; this doesn't, which only makes the harness pessimistic.)
function _G.cost_model(far, chunk, radius)
  local n = math.ceil((far + chunk) / chunk)
  local lim = math.ceil(radius / chunk) + 1
  local side = 2 * math.min(n, lim) + 1
  return side * side
end
_G.scatter = {
  create = function(opts)
    for k in pairs(opts) do
      if not KNOWN[k] then
        error("scatter.create: unknown option `" .. tostring(k) .. "`", 2)
      end
    end
    next_source = next_source + 1
    local id = next_source
    -- Derived, not stored — POSITION as well as id, exactly as the real one is
    -- (`hash(seed, chunk, index)`). Two sources sharing a seed are therefore
    -- indistinguishable, which is the mistake this harness exists to catch:
    -- if positions were fixed here, a seed collision would look fine.
    local inst = {}
    for i = 1, 8 do
      local jitter = (opts.seed % 97) * 0.31
      inst[i] = { id = (opts.seed % 1000) * 100 + i,
                  pos = { x = i * 3.0 + jitter, y = 0, z = 0 }, scale = 1.0 }
    end
    SOURCES[id] = { opts = opts, inst = inst, gone = {} }
    created[#created + 1] = opts
    return id
  end,
  destroy = function(id)
    local had = SOURCES[id] ~= nil
    SOURCES[id] = nil
    return had
  end,
  -- scatter.cost(id) — v0.31.0, and floptle/0071, which was filed FROM this
  -- game after the field it guards made the game unplayable.
  --
  -- The oracle below is the harness's, not the script's. That is the point: the
  -- script is not allowed to know how a chunk count is arrived at any more, only
  -- to ask and to obey. `cost_model` is swappable so a test can hand the script
  -- an answer it has to react to, and the script's published numbers are checked
  -- against what this returned — so if it ever goes back to computing its own,
  -- the two diverge and the test says so.
  cost = function(id)
    local s = SOURCES[id]
    if not s then return {} end
    local far = s.opts.lod[#s.opts.lod].distance
    local chunks = _G.cost_model(far, s.opts.chunk, s.opts.radius)
    return { chunks = chunks, props = chunks * s.opts.perChunk,
             far = far, chunkSize = s.opts.chunk, perChunk = s.opts.perChunk }
  end,
  near = function(id, point, radius)
    local s = SOURCES[id]
    if not s then return {} end
    local out = {}
    for _, it in ipairs(s.inst) do
      if not s.gone[it.id] then
        local d = math.sqrt((it.pos.x - point.x) ^ 2 + (it.pos.y - point.y) ^ 2
                          + (it.pos.z - point.z) ^ 2)
        if d <= (radius or 1) then
          out[#out + 1] = { id = it.id, pos = it.pos, distance = d, scale = it.scale }
        end
      end
    end
    table.sort(out, function(a, b) return a.distance < b.distance end)
    return out
  end,
  remove = function(id, inst)
    local s = SOURCES[id]
    if s then s.gone[inst] = true end
  end,
  removed = function(id)
    local s = SOURCES[id]
    if not s then return {} end
    local out = {}
    for k in pairs(s.gone) do out[#out + 1] = k end
    table.sort(out)
    return out
  end,
  restore = function(id)
    local s = SOURCES[id]
    if not s then return 0 end
    local n = 0
    for k in pairs(s.gone) do s.gone[k] = nil; n = n + 1 end
    return n
  end,
}
-- If the field ever reaches for createNode, that is the bug this whole file
-- exists to prevent: it would be building a forest of scene nodes again.
local node_builds = 0
_G.createNode = function() node_builds = node_builds + 1 end
_G.spawn = function() node_builds = node_builds + 1 end

-- ── the world ───────────────────────────────────────────────────────────────
local planet = { name = "Ryilex", x = 4800, y = 0, z = -1200, radius = 214 }
local moon   = { name = "Pelia",  x = 9000, y = 0, z = -1200, radius = 45 }
local WORLDS = {
  Ryilex = { kind = "rock", seed = 7, radius = 214 },
  Pelia  = { kind = "rock", seed = 91, radius = 45 },
}
local here = planet

local astro = { name = "Astronaut", valid = true,
                x = planet.x, y = planet.y + planet.radius, z = planet.z }
-- The planets have SCENE NODES, because that is what a field anchors to: the
-- node the orbital rails move. A body without one gets no field at all, which is
-- the last test in this file.
local PNODES = {
  Astronaut = astro,
  Ryilex = { name = "Ryilex", valid = true },
  Pelia = { name = "Pelia", valid = true },
}
_G.find = function(n) return PNODES[n] end
_G.space = {
  dominant = function() return here.name end,
  body = function(n)
    if n == "Ryilex" then return planet end
    if n == "Pelia" then return moon end
  end,
}
local report = print
_G.print = function() end

-- ── the scripts it reads ────────────────────────────────────────────────────
local walker = { onFoot = true }
local climate = { worldOf = function(n) return WORLDS[n] end }
local mats = { name = function(m) return m end }
local pack_full = false
local added = {}
local inv = {
  add = function(_, mat, n)
    if pack_full then return 0 end
    added[#added + 1] = { mat = mat, n = n }
    return n
  end,
}
local refs = { planet_walker = walker, climate = climate, inventory = inv,
               materials = mats }
_G.findScript = function(k) return refs[k] end
_G.findScripts = function() return {} end

local SAVE = {}
_G.save = {
  get = function(k) return SAVE[k] end,
  set = function(k, v) SAVE[k] = v end,
}

-- ── load ────────────────────────────────────────────────────────────────────
local chunk = assert(loadfile("solar/scripts/mineral_field.lua"))
chunk()
_G.params = {}
for k, v in pairs(_G.defaults) do _G.params[k] = v end
local node = { name = "Mineral Field" }
start(node)

local function tick(n)
  for _ = 1, (n or 1) do
    _G.time = _G.time + 1 / 60
    update(node, 1 / 60)
  end
end

-- 1. STANDING UP A WORLD. One source per rock type, and nothing built by hand.
tick(2)
ok(_G.sources == 4, "four rock types get a source each — got " .. tostring(_G.sources))
ok(_G.bodyName == "Ryilex", "the field names the world it's on")
ok(node_builds == 0, "nothing is built with createNode — the engine draws it")

-- 2. EVERY SOURCE HAS ITS OWN SEED. Sharing one would put every prototype at
-- the same place and the "field" would be four meshes in a stack.
local seeds = {}
local seed_dupes = 0
for _, o in ipairs(created) do
  if seeds[o.seed] then seed_dupes = seed_dupes + 1 end
  seeds[o.seed] = true
end
ok(seed_dupes == 0, "each rock type is seeded differently")

-- 3. …and each declares a real region and a LOD chain, nearest band first.
local well_formed = true
for _, o in ipairs(created) do
  if not (o.center and o.radius and o.perChunk and o.perChunk > 0) then well_formed = false end
  if not (o.lod and #o.lod == 2 and o.lod[1].distance < o.lod[2].distance) then
    well_formed = false
  end
  if not (o.fade and o.fade > 0) then well_formed = false end
end
ok(well_formed, "every source declares a region, a density and a near→far LOD chain")

-- 3b. EVERY MESH IT NAMES IS ON DISK. A mistyped asset path costs nothing at
-- load and draws nothing at all — a field that is simply, silently absent. This
-- is the one part of "does it look right" that can be answered offline.
local missing_assets = {}
for _, o in ipairs(created) do
  for _, band in ipairs(o.lod) do
    local fh = io.open("solar/" .. band.asset, "r")
    if fh then fh:close() else missing_assets[#missing_assets + 1] = band.asset end
  end
end
ok(#missing_assets == 0,
  "every scattered mesh exists: " .. table.concat(missing_assets, ", "))

-- 3c. THE RESIDENCY BUDGET. This is the one that matters most, because getting
-- it wrong does not look like a bug — it looks like the engine being slow.
--
-- The first version of this field shipped far = 700 at chunk = 22 and swept
-- 4,489 chunks per source, four sources: about 211,000 props settled onto the
-- ground with a ray. The game froze on arrival and hitched whenever the player
-- turned the camera, because orbiting one drags new chunks in.
--
-- What is asserted here is NOT arithmetic — the script no longer does any. It
-- is that the field asks `scatter.cost`, believes the answer, and stays inside
-- its declared cap.
local worst, total_props = 0, 0
for _, o in ipairs(created) do
  local c = _G.cost_model(o.lod[#o.lod].distance, o.chunk, o.radius)
  worst = math.max(worst, c)
  total_props = total_props + c * o.perChunk
end
ok(worst <= _G.params.max_chunks,
  string.format("no source exceeds the chunk budget (%d resident, cap %d)",
    worst, _G.params.max_chunks))
ok(_G.chunksPerSource == worst,
  string.format("the field publishes the residency the ENGINE reported (%d vs %d)",
    _G.chunksPerSource, worst))
ok(_G.farUsed == _G.params.far,
  "a field that fits keeps the reach it asked for")
ok(total_props < 20000,
  string.format("the whole field stays under 20k props — got %d", total_props))

-- 3d. …AND IT OBEYS AN ANSWER IT DOESN'T LIKE. Hand the script a world where
-- the reach it wants costs three times the cap, and it has to pull `far` in and
-- ask again rather than ship the field that froze the game.
--
-- This is the negative control for the whole section above: without `fit_far`
-- the cap is never consulted and this fails on the first assertion.
--
-- (Via the moon and back, because a field is only rebuilt when the world under
-- you changes — which is the other thing this proves.)
local honest = _G.cost_model
here = moon
tick(2)

local greedy = 0
_G.cost_model = function(far, chunk, radius)
  greedy = greedy + 1
  return honest(far, chunk, radius) * 3   -- every chunk costs three of anyone else's
end
here = planet
created = {}
tick(2)
ok(_G.chunksPerSource <= _G.params.max_chunks,
  string.format("an over-budget field is pulled in until it fits (%d, cap %d)",
    _G.chunksPerSource, _G.params.max_chunks))
ok(_G.farUsed < _G.params.far,
  string.format("…by shortening the reach (%.0f, asked for %.0f)",
    _G.farUsed, _G.params.far))
ok(greedy > 1, "…which means it asked more than once")
ok(_G.sources == 4, "…and there is still a field afterwards")
-- Every rejected attempt must be destroyed, or the retries pile up invisible
-- sources that cost exactly what the retry was avoiding.
local live_sources = 0
for _ in pairs(SOURCES) do live_sources = live_sources + 1 end
ok(live_sources == 4,
  string.format("…with no abandoned source left running (%d live)", live_sources))
-- The LIVE sources, not `created` — which also holds the attempts that were
-- measured and thrown away, and those are supposed to be at a longer reach.
local all_at_fitted_reach = true
for _, s in pairs(SOURCES) do
  if s.opts.lod[#s.opts.lod].distance ~= _G.farUsed then all_at_fitted_reach = false end
end
ok(all_at_fitted_reach, "…and every kind was built at the reach that survived")

-- 3e. AND IT GIVES UP RATHER THAN SPINS. On a body smaller than the reach,
-- residency has already saturated at the planet — so shortening `far` buys
-- nothing, and no amount of retrying will get under a cap set below what the
-- whole moon costs. That is not a bug to solve, it is a moon: the field has to
-- stop asking and build something.
--
-- The failure this guards against is the retry loop that never converges, which
-- on a real arrival is a hang at exactly the moment the player lands.
_G.cost_model = function(far, chunk, radius) return honest(far, chunk, radius) * 40 end
here = moon
created = {}
tick(2)
ok(_G.sources == 4, "an impossible budget still ends up with a field, not a hang")
ok(#created <= 4 + 6, "…after a bounded number of attempts, not an unbounded one")

-- Back to the honest oracle and the home world for the rest of the file.
_G.cost_model = honest
here = planet
created = {}
tick(2)

-- 3d. DENSITY IS A PURE FUNCTION OF POSITION. The engine samples it once, at
-- declare time, so a rule that read game state would regrow a different world
-- on the second visit. Calling one twice with the same point must agree.
local stable = true
for _, o in ipairs(created) do
  if o.density then
    local a1 = o.density(0.3, 0.5, -0.2)
    local a2 = o.density(0.3, 0.5, -0.2)
    if a1 ~= a2 then stable = false end
    if type(a1) ~= "number" or a1 < 0 or a1 > 1 then stable = false end
  end
end
ok(stable, "every density rule is pure and returns 0..1")

-- 4. AIMING. `scatter.near` is the aim test — a raycast would not hit a prop.
-- Aim at where a rock actually is: with placement derived from each source's
-- own seed, "x = 3" is no longer a place any particular rock stands.
local function some_rock_pos()
  for _, s in pairs(SOURCES) do
    for _, it in ipairs(s.inst) do
      if not s.gone[it.id] then return it.pos.x, it.pos.y, it.pos.z end
    end
  end
end
local rx, ry, rz = some_rock_pos()
local hit = nearest(rx, ry, rz, 1.0)
ok(hit ~= nil, "a rock near the beam is found")
ok(hit and hit.kind and hit.kind.mat, "…and it knows what it's made of")

-- 5. BREAKING IT pays out through the ordinary material registry.
local mat, took = breakAt(hit, "astro")
ok(took and took > 0, "breaking a rock yields material")
ok(#added == 1 and added[1].mat == mat, "…into the pack, through inventory.add")
ok(nearest(rx, ry, rz, 0.4) == nil, "…and the rock is gone")

-- 6. THE LOSS IS SAVED AS IDS. Integers, not positions — which is what makes
-- permanence storable at all inside a ~1 KB save value.
local key
for k, v in pairs(SAVE) do
  if k:find("^rocks%.Ryilex%.") and type(v) == "table" and #v > 0 then key = k end
end
ok(key ~= nil, "the loss is written to the save")
ok(key and type(SAVE[key][1]) == "number", "…as an instance id, not a position")

-- 7. A FULL PACK COSTS YOU THE SWING, NOT THE BOULDER.
pack_full = true
local x2, y2, z2 = some_rock_pos()
local hit2 = nearest(x2, y2, z2, 1.0)
ok(hit2 ~= nil, "there is another rock to try")
local _, took2 = breakAt(hit2, "astro")
ok(took2 == 0, "a full pack takes nothing")
ok(nearest(x2, y2, z2, 0.4) ~= nil, "…and the rock is still standing")
pack_full = false

-- 8. CHANGING WORLDS tears the old planet's sources down and stands the new
-- one's up. A source left behind draws a planet's worth of rock around a body
-- you have flown away from.
local before = next_source
here = moon
astro.x, astro.y, astro.z = moon.x, moon.y + moon.radius, moon.z
tick(2)
ok(_G.bodyName == "Pelia", "arriving at a moon re-sites the field")
ok(next_source > before, "…with new sources")
local alive = 0
for _ in pairs(SOURCES) do alive = alive + 1 end
ok(alive == 4, "…and exactly four sources are live, not eight — got " .. alive)

-- 8b. UP AND AWAY. The engine unloads a field's chunks itself while the
-- camera is far above it (0.102), so a camera kilometres up — the orbit map,
-- a climbing rocket — leaves the fields declared. Tearing them down cost a
-- rebuild hitch on the way back down.
local cam = { valid = true, x = here.x, y = here.y + here.radius + 2, z = here.z }
local plain_find = _G.find
_G.find = function(n) if n == "Camera 1" then return cam end return plain_find(n) end
tick(2)
local function live_count()
  local n = 0
  for _ in pairs(SOURCES) do n = n + 1 end
  return n
end
ok(live_count() == 4, "a camera at the surface keeps the field — got " .. live_count())
cam.y = here.y + here.radius + 5000
tick(2)
ok(live_count() == 4, "a camera 5 km up leaves the field declared — got " .. live_count())
cam.valid = false
_G.find = plain_find

-- 9. REGROWTH. `scatter.restore` puts a whole source back in one call, so the
-- timer is the entire mechanism — and the save's loss list is dropped with it.
here = planet
astro.x, astro.y, astro.z = planet.x, planet.y + planet.radius, planet.z
tick(2)
local x3, y3, z3 = some_rock_pos()
local h3 = nearest(x3, y3, z3, 1.0)
if h3 then breakAt(h3, "astro") end
ok(nearest(x3, y3, z3, 0.4) == nil, "…broken again")
_G.time = _G.time + _G.params.regrow + 1
tick(1)
ok(nearest(x3, y3, z3, 0.4) ~= nil, "a broken field grows back on its timer")

-- 10. EVERY SOURCE IS ANCHORED TO ITS WORLD. `scatter.create` fixes its region
-- in WORLD space, and every world in this game orbits on rails at ~99 units/s —
-- so an UNANCHORED field is entirely behind its planet within three seconds.
-- That shipped, and was reported as the props being left behind.
--
-- `parent` (floptle/0073, filed from this file, engine v0.32.0) moves placement
-- into the body's frame instead. What is asserted is that the field always uses
-- it, and refuses to build at all when it cannot.
-- The LIVE sources: `created` still holds everything ever declared, including
-- the moon's from the world-change test and the attempts the budget rejected.
local anchored_all, anchored_n = true, 0
for _, s in pairs(SOURCES) do
  anchored_n = anchored_n + 1
  if s.opts.parent ~= _G.bodyName then anchored_all = false end
end
ok(anchored_n == 4 and anchored_all,
  "every live source is parented to the world it is scattered on")
ok(_G.anchored == true, "…and the field says so")

-- …and a world with no scene node to anchor to gets NOTHING, loudly. An
-- unanchored field on a moving world is the original bug, and it must not be
-- able to come back by simply failing to find its planet.
local orphan = { name = "Rails", x = 0, y = 0, z = 0, radius = 180 }
WORLDS.Rails = { kind = "rock", seed = 5, radius = 180 }
local prev_body, prev_find = _G.space.body, _G.find
_G.space.body = function(n) if n == "Rails" then return orphan end return prev_body(n) end
_G.find = function(n) if n == "Rails" then return nil end return prev_find(n) end
here = orphan
astro.x, astro.y, astro.z = 0, 180, 0
created = {}
tick(2)
ok(_G.anchored == false, "a world with no scene node cannot be anchored to")
local rails_live = 0
for _ in pairs(SOURCES) do rails_live = rails_live + 1 end
ok(rails_live == 0, "…so no rock is scattered onto it — got " .. rails_live .. " sources")
ok(_G.bodyName == "Rails", "…and the field still says which world it is on")
_G.find = prev_find

if #failures == 0 then
  report("MINERAL SMOKE OK — " .. checks .. " checks passed")
  os.exit(0)
else
  report("MINERAL SMOKE FAILURES:")
  for _, f in ipairs(failures) do report("  \xe2\x9c\x97 " .. f) end
  os.exit(1)
end
