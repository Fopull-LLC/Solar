-- SMOKE: staging and radial decouplers (2026-11-11, Ty's playtest):
--   "pressing new stage doesn't add a new empty stage"
--   "stages don't automatically gate off fuel correctly with radial decouplers"
--   "radial decouplers should apply a bit of a force to shoot out the things
--    they're attached to"
--
--   luajit solar/tests/smoke_staging_feed.lua   (from the Floptle repo root)
--
-- Three shipped pieces, read straight from disk:
--   1. builder.lua's STAGE MODEL block: an EMPTY stage (STAGEM.addBlank)
--      survives sync and moves, takes events, saves by number and goes away;
--   2. electronics.lua fuelGroups: a radial decoupler walls its booster's fuel
--      off unless crossfeed is on, fuel lines cross it, and asparagus lines
--      drain the outer boosters first (a drain loop run the way
--      vessel_controller fuelDrawFed runs it);
--   3. vessel_controller.lua's EJECT block: the push is out along the
--      decoupler's +Y, a little aft, mass × Δv, and the core's reaction is
--      equal and opposite (a ring's cancel).

local failures, checks = {}, 0
local function check(cond, what)
  checks = checks + 1
  if not cond then failures[#failures + 1] = what end
end
local function root_dir()
  local f = io.open("solar/scripts/vessel_controller.lua", "r")
  if f then f:close() return "solar/" end
  return ""
end
local R = root_dir()
local function block(file, a_mark, b_mark, name)
  local f = assert(io.open(R .. file, "r"))
  local src = f:read("*a")
  f:close()
  local a = src:find(a_mark, 1, true)
  local b = src:find(b_mark, 1, true)
  assert(a and b, name .. " markers in " .. file)
  local env = setmetatable({}, { __index = _G })
  local chunk = assert(loadstring(src:sub(a, b - 1), name))
  setfenv(chunk, env)
  chunk()
  return env
end

-- ── 1. NEW STAGE: an empty stage ────────────────────────────────────────────
do
  local SM = block("scripts/builder.lua", "-- ══ STAGE MODEL BEGIN", "-- ══ STAGE MODEL END", "STAGE").STAGEM
  local items = {
    g1 = { key = "g1", ring = true, y = 1.0, uids = { 4, 5 } },
    u3 = { key = "u3", y = 2.0, uids = { 3 } },
    e8 = { key = "e8", engine = true, y = 3.0, uids = { 8 } },
  }
  local function ord(t)
    local o = {}
    for i, g in ipairs(t) do
      local c = {}
      for k, x in ipairs(g) do c[k] = x end
      table.sort(c)
      o[i] = (#c == 0) and "_" or table.concat(c, "+")
    end
    return table.concat(o, " ")
  end
  local st = SM.sync({}, items, {})
  check(ord(st) == "g1 u3", "default stages: " .. ord(st))
  -- NEW STAGE with nothing selected: on top
  st = SM.addBlank(st, #st + 1)
  check(ord(st) == "g1 u3 _", "NEW STAGE adds an empty stage on top: " .. ord(st))
  st = SM.sync(st, items, {})
  check(ord(st) == "g1 u3 _", "sync keeps the empty stage: " .. ord(st))
  -- above a selected stage 1 (at = 2)
  st = SM.addBlank(st, 2)
  check(ord(st) == "g1 _ u3 _", "NEW STAGE above stage 1: " .. ord(st))
  -- drag an engine into the top empty stage, the ring into the middle one
  st = SM.move(st, "e8", 4, false)
  check(ord(st) == "g1 _ u3 e8", "an engine dragged into the empty stage: " .. ord(st))
  st = SM.move(st, "g1", 2, false)
  check(ord(st) == "_ g1 u3 e8" or ord(st) == "g1 u3 e8",
    "an event dragged out of an ordinary stage closes it: " .. ord(st))
  check(ord(st) == "g1 u3 e8", "the ring's old stage (not blank) closed: " .. ord(st))
  -- a blank stage stays blank-flagged when emptied again
  st = SM.addBlank(st, 1)
  st = SM.move(st, "u3", 1, false)
  check(ord(st) == "u3 g1 e8", "event into the bottom empty stage: " .. ord(st))
  st = SM.move(st, "u3", 3, false)
  check(ord(st) == "_ g1 e8+u3", "the NEW STAGE stays when its event leaves: " .. ord(st))
  -- what the blueprint saves: stage numbers per uid and the empty ones
  local idx = SM.index(st, items)
  local bl = SM.blanks(st)
  check(idx[4] == 2 and idx[3] == 3 and idx[8] == 3, "index skips the empty stage's number")
  check(#bl == 1 and bl[1] == 1, "blanks lists the empty stage")
  -- reload: saved numbers, then the blanks put back (builder sync_stage_order)
  local re = SM.sync({}, items, idx)
  for _, n in ipairs(bl) do SM.addBlank(re, n) end
  check(ord(re) == ord(st), "save and load keep the empty stage: " .. ord(re) .. " vs " .. ord(st))
  -- remove it
  re = SM.removeBlank(re, 1)
  check(ord(re) == "g1 e8+u3", "the ✕ removes an empty stage: " .. ord(re))
  re = SM.removeBlank(re, 1)
  check(ord(re) == "g1 e8+u3", "removeBlank never removes a stage with events")
  -- replace (an engine group split) keeps a blank
  local rp = SM.replace({ { "g1" }, { blank = true }, { "eg2" } }, "eg2", { "e5", "e6" })
  check(#rp == 3 and #rp[2] == 0, "replace keeps the empty stage")
end

-- ── 2. FUEL GROUPS ──────────────────────────────────────────────────────────
local E = {}
do
  local chunk = assert(loadfile(R .. "scripts/electronics.lua"))
  setfenv(chunk, setmetatable(E, { __index = _G }))
  chunk()
end
local function rec(uid, parent, o)
  local d = { uid = uid, parent = parent or 0 }
  for k, v in pairs(o or {}) do d[k] = v end
  return d
end
local TANK, ENG = { fuel = 160 }, { thrust = 85 }
local function with(base, more) local t = {} for k, v in pairs(base) do t[k] = v end for k, v in pairs(more or {}) do t[k] = v end return t end
-- a core (pod 1, tank 2, tank 3, engine 4) with two radial boosters:
-- decoupler 10 → tank 11 → engine 12, decoupler 20 → tank 21 → engine 22
local function core_two(xfeed, lines)
  local L = {
    rec(1, 0, { kind = "crewed" }), rec(2, 1, TANK), rec(3, 2, TANK), rec(4, 3, ENG),
    rec(10, 3, { decouple = 1, radial = 1, size = xfeed and { xfeed = true } or nil }), rec(11, 10, TANK), rec(12, 11, ENG),
    rec(20, 3, { decouple = 1, radial = 1, size = xfeed and { xfeed = true } or nil }), rec(21, 20, TANK), rec(22, 21, ENG),
  }
  for _, l in ipairs(lines or {}) do L[#L + 1] = l end
  return L
end
do
  local F = E.fuelGroups(core_two(false), { keep = 1 })
  local core, b1, b2 = F.of[4], F.of[12], F.of[22]
  check(core ~= b1 and core ~= b2 and b1 ~= b2, "a radial decoupler walls each booster off from the core and from each other")
  check(F.of[2] == core and F.of[3] == core, "the core's tanks are the core's group")
  check(F.of[11] == b1 and F.of[21] == b2, "each booster's tank is its own engine's group")
  check(#F.order[core] == 1 and F.order[core][1] == core, "the core drinks only its own tanks")
  check(#F.order[b1] == 1 and F.order[b1][1] == b1, "a booster drinks only its own tanks")
  check(F.groups[core].keep == true and F.groups[core].fuel == 320, "the core group: crew's side, 320 fuel")
  check(F.of[10] ~= core and F.of[10] ~= b1, "the decoupler itself passes nothing")
end
do
  local F = E.fuelGroups(core_two(true), { keep = 1 })
  check(F.of[4] == F.of[12] and F.of[12] == F.of[22], "crossfeed on: booster and core are one tank group")
  check(F.groups[F.of[4]].fuel == 640, "crossfeed on: the pool holds all four tanks")
end
do
  -- fuel lines from each booster's tank (source) into the core's tank 3
  local F = E.fuelGroups(core_two(false, {
    rec(30, 11, { fline = 1, size = { to = 3 } }), rec(31, 21, { fline = 1, size = { to = 3 } }) }), { keep = 1 })
  local core, b1, b2 = F.of[4], F.of[12], F.of[22]
  check(core ~= b1, "a fuel line does not merge the groups (the decoupler still walls them)")
  local o = F.order[core]
  check(#o == 3 and o[3] == core and ((o[1] == b1 and o[2] == b2) or (o[1] == b2 and o[2] == b1)),
    "a fuel line across the decoupler: the core drinks both boosters, then itself")
  check(#F.order[b1] == 1, "the line runs one way: a booster does not drink the core")
  check(F.of[30] == b1, "a fuel line rides its source (it leaves with the booster)")
end
do
  -- an engine bolted under an axial decoupler with no tank of its own
  local L = { rec(1, 0, { kind = "crewed" }), rec(2, 1, TANK), rec(3, 2, { decouple = 1 }), rec(4, 3, ENG) }
  local F = E.fuelGroups(L, { keep = 1 })
  check(F.of[4] ~= F.of[2], "the axial decoupler splits the stack")
  check(F.order[F.of[4]][1] == F.of[2], "a tankless engine group drinks through its decoupler")
end
do
  -- ASPARAGUS: outer pair O (40/41 → tank 42, engine 43 ; 50 → 52, 53) feeds
  -- the inner pair I (10/20), which feeds the core. The drain is run the way
  -- the flight runs it (fuelDrawFed): each engine group draws its burn from
  -- its feed order, the first group first.
  local L = core_two(false, {
    rec(40, 11, { decouple = 1, radial = 1 }), rec(42, 40, TANK), rec(43, 42, ENG),
    rec(50, 21, { decouple = 1, radial = 1 }), rec(52, 50, TANK), rec(53, 52, ENG),
    rec(44, 42, { fline = 1, size = { to = 11 } }), rec(54, 52, { fline = 1, size = { to = 21 } }),
    rec(30, 11, { fline = 1, size = { to = 3 } }), rec(31, 21, { fline = 1, size = { to = 3 } }),
  })
  local F = E.fuelGroups(L, { keep = 1 })
  local core = F.of[4]
  local o = F.order[core]
  check(#o == 5 and (o[1] == F.of[42] or o[1] == F.of[52]) and o[5] == core,
    "asparagus: the core drinks outer, then inner, then its own (" .. table.concat(o, ",") .. ")")
  local left = {}
  for _, d in ipairs(L) do if d.fuel then left[d.uid] = d.fuel end end
  local function gfuel(g) local s = 0 for _, u in ipairs(F.groups[g].tanks) do s = s + left[u] end return s end
  local function draw(g, need)
    local L0 = gfuel(g)
    if L0 <= 0 then return 0 end
    local take = math.min(L0, need)
    for _, u in ipairs(F.groups[g].tanks) do left[u] = left[u] - take * left[u] / L0 end
    return take
  end
  local first_dry = nil
  for step = 1, 2000 do
    for g, grp in pairs(F.groups) do
      if #grp.engines > 0 then
        E.fuelFeedDraw(F, g, #grp.engines * 1.0, gfuel, draw)
      end
    end
    if not first_dry then
      for _, u in ipairs({ 42, 52, 11, 21, 2, 3 }) do
        if left[u] < 1e-6 then first_dry = u break end
      end
    end
  end
  check(first_dry == 42 or first_dry == 52, "asparagus: an outer booster's tank runs dry first (got " .. tostring(first_dry) .. ")")
  -- the moment the outer tanks are dry, the inner and the core must still be full-ish
  local L2 = {}
  for _, d in ipairs(L) do if d.fuel then L2[d.uid] = d.fuel end end
  left = L2
  for step = 1, 400 do
    for g, grp in pairs(F.groups) do
      if #grp.engines > 0 then
        E.fuelFeedDraw(F, g, #grp.engines * 1.0, gfuel, draw)
      end
    end
    if left[42] < 1e-6 then break end
  end
  check(left[42] < 1e-6 and left[52] < 1e-6, "asparagus: both outer tanks dry together")
  check(left[11] > 159 and left[21] > 159 and left[2] + left[3] > 319, string.format(
    "asparagus: inner boosters and core untouched while the outers feed them (inner %.1f, core %.1f)", left[11], left[2] + left[3]))
end
do
  -- without lines the boosters burn their own and the core its own, side by side
  local L = core_two(false)
  local F = E.fuelGroups(L, { keep = 1 })
  local left = { [2] = 160, [3] = 160, [11] = 160, [21] = 160 }
  for step = 1, 160 do
    for g, grp in pairs(F.groups) do
      if #grp.engines > 0 then
        for _, x in ipairs(F.order[g]) do
          local t = F.groups[x].tanks
          local s = 0
          for _, u in ipairs(t) do s = s + left[u] end
          local take = math.min(s, #grp.engines)
          for _, u in ipairs(t) do if s > 0 then left[u] = left[u] - take * left[u] / s end end
        end
      end
    end
  end
  check(left[11] < 1e-6 and left[21] < 1e-6, "no lines: each booster burns its own tank dry")
  check(math.abs(left[2] + left[3] - 160) < 1e-6, "no lines: the core burnt its own 160 alongside, and has 160 left")
end

-- ── 3. THE CHARGE ───────────────────────────────────────────────────────────
do
  local env = block("scripts/vessel_controller.lua", "-- ══ EJECT RULEBOOK BEGIN", "-- ══ EJECT RULEBOOK END", "EJECT")
  local EJ = env.EJECT
  local function near(a, b, e) return math.abs(a - b) < (e or 1e-6) end
  -- a radial decoupler on the +X flank as the builder stands it: +Y out (+X),
  -- +X along the host's axis. Its YXZ euler: roll −90° turns +Y onto +X.
  local yaw, pitch, roll = 0, 0, -math.pi / 2
  local x, y, z = EJ.partY(yaw, pitch, roll)
  check(near(x, 1) and near(y, 0) and near(z, 0), string.format("partY: roll −90° points +Y out along +X (%.2f %.2f %.2f)", x, y, z))
  local d = { yaw = yaw, pitch = pitch, roll = roll }
  -- the craft upright: R = +X, U = +Y, Z = +Z
  local Rw, Uw, Zw = { x = 1, y = 0, z = 0 }, { x = 0, y = 1, z = 0 }, { x = 0, y = 0, z = 1 }
  local dir = EJ.dir(d, Rw, Uw, Zw)
  check(dir and dir.x > 0.98 and dir.y < 0 and dir.y > -0.2 and near(dir.z, 0),
    string.format("the push is outward and a little aft (%.3f %.3f %.3f)", dir.x, dir.y, dir.z))
  check(near(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z, 1), "the push direction is unit")
  -- the craft lying over: R = +Y, U = −X (nose toward −X), Z = +Z
  local dir2 = EJ.dir(d, { x = 0, y = 1, z = 0 }, { x = -1, y = 0, z = 0 }, Zw)
  check(dir2.y > 0.98 and dir2.x > 0 and dir2.x < 0.2, string.format("it turns with the craft (%.3f %.3f %.3f)", dir2.x, dir2.y, dir2.z))
  -- the mirror decoupler (+Y out along −X) pushes the other way
  local dm = EJ.dir({ yaw = 0, pitch = 0, roll = math.pi / 2 }, Rw, Uw, Zw)
  check(dm.x < -0.98, "the ring's other decoupler pushes the other way")
  -- magnitude: mass × Δv; reaction equal and opposite
  local J, back = EJ.impulse(dir, 1.6, 4.5)
  local jm = math.sqrt(J.x * J.x + J.y * J.y + J.z * J.z)
  check(near(jm, 7.2, 1e-9), string.format("impulse = mass × Δv (%.3f)", jm))
  check(near(J.x + back.x, 0) and near(J.y + back.y, 0) and near(J.z + back.z, 0), "the core's reaction is equal and opposite")
  local Jm, backm = EJ.impulse(dm, 1.6, 4.5)
  check(near(back.x + backm.x, 0) and near(back.z + backm.z, 0),
    "a symmetric pair's reactions cancel across the stack (the core holds its course)")
  check(back.y + backm.y > 0 and back.y + backm.y < 0.3 * 7.2,
    "what is left of a pair's reaction is a small push along the stack, never a turn")
  -- the setting
  check(EJ.dv({}) == env.EJECT_DV, "no setting: the default charge")
  check(EJ.dv({ size = { eject = 7 } }) == 7, "the part setting sets the charge")
  check(EJ.dv({ size = { eject = 99 } }) == 12 and EJ.dv({ size = { eject = -1 } }) == 0, "the setting is clamped 0..12")
  local J0 = EJ.impulse(dir, 1.6, 0)
  check(J0.x == 0 and J0.y == 0, "a charge of 0 pushes nothing")
end

if #failures > 0 then
  print("STAGING/FEED SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print(string.format("smoke_staging_feed: all %d checks passed", checks))
