-- CAMCLEAR_MON — is a cutscene camera ever inside a body? (uxpolish 2026-11-11,
-- Ty: "cutscene camera still clipping inside of astronaut bodies").
-- Spliced into scnprobe.sh's perfbench by EXTRA_LUA=tools/perf/camclear_mon.lua.
-- Every frame a shot or a cutscene is up, right after planet_camera placed
-- the view (pc.deferLate, so camera and bodies are this frame's drawn poses),
-- it measures the camera's distance to each visible body's capsule axis (the
-- crew on foot and the player; segment ±0.64 m about the capsule centre,
-- along the local vertical). Under 0.42 m the camera is inside the suit.
-- Lines: "CC " once a second during shots, and "CC TOTAL" at the end. It
-- also says which pose the physics queries answer in: a ray down from the
-- player's drawn centre and from its tick centre (the capsule's half height,
-- 0.95, is the right answer).
local CC = { frames = 0, bad = 0, minD = 99, worst = nil, last = -1, shift = 0, maxShift = 0, rays = {} }
local cc_pc = nil
local function cc_seg(p, c, u, h)
  local q = p - c
  local s = math.max(-h, math.min(h, q:dot(u)))
  return (q - u * s):length()
end
local function cc_late()
  local pc = cc_pc
  if not (pc and pc.cam_x) then return end
  local stg = findScript("scenario_stage", { quiet = true })
  local cut = stg and stg.cutsceneOn and stg.cutsceneOn()
  local w = pc.shotW or 0
  local on = pc.shotOn and pc.shotOn()
  if not (w > 0 or cut or on) then return end
  CC.frames = CC.frames + 1
  local cam = vec3(pc.cam_x, pc.cam_y, pc.cam_z)
  local nodes = {}
  local C = findScript("crew", { quiet = true })
  if C and C.bodyNodes then for id, n in pairs(C.bodyNodes()) do nodes[#nodes + 1] = { n, "crew" .. tostring(id) } end end
  local a = find("Astronaut")
  -- (the player's own eyes in first person, fp_body's headless body set
  -- back from the view, is first person working, not a camera in a body:
  -- a cutscene with no shot up, and a blend's first frame)
  if a and not (pc.firstPerson and pc.fp_drawn) then nodes[#nodes + 1] = { a, "player" } end
  local dmin, who = 99, nil
  for _, e in ipairs(nodes) do
    local n = e[1]
    if n and n.valid ~= false and n.visible ~= false and n.worldPos then
      local p = n.worldPos
      local b = space.dominant(p.x, p.y, p.z)
      local bb = b and space.body(b)
      local u = bb and (p - vec3(bb.x, bb.y, bb.z)):normalized() or vec3(0, 1, 0)
      local d = cc_seg(cam, p, u, 0.64)
      if d < dmin then dmin, who = d, e[2] end
    end
  end
  if dmin < CC.minD then CC.minD, CC.worst = dmin, who end
  if dmin < 0.42 then CC.bad = CC.bad + 1 end
  if a and a.tickPos and a.worldPos then
    local s = (a.tickPos - a.worldPos):length()
    CC.shift = s
    if s > CC.maxShift then CC.maxShift = s end
  end
  if time - CC.last >= 1.0 then
    CC.last = time
    local sp = pc.shotProbe or {}
    -- which pose do the queries answer in?
    local rw, rt = -1, -1
    if a and a.worldPos and a.tickPos and raycast then
      local p = a.worldPos
      local b = space.dominant(p.x, p.y, p.z)
      local bb = b and space.body(b)
      local u = bb and (p - vec3(bb.x, bb.y, bb.z)):normalized() or vec3(0, 1, 0)
      local h1 = raycast(p, u * -1, 6, a)
      local h2 = raycast(a.tickPos, u * -1, 6, a)
      rw, rt = h1 and h1.distance or -1, h2 and h2.distance or -1
    end
    print(string.format("CC t %.1f w %.2f cut %s nearest %.2f m (%s) bodies %d shift %.2f m swing %s pulled %s | ray down drawn %.2f tick %.2f",
      time, w, tostring(cut), dmin, tostring(who), #nodes, CC.shift, tostring(sp.swing), tostring(sp.pulled), rw, rt))
  end
end
function MON_tick()
  if not (cc_pc and cc_pc.valid ~= false) then cc_pc = findScript("planet_camera", { quiet = true }) end
  if cc_pc and cc_pc.deferLate and NODE then pcall(cc_pc.deferLate, NODE, 0, cc_late) end
end
function MON_total()
  print(string.format("CC TOTAL shot frames %d, camera inside a body %d, nearest %.2f m (%s), tick-drawn gap max %.2f m",
    CC.frames, CC.bad, CC.minD, tostring(CC.worst), CC.maxShift))
end
