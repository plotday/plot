import Stripe from "stripe";

/**
 * Initialize Stripe client with API key
 */
export function createStripeClient(apiKey: string): Stripe {
  return new Stripe(apiKey, {
    apiVersion: "2025-02-24.acacia",
    // Cloudflare Workers compatible fetch
    httpClient: Stripe.createFetchHttpClient(),
  });
}

/**
 * Verify Stripe webhook signature
 */
export async function verifyWebhookSignature(
  stripe: Stripe,
  payload: string,
  signature: string,
  secret: string
): Promise<Stripe.Event> {
  return stripe.webhooks.constructEventAsync(payload, signature, secret);
}

/**
 * Create a Stripe customer for a new user
 */
export async function createStripeCustomer(
  stripe: Stripe,
  {
    userId,
    email,
    name,
  }: {
    userId: string;
    email: string;
    name?: string;
  }
): Promise<Stripe.Customer> {
  return await stripe.customers.create({
    email,
    name,
    metadata: {
      user_id: userId,
    },
  });
}

/**
 * Create a free tier "subscription" (no actual Stripe subscription, just tracking)
 * Returns billing cycle dates (monthly from now)
 */
export function createFreeTierBillingCycle(): {
  start: Date;
  end: Date;
} {
  const start = new Date();
  const end = new Date(start);
  end.setMonth(end.getMonth() + 1);

  return { start, end };
}

/**
 * Get subscription status from Stripe subscription object
 */
export function mapStripeStatus(
  status: Stripe.Subscription.Status
):
  | "active"
  | "canceled"
  | "past_due"
  | "trialing"
  | "incomplete"
  | "incomplete_expired"
  | "unpaid" {
  // Stripe statuses map directly to our enum
  const validStatuses = [
    "active",
    "canceled",
    "past_due",
    "trialing",
    "incomplete",
    "incomplete_expired",
    "unpaid",
  ] as const;

  if (validStatuses.includes(status as any)) {
    return status as any;
  }

  // Default to active for unknown statuses
  return "active";
}

/**
 * Extract billing cycle dates from Stripe subscription
 */
export function getBillingCycleDates(subscription: Stripe.Subscription): {
  start: Date;
  end: Date;
} {
  const start = subscription.current_period_start
    ? new Date(subscription.current_period_start * 1000)
    : new Date();
  const end = subscription.current_period_end
    ? new Date(subscription.current_period_end * 1000)
    : new Date();
  return { start, end };
}

/**
 * Check if an error is a Stripe "No such customer" error
 */
export function isCustomerDeletedError(error: unknown): boolean {
  return (
    error instanceof Stripe.errors.StripeInvalidRequestError &&
    error.code === "resource_missing" &&
    typeof error.message === "string" &&
    error.message.includes("No such customer")
  );
}

/**
 * Create a free tier subscription in Stripe. Used to reinstate billing
 * tracking after a paid sub is cancelled (or a trial ends without payment).
 */
export async function createFreeSubscription(
  stripe: Stripe,
  {
    customerId,
    userId,
  }: {
    customerId: string;
    userId: string;
  }
): Promise<Stripe.Subscription> {
  const prices = await stripe.prices.list({
    lookup_keys: ["free_monthly"],
    limit: 1,
  });

  if (!prices.data.length) {
    throw new Error(
      'Price with lookup key "free_monthly" not found in Stripe. Please create it first.'
    );
  }

  return await stripe.subscriptions.create({
    customer: customerId,
    items: [{ price: prices.data[0].id }],
    metadata: {
      user_id: userId,
      plan: "free",
    },
  });
}

/**
 * Create the initial subscription for a brand-new user: a 30-day Stripe-native
 * trial of the Core plan with no card collected up front. If the user adds a
 * payment method during the trial, Stripe converts to active billing
 * automatically. If they don't, Stripe cancels the sub at trial end and
 * customer.subscription.deleted fires so we can downgrade to free.
 *
 * Stripe drives all the timing (trial_will_end fires 3 days before, deleted
 * fires at expiry) — no Durable Object scheduling needed on our side.
 */
export async function createInitialTrialSubscription(
  stripe: Stripe,
  {
    customerId,
    userId,
  }: {
    customerId: string;
    userId: string;
  }
): Promise<Stripe.Subscription> {
  const prices = await stripe.prices.list({
    lookup_keys: ["free_monthly"],
    limit: 1,
  });

  if (!prices.data.length) {
    throw new Error(
      'Price with lookup key "free_monthly" not found in Stripe. Please create it first.'
    );
  }

  return await stripe.subscriptions.create({
    customer: customerId,
    items: [{ price: prices.data[0].id }],
    trial_period_days: 30,
    payment_settings: {
      save_default_payment_method: "on_subscription",
    },
    trial_settings: {
      end_behavior: { missing_payment_method: "cancel" },
    },
    metadata: {
      user_id: userId,
      plan: "free",
    },
  });
}
