# Positions, frames and aiming in Solar

Read this before writing any code that aims, draws a line or marker at
something, steers toward something, caches a point, or measures a speed. The
same family of bugs has been fixed many times: the gravity gun facing the sky,
the target line pointing into space, the warp limit falling as the warp rose,
thrust a hull-width off the engines, links blinking. Every one came from
breaking one of the rules below.

## Why it's hard here

- **Everything moves, all the time.** The home planet travels 1.5–6 m per tick
  on its rails, and craft in orbit move hundreds of m/s. A world point read
  this tick is the wrong place by the next tick, and it is metres off a frame
  later.
- **Each node has two positions:**
  - **The drawn pose**: `node.x/y/z`, `node.worldPos`, `node:toWorld(v)`.
    This is where the node is drawn this frame, between ticks, and every handle
    to the node agrees on it.
  - **The tick pose**: `node.tickPos`, and for a craft `assembly.info(root).origin`
    and `.right/.up`. This is where the simulation has it, up to one tick of
    travel away.
- **A node's own axes and position can lag the rails carry.** On a craft,
  `node.x` and `basis(node)` were measured 3.4 m behind in orbit
  (vessel_controller.lua `partFrameNow`, `base_of`).
- **World velocities include the planet's orbit.** A parked rover "moves"
  hundreds of m/s in world terms.

## The rules

1. **Never keep a world position across frames.** Anything that lives longer
   than this frame is stored relative to its body, or in a part's frame:
   - a lock, an aim, an IK target, a cached hit, a coroutine's centre, a
     waypoint, a preview.

   Convert it back to world at the moment you use it.
   - **Body-relative:** `name = space.dominant(x,y,z)`, `b = space.body(name)`,
     then store `x - b.x` and so on.
     - Planets only translate, so this is exact.
     - Helpers: `to_body`/`to_world` (tool_belt.lua), `carry_mark`/`carry_since`
       (tool_belt.lua, for caches), comms.lua's pinned nodes and `place()`.
   - **Part-relative** (a point on a craft that turns): store it in the part's
     frame, and place it with `partFrameNow(uid)` (vessel_controller.lua).

2. **Mix only positions from the same read and the same pose.** When you
   compute a direction from A to B, take both A and B from the same moment:
   - **For drawing** (lines, markers, HUD tags, camera, poses in lateUpdate):
     use drawn poses for both ends, i.e. `node:toWorld`, `node.x`, and body
     points placed against `space.body()` read in the same pass.
   - **For physics and steering** (forces, SAS targets, thrust points, anything
     in fixedUpdate): use tick poses for both ends, i.e. `node.tickPos`,
     `assembly.info(root).origin/right/up/com`, and `partFrameNow`.
   - **Never draw a line from a tick pose to a drawn pose**, or steer from a
     drawn pose to a tick pose. That one-tick gap is metres here.
   - **When several bodies are involved** (comms, coverage, targeting across
     worlds), read `space.bodies()` **once** and place everything against that
     single read.

3. **In fixedUpdate, read and write `tickPos`.** Never write `node.x` there;
   that teleports the body to its drawn place.

4. **Measure velocities and speeds relative to the local body.** Subtract the
   body's `vx,vy,vz` (from `space.body`) before comparing, limiting or showing a
   speed. Use game time (`space.time()`), not real seconds, for anything that
   must hold under time warp.

5. **Re-derive aims every frame from what's live now.**
   - Recompute an aim ray from the camera's current pose: planet_camera
     publishes `fwd`/`cam`.
   - Turn a body or arm toward the target as it is now: `tool_belt.aimNow()`
     returns this frame's world point, not one cached from the last update.

6. **Probe and screenshot cameras go in lateUpdate**, after the game has placed
   everything for the frame.

## Recipes

**Hold a point on the ground** (a waypoint, a dig spot, a plant):

```lua
local held = to_body(hit)          -- { body = "Naolol", x,y,z = offset from its centre }
-- … later, any frame:
local w = to_world(held)           -- world point where it is now
```

**Hold a point on a craft** (a docking port, a repair spot):

```lua
local F = partFrameNow(uid)        -- this tick's frame of that part (origin + axes)
local wx = F.ox + F.rx*lx + F.ux*ly + F.zx*lz   -- lx,ly,lz stored in the part's frame
```

**Draw a line from our craft to a target** (lateUpdate):
- Both ends must be drawn poses from this frame: our part via
  `node:toWorld(localPoint)`, the target via its node's `toWorld`, or via its
  body-relative point placed against this frame's `space.body()`.
- Before calling it done, check that the line ends on the target in a
  screenshot.

**Steer toward a target** (fixedUpdate):
- Both ends are tick poses: `assembly.info(root)` for us, and `partFrameNow`
  (or the target craft's `assembly.info`) for them.
- Measure the error against the same vectors the drawing uses, converted to the
  same pose, so "aligned 0°" means aligned on screen too.

**A cached result reused for a few frames** (a 0.1 s preview, a raycast cache):
- Call `carry_mark(cache, point)` when you fill it.
- Call `carry_since(cache, {…})` before you use it.

## Bugs this caused, so you can recognise them

| Symptom | Cause | Fix |
|---|---|---|
| The gravity gun turned the crew to face the sky while pulling a plant to its left | Faced `tb.aimX`, a world point from the previous update | `aimNow()` (body-relative), `carry_since` on previews |
| The targeting / docking lines ran off into space | Line ends from different poses or frames | Rule 2 |
| Thrust a hull-width off the engines; SAS fought a phantom torque forever | `node.x`/basis lag the rails carry | `base_of`, `assembly.info().origin` |
| The warp limit fell as the warp rose; parked craft were dropped to 10x | Speed taken in the world frame, divided by real seconds | Rule 4: body-relative, `space.time()` |
| Coverage swung 0–45%; links blinked | Relays and stations placed against different reads of the bodies | Rule 2: one `space.bodies()` read |
| Boarding rings drawn beside the ship | Drawn with node coords that lag the carry | Tick or drawn pose consistently |
| Plants appearing, sliding and vanishing at the base | Sources redeclared with world-frame props | Keep scatter edits in the planet frame |

## Review checklist (code and screenshots)

- [ ] Nothing stores a world position past this frame.
- [ ] Every direction or line is built from two points of the same pose, read in
      the same pass.
- [ ] fixedUpdate uses tick poses; lateUpdate and drawing use drawn poses.
- [ ] Speeds are body-relative, and timing that must survive warp uses game time.
- [ ] **In the screenshots, every line, marker and aim ends ON its target**, from
      at least two angles, while moving (in orbit or on the moving planet), not
      only at rest.
