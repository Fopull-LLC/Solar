-- SMOKE: gas engines, the Drive Chain, gas tanks, the Gas Can and the Repair
-- Bay's gas (playtest 2026-11-03c). All pure: the rulebooks loaded from disk
-- with a save stub, nothing of the engine around them.
--
--   luajit solar/tests/smoke_gas.lua
--
-- Holds:
--   * the engines (auto_drive §5): a torque curve that peaks where it says,
--     a clutch that pulls from a standstill, an automatic gearbox that pulls
--     harder low and tops out at the redline, bigger engines stronger and
--     faster, a believable burn, engine braking that grows with the rpm;
--     the chain's rear sprocket trades torque for top speed;
--   * the parts register (ROVER section), with their modules, priced in the
--     ground tier; a chain's size prices it like a member;
--   * CHAIN LINKING (builder_attach chainBetween): from the engine's sprocket
--     to the wheel's hub, the rear sprocket in line with the engine's, the
--     loop in the wheel's plane; refused along the axle; builder_proc draws a
--     chain of that length with a token collider;
--   * FUEL DRAW: a craft's tanks drain and fill together, in proportion;
--   * THE CAN: comes full; a pour draws the emptiest can first; it keeps its
--     level through a locker and the warehouse (which tops other fills up);
--     a pump fills the fullest can that has room;
--   * THE REPAIR BAY: the work order prices the gas by the litre; the pump
--     pays as each dollar's worth goes in, the cents carried, and stops when
--     the money or the room runs out;
--   * SAVE ROUND TRIP: a fleet record (electronics.packRecord) keeps a gas
--     tank's level and a chain's ends and sprockets (its size, which a fleet
--     record used to drop).

local fails, passes = {}, 0
local function check(name, ok, detail)
  if ok then passes = passes + 1
  else fails[#fails + 1] = name .. (detail and ("  (" .. tostring(detail) .. ")") or "") end
end
local function near(a, b, tol) return math.abs((a or 0) - (b or 0)) <= (tol or 1e-6) end

local store = {}
local envs = {}
local API = {
  findScript = function(k) return envs[k] end,
  findScripts = function() return {} end,
  log = function() end,
  save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
}
local function load(path, kind)
  local env = setmetatable({}, { __index = function(_, k) return API[k] or _G[k] end })
  local f = io.open("solar/" .. path) and ("solar/" .. path) or path
  local chunk = assert(loadfile(f))
  setfenv(chunk, env)
  chunk()
  env.params = {}
  for k, v in pairs(env.defaults or {}) do env.params[k] = v end
  env.valid = true
  if kind then envs[kind] = env end
  return env
end

local A = load("scripts/auto_drive.lua", "auto_drive")
local PA = load("scripts/parts_auto.lua", "parts_auto")
local PR = load("scripts/parts_registry.lua", "parts_registry")
local BA = load("scripts/builder_attach.lua", "builder_attach")
local BP = load("scripts/builder_proc.lua", "builder_proc")
local E = load("scripts/electronics.lua", "electronics")

local function gm(id)
  for _, m in ipairs(PA.PARTS[id].mods or {}) do if m.type == "gasengine" then return m end end
end

-- ── 1. the engines ──────────────────────────────────────────────────────────
local last = { kw = 0, top = 0, t0 = 0 }
for _, id in ipairs({ "gasE50", "gasE125", "gasE250", "gasE500" }) do
  local m = gm(id)
  check(id .. ": a gasengine module", m ~= nil)
  local pk = A.gasTorque(m, m.rpk)
  check(id .. ": the curve peaks at its rpk", pk >= A.gasTorque(m, m.rpk - 800) and pk >= A.gasTorque(m, m.rpk + 800), pk)
  check(id .. ": nothing past the redline (the limiter)", A.gasTorque(m, m.red + 200) == 0)
  local kw = A.gasPeak(m)
  local w0 = A.gasWheel(m, 0, 0.33)
  check(id .. ": the clutch pulls from a standstill", w0.torque > 0 and w0.rpm == m.eng and w0.gear == 1,
    string.format("%.3f kN·m at %d rpm, gear %d", w0.torque, w0.rpm, w0.gear))
  local w10, w20 = A.gasWheel(m, 0.5 * w0.top, 0.33), A.gasWheel(m, 0.9 * w0.top, 0.33)
  check(id .. ": it shifts up as it goes", w20.gear >= w10.gear and w10.gear >= 1 and w20.torque < w0.torque * 1.3)
  check(id .. ": past the top speed it pulls nothing", A.gasWheel(m, w0.top * 1.05, 0.33).torque == 0)
  check(id .. ": a bigger engine is stronger and faster", kw > last.kw and w0.top >= last.top - 0.5 and w0.torque > last.t0,
    string.format("%.1f kW, top %.1f, %.3f kN·m", kw, w0.top, w0.torque))
  last = { kw = kw, top = w0.top, t0 = w0.torque }
  -- power through the wheel never beats the crank's (the gearbox is lossy)
  local w = A.gasWheel(m, 10, 0.33)
  check(id .. ": the wheel's power is the crank's less the losses", w.torque * 10 / 0.33 <= w.kw * 1.0001,
    string.format("%.2f kW at the wheel, %.2f at the crank", w.torque * 10 / 0.33, w.kw))
  -- the burn: an idle, plus bsfc × power
  local idle = A.gasBurn(m, 0, kw, 3600)
  local full = A.gasBurn(m, 1, kw, 3600)
  check(id .. ": idles on its lph", near(idle, m.lph, 1e-9), idle)
  check(id .. ": full power burns bsfc × kW an hour", near(full - idle, kw * m.bsfc, 1e-6), full)
  check(id .. ": engine braking grows with the rpm", A.gasBrake(m, m.red, 10) > A.gasBrake(m, m.idle + 500, 10)
    and A.gasBrake(m, m.idle, 10) == 0)
end
do
  local m = gm("gasE250")
  local a, b = A.gasWheel(m, 0, 0.33, 40), A.gasWheel(m, 0, 0.33, 56)
  check("more teeth on the rear sprocket: more torque, a lower top", b.torque > a.torque and b.top < a.top,
    string.format("40T %.3f/%.1f, 56T %.3f/%.1f", a.torque, a.top, b.torque, b.top))
  check("a 250 lasts about 20–30 min flat out on a 4 L tank", A.gasHours(m, 4, 1) > 0.3 and A.gasHours(m, 4, 1) < 0.55,
    A.gasHours(m, 4, 1))
end

-- ── 2. the parts ────────────────────────────────────────────────────────────
local REG, CAT = {}, { { "ROVER", { "roverBody" } } }
PA.register(REG, CAT)
for _, id in ipairs({ "gasE50", "gasE125", "gasE250", "gasE500", "chain", "gasTankS", "gasTankM" }) do
  check(id .. " registers", REG[id] ~= nil and REG[id].prefab ~= nil and REG[id].cost <= 60)
  local listed = false
  for _, x in ipairs(CAT[1][2]) do if x == id then listed = true end end
  check(id .. " is in the ROVER section", listed)
  local f = io.open("solar/prefabs/" .. REG[id].prefab .. ".prefab.ron")
  check(id .. ": its prefab exists", f ~= nil)
  if f then f:close() end
  local fv = io.open("solar/prefabs/vis/" .. REG[id].prefab .. ".prefab.ron")
  check(id .. ": its builder (vis) prefab exists", fv ~= nil)
  if fv then fv:close() end
end
check("the tanks hold 4 and 12 L", PA.PARTS.gasTankS.mods[1].L == 4 and PA.PARTS.gasTankM.mods[1].L == 12)
do
  local z = PR.sizeOf(PA.PARTS.chain, { len = 0.8, prof = "chain" })
  check("a chain is priced by its length", z and near(z.mass, 0.0016 * 0.8, 1e-9) and z.cost == math.floor(4 * 0.8 + 6 + 0.5), z and z.cost)
end

-- ── 3. chain linking ────────────────────────────────────────────────────────
local function basis(yaw)
  local c, s = math.cos(yaw), math.sin(yaw)
  return { X = { x = c, y = 0, z = -s }, Y = { x = 0, y = 1, z = 0 }, Z = { x = s, y = 0, z = c } }
end
do
  -- a bike frame along X: the engine low in the middle, the rear wheel 0.8 m
  -- behind it, its axle across (the wheel part's +X along the craft's Z)
  local eng = { x = 0, y = 0.4, z = 0, B = basis(0) }
  local wheel = { x = -0.8, y = 0.33, z = 0, B = basis(-math.pi / 2) }
  local m = gm("gasE250")
  local sh = BA.chainBetween(eng, m, wheel, { tx = 0, hub = 0.18 })
  check("a chain from the engine to the wheel", sh ~= nil)
  if sh then
    local a, b = sh.ends.a, sh.ends.b
    check("it starts on the engine's sprocket", near(a.x, m.sx, 1e-9) and near(a.y, 0.4 + m.sy, 1e-9) and near(a.z, m.sz, 1e-9))
    check("its rear sprocket is on the hub, in line with the engine's",
      near(b.x, -0.8, 1e-9) and near(b.y, 0.33, 1e-9) and near(b.z, m.sz, 1e-9), string.format("%.3f %.3f %.3f", b.x, b.y, b.z))
    check("its carrier runs back to the wheel's mid-plane", near(math.abs(sh.size.hubx), math.abs(m.sz), 2e-3), sh.size.hubx)
    local far = BA.chainBetween(eng, m, wheel, { tx = 0, hub = 0.1 })
    check("…clamped to how far a sprocket can stand off the hub", far and near(far.ends.b.z, -0.1, 1e-9))
    local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
    check("its length is the run", near(sh.size.len, math.sqrt(dx * dx + dy * dy + dz * dz), 1e-9))
    check("its X is the wheel's axle, square to the run", math.abs(sh.B.X.z) > 0.99 and
      near(sh.B.X.x * sh.B.Y.x + sh.B.X.y * sh.B.Y.y + sh.B.X.z * sh.B.Y.z, 0, 1e-9))
    check("its middle is between the ends", near(sh.x, (a.x + b.x) / 2, 1e-9) and near(sh.y, (a.y + b.y) / 2, 1e-9))
    local rec = { def = PA.PARTS.chain, size = { len = sh.size.len, front = 13, teeth = 48 } }
    local M = BP.arraysOf(rec)
    check("builder_proc draws the chain", M and #M.indices > 300, M and #M.indices)
    local ymin, ymax = math.huge, -math.huge
    for i = 2, #M.positions, 3 do ymin = math.min(ymin, M.positions[i]); ymax = math.max(ymax, M.positions[i]) end
    check("the drawn loop ends on both sprockets", near(ymin, -sh.size.len / 2 - BP.sprocketR(13), 0.012) and
      near(ymax, sh.size.len / 2 + BP.sprocketR(48), 0.012), string.format("%.3f..%.3f", ymin, ymax))
    local hx, hy, hz = BP.collider(rec)
    check("a chain's collider is a token box (it must not knock its tyre)", hx <= 0.011 and hy <= 0.011 and hz <= 0.011)
    check("each length of chain is its own mesh", BP.keyOf(rec) ~= BP.keyOf({ def = PA.PARTS.chain, size = { len = sh.size.len + 0.02, front = 13, teeth = 48 } }))
  end
  -- along the axle there is no plane to turn in
  local w2 = { x = 0, y = 0.4 + m.sy, z = -0.9, B = basis(-math.pi / 2) }
  check("a chain along the wheel's axle is refused", BA.chainBetween(eng, m, w2, { tx = 0, hub = 0.18 }) == nil)
end

-- ── 4. fuel draw ────────────────────────────────────────────────────────────
do
  local T = { { cap = 4, left = 4 }, { cap = 12, left = 6 } }
  local got = A.gasDrawFrom(T, 5)
  check("a draw comes from every tank by what it holds", near(got, 5) and near(T[1].left, 4 - 5 * 0.4, 1e-9) and near(T[2].left, 6 - 5 * 0.6, 1e-9))
  local all = A.gasDrawFrom(T, 99)
  check("a draw past the gas aboard gets what is left", near(all, 5, 1e-9) and near(T[1].left + T[2].left, 0, 1e-9))
  check("dry tanks give nothing", A.gasDrawFrom(T, 1) == 0)
  local put = A.gasFillInto(T, 10)
  check("a fill shares by the room", near(put, 10) and near(T[1].left, 2.5, 1e-9) and near(T[2].left, 7.5, 1e-9))
  check("a fill past full stops at full", near(A.gasFillInto(T, 99), 6, 1e-9) and near(T[1].left, 4) and near(T[2].left, 12))
end

-- ── 5. the can ──────────────────────────────────────────────────────────────
local I = load("scripts/items.lua", "items")
load("scripts/materials.lua", "materials")
local inv = load("scripts/inventory.lua", "inventory")
do
  local d = I.def("gascan")
  check("the Gas Can is a holdable device with a fill in litres", d and I.holdable("gascan") and d.fill.what == "gas" and d.fill.cap == 10)
  check("it says its level in litres", select(2, I.fillText("gascan", 7.25)) == "L" and I.fillText("gascan", 7.25) == "7.2")
  inv.addItem("crew:1", "gascan", 2)
  local f = inv.fills("crew:1", "gascan")
  check("a new can comes full", #f == 2 and f[1] == 10 and f[2] == 10)
  local got = inv.drawFill("crew:1", "gascan", 3)
  f = inv.fills("crew:1", "gascan")
  table.sort(f)
  check("a pour draws one can (the emptiest first)", near(got, 3) and near(f[1], 7) and near(f[2], 10), table.concat(f, ","))
  inv.drawFill("crew:1", "gascan", 7)
  inv.drawFill("crew:1", "gascan", 1)
  f = inv.fills("crew:1", "gascan"); table.sort(f)
  check("…then the next", near(f[1], 0) and near(f[2], 9), table.concat(f, ","))
  -- a locker keeps the levels
  inv.moveItem("crew:1", "locker:1", "gascan", 2, { force = true })
  f = inv.fills("locker:1", "gascan"); table.sort(f)
  check("a locker keeps each can's level", near(f[1], 0) and near(f[2], 9), table.concat(f, ","))
  -- the warehouse tops oxygen up for free, but not petrol
  inv.moveItem("locker:1", "base", "gascan", 2, { force = true })
  f = inv.fills("base", "gascan"); table.sort(f)
  check("the warehouse keeps a can's level (petrol is bought at the pump)", near(f[1], 0) and near(f[2], 9), table.concat(f, ","))
  inv.addItem("crew:2", "o2tank", 1)
  inv.drawFill("crew:2", "o2tank", 300)
  inv.moveItem("crew:2", "base", "o2tank", 1, { force = true })
  check("…while it still tops an oxygen tank up", near(inv.fills("base", "o2tank")[1], 900))
  -- the pump fills the fullest can with room first
  inv.moveItem("base", "crew:1", "gascan", 2, { force = true })
  local put = inv.addFill("crew:1", "gascan", 3)
  f = inv.fills("crew:1", "gascan"); table.sort(f)
  check("a pump finishes the fuller can first", near(put, 3) and near(f[1], 2) and near(f[2], 10), table.concat(f, ","))
end

-- ── 6. the Repair Bay ───────────────────────────────────────────────────────
local RB = load("scripts/repair_bay.lua", "repair_bay")
do
  local q = RB.quote({ parts = {}, fuel = 0, charge = 0, gas = 2.34 }, RB.defaults)
  check("the work order prices the gas by the litre", near(q.gas, 2.3) and near(q.gasCost, 2.3 * RB.defaults.gas_price) and not q.nothing)
  local lines = RB.orderLines(q)
  local found = false
  for _, l in ipairs(lines) do if l[1]:match("^Gas") then found = true end end
  check("…on its own line", found)
  check("a full tank is nothing to do", RB.quote({ parts = {}, gas = 0.02 }, RB.defaults).nothing)
  local st = { owed = 0 }
  local paid, put = 0, 0
  for _ = 1, 600 do
    local L, pay, why = RB.pumpTick(st, 1 / 60, 10 - put, 1000, RB.defaults)
    put, paid = put + L, paid + pay
    if why then break end
  end
  check("the pump runs at its rate", near(put, math.min(10, 10 * RB.defaults.pump_rate), 1e-6), put)
  check("…and is paid by the dollar, the cents carried", near(paid + st.owed, put * RB.defaults.gas_price, 1e-6) and st.owed < 1,
    string.format("%d paid, %.2f owed", paid, st.owed))
  local L2, _, why = RB.pumpTick({ owed = 0 }, 1, 5, 0.3, RB.defaults)
  check("it stops when the money runs out", L2 <= 0.3 / RB.defaults.gas_price + 1e-9, why)
  local _, _, w3 = RB.pumpTick({ owed = 0 }, 1, 0, 100, RB.defaults)
  check("…and when the can is full", w3 == "full")
end

-- ── 7. the save round trip ─────────────────────────────────────────────────
do
  local tank = { uid = 7, id = "gasTankS", mods = PA.PARTS.gasTankS.mods, st = { gas = 2.75 } }
  local chain = { uid = 9, id = "chain", proc = "chain", size = { len = 0.83, prof = "chain", e = 4, w = 5, teeth = 52, front = 13 } }
  local pt, pc = E.packRecord(tank), E.packRecord(chain)
  check("a fleet record keeps a gas tank's level", pt.st and pt.st.gas == 2.75)
  check("a fleet record keeps a chain's ends and sprockets", pc.size and pc.size.e == 4 and pc.size.w == 5 and pc.size.teeth == 52 and pc.size.len == 0.83)
  chain.size.e = 99
  check("…as its own copy", pc.size.e == 4)
  check("a gas tank's module survives the record", E.modOf(pt, "gastank") and E.modOf(pt, "gastank").L == 4)
end

if #fails > 0 then
  print("GAS SMOKE FAILURES:")
  for _, f in ipairs(fails) do print("  ✗ " .. f) end
  print(string.format("smoke_gas: %d passed, %d FAILED", passes, #fails))
  os.exit(1)
end
print(string.format("smoke_gas: all %d checks passed", passes))
