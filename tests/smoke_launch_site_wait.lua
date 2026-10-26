-- SMOKE HARNESS: a launch WAITS for its site, and never drops a craft
-- (vessel_spawner's site gate).
--
-- In one bigpark run of five the 1,002-part craft was assembled over Launch
-- Complex 1 before base_facilities had put the pad down: the old gate asked
-- only for "something under the deck point" and the terrain 1.9 m below
-- answered it. On release the craft fell 15 m into the sea. The promises:
--
--   * the pad: nothing is assembled until rays through the craft's footprint
--     strike the pad's own structure (BasePad) at its deck height — terrain
--     under the pad does not count, nor a part of the pad far over the deck;
--   * the runway: nothing is assembled until the ground at the threshold is
--     final (terrain.ready) and where the site says it is;
--   * while it waits, it says so ("Waiting for the launch pad…");
--   * if the site never comes, the launch is called off after SITE_WAIT s
--     (SITE_WAIT_BASE while the base has not put its pad down at all): no
--     craft, the hull refunded, the crew home, a caption that says why.
--
--   luajit solar/tests/smoke_launch_site_wait.lua

local checks, failures = 0, {}
local function check(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end

local function deep(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = deep(v) end
  return o
end

-- One body at the origin, radius 100; the pad site on top (+Y), the runway
-- threshold 122 m round toward +X. The pad's deck tops out 2.49 m over the
-- site point; the terrain is 1.9 m under it. (The ground is the r 102 sphere.)
local PAD = { x = 0, y = 102, z = 0 }
local RWY = { x = 102 * math.sin(1.2), y = 102 * math.cos(1.2), z = 0 }
local DECK = 2.49

local BP = { name = "Kestrel I", parts = {
  { uid = 1, prefab = "PartPod", x = 0, y = 2.5, z = 0, h = 1.0, rx = 0.6, rz = 0.6, mass = 1 },
  { uid = 2, prefab = "PartTank", x = 0, y = 1.0, z = 0, h = 2.0, rx = 0.6, rz = 0.6, mass = 2 },
} }

-- A fresh world and a fresh vessel_spawner. `w` is what the test steers:
--   w.pad      "deck" (BasePad down, deck at DECK), "none", "high" (only a part
--              of the pad far over the deck answers), "narrow" (the deck only
--              under the centre)
--   w.sited    base_facilities.sited
--   w.ready    terrain.ready's answer
local function world(site, w)
  local W = { spawned = {}, captions = {}, hidden = 0, logs = {} }
  local next_id = 1
  local live = {}
  local function node(name, x, y, z, parent)
    local n = { id = next_id, name = name, valid = true, visible = true, tags_ = {}, kids = {},
                x = x or 0, y = y or 0, z = z or 0, parent = parent }
    next_id = next_id + 1
    n.children = function(self) local o = {} for _, c in ipairs(self.kids) do if c.valid then o[#o + 1] = c end end return o end
    n.addTag = function(self, tg) self.tags_[tg] = true end
    n.hasTag = function(self, tg) return self.tags_[tg] == true end
    n.setUp = function() end
    n.setAngles = function() end
    n.toWorld = function(self, v) return { x = self.x + v.x, y = self.y + v.y, z = self.z + v.z } end
    n.worldRight = function() return { x = 1, y = 0, z = 0 } end
    n.worldUp = function() return { x = 0, y = 1, z = 0 } end
    n.worldForward = function() return { x = 0, y = 0, z = -1 } end
    if parent then parent.kids[#parent.kids + 1] = n end
    live[#live + 1] = n
    return n
  end
  W.node = node
  local store = {}
  W.store = store
  local save = {
    get = function(k) return deep(store[k]) end,
    set = function(k, v) store[k] = deep(v) end,
    flush = function() return true end,
  }
  local body = { name = "Golil", x = 0, y = 0, z = 0, radius = 100, soi = 5000, mu = 1000 }
  local base_facilities = {
    sited = w.sited,
    launchSite = function(kind)
      if kind == "runway" then
        local l = math.sqrt(RWY.x ^ 2 + RWY.y ^ 2)
        return { body = "Golil", kind = "runway", x = RWY.x, y = RWY.y, z = RWY.z,
                 up = { x = RWY.x / l, y = RWY.y / l, z = 0 }, fwd = { x = 0, y = 0, z = 1 }, deck = false }
      end
      return { body = "Golil", kind = "pad", x = PAD.x, y = PAD.y, z = PAD.z,
               up = { x = 0, y = 1, z = 0 }, fwd = { x = 0, y = 0, z = 1 }, deck = true }
    end,
  }
  W.bf = base_facilities
  local company = { earn = function(a) store["co.funds"] = (store["co.funds"] or 0) + a end }
  local big_caption = {
    current = nil,
    show = function(t, s) W.captions[#W.captions + 1] = { t = t, s = s }; W.bc.current = t end,
    hide = function() W.hidden = W.hidden + 1; W.bc.current = nil end,
  }
  W.bc = big_caption
  local scripts = {
    company = company, big_caption = big_caption, base_facilities = base_facilities,
    flight_ops = { fleetOffline = function() return {} end, crewHome = function() return 30, 101.6, 0 end },
    game_manager = { loading = false }, planet_walker = { onFoot = false },
  }
  local astro = node("Astronaut", PAD.x, PAD.y + 3, PAD.z)
  astro.visible = false
  W.astro = astro
  local base_pad, deck, mast = nil, nil, nil
  function W.putPad()
    base_pad = node("BasePad", PAD.x, PAD.y + 16.5, PAD.z)
    deck = node("Shell 3", 0, -14.4, 0, base_pad)
    mast = node("Mast", 0, 10, 0, base_pad)
  end

  local env = setmetatable({}, { __index = _G })
  env.save = save
  env.log = function(s) W.logs[#W.logs + 1] = s end
  env.time = 0
  env.vec3 = function(x, y, z) return { x = x, y = y, z = z } end
  env.findScript = function(k) return scripts[k] end
  env.findScripts = function() return {} end
  env.findTagged = function() return {} end
  env.find = function(name)
    for _, n in ipairs(live) do if n.valid and n.name == name then return n end end
    return nil
  end
  env.destroy = function(n) n.valid = false end
  env.space = { body = function(n) return n == "Golil" and body or nil end, bodies = function() return { body } end }
  env.terrain = { warm = function() end, query = function() return 1 end,
                  ready = function() return w.ready ~= false end }
  -- Every ray the gate casts: over the pad site, the deck (if the pad is
  -- down and reaches there), else the terrain 1.9 m under the site; over the
  -- runway, the ground at the site.
  env.raycast = function(x, y, z, dx, dy, dz, max, opts)
    W.rays = (W.rays or 0) + 1
    local near_pad = math.abs(x - PAD.x) < 6 and math.abs(z - PAD.z) < 6 and y > PAD.y
    if near_pad then
      local centre = math.abs(x - PAD.x) < 0.1 and math.abs(z - PAD.z) < 0.1
      if base_pad and w.pad == "deck" or (base_pad and w.pad == "narrow" and centre) then
        return { distance = y - (PAD.y + DECK), x = x, y = PAD.y + DECK, z = z, node = deck }
      elseif base_pad and w.pad == "high" then
        return { distance = math.max(0.1, y - (PAD.y + 9)), x = x, y = PAD.y + 9, z = z, node = mast }
      end
      return { distance = y - (PAD.y - 1.9), x = x, y = PAD.y - 1.9, z = z } -- the terrain
    end
    local l = math.sqrt(x * x + y * y + z * z)
    return { distance = l - 102, x = x, y = y, z = z }
  end
  env.spawn = function(prefab, p, cb, parent)
    local n = node(prefab, p.x, p.y, p.z, parent)
    W.spawned[#W.spawned + 1] = prefab
    if cb then cb(n) end
    return n
  end
  env.assembly = { rebuild = function() end, setAnchored = function() end, teleport = function() end,
                   info = function() return { anchored = true } end }

  local chunk = assert(loadfile("solar/scripts/vessel_spawner.lua"))
  setfenv(chunk, env)
  chunk()
  env.params = {}
  for k, v in pairs(env.defaults) do env.params[k] = v end
  W.VS = env
  W.env = env
  W.SP = node("Vessel Spawner")
  store["shipyard.blueprint"] = BP
  store["shipyard.site"] = site
  store["shipyard.launch"] = 1
  store["shipyard.pilot"] = 1
  store["shipyard.spent"] = 800
  store["co.funds"] = 5000
  if w.pad and w.pad ~= "none" and w.padNow then W.putPad() end
  function W.tick(dt)
    env.time = env.time + (dt or 0.5)
    W.VS.update(W.SP, dt or 0.5)
  end
  function W.run(secs, dt)
    local n = math.floor(secs / (dt or 0.5) + 0.5)
    for _ = 1, n do W.tick(dt) end
  end
  function W.vessels()
    local c = 0
    for _, p in ipairs(W.spawned) do if p == "Vessel" then c = c + 1 end end
    return c
  end
  return W
end

-- ── 1. the gate itself ───────────────────────────────────────────────────────
do
  local W = world("pad", { pad = "deck", sited = true, padNow = true })
  local VS = W.VS
  check(VS.SITE_WAIT == 30.0 and VS.SITE_WAIT_BASE == 180.0, "the waits are 30 s, and 180 s while the base is still going up")
  check(VS.siteGate(0, true, false) == "go", "a ready site goes")
  check(VS.siteGate(100, true, true) == "go", "a ready site goes however long it took")
  check(VS.siteGate(29.9, false, false) == "wait", "a site not there yet waits")
  check(VS.siteGate(30.0, false, false) == "refuse", "...and is called off after SITE_WAIT")
  check(VS.siteGate(60, false, true) == "wait", "while the base has not put its pad down it waits longer")
  check(VS.siteGate(179, false, true) == "wait", "...a new save's base grading for minutes is waited for")
  check(VS.siteGate(180, false, true) == "refuse", "...but not for ever")
  check(VS.siteGate(100, false, false, 10) == "wait", "the base just finished: SITE_WAIT counts from then, not from the first look")
  check(VS.siteGate(100, false, false, 30) == "refuse", "...and then it is called off")
end

-- ── 2. the pad is down: the launch goes at once ──────────────────────────────
do
  local W = world("pad", { pad = "deck", sited = true, padNow = true })
  W.VS.start(W.SP)
  W.tick()
  check(W.vessels() == 1, "the pad down and clear: the craft assembles on the first look")
  check(W.VS.waitingFor == nil and #W.captions == 0, "...with no waiting caption")
end

-- ── 3. the pad comes in late (the bigpark race): the launch waits for it ────
do
  local W = world("pad", { pad = "deck", sited = false })
  W.VS.start(W.SP)
  W.run(4.0)
  check(W.vessels() == 0, "terrain under the site but no pad: nothing is assembled (the old gate went here)")
  check(W.VS.launchState() == "waiting", "the launch reads waiting")
  check(W.VS.waitingFor == "Waiting for the launch pad…", "it says what it waits for: " .. tostring(W.VS.waitingFor))
  check(#W.captions == 1 and W.captions[1].t == "WAITING FOR THE LAUNCH PAD"
    and W.captions[1].s == "Waiting for the launch pad…", "the waiting caption is up, once")
  W.run(40.0)
  check(W.vessels() == 0 and W.VS.launchState() == "waiting",
    "past SITE_WAIT while the base has not put its pad down: still waiting, nothing dropped")
  W.putPad()
  W.tick()
  check(W.vessels() == 1, "the pad down: the craft assembles")
  check(W.VS.waitingFor == nil and W.hidden == 1, "the waiting words and caption come down")
  check(W.store["shipyard.spent"] == 800, "...and nothing was refunded: the launch went ahead")
end

-- ── 4. the pad never comes: called off, refunded, the crew home ─────────────
do
  local W = world("pad", { pad = "deck", sited = true })
  W.VS.start(W.SP)
  W.run(29.0)
  check(W.vessels() == 0 and W.VS.launchState() == "waiting", "the base sited but no pad yet: waiting at 29 s")
  W.run(2.0)
  check(W.vessels() == 0, "the pad never came: nothing was assembled")
  check(W.VS.launchState() == nil, "the launch is over")
  check(W.store["co.funds"] == 5800 and W.store["shipyard.spent"] == 0, "the hull is refunded")
  check(W.store["shipyard.pilot"] == 0 and W.astro.visible == true and W.astro.x == 30, "the crew is brought home, in view")
  local last = W.captions[#W.captions]
  check(last and last.t == "PAD NOT READY" and last.s:find("refunded", 1, true), "a caption says why: " .. tostring(last and last.s))
  check(W.VS.lastRefusal and W.VS.lastRefusal.what == "unready", "lastRefusal names it (probes)")
  W.run(10.0)
  check(W.vessels() == 0, "and nothing turns up later")
end

-- ── 5. the base never puts the pad down: 180 s, then called off ─────────────
do
  local W = world("pad", { pad = "deck", sited = false })
  W.VS.start(W.SP)
  W.run(170.0)
  check(W.VS.launchState() == "waiting", "the base still going up: waiting at 170 s")
  W.run(12.0)
  check(W.VS.launchState() == nil and W.vessels() == 0 and W.store["shipyard.spent"] == 0,
    "...called off by SITE_WAIT_BASE, refunded")
end

-- ── 5b. a NEW save: the base sited but still grading its ground for two
-- minutes, the runway off its site until the grade lands — the first launch
-- waits it out and goes; it is never called off ───────────────────────────
do
  local w = { pad = "none", sited = true, ready = true }
  local W = world("runway", w)
  local grading = true
  W.bf.grading = function() return grading end
  local real = W.env.raycast
  -- the ground 4.9 m under the site until the grade is done
  W.env.raycast = function(x, y, z, dx, dy, dz, max, opt)
    local h = real(x, y, z, dx, dy, dz, max, opt)
    if h and grading and h.distance then h = { distance = h.distance + 4.9, node = h.node, x = h.x, y = h.y, z = h.z } end
    return h
  end
  W.VS.start(W.SP)
  W.run(120.0)
  check(W.vessels() == 0 and W.VS.launchState() == "waiting", "grading for 120 s: the first launch is still waiting, not refused")
  grading = false
  W.tick()
  check(W.vessels() == 1, "the grade lands: the craft rolls out")
  check(W.store["shipyard.spent"] == 800, "...and nothing was refunded")
end

-- ── 5c. the grade done but the site still wrong: SITE_WAIT from then ───────
do
  local w = { pad = "none", sited = true, ready = true }
  local W = world("runway", w)
  local grading = true
  W.bf.grading = function() return grading end
  local real = W.env.raycast
  W.env.raycast = function(x, y, z, dx, dy, dz, max, opt)
    local h = real(x, y, z, dx, dy, dz, max, opt)
    if h and h.distance then h = { distance = h.distance + 4.9, node = h.node, x = h.x, y = h.y, z = h.z } end
    return h
  end
  W.VS.start(W.SP)
  W.run(100.0)
  grading = false
  W.run(20.0)
  check(W.VS.launchState() == "waiting", "20 s after the grade: still waiting (SITE_WAIT counts from the grade)")
  W.run(12.0)
  check(W.VS.launchState() == nil and W.vessels() == 0, "...then called off, nothing built over the wrong ground")
end

-- ── 6. only part of the pad answers ─────────────────────────────────────────
do
  local W = world("pad", { pad = "high", sited = true, padNow = true })
  W.VS.start(W.SP)
  W.run(5.0)
  check(W.vessels() == 0, "a part of the pad 9 m over the site is not its deck: waiting")
  local W2 = world("pad", { pad = "narrow", sited = true, padNow = true })
  W2.VS.start(W2.SP)
  W2.run(5.0)
  check(W2.vessels() == 0, "the deck under the centre only, not under the footprint: waiting")
end

-- ── 7. the runway: final ground first ───────────────────────────────────────
do
  local w = { pad = "none", sited = true, ready = false }
  local W = world("runway", w)
  W.VS.start(W.SP)
  W.run(5.0)
  check(W.vessels() == 0, "the threshold's ground not final yet: waiting")
  check(W.VS.waitingFor == "Waiting for the runway…", "it says the runway: " .. tostring(W.VS.waitingFor))
  w.ready = true
  W.tick()
  check(W.vessels() == 1, "the ground final: the craft rolls out")
end

-- ── 8. a launch in place (from the VAB) waits the same way ──────────────────
do
  local W = world("pad", { pad = "deck", sited = true })
  W.store["shipyard.launch"] = 0
  W.VS.start(W.SP)
  local ok = W.VS.launchNow("pad", { bp = BP })
  check(ok == true and W.VS.launchState() == "waiting", "launchNow starts a rollout")
  W.run(3.0)
  check(W.vessels() == 0, "...that waits for the pad")
  W.putPad()
  W.tick()
  check(W.vessels() == 1, "...and assembles once it is there")
end

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL: " .. f) end
  print(string.format("launch site wait smoke: %d of %d checks failed", #failures, checks))
  os.exit(1)
end
print(string.format("launch site wait smoke: %d checks passed", checks))
