-- ── soak probe (tools/perf/soakprobe.sh): does a long session get slower? ────
-- mode "soak": a scripted loop of what a player does for an hour, compressed:
--   1 the crew is put down somewhere new (a bearing that turns 137° a cycle,
--     250–570 m from the base: new flora and rock patches every time) and
--     walks `soak_walk` s, digs `soak_digs` laser bites
--   2 the panels: inventory (i), the ops board, the orbit map (m)
--   3 time warp on foot: "." to the top of what is allowed, `soak_warp` s, back
--   4 crew switch: "]" and "[" (craft and members in range)
--   5 a launch: the starter rocket from the VAB, burned `soak_fly` s, reverted
--     to the builder and walked out of the VAB (every cycle); with
--     `soak_rover` N, every Nth cycle a rover is rolled out, driven and LEFT
--     parked instead (the fleet grows the way a player's does)
-- Every `soak_every` (30) s, from update() and so between any two steps, one
-- SOAK line: the window's frame p50/p95/p99/max and mean, per-script ms/frame
-- (top 12), Lua memory (KB), nodes, live craft and their parts, the costly
-- bodies, the engine counts (props, decals, particles, effects, lights,
-- voices, draws, instances, chunks), terrain memory — and, every second
-- sample, the size of every script's GLOBAL state (getfenv on an exported
-- function: entries reachable from its globals; `local` state is not
-- reachable from outside, so the field scripts publish what matters).
-- The same window is also a perfbench scenario ("soak_wNN": RESULT lines and
-- a BENCHJSON row with the hitch culprits).
-- Segments: soakprobe.sh runs several plays on one save (slot 14): the first
-- makes it, the rest CONTINUE it, so what a save carries (fleet, comms, cuts)
-- grows across segments while each segment shows the growth inside one run.
local SK = { win = 0, next_t = nil, w0 = nil, cycles = 0, launches = 0, rovers = 0, digs = 0, walk_m = 0, warps = 0, switches = 0 }
local function sk_bearing(k)
  local u, t1, t2, R = base_frame()
  local ang = math.rad((k * 137) % 360)
  local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang),
                   z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
  return u, t, R
end
-- a dry spot `d` m out on bearing k (nil if the bearing is all sea)
local function sk_spot(k)
  local b = home()
  local cl = findScript("climate")
  for _, d in ipairs({ 250 + 80 * (k % 5), 200, 150, 320, 100 }) do
    local u, t, R = sk_bearing(k)
    local dir = dir_at(u, t, d, R)
    local gr = ground_r(b, dir.x, dir.y, dir.z, R + 150)
    if gr then
      local p = { x = b.x + dir.x * gr, y = b.y + dir.y * gr, z = b.z + dir.z * gr }
      local wet = cl and cl.isUnderwater and cl.isUnderwater(p.x, p.y + 0.5, p.z)
      if not wet then return { dir = dir, r = gr, t = t, d = d, biome = "?", flora = 0 } end
    end
  end
  return nil
end
local function sk_put(spot)
  local a = astro()
  if not (a and spot) then return false end
  local bb = home()
  a.x, a.y, a.z = bb.x + spot.dir.x * (spot.r + 1.0), bb.y + spot.dir.y * (spot.r + 1.0), bb.z + spot.dir.z * (spot.r + 1.0)
  a.vx, a.vy, a.vz = 0, 0, 0
  return true
end
-- retire perfbench's finished scenarios that a helper re-opened (a done
-- record re-begun stays active forever and is measured every frame)
local function sk_quiet() for _, r in pairs(RECS) do if r.done then r.active = false end end end
local function sk_dig(spot, n)
  local a, tb = astro(), findScript("tool_belt")
  if not (a and tb and spot) then return end
  local inv = findScript("inventory")
  if inv and inv.gearCount and inv.gearCount("astro", "laser") < 1 then inv.addGear("astro", "laser", 1) end
  local slot = nil
  for i, s in ipairs(tb.belt()) do if s.id == "laser" then slot = i end end
  tb.sim = { pressed = { [tostring(slot or 2)] = true } }
  wait(0.4)
  local bb = home()
  for i = 1, n do
    if not (a and a.valid) then break end
    local up = unit(sub(a, bb))
    local eye = { x = a.x + up.x * 0.6, y = a.y + up.y * 0.6, z = a.z + up.z * 0.6 }
    local k = 3.5 + (i % 5) * 0.3
    local tgt = { x = a.x + spot.t.x * k - up.x * 1.6, y = a.y + spot.t.y * k - up.y * 1.6, z = a.z + spot.t.z * k - up.z * 1.6 }
    local d = sub(tgt, eye)
    tb.sim = { btn = { [0] = true }, aim = { eye.x, eye.y, eye.z, d.x, d.y, d.z } }
    wait(0.4)
    tb.sim = { btn = { [0] = false }, aim = { eye.x, eye.y, eye.z, d.x, d.y, d.z } }
    wait(0.3)
    SK.digs = SK.digs + 1
  end
  tb.sim = nil
end
local function sk_walk(secs)
  local a = astro()
  local b = home()
  local p0 = a and sub(a, b)
  local t0 = time
  while time - t0 < secs do
    if not HELD.w then key_down("w") end
    local ph = (time - t0) % 8
    if ph < 0.7 then if not HELD.d then key_down("d") end elseif HELD.d then key_up("d") end
    yield()
  end
  release_all()
  a, b = astro(), home()
  if a and p0 then local p1 = sub(a, b); SK.walk_m = SK.walk_m + len(p1.x - p0.x, p1.y - p0.y, p1.z - p0.z) end
end
local function sk_panels()
  tap("i"); wait(1.5); tap("i"); wait(0.5)
  local ob = findScript("ops_board")
  if ob and ob.toggle then pcall(ob.toggle); wait(1.5); pcall(ob.toggle); wait(0.5) end
  tap("m"); wait(3.0); tap("m"); wait(1.0)
  local om = findScript("orbit_map")
  if om and om.isOpen and om.isOpen() and om.toggle then om.toggle() end
end
local function sk_warp(secs)
  for _ = 1, 6 do tap("."); wait(0.3) end
  local top = space.warp()
  wait(secs)
  for _ = 1, 8 do if space.warp() <= 1.001 then break end; tap(","); wait(0.3) end
  if space.warp() > 1.001 and space.setWarp then pcall(space.setWarp, 1) end
  SK.warps = SK.warps + 1
  return top
end
local function sk_switch()
  tap("]"); wait(1.5); tap("["); wait(1.5)
  SK.switches = SK.switches + 1
end
-- the crew back on foot at the base, whatever the last step left
local function sk_onfoot()
  local v = pilot()
  if v then
    local rr = v.recoverReady and v.recoverReady()
    if rr and v.recoverCraft then v.recoverCraft() else tap("f") end
    wait(2.5)
  end
  local bh = findScript("build_host")
  if bh and bh.state == "building" then if bh.leave then pcall(bh.leave) else tap("escape") end; wait(1.5) end
end
-- back where the crew stood at the start (the base: the VAB is only there to
-- walk into when you are near it)
local function sk_home()
  local a, b = astro(), home()
  if not (a and b and SK.home_rel) then return end
  a.x, a.y, a.z = b.x + SK.home_rel.x, b.y + SK.home_rel.y, b.z + SK.home_rel.z
  a.vx, a.vy, a.vz = 0, 0, 0
  wait(3)
end
local function sk_launch(k)
  sk_home()
  local ok, err = pcall(function()
    local bp = rocket_bp(2)
    local vc = launch_in_vab(bp, "pad", #bp)
    sk_quiet()
    if not vc then P("SOAK launch %d: no craft", k); return end
    SK.launches = SK.launches + 1
    wait(1)
    tap("z"); wait(0.3); tap("space"); wait(0.5)
    if assembly.info(vc.node) and assembly.info(vc.node).anchored then vc.releaseClamps() end
    wait(params.soak_fly)
    tap("x")
    -- back to the builder (the flight's pieces cleared, the pad free for the
    -- next one), then out of the VAB on foot
    local vs = findScript("vessel_spawner")
    local okr, why = vs.revertToBuilder()
    local bh = wait_for(function() local b = findScript("build_host"); return b and b.state == "building" and b end, 30, "the builder after the revert")
    sk_quiet()
    P("SOAK launch %d: reverted to the builder %s %s, builder %s", k, tostring(okr), tostring(why), tostring(bh ~= nil))
    if bh then
      if bh.leave then pcall(bh.leave) else tap("escape") end
      wait(1.0)
      wait_for(function() local b = findScript("build_host"); return not (b and b.state == "building") end, 20, "leaving the builder")
    end
    sk_onfoot()
  end)
  if not ok then P("SOAK launch %d error %s", k, tostring(err)); release_all(); sk_onfoot() end
end
local function sk_rover(k)
  sk_home()
  local ok, err = pcall(function()
    local vc = launch_in_vab(ROVER, "runway", 6)
    sk_quiet()
    if not vc then P("SOAK rover %d: no craft", k); return end
    vc.releaseClamps(); wait(1)
    key_down("w"); wait(8); release_all()
    wait(2)
    tap("f"); wait(2)        -- left where it stopped: the fleet grows
    SK.rovers = SK.rovers + 1
  end)
  if not ok then P("SOAK rover %d error %s", k, tostring(err)); release_all(); sk_onfoot() end
end

-- ── the sample ──────────────────────────────────────────────────────────────
local function sk_envsize(kind)
  local h = findScript(kind, { quiet = true })
  if not h then return nil end
  local f = h.update or h.start or h.fixedUpdate or h.lateUpdate
  if type(f) ~= "function" or not getfenv then return nil end
  local ok, env = pcall(getfenv, f)
  if not ok or type(env) ~= "table" then return nil end
  local seen, total, per = {}, 0, {}
  local budget = 400000
  local function walk(t)
    if seen[t] then return 0 end
    seen[t] = true
    if rawget(t, "__id") ~= nil then return 1 end   -- a node / component handle
    local n = 0
    for _, v in next, t do
      n = n + 1
      budget = budget - 1
      if budget < 0 then return n end
      if type(v) == "table" then n = n + walk(v) end
    end
    return n
  end
  for k, v in next, env do
    if type(v) == "table" and k ~= "params" and k ~= "defaults" then
      local n = walk(v)
      total = total + n
      per[#per + 1] = { tostring(k), n }
    end
  end
  table.sort(per, function(a, b) return a[2] > b[2] end)
  return total, per
end
local SK_SIZES = {}   -- kind → first total seen
local function sk_sample()
  local name = string.format("soak_w%02d", SK.win)
  local r = RECS[name]
  local st = r and stats(r.dts) or { p50 = 0, p95 = 0, p99 = 0, max = 0, mean = 0, n = 0 }
  local scr = r and topk(r.s, 14, math.max(#r.dts, 1)) or {}
  local bm = {}
  if r then for k, v in pairs(r.b) do bm[k] = v / math.max(#r.dts, 1) end end
  sc_end(name)
  local c = perf.counts() or {}
  local nv, parts = 0, 0
  for _, v in ipairs(findScripts("vessel_controller")) do
    local i = v.node and v.node.valid and assembly.info(v.node)
    if i then nv = nv + 1; parts = parts + #(i.parts or {}) end
  end
  local bod = perf.bodies and perf.bodies(400) or {}
  local ts = terrain.stats and terrain.stats() or {}
  local kb = collectgarbage and collectgarbage("count") or -1
  local ff, mf = findScript("flora_field", { quiet = true }), findScript("mineral_field", { quiet = true })
  P("SOAK w%02d t=%.0f s game %.0f: frame p50 %.1f p95 %.1f p99 %.1f max %.0f mean %.2f (%d frames) | lua %.0f KB | nodes %s craft %d parts %d bodiesTimed %d | props %s decals %s particles %s effects %s lights %s voices %s draws %s inst %s chunks %s | terrain %.0f MB | flora patches %s sources %s, minerals %s",
    SK.win, W() - SK.w0, time, st.p50, st.p95, st.p99, st.max, st.mean, st.n, kb, tostring(c.nodes), nv, parts, #bod,
    tostring(c.props), tostring(c.decals), tostring(c.particles), tostring(c.effects), tostring(c.lights), tostring(c.voices),
    tostring(c.draws), tostring(c.instances), tostring(c.chunks), (ts.total or 0) / 1048576,
    tostring(ff and ff.patchCount), tostring(ff and ff.sources), tostring(mf and mf.sources))
  local function mb(k) return (ts[k] or 0) / 1048576 end
  P("SOAK w%02d terrain: total %.0f MB field %.0f standIns %.0f meshesGpu %.0f meshesCpu %.0f collision %.0f shadow %.0f undo %.0f tables %.0f | dataChunks %s standInChunks %s terrains %s budget %s",
    SK.win, mb("total"), mb("field"), mb("standIns"), mb("meshesGpu"), mb("meshesCpu"), mb("collision"), mb("shadow"), mb("undo"), mb("tables"),
    tostring(ts.dataChunks), tostring(ts.standInChunks), tostring(ts.terrains), tostring(ts.budget))
  P("SOAK w%02d scripts: %s", SK.win, fmtk(scr))
  P("SOAK w%02d buckets: %s", SK.win, fmtk(topk(bm, 9)))
  P("SOAK w%02d actions: cycles %d launches %d rovers %d digs %d walked %.0f m warps %d switches %d",
    SK.win, SK.cycles, SK.launches, SK.rovers, SK.digs, SK.walk_m, SK.warps, SK.switches)
  if SK.win % 2 == 0 then
    local w1 = W()
    local rows = {}
    for _, s in ipairs(perf.scripts() or {}) do
      local tot, per = sk_envsize(s.name)
      if tot then
        SK_SIZES[s.name] = SK_SIZES[s.name] or tot
        rows[#rows + 1] = { s.name, tot, per }
      end
    end
    table.sort(rows, function(a, b) return a[2] > b[2] end)
    local o = {}
    for i = 1, math.min(14, #rows) do
      local e = rows[i]
      local top = {}
      for j = 1, math.min(2, #e[3]) do top[#top + 1] = e[3][j][1] .. "=" .. e[3][j][2] end
      o[#o + 1] = string.format("%s %d (%+d; %s)", e[1], e[2], e[2] - SK_SIZES[e[1]], table.concat(top, " "))
    end
    P("SOAK w%02d globals (entries, since first): %s [%.0f ms]", SK.win, table.concat(o, ", "), (W() - w1) * 1000)
  end
  print("SOAKJSON " .. json({ win = SK.win, t = W() - SK.w0, game = time, p50 = st.p50, p95 = st.p95, p99 = st.p99, max = st.max, mean = st.mean,
    frames = st.n, lua_kb = kb, nodes = c.nodes or 0, craft = nv, parts = parts, bodies = #bod, props = c.props or 0, decals = c.decals or 0,
    particles = c.particles or 0, effects = c.effects or 0, draws = c.draws or 0, terrain_mb = (ts.total or 0) / 1048576, chunks = c.chunks or 0, scripts = scr,
    buckets = topk(bm, 12), cycles = SK.cycles, launches = SK.launches, rovers = SK.rovers, digs = SK.digs }))
  SK.win = SK.win + 1
  sc_begin(string.format("soak_w%02d", SK.win))
end
-- called from update() every frame (outside the coroutine)
function soak_tick()
  if not SK.next_t then return end
  if W() >= SK.next_t then
    SK.next_t = SK.next_t + params.soak_every
    sk_sample()
  end
end

local function run_soak()
  local secs = params.soak_secs
  wait_ready(120)
  sk_quiet()
  SK.w0 = W()
  do local a, b = astro(), home(); if a and b then SK.home_rel = sub(a, b) end end
  SK.next_t = W() + params.soak_every
  sc_begin("soak_w00")
  local seg = math.floor(params.soak_seg or 0)
  P("SOAK start: segment %d, %.0f s, a sample every %.0f s; lua %.0f KB", seg, secs, params.soak_every, collectgarbage and collectgarbage("count") or -1)
  local k = seg * 7
  while W() - SK.w0 < secs do
    k = k + 1
    SK.cycles = SK.cycles + 1
    local spot = sk_spot(k)
    if spot and sk_put(spot) then
      wait(3)
      sk_walk(params.soak_walk)
      sk_dig(spot, params.soak_digs)
    end
    if W() - SK.w0 > secs then break end
    sk_panels()
    sk_warp(params.soak_warp)
    sk_switch()
    sk_onfoot()
    if W() - SK.w0 > secs then break end
    if params.soak_rover > 0 and k % math.floor(params.soak_rover) == 0 then sk_rover(k) else sk_launch(k) end
    sk_quiet()
  end
  sk_sample()
  SK.next_t = nil
  P("SOAK end: %d cycles", SK.cycles)
end
