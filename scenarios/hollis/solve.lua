-- WHAT HOLLIS LEFT: the probe's solution (tools/perf/scnprobe.sh <engine> hollis).
-- Spliced after scnprobe_modes.lua. Plays the camp through the systems the
-- menus call (ruins.claim, base_power.setBreaker, ruins.restore by lot,
-- room_air.repairSeal, ruins.repairPiece), reads the cores the way E does
-- (the terminal's CORE page on a console; the spot's act on a bunk or a
-- block), answers the dialogue, and takes the pictures of every act.
--   default: THE READ ENDING, the gold order: the bunk room's roof first,
--   every core read, Teodor decides about the fourth and reads it.
--   BENCH_STRS='("branch", "seal")': THE SEALED ENDING, the wrong order: the
--   shed's roof first ($1,700), so the allowance no longer covers the bunk
--   room; Brennan's advance taken; the fourth core sealed unread.
local S = "Lindqvist Camp"
local HS = {}
local function srec()
  local ST = findScript("structures")
  local sid = (save.get("scn.structs") or {})[S]
  return sid and ST.get(sid), sid
end
-- a camera in the camp's own frame, re-placed every frame (docs/positions-and-frames.md)
local function sl(lx, ly, lz)
  local ST = findScript("structures")
  local r = srec()
  if not r then return nil end
  local ux, uy, uz, fx, fy, fz, rx, ry, rz = ST.frame(r)
  local b = space.body(r.b)
  return { x = b.x + r.x + rx * lx + ux * ly + fx * lz, y = b.y + r.y + ry * lx + uy * ly + fy * lz, z = b.z + r.z + rz * lx + uz * ly + fz * lz }
end
function lateUpdate(node, dt)
  local c = HS.cam
  if not (c or HS.camw) then return end
  local pc = findScript("planet_camera")
  if not (pc and pc.setFreecam) then return end
  local eye, tgt
  if HS.camw then eye, tgt = HS.camw() else eye, tgt = sl(c[1], c[2], c[3]), sl(c[4], c[5], c[6]) end
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
local function cam_off()
  HS.cam, HS.camw = nil, nil
  local pc = findScript("planet_camera")
  if pc and pc.setFreecam then pc.setFreecam(false) end
end
local function view(nm, e, t, ui)
  HS.cam = { e[1], e[2], e[3], t[1], t[2], t[3] }
  wait(1.4)
  SP.shot(nm, ui == true)
  cam_off()
  wait(0.3)
end

-- the dialogue: lines clicked through, choices answered by policy
local POLICY = {}
local HOLD = false
-- STOPS: a picture when a line matching { who, text part } comes up (once each)
local STOPS = {}
local function talk(sr)
  local st = sr.state()
  if st.line and not st.choice then
    for i, sp in ipairs(STOPS) do
      if st.line.who == sp.who and (not sp.part or tostring(st.line.text):find(sp.part, 1, true)) then
        table.remove(STOPS, i)
        wait(sp.after or 1.6)
        SP.shot(sp.shot, true)
        break
      end
    end
  end
  if st.choice then
    local p = tostring(st.choice.prompt or "")
    local pick = nil
    for k, v in pairs(POLICY) do if p:find(k, 1, true) then pick = v end end
    if pick then
      P("HS CHOICE %q → %d (%s)", p, pick, tostring(st.choice.options and st.choice.options[pick]))
      sr.choose(pick)
    end
  elseif st.line and not HOLD and st.line.t0 and (time - st.line.t0) > 0.8 then
    sr.lineDone()
  end
end
local function until_(sr, cond, tmo, what)
  local t0 = W()
  while W() - t0 < (tmo or 60) do
    talk(sr)
    if cond() then return true end
    yield()
  end
  P("HS TIMEOUT %s", tostring(what))
  SP.readings("timeout " .. tostring(what))
  return false
end
local function talk_for(sr, secs) local t0 = W(); while W() - t0 < secs do talk(sr); yield() end end
local function done(id) return (save.get("scn.done") or {})[id] ~= nil end
local function step(sr, id, tmo) local ok = until_(sr, function() return done(id) end, tmo or 60, id); SP.check("step_" .. id, ok, "%s latched", id); return ok end
local function apart(sr, a, b)
  local p, q = sr.posOf(a), sr.posOf(b)
  if not (p and q and p.body == q.body) then return nil end
  local l = math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z)
  local dx, dy, dz = p.x - q.x, p.y - q.y, p.z - q.z
  local du = (dx * q.x + dy * q.y + dz * q.z) / l
  return math.sqrt(math.max(0, dx * dx + dy * dy + dz * dz - du * du))
end
-- the player's view turned to a ref for a moment (body-relative, re-read each frame)
local function look_at(sr, who, secs, lift)
  local pc = findScript("planet_camera")
  local t0 = W()
  while W() - t0 < (secs or 1.0) do
    local x, y, z = sr.pointOf(who)
    local q = sr.posOf(who)
    if x and pc and pc.face and pc.cam_x then
      local l = math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z)
      local h = lift or 1.2
      local tx, ty, tz = x + q.x / l * h, y + q.y / l * h, z + q.z / l * h
      local dx, dy, dz = tx - pc.cam_x, ty - pc.cam_y, tz - pc.cam_z
      local d = math.sqrt(dx * dx + dy * dy + dz * dz)
      local du = (dx * q.x + dy * q.y + dz * q.z) / l
      pc.face(dx, dy, dz, math.atan2(du, math.sqrt(math.max(0, d * d - du * du))))
    end
    talk(sr)
    yield()
  end
end
-- over the player's shoulder at member `who`'s face
local function over_shoulder(sr, nm, who)
  HS.camw = function()
    local a, q = sr.posOf("crew:Haddad"), sr.posOf(who)
    if not (a and q and a.body == q.body) then return nil end
    local b = space.body(a.body)
    local l = math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
    local ux, uy, uz = a.x / l, a.y / l, a.z / l
    local dx, dy, dz = q.x - a.x, q.y - a.y, q.z - a.z
    local du = dx * ux + dy * uy + dz * uz
    dx, dy, dz = dx - ux * du, dy - uy * du, dz - uz * du
    local m = math.sqrt(dx * dx + dy * dy + dz * dz)
    if m < 1e-3 then return nil end
    dx, dy, dz = dx / m, dy / m, dz / m
    local rx, ry, rz = dy * uz - dz * uy, dz * ux - dx * uz, dx * uy - dy * ux
    local ex, ey, ez = b.x + a.x - dx * 1.1 + rx * 0.45 + ux * 0.85, b.y + a.y - dy * 1.1 + ry * 0.45 + uy * 0.85, b.z + a.z - dz * 1.1 + rz * 0.45 + uz * 0.85
    local tx, ty, tz = b.x + q.x + ux * 0.75, b.y + q.y + uy * 0.75, b.z + q.z + uz * 0.75
    return { x = ex, y = ey, z = ez }, { x = tx, y = ty, z = tz }
  end
  wait(1.2)
  SP.shot(nm, true)
  cam_off()
end
-- E at a console: its terminal, on the CORE page, a picture, closed
local function read_at_console(sr, nm, uid)
  local T = findScript("terminal")
  local _, sid = srec()
  local ok, why = T.openAt(sid, uid)
  wait(1.5)
  local st = T.state()
  SP.check(nm .. "_page", ok and st and st.page == "CORE", "the terminal opens on %s (%s)", tostring(st and st.page), tostring(why))
  wait(1.0)
  SP.shot(nm, true)
  T.close()
  wait(0.5)
end
-- E on a spot (a bunk, a block): the spot's own act, as the prompt's E calls it
local function press_spot(sr, key)
  local T = findScript("terminal")
  local sp = T.spots and T.spots()[key]
  if not sp then P("HS no spot %s", key) return false end
  local lbl = type(sp.label) == "function" and sp.label() or sp.label
  P("HS SPOT %s: %s", key, tostring(lbl))
  sp.act()
  return true
end

function SOLVE(SP)
  local sr = SP.run_()
  local RU, ST, RA, BP, co = findScript("ruins"), findScript("structures"), findScript("room_air"), findScript("base_power"), findScript("company")
  local seal = tostring(params.branch or "") == "seal"
  P("HS branch %s", seal and "SEALED (wrong order, the advance, the core sealed)" or "READ (gold order, every core)")
  POLICY = { ["Do you believe it"] = 3, ["Give me a second"] = 1, ["seal the fourth"] = seal and 1 or 3,
             ["What are you going to do with it"] = seal and 1 or 3, ["Hendry's advance"] = seal and 1 or 2,
             ["Brennan's advance"] = seal and 1 or 2, ["What happens to the camp"] = seal and 1 or 2 }
  local r, sid = srec()
  SP.check("camp", r ~= nil and r.ru ~= nil, "Lindqvist Camp staged as a ruin: %s (%d pieces)", tostring(r and r.ru), r and #r.bp or 0)
  local id = r and r.ru
  P("HS FUNDS %d", co.balance())
  do
    -- ── ACT 1 ──
    if sr.state().cutscene then
      wait(3.0); SP.shot("a0_arrival_orbit", true)
      wait(6.0); SP.shot("a0_arrival_dolly", true)
      until_(sr, function() return not sr.state().cutscene end, 30, "arrival ends")
    end
    wait(0.5)
    local d0 = apart(sr, "crew:Lindqvist", "crew:Haddad") or -1
    HOLD = true
    local came = until_(sr, function() local d = apart(sr, "crew:Lindqvist", "crew:Haddad"); return d and d < 2.0 end, 20, "Teodor walks up")
    until_(sr, function() local st = sr.state(); return st.line and st.line.who == "teo" end, 10, "Teodor speaks")
    HOLD = false
    local d1 = apart(sr, "crew:Lindqvist", "crew:Haddad") or -1
    SP.check("teo_walks_up", came and d1 > 0.9, "Teodor from %.1f m to %.2f m, face to face", d0, d1)
    look_at(sr, "crew:Lindqvist", 1.2, 0.55); SP.shot("a1_teodor_face_to_face", true)
    until_(sr, function() return sr.var("arrive") ~= nil end, 60, "the first choice")
    until_(sr, function() local st = sr.state(); return st.line and st.line.who == "brennan" end, 30, "Brennan")
    wait(0.4); SP.shot("a1_brennan_radio", true)
    talk_for(sr, 6)
    -- the walk in: the ruin from the flats, then the door
    view("a1_ruin_from_flats", { 2.5, 1.7, -40 }, { 4, 2.0, 2 }, false)
    view("a1_ruin_close", { -3.5, 1.8, -7.5 }, { 3.0, 1.2, 2.0 }, false)
    SP.stand("mark:approach", 30)
    talk_for(sr, 2)
    SP.stand("mark:front", 30)
    step(sr, "walk", 30)
    view("a1_ruin_inside_mess", { 4.2, 1.6, -0.3 }, { 0.5, 1.0, 2.5 }, false)
    -- core 1: the mess terminal's CORE page
    SP.stand("mark:mess", 30)
    read_at_console(sr, "a1_core1_terminal", 60)
    step(sr, "core1", 20)
    talk_for(sr, 8)
    -- ── ACT 2 ──
    local ok = RU.claim(id, nil, true)
    SP.check("claim", ok == true, "the tower claimed (%s)", tostring(ok))
    step(sr, "claim", 20)
    BP.setBreaker(sid, 73, true, "hand")
    local up = until_(sr, function() return done("power") end, 60, "the grid")
    local g = findScript("base_grid") and findScript("base_grid").gridOfStruct and findScript("base_grid").gridOfStruct(sid)
    SP.check("step_power", up, "the camp's grid: %s", g and string.format("%.2f kW made, %.2f drawn, %s", g.supply or 0, g.need or 0, tostring(g.powered)) or "none")
    talk_for(sr, 3)
    view("a2_workshop_lamp", { 6.0, 1.7, -0.4 }, { 7.3, 1.1, 2.5 }, false)
    SP.stand("mark:shop", 30)
    read_at_console(sr, "a2_core2_terminal", 70)
    step(sr, "core2", 20)
    local pol = POLICY["Give me a second"]
    POLICY["Give me a second"] = nil
    until_(sr, function() local st = sr.state(); return st.choice ~= nil end, 30, "Teodor's choice")
    wait(0.3); SP.shot("a2_teodor_still", true)
    POLICY["Give me a second"] = pol
    talk_for(sr, 10)
  end
  -- ── ACT 3 ──
  if seal then
    RU.restore(id, false, "shed")
    P("HS FUNDS after the shed roof %d", co.balance())
    until_(sr, function() return sr.var("owed") == true and co.balance() >= 1300 end, 40, "Brennan's advance")
    P("HS FUNDS after the advance %d", co.balance())
  end
  local n = RU.restore(id, false, "bunks")
  SP.check("bunks_roof", n == 5, "the bunk room's roof: %s pieces (funds left %d)", tostring(n), co.balance())
  view("a3_bunk_roof_back", { -3.5, 4.2, 1.5 }, { 2.5, 2.0, 5.0 }, false)
  SP.stand("mark:bunk", 30)
  RA.repairSeal(sid, 27)
  step(sr, "room", 30)
  -- the room is sealed: the shock case opens (the solve reads the rule first:
  -- a refusal is pictured when it would refuse)
  STOPS = { { who = "agnes", part = "Lander at six", shot = "a3_core3_plate", after = 2.2 },
            { who = "brennan", part = "fourth core", shot = "a3_brennan_demand", after = 2.0 },
            { who = "agnes", part = "Day nine", shot = "a4_core4_plate", after = 2.2 },
            { who = "teo", part = "She went up on the roof", shot = "a4_teodor_roof", after = 1.2 },
            { who = "brennan", part = "Good morning", shot = "a5_brennan_last_read", after = 1.6 },
            { who = "brennan", part = "Counsel has the case number", shot = "a5_brennan_last_sealed", after = 1.6 },
            { who = "teo", part = "Mum.", shot = "a5_teodor_counts", after = 1.0 },
            { who = "kestrel", part = "Coming over the ridge", shot = "a5_first_light", after = 1.5 },
            { who = "teo", part = "Her console", shot = "a4_shed_console", after = 1.5 } }
  local okc = sr.coreReadable and sr.coreReadable("c3")
  SP.check("air", okc == true, "the shock case's rule: a sealed room round it (%s)", tostring(okc))
  if not okc then press_spot(sr, "core:c3"); wait(0.5); SP.shot("a3_core3_refused", true) end
  press_spot(sr, "core:c3")
  step(sr, "core3", 90)
  until_(sr, function() return (sr.var("choice4") or "") ~= "" end, 90, "Brennan's choice")
  talk_for(sr, 6)
  view("a3_teodor_on_the_bunk", { 2.6, 1.6, 4.2 }, { 0.6, 1.0, 6.1 }, false)
  -- ── ACT 4 ──
  until_(sr, function() return sr.state().stepId == "shed" end, 30, "act 4")
  space.warp(4)
  talk_for(sr, 12)
  space.warp(1)
  SP.stand("mark:shed", 30)
  view("a4_shed_night", { 17.0, 1.7, -7.0 }, { 16.5, 1.2, 1.5 }, false)
  SP.stand("mark:shedin", 30)
  until_(sr, function() return sr.state().cutscene end, 20, "the shed")
  until_(sr, function() return not sr.state().cutscene end, 40, "the shed ends")
  RU.repairPiece(sid, 117)
  step(sr, "shed", 30)
  local K4 = "What are you going to do with it"
  local pol4 = POLICY[K4]
  POLICY[K4] = nil
  press_spot(sr, "core:c4")
  until_(sr, function() local st = sr.state(); return st.choice ~= nil and tostring(st.choice.prompt):find(K4, 1, true) ~= nil end, 30, "the case")
  wait(0.6); SP.shot("a4_core4_choice", true)
  POLICY[K4] = pol4
  step(sr, "core4", 120)
  -- ── the morning ──
  step(sr, "dawn", 150)
  for _, k in ipairs({ "trust", "cores_read", "choice4", "owed", "teo_read", "camp", "core_c1", "core_c2", "core_c3", "core_c4" }) do P("HS VAR %s = %s", k, tostring(sr.var(k))) end
  P("HS FUNDS end %d", co.balance())
  SP.check("ending", (seal and sr.var("core_c4") == "sealed") or (not seal and sr.var("core_c4") == "read" and sr.var("cores_read") == 4),
    "core 4 %s, %s cores read", tostring(sr.var("core_c4")), tostring(sr.var("cores_read")))
  wait(2); SP.shot("a5_debrief", true)
end
