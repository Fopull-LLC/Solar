-- ── fix probe (tools/perf/fixprobe.sh): the 2026-11-03 playtest's maneuver
-- readout, engine staging, wing symmetry and rover navball. See fixprobe.sh.
local FX = { fails = 0, tag = "fix" }
function FX.check(name, ok, fmt, ...)
  P("FX %s %s: " .. (fmt or ""), ok and "PASS" or "FAIL", name, ...)
  if not ok then FX.fails = FX.fails + 1 end
  return ok
end
function FX.result() P("FX RESULT %s: %s (%d failed check(s))", FX.tag, FX.fails == 0 and "PASS" or "FAIL", FX.fails) end
function FX.shot(nm)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes)
    if bytes then assets.writeBytes("user://fixshots/" .. FX.tag .. "_" .. nm .. ".png", bytes); P("FX SHOT %s_%s", FX.tag, nm) end
    done = true
  end)
  if ok then wait_for(function() return done end, 5, "shot " .. nm) end
end
function FX.decode(v)
  local t = type(v)
  if t == "string" then
    if v:sub(1, 1) ~= "\0" then return v end
    local tag, rest = v:sub(2, 3), v:sub(4)
    if tag == "s:" then return rest end
    if tag == "d:" then local m, e = rest:match("^(-?%d+):(-?%d+)$"); if m then return math.ldexp(tonumber(m), tonumber(e)) end end
    return v
  elseif t ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = FX.decode(x) end
  return out
end
local function fx_craft(file)
  local ok, raw = pcall(assets.readJson, "user://" .. file)
  if not ok or type(raw) ~= "table" then P("FX no user://%s", file); return nil end
  return FX.decode(raw.bp)
end
local function fx_money()
  local co = findScript("company")
  if co and co.earn then co.earn(200000, "probe") end
  local rs = findScript("research")
  if rs and rs.grant then
    for _, id in ipairs({ "tankM", "engineM", "skipper", "gearM", "gearS", "wingDelta", "jet", "decoupler", "radialDec", "light",
                          "fuseTank", "cockpit", "tailFin", "intake", "intakeCone", "roverBody", "wheelM", "seat" }) do rs.grant(id, "probe") end
  end
end
local function fx_air(vc, up)
  local vn = vc.node
  vc.releaseClamps()
  yield()
  local S0 = body_state(vn)
  local io = assembly.info(vn)
  if S0 and io and io.origin then
    assembly.teleport(vn, vec3(io.origin.x + S0.U.x * up, io.origin.y + S0.U.y * up, io.origin.z + S0.U.z * up))
  end
  yield(); yield()
end
-- pod / FT-S / Sputter | decoupler | FT-M / Skipper, the pod the tree's root
local function fx_simple(eng_stage)
  local l = {}
  l[#l + 1] = rec(1, "pod", 0, 6.05, 0, {})
  l[#l + 1] = rec(2, "tankS", 0, 5.15, 0, { parent = 1, att = "bottom" })
  l[#l + 1] = rec(3, "engineS", 0, 4.0, 0, { parent = 2, att = "bottom", stage = eng_stage })
  l[#l + 1] = rec(4, "decoupler", 0, 3.225, 0, { parent = 3, att = "bottom", stage = 1 })
  l[#l + 1] = rec(5, "tankM", 0, 2.35, 0, { parent = 4, att = "bottom" })
  l[#l + 1] = rec(6, "skipper", 0, 0.8, 0, { parent = 5, att = "bottom", stage = -1 })
  l[#l + 1] = rec(7, "chute", 0, 6.62, 0, { parent = 1, att = "top" })
  return l
end

-- ── the maneuver readout ────────────────────────────────────────────────────
function run_mnvhud()
  FX.tag = params.tag or "mnv"
  fx_money()
  local list = fx_simple(0)
  local vc = launch_in_vab(list, "pad", #list, { root = 1, name = "Node Test" })
  if not vc then FX.check("rollout", false, "no craft"); FX.result(); return end
  wait(2)
  fx_air(vc, tonumber(params.airstart) or 900)
  vc.setSAS("stability")
  local om = findScript("orbit_map")
  local fh = findScript("flight_hud")
  om.toggle()
  wait(1.0)
  tap("n")
  wait(0.8)
  -- prograde for a while: W tunes the node's Δv in plan mode (the keys work)…
  key_down("w"); wait(1.0); key_up("w")
  local bk = om.burnInfo and om.burnInfo()
  FX.check("plan_keys", bk and bk.dv > 0.2, "W in plan mode adds prograde: %.1f m/s", bk and bk.dv or -1)
  -- …then a real burn: 40 m/s prograde, 25 s ahead
  om.planBurn(tonumber(params.mnvlead) or 25, tonumber(params.mnvdv) or 40, 0, 0)
  wait(0.8)
  local b0 = om.burnInfo and om.burnInfo()
  FX.check("node_planned", b0 and b0.dv > 1 and b0.dir ~= nil, "a node: %.1f m/s, in %.0f s, dir %s", b0 and b0.dv or -1, b0 and b0.lead or -1, tostring(b0 and b0.dir ~= nil))
  FX.shot("0map_node")
  tap("n")
  wait(0.3)
  om.toggle()
  wait(1.2)
  FX.shot("1flight_readout")
  local m = fh.nodeMark and fh.nodeMark()
  P("FX mark %s at %.1f,%.1f (ball %.1f,%.1f r %.0f) behind %s", tostring(m and m.on), m and m.x or -1, m and m.y or -1, m and m.cx or -1, m and m.cy or -1, m and m.r or -1, tostring(m and m.behind))
  P("FX mark element: %s", m and m.el and string.format("visible %s pos %.1f,%.1f opacity %.2f", tostring(m.el.vis), m.el.x or -1, m.el.y or -1, m.el.op or -1) or "none")
  FX.check("mark_shown", m and m.on and m.el and m.el.vis, "the node's ◆ is on the ball")
  -- the hold: the nose goes onto the burn, so the ◆ comes to the cross
  vc.setSAS("node")
  local t0 = time
  local d = 1e9
  while time - t0 < 14 do
    yield()
    m = fh.nodeMark()
    if m and m.on and not m.behind then d = math.sqrt((m.x - m.cx) ^ 2 + (m.y - m.cy) ^ 2) end
    if d < 3 and time - t0 > 3 then break end
  end
  FX.check("mark_on_cross", d < 6, "SAS NODE holds the nose on it: the ◆ is %.1f units off the ball's centre (r %.0f)", d, m and m.r or -1)
  FX.shot("2held_on_node")
  -- burn: Δv left falls
  local b1 = om.burnInfo()
  local t1 = time
  while time - t1 < 1.5 do vc.setThrottle(0.15); yield() end
  local b2 = om.burnInfo()
  FX.check("dv_falls", b2 and b1 and b2.left < b1.left - 1, "Δv left %.1f → %.1f m/s after 1.5 s at 15%% (%.0f%% done)", b1 and b1.left or -1, b2 and b2.left or -1, (b2 and b2.done or 0) * 100)
  FX.shot("3burning")
  local t2 = time
  while time - t2 < 30 do
    local bb = om.burnInfo()
    if not bb or bb.left < 0.6 then break end
    vc.setThrottle(bb.left < 4 and 0.03 or 0.2)
    yield()
  end
  vc.setThrottle(0)
  wait(0.4)
  local b3 = om.burnInfo()
  FX.check("burn_done", b3 and b3.left < 1.5, "after the burn: %.2f m/s left", b3 and b3.left or -1)
  FX.shot("4burn_done")
  FX.result()
end

-- ── the STAGE tab with engines, and staged ignition in flight ───────────────
function run_stageui()
  FX.tag = params.tag or "stage"
  fx_money()
  local BH = enter_vab("fx_enter")
  if not BH then FX.check("vab", false, "no builder"); FX.result(); return end
  local B = findScript("builder")
  local ins = findScript("builder_inspector")
  local bc = findScript("builder_camera")
  wait(1)
  local bp = fx_craft("probe_deepspace.json")
  load_bp(B, "fx_deep", bp.parts, { links = bp.links, root = bp.root, v = bp.v or 2 })
  if ins and ins.setTab then ins.setTab("STAGE") end
  if bc and bc.frameCraft then bc.frameCraft() end
  wait(2)
  local v = B.stageView()
  local function describe_v(vv)
    local o = { "L:" }
    for _, e in ipairs(vv.launch.items or {}) do o[#o + 1] = e.key .. "(" .. e.n .. ")" end
    for n, sg in ipairs(vv.stages) do
      o[#o + 1] = "|" .. n .. ":"
      for _, e in ipairs(sg.items) do o[#o + 1] = e.key .. (e.kind == "engine" and ("(" .. e.n .. ")") or "") end
    end
    return table.concat(o, " ")
  end
  P("FX view %s", describe_v(v))
  local grp = nil
  for _, e in ipairs(v.launch.items or {}) do if e.n == 4 then grp = e.key end end
  FX.check("group_x4", grp ~= nil, "the four Skippers are one item ×4 at launch (%s)", tostring(grp))
  local s1eng = false
  for _, e in ipairs(v.stages[1] and v.stages[1].items or {}) do if e.kind == "engine" and e.n == 1 then s1eng = true end end
  FX.check("upper_follows", s1eng, "the Sputter over the decoupler ignites with stage 1")
  FX.shot("1stage_tab_default")
  -- drag the group into stage 1 (the drop's command)
  if grp then B.cmd("stage", { op = "item", key = grp, to = 1 }) end
  wait(0.8)
  v = B.stageView()
  P("FX view %s", describe_v(v))
  local moved = false
  for _, e in ipairs(v.stages[1].items) do if e.key == grp then moved = true end end
  FX.check("group_moved", moved, "the ×4 group moved into stage 1 as one")
  FX.shot("2group_in_stage1")
  B.cmd("stage", { op = "split", key = grp })
  wait(0.8)
  v = B.stageView()
  P("FX view %s", describe_v(v))
  local singles = 0
  for _, e in ipairs(v.stages[1].items) do if e.kind == "engine" and e.n == 1 then singles = singles + 1 end end
  FX.check("split", singles >= 5, "split: %d single engine rows in stage 1", singles)
  FX.shot("3split")
  B.undoStep(); B.undoStep()
  wait(0.6)
  v = B.stageView()
  P("FX view after two undos %s", describe_v(v))
  FX.check("undo", #(v.launch.items or {}) >= 2, "two undos: the group back at launch")
  -- in flight: the Sputter in a stage of its own (2), after the decoupler (1)
  local list = fx_simple(2)
  load_bp(B, "fx_simple", list, { root = 1, name = "Ignition Test" })
  wait(0.8)
  v = B.stageView()
  P("FX simple view %s", describe_v(v))
  FX.shot("4simple_ignite_stage")
  if B.launchSite and B.launchSite() ~= "pad" and B.toggleLaunchSite then B.toggleLaunchSite() end
  B.doLaunch()
  wait(0.6)
  if BH.state == "building" then B.doLaunch() end
  local vc = wait_craft(#list, 150)
  if not vc then FX.check("rollout", false, "no craft"); FX.result(); return end
  wait(2)
  local t = vc.tele or {}
  FX.check("hud_cards", t.stages and #t.stages == 3, "the HUD's stack: %s cards (decouple, ignite, chutes)", tostring(t.stages and #t.stages))
  fx_air(vc, 500)
  local t0 = time
  while time - t0 < 1.5 do vc.setThrottle(1); yield() end
  t = vc.tele or {}
  FX.check("launch_lit", (t.eng or 0) == 1 and (t.thrust_now or 0) > 100, "lift-off: the Skipper only (%s eng, %.0f kN)", tostring(t.eng), t.thrust_now or 0)
  vc.stageNext()          -- the decoupler
  wait(0.5)
  t0 = time
  while time - t0 < 1.0 do vc.setThrottle(1); yield() end
  t = vc.tele or {}
  FX.check("cold_after_cut", (t.thrust_now or 0) < 0.5, "after the decoupler the Sputter waits for its stage (%.1f kN)", t.thrust_now or 0)
  FX.shot("5after_cut_cold")
  vc.stageNext()          -- the ignition
  t0 = time
  while time - t0 < 1.0 do vc.setThrottle(1); yield() end
  t = vc.tele or {}
  FX.check("ignited", (t.eng or 0) == 1 and (t.thrust_now or 0) > 40, "SPACE 2 ignites it (%s eng, %.1f kN)", tostring(t.eng), t.thrust_now or 0)
  FX.shot("6ignited")
  vc.setThrottle(0)
  FX.result()
end

-- ── wing gear symmetry ──────────────────────────────────────────────────────
function run_symwing()
  FX.tag = params.tag or "sym"
  fx_money()
  local BH = enter_vab("fx_enter")
  if not BH then FX.check("vab", false, "no builder"); FX.result(); return end
  local B = findScript("builder")
  local bc = findScript("builder_camera")
  wait(1)
  local bp = fx_craft("probe_plane.json")
  local keep = {}
  for _, d in ipairs(bp.parts) do if d.id ~= "gearM" and d.id ~= "gearS" then keep[#keep + 1] = d end end
  local links = {}
  local have = {}
  for _, d in ipairs(keep) do have[d.uid] = true end
  for _, l in ipairs(bp.links or {}) do if have[l.a] and have[l.b] then links[#links + 1] = l end end
  load_bp(B, "fx_plane", keep, { links = links, root = bp.root, v = bp.v or 2 })
  wait(1.5)
  local fr = B.frame and B.frame()
  local function W(x, y, z)
    if fr and fr.toWorld and not fr.identity then return fr.toWorld(x, y, z) end
    return x, y, z
  end
  local wing = B.partRec(131)
  local fuse = B.partRec(129)
  if not (wing and fuse) then FX.check("craft", false, "no wing 131 / fuselage 129"); FX.result(); return end
  P("FX wing 131 at %.2f %.2f %.2f, fuselage %.2f %.2f %.2f", wing.x, wing.y, wing.z, fuse.x, fuse.y, fuse.z)
  -- from below and in front of the right wing, looking up at its underside
  local function cam_below(target, yaw)
    bc.setCamState({ P = { x = target.x, y = target.y, z = target.z }, yaw = yaw or 0.0, pitch = tonumber(params.campitch) or 0.55, d = tonumber(params.camd) or 4.0 })
    wait(0.6)
  end
  local function gears()
    local o = {}
    for _, u in ipairs(B.partUids()) do local r = B.partRec(u); if r and r.id == "gearM" then o[#o + 1] = r end end
    return o
  end
  local function place_under(host, id, off)
    B.hold(id)
    wait(0.4)
    local px, py = camera.worldToScreen(W(host.x + (off.x or 0), host.y + (off.y or 0), host.z + (off.z or 0)))
    P("FX aim %s at screen %s,%s", id, tostring(px), tostring(py))
    if not px then return false end
    mouse_to(px, py); wait(0.5)
    lmb_click(); wait(0.8)
    tap("escape"); wait(0.3)
    return true
  end
  B.setSym(2)
  cam_below({ x = wing.x, y = wing.y - 0.5, z = wing.z + 1.5 }, 0.0)
  FX.shot("0before_below")
  place_under(wing, "gearM", { y = -0.05, z = -0.2 })
  local g = gears()
  P("FX gears: %d", #g)
  for _, r in ipairs(g) do P("FX gear %d on %s at %.2f %.2f %.2f yaw %.2f pitch %.2f roll %.2f sym %s mir %s", r.uid, tostring(r.parent), r.x, r.y, r.z, r.yaw or 0, r.pitch or 0, r.roll or 0, tostring(r.sym), tostring(r.mir)) end
  local both_under = #g == 2
  for _, r in ipairs(g) do if not (r.y < wing.y - 0.05) then both_under = false end end
  FX.check("pair", #g == 2, "×2 under one wing places a pair (%d)", #g)
  FX.check("both_under", both_under, "both gears hang UNDER their wings (wing y %.2f)", wing.y)
  if #g == 2 then
    FX.check("mirrored_x", math.abs(g[1].x + g[2].x - 2 * fuse.x) < 0.05 and math.abs(g[1].y - g[2].y) < 0.02 and math.abs(g[1].z - g[2].z) < 0.02,
      "the pair mirrors across the fuselage: x %.2f / %.2f, y %.2f / %.2f, z %.2f / %.2f", g[1].x, g[2].x, g[1].y, g[2].y, g[1].z, g[2].z)
  end
  cam_below({ x = fuse.x, y = wing.y - 0.6, z = wing.z + 2.5 }, 0.0)
  FX.shot("1wing_gear_below")
  cam_below({ x = fuse.x, y = wing.y - 0.3, z = wing.z }, 1.5708)
  FX.shot("2wing_gear_side")
  -- straight up from under the craft: both gears on the wings' undersides
  bc.setCamState({ P = { x = fuse.x, y = wing.y, z = wing.z }, yaw = 0.0, pitch = 1.25, d = 4.5 })
  wait(0.6)
  FX.shot("2b_from_below")
  -- the fuselage's flank: ×2, a light low on the side → a low pair
  local n0 = 0
  for _, u in ipairs(B.partUids()) do local r = B.partRec(u); if r and r.id == "light" then n0 = n0 + 1 end end
  cam_below({ x = fuse.x + 2.0, y = fuse.y, z = fuse.z - 0.5 }, 1.5708)
  B.setSym(2)
  place_under(fuse, "light", { x = 0.5, y = -0.25, z = -0.5 })
  local lights = {}
  for _, u in ipairs(B.partUids()) do local r = B.partRec(u); if r and r.id == "light" then lights[#lights + 1] = r end end
  for _, r in ipairs(lights) do P("FX light %d at %.2f %.2f %.2f mir %s", r.uid, r.x, r.y, r.z, tostring(r.mir)) end
  FX.check("flank_pair", #lights == 2 and math.abs(lights[1].y - lights[2].y) < 0.02 and lights[1].y < fuse.y and math.abs(lights[1].x + lights[2].x - 2 * fuse.x) < 0.05,
    "×2 on the fuselage's flank: a left/right pair at the same low height (%d)", #lights)
  cam_below({ x = fuse.x, y = fuse.y - 0.2, z = fuse.z + 3.0 }, 0.0)
  FX.shot("3flank_pair")
  B.setSym(1)
  FX.result()
end

-- ── the rover's navball ────────────────────────────────────────────────────
function run_roverball()
  FX.tag = params.tag or "rover"
  fx_money()
  local list = {}
  for _, r in ipairs(ROVER) do list[#list + 1] = r end
  local vc = launch_in_vab(list, "runway", #list, { name = "Ball Rover" })
  if not vc then FX.check("rollout", false, "no craft"); FX.result(); return end
  wait(2)
  vc.releaseClamps()
  wait(3)
  local NB = vc.NAVBALL
  local pitch = NB and NB.ny and math.deg(math.asin(NB.ny)) or 99
  local mode = vc.ctrlModeInfo and vc.ctrlModeInfo().mode
  P("FX rover mode %s, ball nose %.2f %.2f %.2f, fwd %s,%s", tostring(mode), NB.nx or 0, NB.ny or 0, NB.nz or 0, tostring(vc.R2 and vc.R2.fwd and vc.R2.fwd.x), tostring(vc.R2 and vc.R2.fwd and vc.R2.fwd.z))
  FX.check("rover_mode", mode == "rover", "the craft flies as a rover (%s)", tostring(mode))
  FX.check("level_ahead", math.abs(pitch) < 12, "the ball reads the horizon ahead: pitch %.1f°", pitch)
  FX.shot("1rover_ball")
  -- drive a little: the heading follows the drive front
  key_down("w"); wait(2.5); key_up("w")
  wait(0.5)
  NB = vc.NAVBALL
  pitch = NB and NB.ny and math.deg(math.asin(NB.ny)) or 99
  FX.check("level_driving", math.abs(pitch) < 15, "driving: pitch %.1f°", pitch)
  FX.shot("2rover_driving")
  FX.result()
end
