-- ── physfix probe (tools/perf/physfixprobe.sh): playtest 2026-11-12 ──
-- Spliced into a copy of perfbench.lua before its main (like walkprobe).
-- "Died jumping on flat ground with a heavy-ish pack"; "the game often
-- freezes when an astronaut dies"; "repair animations janky". Modes:
--   packjump  jumps on flat ground (the base's graded ground and open
--             terrain) with 0..90 kg in the pack: standing, walking and
--             sprinting, three of each. Every Δv the fall monitor judges is
--             kept (crew.impactRule wrapped) and so is every kill (crew.kill
--             wrapped: logged, not done) and any hp lost. `PF JUMP` a set,
--             `PF PASS|FAIL packjump`.
--   deaths    deaths of several causes with death ON: a long fall (dead),
--             a shorter one (downed), out of air, drowned, the carrier dying
--             with someone on their back, a carried survivor dying, a seated
--             rover crew (a rover rolled out). Around each the wall-clock
--             frame time, 1 s before to 6 s after: `PF DEATH <cause> max
--             <ms> p99 <ms> >50ms <n>`, and `PF PASS|FAIL deaths`.
--   repair    a rover with a battery on its deck rolled out; the crew steps
--             out, holds the Repair Kit and repairs the battery (side), the
--             body (low) and the seat (high): the body's height over the
--             ground, its tilt off the local up, the hands' distance to the
--             hit, the blend in and out. Pictures in user://physfix/.
do
local PF = {}
-- (perfbench's measure() reads perf.hitches every frame, which empties it:
-- every hitch it hands out is kept here too)
PF.hbuf = {}
if perf and perf.hitches and not PF_HOOKED then
  PF_HOOKED = true
  local orig = perf.hitches
  pcall(function()
    perf.hitches = function(...)
      local h = orig(...) or {}
      for _, e in ipairs(h) do if #PF.hbuf < 64 then PF.hbuf[#PF.hbuf + 1] = e end end
      return h
    end
  end)
end
local function PFL(fmt, ...) P("PF " .. fmt, ...) end
local function crew() return findScript("crew") end
local function walker() return findScript("planet_walker") end

-- body-relative helpers
local function W_(p) local b = home(); return { x = b.x + p.x, y = b.y + p.y, z = b.z + p.z } end
local function upAt(x, y, z) local b = home(); return unit({ x = x - b.x, y = y - b.y, z = z - b.z }) end

-- a world point `h` m over the ground at body direction `dir`
local function over_ground(dir, h)
  local b = home()
  local gr = ground_r(b, dir.x, dir.y, dir.z, len(dir.x, dir.y, dir.z) > 0 and (b.radius + 300) or 0)
  if not gr then return nil end
  return { x = dir.x * (gr + h), y = dir.y * (gr + h), z = dir.z * (gr + h) }, gr
end
local function put_rel(p)
  local A = astro()
  local w = W_(p)
  A.x, A.y, A.z = w.x, w.y, w.z
  A.vx, A.vy, A.vz = 0, 0, 0
  local C = crew()
  if C and C.quietMonitors then C.quietMonitors(0.25) end
end
local function hp_of(id)
  local C = crew()
  local r = C and C.get and C.get(id or C.activeId())
  return r and r.hp or 1
end

local function shot(nm, ui)
  local done = false
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = ui ~= false }, function(bytes, why)
    if bytes then assets.writeBytes("user://physfix/" .. nm .. ".png", bytes); PFL("SHOT %s", nm)
    else PFL("SHOT %s failed: %s", nm, tostring(why)) end
    done = true
  end)
  if not ok then PFL("capture error %s", tostring(err)); return end
  wait_for(function() return done end, 6, "shot " .. nm)
end

-- the pack's load: iron to the nearest unit of `kg` (4.2 kg a unit)
local function set_pack(kg)
  local inv = findScript("inventory")
  if not inv then return 0 end
  inv.clear("astro")
  if kg > 0 then
    local cap = inv.cap and inv.cap("astro") or 90
    if cap < kg + 1 and inv.setCap then inv.setCap("astro", kg + 10) end
    inv.add("astro", "regolith", math.floor(kg / 1.8 + 0.5))
  end
  return inv.mass("astro")
end

-- ── packjump ────────────────────────────────────────────────────────────────
local K = { dv = {}, kills = {}, hurt = 0 }
local function wrap_crew()
  local C = crew()
  if C.__pf then return end
  C.__pf = true
  local orig = C.impactRule
  C.impactRule = function(dv)
    if dv > 0.5 then K.dv[#K.dv + 1] = dv end
    return orig(dv)
  end
  local okill = C.kill
  C.kill = function(id, cause, detail, opts)
    if K.block then
      K.kills[#K.kills + 1] = string.format("%s(%s)", tostring(cause), tostring(detail))
      PFL("KILL blocked: #%s %s %s", tostring(id), tostring(cause), tostring(detail))
      return false
    end
    K.kill_w = W()
    local w0 = W()
    local r = okill(id, cause, detail, opts)
    PFL("KILL #%s %s took %.1f ms", tostring(id), tostring(cause), (W() - w0) * 1000)
    return r
  end
end

-- a frame stalled on the wall clock (a stutter on a busy machine: the
-- engine then runs several catch-up ticks in the next frame)
local function stall(ms)
  local t = W() + ms / 1000
  while W() < t do end
end
local function jump_set(tag, kg, style, hitch)
  local pw = walker()
  K.dv, K.kills = {}, {}
  local hp0 = hp_of()
  local trace = {}
  local maxdv, wimp = 0, 0
  for n = 1, 2 do
    local t0 = time
    local fwd = style ~= "stand" and 1 or 0
    local spr = style == "sprint"
    local seq0 = pw.impactSeq or 0
    local up_max, vlast = 0, 0
    local stalled = 0
    while time - t0 < 2.4 do
      local t = time - t0
      pw.steer(fwd, 0, spr, t > 0.6 and t < 0.66)
      -- (hitch: stalls on the way down, the last before the touchdown)
      if hitch and t > 0.8 and not pw.grounded and vlast < -1.0 and stalled < 3 then stall(90 + 60 * stalled); stalled = stalled + 1 end
      yield()
      local A = astro()
      local u = upAt(A.x, A.y, A.z)
      local vu = (A.vx or 0) * u.x + (A.vy or 0) * u.y + (A.vz or 0) * u.z
      if #trace < 2000 then trace[#trace + 1] = string.format("%.2f:%.2f:%s", t, vu, pw.grounded and "g" or "a") end
      vlast = vu
    end
    if (pw.impactSeq or 0) ~= seq0 then wimp = math.max(wimp, pw.impactSpeed or 0) end
  end
  pw.steer(0, 0, false)
  wait(0.4)
  for _, d in ipairs(K.dv) do maxdv = math.max(maxdv, d) end
  local lost = hp0 - hp_of()
  local mass = findScript("inventory").mass("astro")
  PFL("JUMP %s%s %3d kg (pack %.1f kg, encumbrance %.2f, rig mass %.3f t) %-6s: max Δv judged %.2f m/s, walker impact %.2f, hp lost %.3f, kills %d %s",
    tag, hitch and "+hitch" or "", kg, mass, pw.encumbrance or -1, pw.bodyMass and pw.bodyMass() or -1, style, maxdv, wimp, lost, #K.kills, table.concat(K.kills, ","))
  local C = crew()
  if lost > 0 and C.patch then C.patch(C.activeId(), { hp = 1.0 }) end
  return maxdv, lost, #K.kills
end

function PF.packjump()
  wait_ready(90)
  wait(2)
  clear_weather()
  local C = crew()
  C.setSafety("death")
  wrap_crew()
  K.block = true
  local pw = walker()
  if pw.bump then pw.bump = function() end end
  local A = astro()
  local bad = 0
  -- 1. where the crew stands at the start (the base's graded apron)
  local spots = {}
  local b = home()
  spots[#spots + 1] = { tag = "spawn", p = { x = A.x - b.x, y = A.y - b.y, z = A.z - b.z } }
  -- 2. open, flat-ish ground 60-150 m out (the bare-rock spot)
  local _, rock = find_spots()
  if rock then
    local p = over_ground(scl(rock.dir, 1), 1.0)
    if p then spots[#spots + 1] = { tag = "rock", p = p } end
  end
  -- 1. a real fall still hurts: 6, 14 and 30 m drops on open ground
  local fs = spots[#spots]
  for _, h in ipairs({ 6, 14, 30 }) do
    local u = unit(fs.p)
    put_rel({ x = fs.p.x + u.x * h, y = fs.p.y + u.y * h, z = fs.p.z + u.z * h })
    K.dv, K.kills = {}, {}
    local hp0 = hp_of()
    wait(5)
    local m = 0
    for _, d in ipairs(K.dv) do m = math.max(m, d) end
    PFL("FALL %d m: max Δv %.2f, hp lost %.3f, kills %s", h, m, hp0 - hp_of(), table.concat(K.kills, ","))
    if h == 30 and (hp0 - hp_of()) <= 0 and #K.kills == 0 then bad = bad + 1; PFL("a 30 m fall did nothing") end
    C.patch(C.activeId(), { hp = 1.0 })
  end
  -- 2. jumps, 0-90 kg, standing / walking / sprinting, smooth and with stalls
  local kgs = {}
  for x in tostring(params.kgs or "0,30,60,90"):gmatch("[^,]+") do kgs[#kgs + 1] = tonumber(x) end
  if #kgs == 0 then kgs = { 0, 30, 60, 90 } end
  for si, s in ipairs(spots) do
    -- (the open ground: the ends of the range, no stalls — a run is 6 min)
    for _, kg in ipairs(si == 1 and kgs or { 0, 90 }) do
      set_pack(kg)
      wait(0.6)   -- (bodyMass reads the pack every 0.5 s)
      for _, style in ipairs({ "stand", "walk", "sprint" }) do
        for _, hitch in ipairs(si == 1 and { false, true } or { false }) do
          put_rel(s.p)
          pw.steer(0, 0, false)
          wait(0.8)
          local dv, lost, kills = jump_set(s.tag, kg, style, hitch)
          if dv > (C.params and C.params.impact_injure or 9) or lost > 0 or kills > 0 then bad = bad + 1 end
        end
      end
    end
  end
  set_pack(0)
  PFL("%s packjump: %d bad sets", bad == 0 and "PASS" or "FAIL", bad)
  PFL("DONE")
end

-- ── deaths ──────────────────────────────────────────────────────────────────
-- the wall clock of every frame from `t_before` s before to `after` s after
local function frames_around(cause, fn, after)
  local ft = {}
  local last = W()
  for _ = 1, 30 do yield(); local w = W(); ft[#ft + 1] = (w - last) * 1000; last = w end
  local pre = #ft
  if perf.hitches then perf.hitches() end
  PF.hbuf = {}
  local w0 = W()
  K.kill_w = nil
  local wt, hidden, saw_black = {}, {}, false
  local ok, err = pcall(fn)
  if not ok then PFL("DEATH %s: the trigger failed: %s", cause, tostring(err)) end
  local t0 = time
  local why = {}
  while time - t0 < (after or 6) do
    yield()
    local w = W()
    ft[#ft + 1] = (w - last) * 1000
    wt[#ft] = w
    last = w
    -- (behind the death curtain? a long frame under black is not seen)
    local Cc = crew()
    local al = Cc and Cc.curtainAlpha and Cc.curtainAlpha() or 0
    if al >= 0.98 then hidden[#ft] = true end
    -- the black itself, once, for the record
    if al >= 0.98 and not saw_black then saw_black = true; PFL("  %s: the picture is black %.2f s after the trigger", cause, w - w0) end
    -- a long frame: what the engine says it went on (its own last frame)
    if ft[#ft] > 50 and #why < 6 and perf.frames then
      local fr = perf.frames(1) or {}
      local f = fr[#fr]
      if f then
        local function top(t, kf, vf, n)
          local l = {}
          for k, v in pairs(t or {}) do
            local name, ms = kf(k, v), vf(k, v)
            if ms and ms > 3 then l[#l + 1] = { name, ms } end
          end
          table.sort(l, function(a, b) return a[2] > b[2] end)
          local o = {}
          for i = 1, math.min(n, #l) do o[#o + 1] = string.format("%s %.0f", l[i][1], l[i][2]) end
          return table.concat(o, ", ")
        end
        local id = function(k, v) return k end
        local val = function(k, v) return v end
        local sname = function(k, v) return v.name end
        local sms = function(k, v) return v.ms end
        why[#why + 1] = string.format("f%d %.0f ms: buckets [%s] parts [%s] scripts [%s] ticks %s", #ft - pre, ft[#ft],
          top(f.buckets, id, val, 5), top(f.parts, id, val, 5), top(f.scripts, sname, sms, 5), tostring(f.ticks))
      end
    end
  end
  for _, l in ipairs(why) do PFL("  LONG %s %s", cause, l) end
  -- the engine's own record of every hitch in the window: parts, the
  -- engine calls the scripts made, the files it prepared
  if perf.hitches then
    local n = 0
    perf.hitches()
    for _, h in ipairs(PF.hbuf) do
      if (h.ms or 0) > 150 and n < 5 then
        n = n + 1
        local pl = {}
        for k, v in pairs(h.parts or {}) do if v > 1 then pl[#pl + 1] = string.format("%s %.0f", k, v) end end
        local cl = {}
        table.sort(h.calls or {}, function(a, b) return (a.ms or 0) > (b.ms or 0) end)
        for i, c in ipairs(h.calls or {}) do if i <= 6 then cl[#cl + 1] = string.format("%s.%s x%d %.0f", tostring(c.script), tostring(c.call), c.n or 0, c.ms or 0) end end
        local al = {}
        for i, a in ipairs(h.assets or {}) do if i <= 4 then al[#al + 1] = string.format("%s %s %.0f", tostring(a.path), tostring(a.part), a.ms or 0) end end
        local sl = {}
        for i, sc in ipairs(h.scripts or {}) do if i <= 4 then sl[#sl + 1] = string.format("%s %.0f", tostring(sc.name), sc.ms or 0) end end
        PFL("  HITCH %s %.0f ms top %s | parts [%s] | calls [%s] | assets [%s] | scripts [%s]", cause, h.ms or 0, tostring(h.top),
          table.concat(pl, ", "), table.concat(cl, ", "), table.concat(al, ", "), table.concat(sl, ", "))
      end
    end
  end
  local post = {}
  local mx, big, vis = 0, 0, 0
  for i = pre, #ft do
    post[#post + 1] = ft[i]
    if hidden[i] then
      if ft[i] > 50 then PFL("  %s: a %.0f ms frame behind the curtain", cause, ft[i]) end
    else
      mx = math.max(mx, ft[i]); if ft[i] > 50 then big = big + 1 end
    end
    vis = vis + (hidden[i] and 0 or 1)
  end
  table.sort(post)
  local p99 = post[math.max(1, math.floor(#post * 0.99))]
  local med = post[math.max(1, math.floor(#post * 0.5))]
  local prem = 0
  for i = 1, pre - 1 do prem = math.max(prem, ft[i]) end
  local worst = {}
  for i = pre, #ft do
    if ft[i] > 34 and #worst < 10 then
      local rel = (K.kill_w and wt[i]) and string.format("@%+.2fs", wt[i] - K.kill_w) or ""
      worst[#worst + 1] = string.format("f%d%s:%.0f", i - pre, rel, ft[i])
    end
  end
  PFL("DEATH %-14s frames %d: median %.1f ms, p99 %.1f, max seen %.1f (before %.1f), >50 ms seen: %d  [%s]", cause, #post, med, p99, mx, prem, big,
    table.concat(worst, " "))
  return mx, big
end

local function status_of(id)
  local C = crew()
  local r = C.get(id)
  return (r and r.status or "?") .. (r and r.downed and " (downed)" or "")
end
-- a fresh member on foot at the spot, in control (hired when the roster runs out)
local function fresh_member(spot)
  local C = crew()
  local id = C.activeId()
  local r = id and C.get(id)
  if not (r and r.status ~= "dead") then
    wait_for(function() local i = C.activeId(); local q = i and C.get(i); return q and q.status ~= "dead" and not C.held(i) end, 20, "a member in control")
  end
  wait(1.0)
  put_rel(spot)
  wait(1.5)
  return C.activeId()
end

function PF.deaths()
  wait_ready(90)
  wait(2)
  clear_weather()
  local C = crew()
  C.setSafety("death")
  wrap_crew()
  K.block = false
  local pw = walker()
  local b = home()
  local A = astro()
  local _, rock = find_spots()
  local spot = rock and over_ground(scl(rock.dir, 1), 1.0) or { x = A.x - b.x, y = A.y - b.y, z = A.z - b.z }
  local u = unit(spot)
  local worst, bigs = 0, 0
  local function note(mx, big) worst = math.max(worst, mx); bigs = bigs + big end
  local function lift(h) return { x = spot.x + u.x * h, y = spot.y + u.y * h, z = spot.z + u.z * h } end

  -- 1. a long fall: dead (Δv well past down_over × impact_kill)
  local id = fresh_member(spot)
  note(frames_around("fall-dead", function() put_rel(lift(160)) end, 14))
  PFL("  #%s after the fall: %s; active now #%s", tostring(id), status_of(id), tostring(C.activeId()))
  -- 2. a shorter fall: downed (bleeding out), then bled out at once
  id = fresh_member(spot)
  note(frames_around("fall-downed", function() put_rel(lift(48)) end, 9))
  PFL("  #%s after the fall: %s", tostring(id), status_of(id))
  local r = C.get(id)
  if r and r.downed then
    note(frames_around("bled-out", function() C.kill(id, "impact", "bled", { bled = true }) end, 6))
    PFL("  #%s: %s", tostring(id), status_of(id))
  end
  -- 3. out of air (the walker's blackout end, as it asks)
  id = fresh_member(spot)
  note(frames_around("oxygen", function() C.blackoutEnd("suit") end, 6))
  PFL("  #%s: %s", tostring(id), status_of(id))
  -- 3b. out of air far from the base (the next member walks out of the
  -- Command Centre: the view jumps back to the base)
  do
    local u0, t1 = base_frame()
    local far = over_ground(dir_at(u0, t1, params.far_m or 1500, len(spot.x, spot.y, spot.z)), 1.0)
    if far then
      id = fresh_member(far)
      wait(6)   -- (the ground out there streamed in, the base's let go)
      note(frames_around("oxygen-far", function() C.blackoutEnd("suit") end, 8))
      PFL("  #%s: %s", tostring(id), status_of(id))
    end
  end
  -- 4. drowned
  id = fresh_member(spot)
  note(frames_around("drowned", function() C.blackoutEnd("hold") end, 6))
  PFL("  #%s: %s", tostring(id), status_of(id))
  -- 5. a carried survivor dies; then the carrier dies with one on their back
  id = fresh_member(spot)
  local a2 = astro()
  local function survivor()
    local d, x, y, z = space.dominant(a2.x, a2.y, a2.z), nil, nil, nil
    local bb = space.body(d)
    local sid = C.newClient("Probe Survivor", { client = "probe", hp = 0.2, downed = true,
      body = d, x = a2.x - bb.x + 1.0, y = a2.y - bb.y, z = a2.z - bb.z })
    return sid
  end
  local sid = survivor()
  wait(2.0)
  local okc, whyc = C.carry(sid)
  PFL("  carry #%s: %s %s", tostring(sid), tostring(okc), tostring(whyc))
  wait(1.0)
  note(frames_around("carried-dies", function() C.kill(sid, "air", "probe") end, 4))
  PFL("  survivor #%s: %s", tostring(sid), status_of(sid))
  sid = survivor()
  wait(2.0)
  okc, whyc = C.carry(sid)
  PFL("  carry #%s: %s %s", tostring(sid), tostring(okc), tostring(whyc))
  wait(1.0)
  note(frames_around("carrier-dies", function() C.kill(id, "crushed") end, 7))
  PFL("  carrier #%s: %s; survivor #%s: %s; carrying %s", tostring(id), status_of(id), tostring(sid), status_of(sid), tostring(C.carrying()))
  PFL("%s deaths: worst frame %.1f ms, %d frames over 50 ms", (worst < 120 and bigs <= 3) and "PASS" or "FAIL", worst, bigs)
  PFL("DONE")
end

-- ── repair ──────────────────────────────────────────────────────────────────
local HPI = math.pi / 2
local RROVER = {
  rec(1, "roverBody", 0, 0.62, 0),
  rec(2, "wheelM", 0.66, 0.42, 0.7, { yaw = -HPI, parent = 1, att = "surface", sym = 1, mir = "z" }),
  rec(3, "wheelM", 0.66, 0.42, -0.7, { yaw = HPI, parent = 1, att = "surface", sym = 1, mir = "z" }),
  rec(4, "wheelM", -0.66, 0.42, 0.7, { yaw = -HPI, parent = 1, att = "surface", sym = 2, mir = "z" }),
  rec(5, "wheelM", -0.66, 0.42, -0.7, { yaw = HPI, parent = 1, att = "surface", sym = 2, mir = "z" }),
  rec(6, "seat", -0.4, 0.62 + 0.15 + 0.65, 0, { parent = 1, att = "top" }),
  rec(7, "packB", 0.45, 0.62 + 0.15 + 0.175, 0, { parent = 1, att = "surface" }),
}

local function part_node(vc, uid)
  local function walk(n)
    for _, ch in ipairs(n:children() or {}) do
      if vc.uidOfNode(ch) == uid then return ch end
      local r = walk(ch)
      if r then return r end
    end
  end
  return walk(vc.node)
end

-- the held body: its height over the ground below it, its tilt off the up,
-- the hands to the hit (item_hand's probes), measured each frame
local function measure_hold(tag, secs)
  local ih = findScript("item_hand")
  local A = astro()
  local s = { n = 0, gap_max = -1e9, gap_min = 1e9, tilt = 0, hand = 0, hand_n = 0, jump = 0 }
  local t0 = time
  local lastp
  while time - t0 < secs do
    yield()
    local u = upAt(A.x, A.y, A.z)
    local h = raycast(A.x, A.y, A.z, -u.x, -u.y, -u.z, 6.0, { ignore = A })
    if h and h.distance then
      local gap = h.distance - (PF.base and (PF.base + 0.95) or 0.95)
      s.gap_max, s.gap_min = math.max(s.gap_max, gap), math.min(s.gap_min, gap)
    end
    local wu = A.worldUp and A:worldUp()
    if wu then
      local c = clamp(wu.x * u.x + wu.y * u.y + wu.z * u.z, -1, 1)
      s.tilt = math.max(s.tilt, math.deg(math.acos(c)))
    end
    if ih.handToHit then s.hand = math.max(s.hand, ih.handToHit); s.hand_n = s.hand_n + 1 end
    s.n = s.n + 1
  end
  PFL("HOLD %s: feet over the ground (vs standing) %.2f..%.2f m, tilt max %.1f°, right hand to hit max %.2f m (%d frames), standoff %s",
    tag, s.gap_min, s.gap_max, s.tilt, s.hand, s.hand_n, tostring(PF.standoff))
  return s
end

function PF.repair()
  wait_ready(90)
  wait(2)
  clear_weather()
  local C = crew()
  C.setSafety("invincible")
  local vc = launch_via_builder(RROVER, "runway", 7)
  if not vc then PFL("FAIL repair: no rover"); return end
  PFL("rover up: releaseClamps %s, crew %s", type(vc.releaseClamps), type(crew()))
  local okc, ec = pcall(vc.releaseClamps)
  if not okc then PFL("releaseClamps: %s", tostring(ec)) end
  wait(4)
  C = crew()   -- (the scene was loaded again: a fresh handle)
  PFL("crew handle: activeId %s eva %s", type(C and C.activeId), type(C and C.eva))
  local id = C.activeId()
  local okE, whyE = C.eva(id)
  PFL("eva: %s %s", tostring(okE), tostring(whyE))
  wait(3)
  local inv = findScript("inventory")
  inv.addItem("astro", "repairkit", 6)
  local ih = findScript("item_hand")
  local okH, whyH = ih.hold("repairkit")
  PFL("hold kit: %s %s", tostring(okH), tostring(whyH))
  wait(0.5)
  local pc = findScript("planet_camera")
  -- (third person, close: the body and the part in one picture)
  pc.firstPerson = false
  if pc.params then pc.params.distance = 3.0 end
  local bad = 0
  local info = assembly.info(vc.node)
  local list = {}
  for _, p in ipairs(info.parts or {}) do list[#list + 1] = p end
  PFL("rover parts: %d", #list)
  -- (the PHYSICS frame: the rays below meet the colliders where the tick has
  -- them; the hit is handed to the menu's path in the drawn pose)
  local function frame_of(uid) return vc.partFrameNow and vc.partFrameNow(uid) end
  -- the targets: the battery from its side, the body low at the front, the seat high
  local targets = {
    { uid = 7, tag = "battery_side", side = "z", h = 0.0 },
    { uid = 1, tag = "body_front", side = "x", h = 0.0 },
    { uid = 6, tag = "seat_high", side = "z", h = 0.5 },
    { uid = 7, tag = "battery_top", side = "up", h = 0.0 },
  }
  for i, tg in ipairs(targets) do
    vc.wearPart(tg.uid, 0.4)
    wait(0.3)
    local F = frame_of(tg.uid)
    if not F then PFL("no frame for %d", tg.uid) break end
    -- the hit: on the part's flank toward +side, and the crew 1.6 m out that way
    local ax = tg.side == "x" and { x = F.rx, y = F.ry, z = F.rz } or (tg.side == "z" and { x = F.zx, y = F.zy, z = F.zz } or nil)
    local U = upAt(F.ox, F.oy, F.oz)
    local hx, hy, hz, nx, ny, nz
    local A = astro()
    local out
    if ax then
      out = unit(sub(ax, scl(U, dot(ax, U))))
      local o = { x = F.ox + out.x * 2.5 + U.x * tg.h, y = F.oy + out.y * 2.5 + U.y * tg.h, z = F.oz + out.z * 2.5 + U.z * tg.h }
      local h = raycast(o.x, o.y, o.z, -out.x, -out.y, -out.z, 3.0, { ignore = A })
      if h then hx, hy, hz, nx, ny, nz = h.x, h.y, h.z, h.nx, h.ny, h.nz end
    else
      out = unit(sub({ x = F.zx, y = F.zy, z = F.zz }, scl(U, dot({ x = F.zx, y = F.zy, z = F.zz }, U))))
      local o = { x = F.ox + U.x * 1.5, y = F.oy + U.y * 1.5, z = F.oz + U.z * 1.5 }
      local h = raycast(o.x, o.y, o.z, -U.x, -U.y, -U.z, 3.0, { ignore = A })
      if h then hx, hy, hz, nx, ny, nz = h.x, h.y, h.z, h.nx, h.ny, h.nz end
    end
    if not hx then PFL("%s: no hit", tg.tag); bad = bad + 1
    else
      -- (both points kept in the part's frame at once: a world point is
      -- metres off a few frames later on the moving planet)
      local hl1, hl2, hl3 = vc.partLocalNow(tg.uid, hx, hy, hz)
      local sl1, sl2, sl3 = vc.partLocalNow(tg.uid, F.ox + out.x * 1.8, F.oy + out.y * 1.8, F.oz + out.z * 1.8)
      -- stand the crew 1.8 m out on the ground (drawn pose, this frame)
      local b = home()
      local s1, s2, s3 = vc.partPointNow(tg.uid, sl1, sl2, sl3, true)
      local sp = { x = s1 - b.x, y = s2 - b.y, z = s3 - b.z }
      local g = over_ground(unit(sp), 1.0)
      if g then put_rel(g) end
      wait(1.2)
      pc.face(-out.x, -out.y, -out.z, -0.15)
      -- the hit as the menu's pick would hand it: the drawn pose, this frame
      local dx, dy, dz = vc.partPointNow(tg.uid, hl1, hl2, hl3, true)
      local t = { kind = "part", vessel = vc, uid = tg.uid, wx = dx, wy = dy, wz = dz, node = part_node(vc, tg.uid), rec = vc.partRec and vc.partRec(tg.uid) }
      PF.base = nil
      local sb = measure_hold(tg.tag .. "_standing", 0.3)
      PF.base = sb.gap_min
      do
        local A2 = astro()
        local tk = ih.repairTask(t)
        local px, py, pz = vc.physPosOf(A2)
        local hp1, hp2, hp3 = vc.partPointNow(tg.uid, hl1, hl2, hl3)
        PFL("%s: crew to the hit drawn %.2f m, physics %.2f m; the task's hit off the true one by %s m",
          tg.tag, len(A2.x - dx, A2.y - dy, A2.z - dz), len(px - hp1, py - hp2, pz - hp3),
          tk and string.format("%.2f", len(tk.lx - hl1, tk.ly - hl2, tk.lz - hl3)) or "(no task)")
      end
      -- (started as rolesprobe and evaprobe do: crew_task's own task from a
      -- hit in this tick's physics frame, then crew.setTask; the menu's
      -- drawn-pose pick has no stand-in that is the same frame here)
      local okR, whyR
      do
        local ct0 = findScript("crew_task")
        local hp1, hp2, hp3 = vc.partPointNow(tg.uid, hl1, hl2, hl3)
        local tk, why0 = ct0.repairTask(vc, tg.uid, hp1, hp2, hp3, nx, ny, nz, { id = id })
        if tk then
          tk.frame, tk.label = "part", tg.tag
          okR, whyR = C.setTask(id, tk)
        else
          okR, whyR = false, why0
        end
      end
      local ct = findScript("crew_task")
      local ls = ct and ct.lastStance
      if ls then PFL("%s: stance d %.2f footing %.2f (hit %.2f over the soles), turned %.0f°, shoulder to hit %.2f m, in reach %s", tg.tag, ls.d, ls.g, ls.hh, ls.turn or 0, ls.shoulder or -1, tostring(ls.reach)) end
      PFL("%s: start %s %s (hit %.2f m over the part's origin)", tg.tag, tostring(okR), tostring(whyR), dot(sub({ x = hx, y = hy, z = hz }, { x = F.ox, y = F.oy, z = F.oz }), U))
      if okR then
        local s0 = measure_hold(tg.tag .. "_in", 0.6)
        local s = measure_hold(tg.tag, 1.6)
        -- a side view and a three-quarter view
        local side = unit(cross(U, out))
        -- the free camera, placed off the crew in the planet's frame (the
        -- crew holds still on the planet, which only translates)
        local function view(dir, dist, up_m, nm)
          local A3 = astro()
          local b3 = home()
          local rel = { x = A3.x - b3.x, y = A3.y - b3.y, z = A3.z - b3.z }
          local u3 = unit(rel)
          local cp = { x = rel.x + dir.x * dist + u3.x * up_m, y = rel.y + dir.y * dist + u3.y * up_m, z = rel.z + dir.z * dist + u3.z * up_m }
          local look = sub(rel, cp)
          local fl = sub(look, scl(u3, dot(look, u3)))
          pc.setFreecam(true)
          local fc = pc.freecamState()
          if fc then
            fc.body = b3.name
            fc.rel = vec3(cp.x, cp.y, cp.z)
            fc.ref = vec3(fl.x, fl.y, fl.z):normalized()
            fc.pitch = math.atan2(dot(look, u3), len(fl.x, fl.y, fl.z))
            fc.speed = 0
          end
          wait(0.25)
          shot(nm)
        end
        view(side, 3.0, 0.3, string.format("%d_%s_side", i, tg.tag))
        view(unit({ x = out.x + side.x, y = out.y + side.y, z = out.z + side.z }), 3.2, 0.8, string.format("%d_%s_34", i, tg.tag))
        pc.setFreecam(false)
        if s.gap_max > 0.25 or s.gap_min < -0.25 then bad = bad + 1; PFL("%s: the feet are off the ground", tg.tag) end
        if s.tilt > 12 then bad = bad + 1; PFL("%s: the body tilts %.0f°", tg.tag, s.tilt) end
        if s.hand > 0.3 then bad = bad + 1; PFL("%s: the hand misses the hit by %.2f m", tg.tag, s.hand) end
        C.cancelTask(id)
        measure_hold(tg.tag .. "_out", 0.8)
        wait(1.0)
      else
        bad = bad + 1
      end
    end
  end
  PFL("%s repair: %d bad", bad == 0 and "PASS" or "FAIL", bad)
  PFL("DONE")
end

function PF.deathseat()
  wait_ready(90)
  wait(2)
  clear_weather()
  local C = crew()
  C.setSafety("death")
  local worst, bigs = 0, 0
  local function note(mx, big) worst = math.max(worst, mx); bigs = bigs + big end
  -- 6. seated: a rover rolled out, the member in its seat
  local vc = launch_via_builder(ROVER, "runway", 6)
  if vc then
    PFL("rover up: releaseClamps %s, crew %s", type(vc.releaseClamps), type(crew()))
    local okc, ec = pcall(vc.releaseClamps)
    if not okc then PFL("releaseClamps: %s", tostring(ec)) end
    wait(3)
    C = crew()   -- (the scene was loaded again: a fresh handle)
    PFL("crew handle: activeId %s setSafety %s", type(C and C.activeId), type(C and C.setSafety))
    C.setSafety("death")
    local sid2 = C.activeId()
    local inseat = C.craftOf and C.craftOf(sid2)
    PFL("  seated #%s aboard %s", tostring(sid2), tostring(inseat ~= nil))
    note(frames_around("seated-heat", function() C.kill(sid2, "heat") end, 7))
    PFL("  #%s: %s; active #%s", tostring(sid2), status_of(sid2), tostring(C.activeId()))
  else
    PFL("  no rover: seated death skipped")
  end
  PFL("%s deathseat: worst frame %.1f ms, %d frames over 50 ms", (worst < 120 and bigs <= 3) and "PASS" or "FAIL", worst, bigs)
  PFL("DONE")
end

PF_RUN = { packjump = PF.packjump, deaths = PF.deaths, deathseat = PF.deathseat, repair = PF.repair }
end
