-- ── stale-handle probe (tools/perf/staleprobe.sh): a handle kept from a node that is gone (engine card 0552) ──
-- tool_belt.knockLoose (what the laser's mining does) knocks rocks loose:
-- tool_belt keeps them, and the oldest goes when the list is full. Every chunk is then taken away as a stow or the depot
-- would (destroyed, still in tool_belt's list), a batch of marker nodes is made
-- so the freed slots are handed on, and more are knocked loose until the
-- old entries have all been evicted. A marker made in a destroyed chunk's slot
-- (same id) must still be there: before the fix the eviction destroyed it.
local function sp_chunks()
  local o = {}
  for _, n in ipairs(findTagged("loose_rock") or {}) do
    if n.valid and (n.name or ""):sub(1, 9) == "LooseRock" then o[#o + 1] = n end
  end
  return o
end
-- knock `n` chunks loose 3 m in front of the crew, a frame apart
local function sp_knock(knock, n)
  local a, bb = astro(), home()
  for _ = 1, n do
    local up = unit(sub(a, bb))
    knock(a.x + up.x * 1.5 + 3, a.y + up.y * 1.5, a.z + up.z * 1.5, up.x, up.y, up.z, "regolith")
    yield(); yield()
  end
  wait(1.0)
end
local function run_stale()
  wait_ready(90)
  local tb = findScript("tool_belt")
  if not (tb and tb.params) then P("SP RESULT: FAIL (no tool_belt)"); return end
  local knock = tb.knockLoose
  P("SP tool_belt rocks_max %s, knockLoose %s", tostring(tb.params.rocks_max), knock and "there" or "MISSING")
  if not knock then P("SP RESULT: FAIL (no knockLoose)"); return end
  sp_knock(knock, 4)
  local first = sp_chunks()
  local names = {}
  for _, n in ipairs(first) do names[#names + 1] = n.name .. "#" .. n.id end
  P("SP knocked loose: %d chunk(s): %s", #first, table.concat(names, " "))
  if #first == 0 then P("SP RESULT: FAIL (no chunk knocked loose)"); return end
  -- taken away (a stow, the depot): destroyed, and nobody tells tool_belt
  local gone = {}
  for _, n in ipairs(first) do gone[n.id] = n.name; n:destroy() end
  yield(); yield()
  -- new nodes: some are made in the freed slots
  local markers, made = {}, 0
  for i = 1, 60 do
    createNode("Stale Marker " .. i, function(n) markers[#markers + 1] = n; made = made + 1 end)
  end
  wait_for(function() return made >= 60 end, 10, "the markers")
  local reused = {}
  for _, m in ipairs(markers) do if gone[m.id] then reused[#reused + 1] = m end end
  local rn = {}
  for _, m in ipairs(reused) do rn[#rn + 1] = string.format("%s in %s's slot %d", m.name, gone[m.id], m.id) end
  P("SP %d of %d freed slot(s) handed to markers: %s", #reused, #first, table.concat(rn, ", "))
  -- more chunks: the old entries are evicted
  sp_knock(knock, 8)
  wait(1.0)
  local now = sp_chunks()
  local lost = 0
  for _, m in ipairs(reused) do
    local okm = m.valid and (m.name or ""):sub(1, 12) == "Stale Marker"
    P("SP marker %s (slot %d): %s", tostring(okm and m.name or "?"), m.id, okm and "still there" or "DESTROYED")
    if not okm then lost = lost + 1 end
  end
  P("SP after eight more: %d loose chunk(s) (rocks_max %s)", #now, tostring(tb.params.rocks_max))
  if #reused == 0 then
    P("SP RESULT: INCONCLUSIVE (no freed slot was handed to a marker)")
  elseif lost > 0 then
    P("SP RESULT: FAIL (%d marker(s) in a stowed chunk's slot destroyed by the eviction)", lost)
  else
    P("SP RESULT: PASS (%d marker(s) in stowed chunks' slots survived the eviction)", #reused)
  end
  for _, m in ipairs(markers) do if m.valid then m:destroy() end end
end

