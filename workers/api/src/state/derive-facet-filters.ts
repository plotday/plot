import { generateObject } from "ai";

import { createLogger } from "@plotday/worker-util";

import type { Bindings } from "../env";
import { createSystemModel, SYSTEM_PROVIDER_OPTIONS } from "../utils/system-model";
import { FacetFiltersSchema, registryPromptBlock, type FacetFilters } from "./facet-registry";

const SYSTEM_PROMPT = `You configure classification filters for a "focus" — a project or area-of-life a user gathers related items under.

Given the focus's title and description, decide which message FACETS belong in it. Output include/exclude sets per dimension and an optional trustedSendersOnly flag, using ONLY the documented values.

Be conservative: constrain a dimension ONLY when the focus clearly implies it. Leave a dimension out entirely when unsure — an absent dimension means "no filtering on that axis". It is far better to under-filter than to wrongly exclude wanted items.

Facets:
${registryPromptBlock()}

Examples:
- "Reading — newsletters and long reads" → { "format": { "include": ["reading"] } } (and consider excluding notification/promotion/receipt/invoice)
- "Receipts & invoices" → { "format": { "include": ["receipt","invoice"] } }
- "Important people" → { "trustedSendersOnly": true, "automation": { "exclude": ["automated"] } }
- "Work" (generic) → {} (no clear facet implication)`;

/**
 * Derive facet filters for a focus from its title + description. Returns the
 * validated filters, or null when the LLM is unavailable/failed (fail-open:
 * the focus then classifies with no facet gate).
 */
export async function deriveFacetFilters(
  env: Bindings,
  title: string,
  description: string | null
): Promise<FacetFilters | null> {
  const logger = createLogger({ component: "derive-facet-filters" });
  const model = createSystemModel(env);
  if (!model) {
    return null;
  }

  const userPrompt = `Focus title: ${JSON.stringify(title || "(untitled)")}
Focus description: ${JSON.stringify(description ?? "")}

Return the facet filters for this focus.`;

  try {
    const result = await generateObject({
      model,
      schema: FacetFiltersSchema,
      schemaName: "FacetFilters",
      schemaDescription:
        "Per-dimension include/exclude sets (format/automation/reach) plus an optional trustedSendersOnly boolean.",
      maxOutputTokens: 1_000,
      providerOptions: SYSTEM_PROVIDER_OPTIONS,
      instructions: SYSTEM_PROMPT,
      messages: [{ role: "user", content: userPrompt }],
    });
    return result.object;
  } catch (error) {
    logger.warn("facet-filter derivation failed", { error: (error as Error).message });
    return null;
  }
}
