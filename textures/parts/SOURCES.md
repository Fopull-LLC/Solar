# textures/parts — sources

Every image in this folder is **generated**, by `tools/gen_part_textures.py`
(numpy + Pillow, fixed seeds — rerun it and you get the same bytes). No
photograph, scan, asset-store pack or third-party texture went into any of them.

| file | what it is | made from |
|---|---|---|
| `paint_*` | white-painted aluminium skin, 1 m tile: staggered panels, bevelled seams, rivet rows, screwed hatches, streaked grime, paint chips | spectral noise, drawn seams/domes |
| `metal_*` | brushed bare alloy, 0.5 m tile, seams and hex bolts (tinted in a material for dark/anodised parts) | anisotropic noise, drawn bolts |
| `tiles_*` | black thermal-protection tiles with gap filler | drawn grid, noise |
| `ablative_*` | charred honeycomb heat-shield | drawn hex cells, noise |
| `bell_*` | engine nozzle: cooling tubes, heat-tint bands, dark throat (not tiled along its length) | drawn ridges, colour ramp, noise |
| `foil_*` | gold multi-layer insulation with a tape seam | ridged noise |
| `solar_*` | photovoltaic cells, busbars, fingers | drawn |
| `tread_*` | diamond tread plate, 0.5 m tile: raised lozenges, polished tops, grime between | drawn lozenge field, noise |
| `rubber_*` | tyre tread: chevron lugs, sipes, dust in the grooves (u across the tyre) | drawn chevrons, noise |
| `markings.png` | RGBA decal atlas: part names, serials, hazard stripes, a fictional colony flag, hatch outline, roll pattern | drawn shapes and text |
| `interior_*` | cabin atlas: quilted wall padding, switch console, seat, suit fabric, the screens | drawn shapes and text, noise |

`*_orm.png` packs ambient occlusion (R), roughness (G) and metallic (B) — glTF's
layout — so one image feeds a material's `ao_map`, `roughness_map` and
`metallic_map` at once.

**Fonts** rasterised into `markings.png` and `interior_albedo.png`: Noto Sans
Black / Bold (SIL Open Font License 1.1, from the system's `noto-fonts`) and the
project's own `fonts/NotoSansMono-Medium.ttf` (OFL 1.1). The OFL covers the
fonts; text rendered into an image with them carries no font licence.

The flag is invented for the game; it is not any real nation's or agency's.

The meshes these textures dress are built by `tools/gen_part_meshes.py` (also
fully procedural); it binds the textures to each part prefab through
`object_materials`.
