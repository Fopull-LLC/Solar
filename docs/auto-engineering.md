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
| **Telescopic Fork** | a FRONT face (stands upright whatever it is on) | a Moto Wheel between its legs | Steers on A/D about a 24° raked head; 22 cm of travel (a dirt bike's 250–300 mm); the bars turn with it. |
| **Swing Arm** | a REAR face | a Moto Wheel in its jaws | Rear suspension: pivot and monoshock, 20 cm at the axle; never steers. |
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
- A bike with neither a rider nor a gyro falls over once its tyres are out;
  parked and unridden it stands on its stand (§3b).
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

**The joint slides along the part's own axis.** A fork's rake and a turned
swing arm are the joint's real axes (`auto_drive.suspAxis`; upright only
where the rake can't carry the axle). From the 2026-10-27 playtest ("the bike
drives much better BACKWARDS than forwards") to engine 0.117.1-dev.1374 every
joint slid upright instead (`auto_drive.jointAxis`, now gone): the engine's
wheel joint locked a wheel's off-axle spin with a rounding error that braked
every wheel in proportion to its speed, worst on two wheels in line and on a
raked axis (floptle 0579).

**One friction budget per tyre.** The project sets `wheel_friction:
Some(Single)` (floptle 0575): a wheel-joint tyre grips by its friction times
its load, once. Before it, the tyre's ground contact spent its friction too,
about 2μN. `R2_TYRE_MU` and the drive were retuned with it (vessel_controller
"The tyre's friction"): tyres of friction 0.9, and
the traction control's lead adapts to the push it allows (the wheelie cap
included) up to `R2_LK_MAX`. It is remembered for each way (a raked bike needs
about three times the lead forwards; learnt only on more than half stick,
rolling that way and not braking, and a start picks up at most
`R2_LK_START`, 12), dropped to 1.5 off the stick and forgotten after
`R2_LK_FORGET` (2 s) let go. The push stays under 0.7 of what
would lift a bike's front wheel.

## 3b. Building it any way you like (playtest 2026-10-26)

"motorcycles are hard to build right… sometimes it gets the direction wrong
and it drives better backwards… people are free to build how they want and it
recognizes what you build". What the flight now reads from the build, and why:

- **The rider no longer shoves the bike.** The rider rides as the
  astronaut's kinematic capsule (2 m × 0.33 m), parked in the saddle, and on
  a saddle it reaches down through the frame and both tyres.
  `physics.ignorePair` (command_seat) does not stop a kinematic body's
  contacts on 0.117.0-rc38, so the capsule, re-placed every tick on a planet
  moving metres a tick, pushed the bike: a parked bike rolled off at up to
  1.8 m/s², under full drive it crawled at 0.4–0.7 m/s or went backwards, and
  which way depended on where the planet was in its orbit ("sometimes"). It
  was never the motors: the same bike with a Probe Core and a gyro instead of
  a rider did 14 m/s. While anyone rides a seat the capsule is shrunk to a
  point (`motoRiderShape`, vessel_controller) and given back when they are
  off it. motoprobe `bikelab`, `tinyrider` A/B: 0.4 → 15.6 m/s; a 28 % ramp
  (32 % at its steepest) climbed in 7.6 s.
- **The front is the fork's.** A fork (or a swing arm's other end; from the
  arm to the fork when there are both) says where the front is, whichever
  way the saddle sits (`r2MotoFront`). A seat or a probe core put on sideways
  no longer turns W into a sideways push: when most wheels would roll across
  the front, the front is turned onto the line they roll on
  (`r2RollFront`). A tilted command part is a plane's nose only on an
  aircraft (a cockpit, Aircraft mode, or nothing else saying where the front
  is).
- **Every wheel rolls along the craft.** A wheel whose axle stands upright
  or runs within 60° of the front (on a front face, on a strut bolted to a
  front face, a landing gear turned on its leg) is laid across the front;
  the drawn tyre follows (`r2WheelSetup`, `R2_REALIGN`, and the same in
  `motoScan` for a wheel on a suspension part).
- **Two wheels and no rocket engine is a bike**, whatever commands it
  (craft_mode: a Probe Core and a gyro ride as well as a saddle; it was
  "Rocket", and its wheels only rolled).
- **The stand.** A bike nobody rides (tyres in) stands on its moto wheels'
  boxes made `BIKE_STAND` (0.3 m) wide across the axle: a centre stand. It
  used to fall over the moment the rider stepped off.
- **The builder says what is missing** (`builder.wheelChecks`, in the launch
  check): driven wheels with no battery; wheels and no motor; a two-wheeler
  with no seat and no gyro; a bike's wheels out of line by more than 4 cm.
  The old "wheels on more than one axle line" warning is gone: the flight lays
  every wheel along the front now.
- **Snapping lands exactly.** The grid used to run from a face's corner, so
  on a Strut Hub (0.24 m) the hull grid's 25 cm left only its edges and a
  part could not be centred at all, and on a Rover Body's top it was 5 cm off
  the centre line. A face's grid now runs from its centre, which always snaps
  (`builder_attach.faceSnap`; a frame member keeps its grid from end A), and
  a part's own hubs and ends — a fork's or swing arm's hub, a strut's flange,
  a wheel's axle ends — win outright when the cursor is anywhere on that part
  (`HUB_PX` from beside it). tests/smoke_snap.lua; motoprobe `snapbuild`
  builds the bike and a strut car through the builder's own query with the
  grid on, 16 joints, every one exact (0 m).

## 3c. Landing gear (playtest 2026-10-26)

"sometimes the jet / aircraft's landing gear points in the wrong direction or
is like fighting and it makes the aircraft jump around crazily". Two causes,
both in vessel_controller's wheel code:

- **Pointing the wrong way.** A gear's axle was its part's Z, so a gear turned
  on its leg, or hung from a part whose axes run another way (the builder's
  `radial_orient` takes the host's axes: on a hub block or a plate the gear's
  Z ran along the nose), rolled across the runway and its tyre's side grip
  fought the take-off roll. Every gear is now laid across the craft's front
  (`r2WheelSetup`); motoprobe `jetgear` 1 (every gear turned 90°), 2 (180°),
  3 (mains splayed 25°, nose 90°) and 5 (one main 90°, one 180°) take off.
- **Jumping.** At touchdown (2 m/s sink, 43 m/s) the engine pushed the light
  tyre 0.28 m up its leg in two ticks — further than the sink could carry it —
  and the wheel joint's spring, at 91 kN on a 10 kN load, threw the 3 t jet
  back up at 7 m/s, 8–10 m over the runway, on every landing, on the old
  code too. Three answers: a tyre is never lighter than 1/12 of the load it
  carries (`R2_TYRE_RATIO`: the joint's stiffness works on the tyre's mass); an
  oleo damper on each leg's stroke (`gearOleo`, `R2_OLEO_C`, booked for the
  stress model); and on an Aircraft the gear may not push the hull up faster
  than `R2_GEAR_VUP` (1.5 m/s) while a tyre is down and 0.4 s after (taken off
  at the centre of mass, at most 4 g a tick, booked through it). Unbooked, the
  first versions of the last two read as a shock and tore the gear off.

## 3d. Gas engines (playtest 2026-11-03c)

"Add a motor engine vs an electric one to power vehicles … different-cc gas
engines. You place a chain item which snaps to an engine on one end and a
wheel on the other." Electric stays the default: a wheel with no chain runs
on its hub motor exactly as before.

| Part | What it is |
|---|---|
| **Gas Engine 50 / 125 / 250 / 500cc** | A single with its clutch and gearbox in one case (X forward, the gearbox sprocket on the left −Z, the exhaust on the right). 3 / 9 / 25 / 41 kW; 3 or 5 speeds. Stacks or sits on any face. |
| **Drive Chain** | A drawn part, placed like the Brace: click an engine (it snaps to the sprocket), then a wheel (the rear sprocket goes on the hub, in line). Its `size` carries the engine and the wheel (`e`, `w`), the sprockets (`front`, `teeth`) and its length; it is drawn again whenever either end moves (builder `chainRefit`). One chain powers one wheel; an engine can drive several. More than 30° out of the wheel's plane is refused. |
| **Gas Tank 4 L / 12 L** | Petrol (`gastank` L). Full on every rollout; all tanks drain and fill together. The level is part state (`st.gas`, nil = full), so fleet saves, splits and docking carry it. |
| **Gas Can** (item) | 10 L, a fill in litres kept per can. Beside a craft's gas tank, LMB held pours 2.5 L/s. The warehouse keeps its level (`fill.keep`). |

**The engine** (`auto_drive` §5): a torque curve through the peak, a clutch
that slips below `eng` rpm (so it pulls from a standstill and never stalls),
an automatic gearbox that is always in the gear that pulls hardest at the
road speed, the redline in top gear as the wheel's top speed, crank torque ×
overall ratio × 0.9 at the wheel (× the save's rating, like every motor). It
burns `lph` at idle plus `bsfc` L/kWh of the work the traction control lets it
do, only while the craft is driven; dry, it dies and its wheels roll free.
Throttle shut, it drags its wheel (`gasBrake`). `r2WheelSource` answers for a
chained wheel; the traction control, wheelie control and brakes act on that.
On a craft with a chain, a hub motor past its own top speed freewheels
instead of braking (a hybrid's 18 m/s front motor threw the bike down at 20).

**Second pass (2026-11-03):**
- *Starting.* An engine is off until the rider opens the throttle: the
  starter cranks it for 0.65 s (`engine_crank.ogg`, no drive yet), then it
  catches, idles off the throttle and pulls on it. It stops when the rider
  gets off, the gas runs out, or the ignition is killed: the engine part's
  `ign` toggle (electronics `gasengine`, "Engine start / kill"), bindable to
  any group key in the controls panel; switching it back on cranks it at once.
  Every letter is already a flight key, so auto-start on W is the default and
  the kill switch is an action rather than a fixed key.
- *Launch.* Wide open, the slipping clutch holds the engine at its torque
  peak (`rpk`), not at `eng` (gasWheel `thr`): +21–27 % off the line.
- *Shifts.* The box keeps its gear while it pulls within 4 % of the best
  (`GAS_SHIFT_K`: no hunting on a shift point), and a change cuts the drive
  to a quarter for 0.1 s, heard as a dip in the loop.
- *Mass.* A tank weighs its petrol (0.74 kg/L), written to the part's mass in
  0.25 L steps (massSync), about once a minute flat out.
- *Air.* Open frames carry `af = "fill=…"` (aero.lua): the moto wheel 0.55,
  the fork 0.22, the swing arm 0.35. A part's drag is that share of a solid
  box's and it hides only that share of what is behind it; the wake now
  hides every face of a part behind another, not only its ends. The
  player's bike went from CdA 2.7 m² to 1.4 (its rider 0.5, its locker,
  pack and solar panel most of the rest).
- *At speed.* A bike's push keeps more of the front's load past 14 m/s
  (R2_BIKE `liftHi` 0.55 by 24 m/s) and takes the nose-up of the drag on
  the rider off the budget (aeroTick's torque). The traction control's lead
  no longer winds up chasing a push the engine cannot make (R2.srcF).
- *Governor (gone):* `GAS_SAFE_V` held a chained wheel to 24 m/s while the
  tyres skipped past ~25 m/s (engine card 0628; the pure 500 fell in 3 of 4
  flat-out runs). On engine .1417 with the third pass it is nil: the pure 500
  ran flat out to 30.9 m/s 4 of 4 without a fall. The gearing's tops are 28
  (250) and 31 m/s (500).
- *The 125 on a 0.4 t bike:* 10.5 N·m is a real 125 four-stroke's, and first
  gear (39:1 overall) is already lower than a CRF125F's (27.5:1). Its 1.1 kN
  at the wheel is 0.29 g on 0.4 t: no 125 climbs 31° from a stop with that
  load. It climbs on a ~0.2 t bike. The moto parts weigh 2–4× a real dirt
  bike's (wheel 50 kg, fork 30, saddle 30, swing arm 25), which is the lever
  if lighter bikes are wanted.

**Third pass (playtest 9e675fb):**
- *The loop always stops.* Off, the engine's loop runs down over a tenth
  of a second and is stopped, not left muted (SFX.gas). Every frame
  (lateUpdate, dormant or not) a watchdog fades the drive and engine loops
  when no tick has fed them (the pause menu's `physics.pause`, a craft gone
  dormant, a wreck) and stops them after 0.8 s (SFX.watch). With every
  engine gone the loop still hears it is off. Wheels stowed with the rider
  still aboard (a long jump) keep the engine idling; with no one aboard it
  stops. (Pass 1 left `run` set when the wheels stowed after the rider got
  off, and the loop played again forever.) `tests/smoke_gas_sound.lua`.
- *A stator.* A running engine supplies `alt` EC/s (0.45 to 1.0 by size,
  a third of it at idle): a gas bike needs no battery for its gyro and
  lights. The player's gas bike had no battery, so its Balance Gyro never
  had any power.
- *Suspension travel.* Fork 22 cm, swing arm 20 cm (a dirt bike's
  250-300 mm). At 13 and 12 cm both bottomed on every pass over the bump
  course, and a landing on the bump stops kicked the bike 10-20° over in a
  tick. A wheel still droops no more than 6.5 cm (`R2_MOTO_DROOP`: how far
  the fork's sliders are drawn below their stanchions).
- *Riding technique* (`BIKE_RIDE2`): in the air the nose aims at the slope
  it will land on (the centre of mass's arc cast to the ground,
  `motoLandSlope`), measured off the wheel line (`motoPitch0`: a bike built
  with its rear wheel hung high sits nose up), rear wheel first. Throttle
  (W) lifts the nose 6°, the rear brake (S) drops it 10°. The front is
  held along the flight (the wheels' gyroscopic stiffness and the rider's
  hips, `RIDER_YAW`): loose, a bike yawed off a kicker, landed 4-6° across
  its own path, kicked to 1 rad/s of yaw on the tyres and slid out. On the ground
  past 4 m/s the rider stands on the pegs: pitch the ground did not ask for
  is damped, and past 10° off the ground's slope it is sprung back
  (`motoPitch`, `RIDER_PITCH` 1.4 kN·m plus half the gyros'), 1.8 times as
  hard for half a second after a landing, and for a second after it a yaw
  the lean does not ask for is damped too (landed with the throttle open,
  the rear stepped out and the bike spun out sideways). The gyros' torque is one budget
  shared by roll and pitch in the air, and the rider's body adds its own on
  each axis.
- *The gyro* acts through `assembly.torque` on the whole craft, so where
  it sits does not change its torque (as for a real control-moment gyro).
  Its 60 kg moves the centre of mass, which is why moving it near the engine
  changed the handling a little.
- *The bump course* (jumpprobe `vbump`): 14 whoops, a kicker and a
  run-out on the flat strip, ridden from a standstill at each speed.
  Between passes the probe holds the bike in the air, square to the strip,
  and sets it down (`JP.reset`; `JP.place` now does the same, so a hill is
  never met at an angle).
- *The Drive Chain tool* is done after one chain: back to select, with the
  new chain selected.

**A tyre's load (engine .1421/.1423, card 0629).** `node.contactForce` on a
tyre is the ground's push over the last step (kN, 0 the tick it leaves), and
since .1421 a held tyre's load over ripple is no longer counted twice, so
landing grip is honest.
- *Read once a tick* (`r2Contacts`, r2Tick): each wheel's `w.down`
  (grounded) and `w.load` (contactForce), `R2.loadF` / `R2.loadR` at the
  ends. Every reader that tick (the wheel count, the wheelie control, the
  hill hold, the dampers, the oleo, roundTwoState) uses them, not the node.
- *The rear tyre's slope* in a wheelie is its contact's `groundNormal`, not a
  ray cast down from it.
- *The grip cap* (`R2_GRIP_K`, the bike block): at a launch and a crawl the
  push is held to the driven tyres' friction × their load (smoothed at
  `R2_GRIP_RATE`), faded out from `R2_GRIP_V0` to `R2_GRIP_V1` (6 to 10 m/s).
  It stops the rear stepping out off the line (the electric bike: 17° of roll
  at 3-4 m/s, now 0.5-3.7°). Kept on at speed it cut the push on every whoop's
  crest and the nose dropped into the next: 3 falls in 3 at 28 m/s.
- *Probes*: jumpprobe counts a tyre off by its load (`JP.down`, and how often
  `grounded` disagreed: `odd`), JP RIDE and JP BUMP give the loads in weights
  (a landing on the bump course peaks at 5-11 W), and `vload` compares a
  parked or rolling bike's loads with its mass. `assembly.info().mass` leaves
  out the tyres (bodies of their own) and the seated rider (a kinematic body,
  0.14 t, in no mass), and a parked bike's tyres carry 105-109 % of
  info.mass × g, 90-91.5 % of chassis and tyres (asked of the engine:
  `work/gas/card-0629-acceptance-solar.md`).

**Fourth pass (2026-11-04, engine .1426): flat out, landings under power.**
- *The "wheelie" flat out was a crash.* The 39-58° peaks the vride and
  vhill flat-out runs reported were the bike reaching the end of the probe's
  strip at 29 m/s: the natural ground there stands up like a wall (front
  load 72 kN, 29 to 5 m/s in a tenth of a second). Both runs now stop 30-40 m
  short of the strip's end. On the strip itself the 500 holds its nose within
  3-5° of its seated pitch from 20 to 29 m/s. The front skims (off the ground
  about half the ticks past 25 m/s) because a light front tyre hops on the
  strip's ripple, not because the push lifts it: at 25 m/s the engine's
  0.55 g is well under the 0.88 g that would lift the front.
- *The slope while the front is up* is read in the chassis's frame, as it
  is with both tyres down (the rear contact's normal plus `motoPitch0`).
  Read as the ground's own slope, every skip of the user's 500's front (built
  6.6° nose up) counted as a 7° wheelie and cut the push.
- *In the air a driven rim keeps to the ground speed* (`R2_AIR_LEAD`,
  0.15 m/s). Led by `R2.lk`, it spun up 1-1.6 m/s ahead in every hop and
  landed with the push saturating the tyre: no grip left sideways, so the
  touchdown yawed at 1 rad/s and slid 3.6 m/s.
- *Traction control at any speed* (`R2_TC2_*`, the last rule on the push,
  after the landing's blend). The push is held to 0.7 × μ × the driven
  tyre's load (0 in the air, dropping at once, coming back at 8 /s), which
  leaves the rest of the grip to hold the tyre sideways. It acts only while
  the rear is in trouble, never on low load alone:
  - for 0.6 s after a flight of 0.3 s or more;
  - while the rear tyre slides across its tread faster than 0.3 m/s (fully
    by 1.0);
  - while the rear carries under half its share and its rim runs ahead of
    the ground by more than 0.6 m/s.
- *The front alone on the ground* past a walk (a landing's first touch, the
  rear kicked off a whoop): the balance's bars keep a quarter of their angle
  (`BIKE_FRONT_ONLY_K`). A steered front tyre loaded at 5 W, with nothing on
  the ground behind it, yawed the bike at 1.3 rad/s before the rear came
  down.
- *In the air the gyros serve roll first* (motoAir): whatever roll the
  rider's body cannot take comes from the gyros before any pitch or yaw.
  Shared out by size, a long nose-high flight spent almost all of the gyros
  on pitch.
- *Probes:* `JP BZ` reports each bump pass's roll in the whoops and at the
  kicker, the slide off the lip and the rear's least load after the landing.
  `ttrace=n` traces the flat-out run tick by tick (the push and its caps, the
  loads, the gear, the rider's torques, the traction control). At 28 m/s, pass 2
  of 3 hit the kicker's face hard in two of four runs, losing 3-13 m/s in a
  tick (the fork bottoms, 3.4 rad/s of yaw, a 4.7-7.4 m/s "slide off the
  lip"). That is the course's sculpt (three 1.7 m brushes across), not the
  run-up: on the other passes the bike leaves the lip at under 0.2 m/s across.

**Heard and seen**: a running loop per craft (`audio/foley/engine_four.ogg`,
`engine_two.ogg`, `tools/gen_engine_audio.py`) pitched by rpm, and a
`TailpipePuff` out of each running engine's tailpipe (lamp_response 0.3).
The flight HUD has a GAS bar beside FUEL and CHARGE when the craft carries
gas (its tooltip: the engine, rpm, gear, burn and time left).

**Refuelling**: the Repair Bay's work order fills the gas (`gas_price`, $0.6
a litre); the bay's gas pump (west wall, between the lift and the propellant
dispenser) fills a Gas Can in hand while E is held, paid by the dollar.

Files: `scripts/parts_auto.lua` (parts), `scripts/auto_drive.lua` §5 (maths),
`scripts/vessel_controller.lua` GAS, `scripts/builder.lua` (the chain tool,
`chainRefit`, launch checks, the GAS header line), `builder_attach.chainBetween`,
`builder_proc.chainArrays`, `scripts/items.lua` / `item_hand.lua` (the can),
`scripts/repair_bay.lua` (order line, pump), `tools/gen_gas_parts.py`
(meshes, prefabs), `tools/base_buildings.py` (the pump), `tests/smoke_gas.lua`,
`tools/perf/gasbike.py`, `gasprobe.lua` / `gasshots.sh`, jumpprobe `JP GAS`.

## 3e. Wheels on servos, hinges and pistons (playtest 2026-11-04)

"I tried adding a servo joint and then attaching my back wheel to it … when
a wheel is attached to a servo joint it just doesn't work whatsoever." A
wheel moved by a robotic part (built on a hinge, a piston or a rotor, or on a
swing arm hung from one) used to ride rigid: its tyre never came out, so the
bike sat on that wheel's box and could not roll at all, chain or no chain.

**Now it is a wheel like any other.** Its tyre comes out and hangs on the
wheel joint at the mount *as the joints have posed it*
(`vessel_controller` `roboMountScan` / `roboMounts`): the rest mount, the
suspension part's axis and the axle carried through every robotic part that
moves the wheel (`robo_pose`). A turn of the axle about the suspension's axis
is added to the wheel's base steer, so a servo that swings an axle round
steers it. When the servo moves the mount more than `ROBO_REHANG_M` (4 mm)
or turns it more than `ROBO_REHANG_DEG` (0.5°), the joint is made again
there, keeping the motor, brake and bars that `drive_tick` left on it. So
the wheel drives, brakes, steers and springs through the move, and the servo
works while you ride: a tilting swing arm, a lowering rear, a ride-height
servo.

**The chain (auto_drive §6).** The engine's sprocket stays put and the
wheel's moves, so the run between them changes. The chain is re-laid along
the new run (`roboChains`). It is given a spring tensioner's take-up, its
**slack**: 8 % of its run, at least 4 cm, either way (`CHAIN_SLACK_K`,
`CHAIN_SLACK_MIN`). Within that slack the engine's whole torque reaches the
wheel. Past it the chain skips teeth, and the drive fades to nothing over
another slack's length (`chainShare`). The wheel then rolls free until the
servo brings it back. A caption says so once. The chain never locks the
wheel and never breaks the build. A real swing arm pivots beside the gearbox
sprocket, so its chain barely changes over the arm's travel; a hinge there
keeps the drive over most of its ±90°. A hinge far from the sprocket soon
pulls the chain past its slack. The builder says so before launch
(`builder.chainJointChecks`, in the wheel checks): "the Drive Chain to the
Moto Wheel keeps its drive only from -7° to 7° of the Servo Hinge's ±90°…".
That is a warning only; the craft still launches.

Probe: `tools/perf/servoprobe.sh <engine> [none arm direct elec far]`
(`servoprobe_modes.lua`). Smoke: `tests/smoke_servo_wheels.lua`.

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
