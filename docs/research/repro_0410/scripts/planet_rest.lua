-- 0410 repro, planet case: 200 colliding particles dropped beside the crew on
-- Solar's home planet (moving on rails). Prints the particle bucket before the
-- drop, while falling, and after every particle has landed. On rc2 a landed
-- cloud kept costing about 0.2 ms here while terrain was still streaming,
-- against 0.001 ms in rest0.ron.
--
-- Params (scene file, all optional):
--   warm    seconds after the save loads before the "before" window opens (60)
--   dropAt  seconds after the save loads when the cloud is dropped (70);
--           a small value (10) drops it while the terrain is still streaming
--   walk    1 = from 3 s after the drop the crew strafes back and forth
--           through and beside the cloud (planet_walker.steer), so a moving
--           collider and the terrain around it keep changing next to it
defaults = { warm = 60.0, dropAt = 70.0, walk = 0 }

local stage, t, fired, t_fire = 0, 0, false, 0
local win = { acc = 0, n = 0, live = 0, terr = 0, max = 0, hot = 0 }
local next_flush = nil
local function flush(label)
  if win.n > 0 then
    print(string.format("PLANETREST %-14s particles mean %.3f ms  max %.3f  >0.1ms %d frames  live %d  terrain %.3f ms  (%d frames)",
      label, win.acc / win.n, win.max, win.hot, win.live, win.terr / win.n, win.n))
  end
  win.acc, win.n, win.live, win.terr, win.max, win.hot = 0, 0, 0, 0, 0, 0
end

function update(node, dt)
  if stage == 0 then
    stage = 1
    node.persistent = true
    perf.enable(true)
    save.deleteSlot("slot9"); save.slot("slot9")
    save.set("g_seed", 1911564384)
    scene.load("system")
  end
end

local walker = nil
local function steer(f, s)
  if not (walker and walker.valid) then walker = findScript("planet_walker") end
  if walker and walker.steer then walker.steer(f, s) end
end

function lateUpdate(node, dt)
  if stage ~= 1 then return end
  t = t + dt
  local a = find("Astronaut")
  if not a then return end
  local bname = space.dominant(a.x, a.y, a.z)
  local b = bname and space.body(bname)
  if not b or t < (params.warm or 60) then return end
  local pm = perf.ms("particles")
  win.acc = win.acc + pm; win.n = win.n + 1
  win.max = math.max(win.max, pm)
  if pm > 0.1 then win.hot = win.hot + 1 end
  win.live = math.max(win.live, (perf.counts().particles or 0))
  win.terr = win.terr + (perf.ms("terrain") or 0)
  if not fired and t >= (params.dropAt or 70) then
    flush("before")
    -- 2 m beside the crew, 1 m up, on the planet's up.
    local ux, uy, uz = a.x - b.x, a.y - b.y, a.z - b.z
    local l = math.sqrt(ux * ux + uy * uy + uz * uz)
    ux, uy, uz = ux / l, uy / l, uz / l
    local sx, sy, sz = uy, -ux, 0
    local sl = math.max(1e-6, math.sqrt(sx * sx + sy * sy))
    spawnEffect("vfx/Rest200", vec3(a.x + 2 * sx / sl + ux, a.y + 2 * sy / sl + uy, a.z + uz),
      { normal = vec3(ux, uy, uz) })
    fired, t_fire = true, t
    return
  end
  if fired then
    local since = t - t_fire
    if since >= 3 and since < 3 + dt then flush("falling"); next_flush = 5 end
    if (params.walk or 0) >= 1 and since >= 3 and since < 12 then
      -- Strafe 1.2 s each way: a few metres through and past the cloud.
      steer(0, (math.floor((since - 3) / 1.2) % 2 == 0) and 1 or -1)
    elseif (params.walk or 0) >= 1 and since >= 12 then
      steer(nil)
    end
    if next_flush and since >= next_flush then
      flush(string.format("landed %d-%ds", next_flush - 2, next_flush))
      next_flush = next_flush + 2
      if next_flush > 14 then next_flush = nil; save.deleteSlot("slot9"); app.quit() end
    end
  end
end
