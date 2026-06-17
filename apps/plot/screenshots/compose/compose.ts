import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';
import { chromium } from 'playwright';
import { PLANS, type PlatformPlan } from '../manifest.ts';
import { heroCanvas, heroClips } from '../geometry.ts';
import { phoneSlot, heroSpan, multipanelFlat, multipanelWindows } from './templates.ts';

const RAW = new URL('../raw/', import.meta.url).pathname;
const STORE = new URL('../store/', import.meta.url).pathname;

async function dataUrl(path: string): Promise<string> {
  const buf = await readFile(path);
  return `data:image/png;base64,${buf.toString('base64')}`;
}
async function save(path: string, buf: Buffer) {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, buf);
}

async function renderPng(html: string, w: number, h: number,
    clip?: { x: number; y: number; width: number; height: number }) {
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage({ viewport: { width: w, height: h },
      deviceScaleFactor: 1 });
    await page.setContent(html, { waitUntil: 'networkidle' });
    return await page.screenshot(clip ? { clip } : {});
  } finally {
    await browser.close();
  }
}

// Native screen pixel size of each capture device (for frame aspect).
// Native screen pixel size of each capture device (used for frame aspect).
const SCREEN = {
  'iphone-6.9': { w: 1320, h: 2868 }, // iPhone 16 Pro Max native
  'ipad-13': { w: 2752, h: 2064 },    // iPad Pro 13" landscape (unused by flat)
  'macos': { w: 2880, h: 1800 },
  'android-phone': { w: 1080, h: 2340 },   // Galaxy S25
  'android-tablet': { w: 2560, h: 1600 },  // Galaxy Tab S8 Ultra landscape (unused by flat)
  'windows': { w: 1440, h: 900 },          // macOS capture window (emulated)
} as const;

export async function composePlatform(p: PlatformPlan) {
  for (const slot of p.slots) {
    const [W, H] = p.resolution;
    const dir = `${STORE}${p.store}/${p.platform}`;
    const raw = `${RAW}${p.platform}/${slot.scene}-${slot.mode}.png`;
    const src = await dataUrl(raw);
    const sc = SCREEN[p.platform];

    if (slot.framing === 'phone-hero-span') {
      const [cw, ch] = heroCanvas(p.resolution);
      const html = heroSpan({ src, canvasW: cw, canvasH: ch,
        screenW: sc.w, screenH: sc.h, headline: slot.headline, subhead: slot.subhead,
        platform: p.platform });
      const clips = heroClips(p.resolution);
      for (let i = 0; i < slot.slots.length; i++) {
        const png = await renderPng(html, cw, ch, clips[i]);
        await save(`${dir}/${String(slot.slots[i]).padStart(2, '0')}-${slot.scene}.png`, png);
      }
    } else if (slot.framing === 'phone') {
      const html = phoneSlot({ src, w: W, h: H, screenW: sc.w, screenH: sc.h,
        headline: slot.headline, subhead: slot.subhead, platform: p.platform });
      const png = await renderPng(html, W, H);
      await save(`${dir}/${String(slot.slots[0]).padStart(2, '0')}-${slot.scene}.png`, png);
    } else if (slot.framing === 'multipanel-windows') {
      const html = multipanelWindows({ src, w: W, h: H, headline: slot.headline });
      const png = await renderPng(html, W, H);
      await save(`${dir}/${String(slot.slots[0]).padStart(2, '0')}-${slot.scene}.png`, png);
    } else { // multipanel-flat
      const html = multipanelFlat({ src, w: W, h: H, headline: slot.headline });
      const png = await renderPng(html, W, H);
      await save(`${dir}/${String(slot.slots[0]).padStart(2, '0')}-${slot.scene}.png`, png);
    }
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  void (async () => {
    const only = process.argv[2];
    for (const p of PLANS) {
      if (only && p.platform !== only) continue;
      await composePlatform(p);
      console.log(`composed ${p.platform}`);
    }
  })();
}
