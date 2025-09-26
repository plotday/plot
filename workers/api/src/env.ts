import { type RunMessage } from "./agent/tools/run";
import { type Broadcast } from "./broadcast";
import { type Callbacks } from "./callbacks";
import { type Storage } from "./storage";
import { type UpdateItem, type ActivityItem, type PriorityItem, type SessionItem } from "./types";

export type UpdateMessage = {
  type: "activity" | "priority" | "session";
  event?: "created" | "updated" | "deleted";
  item: UpdateItem;
  agents: {
    agent_id: string;
    priority_agent_id: string;
    config?: any;
    tools?: any;
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

// Queue message type union for proper type handling
export type QueueMessage = RunMessage | UpdateMessage;

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

  readonly API_ROOT: string;

  readonly RUN_QUEUE: Queue<RunMessage>;
  readonly UPDATES_QUEUE: Queue<UpdateMessage>;
  readonly AI: Ai;
  readonly AGENTS: DispatchNamespace;
  readonly STORAGE: DurableObjectNamespace<Storage>;
  readonly CALLBACKS: DurableObjectNamespace<Callbacks>;
  readonly BROADCAST: DurableObjectNamespace<Broadcast>;
};
