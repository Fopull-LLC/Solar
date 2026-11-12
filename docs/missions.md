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
