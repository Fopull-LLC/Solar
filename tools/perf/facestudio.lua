-- FACESTUDIO: the crew's faces on a plain stage (tools/perf/facestudio.sh).
--   case lineup   every actor a different member (crew_faces.lookFor), a
--                 wide shot of the row, then each face close
--   case expr     actor 1 through crew_faces.EXPR, one picture each
--   case rig      the rig's signs: jaw open, a blink, eyes left/up
--   case perf     all actors live (life only), perf.scriptMs of face/crew_faces
-- Pictures: user://facestudio/<name>.png. params: n, seed, quit.
defaults = { n = 8, seed = 1911564384, quit = 1, actor = 1, case = "lineup" }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("FACE %7.2f " .. fmt, W() - W0, ...)) end
local CO, CASE
local cam_at = nil          -- { x,y,z, tx,ty,tz }
local head_turn = nil       -- { yaw, pitch, roll } on every actor's suit Head bone (case neck)
local pending = 0
local function yield() coroutine.yield() end
local function wait(s) local t = W() + s; while W() < t do yield() end end

local function shot(name, w, h)
  pending = pending + 1
  local ok, err = pcall(camera.capture, { w = w or 1280, h = h or 720, ui = false }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://facestudio/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("capture failed %s %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
  wait(0.4)
end

local function actor(k)
  local root = find("Actor " .. k)
  if not root then return nil end
  for _, m in ipairs(root:children()) do
    if m.name == "AstroModel" then
      for _, f in ipairs(m:children()) do
        if f.name == "Face" then return f, f:getScript("face"), m end
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
  return { x = mx, y = my - 0.03, z = mz, fx = fx / l, fz = fz / l }
end

local function frame_face(f, dist, dy, side)
  local fr = face_frame(f)
  if not fr then return false end
  side = side or 0
  local rx, rz = -fr.fz, fr.fx
  cam_at = { fr.x + fr.fx * dist + rx * side, fr.y + (dy or 0), fr.z + fr.fz * dist + rz * side, fr.x, fr.y, fr.z }
  return true
end

local CH = nil
local function full(t)
  local o = {}
  for _, k in ipairs(CH) do o[k] = 0 end
  for k, v in pairs(t or {}) do o[k] = v end
  return o
end

local function looks()
  local F = findScript("crew_faces")
  local firsts = { "Dana Okafor", "Jonah Reyes", "Mira Ito", "Theo Lindqvist", "Imani Achebe", "Ravi Pillai",
                   "Saga Kowalski", "Mateo Castillo", "Noor Haddad", "Bram Kerr" }
  local taken = { heads = {}, styles = {}, skins = {} }
  local out = {}
  for k = 1, params.n do
    local nm = firsts[(k - 1) % #firsts + 1]
    local l = F.lookFor(params.seed, k, nm, taken)
    taken.heads[l.head] = (taken.heads[l.head] or 0) + 1
    taken.styles[l.hairStyle] = (taken.styles[l.hairStyle] or 0) + 1
    taken.skins[#taken.skins + 1] = l.skinX
    out[k] = l
    P("LOOK %d %-16s head %d %s hair %s/%s eyes %s skin %.2f age %.2f stubble %.2f frk %.2f scar %d courage %.2f thrill %.2f",
      k, nm, l.head, l.fem and "F" or "M", l.hairName, l.hairStyle, l.eyeName, l.skinX, l.age, l.stubble, l.freckles,
      l.scar, l.courage, l.thrill)
  end
  return out
end

local MAIN = function()
  wait(1.0)
  local F = findScript("crew_faces")
  local f1, s1 = actor(1)
  while not (F and s1 and s1.CHANNELS and face_frame(f1)) do
    yield(); F = findScript("crew_faces"); f1, s1 = actor(1)
  end
  CH = s1.CHANNELS
  local t_ready = W() + 20
  while W() < t_ready do
    local all = true
    for k = 1, params.n do local f, s = actor(k); if not (s and s.setLook) then all = false end end
    if all then break end
    yield()
  end
  local L = looks()
  for k = 1, params.n do
    local f, s = actor(k)
    if s and s.setLook then s.setLook(L[k]) else P("actor %d has no face script", k) end
  end
  wait(2.0)
  if CASE == "lineup" then
    for k = 1, params.n do local _, s = actor(k); s.still = true; s.override = full({}) end
    -- the row, from in front and a little above
    local fa = face_frame(actor(1))
    local fb = face_frame(actor(params.n))
    local cx, cz = (fa.x + fb.x) / 2, (fa.z + fb.z) / 2
    local span = math.sqrt((fa.x - fb.x) ^ 2 + (fa.z - fb.z) ^ 2)
    local d = span * 0.62 + 0.6
    cam_at = { cx + fa.fx * d, fa.y + 0.15, cz + fa.fz * d, cx, fa.y - 0.05, cz }
    wait(0.6)
    shot("lineup")
    for k = 1, params.n do
      local f = actor(k)
      frame_face(f, 0.62, 0.02, 0.12)
      wait(0.35)
      shot(string.format("face_%d", k), 720, 720)
    end
  elseif CASE == "expr" then
    local f, s = actor(params.actor)
    s.still = true
    local names = { "neutral", "focus", "happy", "excited", "relief", "delight", "worried", "scared", "panic", "pain",
                    "strain", "tired", "bored", "out", "dead" }
    frame_face(f, 0.60, 0.02, 0.10)
    for _, nm in ipairs(names) do
      s.override = full(F.EXPR[nm])
      wait(0.45)
      shot("expr_" .. nm, 720, 720)
    end
  elseif CASE == "review" then
    -- for the user: six people, each with a face of their own on, close,
    -- mid (head and shoulders) and in the helmet (visor down)
    local exprs = { "neutral", "happy", "focus", "worried", "excited", "scared", "relief", "strain" }
    local key, fill = find("Key Light"), find("Fill Light")
    local function helmets(k, on)
      local _, s, m = actor(k)
      for _, c in ipairs(m:children()) do if c.name == "Helmet" then c.visible = on end end
      s.forceHelmet = on
    end
    for k = 1, params.n do helmets(k, false) end
    wait(0.5)
    for k = 1, params.n do
      local f, s = actor(k)
      s.still = true             -- no blink caught mid-shot
      s.override = nil
      local e = F.EXPR[exprs[(k - 1) % #exprs + 1]]
      s.override = {}
      for ch, v in pairs(e) do s.override[ch] = v end
      local fr = face_frame(f)
      -- the lights go with the sitter: a key high to one side, a fill low on the other
      local rx, rz = -fr.fz, fr.fx
      key.pos = vec3(fr.x + fr.fx * 0.9 + rx * 0.7, fr.y + 0.55, fr.z + fr.fz * 0.9 + rz * 0.7)
      fill.pos = vec3(fr.x + fr.fx * 0.8 - rx * 0.9, fr.y + 0.05, fr.z + fr.fz * 0.8 - rz * 0.9)
      frame_face(f, 0.40, 0.01, 0.12)
      wait(0.6)
      shot(string.format("p%d_close", k), 720, 720)
      frame_face(f, 1.05, -0.08, 0.35)
      cam_at[5] = cam_at[5] - 0.10
      wait(0.4)
      shot(string.format("p%d_mid", k), 720, 720)
      helmets(k, true)
      frame_face(f, 0.62, 0.02, 0.18)
      wait(0.6)
      shot(string.format("p%d_helmet", k), 720, 720)
      helmets(k, false)
    end
  elseif CASE == "exprs" then
    -- every person through the main expressions: close (512²) and at the
    -- strip portrait's framing, small (fovY 0.9 at 0.42 m is this lens at
    -- 0.80 m; captured 336² and shown at 168², a portrait's target size)
    local list = { "neutral", "happy", "focus", "worried", "scared", "excited", "relief", "delight" }
    local key, fill = find("Key Light"), find("Fill Light")
    for k = 1, params.n do
      local _, _, m = actor(k)
      for _, c in ipairs(m:children()) do if c.name == "Helmet" then c.visible = false end end
    end
    for k = 1, params.n do
      local f, s = actor(k)
      s.forceHelmet = false
      s.still = true
      local fr = face_frame(f)
      local rx, rz = -fr.fz, fr.fx
      key.pos = vec3(fr.x + fr.fx * 0.9 + rx * 0.7, fr.y + 0.55, fr.z + fr.fz * 0.9 + rz * 0.7)
      fill.pos = vec3(fr.x + fr.fx * 0.8 - rx * 0.9, fr.y + 0.05, fr.z + fr.fz * 0.8 - rz * 0.9)
      for _, nm in ipairs(list) do
        s.override = {}
        for ch, v in pairs(F.EXPR[nm]) do s.override[ch] = v end
        frame_face(f, 0.40, 0.0, 0.06)
        wait(0.5)
        shot(string.format("x%d_%s_close", k, nm), 512, 512)
        frame_face(f, 0.80, -0.03, 0.0)
        wait(0.3)
        shot(string.format("x%d_%s_strip", k, nm), 336, 336)
      end
    end
  elseif CASE == "mouthdebug" then
    local f, s = actor(1)
    s.still = true
    s.override = {}
    for ch, v in pairs(F.EXPR.excited) do s.override[ch] = v end
    frame_face(f, 0.30, -0.05, 0.0)
    wait(0.6)
    shot("md_plain", 512, 512)
    local m = f:material("FaceMouth")
    pcall(function() m.color = { 0, 1, 0 } end)
    wait(0.4)
    shot("md_mouthgreen", 512, 512)
    pcall(function() m.color = { 1, 1, 1 } end)
    local e = f:material("FaceEye")
    pcall(function() e.color = { 0, 0, 1 } end)
    local sk = f:material("FaceSkin")
    pcall(sk.setShaderParam, sk, "skin", 1, 0, 1)
    wait(0.4)
    shot("md_skinmagenta", 512, 512)
    pcall(sk.setShaderParam, sk, "debugView", 1, 0, 0)
    wait(0.4)
    shot("md_alpha", 512, 512)
    pcall(sk.setShaderParam, sk, "debugView", 0, 1, 0)
    wait(0.4)
    shot("md_red", 512, 512)
    pcall(sk.setShaderParam, sk, "debugView", 0, 0, 0)
    for _, c in ipairs(f:children()) do c.visible = false end
    wait(0.3)
    shot("md_nohair", 512, 512)
    f.visible = false
    wait(0.3)
    shot("md_noface", 512, 512)
    P("materials: %s", tostring(#f:materials()))
    for _, mm in ipairs(f:materials()) do P("  part %s mat %s", tostring(mm.object), tostring(mm.material)) end
  elseif CASE == "neck" then
    -- the worst poses for the neck: the head turned, tipped and rolled
    -- with the mouth wide open; from below the chin and into the mouth
    local poses = { { "front_jawfull", 0, 0, 0, "jaw" }, { "turned_panic", 0.70, 0.52, 0.26, "panic" },
                    { "down_panic", 0, -0.61, 0, "panic" }, { "up_excited", -0.70, 0.61, 0, "excited" } }
    local key, fill = find("Key Light"), find("Fill Light")
    for k = 1, params.n do
      local _, _, m = actor(k)
      for _, c in ipairs(m:children()) do if c.name == "Helmet" then c.visible = false end end
    end
    for k = 1, params.n do
      local f, s = actor(k)
      s.still = true
      s.forceHelmet = false
      for _, ps in ipairs(poses) do
        s.override = {}
        if ps[5] == "jaw" then s.override = { jaw_open = 1, lip_down = 1 }
        else for ch, v in pairs(F.EXPR[ps[5]]) do s.override[ch] = v end end
        -- frame from the unturned face (taken before the turn), aimed at the
        -- head's place: the turned head is seen as it turns
        head_turn = nil
        wait(0.3)
        local fr = face_frame(f)
        head_turn = { ps[2], ps[3], ps[4] }
        wait(0.5)
        local rx, rz = -fr.fz, fr.fx
        key.pos = vec3(fr.x + fr.fx * 0.9 + rx * 0.7, fr.y + 0.55, fr.z + fr.fz * 0.9 + rz * 0.7)
        fill.pos = vec3(fr.x + fr.fx * 0.8 - rx * 0.9, fr.y - 0.25, fr.z + fr.fz * 0.8 - rz * 0.9)
        -- into the mouth (from in front, a little above the lips)
        cam_at = { fr.x + fr.fx * 0.26, fr.y - 0.035, fr.z + fr.fz * 0.26, fr.x, fr.y - 0.085, fr.z }
        wait(0.3)
        shot(string.format("n%d_%s_mouth", k, ps[1]), 512, 512)
        -- from below the chin, looking up at the jaw and the neck
        cam_at = { fr.x + fr.fx * 0.22, fr.y - 0.24, fr.z + fr.fz * 0.22, fr.x, fr.y - 0.11, fr.z }
        wait(0.3)
        shot(string.format("n%d_%s_below", k, ps[1]), 512, 512)
      end
      head_turn = nil
    end
  elseif CASE == "rig" then
    local f, s = actor(params.actor)
    s.still = true
    frame_face(f, 0.55, 0.02, 0.0)
    for _, c in ipairs({ { "rest", {} }, { "jaw", { jaw_open = 1 } }, { "blink", { blink_L = 1, blink_R = 1 } },
                         { "lookleft_up", { look_x = 1, look_y = 1 } }, { "wide", { wide_L = 1, wide_R = 1 } },
                         { "smile", { smile_L = 1, smile_R = 1, cheek_L = 1, cheek_R = 1 } },
                         { "browsup", { brow_in_up_L = 1, brow_in_up_R = 1, brow_out_up_L = 1, brow_out_up_R = 1 } } }) do
      s.override = full(c[2])
      wait(0.4)
      shot("rig_" .. c[1], 720, 720)
    end
    frame_face(f, 0.6, 0.0, 0.45)
    s.override = full({ jaw_open = 1, lip_down = 1, lip_up = 1 })
    wait(0.4)
    shot("rig_side_open", 720, 720)
  elseif CASE == "perf" then
    if perf and perf.enable then perf.enable(true) end
    local fa = face_frame(actor(1))
    cam_at = { fa.x + fa.fx * 2.5, fa.y, fa.z + fa.fz * 2.5, fa.x, fa.y, fa.z }
    wait(6)
    P("PERF face %.4f ms crew_faces %.4f ms (n %d)", perf.scriptMs("face"), perf.scriptMs("crew_faces"), params.n)
    P("PERF gpu %s", tostring(perf.gpuMs and perf.gpuMs() or "?"))
  end
  local t = W() + 10
  while pending > 0 and W() < t do yield() end
  P("DONE")
  if params.quit > 0 then app.quit() end
  while true do yield() end
end

function update(node, dt)
  if not CO then CASE = params.case or "lineup"; CO = coroutine.create(MAIN) end
  if coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO)
    if not ok then P("ERROR %s", tostring(err)) end
  end
end

function lateUpdate(node, dt)
  if head_turn then
    for k = 1, params.n do
      local _, _, m = actor(k)
      local a = m and m:animator()
      if a then pcall(a.addBoneRot, a, "Head", head_turn[1], head_turn[2], head_turn[3]) end
    end
  end
  local c = find("Camera")
  if c and cam_at then
    c.pos = vec3(cam_at[1], cam_at[2], cam_at[3])
    c:lookAt(vec3(cam_at[4], cam_at[5], cam_at[6]), vec3(0, 1, 0))
  end
end
