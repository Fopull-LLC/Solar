# Craft builder overhaul: UX analysis and design

Status: design, phase 1 (2026-10-23). Implementation agents build from this file.
Inputs: the user's builder request and playtest notes of 2026-10-23, `docs/ui-style.md`,
a full read of the builder code, and engine probes on 0.117.0-rc6 (method and numbers
in section 2).

---

## 0. Executive summary

The builder works for a 20-part rocket. It fails at four things the user now wants:
clean frames, aircraft, big crafts, and a sense of place.

1. **It stops working at scale.** With a part in hand the builder script costs 7 ms
   at 25 parts, 87 ms at 100 and 244–600 ms at 250. At 500 parts the engine's 2 s
   watchdog kills the builder script for good. Idle, 1,000 parts cost 58 ms a frame
   in *physics*, because every part on the stand is a kinematic body. A 2,000-part
   load trips the watchdog half way. The cause is algorithmic (O(n²) node and overlap
   scans, per-spawn stat refreshes), not the engine, so it can be fixed in Lua.
2. **Frames look like Lego because the attach model can't make a corner.** A part has
   one parent, and nodes exist only at the ends and the middle of each flank. A
   52 px node magnet beats surface attach, and occupied nodes are worked out from
   world Y, which is wrong for any part lying down. A flush L or T joint is
   impossible without a Strut Hub. The probe shows all four (section 2.3).
3. **Planes can't be built in the shipped builder.** It has no wings, control
   surfaces, jets, intakes or gear, no centre of lift, and no analog axis input. The
   aero agent's new parts and maths (section 7.1) fill the part gap. The builder still
   needs the placement, overlays and testing.
4. **Controls take a hunt.** Binding a key means tool 5, then a group chip, then a
   part, then an action tick, and nothing tells you tool 5 exists except the hint
   line. Hinges need two separate groups, and there is no axis binding.
5. **The hangar is a grey box.** It is 48 × 48 m with a 13 m ceiling, a static
   skybox, and a full world reload on every exit and every launch.

**The overhaul:**

- **One selection-centred mode.** Click to select, drag to move, right-click for a
  part menu, and gizmos (2 OFFSET, 3 ROTATE) on the selection. The camera orbits by
  default, which frees W/A/S/D/Q/E for rotation.
- **A connection graph instead of a parent tree.**
  - Surface attach anywhere, snapped to a grid on the host.
  - Automatic beam joints (end-to-end, T, L and crossings) with auto-welds and
    gussets.
  - Procedural beams and trusses (drag a length) and two-point braces.
  - Hubs stay as an optional part.
- **A Controls model with axes.**
  - Fast bind: select a part, press B, press a key.
  - A per-part menu.
  - A keymap tab.
  - Axis bindings (pitch, yaw, roll, throttle, steer and custom key pairs) with gain
    and trim.
  - Presets, and a Controls card in flight.
- **Aircraft**, on the aero agent's new `aero.lua` and `parts_aero.lua`.
  - Wings, control surfaces, jets, intakes and gear go in a placement flow that works
    first time: centre-plane mirror, nose-aligned surface attach, and wing-panel edge
    snapping.
  - CoM, CoT and CoL overlays from the flight's own maths, with static-margin and
    stall readouts.
  - A deflection preview in TEST, a gear tip-back check, and the runway as a
    first-class launch site.
  - Procedural wings come in phase 2.
- **Big crafts.**
  - Spatial hashing and graph adjacency, with no O(n²) scans.
  - Visual-only parts on the stand.
  - Multi-select, sub-assemblies, a craft library, copy and paste, mirror, named
    groups, and unlimited undo and redo.
  - An orbit, pan and zoom-to-cursor camera with a height slider.
  - Target: **1,000 parts at ≤ 4 ms of builder script with a part in hand.**
- **In the real world (recommendation (c)).** The builder becomes an **additive
  overlay scene** loaded over the live system scene at the real VAB. Parts are
  parented to a BuildFrame on the VAB's mobile launcher, so the sky, time, weather,
  wind and the open doors are the real ones. Leaving is instant, and launch rolls the
  craft out with no world reload. `scenes/builder.ron` survives as the overlay and as
  a fallback host.

Six work packages (section 11) own disjoint files and can run in parallel.

---

## 1. Ground rules for this design

- **Realistic and grounded.** No magic glue: every connection is a visible joint,
  and every structural shortcut (hubs, braces, gussets) is a real part with mass and
  strength.
- **Direct manipulation first, keys second, panels third.** Every key has a visible
  button or menu entry. Hidden keys are accelerators, never the only way.
- **One accent per screen** (`docs/ui-style.md`). Orange marks the selection, the
  captured snap and the primary action. Live numbers sit on CRT strips in phosphor
  mono. No navy or teal fills. The current symmetry chips (`drawModes`, fill 0.05
  0.07 0.09) break this and are replaced.
- **The craft is data.** Panels and overlays read a public builder API and never
  each other's state (section 11.1).

---

## 2. Audit of the current builder

### 2.1 What exists

| Area | Where | Notes |
|---|---|---|
| Part registry | `builder.lua` `REG`, `DESC`, `CATALOGUE` (lines 85–339) | 49 parts; flags drive behaviour (`side`, `radial_orient`, `axial_out`, `top`/`bottom`) |
| Attach | `attach_nodes_of`, `find_snap`, `surfaceUnderCursor`, `snapPlace`, `attachBasis` | axial top and bottom nodes, 4 mid-flank nodes, and surface attach as a fallback when no node is within `snap_px` = 52 px |
| Structure | `parts[uid].parent`, `att` ∈ top, bottom, radial, surface | a single-parent tree; `subtree()` is an O(n·depth) scan |
| Symmetry | `symCopies`, `placeCopies`, `sym`/`mir` group ids | ×2…×8 rings about the host axis, a mirror pair, and "follow" when placing on a ring member |
| Rotation | `rotKeysQ` (WASD/QE, R spin, SPACE reset, C camera/part frame), ring gizmo | matrix-based since 2026-10-23 |
| Move | arrow-key nudges of 0.1 m, an arrow gizmo on world axes | no numeric entry, no grid |
| Tools | 1 move, 2 rotate, 3 stage, 4 grab, 5 action groups | listed only in the hint line |
| Staging | decoupler events, a drag-to-reorder panel, numbered badges | a separate tool |
| Action groups | `groups_panel.lua` and `electronics.lua` groups | tool 5; group, then part, then tick; custom groups on 1–0; a one-click "auto actuators" |
| Wheels | `wheelCfg`, `wheelPlan`, `wheelArrows`, a settings panel | shown only when a wheel is selected outside tools 3 and 5 |
| Fairings | shaping mode (B), a fitted shell | modal |
| Save | `shipyard.blueprint`, **one slot** | no library, no sub-assemblies; ESC saves and leaves |
| Camera | `builder_camera.lua` free-fly on WASD, F to focus-orbit | orbit distance = 2.5 + 1.1 × part count (1,100 m at 1,000 parts); centre = unweighted mean of part centres |
| Scene | `scenes/builder.ron` | 48 × 48 m floor, 14 m walls, ceiling at 13.5 m, grey skybox, props |

### 2.2 Performance (probe, measured)

Probe: `SCRATCH/builder_ux/uxprobe.lua`, modes `perf`, `perf2` and `perf3`, run on
rc6 with a muted ALSA device. The craft is a lattice of 1 m box beams stacked in
parent chains of 10. Times are the builder script's own hook time
(`perf.scriptMs("builder")`). The window was capped at 20 fps (50 ms) unfocused, so
frame times only show what goes over that.

| Parts | Idle builder | Selected | **Part in hand** | Physics bucket (idle) | Load (F5) |
|---:|---:|---:|---:|---:|---:|
| 25 | 0.07 ms | 0.18 ms | **7.0 ms** | – | 0.26 s |
| 50 | 0.19 | 0.23 | **46.8 ms** | – | 0.25 s |
| 75 | 0.25 | 0.21 | **69.2 ms** | – | 0.30 s |
| 100 | 0.55 | 0.30 | **87.3 ms** (frame 108 ms) | – | 0.25 s |
| 150 | 0.52 | 0.52 | **218 ms**, worst 447 ms | – | 0.30 s |
| 250 | 0.37 | 0.35 | **244 ms**, worst 598 ms (frame 640 ms) | – | 0.27 s |
| 300 | 0.36 | – | – | 18.3 ms | 1.14 s |
| 500 | 1.10 | 0.55 | **watchdog: builder stopped for good** | – | 1.27 s |
| 1,000 | 0.85–2.3 | 1.8 | (not reachable) | **57.9 ms** (frame 76–146 ms) | 5.05–5.2 s |
| 2,000 | – | – | – | – | **watchdog during load** (713 of 2,000 landed) |

At 1,000 parts there are also 3,096 draws and 1,100 instances (`perf.counts`).
`catalog_panel` costs a constant 1.4–1.8 ms a frame, because it re-describes itself.

Causes, read from the code:

- **The part in hand.** Every frame, `find_snap` and the telegraph loop each call
  `attach_nodes_of` for every part. That calls `is_side_occupied` for each of four
  flank nodes, which scans every part. That is about 8·n² `part_extents` calls (with
  trig) per frame, plus two O(n) occupancy passes.
- **Physics.** Every `Part*.prefab.ron` carries a `Kinematic` rigidbody. The builder
  uses the bodies only as a fallback raycast target, since `rayPart` already does
  exact picking.
- **Load.** Each spawn callback runs `publish_center()` and `refresh_stats()`, which
  covers stages, launch checks and power: O(n) each, so O(n²) per load, all inside
  frames.
- **Selection.** `edit_set` and `subtree` rescan `parts` until nothing changes.
- **The watchdog** (floptle-script `budget.rs:166`) stops the script until it is
  edited. In play that means the builder is dead with no recovery (section 12, card 3).

### 2.3 Attachment behaviour (probe `beams`, shots in `SCRATCH/builder_ux/shots/beams/`)

- **`1_occupied_node_offered`.** Two 2 m beams lie end to end (one stacked on the
  other's bottom node). Picking up a third beam shows a **red "buried" ring on the
  occupied joint**. Occupancy is `p.y >= parent.y` in world Y, so for parts lying
  down it marks the wrong end. Every part also shows all of its free nodes at once
  (six overlapping rings on two beams).
- **`3/4_corner`.** A horizontal beam aimed at a post's side 0.2 m below its top
  lands at the aimed height (y 2.00). The post sticks out 0.22 m above it, so it
  makes a **T, not a flush L**. No node exists at the post's top corner facing
  sideways. The only clean corner is a Strut Hub on top (shot `6`). This is the
  "everything needs a hub" the user describes.
- **`5_side_upper_ghost`.** A beam aimed half way between a post's mid-flank node and
  its top **snaps to the mid-flank node**. The 52 px magnet beats surface attach on
  any part shorter than about 4 node radii on screen, so "I can't just place beams on
  each other" where you aim.
- **One parent.** A beam spanning two posts belongs to one of them. Picking up the
  first post carries the bridge, the stress model loads only one end, and closing a
  loop is never recorded.

### 2.4 Task timings

These are keystroke-level estimates for an expert who knows every key, built from the
code paths. The operators are point P 1.1 s, click 0.2 s, key 0.28 s, think M 1.35 s,
catalogue scroll 0.75 s on average, and a camera reposition 2.5 s. The probe confirmed
the blockers that are named. Real first-time times are far longer, because every key
below is hidden.

| Task | Today (expert) | Blockers | Target |
|---|---:|---|---:|
| T1 two-stage rocket: pod, chute, 2 tanks, 2 engines, decoupler, ×4 fins, ×3 legs | ~59 s | X cycles through six states and must be cycled back to OFF; no part search | ~40 s |
| T2 rover with a 2-hinge arm, claw and seat, bound | ~80 s with auto-actuators, ~115 s by hand, plus a launch round trip (a world reload) to see whether the arm moves the right way | wheels can't be placed symmetrically front and back (no grid; nudges are 0.1 m); hinge axes are set blind; no test mode | ~45 s, tested in the builder |
| T3 plane-like shape that flies | **cannot be done** | no wings, control surfaces, jets, intakes, gear or CoL. A panel surface-attached to a hull stands out as a wall and needs W/S per placement | ~90 s for a small jet |
| T4 bind a pair of floodlights to a custom key and name it | ~11 s, if you know tool 5 | 5 key, group chip, part, action tick, rename field, 1 key | ~4 s (select, B, key, Enter) |
| T5a insert a tank into the middle of a 6-part stack | ~18 s | grab carries everything above; you must put the stack aside, place the tank, then re-place the stack | ~4 s (drop on the joint inserts) |
| T5b move a booster pair up 1.0 m | ~6 s (10 presses of the up arrow) | no numeric entry, no grid readout | ~3 s (drag with a 0.25 m grid, or type 1.0) |
| T5c any edit on a 500-part craft | impossible (the watchdog kills the builder) | O(n²) placement | under 4 ms a frame |

### 2.5 Friction points and severity

S1 means it blocks a goal or breaks. S2 means it is slow, confusing or frequent. S3
is polish.

| # | Friction | Sev |
|---|---|---|
| F1 | Placement cost is O(n²); 500+ parts kills the script | S1 |
| F2 | Builder parts are physics bodies (58 ms idle at 1,000); O(n²) load | S1 |
| F3 | No flush L or T beam joints; hubs are mandatory for clean frames | S1 |
| F4 | Node magnet (52 px) beats surface attach; can't place between nodes | S1 |
| F5 | Occupied nodes worked out from world Y, so parts lying down offer occupied joints and show red | S2 |
| F6 | No aircraft parts, aero data, CoL or axis input | S1 |
| F7 | One blueprint slot: no craft library, sub-assemblies, copy and paste, or redo; undo capped at 40 | S1 |
| F8 | Hangar ceiling at 13.5 m; nothing tall fits; not the real world; world reload on every exit and launch | S1 |
| F9 | W/A/S/D/Q/E means both camera flight and rotation, decided by `rotKeysBusy`; while you hold a part the camera only moves with RMB held | S2 |
| F10 | Tools 1–5 exist only in the hint text; tool switches are a hidden mode | S2 |
| F11 | Moving a part needs tool 4 (grab), and grab carries everything stacked above it; no move-just-this; no insert into a stack | S2 |
| F12 | Action groups: a separate tool and a 3-step panel; hinges need two groups; no axis binding; no key choice beyond 1–0 | S2 |
| F13 | Camera: free-fly by default; F orbits about an unweighted mean; orbit distance grows with part count; no pan, zoom-to-cursor, frame-selection or height control; floor clamp at 0.4 m | S2 |
| F14 | No multi-select, box select or select-connected; the selection is one part plus its subtree | S2 |
| F15 | Rotation: the camera frame snaps to world axes, C toggles the frame, R, T and Y are legacy aliases, and SPACE resets; the keys overlap with the camera and the semantics shift with C | S2 |
| F16 | No snapping grid, no numeric offset or rotation, no offset limit feedback | S2 |
| F17 | All attach nodes on all parts are drawn while a part is in hand (ring clutter) | S2 |
| F18 | ESC with no part in hand (even with a selection) saves and **leaves the scene** | S2 |
| F19 | Catalogue is one long scroll of 49 cards; no search, no thumbnails; locked cards need two clicks | S2 |
| F20 | Symmetry: X cycles six states; you must remember to turn it off; the chips are off-palette | S3 |
| F21 | Feedback is a single hint line of long text; errors such as "buried inside another part" appear only there | S2 |
| F22 | Launch site is the hidden key L | S3 |
| F23 | Stats header is a wall of text (TWR, Δv, power, comms, staging) | S3 |
| F24 | Staging lists only decouplers, inside a tool; engines and chutes are implicit | S3 |
| F25 | Wheel settings appear only on a selected wheel outside tools 3 and 5 | S3 |
| F26 | Fairing shaping is a modal B mode with its own keys | S3 |
| F27 | CoM and CoT always draw; there is no CoL and no toggle | S3 |
| F28 | No way to test actuators or controls without a launch and a world reload | S2 |

---

## 3. Prioritised problems

- **P0, do first: these block the user's goals.**
  1. Scale: F1 and F2. Without this nothing else matters for "massive projects".
  2. The attach model: F3, F4, F5 and F17. This is the "Lego" complaint.
  3. A craft library and history: F7.
  4. Aircraft: F6.
  5. The world: F8.
- **P1: fighting the tool.** F9, F10, F11, F12, F13, F14, F15, F16, F18, F21 and F28.
- **P2: polish.** F19, F20, F22, F23, F24, F25, F26 and F27.

---

## 4. The new interaction model

### 4.1 One mode, a selection, and verbs

There is one mode: **Build**. Three states sit inside it and are always visible on
the toolbar:

- **Idle.** Nothing in hand. Click to select, drag to move.
- **Holding.** A part, a group or a sub-assembly follows the cursor and snaps. Click
  places it. **Shift+click places and keeps a copy in hand** for repeated placement.
  Esc drops it.
- **Gizmo.** 2 OFFSET or 3 ROTATE on the selection, the KSP numbering players already
  know. 1 returns to plain select and drag. 4 ROOT re-roots the craft.

Staging, Controls and the craft outliner become **right-panel tabs**, not tools.
Fairing, wing and beam shaping are **handles on the selected part**, not modes.
Two toggles change what the keys do, and both show a lit keycap:

- **TEST** (key T): the craft's controls drive its actuators and control surfaces in
  the builder, kinematically, with no physics.
- **PHOTO** (F4 hides the UI, F5 frees the camera): the same keys as `planet_camera`.

### 4.2 Mouse

| Input | Does |
|---|---|
| LMB click on a part | select it (replaces the selection) |
| Shift+LMB / Ctrl+LMB | add to / toggle in the selection |
| LMB drag on empty space | box select (Shift adds) |
| Double-click a part | select its connected assembly up to the first decoupler; double-click again for the whole craft |
| LMB drag on a part (6 px threshold) | **move**: lift the selection plus its *dependents* (the parts that would lose the root without it, section 5.4) and re-attach where it snaps |
| Alt+LMB drag | move **only** the selection; its dependents stay and show as loose (orange outline) until re-attached or welded |
| Drop on an occupied stack joint | **insert**: the part goes between, and the stack above shifts by its height |
| RMB drag | orbit about the pivot (the point under the cursor when the drag starts, or the selection centre) |
| RMB click (no drag) | part context menu (section 4.5) |
| MMB drag / Shift+RMB drag | pan |
| Wheel | zoom toward the cursor; Ctrl+wheel steps the camera height |
| Wheel while holding a part | nothing: never change state on scroll while holding |

### 4.3 Keys

Every key below has a button or menu entry. The `?` key shows this table as an
overlay.

| Key | Action |
|---|---|
| W/S A/D Q/E | rotate the held part or the selection 90° about the gizmo space (pitch, yaw, roll); Shift = 15°. Never moves the camera (RMB+WASD flies, Unreal style) |
| Space | reset the rotation to how the mount stands it |
| R | spin about the mount normal 15° (Shift 5°) |
| 1 2 3 4 | select / OFFSET gizmo / ROTATE gizmo / ROOT |
| L | gizmo space LOCAL ↔ WORLD (was C; the launch site moves to the LAUNCH button) |
| X / Shift+X | symmetry ×1 ×2 ×3 ×4 ×6 ×8 / back |
| M | mirror symmetry (a plane through the host; Alt+M picks the craft centre plane) |
| G | grid snap 1 cm / 5 cm / 25 cm / 1 m / off (shown on the toolbar) |
| Shift+G | angle snap 1° / 5° / 15° / off |
| B | bind: press the key the selected parts' main action should use (section 6.3) |
| T | TEST controls in the builder |
| V | cycle overlays: none / CoM+CoT / +CoL / +aero vectors |
| F / Home | frame the selection / frame the craft |
| PgUp / PgDn | camera height step (also the vertical slider) |
| Numpad 1 3 7, 5 | front / side / top view, perspective ↔ orthographic |
| H / Alt+H | hide the selection / unhide all; Shift+H isolates |
| Ctrl+Z / Ctrl+Y (Ctrl+Shift+Z) | undo / redo |
| Ctrl+C / Ctrl+V / Ctrl+D | copy / paste (into the hand) / duplicate in place |
| Del | delete the selection (the dependents go too; Alt+Del deletes only the selection) |
| Ctrl+S / Ctrl+O / Ctrl+N | save / open the library / new craft |
| Ctrl+F or / | focus the part search |
| Tab | cycle the right-panel tabs |
| Esc | back out one level: drop the held part, close the menu, clear the selection. **Never leaves the VAB**: LEAVE is a button, and Ctrl+Q asks first |

### 4.4 Screen layout

The design is drawn at 1280 × 720 design units (the UI scales). Panels are screwed
enamel plates (`panel/frame`). Live numbers sit on CRT strips (`hud/instrument`).
Keys are keycaps (`panel/choice` latched in = active).

```
┌─[▣ VAB]──────────────────────────────────────────────────────────────────────────────────────┐
│ CRAFT ┃Kestrel Mk2      ▾┃ [NEW][OPEN][SAVE][SUB-ASSY]   [1 SEL][2 OFFSET][3 ROTATE][4 ROOT]  │
│ SYM [OFF][×2][×3][×4][×6][×8][MIR]  SNAP [GRID 25cm][15°]  SPACE [LOCAL]  [TEST][V CoM·CoT·CoL]│
│                                                         ◂ LEAVE      [ LAUNCH ▸ ┃RUNWAY▾┃ ]     │
├──────────────┬─────────────────────────────────────────────────────────────┬──┬──────────────┤
│ PARTS        │                                                             │▲ │[INSPECT]STAGE│
│┌────────────┐│                                                             │  │ CONTROLS CRAFT│
││/ search… ⌕ ││                 (the VAB, the craft, the open door,         │██│──────────────│
│└────────────┘│                  the sky beyond it)                         │██│ SERVO HINGE  │
│ CMD PROP AERO│                                                             │  │ ×2 (mirror)  │
│ STR FRM ELEC │            ┌─────────┐                                      │  │ mass  60 kg  │
│ ROV ROBO PAY │            │ selected │◀ orange outline, gizmo               │  │ cost  $240   │
│──────────────│            └─────────┘                                      │  │──────────────│
│ ▣ ▣ ▣ ▣      │                                                             │  │ OFFSET  mm   │
│ thumbnails   │                                                             │  │ x[  0 ] y[120│
│ 4 per row,   │                                                             │  │ ROTATE  °    │
│ name + price │                                                             │  │ p[ 0 ]y[90]r │
│ under each   │                                                             │  │──────────────│
│              │                                                             │HT│ CONTROLS     │
│ RECENT ▣▣▣▣  │                                                             │  │ Angle  [6][7]│
│ SUB-ASSY ▣▣  │                                                             │▼ │ axis: —   [+]│
├──────────────┴─────────────────────────────────────────────────────────────┴──┴──────────────┤
│▐ PARTS 312 ▐ MASS 18.40 t ▐ ΔV 1 240 m/s ▐ TWR 1.42 ▐ MARGIN +6 % MAC ▐ COST $12 400 ▐ 3.1 ms▐│
│ hint: drag to move · Alt+drag moves only this · RMB for its menu                     [?] KEYS │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
```

- **The top plate is the toolbar**: craft name, file keys, tools, symmetry, snap,
  space, TEST, overlays, and LEAVE and LAUNCH at the right. The LAUNCH key has the
  site latched in its split (PAD / RUNWAY). It is the screen's one orange key.
- **The left plate holds the parts.**
  - A search field is focused by / or Ctrl+F. Typing filters; Enter picks the first
    match into the hand.
  - Category keycaps sit above a grid of **thumbnails**, rendered once per part with
    `camera.captureTexture` and cached.
  - RECENT shows the last 8 parts picked. SUB-ASSY shows saved sub-assemblies.
- **The right plate has tabs.**
  - INSPECT: the selection's name, count, mass and cost; numeric offset and rotation;
    the part's own settings (wheel, actuator limits, wing shape, fuel load); its
    controls.
  - STAGE: the staging stack.
  - CONTROLS: the keymap (section 6).
  - CRAFT: the outliner (named groups, sub-assemblies, symmetry sets), the history
    list, and the part and performance budget.
- **HT** is the camera height slider on the viewport's right edge. Its range is the
  craft's bounding box from floor to top, and it moves the orbit pivot up and down
  the craft.
- **The bottom CRT strip** carries the live figures in phosphor mono. The last figure
  is the builder's frame cost, which turns caution yellow above 4 ms. The hint line
  sits under it in `hud/hint`.

### 4.5 Part context menu (RMB click)

```
┌ SERVO HINGE ×2 ──────────────┐
│ Inspect                    ⏎ │
│ Controls ▸  Angle +   [ 6 ]  │
│             Angle −   [ 7 ]  │
│             Lock      [ — ]  │
│             Axis…     [ — ]  │
│ Select ▸ connected · ring ·  │
│          same part · group   │
│ Copy  Ctrl+C   Duplicate ^D  │
│ Make sub-assembly…           │
│ Set as root                  │
│ Detach (keep dependents)     │
│ Delete                  Del  │
└──────────────────────────────┘
```

It uses `hud/tooltip` light-enamel rows. A keycap opens the bind prompt for that
action (section 6.3).

### 4.6 Feedback rules

- A **snap is shown, not described**. The captured attach point gets an orange ring
  and a tie line, and the ghost shows the exact final pose (symmetry copies as amber
  outlines). A refusal shows a red outline on the *blocking* part plus a one-line
  placard (`hud/caption`) at the cursor, not in the hint bar.
- **Nodes draw only on the part under the cursor and its direct neighbours**, and
  only the nodes the held part fits (stack size, free). Occupied nodes never draw.
- Every placement, move and delete plays its click (UI bus) and puts one line in the
  history list.

---

## 5. The attachment model

### 5.1 From a tree to a graph

A craft is **parts plus connections**:

- `parts[uid]`: id, pose in the BuildFrame (x, y, z and yaw, pitch, roll), and size
  parameters for procedural parts.
- `links[]`: each is `{ a, b, kind, pa = point on a, pb = point on b, n = normal, strength }`.
  The kind is one of:
  - `stack`: node to node, axial;
  - `surface`: a face or the hull at a point;
  - `splice`: beam end to beam end;
  - `tee`: beam end to beam side;
  - `corner`: beam end to beam end at an angle;
  - `cross`: a beam crossing a beam;
  - `brace`: a two-point strut;
  - `weld`: an automatic contact weld;
  - `decouple`: through a decoupler's separation plane;
  - `hinge`, `piston` or `rotor`: through a robotic part's moving face.
- `root`: a uid, the command part by default (tool 4 changes it).

A **parent** still exists for every part. It is the primary link through which the
part was placed, and it keeps the old blueprint fields (`parent`, `att`) for back
compatibility. Every rule that used to walk the tree now asks the graph:

| Question | Tree answer (today) | Graph answer (new) |
|---|---|---|
| What comes along when I move X? | `subtree(X)` | **dependents(X)**: the parts cut off from the root if X is removed (one BFS from the root that skips X) |
| What separates at a decoupler? | everything below | remove the `decouple` links, then take connected components; the root's component stays |
| What moves with a hinge? | the stack on its top node | the component on the moving side once the hinge link is removed. If that component reaches the fixed side through another link, the hinge is **locked by a loop**: red outline, refused in TEST, a launch warning |
| Joint load (flight) | each part's link to its parent | the spanning tree of the strongest links from the root, with the strength of every **non-tree link added to the tree links on its cycle** (parallel load paths) |
| What breaks off? | the subtree past a failed joint | remove the failed link; split only if the graph disconnects |

**Mapping onto physics.** A flying craft is still one compound assembly per connected
component: `assembly.rebuild` gathers the parts' box colliders, as now. The engine
never sees links. Links matter only to the Solar rules above: staging, robotics, the
stress model and breakage. No engine change is required. Procedural parts set their
collider at runtime through the RigidBody component's `half_x`, `half_y` and
`half_z` (documented in `lua-api.md`).

### 5.2 Where a part can attach

Priority under the cursor, decided each frame from the part the cursor ray hits
first:

1. **A compatible stack node within 10 % of the host's size** (at least 12 px, at most
   40 px on screen). Stack nodes still win for rocket parts (tank on tank), but they
   no longer win from across the part. On a frame member (beam, strut, panel) the
   node radius is 6 % and never more than 24 px.
2. **Beam joint regions** when the held part and the host are both frame members
   (section 5.3).
3. **Surface attach** at the hit point on the host's real shape (`rayPart`: round
   hulls are round, boxes are boxes), snapped to the **host grid**: positions along
   the host's own axes at the grid step (default 5 cm on frame parts, 25 cm on hulls),
   and angles about a round hull at 15° (Shift: free).
4. **Free placement** on the build floor (the mobile launcher deck), snapped to the
   floor grid. It is allowed for any part, not only the first. A free part is a new
   island, outlined orange and listed in CRAFT as *unattached*. LAUNCH warns that
   only the root's island launches.

Orientation on surface attach is unchanged from today (`attachBasis`):

- fins and blades stand with +X out of the face;
- frame members point out of the face (`axial_out`);
- anything else stands on the face.

Then `ghost.off` applies the player's own turn.

### 5.3 Beam joints (no hubs needed)

A frame member (strut, box beam, I-beam, truss, procedural beam) has three regions
along its length: **end A**, **span** and **end B**. Each end region is the last 12 %
of the length, or 0.15 m, whichever is larger. With a frame member in hand, aiming at
another member offers these joints:

| Aim at | Held member's end goes | Joint | Visual |
|---|---|---|---|
| host end cap | onto the cap, colinear | `splice` | splice plates on two faces |
| host end region, side face | flush **corner**: the held member's outer face aligns with the host's end face, perpendicular, out of that side; Shift+wheel or A/D steps the angle 15° up to colinear | `corner` | a triangular gusset plate in the joint's inner angle |
| host span, side face | **T**: end flush on the side at the snapped point along the host (grid), perpendicular | `tee` | gusset pair (toggle off in INSPECT) |
| host span, held member crossing it | through, both continue | `cross` | a bolted clamp block |

- **Auto-weld.** After any placement, every end of the placed part that ends within
  2 cm of another part's surface or node (the spatial hash finds candidates; the
  exact test uses `rayPart` and the end-cap rectangle) gets a `weld`. Closing a
  rectangle with its fourth beam welds both ends. The tie lines flash once.
- **Gussets and splice plates** are small generated meshes (`mesh.build`). One mesh
  per joint style and size is cached, and each joint is a child node of the joint's
  first part. They carry mass (about 1 kg) and add 25 % strength to the link. They are
  never separate parts in the part list.
- **Strut Hub** stays in FRAME as a part, a "node block" for when you want a visible
  hub (and for six members at a point).
- **Brace** (a new part, Besiege and KSP style). Pick Brace, click point A on any
  part, then point B on another. A thin tube is drawn between them, and a `brace`
  link adds stiffness to big frames, booster rings and wing roots. It snaps to nodes
  and to the grid on both ends, and it is mirrored and ringed by symmetry.

### 5.4 Moving, inserting and detaching

- **Drag moves the selection plus its dependents.** The dependents are measured from
  the root, so dragging a booster takes its engine and fins, and dragging a beam in
  the middle of a closed frame takes only that beam, because the rest is still
  connected through other links.
- **Alt+drag** moves only the selection. Its links to its dependents are cut, and the
  dependents become loose islands (orange) until placed or welded.
- **Insert.** Dropping a stack part on an occupied stack joint inserts it, and
  everything on the far side moves out along the stack axis by the part's height.
  This is one undo step.
- **Detach** (menu) cuts the selection's links but keeps its pose. Use it to rebuild
  a joint.

### 5.5 Procedural members and panels

- **Beam tool.** Use FRAME ▸ *Beam* (or press N with nothing in hand).
  1. Click a start point on a node, a surface (grid-snapped) or the floor grid.
  2. Move the cursor. A live member stretches from the start, its length snapped to
     the grid with a phosphor length tag on the cursor.
  3. Click the end. Each end makes its joint as in 5.3.
  4. Shift+click chains the next member from that end; Esc ends the chain.
- **Profiles:** tube strut (Ø 0.14), box (0.24 × 0.14), I-beam (0.24 × 0.26) and
  lattice truss (0.4 triangular). Length runs 0.25–12 m in 0.05 m steps. Mass, cost
  and joint strength scale linearly with length from the catalogue figures.
  Selecting a member shows **end handles** to drag its length.
- **Panel tool.** Drag a rectangle on a face or on the floor grid to get a procedural
  panel (thickness 4 cm or deck 10 cm). It has edge handles.
- **Rendering.** `mesh.build` builds the meshes, cached by (profile, length)
  quantised to 5 cm, so a 1,000-member frame has a few dozen distinct meshes. The
  collider is the part's box with runtime half-extents.
- The fixed-length catalogue beams stay (they are procedural members with presets),
  so old crafts load unchanged.

### 5.6 Offset and rotate gizmos after placing

- **2 OFFSET** draws three arrows in the **mount frame**: two along the host surface
  and one along the normal (or world axes in WORLD space). Dragging slides the part.
  It snaps to the grid, and Shift gives 1 cm. A length tag on the cursor shows the
  offset. INSPECT shows offset x, y, z in millimetres as fields you can type in.
  - The link keeps its attach point. The joint follows the part.
  - Offset is free while the part still touches its host (its box overlaps the host's
    within 2 cm).
  - Past that the tie line turns **red**, the placard reads "not touching what it is
    attached to", and LAUNCH refuses until it is fixed. That is the realism, and it
    is also KSP's offset limit without the mystery.
- **3 ROTATE** draws rings in the gizmo space. It snaps to the angle snap, and Shift
  turns freely. INSPECT has pitch, yaw and roll fields. Symmetry members follow, as
  `rotateSelection` already does.
- **Align to** (menu ▸ Align ▸ to part…): click a reference part and the selection
  takes its orientation. **Distribute** (menu, 3+ selected): equal spacing along the
  line through the first and the last.

### 5.7 Symmetry

Behaviour stays as fixed on 2026-10-23: copies are made only when symmetry is on
**now**. Four changes:

- **Placing with symmetry on also arms the held copies for repeated placement**
  (Shift+click). X state shows as latched keycaps on the toolbar, not off-palette
  chips.
- **A mirror plane can be the craft's centre plane** (Alt+M) as well as the host's.
  Planes need this: wings mirror across the fuselage centre, not across a small
  bracket.
- **Mirrored aero parts are chiral.** A left wing is a reflected wing, and its control
  surface roll mapping inverts.
- **The "follow" rule is kept.** Placing on a ring member places on every member, but
  only while symmetry is on.

### 5.8 Blueprint v2

```lua
bp = {
  v = 2, name = "Kestrel Mk2", root = 1,
  parts = { { uid, id, x, y, z, yaw, pitch, roll,      -- BuildFrame-local, as today
              size = { len = 3.25, prof = "box" },      -- procedural parameters, optional
              parent, att, sym, mir, an*, stage, wcfg, mods, … } },  -- v1 fields kept
  links = { { a = 3, b = 7, k = "tee", pa = {…}, pb = {…}, s = 380 }, … },
  controls = { groups = …, axes = …, custom = … },      -- section 6
  groups = { { name = "Left wing", uids = {…} } },      -- outliner groups
}
```

A v1 blueprint loads by turning every `parent` into a link of kind `stack` or
`surface` (taken from `att`). The flight side reads `links` if present and otherwise
rebuilds them from `parent`, so old fleet records keep flying.

---

## 6. Action groups and input binding

### 6.1 Model: actions, groups and axes

- **Actions** stay as `electronics.lua` derives them from modules (toggles, triggers
  and axis setpoints).
- **Groups** stay: Gear G, Deploy U, Lights Y, Brakes B, RCS R, SAS T, Abort ⌫, and
  custom groups. Custom groups may sit on **any free key**, not only 1–0.
  `controls.validKey` refuses keys reserved in flight:
  - W, A, S, D, Q and E;
  - Shift, Ctrl, X and Z (throttle);
  - Space (stage);
  - I, J, K, L, H and N (translation);
  - M (map);
  - F (board);
  - V and C (cockpit view and camera mode);
  - period and comma (warp);
  - Esc.

  Up to 20 groups are allowed.
- **Axes** are new: continuous inputs that drive axis setpoints every tick.
  - Built in: PITCH (W/S), YAW (A/D), ROLL (Q/E), THROTTLE, STEER (A/D on wheels),
    DRIVE (W/S on wheels), and TRANSLATE X, Y and Z.
  - Custom: up to 6 axes, each a key pair (for example ↑/↓, [/], or Num8/Num2) or
    the mouse wheel.
  - An **axis binding** ties one part action to one axis:
    `{ uid, act = "angle", src = "pitch"|"c1"…, gain = −1..1, trim, mode = "position"|"rate", dead = 0..0.2, smooth = s }`.
    - Position mode gives setpoint = trim + gain × input × half-range: a servo that
      follows the stick and springs back.
    - Rate mode moves the setpoint at gain × input × rate and holds it where it
      stops: a crane arm.
  - **Control surfaces** have a default binding of *auto*. They respond to pitch, yaw
    and roll in proportion to their lever arm about the CoM along each axis, as KSP
    does. An INSPECT checkbox per axis and an authority slider override it.

### 6.2 What changes for the player

- Hinges no longer need two groups. One custom axis (↑/↓) drives the hinge in rate
  mode, or a group key toggles it between presets.
- A rover arm is "select hinge 1, B, ↑ ↓; select hinge 2, B, ← →; select claw, B,
  P". That is three binds of about 3 s each.

### 6.3 Flows

**A. Fast bind (B).** Select one or more parts (a symmetry set counts as one), then
press B. The viewport dims (`panel/scrim`) and a riveted placard appears at the
cursor:

```
╔═ BIND ═ Servo Hinge ×2 ══════════════════════════╗
║  press a key for  ANGLE   (rate axis)            ║
║  first key = + , second key = −   ·  ⏎ one key   ║
║  [Angle ▾]  [rate ▸ position]        Esc cancel  ║
╚══════════════════════════════════════════════════╝
```

- The part's **primary action** is preselected:
  - hinge, piston or rotor: its axis;
  - light: Light on/off;
  - legs: Extend/retract;
  - engine: Activate/shut down;
  - decoupler: Decouple;
  - wheel: Brakes;
  - claw: Arm/disarm;
  - drill: Lower and run.

  The ▾ picks another action.
- A key on a reserved flight key is refused in the placard with its reason.
- A key already used by another group shows "joins *Lights* (Y) ▸ ⏎ / pick another".
- For axes, the first key is +; the second key, or Enter, makes it a one-key toggle
  between presets.
- One undo step.

**B. Context menu ▸ Controls.** Every action of the part is listed with its keycap.
Clicking a keycap is flow A for that action. "Axis…" opens the axis row editor
inline (source, gain slider, trim, mode).

**C. CONTROLS tab (the keymap).** One row per key in use, Besiege style:

```
┌ CONTROLS ── TEST [T] ─────────────────────────────┐
│ KEY  NAME          PARTS                     MODE │
│ [G]  Gear          Landing Legs ×4           ⇅    │
│ [Y]  Lights        Floodlight ×2             ⇅    │
│ [6]  Arm lift      Servo Hinge ×2  +         rate │
│ [7]  Arm lift      Servo Hinge ×2  −         rate │
│ [P]  Claw          Landing Claw              ⇅    │
│ ── AXES ───────────────────────────────────────── │
│ PITCH W/S   Elevator ×2 (auto)  Hinge 3 ×0.5 pos  │
│ C1   ↑/↓    Crane boom  rate 30°/s               │
│ [+ custom axis]   [presets ▾]   [clear all]       │
└───────────────────────────────────────────────────┘
```

- Hovering a row outlines its parts (orange). Dragging a part chip to another key
  rebinds it. Double-clicking a name renames it (that label shows in flight).
- Conflicts (two different things on one key) show a caution-yellow key.
- TEST (T) drives the craft from these keys in the builder: actuators move
  kinematically and surfaces deflect, with no physics. This removes the launch round
  trip from F28.

**D. Presets.**

- **Craft presets** (the CONTROLS ▸ presets menu):
  - *Rover*: drive and steer axes on, brakes B, lights Y.
  - *Plane*: surfaces on auto, gear G, flaps on the custom axis [/], brakes B.
  - *Arm*: the selected hinges in chain order get key pairs 1/2, 3/4, 5/6…, and the
    claw or drill gets P.
  - *Rocket*: the standard set, as today.
- **Part presets.** Menu ▸ Controls ▸ *Copy controls* / *Paste controls* copies one
  part's bindings onto other parts of the same kind, with the uids remapped.
- `electronics.defaultGroups` stays the zero-click default, and `groupsAutoActuators`
  becomes the *Arm* preset.

**E. In flight.**

- A **Controls card** (O; K is RCS translation) lists the craft's keys, names and live state as
  annunciators (`hud/lamp*`: a lens lit while a toggle is on). Each custom axis has a
  small tape showing its setpoint.
- On the first flight of a craft with custom controls, a toast reads "6 custom
  controls ▸ O".
- The card is `flight_hud`'s, through a patch (WP5).

### 6.4 Storage

`bp.controls = { groups = packGroups(...) (as now), axes = { … }, custom = { c1 = { pos = "up", neg = "down", name = "Crane" } } }`.
The flight applies it in `vessel_controller.groupKeysTick`. `holdGroupAxes` becomes
`controls.evaluate(ctl, inputs, recs)`, which returns setpoints, and the existing
`partAction` writes them.

---

## 7. Aircraft

### 7.1 What the aerodynamics agent already ships (2026-10-23, uncommitted)

The aero agent works in parallel and has landed two rulebooks. This design builds on
them and does not duplicate them.

- **`scripts/aero.lua`** is a pure library on an `AeroLib` node. It has per-part
  body drag with shielding; thin-plate lift with Helmbold slope, Prandtl–Glauert,
  stall and induced drag; all-moving control surfaces mixed to pitch, yaw and roll by
  their moment about the CoM (KSP-style auto, with an axis mask `ctl=pr`); Mach drag;
  the world's air and oxygen; and jets. Its builder readouts are:
  - `frameOf(parts)` → nose and top;
  - `centerOfMass(parts, fuel_t)`;
  - `centerOfLift(parts, { alpha })` → point, lift per unit q, and direction;
  - `centerOfThrust(parts)`;
  - `staticMargin(parts)` → metres and mean chords;
  - `stallSpeed(parts, m, g, rho)`.
- **`scripts/parts_aero.lua`** holds the AIRCRAFT parts: Swift Cockpit, Fuselage
  Tank, Wasp Turbojet, Ram Intake, Shock Cone, Wing Panel S and L, Swept Wing, Wing
  Tip, Delta Wing, Elevon, Aileron Panel, Tail Fin, Canard, and Landing Gear S and M.
  - Each is a builder registry entry plus one string key, **`af`**, which holds the
    part's aero spec (`wing span= root= tip= lsw= le= cl0= ctl= defl= flap= hinge=`,
    `jet air= spool= mmax=`, `intake=`, `gear`, `cd=`…).
  - The builder joins them with `findScript("parts_aero").register(REG, CATALOGUE)`.
  - The blueprint carries `af` verbatim.
- **Frames.** A lifting surface is a radial part: +X is the span out from the root,
  +Y the chord with the **leading edge at +Y** (the host's nose-ward axis), and ±Z its
  faces. A cockpit flies nose-first (+Y nose, −Z canopy). A plane is built either
  nose-up (VAB style) or laid down (nose along the floor) for the runway. Controls
  follow the cockpit either way.
- **Gear** is a radial leg with a free-rolling tyre on the engine's wheel joint
  (`drive` with speed 0), brakes on B, steering on A/D at the front, retracting on G
  (`deploy` anim `legs`).

**The contract:** the builder never interprets `af`. It passes the part records it
already builds (`craft_records()` plus pose plus `af`) to `aero.lua` for every
aircraft readout, so the CoL you see is the lift you fly with. If the builder needs a
number aero.lua doesn't give, WP4 asks the aero agent for it by patch.

### 7.2 What the builder adds (WP4)

1. **The AERO tab of the parts panel** shows the AIRCRAFT section with thumbnails,
   and a "Light jet" sub-assembly preset. That preset is the aero agent's reference
   craft (cockpit, fuselage tank, Wasp, two Wing Panel L, two tips, two elevons, a
   tail fin, two intakes and three gears; 1.8 t), so a first plane is one pick.
2. **Wing placement that works first time.**
   - Picking a lifting surface with nothing else in hand turns on **mirror at the
     craft centre plane** (toolbar latched; section 5.7).
   - Surface attach on a fuselage snaps the root to the host grid along the fuselage
     and orients the leading edge to the craft's nose (`frameOf`), not to the host's
     raw +Y. That matters when the host is a bracket or a beam.
   - **Edge snapping between wing panels**: a panel aimed at another panel's tip edge
     joins span-wise (root chord to tip chord, flush, leading edges aligned). A panel
     aimed at a trailing edge joins chord-wise (for an aileron panel behind a wing). A
     whole wing is assembled from modules without hubs or nudging, using the
     attachment rules of section 5.3 applied to plates.
   - **Dihedral and incidence** are the ROTATE gizmo about the root chord line and
     the span line. On a lifting surface it snaps at 1°, and INSPECT shows dihedral,
     sweep and incidence as typed fields that rotate the mirrored pair together.
3. **Procedural wing (phase 2, proposed to the aero agent).**
   - One "Wing (procedural)" entry whose `af` the builder writes from handles: drag
     the tip for span and sweep (`lsw`), the root and tip trailing edges for chord, and
     the hinge line for a control share (`ctl`, `flap`, `defl`, `hinge`).
   - `scripts/wing_mesh.lua` builds the planform skins and a separate hinged
     control-surface mesh (`mesh.build`, cached by spec), with a box collider fitted
     to the planform (runtime `half_x/y/z`).
   - The aero model needs nothing new: it already reads any planform from `af`. Mass,
     cost and strength scale with area (`parts_registry.sizeOf`).
   - Until then, the modular panels plus edge snapping cover the need.
4. **Overlays** (V cycles), all from `aero.lua` in the craft frame, converted to the
   BuildFrame:
   - **CoM wet**, an amber disc, and **CoM dry**, a hollow ring, joined by a line, so
     the shift as fuel burns shows;
   - **CoT** (`centerOfThrust`), a blue disc and thrust line;
   - **CoL** (`centerOfLift`, alpha 5°), a cyan disc and lift arrow.

   The CRT strip shows **MARGIN** from `staticMargin` in mean chords (caution yellow
   under +0.03 MAC, red at or under 0) and **STALL ≈ v** from `stallSpeed` at the
   wet mass, the launch world's gravity and its sea-level density. This replaces
   today's always-on `draw_engineering`.
5. **Deflection preview.** A selected control surface shows its travel (`defl`) as a
   thin arc. In **TEST**, W/S, A/D and Q/E deflect every surface live with aero.lua's
   mixing (the same sign rule the flight uses). With overlays on, each surface shows
   its force arrow, so a reversed aileron or a rudder that also rolls is obvious
   before launch.
6. **Gear check** (RUNWAY site), drawn on the floor:
   - the ground line through the lowest tyres;
   - the main-gear contact line;
   - the **tip-back** test: the CoM must be ahead of the main gear, and the nose gear
     must carry at least 5 % of the weight;
   - the tail-strike rotation angle against the stall angle of attack.

   Each failure is a LAUNCH warning with the part outlined.
7. **Jets.** The INSPECT panel of a jet shows its intake supply: the sum of `intake=`
   over the craft against `air=` per jet, a ratio such as 0.12 / 0.12. LAUNCH warns
   "jets starved of air" below 1.0 when standing still. A world without oxygen
   (`aero.oxygen`) gets a warning: "this world's air won't light a jet".
8. **Runway.** The LAUNCH split key picks PAD or RUNWAY, latched. The default is
   RUNWAY when the craft has gear or wheels and a lifting surface, and PAD otherwise.
   The vessel spawner already supports the runway.

## 8. Large-craft support

### 8.1 Performance budget (acceptance numbers)

| Measure | Target at 1,000 parts | At 3,000 parts (hard cap) |
|---|---|---|
| Builder script, idle | ≤ 1.5 ms | ≤ 4 ms |
| Builder script, part in hand | ≤ 4 ms | ≤ 10 ms |
| Builder script, dragging 200 parts | ≤ 6 ms | – |
| Physics bucket in the builder | ≈ 0 (visual-only parts) | ≈ 0 |
| Load (open a craft) | ≤ 2 s, no frame over 100 ms (time-sliced, progress on the CRT strip) | ≤ 6 s |
| Undo or redo of a 200-part op | ≤ 50 ms | – |

The part count shows on the CRT strip. At **1,000** a caution placard notes the
flight cost and asks for the craft to be tested. **3,000** is the save cap. CRAFT ▸
Budget lists the counts: parts, colliders, draws (from `perf.counts`), procedural
meshes, and the builder's frame cost.

### 8.2 How to hit it (WP1)

- **Visual-only parts on the stand.** The builder spawns `prefabs/vis/Part*.prefab.ron`
  (the same mesh and materials, no rigidbody), generated alongside the flight prefabs.
  Picking is `rayPart` against candidates from the spatial hash, which is exact and
  needs no colliders.
- **A spatial hash** of part AABBs in the BuildFrame (cell 1 m, or 2 m beyond 1,000
  parts). It serves:
  - occupancy and overlap: O(1) on average;
  - the cursor ray: walk the cells along the ray and test only those parts;
  - auto-weld candidates.
- **Cached attach points.** Each part caches its node and joint-region points in the
  BuildFrame, invalidated only when it moves. Only the part under the cursor and its
  neighbours are asked for candidates, never every part.
- **Graph adjacency.** `links` sit in per-part adjacency lists. `dependents` is one
  BFS, and components use union-find.
- **Dirty-flag stats.** Stats, staging, power and launch checks recompute at most once
  a frame, and only when `craftVersion` changed. Spawn callbacks never call them.
- **Time-sliced load and paste.** At most 60 spawns a frame, with a progress readout.
- **Draw caps.** Outlines cover the selection up to 200 parts. Past that, one merged
  oriented box per symmetry set or outline group. Hover outlines one part. Node rings
  draw near the cursor only.
- **Draws.** 3 draws a part (4 materials) gives 3,096 draws at 1,000 beams. The
  generator merges the "Decal" material into the albedo atlas for frame parts (target
  ≤ 2 draws a part), and procedural members share meshes, so instancing holds.

### 8.3 Selection, groups and sub-assemblies

- **Selection** follows section 4.2. Menu ▸ Select also offers connected,
  symmetry set, same part type, outliner group, and invert.
- **Named groups** (CRAFT tab): Ctrl+G groups the selection ("Left wing", "Booster
  A"). Each row has eye (hide), lock and select. Groups are stored in `bp.groups` and
  never affect physics.
- **Sub-assemblies.** Menu ▸ *Make sub-assembly…* saves the selection, its internal
  links, controls and symmetry as a named blueprint fragment with a thumbnail in the
  **library** (section 8.4). Picking one from PARTS ▸ SUB-ASSY puts it in the hand,
  rooted at its first part. It attaches like a part, and its controls merge with the
  uids remapped (`electronics.remapGroups` already exists).
- **Merge.** OPEN ▸ *Merge into this craft* puts a whole saved craft in the hand.

### 8.4 Craft library and history

- **Library.** `shipyard.crafts = { [name] = bp }` in the save slot, plus
  `shipyard.current`. `shipyard.blueprint` stays the "on the stand" copy that the
  launch reads, so the vessel spawner is unchanged. Sub-assemblies live in
  `user://subassemblies/*.json` so they carry across saves. OPEN shows thumbnails
  (`camera.capture` at save) with part count, mass and cost.
- **History.** A command stack with do and undo, 500 steps:
  - place, move, rotate, delete, insert, detach, link, set a parameter, bind, rename
    and group;
  - redo is Ctrl+Y;
  - CRAFT ▸ History lists the steps, and clicking one jumps there;
  - a drag or a slider is one step;
  - history survives SAVE but not a scene unload.

### 8.5 Copy, paste and mirror

- **Ctrl+C** copies the selection with its internal links, wheel settings, shapes and
  bindings. **Ctrl+V** puts it in the hand. **Ctrl+D** duplicates it 0.5 m off along
  the camera's right and keeps the new copy selected.
- **Mirror selection** (menu): reflects the selection across the craft centre plane
  or a chosen part's plane as a new mirrored set (chiral parts reflect).

### 8.6 Camera for big crafts (WP2)

- **Orbit about a pivot.** The pivot is the point under the cursor at RMB-down, or the
  selection's centre. Zoom moves toward the cursor (distance clamps 0.5 m to 400 m),
  MMB pans, and **F** frames the selection's bounding sphere (Home frames the
  craft).
- **The height slider** (HT in 4.4): a fader on the viewport's right edge from the
  craft's floor to its top. Dragging it moves the pivot up and down the craft at the
  current yaw and distance. PgUp and PgDn step it 10 %.
- **Orthographic views** on the numpad: 1 front, 3 side, 7 top, and 5 toggles.
  Precise frames and wings need them.
- **Inside the VAB** the camera is soft-bounded to the building's interior plus the
  door volumes. It can leave through the doors (there is no wall jail). Near
  geometry fades (`vab_fade.lua`, from the VAB agent) when it stands between the
  camera and the pivot.
- **PHOTO.** F4 hides the UI and F5 frees the camera with the same keys as
  `planet_camera`. F12 takes a screenshot.

The craft centre is **mass-weighted**, from the AABB centre of the parts, not the
unweighted mean of part centres. The orbit distance comes from the bounding radius,
not the part count.

---

## 9. The building itself: in-world VAB architecture

### 9.1 Options

| | (a) Build in place in the system scene | (b) Keep `builder.ron` and reproduce the world | (c) **Hybrid: the builder as an additive overlay on the live system scene** |
|---|---|---|---|
| Fidelity | real: sky, time, sun, planets, weather, wind, flora, other craft, the crew | an imitation: sky and sun from the save clock, far bodies from the far_bodies cache, the base from its glbs; no live terrain, flora or weather | real, same as (a) |
| Enter, leave, launch | instant; launch rolls out with no reload | a scene load each way (world regen and streaming behind a loading screen) | instant enter (additive load of a small scene) and leave (`scene.unload`); launch converts in place |
| Performance | system scene baseline plus the builder | builder only (cheapest) | system scene baseline plus the builder; needs WP1's budget |
| Code shape | the builder merges into a scene full of other scripts; every part lives in the system scene file | separate and isolated; duplicates sky and world logic | the builder stays a self-contained scene file and set of scripts; only a small host glue touches the world |
| Input conflicts | walker, tool belt, map, pause, facility menu, planet camera | none | the same as (a), solved once with an input-owner flag |
| Frame | the planet is on rails and the VAB is tilted on a round world: the builder must work in a moving local frame | world Y up, static (today) | moving local frame (BuildFrame), as (a) |
| Risk | high: one big merge | low, but it doesn't meet the request | medium: the frame adapter and input gating are the risky parts; both can be tested in `builder.ron` first |
| Effort | high | medium (and thrown away later) | medium-high, with no throwaway work: the same code runs in both hosts |

### 9.2 Recommendation: (c)

The user's ask is literal: the real view from the real building, with time passing.
Only the live world delivers that. Building inside `system.ron` directly (a) would
weld 8,000 lines of builder code and UI into an already busy scene. Reproducing the
world (b) is a fake that has to be thrown away.

**`scene.load("builder", { additive = true })`** layers the builder over the running
world, and `scene.unload("builder")` removes it. The builder's parts and camera
attach to a **BuildFrame node inside the real VAB**, so they ride the planet and its
tilt.

How it works:

1. **The BuildFrame** (base agent, patch via WP6) is an empty child of the VAB
   building (`FacHangar`), placed at the VAB agent's `BUILD_POINT` on the mobile
   launcher deck (0, 2.6, 0 in the building's ground frame; `vab_dims.py`). +Y is the
   building's up and +Z its front (toward the apron and runway).
2. **Enter.** At the VAB, E (`facility_menu`) calls `build_host.enter()`. That:
   - sets `game_manager.inputOwner = "builder"`;
   - parks the astronaut (hidden, seated in the VAB, oxygen supplied);
   - loads `builder` additively.

   The builder finds `BuildFrame` and runs in its local frame. The world keeps
   running: time passes, weather blows through the open doors.
3. **The frame adapter** (WP1, `builder_space.lua`):
   - every builder coordinate is BuildFrame-local;
   - part nodes are spawned **as children of BuildFrame** (`spawn(..., fn, frameNode)`),
     so `node.x/y/z` are local and the engine carries them with the planet;
   - mouse rays come in through `frame:toLocal`;
   - `draw.*` goes out through `toWorld`.

   With no BuildFrame (`builder.ron` standalone, the fallback and the test host), the
   frame is the identity, which is today's behaviour.
4. **Physics held.** Stand parts are visual-only (8.2), so nothing on the stand
   simulates or collides. The crew and debris can't knock it, and the 58 ms
   kinematic cost disappears.
5. **Leave.** LEAVE saves the craft to the library and unloads the overlay. The
   astronaut stands at the VAB console. There is no reload.
6. **Launch.** The builder writes `shipyard.blueprint` as today and calls
   `build_host.rollout(site)`. `vessel_spawner` gets an in-place entry (patch):
   - it builds the Vessel at the BuildFrame from the stand parts' poses (it can reuse
     their nodes' places);
   - it anchors the craft there;
   - it unloads the overlay;
   - then it **rolls the anchored craft out**: a 6–10 s crawler move through the door
     along the crawlerway to the pad (PAD), or along the taxiway to the runway
     threshold (RUNWAY), with the camera following and skippable with Space;
   - it hands the pilot seat over exactly as the pad flow does today.

   A rover or plane can instead launch "here", unanchored on the VAB floor, and be
   driven or taxied out through the 42 m lower door.
7. **Input owner.** One published flag (`game_manager.inputOwner`). While it is
   `"builder"`:
   - `planet_walker`, `tool_belt`, `planet_camera` (except PHOTO keys), the map key,
     `pause_menu` (ESC goes to the builder first), `facility_menu` and `flight_hud`
     return early;
   - the builder camera takes `active = true` and gives it back on leave.

   These are one-line gates, delivered as patches to their owners. The engine's
   `input.pushContext` would do this for action-based input; Solar mostly reads raw
   keys, so a flag is the practical gate.
8. **Fallback.** `builder.ron` keeps working on its own: identity frame, a
   `VabInterior` prefab instance instead of the old box hangar, and a time-of-day sky
   from the save clock. It is the test host for probes and smoke tests, and the
   fallback if the additive path hits an engine blocker.

### 9.3 Interior size and fading (aligned with the VAB agent)

- The VAB agent is building to **50 × 50 m, 72 m high**:
  - 48.8 m clear wall to wall;
  - work platforms from 10.5 m up;
  - the bottom chord of the roof trusses at 65.5 m;
  - door: an inverted T, 42 × 20 m below and a 24 m slot up to 64 m;
  - a mobile launcher 24 × 20 m, deck at 2.6 m.

  That holds a 60 m rocket and a 40 m wingspan. The builder adopts it:
  - the **build volume** is the floor ±24 m and the ML deck to 62.9 m;
  - parts may extend outside it, but LAUNCH warns when the craft won't clear the door
    (the rollout path checks the AABB against the door's T profile).
- **Fading** is the VAB agent's `vab_fade.lua`. Shell sections (each wall, each door
  end, the roof) and the near platforms dither out when they stand between the camera
  and the pivot, or within 3 m of the camera. The builder publishes
  `builderCamera.pivot` and its position for it.
- The **interior lamps** are real lights. With the doors open, the sun and sky light
  the floor by day, and the interior lamps carry the night.

### 9.4 Risks and mitigations

| Risk | Mitigation |
|---|---|
| The planet moves between the builder's update and the draw, so overlays lag a frame | draw in `lateUpdate` (probe cameras already must); an engine card asks for `draw` in a node frame (section 12, card 4) |
| System scene frame cost plus the builder | WP1 budget; the overlay disables flora interaction and walker raycasts while active (input owner) |
| Additive load places the layer at a world offset; the planet moves | the overlay's 3D nodes are reparented to BuildFrame on start (`node:setParent`); its UI is screen-space anyway; card 5 asks for `scene.load{ additive, parent = node }` |
| Two copies of manager scripts (company, research, electronics) when overlaid on `system.ron` | the overlay scene carries none: the builder finds the system scene's (`findScript`). In standalone `builder.ron` they come from a sub-tree the overlay strips (WP6 builds two variants from one file, or `build_host` disables duplicates) |
| A save mid-build | the stand is saved to `shipyard.crafts[current]` on every change (debounced 2 s), so a crash or quit loses nothing |

---

## 10. A competitive look

| Game | What works | Take for Solar | Avoid |
|---|---|---|---|
| **KSP 1** | stack nodes plus Alt surface attach; offset and rotate gizmos (1–4); radial and mirror symmetry; CoM, CoL and CoT overlays; sub-assemblies; tweakable control surfaces (authority, per-axis); the action group editor | the 1–4 tool numbering; offset with a limit; overlays; per-axis control-surface authority; sub-assemblies and merge | the VAB vertical-axis camera jail; node clutter; struts as the only bracing; separate VAB and SPH |
| **KSP 2** | procedural wings (span, sweep, chord, thickness); multi-select; free-floating unattached assemblies in the workspace; the part manager | procedural wings; multi-select; loose islands that warn at launch | heavy UI chrome |
| **SimplePlanes** | procedural wings and fuselages that adapt; the Fine Tuner with numeric entry; **input mapping per part** (Pitch, Roll, Yaw, Throttle, VTOL, Trim, Activate 1–8, gain and invert); auto-connect of touching parts | the axis-binding model (6.1); numeric gizmo fields; auto-weld on contact | expression-language inputs as the default (keep it simple: source, gain, trim, mode) |
| **Stormworks** | everything snaps to a 0.25 m grid, so alignment is free; seat key bindings feed logic; merge blocks | the **host grid** for surface attach (5.2) and the floor grid; grid steps shown on the toolbar | voxel blockiness: Solar's grid is a snap, not a shape |
| **Space Engineers** | adjacent blocks merge automatically; symmetry planes set anywhere; copy, paste and projectors; toolbar action pages per cockpit | auto-merge (`weld` links); symmetry planes at the craft centre; copy and paste of linked selections | huge block grids for small craft |
| **Besiege** | any block on any face; **braces** between two arbitrary points; the key mapper (select a block, press a key; one key drives many) | the brace part; bind by pressing the key; the keymap tab | cartoon physics |

---

## 11. Implementation plan

### 11.1 Interfaces first (day 0, about 2 hours, WP1 and WP6)

**The public builder API.** These are globals on the `builder` script, reached with
`findScript("builder")`. Every panel and overlay uses only these; nothing reads
`parts` directly.

```lua
-- queries
craftVersion                     -- integer, bumped on every change (poll to refresh)
partUids() ; partRec(uid)        -- rec: { uid, id, def, x,y,z, B (basis), size, sym, mir, links = {…} }
selection() ; select(uids, mode) -- mode: "set" | "add" | "toggle"
hovered() ; held()               -- uid or nil ; { ids… } or nil
stats()                          -- { parts, mass, dry, cost, dv, twr, com, cot, … }
frame()                          -- the adapter: toLocal / toWorld / dirToLocal / dirToWorld / ray(mx, my)
-- commands (all undoable, one history step each)
cmd(name, args)                  -- "place" "move" "rotate" "delete" "insert" "detach" "link" "unlink"
                                 -- "setParam" "setWcfg" "bind" "unbind" "bindAxis" "group" "rename"
hold(spec)                       -- spec: part id | uid list | sub-assembly table
-- UI plumbing
registerPanel(script)            -- script.ownsMouse() → bool; the builder skips picking while any does
hint(msg, secs) ; placard(msg, kind)
testMode() ; setTestMode(on)
```

**The rulebook pattern.** `builder_graph`, `parts_registry`, `controls`,
`builder_attach` and `wing_mesh` are pure scripts on manager nodes (as are the aero
agent's `aero` and `parts_aero`, on their `AeroLib` node):

- no scene access;
- their globals are their API;
- each loads from disk in a luajit test, as `electronics.lua` does.

**`scenes/builder.ron` scaffold (WP6, day 0).** It adds manager nodes for every
rulebook script above, plus one host node per panel script (`builder_toolbar`,
`builder_inspector`, `builder_context`, `builder_bind`, `builder_aero`,
`catalog_panel`, `groups_panel`), and the `AeroLib` prefab instance. After that, WP6 alone edits the scene file.

### 11.2 Work packages

Each package owns its files outright. A change needed in another package's file is
a patch in `SCRATCH/<wp>/…patch`, sent to the owner.

**WP1. Builder core: graph, frame, history, performance and input**

- **Owns:**
  - `scripts/builder.lua` (it becomes the orchestrator and loses REG to WP3);
  - new `scripts/builder_graph.lua`, `scripts/builder_space.lua` and
    `scripts/builder_history.lua`;
  - `tests/smoke_builder.lua`, `smoke_builder_orient.lua`, `smoke_builder_rc3.lua`,
    `smoke_builder_elec.lua`;
  - new `tests/smoke_builder_graph.lua` and `smoke_builder_perf.lua`.
- **Does:**
  - the public API (11.1);
  - the links graph, dependents, components, staging under the graph, and blueprint
    v2 with v1 import;
  - the frame adapter, with every computation local;
  - the spatial hash, cached attach points, dirty-flag stats and time-sliced
    load and paste;
  - visual-only spawns (falls back to the flight prefabs until WP3 ships `vis/`);
  - selection: click, Shift, Ctrl, box, double-click, and drag versus click;
  - drag-move with dependents, Alt-drag, insert and detach;
  - the OFFSET and ROTATE gizmos in mount and world space, with snaps and the offset
    limit;
  - the history (500 steps, redo, list);
  - the craft library, sub-assemblies, copy, paste and duplicate;
  - the key map of 4.3, and ESC never leaving;
  - the aero agent's builder hook: the `parts_aero.register` call, an `AeroLib` node
    when the scene has none, and `af` carried into the blueprint record. This is
    `SCRATCH/aero/builder.patch` when it arrives; apply it first and keep it through
    the refactor.
  - It calls WP3's `builder_attach.candidates` for snaps, and keeps today's node rules
    behind a flag until WP3 lands.
- **Acceptance:**
  - luajit: the existing builder smokes pass (updated to the API);
  - `smoke_builder_graph`:
    - dependents of a mid-frame beam = {} in a closed rectangle;
    - decouple components;
    - a hinge locked by a loop is detected;
    - a v1 blueprint round-trips v1 → v2 → flight fields;
  - `smoke_builder_perf` with the stub engine: 1,000-part lattice; with a part in
    hand, `find_snap` plus telegraphs make fewer than 20,000 part visits a frame
    (counted);
  - the engine probe (`SCRATCH/builder_ux/uxprobe.lua` perf mode, rerun) meets
    table 8.1: 1,000 parts with a part in hand ≤ 4 ms; physics ≈ 0; a 2,000-part load
    with no watchdog and no frame over 100 ms;
  - KLM re-time of T5a ≤ 5 s (a probe that drops onto a joint);
  - no watchdog in any mode up to 3,000 parts.

**WP2. Interaction UI and camera**

- **Owns:** `scripts/builder_camera.lua`, `scripts/catalog_panel.lua`,
  `scripts/builder_hud_button.lua`, and new `scripts/builder_toolbar.lua`,
  `scripts/builder_inspector.lua`, `scripts/builder_context.lua` and
  `scripts/builder_statusbar.lua`. Its new styles go in a `builder/*` block of
  `ui/solar.uistyle.ron`, by patch to the UI agent unless it is handed ownership.
- **Does:**
  - the toolbar, the parts panel (search, tabs, thumbnails cached per part, RECENT,
    SUB-ASSY), INSPECT (numeric fields, part settings, the wheel settings moved here),
    the context menu, the CRT status strip, placards, and the `?` key overlay;
  - the camera: orbit about the pivot, pan, zoom to the cursor, F and Home framing,
    the height slider, orthographic views, the BuildFrame-local up, soft bounds,
    `pivot` published for `vab_fade`, and PHOTO;
  - everything through the WP1 API; the house style throughout.
- **Acceptance:**
  - `smoke_builder_ui` (luajit):
    - each panel's `describe()` builds with no missing style;
    - search "tank" + Enter holds `tankS`;
    - the context menu lists Controls for a hinge;
  - shots at 1280 × 720 and 2560 × 1440 (`floptle shot --size`) for the main layout,
    the context menu and the inspector, with no overlaps or clipping;
  - a camera probe: F frames a 60 m rocket inside the view; the slider moves the pivot
    from 0 to 60 m; zoom to the cursor keeps the point under the cursor fixed (≤ 2 px
    drift);
  - `catalog_panel` ≤ 0.3 ms a frame (from 1.4–1.8).

**WP3. Attachment and frame parts**

- **Owns:**
  - new `scripts/parts_registry.lua` (REG, DESC and CATALOGUE moved verbatim from
    `builder.lua`, plus `sizeOf(def, size)` for procedural mass, cost and strength,
    and the call to the aero agent's existing `parts_aero.register(REG, CATALOGUE)`);
  - new `scripts/builder_attach.lua` (candidates, joint regions, grid snapping,
    auto-weld tests, the joint geometry of 5.2–5.3);
  - new `scripts/builder_proc.lua` (procedural member and panel meshes, gussets,
    splice plates, the mesh cache);
  - `tools/gen_part_meshes.py`, `prefabs/Part*.prefab.ron` (frame and existing parts)
    and new `prefabs/vis/*.prefab.ron`;
  - the Brace part;
  - `tests/smoke_catalogue*.lua` and new `tests/smoke_attach.lua`.
- **Does:** sections 5.2–5.5. The node radius rules; host-grid surface attach; the
  splice, corner, tee and cross joints; auto-weld; procedural beams and panels with
  handles; the Brace; occupancy from links, not world Y; visual-only prefab variants;
  and the Decal material merged into the frame parts' atlas.
- **Acceptance** (luajit `smoke_attach` with fixed geometry):
  - aiming at a post's side 5 cm under its top offers `corner`, and the placed
    member's top face is flush with the post's top (within 1 mm);
  - aiming at the span gives `tee` at the grid point;
  - a 4-beam rectangle closes with 2 welds on the last member;
  - an occupied joint on a horizontal beam is never offered;
  - on a 2 m beam seen at 6 m, the surface point between the middle and the end is
    reachable (the node does not capture it);
  - engine probe `beams` (rerun): shots show a flush L with no hub, a T, and no red
    ring on occupied joints;
  - KLM: a 2 × 2 × 2 m cube frame of 12 members ≤ 40 s with the Beam tool.

**WP4. Aircraft (builder side)**

- **Owns:**
  - new `scripts/builder_aero.lua` (overlays, the margin and stall readouts, the
    deflection preview in TEST, the gear tip-back check, the jet intake check, the
    nose-aligned and edge-snapping rules for lifting surfaces, which WP3's
    `builder_attach` calls through a hook);
  - new `scripts/wing_mesh.lua` (phase 2 procedural wing meshes);
  - the "Light jet" sub-assembly preset file;
  - new `tests/smoke_aero_builder.lua`.
- **Does not own** `scripts/aero.lua`, `scripts/parts_aero.lua`, their prefabs or
  `tests/smoke_aero.lua`. Those are the aerodynamics agent's. WP4 sends patches
  (for example a `wingProc` entry, or a readout aero.lua lacks) and coordinates
  through `SCRATCH/aero/NOTES.md`.
- **Acceptance:**
  - luajit:
    - the overlay CoL equals `aero.centerOfLift` for the reference light jet (it is
      the same call: a guard against frame-conversion errors, within 1 mm);
    - a mirrored aileron pair deflects opposite ways for roll in TEST (`aero` mixing
      signs);
    - the tip-back check flags a craft whose CoM is behind its main gear;
    - wing-panel edge snap: a Wing Tip on a Wing Panel L's tip edge is flush (chord
      and leading edge within 1 mm);
  - probe: build the reference light jet in ≤ 90 s of simulated input (thanks to the
    preset, in ≤ 15 s); TEST shows deflections (shot); LAUNCH ▸ RUNWAY spawns it on
    the threshold;
  - with the aero agent's flight model: the jet takes off and climbs at full throttle
    (the aero agent's own flight probe).

**WP5. Controls (groups, axes and binding)**

- **Owns:** new `scripts/controls.lua` (the rulebook: axes, `validKey`, axis
  evaluation, presets, pack and unpack), `scripts/groups_panel.lua` (rebuilt as the
  CONTROLS tab), new `scripts/builder_bind.lua` (the B prompt flow), and new
  `tests/smoke_controls.lua`.
- **Patches out:**
  - `vessel_controller.lua` (vehicles agent): `groupKeysTick` evaluates the axes,
    reads `bp.controls`, and stays compatible with old `bp.groups`;
  - `flight_hud.lua` (UI agent): the Controls card on O;
  - `electronics.lua` (electronics agent): only if a helper is missing. It should not
    be.
- **Acceptance:**
  - luajit:
    - bind a hinge to ↑/↓ as a rate axis; 1 s of ↑ moves the setpoint +30°;
    - a position axis returns to trim on release;
    - a reserved key is refused with its reason;
    - the *Arm* preset on 2 hinges and a claw gives 1/2, 3/4 and P;
    - v1 `bp.groups` load unchanged;
  - probe: T4 (select light, B, 4, Enter) in ≤ 4 s of simulated input; T2's binds in
    ≤ 12 s; TEST moves the arm (shots before and after);
  - flight probe (vehicles agent): a hinge on a custom axis moves in flight.

**WP6. In-world VAB host**

- **Owns:**
  - `scenes/builder.ron` (the overlay scaffold, the standalone variant with the
    `VabInterior` instance, the old hangar box removed);
  - new `scripts/build_host.lua` (enter, leave, rollout, the input owner, BuildFrame
    lookup, the autosave debounce);
  - `scripts/facility_menu.lua`, the VAB entry only (or a patch, if the base or UI
    agent holds it).
- **Patches out:**
  - `base_facilities.lua` (base agent): the BuildFrame node at `BUILD_POINT`;
  - `game_manager.lua`: `inputOwner`;
  - `planet_walker.lua`, `tool_belt.lua`, `planet_camera.lua`, `pause_menu.lua` and
    `flight_hud.lua`: one-line gates;
  - `vessel_spawner.lua` (vehicles agent): the in-place spawn and the rollout to the
    pad or runway.
- **Coordinates:** the VAB agent's `vab_fade.lua` and the interior prefab.
- **Acceptance:**
  - a probe on a new save:
    - E at the VAB shows the builder over the live world within 1 s (shot: the open
      door, the sky and the base beyond);
    - building through 2 minutes of game time shows the sun moving (shots at t = 0
      and t = 120 s);
    - LEAVE returns to the astronaut in under 0.5 s with no loading screen;
    - LAUNCH ▸ PAD rolls out and clamps on the pad; LAUNCH ▸ RUNWAY reaches the
      threshold;
    - `game_manager` reports no world reload;
  - the same flows work in standalone `builder.ron`;
  - no input leaks: W walks nothing, M opens no map, ESC never leaves;
  - frame budget: system scene plus the builder at 300 parts ≤ the system scene
    baseline + 5 ms.

### 11.3 Order and dependencies

```
day 0   WP1 API stubs + WP6 builder.ron scaffold + WP3 moves REG → parts_registry (one sitting, with WP1)
week 1  WP1 graph/frame/hash/history   WP2 panels+camera on stub API   WP3 attach+proc   WP4 overlays on aero.lua   WP5 controls rulebook   WP6 host in builder.ron
week 2  WP1 integrates WP3 candidates   WP2 wires real API   WP4 TEST preview + edge snapping   WP5 bind flow + patches   WP6 additive host on system scene
week 3  integration probes (all acceptance), KLM re-timing of T1–T5, playtest build
```

- WP2, WP4 and WP5 depend only on the API (11.1) and can start on stubs.
- WP3's candidates plug into WP1 behind a flag.
- WP6's in-world mode needs WP1's frame adapter. Until then it works in standalone
  `builder.ron`.

---

## 12. Engine cards (for E)

1. **Spawn without a body.** `spawn(prefab, pos, fn, { body = false })`, or a prefab
   flag for display-only instances. Repro: 1,000 `PartBeam1` prefabs (`Kinematic`
   box) stacked in the builder scene; the physics bucket reads 57.9 ms idle (probe
   `perf3`). Solar works around it with generated `prefabs/vis/` variants.
2. **Kinematic–kinematic contact cost.** The same repro. Touching kinematic bodies
   that never move seem to cost broadphase and narrowphase time every tick (300
   parts: 18.3 ms; 1,000: 57.9 ms). They should sleep, or skip pairs.
3. **The watchdog stop is permanent in play.** `floptle-script/src/budget.rs:166`:
   "the script is stopped until it is edited". In a shipped game one slow frame kills
   a script for the session with no recovery. Repro: the builder with 500 parts and a
   part in hand. Ask for a soft mode in play (skip the hook, log, retry next frame, and
   stop after N consecutive trips), or a `script.onBudget` hook.
4. **`draw.*` in a node's frame.** `draw.setFrame(node)` (or a `frame =` option) so
   overlays in a moving planet frame don't convert every vertex in Lua, and don't lag
   when the frame moves after `lateUpdate`.
5. **Additive scene parented to a node.** `scene.load(name, { additive = true, parent = node })`.
   Today `offset` is a world vec3, which is wrong on a planet on rails.
6. (Minor) **Draws per part.** 1,000 four-material parts give 3,096 draws. Merging
   materials across instances of one model, or batching same-shader materials, would
   help big crafts in flight too.

---

## 13. Open questions for the user

1. Rollout: an animated crawler drive to the pad (6–10 s, skippable), or a fade and
   teleport? The design assumes the drive.
2. Should leaving the VAB keep the craft "on the stand" (visible in the VAB in the
   world) or stow it? The design keeps the last craft visible on the mobile launcher,
   which is nice from outside.
3. The part-count soft cap of 1,000 and hard cap of 3,000: are these acceptable as a
   first target?
