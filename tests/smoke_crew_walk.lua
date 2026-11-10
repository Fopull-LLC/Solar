-- SMOKE: crew_body's path finder (graveyard2): the A* over the walker's own
-- 0.25 m grid, asked cell by cell, and the route pulled straight. Pure: the
-- cells come from a map here, not the physics world.
--
--   luajit solar/tests/smoke_crew_walk.lua
local failures, passed = {}, 0
local function check(ok, msg) if ok then passed = passed + 1 else failures[#failures + 1] = msg end return ok end
local E = setmetatable({ time = 0, findScript = function() return nil end, findScripts = function() return {} end }, { __index = _G })
local f = assert(loadfile("solar/scripts/crew_body.lua"))
setfenv(f, E)
f()

-- a room 4 m x 4 m (cells -8..8), a wall across it at j = 4 with a door gap at i = -1..1
local function room(door)
  return function(i, j)
    if math.abs(i) > 8 or math.abs(j) > 8 then return false end
    if j == 4 and not (door and i >= -1 and i <= 1) then return false end
    return true
  end
end
local asked = 0
local function counting(fr) return function(i, j) asked = asked + 1; return fr(i, j) end end

-- through the door: start (0,0) → goal (-6, 7) beyond the wall
do
  asked = 0
  local P = E.newPlan(-6, 7, 1, 1800)
  local st, n = "run", 0
  repeat st = E.planStep(P, counting(room(true)), 24); n = n + 1 until st ~= "run" or n > 500
  check(st == "done" and P.reached, "a route through the door: " .. tostring(st))
  local through = false
  for _, c in ipairs(P.cells or {}) do if c[2] == 4 then through = c[1] >= -1 and c[1] <= 1 end end
  check(through, "the route crosses the wall in the door's gap")
  local pts = E.pullStraight(P, room(true))
  check(#pts >= 2 and #pts <= 5, "pulled straight to a few corners: " .. #pts)
  -- every pulled leg is clear of the wall
  local prev, clear = { 0, 0 }, true
  for _, c in ipairs(pts) do
    for s = 1, 19 do
      local t = s / 20
      local i, j = math.floor(prev[1] + (c[1] - prev[1]) * t + 0.5), math.floor(prev[2] + (c[2] - prev[2]) * t + 0.5)
      if not room(true)(i, j) then clear = false end
    end
    prev = c
  end
  check(clear, "no pulled leg crosses the wall")
  check(asked < 400, "cells asked: " .. asked .. " (lazily, under 400)")
  check(n > 1, "spread over ticks on a budget (" .. n .. " steps of 24)")
end

-- no door: the nearest reachable cell, still "done" but not reached
do
  local P = E.newPlan(-6, 7, 1, 1800)
  local st, n = "run", 0
  repeat st = E.planStep(P, room(false), 64); n = n + 1 until st ~= "run" or n > 500
  check(st == "done" and P.reached == false, "no way through: the nearest cell (" .. tostring(st) .. ", reached " .. tostring(P.reached) .. ")")
  local last = P.cells[#P.cells]
  check(last and last[2] == 3, "it stops against the wall: j " .. tostring(last and last[2]))
end

-- the straight case: nothing in the way, one leg
do
  local P = E.newPlan(5, 3, 1, 1800)
  local st
  repeat st = E.planStep(P, function() return true end, 24) until st ~= "run"
  local pts = E.pullStraight(P, function() return true end)
  check(st == "done" and #pts == 1, "open floor: one straight leg (" .. #pts .. ")")
end

-- a cap on the cells asked: an endless open plain gives up on the nearest
do
  local P = E.newPlan(400, 0, 1, 300)
  local st
  repeat st = E.planStep(P, function(i, j) return not (i == 3 and math.abs(j) < 200) end, 50) until st ~= "run"
  check(P.evals <= 310 and st == "done" and not P.reached, "capped at 300 cells: " .. P.evals)
end

-- a corner is never cut diagonally
do
  local fr = function(i, j) return not (i == 1 and j == 0) and not (i == 0 and j == 1) or (i == 0 and j == 0) end
  local P = E.newPlan(1, 1, 0, 200)
  local st
  repeat st = E.planStep(P, fr, 24) until st ~= "run"
  local direct = P.cells and #P.cells == 2
  check(not direct, "a diagonal past two blocked cells is not taken")
end

if #failures > 0 then
  for _, m in ipairs(failures) do print("FAIL " .. m) end
  print(string.format("smoke_crew_walk: %d passed, %d failed", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_crew_walk: %d passed, 0 failed", passed))
