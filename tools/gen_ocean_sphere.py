#!/usr/bin/env python3
"""Write models/water/ocean_sphere.glb — a unit icosphere for the sea surface.

The engine's Sphere primitive is a 24×36 UV sphere: its facets sag about 0.4 %
of the radius between vertices, 0.6 m on a 170 m sea, so the drawn waterline
wandered off the one the swimmer and the shoreline foam use. A subdivision-5
icosphere (20 480 triangles, evenly spread, no pole pinch) sags ~4 cm there.

Radius 1: the sea node's scale IS the sea radius. Positions + normals + a
spherical UV, one mesh, one primitive, no material (the prefab supplies one).

    python3 tools/gen_ocean_sphere.py [SUBDIVISIONS]
"""
import json
import math
import struct
import sys
from pathlib import Path

import numpy as np

SUB = int(sys.argv[1]) if len(sys.argv) > 1 else 5
OUT = Path(__file__).resolve().parent.parent / "models" / "water" / "ocean_sphere.glb"


def icosphere(n):
    t = (1 + 5 ** 0.5) / 2
    verts = [(-1, t, 0), (1, t, 0), (-1, -t, 0), (1, -t, 0), (0, -1, t), (0, 1, t),
             (0, -1, -t), (0, 1, -t), (t, 0, -1), (t, 0, 1), (-t, 0, -1), (-t, 0, 1)]
    verts = [np.array(v, float) / np.linalg.norm(v) for v in verts]
    faces = [(0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4),
             (11, 10, 2), (10, 7, 6), (7, 1, 8), (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8),
             (3, 8, 9), (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1)]
    for _ in range(n):
        cache = {}

        def mid(a, b):
            k = (min(a, b), max(a, b))
            if k not in cache:
                m = verts[a] + verts[b]
                verts.append(m / np.linalg.norm(m))
                cache[k] = len(verts) - 1
            return cache[k]

        nf = []
        for a, b, c in faces:
            ab, bc, ca = mid(a, b), mid(b, c), mid(c, a)
            nf += [(a, ab, ca), (b, bc, ab), (c, ca, bc), (ab, bc, ca)]
        faces = nf
    return np.array(verts, np.float32), np.array(faces, np.uint32)


def main():
    v, f = icosphere(SUB)
    n = v.copy()
    uv = np.stack([0.5 + np.arctan2(v[:, 2], v[:, 0]) / (2 * math.pi),
                   0.5 - np.arcsin(np.clip(v[:, 1], -1, 1)) / math.pi], 1).astype(np.float32)
    idx = f.astype(np.uint32).reshape(-1)

    blobs = [v.tobytes(), n.tobytes(), uv.tobytes(), idx.tobytes()]
    views, off = [], 0
    for i, b in enumerate(blobs):
        views.append({"buffer": 0, "byteOffset": off, "byteLength": len(b),
                      "target": 34963 if i == 3 else 34962})
        off += (len(b) + 3) & ~3
    binary = b"".join(b + b"\0" * (((len(b) + 3) & ~3) - len(b)) for b in blobs)

    gltf = {
        "asset": {"version": "2.0", "generator": "Solar tools/gen_ocean_sphere.py"},
        "scene": 0, "scenes": [{"nodes": [0]}],
        "nodes": [{"name": "Ocean", "mesh": 0}],
        "meshes": [{"name": "Ocean", "primitives": [{
            "attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2}, "indices": 3}]}],
        "buffers": [{"byteLength": len(binary)}],
        "bufferViews": views,
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": len(v), "type": "VEC3",
             "min": v.min(0).tolist(), "max": v.max(0).tolist()},
            {"bufferView": 1, "componentType": 5126, "count": len(n), "type": "VEC3"},
            {"bufferView": 2, "componentType": 5126, "count": len(uv), "type": "VEC2"},
            {"bufferView": 3, "componentType": 5125, "count": len(idx), "type": "SCALAR"},
        ],
    }
    js = json.dumps(gltf, separators=(",", ":")).encode()
    js += b" " * (((len(js) + 3) & ~3) - len(js))
    glb = struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(binary))
    glb += struct.pack("<II", len(js), 0x4E4F534A) + js
    glb += struct.pack("<II", len(binary), 0x004E4942) + binary
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(glb)
    print(f"wrote {OUT}: {len(v)} vertices, {len(f)} triangles, {len(glb) // 1024} KB")


if __name__ == "__main__":
    main()
