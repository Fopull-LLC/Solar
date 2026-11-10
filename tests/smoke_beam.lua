-- SMOKE: the laser's beam physics (expansion X9; scripts/beam.lua; PLAN §4.1).
--
--   * the plan's worked figures: a 0.5 m director's 60 MJ at 100 km and at
--     2,000 km, the 8 m dish's 1.2 GJ at 10,000 km (diffraction, as the plan
--     writes them), and with the director's jitter;
--   * the pulse: a 10-bank emitter, stages on their own banks, the cap of six;
--   * focus: the director's reach, a Lens Group's, a fixed range; off-focus blur;
--   * air: sea-level extinction, blooming for CW in thick air only;
--   * occlusion by a body from one bodies read;
--   * cooldown and the 40 % no-coolant rate;
--   * the cinematic regime: 0 for normal builds, continuous, rising with energy,
--     amplification and magnification, never a step;
--   * the layout: banks + bus → emitter → amp → lens → director by their ports;
--     an open chain and a missing bank say why.
--
--   luajit solar/tests/smoke_beam.lua

local failures, passed = {}, 0
local function check(ok, msg) if ok then passed = passed + 1 else failures[#failures + 1] = msg end end
local function near(a, b, tol) return math.abs(a - b) <= (tol or 1e-6) * math.max(1, math.abs(a), math.abs(b)) end
local function load(path)
  local E = setmetatable({ save = { get = function() end, set = function() end }, findScript = function() end, log = function() end },
                         { __index = _G })
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, E)
  f()
  return E
end
local B = load("beam.lua")

-- ── 1. the plan's worked figures ────────────────────────────────────────────
do
  local th = B.diffraction(0.5)
  local d = B.spotAt(100e3, 0.5, th, 100e3)
  check(near(d, 0.517, 2e-3), string.format("0.5 m director at 100 km: spot %.3f m (plan 0.52)", d))
  local F = B.fluence(60e6, d)
  check(near(F, 2.86e8, 0.02), string.format("60 MJ at 100 km: F %.3g (plan 2.8e8)", F))
  local d2 = B.spotAt(2000e3, 0.5, th, 2000e3)
  check(near(d2, 10.34, 0.01), string.format("at 2,000 km: spot %.2f m (plan 10)", d2))
  check(near(B.fluence(60e6, 10), 7.64e5, 0.01), "60 MJ on a 10 m spot: 7.6e5 (plan)")
  local thL = B.diffraction(8)
  local d3 = B.spotAt(1e7, 8, thL, 1e7)
  check(near(d3, 3.23, 0.01), string.format("the 8 m dish at 10,000 km: spot %.2f m (plan 3.2)", d3))
  check(near(B.fluence(1.2e9, d3), 1.46e8, 0.02), string.format("1.2 GJ there: F %.3g (plan 1.5e8)", B.fluence(1.2e9, d3)))
  -- with the director's 1 µrad jitter (the plan's own rule, which its worked figure leaves out)
  local thj = B.divergence(0.5, 0, B.JIT_DIR)
  check(near(thj, th + 1e-6), "θ = 2.44 λ/D + the director's jitter")
  local dj = B.spotAt(100e3, 0.5, thj, 100e3)
  check(near(dj, 0.617, 3e-3), string.format("with jitter: %.3f m at 100 km", dj))
  -- stage jitter shrinks with the expander's magnification
  local j6s = B.divergence(0.5, 6, B.JIT_DIR) - B.diffraction(0.5) - B.JIT_DIR
  local j6L = B.divergence(8, 6, B.JIT_LARGE) - B.diffraction(8) - B.JIT_LARGE
  check(near(j6s, 2.4e-6, 1e-6) and near(j6L, 0.15e-6, 1e-6), string.format("six stages: %.2f µrad on 0.5 m, %.2f on 8 m", j6s * 1e6, j6L * 1e6))
  check(B.spotAt(1, 0.5, thj, 1) == B.SPOT_MIN, "close in, the spot is the train's 2 cm floor")
end

-- ── 2. the pulse ────────────────────────────────────────────────────────────
do
  local E, wall, heat = B.pulseEnergy({ emitter = 10 * 20e6 })
  check(near(E, 55.2e6) and near(wall, 200e6) and near(heat, 144.8e6), string.format("10 banks: %.1f MJ, %.0f MJ drawn, %.1f MJ heat", E / 1e6, wall / 1e6, heat / 1e6))
  local E2 = B.pulseEnergy({ emitter = 10 * 20e6, stages = { 10 * 20e6 } })
  check(near(E2, 55.2e6 + 0.92 * 0.45 * 200e6), string.format("+ a stage on its own 10 banks: %.1f MJ", E2 / 1e6))
  local st = {}
  for i = 1, 8 do st[i] = 1e6 end
  local E8, w8 = B.pulseEnergy({ emitter = 0, stages = st })
  check(near(E8, 6 * 0.92 * 0.45 * 1e6) and near(w8, 6e6), "only six stages count")
  check(near(B.shareOf(40e6, 2), 20e6), "a group shared by two devices: half each")
  check(B.pulseEnergy(nil) == 0, "no chain, no pulse")
end

-- ── 3. focus ────────────────────────────────────────────────────────────────
do
  check(B.focusFor(300) == 300 and B.focusFor(20000) == B.REACH_DIR, "the director focuses to 5 km by itself")
  check(B.focusFor(2e6, B.REACH_LENS) == 2e6, "a Lens Group's reach: 50,000 km")
  check(B.focusFor(800, B.REACH_LENS, 100) == 100, "a fixed focus holds")
  check(B.focusFor(5) == B.FOCUS_MIN, "never closer than 20 m")
  local th = B.divergence(0.5, 0)
  local onf = B.spotAt(300, 0.5, th, 300)
  local off = B.spotAt(300, 0.5, th, 30)
  check(onf == B.SPOT_MIN and near(off, 0.5 * 9, 1e-3), string.format("off focus the blur D·|1−R/f| = %.2f m", off))
  local far = B.spotAt(100e3, 0.5, th, B.focusFor(100e3))
  check(far > 9, string.format("past the director's reach without a lens: %.1f m at 100 km", far))
end

-- ── 4. air ──────────────────────────────────────────────────────────────────
do
  check(near(B.airTransmission(1000, 1.225), math.exp(-0.1)), "sea level: 0.1 /km")
  check(B.airTransmission(1000, 0) == 1, "vacuum: no loss")
  check(near(B.airTransmission(1000, 1.225, true, 30), 0.5 * math.exp(-0.1)), "a 30 kW CW beam in thick air blooms")
  check(near(B.airTransmission(1000, 0.1, true, 30), math.exp(-0.1 * 0.1 / 1.225)), "thin air: no blooming")
  check(near(B.airTransmission(1000, 1.225, true, 8), math.exp(-0.1)), "under 10 kW: no blooming")
  local rho = B.rhoAlong(0, 100, 0, 0, 100, 0, 0, 0, 0, 100, function(alt) return alt < 1 and 1.2 or 0 end, 4)
  check(near(rho, 1.2), "the mean density along a ground path")
  local rho2 = B.rhoAlong(0, 100, 0, 0, 300, 0, 0, 0, 0, 100, function(alt) return math.max(0, 1.2 * (1 - alt / 100)) end, 8)
  check(rho2 > 0 and rho2 < 1.2, string.format("a climbing path: %.3f", rho2))
end

-- ── 5. occlusion ────────────────────────────────────────────────────────────
do
  local bodies = { { name = "Home", x = 0, y = 0, z = 0, radius = 600 }, { name = "Moon", x = 5000, y = 0, z = 0, radius = 200 } }
  check(B.occluded(-700, 0, 0, 700, 0, 0, bodies) == "Home", "through the planet: occluded")
  check(B.occluded(0, 610, 0, 0, 2000, 0, bodies) == nil, "straight up: clear")
  check(B.occluded(0, 610, 0, 4600, 0, 0, bodies, nil, 1) == nil, "to the moon's near face: clear")
  check(B.occluded(0, 610, 0, 5400, 0, 0, bodies, "Home", 1) == "Moon", "to its far side: the moon itself is in the way")
end

-- ── 6. cooldown ─────────────────────────────────────────────────────────────
do
  check(near(B.cooldown(60, 1), 9), "60 MJ at full cooling: 3 + 6 s")
  check(near(B.cooldown(60, 0.2), 9 / 0.4), "no coolant: 40 % of its rate")
end

-- ── 7. the cinematic regime ─────────────────────────────────────────────────
do
  local th = B.divergence(0.5, 0)
  local F10 = B.fluence(55.2e6, B.SPOT_MIN)
  check(B.regime(55.2e6, F10, 0, 0.5) == 0, "a 10-bank laser at point blank: c = 0 (the physics)")
  check(B.regime(1e9, 1e8, 6, 8) == 0 and B.regime(5e9, 5e8, 6, 8) == 0, "a big pulse on a wide spot: c = 0")
  -- the max buildable now: 0.5 m director, six stages, 30 banks on every bus
  local Emax = B.pulseEnergy({ emitter = 30 * 20e6, stages = { 6e8, 6e8, 6e8, 6e8, 6e8, 6e8 } })
  local cNow = B.regime(Emax, B.fluence(Emax, B.SPOT_MIN), 6, 0.5)
  check(cNow > 0 and cNow < 0.1, string.format("the largest X9 build (%.2f GJ): c = %.3f, just over the edge", Emax / 1e9, cNow))
  -- the full path: X11's 8 m dish with 400 banks a bus
  local Ebig = B.pulseEnergy({ emitter = 400 * 20e6, stages = { 8e9, 8e9, 8e9, 8e9, 8e9, 8e9 } })
  local cBig = B.regime(Ebig, B.fluence(Ebig, 0.3), 6, 8)
  check(cBig > 0.9, string.format("a death-star build (%.0f GJ on a 0.3 m spot): c = %.2f", Ebig / 1e9, cBig))
  -- continuous: no step anywhere along the bank count, and monotonic
  local last, maxstep = -1, 0
  for n = 1, 400 do
    local E = B.pulseEnergy({ emitter = n * 20e6, stages = { n * 20e6, n * 20e6, n * 20e6, n * 20e6, n * 20e6, n * 20e6 } })
    local c = B.regime(E, B.fluence(E, 0.5), 6, 8)
    check(c >= last - 1e-12, "monotonic in banks at n " .. n)
    if last >= 0 then maxstep = math.max(maxstep, c - last) end
    last = c
  end
  check(maxstep < 0.02, string.format("continuous: the largest step for one more bank on every bus is %.4f", maxstep))
  check(B.regime(1e10, 1e12, 0, 8) < B.regime(1e10, 1e12, 3, 8) and B.regime(1e10, 1e12, 3, 8) < B.regime(1e10, 1e12, 6, 8), "amplification raises it")
  check(B.regime(1e10, 1e12, 6, 0.5) < B.regime(1e10, 1e12, 6, 2) and B.regime(1e10, 1e12, 6, 2) < B.regime(1e10, 1e12, 6, 8), "magnification raises it")
  local P = B.predict(55.2e6, 300, 0.5, th, 300, 0.97, 0)
  check(P.d == B.SPOT_MIN and near(P.E, 55.2e6 * 0.97) and P.c == 0, "predict: spot, energy on arrival, regime")
end

-- ── 8. the layout ───────────────────────────────────────────────────────────
do
  local function pp(x, z, nx, nz) return { x = x, y = 0.5, z = z, nx = nx, nz = nz, pulse = true } end
  local function bp(z, nz, io) return { x = 0, y = 1.0, z = z, nx = 0, nz = nz, beam = io } end
  -- banks at x = -3..-1 (two), a bus -1..? : bank A [-5,-3], bank B [-3,-1], the emitter's pulse port at x = -0.5 facing -X ⇒ a bus from -1 to -0.5? use a 0.5 bus
  local pieces = {
    { key = "capA", kind = "cap", ports = { pp(-4.5, 0, -1, 0), pp(-2.5, 0, 1, 0) } },
    { key = "capB", kind = "cap", ports = { pp(-2.5, 0, -1, 0), pp(-0.5, 0, 1, 0) } },
    { key = "em", kind = "emitter", ports = { pp(-0.5, 0, -1, 0), bp(0.75, 1, "out") } },
    { key = "amp", kind = "amp", ports = { bp(0.75, -1, "in"), bp(2.75, 1, "out"), pp(-0.5, 1.75, -1, 0) } },
    { key = "capC", kind = "cap", ports = { pp(-2.5, 1.75, -1, 0), pp(-0.5, 1.75, 1, 0) } },
    { key = "lens", kind = "lens", ports = { bp(2.75, -1, "in"), bp(3.75, 1, "out") } },
    { key = "dir", kind = "director", ports = { bp(3.75, -1, "in") } },
  }
  local W, groups, members = B.layout(pieces)
  check(#W == 1 and W[1].director == "dir" and W[1].why == nil, "the chain reaches the director: " .. tostring(W[1] and W[1].why))
  check(#W[1].stages == 1 and W[1].stages[1] == "amp" and #W[1].lenses == 1, "one stage and one lens on the path")
  check(groups.capA == groups.capB and groups.capB == groups.em, "banks A and B and the emitter are one pulse group")
  check(groups.capC == groups.amp and groups.capC ~= groups.em, "the stage has its own group")
  check(#members[groups.em].banks == 2 and #members[groups.em].devs == 1, "the emitter's group: two banks, one device")
  -- an open chain
  local p2 = { pieces[1], pieces[2], pieces[3] }
  local W2 = B.layout(p2)
  check(W2[1].director == nil and tostring(W2[1].why):find("Amplifier Stage"), "nothing on the beam port: " .. tostring(W2[1].why))
  -- no bank
  local p3 = { pieces[3], pieces[4], pieces[6], pieces[7] }
  local W3 = B.layout(p3)
  check(W3[1].director == "dir" and tostring(W3[1].why):find("Capacitor Bank"), "a chain with no bank: " .. tostring(W3[1].why))
  -- a gap in the beam (the lens moved 0.1 m)
  local lens2 = { key = "lens", kind = "lens", ports = { bp(2.85, -1, "in"), bp(3.85, 1, "out") } }
  local W4 = B.layout({ pieces[1], pieces[2], pieces[3], pieces[4], pieces[5], lens2, pieces[7] })
  check(W4[1].director == nil and tostring(W4[1].why):find("open"), "a 10 cm gap: the beam leaves into the open")
end

-- ── report ──────────────────────────────────────────────────────────────────
if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL " .. f) end
  print(string.format("smoke_beam: %d passed, %d failed", passed, #failures))
  os.exit(1)
end
print(string.format("smoke_beam: %d passed", passed))
