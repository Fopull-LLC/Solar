-- ── crew probe (tools/perf/crewprobe.sh): the multi-crew slice 2 spine ──────
-- docs/crew-and-items.md §2–4. Spliced into a copy of perfbench.lua. Modes:
--   crewpod      a new save: three starters. A Pod Mk2 rocket rolled out with
--                all three aboard (the VAB plan, `shipyard.crew`); their
--                seats, the commander, two dolls. Switch to #2 at their seat;
--                EVA #3 (out at the hatch, clear of the hull, at rest);
--                `[`/`]` reaches everyone; quick swap ×6; Shift-EVA #2 (a
--                CrewBody by the hatch, you keep the craft); take control of
--                #2 on foot; re-board both (F into the free slot, "Board")
--   crewrover    a rover with two Command Seats: the avatar in one, a doll
--                riding the other, in view (the pose command_seat gives both)
--   crewsplit    a 2-pod stack (pod | decoupler | pod) with a member in each:
--                in the air, SPACE splits it; each piece keeps its seated
--                crew, control follows the active member, the other piece is
--                a craft with crew aboard and `]` flies it as them
--   crewdeath    a 5 m drop (alive), a 40 m drop with the fall warning first
--                (alerts().fall ≥ 12 m/s before the impact), the death (cause,
--                memorial row, remains, the pack's crate), the 2 s hold, then
--                control passes to a member at base; the free newbie; and the
--                same 40 m drop with death off (rescued)
--   crewmigrate  USERSAVE=1: the player's save → three starters, member #1
--                and their pack untouched
-- One `CP PASS|FAIL <check>` line a check and `CP RESULT <mode>: PASS/FAIL`.
-- Pictures (1280×720) in $WORK/proj/save/user/crewshots/.
local CP = { fails = 0, tag = "crew" }
function CP.check(name, ok, fmt, ...)
  P("CP %s %s: " .. (fmt or ""), ok and "PASS" or "FAIL", name, ...)
  if not ok then CP.fails = CP.fails + 1 end
  return ok
end
function CP.result()
  P("CP RESULT %s: %s (%d failed check(s))", CP.tag, CP.fails == 0 and "PASS" or "FAIL", CP.fails)
end
function CP.shot(nm)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes)
    if bytes then assets.writeBytes("user://crewshots/" .. CP.tag .. "_" .. nm .. ".png", bytes); P("CP SHOT %s_%s", CP.tag, nm) end
    done = true
  end)
  if ok then wait_for(function() return done end, 5, "shot " .. nm) end
end
function CP.crew() return findScript("crew") end
function CP.dump(tag)
  local c = CP.crew()
  for _, r in ipairs(c.roster()) do
    P("CP [%s] #%d %-18s %-6s craft %-10s hp %.2f o2 %.2f%s", tag, r.id, r.name, tostring(r.status), tostring(r.craft),
      r.hp or 1, r.o2 or 1, r.died and (" died: " .. tostring(r.died.cause) .. " " .. tostring(r.died.detail)) or "")
  end
  P("CP [%s] active #%s, living %d", tag, tostring(c.activeId()), c.living())
end
function CP.vessels()
  local out = {}
  for _, v in ipairs(findScripts("vessel_controller")) do if v.node and v.node.valid then out[#out + 1] = v end end
  return out
end
function CP.seats(v, tag)
  local s = {}
  for _, e in ipairs(v.seatsOf()) do s[#s + 1] = string.format("%d/%d=%s", e.uid, e.slot, tostring(e.taken)) end
  P("CP [%s] %s seats %s, commander %s, avatar aboard %s, piloting %s", tag, tostring(v.craftName), table.concat(s, " "),
    tostring(v.commander()), tostring(v.crewAboard), tostring(v.piloting))
end
-- frames until `fn` is true (at most `n`)
function CP.frames(fn, n)
  for i = 0, n or 120 do
    if fn() then return i end
    yield()
  end
  return nil
end
function CP.astroSpeedRel(v)
  local a = astro()
  local i = assembly.info(v.node)
  if not (a and i) then return -1 end
  return len(a.vx - i.vel.x, a.vy - i.vel.y, a.vz - i.vel.z)
end
-- The VAB launch with a seat plan. The plan is written once the craft is IN
-- the builder, as the CREW tab writes it: builder_crew prunes `shipyard.crew`
-- to the craft on the stand, so a plan written before the blueprint loads
-- names parts that aren't there yet and is dropped.
local function cp_launch(list, extra, site, plan)
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  local rs = findScript("research")
  for _, d in ipairs(list) do if rs and rs.grant then rs.grant(d.id, "probe") end end
  local BH = enter_vab("launch_enter")
  if not BH then return nil end
  local B = findScript("builder")
  wait(1.0)
  load_bp(B, "launch_bp", list, extra)
  if B.launchSite and B.launchSite() ~= site and B.toggleLaunchSite then B.toggleLaunchSite() end
  wait(0.5)
  if plan then
    save.set("shipyard.crew", plan)
    wait(0.5)
    P("CP plan in the builder: %d seat(s) kept of %d", #(save.get("shipyard.crew") or {}), #plan)
  end
  B.doLaunch()
  wait(0.6)
  if BH.state == "building" then B.doLaunch() end
  return wait_craft(#list, 150)
end

-- engineS | tankS | Pod Mk2 | chute
local function pod2_bp()
  return {
    rec(1, "engineS", 0, 0.65, 0),
    rec(2, "tankS", 0, 1.8, 0, { parent = 1, att = "top" }),
    rec(3, "podMk2", 0, 2.3 + 0.575, 0, { parent = 2, att = "top" }),
    rec(4, "chute", 0, 3.45 + 0.17, 0, { parent = 3, att = "top", stage = 1 }),
  }
end

local function run_crewpod()
  CP.tag = "pod"
  local c = CP.crew()
  CP.dump("new save")
  local r = c.roster()
  CP.check("three_starters", #r == 3 and r[1].status == "afoot" and r[2].status == "base" and r[3].status == "base"
    and r[1].starter and r[2].starter and r[3].starter, "%d members: #1 %s, #2 %s, #3 %s", #r, r[1].status, tostring(r[2] and r[2].status), tostring(r[3] and r[3].status))
  -- the VAB's seat plan (what WS2's CREW tab writes): all three in the Mk2
  local vc = cp_launch(pod2_bp(), { name = "Kestrel" }, "pad", { { uid = 3, slot = 1, id = 1 }, { uid = 3, slot = 2, id = 2 }, { uid = 3, slot = 3, id = 3 } })
  if not vc then CP.check("rollout", false, "no craft"); CP.result(); return end
  wait(2)
  CP.seats(vc, "on the pad")
  CP.dump("on the pad")
  local ids = vc.crewIds()
  CP.check("three_aboard", #ids == 3 and vc.commander() == 1 and vc.crewAboard, "aboard %s, commander %s", table.concat(ids, ","), tostring(vc.commander()))
  CP.check("records_aboard", c.get(2).status == "aboard" and c.get(3).status == "aboard", "#2 %s, #3 %s", c.get(2).status, c.get(3).status)
  wait(0.5)
  CP.check("dolls", c.dollOf(2) ~= nil and c.dollOf(3) ~= nil and c.dollOf(1) == nil, "dolls for #2 %s and #3 %s, none for the avatar", tostring(c.dollOf(2)), tostring(c.dollOf(3)))
  -- a closed pod's doll sits where crew.dollPose puts it: at its seat in the
  -- pod, or in its IVA room (iva.lua, WS2: a human-scale interior kept in a
  -- space of its own) when the interiors are in
  local dn = c.dollOf(2)
  local want = c.dollPose(2)
  local px, py, pz = vc.partPointNow(3, 0, 0, 0)
  local dd = (dn and want) and len(dn.x - want.x, dn.y - want.y, dn.z - want.z) or -1
  local dp = (dn and px) and len(dn.x - px, dn.y - py, dn.z - pz) or -1
  CP.check("doll_placed", dd >= 0 and dd < 0.3, "#2's doll %.2f m from its pose (%s; %.1f m from the Mk2, visible %s)",
    dd, findScript("iva") and "the IVA room" or "the pod's seat", dp, tostring(dn and dn.visible))
  local por = c.aboard(vc)
  CP.check("portraits", #por == 3 and por[1].commander and por[1].id == 1, "aboard(): %d, first #%s commander %s", #por, tostring(por[1] and por[1].id), tostring(por[1] and por[1].commander))
  CP.shot("1pad")
  -- switch to #2 at their seat
  local ok, why = c.takeCraft(vc, 2)
  local f = CP.frames(function() return c.activeId() == 2 end, 30)
  wait(0.5)
  CP.check("switch_seat", ok and f ~= nil and vc.crewAboard and vc.piloting and c.dollOf(1) ~= nil and c.dollOf(2) == nil,
    "fly as #2 (%s, %s frames): #1 now a doll %s", tostring(why), tostring(f), tostring(c.dollOf(1)))
  CP.seats(vc, "as #2")
  -- EVA #3: out of the Mk2's hatch as the avatar
  ok, why = c.eva(3)
  f = CP.frames(function() return c.activeId() == 3 and not vc.crewAboard end, 30)
  local a = astro()
  -- the hatch and the crew in the same frame (the physics tick's: the node
  -- poses lag it by a rails carry, 1.5–6 m a tick)
  local hx, hy, hz = vc.hatchWorld(3)
  local ax, ay, az = vc.physPosOf(a)
  local d = (a and hx) and len(ax - hx, ay - hy, az - hz) or -1
  local rel = CP.astroSpeedRel(vc)
  local via = vc.dock and vc.dock.lastExit or "?"
  CP.check("eva3", ok and f ~= nil and d > 0.5 and d < (via == "hatch" and 2.0 or 4.5) and rel < 0.3,
    "EVA #3 (%s): %s frames, out by the %s, %.2f m from the hatch, %.2f m/s against the craft", tostring(why), tostring(f), via, d, rel)
  CP.check("eva3_seat_free", vc.memberSlot(3) == nil and #vc.crewIds() == 2, "#3's seat is free; %d aboard", #vc.crewIds())
  wait(1.5)
  CP.dump("#3 out")
  CP.shot("2eva3")
  -- the switch list
  local list = c.switchList()
  local names = {}
  local has3, hasv = false, false
  for _, t in ipairs(list) do
    names[#names + 1] = t.kind == "crew" and ("crew:" .. t.name) or (t.name .. "(" .. tostring(t.crew) .. ")")
    if t.kind == "crew" and t.id == 3 then has3 = true end
    if t.kind == "vessel" and t.v.node.id == vc.node.id and t.crew == 2 then hasv = true end
  end
  CP.check("switch_list", has3 and hasv, "[ ] list: %s", table.concat(names, " | "))
  -- quick swap ×6: craft ⇄ #3 (each settles within a few frames)
  local worst = 0
  for i = 1, 6 do
    local want_craft = (i % 2) == 1
    c.quickSwap()
    local n = CP.frames(function()
      if want_craft then return vc.crewAboard and vc.piloting end
      return c.activeId() == 3 and not vc.crewAboard
    end, 60)
    worst = math.max(worst, n or 999)
    wait(0.3)
  end
  CP.check("quickswap", worst <= 3, "6 quick swaps, worst %d frame(s) to settle", worst)
  CP.dump("after swaps")
  -- [ ] steps: from #3 on foot, `]` lands on the craft, again on #3
  local seen = {}
  for i = 1, #list + 1 do
    local nm = c.step(1)
    wait(0.4)
    seen[#seen + 1] = tostring(nm)
  end
  CP.check("step_all", #seen >= 2, "] steps: %s", table.concat(seen, " → "))
  -- back aboard as the commander (the step may have left us on foot)
  if not vc.crewAboard then c.takeCraft(vc); CP.frames(function() return vc.crewAboard end, 30) end
  -- Shift-EVA #2: a CrewBody by the hatch, you keep the craft
  local act = c.activeId()
  local who = act == 2 and 1 or 2
  ok, why = c.eva(who, { stay = true })
  wait(1.0)
  local body = c.bodyOf(who)
  CP.check("shift_eva", ok and body ~= nil and vc.piloting and vc.crewAboard and c.activeId() == act,
    "Shift-EVA #%d (%s): body %s, still flying as #%s", who, tostring(why), tostring(body), tostring(c.activeId()))
  CP.shot("3shift_eva")
  -- take control of them on foot
  ok, why = c.control(who)
  f = CP.frames(function() return c.activeId() == who and not vc.crewAboard end, 30)
  wait(1.0)
  CP.check("control_onfoot", ok and f ~= nil and c.bodyOf(who) == astro(), "control #%d on foot (%s, %s frames)", who, tostring(why), tostring(f))
  CP.dump("on foot")
  -- everyone on foot: two bodies and the avatar near the pod
  if c.get(3).status ~= "afoot" then c.eva(3); wait(1.0) end
  CP.shot("4onfoot")
  -- re-board: F as the avatar into a free slot, then "Board" for a body
  local a2 = astro()
  local sx, sy, sz = vc.hatchSpot(3)
  if a2 and sx then a2.x, a2.y, a2.z = sx, sy, sz; a2.vx, a2.vy, a2.vz = 0, 0, 0 end
  wait(0.5)
  local boarded = vc.boardNow()
  wait(0.3)
  CP.check("reboard_f", boarded and vc.crewAboard and vc.memberSlot(c.activeId()) ~= nil, "F boards #%s into slot %s/%s",
    tostring(c.activeId()), tostring(vc.memberSlot(c.activeId())), tostring(select(2, vc.memberSlot(c.activeId()))))
  for _, rr in ipairs(c.roster()) do
    if rr.status == "afoot" and rr.id ~= c.activeId() then
      local okb, whyb = c.board(rr.id, vc)
      CP.check("reboard_" .. rr.id, okb, "#%d boards (%s)", rr.id, tostring(whyb))
    end
  end
  wait(0.5)
  CP.seats(vc, "all back")
  CP.check("all_back", #vc.crewIds() == 3, "%d aboard again", #vc.crewIds())
  CP.dump("end")
  CP.result()
end

local function run_crewrover()
  CP.tag = "rover"
  local c = CP.crew()
  local l = {
    rec(1, "roverBody", 0, 0.62, 0),
    rec(2, "wheelM", 0.66, 0.42, 0.7, { yaw = -HP, parent = 1, att = "surface", sym = 1, mir = "z" }),
    rec(3, "wheelM", 0.66, 0.42, -0.7, { yaw = HP, parent = 1, att = "surface", sym = 1, mir = "z" }),
    rec(4, "wheelM", -0.66, 0.42, 0.7, { yaw = -HP, parent = 1, att = "surface", sym = 2, mir = "z" }),
    rec(5, "wheelM", -0.66, 0.42, -0.7, { yaw = HP, parent = 1, att = "surface", sym = 2, mir = "z" }),
    rec(6, "seat", 0.3, 0.62 + 0.15 + 0.65, 0.3, { parent = 1, att = "top" }),
    rec(7, "seat", -0.4, 0.62 + 0.15 + 0.65, -0.3, { parent = 1, att = "top" }),
  }
  local vc = cp_launch(l, { name = "Two Seater" }, "runway", { { uid = 6, slot = 1, id = 1 }, { uid = 7, slot = 1, id = 2 } })
  if not vc then CP.check("rollout", false, "no craft"); CP.result(); return end
  wait(3)
  vc.releaseClamps()
  wait(3)
  CP.seats(vc, "rolled out")
  local doll = c.dollOf(2)
  CP.check("two_riders", #vc.crewIds() == 2 and doll ~= nil and doll.visible ~= false, "two aboard, #2's doll %s visible %s",
    tostring(doll), tostring(doll and doll.visible))
  local seat7 = nil
  for _, ch in ipairs(vc.node:children()) do if vc.uidOfNode(ch) == 7 then seat7 = ch end end
  local cs = seat7 and seat7.getScript and seat7:getScript("command_seat")
  CP.check("doll_posed", cs and cs.ridingDoll == true, "the second seat poses its doll (ridingDoll %s)", tostring(cs and cs.ridingDoll))
  if doll and seat7 then
    local p, q = doll.worldPos or doll, seat7.worldPos
    CP.check("doll_in_seat", len(p.x - q.x, p.y - q.y, p.z - q.z) < 0.6, "the doll sits in the seat (%.2f m)", len(p.x - q.x, p.y - q.y, p.z - q.z))
  end
  local cam = findScript("planet_camera")
  CP.shot("1two_riders")
  CP.result()
end

-- engineS | tankS | pod (#2) | decoupler | pod (#1) | chute
local function split_bp()
  return {
    rec(1, "engineS", 0, 0.65, 0),
    rec(2, "tankS", 0, 1.8, 0, { parent = 1, att = "top" }),
    rec(3, "pod", 0, 2.7, 0, { parent = 2, att = "top" }),
    rec(4, "decoupler", 0, 3.1 + 0.125, 0, { parent = 3, att = "top", stage = 1 }),
    rec(5, "pod", 0, 3.35 + 0.4, 0, { parent = 4, att = "top" }),
    rec(6, "chute", 0, 4.15 + 0.17, 0, { parent = 5, att = "top", stage = 2 }),
  }
end

local function run_crewsplit()
  CP.tag = "split"
  local c = CP.crew()
  local vc = cp_launch(split_bp(), { name = "Twin" }, "pad", { { uid = 5, slot = 1, id = 1 }, { uid = 3, slot = 1, id = 2 } })
  if not vc then CP.check("rollout", false, "no craft"); CP.result(); return end
  wait(2)
  CP.seats(vc, "on the pad")
  CP.dump("on the pad")
  local act = c.activeId()
  CP.check("two_pods", #vc.crewIds() == 2, "two aboard (active #%s, commander #%s)", tostring(act), tostring(vc.commander()))
  -- in the air (the stageprobe's air start): clamps off, put 400 m up
  vc.releaseClamps()
  yield()
  local S0 = body_state(vc.node)
  local io = assembly.info(vc.node)
  if S0 and io and io.origin then
    assembly.teleport(vc.node, vec3(io.origin.x + S0.U.x * 400, io.origin.y + S0.U.y * 400, io.origin.z + S0.U.z * 400))
  end
  yield(); yield()
  vc.setThrottle(0)
  wait(0.5)
  local n0 = #CP.vessels()
  local fired = vc.stageNext()
  wait(1.0)
  local vs = CP.vessels()
  local other = nil
  for _, v in ipairs(vs) do if v.node.id ~= vc.node.id then other = v end end
  CP.seats(vc, "kept")
  if other then CP.seats(other, "departed") end
  CP.dump("after the split")
  CP.check("split_fired", fired == true and #vs == n0 + 1 and other ~= nil, "SPACE split it: %d craft (was %d)", #vs, n0)
  local mine = vc.memberSlot(act)
  CP.check("control_follows", vc.piloting and vc.crewAboard and mine ~= nil, "the active #%s keeps the controls in their own pod (slot %s)", tostring(act), tostring(mine))
  local oc = other and other.crewIds() or {}
  CP.check("other_has_crew", #oc == 1 and oc[1] ~= act, "the departed piece carries #%s", tostring(oc[1]))
  wait(0.5)
  CP.check("other_doll", oc[1] and c.dollOf(oc[1]) ~= nil, "...as a doll in its pod")
  CP.shot("1split")
  -- ] flies the other piece as its crew member
  local list = c.switchList(5000)
  local nm = nil
  for _, t in ipairs(list) do if t.kind == "vessel" and other and t.v.node.id == other.node.id then nm = t end end
  CP.check("other_listed", nm ~= nil and nm.crew == 1, "the other piece is on the [ ] list with 1 aboard")
  local ok, why = c.switchTo(nm)
  local f = CP.frames(function() return other.piloting and other.crewAboard end, 30)
  wait(0.5)
  CP.check("switch_craft", ok and f ~= nil and c.activeId() == oc[1] and not vc.crewAboard and c.dollOf(act) ~= nil,
    "flying the other piece as #%s (%s, %s frames); #%s is a doll back in the first", tostring(c.activeId()), tostring(why), tostring(f), tostring(act))
  CP.shot("2switched")
  -- and back with `
  c.quickSwap()
  f = CP.frames(function() return vc.piloting and vc.crewAboard and c.activeId() == act end, 30)
  CP.check("swap_back", f ~= nil, "` back to #%s in the first piece (%s frames)", tostring(act), tostring(f))
  CP.dump("end")
  CP.result()
end

-- the avatar `h` m straight up, at rest relative to the ground
local function lift(h)
  local a = astro()
  local b = home()
  if not (a and b) then return end
  local ux, uy, uz = a.x - b.x, a.y - b.y, a.z - b.z
  local l = len(ux, uy, uz)
  ux, uy, uz = ux / l, uy / l, uz / l
  -- (a few metres out from the Command Centre's door, clear of the roofs)
  a.x, a.y, a.z = a.x + ux * h, a.y + uy * h, a.z + uz * h
  a.vx, a.vy, a.vz = 0, 0, 0   -- (the rails frame: at rest over the ground)
end

local function run_crewdeath()
  CP.tag = "death"
  local c = CP.crew()
  wait(3)
  -- step away from the buildings: 40 m out along the ground
  local a = astro()
  CP.dump("start")
  -- a 5 m drop: nothing
  lift(5)
  local fmax = 0
  for _ = 1, 240 do yield(); fmax = math.max(fmax, c.alerts().fall or 0) end
  CP.check("drop5", c.get(1).status ~= "dead", "a 5 m drop: alive (hp %.2f, fall chip peaked %.1f m/s)", c.get(1).hp or 1, fmax)
  -- 40 m: the fall chip goes red (≥ 12 m/s) before the impact
  lift(40)
  local warned_t, dead_t = nil, nil
  fmax = 0
  local t0 = time
  for _ = 1, 600 do
    yield()
    local al = c.alerts(1)
    fmax = math.max(fmax, al.fall or 0)
    if not warned_t and (al.fall or 0) >= 12 then warned_t = time - t0; CP.shot("1falling") end
    if c.get(1).status == "dead" then dead_t = time - t0 break end
  end
  local r = c.get(1)
  CP.check("warned_first", warned_t ~= nil and dead_t ~= nil and warned_t < dead_t, "FATAL FALL chip at %.2f s, death at %s s (peak %.1f m/s)",
    warned_t or -1, tostring(dead_t), fmax)
  CP.check("died_impact", r.status == "dead" and r.died and r.died.cause == "impact", "#1: %s, %s %s", r.status, tostring(r.died and r.died.cause), tostring(r.died and r.died.detail))
  CP.check("memorial", #c.memorial() == 1, "the memorial: %d row(s)", #c.memorial())
  local dep = findScript("deployables")
  local rem = dep and dep.list and dep.list("remains") or {}
  CP.check("remains", #rem == 1 and r.died.remains ~= nil, "remains placed (%d)", #rem)
  CP.check("crate", r.died.crate ~= nil, "the pack's crate #%s", tostring(r.died.crate))
  CP.check("caption", c.lastDeath and c.lastDeath.id == 1, "%s", tostring(c.lastDeath and c.lastDeath.text))
  wait(0.8)
  CP.shot("2remains")
  wait(2.0)
  CP.check("handoff", c.activeId() == 2 and c.get(2).status == "afoot", "control passed to #%s (%s)", tostring(c.activeId()), tostring(c.get(c.activeId() or 0) and c.get(c.activeId()).status))
  CP.shot("3handoff")
  -- everyone dead: the free newbie
  c.kill(3, "crushed")
  c.kill(2, "oxygen")
  wait(3)
  CP.dump("all gone")
  local nb = c.get(c.activeId())
  CP.check("newbie", c.living() == 1 and nb and nb.cost == 0 and nb.status == "afoot", "the newbie #%s %s ($%s)", tostring(nb and nb.id), tostring(nb and nb.name), tostring(nb and nb.cost))
  -- death off: the same 40 m drop rescues
  c.setDeath(false)
  wait(1)
  lift(40)
  local id = c.activeId()
  for _ = 1, 600 do yield(); if time - t0 > 1e9 then break end end
  CP.check("rescue", c.get(id).status == "afoot" and c.living() == 1, "death off: #%s %s after the 40 m drop", tostring(id), tostring(c.get(id).status))
  c.setDeath(true)
  CP.dump("end")
  CP.result()
end

local function run_crewmigrate()
  CP.tag = "migrate"
  local c = CP.crew()
  wait(2)
  CP.dump("the player's save")
  local r = c.roster()
  CP.check("three", #r == 3 and r[2].starter and r[3].starter and r[2].status == "base", "%d members", #r)
  CP.check("version", save.get("crew.version") == c.VERSION, "crew.version %s", tostring(save.get("crew.version")))
  local inv = findScript("inventory")
  local items = inv and inv.items and inv.items("crew:1") or {}
  local gear = inv and inv.itemList and inv.itemList("crew:1") or {}
  P("CP member #1: %s, hp %.2f, flights %s, hand %s; pack %d materials, %d items", r[1].name, r[1].hp or 1, tostring(r[1].flights), tostring(r[1].hand), #items, #gear)
  CP.check("pack_kept", (#items + #gear) > 0, "#1's pack (%d + %d)", #items, #gear)
  CP.check("active_kept", c.activeId() == 1, "#1 still in control")
  CP.shot("1player_save")
  CP.result()
end
