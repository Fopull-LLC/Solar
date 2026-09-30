-- GALAXY PROBE — a headless test rig for the galaxy streamer, and nothing else.
--
-- The real game reaches the galaxy through the save-slot flow (menu → slot →
-- game_manager.regenerate), which needs a player to press things and so cannot
-- be driven by `floptle run`. This script is the same sequence with the player
-- taken out: roll a home system, then walk the anchor straight out of it at a
-- chosen speed and report what the galaxy does about it.
--
-- It is a TEST FIXTURE. It lives in `scenes/galaxy_probe.ron` and nothing in
-- the shipped game references it.
--
--     floptle run . --scene galaxy_probe --seconds 90

defaults = {
  --- Metres per second the anchor travels outward. The point of the rig: at a
  --- high enough speed the ceiling should bite and the log should say so.
  --@range 100 5000000
  speed = 300000.0,
  --- Seconds to let the home system settle before moving.
  --@range 0 60
  settle = 4.0,
  --- How often to report, in seconds.
  --@range 0.5 30
  report = 5.0,
}

local rolled = false
local moved = 0.0
local t_report = 0.0
local anchor_node

function start(node)
  anchor_node = find("Astronaut")
  print("galaxy probe: rolling the home system…")
end

function update(node, dt)
  local gen = findScript("system_generator")
  if not gen then return end
  if not rolled then
    -- pregen = false: the home planet streams from its genspec on demand
    -- rather than blocking the rig for the seconds a full fill takes.
    gen.regenerate(1234, { pregen = false, planets = 4 })
    rolled = true
    print("galaxy probe: home is " .. tostring(gen.homeStar))
    return
  end
  if time < (params.settle or 4.0) then return end
  if not (anchor_node and anchor_node.valid) then
    anchor_node = find("Astronaut")
    if not anchor_node then return end
  end

  -- Straight out along +X. The galaxy hashes by sector, so a straight line
  -- crosses sector boundaries at a predictable rate and the build cadence is
  -- readable off the log.
  local step = (params.speed or 300000.0) * dt
  moved = moved + step
  anchor_node.x = anchor_node.x + step

  if time - t_report >= (params.report or 5.0) then
    t_report = time
    local gx = findScript("galaxy")
    if gx then
      print(string.format(
        "galaxy probe: %.2f Mm out — %d resident, %d built, warp ceiling %s%s",
        moved / 1e6, gx.resident or -1, gx.built or -1,
        tostring(gx.maxWarp()), gx.warpNote() and ("  (" .. gx.warpNote() .. ")") or ""))
      for _, s in ipairs(gx.systems()) do
        print(string.format("    %-18s %8.2f Mm", s.star, s.dist / 1e6))
      end
    end
  end
end
