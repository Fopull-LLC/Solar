-- THE CRAFT CHECK'S TEST CRAFT (tests/smoke_craft_check.lua): blueprint
-- fragments built in code, each a variant of a reference craft so a rule's
-- trigger is one change away from a craft that passes.
--
--   lightjet(o)   smoke_aero's light jet laid level for the runway (nose +X,
--                 top +Y): cockpit, fuselage tank, Wasp, two Wing Panel L and
--                 tips, two elevons, a tail fin, two Ram Intakes, three gear.
--                 o.intakes (0|1|2), o.upright (every part turned so the nose
--                 is +Y, as built standing up in the VAB), o.wingdx (wings and
--                 tips moved along the nose), o.elevons = false, o.maindx (the
--                 main gear moved along the nose)
--   starter(o)    pod, chute, FT-S, Sputter stacked; o.tanks = { ids } under
--                 the pod instead, o.engine = false, o.chutes = n
--   twostage(o)   Sputter, FT-M, decoupler, then the upper stage: o.upper =
--                 { ids, bottom first } under a probe core
--   faired(o)     Sputter, FT-M, a 1.25 m fairing base, a probe and a battery
--   probe(o)      Sputter, FT-S, probe core; o.antenna, o.battery
--   rover(o)      Rover Body on four Wheel M; o.mast (a battery that high
--                 over the body), o.track (the wheels' spread)
--   lattice(n)    a probe core and n−1 hubs in a column (perf)
--
-- Records are the builder's blueprint parts: { uid, id, x, y, z, yaw, pitch,
-- roll, parent, att }. Poses come from axes (X, Y): eulerOf inverts the
-- builder's rot_basis (aero.axes).

local M = {}
local function cross(a, b) return { x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x } end
local function unit(v) local l = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) return { x = v.x / l, y = v.y / l, z = v.z / l } end
function M.eulerOf(X, Y, Z)
  local pitch = math.asin(math.max(-1, math.min(1, -Z.y)))
  if math.abs(Z.y) > 1 - 1e-10 then return math.atan2(-X.z, X.x), pitch, 0 end
  return math.atan2(Z.x, Z.z), pitch, math.atan2(X.y, Y.y)
end

-- a builder: add(id, x, y, z, X, Y, parent, att) → the record
local function maker(rot)
  local P, uid = {}, 0
  local function R(v) return rot and rot(v) or v end
  local function add(id, x, y, z, X, Y, parent, att, extra)
    uid = uid + 1
    X, Y = R(X or { x = 1, y = 0, z = 0 }), R(Y or { x = 0, y = 1, z = 0 })
    local p = R({ x = x, y = y, z = z })
    local yaw, pitch, roll = M.eulerOf(X, Y, cross(X, Y))
    local r = { uid = uid, id = id, x = p.x, y = p.y, z = p.z, yaw = yaw, pitch = pitch, roll = roll,
                parent = parent or 0, att = att or "", sym = 0, stage = 0 }
    for k, v in pairs(extra or {}) do r[k] = v end
    P[#P + 1] = r
    return r
  end
  return add, P
end

local NOSE, TOP = { x = 1, y = 0, z = 0 }, { x = 0, y = 1, z = 0 }
function M.lightjet(o)
  o = o or {}
  -- standing up: +X (the nose) turned to +Y, +Y to −X
  local rot = o.upright and function(v) return { x = -v.y, y = v.x, z = v.z } end or nil
  local add, P = maker(rot)
  local Y0 = 1.5
  local cZ = { x = 0, y = -1, z = 0 }
  local cX = cross(NOSE, cZ)
  local ck = add("cockpit", 1.9, Y0, 0, cX, NOSE)
  local ft = add("fuseTank", -0.2, Y0, 0, cX, NOSE, ck.uid, "bottom")
  local jt = add("jet", -2.1, Y0, 0, cX, NOSE, ft.uid, "bottom")
  local wdx, mdx = o.wingdx or 0, o.maindx or 0
  local ni = o.intakes or 2
  for k, s in ipairs({ 1, -1 }) do
    local out = { x = 0, y = 0, z = s }
    local w = add("wingL", -0.6 + wdx, Y0, s * (0.5 + 1.75), out, NOSE, ft.uid, "surface")
    add("wingTip", -0.6 + wdx, Y0, s * (0.5 + 3.5 + 0.6), out, NOSE, w.uid, "surface")
    if o.elevons ~= false then add("elevon", -2.35, Y0, s * (0.5 + 0.8), out, NOSE, jt.uid, "surface") end
    if k <= ni then
      local ia = unit({ x = 0, y = 0.707, z = s * 0.707 })
      add("intake", 0.2, Y0 + ia.y * 0.7, ia.z * 0.7, ia, NOSE, ft.uid, "surface")
    end
    -- (the main gear hangs under the wing: it moves with it, and o.maindx
    -- moves it alone, within the wing's chord)
    add("gearM", -0.45 + wdx + mdx, 0.75, s * 1.4, { x = 0, y = -1, z = 0 }, NOSE, w.uid, "surface")
  end
  local tf = add("tailFin", -2.3, Y0 + 0.5 + 0.75, 0, TOP, NOSE, jt.uid, "surface")
  add("gearS", 2.3, 0.5, 0, { x = 0, y = -1, z = 0 }, NOSE, ck.uid, "surface")
  -- o.hubs: a column of Strut Hubs on the fin's tip (a big craft for perf)
  local prev, y = tf, Y0 + 0.5 + 1.5
  for _ = 1, o.hubs or 0 do
    prev = add("hub", -2.3, y + 0.12, 0, nil, nil, prev.uid, "top")
    y = y + 0.24
  end
  return { parts = P }
end

-- a column, bottom up: ids → records stacked on each other's top
local function column(add, REG, ids, y, parent)
  local prev = parent
  local out = {}
  for _, id in ipairs(ids) do
    local h = REG[id].h
    local r = add(id, 0, y + h / 2, 0, nil, nil, prev and prev.uid or 0, prev and "top" or "")
    y = y + h
    prev = r
    out[#out + 1] = r
  end
  return out, y, prev
end

function M.starter(REG, o)
  o = o or {}
  local add, P = maker()
  local ids = {}
  if o.engine ~= false then ids[#ids + 1] = "engineS" end
  for _, t in ipairs(o.tanks or { "tankS" }) do ids[#ids + 1] = t end
  ids[#ids + 1] = "pod"
  local col, y, pod = column(add, REG, ids, 0)
  for i = 1, (o.chutes or 1) do
    if i == 1 then add("chute", 0, y + REG.chute.h / 2, 0, nil, nil, pod.uid, "top")
    else
      local a = (i - 2) * math.pi
      local X = { x = math.cos(a), y = 0, z = math.sin(a) }
      add("chute", X.x * 0.62, pod.y, X.z * 0.62, { x = 0, y = 0, z = 1 }, X, pod.uid, "surface")
    end
  end
  return { parts = P }
end

function M.twostage(REG, o)
  o = o or {}
  local add, P = maker()
  local col, y, top = column(add, REG, { "engineS", "tankM", "decoupler" }, 0)
  local up = o.upper or { "engineS", "tankS" }
  local col2, y2, top2 = column(add, REG, up, y, top)
  local c3, y3, pr = column(add, REG, { "probe" }, y2, top2)
  return { parts = P, dec = top.uid }
end

function M.faired(REG, o)
  o = o or {}
  local add, P = maker()
  local col, y, fb = column(add, REG, { "engineS", "tankM", "fairingS" }, 0)
  local c2, y2, pr = column(add, REG, { "probe", "battery" }, y, fb)
  return { parts = P, base = fb.uid, payload = { c2[1].uid, c2[2].uid } }
end

function M.probe(REG, o)
  o = o or {}
  local add, P = maker()
  local col, y, pr = column(add, REG, { "engineS", "tankS", "probe" }, 0)
  return { parts = P, probe = pr.uid }
end

function M.rover(REG, o)
  o = o or {}
  local add, P = maker()
  local body = add("roverBody", 0, 0.55, 0)
  local tw = o.track or 1.1
  for _, sx in ipairs({ 0.55, -0.55 }) do
    for _, sz in ipairs({ 1, -1 }) do
      -- the wheel's +X (its axle) out along ±Z
      add("wheelM", sx, 0.4, sz * tw / 2, { x = 0, y = 0, z = sz }, { x = 1, y = 0, z = 0 }, body.uid, "surface")
    end
  end
  if o.mast then
    local h = REG.battery.h
    local prev = body
    local y = 0.55 + REG.roverBody.h / 2
    for i = 1, o.mast do
      prev = add("battery", 0, y + h / 2, 0, nil, nil, prev.uid, "top")
      y = y + h
    end
  end
  return { parts = P }
end

-- nuclear(o): an Ember reactor with a pod on top (in its cone), a chute;
-- o.shield puts a Shadow Shield between them, o.panels = n Radiator Panels
-- on the reactor's flanks
function M.nuclear(REG, o)
  o = o or {}
  local add, P = maker()
  local ids = { "ember" }
  if o.shield then ids[#ids + 1] = "shadowShield" end
  ids[#ids + 1] = "pod"
  local col, y, pod = column(add, REG, ids, 0)
  add("chute", 0, y + REG.chute.h / 2, 0, nil, nil, pod.uid, "top")
  local core = col[1]
  for i = 1, o.panels or 0 do
    local a = (i - 1) * 2 * math.pi / math.max(1, o.panels)
    local X = { x = math.cos(a), y = 0, z = math.sin(a) }
    local r = (REG.ember.rx or 0.5) + (REG.radPanel.rx or 0.62)
    add("radPanel", X.x * r, core.y, X.z * r, X, { x = 0, y = 1, z = 0 }, core.uid, "surface")
  end
  return { parts = P, core = core.uid, pod = pod.uid }
end

function M.lattice(REG, n)
  local add, P = maker()
  local col, y, prev = column(add, REG, { "probe" }, 0)
  local h = REG.hub.h
  for i = 2, n do
    prev = add("hub", 0, y + h / 2, 0, nil, nil, prev.uid, "top")
    y = y + h
  end
  return { parts = P }
end

return M
