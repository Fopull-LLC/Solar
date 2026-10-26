-- SMOKE HARNESS: the launch site check and REVERT TO LAUNCH (vessel_spawner).
--
-- Two promises are held here.
--
-- A BLOCKED SITE REFUSES. A craft left on the pad, the debris a craft shed
-- there, or a parked craft the fleet has not rebuilt yet: launching onto any of
-- them is called off with a notice that names it, the hull comes back, and
-- nothing is deleted. The pad and the runway are separate sites, so a craft on
-- one never stops a launch from the other.
--
-- A REVERT PUTS THE GAME BACK AS IT WAS AT THE LAUNCH. Money, the ledger,
-- the inventories (the new craft's hold too), contracts and research are the
-- launch-time values; every craft and piece the flight put in the world is
-- taken away (and only those); the same design rolls out on the same site. And
-- it is only there while the flight is fresh: money coming in, a contract paid
-- or flying another craft takes it away.
--
--   luajit solar/tests/smoke_revert.lua

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

-- ── the world ───────────────────────────────────────────────────────────────
-- One body at the origin, radius 100; the pad on top (+Y), the runway 120 m
-- round toward +X. Nodes are flat (world == local) except parts, which sit
-- under their root.
local body = { name = "Golil", x = 0, y = 0, z = 0, radius = 100, soi = 5000, mu = 1000 }
local PAD = { x = 0, y = 102, z = 0 }
local RWY = { x = 120 * math.sin(1.2), y = 102 * math.cos(1.2), z = 0 }

local next_id = 1
local live = {}
local destroyed = {}
local function node(name, x, y, z, parent)
  local n = { id = next_id, name = name, valid = true, visible = true, tags_ = {}, kids = {},
              x = x or 0, y = y or 0, z = z or 0, parent = parent }
  next_id = next_id + 1
  n.worldPos = nil
  setmetatable(n, { __index = function(t, k)
    if k == "worldPos" then
      local p = rawget(t, "parent")
      if p then return { x = p.x + t.x, y = p.y + t.y, z = p.z + t.z } end
      return { x = t.x, y = t.y, z = t.z }
    elseif k == "tags" then
      local o = {}
      for tg in pairs(t.tags_) do o[#o + 1] = tg end
      return o
    end
  end })
  n.children = function(self) local o = {} for _, c in ipairs(self.kids) do if c.valid then o[#o + 1] = c end end return o end
  n.addTag = function(self, tg) self.tags_[tg] = true end
  n.hasTag = function(self, tg) return self.tags_[tg] == true end
  n.toWorld = function(self, v) return { x = self.x + v.x, y = self.y + v.y, z = self.z + v.z } end
  n.setUp = function() end
  n.setAngles = function() end
  n.worldRight = function() return { x = 1, y = 0, z = 0 } end
  n.worldUp = function() return { x = 0, y = 1, z = 0 } end
  n.worldForward = function() return { x = 0, y = 0, z = -1 } end
  if parent then parent.kids[#parent.kids + 1] = n end
  live[#live + 1] = n
  return n
end

local function kill(n)
  n.valid = false
  destroyed[n.id] = true
  for _, c in ipairs(n.kids) do kill(c) end
end

-- ── the save ────────────────────────────────────────────────────────────────
local store = {}
local save = {
  get = function(k) return deep(store[k]) end,
  set = function(k, v) store[k] = deep(v) end,
  delete = function(k) local had = store[k] ~= nil; store[k] = nil; return had end,
  flush = function() return true end,
}

-- ── other scripts ───────────────────────────────────────────────────────────
local ledger_t = 0
local company = {
  earn = function(a, why)
    store["co.funds"] = (store["co.funds"] or 0) + a
    local l = store["co.ledger"] or {}
    l[#l + 1] = { amount = a, why = why, t = ledger_t }
    store["co.ledger"] = l
  end,
}
local captions = {}
local big_caption = { show = function(t, s) captions[#captions + 1] = { t = t, s = s } end }
local base_facilities = {
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
local offline = {}
local forgot = {}
local flight_ops = {
  fleetOffline = function() return offline end,
  crewHome = function() return 30, 101.6, 0 end,
  forgetNodes = function(ids) for _, id in ipairs(ids) do forgot[#forgot + 1] = id end return #ids end,
}
local reloaded = 0
local missions = { reloadFromSave = function() reloaded = reloaded + 1 end }
local research = { spent = 0 }
local game_manager = { loading = false, inputOwner = nil }
local planet_walker = { onFoot = false }
local build_host = { mode = "world", state = "idle", entered = 0 }
build_host.enter = function() build_host.entered = build_host.entered + 1; return true end

-- craft controllers: { node, craftName, piloting, crewAboard, ... }
local controllers = {}
local function controller(name, root)
  local v = { node = root, craftName = name, piloting = false, crewAboard = false, dock = { latched = 0 } }
  v.standDown = function() v.piloting, v.crewAboard, v.stood = false, false, true end
  v.releaseControl = function() v.piloting = false end
  v.isLost = function() return false end
  controllers[#controllers + 1] = v
  return v
end

local astro = node("Astronaut", 30, 101.6, 0)
local vab = node("VabInterior", -40, 101, 0)

local scripts = {
  company = company, big_caption = big_caption, base_facilities = base_facilities,
  flight_ops = flight_ops, missions = missions, research = research,
  game_manager = game_manager, planet_walker = planet_walker, build_host = build_host,
}

local env = setmetatable({}, { __index = _G })
env.save = save
env.log = function() end
env.time = 0
env.vec3 = function(x, y, z) return { x = x, y = y, z = z } end
env.findScript = function(k) return scripts[k] end
env.findScripts = function(k)
  if k ~= "vessel_controller" then return {} end
  local o = {}
  for _, v in ipairs(controllers) do if v.node.valid then o[#o + 1] = v end end
  return o
end
env.findTagged = function(tg)
  local o = {}
  for _, n in ipairs(live) do if n.valid and n.tags_[tg] then o[#o + 1] = n end end
  return o
end
env.find = function(name)
  for _, n in ipairs(live) do if n.valid and n.name == name then return n end end
  return nil
end
env.destroy = kill
env.space = { body = function(n) return n == "Golil" and body or nil end, bodies = function() return { body } end,
              warp = function() return 1 end }
-- The ground is in (the site's ray hits, the field answers), and a spawn lands
-- at once: a launch assembles on the next update.
env.terrain = { warm = function() end, query = function() return 1 end }
-- Launch Complex 1 stands on the pad site: its deck (Shell 3, under BasePad)
-- tops out 2.49 m over the site point, and the spawner looks for it there.
local base_pad = node("BasePad", PAD.x, PAD.y + 16.5, PAD.z)
local pad_deck = node("Shell 3", 0, -14.4, 0, base_pad)
env.raycast = function(x, y, z)
  if math.abs(x - PAD.x) < 5 and math.abs(z - PAD.z) < 5 and y > PAD.y + 2.49 and y < PAD.y + 60 then
    return { distance = y - (PAD.y + 2.49), x = x, y = PAD.y + 2.49, z = z, node = pad_deck }
  end
  return { distance = 40, x = x, y = y - 40, z = z }
end
local spawned = {}
env.spawn = function(prefab, p, cb, parent)
  local n = node(prefab, p.x - (parent and parent.x or 0), p.y - (parent and parent.y or 0), p.z - (parent and parent.z or 0), parent)
  spawned[#spawned + 1] = n
  if cb then cb(n) end
  return n
end
env.assembly = {
  rebuild = function() end, setAnchored = function() end, teleport = function() end,
  info = function() return { anchored = true } end,
}

local chunk = assert(loadfile("solar/scripts/vessel_spawner.lua"))
setfenv(chunk, env)
chunk()
env.params = {}
for k, v in pairs(env.defaults) do env.params[k] = v end
local VS = env
local SP = node("Vessel Spawner")
VS.start(SP)

local function tick(dt)
  env.time = env.time + (dt or 0.6)
  VS.update(SP, dt or 0.6)
end

-- A craft standing at a world point: a root with a controller and parts that
-- carry the craft tag (+ a flight tag when given).
local function craft_at(name, p, tag)
  local root = node("Vessel", p.x, p.y + 1, p.z)
  for i = 0, 2 do
    local part = node("PartTank", 0, i * 1.2, 0, root)
    part:addTag("craftpart")
    if tag then part:addTag(tag) end
  end
  return controller(name, root), root
end

local BP = { name = "Kestrel I", parts = {
  { uid = 1, prefab = "PartPod", x = 0, y = 2.5, z = 0, h = 1.0, rx = 0.6, rz = 0.6, mass = 1 },
  { uid = 2, prefab = "PartTank", x = 0, y = 1.0, z = 0, h = 2.0, rx = 0.6, rz = 0.6, mass = 2 },
} }

-- The launch-time state.
store["co.funds"] = 5000
store["co.ledger"] = { { amount = 20000, why = "seed", t = -10 }, { amount = -800, why = "hull rollout", t = -1 } }
store["co.rep"] = 3
store["res.done"] = { basic = true }
store["res.spent"] = 100
store["mission.active"] = "first"
store["mission.seen"] = {}
store["mission.done"] = { tutorial = true }
store["mission.gcount"] = 2
store["inv.base"] = { iron = 40 }
store["inv.astro"] = { ice = 2 }
store["inv.cap"] = { ["hold:Old Barge"] = 500 }
store["inv.hold:Old Barge"] = { iron = 5 }
store["names.n"] = 4
store["shipyard.blueprint"] = BP
store["shipyard.spent"] = 800
store["shipyard.pilot"] = 1

-- ── 1. the site check ───────────────────────────────────────────────────────
check(VS.siteBlocker("pad", BP) == nil, "a clear pad is clear")
local barge, barge_root = craft_at("Old Barge", PAD)
local info = VS.siteBlocker("pad", BP)
check(info and info.what == "craft" and info.name == "Old Barge", "a craft standing on the pad blocks it, by name")
check(VS.siteBlocker("runway", BP) == nil, "...but not the runway, 120 m away")
local why = VS.launchBlockedWhy("pad", BP)
check(why and why:find("Old Barge", 1, true) and why:find("Tracking Station", 1, true),
  "the builder's sentence names it and says where to recover it: " .. tostring(why))

-- A launch onto it is called off: nothing deleted, the hull refunded, the crew home.
astro.visible = false
local ok, reason = VS.launchNow("pad")
check(ok == false and reason == "blocked", "launchNow refuses the blocked pad")
check(barge_root.valid, "...and leaves the craft where it is")
check(#captions == 1 and captions[1].t == "PAD BLOCKED" and captions[1].s:find("Old Barge", 1, true),
  "the refusal is a caption naming the craft")
check(store["co.funds"] == 5800 and store["shipyard.spent"] == 0, "the hull charged at rollout comes back")
check(store["shipyard.pilot"] == 0 and astro.visible == true and astro.x == 30, "the crew is brought home, in view")
check(VS.launchState() == nil and not VS.canRevert(), "nothing is launching, and there is nothing to revert")

-- Debris on the pad: a piece with the craft tag and no controller.
kill(barge_root)
local junk_root = node("Vessel (stage)", PAD.x + 2, PAD.y + 0.5, PAD.z)
local junk = node("PartTank", 0, 0, 0, junk_root)
junk:addTag("craftpart")
info = VS.siteBlocker("pad", BP)
check(info and info.what == "debris", "a shed stage on the pad blocks it as debris")
kill(junk_root)
-- A parked craft the fleet has not put back yet.
offline = { { fid = "c1", name = "Rover 2", wx = PAD.x + 1, wy = PAD.y, wz = PAD.z, parts = {} } }
info = VS.siteBlocker("pad", BP)
check(info and info.what == "parked" and info.name == "Rover 2", "a fleet record waiting to be rebuilt on the pad blocks it")
offline = {}
-- The crew on foot on the pad (not the crew going out to board).
planet_walker.onFoot = true
store["shipyard.pilot"] = 0
astro.x, astro.y, astro.z = PAD.x, PAD.y, PAD.z
info = VS.siteBlocker("pad", BP)
check(info and info.what == "crew", "the crew standing on the pad blocks it")
astro.x, astro.y, astro.z = 30, 101.6, 0
planet_walker.onFoot = false

-- A craft on the RUNWAY doesn't stop a pad launch.
local plane, plane_root = craft_at("Skylark", RWY)
check(VS.siteBlocker("runway", BP) ~= nil, "a plane on the runway blocks the runway")
store["co.funds"] = 5000
store["shipyard.spent"] = 800
store["shipyard.pilot"] = 1
captions = {}
ok = VS.launchNow("pad")
check(ok == true and VS.launchState() == "waiting", "a pad launch goes ahead while the runway is taken")
check(#captions == 0, "...with no notice")
check(VS.canRevert(), "a launch is revertable from the start")

-- ── 2. the flight ───────────────────────────────────────────────────────────
local snap_funds = store["co.funds"]
local snap_ledger = #store["co.ledger"]
tick()  -- the site's ground answers: the clamps go down and the craft assembles
local tag = VS.flightTag and VS.flightTag()
check(tag ~= nil, "the flight has a tag")
local ship_root, clamps = nil, nil
for _, n in ipairs(spawned) do
  if n.name == "Vessel" then ship_root = n end
  if n.name == "PadClamps" then clamps = n end
end
check(ship_root and #ship_root:children() == 2, "the craft assembled on the pad")
local tagged = 0
for _, c in ipairs(ship_root and ship_root:children() or {}) do
  if c:hasTag(tag) and c:hasTag("craftpart") then tagged = tagged + 1 end
end
check(tagged == 2, "every part it put down carries the flight's tag and the craft tag")
check(VS.launchState() == "ready", "...and it is clamped, ready")
local ship = controller("Kestrel I", ship_root)
ship.piloting, ship.crewAboard = true, true
-- it staged: the spent stage is a root of its own, and its part keeps the tags
local stage_root = node("Vessel (stage)", 5, 140, 0)
local sp1 = ship_root:children()[1]
sp1.parent = stage_root; stage_root.kids[1] = sp1; table.remove(ship_root.kids, 1)
-- and a crash shed a piece
local shard_root = node("Vessel (stage)", 8, 101, 0)
local sh1 = node("PartFin", 0, 0, 0, shard_root)
sh1:addTag("craftpart"); sh1:addTag(tag)
-- a part left on the craft, for the revert to find it by
local keep = node("PartPod", 0, 2, 0, ship_root)
keep:addTag("craftpart"); keep:addTag(tag)
tick()
check(VS.canRevert(), "staging and flying keep the flight revertable")
-- Progress made during the flight: spending, the hold filled, a goal ticked.
store["co.funds"] = snap_funds - 300
local l = store["co.ledger"]; l[#l + 1] = { amount = -300, why = "parts", t = env.time }; store["co.ledger"] = l
store["inv.cap"]["hold:Kestrel I"] = 200
store["inv.hold:Kestrel I"] = { ore = 12 }
store["inv.astro"] = { ice = 2, iron = 30 }
store["inv.base"] = nil
store["mission.seen"] = { [1] = true }
store["res.done"] = { basic = true, chutes = true }
store["res.spent"] = 400
store["names.n"] = 5

-- ── 3. revert ───────────────────────────────────────────────────────────────
local q = VS.revertQuote()
check(q and q.ok and q.builder, "revert is offered (to launch, and to the builder)")
check(VS.revertClick("launch") == false and VS.revertArmed("launch"), "the first click arms it")
check(VS.revertLabel("launch"):find("Progress since launch is lost", 1, true), "...and the row asks: " .. VS.revertLabel("launch"))
local ok2 = VS.revertClick("launch")
check(ok2 == true, "the second click reverts")
check(store["co.funds"] == snap_funds and #store["co.ledger"] == snap_ledger, "money and the ledger are as at launch")
check(store["inv.hold:Kestrel I"] == nil and (store["inv.cap"] or {})["hold:Kestrel I"] == nil,
  "the new craft's hold is put away")
check(store["inv.hold:Old Barge"] and store["inv.hold:Old Barge"].iron == 5, "...an older craft's hold kept as it was")
check(store["inv.astro"].iron == nil and store["inv.astro"].ice == 2 and store["inv.base"].iron == 40,
  "the suit pack and the warehouse are as at launch")
check(next(store["mission.seen"]) == nil and reloaded == 1, "contract progress is as at launch, and missions re-read it")
check(store["res.done"].chutes == nil and research.spent == 100, "research is as at launch")
check(store["names.n"] == 4, "the craft numbering is as at launch")
check(not ship_root.valid and not stage_root.valid and not shard_root.valid, "the craft, its stage and its debris are gone")
check(clamps and not clamps.valid, "...and the launch's hold-downs are taken up")
check(plane_root.valid, "...and nothing else: the plane on the runway stays")
check(ship.stood == true, "the crew was taken out of the seat first")
check(#forgot == 3, "the fleet board forgets the flight's pieces")
check(VS.launchState() == "waiting" and store["shipyard.pilot"] == 1 and astro.visible == false and astro.y > 104,
  "the same design rolls out again with the crew waiting to board on the pad")
tick()
check(VS.launchState() == "ready", "...and assembles")
check(store["shipyard.blueprint"].name == "Kestrel I" and store["shipyard.spent"] == 800, "the same design, the same hull price")
check(captions[#captions] and captions[#captions].t == "REVERTED TO LAUNCH", "the revert says so")
check(VS.canRevert(), "the relaunch is itself revertable")

-- ── 4. freshness ────────────────────────────────────────────────────────────
-- Money coming in (a contract paid, a recovery) takes revert away.
ledger_t = env.time + 1
tick()
company.earn(2500, "contract: First Flight")
tick()
check(not VS.canRevert() and VS.revertQuote() == nil, "once rewards are banked there is no revert")
check(VS.revertGone and VS.revertGone:find("money", 1, true), "...and it says why: " .. tostring(VS.revertGone))

-- Flying another craft takes it away too.
store["shipyard.pilot"] = 1
check(VS.launchNow("pad", { force = true }), "another launch")
tick()
check(VS.canRevert(), "...revertable")
plane.piloting = true
tick()
check(not VS.canRevert(), "taking control of another craft ends the revert")
plane.piloting = false

-- Revert to the builder hands the hull back.
VS.launchNow("pad", { force = true })
tick()
local before = store["co.funds"]
check(VS.revertClick("builder") == false and VS.revertClick("builder") == true, "revert to the builder (two clicks)")
check(store["co.funds"] == before + 800, "the hull is refunded")
check(build_host.entered == 1 and store["shipyard.pilot"] == 0, "the builder opens with the design")
check(VS.launchState() == nil, "nothing rolls out")

-- ── 5. through the black, beacons and all ──────────────────────────────────
-- With the host's fadeThrough the revert waits for the black, and fades in
-- once the craft is clamped and someone is in the seat. The comms beacons
-- are snapshotted at the launch and put back by the revert.
local snaps, restored = 0, {}
scripts.comms = {
  beaconSnapshot = function() snaps = snaps + 1; return { order = {}, rec = {}, n = snaps } end,
  beaconRestore = function(sn) restored[#restored + 1] = sn.n; return 0, 0 end,
}
local fade = nil
build_host.fadeThrough = function(atBlack, ready) fade = { atBlack = atBlack, ready = ready }; return true end
build_host.fading = function() return fade ~= nil end
VS.launchNow("pad", { force = true })
tick()
local snap_n = snaps
check(snap_n >= 1, "a launch snapshots the beacons")
check(VS.revertClick("launch") == false, "arm")
check(VS.revertClick("launch") == true and fade ~= nil, "the second click starts the fade")
check(#restored == 0 and VS.canRevert(), "...and nothing is undone before the black")
check(VS.revertClick("launch") == false, "a click during the fade does nothing")
fade.atBlack()
check(restored[1] == snap_n, "at black the revert puts back the beacons the launch saw")
check(fade.ready() == false, "the fade holds while the craft assembles")
tick()
check(VS.launchState() == "ready", "the relaunch assembles behind the black")
-- (the harness has no controller for the new craft: a stand-in takes the seat)
local pilot = controller("Kestrel I", node("Vessel", 0, 104, 0))
pilot.piloting = true
check(fade.ready() == true, "...and the fade lifts once it is ready and crewed")
build_host.fadeThrough, build_host.fading = nil, nil

if #failures > 0 then
  print("REVERT SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print(string.format("revert smoke: %d checks passed", checks))
