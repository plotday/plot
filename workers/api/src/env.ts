import { type AgentBuilder } from "../";
import { type RunMessage } from "./agent/tools/tasks";
import { type Broadcast } from "./state/broadcast";
import { type CallbacksState } from "./state/callbacks";
import { type LogStream } from "./state/log-stream";
import { type LogSubscriptions } from "./state/log-subscriptions";
import { type Storage } from "./state/storage";
import { type Usage } from "./state/usage";
import {
  type ActivityItem,
  type PriorityItem,
  type SessionItem,
  type UpdateItem,
} from "./types";

export type AgentEnvironment = "personal" | "private" | "review" | "public";

export type UpdateMessage = {
  type: "activity" | "priority" | "session";
  event?: "created" | "updated" | "deleted";
  item: UpdateItem;
  previous?: UpdateItem;
  agents: {
    id: string;
    environment: AgentEnvironment;
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
  environment: AgentEnvironment;
  severity: "log" | "error" | "warn" | "info";
  message: string;
  timestamp: number;
};

// Queue message type union for proper type handling
export type QueueMessage = RunMessage | UpdateMessage | LogMessage;

export type Bindings = {
  readonly API_HMAC_SECRET?: string;
  readonly POSTHOG_API_KEY: string;
  readonly POSTHOG_HOST: string;

  readonly SUPABASE_URL: string;
  readonly SUPABASE_ANON_KEY: string;
  readonly SUPABASE_SERVICE_KEY: string;

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

  readonly STRIPE_SECRET_KEY: string;
  readonly STRIPE_WEBHOOK_SECRET: string;

  readonly API_ROOT: string;

  readonly AI_GATEWAY_ACCOUNT_ID: string;
  readonly AI_GATEWAY_ID: string;
  readonly AI_GATEWAY_TOKEN: string;
  // Can hopefully remove this once we can use the Vercel AI SDK with Cloudflare AI Gateway without requiring an API key.
  readonly ANTHROPIC_API_KEY: string;

  readonly AGENT_CONFIG: KVNamespace;

  readonly AGENT_BUILDER: DurableObjectNamespace<AgentBuilder>;
  readonly LOADER: WorkerLoader;
  readonly RUN_QUEUE: Queue<RunMessage>;
  readonly UPDATES_QUEUE: Queue<UpdateMessage>;
  readonly AGENT_LOGS_QUEUE: Queue<LogMessage>;
  readonly AI: Ai;
  readonly STORAGE: DurableObjectNamespace<Storage>;
  readonly CALLBACKS: DurableObjectNamespace<CallbacksState>;
  readonly BROADCAST: DurableObjectNamespace<Broadcast>;
  readonly USAGE: DurableObjectNamespace<Usage>;
  readonly LOG_SUBSCRIPTIONS: DurableObjectNamespace<LogSubscriptions>;
  readonly LOG_STREAM: DurableObjectNamespace<LogStream>;
  readonly AGENT_MODULES_BUCKET: R2Bucket;
};
