export type Mode = 'light' | 'dark';
export type Framing = 'phone' | 'phone-hero-span' | 'multipanel-flat';

export interface SlotPlan {
  slots: number[];          // [3] = one slot; [1,2] = spanning hero
  scene: string;
  mode: Mode;
  framing: Framing;
  headline: string;
  subhead?: string;
}
export interface PlatformPlan {
  platform: 'iphone-6.9' | 'ipad-13' | 'macos' | 'android-phone' | 'android-tablet';
  store: 'app-store' | 'play';
  captureDevice: string;    // sim name or 'macos'
  resolution: [number, number]; // exact px per slot
  slots: SlotPlan[];
}

export const PLANS: PlatformPlan[] = [
  {
    platform: 'iphone-6.9', store: 'app-store',
    captureDevice: 'iPhone 16 Pro Max', resolution: [1290, 2796],
    slots: [
      { slots: [1, 2], scene: 'S1', mode: 'light', framing: 'phone-hero-span',
        headline: 'All your work, ready for action',
        subhead: 'Team chat, email, and app threads in one place' },
      { slots: [3], scene: 'S2', mode: 'light', framing: 'phone',
        headline: 'Reply to anything without opening another app' },
      { slots: [4], scene: 'S3', mode: 'dark', framing: 'phone',
        headline: 'Your day in context' },
      { slots: [5], scene: 'S5', mode: 'light', framing: 'phone',
        headline: 'Start anything from one place' },
      { slots: [6], scene: 'S7', mode: 'dark', framing: 'phone',
        headline: 'AI right alongside your work', subhead: 'Use it your way, or turn it off' },
      { slots: [7], scene: 'S6', mode: 'light', framing: 'phone',
        headline: 'Find anything, wherever it lives' },
      { slots: [8], scene: 'S4', mode: 'light', framing: 'phone',
        headline: 'Organized by focus' },
    ],
  },
  {
    platform: 'macos', store: 'app-store',
    captureDevice: 'macos', resolution: [2880, 1800],
    slots: [
      { slots: [1], scene: 'S1', mode: 'light', framing: 'multipanel-flat',
        headline: 'All your work, ready for action' },
      { slots: [2], scene: 'S2', mode: 'light', framing: 'multipanel-flat',
        headline: 'Reply to anything without opening another app' },
      { slots: [3], scene: 'S11', mode: 'light', framing: 'multipanel-flat',
        headline: 'Drive it from the keyboard' },
      { slots: [4], scene: 'S7', mode: 'dark', framing: 'multipanel-flat',
        headline: 'AI alongside your work — or off entirely' },
      { slots: [5], scene: 'S8', mode: 'light', framing: 'multipanel-flat',
        headline: 'Works with the tools you already use' },
    ],
  },
  {
    platform: 'ipad-13', store: 'app-store',
    captureDevice: 'iPad Pro 13-inch (M4)', resolution: [2752, 2064],
    slots: [
      { slots: [1], scene: 'S1', mode: 'light', framing: 'multipanel-flat',
        headline: 'All your work, ready for action' },
      { slots: [2], scene: 'S2', mode: 'light', framing: 'multipanel-flat',
        headline: 'Reply to anything without opening another app' },
      { slots: [3], scene: 'S7', mode: 'dark', framing: 'multipanel-flat',
        headline: 'AI alongside your work — or off entirely' },
      { slots: [4], scene: 'S5', mode: 'light', framing: 'multipanel-flat',
        headline: 'Start anything from one place' },
      { slots: [5], scene: 'S8', mode: 'light', framing: 'multipanel-flat',
        headline: 'Works with the tools you already use' },
    ],
  },
  {
    platform: 'android-phone', store: 'play',
    captureDevice: 'Galaxy_S25', resolution: [1080, 2340],
    slots: [
      { slots: [1, 2], scene: 'S1', mode: 'light', framing: 'phone-hero-span',
        headline: 'All your work, ready for action',
        subhead: 'Team chat, email, and app threads in one place' },
      { slots: [3], scene: 'S2', mode: 'light', framing: 'phone',
        headline: 'Reply to anything without opening another app' },
      { slots: [4], scene: 'S3', mode: 'dark', framing: 'phone',
        headline: 'Your day in context' },
      { slots: [5], scene: 'S5', mode: 'light', framing: 'phone',
        headline: 'Start anything from one place' },
      { slots: [6], scene: 'S12', mode: 'light', framing: 'phone',
        headline: 'Save and share from any app' },
      { slots: [7], scene: 'S6', mode: 'light', framing: 'phone',
        headline: 'Find anything, wherever it lives' },
    ],
  },
  {
    platform: 'android-tablet', store: 'play',
    captureDevice: 'Galaxy_Tab_S8_Ultra', resolution: [2560, 1600],
    slots: [
      { slots: [1], scene: 'S1', mode: 'light', framing: 'multipanel-flat',
        headline: 'All your work, ready for action' },
      { slots: [2], scene: 'S2', mode: 'light', framing: 'multipanel-flat',
        headline: 'Reply to anything without opening another app' },
      { slots: [3], scene: 'S7', mode: 'dark', framing: 'multipanel-flat',
        headline: 'AI alongside your work — or off entirely' },
      { slots: [4], scene: 'S8', mode: 'light', framing: 'multipanel-flat',
        headline: 'Works with the tools you already use' },
    ],
  },
];

export const BRAND = { green: '#01845E', magenta: '#944390', greenDark: '#4AB088' };

/** Distinct (scene, mode) pairs to capture for a platform. */
export function capturesFor(p: PlatformPlan): { scene: string; mode: Mode }[] {
  const seen = new Set<string>();
  const out: { scene: string; mode: Mode }[] = [];
  for (const s of p.slots) {
    const k = `${s.scene}-${s.mode}`;
    if (!seen.has(k)) { seen.add(k); out.push({ scene: s.scene, mode: s.mode }); }
  }
  return out;
}
