-- ── safety probe (tools/perf/safetyprobe.sh): the 11-04 playtest's three ─────
-- Spliced into a copy of perfbench.lua. Modes:
--   crashrevert  a SANDBOX save: the pod rocket hops off the pad and falls
--                back (the pod breaks); the revert is still on offer after the
--                crash (vessel_spawner.revertQuote, the on-foot REVERT key),
--                and a revert puts the craft back on the pad with the crew
--                seated and alive
--   rescuecrash  CREW SAFETY "rescue": the same crash with the crew aboard →
--                the craft still breaks, the pilot is NOT stood down beside the
--                wreck: hurt (hp < 1), home at the base, the fee charged;
--                then a 40 m fall on foot → hurt and home, not dead; and with
--                "invincible" the same fall leaves them where they landed,
--                unhurt (the two are distinct)
--   vabfunds     the VAB's bottom bar: COST and FUNDS in a career (in
--                budget, then over: red), and FUNDS ∞ in a sandbox
-- One `SF PASS|FAIL <check>` line a check and `SF RESULT <mode>: PASS/FAIL`.
-- Pictures (1280×720) in $WORK/proj/save/user/sfshots/.
local SF = { fails = 0, tag = "sf" }
function SF.check(name, ok, fmt, ...)
  P("SF %s %s: " .. (fmt or ""), ok and "PASS" or "FAIL", name, ...)
  if not ok then SF.fails = SF.fails + 1 end
  return ok
end
function SF.result()
  P("SF RESULT %s: %s (%d failed check(s))", SF.tag, SF.fails == 0 and "PASS" or "FAIL", SF.fails)
end
function SF.shot(nm)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes)
    if bytes then assets.writeBytes("user://sfshots/" .. SF.tag .. "_" .. nm .. ".png", bytes); P("SF SHOT %s_%s", SF.tag, nm) end
    done = true
  end)
  if ok then wait_for(function() return done end, 5, "shot " .. nm) end
end
function SF.dump(tag)
  local c = findScript("crew")
  for _, r in ipairs(c.roster()) do
    P("SF [%s] #%d %-18s %-6s craft %-10s hp %.2f%s", tag, r.id, r.name, tostring(r.status), tostring(r.craft),
      r.hp or 1, r.died and (" died: " .. tostring(r.died.cause)) or "")
  end
  P("SF [%s] active #%s, living %d, safety %s", tag, tostring(c.activeId()), c.living(), tostring(c.safety()))
end
-- the avatar's distance from the crew's home point (flight_ops.crewHome), in m
function SF.homeDist()
  local fo = findScript("flight_ops")
  local a = astro()
  if not (a and fo and fo.crewHome) then return -1 end
  local hx, hy, hz = fo.crewHome()
  if not hx then return -1 end
  return len(a.x - hx, a.y - hy, a.z - hz)
end
function SF.ledgerHas(pat)
  for _, e in ipairs(save.get("co.ledger") or {}) do
    if type(e) == "table" and tostring(e.why):find(pat) then return e end
  end
  return nil
end

-- engineS | tankS | pod | chute: up off the pad at full throttle for `burn` s,
-- cut, and wait for the pod to break when it comes back down.
local function sf_hop_crash(burn)
  local bp = rocket_bp(1)
  local vc = launch_in_vab(bp, "pad", #bp)
  if not vc then return nil end
  wait(1.0)
  tap("z")
  wait(0.3)
  tap("space")
  wait(0.8)
  if assembly.info(vc.node).anchored and vc.releaseClamps then vc.releaseClamps() end
  wait(burn or 4.0)
  tap("x")
  if vc.setThrottle then vc.setThrottle(0) end
  P("SF hop: throttle cut at alt above pad; waiting for the crash")
  local id0 = findScript("crew").activeId()
  local t = wait_for(function()
    for _, v in ipairs(findScripts("vessel_controller")) do if v.isLost and v.isLost() then return true end end
    return (not vc.crewAboard) or findScript("crew").activeId() ~= id0 or nil
  end, 60, "the crash")
  P("SF crash: crew #%s %s, vc.isLost %s, crewAboard %s", tostring(id0), tostring(findScript("crew").get(id0).status), tostring(vc.isLost and vc.isLost()), tostring(vc.crewAboard))
  P("SF crash: destroyed %s", tostring(t ~= nil))
  return vc, t ~= nil
end

local function run_crashrevert()
  SF.tag = "revert"
  save.set("game.mode", "sandbox")
  wait(1)
  local vs = findScript("vessel_spawner")
  local vc, crashed = sf_hop_crash(4.0)
  if not SF.check("crashed", crashed, "the pod rocket came back down and broke up") then SF.result() return end
  wait(3.0)
  SF.dump("after the crash")
  local q = vs.revertQuote(true)
  P("SF revert after crash: quote %s ok %s why %s gone %s", tostring(q ~= nil), tostring(q and q.ok), tostring(q and q.why), tostring(vs.revertGone))
  SF.check("quote_after_crash", q ~= nil and q.ok, "revert still offered after the crash (gone: %s)", tostring(vs.revertGone))
  local key = find("revert")
  local kx = key and key.uiRect and key:uiRect()
  SF.check("key_on_foot", kx ~= nil, "the REVERT key is on screen with the crew on foot by the wreck")
  SF.shot("1after_crash")
  -- the HUD key, as the player clicks it: arm, then confirm
  local ok1 = vs.revertClick("launch")
  wait(0.3)
  local ok2 = vs.revertClick("launch")
  local back = wait_for(function()
    for _, v in ipairs(findScripts("vessel_controller")) do
      if v.piloting and v.node and v.node.valid then
        local i = assembly.info(v.node)
        if i and i.anchored and #i.parts >= 4 then return v end
      end
    end
  end, 60, "the craft back on the pad")
  wait(1.0)
  SF.dump("after the revert")
  local c = findScript("crew")
  SF.check("reverted", back ~= nil and back.crewAboard and c.get(c.activeId()).status ~= "dead",
    "revert (%s/%s): the craft on the pad, crew aboard %s", tostring(ok1), tostring(ok2), tostring(back and back.crewAboard))
  SF.shot("2reverted")
  SF.result()
end

local function run_rescuecrash()
  SF.tag = "rescue"
  local c = findScript("crew")
  c.setSafety("rescue")
  wait(1)
  local co = findScript("company")
  local vc, crashed = sf_hop_crash(4.0)
  if not SF.check("crashed", crashed, "the pod rocket came back down and broke up") then SF.result() return end
  local id = c.activeId()
  wait(1.0)
  SF.shot("1crash")
  wait(2.0)
  SF.dump("after the crash")
  local r = c.get(id)
  local d = SF.homeDist()
  SF.check("alive", r and r.status ~= "dead", "#%s %s after the crash", tostring(id), tostring(r and r.status))
  SF.check("hurt", r and (r.hp or 1) < 0.99, "#%s hp %.2f (hurt, not untouched)", tostring(id), r and r.hp or -1)
  SF.check("home", d >= 0 and d < 30, "the pilot is %.1f m from the crew's home point (brought back to the base)", d)
  SF.check("fee", SF.ledgerHas("crew rescue") ~= nil, "the rescue fee is on the ledger")
  SF.check("not_aboard", not vc.crewAboard, "the wreck no longer holds the pilot")
  SF.shot("2rescued")
  -- on foot: a 40 m fall → hurt and home
  wait(2.0)
  local a = astro()
  local b = home()
  local function lift(h)
    local ux, uy, uz = a.x - b.x, a.y - b.y, a.z - b.z
    local l = len(ux, uy, uz)
    a.x, a.y, a.z = a.x + ux / l * h, a.y + uy / l * h, a.z + uz / l * h
    a.vx, a.vy, a.vz = 0, 0, 0
  end
  lift(40)
  local before = #(save.get("co.ledger") or {})
  local resc = wait_for(function() local rr = c.get(id); return (rr.status == "dead" or #(save.get("co.ledger") or {}) > before) and rr end, 20, "the fall's end")
  wait(2.0)
  r = c.get(id)
  SF.dump("after the fall")
  SF.check("fall_alive", r.status ~= "dead", "a 40 m fall in rescue mode: %s", r.status)
  SF.check("fall_hurt", (r.hp or 1) < 0.99, "hp %.2f after the fall", r.hp or 1)
  SF.check("fall_home", SF.homeDist() < 30, "%.1f m from home after the fall", SF.homeDist())
  SF.shot("3fall")
  -- invincible: the same fall, nothing happens
  c.setSafety("invincible")
  local patch_hp = r.hp
  wait(1.0)
  lift(40)
  wait(6.0)
  r = c.get(id)
  SF.check("invincible_distinct", r.status ~= "dead" and (r.hp or 1) >= (patch_hp or 0) - 1e-6,
    "invincible: the same fall leaves hp %.2f (was %.2f)", r.hp or 1, patch_hp or -1)
  c.setSafety("death")
  SF.result()
end

local function run_vabfunds()
  SF.tag = "vab"
  local BH = enter_vab("vab_enter")
  if not BH then SF.check("vab", false, "no builder") SF.result() return end
  local B = findScript("builder")
  wait(1.0)
  local bp = rocket_bp(2)
  load_bp(B, "vab_bp", bp)
  wait(1.0)
  local sb = findScript("builder_statusbar")
  local function fig(k)
    for _, f in ipairs(sb.figures(B)) do if f.key == k then return f end end
  end
  local co = findScript("company")
  save.set("co.funds", 19526)
  wait(1.0)
  local fc, ff = fig("cost"), fig("funds")
  P("SF career: COST %s (%s), FUNDS %s (%s)", tostring(fc and fc.value), tostring(fc and fc.tone), tostring(ff and ff.value), tostring(ff and ff.tone))
  SF.check("funds_shown", ff ~= nil and ff.value == co.money(19526) and ff.tone == nil, "FUNDS beside COST in budget")
  SF.shot("1career")
  save.set("co.funds", 100)
  wait(1.0)
  fc, ff = fig("cost"), fig("funds")
  P("SF over: COST %s (%s), FUNDS %s (%s)", tostring(fc and fc.value), tostring(fc and fc.tone), tostring(ff and ff.value), tostring(ff and ff.tone))
  SF.check("over_red", ff ~= nil and ff.tone == "danger" and fc.tone == "danger", "over budget: COST and FUNDS red")
  SF.shot("2over")
  save.set("game.mode", "sandbox")
  wait(1.0)
  fc, ff = fig("cost"), fig("funds")
  P("SF sandbox: COST %s (%s), FUNDS %s (%s)", tostring(fc and fc.value), tostring(fc and fc.tone), tostring(ff and ff.value), tostring(ff and ff.tone))
  SF.check("sandbox_inf", ff ~= nil and ff.value == "∞" and fc.tone == nil, "sandbox: FUNDS ∞, never red")
  SF.shot("3sandbox")
  save.set("game.mode", "career")
  SF.result()
end
