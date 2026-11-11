-- ── booster probe (tools/perf/boosterprobe.sh): radial boosters, fuel gating, the charge (2026-11-11) ──
-- Ty: "stages don't automatically gate off fuel correctly with radial
-- decouplers", "radial decouplers should apply a bit of a force to shoot out
-- the things they're attached to", "pressing new stage doesn't add a new
-- empty stage". Modes:
--   boostvab   the VAB: a core (pod, chute, 2 FT-M, Anvil) with two radial
--              boosters (stand-off pylon, FT-S, Sputter). The STAGE tab's
--              fuel groups (core + boosters ×2), NEW STAGE adds an empty
--              stage that survives a save and reload, crossfeed merges the
--              groups, and shots of the pylon from two angles
--   boostfly   the same craft flown: the boosters drain THEIR OWN tanks while
--              the core drains its own (core fuel falls too, boosters run dry
--              first, then their engines stop), SPACE throws the boosters
--              clear (out from the core axis, > 2.5 m in 1.5 s) and the core
--              is not spun (|ω| change < 0.08 rad/s) nor knocked sideways
-- One `SP PASS|FAIL <check>` a check and `SP RESULT <mode>: PASS/FAIL`.
-- Pictures in $WORK/proj/save/user/stageshots/.
local SP = { fails = 0, tag = "boost" }
function SP.check(name, ok, fmt, ...)
  P("SP %s %s: " .. (fmt or ""), ok and "PASS" or "FAIL", name, ...)
  if not ok then SP.fails = SP.fails + 1 end
  return ok
end
function SP.result()
  P("SP RESULT %s: %s (%d failed check(s))", SP.tag, SP.fails == 0 and "PASS" or "FAIL", SP.fails)
end
function SP.shot(nm)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes)
    if bytes then assets.writeBytes("user://stageshots/" .. SP.tag .. "_" .. nm .. ".png", bytes); P("SP SHOT %s_%s", SP.tag, nm) end
    done = true
  end)
  if ok then wait_for(function() return done end, 5, "shot " .. nm) end
end

-- the craft: uids 1 pod, 2 FT-M, 3 FT-M, 4 Anvil, 5 chute; boosters
-- 6/7 radial decouplers, 8/9 FT-S, 10/11 Sputter
local function booster_craft()
  puid = 0
  local R, up = {}, { x = 0, y = 1, z = 0 }
  local function add(r) R[#R + 1] = r return r end
  local X = { x = 1, y = 0, z = 0 }
  local pod = add(prec("pod", 0, 5.0, 0, X, up))
  local t1 = add(prec("tankM", 0, 3.85, 0, X, up, { parent = pod.uid, att = "bottom" }))
  local t2 = add(prec("tankM", 0, 2.35, 0, X, up, { parent = t1.uid, att = "bottom" }))
  add(prec("engineM", 0, 0.8, 0, X, up, { parent = t2.uid, att = "bottom" }))
  add(prec("chute", 0, 5.57, 0, X, up, { parent = pod.uid, att = "top" }))
  local decs, tanks = {}, {}
  for _, s in ipairs({ 1, -1 }) do
    -- the pylon as the builder stands it: +Y out of the wall, +X up the core
    -- (along ±Z: the pad's chase camera looks along X, so they leave sideways in its view)
    local out = { x = 0, y = 0, z = s }
    decs[#decs + 1] = add(prec("radialDec", 0, 2.6, s * 0.70, up, out, { parent = t2.uid, att = "surface", sym = 1, mir = "z" }))
  end
  for i, s in ipairs({ 1, -1 }) do
    tanks[i] = add(prec("tankS", 0, 2.6, s * 1.40, X, up, { parent = decs[i].uid, att = "surface", sym = 2, mir = "z" }))
  end
  for i, s in ipairs({ 1, -1 }) do
    add(prec("engineS", 0, 1.45, s * 1.40, X, up, { parent = tanks[i].uid, att = "bottom", sym = 3, mir = "z" }))
  end
  return R
end
local function grant(list)
  local rs = findScript("research")
  for _, d in ipairs(list) do if rs and rs.grant then rs.grant(d.id, "probe") end end
  if rs and rs.grant then rs.grant("fuelLine", "probe") end
end

local function run_boostvab()
  SP.tag = params.tag or "vab"
  local list = booster_craft()
  grant(list)
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  local BH = enter_vab("sp_enter")
  if not BH then SP.check("vab", false, "no builder"); SP.result(); return end
  local B = findScript("builder")
  local ins = findScript("builder_inspector")
  local bc = findScript("builder_camera")
  wait(1)
  load_bp(B, "sp_boost", list, { name = "Booster Test" })
  wait(0.5)
  if ins and ins.setTab then ins.setTab("STAGE") end
  if bc and bc.frameCraft then bc.frameCraft() end
  wait(1.5)
  local fv = B.fuelView and B.fuelView() or {}
  local desc = {}
  local core, boost = nil, nil
  for _, r in ipairs(fv) do
    desc[#desc + 1] = string.format("%s×%d %d tank(s) %d fuel → %s", r.name, r.n, r.tanks, r.fuel, tostring(r.engines))
    if r.name == "CORE" then core = r elseif r.name == "BOOSTER" then boost = r end
  end
  P("SP fuel view: %s", table.concat(desc, " | "))
  SP.check("fuel_groups", core and boost and boost.n == 2 and core.fuel == 320 and boost.fuel == 80 and #core.from == 0,
    "the core and the two boosters are separate tank groups")
  local s = B.stageStats and B.stageStats()
  if s and s.boosters then
    P("SP stats: boosters dv %.0f (iso %s, core used %.1f), stage 1 dv %.0f, total %.0f", s.boosters.dv, tostring(s.boosters.iso),
      s.boosters.core_used or -1, s.stages[1] and s.stages[1].dv or -1, s.dv)
    SP.check("dv_iso", s.boosters.iso == true, "the builder's Δv burns the boosters side by side with the core")
  end
  SP.shot("1stage_tab_fuel")
  -- NEW STAGE: an empty stage on top
  local v0 = B.stageView()
  local n0 = #v0.stages
  B.cmd("stage", { op = "blank" })
  wait(0.5)
  local v1 = B.stageView()
  SP.check("new_stage", #v1.stages == n0 + 1 and v1.stages[#v1.stages].blank == true, "NEW STAGE: %d → %d stages, the top one empty", n0, #v1.stages)
  SP.shot("2new_stage")
  -- drag the core engine into it
  local ek = nil
  for _, sg in ipairs(v1.stages) do for _, e in ipairs(sg.items) do if e.kind == "engine" then ek = e.key end end end
  for _, e in ipairs(v1.launch.items or {}) do if not ek then ek = e.key end end
  local bp = B.blueprintNow()
  SP.check("saved_blank", type(bp.stageBlank) == "table" and #bp.stageBlank == 1, "the blueprint keeps the empty stage (%s)",
    type(bp.stageBlank) == "table" and table.concat(bp.stageBlank, ",") or "none")
  save.set("shipyard.blueprint", bp)
  B.reload()
  wait_for(function() return not (B.loadProgress and B.loadProgress()) and (B.partCount or 0) >= #list end, 60, "reload")
  wait(0.5)
  local v2 = B.stageView()
  SP.check("reload_blank", #v2.stages == n0 + 1 and v2.stages[#v2.stages].blank == true, "after a reload: %d stages, the top one empty", #v2.stages)
  if ek then
    B.cmd("stage", { op = "item", key = ek, to = #v2.stages })
    wait(0.3)
    local v3 = B.stageView()
    SP.check("into_blank", #v3.stages == n0 + 1 and #v3.stages[#v3.stages].items == 1, "an engine dragged into the new stage")
  end
  -- crossfeed on: the boosters join the core's group
  B.cmd("decCfg", { uid = 6, key = "xfeed", value = true })
  wait(0.3)
  local fx = B.fuelView() or {}
  local merged = #fx == 1 and fx[1].name == "CORE" and fx[1].fuel == 480
  SP.check("crossfeed", merged, "crossfeed on (both pylons): one group (%d rows, %s fuel)", #fx, tostring(fx[1] and fx[1].fuel))
  local c = B.decouplerCfg(7)
  SP.check("ring_setting", c and c.xfeed == true, "the setting went to the whole ring")
  B.cmd("decCfg", { uid = 6, key = "xfeed", value = false })
  -- the pylon close up, INSPECT showing its settings
  B.select({ 6 }, "set")
  if ins and ins.setTab then ins.setTab("INSPECT") end
  if bc and bc.frameSelection then bc.frameSelection() end
  wait(1.5)
  SP.shot("3pylon_inspect")
  if bc and bc.camState and bc.setCamState then
    local cs = bc.camState()
    bc.setCamState({ yaw = (cs.yaw or 0) + 1.1, pitch = (cs.pitch or 0) + 0.35, d = cs.d, P = cs.P, fov = cs.fov })
    wait(1.0)
    SP.shot("4pylon_angle2")
    bc.setCamState({ yaw = (cs.yaw or 0) - 0.6, pitch = -0.15, d = (cs.d or 3) * 2.2, P = cs.P, fov = cs.fov })
    wait(1.0)
    SP.shot("5pylon_low")
    -- clean looks: nothing selected, the select tool, round the pylon
    B.select({}, "set")
    if B.setTool then B.setTool("select") end
    local r = B.partRec(6)
    for k, yaw in ipairs({ 0, math.pi / 2, math.pi, -math.pi / 2 }) do
      bc.setCamState({ yaw = yaw, pitch = 0.25, d = 2.2, P = { x = r.x, y = r.y, z = r.z }, fov = cs.fov })
      wait(1.0)
      SP.shot("6look" .. k)
    end
  end
  SP.result()
end

local function run_boostfly()
  SP.tag = params.tag or "fly"
  local list = booster_craft()
  grant(list)
  local vc = launch_in_vab(list, params.site or "pad", #list, { name = "Booster Test" })
  if not vc then SP.check("rollout", false, "no craft"); SP.result(); return end
  local vn = vc.node
  wait(2)
  local function left(u) return vc.tankLeft and vc.tankLeft(u) or -1 end
  local c0 = left(2) + left(3)
  P("SP on the pad: core %.1f, boosters %.1f / %.1f, engines %s", c0, left(8), left(9), tostring((vc.tele or {}).eng))
  SP.shot("1pad")
  vc.releaseClamps()
  vc.setSAS("stability")
  local t0, tl = time, -1
  local dry_at = nil
  while time - t0 < (tonumber(params.burn) or 90) do
    vc.setThrottle(1)
    yield()
    if not vn.valid then break end
    local b = left(8) + left(9)
    if time - tl >= 1.0 then
      tl = time
      local S = body_state(vn)
      P("SP burn +%.1f s: core %.1f, boosters %.2f / %.2f, engines %s, alt %.0f", time - t0, left(2) + left(3), left(8), left(9),
        tostring((vc.tele or {}).eng), S and S.alt or -1)
    end
    if b <= 1e-6 and not dry_at then dry_at = time end
    if dry_at and time - dry_at > 1.0 then break end
  end
  local cl = left(2) + left(3)
  SP.check("boosters_dry", dry_at ~= nil, "the boosters ran dry")
  SP.check("core_own", cl < c0 - 20 and cl > 0, "the core burnt its own fuel alongside (%.1f of %.1f left when the boosters ran dry)", cl, c0)
  SP.check("twins_even", math.abs(left(8) - left(9)) < 0.5, "both boosters drained together")
  local eng = (vc.tele or {}).eng
  SP.check("booster_engines_out", eng == 1, "dry boosters do not drink the core: %s engine(s) burning", tostring(eng))
  SP.shot("2boosters_dry")
  -- the booster tanks' nodes: they ride the boosters away
  local bt = {}
  for _, ch in ipairs(vn:children()) do if ch.name == "PartTankS" then bt[#bt + 1] = ch end end
  local function off_axis(n)
    local i = assembly.info(vn)
    if not (i and n.valid) then return 0 end
    local w = n.worldPos
    local o = vn.worldPos
    local U = i.up
    local dx, dy, dz = w.x - o.x, w.y - o.y, w.z - o.z
    local a = dx * U.x + dy * U.y + dz * U.z
    dx, dy, dz = dx - U.x * a, dy - U.y * a, dz - U.z * a
    return math.sqrt(dx * dx + dy * dy + dz * dz)
  end
  -- a BASELINE window first: what 1.5 s of flight alone does to ω and to the
  -- velocity across the axis (gravity, air, SAS), to compare the stage with
  local function window(secs, during)
    local ia = assembly.info(vn)
    local wa, va, Ua = ia.angVel, ia.vel, ia.up
    local t1, mw = time, 0
    while time - t1 < secs do
      vc.setThrottle(1)
      yield()
      if during then during(time - t1) end
      local i = vn.valid and assembly.info(vn)
      if i then
        mw = math.max(mw, math.sqrt((i.angVel.x - wa.x) ^ 2 + (i.angVel.y - wa.y) ^ 2 + (i.angVel.z - wa.z) ^ 2))
      end
    end
    local ib = assembly.info(vn)
    local dv = { x = ib.vel.x - va.x, y = ib.vel.y - va.y, z = ib.vel.z - va.z }
    local a = dv.x * Ua.x + dv.y * Ua.y + dv.z * Ua.z
    return mw, { x = dv.x - Ua.x * a, y = dv.y - Ua.y * a, z = dv.z - Ua.z * a }
  end
  local bw, bside = window(1.5)
  P("SP baseline 1.5 s: max |dw| %.4f, sideways dv (%.3f, %.3f, %.3f)", bw, bside.x, bside.y, bside.z)
  local i0 = assembly.info(vn)
  local w0 = i0.angVel
  local v0 = i0.vel
  local U0 = i0.up
  local d0 = {}
  for k, n in ipairs(bt) do d0[k] = off_axis(n) end
  P("SP before SPACE: %d booster tanks at %s m off the axis, |w| %.4f", #bt, table.concat(d0, ", "),
    math.sqrt(w0.x * w0.x + w0.y * w0.y + w0.z * w0.z))
  local fired = vc.stageNext()
  local shot1 = false
  local maxw, sside = window(1.5, function(t) if not shot1 and t > 0.25 then shot1 = true; SP.shot("3separating") end end)
  local i1 = assembly.info(vn)
  local d1 = {}
  for k, n in ipairs(bt) do d1[k] = off_axis(n) end
  P("SP 1.5 s after SPACE: booster tanks %s m off the axis; core parts %d, max |dw| %.4f", table.concat(d1, ", "), #i1.parts, maxw)
  SP.check("fired", fired == true and #i1.parts == 5, "SPACE dropped both boosters (%d parts fly on)", #i1.parts)
  local clear = #bt == 2
  for k = 1, #bt do if not (d1[k] and d1[k] > (d0[k] or 0) + 1.0 and d1[k] > 2.5) then clear = false end end
  SP.check("thrown_clear", clear, "the boosters were thrown out from the core (%s → %s m)", table.concat(d0, ","), table.concat(d1, ","))
  SP.check("core_unspun", maxw < bw + 0.05, "the core was not spun: max |Δω| %.4f rad/s over the stage (%.4f flying alone)", maxw, bw)
  -- sideways Δv of the core, less what flight alone gave in the window before
  local side = math.sqrt((sside.x - bside.x) ^ 2 + (sside.y - bside.y) ^ 2 + (sside.z - bside.z) ^ 2)
  SP.check("core_on_course", side < 0.4, "the stage's own sideways Δv on the core: %.3f m/s", side)
  SP.shot("4clear")
  wait(0.6)
  SP.shot("5later")
  SP.result()
end
