-- ── craft probe (tools/perf/craftprobe.sh): the player's jet (userjet: params bury, notail, tag) and a rover jump (jump: params pod, kick, jumprun) ──
local function cp_decode(v)
  local t = type(v)
  if t == "string" then
    if v:sub(1, 1) ~= "\0" then return v end
    local tag, rest = v:sub(2, 3), v:sub(4)
    if tag == "s:" then return rest end
    if tag == "d:" then local m, e = rest:match("^(-?%d+):(-?%d+)$"); if m then return math.ldexp(tonumber(m), tonumber(e)) end end
    return v
  elseif t ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = cp_decode(x) end
  return out
end
local function wbasis(n)
  local f = n:worldForward()
  local r, u = n:worldRight(), n:worldUp()
  return { x = r.x, y = r.y, z = r.z }, { x = u.x, y = u.y, z = u.z }, { x = -f.x, y = -f.y, z = -f.z }
end
-- where the craft is against the ground: terrain.query (signed distance to
-- the surface, negative = inside rock) at the CoM, the vessel origin and each
-- tyre; the ground under the CoM by a ray from 30 m above; the vessel's up
-- against the planet's
local CP_TAG = "x"
local function cpshot(nm)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = false }, function(bytes, why)
    if bytes then assets.writeBytes("user://craftshots/" .. CP_TAG .. "_" .. nm .. ".png", bytes); P("CP SHOT %s_%s", CP_TAG, nm) end
    done = true
  end)
  if ok then wait_for(function() return done end, 5, "shot " .. nm) end
end
local function cp_state(vc, vn, tag)
  local i = assembly.info(vn)
  local b = home()
  if not (i and b) then P("CP %s: no info", tag); return end
  local U = unit(sub(i.com, b))
  local top = { x = i.com.x + U.x * 30, y = i.com.y + U.y * 30, z = i.com.z + U.z * 30 }
  local h = raycast(top.x, top.y, top.z, -U.x, -U.y, -U.z, 80, vn)
  local gnd = h and (30 - h.distance) or 99  -- the ground (or whatever the ray met) below the CoM, m
  local qc = terrain.query(i.com.x, i.com.y, i.com.z)
  local o = vn:toWorld(vec3(0, 0, 0))
  local qo = terrain.query(o.x, o.y, o.z)
  local tq = {}
  local ng, nt = 0, 0
  for _, w in ipairs(vc.R2.wheels or {}) do
    if w.tyre and w.tyre.valid then
      nt = nt + 1; if w.tyre.grounded then ng = ng + 1 end
      local q = terrain.query(w.tyre.x, w.tyre.y, w.tyre.z)
      tq[#tq + 1] = string.format("%s%.2f", w.gear and "g" or "w", q or -99)
    end
  end
  local upw = vn:worldUp()
  local v = i.vel
  P("CP %s field@com %.2f field@origin %.2f ground-under-com %.2f (%s) | tyres %d grounded %d field %s | up.U %.3f | |v| %.2f vU %.2f |w| %.2f | parts %d onWheels %s live %s grounded %s anchored %s destroyed %s",
    tag, qc or -99, qo or -99, gnd, h and h.node and h.node.name or "-", nt, ng, table.concat(tq, " "),
    dot(upw, U), len(v.x, v.y, v.z), dot(v, U), len(i.angVel.x, i.angVel.y, i.angVel.z), #i.parts,
    tostring(vc.R2.onWheels), tostring(vc.R2.live), tostring(i.grounded), tostring(i.anchored), tostring(vc.destroyed))
  return qc, i
end

local function run_userjet()
  local ok, raw = pcall(assets.readJson, "user://probe_jet.json")
  if not ok or type(raw) ~= "table" then P("CP no user://probe_jet.json: %s", tostring(raw)); return end
  local bp = cp_decode(raw.bp)
  if (params.notail or 0) > 0 then
    -- (the variant: the gear under the jet's tail taken off)
    local keep = {}
    for _, d in ipairs(bp.parts) do if d.uid ~= 31 then keep[#keep + 1] = d end end
    bp.parts = keep
    local kl = {}
    for _, l in ipairs(bp.links or {}) do if l.a ~= 31 and l.b ~= 31 then kl[#kl + 1] = l end end
    bp.links = kl
  end
  P("CP jet blueprint: %d parts, root %s", #bp.parts, tostring(bp.root))
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  save.set("shipyard.blueprint", bp)
  save.set("shipyard.site", "runway")
  save.set("shipyard.pilot", 1)
  scene.load("builder")
  local B = wait_for(function() local B = findScript("builder"); return B and B.partUids and #B.partUids() >= #bp.parts and B end, 90, "the builder")
  if not B then P("CP builder did not load the jet (%s parts)", tostring(findScript("builder") and #findScript("builder").partUids())) return end
  wait(1.5)
  save.set("shipyard.site", "runway")
  B.doLaunch()
  if save.get("shipyard.launch") ~= 1 then B.doLaunch() end
  local vc = wait_craft(#bp.parts, 150)
  wait_regrade()
  if not vc then P("CP RESULT jet: no craft"); return end
  local vn = vc.node
  CP_TAG = params.tag or "jet"
  cp_state(vc, vn, "clamped")
  if (params.bury or 0) > 0 then
    -- A GRADE UNDER THE HELD CRAFT (what the base's regrade did in run
    -- before2): the ground under the jet raised by `bury` m while it is clamped
    local i0 = assembly.info(vn)
    local b0 = home()
    local U0 = unit(sub(i0.com, b0))
    local top = { x = i0.com.x + U0.x * 30, y = i0.com.y + U0.y * 30, z = i0.com.z + U0.z * 30 }
    local h0 = raycast(top.x, top.y, top.z, -U0.x, -U0.y, -U0.z, 80, vn)
    if h0 then
      local g = { x = h0.x + U0.x * params.bury, y = h0.y + U0.y * params.bury, z = h0.z + U0.z * params.bury }
      for k3 = -2, 2 do
        local f = vn:worldForward()
        terrain.sculpt(g.x + f.x * k3 * 2.5, g.y + f.y * k3 * 2.5, g.z + f.z * k3 * 2.5, 7.0, 1.0, "flatten")
      end
      wait_for(function() return (terrain.pending and terrain.pending() or 0) == 0 end, 20, "the grade")
      wait(1.5)
      P("CP bury: the ground under the held jet raised %.1f m", params.bury)
      cp_state(vc, vn, "buried")
    end
  end
  cpshot("1clamped")
  vc.releaseClamps()
  vc.setSAS("stability")
  local t0 = time
  local nextp = 0
  while time - t0 < 8 do
    yield()
    if not vn.valid then P("CP jet node gone"); break end
    if time - t0 >= nextp then cp_state(vc, vn, string.format("rest+%.1f", time - t0)); nextp = nextp + 0.25 end
    if not SH2 and time - t0 > 2.0 then SH2 = true; cpshot("2rest2s") end
  end
  cpshot("3rest8s")
  if params.shotjet and vn.valid then P("CP shot") end
  -- the take-off roll: full throttle, the stick a little back past 30 m/s
  t0 = time
  nextp = 0
  local maxagl = 0
  while vn.valid and time - t0 < 40 do
    yield()
    vc.setThrottle(1)
    local i = assembly.info(vn)
    if not i then break end
    local V = len(i.vel.x, i.vel.y, i.vel.z)
    vc.AERO.cmd = { p = V > 30 and -0.6 or 0, y = 0, r = 0 }
    if time - t0 >= nextp then
      local agl = cp_state(vc, vn, string.format("roll+%.1f V=%.1f", time - t0, V)); nextp = nextp + 1
      if agl then maxagl = math.max(maxagl, agl) end
      if math.floor(time - t0) == 12 and not SH4 then SH4 = true; cpshot("4roll12s") end
    end
    if vc.destroyed then P("CP jet destroyed at roll+%.1f", time - t0); break end
  end
  P("CP RESULT jet: max field@com in the roll %.1f m, destroyed %s, parts %d", maxagl, tostring(vc.destroyed), vn.valid and #assembly.info(vn).parts or -1)
end

local function run_jump()
  local bpr = ROVER
  if (params.pod or 0) > 0 then
    -- the player's kind of rover: a pod (a real reaction wheel) on the deck
    bpr = {}
    for k2, r in ipairs(ROVER) do bpr[k2] = r end
    bpr[6] = rec(6, "pod", 0, 0.62 + 0.15 + 0.4, 0, { parent = 1, att = "top" })
  end
  local vc = launch_via_builder(bpr, "runway", 6)
  if not vc then P("CP RESULT jump: no craft"); return end
  local vn = vc.node
  vc.releaseClamps()
  vc.setSAS("stability")
  wait(2)
  key_down("w")
  wait(params.jumprun or 5)
  local i = assembly.info(vn)
  local b = home()
  local Ug = unit(sub(i.com, b))
  P("CP jump: speed %.1f before the kick, onWheels %s, fwd (%.2f, %.2f)", len(i.vel.x, i.vel.y, i.vel.z), tostring(vc.R2.onWheels), vc.R2.fwd.x, vc.R2.fwd.z)
  -- the kick: straight up, at the CoM (no torque), as if off a ramp
  local kv = params.kick or 7
  assembly.impulseAt(vn, vec3(Ug.x * kv * i.mass, Ug.y * kv * i.mass, Ug.z * kv * i.mass), vec3(i.com.x, i.com.y, i.com.z))
  local F0, t0 = nil, time
  local maxp, maxr, maxy = 0, 0, 0
  local landed_t = nil
  local nextp = 0
  while time - t0 < 6 do
    yield()
    if not vn.valid then break end
    i = assembly.info(vn); b = home()
    Ug = unit(sub(i.com, b))
    local rx, up, rz = wbasis(vn)
    local F = vc.R2.fwd
    local Fw = unit({ x = rx.x * F.x + rz.x * F.z, y = rx.y * F.x + rz.y * F.z, z = rx.z * F.x + rz.z * F.z })
    local Rt = cross(Fw, up)
    local Fh = unit(sub(Fw, scl(Ug, dot(Fw, Ug))))
    F0 = F0 or Fh
    local pitch = math.deg(math.asin(clamp(dot(Fw, Ug), -1, 1)))     -- nose up +
    local roll = math.deg(-math.asin(clamp(dot(Rt, Ug), -1, 1)))     -- right side down +
    local yaw = math.deg(math.atan2(dot(cross(F0, Fh), Ug), dot(F0, Fh)))  -- left +
    local w = i.angVel
    local air = not vc.R2.onWheels and not i.grounded
    if time - t0 > 0.15 and air then
      maxp = math.max(maxp, math.abs(pitch)); maxr = math.max(maxr, math.abs(roll)); maxy = math.max(maxy, math.abs(yaw))
    end
    if not air and time - t0 > 0.4 and not landed_t then landed_t = time - t0; P("CP jump: landed after %.2f s, pitch %.1f roll %.1f yaw %.1f", landed_t, pitch, roll, yaw) end
    if time - t0 >= nextp then
      if math.floor((time - t0) * 2) ~= math.floor((time - t0 - 0.1) * 2) then
        local el = vc.elec or {}
        P("CP jumpdbg torque_k %s wheel_use %s control %s aeroframe %s sas %s", tostring(el.torque_k), tostring(el.wheel_use), tostring(el.control), tostring(vc.AERO and vc.AERO.frame ~= nil), tostring(vc.sas_mode))
      end
      nextp = nextp + 0.1
      P("CP jumplog t=%.2f air %s pitch %.1f roll %.1f yaw %.1f | rates nose-up %.2f roll-right %.2f yaw-left %.2f | v %.1f driving %s",
        time - t0, tostring(air), pitch, roll, yaw, dot(w, Rt), dot(w, Fw), dot(w, up), len(i.vel.x, i.vel.y, i.vel.z), tostring(vc.R2.driving))
    end
  end
  release_all()
  P("CP RESULT jump: max |pitch| %.1f |roll| %.1f |yaw| %.1f deg in the air (W held), landed after %s s", maxp, maxr, maxy, tostring(landed_t))
end

