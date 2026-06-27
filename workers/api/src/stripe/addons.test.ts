import { expect, it, vi } from "vitest";
import type Stripe from "stripe";
import { provisionAddonCredit, reconcileAddonQuantityDown, customerHasPaymentMethod, createAddonCheckoutSession, TWIST_ADDON, setTwistAddonQuantity } from "./addons";

function stubStripe(over: Record<string, unknown> = {}) {
  return {
    customers: { retrieve: vi.fn().mockResolvedValue({ invoice_settings: { default_payment_method: "pm_1" } }) },
    paymentMethods: { list: vi.fn().mockResolvedValue({ data: [{ id: "pm_1" }] }) },
    prices: { list: vi.fn().mockResolvedValue({ data: [{ id: "price_addon" }] }) },
    subscriptions: {
      create: vi.fn().mockResolvedValue({ id: "sub_new", items: { data: [{ id: "si_1", quantity: 1 }] } }),
      retrieve: vi.fn().mockResolvedValue({ id: "sub_x", items: { data: [{ id: "si_1", quantity: 1, price: { lookup_key: "addon_monthly" } }] } }),
      update: vi.fn().mockResolvedValue({ id: "sub_x", items: { data: [{ id: "si_1", quantity: 2 }] } }),
      cancel: vi.fn().mockResolvedValue({ id: "sub_x", status: "canceled" }),
    },
    ...over,
  } as unknown as Stripe;
}

it("customerHasPaymentMethod true when a default PM exists", async () => {
  expect(await customerHasPaymentMethod(stubStripe(), "cus_1")).toBe(true);
});

it("provisionAddonCredit creates a monthly add-on sub at qty 1 when none exists", async () => {
  const s = stubStripe();
  const r = await provisionAddonCredit({ stripe: s, customerId: "cus_1", addonSubscriptionId: null, scopeMetadata: { user_id: "u1" } });
  expect(r).toEqual({ subscriptionId: "sub_new", quantity: 1 });
  expect((s.subscriptions.create as any)).toHaveBeenCalledWith(expect.objectContaining({
    customer: "cus_1",
    metadata: expect.objectContaining({ type: "addon", user_id: "u1" }),
    proration_behavior: "always_invoice",
  }));
});

it("provisionAddonCredit bumps an existing add-on sub by 1", async () => {
  const s = stubStripe();
  const r = await provisionAddonCredit({ stripe: s, customerId: "cus_1", addonSubscriptionId: "sub_x", scopeMetadata: { user_id: "u1" } });
  expect(r.quantity).toBe(2);
  expect((s.subscriptions.update as any)).toHaveBeenCalledWith("sub_x", expect.objectContaining({
    items: [{ id: "si_1", quantity: 2 }], proration_behavior: "always_invoice",
  }));
});

it("reconcileAddonQuantityDown cancels the sub at activeCount 0", async () => {
  const s = stubStripe();
  const r = await reconcileAddonQuantityDown({ stripe: s, addonSubscriptionId: "sub_x", activeCount: 0 });
  expect(r).toEqual({ canceled: true, quantity: 0 });
  expect((s.subscriptions.cancel as any)).toHaveBeenCalledWith("sub_x", expect.objectContaining({ prorate: true }));
});

it("reconcileAddonQuantityDown sets quantity to activeCount when > 0 (decreasing)", async () => {
  const s = stubStripe();
  (s.subscriptions.retrieve as any).mockResolvedValue({ id: "sub_x", items: { data: [{ id: "si_1", quantity: 2, price: { lookup_key: "addon_monthly" } }] } });
  const r = await reconcileAddonQuantityDown({ stripe: s, addonSubscriptionId: "sub_x", activeCount: 1 });
  expect(r).toEqual({ canceled: false, quantity: 1 });
  expect((s.subscriptions.update as any)).toHaveBeenCalledWith("sub_x", expect.objectContaining({
    items: [{ id: "si_1", quantity: 1 }],
    proration_behavior: "always_invoice",
  }));
});

it("reconcileAddonQuantityDown does NOT increase quantity when activeCount exceeds current", async () => {
  const s = stubStripe();
  // stub retrieve returns quantity: 1 by default; calling with activeCount 3 must not trigger update
  const r = await reconcileAddonQuantityDown({ stripe: s, addonSubscriptionId: "sub_x", activeCount: 3 });
  expect(r).toEqual({ canceled: false, quantity: 1 });
  expect((s.subscriptions.update as any)).not.toHaveBeenCalled();
});

it("createAddonCheckoutSession returns checkout url with correct params", async () => {
  const s = stubStripe({
    checkout: { sessions: { create: vi.fn().mockResolvedValue({ url: "https://checkout.test/abc" }) } },
  });
  const url = await createAddonCheckoutSession({ stripe: s, customerId: "cus_1", siteRoot: "https://app.plot.day", scopeMetadata: { workspace_id: "w1" } });
  expect(url).toBe("https://checkout.test/abc");
  expect((s as any).checkout.sessions.create).toHaveBeenCalledWith(expect.objectContaining({
    mode: "subscription",
    subscription_data: expect.objectContaining({
      metadata: expect.objectContaining({ type: "addon" }),
    }),
  }));
});

it("customerHasPaymentMethod true via paymentMethods.list fallback when no default PM", async () => {
  const s = stubStripe();
  (s.customers.retrieve as any).mockResolvedValue({ invoice_settings: { default_payment_method: null } });
  expect(await customerHasPaymentMethod(s, "cus_1")).toBe(true);
});

it("customerHasPaymentMethod false when no default PM and empty list", async () => {
  const s = stubStripe();
  (s.customers.retrieve as any).mockResolvedValue({ invoice_settings: { default_payment_method: null } });
  (s.paymentMethods.list as any).mockResolvedValue({ data: [] });
  expect(await customerHasPaymentMethod(s, "cus_1")).toBe(false);
});

// --- TWIST_ADDON / setTwistAddonQuantity tests ---

it("setTwistAddonQuantity creates a twist sub at absolute quantity when none exists", async () => {
  const s = stubStripe({
    prices: { list: vi.fn().mockResolvedValue({ data: [{ id: "price_twist_addon" }] }) },
  });
  const r = await setTwistAddonQuantity({ stripe: s, customerId: "cus_1", twistAddonSubscriptionId: null, scopeMetadata: { workspace_id: "w1" }, quantity: 3 });
  expect(r).toEqual({ subscriptionId: "sub_new", quantity: 3 });
  expect((s.subscriptions.create as any)).toHaveBeenCalledWith(expect.objectContaining({
    customer: "cus_1",
    items: [{ price: "price_twist_addon", quantity: 3 }],
    metadata: expect.objectContaining({ type: "twist_addon", workspace_id: "w1" }),
    proration_behavior: "always_invoice",
  }));
  // Verify the twist_addon_monthly lookup key was used
  expect((s.prices.list as any)).toHaveBeenCalledWith(expect.objectContaining({
    lookup_keys: ["twist_addon_monthly"],
  }));
});

it("setTwistAddonQuantity updates existing sub to absolute quantity", async () => {
  const s = stubStripe();
  const r = await setTwistAddonQuantity({ stripe: s, customerId: "cus_1", twistAddonSubscriptionId: "sub_x", scopeMetadata: { workspace_id: "w1" }, quantity: 5 });
  expect(r).toEqual({ subscriptionId: "sub_x", quantity: 5 });
  expect((s.subscriptions.update as any)).toHaveBeenCalledWith("sub_x", expect.objectContaining({
    items: [{ id: "si_1", quantity: 5 }],
    proration_behavior: "always_invoice",
  }));
  // Should not call prices.list when sub already exists
  expect((s.prices.list as any)).not.toHaveBeenCalled();
});

it("createAddonCheckoutSession with TWIST_ADDON uses twist lookup key, metadata.type twist_addon, and ?twist_addon= urls", async () => {
  const s = stubStripe({
    prices: { list: vi.fn().mockResolvedValue({ data: [{ id: "price_twist_addon" }] }) },
    checkout: { sessions: { create: vi.fn().mockResolvedValue({ url: "https://checkout.test/twist" }) } },
  });
  const url = await createAddonCheckoutSession({ kind: TWIST_ADDON, stripe: s, customerId: "cus_1", siteRoot: "https://app.plot.day", scopeMetadata: { workspace_id: "w1" } });
  expect(url).toBe("https://checkout.test/twist");
  expect((s.prices.list as any)).toHaveBeenCalledWith(expect.objectContaining({
    lookup_keys: ["twist_addon_monthly"],
  }));
  expect((s as any).checkout.sessions.create).toHaveBeenCalledWith(expect.objectContaining({
    mode: "subscription",
    success_url: expect.stringContaining("?twist_addon=success"),
    cancel_url: expect.stringContaining("?twist_addon=canceled"),
    subscription_data: expect.objectContaining({
      metadata: expect.objectContaining({ type: "twist_addon" }),
    }),
  }));
});

it("createAddonCheckoutSession defaults to CONNECTION_ADDON (kind omitted) - uses addon lookup key and ?addon= urls", async () => {
  const s = stubStripe({
    checkout: { sessions: { create: vi.fn().mockResolvedValue({ url: "https://checkout.test/abc" }) } },
  });
  const url = await createAddonCheckoutSession({ stripe: s, customerId: "cus_1", siteRoot: "https://app.plot.day", scopeMetadata: { workspace_id: "w1" } });
  expect(url).toBe("https://checkout.test/abc");
  expect((s.prices.list as any)).toHaveBeenCalledWith(expect.objectContaining({
    lookup_keys: ["addon_monthly"],
  }));
  expect((s as any).checkout.sessions.create).toHaveBeenCalledWith(expect.objectContaining({
    success_url: expect.stringContaining("?addon=success"),
    cancel_url: expect.stringContaining("?addon=canceled"),
    subscription_data: expect.objectContaining({
      metadata: expect.objectContaining({ type: "addon" }),
    }),
  }));
});
