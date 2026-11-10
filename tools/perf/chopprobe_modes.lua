-- ── chop probe (tools/perf/chopprobe.sh): playtest 11-10 "choppy from the ──
-- first base plate". Spliced after vfxprobe_modes.lua, buildkitprobe_modes.lua
-- (BK) and kitprobe_modes.lua (KIT).
--   chop   on flat ground 150+ m out: 10 s on foot (kit shut), 8 s with the
--          kit open and a Pad Plate's ghost under the cursor, the plate placed
--          by a click (the kit's own path), 10 s after it with the ghost up;
--          then a 40-piece base beside it (16 slabs, 16 walls, 4 roof floors,
--          4 more slabs), each piece's ghost aimed at its spot for 0.4 s and
--          placed by field_builder.placeAt (pose → snap → validity → place);
--          then 10 s with the kit open and 10 s with it shut. Every frame over
--          `chopms` (25) ms is printed with its buckets, parts, scripts and
--          hottest lines (`CHOP SLOW`), and every placement's own frames
--          (`CHOP PLACE`: the worst frame in the 0.5 s after it).
-- `CHOP RESULT` compares the shut-kit windows before and after the base.
CHOP = { slow = 0, worst = 0, lastf = -1 }

function CHOP.watch(tag)
  if not perf.frames then return end
  local fr = perf.frames(8) or {}
  for _, f in ipairs(fr) do
    if f.frame and f.frame > CHOP.lastf then
      CHOP.lastf = f.frame
      local ms = f.ms or 0
      if ms > CHOP.worst then CHOP.worst = ms end
      if CHOP.win then CHOP.win.max = math.max(CHOP.win.max, ms); CHOP.win.n = CHOP.win.n + 1; if ms > 33.3 then CHOP.win.over = CHOP.win.over + 1 end end
      if ms > (params.chopms or 25) then
        CHOP.slow = CHOP.slow + 1
        local b, p, s, sm = {}, {}, {}, {}
        for k, v in pairs(f.buckets or {}) do if v > 0.5 then b[#b + 1] = { k, v } end end
        for k, v in pairs(f.parts or {}) do if v > 0.5 then p[#p + 1] = { k, v } end end
        for _, e in ipairs(f.scripts or {}) do if (e.ms or 0) > 0.3 then s[#s + 1] = { e.name, e.ms } end end
        for _, e in ipairs(f.samples or {}) do if (e.ms or 0) > 0.3 then sm[#sm + 1] = { string.format("%s:%s:%s", e.script or "?", e.fn or "?", tostring(e.line or "?")), e.ms } end end
        local function srt(t) table.sort(t, function(a, c) return a[2] > c[2] end); local o = {}; for i = 1, math.min(#t, 8) do o[i] = t[i] end; return o end
        P("CHOP SLOW [%s] frame %d %.1f ms ticks %s | buckets %s | parts %s | scripts %s | lines %s", tag, f.frame, ms, tostring(f.ticks),
          fmtk(srt(b)), fmtk(srt(p)), fmtk(srt(s)), fmtk(srt(sm)))
      end
    end
  end
end
-- wait `secs`, watching every frame (and re-aiming the cursor when asked)
function CHOP.wait(tag, secs, aim)
  local t_end = time + secs
  while time < t_end do
    if aim and BK.aimfn then BK.aimfn() end
    yield()
    CHOP.watch(tag)
  end
end
function CHOP.window(name, secs, aim)
  CHOP.win = { max = 0, n = 0, over = 0 }
  sc_begin(name)
  CHOP.wait(name, secs, aim)
  sc_end(name)
  local w = CHOP.win
  CHOP.win = nil
  P("CHOP WINDOW %s: %d frames, max %.1f ms, %d over 33 ms", name, w.n, w.max, w.over)
  return w
end
-- one piece: its ghost aimed at the ray's hit for `ghost` s, then placed
function CHOP.piece(fb, ST, sid, id, a, b, tag)
  fb.hold(id)
  local rec = ST.get(sid)
  BK.aim_local(ST, sid, b[1], b[2], b[3])
  CHOP.win = { max = 0, n = 0, over = 0 }
  CHOP.wait("ghost " .. tag, params.chopghost or 0.4, true)
  local gw = CHOP.win
  rec = ST.get(sid)
  local h = KIT.ray(rec, a, b)
  local t0 = W()
  local uid, why
  if h then
    local s2, w2, _, u2 = fb.placeAt(h.x, h.y, h.z, h.nx, h.ny, h.nz, h.node)
    uid, why = u2, w2
    if not s2 then uid = nil end
  else why = "no hit" end
  local callms = (W() - t0) * 1000
  CHOP.win = { max = 0, n = 0, over = 0 }
  CHOP.wait("after " .. tag, 0.5, true)
  local aw = CHOP.win
  CHOP.win = nil
  P("CHOP PLACE %-16s %-18s %s · placeAt %.1f ms · ghost max %.1f · after max %.1f (%d frames, %d >33)", tag, id,
    uid and ("uid " .. uid) or ("REFUSED " .. tostring(why)), callms, gw.max, aw.max, aw.n, aw.over)
  CHOP.n = (CHOP.n or 0) + (uid and 1 or 0)
  CHOP.placeMax = math.max(CHOP.placeMax or 0, aw.max, gw.max)
  return uid
end

function CHOP.run()
  BK.tag = "chop"
  if perf.hitchThreshold then perf.hitchThreshold(33) end
  wait_ready(120)
  wait(2)
  local fb, ST, C = findScript("field_builder"), findScript("structures"), findScript("crew")
  local spot = BK.flat_spot()
  if not BK.check("spot", spot ~= nil, "flat ground %s m out", spot and spot.d or -1) then BK.result() return end
  stand_at(spot)
  BK.F = spot.t
  wait(4)
  key_down("w"); wait(0.6); key_up("w"); wait(1.5)
  do
    local pc0 = findScript("planet_camera")
    local U = unit(sub(astro(), home()))
    local f = { x = pc0.fwd_x or BK.F.x, y = pc0.fwd_y or BK.F.y, z = pc0.fwd_z or BK.F.z }
    BK.F = unit(sub(f, scl(U, dot(f, U))))
  end
  BK.unlock()
  C.patch(C.activeId(), { role = "engineer" })
  wait(4)
  if perf.sampleScripts and (params.chopsample or 1) > 0 then perf.sampleScripts(true) end
  local w0 = CHOP.window("c0_idle_shut", 10)
  tap("b"); wait(1.5)
  BK.check("open", fb.isOpen(), "B opens the kit (gate %s)", tostring(fb.gate))
  local cp = findScript("catalog_panel")
  cp.pickPart("padPlate")
  BK.aim_at(9, 0)
  for _ = 1, 20 do BK.aimfn(); yield() end
  local w1 = CHOP.window("c1_ghost_before", 8, true)
  -- THE FIRST PLATE, by a click
  CHOP.win = { max = 0, n = 0, over = 0 }
  BK.aimfn()
  sc_begin("c2_first_plate")
  BK.click(false)
  CHOP.wait("first plate", 1.0, true)
  local wfirst = CHOP.win
  P("CHOP FIRST PLATE: placed %s, worst frame in the 1 s after the click %.1f ms (%d over 33)", tostring(fb.lastPlace and fb.lastPlace.sid),
    wfirst.max, wfirst.over)
  CHOP.wait("first plate", 9.0, true)
  sc_end("c2_first_plate")
  CHOP.win = nil
  local sidPad = fb.lastPlace and fb.lastPlace.sid
  BK.check("pad", sidPad ~= nil, "the Pad Plate placed (struct %s)", tostring(sidPad))
  -- THE 40-PIECE BASE: a first slab founds it 22 m to the side (past the 12 m join)
  fb.hold("slab2.concrete")
  BK.aim_at(8, -22)
  CHOP.wait("ghost slab0", 0.5, true)
  local g = BK.ground_ahead(8, -22)
  sc_begin("c3_build40")
  CHOP.win = { max = 0, n = 0, over = 0 }
  local sid, why = fb.placeAt(g.x, g.y, g.z, g.nx, g.ny, g.nz, g.node)
  if not BK.check("slab0", sid ~= nil, "the first slab founds a structure (%s)", tostring(why)) then BK.result() return end
  CHOP.n = 1
  CHOP.wait("after slab0", 0.5, true)
  P("CHOP PLACE %-16s %-18s first slab · after max %.1f", "slab0", "slab2.concrete", CHOP.win.max)
  CHOP.placeMax = CHOP.win.max
  for i = 0, 3 do
    for j = 0, 3 do
      if not (i == 0 and j == 0) then
        local x, z = i * 2, j * 2
        CHOP.piece(fb, ST, sid, "slab2.concrete", { x, 4, z }, { x, -4, z }, "slab" .. i .. j)
      end
    end
  end
  -- walls on the outer edge lines (x, z ∈ -1 .. 7)
  for k = 0, 3 do
    local c = k * 2
    CHOP.piece(fb, ST, sid, "wall.steel", { c, 3, 6.7 }, { c, -2, 6.7 }, "wallF" .. k)
    CHOP.piece(fb, ST, sid, "wall.steel", { c, 3, -0.7 }, { c, -2, -0.7 }, "wallB" .. k)
    CHOP.piece(fb, ST, sid, "wall.steel", { -0.7, 3, c }, { -0.7, -2, c }, "wallL" .. k)
    CHOP.piece(fb, ST, sid, "wall.steel", { 6.7, 3, c }, { 6.7, -2, c }, "wallR" .. k)
  end
  -- a roof strip on the front walls' tops
  for k = 0, 3 do
    local c = k * 2
    CHOP.piece(fb, ST, sid, "floor.steel", { c, 5, 7 }, { c, 1, 7 }, "roof" .. k)
  end
  -- four more slabs along the side
  for k = 0, 3 do
    CHOP.piece(fb, ST, sid, "slab2.concrete", { 8, 4, k * 2 }, { 8, -4, k * 2 }, "slabX" .. k)
  end
  local wb = CHOP.win
  CHOP.win = nil
  sc_end("c3_build40")
  fb.dropHeld()
  local rec = ST.get(sid)
  P("CHOP BUILD: %d placed, %d pieces on the record; worst frame while building %.1f ms", CHOP.n or 0, rec and #rec.bp or -1, CHOP.placeMax or -1)
  -- steady state, the kit still open (nothing in hand), then shut
  local w4 = CHOP.window("c4_after_open", 10)
  KIT.close(fb)
  local w5 = CHOP.window("c5_after_shut", 10)
  local w6 = CHOP.window("c6_after_shut_b", 20)
  P("CHOP RESULT: before (shut) max %.1f ms; ghost before max %.1f; first plate 1 s max %.1f; build max %.1f; after open max %.1f; after shut max %.1f / %.1f; %d slow frames over %d ms",
    w0.max, w1.max, wfirst.max, CHOP.placeMax or -1, w4.max, w5.max, w6.max, CHOP.slow, params.chopms or 25)
  BK.check("smooth_build", (CHOP.placeMax or 99) <= 33.3, "no frame over 33 ms while building (%.1f)", CHOP.placeMax or -1)
  BK.result()
end

-- chopab: what the open kit itself costs, one thing at a time, at one spot
-- (nothing placed): shut; open with the icons being taken; open after every
-- icon; the column folded; a part in hand (the live preview); in hand folded;
-- in hand with the preview's camera held off.
function CHOP.run_ab()
  BK.tag = "chopab"
  if perf.hitchThreshold then perf.hitchThreshold(33) end
  wait_ready(120)
  wait(2)
  local fb, C = findScript("field_builder"), findScript("crew")
  local spot = BK.flat_spot()
  stand_at(spot)
  BK.F = spot.t
  wait(4)
  key_down("w"); wait(0.6); key_up("w"); wait(1.5)
  BK.unlock()
  C.patch(C.activeId(), { role = "engineer" })
  wait(4)
  local S = (params.absecs or 6)
  CHOP.window("ab0_shut", S)
  tap("b"); wait(0.5)
  local cp = findScript("catalog_panel")
  P("CHOP AB icons at open %d", cp.iconCount())
  CHOP.window("ab1_open_icons", S)
  P("CHOP AB icons after %d s: %d", S, cp.iconCount())
  local last, t_same = cp.iconCount(), time
  local t0 = time
  while time - t_same < 3 and time - t0 < 150 do
    CHOP.wait("icons", 0.5)
    local n = cp.iconCount()
    if n ~= last then last, t_same = n, time end
  end
  P("CHOP AB icons done: %d after %.0f s", cp.iconCount(), time - t0)
  CHOP.window("ab2_open_idle", S)
  fb.collapsed = true
  CHOP.wait("fold", 0.5)
  CHOP.window("ab3_open_folded", S)
  fb.collapsed = false
  cp.pickPart("padPlate")
  BK.aim_at(9, 0)
  CHOP.wait("pick", 1.0, true)
  CHOP.window("ab4_held", S, true)
  fb.collapsed = true
  CHOP.wait("fold", 0.5, true)
  CHOP.window("ab5_held_folded", S, true)
  fb.collapsed = false
  CHOP.wait("unfold", 0.5, true)
  local pcam = find("PartPreviewCam")
  local function camoff() local n = find("PartPreviewCam"); if n then n.enabled = false end end
  local aim0 = BK.aimfn
  BK.aimfn = function() aim0(); camoff() end
  CHOP.window("ab6_held_nopreview", S, true)
  BK.aimfn = aim0
  P("CHOP AB preview cam node %s", tostring(pcam ~= nil))
  KIT.close(fb)
  CHOP.window("ab7_shut_again", S)
  BK.result()
end
