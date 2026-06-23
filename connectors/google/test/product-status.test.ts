import { describe, expect, it } from "vitest";
import type { LinkTypeConfig } from "@plotday/twister/tools/integrations";
import type { Product } from "../src/products/product";
import { computeProductStatus } from "../src/product-status";

// Minimal fake products: a channel-bearing one ("mail") and a channelless one
// ("contacts"). getRawChannels/onEnable/onDisable are irrelevant to status.
const noop = async () => {};
const mail: Product = {
  key: "mail",
  requiredScopes: ["scope.mail"],
  linkTypes: [] as LinkTypeConfig[],
  getRawChannels: async () => [],
  onEnable: noop,
  onDisable: noop,
};
const contacts: Product = {
  key: "contacts",
  requiredScopes: ["scope.contacts"],
  linkTypes: [] as LinkTypeConfig[],
  channelless: true,
  getRawChannels: async () => [],
  onEnable: noop,
  onDisable: noop,
};
const products = [mail, contacts];

const base = { enabledChannelCount: {}, locallyOff: {} };

describe("computeProductStatus", () => {
  it("reports scope-missing when the required scope is not granted", () => {
    const status = computeProductStatus(products, { ...base, grantedScopes: [] });
    expect(status.find((s) => s.key === "mail")).toEqual({
      key: "mail",
      enabled: false,
      reason: "scope-missing",
    });
  });

  it("reports no-channels for a scoped channel-product with zero enabled channels", () => {
    const status = computeProductStatus(products, {
      ...base,
      grantedScopes: ["scope.mail"],
    });
    expect(status.find((s) => s.key === "mail")).toEqual({
      key: "mail",
      enabled: false,
      reason: "no-channels",
    });
  });

  it("enables a channel-product once it has an enabled channel", () => {
    const status = computeProductStatus(products, {
      grantedScopes: ["scope.mail"],
      enabledChannelCount: { mail: 2 },
      locallyOff: {},
    });
    expect(status.find((s) => s.key === "mail")).toEqual({
      key: "mail",
      enabled: true,
      reason: "granted",
    });
  });

  it("enables a channelless product on scope alone (no channel required)", () => {
    const status = computeProductStatus(products, {
      ...base,
      grantedScopes: ["scope.contacts"],
    });
    expect(status.find((s) => s.key === "contacts")).toEqual({
      key: "contacts",
      enabled: true,
      reason: "granted",
    });
  });

  it("reports locally-off when the user turned a scoped product off", () => {
    const status = computeProductStatus(products, {
      grantedScopes: ["scope.contacts"],
      enabledChannelCount: {},
      locallyOff: { contacts: true },
    });
    expect(status.find((s) => s.key === "contacts")).toEqual({
      key: "contacts",
      enabled: false,
      reason: "locally-off",
    });
  });

  it("scope-missing takes precedence over locally-off", () => {
    const status = computeProductStatus(products, {
      grantedScopes: [],
      enabledChannelCount: {},
      locallyOff: { mail: true },
    });
    expect(status.find((s) => s.key === "mail")?.reason).toBe("scope-missing");
  });
});
