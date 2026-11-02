-- ── deep-space craft probe (tools/perf/deepprobe.sh): the player's 54-part
-- "deepspace mission" (2026-11-02: "this craft just goes ballistic as soon as
-- I launch it"). One mode, `deep`:
--   VAB   the craft loaded in the builder: every engine's place and thrust axis
--         (cant out from the craft's axis, cant round it), the CoM wet/dry, the
--         CoT, the thrust sum and its torque about the CoM; a picture with the
--         CoM/CoT overlay
--   PAD   rolled out on the pad, released, SAS stability, full throttle; for
--         `secs` (20) s at 10 Hz: tilt from the local vertical, the body rates
--         (pitch/yaw about the craft's right/forward, roll about its up), the
--         thrust torque from every live engine's own axis about the live CoM,
--         the SAS's rate damper, and what is left (I·α − thrust − SAS: the air,
--         the ground, anything else), the air's q and angle of attack
-- Params: straight=1 the boosters' tilt taken out (pitch/roll 0 on every part
-- of the four booster stacks); sas=0 SAS off; secs=N.
-- Lines: `DP VAB …`, `DP ENG …`, `DP T …`, `DP RESULT …`; pictures in
-- $WORK/proj/save/user/deepshots/.
local DP = {}
function DP.shot(nm)
  local done = false
  local ok = pcall(camera.capture, { w = 1280, h = 720, ui = true, draws = true }, function(bytes)
    if bytes then assets.writeBytes("user://deepshots/" .. (DP.tag or "deep") .. "_" .. nm .. ".png", bytes); P("DP SHOT %s_%s", DP.tag or "deep", nm) end
    done = true
  end)
  if ok then wait_for(function() return done end, 5, "shot " .. nm) end
end
function DP.decode(v)
  local t = type(v)
  if t == "string" then
    if v:sub(1, 1) ~= "\0" then return v end
    local tag, rest = v:sub(2, 3), v:sub(4)
    if tag == "s:" then return rest end
    if tag == "d:" then local m, e = rest:match("^(-?%d+):(-?%d+)$"); if m then return math.ldexp(tonumber(m), tonumber(e)) end end
    return v
  elseif t ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = DP.decode(x) end
  return out
end
-- vessel_controller.part_axis: the part's +Y in the vessel frame (YXZ Euler)
function DP.axis(d)
  local cy, sy = math.cos(d.yaw or 0), math.sin(d.yaw or 0)
  local cx, sx = math.cos(d.pitch or 0), math.sin(d.pitch or 0)
  local cz, sz = math.cos(d.roll or 0), math.sin(d.roll or 0)
  return { x = -cy * sz + sy * sx * cz, y = cx * cz, z = sy * sz + cy * sx * cz }
end
-- the blueprint's own numbers: CoM (wet), CoT, the engines below the lowest
-- axial decoupler (the ones that light at launch), their axes and torque
function DP.blueprint(bp, tag)
  local by = {}
  for _, d in ipairs(bp.parts) do by[d.uid] = d end
  local cut = math.huge
  for _, d in ipairs(bp.parts) do
    if (d.decouple or 0) == 1 and (d.radial or 0) ~= 1 and d.y < cut then cut = d.y end
  end
  local M, C = 0, { x = 0, y = 0, z = 0 }
  for _, d in ipairs(bp.parts) do
    local m = (d.mass or 0) + (d.fuel or 0) * (d.fuel_t or 0)
    M = M + m
    C.x, C.y, C.z = C.x + m * d.x, C.y + m * d.y, C.z + m * d.z
  end
  C = scl(C, 1 / M)
  local root = by[bp.root] or bp.parts[1]
  local F, T, th = { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }, 0
  local Ct = { x = 0, y = 0, z = 0 }
  for _, d in ipairs(bp.parts) do
    if (d.thrust or 0) > 0 and d.y < cut - 0.01 then
      local a = DP.axis(d)
      local f = d.thrust
      local r = sub(d, C)
      local Fv = scl(a, f)
      local t = cross(r, Fv)
      F = { x = F.x + Fv.x, y = F.y + Fv.y, z = F.z + Fv.z }
      T = { x = T.x + t.x, y = T.y + t.y, z = T.z + t.z }
      th = th + f
      Ct = { x = Ct.x + d.x * f, y = Ct.y + d.y * f, z = Ct.z + d.z * f }
      local rx, rz = d.x - root.x, d.z - root.z
      local rl = math.sqrt(rx * rx + rz * rz)
      local out, round = 0, 0
      if rl > 0.05 then
        out = (a.x * rx + a.z * rz) / rl
        round = (-a.x * rz + a.z * rx) / rl
      end
      P("DP ENG [%s] %d %s at (%.3f %.3f %.3f) r %.2f m, axis (%.4f %.4f %.4f): cant out %.2f° round %.2f°, %.0f kN, torque about CoM (%.1f %.1f %.1f) kN·m",
        tag, d.uid, d.id, d.x, d.y, d.z, rl, a.x, a.y, a.z, math.deg(math.asin(out)), math.deg(math.asin(round)), f, t.x, t.y, t.z)
    end
  end
  if th > 0 then Ct = scl(Ct, 1 / th) end
  P("DP VAB [%s] %d parts, %.2f t wet, CoM (%.3f %.3f %.3f), CoT (%.3f %.3f %.3f) — CoT off the CoM's vertical %.1f mm; thrust %.0f kN, lateral %.2f kN, torque about CoM pitch/yaw %.1f kN·m roll %.1f kN·m",
    tag, #bp.parts, M, C.x, C.y, C.z, Ct.x, Ct.y, Ct.z, 1000 * math.sqrt((Ct.x - C.x) ^ 2 + (Ct.z - C.z) ^ 2),
    math.sqrt(F.x ^ 2 + F.y ^ 2 + F.z ^ 2), math.sqrt(F.x ^ 2 + F.z ^ 2), math.sqrt(T.x ^ 2 + T.z ^ 2), T.y)
  return cut
end

local BOOSTER = { 107, 108, 109, 110, 115, 116, 117, 118, 119, 120, 121, 122, 124, 125, 126, 127 }

local function run_deep()
  DP.tag = ((params.straight or 0) > 0 and "straight" or "asbuilt") .. ((params.noarm or 0) > 0 and "_noarm" or "") .. ((params.sas or 1) == 0 and "_nosas" or "")
  local ok, raw = pcall(assets.readJson, "user://probe_deep.json")
  if not ok or type(raw) ~= "table" then P("DP no user://probe_deep.json"); return end
  local bp = DP.decode(raw.bp)
  if (params.straight or 0) > 0 then
    -- the booster stacks stood straight: no pitch or roll, each part on its
    -- tank's vertical (x, z of its tankM), heights kept
    local by = {}
    for _, d in ipairs(bp.parts) do by[d.uid] = d end
    local base = { [107] = { 107, 115, 119, 124 }, [108] = { 108, 116, 120, 125 }, [109] = { 109, 117, 121, 126 }, [110] = { 110, 118, 122, 127 } }
    for t, l in pairs(base) do
      for _, u in ipairs(l) do
        local d = by[u]
        d.pitch, d.roll = 0, 0
        d.x, d.z = by[t].x, by[t].z
      end
    end
  end
  DP.blueprint(bp, "file")
  local co = findScript("company")
  if co and co.earn then co.earn(80000, "probe") end
  local rs = findScript("research")
  for _, d in ipairs(bp.parts) do if rs and rs.grant then rs.grant(d.id, "probe") end end
  local BH = enter_vab("deep_enter")
  if not BH then P("DP RESULT no VAB"); return end
  local B = findScript("builder")
  wait(1.0)
  load_bp(B, "deep_bp", bp.parts, { links = bp.links, root = bp.root, v = bp.v or 2, name = bp.name })
  if B.setOverlayMode then B.setOverlayMode(1) end
  wait(1.5)
  local s = B.stats and B.stats()
  if s then
    P("DP VAB builder stats: %d parts, %.2f t, dry %.2f t, thrust %.0f, TWR %.2f (pad %.2f), dv %.0f (pad %.0f), CoM (%.3f %.3f %.3f) dry (%.3f %.3f %.3f) CoT (%.3f %.3f %.3f)",
      s.parts, s.mass, s.dry, s.thrust, s.twr, s.twr_sl or 0, s.dv, s.dv_sl or 0, s.com.x, s.com.y, s.com.z, s.comDry.x, s.comDry.y, s.comDry.z, s.cot.x, s.cot.y, s.cot.z)
    for _, w in ipairs(s.launch and s.launch.warn or {}) do P("DP VAB launch warning: %s", w) end
  end
  DP.shot("1vab")
  local bc = findScript("builder_camera")
  if bc and bc.frameCraft then pcall(bc.frameCraft); wait(1.0); if bc.settle then pcall(bc.settle) end; wait(0.3); DP.shot("1vab_framed") end
  if B.launchSite and B.launchSite() ~= "pad" and B.toggleLaunchSite then B.toggleLaunchSite() end
  B.doLaunch()
  wait(0.6)
  if BH.state == "building" then B.doLaunch() end
  local vc = wait_craft(#bp.parts, 150)
  if not vc then P("DP RESULT no craft"); return end
  local lbp = save.get("shipyard.blueprint")
  if lbp and lbp.parts then
    lbp = DP.decode(lbp)
    DP.blueprint(lbp, "launch")
    local by = {}
    for _, d in ipairs(lbp.parts) do by[d.uid] = d end
    for _, u in ipairs(BOOSTER) do
      local d = by[u]
      if d then P("DP LBP %d %s (%.3f %.3f %.3f) yaw %.4f pitch %.4f roll %.4f sym %s", u, d.id, d.x, d.y, d.z, d.yaw or 0, d.pitch or 0, d.roll or 0, tostring(d.sym)) end
    end
  end
  local vn = vc.node
  wait(1.5)
  DP.shot("2pad")
  local engs = {}
  for _, d in ipairs((lbp and lbp.parts) or bp.parts) do
    if (d.thrust or 0) > 0 then engs[#engs + 1] = { uid = d.uid, d = d, a = DP.axis(d) } end
  end
  if (params.noarm or 0) > 0 then
    -- the A/B: the pad's crew access arm (BasePad "Shell 32", the floor box
    -- 4.6 m over the deck that reaches to 2.4 m from the pad's axis) taken out
    local pad = find("BasePad")
    local gone = 0
    for _, c in ipairs(pad and pad:children() or {}) do
      if c.name == "Shell 32" then destroy(c); gone = gone + 1 end
    end
    P("DP noarm: %d access-arm collider(s) removed", gone)
    yield(); yield()
  end
  vc.releaseClamps()
  if (params.sas or 1) == 0 then vc.setSAS("off") else vc.setSAS("stability") end
  local t0 = time
  local lastw, lastt = nil, nil
  local secs = params.secs or 20
  local nextp, nshot = 0, 0
  local first_div = nil
  local maxtilt = 0
  while time - t0 < secs do
    vc.setThrottle(1)
    yield()
    if not vn.valid or vc.destroyed then P("DP craft gone at +%.1f", time - t0); break end
    local i = assembly.info(vn)
    local b = home()
    if i and b and i.right and i.up then
      local U = unit(sub(i.com, b))
      local R, Up = i.right, i.up
      local Z = cross(R, Up)
      local w = i.angVel
      local tilt = math.deg(math.acos(math.max(-1, math.min(1, dot(Up, U)))))
      maxtilt = math.max(maxtilt, tilt)
      local tnow = time
      -- every contact the craft had last tick (the first 2 s): which part, how hard, where
      if time - t0 < 2.0 and assembly.impacts then
        local im = assembly.impacts(vn) or {}
        local tot, list = 0, {}
        for _, c in ipairs(im) do
          tot = tot + (c.impulse or 0)
          if #list < 6 then
            local lp = sub({ x = c.x, y = c.y, z = c.z }, i.origin)
            list[#list + 1] = string.format("%s J %.1f v %.2f at craft (%.2f %.2f %.2f)", (type(c.part) == "table" and c.part.valid) and c.part.name or tostring(c.part), c.impulse or 0, c.speed or 0, dot(lp, R), dot(lp, Up), dot(lp, Z))
          end
        end
        if #im > 0 then P("DP C +%5.3f grounded %s contacts %d ΣJ %.1f: %s", time - t0, tostring(i.grounded), #im, tot, table.concat(list, " | ")) end
      end
      if time - t0 >= nextp then
        nextp = (time - t0 < 1.5) and (time - t0) or (nextp + 0.1)
        -- the thrust torque about the live CoM, every engine on its own axis
        local TL = vc.THRUST_LIVE or 0
        local Tsum, live = 0, {}
        for _, e in ipairs(engs) do
          local F = vc.partFrameNow and vc.partFrameNow(e.uid)
          if F then live[#live + 1] = { e = e, F = F }; Tsum = Tsum + e.d.thrust * (e.d.y < 5.8 and 1 or 0) end
        end
        local k = (Tsum > 0) and TL / Tsum or 0
        local tq = { x = 0, y = 0, z = 0 }
        for _, l in ipairs(live) do
          local e, F = l.e, l.F
          if e.d.y < 5.8 then
            local ax = { x = F.rx * e.a.x + F.ux * e.a.y + F.zx * e.a.z, y = F.ry * e.a.x + F.uy * e.a.y + F.zy * e.a.z, z = F.rz * e.a.x + F.uz * e.a.y + F.zz * e.a.z }
            local f = e.d.thrust * k
            local r = { x = F.ox - i.com.x, y = F.oy - i.com.y, z = F.oz - i.com.z }
            local t = cross(r, scl(ax, f))
            tq = { x = tq.x + t.x, y = tq.y + t.y, z = tq.z + t.z }
          end
        end
        -- the SAS's rate damper (stability: torque = 60·torque_k·(0 − ω), capped)
        local sas = (params.sas or 1) == 0 and { x = 0, y = 0, z = 0 } or scl(w, -60)
        -- I·α (world) from the last sample, and what nothing above explains
        local Ia, rest = { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }
        local I = i.inertia
        if lastw and tnow > lastt and I then
          local dt = tnow - lastt
          local al = { x = (w.x - lastw.x) / dt, y = (w.y - lastw.y) / dt, z = (w.z - lastw.z) / dt }
          Ia = { x = I[1].x * al.x + I[1].y * al.y + I[1].z * al.z, y = I[2].x * al.x + I[2].y * al.y + I[2].z * al.z, z = I[3].x * al.x + I[3].y * al.y + I[3].z * al.z }
          rest = { x = Ia.x - tq.x - sas.x, y = Ia.y - tq.y - sas.y, z = Ia.z - tq.z - sas.z }
        end
        lastw, lastt = { x = w.x, y = w.y, z = w.z }, tnow
        local function body(v) return dot(v, R), dot(v, Up), dot(v, Z) end
        local wp, wr, wy = body(w)
        local tp, tr, ty = body(tq)
        local sp, sr, sy = body(sas)
        local rp, rr, ry = body(rest)
        local S = body_state(vn)
        local ah = vc.AERO and vc.AERO.hud or {}
        local Ip = I and (I[1].x * R.x * R.x + I[2].y * R.y * R.y + I[3].z * R.z * R.z + 2 * (I[1].y * R.x * R.y + I[1].z * R.x * R.z + I[2].z * R.y * R.z)) or -1
        local Ir = I and (I[1].x * Up.x * Up.x + I[2].y * Up.y * Up.y + I[3].z * Up.z * Up.z + 2 * (I[1].y * Up.x * Up.y + I[1].z * Up.x * Up.z + I[2].z * Up.y * Up.z)) or -1
        P("DP T +%5.2f alt %6.1f V %6.1f tilt %5.1f° | ω p %6.3f y %6.3f r %6.3f rad/s | thrust τ p %7.1f y %7.1f r %7.1f | SAS τ p %7.1f y %7.1f r %7.1f | rest τ p %7.1f y %7.1f r %7.1f kN·m | q %s aoa %s | thrust %.0f kN mass %.2f t parts %d | I pitch %.0f roll %.0f t·m²",
          time - t0, S and S.alt or -1, S and S.V or -1, tilt, wp, wy, wr, tp, ty, tr, sp, sy, sr, rp, ry, rr,
          tostring(ah.q and string.format("%.2f", ah.q)), tostring(ah.aoa and string.format("%.1f", ah.aoa)), TL, i.mass, #i.parts, Ip, Ir)
        if not first_div and tilt > 10 then first_div = time - t0; P("DP tilt past 10° at +%.2f s", first_div) end
      end
      local SH = { 0.3, 0.7, 3 }
      if nshot < 3 and time - t0 >= SH[nshot + 1] then nshot = nshot + 1; DP.shot(string.format("%dflight%.1fs", nshot + 2, SH[nshot])) end
    end
  end
  P("DP RESULT %s: max tilt %.1f° in %.0f s, past 10° at %s s", DP.tag, maxtilt, secs, tostring(first_div))
end
