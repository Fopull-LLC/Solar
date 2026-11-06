-- SMOKE: the modular structure kit (sandbox plan S1, work/sandbox/PLAN.md §1;
-- docs/base-building.md §13), against the real parts_kit, kit_snap,
-- parts_base, structures and field_builder on a stub save.
--
--   * parts_kit: every piece in every material it comes in resolves to a def
--     with a prefab on disk, the generated mesh's bounds agree with its
--     nominal box, masses are the plan's (a steel wall 0.10 t, concrete
--     1.84 t per 0.8 m³ …), regocrete is cheaper than concrete, concrete
--     walls shield by record; the FITTINGS' copied registry figures equal
--     parts_registry's (parts_aero's, parts_nuclear's);
--   * parts_base.partInfo falls through to the kit;
--   * kit_snap.face: a wall aimed at a floor's top by its edge stands on the
--     edge line, its outside out; in the middle it is a partition; on a wall's
--     end the line goes on; on its top it stacks; on its face it squares off;
--     a floor beside a floor lies level with it; on a wall's top it is a roof
--     over the far side; a pitched panel rises away from its wall; a mount on
--     a wall faces out of it; a hab ring goes on a ring's end, a cap turns to
--     face out;
--   * the records rules: a second wall where one stands overlaps, a corner
--     doesn't; a floor in the air is held by nothing, on two pillars it is,
--     one module beside a held floor is; taking a floor down takes the wall
--     on it and the light on the wall;
--   * structures.partPose with pitch: a wall light faces out of its wall;
--   * field_builder: placing face-snapped pieces writes them into one
--     structure with pitch and roll, a group of placements is ONE undo, the
--     mirror twin, a copy pasted elsewhere, Creative skips the support check.
--
--   luajit solar/tests/smoke_kit.lua

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
local defs = function(id) return PB.partInfo(id) end

-- ── parts_kit ───────────────────────────────────────────────────────────────
local shapes = dofile("solar/tests/fixtures/kit_shapes.lua")
local npieces, nprefabs = 0, 0
for name, P in pairs(K.PIECES) do
  npieces = npieces + 1
  check(type(P.box) == "table" and #P.box == 6 and P.box[2] > P.box[1] and P.box[4] > P.box[3] and P.box[6] > P.box[5], name .. ": a nominal box")
  check(#P.mats >= 1, name .. ": at least one material")
  for _, m in ipairs(P.mats) do
    nprefabs = nprefabs + 1
    local id = K.idOf(name, m)
    local d = PB.partInfo(id)
    check(d ~= nil and d.kit and d.mat == m and d.piece == name, id .. ": resolves through parts_base")
    if d then
      local f = io.open("solar/prefabs/" .. d.prefab .. ".prefab.ron")
      check(f ~= nil, id .. ": its prefab " .. d.prefab .. " is on disk")
      if f then f:close() end
      check(d.mass > 0 and d.cost > 0 and d.seat == 0 and d.half.x > 0, id .. ": mass, cost, a seat of 0 (the root is the ground point), a footprint")
      local sh = shapes[d.prefab]
      check(sh ~= nil, id .. ": in the generated bounds")
      if sh then
        local b = P.box
        local tol = 0.13
        check(math.abs(sh.lo[1] - b[1]) <= tol and math.abs(sh.hi[1] - b[2]) <= tol, string.format("%s: mesh x %.2f..%.2f vs box %.2f..%.2f", id, sh.lo[1], sh.hi[1], b[1], b[2]))
        check(math.abs(sh.lo[3] - b[5]) <= tol + 0.08 and math.abs(sh.hi[3] - b[6]) <= tol + 0.08, string.format("%s: mesh z %.2f..%.2f vs box %.2f..%.2f", id, sh.lo[3], sh.hi[3], b[5], b[6]))
        -- (a stair's rails stand 1 m over its treads; a roof panel's thickness hangs under its eave)
        local up = (P.snap == "block" and b[4] > 0.5) and 1.1 or 0.1
        check(sh.lo[2] >= b[3] - 0.11 and sh.hi[2] <= b[4] + up and sh.hi[2] >= b[4] - 0.1,
          string.format("%s: mesh y %.2f..%.2f vs box %.2f..%.2f", id, sh.lo[2], sh.hi[2], b[3], b[4]))
        if P.snap ~= "mount" then check(sh.colliders >= 1, id .. ": static colliders to walk on and bump into") end
        if P.door then
          local has = false
          for _, c in ipairs(sh.children) do if c == "Door" then has = true end end
          check(has, id .. ": a Door child that slides")
        end
        if P.light then
          local has = false
          for _, c in ipairs(sh.children) do if c == "Light" then has = true end end
          check(has, id .. ": a Light child for the pooled lamp")
        end
      end
    end
  end
end
check(npieces >= 40, string.format("the first release's pieces (%d)", npieces))
check(#K.allPrefabs() == nprefabs, "allPrefabs lists every piece × material")
-- the families of plan §1.2
for _, p in ipairs({ "slab2", "floor", "wall", "doorWall", "windowWall", "airlockWall", "openFrame", "roofPitch", "stairs", "ladder",
                     "pillar2", "truss4", "catwalk", "habSeg", "habBulkhead", "habCap", "wallTray", "lightFitting", "wallScreen", "switchPlate" }) do
  check(K.PIECES[p] ~= nil, "the kit has " .. p)
end
-- masses (plan §1.2, real: a wall is 2 x 2.2 m here, 0.88 m³ gross)
local function m(id) return PB.partInfo(id).mass end
check(near(m("wall.steel"), 0.88 * 7.85 * 0.016, 1e-6) and near(m("wall.steel"), 0.11, 0.01), "a steel sandwich wall ≈ 0.11 t")
check(near(m("wall.concrete"), 0.88 * 2.3, 1e-6), "a concrete wall: 0.88 m³ × 2.3 t/m³ = 2.02 t")
check(near(m("wall.regocrete"), 0.88 * 2.0, 1e-6), "regocrete: 2.0 t/m³")
check(near(m("wall.glass"), 0.88 * 2.5 * 0.1, 1e-6), "a glass wall: a 20 mm pane in its frame ≈ 0.22 t")
check(near(m("floor.concrete"), 1.84, 1e-6), "a concrete floor: 1.84 t (plan)")
check(near(m("floor.steel"), 0.8 * 7.85 * 0.019, 1e-6) and near(m("floor.steel"), 0.12, 0.005), "a steel deck panel ≈ 0.12 t (plan)")
check(near(m("slab2.concrete"), 2.76, 0.05), "a 2 x 2 slab ≈ 2.8 t (plan)")
check(near(m("habSeg.steel"), 0.9, 0.01), "a hab segment 0.9 t (plan)")
check(near(m("habWindow.steel"), 1.1, 0.01), "a hab window segment 1.1 t (plan)")
check(near(m("truss4.steel"), 0.24, 0.005), "a 4 m truss 0.24 t (plan)")
check(near(m("pillar2.concrete"), 0.198 * 2.3, 1e-6), "a concrete pillar by its volume")
check(near(m("leadWall.steel"), 0.95, 1e-6), "the lead-lined wall 0.95 t")
check(PB.partInfo("wall.steel").cost == 600 and PB.partInfo("wall.glass").cost == 900, "a steel wall $600, glass $900 (plan)")
check(PB.partInfo("wall.regocrete").cost < PB.partInfo("wall.concrete").cost, "regocrete is the cheapest wall")
check(PB.partInfo("doorWall.steel").cost == 1100 and PB.partInfo("airlockWall.steel").cost == 3800 and PB.partInfo("habSeg.steel").cost == 4200,
  "door wall $1,100, airlock $3,800, hab segment $4,200 (plan)")
check(PB.partInfo("wall.concrete").shield and near(PB.partInfo("wall.concrete").shield.k, 0.35), "a concrete wall shields by record (k 0.35)")
check(PB.partInfo("wall.steel").shield == nil, "a steel wall doesn't count as shielding")
check(PB.partInfo("shieldBlock.concrete").shield.k == 0.05, "a shield block lets 5 % through")
check(PB.partInfo("doorWall.steel").script == "kit_live" and PB.partInfo("wall.steel").script == nil, "a door is live, a wall is static")
check(PB.partInfo("lightFitting.steel").power.kind == "load" and PB.partInfo("lightFitting.steel").power.use > 0, "a light fitting is a load on the base grid")
check(PB.partInfo("wall.glass") ~= nil and PB.partInfo("stairs.glass") == nil, "a material a piece doesn't come in is no part")
check(K.matFor("stairs", "glass") == "steel" and K.matFor("wall", "glass") == "glass", "matFor falls back to the piece's first")
check(K.nextMat("glass") == "steel" and K.nextMat("steel") == "concrete", "M cycles the materials")
check(PB.partInfo("padPlate") ~= nil and PB.partInfo("padPlate").kit == nil, "the BASE parts are untouched")
check(PB.partInfo("shed").script == "kit_live" and PB.partInfo("shed").door and PB.partInfo("hab").door and PB.partInfo("hab").light,
  "the Shed and the Hab stay one-click and get a door and a light")
-- the catalogue: the kit's sections at a material
local cat = K.catalogue("glass")
local secs, inglass = {}, false
for _, s in ipairs(cat) do secs[s.title] = s.ids; for _, id in ipairs(s.ids) do if id == "wall.glass" then inglass = true end end end
check(secs.WALL and secs.FLOOR and secs.HAB and secs.FITTINGS and inglass, "the catalogue's sections, the walls in glass")
for _, id in ipairs(secs.FOUNDATION or {}) do check(PB.partInfo(id) ~= nil, "the glass catalogue's " .. id .. " resolves (its own material)") end
-- FITTINGS: the registry's figures
local REGE = env({}, {})
local REG = load_script("parts_registry.lua", REGE).REG
local AERO = load_script("parts_aero.lua", env({}, {})).PARTS
local NUC = load_script("parts_nuclear.lua", env({}, {})).PARTS
local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not same(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
for _, id in ipairs(K.LIVE_ORDER) do
  local L = K.LIVE[id]
  local src = (K.LIVE_SRC[id] == "parts_aero" and AERO[id]) or (K.LIVE_SRC[id] == "parts_nuclear" and NUC[id]) or REG[id]
  check(src ~= nil, id .. ": a real registry part")
  if src then
    for _, f in ipairs({ "prefab", "label", "h", "rx", "rz", "mass", "cost", "kind", "mods", "seats", "hatch", "iva", "seat", "store", "vol", "power", "ec", "solar", "gen", "af", "strength" }) do
      check(same(L[f], src[f]), string.format("%s.%s matches the registry", id, f))
    end
  end
  local d = PB.partInfo("vab." .. id)
  check(d and d.live and d.vab == id and d.prefab == L.prefab and d.seat > 0, id .. ": a live def standing on its ground point")
end
check(PB.partInfo("vab.cockpit").lay and near(PB.partInfo("vab.cockpit").half.y, 0.5) and near(PB.partInfo("vab.cockpit").half.z, 1.1),
  "the cockpit lies on its belly: its box is 1 m high, 2.2 m long")

-- ── kit_snap.face ───────────────────────────────────────────────────────────
-- a structure on flat ground at the body origin, up +Y, front +Z
local function rec_with(parts)
  return { id = 7, b = "Home", x = 0, y = 0, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1, bp = parts }
end
local function P(uid, id, x, y, z, yaw, pitch) return { uid = uid, id = id, x = x, y = y, z = z, yaw = yaw or 0, pitch = pitch or 0, roll = 0 } end
local R = rec_with({ P(1, "floor.steel", 0, 0, 0) })
local function face(id, hitUid, px, py, pz, nx, ny, nz, tx, tz, yawOff)
  local hp
  for _, p in ipairs(R.bp) do if p.uid == hitUid then hp = p end end
  return KS.face({ def = defs(id), id = id, P = { x = px, y = py, z = pz }, N = { x = nx, y = ny, z = nz },
    toward = { x = tx or 0, y = 0, z = tz or 5 }, hit = { rec = R, part = hp }, defs = defs, yawOff = yawOff })
end
local f = face("wall.steel", 1, 0.2, 0.2, 0.8, 0, 1, 0)
check(f and f.mode == "face" and near(f.lz, 1) and near(f.ly, 0.2) and near(f.lx, 0) and near(f.yaw, 0), "a wall on a floor's +Z edge: on the edge line, on the floor's top")
f = face("wall.steel", 1, 0.85, 0.2, 0.1, 0, 1, 0)
check(f and near(f.lx, 1) and near(f.lz, 0) and near(f.yaw, math.pi / 2), "on the +X edge: turned to face +X")
f = face("wall.steel", 1, 0.1, 0.2, -0.9, 0, 1, 0)
check(f and near(f.lz, -1) and near(math.abs(f.yaw), math.pi), "on the -Z edge: its outside faces -Z")
f = face("wall.steel", 1, 0.1, 0.2, 0.1, 0, 1, 0, 5, 0)
check(f and near(f.lx, 0) and near(f.lz, 0) and near(math.abs(f.yaw), math.pi / 2), "in the floor's middle: a partition at the cursor, facing you")
R.bp[2] = P(2, "wall.steel", 0, 0.2, 1, 0)
f = face("wall.steel", 2, 1.0, 1.2, 1.0, 1, 0, 0)
check(f and near(f.lx, 2) and near(f.ly, 0.2) and near(f.lz, 1) and near(f.yaw, 0), "on a wall's end: the line goes on")
f = face("wall.steel", 2, 0.3, 2.4, 1.0, 0, 1, 0)
check(f and near(f.ly, 2.4) and near(f.lx, 0) and near(f.lz, 1), "on a wall's top: stacked (the next storey's wall)")
f = face("wall.steel", 2, 0.4, 1.0, 1.1, 0, 0, 1)
check(f and near(math.abs(f.yaw), math.pi / 2) and near(f.lz, 2.1) and near(f.ly, 0.2), "on a wall's face: square off it")
f = face("floor.steel", 1, 1.0, 0.1, 0.2, 1, 0, 0)
check(f and near(f.lx, 2) and near(f.ly, 0) and near(f.lz, 0), "a floor beside a floor: level, edge to edge")
f = face("floor.steel", 2, 0.2, 2.4, 1.0, 0, 1, 0, 0, 5)
check(f and near(f.ly, 2.4) and near(f.lz, 0) and near(f.lx, 0), "a floor on a wall's top from outside (+Z): the roof over the room behind it")
f = face("floor.steel", 2, 0.2, 1.5, 0.9, 0, 0, -1)
check(f and near(f.lz, 0), "a floor at a wall's inner face: out over the room you're in")
f = face("roofPitch.steel", 2, 0.2, 2.4, 1.0, 0, 1, 0, 0, 5)
check(f and near(f.ly, 2.4) and near(f.lz, 0) and near(f.yaw, 0), "a pitched panel on a wall: its eave on the wall, rising over the room")
f = face("lightFitting.steel", 2, 0.3, 1.6, 0.9, 0, 0, -1)
check(f and near(f.pitch, math.pi / 2) and near(math.abs(f.yaw), math.pi) and near(f.lz, 0.9) and near(f.ly, 1.6, 0.13), "a light on a wall's inner face faces into the room")
f = face("lightFitting.steel", 1, 0.3, 0.0, 0.2, 0, -1, 0)
check(f and near(f.pitch, math.pi) and near(f.ly, 0), "under a floor: it hangs, face down")
-- hab rings
local H = rec_with({ P(1, "habSeg.steel", 0, 0, 0) })
R = H
f = face("habSeg.steel", 1, 0, 1.6, 1.0, 0, 0, 1)
check(f and near(f.lz, 2) and near(f.yaw, 0), "a hab ring on a ring's +Z end: the next ring, 2 m on")
f = face("habCap.steel", 1, 0, 1.6, -1.0, 0, 0, -1)
check(f and near(f.lz, -1.35) and near(math.abs(f.yaw), math.pi), "a cap on the -Z end turns to face out")
R = rec_with({ P(1, "floor.steel", 0, 0, 0) })

-- ── the records rules ───────────────────────────────────────────────────────
local W = rec_with({ P(1, "floor.steel", 0, 0, 0), P(2, "wall.steel", 0, 0.2, 1, 0) })
check(KS.overlapIn(W, defs, P(-1, "wall.steel", 0, 0.2, 1, 0), defs("wall.steel")) ~= nil, "a second wall where one stands overlaps it")
check(KS.overlapIn(W, defs, P(-1, "wall.steel", 1, 0.2, 0, math.pi / 2), defs("wall.steel")) == nil, "a wall meeting it at the corner doesn't")
check(KS.overlapIn(W, defs, P(-1, "floor.steel", 0, 2.4, 0, 0), defs("floor.steel")) == nil, "a roof on the wall's top doesn't")
check(KS.overlapIn(W, defs, P(-1, "lightFitting.steel", 0, 1.6, 0.9, math.pi, math.pi / 2), defs("lightFitting.steel")) == nil, "a light on its face doesn't")
check(KS.supported(W, defs, P(-1, "wall.steel", 2, 0.2, 1, 0), defs("wall.steel")) == false, "a wall off the floor's edge, standing on air: held by nothing")
check(KS.supported(W, defs, P(-1, "floor.steel", 0, 4.6, 0, 0), defs("floor.steel")) == false, "a floor in the air: held by nothing")
local PL = rec_with({ P(1, "pillar2.steel", -1, 0, -1), P(2, "pillar2.steel", 1, 0, 1) })
check(KS.supported(PL, defs, P(-1, "floor.steel", 0, 2.2, 0, 0), defs("floor.steel")) == true, "a floor on two pillars is held")
check(KS.supported(W, defs, P(-1, "floor.steel", 2, 0.0, 0, 0), defs("floor.steel")) == true, "a floor beside a floor on the ground is held")
local C = rec_with({ P(1, "pillar2.steel", 0, 0, 0), P(2, "floor.steel", 0, 2.2, 0, 0) })
check(KS.supported(C, defs, P(-1, "floor.steel", 2, 2.2, 0, 0), defs("floor.steel")) == true, "one module cantilevered beside a held floor is held")
check(KS.supported(C, defs, P(-1, "floor.steel", 4, 2.2, 0, 0), defs("floor.steel")) == false, "two modules out is not")
local D = rec_with({ P(1, "slab2.concrete", 0, 0, 0), P(2, "floor.steel", 0, 0.2, 0), P(3, "wall.steel", 0, 0.4, 1, 0),
                     P(4, "lightFitting.steel", 0, 1.6, 0.9, math.pi, math.pi / 2), P(5, "wall.steel", 2, 0.0, 1, 0) })
local fall = KS.fallsWith(D, defs, { 2 })
local set = {}
for _, u in ipairs(fall) do set[u] = true end
check(set[3] and set[4] and not set[5] and not set[1], "taking the floor down takes the wall on it and the light on the wall, nothing else")

-- ── structures: a pitched (wall) light's pose ───────────────────────────────
local ST = load_script("structures.lua", env({}, {}))
local rec = rec_with({ P(1, "lightFitting.steel", 0, 1.6, 0.9, math.pi, math.pi / 2) })
local _, _, _, U, Fw = ST.partPose(rec, rec.bp[1], 0)
check(near(U.z, -1, 1e-9) and near(U.y, 0, 1e-9) and near(Fw.y, -1, 1e-9), "a wall light's up is out of its wall (-Z), its front down the wall")
local _, _, _, U2, F2 = ST.partPose(rec, P(2, "wall.steel", 0, 0, 0, 0.3), 0)
check(near(U2.y, 1) and near(F2.x, math.sin(0.3)) and near(F2.z, math.cos(0.3)), "yaw only: the step-4 pose as before")
local u3, f3 = ST.localAxes(0.4, 0.3, 0.2)
local u4, f4 = KS.localAxes(0.4, 0.3, 0.2)
check(near(u3[1], u4[1]) and near(u3[2], u4[2]) and near(f3[3], f4[3]), "structures and kit_snap turn a piece the same way")

-- ── field_builder: placing, the ring, the mirror, a paste, Creative ─────────
do
  local store = { ["base.body"] = "Home" }
  local SS = {}
  local spent, refunded = 0, 0
  local sandbox = false
  SS.company = { spend = function(n) spent = spent + n; return true end, refund = function(n) refunded = refunded + n end,
                 earn = function(n) refunded = refunded + n end, afford = function() return true end,
                 isSandbox = function() return sandbox end }
  SS.parts_kit, SS.kit_snap = K, KS
  local E = env(store, SS, { space = { body = function() return { x = 0, y = 0, z = 0 } end, dominant = function() return "Home" end } })
  SS.parts_base = load_script("parts_base.lua", env(store, SS))
  SS.base_economy = load_script("base_economy.lua", env(store, SS))
  SS.structures = load_script("structures.lua", env(store, SS))
  SS.base_snap = load_script("base_snap.lua", env(store, SS))
  SS.builder_history = load_script("builder_history.lua", env(store, SS))
  SS.crew = { activeId = function() return 1 end, hasRole = function() return true end, credit = function() end }
  local FB = load_script("field_builder.lua", E)
  SS.field_builder = FB
  local STs = SS.structures
  -- a floor on the ground (a new structure), then a wall on it, face-snapped
  local g = { body = "Home", x = 0, y = 0, z = 0, up = { x = 0, y = 1, z = 0 }, fwd = { x = 0, y = 0, z = 1 }, mode = "grid", base = 0 }
  local sid = FB.place(nil, "floor.steel", g, "money")
  check(sid ~= nil and STs.get(sid) and STs.get(sid).n == "Structure", "a kit floor on the ground founds a structure")
  local p = { body = "Home", mode = "face", sid = sid, lx = 0, ly = 0.2, lz = 1, yaw = 0, pitch = 0, roll = 0, x = 0, y = 0.2, z = 1,
              up = { x = 0, y = 1, z = 0 }, fwd = { x = 0, y = 0, z = 1 } }
  check(FB.kitWhy(defs("wall.steel"), p, "wall.steel") == nil, "the wall fits and is held")
  local list = {}
  local s2, why, q, uid = FB.place(sid, "wall.steel", p, "money", { collect = list })
  check(s2 == sid and uid == 2 and #list == 1, "joined to the floor's structure; the step collected, not pushed")
  local lp = { body = "Home", mode = "face", sid = sid, lx = 0, ly = 1.6, lz = 0.9, yaw = math.pi, pitch = math.pi / 2, roll = 0, x = 0, y = 1.6, z = 0.9,
               up = { x = 0, y = 0, z = -1 }, fwd = { x = 0, y = -1, z = 0 } }
  FB.place(sid, "lightFitting.steel", lp, "money", { collect = list })
  local rp = STs.getPart(sid, 3)
  check(rp and near(rp.pitch, math.pi / 2) and near(rp.yaw, math.pi), "the light's pitch and yaw are in its record")
  FB.pushGroup(list, "test group")
  check(FB.kitWhy(defs("wall.steel"), p, "wall.steel") ~= nil, "a second wall there: refused (the Wall is there)")
  local amt = FB.undo()
  check(amt ~= nil and STs.getPart(sid, 2) == nil and STs.getPart(sid, 3) == nil and STs.getPart(sid, 1) ~= nil, "one Ctrl+Z takes the group back: wall and light")
  check(FB.redo() ~= nil and STs.getPart(sid, 2) ~= nil and STs.getPart(sid, 3) ~= nil, "and Ctrl+Shift+Z puts both back")
  -- the mirror: about the structure's X plane at 0
  FB.sym = { axis = "x", sid = sid, at = 0 }
  local sp = { body = "Home", mode = "face", sid = sid, lx = 1, ly = 0.2, lz = 0, yaw = math.pi / 2, pitch = 0, roll = 0 }
  local twin = FB.mirror_twin("wall.steel", defs("wall.steel"), sp, sid)
  check(twin and near(twin.lx, -1) and near(twin.yaw, -math.pi / 2), "SYM: the wall on +X mirrors to -X, facing out")
  FB.sym = nil
  -- (S3 follow-up) a TRUE reflection: every point of the twin is the mirror
  -- image of a point of the piece, for a piece symmetric left-right ("x"),
  -- front-back ("z": the gable, an airlock wall, a pod), or neither (the Door
  -- Wall: its mirrored variant, built reflected in its own X), at any yaw,
  -- pitch and roll
  do
    local function mat(yaw, pitch, roll)
      local u, f = STs.localAxes(yaw, pitch, roll)
      local x = { u[2] * f[3] - u[3] * f[2], u[3] * f[1] - u[1] * f[3], u[1] * f[2] - u[2] * f[1] }
      return { x, u, f }
    end
    local function apply(M, o, v) local r = {}; for k = 1, 3 do r[k] = o[k] + M[1][k] * v[1] + M[2][k] * v[2] + M[3][k] * v[3] end; return r end
    local worst, cases = 0, 0
    for _, case in ipairs({ { "wall.steel", { -1, 1, 1 } }, { "gable.steel", { 1, 1, -1 } }, { "airlockWall.steel", { 1, 1, -1 } },
                            { "doorWall.steel", { -1, 1, 1 }, "doorWallM.steel" }, { "vab.pod", { 1, 1, -1 } } }) do
      local d = defs(case[1])
      for _, axis in ipairs({ "x", "z" }) do
        for _, pose in ipairs({ { 0.3, 0, 0 }, { math.pi / 2, 0, 0 }, { 0.7, math.pi / 2, 0 }, { -1.1, 0.4, math.pi / 2 }, { 2.0, -math.pi / 2, 0.3 } }) do
          local p0 = { lx = 1.5, ly = 0.7, lz = -2.0, yaw = pose[1], pitch = pose[2], roll = pose[3] }
          local m, vid = FB.mirrorPose(p0, axis, 0.25, d)
          cases = cases + 1
          if case[3] and vid ~= case[3] then worst = math.huge end
          if not case[3] and vid ~= nil then worst = math.huge end
          local M0, M1 = mat(p0.yaw, p0.pitch, p0.roll), mat(m.yaw, m.pitch, m.roll)
          local L = case[2]
          for _, f in ipairs({ { 0.3, 0.9, 0.07 }, { -0.8, 0.1, -0.05 }, { 0.6, 2.0, 0.1 } }) do
            local w = apply(M0, { p0.lx, p0.ly, p0.lz }, f)
            if axis == "x" then w[1] = 2 * 0.25 - w[1] else w[3] = 2 * 0.25 - w[3] end
            local t = apply(M1, { m.lx, m.ly, m.lz }, { L[1] * f[1], L[2] * f[2], L[3] * f[3] })
            worst = math.max(worst, math.abs(t[1] - w[1]) + math.abs(t[2] - w[2]) + math.abs(t[3] - w[3]))
          end
        end
      end
    end
    check(worst < 1e-9, string.format("SYM reflects (%d cases: walls, a gable, an airlock wall, the Door Wall's variant, a pod; turned in yaw, pitch and roll): worst %.2g m", cases, worst))
    local dv = defs("doorWallM.steel")
    check(dv and dv.hidden and dv.door and dv.door.slide[1] < 0 and dv.mirror == "doorWall", "the Door Wall's mirrored variant: hidden from the column, its door the other way")
    local listed = false
    for _, s in ipairs(K.catalogue("steel")) do for _, id in ipairs(s.ids) do if id:find("doorWallM", 1, true) then listed = true end end end
    check(not listed, "the variant isn't in the parts column")
    FB.sym = { axis = "x", sid = sid, at = 0 }
    local dp = { body = "Home", mode = "face", sid = sid, lx = 1, ly = 0.2, lz = 0, yaw = math.pi / 2, pitch = 0, roll = 0 }
    local dt = FB.mirror_twin("doorWall.steel", defs("doorWall.steel"), dp, sid)
    check(dt and dt.id == "doorWallM.steel" and near(dt.lx, -1), "SYM with a Door Wall places its mirrored variant opposite")
    FB.sym = nil
  end
  -- copy and paste
  local n = FB.copyParts(sid, { 1, 2 })
  check(n == 2 and FB.clip and FB.clip.parts[1].id == "floor.steel" and near(FB.clip.parts[2].dz, 1), "copy: the floor and its wall, relative to the floor")
  local cp = FB.clipPose({ lx = 4, ly = 0, lz = 0, yaw = math.pi / 2 }, FB.clip.parts[2])
  check(near(cp.lx, 5) and near(cp.lz, 0, 1e-9) and near(cp.yaw, math.pi / 2) and near(cp.ly, 0.2), "the copy turned a quarter: the wall goes with it")
  -- Creative skips the support check
  local air = { body = "Home", mode = "face", sid = sid, lx = 0, ly = 6, lz = 0, yaw = 0, pitch = 0, roll = 0 }
  check(FB.kitWhy(defs("floor.steel"), air, "floor.steel") ~= nil, "Career: a floating floor is refused")
  sandbox = true
  check(FB.kitWhy(defs("floor.steel"), air, "floor.steel") == nil, "Creative: it goes")
  sandbox = false
  -- the footprint's ground over stand-in ground: terrain.raycast answers
  -- nil, "unknown", distance there, and that distance is the ground
  E.terrain = { raycast = function() return nil, "unknown", 3.5 end }
  E.vec3 = function(x, y, z) return { x = x, y = y, z = z } end
  local hs = FB.sampleGround(defs("padPlate"), { body = "Home", x = 0, y = 600, z = 0, up = { x = 0, y = 1, z = 0 }, fwd = { x = 0, y = 0, z = 1 } })
  local nh = 0
  for _, h in ipairs(hs or {}) do if h and math.abs(h - (2.0 + 2.5 - 3.5)) < 1e-6 then nh = nh + 1 end end
  check(nh == 9 and FB.lastRayWhy == "unknown at 3.50 m", "stand-in ground answers \"unknown\" with its distance: the footprint reads it as ground (a stand by a fresh slab)")
  E.terrain = nil
  -- deconstruct the floor: the wall and the light with it
  local refund, uids = FB.deconstruct(sid, 1)
  check(refund and uids and #uids == 3, "Deconstruct the floor: the wall and the light come down with it")
end

if #failures > 0 then
  print("FAIL smoke_kit: " .. #failures .. " of " .. (#failures + passed))
  for _, m in ipairs(failures) do print("  - " .. m) end
  os.exit(1)
end
print(string.format("smoke_kit: %d checks passed", passed))
