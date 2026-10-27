-- ── IVA / crew-strip probe (tools/perf/ivaprobe.sh) ─────────────────────────
-- docs/crew-and-items.md §4.4 (strip, crew cams), §3.4 (interiors), §2.3
-- (alerts). Spliced into a copy of perfbench.lua. Modes:
--   ivapod2    a Pod Mk2 rocket, three aboard: the strip (3 live portraits),
--              hover (EVA ⇄), the strip's GPU cost on/off, then V: the seat
--              view from every seat, looking forward/left/right/up/down/back
--   ivapod1    a Pod Mk1 rocket, one aboard: the seat view all round
--   ivacabin   Pod Mk2 over a Crew Cabin: the commander up top, two in the
--              cabin; V steps commander → cabin seats, all round from each
--   ivajet     the Swift (cockpit) on the runway: the cockpit all round
--   ivaseat    a rover with two Command Seats: open-seat first person
--   ivasaddle  the bike of motoprobe_modes.lua: the Moto Saddle in first person
--   ivaalerts  on foot: the warning chips forced through crew.alerts
--              (O2 25 %, 10 %, 1 MIN, blackout, FATAL FALL, PINNED), and a
--              death (the sting, the hold, the caption)
-- `IV PASS|FAIL <check>` lines; pictures in $WORK/proj/save/user/ivashots/.
local IV = { fails = 0, tag = "iva" }
function IV.check(name, ok, fmt, ...)
  P("IV %s %s: " .. (fmt or ""), ok and "PASS" or "FAIL", name, ...)
  if not ok then IV.fails = IV.fails + 1 end
  return ok
end
function IV.result() P("IV RESULT %s: %s (%d failed)", IV.tag, IV.fails == 0 and "PASS" or "FAIL", IV.fails) end
function IV.shot(nm, ui)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = ui ~= false }, function(bytes)
    if bytes then assets.writeBytes("user://ivashots/" .. IV.tag .. "_" .. nm .. ".png", bytes); P("IV SHOT %s_%s", IV.tag, nm) end
    done = true
  end)
  if ok then wait_for(function() return done end, 6, "shot " .. nm) end
end
function IV.medium()
  local gx = findScript("graphics")
  if gx and gx.set then gx.set(tostring(params.gfx or "Medium")) end
  local w, h = 0, 0
  if camera and camera.screenSize then w, h = camera.screenSize() end
  P("IV graphics %s, screen %dx%d, render scale %.2f", gx and gx.level and gx.level() or "?", w or 0, h or 0,
    app.renderScale and app.renderScale() or -1)
end
-- launch_in_vab, with the crew seated through the VAB's CREW tab
-- (builder_crew.seatMember) between the blueprint load and the launch.
local function iv_launch(list, extra, site, plan)
  IV.medium()
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
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
      P("IV plan #%d -> %d/%d: %s %s", p.id, p.uid, p.slot, tostring(ok), tostring(why))
    end
  end
  if B.launchSite and B.launchSite() ~= (site or "pad") and B.toggleLaunchSite then B.toggleLaunchSite() end
  B.doLaunch()
  wait(0.6)
  if BH.state == "building" then B.doLaunch() end
  return wait_craft(#list, 150)
end
local function stack(ids)
  local l, y = {}, 0
  for i, e in ipairs(ids) do
    local id, h, st = e[1], e[2], e[3]
    l[#l + 1] = rec(i, id, 0, y + h / 2, 0, { parent = i > 1 and i - 1 or 0, att = i > 1 and "top" or "", stage = st or 0 })
    y = y + h
  end
  return l
end
local DIRS = { { "fwd", 0.0, -0.08 }, { "left", -1.45, 0.0 }, { "right", 1.45, 0.0 }, { "up", 0.0, 1.35 },
               { "down", 0.0, -1.22 }, { "back", 2.95, 0.05 } }
local function look_round(tag, only)
  local pc = findScript("planet_camera")
  for _, d in ipairs(DIRS) do
    if not only or only[d[1]] then
      pc.setSeatLook(d[2], d[3])
      wait(0.35)
      IV.shot(tag .. "_" .. d[1], false)
    end
  end
  pc.setSeatLook(0, -0.08)
end
local function piloted_v()
  for _, v in ipairs(findScripts("vessel_controller")) do if v.piloting and v.node and v.node.valid then return v end end
end
local function gpu_avg(n)
  local tot, k, passes = 0, 0, {}
  for _ = 1, n do
    yield()
    local g = perf.gpu and perf.gpu()
    if g and g.total then
      tot, k = tot + g.total, k + 1
      for _, p in ipairs(g.passes or {}) do passes[p.name] = (passes[p.name] or 0) + p.ms end
    end
  end
  for nm, v in pairs(passes) do passes[nm] = v / math.max(k, 1) end
  return k > 0 and tot / k or -1, passes, (perf.ms and perf.ms("render")) or -1
end
local function enter_seat(v, at)
  local pc = findScript("planet_camera")
  local ok = pc.setCockpit(true, v, at)
  wait(0.6)
  local I = findScript("iva")
  IV.check("seat_view_" .. tostring(at or 1), ok and pc.cockpit and pc.seatView ~= nil,
    "cockpit %s view %s (uid %s slot %s open %s) of %s; interiors %d", tostring(pc.cockpit), tostring(pc.seatView ~= nil),
    tostring(pc.seatView and pc.seatView.uid), tostring(pc.seatView and pc.seatView.slot), tostring(pc.seatView and pc.seatView.open),
    tostring(pc.seatView and pc.seatView.count), (function() local n = 0; for _ in pairs(I.interiorsOf(v)) do n = n + 1 end; return n end)())
  return ok
end

local function run_ivapod2()
  IV.tag = "pod2"
  perf.enable(true)
  local plan = { { uid = 3, slot = 1, id = 1 }, { uid = 3, slot = 2, id = 2 }, { uid = 3, slot = 3, id = 3 } }
  local vc = iv_launch(stack({ { "engineS", 1.3 }, { "tankS", 1.0 }, { "podMk2", 1.15 }, { "chute", 0.34, 1 } }), { name = "Kestrel" }, "pad", plan)
  if not vc then IV.check("rollout", false, "no craft"); IV.result(); return end
  wait(3)
  local S = findScript("crew_strip")
  local C = findScript("crew")
  S.setMode("small")
  wait(1.5)
  local I = findScript("iva")
  for _, m in ipairs(C.aboard(vc)) do
    local dn = C.dollOf(m.id) or (m.avatar and I.standIn()) or nil
    local hip = I.seatFrame(vc, m.uid, m.slot)
    local dp = C.dollPose and C.dollPose(m.id)
    if dp then P("IV dollPose #%d: %.2f %.2f %.2f open %s visible %s; node %.2f %.2f %.2f; parent %s", m.id, dp.x, dp.y, dp.z,
      tostring(dp.open), tostring(dp.visible), dn and dn.x or 0, dn and dn.y or 0, dn and dn.z or 0,
      tostring(dn and dn.parent and dn.parent.name)) end
    if dn and hip then
      P("IV doll #%d %s slot %d/%d: doll-to-seat %.3f m, layer %s visible %s", m.id, m.name, m.uid, m.slot,
        len(dn.x - hip.x, dn.y - hip.y, dn.z - hip.z), tostring(dn.layer), tostring(dn.visible))
    else P("IV doll #%d: doll %s hip %s", m.id, tostring(dn), tostring(hip)) end
  end
  P("IV posed dolls %d, rigged %d", I.posed.dolls, I.posed.rigged)
  IV.check("strip", S.strip.shown == 3 and S.strip.live == 3, "portraits %d, live cams %d, aboard %d", S.strip.shown, S.strip.live, #C.aboard(vc))
  IV.shot("strip")
  S.forceHover(2)
  wait(0.5)
  IV.shot("strip_hover")
  S.forceHover(nil)
  S.setMode("large")
  wait(1.0)
  IV.shot("strip_large")
  S.setMode("small")
  -- the strip's GPU cost: on, off, on, off (the same frames' views)
  local res = {}
  for i, m in ipairs({ "small", "hidden", "small", "hidden" }) do
    S.setMode(m)
    wait(1.0)
    local g, passes, r = gpu_avg(120)
    res[i] = g
    local list = {}
    for nm, ms in pairs(passes) do if ms > 0.05 then list[#list + 1] = string.format("%s %.2f", nm, ms) end end
    table.sort(list)
    P("IV GPU strip %-6s total %.3f ms, render bucket %.3f ms; passes: %s", m, g, r, table.concat(list, ", "))
  end
  local d = ((res[1] - res[2]) + (res[3] - res[4])) / 2
  IV.check("strip_cost", d <= 0.6, "strip on − off = %.3f ms GPU (budget 0.6)", d)
  S.setMode("small")
  -- the seat view from every seat
  local pc = findScript("planet_camera")
  local n = #pc.seatList(vc)
  IV.check("seat_list", n == 3, "%d seats to step through", n)
  for k = 1, n do
    enter_seat(vc, k)
    local g = gpu_avg(60)
    P("IV GPU seat view %d: total %.3f ms", k, g)
    look_round("seat" .. k, k > 1 and { fwd = true, left = true, right = true, back = true } or nil)
  end
  pc.setCockpit(false)
  wait(0.5)
  local g0 = gpu_avg(60)
  P("IV GPU orbit view (no seat): total %.3f ms", g0)
  IV.result()
end

local function run_ivapod1()
  IV.tag = "pod1"
  perf.enable(true)
  local plan = { { uid = 3, slot = 1, id = 1 } }
  local vc = iv_launch(stack({ { "engineS", 1.3 }, { "tankS", 1.0 }, { "pod", 0.8 }, { "chute", 0.34, 1 } }), { name = "Gnat" }, "pad", plan)
  if not vc then IV.check("rollout", false, "no craft"); IV.result(); return end
  wait(3)
  IV.shot("strip")
  enter_seat(vc, 1)
  P("IV GPU seat view: total %.3f ms", gpu_avg(60))
  look_round("seat1")
  findScript("planet_camera").setCockpit(false)
  P("IV GPU orbit: total %.3f ms", gpu_avg(60))
  IV.result()
end

local function run_ivacabin()
  IV.tag = "cabin"
  local plan = { { uid = 4, slot = 1, id = 1 }, { uid = 3, slot = 1, id = 2 }, { uid = 3, slot = 4, id = 3 } }
  local vc = iv_launch(stack({ { "engineS", 1.3 }, { "tankS", 1.0 }, { "cabin", 1.3 }, { "podMk2", 1.15 }, { "chute", 0.34, 1 } }),
    { name = "Omnibus" }, "pad", plan)
  if not vc then IV.check("rollout", false, "no craft"); IV.result(); return end
  wait(3)
  IV.shot("strip")
  local pc = findScript("planet_camera")
  local n = #pc.seatList(vc)
  IV.check("seat_list", n == 3, "%d seats", n)
  for k = 1, n do
    enter_seat(vc, k)
    look_round("seat" .. k, k == 1 and { fwd = true } or nil)
  end
  pc.setCockpit(false)
  IV.result()
end

local function run_ivajet()
  IV.tag = "jet"
  local list = plane()
  local plan = { { uid = 1, slot = 1, id = 1 } }
  local vc = iv_launch(list, { name = "Swift" }, "runway", plan)
  if not vc then IV.check("rollout", false, "no craft"); IV.result(); return end
  wait(3)
  enter_seat(vc, 1)
  look_round("seat1")
  findScript("planet_camera").setCockpit(false)
  IV.result()
end

local function run_ivaseat()
  IV.tag = "seat"
  local l = {
    rec(1, "roverBody", 0, 0.62, 0),
    rec(2, "wheelM", 0.66, 0.42, 0.7, { yaw = -HP, parent = 1, att = "surface", sym = 1, mir = "z" }),
    rec(3, "wheelM", 0.66, 0.42, -0.7, { yaw = HP, parent = 1, att = "surface", sym = 1, mir = "z" }),
    rec(4, "wheelM", -0.66, 0.42, 0.7, { yaw = -HP, parent = 1, att = "surface", sym = 2, mir = "z" }),
    rec(5, "wheelM", -0.66, 0.42, -0.7, { yaw = HP, parent = 1, att = "surface", sym = 2, mir = "z" }),
    rec(6, "seat", 0.3, 0.62 + 0.15 + 0.65, 0.3, { parent = 1, att = "top" }),
    rec(7, "seat", -0.4, 0.62 + 0.15 + 0.65, -0.3, { parent = 1, att = "top" }),
  }
  local plan = { { uid = 6, slot = 1, id = 1 }, { uid = 7, slot = 1, id = 2 } }
  local vc = iv_launch(l, { name = "Two Seater" }, "runway", plan)
  if not vc then IV.check("rollout", false, "no craft"); IV.result(); return end
  wait(3)
  vc.releaseClamps()
  wait(3)
  local S = findScript("crew_strip")
  S.forceHover(2)
  wait(0.6)
  IV.shot("strip_open")
  S.forceHover(nil)
  enter_seat(vc, 1)
  look_round("seat1")
  findScript("planet_camera").setCockpit(false)
  IV.result()
end

local function run_ivaalerts()
  IV.tag = "alerts"
  local C = findScript("crew")
  local H = findScript("crew_alerts_hud")
  local fake = nil
  local real = C.alerts
  C.alerts = function(id) if fake then return fake end return real(id) end
  local steps = {
    { "o2_25", { o2 = 0.24, air_s = 288, breath = 1, hp = 1, heat = 0, fall = 0 } },
    { "o2_10", { o2 = 0.09, air_s = 108, breath = 1, hp = 0.7, heat = 0, fall = 0 } },
    { "o2_1min", { o2 = 0.04, air_s = 48, breath = 1, hp = 0.7, heat = 0, fall = 0 } },
    { "blackout", { o2 = 0.0, air_s = 0, breath = 1, hp = 0.7, heat = 0, fall = 0, blackout = 9 } },
    { "fall", { o2 = 1, breath = 1, hp = 1, heat = 0, fall = 14.0 } },
    { "pinned", { o2 = 1, breath = 1, hp = 0.5, heat = 0.7, fall = 0, pinned = true } },
  }
  for _, s in ipairs(steps) do
    fake = s[2]
    wait(s[1] == "blackout" and 4.0 or 1.2)
    IV.check("chips_" .. s[1], H.hud.chips > 0, "chips %d, dim %.2f, loop %s", H.hud.chips, H.hud.dim, tostring(H.hud.loop))
    IV.shot(s[1])
  end
  fake = nil
  wait(1.5)
  IV.check("clear", H.hud.chips == 0 and H.hud.loop == nil, "chips %d loop %s", H.hud.chips, tostring(H.hud.loop))
  C.alerts = real
  -- a death: the sting, the 2 s hold on the place, the caption
  local pc = findScript("planet_camera")
  local id = C.activeId()
  local okk = C.kill and C.kill(id, "impact", "17 m/s")
  wait(0.5)
  IV.check("death_hold", okk and pc.holding and pc.holding(), "kill #%s: %s; the camera holds %s; lastDeath %s", tostring(id),
    tostring(okk), tostring(pc.holding and pc.holding()), tostring(C.lastDeath and C.lastDeath.text))
  IV.shot("death")
  wait(2.0)
  IV.check("death_release", not pc.holding(), "the hold lets go after 2 s; active now #%s", tostring(C.activeId()))
  local mem = C.memorial and C.memorial() or {}
  IV.check("memorial", #mem >= 1 and mem[1].died and mem[1].died.cause == "impact", "memorial rows %d, cause %s", #mem,
    tostring(mem[1] and mem[1].died and mem[1].died.cause))
  local R = findScript("crew_roster_panel")
  if R and R.openPanel then R.openPanel("MEMORIAL"); wait(1.0); IV.shot("memorial"); if R.close then R.close() end end
  IV.result()
end

-- ── the Moto Saddle: the bike of tools/perf/motoprobe_modes.lua (mp_bike) ───
local function iv_bike()
  puid = 0
  local X1, Y1, Z1 = { x = 1, y = 0, z = 0 }, { x = 0, y = 1, z = 0 }, { x = 0, y = 0, z = 1 }
  local function neg(a) return { x = -a.x, y = -a.y, z = -a.z } end
  local function member(id, a, b, o)
    local d = { x = b.x - a.x, y = b.y - a.y, z = b.z - a.z }
    local L = len(d.x, d.y, d.z)
    local Y = unit(d)
    local X = unit(cross(Y, Z1))
    if len(X.x, X.y, X.z) < 0.5 then X = X1 end
    local r = prec(id, (a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2, X, Y, o)
    r.size = { len = L, prof = "box" }
    r.proc, r.prof = "member", "box"
    return r
  end
  local L = {}
  local function add(r) L[#L + 1] = r return r end
  local H = add(prec("hub", 0.18, 1.068, 0, X1, Y1))
  local F = add(prec("forkT", 0.7416, 0.7564, 0, X1, Y1, { parent = H.uid, att = "surface" }))
  add(prec("wheelB", 0.8022, 0.3497, 0, Z1, Y1, { parent = F.uid, att = "surface" }))
  add(prec("packB", 0.12, 0.77, 0, X1, Y1, { parent = H.uid, att = "surface" }))
  local hp, rp = { x = 0.18, y = 1.068, z = 0 }, { x = -0.03, y = 0.48, z = 0 }
  local sp = add(member("beamP", hp, rp, { parent = H.uid, att = "surface" }))
  local R = add(prec("hub", rp.x, rp.y, 0, X1, Y1, { parent = sp.uid, att = "surface" }))
  local A = add(prec("swingArm", -0.485, 0.4826, 0, neg(X1), Y1, { parent = R.uid, att = "surface" }))
  add(prec("wheelB", -0.75, 0.35, 0, neg(Z1), Y1, { parent = A.uid, att = "surface" }))
  local sh = { x = -0.30, y = 0.79, z = 0 }
  local sf = add(member("beamP", rp, sh, { parent = R.uid, att = "surface" }))
  local S = add(prec("hub", sh.x, sh.y, 0, X1, Y1, { parent = sf.uid, att = "surface" }))
  local sd = add(prec("saddle", sh.x, sh.y + 0.12 + 0.65, 0, X1, Y1, { parent = S.uid, att = "top" }))
  add(prec("gyro", rp.x + 0.12 + 0.2, rp.y, 0, X1, Y1, { parent = R.uid, att = "surface" }))
  return L, sd.uid
end

local function run_ivasaddle()
  IV.tag = "saddle"
  local list, su = iv_bike()
  local vc = iv_launch(list, { name = "Moto" }, "runway", { { uid = su, slot = 1, id = 1 } })
  if not vc then IV.check("rollout", false, "no craft"); IV.result(); return end
  wait(3)
  vc.releaseClamps()
  wait(2)
  enter_seat(vc, 1)
  look_round("seat1")
  findScript("planet_camera").setCockpit(false)
  IV.result()
end
