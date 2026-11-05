-- ── partshots: the craft parts and the lab in the real game (tools/perf/partshots.sh) ──
-- Spliced into a copy of perfbench.lua before its main (the repo's perfbench is
-- untouched), for the realistic-texture wave 3 (textures/parts, textures/lab): the lab's
-- interior from fixed points, the VAB with the two-stage rocket on the stand, then that
-- rocket on the pad, a plane on the runway and the rover beside it, each photographed
-- up close from fixed points in the craft's own frame. `PS` lines; pictures to
-- user://partshots/<name>.png.
--
-- The cameras go through planet_camera.setShot, whose function is called in the
-- camera's late pass every frame: every point is re-derived there from drawn poses
-- (the craft's root node:toWorld, the lab root's toWorld), never kept across frames
-- (docs/positions-and-frames.md rules 1, 2 and 6).
-- (one local for the lot: perfbench's main chunk is near Lua's 200-local limit)
local PSX = {}
function PSX.PS(fmt, ...) P("PS " .. fmt, ...) end
PSX.pending = 0
function PSX.ps_shot(name)
  PSX.pending = PSX.pending + 1
  local ok, err = pcall(camera.capture, { w = 1600, h = 900, ui = false, draws = false }, function(bytes, why)
    PSX.pending = PSX.pending - 1
    if bytes then assets.writeBytes("user://partshots/" .. name .. ".png", bytes); PSX.PS("SHOT %s", name)
    else PSX.PS("SHOT %s failed %s", name, tostring(why)) end
  end)
  if not ok then PSX.pending = PSX.pending - 1; PSX.PS("capture error %s", tostring(err)) end
end
function PSX.ps_cam(fn) local pc = findScript("planet_camera"); if pc and pc.setShot then pc.setShot(fn, 0.05) end end
function PSX.ps_cam_off() local pc = findScript("planet_camera"); if pc and pc.clearShot then pc.clearShot(0.05) end end

-- A view in a node's own frame: eye and target local points, the node's local +y up.
function PSX.node_view(n, eye, tgt)
  PSX.ps_cam(function()
    if not (n and n.valid) then return nil end
    local a, b = n:toWorld(vec3(eye[1], eye[2], eye[3])), n:toWorld(vec3(tgt[1], tgt[2], tgt[3]))
    local o, u = n.worldPos, n:toWorld(vec3(0, 1, 0))
    return a.x, a.y, a.z, b.x, b.y, b.z, u.x - o.x, u.y - o.y, u.z - o.z
  end)
end

function PSX.ps_views(n, prefix, views)
  local i = assembly.info(n)
  local o, ux, rx, fz = n.worldPos, n:toWorld(vec3(0, 1, 0)), n:toWorld(vec3(1, 0, 0)), n:toWorld(vec3(0, 0, 1))
  if i and i.com then
    -- (a log line only: the com in the root's frame, to place the views)
    local d = { x = i.com.x - o.x, y = i.com.y - o.y, z = i.com.z - o.z }
    local function dd(p) return d.x * (p.x - o.x) + d.y * (p.y - o.y) + d.z * (p.z - o.z) end
    PSX.PS("%s: %d parts, com in root frame (%.2f, %.2f, %.2f)", prefix, #i.parts, dd(rx), dd(ux), dd(fz))
  end
  for _, v in ipairs(views) do
    PSX.node_view(n, v[2], v[3])
    wait(1.2)
    PSX.ps_shot(prefix .. "_" .. v[1])
    wait(0.5)
  end
  PSX.ps_cam_off()
end

-- the lab: its ground frame (x east, y up from the slab, z south; tools/gen_lab.py) is the
-- lab root's local frame shifted (tools/perf/labprobe.lua labpt)
function PSX.ps_lab()
  local L = wait_for(function() local l = findScript("lab"); return l and l.ROOT and l.ROOT.valid and l end, 60, "the lab")
  if not L then PSX.PS("no lab"); return end
  local function lp(x, y, z) return { x, y - 4.24, z - 2.05 } end
  local p = L.ROOT:toWorld(vec3(8.0, 0.6 - 4.24, 5.6 - 2.05))
  local a = astro()
  local b = home()
  local u = unit({ x = p.x - b.x, y = p.y - b.y, z = p.z - b.z })
  local h = raycast(p.x + u.x * 3, p.y + u.y * 3, p.z + u.z * 3, -u.x, -u.y, -u.z, 10, { ignore = a })
  if h then a.x, a.y, a.z = h.x + u.x * 1.1, h.y + u.y * 1.1, h.z + u.z * 1.1; a.vx, a.vy, a.vz = 0, 0, 0 end
  local on = wait_for(function() return L.inside end, 15, "the lab interior")
  PSX.PS("lab interior on %s", tostring(on))
  wait(2.0)
  local V = {
    { "lab_from_door", lp(6.0, 1.7, 2.8), lp(-8, 1.1, -1.5) },
    { "lab_hoods", lp(-5.6, 1.65, -2.6), lp(-8.2, 1.35, -6.4) },
    { "lab_island", lp(-3.0, 1.75, 2.6), lp(-6.0, 1.0, 0.2) },
    { "lab_floor_low", lp(1.0, 0.45, 5.0), lp(-6, 0.8, -3) },
    { "lab_wall_bench", lp(-1.0, 1.6, 1.0), lp(-2.0, 1.0, 6.0) },
    { "lab_floor_feet", lp(2.0, 1.6, 3.0), lp(2.6, 0.15, 2.0) },
  }
  PSX.ps_views(L.ROOT, "lab", V)
end

function PSX.ps_vab()
  local BH = enter_vab("ps_vab")
  if not BH then PSX.PS("no builder"); return end
  local B = findScript("builder")
  wait(1.0)
  local rs = findScript("research")
  for _, id in ipairs({ "tankM", "engineM", "skipper" }) do if rs and rs.grant then rs.grant(id, "probe") end end
  load_bp(B, "ps_bp", rocket_2stage())
  local bc = findScript("builder_camera")
  if bc and bc.frameCraft then bc.frameCraft() end
  wait(3)
  PSX.ps_shot("vab_craft")
  wait(0.5)
end

function PSX.run_partshots()
  if (params.lab or 1) > 0 then PSX.ps_lab() end
  -- (the VAB last, its own run: a standalone builder loaded from the VAB's overlay has no doLaunch)
  if (params.vab or 0) > 0 then PSX.ps_vab(); PSX.finish(); return end
  if (params.crafts or 1) <= 0 then PSX.finish(); return end
  local rs = findScript("research")
  for _, id in ipairs({ "tankM", "engineM", "skipper" }) do if rs and rs.grant then rs.grant(id, "probe") end end
  -- the two-stage rocket on the pad (root: the Skipper at the bottom of the stack)
  local vc = launch_via_builder(rocket_2stage(), "pad", 9)
  if vc then
    wait_regrade(); wait(3)
    PSX.ps_views(vc.node, "pad", {
      { "full", { 7.5, 4.5, 7.5 }, { 0, 4.5, 0 } },
      { "bell", { 2.0, 0.6, 2.0 }, { 0, 0.4, 0 } },
      { "tank", { 1.7, 3.2, 1.2 }, { 0, 3.0, 0 } },
      { "stage", { 1.6, 5.9, -1.3 }, { 0, 5.6, 0 } },
      { "pod", { 1.5, 9.2, 1.3 }, { 0, 8.8, 0 } },
    })
  else PSX.PS("no rocket") end
  -- a plane on the runway (nose +x, wings along z: perfbench plane())
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  save.set("shipyard.blueprint", { parts = rocket_bp(1) })
  save.set("shipyard.site", "pad")
  scene.load("builder")
  wait_for(function() local B = findScript("builder"); return B and B.partUids and #B.partUids() >= 4 end, 90, "the builder")
  wait(1.5)
  local pa = findScript("parts_aero")
  if not pa then spawn("AeroLib", vec3(0, 0, 0)); pa = wait_for(function() return findScript("parts_aero") end, 10, "parts_aero") end
  local k = save.get("parts.rating") or { thrust = 1.4, ve = 1 }
  local list = {}
  for _, r in ipairs(plane()) do
    local def = pa and pa.PARTS[r.id]
    if def then list[#list + 1] = full(r, def, k) end
  end
  save.set("shipyard.blueprint", { parts = list, catalogue = { thrust = k.thrust, ve = k.ve } })
  save.set("shipyard.launch", 1)
  save.set("shipyard.site", "runway")
  save.set("shipyard.pilot", 1)
  scene.load("system")
  yield()
  local pv = wait_craft(#list, 150)
  if pv then
    wait_regrade(); wait(3)
    PSX.ps_views(pv.node, "rwy", {
      { "full", { 7.0, 4.0, 8.0 }, { 0, 1.4, 0 } },
      { "nose", { 4.6, 2.0, 2.2 }, { 1.6, 1.5, 0 } },
      { "wing", { -0.4, 3.2, 4.6 }, { -0.6, 1.5, 2.6 } },
      { "gear", { 0.9, 0.55, 2.8 }, { -0.45, 0.55, 1.4 } },
      { "tail", { -5.2, 2.4, 2.6 }, { -2.2, 1.7, 0 } },
    })
  else PSX.PS("no plane") end
  -- the rover on the runway
  local rv = launch_via_builder(ROVER, "runway", 6)
  if rv then
    wait_regrade(); wait(3)
    PSX.ps_views(rv.node, "rover", {
      { "side", { 0.6, 1.3, 2.8 }, { 0, 0.5, 0 } },
      { "wheel", { 1.4, 0.6, 1.7 }, { 0.66, 0.0, 0.7 } },
      { "deck", { 1.6, 2.3, 1.2 }, { 0, 0.2, 0 } },
    })
  else PSX.PS("no rover") end
  PSX.finish()
end
function PSX.finish()
  wait_for(function() return PSX.pending <= 0 end, 20, "the pictures")
  PSX.PS("DONE")
end

