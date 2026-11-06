-- CRAFT_ORIENT — which way up a craft goes, and how it sits on a Build Stand
-- (work/standeditor/PLAN.md §3, §4; docs/base-building.md §10).
--
-- A pure RULEBOOK (no scene access; it loads in a luajit test). The builder
-- asks it to turn a craft opened at a stand (or any craft, ORIENT keys) so
-- its wheels are down and its nose along the builder's front (+X, the
-- builder's craftFront, which a stand's BuildFrame lays along the stand's
-- front); craft_stand asks it how a craft sits on the deck; the CHECK asks it
-- for the stand's own rows (S1–S7, a checkHook).
--
-- RECORDS are blueprint-shaped (flat): { uid, x, y, z, yaw, pitch, roll, h,
-- rx, rz, mass, kind, wheel, af, front, seat, thrust }, in the craft frame
-- (+Y up). The builder makes them from its parts (orientRecs).
--
--   kindOf(recs, override, CM) → "rocket"|"rover"|"aircraft", why
--   upAxis(recs, kind)         → unit vector (craft frame) that should be +Y
--   noseAxis(recs, kind, up)   → unit vector ⟂ up that should be +X, or nil
--   basisFor(recs, kind, opts) → Q {X,Y,Z} (columns, the builder's basis shape)
--                                 taking up → +Y and nose → +X, or nil when the
--                                 craft is within 5° of it already
--   axisTurn(axis, sign)       → Q of a quarter turn about a frame axis
--   apply(Q, v), mul(A, B)     → basis helpers (builder.lua's shape)
--   settle(recs, floor_y)      → dy: the lowest part box onto floor_y
--   deckFit(recs, S, CS, wc, rise, clear) → { belly, lo, hi, com, need, why }
--                                 (craft_stand.bounds + needHeight: one owner)
--   floorOffset(recs, S, CS)   → how far the belly sits over the craft's
--                                 lowest point (the editor's frame shift)
--   standRules(ctx, out, k)    → the stand's CHECK rows (a checkHook)

TURN_MIN = math.rad(5)
KINDS = { auto = true, rocket = true, plane = true, jet = true, rover = true, boat = true, station = true, probe = true }
-- a bp.kind → the orientation family
local FAMILY = { rocket = "rocket", probe = "rocket", station = "rocket", plane = "aircraft", jet = "aircraft",
                 rover = "rover", boat = "rover" }

local function V(x, y, z) return { x = x, y = y, z = z } end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b) return V(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local function sub(a, b) return V(a.x - b.x, a.y - b.y, a.z - b.z) end
local function scl(a, k) return V(a.x * k, a.y * k, a.z * k) end
local function len(a) return math.sqrt(dot(a, a)) end
local function unit(a) local l = len(a); if l < 1e-9 then return nil end return scl(a, 1 / l) end

-- A part's local axes in the craft frame (YXZ, as everywhere in Solar).
function axesOf(d)
  local cy, sy = math.cos(d.yaw or 0), math.sin(d.yaw or 0)
  local cx, sx = math.cos(d.pitch or 0), math.sin(d.pitch or 0)
  local cz, sz = math.cos(d.roll or 0), math.sin(d.roll or 0)
  local X = V(cy * cz + sy * sx * sz, cx * sz, -sy * cz + cy * sx * sz)
  local Y = V(-cy * sz + sy * sx * cz, cx * cz, sy * sz + cy * sx * cz)
  return X, Y, cross(X, Y)
end

local function is_wheel(d) return type(d.wheel) == "string" and d.wheel ~= "" end
local function af_has(d, w) return type(d.af) == "string" and (" " .. d.af .. " "):find(" " .. w) ~= nil end
local function is_gear(d) return af_has(d, "gear") end
local function is_wing(d) return af_has(d, "wing") or (type(d.af) == "table" and d.af.wing ~= nil) end
local function is_cockpit(d) return af_has(d, "cockpit") or (type(d.af) == "table" and d.af.cockpit ~= nil) end
local function is_command(d) return d.kind == "crewed" or d.kind == "probe" end

local function com(recs)
  local m, c = 0, V(0, 0, 0)
  for _, d in pairs(recs) do
    local w = math.max(1e-3, d.mass or 0.01)
    m = m + w
    c = V(c.x + w * (d.x or 0), c.y + w * (d.y or 0), c.z + w * (d.z or 0))
  end
  if m <= 0 then return V(0, 0, 0) end
  return scl(c, 1 / m)
end
comOf = com

-- What the craft is, for its orientation. A set kind (bp.kind) wins; then
-- craft_mode.autoOf when it is given; then the parts' own say.
function kindOf(recs, override, CM)
  if override and FAMILY[override] then return FAMILY[override], "set on the CRAFT tab" end
  if CM and CM.autoOf then
    local ok, m, why = pcall(CM.autoOf, recs)
    if ok and (m == "rover" or m == "aircraft" or m == "rocket") then return m, why end
  end
  local wheels, wings = 0, 0
  for _, d in pairs(recs) do
    if is_wheel(d) and not is_gear(d) then wheels = wheels + 1 end
    if is_wing(d) then wings = wings + 1 end
  end
  if wings > 0 then return "aircraft", "it has wings" end
  if wheels >= 2 then return "rover", string.format("%d wheels", wheels) end
  return "rocket", "no wings, no wheels"
end

-- The best-fit plane normal of a set of points (the largest triangle's).
local function plane_normal(pts)
  local best, ba = nil, 1e-6
  for i = 1, #pts do
    for j = i + 1, #pts do
      for k = j + 1, #pts do
        local n = cross(sub(pts[j], pts[i]), sub(pts[k], pts[i]))
        local a = len(n)
        if a > ba then best, ba = n, a end
      end
    end
  end
  return best and unit(best) or nil
end

-- Which way is up, in the craft's own frame.
function upAxis(recs, kind)
  local c = com(recs)
  if kind == "rover" or kind == "aircraft" then
    local pts = {}
    for _, d in pairs(recs) do
      if is_wheel(d) or (kind == "aircraft" and is_gear(d)) then pts[#pts + 1] = V(d.x or 0, d.y or 0, d.z or 0) end
    end
    local wc = nil
    if #pts > 0 then
      wc = V(0, 0, 0)
      for _, p in ipairs(pts) do wc = V(wc.x + p.x / #pts, wc.y + p.y / #pts, wc.z + p.z / #pts) end
    end
    local n = nil
    if #pts >= 3 then n = plane_normal(pts) end
    if not n and #pts == 2 then
      -- a bike: up is the CoM's side of the wheel line, square to it
      local line = unit(sub(pts[2], pts[1]))
      local toc = sub(c, pts[1])
      if line then n = unit(sub(toc, scl(line, dot(toc, line)))) end
    end
    if not n and kind == "aircraft" then
      -- no gear: the wings' own +Y (a wing panel's normal), summed
      local s = V(0, 0, 0)
      for _, d in pairs(recs) do
        if is_wing(d) then local _, Y = axesOf(d); s = V(s.x + Y.x, s.y + Y.y, s.z + Y.z) end
      end
      n = unit(s)
    end
    if n then
      -- away from the wheels, toward the craft's mass
      if wc and dot(n, sub(c, wc)) < 0 then n = scl(n, -1) end
      if not wc and n.y < 0 then n = scl(n, -1) end
      return n
    end
  end
  -- a rocket: the command part's own +Y (the stack's axis)
  local cmd, cu = nil, nil
  for _, d in pairs(recs) do
    if is_command(d) and (not cu or (d.uid or 0) < cu) then cmd, cu = d, d.uid or 0 end
  end
  if cmd then local _, Y = axesOf(cmd); return Y end
  return V(0, 1, 0)
end

-- Where the nose goes (the front a rollout and a stand use: a cockpit's +Y,
-- a rover body's or a seat's +X, the command part's +X), square to up.
function noseAxis(recs, kind, up)
  local cand = nil
  for _, d in pairs(recs) do
    if is_cockpit(d) then local _, Y = axesOf(d); cand = Y break end
  end
  if not cand then
    local bu = nil
    for _, d in pairs(recs) do
      if ((d.front or 0) == 1 or d.front == true or (d.seat or 0) == 1 or d.seat == true) and (not bu or (d.uid or 0) < bu) then
        cand, bu = (axesOf(d)), d.uid or 0
      end
    end
  end
  if not cand and kind ~= "rocket" then
    for _, d in pairs(recs) do
      if is_command(d) then cand = (axesOf(d)) break end
    end
  end
  if not cand then return nil end
  local n = unit(sub(cand, scl(up, dot(cand, up))))
  return n
end

-- The turn that stands it up and points its nose (a basis in the builder's
-- column shape: apply(Q, v) = X·v.x + Y·v.y + Z·v.z).
function basisFrom(up, nose)
  local w = cross(nose, up)
  return { X = V(nose.x, up.x, w.x), Y = V(nose.y, up.y, w.y), Z = V(nose.z, up.z, w.z) }
end
function angleOf(Q)
  local tr = Q.X.x + Q.Y.y + Q.Z.z
  return math.acos(math.max(-1, math.min(1, (tr - 1) / 2)))
end
-- opts = { kind, wheelsDown = true (only up), noseLevel = true (only the
-- nose, about up), force = true (return it even if small) }
function basisFor(recs, kind, opts)
  opts = opts or {}
  kind = kind or kindOf(recs)
  local up = upAxis(recs, kind)
  if opts.noseLevel then up = V(0, 1, 0) end
  local nose = (not opts.wheelsDown) and noseAxis(recs, kind, up) or nil
  if not nose then
    -- keep the craft's present heading: its +X, square to the new up (or +Z)
    nose = unit(sub(V(1, 0, 0), scl(up, up.x))) or unit(sub(V(0, 0, 1), scl(up, up.z)))
  end
  local Q = basisFrom(up, nose)
  if not opts.force and angleOf(Q) < TURN_MIN then return nil end
  return Q
end

function apply(Q, v)
  return V(Q.X.x * v.x + Q.Y.x * v.y + Q.Z.x * v.z, Q.X.y * v.x + Q.Y.y * v.y + Q.Z.y * v.z,
           Q.X.z * v.x + Q.Y.z * v.y + Q.Z.z * v.z)
end
function mul(A, B) return { X = apply(A, B.X), Y = apply(A, B.Y), Z = apply(A, B.Z) } end
-- A quarter turn about a frame axis ("x" | "y" | "z"), sign ±1 (right-handed).
function axisTurn(axis, sign)
  local s = (sign or 1) >= 0 and 1 or -1
  if axis == "x" then return { X = V(1, 0, 0), Y = V(0, 0, s), Z = V(0, -s, 0) } end
  if axis == "z" then return { X = V(0, s, 0), Y = V(-s, 0, 0), Z = V(0, 0, 1) } end
  return { X = V(0, 0, -s), Y = V(0, 1, 0), Z = V(s, 0, 0) }
end

-- A part's box (the blueprint's rx, h/2, rz turned by its pose): y extent.
local function y_extent(d, half)
  local hx = math.max(0.05, (half and half.x) or d.rx or 0.5)
  local hy = math.max(0.05, (half and half.y) or (d.h or 1.0) * 0.5)
  local hz = math.max(0.05, (half and half.z) or d.rz or 0.5)
  local X, Y, Z = axesOf(d)
  return math.abs(X.y) * hx + math.abs(Y.y) * hy + math.abs(Z.y) * hz
end
function lowest(recs, halves)
  local lo = nil
  for _, d in pairs(recs) do
    local b = (d.y or 0) - y_extent(d, halves and halves[d.uid])
    if not lo or b < lo then lo = b end
  end
  return lo
end
function settle(recs, floor_y, halves)
  local lo = lowest(recs, halves)
  if not lo then return 0 end
  return (floor_y or 0) - lo
end

-- How it sits on a stand (craft_stand's own functions, so the editor's
-- preview and commission agree). → { belly, lo, hi, com, need, why }
function deckFit(recs, S, CS, wheelClear, rise, clear)
  if not (CS and CS.bounds and CS.needHeight) then return { why = "no stand rules" } end
  local b = CS.bounds({ parts = recs }, S.deck)
  if not b then return { why = "there is nothing on the deck" } end
  local need, why = CS.needHeight(b, S, wheelClear or 0.10, rise or 0, clear or 0.02)
  return { belly = b.belly, lo = b.lo, hi = b.hi, com = b.com, need = need, why = why, b = b }
end
-- How far the craft's belly sits over its lowest point (0 when nothing rests
-- on the deck: the builder's floor is then the deck's top).
function floorOffset(recs, S, CS)
  local f = deckFit(recs, S, CS)
  if not (f.belly and f.lo) then return 0 end
  return math.max(0, f.belly - f.lo)
end

-- ── THE STAND'S CHECK ROWS (builder.checkHook("stand", standRules)) ─────────
-- ctx.stand = { body, home, g, air, slope (deg), slopeDir, h, need, needWhy,
--   deckR, front = { name, d } | nil (the release path), plume = { name, d }
--   | nil, standing = bool, added = $ the diff adds, away = bool, wheeled,
--   thrust = bool, holdDeg }
SLOPE_ROCKET = 3.0
SLOPE_ROVER = 12.0
local function row(out, id, sev, rank, head, text)
  out[#out + 1] = { id = id, sev = sev, rank = rank, kind = "stand", head = head, text = text, uids = {} }
end
function standRules(ctx, out, k)
  local s = ctx and ctx.stand
  if not s then return end
  local wheeled = s.wheeled == true
  -- S6 the stand's height
  if s.need == nil then
    row(out, "S6", "block", 0, "The stand can't hold it", s.needWhy or "nothing of it rests on the deck: put a part over its centre of mass")
  end
  -- S5 the Engineer in the craft's box
  if s.standing then
    row(out, "S5", "warn", 0, "You're standing where it goes", "You're standing where the craft goes: step back before Commission")
  end
  -- S7 off the home world
  if s.away and (s.added or 0) > 0 then
    row(out, "S7", "block", 0, "Parts aren't shipped here", "Off the home world a part is made, not shipped: the Fabricator comes later")
  end
  -- S1 the ground's slope
  local lim = wheeled and (s.holdDeg or SLOPE_ROVER) or SLOPE_ROCKET
  if (s.slope or 0) > lim then
    row(out, "S1", "warn", 1, string.format("The ground tilts %.0f°", s.slope),
      string.format("The ground tilts %.0f°%s: released, it %s. Park with the brake, or build on a Pad Plate",
        s.slope, s.slopeDir and (" toward the " .. s.slopeDir) or "", wheeled and "rolls" or "leans off the deck"))
  end
  -- S3 the release path (a craft let down onto its wheels drives off ahead)
  if wheeled and s.front then
    row(out, "S3", "warn", 1, "Something is in its way",
      string.format("Something is %.1f m in front of it: %s", s.front.d or 0, tostring(s.front.name or "something")))
  end
  -- S4 the plume (a craft that lifts off)
  if not wheeled and s.thrust and s.plume then
    row(out, "S4", "warn", 1, "Too close to the base",
      string.format("%s is %.0f m from the plume", tostring(s.plume.name or "a structure"), s.plume.d or 0))
  end
  -- S2 another world
  if s.body and s.home and s.body ~= s.home then
    row(out, "S2", "note", 2, "Built on " .. tostring(s.body),
      string.format("Built on %s: g %.1f m/s²%s — TWR and jets read for here", tostring(s.body), s.g or 0,
        s.air and string.format(", air %.2f", s.air) or ""))
  end
end
