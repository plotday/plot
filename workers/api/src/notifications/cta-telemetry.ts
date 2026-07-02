import { PostHog } from "posthog-node";

import type { Kysely } from "kysely";

import { exceptionFingerprintBeforeSend } from "@plotday/worker-util";

import type { DB } from "../db";
import type { Bindings } from "../env";

/**
 * Telemetry for the immediate, gate-bypassing CTA push (OTP / confirm). These
 * pushes deliberately skip every normal notify gate (importance, FYI,
 * notify-window) and write nothing to thread_notify_state, so before this they
 * were invisible — there was no way to measure OTP push volume or catch a
 * false-positive storm (a promo "Code: 1234" firing a login-code push). These
 * events close that blind spot and flag likely residual false positives.
 */

type CtaFacets = {
  format: string | null;
  reach: string | null;
  automation: string | null;
} | null;

function domainOf(email: string | null): string | null {
  if (!email) return null;
  const at = email.indexOf("@");
  return at === -1 ? null : email.slice(at + 1).toLowerCase() || null;
}

/**
 * Pure: build the PostHog property bag for one CTA push. A genuine one-time code
 * is transactional and directly addressed, so a CTA push on bulk-list /
 * promotion mail is a likely residual false positive worth surfacing.
 */
export function ctaPushProperties(
  kind: string,
  facets: CtaFacets,
  authorEmail: string | null,
): Record<string, unknown> {
  return {
    cta_kind: kind,
    facet_format: facets?.format ?? null,
    facet_reach: facets?.reach ?? null,
    facet_automation: facets?.automation ?? null,
    sender_domain: domainOf(authorEmail),
    likely_false_positive: facets?.reach === "list" || facets?.format === "promotion",
  };
}

/**
 * Fetch the thread's facets + author email and emit one `cta_push` event per
 * notified recipient. Best-effort: opens a dedicated PostHog client (this runs
 * in the twist-runtime note-create path, which has no request-scoped tracker)
 * and flushes on shutdown. Never throws.
 */
export async function emitCtaPushEvent(
  env: Bindings,
  db: Kysely<DB>,
  note: { id: string; threadId: string; cta: { kind: string } },
  recipientUserIds: string[],
): Promise<void> {
  if (!env.POSTHOG_API_KEY || recipientUserIds.length === 0) return;
  try {
    const thread = await db
      .selectFrom("thread")
      .leftJoin("contact", "contact.id", "thread.author_id")
      .select(["thread.facets as facets", "contact.email as authorEmail"])
      .where("thread.id", "=", note.threadId)
      .executeTakeFirst();

    const props = ctaPushProperties(
      note.cta.kind,
      (thread?.facets as CtaFacets) ?? null,
      thread?.authorEmail ?? null,
    );

    const postHog = new PostHog(env.POSTHOG_API_KEY, {
      host: env.POSTHOG_HOST,
      flushAt: 1,
      flushInterval: 0,
      before_send: exceptionFingerprintBeforeSend,
    });
    try {
      for (const userId of recipientUserIds) {
        postHog.capture({
          distinctId: userId,
          event: "cta_push",
          properties: { ...props, note_id: note.id, thread_id: note.threadId },
        });
      }
    } finally {
      await postHog.shutdown();
    }
  } catch {
    // Telemetry must never disrupt a time-sensitive push. Swallow.
  }
}
