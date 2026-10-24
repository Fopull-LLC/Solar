-- SMOKE: the controls rulebook (scripts/controls.lua) — pure logic, no engine.
-- Groups on any key, reserved flight keys, axis bindings (rate and position,
-- gain and trim), presets, the save format, the builder's command adapters,
-- and that an old craft's bp.groups still fly.
--
--   luajit solar/tests/smoke_controls.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

local function load(path)
  local env = setmetatable({}, { __index = _G })
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  return env
end
local E = load("solar/scripts/electronics.lua")
local C = load("solar/scripts/controls.lua")

-- A small arm: pod (1) → hinge (2) → hinge (3) → claw (4), a piston (5), two
-- floodlights in a ring (6, 7), legs (8), a rover wheel (9).
local function craft()
  local function rec(uid, id, label, mods, parent, sym)
    return { uid = uid, id = id, label = label, mods = mods, parent = parent, sym = sym }
  end
  return {
    [1] = rec(1, "pod", "Pod", E.deriveMods({ kind = "crewed" })),
    [2] = rec(2, "hinge", "Servo Hinge", { { type = "hinge", torque = 3, rate = 30 } }, 1),
    [3] = rec(3, "hinge", "Servo Hinge", { { type = "hinge", torque = 3, rate = 30 } }, 2),
    [4] = rec(4, "claw", "Landing Claw", { { type = "claw" } }, 3),
    [5] = rec(5, "piston", "Piston", { { type = "piston", rate = 0.3 } }, 1),
    [6] = rec(6, "light", "Floodlight", { { type = "light" } }, 1, 7),
    [7] = rec(7, "light", "Floodlight", { { type = "light" } }, 1, 7),
    [8] = rec(8, "legs", "Landing Legs", E.deriveMods({ legs = true }), 1),
    [9] = rec(9, "wheelM", "Wheel", { { type = "drive" } }, 1),
  }
end
local function ctx_of(groups, recs)
  return { groups = groups, recs = recs, E = E,
           members = function(u) local r = recs[u]
             if r and r.sym then local out = {}
               for v, q in pairs(recs) do if q.sym == r.sym then out[#out + 1] = v end end
               table.sort(out) return out end
             return { u } end }
end

-- ── keys ────────────────────────────────────────────────────────────────────
local ok, why = C.validKey("w")
check(not ok and why:find("pitch"), "W is refused: " .. tostring(why))
ok, why = C.validKey("space")
check(not ok and why:find("staging"), "Space is refused with its reason")
check(not C.validKey("m") and not C.validKey("f") and not C.validKey(".") and not C.validKey("escape"),
  "map, board, warp and Esc are reserved")
check(C.validKey("p") and C.validKey("up") and C.validKey("[") and C.validKey("num8") and C.validKey("4"),
  "P, arrows, brackets, numpad and digits are free")
check(C.gidForKey("g", E) == "gear" and C.gidForKey("4", E) == "4" and C.gidForKey("p", E) == "k:p",
  "G is the Gear group, 4 its digit group, P a key group")
check(C.keyOfGroup("k:[", E) == "[" and C.keyOfGroup("lights", E) == "y", "a group's key")
check(C.keyLabel("up") == "↑" and C.keyLabel("p") == "P", "key caps")

-- ── T4: select light, B, 4 (a pair in a ring binds as one) ──────────────────
local recs = craft()
local groups, state = {}, {}
local ctx = ctx_of(groups, recs)
local prim = C.primaryOf(recs[6], E)
check(prim and prim.acts[1] == "lit.toggle", "a light's primary action is Light on / off")
local gid = C.bind(state, { uid = 6, acts = prim.acts, key = "4", name = "Floods" }, ctx)
check(gid == "4" and E.isBound(groups, "4", 6, "lit.toggle") and E.isBound(groups, "4", 7, "lit.toggle"),
  "B then 4 binds both lights of the ring to group 4")
check(groups["4"].name == "Floods", "the custom group takes the name")
check(C.bind(state, { uid = 6, acts = prim.acts, key = "w" }, ctx) == false and C.lastError:find("pitch"),
  "a reserved key is refused with its reason")
-- a key group on any free key
check(C.bind(state, { uid = 8, acts = { "deployed.toggle" }, key = "p" }, ctx) == "k:p", "legs on P")
local xg = C.extraGroups(groups)
check(#xg == 1 and xg[1].key == "p", "the flight's extra key groups list P")

-- ── hinge on ↑/↓ as a rate axis: 1 s of ↑ moves the setpoint +30° ───────────
local src = C.bind(state, { uid = 2, axis = "angle", pos = "up", neg = "down", mode = "rate" }, ctx)
check(src == "c1", "hinge 1 on a custom axis c1 (↑/↓)")
local live = C.live(state)
local down = { up = true }
local function key(k) return down[k] == true end
local st2 = E.stateOf(recs[2])
for _ = 1, 60 do
  local inp = C.readInputs(live, key, function() return false end)
  C.apply(C.evaluate(live, inp, recs, 1 / 60, E), recs, E)
end
check(near(st2.angle, 30, 1e-6), string.format("1 s of ↑ = +30° (got %.3f)", st2.angle))
down = {}
for _ = 1, 30 do C.apply(C.evaluate(live, C.readInputs(live, key), recs, 1 / 60, E), recs, E) end
check(near(st2.angle, 30, 1e-6), "a rate axis holds where it stopped")

-- ── a position axis returns to trim on release; gain scales ─────────────────
check(C.bindAxis(state, { uid = 3, act = "angle", src = "pitch", mode = "position", gain = 0.5, trim = 10 }, ctx) == "pitch",
  "hinge 2 on PITCH, position, gain 0.5, trim 10°")
live = C.live(state)
local st3 = E.stateOf(recs[3])
down = { w = true }
C.apply(C.evaluate(live, C.readInputs(live, key), recs, 1 / 60, E), recs, E)
check(near(st3.angle, 10 + 0.5 * 90), string.format("full W: trim + gain × half range = 55° (got %.2f)", st3.angle))
down = {}
C.apply(C.evaluate(live, C.readInputs(live, key), recs, 1 / 60, E), recs, E)
check(near(st3.angle, 10), "released: back to the trim")
check(C.bindAxis(state, { uid = 3, act = "angle", field = "gain", value = -1 }, ctx), "tune the gain")
live = C.live(state)
down = { w = true }
C.apply(C.evaluate(live, C.readInputs(live, key), recs, 1 / 60, E), recs, E)
check(near(st3.angle, -80), "gain −1 inverts (10 − 90 = −80)")

-- piston: one-key latch between the presets
check(C.bind(state, { uid = 5, axis = "extension", pos = "o" }, ctx) == false, "O is the Controls card in flight")
check(C.bind(state, { uid = 5, axis = "extension", pos = "u" }, ctx) == false and C.lastError:find("Deploy"),
  "U is the Deploy key — refused for an axis")
local psrc = C.bind(state, { uid = 5, axis = "extension", pos = "j" }, ctx)
check(psrc == false, "J (translation) refused")
psrc = C.bind(state, { uid = 5, axis = "extension", pos = "x" }, ctx)
check(psrc == false, "X refused")
psrc = C.bind(state, { uid = 5, axis = "extension", pos = "[" }, ctx)
check(psrc and C.live(state).custom[psrc].neg == nil, "the piston latches on [")
live = C.live(state)
local st5 = E.stateOf(recs[5])
local presses = { ["["] = true }
C.apply(C.evaluate(live, C.readInputs(live, key, function(k) return presses[k] end), recs, 1 / 60, E), recs, E)
check(near(st5.extension, 0.8) and st5.extended, "a press runs it out to the stop")
C.apply(C.evaluate(live, C.readInputs(live, key, function(k) return presses[k] end), recs, 1 / 60, E), recs, E)
check(near(st5.extension, 0.0) and not st5.extended, "a second press brings it home")

-- conflicts
local use = C.keyUse(groups, state, "up", E)
check(#use == 1 and use[1].kind == "axis", "↑ is in use by an axis")
check(C.bind(state, { uid = 8, acts = { "deployed.on" }, key = "up" }, ctx) == false, "a key an axis owns can't take a group")
use = C.keyUse(groups, state, "y", E)
check(use[1] and use[1].kind == "group" and use[1].gid == "lights", "Y is the Lights key")

-- ── the context menu's list ─────────────────────────────────────────────────
local pc = C.partControls(groups, state, recs[2], E)
check(pc[1].axis == "angle" and pc[1].primary and pc[1].keys[1] == "↑/↓", "a hinge's menu leads with Angle on ↑/↓")
local found = false
for _, c in ipairs(pc) do if c.acts and c.acts[1] == "locked.toggle" then found = true end end
check(found, "…and lists Lock / unlock")

-- ── the keymap ──────────────────────────────────────────────────────────────
local km = C.keymap(groups, state, recs, E)
local k4
for _, r in ipairs(km.keys) do if r.key == "4" then k4 = r end end
check(k4 and k4.parts[1].n == 2 and k4.parts[1].label == "Floodlight", "keymap: 4 · Floodlight ×2")
check(#km.axes == 3, "keymap: three axis rows (PITCH, c1, c2): " .. #km.axes)

-- ── save format ─────────────────────────────────────────────────────────────
local function depth(t, d)
  d = d or 1
  local m = d
  for _, v in pairs(t) do if type(v) == "table" then m = math.max(m, depth(v, d + 1)) end end
  return m
end
check(depth(state) <= 2, "bp.controls is at most two tables deep (save.set holds four)")
local back = C.live(C.pack(C.live(state)))
check(#back.axes == 3 and back.custom.c1.pos == "up" and back.custom.c1.neg == "down", "pack → unpack round-trips")
local b3 = C.axisOf(back, 3, "angle")
check(b3 and b3.mode == "position" and near(b3.gain, -1) and near(b3.trim, 10), "tuning survives the round trip")
local rm = C.remap(state, { [2] = 12, [3] = 13 })
check(#C.live(rm).axes == 2 and C.axisOf(C.live(rm), 12, "angle"), "remap renumbers and drops")
check(#C.subset(state, { [5] = true }).axes == 1, "subset keeps the departing parts' axes")

-- unbind
check(C.unbind(state, { uid = 3, axis = "angle" }, ctx) == 1 and not C.axisOf(C.live(state), 3, "angle"), "unbind an axis")
check(C.unbind(state, { uid = 6, acts = { "lit.toggle" }, key = "4" }, ctx) == 2 and not groups["4"].binds[1],
  "unbind a key (both ring members)")

-- ── presets: Arm on 2 hinges and a claw gives 1/2, 3/4 and P ────────────────
recs = craft()
groups = E.defaultGroups(recs)    -- the standard set already put actuators on 1–0
state = {}
ctx = ctx_of(groups, recs)
check(C.bind(state, { preset = "arm", uids = { 2, 3, 4 } }, ctx), "the Arm preset on the selection")
live = C.live(state)
local a2, a3 = C.axisOf(live, 2, "angle"), C.axisOf(live, 3, "angle")
check(a2 and live.custom[a2.src].pos == "1" and live.custom[a2.src].neg == "2", "hinge 1 → 1/2")
check(a3 and live.custom[a3.src].pos == "3" and live.custom[a3.src].neg == "4", "hinge 2 → 3/4")
check(E.isBound(groups, "k:p", 4, "armed.toggle"), "claw → P")
local g12 = 0
for _, k in ipairs({ "1", "2", "3", "4" }) do g12 = g12 + #((groups[k] or {}).binds or {}) end
check(g12 == 0, "the digit groups the arm took are empty (no double drive)")
check(C.bind(state, { preset = "rover" }, ctx) and E.isBound(groups, "brakes", 9, "brakes.toggle"),
  "Rover: brakes on B")
check(C.bind(state, { preset = "rocket" }, ctx) and #C.live(state).axes == 0
  and E.isBound(groups, "gear", 8, "deployed.toggle"), "Rocket: the standard set, no axes")

-- an axis takes the part's old group keys for that axis off (no two drivers)
recs = craft()
groups = E.defaultGroups(recs)      -- piston on a digit key: Extend / retract
state = {}
ctx = ctx_of(groups, recs)
local had = #C.bindsOfPart(groups, 5, E)
C.bind(state, { uid = 5, axis = "extension", pos = "[", neg = "]" }, ctx)
check(had > 0 and #C.bindsOfPart(groups, 5, E) == 0, "binding the piston's axis takes its Extend / retract key off")

-- ── an old craft's bp.groups load unchanged ─────────────────────────────────
local old = { "gear|Gear|8@deployed.toggle", "1|Arm up|2@angle.inc" }
local og = E.unpackGroups(old)
check(og.gear and og.gear.binds[1].uid == 8 and og["1"].name == "Arm up", "v1 groups unpack as before")
local km2 = C.keymap(og, nil, craft(), E)
check(#km2.keys == 2 and #km2.axes == 0, "the keymap reads an old craft (no controls table)")
check(#C.live(nil).axes == 0, "no bp.controls → no axes")
-- key groups survive electronics' own pack/unpack (bp.groups)
local kg = {}
C.bindKey(kg, nil, { 8 }, { "deployed.toggle" }, "p", E)
local rt = E.unpackGroups(E.packGroups(kg))
check(rt["k:p"] and rt["k:p"].binds[1].uid == 8, "a key group rides bp.groups")

-- ── the flight card ─────────────────────────────────────────────────────────
recs = craft()
groups, state = {}, {}
ctx = ctx_of(groups, recs)
C.bind(state, { uid = 2, axis = "angle", pos = "up", neg = "down" }, ctx)
E.stateOf(recs[2]).angle = 45
local cd = C.card(groups, state, recs, E)
check(#cd.axes == 1 and near(cd.axes[1].value, 0.5) and cd.axes[1].cap == "↑/↓", "card: the axis tape reads +45° as half way")
check(C.customCount(groups, state, E) == 1, "one custom control")

for _, f in ipairs(failures) do print("FAIL " .. f) end
print(string.format("smoke_controls: %d passed, %d failed", passed, #failures))
if #failures > 0 then os.exit(1) end
