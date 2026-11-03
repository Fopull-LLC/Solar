-- SMOKE HARNESS: ore hauls (scripts/missions.lua "ORE HAULS", kind "orehaul").
-- Runs the real missions.lua + company.lua + materials.lua + inventory.lua
-- against a stubbed engine holding a small generated system, no engine:
--
--   luajit solar/tests/smoke_haul_offworld.lua        (add -v for the pay table)
--
-- What it pins:
--  * an ore haul names the body and one of ITS ores (materials.bodyOres) that
--    the home world has none of, and its goals say so;
--  * it pays more for rarer and deeper ores, and more for farther bodies;
--  * it is only offered once the company has reached that body (or one no
--    easier to get back from), and only inside the tiers that open hauls;
--  * the delivery counts only ore MINED ON that body (materials.minedOn, the
--    ore's recorded origin), and the buyer takes it;
--  * the haul's "set foot on X" is a visit, not a flag (the old haul text and
--    latch called it a beacon and stopped the board offering the flag).

local VERBOSE = arg and arg[1] == "-v"
local T, TICK = 0.0, 1 / 60

local STAR_MU = 7.0e7
local ROSTER = { star = "Saelo", mu = STAR_MU, bodies = {
  { name = "Umunquo", kind = "canyon", parent = "Saelo",   a = 5500,  radius = 185, relief = 12, mu = 7.0 * 185 * 185, atmo = 0.7 },
  { name = "Ryethos", kind = "barren", parent = "Umunquo", a = 1110,  radius = 40,  relief = 3,  mu = 3.5 * 40 * 40,   atmo = 0 },
  { name = "Nami",    kind = "lava",   parent = "Saelo",   a = 12100, radius = 150, relief = 10, mu = 8.0 * 150 * 150, atmo = 0.6 },
  { name = "Oskal",   kind = "barren", parent = "Nami",    a = 900,   radius = 35,  relief = 2,  mu = 3.0 * 35 * 35,   atmo = 0 },
} }
local BODIES = {}
local function add_body(name, x, soi)
  for _, b in ipairs(ROSTER.bodies) do
    if b.name == name then
      BODIES[name] = { name = name, x = x, y = 0, z = 0, radius = b.radius, mu = b.mu, soi = soi }
    end
  end
end
add_body("Umunquo", 5500, 2200)
add_body("Ryethos", 5500 + 1110, 240)
add_body("Nami", -12100, 1800)
add_body("Oskal", -12100 + 900, 200)
BODIES.Saelo = { name = "Saelo", x = 0, y = 0, z = 0, radius = 700, mu = STAR_MU, soi = -1 }

local API, store, logs = {}, {}, {}
API.save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end }
function API.log(m) logs[#logs + 1] = tostring(m) end
API.print = function() end
local function dominant(x, y, z)
  local best, bs = nil, math.huge
  for _, b in pairs(BODIES) do
    local s = b.soi < 0 and math.huge or b.soi
    local d = math.sqrt((x - b.x) ^ 2 + (y - b.y) ^ 2 + (z - b.z) ^ 2)
    if d <= s and s < bs then best, bs = b.name, s end
  end
  return best
end
API.space = {
  bodies = function() local out = {} for _, b in pairs(BODIES) do out[#out + 1] = b end return out end,
  body = function(n) return BODIES[n] end,
  dominant = dominant,
  elements = function() return nil end,
}
API.assembly = { info = function() return { grounded = false, vel = { x = 0, y = 0, z = 0 } } end }
local astro = { valid = true, x = 0, y = 0, z = 0 }
local walker = { onFoot = true, valid = true }
function API.find(n) if n == "Astronaut" then return astro end end
local function put(n, body, alt)
  local b = BODIES[body]
  n.x, n.y, n.z = b.x, b.y + b.radius + (alt or 0), b.z
end

local envs = {}
local function load_script(path, kind)
  local env = setmetatable({}, { __index = function(_, k)
    if k == "time" then return T end
    return API[k] or _G[k]
  end })
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  env.params = {}
  for k, v in pairs(env.defaults or {}) do env.params[k] = v end
  env.valid = true
  envs[kind] = env
  return env
end
function API.findScript(kind)
  if kind == "planet_walker" then return walker end
  return envs[kind]
end
function API.findScripts(kind)
  if kind == "vessel_controller" then return {} end
  return envs[kind] and { envs[kind] } or {}
end

store["system.home"] = ROSTER
store["base.body"] = "Umunquo"
local GEO = { Umunquo = "verdant", Ryethos = "maria", Nami = "volcanic", Oskal = "maria" }
for i, b in ipairs(ROSTER.bodies) do
  store["world." .. b.name] = { name = b.name, kind = b.kind, radius = b.radius, relief = b.relief,
    atmo = b.atmo, seed = 100 + i * 17, geo = { type = GEO[b.name], family = b.kind, home = b.name == "Umunquo" } }
end

local co = load_script("solar/scripts/company.lua", "company")
local mats = load_script("solar/scripts/materials.lua", "materials")
local inv = load_script("solar/scripts/inventory.lua", "inventory")
local mi = load_script("solar/scripts/missions.lua", "missions")
co.start({})
mi.start({})
local MNODE = { x = 0, y = 0, z = 0 }
put(MNODE, "Umunquo", 0)
put(astro, "Umunquo", 1)
local function tick(n)
  for _ = 1, (n or 1) do
    T = T + TICK
    co.update({}, TICK)
    mi.update(MNODE, TICK)
  end
end
local function second() tick(70) end

local checks = {}
local function check(desc, ok, detail) checks[#checks + 1] = { desc = desc, ok = ok and true or false, detail = detail } end

-- ── 1. what an ore haul asks for ────────────────────────────────────────────
local home_ores = {}
for _, e in ipairs((mats.bodyOres("Umunquo"))) do home_ores[e.mat] = true end
local moon_ores = {}
for _, e in ipairs((mats.bodyOres("Ryethos"))) do moon_ores[e.mat] = true end

local s = mi.genSpec("orehaul", "Ryethos", 1)
local g1, g2 = s and s.goals[1], s and s.goals[2]
check("an ore haul is generated for the home moon", s ~= nil)
check("…for one of the moon's own ores the home world has none of",
  g2 and moon_ores[g2.mat] and not home_ores[g2.mat] and mats.ORE[g2.mat] ~= nil, g2 and g2.mat)
check("…its title names the body and the ore",
  s and s.title:find("Ryethos", 1, true) and s.title:find(mats.label(g2.mat), 1, true), s and s.title)
check("…its goals: set foot on the body, then that ore FROM it in the warehouse",
  g1.kind == "flag" and g1.body == "Ryethos" and g1.v == nil and g1.label == "Set foot on Ryethos"
  and g2.kind == "deliver" and g2.origin == "Ryethos" and g2.after == 1 and g2.consume == true
  and g2.label == string.format("%d kg of %s from Ryethos in the warehouse", g2.kg, mats.label(g2.mat)),
  g1.label .. " / " .. g2.label)
check("…and the brief says where the ore lies", s.brief:find("surface", 1, true) or s.brief:find("m down", 1, true), s.brief)
local seen_mats = {}
for seq = 1, 60 do
  local sp = mi.genSpec("orehaul", "Ryethos", seq)
  if sp then seen_mats[sp.goals[2].mat] = sp end
end
local nseen = 0
for _ in pairs(seen_mats) do nseen = nseen + 1 end
check("different rolls ask for different ores of the moon", nseen >= 2, nseen)
check("no ore haul from the home world itself", mi.genSpec("orehaul", "Umunquo", 1) == nil)
check("the old haul still asks for its own material", (function()
  local h = mi.genSpec("haul", "Ryethos", 1)
  return h == nil or (h.goals[2].origin == nil)
end)())

-- ── 2. the pay ──────────────────────────────────────────────────────────────
-- rarer and deeper: on one body, the ore with the larger factor pays more
local rows = {}
for mat, sp in pairs(seen_mats) do rows[#rows + 1] = { mat = mat, f = mi.oreHaulFactor(mat), r = sp.reward, sp = sp } end
table.sort(rows, function(a, b) return a.f < b.f end)
local mono = true
for i = 2, #rows do if rows[i].f > rows[i - 1].f + 1e-9 and rows[i].r <= rows[i - 1].r then mono = false end end
local tbl = {}
for _, r in ipairs(rows) do tbl[#tbl + 1] = string.format("%s f%.2f $%d", r.mat, r.f, r.r) end
check("rarer and deeper ores pay more (same body)", mono and #rows >= 2, table.concat(tbl, ", "))
check("the ore factor rises with rarity and with depth",
  mi.oreHaulFactor("sperrylite") > mi.oreHaulFactor("kamacite")
  and mi.oreHaulFactor("kreep") > mi.oreHaulFactor("he3")          -- same rarity, kreep lies deeper
  and mi.oreHaulFactor("ilmenite") > mi.oreHaulFactor("iron"))
check("an ore haul pays well: more than the plain haul and the landing there", (function()
  local land = mi.genSpec("land", "Ryethos", 1)
  return rows[1] and land and rows[1].r > land.reward
end)(), rows[1] and rows[1].r)
-- farther: the same ore from a moon of another planet pays more than from home's
local same, near_r, far_r = nil, nil, nil
for seq = 1, 200 do
  local a, b = mi.genSpec("orehaul", "Ryethos", seq), mi.genSpec("orehaul", "Oskal", seq)
  if a and b and a.goals[2].mat == b.goals[2].mat then same, near_r, far_r = a.goals[2].mat, a.reward, b.reward break end
end
check("the same ore from a farther body pays more", same and far_r > near_r,
  string.format("%s: Ryethos $%s, Oskal $%s", tostring(same), tostring(near_r), tostring(far_r)))
local nami = mi.genSpec("orehaul", "Nami", 1)
check("a planet with air has ores of its own too (rare earths, volcanic glass)",
  nami and not home_ores[nami.goals[2].mat], nami and nami.goals[2].mat)
if VERBOSE then
  for _, r in ipairs(rows) do print(string.format("  Ryethos %-12s f %.2f  %3d kg  $%d", r.mat, r.f, r.sp.goals[2].kg, r.r)) end
  print(string.format("  same ore %s: Ryethos $%s, Oskal $%s", tostring(same), tostring(near_r), tostring(far_r)))
end

-- ── 3. when it is offered ───────────────────────────────────────────────────
local function board_has(kind, body, rolls)
  for _ = 1, rolls or 30 do
    store["mission.board"] = {}
    second()
    for _, m in ipairs(mi.offers()) do
      if m.gen and m.kind == kind and (not body or m.body == body) then return true end
    end
  end
  return false
end
co.addRep(3, "test")
store["mission.done"] = { firstflight = true, highroad = true }
second()
check("local space open, moon not reached: no ore haul from it", not mi.reachOk("Ryethos")
  and not board_has("orehaul", nil, 30))
store["mission.gdone"] = { ["orbit:Ryethos"] = true }
check("an orbital survey of the moon reaches it", mi.reached("Ryethos") and mi.reachOk("Ryethos"))
check("…and then the board offers an ore haul from it", board_has("orehaul", "Ryethos", 40))
check("a harder trip (a moon of another planet) is not plausible yet", not mi.reachOk("Oskal"))
check("…nor is anything offered from a planet outside the open tiers", not board_has("orehaul", "Nami", 20))
store["mission.visited"] = { Umunquo = true, Oskal = true }
local d_nami, d_osk = mi.genSpec("orehaul", "Nami", 0).dv, mi.genSpec("orehaul", "Oskal", 0).dv
check("standing on Oskal reaches it; a body no harder to get back from is plausible",
  mi.reachOk("Oskal") and (mi.reachOk("Nami") == (d_nami <= d_osk * 1.10)),
  string.format("Nami %d m/s vs Oskal %d m/s, ok %s", d_nami, d_osk, tostring(mi.reachOk("Nami"))))
co.addRep(20, "test")
store["mission.done"] = { firstflight = true, highroad = true, orbit = true }
check("with the Deep field tier open, a reached far moon gets ore hauls", board_has("orehaul", "Oskal", 40))
store["mission.visited"], store["mission.gdone"] = { Umunquo = true }, {}

-- ── 4. the delivery counts the ore's origin ─────────────────────────────────
local function take(kind, body, seq)
  local sp = mi.genSpec(kind, body, seq)
  store["mission.board"] = { sp }
  check("signing " .. sp.title, mi.accept(sp.id) == true)
  return sp
end
local function paid(sp) return mi.active == nil and mi.lastPaid and mi.lastPaid.id == sp.id end
s = take("orehaul", "Ryethos", 1)
local mat, kg = s.goals[2].mat, s.goals[2].kg
local units = math.ceil(kg / mats.kg(mat)) + 1
put(astro, "Ryethos", 1)
second()
check("setting foot on the moon ticks the first goal", mi.goalLines()[1]:sub(1, 3) == "✓", mi.goalLines()[1])
check("…and is a visit, not a flag (the flag contract stays on offer)",
  not (store["mission.flags"] or {}).Ryethos and (store["mission.visited"] or {}).Ryethos)
put(astro, "Umunquo", 1)
inv.add("base", mat, units)
second()
check("the ore in the warehouse with no recorded origin doesn't count", mi.active == s.id, mi.goalLines()[2])
check("…and the line says why", mi.goalLines()[2]:find("none mined on Ryethos yet", 1, true), mi.goalLines()[2])
check("…while the depot keeps it back for the contract", mi.reserves(mat))
mats.noteOrigin(mat, "Oskal")
second()
check("ore first mined on another moon doesn't count", mi.active == s.id and mats.originOf(mat) == "Oskal", mi.goalLines()[2])
mats.noteOrigin(mat, "Ryethos")
local bal = co.balance()
second()
check("ore mined on the moon itself pays (its first origin elsewhere notwithstanding)",
  paid(s) and co.balance() == bal + s.reward, tostring(mi.active))
check("…and the buyer takes it", inv.count("base", mat) * mats.kg(mat) < kg, inv.count("base", mat))

-- a haul's set-foot no longer plants the flag: the flag is still offered there
check("a flag contract is still offered on the moon after the haul", (function()
  for _ = 1, 30 do
    store["mission.board"] = {}
    second()
    for _, m in ipairs(mi.offers()) do if m.kind == "flag" and m.body == "Ryethos" then return true end end
  end
  return false
end)())

local fails = {}
for _, c in ipairs(checks) do if not c.ok then fails[#fails + 1] = "  ✗ " .. c.desc .. (c.detail and ("   [" .. tostring(c.detail) .. "]") or "") end end
if #fails == 0 then
  print(string.format("ORE HAUL SMOKE OK — %d checks passed", #checks))
  os.exit(0)
end
print("ORE HAUL SMOKE FAILURES:")
for _, f in ipairs(fails) do print(f) end
print("\n-- script logs --")
for i = math.max(1, #logs - 20), #logs do print("  " .. logs[i]) end
os.exit(1)
