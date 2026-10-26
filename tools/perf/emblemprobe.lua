-- EMBLEMPROBE: the agency emblem and flag generator in the engine
-- (tools/perf/emblemprobe.sh). On the main menu:
--
--   1. timing: for each of eight specs (every shape, a spread of motifs,
--      fonts and palettes), rasterEmblem + rasterFlag called straight through,
--      warm, the median of REPS; and the 96² slot-card emblem
--   2. pictures: each emblem and flag written to user://emblemshots/ as PNG
--   3. the NEW GALAXY panel: TWEAKS steps of the editor (shape, palette,
--      motif, font, ↻) a TWEAK_DT apart, every frame's length recorded, and
--      the same span idle before it for comparison
--
-- Lines "EMB ". Writes nothing to any save slot.
defaults = { ops = 1, slot = 14, reps = 5, tweaks = 24, tweak_dt = 0.25, quit = 1 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("EMB %7.2f " .. fmt, W() - W0, ...)) end
local CO
local function yield() coroutine.yield() end
local function wait_for(fn, tmo, what)
  local t = W() + (tmo or 60)
  while W() < t do local r = fn(); if r then return r end; yield() end
  P("TIMEOUT %s", what or "?")
end
local function hold(secs) local t = W() + secs; while W() < t do yield() end end

local CASES = {
  { "Solar Exploration Agency", "roundel", "orbit" },
  { "Kestrel Aerospace", "patch", "rocket" },
  { "Northern Lights Space Command", "patch", "star" },
  { "Orbital Dynamics & Freight", "shield", "planet" },
  { "Bluebird Rocketry", "hex", "swoosh" },
  { "Deep Sky Mining Co.", "chevron", "orbit" },
  { "Station 9", "square", "planet" },
  { "United Federation of Planets", "shield", "star" },
}

local function median(t) table.sort(t) return t[math.floor((#t + 1) / 2)] end

-- frame lengths, recorded by update
local frames = nil
local last_w = nil
function update(node, dt)
  local w = W()
  if frames and last_w then frames[#frames + 1] = (w - last_w) * 1000 end
  last_w = w
  if CO and coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO)
    if not ok then P("ERROR %s", tostring(err)); CO = nil; if params.quit == 1 and app.quit then app.quit() end end
  end
end

local function stats(fr)
  local s = {}
  for i, v in ipairs(fr) do s[i] = v end
  table.sort(s)
  local n = #s
  if n == 0 then return "none" end
  local over = function(x) local c = 0 for _, v in ipairs(s) do if v > x then c = c + 1 end end return c end
  return string.format("n=%d p50=%.1f p95=%.1f p99=%.1f max=%.1f >25ms=%d >50ms=%d >100ms=%d",
    n, s[math.floor(n * 0.5) + 1], s[math.min(n, math.floor(n * 0.95) + 1)], s[math.min(n, math.floor(n * 0.99) + 1)],
    s[n], over(25), over(50), over(100))
end

local function write_png(path, w, h, px)
  if not (image and image.fromPixels) then return end
  local img = image.fromPixels(w, h, px)
  assets.writeBytes(path, img:png())
end

local function run()
  NODE.persistent = true
  scene.load("menu")
  yield()
  local em = wait_for(function() return findScript("menu_newsave") and findScript("emblem") end, 30, "the menu")
  em = findScript("emblem")
  hold(1.0)
  P("engine %s", tostring(app.version and app.version() or "?"))
  -- ── 0: what each image.* call costs (256²) ──
  if params.ops == 1 then
    local function bench(name, n, fn)
      local t0 = W()
      for i = 1, n do fn(i) end
      P("OP %-34s %8.3f ms", name, (W() - t0) * 1000 / n)
    end
    local img = image.new(256, 256, 0.2, 0.3, 0.4, 1)
    local other = image.new(256, 256, 0.9, 0.1, 0.1, 0.5)
    local circ = {}
    for i = 0, 149 do local a = i * 2 * math.pi / 150; circ[#circ + 1] = 128 + math.cos(a) * 124; circ[#circ + 1] = 128 + math.sin(a) * 124 end
    bench("image.new 256²", 50, function() image.new(256, 256) end)
    bench("img:clear", 50, function() img:clear() end)
    bench("img:circle r124", 50, function() img:circle(128, 128, 124, 1, 0, 0, 1) end)
    bench("img:ring r120 w4", 50, function() img:ring(128, 128, 120, 4, 1, 0, 0, 1) end)
    bench("img:polygon 150-gon r124", 50, function() img:polygon(circ, 1, 0, 0, 1) end)
    bench("img:polygon tri small", 500, function() img:polygon({ 10, 10, 20, 10, 15, 20 }, 1, 0, 0, 1) end)
    bench("img:draw 256² 1:1", 50, function() img:draw(other, 0, 0) end)
    bench("img:fill 1 row", 2000, function(i) img:fill(0, i % 256, 100, 1, 0, 0, 0, 0) end)
    bench("img:line 10px w8", 500, function(i) img:line(50, 50, 60, 55, 8, 1, 1, 1, 1) end)
    bench("img:bytes 256²", 50, function() img:bytes() end)
    bench("image.fromPixels 256²", 50, function() image.fromPixels(256, 256, img:bytes()) end)
    bench("img:texture new 256²", 20, function() local t = image.new(256, 256):texture(); if t then assets.release(t) end end)
  end
  -- ── 1 + 2 ──
  local te, tf, ts = {}, {}, {}
  for i, c in ipairs(CASES) do
    local name = c[1]
    local s = em.specFor(name)
    s.shape, s.motif = c[2], c[3]
    if i % 3 == 0 then s.font = (s.font == "stencil") and "label" or "stencil" end
    local E, F, S = {}, {}, {}
    local px, fpx
    for r = 1, params.reps do
      local t0 = W()
      px = em.rasterEmblem(s, name)
      local t1 = W()
      fpx = em.rasterFlag(s, name, px)
      local t2 = W()
      local sp = em.rasterEmblem(s, name, 96)
      local t3 = W()
      E[r], F[r], S[r] = (t1 - t0) * 1000, (t2 - t1) * 1000, (t3 - t2) * 1000
      yield()
    end
    te[i], tf[i], ts[i] = median(E), median(F), median(S)
    P("case %d %-30s %-8s %-7s %-8s %-4s emblem %.2f ms  flag %.2f ms  small %.2f ms", i, name, s.shape, s.motif,
      s.font, s.mono, te[i], tf[i], ts[i])
    write_png(string.format("user://emblemshots/e%d.png", i), 256, 256, px)
    write_png(string.format("user://emblemshots/f%d.png", i), 512, 341, fpx)
  end
  em.PROF = {}
  for i, c in ipairs(CASES) do
    local s = em.specFor(c[1]); s.shape, s.motif = c[2], c[3]
    em.rasterEmblem(s, c[1])
  end
  local parts = {}
  for k, v in pairs(em.PROF) do parts[#parts + 1] = string.format("%s %.2f", k, v / #CASES) end
  table.sort(parts)
  P("PHASES per emblem (ms): %s", table.concat(parts, "  "))
  em.PROF = nil
  local function mean(t) local a = 0 for _, v in ipairs(t) do a = a + v end return a / #t end
  P("MEAN emblem %.2f ms  flag %.2f ms  small %.2f ms", mean(te), mean(tf), mean(ts))
  -- ── 3 ──
  local ns = findScript("menu_newsave")
  ns.openFor(math.floor(params.slot))
  hold(1.0)
  local ed = ns.editor()
  wait_for(function() return ed and ed.tex end, 15, "the preview")
  hold(1.0)
  local span = params.tweaks * params.tweak_dt + 1.0
  frames = {}
  hold(span)
  P("IDLE   %s", stats(frames))
  frames = {}
  local builds = {}
  local steps = { "shape", "pal", "motif", "font", "regen" }
  for i = 1, params.tweaks do
    local k = steps[(i - 1) % #steps + 1]
    if k == "regen" then
      ed.spec = em.regenerate(ed.spec, ed.name); ed.spec.mono = em.monogram(ed.name)
    else
      ed.spec = em.tweak(ed.spec, k, 1)
    end
    ed.tweaked = true; ed.dirty = true; ed.dirty_t = -1
    local before = ed.ms
    hold(params.tweak_dt)
    if ed.ms then builds[#builds + 1] = ed.ms end
  end
  hold(1.0)
  P("TWEAK  %s", stats(frames))
  frames = nil
  if #builds > 0 then P("preview build work: median %.1f ms max %.1f ms (%d builds)", median(builds), builds[#builds], #builds) end
  P("DONE")
  if params.quit == 1 and app.quit then app.quit() end
end

function start(node)
  NODE = node
  CO = coroutine.create(run)
end
