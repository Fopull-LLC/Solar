-- ── STRIP probe (tools/perf/stripprobe.sh): the crew strip as a scroll view ──
-- Spliced into a copy of perfbench.lua after ivaprobe_modes.lua (it uses IV,
-- iv_launch and stack). Modes strip1, strip4, strip8: that many crew aboard
-- (a Pod Mk2 over one or two Crew Cabins), then at interface sizes 70 %,
-- Auto, 85 % (Auto at 1080p), 80 % (Auto at 1440p) and 100 %, small and
-- large: a picture at the start and, when the crew overflow it, one scrolled
-- to the end. Every pose checks, in screen pixels, that the strip ends before
-- the console with a gap, that the Flight Ops card, the CONTROLS card and the
-- strip overlap nowhere, and that only the portraits in view film.
-- `SP CHECK`, `SP GEOM` lines; pictures in $WORK/proj/save/user/ivashots/strip<n>_*.png.

local function sp_rect(name)
  local n = find(name)
  local e = n and n:getcomponent("UiElement")
  if not (n and e and e.visible ~= false and n.uiRect) then return nil end
  local x, y, w, h = n:uiRect()
  if not (x and w and w > 0) then return nil end
  return { x = x, y = y, w = w, h = h }
end

local function sp_overlap(a, b)
  if not (a and b) then return false end
  return a.x < b.x + b.w - 0.5 and b.x < a.x + a.w - 0.5 and a.y < b.y + b.h - 0.5 and b.y < a.y + a.h - 0.5
end

-- A picture at the screen's own size (IV.shot takes 1280×720 whatever the screen).
local function sp_shot(nm)
  local w, h = camera.screenSize()
  local done = false
  local ok = pcall(camera.capture, { w = w, h = h, ui = true }, function(bytes)
    if bytes then assets.writeBytes("user://ivashots/" .. IV.tag .. "_" .. nm .. ".png", bytes); P("IV SHOT %s_%s", IV.tag, nm) end
    done = true
  end)
  if ok then wait_for(function() return done end, 6, "shot " .. nm) end
end

local function sp_crew(n)
  local C = findScript("crew")
  local co = findScript("company")
  if co and co.earn then co.earn(200000, "probe") end
  local tries = 0
  while #(C.roster() or {}) < n and tries < 20 do
    tries = tries + 1
    local id, why = C.hire(1)
    P("SP hired %s (%s)", tostring(id), tostring(why))
    if not id then break end
  end
  local ids = {}
  for _, r in ipairs(C.roster()) do if r.status ~= "dead" then ids[#ids + 1] = r.id end end
  return ids
end

local function sp_pose(N, tag, S)
  local st = findScript("settings")
  local fh, sh = findScript("flight_hud"), findScript("status_hud")
  local sw, shh = camera.screenSize()
  local dh = st.designHeight()
  local k = shh / dh                                       -- design → pixels
  local strip = sp_rect("Crew Strip")
  local fo = sp_rect("Flight Ops")
  local ctl = sp_rect("Controls Card")
  local cl = fh.layout and fh.layout.consoleLeft
  local cpx = cl and cl * k
  local gap = strip and cpx and (cpx - (strip.x + strip.w)) / k or -1
  P("SP GEOM %s: screen %dx%d ui %.2f dw %.0f | strip x %.0f w %.0f (cap %.0f, view %.0f, n %d, in view %d, live %d, scroll %.0f/%.0f) console-left %.0f gap %.1f du | fo %s ctl %s ctlY %.0f",
    tag, sw, shh, st.uiScale or -1, sh.designWidth(), strip and strip.x or -1, strip and strip.w / k or -1, S.strip.cap or -1,
    S.strip.viewW or -1, S.strip.n, S.strip.shown, S.strip.live, S.strip.scroll or 0, S.strip.maxScroll or 0, cl or -1, gap,
    fo and string.format("%.0f,%.0f %.0fx%.0f", fo.x, fo.y, fo.w, fo.h) or "-",
    ctl and string.format("%.0f,%.0f %.0fx%.0f", ctl.x, ctl.y, ctl.w, ctl.h) or "-", sh.controlsY or 0)
  IV.check(tag .. "_ends_before_console", strip ~= nil and gap >= 8, "gap %.1f design units", gap)
  IV.check(tag .. "_fo_vs_controls", not sp_overlap(fo, ctl), "Flight Ops vs CONTROLS")
  IV.check(tag .. "_fo_vs_strip", not sp_overlap(fo, strip), "Flight Ops vs strip")
  IV.check(tag .. "_strip_vs_controls", not sp_overlap(strip, ctl), "strip vs CONTROLS")
  IV.check(tag .. "_fo_vs_console", not (fo and cpx and fo.x + fo.w > cpx and fo.y + fo.h > shh - (fh.layout.consoleRise or 0) * k),
    "Flight Ops vs console")
  IV.check(tag .. "_live_bounded", S.strip.live <= S.strip.shown and S.strip.shown <= N, "live %d, in view %d, aboard %d",
    S.strip.live, S.strip.shown, N)
  -- every portrait camera out of view is off (a disabled camera is not drawn)
  local inview, filming_out = {}, {}
  for _, i in ipairs(S.strip.visible or {}) do inview[i] = true end
  for i = 1, N do
    local c = find("Crew Cam " .. i)
    if c and c.enabled and not inview[i] then filming_out[#filming_out + 1] = i end
  end
  IV.check(tag .. "_offscreen_off", #filming_out == 0, "%d of %d in view (%s); out of view but filming: %s",
    S.strip.shown, N, table.concat(S.strip.visible or {}, ","), #filming_out > 0 and table.concat(filming_out, ",") or "none")
end

local function run_strip(N)
  IV.tag = "strip" .. N
  local ids = sp_crew(N)
  if #ids < N then IV.check("crew", false, "only %d crew", #ids); IV.result(); return end
  -- a Pod Mk2 (3) over Crew Cabins (4 each); stack uids: 1 engine, 2 tank, 3.. cabins, then the pod
  local parts = { { "engineS", 1.3 }, { "tankS", 1.0 } }
  local cabins = N > 3 and math.ceil((N - 3) / 4) or 0
  for _ = 1, cabins do parts[#parts + 1] = { "cabin", 1.3 } end
  parts[#parts + 1] = { "podMk2", 1.15 }
  parts[#parts + 1] = { "chute", 0.34, 1 }
  local pod = 3 + cabins
  local plan = {}
  for i = 1, N do
    if i <= 3 then plan[i] = { uid = pod, slot = i, id = ids[i] }
    else
      local j = i - 4
      plan[i] = { uid = 3 + math.floor(j / 4), slot = j % 4 + 1, id = ids[i] }
    end
  end
  local vc = iv_launch(stack(parts), { name = "Omnibus" }, "pad", plan)
  if not vc then IV.check("rollout", false, "no craft"); IV.result(); return end
  local S, st = findScript("crew_strip"), findScript("settings")
  wait(3)
  IV.check("aboard", S.strip.n == N, "%d aboard (want %d)", S.strip.n, N)
  -- the screen is the run's (stripprobe.sh: `floptle shot --size WxH`);
  -- Auto at 1440p is 80 %
  local sw, shh = camera.screenSize()
  P("SP RES %dx%d", sw, shh)
  for _, sz in ipairs({ { "70", 0.7 }, { "auto", nil }, { "80", 0.8 }, { "100", 1.0 } }) do
    st.set("ui_scale", sz[2])
    for _, m in ipairs({ "small", "large" }) do
      S.setMode(m)
      S.scrollTo(0)
      wait(1.2)
      local tag = shh .. "_" .. sz[1] .. "_" .. m
      sp_pose(N, tag, S)
      sp_shot(tag)
      if S.strip.overflow then
        S.scrollTo(1e6)
        wait(0.8)
        IV.check(tag .. "_end", S.strip.visible[#S.strip.visible] == N, "scrolled to the end: last in view #%s",
          tostring(S.strip.visible[#S.strip.visible]))
        sp_pose(N, tag .. "_end", S)
        sp_shot(tag .. "_end")
      end
    end
  end
  -- a contract on the books: the objectives card takes the top-left corner
  -- in flight, and the left column is at its most crowded
  local MS = findScript("missions")
  local of = MS and MS.offers and MS.offers() or {}
  if of[1] and MS.accept(of[1].id) then
    P("SP contract %s", tostring(of[1].id))
    for _, sz in ipairs({ { "auto", nil }, { "100", 1.0 } }) do
      st.set("ui_scale", sz[2])
      for _, m in ipairs({ "small", "large" }) do
        S.setMode(m)
        S.scrollTo(0)
        wait(1.5)
        local tag = shh .. "_contract_" .. sz[1] .. "_" .. m
        local ob = sp_rect("Objectives")
        P("SP OBJ %s %s", tag, ob and string.format("%.0f,%.0f %.0fx%.0f", ob.x, ob.y, ob.w, ob.h) or "-")
        sp_pose(N, tag, S)
        IV.check(tag .. "_obj_vs_controls", not sp_overlap(ob, sp_rect("Controls Card")), "objectives vs CONTROLS")
        IV.check(tag .. "_obj_vs_fo", not sp_overlap(ob, sp_rect("Flight Ops")), "objectives vs Flight Ops")
        sp_shot(tag)
      end
    end
  end
  -- focusing a member (as switching to them does) scrolls them into view
  if N > 3 then
    st.set("ui_scale", 1.0)
    S.setMode("small")
    S.scrollTo(0)
    wait(0.8)
    local C = findScript("crew")
    local list = C.aboard(vc)
    local idx = #list
    S.focusMember(list[idx].id)
    wait(0.8)
    local seen = false
    for _, i in ipairs(S.strip.visible) do if i == idx then seen = true end end
    IV.check("focus", seen, "focusMember(#%d, portrait %d): in view %s", list[idx].id, idx, table.concat(S.strip.visible, ","))
    sp_shot(shh .. "_focus")
  end
  st.set("ui_scale", nil)
  S.setMode("small")
  IV.result()
end
local function run_strip1() run_strip(1) end
local function run_strip4() run_strip(4) end
local function run_strip8() run_strip(8) end
