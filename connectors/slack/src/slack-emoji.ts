import {
  SLACK_SHORTCODE_TO_UNICODE,
  SLACK_UNICODE_TO_SHORTCODE,
} from "./slack-emoji-map.g";

// Unicode skin-tone modifier grapheme -> Slack tone number (2..6).
const SKIN_TONE_MODIFIERS: Record<string, number> = {
  "🏻": 2,
  "🏼": 3,
  "🏽": 4,
  "🏾": 5,
  "🏿": 6,
};
const MODIFIER_BY_TONE: Record<number, string> = {
  2: "🏻",
  3: "🏼",
  4: "🏽",
  5: "🏾",
  6: "🏿",
};

/**
 * Slack reaction name (with or without `::skin-tone-N`) → Unicode grapheme.
 * Custom/unknown shortcodes return null so the caller can route them
 * elsewhere (Phase C) or drop them.
 */
export function slackNameToUnicode(name: string): string | null {
  // Direct hit — covers base names and the generated single-tone variants.
  const direct = SLACK_SHORTCODE_TO_UNICODE[name];
  if (direct) return direct;

  // Defensive fallback: compose a simple base+modifier the table missed.
  const m = name.match(/^(.+?)((?:::skin-tone-[2-6])+)$/);
  if (m) {
    const base = SLACK_SHORTCODE_TO_UNICODE[m[1]];
    if (!base) return null;
    const tones = [...m[2].matchAll(/::skin-tone-([2-6])/g)].map((t) =>
      Number(t[1])
    );
    if (tones.length === 1) return base + MODIFIER_BY_TONE[tones[0]];
    return base; // compound multi-tone: keep emoji, drop tone
  }
  return null;
}

/**
 * Unicode grapheme → preferred Slack reaction name (with `::skin-tone-N`
 * when toned). Returns null when Slack has no equivalent.
 */
export function unicodeToSlackName(grapheme: string): string | null {
  // Direct hit — covers base + generated single-tone + ZWJ-tone graphemes.
  const direct = SLACK_UNICODE_TO_SHORTCODE[grapheme];
  if (direct) return direct;

  // Defensive fallback: strip simple trailing skin modifier(s), retry base.
  const cps = Array.from(grapheme);
  const toneCps = cps.filter((c) => c in SKIN_TONE_MODIFIERS);
  if (toneCps.length === 0) return null;
  const base = cps.filter((c) => !(c in SKIN_TONE_MODIFIERS)).join("");
  const baseName = SLACK_UNICODE_TO_SHORTCODE[base];
  if (!baseName) return null;
  const distinct = new Set(toneCps.map((c) => SKIN_TONE_MODIFIERS[c]));
  if (distinct.size === 1) return `${baseName}::skin-tone-${[...distinct][0]}`;
  return baseName; // compound multi-tone: degrade to base name
}
