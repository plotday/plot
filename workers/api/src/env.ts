import { type RunMessage } from "./agent/tools/run";
import { type Broadcast } from "./state/broadcast";
import { type Callbacks } from "./state/callbacks";
import { type LogSubscriptions } from "./state/log-subscriptions";
import { type Storage } from "./state/storage";
import { type Usage } from "./state/usage";
import {
  type ActivityItem,
  type PriorityItem,
  type SessionItem,
  type UpdateItem,
} from "./types";

export type UpdateMessage = {
  type: "activity" | "priority" | "session";
  event?: "created" | "updated" | "deleted";
  item: UpdateItem;
  previous?: UpdateItem;
  agents: {
    id: string;
    environment: string;
    priority_agent_id: string;
    config?: any;
    version?: string;
  }[];
  users?: { user_id: string }[];
  timestamp?: number;
  table?: string;
};

// Specific typed versions for each item type
export type ActivityUpdateMessage = Omit<UpdateMessage, "type" | "item"> & {
  type: "activity";
  item: ActivityItem;
};

export type PriorityUpdateMessage = Omit<UpdateMessage, "type" | "item"> & {
  type: "priority";
  item: PriorityItem;
};

export type SessionUpdateMessage = Omit<UpdateMessage, "type" | "item"> & {
  type: "session";
  item: SessionItem;
};

export type LogMessage = {
  agentRootId: string;
  environment: "personal" | "private" | "review" | "public";
  severity: "log" | "error" | "warn" | "info";
  message: string;
  timestamp: number;
};

// Queue message type union for proper type handling
export type QueueMessage = RunMessage | UpdateMessage | LogMessage;

export type Bindings = {
  readonly API_HMAC_SECRET?: string;
  readonly SENTRY_DSN: string;

  readonly SUPABASE_URL: string;
  readonly SUPABASE_ANON_KEY: string;
  readonly SUPABASE_SERVICE_KEY: string;

  readonly AUTH_GOOGLE_ID: string;
  readonly AUTH_GOOGLE_IOS_ID: string;
  readonly AUTH_GOOGLE_ANDROID_ID: string;
  readonly AUTH_GOOGLE_SECRET: string;
  readonly AUTH_MICROSOFT_ID: string;
  readonly AUTH_MICROSOFT_SECRET: string;

  readonly STRIPE_SECRET_KEY: string;
  readonly STRIPE_WEBHOOK_SECRET: string;

  readonly API_ROOT: string;

  readonly AI_GATEWAY_ACCOUNT_ID: string;
  readonly AI_GATEWAY_ID: string;

  readonly LOADER: WorkerLoader;
  readonly RUN_QUEUE: Queue<RunMessage>;
  readonly UPDATES_QUEUE: Queue<UpdateMessage>;
  readonly AGENT_LOGS_QUEUE: Queue<LogMessage>;
  readonly AI: Ai;
  readonly STORAGE: DurableObjectNamespace<Storage>;
  readonly CALLBACKS: DurableObjectNamespace<Callbacks>;
  readonly BROADCAST: DurableObjectNamespace<Broadcast>;
  readonly USAGE: DurableObjectNamespace<Usage>;
  readonly LOG_SUBSCRIPTIONS: DurableObjectNamespace<LogSubscriptions>;
  readonly AGENT_MODULES_BUCKET: R2Bucket;
};
