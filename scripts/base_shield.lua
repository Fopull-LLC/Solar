-- BASE SHIELD — walls on the ground that block radiation, and the ground's own
-- sources (deep-space addendum M6c, step 3's A4 carried to the base;
-- docs/base-building.md §12, docs/heat-and-nuclear.md §4).
--
-- THE RULE IS STEP 3's: what stands between a core and a crew member is
-- counted by PART RECORD, never by "a ray hit a solid" (so it holds once
-- modules are hollow, engine interiors stage 1). A placed BASE part with a
-- `shield` (the Shield Wall: k = 0.05, half a metre of concrete) is an
-- oriented box in its body's frame; thermal.shieldFactor multiplies the k of
-- every box the core→crew segment crosses. Only crew ON FOOT are counted
-- against walls, as only they get the terrain ray (a seated member is behind
-- their own craft's parts, which the craft's pass counts).
--
--   WALLS     kept from the structures' records (rebuilt when they change):
--             `blockersOn(body, a, b)` → the boxes near a segment, and
--             `wallFactor(body, a, b)` → their product. vessel_thermal's dose
--             pass asks it for every member on foot in a craft reactor's cone.
--   SOURCES   a BASE part with `rad` gives a dose of its own: the Isotope
--             Skid's four cells a weak field all round (`omni`), a ground
--             reactor (step 11) its cone. Twice a second, only while one
--             exists: a distance test for each member on foot on its world,
--             then the inverse square, the walls, and the terrain ray, as A4.
--   THE DRAW  with the Build Kit open, every source within 80 m and every
--             live craft core is drawn the VAB's way (builder.draw_thermal:
--             eight lines and three rings for a cone; three rings round an
--             omni source), and each member on foot it reaches gets the VAB's
--             marker from the SAME numbers the dose pass wrote (`noted`): red
--             in the open, amber behind shielding. The draw and the dose
--             can't disagree: one is read off the other.
--
-- COST: nothing per frame with no source and the kit closed. With a source:
-- a list walk twice a second. Records are rebuilt on structures.version.
--
-- Probes: walls(), sources(), blockersOn, wallFactor, noted(id), pass(),
-- doseNow(id), live (craft cores published by vessel_thermal).

defaults = {
  --@range 0.1 2 --@units s
  every = 0.5,
}

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function now() return time or 0 end
local function len3(x, y, z) return math.sqrt(x * x + y * y + z * z) end

-- ── pure: a placed part as a box ────────────────────────────────────────────
-- (structures.partPose's frame: R right, U up, F front; centre half.y up)
function partBox(ST, rec, p, def)
  local gx, gy, gz, U, F = ST.partPose(rec, p, 0)
  local R = { x = U.y * F.z - U.z * F.y, y = U.z * F.x - U.x * F.z, z = U.x * F.y - U.y * F.x }
  local h = def.half or { x = 0.5, y = 0.5, z = 0.5 }
  return { x = gx + U.x * h.y, y = gy + U.y * h.y, z = gz + U.z * h.y, X = R, Y = U, Z = F,
           hx = h.x, hy = h.y, hz = h.z, b = rec.b, sid = rec.id, uid = p.uid, label = def.label }
end

-- Walls and sources from the records. → walls, sources
function scan(ST, defs)
  local W, S = {}, {}
  for _, rec in ipairs(ST.list()) do
    for _, p in ipairs(rec.bp or {}) do
      local d = defs(p.id)
      if d and d.shield then
        local b = partBox(ST, rec, p, d)
        b.k = d.shield.k or 0.05
        W[#W + 1] = b
      end
      if d and d.rad then
        local b = partBox(ST, rec, p, d)
        -- (S6: a reactor vessel's source is its core, `up` over the box's
        -- centre; `dynamic`: its strength is the plant's, asked each pass)
        local up = d.rad.up or 0
        S[#S + 1] = { b = rec.b, x = b.x + b.Y.x * up, y = b.y + b.Y.y * up, z = b.z + b.Y.z * up, ax = b.Y.x, ay = b.Y.y, az = b.Y.z,
                      rad = d.rad.rad or 0, omni = d.rad.omni == true, share = d.rad.dynamic and 0 or 1, dyn = d.rad.dynamic == true,
                      sid = rec.id, uid = p.uid, label = d.rad.dynamic and "reactor" or d.label }
      end
    end
  end
  return W, S
end

-- The walls on `body` whose box could cross the segment a→b (body-relative):
-- a bounding-sphere test, then thermal's slab test does the rest.
function blockersIn(list, body, ax, ay, az, bx, by, bz)
  local out = {}
  local mx, my, mz = (ax + bx) / 2, (ay + by) / 2, (az + bz) / 2
  local hl = len3(bx - ax, by - ay, bz - az) / 2
  for _, w in ipairs(list or {}) do
    if w.b == body then
      local rr = hl + len3(w.hx, w.hy, w.hz)
      if (w.x - mx) ^ 2 + (w.y - my) ^ 2 + (w.z - mz) ^ 2 <= rr * rr then out[#out + 1] = w end
    end
  end
  return out
end

-- An omni source's direct rate at distance r (dose a game second): A4's
-- inverse square from `rad` at dose_r0, never closer than dose_near.
function omniRate(src, r, TP)
  if r > TP.dose_range then return 0 end
  local rr = math.max(r, TP.dose_near)
  return (src.rad or 0) * (src.share or 1) * (TP.dose_r0 / rr) ^ 2 / 3600
end

-- ── the scene half ──────────────────────────────────────────────────────────
local WALLS, SRCS = {}, {}
local st_ver = nil
local function defs(id) local pb = ref("parts_base"); return pb and pb.partInfo(id) or nil end
local function rescan()
  local ST = ref("structures")
  if not (ST and ST.list and ST.partPose) then return end
  WALLS, SRCS = scan(ST, defs)
  st_ver = ST.version
end
function walls() return WALLS end
function sources() return SRCS end
function blockersOn(body, ax, ay, az, bx, by, bz) return blockersIn(WALLS, body, ax, ay, az, bx, by, bz) end
-- The walls' share between a and b (body-relative, the same read). → f, n
function wallFactor(body, ax, ay, az, bx, by, bz, TH)
  TH = TH or ref("thermal")
  if #WALLS == 0 or not TH then return 1, 0 end
  local bl = blockersIn(WALLS, body, ax, ay, az, bx, by, bz)
  if #bl == 0 then return 1, 0 end
  return TH.shieldFactor(ax, ay, az, bx, by, bz, bl, nil)
end

-- What the dose passes found for each member on foot (the draw reads it):
-- id → { rate, bare, f, t, from, b, sx, sy, sz (the source, body-relative) }
local NOTED = {}
function note(id, rate, bare, from, b, sx, sy, sz)
  local e = NOTED[id]
  if not e or now() - e.t > 0.25 or (rate or 0) > (e.rate or 0) then
    NOTED[id] = { rate = rate, bare = bare, f = (bare and bare > 0) and rate / bare or 1, t = now(), from = from, b = b,
                  sx = sx, sy = sy, sz = sz }
  end
end
function noted(id) local e = NOTED[id]; return (e and now() - e.t < 1.5) and e or nil end

-- Craft reactor cores the flight's dose pass saw (vessel_thermal publishes):
-- node id → { t, b, cores = { { x,y,z (body-relative), ax,ay,az, rad, share, label } } }
live = {}
function publish(key, b, cores) live[key] = { t = now(), b = b, cores = cores } end

-- THE GROUND SOURCES' PASS: who on foot is near a source, and what reaches them.
local P = { t = -10, crew_t = -10, afoot = {}, pending = {}, flush_t = -10 }
local last_pass = nil
local function flush(cl, force)
  if not (cl and cl.addDose) then return end
  local t = now()
  if not force and t - P.flush_t < 2.0 then return end
  P.flush_t = t
  for id, e in pairs(P.pending) do if e.d > 0 then cl.addDose(id, e.d, e.src, e.rate) end end
  P.pending = {}
end

function pass(gs)
  local TH, cl = ref("thermal"), ref("crew")
  if not (TH and cl and #SRCS > 0) then return nil end
  local TP = TH.THERMAL
  if now() - P.crew_t > 4.0 then
    P.crew_t = now()
    P.afoot = {}
    if cl.roster then for _, r in ipairs(cl.roster()) do if r.status == "afoot" then P.afoot[#P.afoot + 1] = r.id end end end
  end
  local rep = { traced = 0, hit = 0, out = {} }
  local bodyCache = {}
  -- (S6) the reactors' strength now: their heat over their rating, and any release
  local RP = ref("reactor_plant")
  local live_n = 0
  for _, s in ipairs(SRCS) do
    if s.dyn then
      if RP and RP.radOf then s.rad, s.share = RP.radOf(s.sid, s.uid) else s.share = 0 end
      s.rad, s.share = s.rad or 0, s.share or 0
    end
    if (s.share or 0) > 0 and (s.rad or 0) > 0 then live_n = live_n + 1 end
  end
  if live_n == 0 then last_pass = rep return rep end
  for _, id in ipairs(P.afoot) do
    local nb = cl.bodyOf and cl.bodyOf(id)
    if nb and nb.valid ~= false then
      local wx, wy, wz = nb.x, nb.y, nb.z
      local bname = space.dominant(wx, wy, wz)
      local b = bname and (bodyCache[bname] or space.body(bname))
      bodyCache[bname or ""] = b
      if b then
        local px, py, pz = wx - b.x, wy - b.y, wz - b.z
        -- (the member's chest: the capsule's centre is 1 m up, the chest 0.4 m over it)
        local l = math.max(len3(px, py, pz), 1e-6)
        px, py, pz = px * (1 + 0.4 / l), py * (1 + 0.4 / l), pz * (1 + 0.4 / l)
        local sum, bare_sum, from = 0, 0, nil
        local fx, fy, fz
        for _, s in ipairs(SRCS) do
          if s.b == bname then
            local r = len3(px - s.x, py - s.y, pz - s.z)
            if r <= TP.dose_range then
              local bare
              if s.omni then bare = omniRate(s, r, TP)
              else local _, rr = TH.coneAt(s, px, py, pz); bare = rr or 0 end
              if bare > 0 then
                rep.traced = rep.traced + 1
                local f = 1
                local bl = blockersIn(WALLS, bname, s.x, s.y, s.z, px, py, pz)
                if #bl > 0 then f = TH.shieldFactor(s.x, s.y, s.z, px, py, pz, bl, nil) end
                local rate = bare * f
                -- the ground between (on foot: a ray from the source to them)
                if rate > 0 and terrain and terrain.raycast then
                  local cx, cy, cz = b.x + s.x, b.y + s.y, b.z + s.z
                  local dx, dy, dz = (b.x + px) - cx, (b.y + py) - cy, (b.z + pz) - cz
                  local dl = len3(dx, dy, dz)
                  if dl > 1.0 then
                    local ok, hit = pcall(terrain.raycast, vec3(cx, cy, cz), vec3(dx / dl, dy / dl, dz / dl), dl)
                    if ok and hit and hit.distance and hit.distance < dl - 0.6 then rate = 0 end
                  end
                end
                sum, bare_sum = sum + rate, bare_sum + bare
                if rate > 0 or not from then from = s.label; fx, fy, fz = s.x, s.y, s.z end
              end
            end
          end
        end
        if bare_sum > 0 then
          rep.hit = rep.hit + 1
          rep.out[id] = { rate = sum, bare = bare_sum }
          note(id, sum, bare_sum, from, bname, fx, fy, fz)
          if sum > 0 then
            local e = P.pending[id] or { d = 0 }
            e.d, e.rate, e.src = e.d + sum * gs, sum, "the " .. tostring(from or "isotope cells")
            P.pending[id] = e
          end
        end
      end
    end
  end
  flush(cl, false)
  last_pass = rep
  return rep
end
function lastPass() return last_pass end
-- (S8, an Area Radiation Monitor) the dose rate at a body-relative point from
-- the ground sources now (lethal shares a game second), the walls counted by
-- record as for the crew; no terrain ray (a monitor hangs in the open of its
-- room). The reactors' strength is the last dose pass's.
function doseAt(bname, px, py, pz)
  local TH = ref("thermal")
  if not (TH and #SRCS > 0) then return 0 end
  local TP = TH.THERMAL
  local sum = 0
  local RP = ref("reactor_plant")
  for _, s in ipairs(SRCS) do
    if s.dyn and s.b == bname and RP and RP.radOf then s.rad, s.share = RP.radOf(s.sid, s.uid); s.rad, s.share = s.rad or 0, s.share or 0 end
    if s.b == bname and (s.rad or 0) > 0 and (s.share == nil or s.share > 0) then
      local r = len3(px - s.x, py - s.y, pz - s.z)
      if r <= TP.dose_range then
        local bare
        if s.omni then bare = omniRate(s, r, TP) else local _, rr = TH.coneAt(s, px, py, pz); bare = rr or 0 end
        if bare > 0 then
          local bl = blockersIn(WALLS, bname, s.x, s.y, s.z, px, py, pz)
          sum = sum + bare * ((#bl > 0) and TH.shieldFactor(s.x, s.y, s.z, px, py, pz, bl, nil) or 1)
        end
      end
    end
  end
  return sum
end
-- (probes) a member's dose rate from the ground sources now, a game hour's share
function doseNow(id) local e = noted(id); return e and e.rate * 3600 or 0, e and e.bare * 3600 or 0 end

-- ── the draw (the kit open) ─────────────────────────────────────────────────
local function red(bad) if bad then return 0.97, 0.34, 0.25 end return 1.0, 0.8, 0.28 end
local function draw_cone(b, c, L)
  local TH = ref("thermal")
  local half = math.rad(TH and TH.THERMAL.cone_deg or 30)
  local tn = math.tan(half)
  local ax, ay, az = c.ax, c.ay, c.az
  local ux, uy, uz = 1, 0, 0
  if math.abs(ax) > 0.9 then ux, uy, uz = 0, 0, 1 end
  local vx, vy, vz = ay * uz - az * uy, az * ux - ax * uz, ax * uy - ay * ux
  local vl = len3(vx, vy, vz)
  vx, vy, vz = vx / vl, vy / vl, vz / vl
  ux, uy, uz = vy * az - vz * ay, vz * ax - vx * az, vx * ay - vy * ax
  local x0, y0, z0 = b.x + c.x, b.y + c.y, b.z + c.z
  for k = 0, 7 do
    local a = k / 8 * math.pi * 2
    local ca, sa = math.cos(a) * tn * L, math.sin(a) * tn * L
    draw.line(x0, y0, z0, x0 + ax * L + ux * ca + vx * sa, y0 + ay * L + uy * ca + vy * sa, z0 + az * L + uz * ca + vz * sa, 0.97, 0.34, 0.25, 0.45)
  end
  for _, d in ipairs({ L / 3, 2 * L / 3, L }) do
    draw.ring(x0 + ax * d, y0 + ay * d, z0 + az * d, ax, ay, az, d * tn, 0.97, 0.34, 0.25, d == L / 3 and 0.8 or 0.5)
  end
end
function drawFields()
  if not (draw and draw.line and draw.ring) then return 0 end
  local a = find and find("Astronaut")
  if not a then return 0 end
  local n = 0
  local bodyc = {}
  local function body(nm) local b = bodyc[nm]; if b == nil then b = space.body(nm) or false; bodyc[nm] = b end return b or nil end
  for _, s in ipairs(SRCS) do
    local b = body(s.b)
    if b and not s.dyn and len3(b.x + s.x - a.x, b.y + s.y - a.y, b.z + s.z - a.z) < 80 then
      n = n + 1
      if s.omni then
        -- where the field falls to a share an hour: 1 %, 0.5 %, 0.2 % of a lethal dose
        for _, share in ipairs({ 0.01, 0.005, 0.002 }) do
          local r = 5.0 * math.sqrt(math.max((s.rad or 0) / share, 0))
          r = math.max(r, 1.2)
          draw.ring(b.x + s.x, b.y + s.y, b.z + s.z, s.ax, s.ay, s.az, r, 1.0, 0.8, 0.28, share == 0.01 and 0.8 or 0.45)
        end
      else
        draw_cone(b, s, 9.0)
      end
    end
  end
  for key, e in pairs(live) do
    if now() - e.t > 2.0 then live[key] = nil
    else
      local b = body(e.b)
      if b then for _, c in ipairs(e.cores) do
        if len3(b.x + c.x - a.x, b.y + c.y - a.y, b.z + c.z - a.z) < 120 then draw_cone(b, c, 12.0); n = n + 1 end
      end end
    end
  end
  -- the markers: what the dose passes wrote for each member on foot
  local cl = ref("crew")
  for id, e in pairs(NOTED) do
    if now() - e.t < 1.5 and cl and cl.bodyOf then
      local nb = cl.bodyOf(id)
      if nb and nb.valid ~= false then
        local shielded = (e.f or 1) < 0.999 or (e.rate or 0) <= 0
        local r, g, bl = red(not shielded)
        local U = { x = 0, y = 1, z = 0 }
        local bb = body(e.b)
        if bb then
          local ux, uy, uz = nb.x - bb.x, nb.y - bb.y, nb.z - bb.z
          local l = len3(ux, uy, uz)
          U = { x = ux / l, y = uy / l, z = uz / l }
        end
        local cx, cy, cz = nb.x + U.x * 0.4, nb.y + U.y * 0.4, nb.z + U.z * 0.4
        draw.sphere(cx, cy, cz, 0.22, r, g, bl, 1.0)
        draw.ring(cx, cy, cz, U.x, U.y, U.z, 0.75, r, g, bl, 1.0)
        draw.ring(cx, cy, cz, U.x, U.y, U.z, 0.80, r, g, bl, 1.0)
        if bb and e.sx then
          draw.line(bb.x + e.sx, bb.y + e.sy, bb.z + e.sz, cx, cy, cz, r, g, bl, 0.35)
        end
      end
    end
  end
  return n
end

function start(node)
  if findScripts then
    local all = findScripts("base_shield")
    if #all > 1 and all[1].node and all[1].node.id ~= node.id then node:destroy() return end
  end
  WALLS, SRCS, st_ver, NOTED, live = {}, {}, nil, {}, {}
  P = { t = -10, crew_t = -10, afoot = {}, pending = {}, flush_t = -10 }
end

local clock_last = nil
function update(node, dt)
  local ST = ref("structures")
  if ST and ST.version ~= st_ver then rescan() end
  if #SRCS == 0 then return end
  local t = now()
  local every = (params and params.every) or 0.5
  if t - P.t < every then return end
  -- the step in GAME seconds (warp included), as the flight's dose pass
  local g = space and space.time and space.time() or t
  local gs = clock_last and math.max(0, math.min(g - clock_last, 3600)) or 0
  clock_last = g
  P.t = t
  pass(gs)
end

function lateUpdate(node, dt)
  local fb = ref("field_builder")
  if fb and fb.isOpen and fb.isOpen() then drawFields() end
end
