-- SMOKE: the agency's flags and the deployables store, offline.
--
--   * DEPLOYABLES (scripts/deployables.lua): place, list, near, rename and
--     remove; records body-relative in the save (dep.list / dep.<id>);
--     hasFlagOn / flagBodies; the missions board hears of a plant; the date
--     comes off the agency's own clock (kept in the save across sessions);
--     snapshot and restore for a revert to launch; a reload reads it all back
--   * THE TRACKING STATION lists the flags under FLAGS, its detail has the
--     photo slot, VIEW, MAP, RENAME and REMOVE (twice)
--
--   luajit solar/tests/smoke_flags.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end

local function load(path, env)
  local chunk = assert(loadfile(path))
  setfenv(chunk, setmetatable(env, { __index = _G }))
  chunk()
  return env
end

local SAVE = {}
local BODIES = {
  Home = { name = "Home", x = 1000, y = 0, z = 0, radius = 300 },
  Moon = { name = "Moon", x = 5000, y = 0, z = 0, radius = 60 },
}
local SIM = 0
local planted = {}
local MISSIONS = { valid = true, flagPlanted = function(b, id) planted[#planted + 1] = b end }
local CREW = { valid = true, get = function(id) return id == 1 and { id = 1, name = "Val Orbison" } or nil end }
local env = {
  save = { get = function(k) return SAVE[k] end, set = function(k, v) SAVE[k] = v end,
           delete = function(k) SAVE[k] = nil end, slot = function() return "slot2" end },
  space = { body = function(n) return BODIES[n] end, time = function() return SIM end,
            dominant = function(x, y, z) return "Home" end },
  findScript = function(k) if k == "missions" then return MISSIONS end if k == "crew" then return CREW end end,
  find = function(n) if n == "Astronaut" then return { x = 1000, y = 302, z = 3 } end end,
  log = function() end,
  time = 0,
}
local D = load("solar/scripts/deployables.lua", env)
D.params = { spawn_range = 20000 }

-- ── place / list / near ─────────────────────────────────────────────────────
local id1 = D.place("flag", "Home", 1000, 300, 0, { by = 1 })
check(id1 == 1, "a flag is planted: " .. tostring(id1))
local r = SAVE["dep.1"]
check(r and r.k == "flag" and r.b == "Home" and r.x == 0 and r.y == 300 and r.z == 0 and r.by == 1,
  "its record is body-relative, with who planted it")
check(r and r.photo == "user://flags/slot2/1.jpg", "it has a photo path in the player's folder: " .. tostring(r and r.photo))
check(r and r.n:find("Home", 1, true) and r.d:match("^Day %d+, Y%d+$"), "it is named for its world and date: " .. tostring(r and r.n))
check(r and r.fz and r.fz > 0, "it faces whoever planted it")
check(#planted == 1 and planted[1] == "Home", "the missions board hears of it")
check(SAVE["dep.list"][1] == 1, "the index is kept")
local e, d = D.near(1000.5, 300.2, 0, 2.0)
check(e and e.id == 1 and e.kind == "flag" and d < 1, "near finds it at its foot")
local e2 = D.near(1000.1, 301.8, 0.1, 0.5)
check(e2 and e2.id == 1, "...and along its pole")
check(D.near(1010, 300, 0, 2.0) == nil, "...and not 10 m away")
local id2 = D.place("flag", "Moon", 5000, 60, 0, { by = 1, ceremony = false })
check(id2 == 2 and SAVE["dep.2"].photo == nil, "a flag planted without a ceremony takes no photo")
check(D.hasFlagOn("Moon") and D.hasFlagOn("Home") and not D.hasFlagOn("Nowhere"), "hasFlagOn")
local fb = D.flagBodies()
check(fb.Home == 1 and fb.Moon == 1, "flagBodies counts them")
check(#D.list("flag") == 2 and D.list("flag")[2].gx == 5000 + 0 and D.list("flag")[2].gy == 60, "list gives world points")
check(D.place("flag", "Nowhere", 0, 0, 0) == nil, "nothing is planted off a world")
check(D.place("teapot", "Home", 0, 0, 0) == nil, "nor an unknown kind")
check(D.memberName(1) == "Val Orbison", "the planter's name comes from the roster")

-- ── a flag's script claims its record (and its ceremony, once) ─────────────
do
  local recs_node = { valid = true, id = 4242 }
  -- stand in for the spawn: give record 1 a node
  local e1 = D.get(1)
  check(D.claim({ id = 4242 }) == nil, "an unknown node claims nothing")
end

-- ── the clock and the date ──────────────────────────────────────────────────
check(D.dateOf(0) == "Day 1, Y1" and D.dateOf(86400 * 366) == "Day 2, Y2", "dates: " .. D.dateOf(86400 * 366))
SIM = 100; env.time = 10; D.update({}, 0.016)
SIM = 86400 * 3 + 100; env.time = 20; D.update({}, 0.016)
check(D.agencyClock() >= 86400 * 3, "the agency's clock follows the sim clock")
check((SAVE["agency.clock"] or 0) >= 86400 * 3, "...and is kept in the save")
local id3 = D.place("flag", "Home", 1000, 0, 300, { by = 1 })
check(SAVE["dep." .. id3].d == "Day 4, Y1", "a later flag is dated later: " .. tostring(SAVE["dep." .. id3].d))

-- ── rename / remove ─────────────────────────────────────────────────────────
check(D.rename(1, "  First Light  ") and SAVE["dep.1"].n == "First Light", "rename (trimmed)")
check(not D.rename(1, "   "), "an empty name is refused")
local v = D.version
check(D.remove(id3) and SAVE["dep." .. id3] == nil and D.version == v + 1, "remove forgets it")
check(not D.remove(99), "removing nothing is false")

-- ── revert ──────────────────────────────────────────────────────────────────
local snap = D.snapshot()
local id4 = D.place("flag", "Home", 1000, 0, -300, { by = 1 })
D.remove(1)
local gone, back = D.restore(snap)
check(gone == 1 and back == 1, "a revert takes up the new flag and stands the old one again")
check(SAVE["dep.1"] and SAVE["dep.1"].n == "First Light" and SAVE["dep." .. id4] == nil, "...in the save too")
check(SAVE["dep.seq"] >= id4, "ids are never reused")

-- ── reload ──────────────────────────────────────────────────────────────────
local D2 = load("solar/scripts/deployables.lua", {
  save = env.save, space = env.space, findScript = env.findScript, find = env.find, log = function() end, time = 0 })
check(#D2.list() == 2 and D2.get(1).n == "First Light", "a new session reads every flag back")

-- ── the Tracking Station's FLAGS ───────────────────────────────────────────
local PROPS = {}
for p in ([[align border borderB borderColor borderL borderR borderT button case cell cols
  count dir disabled draggable dropTarget field fill fillA fillB fillG fillR flip focusable
  font frame frameSlice frameUV gap group groupA groupB groupG groupR groupTint h height image
  imageFit inset interact justify lineHeight margin mask max maxH maxLen maxLines maxW min minH
  minW numeric opacity order overflow pad part pin pivot placeholder pos posX posY radius
  radiusBL radiusBR radiusTL radiusTR rotation rows scale scaleX scaleY scrollDrag scrollSpeed
  scrollX scrollY scrollbarAxis scrollbarFor selected shader size slice sliderDir stretch style
  template text textA textAlign textB textColor textFit textG textR textSize textValign texture
  tiling tint tintA tintB tintG tintR toggle tooltip tooltipBox tracking upper value visible w
  width wrap x y navUp navDown navLeft navRight]]):gmatch("%S+") do PROPS[p] = true end
local KINDS = { box = true, row = true, col = true, text = true, image = true, button = true,
                field = true, slider = true, scroll = true }
local bad = {}
local function each(el, out)
  out = out or {}
  if type(el) ~= "table" then return out end
  out[#out + 1] = el
  local fn
  for i = 1, #el do
    if type(el[i]) == "table" then each(el[i], out) elseif type(el[i]) == "function" then fn = el[i] end
  end
  if el.items and fn then for i, it in ipairs(el.items) do each(fn(it, i), out) end end
  return out
end
local function validate(tree)
  for _, el in ipairs(each(tree)) do
    if type(el[1]) == "string" and not KINDS[el[1]] then bad[#bad + 1] = "kind " .. el[1] end
    for k in pairs(el) do
      if type(k) == "string" and not (PROPS[k] or k == "key" or k == "name" or k == "items" or k:match("^on%u")) then
        bad[#bad + 1] = "property " .. k
      end
    end
  end
end
local function by_key(tree, key) for _, e in ipairs(each(tree)) do if e.key == key then return e end end end
local function has_text(tree, needle)
  for _, e in ipairs(each(tree)) do if type(e.text) == "string" and e.text:find(needle, 1, true) then return e end end
end
local tree
local panel = { visible = false, width = 0 }
local closed = 0
local mapped = nil
local EM = { valid = true, tex = function() return "img:9" end, name = function() return "Polaris Works" end }
local ts = load("solar/scripts/tracking_station.lua", {
  time = 0,
  findScript = function(k)
    if k == "deployables" then return D2 end
    if k == "emblem" then return EM end
    if k == "flight_ops" then return { valid = true, fleetList = function() return {} end } end
    if k == "base_facilities" then return { valid = true, sited = true, baseBody = "Home", baseX = 1000, baseY = 300, baseZ = 0 } end
    if k == "orbit_map" then return { valid = true, focusNode = function(n) mapped = n end } end
    if k == "facility_menu" then return { valid = true, close = function() closed = closed + 1 end } end
    if k == "crew" then return CREW end
    return nil
  end,
  save = env.save, log = function() end,
  find = function(n) if n == "Moon" then return { name = "Moon" } end end,
  space = { body = function(n) return BODIES[n] end, dominant = function() return "Home" end },
  ui = { make = function(_, t) tree = t end },
  input = { setMouseLocked = function() end },
  camera = { screenSize = function() return 1600, 900 end },
})
ts.start({ getcomponent = function() return panel end })
ts.open()
ts.update({ getcomponent = function() return panel end }, 0.016)
validate(tree)
check(by_key(tree, "LFlags") and by_key(tree, "rf:1") and by_key(tree, "rf:2"), "the station lists the flags under FLAGS")
check(has_text(tree, "Polaris Works") and by_key(tree, "emb").texture == "img:9", "its header wears the agency's emblem and name")
check(has_text(tree, "2 flags"), "...and counts the flags")
by_key(tree, "rf:2").onClicked()
ts.update({ getcomponent = function() return panel end }, 0.016)
validate(tree)
check(has_text(tree, "Agency flag") and has_text(tree, "Moon") and has_text(tree, "°N"), "the detail says where it stands")
check(has_text(tree, "no photo"), "a flag without a photo says so")
check(has_text(tree, "Val Orbison"), "...and who planted it")
check(has_text(tree, "world to world"), "a flag on another world is measured world to world")
by_key(tree, "map").onClicked()
check(mapped and mapped.name == "Moon" and closed == 1, "MAP opens the orbit map on its world")
by_key(tree, "rf:1").onClicked()
ts.update({ getcomponent = function() return panel end }, 0.016)
check(has_text(tree, "From base"), "a flag on the home world is measured from the base")
by_key(tree, "rn").onClicked()
ts.update({ getcomponent = function() return panel end }, 0.016)
by_key(tree, "f").onSubmitted({ text = "Home Plate" })
check(D2.get(1).n == "Home Plate", "RENAME renames it")
ts.update({ getcomponent = function() return panel end }, 0.016)
by_key(tree, "rm").onClicked()
check(D2.get(1) ~= nil, "REMOVE asks first")
ts.update({ getcomponent = function() return panel end }, 0.016)
check(has_text(tree, "Press again"), "...and says so")
by_key(tree, "rm").onClicked()
check(D2.get(1) == nil, "...and the second press takes it down")
check(#bad == 0, "every element is one ui.make accepts: " .. table.concat(bad, ", "))

if #failures > 0 then
  print("FLAGS SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print(string.format("FLAGS SMOKE OK — %d checks passed", passed))
