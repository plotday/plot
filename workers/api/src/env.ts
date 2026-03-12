import { type TwistBuilder } from "../";
import { type RunMessage } from "./twist/tools/tasks";
import { type Broadcast } from "./state/broadcast";
import { type CallbacksState } from "./state/callbacks";
import { type LogStream } from "./state/log-stream";
import { type LogSubscriptions } from "./state/log-subscriptions";
import { type SdkTokenStore } from "./state/sdk-token-store";
import { type Storage } from "./state/storage";
import { type TwistSync } from "./state/twist-sync";
import { type SyncNotify } from "./state/sync-notify";
import { type SyncRecovery } from "./state/sync-recovery";
import { type PrivacyReporting } from "./state/privacy-reporting";
import { type Usage } from "./state/usage";
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
 * Simple notification that tells clients to re-fetch data for a specific table.
 * No entity data is included - clients pull fresh data themselves.
 */
export type UserSyncMessage = {
  type: "sync";
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
  priorityTwistId: string;
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
  priorityTwist: any | null;
};

// Queue message type union for proper type handling
export type QueueMessage = RunMessage | TwistBatchMessage | LogMessage;

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

  readonly GCP_PROJECT_ID: string;
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

  readonly SYNC_TIMING_ENABLED?: string;

  readonly TWIST_CONFIG: KVNamespace;
  readonly VOTES: KVNamespace;

  // Rate Limiting Bindings
  readonly GENERAL_RATE_LIMITER: RateLimit;
  readonly AUTH_RATE_LIMITER: RateLimit;
  readonly TOKEN_RATE_LIMITER: RateLimit;
  readonly WEBHOOK_RATE_LIMITER: RateLimit;
  readonly SYNC_RATE_LIMITER: RateLimit;
  readonly APP_SYNC_RATE_LIMITER: RateLimit;
  readonly DEPLOYMENT_RATE_LIMITER: RateLimit;

  readonly TWIST_BUILDER: DurableObjectNamespace<TwistBuilder>;
  readonly LOADER: WorkerLoader;
  readonly RUN_QUEUE: Queue<RunMessage>;
  readonly UPDATES_QUEUE: Queue<TwistBatchMessage>;
  readonly TWIST_LOGS_QUEUE: Queue<LogMessage>;
  readonly MAIL_QUEUE: Queue<{
    to: string[];
    subject: string;
    email: string;
    props?: Record<string, unknown>;
  }>;
  readonly AI: Ai;
  readonly STORAGE: DurableObjectNamespace<Storage>;
  readonly CALLBACKS: DurableObjectNamespace<CallbacksState>;
  readonly BROADCAST: DurableObjectNamespace<Broadcast>;
  readonly USAGE: DurableObjectNamespace<Usage>;
  readonly LOG_SUBSCRIPTIONS: DurableObjectNamespace<LogSubscriptions>;
  readonly LOG_STREAM: DurableObjectNamespace<LogStream>;
  readonly SDK_TOKEN_STORE: DurableObjectNamespace<SdkTokenStore>;
  readonly USER_SYNC: DurableObjectNamespace<UserSync>;
  readonly TWIST_SYNC: DurableObjectNamespace<TwistSync>;
  readonly SYNC_NOTIFY: DurableObjectNamespace<SyncNotify>;
  readonly SYNC_RECOVERY: DurableObjectNamespace<SyncRecovery>;
  readonly PRIVACY_REPORTING: DurableObjectNamespace<PrivacyReporting>;
  readonly TWIST_MODULES_BUCKET: R2Bucket;
  readonly FILES_BUCKET: R2Bucket;
};
