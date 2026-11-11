-- ── HARD VACUUM probe (tools/perf/vacprobe.sh; scenarios/hard_vacuum) ──────
-- Spliced into a copy of perfbench.lua. Modes:
--   anselbuild  the freighter Ansel built in the VAB from the records below
--               (the builder fills in every field the launch format carries),
--               written as user://ansel.json ({"fmt":1,"bp":…}, the builder's
--               own library encoding); then rolled out, put in orbit and its
--               cabin modules, doors and thermal loop read back
-- `VP PASS|FAIL <check>` lines and `VP RESULT`.
local VP = { fails = 0, passed = 0 }
function VP.check(name, ok, fmt, ...)
  P("VP %s %s: " .. (fmt or ""), ok and "PASS" or "FAIL", name, ...)
  if ok then VP.passed = VP.passed + 1 else VP.fails = VP.fails + 1 end
  return ok
end
function VP.result() P("VP RESULT %d passed, %d failed", VP.passed, VP.fails) end

-- ANSEL, bottom (aft) to top (forward), +Y up the stack. Uids are the
-- scenario's: it names the breach (10), the hatches (12/13, 15/16), the
-- seats (14, 17) and the core (4).
--   1 Anvil · 2-3 FT-M · 4 Ember (its cone opens up the stack) · 5-8 four
--   Cargo Bays (the spine) · 9 the Shadow Shield · 19-20 two more bays ·
--   10-11 the stores (two Crew Cabins: one module) · 12-13 hatch B ·
--   14 the hab (a Crew Cabin) · 15-16 hatch A · 17 the flight deck (Pod
--   Mk2) · 18 a Relay Dish · 21-22 radiator panels on the Ember
function VP.ansel()
  local l = {}
  local y = 0
  local function stack(uid, id, h, parent, st)
    l[#l + 1] = rec(uid, id, 0, y + h / 2, 0, { parent = parent or 0, att = parent and "top" or "" })
    l[#l].st = st
    y = y + h
  end
  stack(1, "engineM", 1.6, nil)
  stack(2, "tankM", 1.5, 1)
  stack(3, "tankM", 1.5, 2)
  local ember_y = y + 0.7
  stack(4, "ember", 1.4, 3, { rods = 1, life = 3600, critical = true, output = 40 })
  stack(5, "cargo", 1.2, 4)
  stack(6, "cargo", 1.2, 5)
  stack(7, "cargo", 1.2, 6)
  stack(8, "cargo", 1.2, 7)
  stack(9, "shadowShield", 0.18, 8)
  stack(19, "cargo", 1.2, 9)
  stack(20, "cargo", 1.2, 19)
  stack(10, "cabin", 1.3, 20)
  stack(11, "cabin", 1.3, 10)
  stack(12, "dockPort", 0.28, 11, { ph = "open" })
  stack(13, "dockPort", 0.28, 12, { ph = "open" })
  stack(14, "cabin", 1.3, 13)
  stack(15, "dockPort", 0.28, 14, { ph = "open" })
  stack(16, "dockPort", 0.28, 15, { ph = "open" })
  stack(17, "podMk2", 1.15, 16)
  stack(18, "dish", 0.8, 17)
  -- the radiators, either side of the core, folded out
  l[#l + 1] = rec(21, "radPanel", 1.12, ember_y, 0, { parent = 4, att = "surface" })
  l[#l].anx, l[#l].anz, l[#l].st = 1, 0, { deployed = true }
  l[#l + 1] = rec(22, "radPanel", -1.12, ember_y, 0, { parent = 4, att = "surface", yaw = math.pi })
  l[#l].anx, l[#l].anz, l[#l].st = -1, 0, { deployed = true }
  return l
end

local function vp_orbit(vn)
  local i = assembly.info(vn)
  local b = home()
  local U = unit(sub(i.com, b))
  local T = cross(U, { x = 0, y = 1, z = 0 })
  if len(T.x, T.y, T.z) < 0.1 then T = cross(U, { x = 1, y = 0, z = 0 }) end
  T = unit(T)
  local wd = save.get("world." .. b.name)
  local atmo = type(wd) == "table" and (wd.atmoHeight or 0) or 0
  local r = b.radius + math.max(atmo + 500, b.radius * 0.6)
  local o = i.origin
  local want = { x = b.x + U.x * r, y = b.y + U.y * r, z = b.z + U.z * r }
  assembly.teleport(vn, vec3(want.x + (o.x - i.com.x), want.y + (o.y - i.com.y), want.z + (o.z - i.com.z)))
  wait(0.3)
  local vcirc = math.sqrt(b.mu / r)
  local gain = 1.0
  for _ = 1, 10 do
    i = assembly.info(vn)
    b = home()
    U = unit(sub(i.com, b))
    local Tn = unit(cross(U, cross(T, U)))
    local dv = sub(scl(Tn, vcirc), i.vel)
    local dl = len(dv.x, dv.y, dv.z)
    if dl < 0.5 then break end
    local v0 = i.vel
    local s = i.mass / gain
    assembly.impulseAt(vn, vec3(dv.x * s, dv.y * s, dv.z * s), i.com)
    wait(0.6)
    local i2 = assembly.info(vn)
    local got = len(i2.vel.x - v0.x, i2.vel.y - v0.y, i2.vel.z - v0.z)
    if got > 1e-3 then gain = math.max(0.02, math.min(5, gain * got / dl)) end
  end
end

local function run_anselbuild()
  local co = findScript("company")
  if co and co.earn then co.earn(200000, "probe") end
  local rs = findScript("research")
  for _, t in ipairs({ "ember", "rtg", "radPanel", "shadowShield", "dockPort", "podMk2", "cabin", "cargo", "dish", "engineM", "tankM" }) do
    if rs and rs.grant then pcall(rs.grant, t, "probe") end
  end
  local BH = enter_vab("launch_enter")
  if not VP.check("vab", BH ~= nil, "in the VAB") then VP.result(); return end
  local B = findScript("builder")
  wait(1.0)
  local list = VP.ansel()
  load_bp(B, "ansel_bp", list, { name = "Ansel" })
  wait(1.0)
  local bp = B.blueprintNow()
  VP.check("parts", bp and #bp.parts == #list, "%d of %d parts in the launch blueprint", bp and #bp.parts or -1, #list)
  -- the states the records carried (the builder may drop them: put them back)
  local by = {}
  for _, d in ipairs(list) do by[d.uid] = d end
  for _, d in ipairs(bp.parts or {}) do
    local src = by[d.uid]
    if src and src.st then d.st = type(d.st) == "table" and d.st or {}; for k, v in pairs(src.st) do d.st[k] = v end end
  end
  bp.name = "Ansel"
  local text = B.libText(bp)
  local okw = pcall(assets.writeText, "user://ansel.json", text)
  VP.check("written", okw, "user://ansel.json (%d bytes)", #text)
  for _, d in ipairs(bp.parts or {}) do
    P("VP part %d %s y %.3f h %.2f parent %s att %s st %s", d.uid, tostring(d.id), tonumber(d.y) or -1, tonumber(d.h) or -1,
      tostring(d.parent), tostring(d.att), d.st and "yes" or "-")
  end
  -- fly it: rolled out with this blueprint, then in orbit
  save.set("shipyard.blueprint", bp)
  if B.launchSite and B.launchSite() ~= "pad" and B.toggleLaunchSite then B.toggleLaunchSite() end
  B.doLaunch()
  wait(0.6)
  if BH.state == "building" then B.doLaunch() end
  local vc = wait_craft(#list, 150)
  if not VP.check("rollout", vc ~= nil, "on the pad") then VP.result(); return end
  vc.releaseClamps()
  vc.setSAS("stability")
  vc.setThrottle(0)
  wait(0.5)
  vp_orbit(vc.node)
  wait(3)
  local CA = findScript("cabin_air")
  CA.tickNow()
  local G = CA.modulesOf(vc)
  local mods = {}
  for i, m in ipairs(G and G.mods or {}) do
    local s = CA.statusOf(vc, i)
    mods[#mods + 1] = string.format("[%d %s %.1f m3 %.2f atm res %.1f/%.0f]", i, m.label, m.V, s and s.p or -1, s and s.reserve or -1, s and s.qcap or -1)
  end
  local doors = {}
  for _, d in ipairs(CA.doorsOf(vc)) do doors[#doors + 1] = string.format("%s#%d %d-%d %s", d.kind, d.uid, d.a or 0, d.b or 0, tostring(d.state)) end
  VP.check("modules", G and #G.mods == 3, "%s · doors %s", table.concat(mods, " "), table.concat(doors, ", "))
  local hud = vc.thermalHud and vc.thermalHud()
  VP.check("thermal", hud ~= nil, "loop T %.2f settles %.2f, cores %s live %s out %.2f", hud and hud.T or -1, hud and hud.eq or -1,
    tostring(hud and hud.cores), tostring(hud and hud.live), hud and hud.out or -1)
  VP.result()
end
