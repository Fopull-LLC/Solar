-- VAB FADE — the Vehicle Assembly Building thins away whatever would stand
-- between the camera and the craft, so the builder's camera can orbit a craft
-- bigger than the room through walls, catwalks and trusses.
--
-- The building is cut into CHUNKS (tools/gen_vab.py, tools/base_buildings.py):
-- VabInterior's "Fade *" children and FacHangar's "Ext *" children, each one
-- mesh whose materials carry retro dither_alpha. A chunk's opacity is written
-- per material (node:material(name).alpha); below 1 the engine drops pixels in
-- an ordered 4×4 screen door instead of blending, so a fading chunk stays in
-- the opaque pass (no sorting) and at 0 it is hidden outright (no draw).
-- (Since engine 0.117.0-rc8 an alpha below 1 turns a material's blend on,
-- except on a dither_alpha material, so these chunks stay dithered: checked
-- in the VAB on rc8 at 0.25 / 0.5 / 0.75.)
--
-- Two rules, the lower opacity wins:
--   NEAR      a chunk whose box comes within `near1` of the camera starts to
--             thin, and is gone inside `near0` (× the chunk's own factor: the
--             launcher under the craft only goes when the camera is right on it);
--   OCCLUDE   (when `occlude` is on) a chunk whose box a line from the camera
--             to the craft passes through is gone — the walls, platforms and
--             trusses in front of the craft, whichever side you look from. The
--             lines run to the craft's centre and to four points on its
--             silhouette (`radius` to either side across the view, `halfHeight`
--             above and below), so nothing stands in front of any of it.
-- Opacity eases toward that goal at `rate` per second, in steps of 1/8 (a
-- material write only when the step changes).
--
-- WHERE THE CAMERA IS (the builder's flicker, 2026-10-24). This used to read
-- the camera off the render camera's node (camera.screenToRay) and turn it
-- into the building's frame. In the builder that node is placed by
-- builder_camera's lateUpdate, which runs AFTER this one (the overlay's
-- scripts come later in the scene), so the camera read here was last frame's
-- — and the building, parented to a planet moving ~90 m/s on rails, had moved
-- on by one, two or no rails ticks since. The camera "seen" from the building
-- jumped by multiples of ~1.45 m from frame to frame (measured: steps of 1.4,
-- 2.9, 4.4 … 10 m, with the real camera still or orbiting slowly), so walls at
-- the edge of the near band and of a sight line faded in and out a step every
-- frame or two: 45 reversals in 24 s of slow orbit, 3–5 with the camera
-- still. Now, in the builder, the camera and the craft come straight from
-- builder_camera's own state in the build frame (a child of this building,
-- unrotated): no node, no rails, no frame of lag. Elsewhere (on foot, the
-- planet camera) the render camera is still read, which is fresh there.
--
-- HYSTERESIS. An occluded chunk stays out for `hold` seconds after the last
-- sight line through it clears, so a line grazing a chunk's edge as the view
-- turns does not blink it.
--
-- Chunk boxes come from the root's string params (written by the
-- generators): "node|hx|hy|hz|Mat,Mat|k;..." — half sizes about the node's
-- origin, the materials to write, and the near factor k (default 1).
--
-- Published, for the builder (findScript("vab_fade")):
--   enabled  false restores everything and stops
--   occlude  true in the builder (default false: in the world only NEAR)
--   target   a world vec3 the camera looks at (the craft's centre); nil = the
--            build point on the mobile launcher
--   radius, halfHeight   the craft's size about `target` (metres; 0 = a point)
--   near0, near1, rate   the numbers above (metres, metres, 1/s)
--   faded    how many chunks are below full opacity (read-only, for probes)
--   fadedNames  which, with their opacity (read-only, for probes)
--   seen     the camera position the fade used this frame, building-local

defaults = { near0 = 0.6, near1 = 3.0, rate = 6.0, hold = 0.35, chunks = "", ext = "" }

enabled = true
occlude = false
target = nil
radius, halfHeight = 4.0, 8.0
near0, near1, rate = nil, nil, nil
faded = 0
fadedNames = ""
seen = { 0, 0, 0 }   -- where the camera was taken to be this frame (vab-local; probes)

local root
local chunks = {}       -- { name, node, ext, hx, hy, hz, k, mats, cx, cy, cz, a, q }
local hangar            -- FacHangar's root, once found
local bp = { 0, 2.84, 0 }
local refresh = 0
local resolved = false
local tick = 0
local PX, PY, PZ = {}, {}, {}   -- the silhouette samples, reused frame to frame

local function parse(spec, ext)
  for row in string.gmatch(spec or "", "[^;]+") do
    local f = {}
    for v in string.gmatch(row, "[^|]+") do f[#f + 1] = v end
    if #f >= 5 then
      local mats = {}
      for mname in string.gmatch(f[5], "[^,]+") do mats[#mats + 1] = mname end
      chunks[#chunks + 1] = {
        name = f[1], ext = ext, hx = tonumber(f[2]), hy = tonumber(f[3]), hz = tonumber(f[4]),
        mats = mats, k = tonumber(f[6] or "1") or 1, a = 1.0, q = 1.0,
      }
    end
  end
end

function start(node)
  root = node
  near0, near1, rate = params.near0, params.near1, params.rate
  parse(params.chunks, false)
  parse(params.ext, true)
end

-- Find the chunk nodes (the hangar is spawned beside us, maybe a frame later)
-- and their centres: each node's local position, which is in our frame
-- because FacHangar and VabInterior are spawned with one position and
-- rotation (both origins are the slab's centre).
local function resolve()
  if not hangar then hangar = find("FacHangar") end
  local all = true
  for _, c in ipairs(chunks) do
    if not c.node then
      local owner = c.ext and hangar or root
      c.node = owner and owner:find(c.name) or nil
    end
    if c.node then
      -- local to its own root; FacHangar and VabInterior share one transform
      c.cx, c.cy, c.cz = c.node.x, c.node.y, c.node.z
    else
      all = false
    end
  end
  local m = root:find("VabBuildPoint")
  if m then bp = { m.x, m.y, m.z } end
  return all
end

local function box_dist(px, py, pz, c)
  local dx = math.max(math.abs(px - c.cx) - c.hx, 0)
  local dy = math.max(math.abs(py - c.cy) - c.hy, 0)
  local dz = math.max(math.abs(pz - c.cz) - c.hz, 0)
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- One axis of the slab test: narrow [t0, t1] to where the segment is inside
-- [lo, hi] on this axis; nil when it never is.
local function slab(p, d, lo, hi, t0, t1)
  if math.abs(d) < 1e-9 then
    if p < lo or p > hi then return nil end
    return t0, t1
  end
  local ta, tb = (lo - p) / d, (hi - p) / d
  if ta > tb then ta, tb = tb, ta end
  if ta > t0 then t0 = ta end
  if tb < t1 then t1 = tb end
  if t0 > t1 then return nil end
  return t0, t1
end

-- Does the segment p→q pass through the chunk's box?
local function seg_hits(px, py, pz, qx, qy, qz, c)
  local t0, t1 = slab(px, qx - px, c.cx - c.hx, c.cx + c.hx, 0.0, 1.0)
  if not t0 then return false end
  t0, t1 = slab(py, qy - py, c.cy - c.hy, c.cy + c.hy, t0, t1)
  if not t0 then return false end
  t0, t1 = slab(pz, qz - pz, c.cz - c.hz, c.cz + c.hz, t0, t1)
  return t0 ~= nil
end

local function inside(px, py, pz, c)
  return math.abs(px - c.cx) <= c.hx and math.abs(py - c.cy) <= c.hy and math.abs(pz - c.cz) <= c.hz
end

-- The builder's own view, in this building's frame: camera and craft centre
-- (vab-local), or nil when the builder is not up here. The build frame is an
-- unrotated child of this node (build_host make_frame), so frame → building is
-- its offset; in the standalone builder the builder's frame is the world and
-- this node stands unrotated at its own position.
local bc_ref, bh_ref, view_retry = nil, nil, 0
local function builder_view()
  if not occlude then return nil end
  if not (bc_ref and bc_ref.valid ~= false) or not (bh_ref and bh_ref.valid ~= false) then
    view_retry = view_retry - 1
    if view_retry > 0 then return nil end
    view_retry = 60
    bc_ref = find("Builder Camera") and findScript("builder_camera") or nil
    bh_ref = find("Build Host") and findScript("build_host") or nil
  end
  local bc, bh = bc_ref, bh_ref
  if not (bc and bc.camState and bc.viewBasis) then return nil end
  local ox, oy, oz
  local fr = bh and bh.frameNode and bh.frameNode()
  if fr and fr.valid ~= false and fr.parent and fr.parent.id == root.id then
    ox, oy, oz = fr.x, fr.y, fr.z
  elseif bh and bh.mode == "standalone" then
    ox, oy, oz = -root.x, -root.y, -root.z
  else
    return nil
  end
  local cs = bc.camState()
  if not (cs and cs.P and cs.d) then return nil end
  local f = bc.viewBasis(cs.yaw or 0, cs.pitch or 0)
  local cam = { cs.P.x - f.x * cs.d + ox, cs.P.y - f.y * cs.d + oy, cs.P.z - f.z * cs.d + oz }
  local b = bc.bounds and bc.bounds()
  local tgt = b and b.centre and { b.centre.x + ox, b.centre.y + oy, b.centre.z + oz } or nil
  return cam, tgt
end

local function apply(c, q)
  if q == c.q or not c.node then return end
  c.q = q
  if q <= 0.0 then
    c.node.visible = false
    return
  end
  c.node.visible = true
  for _, mname in ipairs(c.mats) do
    c.node:material(mname).alpha = q
  end
end

function lateUpdate(node, dt)
  refresh = refresh - 1
  if not resolved or refresh <= 0 then
    resolved = resolve()
    refresh = resolved and 120 or 10
  end
  if not enabled then
    for _, c in ipairs(chunks) do c.a = 1.0; apply(c, 1.0) end
    faded = 0
    return
  end
  local cx, cy, cz, tx, ty, tz
  local bcam, btgt = builder_view()
  if bcam then
    cx, cy, cz = bcam[1], bcam[2], bcam[3]
  else
    if not camera.exists() then return end
    local w, h = camera.screenSize()
    local ox, oy, oz = camera.screenToRay(w * 0.5, h * 0.5)
    local cam = root:toLocal(vec3(ox, oy, oz))
    cx, cy, cz = cam.x, cam.y, cam.z
  end
  seen[1], seen[2], seen[3] = cx, cy, cz
  tx, ty, tz = bp[1], bp[2], bp[3]
  if btgt then
    tx, ty, tz = btgt[1], btgt[2], btgt[3]
  elseif target then
    local t = root:toLocal(target)
    tx, ty, tz = t.x, t.y, t.z
  end
  -- the craft's silhouette, sampled: a column of points every ~4 m from its
  -- foot to its top, at its centre and either side across the view
  local sx, sz = tz - cz, cx - tx             -- horizontal, perpendicular to the view
  local sl = math.sqrt(sx * sx + sz * sz)
  local r = radius or 0
  if sl > 1e-6 then sx, sz = sx / sl * r, sz / sl * r else sx, sz = 0, 0 end
  local hh = halfHeight or 0
  local y0, y1 = math.max(ty - hh, bp[2] + 0.5), ty + hh
  local rows = math.max(1, math.min(12, math.ceil((y1 - y0) / 5.0)))
  local np = 0
  -- and the box all the sight lines lie in: a chunk outside it hides nothing
  local vx0, vy0, vz0, vx1, vy1, vz1 = cx, cy, cz, cx, cy, cz
  for i = 0, rows do
    local y = y0 + (y1 - y0) * i / rows
    for k = -1, 1 do
      if k == 0 or r > 0 then
        np = np + 1
        local x, z = tx + sx * k, tz + sz * k
        PX[np], PY[np], PZ[np] = x, y, z
        if x < vx0 then vx0 = x elseif x > vx1 then vx1 = x end
        if y < vy0 then vy0 = y elseif y > vy1 then vy1 = y end
        if z < vz0 then vz0 = z elseif z > vz1 then vz1 = z end
      end
    end
  end
  tick = tick + 1
  local n0, n1 = near0 or defaults.near0, near1 or defaults.near1
  local ease = math.min(1.0, (rate or defaults.rate) * dt)
  local count = 0
  local names = {}
  for i, c in ipairs(chunks) do
    if c.node and c.cx then
      local goal = math.smoothstep(n0 * c.k, n1 * c.k, box_dist(cx, cy, cz, c))
      -- occlusion is re-tested for a third of the chunks each frame (the
      -- easing hides the lag); the others keep their last answer
      if (i + tick) % 3 == 0 or c.occ == nil then
        local occ = false
        if occlude and goal > 0 and not inside(tx, ty, tz, c)
          and c.cx + c.hx >= vx0 and c.cx - c.hx <= vx1 and c.cy + c.hy >= vy0 and c.cy - c.hy <= vy1
          and c.cz + c.hz >= vz0 and c.cz - c.hz <= vz1 then
          for j = 1, np do
            -- (a chunk the point is inside is under or round the craft, not in front of it)
            if not inside(PX[j], PY[j], PZ[j], c) and seg_hits(cx, cy, cz, PX[j], PY[j], PZ[j], c) then
              occ = true
              break
            end
          end
        end
        if occ then c.occ_t = time end
        -- (held out a moment after the last line through it clears)
        c.occ = occ or (c.occ_t ~= nil and time - c.occ_t < (params.hold or 0.35))
      end
      if c.occ and occlude then goal = 0.0 end
      c.a = c.a + (goal - c.a) * ease
      if math.abs(goal - c.a) < 0.02 then c.a = goal end
      local q = math.floor(c.a * 8 + 0.5) / 8
      apply(c, q)
      if q < 1 then
        count = count + 1
        names[#names + 1] = string.format("%s=%.2f", c.name, q)
      end
    end
  end
  faded = count
  fadedNames = table.concat(names, " ")
end
