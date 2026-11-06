-- station_bench.lua — the Tracking Station's map pass in luajit, deterministic:
-- tests/smoke_tracking.lua's fleet (60 craft, 3 crew, 200 debris, relays,
-- flags, a structure) and its stubs, with a camera.worldToScreen that costs
-- what the engine's does (~3 µs a call: the 2026-11-05 probe measured 0.53 ms
-- for ~180 calls), a pinhole the station's Lua camera can match, and a view
-- that turns. A/B two versions of the station on the same machine in one go:
--
--   cd <dir holding solar/> && luajit solar/tools/perf/station_bench.lua [root]
--     root: the tree whose scripts/tracking_station.lua, fleet_view.lua and
--     map_labels.lua to load (default "solar"); the stubs come from solar/tests.
--
-- Prints the mean ms a frame of drawMap and of update over 1200 frames.
local root = arg and arg[1] or "solar"
local src = assert(io.open("solar/tests/smoke_tracking.lua")):read("*a")
local cut = src:find('TS.start%(NODES%["Tracking Station"%]%)')
src = src:sub(1, cut - 1)
src = src:gsub('"solar/scripts/fleet_view.lua"', '"' .. root .. '/scripts/fleet_view.lua"')
src = src:gsub('"solar/scripts/map_labels.lua"', '"' .. root .. '/scripts/map_labels.lua"')
src = src:gsub('"solar/scripts/tracking_station.lua"', '"' .. root .. '/scripts/tracking_station.lua"')
src = src .. [[
return { TS = TS, env = env, tick = tick, set_t = function(v) T = v end, get_t = function() return T end }
]]
local H = assert(loadstring(src))()
local TS, env = H.TS, H.env
local clock = os.clock
-- the engine's call: a pinhole at `cam` looking at the origin, ~3 µs
local TANH = math.tan(0.35)
local cam = { x = 0, y = 0, z = 4000 }
local function spin(us) local t = clock() + us * 1e-6 while clock() < t do end end
local calls = 0
env.camera.worldToScreen = function(x, y, z)
  calls = calls + 1
  spin(3)
  local dx, dy, dz = x - cam.x, y - cam.y, z - cam.z
  -- camera axes for a view from cam towards the origin, no roll
  local fl = math.sqrt(cam.x ^ 2 + cam.y ^ 2 + cam.z ^ 2)
  local fx, fy, fz = -cam.x / fl, -cam.y / fl, -cam.z / fl
  local rx, rz = -fz, fx
  local rl = math.sqrt(rx * rx + rz * rz); rx, rz = rx / rl, rz / rl
  local ux, uy, uz = -rz * fy, rz * fx - rx * fz, rx * fy
  local d = dx * fx + dy * fy + dz * fz
  if d <= 0 then return 0, 0, d, false end
  local f = 900 / (2 * TANH)
  local sx, sy = 800 + f * (dx * rx + dz * rz) / d, 450 - f * (dx * ux + dy * uy + dz * uz) / d
  return sx, sy, d, sx >= 0 and sx <= 1600 and sy >= 0 and sy <= 900
end
env.camera.screenRect = function() return 0, 0, 1600, 900 end
TS.start({ name = "Tracking Station", valid = true, getcomponent = function() return { visible = false } end })
TS.open()
local function ctx()
  return { bodies = env.space.bodies(), px_at = function(_, _, _, px) return px end,
           ppu = function(d) return 900 / (2 * TANH * d) end, cam = { x = cam.x, y = cam.y, z = cam.z },
           look = { x = 0, y = 0, z = 0 }, tanh = TANH, lk = 1.25, sw = 1600, sh = 900, placed = {}, blocked = {},
           yaw = math.atan2(cam.x, cam.z), pitch = 0, ppuFocus = 900 / (2 * TANH * 4000),
           show = { orbits = true, markers = false }, drawTrack = function() end,
           TRAJ = { track = function() return {} end }, cine = false }
end
TS.selectCraft("c1")
for _ = 1, 30 do H.tick(1 / 60); TS.drawMap(ctx()) end   -- warm: the snapshot, the JIT
local N = 1200
local dm, up = 0, 0
calls = 0
for i = 1, N do
  local a = i * 0.002                       -- the view turns slowly round the world
  cam.x, cam.z = 4000 * math.sin(a), 4000 * math.cos(a)
  H.set_t(H.get_t() + 1 / 60)
  local t0 = clock()
  H.tick(1 / 60)
  local t1 = clock()
  TS.drawMap(ctx())
  local t2 = clock()
  up, dm = up + (t1 - t0), dm + (t2 - t1)
end
print(string.format("%s: drawMap %.3f ms, update %.3f ms a frame (%.1f engine projections a frame; mode %s)",
  root, dm / N * 1000, up / N * 1000, calls / N, tostring(TS.proj and TS.proj.mode or "single")))
