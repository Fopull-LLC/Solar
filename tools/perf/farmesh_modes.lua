-- ── farmesh (tools/perf/farmesh.sh): the far-body impostor's mesh.build, lists against buffers ──
-- mode "farmesh": a fresh save; a free camera parked over another world (the
-- biggest one far_bodies tracks, not home) at `fm_radii` of its radius
-- (default 3), looking at its centre, the map's focus on it, so it refines to
-- the focused level (6: 40,962 vertices). Then, for lists and for buffers in
-- turn (twice each, alternating), far_bodies.rebuild(): its meshes made again
-- (heights and paint from the disk cache, so only the vertex write and the
-- uploads), the two uploads' times read from far_bodies.stats(), a picture of
-- each (user://farmesh/<pass>.png, no UI), and the frames of the rebuild.
-- Lines "FMB ".
local FMB_DIR = "user://farmesh/"
local function fmb_shot(nm)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = false, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes(FMB_DIR .. nm .. ".png", bytes); P("FMB SHOT %s", nm) else P("FMB SHOT %s failed %s", nm, tostring(why)) end
    done = true
  end)
  if ok then wait_for(function() return done end, 8, "shot " .. nm) else P("FMB SHOT %s: capture refused", nm) end
end
local function run_farmesh()
  wait_ready(150)
  local fb = findScript("far_bodies")
  local cam = findScript("planet_camera")
  if not (fb and fb.rebuild and cam and cam.setFreecam) then P("FMB no far_bodies.rebuild / planet_camera"); return end
  local home = save.get("base.body")
  wait_for(function() return #fb.tracked() > 1 end, 30, "tracked worlds")
  local best, br = nil, 0
  for _, nm in ipairs(fb.tracked()) do
    local b = space.body(nm)
    if nm ~= home and b and b.radius > br then best, br = nm, b.radius end
  end
  if not best then P("FMB no world but home tracked (%s)", table.concat(fb.tracked(), ",")); return end
  P("FMB world %s radius %.0f m (home %s); buffers available %s", best, br, tostring(home), tostring(fb.use_buffers()))
  cam.setFreecam(true)
  wait(0.3)
  local fc = cam.freecamState()
  local k = tonumber(params.fm_radii or 3) or 3
  local up = vec3(0.3, 0.8, 0.52):normalized()
  fc.body = best
  fc.rel = up * (br * k)
  fc.ref = up:cross(vec3(1, 0, 0)):normalized()
  fc.pitch = -(math.pi * 0.5 - 0.08)
  fb.focus(best)
  -- the focused level built once (computed or read back), before any timing
  local t0 = W()
  wait_for(function() return fb.stats():find(best .. "%[[%d,]-6|") ~= nil end, 150, "level 6")
  P("FMB first build %.1f s: %s", W() - t0, fb.stats():sub(1, 400))
  wait(2)
  fmb_shot("first")
  local passes = { "lists1", "buffers1", "lists2", "buffers2" }
  for _, pass in ipairs(passes) do
    local lists = pass:sub(1, 5) == "lists"
    fb.FAR_LISTS = lists or nil
    wait_for(function() return fb.rebuild(best) end, 30, "idle " .. pass)
    fb.uploads()
    sc_begin(pass)
    local t1 = W()
    wait_for(function() return fb.stats():find(best .. "%[[%d,]-6|") ~= nil end, 120, "rebuilt " .. pass)
    local ups = {}
    for _, u in ipairs(fb.uploads()) do ups[#ups + 1] = string.format("%.2f ms/%d v", u.ms, u.n) end
    P("FMB %s rebuilt in %.2f s · mesh.build %s · %s", pass, W() - t1, table.concat(ups, ", "), fb.use_buffers() and "buffers" or "lists")
    wait(1.5)
    sc_end(pass)
    fmb_shot(pass)
  end
  fb.FAR_LISTS = nil
  P("FMB done: %s", fb.stats():sub(1, 400))
end
