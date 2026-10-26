-- Contact sheet of generated emblems (and one flag), offline:
--   luajit tools/perf/emblem_sheet.lua OUTDIR   (from the Solar root)
-- Writes OUTDIR/e<i>.rgba (256²) and OUTDIR/flag.rgba, plus timings on stdout.
-- tools/perf/emblem_sheet.py turns them into a PNG grid.
local out = arg[1] or "."
local env = setmetatable({}, { __index = _G })
local chunk = assert(loadfile("scripts/emblem.lua"))
setfenv(chunk, env); chunk()
local NAMES = { "Solar Exploration Agency", "Kestrel Aerospace", "Northern Lights Space Command",
  "Vostok", "United Federation of Planets", "Orbital Dynamics & Freight", "NASA", "Bluebird Rocketry",
  "Agence Spatiale Européenne", "Deep Sky Mining Co.", "Ad Astra Collective", "Station 9" }
local tot = 0
for i, n in ipairs(NAMES) do
  local s = env.specFor(n)
  if arg[2] then s.shape = env.SHAPES[(i - 1) % #env.SHAPES + 1] end
  local t0 = os.clock()
  local px = env.rasterEmblem(s, n)
  local fpx = env.rasterFlag(s, n, px)
  local ms = (os.clock() - t0) * 1000
  tot = tot + ms
  print(string.format("%-32s %-8s %-7s %-8s %-16s %s  %.1f ms", n, s.shape, s.motif, s.font,
    env.PALETTES[s.palIndex].name, s.mono, ms))
  local f = io.open(out .. "/e" .. i .. ".rgba", "wb"); f:write(px); f:close()
  if i == 1 or i == 6 then
    local g = io.open(out .. "/flag" .. i .. ".rgba", "wb"); g:write(fpx); g:close()
  end
end
print(string.format("mean emblem+flag %.1f ms", tot / #NAMES))
