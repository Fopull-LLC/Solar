-- SMOKE: the Dust Season scenario's base (scenarios/dust_season/,
-- tools/gen_dust_station.lua), against the real rooms.lua, blueprints.lua,
-- base_power.lua and the kit:
--   * the four .bp.txt are the generator's output (regenerate if this fails)
--   * the hab's six rooms: five sealed, one an airlock; the shop open
--   * nothing stands in anything else: every prop's and machine's box clear of
--     the walls and of each other (5 mm), and every door's walk clear for 1 m
--     each side of its opening
--   * the electrics the story turns on: the shop run's three heaters under the
--     2.5 mm² flex's rating, the fourth past B-3's dial (Ir 0.4) and past the
--     flex's burn; the hab's load under the battery's hour
--
--   * base_power.eventsIn: B-3 trips at its dial; taped, the flex burns under it
--   * the framework pieces the scenario added: room_air `breathable = false`,
--     power_read `burnt`, start.cables validation
--
--   luajit solar/tests/smoke_dust_season.lua
local failures, passed = {}, 0
local function check(ok, msg) if ok then passed = passed + 1 else failures[#failures + 1] = msg end return ok end
local function env(store, scripts)
  return setmetatable({ time = 5.0, save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
    findScript = function(k) return scripts[k] end, findScripts = function() return {} end, find = function() return nil end, log = function() end }, { __index = _G })
end
local function load_script(path, E) local f = assert(loadfile("solar/scripts/" .. path)); setfenv(f, E); f(); E.params = {}; for k, v in pairs(E.defaults or {}) do E.params[k] = v end; return E end
local SC = {}
SC.thermal = load_script("thermal.lua", env({}, SC))
SC.parts_kit = load_script("parts_kit.lua", env({}, SC))
SC.parts_base = load_script("parts_base.lua", env({}, SC))
SC.rooms = load_script("rooms.lua", env({}, SC))
SC.blueprints = load_script("blueprints.lua", env({}, SC))
SC.base_power = load_script("base_power.lua", env({}, SC))
local defs = function(id) return SC.parts_base.partInfo(id) end
local G = dofile("solar/tools/gen_dust_station.lua")
local B = {}
for _, k in ipairs({ "hab", "shop", "field", "mast" }) do
  local P, U = G[k]()
  B[k] = { P = P, U = U }
  local f = io.open("solar/scenarios/dust_season/" .. k .. ".bp.txt", "rb")
  local code = f and f:read("*a") or ""
  if f then f:close() end
  local bp = SC.blueprints.decode(code)
  check(bp ~= nil and SC.blueprints.same(bp, { pieces = P }), k .. ".bp.txt is the generator's output (" .. tostring(bp and bp.n) .. " vs " .. #P .. " pieces)")
  for _, p in ipairs(P) do if not defs(p.id) then check(false, k .. ": no part " .. p.id) end end
end
local H, S = B.hab, B.shop
-- the uids the scenario names
check(H.U.b3 == 150 and H.U.growHeater == 130 and H.U.northDoor == 96 and H.U.storeIn == 95 and H.U.console == 109 and H.U.main == 112,
  string.format("the scenario's hab uids: B-3 %s HTR-1 %s north door %s store door %s console %s main %s",
    H.U.b3, H.U.growHeater, H.U.northDoor, H.U.storeIn, H.U.console, H.U.main))
check(S.U.heaters[4] == 26 and S.U.jb == 36, string.format("the shop's: HTR-4 %s, the junction box %s", S.U.heaters[4], S.U.jb))

-- ── the rooms ──
local function solve(P) return SC.rooms.solve({ id = 7, b = "Home", x = 0, y = 600, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1, bp = P, st = {} }, defs, os.clock) end
do
  local Rm = solve(H.P)
  local sealed, lock = 0, 0
  for _, r in ipairs(Rm.rooms) do
    if r.sealed then sealed = sealed + 1 end
    if r.airlock then lock = lock + 1 end
  end
  check(sealed == 6 and lock == 1, string.format("the hab: six sealed rooms, one an airlock (%d sealed, %d airlocks, %d rooms)", sealed, lock, #Rm.rooms))
  local Rs = solve(S.P)
  local ss = 0
  for _, r in ipairs(Rs.rooms) do if r.sealed then ss = ss + 1 end end
  check(ss == 0, "the shop is open to the weather (" .. ss .. " sealed)")
end

-- ── nothing in anything ──
local function rot(x, z, th) local c, s = math.cos(th), math.sin(th); return x * c + z * s, -x * s + z * c end
local function aabb(p)
  local d = defs(p.id)
  local b = d and d.box
  if not b then return nil end
  local x0, x1, y0, y1, z0, z1 = b[1] or b.x0, b[2] or b.x1, b[3] or b.y0, b[4] or b.y1, b[5] or b.z0, b[6] or b.z1
  local lo, hi = { math.huge, p.y + y0, math.huge }, { -math.huge, p.y + y1, -math.huge }
  for _, cx in ipairs({ x0, x1 }) do for _, cz in ipairs({ z0, z1 }) do
    local wx, wz = rot(cx, cz, p.yaw or 0)
    lo[1], hi[1] = math.min(lo[1], p.x + wx), math.max(hi[1], p.x + wx)
    lo[3], hi[3] = math.min(lo[3], p.z + wz), math.max(hi[3], p.z + wz)
  end end
  return lo, hi, d
end
local SKIP = { slab2 = true, floor = true, steps = true }
local function kind(p, d)
  local base = p.id:match("^([^.]+)")
  if SKIP[base] or (p.pitch or 0) ~= 0 or p.id:match("%.film$") then return nil end
  if d.snap == "wall" then return "wall" end
  return "prop"
end
local function overlaps(P, name)
  local L = {}
  for _, p in ipairs(P) do
    local lo, hi, d = aabb(p)
    if lo then local k = kind(p, d); if k then L[#L + 1] = { p = p, lo = lo, hi = hi, k = k } end end
  end
  local bad = {}
  local e = 0.005
  for i = 1, #L do for j = i + 1, #L do
    local a, b = L[i], L[j]
    if not (a.k == "wall" and b.k == "wall") then
      local hit = true
      for ax = 1, 3 do if a.hi[ax] <= b.lo[ax] + e or b.hi[ax] <= a.lo[ax] + e then hit = false end end
      -- (a prop on a table or a bench: it stands on it)
      if hit and (math.abs(a.lo[2] - b.hi[2]) < 0.03 or math.abs(b.lo[2] - a.hi[2]) < 0.03) then hit = false end
      -- (a tray on a bench's top: raised 0.7 m or more over the other's foot)
      if hit and a.k == "prop" and b.k == "prop" and math.abs(a.lo[2] - b.lo[2]) >= 0.7 then hit = false end
      if hit then bad[#bad + 1] = string.format("%s %d × %s %d", a.p.id, a.p.uid, b.p.id, b.p.uid) end
    end
  end end
  check(#bad == 0, name .. ": nothing stands in anything (" .. #bad .. ": " .. table.concat(bad, "; ", 1, math.min(#bad, 6)) .. ")")
end
overlaps(H.P, "the hab")
overlaps(S.P, "the shop")
-- every doorway's walk: 1 m out each side of the middle of its opening, 0.3 m
-- either side of that line, free of every prop between the knee and the head
local function walks(P, name)
  local props = {}
  for _, p in ipairs(P) do
    local lo, hi, d = aabb(p)
    if lo and kind(p, d) == "prop" then props[#props + 1] = { p = p, lo = lo, hi = hi } end
  end
  local bad = {}
  for _, p in ipairs(P) do
    local d = defs(p.id)
    local base = p.id:match("^([^.]+)")
    if d and (d.door or base == "openFrame") then
      local mid = 0
      if d.door and not d.door.pair then local sl = d.door.slide and d.door.slide[1] or 0.92; mid = (sl > 0) and -sl / 2 or -sl / 2 end
      for _, n in ipairs({ -1.0, -0.6, -0.3, 0.3, 0.6, 1.0 }) do
        for _, a in ipairs({ -0.3, 0, 0.3 }) do
          local wx, wz = rot(mid + a, n, p.yaw or 0)
          local x, z = p.x + wx, p.z + wz
          for _, q in ipairs(props) do
            if x > q.lo[1] and x < q.hi[1] and z > q.lo[3] and z < q.hi[3] and q.hi[2] > p.y + 0.3 and q.lo[2] < p.y + 1.7 then
              bad[#bad + 1] = string.format("%s %d blocked by %s %d", p.id, p.uid, q.p.id, q.p.uid)
            end
          end
        end
      end
    end
  end
  check(#bad == 0, name .. ": every doorway's walk is clear (" .. #bad .. ": " .. table.concat(bad, "; ", 1, math.min(#bad, 4)) .. ")")
end
walks(H.P, "the hab")
walks(S.P, "the shop")

-- ── the electrics ──
local function use(id) local d = defs(id); return d and d.power and d.power.use or 0 end
local shop3, shopAll = 0, 0
for _, p in ipairs(S.P) do
  local d = defs(p.id)
  if d.power and d.power.kind == "load" then
    shopAll = shopAll + d.power.use
    if p.uid ~= S.U.heaters[4] then shop3 = shop3 + d.power.use end
  end
end
local BP = SC.base_power
local cap = BP.capacityKW("lv2")
local b3 = BP.breakerKW(defs("breaker63.steel").power) * 0.4
check(math.abs(cap - 9.6) < 1e-9 and BP.CABLES.lv2.flex, string.format("the flex run: 2.5 mm², %.1f kW rated, burns over %.1f kW", cap, cap * BP.BURN))
check(shop3 < cap and shop3 > 0.9 * cap, string.format("three heaters and the lights: %.2f kW, %d %% of the flex", shop3, math.floor(100 * shop3 / cap + 0.5)))
check(shop3 < b3 and shopAll > b3, string.format("B-3 at Ir 0.4 (%.2f kW) holds three heaters and trips on the fourth (%.2f kW)", b3, shopAll))
check(shopAll > cap * BP.BURN, string.format("taped, the fourth burns the flex (%.2f kW over %.2f)", shopAll, cap * BP.BURN))
-- base_power.eventsIn: B-3 at its dial trips first; taped (Ir 1, 25.2 kW) the flex burns under it
do
  local net = { edges = { { id = 1, guard = { { key = "1:150", kW = b3 } } } }, cap = { cap } }
  local ev = BP.eventsIn(net, { P = { shopAll } }) or {}
  check(#ev == 1 and ev[1].kind == "trip", string.format("the fourth heater at Ir 0.4: B-3 trips (%s)", ev[1] and ev[1].kind or "nothing"))
  net.edges[1].guard[1].kW = BP.breakerKW(defs("breaker63.steel").power)
  ev = BP.eventsIn(net, { P = { shopAll } }) or {}
  check(#ev == 1 and ev[1].kind == "burn", string.format("taped to Ir 1: nothing trips and the flex burns (%s)", ev[1] and ev[1].kind or "nothing"))
  ev = BP.eventsIn(net, { P = { shop3 } }) or {}
  check(#ev == 0, "three heaters, taped or not: nothing happens")
end
local hab = 0
for _, p in ipairs(H.P) do local d = defs(p.id); if d.power and d.power.kind == "load" then hab = hab + d.power.use end end
check(hab > 4 and hab < 7, string.format("the hab draws %.2f kW (life support, HTR-1, the lights)", hab))
check(hab + 2.5 < b3 + 10, "…and an airlock cycle on top")
local banks, arrays = 0, 0
for _, p in ipairs(B.field.P) do if p.id == "batteryBank" then banks = banks + 1 elseif p.id == "solarArray" then arrays = arrays + 1 end end
check(banks == 12 and arrays == 12, string.format("the field: %d arrays, %d banks (%.1f kWh)", arrays, banks, banks * 4000 / 3600))

-- ── the framework pieces the scenario added (scenario.lua, pure) ──
do
  local R = load_script("scenario.lua", env({}, {}))
  local rooms = { { id = 1, sealed = true, airlock = false, m3 = 80 } }
  local air = { breathable = true }
  local W = { structId = function() return 7 end, rooms = function() return rooms end, roomAir = function() return air end,
              grid = function() return { cap = 100, stored = 50, need = 5, supply = 1, powered = true } end,
              cableBurnt = function() return true end, breaker = function() return "closed" end }
  local function ev(g) return R.evalGoal(g, W, {}, { now = 0 }) end
  -- (sid_of reads W.structSid or W.sidOf: try both shapes)
  -- (sid_of asks W.structId)
  local okA = ev({ kind = "room_air", struct = "X", room = "largest", breathable = false })
  air.breathable = false
  local okB = ev({ kind = "room_air", struct = "X", room = "largest", breathable = false })
  check(okA == false and okB == true, "room_air breathable = false reads the air (was always met)")
  local okC = ev({ kind = "power_read", struct = "X", burnt = true })
  local okD = ev({ kind = "power_read", struct = "X", burnt = false })
  check(okC == true and okD == false, "power_read burnt reads the structure's cables")
  local sc = { id = "x", title = "x", start = { structures = { { bp = "x/a.bp.txt", name = "A" } },
    cables = { { from = { struct = "A", uid = 1 }, to = { struct = "B", uid = 2 }, ty = "lv7" } } }, steps = { { id = "s", text = "t", goals = { { kind = "var", name = "v", is = true } } } } }
  local ok, errs = R.validate(sc, {})
  local msg = table.concat(errs or {}, " | ")
  check(not ok and msg:find("start.cables[1].to.struct", 1, true) and msg:find("start.cables[1].ty", 1, true), "start.cables validated: " .. msg:sub(1, 160))
end

print(string.format("smoke_dust_season: %d passed, %d failed", passed, #failures))
for _, f in ipairs(failures) do print("  FAIL " .. f) end
os.exit(#failures == 0 and 0 or 1)
