-- alienprobe_dump.lua — the worlds tools/perf/alienprobe.sh renders, as opts
-- tables, from the real system_generator (rollGeology → geoOpts3) run offline.
--
--   luajit tools/perf/alienprobe_dump.lua <solar dir> <out.lua> <before|after> [list]
--
-- `after` rolls each world as a body of ANOTHER star system (homeStar set, so
-- alien_reach is far) at g_alienGen ALIEN_GEN; `before` the same body with the
-- formations off (ALIEN_GEN_FORCE 0), which is what every world rolled until
-- 2026-11-03. A world is named `<type>:<signature>[:home]`: the dumper walks
-- terrain seeds until the type rolls that signature, so the same list always
-- picks the same seeds. `:home` rolls it as a home-system body (the touch).
local bit = require("bit")
local SOL, OUT, WHEN, LIST = arg[1], arg[2], arg[3] or "after", arg[4]

local function U32(x) return x % 4294967296 end
local function rng(seed)
  local st = U32(math.floor(seed or 1))
  if st == 0 then st = 0x9E3779B9 end
  local function nxt()
    local x = bit.tobit(st)
    x = bit.bxor(x, bit.lshift(x, 13))
    x = bit.bxor(x, bit.rshift(x, 17))
    x = bit.bxor(x, bit.lshift(x, 5))
    st = U32(x)
    return st
  end
  local r = { seed = seed }
  function r:next() return math.floor(nxt() / 256) / 16777216 end
  function r:range(a, b) return a + (b - a) * self:next() end
  function r:int(a, b)
    local lo, hi = math.min(a, b), math.max(a, b)
    return lo + nxt() % (hi - lo + 1)
  end
  function r:pick(list) return list[self:int(1, #list)] end
  return r
end

local env = setmetatable({ rng = rng, print = function() end, log = function() end, save = nil }, { __index = _G })
local chunk = assert(loadfile(SOL .. "/scripts/system_generator.lua"))
setfenv(chunk, env)
chunk()

local TK = { canyon = 290, ironred = 260, crystal = 250, sulfur = 400, saltflat = 320, greenhouse = 420,
  frost = 150, glacial = 200, dune = 330, alpine = 270, regolith = 200, maria = 220, titan = 120,
  volcanic = 500, tundra = 240, archipelago = 290, verdant = 300, steppe = 285 }
local AIR = { canyon = true, ironred = false, crystal = false, sulfur = false, saltflat = false, greenhouse = true,
  frost = false, glacial = false, dune = true, alpine = true, regolith = false, maria = false, titan = true,
  volcanic = false, tundra = true, archipelago = true, verdant = true, steppe = true }

local function ser(v, ind)
  ind = ind or ""
  if type(v) == "table" then
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do
      local ks = type(k) == "number" and ("[" .. k .. "]") or (k:match("^[%a_][%w_]*$") and k or string.format("[%q]", k))
      out[#out + 1] = ind .. "  " .. ks .. " = " .. ser(v[k], ind .. "  ")
    end
    return "{\n" .. table.concat(out, ",\n") .. "\n" .. ind .. "}"
  elseif type(v) == "string" then return string.format("%q", v)
  elseif type(v) == "number" then return string.format("%.17g", v)
  else return tostring(v) end
end

local list = {}
for w in (LIST or "crystal:fins,canyon:arches,ironred:hoodoos,sulfur:karst,saltflat:mesas,greenhouse:ribs,frost:sponge,canyon:arches:home"):gmatch("[^,]+") do
  list[#list + 1] = w
end

local SC = env.SCALES[env.CURRENT_SCALE]
local worlds = {}
for _, name in ipairs(list) do
  local ty, sig, home = name:match("^([^:]+):([^:]+):?(.*)$")
  local R = (home == "moon") and 230 or 700
  local found
  for k = 1, 4000 do
    local tseed = 1000 + k * 7919
    local g = env.rollGeology(rng(tseed * 3 + 1), { type = ty, Tk = TK[ty], air = AIR[ty] and home ~= "moon" })
    env.homeStar = (home == "" ) and "Far Star" or nil
    env.ALIEN_GEN_FORCE = env.ALIEN_GEN
    local o, sh = env.geoOpts3(g, R, 1, SC, tseed)
    local want = (home ~= "") and (sh.reach and sh.reach > 0.1 and o.overhangs ~= nil and k > 0) or (sh.formation == sig)
    if want then
      if WHEN == "before" then
        env.ALIEN_GEN_FORCE = 0
        g = env.rollGeology(rng(tseed * 3 + 1), { type = ty, Tk = TK[ty], air = AIR[ty] and home ~= "moon" })
        o, sh = env.geoOpts3(g, R, 1, SC, tseed)
      end
      o.seed = tseed
      found = { name = name, label = g.label, formation = sh.formation or "none", reach = sh.reach or 0,
        peak = sh.peak, low = sh.low, seaAlt = sh.seaAlt, opts = o }
      break
    end
  end
  assert(found, "no seed rolls " .. name)
  worlds[#worlds + 1] = found
  io.stderr:write(string.format("%-24s seed %d %s reach %.2f peak %.0f | mtn %s ovh %s ter %s plat %s crat %s\n", name, found.opts.seed,
    found.formation, found.reach, found.peak,
    found.opts.mountains and string.format("h%.0f s%.1f sh%.1f c%.2f o%d", found.opts.mountains.height, found.opts.mountains.scale, found.opts.mountains.sharpness, found.opts.mountains.coverage, found.opts.mountains.octaves) or "-",
    found.opts.overhangs and string.format("d%.0f sc%.3f st%.1f", found.opts.overhangs.depth, found.opts.overhangs.scale, found.opts.overhangs.strength) or "-",
    found.opts.terrace and string.format("%.1f/%.2f", found.opts.terrace.step, found.opts.terrace.sharpness) or "-",
    found.opts.plateau and string.format("%.1f", found.opts.plateau.height) or "-",
    tostring(found.opts.craters)))
end
local f = assert(io.open(OUT, "w"))
f:write("WORLDS = " .. ser(worlds) .. "\n")
f:close()
