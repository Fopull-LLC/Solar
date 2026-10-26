-- FLAGPROBE: the agency's identity and its flags in the real game, on a NEW
-- save (tools/perf/flagshots.sh; docs/crew-and-items.md §2.5, §7, WS4).
--
--   1. the main menu: an empty slot's NEW GALAXY panel with the agency column
--      (default, a typed name, regenerated + tweaked with the colour chips
--      open, a custom picture from user://emblems); the preview's build time
--   2. CREATE: the new save gets the agency's name and spec, no pixels
--   3. the home world: the emblem build time at load and on a rebuild; a flag
--      planted (through the hand's deploy mode when WS3's item_hand is there,
--      else deployables.place) with its ceremony: driven in, the salute, the
--      photo; two pictures 0.5 s apart for the cloth's motion; it faces
--      downwind
--   4. a pod: its hull plate wears the emblem
--   5. a rename in Settings (emblem.set): the planted flag and the plate
--      repaint without a reload
--   6. the Tracking Station's FLAGS list and its photo
--   7. an airless world, if one can be reached: a flag hanging still
--   8. reload: the flag is still there
--
-- Pictures to user://flagshots/, lines "FLG ". One RESULT line per check.
defaults = { quit = 1, slot = 15, seed = 4242, scale = 4, airless = 1 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("FLG %7.2f g%7.2f " .. fmt, W() - W0, time or 0, ...)) end
local NODE, CO, pending = nil, nil, 0
local function yield() coroutine.yield() end
local function wait_for(fn, tmo, what)
  local t = W() + (tmo or 60)
  while W() < t do local r = fn(); if r then return r end; yield() end
  P("TIMEOUT %s", what or "?")
end
local function hold(secs)
  local acc, last = 0, time
  while acc < secs do
    yield()
    local d = time - last
    last = time
    if d > 0 and d < 1 then acc = acc + d end
  end
end
local function R(name, ok, fmt, ...) P("RESULT %s: %s " .. (fmt or ""), name, ok and "PASS" or "FAIL", ...) end
local function shot(name, ui)
  pending = pending + 1
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = ui ~= false, draws = false }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://flagshots/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("SHOT %s failed %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
end

-- ── the camera ──────────────────────────────────────────────────────────────
-- A free camera placed each frame in its body's frame (the planet moves).
local camwant = nil   -- { body, pos (body-relative), tgt (body-relative) }
local function cam_at(bname, pos, tgt)
  camwant = { body = bname, pos = pos, tgt = tgt }
end
-- A camera held in a node's own frame (worked out again every frame).
local function cam_node(bname, node, lpos, ltgt)
  camwant = { body = bname, node = node, lpos = lpos, ltgt = ltgt }
end
local function cam_off()
  camwant = nil
  local pc = findScript("planet_camera")
  if pc and pc.setFreecam then pc.setFreecam(false) end
end
function lateUpdate(node, dt)
  if not camwant then return end
  local pc = findScript("planet_camera")
  local b = space.body(camwant.body)
  if not (pc and b and pc.setFreecam) then return end
  if camwant.node then
    if not camwant.node.valid then return end
    local bp = vec3(b.x, b.y, b.z)
    camwant.pos = camwant.node:toWorld(camwant.lpos) - bp
    camwant.tgt = camwant.node:toWorld(camwant.ltgt) - bp
  end
  pc.setFreecam(true)
  local fc = pc.freecamState and pc.freecamState()
  if not fc then return end
  local u = camwant.pos:normalized()
  fc.body = camwant.body
  fc.rel = camwant.pos
  local d = camwant.tgt - camwant.pos
  local h = d:flatten(u)
  fc.ref = h:normalized()
  fc.pitch = math.atan2(d:dot(u), h:length())
end

local function up_of(bname, x, y, z)
  local b = space.body(bname)
  return vec3(x - b.x, y - b.y, z - b.z):normalized(), b
end

-- The ground under a point on a body (body-relative world axes) → world point.
local function ground_at(bname, rel)
  local b = space.body(bname)
  local u = rel:normalized()
  local top = vec3(b.x, b.y, b.z) + u * (rel:length() + 60)
  local h = raycast(top.x, top.y, top.z, -u.x, -u.y, -u.z, 400, { ignore = find("Astronaut") })
  if h then return vec3(h.x, h.y, h.z) end
  return nil
end

local function boot_menu()
  NODE.persistent = true
  local s = "slot" .. math.floor(params.slot)
  terrain.deleteSaveDir("saves/" .. s .. "/terrain")
  if save.deleteSlot then save.deleteSlot(s) end
  scene.load("menu")
  yield()
  wait_for(function() return findScript("menu_newsave") and findScript("emblem") end, 30, "the menu")
  hold(0.5)
end

local function emblem() return findScript("emblem") end

local function run()
  -- ── 1. the new-save panel ──
  boot_menu()
  local ns = findScript("menu_newsave")
  ns.openFor(math.floor(params.slot))
  hold(1.0)
  local ed = ns.editor()
  wait_for(function() return ed and ed.tex end, 10, "the preview")
  P("preview build %.1f ms", ed.ms or -1)
  shot("1_newsave_default")
  hold(0.4)
  -- type a name into the field, as the player would
  local field = find("FieldAgencyName")
  if field and ui.focus then ui.focus(field) end
  yield()
  input.simulate { text = "Kestrel Aerospace" }
  hold(0.6)
  if ui.focus then ui.focus(nil) end
  hold(0.4)
  R("typing names the agency", ed.name == "Kestrel Aerospace" and ed.spec.mono == "KA", "%s %s", ed.name, ed.spec.mono)
  shot("2_newsave_named")
  hold(0.3)
  local em = emblem()
  local seed0 = ed.spec.seed
  ed.spec = em.regenerate(ed.spec, ed.name); ed.spec.mono = em.monogram(ed.name); ed.tweaked = true; ed.dirty = true
  ed.spec = em.tweak(ed.spec, "shape", 1)
  ed.spec = em.tweak(ed.spec, "pal", 1)
  ed.pick = "accent"
  ed.spec = em.setColour(ed.spec, "accent", em.CHIPS[13])
  ed.dirty = true
  hold(0.8)
  R("regenerate and tweak", ed.spec.seed ~= seed0, "seed %d → %d, %s, ms %.1f", seed0, ed.spec.seed, ed.spec.shape, ed.ms or -1)
  shot("3_newsave_tweaked")
  hold(0.3)
  ed.pick = nil
  -- a picture of the player's own, from user://emblems
  ed.mode = "files"; ed.files = nil
  hold(0.4)
  local files = em.customFiles()
  P("emblems folder %s: %d file(s)", em.emblemsFolder(), #files)
  local logo = nil
  for _, f in ipairs(files) do if f:find("flag_logo") then logo = f end end
  if logo then
    em.refreshCustom()
    local t0 = W()
    local buf, why = em.loadCustom(logo)
    P("custom picture decoded in %.1f ms: %s", (W() - t0) * 1000, tostring(buf and "ok" or why))
    ed.spec = em.copySpec(ed.spec); ed.spec.image = logo; ed.dirty = true
    hold(0.8)
    shot("4_newsave_custom")
    hold(0.4)   -- a capture renders a frame or two later: keep the state till then
    R("a picture from user://emblems becomes the emblem", buf ~= nil, "%s", logo)
  else
    R("a picture from user://emblems becomes the emblem", false, "no flag_logo in %s", em.emblemsFolder())
  end
  -- back to a generated one for the game
  ed.spec = em.copySpec(ed.spec); ed.spec.image = nil; ed.mode = "gen"; ed.dirty = true
  hold(0.5)
  shot("5_newsave_final")
  hold(0.4)
  local want_name, want_spec = em.editorResult(ed)
  P("creating: %s (%s %s %s)", want_name, want_spec.shape, want_spec.motif, tostring(want_spec.palIndex))
  -- fixed generator knobs so the run is the same every time
  ns.press("create")
  yield()
  -- ── 2. the save ──
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
  end, 300, "the reveal")
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
  local sn, se = save.get("agency.name"), save.get("agency.emblem")
  local pixels = false
  for k, v in pairs(se or {}) do if type(v) == "string" and #v > 200 then pixels = true end end
  R("the save keeps the agency", sn == want_name and type(se) == "table" and se.shape == want_spec.shape and not pixels,
    "%s / %s", tostring(sn), tostring(se and se.shape))
  em = wait_for(function() local e = emblem(); return e and e.tex and e.tex() and e end, 20, "the emblem")
  wait_for(function() return not em.busy() end, 20, "the load build")
  P("at load: built %s ms of work over %s frames; cache load %s ms", tostring(em.lastBuildMs),
    tostring(em.lastBuildFrames), tostring(em.lastLoadMs))
  -- a fresh raster (a spec not in the cache), sliced over frames
  local base_spec = em.spec()
  local works, loads = {}, {}
  for i = 1, 3 do
    local sp2 = em.regenerate(em.spec(), em.name())
    em.set(em.name(), sp2)
    wait_for(function() return not em.busy() end, 20, "a rebuild")
    works[#works + 1] = string.format("%.1f ms/%d fr", em.lastBuildMs or -1, em.lastBuildFrames or 0)
  end
  -- back to the save's own spec: from the cache this time? (the cache keeps
  -- one per slot, so the first rebuild above replaced it: build once more,
  -- then load it again)
  em.set(em.name(), base_spec)
  wait_for(function() return not em.busy() end, 20, "the rebuild")
  local t0 = W()
  em.set(em.name(), base_spec)
  local load_ms = (W() - t0) * 1000
  R("emblem + flag at load ≤ 30 ms (from the cache; rasters sliced 5 ms a frame)", load_ms <= 30,
    "cache load %.1f ms (set() %.1f ms total); rasters: %s", em.lastLoadMs or -1, load_ms, table.concat(works, ", "))
  local dep = wait_for(function() return findScript("deployables") end, 10, "deployables")
  local a = find("Astronaut")
  local bname = space.dominant(a.x, a.y, a.z)
  local u, b = up_of(bname, a.x, a.y, a.z)
  local pc = findScript("planet_camera")
  local f0 = vec3(pc.fwd_x or 1, pc.fwd_y or 0, pc.fwd_z or 0):flatten(u):normalized()
  local rt = f0:cross(u):normalized()
  -- ── 3. a flag on the home meadow, 4 m ahead ──
  local spot = ground_at(bname, vec3(a.x - b.x, a.y - b.y, a.z - b.z) + f0 * 4.0)
  -- keep it in the planet's frame: the world moves metres a tick
  local srel = spot and (spot - vec3(b.x, b.y, b.z))
  local function spot_now()
    local bb = space.body(bname)
    return vec3(bb.x, bb.y, bb.z) + srel
  end
  local fid
  local ih = findScript("item_hand")
  local inv = findScript("inventory")
  if spot and ih and ih.deployAt and inv and inv.addItem then
    pcall(inv.addItem, "astro", "flag", 1)
    pcall(ih.hold, "flag")
    hold(0.6)
    local sw = spot_now()
    local ok, r = pcall(ih.deployAt, sw.x, sw.y, sw.z)
    fid = ok and r or nil
    P("planted through the hand's deploy mode: %s", tostring(r))
  end
  if not fid and spot then
    local sw = spot_now()
    fid = dep.place("flag", bname, sw.x, sw.y, sw.z, { by = 1 })
    P("planted through deployables.place: %s", tostring(fid))
  end
  R("a flag is planted on the home world", fid ~= nil and dep.hasFlagOn(bname), "%s #%s", bname, tostring(fid))
  local fnode = wait_for(function() return dep.nodeOf(fid) end, 10, "the flag's node")
  local fl = fnode and fnode:getScript("flag")
  if fnode and spot then
    local fw = fnode:toWorld(vec3(0, 0, 0))
    spot = spot_now()
    a = find("Astronaut")
    P("flag node at %.1f %.1f %.1f (spot %.1f %.1f %.1f, %.2f m off; astro %.1f m away) parent %s visible %s",
      fw.x, fw.y, fw.z, spot.x, spot.y, spot.z, (fw - spot):length(), (fw - vec3(a.x, a.y, a.z)):length(),
      tostring(fnode.parent and fnode.parent.name), tostring(fnode.visible))
  end
  -- the ceremony from beside the crew
  local frel = srel
  if frel then
    local fu = frel:normalized()
    local mid = frel + fu * 1.2 - f0 * 2.0
    cam_at(bname, frel - f0 * 2.0 + rt * 5.5 + fu * 1.8, mid)
  end
  hold(0.25)
  shot("6_drive", false)
  hold(1.0)
  P("ceremony phase %s", fl and fl.state and fl.state.phase or "?")
  shot("7_salute", false)
  hold(1.6)
  P("photo: %s", fl and fl.state and tostring(fl.state.photo) or "?")
  -- the cloth face-on (the pivot turns with the wind), two pictures half a
  -- second apart
  local pvn = nil
  for _, c in ipairs(fnode and fnode:children() or {}) do if c.name == "Flag Pivot" then pvn = c end end
  if pvn then cam_node(bname, pvn, vec3(1.4, -0.6, 4.6), vec3(0.55, -0.45, 0)) end
  hold(2.0)
  local st = fl and fl.state or {}
  P("wind %.2f m/s still %s swing %.2f sampled %d raw %s", st.wind or -1, tostring(st.still), st.swing or 0, st.sampled or 0,
    tostring(st.raw) .. " err " .. tostring(st.windErr))
  if fl and fl.windHere then
    local v, why = fl.windHere()
    local o = fnode:toWorld(vec3(0, 1.2, 0))
    local w2 = weather.windAt(o)
    P("windHere %s | probe at same point %.2f %.2f %.2f", tostring(why), w2.x, w2.y, w2.z)
  end
  shot("8_wave_a", false)
  hold(0.5)
  shot("8_wave_b", false)
  hold(0.3)
  -- downwind: the pivot's +X along the eased wind
  local pv = nil
  for _, c in ipairs(fnode and fnode:children() or {}) do if c.name == "Flag Pivot" then pv = c end end
  if pv and weather and weather.windAt then
    local o = pv:toWorld(vec3(0, 0, 0))
    local x = (pv:toWorld(vec3(1, 0, 0)) - o):normalized()
    local w = weather.windAt(o + u * 1.2)
    local wf = w:flatten(u)
    local dotv = wf:length() > 0.2 and x:dot(wf:normalized()) or 1
    R("the flag lies downwind", dotv > 0.7, "cos %.2f (wind %.2f m/s)", dotv, wf:length())
  end
  -- ── 4. plates: a pod and a free plate beside the flag ──
  local pod, plate = nil, nil
  if frel then
    local fu = frel:normalized()
    local pp = ground_at(bname, frel + rt * 2.4 + f0 * 0.5)
    local planet = find(bname)
    if pp and planet then
      local lp = planet:toLocal(pp + fu * 0.45)
      spawn("PartPod", pp + fu * 0.45, function(n)
        n.x, n.y, n.z = lp.x, lp.y, lp.z
        n:setUp(fu, (vec3(0, 0, 0) - rt):normalized())
        pod = n
      end, { parent = planet, body = false })
    end
    hold(1.5)
    if pod then
      -- the plate is on the pod's -X flank: look at it from there
      cam_node(bname, pod, vec3(-1.5, 0.35, 0.45), vec3(-0.38, 0.05, 0))
      hold(1.0)
      shot("9_pod_plate", false)
      hold(0.3)
    end
  end
  local pl = nil
  if pod then
    for _, c in ipairs(pod:children()) do if c.name == "Emblem Plate" then pl = c:getScript("emblem_plate") end end
  end
  R("the pod's plate wears the emblem", pl ~= nil and pl.painted() == em.version, "painted %s version %s",
    tostring(pl and pl.painted()), tostring(em.version))
  -- ── 5. a rename in Settings repaints flag and plate live ──
  local v0 = em.version
  local sp = em.specFor("Polaris Works")
  em.set("Polaris Works", sp)
  wait_for(function() return not em.busy() end, 20, "the rename build")
  hold(1.0)
  R("a rename repaints the plate without a reload", pl ~= nil and pl.painted() == em.version and em.version > v0,
    "painted %s version %s", tostring(pl and pl.painted()), tostring(em.version))
  if pod then
    cam_node(bname, pod, vec3(-1.5, 0.35, 0.45), vec3(-0.38, 0.05, 0))
    hold(0.8)
    shot("10_pod_plate_renamed", false)
  end
  if pvn then
    cam_node(bname, pvn, vec3(1.4, -0.6, 4.6), vec3(0.55, -0.45, 0))
    hold(1.0)
    shot("11_flag_renamed", false)
  end
  -- the custom picture on the flag
  local files = em.customFiles()
  local logo = nil
  for _, f in ipairs(files) do if f:find("flag_logo") then logo = f end end
  if logo then
    local s2 = em.spec(); s2.image = logo
    em.set("Kestrel Aerospace", s2)
    hold(1.0)
    shot("12_flag_custom", false)
    hold(0.4)
    R("a custom picture becomes the flag", em.noticeText() == nil, "%s", tostring(em.noticeText()))
    em.set(want_name, want_spec)
    hold(0.5)
  end
  -- ── 6. the Tracking Station ──
  cam_off()
  hold(0.5)
  local ts = findScript("tracking_station")
  local fm = findScript("facility_menu")
  -- walk up to the Tracking Station's dish, as the player does, so the
  -- facility menu owns the panel (and everything that hides under a panel
  -- does)
  local dish = find("FacTracking")
  if dish then
    local astro = find("Astronaut")
    local bb = space.body(bname)
    local dw = dish:toWorld(vec3(0, 0, 0))
    local du = (dw - vec3(bb.x, bb.y, bb.z)):normalized()
    local aw = vec3(astro.x, astro.y, astro.z)
    local side = (aw - dw):flatten(du)
    side = side:length() > 1 and side:normalized() or du:cross(vec3(0, 0, 1)):normalized()
    local g = ground_at(bname, (dw - vec3(bb.x, bb.y, bb.z)) + side * 9.0)
    if g then
      astro.x, astro.y, astro.z = g.x + du.x * 1.2, g.y + du.y * 1.2, g.z + du.z * 1.2
      astro.vx, astro.vy, astro.vz = 0, 0, 0
    end
    hold(1.0)
  end
  if ts then
    if fm and fm.openMenu then fm.openMenu("FacTracking") else ts.open() end
    ts.selectCraft("f:" .. tostring(fid))
    local photo_tex = wait_for(function() return dep.photoTex(fid) end, 15, "the photo texture")
    if not ts.isOpen() then ts.open() end
    hold(0.6)
    P("tracking station open %s", tostring(ts.isOpen()))
    shot("13_tracking_flags")
    hold(0.4)
    R("the Tracking Station row shows the photo", photo_tex ~= nil, "%s", tostring(photo_tex))
    if fm and fm.close then fm.close() else ts.close() end
  end
  hold(0.3)
  -- ── 8. reload: the flag is still there ──
  cam_off()
  if save.flush then save.flush() end
  scene.load("system")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain
  end, 300, "the reload")
  local dep2 = wait_for(function() return findScript("deployables") end, 20, "deployables after reload")
  local back = dep2 and dep2.get(fid)
  local n3 = dep2 and wait_for(function() return dep2.nodeOf(fid) end, 20, "the flag after reload")
  R("reload: the flag is still there", back ~= nil and n3 ~= nil, "%s", back and back.n or "missing")
  -- ── 7. an airless world ──
  dep = findScript("deployables") or dep
  if params.airless == 1 then
    local target = nil
    local bodies = {}
    for _, bb in ipairs(space.bodies and space.bodies() or {}) do bodies[#bodies + 1] = bb end
    for _, bb in ipairs(bodies) do
      local w = save.get("world." .. tostring(bb.name))
      if type(w) == "table" and (w.atmo or 0) < 0.05 and bb.name ~= bname and (bb.radius or 0) > 20 then
        target = bb; break
      end
    end
    if target then
      P("airless world: %s r %.0f", target.name, target.radius)
      local astro = find("Astronaut")
      local pw = findScript("planet_walker")
      -- the day side: toward the star (at the system's origin), tipped a
      -- little so the sun is up but not overhead
      local dir = (vec3(0, 0, 0) - vec3(target.x, target.y, target.z)):normalized()
      dir = (dir + vec3(0, 0.45, 0)):normalized()
      local landed = false
      -- put the crew down there (the walker's own teleport if it has one)
      local tp = target.radius + 80
      local ok = false
      if pw and pw.teleport then ok = pcall(pw.teleport, target.x + dir.x * tp, target.y + dir.y * tp, target.z + dir.z * tp) end
      if not ok then
        astro.x, astro.y, astro.z = target.x + dir.x * tp, target.y + dir.y * tp, target.z + dir.z * tp
        local rb = astro:getcomponent("RigidBody")
        if rb then astro.vx, astro.vy, astro.vz = 0, 0, 0 end
      end
      local g = wait_for(function()
        local tb = space.body(target.name)
        local here = vec3(astro.x - tb.x, astro.y - tb.y, astro.z - tb.z)
        return ground_at(target.name, here:normalized() * (target.radius + 5))
      end, 60, "airless ground")
      if g then
        local tb = space.body(target.name)
        local rel = g - vec3(tb.x, tb.y, tb.z)
        local uu = rel:normalized()
        local ff = uu:cross(vec3(0, 0, 1)):normalized()
        local fid2 = dep.place("flag", target.name, g.x, g.y, g.z, { by = 1, ceremony = false,
          fx = ff.x, fy = ff.y, fz = ff.z })
        local n2 = wait_for(function() return dep.nodeOf(fid2) end, 15, "the airless flag")
        hold(2.0)
        local rr = uu:cross(ff):normalized()
        if n2 then cam_node(target.name, n2, vec3(1.3, 0.7, 3.4), vec3(0.6, 0.75, 0)) end
        hold(2.0)
        local s2 = n2 and n2:getScript("flag")
        R("on an airless world the cloth hangs still", s2 and s2.state and s2.state.still == 1, "still %s wind %.2f",
          tostring(s2 and s2.state and s2.state.still), s2 and s2.state and s2.state.wind or -1)
        shot("14_airless_a", false)
        hold(0.5)
        shot("14_airless_b", false)
      else
        R("on an airless world the cloth hangs still", false, "no ground reached on %s", target.name)
      end
    else
      P("no airless world in this system")
    end
  end
  wait_for(function() return pending == 0 end, 10, "the pictures")
  hold(0.5)
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

function update(node, dt)
  if CO and coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO)
    if not ok then P("ERROR %s", tostring(err)) end
  end
end
