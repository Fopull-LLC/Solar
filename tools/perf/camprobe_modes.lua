-- ── builder camera probe (tools/perf/chopprobe.sh cam): playtest 11-10 ──────
-- "the camera in the full builder hub mode is really hard to control, it gets
-- stuck in the ground and is hard to orientate". Three Base Hubs: on flat
-- ground, on the flank of a raised hill, and on the rim of a dug pit (a 9 m
-- drop). At each, the full builder is opened from the hub's menu and the
-- camera driven the ways that buried it: an orbit low round the hub (eight
-- bearings at a 6° look up), a pivot pushed into the hill, the wheel zoomed
-- hard toward the ground, a pan across the ground, HOME. After each the
-- camera's world point is checked against the terrain (terrain.query > 0.1 m,
-- and no ground above it along the local up), the pivot too, and the camera's
-- up against the local radial up. Pictures from several angles at each hub.
-- One `CAMP PASS|FAIL <check>` line a check (BK.check), `BK RESULT cam`.
-- Spliced after vfxprobe/buildkitprobe/kitprobe/fullbuildprobe helpers? No:
-- after vfxprobe, buildkitprobe and kitprobe (FB's helpers are copied here).
CAMP = { worst = 1e9, fails = 0 }

local function camp_engineer()
  local C = findScript("crew")
  BK.unlock()
  C.patch(C.activeId(), { role = "engineer" })
  wait(3.5)
end
local function camp_face()
  local pc0 = findScript("planet_camera")
  local U = unit(sub(astro(), home()))
  local f = { x = pc0.fwd_x or BK.F.x, y = pc0.fwd_y or BK.F.y, z = pc0.fwd_z or BK.F.z }
  BK.F = unit(sub(f, scl(U, dot(f, U))))
end
-- move the crew to a body-relative ground point (feet on it)
local function camp_put(rel)
  local b = home()
  local a = astro()
  local U = unit(rel)
  local top = { x = b.x + rel.x + U.x * 30, y = b.y + rel.y + U.y * 30, z = b.z + rel.z + U.z * 30 }
  local h = raycast(top.x, top.y, top.z, -U.x, -U.y, -U.z, 80, { ignore = a })
  local g = h or { x = b.x + rel.x, y = b.y + rel.y, z = b.z + rel.z }
  a.x, a.y, a.z = g.x + U.x * 1.0, g.y + U.y * 1.0, g.z + U.z * 1.0
  a.vx, a.vy, a.vz = 0, 0, 0
  wait(2.0)
end
-- a body-relative point `ahead` m along BK.F and `side` m to the right of the crew, on the ground
local function camp_ground(ahead, side)
  local h = BK.ground_ahead(ahead, side)
  if not h then return nil end
  return sub(h, home())
end
local function sculpt_at(rel, r, k, mode, n)
  for _ = 1, n do
    local bb = home()
    terrain.sculpt(bb.x + rel.x, bb.y + rel.y, bb.z + rel.z, r, k, mode)
    wait(0.15)
  end
  wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, 30, "the sculpt")
  wait(0.8)
end
local function place_hub(fb, offs)
  local cp = findScript("catalog_panel")
  for _, o in ipairs(offs) do
    fb.hold("baseHub")
    yield()
    local g = BK.ground_ahead(o[1], o[2])
    local sid, why, _, uid
    if g then sid, why, _, uid = fb.placeAt(g.x, g.y, g.z, g.nx, g.ny, g.nz, g.node) end
    P("CAMP hub at %.1f,%.1f: %s %s", o[1], o[2], tostring(sid), tostring(why or ""))
    if sid then wait(1.0) return sid, uid end
  end
  return nil
end
local function open_hub(sid, uid)
  local ST, bh = findScript("structures"), findScript("build_host")
  local node = ST.nodeOf(sid, uid)
  local list = BK.menu(node)
  local e = BK.entry(list, "hub_build")
  if not e then P("CAMP hub menu: %d entries, none to build", #list) return nil end
  BK.run_entry(e)
  wait_for(function() return bh.state == "building" end, 30, "the hub's builder")
  wait(2.5)
  return findScript("builder"), bh
end

-- the camera against the ground, now (drawn poses, this frame)
function CAMP.clear(tag)
  local bc = findScript("builder_camera")
  local cam = find("Builder Camera")
  local c = bc.camPos
  local pw = bc.pivotWorld
  local b = home()
  local U = unit(sub(c, b))
  local q = terrain.query(c.x, c.y, c.z)
  local qp = terrain.query(pw.x, pw.y, pw.z)
  local up = terrain.raycast(vec3(c.x, c.y, c.z), vec3(U.x, U.y, U.z), 120)
  local under = up ~= nil and up.distance ~= nil
  -- the camera's own up against the radial up (an upright view)
  local tilt = -1
  if cam and cam.toWorld then
    local o = cam:toWorld(vec3(0, 0, 0))
    local y = cam:toWorld(vec3(0, 1, 0))
    local cu = unit(sub(y, o))
    local f = unit(sub(pw, c))
    local Uh = unit(sub(U, scl(f, dot(U, f))))
    tilt = math.deg(math.acos(clamp(dot(cu, Uh), -1, 1)))
  end
  local ok = q ~= nil and q > 0.1 and not under and (qp == nil or qp > 0.05)
  P("CAMP %s: camera %.2f m from the ground (query), pivot %.2f, ground above it %s, d %.2f (drawn %.2f), pitch %.1f°, roll off up %.1f°",
    tag, q or -99, qp or -99, tostring(under), bc.dist or -1, bc.clipD or -1, math.deg(bc.camState().pitch), tilt)
  CAMP.worst = math.min(CAMP.worst, q or -99)
  BK.check("cam_" .. tag, ok and tilt < 2.0, "camera out of the ground and upright (%.2f m, %.1f°)", q or -99, tilt)
  return q
end

-- drive the camera at one hub and picture it
function CAMP.drive(tag, B, bh, hillLocal)
  local bc = findScript("builder_camera")
  local st0 = bc.camState()
  local hub = st0.P
  BK.shot(tag .. "_1_open", true)
  CAMP.clear(tag .. "_open")
  -- 1. an orbit low round the hub: eight bearings, a 6° look UP (the old floor let it dive 3 m under the plane)
  for k = 0, 7 do
    bc.setCamState({ P = hub, yaw = k * math.pi / 4, pitch = 0.10, d = 16 })
    wait(0.4)
    CAMP.clear(string.format("%s_orbit%d", tag, k))
    local dd = bc.clipD or bc.dist
    BK.check(string.format("%s_orbit%d_room", tag, k), dd >= 0.5 * bc.dist,
      "the orbit is not pulled in against the ground (drawn %.1f of %.1f m, pitch now %.1f°)", dd, bc.dist, math.deg(bc.camState().pitch))
    if k % 2 == 0 then BK.shot(string.format("%s_2_orbit%d", tag, k), true) end
  end
  -- 2. the pivot pushed into the ground (or the hill) and the camera dragged below it
  local hp = hillLocal or { x = hub.x + 6, z = hub.z + 6 }
  bc.setCamState({ P = { x = hp.x, y = -4, z = hp.z }, yaw = 0.8, pitch = 0.3, d = 10 })
  wait(0.5)
  CAMP.clear(tag .. "_buried")
  BK.shot(tag .. "_3_buried_pivot", true)
  -- 3. the wheel: 12 notches in at the screen's middle, the distance logged as it eases
  bc.setCamState({ P = hub, yaw = 2.2, pitch = -0.30, d = 30 })
  wait(0.4)
  local sw, sh = camera.screenSize()
  bc.zoomAt(12, sw * 0.5, sh * 0.62)
  local ds = {}
  for i = 1, 30 do yield(); if i % 3 == 0 then ds[#ds + 1] = string.format("%.1f", bc.dist) end end
  P("CAMP %s zoom in: d over 30 frames %s", tag, table.concat(ds, " "))
  CAMP.clear(tag .. "_zoomin")
  bc.zoomAt(-14, sw * 0.5, sh * 0.5)
  wait(0.8)
  CAMP.clear(tag .. "_zoomout")
  -- 4. a pan along the ground (MMB drag, simulated): the pivot stays over the ground at its height
  local P0 = bc.camState().P
  for _ = 1, 20 do if bc.panBy then bc.panBy(12, 8) end; yield() end
  wait(0.2)
  local P1 = bc.camState().P
  P("CAMP %s pan: pivot (%.2f, %.2f, %.2f) → (%.2f, %.2f, %.2f) (frame)", tag, P0.x, P0.y, P0.z, P1.x, P1.y, P1.z)
  local moved = math.sqrt((P1.x - P0.x) ^ 2 + (P1.z - P0.z) ^ 2)
  BK.check(tag .. "_pan_level", moved > 2 and (math.abs(P1.y - P0.y) < 0.05 or (bc.groundAt and bc.groundAt.pivot and P1.y <= bc.groundAt.pivot + 0.6)),
    "a pan slides the pivot %.1f m along the ground plane (height %.2f → %.2f)", moved, P0.y, P1.y)
  CAMP.clear(tag .. "_pan")
  -- 5. HOME recentres on the base from an easy look down
  bc.setCamState({ P = { x = hub.x + 20, y = 9, z = hub.z - 15 }, yaw = 1.0, pitch = 1.2, d = 4 })
  wait(0.3)
  tap("home")
  wait(1.0)
  local s = bc.camState()
  BK.check(tag .. "_home", math.abs(s.pitch + 0.44) < 0.05 and math.abs(s.P.x - hub.x) < 6 and math.abs(s.P.z - hub.z) < 6,
    "HOME recentres: pivot (%.1f, %.1f, %.1f), pitch %.1f°", s.P.x, s.P.y, s.P.z, math.deg(s.pitch))
  CAMP.clear(tag .. "_home")
  BK.shot(tag .. "_4_home", true)
  -- two more angles for the record
  bc.setCamState({ P = hub, yaw = 3.6, pitch = -0.12, d = 12 }); wait(0.5); BK.shot(tag .. "_5_low", true); CAMP.clear(tag .. "_low")
  bc.setCamState({ P = hub, yaw = 5.0, pitch = -0.9, d = 22 }); wait(0.5); BK.shot(tag .. "_6_high", true); CAMP.clear(tag .. "_high")
  -- the cost of the camera itself, at rest
  local f0 = FRAME
  wait(2)
  P("CAMP %s builder_camera %.3f ms/frame (%d frames)", tag, perf.scriptMs and perf.scriptMs("builder_camera") or -1, FRAME - f0)
end

function CAMP.run()
  BK.tag = "cam"
  wait_ready(120)
  wait(2)
  local fb, ST = findScript("field_builder"), findScript("structures")
  camp_engineer()
  local rs0 = findScript("research")
  for id in pairs(rs0.TECH or {}) do pcall(rs0.grant, id, "probe") end
  local spot = BK.flat_spot()
  if not BK.check("spot", spot ~= nil, "flat ground") then BK.result() return end
  stand_at(spot)
  BK.F = spot.t
  wait(4)
  key_down("w"); wait(0.6); key_up("w"); wait(1.5)
  camp_face()
  local base0 = sub(astro(), home())
  local which = params.camwhich or 7    -- bit 1 flat, 2 slope, 4 cliff
  local hubs = {}
  -- THE FLAT HUB
  tap("b"); wait(1.5)
  if which % 2 == 1 then
    local sid, uid = place_hub(fb, { { 8, -3 }, { 8, 0 }, { 10, 3 } })
    hubs[#hubs + 1] = { tag = "flat", sid = sid, uid = uid }
  end
  -- THE SLOPE: a hill raised 14 m ahead and 30 m to the right, the hub on its flank
  if math.floor(which / 2) % 2 == 1 then
    local c = camp_ground(14, 30)
    if c then
      sculpt_at(c, 9.0, 1.0, "raise", 7)
      -- stand 12 m short of the hill's centre, facing it
      local Ua = unit(c)
      local toC = unit(sub(c, base0)); toC = unit(sub(toC, scl(Ua, dot(toC, Ua))))
      camp_put(sub(c, scl(toC, 13)))
      BK.F = toC
      local sid, uid = place_hub(fb, { { 6.5, 0 }, { 7.0, 0 }, { 6.0, 0 }, { 7.5, 0 }, { 5.5, 0 }, { 8.0, 0 }, { 5.0, 0 } })
      hubs[#hubs + 1] = { tag = "slope", sid = sid, uid = uid, hill = c }
    end
  end
  -- THE CLIFF: a pit dug 14 m ahead and 30 m to the left, 9 m deep, the hub on its rim
  if math.floor(which / 4) % 2 == 1 then
    camp_put(base0)
    BK.F = spot.t
    camp_face()
    local c = camp_ground(14, -30)
    if c then
      local Uc = unit(c)
      for k = 0, 5 do
        sculpt_at(sub(c, scl(Uc, k * 1.6)), 7.5, 1.0, "lower", 2)
      end
      local toC = unit(sub(c, base0)); toC = unit(sub(toC, scl(Uc, dot(toC, Uc))))
      camp_put(sub(c, scl(toC, 15)))
      BK.F = toC
      local sid, uid = place_hub(fb, { { 5.0, 0 }, { 4.5, 0 }, { 5.5, 0 }, { 4.0, 0 }, { 3.5, 0 } })
      hubs[#hubs + 1] = { tag = "cliff", sid = sid, uid = uid, pit = c }
    end
  end
  KIT.close(fb)
  for _, h in ipairs(hubs) do
    if BK.check(h.tag .. "_hub", h.sid ~= nil, "a Base Hub placed (%s)", h.tag) then
      -- the crew beside the hub, so the builder opens from there
      local rec = ST.get(h.sid)
      local hp = ST.getPart(h.sid, h.uid)
      local b = home()
      local fr = findScript("kit_snap").frameOf(rec)
      local pr = { x = fr.O.x + fr.R.x * (hp.x - 4) + fr.F.x * (hp.z - 4), y = fr.O.y + fr.R.y * (hp.x - 4) + fr.F.y * (hp.z - 4),
                   z = fr.O.z + fr.R.z * (hp.x - 4) + fr.F.z * (hp.z - 4) }
      camp_put(pr)
      local B, bh = open_hub(h.sid, h.uid)
      if BK.check(h.tag .. "_open", B ~= nil and bh.state == "building", "the full builder at the %s hub", h.tag) then
        -- (the hill / pit in the structure's frame, for the buried-pivot test)
        local loc = nil
        local feat = h.hill or h.pit
        if feat then
          local d = sub(feat, fr.O)
          loc = { x = dot(d, fr.R), z = dot(d, fr.F) }
          if h.pit then loc = { x = loc.x * 0.3, z = loc.z * 0.3 } end
        end
        CAMP.drive(h.tag, B, bh, loc)
        B.doLaunch()
        wait_for(function() return bh.state == "idle" end, 15, "the hub's builder closing")
        wait(1.5)
      end
    end
  end
  P("CAMP RESULT: the camera's least clearance %.2f m over every check", CAMP.worst)
  BK.result()
end
