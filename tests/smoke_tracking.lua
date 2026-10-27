-- SMOKE: the screens and switches of the electronics pass, offline.
--
--   * TRACKING STATION (scripts/tracking_station.lua): the board lists the crew
--     and every craft with its signal; the detail says power, signal, path and
--     who can fly it; FLY / RECOVER / END FLIGHT (two presses) / RENAME / MAP
--     call flight_ops; every element is one ui.make accepts.
--   * CONTROLS TAB (scripts/groups_panel.lua, was the action groups panel): the
--     selected part's actions as ticks, the open group's list with ✕; a tick
--     calls the builder; every element valid.
--   * VESSEL SWITCHER (scripts/vessel_switcher.lua): [ ] cycles the crew and
--     the craft in range — never one out of range, always the crew.
--
--   luajit solar/tests/smoke_tracking.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end

-- ── what ui.make accepts (floptle-ui make.rs ALL_PROPS) — as smoke_flight_hud ──
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
local BUILDER = { key = true, name = true, items = true }
local KINDS = { box = true, row = true, col = true, text = true, image = true, button = true,
                field = true, slider = true, scroll = true }
local bad = {}
local function validate(el, path)
  if type(el) ~= "table" then return end
  if type(el[1]) == "string" and not KINDS[el[1]] then bad[#bad + 1] = path .. ": kind " .. el[1] end
  for k in pairs(el) do
    if type(k) == "string" and not (PROPS[k] or BUILDER[k] or k:match("^on%u")) then
      bad[#bad + 1] = path .. ": property " .. k
    end
  end
  local fn
  for i = 1, #el do
    if type(el[i]) == "table" then validate(el[i], path .. "/" .. tostring(el[i].key or i))
    elseif type(el[i]) == "function" then fn = el[i] end
  end
  if el.items and fn then
    for i, it in ipairs(el.items) do
      local c = fn(it, i)
      if c then validate(c, path .. "/" .. tostring(c.key or i)) end
    end
  end
end
local function each(el, out)
  out = out or {}
  if type(el) ~= "table" then return out end
  out[#out + 1] = el
  local fn
  for i = 1, #el do
    if type(el[i]) == "table" then each(el[i], out)
    elseif type(el[i]) == "function" then fn = el[i] end
  end
  if el.items and fn then
    for i, it in ipairs(el.items) do each(fn(it, i), out) end
  end
  return out
end
local function by_key(tree, key)
  for _, e in ipairs(each(tree)) do if e.key == key then return e end end
end
local function has_text(tree, needle)
  for _, e in ipairs(each(tree)) do
    if type(e.text) == "string" and e.text:find(needle, 1, true) then return e end
  end
end

-- ── the rulebook ────────────────────────────────────────────────────────────
local Eenv = setmetatable({}, { __index = _G })
local ec = assert(loadfile("solar/scripts/electronics.lua"))
setfenv(ec, Eenv)
ec()
local E = Eenv
E.valid = true

local function load(path, env)
  local chunk = assert(loadfile(path))
  setfenv(chunk, setmetatable(env, { __index = _G }))
  chunk()
  return env
end

-- ── TRACKING STATION ────────────────────────────────────────────────────────
local calls = {}
local FLEET = {
  { fid = "c1", name = "Relay One", body = "Home", status = "in orbit", alt = 900, pe = 850, ap = 950,
    live = true, piloted = false, link = true, signal = 0.9, hops = 1, path = { "Ground station" },
    probe = true, pod = false, comms = true, charge = 180, cap = 200, control = true, fee = 0 },
  { fid = "c2", name = "Moonwatch B", body = "Home", status = "in flight", alt = 1400, live = true,
    piloted = false, link = false, signal = 0, hops = 0, probe = true, pod = false, comms = true,
    charge = 40, cap = 50, control = false, why = "NO SIGNAL — no path home", fee = 0 },
  { fid = "c3", name = "Lander", body = "Home", status = "landed", alt = 2, landed = true, home = true,
    live = true, piloted = false, link = true, signal = 0.6, hops = 2, path = { "Relay One", "Ground station" },
    probe = false, pod = true, comms = false, charge = 30, cap = 40, fee = 0, dist = 80 },
}
local FO = { valid = true,
  fleetList = function() return FLEET end,
  takeControlOf = function(fid) calls[#calls + 1] = "fly:" .. fid return true, fid end,
  recoverFleet = function(fid) calls[#calls + 1] = "recover:" .. fid return true end,
  terminateFleet = function(fid) calls[#calls + 1] = "end:" .. fid return true end,
  renameFleet = function(fid, n) calls[#calls + 1] = "rename:" .. fid .. ":" .. tostring(n) return true end,
  liveOf = function(fid)
    return { node = { id = 7, valid = true, x = 40, y = 301, z = 0 },
             recoverValue = function() return 1000 end, parked = function() return fid == "c3" end }
  end,
}
local EARNED = {}
local CO = { valid = true, earn = function(v, why) EARNED[#EARNED + 1] = { v = v, why = why } end,
             money = function(v) return "$" .. tostring(v) end }
local BF = { valid = true, sited = true, baseBody = "Home", baseX = 0, baseY = 300, baseZ = 0,
             trackingStationOn = function(b) return b == "Home" end }
local SAVE = {}
local MAP = { valid = true, focusNode = function() calls[#calls + 1] = "map" end }
local tree = nil
local panel_el = { visible = false, width = 0 }
local FM = { valid = true, close = function() panel_el.visible = false; calls[#calls + 1] = "close" end }
local T = 0
local ts = load("solar/scripts/tracking_station.lua", {
  time = 0,
  findScript = function(k)
    if k == "flight_ops" then return FO end
    if k == "electronics" then return E end
    if k == "orbit_map" then return MAP end
    if k == "facility_menu" then return FM end
    if k == "comms" then return { valid = true, transmitters = 4, refreshNow = function() end } end
    if k == "company" then return CO end
    if k == "base_facilities" then return BF end
    if k == "crew" then return { valid = true, activeId = function() return 1 end,
      get = function(id) return id == 1 and { id = 1, name = "Felix Vance" } or nil end, roster = function() return {} end } end
    return nil
  end,
  save = { get = function(k) return SAVE[k] end, set = function(k, v) SAVE[k] = v end },
  log = function() end,
  find = function(n) if n == "Astronaut" then return { x = 0, y = 310, z = 0 } end end,
  space = { dominant = function() return "Home" end,
            body = function() return { x = 0, y = 0, z = 0, radius = 300 } end },
  ui = { make = function(_, t) tree = t end },
  input = { setMouseLocked = function() end },
  camera = { screenSize = function() return 1600, 900 end },
})
local tnode = { getcomponent = function() return panel_el end }
ts.start(tnode)
ts.open()
check(ts.isOpen(), "the station opens")
ts.update(tnode, 0.016)
validate(tree, "ts")
check(#bad == 0, "every tracking-station element is valid: " .. table.concat(bad, ", "))
check(by_key(tree, "rcrew") and by_key(tree, "rc1") and by_key(tree, "rc2") and by_key(tree, "rc3"),
  "the board lists the crew and every craft")
check(has_text(tree, "Felix Vance"), "the crew row names the crew member you control (not \"Crew\")")
check(has_text(tree, "▮▮▮▮"), "a craft in contact shows its signal bars")
check(has_text(tree, "no link"), "a craft out of contact says so")
-- select the probe out of contact: detail says why it can't be flown
by_key(tree, "rc2").onClicked()
ts.update(tnode, 0.016)
check(has_text(tree, "no signal") or has_text(tree, "NO SIGNAL") or has_text(tree, "no path home"),
  "the detail says why a probe can't be commanded")
-- select the relay and fly it
by_key(tree, "rc1").onClicked()
ts.update(tnode, 0.016)
check(has_text(tree, "Ground station") and has_text(tree, "180 / 200 EC"), "the detail shows its path and its power")
by_key(tree, "fly").onClicked()
check(calls[#calls] == "close" and calls[#calls - 1] == "fly:c1", "FLY takes its controls and closes the station")
-- the lander: recover (landed at home), map, end flight twice
panel_el.visible = true
by_key(tree, "rc3").onClicked()
ts.update(tnode, 0.016)
check(by_key(tree, "rec").disabled == false, "a craft landed at home can be recovered")
check(has_text(tree, "Relay One → Ground station"), "a relayed path is spelled out")
by_key(tree, "rec").onClicked()
check(calls[#calls] == "end:c3" and #EARNED == 1 and EARNED[1].v == 1000 and SAVE["mission.recovered"] == true,
  "RECOVER refunds the craft, ticks the recovery goal and takes it off the board")
-- a landed craft far from the base: still recoverable, refund scaled down
FLEET[3].home, FLEET[3].dist = false, 9000
local far_live = FO.liveOf
FO.liveOf = function(fid)
  local v = far_live(fid)
  v.node.x, v.node.y = 300, 0   -- a quarter of the way round the 300 m world
  return v
end
ts.selectCraft("c3")
ts.update(tnode, 0.016)
check(by_key(tree, "rec").disabled == false, "a craft landed anywhere on the home world can be recovered")
by_key(tree, "rec").onClicked()
check(#EARNED == 2 and EARNED[2].v < 1000 and EARNED[2].v > 100,
  "...and a far one refunds less (" .. tostring(EARNED[2] and EARNED[2].v) .. ")")
FO.liveOf = far_live
-- in orbit: greyed out, with the reason on the screen
ts.selectCraft("c1")
ts.update(tnode, 0.016)
check(by_key(tree, "rec").disabled == true and has_text(tree, "in orbit"),
  "a craft in orbit can't be recovered, and the screen says why")
-- landed on a world with no tracking station
FLEET[3].body = "Moon"
ts.selectCraft("c3")
ts.update(tnode, 0.016)
check(by_key(tree, "rec").disabled == true and has_text(tree, "not on a planet with a tracking station"),
  "a craft landed on another world can't be recovered, and the screen says why")
FLEET[3].body = "Home"
calls[#calls + 1] = "-"

-- a crew transfer the account can't pay for: greyed out, and it says why
FLEET[3].pod, FLEET[3].probe, FLEET[3].crew, FLEET[3].fee = true, false, false, 195
CO.afford = function(v) return v <= 110 end
CO.balance = function() return 110 end
ts.selectCraft("c3")
ts.update(tnode, 0.016)
check(by_key(tree, "fly").disabled == true and has_text(tree, "more than the balance"),
  "Send the crew is greyed out when the shuttle costs more than the balance, with the reason")
CO.afford = function() return true end
ts.update(tnode, 0.016)
check(by_key(tree, "fly").disabled == false, "...and open again once it can be paid")
FLEET[3].fee = 0

-- the rules themselves (pure)
local home = function(b) return b == "Home" end
check(ts.recoverRule({ fid = "x", body = "Home", rest = true }, home) == true, "rule: at rest at home → yes")
local okf, whyf = ts.recoverRule({ fid = "x", body = "Home", rest = false, status = "in orbit" }, home)
check(okf == false and whyf:find("in orbit", 1, true), "rule: in orbit → no, says in orbit")
local okl, whyl = ts.recoverRule({ fid = "x", body = "Home", rest = false, status = "flying — remote" }, home)
check(okl == false and whyl:find("in flight", 1, true), "rule: flying → no, says in flight")
local okm, whym = ts.recoverRule({ fid = "x", body = "Moon", rest = true }, home)
check(okm == false and whym == "not on a planet with a tracking station", "rule: another world → no station")
check(ts.recoverRule({ fid = "x", body = "Moon", rest = true }, function() return true end) == true,
  "rule: a world that gets a station opens up (the hook)")
check(ts.recoverRule({ fid = "x", body = "Home", rest = true, crewAway = true }, home) == false,
  "rule: a crewed craft not back in the scene waits")
check(ts.recoverRule({ fid = "crew" }, home) == false, "rule: the crew row is not a craft")
check(ts.recoveryFactor(100, 30000) == 1.0 and ts.recoveryFactor(nil, 30000) == 1.0, "factor: full at the base")
local f1, f2 = ts.recoveryFactor(5000, 30000), ts.recoveryFactor(40000, 30000)
check(f1 < 1.0 and f2 < f1 and f2 > 0.1, "factor: falls off with distance")
check(math.abs(ts.recoveryFactor(math.pi * 30000, 30000) - 0.25) < 1e-9, "factor: 25% at the antipode")
ts.selectCraft("c3")
ts.update(tnode, 0.016)
by_key(tree, "end").onClicked()
ts.update(tnode, 0.016)
check(by_key(tree, "end").text == "Confirm" and calls[#calls] ~= "end:c3", "END FLIGHT arms on the first press")
by_key(tree, "end").onClicked()
check(calls[#calls] == "end:c3", "...and writes the craft off on the second")
-- rename
by_key(tree, "rc1").onClicked()
ts.update(tnode, 0.016)
by_key(tree, "rn").onClicked()
ts.update(tnode, 0.016)
check(ts.typing() and by_key(tree, "f") and by_key(tree, "f")[1] == "field", "RENAME opens a text field")
by_key(tree, "f").onSubmitted({ text = "Hermes" })
check(calls[#calls] == "rename:c1:Hermes", "...and Enter renames the craft")
bad = {}
validate(tree, "ts2")
check(#bad == 0, "the rename row is valid too: " .. table.concat(bad, ", "))

-- ── CONTROLS TAB (groups_panel.lua, the builder's keymap — WP5) ─────────────
-- The bind flow itself is tests/smoke_builder_bind.lua; this checks the tab
-- reads a craft's standard groups and edits through the builder's commands.
local recs = {
  [1] = { uid = 1, id = "probe", label = "Probe Core", kind = "probe" },
  [5] = { uid = 5, id = "solar", label = "Solar Panel", sym = 1, mods = { { type = "solar", gen = 1 }, { type = "deploy", anim = "solar" } } },
  [6] = { uid = 6, id = "solar", label = "Solar Panel", sym = 1, mods = { { type = "solar", gen = 1 }, { type = "deploy", anim = "solar" } } },
  [8] = { uid = 8, id = "light", label = "Floodlight", mods = { { type = "light", draw = 0.2 } } },
}
local CT = load("solar/scripts/controls.lua", {})
local G = E.defaultGroups(recs)
local cdata = { v = 1, axes = {}, custom = {} }
local psel = 8
local B = { valid = true, craftVersion = 1,
  tool = function() return "groups" end,
  groupsNow = function() return G, recs end,
  controlsData = function() return cdata end,
  selection = function() return { psel } end,
  selectionPrimary = function() return psel end,
  partRec = function(u) local r = recs[u] return r and { uid = u, id = r.id, def = { label = r.label, mods = r.mods, kind = r.kind }, sym = r.sym } end,
  cmd = function(name, a)
    local r = CT[name](cdata, a, { groups = G, recs = recs, E = E, members = function(u) return { u } end })
    if r then B.craftVersion = B.craftVersion + 1 end
    return r
  end,
}
local gtree = nil
local gel = { visible = false }
local gp = load("solar/scripts/groups_panel.lua", {
  findScript = function(k) if k == "builder" then return B end if k == "electronics" then return E end
    if k == "controls" then return CT end end,
  ui = { make = function(_, t) gtree = t end },
})
local gnode = { getcomponent = function() return gel end }
gp.start(gnode)
gp.update(gnode, 0.016)
check(gel.visible, "the CONTROLS tab shows on the groups tool")
bad = {}
validate(gtree, "groups")
check(#bad == 0, "every CONTROLS element is valid: " .. table.concat(bad, ", "))
check(has_text(gtree, "Solar Panel ×2") and has_text(gtree, "Deploy"), "the Deploy key lists the panel ring as one entry")
check(has_text(gtree, "Floodlight") and has_text(gtree, "Lights"), "the Lights key holds the floodlight")
check(has_text(gtree, "Light on / off"), "the selected floodlight's actions are listed")
-- take the floodlight off its key from the selected-part list
local x = nil
for _, e in ipairs(each(gtree)) do if e.key == "x" and e.onClicked and not e.disabled and not x then x = e end end
check(x ~= nil, "a ✕ to take an action off its key")
gp.update(gnode, 0.016)
local before = E.isBound(G, "lights", 8, "lit.toggle")
CT.unbind(cdata, { uids = { 8 }, acts = { "lit.toggle" } }, { groups = G, recs = recs, E = E })
check(before and not E.isBound(G, "lights", 8, "lit.toggle"), "unbinding through controls.lua takes the light off Lights")

-- ── VESSEL SWITCHER ─────────────────────────────────────────────────────────
local function V(id, name, x, cs)
  local v = { node = { id = id, valid = true, x = x, y = 0, z = 0 }, craftName = name, piloting = false,
              crewAboard = cs.crew or false }
  v.controlState = function() return cs end
  return v
end
local A = V(1, "Alpha", 0, { pod = true, crew = false, can = false })
local Bv = V(2, "Bravo", 500, { probe = true, can = true })
local C = V(3, "Charlie", 90000, { probe = true, can = true })
local D = V(4, "Debris", 100, { lost = true, probe = true })
local VS = { A, Bv, C, D }
local switched = {}
local FO2 = { valid = true,
  switchToVessel = function(v) for _, x in ipairs(VS) do x.piloting = false end; v.piloting = true; switched[#switched + 1] = v.craftName return true end,
  switchToCrew = function() for _, x in ipairs(VS) do x.piloting = false end; switched[#switched + 1] = "crew" return true end,
}
local sw = load("solar/scripts/vessel_switcher.lua", {
  params = { range = 2500 },
  findScript = function(k) if k == "flight_ops" then return FO2 end return nil end,
  -- fresh handles every call, as the engine's findScripts gives
  findScripts = function(k)
    if k ~= "vessel_controller" then return {} end
    local out = {}
    for i, v in ipairs(VS) do out[i] = setmetatable({}, { __index = v, __newindex = v }) end
    return out
  end,
  find = function(n) if n == "Astronaut" then return { x = 10, y = 0, z = 0 } end end,
  caption = function() end, log = function() end,
  input = { pressed = function() return false end },
})
local list = sw.targets()
local names = {}
for _, t in ipairs(list) do names[#names + 1] = t.name end
check(table.concat(names, ",") == "Crew,Alpha,Bravo", "in range: the crew, then craft by name (" .. table.concat(names, ",") .. ")")
sw.step(1)
check(switched[#switched] == "Alpha", "] from the crew goes to the first craft")
sw.step(1)
check(switched[#switched] == "Bravo", "] again: the next")
sw.step(1)
check(switched[#switched] == "crew", "] wraps round to the crew")
sw.step(-1)
check(switched[#switched] == "Bravo", "[ goes back")
-- flying Bravo far away: Charlie is in range of IT, the crew is always there
Bv.node.x = 89000
Bv.piloting = true
names = {}
for _, t in ipairs(sw.targets()) do names[#names + 1] = t.name end
check(table.concat(names, ",") == "Crew,Bravo,Charlie", "range is measured from what you fly; the crew is always on the list (" .. table.concat(names, ",") .. ")")

if #failures == 0 then
  print(string.format("TRACKING SMOKE OK — %d checks passed", passed))
  os.exit(0)
end
print("TRACKING SMOKE FAILURES:")
for _, f in ipairs(failures) do print("  ✗ " .. f) end
os.exit(1)
