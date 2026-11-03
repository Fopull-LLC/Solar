-- ── soak probe (tools/perf/soakprobe.sh): does a long session get slower? ────
-- mode "soak": a scripted loop of what a player does for an hour, compressed:
--   1 the crew is put down somewhere new (a bearing that turns 137° a cycle,
--     250–570 m from the base: new flora and rock patches every time) and
--     walks `soak_walk` s, digs `soak_digs` laser bites
--   2 the panels: inventory (i), the ops board, the orbit map (m)
--   3 time warp on foot: "." to the top of what is allowed, `soak_warp` s, back
--   4 crew switch: "]" and "[" (craft and members in range)
--   5 a launch: the starter rocket from the VAB, burned `soak_fly` s, reverted
--     to the builder and walked out of the VAB; every `soak_rover` (2) cycles
--     the 6-part rover instead, driven `soak_drive` s and reverted the same
--     way (`soak_park` 1: LEFT parked, so the fleet grows)
--   6 a save (game_manager.saveGame), `soak_save` 1
--   7 every `soak_menu` (3) cycles: the pause menu's MAIN MENU
--     (game_manager.exitToMenu), a few seconds there, CONTINUE (the slot
--     picked, the system scene loaded) — in the same process
-- Every `soak_every` (60) s, from update() and so between any two steps, one
-- SOAK line: the window's frame p50/p95/p99/max and mean, per-script ms/frame
-- (top 14), Lua memory (KB), nodes, live craft and their parts, the costly
-- bodies, the engine counts (props, decals, particles, effects, lights,
-- voices, draws, instances, chunks), terrain memory, and a census
-- (sk_census): script instances, the node tree by root with its rigidbodies,
-- Lua memory after a full collect, the meshes and textures scripts made and
-- never freed, by maker (sk_wrap), and each script's global-state size with
-- what grew most (getfenv; Luau has no debug.getupvalue, so `local` tables
-- are out of reach).
-- The same window is also a perfbench scenario ("soak_wNN": RESULT lines and
-- a BENCHJSON row with the hitch culprits).
-- Segments: soakprobe.sh runs several plays on one save (slot 14): the first
-- makes it, the rest CONTINUE it, so what a save carries (fleet, comms, cuts)
-- grows across segments while each segment shows the growth inside one run.
local SK = { win = 0, next_t = nil, w0 = nil, cycles = 0, launches = 0, rovers = 0, digs = 0, walk_m = 0, warps = 0, switches = 0, saves = 0, menus = 0 }
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
    key_down("w")
    local t0 = time
    while time - t0 < params.soak_drive do
      local ph = (time - t0) % 6
      if ph > 3 and ph < 4 then if not HELD.a then key_down("a") end elseif HELD.a then key_up("a") end
      yield()
    end
    release_all()
    wait(2)
    SK.rovers = SK.rovers + 1
    if (params.soak_park or 0) > 0 then
      tap("f"); wait(2)        -- left where it stopped: the fleet grows
    else
      -- back to the builder (the drive cleared) and out of the VAB on foot
      local okr, why = findScript("vessel_spawner").revertToBuilder()
      local bh = wait_for(function() local b = findScript("build_host"); return b and b.state == "building" and b end, 30, "the builder after the rover")
      sk_quiet()
      P("SOAK rover %d: reverted %s %s", k, tostring(okr), tostring(why))
      if bh then
        if bh.leave then pcall(bh.leave) else tap("escape") end
        wait(1.0)
        wait_for(function() local b = findScript("build_host"); return not (b and b.state == "building") end, 20, "leaving the builder")
      end
      sk_onfoot()
    end
  end)
  if not ok then P("SOAK rover %d error %s", k, tostring(err)); release_all(); sk_onfoot() end
end

-- ── save, the menu and back ─────────────────────────────────────────────────
local function sk_save()
  local gm = findScript("game_manager")
  local w1 = W()
  if gm and gm.saveGame then pcall(gm.saveGame) end
  SK.saves = SK.saves + 1
  P("SOAK save %d: %.0f ms", SK.saves, (W() - w1) * 1000)
end
local sk_census   -- below
-- the pause menu's MAIN MENU (game_manager.exitToMenu: the checkpoint, the
-- flush, the menu scene), a few seconds there, then CONTINUE as menu_slot does
local function sk_menu()
  local gm = findScript("game_manager")
  if not (gm and gm.exitToMenu) then return end
  local s = save.slot()
  local w1 = W()
  local ok, err = pcall(gm.exitToMenu)
  local at = wait_for(function() return tostring(scene.current() or ""):match("menu") end, 60, "the menu")
  wait(4)
  if sk_census then sk_census("menu") end
  save.slot(s)
  scene.load("system")
  yield()
  wait_for(function() local g = findScript("game_manager"); return g and not g.loading and not g.curtain end, 300, "the reveal after the menu")
  wait_ready(120)
  clear_weather()
  SK.menus = SK.menus + 1
  P("SOAK menu %d: %s %s, at the menu %s, back in %.1f s", SK.menus, tostring(ok), tostring(err), tostring(at ~= nil), W() - w1)
end

-- ── what the engine holds that a script made: meshes and textures ───────────
-- mesh.build / assets.textureFromPixels|Bytes / camera.captureTexture are kept
-- until mesh.free / assets.release or Stop (lua-api.md); the engine has no
-- count of them, so the probe wraps the shared library tables and keeps the
-- live names, each with the script that made it.
local LIVE = { mesh = {}, tex = {}, made = { mesh = 0, tex = 0 }, freed = { mesh = 0, tex = 0 }, shared = "?" }
local TB_SHOWN = false
local function caller()
  -- the first script on the stack that is not this probe (Luau's traceback
  -- names each frame's chunk)
  local tb = debug and debug.traceback and debug.traceback("", 2) or ""
  if not TB_SHOWN then TB_SHOWN = true; print("SOAK traceback sample: " .. tb:gsub("\n", " | ")) end
  for line in tb:gmatch("[^\n]+") do
    local nm = line:match("([%w_]+)%.lua") or line:match('%[string "([%w_/%.]+)"%]')
    if nm and not nm:match("perfbench") then return (nm:match("([%w_]+)$") or nm) end
  end
  return "?"
end
local function sk_wrap()
  if LIVE.wrapped then return end
  LIVE.wrapped = true
  if mesh and mesh.build then
    local b, f = mesh.build, mesh.free
    mesh.build = function(...) local n, e = b(...); local src = caller(); if type(n) == "string" then LIVE.mesh[n] = src; LIVE.made.mesh = LIVE.made.mesh + 1 end; return n, e end
    if f then mesh.free = function(n, ...) if LIVE.mesh[n] then LIVE.mesh[n] = nil; LIVE.freed.mesh = LIVE.freed.mesh + 1 end; return f(n, ...) end end
  end
  if assets then
    for _, fn in ipairs({ "textureFromPixels", "textureFromBytes" }) do
      local o = assets[fn]
      if o then assets[fn] = function(...) local n, e = o(...); if type(n) == "string" then LIVE.tex[n] = caller(); LIVE.made.tex = LIVE.made.tex + 1 end; return n, e end end
    end
    local r = assets.release
    if r then assets.release = function(n, ...) if LIVE.tex[n] then LIVE.tex[n] = nil; LIVE.freed.tex = LIVE.freed.tex + 1 end; return r(n, ...) end end
  end
  if camera and camera.captureTexture then
    local o = camera.captureTexture
    camera.captureTexture = function(...)
      local a = { ... }
      local src = caller()
      local cb = a[#a]
      if type(cb) == "function" then
        a[#a] = function(tex, err, ...) if type(tex) == "string" then LIVE.tex[tex] = src; LIVE.made.tex = LIVE.made.tex + 1 end; return cb(tex, err, ...) end
      end
      return o((unpack or table.unpack)(a))
    end
  end
  -- shared? another script's environment sees the same table
  local h = findScript("vessel_spawner", { quiet = true }) or findScript("game_manager", { quiet = true })
  local f = h and (h.update or h.start)
  local ok, env = pcall(getfenv or function() return nil end, f)
  LIVE.shared = tostring(ok and type(env) == "table" and env.mesh == mesh and env.assets == assets)
end
local function live_line()
  local function by(t)
    local m, n = {}, 0
    for _, src in pairs(t) do m[src] = (m[src] or 0) + 1; n = n + 1 end
    local l = {}
    for k, v in pairs(m) do l[#l + 1] = { k, v } end
    table.sort(l, function(a, b) return a[2] > b[2] end)
    local o = {}
    for i = 1, math.min(6, #l) do o[#o + 1] = l[i][1] .. " " .. l[i][2] end
    return n, table.concat(o, ", ")
  end
  local nm, sm = by(LIVE.mesh)
  local nt, st = by(LIVE.tex)
  return nm, nt, string.format("meshes live %d (made %d freed %d: %s) | textures live %d (made %d freed %d: %s) | shared %s",
    nm, LIVE.made.mesh, LIVE.freed.mesh, sm, nt, LIVE.made.tex, LIVE.freed.tex, st, LIVE.shared)
end

-- ── the census: script instances, the node tree, bodies, module state ───────
local SK_UPV = {}   -- kind → first total
local function sk_upvalues(h)
  -- entries reachable from a script's module locals (the upvalues of its
  -- functions) and globals: `local cache = {}` at the top of a script is an
  -- upvalue of every function that uses it
  -- (Luau has no debug.getupvalue: there only the globals are reachable)
  if not getfenv then return nil end
  local upv = debug and debug.getupvalue
  local f = h.update or h.start or h.fixedUpdate or h.lateUpdate
  if type(f) ~= "function" then return nil end
  local ok, env = pcall(getfenv, f)
  if not ok or type(env) ~= "table" then return nil end
  local seen, budget = {}, 300000
  seen[_G or {}] = true
  for _, lib in ipairs({ math, string, table, os, coroutine }) do if lib then seen[lib] = true end end
  local function walk(t)
    if seen[t] then return 0 end
    seen[t] = true
    if rawget(t, "__id") ~= nil then return 1 end
    local n = 0
    for _, v in next, t do
      n = n + 1
      budget = budget - 1
      if budget < 0 then return n end
      if type(v) == "table" then n = n + walk(v) end
    end
    return n
  end
  local per, total = {}, 0
  local fseen = {}
  local function fn_upv(fn, depth)
    if fseen[fn] or depth > 3 then return end
    fseen[fn] = true
    for i = 1, 200 do
      local okn, name, v = pcall(debug.getupvalue, fn, i)
      if not okn or name == nil then break end
      if type(v) == "table" and v ~= env and not seen[v] then
        local n = walk(v); total = total + n
        per[#per + 1] = { tostring(name), n }
      elseif type(v) == "function" then fn_upv(v, depth + 1) end
    end
  end
  for k, v in next, env do
    if type(v) == "function" then if upv then fn_upv(v, 0) end
    elseif type(v) == "table" and k ~= "params" and k ~= "defaults" and not seen[v] then
      local n = walk(v); total = total + n; per[#per + 1] = { tostring(k), n }
    end
  end
  table.sort(per, function(a, b) return a[2] > b[2] end)
  return total, per
end
local SK_TOPN = {}   -- per-variable first sizes, "kind.var" → n
local function sk_census_impl(tag)
  local w1 = W()
  -- script instances
  local kinds, inst = {}, 0
  local roots, rootl = {}, {}
  local function addroot(n)
    local r, guard = n, 0
    while r and r.valid and guard < 64 do
      local p = r:getParent()
      if not (p and p.valid) then break end
      r = p; guard = guard + 1
    end
    if r and r.valid and not roots[r.id] then roots[r.id] = r; rootl[#rootl + 1] = r end
  end
  local names = {}
  for _, s in ipairs(perf.scripts() or {}) do names[#names + 1] = s.name end
  for _, nm in ipairs(names) do
    local l = findScripts(nm) or {}
    kinds[nm] = #l; inst = inst + #l
    for _, h in ipairs(l) do if h.node and h.node.valid then addroot(h.node) end end
  end
  local a = find("Astronaut"); if a then addroot(a) end
  -- the tree under every root found, by root name
  local byroot, nodes, bodies = {}, 0, 0
  local function walk(n, key, depth)
    nodes = nodes + 1
    local e = byroot[key]; e.n = e.n + 1
    local rb = n:getComponent("RigidBody")
    if rb then bodies = bodies + 1; e.b = e.b + 1 end
    if depth < 40 then for _, c in ipairs(n:children() or {}) do walk(c, key, depth + 1) end end
  end
  for _, r in ipairs(rootl) do
    local key = tostring(r.name or "?"):gsub("%d+$", "#")
    byroot[key] = byroot[key] or { n = 0, b = 0, roots = 0 }
    byroot[key].roots = byroot[key].roots + 1
    walk(r, key, 0)
  end
  local bl = {}
  for k, v in pairs(byroot) do bl[#bl + 1] = { k, v } end
  table.sort(bl, function(x, y) return x[2].n > y[2].n end)
  local o = {}
  for i = 1, math.min(14, #bl) do o[#o + 1] = string.format("%s%s %d/%db", bl[i][1], bl[i][2].roots > 1 and ("×" .. bl[i][2].roots) or "", bl[i][2].n, bl[i][2].b) end
  local c = perf.counts() or {}
  local tw = W()
  -- module state of every script kind (the first instance)
  local rows = {}
  for _, nm in ipairs(names) do
    local h = findScript(nm, { quiet = true })
    local tot, per
    if h then tot, per = sk_upvalues(h) end
    if tot then
      SK_UPV[nm] = SK_UPV[nm] or tot
      rows[#rows + 1] = { nm, tot, per }
    end
  end
  table.sort(rows, function(x, y) return (x[2] - SK_UPV[x[1]]) > (y[2] - SK_UPV[y[1]]) end)
  local u = {}
  local grow = {}
  for i = 1, math.min(10, #rows) do
    local e = rows[i]
    local top = {}
    for j = 1, math.min(3, #e[3]) do
      local key = e[1] .. "." .. e[3][j][1]
      SK_TOPN[key] = SK_TOPN[key] or e[3][j][2]
      top[#top + 1] = string.format("%s=%d(%+d)", e[3][j][1], e[3][j][2], e[3][j][2] - SK_TOPN[key])
    end
    u[#u + 1] = string.format("%s %d (%+d; %s)", e[1], e[2], e[2] - SK_UPV[e[1]], table.concat(top, " "))
  end
  for _, e in ipairs(rows) do grow[e[1]] = e[2] end
  -- the variables that grew most, across every script
  local vg = {}
  for _, e in ipairs(rows) do
    for _, pv in ipairs(e[3]) do
      local key = e[1] .. "." .. pv[1]
      SK_TOPN[key] = SK_TOPN[key] or pv[2]
      local d = pv[2] - SK_TOPN[key]
      if d ~= 0 then vg[#vg + 1] = { key, pv[2], d } end
    end
  end
  table.sort(vg, function(x, y) return x[3] > y[3] end)
  local vo = {}
  for i = 1, math.min(14, #vg) do vo[#vo + 1] = string.format("%s=%d(%+d)", vg[i][1], vg[i][2], vg[i][3]) end
  local kb0 = collectgarbage("count")
  local wg = W()
  collectgarbage("collect")
  local kb1 = collectgarbage("count")
  local gms = (W() - wg) * 1000
  local nm, nt, ll = live_line()
  local wakes = 0
  for _, v in pairs(c.wakes or {}) do wakes = wakes + v end
  P("SOAK %s census: scripts %d instances in %d kinds | tree %d nodes (engine %s), rigidbodies %d | lua %.0f KB -> %.0f KB after a full collect (%.0f ms) | %s | mirrorRebuilds %s animators %s wakes %d decalTris %s unbatched %s lights %s effects %s terrainDropped %s [walk %.0f ms, upvalues %.0f ms]",
    tag, inst, #names, nodes, tostring(c.nodes), bodies, kb0, kb1, gms, ll, tostring(c.mirrorRebuilds), tostring(c.animators), wakes,
    tostring(c.decalTris), tostring(c.unbatched), tostring(c.lights), tostring(c.effects), tostring(c.terrainDropped), (tw - w1) * 1000, (wg - tw) * 1000)
  P("SOAK %s roots: %s", tag, table.concat(o, ", "))
  local ko = {}
  for k, v in pairs(kinds) do if v > 1 then ko[#ko + 1] = { k, v } end end
  table.sort(ko, function(x, y) return x[2] > y[2] end)
  local kk = {}
  for i = 1, math.min(12, #ko) do kk[#kk + 1] = ko[i][1] .. " " .. ko[i][2] end
  P("SOAK %s instances: %s", tag, table.concat(kk, ", "))
  P("SOAK %s module state (entries, since first): %s", tag, table.concat(u, ", "))
  P("SOAK %s state grown most: %s", tag, table.concat(vo, ", "))
  return { inst = inst, kinds = #names, tree = nodes, rigidbodies = bodies, lua_live_kb = kb1, meshes = nm, textures = nt,
           mirror = c.mirrorRebuilds or 0, animators = c.animators or 0, wakes = wakes, decal_tris = c.decalTris or 0, lights = c.lights or 0,
           voices = c.voices or 0, effects = c.effects or 0, unbatched = c.unbatched or 0, state = grow }
end
sk_census = function(tag)
  local ok, r = pcall(sk_census_impl, tag)
  if not ok then P("SOAK %s census error %s", tag, tostring(r)); return {} end
  return r
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
  P("SOAK w%02d actions: cycles %d launches %d rovers %d digs %d walked %.0f m warps %d switches %d saves %d menus %d",
    SK.win, SK.cycles, SK.launches, SK.rovers, SK.digs, SK.walk_m, SK.warps, SK.switches, SK.saves, SK.menus)
  local cs = sk_census(string.format("w%02d", SK.win))
  print("SOAKJSON " .. json({ win = SK.win, t = W() - SK.w0, game = time, p50 = st.p50, p95 = st.p95, p99 = st.p99, max = st.max, mean = st.mean,
    frames = st.n, lua_kb = kb, nodes = c.nodes or 0, craft = nv, parts = parts, bodies = #bod, props = c.props or 0, decals = c.decals or 0,
    particles = c.particles or 0, effects = c.effects or 0, draws = c.draws or 0, terrain_mb = (ts.total or 0) / 1048576, chunks = c.chunks or 0, scripts = scr,
    buckets = topk(bm, 12), cycles = SK.cycles, launches = SK.launches, rovers = SK.rovers, digs = SK.digs, saves = SK.saves, menus = SK.menus,
    inst = cs.inst, tree = cs.tree, rigidbodies = cs.rigidbodies, lua_live_kb = cs.lua_live_kb, meshes = cs.meshes, textures = cs.textures,
    mirror = cs.mirror, animators = cs.animators, wakes = cs.wakes, decal_tris = cs.decal_tris, lights = cs.lights, voices = cs.voices, state = cs.state }))
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
  sk_wrap()
  do local dk = {}; for k in pairs(debug or {}) do dk[#dk + 1] = tostring(k) end; table.sort(dk)
     P("SOAK debug library: %s; getfenv %s setfenv %s", table.concat(dk, " "), type(getfenv), type(setfenv)) end
  sk_census("start")
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
    if params.soak_save > 0 then sk_save() end
    if params.soak_menu > 0 and SK.cycles % math.floor(params.soak_menu) == 0 and W() - SK.w0 < secs - 60 then
      sk_menu(); sk_quiet()
      do local a, b = astro(), home(); if a and b and not SK.home_rel then SK.home_rel = sub(a, b) end end
    end
  end
  sk_sample()
  SK.next_t = nil
  P("SOAK end: %d cycles", SK.cycles)
end
