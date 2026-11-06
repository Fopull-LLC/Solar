-- SMOKE: rooms and air (sandbox plan S3, work/sandbox/PLAN.md §1.5, §12;
-- docs/base-building.md §14), against the real parts_kit, parts_base,
-- kit_snap, rooms and room_air.
--
--   * rooms.solve, the flood fill on the cell grid from the pieces' `seals`:
--     a 2 x 2 box of a floor, four walls and a roof is ONE sealed room of
--     8.8 m³; a door wall in it is still sealed, its door to the outside; a
--     window wall seals; a wall missing is a LEAKY room with the gap named; an
--     open frame, a vent louvre and a half wall leak and say so; two rooms
--     joined by a door are two rooms and one door between them; a chamber
--     with an Airlock Wall out and a door in is an airlock; a hab can of three
--     segments and two caps seals; a canopy on posts is no room at all; a
--     point inside finds its room;
--   * room_air.advance, the closed form: an hour in one step equals 3,600
--     one-second steps to 1e-6 (crew, a generator, a scrubber); a regulator
--     cycling a tank against the crew's breathing over 30 hours, one step
--     against 108,000; venting through a door (95 % gone in 3 τ) in one step
--     and in many; two crew in 16 m³ with a scrubber and a generator hold
--     1 atm and normal O2 for a day;
--   * room_air's scene half on a stub engine: rooms solved once, the air of a
--     new room is the outside's (vacuum on a moon), a tank pressurises it, the
--     crew in it breathe its air (airAt), an open door vents it with a
--     DEPRESSURISATION alarm naming the door, the AIRLOCK cycle (never both
--     doors open; it depressurises before the outer door opens and
--     repressurises before the inner one, pumping the air back into the hab),
--     a catch-up capped at 30 game days, the save carried into a new session.
--
--   luajit solar/tests/smoke_rooms.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, e) return math.abs(a - b) <= (e or 1e-6) end

local function env(store, scripts, extra)
  local E = setmetatable({
    time = 5.0,
    save = {
      get = function(k) return store[k] end,
      set = function(k, v) store[k] = v end,
      delete = function(k) local had = store[k] ~= nil; store[k] = nil; return had end,
    },
    findScript = function(k) return scripts[k] end,
    findScripts = function(k) return {} end,
    find = function() return nil end,
    log = function() end,
  }, { __index = _G })
  for k, v in pairs(extra or {}) do E[k] = v end
  return E
end
local function load_script(path, E)
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, E)
  f()
  E.params = {}
  for k, v in pairs(E.defaults or {}) do E.params[k] = v end
  return E
end

local S = {}
S.parts_kit = load_script("parts_kit.lua", env({}, S))
S.parts_base = load_script("parts_base.lua", env({}, S))
S.kit_snap = load_script("kit_snap.lua", env({}, S))
local RL = load_script("rooms.lua", env({}, S))
S.rooms = RL
local RA = load_script("room_air.lua", env({}, S))
local defs = function(id) return S.parts_base.partInfo(id) end

local PI2 = math.pi / 2
local function P(uid, id, x, y, z, yaw, pitch, roll) return { uid = uid, id = id, x = x, y = y, z = z, yaw = yaw or 0, pitch = pitch or 0, roll = roll or 0 } end
local function rec_of(bp) return { id = 1, b = "Home", x = 0, y = 600, z = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1, bp = bp } end
-- a 2 x 2 box: a floor, four walls (front = +Z), a roof; `front` the front wall's piece
local function box(front, opts)
  opts = opts or {}
  local bp = { P(1, "floor.steel", 0, 0, 0), P(2, "wall.steel", 1, 0.2, 0, PI2), P(3, "wall.steel", -1, 0.2, 0, PI2),
               P(4, "wall.steel", 0, 0.2, -1, 0), P(6, "floor.steel", 0, 2.4, 0) }
  if front then bp[#bp + 1] = P(5, front, 0, 0.2, 1, 0) end
  return rec_of(bp)
end

-- ── the flood fill ──────────────────────────────────────────────────────────
do
  local R = RL.solve(box("wall.steel"), defs)
  check(#R.rooms == 1 and R.rooms[1].sealed and R.rooms[1].ncell == 4, string.format("a floor, four walls and a roof: one sealed room of 4 cells (%d rooms)", #R.rooms))
  check(R.rooms[1] and near(R.rooms[1].m3, 8.8, 1e-9), string.format("its volume 2 x 2 x 2.2 m = 8.8 m³ (%.2f)", R.rooms[1] and R.rooms[1].m3 or -1))
  check(R.rooms[1] and #R.rooms[1].doors == 0 and #R.rooms[1].leaks == 0, "no door, no leak")
  local r = RL.roomAt(R, 0.3, 1.2, -0.4)
  check(r and r.id == R.rooms[1].id, "a point inside finds its room")
  check(RL.roomAt(R, 0.3, 1.2, 1.6) == nil and RL.roomAt(R, 0.3, 3.4, 0) == nil, "outside, and over the roof: no room")
  check(R.rooms[1] and #R.rooms[1].seg >= 16 * 6, "its outline: the floor's and the ceiling's edges")
  -- a door wall: sealed with its door shut; the door is to the outside
  local Rd = RL.solve(box("doorWall.steel"), defs)
  local rd = Rd.rooms[1]
  check(#Rd.rooms == 1 and rd.sealed and #rd.doors == 1 and rd.doors[1] == 5, "a door wall: still one sealed room, with its door")
  check(Rd.doors[5] and Rd.doors[5].a == 0 and Rd.doors[5].b == rd.id, "the door is between the room and the outside")
  check(Rd.doors[5] and near(Rd.doors[5].z, 1, 1e-9) and math.abs(Rd.doors[5].x) <= 0.5 + 1e-9 and Rd.doors[5].y > 0.1 and Rd.doors[5].y < 2.5,
    "and it is where the door wall stands (the overlay marks it there)")
  -- the mirrored Door Wall seals the same
  local Rm = RL.solve(box("doorWallM.steel"), defs)
  check(#Rm.rooms == 1 and Rm.rooms[1].sealed and Rm.doors[5] ~= nil, "the Door Wall's mirrored variant seals with its door")
  -- a window wall seals
  local Rw = RL.solve(box("windowWall.steel"), defs)
  check(#Rw.rooms == 1 and Rw.rooms[1].sealed and #Rw.rooms[1].doors == 0, "a window wall seals (double glazed)")
  local Rg = RL.solve(box("wall.glass"), defs)
  check(#Rg.rooms == 1 and Rg.rooms[1].sealed, "a glass wall seals")
  -- a gap: no front wall
  local Rgap = RL.solve(box(nil), defs)
  local rg = Rgap.rooms[1]
  check(#Rgap.rooms == 1 and rg and not rg.sealed and rg.leaky, "a wall missing: a LEAKY room")
  check(rg and #rg.leaks == 1 and rg.leaks[1].label == "a gap in the wall" and near(rg.leaks[1].z, 1, 1e-9),
    string.format("its leak named, at the gap: %s at z %.2f", rg and rg.leaks[1] and rg.leaks[1].label or "-", rg and rg.leaks[1] and rg.leaks[1].z or -9))
  for _, c in ipairs({ { "openFrame.steel", "Open Frame lets air through" }, { "ventWall.steel", "Vent Louvre Wall lets air through" },
                       { "halfWall.steel", "the Half Wall stops short of the ceiling" } }) do
    local Ro = RL.solve(box(c[1]), defs)
    local ro = Ro.rooms[1]
    check(ro and ro.leaky and ro.leaks[1] and ro.leaks[1].label == c[2] and ro.leaks[1].uid == 5,
      string.format("%s: leaks, and says \"%s\" (%s)", c[1], c[2], ro and ro.leaks[1] and ro.leaks[1].label or "no room"))
  end
  -- no roof: no room; a canopy on posts: no room
  local nr = rec_of({ P(1, "floor.steel", 0, 0, 0), P(2, "wall.steel", 1, 0.2, 0, PI2), P(3, "wall.steel", -1, 0.2, 0, PI2),
                      P(4, "wall.steel", 0, 0.2, -1, 0), P(5, "wall.steel", 0, 0.2, 1, 0) })
  check(#RL.solve(nr, defs).rooms == 0, "four walls and a floor, no roof: no room")
  local can = rec_of({ P(1, "floor.steel", 0, 0, 0), P(2, "pillar2.steel", 1, 0.2, 1), P(3, "floor.steel", 0, 2.4, 0) })
  check(#RL.solve(can, defs).rooms == 0, "a roof on a post over a floor: a canopy, no room")
  -- two rooms joined by a door
  local two = rec_of({ P(1, "floor.steel", 0, 0, 0), P(2, "floor.steel", 2, 0, 0),
    P(3, "wall.steel", -1, 0.2, 0, PI2), P(4, "wall.steel", 3, 0.2, 0, PI2),
    P(5, "wall.steel", 0, 0.2, -1, 0), P(6, "wall.steel", 2, 0.2, -1, 0), P(7, "wall.steel", 0, 0.2, 1, 0), P(8, "wall.steel", 2, 0.2, 1, 0),
    P(9, "doorWall.steel", 1, 0.2, 0, PI2), P(10, "floor.steel", 0, 2.4, 0), P(11, "floor.steel", 2, 2.4, 0) })
  local R2 = RL.solve(two, defs)
  check(#R2.rooms == 2 and R2.rooms[1].sealed and R2.rooms[2].sealed and near(R2.rooms[1].m3, 8.8, 1e-9) and near(R2.rooms[2].m3, 8.8, 1e-9),
    string.format("a partition with a door: two sealed rooms of 8.8 m³ (%d)", #R2.rooms))
  local d9 = R2.doors[9]
  check(d9 and d9.a == 1 and d9.b == 2 and not R2.rooms[1].airlock, "the door joins them; no airlock (no Airlock Wall)")
  -- an airlock: an Airlock Wall out of the chamber, a door into the hab
  local lock = rec_of({ P(1, "floor.steel", 0, 0, 0), P(2, "floor.steel", 2, 0, 0),
    P(3, "airlockWall.steel", -1, 0.2, 0, PI2), P(4, "wall.steel", 3, 0.2, 0, PI2),
    P(5, "wall.steel", 0, 0.2, -1, 0), P(6, "wall.steel", 2, 0.2, -1, 0), P(7, "wall.steel", 0, 0.2, 1, 0), P(8, "wall.steel", 2, 0.2, 1, 0),
    P(9, "doorWall.steel", 1, 0.2, 0, PI2), P(10, "floor.steel", 0, 2.4, 0), P(11, "floor.steel", 2, 2.4, 0) })
  local RA_ = RL.solve(lock, defs)
  local ch = RL.roomAt(RA_, 0, 1.2, 0)
  local hab = RL.roomAt(RA_, 2, 1.2, 0)
  check(ch and ch.airlock and #ch.doors == 2 and hab and not hab.airlock, "an Airlock Wall and a door: the chamber is an airlock, the hab isn't")
  check(RA_.doors[3] and RA_.doors[3].airlock and RA_.doors[3].a == 0, "the Airlock Wall's door is to the outside")
  -- a hab can: three segments and two caps
  local habc = rec_of({ P(1, "habSeg.steel", 0, 0, 0), P(2, "habSeg.steel", 0, 0, 2), P(3, "habWindow.steel", 0, 0, 4),
                        P(4, "habCap.steel", 0, 0, -1.35, math.pi), P(5, "habCap.steel", 0, 0, 5.35) })
  local Rh = RL.solve(habc, defs)
  check(#Rh.rooms == 1 and Rh.rooms[1].sealed and Rh.rooms[1].ncell >= 12, string.format("a hab of three segments and two caps seals (%d rooms, %d cells)", #Rh.rooms, Rh.rooms[1] and Rh.rooms[1].ncell or 0))
  local habo = rec_of({ P(1, "habSeg.steel", 0, 0, 0), P(2, "habSeg.steel", 0, 0, 2), P(3, "habCap.steel", 0, 0, -1.35, math.pi) })
  local Rho = RL.solve(habo, defs)
  check(#Rho.rooms == 1 and Rho.rooms[1].leaky, "a can with an open end: leaky")
  local habd = rec_of({ P(1, "habSeg.steel", 0, 0, 0), P(2, "habCap.steel", 0, 0, -1.35, math.pi), P(3, "habBulkhead.steel", 0, 0, 1.2) })
  local Rhd = RL.solve(habd, defs)
  check(#Rhd.rooms == 1 and Rhd.rooms[1].sealed and Rhd.doors[3] ~= nil, "a can closed by a door bulkhead: sealed, with its door")
  -- turned: the box turned a quarter is the same room
  local tb = box("doorWall.steel")
  for _, p in ipairs(tb.bp) do p.x, p.z = p.z, -p.x; p.yaw = p.yaw + PI2 end
  local Rt = RL.solve(tb, defs)
  check(#Rt.rooms == 1 and Rt.rooms[1].sealed and near(Rt.rooms[1].m3, 8.8, 1e-9) and Rt.doors[5], "the same box turned a quarter: the same room")
  -- a big floor plan: 10 x 10 m of one room, solved fast
  local big = { }
  local uid = 0
  local function add(id, x, y, z, yaw) uid = uid + 1; big[#big + 1] = P(uid, id, x, y, z, yaw) end
  for i = 0, 4 do for k = 0, 4 do add("floor.steel", i * 2, 0, k * 2); add("floor.steel", i * 2, 2.4, k * 2) end end
  for i = 0, 4 do add("wall.steel", i * 2, 0.2, -1, 0); add("wall.steel", i * 2, 0.2, 9, 0); add("wall.steel", -1, 0.2, i * 2, PI2); add("wall.steel", 9, 0.2, i * 2, PI2) end
  local Rb = RL.solve(rec_of(big), defs, os.clock)
  check(#Rb.rooms == 1 and Rb.rooms[1].sealed and near(Rb.rooms[1].m3, 220, 1e-9), string.format("a 10 x 10 m hall: one room of 220 m³ (%.1f)", Rb.rooms[1] and Rb.rooms[1].m3 or -1))
  check(Rb.ms and Rb.ms < 20, string.format("solved in %.2f ms", Rb.ms or -1))
  -- the signature: a light on the wall doesn't change the rooms, a wall does
  local s0 = RL.signatureOf(box("wall.steel"), defs)
  local bl = box("wall.steel"); bl.bp[#bl.bp + 1] = P(9, "lightFitting.steel", 0, 2.3, 0, 0, math.pi)
  check(RL.signatureOf(bl, defs) == s0, "a light added: no new solve")
  local bw = box("wall.steel"); bw.bp[5].x = 0.5
  check(RL.signatureOf(bw, defs) ~= s0, "a wall moved: a new solve")
end

-- ── the closed form ─────────────────────────────────────────────────────────
local function copy(t) local o = {}; for k, v in pairs(t) do o[k] = v end; return o end
local function same(a, b, tol)
  local w = 0
  for _, k in ipairs({ "N", "x", "c", "q" }) do
    local d = math.abs(a[k] - b[k]) / math.max(1, math.abs(b[k]))
    if d > w then w = d end
  end
  return w <= tol, w
end
do
  local V = 16
  local st0 = { N = 0.79 * V, x = 0.21 * V * 0.9, c = 0.002 * V, q = 0, feed = false }
  local M = { V = V, crew = 2, G = 2.8e-5, S = 2.4e-5, F = 0 }
  local one = RA.advance(copy(st0), M, 3600)
  local many = copy(st0)
  for _ = 1, 3600 do RA.advance(many, M, 1.0) end
  local ok, w = same(one, many, 1e-6)
  check(ok, string.format("an hour of two crew, a generator and a scrubber: one step = 3,600 steps (worst %.2g)", w))
  check(one.x > st0.x and near(one.c, 0, 1e-12), "the generator is bringing the O2 back; the scrubber cleared the CO2 (45 min)")
  local day = RA.advance(copy(st0), M, 86400)
  local sd = RA.statusOf(day, V)
  check(sd.breathable and near(sd.p, 1.0, 0.01) and near(sd.share, 1.0, 1e-6) and near(day.c, 0, 1e-12),
    string.format("two crew in 16 m³ for a day: %.3f atm, O2 back at %.0f %% of normal and held there, no CO2", sd.p, 100 * sd.share))
  -- the regulator: a tank against three crew breathing, no generator, 30 hours
  local V2 = 10
  local s2 = { N = 0.79 * V2, x = 0.21 * V2, c = 0, q = 5, feed = false }
  local M2 = { V = V2, crew = 3, G = 0, S = 3e-5, F = 0.05 }
  local rep = { segs = 0, events = {} }
  local o2 = RA.advance(copy(s2), M2, 30 * 3600, rep)
  local m2 = copy(s2)
  for _ = 1, 30 * 3600 do RA.advance(m2, M2, 1.0) end
  local ok2, w2 = same(o2, m2, 1e-6)
  local ons = 0
  for _, e in ipairs(rep.events) do if e == "feed_on" then ons = ons + 1 end end
  check(ok2, string.format("30 hours of a regulator topping up a room three crew breathe: one step = 108,000 steps (worst %.2g)", w2))
  check(ons >= 4 and (o2.N + o2.x + o2.c) / V2 > 0.96, string.format("the regulator opened %d times and held the pressure (%.3f atm)", ons, (o2.N + o2.x + o2.c) / V2))
  check(o2.q < 5 and o2.q > 0, string.format("the tank gave what the crew breathed away (%.2f of 5 left)", o2.q))
  -- venting through a door: e^(-t/τ), one step and many
  local V3 = 8.8
  local s3 = { N = 0.79 * V3, x = 0.21 * V3, c = 0.01, q = 0, feed = false }
  local tau = RA.VENT_S * V3
  local M3 = { V = V3, crew = 1, tau = tau, pout = 0, xout = 0 }
  local v1 = RA.advance(copy(s3), M3, 3 * tau)
  local vm = copy(s3)
  for _ = 1, 300 do RA.advance(vm, M3, 3 * tau / 300) end
  local ok3, w3 = same(v1, vm, 1e-6)
  check(ok3 and near(RA.statusOf(v1, V3).p, RA.statusOf(s3, V3).p * math.exp(-3), 1e-9), string.format("venting: 95 %% gone in 3 τ = %.1f s, one step = 300 steps (p %.4f)", 3 * tau, RA.statusOf(v1, V3).p))
  -- a home world's air: venting relaxes to it, not to vacuum
  local v2 = RA.advance({ N = 0, x = 0, c = 0, q = 0 }, { V = V3, tau = tau, pout = 1.0, xout = 0.21 }, 60)
  check(RA.statusOf(v2, V3).breathable and near(RA.statusOf(v2, V3).p, 1.0, 1e-4), "a room open to a breathable world's air fills with it")
  -- the O2 running out with no machine: an event, and it stays at nothing
  local s4 = RA.advance({ N = 0.79, x = 0.21, c = 0, q = 0 }, { V = 1, crew = 1 }, 1e6)
  check(near(s4.x, 0, 1e-12) and not RA.statusOf(s4, 1).breathable, "a crew member shut in a cupboard runs it out of O2, and no further")
  check(RA.o2Left({ x = 0.21 * 16 }, 16, 2, 0) > 0 and RA.o2Left({ x = 3.36 }, 16, 2, 2.8e-5) == nil, "O2 left: hours with no generator, as long as the power with one")
end

-- ── the scene half on a stub engine ─────────────────────────────────────────
do
  local store = {}
  local SS = {}
  for k, v in pairs(S) do SS[k] = v end
  local planet = { x = 1000, y = 0, z = 0, name = "Moon" }
  local agency = 1000.0
  local doors = {}               -- uid → open (0..1), driven by the gate as kit_live would
  local astro = { x = 0, y = 0, z = 0, valid = true }
  local lock = rec_of({ P(1, "floor.steel", 0, 0, 0), P(2, "floor.steel", 2, 0, 0),
    P(3, "airlockWall.steel", -1, 0.2, 0, PI2), P(4, "wall.steel", 3, 0.2, 0, PI2),
    P(5, "wall.steel", 0, 0.2, -1, 0), P(6, "wall.steel", 2, 0.2, -1, 0), P(7, "wall.steel", 0, 0.2, 1, 0), P(8, "doorWall.steel", 2, 0.2, 1, 0),
    P(9, "doorWall.steel", 1, 0.2, 0, PI2), P(10, "floor.steel", 0, 2.4, 0), P(11, "floor.steel", 2, 2.4, 0),
    P(12, "airTank.steel", 2.4, 0.2, -0.5) })
  lock.b = "Moon"
  local recs = { lock }
  SS.structures = { version = 1, list = function() return recs end, get = function(id) for _, r in ipairs(recs) do if r.id == id then return r end end end }
  SS.kit_live = { doorOpen = function(sid, uid) return doors[uid] or 0 end }
  SS.base_grid = { gridOfStruct = function() return nil end }
  SS.deployables = { agencyClock = function() return agency end }
  SS.climate = { worldOf = function() return { atmo = 0, radius = 500 } end }
  local captions, sounds = {}, {}
  SS.big_caption = { show = function(a, b) captions[#captions + 1] = a .. ": " .. b end }
  SS.sfx = { caption = function() end }
  local E = env(store, SS, {
    space = { body = function() return planet end, dominant = function() return "Moon" end },
    find = function(n) if n == "Astronaut" then return astro end end,
    audio = { play = function(clip) sounds[#sounds + 1] = clip; return { stop = function() end } end },
    app = { wallClock = os.clock },
  })
  local A = load_script("room_air.lua", E)
  local function at(lx, ly, lz) astro.x, astro.y, astro.z = planet.x + lock.x + lx, planet.y + lock.y + ly, planet.z + lock.z + lz end
  local function frame(dt, wants)
    E.time = E.time + dt
    agency = agency + dt
    -- kit_live's part: each door the crew is near asks; the gate answers
    for uid, w in pairs(wants or {}) do
      local g = A.gate(1, uid, w)
      local o = doors[uid] or 0
      if g > 0 then o = math.min(1, o + dt / 1.0) else o = math.max(0, o - dt / 1.0) end
      if (o > 0.02) ~= ((doors[uid] or 0) > 0.02) then A.doorMoved(1, uid) end
      doors[uid] = o
    end
    A.update(nil, dt)
  end
  at(5, 1.0, 5)
  for _ = 1, 10 do frame(0.1) end
  local st = A.state(1)
  check(st and st.R and #st.R.rooms == 2 and A.PROF.n_solve == 1, string.format("the stub base solved once: the chamber and the hab (%d rooms)", st and st.R and #st.R.rooms or -1))
  local ch = st and RL.roomAt(st.R, 0, 1.2, 0)
  local hab = st and RL.roomAt(st.R, 2, 1.2, 0)
  check(ch and ch.airlock and hab and hab.sealed and not hab.airlock, "the chamber is an airlock; the hab, with its own door out, isn't")
  for _ = 1, 500 do frame(0.1) end
  local a0 = hab and A.airOf(1, hab.id)
  check(a0 and a0.p > 0.9, string.format("the Air Tank Rack pressurised the hab it stands in (%.2f atm)", a0 and a0.p or -1))
  check(A.state(1).tanks[12] and A.state(1).tanks[12] < 60, string.format("from its store (%.1f of 60 m³ left)", A.state(1).tanks[12] or -1))
  -- pressurise the chamber from the hab's own air (an inner-door walk in, then out)
  local cha = A.airOf(1, ch.id)
  check(cha and cha.p < 0.05, string.format("the chamber, closed round the moon's vacuum, holds none (%.2f atm)", cha and cha.p or -1))
  -- the crew in the hab: the hab's air is theirs
  at(2.2, 1.0, 0.2)
  for _ = 1, 3 do frame(0.1) end
  local ok, why = A.airAt(astro.x, astro.y, astro.z)
  check(ok == true, "in the hab, the crew breathe its air (airAt)")
  local _, rid = A.crewRoom()
  check(rid == hab.id, "and they are counted in it")
  -- WALK OUT THROUGH THE AIRLOCK: the inner door first
  local both, maxIn = false, 0
  local function watch() if (doors[3] or 0) > 0.02 and (doors[9] or 0) > 0.02 then both = true end end
  at(1.6, 1.0, 0)   -- by the inner door, in the hab
  for _ = 1, 400 do frame(0.1, { [9] = 1 }); watch() end
  check((doors[9] or 0) > 0.9, string.format("the inner door opens to the crew in the hab (chamber and hab at %.2f / %.2f atm)", A.airOf(1, ch.id).p, A.airOf(1, hab.id).p))
  check(A.airOf(1, ch.id).p > 0.4, "with the inner door open the chamber shares the hab's air")
  at(0, 1.0, 0)     -- in the chamber
  local pmin = 1
  for _ = 1, 600 do
    frame(0.1, { [9] = 1, [3] = 1 }); watch()
    pmin = math.min(pmin, A.airOf(1, ch.id).p)
    if (doors[3] or 0) > 0.99 then break end
  end
  check((doors[3] or 0) > 0.99 and (doors[9] or 0) < 0.02, "in the chamber: the inner door shut, then the outer one opened")
  check(pmin < 0.06, string.format("it depressurised before the outer door opened (%.3f atm)", pmin))
  local habp = A.airOf(1, hab.id).p
  check(habp > 0.9, string.format("the chamber's air was pumped back into the hab (%.2f atm)", habp))
  check(not both, "never both doors open at once")
  -- and back in
  at(-1.8, 1.0, 0)  -- outside, by the outer door
  for _ = 1, 40 do frame(0.1, { [3] = 1 }) end
  at(0, 1.0, 0)
  local pmax = 0
  for _ = 1, 600 do
    frame(0.1, { [3] = 1, [9] = 1 }); watch()
    pmax = math.max(pmax, A.airOf(1, ch.id).p)
    if (doors[9] or 0) > 0.99 then break end
  end
  check((doors[9] or 0) > 0.99 and (doors[3] or 0) < 0.02 and pmax > 0.85, string.format("back in: outer door shut, chamber repressurised (%.2f atm), inner door open", pmax))
  check(not both, "never both doors open at once (in either direction)")
  local cyc = 0
  for _, s in ipairs(sounds) do if s:find("hiss_cylinder", 1, true) then cyc = cyc + 1 end end
  check(cyc >= 2, string.format("each cycle hissed (%d)", cyc))
  -- A DOOR LEFT OPEN: the hab's front door to the moon
  at(2.2, 1.0, 0.2)
  for _ = 1, 30 do frame(0.1, { [9] = 0 }) end
  local p0 = A.airOf(1, hab.id).p
  -- the pressure holds it: a crew member by it doesn't open it; its menu forces it
  check(A.gate(1, 8, 1) == 0, "the hab's door to the moon is held shut by 1 atm: walking up to it doesn't open it")
  A.forceOpen(1, 8)
  check(A.gate(1, 8, 1) == 1, "forced from its menu, it opens")
  doors[8] = 1; A.doorMoved(1, 8)
  for _ = 1, 40 do frame(0.25) end
  local q = A.airOf(1, hab.id)
  check(p0 > 0.9 and q.p < 0.2 and q.venting, string.format("the hab's door open to the moon: it vents (%.2f → %.2f atm)", p0, q.p))
  local al = A.lastAlarm
  check(al and al.kind == "depress" and al.cause:find("Door Wall", 1, true), string.format("a DEPRESSURISATION alarm, the door named: %s", al and al.cause or "none"))
  check(#captions > 0 and captions[#captions]:find("DEPRESSURISATION", 1, true), "the caption says so")
  local alarmed = 0
  for _, s in ipairs(sounds) do if s:find("crew_alarm", 1, true) then alarmed = alarmed + 1 end end
  check(alarmed >= 1, "the alarm sounds")
  local okb = A.airAt(astro.x, astro.y, astro.z)
  check(okb == false, "and the crew in it are back on their suits (airAt: not breathable)")
  doors[8] = 0; A.doorMoved(1, 8)
  check(not A.state(1).forced[8], "shut again, it holds again")
  for _ = 1, 400 do frame(0.25) end
  local q2 = A.airOf(1, hab.id)
  check(q2.p > 0.9 and not q2.venting, string.format("door shut: the regulator brings the hab back (%.2f atm)", q2.p))
  -- the save, and a catch-up capped at 30 game days
  A.saveNow()
  local sv = store["air.1"]
  check(type(sv) == "table" and sv.rooms and sv.tanks and sv.a, "the air is in the save")
  local x0 = A.airOf(1, hab.id).o2 * hab.m3
  local p0s = A.airOf(1, hab.id).p
  local E2 = env(store, SS, {
    space = E.space, find = E.find, audio = E.audio, app = E.app,
  })
  E2.time = E.time
  local A2 = load_script("room_air.lua", E2)
  agency = agency + 60 * 86400
  at(2.2, 1.0, 0.2)
  for _ = 1, 10 do E2.time = E2.time + 0.1; A2.update(nil, 0.1) end
  local q3 = A2.airOf(1, hab.id)
  check(q3 and near(q3.p, p0s, 1e-6) and near(q3.o2 * hab.m3, x0, 1e-6), string.format("a new session takes the hab's air from the save (%.3f atm)", q3 and q3.p or -1))
  check(A2.PROF.catch and near(A2.PROF.catch, 30 * 86400, 1e-6) and math.abs(A2.state(1).a - agency) < 1e-6,
    string.format("60 game days away: caught up in one step, capped at 30 (%.1f days)", (A2.PROF.catch or 0) / 86400))
end

if #failures > 0 then
  print("FAIL smoke_rooms: " .. #failures .. " of " .. (#failures + passed))
  for _, m in ipairs(failures) do print("  - " .. m) end
  os.exit(1)
end
print(string.format("smoke_rooms: %d checks passed", passed))
