import { describe, expect, it } from "vitest";
import { deriveFacetFilters } from "./derive-facet-filters";
import type { Bindings } from "../env";

describe("deriveFacetFilters", () => {
  it("returns null (fail-open) when the AI gateway is not configured", async () => {
    const env = {
      AI_GATEWAY_ACCOUNT_ID: "",
      AI_GATEWAY_ID: "",
      AI_GATEWAY_TOKEN: "",
      ANTHROPIC_API_KEY: "",
    } as unknown as Bindings;
    expect(await deriveFacetFilters(env, "Reading", "newsletters")).toBeNull();
  });
});
