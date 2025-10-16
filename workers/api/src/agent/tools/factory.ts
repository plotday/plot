import type { SupabaseClient } from "@plotday/db";

import type { ToolDependencies } from "..";
import type { Bindings } from "../../env";
import { type Callbacks } from "../../state/callbacks";
import { type LogSubscriptions } from "../../state/log-subscriptions";
import { type Storage } from "../../state/storage";
import type { Tool } from "@plotday/sdk";
import { Agent } from "./agent";
import { AI } from "./ai";
import { Auth } from "./auth";
import { CallbackTool } from "./callback";
import { Plot } from "./plot";
import { Run } from "./run";
import { Store } from "./store";
import { Webhook } from "./webhook";

export type ToolDependencySpec = {
  id: string;
  tools?: ToolDependencySpec[];
};

export function createTool(
  path: string[],
  spec: ToolDependencySpec,
  {
    supabase,
    priorityId,
    priorityAgentId,
    storage,
    callbacks,
    logSubscriptions,
    env,
  }: {
    supabase: SupabaseClient;
    priorityId: string;
    priorityAgentId: string;
    storage: DurableObjectNamespace<Storage>;
    callbacks: DurableObjectNamespace<Callbacks>;
    logSubscriptions: DurableObjectNamespace<LogSubscriptions>;
    env: Bindings;
  }
): ToolDependencies {
  let tool: unknown = undefined;
  switch (spec.id) {
    case "plot":
      tool = new Plot({
        supabase,
        priorityId,
        priorityAgentId,
      });
      break;
    case "ai":
      tool = new AI({
        accountId: env.AI_GATEWAY_ACCOUNT_ID,
        gatewayId: env.AI_GATEWAY_ID,
        ai: env.AI,
      });
      break;
    case "auth":
      tool = new Auth({
        path,
        store: new Store({
          path,
          storage,
          priorityAgentId,
        }),
        env,
        priorityAgentId,
        callbacks,
      });
      break;
    case "store":
      tool = new Store({
        path: path.slice(0, -1),
        storage,
        priorityAgentId,
      });
      break;
    case "webhook":
      tool = new Webhook({
        path,
        callbacks,
        priorityAgentId,
        baseUrl: env.API_ROOT,
      });
      break;
    case "run":
      tool = new Run({
        path,
        callbacks,
        priorityAgentId,
        queue: env.RUN_QUEUE,
      });
      break;
    case "callback":
      tool = new CallbackTool({
        callbacks,
        priorityAgentId,
        path,
      });
      break;
    case "agent":
      tool = new Agent({
        supabase,
        priorityAgentId,
        logSubscriptions,
      });
      break;
  }
  // @ts-ignore - Type instantiation issue with ToolDependencies recursion
  return {
    id: spec.id,
    tool: tool as Tool | undefined,
    dependencies: createTools(
      { path, dependencies: spec.tools ?? [] },
      {
        supabase,
        priorityId,
        priorityAgentId,
        storage,
        callbacks,
        logSubscriptions,
        env,
      }
    ),
  };
}

export function createTools(
  {
    path,
    dependencies,
  }: {
    path: string[]; // path to the tool within the agent
    dependencies: ToolDependencySpec[];
  },
  {
    supabase,
    priorityId,
    priorityAgentId,
    storage,
    callbacks,
    logSubscriptions,
    env,
  }: {
    supabase: SupabaseClient;
    priorityId: string;
    priorityAgentId: string;
    storage: DurableObjectNamespace<Storage>;
    callbacks: DurableObjectNamespace<Callbacks>;
    logSubscriptions: DurableObjectNamespace<LogSubscriptions>;
    env: Bindings;
  }
): ToolDependencies[] {
  const ret = dependencies.map((dep) =>
    createTool(path.concat([dep.id]), dep, {
      supabase,
      priorityId,
      priorityAgentId,
      storage,
      callbacks,
      logSubscriptions,
      env,
    })
  );
  return ret;
}
