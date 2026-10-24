-- BUILDER_SPACE — the builder's FRAME ADAPTER and SPATIAL HASH (WP1,
-- docs/builder-design.md §8.2, §9.2). A pure RULEBOOK script: no scene access
-- of its own (it only reads the node and camera it is handed), its globals are
-- its API, and it loads from disk in a luajit test. Reach it with
-- findScript("builder_space").
--
-- THE FRAME. Every builder coordinate is BuildFrame-local. With no BuildFrame
-- node (standalone builder.ron, the tests) the frame is the identity and costs
-- nothing. With one, part nodes are children of it (so node.x/y/z are local and
-- the engine carries them with the planet), mouse rays come in through toLocal
-- and draw.* goes out through toWorld.
--
--   F = newFrame(node, camera)      node nil → identity
--   F:refresh()                     re-read the node's world pose (once a frame)
--   F.toLocal(x,y,z) / F.toWorld / F.dirToLocal / F.dirToWorld   (. or :)
--   F.ray(mx, my) → ox,oy,oz, dx,dy,dz in the frame
--   wrapDraw(F, draw) / wrapCamera(F, camera) → proxies that take and give
--   local coordinates (the identity frame hands back the originals).
--
-- THE HASH. Part AABBs in the frame, in cubic cells (1 m; 2 m past 1,000
-- parts). Each entry is filed under every cell its AABB, grown by `pad`,
-- touches, so a walk along a ray also finds parts NEAR the ray (attach nodes
-- just off a hull). Entries spanning more than BIG_CELLS cells go on a short
-- always-checked list instead.
--
--   H = newHash(cell, pad)
--   H:set(uid, minx,miny,minz, maxx,maxy,maxz)   insert or move
--   H:remove(uid)
--   H:box(minx,miny,minz, maxx,maxy,maxz, out) → out (uids, no duplicates)
--   H:ray(ox,oy,oz, dx,dy,dz, tmax, out, grow) → out: uids whose AABB grown by
--                                   `grow` the ray passes, nearest entry first
--   H:count()   H.visits (cells walked + entries tested since H:resetVisits())

local function xyz(a, b, c, d)
  if type(a) == "table" then return b, c, d end
  return a, b, c
end

-- ── frame ────────────────────────────────────────────────────────────────────
function newFrame(node, cam)
  local F = { identity = node == nil, node = node, cam = cam,
              ox = 0, oy = 0, oz = 0,
              rx = 1, ry = 0, rz = 0, ux = 0, uy = 1, uz = 0, zx = 0, zy = 0, zz = 1 }
  function F.refresh()
    if F.identity or not F.node then return end
    local n = F.node
    if n.valid == false then return end
    local p = n.worldPos
    if p then F.ox, F.oy, F.oz = p.x, p.y, p.z end
    local r, u, f = n:worldRight(), n:worldUp(), n:worldForward()
    if r and u and f then
      F.rx, F.ry, F.rz = r.x, r.y, r.z
      F.ux, F.uy, F.uz = u.x, u.y, u.z
      F.zx, F.zy, F.zz = -f.x, -f.y, -f.z   -- forward is −Z
    end
  end
  function F.toLocal(...)
    local x, y, z = xyz(...)
    if F.identity then return x, y, z end
    x, y, z = x - F.ox, y - F.oy, z - F.oz
    return x * F.rx + y * F.ry + z * F.rz, x * F.ux + y * F.uy + z * F.uz, x * F.zx + y * F.zy + z * F.zz
  end
  function F.toWorld(...)
    local x, y, z = xyz(...)
    if F.identity then return x, y, z end
    return F.ox + F.rx * x + F.ux * y + F.zx * z,
           F.oy + F.ry * x + F.uy * y + F.zy * z,
           F.oz + F.rz * x + F.uz * y + F.zz * z
  end
  function F.dirToLocal(...)
    local x, y, z = xyz(...)
    if F.identity then return x, y, z end
    return x * F.rx + y * F.ry + z * F.rz, x * F.ux + y * F.uy + z * F.uz, x * F.zx + y * F.zy + z * F.zz
  end
  function F.dirToWorld(...)
    local x, y, z = xyz(...)
    if F.identity then return x, y, z end
    return F.rx * x + F.ux * y + F.zx * z, F.ry * x + F.uy * y + F.zy * z, F.rz * x + F.uz * y + F.zz * z
  end
  function F.ray(a, b, c)
    local mx, my = a, b
    if type(a) == "table" then mx, my = b, c end
    local ox, oy, oz, dx, dy, dz = F.cam.screenToRay(mx, my)
    if F.identity then return ox, oy, oz, dx, dy, dz end
    local lx, ly, lz = F.toLocal(ox, oy, oz)
    local ex, ey, ez = F.dirToLocal(dx, dy, dz)
    return lx, ly, lz, ex, ey, ez
  end
  return F
end

-- draw.* in the frame: every point argument goes out through toWorld, every
-- direction through dirToWorld. Screen-space calls (rect, text…) pass through.
local DRAW_SIG = {
  -- name = { kinds of the leading arguments: "p" point (3 numbers), "d" dir }
  line = { "p", "p" }, sphere = { "p" }, box = { "p" }, ring = { "p", "d" },
  disc = { "p", "d" }, cone = { "p", "d" }, arrow = { "p", "p" },
  tri = { "p", "p", "p" },
}
function wrapDraw(F, draw)
  if F.identity or not draw then return draw end
  local proxy = {}
  for name, sig in pairs(DRAW_SIG) do
    local fn = draw[name]
    if fn then
      local function emit(a, n)
        local i = 1
        for _, k in ipairs(sig) do
          local x, y, z = a[i], a[i + 1], a[i + 2]
          if k == "p" then a[i], a[i + 1], a[i + 2] = F.toWorld(x, y, z)
          else a[i], a[i + 1], a[i + 2] = F.dirToWorld(x, y, z) end
          i = i + 3
        end
        return fn(unpack(a, 1, n))
      end
      proxy[name] = function(...)
        local a, n = { ... }, select("#", ...)
        -- Drawn from `update`, a shape would be turned into the world with
        -- the frame as it stood then, and the planet's rails tick before the
        -- picture is drawn (several metres at orbital speed): the overlay
        -- would trail the parts. So shapes are queued in frame coordinates
        -- and drawn by F.flush() from lateUpdate, against the frame re-read
        -- there. Outside update (lateUpdate itself) they go straight out.
        if F.queueing then
          local q = F.queue
          q[#q + 1] = { emit, a, n }
          return
        end
        return emit(a, n)
      end
    end
  end
  if draw.polyline then
    local function emitp(a, n)
      local pts, w = a[1], {}
      for i = 1, #pts - 2, 3 do
        w[i], w[i + 1], w[i + 2] = F.toWorld(pts[i], pts[i + 1], pts[i + 2])
      end
      a[1] = w
      return draw.polyline(unpack(a, 1, n))
    end
    proxy.polyline = function(...)
      local a, n = { ... }, select("#", ...)
      if F.queueing then local q = F.queue; q[#q + 1] = { emitp, a, n } return end
      return emitp(a, n)
    end
  end
  -- The queue: F.beginQueue() at the top of update, F.flush() in lateUpdate
  -- (re-reads the frame, then draws everything queued since).
  F.queue = F.queue or {}
  F.queueing = false
  function F.beginQueue() F.queueing = true end
  function F.flush()
    F.queueing = false
    F.refresh()
    local q = F.queue
    for i = 1, #q do
      local e = q[i]
      e[1](e[2], e[3])
      q[i] = nil
    end
  end
  return setmetatable(proxy, { __index = draw })
end

-- camera.* in the frame: screenToRay hands back a local ray, worldToScreen
-- takes a local point. Everything else is the camera's own.
function wrapCamera(F, cam)
  if F.identity or not cam then return cam end
  local proxy = {
    screenToRay = function(mx, my) return F.ray(mx, my) end,
    worldToScreen = function(x, y, z)
      local wx, wy, wz = F.toWorld(x, y, z)
      return cam.worldToScreen(wx, wy, wz)
    end,
  }
  return setmetatable(proxy, { __index = cam })
end

-- ── spatial hash ─────────────────────────────────────────────────────────────
local BIG_CELLS = 96
local OFF = 1048576   -- keeps cell indices positive in the key

local function key(ix, iy, iz)
  return ((ix + 2048) * 4096 + (iy + 2048)) * 4096 + (iz + 2048)
end

function newHash(cell, pad)
  local H = { cell = cell or 1.0, pad = pad or 0.5, cells = {}, ent = {}, big = {},
              n = 0, stamp = 0, seen = {}, visits = 0,
              bminx = math.huge, bminy = math.huge, bminz = math.huge,
              bmaxx = -math.huge, bmaxy = -math.huge, bmaxz = -math.huge }
  local floor = math.floor

  local function file(uid, e)
    local c, p = H.cell, H.pad
    local x0, y0, z0 = floor((e[1] - p) / c), floor((e[2] - p) / c), floor((e[3] - p) / c)
    local x1, y1, z1 = floor((e[4] + p) / c), floor((e[5] + p) / c), floor((e[6] + p) / c)
    if (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1) > BIG_CELLS then
      H.big[uid] = true
      e.big = true
      return
    end
    local keys = {}
    for ix = x0, x1 do
      for iy = y0, y1 do
        for iz = z0, z1 do
          local k = key(ix, iy, iz)
          local b = H.cells[k]
          if not b then b = {}; H.cells[k] = b end
          b[uid] = true
          keys[#keys + 1] = k
        end
      end
    end
    e.keys = keys
  end

  local function unfile(uid, e)
    if e.big then H.big[uid] = nil; return end
    for _, k in ipairs(e.keys or {}) do
      local b = H.cells[k]
      if b then
        b[uid] = nil
        if next(b) == nil then H.cells[k] = nil end
      end
    end
  end

  function H:set(uid, a, b, c, d, e2, f)
    local e = self.ent[uid]
    if e then
      -- unchanged cells: only the box moves
      if e[1] == a and e[2] == b and e[3] == c and e[4] == d and e[5] == e2 and e[6] == f then return end
      unfile(uid, e)
    else
      self.n = self.n + 1
    end
    e = { a, b, c, d, e2, f }
    self.ent[uid] = e
    file(uid, e)
    if a < self.bminx then self.bminx = a end
    if b < self.bminy then self.bminy = b end
    if c < self.bminz then self.bminz = c end
    if d > self.bmaxx then self.bmaxx = d end
    if e2 > self.bmaxy then self.bmaxy = e2 end
    if f > self.bmaxz then self.bmaxz = f end
  end

  function H:remove(uid)
    local e = self.ent[uid]
    if not e then return end
    unfile(uid, e)
    self.ent[uid] = nil
    self.n = self.n - 1
  end

  function H:has(uid) return self.ent[uid] ~= nil end
  function H:count() return self.n end
  function H:resetVisits() self.visits = 0 end
  function H:clear()
    self.cells, self.ent, self.big, self.n = {}, {}, {}, 0
    self.bminx, self.bminy, self.bminz = math.huge, math.huge, math.huge
    self.bmaxx, self.bmaxy, self.bmaxz = -math.huge, -math.huge, -math.huge
  end
  -- Shrink the overall bounds back to the entries (after big deletions).
  function H:rebound()
    self.bminx, self.bminy, self.bminz = math.huge, math.huge, math.huge
    self.bmaxx, self.bmaxy, self.bmaxz = -math.huge, -math.huge, -math.huge
    for _, e in pairs(self.ent) do
      if e[1] < self.bminx then self.bminx = e[1] end
      if e[2] < self.bminy then self.bminy = e[2] end
      if e[3] < self.bminz then self.bminz = e[3] end
      if e[4] > self.bmaxx then self.bmaxx = e[4] end
      if e[5] > self.bmaxy then self.bmaxy = e[5] end
      if e[6] > self.bmaxz then self.bmaxz = e[6] end
    end
  end

  -- Every entry whose AABB overlaps the box.
  function H:box(a, b, c, d, e2, f, out)
    out = out or {}
    self.stamp = self.stamp + 1
    local st, seen, ent = self.stamp, self.seen, self.ent
    local cs = self.cell
    local x0, y0, z0 = floor(a / cs), floor(b / cs), floor(c / cs)
    local x1, y1, z1 = floor(d / cs), floor(e2 / cs), floor(f / cs)
    local function test(uid)
      if seen[uid] ~= st then
        seen[uid] = st
        self.visits = self.visits + 1
        local e = ent[uid]
        if e and e[1] <= d and e[4] >= a and e[2] <= e2 and e[5] >= b and e[3] <= f and e[6] >= c then
          out[#out + 1] = uid
        end
      end
    end
    if (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1) > 4096 then
      for uid in pairs(ent) do test(uid) end
      return out
    end
    for ix = x0, x1 do
      for iy = y0, y1 do
        for iz = z0, z1 do
          local bk = self.cells[key(ix, iy, iz)]
          if bk then for uid in pairs(bk) do test(uid) end end
        end
      end
    end
    for uid in pairs(self.big) do test(uid) end
    return out
  end

  -- Slab test of a ray against an AABB grown by g → entry t (or nil).
  local function slab(e, g, ox, oy, oz, dx, dy, dz, tmax)
    local t0, t1 = 0.0, tmax
    local lo, hi
    lo, hi = e[1] - g, e[4] + g
    if math.abs(dx) < 1e-12 then
      if ox < lo or ox > hi then return nil end
    else
      local a2, b2 = (lo - ox) / dx, (hi - ox) / dx
      if a2 > b2 then a2, b2 = b2, a2 end
      if a2 > t0 then t0 = a2 end
      if b2 < t1 then t1 = b2 end
      if t0 > t1 then return nil end
    end
    lo, hi = e[2] - g, e[5] + g
    if math.abs(dy) < 1e-12 then
      if oy < lo or oy > hi then return nil end
    else
      local a2, b2 = (lo - oy) / dy, (hi - oy) / dy
      if a2 > b2 then a2, b2 = b2, a2 end
      if a2 > t0 then t0 = a2 end
      if b2 < t1 then t1 = b2 end
      if t0 > t1 then return nil end
    end
    lo, hi = e[3] - g, e[6] + g
    if math.abs(dz) < 1e-12 then
      if oz < lo or oz > hi then return nil end
    else
      local a2, b2 = (lo - oz) / dz, (hi - oz) / dz
      if a2 > b2 then a2, b2 = b2, a2 end
      if a2 > t0 then t0 = a2 end
      if b2 < t1 then t1 = b2 end
      if t0 > t1 then return nil end
    end
    return t0
  end

  -- Entries whose AABB (grown by `grow`, at most the hash pad) the ray passes,
  -- sorted by entry distance. A 3-D DDA over the cells, clipped to the hash's
  -- overall bounds, so a ray across an empty sky walks no cells at all.
  function H:ray(ox, oy, oz, dx, dy, dz, tmax, out, grow)
    out = out or {}
    grow = math.min(grow or 0, self.pad)
    if self.n == 0 then return out end
    self.stamp = self.stamp + 1
    local st, seen, ent = self.stamp, self.seen, self.ent
    local hits = {}
    local function test(uid)
      if seen[uid] ~= st then
        seen[uid] = st
        self.visits = self.visits + 1
        local e = ent[uid]
        local t = e and slab(e, grow, ox, oy, oz, dx, dy, dz, tmax)
        if t then hits[#hits + 1] = { uid, t } end
      end
    end
    for uid in pairs(self.big) do test(uid) end
    -- clip to the bounds (grown by the pad)
    local p = self.pad
    local box = { self.bminx - p, self.bminy - p, self.bminz - p, self.bmaxx + p, self.bmaxy + p, self.bmaxz + p }
    local tin = slab(box, 0, ox, oy, oz, dx, dy, dz, tmax)
    if tin then
      -- exit distance: walk until we leave the box (or tmax)
      local cs = self.cell
      local t = tin
      local px, py, pz = ox + dx * t, oy + dy * t, oz + dz * t
      local ix, iy, iz = floor(px / cs), floor(py / cs), floor(pz / cs)
      local sx = dx > 0 and 1 or -1
      local sy = dy > 0 and 1 or -1
      local sz = dz > 0 and 1 or -1
      local function first(pc, d, i)
        if math.abs(d) < 1e-12 then return math.huge end
        local edge = (d > 0) and (i + 1) * cs or i * cs
        return t + (edge - pc) / d
      end
      local tx, ty, tz = first(px, dx, ix), first(py, dy, iy), first(pz, dz, iz)
      local ddx = math.abs(dx) > 1e-12 and cs / math.abs(dx) or math.huge
      local ddy = math.abs(dy) > 1e-12 and cs / math.abs(dy) or math.huge
      local ddz = math.abs(dz) > 1e-12 and cs / math.abs(dz) or math.huge
      local bx0, by0, bz0 = floor(box[1] / cs), floor(box[2] / cs), floor(box[3] / cs)
      local bx1, by1, bz1 = floor(box[4] / cs), floor(box[5] / cs), floor(box[6] / cs)
      local guard = 0
      while guard < 4096 do
        guard = guard + 1
        if ix < bx0 - 1 or ix > bx1 + 1 or iy < by0 - 1 or iy > by1 + 1 or iz < bz0 - 1 or iz > bz1 + 1 then break end
        self.visits = self.visits + 1
        local bk = self.cells[key(ix, iy, iz)]
        if bk then for uid in pairs(bk) do test(uid) end end
        local tn = math.min(tx, ty, tz)
        if tn > tmax then break end
        if tx == tn then ix = ix + sx; tx = tx + ddx
        elseif ty == tn then iy = iy + sy; ty = ty + ddy
        else iz = iz + sz; tz = tz + ddz end
      end
    end
    table.sort(hits, function(a, b) return a[2] < b[2] end)
    for i, h in ipairs(hits) do out[#out + 1] = h[1] end
    return out
  end

  return H
end
