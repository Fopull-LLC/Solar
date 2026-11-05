-- SMOKE: the fairing redesign (deep-space proposal §6, E1–E6) — the rulebook
-- (electronics.lua) and the builder (builder.lua):
--
--   * E1 the profile you drag: handles → profile (and the fitted shell as
--     handles is the fitted shell), drags clamp and push instead of refusing,
--     the record's flat list round-trips;
--   * E3 FIT: what sticks out is held after it, with the clearance, and
--     nothing that was held lets go; a drawn ring shape grows too; an open
--     top leaves the stage above it alone;
--   * E4 the split: three pieces at 120° with a seam on +X (none leaves along
--     it), halves along ±Z, every piece's mesh inside its own span; the hinge
--     keeps its pivot and swings the top out;
--   * E5 the debris box at the outer skin never reaches into the payload, at
--     the shut and the opened pose;
--   * E6 a new fairing's stage: just before the first stage that fires a
--     decoupler above its base, else after the lifter; auto-drop;
--   * the builder: a base hung UNDER its payload grows a shell (E2), a handle
--     drag re-lathes without touching craftVersion and lands as one save
--     (fhp + fprof), reloads, FIT / open / pieces / auto / reset commands,
--     the stage card's auto-drop.
--
--   luajit solar/tests/smoke_fairing_shape.lua   (from the Floptle repo root)

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

local Eenv = setmetatable({}, { __index = _G })
local ec = assert(loadfile("solar/scripts/electronics.lua"))
setfenv(ec, Eenv)
ec()
local E = Eenv
E.valid = true

-- ── 1. E1: handles → profile ────────────────────────────────────────────────
do
  local y0 = 0.1
  local hp = E.fairingHandlesFit(0.7, y0, 2.0, 0.77)
  local prof = E.fairingHandleProfile(hp, y0)
  local auto = E.fairingAutoProfile(0.7, y0, 2.0, 0.77)
  check(prof[1][1] == 0.7 and prof[1][2] == y0, "the handle profile starts at the base handle")
  check(near(prof[3][2], 2.0) and prof[#prof][1] == 0 and near(prof[#prof][2], 2.77), "…the top at the barrel's top, an apex at the nose tip")
  -- the fitted shell as handles IS the fitted shell: same radius everywhere
  local same = true
  for y = y0, 2.77, 0.05 do
    local a, b = E.fairingRadiusAt(prof, y), E.fairingRadiusAt(auto, y)
    if not (a and b and near(a, b, 1e-6)) then same = false end
  end
  check(same, "the fitted shell as handles has the fitted shell's radius at every height")
  local a1 = E.fairingStats(prof)
  local a2 = E.fairingStats(auto)
  check(near(a1, a2, 1e-6), string.format("…and its skin area (%.4f vs %.4f m²)", a1, a2))
  local pts = E.fairingHandlePoints(hp, y0)
  check(#pts == 4 and pts[1].key == "base" and pts[4].key == "nose" and pts[4].r == 0, "four handles: base, shoulder, top, nose tip on the axis")

  -- drags: nothing refused, neighbours pushed
  local n, ch = E.fairingHandleDrag(hp, "shoulder", 0.9, 2.5)
  check(ch and n.rs == 0.9 and n.hs == 2.5 and near(n.ht, 2.5 + E.FAIRING_GAP), "a shoulder dragged over the top lifts the top")
  n = E.fairingHandleDrag(hp, "top", 0.6, 0.02)
  check(near(n.ht, 2 * E.FAIRING_GAP) and n.hs <= n.ht - E.FAIRING_GAP + 1e-9 and n.hs >= E.FAIRING_GAP - 1e-9,
    "a top dragged under the shoulder pushes the shoulder down (and stops at the floor)")
  n = E.fairingHandleDrag(hp, "nose", 0, hp.ht - 1)
  check(n.hn == 0.15, "the nose never goes shorter than 15 cm")
  n = E.fairingHandleDrag(hp, "base", 99, 0)
  check(n.rb == E.FAIRING_R_MAX, "radii clamp to the largest a shell may be")
  local _, same2 = E.fairingHandleDrag(hp, "base", hp.rb, 0)
  check(not same2, "a drag to where the handle already is changes nothing (no rebuild)")
  check(near(E.fairingSnap(0.83), 0.85) and near(E.fairingSnap(0.31), 0.3), "shift snaps to 5 cm")
  local f = E.fairingHandlesFlat(n)
  local back = E.fairingHandlesUnflat(f)
  check(back and back.rb == n.rb and back.hs == n.hs and back.hn == n.hn and back.open == false, "the record's flat list round-trips")
  local op = E.fairingHandlesCopy(hp); op.open = true
  local po = E.fairingHandleProfile(op, y0)
  check(#po == 3 and po[3][1] == hp.rt and E.fairingHandlesUnflat(E.fairingHandlesFlat(op)).open, "an open top ends at its top ring (no nose)")
end

-- ── 2. E3: FIT ──────────────────────────────────────────────────────────────
do
  local y0 = 0.1
  local hp = E.fairingHandlesFit(0.7, y0, 2.0, 0.77)
  local pls = {
    wide = { lo = 0.5, hi = 1.2, rad = 0.75 },      -- wider than the barrel
    tall = { lo = 1.2, hi = 2.72, rad = 0.35 },     -- into the nose
    fine = { lo = 0.2, hi = 0.4, rad = 0.3 },       -- already held
  }
  local before = E.fairingHandleProfile(hp, y0)
  check(not E.fairingHolds(before, 0.5, 1.2, 0.75) and not E.fairingHolds(before, 1.2, 2.72, 0.35), "two parts stick out")
  local n = E.fairingFitHandles(hp, y0, pls)
  local after = E.fairingHandleProfile(n, y0)
  local all = true
  for _, pl in pairs(pls) do if not E.fairingHolds(after, pl.lo, pl.hi, pl.rad) then all = false end end
  check(all, "FIT: every part is held")
  -- just enough: the barrel is the wide part plus the clearance, not a fat can
  check(near(n.rs, 0.75 + E.FAIRING_MARGIN, 1e-6) and near(n.rt, 0.75 + E.FAIRING_MARGIN, 1e-6),
    string.format("…the barrel grew to the part's radius + %.0f cm (%.3f m)", E.FAIRING_MARGIN * 100, n.rt))
  check(n.rb == hp.rb and n.hs == hp.hs, "…the base and the shoulder height it didn't need stay")
  for y = y0, 2.7, 0.05 do
    local a, b = E.fairingRadiusAt(before, y), E.fairingRadiusAt(after, y)
    if a and (not b or b < a - 1e-9) then all = false end
  end
  check(all, "…and the shell only grew (nothing it held lets go)")
  -- a narrow tall part goes into a longer nose, not a fatter barrel
  local hp2 = E.fairingHandlesFit(0.7, y0, 2.0, 0.77)
  local n2 = E.fairingFitHandles(hp2, y0, { tall = { lo = 1.5, hi = 3.0, rad = 0.2 } })
  check(near(n2.rt, 0.7) and n2.hn > 0.77 and E.fairingHolds(E.fairingHandleProfile(n2, y0), 1.5, 3.0, 0.2),
    string.format("a thin mast lengthens the nose (%.2f → %.2f m), the barrel stays", 0.77, n2.hn))
  -- a drawn ring shape grows its rings (the base ring stays)
  local secs = E.fairingFitRings(0.625, y0, { { r = 0.7, h = 0.3 }, { r = 0.7, h = 1.5 } }, pls)
  local pr = E.fairingSectionsProfile(0.625, y0, secs, true)
  all = true
  for _, pl in pairs(pls) do if not E.fairingHolds(pr, pl.lo, pl.hi, pl.rad) then all = false end end
  check(all and pr[1][1] == 0.625, "FIT on a drawn ring shape holds them all, from the same base ring")
  -- an open top: the stage above it is not "sticking out"
  local op = E.fairingHandlesFit(0.7, y0, 1.6, 0.77); op.open = true
  local prof = E.fairingHandleProfile(op, y0)
  local load, out, above = E.fairingSort(prof, { eng = { lo = 0.2, hi = 1.2, rad = 0.4 }, tank = { lo = 1.6, hi = 3.0, rad = 0.62 } }, true)
  check(load.eng and above.tank and not out.tank, "an inter-stage skirt holds the engine; the tank over it is above, not out")
  local fo = E.fairingFitHandles(op, y0, { eng = { lo = 0.2, hi = 1.2, rad = 0.4 }, tank = { lo = 1.6, hi = 3.0, rad = 0.62 } })
  check(near(fo.ht, op.ht) and fo.open, "FIT on a skirt leaves its top ring under the stage above")
end

-- ── 3. E4: the split and the hinge ──────────────────────────────────────────
do
  local deg = 180 / math.pi
  local a = {}
  for k = 1, 3 do a[k] = E.fairingPieceAngle(k, 3) end
  check(near((a[2] - a[1]) * deg, 120, 1e-9) and near((a[3] - a[2]) * deg, 120, 1e-9), "three pieces sit 120° apart")
  local clear = true
  for k = 1, 3 do
    local off = math.abs(math.atan2(math.sin(a[k]), math.cos(a[k]))) * deg
    if off < 60 - 1e-9 then clear = false end
  end
  check(clear, "no piece of three leaves along the base's +X (each ≥ 60° off it: a seam lies on +X)")
  local s3 = E.fairingSeams(3)
  check(near(s3[1], 0) and near(s3[2] * deg, 120) and near(s3[3] * deg, 240), "…the seams at 0°, 120°, 240°")
  check(near(math.sin(E.fairingPieceAngle(1, 2)), 1) and near(math.sin(E.fairingPieceAngle(2, 2)), -1), "halves leave along ±Z")
  -- every piece's mesh lies inside its own span
  local prof = E.fairingSectionsProfile(0.6, 0.1, { { r = 0.8, h = 0.3 }, { r = 0.8, h = 1.5 } }, true)
  for _, n in ipairs({ 2, 3 }) do
    for k = 1, n do
      local m = E.fairingPiece(prof, k, n, 24)
      local ac = E.fairingPieceAngle(k, n)
      local ok = true
      for i = 1, #m.positions, 3 do
        local x, z = m.positions[i], m.positions[i + 2]
        if x * x + z * z > 1e-6 then
          local d = math.atan2(math.sin(math.atan2(z, x) - ac), math.cos(math.atan2(z, x) - ac))
          if math.abs(d) > math.pi / n + 1e-6 then ok = false end
        end
      end
      check(ok, string.format("piece %d of %d: its mesh is inside its own span", k, n))
    end
  end
  -- the hinge: shut is no turn; open keeps the pivot and swings the top out
  local H0 = E.fairingHinge(prof, 2, 3, 0)
  check(near(H0.X[1], 1) and near(H0.Y[2], 1) and near(H0.Z[3], 1) and near(H0.pos[1], 0) and near(H0.pos[2], 0),
    "shut: the shell sits where it was built")
  local th = math.rad(E.FAIRING_OPEN_DEG)
  local H = E.fairingHinge(prof, 2, 3, th)
  local function apply(Hh, v)
    return { Hh.pos[1] + Hh.X[1] * v[1] + Hh.Y[1] * v[2] + Hh.Z[1] * v[3],
             Hh.pos[2] + Hh.X[2] * v[1] + Hh.Y[2] * v[2] + Hh.Z[2] * v[3],
             Hh.pos[3] + Hh.X[3] * v[1] + Hh.Y[3] * v[2] + Hh.Z[3] * v[3] }
  end
  local p = apply(H, H.p)
  check(near(p[1], H.p[1]) and near(p[2], H.p[2]) and near(p[3], H.p[3]), "open: the hinge point stays on the base ring")
  local top = { 0.8 * H.d[1], 1.6, 0.8 * H.d[3] }
  local t2 = apply(H, top)
  local out0 = top[1] * H.d[1] + top[3] * H.d[3]
  local out1 = t2[1] * H.d[1] + t2[3] * H.d[3]
  check(out1 > out0 + 0.5 and near(t2[1] * H.A[1] + t2[3] * H.A[3], top[1] * H.A[1] + top[3] * H.A[3], 1e-9),
    string.format("open %d°: the top swings out %.2f m, along its own way only", E.FAIRING_OPEN_DEG, out1 - out0))
end

-- ── 4. E5: the debris box never reaches into the payload ─────────────────────
do
  -- the fitted shell round a payload as wide as it allows (radius − 8 cm)
  for _, R in ipairs({ 0.625, 0.9, 1.25, 2.0 }) do
    local prof = E.fairingAutoProfile(R, 0.1, 2.5, R * 1.1)
    local pay = R - 0.08
    for _, n in ipairs({ 2, 3 }) do
      for _, th in ipairs({ 0, math.rad(E.FAIRING_OPEN_DEG) }) do
        local worst = math.huge
        for k = 1, n do
          local b = E.fairingPieceBody(prof, k, n, th)
          -- the box's 8 corners and its inner face's centre: distance from the axis
          for _, sx in ipairs({ -1, 1 }) do for _, sy in ipairs({ -1, 1 }) do for _, sz in ipairs({ -1, 0, 1 }) do
            local hz = (sz == 0) and -b.hz or sz * b.hz
            local x = b.O[1] + b.BX[1] * sx * b.hx + b.BY[1] * sy * b.hy + b.BZ[1] * hz
            local y = b.O[2] + b.BX[2] * sx * b.hx + b.BY[2] * sy * b.hy + b.BZ[2] * hz
            local z = b.O[3] + b.BX[3] * sx * b.hx + b.BY[3] * sy * b.hy + b.BZ[3] * hz
            if y > 0.1 and y < 2.5 then worst = math.min(worst, math.sqrt(x * x + z * z)) end
            -- the inner face's middle (the nearest the box comes to the axis)
          end end end
          local ix = b.O[1] - b.BZ[1] * b.hz
          local iz = b.O[3] - b.BZ[3] * b.hz
          worst = math.min(worst, math.sqrt(ix * ix + iz * iz))
        end
        check(worst >= pay - 1e-6, string.format("R %.3f, %d pieces, %s: the box keeps %.3f m from the axis (payload ≤ %.3f)",
          R, n, th == 0 and "shut" or "open", worst, pay))
      end
    end
    local b = E.fairingPieceBody(prof, 1, 2, 0)
    check(near(b.hz, E.FAIRING_SKIN_T) and near(b.cr + b.hz, R + 0.02), string.format("R %.3f: a thin box at the outer skin", R))
  end
  -- the opened normal points out (and the release velocity with it)
  local prof = E.fairingAutoProfile(0.7, 0.1, 2.0, 0.77)
  local b = E.fairingPieceBody(prof, 1, 2, math.rad(28))
  check(b.N[1] * b.hinge.d[1] + b.N[3] * b.hinge.d[3] > 0.85 and b.N[2] < 0, "the opened piece's normal points out (and a little back)")
  -- the shell under the body: body · child = the base frame (the mesh lands where it was)
  local function ap(bb, v)
    -- child local → body local → base
    local cx = bb.cpos[1] + bb.cX[1] * v[1] + bb.cY[1] * v[2] + bb.cZ[1] * v[3]
    local cy = bb.cpos[2] + bb.cX[2] * v[1] + bb.cY[2] * v[2] + bb.cZ[2] * v[3]
    local cz = bb.cpos[3] + bb.cX[3] * v[1] + bb.cY[3] * v[2] + bb.cZ[3] * v[3]
    return { bb.O[1] + bb.BX[1] * cx + bb.BY[1] * cy + bb.BZ[1] * cz,
             bb.O[2] + bb.BX[2] * cx + bb.BY[2] * cy + bb.BZ[2] * cz,
             bb.O[3] + bb.BX[3] * cx + bb.BY[3] * cy + bb.BZ[3] * cz }
  end
  local b0 = E.fairingPieceBody(prof, 1, 2, 0)
  local q = ap(b0, { 0.3, 1.0, 0.6 })
  check(near(q[1], 0.3) and near(q[2], 1.0) and near(q[3], 0.6), "shut, the released shell lands exactly on the built one")
  local H = E.fairingHinge(prof, 1, 2, math.rad(28))
  local q2 = ap(b, { 0.3, 1.0, 0.6 })
  local h2 = { H.pos[1] + H.X[1] * 0.3 + H.Y[1] * 1.0 + H.Z[1] * 0.6, H.pos[2] + H.X[2] * 0.3 + H.Y[2] * 1.0 + H.Z[2] * 0.6,
               H.pos[3] + H.X[3] * 0.3 + H.Y[3] * 1.0 + H.Z[3] * 0.6 }
  check(near(q2[1], h2[1]) and near(q2[2], h2[2]) and near(q2[3], h2[3]), "open, the released shell lands on the swung one (no jump)")
  check(E.fairingAutoDue(70, 0.29, true) and not E.fairingAutoDue(70, 0.31, true) and not E.fairingAutoDue(0, 0, true)
    and not E.fairingAutoDue(70, 0, false), "auto-drop at 70 % of the air: under 30 % of it left, never off, never airless")
end

-- ── 5. E6: where a new fairing is staged ─────────────────────────────────────
do
  local f = assert(io.open("solar/scripts/builder.lua", "r"))
  local src = f:read("*a")
  f:close()
  local a = src:find("-- ══ STAGE MODEL BEGIN", 1, true)
  local b = src:find("-- ══ STAGE MODEL END", 1, true)
  local env = setmetatable({}, { __index = _G })
  local chunk = assert(loadstring(src:sub(a, b - 1), "STAGE"))
  setfenv(chunk, env)
  chunk()
  local SM = env.STAGEM
  local function ord(t) local o = {}; for i, g in ipairs(t) do o[i] = table.concat(g, "+") end; return table.concat(o, " ") end
  -- a lifter cut (u3) under the base, a payload release (u12) inside the shell over it
  local items = {
    u3 = { key = "u3", y = 2.0, uids = { 3 } },
    u12 = { key = "u12", y = 7.0, uids = { 12 } },
    u9 = { key = "u9", fair = true, y = 6.5, uids = { 9 } },
    c = { key = "c", chute = true, y = 9.0, uids = { 10 } },
  }
  local st = SM.sync({}, items, {})
  check(ord(st) == "u3 u9 u12 c", "a fresh craft: lifter, fairing, payload release, chutes (" .. ord(st) .. ")")
  -- added later to a craft whose stages are set (the payload release merged with the lifter)
  local staged = { { "u3", "u12" }, { "c" } }
  staged[0] = {}
  local items2 = { u3 = items.u3, u12 = items.u12, c = items.c, u9 = items.u9 }
  st = SM.sync(staged, items2, {})
  check(ord(st) == "u9 u3+u12 c", "a new fairing goes before the first stage that lets the payload go (" .. ord(st) .. ")")
  -- a later payload release stage: just before it, after the lifter
  staged = { { "u3" }, { "u12" }, { "c" } }
  staged[0] = {}
  st = SM.sync(staged, items2, {})
  check(ord(st) == "u3 u9 u12 c", "…between the lifter and the payload release (" .. ord(st) .. ")")
  -- nothing above the base: after the lifter, before the chutes moved first
  staged = { { "c" }, { "u3" } }
  staged[0] = {}
  st = SM.sync(staged, { u3 = items.u3, c = items.c, u9 = items.u9 }, {})
  check(ord(st) == "c u3 u9", "no decoupler above it: it follows the lifter (" .. ord(st) .. ")")
  check(SM.fairAt({ { "u3" }, { "u12" } }, items, items.u9) == 2, "fairAt: the stage of the first decoupler above the base")
end

-- ── 6. the builder ──────────────────────────────────────────────────────────
local REGENV = setmetatable({}, { __index = _G })
do
  local rc = assert(loadfile("solar/scripts/parts_registry.lua"))
  setfenv(rc, REGENV)
  rc()
end
local T = 0
local nodes = {}
local function make_node(name, x, y, z)
  local n = { id = #nodes + 1, name = name, valid = true, visible = true, x = x or 0, y = y or 0, z = z or 0,
              pitch = 0, roll = 0, yaw = 0, text = "", components = {} }
  n.getcomponent = function(self, k) return self.components[k] end
  n.uiRect = function() return 0, 0, 0, 0 end
  nodes[#nodes + 1] = n
  return n
end
local store = {}
local stub = setmetatable({}, { __index = function() return function() end end })
local built = 0
local API = {
  vec3 = function(x, y, z) return { x = x, y = y, z = z } end,
  destroy = function(n) n.valid = false end,
  find = function(name) for _, n in ipairs(nodes) do if n.valid and n.name == name then return n end end end,
  print = function() end, log = function() end,
  spawn = function(prefab, pos, cb) local n = make_node(prefab, pos.x, pos.y, pos.z) if cb then cb(n) end end,
  save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end, flush = function() end },
  findScript = function(k)
    if k == "electronics" then return E end
    if k == "parts_registry" then return REGENV end
    return nil
  end,
  findScripts = function() return {} end,
  input = { key = function() return false end, pressed = function() return false end, button = function() return false end,
            mouse = function() return 0, 0 end },
  camera = { worldToScreen = function() return 0, 0, 1, true end, screenSize = function() return 1280, 720 end,
             screenToRay = function() return 0, 10, 0, 0, -1, 0 end },
  mesh = { build = function() built = built + 1; return "m" .. built end, free = function() end },
  draw = stub, audio = stub, scene = { load = function() end }, raycast = function() return nil end,
}
make_node("BuildStats"); make_node("BuildHint")
local env = setmetatable({}, { __index = function(_, k)
  if k == "time" then return T end
  return API[k] or _G[k]
end })
local function P(t)
  local d = { yaw = 0, pitch = 0, roll = 0, parent = 0, att = "", sym = 0, stage = 0 }
  for k, v in pairs(t) do d[k] = v end
  return d
end
local function rec_of(bp, uid) for _, d in ipairs(bp.parts) do if d.uid == uid then return d end end end

-- E2: a stack built from the TOP down: the probe is the root, the fairing
-- base hangs under it (its parent is the payload), the tank and engine under that
store["shipyard.blueprint"] = { parts = {
  P{ uid = 1, id = "probe", x = 0, y = 3.21, z = 0 },
  P{ uid = 2, id = "fairingS", x = 0, y = 2.9, z = 0, parent = 1, att = "bottom" },
  P{ uid = 3, id = "tankM", x = 0, y = 2.05, z = 0, parent = 2, att = "bottom" },
  P{ uid = 4, id = "engineS", x = 0, y = 0.65, z = 0, parent = 3, att = "bottom" },
} }
local chunk = assert(loadfile("solar/scripts/builder.lua"))
setfenv(chunk, env)
chunk()
env.params = {}
for k, v in pairs(env.defaults or {}) do env.params[k] = v end
env.start(make_node("Builder"))
local fit = env.fairingFit(2)
check(fit and fit.load and fit.load[1] and not fit.load[3] and not fit.load[4],
  "E2: a base hung under its payload grows a shell round the payload (and not round the stage below)")
env.doSave()
check(rec_of(store["shipyard.blueprint"], 1).faired == 2, "…and the probe rides inside it in flight")

-- a bottom-up stack for the handles
store["shipyard.blueprint"] = { parts = {
  P{ uid = 1, id = "engineS", x = 0, y = 0.65, z = 0 },
  P{ uid = 2, id = "tankM", x = 0, y = 2.05, z = 0, parent = 1, att = "top" },
  P{ uid = 3, id = "fairingS", x = 0, y = 2.9, z = 0, parent = 2, att = "top", stage = 1 },
  P{ uid = 4, id = "probe", x = 0, y = 3.21, z = 0, parent = 3, att = "top" },
  P{ uid = 5, id = "battery", x = 0, y = 3.92, z = 0, parent = 4, att = "top" },
} }
env.start(make_node("Builder"))
local f0 = env.fairingFit(3)
check(f0 and f0.kind == "fitted" and f0.nout == 0, "a fresh base fits its payload")
local v0, s0 = env.craftVersion, env.fairingShapeVersion()
local hp0 = env.fairing_handles_of(3, f0)
check(hp0 and hp0.rb == f0.env.r, "the fitted shell offers its handles")
check(env.fairingHandleSet(3, "top", hp0.rt + 0.2, hp0.ht + 0.5, false), "dragging the top handle changes the shell")
check(env.craftVersion == v0 and env.fairingShapeVersion() > s0, "…without touching craftVersion (only the shell's own version)")
local s1 = env.fairingShapeVersion()
check(not env.fairingHandleSet(3, "top", hp0.rt + 0.2, hp0.ht + 0.5, false) and env.fairingShapeVersion() == s1,
  "the same spot again: no change, no rebuild")
env.fairingHandleSet(3, "base", 0.5, 0, true)
local sh = env.fshapes[3]
check(sh and sh.hp and near(sh.hp.rb, 0.5) and near(sh.hp.rt, hp0.rt + 0.2, 0.011), "the base pulled in to a boat-tail, the top widened")
env.doSave()
local r3 = rec_of(store["shipyard.blueprint"], 3)
check(type(r3.fhp) == "table" and #r3.fhp == 7 and type(r3.fprof) == "table" and r3.fsec == nil,
  "the record carries the handles (fhp) and the profile they make (fprof), no rings")
check(env.fairingFit(3).out[4] and rec_of(store["shipyard.blueprint"], 4).faired == nil,
  "…a boat-tail pulled in under the probe lets it out (red, unshielded): what FIT is for")
env.start(make_node("Builder"))
check(env.fshapes[3] and env.fshapes[3].hp and near(env.fshapes[3].hp.rb, 0.5), "reloaded, the handles come back")

-- FIT: shrink the shell round the battery's height, then FIT it
env.cmd("fairing", { uid = 3, op = "handles", hp = { rb = 0.6, rs = 0.6, hs = 0.1, rt = 0.4, ht = 0.4, hn = 0.3, open = false } })
local f1 = env.fairingFit(3)
check(f1.nout > 0, string.format("a squat shell: %d part(s) stick out", f1.nout))
check(env.cmd("fairing", { uid = 3, op = "fit" }), "FIT")
local f2 = env.fairingFit(3)
check(f2.nout == 0 and f2.nin == f1.nin + f1.nout, string.format("FIT holds every part (%d of %d)", f2.nin, f2.nin + f2.nout))
env.undoStep()
check(env.fairingFit(3).nout > 0, "CTRL+Z takes the FIT back")
env.redoStep()

-- pieces, auto-drop, open top
env.cmd("fairing", { uid = 3, op = "split", n = 3 })
env.cmd("fairing", { uid = 3, op = "auto", pct = 70 })
env.doSave()
r3 = rec_of(store["shipyard.blueprint"], 3)
check(r3.fsplit == 3 and r3.fauto == 70, "three pieces and an auto-drop at 70 % ride in the record")
local view = env.stageView()
local fe = nil
for _, s in ipairs(view.stages) do for _, e in ipairs(s.items) do if e.kind == "fairing" then fe = e end end end
check(fe and fe.fauto == 70, "the stage card knows it drops at 70 % of the air")
env.cmd("fairing", { uid = 3, op = "open", on = true })
local f3 = env.fairingFit(3)
check(f3.open and #f3.prof == 3, "an open top: an inter-stage skirt, no nose")
env.doSave()
r3 = rec_of(store["shipyard.blueprint"], 3)
check(r3.fopen == 1 and (r3.fhn or 1) == 0 and type(r3.fprof) == "table", "…saved open (fopen, no nose)")
env.cmd("fairing", { uid = 3, op = "reset" })
local f4 = env.fairingFit(3)
check(f4.kind == "fitted" and env.fshapes[3] and env.fshapes[3].split == 3 and env.fshapes[3].auto == 70,
  "RESET: the shell fits itself again; the pieces and the auto-drop stay")
env.cmd("fairing", { uid = 3, op = "split", n = 2 })
env.cmd("fairing", { uid = 3, op = "auto", pct = 0 })
check(env.fshapes[3] == nil, "…and an entry with nothing left to say goes")
-- ADVANCED: drawing rings from a handle shape starts from its shoulder and top
env.cmd("fairing", { uid = 3, op = "handles", hp = { rb = 0.7, rs = 0.75, hs = 0.3, rt = 0.75, ht = 1.4, hn = 0.8, open = false } })
env.shapeStart(3)
check(env.fshapes[3].hp == nil and #env.fshapes[3].secs == 2 and env.fshapes[3].secs[2].h == 1.4,
  "ADVANCED ring drawing takes over from the handles (their shoulder and top as rings)")
env.shapeStop(true)
check(env.fairingFit(3).kind == "rings", "…and the shell is the drawn one")

if #failures == 0 then
  print(string.format("FAIRING SHAPE SMOKE OK — %d checks passed", passed))
  os.exit(0)
end
print("FAIRING SHAPE SMOKE FAILURES:")
for _, f2 in ipairs(failures) do print("  ✗ " .. f2) end
os.exit(1)
