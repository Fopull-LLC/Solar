-- SMOKE (WP1, docs/builder-design.md §5, §8, §11.2): the builder's graph,
-- frame, hash and history rulebooks on their own, then the real builder.lua
-- through a stubbed engine.
--
--   * graph: a beam in the middle of a closed rectangle has NO dependents; a
--     decoupler splits the craft into the root's side and its far side; a
--     hinge whose moving side reaches back to the fixed side is LOCKED
--   * blueprint: v1 → (load) → v2 (save) keeps every flight field, and adds
--     links; a v2 blueprint reloads with the same links
--   * frame adapter: toLocal ∘ toWorld is the identity on a turned frame; the
--     wrapped camera hands back local rays
--   * hash: a ray finds exactly what a brute-force slab test finds
--   * history: 500 steps, undo and redo of place / delete / move
--   * builder: multi-select (SHIFT, CTRL, box), drag-move carries dependents,
--     ALT-drag only the selection, insert on an occupied joint, detach, ESC
--     never leaves, copy / paste / duplicate, the craft library, a
--     sub-assembly in hand
--
--   luajit solar/tests/smoke_builder_graph.lua   (from the Floptle repo root)

local failures, checks = {}, 0
local function check(cond, what)
  checks = checks + 1
  if not cond then failures[#failures + 1] = what end
end
local function near(a, b, e) return math.abs(a - b) < (e or 1e-6) end
local function load_pure(name)
  local env = setmetatable({}, { __index = _G })
  local f = assert(loadfile("solar/scripts/" .. name .. ".lua"))
  setfenv(f, env)
  f()
  return env
end

-- ── 1. the graph rulebook ───────────────────────────────────────────────────
local GL = load_pure("builder_graph")
do
  -- a closed rectangle: 1-2-3-4-1 (4 beams), root 1
  local G = GL.newGraph()
  local alive = { [1] = true, [2] = true, [3] = true, [4] = true }
  G:add({ a = 1, b = 2, k = "corner", prim = true })
  G:add({ a = 2, b = 3, k = "corner", prim = true })
  G:add({ a = 3, b = 4, k = "corner", prim = true })
  G:add({ a = 4, b = 1, k = "weld" })
  local d = GL.dependents(G, alive, { [3] = true }, 1)
  check(next(d) == nil, "a mid-frame beam in a closed rectangle has no dependents")
  -- open the loop: now 4 hangs from 3
  local w
  for _, l in ipairs(G:incident(4)) do if l.k == "weld" then w = l.id end end
  G:remove(w)
  d = GL.dependents(G, alive, { [3] = true }, 1)
  check(d[4] and not d[2] and not d[1], "with the loop open, the beam beyond depends on it")
  check(G:add({ a = 1, b = 2, k = "corner" }) ~= nil and G:count() == 3, "the same link is never added twice")

  -- decouple: pod(1) - tank(2) - decoupler(3) - tank(4) - engine(5)
  local G2 = GL.newGraph()
  local al = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true }
  G2:add(GL.v1Link(1, 2, "bottom"))
  G2:add(GL.v1Link(2, 3, "bottom"))
  G2:add(GL.v1Link(3, 4, "bottom"))
  G2:add(GL.v1Link(4, 5, "bottom"))
  local far = GL.separation(G2, al, 3, 1)
  check(far and far[3] and far[4] and far[5] and not far[1] and not far[2], "a decoupler throws off its far side")
  -- a strut from the lower tank back to the upper one: no separation
  G2:add({ a = 2, b = 4, k = "brace" })
  check(GL.separation(G2, al, 3, 1) == nil, "a brace across the decoupler keeps the stages joined")
  local comps = GL.components(G2, al, 1)
  check(#comps == 2 and comps[1].root, "components: the craft and the loose part 6, root's first")

  -- a hinge (2) on a base (1) carrying an arm (3); a strut from arm to base locks it
  local G3 = GL.newGraph()
  local a3 = { [1] = true, [2] = true, [3] = true }
  G3:add({ a = 1, b = 2, k = "stack", prim = true })
  G3:add({ a = 2, b = 3, k = "hinge", prim = true })
  check(not GL.hingeLocked(G3, a3, 2), "a free hinge is not locked")
  G3:add({ a = 3, b = 1, k = "brace" })
  check(GL.hingeLocked(G3, a3, 2), "a hinge whose arm is braced to its base is locked by the loop")
  -- stack-node occupancy comes from link sides, never world Y
  check(G2:sideUsed(2, "bottom") and G2:sideUsed(3, "top") and not G2:sideUsed(1, "top"), "occupancy from link sides")
end

-- ── 2. the frame adapter and the hash ───────────────────────────────────────
local SL = load_pure("builder_space")
do
  local c, s = math.cos(0.7), math.sin(0.7)
  -- a node turned 0.7 rad about Y at (10, 2, -5)
  local node = { valid = true, worldPos = { x = 10, y = 2, z = -5 } }
  function node:worldRight() return { x = c, y = 0, z = -s } end
  function node:worldUp() return { x = 0, y = 1, z = 0 } end
  function node:worldForward() return { x = -s, y = 0, z = -c } end
  local cam = { screenToRay = function() return 10, 12, -5, 0, -1, 0 end,
                worldToScreen = function(x, y, z) return x, z, 1, true end }
  local F = SL.newFrame(node, cam)
  F.refresh()
  local wx, wy, wz = F.toWorld(1, 2, 3)
  local lx, ly, lz = F:toLocal(wx, wy, wz)
  check(near(lx, 1) and near(ly, 2) and near(lz, 3), "frame: toLocal ∘ toWorld is the identity")
  local ox, oy, oz, dx, dy, dz = F.ray(0, 0)
  check(near(ox, 0) and near(oy, 10) and near(oz, 0) and near(dy, -1), "frame: the cursor ray arrives local")
  local wc = SL.wrapCamera(F, cam)
  local sx, sy = wc.worldToScreen(0, 0, 0)
  check(near(sx, 10) and near(sy, -5), "frame: the wrapped camera projects local points")
  local I = SL.newFrame(nil, cam)
  check(I.identity and select(1, I.toWorld(4, 5, 6)) == 4, "no BuildFrame: the identity")

  -- the hash against brute force, 600 random boxes, 200 random rays
  local H = SL.newHash(1.0, 0.5)
  local boxes = {}
  local seed = 7
  local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 end
  for u = 1, 600 do
    local x, y, z = rnd() * 40 - 20, rnd() * 20, rnd() * 40 - 20
    local h = 0.1 + rnd() * (u % 50 == 0 and 8 or 1)
    boxes[u] = { x - h, y - h, z - h, x + h, y + h, z + h }
    H:set(u, unpack(boxes[u]))
  end
  local function slab(b, ox, oy, oz, dx, dy, dz)
    local t0, t1 = 0, 400
    local o, d = { ox, oy, oz }, { dx, dy, dz }
    for k = 1, 3 do
      if math.abs(d[k]) < 1e-12 then
        if o[k] < b[k] or o[k] > b[k + 3] then return false end
      else
        local a, c2 = (b[k] - o[k]) / d[k], (b[k + 3] - o[k]) / d[k]
        if a > c2 then a, c2 = c2, a end
        t0, t1 = math.max(t0, a), math.min(t1, c2)
        if t0 > t1 then return false end
      end
    end
    return true
  end
  local bad = 0
  for _ = 1, 200 do
    local ox, oy, oz = rnd() * 80 - 40, rnd() * 40 - 10, rnd() * 80 - 40
    local dx, dy, dz = rnd() - 0.5, rnd() - 0.5, rnd() - 0.5
    local l = math.sqrt(dx * dx + dy * dy + dz * dz)
    dx, dy, dz = dx / l, dy / l, dz / l
    local got = {}
    for _, u in ipairs(H:ray(ox, oy, oz, dx, dy, dz, 400, {}, 0)) do got[u] = true end
    for u, b in pairs(boxes) do
      if slab(b, ox, oy, oz, dx, dy, dz) ~= (got[u] == true) then bad = bad + 1 end
    end
  end
  check(bad == 0, "hash: every ray finds exactly the boxes it passes (" .. bad .. " wrong)")
  local inbox = H:box(-1, -1, -1, 1, 1, 1, {})
  local want = 0
  for _, b in pairs(boxes) do if b[1] <= 1 and b[4] >= -1 and b[2] <= 1 and b[5] >= -1 and b[3] <= 1 and b[6] >= -1 then want = want + 1 end end
  check(#inbox == want, "hash: a box query finds the overlapping boxes")
  H:remove(1)
  check(H:count() == 599, "hash: remove")
end

-- ── 3. the history rulebook ─────────────────────────────────────────────────
do
  local HL = load_pure("builder_history")
  local H = HL.newHistory(500)
  local v = 0
  for i = 1, 520 do
    H:push({ label = "s" .. i, undo = function() v = v - 1 end, redo = function() v = v + 1 end })
    v = v + 1
  end
  check(H:size() == 500, "history keeps 500 steps")
  for _ = 1, 500 do H:undo() end
  check(v == 20 and not H:canUndo(), "500 undos")
  H:redo(); H:redo()
  check(v == 22 and H:list().index == 2, "redo")
  H:jump(10)
  check(v == 30, "jump to step 10")
  H:push({ label = "m", merge = "k", undo = function() end })
  H:push({ label = "m2", merge = "k", undo = function() end })
  check(H:size() == 11 and H:top().label == "m2", "a merge key folds a drag into one step (and drops the redo tail)")
end

-- ── 4. the builder, driven ─────────────────────────────────────────────────
local T, TICK = 0.0, 1 / 60
local nodes, next_id = {}, 1
local function make_node(name, x, y, z)
  local n = { id = next_id, name = name, valid = true, visible = true, x = x or 0, y = y or 0, z = z or 0,
              pitch = 0, roll = 0, yaw = 0, text = "", components = {} }
  n.getcomponent = function(self, k) return self.components[k] end
  n.uiRect = function() return 0, 0, 0, 0 end
  next_id = next_id + 1
  nodes[#nodes + 1] = n
  return n
end
local API, store = {}, {}
API.vec3 = function(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
API.destroy = function(n) n.valid = false end
API.find = function(name) for _, n in ipairs(nodes) do if n.valid and n.name == name then return n end end end
API.print, API.log = function() end, function() end
API.spawn = function(prefab, pos, cb) local n = make_node(prefab, pos.x, pos.y, pos.z) if cb then cb(n) end end
API.KEYS = { down = {}, edge = {} }
local MOUSE = { x = 5000, y = 5000, lmb = false }
API.input = {
  key = function(k) return API.KEYS.down[k] or false end,
  pressed = function(k) return API.KEYS.edge[k] or false end,
  button = function(b) return b == 0 and MOUSE.lmb or false end,
  mouse = function() return MOUSE.x, MOUSE.y end,
}
-- straight down: screen x = world x, screen y = world z (×100 + 500)
API.camera = {
  worldToScreen = function(x, y, z) return x * 100 + 500, z * 100 + 500, 20 - y, true end,
  screenSize = function() return 1920, 1080 end,
  screenToRay = function(mx, my) return (mx - 500) / 100, 20.0, (my - 500) / 100, 0, -1, 0 end,
}
API.raycast = function() return nil end
API.draw = setmetatable({}, { __index = function() return function() end end })
API.audio = setmetatable({}, { __index = function() return function() end end })
API.save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end, flush = function() end }
local scene_loads = 0
API.scene = { load = function() scene_loads = scene_loads + 1 end }
local REGENV = load_pure("parts_registry")
API.findScript = function(k) if k == "parts_registry" then return REGENV end end
API.findScripts = function() return {} end
make_node("BuildStats"); make_node("BuildHint")
local env = setmetatable({}, { __index = function(_, k)
  if k == "time" then return T end
  return API[k] or _G[k]
end })
local chunk = assert(loadfile("solar/scripts/builder.lua"))
setfenv(chunk, env)
chunk()
env.params = {}
for k, v in pairs(env.defaults or {}) do env.params[k] = v end
local bnode = make_node("Builder")
local function step(n)
  for _ = 1, n or 1 do
    T = T + TICK
    local ok, err = xpcall(env.update, debug.traceback, bnode, TICK)
    if not ok then failures[#failures + 1] = "update: " .. err end
    API.KEYS.edge = {}
  end
end
local function press(k) API.KEYS.edge[k] = true; step(1) end
local function at(x, z) MOUSE.x, MOUSE.y = x * 100 + 500, z * 100 + 500 end
local function click() MOUSE.lmb = true; step(1); MOUSE.lmb = false; step(25) end
local function drag(x0, z0, x1, z1)
  at(x0, z0); MOUSE.lmb = true; step(1)
  for i = 1, 6 do at(x0 + (x1 - x0) * i / 6, z0 + (z1 - z0) * i / 6); step(1) end
  MOUSE.lmb = false; step(2)
end
local function P(t)
  local d = { yaw = 0, pitch = 0, roll = 0, parent = 0, att = "", sym = 0, stage = 0, mir = "" }
  for k, v in pairs(t) do d[k] = v end
  return d
end
local function rec(bp, uid) for _, d in ipairs(bp.parts) do if d.uid == uid then return d end end end

-- 4a. a v1 blueprint: pod over a tank over a decoupler over a tank and engine
-- (stacked flush from the registry's own heights)
local function H(id) return REGENV.REG[id].h end
local ys = {}
do
  local y = 0.0
  for i, id in ipairs({ "engineS", "tankS", "decoupler", "tankS", "pod" }) do
    ys[6 - i] = y + H(id) * 0.5
    y = y + H(id)
  end
end
local V1 = { parts = {
  P{ uid = 1, id = "pod", x = 0, y = ys[1], z = 0 },
  P{ uid = 2, id = "tankS", x = 0, y = ys[2], z = 0, parent = 1, att = "bottom" },
  P{ uid = 3, id = "decoupler", x = 0, y = ys[3], z = 0, parent = 2, att = "bottom", stage = 1 },
  P{ uid = 4, id = "tankS", x = 0, y = ys[4], z = 0, parent = 3, att = "bottom" },
  P{ uid = 5, id = "engineS", x = 0, y = ys[5], z = 0, parent = 4, att = "bottom" },
} }
local function copy(t) if type(t) ~= "table" then return t end local o = {} for k, v in pairs(t) do o[k] = copy(v) end return o end
store["shipyard.blueprint"] = copy(V1)
env.start(bnode)
step(2)
check(env.partCount == 5, "v1 blueprint loads (" .. env.partCount .. ")")
check(#env.links(2) == 2 and env.links(2)[1].k == "stack", "v1 parents became stack links")
check(env.root() == 1, "the pod is the root")
env.doSave()
local bp2 = store["shipyard.blueprint"]
check(bp2.v == 2 and type(bp2.links) == "table" and #bp2.links == 4, "saved as v2 with its 4 links")
local same = true
for _, d in ipairs(V1.parts) do
  local r = rec(bp2, d.uid)
  for _, f in ipairs({ "id", "parent", "att", "sym", "stage" }) do
    if not r or r[f] ~= d[f] then same = false end
  end
  if not r or not near(r.y - rec(bp2, 5).y, d.y - ys[5], 1e-3) then same = false end
  for _, f in ipairs({ "h", "mass", "cost", "thrust", "fuel", "strength", "decouple" }) do
    if r and r[f] == nil then same = false end
  end
end
check(same, "v1 → v2 keeps every flight field (parent, att, pose, ratings)")
check(env.separation(3) and #env.separation(3) == 3, "the decoupler throws off itself, the lower tank and the engine")
env.start(bnode) -- reload the v2 one
step(2)
check(env.partCount == 5 and #env.links(3) == 2, "a v2 blueprint reloads with its links")

-- 4b. dependents and the drag: the lower tank carries the engine; the pod carries all
check(table.concat(env.dependents({ 4 }), ",") == "5", "dependents of the lower tank: the engine")
check(#env.dependents({ 1 }) == 4, "dependents of the root: everything")

-- 4c. multi-select: click, SHIFT, CTRL, box, ESC
local function scr(uid) local r = env.partRec(uid); return r.x, r.z end
env.select({}, "set")
at(scr(5)) -- straight down onto the stack: the pod is on top
click()
check(#env.selection() == 1, "a click selects one part (" .. #env.selection() .. ")")
-- a double-click: the assembly up to the decoupler; again: the whole craft
local function quick() MOUSE.lmb = true; step(1); MOUSE.lmb = false; step(3) end
quick(); quick()
local asm = #env.selection()
quick(); quick()
check(asm == 3 and #env.selection() == 5,
  "double-click selects the assembly up to the decoupler (" .. asm .. "), again the craft (" .. #env.selection() .. ")")
step(30)
env.select({ 1 }, "set")
env.select({ 2 }, "add")
env.select({ 4 }, "add")
check(#env.selection() == 3 and env.selectionPrimary() == 4, "select add, primary last")
env.select({ 2 }, "toggle")
check(#env.selection() == 2, "toggle removes")
press("escape")
check(#env.selection() == 0, "ESC clears the selection")
press("escape")
check(scene_loads == 0, "ESC never leaves the VAB")
drag(-3, -3, 3, 3)
check(#env.selection() == 5, "a box over the craft selects all five (" .. #env.selection() .. ")")
env.select({}, "set")

-- 4d. history: delete the engine, undo, redo, undo
local n0 = env.partCount
env.cmd("delete", { uids = { 4 } })
check(env.partCount == n0 - 2, "delete takes the tank and what hangs on it")
env.undoStep()
check(env.partCount == n0 and #env.links(4) == 2, "undo brings both back, linked")
env.redoStep()
check(env.partCount == n0 - 2, "redo deletes again")
env.undoStep()
check(env.partCount == n0, "undo again")
env.cmd("delete", { uids = { 4 }, only = true })
check(env.partCount == n0 - 1 and env.partRec(5) and env.partRec(5).loose, "ALT+DEL takes only the tank; the engine is loose")
env.undoStep()
check(not env.partRec(5).loose, "…undone")

-- 4d2. the offset limit: an engine pulled 3 m off its tank stops the launch
check(env.launchCheck().block == nil, "attached craft launches")
env.cmd("move", { uids = { 5 }, dx = 3 })
local lc = env.launchCheck()
check(lc.block and lc.block:find("not touching") and lc.detached[1] == 5, "a part off its mount blocks LAUNCH")
env.undoStep()
check(env.launchCheck().block == nil, "…moved back, it launches")
env.cmd("move", { uids = { 5 }, dy = -0.01 })
check(env.launchCheck().block == nil, "1 cm of offset still touches")
env.undoStep()

-- 4e. insert: a tank between the decoupler and the lower tank; the far side moves down
local e0 = env.partRec(5).y
local nu = env.cmd("insert", { id = "tankS", host = 3, side = "bottom" })
local h = env.partInfo("tankS").h
check(nu and near(env.partRec(5).y, e0 - h, 1e-6), "insert moves the far side by the new part's height")
check(env.partRec(4).parent == nu and env.partRec(nu).parent == 3, "the joint re-forms through the new tank")
env.undoStep()
check(env.partRec(nu) == nil and near(env.partRec(5).y, e0, 1e-6) and env.partRec(4).parent == 3, "one undo puts it back")

-- 4f. detach keeps poses and cuts links
env.cmd("detach", { uids = { 5 } })
check(#env.links(5) == 0 and env.partRec(5).loose, "detach cuts the engine's links")
env.undoStep()
check(#env.links(5) == 1, "…undone")

-- 4g. drag-move: drag the lower tank off sideways onto the floor; the engine comes along
local t4, t5 = env.partRec(4), env.partRec(5)
env.select({ 4 }, "set")
at(t4.x, t4.z)
-- straight down hits the pod first; select by API then drag from the tank's spot
MOUSE.lmb = true; step(1)
local hov = env.hovered()
for i = 1, 6 do at(t4.x + i, t4.z + 3); step(1) end
local carry = env.held()
MOUSE.lmb = false; step(2)
check(hov ~= nil, "a press over the craft hovers a part")
check(carry ~= nil and #carry >= 1, "dragging a part puts it (and its dependents) in hand")
step(3)
check(env.held() == nil, "release places it")
env.undoStep()
step(1)
check(near(env.partRec(1).x, 0, 1e-6) and env.partRec(2).parent == 1 and env.partRec(4).parent == 3,
  "one undo puts the dragged set back where it was, links and all")
-- hold({uid}) lifts a part with its dependents; ESC drops it back
env.hold({ 4 })
local held = env.held()
check(held and #held == 2, "hold({uid}) lifts the tank and the engine")
press("escape")
check(env.held() == nil and env.partRec(4).parent == 3 and env.partRec(5).parent == 4, "ESC puts them back")

-- 4h. copy, paste, duplicate
env.select({ 4, 5 }, "set")
check(env.copy() == 2, "copy two parts")
local before = env.partCount
check(env.paste() and env.holding() == "paste", "paste puts them in hand")
press("escape")
check(env.partCount == before, "ESC drops a paste without leaving parts behind")
local dup = env.duplicate({ 4, 5 })
check(type(dup) == "table" and #dup == 2 and env.partCount == before + 2, "duplicate adds a copy")
check(#env.links(dup[1]) >= 1, "…with its internal link")
env.undoStep()
check(env.partCount == before, "duplicate is one undo step")

-- 4i. the library and a sub-assembly
check(env.craftSave("Test Mk1"), "save to the library")
check(#env.craftList() == 1 and env.craftList()[1].name == "Test Mk1" and env.craftList()[1].parts == 5, "the library lists it")
env.craftNew()
check(env.partCount == 0, "a new craft clears the stand")
check(env.craftOpen("Test Mk1"), "open it again")
step(2)
check(env.partCount == 5 and #env.links(3) == 2 and env.craftName() == "Test Mk1", "it comes back whole")
check(env.makeSubAssembly("Lower stage", { 3, 4, 5 }), "make a sub-assembly")
check(env.hold("Lower stage") and #env.held() == 3, "a sub-assembly goes in the hand")
press("escape")
check(env.craftOpen("Test Mk1", "merge") and #env.held() == 5, "OPEN ▸ merge puts a saved craft in the hand")
press("escape")
check(env.partCount == 5, "and ESC leaves the stand as it was")

-- 4j. root and outliner groups
env.cmd("root", { uid = 3 })
check(env.root() == 3 and #env.dependents({ 3 }) == 4, "tool 4: the decoupler is the root now")
env.undoStep()
check(env.root() == 1, "…undone")
env.cmd("group", { name = "Lower", uids = { 4, 5 } })
check(env.outliner()[1] and env.outliner()[1].name == "Lower", "an outliner group")
env.doSave()
check(store["shipyard.blueprint"].outliner and store["shipyard.blueprint"].groups == nil,
  "outliner groups save as bp.outliner (bp.groups stays the action groups)")

-- 4j2. the Beam tool (WP3's rulebook): two clicks on the floor draw a member;
--      a second from the floor onto its span makes a tee
if env.attachRules() == "wp3" then
  local n1 = env.partCount
  env.pick("beamP")
  step(12) -- the pick's click cooldown
  check(env.drawingTool() and env.drawingTool().kind == "member", "picking the drawn beam starts the Beam tool")
  at(5, -2); click()
  at(5, 2); click()
  check(env.partCount == n1 + 1, "two clicks draw a member (" .. env.partCount - n1 .. ")")
  local bu
  for _, u in ipairs(env.partUids()) do if env.partRec(u).id == "beamP" then bu = u end end
  local br = bu and env.partRec(bu)
  check(br and br.size and near(br.size.len, 4.0, 1e-6) and near(br.def.h, 4.0, 1e-6),
    "the member is 4 m long and its def says so (sizeOf)")
  -- from the floor at x = 7 to the beam's side (aim straight down past its flank)
  at(7, 0); click()
  at(5.0, 0.0); click()
  local tee = false
  for _, u in ipairs(env.partUids()) do
    local r = env.partRec(u)
    if r.id == "beamP" and u ~= bu then
      for _, l in ipairs(r.links) do if l.a == bu or l.b == bu then tee = l.k end end
    end
  end
  check(tee ~= false, "a member drawn onto another joins it (" .. tostring(tee) .. ")")
  press("escape"); press("escape")
  check(env.drawingTool() == nil, "ESC ends the chain, then the tool")
  env.doSave()
  local rb = rec(store["shipyard.blueprint"], bu)
  check(rb and rb.proc == "member" and rb.size and near(rb.h, 4.0, 1e-6) and rb.mass > 0, "the blueprint carries proc, size and sized figures")
  env.undoStep(); env.undoStep()
  check(env.partCount == n1, "each drawn member is one undo step")
end

-- 4k. CTRL+Q leaves only on a second press
API.KEYS.down.ctrl = true
press("q")
check(scene_loads == 0, "CTRL+Q once only asks")
press("q")
API.KEYS.down.ctrl = false
check(scene_loads == 1, "CTRL+Q twice leaves")

if #failures == 0 then
  print(string.format("BUILDER GRAPH SMOKE OK — %d checks passed", checks))
  os.exit(0)
end
print("BUILDER GRAPH SMOKE FAILURES:")
for _, f in ipairs(failures) do print("  ✗ " .. f) end
os.exit(1)
