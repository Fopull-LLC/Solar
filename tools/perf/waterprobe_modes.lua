-- ── water probe (tools/perf/waterprobe.sh): there is no set water level ──────
-- On the home world: the crew on a beach (shots), a pit dug 90 m inland to
-- under the sea's radius (must stay DRY: climate's reach rule, no pool), a
-- trench cut from the waterline into a pit (must FLOOD), a pit dug beside a
-- lake (must SEEP full to the lake's level over a minute), and climate.lua's
-- frame cost at each. `WATER ... RESULT` lines say what passed; pictures in
-- $WORK/proj/save/user/watershots/.
local function w_shot(nm)
  local done = false
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = false, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://watershots/" .. nm .. ".png", bytes); P("SHOT %s", nm)
    else P("SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if not ok then P("capture error %s", tostring(err)); return end
  wait_for(function() return done end, 5, "shot " .. nm)
end

-- The free camera at body-relative point `rel` (a {x,y,z}), looking along
-- horizontal `ref` with `pitch` (rad). Leaves it there; w_cam_off ends it.
local function w_cam(b, rel, ref, pitch)
  local pc = findScript("planet_camera")
  if not (pc and pc.setFreecam and pc.freecamState) then return false end
  pc.setFreecam(true); wait(0.3)
  local fc = pc.freecamState()
  fc.body = b.name
  fc.rel = vec3(rel.x, rel.y, rel.z)
  fc.ref = vec3(ref.x, ref.y, ref.z)
  fc.pitch = pitch or 0
  wait(1.2)
  return true
end
local function w_cam_off()
  local pc = findScript("planet_camera")
  if pc and pc.setFreecam then pc.setFreecam(false); wait(0.4) end
end

-- A unit direction `d` metres along unit tangent `t` from unit direction `u`
-- on a sphere of radius R.
local function w_along(u, t, d, R)
  local k = d / R
  return unit({ x = u.x + t.x * k, y = u.y + t.y * k, z = u.z + t.z * k })
end
local function w_tangent(u)
  local a = { x = 0, y = 1, z = 0 }
  if math.abs(u.y) > 0.9 then a = { x = 1, y = 0, z = 0 } end
  local t1 = unit(cross(u, a))
  return t1, unit(cross(u, t1))
end

-- The ground radius under unit direction u, marched down from `from`; the
-- field has a top (nil above the planet's relief), so a start above it is
-- lowered 15 m at a time until the field answers.
local function w_ground(u, from)
  for _ = 1, 8 do
    local b = home()
    local g = ground_r(b, u.x, u.y, u.z, from)
    if g then return g end
    from = from - 15
  end
  return nil
end

-- The ground streams in round the player: put the crew at unit direction u,
-- `rad` from the centre, and wait for the field to answer there.
local function w_stream_to(u, rad, what)
  local A = astro()
  local function put()
    local bb = home()
    A.x, A.y, A.z = bb.x + u.x * rad, bb.y + u.y * rad, bb.z + u.z * rad
    A.vx, A.vy, A.vz = 0, 0, 0
  end
  put()
  local ok = wait_for(function()
    put()
    local bb = home()
    return terrain.query(bb.x + u.x * rad, bb.y + u.y * rad, bb.z + u.z * rad) ~= nil
      and not (terrain.busy and terrain.busy())
  end, 40, "ground streamed at " .. (what or "?"))
  wait(2.0)
  put()
  return ok ~= nil
end

-- A beach within `reach` m of unit direction u0: ground 1.5–5 m over the sea
-- with open sea (ground 3 m under it) within 28 m and land behind. → u (unit
-- dir), g (ground radius), seaward unit tangent; or nil.
local function w_find_beach(b, R, u0, reach)
  local t1, t2 = w_tangent(u0)
  local N = 900
  for i = 0, N - 1 do
    -- a sunflower spiral out to `reach`
    local rr = math.sqrt((i + 0.5) / N) * reach
    local th = i * 2.399963
    local u = w_along(u0, unit({ x = t1.x * math.cos(th) + t2.x * math.sin(th), y = t1.y * math.cos(th) + t2.y * math.sin(th), z = t1.z * math.cos(th) + t2.z * math.sin(th) }), rr, R)
    local g = w_ground(u, R + 60)
    if g and g > R + 1.5 and g < R + 5 then
      local t1, t2 = w_tangent(u)
      for k = 0, 7 do
        local a = k * math.pi / 4
        local t = unit({ x = t1.x * math.cos(a) + t2.x * math.sin(a), y = t1.y * math.cos(a) + t2.y * math.sin(a), z = t1.z * math.cos(a) + t2.z * math.sin(a) })
        local d = w_along(u, t, 28, R)
        local gs = w_ground(d, R + 60)
        -- the SEA, by climate's own rule (a dug hole or a crater under the
        -- sea's radius is not: the first run's "beach" stood by a quarry)
        local d2 = w_along(u, t, 45, R)
        local cl2 = findScript("climate")
        local bb = home()
        local open = gs and gs < R - 3 and cl2 and cl2.seaDepth(bb.x + d2.x * (R - 1), bb.y + d2.y * (R - 1), bb.z + d2.z * (R - 1))
        if open and open > 0 then
          -- and land the other way (a beach, not a reef)
          local dl = w_along(u, t, -40, R)
          local gl = w_ground(dl, R + 80)
          if gl and gl > R + 2 then return u, g, t end
        end
      end
    end
    if i % 50 == 0 then yield() end
  end
  return nil
end

-- Dig a shaft at unit direction u from radius `top` down to radius `bottom`
-- with balls of radius r (terrain.dig, the laser's own brush), then wait for
-- the ground to land.
local function w_shaft(u, top, bottom, r)
  local n = 0
  local rad = top
  while rad > bottom do
    local b = home()
    terrain.dig(b.x + u.x * rad, b.y + u.y * rad, b.z + u.z * rad, r, 1.0, { hardness = 1.0, falloff = "linear" })
    n = n + 1
    rad = rad - r * 0.7
    yield()
  end
  local b = home()
  terrain.dig(b.x + u.x * bottom, b.y + u.y * bottom, b.z + u.z * bottom, r, 1.0, { hardness = 1.0, falloff = "linear" })
  wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, 30, "digs landing")
  wait(2.5)
  return n + 1
end

local function w_climate_ms(secs)
  local acc, n, worst = 0, 0, 0
  for _ = 1, math.floor(secs * 2) do
    wait(0.5)
    local m = perf.scriptMs and perf.scriptMs("climate") or 0
    acc, n = acc + m, n + 1
    local ww = perf.scriptWorstMs and perf.scriptWorstMs("climate") or 0
    if ww > worst then worst = ww end
  end
  return n > 0 and acc / n or 0, worst
end

local function w_depth_at(cl, u, rad)
  local b = home()
  return cl.seaDepth(b.x + u.x * rad, b.y + u.y * rad, b.z + u.z * rad)
end

local function run_water()
  wait_ready(90)
  local b = home()
  local cl = findScript("climate")
  local oc = findScript("ocean")
  local pw = findScript("planet_walker")
  local R = cl and cl.seaRadius(b.name) or 0
  local WR = (cl and cl.worldOf and cl.worldOf(b.name) or {}).radius or b.radius   -- the genspec radius (lake levels are over it), not the celestial's
  P("WATER world %s radius %.1f (celestial %.1f) sea radius %.1f", b.name, WR, b.radius, R)
  perf.enable(true)
  local ms0, w0 = w_climate_ms(4)
  P("PERF climate at the base: %.3f ms/frame (worst %.2f)", ms0, w0)
  local A = astro()
  local function put(u, rad)
    local bb = home()
    A.x, A.y, A.z = bb.x + u.x * rad, bb.y + u.y * rad, bb.z + u.z * rad
    A.vx, A.vy, A.vz = 0, 0, 0
  end

  -- THE BASE PIT (Ty, 11-12b: "digging a hole still leads to water", a 6 m
  -- pit by the base fence with a puddle in it): 6 m down, 14 m from where the
  -- crew starts. No water is beside it: it must stay DRY, with no pool.
  do
    local bb = home()
    local bu = unit({ x = A.x - bb.x, y = A.y - bb.y, z = A.z - bb.z })
    local bt = w_tangent(bu)
    local pu0 = w_along(bu, bt, 14, WR)
    local pg0 = w_ground(pu0, len(A.x - bb.x, A.y - bb.y, A.z - bb.z) + 30)
    if pg0 then
      local n0 = w_shaft(pu0, pg0 + 0.5, pg0 - 6.0, 2.4)
      wait(4)
      local fl0 = ground_r(home(), pu0.x, pu0.y, pu0.z, pg0 + 3) or (pg0 - 6)
      local sd0 = w_depth_at(cl, pu0, fl0 + 0.5)
      local np0 = 0
      for _, p in pairs(cl.waterNear().poolSpecs or {}) do np0 = np0 + 1 end
      local ps0 = cl.poolStats or {}
      P("BASEPIT %d bites, ground %.1f over the sea's radius, floor %.1f; seaDepth %s, pools %d (pits %s dry %s)", n0, pg0 - R, fl0 - R,
        tostring(sd0), np0, tostring(ps0.pits), tostring(ps0.dry))
      P("WATER RESULT base pit: %s", ((sd0 == nil or sd0 <= 0) and np0 == 0) and "DRY" or "WET")
      local be = w_along(pu0, bt, -6, WR)
      if w_cam(home(), { x = be.x * (pg0 + 4), y = be.y * (pg0 + 4), z = be.z * (pg0 + 4) }, bt, -0.7) then
        w_shot("0_base_pit")
        w_cam_off()
      end
    end
  end
  if R > 0 then
    -- Where is a coast? The ground only exists near the player, so go to
    -- where a river ends (it runs to the sea), else try the base's own
    -- surroundings, else a few spots round the world.
    local h0 = cl.hydroOf and cl.hydroOf(b.name)
    local tries = {}
    local a0 = astro()
    tries[#tries + 1] = { name = "the base", u = unit({ x = a0.x - b.x, y = a0.y - b.y, z = a0.z - b.z }) }
    for _, rv in ipairs(h0 and h0.rivers or {}) do
      if rv.river and #rv.points >= 6 then
        local n = #rv.points
        local e = unit({ x = rv.points[n - 2], y = rv.points[n - 1], z = rv.points[n] })
        -- a river's mouth at the sea: its last point is under the sea's radius
        tries[#tries + 1] = { name = "a river's mouth", u = e }
        if #tries >= 4 then break end
      end
    end
    for i = 0, 5 do
      local y = 1 - (i + 0.5) / 6 * 2
      local rr = math.sqrt(1 - y * y)
      local th = i * 2.399963
      tries[#tries + 1] = { name = "spot " .. i, u = { x = math.cos(th) * rr, y = y, z = math.sin(th) * rr } }
    end
    local u, g, t
    for _, tr in ipairs(tries) do
      if #tries > 1 and tr.name ~= "the base" then w_stream_to(tr.u, R + 40, tr.name) end
      b = home()
      u, g, t = w_find_beach(b, R, tr.u, 420)
      P("COAST search at %s: %s", tr.name, u and "beach found" or "no beach")
      if u then break end
    end
    if not u then
      P("WATER RESULT beach: none found (no shore 1.5–5 m over the sea with sea within 28 m)")
    else
      P("BEACH at ground %.1f (%.1f over the sea)", g, g - R)
      put(u, g + 1.2)
      wait(2.0)
      P("BEACH crew: seaDepth %s swimming %s", tostring(w_depth_at(cl, u, g + 1.0)), tostring(pw and pw.swimming))
      -- shots of the shoreline: eye level looking seaward, then from 25 m up
      local eye = w_along(u, t, -6, R)
      if w_cam(home(), { x = eye.x * (g + 1.7), y = eye.y * (g + 1.7), z = eye.z * (g + 1.7) }, t, -0.08) then
        w_shot("1_shore_eye")
        local fc = findScript("planet_camera").freecamState()
        fc.rel = vec3(eye.x, eye.y, eye.z) * (g + 25)
        fc.pitch = -0.7
        wait(1.0)
        w_shot("2_shore_high")
        w_cam_off()
      end
      -- THE NEAR PIT: 30–70 m from the beach, ground 3–14 m over the sea,
      -- dug to 3 m under the sea's radius. Dry, by the reach rule, and no pool.
      local pu, pg
      -- (a fan of inland directions, 60 m to 220 m, ground 3–14 m over the
      -- sea: low coast, not a cliff top, so a 2.4 m brush reaches under it)
      local bt1, bt2 = w_tangent(u)
      local prof = {}
      for d = -220, 40, 20 do
        local gg = w_ground(w_along(u, t, d, R), R + 80)
        prof[#prof + 1] = string.format("%d:%s", d, gg and string.format("%.1f", gg - R) or "nil")
      end
      P("BEACH ground profile along the seaward line (m: over the sea): %s", table.concat(prof, " "))
      for _, ang in ipairs({ 0, 0.5, -0.5, 1.0, -1.0, 1.5, -1.5 }) do
        if pu then break end
        local tx = unit({ x = -t.x * math.cos(ang) + bt1.x * math.sin(ang), y = -t.y * math.cos(ang) + bt1.y * math.sin(ang), z = -t.z * math.cos(ang) + bt1.z * math.sin(ang) })
        for d = 6, 16, 2 do
          local cand = w_along(u, tx, d, R)
          local gg = w_ground(cand, R + 80)
          if gg and gg > R + 1.2 and gg < R + 14 then pu, pg = cand, gg break end
        end
      end
      if not pu then
        P("WATER RESULT pit: no ground 3–14 m over the sea 60–220 m inland")
      else
        local c0 = perf.counts()
        local n = w_shaft(pu, pg + 0.5, R - 3.0, 2.4)
        local floor = ground_r(home(), pu.x, pu.y, pu.z, pg + 3) or (R - 3)
        P("PIT dug with %d bites: ground was %.1f over the sea, floor now %.1f under it", n, pg - R, R - floor)
        local sd
        for i = 1, 6 do
          wait(0.5)
          sd = w_depth_at(cl, pu, floor + 0.6)
          P("PIT t=%.1f seaDepth at the floor %s", i * 0.5, tostring(sd))
        end
        put(pu, floor + 1.0)
        wait(1.5)
        local bb = home()
        local wa = water.at(vec3(A.x, A.y, A.z))
        local wn = cl.waterNear and cl.waterNear() or {}
        local npits = 0
        for _, p in pairs(wn.poolSpecs or {}) do if p.kind == "pit" then npits = npits + 1 end end
        local pool
        for _, p in pairs(wn.poolSpecs or {}) do if p.kind == "pit" then pool = p end end
        P("PIT crew at the floor: seaDepth %s swimming %s water.at %s ocean.caveDry %s pit pools %d%s",
          tostring(w_depth_at(cl, pu, floor + 1.0)), tostring(pw and pw.swimming),
          wa and string.format("depth %.2f", wa.depth or -1) or "nil", tostring(oc and oc.caveDry), npits,
          pool and string.format(" (level %.2f target %.2f over the radius; the sea is %.2f)", pool.level, pool.target or -99, R - WR) or "")
        -- This pit is within PIT_SOURCE (60 m) of the sea: the sea is not IN it
        -- (seaDepth -1, no murk) but it SEEPS in, to the sea's level.
        local seeps = pool ~= nil and math.abs((pool.target or -99) - (R - WR)) < 0.3
        -- (a pit a few metres behind a low beach usually opens into the sea
        -- itself: then it IS sea, which is as honest as a seep)
        P("WATER RESULT near pit: %s (seaDepth %s; %s)", (sd and sd > 0) and "JOINED THE SEA" or (seeps and "SEEPS TO SEA LEVEL" or "DRY"),
          tostring(sd), pool and "a seep pool with the sea's level" or "no seep pool")
        local t1 = w_tangent(pu)
        if w_cam(home(), { x = pu.x * (floor + 1.5), y = pu.y * (floor + 1.5), z = pu.z * (floor + 1.5) }, t1, -0.35) then
          w_shot("3_pit_inside")
          local fc = findScript("planet_camera").freecamState()
          local above = w_along(pu, t1, -7, R)
          fc.rel = vec3(above.x, above.y, above.z) * (pg + 9)
          fc.pitch = -1.05
          wait(1.0)
          w_shot("4_pit_above")
          w_cam_off()
        end
        local rs = wn.reach or {}
        P("REACH after the pit: floods %s wet %s dry %s cold %s deferred %s cells %s", tostring(rs.floods), tostring(rs.wet),
          tostring(rs.dry), tostring(rs.cold), tostring(rs.deferred), tostring(rs.cells))
      end
      -- THE FAR PIT: 100–220 m inland (past PIT_SOURCE of the sea), dug 7 m
      -- deep wherever the ground is, under the sea's radius if it reaches.
      -- Nothing stands near enough to seep: DRY, and no pool.
      local fu, fg
      for _, ang in ipairs({ 0, 0.6, -0.6, 1.1, -1.1 }) do
        if fu then break end
        local tx = unit({ x = -t.x * math.cos(ang) + bt1.x * math.sin(ang), y = -t.y * math.cos(ang) + bt1.y * math.sin(ang), z = -t.z * math.cos(ang) + bt1.z * math.sin(ang) })
        for d = 100, 220, 15 do
          local cand = w_along(u, tx, d, R)
          local gg = w_ground(cand, R + 80)
          if gg and gg > R + 3 and gg < R + 30 then
            -- (no sea within 70 m of it)
            local near_sea = false
            local c1, c2 = w_tangent(cand)
            for k = 0, 7 do
              local a = k * math.pi / 4
              for _, rr in ipairs({ 6, 12, 20, 30, 45, 70 }) do
                local q = w_along(cand, unit({ x = c1.x * math.cos(a) + c2.x * math.sin(a), y = c1.y * math.cos(a) + c2.y * math.sin(a), z = c1.z * math.cos(a) + c2.z * math.sin(a) }), rr, R)
                local gq = w_ground(q, R + 80)
                if gq and gq < R + 0.8 then near_sea = true end
              end
            end
            if not near_sea then fu, fg = cand, gg break end
          end
        end
      end
      if not fu then
        P("WATER RESULT far pit: no inland ground 3–30 m over the sea with no sea within 70 m")
      else
        local before = 0
        for _, p in pairs(cl.waterNear().poolSpecs or {}) do if p.kind == "pit" then before = before + 1 end end
        local n = w_shaft(fu, fg + 0.5, (fg < R + 16) and (R - 2.5) or (fg - 7), 2.4)
        local floor = ground_r(home(), fu.x, fu.y, fu.z, fg + 3) or (fg - 7)
        wait(3)
        local sd = w_depth_at(cl, fu, floor + 0.6)
        local after = 0
        for _, p in pairs(cl.waterNear().poolSpecs or {}) do if p.kind == "pit" then after = after + 1 end end
        P("FARPIT %d bites, ground %.1f over the sea, floor %.1f %s the sea's radius: seaDepth %s, pit pools %d -> %d", n, fg - R,
          math.abs(R - floor), floor < R and "under" or "over", tostring(sd), before, after)
        P("WATER RESULT far pit: %s", ((sd == nil or sd <= 0) and after == before) and "DRY" or "WET")
        do
          -- why: the field at the sea's radius round the pit, and the reach stats
          local c1, c2 = w_tangent(fu)
          local out = {}
          for _, rr in ipairs({ 0, 2, 4, 6, 9, 14 }) do
            local row = {}
            for k = 0, 7 do
              local a = k * math.pi / 4
              local q = w_along(fu, unit({ x = c1.x * math.cos(a) + c2.x * math.sin(a), y = c1.y * math.cos(a) + c2.y * math.sin(a), z = c1.z * math.cos(a) + c2.z * math.sin(a) }), rr, R)
              local bb = home()
              local v = terrain.query(bb.x + q.x * R, bb.y + q.y * R, bb.z + q.z * R)
              row[#row + 1] = v and string.format("%.1f", v) or "nil"
            end
            out[#out + 1] = rr .. "m[" .. table.concat(row, " ") .. "]"
          end
          local rs = cl.waterNear().reach or {}
          P("FARPIT field at the sea's radius: %s", table.concat(out, " "))
          P("FARPIT reach: floods %s wet %s dry %s cold %s deferred %s cells %s; lakeDepth %s", tostring(rs.floods), tostring(rs.wet), tostring(rs.dry),
            tostring(rs.cold), tostring(rs.deferred), tostring(rs.cells), tostring(cl.lakeDepth(home().name, home().x + fu.x * (floor + 0.6), home().y + fu.y * (floor + 0.6), home().z + fu.z * (floor + 0.6))))
        end
        local ps = cl.poolStats or {}
        P("POOLS after the far pit: pits %s dry %s", tostring(ps.pits), tostring(ps.dry))
      end
      -- THE TRENCH: from 3 m seaward of the waterline, 16 m inland, cut to
      -- 1.6 m under the sea's radius, ending in a pit. The sea reaches it.
      -- (the waterline: where the beach's ground meets the sea's radius)
      local wl = nil
      for d = 0, 40, 2 do
        local cand = w_along(u, t, d, R)
        local gg = w_ground(cand, R + 60)
        if gg and gg < R then wl = d break end
      end
      if not wl then
        P("WATER RESULT trench: no waterline found seaward of the beach")
      else
        local far = w_along(u, t, wl - 16, R)
        local gfar = w_ground(far, R + 60) or R
        for d = wl + 3, wl - 16, -1.6 do
          local p = w_along(u, t, d, R)
          local bb = home()
          terrain.dig(bb.x + p.x * (R - 1.6), bb.y + p.y * (R - 1.6), bb.z + p.z * (R - 1.6), 2.2, 1.0, { hardness = 1.0, falloff = "linear" })
          -- and the ground over the cut, where the bank stands higher
          local gg = w_ground(p, R + 60)
          if gg and gg > R + 0.5 then
            local rad = gg
            while rad > R do
              terrain.dig(bb.x + p.x * rad, bb.y + p.y * rad, bb.z + p.z * rad, 2.2, 1.0, { hardness = 1.0, falloff = "linear" })
              rad = rad - 1.5
            end
          end
          yield()
        end
        w_shaft(far, gfar + 0.5, R - 3.0, 2.4)
        local tfloor = ground_r(home(), far.x, far.y, far.z, gfar + 3) or (R - 3)
        local td
        for i = 1, 8 do
          wait(0.5)
          td = w_depth_at(cl, far, tfloor + 0.5)
          P("TRENCH t=%.1f seaDepth at the pit's floor %s (floor %.1f under the sea)", i * 0.5, tostring(td), R - tfloor)
        end
        P("WATER RESULT trench: %s (seaDepth %s)", (td and td > 0) and "FLOODED" or "DRY", tostring(td))
        local teye = w_along(u, t, wl + 10, R)
        local back = { x = -t.x, y = -t.y, z = -t.z }
        if w_cam(home(), { x = teye.x * (R + 7), y = teye.y * (R + 7), z = teye.z * (R + 7) }, back, -0.45) then
          w_shot("5_trench")
          w_cam_off()
        end
        local ms1, w1 = w_climate_ms(4)
        P("PERF climate beside the digs: %.3f ms/frame (worst %.2f)", ms1, w1)
      end
    end
  else
    P("WATER RESULT sea: the home world has no sea; pit and trench skipped")
  end

  -- A PIT BESIDE A LAKE seeps full to the lake's level.
  local h = cl.hydroOf and cl.hydroOf(b.name)
  local L = h and h.lakes and h.lakes[1]
  if not L then
    P("WATER RESULT lake pit: the home world has no lakes")
    return
  end
  b = home()
  local lu = unit({ x = L.x, y = L.y, z = L.z })
  local Rl = WR + L.level
  local t1 = w_tangent(lu)
  -- the ground round the lake has to be there first
  P("LAKE 1: level %.1f reach %.0f depth %.1f at %.0f %.0f %.0f (|p| %.1f)", L.level, L.reach, L.depth or -1, L.x, L.y, L.z, len(L.x, L.y, L.z))
  w_stream_to(w_along(lu, t1, L.reach + 14, WR), Rl + 12, "lake 1")
  wait(6)
  b = home()
  -- the shore: out along t1 until the ground stands over the water, then 12 m on
  local shore, sg = nil, nil
  local prof = {}
  for d = 0, L.reach * 2 + 60, 10 do
    local cand = w_along(lu, t1, d, WR)
    local gg = w_ground(cand, Rl + 60)
    prof[#prof + 1] = string.format("%d:%s", d, gg and string.format("%.1f", gg - Rl) or "nil")
  end
  P("LAKE ground profile out from the centre (m: over the lake's level): %s", table.concat(prof, " "))
  -- (dry ground for 8 m running: three samples over the level, so the pit
  -- is on the bank, not on a bump in the shallows)
  local run = 0
  for d = L.reach * 0.5, L.reach * 2 + 60, 4 do
    local cand = w_along(lu, t1, d, WR)
    local gg = w_ground(cand, Rl + 60)
    if gg and gg > Rl + 0.5 then run = run + 1 else run = 0 end
    if run >= 3 then shore = d - 8; sg = gg break end
  end
  if not shore then P("WATER RESULT lake pit: no shore found round lake 1"); return end
  local pu = w_along(lu, t1, shore + 12, WR)
  local pg = w_ground(pu, Rl + 80)
  if not (pg and pg > Rl + 0.3) then P("WATER RESULT lake pit: the spot 12 m off the shore is not above the lake (%s)", tostring(pg)); return end
  put(pu, pg + 1.5)
  local ok = wait_for(function() local wn = cl.waterNear(); return wn.lakes >= 1 end, 60, "the lake built")
  P("LAKE level %.1f reach %.0f: built %s; pit spot %.1f over the lake, %.0f m from the water", L.level, L.reach, tostring(ok ~= nil), pg - Rl, 12)
  local n = w_shaft(pu, pg + 0.5, Rl - 2.5, 2.4)
  local floor = ground_r(home(), pu.x, pu.y, pu.z, pg + 3) or (Rl - 2.5)
  P("LAKEPIT dug with %d bites, floor %.1f under the lake's level", n, Rl - floor)
  local pool, filled = nil, false
  for i = 1, 20 do
    wait(5)
    local wn = cl.waterNear()
    pool = nil
    for _, p in pairs(wn.poolSpecs or {}) do if p.kind == "pit" then pool = p end end
    local d = w_depth_at(cl, pu, floor + 0.4)
    P("LAKEPIT t=%ds pool %s depth at floor+0.4 %s pools built %d", i * 5,
      pool and string.format("level %.2f target %.2f rate %.3f", pool.level, pool.target or -99, pool.rate or 0) or "none", tostring(d), wn.pools or 0)
    if pool and math.abs((pool.target or 0) - pool.level) < 0.02 and d and d > 0 then filled = true break end
    if not pool and i >= 3 then break end
  end
  P("WATER RESULT lake pit: %s", filled and "SEEPED FULL" or (pool and "FILLING (not done in 100 s)" or "NO POOL"))
  local peye = w_along(pu, t1, 6, WR)
  local back = { x = -t1.x, y = -t1.y, z = -t1.z }
  if w_cam(home(), { x = peye.x * (pg + 5), y = peye.y * (pg + 5), z = peye.z * (pg + 5) }, back, -0.75) then
    w_shot("6_lake_pit")
    local fc = findScript("planet_camera").freecamState()
    local le = w_along(lu, t1, shore - 4, WR)
    fc.rel = vec3(le.x, le.y, le.z) * (Rl + 1.6)
    fc.ref = vec3(t1.x, t1.y, t1.z)
    fc.pitch = -0.12
    wait(1.0)
    w_shot("7_lake_shore")
    w_cam_off()
  end
  local ms2, w2 = w_climate_ms(4)
  P("PERF climate at the lake: %.3f ms/frame (worst %.2f)", ms2, w2)
  local wn = cl.waterNear()
  local rs = wn.reach or {}
  P("REACH final: floods %s wet %s dry %s cold %s deferred %s cells %s", tostring(rs.floods), tostring(rs.wet),
    tostring(rs.dry), tostring(rs.cold), tostring(rs.deferred), tostring(rs.cells))
  local ps = cl.poolStats or {}
  P("POOLS final: pits %s sumps %s dry %s rebuilt %s breaches %s searches %s", tostring(ps.pits), tostring(ps.sumps),
    tostring(ps.dry), tostring(ps.rebuilt), tostring(ps.breaches), tostring(ps.searches))
end

-- ── sea look (waterprobe.sh sealook): the sea's rendering, R1 ──────────────
-- Shots of the home world's sea from the shore, skimming the surface, from
-- 12 m, 150 m and 700 m up, and after a fly along the shore (the cap re-aims
-- under the eye); the frame's buckets and GPU passes with the sea filling the
-- screen (scenario b_sea), ocean.lua's cost and the cap's build stats.
local function run_sealook()
  wait_ready(90)
  local b = home()
  local cl = findScript("climate")
  local oc = findScript("ocean")
  local R = cl and cl.seaRadius(b.name) or 0
  local WR = (cl and cl.worldOf and cl.worldOf(b.name) or {}).radius or b.radius
  P("SEALOOK world %s radius %.1f sea radius %.1f", b.name, WR, R)
  if R <= 0 then P("SEALOOK RESULT: no sea on the home world"); return end
  perf.enable(true)
  local a0 = astro()
  local u, g, t = w_find_beach(home(), R, unit({ x = a0.x - b.x, y = a0.y - b.y, z = a0.z - b.z }), 420)
  if not u then
    local h0 = cl.hydroOf and cl.hydroOf(b.name)
    for _, rv in ipairs(h0 and h0.rivers or {}) do
      if u then break end
      if rv.river and #rv.points >= 6 then
        local n = #rv.points
        local e = unit({ x = rv.points[n - 2], y = rv.points[n - 1], z = rv.points[n] })
        w_stream_to(e, R + 40, "a river's mouth")
        u, g, t = w_find_beach(home(), R, e, 420)
      end
    end
  end
  if not u then P("SEALOOK RESULT: no beach found"); return end
  local A = astro()
  b = home()
  A.x, A.y, A.z = b.x + u.x * (g + 1.2), b.y + u.y * (g + 1.2), b.z + u.z * (g + 1.2)
  A.vx, A.vy, A.vz = 0, 0, 0
  wait(3)
  -- (every sea's script: findScript("ocean") answers another world's)
  local function caps()
    local out = { builds = 0, reads = 0, frames = 0 }
    local list = findScripts and findScripts("ocean") or (oc and { oc } or {})
    for _, o in ipairs(list) do
      local cs = o and o.capStats
      if cs then out.builds, out.reads, out.frames = out.builds + (cs.builds or 0), out.reads + (cs.reads or 0), out.frames + (cs.frames or 0) end
    end
    return out
  end
  local function stats(tag)
    local cs = caps()
    local sc = find and find("SeaCap")
    if sc then
      local okm, m = pcall(sc.material, sc)
      local okp, parts = pcall(sc.materials, sc)
      P("SEALOOK cap node: valid %s visible %s model %s shader %s parts %s parent %s", tostring(sc.valid), tostring(sc.visible), tostring(sc.model),
        tostring(okm and m and m.shader), tostring(okp and parts and #parts), tostring(sc.parent and sc.parent.name))
    else
      P("SEALOOK cap node: none")
    end
    for _, o in ipairs(findScripts and findScripts("ocean") or {}) do
      if o.waveNow then P("SEALOOK swell: U %.1f amp %.3f lam %.2f g %.2f R %.1f", o.waveNow.U, o.waveNow.amp, o.waveNow.lam, o.waveNow.g, o.waveNow.R) end
    end
    P("SEALOOK %s: ocean %.3f ms (worst %.2f) climate %.3f ms; cap builds %s reads %s frames %s; gpu %s ms", tag,
      perf.scriptMs and perf.scriptMs("ocean") or -1, perf.scriptWorstMs and perf.scriptWorstMs("ocean") or -1,
      perf.scriptMs and perf.scriptMs("climate") or -1, tostring(cs.builds), tostring(cs.reads), tostring(cs.frames),
      tostring((function() local ok, gg = pcall(perf.gpu); return ok and gg and gg.total or "?" end)()))
  end
  -- a: the shore at eye level, looking out to sea
  local eye = w_along(u, t, 10, R)
  if not w_cam(home(), { x = eye.x * (R + 1.7), y = eye.y * (R + 1.7), z = eye.z * (R + 1.7) }, t, -0.06) then
    P("SEALOOK RESULT: no free camera"); return
  end
  wait(2.5)
  stats("shore")
  local wf0 = cl.waterFx or {}
  P("SEALOOK waterfx shore: on %s depth %.2f R %.1f", tostring(wf0.on), wf0.depth or -99, wf0.R or 0)
  w_shot("a_shore_eye")
  local pc = findScript("planet_camera")
  local fc = pc.freecamState()
  -- b: skimming the surface 25 m out, looking along it (reflections, foam)
  local out = w_along(u, t, 25, R)
  fc.rel = vec3(out.x, out.y, out.z) * (R + 0.5)
  fc.ref = vec3(t.x, t.y, t.z)
  fc.pitch = -0.04
  wait(2.0)
  sc_begin("b_sea")
  wait(6)
  sc_end("b_sea")
  stats("skim")
  w_shot("b_skim")
  -- grazing looks (Ty, 11-12: the horizon's bend showed through the surface):
  -- 0.5, 1.5 and 3 m over the water, level, out to the horizon
  for _, hgt in ipairs({ 0.5, 1.5, 3.0 }) do
    fc.rel = vec3(out.x, out.y, out.z) * (R + hgt)
    fc.ref = vec3(t.x, t.y, t.z)
    fc.pitch = -0.02
    wait(1.5)
    w_shot(string.format("b_graze_%.1fm", hgt))
  end
  -- jitter (Ty, 11-12: "the water jitters into different shapes"): a camera
  -- held at a fixed BODY-relative point 2 m over the water for ~10 s while
  -- the planet moves, 16 shots; work/water/jitter_diff.py diffs them. The
  -- wind is logged with each so a direction change can be matched to a jump.
  fc.rel = vec3(out.x, out.y, out.z) * (R + 2.0)
  fc.ref = vec3(t.x, t.y, t.z)
  fc.pitch = -0.35
  wait(1.5)
  local wx0 = findScript("weather")
  for k = 0, 15 do
    local wc0 = wx0 and wx0.current and wx0.current()
    local bb0 = home()
    P("SEALOOK jit %02d: t %.2f body %.1f %.1f %.1f wind %.1f dir %.2f %.2f %.2f", k, time, bb0.x, bb0.y, bb0.z,
      wc0 and (wc0.windNow or wc0.wind or 0) or -1, wc0 and wc0.windX or 0, wc0 and wc0.windY or 0, wc0 and wc0.windZ or 0)
    w_shot(string.format("j_jit_%02d", k))
    wait(0.2)
  end
  -- c: 12 m up, looking down 45°
  fc.rel = vec3(out.x, out.y, out.z) * (R + 12)
  fc.pitch = -0.8
  wait(2.0)
  w_shot("c_12m")
  -- d: 150 m up (the cap's reach from above)
  fc.rel = vec3(out.x, out.y, out.z) * (R + 150)
  fc.pitch = -1.2
  wait(2.5)
  stats("150m")
  w_shot("d_150m")
  -- e: 700 m up (the far sphere alone)
  fc.rel = vec3(out.x, out.y, out.z) * (R + 700)
  fc.pitch = -1.3
  wait(2.5)
  stats("700m")
  w_shot("e_700m")
  -- f: back down, a fly along the shore (the cap re-aims under the eye)
  local st = w_along(u, t, 12, R)
  fc.rel = vec3(st.x, st.y, st.z) * (R + 1.2)
  fc.ref = vec3(t.x, t.y, t.z)
  fc.pitch = -0.03
  wait(2.0)
  local c0 = caps().builds
  key_down("w")
  wait(2.0)
  w_shot("f_fly_moving")
  wait(2.0)
  key_up("w")
  wait(1.0)
  local c1 = caps().builds
  P("SEALOOK fly: cap builds %d -> %d", c0, c1)
  stats("fly")
  w_shot("f_fly")
  -- g: the same from the water, 0.3 m under, looking up at the surface
  local sw = w_along(u, t, 30, R)
  fc.rel = vec3(sw.x, sw.y, sw.z) * (R - 0.6)
  fc.ref = vec3(t.x, t.y, t.z)
  fc.pitch = 0.5
  wait(2.0)
  local wf = cl.waterFx or {}
  P("SEALOOK waterfx under: on %s depth %.2f R %.1f", tostring(wf.on), wf.depth or -99, wf.R or 0)
  w_shot("g_under")
  -- the eye 2 m under, looking level along the water (the fog and the bed)
  fc.rel = vec3(sw.x, sw.y, sw.z) * (R - 2.0)
  fc.pitch = -0.1
  wait(1.5)
  wf = cl.waterFx or {}
  P("SEALOOK waterfx 2 m under: on %s depth %.2f R %.1f", tostring(wf.on), wf.depth or -99, wf.R or 0)
  w_shot("g_under_level")
  -- h: a lake's shore (the same shader on a sheet climate built; its
  -- parameters land the tick after the node, dress_params)
  local h0 = cl.hydroOf and cl.hydroOf(b.name)
  -- a REAL lake: the one with the smallest reach over 15 m nearest the base
  -- (lake 1 on Naolol is a 467 m basin whose level sits within a metre of
  -- the ground: no sheet to see)
  local L, Lscore = nil, 1e18
  local a1 = astro()
  for _, Lk in ipairs(h0 and h0.lakes or {}) do
    if (Lk.reach or 0) > 15 and (Lk.reach or 0) < 150 and (Lk.depth or 0) > 1.5 then
      local d = len(Lk.x - (a1.x - b.x), Lk.y - (a1.y - b.y), Lk.z - (a1.z - b.z))
      if d < Lscore then L, Lscore = Lk, d end
    end
  end
  if L then P("SEALOOK lake pick: reach %.0f depth %.1f level %.1f, %.0f m from the crew", L.reach, L.depth or -1, L.level, Lscore) end
  if L then
    local lu = unit({ x = L.x, y = L.y, z = L.z })
    local Rl = WR + L.level
    local lt1 = w_tangent(lu)
    local le = w_along(lu, lt1, L.reach * 0.6, WR)
    fc.rel = vec3(le.x, le.y, le.z) * (Rl + 1.8)
    fc.ref = vec3(-lt1.x, -lt1.y, -lt1.z)
    fc.pitch = -0.12
    local A2 = astro()
    local bb = home()
    A2.x, A2.y, A2.z = bb.x + le.x * (Rl + 2.5), bb.y + le.y * (Rl + 2.5), bb.z + le.z * (Rl + 2.5)
    A2.vx, A2.vy, A2.vz = 0, 0, 0
    wait_for(function() return cl.waterNear().lakes >= 1 end, 60, "the lake built")
    wait(3)
    w_shot("h_lake")
    fc.rel = vec3(le.x, le.y, le.z) * (Rl + 20)
    fc.pitch = -0.9
    wait(1.5)
    w_shot("i_lake_high")
    P("SEALOOK lake 1: %s", tostring(cl.waterNear().lakes))
  end
  -- r: a RIVER (the longest, from a third of the way down): its ribbon, the
  -- stream loop, and the first waterfall the build found (sheet, mist, loop)
  local best_rv, best_len = nil, 0
  for _, rv in ipairs(h0 and h0.rivers or {}) do
    if rv.river and (rv.length or 0) > best_len then best_rv, best_len = rv, rv.length or 0 end
  end
  if best_rv then
    local n = math.floor(#best_rv.points / 3)
    local i = math.max(1, math.floor(n / 3))
    local ru = unit({ x = best_rv.points[i * 3 - 2], y = best_rv.points[i * 3 - 1], z = best_rv.points[i * 3] })
    w_stream_to(ru, WR + 30, "river")
    local A3 = astro()
    local bb = home()
    local rg = w_ground(ru, WR + 80) or WR
    A3.x, A3.y, A3.z = bb.x + ru.x * (rg + 1.5), bb.y + ru.y * (rg + 1.5), bb.z + ru.z * (rg + 1.5)
    A3.vx, A3.vy, A3.vz = 0, 0, 0
    -- (the free camera is the eye the water is built round: bring it along)
    fc.rel = vec3(ru.x, ru.y, ru.z) * (rg + 6)
    wait_for(function() return cl.waterNear().rivers >= 1 end, 60, "the river built")
    -- let the pieces near the eye finish (one build at a time)
    local last, same = -1, 0
    for _ = 1, 40 do
      wait(1)
      local nr = cl.waterNear().rivers
      if nr == last then same = same + 1 else same, last = 0, nr end
      if same >= 4 and nr >= 1 then break end
    end
    local wn = cl.waterNear()
    -- the built row nearest the crew (the hydro point itself may lie in a lake's basin)
    local bb3 = home()
    local crx, cry, crz = A3.x - bb3.x, A3.y - bb3.y, A3.z - bb3.z
    local row, rd = nil, 1e9
    for _, rw in ipairs(wn.rows or {}) do
      local d = len(rw.x - crx, rw.y - cry, rw.z - crz)
      if d < rd then row, rd = rw, d end
    end
    P("SEALOOK river: %d row samples, nearest %.0f m away; falls: %d", #(wn.rows or {}), rd, #(wn.falls or {}))
    for i, f in ipairs(wn.falls or {}) do
      if i <= 8 then P("SEALOOK   fall %d: drop %.1f half %.1f built %s piece %s, %.0f m from the crew", i, f.drop, f.half, tostring(f.built), tostring(f.piece), len(f.x - crx, f.y - cry, f.z - crz)) end
    end
    if row then
      ru = unit({ x = row.x, y = row.y, z = row.z })
      rg = len(row.x, row.y, row.z)
      w_stream_to(ru, rg + 2, "the river row")
      wait(3)
      A3 = astro()
      P("SEALOOK river: standing by the nearest built row (half-width %.1f m); stream loop at %s m", row.half or -1, tostring(cl.waterNear().ambient.stream))
      -- the current: the crew stood IN the stream, hands off, for 5 s
      local pwk = findScript("planet_walker")
      local bb4 = home()
      -- (feet on the bed: the capsule's centre ~0.6 m over the water)
      local rl4 = len(row.x, row.y, row.z)
      A3.x, A3.y, A3.z = bb4.x + row.x * (1 + 0.6 / rl4), bb4.y + row.y * (1 + 0.6 / rl4), bb4.z + row.z * (1 + 0.6 / rl4)
      A3.vx, A3.vy, A3.vz = 0, 0, 0
      wait(1.0)
      bb4 = home()
      local sx0, sy0, sz0 = A3.x - bb4.x, A3.y - bb4.y, A3.z - bb4.z
      local fvx, fvy, fvz = cl.flowAt(A3.x, A3.y, A3.z)
      P("SEALOOK current: seaDepth %s flowAt %.2f m/s wadeDepth %s walker.current %s", tostring(cl.seaDepth(A3.x, A3.y, A3.z)),
        len(fvx, fvy, fvz), tostring(pwk and pwk.wadeDepth), tostring(pwk and pwk.current))
      wait(5.0)
      bb4 = home()
      P("SEALOOK current: the crew drifted %.1f m in 5 s (wadeDepth %s, current %s)", len(A3.x - bb4.x - sx0, A3.y - bb4.y - sy0, A3.z - bb4.z - sz0),
        tostring(pwk and pwk.wadeDepth), tostring(pwk and pwk.current))
    end
    local am = wn.ambient or {}
    P("SEALOOK river: %d pieces built, falls %d, stream loop at %s m, fall loops %s, near %s; river stats %s",
      wn.rivers, #(wn.falls or {}), tostring(am.stream), tostring(am.fall), tostring(am.near), json and json(wn.stats) or "?")
    local rt1 = w_tangent(ru)
    local re = w_along(ru, rt1, 6, WR)
    fc.rel = vec3(re.x, re.y, re.z) * (rg + 1.7)
    fc.ref = vec3(-rt1.x, -rt1.y, -rt1.z)
    fc.pitch = -0.2
    wait(1.5)
    w_shot("r_river_eye")
    fc.rel = vec3(ru.x, ru.y, ru.z) * (rg + 25)
    fc.pitch = -1.1
    wait(1.5)
    w_shot("s_river_high")
    -- the nearest built fall: stand 12 m off its foot, looking at it
    local nf, nd = nil, 1e9
    bb = home()
    for _, f in ipairs(wn.falls or {}) do
      local d = len(f.x - (A3.x - bb.x), f.y - (A3.y - bb.y), f.z - (A3.z - bb.z))
      if d < nd then nf, nd = f, d end
    end
    if nf and nd > 600 then P("SEALOOK fall: the nearest is %.0f m away (a stale piece); none near", nd); nf = nil end
    if nf then
      local fu = unit({ x = nf.x, y = nf.y, z = nf.z })
      local fr = len(nf.x, nf.y, nf.z)
      w_stream_to(fu, fr + 3, "the fall")
      wait_for(function() local a = cl.waterNear().ambient; return a and (a.fall or 0) >= 1 end, 40, "a fall loop near")
      wait(3)
      local ft1 = w_tangent(fu)
      local fe = w_along(fu, ft1, 12, WR)
      fc.rel = vec3(fe.x, fe.y, fe.z) * (fr + 2.5)
      fc.ref = vec3(-ft1.x, -ft1.y, -ft1.z)
      fc.pitch = 0.1
      wait(2.0)
      local wn2 = cl.waterNear()
      P("SEALOOK fall: drop %.1f half %.1f built %s, %.0f m from the crew; fall loops %s", nf.drop, nf.half, tostring(nf.built), nd,
        tostring(wn2.ambient and wn2.ambient.fall))
      w_shot("t_fall")
      fc.rel = vec3(fu.x, fu.y, fu.z) * (fr + nf.drop + 8)
      fc.pitch = -0.9
      wait(1.5)
      w_shot("u_fall_above")
    else
      P("SEALOOK fall: none within the built pieces of the longest river")
    end
  end
  -- n: NOON over the first beach: warp the clock until the star stands at
  -- least 45° up, then the shore and skim shots again (the sky reflection
  -- and the glint in real light)
  if u and space.warp then
    local function sun_up()
      local bb = home()
      local best, bmu = nil, -1
      for _, sb in ipairs(space.bodies() or {}) do
        local key = ((sb.soi or 0) < 0 and 1e30 or 0) + (sb.mu or 0)
        if key > bmu then best, bmu = sb, key end
      end
      if not best then return 0 end
      local sx, sy, sz = best.x - (bb.x + u.x * R), best.y - (bb.y + u.y * R), best.z - (bb.z + u.z * R)
      local sl = len(sx, sy, sz)
      return (sx * u.x + sy * u.y + sz * u.z) / math.max(sl, 1e-6)
    end
    local A4 = astro()
    local bb = home()
    A4.x, A4.y, A4.z = bb.x + u.x * (g + 1.5), bb.y + u.y * (g + 1.5), bb.z + u.z * (g + 1.5)
    A4.vx, A4.vy, A4.vz = 0, 0, 0
    wait(2)
    local s0 = sun_up()
    local tries = 0
    while sun_up() < 0.7 and tries < 40 do
      space.warp(1000)
      wait(1.0)
      space.warp(1)
      wait(0.5)
      tries = tries + 1
    end
    P("SEALOOK noon: sun elevation sin %.2f -> %.2f after %d warps", s0, sun_up(), tries)
    wait(3)
    local ne = w_along(u, t, 10, R)
    fc.rel = vec3(ne.x, ne.y, ne.z) * (R + 1.7)
    fc.ref = vec3(t.x, t.y, t.z)
    fc.pitch = -0.08
    wait(2.0)
    w_shot("n_noon_shore")
    fc.rel = vec3(out.x, out.y, out.z) * (R + 0.6)
    fc.pitch = -0.05
    wait(1.5)
    w_shot("n_noon_skim")
    fc.rel = vec3(out.x, out.y, out.z) * (R + 12)
    fc.pitch = -0.8
    wait(1.5)
    w_shot("n_noon_12m")
    fc.rel = vec3(sw.x, sw.y, sw.z) * (R - 1.5)
    fc.pitch = 0.45
    wait(1.5)
    w_shot("n_noon_under")
  end
  w_cam_off()
  P("SEALOOK RESULT: shots a–u (+n) taken")
end

-- ── tysea (waterprobe.sh tysea, USERSAVE=1): one answer where the crew stands ──
-- On a copy of the player's save (cpuperf, 11-13: the crew in a pit 27 m
-- under Kaia's sea, beside the sea, read dry then wet between runs and
-- within one): climate.seaDepth at the crew four times a second for 45 s,
-- standing and then walked back and forth 6 m, with the terrain streaming
-- in round them. RESULT: how many times the wet/dry answer changed.
local function run_tysea()
  wait_ready(120)
  local cl = findScript("climate")
  local pw = findScript("planet_walker")
  local A = astro()
  local b = home()
  local name = space.dominant(A.x, A.y, A.z)
  local bb = space.body(name)
  local R = cl.seaRadius(name) or 0
  P("TYSEA body %s sea %.1f crew |r| %.1f (%.1f under the sea's radius)", tostring(name), R, len(A.x - bb.x, A.y - bb.y, A.z - bb.z), R - len(A.x - bb.x, A.y - bb.y, A.z - bb.z))
  local last, flips, wet_n, n = nil, 0, 0, 0
  local t0 = W()
  local walking = false
  while W() - t0 < 45 do
    wait(0.25)
    if not walking and W() - t0 > 15 then walking = true; key_down("w") end
    if walking and W() - t0 > 22 then key_up("w"); key_down("s") end
    if walking and W() - t0 > 29 then key_up("s") end
    local d = cl.seaDepth(A.x, A.y, A.z)
    local wet = d ~= nil and d > 0
    n = n + 1
    if wet then wet_n = wet_n + 1 end
    if last ~= nil and wet ~= last then
      flips = flips + 1
      P("TYSEA flip %d at %.1f s: seaDepth %s swimming %s busy %s", flips, W() - t0, tostring(d), tostring(pw and pw.swimming), tostring(terrain.busy and terrain.busy()))
    end
    last = wet
  end
  release_all()
  local rs = cl.reachStats or {}
  P("TYSEA RESULT: %d reads, %d wet, %d flips; reach floods %s wet %s dry %s cold %s; final seaDepth %s", n, wet_n, flips,
    tostring(rs.floods), tostring(rs.wet), tostring(rs.dry), tostring(rs.cold), tostring(cl.seaDepth(A.x, A.y, A.z)))
end
