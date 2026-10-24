-- SMOKE: the part registry (scripts/parts_registry.lua) — a pure rulebook,
-- loaded from disk with nothing of the engine around it (no find, spawn,
-- input or camera: a call to any of them would fail the load).
--
--   luajit solar/tests/smoke_parts_registry.lua
--
-- Day 0 of the builder overhaul (docs/builder-design.md §11.1) moved REG, DESC
-- and CATALOGUE out of builder.lua verbatim. The counts below are the old
-- builder's, so a part lost (or gained without a catalogue slot) in the move
-- or later is a failure here.

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end

local env = setmetatable({}, { __index = _G })
local chunk = assert(loadfile("solar/scripts/parts_registry.lua"))
setfenv(chunk, env)
chunk()
local R = env

-- ── the old builder's numbers ───────────────────────────────────────────────
-- WP3 adds three drawn frame parts (beamP, panelP, brace) to FRAME, each
-- with a catalogue line: 49 + 3 parts, 26 + 3 lines, FRAME 13 + 3.
local OLD_REG, OLD_DESC = 52, 29
local OLD_SECTIONS = {
  { "COMMAND", 5 }, { "ELECTRICAL", 7 }, { "PROPULSION", 7 }, { "STRUCTURE", 4 },
  { "FRAME", 16 }, { "PAYLOAD", 4 }, { "ROVER", 4 }, { "ROBOTICS", 5 },
}

local n = 0
for _ in pairs(R.REG) do n = n + 1 end
check(n == OLD_REG, string.format("REG holds %d parts (the old builder had %d)", n, OLD_REG))
local d = 0
for _ in pairs(R.DESC) do d = d + 1 end
check(d == OLD_DESC, string.format("DESC holds %d lines (the old builder had %d)", d, OLD_DESC))
check(#R.registryIds() == OLD_REG, "registryIds lists every part")

local cat = R.catalogue()
check(#cat == #OLD_SECTIONS, "the catalogue has the old builder's 8 sections")
for i, want in ipairs(OLD_SECTIONS) do
  local s = cat[i]
  check(s and s.title == want[1] and #s.ids == want[2],
    string.format("section %d is %s with %d parts", i, want[1], want[2]))
end

-- every part is on sale exactly once, and every card is a real part
local seen = {}
for _, s in ipairs(cat) do
  for _, id in ipairs(s.ids) do
    check(not seen[id], "listed once: " .. id)
    seen[id] = true
    check(R.REG[id] ~= nil, "a catalogue id is a registry entry: " .. id)
  end
end
for _, id in ipairs(R.registryIds()) do check(seen[id], "in the catalogue: " .. id) end

-- the entries the builder leans on, spot-checked against the old figures
local pod = R.partInfo("pod")
check(pod and pod.prefab == "PartPod" and pod.h == 0.80 and pod.mass == 1.3 and pod.cost == 400,
  "pod: prefab, height, mass, cost")
check(R.REG.chute.h == 0.34 and R.REG.chute.rx == 0.22, "chute keeps its refit size (refit_chutes reads it)")
check(R.REG.engineS.thrust == 35 and R.REG.engineS.ve == 160, "Sputter on the reference figures")
check(R.REG.strut1.axial_out and R.REG.fins.radial_orient and R.REG.radialDec.radial,
  "placement flags survive the move")
check(R.REG.wheelM.wheel == "M" and R.REG.wheelM.travel == 0.15, "wheel size and travel (wcfg reads travel)")
check(R.REG.hub.desc == R.DESC.hub and R.REG.hub.desc:find("optional"), "DESC is copied onto the entries (the hub is optional now)")
check(R.partInfo("nope") == nil, "an unknown id is nil")

-- every entry has what spawning and the stats need
for _, id in ipairs(R.registryIds()) do
  local e = R.REG[id]
  check(type(e.prefab) == "string" and type(e.label) == "string" and (e.h or 0) > 0
    and (e.rx or 0) > 0 and (e.rz or 0) > 0 and (e.mass or 0) > 0 and (e.cost or 0) > 0
    and type(e.kind) == "string", "complete entry: " .. id)
end

-- sizeOf: the catalogue figures until parts are procedural
local sz = R.sizeOf("beam2", { len = 2 })
check(sz and sz.mass == 0.04 and sz.cost == 35 and sz.strength == 380, "sizeOf gives the catalogue figures")
check(R.sizeOf("nope") == nil, "sizeOf of an unknown part is nil")

-- extend: the hook parts_aero.register joins through (a stand-in provider)
local calls = 0
local provider = { kind = "fake_parts", register = function(REG, CATALOGUE)
  calls = calls + 1
  REG.fakeWing = { prefab = "PartFakeWing", label = "Fake Wing", h = 0.1, rx = 1, rz = 0.5,
                   mass = 0.1, cost = 10, kind = "structural" }
  CATALOGUE[#CATALOGUE + 1] = { "FAKE", { "fakeWing" } }
  return 1
end }
check(R.extend(provider) == 1, "extend adds the provider's parts")
check(R.extend(provider) == 0 and calls == 1, "extend runs a provider once")
check(R.partInfo("fakeWing") ~= nil and #R.registryIds() == OLD_REG + 1, "an extended part is in the registry")
local last = R.catalogue()[#R.catalogue()]
check(last.title == "FAKE" and last.ids[1] == "fakeWing", "and its section is in the catalogue")
check(R.extend(nil) == 0 and R.extend({}) == 0, "extend ignores a provider with no register")

-- ── report ──────────────────────────────────────────────────────────────────
if #failures == 0 then
  print(string.format("PARTS REGISTRY SMOKE OK — %d checks passed", passed))
  os.exit(0)
end
print("PARTS REGISTRY SMOKE FAILURES:")
for _, f in ipairs(failures) do print("  ✗ " .. f) end
os.exit(1)
