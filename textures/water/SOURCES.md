# textures/water — where these came from

| File | Source | Licence |
|---|---|---|
| `river_ripples.png` | generated (2026-10-20) for `shaders/river.flsl`: a tileable 512² ripple HEIGHT map (grey), a sum of 90 periodic waves with integer wave numbers 3–22 per tile (so it tiles exactly), amplitude ∝ 1/k^0.9, crests sharpened by `s + 0.25 s²`, numpy seed 1187, normalised to 0–255. The shader reads it three times a phase for the slope, so it is used as heights, not as a normal map (the colour space it is sampled in does not matter). | made for Solar |
