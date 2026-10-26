-- CTXPROBE (scratch only): the right-click menus in the real game, for
-- `floptle shot` (tools/perf/ctxshot.sh). One case per run; the probe drives
-- the game to the state, opens the menu the way a player does (a simulated
-- right TAP at the thing's spot on screen: rc10's input.simulate{button=1}),
-- checks what came up, then HOLDS the menu open for the picture.
--
--   case astro    the crew on foot: the suit menu; helmet off and on again
--   case tank     a rocket on the pad (VAB rollout): a tank's menu (health
--                 after wear, its own propellant, the pool)
--   case pump     …the tank's Pump sub-panel, after pumping between tanks
--   case locker   …a stowage locker's contents (read-only)
--   case engine   …the engine's menu
--   case builder  the VAB builder: the part menu with the shared rows
--
-- strs: case; params: slot (13), fresh (1 = make the save new, as the
-- new-save panel does; 0 = continue it), quit (0 holds for the shot).
defaults = { slot = 13, seed = 1911564384, fresh = 0, quit = 0 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("CTX %7.2f g%7.2f " .. fmt, W() - W0, time or 0, ...)) end
local CASE = "astro"
local NODE, CO
local function yield() coroutine.yield() end
local function wait(s)
  local acc, last = 0, time
  while acc < s do yield(); local d = time - last; last = time; if d > 0 and d < 1 then acc = acc + d end end
end
local function wait_for(fn, tmo, what)
  local t = W() + (tmo or 60)
  while true do
    local r = fn()
    if r then return r end
    if W() > t then P("TIMEOUT waiting for %s", what or "?"); return nil end
    yield()
  end
end
local function tap(k) input.simulate { key = k, down = true }; yield(); yield(); input.simulate { key = k, down = false } end

local function world_ready()
  local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
  return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
end

local function boot()
  local s = "slot" .. math.floor(params.slot)
  NODE.persistent = true
  if (params.fresh or 0) > 0 then
    terrain.deleteSaveDir("saves/" .. s .. "/terrain")
    if save.deleteSlot then save.deleteSlot(s) end
    save.slot(s)
    save.set("g_seed", math.floor(params.seed))
    for k, v in pairs({ g_planets = 3, g_moonchance = 0.6, g_atmo = 0.8, g_caves = 1.0, g_minorbit = 60000, g_spacing = 2.2,
                        g_radmin = 600, g_radmax = 950, g_gravmin = 3.5, g_gravmax = 8.5, g_star = 1.0 }) do save.set(k, v) end
    local ns = findScript("menu_newsave")
    save.set("g_scale", math.floor((ns and ns.WORLD_SCALE) or 4))
    P("created %s", s)
  else
    save.slot(s)
    P("continuing %s (seed %s)", s, tostring(save.get("g_seed")))
  end
  scene.load("system")
  yield()
  wait_for(world_ready, 300, "the world")
  P("world ready")
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
end

local function cm() return findScript("context_menu") end

-- A right TAP at a screen pixel, the way a player gives it.
local function rtap(sx, sy)
  input.simulate { mouse = { sx, sy } }
  yield(); yield()
  input.simulate { button = 1, down = true }
  yield(); yield()
  input.simulate { button = 1, down = false }
  yield(); yield(); yield()
end

local function dump(tag)
  local c = cm()
  local list = c and c.entries() or {}
  local out = {}
  local reg = findScript("context_registry")
  for _, e in ipairs(list) do
    local v = reg and reg.live(e.value)
    local u, why = true, nil
    if reg then u, why = reg.usable(e) end
    out[#out + 1] = string.format("%s[%s]%s%s%s", e.id, e.type, e.label ~= "" and (" " .. e.label) or "",
      v and (" = " .. tostring(v)) or "", u and "" or (" (dim: " .. tostring(why) .. ")"))
  end
  P("MENU %s: open %s target %s actor %s | %s", tag, tostring(c and c.isOpen()), tostring(c and c.target and c.target.kind),
    tostring(c and c.actor and c.actor.id), table.concat(out, " ; "))
end

local function open_on(wx, wy, wz, kind, uid, tag)
  local c = cm()
  local sx, sy, _, on = camera.worldToScreen(wx, wy, wz)
  P("%s on screen at %.0f, %.0f (%s)", tag, sx or -1, sy or -1, tostring(on))
  rtap(sx, sy)
  local good = c.isOpen() and c.target and c.target.kind == kind and (uid == nil or c.target.uid == uid)
  P("RESULT %s: a right tap opened %s (%s, uid %s)", tag, good and "PASS" or "FAIL",
    tostring(c.target and c.target.kind), tostring(c.target and c.target.uid))
  if not good then
    -- (fallback so the picture still shows the menu: the pick, then open)
    local t = c.pick(sx, sy)
    if t and t.kind == kind then c.openFor(t, nil, sx, sy) end
  end
  return c.isOpen()
end

-- ── cases ───────────────────────────────────────────────────────────────────
local function astro()
  if not findScript("suit") and spawn then pcall(spawn, "SuitStub", vec3(0, 0, 0)); wait(1) end
  local a = find("Astronaut")
  local pc = findScript("planet_camera")
  wait(3)
  local up = a.up or vec3(0, 1, 0)
  open_on(a.worldX + up.x * 0.3, a.worldY + up.y * 0.3, a.worldZ + up.z * 0.3, "astro", nil, "astro")
  dump("astro")
  local c = cm()
  local s = findScript("suit")
  local before = s and s.helmetOn()
  local ok1 = c.press("helmet")
  wait(2.0)
  local mid = s and s.helmetOn()
  dump("after-remove")
  local ok2 = c.press("helmet")
  wait(2.0)
  local after = s and s.helmetOn()
  P("RESULT helmet: %s (on %s → %s → %s; presses %s %s)", (before == true and mid == false and after == true) and "PASS" or "FAIL",
    tostring(before), tostring(mid), tostring(after), tostring(ok1), tostring(ok2))
  c.press("helmet")  -- off again, for the picture: the row then offers "Put on helmet"
  wait(2.0)
  dump("hold")
end

local function rocket()
  local l, y, u = {}, 0, 0
  local function add(id, h, st)
    u = u + 1
    l[#l + 1] = { uid = u, id = id, x = 0, y = y + h / 2, z = 0, yaw = 0, pitch = 0, roll = 0,
                  parent = u > 1 and u - 1 or 0, att = u > 1 and "top" or "", sym = 0, mir = "", stage = st or 0 }
    y = y + h
  end
  add("engineM", 1.6); add("tankM", 1.5); add("tankS", 1.0); add("locker", 0.5); add("pod", 0.8); add("chute", 0.34, 1)
  return l
end

local function launch()
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  local vab = wait_for(function() return find("VabInterior") end, 150, "the VAB")
  local a = find("Astronaut")
  local p = vab:toWorld(vec3(0, 1.4, 14))
  a.x, a.y, a.z = p.x, p.y, p.z
  a.vx, a.vy, a.vz = 0, 0, 0
  wait(2.5)
  tap("e")
  local BH = wait_for(function() local bh = findScript("build_host"); return bh and bh.state == "building" and bh end, 20, "the builder")
  if not BH then local fm = findScript("facility_menu"); if fm then fm.openMenu("FacHangar"); fm.action() end
    BH = wait_for(function() local bh = findScript("build_host"); return bh and bh.state == "building" and bh end, 30, "the builder (menu)") end
  local B = findScript("builder")
  wait(1)
  local bp = rocket()
  save.set("shipyard.blueprint", { parts = bp })
  B.reload()
  wait_for(function() return not (B.loadProgress and B.loadProgress()) and (B.partCount or 0) >= #bp end, 60, "the blueprint")
  P("builder: %d parts", B.partCount or -1)
  return B, BH, bp
end

local function builder_case()
  local B = launch()
  wait(2)
  local bc = findScript("builder_context")
  -- the tank (uid 2 in the blueprint → the builder's own uid)
  local uid = nil
  for _, u in ipairs(B.partUids()) do local r = B.partRec(u); if r and r.id == "tankM" then uid = u end end
  local ok = bc and uid and bc.openFor(uid, 560, 260)
  local list = bc and bc.sharedEntries and bc.sharedEntries(B, uid) or {}
  local reg = findScript("context_registry")
  local out = {}
  for _, e in ipairs(list) do out[#out + 1] = e.id .. "=" .. tostring(reg and reg.live(e.value)) end
  P("RESULT builder: %s menu on uid %s; shared rows: %s", (ok and #list > 3) and "PASS" or "FAIL", tostring(uid), table.concat(out, " ; "))
end

local function flight_case()
  local B, BH, bp = launch()
  if B.launchSite and B.launchSite() ~= "pad" and B.toggleLaunchSite then B.toggleLaunchSite() end
  B.doLaunch()
  wait(0.6)
  if BH.state == "building" then B.doLaunch() end
  local vc = wait_for(function()
    for _, v in ipairs(findScripts("vessel_controller")) do
      if v.piloting and v.node and v.node.valid then
        local i = assembly.info(v.node)
        if i and #i.parts >= #bp then return v end
      end
    end
  end, 200, "the craft on the pad")
  if not vc then return end
  wait_for(function() local bf = findScript("base_facilities"); return bf and bf.sited and not (bf.grading and bf.grading()) end, 150, "the regrade")
  wait(4)
  P("craft: %s, patched API %s %s %s", tostring(vc.craftName), tostring(vc.partHp ~= nil), tostring(vc.tankTransfer ~= nil), tostring(vc.lockerOf ~= nil))
  -- uids by part id
  local by = {}
  for u, d in pairs(vc.aboardRecs()) do by[d.id] = u end
  local inv = findScript("inventory")
  local cid = vc.lockerOf and vc.lockerOf(by.locker)
  if cid then inv.add(cid, "iron", 6); inv.add(cid, "copper", 3); vc.holdApplyMass(vc.node) end
  P("locker %s: %s", tostring(cid), cid and inv.line(cid) or "-")
  if vc.wearPart then vc.wearPart(by.tankM, 0.55) end
  local function at(id)
    local d = vc.aboardRecs()[by[id]]
    return vc.node:toWorld(vec3(d.x, d.y, d.z))
  end
  -- the chase camera: a little time to settle on the stack
  wait(2)
  local c = cm()
  if CASE == "tank" or CASE == "pump" then
    local p = at("tankM")
    open_on(p.x, p.y, p.z, "part", by.tankM, CASE)
    dump("tank")
    if CASE == "pump" then
      -- off the clamps (the pad tops the tanks up while clamped), and 60 u
      -- burnt from the bottom tank, as a flight would have
      if vc.releaseClamps then vc.releaseClamps() end
      wait(1)
      vc.fuelDraw(60)
      wait(0.3)
      c.press("pump")
      wait(0.3)
      local s0, m0 = vc.tankLeft(by.tankS), vc.tankLeft(by.tankM)
      local okp = c.press("in" .. by.tankS)
      wait(0.3)
      local s1, m1 = vc.tankLeft(by.tankS), vc.tankLeft(by.tankM)
      P("RESULT pump: %s (FT-S %.1f → %.1f, FT-M %.1f → %.1f, pool %.1f)", (okp and s1 < s0 and m1 > m0 and math.abs((s0 + m0) - (s1 + m1)) < 0.01) and "PASS" or "FAIL",
        s0 or -1, s1 or -1, m0 or -1, m1 or -1, vc.fuel or -1)
      dump("pump")
    end
  elseif CASE == "locker" then
    local p = at("locker")
    open_on(p.x, p.y, p.z, "part", by.locker, "locker")
    dump("locker")
    c.press("open")
    wait(0.3)
    dump("locker-contents")
    local list = c.entries()
    local n = 0
    for _, e in ipairs(list) do if e.id:match("c_mat_") then n = n + 1 end end
    P("RESULT locker: %s (%d stacks listed)", n == 2 and "PASS" or "FAIL", n)
  elseif CASE == "engine" then
    local p = at("engineM")
    open_on(p.x, p.y, p.z, "part", by.engineM, "engine")
    dump("engine")
  end
end

local MAIN = function()
  boot()
  wait(4)
  if CASE == "astro" then astro()
  elseif CASE == "builder" then builder_case()
  else flight_case() end
  P("HOLD")
  if (params.quit or 0) > 0 then app.quit() end
  while true do
    -- keep the menu up for the picture (a wandering pointer must not close it)
    yield()
  end
end

function update(node, dt)
  if not CO then
    NODE = node
    CASE = params.case or "astro"
    CO = coroutine.create(MAIN)
  end
  if coroutine.status(CO) ~= "dead" then
    local ok, err = coroutine.resume(CO)
    if not ok then P("ERROR %s", tostring(err)) end
  end
end
