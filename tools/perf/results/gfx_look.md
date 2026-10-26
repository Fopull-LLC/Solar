# The lens look: sun flare, bloom, far-field blur (2026-10-26, engine 0.117.0-rc33)

Probe: `tools/perf/gfx.sh` + `gfxprobe.lua` (a copy of the player's save, 1920×1052
window, XWayland, vsync off; each scene shot with the OLD look and the NEW one in
one run). Machine load was high throughout (load average 14–146; other agents and
cargo builds), so whole-frame totals drift by several ms between samples. The
`post` pass is the stable number, and it is the only pass these changes touch.

## What changed

- **Bloom**: threshold 1.0 → 1.6, intensity 0.25 → 0.35 (all levels; Low 0.30).
  The bright-pass is a hard luminance threshold in linear light. At 1.0 sunlit
  pale ground and walls passed it and the day wore a milky haze; at 1.6 only
  emitters (the star, the tools' energy parts, lamps, exhaust) glow. Free (post
  0.47 → 0.48 ms).
- **Sun flare** (`shaders/sunFlare.flsl`, a screen pass on the Post Processing
  node, driven by `scripts/sun_flare.lua`): glare, six diffraction rays and a
  ghost chain. Occlusion comes from the frame's depth (9 taps over the disc), so
  terrain, buildings and the planet hide it. Its colour and strength follow the
  airmass (it goes orange, red and weak toward the horizon) and the weather's
  cloud cover. It is stronger in vacuum: more glare, longer rays, brighter ghosts.
  Medium and up; off at Low; the "Sun lens flare" setting.
- **Far-field depth of field** (graphics.lua): the focus is `25 m × shadowScale +
  1.2 × altitude` (65 m on a 935 m world), the far range is 2.5× the focus, and
  the near range is 1e6, so nothing in front of the focus ever blurs. Max blur
  is 1.75 px (Medium, 8 taps), 2.25 px (High, 12 taps) or 2.5 px (Ultra, 16
  taps), scaled to the picture height. It fades out in thin air and at night, and
  is off in the map view. In the VAB the focus follows `builder_camera.dist`. The
  "Distance blur" setting turns it off.
- **Medium upscale sharpening**: 0.4 → 0.25. It was sharpening the speckle.

## The "grain at distance"

The far ground shows a per-pixel speckle from about 40 m out. It does not change
with AO off, the fog dither off, upscale sharpening off, or render scale 1.0. Two
consecutive frames of a still camera are identical (mean difference 0.13/255), so
the speckle is spatial aliasing, and it crawls whenever the camera moves.

**Cause (engine):** the terrain palette texture array has one mip level
(`floptle-render/src/raymarch.rs` `make_terrain_array`, `mip_level_count: 1`).
A palette texture without an import setting defaults to Pixelated (nearest).
Solar's 32 terrain textures were not in `.floptle/textures.ron`. The engine has
no AA pass (no MSAA, FXAA or TAA).

High also shows a faint diagonal hatch in the sky from the volumetric fog
march. It stays with the fog dither off. The far blur removes it.

Grain metric: the standard deviation of a 4-neighbour Laplacian over the far
ground, crop (1250,690)–(1650,820). Lower is smoother.

| | old | new | new + linear terrain filter |
|---|---|---|---|
| Medium | 45.0 | 38.9 | 34.8 (r4) |
| High | 31.8 | 25.9 | 22.2 (r4) |

## GPU cost (post pass, ms, 1920×1052)

Medium renders at scale 0.9; High at 1.0. Clean samples only.

| | old | bloom only | + far blur | + flare | new (all) |
|---|---|---|---|---|---|
| Medium | 0.47–0.48 | 0.47–0.50 | 0.61–0.62 (+0.14) | 0.60 (+0.13) | 0.74–0.75 (**+0.27**) |
| High | 0.46–0.47 | 0.47–0.49 | 0.71–0.74 (+0.25) | 0.62–0.63 (+0.15) | 0.86–0.89 (**+0.40**) |

The whole-frame totals for old and new interleave within noise: Medium 6.4–6.6
vs 6.4–6.9, High 12.4–12.7 vs 12.8–13.0.
