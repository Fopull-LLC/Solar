-- SMOKE: the builder's interface and camera (WP2, docs/builder-design.md §11.2).
--
-- Loads the panel scripts from disk with a stub builder (the public API only)
-- and reads back the trees they hand to `ui.make`:
--
--  * every panel describes with only properties ui.make accepts, and every
--    style it names exists in ui/solar.uistyle.ron;
--  * search "tank" + ENTER puts tankS in the hand;
--  * the context menu lists CONTROLS for a hinge;
--  * the layout fits from 1024 to 1506 design units wide (interface sizes);
--  * the camera's framing holds a 60 m stack, and zoom to the cursor is a
--    homothety (the point under the cursor does not move);
--  * an idle catalogue does not re-describe itself.
--
--   luajit solar/tests/smoke_builder_ui.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end

-- ── what ui.make accepts (floptle-ui make.rs ALL_PROPS) ─────────────────────
local PROPS = {}
for p in ([[align border borderB borderColor borderL borderR borderT button case cell cols count dir
  disabled draggable dropTarget field fill fillA fillB fillG fillR flip focusable font frame framePpu
  frameSlice frameUV gap group groupA groupB groupG groupR groupTint h height image imageFit inset
  interact justify lineHeight margin mask max maxH maxLen maxLines maxW min minH minW numeric opacity
  order overflow pad part pin pivot placeholder pos posX posY radius radiusBL radiusBR radiusTL
  radiusTR rotation rows scale scaleX scaleY scrollDrag scrollSpeed scrollX scrollY scrollbarAxis
  scrollbarFor selected shader size slice slicePpu sliderDir stretch style surface surfaceOffset
  surfaceTile surfaceTint template text textA textAlign textB textColor textFit textG textR textSize
  textValign texture tiling tint tintA tintB tintG tintR toggle tooltip tooltipBox tracking upper value
  visible w width wrap x y navUp navDown navLeft navRight]]):gmatch("%S+") do PROPS[p] = true end
local BUILDER = { key = true, name = true, items = true }
local KINDS = { box = true, row = true, col = true, text = true, image = true, button = true,
                field = true, slider = true, scroll = true }
local ENUMS = {
  pin = { "topLeft", "top", "topRight", "left", "center", "right", "bottomLeft", "bottom", "bottomRight" },
  align = { "start", "left", "top", "center", "end", "right", "bottom", "stretch" },
  justify = { "start", "center", "end", "between" },
  dir = { "row", "column" }, sliderDir = { "row", "column" },
}
ENUMS.textAlign, ENUMS.textValign = ENUMS.align, ENUMS.align
local STYLES = {}
for nm in io.open("solar/ui/solar.uistyle.ron"):read("*a"):gmatch('\n%s*"([%w/]+)":%s*%(') do STYLES[nm] = true end
check(STYLES["panel/frame"] and STYLES["hud/instrument"], "the style sheet parses")

local function one_of(v, list) for _, x in ipairs(list) do if x == v then return true end end return false end
local function validate(el, path, bad)
  if type(el) ~= "table" then return end
  if type(el[1]) == "string" and not KINDS[el[1]] then bad[#bad + 1] = path .. ": kind " .. el[1] end
  for k, v in pairs(el) do
    if type(k) == "string" then
      if not (PROPS[k] or BUILDER[k] or k:match("^on%u")) then bad[#bad + 1] = path .. ": property " .. k
      elseif ENUMS[k] and not one_of(v, ENUMS[k]) then bad[#bad + 1] = path .. ": " .. k .. " = " .. tostring(v)
      elseif k == "style" and not STYLES[v] then bad[#bad + 1] = path .. ": style " .. tostring(v) end
    end
  end
  local fn
  for i = 1, #el do
    if type(el[i]) == "table" then validate(el[i], path .. "/" .. tostring(el[i].key or i), bad)
    elseif type(el[i]) == "function" then fn = el[i] end
  end
  if el.items and fn then
    for i, it in ipairs(el.items) do
      local c = fn(it, i)
      if c then validate(c, path .. "/" .. tostring(c.key or i), bad) end
    end
  end
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

-- ── a stub engine and builder ───────────────────────────────────────────────
local function load(path, env)
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  return env
end
local REGE = load("solar/scripts/parts_registry.lua", setmetatable({}, { __index = _G }))
local E = load("solar/scripts/electronics.lua", setmetatable({ log = function() end }, { __index = _G }))

local made = {}
local scripts = {}
local B = {
  craftVersion = 1, _held = nil, _sel = {},
  recs = {
    [1] = { uid = 1, id = "tankS", x = 0, y = 0.61, z = 0 },
    [2] = { uid = 2, id = "hinge", x = 0, y = 1.31, z = 0 },
    [3] = { uid = 3, id = "wheelM", x = 0.9, y = 0.6, z = 0, wcfg = {} },
  },
}
function B.catalogue() return REGE.catalogue() end
function B.partInfo(id) return REGE.partInfo(id) end
function B.hold(spec) B._held = spec return true end
function B.held() return B._held and { B._held } or nil end
function B.selection() return B._sel end
function B.select(u, m) B._sel = type(u) == "table" and u or { u } return B._sel end
function B.partUids() return { 1, 2, 3 } end
function B.partRec(uid)
  local r = B.recs[uid]
  if not r then return nil end
  local c = {}
  for k, v in pairs(r) do c[k] = v end
  c.def, c.yaw, c.pitch, c.roll = REGE.REG[r.id], 0, 0, 0
  return c
end
function B.stats() return { parts = 3, mass = 0.4, cost = 600, dv = 0, twr = 0, launch = { warn = {} } } end
function B.cmd(name, a) B._last = { name, a } return true end
function B.registerPanel() return true end
function B.hint(m) B._hint = m end
function B.tool() return "select" end

local function stub_env()
  local env = setmetatable({}, { __index = _G })
  env.findScript = function(k) if k == "builder" then return B end return scripts[k] end
  env.ui = { make = function(node, tree) made[node] = tree end, focused = function() return nil end,
             focus = function() end, hovered = function() return nil end }
  env.input = { mouse = function() return 0, 0 end, button = function() return false end,
                pressed = function() return false end, key = function() return false end,
                scroll = function() return 0 end, mouse_delta = function() return 0, 0 end }
  env.save = { get = function(_, d) return d end, set = function() end }
  env.time = 0
  env.find = function() return nil end
  env.vec3 = nil
  return env
end
local function node(name)
  return { name = name, getcomponent = function(self) return self.el end, el = { visible = false, width = 10, height = 10 } }
end
for _, k in ipairs({ "builder_toolbar", "catalog_panel", "builder_inspector", "builder_context", "builder_statusbar",
                     "builder_camera" }) do
  scripts[k] = load("solar/scripts/" .. k .. ".lua", stub_env())
end
scripts.electronics = E
local T, CAT, INS, CTX, SB, CAM = scripts.builder_toolbar, scripts.catalog_panel, scripts.builder_inspector,
  scripts.builder_context, scripts.builder_statusbar, scripts.builder_camera

-- ── every panel describes cleanly ───────────────────────────────────────────
local nodes = {}
for _, k in ipairs({ "builder_toolbar", "catalog_panel", "builder_inspector", "builder_context", "builder_statusbar" }) do
  nodes[k] = node(k)
  scripts[k].start(nodes[k])
end
local function frame(dt)
  for _, k in ipairs({ "builder_toolbar", "catalog_panel", "builder_inspector", "builder_context", "builder_statusbar" }) do
    scripts[k].update(nodes[k], dt or 0.016)
  end
end
local function validate_all(label)
  for k, n in pairs(nodes) do
    local bad = {}
    validate(made[n], k, bad)
    check(#bad == 0, label .. ": " .. k .. " describes cleanly — " .. table.concat(bad, "; "))
  end
end
frame()
for _, k in ipairs({ "builder_toolbar", "catalog_panel", "builder_inspector", "builder_statusbar" }) do
  check(made[nodes[k]] ~= nil, k .. " made its plate")
end
check(nodes.builder_toolbar.el.visible == true and nodes.builder_toolbar.el.width > 1000,
  "the toolbar's host is stretched over the layer")
validate_all("nothing selected")

-- A hinge selected: the inspector shows numbers and controls; the menu opens.
B._sel = { 2 }; B.craftVersion = 2
check(CTX.openFor(2, 500, 300), "the context menu opens on a hinge")
frame()
validate_all("hinge selected, menu open")
local ents = CTX.entries(B, 2)
local ctl = 0
for _, e in ipairs(ents) do if e.kind == "control" then ctl = ctl + 1 end end
check(ctl > 0, "the context menu lists Controls for a hinge (" .. ctl .. ")")
local labels = {}
for _, e in ipairs(ents) do labels[e.key] = e end
check(labels.inspect and labels.delete and labels.copy and labels.sel, "the menu has Inspect, Select, Copy and Delete")
labels.delete.act()
check(B._last and B._last[1] == "delete" and B._last[2].uids[1] == 2, "Delete goes through cmd('delete')")
local ins_fields = 0
for _, el in ipairs(each(made[nodes.builder_inspector])) do
  if el[1] == "field" and el.numeric then ins_fields = ins_fields + 1 end
end
check(ins_fields == 6, "the inspector has six numeric fields (position and rotation): " .. ins_fields)
-- typing a position moves the part through cmd
for _, el in ipairs(each(made[nodes.builder_inspector])) do
  if el.name == "FieldInsPY" then el.onSubmitted({ text = "2.5" }) end
end
check(B._last and B._last[1] == "move" and B._last[2].y == 2.5 and B._last[2].uid == 2, "Y = 2.5 + ENTER moves the part")
-- typing a yaw turns it
for _, el in ipairs(each(made[nodes.builder_inspector])) do
  if el.name == "FieldInsRY" then el.onSubmitted({ text = "90" }) end
end
local Q = B._last and B._last[2].Q
check(B._last[1] == "rotate" and Q and math.abs(Q.X.z + 1) < 1e-9 and math.abs(Q.Z.x - 1) < 1e-9,
  "yaw 90 + ENTER turns it 90° about Y")

-- A wheel: the wheel settings are in INSPECT.
B._sel = { 3 }; B.craftVersion = 3
CTX.close()
frame()
validate_all("wheel selected")
local has_wheel = false
for _, el in ipairs(each(made[nodes.builder_inspector])) do if el.key == "whd" then has_wheel = true end end
check(has_wheel, "a selected wheel shows its settings in INSPECT")

-- ── the catalogue: search + ENTER ───────────────────────────────────────────
check(CAT.firstMatch(B, "tank") == "tankS", "the first match for 'tank' is tankS: " .. tostring(CAT.firstMatch(B, "tank")))
local field
for _, el in ipairs(each(made[nodes.catalog_panel])) do if el.name == "FieldPartSearch" then field = el end end
check(field ~= nil and field.onSubmitted ~= nil, "the catalogue has the search field")
field.onChanged({ text = "tank" })
field.onSubmitted({ text = "tank" })
check(B._held == "tankS", "search 'tank' + ENTER holds tankS: " .. tostring(B._held))
check(CAT.recent()[1] == "tankS", "the pick is in RECENT")
CAT.toggleFavourite("engineS")
check(CAT.isFavourite("engineS"), "★ keeps a favourite")
local fav = CAT.listFor(B, "FAV", "")
check(#fav == 1 and fav[1].id == "engineS", "the ★ tab lists the favourites")
check(#CAT.listFor(B, "PROPULSION", "") >= 5, "a section tab lists its parts")
check(#CAT.listFor(B, "ALL", "zzzz") == 0, "a search with no match lists nothing")
frame()
validate_all("search typed")
-- idle: no re-describe
local before = made[nodes.catalog_panel]
made[nodes.catalog_panel] = nil
frame(0.016)
check(made[nodes.catalog_panel] == nil, "an idle catalogue does not re-describe")
made[nodes.catalog_panel] = before

-- ── the layout fits every interface size ────────────────────────────────────
local function row_width(row)
  local w, n = 0, 0
  for i = 1, #row do
    local c = row[i]
    if type(c) == "table" then n = n + 1; if type(c.w) == "number" then w = w + c.w end end
  end
  return w + math.max(0, n - 1) * (row.gap or 0)
end
for _, H in ipairs({ 576, 720, 847, 900 }) do
  local W = H * 16 / 9
  local L = T.builderLayout(W, H)
  check(L.view.w > 300 and L.left.h > 380, string.format("the viewport is usable at %dx%d (%.0f wide, plates %.0f tall)",
    W, H, L.view.w, L.left.h))
  check(L.status.y + L.status.h <= H and L.toolbar.y >= 0, "the strip and the toolbar are on the layer at " .. H)
end
local bar = made[nodes.builder_toolbar][1]
local inner = T.builderLayout(1024, 576).toolbar.w - 2 * (bar.pad or 0)
check(row_width(bar[1]) <= inner, string.format("toolbar row 1 fits 1024 wide (%d of %d)", row_width(bar[1]), inner))
check(row_width(bar[2]) <= inner, string.format("toolbar row 2 fits 1024 wide (%d of %d)", row_width(bar[2]), inner))

-- ── the camera's maths ──────────────────────────────────────────────────────
local bx = CAM.boxOf({ x = -1, y = 0, z = -1 }, { x = 1, y = 60, z = 1 })
local f, r, u = CAM.viewBasis(0.6, -0.15)
local d = CAM.fitDistance(bx, bx.centre, f, r, u, math.tan(1.08 / 2), 16 / 9)
local C = { x = bx.centre.x - f.x * d, y = bx.centre.y - f.y * d, z = bx.centre.z - f.z * d }
local function proj(p)
  local q = { x = p.x - C.x, y = p.y - C.y, z = p.z - C.z }
  local z = q.x * f.x + q.y * f.y + q.z * f.z
  return (q.x * r.x + q.y * r.y + q.z * r.z) / z, (q.x * u.x + q.y * u.y + q.z * u.z) / z
end
local tv = math.tan(1.08 / 2)
local all_in = true
for _, p in ipairs({ { x = 0, y = 60, z = 0 }, { x = 0, y = 0, z = 0 }, { x = 1, y = 60, z = 1 }, { x = -1, y = 0, z = -1 } }) do
  local sx, sy = proj(p)
  if math.abs(sy) > tv or math.abs(sx) > tv * 16 / 9 then all_in = false end
end
check(all_in, string.format("F frames a 60 m stack inside the view (d = %.1f m)", d))
check(d < 120, "…without backing off further than it must (" .. string.format("%.1f", d) .. " m)")
-- zoom to the cursor: a point on the cursor ray keeps its place
local P = { x = 0, y = 30, z = 0 }
local Qp = { x = 3, y = 40, z = 2 }
local C1 = { x = 10, y = 35, z = 30 }
local C2, P2 = CAM.zoomAbout(C1, P, Qp, 0.5)
local function dir(a, b) local x, y, z = b.x - a.x, b.y - a.y, b.z - a.z local l = math.sqrt(x * x + y * y + z * z) return x / l, y / l, z / l end
local ax, ay, az = dir(C1, Qp)
local bx2, by2, bz2 = dir(C2, Qp)
check(math.abs(ax - bx2) + math.abs(ay - by2) + math.abs(az - bz2) < 1e-9, "zoom to the cursor keeps the point under the cursor")
check(math.abs((P2.y - Qp.y) - (P.y - Qp.y) * 0.5) < 1e-9, "…and scales the pivot toward it")
local cb = CAM.craftBounds({ { x = 0, y = 1, z = 0, r = 0.5 }, { x = 0, y = 59, z = 0, r = 1 } })
check(cb.axis == "y" and math.abs(cb.hi.y - 60) < 1e-9 and math.abs(cb.lo.y - 0.5) < 1e-9, "craftBounds spans the stack")

-- ── report ──────────────────────────────────────────────────────────────────
if #failures > 0 then
  print(string.format("smoke_builder_ui: %d passed, %d FAILED", passed, #failures))
  for _, m in ipairs(failures) do print("  FAIL " .. m) end
  os.exit(1)
end
print(string.format("smoke_builder_ui: %d checks passed", passed))
