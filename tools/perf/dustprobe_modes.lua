-- ── dust probe (tools/perf/dustprobe.sh): the wheel dust under a lit headlight ──
-- Spliced after jumpprobe_modes.lua (uses V.* and JP.*). Playtest 11-03c
-- (playtest-1103c/14.png): "vehicle driving particles are glowing extremely
-- bright when a light is on nearby" — the bike's Floodlight on at dusk, the
-- TyreDust trail behind it blown out to white.
--   vdust  (night = the sun's elevation to warp to first; 1.0: stay in the
--          day) the player's bike out past 95 m, then riding on loose ground
--          at ~8 m/s: the chase camera with the Floodlight off, then on.
-- `VP` lines; pictures <tag>_dust_off / _dust_on in $WORK/proj/save/user/vshots/.
local function run_vdust()
  V.tag = "dust"
  wait(3)
  local su = star_up(astro())
  local want = tonumber(params.night or 1.0)
  local t0 = W()
  if want < 0.99 and su > want then
    space.warp(tonumber(params.nwarp or 500))
    while W() - t0 < 120 do
      wait(0.25)
      su = star_up(astro())
      if space.warp() < 2 then space.warp(tonumber(params.nwarp or 500)) end
      if su < want then break end
    end
    space.warp(1)
    wait(2)
  end
  P("JP dust: sun elevation %.2f", star_up(astro()))
  local vc = JP.bike(want < 0.99 and "dusk" or "day")
  if not vc then return end
  local ok = V.out(vc, 95)
  -- off the paved runway (no dust off a hard surface: vehicle_fx W.hard):
  -- a quarter turn, then straight out onto the loose ground
  local t1 = time
  while time - t1 < 9.0 do
    local sp = V.speed(vc)
    vc.R2.cmd = { drive = clamp(0.3 + (7 - sp) * 0.3, 0, 1), steer = (time - t1 < 2.6) and 0.45 or 0.0 }
    yield()
  end
  P("JP dust: off the runway, %.1f m/s", V.speed(vc))
  local lamp
  local function scan(n, depth)
    for _, c in ipairs(n:children()) do
      if c.name == "Lamp" then lamp = c end
      if depth < 3 then scan(c, depth + 1) end
    end
  end
  scan(vc.node, 0)
  local function ride(secs, nm)
    local t1 = time
    while time - t1 < secs do
      local sp = V.speed(vc)
      vc.R2.cmd = { drive = clamp(0.3 + (8 - sp) * 0.3, 0, 1), steer = 0.05 }
      yield()
    end
    local c = perf.counts and perf.counts() or {}
    P("JP dust %s: speed %.1f m/s, particles %s", nm, V.speed(vc), tostring(c.particles))
    V.shot("dust_" .. nm, false)
    vc.R2.cmd = { drive = 0.4, steer = 0.0 }
  end
  ride(3.0, "off")
  tap("y")
  ride(2.5, "on")
  local pl = lamp and lamp:getcomponent("PointLight")
  P("JP lamp %s: intensity %s range %s", tostring(lamp ~= nil), tostring(pl and pl.intensity), tostring(pl and pl.range))
  V.check("lamp_on", pl and (pl.intensity or 0) > 0, "lamp intensity %s", tostring(pl and pl.intensity))
  vc.R2.cmd = { drive = 0, steer = 0 }
  V.result()
end
JP_RUN_EXTRA = { vdust = run_vdust }
