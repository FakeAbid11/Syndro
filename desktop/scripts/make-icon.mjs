// Generates desktop/build/icon.ico and icon.png without any image tooling.
//
// The mark is the same geometry as the Android adaptive icon: an amber
// rounded square with a dark up-arrow and base bar, so the taskbar entry and
// the phone launcher read as the same product.
import { deflateSync } from "node:zlib";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SIZES = [16, 24, 32, 48, 64, 128, 256];
const SUPERSAMPLE = 4;
const AMBER = [0xff, 0xb4, 0x54];
const INK = [0x0b, 0x0b, 0x0c];

// Source geometry in a 108x108 viewport, matching ic_launcher_foreground.xml.
const VIEWPORT = 108;
const RADIUS = 22;
const ARROW = [
  [54, 28],
  [76, 50],
  [65, 50],
  [65, 80],
  [43, 80],
  [43, 50],
  [32, 50],
];
const BAR = [34, 84, 74, 89];

function insideRoundedSquare(x, y, size) {
  const r = (RADIUS / VIEWPORT) * size;
  if (x < 0 || y < 0 || x > size || y > size) return false;
  const cx = Math.min(Math.max(x, r), size - r);
  const cy = Math.min(Math.max(y, r), size - r);
  const dx = x - cx;
  const dy = y - cy;
  return dx * dx + dy * dy <= r * r;
}

function insidePolygon(x, y, points, size) {
  const scale = size / VIEWPORT;
  let inside = false;
  for (let i = 0, j = points.length - 1; i < points.length; j = i++) {
    const xi = points[i][0] * scale;
    const yi = points[i][1] * scale;
    const xj = points[j][0] * scale;
    const yj = points[j][1] * scale;
    if (yi > y !== yj > y && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) {
      inside = !inside;
    }
  }
  return inside;
}

/** Straight-alpha RGBA, supersampled and box-filtered down. */
function render(size) {
  const hi = size * SUPERSAMPLE;
  const scale = hi / VIEWPORT;
  const bar = [BAR[0] * scale, BAR[1] * scale, BAR[2] * scale, BAR[3] * scale];
  const out = Buffer.alloc(size * size * 4);

  for (let py = 0; py < size; py++) {
    for (let px = 0; px < size; px++) {
      let r = 0;
      let g = 0;
      let b = 0;
      let covered = 0;

      for (let sy = 0; sy < SUPERSAMPLE; sy++) {
        for (let sx = 0; sx < SUPERSAMPLE; sx++) {
          const x = px * SUPERSAMPLE + sx + 0.5;
          const y = py * SUPERSAMPLE + sy + 0.5;
          if (!insideRoundedSquare(x, y, hi)) continue;

          const isInk =
            insidePolygon(x, y, ARROW, hi) ||
            (x >= bar[0] && x <= bar[2] && y >= bar[1] && y <= bar[3]);
          const color = isInk ? INK : AMBER;
          r += color[0];
          g += color[1];
          b += color[2];
          covered++;
        }
      }

      if (covered === 0) continue;
      const offset = (py * size + px) * 4;
      out[offset] = Math.round(r / covered);
      out[offset + 1] = Math.round(g / covered);
      out[offset + 2] = Math.round(b / covered);
      out[offset + 3] = Math.round((covered * 255) / (SUPERSAMPLE * SUPERSAMPLE));
    }
  }

  return out;
}

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(buffer) {
  let c = 0xffffffff;
  for (const byte of buffer) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const head = Buffer.alloc(8);
  head.writeUInt32BE(data.length, 0);
  head.write(type, 4, "ascii");
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([head.subarray(4), data])), 0);
  return Buffer.concat([head, data, crc]);
}

function png(size, rgba) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // RGBA
  ihdr[10] = 0;
  ihdr[11] = 0;
  ihdr[12] = 0;

  const stride = size * 4;
  const raw = Buffer.alloc((stride + 1) * size);
  for (let y = 0; y < size; y++) {
    raw[y * (stride + 1)] = 0; // filter: none
    rgba.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  }

  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

/**
 * Classic 32-bit DIB icon entries. PNG-compressed ICO data is legal but some
 * Windows tooling (including .NET's Icon class and parts of NSIS) still expects
 * DIBs, so this keeps the installer icon boringly compatible.
 */
function dib(size, rgba) {
  const header = Buffer.alloc(40);
  header.writeUInt32LE(40, 0);
  header.writeInt32LE(size, 4);
  header.writeInt32LE(size * 2, 8); // XOR + AND masks
  header.writeUInt16LE(1, 12);
  header.writeUInt16LE(32, 14);
  header.writeUInt32LE(0, 16);
  header.writeUInt32LE(size * size * 4, 20);

  const pixels = Buffer.alloc(size * size * 4);
  for (let y = 0; y < size; y++) {
    const source = (size - 1 - y) * size * 4; // bottom-up
    const target = y * size * 4;
    for (let x = 0; x < size; x++) {
      const s = source + x * 4;
      const t = target + x * 4;
      pixels[t] = rgba[s + 2];
      pixels[t + 1] = rgba[s + 1];
      pixels[t + 2] = rgba[s];
      pixels[t + 3] = rgba[s + 3];
    }
  }

  const maskStride = Math.ceil(size / 32) * 4;
  const mask = Buffer.alloc(maskStride * size);
  for (let y = 0; y < size; y++) {
    const row = (size - 1 - y) * maskStride;
    for (let x = 0; x < size; x++) {
      if (rgba[((size - 1 - y) * size + x) * 4 + 3] === 0) {
        mask[row + (x >> 3)] |= 0x80 >> (x & 7);
      }
    }
  }

  return Buffer.concat([header, pixels, mask]);
}

function ico(images) {
  const header = Buffer.alloc(6);
  header.writeUInt16LE(0, 0);
  header.writeUInt16LE(1, 2);
  header.writeUInt16LE(images.length, 4);

  const entries = Buffer.alloc(16 * images.length);
  let offset = 6 + entries.length;
  images.forEach((image, index) => {
    const entry = index * 16;
    entries[entry] = image.size >= 256 ? 0 : image.size;
    entries[entry + 1] = image.size >= 256 ? 0 : image.size;
    entries[entry + 2] = 0;
    entries[entry + 3] = 0;
    entries.writeUInt16LE(1, entry + 4);
    entries.writeUInt16LE(32, entry + 6);
    entries.writeUInt32LE(image.data.length, entry + 8);
    entries.writeUInt32LE(offset, entry + 12);
    offset += image.data.length;
  });

  return Buffer.concat([header, entries, ...images.map((image) => image.data)]);
}

const here = dirname(fileURLToPath(import.meta.url));
const buildDir = join(here, "..", "build");
mkdirSync(buildDir, { recursive: true });

const icoPath = join(buildDir, "icon.ico");
const pngPath = join(buildDir, "icon.png");

writeFileSync(icoPath, ico(SIZES.map((size) => ({ size, data: dib(size, render(size)) }))));
writeFileSync(pngPath, png(512, render(512)));

console.log(`wrote ${icoPath} (${SIZES.join(", ")} px)`);
console.log(`wrote ${pngPath} (512 px)`);
