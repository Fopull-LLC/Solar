-- MEDKITPROBE: DOWNED and the MEDKIT in the real game, on a NEW Career save
-- with Permadeath (tools/perf/medkitshots.sh; scripts/crew.lua, items.lua,
-- item_hand.lua, crew_body.lua, context_providers.lua).
--
--   1. the depot: the Medkit on the BUY counter, three bought into #2's pack
--      ($150 each, 1.5 kg)
--   2. #1 (the avatar) dropped to land at ~26 m/s (past the 20 m/s that
--      kills, under 1.6×): DOWN, lying where they fell, control passes to
--      #2 (on foot nearby), the HUD's "DOWN · BLEEDING OUT" chip
--   3. #2 walks over, Medkit in hand: the right-click rows ("Use Medkit"),
--      the revive (6 s held; the bleed-out clock stops) → #1 up at 25 %
--   4. a second Medkit on #1, injured: +50 % → 75 %
--   5. #3 shot down (not overkill) and left: bleeds out at the timer — dead,
--      "bled out after a shot …" on the memorial
--   6. an explosion: dead outright, never down
--
-- Pictures (1280×720) to user://medkitshots/, lines "MKP ", one RESULT a check.
defaults = { quit = 1, slot = 18, seed = 5150, scale = 4, fall_v = 26 }

local W = function() return app.wallClock and app.wallClock() or os.clock() end
local W0 = W()
local function P(fmt, ...) print(string.format("MKP %7.2f " .. fmt, W() - W0, ...)) end
local NODE, CO, pending = nil, nil, 0
local FAILS = 0
local function yield() coroutine.yield() end
local function wait_for(fn, tmo, what)
  local t = W() + (tmo or 60)
  while W() < t do local r = fn(); if r then return r end; yield() end
  P("TIMEOUT %s", what or "?")
end
local function hold(secs)
  local acc, last = 0, time
  while acc < secs do
    yield()
    local d = time - last
    last = time
    if d > 0 and d < 1 then acc = acc + d end
  end
end
local function frames(n) for _ = 1, n do yield() end end
local function R(name, ok, fmt, ...)
  if not ok then FAILS = FAILS + 1 end
  P("RESULT %s: %s " .. (fmt or ""), name, ok and "PASS" or "FAIL", ...)
end
local function shot(name)
  pending = pending + 1
  local ok, err = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes, why)
    pending = pending - 1
    if bytes then assets.writeBytes("user://medkitshots/" .. name .. ".png", bytes); P("SHOT %s", name)
    else P("SHOT %s failed %s", name, tostring(why)) end
  end)
  if not ok then pending = pending - 1; P("capture error %s", tostring(err)) end
end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function home() local n = save.get("base.body"); return n and space.body(n) end
local function unit(a) local l = len(a.x, a.y, a.z); return { x = a.x / l, y = a.y / l, z = a.z / l } end
local function cross(a, b) return { x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x } end
local function ground_r(b, ux, uy, uz, from)
  local r = from
  for _ = 1, 400 do
    local d = terrain.query(b.x + ux * r, b.y + uy * r, b.z + uz * r)
    if not d then return nil end
    if d < 0.05 then return r end
    r = r - math.max(d * 0.8, 0.1)
  end
  return r
end
local function spot(d, ang)
  local b = home()
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  local R0 = len(bx, by, bz)
  local u = { x = bx / R0, y = by / R0, z = bz / R0 }
  local a = math.abs(u.y) > 0.9 and { x = 1, y = 0, z = 0 } or { x = 0, y = 1, z = 0 }
  local t1 = unit(cross(u, a))
  local t2 = unit(cross(u, t1))
  local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang),
                   z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
  local k = d / R0
  local dir = unit({ x = u.x * math.cos(k) + t.x * math.sin(k), y = u.y * math.cos(k) + t.y * math.sin(k),
                     z = u.z * math.cos(k) + t.z * math.sin(k) })
  local gr = ground_r(b, dir.x, dir.y, dir.z, R0 + 150)
  return gr and { dir = dir, r = gr } or nil
end
local function at(s, h)
  local b = home()
  return b.x + s.dir.x * (s.r + h), b.y + s.dir.y * (s.r + h), b.z + s.dir.z * (s.r + h)
end
-- the camera on a point, from the avatar's eye
local function face(tx, ty, tz)
  local cam = findScript("planet_camera")
  local a = find("Astronaut")
  local b = home()
  local u = unit({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z })
  local ex, ey, ez = a.x + u.x * 1.5, a.y + u.y * 1.5, a.z + u.z * 1.5
  local dx, dy, dz = tx - ex, ty - ey, tz - ez
  local v = dx * u.x + dy * u.y + dz * u.z
  local hx, hy, hz = dx - u.x * v, dy - u.y * v, dz - u.z * v
  local hl = len(hx, hy, hz)
  if cam and cam.face and hl > 1e-3 then cam.face(hx / hl, hy / hl, hz / hl, -0.18) end
end

local function boot()
  local s = "slot" .. math.floor(params.slot)
  NODE.persistent = true
  terrain.deleteSaveDir("saves/" .. s .. "/terrain")
  if save.deleteSlot then save.deleteSlot(s) end
  save.slot(s)
  save.set("g_seed", math.floor(params.seed))
  for k, v in pairs({ g_planets = 3, g_moonchance = 0.6, g_atmo = 0.8, g_caves = 1.0, g_minorbit = 60000, g_spacing = 2.2,
                      g_radmin = 600, g_radmax = 950, g_gravmin = 3.5, g_gravmax = 8.5, g_star = 1.0 }) do save.set(k, v) end
  save.set("g_scale", math.floor(params.scale))
  save.set("game.mode", "career")
  save.set("crew.safety", "death")
  save.set("crew.death", true)
  scene.load("system")
  yield()
  wait_for(function()
    local pw, gm, bf = findScript("planet_walker"), findScript("game_manager"), findScript("base_facilities")
    return pw and gm and bf and bf.sited and not gm.loading and not gm.curtain and not (bf.grading and bf.grading())
  end, 240, "the reveal")
  local wx = findScript("weather")
  if wx and wx.force then wx.force("clear") end
end

local function main()
  boot()
  hold(3.0)
  local C, inv, H, co, I = findScript("crew"), findScript("inventory"), findScript("item_hand"), findScript("company"), findScript("items")
  local cam = findScript("planet_camera")
  R("safety", C.safety() == "death" and not co.isSandbox(), "safety %s mode %s", C.safety(), tostring(save.get("game.mode")))
  -- 1. the depot
  co.earn(3000, "probe")
  local listed = nil
  for _, e in ipairs(inv.shopList()) do if e.id == "medkit" then listed = e end end
  local dep = find("FacDepot")
  local a = find("Astronaut")
  local ip = findScript("inventory_panel")
  if dep and ip then
    -- to the counter: 11 m out from the depot, on the side away from the
    -- base's middle, on the ground
    local b = home()
    local dw = dep.worldPos or vec3(dep.worldX, dep.worldY, dep.worldZ)
    local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
    local u = unit({ x = dw.x - b.x, y = dw.y - b.y, z = dw.z - b.z })
    local o = { x = dw.x - (b.x + bx), y = dw.y - (b.y + by), z = dw.z - (b.z + bz) }
    local d0 = o.x * u.x + o.y * u.y + o.z * u.z
    local t = unit({ x = o.x - u.x * d0, y = o.y - u.y * d0, z = o.z - u.z * d0 })
    local px, py, pz = dw.x + t.x * 11, dw.y + t.y * 11, dw.z + t.z * 11
    local pu = unit({ x = px - b.x, y = py - b.y, z = pz - b.z })
    local gr = ground_r(b, pu.x, pu.y, pu.z, len(px - b.x, py - b.y, pz - b.z) + 30)
    if gr then
      a.x, a.y, a.z = b.x + pu.x * (gr + 1.1), b.y + pu.y * (gr + 1.1), b.z + pu.z * (gr + 1.1)
      a.vx, a.vy, a.vz = 0, 0, 0
      C.quietMonitors(1.0)
      hold(1.0)
      face(dw.x, dw.y, dw.z)
      hold(0.5)
    end
    P("at the depot: %.1f m (counter reach)", a:distanceTo(dep))
    ip.openCounters("buy")
    hold(1.2)
    shot("depot_buy")
    frames(3)
    ip.open = false
  end
  local b0 = co.balance()
  local ok2, why2 = inv.buyItem("crew:2", "medkit", 3)
  local b1 = co.balance()
  R("depot", listed and listed.cost == 150 and ok2 and b0 - b1 == 450 and inv.itemCount("crew:2", "medkit") == 3,
    "listed %s at $%s; 3 bought into #2's pack: %s (%s), $%d → $%d; #2 has %d", tostring(listed ~= nil),
    tostring(listed and listed.cost), tostring(ok2), tostring(why2), b0, b1, inv.itemCount("crew:2", "medkit"))
  -- 2. #2 set down on foot 6 m from where #1 will land; #1 dropped
  local S = spot(150, 2.2)
  local S2 = spot(156, 2.2)
  if not (S and S2) then R("spots", false, "no ground"); return end
  local x2, y2, z2 = at(S2, 1.05)
  C.setDown(2, x2, y2, z2)
  wait_for(function() local n = C.bodyOf(2); return n and n.valid ~= false end, 10, "#2's body")
  local hb = home()
  local g = hb.mu / (S.r * S.r)
  local h = params.fall_v * params.fall_v / (2 * g)
  P("g %.2f: a %.0f m/s landing is a %.1f m drop", g, params.fall_v, h)
  a = find("Astronaut")
  a.x, a.y, a.z = at(S, 1.05 + h)
  a.vx, a.vy, a.vz = 0, 0, 0
  C.quietMonitors(0.3)   -- (a teleport, as the game's own make it: not part of the fall)
  local id1 = C.activeId()
  local pw = findScript("planet_walker")
  local tl = W()
  local down = wait_for(function()
    local r = C.get(id1)
    if W() - tl > 0.1 and not (r and r.downed) then
      tl = W()
      local b = home()
      local u = unit({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z })
      local m = C._debug().mon
      P("FALL vr %.1f grounded %s onFoot %s air %.2f peak %.1f hp %.2f", -(a.vx * u.x + a.vy * u.y + a.vz * u.z),
        tostring(pw.grounded), tostring(pw.onFoot), m.air or -1, m.peak or -1, r and r.hp or -1)
    end
    return r and r.downed and r end, 20, "#1 down")
  local r1 = C.get(id1)
  R("down", down ~= nil and r1.status == "afoot" and r1.hp == 0, "#%d: %s; downed %s s (cause %s %s); lastDown %s",
    id1, tostring(r1.status), down and string.format("%.0f", down.downed.secs) or "-", tostring(down and down.downed.cause),
    tostring(down and down.downed.detail), tostring(C.lastDown and C.lastDown.name))
  wait_for(function() return C.activeId() ~= id1 end, 10, "the handoff")
  hold(1.5)
  local medic = C.activeId()
  R("handoff", medic == 2 and select(1, C.control(id1)) == false, "control → #%s; control(#1): %s",
    tostring(medic), tostring(select(2, C.control(id1))))
  -- the downed body and the chip
  local body = C.bodyOf(id1)
  a = find("Astronaut")
  if body then
    local b = home()
    local u = unit({ x = body.x - b.x, y = body.y - b.y, z = body.z - b.z })
    local side = unit(cross(u, math.abs(u.y) > 0.9 and { x = 1, y = 0, z = 0 } or { x = 0, y = 1, z = 0 }))
    a.x, a.y, a.z = body.x - side.x * 4 + u.x * 0.9, body.y - side.y * 4 + u.y * 0.9, body.z - side.z * 4 + u.z * 0.9
    a.vx, a.vy, a.vz = 0, 0, 0
    C.quietMonitors(1.0)
    hold(0.6)
    face(body.x, body.y, body.z)
  end
  hold(1.0)
  if body then
    local m = nil
    for _, ch in ipairs(body:children()) do if ch.name == "AstroModel" then m = ch end end
    local hb2 = home()
    local u = unit({ x = body.x - hb2.x, y = body.y - hb2.y, z = body.z - hb2.z })
    P("BODY visible %s model %s; medic→body %.2f m; body up·radial %.2f; ground clearance %.2f m",
      tostring(body.visible), tostring(m and m.visible), len(a.x - body.x, a.y - body.y, a.z - body.z),
      body.up and (body.up.x * u.x + body.up.y * u.y + body.up.z * u.z) or -9,
      terrain.query(body.x, body.y, body.z) or -1)
  end
  if body and body.worldForward then
    -- lying on the back: the suit's front (the node's +Z, crew_body) to the sky
    local hb3 = home()
    local u = unit({ x = body.x - hb3.x, y = body.y - hb3.y, z = body.z - hb3.z })
    local f = body:worldForward()
    local front = -(f.x * u.x + f.y * u.y + f.z * u.z)
    R("down_pose", front > 0.8, "the suit's front · the sky %.2f (1 = flat on the back, -1 = face-down)", front)
    -- and CONTROL is not offered on them: the switch list (the strip's chips, [ ])
    local listed = false
    for _, e in ipairs(C.switchList() or {}) do if e.kind == "crew" and e.id == id1 then listed = true end end
    R("no_control", not listed, "the downed member in the switch list: %s", tostring(listed))
  end
  local chips = findScript("crew_alerts_hud").chipsOf(C.alerts())
  local ct = {}
  for _, c in ipairs(chips) do ct[#ct + 1] = c[1] end
  shot("downed_chip")
  frames(3)
  if body then
    -- a close look at the downed: 2.2 m off their side, the camera low
    local b = home()
    local u = unit({ x = body.x - b.x, y = body.y - b.y, z = body.z - b.z })
    local side = unit(cross(u, math.abs(u.y) > 0.9 and { x = 1, y = 0, z = 0 } or { x = 0, y = 1, z = 0 }))
    a.x, a.y, a.z = body.x - side.x * 2.6 + u.x * 0.9, body.y - side.y * 2.6 + u.y * 0.9, body.z - side.z * 2.6 + u.z * 0.9
    a.vx, a.vy, a.vz = 0, 0, 0
    if cam then cam.firstPerson = true end
    hold(0.6)
    face(body.x, body.y, body.z)
    hold(0.6)
    shot("downed_close")
    frames(3)
    if cam then cam.firstPerson = false end
  end
  R("chip", #ct > 0 and ct[#ct]:match("DOWN") ~= nil, "chips: %s", table.concat(ct, " | "))
  -- 3. over to them, the Medkit in hand, the right-click rows, the revive
  if body then
    local b = home()
    local u = unit({ x = body.x - b.x, y = body.y - b.y, z = body.z - b.z })
    local side = unit(cross(u, math.abs(u.y) > 0.9 and { x = 1, y = 0, z = 0 } or { x = 0, y = 1, z = 0 }))
    a.x, a.y, a.z = body.x + side.x * 1.4 + u.x * 0.8, body.y + side.y * 1.4 + u.y * 0.8, body.z + side.z * 1.4 + u.z * 0.8
    a.vx, a.vy, a.vz = 0, 0, 0
  end
  hold(1.0)
  H.hold("medkit")
  hold(1.0)
  if cam then cam.firstPerson = false end
  if body then face(body.x, body.y, body.z) end
  hold(0.8)
  shot("medkit_in_hand")
  frames(3)
  local reg = findScript("context_registry")
  local labels, use = {}, nil
  if reg and reg.entriesFor then
    local list, errs = reg.entriesFor({ kind = "member", id = id1, node = body, label = "crew" },
      { ref = function(k) return findScript(k) end })
    for _, e in ipairs(list or {}) do labels[#labels + 1] = e.label .. (e.type == "info" and (" " .. tostring(reg.live(e.value))) or "") end
    for _, e in ipairs(errs or {}) do P("provider error %s", e) end
    use = reg.byId(list, "medkit")
    if use then labels[#labels + 1] = "(usable " .. tostring(reg.usable(use)) .. ")" end
  end
  local why0 = C.treatWhyNot(id1)
  R("menu", use ~= nil and why0 == nil, "rows: %s; why %s", table.concat(labels, ", "), tostring(why0))
  local left0 = C.get(id1).downed and C.get(id1).downed.left or -1
  local okT = use and reg.press(use) or C.treat(id1)
  for k = 1, 6 do
    hold(0.5)
    local bb = C.bodyOf(id1)
    P("TREAT %.1f s: medic-patient %.2f m, treating %s, medic v %.2f", k * 0.5,
      bb and len(a.x - bb.x, a.y - bb.y, a.z - bb.z) or -1, tostring(C.treating() ~= nil), len(a.vx, a.vy, a.vz))
    if k == 6 then break end
  end
  local left1 = C.get(id1).downed and C.get(id1).downed.left or -1
  shot("revive_progress")
  frames(3)
  local T = C.treating()
  wait_for(function() return C.treating() == nil end, 12, "the revive")
  hold(0.5)
  r1 = C.get(id1)
  R("revive", okT and T and T.kind == "revive" and math.abs(left1 - left0) < 0.3 and not r1.downed and math.abs((r1.hp or 0) - 0.25) < 1e-3
    and inv.itemCount("crew:2", "medkit") == 2,
    "treat %s (%s at %.0f%%); bleed clock %.1f → %.1f while working; #1 downed %s hp %.2f; #2's kits %d",
    tostring(okT), tostring(T and T.kind), (T and T.frac or 0) * 100, left0, left1, tostring(r1.downed ~= nil), r1.hp or -1,
    inv.itemCount("crew:2", "medkit"))
  hold(2.0)
  shot("revived")
  frames(3)
  -- 4. the injured: +50 %
  do  -- (walk back up to them: they are standing now)
    local bb = C.bodyOf(id1)
    if bb then
      local b = home()
      local u = unit({ x = bb.x - b.x, y = bb.y - b.y, z = bb.z - b.z })
      local side = unit(cross(u, math.abs(u.y) > 0.9 and { x = 1, y = 0, z = 0 } or { x = 0, y = 1, z = 0 }))
      a.x, a.y, a.z = bb.x + side.x * 1.3, bb.y + side.y * 1.3, bb.z + side.z * 1.3
      a.vx, a.vy, a.vz = 0, 0, 0
      C.quietMonitors(1.0)
      hold(0.8)
    end
  end
  local okH, whyH = C.treat(id1)
  if not okH then P("heal refused: %s", tostring(whyH)) end
  wait_for(function() return C.treating() == nil end, 10, "the heal")
  r1 = C.get(id1)
  R("heal", okH and math.abs((r1.hp or 0) - 0.75) < 0.02 and inv.itemCount("crew:2", "medkit") == 1,
    "treat %s; #1 hp %.2f; #2's kits %d", tostring(okH), r1.hp or -1, inv.itemCount("crew:2", "medkit"))
  -- 5. #3 shot down and left to bleed out
  local S3 = spot(170, 2.2)
  local x3, y3, z3 = at(S3, 1.05)
  C.setDown(3, x3, y3, z3)
  wait_for(function() local n = C.bodyOf(3); return n and n.valid ~= false end, 10, "#3's body")
  C.patch(3, { hp = 0.3 })
  C.hurt(3, 0.45, "shot", "by a probe's hostile, 40 m", { by = "a probe's hostile" })
  local d3 = C.get(3).downed
  R("down3", d3 ~= nil, "#3 down: %s s", d3 and string.format("%.0f", d3.secs) or "-")
  local t0 = W()
  wait_for(function() return C.get(3).status == "dead" end, (d3 and d3.secs or 80) + 20, "#3 bleeding out")
  local r3 = C.get(3)
  local mem = C.memorial()
  local rp = findScript("crew_roster_panel")
  local line = (rp and rp.causeText and r3.died) and rp.causeText(r3.died) or tostring(r3.died and r3.died.detail)
  R("bled", r3.status == "dead" and r3.died.bled == true and r3.died.cause == "shot" and #mem >= 1 and mem[#mem].id == 3,
    "after %.0f s: %s, cause %s, detail %q; memorial: %s", W() - t0, tostring(r3.status), tostring(r3.died and r3.died.cause),
    tostring(r3.died and r3.died.detail), line)
  -- 6. an explosion: dead outright
  C.kill(id1, "explosion", nil, { over = 1.0 })
  local re = C.get(id1)
  R("explosion", re.status == "dead" and not re.downed and not re.died.bled, "#1: %s (%s)", tostring(re.status),
    tostring(C.lastDeath and C.lastDeath.text))
  wait_for(function() return pending == 0 end, 10, "the pictures")
  P("DONE fails %d", FAILS)
end

function start(node)
  NODE = node
  CO = coroutine.create(main)
end

function update(node, dt)
  if not CO then return end
  if coroutine.status(CO) == "dead" then
    CO = nil
    if params.quit == 1 and app.quit then app.quit() end
    return
  end
  local ok, err = coroutine.resume(CO)
  if not ok then P("ERROR %s", tostring(err)); CO = nil; if params.quit == 1 and app.quit then app.quit() end end
end
