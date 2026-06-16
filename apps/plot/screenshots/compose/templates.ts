import { BRAND } from '../manifest.ts';

const FONT =
  `-apple-system, BlinkMacSystemFont, 'SF Pro Display', Inter, sans-serif`;

function gradient(angleDeg: number): string {
  // One continuous brand gradient; reused so spanning slots align.
  return `linear-gradient(${angleDeg}deg, ${BRAND.green} 0%, ${BRAND.magenta} 100%)`;
}

function caption(headline: string, subhead: string | undefined, w: number): string {
  const size = Math.round(w * 0.052);
  const sub = Math.round(w * 0.030);
  return `
    <div style="position:absolute;top:6%;left:0;right:0;text-align:center;
      font-family:${FONT};color:#fff;padding:0 8%">
      <div style="font-weight:700;font-size:${size}px;line-height:1.1;
        letter-spacing:-0.5px">${headline}</div>
      ${subhead ? `<div style="margin-top:14px;font-weight:400;opacity:.92;
        font-size:${sub}px">${subhead}</div>` : ''}
    </div>`;
}

/** Corner-radius factor (× screenW) for a platform's device frame. iPhones have
 *  deeply rounded screen corners; Samsung/Android screens are far squarer. The
 *  iPhone-tuned 0.11 radius clips Android's status-bar clock, which sits flush
 *  in the top-left corner (the clock reads "32" instead of "8:32"), so Android
 *  uses a much smaller, also more device-accurate radius. */
function frameRadiusFactor(platform: string): number {
  return platform.startsWith('android') ? 0.04 : 0.11;
}

/** A CSS device frame wrapping a screenshot data URL. */
function frame(src: string, screenW: number, screenH: number,
    radiusFactor = 0.11): string {
  const bezel = Math.round(screenW * 0.018);
  const radius = Math.round(screenW * radiusFactor);
  return `
    <div style="background:#0b0b0d;padding:${bezel}px;border-radius:${radius}px;
      box-shadow:0 40px 120px rgba(0,0,0,.45)">
      <img src="${src}" width="${screenW}" height="${screenH}"
        style="display:block;border-radius:${Math.round(radius * 0.82)}px"/>
    </div>`;
}

/** One phone slot: caption band up top, then a large device that bleeds off
 *  the bottom edge so the screen content stays legible at thumbnail size. */
export function phoneSlot(o: {
  src: string; w: number; h: number; screenW: number; screenH: number;
  headline: string; subhead?: string; platform: string;
}): string {
  // 0.86 of canvas width (vs a timid 0.74) → bigger, more readable UI. Anchored
  // just below the caption and scaled from the top so the device grows downward
  // and its bottom bleeds off-canvas (the standard high-converting phone shot).
  const scale = (o.w * 0.86) / o.screenW;
  const rf = frameRadiusFactor(o.platform);
  return `<!doctype html><html><body style="margin:0">
    <div style="position:relative;width:${o.w}px;height:${o.h}px;overflow:hidden;
      background:${gradient(155)}">
      ${caption(o.headline, o.subhead, o.w)}
      <div style="position:absolute;left:50%;top:17%;transform-origin:top center;
        transform:translateX(-50%) scale(${scale})">
        ${frame(o.src, o.screenW, o.screenH, rf)}</div>
    </div></body></html>`;
}

/** Spanning hero: double-wide single-gradient canvas, one large centred device
 *  that bleeds off the bottom. The headline sits in the left slot and the
 *  subhead in the right slot (both full size) so each sliced half carries text.
 *  The device is sized so each slot keeps at most ~25% empty gradient. */
export function heroSpan(o: {
  src: string; canvasW: number; canvasH: number; screenW: number; screenH: number;
  headline: string; subhead?: string; platform: string;
}): string {
  const rf = frameRadiusFactor(o.platform);
  const titleSize = Math.round(o.canvasW * 0.024);
  // Frame the device to ~0.78 of the canvas width (a portrait phone that fills
  // 75%+ of a double-wide canvas) and anchor its top below the text band so it
  // grows downward and bleeds off the bottom — the status bar stays visible.
  const framedW = o.screenW * 1.036; // screen + 2× bezel (see frame())
  const scale = (o.canvasW * 0.78) / framedW;
  return `<!doctype html><html><body style="margin:0">
    <div style="position:relative;width:${o.canvasW}px;height:${o.canvasH}px;
      overflow:hidden;background:${gradient(155)}">
      <div style="position:absolute;top:5.5%;left:0;width:50%;text-align:center;
        box-sizing:border-box;font-family:${FONT};color:#fff;padding:0 7%">
        <div style="font-weight:700;font-size:${titleSize}px;
          line-height:1.12;letter-spacing:-1px">${o.headline}</div>
      </div>
      ${o.subhead ? `<div style="position:absolute;top:5.5%;left:50%;width:50%;
        text-align:center;box-sizing:border-box;font-family:${FONT};color:#fff;
        padding:0 7%">
        <div style="font-weight:700;font-size:${titleSize}px;
          line-height:1.12;letter-spacing:-1px">${o.subhead}</div>
      </div>` : ''}
      <div style="position:absolute;left:50%;top:19%;transform-origin:top center;
        transform:translateX(-50%) scale(${scale})">
        ${frame(o.src, o.screenW, o.screenH, rf)}
      </div>
    </div></body></html>`;
}

/** Flat multi-panel (tablet/desktop): caption band on top, then the shot
 *  scaled to fit the remaining area (works for both 16:10 macOS and 4:3 iPad
 *  captures — fit-to-area, not width-only, so the taller iPad shot doesn't
 *  overflow). */
export function multipanelFlat(o: {
  src: string; w: number; h: number; headline: string;
}): string {
  const bandH = Math.round(o.h * 0.105);
  const pad = Math.round(o.h * 0.03);
  return `<!doctype html><html><body style="margin:0">
    <div style="width:${o.w}px;height:${o.h}px;background:${gradient(120)};
      box-sizing:border-box;display:flex;flex-direction:column;
      align-items:center">
      <div style="flex:0 0 ${bandH}px;display:flex;align-items:center;
        font-family:${FONT};color:#fff;font-weight:700;
        font-size:${Math.round(o.w * 0.024)}px">${o.headline}</div>
      <div style="flex:1 1 auto;min-height:0;width:100%;display:flex;
        align-items:flex-start;justify-content:center;padding:0 0 ${pad}px">
        <img src="${o.src}" style="max-width:95%;max-height:100%;
          border-radius:14px;box-shadow:0 30px 90px rgba(0,0,0,.4)"/>
      </div>
    </div></body></html>`;
}
