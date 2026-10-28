-- ── fell probe (tools/perf/fellprobe.sh): felling trees with the terrain laser, as a player ──
-- Spliced into a copy of perfbench.lua after ivaprobe_modes.lua and
-- verifyprobe_modes.lua (V.*). Mode:
--   vfell   a new world: rings round the base searched for broadleaf, conifer,
--           palm and fungus stands; at each tree the crew stands 2–6 m off,
--           the CAMERA is turned until the crosshair (the screen's middle, the
--           mouse put there too) sits on the trunk at chest height, and the
--           trigger (input.simulate button 0) — or E for one tree — is held.
--           Logged: the saw's state, the prompt, the progress, the felling,
--           the log left, the plant gone from the field; the felled parts'
--           materials. Pictures: the cut under way (UI on), the tree coming
--           down, the felled tree lying by the standing ones.
-- `VP PASS|FAIL <check>` lines and `VP RESULT fell`; pictures in
-- $WORK/proj/save/user/vshots/fell_*.png.
local FP = {}
-- every tree kind the stands grow, and the giant fungi
FP.KINDS = { broadleaf = true, conifer = true, palm = true, fungus = true }

function FP.search(want, max_stops)
  -- out from the base on rings; at each stop, the plants within 25 m by kind
  local found, have = {}, 0
  local u, t1, t2, R = base_frame()
  local cl = findScript("climate")
  local stops = 0
  for _, dist in ipairs({ 90, 160, 240, 340, 460, 600 }) do
    for k = 0, 7 do
      if stops >= max_stops or have >= want then return found end
      local ang = k * math.pi / 4 + dist * 0.01
      local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang), z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
      local dir = dir_at(u, t, dist, R)
      local b = home()
      local gr = ground_r(b, dir.x, dir.y, dir.z, R + 150)
      local sea = cl and cl.seaRadius and cl.seaRadius(b.name) or 0
      if gr and gr > sea + 1 then
        stops = stops + 1
        stand_at({ dir = dir, r = gr })
        wait(2.5)
        local a = astro()
        local kinds = {}
        for _, q in ipairs(V.plants_near(a, 25)) do
          kinds[q.kind] = (kinds[q.kind] or 0) + 1
          if FP.KINDS[q.kind] and (q.height or 2) >= 2.0 then
            local L = found[q.kind] or {}
            found[q.kind] = L
            if #L == 0 then have = have + 1 end
            if #L < 4 then
              q.from = { x = a.x - home().x, y = a.y - home().y, z = a.z - home().z }
              L[#L + 1] = q
            end
          end
        end
        local kl = {}
        for kk, n in pairs(kinds) do kl[#kl + 1] = kk .. " " .. n end
        P("VP search %d m bearing %.0f: %s", dist, math.deg(ang), table.concat(kl, ", "))
      end
    end
  end
  return found
end

-- rotate v (square to U) about U by ang
local function rot(v, U, ang)
  local c, s = math.cos(ang), math.sin(ang)
  local w = cross(U, v)
  return { x = v.x * c + w.x * s, y = v.y * c + w.y * s, z = v.z * c + w.z * s }
end
local function flat(v, U) return unit(sub(v, scl(U, dot(v, U)))) end

-- The camera turned (planet_camera.face) until the screen's middle — the
-- crosshair — looks at the world point `T()` (asked each frame). One step a
-- frame; returns the angle left between the crosshair ray and the target.
FP.aim = { ref = nil, pitch = -0.15 }
function FP.aim_step(T)
  local pc = V.pc()
  local a = astro()
  local vx, vy, vw, vh = camera.screenRect()
  local cx, cy = vx + vw * 0.5, vy + vh * 0.5
  input.simulate { mouse = { cx, cy } }
  local ox, oy, oz, dx, dy, dz = camera.screenToRay(cx, cy)
  local U = V.up(a)
  local t = T()
  local w = unit({ x = t.x - ox, y = t.y - oy, z = t.z - oz })
  local d = unit({ x = dx, y = dy, z = dz })
  local A = FP.aim
  local hw = flat(w, U)
  if not A.ref then A.ref = hw; A.pitch = math.asin(math.max(-1, math.min(1, dot(w, U)))) end
  A.ref = flat(A.ref, U)
  local hd = flat(d, U)
  local ang = math.atan2(dot(cross(hd, hw), U), dot(hd, hw))
  A.ref = rot(A.ref, U, ang * 0.8)
  A.pitch = math.max(A.lo or -1.3, math.min(A.hi or 1.3, A.pitch + 0.8 * (math.asin(math.max(-1, math.min(1, dot(w, U)))) - math.asin(math.max(-1, math.min(1, dot(d, U)))))))
  pc.face(A.ref.x, A.ref.y, A.ref.z, A.pitch)
  return math.deg(math.acos(math.max(-1, math.min(1, dot(w, d))))), { x = ox, y = oy, z = oz }, d
end

-- the plant's trunk at height h, where it stands now
function FP.trunk(q, h)
  return function()
    local p = V.w(q)
    local U = V.up(p)
    return { x = p.x + U.x * h, y = p.y + U.y * h, z = p.z + U.z * h }
  end
end

-- the crew `D` m off the plant, on the side it was seen from, on the ground
function FP.place(q, D)
  local p = V.w(q)
  local b = home()
  local U = V.up(p)
  local from = q.from and { x = b.x + q.from.x, y = b.y + q.from.y, z = b.z + q.from.z } or astro()
  local away = flat(sub(from, p), U)
  local s = { x = p.x + away.x * D, y = p.y + away.y * D, z = p.z + away.z * D }
  local dir = unit(sub(s, b))
  local gr = ground_r(b, dir.x, dir.y, dir.z, len(s.x - b.x, s.y - b.y, s.z - b.z) + 30)
  stand_at({ dir = dir, r = gr or len(s.x - b.x, s.y - b.y, s.z - b.z) })
  FP.aim.ref = nil
end

function FP.flora_looks(tag)
  local ff = findScript("flora_field")
  local list = ff.fellingParts and ff.fellingParts() or {}
  for _, nd in ipairs(list) do
    local ok, m = pcall(function() return nd:material() end)
    local c = ok and m and m.color
    P("VP %s felled part '%s' model %s: material texture %s normal %s colour %s", tag, tostring(nd.name), tostring(nd.model),
      ok and m and tostring(m.texture) or "-", ok and m and tostring(m.normal_map or m.normalMap) or "-",
      c and string.format("%.2f %.2f %.2f", c[1] or c.r or 0, c[2] or c.g or 0, c[3] or c.b or 0) or "-")
  end
  P("VP %s: %d felled parts", tag, #list)
  return #list
end

-- the plants within 3 m of q's root (src, id, kind, metres)
function FP.around(q, tag)
  local ff = findScript("flora_field")
  local p = V.w(q)
  local A = ff.groundAudit(p.x, p.y, p.z, 3.0, 5)
  local o = {}
  for _, h in ipairs(A.props or {}) do
    if h.kind ~= "grass" then
      local si = ff.sourceInfo and ff.sourceInfo(h.src)
      o[#o + 1] = string.format("%s/%s %s %.2f m [%s]", tostring(h.src), tostring(h.id), h.kind, len(h.x - p.x, h.y - p.y, h.z - p.z),
        si and string.format("%s sp %s %s part %s made %.1f current %s%s", tostring(si.patch), tostring(si.spid), tostring(si.name), tostring(si.part),
          si.made or -1, tostring(si.current), si.retiring and " RETIRING" or "") or "not the field's")
    end
  end
  P("VP %s: within 3 m of the root: %s", tag, table.concat(o, "; "))
end

-- One tree: stand D m off, aim the crosshair at the trunk, hold the trigger
-- (how = "lmb") or E (how = "e"). Returns whether it came down and went.
function FP.cut(q, D, how, tag)
  local ff = findScript("flora_field")
  local tb = findScript("tool_belt")
  FP.place(q, D)
  wait(2.0)
  if V.gone(q) then return "skip" end
  local T = FP.trunk(q, 1.1)
  local err = 99
  for k = 1, 120 do
    err = FP.aim_step(T); yield()
    if k > 30 and err < 0.3 then break end
  end
  local a = astro()
  local root = V.w(q)
  P("VP %s: a %s %s %.1f m tall (id %s), crew %.1f m from its root, the crosshair %.2f° off the trunk at 1.1 m", tag, q.kind, tostring(q.name), q.height or -1, tostring(q.id),
    len(a.x - root.x, a.y - root.y, a.z - root.z), err)
  -- what the field says is on the crosshair (the tool asks the same)
  local _, o, d = FP.aim_step(T)
  local back = len(a.x - o.x, a.y - o.y, a.z - o.z)
  local np = ff.nearestPlant(o.x, o.y, o.z, d.x, d.y, d.z, tb.params.saw_reach + back, 2.0, tb.params.saw_grab,
    { from = { x = a.x, y = a.y, z = a.z }, reach = tb.params.saw_reach, crown = 4.0 })
  P("VP %s: on the crosshair: %s; the probe's plant %s/%s", tag, np and string.format("%s (%s, %.1f m tall), %.2f m off its axis, %s/%s patch %s, root %.2f m from the probe's",
    np.rec.sp.name, tostring(np.rec.sp.id), np.height, np.gap, tostring(np.rec.src), tostring(np.rec.inst), tostring(np.rec.patch),
    len(np.x - root.x, np.y - root.y, np.z - root.z)) or "nothing", tostring(q.src), tostring(q.id))
  FP.around(q, tag .. " before")
  local logs0 = ff.logCount()
  local fell0 = ff.felling()
  local seen, lastss = {}, nil
  local p0 = tb.prompt
  if how == "e" then key_down("e") else input.simulate { button = 0, down = true } end
  local t0 = time
  local mp, fell_t, shot_cut, maxfell = 0, nil, false, 0
  local aerr, ao = 0, nil
  while time - t0 < 16 do
    aerr, ao = FP.aim_step(T)
    yield()
    mp = math.max(mp, tb.progress or 0)
    local ss = tb.sawState and tb.sawState() or "?"
    ss = ss:gsub(" %d+%%$", "")
    local mode = (tb.cutMode and "CUT" or "DIG") .. (tb.cutAuto and "(auto)" or "")
    ss = mode .. " " .. ss
    if ss ~= lastss then
      local aa = astro()
      local rr = V.w(q)
      seen[#seen + 1] = string.format("%.1f %s [%s] (aim %.2f° off, camera %.1f m from the crew, crew %.1f m from the root)", time - t0, ss, tostring(tb.prompt),
        aerr or -1, ao and len(ao.x - aa.x, ao.y - aa.y, ao.z - aa.z) or -1, len(aa.x - rr.x, aa.y - rr.y, aa.z - rr.z))
      lastss = ss
    end
    if not shot_cut and (tb.progress or 0) >= 0.5 then shot_cut = true; V.shot("cut_" .. tag, true) end
    maxfell = math.max(maxfell, ff.felling() - fell0)
    if not fell_t and ff.felling() > fell0 then fell_t = time end
    if fell_t and time - fell_t > 0.25 then break end
  end
  if how == "e" then key_up("e") else input.simulate { button = 0, down = false } end
  P("VP %s: progress reached %.2f, %s; the states: %s", tag, mp, fell_t and string.format("felling began %.1f s in", fell_t - t0) or "nothing fell",
    table.concat(seen, " | "))
  P("VP %s: the prompt before the pull '%s'", tag, tostring(p0))
  if fell_t then
    -- the side view, from the player's own camera: the crew stepped out to
    -- the side of the fall (a teleport — the stand-in falls on regardless)
    -- and the view turned onto the falling tree
    local hgt = np and np.height or 6
    -- (all of it from the plant's planet-relative place, read now: `root`
    -- is a world point from seconds ago, metres off on a moving planet)
    local now = V.w(q)
    local U0 = V.up(now)
    local fd = flat(sub(now, a), U0)
    local sd = unit(cross(fd, U0))
    local rel = q.rel
    local function at(f, s_, u)
      local b = home()
      return { x = b.x + rel.x + fd.x * f + sd.x * s_ + U0.x * u, y = b.y + rel.y + fd.y * f + sd.y * s_ + U0.y * u,
               z = b.z + rel.z + fd.z * f + sd.z * s_ + U0.z * u }
    end
    local function stand(f, s_)
      local w = at(f, s_, 0)
      local b = home()
      local dir = unit(sub(w, b))
      local gr = ground_r(b, dir.x, dir.y, dir.z, len(w.x - b.x, w.y - b.y, w.z - b.z) + 30)
      stand_at({ dir = dir, r = gr or len(w.x - b.x, w.y - b.y, w.z - b.z) })
      FP.aim.ref = nil
    end
    FP.aim.lo, FP.aim.hi = -0.45, 0.25   -- (the orbit camera climbs as it pitches down: unclamped, the chase ran to straight down)
    stand(hgt * 0.35, math.max(7, hgt * 0.75))
    local mid = function() return at(hgt * 0.35, 0, 1.0) end
    while time - fell_t < 0.85 do FP.aim_step(mid); yield() end
    V.shot("falling_" .. tag, false)
    while time - fell_t < 1.6 do FP.aim_step(mid); yield() end
    V.shot("felled_" .. tag, false)
    -- close: by the fallen crown, the stump and the standing trees beyond
    stand(hgt * 0.55, 3.5)
    local crown = function() return at(hgt * 0.6, 0, 0.6) end
    while time - fell_t < 2.1 do FP.aim_step(crown); yield() end
    V.shot("felledclose_" .. tag, false)
    FP.flora_looks(tag)
  end
  wait(3.0)
  local gone = V.gone(q)
  local logs1 = ff.logCount()
  P("VP %s: the plant gone from the field %s; logs %d → %d", tag, tostring(gone), logs0, logs1)
  FP.around(q, tag .. " after")
  if fell_t and logs1 > logs0 then
    local r = V.w(q)
    local U = V.up(r)
    local fdir = flat(sub(r, a), U)
    local lp = function() return { x = r.x + fdir.x * 2.0, y = r.y + fdir.y * 2.0, z = r.z + fdir.z * 2.0 } end
    for _ = 1, 30 do FP.aim_step(function() r = V.w(q); return lp() end); yield() end
    V.shot("log_" .. tag, false)
  end
  FP.aim.lo, FP.aim.hi = nil, nil
  return fell_t ~= nil, gone, mp
end

local function run_vfell()
  V.tag = "fell"
  local Cc = findScript("crew")
  if Cc and Cc.setSafety then Cc.setSafety("invincible") end
  wait(4)
  -- what this world grows at all (flora_gen's cast for the home world)
  local fg, cl = findScript("flora_gen"), findScript("climate")
  local hb = home()
  local cast = fg and fg.speciesFor and fg.speciesFor(hb.name, cl and cl.worldOf and cl.worldOf(hb.name)) or {}
  local ck, trees = {}, {}
  for _, sp in ipairs(cast) do
    ck[#ck + 1] = string.format("%s=%s/%s(%.0fm)", tostring(sp.name), tostring(sp.kind), tostring(sp.shape), sp.height or 0)
    trees[sp.kind] = true
  end
  P("VP the world %s (seed %s) grows: %s", hb.name, tostring(params.seed), table.concat(ck, ", "))
  if ((params.fneed or 0) == 1 and not (trees.conifer or trees.palm)) or ((params.fneed or 0) == 2 and not trees.conifer) then
    P("VP no conifer or palm on this world: stopping"); V.result(); return
  end
  local found = FP.search(4, params.fstops or 22)
  local kl = {}
  for k, L in pairs(found) do kl[#kl + 1] = k .. " " .. #L end
  P("VP found: %s", table.concat(kl, ", "))
  V.select_tool("laser")
  local plan = {
    { "broadleaf", 1, 3.0, "lmb" }, { "conifer", 1, 4.5, "lmb" }, { "palm", 1, 3.5, "lmb" },
    { "broadleaf", 2, 2.0, "e" }, { "broadleaf", 3, 6.0, "lmb" }, { "conifer", 2, 6.0, "lmb" }, { "fungus", 1, 3.0, "lmb" }, { "fungus", 2, 3.0, "lmb" }, { "fungus", 3, 3.0, "e" },
  }
  for _, st in ipairs(plan) do
    local kind, i, D, how = st[1], st[2], st[3], st[4]
    local q = found[kind] and found[kind][i]
    if q then
      local tag = string.format("%s%d_%s_%.0fm", kind, i, how, D)
      local fell, gone, mp = FP.cut(q, D, how, tag)
      local tree = kind ~= "fungus"
      if fell == "skip" then P("VP the %s #%d is gone already (cut with an earlier one)", kind, i) else
      V.check(tag, (tree and fell or mp >= 0.95) and gone, "a %s %.0f m off, %s held on the trunk: progress %.2f, fell %s, gone from the field %s",
        kind, D, how == "e" and "E" or "the trigger", mp, tostring(fell), tostring(gone))
      end
    else
      P("VP no %s #%d found to cut", kind, i)
    end
  end
  V.result()
end
