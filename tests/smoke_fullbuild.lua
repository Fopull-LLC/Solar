-- SMOKE: playtest 11-09's builder fixes and the full freecam builder for bases
-- (docs/base-building.md §19), on stub engines.
--
--   * support through connections (kit_snap's structural graph): a floor at a
--     wall's face, a floor two modules out from what holds it (not three), an
--     8 m roof over four walls, a wall standing on air still refused, a piece
--     set on the terrain held whatever its height, and what falls when a wall
--     goes (the floor hung on it, unless something else holds it);
--   * snaps exact: a joined piece turns only in quarter turns whatever the
--     wheel dialled (15°, 5°), a block keeps clean 15° steps; ground within
--     12 m of a structure JOINS it, in its own frame (its up exactly, its
--     grid, quarter turns), farther out a new structure as before;
--   * the input guard: a focused "Field…" node blocks every raw key but
--     Escape and Enter, every keyboard action (Jump, Move, Interact …), and
--     lets the mouse's and Pause through; a focused button blocks nothing;
--     installed once;
--   * the tower: 300 m apart, the spaceport's station included, and the red
--     ghost says how much further;
--   * base_hub: the builder's catalogue gains the BASE section and every kit
--     category, each piece in every material, a clashing title as "BASE …",
--     no VAB fitting twice; a piece's box centre and its prefab root (npiv);
--     a structure into the builder and back is exact (turned, pitched,
--     seated); the diff (added, moved, taken off, the hub kept); the commit
--     (one truck, the deconstruct refund, a VAB part's launch record kept and
--     its figures learned); struct_live builds the structure vessel from the
--     kept records; structures.suspend holds a structure out of the world.
--
--   luajit solar/tests/smoke_fullbuild.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, e) return math.abs((a or 0) - (b or 0)) <= (e or 1e-6) end

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

local store = {}
local S = {}
S.parts_kit = load_script("parts_kit.lua", env(store, S))
S.parts_base = load_script("parts_base.lua", env(store, S))
S.kit_snap = load_script("kit_snap.lua", env(store, S))
S.base_snap = load_script("base_snap.lua", env(store, S))
local KS, SN, PB, K = S.kit_snap, S.base_snap, S.parts_base, S.parts_kit
local defs = function(id) return PB.partInfo(id) end
local function rec_with(parts)
  return { id = 7, b = "Home", x = 0, y = 0, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1, bp = parts }
end
local function P(uid, id, x, y, z, yaw, pitch) return { uid = uid, id = id, x = x, y = y, z = z, yaw = yaw or 0, pitch = pitch or 0, roll = 0 } end
local Q = math.pi / 2

-- ── 1. support through connections ─────────────────────────────────────────
-- a 2 x 2 room: a floor, four walls on its edges
local room = { P(1, "floor.steel", 0, 0, 0), P(2, "wall.steel", 0, 0.2, 1, 0), P(3, "wall.steel", 0, 0.2, -1, math.pi),
               P(4, "wall.steel", 1, 0.2, 0, Q), P(5, "wall.steel", -1, 0.2, 0, -Q) }
local R1 = rec_with(room)
local ok, h = KS.supported(R1, defs, P(-1, "floor.steel", 0, 1.2, 2.0), defs("floor.steel"))
check(ok and h == 1, "a floor at a wall's outside face, half way up (a mezzanine), is held by the wall it touches: hang " .. tostring(h))
ok, h = KS.supported(R1, defs, P(-1, "floor.steel", 0, 2.4, 0), defs("floor.steel"))
check(ok and h == 0, "a roof on the walls' tops rests on them: hang 0")
-- (floors at z 0 and 2 both rest on the wall on the line z = 1 between them)
local R2 = rec_with({ P(1, "floor.steel", 0, 0, 0), P(2, "wall.steel", 0, 0.2, 1, 0), P(3, "floor.steel", 0, 2.4, 0),
                      P(4, "floor.steel", 0, 2.4, 2), P(5, "floor.steel", 0, 2.4, 4), P(10, "pillar2.steel", -3, 0, 6) })
ok, h = KS.supported(R2, defs, P(-1, "floor.steel", 0, 2.4, 6), defs("floor.steel"))
check(ok and h == 2, "a floor two modules out from the one on the wall: held (hang " .. tostring(h) .. ")")
R2.bp[#R2.bp + 1] = P(6, "floor.steel", 0, 2.4, 6)
check(not KS.supported(R2, defs, P(-1, "floor.steel", 0, 2.4, 8), defs("floor.steel")), "a third module out is not")
check(not KS.supported(rec_with({ P(1, "floor.steel", 0, 0, 0), P(2, "wall.steel", 0, 0.2, 1, 0) }), defs, P(-1, "wall.steel", 2, 0.2, 1, 0), defs("wall.steel")),
  "a wall bolted at one end over air is still held by nothing")
-- an 8 m room roofed with sixteen floors: every one held (the middle four
-- beside the twelve that rest on the walls), with no pillar
local big = {}
local u = 0
for i = 0, 3 do
  local x = -3 + 2 * i
  u = u + 1; big[#big + 1] = P(u, "wall.steel", x, 0, 4, 0)
  u = u + 1; big[#big + 1] = P(u, "wall.steel", x, 0, -4, math.pi)
  u = u + 1; big[#big + 1] = P(u, "wall.steel", 4, 0, x, Q)
  u = u + 1; big[#big + 1] = P(u, "wall.steel", -4, 0, x, -Q)
end
for i = 0, 3 do for k = 0, 3 do u = u + 1; big[#big + 1] = P(u, "floor.steel", -3 + 2 * i, 2.2, -3 + 2 * k) end end
local RB = rec_with(big)
local map = KS.supportMap(RB, defs)
local held = 0
for _, p in ipairs(big) do if p.id == "floor.steel" and map[p.uid] then held = held + 1 end end
check(held == 16, "an 8 m room: all sixteen roof panels are held through each other (" .. held .. ")")
check(map[RB.bp[#RB.bp].uid] ~= nil and KS.supportMap(RB, defs) == map, "the map is kept until the structure's parts change")
-- set on the terrain: held at any height in the frame
check(KS.supported(rec_with({}), defs, { uid = -1, id = "floor.steel", x = 9, y = 0.7, z = 0, yaw = 0, pitch = 0, roll = 0, gnd = true }, defs("floor.steel")),
  "a piece set on the terrain (gnd) is held wherever the ground put it")
-- what falls: a mezzanine floor hung on one wall goes with the wall
local R3 = rec_with({ P(1, "floor.steel", 0, 0, 0), P(2, "wall.steel", 0, 0.2, 1, 0), P(3, "floor.steel", 0, 1.2, 2), P(4, "wall.steel", 2, 0.2, 1, 0) })
local fall = KS.fallsWith(R3, defs, { 2 })
local fs = {}
for _, x in ipairs(fall) do fs[x] = true end
check(fs[3], "the floor hung on a wall's face falls with the wall")
local R4 = rec_with({ P(1, "floor.steel", 0, 0, 0), P(2, "wall.steel", 0, 0.2, 1, 0), P(3, "floor.steel", 0, 1.2, 2), P(5, "pillar2.steel", 0.75, 0, 2.75) })
check(#KS.fallsWith(R4, defs, { 2 }) == 0, "...but not when a pillar under it holds it too")

-- ── 2. snaps exact ─────────────────────────────────────────────────────────
local RF = rec_with({ P(1, "floor.steel", 0, 0, 0) })
local function face(id, px, py, pz, nx, ny, nz, yawOff)
  return KS.face({ def = defs(id), id = id, P = { x = px, y = py, z = pz }, N = { x = nx, y = ny, z = nz },
    toward = { x = 0, y = 0, z = 5 }, hit = { rec = RF, part = RF.bp[1] }, defs = defs, yawOff = yawOff })
end
for _, yo in ipairs({ math.rad(15), math.rad(5), math.rad(-30), math.rad(80) }) do
  local f = face("wall.steel", 0.2, 0.2, 0.8, 0, 1, 0, yo)
  local q = f and f.yaw / Q
  check(f and near(q, math.floor(q + 0.5), 1e-9), string.format("a wall on a floor's edge with %.0f° dialled: a quarter turn exactly (%.6f)", math.deg(yo), q or -1))
end
local fb = face("crate.steel", 0.3, 0.2, 0.3, 0, 1, 0, math.rad(5))
check(fb == nil or near((fb.yaw / math.rad(15)) % 1, 0, 1e-9) or near((fb.yaw / math.rad(15)) % 1, 1, 1e-9), "a block on a top keeps clean 15° steps")
-- ground near a structure joins it, in its frame
local tilt = { id = 3, b = "Home", x = 0, y = 800, z = 0, ux = 0.0, uy = 1, uz = 0.0, fx = 0, fy = 0, fz = 1, bp = { P(1, "slab2.concrete", 0, 0, 0) } }
local U2 = { x = 0.0087, y = 0.99996, z = 0.0 }  -- the radial up 7 m on
local s = SN.snap({ def = defs("floor.steel"), P = { x = 7.2, y = 800.03, z = 0.3 }, U = U2, toward = { x = 0.3, y = 0, z = 1 },
  near = { { rec = tilt, part = tilt.bp[1], d = 7.2 } }, defs = defs, yawOff = math.rad(15) })
check(s.mode == "grid" and s.rec == tilt and s.join, "ground 7 m from a structure joins it")
check(near(s.up.x, 0, 1e-12) and near(s.up.y, 1, 1e-12) and near(s.lx, 7.0) and near(s.lz, 0.5) and near(s.ly, 0.03, 1e-9),
  string.format("…in its own frame: its up exactly, on its 0.5 m grid (%.3f, %.3f, %.3f)", s.lx, s.ly, s.lz))
local s2 = SN.snap({ def = defs("floor.steel"), P = { x = 20, y = 800, z = 0 }, U = U2, toward = { x = 0, y = 0, z = 1 },
  near = { { rec = tilt, part = tilt.bp[1], d = 20 } }, defs = defs, yawOff = 0 })
check(s2.mode == "grid" and s2.rec == nil, "20 m out: a new structure, square to it, as before")
local s3 = SN.snap({ def = defs("floor.steel"), P = { x = 7.2, y = 800, z = 0.3 }, U = U2, toward = { x = 0, y = 0, z = 1 },
  near = { { rec = tilt, part = tilt.bp[1], d = 7.2 } }, defs = defs, yawOff = 0, free = true })
check(s3.mode == "free" and s3.rec == nil, "Shift still frees it")

-- ── 3. the input guard ─────────────────────────────────────────────────────
local focused = nil
local raw = {
  key = function(k) return true end, pressed = function(k) return true end, released = function(k) return true end,
  action = function(n) return true end, justPressed = function(n) return true end, justReleased = function(n) return true end,
  heldSecs = function(n) return 1.5 end, axis1 = function(n) return 0.7 end, axis2 = function(n) return 0.5, -0.5 end,
}
local uiStub = { focused = function() return focused end }
local IG = load_script("input_guard.lua", env({}, {}, { ui = uiStub, input = raw }))
check(IG.install(raw) == true and IG.install(raw) == false, "installed once on the shared table")
focused = { name = "FieldPartSearch" }
IG.forget()
check(raw.pressed("e") == false and raw.pressed("tab") == false and raw.pressed("b") == false and raw.pressed("3") == false
  and raw.key("w") == false and raw.key("ctrl") == false and raw.released("space") == false, "typing: E, Tab, B, 3, W, Ctrl, Space are not game keys")
check(raw.pressed("escape") == true and raw.pressed("enter") == true, "...Escape and Enter still are (they drop or submit the field)")
local ax, ay = raw.axis2("Move")
check(raw.justPressed("Jump") == false and raw.action("Interact") == false and ax == 0 and ay == 0 and raw.axis1("Fly") == 0
  and raw.heldSecs("Sprint") == 0, "...no Jump, no Interact, no Move, no Fly, no Sprint")
local lx, ly = raw.axis2("Look")
check(raw.justPressed("Pause") == true and lx == 0.5 and raw.axis1("Zoom") == 0.7 and raw.action("LookEnable") == true,
  "...the mouse's look and zoom and Pause still answer")
check(raw.rawPressed("e") == true, "a script that must can read the raw key")
do
  local held = { space = true }
  local r2 = { key = function(k) return held[k] == true end, pressed = function(k) return held[k] == true end, released = function() return false end }
  local IG2 = load_script("input_guard.lua", env({}, {}, { ui = { focused = function() return nil end, focus = function() end }, input = r2 }))
  IG2.install(r2)
  local sp1 = r2.spaceSubmit(nil)
  held = { space = true, enter = true }
  check(sp1 == true and r2.spaceSubmit(nil) == false, "a field's submit fired by Space is told apart from Enter's (the engine's nav counts Space as submit)")
end
focused = { name = "PauseResume" }
IG.forget()
check(raw.pressed("e") == true and raw.justPressed("Jump") == true, "a focused button blocks nothing")
focused = nil
IG.forget()
check(raw.key("w") == true, "nothing focused: everything answers")

-- ── 4. the tower: 300 m apart ───────────────────────────────────────────────
local B = load_script("bases.lua", env({}, {}))
local RR = 922
local why = B.spacingWhy("Naolol", RR * math.cos(210 / RR), RR * math.sin(210 / RR), 0, RR, { b = "Naolol", x = RR, y = 0, z = 0 })
check(why and why:find("300 m apart", 1, true) and why:find("90 m further", 1, true), "210 m from the station: refused, and it says how far on: " .. tostring(why))
check(B.spacingWhy("Naolol", RR * math.cos(320 / RR), RR * math.sin(320 / RR), 0, RR, { b = "Naolol", x = RR, y = 0, z = 0 }) == nil,
  "320 m from the station: a tower can stand (it was 1 km: nowhere near home)")

-- ── 5. base_hub: the catalogue ──────────────────────────────────────────────
S.base_economy = load_script("base_economy.lua", env(store, S))
local BH = load_script("base_hub.lua", env(store, S))
S.base_hub = BH
local REG, CAT = { frameP = { prefab = "PartFrame" } }, { { "COMMAND", { "pod" } }, { "FRAME", { "frameP" } }, { "NUCLEAR", { "rtg" } } }
local n = BH.register(REG, CAT)
local titles, where = {}, {}
for _, sec in ipairs(CAT) do titles[sec[1]] = #sec[2]; for _, id in ipairs(sec[2]) do where[id] = sec[1] end end
check(titles.BASE and where.baseHub == "BASE" and where.tower == "BASE" and where.powerCable == nil, "the BASE section: the hub, the tower … (a cable is a run, not a part)")
check(titles.WALL and titles.FLOOR and titles.FLUID and titles.POWER and titles.LIFE and titles.PROPS and titles.DECALS, "every kit category is a section")
check(titles["BASE FRAME"] and titles["BASE NUCLEAR"] and titles.FRAME == 1 and titles.NUCLEAR == 1, "a title the VAB uses is \"BASE …\": FRAME, NUCLEAR")
check(where["wall.steel"] == "WALL" and where["wall.concrete"] == "WALL" and where["wall.glass"] == "WALL" and where["wall.regocrete"] == "WALL",
  "a piece comes in every material it is made in")
check(where["vab.pod"] == nil and REG["vab.pod"] == nil, "a VAB fitting is not listed twice (the VAB's own sections have it)")
local nkit = 0
for k, Pc in pairs(K.PIECES) do nkit = nkit + #Pc.mats end
check(n >= nkit and REG["doorWallM.steel"] ~= nil and where["doorWallM.steel"] == nil, string.format("%d entries; a hidden piece loads but isn't listed", n))
local wd = REG["wall.steel"]
check(wd.base and wd.baseId == "wall.steel" and near(wd.h, 2.2) and near(wd.npiv.y, -1.1) and near(wd.npiv.x, 0) and wd.kitSnap,
  "a wall's builder box is centred 1.1 m over its ground point: its prefab root 1.1 m under the box centre")
local sd = REG.slab2 or REG["slab2.concrete"]
check(sd and near(sd.npiv.y, -0.05), "a slab's root is its ground point, 0.05 m under its box centre (it is cast 0.1 m into the ground)")
local td = REG.tower
check(td and near(td.npiv.y, PB.partInfo("tower").seat - PB.partInfo("tower").half.y, 1e-6), "a BASE part's root is its seat over the ground")

-- ── 6. base_hub: into the builder and back ──────────────────────────────────
local hubrec = rec_with({ P(1, "baseHub", 0, 0, 0), P(2, "floor.steel", 4, 0, 0, Q), P(3, "wall.steel", 4, 0.2, 1, 0),
                          { uid = 4, id = "truss2.steel", x = 3, y = 2.4, z = -1, yaw = Q, pitch = Q, roll = 0 },
                          P(5, "tower", 10, 0, 0, 0.3) })
hubrec.id = 21
local bp = BH.toBuilder(hubrec, {})
local back = BH.fromBuilder(bp.parts, REG)
local exact = #back == #hubrec.bp
for i, e in ipairs(back) do
  local p = hubrec.bp[i]
  if not (e.id == p.id and near(e.x, p.x, 1e-9) and near(e.y, p.y, 1e-9) and near(e.z, p.z, 1e-9) and near(e.yaw, p.yaw, 1e-12) and near(e.pitch, p.pitch, 1e-12)) then exact = false end
end
check(exact, "a structure into the builder and back: every piece where it was, to 1e-9 m (turned, a truss laid down, a seated tower)")
local wb
for _, d in ipairs(bp.parts) do if d.uid == 3 then wb = d end end
check(wb and near(wb.y, 0.2 + 1.1) and near(wb.z, 1.0), "the wall's builder centre is 1.1 m over its ground point")
-- the diff: the hub moved (kept), a floor moved, the tower taken off, a strut and a cockpit added
local list = {}
for _, d in ipairs(bp.parts) do list[#list + 1] = { uid = d.uid, id = d.id, x = d.x, y = d.y, z = d.z, yaw = d.yaw, pitch = d.pitch, roll = d.roll } end
list[1].x = list[1].x + 3
list[2].z = list[2].z + 2
table.remove(list, 5)
list[#list + 1] = { uid = 9, id = "beamP", x = 4, y = 3.0, z = 0, yaw = 0, pitch = 0, roll = 0,
  lp = { uid = 9, id = "beamP", prefab = "PartBeam", label = "Strut", h = 2, rx = 0.1, rz = 0.1, mass = 0.04, cost = 30, kind = "structural",
         proc = "member", size = { len = 2, prof = "box" }, x = 1, y = 2, z = 3 } }
list[#list + 1] = { uid = 10, id = "cockpit", x = 4, y = 3.5, z = 1, yaw = 0, pitch = Q, roll = 0,
  lp = { uid = 10, id = "cockpit", prefab = "PartCockpit", label = "Swift Cockpit", h = 2.2, rx = 0.5, rz = 0.5, mass = 0.35, cost = 700, kind = "crewed" } }
local entries = BH.fromBuilder(list, REG)
local d = BH.diff(hubrec, entries, 1)
check(#d.add == 2 and #d.move == 1 and #d.remove == 1 and d.remove[1] == 5 and #d.kept == 1, string.format("the diff: 2 added, 1 moved, the tower off, the hub kept (%d/%d/%d/%d)", #d.add, #d.move, #d.remove, #d.kept))
local ce
for _, e in ipairs(entries) do if e.uid == 10 then ce = e end end
check(ce and ce.id == "vab.cockpit" and near(ce.y, 3.5 - PB.partInfo("vab.cockpit").seat) and ce.lp and ce.lp.x == nil and ce.lp.id == "cockpit",
  "a VAB part is a live part \"vab.<id>\" with its launch record (no pose in it)")
-- the commit, on stub structures and a stub company
local spent, refunded = {}, {}
local stST = { recs = { [21] = hubrec }, version = 0 }
function stST.get(id) return stST.recs[id] end
function stST.put(r) stST.version = stST.version + 1 return true end
function stST.removeParts(id, uids)
  local r = stST.recs[id]
  for _, uu in ipairs(uids) do for i = #r.bp, 1, -1 do if r.bp[i].uid == uu then table.remove(r.bp, i) end end end
  return {}
end
function stST.addPart(id, part)
  local r = stST.recs[id]
  local m = 0
  for _, p in ipairs(r.bp) do m = math.max(m, p.uid) end
  part.uid = part.uid or (m + 1)
  r.bp[#r.bp + 1] = part
  return part.uid
end
S.structures = stST
S.company = { spend = function(v, w) spent[#spent + 1] = v; return true end, refund = function(v, w) refunded[#refunded + 1] = v end }
hubrec.bp[5].paid = { cost = 4000, ship = 450, total = 4450, t = -100 }
local okc, whyc, q = BH.commit(21, entries, { hubUid = 1, t = 100 })
check(okc and q and q.added == 730 and q.ship == S.base_economy.shipping(730) and q.refund == 4000,
  string.format("the bill: $730 of parts + one truck; the tower back at its price (%s, %s, %s)", tostring(q and q.added), tostring(q and q.ship), tostring(q and q.refund)))
check(#spent == 0 and #refunded == 1 and near(refunded[1], 4000 - 730 - S.base_economy.shipping(730)), "one movement of money: the net back")
local hb, fl, sp
for _, p in ipairs(hubrec.bp) do if p.uid == 1 then hb = p elseif p.uid == 2 then fl = p elseif p.uid == 10 then sp = p end end
check(hb and near(hb.x, 0) and fl and near(fl.z, 2) and sp and sp.id == "vab.cockpit" and sp.paid and sp.paid.total > 0,
  "the hub stays put, the floor moved, the cockpit joined with its share of the bill")
local lps = store["slivebp.21"]
check(type(lps) == "table" and lps["9"] and lps["9"].size.len == 2 and lps["10"].prefab == "PartCockpit", "the VAB parts' launch records are kept beside the structure")
check(type(store.vabdefs) == "table" and store.vabdefs.beamP and store.vabdefs.beamP.prefab == "PartBeam" and PB.partInfo("vab.beamP").live,
  "a part the world has no registry for is learned: vab.beamP is a live part now")
-- struct_live builds the vessel from the kept records
S.electronics = load_script("electronics.lua", env(store, S))
local SL = load_script("struct_live.lua", env(store, S))
local vbp = SL.blueprintOf(hubrec, defs, nil, S.electronics, lps)
local vb, vc
for _, x in ipairs(vbp and vbp.parts or {}) do if x.uid == 9 then vb = x elseif x.uid == 10 then vc = x end end
check(vbp and vb and vb.proc == "member" and vb.size.len == 2 and near(vb.y, 3.0) and vc and near(vc.pitch, Q) and vbp.root == 10,
  "the structure vessel: the strut at its size, the cockpit turned as it was built, the cockpit its root")

-- ── 7. structures.suspend ───────────────────────────────────────────────────
local st2 = {}
local ST = load_script("structures.lua", env(st2, S))
local r = ST.newRecord(nil, "Home", 0, 800, 0, { x = 0, y = 1, z = 0 }, { x = 0, y = 0, z = 1 }, "floor.steel")
local sid = ST.add(r)
local v0 = ST.version
check(ST.suspend(sid, true) and ST.suspended(sid) and ST.version > v0 and not ST.isLive(sid), "a structure held out of the world: not live, the version moved")
check(ST.suspend(sid, false) and not ST.suspended(sid), "...and let back in")

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL: " .. f) end
  print(string.format("smoke_fullbuild: %d passed, %d FAILED", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_fullbuild: all %d checks passed", passed))
