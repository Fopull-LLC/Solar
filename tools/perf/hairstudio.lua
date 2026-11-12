-- HAIRSTUDIO: the long hair styles on a plain stage (tools/perf/hairstudio.sh).
--   case styles   one actor per long style (helmets off): the row, then each
--                 close from the front three-quarter, the side and behind
--   case motion   actor 1 (params.style) turns, sprints, stops and jumps:
--                 short sequences of stills, and how far the tips swung
--   case perf     every actor long-haired, the springs on, off and the hair
--                 hidden: the frame's CPU time each way (perf.frames)
--   case helmet   helmet on then off: the hair hidden, and back with no swing
-- Pictures: user://hairstudio/<name>.png. params: n, quit; strs: case, style.
defaults = { n = 6, quit = 1, case = "styles", style = "long" }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("HAIR %7.2f " .. fmt, W() - W0, ...)) end
local CO, CASE
local cam_at = nil
local pending = 0
local spin = nil           -- { k = actor, yaw0, rate } turning an actor's root
local moves = {}           -- actor k → { dx, dy, dz } offset from its start (the root's own place)
local starts = {}
local function yield() coroutine.yield() end
local function wait(s) local t = W() + s; while W() < t do yield() end end

local STYLES = { "long", "wavy", "shoulder", "lowtail", "braid", "halfup" }
local COLOURS = { { 0.06, 0.05, 0.045 }, { 0.36, 0.21, 0.12 }, { 0.62, 0.48, 0.30 }, { 0.45, 0.20, 0.10 },
                  { 0.13, 0.09, 0.07 }, { 0.25, 0.16, 0.10 } }

local function shot(name, w, h)
  pending = pending + 1
  local ok, err = pcall(camera.capture, { w = w or 1280, h = h or 720, ui = false }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://hairstudio/" .. name .. ".png", bytes, { async = true }); P("SHOT %s", name)
    else P("capture failed %s %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
end

local function actor(k)
  local root = find("Actor " .. k)
  if not root then return nil end
  for _, m in ipairs(root:children()) do
    if m.name == "AstroModel" then
      for _, f in ipairs(m:children()) do
        if f.name == "Face" then
          local hair
          for _, c in ipairs(f:children()) do if c.name == "Hair" then hair = c end end
          return f, f:getScript("face"), m, root, hair
        end
      end
    end
  end
end

-- the face's centre and forward, from its own bones this frame
local function face_frame(f)
  local a = f:animator()
  local r = a and a:boneWorld("FaceRoot")
  local el = a and a:boneWorld("EyeL")
  local er = a and a:boneWorld("EyeR")
  if not (r and el and er) then return nil end
  local mx, my, mz = (el.x + er.x) / 2, (el.y + er.y) / 2, (el.z + er.z) / 2
  local fx, fz = mx - r.x, mz - r.z
  local l = math.sqrt(fx * fx + fz * fz)
  return { x = r.x, y = my - 0.03, z = r.z, fx = fx / l, fz = fz / l }
end

-- the camera at `dist` from the head, `ang` radians round from the face
-- (0 in front, pi behind), `dy` up, looking at the head lowered by `ty`
local function frame_at(f, dist, ang, dy, ty)
  local fr = face_frame(f)
  if not fr then return nil end
  local c, s = math.cos(ang), math.sin(ang)
  local dx, dz = fr.fx * c - fr.fz * s, fr.fz * c + fr.fx * s
  cam_at = { fr.x + dx * dist, fr.y + (dy or 0), fr.z + dz * dist, fr.x, fr.y - (ty or 0), fr.z }
  return fr
end

local function lights_on(fr)
  local key, fill = find("Key Light"), find("Fill Light")
  local rx, rz = -fr.fz, fr.fx
  key.pos = vec3(fr.x + fr.fx * 0.9 + rx * 0.8, fr.y + 0.7, fr.z + fr.fz * 0.9 + rz * 0.8)
  fill.pos = vec3(fr.x - fr.fx * 0.9 - rx * 0.9, fr.y + 0.3, fr.z - fr.fz * 0.9 - rz * 0.9)
end

local function look_for(k, style)
  local F = findScript("crew_faces")
  local names = { "Dana Okafor", "Jonah Reyes", "Mira Ito", "Theo Lindqvist", "Imani Achebe", "Ravi Pillai",
                  "Saga Kowalski", "Mateo Castillo" }
  local l = F.lookFor(1911564384, k, names[(k - 1) % #names + 1])
  local c = {}
  for kk, v in pairs(l) do c[kk] = v end
  c.hairStyle = style
  c.hair = COLOURS[(k - 1) % #COLOURS + 1]
  c.key = (l.key or "") .. ":" .. style
  return c
end

local function tip_of(hair, chain, last)
  local a = hair and hair:animator()
  if not a then return nil end
  local ok, b = pcall(a.boneWorld, a, string.format("S%02d_%d", chain, last))
  return ok and b or nil
end

local function helmets(k, on)
  local _, s, m = actor(k)
  for _, c in ipairs(m:children()) do if c.name == "Helmet" then c.visible = on end end
  s.forceHelmet = on
end

local MAIN = function()
  wait(1.0)
  local F = findScript("crew_faces")
  local f1, s1 = actor(1)
  while not (F and s1 and s1.setLook and face_frame(f1)) do
    yield(); F = findScript("crew_faces"); f1, s1 = actor(1)
  end
  for k = 1, params.n do
    local _, s, _, root = actor(k)
    starts[k] = { root.x, root.y, root.z }
    local st = (CASE == "motion" or CASE == "helmet") and (params.style or "long") or STYLES[(k - 1) % #STYLES + 1]
    s.setLook(look_for(k, st))
    s.still = true
    s.gaze = function() return nil end   -- no head turn to the camera (a camera jump would snap it)
    helmets(k, false)
  end
  wait(3.0)
  if CASE == "styles" then
    local fa, fb = face_frame(actor(1)), face_frame(actor(params.n))
    local cx, cz = (fa.x + fb.x) / 2, (fa.z + fb.z) / 2
    local span = math.sqrt((fa.x - fb.x) ^ 2 + (fa.z - fb.z) ^ 2)
    local d = span * 0.75 + 1.0
    cam_at = { cx + fa.fx * d, fa.y - 0.1, cz + fa.fz * d, cx, fa.y - 0.25, cz }
    wait(0.6); shot("row"); wait(0.4)
    cam_at = { cx - fa.fx * d, fa.y - 0.1, cz - fa.fz * d, cx, fa.y - 0.25, cz }
    wait(0.6); shot("row_back"); wait(0.4)
    for k = 1, params.n do
      local f, s = actor(k)
      local st = STYLES[(k - 1) % #STYLES + 1]
      local views = { { "front", 0.0, 0.62, 0.0, 0.05 }, { "3q", 0.75, 0.55, 0.02, 0.04 }, { "side", 1.57, 0.70, 0.0, 0.12 },
                      { "back3q", 2.4, 0.80, 0.05, 0.15 }, { "back", 3.14, 0.85, 0.05, 0.18 }, { "close", 0.45, 0.36, 0.0, 0.0 } }
      for _, v in ipairs(views) do
        local fr = frame_at(f, v[3], v[2], v[4], v[5])
        lights_on(fr)
        wait(0.9)
        shot(string.format("%d_%s_%s", k, st, v[1]), 720, 720)
        wait(0.1)
      end
    end
  elseif CASE == "motion" then
    local f, s, m, root, hair = actor(1)
    local st = params.style or "long"
    local fr = frame_at(f, 1.6, 0.6, 0.0, 0.15)
    lights_on(fr)
    -- the camera stays put (in world) while the actor moves
    -- the tips relative to the hair's root, the rest turned with the actor
    -- (either way round: the smaller is the swing)
    local hroot = function() return hair:animator():boneWorld("HairRoot") end
    local rest, yaw0 = {}, root.yaw or 0
    local h0 = hroot()
    for c = 0, 23 do
      local b = tip_of(hair, c, 6) or tip_of(hair, c, 3)
      if b then rest[c] = { b.x - h0.x, b.y - h0.y, b.z - h0.z } end
    end
    local function sample(tag)
      local maxd, which = 0, -1
      local h = hroot()
      local dyaw = (root.yaw or 0) - yaw0
      for c = 0, 23 do
        local b = tip_of(hair, c, 6) or tip_of(hair, c, 3)
        local r = rest[c]
        if b and r then
          local best = 1e9
          for _, sg in ipairs({ 1, -1 }) do
            local cs, sn = math.cos(dyaw * sg), math.sin(dyaw * sg)
            local rx, rz = r[1] * cs + r[3] * sn, -r[1] * sn + r[3] * cs
            local dx, dy, dz = b.x - h.x - rx, b.y - h.y - r[2], b.z - h.z - rz
            best = math.min(best, math.sqrt(dx * dx + dy * dy + dz * dz))
          end
          if best > maxd then maxd, which = best, c end
        end
      end
      P("SWING %s max %.3f m (chain S%02d) frame %.1f ms", tag, maxd, which, 1000 * (dt_last or 0))
    end
    local function seq(tag, secs, step)
      local n = math.floor(secs / step + 0.5)
      for i = 0, n - 1 do
        shot(string.format("%s_%s_%02d", st, tag, i), 560, 560)
        if i % 3 == 0 then sample(tag .. i) end
        wait(step)
      end
    end
    -- a turn: 180° in 0.6 s, then stop
    shot(st .. "_rest", 720, 720); wait(0.5)
    spin = { k = 1, rate = 5.2, left = math.pi }
    seq("turn", 2.4, 0.08)
    spin = { k = 1, rate = -5.2, left = math.pi }
    seq("turnback", 2.0, 0.1)
    -- a sprint sideways and a stop (the root moves 1.6 m in 0.4 s)
    local t0 = W()
    local function slide(dx, secs)
      local a = W()
      local x0 = (moves[1] or { 0, 0, 0 })[1]
      while W() - a < secs do
        local u = (W() - a) / secs
        moves[1] = { x0 + dx * u, 0, 0 }
        if math.floor((W() - a) / 0.08) ~= math.floor((W() - a - 0.017) / 0.08) then
          shot(string.format("%s_sprint_%03d", st, math.floor((W() - t0) * 100)), 560, 560)
        end
        yield()
      end
      moves[1] = { x0 + dx, 0, 0 }
    end
    slide(1.2, 0.35)
    seq("stop", 1.6, 0.08)
    slide(-1.2, 0.35)
    seq("stopback", 1.0, 0.1)
    -- a jump: up 0.45 m and down in 0.6 s
    local a = W()
    while W() - a < 0.6 do
      local u = (W() - a) / 0.6
      moves[1] = { 0, 0.45 * 4 * u * (1 - u), 0 }
      if math.floor((W() - a) / 0.06) ~= math.floor((W() - a - 0.017) / 0.06) then
        shot(string.format("%s_jump_%03d", st, math.floor((W() - a) * 100)), 560, 560)
      end
      yield()
    end
    moves[1] = { 0, 0, 0 }
    seq("land", 1.2, 0.08)
    sample("settled")
  elseif CASE == "rest" then
    -- the drawn rest pose (springs off) against the swung one, and where
    -- the bones are: the rig's sanity
    local f, s, m, root, hair = actor(1)
    local st = params.style or "long"
    local a = hair:animator()
    local function dump(tag)
      local hr = a:boneWorld("HairRoot")
      local fr = f:animator():boneWorld("FaceRoot")
      P("BONES %s HairRoot %.3f %.3f %.3f FaceRoot %.3f %.3f %.3f", tag, hr.x, hr.y, hr.z, fr.x, fr.y, fr.z)
      local gg = s.hairGravity or {}
      P("GRAV %s %s %s %s dominant %s", tag, tostring(gg[1]), tostring(gg[2]), tostring(gg[3]),
        tostring(space and space.dominant and space.dominant(hr.x, hr.y, hr.z)))
      for _, c in ipairs({ 0, 3, 6, 11 }) do
        local line = {}
        for j = 0, 6 do
          local ok, b = pcall(a.boneWorld, a, string.format("S%02d_%d", c, j))
          if ok and b then line[#line + 1] = string.format("(%.3f,%.3f,%.3f)", b.x - hr.x, b.y - hr.y, b.z - hr.z) end
        end
        P("BONES %s S%02d %s", tag, c, table.concat(line, " "))
      end
    end
    for c = 0, 23 do a:setSpringEnabled(string.format("S%02d", c), false) end
    wait(1.0)
    dump("off")
    for _, v in ipairs({ { "side", 1.57 }, { "back3q", 2.4 }, { "front", 0.0 } }) do
      lights_on(frame_at(f, 0.9, v[2], 0.0, 0.15)); wait(0.5); shot(st .. "_off_" .. v[1], 640, 640); wait(0.2)
    end
    for c = 0, 23 do a:setSpringEnabled(string.format("S%02d", c), true) end
    wait(2.0)
    dump("on")
    for _, v in ipairs({ { "side", 1.57 }, { "back3q", 2.4 }, { "front", 0.0 } }) do
      lights_on(frame_at(f, 0.9, v[2], 0.0, 0.15)); wait(0.5); shot(st .. "_on_" .. v[1], 640, 640); wait(0.2)
    end
  elseif CASE == "helmet" then
    local f, s, m, root, hair = actor(1)
    local st = params.style or "long"
    local fr = frame_at(f, 0.9, 2.3, 0.05, 0.12)
    lights_on(fr)
    wait(0.5); shot(st .. "_off_a", 640, 640); wait(0.3)
    helmets(1, true)
    wait(0.8); shot(st .. "_on", 640, 640); wait(0.3)
    P("helmet on: hair visible %s", tostring(hair and hair.visible))
    helmets(1, false)
    for i = 0, 5 do wait(0.08); shot(string.format("%s_off_b%d", st, i), 640, 640) end
    P("helmet off: hair visible %s", tostring(hair and hair.visible))
  elseif CASE == "perf" then
    if perf and perf.enable then perf.enable(true) end
    local fa, fb = face_frame(actor(1)), face_frame(actor(params.n))
    local cx, cz = (fa.x + fb.x) / 2, (fa.z + fb.z) / 2
    local span = math.sqrt((fa.x - fb.x) ^ 2 + (fa.z - fb.z) ^ 2)
    local d = span * 0.75 + 1.2
    cam_at = { cx + fa.fx * d, fa.y, cz + fa.fz * d, cx, fa.y - 0.2, cz }
    -- the actors turn back and forth all the while (the springs work)
    spin = { k = 0, rate = 2.5, left = 1e9, wobble = true }
    local function measure(tag)
      wait(1.5)
      local t = W()
      local fr = perf.frames and perf.frames(180) or {}
      local n, ms, anim, untimed, render = 0, 0, 0, 0, 0
      for _, x in ipairs(fr) do
        n = n + 1
        ms = ms + (x.ms or 0)
        anim = anim + ((x.buckets or {}).animation or 0)
        untimed = untimed + ((x.buckets or {}).untimed or 0)
        render = render + ((x.buckets or {}).render or 0)
      end
      local acc = perf.accountedMs and perf.accountedMs() or 0
      n = math.max(n, 1)
      P("PERF %-10s frames %d frame %.3f ms animation %.3f untimed %.3f render %.3f accounted(last) %.3f gpu %s tris %s",
        tag, n, ms / n, anim / n, untimed / n, render / n, acc, tostring(perf.gpuMs and perf.gpuMs("total") or "?"),
        tostring((perf.counts() or {}).triangles))
    end
    measure("on")
    for k = 1, params.n do
      local _, _, _, _, hair = actor(k)
      local a = hair and hair:animator()
      for c = 0, 23 do if a then a:setSpringEnabled(string.format("S%02d", c), false) end end
    end
    measure("off")
    for k = 1, params.n do
      local _, _, _, _, hair = actor(k)
      local a = hair and hair:animator()
      for c = 0, 23 do if a then a:setSpringEnabled(string.format("S%02d", c), true) end end
    end
    measure("on2")
    for k = 1, params.n do
      local _, s = actor(k)
      s.forceHelmet = true          -- the hair hidden (its animator culled)
    end
    measure("hidden")
    for k = 1, params.n do
      local _, s = actor(k)
      local l = look_for(k, "crop")
      s.setLook(l)
      s.forceHelmet = false
    end
    measure("short")
    spin = nil
  end
  local t = W() + 10
  while pending > 0 and W() < t do yield() end
  P("DONE")
  if params.quit > 0 then app.quit() end
  while true do yield() end
end

function update(node, dt)
  dt_last = dt
  if not CO then CASE = params.case or "styles"; CO = coroutine.create(MAIN) end
  if coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO)
    if not ok then P("ERROR %s", tostring(err)) end
  end
  -- the actors' roots: turning and moving (in update: the springs feel it)
  if spin then
    for k = 1, params.n do
      if spin.k == 0 or spin.k == k then
        local _, _, _, root = actor(k)
        if root then
          local step = spin.rate * dt
          if spin.wobble then
            root.yaw = 0.9 * math.sin((time or 0) * spin.rate + k)
          else
            if math.abs(step) > spin.left then step = (step > 0 and 1 or -1) * spin.left end
            root.yaw = (root.yaw or 0) + step
          end
        end
      end
    end
    if not spin.wobble then
      spin.left = spin.left - math.abs(spin.rate * dt)
      if spin.left <= 0 then spin = nil end
    end
  end
  for k, mv in pairs(moves) do
    local _, _, _, root = actor(k)
    local s0 = starts[k]
    if root and s0 then root.pos = vec3(s0[1] + mv[1], s0[2] + mv[2], s0[3] + mv[3]) end
  end
end

function lateUpdate(node, dt)
  local c = find("Camera")
  if c and cam_at then
    c.pos = vec3(cam_at[1], cam_at[2], cam_at[3])
    c:lookAt(vec3(cam_at[4], cam_at[5], cam_at[6]), vec3(0, 1, 0))
  end
end
