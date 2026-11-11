-- FRAMEMON — frame time per scenario act, map open or shut, and what the
-- slow frames spent (perfmap 2026-11-11, Ty: "constant CPU spikes … especially
-- when I open the map" in Dust Season's mast act).
-- Spliced into scnprobe.sh's perfbench by EXTRA_LUA=tools/perf/framemon.lua.
-- Every frame the engine kept (perf.frames, no frame missed) is filed under
-- "<step>|map|wN" (the scenario's open step, the map open or shut, the warp).
-- Lines:
--   FM SLOW <label> <ms>: buckets … · scripts … · callbacks … · lines …
--       every frame over FM_SLOW ms (default 33), its costliest parts
--   FM ACT <label> n … mean … p95 … p99 … max … >33 … · scripts mean/max
--       per label at the end (MON_total), and the scripts' share per label
-- Params (BENCH_STRS): ("fm_map", "1") toggles the map every 12 s in the steps
-- named by fm_steps (comma list, default "home"); ("fm_warp1", "1") holds warp
-- 1 for the first fm_w1 s (default 40) of those steps; ("fm_sample", "1") the
-- script sampler on (slower, names lines).
local FM = { last = 0, acts = {}, order = {}, slow = 0, mapT = nil, stepT = {}, sr = nil }
local FM_SLOW = 33
local function fm_steps()
  local s = {}
  for w in tostring(params.fm_steps or "home"):gmatch("[^,]+") do s[w] = true end
  return s
end
local FM_STEPS = nil
-- THE MAP CAMERA SEQUENCE (("fm_cam", "1") in a scenario's fm_steps, or the
-- career probe's mapcam mode, tools/perf/mapcamprobe.sh): the map opened and
-- every camera mode held in turn, on yourself and on the home world, with a
-- drag where the mode has one; a picture of each (user://scnshots/map_*.png)
-- and its frames filed under "mc|<name>". MC_step() is non-blocking.
MC = { i = 0, t0 = nil, cur = nil, done = false, shot = nil }
local MC_SEQ = {
  { "free_self", "free", "self", 2.5 },
  { "free_world", "free", "world", 2.5 },
  { "horizon_world", "horizon", "world", 3.0 },
  { "horizon_world_turned", "horizon", "world", 2.5, drag = { 5, 1.5 } },
  { "horizon_world_walked", "horizon", "world", 2.0, drag = { 6, 3 }, pan = true },
  { "ball_world", "ball", "world", 2.5 },
  { "ball_world_spun", "ball", "world", 2.5, drag = { 14, 6 }, dragSecs = 0.8 },
  { "follow_self", "follow", "self", 3.0 },
  { "horizon_self", "horizon", "self", 3.0 },
  { "free_back", "free", "self", 2.0 },
}
function MC_step()
  if MC.done then return end
  local om = findScript("orbit_map", { quiet = true })
  if not (om and om.toggle and om.focusBody) then return end
  local now = W()
  local e = MC_SEQ[MC.i]
  if MC.waiting then
    if now - MC.waiting < 6 then return end   -- (the picture first, then the next mode)
    MC.waiting = nil
  end
  if e and now - MC.t0 >= e[4] and not MC.shot then
    -- the picture of the one ending (the next mode waits for it)
    local nm = "map_" .. e[1]
    local lab = tostring(om.camMode and select(2, om.camMode()))
    MC.shot, MC.waiting = nm, now
    pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes, why)
      if bytes then assets.writeBytes("user://scnshots/" .. nm .. ".png", bytes); P("MC SHOT %s (%s)", nm, lab) else P("MC SHOT %s failed %s", nm, tostring(why)) end
      MC.waiting = nil
    end)
    return
  end
  if not e or MC.shot then
    MC.shot = nil
    MC.i = MC.i + 1
    e = MC_SEQ[MC.i]
    if not e then
      MC.done, MC.cur = true, nil
      if om.isOpen() then om.toggle() end
      if om.setCamMode then om.setCamMode("free") end
      P("MC DONE")
      return
    end
    MC.t0 = now
    if not om.isOpen() then om.toggle() end
    if e[3] == "world" then
      local a = find("Astronaut")
      local home = a and space.dominant(a.x, a.y, a.z)
      if home and (MC.focus ~= "world") then om.focusBody(home) end
    elseif MC.focus ~= "self" then
      om.toggle(); om.toggle()   -- (re-opens on yourself)
    end
    MC.focus = e[3]
    om.setCamMode(e[2])
    MC.cur = e[1]
    P("MC %s: mode %s on %s", e[1], e[2], e[3])
  end
  if e and e.drag and om.CAMM and now - MC.t0 > 0.8 and now - MC.t0 < 0.8 + (e.dragSecs or 1.4) then
    om.CAMM.drag(e.drag[1], e.drag[2], e.pan == true, 1 / 60)
  end
end
local function fm_label()
  local sr = FM.sr
  if not (sr and sr.valid ~= false and sr.state) then FM.sr = findScript("scenario_run", { quiet = true }); sr = FM.sr end
  local st = sr and sr.state and sr.state() or {}
  local om = findScript("orbit_map", { quiet = true })
  local open = om and om.isOpen and om.isOpen() or false
  local w = space.warpRate and space.warpRate() or (space.warp and space.warp()) or 1
  if MC.cur then return "mc|" .. MC.cur, st, om, open end
  -- (staging, the curtain, a briefing: not play)
  local gm = findScript("game_manager", { quiet = true })
  if st.phase ~= "running" or (gm and (gm.curtain or gm.loading)) then return "load|-|-", st, om, open end
  return string.format("%s|%s|w%s", tostring(st.cutscene and "cut" or st.stepId or st.phase or "-"), open and "map" or "-", tostring(math.floor((tonumber(w) or 1) + 0.5))),
    st, om, open
end
local function top(t, n, min)
  local a = {}
  for k, v in pairs(t) do if v >= (min or 0) then a[#a + 1] = { k, v } end end
  table.sort(a, function(x, y) return x[2] > y[2] end)
  local o = {}
  for i = 1, math.min(n, #a) do o[#o + 1] = string.format("%s %.1f", a[i][1], a[i][2]) end
  return table.concat(o, ", ")
end
-- (perfbench's measure() reads perf.hitches() first and each read empties it:
-- the list it got is kept here too)
FM.hq = {}
do
  local orig = perf.hitches
  pcall(function() perf.hitches = function() local h = orig() or {}; for _, e in ipairs(h) do FM.hq[#FM.hq + 1] = e end; return h end end)
end
function MON_tick()
  if not perf.enabled() then return end
  if #FM.hq > 0 then
    for _, h in ipairs(FM.hq) do
      if (h.ms or 0) > 100 and FM.slow < 400 then
        local as = {}
        for i, a in ipairs(h.assets or {}) do if i <= 6 then as[#as + 1] = string.format("%s %s %.0f", tostring(a.path), tostring(a.part), a.ms or 0) end end
        P("FM HITCH %.0f ms top %s · assets %s", h.ms or 0, tostring(h.top), table.concat(as, " | "))
      end
    end
    FM.hq = {}
  end
  if not FM_STEPS then FM_STEPS = fm_steps(); FM_SLOW = tonumber(params.fm_slow or 33) or 33 end
  if tostring(params.fm_sample or "") == "1" and not FM.sampling and perf.sampleScripts then perf.sampleScripts(true); FM.sampling = true end
  local label, st, om, open = fm_label()
  -- the act's driver: the map toggled, warp 1 held
  local sid = st.stepId
  if sid and FM_STEPS[sid] and not st.cutscene then
    FM.stepT[sid] = FM.stepT[sid] or W()
    local age = W() - FM.stepT[sid]
    if tostring(params.fm_warp1 or "") == "1" and age < (tonumber(params.fm_w1 or 40) or 40) then
      if space.warp then space.warp(1) end
    elseif tostring(params.fm_warp1 or "") == "1" and not FM["rewarp_" .. sid] then
      -- (the window over: the solver's warp back, as it had asked)
      FM["rewarp_" .. sid] = true
      if space.warp then space.warp(tonumber(params.fm_rewarp or 50) or 50) end
    end
    if tostring(params.fm_cam or "") == "1" and not MC.done and age > (tonumber(params.fm_camat or 5) or 5) then
      if space.warp then space.warp(1) end
      MC_step()
      if MC.done and space.warp then space.warp(tonumber(params.fm_rewarp or 50) or 50) end
    elseif tostring(params.fm_map or "") == "1" and om and om.toggle and (MC.done or tostring(params.fm_cam or "") ~= "1") then
      local want = math.floor(age / 12) % 2 == 1
      if want ~= open then om.toggle() end
    end
  elseif open and tostring(params.fm_map or "") == "1" and om and om.toggle and not (sid and FM_STEPS[sid]) and FM.stepT[next(FM.stepT) or ""] then
    om.toggle()
  end
  -- the Lua heap every 5 s (a 1.4 s frame in one script's hook, its time
  -- spread over allocating lines, reads as a collector pause)
  if W() - (FM.gct or -99) > 5 then
    FM.gct = W()
    local kb = (gcinfo and gcinfo()) or (collectgarbage and collectgarbage("count")) or -1
    P("FM HEAP %.0f MB (%s)", kb / 1024, label)
  end
  -- (structures.version moves on every part-state write: how often, per act)
  local STs = findScript("structures", { quiet = true })
  local sv = STs and STs.version
  if sv and FM.sv and sv ~= FM.sv then
    local a0 = FM.acts[label]
    if a0 then a0.svn = (a0.svn or 0) + 1 end
  end
  FM.sv = sv
  for _, f in ipairs(perf.frames(4) or {}) do
    if f.frame and f.frame > FM.last then
      FM.last = f.frame
      local a = FM.acts[label]
      if not a then a = { ms = {}, s = {}, smax = {}, b = {}, p = {}, s5 = {} }; FM.acts[label] = a; FM.order[#FM.order + 1] = label end
      a.ms[#a.ms + 1] = f.ms
      local sc = 0
      for _, e in ipairs(f.scripts or {}) do
        a.s[e.name] = (a.s[e.name] or 0) + (e.ms or 0)
        if (e.ms or 0) > (a.smax[e.name] or 0) then a.smax[e.name] = e.ms end
        if (e.ms or 0) > 5 then a.s5[e.name] = (a.s5[e.name] or 0) + 1 end
        sc = sc + (e.ms or 0)
      end
      for k, v in pairs(f.buckets or {}) do a.b[k] = (a.b[k] or 0) + v end
      for k, v in pairs(f.parts or {}) do a.p[k] = (a.p[k] or 0) + v end
      a.ssum = (a.ssum or 0) + sc
      -- a script over 6 ms in a frame of play: which lines
      if label:sub(1, 4) ~= "load" and (FM.spk or 0) < 300 then
        for _, e in ipairs(f.scripts or {}) do
          if (e.ms or 0) > 6 and e.name ~= "perfbench" then
            FM.spk = (FM.spk or 0) + 1
            local ln = {}
            for _, q in ipairs(f.samples or {}) do if q.script == e.name then ln[string.format("%s:%s", q.fn or "?", tostring(q.line))] = q.ms or 0 end end
            local cl = {}
            for _, q in ipairs(f.calls or {}) do if q.script == e.name then cl[tostring(q.call)] = q.ms or 0 end end
            P("FM SPIKE %s %s %.1f ms (frame %.1f) · lines %s · calls %s", label, e.name, e.ms, f.ms, top(ln, 5, 0.2), top(cl, 3, 0.2))
          end
        end
      end
      if f.ms > FM_SLOW and FM.slow < 400 then
        FM.slow = FM.slow + 1
        local sp = {}
        for _, e in ipairs(f.scripts or {}) do sp[e.name] = e.ms end
        local cl = {}
        for _, e in ipairs(f.calls or {}) do cl[tostring(e.script) .. "." .. tostring(e.call)] = (e.ms or 0) end
        local ln = {}
        for _, e in ipairs(f.samples or {}) do ln[string.format("%s:%s:%s", e.script or "?", e.fn or "?", tostring(e.line))] = e.ms or 0 end
        P("FM SLOW %s %.1f ms (ticks %s): buckets %s · parts %s · scripts %s · calls %s · lines %s", label, f.ms, tostring(f.ticks),
          top(f.buckets or {}, 5, 0.5), top(f.parts or {}, 6, 0.5), top(sp, 6, 0.3), top(cl, 4, 0.3), top(ln, 6, 0.2))
      end
    end
  end
end
function MON_total()
  for _, label in ipairs(FM.order) do
    local a = FM.acts[label]
    local t = {}
    local sum, n33 = 0, 0
    for i, v in ipairs(a.ms) do t[i] = v; sum = sum + v; if v > 33 then n33 = n33 + 1 end end
    table.sort(t)
    local n = #t
    local function q(p) return t[math.max(1, math.min(n, math.ceil(p * n)))] or 0 end
    local sm = {}
    for k, v in pairs(a.s) do sm[k] = v / n end
    local bm = {}
    for k, v in pairs(a.b) do bm[k] = v / n end
    local pm = {}
    for k, v in pairs(a.p) do pm[k] = v / n end
    P("FM ACT %s n %d mean %.1f p95 %.1f p99 %.1f max %.1f >33 %d · buckets %s · scripts mean %s · script max %s", label, n, sum / math.max(1, n), q(0.95), q(0.99),
      t[n] or 0, n33, top(bm, 6, 0.2), top(sm, 8, 0.05), top(a.smax, 6, 1.0))
    P("FM ACT3 %s scripts bucket mean %.2f ms · the scripts' own hook time %.2f ms · the rest %.2f ms · structures.version moved in %d frames", label, bm.scripts or 0, (a.ssum or 0) / n, (bm.scripts or 0) - (a.ssum or 0) / n, a.svn or 0)
    P("FM ACT2 %s parts mean %s · frames a script spent over 5 ms %s", label, top(pm, 10, 0.1), top(a.s5, 8, 1))
  end
end
