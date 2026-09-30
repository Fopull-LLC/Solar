-- SMOKE HARNESS for inventory_panel.lua — the suit pack, and where its contents
-- can go from here.
--
-- The panel was eight fixed row nodes with a script each until it became one
-- described screen, so what this harness is really guarding is the thing that
-- change bought and the things it could have broken:
--
--   * a NINTH material appears. The old panel could not show one — there were
--     eight row nodes and that was the whole list. This is the regression test
--     for the reason the rewrite happened.
--   * a closed panel does NO work: no target search, no screen described. It
--     ran `find_target` every frame regardless before.
--   * a transfer that doesn't fit says so, and does not destroy the remainder.
--   * a craft in reach beats the depot, because you walked to the ship for a
--     reason — and reach is measured through `distanceTo`, so a planet-parented
--     depot is compared in the right frame.
--   * loading a craft re-applies its mass, or the ship you just filled still
--     flies empty.
--
--   luajit solar/tests/smoke_inventory.lua

local checks = 0
local function ok(cond, msg)
  checks = checks + 1
  if not cond then
    io.write("\xe2\x9c\x97 CHECK FAILED: " .. msg .. "\n")
    os.exit(1)
  end
end

_G.time = 0.0

-- ── the world ───────────────────────────────────────────────────────────────
-- The two frames the real scene has: the depot is planet-parented (its coords
-- are body-relative), the astronaut is top-level (world). A panel that compared
-- them raw would be wrong by the planet's orbital position — which is why the
-- node handles carry `distanceTo` and the panel uses it.
local planet = { name = "Ryilex", x = 4800, y = 0, z = -1200, radius = 214 }
local planet_node = { name = planet.name, x = planet.x, y = planet.y, z = planet.z }

local nodes = {}
local function world_of(n)
  local x, y, z, p, guard = n.x, n.y, n.z, n.parent, 0
  while p and guard < 8 do x, y, z = x + p.x, y + p.y, z + p.z; p, guard = p.parent, guard + 1 end
  return x, y, z
end
local function add(n)
  n.valid = true
  function n:distanceTo(other)
    local ax, ay, az = world_of(self)
    local bx, by, bz = world_of(other)
    return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2 + (az - bz) ^ 2)
  end
  nodes[n.name] = n
  return n
end

add(planet_node)
local astro = add({ name = "Astronaut", visible = true,
  x = planet.x, y = planet.y + planet.radius, z = planet.z })
-- The depot, body-relative, 8 m from the crew in world space.
add({ name = "FacDepot", parent = planet_node, x = 8, y = planet.radius, z = 0 })

local panel = add({ name = "Inventory Panel", __el = { visible = false },
  getcomponent = function(self) return self.__el end })

_G.find = function(n) return nodes[n] end
local KEYS = {}
_G.input = {
  pressed = function(k) return KEYS[k] == true end,
  setMouseLocked = function() end,
}
_G.log = function() end
-- The scripts under test print diagnostics; the harness keeps its own channel
-- so a passing run says so and a failing one says why.
local report = print
_G.print = function() end

-- ── the scripts it reads ────────────────────────────────────────────────────
local walker = { onFoot = true }
local NAMES = { ore = "Iron Ore", ice = "Water Ice", crys = "Resonant Crystal",
                salt = "Halite", cu = "Copper Ore", ni = "Nickel", si = "Silica",
                ti = "Titanium", au = "Native Gold" }
local TIERS = { crys = 3, au = 3, ti = 2, ni = 2 }
local mats = {
  -- `label`, not `name`: a script handle's `.name` is reserved by the engine.
  label = function(m) return NAMES[m] or m end,
  tier = function(m) return TIERS[m] or 1 end,
}
local co = { money = function(v) return "$" .. tostring(math.floor(v or 0)) end }
local climate = { surveyLine = function() return "temperate shelf" end }

-- A pack of stacks, in registry order.
local pack = {}
local moved_log = {}
local hold_full = false
local inv = {
  items = function(_) return pack end,
  isEmpty = function(_) return #pack == 0 end,
  mass = function(_)
    local m = 0
    for _, e in ipairs(pack) do m = m + e.kg end
    return m
  end,
  totalValue = function(_)
    local v = 0
    for _, e in ipairs(pack) do v = v + e.value end
    return v
  end,
  line = function(_) return "12.0 / 90.0 kg" end,
  count = function(_, mat)
    for _, e in ipairs(pack) do if e.mat == mat then return e.n end end
    return 0
  end,
}
-- A transfer moves nothing when the hold is full, and never destroys the rest.
function inv.transfer(_, dst, mat, n)
  if hold_full then return 0 end
  for i, e in ipairs(pack) do
    if e.mat == mat then table.remove(pack, i) break end
  end
  moved_log[#moved_log + 1] = { dst = dst, mat = mat, n = n }
  return n
end
function inv.transferAll(_, dst)
  if hold_full then return 0 end
  local n = 0
  for _, e in ipairs(pack) do n = n + e.n end
  pack = {}
  moved_log[#moved_log + 1] = { dst = dst, mat = "*", n = n }
  return n
end

-- A craft with a hold, near or far. `massApplied` is the thing a transfer must
-- not forget: a ship you just loaded has to fly like a loaded ship.
local craft_node = add({ name = "Lander", x = astro.x + 200, y = astro.y, z = astro.z })
local mass_applied = 0
local craft = { piloting = false, node = craft_node, holdId = "hold1",
                craftName = "Lander",
                holdApplyMass = function() mass_applied = mass_applied + 1 end }
local fleet = { craft }

local refs = { planet_walker = walker, inventory = inv, materials = mats,
               company = co, climate = climate }
_G.findScript = function(kind) return refs[kind] end
_G.findScripts = function(kind) return kind == "vessel_controller" and fleet or {} end

-- What the panel last described.
local drawn = nil
_G.ui = { make = function(_, tree) drawn = tree end }

-- Walk the described tree and collect every text run, and every button.
local function walk(el, texts, buttons)
  if type(el) ~= "table" then return end
  if el.text then texts[#texts + 1] = el.text end
  if el[1] == "button" then buttons[#buttons + 1] = el end
  local list = el.items
  local fn
  for _, v in ipairs(el) do if type(v) == "function" then fn = v end end
  if list and fn then
    for i, item in ipairs(list) do walk(fn(item, i), texts, buttons) end
  end
  for _, v in ipairs(el) do if type(v) == "table" then walk(v, texts, buttons) end end
end
-- What a button reads as: its own text, or its cells' joined (a stack row is
-- a row of cells — count, name, mass, value).
local function label(b)
  local t = {}
  walk(b, t, {})
  return table.concat(t, " ")
end
local function screen()
  local texts, buttons = {}, {}
  walk(drawn, texts, buttons)
  for _, b in ipairs(buttons) do b.text = b.text or label(b) end
  return texts, buttons
end
local function says(needle)
  local texts = screen()
  for _, l in ipairs(texts) do if l:find(needle, 1, true) then return true end end
  return false
end

-- ── load ────────────────────────────────────────────────────────────────────
local chunk = assert(loadfile("solar/scripts/inventory_panel.lua"))
chunk()
_G.params = { reach = 11.0 }
start(panel)
ok(panel.__el.visible == false, "the panel starts closed")

local function tick(n)
  for _ = 1, (n or 1) do
    _G.time = _G.time + 1 / 60
    update(panel, 1 / 60)
    for k in pairs(KEYS) do KEYS[k] = nil end
  end
end
local function press(k) KEYS[k] = true end

-- 1. A CLOSED PANEL COSTS NOTHING. It describes no screen and looks for no
-- transfer target — the old one ran the whole target search every frame.
drawn = nil
tick(3)
ok(drawn == nil, "a closed panel describes nothing")
ok(_G.open == false, "…and reports itself closed")

-- 2. I OPENS IT.
press("i"); tick(1)
ok(_G.open == true, "I opens the pack")
ok(panel.__el.visible == true, "…and the frame becomes visible")

-- 3. AN EMPTY PACK SAYS SO, and says what to do about it.
ok(says("nothing in the pack"), "an empty pack says it is empty")
ok(says("mine rock"), "…and points at the tools that fill it")

-- 4. NINE MATERIALS ALL APPEAR. This is the whole reason for the rewrite: the
-- panel it replaced had eight row nodes, so a ninth stack was invisible.
for i, m in ipairs({ "ore", "ice", "crys", "salt", "cu", "ni", "si", "ti", "au" }) do
  pack[i] = { mat = m, n = i * 2, kg = i * 1.5, value = i * 40 }
end
tick(1)
local _, buttons = screen()
local rows = 0
for _, b in ipairs(buttons) do if b.style == "panel/row" then rows = rows + 1 end end
ok(rows == 9, "all nine stacks get a row (the old panel capped at 8) — got " .. rows)
ok(says("Resonant Crystal"), "a stack names its material")
ok(says("Native Gold"), "…including the ninth one")

-- 5. TIER TINTS THE ROW, and it is set on the element rather than in the
-- stylesheet — a style that named text_color would overwrite it every frame.
local gold, common
for _, b in ipairs(buttons) do
  if b.text:find("Native Gold", 1, true) then gold = b end
  if b.text:find("Halite", 1, true) then common = b end
end
ok(gold and gold.textR > 0.9 and gold.textG > 0.8 and gold.textB < 0.7,
  "a tier-3 material reads warm")
ok(common and common.textB > common.textR, "…and a common one reads cold")

-- 6. THE HEADING carries the live pack line and what it is worth.
ok(says("suit pack"), "the heading shows the pack line")
ok(says("worth $"), "…and what the depot would pay for it")
ok(says("temperate shelf"), "…and what you're standing on")

-- 7. A CRAFT IN REACH BEATS THE DEPOT. The depot is 8 m away and always has
-- been; the moment the lander is closer, the transfer goes to the hold.
ok(_G.targetId == "base", "with only the depot in reach, the target is the warehouse")
craft_node.x = astro.x + 4
tick(1)
ok(_G.targetId == "hold1", "a craft in reach wins — you walked to the ship for a reason")
ok(says("Transfer all"), "…and the panel offers the one primary action")

-- 8. CLICKING A ROW MOVES THAT STACK, and re-applies the craft's mass.
local before_mass = mass_applied
local _, bs = screen()
local ore_row
for _, b in ipairs(bs) do if b.text:find("Iron Ore", 1, true) then ore_row = b end end
ok(ore_row ~= nil, "the ore stack has a clickable row")
ore_row.onClicked()
ok(#moved_log == 1 and moved_log[1].dst == "hold1", "clicking a row moves that stack to the hold")
ok(mass_applied > before_mass, "…and the craft's mass is re-applied (a loaded ship flies loaded)")
tick(1)
-- The ROWS, specifically: the confirmation line still names the material, and
-- should — "2 x Iron Ore -> Lander hold" is the panel telling you it worked.
local function row_says(needle)
  local _, bb = screen()
  for _, b in ipairs(bb) do
    if b.style == "panel/row" and b.text:find(needle, 1, true) then return true end
  end
  return false
end
ok(not row_says("Iron Ore"), "the moved stack leaves the list")
ok(says("Iron Ore"), "…but the panel still confirms what it moved")

-- 9. A FULL HOLD SAYS SO AND KEEPS THE CARGO. The failure that must never be
-- silent: a transfer that can't happen must not eat the pack.
hold_full = true
local n_before = #pack
local _, bs2 = screen()
for _, b in ipairs(bs2) do
  if b.style == "panel/action" then b.onClicked() end
end
tick(1)
ok(#pack == n_before, "a refused transfer destroys nothing")
ok(says("nothing fits"), "…and the panel says why: " .. table.concat((screen()), " | "))
hold_full = false

-- 10. ESC CLOSES IT, and so does walking away — the pack is on your back, but
-- the panel is not something that follows you into a cockpit.
press("escape"); tick(1)
ok(_G.open == false, "Esc closes the panel")
press("i"); tick(1)
ok(_G.open == true, "…and I opens it again")
walker.onFoot = false
tick(1)
ok(_G.open == false and panel.__el.visible == false,
  "climbing into a pod closes the panel")

report("INVENTORY SMOKE OK — " .. checks .. " checks passed")
