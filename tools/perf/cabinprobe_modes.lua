-- ── CABIN AIR probe (tools/perf/cabinprobe.sh; scenarios2 PLAN §2 G1) ────────
-- Spliced into a copy of perfbench.lua. One mode, cabinorbit:
--   a Pod Mk2 over a mated docking-port pair and a Pod Mk1 (two modules, one
--   docking hatch), one crew in the Mk2, rolled out through the VAB and put
--   on a circular orbit; then in the seat view:
--     the gauge reads 1 atm; the Mk2 PUNCTURED (wearPart 0.3): the gauge
--     falls, the DEPRESSURISATION alarm, the hiss on the part; the part's
--     menu with its CABIN section and the "Patch the leak" row; PATCHED
--     (to PATCH_HP): the regulator repressurises from the reserve (warped);
--     the helmet aboard (off when breathable, refused while thin);
--     the Mk1 vented through its open side hatch to vacuum and sealed; the
--     docking hatch SHUT (its valve) and the two modules meet in the middle;
--     OPEN: one network; an EVA from the Mk2 opens its hatch and vents it.
-- `CB PASS|FAIL <check>` lines and `CB RESULT`; pictures in
-- $WORK/proj/save/user/cabinshots/.
local CB = { fails = 0, passed = 0 }
function CB.check(name, ok, fmt, ...)
  P("CB %s %s: " .. (fmt or ""), ok and "PASS" or "FAIL", name, ...)
  if ok then CB.passed = CB.passed + 1 else CB.fails = CB.fails + 1 end
  return ok
end
function CB.result() P("CB RESULT %d passed, %d failed", CB.passed, CB.fails) end
function CB.shot(nm, ui)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = ui ~= false }, function(bytes)
    if bytes then assets.writeBytes("user://cabinshots/" .. nm .. ".png", bytes); P("CB SHOT %s", nm) end
    done = true
  end)
  if ok then wait_for(function() return done end, 6, "shot " .. nm) end
end
local function cb_stack(ids)
  local l, y = {}, 0
  for i, e in ipairs(ids) do
    local id, h, st = e[1], e[2], e[3]
    l[#l + 1] = rec(i, id, 0, y + h / 2, 0, { parent = i > 1 and i - 1 or 0, att = i > 1 and "top" or "", stage = st or 0 })
    y = y + h
  end
  return l
end
local function cb_launch(list, extra, plan)
  local co = findScript("company")
  if co and co.earn then co.earn(90000, "probe") end
  local rs = findScript("research")
  for _, d in ipairs(list) do if rs and rs.grant then rs.grant(d.id, "probe") end end
  local BH = enter_vab("launch_enter")
  if not BH then return nil end
  local B = findScript("builder")
  wait(1.0)
  load_bp(B, "launch_bp", list, extra)
  wait(0.5)
  local BC = findScript("builder_crew")
  if BC and plan then
    for _, p in ipairs(plan) do if BC.unseatMember then BC.unseatMember(p.id) end end
    for _, p in ipairs(plan) do
      local ok, why = BC.seatMember(p.id, p.uid, p.slot)
      P("CB plan #%d -> %d/%d: %s %s", p.id, p.uid, p.slot, tostring(ok), tostring(why))
    end
  end
  if B.launchSite and B.launchSite() ~= "pad" and B.toggleLaunchSite then B.toggleLaunchSite() end
  B.doLaunch()
  wait(0.6)
  if BH.state == "building" then B.doLaunch() end
  return wait_craft(#list, 150)
end
-- a circular orbit by teleport and impulses (mnvprobe's MP.to_orbit)
local function cb_orbit(vn)
  local i = assembly.info(vn)
  local b = home()
  local U = unit(sub(i.com, b))
  local T = cross(U, { x = 0, y = 1, z = 0 })
  if len(T.x, T.y, T.z) < 0.1 then T = cross(U, { x = 1, y = 0, z = 0 }) end
  T = unit(T)
  local wd = save.get("world." .. b.name)
  local atmo = type(wd) == "table" and (wd.atmoHeight or 0) or 0
  local r = b.radius + math.max(atmo + 500, b.radius * 0.6)
  if (b.soi or -1) > 0 then r = math.min(r, b.soi * 0.5) end
  local o = i.origin
  local want = { x = b.x + U.x * r, y = b.y + U.y * r, z = b.z + U.z * r }
  assembly.teleport(vn, vec3(want.x + (o.x - i.com.x), want.y + (o.y - i.com.y), want.z + (o.z - i.com.z)))
  wait(0.3)
  local vcirc = math.sqrt(b.mu / r)
  local gain = 1.0
  for _ = 1, 10 do
    i = assembly.info(vn)
    b = home()
    U = unit(sub(i.com, b))
    local Tn = unit(cross(U, cross(T, U)))
    local dv = sub(scl(Tn, vcirc), i.vel)
    local dl = len(dv.x, dv.y, dv.z)
    if dl < 0.5 then break end
    local v0 = i.vel
    local s = i.mass / gain
    assembly.impulseAt(vn, vec3(dv.x * s, dv.y * s, dv.z * s), i.com)
    wait(0.6)
    local i2 = assembly.info(vn)
    local got = len(i2.vel.x - v0.x, i2.vel.y - v0.y, i2.vel.z - v0.z)
    if got > 1e-3 then gain = math.max(0.02, math.min(5, gain * got / dl)) end
  end
  local io = assembly.info(vn)
  local el = space.elements(io.origin.x, io.origin.y, io.origin.z, io.vel.x, io.vel.y, io.vel.z)
  P("CB orbit: alt %.0f, pe %.0f", r - b.radius, el and el.periapsis and (el.periapsis - b.radius) or -1)
  return el
end
local function cb_line(CA, vc, tag)
  local G = CA.modulesOf(vc)
  local bits = {}
  for i, m in ipairs(G and G.mods or {}) do
    local s = CA.statusOf(vc, i)
    bits[#bits + 1] = string.format("[%d %s %.1f m3: %.3f atm O2 %.3f CO2 %.4f res %.2f%s%s]", i, m.label, m.V, s and s.p or -1,
      s and s.o2 or -1, s and s.co2 or -1, s and s.reserve or -1, s and s.venting and " VENT" or "", s and #(s.leaks or {}) > 0 and " LEAK" or "")
  end
  P("CB AIR %s t=%.1f: %s · doors %s", tag, space.time(), table.concat(bits, " "), (function()
    local o = {}
    for _, d in ipairs(CA.doorsOf(vc)) do o[#o + 1] = string.format("%s#%d:%s", d.kind, d.uid, d.state) end
    return table.concat(o, ",")
  end)())
end
local function cb_mod(CA, vc, uid) local G = CA.modulesOf(vc); return G and G.modOf[uid] end
local function cb_p(CA, vc, uid) local s = CA.statusOf(vc, cb_mod(CA, vc, uid)); return s and s.p or -1, s end
local function cb_warp(k, secs)
  space.warp(k)
  wait(secs)
  space.warp(1)
  wait(0.3)
end

local function run_cabinorbit()
  perf.enable(true)
  local gx = findScript("graphics")
  if gx and gx.set then gx.set("Medium") end
  -- 1 engine, 2 tank, 3 Pod Mk2, 4-5 a mated port pair, 6 Pod Mk1, 7 chute
  local plan = { { uid = 3, slot = 1, id = 1 } }
  local vc = cb_launch(cb_stack({ { "engineS", 1.3 }, { "tankS", 1.0 }, { "podMk2", 1.15 }, { "dockPort", 0.28 }, { "dockPort", 0.28 },
    { "pod", 0.8 }, { "chute", 0.34, 1 } }), { name = "Ansel" }, plan)
  if not vc then CB.check("rollout", false, "no craft"); CB.result(); return end
  local CA = findScript("cabin_air")
  if not CB.check("script", CA ~= nil and CA.enabled(), "cabin_air in the scene, mode %s", CA and CA.mode() or "?") then CB.result(); return end
  wait(2)
  local G = CA.modulesOf(vc)
  local nd = 0
  for _, d in ipairs(CA.doorsOf(vc)) do if d.kind == "port" and d.b > 0 then nd = nd + 1 end end
  CB.check("modules", G and #G.mods == 2 and nd == 1, "%d modules, %d docking hatch between them", G and #G.mods or -1, nd)
  vc.releaseClamps()
  vc.setSAS("stability")
  vc.setThrottle(0)
  wait(0.5)
  local el = cb_orbit(vc.node)
  CB.check("orbit", el and el.period ~= nil, "a closed orbit")
  wait(2)
  CA.tickNow()
  cb_line(CA, vc, "orbit")
  local pA = cb_p(CA, vc, 3)
  CB.check("fresh", math.abs(pA - 1.0) < 0.02, "the Mk2 holds %.3f atm in orbit", pA)
  -- the seat view and the gauge
  local pc = findScript("planet_camera")
  pc.setCockpit(true, vc, 1)
  wait(1.2)
  CB.check("gauge", CA.gauge ~= nil and math.abs((CA.gauge.p or 0) - 1) < 0.02, "the IVA gauge up: %s %.3f atm", CA.gauge and CA.gauge.label or "-", CA.gauge and CA.gauge.p or -1)
  CB.shot("iva_gauge")
  -- helmet off aboard (breathable)
  local su = findScript("suit")
  local okh, whyh = su.canRemoveHelmet()
  CB.check("helmet_ok", okh == true, "the helmet may come off aboard in good air (%s)", tostring(whyh))
  -- PUNCTURE the Mk2
  local t0 = space.time()
  vc.wearPart(3, 0.3)
  wait(2.5)
  local p1, s1 = cb_p(CA, vc, 3)
  cb_line(CA, vc, "punctured +2.5 s")
  CB.check("leak", s1 and s1.venting and #(s1.leaks or {}) == 1 and p1 < 0.97, "venting through %d hole(s) of %.1f cm², %.3f atm, unbreathable in %.0f s",
    s1 and #(s1.leaks or {}) or -1, CA.holeArea(0.3) * 1e4, p1, s1 and s1.untilBad or -1)
  CB.check("alarm", CA.lastAlarm ~= nil and CA.lastAlarm.t >= t0 - 1 and (CA.lastAlarm.cause or ""):find("hole") ~= nil,
    "DEPRESSURISATION: %s", CA.lastAlarm and tostring(CA.lastAlarm.cause) or "none")
  CB.check("hiss", CA.lastLeakSound ~= nil and CA.lastLeakSound.uid == 3, "the hiss on part %s at volume %.2f",
    tostring(CA.lastLeakSound and CA.lastLeakSound.uid), CA.lastLeakSound and CA.lastLeakSound.vol or -1)
  wait(1.0)
  CB.shot("iva_leak")
  local pl = {}
  for k = 1, 4 do wait(2.0); pl[k] = cb_p(CA, vc, 3) end
  CB.check("falling", pl[1] > pl[2] and pl[2] > pl[3] and pl[3] > pl[4], "the gauge falls: %.3f %.3f %.3f %.3f", pl[1], pl[2], pl[3], pl[4])
  local okh2, whyh2 = su.canRemoveHelmet()
  CB.check("helmet_refused", okh2 == false or not su.helmetOn(), "the helmet aboard now: %s (%s)", tostring(okh2), tostring(whyh2))
  CB.shot("iva_leak_late")
  -- the part's menu, from the seat: CABIN rows and the patch
  local cm = findScript("context_menu")
  local REG = findScript("context_registry")
  local tgt = { kind = "part", vessel = vc, uid = 3, rec = vc.partRec(3), label = "Pod Mk2" }
  local rows = REG and REG.entriesFor(tgt, { ref = function(k) return findScript(k) end, actor = { kind = "craft" } }) or {}
  local have = {}
  for _, e in ipairs(rows) do have[(tostring(e.id):gsub("^.*%.", ""))] = true end
  CB.check("menu_rows", have.ca_air and have.ca_leak and have.ca_patch and have.ca_h_open, "CABIN rows: air %s leak %s patch %s hatch %s",
    tostring(have.ca_air), tostring(have.ca_leak), tostring(have.ca_patch), tostring(have.ca_h_open))
  pc.setCockpit(false)
  wait(0.8)
  if cm and cm.openFor then
    local F = vc.partFrameNow and vc.partFrameNow(3, true)
    if F then tgt.wx, tgt.wy, tgt.wz = F.ox, F.oy, F.oz end
    cm.openFor(tgt, nil, 760, 300)
    wait(0.8)
    CB.shot("menu_leak")
    if cm.close then cm.close() end
  end
  -- PATCH it (the Repair Kit's result), and the regulator refills from the reserve
  local r0 = (CA.statusOf(vc, cb_mod(CA, vc, 3)) or {}).reserve or 0
  vc.repairPart(3, CA.PATCH_HP)
  cb_warp(10, 14)
  CA.tickNow()
  local p2, s2 = cb_p(CA, vc, 3)
  cb_line(CA, vc, "patched + warp")
  CB.check("repress", p2 > 0.96 and s2 and s2.breathable and (s2.reserve or 99) < r0 - 1, "repressurised to %.3f atm from the reserve (%.2f → %.2f atm·m³)", p2, r0, s2 and s2.reserve or -1)
  pc.setCockpit(true, vc, 1)
  wait(1.0)
  CB.shot("iva_repress")
  pc.setCockpit(false)
  -- the Pod Mk1 vented through its side hatch, then sealed
  local okd, wd = CA.setDoor(vc, 6, "open", "probe")
  CB.check("vent_warn", okd and wd and wd:find("vents") ~= nil, "opening the Mk1's hatch: %s", tostring(wd))
  wait(2.0)
  CA.tickNow()
  local pB = cb_p(CA, vc, 6)
  CB.check("vented", pB < 0.02, "the Mk1 at %.4f atm through its open hatch", pB)
  CA.setDoor(vc, 6, "sealed", "probe")
  vc.partSt(6, "creg", "off", true)   -- (its regulator off: the docking hatch refills it)
  -- the docking hatch: SHUT (valve), then equal
  local dk = nil
  for _, d in ipairs(CA.doorsOf(vc)) do if d.kind == "port" and d.b > 0 then dk = d end end
  local okp, wp = CA.setDoorIndex(vc, dk.k, "shut", "probe")
  P("CB docking hatch shut: %s %s", tostring(okp), tostring(wp))
  vc.partSt(3, "creg", "off", true)
  local pa0, pb0 = cb_p(CA, vc, 3), cb_p(CA, vc, 6)
  cb_warp(10, 14)
  CA.tickNow()
  local pa1, pb1 = cb_p(CA, vc, 3), cb_p(CA, vc, 6)
  cb_line(CA, vc, "valve")
  local want = (pa0 * 4.5 + pb0 * 2.0) / 6.5
  CB.check("equalise", math.abs(pa1 - pb1) < 0.05 and math.abs(pa1 - want) < 0.05, "through the valve %.3f/%.3f → %.3f/%.3f atm (mean %.3f)", pa0, pb0, pa1, pb1, want)
  CA.setDoorIndex(vc, dk.k, "open", "probe")
  wait(1.5)
  CA.tickNow()
  local G2 = CA.modulesOf(vc)
  local sa, sb = CA.statusOf(vc, G2.modOf[3]), CA.statusOf(vc, G2.modOf[6])
  CB.check("merged", sa and sb and sa.net == sb.net and math.abs(sa.p - sb.p) < 1e-6, "the docking hatch open: one network at %.3f atm", sa and sa.p or -1)
  vc.partSt(3, "creg", false, true); vc.partSt(6, "creg", false, true)
  cb_warp(10, 8)
  CA.tickNow()
  cb_line(CA, vc, "merged + regulators")
  -- an EVA opens the Mk2's hatch: the joined modules vent
  local tE = time
  if vc.evaNow then vc.evaNow() end
  wait(4.0)
  CA.tickNow()
  local pe = cb_p(CA, vc, 3)
  CB.check("eva_vent", CA.lastHatch and CA.lastHatch.by == "eva" and pe < 0.1, "EVA: hatch %s by %s, the cabin at %.3f atm",
    tostring(CA.lastHatch and CA.lastHatch.to), tostring(CA.lastHatch and CA.lastHatch.by), pe)
  cb_line(CA, vc, "eva")
  CB.shot("eva_outside")
  P("CB PROF cabin_air tick %.3f ms over %d craft, %d modules", CA.PROF.ms, CA.PROF.crafts, CA.PROF.mods)
  CB.check("cost", CA.PROF.ms < 1.0, "the air tick %.3f ms (1 Hz)", CA.PROF.ms)
  CB.result()
end
