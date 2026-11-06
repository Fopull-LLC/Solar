-- ── roles probe (tools/perf/rolesprobe.sh): deep-space step 9, J4 and J6 ────
-- Spliced after crewprobe_modes.lua (CP.*, cp_launch, pod2_bp) into a copy of
-- perfbench.lua. A new save; the founding three are #1 Pilot, #2 Engineer,
-- #3 Scientist. The probe swaps #1 and #2 (#1 the Engineer, #2 the Pilot) so
-- the one being played is a non-pilot:
--   1. the Pod Mk2 rocket rolled out with #1 alone: the SAS grid greys every
--      hold but stability / prograde / retrograde; setSAS("target") refused
--      with the reason, prograde taken;
--   2. the Pilot (#2) seated beside them: every hold back, TARGET taken; the
--      Pilot unseated: the TARGET hold drops to stability;
--   3. #1 steps out onto the deck; the pod worn to 40 %: a repair as the
--      Engineer (×0.5) and as a Scientist (×1), each timed to the end;
--   4. a level-2 Engineer: the WEAR tag over the worn pod; a Scientist: none;
--   5. two Battery Banks 40 m apart: a Scientist can't lay a Power Cable
--      between them (nor open the Build Kit with B, nor place a Shield Wall);
--      the same member as an Engineer lays it.
-- `RP PASS|FAIL <check>` lines and `RP RESULT roles9`; pictures (1280×720)
-- in $WORK/proj/save/user/crewshots/roles9_*.png.
local RP = {}

function RP.patch_role(id, role, extra)
  local c = CP.crew()
  local p = { role = role }
  for k, v in pairs(extra or {}) do p[k] = v end
  c.patch(id, p)
end

-- the pod's centre and the way out to the astronaut, flat on the ground
function RP.pod_side(vc, uid)
  local F = vc.partFrameNow(uid)
  local a = astro()
  if not (F and a) then return nil end
  local b = home()
  local U = unit(sub({ x = F.ox, y = F.oy, z = F.oz }, b))
  local d = sub({ x = a.x, y = a.y, z = a.z }, { x = F.ox, y = F.oy, z = F.oz })
  local h = sub(d, scl(U, dot(d, U)))
  local hl = len(h.x, h.y, h.z)
  if hl < 1e-3 then h = { x = F.rx, y = F.ry, z = F.rz }; hl = 1 end
  return F, { x = h.x / hl, y = h.y / hl, z = h.z / hl }, hl
end

-- the camera behind the crew, looking at part `uid`
function RP.face(vc, uid)
  local F, n = RP.pod_side(vc, uid)
  local pc = findScript("planet_camera")
  if F and pc and pc.face then pc.face(-n.x, -n.y, -n.z, -0.12) end
end

-- a repair of `uid` as the member being played, timed to the end (game s)
function RP.repair(vc, uid, tag)
  local c, ct = CP.crew(), findScript("crew_task")
  vc.wearPart(uid, 0.4)
  wait(0.5)
  local F, n = RP.pod_side(vc, uid)
  if not F then CP.check(tag .. "_frame", false, "no frame") return nil end
  -- the hit point on the pod's skin toward the crew (Pod Mk2: ~1.25 m round)
  local hx, hy, hz = F.ox + n.x * 1.15, F.oy + n.y * 1.15, F.oz + n.z * 1.15
  local task, why = ct.repairTask(vc, uid, hx, hy, hz, n.x, n.y, n.z, { id = c.activeId() })
  local ok, why2 = false, why
  if task then ok, why2 = c.setTask(c.activeId(), task) end
  P("RP %s: the task %s %s, secs %.2f", tag, tostring(ok), tostring(why2), task and task.secs or -1)
  if not ok then return nil, task end
  local t0 = time
  RP.face(vc, uid)
  wait(2.0)
  CP.shot(tag)
  wait_for(function() return not c.held() end, 60, tag .. " done")
  local secs = time - t0
  local hp = vc.partHp(uid)
  P("RP %s: done in %.2f s, hp %.3f", tag, secs, hp or -1)
  return secs, task, hp
end

function RP.run()
  CP.tag = "roles9"
  if access and access.setCaptions then access.setCaptions(true) end   -- (the refusals are captions)
  local c = CP.crew()
  local r = c.roster()
  CP.check("starters", #r == 3 and c.role(1) == "pilot" and c.role(2) == "engineer" and c.role(3) == "scientist",
    "#1 %s, #2 %s, #3 %s", tostring(c.role(1)), tostring(c.role(2)), tostring(c.role(3)))
  RP.patch_role(1, "engineer")
  RP.patch_role(2, "pilot")
  CP.check("swapped", c.role(1) == "engineer" and c.role(2) == "pilot", "#1 is now the Engineer, #2 the Pilot")
  -- 1. a non-pilot alone in the pod
  local vc = cp_launch(pod2_bp(), { name = "Kestrel" }, "pad", { { uid = 3, slot = 1, id = 1 } })
  if not vc then CP.check("rollout", false, "no craft"); CP.result(); return end
  wait(2.5)
  CP.seats(vc, "on the pad")
  local ids = vc.crewIds()
  CP.check("alone", #ids == 1 and ids[1] == 1, "aboard: %s", table.concat(ids, ","))
  CP.shot("sas_nopilot")          -- (before any refusal: the greyed grid alone)
  local okP = vc.sasAllowed("prograde")
  local okT, whyT = vc.sasAllowed("target")
  local okD, okN, okNm = vc.sasAllowed("dock"), vc.sasAllowed("node"), vc.sasAllowed("normal")
  CP.check("gate_basic", okP and vc.sasAllowed("retrograde") and vc.sasAllowed("stability"), "stability / prograde / retrograde allowed")
  CP.check("gate_target", okT == false and okD == false and okN == false and okNm == false,
    "TARGET %s, DOCK %s, NODE %s, normal %s: %s", tostring(okT), tostring(okD), tostring(okN), tostring(okNm), tostring(whyT))
  local okS, whyS = vc.setSAS("target")
  CP.check("setsas_refused", okS == false and vc.sas_mode ~= "target", "setSAS(target) → %s (%s); flying %s", tostring(okS), tostring(whyS), tostring(vc.sas_mode))
  local okG = vc.setSAS("prograde")
  CP.check("setsas_prograde", okG == true and vc.sas_mode == "prograde", "setSAS(prograde) → %s; flying %s", tostring(okG), tostring(vc.sas_mode))
  vc.setSAS("target")             -- (the refusal's caption, for the picture)
  wait(0.4)
  CP.shot("sas_refused")
  -- 2. the Pilot seated beside them
  local okSeat, whySeat = vc.seatMember(3, 2, 2)
  wait(1.5)
  local ids2 = vc.crewIds()
  P("RP the Pilot seated: %s %s; aboard %s", tostring(okSeat), tostring(whySeat), table.concat(ids2, ","))
  local okT2 = vc.sasAllowed("target")
  CP.check("pilot_unlocks", okSeat and okT2 == true and vc.sasAllowed("dock") == true and vc.sasAllowed("node") == true,
    "with #2 (the Pilot) aboard: TARGET %s, DOCK %s, NODE %s", tostring(okT2), tostring(vc.sasAllowed("dock")), tostring(vc.sasAllowed("node")))
  local okS2 = vc.setSAS("target")
  CP.check("pilot_target", okS2 == true and vc.sas_mode == "target", "setSAS(target) → %s; flying %s", tostring(okS2), tostring(vc.sas_mode))
  wait(5.0)                       -- (the refusal captions gone)
  CP.shot("sas_pilot")
  vc.seatMember(3, 2, nil)
  wait(1.6)
  CP.check("pilot_gone", vc.sas_mode == "stability" and vc.sasAllowed("target") == false,
    "the Pilot unseated: flying %s, TARGET %s", tostring(vc.sas_mode), tostring(vc.sasAllowed("target")))
  -- 3. repairs: out onto the deck
  local V = findScript("inventory")
  V.addItem("astro", "repairkit", 3, { force = true })
  tap("f")
  wait(3.0)
  local pw = findScript("planet_walker")
  P("RP stepped out: on foot %s, piloting %s", tostring(pw and pw.onFoot), tostring(vc.piloting))
  local secsE, tkE, hpE = RP.repair(vc, 3, "repair_engineer")
  RP.patch_role(1, "scientist")
  wait(0.3)
  local secsS, tkS, hpS = RP.repair(vc, 3, "repair_scientist")
  CP.check("repair_engineer", secsE and math.abs((tkE.secs or 0) - 7.8) < 0.05 and hpE and hpE > 0.999,
    "an Engineer's repair at 40 %%: task %.2f s (want 7.8), done in %.2f s, hp %.3f", tkE and tkE.secs or -1, secsE or -1, hpE or -1)
  CP.check("repair_scientist", secsS and math.abs((tkS.secs or 0) - 15.6) < 0.05 and hpS and hpS > 0.999,
    "a Scientist's at 40 %%: task %.2f s (want 15.6), done in %.2f s, hp %.3f", tkS and tkS.secs or -1, secsS or -1, hpS or -1)
  CP.check("repair_faster", secsE and secsS and secsE < secsS * 0.6,
    "the Engineer took %.2f s against %.2f s (%.2f×)", secsE or -1, secsS or -1, (secsE or 0) / math.max(0.01, secsS or 1))
  -- 4. the wear tag (a level-2 Engineer: 20 structures)
  RP.patch_role(1, "engineer", { built = 20 })
  vc.wearPart(3, 0.4)
  local cm = findScript("context_menu")
  local pod = nil
  for _, ch in ipairs(vc.node:children()) do if vc.uidOfNode and vc.uidOfNode(ch) == 3 then pod = ch end end
  local function aim_pod()
    local w = pod and pod.worldPos
    if not w then return end
    local sx, sy = camera.worldToScreen(w.x, w.y, w.z)
    if sx then cm.wearSim = { sx, sy } end
  end
  RP.face(vc, 3)
  wait(1.0)
  for _ = 1, 90 do aim_pod(); yield() end
  local W1 = cm.wearTag
  if not W1 then
    local w = pod and pod.worldPos
    local sx, sy, _, on = camera.worldToScreen(w.x, w.y, w.z)
    local t = cm.pick(sx, sy)
    P("RP wear: pod node %s at screen %.0f %.0f (on %s); pick %s %s uid %s", tostring(pod and pod.name), sx or -1, sy or -1, tostring(on),
      tostring(t and t.kind), tostring(t and t.label), tostring(t and t.uid))
  end
  CP.check("wear_tag", W1 and math.abs((W1.wear or 0) - 0.6) < 0.01 and W1.secs and math.abs(W1.secs - 5.46) < 0.05,
    "level %s Engineer: tag %s, wear %.2f, repair %.2f s", tostring(c.level(1)), W1 and tostring(W1.label) or "none", W1 and W1.wear or -1, W1 and W1.secs or -1)
  CP.shot("wear_tag")
  RP.patch_role(1, "scientist")
  for _ = 1, 90 do aim_pod(); yield() end
  CP.check("wear_none", cm.wearTag == nil, "a Scientist sees no tag (%s)", tostring(cm.wearTag and cm.wearTag.label))
  cm.wearSim = nil
  vc.repairPart(3, 1.0)
  -- 5. the cable gate
  local ST, CB, fb, co = findScript("structures"), findScript("base_cable"), findScript("field_builder"), findScript("company")
  local b = home()
  local a = astro()
  local U = unit(sub(a, b))
  local fwd = unit(sub({ x = 1, y = 0, z = 0 }, scl(U, U.x)))
  local side = unit(cross(U, fwd))
  local function bank_at(off_f, off_s)
    local p = { x = a.x + fwd.x * off_f + side.x * off_s, y = a.y + fwd.y * off_f + side.y * off_s, z = a.z + fwd.z * off_f + side.z * off_s }
    local u = unit(sub(p, b))
    local gr = ground_r(b, u.x, u.y, u.z, len(p.x - b.x, p.y - b.y, p.z - b.z) + 60)
    if not gr then return nil end
    local rec0 = ST.newRecord(nil, save.get("base.body"), u.x * gr, u.y * gr, u.z * gr, u, fwd, "batteryBank",
      { by = 2, name = "probe bank" })
    return ST.add(rec0)
  end
  local s1, s2 = bank_at(30, 20), bank_at(30, 60)
  P("RP two banks: structures %s and %s", tostring(s1), tostring(s2))
  local bal0 = co.balance and co.balance() or 0
  local idS, whyS3 = CB.lay({ sid = s1, uid = 1 }, { sid = s2, uid = 1 })
  CP.check("cable_refused", idS == nil and tostring(whyS3):match("Engineers only") ~= nil and (co.balance() == bal0),
    "a Scientist lays a cable: %s (%s); nothing charged", tostring(idS), tostring(whyS3))
  local vS = CB.validity(nil, { rec = ST.get(s1), part = ST.getPart(s1, 1) }, save.get("base.body"))
  CP.check("cable_aim_refused", vS.bad and vS.bad:match("Engineers only") ~= nil, "the drum's hint for a Scientist: %s", tostring(vS.bad))
  local vW = fb.validity("shieldWall", { body = save.get("base.body"), x = 0, y = 0, z = 0, up = U, fwd = fwd })
  CP.check("wall_refused", vW.bad and vW.bad:match("Shield Wall") ~= nil, "a Shield Wall for a Scientist: %s", tostring(vW.bad))
  V.addItem("astro", "buildkit", 1, { force = true })
  local okK, whyK = fb.open()
  CP.check("kit_refused", okK == false and tostring(whyK):match("Engineers only") ~= nil, "B with the kit in the pack: %s (%s)", tostring(okK), tostring(whyK))
  tap("b")
  wait(0.4)
  CP.shot("kit_refused")
  RP.patch_role(1, "engineer", { built = 0 })
  wait(0.2)
  local idE, whyE, qE, LE = CB.lay({ sid = s1, uid = 1 }, { sid = s2, uid = 1 })
  CP.check("cable_engineer", idE ~= nil, "the same member as an Engineer: cable %s (%s), %.0f m, %s", tostring(idE), tostring(whyE), LE or -1,
    qE and tostring(qE.total) or "-")
  -- the level-2 perk: the same run quoted at ×0.9 a metre
  local q1 = CB.quote(100, 1)
  RP.patch_role(1, "engineer", { built = 20 })
  local q2 = CB.quote(100, 1)
  CP.check("cable_perk", q2.cost < q1.cost and math.abs(q2.cost - math.ceil(q1.cost * 0.9)) <= 1,
    "100 m of cable: $%s at level 1, $%s at level 2", tostring(q1.cost), tostring(q2.cost))
  if idE then CB.takeUp(idE) end
  if s2 then ST.remove(s2) end
  if s1 then ST.remove(s1) end
  CP.result()
end
