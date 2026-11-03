-- ── top-stage probe (tools/perf/topstageprobe.sh): the upper stage's engine
-- after an axial decoupler fires (playtest 2026-11-03: "after decoupling my top
-- stage (the decoupler was right below the engine) my top stage was not able to
-- use the engine at all"). Modes:
--   topuser    the player's craft (crafts/deepspace_mission.json: pod, battery,
--              FT-S, Sputter | decoupler | crew cabin, tanks, Anvil and four
--              strut-hung Skippers), started 400 m up, burnt 2 s, SPACE, then
--              full throttle on what we fly: its engine must push
--   topsimple  pod / FT-S / Sputter | decoupler | FT-M / Skipper, built from the
--              pod down (the pod is the tree's root, like the player's)
--   topcabin   the player's craft with the crew moved to the Crew Cabin under
--              the decoupler (two crewed parts): the top stage leaves as its own
--              craft; switch to it and throttle
-- One `TS PASS|FAIL <check>` a check and `TS RESULT <mode>`.
local TS = { fails = 0, tag = "top" }
function TS.check(name, ok, fmt, ...)
  P("TS %s %s: " .. (fmt or ""), ok and "PASS" or "FAIL", name, ...)
  if not ok then TS.fails = TS.fails + 1 end
  return ok
end
function TS.result() P("TS RESULT %s: %s (%d failed check(s))", TS.tag, TS.fails == 0 and "PASS" or "FAIL", TS.fails) end
function TS.shot(nm)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes)
    if bytes then assets.writeBytes("user://topshots/" .. TS.tag .. "_" .. nm .. ".png", bytes); P("TS SHOT %s_%s", TS.tag, nm) end
    done = true
  end)
  if ok then wait_for(function() return done end, 5, "shot " .. nm) end
end
function TS.decode(v)
  local t = type(v)
  if t == "string" then
    if v:sub(1, 1) ~= "\0" then return v end
    local tag, rest = v:sub(2, 3), v:sub(4)
    if tag == "s:" then return rest end
    if tag == "d:" then local m, e = rest:match("^(-?%d+):(-?%d+)$"); if m then return math.ldexp(tonumber(m), tonumber(e)) end end
    return v
  elseif t ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = TS.decode(x) end
  return out
end
function TS.controllers()
  local out = {}
  for _, v in ipairs(findScripts("vessel_controller")) do if v.node and v.node.valid then out[#out + 1] = v end end
  return out
end
function TS.state(vc, tag)
  local i = vc.node.valid and assembly.info(vc.node)
  local st = vc.crewStation and vc.crewStation()
  local t = vc.tele or {}
  local S = vc.node.valid and body_state(vc.node)
  P("TS [%s] %s: parts %d, piloting %s, crew %s (station %s), command %s, fuel %.1f, eng %s thrust %.1f kN, now %.1f kN, throttle %s, ctl %s, alt %.0f, vr %.1f, events %s",
    tag, tostring(vc.craftName), i and #i.parts or -1, tostring(vc.piloting), tostring(vc.crewAboard), tostring(st),
    tostring(vc.commandUid and vc.commandUid()), vc.fuel or -1, tostring(t.eng), t.thrust or 0, t.thrust_now or 0,
    tostring(vc.throttle), tostring(vc.elec and vc.elec.control), S and S.alt or -1, S and S.vr or 0, tostring(t.stages and #t.stages))
end
function TS.uids(vc)
  local fp = vc.fleetParts and vc.fleetParts()
  local set, n = {}, 0
  for _, r in ipairs(fp and fp.parts or {}) do set[r.uid] = true; n = n + 1 end
  return set, n
end
-- full throttle `secs` s on `vc`: the vertical-speed change and the thrust read
function TS.burn(vc, secs)
  local vn = vc.node
  local S0 = body_state(vn)
  local t0, best = time, 0
  vc.setSAS("stability")
  while time - t0 < secs and vn.valid do
    vc.setThrottle(1)
    yield()
    local t = vc.tele or {}
    best = math.max(best, t.thrust_now or 0)
  end
  local S1 = vn.valid and body_state(vn)
  return best, (S1 and S0) and (S1.vr - S0.vr) or 0
end
local function ts_launch(list, extra, site)
  local co = findScript("company")
  if co and co.earn then co.earn(200000, "probe") end
  local rs = findScript("research")
  for _, d in ipairs(list) do if rs and rs.grant then rs.grant(d.id, "probe") end end
  return launch_in_vab(list, site or "pad", #list, extra)
end
local function ts_air(vc, up)
  local vn = vc.node
  vc.releaseClamps()
  yield()
  local S0 = body_state(vn)
  local io = assembly.info(vn)
  if S0 and io and io.origin then
    assembly.teleport(vn, vec3(io.origin.x + S0.U.x * up, io.origin.y + S0.U.y * up, io.origin.z + S0.U.z * up))
  end
  yield(); yield()
end

local function deep()
  local ok, raw = pcall(assets.readJson, "user://probe_deepspace.json")
  if not ok or type(raw) ~= "table" then P("TS no user://probe_deepspace.json: %s", tostring(raw)); return nil end
  return TS.decode(raw.bp)
end

-- the common flight: up in the air, burn, SPACE, then throttle what holds `eng_uid`
local function fly_and_stage(vc, eng_uid, cabin, top_fuel)
  wait(2)
  if cabin then
    local okc = vc.setStation and vc.setStation(cabin)
    P("TS crew to the cabin %s: %s", tostring(cabin), tostring(okc))
    wait(0.5)
  end
  TS.state(vc, "on the pad")
  ts_air(vc, tonumber(params.airstart) or 400)
  local th0, dv0 = TS.burn(vc, 2.0)
  TS.state(vc, "lower stage burning")
  TS.check("lower_stage_pushes", th0 > 0 and dv0 > 0, "the lower stage's engines: %.1f kN, +%.1f m/s up in 2 s", th0, dv0)
  TS.shot("1burning")
  -- BURNOUT: on until the lower stage's own tanks are dry (the pool is down
  -- to what sits above the decoupler), then 3 s more: the player burns a
  -- stage until it stops pushing before SPACE. The upper stage's fuel must
  -- still be there.
  if (params.burnout or 1) > 0 and top_fuel then
    local t0 = time
    while time - t0 < 60 and vc.node.valid and (vc.fuel or 0) > top_fuel + 0.5 do vc.setThrottle(1); yield() end
    P("TS lower tanks dry after %.1f s more: fuel %.1f (the upper stage holds %.1f)", time - t0, vc.fuel or -1, top_fuel)
    local t1 = time
    while time - t1 < 3 and vc.node.valid do vc.setThrottle(1); yield() end
    TS.state(vc, "3 s after the lower tanks ran dry")
    TS.check("upper_fuel_kept", (vc.fuel or 0) >= top_fuel - 0.5, "the upper stage's %.0f units are still aboard (%.1f): the lower engines can't drink across the decoupler", top_fuel, vc.fuel or -1)
    local t = vc.tele or {}
    TS.check("lower_flamed_out", (t.thrust_now or 0) < 0.5, "the lower stage's engines are out of fuel (%.1f kN)", t.thrust_now or 0)
  end
  vc.setThrottle(0)
  local n0 = #TS.controllers()
  local fired = vc.stageNext()
  wait(0.8)
  TS.check("fired", fired == true, "SPACE fired the decoupler")
  local upper = nil
  for _, v in ipairs(TS.controllers()) do
    local set = TS.uids(v)
    TS.state(v, "after SPACE")
    if set[eng_uid] then upper = v end
  end
  P("TS controllers %d (was %d)", #TS.controllers(), n0)
  if not TS.check("upper_found", upper ~= nil, "a craft holds the upper engine (uid %d)", eng_uid) then return end
  if not upper.piloting then
    local sw = findScript("vessel_switcher")
    for _ = 1, 4 do
      local p = pilot()
      if p and p.node.id == upper.node.id then break end
      if sw then sw.step(1) end
      wait(1.0)
    end
  end
  local p = pilot()
  TS.check("flying_upper", p and p.node.id == upper.node.id, "we fly the upper stage (%s)", tostring(p and p.craftName))
  local th1, dv1 = TS.burn(upper, 2.5)
  TS.state(upper, "upper stage at full throttle")
  local t = upper.tele or {}
  TS.check("upper_engine_lit", (t.eng or 0) >= 1, "the HUD counts %s engine(s) lit on the upper stage", tostring(t.eng))
  TS.check("upper_pushes", th1 > 0 and dv1 > 0.5, "the upper stage's engine: %.1f kN, %+.1f m/s up in 2.5 s", th1, dv1)
  TS.shot("2upper_burning")
  upper.setThrottle(0)
end

function run_topuser()
  TS.tag = params.tag or "user"
  local bp = deep()
  if not bp then TS.check("craft", false, "no craft file"); TS.result(); return end
  P("TS the player's craft: %d parts, root %s", #bp.parts, tostring(bp.root))
  local vc = ts_launch(bp.parts, { links = bp.links, root = bp.root, v = bp.v or 2, name = "deepspace mission" }, "pad")
  if not vc then TS.check("rollout", false, "no craft"); TS.result(); return end
  fly_and_stage(vc, 45, nil, 320)
  TS.result()
end

function run_topcabin()
  TS.tag = params.tag or "cabin"
  local bp = deep()
  if not bp then TS.check("craft", false, "no craft file"); TS.result(); return end
  local vc = ts_launch(bp.parts, { links = bp.links, root = bp.root, v = bp.v or 2, name = "deepspace mission" }, "pad")
  if not vc then TS.check("rollout", false, "no craft"); TS.result(); return end
  fly_and_stage(vc, 45, 49, 320)
  TS.result()
end

-- pod / FT-S / Sputter | decoupler | FT-M / Skipper, the pod the tree's root
local function simple()
  local l = {}
  l[#l + 1] = rec(1, "pod", 0, 6.05, 0, {})
  l[#l + 1] = rec(2, "tankS", 0, 5.15, 0, { parent = 1, att = "bottom" })
  l[#l + 1] = rec(3, "engineS", 0, 4.0, 0, { parent = 2, att = "bottom" })
  l[#l + 1] = rec(4, "decoupler", 0, 3.225, 0, { parent = 3, att = "bottom" })
  l[#l + 1] = rec(5, "tankM", 0, 2.35, 0, { parent = 4, att = "bottom" })
  l[#l + 1] = rec(6, "skipper", 0, 0.8, 0, { parent = 5, att = "bottom" })
  l[#l + 1] = rec(7, "chute", 0, 6.62, 0, { parent = 1, att = "top" })
  return l
end
function run_topsimple()
  TS.tag = params.tag or "simple"
  local list = simple()
  local vc = ts_launch(list, { root = 1, name = "Two Stage" }, "pad")
  if not vc then TS.check("rollout", false, "no craft"); TS.result(); return end
  fly_and_stage(vc, 3, nil, 80)
  TS.result()
end
