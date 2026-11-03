-- ── cloudshots (tools/perf/cloudshot.sh): the weather map the clouds will read ──
-- mode "cloudshots": a fresh save, on foot at the base:
--   1 the GPU map against the Lua: shaders/weather_map.wgsl `probe` at 512
--     directions beside weather_map.lua fieldAt, the largest difference per
--     channel (must be < 0.01: they are one function written twice)
--   2 the weather where you stand is the map's there (weather.current())
--   3 the debug view, now and every 20 min of weather clock for 2 h, in
--     "all" and "type": pictures of the map moving
--   4 what the map costs on the GPU (perf.gpu "compute atlas")
local CS_DIR = "user://cloudshots/"
local function cs_shot(nm)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes(CS_DIR .. nm .. ".png", bytes); P("CS SHOT %s", nm) else P("CS SHOT %s failed %s", nm, tostring(why)) end
    done = true
  end)
  if ok then wait_for(function() return done end, 8, "shot " .. nm) else P("CS SHOT %s: capture refused", nm) end
end
local function run_cloudshots()
  wait_ready(120)
  local M = findScript("weather_map")
  local Wx = findScript("weather")
  if not (M and Wx) then P("CS no weather_map/weather"); return end
  if Wx.force then Wx.force(nil) end   -- perfbench holds the weather clear; let the map have it
  M.params.debug = true
  M.params.debugWidth = 960
  wait(3)
  local ctx = Wx.map_ctx
  P("CS world %s seed %s clock %.0f map %s", tostring(ctx and ctx.name), tostring(ctx and ctx.seed), ctx and ctx.clock or -1,
    M.map and (M.map.tex .. " " .. M.map.w .. "x" .. M.map.h) or "none")
  -- 1. GPU against Lua
  local sys, base = M.last_sys, M.last_base
  if sys and base and gpu and compute then
    local NP = 512
    local dirs = gpu.buffer { count = NP, type = "vec4" }
    local res = gpu.buffer { count = NP, type = "vec4" }
    local sb = gpu.buffer { count = (M.NS + M.NC) * 16, type = "f32" }
    local v, D = {}, {}
    for i, s in ipairs(sys) do
      local o = (i - 1) * 16
      local f = { s.cx, s.cy, s.cz, s.I, s.ex, s.ey, s.ez, s.rc, s.nx, s.ny, s.nz, s.len, s.cls, s.kind, s.hail, s.sgn }
      for k = 1, 16 do v[o + k] = f[k] end
    end
    if #v == 0 then v = { 0 } end
    sb:write(v)
    -- half the directions on a lattice, half at the systems (where the fronts are)
    for i = 0, NP - 1 do
      local x, y, z
      if i < NP / 2 or #sys == 0 then
        y = 1 - 2 * (i + 0.5) / (NP / 2); local r = math.sqrt(math.max(0, 1 - y * y)); local th = i * 2.39996
        x, z = r * math.cos(th), r * math.sin(th)
        if i >= NP / 2 then y = -y end
      else
        local s = sys[(i % #sys) + 1]
        local a, b = math.sin(i * 1.7) * 0.4, math.cos(i * 2.3) * 0.4
        x, y, z = s.cx + s.ex * a + s.nx * b, s.cy + s.ey * a + s.ny * b, s.cz + s.ez * a + s.nz * b
      end
      local l = math.sqrt(x * x + y * y + z * z)
      D[i + 1] = { x / l, y / l, z / l }
      dirs:write({ { x = x / l, y = y / l, z = z / l, w = 0 } }, i)
    end
    compute.run("shaders/weather_map.wgsl", "probe", { size = { NP }, bind = { sys = sb, dirs = dirs, res = res }, params = {
      n = #sys, count = NP, moist = base.moist, cover = base.cover, polar = base.polar, phase = base.phase, seed = 0 } })
    local got = nil
    res:read(function(vals) got = vals end)
    wait_for(function() return got ~= nil end, 10, "probe readback")
    if got then
      local md = { 0, 0, 0, 0 }
      for i = 1, NP do
        local f = M.fieldAt(sys, base, D[i][1], D[i][2], D[i][3])
        local g = got[i]
        local gx, gy, gz, gw
        if type(g) == "table" then gx, gy, gz, gw = g.x or g[1], g.y or g[2], g.z or g[3], g.w or g[4]
        else gx, gy, gz, gw = got[(i - 1) * 4 + 1], got[(i - 1) * 4 + 2], got[(i - 1) * 4 + 3], got[(i - 1) * 4 + 4] end
        md[1] = math.max(md[1], math.abs(gx - f.cov)); md[2] = math.max(md[2], math.abs(gy - f.typ))
        md[3] = math.max(md[3], math.abs(gz - f.dens)); md[4] = math.max(md[4], math.abs(gw - f.cir))
      end
      P("CS GPU vs LUA (%d dirs, %d systems): max |d| cov %.5f type %.5f dens %.5f cirrus %.5f %s", NP, #sys,
        md[1], md[2], md[3], md[4], (math.max(md[1], md[2], md[3], md[4]) < 0.01) and "OK" or "MISMATCH")
    else
      P("CS GPU readback: none")
    end
  else
    P("CS no systems/compute (sys %s base %s)", tostring(sys), tostring(base))
  end
  -- 2. here
  local c = Wx.current()
  if c then
    P("CS HERE %s: %s/%s I %.3f cover %.2f precip %.2f | map I %.3f cov %.2f type %.2f cirrus %.2f", c.body, c.type, c.state,
      c.intensity or -1, c.cover or -1, c.precip or -1, c.map and c.map.I or -1, c.map and c.map.cov or -1,
      c.map and c.map.typ or -1, c.map and c.map.cir or -1)
  end
  -- 3. pictures
  for k = 0, 6 do
    M.params.debugAhead = k * 1200
    M.params.debugMode = "all"
    wait(1.3)
    cs_shot(string.format("map_all_%03dmin", k * 20))
    if k % 3 == 0 then
      M.params.debugMode = "type"; wait(1.3); cs_shot(string.format("map_type_%03dmin", k * 20))
    end
  end
  M.params.debugAhead = 0
  M.params.debugMode = "all"
  -- 4. cost
  M.params.period = 0.0
  local g, n = 0, 0
  for _ = 1, 120 do
    yield()
    local ok, gg = pcall(perf.gpu)
    if ok and gg then
      for _, ps in ipairs(gg.passes or {}) do if tostring(ps.name):find("atlas") then g, n = g + ps.ms, n + 1 end end
    end
  end
  P("CS COST compute atlas: %.3f ms (%d samples, every frame; the game redraws once a second)", n > 0 and g / n or -1, n)
  M.params.period = 1.0
  M.params.debug = false
end
