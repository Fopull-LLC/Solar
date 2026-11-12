# Career missions

The contracts, the money they move and the standing they earn. The plan is
`work/missions/PLAN.md` (shared scratch); each slice adds a section here.
The milestone arc is `docs/progression.md`.

## E1 — the economy fix (2026-11-11)

Ty: "I get stuck in loops of needing money to make the next contract's craft
requirements, so I end up doing repetitive simple and boring missions just to
get money and reputation." Four causes, each fixed in code:

**1. An advance on signing** (`missions.lua` `ADVANCE_SHARE`, `advanceFor`).
Signing pays 30 % of the reward at once, for every generated contract (ground
work too) and the ladder from The High Road up (`advance = true` on the rung:
High Road $1,500, Deep Core $1,950, Made Orbit $3,300, Rendezvous $7,200).
Completion pays the rest (`payout`: reward − `mission.adv`). Abandoning hands
it back through `company.clawBack`: what the balance covers is taken, the rest
goes on the books as money owed (`co.loan`, repaid from 25 % of income like
Mission Control's advance) and then the walk-away costs 2 reputation, not 1.
A contract signed before E1 has no `mission.adv` and pays in full.

**2. Two contracts on the books** (`missions.lua` "TWO CONTRACTS ON THE
BOOKS"). One flight contract and one ground or client job (`slotGroup`:
generated ground work, the ladder's on-foot rungs Field Botany, Prospector and
Deep Core, and later the client families). Each slot keeps its own id, spec,
latches, high-water marks, odometer and advance. Slot 1 is the save keys a
one-contract save always had (`mission.active`, `.activeSpec`, `.seen`,
`.perm`, `.odo`, plus `.adv`); slot 2 the same with a `2`. An older save's
contract is simply slot 1, whatever its kind: nothing migrates. The tracker
runs once per slot with that slot's state swapped in (`with_slot`); between
calls the primary (flight) slot is swapped in, so `missions.active`,
`odometer()` and the flight HUD read the flight contract first. API:
`actives()`, `isActive(id)`, `signBlock(m)` (the sentence when its place is
taken), `accept(id)` → `true` | `false, why`, `abandon(id?)`,
`goalLines(id?)`, `activeLine(id?)`, `forceComplete(id?)`, `advancePaid(id)`.

**3. Ground work earns standing, to Trusted** (`GROUND_REP`, `GROUND_REP_CAP`,
`repOf`). A bulk haul and a survey drive pay +1 reputation through
`company.addRep(d, why, { cap = 8 })`; a supply order stays money only. A haul
rolled before E1 (rep 0 on the board) earns its point too.

**4. Mid-game prices.** RCS research $2,600 → $1,800; Docking Port $3,800 at
rep 6 → $2,400 at rep 4; Skipper rep 8 → 6 (`research.lua`). Crusher $18,000
→ $9,000, Furnace $32,000 → $16,000 (`parts_kit.lua`, progression PLAN §6 Q4).

Also:

- **Mission Control's advance** (`company.lua` `ADVANCE`, `advanceAmount`)
  steps in under $600 (was $300) and is at least $2,500, or half the craft the
  cheapest open contract needs (`missions.openCraftCost`: the contracts on the
  books, else the board; the ladder's `craft`, a generated flight's orbiter
  scaled by the trip, a rover for a haul).
- **Hull insurance** (`company.INSURANCE`, `insuranceRate`, `insureLoss`;
  `vessel_controller.insureHull` at the two loss sites, latched per craft): a
  flown craft with a command part, lost and not recovered, refunds 20 % of its
  parts' cost at Contractor, 35 % Trusted, 50 % Prime. Not in a sandbox or a
  scenario.
- **A client group on the board** (`CLIENT_SLOTS`, `group_of`): a generated
  kind with `client = true` rolls into its own slots (1–3 by standing), takes
  the second place on the books, and may carry `expires` (agency seconds). No
  kind has it yet: rescues and salvage runs (R1, X1) fill it.
- **Revert to launch** restores the slot-2 keys and the advances
  (`vessel_spawner.lua` `REVERT_KEYS`).

**The Ops Board** lists both contracts under "On the books · n of 2"; the
detail says which place a contract takes, the advance ("Advance $3,300 on
signing · $7,700 on completion"), the reputation (and its ceiling for ground
work); an offer whose place is taken keeps its SIGN greyed with the reason;
the armed abandon names the advance going back. **The objectives card** puts
both contracts on the switcher (/), adds "Also on the books: …" under the one
it follows, and its pay line reads "$7,700 on completion ($3,300 advance
paid)"; the paid banner says the advance.

Tests: `smoke_contracts` (the E1 section), `smoke_economy`, `smoke_ops_board`,
`smoke_objectives`; engine: `tools/perf/careerprobe.sh` (`career`, `careerold`
on a copy of a player's save).

## D1 — deaths cost reputation (setting, 2026-11-11)

Ty: "it's really easy to kill astronauts which sucks for reputation, so let's
make a setting for whether killing astronauts reduces your reputation."
`crew.deathRep` per save, default ON (`crew.lua` `deathRep`, `setDeathRep`).
`kill` takes 2 reputation only while it is on, for our crew and for a client
record (a rescue's survivor: "client lost"). Permadeath, the memorial and the
dropped pack are untouched; abandoning a contract is not under it. Rows:
Settings ▸ Agency "Deaths cost rep" (hidden while the crew are Invincible) and
the new-save panel's "Losses" (Deaths cost rep / Standing spared). Tests:
`smoke_crew_death`, `smoke_settings`, `smoke_sandbox`.

## S0 — career story beats (2026-11-11)

Ty wants story in career missions: named people, dialogue, immersive moments,
few popups. The scenario runner's beat engine now plays in a career save
(`scenario_run.lua`, the marked `CAREER BEATS` section): `runBeats(list, ctx)`
with `ctx = { id, cast, vars, refs, marks, crew, sequences, hooks, onDone }`.
Only the beats in `CAREER_BEATS` run (say, ops, caption, choice, shot/camera,
wait, sound, var, add, branch, face, look, turn, gesture, pose, walk, board,
drive, place, charge, give, wear, weather, mark, hook, run, cutscene); a
scenario's goals, steps, objectives and structures are dropped and named in
`lastCareer.dropped`. Nothing writes `scn.*` while a career run plays (the one
choke point is `sset`); the variables are the caller's table; marks and refs
are the run's own (`mark:<name>`, a function re-read every frame for a moving
point). One run at a time, the next waits its turn; `stopBeats(why, id)`
ends one. A scenario save refuses (the scenario owns the runner). The plate is
scenario_stage's (the cast's portrait, a live render target too); a radio
voice (cast `radio`, or Ops) goes to the Ops strip, garbled when its `link`
reads no comms path, as in a scenario.

The people and their lines are data in `scripts/mission_story.lua` (on
ScenarioLib): families (buyer, survey, flight, rescue), each with a cast and
a few variants per event (`accept`, `delivered`, `failed`; for rescues `near`,
`contact` with the one choice, `carried`, `admitted`), with `{name}`,
`{company}`, `{dispatcher}`, `{body}` filled in. The contract's id picks the
client company (eight of them, each with a dispatcher) and the variant.
`missions.storyEvent(m, event, extra)` plays them; generated contracts fire
accept, delivered and failed (abandoned). Tests: `smoke_scenario_career`
(beats in a career save, the plate and the strip, garble, a choice into the
caller's vars and a hook, a shot riding the moving planet, a survivor found
off the roster, nothing written to `scn.*`, the queue, a scenario save
refusing); `smoke_scenarios` unchanged.

## N1 — survivors and carrying (2026-11-11)

A **survivor** is a crew record with `client` (the contract's id), kept off
the roster in `crew.clients` (`newClient`, `removeClient`, `clients`,
`everyone`): not on the roster panel, not counted by `living()` or the hire
fee, never chosen by the handoff or the switcher; on foot a CrewBody like
anyone (`body_sync`), breathing from the suit (`recordTick`), treatable with
a Medkit, lying downed without bleeding out (the contract's clock is the
danger). A survivor who dies goes by `clientDied` (no memorial; −2 rep only
while `crew.deathRep` is on).

**Carrying** (Ty: "strap them on your back which weighs you down"):
right-click someone lying on the ground → Carry (`crew.carry`): no body, the
record rides the carrier (2 Hz), and `planet_walker.extraLoad` adds
`CARRY.kg` = 60 kg effective (30 with a Stretcher in the pack) to the pack
through the walker's encumbrance curve. Right-click yourself → Set them down
(`putDown`, in front, lying if down). Boarding a craft with them on your back
seats them in a free seat (`seatCarried`), else sets them down. A survivor
who can walk (hp ≥ 0.35, not down) gets Follow me / Wait here: they walk
2.5 m behind you (`followPoint`, `crew_body.steerSelf` at 2 Hz) and board when
you do. `carryRefusal` holds the refusals as sentences (a rope up; a ladder to
a hatch over 1.2 m; a jump over 0.4 m); wiring them into the rope and hatch
code is R1's. The **Stretcher** (items, 12 kg, $260) is stocked once the
Medical Bay has taken in its first survivor (research `stretcher`, featGrant
`medevac`). **Recall** (the roster panel): `crew.recall` did not exist and the
fallback set a downed member to "base" still bleeding, so they died at the
base; now `recallWhyNot` refuses the downed ("carry them home, or treat them
with a Medkit first") and the one you are, the fee is taken only after it is
allowed, and a member found at the base still downed (an old save) is
stabilised. `CAUSE_TEXT` has air, hypoxia, gas, cold and hotair. Tests:
`smoke_medical` (the crew half).

## M1 — the Medical Bay (2026-11-11)

Ty: "a new medical bay building on the home base that should be connected to
the lab. It should have a drive-in area and a walk-in from the lab … when you
go in there and talk to them they heal you for free." `FacMedical` stands at
u −34, v 34, face S, between the Research Lab and the VAB
(`base_facilities.lua` FACILITIES; `tools/base_buildings.py medical()`). Its
roller door (4.4 × 4.0 m) opens south onto **Medical Alley** (a yard strip
from Road West's north edge between the depot and the VAB); its west doorway
meets the glazed link (`prefabs/MedLink`, the bay's origin) that runs to the
lab's new east door (`Med Door N/S` in LabInterior, opened by `lab.lua` only
while the link stands). Inside (`prefabs/MedInterior`, `tools/gen_medical.py`,
drawn within 60 m): a treatment area with two beds, curtains, monitors, a
crash cart, cabinets, a desk; the sealed bay floor with its box and stop line.
Its own signs are `textures/medical/signs.png` (`tools/med_signs.py`); the
base atlas is untouched.

`scripts/medical.lua` runs on it. **Dr Imke Rao** (LabScientist, bound to the
bay) stands at Bed 1. E at her (or right-click → Talk): a medium shot, and the
talk plays as a career beat run on the plate with her live portrait (a render
target). Hurt, dosed or burned, "Patch me up": a line, a 5 s shot of her at
work, `crew.medTreat` (hp, dose, a downed wound, the heat, a full suit, free),
and she names what it was (`crew.lastCause`: hurt keeps `hurtBy`). A member
hurt at the base: "See to <name>". Nothing wrong: a line and no menu.
**Admit**: a survivor carried in, walking in or seated in a craft on the bay
floor is laid on Bed 2, treated, recorded (`medical.admitted`), the feat
`medevac` is marked and `missions.survivorAdmitted(id, client)` is called
(R1's survivor goal); her line and the client's (`mission_story` admitted)
play. The drive-in box (`inBay`) is the repair bay's over the bay floor;
`craftIn` names a craft standing there. **Old saves**: the grade is checked
once more (GRADED .2); `medical_site` puts the bay on the first of
`MEDICAL_SITES` with none of the player's structures on it (the link's run
included) and Ops says once where it stands (one strip line). Sounds: the
recorded fan (room air) and a pneumatic hiss at the treatment. Tests:
`smoke_medical` (the bay half, the lot and site, the lab's zones);
engine: `tools/perf/medprobe.sh` (`med`: walk in from the lab, talk, heal,
carry a survivor in, a story run; `medrover`: drive into the bay).
