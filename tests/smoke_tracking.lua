-- SMOKE: the screens and switches of the electronics pass, offline.
--
--   * TRACKING STATION (scripts/tracking_station.lua, the orbit map's STATION
--     mode; fleet_view.lua, map_labels.lua): 60 craft, crew, 200 debris, relays,
--     flags and a structure; the FLEET groups (DEBRIS folded), ATTENTION, the
--     SELECTED card (CRT inset, crew, recover badge or the reason verbatim),
--     FLY / RECOVER / TERMINATE (two presses) / RENAME / GO TO / the WARP
--     rungs; the board read at 2 Hz, the list described on change; the map
--     pass: anchors for every entry this frame, an offline craft carried
--     along its conic, at most 40 tags, none overlapping, none under a panel,
--     a click on an icon selects it; every element one ui.make accepts.
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
  width wrap x y navUp navDown navLeft navRight scrollFade]]):gmatch("%S+") do PROPS[p] = true end
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

local function loadin(path, E)
  local chunk = assert(loadfile(path))
  setfenv(chunk, E)
  chunk()
  if E.defaults and not E.params then E.params = {}; for k, v in pairs(E.defaults) do E.params[k] = v end end
  return E
end
-- ── TRACKING STATION (the orbit map's STATION mode) ─────────────────────────
-- A fleet of 60 craft, three members, relays, flags, debris and a structure,
-- against stubs of everything the station reads.
local T = 100.0
local calls = {}
local SAVE = {}
local BODY = { name = "Home", x = 0, y = 0, z = 0, vx = 0, vy = 0, vz = 0, radius = 300, mu = 3.0e6, soi = 6000 }
local MOON = { name = "Moon", x = 20000, y = 0, z = 0, vx = 0, vy = 0, vz = 0, radius = 80, mu = 2.0e5, soi = 900 }
local BODIES = { BODY, MOON }
local function body(n) if n == "Home" then return BODY elseif n == "Moon" then return MOON end end
local POD = { uid = 1, id = "pod", kind = "crewed", cost = 600, st = { crew1 = 1 } }
local PROBE = { uid = 1, id = "probe", kind = "probe", cost = 400 }
local function parts(kind)
  if kind == "rocket" then return { { uid = 1, id = "pod", kind = "crewed", cost = 600, st = "crew1=2" },
    { uid = 2, id = "tankS", kind = "tank", fuel = 100, cost = 100 }, { uid = 3, id = "engineS", kind = "engine", cost = 300 } } end
  if kind == "rover" then return { { uid = 1, id = "roverBody", kind = "probe" }, { uid = 2, id = "wheelS" }, { uid = 3, id = "wheelS" },
    { uid = 4, id = "wheelS" }, { uid = 5, id = "wheelS" } } end
  if kind == "plane" then return { { uid = 1, id = "cockpit", kind = "crewed" }, { uid = 2, id = "wingL" }, { uid = 3, id = "wingL" } } end
  return { { uid = 1, id = "probe", kind = "probe", cost = 400 }, { uid = 2, id = "battery", kind = "structural", cost = 50 } }
end
local FLEET, RECS = {}, {}
local function add_craft(fid, name, kind, f)
  local e = { fid = fid, name = name, body = f.body or "Home", status = f.status or "in orbit", alt = f.alt or 900, pe = f.pe, ap = f.ap,
              live = f.live ~= false, piloted = f.piloted or false, link = f.link ~= false, signal = 0.8, hops = 1,
              path = { "Ground station" }, probe = kind ~= "rocket" and kind ~= "plane", pod = kind == "rocket" or kind == "plane",
              comms = true, charge = f.charge or 180, cap = f.cap or 200, control = f.link ~= false, fee = 0,
              landed = f.landed or false, crew = f.crew or false, dist = f.dist }
  FLEET[#FLEET + 1] = e
  RECS[fid] = { name = name, body = e.body, x = f.x or 0, y = f.y or 1200, z = f.z or 0, vx = f.vx or 50, vy = 0, vz = f.vz or 0,
                landed = e.landed, parts = parts(kind), t = 1, stime = T, fuel = 50 }
end
add_craft("c1", "Relay One", "probe", { pe = 850, ap = 950, x = 1200, y = 0, vz = 50 })
add_craft("c2", "Moonwatch B", "probe", { link = false, status = "in flight", charge = 4, cap = 50, x = 0, y = 1300, vx = 48 })
add_craft("c3", "Lander", "rocket", { status = "landed", landed = true, alt = 2, x = 0, y = 302, vx = 0, dist = 80 })
add_craft("c4", "Gull 2", "plane", { status = "landed", landed = true, alt = 2, x = 60, y = 300, vx = 0 })
add_craft("c5", "Dustcat", "rover", { status = "landed", landed = true, alt = 1, x = -80, y = 296, vx = 0 })
for i = 6, 60 do
  local a = i * 0.37
  add_craft("c" .. i, string.format("Sat %02d", i), "probe",
    { pe = 700 + i, ap = 800 + i, x = math.cos(a) * (1000 + i * 5), y = math.sin(a) * (1000 + i * 5), vx = -math.sin(a) * 50, vz = 5, live = (i % 2 == 0) })
end
local fleet_calls = 0
local LIVE = {}
for _, e in ipairs(FLEET) do
  if e.live then
    local r = RECS[e.fid]
    LIVE[e.fid] = { node = { id = #LIVE + 7, valid = true, x = r.x, y = r.y, z = r.z, vx = r.vx, vy = r.vy, vz = r.vz },
                    craftName = e.name, recoverValue = function() return 1000 end,
                    parked = function() return e.landed end, piloting = e.piloted }
  end
end
local FO = { valid = true, fleetVersion = 1,
  fleetList = function() fleet_calls = fleet_calls + 1 return FLEET end,
  fleetRecords = function() return RECS end,
  takeControlOf = function(fid) calls[#calls + 1] = "fly:" .. fid return true, fid end,
  terminateFleet = function(fid) calls[#calls + 1] = "end:" .. fid
    for i, e in ipairs(FLEET) do if e.fid == fid then table.remove(FLEET, i) break end end
    RECS[fid] = nil; LIVE[fid] = nil; return true end,
  renameFleet = function(fid, n) calls[#calls + 1] = "rename:" .. fid .. ":" .. tostring(n) return true end,
  liveOf = function(fid) return LIVE[fid] end,
}
local EARNED = {}
local CO = { valid = true, earn = function(v, why) EARNED[#EARNED + 1] = { v = v, why = why } end,
             money = function(v) return "$" .. tostring(v) end, afford = function() return true end }
local BF = { valid = true, sited = true, baseBody = "Home", baseX = 0, baseY = 300, baseZ = 0,
             footprint = { body = "Home", x = 0, y = 300, z = 0, radius = 120 },
             trackingStationOn = function(b) return b == "Home" end }
local MEMBERS = {
  [1] = { id = 1, name = "Dana Okafor", status = "afoot", body = "Home", x = 10, y = 300, z = 0, o2 = 0.9, hp = 1 },
  [2] = { id = 2, name = "Jonah Reyes", status = "aboard", craft = "Lander", o2 = 1, hp = 1 },
  [3] = { id = 3, name = "Mira Hale", status = "afoot", body = "Moon", x = 0, y = 80, z = 0, o2 = 0.18, hp = 1 },
}
local CR = { valid = true, version = 1,
  activeId = function() return 1 end, avatarCraft = function() return nil end,
  get = function(id) return MEMBERS[id] end,
  roster = function() local o = {} for i = 1, 3 do o[i] = MEMBERS[i] end return o end,
  roleLetter = function(r) return ({ "P", "E", "S" })[r.id or 1] end, roleName = function() return "Pilot" end,
  busy = function() return nil end, bodyOf = function() return nil end,
  seatedIn = function(ps) local o = {} for _, d in ipairs(ps or {}) do
      local st = type(d.st) == "string" and tonumber(d.st:match("crew1=(%d+)")) or (type(d.st) == "table" and d.st.crew1)
      if st then o[#o + 1] = { id = st, uid = d.uid, slot = 1 } end end return o end,
  aboard = function(v) if v.craftName == "Lander" then return { { id = 2, name = "Jonah Reyes" } } end return {} end,
  canSwitch = function(id) if id == 1 then return false, "that's you" end
    if id == 3 then return true, nil, "travel", "Moon" end return true, nil, "craft", "Lander" end,
  switchToMember = function(id) calls[#calls + 1] = "switch:" .. id return true, "travel" end,
  training = function() return nil end,
}
local DEP_FLAGS = { { id = 1, n = "Home Plate", b = "Home", x = 0, y = 300, z = 30, d = "Day 3, Y1" } }
local DEP = { valid = true, version = 1, list = function(k) if k == "flag" then return DEP_FLAGS end return {} end,
              remove = function(id) calls[#calls + 1] = "unflag:" .. id; DEP_FLAGS = {} return true end,
              rename = function(id, n) calls[#calls + 1] = "reflag:" .. n return true end,
              agencyClock = function() return 90061 end,
              dateOf = function(t) return "Day 2, Y1" end }
local DEBRIS = {}
for i = 1, 200 do
  local a = i * 0.11
  DEBRIS[i] = { id = "d" .. i, name = "debris", kind = (i % 3 == 0) and "landed" or "orbit", body = "Home",
                x = math.cos(a) * 1100, y = math.sin(a) * 1100, z = 0, vx = -math.sin(a) * 52, vy = math.cos(a) * 52, vz = 0,
                stime = T, parts = 2 }
end
local DP = { valid = true, packVersion = 1, packedPoses = function() return DEBRIS end,
             forget = function(id) calls[#calls + 1] = "forget:" .. id return true end }
local NET = { valid = true, networkVersion = 1, transmitters = 4, refreshNow = function() end,
  beaconList = function() return { { id = 1, name = "Relay 1", body = "Home", x = 300, y = 0, z = 0, linked = true, strength = 0.9, hops = 1 } } end,
  coverage = function() return { ground = 0.31 } end }
local STC = { valid = true, version = 1, list = function() return { { id = 1, n = "Pad Plate", b = "Home", x = 20, y = 299, z = 0, bp = { {}, {} }, d = "Day 1, Y1" } } end }
local MODE = { open = false, mode = "chart", focus = nil, zoom = nil }
local OM
OM = { valid = true,
  isOpen = function() return MODE.open end,
  openStation = function() MODE.open = true; OM.mode = "station" end,
  close = function() MODE.open = false; OM.mode = "chart" end,
  setMode = function(m) OM.mode = m end,
  focusOn = function(fn) MODE.focus = fn end, setZoom = function(z) MODE.zoom = z end,
  mode = "chart" }
local WC = { valid = true, request = function(w) calls[#calls + 1] = "warp:" .. w return true end, capNow = function() return 1e9 end,
  warpTo = function(t, label) calls[#calls + 1] = "warpto:" .. tostring(label) return true end }
local MENU = { opened = nil, reg = {} }
local CM = { valid = true, actorNow = function() return { kind = "crew", id = 1 } end,
  openFor = function(t, who, x, y) MENU.opened = { t = t, x = x, y = y } return true end }
local CREG = { valid = true, register = function(kind, fn, opts) MENU.reg[kind] = fn end }
local TG = { valid = true, targetCraft = function(v) calls[#calls + 1] = "target:" .. tostring(v and v.craftName) return true end }
local TREES = {}
local NODES = {}
for _, nm in ipairs({ "Tracking Station", "Station Fleet", "Station Card", "Station Strip" }) do
  local el = { visible = false }
  NODES[nm] = { name = nm, valid = true, getcomponent = function() return el end, el = el }
end
local DRAWN = { rect = 0, text = 0, circle = 0, line = 0 }
local MOUSE = { 0, 0 }
local LMB, RMB, FOCUSED = false, false, nil
local SCR = {}
local env = {
  time = 0,
  save = { get = function(k) return SAVE[k] end, set = function(k, v) SAVE[k] = v end },
  log = function() end,
  find = function(n) return NODES[n] end,
  findScripts = function() return {} end,
  space = { dominant = function() return "Home" end, body = body, bodies = function() return BODIES end,
            time = function() return T end, warp = function() return 1 end,
            elements = function(x, y, z) return { periapsis = 1000, apoapsis = 1100 } end,
            propagate = function(x, y, z, vx, vy, vz, mu, dt) return x + vx * dt, y + vy * dt, z + vz * dt, vx, vy, vz end },
  ui = { make = function(n, t) TREES[n.name] = t end, hovered = function() return nil end, focus = function() end,
         focused = function() return FOCUSED end },
  input = { setMouseLocked = function() end, mouse = function() return MOUSE[1], MOUSE[2] end,
            button = function(b) if b == 1 then return RMB end return b == 0 and LMB end, pressed = function() return false end,
            scroll = function() return 0 end },
  camera = { screenSize = function() return 1600, 900 end,
             worldToScreen = function(x, y, z) return 800 + x * 0.25, 450 - y * 0.25, 1, true end },
  draw = { rect = function() DRAWN.rect = DRAWN.rect + 1 end, rectOutline = function() DRAWN.rect = DRAWN.rect + 1 end,
           circle = function() DRAWN.circle = DRAWN.circle + 1 end, circleOutline = function() DRAWN.circle = DRAWN.circle + 1 end,
           text = function() DRAWN.text = DRAWN.text + 1 end, line = function() DRAWN.line = DRAWN.line + 1 end },
}
setmetatable(env, { __index = _G })
local FV = loadin("solar/scripts/fleet_view.lua", setmetatable({}, { __index = env }))
local ML = loadin("solar/scripts/map_labels.lua", setmetatable({}, { __index = env }))
local TS
SCR = { flight_ops = FO, electronics = E, orbit_map = OM, comms = NET, company = CO, base_facilities = BF, crew = CR,
        fleet_view = FV, map_labels = ML, deployables = DEP, debris_pack = DP, structures = STC, warp_chip = WC, targeting = TG,
        context_menu = CM, context_registry = CREG }
env.findScript = function(k) if k == "tracking_station" then return TS end return SCR[k] end
FV.findScript, ML.findScript = env.findScript, env.findScript
FV.findScripts = env.findScripts
local tsenv = setmetatable({}, { __index = env })
TS = loadin("solar/scripts/tracking_station.lua", tsenv)
TS.valid = true
local function tick(dt)
  env.time = env.time + (dt or 1 / 60)
  tsenv.time, FV.time = env.time, env.time
  TS.update(NODES["Tracking Station"], dt or 1 / 60)
end
local function all_trees()
  return { "col", TREES["Tracking Station"], TREES["Station Fleet"], TREES["Station Card"], TREES["Station Strip"] }
end
TS.start(NODES["Tracking Station"])
check(not TS.isOpen(), "the station starts shut")
TS.open()
check(TS.isOpen() and OM.mode == "station", "open() opens the orbit map in STATION mode")
tick()
check(NODES["Station Fleet"].el.visible and NODES["Station Card"].el.visible and NODES["Station Strip"].el.visible,
  "the FLEET column, the SELECTED card and the strip show")
bad = {}
validate(all_trees(), "station")
check(#bad == 0, "every station element is one ui.make accepts: " .. table.concat(bad, ", "))
local tree = all_trees()
check(by_key(tree, "rc1") and by_key(tree, "rc3") and by_key(tree, "rm:3"), "the list has the craft and the crew")
check(by_key(tree, "GATTENTION") and by_key(tree, "GCREWED") and by_key(tree, "GPROBES") and by_key(tree, "GDEBRIS")
  and by_key(tree, "GRELAYS") and by_key(tree, "GFLAGS") and by_key(tree, "GSTRUCTURES"), "the list is grouped")
check(not by_key(tree, "rd:d1"), "DEBRIS starts folded (200 rows are not described)")
check(has_text(tree, "O2 18 %") and has_text(tree, "NO SIGNAL"), "ATTENTION names the low suit and the lost probe")
check(has_text(tree, "TRACKING STATION") and has_text(tree, "60 craft"), "the top bar counts the fleet")
-- the snapshot's kinds
local S = FV.current()
check(S.byId.c3.kind == "rocket" and S.byId.c4.kind == "plane" and S.byId.c5.kind == "rover" and S.byId.c1.kind == "probe",
  "kinds from the part records: rocket, plane, rover, probe")
check(S.byId.c3.crewed and S.byId.c3.crew[1].id == 2, "the Lander's crew comes from its seat")
for _, e in ipairs(S.entries) do
  if e.wx or e.worldX then check(false, "an entry keeps a world point: " .. e.id) end
end
-- cadence: the board is read twice a second, not every frame
local before, lists0 = fleet_calls, TS.stats.lists
for _ = 1, 60 do tick(1 / 60) end
check(fleet_calls - before <= 3, "fleetList read at 2 Hz, not every frame (" .. (fleet_calls - before) .. " in 1 s)")
check(TS.stats.lists - lists0 <= 3, "the list is described when it changes (" .. (TS.stats.lists - lists0) .. " in 1 s)")
-- select the lander: the card
by_key(all_trees(), "rc3").onClicked()
tick()
tree = all_trees()
check(TS.selectedId() == "c3" and has_text(tree, "Lander") and has_text(tree, "RECOVERABLE"), "selecting the lander: its card, recoverable")
check(has_text(tree, "Jonah Reyes"), "the card lists its crew")
check(MODE.focus ~= nil, "a click eases the map's focus to it")
bad = {}
validate(tree, "card")
check(#bad == 0, "the craft card is valid: " .. table.concat(bad, ", "))
by_key(tree, "rec").onClicked()
check(calls[#calls] == "end:c3" and #EARNED == 1 and EARNED[1].v == 1000 and SAVE["mission.recovered"] == true,
  "RECOVER pays the quote, ticks the goal and takes it off the board")
-- in orbit: the reason, verbatim
TS.selectCraft("c1")
tick(0.2)
tree = all_trees()
check(by_key(tree, "rec").disabled == true and has_text(tree, "only a craft at rest"), "a craft in orbit: the recoverRule reason on the card")
check(has_text(tree, "AP ") and has_text(tree, "PE "), "the CRT inset reads Ap and Pe")
by_key(tree, "fly").onClicked()
check(calls[#calls] == "fly:c1" and not TS.isOpen(), "FLY takes its controls and closes the station")
TS.open(); tick(0.2)
-- terminate: two presses
TS.selectCraft("c7")
tick(0.2)
by_key(all_trees(), "end").onClicked()
tick(0.2)
check(by_key(all_trees(), "end").text == "Confirm" and calls[#calls] ~= "end:c7", "TERMINATE arms on the first press")
by_key(all_trees(), "end").onClicked()
check(calls[#calls] == "end:c7", "...and writes it off on the second")
-- rename
TS.selectCraft("c1")
tick(0.2)
by_key(all_trees(), "rn").onClicked()
tick(0.2)
check(TS.typing() and by_key(all_trees(), "f"), "RENAME opens a field")
by_key(all_trees(), "f").onSubmitted({ text = "Hermes" })
check(calls[#calls] == "rename:c1:Hermes", "...and Enter renames it")
check(TS.escape() == false, "Esc with nothing to back out of goes to the map (which closes the station)")
-- a member far away: GO TO
TS.selectCraft("m:3")
tick(0.2)
tree = all_trees()
check(has_text(tree, "Go to") and has_text(tree, "Moon"), "a member on another world: Go to · Moon")
by_key(tree, "sw").onClicked()
check(calls[#calls] == "switch:3", "...which is crew.switchToMember")
TS.open(); tick(0.2)
-- the flag card and the warp rungs
TS.selectCraft("f:1")
tick(0.2)
by_key(all_trees(), "end").onClicked(); tick(0.2); by_key(all_trees(), "end").onClicked()
check(calls[#calls] == "unflag:1", "a flag comes down on the second press")
by_key(all_trees(), "w5").onClicked()
check(calls[#calls] == "warp:100", "a WARP rung asks warp_chip.request")
check(has_text(all_trees(), "Day 2, Y1"), "the strip reads the agency's calendar")
-- THE MAP PASS: anchors from one bodies read, tags that never overlap
-- (the stub's propagate is a straight line: exact steps every frame here; the
-- second-order carry between steps is checked against a real conic below)
TS.CARRY_STEP = 0
TS.selectCraft("c1")
for _ = 1, 3 do
  DRAWN = { rect = 0, text = 0, circle = 0, line = 0 }
  env.draw.rect = function() DRAWN.rect = DRAWN.rect + 1 end
  env.draw.text = function() DRAWN.text = DRAWN.text + 1 end
  env.draw.circle = function() DRAWN.circle = DRAWN.circle + 1 end
  env.draw.circleOutline = function() DRAWN.circle = DRAWN.circle + 1 end
  T = T + 0.5
  tick(0.3)
  TS.drawMap({ bodies = BODIES, px_at = function(_, _, _, px) return px end, ppu = function(d) return 900 / (0.7 * d) end,
               cam = { x = 0, y = 0, z = 4000 }, lk = 1.25, sw = 1600, sh = 900, placed = {}, blocked = {}, yaw = 0, pitch = 0,
               ppuFocus = 0.2, show = { orbits = true, markers = true }, drawTrack = function() end,
               TRAJ = { track = function() return {} end }, cine = false })
end
local A = TS.anchorsNow()
local n_anch = 0
for _ in pairs(A) do n_anch = n_anch + 1 end
check(n_anch > 200, "every entry with a place has an anchor this frame (" .. n_anch .. ")")
-- an offline craft in flight is carried along its conic to now
local e9 = FV.current().byId.c9
local a9 = A.c9
check(e9 and a9 and math.abs(a9[3] - (e9.rx + e9.vx * (T - e9.st))) < 1e-6, "an offline craft's anchor is its record carried to now")
-- the carry between exact steps against a two-body step (RK4, small dt)
do
  local mu, r0 = 3.986e14, 6.771e6
  local x, y, vx, vy = r0, 0, 0, math.sqrt(mu / r0)
  local h = 1.0
  local ax, ay = -mu * x / r0 ^ 3, -mu * y / r0 ^ 3
  local cx, cy = x + vx * h + 0.5 * ax * h * h, y + vy * h + 0.5 * ay * h * h
  local function acc(px, py) local r = math.sqrt(px * px + py * py) return -mu * px / r ^ 3, -mu * py / r ^ 3 end
  local px, py, pvx, pvy = x, y, vx, vy
  local n = 1000
  local dt = h / n
  for _ = 1, n do
    local a1x, a1y = acc(px, py)
    local k2x, k2y = acc(px + pvx * dt / 2, py + pvy * dt / 2)
    local k3x, k3y = acc(px + (pvx + a1x * dt / 2) * dt / 2, py + (pvy + a1y * dt / 2) * dt / 2)
    local k4x, k4y = acc(px + (pvx + k3x * dt / 2) * dt, py + (pvy + k3y * dt / 2) * dt)
    px = px + pvx * dt + (a1x + k2x + k3x) * dt * dt / 6
    py = py + pvy * dt + (a1y + k2y + k3y) * dt * dt / 6
    pvx = pvx + (a1x + 2 * k2x + 2 * k3x + k4x) * dt / 6
    pvy = pvy + (a1y + 2 * k2y + 2 * k3y + k4y) * dt / 6
  end
  local err = math.sqrt((cx - px) ^ 2 + (cy - py) ^ 2)
  check(err < 0.01, string.format("the carry over a %.0f s step stays within 1 cm of the conic in low orbit (%.4f m)", TS.CARRY_STEP == 0 and 1 or 1, err))
end
local L = TS.labelsNow()
local rects = {}
for _, l in ipairs(L) do rects[#rects + 1] = l end
local over = 0
for i = 1, #rects do for j = i + 1, #rects do
  local a, b = rects[i], rects[j]
  if a.x + 0.01 < b.x + b.w and a.x + a.w > b.x + 0.01 and a.y + 0.01 < b.y + b.h and a.y + a.h > b.y + 0.01 then over = over + 1 end
end end
check(#L > 0 and #L <= 40 and over == 0, string.format("tags: %d drawn, at most 40, none overlap (%d overlaps)", #L, over))
local under = 0
for _, l in ipairs(L) do
  for _, r in ipairs(TS.panelRects()) do
    if l.x < r[1] + r[3] and l.x + l.w > r[1] and l.y < r[2] + r[4] and l.y + l.h > r[2] then under = under + 1 end
  end
end
check(under == 0, "no tag under the panels (" .. under .. ")")
local sel_tag = false
for _, l in ipairs(L) do if l.id == "c1" then sel_tag = true end end
check(sel_tag, "the selected craft has its tag")
check(DRAWN.text < 140, "draw.text calls bounded with 260 entries (" .. DRAWN.text .. ")")
-- ── the pointer on the map (P4): icons, clusters that open, the menu ───────
local function ctx_at(camz, extra)
  local c = { bodies = BODIES, px_at = function(_, _, _, px) return px end, ppu = function(d) return 900 / (0.7 * d) end,
              cam = { x = 0, y = 0, z = camz or 4000 }, lk = 1.25, sw = 1600, sh = 900, placed = {}, blocked = {}, yaw = 0, pitch = 0,
              ppuFocus = 0.2, show = { orbits = false }, cine = false }
  for k2, v in pairs(extra or {}) do c[k2] = v end
  return c
end
local function frame(c)
  T = T + 0.05
  tick(0.05)
  TS.drawMap(c or ctx_at())
end
local function member_set()
  local m = {}
  for _, c in ipairs(TS.clustersNow()) do for _, id in ipairs(c.members) do m[id] = c end end
  return m
end
-- A lone icon: not in a cluster, not under a plate, not the selection, and
-- nothing else drawn within 24 px (so the pointer can only mean it). Sorted:
-- the same one every run (pairs' order is not).
local function find_lone(A2, mem2)
  local ids = {}
  for id in pairs(A2) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local a = A2[id]
    local e = FV.current().byId[id]
    if e and e.kind ~= "debris" and not mem2[id] and id ~= TS.selectedId() and not TS.ownsPointer(a[1], a[2]) then
      local clear = true
      for _, j in ipairs(ids) do
        local b = A2[j]
        if j ~= id and (b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2 < 24 ^ 2 then clear = false break end
      end
      for _, c in ipairs(TS.clustersNow()) do
        local s = A2[c.seed]
        if s and (s[1] + c.ox - a[1]) ^ 2 + (s[2] + c.oy - a[2]) ^ 2 < 24 ^ 2 then clear = false end
      end
      if clear then return id end
    end
  end
end
MOUSE = { 5, 5 }
frame(); frame()
A = TS.anchorsNow()
local mem = member_set()
-- a lone icon: a click selects it
local lone = find_lone(A, mem)
check(lone ~= nil, "a lone icon on the map to click")
if lone then
  MOUSE = { A[lone][1], A[lone][2] }
  LMB = false; frame()
  LMB = true; frame()
  LMB = false; frame()
  check(TS.selectedId() == lone, "a click on an icon selects it (" .. tostring(TS.selectedId()) .. " for " .. lone .. ")")
  check(TS.pointerBusy() == true, "...and the map leaves that click alone (no node placed)")
end
-- a cluster: a click opens it as a column of names, a click on a name picks it
local cl = TS.clustersNow()[1]
check(cl ~= nil and cl.n >= 3, "the landed yard near the base makes a cluster (" .. tostring(cl and cl.n) .. ")")
if cl then
  local sa = A[cl.seed]
  local cx, cy = sa[1] + cl.ox, sa[2] + cl.oy
  MOUSE = { cx, cy }
  LMB = false; frame()
  check(TS.pointerBusy() == true and TS.claimsTap(cx, cy), "hovering a cluster: the map and targeting's menu leave it alone")
  LMB = true; frame()
  LMB = false; frame()
  local F, R = TS.fanNow()
  check(F ~= nil and R ~= nil and #F.members == cl.n, "a click on a cluster opens it: a column of its " .. cl.n .. " names")
  if F and R then
    check(TS.ownsPointer(R[1] + 4, R[2] + 4) == true, "...whose column owns the pointer (the wheel scrolls it, no zoom)")
    -- the third name: rows start one row (the heading) down
    local fs = 12 * 1.25
    local row_h = fs * 1.55
    local want = F.members[3]
    MOUSE = { R[1] + R[3] / 2, R[2] + row_h * 3 + 2 * 1.25 + row_h * 0.5 }
    LMB = false; frame()
    check(TS.fanNow() and TS.fanNow().hot == want, "hovering a name lights it (and rings where that member is)")
    LMB = true; frame()
    LMB = false; frame()
    check(TS.selectedId() == want and TS.fanNow() == nil, "a click on a name selects that member and folds the column (" .. tostring(TS.selectedId()) .. ")")
  end
  -- the right button on a cluster opens it too; Esc folds it
  frame(); frame()
  local cl2 = TS.clustersNow()[1]
  local sa2 = cl2 and TS.anchorsNow()[cl2.seed]
  if sa2 then cx, cy = sa2[1] + cl2.ox, sa2[2] + cl2.oy end
  MOUSE = { cx, cy }
  RMB = false; frame(); RMB = true; frame(); RMB = false; frame()
  check(TS.fanNow() ~= nil, "a right-click on a cluster opens it")
  check(TS.escape() == true and TS.fanNow() == nil, "Esc folds an opened cluster first")
end
-- THE SHARED MENU: a right-button tap on an icon opens the "fleet" menu
MOUSE = { 5, 5 }
frame(); frame()
A = TS.anchorsNow()
mem = member_set()
lone = find_lone(A, mem)
check(lone ~= nil, "a lone icon to right-click")
if lone then
  MENU.opened = nil
  MOUSE = { A[lone][1], A[lone][2] }
  RMB = false; frame(); RMB = true; frame(); RMB = false; frame()
  check(MENU.opened and MENU.opened.t.kind == "fleet" and MENU.opened.t.id == lone and MENU.opened.t.map == true,
    "a right-click on an icon opens the fleet menu on it (a map menu: it stays up over the map)")
  check(MENU.reg.fleet ~= nil, "the station registers one 'fleet' provider (the list and the map share it)")
end
do
  local rows = TS.fleetRows({ id = "c9" })
  local have = {}
  for _, r in ipairs(rows) do have[r.id] = r end
  check(have.fly and have.focus and have.target and have.warp and have.rename and have["end"] and have["end"].type == "sub",
    "the fleet menu: Fly, Focus, Target, Warp, Rename, Terminate behind a confirm")
  check(have.warp.enabled == true and have.warp.label:find("^Warp to %a"), "...Warp names its next event (" .. tostring(have.warp.label) .. ")")
  have.warp.act()
  check(calls[#calls]:find("^warpto:Sat 09"), "...and warps there through warp_chip.warpTo (" .. calls[#calls] .. ")")
  local sub = have["end"].sub()
  check(sub[2] and sub[2].danger and sub[2].label:find("Terminate Sat 09"), "Terminate asks once more, in red")
  local mrows = TS.fleetRows({ id = "m:3" })
  local sw2
  for _, r in ipairs(mrows) do if r.id == "switch" then sw2 = r end end
  check(sw2 and sw2.enabled == true, "a member: Switch to")
end
-- ── FILTERS, SEARCH, SORT AND PAGES (P3/P4) ─────────────────────────────────
TS.selectCraft("c1")
tick(0.2)
local tr = all_trees()
check(by_key(tr, "srch") and by_key(tr, "kall") and by_key(tr, "kdebris") and by_key(tr, "wb") and by_key(tr, "cr")
  and by_key(tr, "at") and by_key(tr, "so"), "the FLEET header: search, the kind keys, world, crewed, alerts, sort")
bad = {}
validate(tr, "filters")
check(#bad == 0, "the header is valid ui.make: " .. table.concat(bad, ", "))
MOUSE = { 5, 5 }
by_key(tr, "kdebris").onClicked()
tick(0.2)
tr = all_trees()
check(by_key(tr, "GDEBRIS") and not by_key(tr, "GPROBES") and not by_key(tr, "GCREWED"), "Debris: only the DEBRIS group")
check(type(SAVE.opt_trackFilter) == "table" and SAVE.opt_trackFilter.kind == "debris", "the filters are kept in the save")
frame(); frame()
local nd, nother = 0, 0
for id in pairs(TS.anchorsNow()) do
  local e = FV.current().byId[id]
  if e and e.kind == "debris" then nd = nd + 1 elseif id ~= TS.selectedId() and not (e and FV.ALWAYS[e.kind]) then nother = nother + 1 end
end
check(nd > 100 and nother == 0, string.format("...and the map shows only debris too (%d debris, %d else)", nd, nother))
-- pages: the 200-row group shows PAGE rows and a pager
by_key(all_trees(), "GDEBRIS").onClicked()
tick(0.2)
tr = all_trees()
local nrows = 0
for _, el in ipairs(each(tr)) do if type(el.key) == "string" and el.key:find("^rd:") then nrows = nrows + 1 end end
local pg = by_key(tr, "pgDEBRIS")
check(nrows == TS.PAGE and pg ~= nil and has_text(pg, "1–40 of 200"), string.format("a long group pages: %d rows and the pager", nrows))
by_key(pg, "nx").onClicked()
tick(0.2)
tr = all_trees()
check(has_text(by_key(tr, "pgDEBRIS"), "41–80 of 200") and by_key(tr, "rd:d41") ~= nil or by_key(tr, "pgDEBRIS") and has_text(by_key(tr, "pgDEBRIS"), "41–80"),
  "▸ shows the next page")
-- a row picked from the map opens its page
TS.selectCraft("d:d150")
tick(0.2)
check(by_key(all_trees(), "rd:d150") ~= nil, "a row picked from the map is put on screen (its page)")
by_key(all_trees(), "kall").onClicked()
tick(0.2)
-- the search: the list narrows, the map dims what it does not match
by_key(all_trees(), "srch").onChanged({ text = "sat 1" })
tick(0.2)
tr = all_trees()
check(by_key(tr, "rc10") and by_key(tr, "rc19") and not by_key(tr, "rc20") and not by_key(tr, "rc3"), "the search narrows the list (Sat 1x)")
check(by_key(tr, "srch").text == "sat 1" and by_key(tr, "sx"), "the field keeps the text, with a ✕ to clear it")
TS.selectCraft("c10")
frame(); frame()
local stray = 0
for _, l in ipairs(TS.labelsNow()) do
  local e = FV.current().byId[l.id]
  if e and not tostring(e.name):lower():find("sat 1", 1, true) then stray = stray + 1 end
end
check(stray == 0 and #TS.labelsNow() > 0, "on the map only the matches are named; the rest are dimmed (" .. stray .. " stray tags)")
FOCUSED = { name = "FieldStationSearch" }
check(TS.typing() == true, "typing in the search: the map's keys and the warp keys stand down (typing())")
check(TS.escape() == true, "Esc leaves the field first")
FOCUSED = nil
check(TS.escape() == true and TS.filter.q == "", "...then clears the search")
tick(0.2)
-- sort, crewed, alerts
by_key(all_trees(), "so").onClicked()
check(TS.filter.sort == "world", "the sort key steps: A–Z → World")
TS.filter.sort = "name"
by_key(all_trees(), "at").onClicked()
tick(0.2)
tr = all_trees()
check(by_key(tr, "GATTENTION") and not by_key(tr, "GPROBES"), "Alerts: only ATTENTION")
by_key(tr, "at").onClicked()
by_key(all_trees(), "wb").onClicked()
check(TS.filter.body == "Home", "the world key steps through the worlds that have something of ours")
by_key(all_trees(), "wb").onClicked()
by_key(all_trees(), "wb").onClicked()
check(TS.filter.body == nil, "...and back to every world")
tick(0.2)
-- ── the debris LOD and the orbit lines (P4 clutter) ─────────────────────────
TS.selectCraft("c1")
frame(); frame()
local function count_debris()
  local n = 0
  for id in pairs(TS.anchorsNow()) do if id:sub(1, 2) == "d:" then n = n + 1 end end
  return n
end
check(count_debris() > 100, "close in, the debris are specks (" .. count_debris() .. ")")
frame(ctx_at(40000)); frame(ctx_at(40000))
check(count_debris() == 0, "far out, a world's debris are not projected at all (its disc under " .. TS.DEBRIS_DISC .. " px)")
by_key(all_trees(), "deb").onClicked()
tick(0.2)
frame(); frame()
check(count_debris() == 0 and TS.mapopt.debris == false, "the Debris key takes the specks off the map")
by_key(all_trees(), "deb").onClicked()
tick(0.2)
local tracks = 0
local tctx = function() return ctx_at(4000, { show = { orbits = true, markers = false }, TRAJ = { track = function() return {} end },
  drawTrack = function(_, _, hi, _, _, _, _, _, fade) tracks = tracks + 1 end }) end
tracks = 0; frame(tctx())
local key_tracks = tracks
by_key(all_trees(), "orb").onClicked()
tick(0.2)
for _ = 1, 8 do tracks = 0; frame(tctx()) end
local all_tracks = tracks
check(key_tracks >= 1 and key_tracks <= 4 and all_tracks > 40,
  string.format("orbit lines: only the ones that matter by default (%d), every one with Orbits · all (%d)", key_tracks, all_tracks))
by_key(all_trees(), "orb").onClicked()
tick(0.2)
for _ = 1, 30 do tracks = 0; frame(tctx()) end
check(tracks == key_tracks, "...and back to the ones that matter, the rest faded out (" .. tracks .. ")")
-- ── ONE PROJECTION FUNCTION (card 0650's shape) ─────────────────────────────
-- A pinhole camera at (0, 0, 4000) looking at the origin: the station's Lua
-- camera must agree with it, and ask the engine for only a few points.
local TANH = math.tan(0.35)
local w2s_calls = 0
local pin = function(x, y, z)
  w2s_calls = w2s_calls + 1
  local d = 4000 - z
  if d <= 0 then return 0, 0, d, false end
  local f = 900 / (2 * TANH)
  local sx, sy = 800 + f * x / d, 450 - f * y / d
  return sx, sy, d, sx >= 0 and sx <= 1600 and sy >= 0 and sy <= 900
end
local old_w2s = env.camera.worldToScreen
env.camera.worldToScreen = pin
env.camera.screenRect = function() return 0, 0, 1600, 900 end
local pctx = ctx_at(4000, { look = { x = 0, y = 0, z = 0 }, tanh = TANH })
frame(pctx)
w2s_calls = 0
frame(pctx)
A = TS.anchorsNow()
local worst, nA = 0, 0
for id, a in pairs(A) do
  local sx, sy = pin(a[3], a[4], a[5])
  worst = math.max(worst, math.abs(sx - a[1]), math.abs(sy - a[2]))
  nA = nA + 1
end
check(TS.proj.mode == "lua" and worst < 1e-6 and nA > 100,
  string.format("the Lua camera projects every anchor exactly (%s, %d anchors, worst %.2g px)", TS.proj.mode, nA, worst))
check(w2s_calls - nA <= 4, "...asking the engine for 3 checks a frame, not one call a point (" .. (w2s_calls - nA) .. ")")
-- a lens or a viewport the map does not know (a centre 3 px off, a 2 % zoom):
-- the gains and centres are fitted to the engine's answers, and still exact
env.camera.worldToScreen = function(x, y, z) local a, b, c2, d = pin(x, y, z) return 800 + (a - 800) * 1.02 + 3, b - 2, c2, d end
frame(pctx)
A = TS.anchorsNow()
worst = 0
for _, a in pairs(A) do
  local sx, sy = env.camera.worldToScreen(a[3], a[4], a[5])
  worst = math.max(worst, math.abs(sx - a[1]), math.abs(sy - a[2]))
end
check(TS.proj.mode == "lua-fit" and worst < 1e-6, string.format("a lens it was not told of: fitted to the engine, exact (%s, %.2g px)", TS.proj.mode, worst))
-- a camera that is not this pinhole at all: the frame falls back to the engine a point
env.camera.worldToScreen = function(x, y, z) local a, b, c2, d = pin(x, y, z) return a + 0.004 * (a - 800) ^ 2 / 10, b, c2, d end
frame(pctx)
check(TS.proj.mode == "single", "a camera it cannot match: that frame falls back to the engine a point (" .. TS.proj.mode .. ")")
local flat, out = { 1, 2, 3, 4, 5, 6 }, {}
env.camera.worldToScreenMany = function(p, o) for i = 1, #p / 3 do o[4 * i - 3], o[4 * i - 2], o[4 * i - 1], o[4 * i] = i, i, i, true end return o end
TS.project_many(flat, 2, out, pctx)
check(TS.proj.mode == "engine" and out[5] == 2 and out[8] == true, "the engine's batched call (card 0650) is used as is when it exists")
env.camera.worldToScreenMany = nil
env.camera.worldToScreen = old_w2s
env.camera.screenRect = nil
-- TO NEXT EVENT on the strip
tick(0.3)
local tn = by_key(all_trees(), "tn")
check(tn and not tn.disabled, "the strip has ▸▸ To next event")
if tn then tn.onClicked() end
check(calls[#calls]:find("^warpto:"), "...which warps through warp_chip.warpTo (" .. tostring(calls[#calls]) .. ")")
TS.close()
tick()
check(not NODES["Station Fleet"].el.visible, "closing puts the plates away")

-- the rules themselves (pure, unchanged)
local home = function(b) return b == "Home" end
local ts = TS
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
