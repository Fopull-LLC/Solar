-- DUST SEASON: Tarrant Flats, the scenario's pre-built base (scenarios/dust_season/).
--
-- Writes the base's four structures as SOLBP1 codes, generated from these
-- lists so the rooms seal, the doors keep a clear walk and nothing stands in
-- another piece. Run from the folder that holds `solar` (the repo):
--
--   luajit solar/tools/gen_dust_station.lua          -- check and print the uids
--   luajit solar/tools/gen_dust_station.lua write    -- write the four .bp.txt
--
-- Each structure's frame: +X east, +Z north, +Y up; the hab's slab deck at y 0.2.
--
--   HAB "Tarrant Flats" (six rooms on one slab, single storey):
--     OPS      x -5..1,  z -3..3   the console (Desk Monitor), the HAB MAIN
--                                   breaker, life support (O2 generator, CO2
--                                   scrubber), the hub every door opens off
--     GROW     x 1..7,   z -3..3   Wren's seed trial on two benches, the grow
--                                   lamps, its one heater (HTR-1)
--     BUNKS    x -5..1,  z 3..7    two bunks
--     GALLEY   x -9..-5, z -3..3   the table, the coffee
--     STORE    x 1..5,   z 3..5    the north store: an inner door from the
--                                   grow room and the NORTH DOOR to the outside
--                                   (a plain door: its old seal is the one
--                                   that lets go in act 3); a bottle rack
--     AIRLOCK  x -3..-1, z -5..-3  out to the south, steps flush with the sill
--     outside: B-3 on the grow room's east wall, guarding the shop run
--   SHOP "Workshop" (x -3..3, z -3..1): an unpressurised steel shed 130 m
--     south-east, four fan heaters keeping the drill hydraulics and the spare
--     packs above freezing, its end of the run on a junction box
--   FIELD "South Field": twelve Solar Arrays and twelve Battery Banks
--   MAST "Mast": the Base Station Tower and its mast-head floodlights
--
-- THE GRID. The mast's 150 m reach holds the hab and the field: one lossless
-- bus. The shop is beyond it, on Beck's 2.5 mm² flex run (base_power lv2:
-- 9.6 kW rated, burns through over 12 kW), guarded at the hab end by B-3,
-- whose trip dial the scenario sets to Ir 0.4 (10.1 kW). Three of the shop's
-- heaters draw 9.2 kW with its lights; the fourth tips it over.
local M = {}
local Q = math.pi / 2
local Y = 0.2
local function r6(v) return math.floor(v * 1e4 + 0.5) / 1e4 end

local function new()
  local P, U = {}, {}
  local uid = 0
  local function add(id, x, y, z, yaw, extra)
    uid = uid + 1
    local p = { uid = uid, id = id, x = r6(x), y = r6(y), z = r6(z), yaw = yaw or 0, pitch = 0, roll = 0 }
    for k, v in pairs(extra or {}) do p[k] = v end
    P[#P + 1] = p
    return uid, p
  end
  return P, U, add
end

-- Rooms of 2 × 2 m cells (centres on even metres): the slabs, the ceilings,
-- and a wall on every cell edge that is not inside one room. `doors` names an
-- edge by "x,z" of its middle (walls stand on odd lines) → the piece there.
local function rooms(add, cells, doors, U, opts)
  opts = opts or {}
  local roomOf = {}
  local function key(x, z) return x .. "," .. z end
  for name, list in pairs(cells) do for _, c in ipairs(list) do roomOf[key(c[1], c[2])] = name end end
  local order = {}
  for name, list in pairs(cells) do for _, c in ipairs(list) do order[#order + 1] = { name, c[1], c[2] } end end
  table.sort(order, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end return a[3] < b[3] end)
  for _, o in ipairs(order) do
    if not opts.noSlab then add("slab2.concrete", o[2], 0, o[3], 0) end
    add(opts.roof or "floor.steel", o[2], Y + 2.2, o[3], 0)
  end
  local done = {}
  for _, o in ipairs(order) do
    local name, x, z = o[1], o[2], o[3]
    -- the four edges: { edge middle x, z, neighbour cell, along ("x" | "z"), the outside's side }
    for _, e in ipairs({ { x, z + 1, x, z + 2, "x", 1 }, { x, z - 1, x, z - 2, "x", -1 },
                         { x + 1, z, x + 2, z, "z", 1 }, { x - 1, z, x - 2, z, "z", -1 } }) do
      local ek = key(e[1], e[2])
      local nb = roomOf[key(e[3], e[4])]
      if nb ~= name and not done[ek] then
        done[ek] = true
        local spec = doors[ek]
        local id = (type(spec) == "table" and spec[1]) or spec or opts.wall or "wall.steel"
        if id ~= "none" then
          -- a wall along X (yaw 0 faces +Z) or along Z (yaw Q faces +X); an
          -- outside wall faces out, an inside one faces the first room's way
          local out = (nb == nil) and e[6] or e[6]
          local yaw
          if e[5] == "x" then yaw = (out > 0) and 0 or math.pi else yaw = (out > 0) and Q or -Q end
          if type(spec) == "table" and spec.yaw ~= nil then yaw = spec.yaw end
          local u = add(id, e[1], Y, e[2], yaw)
          if type(spec) == "table" and spec.name then U[spec.name] = u end
        end
      end
    end
  end
  return roomOf
end

-- ── the hab ─────────────────────────────────────────────────────────────────
function M.hab()
  local P, U, add = new()
  local cells = {
    ops    = { { -4, -2 }, { -2, -2 }, { 0, -2 }, { -4, 0 }, { -2, 0 }, { 0, 0 }, { -4, 2 }, { -2, 2 }, { 0, 2 } },
    grow   = { { 2, -2 }, { 4, -2 }, { 6, -2 }, { 2, 0 }, { 4, 0 }, { 6, 0 }, { 2, 2 }, { 4, 2 }, { 6, 2 } },
    bunks  = { { -4, 4 }, { -2, 4 }, { 0, 4 }, { -4, 6 }, { -2, 6 }, { 0, 6 } },
    galley = { { -8, -2 }, { -6, -2 }, { -8, 0 }, { -6, 0 }, { -8, 2 }, { -6, 2 } },
    store  = { { 2, 4 }, { 4, 4 } },
    lock   = { { -2, -4 } },
  }
  local doors = {
    -- ops ↔ grow: a double door (4 m, its 1.8 m opening z 0.1..1.9); the
    -- cell below it is plain wall, and the one above is the double door's
    ["1,0"] = "none", ["1,2"] = "none", ["1,-2"] = "wall.steel",
    -- (every door's yaw is given: its opening is the half of the panel away
    -- from its pocket, and the two doors of a walk line up)
    ["-2,3"] = { "doorWall.steel", name = "bunkDoor", yaw = 0 },          -- ops ↔ bunks: opening x -2.92..-2.0
    ["-5,0"] = { "doorWall.steel", name = "galleyDoor", yaw = Q },        -- ops ↔ galley: z 0..0.92
    ["2,3"] = { "doorWall.steel", name = "storeIn", yaw = 0 },            -- grow ↔ store: x 1.08..2.0
    ["2,5"] = { "doorWall.steel", name = "northDoor", yaw = 0 },          -- THE NORTH DOOR (store → outside): x 1.08..2.0
    ["-2,-3"] = { "airlockWall.steel", name = "lockIn", yaw = math.pi },  -- ops ↔ airlock: x -2.0..-1.08
    ["-2,-5"] = { "airlockWall.steel", name = "lockOut", yaw = math.pi }, -- airlock → outside (south): x -2.0..-1.08
    ["0,-3"] = "windowWall.steel",                               -- ops: the window onto the field
    ["-9,0"] = "porthole.steel",                                 -- galley
    ["7,0"] = "porthole.steel",                                  -- grow, toward the shop
    ["-4,7"] = "porthole.steel",                                 -- bunks, toward the mast
  }
  rooms(add, cells, doors, U)
  -- the double door, ops ↔ grow, on the line x = 1, middle z = 1
  U.growDoor = add("doubleDoor.steel", 1, Y, 1, Q)
  -- the airlock's steps, flush with the slab, under its opening (x -2..-1.08)
  add("steps.steel", -1.54, Y - 0.8, -5.5, math.pi)

  -- ── OPS ──
  -- the console: a table on the north wall west of the bunk door, its monitor
  U.desk = add("table.steel", -4.0, Y, 2.45, 0)
  U.console = add("monitor.steel", -4.0, Y + 0.74, 2.62, math.pi)
  add("chair.steel", -4.0, Y, 1.62, 0)
  add("lampDesk.steel", -4.62, Y + 0.74, 2.6, 0.4)
  -- the HAB MAIN, breaker 160 A, on the south wall west of the airlock
  U.main = add("breaker160.steel", -4.0, Y + 1.25, -2.9, 0, { pitch = Q })
  add("decalVolt.film", -4.0, Y + 1.85, -2.895, 0, { pitch = Q })
  -- life support: the O2 generator in the south-east corner, 0.8 m clear of
  -- the airlock's opening (x -2.0..-1.08); the scrubber on the north wall
  -- east of the bunk door, clear of the double door (z 0.1..1.9)
  U.o2gen = add("o2gen.steel", 0.15, Y, -2.6, 0)
  U.scrubber = add("scrubber.steel", 0.3, Y, 2.64, math.pi)
  add("wallScreen.steel", -4.9, Y + 1.5, -1.9, Q, { pitch = Q })
  add("grimeScuff.film", -2, Y + 0.002, 0, 0)
  for _, c in ipairs({ { -3.5, -1.0 }, { -0.5, 1.0 } }) do add("lightFitting.steel", c[1], Y + 2.2, c[2], 0, { pitch = math.pi }) end

  -- ── GROW (Wren's) ──
  -- the trial: two benches on the south wall, three trays (pots) on each
  U.bench1 = add("workbench.steel", 2.85, Y, -2.5, 0)
  U.bench2 = add("workbench.steel", 5.25, Y, -2.5, 0)
  U.trays = {}
  for _, bx in ipairs({ 2.85, 5.25 }) do
    for _, dx in ipairs({ -0.6, 0.0, 0.6 }) do U.trays[#U.trays + 1] = add("plant.steel", bx + dx, Y + 0.92, -2.4, 0) end
  end
  -- two more on the floor in the north-east corner, out of the store's walk
  add("plant.steel", 5.45, Y, 2.5, 0)
  add("plant.steel", 6.3, Y, 2.5, 0)
  -- HTR-1: the grow room's heater, under the east porthole's south side
  U.growHeater = add("heater.steel", 6.55, Y, -0.9, -Q)
  -- the grow lamps
  add("lampFloor.steel", 6.35, Y, 1.25, -2.4)
  add("lampFloor.steel", 1.65, Y, -1.35, 0.8)
  for _, c in ipairs({ { 3, -1 }, { 5, 1 } }) do add("lightFitting.steel", c[1], Y + 2.2, c[2], 0, { pitch = math.pi }) end
  add("grimeScuff.film", 4, Y + 0.002, 0, 1.2)

  -- ── BUNKS ──
  U.bunk1 = add("bunk.steel", -3.85, Y, 6.45, math.pi)     -- Wren's (the pillow end west)
  U.bunk2 = add("bunk.steel", -0.13, Y, 6.45, 0)           -- Imre's
  add("crateS.steel", -1.95, Y, 6.6, 0.2)
  add("lightFitting.steel", -2, Y + 2.2, 5, 0, { pitch = math.pi })

  -- ── GALLEY ──
  U.table = add("table.steel", -7.0, Y, -2.3, 0)
  add("chair.steel", -7.45, Y, -1.5, math.pi)
  add("chair.steel", -6.55, Y, -1.5, math.pi)
  add("coffee.steel", -6.5, Y + 0.74, -2.45, 0)
  add("shelf.steel", -8.66, Y, 1.8, Q)
  add("lightFitting.steel", -7, Y + 2.2, 0, 0, { pitch = math.pi })

  -- ── STORE (north) ──
  U.airTank = add("airTank.steel", 4.6, Y, 4.0, -Q)
  add("crateS.steel", 3.55, Y, 4.5, 0.15)
  add("toolRack.steel", 3.6, Y + 1.45, 3.1, 0, { pitch = Q })
  add("lightFitting.steel", 3, Y + 2.2, 4, 0, { pitch = math.pi })

  -- ── outside ──
  -- B-3, the shop run's breaker, on the grow room's east wall (outside face)
  U.b3 = add("breaker63.steel", 7.1, Y + 1.25, -2.0, Q, { pitch = Q })
  add("decalVolt.film", 7.105, Y + 1.85, -2.0, Q, { pitch = Q })
  add("decalAirlock.film", -2.0, Y + 2.3, -5.105, math.pi, { pitch = Q })
  add("lampFloor.steel", -3.4, 0, -6.4, 2.8)              -- a work light by the airlock steps
  add("grimeStreaks.film", 4.0, Y + 1.0, -3.105, math.pi, { pitch = Q })
  add("grimeStreaks.film", 7.105, Y + 1.0, 2.0, Q, { pitch = Q })
  add("drum.steel", -6.8, 0, -3.8, 0)
  add("crate.steel", -8.0, 0, 4.0, 0.2)
  -- (appended: the uids above stay put) a base lived in through a dust
  -- season: boot traffic and red dust tracked in from the airlock, oil under
  -- the life support, rust weeping under the porthole seals, scuffs by the bunks
  add("grimeScuff.film", -2, Y + 0.002, -2, 0.3)
  add("grimeScuff.film", -6.8, Y + 0.002, 0.4, 1.9)
  add("grimeScuff.film", -2.0, Y + 0.002, 4.6, 0.8)
  add("grimeScuff.film", 2.0, Y + 0.002, 4.0, 2.4)
  add("grimeOil.film", 0.4, Y + 0.002, -1.8, 0.6)
  add("grimeLeak.film", 6.895, Y + 1.0, 0.75, -Q, { pitch = Q })
  add("grimeLeak.film", -8.895, Y + 1.0, -0.7, Q, { pitch = Q })
  add("grimeStreaks.film", -2.0, Y + 1.0, -5.105, math.pi, { pitch = Q })
  add("grimeStreaks.film", 2.0, Y + 1.0, 5.105, 0, { pitch = Q })
  return P, U
end

-- ── the shop ────────────────────────────────────────────────────────────────
function M.shop()
  local P, U, add = new()
  local cells = { shop = { { -2, -2 }, { 0, -2 }, { 2, -2 }, { -2, 0 }, { 0, 0 }, { 2, 0 } } }
  local doors = { ["0,1"] = { "openFrame.steel", name = "front" } }    -- the open front, north
  rooms(add, cells, doors, U)
  -- four fan heaters: two on the south wall, two on the east wall
  U.heaters = {}
  U.heaters[1] = add("heater.steel", -1.0, Y, -2.66, 0)
  U.heaters[2] = add("heater.steel", 1.0, Y, -2.66, 0)
  U.heaters[3] = add("heater.steel", 2.66, Y, -1.6, -Q)
  U.heaters[4] = add("heater.steel", 2.66, Y, -0.35, -Q)  -- (the thermostat's last stage: off at the start)
  add("workbench.steel", -2.5, Y, -1.0, Q)
  add("shelf.steel", 2.0, Y, 0.66, math.pi)
  add("crate.steel", -2.2, Y, -2.45, 0)
  add("drum.steel", -2.45, Y, 0.5, 0)
  add("drum.steel", 0.0, Y, -2.5, 0)
  add("lampFloor.steel", -1.55, Y, 0.35, -0.6)
  for _, c in ipairs({ { -1, -1 }, { 1, -1 } }) do add("lightFitting.steel", c[1], Y + 2.2, c[2], 0, { pitch = math.pi }) end
  add("grimeOil.film", 0.5, Y + 0.002, -1.2, 0.7)
  -- the run's end: a junction box outside the north wall, west of the front
  U.jb = add("junctionBox.steel", -2.0, 0, 1.45, 0)
  add("decalVolt.film", -2.0, 0.85, 1.655, 0, { pitch = Q })
  return P, U
end

-- ── the field ───────────────────────────────────────────────────────────────
function M.field()
  local P, U, add = new()
  U.arrays, U.banks = {}, {}
  for r = 0, 2 do
    for c = 0, 3 do U.arrays[#U.arrays + 1] = add("solarArray", -6 + 4 * c, 0, -5 * r, 0) end
  end
  for r = 0, 1 do
    for c = 0, 5 do U.banks[#U.banks + 1] = add("batteryBank", -7.5 + 3.0 * c, 0, -16 - 3.0 * r, 0) end
  end
  return P, U
end

-- ── the mast ────────────────────────────────────────────────────────────────
function M.mast()
  local P, U, add = new()
  U.tower = add("tower", 0, 0, 0, 0)
  -- the mast-head floodlights: what Beck drives home by
  U.lamps = {}
  U.lamps[1] = add("lightFitting.steel", 0.0, 12.9, 0.95, 0, { pitch = math.pi })
  U.lamps[2] = add("lightFitting.steel", 0.0, 12.9, -0.95, math.pi, { pitch = math.pi })
  return P, U
end

M.NAMES = { hab = "Tarrant Flats", shop = "Workshop", field = "South Field", mast = "Mast" }

-- ── run: check, print, write ────────────────────────────────────────────────
if arg and arg[0] and arg[0]:match("gen_dust_station%.lua$") then
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
  local defs = function(id) return SC.parts_base.partInfo(id) end
  for _, k in ipairs({ "hab", "shop", "field", "mast" }) do
    local P, U = M[k]()
    for _, p in ipairs(P) do assert(defs(p.id), "no def " .. p.id) end
    local code = SC.blueprints.encode({ name = M.NAMES[k], pieces = P })
    if arg[1] == "write" then
      local f = assert(io.open("solar/scenarios/dust_season/" .. k .. ".bp.txt", "wb")); f:write(code); f:close()
    end
    local names = {}
    for n, v in pairs(U) do if type(v) == "number" then names[#names + 1] = n .. "=" .. v elseif type(v) == "table" then names[#names + 1] = n .. "=" .. table.concat(v, "/") end end
    table.sort(names)
    print(k, #P .. " pieces", #code .. " chars", table.concat(names, " "))
  end
end

return M
