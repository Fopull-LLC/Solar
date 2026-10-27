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

-- ── the strip's layout: 1, 3 and 7 crew (paging) ───────────────────────────
local S = load("scripts/crew_strip.lua")
local L1 = S.layout(1, 1, "small")
ok(L1.pages == 1 and #L1.shown == 1 and not L1.paged and L1.w == 128 and L1.h == 96, "one aboard: one portrait, 128×96, no pager")
local L3 = S.layout(3, 1, "small")
ok(L3.pages == 1 and #L3.shown == 3 and L3.shown[3] == 3, "three aboard: three portraits on one page")
ok(L3.strip_w == 3 * 128 + 2 * S.GAP + 16, "…laid side by side with the 6-unit gap [" .. L3.strip_w .. "]")
local L7 = S.layout(7, 1, "small")
ok(L7.pages == 2 and L7.paged and #L7.shown == 4 and L7.shown[1] == 1 and L7.shown[4] == 4, "seven: page 1 shows 1–4 of 2 pages")
local L7b = S.layout(7, 2, "small")
ok(#L7b.shown == 3 and L7b.shown[1] == 5 and L7b.shown[3] == 7, "…page 2 shows 5–7")
ok(S.layout(7, 9, "small").page == 2 and S.layout(7, -1, "small").page == 1, "the page is clamped")
local Lg = S.layout(3, 1, "large")
ok(Lg.w == 256 and Lg.h == 192 and Lg.tw == 384 and Lg.th == 288, "large mode doubles portraits and targets")
ok(S.layout(0, 1, "small").pages == 1 and #S.layout(0, 1, "small").shown == 0, "nobody aboard: no portraits")
ok(S.PER_PAGE == 4, "at most four live portraits a page")
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
