-- MINERAL FIELD — the rock lying on a planet's surface, and the ore you can
-- break off it without digging a hole.
--
-- Between the colony buildings, every world in this game used to be a bare
-- shell: terrain, and nothing standing on it. That reads as unfinished long
-- before a player can say why — there is no sense of scale on ground with
-- nothing on it, and nothing to walk toward.
--
-- This is the engine's `scatter` system doing the whole job. A source is a RULE
-- — seed, region, density, meshes — and the engine derives every instance from
-- `hash(seed, chunk, index)` and draws them GPU-instanced, with no scene node
-- anywhere in it. Which is why this file is two hundred lines and puts rock to
-- the horizon, while the flora field beside it is nine hundred and manages
-- ninety plants inside a fifty-five-metre bubble. (Flora can't move over yet:
-- its plants are generated from primitives, and a scatter prototype has to be a
-- mesh file — floptle/0065.)
--
-- BREAKING ROCK. Scattered props have no colliders, so a raycast will never hit
-- one; `scatter.near` is the aim test, which is exactly what the API intends.
-- The mining laser asks this script what its beam is touching, and a hit pays
-- out through the same material registry everything else in the game uses.
--
-- WHAT'S GONE STAYS GONE — and costs almost nothing to remember. An instance id
-- is derived from (seed, chunk, index), so `scatter.removed` is a handful of
-- numbers rather than the position of every rock you ever broke. That is what
-- makes permanence storable at all: save values are capped around a kilobyte,
-- and the flora field regrows on a timer precisely because it could not store
-- its own losses. This one can.
--
-- Cross-script:  local mf = findScript("mineral_field")
--                mf.nearest(x, y, z, radius)   mf.breakAt(hit, "astro")

-- ⚠ THE COST OF THIS FIELD IS ROUGHLY QUADRATIC IN `far / chunk`, up to the
-- size of the planet. Read this before touching either number.
--
-- Residency is a sweep around the camera whose reach is the OUTERMOST `lod`
-- distance, walked to decide which chunks stay loaded, and every prop in a
-- newly loaded chunk is raycast onto the real ground so it settles rather than
-- floats. So `far` is not "how far you can see rock" — it is the budget.
--
-- The first version of this file shipped `far = 700, chunk = 22` and swept
-- 4,489 chunks per source, four sources: the game froze on arrival and hitched
-- every time the player turned to look. That is floptle/0071, filed from this
-- file, and the engine answered it in v0.31.0 — residency now stops at the body
-- (700 m of reach on a 214 m world is 700 m of nothing), ground arrives nearest
-- first over several frames instead of all in one, and the count is no longer
-- recomputed while you stand still.
--
-- WHICH MEANS THE NUMBER IS ASKABLE NOW. `fit_far` below asks `scatter.cost`
-- what a source actually wants and pulls `far` in until the answer fits
-- `max_chunks`. This file used to restate the engine's arithmetic in Lua to get
-- that number, and the restatement was WRONG in the safe direction — it said 225
-- chunks where the engine keeps between 81 and 225 depending on how big the
-- planet is, because it knew nothing about the body clamp or the corner cull.
-- Do not put that formula back. Ask.
defaults = {
  --@header Density
  -- Props rolled per chunk, before each kind's own multiplier. This is how
  -- CLUTTERED the ground looks — not how far it reaches.
  --@range 0 60
  per_chunk = 14,
  -- Chunk size in metres. BIGGER is cheaper: it divides `far` in the sweep
  -- above, so halving this quadruples the number of resident chunks.
  --@range 16 64 --@units m
  chunk = 34.0,

  --@header Look
  -- How far the detailed mesh is used before the cheap one takes over.
  --@range 20 200 --@units m
  near = 60.0,
  -- How far anything is drawn at all — and, because residency follows the
  -- outermost band, the number that sets the whole field's cost. Asked for, not
  -- guaranteed: `fit_far` pulls it in if the engine says it costs too much.
  --
  -- THIS IS THE ONE TO TURN DOWN if the surface ever hitches again.
  --
  -- 190 was the number that made the game playable again after this file broke
  -- it, and it was deliberately short. v0.31.0 pays for some of it back: ground
  -- now arrives nearest-first over several frames instead of all on the one
  -- frame a patch appears, and residency stops recomputing while you stand
  -- still. Where you can SEE this far is from the air — the horizon on a 214 m
  -- world is under thirty metres on foot but two hundred and fifty from a
  -- landing approach, which is the shot this game keeps putting you in.
  --
  -- It costs less than it reads: residency saturates at the body, so on a 100 m
  -- moon 240 is identical to 190 (81 chunks either way) and only the largest
  -- worlds pay, at 225 → 289. `scatter.cost` is what says so, per world, in the
  -- Console line at the bottom of `build`.
  --@range 50 400 --@units m
  far = 240.0,
  -- Metres over which one LOD band cross-dissolves into the next. The pop at a
  -- band boundary is the thing everyone notices about scatter and nothing else.
  --@range 0 40 --@units m
  fade = 16.0,

  --@header Budget
  -- The most chunks one source may keep resident, checked against what
  -- `scatter.cost` says it will actually be. A configuration over this is pulled
  -- in and says so, rather than freezing the game — which is exactly what the
  -- first version of this file did.
  --
  -- The honest ceiling for the settings above is 225, on the largest world the
  -- generator makes (radius 230); the smallest comes to 81. 320 is therefore
  -- slack for a bigger `far`, and still bites long before anything hitches.
  --@range 25 2000
  max_chunks = 320,

  --@header Harvest
  -- How close the beam has to pass to a rock to break it.
  --@range 0.5 6 --@units m
  grab = 2.2,
  -- Seconds before a broken field grows back. Long, because a base's
  -- surroundings SHOULD strip out — that's the reason to fly somewhere else.
  --@range 0 100000 --@units s
  regrow = 2400.0,

  enabled = 1,
}

-- Published for the HUD and the smoke harness.
bodyName = nil
sources = 0

-- ── what grows where ────────────────────────────────────────────────────────
--
-- One source per rock TYPE, because a scatter source draws one prototype (or
-- one LOD chain) and nothing else. They overlap on the same ground with
-- different seeds, which is what gives a mixed field: boulders sparse, gravel
-- common, crystal rare and only where the crust is right.
--
-- `density` is what makes a field a PLACE rather than a texture: it returns
-- 0..1 for a point on the unit sphere, and zero means the prop is never
-- generated — so it is a look and a cost at the same time. Rock confined to a
-- few outcrops is a fraction of the props of rock everywhere, and it is also
-- the only version that reads as geology.
--
-- These rules are PURE functions of position, and have to be: the engine samples
-- them once, at declare time, and placement has to stay derivable or walking
-- away and coming back regrows a different world. Nothing in here reads the
-- climate script, the time, or anything else that could answer twice.
--
-- (This is floptle/0064, filed from this project and shipped in engine v0.29.0.
-- Before it, every source was even across the whole planet and the only knob
-- was how much of it there was.)
local KINDS = {
  {
    id = "gravel", mat = "regolith", per = 1.0, scale = { 0.5, 1.1 },
    lod = { "models/space-kit/rocks_smallA.glb", "models/space-kit/rocks_smallB.glb" },
    yield = 1,
    -- Everywhere, thinning a little on the flats — loose surface material is
    -- the reason the ground stops reading as a bare shell.
    density = function(x, y, z)
      return 0.55 + 0.45 * math.abs(math.fbm(x * 3.0, y * 3.0, z * 3.0, 3))
    end,
  },
  {
    id = "stone", mat = "silica", per = 0.55, scale = { 0.8, 1.6 },
    lod = { "models/space-kit/rock.glb", "models/space-kit/rocks_smallA.glb" },
    yield = 2,
    -- Broken ground: patchy at a coarser scale than the gravel, so the two
    -- don't share a silhouette.
    density = function(x, y, z)
      return math.saturate(math.fbm(x * 1.7 + 11.0, y * 1.7, z * 1.7, 3) * 1.6)
    end,
  },
  {
    id = "boulder", mat = "iron", per = 0.22, scale = { 1.1, 2.4 },
    lod = { "models/space-kit/rock_largeA.glb", "models/space-kit/rock_largeB.glb" },
    yield = 3,
    -- Boulder fields, with real gaps between them.
    density = function(x, y, z)
      local n = math.fbm(x * 1.1 - 31.0, y * 1.1, z * 1.1, 2)
      return math.saturate((n - 0.15) * 2.2)
    end,
  },
  {
    id = "crystal", mat = "crystal", per = 0.05, scale = { 0.7, 1.4 },
    lod = { "models/space-kit/rock_crystalsLargeA.glb", "models/space-kit/rock_crystals.glb" },
    yield = 2,
    -- The good stuff, and now genuinely a PLACE: a handful of outcrops per
    -- world rather than an even sprinkle. Finding one should be an event, and
    -- it is the one surface material worth flying home for on its own.
    density = function(x, y, z)
      local n = math.fbm(x * 2.3 + 77.0, y * 2.3, z * 2.3, 2)
      return math.saturate((n - 0.52) * 6.0)
    end,
  },
}

-- Cross-script singletons, resolved once and kept: `findScript` walks the whole
-- scene (floptle/0063), and asking every frame is what made this project do a
-- hundred scans a frame.
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

-- Live sources on the body we're standing on: kind id → { id, kind }.
local live = {}
local cur_body = nil
local next_regrow = 0

-- A SCATTER SOURCE RIDES ITS WORLD, and every world here moves.
--
-- `scatter.create{ center = ... }` fixes the region in WORLD space at the moment
-- you declare it. On a planet orbiting at 99 units per second — which the spawn
-- world does — a field of reach 240 is entirely behind the planet two and a half
-- seconds after it is declared, and the rocks stay where the planet was. This
-- shipped, and was reported as the props being left behind by the planet.
--
-- `parent` (floptle/0073, filed from this file, engine v0.32.0) is the fix, and
-- it is the good version of it: placement moved into the BODY's frame rather
-- than the props being moved through the world. Every instance id, every settled
-- ground height and the whole removal set are expressed relative to the anchor,
-- so following its planet costs one transform per source per frame — no
-- reseeding, no re-settling, nothing harvested forgotten.
--
-- `anchored` is still published and still checked, because a field with no
-- anchor on a body that moves is the bug above, and it must not be able to come
-- back silently.
bodyMotion = 0.0
anchored = false
-- nil = not yet asked, true/false = this editor build takes `parent` or doesn't.
local anchor_ok = nil

-- How much drift a source may see and still be trusted unanchored. Half a chunk
-- over a second: below that a source outlives its own LOD fade, above it the
-- props visibly swim.
local DRIFT_LIMIT = 0.5

-- Published so the HUD and the smoke harness can read the budget rather than
-- trust it. These are what the ENGINE says, not what this file predicted.
chunksPerSource = 0
propsPerSource = 0
farUsed = 0

-- Declare one source, ask what it costs, and pull `far` in until the answer
-- fits — the whole point of floptle/0071, which this file is the reason for.
--
-- `declare(far)` builds a source and hands back its id; every kind shares the
-- same geometry (chunk, radius, reach), so measuring the first one measures all
-- four and the rest are built at whatever `far` survived.
--
-- Shrinking by 0.7 rather than solving for a reach: the relationship between
-- `far` and the count is not a formula this file gets to know any more — the
-- engine culls corners and stops at the body — so the honest move is to ask
-- again. It converges in two or three tries from anything sane, and the attempt
-- cap means a pathological setting still ends up with a field rather than a
-- hang.
local function fit_far(declare)
  local cap = math.max(25, math.floor(params.max_chunks))
  local floor_far = math.max(params.chunk, 20.0)
  local far = math.max(floor_far, params.far)
  for attempt = 1, 6 do
    local id = declare(far)
    local cost = scatter.cost(id)
    local chunks = (cost and cost.chunks) or 0
    if chunks <= cap or attempt == 6 or far <= floor_far then
      chunksPerSource, propsPerSource, farUsed = chunks, (cost and cost.props) or 0, far
      return id, far
    end
    -- Over budget: this source never draws a frame.
    scatter.destroy(id)
    local next_far = math.max(floor_far, far * 0.7)
    print(string.format(
      "mineral field: far=%.0f at chunk=%.0f keeps %d chunks resident (cap %d) — retrying at far=%.0f",
      far, params.chunk, chunks, cap, next_far))
    far = next_far
  end
end

-- The save key for a body's losses. Per SLOT already, because `save.*` is.
local function loss_key(body, kind)
  return string.format("rocks.%s.%s", body, kind)
end

local function tear_down()
  for _, s in pairs(live) do scatter.destroy(s.id) end
  live, sources, cur_body, bodyName = {}, 0, nil, nil
end

-- Stand a body's fields up. Placement is a pure function of the seed, so this
-- is idempotent in the only sense that matters: the same world always grows the
-- same rocks, on every machine and in every session.
local function build(body, w, anchor)
  local seed = math.floor(w.seed or 1)
  -- A world with no crust to speak of gets nothing: a gas body's "surface" is
  -- not somewhere rocks lie on.
  local rocky = (w.kind ~= "gas")
  if not rocky then return end
  -- A density of zero is how you turn the field off from the Inspector without
  -- unloading the script; below one, nothing would round up to a prop anyway.
  if params.per_chunk < 1 then return end

  local R = w.radius or body.radius or 100

  -- One kind's source, at a given reach. Pulled out of the loop below because
  -- `fit_far` has to be able to build the first one MORE THAN ONCE, throwing
  -- away any that costs too much.
  local function declare(ki, k, far)
    local near = math.min(params.near, far * 0.6)
    local per = math.max(1, math.floor(params.per_chunk * k.per + 0.5))
    local opts = {
        -- Distinct seeds per kind, or every source puts its prop in exactly the
        -- same places and the "field" is four meshes in a stack.
        --
        -- This offset is the kind's INDEX. It was `#k.id` — the length of the
        -- name — which collides the moment two names are the same length, and
        -- "boulder" and "crystal" are both seven. Every crystal outcrop in the
        -- game grew inside a boulder, and breaking one left the other standing
        -- in the same spot.
        seed = seed * 31 + ki * 7919,
        center = vec3(body.x, body.y, body.z),
        radius = R,
        perChunk = per,
        chunk = params.chunk,
        align = "surface",   -- a hillside's rocks lean with the hill
        scaleMin = k.scale[1], scaleMax = k.scale[2],
        fade = params.fade,
        lod = {
          { asset = k.lod[1], distance = near },
          { asset = k.lod[2], distance = far },
        },
        -- WHERE IT GROWS, at last. `density` returns 0..1 and zero means the
        -- instance is never generated — so this is a look AND a cost: crystal
        -- confined to a few outcrops is a tenth of the props of crystal
        -- everywhere, as well as being the right answer.
        --
        -- The rule is sampled once, at declare time, into a grid — so it must
        -- be a pure function of position. Nothing in here reads game state or
        -- another script, deliberately: placement has to stay derivable, or
        -- walking away and coming back regrows a different world.
        density = k.density and function(x, y, z)
          return k.density((x - body.x) / R, (y - body.y) / R, (z - body.z) / R)
        end or nil,
    }
    -- ANCHORED to the planet node, so the field rides the orbit instead of being
    -- left behind by it (floptle/0073). `center` is still the world point the
    -- region is built around; `parent` is what carries it afterwards.
    --
    -- ASKED FOR BY TRYING, because `scatter.create` refuses an option it does
    -- not know (v0.29.0) and an editor built before v0.32.0 does not know this
    -- one. Declaring it blind against an older binary is not a warning, it is a
    -- runtime error every frame per source — four thousand of them in one
    -- session — and no field. So: offer it once, read the refusal, and carry on
    -- without it, saying so.
    if anchor_ok ~= false then
      opts.parent = anchor.name
      local ok, id = pcall(scatter.create, opts)
      if ok then
        anchor_ok = true
        return id
      end
      anchor_ok = false
      print("mineral field: this editor build has no `scatter.create{ parent = }` "
        .. "(engine v0.32.0) — the field cannot follow its planet's orbit and "
        .. "will be left behind. Rebuild the editor. " .. tostring(id))
      opts.parent = nil
    end
    return scatter.create(opts)
  end

  -- Adopt a built source: file it, and put back what this save has already
  -- broken off it. `scatter.removed` stored the losses as instance ids, so this
  -- is a handful of integers rather than the position of every rock.
  local function adopt(k, id)
    live[k.id] = { id = id, kind = k }
    local gone = save.get(loss_key(body.name, k.id))
    if type(gone) == "table" then
      for _, inst in ipairs(gone) do scatter.remove(id, inst) end
    end
  end

  -- The first kind is what the budget is measured on; the rest follow at
  -- whatever reach survived.
  local first_id, far = fit_far(function(f) return declare(1, KINDS[1], f) end)
  adopt(KINDS[1], first_id)
  for ki = 2, #KINDS do
    adopt(KINDS[ki], declare(ki, KINDS[ki], far))
  end

  sources = 0
  for _ in pairs(live) do sources = sources + 1 end
  cur_body, bodyName = body.name, body.name
  -- One line per arrival, with the engine's numbers in it. A field that is
  -- costing more than you meant should be findable in the Console, not in a
  -- playtest — that lesson cost this project a release.
  print(string.format(
    "mineral field: %s (r=%.0f) — %d sources, %d chunks each at far=%.0f",
    body.name, R, sources, chunksPerSource, farUsed))
end

-- ── the tool-facing API ─────────────────────────────────────────────────────

-- The rock nearest a point, within `radius` — or nil. Returns everything the
-- caller needs to break it and to draw a highlight on it.
--
-- Scattered props have no colliders and a raycast will not hit one, so this
-- proximity query IS the aim test. The laser drives a cut point along its beam
-- and asks here at that point, which means pointing at a boulder breaks the
-- boulder rather than the ground behind it.
function nearest(x, y, z, radius)
  local best = nil
  for _, s in pairs(live) do
    local hits = scatter.near(s.id, vec3(x, y, z), radius or params.grab)
    local h = hits and hits[1]
    if h and (not best or h.distance < best.distance) then
      best = { source = s.id, kind = s.kind, id = h.id,
               pos = h.pos, distance = h.distance, scale = h.scale }
    end
  end
  return best
end

-- Break it: the yield goes to `cid`, the instance goes away for good, and the
-- loss is written to the save as a number rather than a position.
--
-- Returns the material id and how many units were actually taken (0 when the
-- pack is full, and the rock is left standing — a break that pays nothing must
-- not also destroy the rock).
function breakAt(hit, cid)
  if not hit then return nil, 0 end
  local inv, mats = ref("inventory"), ref("materials")
  if not (inv and mats) then return nil, 0 end
  local k = hit.kind
  local units = k.yield or 1
  local took = inv.add(cid or "astro", k.mat, units)
  if took <= 0 then return k.mat, 0 end

  scatter.remove(hit.source, hit.id)
  -- Remember the loss. `scatter.removed` is the sorted id list for the whole
  -- source — a handful of integers, which is the entire reason permanence is
  -- storable here and was not for the flora field.
  if cur_body then
    save.set(loss_key(cur_body, k.id), scatter.removed(hit.source))
  end
  return k.mat, took
end

-- ── driver ──────────────────────────────────────────────────────────────────

local function observer()
  local pw = ref("planet_walker")
  local astro = find("Astronaut")
  if astro and pw and pw.onFoot then return astro end
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.piloting and v.node and v.node.valid then return v.node end
  end
  return astro
end

function update(node, dt)
  if params.enabled == 0 then
    if cur_body then tear_down() end
    return
  end
  local gm = ref("game_manager")
  if gm and gm.loading then return end

  local obs = observer()
  if not obs then return end
  local bname = space.dominant(obs.x, obs.y, obs.z)
  local body = bname and space.body(bname)
  local cl = ref("climate")
  if not (body and cl) then
    if cur_body then tear_down() end
    return
  end
  -- The map's camera or a climbing rocket can be kilometres up. The engine
  -- keeps no chunks resident for a camera that far above the field, so the
  -- fields stay declared and there is nothing to rebuild on the way down.

  -- Changed worlds: drop the old planet's sources and stand the new one's up,
  -- ANCHORED to the body. `find(bname)` is the planet's own scene node, which is
  -- what the rails move — hand that to `scatter.create{ parent = }` and the whole
  -- field rides the orbit for one transform a frame.
  if bname ~= cur_body then
    tear_down()
    local anchor = find(bname)
    anchored = anchor ~= nil and anchor.valid == true
    if not anchored then
      -- A field with no anchor on a world that moves is the bug this file
      -- shipped once. It must not be able to come back quietly.
      print(string.format(
        "mineral field: no scene node named %s to anchor to — no surface rock "
        .. "here, because an unanchored field slides off an orbiting world "
        .. "(floptle/0073)", bname))
      cur_body, bodyName = bname, bname
      return
    end
    local w = cl.worldOf(bname)
    if w then build(body, w, anchor) end
    return
  end

  -- Regrowth. A field that never came back would strand a save whose base has
  -- been stripped bare, and `scatter.restore` puts a whole source back in one
  -- call — so this is a timer and two lines rather than a bookkeeping problem.
  if params.regrow > 0 and time >= next_regrow then
    next_regrow = time + params.regrow
    for kid, s in pairs(live) do
      local n = scatter.restore(s.id)
      if n and n > 0 then
        save.set(loss_key(cur_body, kid), nil)
        print(string.format("mineral field: %d %s regrew on %s", n, kid, cur_body))
      end
    end
  end
end

function start(node)
  next_regrow = time + params.regrow
end
