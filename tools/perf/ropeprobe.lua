-- ROPEPROBE: the Rope Kit in the real game, on a NEW save (tools/perf/ropeshots.sh;
-- scripts/rope_climb.lua, rope.lua, items.lua, deployables.lua, crew.lua).
--
--   1. the depot sells it; one bought into the pack
--   2. a 12 m pit dug 150 m from the base: a vertical wall with a ledge
--   3. the kit in hand, planted 0.6 m back from the edge, boom over the pit;
--      the line falls to the floor (its layout, the drawn line)
--   4. E tapped at the davit: clipped on at the top, over the edge
--   5. S lowers to the floor (the descender's rate); E unclips onto it
--   6. E at the line's foot clips on again; W climbs (the ascender: time,
--      bites) to the top; E steps off onto the ledge behind the davit
--   7. clipped on again, lowered to a 6 m drop and let go: the fall is the
--      crew's impact rules'
--   8. the frames: the suit's drawn place against the line's drawn place
--      every frame of the climb (no lag, no jitter)
--   9. a reload (scene.load): the davit and its line are there again, the
--      layout from the save
--  10. E held at the davit: taken down, back in the pack, the save clean
--
-- Pictures (1280×720) to user://ropeshots/, lines "RPB ", one RESULT a check.
defaults = { quit = 1, slot = 23, seed = 5150, scale = 4, reload = 1 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("RPB %7.2f " .. fmt, W() - W0, ...)) end
local NODE, CO, pending = nil, nil, 0
local FAILS = 0
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
local function frames(n) for _ = 1, n do yield() end end
local function R(name, ok, fmt, ...)
  if not ok then FAILS = FAILS + 1 end
  P("RESULT %s: %s " .. (fmt or ""), name, ok and "PASS" or "FAIL", ...)
end
local PCAM_REF = nil   -- (set below: the probe camera, while one is placed)
local function shot(name)
  pending = pending + 1
  local cam = PCAM_REF and PCAM_REF()
  local cb = function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://ropeshots/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("SHOT %s failed %s", name, tostring(why)) end
  end
  local opt = { w = 1280, h = 720, ui = cam == nil, draws = true }
  local ok, err
  if cam then ok, err = pcall(camera.capture, cam, opt, cb) else ok, err = pcall(camera.capture, opt, cb) end
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function home() local n = save.get("base.body"); return n and space.body(n), n end
local function unit(a) local l = len(a.x, a.y, a.z); return { x = a.x / l, y = a.y / l, z = a.z / l } end
local function cross(a, b) return { x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x } end
local function ground_r(b, ux, uy, uz, from)
  local r = from
  for _ = 1, 600 do
    local d = terrain.query(b.x + ux * r, b.y + uy * r, b.z + uz * r)
    if not d then return nil end
    if d < 0.03 then return r end
    r = r - math.max(d * 0.8, 0.05)
  end
  return r
end
local function key(k, down) input.simulate({ key = k, down = down }) end
local function tap(k) key(k, true); frames(3); key(k, false); frames(2) end

-- The pit's frame (body-relative): u up at the spot, t1 along the wall,
-- t2 across it (the ledge is +t2, the pit -t2), g the ground point there.
local F = nil
local function at_body(t1, t2, h)
  local b = home()
  local d = unit({ x = F.u.x * F.r + F.t1.x * t1 + F.t2.x * t2, y = F.u.y * F.r + F.t1.y * t1 + F.t2.y * t2,
                   z = F.u.z * F.r + F.t1.z * t1 + F.t2.z * t2 })
  local gr = ground_r(b, d.x, d.y, d.z, F.r + 20)
  if not gr then return nil end
  return { x = d.x * (gr + h), y = d.y * (gr + h), z = d.z * (gr + h) }, d
end

local function boot()
  local s = "slot" .. math.floor(params.slot)
  NODE.persistent = true
  terrain.deleteSaveDir("saves/" .. s .. "/terrain")
  if save.deleteSlot then save.deleteSlot(s) end
  save.slot(s)
  save.set("g_seed", math.floor(params.seed))
  for k, v in pairs({ g_planets = 3, g_moonchance = 0.6, g_atmo = 0.8, g_caves = 1.0, g_minorbit = 60000, g_spacing = 2.2,
                      g_radmin = 600, g_radmax = 950, g_gravmin = 3.5, g_gravmax = 8.5, g_star = 1.0 }) do save.set(k, v) end
  save.set("g_scale", math.floor(params.scale))
  save.set("game.mode", "career")
  scene.load("system")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
  end, 240, "the reveal")
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
end

-- a probe camera (a FlagPhotoCam, drawn off-screen: the main camera's own
-- framed shots hide the player's suit): eye and target as body-relative
-- points or functions, placed every frame in lateUpdate against the davit's
-- DRAWN pose, so it rides the moving planet with what it looks at
local PCAM = { node = nil, eye = nil, look = nil }
local function origin()
  local b = home()
  local dep = findScript("deployables")
  local ox, oy, oz = b.x, b.y, b.z
  if F and F.id and dep then
    local pn = dep.nodeOf(F.id)
    if pn and pn.worldPos then ox, oy, oz = pn.worldPos.x - pn.x, pn.worldPos.y - pn.y, pn.worldPos.z - pn.z end
  end
  return ox, oy, oz
end
local function place_cam()
  local c = PCAM.node
  if not (c and c.valid ~= false and PCAM.eye) then return end
  local ox, oy, oz = origin()
  local e = type(PCAM.eye) == "function" and PCAM.eye() or PCAM.eye
  local l = type(PCAM.look) == "function" and PCAM.look() or PCAM.look
  c.pos = vec3(ox + e.x, oy + e.y, oz + e.z)
  c:lookAt(vec3(ox + l.x, oy + l.y, oz + l.z), vec3(F.u.x, F.u.y, F.u.z))
end
local function cam_at(eye, look)
  if not (PCAM.node and PCAM.node.valid ~= false) then
    local a = find("Astronaut")
    spawn("FlagPhotoCam", vec3(a.x, a.y, a.z), function(n) PCAM.node = n end)
    wait_for(function() return PCAM.node end, 5, "the probe camera")
  end
  PCAM.eye, PCAM.look = eye, look
end
local function cam_off() PCAM.eye = nil end
PCAM_REF = function() return (PCAM.eye and PCAM.node and PCAM.node.valid ~= false) and PCAM.node or nil end
local function add(p, v, k) return { x = p.x + v.x * k, y = p.y + v.y * k, z = p.z + v.z * k } end
-- the suit's body-relative place, drawn (from the davit's drawn pose)
local function astro_rel()
  local a = find("Astronaut")
  local dep = findScript("deployables")
  local pn = dep and F and F.id and dep.nodeOf(F.id)
  local b = home()
  local ox, oy, oz = b.x, b.y, b.z
  if pn and pn.worldPos then ox, oy, oz = pn.worldPos.x - pn.x, pn.worldPos.y - pn.y, pn.worldPos.z - pn.z end
  return { x = a.x - ox, y = a.y - oy, z = a.z - oz }
end

-- 8. the frames, measured every frame while a climb runs (lateUpdate)
local FR = { on = false, n = 0, max = 0, sum = 0 }
function lateUpdate(node, dt)
  place_cam()
  if not (FR.on and F and F.id) then return end
  local rc = findScript("rope_climb")
  local st = rc and rc.state()
  if not (st and st.mode == "on") then return end
  local L = rc.layoutOf(F.id)
  local p = astro_rel()
  local bx, by, bz = rc.bodyAt(L, st.s)
  local e = len(p.x - bx, p.y - by, p.z - bz)
  FR.n, FR.sum, FR.max = FR.n + 1, FR.sum + e, math.max(FR.max, e)
end

local function main()
  boot()
  hold(3.0)
  local C, inv, H, co, I = findScript("crew"), findScript("inventory"), findScript("item_hand"), findScript("company"), findScript("items")
  local pw = findScript("planet_walker")
  -- 1. the shop
  co.earn(3000, "probe")
  local listed = nil
  for _, e in ipairs(inv.shopList()) do if e.id == "rope" then listed = e end end
  local b0 = co.balance()
  local okb, whyb = inv.buyItem("astro", "rope", 1)
  R("shop", listed ~= nil and listed.cost == 180 and okb and b0 - co.balance() == 180 and inv.itemCount("astro", "rope") == 1,
    "listed %s ($%s, %s kg, %s L); bought: %s %s; in the pack %d", tostring(listed ~= nil), tostring(listed and listed.cost),
    tostring(listed and listed.kg), tostring(listed and listed.L), tostring(okb), tostring(whyb), inv.itemCount("astro", "rope"))
  -- 2. the pit
  local b, bname = home()
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  local R0 = len(bx, by, bz)
  local u0 = { x = bx / R0, y = by / R0, z = bz / R0 }
  local a0 = math.abs(u0.y) > 0.9 and { x = 1, y = 0, z = 0 } or { x = 0, y = 1, z = 0 }
  local tA = unit(cross(u0, a0))
  local k = 150 / R0
  local dir = unit({ x = u0.x * math.cos(k) + tA.x * math.sin(k), y = u0.y * math.cos(k) + tA.y * math.sin(k),
                     z = u0.z * math.cos(k) + tA.z * math.sin(k) })
  local gr = ground_r(b, dir.x, dir.y, dir.z, R0 + 150)
  F = { u = dir, r = gr }
  F.t1 = unit(cross(dir, math.abs(dir.y) > 0.9 and { x = 1, y = 0, z = 0 } or { x = 0, y = 1, z = 0 }))
  F.t2 = unit(cross(dir, F.t1))
  local g = { x = dir.x * gr, y = dir.y * gr, z = dir.z * gr }
  P("spot on %s r %.1f; g %.2f m/s²", tostring(bname), gr, b.mu / (gr * gr))
  -- park the crew well clear while the ground is cut
  local a = find("Astronaut")
  local park = at_body(0, 14, 1.1)
  if park then a.x, a.y, a.z = b.x + park.x, b.y + park.y, b.z + park.z; a.vx, a.vy, a.vz = 0, 0, 0; C.quietMonitors(2.0) end
  hold(1.5)
  local nd = 0
  for _, d in ipairs({ 1.0, 3.0, 5.0, 7.0, 9.0 }) do
    for _, s1 in ipairs({ -6, -3, 0, 3, 6 }) do
      b = home()
      local p = add(add(g, F.u, -d), F.t1, s1)
      terrain.dig(b.x + p.x, b.y + p.y, b.z + p.z, 3.2, 1.0, { hardness = 1.0, falloff = "sharp" })
      nd = nd + 1
    end
  end
  wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, 60, "the digs")
  hold(2.0)
  -- where the edge is: walk +t2 along the ground until it is ground again
  local edge = nil
  b = home()
  for t2 = 0, 8, 0.1 do
    local p = add(add(g, F.u, 2), F.t2, t2)
    local h = terrain.raycast(vec3(b.x + p.x, b.y + p.y, b.z + p.z), vec3(-F.u.x, -F.u.y, -F.u.z), 6)
    if h and h.distance < 2.6 then edge = t2 break end
  end
  local floor_h = nil
  do
    local p = add(g, F.u, 2)
    local h = terrain.raycast(vec3(b.x + p.x, b.y + p.y, b.z + p.z), vec3(-F.u.x, -F.u.y, -F.u.z), 40)
    floor_h = h and (h.distance - 2) or nil
  end
  R("pit", edge ~= nil and floor_h and floor_h > 8, "%d digs; the edge %.1f m out; the floor %.1f m down", nd, edge or -1, floor_h or -1)
  edge = edge or 3.4
  -- 3. on the ledge, the kit in hand, planted 0.6 m back from the edge
  local stand = at_body(0, edge + 2.8, 1.05)
  a.x, a.y, a.z = b.x + stand.x, b.y + stand.y, b.z + stand.z
  a.vx, a.vy, a.vz = 0, 0, 0
  C.quietMonitors(1.0)
  hold(1.0)
  local okh, whyh = H.hold("rope")
  hold(1.2)
  local pc = findScript("planet_camera")
  if pc and pc.face then pc.face(-F.t2.x, -F.t2.y, -F.t2.z, -0.35) end
  hold(0.8)
  shot("0_kit_in_hand")
  frames(3)
  if pc then pc.firstPerson = true end
  hold(1.0)
  shot("0b_kit_first_person")
  frames(3)
  if pc then pc.firstPerson = false end
  hold(0.6)
  local gp = at_body(0, edge + 0.6, 0)
  b = home()
  local id, whyp = H.deployAt(b.x + gp.x, b.y + gp.y, b.z + gp.z)
  local dep = findScript("deployables")
  local rec = id and dep.get(id)
  R("place", id ~= nil and rec and rec.k == "rope" and inv.itemCount("astro", "rope") == 0,
    "held %s (%s); deployAt → %s (%s); kind %s; left in the pack %d", tostring(okh), tostring(whyh), tostring(id),
    tostring(whyp), tostring(rec and rec.k), inv.itemCount("astro", "rope"))
  if not id then return end
  F.id = id
  local rc = wait_for(function() return findScript("rope_climb") end, 10, "RopeLib")
  local L = rc and wait_for(function() return rc.layoutOf(id) end, 20, "the layout")
  local pn = wait_for(function() return dep.nodeOf(id) end, 10, "the davit node")
  local line = pn and wait_for(function()
    for _, c in ipairs(pn:children()) do if c.name == "Rope Line" and c.model and c.model ~= "" then return c end end
  end, 10, "the drawn line")
  R("layout", L and L.g and L.total > 8 and rc.climbable(L),
    "the line falls %.2f m (%s), %d points; climbable %.2f–%.2f; wall at 5 m %.2f m; rays the raycast missed %d", L and L.total or -1,
    L and (L.g and "on the floor" or "free") or "-", L and L.n or 0, L and L.s_top or -1, L and L.s_max or -1,
    L and (rc.wallAt(L, 5) or -1) or -1, rc.castMisses or -1)
  R("line_drawn", line ~= nil, "Rope Line %s (model %s)", tostring(line ~= nil), tostring(line and line.model))
  if not (L and rc.climbable(L)) then return end
  -- the drop point against the sheave the model draws: (the davit node's
  -- frame) — the line's first point in the davit's local frame
  do
    local o = pn:toWorld(vec3(0, 0, 0))
    local lp = pn:toLocal(vec3(o.x + L.p[1] - pn.x, o.y + L.p[2] - pn.y, o.z + L.p[3] - pn.z))
    P("the line leaves the davit at local (%.3f, %.3f, %.3f) (sheave lip: 0, %.3f, %.3f)", lp.x, lp.y, lp.z,
      rc.ROPE.drop_y - rc.ROPE.origin, -rc.ROPE.drop_out)
  end
  local top = L.p
  local sheave = { x = top[1], y = top[2], z = top[3] }
  local mast = add(gp, F.u, 0.9)
  -- pictures: the davit from the ledge, the line from the floor
  cam_at(add(add(add(mast, F.t2, 2.6), F.t1, 2.2), F.u, 0.8), add(mast, F.t2, -0.3))
  hold(0.8)
  shot("1_davit")
  frames(3)
  local foot = { x = top[#top - 2], y = top[#top - 1], z = top[#top] }
  cam_at(add(add(add(foot, F.t2, -4.5), F.t1, 2.5), F.u, 1.6), add(add(foot, F.u, 6), F.t2, 0.2))
  hold(0.8)
  shot("2_line_from_floor")
  frames(3)
  cam_off()
  -- 4. E at the davit: clipped on at the top
  a = find("Astronaut")
  local st0 = at_body(0, edge + 1.9, 1.05)
  b = home()
  a.x, a.y, a.z = b.x + st0.x, b.y + st0.y, b.z + st0.z
  a.vx, a.vy, a.vz = 0, 0, 0
  C.quietMonitors(1.0)
  hold(1.0)
  local tb = findScript("tool_belt")
  P("at the davit: prompt %q; e_taken %s; held hand %s", tostring(rc.promptText), tostring(rc.prompting()), tostring(H.held()))
  shot("3_prompt_at_davit")
  frames(2)
  tap("e")
  hold(0.8)
  local s1 = rc.state()
  local hp0 = C.get(C.activeId()).hp or 1
  R("clip_top", s1 and s1.mode == "on" and math.abs(s1.s - L.s_top) < 0.02 and C.held(),
    "climbing %s mode %s s %.2f (top %.2f); held %s", tostring(rc.climbing()), tostring(s1 and s1.mode), s1 and s1.s or -1,
    L.s_top, tostring(C.held()))
  -- the top hang, from out over the pit
  cam_at(function() local p = astro_rel(); return add(add(add(p, F.t2, -2.8), F.t1, 1.4), F.u, 0.5) end,
         function() local p = astro_rel(); return add(p, F.u, 0.2) end)
  hold(0.8)
  shot("4_hang_at_top")
  frames(3)
  cam_off()
  hold(0.4)
  shot("4b_player_view_at_top")
  frames(3)
  P("player view: hidesBody %s, crew visible %s", tostring(findScript("planet_camera").hidesBody), tostring(find("Astronaut").visible))
  -- 5. S lowers to the floor
  FR.on = true
  local t0 = W()
  key("s", true)
  local mid_shot = false
  local vmax = 0
  wait_for(function()
    local st = rc.state()
    if not st then return true end
    vmax = math.max(vmax, st.v or 0)
    if not mid_shot and st.s > (L.s_top + L.s_max) / 2 then
      mid_shot = true
      cam_at(function() local p = astro_rel(); return add(add(add(p, F.t2, -2.6), F.t1, 1.6), F.u, 0.4) end,
             function() local p = astro_rel(); return add(p, F.u, 0.3) end)
      shot("5_lowering_mid")
    end
    return st.s >= L.s_max - 0.01
  end, 40, "the floor")
  key("s", false)
  local t_down = W() - t0
  local s2 = rc.state()
  R("lower", s2 and math.abs(s2.s - L.s_max) < 0.02 and s2.kind == "bottom",
    "%.1f m in %.1f s (top speed %.2f m/s); at the bottom: %s", L.s_max - L.s_top, t_down, vmax, tostring(s2 and s2.kind))
  cam_at(function() local p = astro_rel(); return add(add(add(p, F.t2, -3.0), F.t1, 1.8), F.u, 0.2) end,
         function() local p = astro_rel(); return add(p, F.u, 0.0) end)
  hold(0.6)
  shot("6_at_the_bottom")
  frames(3)
  cam_off()
  tap("e")
  hold(1.5)
  local rel = rc.lastRelease
  a = find("Astronaut")
  local hp1 = C.get(C.activeId()).hp or 1
  R("unclip_bottom", not rc.climbing() and rel and rel.kind == "bottom" and pw.grounded and not C.held() and hp1 >= hp0 - 1e-6,
    "released %s; grounded %s; held %s; hp %.2f → %.2f", tostring(rel and rel.kind), tostring(pw.grounded), tostring(C.held()), hp0, hp1)
  -- 6. E at the line's foot, W to the top
  frames(10)
  P("at the foot: prompt %q", tostring(rc.promptText))
  tap("e")
  hold(0.8)
  local s3 = rc.state()
  R("clip_rope", s3 and s3.mode == "on" and s3.s > L.s_max - 1.5, "clipped on at %.2f m (bottom %.2f)", s3 and s3.s or -1, L.s_max)
  local bites0 = rc.strokes
  t0 = W()
  key("w", true)
  local shot_c = false
  local vmin = 0
  wait_for(function()
    local st = rc.state()
    if not st then return true end
    vmin = math.min(vmin, st.v or 0)
    if not shot_c and st.s < L.s_top + (L.s_max - L.s_top) * 0.45 then
      shot_c = true
      cam_at(function() local p = astro_rel(); return add(add(add(p, F.t2, -1.6), F.t1, -1.0), F.u, 0.8) end,
             function() local p = astro_rel(); return add(p, F.u, 0.5) end)
      shot("7_climbing_close")
    end
    return st.s <= L.s_top + 0.01
  end, 60, "the top")
  key("w", false)
  local t_up = W() - t0
  local kg = rc.ROPE.body_kg + (inv.mass("astro") or 0)
  local gg = b.mu / (gr * gr)
  local up_v = rc.speeds(gg, kg, false)
  R("climb", (rc.state() or {}).kind == "top" and t_up > t_down and rc.strokes - bites0 > 5,
    "%.1f m up in %.1f s (expected ~%.1f s at %.2f m/s for %.0f kg at %.2f g), %d ascender bites; down took %.1f s",
    L.s_max - (rc.state() and rc.state().s or 0), t_up, (L.s_max - L.s_top) / up_v, up_v, kg, gg, rc.strokes - bites0, t_down)
  FR.on = false
  R("frames", FR.n > 100 and FR.max < 0.25, "the suit's drawn place vs the line's, %d frames: mean %.3f m, max %.3f m",
    FR.n, FR.sum / math.max(1, FR.n), FR.max)
  cam_at(function() local p = astro_rel(); return add(add(add(p, F.t2, -2.8), F.t1, 2.4), F.u, 1.0) end,
         function() local p = astro_rel(); return add(p, F.u, 0.3) end)
  hold(0.6)
  shot("8_back_at_top")
  frames(3)
  -- step off
  tap("e")
  hold(1.6)
  rel = rc.lastRelease
  a = find("Astronaut")
  local here = astro_rel()
  local gl = at_body(0, edge + 0.6 + rc.ROPE.back, 0)
  local hpt = C.get(C.activeId()).hp or 1
  local up_off = (here.x - gl.x) * F.u.x + (here.y - gl.y) * F.u.y + (here.z - gl.z) * F.u.z
  local side = len(here.x - gl.x - F.u.x * up_off, here.y - gl.y - F.u.y * up_off, here.z - gl.z - F.u.z * up_off)
  R("step_off", rel and rel.kind == "top" and not C.held() and side < 0.8 and up_off > 0.6 and up_off < 1.4 and hpt >= hp1 - 1e-6,
    "released %s; %.2f m from the spot behind the davit, %.2f m over the ledge; grounded %s; hp %.2f; hand %s",
    tostring(rel and rel.kind), side, up_off, tostring(pw.grounded), hpt, tostring(H.held()))
  cam_off()
  hold(0.5)
  shot("9_stepped_off")
  frames(3)
  -- 7. back over, down to a ~6 m drop, and let go
  tap("e")
  hold(0.8)
  rc.sim = { move = -1 }
  wait_for(function() local st = rc.state(); return not st or st.s > st.s_top + 0.3 end, 30, "off the top")
  rc.sim = { move = 0 }
  hold(0.5)
  local s4 = rc.state()
  local hpb = C.get(C.activeId()).hp or 1
  P("letting go at %.2f m with %.2f m under the feet: prompt %q", s4 and s4.s or -1, s4 and s4.drop or -1, tostring(rc.promptText))
  rc.sim = nil
  do
    local aa, bb = find("Astronaut"), home()
    local h = terrain.raycast(vec3(aa.x, aa.y, aa.z), vec3(-F.u.x, -F.u.y, -F.u.z), 40)
    P("the ground under the suit: %.2f m under its soles", h and (h.distance - rc.ROPE.foot) or -1)
  end
  tap("e")
  local peak, tl = 0, W()
  wait_for(function()
    local m = C._debug and C._debug().mon
    if m then peak = math.max(peak, m.peak or 0) end
    return W() - tl > 3.0
  end, 5, "the fall")
  rel = rc.lastRelease
  local hpa = C.get(C.activeId()).hp or 1
  local r = C.get(C.activeId())
  R("let_go", rel and rel.kind == "fall" and not C.held() and pw.grounded,
    "released %s from %.1f m; peak fall %.1f m/s; hp %.2f → %.2f (impact rules: injure over %.0f m/s, ~%.1f m/s from %.1f m at %.2f g); status %s",
    tostring(rel and rel.kind), s4 and s4.drop or -1, peak, hpb, hpa, C.params and C.params.impact_injure or 9,
    math.sqrt(2 * gg * (s4 and s4.drop or 0)), s4 and s4.drop or -1, gg, tostring(r and r.status))
  -- 9. a reload
  local key_saved = save.get("rope." .. tostring(id))
  if params.reload == 1 then
    cam_off()
    if save.flush then save.flush() end
    scene.load("system")
    yield()
    wait_for(function()
      local pw2, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
      return pw2 and gm and bf and bf.sited and not gm.loading and not gm.curtain
    end, 300, "the reload")
    hold(2.0)
    C, inv, H = findScript("crew"), findScript("inventory"), findScript("item_hand")
    pw = findScript("planet_walker")
    dep = wait_for(function() return findScript("deployables") end, 20, "deployables after reload")
    -- the crew back by the pit (the davit spawns for the world the crew is on)
    a = find("Astronaut")
    b = home()
    local st5 = at_body(0, edge + 3.0, 1.05)
    a.x, a.y, a.z = b.x + st5.x, b.y + st5.y, b.z + st5.z
    a.vx, a.vy, a.vz = 0, 0, 0
    C.quietMonitors(2.0)
    local pn2 = wait_for(function() return dep.nodeOf(id) end, 20, "the davit after reload")
    rc = wait_for(function() return findScript("rope_climb") end, 20, "RopeLib after reload")
    local L2 = rc and wait_for(function() return rc.layoutOf(id) end, 10, "the layout after reload")
    local line2 = pn2 and wait_for(function()
      for _, c in ipairs(pn2:children()) do if c.name == "Rope Line" and c.model and c.model ~= "" then return c end end
    end, 10, "the line after reload")
    R("persist", type(key_saved) == "table" and pn2 ~= nil and L2 ~= nil and math.abs(L2.total - L.total) < 0.01 and line2 ~= nil,
      "saved %s; davit %s; layout %.2f m (was %.2f); line %s", tostring(type(key_saved) == "table"), tostring(pn2 ~= nil),
      L2 and L2.total or -1, L.total, tostring(line2 ~= nil))
    hold(1.0)
    cam_at(add(add(add(mast, F.t2, 3.0), F.t1, -2.4), F.u, 1.2), add(add(mast, F.t2, -1.0), F.u, -1.5))
    hold(0.8)
    shot("10_after_reload")
    frames(3)
    cam_off()
  end
  -- 10. E held at the davit: taken down
  a = find("Astronaut")
  b = home()
  local st6 = at_body(0, edge + 1.9, 1.05)
  a.x, a.y, a.z = b.x + st6.x, b.y + st6.y, b.z + st6.z
  a.vx, a.vy, a.vz = 0, 0, 0
  C.quietMonitors(1.0)
  hold(1.0)
  local n0 = inv.itemCount("astro", "rope")
  key("e", true)
  hold(0.8)
  local mid = rc.promptText
  hold(1.0)
  key("e", false)
  hold(0.5)
  R("take_down", dep.get(id) == nil and inv.itemCount("astro", "rope") == n0 + 1 and save.get("rope." .. tostring(id)) == nil
    and dep.nodeOf(id) == nil,
    "record %s; in the pack %d → %d; save key %s; while held: %q", tostring(dep.get(id) ~= nil), n0,
    inv.itemCount("astro", "rope"), tostring(save.get("rope." .. tostring(id)) ~= nil), tostring(mid))
  wait_for(function() return pending == 0 end, 10, "the pictures")
  P("DONE fails %d", FAILS)
end

function start(node)
  NODE = node
  CO = coroutine.create(main)
end

function update(node, dt)
  if not CO then return end
  if coroutine.status(CO) == "dead" then
    CO = nil
    if params.quit == 1 and app.quit then app.quit() end
    return
  end
  local ok, err = coroutine.resume(CO)
  if not ok then P("ERROR %s", tostring(err)); CO = nil; if params.quit == 1 and app.quit then app.quit() end end
end
