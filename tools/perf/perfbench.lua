-- PERFBENCH (scratch only): where Solar's frame time goes in real play.
--
-- One probe, one mode per engine run (strs "mode"):
--   base    : a) fresh save — load, reveal, first 30 s on foot;
--             b) 20 terrain-laser clicks on a meadow and 20 on rock (the real
--                tool_belt, driven through its `sim` hook);
--             f) the orbit map opened on foot
--   rocket  : c) a rocket from the pad to orbit, with throttle changes (keys);
--             f) the orbit map in orbit
--   plane   : d) the light jet: take-off roll, then low flight (~35 m up)
--   rover   : e) a 4-wheel rover driven from the runway out past 110 m
--   builder : g) the in-VAB builder at 300 / 1,000 / 3,000 parts (load, idle,
--                a part in hand), then a ~1,000-part craft launched to the pad
--
-- The player's own save (usersave=1; bench.sh USERSAVE=1 copies save/slot1.ron,
-- save/settings.ron and saves/slot1 into the scratch project, never Solar's):
--   foot      : u) stand 20 s at the spawn, then walk 40 s
--   meadow    : u) 220 m out to the grass (the grassiest spot that far), stand
--                  8 s, walk there 40 s — the turf wash / decal relay (0525)
--   digmeadow : u) 100 terrain-laser bites on that meadow
--   park      : s) a 6-wheel rover rolled out to the runway, released, brakes
--                  on: time to node.asleep, the wake reason, physics ms/frame
--                  (0527 / 0531); dump=1 prints, after 10 s braked, every
--                  tyre's joint and rigidbody, the chassis mass and g, two
--                  props by the base, and 120 ticks of planet-frame motion
--   bigpark   : s) the ~1,000-part finned spine released on the pad with NO
--                  throttle: time to sleep and physics before/after (0509 /
--                  0531); loads=1 lets it break up (the pieces' sleep, 0509)
--   gameplay  : the gameplay smoke, each step one RESULT line: an in-VAB rover
--               rollout driven 100 m; the two-stage Skipper→Anvil to orbit; the
--               starter rocket to its apex and a revert to launch (state back,
--               0 old parts); the jet's take-off; the 1,002-part rollout and
--               release, then `sleepsecs` of settling
-- (park, bigpark and gameplay run on a fresh save too.)
--
-- Every frame it reads the engine profiler (perf.*) and INVERTS its smoothed
-- means (mean = 0.9 mean' + 0.1 x, floptle-core/src/profile.rs Series::push)
-- back into exact per-frame bucket and per-script costs. Each scenario prints
-- "PB RESULT" lines and one "BENCHJSON {...}" line for bench.sh to tabulate.
defaults = { slot = 13, seed = 1911564384, quit = 1, onfoot = 30, clicks = 20, hold = 0.5, gap = 0.5,
             mapsecs = 12, flysecs = 45, drivesecs = 45, out = 110, settle = 8, sleepsecs = 20, sample = 0,
             usersave = 0, standsecs = 20, walksecs = 40, meadow_m = 220, digclicks = 100, parksecs = 45,
             burst = 0 }

local MODE = "base"
local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("PB %7.2f " .. fmt, W() - W0, ...)) end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function unit(a) local l = len(a.x, a.y, a.z); return { x = a.x / l, y = a.y / l, z = a.z / l } end
local function cross(a, b) return { x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x } end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function sub(a, b) return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z } end
local function scl(a, k) return { x = a.x * k, y = a.y * k, z = a.z * k } end
local function clamp(x, a, b) return math.max(a, math.min(b, x)) end
local D = math.rad
local function home() local n = save.get("base.body"); return n and space.body(n) end

-- ── JSON (enough for numbers, strings, arrays, objects) ─────────────────────
local function json(v)
  local t = type(v)
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    return string.format("%.3f", v):gsub("%.?0+$", "")
  elseif t == "string" then return '"' .. v:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"'
  elseif t == "boolean" then return tostring(v)
  elseif t == "table" then
    if #v > 0 or next(v) == nil then
      local o = {}
      for i = 1, #v do o[i] = json(v[i]) end
      return "[" .. table.concat(o, ",") .. "]"
    end
    local o, ks = {}, {}
    for k in pairs(v) do ks[#ks + 1] = tostring(k) end
    table.sort(ks)
    for _, k in ipairs(ks) do o[#o + 1] = json(k) .. ":" .. json(v[k]) end
    return "{" .. table.concat(o, ",") .. "}"
  end
  return "null"
end

-- ── the sampler ─────────────────────────────────────────────────────────────
local BK = nil                 -- bucket names
local prevB, prevS = {}, {}    -- last smoothed means (to invert)
local RECS, ORDER = {}, {}
local lastW = nil
local FRAME = 0
local LASTF = -1               -- the last engine frame read from perf.frames
local function new_rec(name)
  return { name = name, dts = {}, b = {}, sb = {}, s = {}, smax = {}, ssp = {}, parts = {}, pmax = {}, psp = {},
           worst = {}, cnt = {}, cmax = {}, cn = 0, gpu = 0, gn = 0, hit = { n = 0, top = {} }, notes = {},
           w0 = W(), t0 = time, active = true, nsp = 0 }
end
local function sc_begin(name)
  local r = RECS[name]
  if not r then r = new_rec(name); RECS[name] = r; ORDER[#ORDER + 1] = name; r.lp0 = LP_SNAP and LP_SNAP() else r.active = true end
  return r
end
local function sc_pause(name) if RECS[name] then RECS[name].active = false end end
local function sc_note(name, k, v) local r = RECS[name]; if r then r.notes[k] = v end end

local function stats(list)
  local t = {}
  for i, v in ipairs(list) do t[i] = v end
  table.sort(t)
  local n = #t
  if n == 0 then return { n = 0, mean = 0, p50 = 0, p95 = 0, p99 = 0, max = 0 } end
  local s = 0
  for _, v in ipairs(t) do s = s + v end
  local function q(f) return t[math.max(1, math.min(n, math.ceil(n * f)))] end
  return { n = n, mean = s / n, p50 = q(0.5), p95 = q(0.95), p99 = q(0.99), max = t[n] }
end
local function topk(map, k, div)
  local t = {}
  for name, v in pairs(map) do t[#t + 1] = { name, v / (div or 1) } end
  table.sort(t, function(a, b) return a[2] > b[2] end)
  local o = {}
  for i = 1, math.min(k, #t) do o[#o + 1] = t[i] end
  return o
end
local function fmtk(list) local o = {}; for _, e in ipairs(list) do o[#o + 1] = string.format("%s %.2f", e[1], e[2]) end; return table.concat(o, ", ") end

-- fieldChunks / fieldEdited / fieldStandIns: the terrains' voxel fields (0.117
-- rc25): chunks held at full detail, those edited since generation (dug,
-- raised, painted: kept and saved for life), and coarse stand-ins
local SUMMARY_COUNTS = { "draws", "unbatched", "nodes", "instances", "chunks", "props", "decals", "decalTris", "particles", "lights", "rays", "sweeps",
                         "fieldChunks", "fieldEdited", "fieldStandIns", "effects", "voices", "decalsRelaid" }

local function measure()
  local now = W()
  local dtw = lastW and (now - lastW) * 1000 or nil
  lastW = now
  FRAME = FRAME + 1
  if not perf.enabled() then return end
  BK = BK or perf.buckets()
  local fb, tot = {}, 0
  for _, k in ipairs(BK) do
    local m = perf.ms(k) or 0
    local p = prevB[k]
    local x = p and math.max(0, (m - 0.9 * p) * 10) or m
    prevB[k] = m
    fb[k] = x
    tot = tot + x
  end
  local fs = {}
  for _, s in ipairs(perf.scripts() or {}) do
    local p = prevS[s.name] or 0
    local x = (s.ms - 0.9 * p) * 10
    prevS[s.name] = s.ms
    if x > 0.002 then fs[s.name] = x end
  end
  local parts = (perf.parts and perf.parts()) or {}
  -- 0.117 rc16 (floptle/0514): the engine keeps every frame exactly. Its own
  -- buckets, parts, scripts, bodies and sampled lines replace the inverted
  -- means, summed over every frame since the last read (a load can pass
  -- several with no update of ours). Frame TIMES stay the wall clock between
  -- our updates, so rows compare with older engines.
  local bod, smp = nil, nil
  if perf.frames then
    local fr = perf.frames(8) or {}
    local xb, xs, xp = {}, {}, {}
    local got = false
    bod, smp = {}, {}
    for _, f in ipairs(fr) do
      if f.frame and f.frame > LASTF then
        LASTF, got = f.frame, true
        for k, v in pairs(f.buckets or {}) do xb[k] = (xb[k] or 0) + v end
        for k, v in pairs(f.parts or {}) do xp[k] = (xp[k] or 0) + v end
        for _, e in ipairs(f.scripts or {}) do xs[e.name] = (xs[e.name] or 0) + (e.ms or 0) end
        for _, e in ipairs(f.bodies or {}) do bod[e.name or "?"] = (bod[e.name or "?"] or 0) + (e.ms or 0) end
        for _, e in ipairs(f.samples or {}) do
          local k = string.format("%s:%s:%s", e.script or "?", e.fn or "?", tostring(e.line or "?"))
          smp[k] = (smp[k] or 0) + (e.ms or 0)
        end
      end
    end
    if got then
      fb, fs, parts, tot = xb, xs, xp, 0
      for _, v in pairs(fb) do tot = tot + v end
    end
  end
  local hs = perf.hitches() or {}
  local c = nil
  if FRAME % 10 == 0 then c = perf.counts() end
  local g = nil
  if FRAME % 10 == 0 then local ok, gg = pcall(perf.gpu); if ok and gg and gg.total then g = gg end end
  if not dtw then return end
  for _, name in ipairs(ORDER) do
    local r = RECS[name]
    if r.active then
      r.dts[#r.dts + 1] = dtw
      r.work = r.work or {}
      r.work[#r.work + 1] = tot - (fb.gpuWait or 0) - (fb.present or 0)
      for k, v in pairs(fb) do r.b[k] = (r.b[k] or 0) + v end
      for k, v in pairs(fs) do r.s[k] = (r.s[k] or 0) + v; if v > (r.smax[k] or 0) then r.smax[k] = v end end
      for k, v in pairs(parts) do r.parts[k] = (r.parts[k] or 0) + v; if v > (r.pmax[k] or 0) then r.pmax[k] = v end end
      if bod then r.bod = r.bod or {}; for k, v in pairs(bod) do r.bod[k] = (r.bod[k] or 0) + v end end
      if smp then r.smp = r.smp or {}; for k, v in pairs(smp) do r.smp[k] = (r.smp[k] or 0) + v end end
      if dtw > 33.3 then
        r.nsp = r.nsp + 1
        for k, v in pairs(fb) do r.sb[k] = (r.sb[k] or 0) + v end
        for k, v in pairs(fs) do r.ssp[k] = (r.ssp[k] or 0) + v end
        for k, v in pairs(parts) do r.psp[k] = (r.psp[k] or 0) + v end
        -- keep the 6 worst frames with their culprits
        local e = { ms = dtw, t = time - r.t0, b = topk(fb, 3), s = topk(fs, 3), p = topk(parts, 3) }
        r.worst[#r.worst + 1] = e
        table.sort(r.worst, function(a, b) return a.ms > b.ms end)
        if #r.worst > 6 then r.worst[7] = nil end
      end
      for _, h in ipairs(hs) do
        -- rc12+: the files a slow frame was preparing (first-use work in assets)
        if h.assets and #h.assets > 0 then
          local a = {}
          for _, x in ipairs(h.assets) do a[#a + 1] = string.format("%s %s %.0f", x.path or "?", x.part or "?", x.ms or 0) end
          P("ASSETHITCH [%s] %.0f ms at +%.1f s (assets %.0f): %s", name, h.ms or 0, time - r.t0, (h.buckets or {}).assets or 0, table.concat(a, "; "))
        end
        r.hit.n = r.hit.n + 1
        r.hit.top[h.top or "?"] = (r.hit.top[h.top or "?"] or 0) + 1
        r.hb = r.hb or {}; r.hp = r.hp or {}; r.hms = (r.hms or 0) + (h.ms or 0)
        for k, v in pairs(h.buckets or {}) do r.hb[k] = (r.hb[k] or 0) + v end
        for k, v in pairs(h.parts or {}) do r.hp[k] = (r.hp[k] or 0) + v end
        -- the engine's own record of the frame: exact, unlike the inverted means
        r.hw = r.hw or {}
        local hsx = fs
        if h.scripts then hsx = {}; for _, e in ipairs(h.scripts) do hsx[e.name] = e.ms or 0 end end
        local hbo = {}
        for _, e in ipairs(h.bodies or {}) do hbo[e.name or "?"] = e.ms or 0 end
        local hsm = {}
        for _, e in ipairs(h.samples or {}) do hsm[string.format("%s:%s:%s", e.script or "?", e.fn or "?", tostring(e.line or "?"))] = e.ms or 0 end
        r.hw[#r.hw + 1] = { ms = h.ms, t = time - r.t0, b = topk(h.buckets or {}, 3), p = topk(h.parts or {}, 3), s = topk(hsx, 3),
                            bo = topk(hbo, 2), sm = topk(hsm, 8) }
        table.sort(r.hw, function(a, b) return a.ms > b.ms end)
        if #r.hw > 6 then r.hw[7] = nil end
      end
      if c then
        r.cn = r.cn + 1
        for _, k in ipairs(SUMMARY_COUNTS) do
          local v = c[k] or 0
          r.cnt[k] = (r.cnt[k] or 0) + v
          if v > (r.cmax[k] or 0) then r.cmax[k] = v end
        end
        r.cnt.mirrorRebuilds = (r.cnt.mirrorRebuilds or 0) + (c.mirrorRebuilds or 0)
        r.cnt.rayMs = (r.cnt.rayMs or 0) + (c.rayMs or 0)
      end
      if g then
        r.gpu = r.gpu + g.total; r.gn = r.gn + 1
        r.gp = r.gp or {}
        for _, ps in ipairs(g.passes or {}) do r.gp[ps.name] = (r.gp[ps.name] or 0) + ps.ms end
      end
    end
  end
end

local function sc_end(name)
  local r = RECS[name]
  if not r or r.done then return end
  r.active, r.done = false, true
  local n = #r.dts
  local st = stats(r.dts)
  local over33, over100 = 0, 0
  for _, v in ipairs(r.dts) do if v > 33.3 then over33 = over33 + 1 end; if v > 100 then over100 = over100 + 1 end end
  local bm = {}
  for k, v in pairs(r.b) do bm[k] = v / math.max(n, 1) end
  local sbm = {}
  for k, v in pairs(r.sb) do sbm[k] = v / math.max(r.nsp, 1) end
  local scr = topk(r.s, 12, math.max(n, 1))
  local scrmax = {}
  for _, e in ipairs(scr) do scrmax[#scrmax + 1] = { e[1], r.smax[e[1]] or 0 } end
  local cm = {}
  for k, v in pairs(r.cnt) do cm[k] = v / math.max(r.cn, 1) end
  local secs = W() - r.w0
  local wk = stats(r.work or {})
  P("RESULT [%s] %.1f s, %d frames: p50 %.1f p95 %.1f p99 %.1f max %.1f mean %.1f ms | >33ms %d, >100ms %d | hitches(>=50) %d",
    name, secs, n, st.p50, st.p95, st.p99, st.max, st.mean, over33, over100, r.hit.n)
  P("RESULT [%s] engine work (frame minus gpuWait/present): p50 %.1f p95 %.1f p99 %.1f max %.1f mean %.1f", name, wk.p50, wk.p95, wk.p99, wk.max, wk.mean)
  P("RESULT [%s] buckets/frame: %s", name, fmtk(topk(bm, 15)))
  P("RESULT [%s] scripts/frame: %s", name, fmtk(scr))
  if r.nsp > 0 then
    P("RESULT [%s] in the %d frames over 33 ms: buckets %s | scripts %s | parts %s", name, r.nsp, fmtk(topk(sbm, 6)),
      fmtk(topk(r.ssp, 6, r.nsp)), fmtk(topk(r.psp, 5, r.nsp)))
  end
  for i, e in ipairs(r.hw or {}) do
    if i > 4 then break end
    P("RESULT [%s] worst hitch #%d %.0f ms at +%.1f s: %s | parts %s | scripts %s%s", name, i, e.ms, e.t, fmtk(e.b), fmtk(e.p), fmtk(e.s),
      ((e.bo and #e.bo > 0) or (e.sm and #e.sm > 0)) and string.format(" | bodies %s | lines %s", fmtk(e.bo or {}), fmtk(e.sm or {})) or "")
  end
  if r.hit.n > 0 then
    P("RESULT [%s] all %d hitches, %.0f ms total: buckets %s | parts %s", name, r.hit.n, r.hms or 0, fmtk(topk(r.hb or {}, 6)), fmtk(topk(r.hp or {}, 6)))
  end
  P("RESULT [%s] counts mean: %s; gpu %.2f ms: %s", name, fmtk(topk(cm, 12)), r.gn > 0 and r.gpu / r.gn or -1, fmtk(topk(r.gp or {}, 6, math.max(r.gn, 1))))
  if r.cn > 0 and ((r.cnt.fieldChunks or 0) > 0 or (r.cnt.fieldEdited or 0) > 0 or (r.parts.decalRelay or 0) > 0) then
    P("RESULT [%s] fields: fieldChunks %.0f (max %d) fieldEdited %.0f (max %d) fieldStandIns %.0f (max %d); decalRelay %.2f ms/frame (max %.1f)",
      name, cm.fieldChunks or 0, r.cmax.fieldChunks or 0, cm.fieldEdited or 0, r.cmax.fieldEdited or 0, cm.fieldStandIns or 0, r.cmax.fieldStandIns or 0,
      (r.parts.decalRelay or 0) / math.max(n, 1), r.pmax.decalRelay or 0)
  end
  local notes = {}
  for k, v in pairs(r.notes) do notes[k] = v end
  local lpd = (r.lp0 and LP_DELTA) and LP_DELTA(r.lp0, n) or {}
  if #lpd > 0 then P("RESULT [%s] lua functions (inclusive ms/frame): %s", name, fmtk(lpd)) end
  if r.bod and next(r.bod) then P("RESULT [%s] bodies/frame: %s", name, fmtk(topk(r.bod, 5, math.max(n, 1)))) end
  if r.smp and next(r.smp) then P("RESULT [%s] sampled lines/frame: %s", name, fmtk(topk(r.smp, 8, math.max(n, 1)))) end
  print("BENCHJSON " .. json({ mode = MODE, scenario = name, secs = secs, frames = n, p50 = st.p50, p95 = st.p95, p99 = st.p99,
    max = st.max, mean = st.mean, work = wk, over33 = over33, over100 = over100, hitches = r.hit.n, hitchTop = r.hit.top,
    buckets = bm, spikeBuckets = sbm, nSpikes = r.nsp, scripts = scr, scriptsMax = scrmax,
    spikeScripts = topk(r.ssp, 8, math.max(r.nsp, 1)), parts = topk(r.parts, 10, math.max(n, 1)),
    partsMax = topk(r.pmax, 10), worst = r.hw or {}, bodies = topk(r.bod or {}, 8, math.max(n, 1)),
    lines = topk(r.smp or {}, 12, math.max(n, 1)), worstInverted = r.worst,
    hitchMs = r.hms or 0, hitchBuckets = topk(r.hb or {}, 8), hitchParts = topk(r.hp or {}, 8), counts = cm, countsMax = r.cmax, gpu = r.gn > 0 and r.gpu / r.gn or -1,
    gpuPasses = topk(r.gp or {}, 8, math.max(r.gn, 1)), luaFns = lpd, notes = notes }))
end
local function finish_all() for _, name in ipairs(ORDER) do sc_end(name) end end

-- ── a Lua-side profiler: wrap a script's global functions with wall timers ──
-- The engine times each script as a whole (perf.scriptMs); this splits the
-- big ones by function. Inclusive times (a wrapped function calling another
-- counts both). Only GLOBAL functions can be reached, through the instance.
local LP = {}
-- per-tick top-level functions only: wrapping a helper called per part per
-- tick (a vararg wrapper) stops LuaJIT compiling the caller's loop and
-- inflates it many times over
local VC_NAMES = { "massSync", "safetyTick", "stressTick", "waterTick", "dockTick", "r2Tick", "groupKeysTick",
  "rcsTick", "hullBump", "aeroTick", "wheelTorque", "chuteDrag", "controlTick", "controlsTick", "elecRescan",
  "fuelSync", "stagedDv", "trueMass", "aboardRecs", "controlsCard", "groupStrip", "peripherals", "recoverValue",
  "dockGuides", "hullSpheres", "seatCrew", "takeControl", "releaseClamps" }
local FO_NAMES = { "fleetSync", "fleetRescan", "liveOf", "landing_surface", "fleetList", "survey", "forgetNodes" }
local PC_NAMES = { "chase_clip", "craftBounds", "zoomRange", "cinematic_tick", "freecamStep" }
local WRAPPED = setmetatable({}, { __mode = "k" })
local function lua_prof(inst, prefix, names)
  if params.luaprof == 0 or not inst or WRAPPED[inst] then return end
  WRAPPED[inst] = true
  local n = 0
  for _, nm in ipairs(names) do
    local ok, f = pcall(function() return inst[nm] end)
    if ok and type(f) == "function" then
      local key = prefix .. "." .. nm
      local acc = LP[key] or { ms = 0, n = 0 }
      LP[key] = acc
      local wc = app.wallClock
      inst[nm] = function(...)
        local t = wc()
        local a, b, c, d, e, f2, g, h = f(...)
        acc.ms = acc.ms + (wc() - t) * 1000
        acc.n = acc.n + 1
        return a, b, c, d, e, f2, g, h
      end
      n = n + 1
    end
  end
  P("luaprof: wrapped %d functions of %s", n, prefix)
end
local function lp_snapshot() local s = {}; for k, v in pairs(LP) do s[k] = v.ms end; return s end
LP_SNAP = lp_snapshot
LP_DELTA = function(snap, frames)
  local d = {}
  for k, v in pairs(LP) do local x = v.ms - (snap[k] or 0); if x > 0.001 then d[k] = x / math.max(frames, 1) end end
  return topk(d, 12)
end

-- ── coroutine helpers ───────────────────────────────────────────────────────
local function yield() coroutine.yield() end
-- game seconds, robust to `time` restarting across a scene.load
local function wait(s)
  local acc, last = 0, time
  while acc < s do
    yield()
    local d = time - last
    last = time
    if d > 0 and d < 1 then acc = acc + d end
  end
end
local function wait_for(fn, tmo, what)
  local t = W() + (tmo or 60)
  while true do
    local r = fn()
    if r then return r end
    if W() > t then P("TIMEOUT waiting for %s", what or "?"); return nil end
    yield()
  end
end
local HELD = {}
local function key_down(k) HELD[k] = true; input.simulate { key = k, down = true } end
local function key_up(k) HELD[k] = nil; input.simulate { key = k, down = false } end
local function tap(k) key_down(k); yield(); yield(); key_up(k) end
local function release_all() for k in pairs(HELD) do key_up(k) end end

-- ── world ───────────────────────────────────────────────────────────────────
local NODE
local function world_ready()
  local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
  return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
end
local function clear_weather()
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
end

local ground96   -- defined with the ground helpers below

local function boot()
  local s = "slot" .. math.floor(params.slot)
  NODE.persistent = true
  if (params.usersave or 0) > 0 then
    -- the player's save, as the menu's CONTINUE loads it (menu_slot.lua): the
    -- slot is picked and the system scene loaded; nothing is written to it.
    -- bench.sh copied it into this scratch project.
    save.slot(s)
    P("usersave: slot %s seed %s base %s scale %s played %s", save.slot(), tostring(save.get("g_seed")), tostring(save.get("base.body")), tostring(save.get("g_scale")), tostring(save.get("g_played")))
  else
  -- exactly what the new-save panel's CREATE does (menu_newsave.lua): wipe the
  -- slot, then its sliders' defaults (scenes/menu.ron), the seed and the current
  -- world scale — and NOTHING else. (Setting base.* / g_played to false made the
  -- slot read as an OLD save: g_played ~= nil skips the spawn planet's pregen and
  -- gives gravGen 1 / homeGen 1 — a different, unbuilt home world.)
  terrain.deleteSaveDir("saves/" .. s .. "/terrain")
  if save.deleteSlot then save.deleteSlot(s) end
  save.slot(s)
  save.set("g_seed", math.floor(params.seed))
  for k, v in pairs({ g_planets = 3, g_moonchance = 0.6, g_atmo = 0.8, g_caves = 1.0, g_minorbit = 60000, g_spacing = 2.2,
                      g_radmin = 600, g_radmax = 950, g_gravmin = 3.5, g_gravmax = 8.5, g_star = 1.0 }) do save.set(k, v) end
  local ns = findScript("menu_newsave")
  save.set("g_scale", math.floor(params.scale or (ns and ns.WORLD_SCALE) or 4))
  end
  perf.enable(true)
  -- the script sampler (rc16) slows tight loops, so it is a separate run's
  if (params.sample or 0) > 0 and perf.sampleScripts then perf.sampleScripts(true) end
  if perf.pacing then
    local pc = perf.pacing() or {}
    P("PACING present %s vsync %s refresh %s limitedBy %s", tostring(pc.presentMode), tostring(pc.vsync), tostring(pc.refreshHz), tostring(pc.limitedBy))
  end
  P("mode %s: created %s seed %d; lua debug=%s jit=%s sethook=%s", MODE, s, params.seed, type(debug), type(jit), tostring(debug and debug.sethook ~= nil))
  sc_begin("a_load")
  local wl = W()
  scene.load("system")
  yield()
  -- the stages of the load, by wall clock
  local seen = {}
  local function mark(k) if not seen[k] then seen[k] = W() - wl; P("LOAD %s at %.2f s", k, seen[k]); sc_note("a_load", k, seen[k]) end end
  wait_for(function()
    local gm, bf = findScript("game_manager"), findScript("base_facilities")
    if gm and gm.loading then mark("loading") end
    if gm and not gm.loading and seen.loading then mark("loaded") end
    if gm and not gm.curtain and seen.loaded then mark("reveal") end
    if bf and bf.sited then mark("sited") end
    if bf and bf.grading and bf.grading() then mark("grading") end
    return seen.reveal ~= nil
  end, 300, "the reveal")
  sc_end("a_load")
  clear_weather()
  sc_begin("a_onfoot30")
  local hb = home()
  local wd = hb and save.get("world." .. hb.name)
  if hb then
    P("WORLD %s R %.1f g %.2f atmoHeight %s", hb.name, hb.radius, hb.mu / hb.radius ^ 2, tostring(type(wd) == "table" and wd.atmoHeight))
    sc_note("a_load", "world", string.format("%s R%.0f", hb.name, hb.radius))
  end
  local c = perf.counts() or {}
  P("FIELDS at reveal: fieldChunks %s fieldEdited %s fieldStandIns %s chunks %s props %s decals %s",
    tostring(c.fieldChunks), tostring(c.fieldEdited), tostring(c.fieldStandIns), tostring(c.chunks), tostring(c.props), tostring(c.decals))
  if (params.usersave or 0) > 0 then GROUND_FIRST = ground96("first (at the reveal)") end
end
local function why_not_ready()
  local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
  return string.format("walker %s gm %s loading %s curtain %s sited %s grading %s pending %s", tostring(pw ~= nil), tostring(gm ~= nil),
    tostring(gm and gm.loading), tostring(gm and gm.curtain), tostring(bf and bf.sited), tostring(bf and bf.grading and bf.grading()),
    tostring(terrain.pending and terrain.pending()))
end
local function wait_ready(tmo)
  local t0 = W()
  local ok = wait_for(world_ready, tmo or 60, "world ready")
  P("world ready=%s %.1f s after asking (%s)", tostring(ok ~= nil), W() - t0, why_not_ready())
  return ok
end

-- 0528: what the engine says about the display and its pacing (the output
-- under the window, the compositor holding frames, the frame cap)
local function pacing_line(tag)
  local rr = app.refreshRate and app.refreshRate()
  local pc = perf.pacing and perf.pacing() or {}
  P("PACING %s: app.refreshRate %s | present %s vsync %s refreshHz %s frameCap %s limitedBy %s frameMs %s waitMs %s paced %s/%s",
    tag, tostring(rr), tostring(pc.presentMode), tostring(pc.vsync), tostring(pc.refreshHz), tostring(pc.frameCap), tostring(pc.limitedBy),
    pc.frameMs and string.format("%.1f", pc.frameMs) or "nil", pc.waitMs and string.format("%.1f", pc.waitMs) or "nil", tostring(pc.pacedFrames), tostring(pc.frames))
end
local function run_quick()
  for k = 1, 4 do pacing_line(string.format("+%d s", (k - 1) * 3)); wait(3) end
  sc_begin("q_idle")
  wait(6)
  sc_end("q_idle")
  pacing_line("end")
  -- a cap at the display's own rate (the 0528 recipe for Adaptive)
  if (params.cap or 0) > 0 and app.setFrameCap and app.refreshRate then
    local rr = app.refreshRate()
    if rr and rr >= 10 then app.setFrameCap(rr); P("PACING setFrameCap(%s)", tostring(rr)) end
    wait(2)
    sc_begin("q_capped"); wait(6); sc_end("q_capped")
    pacing_line("capped")
  end
end

local function after_boot_settle(secs)
  -- non-base modes: the first 30 s are base mode's; just let it settle
  wait(secs)
  sc_pause("a_onfoot30")
end
-- After a launch reloads the system scene the base is graded again (rc10:
-- 24,192 ops on a scale-4 world); fly only once it has landed.
local function wait_regrade()
  sc_begin("launch_regrade")
  local t0 = W()
  local bf = findScript("base_facilities")
  wait_for(function() bf = bf or findScript("base_facilities"); return bf and bf.sited and not (bf.grading and bf.grading()) end, 150, "the regrade")
  sc_note("launch_regrade", "secs", W() - t0)
  P("regrade: %.1f s (%s)", W() - t0, why_not_ready())
  sc_end("launch_regrade")
end

-- ── base: on foot, digging, the map ─────────────────────────────────────────
local function astro() return find("Astronaut") end
local function ground_r(b, ux, uy, uz, from)
  local r = from
  for _ = 1, 400 do
    local d = terrain.query(b.x + ux * r, b.y + uy * r, b.z + uz * r)
    if not d then return nil end
    if d < 0.05 then return r end
    r = r - math.max(d * 0.8, 0.1)
  end
  return r
end
local function base_frame()
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  local l = len(bx, by, bz)
  local u = { x = bx / l, y = by / l, z = bz / l }
  local a = math.abs(u.y) > 0.9 and { x = 1, y = 0, z = 0 } or { x = 0, y = 1, z = 0 }
  local t1 = unit(cross(u, a))
  local t2 = unit(cross(u, t1))
  return u, t1, t2, l
end
local function dir_at(u, t, d, R)
  local a = d / R
  return unit({ x = u.x * math.cos(a) + t.x * math.sin(a), y = u.y * math.cos(a) + t.y * math.sin(a), z = u.z * math.cos(a) + t.z * math.sin(a) })
end

-- 96 ground radii round the base (12 bearings × 8 distances, 15–120 m), summed:
-- one number that says whether the world's ground is the same on two engines
-- (and whether it moved between the reveal and the settled world).
ground96 = function(tag)
  local b = home()
  if not b then P("GROUND96 %s: no home body", tag); return nil end
  local u, t1, t2, R = base_frame()
  local sum, n = 0, 0
  for k = 0, 11 do
    local ang = k * math.pi / 6
    local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang), z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
    for _, d in ipairs({ 15, 30, 45, 60, 75, 90, 105, 120 }) do
      local dir = dir_at(u, t, d, R)
      local gr = ground_r(b, dir.x, dir.y, dir.z, R + 150)
      if gr then sum, n = sum + gr, n + 1 end
    end
  end
  P("GROUND96 %s: %d samples, sum %.4f (mean radius %.4f) on %s R %.1f", tag, n, sum, n > 0 and sum / n or 0, b.name, b.radius)
  return sum
end

local function onfoot_30()
  -- what a player does first: look about, walk out of the base, stop
  local t0 = time
  wait(8)
  key_down("w"); wait(8); key_up("w")
  key_down("d"); wait(1.0); key_up("d")
  key_down("w"); wait(6); key_up("w")
  wait(math.max(0, params.onfoot - (time - t0)))
  sc_end("a_onfoot30")
end

local function find_spots()
  local b = home()
  local u, t1, t2, R = base_frame()
  local cl = findScript("climate")
  local meadow, rock
  for _, d in ipairs({ 60, 90, 120, 150, 190, 240 }) do
    for k = 0, 11 do
      local ang = k * math.pi / 6
      local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang), z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
      local dir = dir_at(u, t, d, R)
      local gr = ground_r(b, dir.x, dir.y, dir.z, R + 120)
      if gr then
        local p = { x = b.x + dir.x * gr, y = b.y + dir.y * gr, z = b.z + dir.z * gr }
        local smp = cl and cl.sampleAt and cl.sampleAt(b.name, p.x, p.y, p.z)
        local wet = cl and cl.isUnderwater and cl.isUnderwater(p.x, p.y + 0.5, p.z)
        if smp and not wet then
          local spot = { dir = dir, r = gr, t = t, biome = smp.biome, flora = smp.density or 0, d = d }
          local dens = smp.density or 0
          local grassy = smp.biome == "grass" or smp.biome == "steppe" or smp.biome == "forest"
          if dens > 0.3 and (not meadow or (grassy and not meadow.grassy)) then spot.grassy = grassy; meadow = spot end
          if not rock or dens < rock.flora then rock = spot end
        end
      end
    end
    if meadow and meadow.grassy and rock and rock.flora <= 0.05 then break end
  end
  return meadow, rock
end

local function dig_at(name, spot)
  local b = home()
  local a = astro()
  local tb = findScript("tool_belt")
  if not (a and tb and spot) then P("DIG %s: no crew/tool_belt/spot", name); return end
  P("DIG %s: %s (flora %.2f) %d m from the base", name, tostring(spot.biome), spot.flora, spot.d)
  -- stand there
  local function stand()
    local bb = home()
    a.x, a.y, a.z = bb.x + spot.dir.x * (spot.r + 1.0), bb.y + spot.dir.y * (spot.r + 1.0), bb.z + spot.dir.z * (spot.r + 1.0)
    a.vx, a.vy, a.vz = 0, 0, 0
  end
  stand()
  wait(params.settle)
  local inv = findScript("inventory")
  if inv and inv.gearCount and inv.gearCount("astro", "laser") < 1 then inv.addGear("astro", "laser", 1); P("gave the crew a laser") end
  local slot = nil
  for i, s in ipairs(tb.belt()) do if s.id == "laser" then slot = i end end
  tb.sim = { pressed = { [tostring(slot or 2)] = true } }
  wait(0.5)
  P("DIG %s: tool %s, gate %s", name, tostring(tb.toolId()), tostring(tb.gate))
  local c0 = perf.counts()
  sc_begin(name)
  local bb = home()
  for i = 1, params.clicks do
    -- aim 4 m ahead, creeping 0.3 m a click, from the crew's eye
    local up = unit(sub(a, bb))
    local eye = { x = a.x + up.x * 0.6, y = a.y + up.y * 0.6, z = a.z + up.z * 0.6 }
    local k = 3.5 + (i % 5) * 0.3
    local tgt = { x = a.x + spot.t.x * k - up.x * 1.6, y = a.y + spot.t.y * k - up.y * 1.6, z = a.z + spot.t.z * k - up.z * 1.6 }
    local d = sub(tgt, eye)
    tb.sim = { btn = { [0] = true }, aim = { eye.x, eye.y, eye.z, d.x, d.y, d.z } }
    wait(params.hold)
    tb.sim = { btn = { [0] = false }, aim = { eye.x, eye.y, eye.z, d.x, d.y, d.z } }
    wait(params.gap)
  end
  wait(1.5)   -- the tail: re-lays and collider rebuilds after the last bite
  tb.sim = nil
  local c1 = perf.counts()
  sc_note(name, "biome", spot.biome)
  sc_note(name, "decals", string.format("%d->%d", c0.decals or 0, c1.decals or 0))
  sc_end(name)
end

local function map_view(name, secs)
  sc_begin(name)
  tap("m")
  wait(0.5)
  local om = findScript("orbit_map")
  local open = om and om.isOpen and om.isOpen()
  if not open and om and om.toggle then om.toggle(); P("map: key did not open it, toggled") end
  wait(secs)
  tap("m")
  wait(1.0)
  if om and om.isOpen and om.isOpen() and om.toggle then om.toggle() end
  sc_end(name)
end

local function run_base()
  onfoot_30()
  sc_begin("a_after30_until_ready")
  wait_ready(90)
  sc_end("a_after30_until_ready")
  local meadow, rock = find_spots()
  P("spots: meadow %s, rock %s", meadow and meadow.biome or "NONE", rock and rock.biome or "NONE")
  dig_at("b_dig_meadow", meadow)
  dig_at("b_dig_rock", rock)
  -- back to the base for the map
  map_view("f_map_onfoot", params.mapsecs)
end

-- ── vehicles: blueprints and launching ──────────────────────────────────────
local function rec(uid, id, x, y, z, o)
  o = o or {}
  return { uid = uid, id = id, x = x, y = y, z = z, yaw = o.yaw or 0, pitch = o.pitch or 0, roll = o.roll or 0,
           parent = o.parent or 0, att = o.att or "", sym = o.sym or 0, mir = o.mir or "", stage = o.stage or 0 }
end
local HP = math.pi / 2
local ROVER = {
  rec(1, "roverBody", 0, 0.62, 0),
  rec(2, "wheelM", 0.66, 0.42, 0.7, { yaw = -HP, parent = 1, att = "surface", sym = 1, mir = "z" }),
  rec(3, "wheelM", 0.66, 0.42, -0.7, { yaw = HP, parent = 1, att = "surface", sym = 1, mir = "z" }),
  rec(4, "wheelM", -0.66, 0.42, 0.7, { yaw = -HP, parent = 1, att = "surface", sym = 2, mir = "z" }),
  rec(5, "wheelM", -0.66, 0.42, -0.7, { yaw = HP, parent = 1, att = "surface", sym = 2, mir = "z" }),
  -- a crewed seat: a probe body loses its link a few hundred metres round a small world
  rec(6, "seat", 0, 0.62 + 0.15 + 0.65, 0, { parent = 1, att = "top" }),
}
local function rocket_bp(ntanks)
  local l, y = { rec(1, "engineS", 0, 0.65, 0) }, 1.3
  for i = 1, ntanks do l[#l + 1] = rec(1 + i, "tankS", 0, y + 0.5, 0, { parent = i, att = "top" }); y = y + 1.0 end
  l[#l + 1] = rec(ntanks + 2, "pod", 0, y + 0.4, 0, { parent = ntanks + 1, att = "top" })
  l[#l + 1] = rec(ntanks + 3, "chute", 0, y + 0.97, 0, { parent = ntanks + 2, att = "top" })
  return l
end

local function pilot()
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.piloting and v.node and v.node.valid then return v end
  end
end
local function wait_craft(minparts, tmo)
  local ready = nil
  return wait_for(function()
    local v = pilot()
    if not v then return nil end
    local i = assembly.info(v.node)
    if i and i.anchored and #i.parts >= minparts then
      ready = ready or time
      if time - ready > 2 then
        lua_prof(v, "vessel_controller", VC_NAMES)
        lua_prof(findScript("flight_ops"), "flight_ops", FO_NAMES)
        lua_prof(findScript("planet_camera"), "planet_camera", PC_NAMES)
        return v
      end
    end
  end, tmo or 120, "the craft on the stand")
end

-- through the standalone builder scene (the probes' proven path)
local function launch_via_builder(bp, site, minparts)
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  save.set("shipyard.blueprint", { parts = bp })
  save.set("shipyard.site", site)
  save.set("shipyard.pilot", 1)
  scene.load("builder")
  local B = wait_for(function() local B = findScript("builder"); return B and B.partUids and #B.partUids() >= minparts and B end, 90, "the builder")
  if not B then return nil end
  wait(1.5)
  save.set("shipyard.site", site)
  sc_begin("launch_load")
  B.doLaunch()
  if save.get("shipyard.launch") ~= 1 then B.doLaunch() end
  local v = wait_craft(minparts, 150)
  sc_end("launch_load")
  wait_regrade()
  return v
end

local function body_state(vnode)
  local i = assembly.info(vnode)
  local b = home()
  if not (i and b) then return nil end
  local rel = sub(i.com, b)
  local r = len(rel.x, rel.y, rel.z)
  local U = scl(rel, 1 / r)
  -- velocity from the craft's own track over the planet (assembly.info's vel
  -- read 0 in flight on rc10 here), smoothed over a few frames
  local now = time
  local v = { x = 0, y = 0, z = 0 }
  if BS_LAST and BS_LAST.node == vnode and now > BS_LAST.t + 1e-4 and now - BS_LAST.t < 1 then
    local k = 1 / (now - BS_LAST.t)
    local raw = { x = (rel.x - BS_LAST.rel.x) * k, y = (rel.y - BS_LAST.rel.y) * k, z = (rel.z - BS_LAST.rel.z) * k }
    local pv = BS_LAST.v
    v = { x = pv.x * 0.6 + raw.x * 0.4, y = pv.y * 0.6 + raw.y * 0.4, z = pv.z * 0.6 + raw.z * 0.4 }
  elseif BS_LAST and BS_LAST.node == vnode then
    v = BS_LAST.v
  end
  if not BS_LAST or BS_LAST.node ~= vnode or now ~= BS_LAST.t then BS_LAST = { node = vnode, t = now, rel = rel, v = v } end
  local mu = b.mu
  local v2 = dot(v, v)
  local eps = v2 / 2 - mu / r
  local h = cross(rel, v)
  local hh = dot(h, h)
  local e = math.sqrt(math.max(0, 1 + 2 * eps * hh / (mu * mu)))
  local a = eps < 0 and -mu / (2 * eps) or math.huge
  return { mu = mu, eps = eps, wv = len(i.vel.x, i.vel.y, i.vel.z), bv = len(b.vx or 0, b.vy or 0, b.vz or 0), i = i, b = b, U = U, r = r, alt = r - b.radius, v = v, V = math.sqrt(v2), vr = dot(v, U),
           apo = a * (1 + e) - b.radius, peri = a * (1 - e) - b.radius }
end
-- the craft's own axis that pointed up on the pad (a vessel node need not be +Y up)
local UP_LOCAL = nil
local function up_axis(n, U)
  local o = n:toWorld(vec3(0, 0, 0))
  local ax = {}
  for k, lv in ipairs({ vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, 1) }) do
    local w = n:toWorld(lv) - o
    ax[k] = unit({ x = w.x, y = w.y, z = w.z })
  end
  if not UP_LOCAL and U then
    local best, bk, bs = -1, 2, 1
    for k = 1, 3 do local d = dot(ax[k], U); if math.abs(d) > best then best, bk, bs = math.abs(d), k, d > 0 and 1 or -1 end end
    UP_LOCAL = { k = bk, s = bs }
  end
  local u = UP_LOCAL or { k = 2, s = 1 }
  return scl(ax[u.k], u.s)
end

-- ── the real launch path since 0406ff9: E at the VAB, build in place, LAUNCH ──
local function enter_vab(tag)
  local vab = wait_for(function() return find("VabInterior") end, 150, "the VAB")
  if not vab then return nil end
  local a = astro()
  local p = vab:toWorld(vec3(0, 1.4, 14))
  a.x, a.y, a.z = p.x, p.y, p.z
  a.vx, a.vy, a.vz = 0, 0, 0
  wait(2.5)
  -- the additive load (rc25: the running scene's sounds and effects play on,
  -- only the overlay's own start): the counts before and after, and the
  -- load's own steps from the frames it took
  local c0 = perf.counts() or {}
  local f0 = LASTF
  sc_begin(tag)
  tap("e")
  local BH = wait_for(function() local bh = findScript("build_host"); return bh and bh.state == "building" and bh end, 20, "the builder")
  if not BH then local fm = findScript("facility_menu"); if fm then fm.openMenu("FacHangar"); fm.action() end
    BH = wait_for(function() local bh = findScript("build_host"); return bh and bh.state == "building" and bh end, 20, "the builder (menu)") end
  sc_end(tag)
  local c1 = perf.counts() or {}
  local steps = {}
  for _, f in ipairs(perf.frames and perf.frames(120) or {}) do
    if f.frame and f.frame > f0 then
      for k, v in pairs(f.parts or {}) do if k:match("^scene") then steps[k] = (steps[k] or 0) + v end end
    end
  end
  if BH then
    P("in the builder (enter %.0f ms): effects %s -> %s, particles %s -> %s, voices %s -> %s, nodes %s -> %s; load steps %s",
      BH.enterMs or -1, tostring(c0.effects), tostring(c1.effects), tostring(c0.particles), tostring(c1.particles), tostring(c0.voices), tostring(c1.voices),
      tostring(c0.nodes), tostring(c1.nodes), fmtk(topk(steps, 10)))
    sc_note(tag, "enterMs", BH.enterMs or -1)
    sc_note(tag, "effects", string.format("%s->%s", tostring(c0.effects), tostring(c1.effects)))
    sc_note(tag, "voices", string.format("%s->%s", tostring(c0.voices), tostring(c1.voices)))
  end
  return BH
end
local function load_bp(B, name, list, extra)
  sc_begin(name)
  local w0 = W()
  local bp = { parts = list }
  for k, v in pairs(extra or {}) do bp[k] = v end
  save.set("shipyard.blueprint", bp)
  B.reload()
  wait_for(function() return not (B.loadProgress and B.loadProgress()) and (B.partCount or 0) >= #list end, 60, name)
  sc_note(name, "load_s", W() - w0)
  sc_note(name, "parts", B.partCount or -1)
  P("%s: %d parts loaded in %.2f s", name, B.partCount or -1, W() - w0)
  sc_end(name)
end
local function launch_in_vab(bp, site, minparts, extra)
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  local BH = enter_vab("launch_enter")
  if not BH then return nil end
  local B = findScript("builder")
  wait(1.0)
  load_bp(B, "launch_bp", bp, extra)
  if B.launchSite and B.launchSite() ~= site and B.toggleLaunchSite then B.toggleLaunchSite() end
  P("launch site %s", tostring(B.launchSite and B.launchSite()))
  sc_begin("launch_rollout")
  B.doLaunch()
  wait(0.6)
  if BH.state == "building" then B.doLaunch() end
  local v = wait_craft(minparts, 150)
  sc_end("launch_rollout")
  return v
end

-- ── rocket: pad to orbit, keys ──────────────────────────────────────────────
-- Skipper, 2 FT-M | decoupler | Anvil, 2 FT-M, pod, chute: the classic two-stage
-- orbiter. (The old Sputter + 6 FT-S stack weighed 7.8 t against the Sputter's
-- ~42 kN: TWR 0.6 on Naolol, so it crawled off the pad and never made orbit.)
local function rocket_2stage()
  local l, y, u = {}, 0, 0
  local function add(id, h, st)
    u = u + 1
    l[#l + 1] = rec(u, id, 0, y + h / 2, 0, { parent = u > 1 and u - 1 or 0, att = u > 1 and "top" or "", stage = st or 0 })
    y = y + h
  end
  add("skipper", 1.6); add("tankM", 1.5); add("tankM", 1.5); add("decoupler", 0.25, 1)
  add("engineM", 1.6); add("tankM", 1.5); add("tankM", 1.5); add("pod", 0.8); add("chute", 0.34, 2)
  return l
end
local ascend
local function run_rocket()
  local rs = findScript("research")
  for _, id in ipairs({ "tankM", "engineM", "skipper" }) do if rs and rs.grant then rs.grant(id, "probe") end end
  local bp = (params.tanks or 0) > 0 and rocket_bp(params.tanks) or rocket_2stage()
  local vc = launch_via_builder(bp, "pad", #bp)
  if not vc then P("RESULT rocket: no craft"); return end
  return ascend(vc)
end
-- The ascent itself, from a craft clamped on the pad: keys, a kick, prograde,
-- MECO at the apoapsis target, a stage, the circularisation. Returns the
-- phase it ended in ("orbit" when it made it) and the last body state.
ascend = function(vc)
  local vn = vc.node
  STAGED, UP_LOCAL = nil, nil
  local S = body_state(vn)
  up_axis(vn, S.U)
  P("ROCKET on the pad: %d parts, %.2f t, alt %.1f; mu %.4g R %.1f craft |v| %.1f body |v| %.1f rel %.1f eps %.1f", #S.i.parts, S.i.mass, S.alt, S.mu, S.b.radius, S.wv, S.bv, S.V, S.eps)
  sc_begin("c_ascent")
  wait(1)
  tap("z")
  wait(0.3)
  tap("space")
  wait(1.0)
  if assembly.info(vn).anchored then P("space did not release; releaseClamps()"); vc.releaseClamps() end
  local alt0 = S.alt
  local wd = save.get("world." .. S.b.name) or {}
  local atmoH = (type(wd) == "table" and wd.atmoHeight) or S.b.radius * 0.3
  local APO = params.apo or math.max(atmoH * 1.25, S.b.radius * 0.15) + 40
  local PERI = params.peri or math.max(atmoH * 1.05, S.b.radius * 0.1) + 20
  P("ROCKET world %s R %.0f atmo %.0f: apo target %.0f, peri target %.0f", S.b.name, S.b.radius, atmoH, APO, PERI)
  sc_note("c_ascent", "world", string.format("%s R%.0f", S.b.name, S.b.radius))
  local phase, tthr = "vertical", nil
  local tstart = time
  local function thr_window(tag)
    sc_begin("c_throttle_change")
    tthr = time
    P("THROTTLE %s at alt %.0f (throttle %.2f)", tag, body_state(vn).alt, vc.throttle or -1)
  end
  local throttle_tests = 0
  while true do
    yield()
    if not vn.valid then P("ROCKET gone"); break end
    S = body_state(vn)
    if not S then break end
    if tthr and time - tthr > 3 then sc_pause("c_throttle_change"); tthr = nil end
    -- the flight path's angle from the vertical (the craft's own axes are not
    -- reliably "up" on every vessel node)
    local tilt = S.V > 1 and math.deg(math.acos(clamp(S.vr / S.V, -1, 1))) or 0
    if phase == "vertical" then
      if S.alt - alt0 > 25 and throttle_tests == 0 then
        throttle_tests = 1
        thr_window("ctrl held 0.6 s"); key_down("ctrl"); wait(0.6); key_up("ctrl"); wait(0.8); tap("z"); thr_window("z full")
      end
      if S.alt - alt0 > 40 then phase = "kick"; key_down("s"); P("KICK at %.0f m, %.1f m/s", S.alt, S.V) end
    elseif phase == "kick" then
      if tilt > 8 then key_up("s"); vc.setSAS("prograde"); phase = "turn"; P("PROGRADE at tilt %.1f, alt %.0f, V %.1f", tilt, S.alt, S.V) end
    elseif phase == "turn" then
      if S.apo > APO then
        tap("x"); thr_window("x cut (apoapsis reached)")
        phase = "coast"; P("MECO apo %.0f peri %.0f alt %.0f V %.1f (craft |v| %.1f body %.1f eps %.1f)", S.apo, S.peri, S.alt, S.V, S.wv, S.bv, S.eps)
      end
    elseif phase == "coast" then
      if S.vr < 3 then
        thr_window("shift ramp"); key_down("shift"); phase = "circ"; P("CIRC burn at alt %.0f", S.alt)
      end
    end
    if not STAGED and (vc.fuel or 0) <= 320.5 and (params.tanks or 0) == 0 then STAGED = true; P("STAGE at alt %.0f: %s", S.alt, tostring(vc.stageNext())) end
    if phase == "circ" then
      if HELD.shift and (vc.throttle or 0) > 0.98 then key_up("shift") end
      if S.peri > PERI or (vc.fuel or 1) <= 0 then
        release_all(); tap("x"); thr_window("x cut (orbit)")
        P("ORBIT apo %.0f peri %.0f alt %.0f V %.1f fuel %.1f", S.apo, S.peri, S.alt, S.V, vc.fuel or -1)
        phase = "orbit"; break
      end
    end
    if S.alt < alt0 - 5 and time - tstart > 10 then P("ROCKET fell: alt %.0f", S.alt); break end
    if time - tstart > (params.ascentmax or 110) then P("ROCKET ascent timed out: phase %s apo %.0f peri %.0f alt %.0f", phase, S.apo, S.peri, S.alt); break end
  end
  release_all()
  sc_note("c_ascent", "phase", phase)
  sc_note("c_ascent", "apo", S and S.apo or -1)
  sc_note("c_ascent", "peri", S and S.peri or -1)
  sc_note("c_ascent", "secs", time - tstart)
  sc_end("c_ascent")
  wait(2)
  sc_end("c_throttle_change")
  sc_begin("c_orbit_coast")
  wait(10)
  sc_end("c_orbit_coast")
  if MODE == "rocket" then map_view("f_map_flight", params.mapsecs) end
  return phase, S
end

-- ── rover ───────────────────────────────────────────────────────────────────
local function run_rover()
  -- (the in-VAB path rolled this rover out with 2 of its 6 parts on rc10: the standalone builder it is)
  local vc = launch_via_builder(ROVER, "runway", 6)
  if not vc then P("RESULT rover: no craft"); return end
  local vn = vc.node
  vc.releaseClamps()
  wait(2)
  local u, _, _, R = base_frame()
  local function from_base()
    local b = home()
    local p = sub(assembly.info(vn).com, b)
    local cang = clamp(dot(unit(p), u), -1, 1)
    return math.acos(cang) * R
  end
  P("ROVER released %.0f m from the base", from_base())
  sc_begin("e_rover")
  local t0, maxd, tout = time, 0, nil
  while time - t0 < params.drivesecs do
    yield()
    if not vn.valid then P("ROVER gone"); break end
    local t = time - t0
    -- the player's keys: W, steering away from the base. The rover rolls out
    -- on the runway pointing back past the colony; a fixed left turn at 8 s
    -- (the old script) sent it out over open ground on some runs and into the
    -- base on others (rc11: 127 m from the base at most, a 536 m run on rc10),
    -- so the drive depended on where the clock happened to leave it.
    if not HELD.w then key_down("w") end
    local want = nil
    do
      local i1 = assembly.info(vn)
      local Rh = unit(sub(i1.com, home()))
      local away = sub(Rh, scl(u, dot(Rh, u)))
      local v = i1.vel
      local vh = sub(v, scl(Rh, dot(v, Rh)))
      if len(away.x, away.y, away.z) > 1e-6 and len(vh.x, vh.y, vh.z) > 2 then
        away = unit(away)
        local sn = dot(cross(unit(vh), away), Rh)   -- + the way out is to the left
        local cs = dot(unit(vh), away)
        if cs < 0.97 then want = sn >= 0 and "a" or "d" end
      end
    end
    for _, k in ipairs({ "a", "d" }) do
      if k == want and not HELD[k] then key_down(k) elseif k ~= want and HELD[k] then key_up(k) end
    end
    if t > 3 and not L_ROVER_LOG then L_ROVER_LOG = true; local i0 = assembly.info(vn); P("ROVER t=3: speed %.1f why %s anchored %s piloting %s ctl %s driving %s drive %.2f onWheels %s wheels %d asleep %s", len(i0.vel.x, i0.vel.y, i0.vel.z), tostring(vc.R2.why), tostring(i0.anchored), tostring(vc.piloting), tostring(vc.R2.ctl), tostring(vc.R2.driving), vc.R2.drive or -1, tostring(vc.R2.onWheels), #(vc.R2.wheels or {}), tostring(i0.asleep)); P("ROVER elec: %s", vc.elecDebug and vc.elecDebug() or "?") end
    local d = from_base()
    maxd = math.max(maxd, d)
    -- the track, every 3 s: a drive that never gets far says where it went
    if math.floor(t / 3) ~= math.floor((t - dt) / 3) then
      local i1 = assembly.info(vn)
      local v = i1.vel
      local Rh = unit(sub(i1.com, home()))
      local away = sub(Rh, scl(u, dot(Rh, u)))
      local la = len(away.x, away.y, away.z)
      local vr = la > 1e-6 and dot(v, scl(away, 1 / la)) or 0  -- + away from the base, - toward it
      P("ROVER track t=%.0f: %.0f m from the base, speed %.1f (%.1f away from it), onWheels %s, why %s",
        t, d, len(v.x, v.y, v.z), vr, tostring(vc.R2.onWheels), tostring(vc.R2.why))
    end
    if d > params.out and not tout then tout = t; P("ROVER %.0f m out after %.1f s", d, t) end
  end
  local i = assembly.info(vn)
  P("ROVER done: max %.0f m from the base, speed %.1f, why %s", maxd, i and len(i.vel.x, i.vel.y, i.vel.z) or -1, tostring(vc.R2.why))
  sc_note("e_rover", "maxFromBase", maxd)
  release_all()
  sc_end("e_rover")
end

-- ── plane (from SCRATCH/aero's probe, trimmed to take-off and low flight) ────
local function basis(n)
  local cy, sy = math.cos(n.yaw), math.sin(n.yaw)
  local cx, sx = math.cos(n.pitch), math.sin(n.pitch)
  local cz, sz = math.cos(n.roll), math.sin(n.roll)
  return { x = cy * cz + sy * sx * sz, y = cx * sz, z = -sy * cz + cy * sx * sz },
         { x = -cy * sz + sy * sx * cz, y = cx * cz, z = sy * sz + cy * sx * cz },
         { x = sy * cx, y = -sx, z = cy * cx }
end
local function eulerOf(X, Y, Z)
  local pitch = math.asin(math.max(-1, math.min(1, -Z.y)))
  if math.abs(Z.y) > 1 - 1e-10 then return math.atan2(-X.z, X.x), pitch, 0 end
  return math.atan2(Z.x, Z.z), pitch, math.atan2(X.y, Y.y)
end
local puid = 0
local function prec(id, x, y, z, X, Y, o)
  puid = puid + 1
  local Z = cross(X, Y)
  local yaw, pitch, roll = eulerOf(X, Y, Z)
  o = o or {}
  return { uid = puid, id = id, x = x, y = y, z = z, yaw = yaw, pitch = pitch, roll = roll,
           parent = o.parent or 0, att = o.att or "", sym = o.sym or 0, mir = o.mir or "", stage = o.stage or 0 }
end
local NOSE, TOP = { x = 1, y = 0, z = 0 }, { x = 0, y = 1, z = 0 }
local function plane()
  puid = 0
  local Y0, R = 1.5, {}
  local function add(r) R[#R + 1] = r return r end
  local cZ = { x = 0, y = -1, z = 0 }
  local cX = cross(NOSE, cZ)
  add(prec("cockpit", 1.9, Y0, 0, cX, NOSE))
  add(prec("fuseTank", -0.2, Y0, 0, cX, NOSE, { parent = 1, att = "bottom" }))
  add(prec("jet", -2.1, Y0, 0, cX, NOSE, { parent = 2, att = "bottom" }))
  for _, s in ipairs({ 1, -1 }) do
    local out = { x = 0, y = 0, z = s }
    local w = add(prec("wingL", -0.6, Y0, s * (0.5 + 1.75), out, NOSE, { parent = 2, att = "radial", sym = 1, mir = "x" }))
    add(prec("wingTip", -0.6, Y0, s * (0.5 + 3.5 + 0.6), out, NOSE, { parent = w.uid, att = "radial", sym = 2, mir = "x" }))
    add(prec("elevon", -2.35, Y0, s * (0.5 + 0.8), out, NOSE, { parent = 3, att = "radial", sym = 3, mir = "x" }))
    local ia = unit({ x = 0, y = 0.707, z = s * 0.707 })
    add(prec("intake", 0.5, Y0 + ia.y * 0.7, ia.z * 0.7, ia, NOSE, { parent = 2, att = "radial", sym = 4, mir = "x" }))
    add(prec("gearM", -0.45, 0.75, s * 1.4, { x = 0, y = -1, z = 0 }, NOSE, { parent = w.uid, att = "radial", sym = 5, mir = "x" }))
  end
  add(prec("tailFin", -2.3, Y0 + 0.5 + 0.75, 0, TOP, NOSE, { parent = 3, att = "radial" }))
  add(prec("gearS", 2.3, 0.5, 0, { x = 0, y = -1, z = 0 }, NOSE, { parent = 1, att = "radial" }))
  return R
end
local function full(r, def, k)
  local E = findScript("electronics")
  local d = {}
  for key, v in pairs(r) do d[key] = v end
  d.prefab, d.label = def.prefab, def.label
  d.h, d.mass, d.cost, d.kind, d.rx, d.rz = def.h, def.mass, def.cost, def.kind, def.rx or 0, def.rz or 0
  d.strength, d.maxq = def.strength or 0, def.maxq or 0
  d.thrust = (def.thrust or 0) * k.thrust
  d.ve = (def.ve or 0) * k.ve
  d.burn = d.thrust > 0 and d.thrust / (d.ve * 0.01) or 0
  d.fuel, d.fuel_t = def.fuel or 0, def.fuel and 0.01 or 0
  d.decouple, d.legs, d.radial, d.chute = def.decouple and 1 or 0, def.legs and 1 or 0, def.radial and 1 or 0, def.chute and 1 or 0
  d.comms, d.aero, d.af = def.comms and 1 or 0, def.aero and 1 or 0, def.af
  d.power, d.solar, d.ec, d.gen, d.dock, d.rcs, d.rcs_thrust, d.cargo = 0, 0, 0, 0, 0, 0, 0, 0
  d.front, d.wheel, d.fairing, d.seat, d.robo, d.claw = def.front and 1 or 0, def.wheel or "", 0, def.seat and 1 or 0, "", 0
  if E then
    local mods = E.deriveMods(def, def.mods)
    for _, m in ipairs(mods) do if m.type == "drive" then m.torque = (m.torque or 0) * k.thrust end end
    d.mods = E.encodeMods(mods)
  end
  return d
end

local function run_plane()
  -- the builder rates the catalogue for this world first (parts.rating)
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
    if def then list[#list + 1] = full(r, def, k) else P("NO DEF %s", r.id) end
  end
  save.set("shipyard.blueprint", { parts = list, catalogue = { thrust = k.thrust, ve = k.ve } })
  save.set("shipyard.launch", 1)
  save.set("shipyard.site", "runway")
  save.set("shipyard.pilot", 1)
  sc_begin("launch_load")
  scene.load("system")
  yield()
  local vc = wait_craft(#list, 150)
  sc_end("launch_load")
  wait_regrade()
  if not vc then P("RESULT plane: no craft"); return end
  local vn = vc.node
  local bf = findScript("base_facilities")
  local site = bf and bf.launchSite and bf.launchSite("runway")
  local function st()
    local i = assembly.info(vn)
    local b = home()
    if not (i and b) then return nil end
    local rx, up, rz = basis(vn)
    local F = vc.AERO and vc.AERO.frame
    local fn = F and F.n or { x = 0, y = 1, z = 0 }
    local ff = F and F.f or { x = 0, y = 0, z = -1 }
    local function w(v) return { x = rx.x * v.x + up.x * v.y + rz.x * v.z, y = rx.y * v.x + up.y * v.y + rz.y * v.z, z = rx.z * v.x + up.z * v.y + rz.z * v.z } end
    local n, t = w(fn), w(ff)
    local r = cross(n, t)
    local rel = sub(i.com, b)
    local rr = len(rel.x, rel.y, rel.z)
    local U = scl(rel, 1 / rr)
    local V = len(i.vel.x, i.vel.y, i.vel.z)
    local S = { i = i, b = b, n = n, t = t, r = r, U = U, V = V, alt = rr - b.radius,
      theta = math.asin(clamp(dot(n, U), -1, 1)), bank = math.asin(clamp(-dot(r, U), -1, 1)),
      gamma = V > 1 and math.asin(clamp(dot(i.vel, U) / V, -1, 1)) or 0,
      qn = -dot(i.angVel, cross(t, n)), pr = dot(i.angVel, n), hud = vc.tele and vc.tele.aero or nil }
    local h = raycast(i.com.x, i.com.y, i.com.z, -U.x, -U.y, -U.z, 400, vn)
    S.agl = h and h.distance or 999
    if site then
      local Ng = unit(cross({ x = site.x, y = site.y, z = site.z }, site.fwd))
      local trk = unit(cross(Ng, U))
      local hn = unit(sub(n, scl(U, dot(n, U))))
      S.herr = math.atan2(dot(cross(hn, trk), U), dot(hn, trk))
      S.Ng = Ng
    end
    return S
  end
  local function fly(S, theta_t, bank_t, yaw_extra)
    local p = -clamp(4.0 * (theta_t - S.theta) - 1.6 * S.qn, -1, 1)
    local r = clamp(2.5 * (bank_t - S.bank) - 0.8 * S.pr, -1, 1)
    local slip = S.hud and S.hud.slip or 0
    vc.AERO.cmd = { p = p, y = clamp(-0.02 * slip + (yaw_extra or 0), -1, 1), r = r }
  end
  -- How the jet stands before brakes off: ground ~1.45 m under its centre of
  -- mass is normal; ~2.5 m means the runway under it is not (yet) the grade.
  do
    local S0 = st()
    local q = nil
    if S0 then
      local c = S0.i.com
      q = terrain.query(c.x - S0.U.x * 1.45, c.y - S0.U.y * 1.45, c.z - S0.U.z * 1.45)
    end
    P("PLANE before release: agl %.2f, field at 1.45 m below the CoM %.2f, grading %s, edits pending %d",
      S0 and S0.agl or -1, q or -99, tostring(bf and bf.grading and bf.grading()), terrain.pending and terrain.pending() or -1)
    -- (params.rwyhold > 0) watch the runway's graded surface while the jet
    -- stays clamped: the field at the grade radius along the centreline
    if (params.rwyhold or 0) > 0 and bf and bf.frameOf and bf.dirAt then
      local R, hd = save.get("base.r"), save.get("base.heading")
      local c = { x = save.get("base.x"), y = save.get("base.y"), z = save.get("base.z") }
      local Fr = bf.frameOf(c, hd, R)
      local function profile(tag)
        local b = home()
        local out, worst = {}, 0
        for uu = -131, 131, 20 do
          local d = bf.dirAt(Fr, uu, -62)
          local qq = terrain.query(b.x + d.x * R, b.y + d.y * R, b.z + d.z * R)
          out[#out + 1] = qq and string.format("%.2f", qq) or "nil"
          if qq then worst = math.max(worst, math.abs(qq)) end
        end
        local S1 = st()
        local c1 = S1 and S1.i.com
        local q1 = c1 and terrain.query(c1.x - S1.U.x * 1.45, c1.y - S1.U.y * 1.45, c1.z - S1.U.z * 1.45)
        P("PLANE RWY[%s] agl %.2f field-at-wheels %.2f, centreline worst %.2f | %s | busy %s",
          tag, S1 and S1.agl or -1, q1 or -99, worst, table.concat(out, " "), tostring(terrain.busy and terrain.busy()))
      end
      for k = 0, params.rwyhold do
        profile("+" .. k .. "s")
        if k < params.rwyhold then wait(1) end
      end
    end
  end
  vc.releaseClamps()
  vc.setSAS("stability")
  sc_begin("d_takeoff")
  local t0, ga, air, phase = time, nil, 0, "roll"
  local S
  -- 0526: the every-7th-frame burst. Every roll frame is kept with the
  -- engine's own record (perf.frames) and the craft's place on its planet in
  -- 24 m chunk cells; the first frame whose physics is 2.5x the running median
  -- (and over `burstms`, default 60) is a burst, printed with the 12 frames
  -- before and the 8 after it, as BURST lines. burst=N captures N bursts.
  local ring, burst_n, burst_arm, med = {}, 0, nil, {}
  local CH = params.chunk or 24
  local function roll_frame(S)
    local fr = perf.frames and perf.frames(4) or {}
    local rel = sub(S.i.com, S.b)
    -- the planet's own axes are the world's here (bodies on rails do not spin)
    local cell = string.format("%d,%d,%d", math.floor(rel.x / CH), math.floor(rel.y / CH), math.floor(rel.z / CH))
    local edge = math.min(rel.x / CH - math.floor(rel.x / CH), rel.y / CH - math.floor(rel.y / CH), rel.z / CH - math.floor(rel.z / CH))
    for _, f in ipairs(fr) do
      if f.frame and (not ring[#ring] or f.frame > ring[#ring].frame) then
        local b, pt, c = f.buckets or {}, f.parts or {}, f.counts or {}
        local bo = {}
        for _, e in ipairs(f.bodies or {}) do bo[e.name or "?"] = e.ms or 0 end
        ring[#ring + 1] = { frame = f.frame, ms = f.ms or 0, physics = b.physics or 0, sweeps = pt.physicsSweeps or 0, static = pt.physicsStatic or 0,
          broad = pt.physicsBroadphase or 0, pairs = pt.physicsPairs or 0, joints = pt.physicsJoints or 0, sleep = pt.physicsSleep or 0,
          meshing = pt.terrainMeshing or 0, terrain = b.terrain or 0, scripts = b.scripts or 0, render = b.render or 0,
          fieldChunks = c.fieldChunks, chunks = c.chunks, sweepsN = c.sweeps, rays = c.rays, props = c.props,
          V = S.V, agl = S.agl, cell = cell, edge = edge, rel = rel, bodies = topk(bo, 3), paced = f.paced }
        if #ring > 40 then table.remove(ring, 1) end
        med[#med + 1] = b.physics or 0
        if #med > 30 then table.remove(med, 1) end
        if not burst_arm and burst_n < math.max(1, params.burst) and #med >= 12 then
          local m = stats(med).p50
          if (b.physics or 0) > 2.5 * m and (b.physics or 0) > (params.burstms or 60) then burst_arm = { frame = f.frame, left = 8, med = m } end
        elseif burst_arm then
          burst_arm.left = burst_arm.left - 1
          if burst_arm.left <= 0 then
            burst_n = burst_n + 1
            P("BURST #%d around frame %d (running median physics %.1f ms); chunk cell %d m; columns: frame ms physics sweeps static broad pairs joints sleep meshing terrain scripts render | V agl | cell edge | fieldChunks chunks sweepsN | bodies | paced",
              burst_n, burst_arm.frame, burst_arm.med, CH)
            for _, r in ipairs(ring) do
              if r.frame >= burst_arm.frame - 12 and r.frame <= burst_arm.frame + 8 then
                P("BURST %s%d %.1f | %.1f %.1f %.1f %.2f %.2f %.2f %.2f | %.2f %.1f %.1f %.1f | %.1f %.1f | %s %.2f | %s %s %s | %s | %s", r.frame == burst_arm.frame and "*" or " ",
                  r.frame, r.ms, r.physics, r.sweeps, r.static, r.broad, r.pairs, r.joints, r.sleep, r.meshing, r.terrain, r.scripts, r.render, r.V, r.agl, r.cell, r.edge,
                  tostring(r.fieldChunks), tostring(r.chunks), tostring(r.sweepsN), fmtk(r.bodies), tostring(r.paced))
              end
            end
            burst_arm = nil
          end
        end
      end
    end
  end
  while true do
    yield()
    if not vn.valid then P("PLANE gone"); break end
    S = st()
    if not S then break end
    ga = ga or S.alt
    local t = time - t0
    vc.setThrottle(1)
    if phase == "roll" then
      roll_frame(S)
      local yaw = clamp(3.0 * (S.herr or 0), -1, 1)
      if S.V < 40 then
        local p = (S.V > 15) and -clamp(3.0 * (D(1) - S.theta) - 1.0 * S.qn, -1, 1) or 0
        vc.AERO.cmd = { p = p, y = yaw, r = clamp(-2.5 * S.bank, -1, 1) }
      else fly(S, D(11), 0, yaw) end
      if not vc.R2.onWheels and S.alt > ga + 1.5 and S.V > 30 then air = air + 1 / 60 else air = 0 end
      if air > 0.6 then
        P("PLANE airborne after %.1f s at %.1f m/s", t, S.V)
        sc_note("d_takeoff", "liftoff_s", t)
        sc_end("d_takeoff")
        phase = "climb"
        for _, w in ipairs(vc.R2.wheels or {}) do vc.partAction(w.uid, "deployed.off") end
        sc_begin("d_low_flight")
        t0 = time
      end
      if t > 45 then P("PLANE no liftoff in 45 s (V %.1f)", S.V); sc_end("d_takeoff"); break end
    else
      -- hold ~35 m over the highest ground ahead, along the runway's great circle
      local ga2 = 0
      if S.Ng then
        local trk = unit(cross(S.Ng, S.U))
        for k2 = 1, 4 do
          local a = (k2 * 50) / S.b.radius
          local dir = unit({ x = S.U.x * math.cos(a) + trk.x * math.sin(a), y = S.U.y * math.cos(a) + trk.y * math.sin(a), z = S.U.z * math.cos(a) + trk.z * math.sin(a) })
          local o = { x = S.b.x + dir.x * (S.b.radius + 250), y = S.b.y + dir.y * (S.b.radius + 250), z = S.b.z + dir.z * (S.b.radius + 250) }
          local h = raycast(o.x, o.y, o.z, -dir.x, -dir.y, -dir.z, 600, vn)
          if h then ga2 = math.max(ga2, 250 - h.distance) end
        end
      end
      local h_t = math.max(ga + 30, ga2 + 30)
      local gam_t = clamp(0.04 * (h_t - S.alt), D(-6), D(10))
      local hud = S.hud or {}
      fly(S, gam_t + D(hud.aoa or 3), clamp(-1.4 * (S.herr or 0), D(-25), D(25)))
      if t > params.flysecs then break end
    end
  end
  if S then P("PLANE end: V %.1f alt %.0f agl %.0f", S.V, S.alt, S.agl) ; sc_note("d_low_flight", "agl_end", S.agl); sc_note("d_low_flight", "V_end", S.V) end
  sc_end("d_low_flight")
end

-- ── builder: 300 / 1,000 / 3,000 in the VAB, then launch ~1,000 ──────────────
local function lattice(N)
  local list, uid = {}, 0
  local cols = math.ceil(N / 10)
  local side = math.ceil(math.sqrt(cols))
  for c = 0, cols - 1 do
    local gx, gz = (c % side) * 1.5 - side * 0.75, math.floor(c / side) * 1.5 - side * 0.75
    local prev = 0
    for kk = 0, 9 do
      if uid >= N then break end
      uid = uid + 1
      list[#list + 1] = rec(uid, "beam1", gx, 0.5 + kk, gz, { parent = prev, att = prev ~= 0 and "top" or "" })
      prev = uid
    end
  end
  return list
end
-- a connected ~1,000-part craft: engine, a spine of tanks each ringed with 24 fins, a pod
local function finned_spine(T, F)
  local l, uid = { rec(1, "engineS", 0, 0.65 + 0.11, 0) }, 1
  local y = 1.3 + 0.11
  local prev = 1
  for k = 1, T do
    uid = uid + 1
    local tu = uid
    l[#l + 1] = rec(tu, "tankS", 0, y + 0.5, 0, { parent = prev, att = "top" })
    for f = 0, F - 1 do
      uid = uid + 1
      local a = f * 2 * math.pi / F
      local c, sn = math.cos(a), -math.sin(a)
      l[#l + 1] = rec(uid, "fins", c * 0.85, y + 0.5, sn * 0.85, { yaw = math.atan2(-sn, c), parent = tu, att = "radial", sym = k })
    end
    prev = tu
    y = y + 1.0
  end
  uid = uid + 1
  l[#l + 1] = rec(uid, "pod", 0, y + 0.4, 0, { parent = prev, att = "top" })
  return l
end

local function run_builder()
  local BH = enter_vab("g_enter")
  if not BH then return end
  local B = findScript("builder")
  wait(1.5)
  local function load_bp_g(name, list) load_bp(B, name, list) end
  for _, N in ipairs({ 300, 1000, 3000 }) do
    load_bp_g("g_load_" .. N, lattice(N))
    sc_begin("g_idle_" .. N); wait(4); sc_end("g_idle_" .. N)
    sc_begin("g_hand_" .. N)
    if B.pick then B.pick("beam1") end
    wait(4)
    tap("escape")
    sc_end("g_hand_" .. N)
    wait(0.5)
  end
  local craft = finned_spine(40, 24)
  load_bp_g("g_load_craft" .. #craft, craft)
  sc_begin("g_idle_craft"); wait(4); sc_end("g_idle_craft")
  if B.launchSite and B.launchSite() ~= "pad" and B.toggleLaunchSite then B.toggleLaunchSite() end
  sc_begin("g_launch_rollout")
  local w0 = W()
  B.doLaunch()
  wait(0.6)
  if BH.state == "building" then B.doLaunch() end
  local vc = wait_craft(#craft * 0.9, 150)
  sc_note("g_launch_rollout", "secs", W() - w0)
  sc_end("g_launch_rollout")
  if not vc then P("RESULT big launch: no craft"); return end
  local i = assembly.info(vc.node)
  P("BIG CRAFT on the pad: %d parts, %.1f t", #i.parts, i.mass)
  sc_begin("g_launch_pad"); wait(8); sc_end("g_launch_pad")
  -- The finned spine is too tall for its engine mount: with the real load
  -- model it crushes at the bottom on release, and the scenario would time a
  -- crash instead of a 1,000-part craft flying. Hold it together unless
  -- loads=1 asks for the crash (pressure limits still apply).
  if (params.loads or 0) == 0 and vc.physTune then vc.physTune.loads = false end
  sc_begin("g_launch_release")
  vc.releaseClamps()
  tap("z")
  wait(10)
  tap("x")
  sc_end("g_launch_release")
  -- ...and with the engine cut, how long until the craft (or what is left of
  -- it) rests: its root compound asleep.
  sc_begin("g_launch_settle")
  local ts = W()
  -- At rest = the root asleep (node.asleep) and physics, the craft's pieces
  -- included (it often breaks up on release), under 2 ms a frame for a
  -- second. The physics time is the engine's own per-frame figure.
  local root_slept, quiet, quiet_t, settled = nil, 0, nil, nil
  while W() - ts < params.sleepsecs do
    yield()
    local n = vc.node
    if not root_slept and n and n.valid ~= false and n.asleep then
      root_slept = W() - ts
      P("SETTLE root asleep %.1f s after the engine cut", root_slept)
    end
    local ph = (perf.ms and perf.frames) and (function()
      local f = perf.frames(1); f = f and f[#f]; return f and f.buckets and f.buckets.physics end)() or nil
    if ph then
      if ph < 2.0 then quiet = quiet + 1; quiet_t = quiet_t or (W() - ts) else quiet, quiet_t = 0, nil end
      if quiet >= 60 and not settled then
        settled = quiet_t
        P("SETTLE physics under 2 ms/frame from %.1f s after the engine cut", settled)
        wait(2)
        break
      end
    end
  end
  if not settled then P("SETTLE physics still over 2 ms/frame %.0f s after the engine cut (root asleep: %s)", params.sleepsecs, tostring(root_slept)) end
  sc_end("g_launch_settle")
end

-- ── sleep: what a resting craft costs, and what keeps it awake (0527/0531) ───
-- Every frame for `secs`: node.asleep, the wake reason (rc25 `assembly.info().wake`),
-- the craft's speed, and the engine's own physics / physicsStatic for that
-- frame (perf.frames). Prints the first sleep, a line every 5 s, and a
-- RESULT with physics before and after sleep.
local function watch_sleep(name, vn, secs, vc)
  sc_begin(name)
  local ts = W()
  local slept, slept_frame, frames, after = nil, nil, 0, 0
  local ph_b, phs_b, n_b, ph_a, phs_a, n_a = 0, 0, 0, 0, 0, 0
  local wakes = {}
  local last5 = -5
  local wake_now, v_now = "?", 0
  local rel0, drift, drift_max = nil, 0, 0   -- the craft's place on its planet: real creep or not
  while W() - ts < secs do
    yield()
    frames = frames + 1
    if not (vn and vn.valid) then P("SLEEP [%s] craft gone", name); break end
    local i = assembly.info(vn) or {}
    if i.com and home() then
      local rel = sub(i.com, home())
      rel0 = rel0 or rel
      drift = len(rel.x - rel0.x, rel.y - rel0.y, rel.z - rel0.z)
      drift_max = math.max(drift_max, drift)
    end
    local asleep = i.asleep or vn.asleep
    wake_now = tostring(i.wake or vn.wake or "n/a")
    v_now = i.vel and len(i.vel.x, i.vel.y, i.vel.z) or 0
    wakes[wake_now] = (wakes[wake_now] or 0) + 1
    local f = perf.frames and perf.frames(1)
    f = f and f[#f]
    local ph = f and f.buckets and f.buckets.physics or 0
    local phs = f and f.parts and f.parts.physicsStatic or 0
    if asleep then
      if not slept then
        slept, slept_frame = W() - ts, frames
        P("SLEEP [%s] asleep %.2f s after release (frame %d), wake %s, |v| %.3f", name, slept, frames, wake_now, v_now)
      end
      ph_a, phs_a, n_a = ph_a + ph, phs_a + phs, n_a + 1
    else
      ph_b, phs_b, n_b = ph_b + ph, phs_b + phs, n_b + 1
      if slept then after = after + 1 end   -- woke again
    end
    if W() - ts - last5 >= 5 then
      last5 = W() - ts
      P("SLEEP [%s] t=%.0f asleep %s wake %s |v| %.3f angVel %.3f drift %.3f m physics %.2f static %.2f carry %s", name, last5, tostring(asleep), wake_now, v_now,
        i.angVel and len(i.angVel.x, i.angVel.y, i.angVel.z) or 0, drift, ph, phs, i.carry and string.format("%.2f", len(i.carry.x or 0, i.carry.y or 0, i.carry.z or 0)) or "?")
      -- the plain props by the base (no script touches them): do THEY sleep on this planet?
      local pr = {}
      local function under(x, y, z, ex)
        local bb = home()
        if not bb then return "?" end
        local u = unit(sub({ x = x, y = y, z = z }, bb))
        local h = raycast(x + u.x * 0.5, y + u.y * 0.5, z + u.z * 0.5, -u.x, -u.y, -u.z, 6, ex)
        return h and ((h.node and h.node.name) or "terrain") .. string.format("@%.2f", h.distance or -1) or "nothing"
      end
      for _, nm in ipairs({ "PropCrate", "PropCan", "PropCone" }) do
        local n = find(nm)
        if n and n.valid then pr[#pr + 1] = string.format("%s asleep %s wake %s |v| %.3f on %s", nm, tostring(n.asleep), tostring(n.wake), len(n.vx or 0, n.vy or 0, n.vz or 0), under(n.x, n.y, n.z, n)) end
      end
      if i.com then pr[#pr + 1] = "craft on " .. under(i.com.x, i.com.y, i.com.z, vn) end
      if #pr > 0 then P("SLEEP [%s] props: %s", name, table.concat(pr, "; ")) end
      -- forcesleep=1: put it to sleep by hand at 10 s; whatever wakes it then is named
      if (params.forcesleep or 0) > 0 and last5 >= 10 and not FORCED then
        FORCED = true
        vn.asleep = true
        P("SLEEP [%s] forced asleep by script at t=%.0f: asleep now %s", name, last5, tostring(vn.asleep))
        yield()
        local i2 = assembly.info(vn) or {}
        P("SLEEP [%s] one frame after the forced sleep: asleep %s wake %s |v| %.3f", name, tostring(i2.asleep), tostring(i2.wake), i2.vel and len(i2.vel.x, i2.vel.y, i2.vel.z) or -1)
      end
    end
  end
  local wk = {}
  for k, v in pairs(wakes) do wk[#wk + 1] = { k, v } end
  table.sort(wk, function(a, b) return a[2] > b[2] end)
  local wl = {}
  for _, e in ipairs(wk) do wl[#wl + 1] = string.format("%s %d", e[1], e[2]) end
  P("RESULT [%s] SLEEP: %s; awake %d frames physics %.2f ms/frame (static %.2f); asleep %d frames physics %.2f (static %.2f); re-woke frames %d; wake reasons %s; drift on its planet %.3f m (max %.3f)",
    name, slept and string.format("asleep after %.2f s (frame %d)", slept, slept_frame) or string.format("NEVER asleep in %.0f s (%d frames), last wake %s |v| %.3f", secs, frames, wake_now, v_now),
    n_b, n_b > 0 and ph_b / n_b or 0, n_b > 0 and phs_b / n_b or 0, n_a, n_a > 0 and ph_a / n_a or 0, n_a > 0 and phs_a / n_a or 0, after, table.concat(wl, ", "), drift, drift_max)
  sc_note(name, "drift", drift)
  sc_note(name, "sleptAfter", slept or -1)
  sc_note(name, "physAwake", n_b > 0 and ph_b / n_b or 0)
  sc_note(name, "physAsleep", n_a > 0 and ph_a / n_a or 0)
  sc_note(name, "wake", wl[1] and wl[1][1] or "?")
  sc_end(name)
  return slept
end

-- ── the player's save: on foot, the meadow, the dig ─────────────────────────
local function walk_about(name, secs)
  -- W held, a strafe every 10 s to change the ground under foot
  sc_begin(name)
  local t0 = time
  while time - t0 < secs do
    if not HELD.w then key_down("w") end
    local k = math.floor((time - t0) / 10) % 2 == 0 and "d" or "a"
    local phase = (time - t0) % 10
    if phase < 1.0 then if not HELD[k] then key_down(k) end else if HELD.a then key_up("a") end; if HELD.d then key_up("d") end end
    yield()
  end
  release_all()
  sc_end(name)
end
local function run_foot()
  sc_pause("a_onfoot30")
  sc_begin("u_stand"); wait(params.standsecs); sc_end("u_stand")
  walk_about("u_walk", params.walksecs)
  if (params.usersave or 0) > 0 then ground96("settled (after the walk)") end
end

-- the grassiest spot about `dist` m from the base (any bearing)
local function find_meadow(dist)
  local b = home()
  local u, t1, t2, R = base_frame()
  local cl = findScript("climate")
  local best
  local census = {}
  for _, d in ipairs({ dist - 60, dist - 30, dist, dist + 30, dist + 60, dist + 100, dist + 140 }) do
    for k = 0, 23 do
      local ang = k * math.pi / 12
      local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang), z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
      local dir = dir_at(u, t, d, R)
      local gr = ground_r(b, dir.x, dir.y, dir.z, R + 150)
      if gr then
        local p = { x = b.x + dir.x * gr, y = b.y + dir.y * gr, z = b.z + dir.z * gr }
        local smp = cl and cl.sampleAt and cl.sampleAt(b.name, p.x, p.y, p.z)
        local wet = cl and cl.isUnderwater and cl.isUnderwater(p.x, p.y + 0.5, p.z)
        if smp and not wet then
          census[smp.biome or "?"] = (census[smp.biome or "?"] or 0) + 1
          local grassy = smp.biome == "grass" or smp.biome == "steppe" or smp.biome == "forest"
          -- grass first (the turf washes live under it), the nearest to `dist` of it
          local score = (grassy and 10 or 0) + (smp.density or 0) - math.abs(d - dist) / 100
          if not best or score > best.score then
            best = { dir = dir, r = gr, t = t, biome = smp.biome, flora = smp.density or 0, d = d, score = score, grassy = grassy }
          end
        end
      end
    end
  end
  local cs = {}
  for k, v in pairs(census) do cs[#cs + 1] = string.format("%s %d", k, v) end
  table.sort(cs)
  P("MEADOW census (%d m .. %d m, 24 bearings): %s", dist - 60, dist + 140, table.concat(cs, ", "))
  return best
end
local function stand_at(spot)
  local a, bb = astro(), home()
  a.x, a.y, a.z = bb.x + spot.dir.x * (spot.r + 1.0), bb.y + spot.dir.y * (spot.r + 1.0), bb.z + spot.dir.z * (spot.r + 1.0)
  a.vx, a.vy, a.vz = 0, 0, 0
end
local function run_meadow()
  sc_pause("a_onfoot30")
  wait_ready(90)
  local spot = find_meadow(params.meadow_m)
  if not spot then P("MEADOW: no spot found"); return end
  P("MEADOW: %s (flora %.2f, grassy %s) %d m from the base", tostring(spot.biome), spot.flora, tostring(spot.grassy), spot.d)
  sc_begin("u_meadow_arrive")
  stand_at(spot)
  wait(params.settle)
  sc_end("u_meadow_arrive")
  walk_about("u_meadow_walk", params.walksecs)
  if (params.usersave or 0) > 0 then ground96("settled (after the meadow)") end
end
local function run_digmeadow()
  sc_pause("a_onfoot30")
  wait_ready(90)
  local spot = find_meadow(params.meadow_m)
  if not spot then P("MEADOW: no spot found"); return end
  params.clicks = params.digclicks
  dig_at("u_dig_meadow", spot)
end

-- ── park: the rover, brakes on; bigpark: the 1,002-part craft, no throttle ──
local function brakes_on(vc)
  tap("b")
  wait(0.3)
  local E = findScript("electronics")
  local on = {}
  for _, w in ipairs(vc.R2 and vc.R2.wheels or {}) do
    local st = E and E.stateOf and E.stateOf(w.d) or {}
    on[#on + 1] = tostring(st.brakes)
  end
  P("PARK brakes: %s", table.concat(on, " "))
  if #on > 0 and on[1] ~= "true" then tap("b"); wait(0.3); P("PARK brakes (second tap): %s", tostring(E and E.stateOf and E.stateOf(vc.R2.wheels[1].d).brakes)) end
end
-- ── park dump=1 (card 0531): the braked rover's tyres and joints, its chassis
-- and two props by the base, tick by tick in the PLANET frame ───────────────
-- Everything positional is `node − space.body(planet)` read in the same tick;
-- nothing in world space is kept across ticks (the planet moves ~5.8 m a tick).
-- The sleeper's own measure is SLEEP_LINEAR_SPEED × dt = 0.05 / 60 = 0.83 mm
-- a tick (floptle-physics world.rs settle), so displacements print in mm.
local DUMP = nil   -- the live tick capture; fixedUpdate fills it and prints a line a tick
local function rb_line(n)
  local rb = n and n.valid and n:getcomponent("RigidBody")
  if not rb then return "no RigidBody" end
  return string.format("mass %.4f radius %.3f (world %.3f) half %.3f/%.3f/%.3f (world %.3f/%.3f/%.3f) shape %s friction %.2f restitution %.2f kinematic %s",
    rb.mass or -1, rb.radius or -1, rb.worldRadius or -1, rb.half_x or -1, rb.half_y or -1, rb.half_z or -1,
    rb.worldHalfX or -1, rb.worldHalfY or -1, rb.worldHalfZ or -1, tostring(rb.shape), rb.friction or -1, rb.restitution or -1, tostring(rb.kinematic))
end
local function child_named(n, name)
  if not (n and n.valid) then return nil end
  for _, c in ipairs(n:children()) do if c.name == name then return c end end
  return nil
end
local function nearest(name, p)
  local best, bd
  for _, n in ipairs(findAll(name) or {}) do
    if n.valid then
      local d = len(n.x - p.x, n.y - p.y, n.z - p.z)
      if not bd or d < bd then best, bd = n, d end
    end
  end
  return best, bd
end
-- the ground under a node along the planet's down: the hit, the distance from
-- the node's centre to it and the ground normal (nil when nothing is hit)
local function ground_under(n, extra)
  local b = home()
  if not (b and n and n.valid) then return nil end
  local u = unit(sub({ x = n.x, y = n.y, z = n.z }, b))
  local ig = { n }
  if extra then ig[#ig + 1] = extra end
  local h = raycast(n.x + u.x * 0.5, n.y + u.y * 0.5, n.z + u.z * 0.5, -u.x, -u.y, -u.z, 8, { ignore = ig })
  if not h then return nil end
  return h, (h.distance or 0) - 0.5, u
end
local function dump_prop_static(tag, n)
  if not (n and n.valid) then P("DUMP %s: none found", tag); return end
  local body = child_named(n, "Body")
  local i = assembly.info(n) or {}
  P("DUMP %s root: %s", tag, rb_line(n))
  P("DUMP %s Body: %s", tag, rb_line(body))
  P("DUMP %s assembly.info: mass %s grounded %s asleep %s wake %s |v| %.4f angVel %.4f; node.asleep %s node.wake %s", tag,
    tostring(i.mass), tostring(i.grounded), tostring(i.asleep), tostring(i.wake), i.vel and len(i.vel.x, i.vel.y, i.vel.z) or -1,
    i.angVel and len(i.angVel.x, i.angVel.y, i.angVel.z) or -1, tostring(n.asleep), tostring(n.wake))
  local up = n:worldUp()
  local h, dist, u = ground_under(n, body)
  if h then
    local nn = { x = h.nx, y = h.ny, z = h.nz }
    local cosang = dot({ x = up.x, y = up.y, z = up.z }, nn)
    local rb = n:getcomponent("RigidBody")
    local hy = rb and rb.worldHalfY or -1
    P("DUMP %s up (%.4f %.4f %.4f) vs ground normal (%.4f %.4f %.4f): %.2f deg; planet up·normal %.2f deg; ground %s at %.3f m below the centre (half_y %.3f: %s %.3f m), material %s", tag,
      up.x, up.y, up.z, nn.x, nn.y, nn.z, math.deg(math.acos(clamp(cosang, -1, 1))), math.deg(math.acos(clamp(dot(u, nn), -1, 1))),
      (h.node and h.node.name) or "terrain", dist, hy, dist < hy and "SUNK by" or "clear by", math.abs(hy - dist), tostring(h.material))
  else
    P("DUMP %s: nothing under it within 7.5 m", tag)
  end
end
local function dump_static(vc, vn)
  local info = assembly.info(vn) or {}
  local b = home()
  local c = info.com or { x = vn.x, y = vn.y, z = vn.z }
  local gx, gy, gz = space.gravity(c.x, c.y, c.z)
  local rel = sub(c, b)
  P("DUMP planet %s R %.1f mu %.4g: g at the rover %.4f m/s2 (mu/R^2 %.4f), altitude %.2f m over R, planet |v| %.2f m/s (%.3f m/tick)",
    b.name, b.radius, b.mu, len(gx or 0, gy or 0, gz or 0), b.mu / (b.radius * b.radius), len(rel.x, rel.y, rel.z) - b.radius,
    len(b.vx or 0, b.vy or 0, b.vz or 0), len(b.vx or 0, b.vy or 0, b.vz or 0) / 60)
  P("DUMP chassis assembly.info: mass %s parts %d grounded %s anchored %s asleep %s wake %s |v| %.4f angVel %.4f carry %.3f; node.asleep %s",
    tostring(info.mass), info.parts and #info.parts or -1, tostring(info.grounded), tostring(info.anchored), tostring(info.asleep), tostring(info.wake),
    info.vel and len(info.vel.x, info.vel.y, info.vel.z) or -1, info.angVel and len(info.angVel.x, info.angVel.y, info.angVel.z) or -1,
    info.carry and len(info.carry.x or 0, info.carry.y or 0, info.carry.z or 0) or -1, tostring(vn.asleep))
  P("DUMP chassis root: %s", rb_line(vn))
  -- how far from the world origin everything sits: f32 positions 4-8 km out
  -- have a 0.5-1 mm ulp, the floor of any per-tick displacement read here
  P("DUMP world origin: planet centre %.1f m away, rover %.1f m away (f32 ulp there %.2g m)", len(b.x, b.y, b.z), len(c.x, c.y, c.z), 2 ^ (math.floor(math.log(math.max(1, len(c.x, c.y, c.z))) / math.log(2)) - 23))
  local E = findScript("electronics")
  local tyres = {}
  for k, w in ipairs(vc.R2 and vc.R2.wheels or {}) do
    local t = w.tyre
    local st = E and E.stateOf and E.stateOf(w.d) or {}
    local c = w.cfg or {}
    local m = w.m or {}
    P("DUMP tyre %d (%s uid %s): Solar set otherAnchor (hull) (%.3f %.3f %.3f) r %.3f steer0 %.1f rs %s; wcfg spring %s damper %s motor %s brake %s friction %s; motor torque %s; brakes %s",
      k, tostring(t and t.valid and t.name), tostring(w.uid), w.cx or 0, w.cy or 0, w.cz or 0, w.r or -1, w.steer0 or 0, tostring(w.rs),
      tostring(c.spring), tostring(c.damper), tostring(c.motor), tostring(c.brake), tostring(c.friction), tostring(m.torque), tostring(st.brakes))
    if t and t.valid then
      tyres[#tyres + 1] = t
      P("DUMP tyre %d rigidbody: %s; grounded %s asleep %s wake %s |v| %.4f", k, rb_line(t), tostring(t.grounded), tostring(t.asleep), tostring(t.wake),
        len(t.vx or 0, t.vy or 0, t.vz or 0))
      local j = t:getcomponent("Joint")
      if j then
        P("DUMP tyre %d joint (engine): stiffness %.3f damping %.3f maxForce %.4f motor %s motorSpeed %.4f steer %.2f force %.5f position %.3f speed %.3f length %.3f limit %s broken %s (otherAnchor/axis: not readable from Lua, Solar's above)",
          k, j.stiffness or -1, j.damping or -1, j.maxForce or -1, tostring(j.motor), j.motorSpeed or -1, j.steer or -1, j.force or -1,
          j.position or -1, j.speed or -1, j.length or -1, tostring(j.limit), tostring(j.broken))
      else
        P("DUMP tyre %d joint: none (jointed %s)", k, tostring(w.jointed))
      end
      local h, dist = ground_under(t)
      local rb = t:getcomponent("RigidBody")
      local r = rb and rb.worldRadius or (w.r or 0)
      if h then
        P("DUMP tyre %d ground: %s at %.4f m below the centre (radius %.3f: %s %.4f m), normal (%.4f %.4f %.4f)", k, (h.node and h.node.name) or "terrain",
          dist, r, dist < r and "SUNK by" or "clear by", math.abs(r - dist), h.nx, h.ny, h.nz)
      else
        P("DUMP tyre %d ground: nothing within 7.5 m", k)
      end
    else
      P("DUMP tyre %d: no tyre node", k)
    end
  end
  return tyres
end
local function dump_park(vc, vn)
  P("DUMP ---- static, after 10 s parked and braked ----")
  local tyres = dump_static(vc, vn)
  local a = astro()
  local crate = nearest("PropCrate", a and a.valid and { x = a.x, y = a.y, z = a.z } or { x = vn.x, y = vn.y, z = vn.z })
  local can = crate and nearest("PropCan", { x = crate.x, y = crate.y, z = crate.z })
  P("DUMP props: PropCrate %s, PropCan %s beside it (%d crates, %d cans in the scene)", tostring(crate and crate.valid), tostring(can and can.valid),
    #(findAll("PropCrate") or {}), #(findAll("PropCan") or {}))
  dump_prop_static("PropCrate", crate)
  dump_prop_static("PropCan", can)
  P("DUMP ---- 120 ticks (2 s) in the planet frame; displacement per tick in mm (sleep threshold 0.83 mm/tick) ----")
  P("DUMP R columns: tick t planet_m chassis_com_dmm chassis_node_dmm tyre1..%d_dmm |v|mm/s asleep wake", #tyres)
  P("DUMP P columns: tick t crate_dmm crate_asleep crate_wake crate|v|mm/s can_dmm can_asleep can_wake can|v|mm/s")
  DUMP = { vn = vn, tyres = tyres, crate = crate, can = can, ticks = 120, n = 0, prev = {}, t0 = time }
  wait_for(function() return DUMP == nil end, 15, "the tick dump")
  DUMP = nil
  P("DUMP ---- end ----")
end
function fixedUpdate(node, dt)
  local D = DUMP
  if not D then return end
  local b = home()
  if not b then return end
  D.n = D.n + 1
  local function track(key, p)
    if not p then return "-" end
    local r = sub(p, b)
    local d = D.prev[key] and (len(r.x - D.prev[key].x, r.y - D.prev[key].y, r.z - D.prev[key].z) * 1000)
    D.prev[key] = r
    return d and string.format("%.2f", d) or "-"
  end
  local pstep = D.pprev and len(b.x - D.pprev.x, b.y - D.pprev.y, b.z - D.pprev.z) or 0
  D.pprev = { x = b.x, y = b.y, z = b.z }
  local vn = D.vn
  if vn and vn.valid then
    local i = assembly.info(vn) or {}
    local ty = {}
    for k, t in ipairs(D.tyres) do ty[k] = t.valid and track("t" .. k, { x = t.x, y = t.y, z = t.z }) or "gone" end
    P("DUMP R %3d %.3f %.3f %s %s %s %.1f %s %s", D.n, time - D.t0, pstep, track("com", i.com), track("node", { x = vn.x, y = vn.y, z = vn.z }),
      table.concat(ty, " "), i.vel and len(i.vel.x, i.vel.y, i.vel.z) * 1000 or -1, tostring(i.asleep), tostring(i.wake))
  end
  local function prop(key, n)
    if not (n and n.valid) then return "gone - - -" end
    return string.format("%s %s %s %.1f", track(key, { x = n.x, y = n.y, z = n.z }), tostring(n.asleep), tostring(n.wake), len(n.vx or 0, n.vy or 0, n.vz or 0) * 1000)
  end
  P("DUMP P %3d %.3f %s %s", D.n, time - D.t0, prop("crate", D.crate), prop("can", D.can))
  if D.n >= D.ticks then DUMP = nil end
end
local function run_park()
  local vc = launch_via_builder(ROVER, "runway", 6)
  if not vc then P("RESULT park: no craft"); return end
  local vn = vc.node
  vc.releaseClamps()
  wait(1.5)
  brakes_on(vc)
  local i = assembly.info(vn)
  local b = home()
  P("PARK rover released: %d parts, |v| %.3f, body |v| %.1f, anchored %s, asleep %s, wake %s", #i.parts, len(i.vel.x, i.vel.y, i.vel.z),
    len(b.vx or 0, b.vy or 0, b.vz or 0), tostring(i.anchored), tostring(i.asleep), tostring(i.wake))
  -- dump=1 (0531): after 10 s parked and braked, the tyres' joints and the
  -- planet-frame motion of everything, tick by tick, before the usual watch
  if (params.dump or 0) > 0 then wait(10); dump_park(vc, vn) end
  watch_sleep("s_park_rover", vn, params.parksecs, vc)
  -- does a drive command wake it, and does it move?
  key_down("w"); wait(2); key_up("w")
  local i2 = assembly.info(vn)
  P("PARK after W 2 s: asleep %s wake %s |v| %.2f", tostring(i2.asleep), tostring(i2.wake), len(i2.vel.x, i2.vel.y, i2.vel.z))
end
local function run_bigpark()
  local craft = finned_spine(40, 24)
  local vc = launch_via_builder(craft, "pad", #craft * 0.9)
  if not vc then P("RESULT bigpark: no craft"); return end
  local vn = vc.node
  local i = assembly.info(vn)
  P("BIG CRAFT on the pad: %d parts, %.1f t", #i.parts, i.mass)
  sc_begin("s_big_clamped"); wait(5); sc_end("s_big_clamped")
  if (params.loads or 0) == 0 and vc.physTune then vc.physTune.loads = false end
  vc.releaseClamps()
  watch_sleep("s_big_release", vn, params.sleepsecs, vc)
  P("BIG CRAFT after: %d vessel controllers live", #findScripts("vessel_controller"))
end

-- ── the gameplay smoke: one RESULT line a step ──────────────────────────────
local function smoke(step, ok, fmt, ...)
  P("RESULT SMOKE %s: %s — " .. fmt, step, ok and "PASS" or "FAIL", ...)
end
local function from_point(vn, p0)
  local i = assembly.info(vn)
  local b = home()
  local d = sub(sub(i.com, b), p0)
  return len(d.x, d.y, d.z)
end
local function recover_all(why)
  local n = 0
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.node and v.node.valid and v.recoverReady and v.recoverCraft then
      local ok = v.recoverReady()
      if ok then v.recoverCraft(); n = n + 1 end
    end
  end
  P("recovered %d craft (%s)", n, why)
  wait(2)
  return n
end
local function run_gameplay()
  -- a) the starter rocket to its apex, then a revert to launch. In the VAB:
  --    only an in-place launch keeps the flight record a revert needs.
  do
    local ok, err = pcall(function()
      local bp = rocket_bp(2)
      local vc = launch_in_vab(bp, "pad", #bp)
      if not vc then smoke("starter", false, "no craft from the in-VAB rollout"); return end
      local vn = vc.node
      STAGED, UP_LOCAL = nil, nil
      local S0 = body_state(vn)
      local fuel0 = vc.fuel or -1
      local vs = findScript("vessel_spawner")
      P("starter on the pad: %d parts, fuel %.1f, canRevert %s", #assembly.info(vn).parts, fuel0, tostring(vs and vs.canRevert and vs.canRevert()))
      wait(1)
      tap("z"); wait(0.3); tap("space"); wait(1)
      if assembly.info(vn).anchored then vc.releaseClamps() end
      local t0, apex = time, S0.alt
      while time - t0 < 150 do
        yield()
        if not vn.valid then break end
        local S = body_state(vn)
        apex = math.max(apex, S.alt)
        if time - t0 > 4 and S.vr < -0.5 then break end
      end
      tap("x")
      smoke("starter_apex", apex > S0.alt + 50 and time - t0 < 150, "apex %.0f m above the pad after %.1f s", apex - S0.alt, time - t0)
      -- the revert: the flight cleared, the craft back on the stand as rolled out
      local okr, why = vs.revertToLaunch()
      P("revert: %s %s", tostring(okr), tostring(why))
      local vc2 = wait_craft(#bp, 120)
      local old = (vn.valid and vc2 and vc2.node ~= vn) and #(assembly.info(vn) or { parts = {} }).parts or 0
      if vc2 then
        local i2 = assembly.info(vc2.node)
        local S2 = body_state(vc2.node)
        smoke("revert", okr and old == 0 and i2.anchored and math.abs(S2.alt - S0.alt) < 2 and math.abs((vc2.fuel or -2) - fuel0) < 0.5,
          "revert %s; %d old parts left; anchored %s; alt %.1f (was %.1f); fuel %.1f (was %.1f); %d parts", tostring(okr), old, tostring(i2.anchored), S2.alt, S0.alt, vc2.fuel or -2, fuel0, #i2.parts)
        -- the pad back to the crane, the crew back on foot
        local rr, rw = vc2.recoverReady()
        if rr then vc2.recoverCraft() else P("recover not ready: %s", tostring(rw)) end
        wait(3)
      else
        smoke("revert", false, "revert %s (%s): no craft on the stand afterwards; %d old parts left", tostring(okr), tostring(why), old)
      end
    end)
    if not ok then smoke("starter", false, "error %s", tostring(err)) end
  end
  -- b) an in-VAB rover rollout, driven 100 m
  do
    local ok, err = pcall(function()
      local a = astro()
      P("crew on foot: %s visible %s", tostring(a ~= nil), tostring(a and a.visible))
      local vc = launch_in_vab(ROVER, "runway", 6)
      if not vc then smoke("rover_rollout", false, "no craft from the in-VAB rollout"); return end
      local vn = vc.node
      local i = assembly.info(vn)
      smoke("rover_rollout", #i.parts == 6, "%d of 6 parts on the runway, anchored %s", #i.parts, tostring(i.anchored))
      vc.releaseClamps()
      wait(1)
      local p0 = sub(assembly.info(vn).com, home())
      sc_begin("k_rover_drive")
      local t0, far = time, 0
      key_down("w")
      while time - t0 < 60 do
        yield()
        far = math.max(far, from_point(vn, p0))
        if far >= 100 then break end
      end
      release_all()
      sc_end("k_rover_drive")
      smoke("rover_drive", far >= 100, "%.0f m from the release point in %.1f s", far, time - t0)
    end)
    if not ok then smoke("rover", false, "error %s", tostring(err)) end
  end
  -- c) the two-stage to orbit
  do
    local ok, err = pcall(function()
      local rs = findScript("research")
      for _, id in ipairs({ "tankM", "engineM", "skipper" }) do if rs and rs.grant then rs.grant(id, "probe") end end
      local bp = rocket_2stage()
      local vc = launch_via_builder(bp, "pad", #bp)
      if not vc then smoke("orbit", false, "no craft on the pad"); return end
      local phase, S = ascend(vc)
      local okp = phase == "orbit" and S and S.peri > 0 and S.apo < math.huge
      smoke("orbit", okp, "phase %s, apo %.0f peri %.0f alt %.0f fuel %.1f", tostring(phase), S and S.apo or -1, S and S.peri or -1, S and S.alt or -1, vc.fuel or -1)
    end)
    if not ok then smoke("orbit", false, "error %s", tostring(err)) end
  end
  -- d) the jet's take-off
  do
    local ok, err = pcall(function()
      run_plane()
      local r = RECS.d_takeoff
      smoke("plane_takeoff", r and r.notes.liftoff_s ~= nil, "liftoff %s s", tostring(r and r.notes.liftoff_s))
    end)
    if not ok then smoke("plane_takeoff", false, "error %s", tostring(err)) end
  end
  -- e) the 1,002-part rollout and release
  do
    local ok, err = pcall(function()
      recover_all("the pad for the big craft")
      local craft = finned_spine(40, 24)
      local vc = launch_via_builder(craft, "pad", #craft * 0.9)
      if not vc then smoke("big_rollout", false, "no craft on the pad"); return end
      local i = assembly.info(vc.node)
      smoke("big_rollout", #i.parts >= #craft * 0.9, "%d of %d parts, %.1f t, rollout %.1f s", #i.parts, #craft, i.mass, RECS.launch_load and (W() - RECS.launch_load.w0) or -1)
      if (params.loads or 0) == 0 and vc.physTune then vc.physTune.loads = false end
      vc.releaseClamps()
      local slept = watch_sleep("k_big_release", vc.node, params.sleepsecs, vc)
      smoke("big_release", vc.node.valid and #findScripts("vessel_controller") >= 1, "root asleep %s; %d craft live", slept and string.format("after %.1f s", slept) or "never", #findScripts("vessel_controller"))
    end)
    if not ok then smoke("big_release", false, "error %s", tostring(err)) end
  end
end

-- ── shot: the tools' marks for `floptle shot --after` (shotcase 1..4) ────────
--   1 the gravity gun aimed at a plant (its rim and glow, the foot ring, the motes)
--   2 the plant being pulled (amber, the tether to it)
--   3 a scattered rock aimed at
--   4 a loose prop held on the tether (its sag)
-- The probe arranges the view and holds it; the engine takes the picture.
local function run_shot()
  wait_ready(120)
  local a = astro()
  local tb = findScript("tool_belt")
  local cam = findScript("planet_camera")
  local ff, mf = findScript("flora_field"), findScript("mineral_field")
  if not (a and tb) then P("SHOT: no crew/tool_belt"); return end
  local case = math.floor(params.shotcase or 1)
  if case <= 2 then
    -- plants: the base clears its ground; go where they grow
    local spot = find_meadow(params.meadow_m)
    if spot then stand_at(spot); P("SHOT: at the %s %d m out", tostring(spot.biome), spot.d); wait(6) end
    a = astro()
  end
  local b = home()
  local up = unit(sub(a, b))
  local tgt, label
  if case == 3 then
    local best
    local function rocks_here()
      for _, rk in ipairs(mf and mf.rocksNear and mf.rocksNear(a.x, a.y, a.z, 150) or {}) do
        local d = len(rk.x - a.x, rk.y - a.y, rk.z - a.z)
        -- only what the gravity gun can pull: a stone, a boulder, a crystal
        local rec = mf.rockRecord and mf.rockRecord(rk)
        local kid = rec and rec.kind and rec.kind.id
        if (kid == "stone" or kid == "boulder" or kid == "crystal") and d > 3 and (not best or d < best.d) then
          best = { x = rk.x, y = rk.y, z = rk.z, d = d, r = rk.r, kind = kid }
        end
      end
    end
    rocks_here()
    if not best then
      -- none by the base: out where the ground is wilder
      local spot = find_meadow(params.meadow_m)
      if spot then stand_at(spot); wait(6); a = astro(); up = unit(sub(a, b)); rocks_here() end
    end
    if best then
      -- go and stand by it (it may be far): the rest of the setup walks 3.5 m short of it
      local _, t1 = base_frame()
      a.x, a.y, a.z = best.x + t1.x * 5.0 + up.x * 1.0, best.y + t1.y * 5.0 + up.y * 1.0, best.z + t1.z * 5.0 + up.z * 1.0
      a.vx, a.vy, a.vz = 0, 0, 0
      wait(3)
    end
    tgt, label = best, best and ("rock " .. tostring(best.kind) .. string.format(" r %.2f", best.r)) or "rock"
  elseif case == 4 then
    local best
    for _, nm in ipairs({ "PropCrate", "PropCan", "PropCone" }) do
      for _, n in ipairs(findAll(nm) or {}) do
        if n and n.valid then
          local d = len(n.x - a.x, n.y - a.y, n.z - a.z)
          if d > 2 and (not best or d < best.d) then best = { x = n.x, y = n.y, z = n.z, d = d, name = nm } end
        end
      end
    end
    tgt, label = best, best and best.name or "prop"
  else
    local best
    local _, t1, t2 = base_frame()
    -- the field settles its plants on a worker: ask again until one answers
    local tries = 0
    while not best and tries < 15 do
      tries = tries + 1
      a = astro(); up = unit(sub(a, b))
      for k = 0, 15 do
        local ang = k * math.pi / 8
        local d = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang), z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
        for _, reach in ipairs({ 6, 14, 25 }) do
          local p = ff and ff.nearestPlant and ff.nearestPlant(a.x + up.x * 0.8, a.y + up.y * 0.8, a.z + up.z * 0.8, d.x, d.y, d.z, reach, 0.2, 2.0)
          if p and p.height and p.height > 0.3 and (not best or p.height > best.height) then best = p end
          if best and best.height >= 2.5 then break end
        end
      end
      if not best then P("SHOT: no plant yet (try %d), props %s", tries, tostring((perf.counts() or {}).props)); wait(2) end
    end
    tgt, label = best, best and ("plant h " .. string.format("%.1f", best.height)) or "plant"
  end
  if not tgt then P("SHOT case %d: no %s found", case, label); return end
  -- the planet moves metres a tick: the target lives in its frame from here on
  local trel = sub(tgt, home())
  local theight = tgt.height
  local function target() return { x = home().x + trel.x, y = home().y + trel.y, z = home().z + trel.z, height = theight } end
  tgt = target()
  -- stand 3.5 m short of it, face it, aim at it
  local d = sub(tgt, a)
  d = sub(d, scl(up, dot(d, up)))
  d = unit(d)
  local dist = len(tgt.x - a.x, tgt.y - a.y, tgt.z - a.z)
  local srel = sub({ x = tgt.x - d.x * 3.5, y = tgt.y - d.y * 3.5, z = tgt.z - d.z * 3.5 }, b)
  local u2 = unit(srel)
  local gr = ground_r(b, u2.x, u2.y, u2.z, len(srel.x, srel.y, srel.z) + 3)
  if gr then srel = scl(u2, gr + 1.0) end
  local function place()
    local bb = home()
    a.x, a.y, a.z = bb.x + srel.x, bb.y + srel.y, bb.z + srel.z
    a.vx, a.vy, a.vz = 0, 0, 0
  end
  place()
  P("SHOT case %d: %s at %.1f m; standing 3.5 m short of it", case, label, dist)
  for _ = 1, 20 do yield(); place() end
  wait(1.0)
  if cam and cam.face then cam.face(d.x, d.y, d.z, -0.2) end
  local slot = nil
  for i, sl in ipairs(tb.belt()) do if sl.id == "gravgun" then slot = i end end
  tb.sim = { pressed = { [tostring(slot or 1)] = true } }
  wait(0.5)
  P("SHOT tool %s, gate %s, instanceTint %s", tostring(tb.toolId()), tostring(tb.gate), tostring(tb.INSTANCE_TINT))
  local hold = (case == 2 or case == 4)
  local t0 = time
  while true do
    local aa = astro()
    tgt = target()
    local eye = { x = aa.x + up.x * 0.6, y = aa.y + up.y * 0.6, z = aa.z + up.z * 0.6 }
    -- aim at the plant's body (a short sedge: a third of the way up, not past
    -- it into the ground), at a rock's or a crate's middle
    local lift = (case <= 2 and math.min(0.5, 0.35 * (tgt.height or 1))) or (case == 4 and -0.1) or 0.1
    local ax = { x = tgt.x + up.x * lift, y = tgt.y + up.y * lift, z = tgt.z + up.z * lift }
    -- the plant moves with its planet: re-aim from the planet frame
    local dd = sub(ax, eye)
    -- the trigger goes down only once the idle aim names the target (a grab
    -- fired at the ground beside a sedge reads "part of the ground")
    local pr = tostring(tb.prompt or "")
    if hold and not HOLD_ON and time - t0 > 0.5 and (case == 4 or pr:find("uproot", 1, true)) then HOLD_ON = true end
    tb.sim = { btn = { [0] = HOLD_ON == true }, aim = { eye.x, eye.y, eye.z, dd.x, dd.y, dd.z } }
    -- the camera on the thing: down at a held crate, level at a plant or rock
    if cam and cam.face then cam.face(d.x, d.y, d.z, case == 4 and -0.45 or -0.15) end
    if math.floor(time - t0) ~= math.floor(time - t0 - dt) then
      P("SHOT t=%.0f: tool %s, holding %s, strain %.2f, prompt %s", time - t0, tostring(tb.toolId()), tostring(tb.holding and tb.holding.name), tb.strain or -1, tostring(tb.prompt))
    end
    -- playshot=N: in a real `play`, photograph the game's camera N s into the
    -- hold (camera.capture, as F12 does) to user://screenshots, then quit
    if (params.playshot or 0) > 0 and time - t0 >= params.playshot and not SHOT_TAKEN and camera and camera.capture then
      SHOT_TAKEN = true
      local path = string.format("user://screenshots/perfshot_case%d.png", case)
      camera.capture({ w = 1280, h = 720, ui = true, draws = true }, function(bytes, why)
        if not bytes then P("SHOT capture failed: %s", tostring(why)); SHOT_DONE = true; return end
        local ok, err = assets.writeBytes(path, bytes)
        P("SHOT written %s: %s %s", path, tostring(ok), tostring(err))
        SHOT_DONE = true
      end)
    end
    if SHOT_DONE then wait(1); return end
    yield()
  end
end

-- ── main ────────────────────────────────────────────────────────────────────
local CO = nil
local MAIN = function()
  boot()
  if MODE == "base" then
    run_base()
  else
    after_boot_settle(4)
    if MODE == "quick" then run_quick()
    elseif MODE == "rocket" then run_rocket()
    elseif MODE == "plane" then run_plane()
    elseif MODE == "rover" then run_rover()
    elseif MODE == "builder" then run_builder()
    elseif MODE == "foot" then run_foot()
    elseif MODE == "meadow" then run_meadow()
    elseif MODE == "digmeadow" then run_digmeadow()
    elseif MODE == "park" then run_park()
    elseif MODE == "bigpark" then run_bigpark()
    elseif MODE == "gameplay" then run_gameplay()
    elseif MODE == "shot" then run_shot()
    else P("unknown mode %s", MODE) end
  end
  release_all()
  finish_all()
  P("DONE mode %s, perfbench own cost %.2f ms/frame", MODE, perf.scriptMs and perf.scriptMs("perfbench") or -1)
  if params.quit > 0 then app.quit() end
end

function update(node, dt)
  measure()
  if not CO then
    if save.slot() == "slot" .. math.floor(params.slot) and RECS.a_load == nil and FRAME > 1 then
      P("probe restarted (scene reload?)"); return
    end
    NODE = node
    MODE = params.mode or "base"
    CO = coroutine.create(MAIN)
  end
  if coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO)
    if not ok then P("ERROR %s", tostring(err)); finish_all(); if params.quit > 0 then app.quit() end end
  end
end
