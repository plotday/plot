/**
 * Generates src/slack-emoji-map.g.ts from iamcal/emoji-data — the dataset
 * Slack itself ships, so `short_name` values are exactly Slack reaction names.
 *
 * Regenerate: pnpm --filter @plotday/connector-slack gen-emoji-map
 * Pin: bump EMOJI_DATA_REF to the latest tag listed at
 *   https://github.com/iamcal/emoji-data/tags
 */
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// Verify/bump against https://github.com/iamcal/emoji-data/tags
const EMOJI_DATA_REF = "v15.1.2";
const SOURCE_URL = `https://raw.githubusercontent.com/iamcal/emoji-data/${EMOJI_DATA_REF}/emoji.json`;

// iamcal skin_variation key (modifier codepoint) -> Slack ::skin-tone-N suffix.
const SKIN_TONE_BY_MODIFIER: Record<string, number> = {
  "1F3FB": 2,
  "1F3FC": 3,
  "1F3FD": 4,
  "1F3FE": 5,
  "1F3FF": 6,
};

type EmojiDatum = {
  unified: string;
  short_name: string;
  short_names: string[];
  skin_variations?: Record<string, { unified: string }>;
};

function unifiedToChar(unified: string): string {
  return String.fromCodePoint(
    ...unified.split("-").map((h) => Number.parseInt(h, 16))
  );
}

async function main(): Promise<void> {
  const res = await fetch(SOURCE_URL);
  if (!res.ok) throw new Error(`fetch ${SOURCE_URL} -> ${res.status}`);
  const data = (await res.json()) as EmojiDatum[];

  const shortcodeToUnicode: Record<string, string> = {};
  const unicodeToShortcode: Record<string, string> = {};
  const addForward = (name: string, char: string) => {
    if (!(name in shortcodeToUnicode)) shortcodeToUnicode[name] = char;
  };
  const addReverse = (char: string, name: string) => {
    if (!(char in unicodeToShortcode)) unicodeToShortcode[char] = name;
  };

  for (const e of data) {
    const baseChar = unifiedToChar(e.unified);
    const names = e.short_names?.length ? e.short_names : [e.short_name];
    for (const n of names) addForward(n, baseChar);
    addReverse(baseChar, e.short_name);

    for (const [modKey, variation] of Object.entries(e.skin_variations ?? {})) {
      const tone = SKIN_TONE_BY_MODIFIER[modKey];
      if (!tone) continue; // skip multi-tone compound keys like "1F3FB-1F3FF"
      const toneChar = unifiedToChar(variation.unified);
      for (const n of names) addForward(`${n}::skin-tone-${tone}`, toneChar);
      addReverse(toneChar, `${e.short_name}::skin-tone-${tone}`);
    }
  }

  const header =
    `// GENERATED FILE — do not edit by hand.\n` +
    `// Source: iamcal/emoji-data ${EMOJI_DATA_REF} (${SOURCE_URL})\n` +
    `// Regenerate via: pnpm --filter @plotday/connector-slack gen-emoji-map\n` +
    `//\n` +
    `// SLACK_SHORTCODE_TO_UNICODE: Slack reaction name (incl. ::skin-tone-N) -> grapheme.\n` +
    `// SLACK_UNICODE_TO_SHORTCODE: grapheme -> preferred Slack reaction name (first short_name wins).\n`;

  const body =
    header +
    `\nexport const SLACK_SHORTCODE_TO_UNICODE: Record<string, string> = ${JSON.stringify(
      shortcodeToUnicode,
      null,
      2
    )};\n\n` +
    `export const SLACK_UNICODE_TO_SHORTCODE: Record<string, string> = ${JSON.stringify(
      unicodeToShortcode,
      null,
      2
    )};\n`;

  const outPath = join(
    dirname(fileURLToPath(import.meta.url)),
    "..",
    "src",
    "slack-emoji-map.g.ts"
  );
  writeFileSync(outPath, body, "utf8");
  console.log(
    `Wrote ${outPath}: ${Object.keys(shortcodeToUnicode).length} names, ` +
      `${Object.keys(unicodeToShortcode).length} graphemes`
  );
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
