# Auto engineering: motorcycles, cars, trikes and rovers

Status: design and first build (2026-10-26). Inputs: the user's request for
"parts that will make building motorcycles easier… suspension forks… a wheel
that's like a through axle", `docs/builder-design.md`, `docs/ui-style.md`, the
rover code in `vessel_controller.lua` (R2) and the engine's wheel joint
(`floptle-physics/src/joints.rs`).

## 1. What a player should be able to do

- Build a motorcycle from a handful of obvious parts, ride it, lean it into
  corners and stop without it falling over.
- Put real, visible suspension on a car or a rover, and tune it.
- Hang things off both sides of a wheel.
- Mix all of it with the existing frame parts, so a ridiculous craft (a
  sidecar, a six-wheeled chopper, a trike with lamps on its hubs) is just as
  easy.

## 2. The parts (seven, in the ROVER section)

| Part | Mounts | Takes | Role |
|---|---|---|---|
| **Moto Wheel** | on a fork's or swing arm's hub (centred), or by an axle end on any face | anything on either axle end | 0.33 m spoked wheel, hub motor, disc brake. Its axle runs right through: it is the through-axle wheel. |
| **Telescopic Fork** | a FRONT face (stands upright whatever it is on) | a Moto Wheel between its legs | Steers on A/D about a 24° raked head; 13 cm of travel; the bars turn with it. |
| **Swing Arm** | a REAR face | a Moto Wheel in its jaws | Rear suspension: pivot and monoshock, 12 cm; never steers. |
| **Coil-over Strut** | a flank (car, rover, trike axle) | any wheel on its hub flange | 18 cm of travel; a strut ahead of the centre of mass steers about its own axis. |
| **Balance Gyro** | anywhere | — | Holds a two-wheeler up at any speed, crewed or not (draws power while it works). |
| **Battery Pack** | stack or any face | — | A tank-shaped 200 EC pack: a seat carries no battery, and a bike needs one. |
| **Moto Saddle** | stacks (its mount cradle) on a frame block, beam or pack; faces +X | — | A crew part for one: saddle and tank-tail shroud on a short subframe, footpegs hanging either side of what it sits on. Commands like the Command Seat (F to ride and to step off, the rider stays in view, the bike counts them as its rider); the rider sits astride, leaning forward, feet on the pegs, hands on the fork's grips. |

Why these and not more:

- **No separate axle part.** A through-axle *wheel* covers "stuff on the left
  and right": its two axle ends are attach nodes, so a strut each side (the
  user's "attach the forks to the side of a wheel"), a lamp, a fender bracket
  or a beam goes straight on. The fork and the swing arm clamp the same wheel
  in the middle.
- **Suspension is a part, not a wheel setting.** A wheel on a fork, arm or
  strut rides that part's spring; a wheel on a plain face keeps its stiff
  built-in travel. You *see* the suspension on the craft, and the wheel's
  existing Spring, Damper and Travel settings tune it (select the wheel).
- **One fork, one arm, one strut.** Their springs are sized from the load
  each wheel carries, so the same strut works under a 0.3 t buggy and a 2 t
  rover.
- **Fenders and frames** are the frame parts you already have (panels, drawn
  beams, the node block); nothing bike-only.
- **A saddle, not a chair.** The Command Seat on a bike looked silly (a
  high-backed chair perched on the frame). The Moto Saddle is the same
  command part (`seat = true`, crew 1: boarding, EVA, the cameras, the
  control mode and the bike's rider all treat it exactly as the seat); only
  the shape and the rider's pose differ. The pose is data: the part's
  prefab passes `scripts/command_seat.lua` its params (sit height, forward
  lean, peg and grip points; `tools/gen_auto_parts.py` writes them from the
  mesh's own numbers). With a fork on the craft the hands go to its grips
  (the fork's ForkSteer node, so they turn with the bars); without one they
  reach forward to a fixed point. Everything follows the part, so a lean on
  A/D tips the rider with the bike.
  Its part box is the Command Seat's height (1.30 m above the mount cradle,
  the rider's room) though the saddle is 0.3 m deep: the crew is parked at
  the command part's centre as a kinematic capsule 2 m tall, and parked at
  the saddle's own centre that capsule reached through the frame to the
  ground and shoved a parked bike off at 20–25 m/s (motoprobe). While they
  ride, `command_seat` also lets the capsule pass through the craft's hull
  and its own live tyres (`physics.ignorePair`, lifted when they get off).

### Attach rules (builder_attach, the hub patch)

- `hub` node — a point and an axle. A Moto Wheel held near a fork's or arm's
  hub snaps in centred, axle along the hub's. The other way round works too:
  put the wheel down first, then a fork held near the wheel's centre stands
  over it ("place your car on top of the fork").
- `end` node — a flank node at a given point: the strut's flange, the wheel's
  two axle ends. Anything mounts there like on any face.
- `upright` — fork, arm and strut keep their +Y on the build's up whatever
  they are put on (a fork on the end of a beam lying along the bike stands up
  instead of lying on its side).
- `mountpt` — the fork mounts by its head bracket, not its box centre.

## 3. How it behaves

**Suspension (real joints).** Each live tyre already hangs from the hull on
the engine's wheel joint. A wheel on a suspension part hangs along *that
part's* axis (the fork's raked head; the arm's and strut's upright) with a
spring that sits the corner a third into its travel (3 g bottoms it) and
damping near half critical. The engine's joint is a soft constraint on the
light tyre's mass, so `auto_drive.suspJoint` inverts its step to get the
spring rate and damper a corner wants, and clamps to what the joint can
carry. The fork legs slide, the arm swings and the strut's knuckle slides and
steers with the tyre.

**Bikes (all wheels in one line).** A/D ask for a **lean**; the rider's
weight (and feet, below a fast walk) or a **Balance Gyro** put the bike there,
and the **bars follow the lean** the way a real fork's trail turns it into the
fall: tan δ = L g tan φ / v². Leaned further than the turn, the turn tightens
and stands it up; less, it widens. So it leans into every corner and tips in
before it turns. At a walk the bars are the rider's (A/D, full lock).

- The lean asked for is capped by the grip (a lowside past it) and comes on at
  30°/s; the traction control never pushes hard enough to lift the front.
- A bike with neither a rider nor a gyro (a probe core alone) falls over.
- Parked, a bike is not brake-held (the parking hold tore its light tyres off
  their spots); B still brakes.
- `auto_drive.bikeSteer` (steering under the fall, a true countersteer, no
  torque) is kept behind `BIKE_STEER_BALANCE` (off): on the engine's ball
  tyres it held some probe runs and threw others.

W/S drive and brake as on any rover; the parking brake holds it when stopped.

**Steering axis.** The engine turns a wheel's axle from the chassis's Z about
the joint's axis, so a raked axis can carry a fork on a craft built facing
±X (the seat's default). On a craft built facing ±Z it can't: the fork then
steers about the vertical (it still works; only the rake is lost).

## 4. Controls summary

| Key | Rover / car / trike | Bike |
|---|---|---|
| W / S | drive / reverse, brake | the same |
| A / D | steer (front struts, the fork) | lean left / right (it steers itself into the turn) |
| B | brakes | brakes |

## 5. Engine gaps found (filed as cards)

1. A wheel joint's `position` (its suspension travel, metres) is written back
   through the degrees conversion for turning joints (× 57.3).
2. A wheel joint has no suspension travel limit (`min`/`max` are a slider's).
3. A wheel joint's axle is always the other body's Z turned by `steer`; an
   `axle` option would let a raked fork steer on a craft facing any way.

## 6. Files

- `scripts/parts_auto.lua` — the parts (registry entries, catalogue lines).
- `scripts/auto_drive.lua` — suspension, steering-axis and balance maths.
- `scripts/command_seat.lua` — the rider's pose on the Command Seat and the
  Moto Saddle (the prefab's params).
- `prefabs/AutoLib.prefab.ron`, `prefabs/Part{WheelB,ForkT,SwingArm,StrutS,Gyro,PackB,Saddle}`,
  `prefabs/WheelTyreB`, `prefabs/vis/…` — written by `tools/gen_auto_parts.py`.
- `tests/smoke_moto.lua`, `tools/perf/motoprobe.sh` + `motoprobe_modes.lua`.
- Patches (owned files): `vessel_controller.lua` (flight), `builder.lua`
  (catalogue), `builder_attach.lua` (hubs, upright, mount point).
