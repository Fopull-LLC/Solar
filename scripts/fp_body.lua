-- FP BODY — first person with your own body drawn (playtest 2026-11-09d: "the
-- first person hands should be more immersive and use things like ik so no
-- matter what action you're doing they fit and look natural").
--
-- First person used to hide the whole crew and float a second model of the
-- held tool, gloves built in, on a camera of its own. Now the body stays: the
-- head and the helmet are put away (the camera is in them), the model sits a
-- few centimetres back of the eye (more as you look down, so the collar never
-- crosses the view and your chest, belt and boots come into sight), the torso
-- is square to the view, and the arms are posed by two-bone IK onto whatever
-- the hands are doing:
--   * a tool (gravity gun, laser, rifle): the third-person model at true size,
--     its grip held in the CAMERA's frame, both hands on its grips
--     (tool_belt.fpHold), with the view's sway, bob, kick and swap dip, pulled
--     in and tipped up by a wall in front;
--   * a case (Medkit, Repair Kit, Gas Can, Build Kit) in the left fist, low
--     left in the view, hanging plumb (item_hand.fpCarry); the slung items
--     ride the shoulder as in third person; the jobs that already pose the
--     arms (a repair, a treatment, a pour, a plant, a rope) are left to their
--     own IK, now in sight;
--   * a kit Ladder: both hands on its rails, sliding up hand over hand;
--   * E (a door, a crate, a console, a pump): a reach to what the crosshair is
--     on, or ahead of the chest, eased out and back; the Flashlight's switch
--     on the helmet when L clicks it.
-- Everything is posed in afterCamera, which planet_camera calls right after it
-- placed (and the rifle's optic turned) the view: every point is this frame's
-- drawn pose, so the hands are pinned to the camera with no lag on a planet
-- that moves metres a tick (docs/positions-and-frames.md, rules 2 and 5).
-- Kept between frames: only body-relative points (a press's target) and
-- camera-frame offsets.
--
-- Only the player's own Astronaut carries this script, and only in first
-- person on foot does it cost anything (`active`). Off (`enabled` false, or
-- save key `opt_fpBody` 0) first person goes back to the view models.
--
-- Published: `active`, `enabled`, `probe` (the hands in the camera's frame
-- after the IK, for tools/perf/fphandprobe), `ms` (this script's cost, eased).
-- `setEnabled(on)`, `press()` (probes: as E).

defaults = {
  enabled = true,
  --- metres the body sits behind the eye, standing and looking ahead
  back = 0.02,
  --- more of it looking straight down (the collar, the chest panel)
  back_down = 0.13,
  --- E reaches for what the crosshair is on within this
  press_reach = 2.4,
  press_in = 0.17,
  press_hold = 0.12,
  press_out = 0.32,
  --- the arm held out at most this far toward a far press (from the shoulder)
  arm_len = 0.62,
}

active = false
enabled = true
probe = { on = false, want = false }   -- want: a probe sets it to have the hands measured
ms = 0.0

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind, { quiet = true }) or nil; refs[kind] = r end
  return r
end
local function now() return time or 0 end
-- a wall clock for the cost readout (os.clock is CPU time summed over every
-- engine thread)
local function clock() return (app and app.wallClock and app.wallClock()) or os.clock() end
local function smooth(a, b, x)
  local t = math.max(0, math.min(1, (x - a) / (b - a)))
  return t * t * (3 - 2 * t)
end

local self_n, model_n, anim_n, face_n = nil, nil, nil, nil
local function rig(node)
  self_n = node or self_n
  if not (model_n and model_n.valid) then
    model_n, anim_n, face_n = nil, nil, nil
    for _, c in ipairs((self_n and self_n.children and self_n:children()) or {}) do
      if c.name == "AstroModel" then model_n = c end
    end
    if model_n then
      for _, c in ipairs(model_n:children() or {}) do if c.name == "Face" then face_n = c end end
    end
  end
  if model_n and not anim_n and model_n.animator then anim_n = model_n:animator() end
  return model_n, anim_n
end

-- ── the head away, the body set back ───────────────────────────────────────
-- The face (with its hair) is hidden here; the helmet, its visor and lamps by
-- suit.lua, which asks `active` (it owns their visibility). What the face was
-- is put back exactly when first person ends.
local face_was = nil
local set_back = 0.0
local function stow_head(on)
  if not (face_n and face_n.valid) then return end
  if on and face_was == nil then
    face_was = face_n.visible
    face_n.visible = false
  elseif not on and face_was ~= nil then
    face_n.visible = face_was
    face_was = nil
  end
end
local function place_body(m, back)
  if not (m and m.valid and self_n) then return end
  -- (every frame: the offset is along the model's facing, which turns)
  if back == 0 and set_back == 0 then return end
  set_back = back
  if back == 0 then m.x, m.z = 0, 0 return end
  -- the model's forward in its parent's (the Astronaut's) frame: its yaw
  -- turns +Z toward +X (the model is never pitched or rolled)
  local y = m.yaw or 0
  m.x, m.z = -back * math.sin(y), -back * math.cos(y)
end

function setEnabled(on)
  enabled = on ~= false
  if save and save.set then pcall(save.set, "opt_fpBody", enabled and 1 or 0) end
end

local function leave()
  stow_head(false)
  local m = rig()
  if set_back ~= 0 and m then place_body(m, 0) end
  probe.on = false
end

-- ── E: a reach to what you pressed ──────────────────────────────────────────
-- { t0, side ("Right"/"Left"), body, x, y, z (body-relative) } or a camera-
-- frame point { cam = {x, y, z} } (the flashlight's switch)
local reach_req = nil
local function to_body(x, y, z)
  local d = space and space.dominant and space.dominant(x, y, z)
  local b = d and space.body(d)
  if not b then return nil end
  return { body = d, x = x - b.x, y = y - b.y, z = z - b.z }
end
local function busy_hands()
  local C = ref("crew")
  if C and C.held and C.held() == true then return true end          -- a job or a rope holds the body
  if C and C.treating and C.treating() then return true end
  local IH = ref("item_hand")
  if IH and IH.busy and IH.busy() then return true end
  return false
end
-- Which hand is free to reach: the right, unless a tool is in both (then the
-- left leaves its fore-grip) or nothing but the left holds a case.
local function free_side()
  return "Right"
end
function press()
  local pc = ref("planet_camera")
  if not (pc and pc.cam_x and pc.fwd_x) then return false end
  if busy_hands() then return false end
  local tb = ref("tool_belt")
  local id = tb and tb.toolId and tb.toolId()
  local two = id == "gravgun" or id == "laser" or id == "surveyor"
  local side = two and "Left" or free_side()
  local ox, oy, oz = pc.cam_x, pc.cam_y, pc.cam_z
  local dx, dy, dz = pc.fwd_x, pc.fwd_y, pc.fwd_z
  local h = raycast and raycast(ox, oy, oz, dx, dy, dz, params.press_reach, self_n)
  local p
  if h and h.distance then
    p = to_body(ox + dx * h.distance, oy + dy * h.distance, oz + dz * h.distance)
  elseif tb and tb.eWant and self_n then
    -- nothing under the crosshair (a prompt by nearness): a reach ahead of
    -- the chest, along the flat view
    local u = self_n.worldUp and self_n:worldUp() or vec3(0, 1, 0)
    local f = vec3(dx, dy, dz)
    f = (f - u * f:dot(u)):normalized()
    local a = self_n.worldPos
    local q = a + u * 0.35 + f * 0.6
    p = to_body(q.x, q.y, q.z)
  end
  if not p then return false end
  p.t0, p.side = now(), side
  reach_req = p
  return true
end
local function press_flashlight()
  reach_req = { t0 = now(), side = "Left", cam = { -0.16, -0.02, 0.21 }, short = true }
end
local function press_weight(r)
  local t = now() - r.t0
  local k = r.short and 0.75 or 1.0
  local a, h, o = params.press_in * k, params.press_hold * k, params.press_out * k
  if t > a + h + o then return nil end
  if t < a then return smooth(0, a, t) end
  if t < a + h then return 1 end
  return 1 - smooth(a + h, a + h + o, t)
end

-- ── the kit ladder: hands on its rails ─────────────────────────────────────
-- What the feet stand on (asked ten times a second): a KitLadder's tread, or
-- the ladder within a stride ahead at the chest. Its rails are the tops of its
-- two side walls ("Wall 2", "Wall 3": 1 m tall boxes along the incline).
local lad = { t = -10, node = nil, w = 0.0 }
local function ladder_of(n)
  for _ = 1, 3 do
    if not (n and n.valid ~= false) then return nil end
    local nm = n.name or ""
    if nm:find("KitLadder", 1, true) then return n end
    n = n.parent
  end
  return nil
end
local function find_ladder(A, U, F)
  if now() - lad.t < 0.1 then return lad.node end
  lad.t = now()
  lad.node = nil
  if not raycast then return nil end
  local h = raycast(A.x, A.y, A.z, -U.x, -U.y, -U.z, 1.6, A)
  local L = h and ladder_of(h.node)
  probe.under = h and h.node and (tostring(h.node.name) .. "<" .. tostring(h.node.parent and h.node.parent.name)) or "nothing"
  if not L then
    local c = A.worldPos + U * 0.2
    h = raycast(c.x, c.y, c.z, F.x, F.y, F.z, 0.9, A)
    L = h and ladder_of(h.node)
  end
  if L then
    local w2, w3
    for _, c in ipairs(L:children() or {}) do
      if c.name == "Wall 2" then w2 = c elseif c.name == "Wall 3" then w3 = c end
    end
    if w2 and w3 then lad.node = { L = L, a = w2, b = w3 } end
  end
  return lad.node
end
-- the point of a rail (the top edge of a side wall) `ahead` metres in front of
-- the shoulder `s` along the body's facing `f` (clamped to the rail's ends)
local function rail_point(w, s, f, ahead)
  local a = w:toWorld(vec3(0, 0.5, -1.6))
  local b = w:toWorld(vec3(0, 0.5, 1.6))
  local ab = b - a
  local k = ab:dot(f)
  local t = math.abs(k) > 1e-4 and (ahead - (a - s):dot(f)) / k or 0.5
  t = math.max(0, math.min(1, t))
  return a + ab * t
end

-- ── the frame ──────────────────────────────────────────────────────────────
function update(node, dt)
  self_n = node
  local pc, pw = ref("planet_camera"), ref("planet_walker")
  local want = enabled and pc ~= nil and pc.firstPerson == true and pc.cockpit ~= true and pc.freecam ~= true
    and pw ~= nil and pw.onFoot == true and node.valid ~= false
  local was = active
  active = want == true
  if was and not active then leave() end
  if not active then reach_req = nil return end
  local tb = ref("tool_belt")
  local typing = tb and tb.text_focus and tb.text_focus()
  -- (E is also the laser's cut and the gravity gun's stow: with a tool in the
  -- hands only a prompt's E reaches)
  if not typing and input and input.pressed and input.pressed("e") == true then
    local id = tb and tb.toolId and tb.toolId()
    local two = id == "gravgun" or id == "laser" or id == "surveyor"
    if (tb and tb.eWant) or not two then press() end
  end
  -- the flashlight clicked on or off (L): a touch at its switch
  local fl = ref("flashlight")
  if fl then
    if lad.fl ~= nil and fl.on ~= lad.fl and not busy_hands() then press_flashlight() end
    lad.fl = fl.on
  end
end

local function cam_frame(cn, w)
  local E = cn.worldPos
  local d = w - E
  return d:dot(cn:worldRight()), d:dot(cn:worldUp()), d:dot(cn:worldForward())
end

function afterCamera(cn, dt)
  if not active then
    if probe.on then probe.on = false end
    return
  end
  local c0 = clock()
  local m, an = rig()
  if not (m and m.valid and an and an.reach and cn and cn.valid) then return end
  local A = self_n
  local pc, pw = ref("planet_camera"), ref("planet_walker")
  stow_head(true)
  local o = m:toWorld(vec3(0, 0, 0))
  local U = A:worldUp()
  local Fc = cn:worldForward()
  local pitch = math.asin(math.max(-1, math.min(1, Fc:dot(U))))
  local busy = busy_hands()
  -- the torso square to the view as it is NOW (the walker turned it to the
  -- view of its update, a frame of mouse ago), unless a job turned it
  if not busy and pw and pw.params then
    local fl = Fc - U * Fc:dot(U)
    if fl:length() > 1e-4 then
      local l = A:toLocal(A.worldPos + fl)     -- (the Astronaut's own origin is 0 in its frame)
      local lx, lz = l.x, l.z
      if lx * lx + lz * lz > 1e-8 then m.yaw = math.atan2(lx, lz) + (pw.params.face_offset or 0) end
    end
  end
  place_body(m, params.back + params.back_down * math.max(0, -math.sin(pitch)))
  -- the hands
  local tb, IH = ref("tool_belt"), ref("item_hand")
  local action, rt, lt = "free", nil, nil
  if not busy then
    if tb and tb.gate == "in hand" and tb.fpHold then
      rt, lt = tb.fpHold(cn, dt)
      if rt then action = "tool" end
    end
    if not rt and IH and IH.fpCarry then
      local a2, r2, l2 = IH.fpCarry(cn, dt)
      if a2 then action, rt, lt = a2, r2, l2 end
    end
    -- the ladder: hands on the rails while the hands are free
    local Fm = (m:toWorld(vec3(0, 0, 1)) - o):normalized()
    local L = (action == "free") and find_ladder(A, U, Fm) or nil
    lad.w = lad.w + ((L and 1 or 0) - lad.w) * (1 - math.exp(-(L and 9 or 6) * dt))
    if L then lad.cur = L end
    local LL = lad.cur
    if lad.w > 0.01 and LL and LL.a.valid and LL.b.valid then
      local sr, sl = an:boneWorld("Upperarm.Right"), an:boneWorld("Upperarm.Left")
      if sr and sl then
        local Rm = (m:toWorld(vec3(-1, 0, 0)) - o):normalized()
        -- hand over hand with the stride: each hand a little ahead in turn
        local ph = (pw and pw.gaitPhase) or 0
        local sw = math.sin(ph * 2 * math.pi) * 0.12
        for _, side in ipairs({ { "Right", sr, Rm, sw }, { "Left", sl, -Rm, -sw } }) do
          -- the rail on this shoulder's side, a forearm ahead
          local ahead = 0.46 + side[4]
          local pa, pb = rail_point(LL.a, side[2], Fm, ahead), rail_point(LL.b, side[2], Fm, ahead)
          local pt = ((pa - side[2]):length() < (pb - side[2]):length()) and pa or pb
          pt = pt + U * 0.04
          an:reach("Hand." .. side[1], pt, { pole = side[2] - U * 0.45 + side[3] * 0.35, weight = lad.w })
        end
        action = "ladder"
      end
    end
  end
  -- E: the reach, over whatever the hand was doing
  local r = reach_req
  if r and not busy then
    local w = press_weight(r)
    if not w then
      reach_req = nil
    else
      local sh = an:boneWorld("Upperarm." .. r.side)
      local tgt
      if r.cam then
        local E = cn.worldPos
        tgt = E + cn:worldRight() * r.cam[1] + cn:worldUp() * r.cam[2] + Fc * r.cam[3]
      else
        local b = space.body(r.body)
        if b then tgt = vec3(b.x + r.x, b.y + r.y, b.z + r.z) end
      end
      if sh and tgt then
        -- the wrist a hand's length short of the point, never past arm's length
        local d = tgt - sh
        local dl = d:length()
        if dl > 1e-4 then
          local dir = d * (1 / dl)
          local reach = math.min(dl - (r.cam and 0 or 0.09), params.arm_len)
          local wt = sh + dir * math.max(0.15, reach)
          local Rm = (m:toWorld(vec3(-1, 0, 0)) - o):normalized()
          local out = r.side == "Right" and Rm or -Rm
          an:reach("Hand." .. r.side, wt, { pole = sh - U * 0.45 + out * 0.3, weight = w })
          an:lookAt({ "Hand." .. r.side }, wt + dir * 0.2,
            { axis = vec3(r.side == "Right" and -0.996 or 0.996, 0.036, 0.08), limit = 80, weight = 0.8 * w })
          action = action .. "+press"
        end
      end
    end
  end
  -- what the hands did, in the camera's frame, read after the IK (only when a
  -- probe asks: probe.want)
  if not probe.want then
    probe.on, probe.action = false, action
    ms = ms + ((clock() - c0) * 1000 - ms) * 0.05
    return
  end
  local hr, hl = an:boneWorld("Hand.Right"), an:boneWorld("Hand.Left")
  probe.on, probe.t, probe.action = hr ~= nil, now(), action
  if hr then
    probe.rx, probe.ry, probe.rz = cam_frame(cn, hr)
    probe.rerr = rt and (hr - rt):length() or -1
  end
  if hl then
    probe.lx, probe.ly, probe.lz = cam_frame(cn, hl)
    probe.lerr = lt and (hl - lt):length() or -1
  end
  -- (the hand that holds: the left for a case, else the right)
  if action:sub(1, 4) == "case" and hl then probe.hx, probe.hy, probe.hz = probe.lx, probe.ly, probe.lz
  else probe.hx, probe.hy, probe.hz = probe.rx, probe.ry, probe.rz end
  local E = cn.worldPos
  probe.clear = math.min(hr and (hr - E):length() or 9, hl and (hl - E):length() or 9)
  local cc = cn.getcomponent and cn:getcomponent("Camera")
  probe.fov = (cc and (cc.fovY or 0) > 0.01 and cc.fovY) or 1.15
  ms = ms + ((clock() - c0) * 1000 - ms) * 0.05
end

function start(node)
  self_n = node
  enabled = params.enabled ~= false
  local v = save and save.get and save.get("opt_fpBody")
  if v ~= nil then enabled = v ~= 0 end
  rig(node)
end
