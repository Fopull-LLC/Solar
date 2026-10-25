# Where the outdoor GPU frame goes on 0.117.0-rc25 (2026-10-25, quiet machine, load 1–4)

The quiet rc22-vs-rc25 benchmark found the frame GPU-bound outdoors: "opaque +
lighting" 16–24 ms, "matter / terrain" ~6, ~3,000 terrain render slots, 750
draws. This is the per-pass breakdown of that frame and an A/B of every dial
that could be in it, from the new `gpu` mode of `tools/perf/perfbench.lua`
(`bench.sh <engine> gpu`, strs `where`/`toggles`/`res`/`gfx`; `gputable.py`
tabulates; `gpushot.sh` photographs one look). Each toggle is applied alone for
6–10 s at the same spot and judged against the untouched look measured on
either side of it, so a scene that drifts (the far rings streaming in, the
flora growing) cannot pass for a toggle. NVIDIA 8 GB card, `floptle play`
under XWayland, vsync off.

## The headline

1. **The bench's "720p" is 1920×1052.** The XWayland play window opens at
   1920×1052, not the 1280×720 `project.ron` implies, and `graphics.lua` picks
   **High** for any screen up to 1100 px tall when no settings slot exists, so
   every fresh-save bench ran at High (render scale 1.0, VOLUMETRIC fog, shadow
   distance 572 → the engine's 400 m cap) at 2.0 MP. The player's own save
   plays at **Medium** (scale 0.9, distance fog), full screen 1920×1080.
2. **At High the lit volumetric fog IS the GPU frame.** Standing on the meadow
   120 m out: 29.8 ms, of which the fog march is 19.6 (distance fog instead:
   9.7–10.5 ms everywhere). It is paid per pixel in BOTH passes — "opaque +
   lighting" for every surface pixel (−16 ms) and "matter / terrain" for every
   sky pixel (−4.4 ms, the raymarch pass is the sky). Inside the fog the light
   injection (`fogLight`, one star phase per step) is 14 of those 20 ms; the
   drifting noise 4.6; 12 steps instead of 16 save 5, 8 steps save 10.
3. **Overdraw multiplies it.** Whatever is drawn in layers pays the march per
   layer: the grown wetland flora (357 props in view) is 12.4 ms at High and
   1.5 ms at Medium; the hangar seen from inside (the spawn) 6.3 + its interior
   3.2. The fully grown meadow by the rover pushed the look from 20 to 33–40 ms.
4. **Shadows, terrain slots, far bodies, the sea, post, SSR, contact shadows are
   not it.** With the sun shadow MAP (system.ron) sun shadows cost 1.1–1.4 ms
   in all (the map 0.7–1.1 + 0.4 in the lighting); the field march instead of
   the map would add 6–8 ms. Shadow distance 150/336/572 and softness: no
   change (the map is one 2048² cascade whatever the distance). 2,900–14,000
   resident chunk slots: the renderer frustum-culls them per chunk
   (`push_terrain_instances`), 750–1,100 draws either way, and the terrain
   pass is 1.65 ms flat with the fog off. Far-body impostors, the sea, the
   post chain (0.6), the base's lamps (0–1 ms in the fog), contact shadows
   (+0.4–0.9 when ON; they are off by default) — all within 1 ms.
5. **The player's own save is not GPU-bound.** At the spawn on Medium,
   1920×1080 full screen, scale 0.9: **9.3–10.0 ms** GPU (opaque + lighting
   3.0–3.6, prepass 1.8–2.7, terrain 1.65, sun map 0.7–1.0, sky 0.7, post 0.6)
   against a 13.4 ms frame — the frame there is CPU-bound (render 6.8, scripts
   4.1). Half of the 9.3 is per-pixel (scale 0.5 → 6.9), so at 2560×1440 × 0.9
   it would be ~12 ms. (2560×1440 could not be measured: under XWayland the
   game's full screen stays on the 1920×1080 monitor, `app.setDisplayMode`
   with `monitor = 1` returned true but the picture stayed 1920×1080.)
6. **Applied (Solar):** `graphics.lua` now sets `fogSteps` per level — High
   12 (was the engine's 16), Ultra 16, Medium 12 / Low 8 (both levels use
   distance fog, so it only matters if volumetric is ever turned on there).
   High on the meadow: 29.8 → 24.7 ms; by the rover 19.9 → 17.0; on the
   Medium save: no change. Three `floptle shot` pictures of the meadow at 16,
   12 and 8 steps differ from each other by 1–2 % of pixels over 4/255, and
   the 8-step picture differs LESS from the 16-step one than the 12-step
   picture does, i.e. the differences are plant sway between runs, not the
   fog. 8 steps (−10 ms) is a further option; it was kept at 12 because a
   thick dawn or storm mist, which the shots do not cover, is where fewer
   steps show. Everything else that would reach 16 ms at High is engine-side
   (below) or a look change (fewer/shorter flora, no volumetric fog on High),
   neither of which this pass took.

## Per scenario, before and after (High, 1920×1052, fresh save)

GPU ms (opaque + lighting / matter / terrain in brackets), the same spots, the
"after" runs with the committed `graphics.lua` (its state line reads
`fogSteps 12`), load 2–7:

| spot | before (fogSteps 16) | after (fogSteps 12) | what remains at High |
|---|---|---|---|
| the spawn (inside the hangar), standing | 24.1 (14.5 / 6.3) at the reveal; 29.5–30.1 (20.8 / 6.4) settled | 19.5 (11.4 / 5.3) | fog 13.5–20, the hangar + its interior 9.5 |
| wetland meadow 120 m out, standing (357 props) | 29.8 (21.2 / 6.2) | 24.6 (17.0 / 5.1) | fog 14.7 (light injection 13.7), flora 12.4 |
| rover stopped 200 m out | 19.9–21.0 (10.9–12.2 / 6.2) | 18.3 (10.6 / 5.1) | fog 12.5; the meadow once grown +13 |
| the player's save, Medium, 1920×1080 × 0.9 | 9.3–10.0 (3.0–3.6 / 1.65) | unchanged (no volumetric fog) | a CPU-bound 13.4 ms frame |

Pictures (1920×1052, `floptle shot --after 80s`, the meadow spot): before
`$SCRATCH/gpu/before-meadow-high-fogsteps16.png`, after
`$SCRATCH/gpu/after-meadow-high-fogsteps12.png`, the 8-step option
`$SCRATCH/gpu/option-meadow-high-fogsteps8.png`, and the spawn
`$SCRATCH/gpu/spawn-hangar-high-look.png` (the "100 m out" of the first walk
runs: the spawn is inside the hangar, already 100 m from the base origin).
After vs before: mean 0.9/255, 1.9 % of pixels over 4/255 and 0.6 % over 16 — the same as two 16-step pictures of a swaying meadow differ from each other.

## What each dial changed (GPU ms, toggle against the mean of the looks either side)

High, 1920×1052, fresh save (the spot in brackets); Medium = the player's save at 1920×1080 × 0.9.

| dial | meadow (L) | rover (E/F) | hangar at the spawn (D/G/I) | base stand (A) | player's save, Medium (B/H/J) |
|---|---|---|---|---|---|
| distance fog instead of volumetric (`fogvol0`) | — | −12.5 | −19.6 | −13.6 | n/a (already) |
| fog light injection off (`foglight0`) | −13.7 | −7.5 | −14.0 | — | n/a |
| fog noise off (`fognoise0`) | −4.6 | −2.3 | −4.7 | — | n/a |
| fogSteps 12 (`fogsteps12`) | −5.1 | −2.9 | −5.0 | — | n/a |
| fogSteps 8 (`fogsteps8`) | −10.4 | −6.4 | −9.9 | −6.4 | n/a |
| sun shadows off (`shadows0`) | — | — | — | −1.3 | −1.2 / −1.4 / −0.9 |
| shadow march instead of the map (`shadowmap0`) | — | — | — | +4.2 | +5.9 |
| shadow distance 150 / 336 | — | — | — | +0.9 / +0.9 (contact was on) | −0.15 |
| shadow softness 0 | — | — | — | +0.8 (contact was on) | — |
| contact shadows ON (`contact1`) | — | — | — | — | +0.85 / +0.36 |
| SSR off (`ssr0`) — it is already off | — | — | — | 0 | — |
| post chain off (`post0`) | — | — | — | −0.6 | −0.6 |
| flora off (`flora0`) | −12.4 | −1.5 (part-grown) / −8 to −13 (grown) | 0 (none in view) | (drifted) | −1.5 / −0.7 |
| far-body impostors off | — | — | — | (drifted) | 0 |
| sea hidden | — | — | 0 | (drifted) | −0.2 |
| base facilities hidden (`base0`) | — | 0 | −8.9 / −9.1 / −9.3 | (drifted) | −0.2 |
| … hangar alone / interior / pad / floods / others | — | — | −6.3 / −3.2 / −0.65 / 0 / −1.0 | — | — |
| the base's 8 lamps pulled in (`lights0`) | — | 0 | −1.0 | — | — |
| render scale 0.5 (diagnostic) | −17.9 | −21 | −18.1 | −19 | −2.6 / −0.6 / −1.2 |

(A's later toggles are marked "drifted": that first run had no interleaved
looks and its restore of `contact0` left contact shadows ON, and the far-body
and flora round trips left more drawn; the protocol was fixed for every later
run.)

## Engine-side (general asks, with repro and source)

Repro for all: `WORK=$SCRATCH/x LOCK=$SCRATCH/engine.lock BENCH_STRS='("where", "walk"), ("toggles", "fogvol0,foglight0,fogsteps8,flora0,scale05")' tools/perf/bench.sh 0.117.0-rc25 gpu` on a fresh save (High), 1920×1052; the `GPU [..]` and `GPU DELTA [..]` lines.

1. **Volumetric fog is marched per full-resolution pixel, twice.** `apply_fog`
   (crates/floptle-render/src/field.wgsl, `fog_march`) runs `fog_steps`
   samples from the camera to the surface for every raster fragment, and
   `fog_sky` runs it again for every sky pixel of the raymarch pass
   (raymarch.wgsl). At 2.0 MP and 16 steps that is 13–20 ms of a 20–30 ms
   frame, and a game can only trade it for banding (`fogSteps`) or turn it off.
   A general mechanism: march the fog at reduced resolution (half or quarter
   per axis, or a froxel volume), depth-aware upsample, composite once —
   the same look at 1–3 ms. A smaller one inside the march: `fog_inscatter`
   is 70 % of the step cost (`foglight0` −14 of −20 ms) and evaluates the
   star direction, colour and phase per step although they barely change
   along a ray; one evaluation per pixel (or per few steps) would halve it.
   Also: the steps are spread uniformly camera→surface whether or not the ray
   is inside the layer (`vol_fog_layer` ≤ 0 → `continue`), so on a 400 m ray
   through a 40 m mist most samples are wasted; clipping the march to the
   ray's span through the layer shell would put every step in the mist.
2. **Layered cutout crowds pay the whole per-fragment cost per layer.** A
   grown scatter field (357 props, trees and grass, alpha-cutout cards) costs
   12.4 ms at High and 1.5 ms at Medium at the same spot; the hangar's
   exterior + interior 9.5 ms from inside. With the depth prepass priming
   depth, hidden card fragments should be killed before the shader; the
   numbers say they are shaded (fog + lighting) and then rejected. Worth
   checking in `raster.rs` whether the opaque colour pipeline (depth write ON,
   `LessEqual`, a shader with `discard`) gets early-z on this driver; a colour
   pass that keeps depth writes off and compares `Equal` against the primed
   depth lets the test run early despite `discard`, or sort cutout instances
   front-to-back. (`push_scatter` in crates/floptle-editor/src/scatter_draw.rs
   puts props through the ordinary raster path, so this is the general
   opaque-with-discard case, not scatter's.)
3. **`app.setDisplayMode` under XWayland on a two-monitor desktop**: `fullscreen
   = true, monitor = 1` (the 2560×1440 HDMI) returned true and the picture
   stayed 1920×1080 on the other monitor; `fullscreen = false, 2560×1440` was
   overridden by the game's own `opt_fullscreen` and when applied after it the
   window stayed 1920×1080. A resolution a settings page lists should take, or
   the call should say why it did not (`camera.screenSize` is the only way to
   find out).
4. **Not a bug, a note:** terrain render slots are frustum-culled per chunk
   and per far group (`push_terrain_instances`, terrain_edit.rs), so 2,900 →
   14,000 resident slots cost the same ~1.65 ms terrain pass; `perf.counts().chunks`
   is the resident count, not what is drawn — a `chunksDrawn` count would have
   answered the "3,000 slots" question without this run.

## The full per-pass tables

Every run, every scenario: picture, render scale, graphics level, frame p50,
GPU total, the passes the engine timed (glass, particles, reflection capture,
editor UI and theme backdrops are each ≤ 0.2 ms and are left out), draws,
instances, resident chunk slots and scatter props in view. `look` rows are
the untouched look; `lookN` the untouched look after the N-th toggle.

#### A-base-720-high (load 1.09, 1.79, 4.44 before, 2.90, 3.28, 4.57 after)

| scenario | picture | scale | level | frame p50 | gpu ms | sky | prepass | matter/terrain | sun map | opaque+light | 2D light | post | draws | inst | chunks | props |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| g_base_look | 1920x1052 | 1.00 | High | 24.0 | 24.1 | 0.11 | 0.91 | 6.33 | 1.07 | 14.53 | 0.01 | 0.78 | 958 | 995 | 2909 | 25 |
| g_base_contact0 | 1920x1052 | 1.00 | High | 24.0 | 24.1 | 0.10 | 0.88 | 6.33 | 1.10 | 14.57 | 0.01 | 0.78 | 980 | 1017 | 4789 | 25 |
| g_base_fogvol0 | 1920x1052 | 1.00 | High | 11.4 | 10.5 | 0.46 | 1.69 | 1.95 | 1.10 | 4.21 | 0.01 | 0.79 | 979 | 1016 | 6151 | 25 |
| g_base_fogsteps8 | 1920x1052 | 1.00 | High | 17.7 | 17.7 | 0.10 | 0.88 | 4.16 | 1.12 | 10.33 | 0.01 | 0.78 | 979 | 1016 | 6151 | 25 |
| g_base_shadows0 | 1920x1052 | 1.00 | High | 22.8 | 22.8 | 0.09 | 0.87 | 6.34 | 0.01 | 14.42 | 0.01 | 0.76 | 978 | 1015 | 6151 | 25 |
| g_base_shadowmap0 | 1920x1052 | 1.00 | High | 28.2 | 28.2 | 0.09 | 0.87 | 6.33 | 0.01 | 19.86 | 0.01 | 0.76 | 978 | 1015 | 6151 | 25 |
| g_base_shadowdist150 | 1920x1052 | 1.00 | High | 25.0 | 25.0 | 0.09 | 0.87 | 6.36 | 1.31 | 15.31 | 0.01 | 0.77 | 978 | 1015 | 6151 | 25 |
| g_base_shadowdist336 | 1920x1052 | 1.00 | High | 24.9 | 25.0 | 0.09 | 0.87 | 6.36 | 1.21 | 15.33 | 0.01 | 0.77 | 979 | 1016 | 6151 | 25 |
| g_base_shadowsoft0 | 1920x1052 | 1.00 | High | 24.8 | 24.9 | 0.09 | 0.87 | 6.36 | 1.17 | 15.31 | 0.01 | 0.77 | 980 | 1017 | 6151 | 25 |
| g_base_ssr0 | 1920x1052 | 1.00 | High | 24.6 | 24.7 | 0.09 | 0.87 | 6.37 | 1.16 | 15.13 | 0.01 | 0.77 | 979 | 1016 | 6151 | 25 |
| g_base_post0 | 1920x1052 | 1.00 | High | 24.4 | 24.5 | 0.09 | 0.86 | 6.37 | 1.15 | 15.51 | 0.01 | 0.14 | 978 | 1015 | 6151 | 25 |
| g_base_flora0 | 1920x1052 | 1.00 | High | 29.4 | 29.5 | 0.09 | 0.60 | 6.36 | 0.72 | 20.74 | 0.01 | 0.69 | 851 | 887 | 6145 | 24 |
| g_base_farbodies0 | 1920x1052 | 1.00 | High | 32.6 | 32.8 | 0.09 | 1.01 | 6.40 | 1.34 | 22.92 | 0.01 | 0.71 | 1098 | 1138 | 6467 | 29 |
| g_base_sea0 | 1920x1052 | 1.00 | High | 32.6 | 32.7 | 0.09 | 1.01 | 6.40 | 1.33 | 22.85 | 0.01 | 0.70 | 1096 | 1133 | 6481 | 24 |
| g_base_base0 | 1920x1052 | 1.00 | High | 30.0 | 30.0 | 0.09 | 0.91 | 6.36 | 1.30 | 20.32 | 0.01 | 0.69 | 1052 | 1088 | 6481 | 24 |
| g_base_scale05 | 1920x1052 | 0.50 | High | 13.1 | 13.4 | 0.09 | 0.81 | 1.64 | 1.29 | 8.88 | 0.01 | 0.41 | 1097 | 1133 | 6481 | 24 |
| g_base_look2 | 1920x1052 | 1.00 | High | 32.7 | 32.6 | 0.09 | 1.01 | 6.40 | 1.30 | 22.78 | 0.01 | 0.70 | 1097 | 1133 | 6481 | 24 |

#### B-spawn-user (load 1.52, 2.68, 4.21 before, 3.33, 3.33, 4.17 after)

| scenario | picture | scale | level | frame p50 | gpu ms | sky | prepass | matter/terrain | sun map | opaque+light | 2D light | post | draws | inst | chunks | props |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| g_spawn_look | 1920x1080 | 0.90 | Medium | 13.5 | 9.3 | 0.69 | 1.76 | 1.64 | 0.72 | 3.58 | 0.01 | 0.63 | 1091 | 1246 | 13540 | 98 |
| g_spawn_contact1 | 1920x1080 | 0.90 | Medium | 13.3 | 10.2 | 0.69 | 1.76 | 1.65 | 0.74 | 4.45 | 0.01 | 0.63 | 1091 | 1246 | 13540 | 98 |
| g_spawn_look2 | 1920x1080 | 0.90 | Medium | 13.4 | 9.4 | 0.70 | 1.77 | 1.65 | 0.76 | 3.59 | 0.01 | 0.63 | 1091 | 1246 | 13540 | 98 |
| g_spawn_shadows0 | 1920x1080 | 0.90 | Medium | 12.0 | 8.2 | 0.67 | 1.76 | 1.65 | 0.01 | 3.21 | 0.01 | 0.63 | 1091 | 1246 | 13540 | 98 |
| g_spawn_look3 | 1920x1080 | 0.90 | Medium | 13.3 | 9.4 | 0.69 | 1.76 | 1.65 | 0.79 | 3.58 | 0.01 | 0.63 | 1091 | 1246 | 13540 | 98 |
| g_spawn_shadowmap0 | 1920x1080 | 0.90 | Medium | 15.2 | 15.3 | 0.10 | 0.87 | 1.64 | 0.01 | 11.74 | 0.01 | 0.65 | 1091 | 1246 | 13540 | 98 |
| g_spawn_look4 | 1920x1080 | 0.90 | Medium | 13.3 | 9.4 | 0.69 | 1.77 | 1.65 | 0.81 | 3.56 | 0.01 | 0.63 | 1091 | 1246 | 13540 | 98 |
| g_spawn_shadowdist150 | 1920x1080 | 0.90 | Medium | 13.4 | 9.3 | 0.68 | 1.78 | 1.65 | 0.67 | 3.57 | 0.01 | 0.63 | 1091 | 1246 | 13540 | 98 |
| g_spawn_look5 | 1920x1080 | 0.90 | Medium | 13.4 | 9.4 | 0.69 | 1.78 | 1.65 | 0.81 | 3.58 | 0.01 | 0.63 | 1091 | 1251 | 13540 | 98 |
| g_spawn_flora0 | 1920x1080 | 0.90 | Medium | 13.4 | 7.9 | 0.70 | 1.71 | 1.65 | 0.81 | 2.15 | 0.01 | 0.62 | 1083 | 1164 | 13540 | 16 |
| g_spawn_look6 | 1920x1080 | 0.90 | Medium | 14.5 | 9.4 | 0.69 | 1.78 | 1.65 | 0.81 | 3.51 | 0.01 | 0.63 | 1091 | 1255 | 13540 | 103 |
| g_spawn_base0 | 1920x1080 | 0.90 | Medium | 13.2 | 9.2 | 0.68 | 1.69 | 1.65 | 0.78 | 3.45 | 0.01 | 0.63 | 1038 | 1202 | 13540 | 103 |
| g_spawn_look7 | 1920x1080 | 0.90 | Medium | 13.4 | 9.4 | 0.69 | 1.77 | 1.65 | 0.79 | 3.58 | 0.01 | 0.63 | 1094 | 1258 | 13540 | 103 |
| g_spawn_farbodies0 | 1920x1080 | 0.90 | Medium | 13.4 | 9.4 | 0.70 | 1.77 | 1.65 | 0.79 | 3.59 | 0.01 | 0.63 | 1093 | 1258 | 14061 | 103 |
| g_spawn_look8 | 1920x1080 | 0.90 | Medium | 13.2 | 9.4 | 0.70 | 1.78 | 1.65 | 0.78 | 3.61 | 0.01 | 0.63 | 1093 | 1258 | 14067 | 103 |
| g_spawn_sea0 | 1920x1080 | 0.90 | Medium | 12.3 | 9.2 | 0.65 | 1.77 | 1.65 | 0.77 | 3.61 | 0.01 | 0.63 | 1092 | 1258 | 14067 | 103 |
| g_spawn_look9 | 1920x1080 | 0.90 | Medium | 13.3 | 9.5 | 0.70 | 1.78 | 1.65 | 0.77 | 3.64 | 0.01 | 0.63 | 1093 | 1258 | 14067 | 103 |
| g_spawn_post0 | 1920x1080 | 0.90 | Medium | 12.8 | 8.8 | 0.54 | 1.77 | 1.65 | 0.76 | 3.65 | 0.01 | 0.17 | 1093 | 1258 | 14067 | 103 |
| g_spawn_look10 | 1920x1080 | 0.90 | Medium | 13.7 | 9.5 | 0.71 | 1.80 | 1.65 | 0.76 | 3.66 | 0.01 | 0.63 | 1093 | 1258 | 14067 | 103 |
| g_spawn_scale05 | 1920x1080 | 0.50 | Medium | 13.5 | 6.9 | 0.70 | 1.60 | 0.64 | 0.86 | 2.36 | 0.01 | 0.44 | 1093 | 1258 | 14067 | 103 |
| g_spawn_look11 | 1920x1080 | 0.90 | Medium | 13.3 | 9.5 | 0.69 | 1.79 | 1.65 | 0.75 | 3.69 | 0.01 | 0.63 | 1093 | 1258 | 14067 | 103 |

#### C-spawn-user-1440 (load 3.33, 3.33, 4.17 before, 3.86, 3.73, 4.23 after)

| scenario | picture | scale | level | frame p50 | gpu ms | sky | prepass | matter/terrain | sun map | opaque+light | 2D light | post | draws | inst | chunks | props |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| g_spawn_look | 1920x1080 | 0.90 | Medium | 13.1 | 7.7 | 0.67 | 1.62 | 1.65 | 0.71 | 2.18 | 0.01 | 0.62 | 1087 | 1163 | 13449 | 18 |
| g_spawn_scale05 | 1920x1080 | 0.50 | Medium | 13.0 | 6.6 | 0.68 | 1.59 | 0.74 | 0.94 | 1.86 | 0.01 | 0.48 | 1087 | 1163 | 13449 | 18 |
| g_spawn_look2 | 1920x1080 | 0.90 | Medium | 13.1 | 7.7 | 0.66 | 1.61 | 1.64 | 0.73 | 2.17 | 0.01 | 0.62 | 1087 | 1163 | 13449 | 18 |
| g_spawn_shadows0 | 1920x1080 | 0.90 | Medium | 11.9 | 6.8 | 0.66 | 1.61 | 1.65 | 0.01 | 1.99 | 0.01 | 0.62 | 1087 | 1163 | 13449 | 18 |
| g_spawn_look3 | 1920x1080 | 0.90 | Medium | 12.9 | 7.8 | 0.66 | 1.60 | 1.65 | 0.76 | 2.18 | 0.01 | 0.62 | 1087 | 1163 | 13449 | 18 |
| g_spawn_flora0 | 1920x1080 | 0.90 | Medium | 12.7 | 7.8 | 0.66 | 1.62 | 1.65 | 0.77 | 2.15 | 0.01 | 0.62 | 1083 | 1158 | 13449 | 16 |
| g_spawn_look4 | 1920x1080 | 0.90 | Medium | 14.4 | 9.2 | 0.68 | 1.72 | 1.65 | 0.79 | 3.49 | 0.01 | 0.63 | 1091 | 1249 | 13449 | 103 |

#### D-walk-high (load 3.86, 3.73, 4.23 before, 3.03, 3.79, 4.21 after)

| scenario | picture | scale | level | frame p50 | gpu ms | sky | prepass | matter/terrain | sun map | opaque+light | 2D light | post | draws | inst | chunks | props |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| g_walk100 |  | 0.00 |  | 26.6 | 26.7 | 0.09 | 0.61 | 6.36 | 0.66 | 18.01 | 0.01 | 0.69 | 788 | 822 | 2053 | 25 |
| g_at100_look | 1920x1052 | 1.00 | High | 29.3 | 29.3 | 0.09 | 0.67 | 6.37 | 0.72 | 20.48 | 0.01 | 0.69 | 909 | 945 | 6208 | 24 |
| g_at100_fogvol0 | 1920x1052 | 1.00 | High | 11.3 | 9.7 | 0.47 | 1.43 | 1.96 | 0.73 | 4.10 | 0.01 | 0.71 | 909 | 945 | 6208 | 24 |
| g_at100_look2 | 1920x1052 | 1.00 | High | 29.1 | 29.3 | 0.09 | 0.67 | 6.37 | 0.75 | 20.40 | 0.01 | 0.70 | 909 | 945 | 6208 | 24 |
| g_at100_fogsteps8 | 1920x1052 | 1.00 | High | 19.3 | 19.4 | 0.09 | 0.67 | 4.18 | 0.76 | 12.70 | 0.01 | 0.69 | 909 | 945 | 6208 | 24 |
| g_at100_look3 | 1920x1052 | 1.00 | High | 29.3 | 29.3 | 0.09 | 0.67 | 6.37 | 0.77 | 20.42 | 0.01 | 0.69 | 909 | 945 | 6208 | 24 |
| g_at100_flora0 | 1920x1052 | 1.00 | High | 29.2 | 29.3 | 0.09 | 0.67 | 6.37 | 0.78 | 20.40 | 0.01 | 0.69 | 910 | 946 | 6208 | 24 |
| g_at100_look4 | 1920x1052 | 1.00 | High | 29.4 | 29.4 | 0.09 | 0.67 | 6.37 | 0.80 | 20.47 | 0.01 | 0.69 | 913 | 969 | 6208 | 47 |
| g_at100_base0 | 1920x1052 | 1.00 | High | 20.5 | 20.5 | 0.09 | 0.53 | 6.39 | 0.78 | 11.73 | 0.01 | 0.68 | 865 | 901 | 6208 | 24 |
| g_at100_look5 | 1920x1052 | 1.00 | High | 29.3 | 29.4 | 0.09 | 0.67 | 6.39 | 0.81 | 20.42 | 0.01 | 0.69 | 910 | 946 | 6208 | 24 |
| g_at100_scale05 | 1920x1052 | 0.50 | High | 11.3 | 11.2 | 0.17 | 0.88 | 1.64 | 0.80 | 7.09 | 0.01 | 0.40 | 910 | 946 | 6208 | 24 |
| g_at100_look6 | 1920x1052 | 1.00 | High | 29.2 | 29.3 | 0.09 | 0.67 | 6.33 | 0.81 | 20.36 | 0.01 | 0.69 | 910 | 946 | 6208 | 25 |

#### E-rover-high (load 3.03, 3.79, 4.21 before, 3.46, 4.10, 4.30 after)

| scenario | picture | scale | level | frame p50 | gpu ms | sky | prepass | matter/terrain | sun map | opaque+light | 2D light | post | draws | inst | chunks | props |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| g_drive200 |  | 0.00 |  | 16.9 | 17.1 | 0.15 | 0.59 | 6.21 | 0.59 | 8.46 | 0.01 | 0.76 | 675 | 698 | 2196 | 33 |
| g_rover_look | 1920x1052 | 1.00 | High | 21.0 | 21.0 | 0.09 | 0.70 | 6.18 | 0.60 | 12.20 | 0.01 | 0.82 | 805 | 961 | 6890 | 180 |
| g_rover_fogvol0 | 1920x1052 | 1.00 | High | 13.5 | 8.5 | 0.50 | 1.45 | 1.96 | 0.57 | 2.69 | 0.01 | 0.89 | 805 | 961 | 6890 | 180 |
| g_rover_look2 | 1920x1052 | 1.00 | High | 21.0 | 21.0 | 0.09 | 0.70 | 6.19 | 0.59 | 12.20 | 0.01 | 0.83 | 805 | 961 | 6890 | 180 |
| g_rover_fogsteps8 | 1920x1052 | 1.00 | High | 14.4 | 14.5 | 0.09 | 0.70 | 4.04 | 0.59 | 7.94 | 0.01 | 0.83 | 805 | 961 | 6890 | 180 |
| g_rover_look3 | 1920x1052 | 1.00 | High | 21.0 | 21.0 | 0.09 | 0.70 | 6.19 | 0.59 | 12.21 | 0.01 | 0.82 | 805 | 961 | 6890 | 180 |
| g_rover_flora0 | 1920x1052 | 1.00 | High | 14.8 | 14.9 | 0.09 | 0.61 | 6.23 | 0.58 | 6.24 | 0.01 | 0.81 | 794 | 802 | 6890 | 23 |
| g_rover_look4 | 1920x1052 | 1.00 | High | 30.1 | 29.5 | 0.09 | 0.81 | 6.18 | 0.60 | 20.64 | 0.01 | 0.83 | 814 | 1115 | 6890 | 333 |
| g_rover_scale05 | 1920x1052 | 0.50 | High | 13.7 | 13.8 | 0.15 | 0.57 | 1.60 | 0.57 | 10.14 | 0.01 | 0.48 | 818 | 1141 | 6890 | 355 |
| g_rover_look5 | 1920x1052 | 1.00 | High | 40.4 | 40.5 | 0.09 | 0.81 | 6.18 | 0.59 | 31.65 | 0.01 | 0.82 | 819 | 1142 | 6890 | 355 |

#### F-rover-high2 (load 1.22, 2.70, 3.71 before, 3.12, 3.52, 3.91 after)

| scenario | picture | scale | level | frame p50 | gpu ms | sky | prepass | matter/terrain | sun map | opaque+light | 2D light | post | draws | inst | chunks | props |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| g_drive200 |  | 0.00 |  | 23.1 | 22.5 | 0.13 | 0.68 | 6.18 | 0.80 | 13.53 | 0.01 | 0.81 | 605 | 628 | 1600 | 32 |
| g_rover_look | 1920x1052 | 1.00 | High | 19.9 | 19.9 | 0.09 | 0.79 | 6.19 | 0.75 | 10.88 | 0.01 | 0.88 | 879 | 1006 | 7001 | 138 |
| g_rover_foglight0 | 1920x1052 | 1.00 | High | 13.5 | 12.5 | 0.47 | 1.50 | 3.39 | 0.74 | 5.13 | 0.01 | 0.88 | 879 | 1006 | 7001 | 138 |
| g_rover_look2 | 1920x1052 | 1.00 | High | 19.9 | 19.9 | 0.09 | 0.79 | 6.19 | 0.74 | 10.88 | 0.01 | 0.88 | 879 | 1006 | 7001 | 138 |
| g_rover_lights0 | 1920x1052 | 1.00 | High | 19.9 | 19.9 | 0.09 | 0.79 | 6.20 | 0.73 | 10.89 | 0.01 | 0.88 | 879 | 1006 | 7001 | 138 |
| g_rover_look3 | 1920x1052 | 1.00 | High | 19.9 | 19.9 | 0.09 | 0.79 | 6.19 | 0.73 | 10.89 | 0.01 | 0.88 | 879 | 1006 | 7001 | 138 |
| g_rover_fognoise0 | 1920x1052 | 1.00 | High | 17.6 | 17.6 | 0.09 | 0.79 | 5.19 | 0.72 | 9.63 | 0.01 | 0.88 | 879 | 1006 | 7001 | 138 |
| g_rover_look4 | 1920x1052 | 1.00 | High | 19.9 | 19.9 | 0.09 | 0.79 | 6.19 | 0.72 | 10.89 | 0.01 | 0.88 | 879 | 1006 | 7001 | 138 |
| g_rover_fogsteps12 | 1920x1052 | 1.00 | High | 17.0 | 17.0 | 0.09 | 0.79 | 5.13 | 0.72 | 9.06 | 0.01 | 0.88 | 879 | 1006 | 7001 | 138 |
| g_rover_look5 | 1920x1052 | 1.00 | High | 19.9 | 19.9 | 0.09 | 0.79 | 6.20 | 0.72 | 10.92 | 0.01 | 0.88 | 879 | 1006 | 7001 | 138 |
| g_rover_base0 | 1920x1052 | 1.00 | High | 19.9 | 19.9 | 0.09 | 0.79 | 6.20 | 0.71 | 10.93 | 0.01 | 0.88 | 879 | 1006 | 7001 | 138 |
| g_rover_look6 | 1920x1052 | 1.00 | High | 19.9 | 19.9 | 0.09 | 0.79 | 6.20 | 0.72 | 10.93 | 0.01 | 0.88 | 879 | 1006 | 7001 | 138 |
| g_rover_flora0 | 1920x1052 | 1.00 | High | 18.4 | 18.4 | 0.09 | 0.76 | 6.22 | 0.72 | 9.42 | 0.01 | 0.88 | 871 | 893 | 7001 | 26 |
| g_rover_look7 | 1920x1052 | 1.00 | High | 33.0 | 33.1 | 0.09 | 1.04 | 6.18 | 0.74 | 23.87 | 0.01 | 0.91 | 890 | 1234 | 7001 | 365 |

#### G-walk-high2 (load 3.12, 3.52, 3.91 before, 2.78, 3.45, 3.84 after)

| scenario | picture | scale | level | frame p50 | gpu ms | sky | prepass | matter/terrain | sun map | opaque+light | 2D light | post | draws | inst | chunks | props |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| g_walk100 |  | 0.00 |  | 27.3 | 27.4 | 0.09 | 0.58 | 6.36 | 0.63 | 18.78 | 0.01 | 0.69 | 671 | 706 | 1579 | 26 |
| g_at100_look | 1920x1052 | 1.00 | High | 30.0 | 30.0 | 0.09 | 0.64 | 6.36 | 0.69 | 21.17 | 0.01 | 0.69 | 860 | 900 | 5907 | 26 |
| g_at100_foglight0 | 1920x1052 | 1.00 | High | 15.9 | 16.0 | 0.09 | 0.65 | 3.42 | 0.71 | 10.07 | 0.01 | 0.70 | 860 | 900 | 5907 | 26 |
| g_at100_look2 | 1920x1052 | 1.00 | High | 29.9 | 29.9 | 0.09 | 0.65 | 6.37 | 0.72 | 21.10 | 0.01 | 0.69 | 860 | 900 | 5907 | 26 |
| g_at100_lights0 | 1920x1052 | 1.00 | High | 28.9 | 29.0 | 0.09 | 0.65 | 6.30 | 0.73 | 20.20 | 0.01 | 0.69 | 860 | 900 | 5907 | 26 |
| g_at100_look3 | 1920x1052 | 1.00 | High | 29.9 | 30.0 | 0.09 | 0.65 | 6.37 | 0.75 | 21.14 | 0.01 | 0.69 | 860 | 900 | 5907 | 26 |
| g_at100_fognoise0 | 1920x1052 | 1.00 | High | 25.3 | 25.3 | 0.09 | 0.64 | 5.33 | 0.76 | 17.49 | 0.01 | 0.69 | 860 | 900 | 5907 | 26 |
| g_at100_look4 | 1920x1052 | 1.00 | High | 29.9 | 30.0 | 0.09 | 0.65 | 6.36 | 0.77 | 21.10 | 0.01 | 0.69 | 860 | 900 | 5907 | 26 |
| g_at100_fogsteps12 | 1920x1052 | 1.00 | High | 25.0 | 25.1 | 0.09 | 0.65 | 5.26 | 0.78 | 17.27 | 0.01 | 0.70 | 860 | 902 | 5907 | 28 |
| g_at100_look5 | 1920x1052 | 1.00 | High | 30.0 | 30.1 | 0.09 | 0.65 | 6.37 | 0.80 | 21.14 | 0.01 | 0.70 | 860 | 902 | 5907 | 28 |
| g_at100_base0 | 1920x1052 | 1.00 | High | 20.9 | 21.0 | 0.09 | 0.49 | 6.35 | 0.78 | 12.29 | 0.01 | 0.68 | 815 | 857 | 5907 | 28 |
| g_at100_look6 | 1920x1052 | 1.00 | High | 30.0 | 30.1 | 0.09 | 0.64 | 6.37 | 0.80 | 21.18 | 0.01 | 0.69 | 860 | 902 | 5907 | 28 |
| g_at100_sea0 | 1920x1052 | 1.00 | High | 30.0 | 30.1 | 0.09 | 0.65 | 6.37 | 0.80 | 21.20 | 0.01 | 0.69 | 858 | 901 | 5907 | 28 |
| g_at100_look7 | 1920x1052 | 1.00 | High | 30.0 | 30.1 | 0.09 | 0.65 | 6.37 | 0.79 | 21.17 | 0.01 | 0.69 | 859 | 901 | 5907 | 28 |

#### H-spawn-user-1440 (load 2.78, 3.45, 3.84 before, 3.56, 3.71, 3.90 after)

| scenario | picture | scale | level | frame p50 | gpu ms | sky | prepass | matter/terrain | sun map | opaque+light | 2D light | post | draws | inst | chunks | props |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| g_spawn_look | 1920x1080 | 0.90 | Medium | 15.6 | 10.0 | 0.67 | 2.74 | 1.65 | 0.99 | 3.01 | 0.01 | 0.62 | 2067 | 2143 | 13370 | 18 |
| g_spawn_scale05 | 1920x1080 | 0.50 | Medium | 15.7 | 9.4 | 0.68 | 2.73 | 0.68 | 1.33 | 3.30 | 0.01 | 0.45 | 2067 | 2143 | 13370 | 18 |
| g_spawn_look2 | 1920x1080 | 0.90 | Medium | 15.9 | 10.0 | 0.68 | 2.75 | 1.65 | 1.01 | 3.02 | 0.01 | 0.62 | 2067 | 2143 | 13370 | 18 |
| g_spawn_shadows0 | 1920x1080 | 0.90 | Medium | 13.9 | 8.7 | 0.68 | 2.78 | 1.65 | 0.01 | 2.63 | 0.01 | 0.62 | 2067 | 2143 | 13370 | 18 |
| g_spawn_look3 | 1920x1080 | 0.90 | Medium | 16.2 | 10.1 | 0.69 | 2.75 | 1.65 | 1.03 | 3.04 | 0.01 | 0.62 | 2067 | 2143 | 13370 | 18 |
| g_spawn_contact1 | 1920x1080 | 0.90 | Medium | 15.7 | 10.4 | 0.67 | 2.73 | 1.65 | 1.04 | 3.36 | 0.01 | 0.62 | 2067 | 2143 | 13370 | 18 |
| g_spawn_look4 | 1920x1080 | 0.90 | Medium | 15.7 | 10.0 | 0.67 | 2.73 | 1.65 | 1.04 | 2.95 | 0.01 | 0.62 | 2067 | 2143 | 13370 | 18 |

#### I-walk-facilities (load 1.51, 2.95, 3.60 before, 2.86, 3.21, 3.62 after)

| scenario | picture | scale | level | frame p50 | gpu ms | sky | prepass | matter/terrain | sun map | opaque+light | 2D light | post | draws | inst | chunks | props |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| g_walk100 |  | 0.00 |  | 26.8 | 26.8 | 0.09 | 0.55 | 6.34 | 0.59 | 18.24 | 0.01 | 0.69 | 632 | 667 | 1600 | 25 |
| g_at100_look | 1920x1052 | 1.00 | High | 29.5 | 29.6 | 0.09 | 0.63 | 6.35 | 0.66 | 20.82 | 0.01 | 0.69 | 850 | 890 | 6015 | 24 |
| g_at100_hangar0 | 1920x1052 | 1.00 | High | 23.2 | 23.2 | 0.09 | 0.57 | 6.34 | 0.67 | 14.56 | 0.01 | 0.68 | 833 | 873 | 6015 | 24 |
| g_at100_look2 | 1920x1052 | 1.00 | High | 29.3 | 29.5 | 0.09 | 0.63 | 6.35 | 0.68 | 20.75 | 0.01 | 0.69 | 850 | 890 | 6015 | 24 |
| g_at100_interior0 | 1920x1052 | 1.00 | High | 26.3 | 26.4 | 0.09 | 0.56 | 6.36 | 0.65 | 17.70 | 0.01 | 0.68 | 768 | 808 | 6015 | 24 |
| g_at100_look3 | 1920x1052 | 1.00 | High | 29.4 | 29.5 | 0.09 | 0.63 | 6.36 | 0.69 | 20.74 | 0.01 | 0.70 | 850 | 890 | 6015 | 24 |
| g_at100_pad0 | 1920x1052 | 1.00 | High | 28.9 | 28.9 | 0.09 | 0.62 | 6.37 | 0.69 | 20.09 | 0.01 | 0.70 | 845 | 885 | 6015 | 24 |
| g_at100_look4 | 1920x1052 | 1.00 | High | 29.4 | 29.5 | 0.09 | 0.63 | 6.36 | 0.71 | 20.74 | 0.01 | 0.69 | 850 | 890 | 6015 | 24 |
| g_at100_flood0 | 1920x1052 | 1.00 | High | 29.5 | 29.5 | 0.09 | 0.63 | 6.36 | 0.72 | 20.69 | 0.01 | 0.69 | 850 | 890 | 6015 | 24 |
| g_at100_look5 | 1920x1052 | 1.00 | High | 29.5 | 29.5 | 0.09 | 0.63 | 6.36 | 0.72 | 20.71 | 0.01 | 0.70 | 850 | 890 | 6015 | 24 |
| g_at100_others0 | 1920x1052 | 1.00 | High | 28.5 | 28.6 | 0.09 | 0.60 | 6.36 | 0.71 | 19.79 | 0.01 | 0.69 | 827 | 867 | 6015 | 24 |
| g_at100_look6 | 1920x1052 | 1.00 | High | 29.5 | 29.6 | 0.09 | 0.63 | 6.37 | 0.73 | 20.75 | 0.01 | 0.69 | 850 | 890 | 6015 | 24 |
| g_at100_base0 | 1920x1052 | 1.00 | High | 20.1 | 20.3 | 0.09 | 0.53 | 6.36 | 0.71 | 11.61 | 0.01 | 0.67 | 805 | 845 | 6015 | 24 |
| g_at100_look7 | 1920x1052 | 1.00 | High | 29.6 | 29.6 | 0.09 | 0.63 | 6.37 | 0.72 | 20.79 | 0.01 | 0.69 | 849 | 891 | 6015 | 26 |

#### J-spawn-user-1440 (load 2.86, 3.21, 3.62 before, 3.64, 3.62, 3.73 after)

| scenario | picture | scale | level | frame p50 | gpu ms | sky | prepass | matter/terrain | sun map | opaque+light | 2D light | post | draws | inst | chunks | props |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| g_spawn_look | 1920x1080 | 0.90 | Medium | 12.9 | 7.7 | 0.66 | 1.60 | 1.65 | 0.71 | 2.18 | 0.01 | 0.62 | 1087 | 1163 | 13440 | 18 |
| g_spawn_scale05 | 1920x1080 | 0.50 | Medium | 13.2 | 6.5 | 0.68 | 1.57 | 0.74 | 0.94 | 1.85 | 0.01 | 0.48 | 1087 | 1163 | 13440 | 18 |
| g_spawn_look2 | 1920x1080 | 0.90 | Medium | 13.3 | 7.8 | 0.67 | 1.62 | 1.64 | 0.74 | 2.17 | 0.01 | 0.62 | 1087 | 1163 | 13440 | 18 |
| g_spawn_shadows0 | 1920x1080 | 0.90 | Medium | 12.3 | 6.9 | 0.69 | 1.64 | 1.65 | 0.01 | 1.99 | 0.01 | 0.62 | 1087 | 1163 | 13440 | 18 |
| g_spawn_look3 | 1920x1080 | 0.90 | Medium | 13.7 | 7.8 | 0.70 | 1.65 | 1.64 | 0.77 | 2.17 | 0.01 | 0.62 | 1087 | 1163 | 13440 | 18 |
| g_spawn_flora0 | 1920x1080 | 0.90 | Medium | 13.4 | 7.8 | 0.70 | 1.64 | 1.65 | 0.78 | 2.16 | 0.01 | 0.62 | 1083 | 1158 | 13440 | 16 |
| g_spawn_look4 | 1920x1080 | 0.90 | Medium | 14.6 | 9.3 | 0.69 | 1.72 | 1.65 | 0.80 | 3.49 | 0.01 | 0.63 | 1091 | 1249 | 13440 | 103 |

#### L-meadow-high (load 2.73, 4.06, 3.95 before, 2.80, 3.83, 3.91 after)

| scenario | picture | scale | level | frame p50 | gpu ms | sky | prepass | matter/terrain | sun map | opaque+light | 2D light | post | draws | inst | chunks | props |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| g_walk |  | 0.00 |  | 30.1 | 29.6 | 0.09 | 0.69 | 6.20 | 0.64 | 21.01 | 0.01 | 0.68 | 714 | 990 | 2339 | 271 |
| g_meadow_look | 1920x1052 | 1.00 | High | 29.9 | 29.8 | 0.09 | 0.69 | 6.19 | 0.66 | 21.21 | 0.01 | 0.69 | 746 | 1097 | 5751 | 357 |
| g_meadow_fogsteps12 | 1920x1052 | 1.00 | High | 24.7 | 24.7 | 0.09 | 0.69 | 5.11 | 0.66 | 17.18 | 0.01 | 0.69 | 746 | 1097 | 5751 | 357 |
| g_meadow_look2 | 1920x1052 | 1.00 | High | 29.8 | 29.8 | 0.09 | 0.69 | 6.19 | 0.67 | 21.16 | 0.01 | 0.69 | 746 | 1097 | 5751 | 357 |
| g_meadow_fogsteps8 | 1920x1052 | 1.00 | High | 19.3 | 19.4 | 0.09 | 0.69 | 4.04 | 0.68 | 12.88 | 0.01 | 0.69 | 746 | 1097 | 5751 | 357 |
| g_meadow_look3 | 1920x1052 | 1.00 | High | 29.7 | 29.7 | 0.09 | 0.69 | 6.19 | 0.69 | 21.09 | 0.01 | 0.69 | 746 | 1097 | 5751 | 357 |
| g_meadow_foglight0 | 1920x1052 | 1.00 | High | 16.0 | 16.1 | 0.09 | 0.69 | 3.36 | 0.69 | 10.23 | 0.01 | 0.69 | 746 | 1097 | 5751 | 357 |
| g_meadow_look4 | 1920x1052 | 1.00 | High | 29.8 | 29.8 | 0.09 | 0.69 | 6.19 | 0.70 | 21.09 | 0.01 | 0.69 | 746 | 1097 | 5751 | 357 |
| g_meadow_fognoise0 | 1920x1052 | 1.00 | High | 25.1 | 25.1 | 0.09 | 0.69 | 5.19 | 0.70 | 17.43 | 0.01 | 0.69 | 746 | 1097 | 5751 | 357 |
| g_meadow_look5 | 1920x1052 | 1.00 | High | 29.7 | 29.7 | 0.09 | 0.69 | 6.19 | 0.71 | 21.07 | 0.01 | 0.69 | 746 | 1097 | 5751 | 357 |
| g_meadow_scale05 | 1920x1052 | 0.50 | High | 11.7 | 11.9 | 0.13 | 0.55 | 1.60 | 0.70 | 8.23 | 0.01 | 0.41 | 746 | 1097 | 5751 | 357 |
| g_meadow_look6 | 1920x1052 | 1.00 | High | 29.7 | 29.7 | 0.09 | 0.69 | 6.19 | 0.72 | 21.04 | 0.01 | 0.68 | 746 | 1097 | 5751 | 357 |
| g_meadow_flora0 | 1920x1052 | 1.00 | High | 17.5 | 17.6 | 0.09 | 0.54 | 6.25 | 0.71 | 9.02 | 0.01 | 0.67 | 727 | 762 | 5751 | 26 |
| g_meadow_look7 | 1920x1052 | 1.00 | High | 30.2 | 30.3 | 0.09 | 0.74 | 6.21 | 0.74 | 21.47 | 0.01 | 0.69 | 747 | 1060 | 5751 | 321 |

#### N-after-meadow — after the change (load 1.98, 4.01, 4.08 before, 3.68, 4.26, 4.18 after)

| scenario | picture | scale | level | frame p50 | gpu ms | sky | prepass | matter/terrain | sun map | opaque+light | 2D light | post | draws | inst | chunks | props |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| g_walk |  | 0.00 |  | 25.0 | 24.7 | 0.09 | 0.74 | 5.14 | 0.58 | 17.19 | 0.01 | 0.68 | 731 | 1003 | 3052 | 269 |
| g_meadow_look | 1920x1052 | 1.00 | High | 24.5 | 24.6 | 0.09 | 0.72 | 5.13 | 0.59 | 17.04 | 0.01 | 0.69 | 745 | 1093 | 6015 | 358 |
| g_meadow_fogsteps8 | 1920x1052 | 1.00 | High | 19.3 | 19.3 | 0.09 | 0.72 | 4.06 | 0.60 | 12.84 | 0.01 | 0.69 | 745 | 1093 | 6015 | 358 |
| g_meadow_look2 | 1920x1052 | 1.00 | High | 24.5 | 24.6 | 0.09 | 0.72 | 5.13 | 0.61 | 17.01 | 0.01 | 0.69 | 745 | 1093 | 6015 | 358 |

#### N-after-base — after the change (load 3.54, 4.22, 4.17 before, 5.37, 4.72, 4.35 after)

| scenario | picture | scale | level | frame p50 | gpu ms | sky | prepass | matter/terrain | sun map | opaque+light | 2D light | post | draws | inst | chunks | props |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| g_base_look | 1920x1052 | 1.00 | High | 19.4 | 19.5 | 0.10 | 0.77 | 5.25 | 0.86 | 11.44 | 0.01 | 0.75 | 957 | 993 | 6207 | 24 |

#### N-after-rover — after the change (load 5.37, 4.72, 4.35 before, 6.86, 5.63, 4.72 after)

| scenario | picture | scale | level | frame p50 | gpu ms | sky | prepass | matter/terrain | sun map | opaque+light | 2D light | post | draws | inst | chunks | props |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| g_drive200 |  | 0.00 |  | 15.8 | 15.0 | 0.26 | 0.81 | 5.11 | 0.61 | 7.06 | 0.01 | 0.76 | 683 | 706 | 2258 | 32 |
| g_rover_look | 1920x1052 | 1.00 | High | 18.2 | 18.3 | 0.09 | 0.70 | 5.10 | 0.57 | 10.60 | 0.01 | 0.83 | 806 | 970 | 6882 | 190 |
