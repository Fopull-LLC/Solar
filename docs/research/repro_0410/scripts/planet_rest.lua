-- 0410 repro, planet case: 200 colliding particles dropped beside the crew on
-- Solar's home planet (moving on rails). Prints the particle bucket before the
-- drop, while falling, and long after every particle has landed. On rc2 a
-- landed cloud keeps costing about 0.2 ms here, against 0.001 ms in rest0.ron.
local stage, t, fired, t_fire = 0, 0, false, 0
local win = { acc = 0, n = 0, worst = 0, live = 0 }
local function flush(label)
  if win.n > 0 then
    print(string.format("PLANETREST %-12s particles mean %.3f ms  worst %.3f  live %d  (%d frames)",
      label, win.acc / win.n, win.worst, win.live, win.n))
  end
  win.acc, win.n, win.worst, win.live = 0, 0, 0, 0
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

function lateUpdate(node, dt)
  if stage ~= 1 then return end
  t = t + dt
  local a = find("Astronaut")
  if not a then return end
  local bname = space.dominant(a.x, a.y, a.z)
  local b = bname and space.body(bname)
  if not b or t < 60 then return end
  win.acc = win.acc + perf.ms("particles"); win.n = win.n + 1
  win.worst = math.max(win.worst, perf.worstMs("particles"))
  win.live = math.max(win.live, (perf.counts().particles or 0))
  if not fired and t >= 70 then
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
    if since >= 3 and since < 3 + dt then flush("falling") end
    if since >= 13.9 then flush("landed 3-14s"); app.quit() end
  end
end
