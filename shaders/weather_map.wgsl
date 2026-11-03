// weather_map — a world's weather drawn into the cube atlas the cloud layer
// reads (scripts/weather_map.lua says what is on it; engine card 0589).
//
// One invocation per atlas texel, gutters included (a gutter texel is the
// direction just past its face's edge, so filtering across a seam finds the
// neighbour face's own weather). `sys` holds the live systems the script rolled,
// 16 floats each: centre.xyz, I | east.xyz, rc | north.xyz, len | cls, kind,
// hail, sgn. The geometry below is `fieldAt` in weather_map.lua, line for line
// (the weather you stand in is that Lua; keep the two in step). The only thing
// the GPU adds is a breakup noise on the fair-weather coverage, which the Lua
// leaves out because the weather where you stand never depends on it.
//
// rgba8: R coverage, G type (0 stratus, 0.5 cumulus, 1 cumulonimbus),
// B density / wetness, A cirrus. Helpers take their numbers as arguments:
// a helper may not read `params` (see rainRipples.wgsl).

fn wm_smooth(a: f32, b: f32, x: f32) -> f32 {
  let t = clamp((x - a) / (b - a), 0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

// Face 0..5 = +X −X +Y −Y +Z −Z, (a, b) across it in −1..1 (weather_map.lua face_dir).
fn wm_face_dir(fi: i32, a: f32, b: f32) -> vec3<f32> {
  var d = vec3<f32>(-a, -b, -1.0);
  if (fi == 0) { d = vec3<f32>(1.0, -b, -a); }
  else if (fi == 1) { d = vec3<f32>(-1.0, -b, a); }
  else if (fi == 2) { d = vec3<f32>(a, 1.0, b); }
  else if (fi == 3) { d = vec3<f32>(a, -1.0, -b); }
  else if (fi == 4) { d = vec3<f32>(a, -b, 1.0); }
  return normalize(d);
}

fn wm_seg_d2(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>) -> f32 {
  let d = b - a;
  let l2 = dot(d, d);
  var h = 0.0;
  if (l2 > 0.0) { h = clamp(dot(p - a, d) / l2, 0.0, 1.0); }
  let q = p - a - d * h;
  return dot(q, q);
}

fn wm_cold_d(p: vec2<f32>, s: f32) -> f32 {
  var m = wm_seg_d2(p, vec2<f32>(0.0, 0.0) * s, vec2<f32>(0.06, -0.3) * s);
  m = min(m, wm_seg_d2(p, vec2<f32>(0.06, -0.3) * s, vec2<f32>(-0.02, -0.62) * s));
  m = min(m, wm_seg_d2(p, vec2<f32>(-0.02, -0.62) * s, vec2<f32>(-0.22, -0.9) * s));
  return sqrt(m);
}

fn wm_warm_d(p: vec2<f32>, s: f32) -> f32 {
  var m = wm_seg_d2(p, vec2<f32>(0.0, 0.0) * s, vec2<f32>(0.3, -0.06) * s);
  m = min(m, wm_seg_d2(p, vec2<f32>(0.3, -0.06) * s, vec2<f32>(0.55, -0.2) * s));
  return sqrt(m);
}

// A small integer hash and 3D value noise for the breakup (GPU only).
fn wm_hash(p: vec3<i32>, seed: u32) -> f32 {
  var h = ((u32(p.x) * 73856093u) ^ (u32(p.y) * 19349663u)) ^ ((u32(p.z) * 83492791u) ^ (seed * 2654435761u));
  h = (h ^ (h >> 16u)) * 2246822519u;
  h = (h ^ (h >> 13u)) * 3266489917u;
  h = h ^ (h >> 16u);
  return f32(h & 0xffffffu) / 16777215.0;
}

fn wm_vnoise(q: vec3<f32>, seed: u32) -> f32 {
  let i = vec3<i32>(floor(q));
  let f = fract(q);
  let u = f * f * (3.0 - 2.0 * f);
  let a = mix(mix(wm_hash(i, seed), wm_hash(i + vec3<i32>(1, 0, 0), seed), u.x),
              mix(wm_hash(i + vec3<i32>(0, 1, 0), seed), wm_hash(i + vec3<i32>(1, 1, 0), seed), u.x), u.y);
  let b = mix(mix(wm_hash(i + vec3<i32>(0, 0, 1), seed), wm_hash(i + vec3<i32>(1, 0, 1), seed), u.x),
              mix(wm_hash(i + vec3<i32>(0, 1, 1), seed), wm_hash(i + vec3<i32>(1, 1, 1), seed), u.x), u.y);
  return mix(a, b, u.z);
}

// The map at unit direction `d`: rgba as above. `noise` off is exactly
// weather_map.lua `fieldAt` (the probe entry checks that).
fn wm_field(d: vec3<f32>, n: i32, moist: f32, cover: f32, polar_k: f32, phase: f32, seed: u32, noise: bool) -> vec4<f32> {
  // the climate's bands
  let lat = asin(clamp(d.y, -1.0, 1.0));
  let lon = atan2(d.z, d.x);
  let alat = abs(lat);
  let iz = (lat - 0.1 * sin(2.0 * lon + phase)) / 0.16;
  let itcz = exp(-iz * iz);
  let sz = (alat - 0.52) / 0.16;
  let sub = exp(-sz * sz);
  let mid = wm_smooth(0.6, 0.8, alat) * (1.0 - wm_smooth(1.15, 1.4, alat));
  let polar = wm_smooth(1.1, 1.4, alat);
  let Ib = clamp(0.06 + 0.24 * itcz * moist + 0.16 * mid * moist + 0.12 * polar * polar_k - 0.05 * sub, 0.0, 0.32);
  var tw = Ib + 1e-4;
  var tsum = (0.5 * itcz + 0.3 * mid + 0.1 * polar + 0.35 * 0.2) / (itcz + mid + polar + 0.2) * tw;
  var keep = 1.0 - Ib;
  var cir = 0.25 * itcz * moist;
  var dustw = 0.0;

  for (var i = 0; i < n; i++) {
    let o = i * 16;
    let c = vec3<f32>(sys[o], sys[o + 1], sys[o + 2]);
    if (dot(d, c) <= 0.3) { continue; }
    let I = sys[o + 3];
    let e = vec3<f32>(sys[o + 4], sys[o + 5], sys[o + 6]);
    let rc = sys[o + 7];
    let nn = vec3<f32>(sys[o + 8], sys[o + 9], sys[o + 10]);
    let L = sys[o + 11];
    let cls = sys[o + 12];
    let kind = sys[o + 13];
    let sgn = sys[o + 15];
    let p0 = vec2<f32>(dot(d, e), dot(d, nn) * sgn);
    // the system's own warp (weather_map.lua: two waves on its own phase)
    let ph = c.x * 13.1 + c.y * 3.3 + c.z * 7.7;
    let wa = select(0.35 * rc, 0.1 * L, cls < 1.5);
    let p = vec2<f32>(
      p0.x + wa * (sin(p0.y / wa * 1.3 + ph) + 0.5 * sin(p0.y / wa * 2.9 + ph * 2.3)),
      p0.y + wa * (sin(p0.x / wa * 1.1 + ph * 1.7) + 0.5 * sin(p0.x / wa * 2.7 + ph * 0.6)));
    var v = 0.0;
    var typ = 0.5;
    var ci = 0.0;
    if (cls < 1.5) {
      let core = exp(-dot(p, p) / (rc * rc));
      let dc = wm_cold_d(p, L) / (0.09 * L);
      let dw = wm_warm_d(p, L) / (0.2 * L);
      let cold = exp(-dc * dc);
      let warm = 0.8 * exp(-dw * dw);
      v = I * max(core, max(cold, warm));
      typ = (core * 0.12 + cold * 0.8 + warm * 0.2) / (core + cold + warm + 1e-4);
      let a = p - vec2<f32>(0.45 * L, 0.1 * L);
      ci = I * (0.9 * exp(-dot(a, a) / (0.16 * L * L)) + 0.3 * core);
    } else {
      let r2 = dot(p, p) / (rc * rc);
      let core = exp(-r2);
      v = I * core;
      let st = wm_smooth(0.55, 0.9, I);
      typ = 0.5 + 0.5 * st * core;
      ci = st * exp(-r2 / 5.0);
    }
    if (kind > 0.5 && kind < 1.5) { dustw = max(dustw, v); }
    keep *= 1.0 - v;
    tsum += v * typ;
    tw += v;
    cir = max(cir, ci);
  }
  let I = 1.0 - keep;
  let pc = cover * (1.0 - 0.6 * sub);
  var cov = (pc + (1.0 - pc) * wm_smooth(0.12, 0.5, I)) * (1.0 - 0.7 * dustw);
  // Breakup: fair weather is patchy at a few hundred metres, an overcast
  // is not (the cloud layer's own noise makes the shapes inside either).
  if (noise) {
    let nz = wm_vnoise(d * 9.0, seed) * 0.65 + wm_vnoise(d * 23.0, seed + 7u) * 0.35;
    let patchy = 1.0 - wm_smooth(0.45, 0.8, cov);
    cov = clamp(cov * mix(1.0, 0.35 + 1.3 * nz, patchy), 0.0, 1.0);
  }
  let dens = wm_smooth(0.3, 0.9, I) * (1.0 - 0.7 * dustw);
  if (noise) {
    let cn = wm_vnoise(d * 6.0 + vec3<f32>(3.1), seed + 13u);
    cir = cir * (0.6 + 0.8 * cn);
  }
  cir = clamp(cir, 0.0, 1.0);
  return vec4<f32>(cov, clamp(tsum / tw, 0.0, 1.0), dens, cir);
}

@compute @workgroup_size(8, 8)
fn atlas(@builtin(global_invocation_id) id: vec3<u32>) {
  let F = i32(params.face);
  let S = F + 2;
  if (i32(id.x) >= 3 * S || i32(id.y) >= 2 * S) { return; }
  let col = i32(id.x) / S;
  let row = i32(id.y) / S;
  let fi = row * 3 + col;
  // texel centre across the face, the gutter just past −1 / +1
  let tx = f32(i32(id.x) - col * S - 1) + 0.5;
  let ty = f32(i32(id.y) - row * S - 1) + 0.5;
  let d = wm_face_dir(fi, tx / f32(F) * 2.0 - 1.0, ty / f32(F) * 2.0 - 1.0);

  let c4 = wm_field(d, i32(params.n), params.moist, params.cover, params.polar, params.phase, u32(params.seed), true);
  textureStore(out, vec2<i32>(id.xy), c4);
}

// For the probe: the map, without the breakup, at the directions in `dirs`
// (xyz), into `res` (rgba), to set beside the Lua's fieldAt.
@compute @workgroup_size(64)
fn probe(@builtin(global_invocation_id) id: vec3<u32>) {
  if (id.x >= u32(params.count)) { return; }
  let d = normalize(dirs[id.x].xyz);
  res[id.x] = wm_field(d, i32(params.n), params.moist, params.cover, params.polar, params.phase, u32(params.seed), false);
}
