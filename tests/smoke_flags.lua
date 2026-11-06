-- SMOKE: the agency's flags and the deployables store, offline.
--
--   * DEPLOYABLES (scripts/deployables.lua): place, list, near, rename and
--     remove; records body-relative in the save (dep.list / dep.<id>);
--     hasFlagOn / flagBodies; the missions board hears of a plant; the date
--     comes off the agency's own clock (kept in the save across sessions);
--     snapshot and restore for a revert to launch; a reload reads it all back
--   * THE TRACKING STATION (the map's STATION mode) lists the flags under
--     FLAGS and on the map; the card says where and who; RENAME (also from
--     deployables' Rename…) and REMOVE (twice)
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
  width wrap x y navUp navDown navLeft navRight scrollFade]]):gmatch("%S+") do PROPS[p] = true end
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
local trees = {}
local NODES = {}
for _, nm in ipairs({ "Tracking Station", "Station Fleet", "Station Card", "Station Strip" }) do
  local el = { visible = false }
  NODES[nm] = { name = nm, valid = true, getcomponent = function() return el end }
end
local EM = { valid = true, tex = function() return "img:9" end, name = function() return "Polaris Works" end }
local OMS = { open = false }
local OM = { valid = true, mode = "chart" }
OM.isOpen = function() return OMS.open end
OM.openStation = function() OMS.open = true; OM.mode = "station" end
OM.close = function() OMS.open = false; OM.mode = "chart" end
OM.focusOn = function(fn) OMS.focus = fn end
OM.setZoom = function() end
local SCR = {
  deployables = D2, emblem = EM, orbit_map = OM,
  flight_ops = { valid = true, fleetList = function() return {} end, fleetRecords = function() return {} end },
  base_facilities = { valid = true, sited = true, baseBody = "Home", baseX = 1000, baseY = 300, baseZ = 0,
                      footprint = { body = "Home", x = 0, y = 300, z = 0 } },
  crew = CREW,
}
local senv = setmetatable({
  time = 0, save = env.save, log = function() end,
  find = function(n) return NODES[n] end, findScripts = function() return {} end,
  space = { body = function(n) return BODIES[n] end, dominant = function() return "Home" end,
            bodies = function() return { BODIES.Home, BODIES.Moon } end, time = function() return SIM end },
  ui = { make = function(n, t) trees[n.name] = t end, hovered = function() return nil end, focus = function() end },
  input = { setMouseLocked = function() end, pressed = function() return false end, mouse = function() return 0, 0 end },
  camera = { screenSize = function() return 1600, 900 end },
}, { __index = _G })
local function fresh(path)
  local E = setmetatable({}, { __index = senv })
  local chunk = assert(loadfile(path))
  setfenv(chunk, E)
  chunk()
  return E
end
local FV = fresh("solar/scripts/fleet_view.lua")
local TS
SCR.fleet_view = FV
senv.findScript = function(k) if k == "tracking_station" then return TS end return SCR[k] end
TS = fresh("solar/scripts/tracking_station.lua")
local function all() return { "col", trees["Tracking Station"], trees["Station Fleet"], trees["Station Card"], trees["Station Strip"] } end
local function tick() senv.time = senv.time + 0.3; TS.update(NODES["Tracking Station"], 0.3) end
TS.start(NODES["Tracking Station"])
TS.open()
tick()
local tree = all()
validate(tree)
check(by_key(tree, "GFLAGS") and by_key(tree, "rf:1") and by_key(tree, "rf:2"), "the station lists the flags under FLAGS")
check(has_text(tree, "Polaris Works") and by_key(tree, "emb").texture == "img:9", "its top bar wears the agency's emblem and name")
local S = FV.current()
check(S.byId["f:1"] and S.byId["f:1"].kind == "flag" and S.byId["f:1"].glyph == "▮" and S.byId["f:1"].rx ~= nil,
  "a flag is a map entry: its pennant glyph, its place body-relative")
by_key(tree, "rf:2").onClicked()
tick()
tree = all()
validate(tree)
check(has_text(tree, "MOON") and has_text(tree, "°N"), "the card says where it stands")
check(has_text(tree, "Val Orbison"), "...and who planted it")
check(OMS.focus ~= nil, "selecting it eases the map's focus to it")
TS.renameFlag(1)
tick()
tree = all()
check(TS.typing() and by_key(tree, "f"), "deployables' Rename… opens the station renaming that flag")
by_key(tree, "f").onSubmitted({ text = "Home Plate" })
check(D2.get(1).n == "Home Plate", "RENAME renames it")
tick()
by_key(all(), "end").onClicked()
check(D2.get(1) ~= nil, "REMOVE asks first")
tick()
check(has_text(all(), "Press again"), "...and says so")
by_key(all(), "end").onClicked()
check(D2.get(1) == nil, "...and the second press takes it down")
check(#bad == 0, "every element is one ui.make accepts: " .. table.concat(bad, ", "))


if #failures > 0 then
  print("FLAGS SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print(string.format("FLAGS SMOKE OK — %d checks passed", passed))
