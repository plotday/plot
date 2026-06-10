import { marked } from "marked";

// The docs are trusted, first-party markdown bundled at build time from the
// repo (see scripts/sync-internal-docs.mjs) — never user input — so marked's
// unsanitized HTML output is safe here. Do NOT point these ?raw imports at any
// user-supplied content without adding sanitization first.
import featuresMd from "./internal-docs/features.md?raw";
import updatesMd from "./internal-docs/updates.md?raw";

export function renderFeatures(): string {
  return marked.parse(featuresMd, { async: false }) as string;
}

export function renderUpdates(): string {
  return marked.parse(updatesMd, { async: false }) as string;
}
