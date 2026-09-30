// tools/undraco.mjs — make a compressed .glb loadable by Floptle.
//
//   npm install @gltf-transform/core @gltf-transform/extensions draco3dgltf
//   node tools/undraco.mjs in.glb out.glb
//
// Decodes Draco-compressed meshes and writes them back uncompressed. A WebP
// texture with a PNG fallback of the same name is replaced by the PNG (Floptle reads
// neither Draco nor EXT_texture_webp).
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import draco3d from 'draco3dgltf';
const [src, dst] = process.argv.slice(2);
const io = new NodeIO().registerExtensions(ALL_EXTENSIONS)
  .registerDependencies({ 'draco3d.decoder': await draco3d.createDecoderModule() });
const doc = await io.read(src);
const root = doc.getRoot();
for (const webp of root.listTextures().filter(t => t.getMimeType() === 'image/webp')) {
  const png = root.listTextures().find(t => t !== webp && t.getMimeType() !== 'image/webp' && t.getName() === webp.getName());
  if (!png) throw new Error(`no fallback for WebP texture ${webp.getName()}`);
  for (const parent of webp.listParents()) if (parent !== root) parent.swap(webp, png);
  webp.dispose();
}
for (const ext of root.listExtensionsUsed())
  if (['KHR_draco_mesh_compression', 'EXT_texture_webp'].includes(ext.extensionName)) ext.dispose();
await io.write(dst, doc);
console.log(src, '->', dst);
