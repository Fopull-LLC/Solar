# Realistic water for Solar on Floptle: research, audit and design

*2026-10-20. Research only: no Solar or engine files were changed. Engine state audited at Floptle `754f4970` (v0.117.0-rc2). Solar state is the working tree on `main`.*

## 0. TL;DR

- **Recommendation: three layers.** The industry pattern (Unreal Water, Crest, Sea of Thieves, Cities: Skylines, Timberborn) separates the water into three layers:
  1. **Where water is (level layer).** The levels of settled seas and lakes come from `lake_levels`. This layer costs nothing per frame.
  2. **How water moves (sim layer).** The 0417 virtual-pipes step runs only where something happens: rivers near the player, breaches and digs.
  3. **How the surface looks up close (detail layer).** Analytic waves, flow-advected normals, ripples and foam in the shader. These are never simulated.
  Physics and rendering read the same first two layers. Physics also evaluates the cheap analytic waves of layer 3 so that boats bob in step with what the player sees.
- **Waves on Solar planets are small, and that is physically correct.** A sea on a 600–950 m planet is at most a few km across. JONSWAP fetch-limited growth then gives a significant wave height of about 0.2–0.5 m and wavelengths of 3–10 m, even in a 10 m/s wind (§1.1). So FFT cascades are not needed. A sum of 8–16 Gerstner waves on a dense near-field mesh is both realistic and cheap. FFT stays an optional later upgrade, for storms only.
- **The biggest visual gap is refraction and real reflection.** In Floptle a surface material cannot read the scene colour today: `sceneColor` exists only in `stage post`. The water fakes transmission with alpha blending. The best interim fix needs no engine work: a **post-process sea**. It ray-casts the sea sphere (and lake spheres) analytically in a `stage post` shader, which already has `sceneColor`, `sceneDepth`, `sceneRay` and `cameraPosition`. The Sebastian Lague-style planet ocean works this way. It gives true refraction, exact Beer–Lambert depth colour and underwater fog in one full-screen pass (≈0.2–0.4 ms).
- **The biggest simulation gap is rivers.** Steady river flow never sleeps in the current step, because cells sleep only when the flux is about zero. So the step needs **steady-state sleep**, **analytic seeding** (Manning's equation from the generator's river network), **weir-limited flow at drops** (which also handles waterfalls), and **flow velocity** read from the pipe fluxes.
- **Engine asks**, split into five cards (§6):
  - (a) Water-surface physics and `water.addVolume`/heightfield buoyancy plus `water.flowAt`.
  - (b) Rivers and sim residency.
  - (c) An engine-drawn water surface mesh from the sim, with LOD.
  - (d) FLSL for transparent surfaces: `sceneColor`/`sceneDepth` in the fragment stage, sky radiance, texture fetch in `output offset`, an extra vertex channel.
  - (e) A shared wave spectrum, splashes, ripples and underwater rendering.

## 1. State of the art (summary; sources in §8)

### 1.1 Ocean waves
- **Tessendorf FFT** [S1]. Synthesise a height field (plus horizontal "choppy" displacement) from a statistical spectrum (Phillips, or JONSWAP [S5]) with an inverse FFT each frame. Typical tiles are 256²–512². Big titles layer 3–4 **cascades** (bands of wavelengths with different tile sizes) so that tiling doesn't show. Atlas uses 4 bands, each faded out after ~30 of its own periods from the camera. Arc Blanc uses 3 cascades at 256². Crest renders each wavelength into the LOD that matches it [S3, S6, S9]. Atlas measured **0.5 ms** for its wind waves at max quality (Radeon VII / RTX 2080). NVIDIA's OceanCS calls three 512² IFFTs "trivial time" and warns that grids above 1024² show FP32 artifacts [S3, S8]. The **Jacobian of the horizontal displacement** gives whitecap foam where the surface folds.
- **Gerstner / trochoidal sums** [S2, GPU Gems ch.1]. N directional waves with a closed-form position *and* normal. They are cheap, deterministic and trivially queryable on the CPU for buoyancy. Unreal's Water plugin ships Gerstner as its only built-in wave model, including a "Spectrum" variant that picks its waves from an oceanographic spectrum [S10]. Their weakness is visible repetition with fewer than about 8 waves. Fix it with direction and wavelength spread, and add fbm or normal-map detail on top.
- **Determinism.** Atlas computes its waves from absolute time and the spectrum parameters alone, so servers and clients agree on the ocean without syncing it [S3]. Floptle's rollback needs exactly this property.
- **Spectrum sizing.** Atlas uses dual fetch-limited JONSWAP (wind sea + swell) [S3]. Horvath 2015 adds TMA (JONSWAP corrected for finite depth, which suits shallow seas) [S5]. Fetch-limited JONSWAP gives `g·Hs/U² = 1.6e-3·(gF/U²)^½` and `g·Tp/U = 0.286·(gF/U²)^⅓` [S5]. For U = 10 m/s, F = 2 km and g = 9.81 the result is Hs ≈ 0.23 m and Tp ≈ 1.7 s, so the deep-water wavelength is ≈ 4.5 m. Solar's seas really should look like a choppy lake, not the Atlantic. Wind comes from `weather.windAt` (0418, live). The formulas also scale with each planet's surface gravity, so low-g worlds get longer, slower and taller waves for free.
- **Spheres.** On a planet, planar waves `sin(k·dot(d, p))` evaluated on the sphere work locally, because the wavelength is much smaller than R. They fail where `d` is parallel to the local up. Fixes:
  - Evaluate waves in the tangent frame of a camera-centred patch, or fade each wave by `1 − |dot(d, up)|`.
  - Proland [S4] (Bruneton/Neyret/Holzschuch, "Real-time realistic ocean lighting using seamless transitions from geometry to BRDF") evaluates the waves in a camera-local frame on the sphere. It then converts sub-pixel waves into a BRDF (a filtered normal distribution) so that the sea from orbit shows a correctly widened sunglint. Solar's `farFade` is a hand-tuned version of this.

### 1.2 Surface meshing and LOD
- **Projected grid** [S11]. A screen-space grid is projected onto the water plane each frame. It needs no LOD bookkeeping, but it aliases in the distance, leaves gaps at the screen edges and swims as the camera moves [S8]. On a sphere it also needs a ray–sphere projection. Good for a pure ocean; poor for lakes and rivers.
- **Geometry clipmaps / CDLOD** [S12, S13]. Nested rings or a quadtree of fixed-size patches centred on the camera, with vertex morphing between levels so they don't pop. Crest's "CDClipmaps" are camera-centred rings that morph CDLOD-style. Its "LOD data" lives in viewer-centred cascaded textures, all the same size (e.g. 256²), each level 2× the last, the whole chain rescaled with viewer altitude: displacement, foam, dynamic waves, sea-floor depth, flow [S6]. Unreal shares one quadtree tile mesh between all water bodies, with rings that halve in density, plus a **WaterInfoTexture** (water Z and ground Z, captured top-down) for depth shading [S10]. On a sphere the standard approach is a **cube-sphere quadtree**: the same cube map the 0417 grid already uses.
- **Local sim-surface meshes** (Unreal water bodies, Cities: Skylines, Timberborn) are a mesh per water chunk, displaced by a height texture from the sim [S10, S20, S22].

### 1.3 Shading (with typical cost)
| Feature | Technique | Cost |
|---|---|---|
| Fresnel | Schlick, F0 = 0.02 | ~free |
| Sky reflection | Sample the sky/atmosphere radiance or a cubemap along `reflect(v, n)` | ~free once the sky is sampleable |
| Local reflection | SSR on the depth buffer (falls back to the sky) or a planar mirror camera (an extra scene render, so roughly 1.5–2× the frame) | SSR 0.3–1 ms |
| Refraction | Copy the opaque colour after the opaque pass and sample it at a uv offset by the normal. Re-check the depth at the offset uv to reject foreground leaks. Unreal's Single Layer Water does this, with per-RGB absorption and scattering coefficients, after lighting and before translucency [S26] | one copy ~0.1–0.2 ms + 1 tap |
| Depth colour | Beer–Lambert per channel, `T = exp(−σ_rgb · thickness)`, with thickness = the view-ray length through the water (scene depth − surface depth). Red dies first, giving turquoise shallows and navy deeps | 1 depth tap |
| Subsurface / "glow" | Approximation: wave height × a sun-behind-the-wave term + a view term + bubble density (Atlas). Sea of Thieves blends to an SSS colour with a wave-peak mask taken from the choppy offsets, because light travels a shorter path through crests [S3, S7] | ~free |
| Foam | (1) Shoreline: `saturate(1 − thickness/w)`. (2) Crest: the Jacobian, or Gerstner `J = 1 − Σ Qᵢkᵢaᵢ sin(·)`. (3) Persistent foam: "turbulent energy" injected where J crosses a threshold, then blurred and faded each frame (Atlas), or a depth-compare foam buffer around objects with feedback blur (Sea of Thieves) [S3, S7]. (4) Wakes | 1–2 texture taps |
| Microfacet water BRDF | Beckmann + Smith + Schlick. Reflection weighted by F, body light by (1−F). Raise roughness with foam [S3]; filter far waves into roughness [S4] | ~free |
| Caustics | Projected animated texture or worley pattern on the underwater ground, attenuated with depth (GPU Gems ch.2 traces from wave normals) [S31] | ~0.1 ms |
| Underwater | Fog by Beer–Lambert on the scene depth, a waterline split, refraction of the surface from below (total internal reflection outside Snell's window) | 1 post pass |

### 1.4 Rivers and flowing water
- **Flow maps** (Vlachos, "Water Flow in Portal 2", SIGGRAPH 2010) [S14]. A 2D flow vector per texel (painted at ~4 texels/m in L4D2 and Portal 2) or per vertex. The normal map is scrolled along it in **two phases offset by half a period** and cross-faded with a triangle weight. That hides the stretching when the pattern resets. A noise texture offsets the phase per pixel to hide pulsing. The cost is 2 extra fetches. Uncharted 3 used a bulk-flow field and a flow shader on meshes [S30].
- **Height-field shallow water / virtual pipes** [S15, S16]. O'Brien & Hodgins 1995, then Mei, Decaudin & Hu 2007 on the GPU. A pipe between each pair of neighbouring cells carries a flux driven by their height difference, and each cell's outflow is scaled so it never goes negative. Velocity comes from the averaged pipe fluxes divided by the depth and width. This is exactly what 0417 implemented. Sea of Thieves uses Mei's pipes for streams, waterfalls and water on deck, with the camera depth projected in so characters block the flow [S7].
- **Beyond pipes:**
  - Chentanez & Müller 2010 [S17] is a GPU shallow-water solver on any terrain, with wet/dry tracking. Breaking waves and waterfalls turn into spray and splash particles that exchange mass with the height field.
  - Their 2011 restricted tall-cell grid [S32] is real-time 3D Eulerian liquid. That is overkill for Solar.
  - Jeschke et al. 2023 [S33] simulate the bulk shallow flow and the surface waves separately: the same split recommended here.
- **Games:**
  - **From Dust** (Ronan Bel, GDC Europe 2010) simulated water, lava, erosion and sediment over the *whole* world every frame, at constant cost. It used SIMD, was multithreaded and held 30 fps on 360/PS3. They added "mud" because pure water carved rivers too deep and too angular [S19].
  - **Cities: Skylines** has a "dynamic water system" in which rivers carry mass and direction and pollution flows downstream. The source is a secondary report of the dev diary [S20].
  - **Timberborn** adapted Mei's virtual pipes per tile. Current is derived from flux compared across ticks. The water ticks every couple of hundred ms and rendering interpolates between ticks. Moisture spreads to the ground nearby [S22]. This tick-plus-interpolate model is the one recommended in §3.2.
  - **Unreal** has spline water bodies (ocean, lake, river), a WaterInfoTexture and a Shallow Water subsystem with velocity render targets [S10].
- **Waterfalls.** Where flow leaves a ledge, games switch representation. Horizon Forbidden West baked Houdini sims into flipbook deformation volumes (128 layers) for waterfall impacts and river standing waves [S23]. Chentanez & Müller emit particles from the sim [S17]. The common cheap form is a mesh sheet with a scrolling texture plus mist and foam particles at the impact. In the height-field sim, flow over a step is bounded by the **weir/critical-flow limit** `q ≤ √g·h^{3/2}`, which also keeps the step stable.
- **Wetness.** Darken and raise the smoothness of terrain within a band above the waterline, and let it fade as water recedes (0418's wetness and a dried-shore timer).

### 1.5 Interaction
- **Buoyancy** from height queries at sample points on the hull. The rule is that **the query must match the render**.
  - **Kerner (Just Cause 3)** clips the hull triangles against the water height field and integrates hydrostatic pressure. Part 2 adds viscous and pressure drag and a **slamming** force [S24].
  - **Crest** answers queries asynchronously through GPU readback, a couple of frames late, and drops wavelengths shorter than the object can feel [S21].
  - **Atlas** undoes FFT horizontal displacement with a fixed-point iteration (`D = disp(P − D)`). Raw per-sample forces were too noisy, so it fits a plane to the samples and springs the ship toward it [S3].
  - Gerstner sums avoid all of this, because the CPU evaluates the same closed form.
- **Ripples, wakes and splashes.** A local wave-equation height field: Hugo Elias's two-buffer `new = Σnbrs/2 − old`, damped by 0.94–0.99 [S27]. Or Tessendorf's iWave, with correct dispersion and obstacles [S18]. Atlas's eWave wakes cost 0.6–0.8 ms [S3]. Wave particles and water-surface wavelets cover large domains without a grid [S34]. Any of these is driven by bodies that cross the surface. A splash is a particle burst, plus a foam decal and a sound, emitted when the submerged volume changes fast. Kelvin wakes come from a foam trail or decal.

### 1.6 What planet games and engines do
- **Proland** (Bruneton) is the closest prior art for a planet: a spherical ocean, viewer-centred LOD, and waves that move from geometry to normals to BRDF [S4].
- **No Man's Sky** rebuilt its water on a mesh in Worlds Part I (2024), with waves and foam that respond to local weather and depth. Worlds Part II added cloud and planet reflections and stronger SSS. Both come from patch notes; there is no technical talk [S28].
- **Space Engineers 2** plans planetary-scale *volumetric* water with oceans, rivers, lakes and submarines (roadmap "VS3"). The April 2026 diary shows flow through a 25 cm hole. It is unreleased and its algorithm is undisclosed [S29].
- **Sea of Thieves** and **Atlas** use FFT oceans, with pipes or eWave for local effects [S3, S7].
- **Horizon Forbidden West** bakes its breaking waves and waterfalls [S23].
- **From Dust**, **Timberborn** and **Cities: Skylines** have real flow sims, all on flat maps [S19, S22, S20].
- **Sebastian Lague's** planet video draws its ocean as a post-process that ray-intersects a sphere [S25, details unverified].
- **Not verified, so not cited:** the internals of KSP1, KSP2, Outer Wilds (Giant's Deep), Teardown, Astroneer and Dual Universe. The research found no primary technical source for any of them.

No shipped title we could find combines all three of these: a dynamic flow sim, spherical worlds and digging. Space Engineers 2 is aiming at that. That makes the three-layer split (static level, sparse sim, analytic detail) the safe design.

## 2. Floptle audit (what exists, v0.117.0-rc2)

### 2.1 Simulation (`crates/floptle-field/src/water.rs`, 598 lines)
- `WaterGrid::sphere(n, radius, ground)` is a cube map with neighbours carried across face edges. `WaterGrid::flat` is the rectangular version.
- `lake_levels(grid, sea)` uses a priority flood to fill every basin to its spill height.
- `ShallowWater` is the virtual pipes model: mass-exact transfers, `damping`, an awake list, sleep after `SLEEP_STEPS` still steps, and `wake(c)`/`wake_all()`. A sleeping cell standing above an awake neighbour joins in, so a dig wakes the lake. `stable_dt` returns a CFL-limited step. The guards (basin stays put, breach conserves mass, dug hole fills, cross-face crater) are unit tests.
- Bench (`examples/water_bench.rs`): a 400 m planet at 2 m cells (~500k cells) costs 0 ms settled and 0.08 ms per step after a shore dig.
- **Limits found:**
  1. Cells sleep only when every flux is below `STILL`. **A steady river never sleeps**, so 20 rivers would keep every river cell awake forever.
  2. The grid is **dense**. Each cell carries `ground, area, nbr[4], dist[4], width[4], depth, flux[4], awake, calm, dv`, about 86 B. A 950 m planet at 2 m cells is 2.8M cells (≈240 MB); at 1 m it is ≈1 GB. It needs sparse tiles, or a coarse grid plus local fine tiles.
  3. There are no sources or sinks: no springs, no rain, no sea boundary condition.
  4. Velocity is never computed.
  5. Flux over a cliff is unbounded by any weir limit. The only bound is the CFL `dt`, and `stable_dt` "needs asking again" when water deepens.
  6. **None of it is reachable from Lua.** Only `terrain.planetLakes` is.
- `terrain.planetRivers(opts)` (generator) returns river polylines with widths; `terrain.planetLakes(opts, {cell, minDepth, seaLevel})` returns `{level, center, reach, area, depth}`.

### 2.2 Physics and queries (`crates/floptle-physics/src/water.rs`, `floptle-script/src/water_api.rs`)
- `WaterShape` is either `Sphere {center, radius}` or `Box {center, half, rot}`. Buoyancy is computed per shape, at each shape's own position, so the torque rights a hull. Drag is quadratic, there is angular drag, and a `frozen` flag turns the sea into ice.
- Lua: `water.at / depthAt / isUnderwater / setFrozen / volumes`.
- **Missing:**
  - a heightfield or mesh shape (lakes cannot float things);
  - a time-varying surface (waves);
  - water velocity (currents);
  - `water.addVolume` from script (0417's open sub-item).
- Volumes are static by design, for deterministic rollback. A wave function of time is still deterministic if it is a pure function of `(p, t)`.

### 2.3 Rendering and FLSL (`floptle-shader`, `docs/subsystems/shaders.md`)
| Capability | Status | Notes |
|---|---|---|
| Alpha-blended surface material | **yes** (`blend alpha`) | WaterVolume reaches the blended pass (water_probe). Materials can carry a shader (0144 done) |
| Vertex displacement | **yes**: `output offset` | Per vertex, procedural only. **No texture sampling in the offset**, and no `fieldDistance`/`surfaceGap`. Lighting uses the *unmoved* normal, so recompute it in the fragment stage. The depth prepass and the sun shadow follow the moved surface |
| Inputs | `uv, normal, worldPos, objectPos, viewDir, time, instanceColor, lightDir, lightColor` | **No vertex colour or second UV**. `mesh.build` accepts `colors`, but FLSL cannot read them |
| Depth behind the surface | **yes**: `surfaceGap(p)` | World distance from the surface to the opaque depth-prepass surface behind it along the view ray: the view-ray water thickness. Only at this pixel, not at an offset uv |
| Distance to terrain SDF | **yes**: `fieldDistance(p)` | ≈ vertical depth over the terrain |
| Scene colour (refraction) | **post only** | `sceneColor(uv)` in `stage post`. A surface material cannot refract |
| Scene depth, ray, camera | **post only** | `sceneDepth(uv)`, `sceneRay(uv)`, `cameraPosition()`, `sceneNormal(uv)` |
| Sky or environment sample | **no op** | `litPbr` does reflect the engine sky internally, but there is no `skyRadiance(dir)` op. Solar fakes it with a horizon/zenith gradient |
| Lighting helpers | `litPbr`, `litSurface(albedo, n)`, `sunShadow`, `applyFog`, `refract`, `reflect`, derivatives | |
| Textures | `sample`, `sampleTriplanar`, up to 8 slots per material | `assets.textureFromPixels(w, h, rgba)` lets Lua bake flow, foam and depth maps at runtime |
| Render targets | **yes**: `setCamera{target=…}` → `rt:name` | A planar reflection is possible but is a full extra render (see docs/render-targets.md) |
| Post stack | **yes**: an ordered list of `stage post` passes | Runs after DoF, before the grade. Depth is opaque-only, so it sees the ground *under* transparent water |
| Compute | **hand-written engine passes only** | No user compute. Renderer docs mention compute displacement buffers as a pattern |
| Runtime meshes | `mesh.build` / `mesh.free`, up to ~1M triangles | No in-place update (rebuild and free). Uploaded next frame |
| Particles | `particles:play/stop/setIntensity/setTint`; prefabs | Enough for splashes, mist and waterfalls |
| Wind | `weather.windAt` (0418) | Drives wave amplitude and direction |

### 2.4 Solar today
- `shaders/ocean.flsl` (alpha, on a 10,242-vertex icosphere; edge ≈ 0.034·R ≈ 28 m at R = 800 m) already has:
  - fbm normal waves;
  - Schlick Fresnel;
  - a sky gradient reflection and sun glint;
  - a `farFade` BRDF-ish transition;
  - depth colour by `surfaceGap` (a single `mix`, not per channel);
  - shoreline surf bands from `fieldDistance`;
  - a feathered waterline;
  - an underside view.
  Its header says "FLSL has no vertex stage". **That is out of date**: `output offset` now exists.
- `shaders/river.flsl` (new, untracked) puts scrolled noise streaks along `uv.y` (metres downstream) and builds a cotangent frame from derivatives.
- `scripts/climate.lua` builds lake sheets (a flood-filled lattice at spill level) and river ribbons with `mesh.build`. Swim depth uses its own `lakeDepth`. **There is no buoyancy in lakes.**

## 3. Design: the simulation (engine)

### 3.1 Layers and residency
1. **Level layer (always resident, ~free).**
   - Per planet, a cube-map grid of *surface levels* at a coarse resolution: 4 m on a 950 m planet is 700k cells. It stores only `ground` and `surface` as f16/f32, ≈5 MB.
   - It is seeded from `lake_levels` plus the sea level, and from the **analytic steady state of the rivers** (§3.2).
   - Physics, rendering and Lua read this layer when no sim tile is resident.
   - A body's frame is the planet's own frame, so rails and rotation are just a transform.
2. **Sim layer (sparse, on demand).**
   - **Tiles** of e.g. 32×32 cells at **1–2 m**. They are allocated only where water is *wet or can become wet* and something is happening:
     - within ~300 m of the player (or of any loaded physics bubble, see 0421);
     - at a terrain edit;
     - at a breach;
     - on a river reach that has been woken.
   - The **sea is a boundary condition**: a fixed-level reservoir cell, not simulated cells. Only the coastal band is simulated.
   - A tile is initialised from the level layer and written back to it when it falls asleep and is evicted. Mass is carried across the write-back, so the change in a lake's volume persists.
3. **Detail layer (visual, analytic).** Waves, flow normals, ripples and foam (§4). Physics also evaluates the waves (§5).

### 3.2 Rivers: sources, steady state and sleep
- **Sources and sinks.**
  - A river head from `planetRivers` becomes a **spring** with a discharge Q (m³/s). Q comes from the river's catchment, or the generator sets it from the width: rule of thumb `Q ≈ 0.5·w·h·v`.
  - The sea is the sink.
  - Optional rain (0418 precipitation) adds to every cell. It is mass-tracked so the totals still balance.
- **Analytic seeding.** For each river segment, solve **Manning's equation** for normal depth: `h = (Q·n / (w·√S))^{3/5}` with `n ≈ 0.035`, S the bed slope and w the bed width. Then `v = Q/(w·h)`. Write `surface = bed + h` into the level layer. A fresh world therefore starts with flowing rivers at the right depth, and nothing floods on frame one (the 0417 guard "seeded state stays put" extends to rivers).
- **Steady-state sleep (the key change).**
  - A cell whose depth changed by less than ε over K steps sleeps **with its flux frozen**.
  - It keeps passing `flux·dt` to its downstream neighbour each step, as a constant transfer list with no solve.
  - If even that is too costly, the tile drops to "rails" mode: the level layer plus a cached velocity.
  - It wakes when a neighbour's surface changes by more than `LEVEL`, or on an edit.
  - Without this, 20 rivers × ~3,000 cells is 60k cells stepped forever.
- **Velocity.**
  - Per cell, `u = ½(F_right_out − F_left_in − F_left_out + F_right_in) / (w·h̄)` along each axis [S16].
  - It is exposed as `water.flowAt(p)` and in the level layer, as a cached steady velocity.
  - It also feeds the renderer as the flow map (§4.3).
- **Drops and waterfalls.**
  - Clamp the pipe flux by the weir limit `F ≤ C·w·√(2g)·h_up^{3/2}` when the downstream ground is lower than the upstream surface. This keeps cliffs stable at the river's `dt`.
  - Mark the pipe as a **fall** when the ground drop is more than about 1.5 m over one cell. Expose the falls (`water.falls()` → position, direction, width, discharge, drop) so the renderer or Solar can place a fall sheet and mist.
- **Terrain edits.**
  - `terrain.dig`/`fill` already queue edits and report `terrain.yields()`. The engine should, in the same edit application, re-sample the `ground` of the affected cells, allocate a tile if needed and call `wake` on them.
  - A dig into a dry hill wakes nothing, because there is no water to move. A dig at a shore or riverbank drains into the hole, which is the existing test.
  - Large digs that open a new basin below the sea level flood from the sea boundary.
- **Stability and dt.** Use a fixed water tick (e.g. 10–20 Hz) with substeps chosen by `stable_dt`, independent of the render frame rate. Pipes on 2 m cells with h ≤ 3 m give `dt ≈ 0.09 s`, so 1–2 substeps per 10 Hz tick.

### 3.3 Budget estimate
- An active tile area of ~300 m radius at 2 m cells is ≈70k cells at the very most, but typically only a few thousand are awake (a river reach plus a dig). The existing step measured 0.08 ms for a shore dig. Expect ≈0.05–0.3 ms per tick on a worker. Over a 10–20 Hz tick that averages under 0.1 ms per frame, well inside 0417's 1 ms main-thread budget.
- The level layer costs nothing per frame. Writing back an evicted tile is O(tile).
- Memory: the level layer ≈5–10 MB per loaded planet, and ≈90 B × 1024 cells ≈ 90 KB per sim tile, with ~50 tiles resident (≈5 MB).

## 4. Design: surface mesh, LOD and shading

### 4.1 Mesh
- **Far (beyond ~2 km, or from orbit):** the existing sea sphere with BRDF-filtered glint (`farFade`). Lakes from orbit are a cheap flat disc or a sphere cap. Waves are fully faded.
- **Near:** the **engine builds water surface patches from the level and sim layers** on the same cube-sphere quadtree as the 0417 grid:
  - CDLOD-style patches of 32×32 quads, with geomorph between levels and **skirts** that tuck under the terrain at the shoreline;
  - vertex height = surface level (bilinear), plus the analytic waves in the shader;
  - vertices exist only where `surface > ground − margin`, so each lake and river is its own patch set and the empty land costs nothing;
  - per-vertex attributes for the shader: flow velocity (2), depth (1), foam/turbulence (1) and fall/shore flags.
- **Rivers:** they are just the same patches with velocity. Splined ribbons (Solar's current approach) are a fine fallback where the sim is coarser than the river.

### 4.2 Shading features, ordered by look per cost
| # | Feature | Needs | Est. GPU cost (1440p, water fills half the screen) | Look gain |
|---|---|---|---|---|
| 1 | Refraction through the scene-colour copy + per-channel Beer–Lambert by the true thickness | `sceneColor`/`sceneDepth(uv)` in the fragment stage | 0.1–0.2 ms copy + 2 taps | **Very high**: the bottom is seen bent through the water, true clarity |
| 2 | Real sky and atmosphere reflection (and clouds) | `skyRadiance(dir)` / env probe op | ~free | **High**: the water matches the sky at every hour and on every planet |
| 3 | Geometric waves (Gerstner, wind-driven) on the near mesh + analytic normal + whitecaps from J | `output offset` (have) + a dense mesh | <0.1 ms | **High**: a moving silhouette and horizon |
| 4 | Flow-mapped normals (2-phase) + flow foam + rapids on steep slope | velocity per vertex or as a texture | 2–4 taps | **High on rivers** |
| 5 | Shoreline foam and swash, wet-sand band | have (`surfaceGap`, `fieldDistance`) | ~free | Medium (largely done) |
| 6 | Subsurface crest glow | analytic | ~free | Medium |
| 7 | SSR for terrain and craft in the water | engine op `ssr(dir)` | 0.3–1 ms | Medium (sky reflection covers most of it) |
| 8 | Caustics under shallow water + underwater fog / waterline | post pass | 0.1–0.3 ms | Medium–high when swimming |
| 9 | Ripples, wakes and splash foam | local wave-eq texture + particles | 0.1 ms | Medium |
| 10 | FFT cascades | compute | 0.3–0.6 ms | Low on Solar (seas are small). Storms only |

## 5. Design: interaction
- **Buoyancy and swimming.**
  - Add `WaterShape::Surface { body, tile/level layer }`. Its `depth_at(p)` is the bilinear level/sim surface in the body frame, minus the height of p along the radial up. `up_at` is radial. `water.at` / `depthAt` / `isUnderwater` / per-shape buoyancy therefore all read the simulated surface.
  - A sea stays a `Sphere` plus waves.
  - Optional **wave function** per volume: the same Gerstner set (amplitude, wavelength, direction, steepness, from wind) evaluated on the CPU as a pure function of `(p, t)`. That keeps rollback deterministic, so a craft bobs in step with the rendered surface (Unreal and Crest do this).
  - Keep the amplitudes small near shore; shoaling attenuation is `tanh(k·depth)`.
- **Currents.** Drag acts on `v_body − v_water(p)`, so a river pushes swimmers and craft downstream and a waterfall pulls them over the edge.
- **Splashes.**
  - The solver already knows each shape's submersion per step. When `d(submersion)/dt × area × speed` exceeds a threshold, emit `water.onSplash{pos, speed, mass, normal}` (or a query `water.splashes()`) for particles, a foam decal and audio.
  - The same event injects a ripple impulse.
- **Crafts landing in water.**
  - Quadratic drag already makes a gentle splashdown float and a 60 m/s impact stop hard.
  - Add a **slamming** impulse (water-entry pressure ∝ ρ·v²·A at first contact) so a high-speed impact can destroy parts (KSP-like), plus a big splash event.
  - Parachute splashdowns then just work.
- **Swimming.** `isUnderwater` on the simulated surface, plus an underwater camera mode: fog, colour absorption, a waterline split, muffled audio (already in `soundscape.lua`).

## 6. Engine work for E: proposed acceptance criteria

These can go onto 0417 as sub-items, or 0417 can be split into five cards.

### 0417a: water surface physics and script access
- [ ] `water.addVolume{shape = "heightfield"|"mesh"|"surface", body = node, level =, cells/points =, density =, drag =}` returns an id; `water.removeVolume(id)`. A Solar lake built from `planetLakes` floats a crate and lets a crew swim, and `water.at` agrees with the drawn lake within 5 cm.
- [ ] A `Surface` volume reads the 0417 sim/level layer. `water.at/depthAt/isUnderwater` and per-shape buoyancy follow a lake that drains after a breach: a floating crate settles onto the lake bed as the lake empties.
- [ ] `water.flowAt(p)` → a velocity vec3 in the world frame. Drag uses the velocity relative to the water, so a 1 kg crate in a 1 m/s river reaches ≥0.8 m/s downstream within 5 s.
- [ ] All of it works on a rotating, on-rails planet, in the body frame. Determinism and rollback are unchanged (the surface is a pure function of the sim state).

### 0417b: rivers and sim residency
- [ ] River heads from `planetRivers` are springs with a discharge. A fresh world starts with rivers at the Manning normal depth, and the first 60 s of sim change no river surface by more than 10 cm (seeded steady state).
- [ ] Steady-state sleep: a planet with 20 flowing rivers and the player idle steps no more than 2,000 cells per tick, and costs ≤0.2 ms per frame averaged.
- [ ] Sparse residency: a 950 m planet at 2 m sim cells keeps ≤32 MB of water state resident. Tiles allocate around the player and around edits and evict to the level layer with mass conserved (≤0.1%).
- [ ] The sea is a fixed-level boundary: a trench dug from the beach inland below sea level fills from the sea and stays full.
- [ ] Terrain edits wake the water automatically (no script call). Digging a channel from a lake shore to a lower valley creates a flowing stream, and the lake level drops until it reaches the channel floor. Mass is conserved within 1%.
- [ ] Weir-limited flow over drops, and `water.falls()` → `{pos, dir, width, discharge, drop}` for every drop over 1.5 m. A 10 m cliff in a river step is stable at the default dt.
- [ ] Water state persists in the save as a diff from the seeded state.
- [ ] Guard: 0417's existing guards, plus "a river seeded steady stays steady", "flow velocity matches Q/(w·h) within 15% on a straight test channel", and "a planet with 20 rivers stays under budget" in the release bench.

### 0417c: water surface rendering (engine mesh)
- [ ] Near-field water patches are generated from the level/sim layer on a cube-sphere quadtree (CDLOD/geomorph, no cracks, skirts at shores) and drawn with a user FLSL material. Lakes and rivers need no script-built meshes.
- [ ] Per-vertex `waterFlow` (vec2, tangent-space m/s), `waterDepth` and `waterFoam` reach FLSL as inputs.
- [ ] The far sea sphere and the near patches meet without a visible seam at any altitude from the surface to orbit.
- [ ] Waterfalls: each `falls()` entry gets a fall sheet (mesh with flow uv) plus a mist/foam particle emitter, and both hide when the fall dries up.
- [ ] Budget: water geometry ≤0.3 ms GPU, ≤150k vertices, and ≤0.1 ms CPU per frame for patch updates.

### 0417d (new card): FLSL for transparent surfaces
- [ ] `sceneColor(uv?)` and `sceneDepth(uv?)` are available in the **fragment** stage of `blend alpha` materials. They read a copy of the opaque HDR scene taken after the opaque pass, which is made only when a visible material uses them. A probe shows a stick bent at the waterline.
- [ ] `skyRadiance(dir)` (the engine sky, atmosphere and clouds as rendered) in the fragment stage.
- [ ] `sample()` allowed in `output offset` (vertex texture fetch), so a height or displacement texture can move a mesh.
- [ ] `vertexColor` (vec4) and/or `uv2` inputs from `mesh.build{colors=}`, so script meshes can carry flow, depth and foam.
- [ ] Optional: `ssr(dir, maxDist)` returning `vec4` (rgb, confidence).
- [ ] Cost probe: refraction copy ≤0.2 ms at 1440p on the reference GPU.

### 0417e (new card): waves, ripples, splashes and underwater
- [ ] `water.setWaves(volume, {wind = vec3 | auto, fetch =, gravity = auto, count = 8..16, seed =})`. A Gerstner set sized by JONSWAP fetch-limited formulas. The same function drives the renderer (a uniform block FLSL can read: `waveDisplace(p)`, `waveNormal(p)`) and the physics queries. `weather.windAt` drives it when `wind = auto`.
- [ ] A float on a 0.5 m swell bobs in phase with the rendered surface within one frame.
- [ ] `water.onSplash` / `water.splashes()` events when a body enters or leaves the water fast, with position, speed and mass. A water-entry slamming impulse is applied.
- [ ] A local ripple field around the camera (wave equation, ~256² over 64 m) is excited by bodies crossing the surface and readable by the water shader.
- [ ] An underwater camera mode: Beer–Lambert fog in the water's colour, a waterline split when the camera straddles the surface, Snell's window from below, and caustics on the lit ground under shallow water. Each can be toggled.

## 7. What Solar can do now (interim, no engine changes)

Ordered by look gain per effort. Effort assumes one focused session each. These should be coordinated with the agent now working on lake rendering.

| # | Change | How with today's features | Look gain | Cost |
|---|---|---|---|---|
| 1 | **Post-process sea and lakes (refraction + true depth colour + underwater)** | A `stage post` shader. Lua pushes `planetCentre − camera` (vec3), the sea radius and up to ~8 lakes (centre dir, level radius, reach) as uniforms. Per pixel: ray–sphere intersect against the sea radius. If the hit is nearer than `sceneDepth()`, the pixel is water. Thickness = `sceneDepth − tHit`. Refract by offsetting the uv with the wave normal, re-checking `sceneDepth(uv')` > tHit to reject foreground leaks. Colour = `sceneColor(uv')·exp(−σ_rgb·thickness)` + in-scatter + Fresnel·sky + glint + foam. For lakes, accept the hit only if within `reach` of the lake centre and the ground behind is below the level. The sea mesh then draws only from orbit (or not at all), and ocean.flsl's look moves into this pass. When the camera is under the sea radius, the same pass does underwater fog. This is the planet-ocean technique popularised by Sebastian Lague [S25]. | **Very high** (refraction, crisp depth colour, underwater for free) | 0.2–0.4 ms GPU; 1–2 days. Risks: the order with atmosphere, cloud and particle passes (post runs before the grade, after everything else), so apply the planet's fog in the pass. Transparent things in front of the water (particles, glass) are drawn over again by the water. Waves are normals only. |
| 2 | **Gerstner geometry on a near-field sea patch** | Build a spherical-cap mesh once with `mesh.build`: a radial grid around +Y, dense at the centre, ~150×150 vertices, ~500 m reach. Parent it to the body and rotate it so its centre sits under the eye; rebuild or re-aim it when the eye moves more than 50 m. Pass the cap's orientation as vec3 uniforms so the shader evaluates the waves in **planet** coordinates (no swimming). `output offset` = a sum of 8 Gerstner waves (amplitude from `weather.windAt` and fetch, ≤0.3 m). The fragment stage recomputes the analytic Gerstner normal at the unmoved `objectPos` (the offset does not relight). Bake per-vertex **water depth into `uv.x`** and the edge fade into `uv.y` in Lua when building (the offset can read `uv`), so the waves die in the shallows and at the cap edge. The far icosphere stays as it is, faded where the cap covers it. Physics stays flat, which is acceptable at ≤0.3 m. | **High** (a moving silhouette and horizon chop) | <0.1 ms GPU; the Lua build is ~10–30 ms, spread over frames; 1–2 days |
| 3 | **Per-channel Beer–Lambert + in-scatter in ocean.flsl / river.flsl** | Replace `mix(shallow, deep, 1 − exp(−gap/clarity))` with `T = exp(−gap·σ_rgb)` (σ per water chemistry, e.g. `(0.45, 0.09, 0.06)/m` clear ocean). colour = `bottomProxy·T + inscatter·(1 − T)`, with alpha = `1 − avg(T)·k`. Use `fieldDistance` for the vertical depth and `surfaceGap` for the view-ray thickness. | Medium | ~free; hours |
| 4 | **Wind-coupled waves and whitecaps** | `ocean.lua` samples `weather.windAt` at the eye and sets `waveScale`, `waveSpeed`, direction and a `whitecap` threshold. Foam where the Gerstner Jacobian `J < threshold`, in the fragment stage. | Medium | ~free; hours |
| 5 | **River flow advection done properly** | In `river.flsl` replace noise streaks with **two-phase flow-map advection** of a tileable normal texture (`sample`, slot 0). Make the scroll speed physical by building **`uv.y` as travel time** (Σ segment length / local speed from Manning, with slope from the bed polyline) instead of metres. A pattern at `uv.y − time` then moves at the local speed everywhere. The speed is recoverable in the fragment stage as `|d(dist)| / |d(uv.y)|` via derivatives, which drives rapids foam and bump strength where the river is fast. | High on rivers | ~free; ~1 day |
| 6 | **Waterfalls and rapids dressing** | In `climate.lua`, where the river polyline's bed drops more than ~1.5 m between points, build a vertical sheet (mesh.build, flow uv) with the river shader (a high flow speed and foam), plus a mist/spray particle prefab at the bottom (`particles:play`). Foam rings where rivers enter lakes and the sea. | High at those spots | Low GPU; ~1 day |
| 7 | **Shoreline wetness** | The terrain shader is the engine's, so do it in the post pass of #1: darken and add spec to ground pixels whose height above the sea/lake level is in [0, band], with a tide/swash wobble. Optionally do the same with 0418 wetness once it ships. | Medium | in #1's pass |
| 8 | **Caustics** | In the post pass of #1: for the ground under water (thickness > 0), add an animated worley/caustic pattern on world position (planet-local coordinates), scaled by sun·T(depth) and faded beyond ~4 m. | Medium (shallows, swimming) | in #1's pass |
| 9 | **Lake buoyancy stopgap** | Until `water.addVolume` exists: a pool **box** WaterVolume prefab per nearby lake (top = level, footprint = the lake's reach), spawned and despawned with the lake mesh. Wrong only where lower ground lies inside the box outside the basin. The `lakeDepth` swim check stays as the cross-check. | Gameplay (floats, splashes) | Low |
| 10 | **Splashes** | `vessel_controller`/`planet_walker` already know `water.at` per frame: on a fast transition (depth crosses 0 with \|v·up\| > 3 m/s), play a splash particle prefab and an SFX at the contact, scaled by speed. | Medium | Low |

Fix ocean.flsl's header comment: it says FLSL has no vertex stage, but `output offset` now exists.

Suggested order: **3 → 4 → 5 → 2 → 1 (with 7, 8) → 6 → 10 → 9**. Steps 3–5 are low-risk shader edits. Step 2 gives geometry. Step 1 is the big visual step but changes the rendering architecture of the sea, so prototype it next to the current sea before switching. Step 9 overlaps the agent doing lakes.

### Performance targets (Solar on the reference machine)
- **Water GPU total:** ≤1.5 ms at 1440p with the sea filling the screen. Post-sea 0.3 ms, near patch 0.1 ms, rivers and lakes 0.2 ms, particles 0.2 ms, with headroom.
- **Water CPU:**
  - Lua water bookkeeping ≤0.3 ms per frame;
  - mesh rebuilds amortised to ≤2 ms in any one frame;
  - the engine sim ≤1 ms main thread (0417), with a target of ≤0.2 ms average.
- **Memory:** ≤40 MB of water state per loaded planet.

## 8. Sources
A research pass opened the primary sources. Full-text extracts of the Atlas, Sea of Thieves, Horizon FW, Vlachos, OceanCS and Arc Blanc PDFs are in `/tmp/claude-1000/-mnt-disks-3tb-GithubRepositories-Solar/691876cc-b436-4042-bbe1-a2851d281671/scratchpad/dl/`. Entries marked *(unverified)* were not opened.

- **S1** Tessendorf, *Simulating Ocean Water*: https://jtessen.people.clemson.edu/reports/papers_files/coursenotes2004.pdf
- **S2** Finch, *Effective Water Simulation from Physical Models*, GPU Gems 1 ch.1: https://developer.nvidia.com/gpugems/gpugems/part-i-natural-effects/chapter-1-effective-water-simulation-physical-models
- **S3** *Interactive Water Simulation in Atlas*, GDC 2019 (Grapeshot / NVIDIA WaveWorks 2): https://gpuopen.com/gdc-presentations/2019/gdc-2019-agtd6-interactive-water-simulation-in-atlas.pdf (also https://gdcvault.com/play/1025819/Advanced-Graphics-Techniques-Tutorial-Wakes)
- **S4** Bruneton, Neyret, Holzschuch, *Real-time Realistic Ocean Lighting using Seamless Transitions from Geometry to BRDF*, 2010:
  - https://evasion.inrialpes.fr/Publications/2010/BNH10
  - Proland spherical ocean: https://proland.inrialpes.fr/doc/proland-4.0/ocean/html/page-examples.html
- **S5** Horvath, *Empirical Directional Wave Spectra for Computer Graphics*, DigiPro 2015: https://doi.org/10.1145/2791261.2791267 (PDF not opened). JONSWAP fetch-limited growth relations are standard oceanography (Hasselmann et al. 1973), applied as in Atlas [S3]. The worked numbers in §1.1 are mine.
- **S6** Crest:
  - https://github.com/ivdstudios/crest-oceanrender
  - https://crest.readthedocs.io/en/4.20.1/user/system-notes.html
- **S7** Ang, *The Technical Art of Sea of Thieves*, SIGGRAPH 2018: https://history.siggraph.org/wp-content/uploads/2022/09/2018-Talks-Ang_The-Technical-Art-of-Sea-of-Thieves.pdf
- **S8** NVIDIA OceanCS slides: https://developer.download.nvidia.com/assets/gamedev/files/sdk/11/OceanCS_Slides.pdf
- **S9** Arc Blanc, 2025: https://arxiv.org/pdf/2503.03326
- **S10** Unreal Water:
  - meshing: https://dev.epicgames.com/documentation/en-us/unreal-engine/water-meshing-system-and-surface-rendering-in-unreal-engine
  - waves: https://dev.epicgames.com/documentation/unreal-engine/simulating-waves-using-the-water-waves-asset-in-unreal-engine
  - bodies: https://dev.epicgames.com/documentation/unreal-engine/water-body-actors-in-unreal-engine
  - shallow water: https://dev.epicgames.com/documentation/en-us/unreal-engine/python-api/class/ShallowWaterSubsystem
- **S11** Johanson, *Real-time water rendering: projected grid*, 2004: https://fileadmin.cs.lth.se/graphics/theses/projects/projgrid/
- **S12** Losasso & Hoppe, *Geometry Clipmaps*, 2004: https://hhoppe.com/proj/geomclipmap/. GPU Gems 2 ch.2: https://developer.nvidia.com/gpugems/gpugems2/part-i-geometric-complexity/chapter-2-terrain-rendering-using-gpu-based-geometry
- **S13** Strugar, *CDLOD*, 2010 (primary not reached; described via Crest's CDClipmaps [S6]) *(unverified)*
- **S14** Vlachos, *Water Flow in Portal 2*, SIGGRAPH 2010: https://www.advances.realtimerendering.com/s2010/Vlachos-Waterflow(SIGGRAPH%202010%20Advanced%20RealTime%20Rendering%20Course).pdf
- **S15** O'Brien & Hodgins, *Dynamic Simulation of Splashing Fluids*, 1995: https://arxiv.org/pdf/2302.06087
- **S16** Mei, Decaudin, Hu, *Fast Hydraulic Erosion Simulation and Visualization on GPU*, PG 2007: https://hgpu.org/?p=2256
- **S17** Chentanez & Müller, *Real-time Simulation of Large Bodies of Water with Small Scale Details*, SCA 2010: https://diglib.eg.org/items/d0320015-4b07-416b-8f41-047485c9f7f3
- **S18** Tessendorf, *Interactive Water Surfaces* (iWave), GPG4: https://jtessen.people.clemson.edu/reports/papers_files/Interactive_Water_Surfaces.pdf
- **S19** Bel, *Creating a High-Performance Simulation* (From Dust), GDC Europe 2010:
  - https://gdcvault.com/play/1013667/Creating-a-High-Performance-Simulation
  - https://history.siggraph.org/learning/developing-the-interactive-dynamic-natural-world-of-from-dust-by-bel-and-vimont/
- **S20** Cities: Skylines water (secondary report): https://www.dsogaming.com/news/cities-skylines-final-dev-diary-focuses-on-in-game-tools/
- **S21** Crest collision and buoyancy queries: https://crest.readthedocs.io/en/4.23.0/user/collision-shape-and-buoyancy-physics.html
- **S22** *Deep dive: Timberborn's water mechanics*: https://www.gamedeveloper.com/design/deep-dive-timberborn-s-water-mechanics
- **S23** Malan, *Horizon Forbidden West water*, SIGGRAPH 2022 Advances: https://advances.realtimerendering.com/s2022/SIGGRAPH2022-Advances-Water-Malan.pdf
- **S24** Kerner, *Water interaction model for boats in video games* (parts 1 and 2):
  - https://gamedeveloper.com/programming/water-interaction-model-for-boats-in-video-games
  - https://www.gamedeveloper.com/programming/water-interaction-model-for-boats-in-video-games-part-2
- **S25** Sebastian Lague, *Coding Adventure: Procedural Moons and Planets*, 2020 (YouTube) *(details unverified)*
- **S26** Unreal *Single Layer Water* shading model: https://dev.epicgames.com/documentation/en-us/unreal-engine/single-layer-water-shading-model-in-unreal-engine
- **S27** Hugo Elias, *2D water*: https://web.archive.org/web/20160418004149/http://freespace.virgin.net/hugo.elias/graphics/x_water.htm
- **S28** No Man's Sky Worlds Part I and II water (patch-note coverage):
  - https://www.thesixthaxis.com/2024/07/17/no-mans-sky-worlds-part-i-update-adds-major-world-improvements/
  - https://www.psu.com/news/no-mans-sky-worlds-part-ii-update-revealed-adds-new-biomes-terrains-lighting-system/
- **S29** Space Engineers 2:
  - roadmap: https://2.spaceengineersgame.com/roadmap/
  - dev diary: https://blog.marekrosa.org/2026/04/mareks-dev-diary-april-30-2026/
- **S30** Gonzalez-Ochoa, *Water Technology of Uncharted*, GDC 2012: https://gdcvault.com/play/1015309/Water-Technology-of
- **S31** Guardado & Sánchez-Crespo, *Rendering Water Caustics*, GPU Gems 1 ch.2: https://developer.nvidia.com/gpugems/gpugems/part-i-natural-effects/chapter-2-rendering-water-caustics
- **S32** Chentanez & Müller, *Real-time Eulerian Water Simulation Using a Restricted Tall Cell Grid*, 2011: https://doi.org/10.1145/2010324.1964977
- **S33** Jeschke et al., *Hybrid shallow water + surface waves*, NVIDIA 2023: https://research.nvidia.com/labs/prl/shallow-water-simulation
- **S34** Wave particles: http://www.cemyuksel.com/research/waveparticles/. Water Surface Wavelets: https://visualcomputing.ist.ac.at/publications/2018/WSW/

Engine files audited (read-only):
- `Floptle/crates/floptle-field/src/water.rs`
- `crates/floptle-physics/src/water.rs`
- `crates/floptle-script/src/{water_api,terrain_api,mesh_api,texture_api}.rs`
- `crates/floptle-shader/src/{stdlib,ir,text}.rs`
- `crates/floptle-render/src/field.wgsl` (`flsl_surface_gap`)
- `docs/subsystems/{shaders,post-processing,renderer}.md`
- `docs/render-targets.md`
- `docs/planet-generator.md`
- card 0417
