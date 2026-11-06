-- SMOKE: bases get character (sandbox plan S4, work/sandbox/PLAN.md §5,
-- §1.4, §6; docs/base-building.md §15), against the real parts_kit,
-- kit_snap, kit_paint, blueprints, structures, kit_live and field_builder on a
-- stub save that copies what it stores (as the real one does).
--
--   * the palette: twelve swatches from the UI tokens; paint is the tint that
--     turns a material's average into the swatch (so the texture's own wear
--     shows through); what takes paint and what doesn't; a wall's two faces;
--     dust by age, faster on a dry world, capped, quantised;
--   * T turns a mount on its face (kit_snap.spinPose keeps its face out);
--     a click on a wall finds the decal on it (kit_snap.mountAt);
--   * paint through field_builder: a face, both, a selection of pieces; the
--     cost, the undo's refund, Creative free; the paint is in the saved
--     records and comes back on a reload;
--   * the character pieces: props (colliders unless clutter), decals (films
--     that overlap nothing), signs (their words, or the base's name);
--   * blueprints: from a structure (paint, inside paint and a sign's words
--     travel), the code and back identical, a damaged or cut code refused,
--     the JSON file and back identical, the library on a stub disk, the stock
--     hut's code under 4 kB, ONE bill (shipping once), each piece's share;
--   * placing a blueprint: the composite paste charges the bill once, every
--     piece fits, they carry their paint, one Ctrl+Z refunds it all; turned.
--
--   luajit solar/tests/smoke_character.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, e) return math.abs(a - b) <= (e or 1e-6) end

local function deep(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = deep(v) end
  return o
end
local function env(store, scripts, extra)
  local E = setmetatable({
    time = 5.0,
    save = {
      get = function(k) return deep(store[k]) end,
      set = function(k, v) store[k] = deep(v) end,
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

local store = { ["base.body"] = "Home", ["agency.clock"] = 1000 }
local SS = {}
local spent, refunded = 0, 0
local sandbox = false
SS.company = { spend = function(n) spent = spent + n; return true end, refund = function(n) refunded = refunded + n end,
               earn = function(n) refunded = refunded + n end, afford = function() return true end,
               isSandbox = function() return sandbox end }
local K = load_script("parts_kit.lua", env(store, SS)); SS.parts_kit = K
local PB = load_script("parts_base.lua", env(store, SS)); SS.parts_base = PB
local KS = load_script("kit_snap.lua", env(store, SS)); SS.kit_snap = KS
local KP = load_script("kit_paint.lua", env(store, SS)); SS.kit_paint = KP
local disk = {}
local ASSETS = {
  writeJson = function(p, t) disk[p] = deep(t); return true end,
  readJson = function(p) return deep(disk[p]) end,
  writeText = function(p, s) disk[p] = s; return true end,
  getContents = function(dir) local o = {} for k in pairs(disk) do if k:sub(1, #dir) == dir then o[#o + 1] = k end end table.sort(o) return o end,
  remove = function(p) disk[p] = nil; return true end,
}
local BP = load_script("blueprints.lua", env(store, SS, { assets = ASSETS })); SS.blueprints = BP
local defs = function(id) return PB.partInfo(id) end
local SPACE = { body = function() return { x = 0, y = 0, z = 0 } end, dominant = function() return "Home" end }

-- ── the palette ─────────────────────────────────────────────────────────────
check(#KP.PALETTE == 12, string.format("a curated palette of 12 swatches (%d)", #KP.PALETTE))
do
  local seen, ok = {}, true
  for _, s in ipairs(KP.PALETTE) do
    if seen[s.key] or not s.token or not s.label then ok = false end
    seen[s.key] = true
    for i = 1, 3 do if not (s.rgb[i] > 0 and s.rgb[i] <= 0.95) then ok = false end end
  end
  check(ok, "each swatch: a key of its own, a label, the UI token it comes from, an enamel's albedo (never pure white or black)")
end
do
  local w = defs("wall.steel")
  local t = KP.tintFor("orange", w)
  local ok = true
  for i = 1, 3 do if not near(t[i] * KP.BASE.steel[i], KP.swatch("orange").rgb[i], 1e-9) then ok = false end end
  check(ok, "paint is the tint that turns the steel's average into the swatch (its stains and seams show through)")
  local c = KP.tintFor("hull", defs("wall.concrete"))
  check(c[1] > 1 and c[1] <= KP.TINT_MAX, "white paint on dark concrete lifts it, within the tint's ceiling")
  -- (S5 polish) the tint never crushes a swatch: on every kit material each
  -- swatch lands on its own albedo (no channel clamped), and the palette
  -- spans light to dark: three swatches over 0.5 luminance, two under 0.07
  local crushed = {}
  for _, m in ipairs({ "steel", "concrete", "regocrete" }) do
    for _, sw in ipairs(KP.PALETTE) do
      local tt = KP.tintFor(sw.key, { kit = true, mat = m })
      for i = 1, 3 do
        if math.abs(tt[i] * KP.BASE[m][i] - sw.rgb[i]) > 1e-9 then crushed[#crushed + 1] = sw.key .. " on " .. m end
      end
    end
  end
  check(#crushed == 0, "no swatch is clamped by the tint on any material: " .. table.concat(crushed, ", "))
  local light, dark, lums = 0, 0, {}
  for _, sw in ipairs(KP.PALETTE) do
    local Y = 0.2126 * sw.rgb[1] + 0.7152 * sw.rgb[2] + 0.0722 * sw.rgb[3]
    if Y > 0.5 then light = light + 1 end
    if Y < 0.07 then dark = dark + 1 end
    lums[#lums + 1] = string.format("%s %.2f", sw.key, Y)
  end
  check(light >= 3 and dark >= 2, "the palette has real value range (light " .. light .. ", dark " .. dark .. "): " .. table.concat(lums, ", "))
  check(KP.swatch("sand") == KP.swatch("bone"), "a key from the first palette still resolves (sand is cream now)")
  check(KP.tintFor(nil, w) == nil and KP.tintFor("nope", w) == nil, "no swatch, no tint")
  KP.setAgency({ 0.85, 0.20, 0.10 })
  local a = KP.rgbOf("agency")
  check(a[1] > a[2] and a[1] <= 0.8, "the agency swatch follows the emblem's colour, worn to an enamel")
  KP.setAgency(nil)
end
check(KP.paintable(defs("wall.steel")) and KP.paintable(defs("crate.steel")) and KP.paintable(defs("habSeg.steel")),
  "walls, props and hab cans take paint")
check(not KP.paintable(defs("lightFitting.steel")) and not KP.paintable(defs("decalHaz.film")) and not KP.paintable(defs("vab.pod"))
  and not KP.paintable(defs("lampDesk.steel")), "a light's lens, a decal and a VAB fitting don't")
check(defs("wall.steel").faces2 and defs("doorWall.concrete").faces2 and defs("habSeg.steel").faces2 and not defs("floor.steel").faces2,
  "walls and hab cans have two faces to paint")
check(KP.faceOf(0, 0, 1) == "out" and KP.faceOf(0, 0, -1) == "in" and KP.faceOf(math.pi / 2, 1, 0) == "out" and KP.faceOf(math.pi / 2, -1, 0) == "in",
  "which face a hit is on, by the piece's yaw")
do
  local p = { paint = "hull" }
  local f = KP.painted(p, "orange", "in", 7)
  check(f.paint == "hull" and f.paintIn == "orange" and f.pt == 7, "painting the inside keeps the outside")
  f = KP.painted({ paint = "hull", paintIn = "bone" }, "olive", "both", 8)
  check(f.paint == "olive" and f.paintIn == nil, "painting both faces is one coat")
  check(KP.pick({ paint = "hull", paintIn = "bone" }, "in") == "bone" and KP.pick({ paint = "hull" }, "in") == "hull", "the eyedropper picks the face it's on")
end
-- dust
do
  local a, b, c = KP.dustLevel(0, false), KP.dustLevel(30, false), KP.dustLevel(400, false)
  check(a == 0 and b > 0 and c > b and c <= 0.55 + 1e-9, string.format("dust gathers with age and stops (0 → %.2f → %.2f)", b, c))
  check(KP.dustLevel(400, true) < c, "rain washes the home world's walls: less dust")
  check(near(b * KP.DUST_STEPS, math.floor(b * KP.DUST_STEPS + 0.5)), "the level is quantised (a re-tint only when it steps)")
  local w = defs("wall.steel")
  local t = KP.surfaceTint(nil, w, 1.0, { 0.4, 0.36, 0.3 })
  check(near(t[1] * KP.BASE.steel[1], 0.4, 1e-9), "fully dusty, the surface is the dust's colour")
  check(KP.surfaceTint(nil, w, 0) == nil, "clean and bare: no tint at all")
  local okn = true
  for _, d0 in ipairs({ 0, 1, 7.3, 30, 90 }) do
    for _, wet in ipairs({ false, true }) do
      local nx = KP.nextStepDays(d0, wet)
      if nx then
        if not (nx > d0 and KP.dustLevel(nx - 1e-6, wet) == KP.dustLevel(d0, wet) and KP.dustLevel(nx + 1e-6, wet) ~= KP.dustLevel(d0, wet)) then okn = false end
      end
    end
  end
  check(okn and KP.nextStepDays(5000, false) == nil, "the driver knows when a piece's dust next steps (and that it stops): idle structures are not looked at")
end
-- spin and pick
do
  local yaw, pitch, roll = KS.spinPose(0, math.pi / 2, math.pi / 2)
  local up, fw = KS.localAxes(yaw, pitch, roll)
  local u0, f0 = KS.localAxes(0, math.pi / 2, 0)
  check(near(up[1], u0[1], 1e-6) and near(up[2], u0[2], 1e-6) and near(up[3], u0[3], 1e-6) and math.abs(fw[1] * f0[1] + fw[2] * f0[2] + fw[3] * f0[3]) < 1e-6,
    "T turns a mount on a wall a quarter about its face: it still faces out, its top turned 90°")
  check(KS.spinPose(0.3, 0.2, 0) == 0.3, "no spin, no change")
  local R = { id = 9, b = "Home", x = 0, y = 0, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1,
              bp = { { uid = 1, id = "wall.steel", x = 0, y = 0, z = 0, yaw = 0, pitch = 0, roll = 0 },
                     { uid = 2, id = "decalHaz.film", x = 0, y = 1.2, z = 0.1, yaw = 0, pitch = math.pi / 2, roll = 0 },
                     { uid = 3, id = "decalNum3.film", x = 0.5, y = 1.2, z = 0.1, yaw = 0, pitch = math.pi / 2, roll = 0 } } }
  local m = KS.mountAt(R, defs, -0.6, 1.22, 0.1)
  check(m and m.uid == 2, "a click on the wall lands on the hazard stripe painted there")
  m = KS.mountAt(R, defs, 0.5, 1.25, 0.1)
  check(m and m.uid == 3, "where a number sits on the stripe, the number")
  check(KS.mountAt(R, defs, 0, 2.0, 0.1) == nil and KS.mountAt(R, defs, -0.6, 1.2, -0.1) == nil, "off it, or on the wall's other face: none")
  check(KS.overlapIn(R, defs, { uid = -1, id = "decalHaz.film", x = 0, y = 1.25, z = 0.1, yaw = 0, pitch = math.pi / 2 }, defs("decalHaz.film")) == nil,
    "a film overlaps nothing: paint goes over paint")
end
-- the character pieces
do
  local props, clutter, films = 0, 0, 0
  for k, P in pairs(K.PIECES) do
    if P.section == "PROPS" then props = props + 1; if P.clutter then clutter = clutter + 1 end end
    if P.film then films = films + 1 end
  end
  check(props >= 16 and clutter >= 4, string.format("props for clutter and character (%d, %d of them clutter)", props, clutter))
  check(films >= 24, string.format("decals: stock films (%d)", films))
  check(defs("lampFloor.steel").light and defs("lampFloor.steel").script == "kit_live" and defs("lampFloor.steel").power.use > 0,
    "a work light pools with the kit's lights and draws from the grid")
  check(defs("signBoard.steel").sign and defs("signBoard.steel").script == "kit_live" and defs("decalEmblem.film").emblem,
    "signs and the emblem are drawn by kit_live")
  check(defs("crate.steel").exterior == false and defs("wall.steel").exterior == true, "dust settles on the structure, not the furniture")
  local secs = {}
  for _, s in ipairs(K.catalogue("steel")) do secs[s.title] = #s.ids end
  check((secs.PROPS or 0) >= 16 and (secs.DECALS or 0) >= 24, "the PROPS and DECALS tabs")
end

-- ── field_builder: paint, blueprints, placing one ───────────────────────────
SS.base_economy = load_script("base_economy.lua", env(store, SS))
SS.structures = load_script("structures.lua", env(store, SS))
SS.base_snap = load_script("base_snap.lua", env(store, SS))
SS.builder_history = load_script("builder_history.lua", env(store, SS))
SS.crew = { activeId = function() return 1 end, hasRole = function() return true end, credit = function() end }
SS.bases = { baseAt = function() return { n = "Kestrel Flats" } end }
local E = env(store, SS, { space = SPACE })
local FB = load_script("field_builder.lua", E)
SS.field_builder = FB
local KL = load_script("kit_live.lua", env(store, SS)); SS.kit_live = KL
local ST = SS.structures

local g = { body = "Home", x = 0, y = 0, z = 0, up = { x = 0, y = 1, z = 0 }, fwd = { x = 0, y = 0, z = 1 }, mode = "grid", base = 0 }
local function face(sid, lx, ly, lz, yaw, pitch)
  return { body = "Home", mode = "face", sid = sid, lx = lx, ly = ly, lz = lz, yaw = yaw or 0, pitch = pitch or 0, roll = 0,
           x = lx, y = ly, z = lz, up = { x = 0, y = 1, z = 0 }, fwd = { x = 0, y = 0, z = 1 } }
end
local sid = FB.place(nil, "slab2.concrete", g, "money")
local q = math.pi / 2
local _, _, _, wF = FB.place(sid, "doorWall.steel", face(sid, 0, 0.2, 1, 0), "money")
local _, _, _, wB = FB.place(sid, "wall.steel", face(sid, 0, 0.2, -1, math.pi), "money")
local _, _, _, wL = FB.place(sid, "wall.steel", face(sid, -1, 0.2, 0, -q), "money")
local _, _, _, wR = FB.place(sid, "windowWall.steel", face(sid, 1, 0.2, 0, q), "money")
local _, _, _, sg = FB.place(sid, "signPlate.steel", face(sid, 0.5, 1.8, 1.1, 0, q), "money")
local _, _, _, dc = FB.place(sid, "decalHaz.film", face(sid, 0, 0.35, 1.1, 0, q), "money")
local _, _, _, cr = FB.place(sid, "crate.steel", face(sid, 0.3, 0.2, -0.4, 0), "money")
check(wF and wB and wL and wR and sg and dc and cr, "a little hut: a slab, four walls, a sign, a stripe, a crate")
-- paint
spent, refunded = 0, 0
local n = FB.paintParts(sid, { wF }, "orange", "out")
check(n == 1 and ST.getPart(sid, wF).paint == "orange" and ST.getPart(sid, wF).paintIn == nil and spent == KP.PAINT_COST,
  "LMB on the door wall's outside: orange out, the inside bare, one coat paid")
FB.paintParts(sid, { wF }, "bone", "in")
check(ST.getPart(sid, wF).paint == "orange" and ST.getPart(sid, wF).paintIn == "bone", "its inside bone, the outside kept")
n = FB.paintParts(sid, { wB, wL, wR, dc }, "hull", "both")
check(n == 3 and ST.getPart(sid, dc).paint == nil, "a selection: three walls hull white, the decal untouched")
local before = spent
local amt = FB.undo()
check(amt == 3 * KP.PAINT_COST and ST.getPart(sid, wB).paint == nil and refunded >= 3 * KP.PAINT_COST, "Ctrl+Z takes the coat back, refunded")
FB.redo()
check(ST.getPart(sid, wB).paint == "hull" and spent > before, "and Ctrl+Shift+Z paints it again")
sandbox = true
local s0 = spent
FB.paintParts(sid, { cr }, "orange", "both")
check(spent == s0 and ST.getPart(sid, cr).paint == "orange", "Creative: paint is free")
sandbox = false
check(FB.paintParts(sid, { dc }, "orange", "both") == nil, "a decal alone takes no paint")
-- it's in the save: a reload brings it back
ST.reloadFromSave()
check(ST.getPart(sid, wF).paint == "orange" and ST.getPart(sid, wF).paintIn == "bone" and ST.getPart(sid, wR).paint == "hull",
  "the paint is in the saved records and comes back on a reload")
-- a sign's words
local w, isBase = KL.signWords(sid, sg)
check(w == "Kestrel Flats" and isBase, "a new sign shows the base's name")
KL.setSignWords(sid, sg, "Workshop 2")
w, isBase = KL.signWords(sid, sg)
check(w == "Workshop 2" and not isBase and ST.partState(sid, sg).text == "Workshop 2", "written on, it keeps its own words (in the part state)")
-- the tools in the column
do
  local secs = {}
  for _, s in ipairs(FB.catalogue()) do secs[s.title] = s.ids end
  check(secs.PAINT and #secs.PAINT == 14 and secs.BLUEPRINTS and #secs.BLUEPRINTS >= 4, "the PAINT tab (12 swatches, the eyedropper, strip) and BLUEPRINTS (save, import, the stock)")
  local d = FB.partInfo("paint:orange")
  check(d and d.tool == "paint" and d.paint == "orange" and d.cost == KP.PAINT_COST and FB.isTool("paint:orange") and FB.isTool("paint:pick"),
    "a swatch card is a tool with its price")
  check(FB.partInfo("bp:stock.hut") and FB.partInfo("bp:stock.hut").cost > 0, "a blueprint card is priced at its one bill")
end

-- ── blueprints ──────────────────────────────────────────────────────────────
local rec = ST.get(sid)
local bp = BP.fromParts(rec, nil, defs, { name = "Hut A", texts = function(uid) local st = ST.partState(sid, uid); return st and st.text end })
check(bp and bp.n == #rec.bp and bp.pieces[1].id == "slab2.concrete" and near(bp.pieces[1].x, 0) and near(bp.pieces[1].yaw, 0),
  "a blueprint of the whole hut: every piece, the slab its anchor at the origin")
local found = {}
for _, e in ipairs(bp.pieces) do found[e.id] = e end
check(found["doorWall.steel"].paint == "orange" and found["doorWall.steel"].paintIn == "bone" and found["signPlate.steel"].text == "Workshop 2",
  "paint, inside paint and the sign's words travel with the pieces")
local code = BP.encode(bp)
local back, why = BP.decode(code)
check(back and BP.same(bp, back) and back.name == "Hut A", "the code and back: the same build (" .. tostring(why) .. ")")
check(code:match("^SOLBP1%.[%w%-_]+%.%w%w%w%w$") ~= nil and #code < 4000, string.format("one line, %d characters", #code))
do
  local bad = code:sub(1, 20) .. (code:sub(21, 21) == "A" and "B" or "A") .. code:sub(22)
  local b1, w1 = BP.decode(bad)
  local b2, w2 = BP.decode(code:sub(1, #code - 30) .. code:sub(-5))
  check(b1 == nil and w1:find("damaged") and b2 == nil, "a code mistyped or cut short is refused, not half built")
  check(BP.decode("hello") == nil and BP.decode("SOLBP9.abc.0000") == nil, "and so is something that isn't one")
end
-- the JSON file and the library on disk
local slug, path, code2 = BP.saveBp(bp)
check(slug == "hut-a" and path == "user://blueprints/hut-a.json" and disk[path] and disk["user://blueprints/hut-a.code.txt"] and code2 == code,
  "saved: user://blueprints/hut-a.json, its code beside it")
BP.scan()
local again = BP.get("hut-a")
check(again and BP.same(bp, again) and again.name == "Hut A", "read back from the disk: the same build")
check(BP.fromTable({ v = 9, pieces = { { id = "wall.steel" } } }) == nil and BP.fromTable({ pieces = {} }) == nil, "a newer or empty file is refused")
local s3 = BP.importCode(code:gsub("%.", ".", 1))
check(s3 ~= nil, "a pasted code joins the library")
-- the stock and one bill
local hut = BP.stock("stock.hut")
local hcode = BP.encode(hut)
check(hut and hut.n >= 25 and #hcode < 4000, string.format("the stock hut: %d pieces, a %d-character code (plan: under 4 kB)", hut and hut.n or 0, #hcode))
local bill = FB.blueprintBill(hut)
local sum = 0
for _, e in ipairs(hut.pieces) do sum = sum + defs(e.id).cost end
check(bill.cost == sum and bill.ship == SS.base_economy.shipping(sum) and bill.total == sum + bill.ship and #bill.missing == 0,
  string.format("ONE bill: the pieces %s + one delivery %s", tostring(bill.cost), tostring(bill.ship)))
do
  local shares = 0
  for _, e in ipairs(hut.pieces) do shares = shares + BP.shareOf(bill, defs(e.id).cost) end
  check(math.abs(shares - bill.ship) <= #hut.pieces, "each piece carries its share of the delivery")
end

-- ── placing a blueprint: one bill, every piece, its paint; one undo ─────────
spent, refunded = 0, 0
check(FB.holdBlueprint("stock.hut") and FB.pasting and FB.clip.n == hut.n and FB.heldBp == "bp:stock.hut", "the hut in hand: a paste of its pieces")
local g2 = { body = "Home", x = 40, y = 0, z = 0, up = { x = 0, y = 1, z = 0 }, fwd = { x = 1, y = 0, z = 0 }, mode = "grid", base = 0 }
FB.paste_click(g2)
local lp = FB.lastPaste
check(lp and lp.placed == hut.n and lp.skipped == 0, string.format("every piece fits (%d placed, %d didn't: %s)", lp and lp.placed or -1, lp and lp.skipped or -1, lp and table.concat(lp.why or {}, "; ") or ""))
check(spent == bill.total and refunded == 0, string.format("charged once, the bill: %d (bill %d)", spent, bill.total))
local hrec = ST.get(lp.sid)
local paid, walls, painted = 0, 0, 0
for _, p in ipairs(hrec.bp) do
  paid = paid + (p.paid and p.paid.total or 0)
  if p.id == "wall.steel" then walls = walls + 1; if p.paint == "hull" and p.paintIn == "bone" then painted = painted + 1 end end
end
check(math.abs(paid - bill.total) <= hut.n, "the pieces' records add up to the bill (an undo refunds it)")
check(walls >= 4 and painted == walls, string.format("the walls came painted, hull out and bone in (%d of %d)", painted, walls))
check(hrec.fx == 1 and math.abs(hrec.fz) < 1e-9, "turned: the hut faces the way the anchor was turned")
local u = FB.undo()
check(u ~= nil and ST.get(lp.sid) == nil and math.abs(refunded - bill.total) <= hut.n, "one Ctrl+Z takes the whole hut back, refunded")
-- every stock blueprint builds whole, and a saved one does too
for _, s in ipairs(BP.STOCK) do
  FB.holdBlueprint(s.key)
  FB.paste_click({ body = "Home", x = 80, y = 0, z = 0, up = { x = 0, y = 1, z = 0 }, fwd = { x = 0, y = 0, z = 1 }, mode = "grid", base = 0 })
  local l2 = FB.lastPaste
  check(l2 and l2.skipped == 0 and l2.placed == FB.clip.n, string.format("stock %s builds whole (%s)", s.key, table.concat(l2 and l2.why or {}, "; ")))
  FB.undo()
end
FB.holdBlueprint("hut-a")
FB.paste_click({ body = "Home", x = -60, y = 0, z = 0, up = { x = 0, y = 1, z = 0 }, fwd = { x = 0, y = 0, z = -1 }, mode = "grid", base = 0 })
do
  local l3 = FB.lastPaste
  local r3 = l3 and ST.get(l3.sid)
  local sgn = nil
  for _, p in ipairs(r3 and r3.bp or {}) do if p.id == "signPlate.steel" then sgn = p end end
  check(l3 and l3.skipped == 0 and sgn and ST.partState(l3.sid, sgn.uid) and ST.partState(l3.sid, sgn.uid).text == "Workshop 2",
    "the saved hut built again from the library, its sign's words with it")
end

if #failures > 0 then
  print("FAIL smoke_character: " .. #failures .. " of " .. (#failures + passed))
  for _, m in ipairs(failures) do print("  - " .. m) end
  os.exit(1)
end
print("ok smoke_character: " .. passed .. " checks")
