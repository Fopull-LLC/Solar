# A parked craft sleeps while piloted (rc27, 2026-10-25)

Engine 0.117.0-rc27, the player's save (Zorosia, carried at 5.79 m/tick) unless
marked fresh. Every run one `bench.sh` play under the shared lock; load in brackets.
Probe: `tools/perf/perfbench.lua` — `trace=1` (on with `dump=1` / `e_secs`) puts a
proxy `assembly` table into each Solar script's environment and counts every
force / torque / forceAt / impulseAt / velocity / anchor write by call site, per
watch window and per dumped tick (`DUMP R … calls …`).

## What Solar wrote on a parked, piloted craft every tick (before)

Braked 6-wheel rover, 0.59 t, 45 s window (2,699 ticks) [load 6]:

| site (vessel_controller) | what | ticks | magnitude (min / mean / max) | per tonne max |
|---|---|---|---|---|
| aeroTick `assembly.force` | the weather's wind on the parked hull | 2699/2699 | 0.162 / 0.224 / 0.270 kN | 0.457 m/s² (4.6 % g) |
| aeroTick `assembly.torque` | the same wind's moment | 2699/2699 | 0.019 / 0.026 / 0.034 kN·m | 0.057 |
| wheelTorque (via r2Steady, SAS stability) | reaction wheels damping the rocking on the springs | 2699/2699 | 0.012 / 0.211 / 0.83 kN·m | 1.4 |
| drive_tick anti-roll bar `assembly.torque` | lean over the tyres × 2 m·g·track | 2699/2699 | 2e-5 / 0.020 / 0.113 kN·m | 0.19 |

1,002-part spine released on the pad, 80.2 t, 20 s (1,187 ticks) [load 6]:

| site | ticks | magnitude | per tonne |
|---|---|---|---|
| aeroTick force (wind) | 1185/1187 | 7.5 / 8.9 / 10.7 kN | 0.134 m/s² (1.3 % g) |
| aeroTick torque | 1185/1187 | 1.9 / 2.3 / 2.7 kN·m | 0.034 |
| wheelTorque | 1187/1187 | exactly 0 every tick (|v| and angVel read 0.000) | — |

No other per-tick write on either: waterTick returns before its force when no part
is wet (already gated, `#cells == 0`); RCS only when firing; chute/re-entry drag,
hull bumps, dock assist, safety impulses are all conditional and did not run;
massSync writes masses only on change; the crew seat writes a kinematic passenger
(not a force; the rc27 patches 1–3 already showed it is not a waker);
command_seat / planet_walker / flight_ops / tool_belt made no assembly write on the
craft. **Joint writes** (`steer`, `motor`, `motorSpeed`, `maxForce` every tick in
drive_tick): the engine copies them into the solver each frame without waking
(floptle-physics sim.rs ~776–800); a joint only keeps an island awake when it
*drives* (`motor` with `motorSpeed ≠ 0`, or a servo: joints.rs `drives()`), and a
parked rover's brakes hold at `motorSpeed = 0`. Not gated: rewriting identical
values costs nothing and wakes nothing.

## What is gated (vessel_controller.lua)

`parkedStill(node, info)` (cached per tick): not clamped; on the ground
(`info.grounded` or on its tyres); time warp 1×; throttle 0; RCS not firing; no
probe command (`R2.cmd`, `AERO.cmd`); |v| < 0.25 m/s and |ω| < 0.10 rad/s; and,
when piloted with control, none of W A S D Q E Shift Z Space held. While it holds:

- **aeroTick:** the air's force and moment are not applied when they are under
  0.1 g of push and 0.025 g·m of turn per tonne (the part-by-part stress booking
  still runs). A braked craft on the ground does not move under that — the brakes
  and the ground's grip hold it; a stronger gust still pushes (and wakes it).
- **wheelTorque** (every reaction-wheel torque, including r2Steady's): skipped when
  the rate error is under 0.20 rad/s — the rocking of a parked craft, not a command.
  A pointing-mode error is larger and still turns; a craft that starts to tip
  passes 0.10 rad/s and ends parkedStill.
- **anti-roll bar:** skipped when its torque is under 0.1 m·g·track (a lean under
  ~2.9°); a rover parked across a steeper side-slope keeps it.

Any input ends parkedStill on the same tick, the forces come back, and the engine's
own wake-on-force wakes the craft: W woke the rover in 2–3 frames (the key reaches
the script the frame after `input.simulate`), Z woke the 1,002-part craft in 2.

## Before / after

| | before | after |
|---|---|---|
| rover braked, piloted: asleep | never (45 s), wake `joint` 2846/2846 frames [6] | asleep 0.02 s after the brakes went on (final run) — ≤1.9 s in the first; stayed asleep 45 s, 0 Lua writes in 2,700 ticks [5–12] |
| rover physics ms/frame | 0.47 (static 0.40) awake | 0.08–0.09 (static 0.05) asleep |
| W (brakes released) | awake 1st frame (it never slept), 10.1 m/s after 2 s | awake after 2–3 frames, 10.13–10.14 m/s after 2 s |
| braked again, stopped | never asleep in 20 s, `joint` | asleep 0.66–0.69 s after stopping, stays asleep 20 s |
| 1,002-part craft released, piloted: asleep | never (20 s), wake `force` 178/179 [6] | 0.63 s after release [7.7]; 8 frames after release [16] |
| its physics ms/frame | 47.5 (static 45.4) | 0.84 (static 0.15); 0.6–1.4 in the final run |
| Z (full throttle) | — | awake after 2 frames, thrust 44.3 kN (the spine's one engine cannot lift 80 t: it moves 0.08 m, same as before) |

Plane (fresh save, the 27-part jet's take-off roll; 'before' = the gates reverted
with `PATCHES`; one before run discarded, its patch failed to apply):

| | liftoff s | speed m/s | roll m | load |
|---|---|---|---|---|
| before 2 | 9.7 | 48.9 | 213.5 | 8.7 |
| before 3 | 10.0 | 49.9 | 226.1 | 6.7 |
| before 4 | 9.7 | 48.9 | 213.9 | 8.1 |
| after 1 | 9.9 | 49.8 | 224.6 | 10.1 |
| after 2 | 10.1 | 50.3 | 231.0 | 12.6 |
| after 3 | 9.8 | 49.1 | 216.1 | 5.3 |
| after 4 | 10.3 | 49.5 | 220.5 | 7.4 |

Before 9.8 s / 49.2 m/s / 218 m (213–226); after 10.0 s / 49.7 m/s / 223 m
(216–231): the ranges overlap, within noise (a moving plane is never parkedStill).

Gameplay smoke, fresh save, after [5.6]: starter apex PASS (285 m), revert PASS,
rover rollout PASS, rover drive PASS (100 m in 6.8 s), **orbit FAIL — the same
pre-existing probe failure as every rc27 run before the change** (circularisation
burns while falling, reads escape; results/rc27.md "Gameplay smoke"), plane
take-off PASS (10.2 s), 1,002-part rollout PASS, release PASS (root asleep 1.0 s).

luajit sweep: 70 tests, 0 failed. `floptle check`: 0 errors, 6 warnings.

**One bigpark run of five dropped the craft:** the spawner logged "waiting for the
pad's ground… (5s)" and assembled anyway; at release the ray found nothing under
the CoM within 600 m (every other run: `Shell 3 < BasePad < Zorosia`), and the
craft fell at ~g, 15 m, into the water [load 12]. The gates do not touch a craft
that is not grounded; this is the spawner proceeding without the pad's collider
(vessel_spawner's ground wait), for its owner.

## For E

### (a) What the 1,002-part craft stands on

`Shell 3`, a child of `BasePad` under the planet node `Zorosia` (carried: the planet
moves 347 m/s, 5.79 m a tick): a **static box** RigidBody, half 4.00 × 0.40 × 4.00 m,
friction 0.9 — not a mesh, not terrain. Same on rc25 and rc27; craft grounded true.
(E's fixture — a tower lying on voxel ground — is a different contact: a box deck
under a standing stack.)

### (b) Writes on it (unchanged code, first 5 s after release, piloted)

| | rc25 [load 16] | rc27 [load 6.5] |
|---|---|---|
| aeroTick force | 95/97 ticks, 7.6–10.6 kN | 297/298 ticks, 8.0–10.7 kN |
| aeroTick torque | 95/97, 1.9–2.7 kN·m | 297/298, 2.0–2.7 kN·m |
| wheelTorque | 97/97, exactly 0 | 297 exactly 0, one 2.4e-4 |
| joint writes | none (no wheels) | none |

### (c) Physics split and the wake readout, per frame (5 s, unchanged code)

| | rc25 | rc27 |
|---|---|---|
| frames / **ticks** in 5 s | 64 / **97** | 52 / **298** |
| frame ms | 78 | 97 |
| physics ms/frame | 40.6 | 41.4 |
| static / sweeps / sleep / joints | 40.1 / 0.38 / 0.008 / 0 | 39.7 / 1.29 / 0.026 / 0 |
| **physics per tick** | **26.8 ms** | **7.2 ms** |
| perf.bodies | Vessel ≈ all of it | Vessel ≈ all of it |
| wake readout | `settling` 63, `script` 1 | `force` 51, `script` 1 |

**The per-tick cost fell 3.7× on rc27; the per-frame figure is higher only because
rc27 runs more ticks a frame.** On rc25 a 26.8 ms tick is over the 16.7 ms slice, so
the tick overload policy plays the game in slow motion (97 ticks in 5 s: a third of
real time, ~1.5 ticks a frame). On rc27 the 7.2 ms tick is under the slice, so the
clock catches up (up to `max_ticks` 8; 5.7 ticks a frame here, since the frame is
~97 ms with Solar's scripts at 44 ms). E's fixture runs short frames, so it sees
the per-tick saving and not the multiplication. A second rc27 run shows it inside
one run: 14.4 ms of physics on 44-ms frames, then 36 ms as frames stretched to
85 ms, with the craft unchanged. (The asleep craft still costs 0.3–0.7 ms of
`physicsSleep` a frame.)

**Post-launch settle, rc27, three runs** (builder `onlycraft=1`, unchanged code,
fresh save, load 6.7–8.6): 12.44, 12.69, 12.30 ms of physics a frame for 20 s,
static 12.0–12.7, sweeps 0.23, sleep 0, joints 0; frames 41–76 ms; **root wake
readout `force` on every frame of all three** (437, 442, 436); never asleep (piloted,
the wind's aero force). All three were the fast mode; the 97 ms slow mode did not
reappear outside the five-mode bench. Given the above, the likeliest reading of
the bimodality is the catch-up: the same per-tick cost multiplied by 2–3 ticks a
frame (short frames) or up to 8 (a frame already long from the scene behind it).

### What the engine should do (general, any game)

1. **Judge rest by motion, not by who touched it.** `apply_force` / `apply_torque`
   (compound.rs ~389–412) wake for any non-zero vector. A held force that the
   body's support balances — a breeze on a parked car, a script's small steady
   push — moves nothing, and a body that stays within the sleep ball over the whole
   count should sleep with it applied. Measured: Solar's 0.13–0.46 m/s² of wind on
   resting craft kept a rover's physics running every frame (0.47 vs 0.08 ms) and
   a 1,002-part stack's at 45–48 ms a frame vs 0.84 asleep. A cheap form: a force
   or torque below a fraction of the body's weight (or unchanged since it fell
   asleep) does not reset the count; the existing motion test still wakes it if it
   moves. Solar now gates its own writes, but every game with wind, buoyancy or a
   stabiliser meets this.
2. **`wake` should name the latest cause, not the first.** `WakeReason::or_own`
   keeps any non-settling cause once set, so the rover read `joint` (from the
   release) on every frame of every variant, while the per-tick writes that kept it
   awake were a force and two torques; it took a Lua proxy over `assembly` to find
   them. Report the most recent waker (or a per-frame bitmask of all of them).
3. **Say how many ticks a frame ran.** perf.frames has no tick count; physics
   ms/frame read without it looked like a 1.7× regression that is really a 3.7×
   per-tick improvement. A `ticks` field per frame (and `physicsPerTick`) would have
   made this one line.
4. Catch-up and big resting bodies: with a project `tick_budget_ms` a frame could
   stop catching up before 8 ticks of a 7 ms awake stack; worth a default when the
   frame is already long.
