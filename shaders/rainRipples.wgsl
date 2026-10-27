// rainRipples — rain rings on wet ground, simulated on the GPU (engine compute,
// 0.117 rc38). Driven by scripts/rain_fx.lua when its `computeRipples` param is
// on (off by default: a prototype). A wave height field, `n`×`n` cells over a
// patch `n * texel` metres across laid round the camera as a decal: every drop
// that lands this step kicks the cells round its point (`emit`), the rings spread,
// cross and die away, and `shade` turns the field's slope into the picture the
// decal draws (light on the side of a ring facing the sky, alpha by slope and
// by how wet the ground is). The drops come from a lattice in the patch's own
// metres (`cell` m a cell, each firing once a `period` with a share `rate` of
// cells firing), so a patch laid again at the same place drops in the same
// spots. (Helpers here read no `params`: a run compiles every helper in the
// file against its own params, so a helper reading a param the run does not
// pass fails that run, called or not.) Two height buffers, `cur` (this step) and `prev` (the last): `step`
// writes the next step over `prev` (each cell only its own), and the script
// swaps the two names.

fn rr_at(p: vec2<i32>, n: i32) -> u32 {
  let q = clamp(p, vec2<i32>(0, 0), vec2<i32>(n - 1, n - 1));
  return u32(q.y * n + q.x);
}

@compute @workgroup_size(8, 8)
fn clear(@builtin(global_invocation_id) id: vec3<u32>) {
  let n = u32(params.n);
  if (id.x >= n || id.y >= n) { return; }
  let i = id.y * n + id.x;
  cur[i] = 0.0;
  prev[i] = 0.0;
}

// The drops landing in this step: one invocation per lattice cell (`cells` a
// side), each kicking the cells within `rad` m of its drop's point. (A drop
// search per height cell, three by three lattice cells each, cost 1.5 ms of
// GPU at 512²; this is a thousand invocations.)
@compute @workgroup_size(8, 8)
fn emit(@builtin(global_invocation_id) id: vec3<u32>) {
  let nc = u32(params.cells);
  if (id.x >= nc || id.y >= nc) { return; }
  let n = i32(params.n);
  let c = vec2<f32>(id.xy);
  let ph = flsl_hash2(c * 1.37 + vec2<f32>(params.ox, params.oy));
  let k0 = floor(params.t0 / params.period + ph);
  let k1 = floor(params.t1 / params.period + ph);
  if (k1 <= k0) { return; }
  if (flsl_hash2(c + vec2<f32>(k1 * 0.731, k1 * 1.173)) >= params.rate) { return; }
  let at = (c + vec2<f32>(flsl_hash2(c + vec2<f32>(k1, 3.1)), flsl_hash2(c + vec2<f32>(5.7, k1)))) * params.cell;
  let px = at / params.texel;
  let r = i32(ceil(params.rad / params.texel));
  for (var dy = -r; dy <= r; dy++) {
    for (var dx = -r; dx <= r; dx++) {
      let q = vec2<i32>(floor(px)) + vec2<i32>(dx, dy);
      if (q.x < 0 || q.y < 0 || q.x >= n || q.y >= n) { continue; }
      let d = length((vec2<f32>(q) + vec2<f32>(0.5, 0.5)) * params.texel - at);
      cur[u32(q.y * n + q.x)] += params.amp * max(0.0, 1.0 - d / params.rad);
    }
  }
}

@compute @workgroup_size(8, 8)
fn step(@builtin(global_invocation_id) id: vec3<u32>) {
  let n = i32(params.n);
  let p = vec2<i32>(id.xy);
  if (p.x >= n || p.y >= n) { return; }
  let i = rr_at(p, n);
  let h = cur[i];
  let lap = cur[rr_at(p + vec2<i32>(1, 0), n)] + cur[rr_at(p - vec2<i32>(1, 0), n)]
          + cur[rr_at(p + vec2<i32>(0, 1), n)] + cur[rr_at(p - vec2<i32>(0, 1), n)] - 4.0 * h;
  prev[i] = (2.0 * h - prev[i] + params.c2 * lap) * params.damp;
}

@compute @workgroup_size(8, 8)
fn shade(@builtin(global_invocation_id) id: vec3<u32>) {
  let n = i32(params.n);
  let p = vec2<i32>(id.xy);
  if (p.x >= n || p.y >= n) { return; }
  if (params.test > 0.5) { textureStore(out, p, vec4<f32>(1.0, 0.0, 1.0, 1.0)); return; }   // (probes: is the decal drawn?)
  let gx = cur[rr_at(p + vec2<i32>(1, 0), n)] - cur[rr_at(p - vec2<i32>(1, 0), n)];
  let gy = cur[rr_at(p + vec2<i32>(0, 1), n)] - cur[rr_at(p - vec2<i32>(0, 1), n)];
  let s = length(vec2<f32>(gx, gy)) * params.gain;
  // fade to nothing at the patch's edge: the decal's border never shows
  let uv = (vec2<f32>(p) + vec2<f32>(0.5, 0.5)) / f32(n) * 2.0 - vec2<f32>(1.0, 1.0);
  let edge = saturate((1.0 - length(uv)) * 5.0);
  // the side of a ring that faces the sky catches it; the other is darker
  let lit = saturate(0.5 + (gx * 0.6 + gy * 0.8) * params.gain * 0.5);
  let col = mix(vec3<f32>(params.dr, params.dg, params.db) * 0.55, vec3<f32>(params.sr, params.sg, params.sb) * 1.6, lit);
  let a = saturate(s) * params.wet * edge;
  textureStore(out, p, vec4<f32>(saturate(col), a));
}
