-- SMOKE: the parts catalogue's playtest fixes (2026-10-26).
--
--   * switching section (or the search) scrolls the list back to the TOP;
--     the once-a-second refresh, a pick and the same tab again never move it
--   * the card of the part in your hand is latched in ("panel/rowActive",
--     IN HAND) and the footer says how to put it back
--   * a second click on the held card puts it back; another card swaps
--
--   luajit solar/tests/smoke_builder_catalog.lua   (from the Floptle repo root)

local failures, checks = {}, 0
local function check(c, what) checks = checks + 1; if not c then failures[#failures + 1] = what end end

local held, holding = nil, nil
local B = {}
local DEFS = { tankS = { label = "FT-S Tank", cost = 100, mass = 0.1, fuel = 10 },
               tankM = { label = "FT-M Tank", cost = 200, mass = 0.2, fuel = 20 },
               pod = { label = "Pod Mk1", cost = 400, mass = 1.3, kind = "crewed" } }
function B.catalogue() return { { title = "COMMAND", ids = { "pod" } }, { title = "PROPULSION", ids = { "tankS", "tankM" } } } end
function B.partInfo(id) return DEFS[id] end
function B.heldId() return held end
function B.holding() return holding end
function B.hold(id) if held then return false end held, holding = id, "part"; return true end
function B.dropHeld() if not held then return false end held, holding = nil, nil; return true end
function B.registerPanel() return true end

local list_el = { scrollY = 0 }
local made = {}
local env = setmetatable({}, { __index = _G })
env.findScript = function(k) if k == "builder" then return B end return nil end
env.find = function(name) if name == "CatalogList" then return { getcomponent = function() return list_el end } end return nil end
env.ui = { make = function(node, tree) made[#made + 1] = tree end, focused = function() return nil end, focus = function() end }
env.input = { mouse = function() return 0, 0 end }
env.save = { get = function(_, d) return d end, set = function() end }
local f = assert(loadfile("solar/scripts/catalog_panel.lua"))
setfenv(f, env)
f()
local C = env
local node = { getcomponent = function() return { visible = true } end }
C.start(node)
local function frame(n, dt) for _ = 1, n or 1 do C.update(node, dt or 0.016) end end
local function find_key(t, key, out)
  if type(t) ~= "table" then return out end
  if t.key == key then out = out or t end
  for i = 1, #t do out = find_key(t[i], key, out) end
  if t.items then
    local fn
    for i = 1, #t do if type(t[i]) == "function" then fn = t[i] end end
    if fn then for i, it in ipairs(t.items) do out = find_key(fn(it, i), key, out) end end
  end
  return out
end

frame(2)
check(#made >= 1, "the catalogue describes itself")
local tree = made[#made]
check(find_key(tree, "list") and find_key(tree, "list").name == "CatalogList", "the list is a named scroll (CatalogList)")

-- scrolled down in ALL, then a section tab: back to the top
list_el.scrollY = 380
frame(30)
check(list_el.scrollY == 380, "idle frames keep the scroll")
frame(1, 1.2)   -- the once-a-second refresh
check(list_el.scrollY == 380, "the once-a-second refresh keeps the scroll")
C.setTab("PROPULSION")
frame(3)
check(list_el.scrollY == 0, "a new section starts at the top")
list_el.scrollY = 120
C.setTab("PROPULSION")
frame(3)
check(list_el.scrollY == 120, "the same section again keeps the scroll")
C.setQuery("tank")
frame(3)
check(list_el.scrollY == 0, "a new search starts at the top")
list_el.scrollY = 50
C.setQuery("tank")
frame(3)
check(list_el.scrollY == 50, "the same search keeps the scroll")
C.setQuery("")
C.setTab("ALL")
frame(3)
list_el.scrollY = 200

-- the part in hand: its card latched, IN HAND, the footer says how to put it back
C.pickPart("tankM")
frame(2)
check(held == "tankM", "a card click puts the part in hand")
check(list_el.scrollY == 200, "a pick keeps the scroll")
tree = made[#made]
local cardM = find_key(tree, "tankM")
local btn = cardM and find_key(cardM, "c")
check(btn and btn.style == "panel/rowActive" and btn.selected == true, "the held card is latched in (panel/rowActive)")
local price = find_key(btn, "p")
check(price and price.text == "IN HAND" and price.style == "cat/inHand", "its price slot reads IN HAND")
local other = find_key(tree, "tankS")
check(other and find_key(other, "c").style == "panel/row", "the other cards are not")
local foot = find_key(tree, "foot")
check(foot and foot.text:find("IN HAND") ~= nil, "the footer says how to put it back")
-- another card swaps; the same card again puts it back
C.pickPart("tankS")
frame(2)
check(held == "tankS", "another card swaps the part in hand")
C.pickPart("tankS")
frame(2)
check(held == nil, "the held card clicked again puts it back")
tree = made[#made]
check(find_key(find_key(tree, "tankS"), "c").style == "panel/row", "…and its card lets go")
-- a lifted craft piece is never dropped from the catalogue
held, holding = "pod", "carry"
C.pickPart("tankS")
check(held == "pod", "a lifted piece in hand is not dropped by a card click")
held, holding = nil, nil

-- every style it names exists
local styles = io.open("solar/ui/solar.uistyle.ron"):read("*a")
check(styles:find('"cat/inHand"', 1, true) ~= nil, "the cat/inHand style exists")

if #failures > 0 then
  print(("smoke_builder_catalog: %d/%d FAILED"):format(#failures, checks))
  for _, m in ipairs(failures) do print("  FAIL " .. m) end
  os.exit(1)
end
print(("smoke_builder_catalog: all %d checks passed"):format(checks))
