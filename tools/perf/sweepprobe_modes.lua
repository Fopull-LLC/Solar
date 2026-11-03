-- ── sweep probe (tools/perf/sweepprobe.sh): what a falling spent stage costs physics ──
-- After the debris probe's orbit run (38.6 ms frames, physicsSweeps 9.3 ms in
-- the seconds after staging), each variant drops bare debris — a plain root
-- with part prefabs under it, built as debris_pack builds one, no controller,
-- no tags, kept out of the distant-craft LOD (keepLive: it is near the craft
-- that dropped it) — 150 m round the planet from the crew on foot, pushed down at
-- `vdown` m/s, and records `s_<variant>` for `secs` seconds: the frame, the
-- physics parts (physicsSweeps, physicsStatic) and perf.bodies per piece.
--   s_none            nothing falling (the baseline)
--   s_n1/n2/n4_small  1, 2, 4 pieces of one FT-S
--   s_n1/n4_large     1, 4 pieces of an 8-part stack
--   s_n1_large_air    the 8-part stack falling low, through the air
--   s_n1_legs         the stack with four landing legs
-- Also, with `slow=1`: the same large piece let go at rest (no push); and
-- s_n1_large_sph, s_n4_large_sph, s_n1_legs_sph: each part's box made a
-- sphere inside it before the rebuild; s_*_auto: the parts tagged as a
-- craft's, so debris_pack's fall tick switches them (packing kept out).
-- `DS` lines: the per-piece body cost and the sweeps per frame.
local DS = {}
local SMALL = { { "PartTankS", 0 } }
local LARGE = { { "PartSkipper", 0 }, { "PartTankM", 1.3 }, { "PartTankM", 1.8 }, { "PartTankM", 2.3 },
                { "PartDecoupler", 2.7 }, { "PartEngineM", 3.6 }, { "PartTankM", 4.6 }, { "PartTankS", 5.4 } }
local function with_legs(list)
  local o = {}
  for _, e in ipairs(list) do o[#o + 1] = e end
  for k = 0, 3 do o[#o + 1] = { "PartLegs", 0.6, k } end
  return o
end

-- one piece of debris at world (x, y, z), its +Y along `U`, pushed at v (world)
local SPHERES = false   -- the variant being dropped: each part's box made a sphere inside it
local TAGGED = false    -- the variant's parts carry CRAFT_TAG: debris_pack's own fall tick handles them
local function drop(name, list, x, y, z, U, v, out)
  local rx = unit(cross(U, { x = 0, y = 0, z = 1 }))
  local rz = cross(rx, U)
  local total, landed = #list, 0
  spawn("DebrisRoot", vec3(x, y, z), function(root)
    root.name = name
    out[#out + 1] = root
    for _, e in ipairs(list) do
      local h = e[2]
      local ox, oz = 0, 0
      if e[3] then local a = e[3] * math.pi / 2; ox, oz = math.cos(a) * 0.9, math.sin(a) * 0.9 end
      local px = x + U.x * h + rx.x * ox + rz.x * oz
      local py = y + U.y * h + rx.y * ox + rz.y * oz
      local pz = z + U.z * h + rx.z * ox + rz.z * oz
      spawn(e[1], vec3(px, py, pz), function(part)
        -- stand it on U (the part's +Y), as a dropped stage hangs
        if part.setUp then part:setUp(vec3(U.x, U.y, U.z)) end
        if TAGGED and part.addTag then part:addTag("craftpart") end
        landed = landed + 1
        if landed == total then
          if SPHERES then
            for _, c in ipairs(root:children()) do
              local rb = c.getcomponent and c:getcomponent("RigidBody")
              if rb and rb.shape == 2 then
                rb.radius = math.min(rb.half_x or 0.5, rb.half_y or 0.5, rb.half_z or 0.5)
                rb.shape = 0
              end
            end
          end
          assembly.rebuild(root, function(s)
            -- near the craft, as a stage just dropped is: out of the
            -- distant-craft LOD whatever the camera's distance
            if assembly.keepLive then assembly.keepLive(s, true) end
            local i = assembly.info(s)
            if i and v then assembly.impulseAt(s, vec3(v.x * i.mass, v.y * i.mass, v.z * i.mass), i.com) end
          end)
        end
      end, root)
    end
  end)
end

local function variant(name, n, list, height, push)
  local a = astro()
  local b = home()
  if not (a and b) then P("DS %s: no crew or body", name); return end
  local U = unit(sub(a, b))
  local T1 = unit(cross(U, { x = 0, y = 1, z = 0 }))
  local T2 = cross(U, T1)
  local out = {}
  for k = 1, n do
    -- 150 m out, spread round so the pieces never touch each other
    local ang = (k - 1) / math.max(1, n) * 2 * math.pi
    local off = { x = T1.x * math.cos(ang) + T2.x * math.sin(ang), y = T1.y * math.cos(ang) + T2.y * math.sin(ang), z = T1.z * math.cos(ang) + T2.z * math.sin(ang) }
    local px, py, pz = a.x + off.x * 150 + U.x * height, a.y + off.y * 150 + U.y * height, a.z + off.z * 150 + U.z * height
    local v = push and { x = -U.x * push, y = -U.y * push, z = -U.z * push } or nil
    drop(name .. "_" .. k, list, px, py, pz, U, v, out)
  end
  wait(0.5)
  sc_begin(name)
  local t0, frames, sw, st = time, 0, 0.0, 0.0
  local bod = {}
  while time - t0 < (params.secs or 6) do
    yield()
    local p = perf.parts and perf.parts() or {}
    sw, st, frames = sw + (p.physicsSweeps or 0), st + (p.physicsStatic or 0), frames + 1
    for _, e in ipairs(perf.bodies and perf.bodies(12) or {}) do bod[e.name] = (bod[e.name] or 0) + (e.ms or 0) end
  end
  sc_end(name)
  local pieces, pmax = 0.0, 0.0
  for k, ms in pairs(bod) do
    if k:sub(1, #name + 1) == name .. "_" or k == "DebrisRoot" then pieces = pieces + ms / frames; pmax = math.max(pmax, ms / frames) end
  end
  local alt = -1
  if out[1] and out[1].valid ~= false then alt = len(out[1].x - b.x, out[1].y - b.y, out[1].z - b.z) - b.radius end
  P("DS %s: %d piece(s) × %d part(s), from %.0f m, push %s: sweeps %.2f ms/frame, static %.2f, pieces' bodies %.2f ms/frame (worst piece %.2f), %d frames; first piece at %.0f m",
    name, n, #list, height, tostring(push), sw / math.max(1, frames), st / math.max(1, frames), pieces, pmax, frames, alt)
  for _, r in ipairs(out) do if r.valid ~= false then destroy(r) end end
  wait(2.0)
end

local function run_sweep()
  local dp = findScript("debris_pack")
  if dp then dp.active = false end
  wait(2)
  local H, HA, V = params.high or 1700, params.low or 350, params.vdown or 60
  variant("s_none", 0, SMALL, H, V)
  variant("s_n1_small", 1, SMALL, H, V)
  variant("s_n2_small", 2, SMALL, H, V)
  variant("s_n4_small", 4, SMALL, H, V)
  variant("s_n1_large", 1, LARGE, H, V)
  variant("s_n4_large", 4, LARGE, H, V)
  variant("s_n1_large_air", 1, LARGE, HA, V)
  variant("s_n1_legs", 1, with_legs(LARGE), H, V)
  if (params.slow or 0) > 0 then variant("s_n1_large_rest", 1, LARGE, H, nil) end
  -- the same falls with each part's box made a sphere inside it (one sweep
  -- sample a part instead of a box's nine)
  SPHERES = true
  variant("s_n1_large_sph", 1, LARGE, H, V)
  variant("s_n4_large_sph", 4, LARGE, H, V)
  variant("s_n1_legs_sph", 1, with_legs(LARGE), H, V)
  SPHERES = false
  -- debris_pack's own fall tick (spheres in the open, boxes before the
  -- ground), packing kept out of it
  if dp then
    dp.active, dp.PACK_DIST = true, 1e9
    TAGGED = true
    variant("s_n1_large_auto", 1, LARGE, H, V)
    variant("s_n4_large_auto", 4, LARGE, H, V)
    variant("s_n1_large_air_auto", 1, LARGE, HA, V)
    TAGGED = false
    P("DS fall tick: %d switch(es) to spheres, %d back to boxes", dp.fallStats.spheres, dp.fallStats.boxes)
    dp.active = false
  end
  P("DS RESULT sweep: done")
end
