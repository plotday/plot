import { marked } from "marked";

// The docs are trusted, first-party markdown bundled at build time from the
// repo (see scripts/sync-internal-docs.mjs) — never user input — so marked's
// unsanitized HTML output is safe here. Do NOT point these ?raw imports at any
// user-supplied content without adding sanitization first.
import featuresMd from "./internal-docs/features.md?raw";
import updatesMd from "./internal-docs/updates.md?raw";
import voiceMd from "./internal-docs/voice.md?raw";

export type InternalDocContent = {
  // Rendered HTML for display.
  html: string;
  // The raw markdown source, returned so the page can offer "Copy as Markdown".
  markdown: string;
};

function render(markdown: string): InternalDocContent {
  return { html: marked.parse(markdown, { async: false }) as string, markdown };
}

export function renderFeatures(): InternalDocContent {
  return render(featuresMd);
}

export function renderUpdates(): InternalDocContent {
  return render(updatesMd);
}

export function renderVoice(): InternalDocContent {
  return render(voiceMd);
}
