-- SMOKE: wood in the Build Kit (progression W1; work/progression/PLAN.md §3;
-- docs/base-building.md §35). Ty 11-11: "cheaper building options like things
-- made of wood for making bridges and simple structures".
--
--   * the material: 550 kg/m³, strength 40, never seals; masses and prices of
--     the plan's worked examples (wall 106 kg $130, floor 110 kg $110, beam4
--     $80, pillar2 $50, roofPitch $90, stairs $210);
--   * the TIMBER pieces: their section first in the column, a Camp Mast that
--     founds a base and never becomes a ground station, a hinged plank door,
--     shoring behind its feat, the Sawbench's saw;
--   * paying: the warehouse's planks pay a timber piece's wood (fittings only),
--     too few and it ships ready-cut; recipes and the Fabricator take planks;
--   * leaky: a room walled in timber is not sealed (its walls are its leaks);
--   * the saw: rates by hand, an Engineer and on the grid, a job advanced on
--     the clock pays whole kg; unsawn timber comes back; the Depot's lots;
--   * strip and damage rows for wood.
--
--   luajit solar/tests/smoke_kit_wood.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, e) return a ~= nil and b ~= nil and math.abs(a - b) <= (e or 1e-6) end

local store = {}
local S = {}
local function env(extra)
  local E = setmetatable({
    time = 1.0,
    save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end,
             delete = function(k) store[k] = nil end },
    findScript = function(k) return S[k] end,
    findScripts = function() return {} end,
    find = function() return nil end,
    log = function() end,
  }, { __index = _G })
  for k, v in pairs(extra or {}) do E[k] = v end
  return E
end
local function load(path, E)
  E = E or env()
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, E)
  f()
  E.params = {}
  for k, v in pairs(E.defaults or {}) do E.params[k] = v end
  return E
end

local MT = load("materials.lua"); S.materials = MT
local K = load("parts_kit.lua"); S.parts_kit = K
local PB = load("parts_base.lua"); S.parts_base = PB
S.kit_snap = load("kit_snap.lua")
local R = load("recipes.lua"); S.recipes = R
local BE = load("base_economy.lua"); S.base_economy = BE
local MC = load("machines.lua"); S.machines = MC
local TB = load("timber.lua"); S.timber = TB
local RL = load("rooms.lua"); S.rooms = RL
local LT = load("loot.lua"); S.loot = LT
local DM = load("damage.lua")
local RS = load("research.lua")
local defs = function(id) return PB.partInfo(id) end

-- ── the material ────────────────────────────────────────────────────────────
local W = K.MATS.wood
check(W and W.kgm3 == 550 and W.strength == 40 and W.seal == false, "timber: 550 kg/m³, strength 40, never seals")
check(W.strength < K.MATS.steel.strength / 4 + 1e-9, "a quarter of steel's strength (W2's load model reads it)")
check(K.MAT_ORDER[#K.MAT_ORDER] == "wood" and K.COSTK.wood == 0.22, "M cycles to timber last; its price 0.22 of steel")
local function m(id) return defs(id).mass * 1000 end
local function c(id) return defs(id).cost end
check(near(m("wall.wood"), 106.48, 0.01) and c("wall.wood") == 130, string.format("a timber wall 106 kg, $130 (%.0f kg, $%d)", m("wall.wood"), c("wall.wood")))
check(near(m("floor.wood"), 110, 0.01) and c("floor.wood") == 110, "a timber floor 110 kg, $110")
check(c("beam4.wood") == 80 and c("pillar2.wood") == 50 and c("roofPitch.wood") == 90 and c("stairs.wood") == 210,
  "beam4 $80, pillar2 $50, roofPitch $90, stairs $210 (the plan's prices)")
check(near(m("beam4.wood"), 176, 0.01), "a 4 m timber beam 176 kg")
check(m("stairs.wood") < 200 and m("steps.wood") < 60, "a timber stair is stringers and treads, not solid wood")
check(c("wall.wood") < c("wall.regocrete"), "timber is the cheapest wall at home")
check(defs("wall.wood").seals == nil and defs("floor.wood").seals == nil and defs("hutDoor.wood").seals == nil,
  "no timber piece seals (a hut leaks)")
check(defs("windowWall.wood") and defs("doorWallM.wood") and defs("doorWall.wood").door.slide, "the Door Wall and its variant come in timber, a pocket leaf")

-- ── the TIMBER pieces ───────────────────────────────────────────────────────
local want = { "post3", "post5", "beam6w", "trussW4", "deck24", "plankFloor", "shingleRoof", "fence", "hutDoor", "campMast", "shoring", "sawbench" }
for _, p in ipairs(want) do
  local d = defs(p .. ".wood")
  check(d and d.section == "TIMBER" and d.mat == "wood" and d.planks and d.planks > 0, p .. ": a TIMBER piece in wood, with its planks")
end
check(K.SECTION_ORDER[1] == "TIMBER" and K.EXTERIOR.TIMBER, "TIMBER first in the column, an exterior section")
local cat = K.catalogue("steel")
check(cat[1].title == "TIMBER" and #cat[1].ids == 12, "the column's first section: the twelve timber pieces")
check(near(m("post3.wood"), 117, 1) and near(m("post5.wood"), 194, 1) and near(m("beam6w.wood"), 198, 1), "log posts 117/194 kg, the 6 m beam 198 kg")
check(c("post3.wood") == 60 and c("beam6w.wood") == 120 and c("deck24.wood") == 170 and c("hutDoor.wood") == 150, "the plan's prices")
local cm = defs("campMast.wood")
check(cm.tower and cm.tower.station == false and cm.tower.radius == 150 and cm.tower.draw == 0.5 and cm.script == "base_tower",
  "the Camp Mast founds a base (base_tower), never a ground station, 0.5 EC/s")
check(cm.fit >= 350 and cm.cost == 450, "its whip antenna ($350) is paid whatever pays its wood")
local hd = defs("hutDoor.wood")
check(hd.door and hd.door.swing and hd.door.swing.deg >= 90 and hd.script == "kit_live", "the plank door is hinged (kit_live swings it)")
check(defs("shoring.wood").tech == "shoring" and defs("shoring.wood").shore and RS.TECH.shoring and RS.TECH.shoring.featGrant == "cave_kinds",
  "shoring: behind its research, granted by a cave explored; `shore` is the cave hazards' hook")
local sb = defs("sawbench.wood")
check(sb.saw and sb.power and sb.power.kind == "aux" and sb.fit >= 450, "the Sawbench: a saw, an aux load on the grid, its saw's price in its fittings")
check(defs("deck24.wood").tile == 2 and defs("shingleRoof.wood").slopeZ, "the deck tiles, the shingle roof slopes like the pitched roof")

-- ── paying ──────────────────────────────────────────────────────────────────
local wall = defs("wall.wood")
local q0 = BE.quote(wall, "WALL", "Home", "Home", 0, nil)
check(q0.mode == "money" and q0.cost == 130 and q0.ship == 63 and not q0.planks, "no planks: it ships ready-cut, $130 + shipping")
local q1 = BE.quote(wall, "WALL", "Home", "Home", 0, { planks = 50 })
check(not q1.planks and q1.cost == 130, "too few planks (50 kg of 106): still ready-cut")
local q2 = BE.quote(wall, "WALL", "Home", "Home", 0, { planks = 500 })
check(q2.mode == "money" and q2.planks == 106 and q2.cost == wall.fit and q2.ship == 0 and q2.total == 22,
  string.format("with planks: 106 kg of them + $22 fittings (%s)", tostring(q2.total)))
local l1, l2 = BE.cardLines(q2)
check(l1 == "$22" and l2:find("106 kg of your planks", 1, true), "the card says so: " .. tostring(l2))
check(BE.ledgerWhy("Wall", q2):find("warehouse's planks", 1, true), "and the ledger")
local qs = BE.quote(defs("wall.steel"), "WALL", "Home", "Home", 0, { planks = 500 })
check(not qs.planks and qs.cost == 600, "a steel wall ignores planks")
local qm = BE.quote(cm, "TIMBER", "Home", "Home", 0, { planks = 1000 })
check(qm.planks == 170 and qm.cost >= 350, "a Camp Mast with planks still pays its whip")
local away = BE.quote(wall, "WALL", "Moon", "Home", 0, { crated = 0 })
check(away.mode == "away", "off the home world the crated rule holds")
-- recipes and the Fabricator
local rw = R.recipeFor(wall, "WALL", "wall.wood")
check(#rw.mats == 1 and rw.mats[1].mat == "plank" and math.abs(rw.mats[1].kg - 106) <= 1, "a timber wall's recipe is its planks: " .. R.lineOf(rw))
local rd = R.recipeFor(hd, "TIMBER", "hutDoor.wood")
check(R.kgOf(rd, "wiring") == 0, "a hinged plank door needs no copper")
check(R.kgOf(R.recipeFor(cm, "TIMBER", "campMast.wood"), "wiring") > 0, "the Camp Mast's radio does")
check(MC.FAB_TAKES.plank and MT.isRefined("plank") and MT.REG.plank.density == 550, "planks: a refined material the Fabricator takes")

-- ── leaky: a room walled in timber ──────────────────────────────────────────
do
  local PI2 = math.pi / 2
  local function P(uid, id, x, y, z, yaw) return { uid = uid, id = id, x = x, y = y, z = z, yaw = yaw or 0, pitch = 0, roll = 0 } end
  local function box(wallId)
    return { id = 1, b = "Home", x = 0, y = 600, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1,
             bp = { P(1, "floor.steel", 0, 0, 0), P(2, wallId, 1, 0.2, 0, PI2), P(3, wallId, -1, 0.2, 0, PI2),
                    P(4, wallId, 0, 0.2, -1, 0), P(5, wallId, 0, 0.2, 1, 0), P(6, "floor.steel", 0, 2.4, 0) } }
  end
  local Rs = RL.solve(box("wall.steel"), defs)
  check(#Rs.rooms == 1 and Rs.rooms[1].sealed, "steel walls: sealed")
  local Rw = RL.solve(box("wall.wood"), defs)
  local sealed = 0
  for _, r in ipairs(Rw.rooms) do if r.sealed then sealed = sealed + 1 end end
  check(sealed == 0, string.format("timber walls under a steel roof: no sealed room (%d rooms)", #Rw.rooms))
  local Rm = RL.solve((function() local b = box("wall.steel"); b.bp[5].id = "wall.wood"; return b end)(), defs)
  check(#Rm.rooms == 0 or not Rm.rooms[1].sealed, "one timber wall in a steel room: it leaks")
  local q = RL.localQuads(defs("wall.wood"))
  check(#q == 1 and q[1].open, "a timber wall is a named leak in the flood fill")
end

-- ── the saw ─────────────────────────────────────────────────────────────────
check(near(TB.sawRate(false, false) * 60, 10) and near(TB.sawRate(false, true) * 60, 20) and near(TB.sawRate(true, false) * 60, 40),
  "by hand 10 kg a minute, an Engineer 20, on the grid 40")
check(TB.planksOf(1) == 25 and TB.planksOf(64) == 1600, "a timber saws to 25 kg: a hut's 1.6 t is 64 timber (≈ 12 trees)")
check(near(TB.sawSecs(100, false, false), 600) and near(TB.sawSecs(100, true, false), 150), "100 kg: 10 minutes by hand, 2.5 on the grid")
local cv = MC.convOf("sawbench")
check(cv and cv.timber and near(cv.timber.tot, 25) and near(cv.timber.rate * 25 * 60, 40, 1e-6), "machines: the saw's conversion, 40 kg a minute at 0.6 kW")
local job = { kg = 50, made = 0 }
local got = 0
for _ = 1, 7 do local w = TB.advance(job, 30, TB.sawRate(false, false)); got = got + w end
check(got == 35 and job.made == 35 and near(job.frac, 0, 1e-9), string.format("3.5 min by hand: 35 whole kg paid (%d)", got))
local w2, done = TB.advance(job, 1000, TB.sawRate(true, false))
check(w2 == 15 and done and job.made == 50, "it stops at its batch")
check(TB.unsawn({ kg = 125, made = 30 }) == 3 and TB.unsawn({ kg = 25, made = 25 }) == 0, "stopping gives back the whole timber not yet sawn")
local oq = TB.orderQuote(100, BE.shipping)
check(oq.cost == 60 and oq.ship == BE.shipping(60) and oq.total == 60 + BE.shipping(60), "the Depot: 100 kg of planks $60 + shipping")
check(TB.jobLine({ kg = 50, made = 10 }, false, true):find("an Engineer", 1, true), "the status line names who saws")

-- ── strip, damage, paint ────────────────────────────────────────────────────
check(LT.STRIP_MAT.wood == "plank", "a timber piece strips to planks")
local y = LT.stripYield(wall, { uid = 1, id = "wall.wood" }, function(mat) return (MT.REG[mat] or {}).kg or 1 end, false, 1.0)
check(y and y.mats and (y.mats.plank or 0) > 0 and (y.mats.plank or 0) <= 106, string.format("stripping a timber wall: %d kg of planks back", y and y.mats and y.mats.plank or -1))
check(DM.F_MAT.wood < DM.F_MAT.steel and DM.E_VOL.wood < DM.E_VOL.steel and DM.RHO.wood == 550, "the laser cuts wood faster than steel")
local KP = load("kit_paint.lua")
check(KP.BASE.wood and KP.BASE.wood[1] > 0, "kit_paint knows timber's colour (paint on it is a stain)")

if #failures > 0 then
  print(string.format("FAIL smoke_kit_wood: %d of %d", #failures, #failures + passed))
  for _, f in ipairs(failures) do print("  - " .. f) end
  os.exit(1)
end
print(string.format("smoke_kit_wood: %d checks passed", passed))
