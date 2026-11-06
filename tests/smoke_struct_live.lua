-- SMOKE: live placed parts (sandbox plan S2 §2; docs/base-building.md §13),
-- on stub engines: struct_live's structure vessel and kit_live's doors,
-- lights and screens.
--
--   * struct_live.blueprintOf: a structure with a cockpit, a locker, a light
--     and walls is ONE vessel blueprint of the three live parts, the cockpit
--     its root (the crewed part), the others hung off it, in the structure's
--     frame (a part's y is its centre: the ground point plus its seat), the
--     modules the electronics rulebook derives, a saved locker number carried;
--     a wall is never in it; the signature changes when a live part moves or
--     is added, not when a wall is; no live part, no vessel;
--   * struct_live in a stub scene: a vessel spawned once with the handoff's
--     `held` and `structure`, its parts adopted by the structure (partOfNode),
--     anchored, pinned body-relative as the planet moves; adding a wall
--     rebuilds nothing; adding a locker rebuilds it once; taking the last live
--     part away drops it;
--   * kit_live: a door slides open with the crew near and shuts behind them
--     (its node in its parent's frame); a light's on/off is its part state,
--     the pool lights the nearest and gives the rest their slot back, a
--     switch plate's "all lights" switches them; a screen's lines read the
--     base grid.
--
--   luajit solar/tests/smoke_struct_live.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, e) return math.abs(a - b) <= (e or 1e-6) end

local function env(store, scripts, extra)
  local E = setmetatable({
    time = 5.0,
    save = {
      get = function(k) return store[k] end,
      set = function(k, v) store[k] = v end,
      delete = function(k) local had = store[k] ~= nil; store[k] = nil; return had end,
    },
    findScript = function(k) return scripts[k] end,
    findScripts = function(k) return {} end,
    find = function() return nil end,
    log = function() end,
  }, { __index = _G })
  for k, v in pairs(extra or {}) do E[k] = v end
  return E
end
local function load_script(path, E)
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, E)
  f()
  E.params = {}
  for k, v in pairs(E.defaults or {}) do E.params[k] = v end
  return E
end

local S = {}
S.parts_kit = load_script("parts_kit.lua", env({}, S))
S.parts_base = load_script("parts_base.lua", env({}, S))
S.kit_snap = load_script("kit_snap.lua", env({}, S))
S.electronics = load_script("electronics.lua", env({}, S))
local defs = function(id) return S.parts_base.partInfo(id) end
local SL = load_script("struct_live.lua", env({}, S))

local function P(uid, id, x, y, z, yaw, pitch) return { uid = uid, id = id, x = x, y = y, z = z, yaw = yaw or 0, pitch = pitch or 0, roll = 0 } end
local rec = { id = 3, b = "Home", x = 10, y = 600, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1, n = "Outpost hab",
  bp = { P(1, "floor.steel", 0, 0, 0), P(2, "wall.steel", 0, 0.2, 1), P(3, "vab.cockpit", 0, 0.2, 0, 0, math.pi / 2),
         P(4, "vab.locker", 0.6, 0.2, -0.6), P(5, "vab.light", 0, 2.2, 0, 0, math.pi) } }

-- ── the blueprint ───────────────────────────────────────────────────────────
local bp = SL.blueprintOf(rec, defs, { [4] = { locker = 17 } }, S.electronics)
check(bp and #bp.parts == 3, "three live parts: the walls and the floor stay static")
local by = {}
for _, d in ipairs(bp and bp.parts or {}) do by[d.uid] = d end
check(bp and bp.root == 3 and by[3].parent == 0 and by[4].parent == 3 and by[5].parent == 3, "the cockpit is the root, the rest hang off it")
check(by[3] and by[3].prefab == "PartCockpit" and by[3].id == "cockpit" and by[3].kind == "crewed", "the cockpit's record is the registry's")
check(by[3] and near(by[3].y, 0.2 + 0.5) and near(by[3].pitch, math.pi / 2), "the cockpit lies on its belly, its centre 0.5 m over the floor")
check(by[4] and near(by[4].x, 0.6) and near(by[4].y, 0.2 + 0.25) and near(by[4].z, -0.6) and by[4].store == 80, "the locker stands on the floor; its 80 kg store")
check(by[4] and by[4].st and by[4].st.locker == 17, "the locker keeps the number it had (its contents with it)")
local cm = by[3] and by[3].mods
local hasCmd, hasBat = false, false
for _, m in ipairs(type(cm) == "table" and cm or {}) do if m.type == "command" then hasCmd = true end if m.type == "battery" then hasBat = true end end
check(hasCmd and hasBat, "the cockpit's modules: command and battery")
local lm = by[5] and by[5].mods
check(type(lm) == "table" and lm[1] and lm[1].type == "light", "the floodlight's light module")
check(bp.name == "Outpost hab", "named for its structure")
-- (S2 follow-up) COUNTED ONCE: a battery, a panel, a cell placed live are the
-- base grid's (by record), so the vessel carries them without those modules;
-- the floodlight's and the cockpit's draws are grid loads, so draw 0 here
do
  local r2 = { id = 4, b = "Home", x = 0, y = 600, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1,
    bp = { P(1, "vab.cockpit", 0, 0.2, 0, 0, math.pi / 2), P(2, "vab.battery", 1, 0.2, 0), P(3, "vab.solar", 2, 0.2, 0),
           P(4, "vab.rtg", 3, 0.2, 0), P(5, "vab.light", 0, 2.2, 0, 0, math.pi) } }
  local b2 = SL.blueprintOf(r2, defs, nil, S.electronics)
  local by2 = {}
  for _, d in ipairs(b2 and b2.parts or {}) do by2[d.uid] = d end
  local function has(d, ty) for _, m in ipairs(type(d and d.mods) == "table" and d.mods or {}) do if m.type == ty then return m end end return nil end
  check(by2[2] and not has(by2[2], "battery") and by2[2].ec == 0 and by2[2].power == 0, "a battery placed live: the grid's 150 EC, not the vessel's too")
  check(by2[3] and not has(by2[3], "solar") and has(by2[3], "deploy") and by2[3].gen == 0, "a panel placed live: the grid's output; it still unfolds")
  check(by2[4] and not has(by2[4], "rtg"), "an isotope cell placed live: the grid's")
  check(by2[5] and has(by2[5], "light") and (has(by2[5], "light").draw or 0) == 0, "the floodlight switches in the vessel, its 0.2 EC/s drawn on the grid")
  local cmd = has(by2[1], "command")
  check(cmd and (cmd.draw or 0) == 0 and has(by2[1], "battery"), "the cockpit's command draw is the grid's; its own cell stays (kept topped up)")
  local nb = 0
  for _, id in ipairs({ "vab.battery", "vab.solar", "vab.rtg", "vab.light", "vab.cockpit" }) do if defs(id).power then nb = nb + 1 end end
  check(nb == 5, "each of them is on the grid by its record (parts_kit.LIVE_POWER)")
end
local sig = SL.signatureOf(rec, defs)
rec.bp[#rec.bp + 1] = P(6, "wall.steel", 1, 0.2, 0, math.pi / 2)
check(SL.signatureOf(rec, defs) == sig, "a wall added: the live parts are the same")
rec.bp[4].x = 0.1
check(SL.signatureOf(rec, defs) ~= sig, "a live part moved: a rebuild")
rec.bp[4].x = 0.6
check(SL.blueprintOf({ bp = { P(1, "floor.steel", 0, 0, 0) } }, defs, nil, S.electronics) == nil, "no live part, no vessel")

-- ── the scene half on a stub engine ─────────────────────────────────────────
do
  local store = {}
  local SS = {}
  for k, v in pairs(S) do SS[k] = v end
  local planet = { x = 0, y = 0, z = 0 }
  local spawned, destroyed, teleports, anchored = {}, 0, {}, {}
  local nid = 100
  local function node(name)
    nid = nid + 1
    local n = { id = nid, name = name, valid = true, x = 0, y = 0, z = 0, tags = {} }
    function n:destroy() self.valid = false; destroyed = destroyed + 1 end
    function n:setUp() end
    function n:setAngles(y, p, r) self.ang = { y, p, r } end
    function n:addTag(t) self.tags[t] = true end
    return n
  end
  local ast = node("Astronaut")
  ast.x, ast.y, ast.z = 10, 602, 3
  local assembly = {
    rebuild = function() end,
    setAnchored = function(v, on) anchored[v.id] = on end,
    info = function(v) return { anchored = anchored[v.id] == true } end,
    teleport = function(v, p) teleports[#teleports + 1] = { x = p.x, y = p.y, z = p.z } end,
  }
  local E = env(store, SS, {
    space = { body = function() return planet end, dominant = function() return "Home" end },
    vec3 = function(x, y, z) return { x = x, y = y, z = z } end,
    find = function(n) if n == "Astronaut" then return ast end return nil end,
    spawn = function(prefab, pos, cb, parent)
      local n = node(prefab)
      spawned[#spawned + 1] = { prefab = prefab, node = n, parent = parent }
      cb(n)
    end,
    assembly = assembly,
  })
  -- a structure store with the record above, spawned
  local STE = env(store, SS)
  local ST = load_script("structures.lua", STE)
  SS.structures = ST
  rec.bp[6] = nil
  ST.add(rec)
  ST.isLive = function(id) return id == rec.id end
  local SLs = load_script("struct_live.lua", E)
  SS.struct_live = SLs
  SLs.update(nil, 0.02)
  local vessels, parts = 0, 0
  local vnode
  for _, s in ipairs(spawned) do
    if s.prefab == "Vessel" then vessels = vessels + 1; vnode = s.node elseif s.parent == vnode then parts = parts + 1 end
  end
  check(vessels == 1 and parts == 3, string.format("one vessel, three parts under it (%d, %d)", vessels, parts))
  local ho = vnode and store["dock.handoff." .. vnode.id]
  check(ho and ho.held == true and ho.structure == rec.id and ho.flown == false and #ho.parts == 3, "the handoff: held, in structure mode, never flown")
  check(vnode and anchored[vnode.id] == true, "anchored once every part landed")
  local cockpit_node
  for _, s in ipairs(spawned) do if s.prefab == "PartCockpit" then cockpit_node = s.node end end
  local r2, p2 = ST.partOfNode(cockpit_node)
  check(r2 and r2.id == rec.id and p2 and p2.uid == 3, "the cockpit's node is its structure's part (Deconstruct finds it)")
  check(cockpit_node and cockpit_node.tags.craftpart and near(cockpit_node.ang[2], math.pi / 2), "a craft part, turned as placed")
  -- the pin: the planet moved
  planet.x = 50
  time = 6.0; E.time = 6.0
  SLs.update(nil, 0.02)
  local last = teleports[#teleports]
  check(last and near(last.x, 50 + 10) and near(last.y, 600), "held on its structure as the planet moves (body-relative)")
  -- a wall: nothing rebuilt
  local before = #spawned
  ST.addPart(rec.id, P(nil, "wall.steel", -1, 0.2, 0, math.pi / 2))
  E.time = 7.5
  SLs.update(nil, 0.02)
  check(#spawned == before, "a wall placed: nothing live rebuilt")
  -- a second locker: one rebuild
  ST.addPart(rec.id, P(nil, "vab.lockerS", -0.6, 0.2, -0.6))
  E.time = 9.0
  SLs.update(nil, 0.02)
  local v2 = 0
  for i = before + 1, #spawned do if spawned[i].prefab == "Vessel" then v2 = v2 + 1 end end
  check(v2 == 1 and not vnode.valid, "a locker placed: the old vessel goes, one new one with it")
  -- the live parts taken away: no vessel
  local uids = {}
  for _, p in ipairs(ST.get(rec.id).bp) do if defs(p.id).live then uids[#uids + 1] = p.uid end end
  ST.removeParts(rec.id, uids)
  E.time = 11.0
  SLs.update(nil, 0.02)
  check(next(SLs.vessels()) == nil, "the last live part down: the vessel goes")
end

-- ── kit_live ────────────────────────────────────────────────────────────────
do
  local store = {}
  local SS = {}
  for k, v in pairs(S) do SS[k] = v end
  local STE = env(store, SS)
  local ST = load_script("structures.lua", STE)
  SS.structures = ST
  local r = { id = 9, b = "Home", x = 0, y = 0, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1,
              bp = { P(1, "floor.steel", 0, 0, 0), P(2, "doorWall.steel", 0, 0.2, 1), P(3, "lightFitting.steel", 0, 2.4, 0, 0, math.pi),
                     P(4, "lightFitting.steel", 0, 2.4, 2, 0, math.pi), P(5, "switchPlate.steel", 0.5, 1.2, 0.9, math.pi, math.pi / 2),
                     P(6, "wallScreen.steel", -0.5, 1.5, 0.9, math.pi, math.pi / 2) } }
  ST.add(r)
  local lights = {}
  local function mk(name, x, y, z)
    local n = { name = name, valid = true, x = x, y = y, z = z, worldPos = { x = x, y = y, z = z }, kids = {} }
    function n:getChild(k) return self.kids[k] end
    function n:children() local o = {}; for _, c in pairs(self.kids) do o[#o + 1] = c end return o end
    function n:toLocal(v) return { x = v.x - self.x, y = v.y - self.y, z = v.z - self.z } end
    function n:setPointLight(t) lights[self] = t.intensity == nil and (lights[self] or 0) or t.intensity end
    function n:setTint() end
    return n
  end
  local ast = mk("Astronaut", 0, 1.1, 6)
  local E = env(store, SS, { find = function(n) if n == "Astronaut" then return ast end end,
    vec3 = function(x, y, z) return { x = x, y = y, z = z } end })
  local KL = load_script("kit_live.lua", E)
  SS.kit_live = KL
  -- the door wall's node (its root at its ground point) and its leaf
  local wallN = mk("KitDoorWall_steel", 0, 0.2, 1)
  local leaf = mk("Door", -0.46, 1.025, 0)
  wallN.kids.Door = leaf
  KL.spawned(r, r.bp[2], wallN)
  local l1, l2 = mk("KitLightFitting_steel", 0, 2.4, 0), mk("KitLightFitting_steel", 0, 2.4, 2)
  l1.kids.Light, l2.kids.Light = mk("Light", 0, 2.2, 0), mk("Light", 0, 2.2, 2)
  l1.kids.Light.worldPos = { x = 0, y = 2.2, z = 0 }; l2.kids.Light.worldPos = { x = 0, y = 2.2, z = 30 }
  KL.spawned(r, r.bp[3], l1); KL.spawned(r, r.bp[4], l2)
  KL.spawned(r, r.bp[5], mk("KitSwitchPlate_steel", 0.5, 1.2, 0.9))
  -- far: shut
  for _ = 1, 30 do E.time = E.time + 0.05; KL.update(nil, 0.05) end
  check(near(KL.doorOpen(9, 2), 0) and near(leaf.x, -0.46), "the crew 5 m off: the door stays shut")
  -- near: open, slid along its frame's +X
  ast.x, ast.y, ast.z = -0.3, 1.2, 2.2
  for _ = 1, 40 do E.time = E.time + 0.05; KL.update(nil, 0.05) end
  check(near(KL.doorOpen(9, 2), 1) and near(leaf.x, -0.46 + 0.92) and near(leaf.y, 1.025), "the crew at the door: it slides open into its pocket")
  ast.x, ast.y, ast.z = 0, 1.1, 8
  for _ = 1, 40 do E.time = E.time + 0.05; KL.update(nil, 0.05) end
  check(near(KL.doorOpen(9, 2), 0) and near(leaf.x, -0.46), "and shuts behind them")
  -- lights: on by default, pooled by distance
  ast.x, ast.y, ast.z = 0, 1.1, 0
  E.time = E.time + 1; KL.update(nil, 0.05)
  check((lights[l1.kids.Light] or 0) > 0 and (lights[l2.kids.Light] or 0) > 0, "both lights on, both in the pool (within reach)")
  KL.setLight(9, 3, false)
  E.time = E.time + 1; KL.update(nil, 0.05)
  check(lights[l1.kids.Light] == 0 and ST.partState(9, 3) and ST.partState(9, 3).off == true, "switched off: its state saved, its slot given back")
  check(KL.setLights(9, true) == 2, "the switch plate: every light of the structure")
  E.time = E.time + 1; KL.update(nil, 0.05)
  check((lights[l1.kids.Light] or 0) > 0 and (ST.partState(9, 3) == nil or not ST.partState(9, 3).off), "all back on")
  local oldPool = KL.POOL
  E.POOL = 1
  E.time = E.time + 1; KL.update(nil, 0.05)
  check((lights[l1.kids.Light] or 0) > 0 and lights[l2.kids.Light] == 0, "a pool of one: the nearer lit, the farther gives its slot back")
  E.POOL = oldPool
  -- the menu
  local rows = KL.providerFn({ node = l1 }, {})
  check(type(rows) == "table", "the light's menu answers")
  -- the screen's lines: no grid
  local L = KL.screenLines(9)
  check(L.lines[1][1] == "NO BASE GRID" and L.lines[1][2] == true, "off any grid the screen says so")
  SS.base_grid = { gridOfStruct = function() return { id = "g1" } end,
                   status = function() return { supply = 3.0, stored = 1000, short = 0 } end,
                   model = function() return { need = 2.06, C = 4000, base = 0 } end,
                   nightLeft = function() return 7200 end }
  L = KL.screenLines(9)
  check(L.lines[1][1]:find("GRID IN", 1, true) and L.lines[3][1]:find("25 %%", 1, false), "on a grid: in, out, the battery at 25 %")
end

if #failures > 0 then
  print("FAIL smoke_struct_live: " .. #failures .. " of " .. (#failures + passed))
  for _, m in ipairs(failures) do print("  - " .. m) end
  os.exit(1)
end
print(string.format("smoke_struct_live: %d checks passed", passed))
