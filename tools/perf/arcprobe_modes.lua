-- ── arc probe (tools/perf/arcprobe.sh; progression P2, docs/progression.md §3)
-- Spliced into a copy of perfbench.lua after vfxprobe_modes.lua (its freecam)
-- and ruinprobe_modes.lua (RN: crew_at, daylight, the near site's helpers).
--   arc     a fresh career walks the arc's first four milestones, the grants
--           checked at each step, the card pictured at each:
--             First Steps  a plant and an ore held → the Build Kit, issued
--             Homestead    the ruin near home found and claimed (the wood
--                          goal waived while the kit has no timber) → the
--                          Solar Array and the Battery Bank
--             Lights On    the claimed yard's grid carrying its tower for a
--                          minute → the tower; a cable laid from the yard to
--                          a new hut 40+ m off; a night held → heavy power
--             Shelter      the hut (steel, a door, a roof: 17.6 m³) sealed →
--                          life support; its scrubber on the grid an hour →
--                          fluids; the crew inside from dusk to dawn
--           The night's length is the world's year / 2 (base_grid slots); it
--           is crossed at warp.
--   arcold  an old save (a copy: USERSAVE=1 with SOLAR=<a copy holding it>):
--           every research it had stays open, the kit's pieces with it, its
--           milestones stand and the arc opens beside them.
-- `AR PASS|FAIL <check>`, `AR …` lines and `AR RESULT`. Pictures: save/user/arcshots/.
AR = { fails = 0, passed = 0 }
function AR.check(name, okc, fmt, ...)
  P("AR %s %s: " .. (fmt or ""), okc and "PASS" or "FAIL", name, ...)
  if okc then AR.passed = AR.passed + 1 else AR.fails = AR.fails + 1 end
  return okc
end
function AR.result() P("AR RESULT %s (%d passed, %d failed)", AR.fails == 0 and "PASS" or "FAIL", AR.passed, AR.fails) end
function AR.shot(nm, ui)
  local done = false
  local ok = pcall(camera.capture, { w = 1600, h = 900, ui = ui ~= false, draws = true }, function(bytes, why)
    if bytes then assets.writeBytes("user://arcshots/" .. nm .. ".png", bytes); P("AR SHOT %s", nm)
    else P("AR SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if ok then wait_for(function() return done end, 6, "shot " .. nm) end
end
-- a catalogue piece open to build: its research (the piece's `tech`, a drum's ALIAS)
function AR.open(id)
  local RS, K = findScript("research"), findScript("parts_kit")
  local d = K and K.partInfo and K.partInfo(id)
  local rid = (d and (d.vab or d.tech)) or id
  return RS.isUnlocked(rid), rid
end
function AR.state(MI, id) for _, e in ipairs(MI.programme()) do if e.m.id == id then return e.state, e.needs end end end
function AR.lines(MI, id) return table.concat(MI.progGoalLines(id) or {}, " | ") end
-- the card as it reads now (its headline; the goal lines from missions)
function AR.card(tag)
  local OB = findScript("objectives")
  P("AR CARD %s: headline '%s' · picked %s", tag, tostring(OB and OB.headline), tostring(OB and OB.selected and OB.selected()))
end
-- the card made to follow milestone `id` (as the player's / would)
function AR.pick(id)
  local OB = findScript("objectives")
  if not (OB and OB.cycle) then return false end
  for _ = 1, 10 do
    if OB.selected() == "prog:" .. id and save.get("objectives.pick") == "prog:" .. id then return true end
    OB.cycle(1)
    yield()
  end
  return OB.selected() == "prog:" .. id
end
-- the crew inside structure `rec` at its local point (x, y, z)
function AR.put_in(rec, lx, ly, lz)
  -- (the record's ground point is the frame's origin, as room_air's locate reads it)
  local KS = findScript("kit_snap")
  local fr = KS.frameOf(rec)
  local a = astro()
  for _ = 1, 10 do
    local b = space.body(rec.b)
    a.x = b.x + rec.x + fr.R.x * lx + fr.U.x * ly + fr.F.x * lz
    a.y = b.y + rec.y + fr.R.y * lx + fr.U.y * ly + fr.F.y * lz
    a.z = b.z + rec.z + fr.R.z * lx + fr.U.z * ly + fr.F.z * lz
    a.vx, a.vy, a.vz = 0, 0, 0
    yield()
  end
end
-- The Ops strip with long lines (2026-11-11: a third wrapped line spilled
-- under its frame): two earlier lines and a four-line one typing, pictured
-- mid-line and finished. The frame must hold every line.
function AR.ops_shots()
  local OS = findScript("ops_strip")
  if not (OS and OS.say and OS.logLine) then P("AR OPSSHOT: no strip") return end
  OS.clear()
  OS.logLine("Logged. The Depot ships Life Support now: CO2 scrubbers, oxygen generators, air tank racks, the airlock receiver and the equalise valve.")
  OS.logLine("Shelter: seal a room, then make its air your own.")
  local long = "Ops here. Your hut closed round the outside's gas; the rack's purge pump has emptied it and the regulator is filling it with air. Keep a scrubber running for an hour and the Depot opens the fluid network to you."
  OS.say(long)
  wait_for(function() return OS.current ~= nil and #(OS.current.shown or "") > 120 end, 15, "the strip typing")
  AR.shot("arc_ops_typing")
  OS.skipLine()
  wait(0.5)
  AR.shot("arc_ops_full")
  P("AR OPSSHOT: lines %d (cpl %d, max %d) · history %d · current %s", OS.linesOf and OS.linesOf(long) or -1, OS.CPL or -1, OS.LINES_MAX or -1,
    #(OS.history() or {}), tostring(OS.current and #OS.current.shown))
end

-- warp at `rate` until fn() or `tmo` real seconds; → met, real s
function AR.warp_until(rate, fn, tmo, every)
  local t0 = W()
  space.warp(rate)
  local last = W()
  while W() - t0 < tmo and not fn() do
    yield()
    if every and W() - last >= 5 then last = W(); every() end
  end
  space.warp(1)
  wait(1.0)
  return fn(), W() - t0
end

-- A steel hut on its slabs: 4 × 2 m inside, 2.2 m high (17.6 m³), a door at
-- x 1, a CO2 Scrubber, an O2 Generator, an Air Tank Rack, a light and a 63 A
-- breaker panel inside.
function AR.hut_pieces()
  local T, H = 0.2, math.pi / 2
  local P_ = {}
  local function add(id, x, y, z, yaw, pitch) P_[#P_ + 1] = { id = id, x = x, y = y, z = z, yaw = yaw or 0, pitch = pitch or 0 } end
  add("slab2.concrete", 2, 0, 0); add("slab2.concrete", 4, 0, 0)
  -- (a yard past the end wall: four more slabs for a timber fence)
  for _, x in ipairs({ 6, 8, 10, 12 }) do add("slab2.concrete", x, 0, 0) end
  add("doorWall.steel", 1, T, 0, H); add("wall.steel", 5, T, 0, H)
  add("wall.steel", 2, T, -1, 0); add("wall.steel", 4, T, -1, 0)
  add("wall.steel", 2, T, 1, 0); add("wall.steel", 4, T, 1, 0)
  add("floor.steel", 2, T + 2.2, 0); add("floor.steel", 4, T + 2.2, 0)
  add("scrubber.steel", 4.4, T, -0.62, 0)
  -- (an O2 Generator: an alien home's outside air holds no oxygen, and a
  -- scrubber only takes the CO2 out)
  add("o2gen.steel", 2.0, T, -0.6, 0)
  -- (an Air Tank Rack: its Purge empties an alien home's air out of the hut
  -- and its regulator refills it, base-building §36)
  add("airTank.steel", 3.2, T, -0.6, 0)
  add("lightFitting.steel", 3.0, T + 2.2 - 0.001, 0, 0, math.pi)
  add("breaker63.steel", 4.9, 1.2, 0.5, -H)
  return P_
end

-- The hut on the ground 45 m along the front of ground frame `gp` (the
-- claimed yard's: within its tower's 150 m, so on its grid). → sid, rec
function AR.build_hut(gp)
  local ST = findScript("structures")
  local px, py, pz = gp.x + gp.fx * 45, gp.y + gp.fy * 45, gp.z + gp.fz * 45
  local pl = math.sqrt(px * px + py * py + pz * pz)
  local dir = { x = px / pl, y = py / pl, z = pz / pl }
  -- (the world read NOW: it has moved kilometres since the probe began;
  -- docs/positions-and-frames.md rule 1)
  local b = home()
  local gr = ground_r(b, dir.x, dir.y, dir.z, b.radius + 150) or pl
  local fx, fy, fz = gp.fx, gp.fy, gp.fz
  local d0 = fx * dir.x + fy * dir.y + fz * dir.z
  fx, fy, fz = fx - dir.x * d0, fy - dir.y * d0, fz - dir.z * d0
  local fl = math.sqrt(fx * fx + fy * fy + fz * fz)
  local hg = { x = dir.x * (gr - 0.05), y = dir.y * (gr - 0.05), z = dir.z * (gr - 0.05), ux = dir.x, uy = dir.y, uz = dir.z,
               fx = fx / fl, fy = fy / fl, fz = fz / fl }
  local rec = ST.recordFromPieces(AR.hut_pieces(), b.name, hg, "Probe Hut", "probe", { t = save.get("agency.clock") or 0 })
  local sid = ST.add(rec)
  P("AR HUT: structure %s, %d pieces, ground %.2f m · %.0f m from the yard", tostring(sid), #rec.bp, gr,
    math.sqrt((hg.x - gp.x) ^ 2 + (hg.y - gp.y) ^ 2 + (hg.z - gp.z) ^ 2))
  return sid, ST.get(sid)
end

function AR.arc()
  wait_ready(120)
  wait(2)
  local MI, RS, F, RU, ST, B, C, inv = findScript("missions"), findScript("research"), findScript("feats"), findScript("ruins"),
    findScript("structures"), findScript("bases"), findScript("crew"), findScript("inventory")
  local BG, RA, CB = findScript("base_grid"), findScript("room_air"), findScript("base_cable")
  if not AR.check("scene", MI and RS and F and RU and ST and B and C and inv and BG and RA and CB and F.gridTick ~= nil,
    "missions %s research %s feats %s (P2 %s) ruins %s grid %s air %s cable %s", tostring(MI ~= nil), tostring(RS ~= nil), tostring(F ~= nil),
    tostring(F and F.gridTick ~= nil), tostring(RU ~= nil), tostring(BG ~= nil), tostring(RA ~= nil), tostring(CB ~= nil)) then AR.result() return end
  if perf.enable then perf.enable(true) end
  local b = home()
  local wood = findScript("parts_kit") and findScript("parts_kit").MATS.wood ~= nil
  -- 0. a fresh career
  AR.check("fresh", save.get("game.mode") ~= "sandbox" and not RS.isUnlocked("buildkit") and AR.state(MI, "first_steps") == "active"
    and AR.state(MI, "homestead") == "locked", "mode %s · kit %s · First Steps %s · Homestead %s · feats.mig %s", tostring(save.get("game.mode")),
    tostring(RS.isUnlocked("buildkit")), tostring(AR.state(MI, "first_steps")), tostring(AR.state(MI, "homestead")), tostring(save.get("feats.mig")))
  AR.check("gates_shut", (not wood or not RS.isUnlocked("tower")) and not RS.isUnlocked("solarArray") and not AR.open("scrubber.steel") and not AR.open("flPump.steel") and not RS.isUnlocked("life") and not RS.isUnlocked("fluids") and not RS.isUnlocked("power2"),
    "solar %s · life %s (%s) · fluids %s · power2 %s · tower %s", tostring(RS.isUnlocked("solarArray")),
    tostring(RS.isUnlocked("life")), tostring(RS.lockLine("life")), tostring(RS.isUnlocked("fluids")), tostring(RS.isUnlocked("power2")),
    tostring(RS.isUnlocked("tower")))
  AR.card("fresh")
  AR.shot("arc_0_first_steps")
  -- 1. First Steps: a plant and an ore held
  inv.add("astro", "fiber", 1)
  inv.add("astro", "regolith", 1)
  wait_for(function() return (save.get("prog.done") or {}).first_steps == true end, 8, "First Steps")
  AR.check("first_steps", (save.get("prog.done") or {}).first_steps == true and RS.isUnlocked("buildkit"),
    "First Steps done · the Build Kit %s", tostring(RS.isUnlocked("buildkit")))
  wait(1.5)
  AR.shot("arc_1_banner")
  local kit_n = 0
  wait_for(function()
    kit_n = 0
    for _, r in ipairs(C.roster()) do kit_n = kit_n + (inv.itemCount(C.packOf(r.id), "buildkit") or 0) end
    return kit_n > 0
  end, 12, "the kit issued")
  AR.check("kit_issued", kit_n > 0, "%d Build Kit(s) issued to the Engineer(s) at the base", kit_n)
  AR.check("homestead_open", AR.state(MI, "homestead") == "active" and AR.state(MI, "relay_net") == "locked",
    "Homestead %s · Relay Network %s (%s)", tostring(AR.state(MI, "homestead")), tostring(AR.state(MI, "relay_net")), tostring(select(2, AR.state(MI, "relay_net"))))
  wait(8.5)   -- (the MILESTONE banner's 9 s)
  AR.card("homestead")
  P("AR LINES homestead: %s", AR.lines(MI, "homestead"))
  AR.shot("arc_1_homestead_auto")
  AR.pick("homestead"); wait(0.6)
  AR.card("homestead picked")
  AR.shot("arc_1_homestead")
  -- 2. Homestead: the ruin near home, found and claimed
  local s = RU.nearOf(b.name)
  if not AR.check("near_site", s ~= nil, "%s", s and s.name or "none") then AR.result() return end
  wait_for(function() local e = RU.state(s.id); return e.sid ~= nil end, 45, "the near site stamped")
  local e = RU.state(s.id)
  if not AR.check("near_stamped", e.sid ~= nil, "structure %s", tostring(e.sid)) then AR.result() return end
  RN.crew_at(s, 70)
  wait_for(function() return F.has("ruin_found") end, 8, "found")
  wait(0.6)
  AR.card("found")
  AR.shot("arc_2_found")
  AR.check("ruin_found", F.has("ruin_found"), "the ruin found at 70 m")
  local l1 = (MI.progGoalLines("homestead") or {})[1] or ""
  AR.check("wood_goal", wood or (l1:find("waived", 1, true) ~= nil and l1:sub(1, 3) == "✓"), "%s", l1)
  local ctx = { actor = { kind = "crew", node = astro(), id = C.activeId(), pack = "astro" }, ref = findScript, toast = function(m) P("AR TOAST %s", m) end }
  C.patch(C.activeId(), { role = "engineer" })
  local okcl, whycl = RU.claim(s.id, ctx)
  local bid = nil
  wait_for(function() local br = RU.baseOf(s.id); bid = br and br.id; return bid ~= nil end, 8, "the base founded")
  AR.check("claim", okcl and bid ~= nil and F.has("base_founded") and RS.isUnlocked("solarArray") and RS.isUnlocked("batteryBank"),
    "claimed (%s): base #%s · base_founded %s · Solar Array %s · Battery Bank %s", tostring(whycl or "ok"), tostring(bid), tostring(F.has("base_founded")),
    tostring(RS.isUnlocked("solarArray")), tostring(RS.isUnlocked("batteryBank")))
  -- the hut (and its yard), and a timber fence round the yard: 8 wood pieces
  -- placed through field_builder (which marks wood_built)
  local hsid, hrec = AR.build_hut(e.g)
  local FB = findScript("field_builder")
  local placed, why8 = 0, nil
  if wood and FB and FB.place then
    for _, x in ipairs({ 6, 8, 10, 12 }) do
      for _, z in ipairs({ -1, 1 }) do
        local p = { body = hrec.b, mode = "face", sid = hsid, lx = x, ly = 0.2, lz = z, yaw = 0, pitch = 0, roll = 0 }
        local s2, w2 = FB.place(hsid, "fence.wood", p, "money")
        if s2 then placed = placed + 1 else why8 = w2 end
      end
    end
  end
  AR.check("wood_built", not wood or F.count("wood_built") >= 8, "%d timber fence pieces placed (%s) · wood_built %d",
    placed, tostring(why8 or "ok"), F.count("wood_built"))
  hrec = ST.get(hsid)
  do
    wait_for(function() return (save.get("prog.done") or {}).homestead == true end, 5, "Homestead")
    AR.check("homestead", (save.get("prog.done") or {}).homestead == true and AR.state(MI, "lights_on") == "active"
      and AR.state(MI, "shelter") == "active" and AR.state(MI, "salvage") == "active",
      "Homestead done · Lights On %s · Shelter %s · Salvage %s", tostring(AR.state(MI, "lights_on")), tostring(AR.state(MI, "shelter")), tostring(AR.state(MI, "salvage")))
  end
  local OS = findScript("ops_strip")
  local hist = {}
  for _, h in ipairs(OS and OS.history and OS.history() or {}) do hist[#hist + 1] = tostring(h.who) .. ": " .. tostring(h.text) end
  P("AR OPS so far: %s", table.concat(hist, " | "))
  wait(9.5)
  AR.pick("lights_on"); wait(0.6)
  AR.card("lights_on")
  P("AR LINES lights_on: %s", AR.lines(MI, "lights_on"))
  AR.shot("arc_2_lights_on")
  -- 3. Lights On: the yard's grid carries its tower
  local yard = ST.get(e.sid)
  for _, p in ipairs(yard.bp) do if p.id == "solarArray" and p.wr then RU.repairPiece(e.sid, p.uid) end end
  local g = e.g
  local gl = math.sqrt(g.x * g.x + g.y * g.y + g.z * g.z)
  RN.daylight({ x = g.x / gl, y = g.y / gl, z = g.z / gl }, 60)
  local sl = BG.slotInfo and BG.slotInfo()
  P("AR YEAR: %s s (night ~%s s); slot %s s", tostring(sl and sl.Y), tostring(sl and sl.Y and math.floor(sl.Y / 2)), tostring(sl and sl.L))
  BG.rebuildNow()
  BG.chargeFull(e.sid, 1.0)
  local tp = BG.towerPower(bid)
  P("AR GRID: supply %.2f need %.2f stored %.0f/%.0f powered %s sources %s", tp.supply or -1, tp.need or -1, tp.stored or -1, tp.cap or -1, tostring(tp.powered), tostring(tp.sources))
  local okg, rs_g = AR.warp_until(10, function() return F.has("grid_served") end, 30)
  tp = BG.towerPower(bid)
  AR.check("grid_served", okg and RS.isUnlocked("tower"), "the yard's grid carried the tower a minute (%.0f s real at 10x) · powered %s · supply %.2f need %.2f · tower %s",
    rs_g, tostring(tp.powered), tp.supply or -1, tp.need or -1, tostring(RS.isUnlocked("tower")))
  hrec = ST.get(hsid)
  local brk, light, scrub = nil, nil, nil
  for _, p in ipairs(hrec.bp) do
    if p.id == "breaker63.steel" then brk = p.uid end
    if p.id == "lightFitting.steel" then light = p.uid end
    if p.id == "scrubber.steel" then scrub = p.uid end
  end
  -- a cable from the yard's bank to the hut's breaker panel (a breaker may double a line)
  local bank = nil
  for _, p in ipairs(yard.bp) do if p.id == "batteryBank" then bank = p.uid end end
  local cid, cwhy, _, clen = nil, "no bank", nil, nil
  if bank and brk then cid, cwhy, _, clen = CB.lay({ sid = e.sid, uid = bank }, { sid = hsid, uid = brk }) end
  AR.check("cable_laid", cid ~= nil and F.has("cable_laid"), "a cable from the yard's Battery Bank to the hut's breaker: %s (%s m) · feat %s",
    tostring(cid or cwhy), clen and string.format("%.0f", clen) or "-", tostring(F.has("cable_laid")))
  -- 4. Shelter: the hut sealed
  wait_for(function() local st = RA.state(hsid); return st and st.R ~= nil end, 10, "the hut's rooms")
  local st = RA.state(hsid)
  local rm = st and st.R and st.R.rooms and st.R.rooms[1]
  AR.check("room_sealed", F.has("room_sealed") and RS.isUnlocked("life") and AR.open("scrubber.steel"),
    "the hut: %d room(s), the first %s %.1f m³ · room_sealed %s · life support %s (%s)", st and st.R and #st.R.rooms or -1,
    rm and (rm.sealed and "sealed" or "leaky") or "-", rm and rm.m3 or -1, tostring(F.has("room_sealed")), tostring(RS.isUnlocked("life")),
    tostring(RS.lockLine("fluids") or "open"))
  wait(1.5)
  -- the crew inside, before dusk; then warp through the hour and the night
  AR.put_in(hrec, 3.6, 1.3, 0)
  wait(1.0)
  local csid, crid = RA.crewRoom()
  do
    local a, bb = astro(), space.body(hrec.b)
    local fr = findScript("kit_snap").frameOf(hrec)
    local dx, dy, dz = a.x - bb.x - hrec.x, a.y - bb.y - hrec.y, a.z - bb.z - hrec.z
    local pw = findScript("planet_walker")
    local st0 = RA.state(hsid)
    P("AR CREW: local (%.2f, %.2f, %.2f) · onFoot %s · airAt %s · outside p %.2f O2 %.3f",
      dx * fr.R.x + dy * fr.R.y + dz * fr.R.z, dx * fr.U.x + dy * fr.U.y + dz * fr.U.z, dx * fr.F.x + dy * fr.F.y + dz * fr.F.z,
      tostring(pw and pw.onFoot), tostring((RA.airAt(a.x, a.y, a.z))), st0 and st0.out and st0.out.p or -1, st0 and st0.out and st0.out.x or -1)
  end
  AR.check("crew_inside", csid == hsid, "the crew in room %s of structure %s", tostring(crid), tostring(csid))
  -- (an alien home's outside holds no O2: the hut closed round it. The rack's
  -- PURGE, from its menu as the player would: the gas pumped overboard, the
  -- regulator refilling the hut; never a direct fill)
  local st1 = RA.state(hsid)
  if st1 and st1.out and (st1.out.x or 0) < 0.15 then
    local rid = crid or 1
    local q0 = RA.airOf(hsid, rid)
    local rack = nil
    for _, p in ipairs(hrec.bp) do if p.id == "airTank.steel" then rack = p.uid end end
    -- the rack's menu, opened on it (its rows: the plan, the switch)
    local CM, rn = findScript("context_menu"), rack and ST.nodeOf(hsid, rack)
    local okm = false
    if CM and rn then
      local w = rn.worldPos
      local t = CM.resolve({ node = rn, x = w.x, y = w.y, z = w.z }, astro())
      okm = t ~= nil and CM.openFor(t) == true
    end
    wait(0.8)
    local rows, info = {}, nil
    for _, e in ipairs(CM and CM.entries and CM.entries() or {}) do
      rows[#rows + 1] = tostring(e.id)
      if e.id == "ra_purge_i" or (type(e.id) == "string" and e.id:find("ra_purge_i", 1, true)) then info = type(e.value) == "function" and e.value() or e.value end
    end
    P("AR PURGE MENU: opened %s · rows %s · plan: %s", tostring(okm), table.concat(rows, ","), tostring(info))
    local pi = RA.purgeInfo(hsid, rid)
    AR.shot("arc_3_purge_menu")
    local ok, warn = RA.startPurge(hsid, rid, "hand")
    P("AR PURGE: outside O2 %.3f at %.2f atm · the hut %.2f atm CO2 %.0f %% (%s) · plan %s · started %s %s",
      st1.out.x or -1, st1.out.p or -1, q0 and q0.p or -1, q0 and 100 * q0.co2 / math.max(q0.p, 1e-6) or -1, q0 and tostring(q0.why) or "-",
      RA.purgeLine(pi), tostring(ok), tostring(warn))
    wait(3.0)
    AR.shot("arc_3_purging")
    if CM and CM.close then CM.close() end
    local a0p = save.get("agency.clock") or 0
    local okp, rsp = AR.warp_until(10, function() local q = RA.airOf(hsid, rid); return q and not q.purging and q.breathable end, 90)
    local q1 = RA.airOf(hsid, rid)
    AR.check("purged", okp and q1 and q1.breathable and not (RA.lastPurge and RA.lastPurge.why ~= "done"),
      "the hut purged and refilled from its rack: %.2f atm · O2 %.2f · CO2 %.4f atm in %.0f s game (%.0f s real at 10x; plan %.0f + %.0f s) · rack %.1f m³ left",
      q1 and q1.p or -1, q1 and q1.o2 or -1, q1 and q1.co2 or -1, (save.get("agency.clock") or 0) - a0p, rsp, pi and pi.plan.pump or -1, pi and pi.plan.fill or -1,
      (RA.state(hsid).tanks or {})[rack] or -1)
  end
  AR.ops_shots()

  wait(9.5)   -- (the goal banners' 9 s)
  AR.pick("shelter"); wait(0.6)
  AR.card("shelter_inside")
  AR.shot("arc_3_shelter_inside")
  BG.rebuildNow()
  BG.chargeFull(e.sid, 1.0)
  local a0 = save.get("agency.clock") or 0
  local function status()
    local tq = BG.towerPower(bid)
    local q = RA.airOf(hsid, crid or 1)
    local gn = (save.get("feats.gn") or {})
    local ph = {}
    for k, v in pairs(gn) do ph[#ph + 1] = tostring(k) .. "=" .. tostring(v.ph) .. (v.ok == false and "(shed)" or "") .. (v.out and "(out)" or "") end
    P("AR NIGHT: +%.0f s agency · supply %.2f need %.2f stored %.0f/%.0f powered %s · air %s · in %s · %s · night_held %s breathable %s slept %s",
      (save.get("agency.clock") or 0) - a0, tq.supply or -1, tq.need or -1, tq.stored or -1, tq.cap or -1, tostring(tq.powered),
      q and ((q.breathable and "breathable" or tostring(q.why)) .. (q.venting and (" VENTING: " .. table.concat(q.causes or {}, ", ")) or "")
        .. string.format(" (S %.2g G %.2g)", q.S or 0, q.G or 0)) or "-", tostring((RA.crewRoom())), table.concat(ph, " "),
      tostring(F.has("night_held")), tostring(F.has("room_breathable")), tostring(F.has("slept_in")))
    local al = F.airLast
    P("AR AIRSTEP: %s", al and string.format("sid %s · %s · %.0f s counted · %s nets", tostring(al.sid), tostring(al.why), al.t or 0, tostring(al.n)) or "never called")
  end
  status()
  local rate = tonumber(params.arcwarp) or 50
  local okn, rs_n = AR.warp_until(rate, function() return F.has("night_held") and F.has("room_breathable") and F.has("slept_in") end,
    tonumber(params.arcnight) or 150, status)
  status()
  AR.check("room_breathable", F.has("room_breathable") and RS.isUnlocked("fluids"), "an hour of the hut's own air, its scrubber running · fluids %s",
    tostring(RS.isUnlocked("fluids")))
  AR.check("night_held", F.has("night_held") and RS.isUnlocked("power2") and RS.isUnlocked("powerCable35"),
    "the yard's grid held through a night (%.0f s real at %dx) · heavy power %s", rs_n, rate, tostring(RS.isUnlocked("power2")))
  AR.check("slept_in", F.has("slept_in"), "the crew inside the sealed hut from dusk to dawn")
  wait(2.5)
  AR.check("lights_on", (save.get("prog.done") or {}).lights_on == true and AR.state(MI, "relay_net") == "active" and AR.state(MI, "ironworks") == "active",
    "Lights On %s · Relay Network %s · Ironworks %s · Wheels %s", tostring(AR.state(MI, "lights_on")), tostring(AR.state(MI, "relay_net")),
    tostring(AR.state(MI, "ironworks")), tostring(AR.state(MI, "wheels")))
  AR.check("shelter", (save.get("prog.done") or {}).shelter == true and AR.state(MI, "underground") == "active",
    "Shelter %s · Underground %s · lines: %s", tostring(AR.state(MI, "shelter")), tostring(AR.state(MI, "underground")), AR.lines(MI, "shelter"))
  AR.check("no_captions", true, "(milestones speak on the Ops strip; see AR OPS)")
  hist = {}
  for _, h in ipairs(OS and OS.history and OS.history() or {}) do hist[#hist + 1] = tostring(h.who) .. ": " .. tostring(h.text) end
  P("AR OPS: %s", table.concat(hist, " | "))
  -- the card now (outside, by the hut)
  AR.put_in(hrec, -1.5, 1.2, 0)
  wait(10)
  AR.card("after")
  AR.shot("arc_4_after_shelter_auto")
  AR.pick("salvage"); wait(0.6)
  AR.card("salvage")
  P("AR LINES salvage: %s", AR.lines(MI, "salvage"))
  AR.shot("arc_4_salvage")
  local co = findScript("company")
  P("AR MONEY: %s · rep %s", co and co.money and co.money(co.balance()) or "?", co and co.rep and tostring(co.rep()) or "?")
  AR.result()
end

-- AN OLD SAVE (a copy): nothing it had is locked, its milestones stand.
function AR.old()
  wait_ready(150)
  wait(4)
  local MI, RS, F = findScript("missions"), findScript("research"), findScript("feats")
  if not AR.check("scene", MI and RS and F and F.gridTick ~= nil, "") then AR.result() return end
  wait_for(function() return (tonumber(save.get("feats.mig")) or 0) >= 2 end, 10, "the migration")
  local pd, pm, rd = save.get("prog.done") or {}, save.get("prog.perm") or {}, save.get("res.done") or {}
  local dl = {}
  for k in pairs(pd) do dl[#dl + 1] = k end
  table.sort(dl)
  P("AR OLD: mode %s · prog.done %s · feats.mig %s · prog.open %s", tostring(save.get("game.mode")), table.concat(dl, ","), tostring(save.get("feats.mig")),
    tostring(save.get("prog.open") and save.get("prog.open").relay_net))
  local locked = {}
  local n = 0
  for id, v in pairs(rd) do if v then n = n + 1; if not RS.isUnlocked(id) then locked[#locked + 1] = id end end end
  local rn = type(pm.relay_net) == "table" and pm.relay_net or {}
  local had_kit = pd.relay_net or rn[1] or rn["1"]
  local want = { "buildkit" }
  if had_kit then for _, t in ipairs({ "tower", "power2", "life", "fluids", "logic", "quarry", "shoring", "scrubber.steel", "flPump.steel", "lsGas.steel", "transformer.steel", "powerCable95" }) do want[#want + 1] = t end end
  for _, t in ipairs(want) do if not AR.open(t) then locked[#locked + 1] = t end end
  AR.check("old_unlocks", #locked == 0, "%d researched + %d the kit implied: locked now %s", n, #want, #locked > 0 and table.concat(locked, ",") or "none")
  local stood = true
  for id in pairs(pd) do if AR.state(MI, id) ~= "done" then stood = false end end
  AR.check("old_milestones", stood and AR.state(MI, "homestead") == "active" and (not pd.first_steps or pd.relay_net or AR.state(MI, "relay_net") == "active"),
    "its milestones stand · Homestead %s · Relay Network %s · Sky %s", tostring(AR.state(MI, "homestead")), tostring(AR.state(MI, "relay_net")), tostring(AR.state(MI, "sky")))
  local fl = {}
  for id, e in pairs(save.get("feats") or {}) do fl[#fl + 1] = id .. "=" .. tostring(e.n) end
  table.sort(fl)
  P("AR OLD FEATS: %s", table.concat(fl, " "))
  wait(10)
  AR.card("old")
  AR.shot("arc_old_card")
  AR.result()
end
