-- SUITSHOTS: the crew's EVA suit in the game, on a NEW save (tools/perf/suitshots.sh).
-- Third person front / side / back / quarter / close with the helmet on; the
-- helmet API (what it says here and on an airless body), the helmet coming
-- off (the hands at the neck ring) and the head under it; first person
-- bare-headed; the left shoulder driven through abduction and flexion by arm
-- IK; a walk; the visor raised; the gloves close up; a crouch (the root
-- lowered, the walker's foot IK bending the knees); and the suit's cost: the
-- GPU passes and the CPU's render and animation buckets with the astronaut
-- framed, shown against hidden (`perf`). Pictures to user://suitshots/,
-- lines "SUS ".
defaults = { quit = 1, slot = 7, seed = 4242, scale = 4, sweep = 1, walk = 1, seat = 1, perf = 1, crouch = 1, onlyperf = 0,
             lod = 1, fptool = 1, night = 1 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("SUS %7.2f " .. fmt, W() - W0, ...)) end
local NODE, CO, pending = nil, nil, 0
local function yield() coroutine.yield() end
local function wait_for(fn, tmo, what)
  local t = W() + tmo
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

local function shot(name)
  pending = pending + 1
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = false, draws = true }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://suitshots/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("SHOT %s failed %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
end

local function boot()
  local s = "slot" .. math.floor(params.slot)
  NODE.persistent = true
  -- exactly what the new-save panel's CREATE does (menu_newsave.lua)
  terrain.deleteSaveDir("saves/" .. s .. "/terrain")
  if save.deleteSlot then save.deleteSlot(s) end
  save.slot(s)
  save.set("g_seed", math.floor(params.seed))
  for k, v in pairs({ g_planets = 3, g_moonchance = 0.6, g_atmo = 0.8, g_caves = 1.0, g_minorbit = 60000, g_spacing = 2.2,
                      g_radmin = 600, g_radmax = 950, g_gravmin = 3.5, g_gravmax = 8.5, g_star = 1.0 }) do save.set(k, v) end
  save.set("g_scale", math.floor(params.scale))
  scene.load("system")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
  end, 240, "the reveal")
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
end

local function main()
  boot()
  hold(3.0)
  local cam, su, pw = findScript("planet_camera"), findScript("suit"), findScript("planet_walker")
  local b = space.body(save.get("base.body"))
  P("world %s, suit script %s, walker onFoot %s", tostring(b and b.name), tostring(su ~= nil), tostring(pw and pw.onFoot))
  local function crew() return find("Astronaut") end
  local function model()
    for _, c in ipairs(crew():children()) do if c.name == "AstroModel" then return c end end
  end
  local function bone(n) local v = model():bonePos(n); return v end
  local function frame()
    local l = (bone("Upperarm.Left") - bone("Upperarm.Right")):normalized()
    local u = (bone("Head") - bone("Hip")):normalized()
    local f = l:cross(u):normalized()
    return l, u, f
  end
  -- the free camera at `pos` looking at `tgt` (world, this frame)
  local function cam_at(pos, tgt)
    local bn = find(b.name)
    local a = crew()
    local uu = vec3(a.x - bn.x, a.y - bn.y, a.z - bn.z):normalized()
    cam.setFreecam(true)
    local fc = cam.freecamState()
    fc.body = b.name
    fc.rel = pos - vec3(bn.x, bn.y, bn.z)
    local d = tgt - pos
    local h = d:flatten(uu)
    fc.ref = h:normalized()
    fc.pitch = math.atan2(d:dot(uu), h:length())
  end
  -- a view: `side` along the crew's left, `fwd` ahead of them, `up`, from
  -- the target bone (+ `lift` up), held for `n` frames then shot
  local function view(name, tb, side, fwd, up, lift, n)
    for _ = 1, (n or 24) do
      local l, u, f = frame()
      local t = bone(tb) + u * (lift or 0)
      cam_at(t + l * side + f * fwd + u * up, t)
      yield()
    end
    shot(name)
    for _ = 1, 3 do
      local l, u, f = frame()
      local t = bone(tb) + u * (lift or 0)
      cam_at(t + l * side + f * fwd + u * up, t)
      yield()
    end
  end
  local function tour(tag)
    view(tag .. "_front", "Back", 0.25, 3.0, 0.15, -0.2)
    view(tag .. "_side", "Back", 3.0, 0.15, 0.15, -0.2)
    view(tag .. "_back", "Back", -0.6, -2.9, 0.4, -0.2)
    view(tag .. "_quarter", "Back", 2.0, 2.2, 0.4, -0.2)
    view(tag .. "_close", "Head", 0.35, 1.05, 0.05, 0.12)
  end

  -- ── the suit's cost: the same framing, the astronaut shown then hidden ──
  if params.perf > 0 then
    local function sample(tag, n)
      perf.enable(false); perf.enable(true)
      local acc, cnt = {}, 0
      for _ = 1, n do
        local l, u, f = frame()
        local t = bone("Back") + u * -0.2
        cam_at(t + l * 0.6 + f * 2.2 + u * 0.2, t)
        yield()
        local g = perf.gpu and perf.gpu()
        local fr = perf.frames(1)
        fr = fr and fr[#fr]
        if g and fr then
          cnt = cnt + 1
          acc.gpu = (acc.gpu or 0) + g.total
          for _, ps in ipairs(g.passes) do acc["g:" .. ps.name] = (acc["g:" .. ps.name] or 0) + ps.ms end
          for _, b in ipairs({ "render", "animation", "models" }) do
            acc["c:" .. b] = (acc["c:" .. b] or 0) + ((fr.buckets or {})[b] or 0)
          end
          acc["c:frame"] = (acc["c:frame"] or 0) + fr.ms
        end
      end
      local keys = {}
      for k_ in pairs(acc) do keys[#keys + 1] = k_ end
      table.sort(keys)
      local parts = {}
      for _, k_ in ipairs(keys) do parts[#parts + 1] = string.format("%s=%.3f", k_, acc[k_] / math.max(cnt, 1)) end
      P("PERF %s n=%d %s", tag, cnt, table.concat(parts, " "))
    end
    local m = model()
    hold(1.0)
    for rep_ = 1, 2 do
      m.visible = true
      sample("shown" .. rep_, 150)
      m.visible = false
      sample("hidden" .. rep_, 150)
    end
    m.visible = true
    perf.enable(false)
    if params.onlyperf > 0 then
      P("DONE")
      if params.quit > 0 then app.quit() end
      return
    end
  end

  -- ── helmet on ──
  hold(1.0)
  tour("on")
  -- the gloves, close
  do
    local l, u, f = frame()
    local d = bone("Hand.Right") - bone("Back")
    P("hand.right from back: side %.2f up %.2f fwd %.2f", d:dot(l), d:dot(u), d:dot(f))
  end
  view("hands_right", "Hand.Right", -0.35, 0.65, 0.30, 0.0)
  view("hands_left", "Hand.Left", 0.40, 0.65, 0.30, 0.0)
  view("hands_low", "Hand.Right", -0.20, 0.55, -0.30, 0.0)
  -- the API, here and on the other bodies (an airless moon refuses)
  local ok, why = su.canRemoveHelmet()
  P("API here: helmetOn %s canRemoveHelmet %s %s refusal(false) %s", tostring(su.helmetOn()), tostring(ok), tostring(why),
    tostring(su.helmetRefusal(false)))
  for _, nm in ipairs(space.bodies and space.bodies() or {}) do
    local bb = space.body(type(nm) == "table" and nm.name or nm)
    if bb and bb.name ~= b.name and bb.radius then
      local ok2, why2 = su.breathableAt(bb.x, bb.y + bb.radius + 1.0, bb.z)
      P("API on %s: %s %s", bb.name, tostring(ok2), tostring(why2))
    end
  end
  -- ── off: the hands at the neck ring, then the head ──
  local ok3, why3 = su.setHelmet(false)
  P("setHelmet(false): %s %s busy %s", tostring(ok3), tostring(why3), tostring(su.busy))
  view("anim_mid", "Back", 1.6, 1.8, 0.4, -0.1, 30)
  wait_for(function() return not su.busy end, 5, "the helmet animation")
  P("after: helmetOn %s, save crew.helmet %s, changes %s", tostring(su.helmetOn()), tostring(save.get("crew.helmet")),
    tostring(su.changes))
  tour("off")
  view("off_head", "Head", 0.12, 0.62, 0.02, 0.14)
  view("off_head_side", "Head", 0.62, 0.20, 0.02, 0.14)
  -- first person bare-headed
  cam.setFreecam(false)
  cam.firstPerson = true
  hold(1.2)
  shot("off_fp")
  hold(0.3)
  cam.firstPerson = false
  hold(0.6)
  -- ── the left shoulder through its range, by arm IK ──
  if params.sweep > 0 then
    local function drive(kind, deg)
      for _ = 1, 28 do
        su.probeArm = { kind = kind, deg = deg }
        local l, u, f = frame()
        local t = bone("Upperarm.Left")
        cam_at(t + l * 1.05 + f * 0.55 + u * 0.25, t + u * 0.02)
        yield()
      end
      su.probeArm = { kind = kind, deg = deg }
      shot(string.format("sweep_%s_%03d", kind, deg + (kind == "flex" and 40 or 0)))
      yield()
    end
    for _, d in ipairs({ 0, 45, 90, 135, 170 }) do drive("abd", d) end
    for _, d in ipairs({ -40, 0, 60, 120, 170 }) do drive("flex", d) end
    -- the left arm ACROSS the chest (a tool held two-handed, a hand to the
    -- right hip): the DCM's hoses must stay behind the forearm
    local function across(name, l, u, f)
      for _ = 1, 28 do
        su.probeArm = { kind = "at", l = l, u = u, f = f }
        local l_, u_, f_ = frame()
        local t = bone("Back")
        cam_at(t - l_ * 0.35 + f_ * 1.10 + u_ * 0.05, t - u_ * 0.12)
        yield()
      end
      su.probeArm = { kind = "at", l = l, u = u, f = f }
      shot(name)
      yield()
    end
    across("cross_dcm", -0.30, -0.22, 0.26)
    across("cross_low", -0.32, -0.34, 0.22)
    across("cross_hip", -0.42, -0.50, 0.16)
  end
  -- ── a crouch: the root lowered, the walker's foot IK bends the knees ──
  if params.crouch > 0 then
    local an = model():animator()
    local function crouched(name, side, fwd, up, n)
      for _ = 1, n do
        an:addBonePos("MaleArm", vec3(0, -0.42, 0))
        local l, u, f = frame()
        local t = bone("Hip")
        cam_at(t + l * side + f * fwd + u * up, t)
        yield()
      end
      shot(name)
      for _ = 1, 3 do an:addBonePos("MaleArm", vec3(0, -0.42, 0)); yield() end
    end
    crouched("crouch_side", 2.2, 0.5, 0.2, 30)
    crouched("crouch_front", 0.4, 2.2, 0.4, 12)
  end
  -- ── a walk (helmet off), from the side ──
  if params.walk > 0 then
    input.simulate { key = "w", down = true }
    hold(1.5)
    view("walk_side", "Back", 2.2, 0.3, 0.2, -0.3, 8)
    view("walk_quarter", "Back", 1.6, 1.6, 0.4, -0.3, 6)
    input.simulate { key = "w", down = false }
    hold(1.0)
  end
  -- ── LOD: the suit at LOD 1 and LOD 2 by a model swap mid-walk (the pose,
  -- the walk and the attachments must carry over), then LOD 0 again ──
  if params.lod > 0 then
    local m = model()
    local look = nil
    for _, c in ipairs(m:children() or {}) do if c.name == "Helmet" then look = c end end
    for _, l in ipairs({ 1, 2, 0 }) do
      m.model = (l == 0) and "models/astronaut/astronaut_male.glb" or ("models/astronaut/astronaut_male_lod" .. l .. ".glb")
      input.simulate { key = "w", down = true }
      hold(0.6)
      local h0 = bone("Hand.Left") - bone("Back")
      hold(0.25)
      local h1 = bone("Hand.Left") - bone("Back")
      P("LOD %d: model %s, the left hand moved %.3f m against the back in 0.25 s (walking)", l, tostring(m.model),
        (h1 - h0):length())
      view("lod" .. l .. "_walk", "Back", 1.6, 1.6, 0.4, -0.3, 6)
      view("lod" .. l .. "_far", "Back", 9.0, 9.0, 1.5, -0.3, 4)
      input.simulate { key = "w", down = false }
      hold(0.6)
    end
    local sl = nil
    for _, sc in ipairs(findScripts("suit_look") or {}) do sl = sc end
    P("suit_look: lod %s emblem painted %s (emblem version %s)", tostring(sl and sl.lodNow and sl.lodNow()),
      tostring(sl and sl.emblemPainted and sl.emblemPainted()), tostring(findScript("emblem") and findScript("emblem").version))
  end

  -- ── back on, visor raised: the face through the bubble ──
  local ok4, why4 = su.setHelmet(true)
  P("setHelmet(true): %s %s", tostring(ok4), tostring(why4))
  wait_for(function() return not su.busy end, 5, "the helmet animation")
  su.setVisor(false)
  view("visorup_close", "Head", 0.30, 0.95, 0.05, 0.12)
  su.setVisor(true)
  view("on_close2", "Head", 0.42, 0.85, -0.05, 0.02)
  view("on_torso", "Back", 0.25, 1.15, 0.05, -0.15)
  view("on_back_close", "Back", -0.35, -1.25, 0.25, -0.15)
  -- ── first person, holding a tool (the gloves and sleeves in view) ──
  if params.fptool > 0 then
    local ih = findScript("item_hand")
    for _, id in ipairs({ "laser", "gravgun" }) do
      if ih and ih.hold then
        local ok, why = ih.hold(id)
        if not ok then P("hold %s refused: %s", id, tostring(why)) end
      end
      hold(1.2)
      cam.setFreecam(false)
      cam.firstPerson = true
      hold(1.5)
      shot("fp_" .. id)
      hold(0.3)
      cam.firstPerson = false
      hold(0.6)
      view("tp_" .. id, "Back", 1.3, 1.6, 0.3, -0.2)
    end
    if ih and ih.hold then pcall(ih.hold, nil) end
    if ih and ih.stow then pcall(ih.stow) end
    hold(0.8)
  end
  -- ── night: warp until the sun is well down, the helmet lamps and the
  -- torch on ──
  if params.night > 0 then
    local function star_up()
      local best, bmu = nil, -1
      for _, bb in ipairs(space.bodies() or {}) do
        local key = ((bb.soi or 0) < 0 and 1e30 or 0) + (bb.mu or 0)
        if key > bmu then best, bmu = bb.name, key end
      end
      local st = best and space.body(best)
      if not st then return 1 end
      local a = crew()
      local bn = find(b.name)
      local U = vec3(a.x - bn.x, a.y - bn.y, a.z - bn.z):normalized()
      return U:dot(vec3(st.x - a.x, st.y - a.y, st.z - a.z):normalized())
    end
    local t0 = W()
    local s0 = star_up()
    if s0 > -0.25 then
      space.warp(500)
      while W() - t0 < 120 do
        hold(0.25)
        if space.warp() < 2 then space.warp(500) end
        if star_up() < -0.30 then break end
      end
      space.warp(1)
      hold(2.0)
    end
    P("night: sun elevation %.2f (was %.2f)", star_up(), s0)
    su.setLamps(true)
    -- the helmet lamps' own beam (scripts/suit.lua), the torch still off, and
    -- what it costs: the GPU with the lamps on against off, same framing
    hold(0.6)
    P("night: helmet beam lit %.2f (lamps %s, helmet %s)", su.beamLit or -1, tostring(su.lampsOn()), tostring(su.helmetOn()))
    view("night_lamps_front", "Back", 0.6, 2.6, 0.3, -0.2)
    view("night_lamps_close", "Head", 0.45, 0.95, 0.0, 0.08)
    -- the beam's pose against the crew's frame, and whether the engine took it
    do
      local l, u, f = frame()
      local hb = bone("Head")
      if su.beamDX then
        local d = vec3(su.beamDX, su.beamDY, su.beamDZ)
        local o = vec3(su.beamX, su.beamY, su.beamZ) - hb
        P("beam: dir . fwd %.2f . up %.2f . left %.2f; origin from the head: fwd %.2f up %.2f left %.2f",
          d:dot(f), d:dot(u), d:dot(l), o:dot(f), o:dot(u), o:dot(l))
      else
        P("beam: no pose published")
      end
      perf.enable(true)
      for _ = 1, 3 do yield() end
      local pc_ = perf.counts and perf.counts() or {}
      P("beam: lights %s, dropped %s", tostring(pc_.lights), tostring(pc_.lightsDropped))
      perf.enable(false)
      su.setLamps(false)
      view("night_nolamps_front", "Back", 0.6, 2.6, 0.3, -0.2)
      su.setLamps(true)
      -- the apron's floodlights switched off for a moment: the helmet lamps
      -- alone, on and off (what the player sees on the dark side of a world)
      local floods = {}
      for _, fnode in ipairs(findAll and findAll("BaseFlood") or {}) do
        local lcf = fnode.getcomponent and fnode:getcomponent("PointLight")
        if lcf then floods[#floods + 1] = { lcf, lcf.intensity }; lcf.intensity = 0 end
      end
      P("floods off: %d", #floods)
      view("dark_lamps_front", "Back", 0.6, 2.6, 0.3, -0.2)
      view("dark_lamps_side", "Back", 2.6, 1.2, 0.4, -0.3)
      su.setLamps(false)
      view("dark_nolamps_front", "Back", 0.6, 2.6, 0.3, -0.2)
      view("dark_nolamps_side", "Back", 2.6, 1.2, 0.4, -0.3)
      su.setLamps(true)
      for _, fl_ in ipairs(floods) do fl_[1].intensity = fl_[2] end
    end
    if params.perf > 0 then
      local function gsample(tag, n)
        perf.enable(false); perf.enable(true)
        local tot, cnt, ps = 0, 0, {}
        for _ = 1, n do
          local l, u, f = frame()
          local t = bone("Back") + u * -0.2
          cam_at(t + l * 0.6 + f * 2.6 + u * 0.3, t)
          yield()
          local g = perf.gpu and perf.gpu()
          if g and g.total then
            tot, cnt = tot + g.total, cnt + 1
            for _, p in ipairs(g.passes) do ps[p.name] = (ps[p.name] or 0) + p.ms end
          end
        end
        local parts = {}
        for k_, v in pairs(ps) do parts[#parts + 1] = string.format("%s=%.3f", k_, v / math.max(cnt, 1)) end
        table.sort(parts)
        P("PERF %s n=%d gpu=%.3f beam=%.2f %s", tag, cnt, tot / math.max(cnt, 1), su.beamLit or -1, table.concat(parts, " "))
      end
      for rep_ = 1, 2 do
        su.setLamps(true); hold(0.3); gsample("lamps_on" .. rep_, 120)
        su.setLamps(false); hold(0.3); gsample("lamps_off" .. rep_, 120)
      end
      su.setLamps(true)
      perf.enable(false)
    end
    local fl = findScript("flashlight")
    local inv = findScript("inventory")
    if inv and inv.addGear then pcall(inv.addGear, "astro", "flashlight", 1) end
    hold(0.5)
    if fl and fl.setOn then pcall(fl.setOn, true) end
    hold(1.0)
    view("night_front", "Back", 0.6, 2.6, 0.3, -0.2)
    view("night_quarter", "Back", 1.8, 2.0, 0.5, -0.2)
    view("night_close", "Head", 0.45, 0.95, 0.0, 0.08)
  end
  -- ── seated: a rover with an open seat, launched as the builder does it;
  -- the helmet taken off first, so the scene reload shows it kept ──
  if params.seat > 0 then
    su.setHelmet(false, { instant = true })
    P("before the rover: helmetOn %s save %s", tostring(su.helmetOn()), tostring(save.get("crew.helmet")))
    local function rec(uid, id, x, y, z, o)
      o = o or {}
      return { uid = uid, id = id, x = x, y = y, z = z, yaw = o.yaw or 0, pitch = 0, roll = 0,
               parent = o.parent or 0, att = o.att or "", sym = o.sym or 0, mir = o.mir or "", stage = 0 }
    end
    local HP = math.pi / 2
    local bp = { rec(1, "roverBody", 0, 0.62, 0),
      rec(2, "wheelM", 0.66, 0.42, 0.7, { yaw = -HP, parent = 1, att = "surface", sym = 1, mir = "z" }),
      rec(3, "wheelM", 0.66, 0.42, -0.7, { yaw = HP, parent = 1, att = "surface", sym = 1, mir = "z" }),
      rec(4, "wheelM", -0.66, 0.42, 0.7, { yaw = -HP, parent = 1, att = "surface", sym = 2, mir = "z" }),
      rec(5, "wheelM", -0.66, 0.42, -0.7, { yaw = HP, parent = 1, att = "surface", sym = 2, mir = "z" }),
      rec(6, "seat", 0, 0.62 + 0.15 + 0.65, 0, { parent = 1, att = "top" }) }
    local co = findScript("company")
    if co and co.earn then co.earn(80000, "probe") end
    cam.setFreecam(false)
    save.set("shipyard.blueprint", { parts = bp })
    save.set("shipyard.site", "runway")
    save.set("shipyard.pilot", 1)
    scene.load("builder")
    local B = wait_for(function() local B = findScript("builder"); return B and B.partUids and #B.partUids() >= 6 and B end, 90, "the builder")
    if B then
      hold(1.5)
      save.set("shipyard.site", "runway")
      B.doLaunch()
      if save.get("shipyard.launch") ~= 1 then B.doLaunch() end
      local vc = wait_for(function()
        for _, v in ipairs(findScripts("vessel_controller")) do
          if v.piloting and v.node and v.node.valid then return v end
        end
      end, 150, "the rover")
      wait_for(function()
        local bf = findScript("base_facilities")
        return bf and bf.sited and not (bf.grading and bf.grading())
      end, 120, "the regrade")
      hold(3.0)
      cam, su = findScript("planet_camera"), findScript("suit")
      P("seated: rover %s, helmetOn %s (saved %s), canRemove %s", tostring(vc ~= nil), tostring(su and su.helmetOn()),
        tostring(save.get("crew.helmet")), tostring(su and select(2, su.canRemoveHelmet())))
      if vc then
        view("seat_off_side", "Back", 2.4, 0.4, 0.4, -0.2)
        view("seat_off_quarter", "Back", 1.6, 1.8, 0.6, -0.2)
        su.setHelmet(true, { instant = true })
        view("seat_on_quarter", "Back", 1.6, 1.8, 0.6, -0.2)
        view("seat_on_front", "Back", 0.2, 2.2, 0.5, -0.2)
      end
    end
  end
  P("end: helmetOn %s visor %s lamps %s save %s/%s/%s", tostring(su.helmetOn()), tostring(su.visorDown()),
    tostring(su.lampsOn()), tostring(save.get("crew.helmet")), tostring(save.get("crew.visor")), tostring(save.get("crew.lamps")))
  cam.setFreecam(false)
  wait_for(function() return pending <= 0 end, 20, "the captures")
  P("DONE")
  if params.quit > 0 then app.quit() end
end

function update(node, dt)
  if not CO then NODE = node; CO = coroutine.create(main) end
  if coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO)
    if not ok then P("ERROR %s", tostring(err)); if params.quit > 0 then app.quit() end end
  end
end
