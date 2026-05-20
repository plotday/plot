import { type EmailType } from "@plotday/email";

import { type TwistBuilder } from "../";
import { type RunMessage } from "./twist/tools/tasks";
import { type Broadcast } from "./state/broadcast";
import { type CallbacksState } from "./state/callbacks";
import { type ChannelRouter } from "./state/channel-router";
import { type LogStream } from "./state/log-stream";
import { type LogSubscriptions } from "./state/log-subscriptions";
import { type SdkTokenStore } from "./state/sdk-token-store";
import { type Storage } from "./state/storage";
import { type TwistSync } from "./state/twist-sync";
import { type EmailNotify } from "./state/email-notify";
import { type PushNotify } from "./state/push-notify";
import { type SyncNotify } from "./state/sync-notify";
import { type SyncRecovery } from "./state/sync-recovery";
import { type PrivacyReporting } from "./state/privacy-reporting";
import { type Usage } from "./state/usage";
import { type UserAiUsage } from "./state/user-ai-usage";
import { type UserSync } from "./state/user-sync";
import type {
  NoteCreate,
  NoteUpdate,
  ThreadUpdate,
  ThreadReadChange,
  ThreadScheduleChange,
  ScheduleContactChange,
  ChannelLinkCreate,
  ChannelLinkUpdate,
  ChannelNoteCreate,
} from "./twist/view-types";

export type TwistEnvironment = "personal" | "private" | "review" | "public";

/**
 * User sync broadcast message.
 * Simple notification that tells clients to re-fetch data for one or more
 * tables. No entity data is included — clients pull fresh data themselves.
 *
 * `tables` is the canonical field. `table` is the legacy single-entity field
 * kept for backwards compatibility with older clients; new code should read
 * `tables` (which always contains `table` as its first element).
 */
export type UserSyncMessage = {
  type: "sync";
  tables: string[];
  table: string;
};

export type LogMessage = {
  twistRootId: string;
  environment: TwistEnvironment;
  severity: "log" | "error" | "warn" | "info";
  message: string;
  timestamp: number;
};

/**
 * Tag change event for thread updates.
 * Aggregates tag additions/removals per thread for twist callbacks.
 */
export type ThreadTagChange = {
  threadId: string;
  occurrence: string | null;
  tagId: number;
  actorId: string;
  changeType: "added" | "removed";
};

/** @deprecated Use ThreadTagChange */
export type ActivityTagChange = ThreadTagChange;

/**
 * Batched twist update message.
 * Contains enriched entity data from database views for twist processing.
 * Uses view types that include JOINed fields like author_name, tags, etc.
 */
export type TwistBatchMessage = {
  type: "twist_batch";
  twistInstanceId: string;
  twistId: number;
  environment: TwistEnvironment;
  version: string;
  // Notes created on threads this twist created or was mentioned in
  newNotes: NoteCreate[];
  // Notes updated by this twist (for the update callback)
  updatedNotes: NoteUpdate[];
  // Threads updated that this twist created (for the update callback)
  updatedThreads: ThreadUpdate[];
  // Tag changes for building tagsAdded/tagsRemoved per thread
  threadTagChanges: ThreadTagChange[];
  // Links created in connected source channels
  channelNewLinks: ChannelLinkCreate[];
  // Links updated in connected source channels
  channelUpdatedLinks: ChannelLinkUpdate[];
  // Notes created on threads with links from connected channels
  channelNewNotes: ChannelNoteCreate[];
  // Thread read status changes for threads this twist created
  threadReads: ThreadReadChange[];
  // Thread schedule changes for threads this twist created (for onThreadToDo callback)
  threadSchedules: ThreadScheduleChange[];
  // Schedule contact changes for link schedules created by this twist (for onScheduleContactUpdated callback)
  scheduleContacts: ScheduleContactChange[];
  // Priority twist config changes
  twistInstance: any | null;
};

/**
 * Webhook callback message queued for async processing.
 *
 * Ingested by /hook/:token, /hook/gmail/:topicId, /hook/pubsub/:topicId,
 * and /hook/slack (one message per matching team callback). Consumed by
 * the webhook queue consumer, which dispatches through
 * `invokeWebhookCallback` so each message executes independently — no
 * shared blast radius, no shared retry fate.
 *
 * The consumer never inspects the callback's return value — callbacks that
 * need a synchronous response (e.g. Microsoft Graph validation echoes) must
 * register with `{ async: false }` so the SDK returns a /hook-sync/:token
 * URL instead.
 */
export type WebhookMessage = {
  type: "webhook";
  token: string;
  method: string;
  headers: Record<string, string>;
  params: Record<string, string>;
  // Optional because the generic /hook/:token producer omits it to avoid
  // duplicating rawBody (Cloudflare Queues caps messages at 128 KB). The
  // consumer re-parses body from rawBody + Content-Type when absent.
  body?: any;
  rawBody?: string;
};

// Queue message type union for proper type handling
export type QueueMessage =
  | RunMessage
  | TwistBatchMessage
  | LogMessage
  | WebhookMessage;

export type MailRequest = {
  to: string[];
  subject: string;
  email: EmailType;
  props?: Record<string, unknown>;
};

export type Bindings = {
  readonly HYPERDRIVE?: Hyperdrive;
  readonly DATABASE_URL?: string;
  readonly POSTHOG_API_KEY: string;
  readonly POSTHOG_HOST: string;

  // Clerk authentication
  readonly CLERK_SECRET_KEY: string;
  readonly CLERK_JWT_KEY: string; // Base64-encoded PEM public key for networkless JWT verification
  readonly CLERK_WEBHOOK_SIGNING_SECRET: string;

  readonly AUTH_GOOGLE_ID: string;
  readonly AUTH_GOOGLE_IOS_ID: string;
  readonly AUTH_GOOGLE_ANDROID_ID: string;
  readonly AUTH_GOOGLE_SECRET: string;
  readonly AUTH_MICROSOFT_ID: string;
  readonly AUTH_MICROSOFT_SECRET: string;
  readonly AUTH_NOTION_ID: string;
  readonly AUTH_NOTION_SECRET: string;
  readonly AUTH_SLACK_ID: string;
  readonly AUTH_SLACK_SECRET: string;
  readonly AUTH_SLACK_SIGNING_SECRET: string;
  readonly AUTH_ATLASSIAN_ID: string;
  readonly AUTH_ATLASSIAN_SECRET: string;
  readonly AUTH_LINEAR_ID: string;
  readonly AUTH_LINEAR_SECRET: string;
  readonly AUTH_MONDAY_ID: string;
  readonly AUTH_MONDAY_SECRET: string;
  readonly AUTH_GITHUB_ID: string;
  readonly AUTH_GITHUB_SECRET: string;
  readonly AUTH_ASANA_ID: string;
  readonly AUTH_ASANA_SECRET: string;
  readonly AUTH_HUBSPOT_ID: string;
  readonly AUTH_HUBSPOT_SECRET: string;
  readonly AUTH_AIRTABLE_ID: string;
  readonly AUTH_AIRTABLE_SECRET: string;

  // Sign in with Apple — used to revoke OAuth tokens on account deletion
  // (App Store guideline 5.1.1(v)).
  readonly AUTH_APPLE_NATIVE_CLIENT_ID: string;
  readonly AUTH_APPLE_WEB_CLIENT_ID: string;
  readonly AUTH_APPLE_TEAM_ID: string;
  readonly AUTH_APPLE_KEY_ID: string;
  readonly AUTH_APPLE_PRIVATE_KEY: string;

  readonly GCP_PROJECT_ID: string;
  readonly GCP_PROJECT_NUMBER: string;
  readonly GCP_SERVICE_ACCOUNT_EMAIL: string;
  readonly GCP_SERVICE_ACCOUNT_KEY: string;

  readonly STRIPE_SECRET_KEY: string;
  readonly STRIPE_WEBHOOK_SECRET: string;

  readonly RESEND_API_KEY: string;

  readonly API_ROOT: string;
  readonly APP_ROOT: string;
  readonly SITE_ROOT: string;

  readonly AI_GATEWAY_ACCOUNT_ID: string;
  readonly AI_GATEWAY_ID: string;
  readonly AI_GATEWAY_TOKEN: string;
  // Can hopefully remove this once we can use the Vercel AI SDK with Cloudflare AI Gateway without requiring an API key.
  readonly ANTHROPIC_API_KEY: string;

  // 256-bit hex key for encrypting user-provided AI API keys at rest (AES-256-GCM)
  readonly AI_KEY_ENCRYPTION_KEY: string;

  // Bearer token gating /admin/* endpoints (e.g. on-demand refreshAllChannels).
  readonly ADMIN_API_KEY?: string;

  readonly SYNC_TIMING_ENABLED?: string;
  readonly NOTIFICATION_DELAY_MULTIPLIER?: string;

  readonly TWIST_CONFIG: KVNamespace;
  readonly VOTES: KVNamespace;
  // Shared between workers/api and workers/classify. Holds the LLM
  // response cache (llm-classify:*) and per-user daily budget counters
  // (llm-budget:*). See libs/classifier-runtime.
  readonly LLM_CACHE: KVNamespace;
  // Google Gemini API key used by the production classifier.
  readonly GOOGLE_GENERATIVE_AI_API_KEY: string;

  // Rate Limiting Bindings
  readonly GENERAL_RATE_LIMITER: RateLimit;
  readonly AUTH_RATE_LIMITER: RateLimit;
  readonly TOKEN_RATE_LIMITER: RateLimit;
  readonly WEBHOOK_RATE_LIMITER: RateLimit;
  readonly WEBHOOK_ASYNC_RATE_LIMITER: RateLimit;
  readonly SYNC_RATE_LIMITER: RateLimit;
  readonly APP_SYNC_RATE_LIMITER: RateLimit;
  readonly DEPLOYMENT_RATE_LIMITER: RateLimit;
  readonly SDK_RATE_LIMITER: RateLimit;
  // Per-channel Voyager call throttle. Key by channelId so each LinkedIn
  // connection has its own bucket (6 calls per 10s) — a single user's burst
  // can't trigger LinkedIn-side throttling for other users.
  readonly LINKEDIN_RATE_LIMITER: RateLimit;

  readonly TWIST_BUILDER: DurableObjectNamespace<TwistBuilder>;
  readonly LOADER: WorkerLoader;
  readonly RUN_QUEUE: Queue<RunMessage>;
  readonly UPDATES_QUEUE: Queue<TwistBatchMessage>;
  readonly TWIST_LOGS_QUEUE: Queue<LogMessage>;
  readonly WEBHOOK_QUEUE: Queue<WebhookMessage>;
  readonly MAIL_QUEUE: Queue<MailRequest>;
  // Producer side of the classify-thread queue; consumer is workers/classify.
  readonly QUEUE_CLASSIFY: Queue<{ userId: string; threadId: string }>;
  readonly AI: Ai;
  readonly STORAGE: DurableObjectNamespace<Storage>;
  readonly CALLBACKS: DurableObjectNamespace<CallbacksState>;
  readonly BROADCAST: DurableObjectNamespace<Broadcast>;
  readonly USAGE: DurableObjectNamespace<Usage>;
  readonly USER_AI_USAGE: DurableObjectNamespace<UserAiUsage>;
  readonly LOG_SUBSCRIPTIONS: DurableObjectNamespace<LogSubscriptions>;
  readonly LOG_STREAM: DurableObjectNamespace<LogStream>;
  readonly SDK_TOKEN_STORE: DurableObjectNamespace<SdkTokenStore>;
  readonly USER_SYNC: DurableObjectNamespace<UserSync>;
  readonly TWIST_SYNC: DurableObjectNamespace<TwistSync>;
  readonly PUSH_NOTIFY: DurableObjectNamespace<PushNotify>;
  readonly EMAIL_NOTIFY: DurableObjectNamespace<EmailNotify>;
  readonly SYNC_NOTIFY: DurableObjectNamespace<SyncNotify>;
  readonly SYNC_RECOVERY: DurableObjectNamespace<SyncRecovery>;
  readonly PRIVACY_REPORTING: DurableObjectNamespace<PrivacyReporting>;
  readonly CHANNEL_ROUTER: DurableObjectNamespace<ChannelRouter>;
  readonly TWIST_MODULES_BUCKET: R2Bucket;
  readonly FILES_BUCKET: R2Bucket;
};
