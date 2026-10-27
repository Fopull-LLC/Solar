# Solar — notes for coding agents

- **Positions, aiming and frames:** read `docs/positions-and-frames.md` before writing any code that aims, draws a line or marker at something, steers toward something, caches a point or measures a speed. The planet and craft move metres per tick. Mixing drawn and tick poses, or keeping world points across frames, is the most frequent bug in this project.
- **Other design docs** live in `docs/`: builder, crew and items, auto-engineering, UI style, VFX.
