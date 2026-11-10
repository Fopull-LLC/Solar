-- SMOKE: hab segments that join their neighbours (Ty 11-10: "it just
-- recognizes what's near it and forms the connection so you can place a
-- hallway off the side of a straight one and it will make the 3 way split";
-- docs/base-building.md §29), against the real parts_kit, parts_base,
-- kit_snap, rooms and structures on a stub save.
--
--   * kit_snap.habShapes, the neighbour-to-shape rules: a straight run stays
--     straight; a segment's end on another's side makes the host a T (R or
--     L); a second branch opposite makes the cross (LR); a branch off a run's
--     last segment is the corner (its free end plated: Rf); a cap on that end
--     opens it again (R); taking the branch away restores the straight
--     segment; a turned run, a run off the 0.5 m grid's middle, a can on
--     another storey or off the quarter grid joins nothing it shouldn't;
--   * kit_snap.face: a segment aimed at a segment's side is offered the
--     branch (its end on the side's middle, square to it); a cap is not;
--   * parts_kit: every junction variant resolves (hidden, with its prefab on
--     disk and in the generated bounds), joinId names it, a window junction
--     with ports both sides is the plain one;
--   * structures: placing, removing and undoing re-shape the host (only the
--     segments near the change), an OLD SAVE (no `hj`) rebuilds its
--     junctions on load, the derived code is written as a cache;
--   * rooms: a T, a cross and an L capped hold ONE sealed room (moved half a
--     module and turned a quarter too); an open branch end leaks; the
--     signature moves with the code;
--   * cost: re-shaping a 48-can base, and a placement's re-shape.
--
--   luajit solar/tests/smoke_hab_join.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, e) return math.abs(a - b) <= (e or 1e-6) end

local function env(store, scripts, extra)
  local E = setmetatable({
    time = 5.0,
    save = {
      get = function(k) return store[k] end,
      set = function(k, v) store[k] = v end,
      delete = function(k) local had = store[k] ~= nil; store[k] = nil; return had end,
    },
    findScript = function(k) return scripts[k] end,
    findScripts = function(k) return {} end,
    find = function() return nil end,
    log = function() end,
  }, { __index = _G })
  for k, v in pairs(extra or {}) do E[k] = v end
  return E
end
local function load_script(path, E)
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, E)
  f()
  E.params = {}
  for k, v in pairs(E.defaults or {}) do E.params[k] = v end
  return E
end

local S = {}
local K = load_script("parts_kit.lua", env({}, S))
S.parts_kit = K
local PB = load_script("parts_base.lua", env({}, S))
S.parts_base = PB
local KS = load_script("kit_snap.lua", env({}, S))
S.kit_snap = KS
local RL = load_script("rooms.lua", env({}, S))
S.rooms = RL
local defs = function(id) return PB.partInfo(id) end

local PI2 = math.pi / 2
local function P(uid, id, x, y, z, yaw) return { uid = uid, id = id, x = x, y = y or 0, z = z, yaw = yaw or 0, pitch = 0, roll = 0 } end
local function rec_of(bp) return { id = 1, b = "Home", x = 0, y = 600, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1, bp = bp } end
local function code_of(rec, uid)
  for _, p in ipairs(rec.bp) do if p.uid == uid then return p.hj end end
end
local function shapes(rec) KS.habShapes(rec, defs, nil); return rec end
-- a run of n segments along Z from z0 (2 m apart), uids 1..n
local function run(n, z0, x, id)
  local bp = {}
  for i = 1, n do bp[#bp + 1] = P(i, id or "habSeg.steel", x or 0, 0, (z0 or 0) + 2 * (i - 1)) end
  return bp
end
local function add(bp, p) bp[#bp + 1] = p; return bp end

-- ── the neighbour-to-shape rules ────────────────────────────────────────────
do
  local R4 = shapes(rec_of(run(4)))
  local any = false
  for _, p in ipairs(R4.bp) do if p.hj then any = true end end
  check(not any, "a straight run of four: every segment straight (no code)")
  -- a branch off seg 2's +X side: its -Z end on the side's middle (x = 1.35)
  local T = shapes(rec_of(add(run(4), P(10, "habSeg.steel", 2.35, 0, 2, PI2))))
  check(code_of(T, 2) == "R", "a segment's end on the run's side: the host is a T, a port on its +X (" .. tostring(code_of(T, 2)) .. ")")
  check(code_of(T, 10) == nil and code_of(T, 1) == nil and code_of(T, 3) == nil, "the branch and the run's others stay straight")
  -- the branch turned the other way round (yaw -90°: its +Z end on the side)
  local T2 = shapes(rec_of(add(run(4), P(10, "habSeg.steel", 2.35, 0, 2, -PI2))))
  check(code_of(T2, 2) == "R", "either end of the branch makes the port")
  -- a second branch opposite: the cross
  local X = shapes(rec_of(add(add(run(4), P(10, "habSeg.steel", 2.35, 0, 2, PI2)), P(11, "habWindow.steel", -2.35, 0, 2, -PI2))))
  check(code_of(X, 2) == "LR", "a branch both sides: the cross (" .. tostring(code_of(X, 2)) .. ")")
  -- the corner: a branch off the run's last segment; its free end plated
  local Lc = shapes(rec_of(add(run(4), P(10, "habSeg.steel", 2.35, 0, 6, PI2))))
  check(code_of(Lc, 4) == "Rf", "a branch off the last segment: the corner, its free +Z end plated (" .. tostring(code_of(Lc, 4)) .. ")")
  local Lb = shapes(rec_of(add(run(4), P(10, "habSeg.steel", -2.35, 0, 0, -PI2))))
  check(code_of(Lb, 1) == "Lb", "off the first segment's -X: Lb (" .. tostring(code_of(Lb, 1)) .. ")")
  -- a cap on that end: the end is the cap's, not plated
  local Lcap = shapes(rec_of(add(add(run(4), P(10, "habSeg.steel", 2.35, 0, 6, PI2)), P(12, "habCap.steel", 0, 0, 7.35))))
  check(code_of(Lcap, 4) == "R", "a cap on the corner's free end: it opens (R)")
  local Lbh = shapes(rec_of(add(add(run(4), P(10, "habSeg.steel", 2.35, 0, 6, PI2)), P(12, "habBulkhead.steel", 0, 0, 7.2))))
  check(code_of(Lbh, 4) == "R", "a door bulkhead there: the same")
  -- one segment alone with a branch: both its ends plated (a dead-end T)
  local one = shapes(rec_of({ P(1, "habSeg.steel", 0, 0, 0), P(2, "habSeg.steel", 2.35, 0, 0, PI2) }))
  check(code_of(one, 1) == "Rbf", "a lone segment with a branch: both ends plated (" .. tostring(code_of(one, 1)) .. ")")
  -- the branch's end against a host segment is its own end's neighbour, so a
  -- branch that is itself a junction keeps that end open
  local chain = shapes(rec_of({ P(1, "habSeg.steel", 0, 0, 0), P(2, "habSeg.steel", 2.35, 0, 0, PI2), P(3, "habSeg.steel", 2.35, 0, 2.35, 0) }))
  check(code_of(chain, 2) == "Lb" or code_of(chain, 2) == "Rb" or code_of(chain, 2) == "Lf" or code_of(chain, 2) == "Rf",
    "a branch that is a host too: a port, its end on the first host open, its free end plated (" .. tostring(code_of(chain, 2)) .. ")")
  -- removal: the branch gone, the host is straight again
  local Tr = rec_of(add(run(4), P(10, "habSeg.steel", 2.35, 0, 2, PI2)))
  shapes(Tr)
  table.remove(Tr.bp, #Tr.bp)
  local ch = KS.habShapes(Tr, defs, { { x = 2.35, z = 2 } })
  check(code_of(Tr, 2) == nil and #ch == 1 and ch[1].uid == 2, "the branch taken away: the T is straight again, and only it changed")
  -- what doesn't join: another storey, off the quarter grid, parallel and apart, a cap at the side
  check(code_of(shapes(rec_of(add(run(4), P(10, "habSeg.steel", 2.35, 2.9, 2, PI2)))), 2) == nil, "a branch a storey up: nothing")
  check(code_of(shapes(rec_of(add(run(4), P(10, "habSeg.steel", 2.35, 0, 2, PI2 + 0.3)))), 2) == nil, "a branch off square: nothing")
  check(code_of(shapes(rec_of(add(run(4), P(10, "habSeg.steel", 2.7, 0, 2, 0)))), 2) == nil, "a parallel can beside it: nothing")
  check(code_of(shapes(rec_of(add(run(4), P(10, "habSeg.steel", 2.35, 0, 2.5, PI2)))), 2) == nil, "a branch half a module along: no port")
  check(code_of(shapes(rec_of(add(run(4), P(10, "habCap.steel", 1.7, 0, 2, PI2)))), 2) == nil, "a cap against the side: nothing (only a segment makes a port)")
  -- the whole thing turned a quarter and moved half a module
  local bp = add(run(4), P(10, "habSeg.steel", 2.35, 0, 2, PI2))
  for _, p in ipairs(bp) do p.x, p.z = p.z + 0.5, -p.x - 0.5; p.yaw = p.yaw + PI2 end
  check(code_of(shapes(rec_of(bp)), 2) == "R", "turned a quarter and moved half a module: still the T")
  -- the preview: the codes with a part not placed yet
  local pv = rec_of(run(4))
  local got = nil
  for _, e in ipairs(KS.habCodes(pv, defs, { { x = 2.35, z = 2 } }, P(-1, "habSeg.steel", 2.35, 0, 2, PI2))) do
    if e.p.uid == 2 then got = e.code end
  end
  check(got == "R" and code_of(pv, 2) == nil, "habCodes previews the T with the ghost, writing nothing")
end

-- ── snapping: the side is offered ───────────────────────────────────────────
do
  local R = rec_of(run(4))
  local fr = KS.frameOf(R)
  local function face(id, uid, lx, ly, lz, nx, ny, nz)
    local part
    for _, p in ipairs(R.bp) do if p.uid == uid then part = p end end
    local x, y, z = fr.O.x + fr.R.x * lx + fr.U.x * ly + fr.F.x * lz, fr.O.y + fr.R.y * lx + fr.U.y * ly + fr.F.y * lz,
                    fr.O.z + fr.R.z * lx + fr.U.z * ly + fr.F.z * lz
    return KS.face({ def = defs(id), id = id, defs = defs, P = { x = x, y = y, z = z },
      N = { x = fr.R.x * nx + fr.U.x * ny + fr.F.x * nz, y = fr.R.y * nx + fr.U.y * ny + fr.F.y * nz, z = fr.R.z * nx + fr.U.z * ny + fr.F.z * nz },
      toward = { x = 0, y = 0, z = 1 }, hit = { rec = R, part = part }, yawOff = 0 })
  end
  local f = face("habSeg.steel", 2, 1.25, 1.6, 2.4, 1, 0, 0)
  check(f and near(f.lx, 2.35) and near(f.lz, 2) and near(f.ly, 0) and near(math.abs(f.yaw), PI2),
    string.format("a segment aimed at a segment's +X side: the branch, its end on the side's middle (%.2f, %.2f, yaw %.2f)", f and f.lx or -1, f and f.lz or -1, f and f.yaw or -1))
  local g = face("habWindow.steel", 3, -1.25, 1.4, 3.6, -1, 0, 0)
  check(g and near(g.lx, -2.35) and near(g.lz, 4), "a window segment on the -X side of another: the same, off the left")
  check(face("habCap.steel", 2, 1.25, 1.6, 2.0, 1, 0, 0) == nil, "a cap aimed at the side: not offered")
  local e = face("habSeg.steel", 4, 0, 1.6, 7.0, 0, 0, 1)
  check(e and near(e.lz, 8) and near(e.lx, 0), "the ring's end still offers the next ring")
  -- the offered branch doesn't overlap the run's neighbours
  check(f and KS.overlapIn(R, defs, P(-1, "habSeg.steel", f.lx, 0, f.lz, f.yaw), defs("habSeg.steel")) == nil, "the branch fits beside the run")
  local R2 = rec_of(add(run(4), P(10, "habSeg.steel", 2.35, 0, 2, PI2)))
  check(KS.overlapIn(R2, defs, P(-1, "habSeg.steel", 2.35, 0, 4, PI2), defs("habSeg.steel")) ~= nil, "a second branch on the next segment overlaps the first (every other one)")
  check(KS.overlapIn(R2, defs, P(-1, "habSeg.steel", 2.35, 0, 6, PI2), defs("habSeg.steel")) == nil, "two along: it fits")
end

-- ── the variants ────────────────────────────────────────────────────────────
do
  local shapes_fx = dofile("solar/tests/fixtures/kit_shapes.lua")
  local n = 0
  for _, base in ipairs({ "habSeg", "habWindow" }) do
    for _, code in ipairs(K.JOIN_CODES) do
      local id = K.joinId(base .. ".steel", code)
      local d = defs(id)
      n = n + 1
      check(d and d.hidden and d.jn and d.joinOf and d.seals == "ring", id .. ": a hidden junction variant that seals as a ring")
      if d then
        local f = io.open("solar/prefabs/" .. d.prefab .. ".prefab.ron")
        check(f ~= nil, id .. ": its prefab on disk")
        if f then f:close() end
        check(shapes_fx[d.prefab] ~= nil, id .. ": in the generated bounds")
        local sh = shapes_fx[d.prefab]
        if sh then check(sh.colliders >= 20, id .. ": walkable (its colliders)") end
      end
    end
  end
  check(n == 24, "twelve codes for each joinable segment")
  check(K.joinId("habWindow.steel", "LR") == "habSegJLR.steel" and K.joinId("habWindow.steel", "Rb") == "habWindowJRb.steel",
    "a window junction keeps its window where there's no port; with ports both sides it is the plain one")
  check(K.joinId("habCap.steel", "R") == "habCap.steel" and K.joinId("habSeg.steel", nil) == "habSeg.steel", "only a joinable segment has variants")
  local cat = K.catalogue("steel")
  local seen = 0
  for _, s in ipairs(cat) do for _, id in ipairs(s.ids) do if id:find("J", 1, true) and id:find("^hab") then seen = seen + 1 end end end
  check(seen == 0, "no junction in the parts column: the catalogue keeps the one Hab Segment")
  check(defs("habSeg.steel").join and defs("habWindow.steel").join and not defs("habCap.steel").join, "the segments join, the cap doesn't")
end

-- ── structures: placing, removing, an old save ──────────────────────────────
do
  -- an OLD SAVE: a T built before junctions existed (no hj anywhere)
  local store = {}
  local bp = add(run(4), P(10, "habSeg.steel", 2.35, 0, 2, PI2))
  store["struct.list"] = { 1 }
  store["struct.seq"] = 1
  store["struct.1"] = { id = 1, b = "Home", x = 0, y = 600, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1, bp = bp }
  local ST = load_script("structures.lua", env(store, S))
  local r = ST.get(1)
  check(r and code_of(r, 2) == "R", "an old save loads and rebuilds its junction (" .. tostring(r and code_of(r, 2)) .. ")")
  -- place a fourth arm opposite: the cross
  local uid = ST.addPart(1, { id = "habSeg.steel", x = -2.35, y = 0, z = 2, yaw = -PI2 })
  check(code_of(ST.get(1), 2) == "LR", "placing the opposite arm makes the cross")
  check(type(store["struct.1"]) == "table" and code_of(store["struct.1"], 2) == "LR", "the derived code is in the saved record (a cache)")
  -- a corner at the run's end
  local u2 = ST.addPart(1, { id = "habSeg.steel", x = 2.35, y = 0, z = 6, yaw = PI2 })
  check(code_of(ST.get(1), 4) == "Rf", "a branch off the last segment: the corner")
  -- undo (the step takes the part back out): straight again, the cross untouched
  ST.removeParts(1, { u2 })
  check(code_of(ST.get(1), 4) == nil and code_of(ST.get(1), 2) == "LR", "removing it: the end segment is straight again, the cross untouched")
  ST.removeParts(1, { uid, 10 })
  check(code_of(ST.get(1), 2) == nil, "both arms gone: a straight run again")
  -- a whole record added at once (a paste, a ruin, a scenario)
  local id2 = ST.add({ b = "Home", x = 50, y = 600, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1, bp = add(run(2), P(5, "habSeg.steel", -2.35, 0, 0, -PI2)) })
  check(code_of(ST.get(id2), 1) == "Lb", "a record added whole is shaped at once (Lb)")
  -- put: a record moved by the hub's commit
  local r2 = ST.get(id2)
  r2.bp[3].x, r2.bp[3].z = -2.35, 2
  ST.put(r2)
  check(code_of(ST.get(id2), 1) == nil and code_of(ST.get(id2), 2) == "Lf", "a part moved and the record put: re-shaped (Lf)")
end

-- ── rooms and air ───────────────────────────────────────────────────────────
do
  local function solved(bp, dx, dz, turn)
    for _, p in ipairs(bp) do
      if turn then p.x, p.z = p.z, -p.x; p.yaw = p.yaw + PI2 end
      p.x, p.z = p.x + (dx or 0), p.z + (dz or 0)
    end
    local rec = shapes(rec_of(bp))
    return RL.solve(rec, defs), rec
  end
  local function capped_run(n)
    local bp = run(n)
    add(bp, P(20, "habCap.steel", 0, 0, -1.35, math.pi))
    add(bp, P(21, "habCap.steel", 0, 0, 2 * (n - 1) + 1.35))
    return bp
  end
  local cases = {
    { "a T capped", function() return add(add(capped_run(4), P(10, "habSeg.steel", 2.35, 0, 2, PI2)), P(30, "habCap.steel", 3.7, 0, 2, PI2)) end, true },
    { "a cross capped", function()
        local bp = add(add(capped_run(4), P(10, "habSeg.steel", 2.35, 0, 2, PI2)), P(30, "habCap.steel", 3.7, 0, 2, PI2))
        return add(add(bp, P(11, "habWindow.steel", -2.35, 0, 2, -PI2)), P(31, "habCap.steel", -3.7, 0, 2, -PI2)) end, true },
    { "an L capped", function()
        local bp = run(4)
        add(bp, P(20, "habCap.steel", 0, 0, -1.35, math.pi))
        return add(add(bp, P(10, "habSeg.steel", 2.35, 0, 6, PI2)), P(30, "habCap.steel", 3.7, 0, 6, PI2)) end, true },
    { "a long branch capped", function()
        local bp = add(add(capped_run(4), P(10, "habSeg.steel", 2.35, 0, 2, PI2)), P(11, "habSeg.steel", 4.35, 0, 2, PI2))
        return add(bp, P(30, "habCap.steel", 5.7, 0, 2, PI2)) end, true },
    { "a T with its branch's end open", function() return add(capped_run(4), P(10, "habSeg.steel", 2.35, 0, 2, PI2)) end, false },
  }
  for _, c in ipairs(cases) do
    for _, mv in ipairs({ { 0, 0, false }, { 0.5, 0, false }, { 0, 0.5, false }, { 0.5, 0.5, true }, { 0, 0, true } }) do
      local R = solved(c[2](), mv[1], mv[2], mv[3])
      local tag = string.format("%s (moved %.1f, %.1f%s)", c[1], mv[1], mv[2], mv[3] and ", turned" or "")
      if c[3] then
        check(#R.rooms == 1 and R.rooms[1].sealed, string.format("%s: ONE sealed room (%d rooms, %s)", tag, #R.rooms,
          R.rooms[1] and (R.rooms[1].sealed and "sealed" or (R.rooms[1].leaky and "leaky" or "?")) or "none"))
      else
        check(#R.rooms == 1 and R.rooms[1].leaky and #R.rooms[1].leaks >= 1, string.format("%s: one leaky room (%d)", tag, #R.rooms))
      end
    end
  end
  -- the T's room spans the branch: a point in the branch and one in the run are in it
  local R, rec = solved(cases[1][2]())
  local a, b = RL.roomAt(R, 0, 1.6, 2), RL.roomAt(R, 2.9, 1.6, 2)
  check(a and b and a.id == b.id, "the run and the branch are one room")
  local m3 = R.rooms[1] and R.rooms[1].m3 or 0
  local Rs = solved(capped_run(4))
  check(Rs.rooms[1] and m3 > Rs.rooms[1].m3 + 4, string.format("the branch adds its volume (%.1f vs %.1f m³)", m3, Rs.rooms[1] and Rs.rooms[1].m3 or 0))
  -- the signature carries the derived code
  local s1 = RL.signatureOf(rec, defs)
  rec.bp[2].hj = nil
  check(RL.signatureOf(rec, defs) ~= s1, "the seal signature moves with a junction's code")
end

-- ── cost ────────────────────────────────────────────────────────────────────
do
  -- a 48-can base: four runs of 8 with branches between them
  local bp, uid = {}, 0
  for r = 0, 3 do
    for i = 0, 7 do uid = uid + 1; bp[#bp + 1] = P(uid, "habSeg.steel", r * 9.4, 0, i * 2) end
    if r < 3 then for i = 0, 7, 2 do uid = uid + 1; bp[#bp + 1] = P(uid, "habSeg.steel", r * 9.4 + 2.35, 0, i * 2, PI2)
      uid = uid + 1; bp[#bp + 1] = P(uid, "habSeg.steel", r * 9.4 + 4.35, 0, i * 2, PI2)
      uid = uid + 1; bp[#bp + 1] = P(uid, "habSeg.steel", r * 9.4 + 7.05, 0, i * 2, -PI2) end end
  end
  -- (filler: walls and floors a real base has too)
  for i = 1, 200 do uid = uid + 1; bp[#bp + 1] = P(uid, "floor.steel", 100 + (i % 20) * 2, 0, math.floor(i / 20) * 2) end
  local rec = rec_of(bp)
  local t0 = os.clock()
  for _ = 1, 20 do for _, p in ipairs(rec.bp) do p.hj = nil end; KS.habShapes(rec, defs, nil) end
  local all = (os.clock() - t0) / 20 * 1000
  local t1 = os.clock()
  for _ = 1, 200 do KS.habShapes(rec, defs, { { x = 2.35, z = 4 } }) end
  local one = (os.clock() - t1) / 200 * 1000
  local nj = 0
  for _, p in ipairs(rec.bp) do if p.hj then nj = nj + 1 end end
  check(nj == 16, string.format("the base has its junctions: 16 hosts, the middle runs crosses (%d)", nj))
  check(one < 1.0, string.format("a placement's re-shape: %.3f ms (under 1 ms)", one))
  check(all < 5.0, string.format("the whole base re-shaped (a load): %.3f ms", all))
  print(string.format("HABJOIN cost: placement %.3f ms, whole %d-part base %.3f ms, %d junctions", one, #rec.bp, all, nj))
end

if #failures > 0 then
  print(string.format("smoke_hab_join: %d passed, %d FAILED", passed, #failures))
  for _, f in ipairs(failures) do print("  FAIL " .. f) end
  os.exit(1)
end
print(string.format("smoke_hab_join: all %d checks passed", passed))
