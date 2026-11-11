-- WHAT HOLLIS LEFT: Lindqvist Camp's pieces (scenarios/hollis/).
--
-- Writes the camp, AS IT WAS BUILT, as a SOLBP1 code. The scenario stamps it
-- as a ruin (start.ruins: ruins.stampAuthored) and its author's decay takes
-- the roofs, breaks the windows and knocks a shield block over; the restore
-- lots put the roofs back. Run from the folder that holds `solar`:
--
--   luajit solar/tools/gen_hollis_camp.lua          -- check and print the uids
--   luajit solar/tools/gen_hollis_camp.lua write    -- write camp.bp.txt
--
-- The frame: +X east, +Z north, +Y up, the slab deck's top at y 0.2.
--   MESS      x -1..5, z -1..3: the table and its terminal (core 1), the
--             front door south, a window west
--   WORKSHOP  x 5..9, z -1..3: the bench and its terminal (core 2), the
--             camp's main breaker on the east wall
--   BUNKS     x -1..5, z 3..7: two bunks, the Air Tank Rack; the door to the
--             mess (its seal blown); Agnes's bunk holds core 3
--   SHED      x 13..19, z -1..5: the reactor shed (its core long pulled):
--             the console, a coolant pump, the pressuriser, the shield
--             blocks along the north wall, one lying across core 4
--   OUTSIDE   the tower, the battery bank and the solar array west of the
--             hab, drums and a cable reel
local M = {}
local Q = math.pi / 2

function M.build()
  local P, U = {}, {}
  local uid = 0
  local function add(id, x, y, z, yaw, extra)
    uid = uid + 1
    local p = { uid = uid, id = id, x = x, y = y, z = z, yaw = yaw or 0, pitch = 0, roll = 0 }
    for k, v in pairs(extra or {}) do p[k] = v end
    P[#P + 1] = p
    return uid
  end
  local Y = 0.2
  local function slab(x, z) return add("slab2.concrete", x, 0, z, 0) end
  -- walls at an edge: along X at z odd (yaw 0 faces +Z), along Z at x odd (yaw Q faces +X)
  local function wx(id, x, z, out, y) return add(id, x, y or Y, z, out and 0 or math.pi, { paint = "bone" }) end
  local function wz(id, x, z, out, y) return add(id, x, y or Y, z, out and Q or -Q, { paint = "bone" }) end
  local function roof(x, z) return add("floor.steel", x, Y + 2.2, z, 0, { paint = "gunmetal" }) end

  -- ── the hab's deck ──
  for _, x in ipairs({ 0, 2, 4, 6, 8 }) do for _, z in ipairs({ 0, 2 }) do slab(x, z) end end
  for _, x in ipairs({ 0, 2, 4 }) do for _, z in ipairs({ 4, 6 }) do slab(x, z) end end
  -- ── the walls ──
  -- south face (the front): the mess's door and window, the workshop's window
  wx("wall.steel", 0, -1, false)
  U.frontDoor = wx("doorWall.steel", 2, -1, false)
  U.messWinS = wx("windowWall.steel", 4, -1, false)
  U.shopWinS = wx("windowWall.steel", 6, -1, false)
  wx("wall.steel", 8, -1, false)
  -- west face
  wz("wall.steel", -1, 0, false)
  U.messWinW = wz("windowWall.steel", -1, 2, false)
  wz("wall.steel", -1, 4, false)
  wz("wall.steel", -1, 6, false)
  -- the mess / bunk room wall, its door (the seal Agnes blew on her way out)
  wx("wall.steel", 0, 3, true)
  U.bunkDoor = wx("doorWall.steel", 2, 3, true)
  wx("wall.steel", 4, 3, true)
  -- the workshop's north wall (outside beyond), the mess / workshop wall and its door
  wx("wall.steel", 6, 3, true)
  wx("wall.steel", 8, 3, true)
  wz("wall.steel", 5, 0, true)
  U.shopDoor = wz("doorWall.steel", 5, 2, true)
  -- east face (workshop), the bunk room's east wall
  wz("wall.steel", 9, 0, true)
  wz("porthole.steel", 9, 2, true)
  wz("wall.steel", 5, 4, true)
  wz("wall.steel", 5, 6, true)
  -- the bunk room's north wall, a porthole onto the ridge
  wx("wall.steel", 0, 7, true)
  wx("porthole.steel", 2, 7, true)
  wx("wall.steel", 4, 7, true)
  -- ── the roofs (the decay takes most of them; the lots put them back) ──
  U.roofMess, U.roofShop, U.roofBunk = {}, {}, {}
  for _, x in ipairs({ 0, 2, 4 }) do for _, z in ipairs({ 0, 2 }) do U.roofMess[#U.roofMess + 1] = roof(x, z) end end
  for _, x in ipairs({ 6, 8 }) do for _, z in ipairs({ 0, 2 }) do U.roofShop[#U.roofShop + 1] = roof(x, z) end end
  for _, x in ipairs({ 0, 2, 4 }) do for _, z in ipairs({ 4, 6 }) do U.roofBunk[#U.roofBunk + 1] = roof(x, z) end end
  -- (one strip light under each roof panel the decay leaves)
  U.lightMess = add("lightFitting.steel", 0, Y + 2.2, 0, 0, { pitch = math.pi })
  U.lightShop = add("lightFitting.steel", 8, Y + 2.2, 2, 0, { pitch = math.pi })
  U.lightBunk = add("lightFitting.steel", 4, Y + 2.2, 6, 0, { pitch = math.pi })

  -- ── the mess ──
  U.messTable = add("table.steel", 2.2, Y, 1.0, 0)
  U.core1 = add("monitor.steel", 2.5, Y + 0.74, 1.12, math.pi)        -- (its screen to the south chair)
  add("coffee.steel", 1.55, Y + 0.74, 1.15, 0.3)
  U.agnesChair = add("chair.steel", 3.4, Y, 0.1, 0.7)            -- (pushed back from the table, askew)
  add("chair.steel", 1.6, Y, 1.7, math.pi)
  add("chair.steel", 3.2, Y, 1.75, math.pi + 0.4)
  add("shelf.steel", -0.55, Y, 0.4, Q)
  add("drum.steel", 4.4, Y, 2.4, 0, { paint = "oxide" })
  add("crateS.steel", 4.4, Y, 0.0, 0.3, { paint = "orange" })
  add("grimeScuff.film", 2.0, Y + 0.002, 0.4, 0)
  -- ── the workshop ──
  U.bench = add("workbench.steel", 7.2, Y, 2.52, math.pi)
  U.core2 = add("monitor.steel", 7.5, Y + 0.92, 2.6, math.pi)
  U.lamp = add("lampDesk.steel", 6.6, Y + 0.92, 2.55, math.pi)
  add("toolRack.steel", 8.9, Y + 1.45, 1.0, -Q, { pitch = Q })
  U.breaker = add("breaker63.steel", 8.9, Y + 1.25, 0.1, -Q, { pitch = Q })
  add("drum.steel", 8.3, Y, -0.4, 0, { paint = "orange" })
  add("cableReel.steel", 6.4, Y, 0.0, 0.6)
  add("grimeOil.film", 7.4, Y + 0.002, 1.2, 0.8)
  -- ── the bunk room ──
  U.bunkA = add("bunk.steel", 3.45, Y, 6.45, math.pi, { paint = "olive" })   -- Agnes's (core 3)
  U.bunkB = add("bunk.steel", 0.55, Y, 6.45, math.pi, { paint = "olive" })
  U.rack = add("airTank.steel", 4.2, Y, 3.62, 0)
  U.locker = add("crateS.steel", -0.45, Y, 4.3, 0.2, { paint = "olive" })
  add("grimeScuff.film", 2.0, Y + 0.002, 5.0, 0)

  -- ── the reactor shed ──
  for _, x in ipairs({ 14, 16, 18 }) do for _, z in ipairs({ 0, 2, 4 }) do slab(x, z) end end
  local CW = "wall.concrete"
  local function cx(id, x, z, out) return add(id, x, Y, z, out and 0 or math.pi, { paint = "gunmetal" }) end
  local function cz(id, x, z, out) return add(id, x, Y, z, out and Q or -Q, { paint = "gunmetal" }) end
  cx(CW, 14, -1, false)
  U.shedDoor = cx("doubleDoor.steel", 17, -1, false)
  for _, x in ipairs({ 14, 16, 18 }) do cx(CW, x, 5, true) end
  for _, z in ipairs({ 0, 2, 4 }) do cz(CW, 13, z, false); cz(CW, 19, z, true) end
  U.roofShed = {}
  for _, x in ipairs({ 14, 16, 18 }) do for _, z in ipairs({ 0, 2, 4 }) do U.roofShed[#U.roofShed + 1] = roof(x, z) end end
  U.console = add("reactorConsole.steel", 18.3, Y, 2.0, -Q)
  add("coolantPump.steel", 14.6, Y, 3.2, math.pi)
  add("pressuriser.steel", 14.4, Y, 0.6, 0)
  -- the shield blocks stacked along the north wall; one lies across core 4
  for k = 0, 2 do add("shieldBlock.concrete", 16.0 + k * 1.05, Y, 4.35, 0) end
  U.block = add("shieldBlock.concrete", 16.4, Y, 1.6, 0.5)
  add("drum.steel", 18.3, Y, 4.2, 0, { paint = "oxide" })
  add("grimeSoot.film", 16.4, Y + 0.002, 1.5, 0.4)

  -- ── outside: the tower, the camp's power, its clutter ──
  U.tower = add("tower", -6, 0, -2, 0)
  U.battery = add("batteryBank", -4.6, 0, 3.6, Q)
  U.array = add("solarArray", -6.5, 0, 7.5, 0)
  add("drum.steel", -2.0, 0, -2.4, 0, { paint = "oxide" })
  add("drum.steel", -2.6, 0, -1.9, 0, { paint = "orange" })
  add("cableReel.steel", 11.0, 0, -2.0, 1.0)
  add("drum.steel", 11.4, 0, 4.2, 0, { paint = "oxide" })
  -- (appended, so the uids above stay put) eleven years of weather inside:
  -- soot and leaks down the walls where the roofs went, oil on the floors,
  -- a drum on its side by the shed, crates stacked
  -- where the evacuation left them
  add("grimeLeak.film", 0.2, Y + 0.002, 1.6, 0.3)
  add("grimeSoot.film", 3.6, Y + 0.002, 2.2, 1.1)
  add("grimeOil.film", 1.2, Y + 0.002, 5.4, 2.0)
  add("grimeLeak.film", 6.8, Y + 0.002, 0.2, 0.9)
  add("grimeSoot.film", 15.4, Y + 0.002, 2.6, 2.4)
  add("grimeLeak.film", 17.6, Y + 0.002, 3.6, 0.2)
  add("crateS.steel", 8.5, Y, 1.7, 0.1, { paint = "olive" })
  add("crateS.steel", 8.48, Y + 0.45, 1.72, 0.5, { paint = "orange" })
  add("crate.steel", 11.5, 0, 0.8, 0.35, { paint = "olive" })
  add("drum.steel", 12.1, 0.3, 2.0, 1.2, { paint = "oxide", roll = Q })
  return P, U
end

-- the restore lots and the author's decay, by uid (the scenario quotes these)
function M.decay(U)
  local function cat(...) local o = {}; for _, t in ipairs({ ... }) do for _, v in ipairs(t) do o[#o + 1] = v end end return o end
  local mess = { U.roofMess[2], U.roofMess[3], U.roofMess[4], U.roofMess[5], U.roofMess[6] }   -- (west south panel kept)
  local shop = { U.roofShop[1], U.roofShop[2], U.roofShop[3] }                                  -- (north-east panel kept)
  local bunk = { U.roofBunk[1], U.roofBunk[2], U.roofBunk[3], U.roofBunk[4], U.roofBunk[5] }   -- (north-east panel kept)
  local shed = U.roofShed
  return {
    gone = cat(mess, shop, bunk, shed),
    broken = { U.messWinS, U.shopWinS, U.messWinW },
    knocked = { U.block },
    lots = { bunks = bunk, shop = shop, mess = mess, shed = shed },
  }
end

if arg and arg[0] and arg[0]:match("gen_hollis_camp%.lua$") then
  local function env(store, scripts)
    return setmetatable({ time = 5.0, save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
      findScript = function(k) return scripts[k] end, findScripts = function() return {} end, find = function() return nil end, log = function() end }, { __index = _G })
  end
  local function load_script(path, E) local f = assert(loadfile("solar/scripts/" .. path)); setfenv(f, E); f(); E.params = {}; for k, v in pairs(E.defaults or {}) do E.params[k] = v end; return E end
  local SC = {}
  SC.thermal = load_script("thermal.lua", env({}, SC))
  SC.parts_kit = load_script("parts_kit.lua", env({}, SC))
  SC.parts_base = load_script("parts_base.lua", env({}, SC))
  SC.blueprints = load_script("blueprints.lua", env({}, SC))
  local P, U = M.build()
  for _, p in ipairs(P) do assert(SC.parts_base.partInfo(p.id), "no part " .. p.id) end
  local code = SC.blueprints.encode({ name = "Lindqvist Camp", pieces = P })
  if arg[1] == "write" then
    local f = assert(io.open("solar/scenarios/hollis/camp.bp.txt", "wb")); f:write(code); f:close()
  end
  local D = M.decay(U)
  local function list(t) local o = {}; for _, v in ipairs(t) do o[#o + 1] = tostring(v) end return "{ " .. table.concat(o, ", ") .. " }" end
  print("pieces", #P, "code", #code)
  for _, k in ipairs({ "core1", "core2", "bunkA", "block", "breaker", "bunkDoor", "rack", "tower", "console", "lamp", "messTable", "agnesChair", "locker" }) do print(k, U[k]) end
  print("gone", list(D.gone)); print("broken", list(D.broken)); print("knocked", list(D.knocked))
  for _, k in ipairs({ "bunks", "shop", "mess", "shed" }) do print("lot " .. k, list(D.lots[k])) end
end

return M
