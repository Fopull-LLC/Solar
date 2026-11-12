-- ── SOUND probe (tools/perf/sfxprobe.sh; scripts/sfx.lua impacts) ───────────
-- Spliced into a copy of perfbench.lua. Mode `sfx`: the real game events, each
-- checked by the bank sfx.lua played for it (its `played` counts and `history`,
-- and with sfxLog on, "SFX <event> <bank> <clip>" in the log). Never by ear:
-- the run is silent.
--   1. on foot out of the base: steps by the ground, none of them concrete
--   2. the crew hurt: the suit's crack and hiss
--   3. a rover dropped 4 m onto open ground 110 m out: its hull and tyres meet
--      the ground with the ground's sounds, not the old steel-bar drop
--   4. a wheel shot off it: a part tearing, not a gunshot; the body left at
--      30 % hp: an electric short (an arc), not radio crackle
-- `SP PASS|FAIL <check>` lines and `SP RESULT`.
local SP = { fails = 0, passed = 0 }
function SP.check(name, ok, fmt, ...)
  P("SP %s %s: " .. (fmt or ""), ok and "PASS" or "FAIL", name, ...)
  if ok then SP.passed = SP.passed + 1 else SP.fails = SP.fails + 1 end
  return ok
end
function SP.result() P("SP RESULT %d passed, %d failed", SP.passed, SP.fails) end
-- the counts now, and what changed since `snap`
function SP.snap(fx) local s = {}; for k, v in pairs(fx.played or {}) do s[k] = v end; return s end
function SP.delta(fx, snap, pat)
  local n, keys = 0, {}
  for k, v in pairs(fx.played or {}) do
    local d = v - (snap[k] or 0)
    if d > 0 and (not pat or k:match(pat)) then n = n + d; keys[#keys + 1] = k .. "×" .. d end
  end
  table.sort(keys)
  return n, table.concat(keys, " ")
end
function SP.events(fx, since_t)
  local o = {}
  for _, h in ipairs(fx.history or {}) do
    if h.t >= since_t then o[#o + 1] = string.format("%s>%s", h.event, h.clip:match("[^/]+$") or h.clip) end
  end
  return table.concat(o, " ")
end

local function run_sfx()
  local fx = findScript("sfx")
  if not SP.check("sfx", fx ~= nil and fx.impact ~= nil, "the sfx script with impacts") then SP.result(); return end
  fx.sfxLog = true
  local wk = findScript("planet_walker")

  -- 1. on foot: out of the base and onto the ground
  local s0, t0 = SP.snap(fx), time
  key_down("w"); wait(9); key_up("w")
  key_down("d"); wait(0.8); key_up("d")
  key_down("w"); wait(6); key_up("w")
  wait(0.5)
  local n, keys = SP.delta(fx, s0, "^step_")
  local nc = SP.delta(fx, s0, "^step_concrete")
  SP.check("steps", n >= 10 and nc == 0, "%d steps (%s), none concrete; underfoot now %s", n, keys, tostring(wk and wk.lastSurface))
  local mat = fx.materialAt and astro() and fx.materialAt(astro().x, astro().y, astro().z)
  SP.check("steps_ground", wk and wk.lastSurface ~= nil and wk.lastSurface ~= "concrete",
    "the last step was on %s (the palette says %s under the crew)", tostring(wk and wk.lastSurface), tostring(mat))
  P("SP events walk: %s", SP.events(fx, t0))

  -- 2. the crew hurt
  local C = findScript("crew")
  s0, t0 = SP.snap(fx), time
  if C and C.hurt and C.activeId then pcall(C.hurt, C.activeId(), 0.06, "probe", "the sound probe") end
  wait(0.5)
  n, keys = SP.delta(fx, s0)
  SP.check("suit_damage", (fx.played.visor_crack or 0) > (s0.visor_crack or 0), "%s", keys)

  -- 3. a rover dropped onto open ground
  local vc = launch_via_builder(ROVER, "runway", 6)
  if not SP.check("rover", vc ~= nil, "rolled out") then SP.result(); return end
  local vn = vc.node
  vc.releaseClamps()
  wait(2)
  -- the builder round trip loaded new scenes: the sfx script is a new one
  fx = findScript("sfx")
  if not SP.check("sfx_again", fx ~= nil and fx.impact ~= nil, "sfx in the flight scene") then SP.result(); return end
  fx.sfxLog = true
  local u, t1, _, R = base_frame()
  local function drop(dist, h)
    local b = home()
    local dir = dir_at(u, t1, dist, R)
    local gr = ground_r(b, dir.x, dir.y, dir.z, R + 200)
    if not gr then return false end
    local i = assembly.info(vn)
    local o = i.origin
    local want = { x = b.x + dir.x * (gr + h), y = b.y + dir.y * (gr + h), z = b.z + dir.z * (gr + h) }
    assembly.teleport(vn, vec3(want.x + (o.x - i.com.x), want.y + (o.y - i.com.y), want.z + (o.z - i.com.z)))
    return true
  end
  wait(1)
  s0, t0 = SP.snap(fx), time
  local dropped = drop(110, 4.0)
  wait(4)
  n, keys = SP.delta(fx, s0)
  local metal = SP.delta(fx, s0, "^metal_") + SP.delta(fx, s0, "^tyre") + SP.delta(fx, s0, "^soil_") + SP.delta(fx, s0, "^rock_")
  SP.check("drop", dropped and metal > 0, "dropped %s: %s", tostring(dropped), keys)
  local can = false
  for _, h in ipairs(fx.history or {}) do if h.t >= t0 and h.clip:find("steel_drop", 1, true) then can = true end end
  SP.check("no_can", not can, "no steel-bar drop among them")
  P("SP events drop: %s", SP.events(fx, t0))
  local gm = fx.materialAt and fx.materialAt(assembly.info(vn).com.x, assembly.info(vn).com.y, assembly.info(vn).com.z)
  P("SP ground under the rover: %s (%s)", tostring(gm), gm and select(2, fx.groundOf(gm)) or "?")

  -- 4. a wheel torn off, the body left hurt
  s0, t0 = SP.snap(fx), time
  pcall(vc.hitPart, 2, 50)
  wait(1.0)
  SP.check("part_break", (fx.played.part_break or 0) > (s0.part_break or 0), "%s", select(2, SP.delta(fx, s0)))
  s0, t0 = SP.snap(fx), time
  pcall(vc.hitPart, 1, (vc.partHp and vc.partHp(1) or 1) - 0.25)
  wait(8)
  SP.check("short", (fx.played.zap or 0) > (s0.zap or 0), "body hp %.2f: %s", vc.partHp and vc.partHp(1) or -1, select(2, SP.delta(fx, s0)))
  P("SP events damage: %s", SP.events(fx, t0))
  SP.result()
end
