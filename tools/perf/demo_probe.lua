-- DEMO_PROBE: a whole player session, for the pre-playtest QA pass
-- (tools/perf/demo.sh). One `DEMO` line per thing seen, one `RESULT` line per
-- check, a `HITCH` line for every frame over 100 ms after the reveal (with the
-- step it happened in), pictures (with the UI) to user://demoshots/.
--
-- params.usersave = 0 — A NEW PLAYER, from the main menu:
--   1. the menu; an empty slot's NEW GALAXY panel; the agency named by typing;
--      CREATE — the time from CREATE to the reveal (and to the base sited and
--      graded)
--   2. the first view: the objectives card, the crew record, the pack
--   3. the right-click suit menu: helmet off, on
--   4. First Steps: a plant cut with the laser's E, ore dug with the laser
--   5. a flag and a beacon bought at the depot's prices, held, set down
--   6. the VAB: the stock starter (Pod, Parachute, FT-S, Sputter) built in
--      place and LAUNCHed — the first launch's wait, from LAUNCH to the crew
--      in the pod on the pad
--   7. Z + SPACE, a few seconds' climb, the flight HUD; revert to launch
--   8. out of the pod; the Tracking Station; the map; the pause menu
-- params.usersave = 1 — THE PLAYER'S SAVE (a copy, slot 1), as CONTINUE loads
--   it: the crew migration (member #1 owns the old pack), the agency prompt on
--   the objectives card, the pack and the belt, the fleet, the beacons; the
--   HUD, the Tracking Station, the map.
defaults = { quit = 1, slot = 3, usersave = 0, flysecs = 8, rush = 0, walk = 0, seed = 0 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local STEP = "boot"
local function P(fmt, ...) print(string.format("DEMO %7.2f [%s] " .. fmt, W() - W0, STEP, ...)) end
local NODE, CO, pending = nil, nil, 0
local REVEALED = false
local HITCHES = {}
local function yield() coroutine.yield() end
local function wait_for(fn, tmo, what)
  local t = W() + (tmo or 60)
  while W() < t do local r = fn(); if r then return r end; yield() end
  P("TIMEOUT %s", what or "?")
end
local function hold(secs)
  local t = W() + secs
  while W() < t do yield() end
end
local function R(name, ok, fmt, ...) P("RESULT %s: %s " .. (fmt or ""), name, ok and "PASS" or "FAIL", ...) end
local SHOTS = 0
local function shot(name)
  pending = pending + 1
  SHOTS = SHOTS + 1
  local nm = string.format("%02d_%s", SHOTS, name)
  local ok, err = pcall(camera.capture, { w = 1920, h = 1080, ui = true, draws = true }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://demoshots/" .. nm .. ".png", bytes); P("SHOT %s", nm)
    else P("SHOT %s failed %s", nm, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
  hold(0.5)
end
local function key_down(k) input.simulate { key = k, down = true } end
local function key_up(k) input.simulate { key = k, down = false } end
local function tap(k) key_down(k); yield(); yield(); key_up(k); yield() end
local function step(s) STEP = s; P("── %s", s) end

local function world_ready()
  local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
  return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
end
local function astro() return find("Astronaut") end
local function home() local n = save.get("base.body"); return n and space.body(n) end

-- what the objectives card says
local function card()
  local ob = findScript("objectives")
  return ob and ob.headline or "?"
end
local function state_dump(tag)
  local cr, inv, em, co = findScript("crew"), findScript("inventory"), findScript("emblem"), findScript("company")
  local ih = findScript("item_hand")
  local ro = cr and cr.roster and cr.roster() or {}
  local names = {}
  for _, r in ipairs(ro) do names[#names + 1] = string.format("#%s %s (pack %s)", tostring(r.id), tostring(r.name), tostring(r.pack)) end
  P("STATE %s: agency '%s' prompt %s | crew %d: %s | active %s", tag, tostring(em and em.name()), tostring(em and em.needsPrompt and em.needsPrompt()),
    #ro, table.concat(names, ", "), tostring(cr and cr.activeId and cr.activeId()))
  if inv then
    local its = {}
    for _, e in ipairs(inv.itemList and inv.itemList("astro") or {}) do its[#its + 1] = string.format("%s×%s", tostring(e.id or e.name), tostring(e.n or e.count)) end
    P("STATE %s: pack -> %s: %s | items %s | %.1f/%.0f kg", tag, tostring(inv.resolve("astro")), tostring(inv.lineFull and inv.lineFull("astro")),
      table.concat(its, " "), inv.mass("astro") or -1, inv.cap("astro") or -1)
  end
  if ih then
    local b = {}
    for i, e in ipairs(ih.belt and ih.belt() or {}) do b[#b + 1] = string.format("%d:%s", i, tostring(e.id)) end
    P("STATE %s: belt %s; in hand %s; hint '%s'", tag, table.concat(b, " "), tostring(ih.held()), tostring(ih.hint and ih.hint()))
  end
  P("STATE %s: card '%s' | money %s", tag, card(), tostring(co and co.balance and co.balance()))
end

-- ── the right-click menu ────────────────────────────────────────────────────
local function cm() return findScript("context_menu") end
local function rtap(sx, sy)
  input.simulate { mouse = { sx, sy } }
  yield(); yield()
  input.simulate { button = 1, down = true }
  yield(); yield()
  input.simulate { button = 1, down = false }
  yield(); yield(); yield()
end
local function menu_dump(tag)
  local c = cm()
  local out = {}
  local reg = findScript("context_registry")
  for _, e in ipairs(c and c.entries() or {}) do
    local u, why = true, nil
    if reg then u, why = reg.usable(e) end
    out[#out + 1] = string.format("%s%s%s", e.id, e.label ~= "" and (" '" .. e.label .. "'") or "", u and "" or (" (dim: " .. tostring(why) .. ")"))
  end
  P("MENU %s: open %s target %s | %s", tag, tostring(c and c.isOpen()), tostring(c and c.target and c.target.kind), table.concat(out, " ; "))
end

-- ── 1. the menu and the new save ────────────────────────────────────────────
local T = {}
local function new_save()
  step("menu")
  local s = "slot" .. math.floor(params.slot)
  terrain.deleteSaveDir("saves/" .. s .. "/terrain")
  if save.deleteSlot then save.deleteSlot(s) end
  scene.load("menu")
  yield()
  wait_for(function() return findScript("menu_newsave") and findScript("emblem") end, 30, "the menu")
  hold(1.5)
  shot("menu")
  local ns = findScript("menu_newsave")
  ns.openFor(math.floor(params.slot))
  hold(1.0)
  local ed = ns.editor()
  local field = find("FieldAgencyName")
  if field and ui.focus then ui.focus(field) end
  yield()
  input.simulate { text = "Kestrel Aerospace" }
  hold(0.6)
  if ui.focus then ui.focus(nil) end
  hold(0.6)
  -- a fixed galaxy (seed=N): typed on the keyboard as the panel takes it
  if (params.seed or 0) > 0 then
    for ch in tostring(math.floor(params.seed)):gmatch("%d") do tap(ch); yield() end
    hold(0.3)
    P("typed seed %d", math.floor(params.seed))
  end
  R("new-save: typing names the agency", ed and ed.name == "Kestrel Aerospace", "%s", tostring(ed and ed.name))
  shot("newsave_named")
  step("load")
  T.create = W()
  ns.press("create")
  yield()
  local seen = {}
  wait_for(function()
    local gm, bf = findScript("game_manager"), findScript("base_facilities")
    if gm and (gm.loading or gm.curtain) and not seen.loading then seen.loading = W() - T.create; P("LOAD loading/curtain seen at %.1f s", seen.loading) end
    if seen.loading and gm and not gm.curtain and not gm.loading and not seen.reveal then seen.reveal = W() - T.create; P("LOAD reveal at %.1f s", seen.reveal) end
    if bf and bf.sited and not seen.sited then seen.sited = W() - T.create; P("LOAD sited at %.1f s", seen.sited) end
    if seen.reveal and not seen.firstshot then seen.firstshot = true; REVEALED = true end
    if seen.sited and bf and bf.grading and not bf.grading() and not seen.graded then seen.graded = W() - T.create; P("LOAD graded at %.1f s", seen.graded) end
    -- rush=1: the player who runs for the VAB the moment the curtain lifts
    return seen.reveal and (seen.graded or (params.rush or 0) > 0)
  end, 300, "the reveal and the grading")
  T.reveal, T.sited, T.graded = seen.reveal, seen.sited, seen.graded
  P("LOAD new save: reveal %.1f s, sited %s s, graded %s s", seen.reveal or -1, tostring(seen.sited), tostring(seen.graded))
  local em = findScript("emblem")
  R("new save keeps the typed agency", em and em.name() == "Kestrel Aerospace", "%s", tostring(em and em.name()))
end

local function user_save()
  step("load")
  -- as the menu's CONTINUE does (menu_slot.clicked): the slot, then the system
  scene.load("menu")
  yield()
  wait_for(function() return findScript("menu_newsave") end, 30, "the menu")
  hold(1.5)
  shot("menu_user")
  T.create = W()
  save.slot("slot1")
  scene.load("system")
  yield()
  local seen = {}
  wait_for(function()
    local gm, bf = findScript("game_manager"), findScript("base_facilities")
    if gm and (gm.loading or gm.curtain) then seen.loading = true end
    if seen.loading and gm and not gm.curtain and not gm.loading and not seen.reveal then seen.reveal = W() - T.create; P("LOAD reveal at %.1f s", seen.reveal); REVEALED = true end
    if bf and bf.sited and not seen.sited then seen.sited = W() - T.create end
    if seen.sited and bf and bf.grading and not bf.grading() and not seen.graded then seen.graded = W() - T.create end
    return seen.reveal and seen.graded
  end, 300, "the reveal")
  T.reveal, T.sited, T.graded = seen.reveal, seen.sited, seen.graded
  P("LOAD player's save: reveal %.1f s, sited %s s, graded %s s", seen.reveal or -1, tostring(seen.sited), tostring(seen.graded))
end

-- ── 3. the suit menu ────────────────────────────────────────────────────────
local function suit_menu()
  step("suit menu")
  local a = astro()
  local c = cm()
  local s = findScript("suit")
  if not (a and c) then R("suit menu", false, "no crew / context_menu"); return end
  local up = a.up or vec3(0, 1, 0)
  local sx, sy = camera.worldToScreen(a.worldX + up.x * 0.3, a.worldY + up.y * 0.3, a.worldZ + up.z * 0.3)
  rtap(sx, sy)
  R("a right tap on the crew opens the suit menu", c.isOpen() and c.target and c.target.kind == "astro", "at %.0f,%.0f target %s",
    sx or -1, sy or -1, tostring(c.target and c.target.kind))
  if not c.isOpen() then
    c.openFor({ kind = "astro", node = a, pack = "astro", label = "Crew", wx = a.worldX, wy = a.worldY, wz = a.worldZ }, nil)
  end
  menu_dump("suit")
  shot("suit_menu")
  local before = s and s.helmetOn()
  local ok1 = c.press("helmet")
  hold(2.5)
  local mid = s and s.helmetOn()
  if not c.isOpen() then rtap(sx, sy) end
  menu_dump("suit, helmet off")
  shot("helmet_off")
  local ok2 = c.press("helmet")
  hold(2.5)
  local after = s and s.helmetOn()
  R("helmet off and on from the menu", before == true and mid == false and after == true, "%s → %s → %s (presses %s %s)",
    tostring(before), tostring(mid), tostring(after), tostring(ok1), tostring(ok2))
  if c.isOpen() then c.close() end
  hold(0.5)
end

-- ── 4. First Steps: a plant, some ore ───────────────────────────────────────
local function face_dir(d)
  local pc = findScript("planet_camera")
  if pc and pc.face then pc.face(d.x, d.y, d.z, -0.35) end
end
local function first_steps()
  step("first steps")
  local a = astro()
  local ih, tb, ff = findScript("item_hand"), findScript("tool_belt"), findScript("flora_field")
  local mi = findScript("missions")
  if not (a and ih and tb and ff) then R("first steps", false, "missing scripts"); return end
  pcall(ih.hold, "laser")
  hold(1.0)
  P("in hand %s, tool %s, gate %s", tostring(ih.held()), tostring(tb.toolId and tb.toolId()), tostring(tb.gate))
  -- the nearest plant in a sweep round the crew (12 bearings, out to 60 m)
  local b = home()
  local u = vec3(a.x - b.x, a.y - b.y, a.z - b.z):normalized()
  local ref = u:cross(vec3(0, 0, 1)):normalized()
  local plant, pd = nil, nil
  for _, r in ipairs({ 6, 12, 20, 30, 45, 60 }) do
    for k = 0, 11 do
      local ang = k * math.pi / 6
      local t = ref * math.cos(ang) + u:cross(ref) * math.sin(ang)
      local p = vec3(a.x, a.y, a.z) + t * r
      local h = ff.nearestPlant(p.x + u.x * 1.5, p.y + u.y * 1.5, p.z + u.z * 1.5, -u.x, -u.y, -u.z, 6.0, 0.9, 3.0)
      if h and h.rec then plant, pd = h, t * r; break end
    end
    if plant then break end
  end
  local cut_ok = false
  local inv = findScript("inventory")
  local m0 = inv and inv.mass("astro") or 0
  local rec_ = plant and plant.rec
  local function goal(k) local l = (mi and mi.progGoalLines and mi.progGoalLines("first_steps") or {})[k] or ""; return l:sub(1, 3) == "✓" end
  local prel = rec_ and vec3(rec_.rx, rec_.ry, rec_.rz)
  if prel then
    -- stand 2.2 m short of the plant's root, on the line from where the crew is
    local bb = home()
    local pu = prel:normalized()
    local dir = (prel - vec3(a.x - bb.x, a.y - bb.y, a.z - bb.z)):flatten(pu):normalized()
    local st = prel - dir * 2.2 + pu * 1.2
    a.x, a.y, a.z = bb.x + st.x, bb.y + st.y, bb.z + st.z
    a.vx, a.vy, a.vz = 0, 0, 0
    hold(2.0)
    face_dir(dir)
    hold(0.5)
    local hh = plant.height or 1
    for _ = 1, 24 do
      local b3 = home()
      local eye = vec3(a.x, a.y, a.z) + pu * 0.6
      local tgt = vec3(b3.x, b3.y, b3.z) + prel + pu * (hh * 0.4)
      local d = tgt - eye
      tb.sim = { keys = { e = true }, aim = { eye.x, eye.y, eye.z, d.x, d.y, d.z } }
      hold(0.5)
      if goal(1) then cut_ok = true; break end
    end
    shot("cutting")
    tb.sim = { keys = { e = false } }
    hold(0.5)
    tb.sim = nil
  end
  local lines = mi and mi.progGoalLines and mi.progGoalLines("first_steps") or {}
  R("First Steps: cut a plant (laser, E held)", cut_ok or goal(1), "plant %s (%s); pack %.1f → %.1f kg; goals: %s",
    tostring(plant ~= nil), tostring(rec_ and rec_.sp and rec_.sp.name), m0, inv and inv.mass("astro") or -1, table.concat(lines, " | "))
  -- ore: dig the natural ground here (off the base's slabs) with LMB
  local ore_ok = false
  for i = 1, 30 do
    local bb = home()
    local uu = vec3(a.x - bb.x, a.y - bb.y, a.z - bb.z):normalized()
    local f = uu:cross(vec3(0, 0, 1)):normalized()
    local eye = vec3(a.x, a.y, a.z) + uu * 0.6
    local tgt = vec3(a.x, a.y, a.z) + f * (3.0 + (i % 4) * 0.3) - uu * 1.6
    local d = tgt - eye
    tb.sim = { btn = { [0] = true }, aim = { eye.x, eye.y, eye.z, d.x, d.y, d.z } }
    hold(0.4)
    tb.sim = { btn = { [0] = false }, aim = { eye.x, eye.y, eye.z, d.x, d.y, d.z } }
    hold(0.2)
    if goal(2) then ore_ok = true; break end
  end
  tb.sim = nil
  shot("after_digging")
  lines = mi and mi.progGoalLines and mi.progGoalLines("first_steps") or {}
  R("First Steps: mine some ore (laser LMB)", ore_ok, "goals: %s; pack %s", table.concat(lines, " | "), tostring(inv and inv.lineFull("astro")))
  local done = save.get("prog.done")
  P("prog.done %s; card '%s'", type(done) == "table" and tostring(done.first_steps) or tostring(done), card())
  pcall(ih.hold, nil)
  hold(1.0)
end

-- ── 5. a flag and a beacon ──────────────────────────────────────────────────
local function ground_ahead(dist)
  local a = astro()
  local b = home()
  local u = vec3(a.x - b.x, a.y - b.y, a.z - b.z):normalized()
  local pc = findScript("planet_camera")
  local f = vec3(pc.fwd_x or 1, pc.fwd_y or 0, pc.fwd_z or 0):flatten(u)
  if f:length() < 0.1 then f = u:cross(vec3(0, 0, 1)) end
  f = f:normalized()
  local p = vec3(a.x, a.y, a.z) + f * dist + u * 3
  local h = raycast(p.x, p.y, p.z, -u.x, -u.y, -u.z, 12, { ignore = a })
  return h and vec3(h.x, h.y, h.z) or nil
end
local function deploy_items()
  step("flag and beacon")
  local inv, ih, dep, cm_ = findScript("inventory"), findScript("item_hand"), findScript("deployables"), findScript("comms")
  local okf, whyf = inv.buyItem("astro", "flag", 1)
  local okb, whyb = inv.buyItem("astro", "beacon", 1)
  P("bought a flag %s (%s), a beacon %s (%s)", tostring(okf), tostring(whyf), tostring(okb), tostring(whyb))
  state_dump("with flag and beacon")
  pcall(ih.hold, "flag")
  hold(1.2)
  shot("flag_in_hand")
  local nflags = #(dep.list and dep.list("flag") or {})
  local fid, why
  for k = 1, 4 do
    local g = ground_ahead(2.5 + k)
    if g then fid, why = ih.deployAt(g.x, g.y, g.z) end
    if fid then break end
    P("flag refused at %d m: %s", 2 + k, tostring(why))
    hold(0.3)
  end
  hold(3.5)
  shot("flag_planted")
  R("plant a flag from the hand", fid ~= nil and #(dep.list("flag") or {}) == nflags + 1, "%s %s", tostring(fid), tostring(why))
  hold(2.0)
  pcall(ih.hold, "beacon")
  hold(1.2)
  local before = cm_ and cm_.beaconList and #cm_.beaconList() or nil
  local bid, bwhy
  local a = astro()
  local pc = findScript("planet_camera")
  -- turn round: the flag is ahead
  if pc and pc.face then local f = vec3(-(pc.fwd_x or 1), -(pc.fwd_y or 0), -(pc.fwd_z or 0)); pc.face(f.x, f.y, f.z, -0.3) end
  hold(0.8)
  for k = 1, 4 do
    local g = ground_ahead(2.5 + k)
    if g then bid, bwhy = ih.deployAt(g.x, g.y, g.z) end
    if bid then break end
    P("beacon refused at %d m: %s", 2 + k, tostring(bwhy))
    hold(0.3)
  end
  hold(2.5)
  shot("beacon_set")
  R("set down a beacon from the hand", bid ~= nil and inv.itemCount("astro", "beacon") == 0, "%s %s; pack beacons %d",
    tostring(bid), tostring(bwhy), inv.itemCount("astro", "beacon"))
  pcall(ih.hold, nil)
  hold(0.5)
end

-- ── 6/7. the VAB, the first launch, a flight, the revert ───────────────────
local function rec(uid, id, x, y, z, o)
  o = o or {}
  return { uid = uid, id = id, x = x, y = y, z = z, yaw = 0, pitch = 0, roll = 0,
           parent = o.parent or 0, att = o.att or "", sym = 0, mir = "", stage = o.stage or 0 }
end
local function starter_bp()
  return { rec(1, "engineS", 0, 0.65, 0), rec(2, "tankS", 0, 1.8, 0, { parent = 1, att = "top" }),
           rec(3, "pod", 0, 2.7, 0, { parent = 2, att = "top" }), rec(4, "chute", 0, 3.27, 0, { parent = 3, att = "top" }) }
end
local function pilot()
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.piloting and v.node and v.node.valid then return v end
  end
end
local function vab_launch()
  step("vab")
  local vab = wait_for(function() return find("VabInterior") end, 60, "the VAB")
  local a = astro()
  if not vab then R("first launch", false, "no VAB"); return end
  if (params.walk or 0) > 0 then
    -- WALK there as a player does (no teleport): face the VAB's door spot
    -- each frame and hold W until the door prompt comes up (60 s at most)
    local fm0 = findScript("facility_menu")
    local pc = findScript("planet_camera")
    local tw = W()
    key_down("w")
    while W() - tw < 60 do
      local p = vab:toWorld(vec3(0, 1.4, 14))
      local d = p - vec3(a.x, a.y, a.z)
      if pc and pc.face then pc.face(d.x, d.y, d.z, -0.2) end
      if (fm0 and fm0.prompting and fm0.prompting()) and d:length() < 8 then break end
      yield()
    end
    key_up("w")
    P("walked to the VAB in %.1f s (prompt %s)", W() - tw, tostring(fm0 and fm0.prompting and fm0.prompting()))
    hold(1.0)
  else
    local p = vab:toWorld(vec3(0, 1.4, 14))
    a.x, a.y, a.z = p.x, p.y, p.z
    a.vx, a.vy, a.vz = 0, 0, 0
    hold(2.5)
  end
  local fm = findScript("facility_menu")
  P("door prompt %s; card '%s'", tostring(fm and fm.prompting and fm.prompting()), card())
  shot("vab_door")
  local te = W()
  tap("e")
  local BH = wait_for(function() local bh = findScript("build_host"); return bh and bh.state == "building" and bh end, 20, "the builder")
  if not BH then if fm then fm.openMenu("FacHangar"); fm.action() end
    BH = wait_for(function() local bh = findScript("build_host"); return bh and bh.state == "building" and bh end, 30, "the builder (menu)") end
  P("in the builder %.1f s after E (enterMs %s)", W() - te, tostring(BH and BH.enterMs))
  local B = findScript("builder")
  if not (BH and B) then R("first launch", false, "no builder"); return end
  hold(1.5)
  shot("builder_empty")
  local bp = starter_bp()
  save.set("shipyard.blueprint", { parts = bp })
  B.reload()
  wait_for(function() return not (B.loadProgress and B.loadProgress()) and (B.partCount or 0) >= #bp end, 60, "the blueprint")
  hold(1.0)
  shot("builder_starter")
  if B.launchSite and B.launchSite() ~= "pad" and B.toggleLaunchSite then B.toggleLaunchSite() end
  step("first launch")
  local co = findScript("company")
  local m0 = co and co.balance and co.balance()
  local tl = W()
  B.doLaunch()
  hold(0.6)
  if BH.state == "building" then P("LAUNCH again (still building: %s)", tostring(B.launchBlock and B.launchBlock())); B.doLaunch() end
  local vs = findScript("vessel_spawner")
  local waits = {}
  local vc = wait_for(function()
    if vs and vs.waitingFor and not waits[vs.waitingFor] then waits[vs.waitingFor] = W() - tl; P("spawner waiting for: %s (+%.1f s)", vs.waitingFor, W() - tl) end
    local v = pilot()
    if v then local i = assembly.info(v.node); if i and i.anchored and #i.parts >= #bp then return v end end
  end, 240, "the starter on the pad")
  T.launch = W() - tl
  R("the first launch goes", vc ~= nil, "%.1f s from LAUNCH to the crew in the pod on the pad (money %s → %s)", T.launch, tostring(m0),
    tostring(co and co.balance and co.balance()))
  if not vc then return end
  hold(1.5)
  shot("on_the_pad")
  step("flight")
  local vn = vc.node
  local b = home()
  local function alt() local i = assembly.info(vn); local r = (i.com - vec3(b.x, b.y, b.z)):length(); return r - b.radius end
  b = home()
  local a0 = alt()
  tap("z"); hold(0.3); tap("space"); hold(1.0)
  if assembly.info(vn).anchored then P("SPACE did not release the clamps"); vc.releaseClamps() end
  local tf = W()
  local shotdone = false
  while W() - tf < params.flysecs do
    yield()
    b = home()
    if not shotdone and W() - tf > 3 then shot("climbing"); shotdone = true end
  end
  b = home()
  local climbed = alt() - a0
  R("the starter climbs", climbed > 30, "%.0f m in %.0f s", climbed, params.flysecs)
  tap("x")
  hold(0.5)
  tap("m")
  hold(2.0)
  shot("map_in_flight")
  tap("m")
  hold(1.0)
  step("revert")
  local okq, why = vs.revertQuote and vs.revertQuote()
  P("revert quote %s %s", tostring(okq), tostring(why))
  local tr = W()
  local okr, whyr = vs.revertToLaunch()
  local vc2 = wait_for(function() local v = pilot(); if v and v.node ~= vn then local i = assembly.info(v.node); if i and i.anchored then return v end end end, 120, "the revert")
  R("revert to launch", okr and vc2 ~= nil, "%s %s, %.1f s", tostring(okr), tostring(whyr), W() - tr)
  hold(1.5)
  shot("reverted")
  step("out of the pod")
  tap("f")
  local pw = findScript("planet_walker")
  wait_for(function() return pw and pw.onFoot end, 20, "on foot")
  hold(2.0)
  R("out of the pod after the revert", pw and pw.onFoot, "")
  shot("on_foot_by_pad")
end

-- ── 8. the Tracking Station, the map, the pause menu ───────────────────────
local function tracking()
  step("tracking")
  local fm, ts = findScript("facility_menu"), findScript("tracking_station")
  local dish = find("FacTracking")
  local a = astro()
  if dish and a then
    local b = home()
    local dw = dish:toWorld(vec3(0, 0, 0))
    local du = (dw - vec3(b.x, b.y, b.z)):normalized()
    local side = (vec3(a.x, a.y, a.z) - dw):flatten(du)
    side = side:length() > 1 and side:normalized() or du:cross(vec3(0, 0, 1)):normalized()
    local p = dw + side * 9.0 + du * 3
    local h = raycast(p.x, p.y, p.z, -du.x, -du.y, -du.z, 20, { ignore = a })
    if h then a.x, a.y, a.z = h.x + du.x * 1.2, h.y + du.y * 1.2, h.z + du.z * 1.2; a.vx, a.vy, a.vz = 0, 0, 0 end
    hold(1.5)
  end
  if fm and fm.openMenu then fm.openMenu("FacTracking") end
  hold(1.0)
  if ts and not ts.isOpen() and fm.action then fm.action() end
  hold(1.0)
  R("the Tracking Station opens", ts and ts.isOpen(), "")
  shot("tracking")
  if fm and fm.close then fm.close() end
  if ts and ts.isOpen() then ts.close() end
  hold(1.0)
  step("map")
  tap("m")
  hold(2.5)
  local om = findScript("orbit_map")
  R("the map opens on foot", om and om.isOpen and om.isOpen(), "")
  shot("map_on_foot")
  tap("m")
  hold(1.0)
  step("pause")
  tap("escape")
  hold(1.5)
  shot("pause_menu")
  tap("escape")
  hold(1.0)
end

local function user_checks()
  step("user checks")
  local cr, inv, em = findScript("crew"), findScript("inventory"), findScript("emblem")
  state_dump("player's save")
  local ro = cr and cr.roster() or {}
  local m1 = ro[1]
  R("crew migration: member #1 owns the old pack", m1 ~= nil and inv.count("astro", "regolith") >= 2 and inv.itemCount("astro", "laser") == 1
    and inv.itemCount("astro", "gravgun") == 1, "#%s %s pack %s; regolith %s, laser %s, gravgun %s", tostring(m1 and m1.id), tostring(m1 and m1.name),
    tostring(m1 and m1.pack), tostring(inv.count("astro", "regolith")), tostring(inv.itemCount("astro", "laser")), tostring(inv.itemCount("astro", "gravgun")))
  R("agency prompt for an older save", em and em.needsPrompt() and card():find("You fly for", 1, true) ~= nil, "name '%s', card '%s'", tostring(em and em.name()), card())
  local fo = findScript("flight_ops")
  local fl = fo and fo.fleetList and fo.fleetList() or {}
  local cm_ = findScript("comms")
  P("fleet %d craft; beacons in save %d; comms relays %s", #fl, #(save.get("comms.beacons") or {}), tostring(cm_ and cm_.beaconList and #cm_.beaconList()))
  shot("user_hud")
  hold(3)
  state_dump("player's save +3 s")
  shot("user_hud_card")
end

local function run()
  NODE.persistent = true
  if (params.usersave or 0) > 0 then user_save() else new_save() end
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
  step("first view")
  hold(1.0)
  shot("reveal")
  state_dump("reveal")
  if (params.usersave or 0) > 0 then
    user_checks()
    suit_menu()
    tracking()
  elseif (params.rush or 0) > 0 then
    local bf = findScript("base_facilities")
    P("RUSH: straight to the VAB; base sited %s grading %s", tostring(bf and bf.sited), tostring(bf and bf.grading and bf.grading()))
    vab_launch()
  else
    hold(4.0)
    shot("first_view_4s")
    state_dump("+5 s")
    suit_menu()
    first_steps()
    state_dump("after first steps")
    deploy_items()
    vab_launch()
    tracking()
  end
  step("end")
  local worst = {}
  table.sort(HITCHES, function(x, y) return x[1] > y[1] end)
  for i = 1, math.min(12, #HITCHES) do worst[#worst + 1] = string.format("%.0f ms @%s", HITCHES[i][1], HITCHES[i][2]) end
  P("HITCHES %d frames over 100 ms after the reveal; worst: %s", #HITCHES, table.concat(worst, ", "))
  P("TIMES reveal %s s, graded %s s, first launch %s s", tostring(T.reveal), tostring(T.graded), tostring(T.launch))
end

function start(node)
  NODE = node
  CO = coroutine.create(function()
    local ok, err = pcall(run)
    if not ok then P("ERROR %s", tostring(err)) end
    wait_for(function() return pending == 0 end, 10, "pending shots")
    P("DONE")
    if params.quit == 1 and app and app.quit then app.quit() end
  end)
end

local LASTW = nil
function update(node, dt)
  local now = W()
  if LASTW and REVEALED then
    local ms = (now - LASTW) * 1000
    if ms > 100 then HITCHES[#HITCHES + 1] = { ms, STEP }; P("HITCH %.0f ms", ms) end
  end
  LASTW = now
  if CO and coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO)
    if not ok then P("ERROR %s", tostring(err)) end
  end
end
