#!/usr/bin/env bun
/**
 * Draws the app icon (pink-to-purple gradient, white rounded play button) as a 1024px PNG
 * for the iOS asset catalog. No dependencies:  bun tools/make-icon.ts
 */
import { deflateSync } from "node:zlib";
import { join } from "node:path";

const OUT = join(import.meta.dir, "../ios/Links/Assets.xcassets/AppIcon.appiconset/AppIcon.png");
const TOP = [255, 55, 95];
const BOTTOM = [120, 60, 220];
const SS = 3; // supersampling per axis
// Triangle in unit space, nudged right so it looks optically centred; rounded by radius R.
const R = 0.045;
const PTS: [number, number][] = [[0.40, 0.30], [0.40, 0.70], [0.70, 0.50]];

/** Distance from a point to the triangle (0 inside). */
function triDist(px: number, py: number): number {
  const edge = (a: [number, number], b: [number, number]) => (b[0] - a[0]) * (py - a[1]) - (b[1] - a[1]) * (px - a[0]);
  const signs = PTS.map((p, i) => edge(p, PTS[(i + 1) % 3]!));
  if (signs.every((s) => s >= 0) || signs.every((s) => s <= 0)) return 0;
  let best = Infinity;
  for (let i = 0; i < 3; i++) {
    const [ax, ay] = PTS[i]!;
    const [bx, by] = PTS[(i + 1) % 3]!;
    const dx = bx - ax, dy = by - ay;
    const t = Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)));
    best = Math.min(best, Math.hypot(px - ax - t * dx, py - ay - t * dy));
  }
  return best;
}

function draw(size: number): Uint8Array {
  const raw = new Uint8Array(size * (size * 3 + 1));
  let o = 0;
  for (let y = 0; y < size; y++) {
    raw[o++] = 0; // filter: none
    const t = y / (size - 1);
    const g = TOP.map((c, i) => c + (BOTTOM[i]! - c) * t);
    for (let x = 0; x < size; x++) {
      let cover = 0;
      for (let sy = 0; sy < SS; sy++) {
        for (let sx = 0; sx < SS; sx++) {
          if (triDist((x + (sx + 0.5) / SS) / size, (y + (sy + 0.5) / SS) / size) <= R) cover++;
        }
      }
      const a = cover / (SS * SS);
      for (let i = 0; i < 3; i++) raw[o++] = Math.round(g[i]! * (1 - a) + 255 * a);
    }
  }
  const chunk = (kind: string, data: Uint8Array) => {
    const body = new Uint8Array([...new TextEncoder().encode(kind), ...data]);
    const out = new Uint8Array(12 + data.length);
    const view = new DataView(out.buffer);
    view.setUint32(0, data.length);
    out.set(body, 4);
    view.setUint32(8 + data.length, Bun.hash.crc32(body));
    return out;
  };
  const ihdr = new Uint8Array(13);
  new DataView(ihdr.buffer).setUint32(0, size);
  new DataView(ihdr.buffer).setUint32(4, size);
  ihdr.set([8, 2, 0, 0, 0], 8); // 8-bit RGB, no alpha (App Store icons must be opaque)
  const parts = [
    new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw, { level: 9 })),
    chunk("IEND", new Uint8Array()),
  ];
  return new Uint8Array(parts.flatMap((p) => [...p]));
}

await Bun.write(OUT, draw(1024));
console.log(`wrote ${OUT}`);
