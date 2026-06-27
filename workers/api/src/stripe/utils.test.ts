/**
 * Tests for stripe/utils.ts — createInitialTrialSubscription.
 *
 * TDD tests written BEFORE implementing Task 2 changes (RED → implement → GREEN).
 * These verify the function uses the free_monthly price and sets plan:'free'
 * in subscription metadata instead of the old core_monthly / plan:'core'.
 */

import { describe, expect, it, vi } from "vitest";

import { createInitialTrialSubscription } from "./utils";
import type Stripe from "stripe";

// ---------------------------------------------------------------------------
// Tests: createInitialTrialSubscription uses free_monthly + plan:'free'
// ---------------------------------------------------------------------------

describe("createInitialTrialSubscription", () => {
  it("looks up 'free_monthly' price (not 'core_monthly')", async () => {
    const pricesList = vi.fn(async () => ({
      data: [{ id: "price_free_test" }],
    }));
    const subscriptionsCreate = vi.fn(async (params: Stripe.SubscriptionCreateParams) => ({
      id: "sub_trial_test",
      ...params,
    }));

    const fakeStripe = {
      prices: { list: pricesList },
      subscriptions: { create: subscriptionsCreate },
    } as unknown as Stripe;

    await createInitialTrialSubscription(fakeStripe, {
      customerId: "cus_test",
      userId: "user-uuid",
    });

    // Must request the FREE price, not core
    expect(pricesList).toHaveBeenCalledWith(
      expect.objectContaining({ lookup_keys: ["free_monthly"] })
    );
    expect(pricesList).not.toHaveBeenCalledWith(
      expect.objectContaining({ lookup_keys: ["core_monthly"] })
    );
  });

  it("sets metadata plan:'free' (not 'core')", async () => {
    const subscriptionsCreate = vi.fn(async (params: Stripe.SubscriptionCreateParams) => ({
      id: "sub_trial_test",
      ...params,
    }));

    const fakeStripe = {
      prices: {
        list: vi.fn(async () => ({ data: [{ id: "price_free_test" }] })),
      },
      subscriptions: { create: subscriptionsCreate },
    } as unknown as Stripe;

    await createInitialTrialSubscription(fakeStripe, {
      customerId: "cus_test",
      userId: "user-uuid",
    });

    const callArg = subscriptionsCreate.mock.calls[0][0] as Stripe.SubscriptionCreateParams;
    expect(callArg.metadata?.plan).toBe("free");
    expect(callArg.metadata?.plan).not.toBe("core");
  });

  it("still sets trial_period_days: 30 and missing_payment_method: 'cancel'", async () => {
    const subscriptionsCreate = vi.fn(async (params: Stripe.SubscriptionCreateParams) => ({
      id: "sub_trial_test",
      ...params,
    }));

    const fakeStripe = {
      prices: {
        list: vi.fn(async () => ({ data: [{ id: "price_free_test" }] })),
      },
      subscriptions: { create: subscriptionsCreate },
    } as unknown as Stripe;

    await createInitialTrialSubscription(fakeStripe, {
      customerId: "cus_test",
      userId: "user-uuid",
    });

    const callArg = subscriptionsCreate.mock.calls[0][0] as Stripe.SubscriptionCreateParams;
    expect(callArg.trial_period_days).toBe(30);
    expect(
      (callArg.trial_settings as any)?.end_behavior?.missing_payment_method
    ).toBe("cancel");
  });

  it("throws a helpful error when free_monthly price is not found", async () => {
    const fakeStripe = {
      prices: { list: vi.fn(async () => ({ data: [] })) },
      subscriptions: { create: vi.fn() },
    } as unknown as Stripe;

    await expect(
      createInitialTrialSubscription(fakeStripe, {
        customerId: "cus_test",
        userId: "user-uuid",
      })
    ).rejects.toThrow(/free_monthly/);
  });
});
