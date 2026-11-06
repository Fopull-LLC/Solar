-- SMOKE: the Build Stand and the craft on it (deep-space addendum step 6:
-- L1, L2, L4; docs/base-building.md §9), against a stub save, the real parts
-- registry, the real structures / field_builder / base_economy, and a stub
-- craft controller.
--
--   * the rules: a part's box in the vessel frame (turned by its yaw); a
--     rover's bounds (its belly is the body, what hangs lowest its tyres);
--     the deck height it needs (rounded up to the stand's step, never under
--     the stand's least, refused past its most); what commands it; wheels;
--     its front; the vessel's axes and origin on the stand (front along the
--     stand's front, centre of mass over the deck, belly on the pads); the
--     Deck child's height; the library's JSON tags decoded;
--   * the stand placed with the Build Kit: its `h` from parts_base `fields`;
--   * a craft put on it: charged price + shipping (one truck), its blueprint
--     under its own save key, the state plain and within the save's depth, the
--     stand raised to what the craft needs; a stand in use refuses a second
--     craft, a craft nothing can command, and a craft that rests on nothing;
--   * the stand can't come down (Deconstruct, the undo ring) while a craft is
--     on it; the height can't go under the craft's need;
--   * Clear the stand: all of it back within a minute, the price after;
--   * Commission needs the stand's node in the scene; Release needs a
--     commissioned craft;
--   * Return to stand: refused for a crewed, moving or airborne craft; a
--     landed, empty one goes back on with its records packed, its fuel, and
--     what recovering it was worth (Clear pays that);
--   * idle: update() with nothing held looks nothing up.
--
--   luajit solar/tests/smoke_stand.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, e) return math.abs(a - b) <= (e or 1e-6) end

local LOOKUPS = { n = 0 }
local function env(store, scripts, extra)
  local E = setmetatable({
    time = 5.0,
    save = {
      get = function(k) return store[k] end,
      set = function(k, v) store[k] = v end,
      delete = function(k) local had = store[k] ~= nil; store[k] = nil; return had end,
    },
    findScript = function(k) LOOKUPS.n = LOOKUPS.n + 1; return scripts[k] end,
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
local function depth(v)
  if type(v) ~= "table" then return 0 end
  local d = 0
  for _, x in pairs(v) do d = math.max(d, depth(x)) end
  return d + 1
end
local function plain(v, seen)
  local t = type(v)
  if t == "number" or t == "string" or t == "boolean" or t == "nil" then return true end
  if t ~= "table" then return false end
  seen = seen or {}
  if seen[v] then return false end
  seen[v] = true
  for k, x in pairs(v) do if not plain(k, seen) or not plain(x, seen) then return false end end
  return true
end

-- the parts as the VAB's make_blueprint writes them (the fields the stand reads)
local REGE = load_script("parts_registry.lua", env({}, {}))
local function part(uid, id, x, y, z, o)
  o = o or {}
  local d = REGE.REG[id]
  return { uid = uid, id = id, prefab = d.prefab, label = d.label, x = x, y = y, z = z, yaw = o.yaw or 0, pitch = o.pitch or 0,
           roll = o.roll or 0, parent = o.parent or 0, att = o.att or "", h = d.h, mass = d.mass, cost = d.cost, kind = d.kind,
           rx = d.rx or 0, rz = d.rz or 0, wheel = d.wheel or "", front = d.front and 1 or 0, seat = d.seat and 1 or 0 }
end
local HP = math.pi / 2
local ROVER = { parts = {
  part(1, "roverBody", 0, 0.62, 0),
  part(2, "wheelM", 0.66, 0.42, 0.7, { yaw = -HP, parent = 1, att = "surface" }),
  part(3, "wheelM", 0.66, 0.42, -0.7, { yaw = HP, parent = 1, att = "surface" }),
  part(4, "wheelM", -0.66, 0.42, 0.7, { yaw = -HP, parent = 1, att = "surface" }),
  part(5, "wheelM", -0.66, 0.42, -0.7, { yaw = HP, parent = 1, att = "surface" }),
  part(6, "seat", 0, 0.62 + 0.15 + 0.65, 0, { parent = 1, att = "top" }),
}, name = "Stand Rover", v = 2 }

local PB = load_script("parts_base.lua", env({}, {}))
local def = PB.partInfo("stand")
local S = def.stand
check(def and def.script == "craft_stand" and def.fields.h == 1.0 and S.min == 0.5 and S.max == 4.0, "the Build Stand: a BASE part with a script, a height field, 0.5–4.0 m")
local f = io.open("solar/prefabs/" .. def.prefab .. ".prefab.ron")
local ron = f and f:read("*a") or ""
if f then f:close() end
check(ron:find('name: "Deck"', 1, true) and ron:find('name: "Deck Wall 1"', 1, true) and ron:find("parent: Some(1)", 1, true),
  "its prefab: a Deck child with its own collider boxes under it")

-- ── the rules ───────────────────────────────────────────────────────────────
local CS0 = load_script("craft_stand.lua", env({}, {}))
local bx = CS0.partBox({ x = 0, y = 1, z = 0, rx = 0.2, h = 0.8, rz = 0.4 })
check(near(bx.x1, 0.2) and near(bx.y0, 0.6) and near(bx.z1, 0.4), "a part's box: rx, h/2, rz round its centre")
local bt = CS0.partBox({ x = 0, y = 1, z = 0, rx = 0.2, h = 0.8, rz = 0.4, yaw = HP })
check(near(bt.x1, 0.4, 1e-9) and near(bt.z1, 0.2, 1e-9), "...turned 90° its x and z swap")
local b = CS0.bounds(ROVER, S.deck)
check(b and near(b.belly, 0.47, 1e-9) and near(b.lo, 0.02, 1e-9), string.format("a rover rests on its body (belly %.2f); its tyres hang lowest (%.2f)", b.belly, b.lo))
check(near(b.com.x, 0, 1e-9) and near(b.com.z, 0, 1e-9), "...its centre of mass over the deck's centre")
local need = CS0.needHeight(b, S, 0.10, 0, 0.02)
check(near(need, 0.6, 1e-9), "it needs a 0.6 m deck: the tyres 0.10 m clear (" .. tostring(need) .. ")")
check(near(CS0.needHeight(b, S, 0.10, 0.4, 0.02), 1.0, 1e-9), "...and 0.4 m more where the ground rises under it")
local legs = { parts = { part(1, "probe", 0, 5.0, 0), part(2, "legs", 2.0, 0.45, 0), part(3, "legs", -2.0, 0.45, 0) } }
local nh, nwhy = CS0.needHeight(CS0.bounds(legs, S.deck), S, 0.1, 0, 0.02)
check(nh == nil and nwhy:find("4.0 m", 1, true), "a probe on 4.8 m legs: more than the stand's 4 m (" .. tostring(nwhy) .. ")")
local hollow = { parts = { part(1, "probe", 2.0, 0.5, 0), part(2, "probe", -2.0, 0.5, 0) } }
local hh, hwhy = CS0.needHeight(CS0.bounds(hollow, S.deck), S, 0.1, 0, 0.02)
check(hh == nil and hwhy:find("rests on the deck", 1, true), "nothing over the deck: refused (" .. tostring(hwhy) .. ")")
local tiny = { parts = { part(1, "probe", 0, 0.21, 0) } }
check(near(CS0.needHeight(CS0.bounds(tiny, S.deck), S, 0.1, 0, 0.02), 0.5, 1e-9), "never under the stand's least, 0.5 m")
check(CS0.commandWhy(ROVER) == nil and CS0.commandWhy({ parts = { part(1, "tankS", 0, 0, 0) } }) ~= nil
  and CS0.commandWhy({ parts = {} }) ~= nil, "something must command it (a pod, a seat, a probe core)")
check(CS0.wheeled(ROVER) and not CS0.wheeled(legs), "a rover has wheels; a probe on legs doesn't")
local fx, fz = CS0.frontOf(ROVER.parts)
check(near(fx, 1) and near(fz, 0), "the rover's front: its body's +X")
-- on a stand facing +Z of a body frame with up +Y
local R, U, F = { x = 1, y = 0, z = 0 }, { x = 0, y = 1, z = 0 }, { x = 0, y = 0, z = 1 }
local X, Uv, Z = CS0.vesselAxes(R, U, F, fx, fz)
local front = { x = X.x * fx + Z.x * fz, y = X.y * fx + Z.y * fz, z = X.z * fx + Z.z * fz }
check(near(front.x, 0, 1e-9) and near(front.z, 1, 1e-9), "the vessel turned so the craft's front is the stand's front")
local Ux = { x = X.y * Z.z - X.z * Z.y, y = X.z * Z.x - X.x * Z.z, z = X.x * Z.y - X.y * Z.x }
check(near(Ux.y, -1, 1e-9) or near(Ux.y, 1, 1e-9), "...its axes square to up")
local XZ = { x = Uv.y * Z.z - Uv.z * Z.y, y = Uv.z * Z.x - Uv.x * Z.z, z = Uv.x * Z.y - Uv.y * Z.x }
check(near(XZ.x, X.x, 1e-9) and near(XZ.z, X.z, 1e-9), "...X = U × Z (setUp(U, −Z) turns a node onto them)")
local fx2, fz2 = 0.6, 0.8
local X2, _, Z2 = CS0.vesselAxes(R, U, F, fx2, fz2)
check(near(X2.x * fx2 + Z2.x * fz2, 0, 1e-9) and near(X2.z * fx2 + Z2.z * fz2, 1, 1e-9), "...for any front")
local G = { x = 10, y = 600, z = -5 }
local O = CS0.vesselOrigin(G, X, Uv, Z, 0.6, b, 0.02)
local wb = { x = O.x + X.x * b.com.x + Z.x * b.com.z + Uv.x * b.belly, y = O.y + X.y * b.com.x + Z.y * b.com.z + Uv.y * b.belly,
             z = O.z + X.z * b.com.x + Z.z * b.com.z + Uv.z * b.belly }
check(near(wb.x, 10, 1e-9) and near(wb.y, 600.62, 1e-9) and near(wb.z, -5, 1e-9), "the craft's belly 2 cm over the deck's pads, over its centre")
check(near(CS0.deckY(def, 1.0), 1.0 - S.deckOff - def.seat, 1e-12), "the Deck child's height: h − deckOff − seat")
check(near(CS0.clampHeight(S, 7), 4.0) and near(CS0.clampHeight(S, 0.1), 0.5) and near(CS0.clampHeight(S, 1.26), 1.3, 1e-9), "heights clamp to 0.5–4.0 m in 0.1 m steps")
local dec = CS0.decodeLib({ ["\0n:3"] = { a = "\0d:4503599627370496:-52" }, s = "\0s:\0x", f = "\0f:inf" })
check(dec[3] and near(dec[3].a, 1.0) and dec.s == "\0x" and dec.f == math.huge, "the library's JSON tags decode (numbers, keys, strings)")
local EC = load_script("base_economy.lua", env({}, {}))
local qr = CS0.quote(ROVER, EC)
check(qr.cost == 150 + 4 * 40 + 40 and qr.ship == EC.shipping(qr.cost) and qr.total == qr.cost + qr.ship,
  string.format("a craft on a stand: its hull's price + one truck's shipping ($%d + $%d)", qr.cost, qr.ship))

-- ── the scene's rules with the real structures and field_builder ──────────
local s = { ["base.body"] = "Vever", ["agency.clock"] = 1000 }
local CLOCK = { t = 1000 }
local scripts = {}
scripts.deployables = { agencyClock = function() return CLOCK.t end, dateOf = function() return "Day 1, Y1" end }
local ledger = {}
local funds = { v = 50000 }
scripts.company = {
  afford = function(a) return funds.v >= a end,
  spend = function(a, why) if funds.v < a then return false end funds.v = funds.v - a; ledger[#ledger + 1] = { -a, why }; return true end,
  refund = function(a, why) funds.v = funds.v + a; ledger[#ledger + 1] = { a, why } end,
  earn = function(a, why) funds.v = funds.v + a; ledger[#ledger + 1] = { a, why, "earn" } end,
}
scripts.parts_base = PB
scripts.base_economy = EC
scripts.base_snap = load_script("base_snap.lua", env({}, {}))
scripts.builder_history = load_script("builder_history.lua", env({}, {}))
scripts.crew = { activeId = function() return 7 end, hasRole = function(id, r) return r == "engineer" end, credit = function() end }
scripts.structures = load_script("structures.lua", env(s, scripts))
local FB = load_script("field_builder.lua", env(s, scripts, { input = { pressed = function() return false end } }))
scripts.field_builder = FB
local forgot = {}
scripts.flight_ops = { forgetNodes = function(ids) for _, i in ipairs(ids) do forgot[#forgot + 1] = i end return #ids end }
scripts.electronics = { packRecord = function(r) local o = {}; for k, v in pairs(r) do if type(v) ~= "table" then o[k] = v end end; return o end }
local ASM = { info = function(n) return n.info end }
local CS = load_script("craft_stand.lua", env(s, scripts, { assembly = ASM }))
scripts.craft_stand = CS
local ST = scripts.structures

local sid, why0 = FB.place(nil, "stand", { body = "Vever", x = 0, y = 600, z = 0, up = { x = 0, y = 1, z = 0 }, fwd = { x = 0, y = 0, z = 1 } }, "money")
check(sid ~= nil and funds.v == 50000 - (650 + EC.shipping(650)), "a Build Stand placed with the kit: $650 + shipping (" .. tostring(why0) .. ")")
local sp = ST.getPart(sid, 1)
check(sp and sp.h == 1.0, "...its deck height from parts_base fields (1.0 m)")
check(FB.removalBlocked(sid, { 1 }) == nil, "an empty stand may come down")
local fp = CS.framePose(sid, 1)
check(fp and near(fp.top.y, 601.0) and near(fp.G.y, 600), "its frame: the ground point and the deck's top 1.0 m over it")
-- a craft on it
local f0 = funds.v
local ok, w, q = CS.putOn(sid, 1, ROVER, { name = "Stand Rover" })
check(ok and q and funds.v == f0 - q.total and q.total == qr.total, "Put a craft on it: charged its hull + shipping now (" .. tostring(w) .. ")")
check(ledger[#ledger][2]:find("Build Stand", 1, true) ~= nil, "...the ledger says where it went")
local st = CS.stateOf(sid, 1)
check(st and st.s == "built" and st.n == 6 and st.name == "Stand Rover" and st.wheeled == true, "the stand's state: built, 6 parts, on wheels")
local key = CS.STAND_KEY(sid, 1)
check(type(s[key]) == "table" and #s[key].parts == 6 and s[key] ~= ROVER, "the blueprint under its own save key (a copy)")
check(depth(s[key]) <= 4 and depth(s["struct." .. sid]) <= 4, string.format("the save stays four tables deep (bp %d, record %d)", depth(s[key]), depth(s["struct." .. sid])))
check(plain(CS.stateOf(sid, 1)) and plain(s[key]), "...plain values (the state and the blueprint)")
check(near(ST.getPart(sid, 1).h, 1.0), "a 1.0 m deck is already high enough for it: kept")
local ok2, w2 = CS.putOn(sid, 1, ROVER)
check(not ok2 and w2:find("already", 1, true), "a stand in use refuses a second craft")
-- what can't come down
local nd, ndw = FB.deconstruct(sid, 1)
check(nd == nil and ndw:find("clear it first", 1, true), "Deconstruct refused while a craft is on it (" .. tostring(ndw) .. ")")
local nu, nuw = FB.undo()
check(nu == nil and nuw:find("clear it first", 1, true) and ST.get(sid) ~= nil, "...and so is the undo of its placement (" .. tostring(nuw) .. ")")
local okh, wh = CS.setHeight(sid, 1, 0.5)
check(not okh and wh:find("needs 0.6", 1, true), "the deck can't go under what the craft needs (" .. tostring(wh) .. ")")
check(CS.setHeight(sid, 1, 2.04) and near(ST.getPart(sid, 1).h, 2.0, 1e-9), "...it can go up (2.0 m, in steps)")
check(CS.setHeight(sid, 1, 0.6) and near(ST.getPart(sid, 1).h, 0.6, 1e-9), "...and down to the need (0.6 m)")
-- commission / release need the scene
local okc, wc = CS.commission(sid, 1)
check(not okc and wc:find("isn't here", 1, true), "Commission needs the stand in the scene (" .. tostring(wc) .. ")")
local okr, wr = CS.release(sid, 1)
check(not okr and wr:find("nothing commissioned", 1, true), "Release needs a commissioned craft")
-- clear within the minute: all of it
CLOCK.t = CLOCK.t + 30
local f1 = funds.v
local back = CS.clear(sid, 1)
check(back == q.total and funds.v == f1 + q.total and CS.stateOf(sid, 1) == nil and s[key] == nil, "Clear within a minute: every dollar back, the key gone")
check(FB.removalBlocked(sid, { 1 }) == nil, "an empty stand may come down again")
-- clear later: the price
CS.putOn(sid, 1, ROVER)
CLOCK.t = CLOCK.t + 70
local back2 = CS.clear(sid, 1)
check(back2 == qr.cost, "Clear after a minute: the price back, the shipping kept (" .. tostring(back2) .. ")")
-- a stand lowered after a release goes back up for the next craft
ST.getPart(sid, 1).lo = true
CS.putOn(sid, 1, ROVER)
check(ST.getPart(sid, 1).lo == nil and near(ST.getPart(sid, 1).h, 0.6, 1e-9), "a lowered stand rises to its setting for the next craft")
CS.clear(sid, 1)
-- refusals
local okn, wn = CS.putOn(sid, 1, { parts = { part(1, "tankS", 0, 0.5, 0) } })
check(not okn and wn:find("command", 1, true) and CS.stateOf(sid, 1) == nil, "a craft nothing can command: refused, nothing charged")
local okt, wt = CS.putOn(sid, 1, legs)
check(not okt and wt:find("4.0 m", 1, true), "a craft that would need more than 4 m: refused")
funds.v = 10
local oka, wa = CS.putOn(sid, 1, ROVER)
check(not oka and wa:find("afford", 1, true) and CS.stateOf(sid, 1) == nil and s[key] == nil, "can't afford it: nothing written")
funds.v = 50000
-- RETURN TO STAND (a stub craft controller)
local node = { valid = true, id = 4242, destroyed = false, x = 0, y = 600, z = 5 }
node.destroy = function(n) n.destroyed = true; n.valid = false end
node.info = { anchored = false, grounded = false, vel = { x = 0, y = 0, z = 0 } }
local v = { node = node, piloting = true, craftName = "Stand Rover",
  r2OnWheels = function() return true end,
  recoverValue = function() return 300 end,
  fleetParts = function()
    local ps = {}
    for i, d in ipairs(ROVER.parts) do local c = {}; for k, x in pairs(d) do c[k] = x end; c.st = { hp = 0.9 }; ps[i] = c end
    return { parts = ps, lost = {}, fuel = 3.5, charge = 40, from = 1, flown = true }
  end }
check(CS.returnWhy(v, sid, 1):find("step off", 1, true), "Return to stand: the crew must step off first")
v.piloting = false
node.info.vel = { x = 1, y = 0, z = 0 }
check(CS.returnWhy(v, sid, 1):find("moving", 1, true), "...it must have stopped")
node.info.vel = { x = 0, y = 0, z = 0 }
node.info.anchored = true
check(CS.returnWhy(v, sid, 1):find("clamped", 1, true), "...and not be clamped")
node.info.anchored = false
check(CS.returnWhy(v, sid, 1) == nil, "a landed, stopped, empty craft may go back on")
local f2 = funds.v
local okb, wb2 = CS.returnTo(v, sid, 1)
local st2 = CS.stateOf(sid, 1)
check(okb and st2 and st2.s == "built" and st2.ret == true and st2.cost == 300 and funds.v == f2,
  "returned: on the stand, not charged, worth its recovery value (" .. tostring(wb2) .. ")")
check(node.destroyed and forgot[1] == 4242, "...the live craft gone, and off the fleet's board")
local kb = s[key]
check(kb and kb.fuel == 3.5 and kb.charge == 40 and kb.parts[1].st == nil and kb.name == "Stand Rover",
  "...its fuel, charge and name kept, its records packed (no tables)")
check(depth(kb) <= 4, "...within the save's depth")
local back3 = CS.clear(sid, 1)
check(back3 == 300, "Clear on a returned craft pays what recovering it was worth ($" .. tostring(back3) .. ")")
-- idle: nothing looked up
LOOKUPS.n = 0
CS.update(nil, 0.016)
local n1 = LOOKUPS.n
for _ = 1, 100 do CS.update(nil, 0.016) end
check(LOOKUPS.n - n1 <= 1, "idle: 100 updates with nothing held look nothing up (" .. tostring(LOOKUPS.n - n1) .. ")")
-- the stand can come down now
local got = FB.deconstruct(sid, 1)
check(got ~= nil and ST.get(sid) == nil, "with the stand empty, Deconstruct takes it down")

if #failures > 0 then
  for _, m in ipairs(failures) do print("FAIL: " .. m) end
  print(string.format("smoke_stand: %d passed, %d FAILED", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_stand: all %d checks passed", passed))
