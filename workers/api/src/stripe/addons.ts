import type Stripe from "stripe";

const ADDON_PRORATION = "always_invoice" as const;

export type AddonKind = {
  lookupKey: string;
  metadataType: string;
  priceMissingError: string;
};

export const CONNECTION_ADDON: AddonKind = {
  lookupKey: "addon_monthly",
  metadataType: "addon",
  priceMissingError: "addon_monthly price not configured",
};

export const TWIST_ADDON: AddonKind = {
  lookupKey: "twist_addon_monthly",
  metadataType: "twist_addon",
  priceMissingError: "twist_addon_monthly price not configured",
};

export async function customerHasPaymentMethod(stripe: Stripe, customerId: string): Promise<boolean> {
  const customer = await stripe.customers.retrieve(customerId);
  if (!customer.deleted && customer.invoice_settings?.default_payment_method) return true;
  const pms = await stripe.paymentMethods.list({ customer: customerId, type: "card", limit: 1 });
  return pms.data.length > 0;
}

async function addonPriceId(stripe: Stripe, kind: AddonKind): Promise<string> {
  const prices = await stripe.prices.list({ lookup_keys: [kind.lookupKey], limit: 1 });
  if (prices.data.length === 0) throw new Error(kind.priceMissingError);
  return prices.data[0].id;
}

export async function provisionAddonCredit(args: {
  stripe: Stripe; customerId: string; addonSubscriptionId: string | null;
  scopeMetadata: Record<string, string>;
}): Promise<{ subscriptionId: string; quantity: number }> {
  const { stripe, customerId, addonSubscriptionId, scopeMetadata } = args;
  if (addonSubscriptionId) {
    const sub = await stripe.subscriptions.retrieve(addonSubscriptionId);
    const item = sub.items.data[0];
    const quantity = (item.quantity ?? 1) + 1;
    await stripe.subscriptions.update(addonSubscriptionId, {
      items: [{ id: item.id, quantity }],
      proration_behavior: ADDON_PRORATION,
    });
    return { subscriptionId: addonSubscriptionId, quantity };
  }
  const price = await addonPriceId(stripe, CONNECTION_ADDON);
  const sub = await stripe.subscriptions.create({
    customer: customerId,
    items: [{ price, quantity: 1 }],
    proration_behavior: ADDON_PRORATION,
    metadata: { type: "addon", ...scopeMetadata },
  });
  return { subscriptionId: sub.id, quantity: 1 };
}

export async function reconcileAddonQuantityDown(args: {
  stripe: Stripe; addonSubscriptionId: string; activeCount: number;
}): Promise<{ canceled: boolean; quantity: number }> {
  const { stripe, addonSubscriptionId, activeCount } = args;
  if (activeCount <= 0) {
    await stripe.subscriptions.cancel(addonSubscriptionId, { prorate: true });
    return { canceled: true, quantity: 0 };
  }
  const sub = await stripe.subscriptions.retrieve(addonSubscriptionId);
  const item = sub.items.data[0];
  const currentQuantity = item.quantity ?? 1;
  if (activeCount >= currentQuantity) {
    // Never increase via this down-only path — return the current quantity unchanged.
    return { canceled: false, quantity: currentQuantity };
  }
  await stripe.subscriptions.update(addonSubscriptionId, {
    items: [{ id: item.id, quantity: activeCount }],
    proration_behavior: ADDON_PRORATION,
  });
  return { canceled: false, quantity: activeCount };
}

export async function setTwistAddonQuantity(args: {
  stripe: Stripe; customerId: string; twistAddonSubscriptionId: string | null;
  scopeMetadata: Record<string, string>; quantity: number;
}): Promise<{ subscriptionId: string; quantity: number }> {
  const { stripe, customerId, twistAddonSubscriptionId, scopeMetadata, quantity } = args;
  if (twistAddonSubscriptionId) {
    const sub = await stripe.subscriptions.retrieve(twistAddonSubscriptionId);
    const item = sub.items.data[0];
    await stripe.subscriptions.update(twistAddonSubscriptionId, {
      items: [{ id: item.id, quantity }],
      proration_behavior: ADDON_PRORATION,
    });
    return { subscriptionId: twistAddonSubscriptionId, quantity };
  }
  const price = await addonPriceId(stripe, TWIST_ADDON);
  const sub = await stripe.subscriptions.create({
    customer: customerId,
    items: [{ price, quantity }],
    proration_behavior: ADDON_PRORATION,
    metadata: { type: "twist_addon", ...scopeMetadata },
  });
  return { subscriptionId: sub.id, quantity };
}

export async function createAddonCardSetupSession(args: {
  stripe: Stripe; customerId: string; siteRoot: string; scopeMetadata: Record<string, string>;
}): Promise<string> {
  const { stripe, customerId, siteRoot, scopeMetadata } = args;
  const session = await stripe.checkout.sessions.create({
    customer: customerId,
    mode: "setup",
    success_url: `${siteRoot}/upgrade?addon=card_saved`,
    cancel_url: `${siteRoot}/upgrade?addon=canceled`,
    setup_intent_data: { metadata: { type: "addon_card", ...scopeMetadata } },
  });
  if (!session.url) throw new Error("Setup session has no url");
  return session.url;
}

export async function createAddonCheckoutSession(args: {
  kind?: AddonKind; stripe: Stripe; customerId: string; siteRoot: string; scopeMetadata: Record<string, string>;
}): Promise<string> {
  const { kind = CONNECTION_ADDON, stripe, customerId, siteRoot, scopeMetadata } = args;
  const price = await addonPriceId(stripe, kind);
  const param = kind.metadataType;
  const session = await stripe.checkout.sessions.create({
    customer: customerId,
    line_items: [{ price, quantity: 1 }],
    mode: "subscription",
    success_url: `${siteRoot}/upgrade?${param}=success`,
    cancel_url: `${siteRoot}/upgrade?${param}=canceled`,
    subscription_data: { metadata: { type: kind.metadataType, ...scopeMetadata } },
  });
  if (!session.url) throw new Error("Checkout session has no url");
  return session.url;
}
