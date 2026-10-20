# textures/vfx — where these came from

Built by `tools/gen_vfx_textures.py` (2026-10-01). Every file is RGBA, straight
alpha, so it works on Alpha and Additive tracks alike.

| Folder / file | Source | Licence |
|---|---|---|
| `smoke/puff_a,b,c.png`, `smoke/soot.png` | Kenney "Smoke Particles" pack (`smokeParticleAssets.zip`, whitePuff03/10/17, blackSmoke08), resized | CC0 (Kenney, kenney.nl) |
| `glow/aura.png` | hackcraft.de lens-flare set (`flare_20120324.zip`, aura.png), luminance → alpha | CC0 (hackcraft.de) |
| `smoke/clump_a,b.png`, `smoke/soft.png`, `glow/flash.png`, `glow/star.png`, `glow/streak.png`, `spark/burst.png`, `debris/spray.png`, `ring/smoke.png` | "masks for particles" pack (`masks_for_particles.zip`: 42, 43, 50, 10, 34, 8, 13, 25, 30), luminance → alpha | added to the project by Ty; no licence file in the pack |
| `fire/fireball_a,b.png` | Solar's own `textures/VFXTEX/Fire/3.png`, `5.png`, luminance → alpha | as `textures/VFXTEX` |
| `fire/fireball_c.png`, `smoke/wisp.png`, `water/splat_a,b.png`, `water/foam.png`, `leaf/leaf.png`, `decal/crater.png` | Floptle-jam-release `assets/textures/VFXTEX` (Fire/7, Fire/4, Water/2, 4, 8, Wind/5, Debris/16) | Ty's own Floptle project; that set has no licence file |
| everything else (`distort/haze.png`, `beam/*`, `glow/soft,tight,core,haze`, `spark/dot,streak`, `smoke/billow_a,b`, `ring/dust,shock`, `debris/grit,chip_a,chip_b`, `decal/scorch*,molten`, `water/droplet,bubble`, `fire/tongue`) | generated procedurally by the script (value-noise fBm, gradients) | made for Solar |

The three packs were unzipped in full, the useful realistic textures taken, and
the zips removed. Left out on purpose: the cartoon "Fart"/"Explosion" puffs, the
magic-circle, hexagon, star, lightning and rune masks, and the flare set's
geometric shapes.

Also found but NOT copied: realistic 8×8 smoke/explosion flipbooks
(NatureManufacture), the Unity Particle Pack and "Bullet Impact FX" in the Unity
repos under GithubRepositories. They are Unity Asset Store content (Standard
EULA: fine inside a shipped game, not as raw files in a public repo), and Solar's
repo is public.
