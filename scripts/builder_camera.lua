-- BUILDER CAMERA — an orbit camera about a pivot, built for crafts of any size
-- (docs/builder-design.md §4.2, §8.6; WP2).
--
--   RMB drag          orbit about the point under the cursor (or the selection)
--   RMB + W/A/S/D/Q/E fly (Unreal style): the mouse looks, the keys move
--   MMB / SHIFT+RMB   pan
--   wheel             zoom toward the cursor, by a factor (params.wheel a notch)
--   CTRL+wheel        camera height step       ALT+wheel  slide along the craft
--   F / HOME          frame the selection / the whole craft (real bounds)
--   PGUP / PGDN       height ±10 % of the craft (also the HT slider)
--   NUM 1 / 3 / 7     front / side / top view; NUM 5 near-orthographic (telephoto)
--   F4 hide the UI · F6 photo orbit · F12 screenshot
--
-- Everything is worked in the builder's frame (builder.frame(): the BuildFrame
-- on the real VAB, or the identity in standalone builder.ron) and turned into
-- the world only when the node is placed, in lateUpdate.
--
-- An RMB press that never moves 4 px is a CLICK, not an orbit: it is published
-- as `rmbClick` for the context menu (builder_context.lua).
--
-- Published: pivot {x,y,z} (frame), pivotWorld, camPos (world), dist, ortho,
-- photoOrbit, rmbClick = { seq, x, y, uid }, heightFrac(), setHeightFrac(f),
-- frameSelection(), frameCraft(), bounds() (the craft's box, frame).

defaults = {
  look = 0.0032,      -- orbit radians per pixel
  speed = 8.0,        -- RMB+WASD fly speed, m/s (SHIFT ×4)
  wheel = 1.2,        -- zoom factor per wheel notch
}

focusing = false      -- legacy: the old builder read this; always false now

local MIN_D, MAX_D = 0.5, 400.0
local PITCH_MAX = math.pi * 0.5 - 0.02
local FLOOR = 0.3               -- the camera never goes under the deck (frame y)
local DRAG_PX = 4
local PHOTO_RATE = math.rad(9)
local ORTHO_FOV = 0.12          -- the "orthographic" view is a long lens
local SLICE = 250               -- parts read per frame while the bounds refresh

-- ── vector maths on plain numbers (testable without the engine) ─────────────
local function v(x, y, z) return { x = x, y = y, z = z } end
local function add(a, b) return v(a.x + b.x, a.y + b.y, a.z + b.z) end
local function sub(a, b) return v(a.x - b.x, a.y - b.y, a.z - b.z) end
local function mul(a, k) return v(a.x * k, a.y * k, a.z * k) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b) return v(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end
-- v turned about unit axis k by angle a (Rodrigues).
local function turn(p, k, a)
  local c, s = math.cos(a), math.sin(a)
  local kx = cross(k, p)
  local d = dot(k, p)
  return v(p.x * c + kx.x * s + k.x * d * (1 - c), p.y * c + kx.y * s + k.y * d * (1 - c),
           p.z * c + kx.z * s + k.z * d * (1 - c))
end

-- The view basis for a yaw and pitch (frame axes; -Z forward at yaw 0).
function viewBasis(yaw, pitch)
  local cy, sy, cp, sp = math.cos(yaw), math.sin(yaw), math.cos(pitch), math.sin(pitch)
  local f = v(-sy * cp, sp, -cy * cp)
  local r = v(cy, 0, -sy)
  return f, r, cross(r, f)
end

-- The box round a list of { x, y, z, r } (planet_camera's craftBounds, on
-- plain tables): lo/hi, centre, radius, axis (the longest side).
function craftBounds(list)
  if not list or #list == 0 then return nil end
  local h = math.huge
  local lo, hi = v(h, h, h), v(-h, -h, -h)
  for _, p in ipairs(list) do
    local r = p.r or 0
    lo.x, lo.y, lo.z = math.min(lo.x, p.x - r), math.min(lo.y, p.y - r), math.min(lo.z, p.z - r)
    hi.x, hi.y, hi.z = math.max(hi.x, p.x + r), math.max(hi.y, p.y + r), math.max(hi.z, p.z + r)
  end
  return boxOf(lo, hi)
end

function boxOf(lo, hi)
  local s = sub(hi, lo)
  local axis = "y"
  if s.x > s.y and s.x >= s.z then axis = "x" elseif s.z > s.y and s.z > s.x then axis = "z" end
  return { lo = lo, hi = hi, centre = mul(add(lo, hi), 0.5), size = s,
           radius = 0.5 * math.sqrt(dot(s, s)), axis = axis }
end

-- How far back along `f` a camera must stand from `c` to hold every corner of
-- the box inside the view (vertical half-angle tan `tv`, aspect `asp`), with a
-- margin: a tall stack fills the height, a wide wing the width.
function fitDistance(b, c, f, r, u, tv, asp, margin)
  margin = margin or 0.88
  local tvm, thm = tv * margin, tv * asp * margin
  local need = 0
  for i = 0, 7 do
    local k = v(i % 2 == 0 and b.lo.x or b.hi.x, math.floor(i / 2) % 2 == 0 and b.lo.y or b.hi.y,
                math.floor(i / 4) == 0 and b.lo.z or b.hi.z)
    local d = sub(k, c)
    local x, y, z = dot(d, r), dot(d, u), dot(d, f)
    need = math.max(need, z + math.abs(y) / tvm, z + math.abs(x) / thm)
  end
  return clamp(need, MIN_D, MAX_D)
end

-- A zoom by factor k centred on the point Q (a homothety): Q stays on the same
-- pixel exactly, because the camera slides along the line through Q.
function zoomAbout(C, P, Q, k)
  return add(Q, mul(sub(C, Q), k)), add(Q, mul(sub(P, Q), k))
end

-- ── state ───────────────────────────────────────────────────────────────────
local S = {
  P = v(0, 2.0, 0),               -- the pivot (frame), on the view axis
  yaw = 0.35, pitch = -0.22, d = 14.0,
  goal = nil,                     -- { P, d } an eased framing
  rmb = nil,                      -- { x, y, t, dragged, Q, fly, uid }
  mmb = nil,
  fov = 1.08, fov0 = nil,
  bounds = nil, bver = -1, scan = nil,
  ui_hidden = false, layers = nil,
  clicks = 0,
}
pivot = { x = 0, y = 2, z = 0 }
pivotWorld = { x = 0, y = 2, z = 0 }
camPos = { x = 0, y = 4, z = 14 }
dist = S.d
ortho = false
photoOrbit = false
rmbClick = { seq = 0 }

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function B() return ref("builder") end

local function cam_pos()
  local f = viewBasis(S.yaw, S.pitch)
  return sub(S.P, mul(f, S.d))
end
-- Set the camera from a position and a pivot on its axis.
local function set_from(C, P)
  local f = viewBasis(S.yaw, S.pitch)
  S.P = P
  S.d = clamp(dot(sub(P, C), f), MIN_D, MAX_D)
end
-- No look up so steep that the camera sinks under the deck.
local function floor_clamp()
  local lim = (S.P.y - FLOOR) / math.max(S.d, 1e-3)
  if lim < 1 then
    local pmax = math.asin(clamp(lim, -1, 1))
    if S.pitch > pmax then S.pitch = math.max(-PITCH_MAX, pmax) end
  end
  S.pitch = clamp(S.pitch, -PITCH_MAX, PITCH_MAX)
end

-- ── the craft's bounds, refreshed a slice at a time ─────────────────────────
-- Each part is a ball round its centre (the registry's half extents). At 1,000
-- parts the walk is spread over four frames, so no frame pays for all of it.
local function part_ball(rec)
  local d = rec.def or {}
  local hx, hy, hz = d.rx or 0.5, (d.h or 1) * 0.5, d.rz or d.rx or 0.5
  if rec.size and rec.size.len then hy = math.max(hy, rec.size.len * 0.5) end
  return { x = rec.x, y = rec.y, z = rec.z, r = math.sqrt(hx * hx + hy * hy + hz * hz) }
end
local function scan_step(b)
  local ver = b.craftVersion or 0
  if not S.scan then
    -- A new walk only when the craft changed, and at most twice a second (a
    -- drag bumps the version every frame).
    if ver == S.bver then return end
    if S.bounds_t and (time or 0) - S.bounds_t < 0.5 then return end
    S.scan = { ver = ver, uids = b.partUids(), i = 1, lo = nil, hi = nil }
  end
  local sc = S.scan
  local n = #sc.uids
  local stop = math.min(n, sc.i + SLICE - 1)
  for i = sc.i, stop do
    local rec = b.partRec(sc.uids[i])
    if rec then
      local p = part_ball(rec)
      if not sc.lo then sc.lo, sc.hi = v(p.x - p.r, p.y - p.r, p.z - p.r), v(p.x + p.r, p.y + p.r, p.z + p.r)
      else
        sc.lo.x, sc.lo.y, sc.lo.z = math.min(sc.lo.x, p.x - p.r), math.min(sc.lo.y, p.y - p.r), math.min(sc.lo.z, p.z - p.r)
        sc.hi.x, sc.hi.y, sc.hi.z = math.max(sc.hi.x, p.x + p.r), math.max(sc.hi.y, p.y + p.r), math.max(sc.hi.z, p.z + p.r)
      end
    end
  end
  sc.i = stop + 1
  if sc.i > n then
    S.bounds = sc.lo and boxOf(sc.lo, sc.hi) or nil
    S.bver, S.scan, S.bounds_t = sc.ver, nil, time or 0
  end
end
-- The whole box now (a key press): finishes any scan in one go.
local function bounds_now()
  local b = B()
  if not (b and b.partUids) then return S.bounds end
  S.scan = nil
  S.bver = -1
  S.scan = { ver = b.craftVersion or 0, uids = b.partUids(), i = 1 }
  repeat scan_step(b) until not S.scan
  return S.bounds
end
function bounds() return S.bounds end

local function sel_bounds()
  local b = B()
  if not (b and b.selection) then return nil end
  local list = {}
  for _, u in ipairs(b.selection()) do
    local rec = b.partRec(u)
    if rec then list[#list + 1] = part_ball(rec) end
  end
  return craftBounds(list)
end

-- ── framing ─────────────────────────────────────────────────────────────────
local function aspect()
  local sw, sh = 16, 9
  if camera and camera.screenSize then
    local w, h = camera.screenSize()
    if w and h and h > 0 then sw, sh = w, h end
  end
  return sw / sh
end
-- The share of the view's half-height and half-width that the plates leave
-- clear round the screen's centre (builder_toolbar.builderLayout's viewport).
local function clear_share()
  local tb = ref("builder_toolbar")
  if not (tb and tb.builderLayout and tb.layerSize) then return 1, 1 end
  local W, H = tb.layerSize()
  local L = tb.builderLayout(W, H)
  local v = L.view
  if not v then return 1, 1 end
  local cx, cy = W * 0.5, H * 0.5
  local hx = math.min(cx - v.x, v.x + v.w - cx) / cx
  local hy = math.min(cy - v.y, v.y + v.h - cy) / cy
  return clamp(hy, 0.3, 1), clamp(hx, 0.2, 1)
end

local function frame_box(bx)
  if not bx then return false end
  local f, r, u = viewBasis(S.yaw, S.pitch)
  local sy, sx = clear_share()
  local d = fitDistance(bx, bx.centre, f, r, u, math.tan(S.fov * 0.5) * sy, aspect() * sx / sy)
  S.goal = { P = bx.centre, d = d }
  photoOrbit = false
  return true
end
function frameSelection()
  local bx = sel_bounds()
  if not bx then return frameCraft() end
  return frame_box(bx)
end
function frameCraft()
  local bx = bounds_now()
  if not bx then S.goal = { P = v(0, 2, 0), d = 14 } return false end
  return frame_box(bx)
end

-- ── the height slider (HT): the pivot from the craft's floor to its top ─────
local function height_range()
  local bx = S.bounds
  if not bx then return 0, 10 end
  return bx.lo.y, math.max(bx.hi.y, bx.lo.y + 0.5)
end
function heightFrac()
  local lo, hi = height_range()
  return clamp((S.P.y - lo) / (hi - lo), 0, 1)
end
function setHeightFrac(fr)
  local lo, hi = height_range()
  local y = lo + clamp(fr, 0, 1) * (hi - lo)
  S.goal = nil
  S.P = v(S.P.x, y, S.P.z)
  floor_clamp()
end
local function height_step(k)
  local lo, hi = height_range()
  S.goal = nil
  S.P = v(S.P.x, clamp(S.P.y + k * (hi - lo), lo, hi), S.P.z)
  floor_clamp()
end

-- Slide the pivot along the craft's long axis (the flight camera's Alt+scroll).
local function slide(clicks)
  local bx = S.bounds
  if not bx then return end
  local len = bx.size[bx.axis]
  local step = math.max(0.5, len * 0.08) * clicks
  local P = { x = S.P.x, y = S.P.y, z = S.P.z }
  P[bx.axis] = clamp(P[bx.axis] + step, bx.lo[bx.axis], bx.hi[bx.axis])
  S.goal = nil
  S.P = v(P.x, P.y, P.z)
  floor_clamp()
end

-- ── input helpers ───────────────────────────────────────────────────────────
-- The pointer is over the interface: a registered panel, or any element.
local function over_ui()
  if ui and ui.hovered and ui.hovered() then return true end
  local b = B()
  return b and b.panelsOwnMouse and b.panelsOwnMouse() or false
end
-- A text field has the keys (the part search, an inspector field).
local function typing()
  if not (ui and ui.focused) then return false end
  local f = ui.focused()
  return f ~= nil and type(f.name) == "string" and f.name:find("^Field") ~= nil
end
local function key(k) return input.key(k) end

-- The point the cursor ray meets at the depth worth zooming to: the part it
-- hits (builder.rayCraft), else the pivot's depth.
local function cursor_point(mx, my)
  local b = B()
  local fr = b and b.frame and b.frame()
  local ox, oy, oz, dx, dy, dz
  if fr and fr.ray then ox, oy, oz, dx, dy, dz = fr.ray(mx, my)
  elseif camera and camera.screenToRay then ox, oy, oz, dx, dy, dz = camera.screenToRay(mx, my) end
  if not ox then return nil end
  local O, D = v(ox, oy, oz), v(dx, dy, dz)
  if b and b.rayCraft then
    local uid, t = b.rayCraft(ox, oy, oz, dx, dy, dz)
    if uid and t and t > 0 then return add(O, mul(D, t)), uid end
  end
  local f = viewBasis(S.yaw, S.pitch)
  local den = dot(D, f)
  if den < 1e-4 then return nil end
  local t = dot(sub(S.P, O), f) / den
  return add(O, mul(D, t)), b and b.hovered and b.hovered() or nil
end

local function zoom(notches, mx, my)
  local k = (params.wheel or 1.2) ^ (-notches)
  local nd = S.d * k
  if nd < MIN_D then k = MIN_D / S.d elseif nd > MAX_D then k = MAX_D / S.d end
  if math.abs(k - 1) < 1e-6 then return end
  S.goal = nil
  local Q = mx and cursor_point(mx, my) or nil
  if not Q then S.d = S.d * k return end
  local C2, P2 = zoomAbout(cam_pos(), S.P, Q, k)
  S.P, S.d = P2, S.d * k
  local _ = C2
end

-- Orbit by mouse pixels about Q: a rigid turn of the camera round a point
-- holds that point on its pixel.
local function orbit(dx, dy, Q)
  local look = params.look or 0.0032
  local dyaw, dpitch = -dx * look, -dy * look
  local np = clamp(S.pitch + dpitch, -PITCH_MAX, PITCH_MAX)
  dpitch = np - S.pitch
  Q = Q or S.P
  local C = cam_pos()
  local up = v(0, 1, 0)
  C, S.P = add(Q, turn(sub(C, Q), up, dyaw)), add(Q, turn(sub(S.P, Q), up, dyaw))
  S.yaw = S.yaw + dyaw
  local _, r = viewBasis(S.yaw, S.pitch)
  C, S.P = add(Q, turn(sub(C, Q), r, dpitch)), add(Q, turn(sub(S.P, Q), r, dpitch))
  S.pitch = np
  set_from(C, S.P)
end

local function pan(dx, dy)
  local sh = 720
  if camera and camera.screenSize then local _, h = camera.screenSize(); sh = (h and h > 0) and h or sh end
  local k = 2 * S.d * math.tan(S.fov * 0.5) / sh
  local _, r, u = viewBasis(S.yaw, S.pitch)
  S.goal = nil
  S.P = add(S.P, add(mul(r, -dx * k), mul(u, dy * k)))
end

local function set_view(yaw, pitch)
  S.yaw, S.pitch, S.goal = yaw, pitch, nil
  floor_clamp()
end

local function set_ortho(on, camc)
  if on == ortho then return end
  local f0 = S.fov0 or S.fov
  local a, b = math.tan((ortho and ORTHO_FOV or f0) * 0.5), math.tan((on and ORTHO_FOV or f0) * 0.5)
  ortho = on
  S.fov = on and ORTHO_FOV or f0
  if camc then camc.fovY = S.fov end
  -- Same framing: the distance grows as the lens narrows (it may pass MAX_D).
  S.d = S.d * a / b
end

-- F4: every UI layer off (a picture); again to bring them back.
local function toggle_ui()
  S.ui_hidden = not S.ui_hidden
  if S.ui_hidden then
    S.layers = {}
    for _, nm in ipairs({ "Builder UI" }) do
      local n = find and find(nm)
      local l = n and n:getcomponent("UiLayer")
      if l then S.layers[#S.layers + 1] = { l = l, was = l.enabled }; l.enabled = false end
    end
  elseif S.layers then
    for _, c in ipairs(S.layers) do c.l.enabled = c.was ~= false and c.was ~= 0 end
    S.layers = nil
  end
end

local shot_n = nil
local function screenshot()
  if not (camera and camera.capture) then return end
  local sw, sh = 1920, 1080
  if camera.screenSize then sw, sh = camera.screenSize() end
  if not shot_n then
    shot_n = 0
    local ok, list = pcall(assets.getContents, "user://screenshots")
    if ok and type(list) == "table" then
      for _, path in ipairs(list) do
        local k = tonumber(tostring(path):match("solar_(%d+)%.png$"))
        if k and k > shot_n then shot_n = k end
      end
    end
  end
  shot_n = shot_n + 1
  local path = string.format("user://screenshots/solar_%04d.png", shot_n)
  pcall(camera.capture, { w = math.min(4096, sw), h = math.min(4096, sh), ui = not S.ui_hidden, draws = false },
    function(bytes) if bytes then assets.writeBytes(path, bytes) end end)
  local b = B()
  if b and b.hint then b.hint("screenshot saved — " .. path:gsub("^user://", ""), 2.5) end
end

-- ── the engine hooks ────────────────────────────────────────────────────────
local camc = nil
function start(node)
  camc = node.getcomponent and node:getcomponent("Camera") or nil
  if camc and camc.fovY then S.fov = camc.fovY end
  S.fov0 = S.fov
  floor_clamp()
end

function update(node, dt)
  local b = B()
  if b and b.partUids then scan_step(b) end
  if typing() then return end
  local mx, my = input.mouse()
  local ui_over = over_ui()

  -- RMB: a click (context menu) or a drag (orbit; fly with WASD held).
  local rmb = input.button(1)
  if rmb and not S.rmb and not ui_over then
    S.rmb = { x = mx, y = my, t = time or 0, dragged = false, uid = b and b.hovered and b.hovered() or nil }
  end
  if S.rmb then
    local R = S.rmb
    local dx, dy = input.mouse_delta()
    local flykeys = key("w") or key("a") or key("s") or key("d") or key("q") or key("e")
    if not R.dragged and (math.abs(mx - R.x) > DRAG_PX or math.abs(my - R.y) > DRAG_PX or flykeys) then
      R.dragged = true
      R.Q = (not key("shift")) and cursor_point(R.x, R.y) or nil
      local sel = (not R.uid) and sel_bounds() or nil
      if sel then R.Q = sel.centre end
      photoOrbit = false
    end
    if R.dragged and rmb then
      S.goal = nil
      if key("shift") and not flykeys then
        pan(dx, dy)
      elseif flykeys then
        -- Fly: look about the camera itself, move on the keys.
        if not R.fly then R.fly = true; input.lockMouse() end
        local C = cam_pos()
        local look = params.look or 0.0032
        S.yaw = S.yaw - dx * look
        S.pitch = clamp(S.pitch - dy * look, -PITCH_MAX, PITCH_MAX)
        local f, r = viewBasis(S.yaw, S.pitch)
        local mv = v(0, 0, 0)
        if key("w") then mv = add(mv, f) end
        if key("s") then mv = sub(mv, f) end
        if key("d") then mv = add(mv, r) end
        if key("a") then mv = sub(mv, r) end
        if key("e") then mv = add(mv, v(0, 1, 0)) end
        if key("q") then mv = sub(mv, v(0, 1, 0)) end
        local sp = (params.speed or 8) * (key("shift") and 4 or 1) * dt
        C = add(C, mul(mv, sp))
        if C.y < FLOOR then C.y = FLOOR end
        S.P = add(C, mul(f, S.d))
      else
        orbit(dx, dy, R.Q)
      end
    end
    if not rmb then
      if R.fly then input.unlockMouse() end
      if not R.dragged then
        rmbClick = { seq = (rmbClick.seq or 0) + 1, x = R.x, y = R.y, uid = R.uid }
      end
      S.rmb = nil
    end
  end

  -- MMB: pan.
  local mmb = input.button(2)
  if mmb and not S.mmb and not ui_over then S.mmb = true end
  if S.mmb then
    if mmb then local dx, dy = input.mouse_delta(); pan(dx, dy) else S.mmb = nil end
  end

  -- The wheel: zoom to the cursor; CTRL height; ALT slide along the craft.
  local sc = input.scroll() or 0
  if sc ~= 0 and not ui_over then
    if key("ctrl") then height_step(sc * 0.05)
    elseif key("alt") then slide(sc)
    else zoom(sc, mx, my) end
  end

  if input.pressed("f") and not key("ctrl") then frameSelection() end
  if input.pressed("home") then frameCraft() end
  if input.pressed("pageup") then height_step(0.10) end
  if input.pressed("pagedown") then height_step(-0.10) end
  if input.pressed("num1") then set_view(0, 0) end
  if input.pressed("num3") then set_view(math.pi * 0.5, 0) end
  if input.pressed("num7") then set_view(S.yaw, -PITCH_MAX) end
  if input.pressed("num5") then set_ortho(not ortho, camc) end
  if input.pressed("f4") then toggle_ui() end
  if input.pressed("f6") then photoOrbit = not photoOrbit; S.goal = nil end
  if photoOrbit and input.pressed("escape") then photoOrbit = false end
  if input.pressed("f12") then screenshot() end

  if photoOrbit then
    local C = cam_pos()
    C = add(S.P, turn(sub(C, S.P), v(0, 1, 0), PHOTO_RATE * dt))
    S.yaw = S.yaw + PHOTO_RATE * dt
    set_from(C, S.P)
  end

  -- An eased framing (F / Home): ~0.25 s, no overshoot.
  if S.goal then
    local a = 1 - math.exp(-dt * 14)
    S.P = add(S.P, mul(sub(S.goal.P, S.P), a))
    S.d = S.d + (S.goal.d - S.d) * a
    if dot(sub(S.goal.P, S.P), sub(S.goal.P, S.P)) < 1e-6 and math.abs(S.goal.d - S.d) < 1e-3 then
      S.P, S.d, S.goal = S.goal.P, S.goal.d, nil
    end
  end
  S.d = clamp(S.d, MIN_D, ortho and MAX_D * 20 or MAX_D)
  floor_clamp()
end

-- Placed after every update (the builder's picking reads last frame's view).
function lateUpdate(node, dt)
  local b = B()
  local fr = b and b.frame and b.frame() or nil
  -- The frame moves with the planet (~190 m/s on rails): the builder read its
  -- pose in update, and the rails have ticked since. Re-read it here, in the
  -- camera pass, or the view sits a frame's travel (several metres) off.
  if fr and not fr.identity and fr.refresh then fr.refresh() end
  local C = cam_pos()
  local wx, wy, wz = C.x, C.y, C.z
  local px, py, pz = S.P.x, S.P.y, S.P.z
  local ux, uy, uz = 0, 1, 0
  if fr and not fr.identity and fr.toWorld then
    wx, wy, wz = fr.toWorld(C.x, C.y, C.z)
    px, py, pz = fr.toWorld(S.P.x, S.P.y, S.P.z)
    ux, uy, uz = fr.dirToWorld(0, 1, 0)
  end
  node.x, node.y, node.z = wx, wy, wz
  if node.lookAt and vec3 then
    node:lookAt(vec3(px, py, pz), vec3(ux, uy, uz))
  else
    node.yaw, node.pitch, node.roll = S.yaw, S.pitch, 0
  end
  pivot = { x = S.P.x, y = S.P.y, z = S.P.z }
  pivotWorld = { x = px, y = py, z = pz }
  camPos = { x = wx, y = wy, z = wz }
  dist = S.d
end

-- For probes and tests: the whole state, and a way to set it.
function camState() return { P = S.P, yaw = S.yaw, pitch = S.pitch, d = S.d, fov = S.fov, goal = S.goal } end
function setCamState(t)
  if t.P then S.P = v(t.P.x, t.P.y, t.P.z) end
  S.yaw, S.pitch, S.d = t.yaw or S.yaw, t.pitch or S.pitch, t.d or S.d
  if t.fov then S.fov = t.fov end
  S.goal = nil
end
-- Zoom by notches toward a screen point (probes drive it without a wheel).
function zoomAt(notches, mx, my) zoom(notches, mx, my) end
function settle() if S.goal then S.P, S.d, S.goal = S.goal.P, S.goal.d, nil end end
