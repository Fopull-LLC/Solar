NASA 3D Resources models (nasa3d.arc.nasa.gov / science.nasa.gov 3D models).

NASA media is generally not copyrighted and may be used without explicit
permission; NASA's guidelines ask that NASA not be depicted as endorsing the
product, and that the NASA insignia/logos not be used improperly. These
models are used here as generic hardware meshes.

Scale note: most of these are authored in INCHES (the Solid Rocket Booster
spans ~1780 units). Downscale by ~0.025 in node/prefab transforms for
game-unit (meter-ish) sizing.

Intended uses (game roadmap): sugar_rocket_nozzle / solid_rocket_booster /
external_tank / esas_crew_module / orbiter_docking_system / payload →
ship parts; dishes / radome / cubesat / telescopes → antennas, satellites,
science instruments (SC6); mobile_launcher / jsc_mission_control_room →
facility dressing; eva_suit / advanced_crew_escape_suit → astronaut suit
looks (SC5); hand tools (hammer, grease_gun, pistol_grip_tool) → inventory
items (SC4+).

Compression: most of these ship Draco-compressed (KHR_draco_mesh_compression),
which Floptle refuses (`floptle check` names the file). The cubesat and the
Canadarm have been decoded with tools/undraco.mjs; run it on any other one
before putting it in a scene or prefab.
