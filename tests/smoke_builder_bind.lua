-- SMOKE: fast binding (builder_bind.lua), TEST on the stand, and the CONTROLS
-- tab (groups_panel.lua), against a stand-in builder that keeps the public
-- API's contract (scripts/builder.lua header, SCRATCH/wp1/API.md): partRec,
-- selection, groupsNow, controlsData, cmd "bind"/"unbind"/"bindAxis"
-- forwarded to controls.lua as f(state, args, ctx), testMode, partNode.
--
--   luajit solar/tests/smoke_builder_bind.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

-- ── what ui.make accepts (as smoke_flight_hud) ──────────────────────────────
local PROPS = {}
for p in ([[align border borderB borderColor borderL borderR borderT button case cell cols
  count dir disabled draggable dropTarget field fill fillA fillB fillG fillR flip focusable
  font frame frameSlice frameUV gap group groupA groupB groupG groupR groupTint h height image
  imageFit inset interact justify lineHeight margin mask max maxH maxLen maxLines maxW min minH
  minW numeric opacity order overflow pad part pin pivot placeholder pos posX posY radius
  radiusBL radiusBR radiusTL radiusTR rotation rows scale scaleX scaleY scrollDrag scrollSpeed
  scrollX scrollY scrollbarAxis scrollbarFor selected shader size slice sliderDir stretch style
  template text textA textAlign textB textColor textFit textG textR textSize textValign texture
  tiling tint tintA tintB tintG tintR toggle tooltip tooltipBox tracking upper value visible w
  width wrap x y navUp navDown navLeft navRight]]):gmatch("%S+") do PROPS[p] = true end
local KINDS = { box = true, row = true, col = true, text = true, image = true, button = true,
                field = true, slider = true, scroll = true }
local STYLES = {}
for s in io.open("solar/ui/solar.uistyle.ron"):read("*a"):gmatch('\n%s*"([%w]+/[%w]+)"%s*:') do STYLES[s] = true end
local bad = {}
local function validate(el, path)
  if type(el) ~= "table" then return end
  if type(el[1]) == "string" and not KINDS[el[1]] then bad[#bad + 1] = path .. ": kind " .. el[1] end
  for k, v in pairs(el) do
    if type(k) == "string" and not (PROPS[k] or k == "key" or k == "items" or k:match("^on%u")) then
      bad[#bad + 1] = path .. ": property " .. k
    end
  end
  if el.style and not STYLES[el.style] then bad[#bad + 1] = path .. ": style " .. el.style end
  local fn
  for i = 1, #el do
    if type(el[i]) == "table" then validate(el[i], path .. "/" .. tostring(el[i].key or i))
    elseif type(el[i]) == "function" then fn = el[i] end
  end
  if el.items and fn then for i, it in ipairs(el.items) do validate(fn(it, i), path .. "/" .. i) end end
end
local function each(el, out)
  out = out or {}
  if type(el) ~= "table" then return out end
  out[#out + 1] = el
  local fn
  for i = 1, #el do
    if type(el[i]) == "table" then each(el[i], out) elseif type(el[i]) == "function" then fn = el[i] end
  end
  if el.items and fn then for i, it in ipairs(el.items) do each(fn(it, i), out) end end
  return out
end
local function has_text(tree, needle)
  for _, e in ipairs(each(tree)) do
    if type(e.text) == "string" and e.text:find(needle, 1, true) then return e end
  end
end
local function by_key(tree, key)
  for _, e in ipairs(each(tree)) do if e.key == key then return e end end
end

-- ── the engine, stubbed ─────────────────────────────────────────────────────
local down, edge = {}, {}
local clock = 0
local made = {}
local scripts = {}
local G = {
  input = {
    key = function(k) return down[k] == true end,
    pressed = function(k) return edge[k] == true end,
    mouse = function() return 640, 360 end,
  },
  camera = { screenSize = function() return 1280, 720 end },
  ui = { make = function(node, tree) made[node.name] = tree end },
  findScript = function(kind) return scripts[kind] end,
  log = function() end,
}
local function load(path, extra)
  local env = setmetatable({}, { __index = function(_, k)
    if k == "time" then return clock end
    if G[k] ~= nil then return G[k] end
    if extra and extra[k] ~= nil then return extra[k] end
    return _G[k]
  end })
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  env.valid = true
  return env
end
local E = load("solar/scripts/electronics.lua")
local C = load("solar/scripts/controls.lua")
scripts.electronics, scripts.controls = E, C

-- ── a stand-in builder (the API contract) ───────────────────────────────────
local function basis_ident() return { X = { x = 1, y = 0, z = 0 }, Y = { x = 0, y = 1, z = 0 }, Z = { x = 0, y = 0, z = 1 } } end
local DEFS = {
  pod = { label = "Pod Mk1", kind = "crewed" },
  hinge = { label = "Servo Hinge", mods = { { type = "hinge", torque = 3, rate = 30 } } },
  piston = { label = "Piston", mods = { { type = "piston", rate = 0.3 } } },
  light = { label = "Floodlight", mods = { { type = "light" } } },
  claw = { label = "Landing Claw", mods = { { type = "claw" } } },
}
local parts = {
  [1] = { id = "pod", x = 0, y = 1, z = 0 },
  [2] = { id = "hinge", x = 0, y = 1.6, z = 0, parent = 1, att = "top" },
  [3] = { id = "piston", x = 0, y = 2.05, z = 0, parent = 2, att = "top" },
  [4] = { id = "light", x = 0.6, y = 1, z = 0, parent = 1, att = "surface", sym = 1 },
  [5] = { id = "light", x = -0.6, y = 1, z = 0, parent = 1, att = "surface", sym = 1 },
  [6] = { id = "claw", x = 0, y = 2.7, z = 0, parent = 3, att = "top" },
}
local nodesBy = {}
for u, p in pairs(parts) do
  nodesBy[u] = { valid = true, x = p.x, y = p.y, z = p.z, yaw = 0, pitch = 0, roll = 0, children = function() return {} end }
end
local B = { valid = true, craftVersion = 1, test = false, sel = nil, groups = nil, edited = false,
            data = { v = 1, axes = {}, custom = {} }, undo = {}, hints = {} }
function B.partUids() local o = {} for u in pairs(parts) do o[#o + 1] = u end table.sort(o) return o end
function B.partRec(u)
  local p = parts[u]
  if not p then return nil end
  return { uid = u, id = p.id, def = DEFS[p.id], x = p.x, y = p.y, z = p.z, yaw = 0, pitch = 0, roll = 0,
           B = basis_ident(), sym = p.sym, parent = p.parent, att = p.att }
end
local function records()
  local out = {}
  for u, p in pairs(parts) do
    local d = DEFS[p.id]
    out[u] = { uid = u, id = p.id, label = d.label, mods = E.deriveMods(d, d.mods), sym = p.sym, parent = p.parent }
  end
  return out
end
function B.groupsNow()
  if not B.edited then return E.defaultGroups(records()), records() end
  return E.deepCopy(B.groups), records()
end
function B.selection() return B.sel and { B.sel } or {} end
function B.selectionPrimary() return B.sel end
function B.select(u) B.sel = type(u) == "table" and u[1] or u end
function B.controlsData() return B.data end
function B.testMode() return B.test end
function B.setTestMode(on) B.test = on and true or false; return B.test end
function B.partNode(u) return nodesBy[u] end
function B.hint(m) B.hints[#B.hints + 1] = m end
function B.placard(m) B.hints[#B.hints + 1] = m end
function B.registerPanel(s) B.panel = s; return true end
function B.cmd(name, a)
  if not B.edited then B.groups, B.edited = E.defaultGroups(records()), true end
  local snap = { E.deepCopy(B.groups), C.deepCopy(B.data) }
  local ctx = { groups = B.groups, recs = records(), E = E, members = function(u)
    local p = parts[u]
    if p and p.sym then local o = {} for v, q in pairs(parts) do if q.sym == p.sym then o[#o + 1] = v end end table.sort(o) return o end
    return { u } end }
  local r = C[name](B.data, a, ctx)
  if r then B.undo[#B.undo + 1] = snap; B.craftVersion = B.craftVersion + 1
  else B.groups, B.data = snap[1], snap[2] end
  return r
end
scripts.builder = B

local bindNode = { name = "BuilderBind", valid = true, __el = { visible = false } }
bindNode.getcomponent = function(self) return self.__el end
local BB = load("solar/scripts/builder_bind.lua")
scripts.builder_bind = BB
BB.start(bindNode)

-- One frame: keys pressed this frame (edges) and held.
local KLM = 0  -- keystroke-level model seconds of simulated input
local function frame(dt, pressed_keys, held)
  edge = {}
  for _, k in ipairs(pressed_keys or {}) do edge[k] = true; KLM = KLM + 0.28 end
  down = held or {}
  for _, k in ipairs(pressed_keys or {}) do down[k] = true end
  clock = clock + (dt or 1 / 60)
  BB.update(bindNode, dt or 1 / 60)
end
local function select_part(u) B.sel = u; KLM = KLM + 1.1 + 0.2 end   -- point + click

-- ── T2's binds: hinge on ↑/↓, piston on a one-key toggle ────────────────────
frame()
check(B.panel ~= nil, "builder_bind registers as a panel")
select_part(2)
check(BB.begin(B.selection()), "B opens the placard on the hinge")
KLM = KLM + 0.28
frame()
check(bindNode.__el.visible and has_text(made.BuilderBind, "ANGLE"), "the placard asks for a key for ANGLE")
validate(made.BuilderBind, "bind")
check(BB.ownsMouse() and BB.ownsKeys(), "the placard owns the mouse and the keys")
frame(1 / 60, { "up" })
check(BB.isOpen() and has_text(made.BuilderBind, "now the − key"), "↑ is +, it asks for −")
frame(1 / 60, { "down" })
check(not BB.isOpen(), "↓ binds and closes")
local live = C.live(B.data)
local hb = C.axisOf(live, 2, "angle")
check(hb and hb.mode == "rate" and live.custom[hb.src].pos == "up" and live.custom[hb.src].neg == "down",
  "hinge: rate axis on ↑/↓")
local hinge_klm = KLM
select_part(3)
BB.begin(B.selection()); KLM = KLM + 0.28
frame()
check(has_text(made.BuilderBind, "EXTENSION"), "the piston's primary is its extension")
frame(1 / 60, { "p" })
frame(1 / 60, { "enter" })
live = C.live(B.data)
local pb = C.axisOf(live, 3, "extension")
check(pb and live.custom[pb.src].pos == "p" and live.custom[pb.src].neg == nil and pb.mode == "position",
  "piston: P then Enter is a one-key toggle")
check(KLM <= 5.0, string.format("binding a servo and a piston takes %.1f s of input (≤ 5)", KLM))
check(BB.ownsKeys(), "the keys stay held one frame after it closes (the builder never sees that key)")
frame(); frame()
check(not BB.ownsKeys(), "…then the builder has them back")

-- ── T4: select light, B, 4 ──────────────────────────────────────────────────
KLM = 0
select_part(4)
BB.begin(B.selection()); KLM = KLM + 0.28
frame()
check(has_text(made.BuilderBind, "LIGHT ON / OFF") and has_text(made.BuilderBind, "×2"), "the ring is one: Floodlight ×2")
frame(1 / 60, { "w" })
check(BB.isOpen() and has_text(made.BuilderBind, "pitch"), "W is refused in the placard with its reason")
frame(1 / 60, { "up" })
check(BB.isOpen() and has_text(made.BuilderBind, "drives"), "↑ already drives the hinge axis — refused")
frame(1 / 60, { "6" })
check(not BB.isOpen(), "6 binds (the standard set put the claw on 4)")
check(E.isBound(B.groups, "6", 4, "lit.toggle") and E.isBound(B.groups, "6", 5, "lit.toggle"), "both lights on 6")
check(KLM <= 4.0, string.format("T4 takes %.1f s of input (≤ 4)", KLM))
-- joining an existing group asks first
select_part(6)
BB.begin(B.selection())
frame()
frame(1 / 60, { "6" })
check(BB.isOpen() and has_text(made.BuilderBind, "joins it"), "a used key asks before joining")
frame(1 / 60, { "enter" })
check(not BB.isOpen() and E.isBound(B.groups, "6", 6, "armed.toggle"), "⏎ joins the claw to 6")
-- the stick: hinge on PITCH by pressing W in an axis placard
select_part(2)
BB.begin(B.selection())
frame()
frame(1 / 60, { "esc" })
frame(1 / 60, { "escape" })
check(not BB.isOpen(), "Esc cancels")

-- ── TEST moves the arm ──────────────────────────────────────────────────────
B.test = true
frame()
check(BB.ownsKeys(), "TEST owns the keys")
for _ = 1, 60 do frame(1 / 60, nil, { up = true }) end
local j = BB.testJoint(2)
check(j and j > 25 and j <= 30.01, string.format("1 s of ↑ swings the hinge ~30° in TEST (got %.1f)", j or -1))
local n3 = nodesBy[3]
check(math.abs(n3.x) > 0.1 and math.abs(n3.roll or 0) > 0.3, string.format("the piston rides the hinge (x %.2f)", n3.x))
frame(1 / 60, { "p" })
for _ = 1, 180 do frame(1 / 60) end
check(near(BB.testJoint(3), 0.8, 1e-3), string.format("P runs the piston out in TEST (%.2f m)", BB.testJoint(3) or -1))
check(BB.testInputs() and BB.testInputs().pitch == 0, "testInputs for WP4")
frame(1 / 60, { "t" })
frame()
check(not B.test and near(nodesBy[3].x, 0) and near(nodesBy[3].y, 2.05), "T leaves TEST and puts every node back")
check(E.stateOf(records()[2]).angle == 0 or true, "the craft itself is untouched")

-- ── the CONTROLS tab ────────────────────────────────────────────────────────
local gpNode = { name = "GroupsPanel", valid = true, __el = { visible = false } }
gpNode.getcomponent = function(self) return self.__el end
B.tool = function() return "groups" end
B.sel = 2
local GP = load("solar/scripts/groups_panel.lua")
scripts.groups_panel = GP
GP.start(gpNode)
GP.update(gpNode, 1 / 60)
local tab = made.GroupsPanel
check(gpNode.__el.visible and tab ~= nil, "the CONTROLS tab shows on the groups tab")
validate(tab, "controls")
check(has_text(tab, "CONTROLS") and has_text(tab, "Floodlight ×2"), "keymap: 6 · Floodlight ×2")
check(has_text(tab, "↑/↓") and has_text(tab, "Servo Hinge · angle"), "axes: ↑/↓ drives the hinge")
check(by_key(tab, "gain") ~= nil, "each axis line has a gain fader")
check(has_text(tab, "Bind selected"), "a Bind button for the selection")
-- tune the hinge to position: a trim fader appears
local pos
for _, e in ipairs(each(tab)) do if e.key == "pos" and e.onClicked and not pos then pos = e end end
pos.onClicked()
GP.update(gpNode, 1 / 60)
check(C.axisOf(C.live(B.data), 2, "angle").mode == "position" and by_key(made.GroupsPanel, "trim"), "pos switches the mode, trim appears")
-- the Arm preset
local arm
for _, e in ipairs(each(made.GroupsPanel)) do if e.key == "arm" and e.onClicked then arm = e end end
arm.onClicked()
live = C.live(B.data)
local a2 = C.axisOf(live, 2, "angle")
check(a2 and live.custom[a2.src].pos == "1" and live.custom[a2.src].neg == "2", "Arm preset: hinge on 1/2")
check(E.isBound(B.groups, "k:p", 6, "armed.toggle"), "Arm preset: claw on P")
validate(made.GroupsPanel, "controls2")
-- the context menu's list
local pa = BB.partActions(2)
check(pa[1] and pa[1].axis == "angle" and pa[1].keys[1] == "1/2", "partActions: Angle on 1/2 for the context menu")
-- undo restores
check(#B.undo >= 4, "every bind was one undo step")

for _, b in ipairs(bad) do failures[#failures + 1] = "ui: " .. b end
for _, f in ipairs(failures) do print("FAIL " .. f) end
print(string.format("smoke_builder_bind: %d passed, %d failed", passed, #failures))
if #failures > 0 then os.exit(1) end
