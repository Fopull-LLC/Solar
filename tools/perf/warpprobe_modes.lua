-- ── warp probe (tools/perf/warpprobe.sh): time warp parked and on foot ──
-- warprover: the rover driven out past `out` m from the base, braked, then the
--            warp stepped up the ladder by the keys (".") to the top and held,
--            the warp level logged every 0.5 s for `warpsecs` real seconds;
--            forced drops (the level falling with no "," pressed) are counted;
--            then "," back to 1× and the planet-relative drift measured.
-- warpfoot : the same on foot at the spawn, a shot of the chip at the top,
--            then W pressed at warp (a drop to 1× with the reason, shot), and
--            a refusal while walking (shot).
-- Positions are kept in the PLANET frame (node − home body, read in the same
-- frame): the home planet moves metres a tick.
local WP_TAG = "w"
local HIST = {}
local function wpshot(nm)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = false }, function(bytes, why)
    if bytes then assets.writeBytes("user://warpshots/" .. WP_TAG .. "_" .. nm .. ".png", bytes); P("WP SHOT %s_%s", WP_TAG, nm) end
    done = true
  end)
  if ok then wait_for(function() return done end, 5, "shot " .. nm) end
end
local function wp_rel(p)
  local b = home()
  return { x = p.x - b.x, y = p.y - b.y, z = p.z - b.z }
end
local function wp_gx()
  local gx = findScript("galaxy")
  if not gx then return -1, "no galaxy" end
  local ok, c = pcall(gx.maxWarp)
  local ok2, n = pcall(gx.warpNote)
  return ok and c or -1, ok2 and n or nil
end
-- tap a warp key until the level moves (fixedUpdate reads `pressed`; a frame
-- with no tick in it can miss a tap)
local function wp_key(k)
  local w0 = space.warp()
  for _ = 1, 4 do
    tap(k)
    wait(0.25)
    if space.warp() ~= w0 then return true end
  end
  return false
end
local function wp_note()
  local wc = findScript("warp_chip")
  return wc and wc.lastNotice or "-"
end

-- every craft's state this frame (the engine drops the warp when a craft that
-- is not grounded moves near the ground; which one, and how, is the question)
local function wp_crafts()
  local o = {}
  for _, v in ipairs(findScripts("vessel_controller")) do
    local n = v.node
    local i = n and n.valid and assembly.info(n)
    if i then
      local ng, nt = 0, 0
      for _, w in ipairs(v.R2 and v.R2.wheels or {}) do
        if w.tyre and w.tyre.valid then nt = nt + 1; if w.tyre.grounded then ng = ng + 1 end end
      end
      local r = wp_rel(i.com)
      o[#o + 1] = string.format("[%s r%.1f |v|%.3f g%s a%s tyres %d/%d]", n.name, len(r.x, r.y, r.z), len(i.vel.x, i.vel.y, i.vel.z),
        tostring(i.grounded), tostring(i.anchored), ng, nt)
    end
  end
  local a = astro()
  if a and a.valid then
    local r = wp_rel(a)
    o[#o + 1] = string.format("[Astronaut r%.1f |v|%.3f g%s vis%s]", len(r.x, r.y, r.z), len(a.vx or 0, a.vy or 0, a.vz or 0), tostring(a.grounded), tostring(a.visible))
  end
  return table.concat(o, " ")
end

-- step to the top, hold, log; `where()` → planet-relative position, extra text
local function wp_ladder(tag, where, secs)
  local p0, x0 = where()
  local st0 = space.time()
  P("WP %s start: warp %.0f, rel (%.3f, %.3f, %.3f) %s", tag, space.warp(), p0.x, p0.y, p0.z, x0 or "")
  local t0 = time
  local nextp, nextk = 0, 1.0
  local mine, drops, maxw, last = space.warp(), 0, 1, space.warp()
  local levels = {}
  local shot_top = false
  while time - t0 < secs do
    yield()
    local w = space.warp()
    if w < last - 0.001 then   -- only "." is pressed in here: any fall is forced
      drops = drops + 1
      for k = math.max(1, #HIST - 3), #HIST do P("WP %s before the drop: %s", tag, HIST[k]) end
      P("WP %s at the drop: %s", tag, wp_crafts())
      local c, n = wp_gx()
      P("WP %s FORCED DROP at +%.1f s: %.0f -> %.0f (galaxy cap %s %s) notice %s", tag, time - t0, last, w, tostring(c), tostring(n), wp_note())
      mine = w
    end
    last = w
    if w > 1.001 then HIST[#HIST + 1] = string.format("%.2f w%.0f %s", time - t0, w, wp_crafts()); if #HIST > 8 then table.remove(HIST, 1) end end
    maxw = math.max(maxw, w)
    if time - t0 >= nextk and w < 10000 then
      nextk = time - t0 + 2.0
      local w0 = space.warp()
      tap(".")
      yield()
      mine = space.warp()
      P("WP %s key . %.0f -> %.0f (%s) notice %s", tag, w0, mine, mine > w0 and "moved" or "refused", wp_note())
      if mine < w0 - 0.001 then drops = drops + 1; P("WP %s FORCED DROP during a tap: %.0f -> %.0f", tag, w0, mine) end
      last = mine
    end
    if time - t0 >= nextp then
      nextp = nextp + 0.5
      local p, xs = where()
      local c, n = wp_gx()
      local d = len(p.x - p0.x, p.y - p0.y, p.z - p0.z)
      levels[#levels + 1] = string.format("%.0f", w)
      P("WP %s t=%.1f warp %.0f galaxyCap %s note %s drift %.3f m %s", tag, time - t0, w, c == math.huge and "inf" or tostring(c), tostring(n), d, xs or "")
    end
    if not shot_top and w >= 10000 and time - t0 > 16 then shot_top = true; wpshot(tag .. "_top") end
  end
  local gsecs = space.time() - st0
  P("WP %s levels: %s", tag, table.concat(levels, " "))
  -- back to 1×
  for _ = 1, 8 do if space.warp() > 1.001 then wp_key(",") end end
  wait(3)
  local p1, x1 = where()
  local d = len(p1.x - p0.x, p1.y - p0.y, p1.z - p0.z)
  P("WP RESULT %s: max warp %.0f, forced drops %d, game time %.0f s (%.1f h) in %.0f s real, back at %.0f×, planet-relative drift %.3f m %s",
    tag, maxw, drops, gsecs, gsecs / 3600, secs, space.warp(), d, x1 or "")
  return drops, d
end

local function run_warprover()
  WP_TAG = params.tag or "rover"
  local vc = run_rover({ name = "w_rover", stop = true })
  if not vc then P("WP RESULT rover: no craft"); return end
  local vn = vc.node
  release_all()
  -- coast to a stop, then the parking brake
  local t0 = time
  while time - t0 < 12 do
    yield()
    local i = assembly.info(vn)
    if i and len(i.vel.x, i.vel.y, i.vel.z) < 0.3 then break end
  end
  brakes_on(vc)
  wait(3)
  local u = base_frame()
  local function where()
    local i = assembly.info(vn)
    local r = wp_rel(i.com)
    local Ug = unit(r)
    local upw = vn:worldUp()
    local cang = clamp(dot(Ug, u), -1, 1)
    return r, string.format("| %.0f m from base, |v| %.3f, grounded %s onWheels %s anchored %s, up.U %.4f, parts %d",
      math.acos(cang) * len(r.x, r.y, r.z), len(i.vel.x, i.vel.y, i.vel.z), tostring(i.grounded), tostring(vc.R2.onWheels),
      tostring(i.anchored), dot(upw, Ug), #i.parts)
  end
  wpshot("parked")
  wp_ladder("rover", where, params.warpsecs or 60)
  wpshot("after")
  -- and it drives off after (the parking brake off first)
  tap("b"); wait(0.3)
  key_down("w"); wait(3); key_up("w")
  local i = assembly.info(vn)
  P("WP rover after warp: W 3 s -> |v| %.2f, destroyed %s", len(i.vel.x, i.vel.y, i.vel.z), tostring(vc.destroyed))
end

local function run_warpfoot()
  WP_TAG = params.tag or "foot"
  sc_pause("a_onfoot30")
  wait_ready(60)
  local a = astro()
  local pw = findScript("planet_walker")
  wait(4)
  local function where()
    local r = wp_rel(a)
    local v = len(a.vx or 0, a.vy or 0, a.vz or 0)
    return r, string.format("| |v| %.3f grounded %s onFoot %s swimming %s", v, tostring(pw.grounded), tostring(pw.onFoot), tostring(pw.swimming))
  end
  -- a refusal: walking
  key_down("w"); wait(1.0)
  wp_key(".")
  P("WP foot walking: warp %.0f notice %s", space.warp(), wp_note())
  wpshot("refused_walking")
  key_up("w"); wait(2.5)
  local drops, d = wp_ladder("foot", where, params.warpsecs or 60)
  -- the chip at a middle rung, then W: dropped to 1× with the reason
  wp_key("."); wp_key("."); wp_key("."); wp_key(".")
  wait(1.0)
  P("WP foot chip at %.0f×", space.warp())
  wpshot("chip")
  key_down("w"); wait(0.2)
  P("WP foot W at warp -> %.0f×, notice %s", space.warp(), wp_note())
  wait(0.3)
  wpshot("dropped_w")
  key_up("w")
end
