-- SLOWRAY — the slow script raycasts, one call at a time (perf2 2026-11-11).
-- Spliced after framemon.lua (and scnact.lua) by scnprobe.sh:
--   EXTRA_LUA="tools/perf/framemon.lua tools/perf/scnact.lua tools/perf/slowray.lua"
-- It sets RAY_HOOK on graphics (the subject ray) and planet_camera (the roof
-- ray); each times its own cast and hands it here. A call over sr_ms
-- (default 5) is logged:
--   SR RAY <tag> <ms> body <name> local (x,y,z) |o| <m> dir (x,y,z) max <m>
--          hit <node> at <m> | miss · counts (the frame before) …
--   SR CNT <tag> frame … (perf.counts() read in the next frame: the call's own)
-- Also every frame a watched script (sr_watch, default "emblem") spends over
-- 5 ms, in play or at load, with its sampled lines (fm_sample=1 names them):
--   SR WATCH <script> <ms> (frame <ms>) · lines … · calls …
local SR = { n = 0, pend = {}, last = 0, hooked = {}, wn = 0 }
local function sr_counts()
  local c = perf.counts and perf.counts() or {}
  return string.format("queryDeferred %s queryMeshed %s queryMeshMs %.2f rays %s rayMs %.2f sweeps %s sweepMs %.2f",
    tostring(c.queryDeferred), tostring(c.queryMeshed), tonumber(c.queryMeshMs) or -1, tostring(c.rays),
    tonumber(c.rayMs) or -1, tostring(c.sweeps), tonumber(c.sweepMs) or -1)
end
local function sr_hook(tag, ms, o, d, m, hit)
  SR.all = (SR.all or 0) + 1
  SR.sum = SR.sum or {}
  local s = SR.sum[tag] or { n = 0, ms = 0, max = 0, over = 0 }
  SR.sum[tag] = s
  s.n, s.ms = s.n + 1, s.ms + ms
  if ms > s.max then s.max = ms end
  local lim = tonumber(params.sr_ms or 5) or 5
  if ms <= lim then return end
  s.over = s.over + 1
  if SR.n >= 60 then return end
  SR.n = SR.n + 1
  local ox, oy, oz = o.x or o[1], o.y or o[2], o.z or o[3]
  local bn = space.dominant and space.dominant(ox, oy, oz)
  local b = bn and space.body(bn)
  local lx, ly, lz = ox - (b and b.x or 0), oy - (b and b.y or 0), oz - (b and b.z or 0)
  local r = math.sqrt(lx * lx + ly * ly + lz * lz)
  local hs = "miss"
  if hit then
    local nd = hit.node
    local nm = nd and (nd.name or tostring(nd.id)) or "?"
    hs = string.format("hit %s at %.2f m", tostring(nm), hit.distance or -1)
  end
  P("SR RAY %s %.2f ms body %s local (%.1f, %.1f, %.1f) |o| %.1f m (alt %.1f) dir (%.3f, %.3f, %.3f) max %.1f %s · counts (prev frame) %s",
    tag, ms, tostring(bn), lx, ly, lz, r, r - (b and b.radius or 0), d.x or d[1], d.y or d[2], d.z or d[3], m, hs, sr_counts())
  SR.pend[#SR.pend + 1] = { tag = tag, t = time, ms = ms }
end
local SR_tick0 = MON_tick
function MON_tick()
  if SR_tick0 then SR_tick0() end
  if not perf.enabled() then return end
  for _, nm in ipairs({ "graphics", "planet_camera" }) do
    local s = SR.hooked[nm]
    if not (s and s.valid ~= false and s.RAY_HOOK == sr_hook) then
      s = findScript(nm, { quiet = true })
      if s then s.RAY_HOOK = sr_hook; SR.hooked[nm] = s end
    end
  end
  -- the call's own frame's counts, one frame on
  if #SR.pend > 0 then
    local keep = {}
    for _, e in ipairs(SR.pend) do
      if time > e.t then P("SR CNT %s %.2f ms · counts (its frame) %s", e.tag, e.ms, sr_counts()) else keep[#keep + 1] = e end
    end
    SR.pend = keep
  end
  -- the watched scripts' slow frames (load included)
  local watch = {}
  for w in tostring(params.sr_watch or "emblem"):gmatch("[^,]+") do watch[w] = true end
  for _, f in ipairs(perf.frames(4) or {}) do
    if f.frame and f.frame > SR.last then
      SR.last = f.frame
      for _, e in ipairs(f.scripts or {}) do
        if watch[e.name] and (e.ms or 0) > 5 and SR.wn < 80 then
          SR.wn = SR.wn + 1
          local ln = {}
          for _, q in ipairs(f.samples or {}) do
            if q.script == e.name then local k = string.format("%s:%s", q.fn or "?", tostring(q.line)); ln[#ln + 1] = { k, q.ms or 0 } end
          end
          table.sort(ln, function(a, b) return a[2] > b[2] end)
          local o = {}
          for i = 1, math.min(8, #ln) do o[#o + 1] = string.format("%s %.1f", ln[i][1], ln[i][2]) end
          local cl = {}
          for _, q in ipairs(f.calls or {}) do if q.script == e.name then cl[#cl + 1] = string.format("%s %.1f", tostring(q.call), q.ms or 0) end end
          P("SR WATCH %s %.1f ms (frame %.1f) · lines %s · calls %s", e.name, e.ms, f.ms, table.concat(o, ", "), table.concat(cl, ", "))
        end
      end
    end
  end
end
local SR_total0 = MON_total
function MON_total()
  if SR_total0 then SR_total0() end
  for tag, s in pairs(SR.sum or {}) do
    P("SR SUM %s calls %d mean %.3f ms max %.2f over %d", tag, s.n, s.ms / math.max(1, s.n), s.max, s.over)
  end
end
