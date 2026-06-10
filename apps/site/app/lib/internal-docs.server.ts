import { marked } from "marked";

import featuresMd from "./internal-docs/features.md?raw";
import updatesMd from "./internal-docs/updates.md?raw";

export function renderFeatures(): string {
  return marked.parse(featuresMd, { async: false }) as string;
}

export function renderUpdates(): string {
  return marked.parse(updatesMd, { async: false }) as string;
}
