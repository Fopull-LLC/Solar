-- SMOKE HARNESS: the crew strip (scripts/crew_strip.lua), the crew alerts
-- (scripts/crew_alerts_hud.lua) and the interiors' seat geometry
-- (scripts/iva.lua against prefabs/Iva*.prefab.ron), docs/crew-and-items.md
-- §4.4, §2.3, §3.4.
--
--   luajit solar/tests/smoke_crew_strip.lua

local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end
local function near(a, b, e) return math.abs((a or 0) - (b or 0)) <= (e or 1e-3) end

local ROOT = "solar/"
local function exists(p) local f = io.open(p) if f then f:close() return true end return false end
if not exists(ROOT .. "scripts/crew_strip.lua") then ROOT = "" end

local SAVE = {}
local function load(path)
  local env = setmetatable({ save = { get = function(k) return SAVE[k] end, set = function(k, v) SAVE[k] = v end },
                             time = 0 }, { __index = _G })
  local chunk = assert(loadfile(ROOT .. path))
  setfenv(chunk, env)
  chunk()
  return env
end

-- ── the strip's layout: a horizontal scroll view, capped ──────────────────
local S = load("scripts/crew_strip.lua")
local FW = 112 + 2 * S.FRAME_PAD
local L1 = S.layout(1, "small", 600, 0)
ok(L1.n == 1 and #L1.visible == 1 and not L1.overflow and L1.w == 112 and L1.h == 112, "one aboard: one portrait, 112×112, no scrolling")
ok(L1.w == L1.h and L1.tw == L1.th, "a portrait and its target are square (nothing stretched or cropped)")
local L3 = S.layout(3, "small", 1000, 0)
ok(#L3.visible == 3 and not L3.overflow and L3.view_w == 3 * FW + 2 * S.GAP,
  "three aboard fit: laid side by side in their frames with the 6-unit gap [" .. L3.view_w .. "]")
ok(S.layout(0, "small", 600, 0).n == 0 and #S.layout(0, "small", 600, 0).visible == 0, "nobody aboard: no portraits")
-- the width cap: never wider than it may be, at every cap and both sizes
local capped = true
for _, size in ipairs({ "small", "large" }) do
  for n = 1, 12 do
    for cap = 260, 1400, 37 do
      local L = S.layout(n, size, cap, 0)
      local one = (size == "large" and 208 or 112) + 2 * S.FRAME_PAD + 2 * S.CARD_PAD + 2 * (S.ARROW_W + S.ARROW_GAP)
      if L.strip_w > cap + 1e-6 and cap >= one then capped = false; print("over", size, n, cap, L.strip_w) end
    end
  end
end
ok(capped, "the strip is never wider than its cap (1–12 crew, small and large, caps 260–1400)")
-- 8 aboard in a 1280-wide 100% screen: the console's left edge at 334
local SH = load("scripts/status_hud.lua")
local cap100 = SH.stripCapOf(1280, 1280 / 2 - 306, false)
ok(near(cap100, 334 - SH.STRIP_GAP - SH.STRIP_X), "the cap ends the strip a gap before the console [" .. cap100 .. "]")
ok(SH.STRIP_X + S.layout(8, "small", cap100, 0).strip_w <= 334 - SH.STRIP_GAP + 1e-6
   and SH.STRIP_X + S.layout(8, "large", cap100, 0).strip_w <= 334 - SH.STRIP_GAP + 1e-6,
   "…eight aboard, small and large, end before the console")
local cap_auto = SH.stripCapOf(1280 / 0.85, 1280 / 0.85 / 2 - 306, false)
ok(cap_auto > cap100, "a smaller interface (Auto at 1080p) leaves the strip more room [" .. cap_auto .. "]")
ok(near(SH.stripCapOf(1280, nil, true), 1280 / 2 - 230 - SH.STRIP_GAP - SH.STRIP_X), "on foot the cap is the hotbar's left edge")
local L8 = S.layout(8, "small", cap100, 0)
ok(L8.overflow and #L8.visible >= 1 and #L8.visible < 8 and near(L8.strip_w, cap100, 1),
  "eight in 100%: the view overflows and fills the room it has (" .. #L8.visible .. " in view)")
ok(not L8.more_l and L8.more_r, "…at the start only ▸ shows")
-- the scroll clamp
local Lmax = S.layout(8, "small", cap100, 1e6)
ok(near(Lmax.scroll, Lmax.max_scroll) and near(Lmax.max_scroll, L8.content_w - L8.view_w), "scrolling past the end clamps to the end")
ok(Lmax.more_l and not Lmax.more_r and Lmax.visible[#Lmax.visible] == 8, "…where ◂ shows, ▸ doesn't, and the last member is in view")
ok(S.layout(8, "small", cap100, -50).scroll == 0, "…and before the start to 0")
-- scroll into view
local s7 = S.scrollToShow(L8, 7, 0)
local L7 = S.layout(8, "small", cap100, s7)
ok(L7.vis[7] and (6 * L7.pitch) >= s7 and (6 * L7.pitch + L7.fw) <= s7 + L7.view_w + 1e-6, "scrollToShow(7) brings #7 fully into view")
ok(S.scrollToShow(L7, 7, s7) == s7, "…and leaves an in-view member where it is")
ok(S.scrollToShow(L7, 1, s7) == 0, "…and #1 scrolls back to the start")
local Lg = S.layout(3, "large", 2000, 0)
ok(Lg.w == 208 and Lg.h == 208 and Lg.tw == 312 and Lg.th == 312, "large mode: bigger square portraits and targets")
-- the left column in flight (status_hud.leftColumnOf, 720 tall at 100%)
local y, beside = SH.leftColumnOf(720, 16, 100, 60, 108, 160)
ok(y == 0 and not beside, "room enough: CONTROLS stays centred")
y, beside = SH.leftColumnOf(720, 16, 290, 70, 298, 160)
local bottom = 720 / 2 + y + 160 / 2
ok(not beside and bottom <= 720 - (298 + 70) - 8 + 1e-6 and 720 / 2 + y - 80 >= 16, "large strip: CONTROLS slides up over the card [bottom " .. bottom .. "]")
y, beside = SH.leftColumnOf(720, 240, 290, 70, 298, 160)
bottom = 720 / 2 + y + 160 / 2
ok(beside and bottom <= 720 - 290 - 8 + 1e-6 and 720 / 2 + y - 80 >= 240, "no room for both: the card stands beside CONTROLS, above the strip")

-- the portrait cameras' redraw budget (H1 fallback)
local tot = 0
for k = 1, 4 do tot = tot + S.rateFor(k, 4, false) end
ok(tot <= S.RT_BUDGET * 1.1, string.format("four portraits share the redraw budget (%.2f/s)", tot))
ok(S.rateFor(1, 1, true) == S.HOVER_HZ, "the hovered portrait gets the hover rate")
ok(S.rateFor(1, 3, false) ~= S.rateFor(2, 3, false), "portrait rates are staggered")
-- names and chips
ok(S.shortName("Dana Okafor") == "D.OKAFOR" and S.shortName("Cher") == "CHER", "short names: D.OKAFOR")
local ch = S.chipsFor({ o2 = 0.08, hp = 0.3, heat = 0.7 }, nil)
ok(#ch == 3 and ch[1][2] == "danger" and ch[2][2] == "danger" and ch[3][2] == "danger", "portrait chips: O2, HP, HEAT in red")
ok(#S.chipsFor({ o2 = 0.9, hp = 1, heat = 0 }) == 0, "…and none when all is well")
-- the strip size key cycles and is saved
S.setMode("small")
ok(S.cycleMode() == "large" and S.cycleMode() == "hidden" and S.cycleMode() == "small", "\\ cycles small → large → hidden")
ok(SAVE.opt_crewStrip == "small", "…and the choice is saved (opt_crewStrip)")

-- ── the cameras: only the portraits in view film ───────────────────────────
do
  local V = {}
  V.__index = V
  local function vec(x, y, z) return setmetatable({ x = x, y = y, z = z }, V) end
  V.__add = function(a, b) return vec(a.x + b.x, a.y + b.y, a.z + b.z) end
  V.__sub = function(a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end
  V.__mul = function(a, k) return vec(a.x * k, a.y * k, a.z * k) end
  local T = load("scripts/crew_strip.lua")
  local members = {}
  for i = 1, 8 do members[i] = { id = i, name = "Crew Member" .. i, uid = 3, slot = i } end
  local cams = {}
  local view = { scrollX = 0, visible = true }
  local view_node = { valid = true, getcomponent = function() return view end }
  local made
  local active = 1
  T.findScript = function(k)
    if k == "crew" then
      return { aboard = function() return members end, activeId = function() return active end,
               alerts = function() return {} end, switchList = function() return {} end, seatMap = function() return members end }
    elseif k == "iva" then
      return { need = function() end, eyeOf = function() return vec(0, 0, 0), vec(1, 0, 0), vec(0, 1, 0), vec(0, 0, 1) end }
    elseif k == "status_hud" then
      return { stripMaxW = function() return cap100 end }
    end
  end
  T.findScripts = function(k)
    if k == "vessel_controller" then return { { piloting = true, node = { valid = true, id = 77 }, craftName = "Omnibus" } } end
    return {}
  end
  T.find = function(nm) if nm == T.VIEW_NAME then return view_node end end
  T.createNode = function(name, _, cb)
    local n = { valid = true, enabled = true, name = name, setCamera = function() end, lookAt = function() end }
    cams[tonumber(name:match("(%d+)$"))] = n
    cb(n)
  end
  T.ui = { make = function(_, tree) made = tree end, hovered = function() return nil end }
  T.input = { pressed = function() return false end, key = function() return false end }
  local el = { visible = false }
  local host = { getcomponent = function() return el end }
  T.start(host)
  local function frame() T.lateUpdate(host, 1 / 60) end
  frame(); frame(); frame()
  local L = T.layout(8, "small", cap100, 0)
  local on, off_ok = 0, true
  for i = 1, 8 do
    local c = cams[i]
    if c and c.enabled then on = on + 1 end
    if not L.vis[i] and c and c.enabled then off_ok = false end
  end
  ok(T.strip.n == 8 and T.strip.overflow and T.strip.shown == #L.visible, "eight aboard: the strip overflows and shows " .. #L.visible)
  ok(off_ok and on == #L.visible and T.strip.live == #L.visible,
    string.format("only the portraits in view film (%d cameras on, %d in view)", on, #L.visible))
  ok(T.strip.width <= cap100 + 1e-6, "the strip stays inside its cap [" .. T.strip.width .. " ≤ " .. cap100 .. "]")
  -- switching to #8 scrolls it into view; its camera comes on, #1's goes off
  active = 8
  frame(); frame(); frame()
  ok(view.scrollX == L.max_scroll and T.strip.visible[#T.strip.visible] == 8, "switching to #8 scrolls it into view [" .. view.scrollX .. "]")
  ok(cams[8] and cams[8].enabled and cams[1] and not cams[1].enabled, "…its camera films and #1's, scrolled out, is off")
  -- the wheel (the engine moves scrollX): the strip follows it
  view.scrollX = 0
  frame(); frame()
  ok(cams[1].enabled and not cams[8].enabled and T.strip.scroll == 0, "the wheel back to the start: #1 films, #8 is off")
  -- the arrows
  T.scrollBy(1)
  frame(); frame()
  ok(near(view.scrollX, L.pitch), "▸ steps one portrait [" .. view.scrollX .. "]")
  -- the description: a scroll view, as wide as the layout says, its wheel a portrait a notch
  local function findk(t, k) if type(t) ~= "table" then return nil end if t.key == k then return t end
    for _, c in ipairs(t) do local r = findk(c, k) if r then return r end end end
  local vw = findk(made, "view")
  ok(vw and vw[1] == "scroll" and vw.name == T.VIEW_NAME and near(vw.w, L.view_w) and vw.scrollSpeed == L.pitch,
    "the portraits sit in a clipped scroll view, a portrait a wheel notch")
  ok(findk(made, "arL") ~= nil and findk(made, "arR") ~= nil, "both arrows show in the middle of the crew")
  ok(findk(made, "fl1") ~= nil and findk(made, "fr1") ~= nil, "…and both edges fade")
  -- hidden: every camera off
  T.setMode("hidden")
  frame()
  local any = false
  for _, c in pairs(cams) do if c.enabled then any = true end end
  ok(not any and T.strip.live == 0, "hidden strip: every camera off")
  T.setMode("small")
end

-- ── EVA from a portrait, and the no-pack confirm (Cancel by default) ───────
local evas = {}
local crew = { eva = function(id, o)
  evas[#evas + 1] = { id = id, o = o }
  if not o.confirmed then return false, "confirm", "Dana has no RCS Pack." end
  return true
end }
S.findScript = function(k) if k == "crew" then return crew end end
local okv, why = S.evaMember(2, false, false)
ok(not okv and why == "confirm" and S.confirmOpen() and S.confirmOpen().id == 2, "no pack in space: the confirm opens, nobody leaves")
S.confirmEva(false)
ok(S.confirmOpen() == nil and #evas == 1, "Cancel closes it and nobody steps out")
S.evaMember(2, false, false)
S.confirmEva(true)
ok(#evas == 3 and evas[3].o.confirmed == true, "EVA anyway steps them out")
SAVE["crew.evaNoAsk"] = true
S.evaMember(3, false, false)
ok(evas[#evas].o.confirmed == true and S.confirmOpen() == nil, "don't-ask-again skips the confirm")

-- ── the alerts' chips and sounds ───────────────────────────────────────────
local H = load("scripts/crew_alerts_hud.lua")
local function chip(a, text) for _, c in ipairs(H.chipsOf(a)) do if c[1]:find(text, 1, true) then return c end end end
ok(chip({ o2 = 0.24, air_s = 288 }, "O2 24%")[2] == "warn", "O2 25%: an amber chip")
ok(chip({ o2 = 0.09, air_s = 108 }, "O2 9%")[2] == "danger", "O2 10%: a red chip")
ok(chip({ o2 = 0.04, air_s = 48 }, "O2 1 MIN") ~= nil, "under a minute of air: O2 1 MIN")
ok(chip({ fall = 8 }, "FALL") == nil and chip({ fall = 12 }, "FALL 12")[2] == "warn" and chip({ fall = 19 }, "FATAL FALL") ~= nil,
  "the fall chip: nothing under 9 m/s, amber from 9, FATAL FALL from 18")
ok(chip({ pinned = true }, "PINNED") ~= nil, "PINNED")
ok(chip({ cabin = 0.3, cabin_tol = 9 }, "CABIN FAILING · hold under 9 m/s") ~= nil, "CABIN FAILING with the tolerance")
ok(chip({ heat = 0.25 }, "HEAT")[2] == "warn" and chip({ heat = 0.65 }, "HEAT")[2] == "danger", "HEAT amber from 0.2, red from 0.6")
ok(chip({ blackout = 9 }, "BLACKOUT") ~= nil, "the blackout chip")
ok(#H.chipsOf({ o2 = 1, breath = 1, hp = 1, heat = 0, fall = 0 }) == 0, "nothing wrong, no chips")
local St = {}
local shots, loop = H.soundsOf(St, { o2 = 0.24, air_s = 288 }, 0)
ok(#shots == 1 and shots[1] == "chime" and loop == nil, "O2 25%: a chime, once")
shots = H.soundsOf(St, { o2 = 0.23, air_s = 280 }, 1)
ok(#shots == 0, "…not again")
shots = H.soundsOf(St, { o2 = 0.09, air_s = 100 }, 2)
ok(#shots == 1 and shots[1] == "alarm", "O2 10%: the alarm")
shots = H.soundsOf(St, { o2 = 0.08, air_s = 95 }, 7)
ok(#shots == 0, "…not before 10 s")
shots = H.soundsOf(St, { o2 = 0.07, air_s = 90 }, 12.5)
ok(#shots == 1, "…again after 10 s")
shots, loop = H.soundsOf(St, { o2 = 0.03, air_s = 40 }, 13)
ok(loop == "loop" and #shots == 0, "1 MIN: the alarm continuous")
shots, loop = H.soundsOf(St, { o2 = 0.0, air_s = 0, blackout = 12 }, 14)
ok(loop == "heart", "blackout: the heartbeat")
shots, loop = H.soundsOf(St, { o2 = 1, air_s = 1200 }, 20)
ok(loop == nil and #shots == 0, "breathing again: silence")

-- ── the interiors: iva.lua's seats agree with the generated prefabs ────────
local I = load("scripts/iva.lua")
local function prefab_nodes(name)
  local f = assert(io.open(ROOT .. "prefabs/" .. name .. ".prefab.ron"))
  local s = f:read("*a")
  f:close()
  local out = {}
  for nm, x, y, z in s:gmatch('name: "([%w]+)",%s*transform: %(%s*translation: %(([%-%d%.]+), ([%-%d%.]+), ([%-%d%.]+)%)') do
    out[nm] = { tonumber(x), tonumber(y), tonumber(z) }
  end
  return out, s
end
for part, d in pairs(I.DEFS) do
  local N, src = prefab_nodes(d.prefab)
  for k, seat in ipairs(d.seats) do
    local n = N["Seat" .. k]
    ok(n and near(n[1], seat[1]) and near(n[2], seat[2]) and near(n[3], seat[3]),
      string.format("%s Seat%d matches iva.lua", d.prefab, k))
    ok(N["Self" .. k] ~= nil and N["Eye" .. k] ~= nil, d.prefab .. " has Self" .. k .. " and Eye" .. k)
  end
  ok(N["Seat" .. (#d.seats + 1)] == nil, d.prefab .. " has exactly " .. #d.seats .. " seats")
  local em = N.EyeMain
  ok(em and near(em[1], d.eye_main[1]) and near(em[2], d.eye_main[2]) and near(em[3], d.eye_main[3]), d.prefab .. " EyeMain agrees")
  local lamps = 0
  for _ in src:gmatch('name: "Lamp%d+"') do lamps = lamps + 1 end
  ok(lamps == d.lamps, string.format("%s has %d lamps (%d)", d.prefab, d.lamps, lamps))
  ok(src:find('asset_path: "models/iva/' .. d.prefab:lower() .. '.glb"', 1, true) ~= nil, d.prefab .. " wears its mesh")
  ok(exists(ROOT .. "models/iva/" .. d.prefab:lower() .. ".glb"), d.prefab .. "'s mesh exists")
  -- the main camera's eye sits inside the hull (the part's own box)
  local box = ({ pod = { 0.5, 0.4 }, podMk2 = { 0.5, 0.575 }, cabin = { 0.57, 0.65 }, cockpit = { 0.6, 1.1 } })[part]
  ok(math.abs(d.eye_main[1]) < box[1] and math.abs(d.eye_main[2]) < box[2] and math.abs(d.eye_main[3]) < box[1] + 0.2,
    part .. ": the main eye is inside the hull")
end
-- the seat in crew.lua's convention (yaw 0 = the part's +X): a Pod Mk1
-- couch facing the window (-Z) is yaw +90°
local cs = I.crewSeat(I.DEFS.pod, 1)
ok(near(cs.yaw, math.pi / 2, 1e-4) and near(cs.y, -0.22), "Pod Mk1's seat for crew.lua faces -Z (yaw π/2)")
local h, f, e = I.seatInPart(I.DEFS.cockpit, 1)
ok(near(f[2], 1) and near(e[3], -(-0.20 + I.EYE_UP), 1e-3), "the Swift's pilot faces the nose (+Y) with the canopy overhead (-Z)")
ok(I.LAYER_BIT == 4 and I.OFF_BIT == 5 and S.INTERIOR_BIT == 2 ^ I.LAYER_BIT and S.OFFSTAGE_BIT == 2 ^ I.OFF_BIT, "interior is layer bit 4, offstage bit 5 (masks 16, 32)")

-- project.ron lists the layers in that order (Default is bit 0)
local pf = assert(io.open(ROOT .. "project.ron"))
local proj = pf:read("*a")
pf:close()
local list = proj:match("layers:%s*%[(.-)%]")
local idx, i = {}, 0
for nm in (list or ""):gmatch('"([%w_]+)"') do i = i + 1; idx[nm] = i end
ok(idx.interior == 4 and idx.offstage == 5, "project.ron: interior is layer 4, offstage 5 [" .. tostring(idx.interior) .. "," .. tostring(idx.offstage) .. "]")

if #failures > 0 then
  for _, m in ipairs(failures) do print("FAIL: " .. m) end
  print(string.format("%d/%d checks failed", #failures, checks))
  os.exit(1)
end
print(string.format("smoke_crew_strip: %d checks passed", checks))
