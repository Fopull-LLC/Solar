-- ATMOSPHERE — the air, drawn.
--
-- Every world in this game already HAS an atmosphere: the generator rolls its
-- colour, its height and its density, and the sky shader draws the halo you see
-- from orbit. On the ground, none of that existed. Standing on a world with a
-- thick blue sky, the far hills were as sharp as the near ones and the horizon
-- cut against black — the atmosphere was something you could only see from
-- outside it, which is exactly backwards.
--
-- This script is the inside of that same air. It reads the body you are at,
-- reads how high above it you are, and drives the scene's fog from the two:
--
--   * in space           no fog at all — vacuum is not hazy, and a fogged
--                        starfield is the single fastest way to make a space
--                        game look like grey soup
--   * entering the air   fog fades UP from nothing as you descend through the
--                        atmosphere's own published height, so re-entry has a
--                        visible skin rather than a switch
--   * on the ground      full depth fog in the body's OWN atmosphere colour,
--                        so distance reads and the horizon has somewhere to go
--
-- A vacuum world (`atmo = 0`) gets nothing, and that is the point: an airless
-- moon should look airless, and the difference between the two should be
-- something you can see from the cockpit before you check an instrument.
--
-- Sunlight through the air is the same fact seen the other way, so the light
-- shafts and the volumetric scattering ride the same curve.
--
-- The one node in the scene is the scene's own Lighting node, which the loader
-- always makes, so this script needs nothing authored to work.

defaults = {
  --- Master switch, so a scene can turn the whole effect off without unwiring.
  on = true,
  --- How far you can see, in metres, in the thickest air at ground level.
  --- Deliberately generous: fog is for depth, not for hiding the world.
  --@range 200 20000
  range = 2600.0,
  --- The fraction of `range` where the fog starts. Below this, nothing hazes,
  --- so the cockpit and the thing you are mining stay crisp.
  --@range 0.0 0.9
  nearFrac = 0.12,
  --- Multiplies the body's published atmosphere height to decide where the
  --- haze begins fading in on the way down. >1 gives a longer, softer entry.
  --@range 0.5 4
  entry = 1.6,
  --- Volumetric scattering: real light marched through the media. Prettier and
  --- more expensive; the shafts through a valley are worth it.
  volumetric = true,
  --- Sun shafts (god rays) where the light is broken by terrain.
  shafts = true,
  --- Density of the volumetric media per world unit, at full atmosphere.
  --@range 0.0 0.2
  density = 0.022,
  --- How much the media throws light toward the sun. Positive blooms around
  --- the star; 0 is an even haze.
  --@range -0.9 0.9
  anisotropy = 0.55,
  --- How fast the look follows the world, in units per second of blend. Low
  --- enough that a fast descent does not pop, high enough that it keeps up.
  --@range 0.1 10
  ease = 2.2,
  --- Print what the air is doing, once a second. For tuning and for `run`.
  debug = false,
}

-- The Lighting node's component, resolved once. Every scene has exactly one and
-- the loader makes it, so this cannot come back nil in a loaded scene — but it
-- is still checked, because a script that assumes is a script that raises.
local lightNode, lit

-- graphics.lua, resolved once (findScript walks the scene).
local gx_ref

-- The eye. The camera is the right anchor here and NOT the crew: this is about
-- what is being LOOKED THROUGH, so an orbit-map view pulled far out of the
-- atmosphere must lose the fog even though the crew is still standing in it.
--
-- `planet_camera` publishes its own eye as `cam_x/y/z` (the same numbers the
-- tool belt aims along), which is the only place the view position is readable
-- from Lua — the `camera` table answers questions about the SCREEN, not about
-- where the screen is. Falls back to the crew, then to this node.
local cam_ref
local function eye()
  if not cam_ref or not cam_ref.valid then cam_ref = findScript("planet_camera") end
  if cam_ref and cam_ref.valid and cam_ref.cam_x then
    return cam_ref.cam_x, cam_ref.cam_y, cam_ref.cam_z
  end
  local a = find("Astronaut")
  if a and a.valid then return a.x, a.y, a.z end
  return nil
end

-- Blended state, so nothing snaps.
local cur = { amt = 0.0, r = 0.6, g = 0.7, b = 0.9, start = 0, stop = 1e6 }
local dbg_t = -100

-- The air at a point: how much of it there is (0..1) and what colour it is.
--
-- `save.world.<name>` is the generator's own record and the best answer. A body
-- with no record — an authored scene, or a world the generator never rolled —
-- falls back to NO air rather than to a guess: inventing an atmosphere for a
-- world whose designer did not give it one is worse than drawing none.
local function air_at(x, y, z)
  local dom = space.dominant(x, y, z)
  if not dom then return 0 end
  local b = space.body(dom)
  if not b then return 0 end
  local w = save.get("world." .. dom)
  if not (w and (w.atmo or 0) > 0.01) then return 0 end

  local dx, dy, dz = x - b.x, y - b.y, z - b.z
  local alt = math.sqrt(dx * dx + dy * dy + dz * dz) - (b.radius or 1)
  -- The published atmosphere height, or a sane fraction of the radius for a
  -- record written before the height was published.
  local h = (w.atmoHeight or 0)
  if h <= 0 then h = (b.radius or 100) * 0.35 end
  h = h * math.max(0.1, params.entry or 1.6)

  -- 1 at the surface, 0 at the top of the air, squared so the thickening is
  -- felt in the last part of the descent rather than spread evenly over it.
  local t = 1.0 - math.max(0.0, math.min(1.0, alt / h))
  local amt = t * t * math.max(0.0, math.min(1.0, w.atmo or 0))
  return amt, (w.atmoR or 0.55), (w.atmoG or 0.68), (w.atmoB or 0.92), b.radius or 100
end

-- Resolved LAZILY rather than in `start`.
--
-- The Lighting node is not authored in the scene file — the loader spawns it —
-- so it is not necessarily there yet when a script's `start` runs, and asking
-- once at start and giving up got exactly one line of "no Lighting node in
-- this scene" and no fog for the rest of the session. Ask every frame until
-- the answer arrives, then stop asking.
local warned = false
local function lighting()
  if lit and lightNode and lightNode.valid then return lit end
  lightNode = find("Lighting")
  lit = lightNode and lightNode:getcomponent("Light") or nil
  if not lit and not warned and time > 5.0 then
    warned = true
    -- Once, and only once. As of this writing `find("Lighting")` cannot
    -- succeed from a game script at all: the loader spawns that node with a
    -- Name and a Light and no Transform, and the script mirror is built from
    -- `query::<Transform>()`, so the node the docs promise is always there is
    -- never in the mirror (platform 0159). Nothing here needs to change when
    -- that lands — the handle is asked for every frame until it arrives, so
    -- the air simply starts being drawn.
    print("atmosphere: the scene's Lighting node is not reachable from Lua on "
      .. "this engine build (platform 0159) — the air is not drawn")
  end
  return lit
end

function update(node, dt)
  local lit = lighting()
  if not lit then return end
  if params.on == false then
    if cur.amt > 0.001 then
      cur.amt = 0
      lit.fog = false
      lit.fogVolumetric = false
      lit.fogShafts = false
    end
    return
  end

  local ex, ey, ez = eye()
  if not ex then ex, ey, ez = node.x, node.y, node.z end
  local amt, r, g, b, rad = air_at(ex, ey, ez)
  amt = amt or 0

  -- Ease toward the target. Colour eases too, so crossing an SOI from a green
  -- world to a red one is a fade rather than a cut.
  local k = math.min(1.0, (params.ease or 2.2) * dt)
  cur.amt = cur.amt + (amt - cur.amt) * k
  if amt > 0.001 then
    cur.r = cur.r + ((r or cur.r) - cur.r) * k
    cur.g = cur.g + ((g or cur.g) - cur.g) * k
    cur.b = cur.b + ((b or cur.b) - cur.b) * k
  end

  -- Under this there is no air worth drawing, and the fog is switched OFF
  -- rather than merely made thin: a fog volume with nothing in it still costs
  -- its pass, and in space that pass buys a picture that is worse.
  if cur.amt < 0.01 then
    lit.fog = false
    lit.fogVolumetric = false
    lit.fogShafts = false
    return
  end

  -- Thicker air = you can see less far. The far plane is pulled in as the
  -- amount rises, floored so the thickest atmosphere is still a place you can
  -- fly through rather than a wall.
  local far = (params.range or 2600.0) * (1.0 - 0.55 * cur.amt)
  local near = far * math.max(0.0, math.min(0.9, params.nearFrac or 0.12))
  -- Never fog closer than the world is big: on a 100 m moon a 300 m near plane
  -- would put the whole planet inside the clear zone and nothing would show.
  if rad and near > rad * 0.5 then near = rad * 0.5 end

  lit.fog = true
  lit.fogColorR, lit.fogColorG, lit.fogColorB = cur.r, cur.g, cur.b
  lit.fogStart, lit.fogEnd = near, far
  lit.fogDither = true
  lit.fogDitherStrength = 0.6

  -- The graphics level has the last word: volumetric fog with sun shafts was
  -- 46 ms of a 1080p frame on a mid-range card (see graphics.lua), so Low and
  -- Medium draw the same air as a distance ramp instead.
  if not gx_ref or not gx_ref.valid then gx_ref = findScript("graphics") end
  local gx_vol = (not gx_ref) or gx_ref.volumetric
  local gx_shafts = (not gx_ref) or gx_ref.shafts
  if params.volumetric ~= false and gx_vol then
    lit.fogVolumetric = true
    lit.fogDensity = (params.density or 0.022) * cur.amt
    lit.fogAnisotropy = params.anisotropy or 0.55
    lit.fogLight = 1
    lit.fogShafts = (params.shafts ~= false) and gx_shafts
  else
    lit.fogVolumetric = false
    lit.fogShafts = false
  end

  if params.debug and time - dbg_t > 1.0 then
    dbg_t = time
    print(string.format("atmosphere: air %.2f  fog %.0f..%.0f  rgb %.2f %.2f %.2f",
      cur.amt, near, far, cur.r, cur.g, cur.b))
  end
end
