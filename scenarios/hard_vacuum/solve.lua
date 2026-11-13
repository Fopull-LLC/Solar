-- HARD VACUUM: the probe's solution (tools/perf/scnprobe.sh <engine> hard_vacuum).
-- Spliced after scnprobe_modes.lua. Plays the breach through the game's own
-- controls: hatch B sealed through cabin_air (the menu row's call), the EVA
-- (crew.eva), the RCS pack flown by a closed loop on tick poses (evaprobe's),
-- the Repair Kit held and the "Patch the leak" row's job (item_hand), the
-- boarding, the valve and the hatch; it answers the dialogue and takes the
-- pictures: the strike, the gauge and banner, the hull outside, the hole, the
-- patch, the gauge coming back.
--   BENCH_STRS='("branch", "up")': the reactor left at 40 % (more dose);
--   default: Ewan takes it to 10 %.
local HV = {}
local CRAFT = "Ansel"
local function ansel()
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.craftName == CRAFT and v.node and v.node.valid then return v end
  end
end
-- a camera in a part's DRAWN frame, re-placed every frame (docs/positions-and-frames.md)
local function pw_(uid, lx, ly, lz)
  local v = ansel()
  local F = v and v.partFrameNow and v.partFrameNow(uid, true)
  if not F then return nil end
  return { x = F.ox + F.rx * lx + F.ux * ly + F.zx * lz, y = F.oy + F.ry * lx + F.uy * ly + F.zy * lz, z = F.oz + F.rz * lx + F.uz * ly + F.zz * lz }
end
function lateUpdate(node, dt)
  local c = HV.cam
  if not c then return end
  local pc = findScript("planet_camera")
  if not (pc and pc.setFreecam) then return end
  local eye, tgt
  if c.astro then
    local a = find("Astronaut")
    local t0 = pw_(c.uid, c[4], c[5], c[6])
    if not (a and t0) then return end
    eye = pw_(c.uid, c[1], c[2], c[3])
    tgt = { x = (a.x + t0.x) / 2, y = (a.y + t0.y) / 2, z = (a.z + t0.z) / 2 }
  else
    eye, tgt = pw_(c.uid, c[1], c[2], c[3]), pw_(c.uid, c[4], c[5], c[6])
  end
  if not (eye and tgt) then return end
  local name = space.dominant(eye.x, eye.y, eye.z)
  local b = name and space.body(name)
  if not b then return end
  pc.setFreecam(true)
  local fc = pc.freecamState and pc.freecamState()
  if not fc then return end
  local pos = vec3(eye.x - b.x, eye.y - b.y, eye.z - b.z)
  local u = pos:normalized()
  fc.body, fc.rel = name, pos
  local d = vec3(tgt.x - eye.x, tgt.y - eye.y, tgt.z - eye.z)
  local du = d:dot(u)
  local h = d - u * du
  fc.ref = h:normalized()
  fc.pitch = math.atan2(du, h:length())
end
local function view(nm, cam, ui)
  HV.cam = cam
  wait(1.4)
  SP.shot(nm, ui == true)
  HV.cam = nil
  local pc = findScript("planet_camera")
  if pc and pc.setFreecam then pc.setFreecam(false) end
  wait(0.3)
end

-- the dialogue: lines clicked through, choices by policy
local POLICY = {}
local function talk(sr)
  local st = sr.state()
  if st.choice then
    local p = tostring(st.choice.prompt or "")
    for k, v in pairs(POLICY) do
      if p:find(k, 1, true) then P("HV CHOICE %q → %d", p, v); sr.choose(v); return end
    end
  elseif st.line and st.line.t0 and (time - st.line.t0) > 0.8 then
    sr.lineDone()
  end
end
local function talk_until(sr, fn, tmo, what)
  return wait_for(function() talk(sr); return fn() end, tmo or 60, what)
end
local function air(tag)
  local v, CA, sr = ansel(), findScript("cabin_air"), SP.run_()
  if not (v and CA) then return end
  CA.tickNow()
  local bits = {}
  for _, u in ipairs({ 10, 14, 17 }) do
    local s = CA.cabinOf(v, "#" .. u)
    bits[#bits + 1] = string.format("#%d %s %.3f atm res %.1f%s%s", u, s and s.label or "?", s and s.p or -1, s and s.reserve or -1,
      s and s.venting and " VENT" or "", s and s.untilBad and string.format(" bad in %.0f s", s.untilBad) or "")
  end
  local C = findScript("crew")
  local rate, dose = 0, 0
  if C and C.doseNow then rate, dose = C.doseNow() end
  P("HV AIR %s t=%.1f: %s · dose %.2f mSv (rate %.2f mSv/h) · vars dose %s res %s t_patch %s",
    tag, space.time(), table.concat(bits, " | "), dose * 5000, rate * 5e6 * 3.6, tostring(sr.var("dose_msv")),
    tostring(sr.var("stores_res")), tostring(sr.var("t_patch")))
end

-- the suit relative to a point on the craft (tick poses throughout: steering)
local function rel_to_point(v, a, uid, lx, ly, lz)
  local F = v.partFrameNow(uid)
  if not F then return nil end
  local tx, ty, tz = F.ox + F.rx * lx + F.ux * ly + F.zx * lz, F.oy + F.ry * lx + F.uy * ly + F.zy * lz, F.oz + F.rz * lx + F.uz * ly + F.zz * lz
  local i = assembly.info(v.node)
  local ax, ay, az = v.physPosOf(a)
  local c, w = i.com, i.angVel
  local qx, qy, qz = ax - c.x, ay - c.y, az - c.z
  local rvx = a.vx - (i.vel.x + w.y * qz - w.z * qy)
  local rvy = a.vy - (i.vel.y + w.z * qx - w.x * qz)
  local rvz = a.vz - (i.vel.z + w.x * qy - w.y * qx)
  return tx - ax, ty - ay, tz - az, rvx, rvy, rvz
end
-- fly the RCS pack to a point in a part's frame, as a pilot would: 0.6 m/s,
-- 0.25 inside 3 m, then HOLD
local function fly_to(v, uid, lx, ly, lz, stop, tmo)
  local ep, a = findScript("eva_pack"), find("Astronaut")
  ep.hold(false)
  local t, d = 0, 99
  while t < (tmo or 60) do
    local dx, dy, dz, rvx, rvy, rvz = rel_to_point(v, a, uid, lx, ly, lz)
    if not dx then break end
    d = math.sqrt(dx * dx + dy * dy + dz * dz)
    if d < (stop or 0.4) then break end
    local want = d > 3 and 0.6 or 0.25
    local ex, ey, ez = dx / d * want - rvx, dy / d * want - rvy, dz / d * want - rvz
    if math.sqrt(ex * ex + ey * ey + ez * ez) > 0.05 then ep.steerWorld(ex, ey, ez) else ep.steerWorld(nil) end
    wait(0.1); t = t + 0.1
  end
  ep.steerWorld(nil); ep.steerCmd(nil)
  ep.hold(true)
  wait(1.5)
  return d, t
end
local function part_node(v, uid)
  for _, ch in ipairs(v.node:children()) do if v.uidOfNode(ch) == uid then return ch end end
end

function SOLVE(SP)
  local sr = SP.run_()
  local up = tostring(params.branch or "") == "up"
  P("HV branch %s", up and "UP (the core left at 40 %)" or "TEN (Ewan takes the core to 10 %)")
  POLICY = { ["take the Ember down"] = up and 3 or 1, ["Kessel, or home"] = 1 }
  local v = wait_for(ansel, 30, "the Ansel")
  if not SP.check("craft", v ~= nil, "the Ansel staged") then return end
  local C, CA, ep = findScript("crew"), findScript("cabin_air"), findScript("eva_pack")
  local G = CA.modulesOf(v)
  local doors = {}
  for _, d in ipairs(CA.doorsOf(v)) do doors[#doors + 1] = string.format("%s#%d %s", d.kind, d.uid, tostring(d.state)) end
  SP.check("modules", G and #G.mods == 3, "%d modules: %s · doors %s", G and #G.mods or -1,
    (function() local o = {}; for _, m in ipairs(G and G.mods or {}) do o[#o + 1] = m.label end return table.concat(o, " / ") end)(), table.concat(doors, ", "))
  local me = (save.get("scn.crew") or {}).Castellanos
  local ewan = (save.get("scn.crew") or {}).Pryce
  local u1 = v.memberSlot(me)
  local u2 = v.memberSlot(ewan)
  SP.check("seated", C.activeId() == me and u1 == 14 and u2 == 17, "you are #%s (Castellanos #%s) in part %s; Ewan in part %s", tostring(C.activeId()), tostring(me), tostring(u1), tostring(u2))
  local hud = v.thermalHud and v.thermalHud()
  P("HV CORE T %.2f settles %.2f live %s out %.2f", hud and hud.T or -1, hud and hud.eq or -1, tostring(hud and hud.live), hud and hud.out or -1)
  -- ACT 1: the strike (a cutscene), then the alarm in the seat view
  wait(4.0)
  SP.shot("a1_strike_cutscene", true)
  wait(4.0)
  SP.shot("a1_strike_hole", true)
  local pc = findScript("planet_camera")
  talk_until(sr, function() return not sr.state().cutscene end, 40, "the cutscene's end")
  if pc.setCockpit then pc.setCockpit(true, v, 1) end
  talk_until(sr, function() return sr.var("struck") == true end, 30, "the strike")
  wait(1.3)
  air("struck")
  -- the banner and the gauge read one value (the G1 fix)
  local g = CA.gauge
  local bc = findScript("big_caption")
  local al = CA.lastAlarm
  P("HV BANNER %s / gauge eta %s (untilBad %s)", tostring(bc and bc.current), tostring(g and g.eta), tostring(g and g.untilBad))
  SP.shot("a1_iva_gauge_banner", true)
  SP.check("alarm", al ~= nil and tostring(al.cause):find("hole") ~= nil, "DEPRESSURISATION: %s", al and tostring(al.cause) or "none")
  SP.wait_step("listen", 60)
  -- ACT 2: hatch B
  talk_until(sr, function() return sr.state().line == nil end, 40, "the brief")
  local okd, wd = CA.setDoor(v, 13, "sealed", "hand")
  P("HV hatch B: %s %s", tostring(okd), tostring(wd))
  talk_until(sr, function() return (save.get("scn.done") or {}).isolate ~= nil end, 30, "isolate")
  SP.wait_step("isolate", 5)
  -- (storypolish) BENCH_STRS='("setback", "1")': a forced fail at the act 2
  -- checkpoint (the scenario's own cabin fail, its words), the fail screen,
  -- CONTINUE, and back at hatch B; the run ends there
  if tostring(params.setback or "") == "1" then
    local f = nil
    for _, e in ipairs(sr.scenario().fail or {}) do if e.kind == "craft_pressure" then f = e end end
    sr.fail(f and f.text or "Probe: a forced fail.", f)
    wait(1.0)
    SP.check("setback_card", sr.phaseNow() == "setback", "the fail is a setback (phase %s)", tostring(sr.phaseNow()))
    SP.shot("a2_fail_fading", true)
    local sb = sr.setbackNow and sr.setbackNow()
    local to = sb and sb.to
    SP.fail_screen(sr, "a2")
    local sr2 = wait_for(function()
      local s = findScript("scenario_run")
      return s and s ~= sr and s.isActive and s.isActive() and s.phaseNow and s.phaseNow() == "running" and s
    end, 300, "the restore")
    local d = save.get("scn.done") or {}
    SP.check("setback_restore", sr2 ~= nil and to ~= nil and d.listen ~= nil and d[to] == nil and (tonumber(save.get("scn.setbacks")) or 0) == 1,
      "back at %s (%s): listen %s, %s open again %s, setbacks %s", tostring(to), tostring(sb and sb.act), tostring(d.listen ~= nil), tostring(to), tostring(to and d[to] == nil), tostring(save.get("scn.setbacks")))
    wait(4.0)
    SP.shot("a2_after_setback", true)
    return
  end
  air("isolated")
  SP.shot("a2_gauge_isolated", true)
  if pc.setCockpit then pc.setCockpit(false) end
  -- ACT 3: the plan, the choice, out
  talk_until(sr, function() return sr.var("briefed") == true end, 120, "the plan")
  SP.wait_step("plan", 10)
  P("HV core %s; output now %s", tostring(sr.var("core")), tostring(v.partSt(4, "output")))
  local okE, whyE = C.eva(C.activeId(), { confirmed = true })
  wait(2.0)
  -- out onto the hab's hatch handrail (boarding by the hatch, 11-11): let go, as SPACE does
  do local ct = findScript("crew_task"); if ct and ct.climbState then C.cancelTask(C.activeId(), "let go"); wait(0.5) end end
  SP.check("eva", okE and not v.crewAboard, "out of the hab (%s %s)", tostring(okE), tostring(whyE))
  SP.wait_step("out", 10)
  wait(1.0)
  air("outside")
  view("a3_eva_hatch_hab", { uid = 14, astro = true, 3.2, 1.2, 2.4, 0.5, 0, 0 }, true)
  -- the walk aft: along the hull to the stores, listening
  local t_out = time
  -- (scnfix2, Ty 11-12b: "I just go outside and the rest completes itself")
  -- out of the hatch, the hole is NOT found yet: it has to be looked for
  wait(3.0)
  SP.check("find_not_free", (save.get("scn.done") or {}).find == nil, "not found from the hab's hatch (find %s)", tostring((save.get("scn.done") or {}).find))
  local d1 = fly_to(v, 11, 1.25, 0, 0, 0.5, 60)
  air("at the forward stores can")
  SP.check("find_not_next_can", (save.get("scn.done") or {}).find == nil, "not found at the forward stores can either")
  local CAj = findScript("cabin_air")
  local j0 = CAj and CAj.JET and CAj.JET.emitted or 0
  wait(1.0)
  SP.check("plume", CAj and CAj.JET and CAj.JET.emitted > j0 and CAj.JET.last and CAj.JET.last.uid == 10,
    "frost venting off the holed can: %d plumes in 1 s, on part %s", (CAj and CAj.JET and CAj.JET.emitted or 0) - j0, tostring(CAj and CAj.JET and CAj.JET.last and CAj.JET.last.uid))
  view("a3_eva_plume_side", { uid = 10, 2.2, 0.4, 4.0, 1.8, 0.1, 0 }, false)
  view("a3_eva_plume_far", { uid = 10, 6.0, -1.0, -4.0, 1.0, 0.1, 0 }, false)
  local hiss = CA.lastLeakSound
  SP.check("hiss", hiss ~= nil and hiss.uid == 10, "the hiss on part %s at volume %.2f", tostring(hiss and hiss.uid), hiss and hiss.vol or -1)
  view("a3_eva_hull_stores", { uid = 11, astro = true, 2.6, 1.6, -2.2, 0.6, -0.6, 0 }, true)
  local d2 = fly_to(v, 10, 1.15, 0.1, 0, 0.35, 40)
  talk_until(sr, function() return (save.get("scn.done") or {}).find ~= nil end, 20, "find")
  SP.wait_step("find", 5)
  air("at the hole")
  view("a3_eva_at_the_hole", { uid = 10, astro = true, 2.2, -0.8, 1.8, 0.5, 0, 0 }, true)
  view("card", { uid = 10, astro = true, 2.2, -0.8, 1.8, 0.5, 0, 0 }, false)     -- the menu card (no interface)
  -- the patch: the Repair Kit in hand, the row's job
  local H = findScript("item_hand")
  local okh, whyh = H.hold("repairkit")
  wait(0.6)
  local a = find("Astronaut")
  local tgt = { kind = "part", vessel = v, uid = 10, rec = v.partRec(10), node = part_node(v, 10), label = "Crew Cabin" }
  local F = v.partFrameNow(10, true)
  if F then tgt.wx, tgt.wy, tgt.wz = F.ox + F.rx * 0.5, F.oy + F.ry * 0.5, F.oz + F.rz * 0.5 end
  local ctx = { ref = function(k) return findScript(k) end, actor = { kind = "crew", id = C.activeId(), node = a, pack = C.packOf and C.packOf(C.activeId()) }, toast = function() end }
  local why = H.repairWhyNot(tgt, ctx)
  local okp, whyp = H.startRepair(tgt, ctx, { patch = true })
  SP.check("patch_row", okp == true, "hold %s (%s); Patch the leak: %s (%s; why-not %s)", tostring(okh), tostring(whyh), tostring(okp), tostring(whyp), tostring(why))
  wait(1.2)
  view("a3_eva_patching", { uid = 10, astro = true, 1.9, 0.9, -1.6, 0.5, 0, 0 }, true)
  SP.shot("a3_eva_patching_hud", true)
  local done = wait_for(function() talk(sr); return (v.partHp(10) or 0) > 0.5 end, 40, "the patch")
  if not done then v.repairPart(10, CA.PATCH_HP) end
  SP.wait_step("patch", 10)
  air("patched")
  local hp = v.partHp(10)
  P("HV patched: hp %.2f, outside %.0f s so far, %.1f mSv", hp or -1, time - t_out, sr.var("dose_msv") or -1)
  -- ACT 4: home through the hab's hatch
  fly_to(v, 14, 0.95, -0.1, 0, 0.4, 60)
  local boarded = v.boardNow and v.boardNow()
  wait(1.0)
  SP.check("boarded", boarded and v.crewAboard, "back in (%s), %.0f s outside", tostring(boarded), time - t_out)
  local exposure = sr.var("dose_msv")
  -- (scnfix2) the hab's regulator, shut for the EVA: no air comes back by itself
  local wc = findScript("warp_chip")
  if wc and wc.request then wc.request(10) end
  wait(4.0)
  if wc and wc.request then wc.request(1) end
  SP.check("home_waits_on_you", (save.get("scn.done") or {}).home == nil and v.partSt(14, "creg") == "off",
    "aboard, the hab still empty with its regulator off (home %s, creg %s)", tostring((save.get("scn.done") or {}).home), tostring(v.partSt(14, "creg")))
  do
    local reg = findScript("context_registry")
    local tgt = { kind = "part", vessel = v, uid = 14, rec = v.partRec(14), node = part_node(v, 14), label = "Crew Cabin" }
    local ctx = { ref = function(k) return findScript(k) end, actor = { kind = "craft", vessel = v, node = v.node, id = C.activeId() }, toast = function() end }
    local row = reg.byId(reg.entriesFor(tgt, ctx), "ca_reg")
    local okR, whyR = reg.press(row)
    SP.check("regulator_on", okR and v.partSt(14, "creg") ~= "off", "the hab's regulator AUTO from its menu (%s %s)", tostring(okR), tostring(whyR))
  end
  if wc and wc.request then wc.request(10) end
  talk_until(sr, function() return (save.get("scn.done") or {}).home ~= nil end, 90, "home")
  if wc and wc.request then wc.request(1) end
  SP.wait_step("home", 5)
  air("home")
  if pc.setCockpit then pc.setCockpit(true, v, 1) end
  wait(1.5)
  SP.shot("a4_iva_gauge_home", true)
  if pc.setCockpit then pc.setCockpit(false) end
  -- the stores: the valve first, then open
  CA.setDoor(v, 13, "shut", "hand")
  if wc and wc.request then wc.request(10) end
  wait_for(function() talk(sr); local s = CA.cabinOf(v, "#10"); local h = CA.cabinOf(v, "#14"); return s and h and math.abs(s.p - h.p) < 0.03 end, 60, "the valve")
  CA.setDoor(v, 13, "open", "hand")
  talk_until(sr, function() return (save.get("scn.done") or {}).stores ~= nil end, 90, "the stores")
  if wc and wc.request then wc.request(1) end
  SP.wait_step("stores", 5)
  air("stores")
  talk_until(sr, function() return sr.var("decided") == true end, 90, "the call")
  SP.wait_step("decide", 5)
  wait(3.0)
  SP.shot("a4_resolution", true)
  talk_until(sr, function() return sr.var("debriefed") == true end, 90, "the end")
  SP.wait_step("end", 10)
  P("HV SUMMARY branch %s: t_patch %s s, dose %s mSv (at boarding %s), stores bottles at the patch %s %%, game time %.0f s",
    up and "up" or "ten", tostring(sr.var("t_patch")), tostring(sr.var("dose_msv")), tostring(exposure), tostring(sr.var("res_at_patch")),
    space.time() - (tonumber(save.get("scn.t0")) or space.time()))
end
