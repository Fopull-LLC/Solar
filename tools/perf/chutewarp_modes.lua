-- ── chute-warp probe (tools/perf/chutewarp.sh): Ty's 2026-11-10 playtest ─────
-- "warping with a parachute to get closer to the ground makes your craft start
-- spinning forever out of control, then you explode due to the angular
-- velocity when you land." Spliced into a copy of perfbench.lua. Modes:
--   chutewarp   the pod rocket hops, opens its chute, settles under it, then
--               warps ×10 (warp_chip.request, the keys' gate) for `warpsecs`
--               real seconds or until the warp drops, and lands
--   chuteland   the same flight with no warp: the ordinary chute landing
--   chutehill   chutewarp moved over the highest ground near the base first
--               (250 m over it), so the warp runs down toward a hilltop
--   coastwarp   the same hop with no chute: ×5 warp on the way up and down
--               above the air's 40 m rule, then down to ×1 (warp without a
--               chute; it crashes, which is fine — the spin is what counts)
-- One `CW` line every 0.25 s (alt, vertical speed, |ω|, warp, canopy, parts)
-- and `CW SUMMARY <mode>` with the peak |ω| before, during and after the warp,
-- the touchdown speed and whether the craft survived.
local CW = { tag = "cw" }
local function cw_w(i) local w = i and i.angVel; return w and len(w.x, w.y, w.z) or 0 end

local function cw_flight(o)
  -- (a craft held by the descent warp reads grounded to the engine)
  local function held() local cw = CW.vc and CW.vc.CHUTE_WARP; return cw and cw.on end
  CW.tag = o.tag
  local bp = rocket_bp(o.tanks or math.floor(params.cwtanks or 1))
  local vc = launch_in_vab(bp, "pad", #bp)
  if not vc then P("CW SUMMARY %s: no craft", o.tag) return end
  CW.vc = vc
  wait(1.0)
  tap("z")
  wait(0.3)
  tap("space")
  wait(0.8)
  if assembly.info(vc.node).anchored and vc.releaseClamps then vc.releaseClamps() end
  local t0 = time
  wait_for(function()
    local st = body_state(vc.node)
    -- cut when the coast would top out at burnAlt (alt + v²/2g, no drag)
    local g = st and st.mu / (st.r * st.r) or 9
    local apex = st and st.alt + math.max(0, st.vr) ^ 2 / (2 * g) or 0
    return apex > (o.burnAlt or 900) or time - t0 > (o.burnMax or 40) or (vc.fuel or 1) <= 0
  end, 60, "the burn")
  tap("x")
  if vc.setThrottle then vc.setThrottle(0) end
  local st = body_state(vc.node)
  P("CW %s: MECO alt %.0f vr %.1f", o.tag, st and st.alt or -1, st and st.vr or 0)
  local peak = { pre = 0, warp = 0, post = 0, land = 0 }
  local phase = "pre"
  local landed_v, lost, parts0 = nil, false, #assembly.info(vc.node).parts
  local warp_t, warp_end_t, chute_t = nil, nil, nil
  local last_log = -1
  local maxwarp = 1
  local warp_on = false
  local function sample()
    local i = vc.node and vc.node.valid and assembly.info(vc.node)
    if not i then return nil end
    local s = body_state(vc.node)
    local w = cw_w(i)
    if w > peak[phase] then peak[phase] = w end
    local wp = space.warp()
    if wp > maxwarp then maxwarp = wp end
    if time - last_log >= 0.25 then
      last_log = time
      local f = vc.chute_fill or {}
      local cw = vc.CHUTE_WARP
      P("CW %s %-4s alt %7.1f vr %7.1f |v| %6.1f |w| %6.2f warp %5.0f chute %s area %.2f parts %d grounded %s descent %s",
        o.tag, phase, s and s.alt or -1, s and s.vr or 0, s and s.V or 0, w, wp, tostring(vc.chutes_deployed), f.area or 0,
        #i.parts, tostring(i.grounded), cw and cw.on and string.format("%.1f m/s", cw.vt or 0) or "-")
    end
    return i, s, w
  end
  local tmo = time + (o.flightMax or 260)
  local chute_open = false
  while time < tmo do
    yield()
    if vc.isLost and vc.isLost() then lost = true break end
    local i, s, w = sample()
    if not i then lost = true break end
    -- the chute: on the way down, as a player would
    if o.chute and not chute_open and s and s.vr < -3 then
      tap("space")
      chute_open = true
      chute_t = time
      P("CW %s: chute staged at alt %.0f vr %.1f", o.tag, s.alt, s.vr)
    end
    -- the warp: under a full canopy (or at MECO + 1 s without one)
    if o.warp and not warp_t then
      local ready
      if o.chute then
        ready = chute_t and time - chute_t > (o.settle or 8) and (vc.chute_fill or {}).area and vc.chute_fill.area > (o.area or 0.3)
      else
        ready = time - t0 > 1.0 and s and s.alt > 60
      end
      if ready and o.hill and not CW.moved then
        -- over the highest ground in reach, 250 m above it: the engine's warp
        -- surface rule is the mean radius + 25 m, under a hill's top
        CW.moved = true
        local b = home()
        local u, t1, t2, R = base_frame()
        local best
        for k = 0, 11 do
          local ang = k * math.pi / 6
          local t = unit({ x = t1.x * math.cos(ang) + t2.x * math.sin(ang), y = t1.y * math.cos(ang) + t2.y * math.sin(ang), z = t1.z * math.cos(ang) + t2.z * math.sin(ang) })
          for _, d in ipairs({ 80, 160, 240, 320 }) do
            local dir = dir_at(u, t, d, R)
            local gr = ground_r(b, dir.x, dir.y, dir.z, b.radius + 600)
            if gr and (not best or gr > best.r) then best = { dir = dir, r = gr } end
          end
        end
        if best then
          local inf = assembly.info(vc.node)
          local off = sub(inf.origin, inf.com)
          local p = { x = b.x + best.dir.x * (best.r + 250), y = b.y + best.dir.y * (best.r + 250), z = b.z + best.dir.z * (best.r + 250) }
          assembly.teleport(vc.node, vec3(p.x + off.x, p.y + off.y, p.z + off.z))
          CW.hill = best.r - b.radius
          P("CW %s: moved over the hill: ground %.0f m over the datum, craft 250 m above it", o.tag, CW.hill)
        else
          P("CW %s: no hill found", o.tag)
        end
        chute_t = time
        ready = false
      end
      if ready then
        local wc = findScript("warp_chip")
        local ok, why = wc.request(o.warp)
        P("CW %s: warp ×%d requested at alt %.0f vr %.1f |w| %.2f: %s %s", o.tag, o.warp, s.alt, s.vr, w, tostring(ok), tostring(why))
        warp_t = time
        phase = "warp"
      end
    end
    if phase == "warp" then
      local hold_done = time - warp_t > (o.warpSecs or 6)
      if space.warp() > 1.001 then warp_on = true end
      if (warp_on and space.warp() <= 1.001) or hold_done or (not warp_on and time - warp_t > 1.0) then
        if space.warp() > 1.001 then space.warp(1) end
        P("CW %s: out of warp after %.1f s (%s) alt %.0f vr %.1f |w| %.2f", o.tag, time - warp_t,
          hold_done and "probe" or "dropped", s and s.alt or -1, s and s.vr or 0, w)
        phase = "post"
        warp_end_t = time
      end
    end
    if i.grounded and not held() and not landed_v and time - t0 > 5 then
      landed_v = s and s.V or -1
      P("CW %s: touchdown |v| %.1f |w| %.2f", o.tag, landed_v, w)
    end
    if i.grounded and not held() and s and math.abs(s.vr) < 0.6 and s.V < 1.0 and time - t0 > 5 then
      phase = "land"
      wait(3.0)
      sample()
      break
    end
  end
  local i = vc.node and vc.node.valid and assembly.info(vc.node)
  local parts1 = i and #i.parts or 0
  P("CW SUMMARY %s: peak |w| pre %.2f warp %.2f post %.2f landed %.2f; max warp %d; touchdown %s; parts %d -> %d; lost %s",
    o.tag, peak.pre, peak.warp, peak.post, peak.land, maxwarp, tostring(landed_v), parts0, parts1, tostring(lost or (vc.isLost and vc.isLost())))
end

local function run_chutewarp() cw_flight({ tag = "chutewarp", chute = true, warp = math.floor(params.cwwarp or 10), warpSecs = params.warpsecs or 6, burnAlt = params.burnalt or 3000 }) end
local function run_chutehill() cw_flight({ tag = "chutehill", chute = true, hill = true, warp = math.floor(params.cwwarp or 10), warpSecs = params.warpsecs or 15 }) end
local function run_chuteland() cw_flight({ tag = "chuteland", chute = true, tanks = 1, burnAlt = params.burnalt or 900 }) end
local function run_coastwarp() cw_flight({ tag = "coastwarp", chute = false, warp = 5, warpSecs = params.warpsecs or 4, burnAlt = params.burnalt or 3000, flightMax = 150 }) end
