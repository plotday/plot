import type { SupabaseClient } from "@plotday/db";

import type { ToolDependencies } from "..";
import type { Bindings } from "../../env";
import { type Callbacks } from "../../state/callbacks";
import { type LogSubscriptions } from "../../state/log-subscriptions";
import { type Storage } from "../../state/storage";
import { Agent } from "./agent";
import { AI } from "./ai";
import { Auth } from "./auth";
import { CallbackTool } from "./callback";
import { Plot } from "./plot";
import { Run } from "./run";
import { Store } from "./store";
import type { Tool } from "./tool";
import { Webhook } from "./webhook";

export function createTool(
  path: string[],
  spec: ToolDependencies,
  {
    agentId,
    environment,
    supabase,
    priorityId,
    priorityAgentId,
    storage,
    callbacks,
    logSubscriptions,
    env,
    ctx,
  }: {
    agentId: string;
    environment: string;
    supabase: SupabaseClient;
    priorityId: string;
    priorityAgentId: string;
    storage: DurableObjectNamespace<Storage>;
    callbacks: DurableObjectNamespace<Callbacks>;
    logSubscriptions: DurableObjectNamespace<LogSubscriptions>;
    env: Bindings;
    ctx: { exports: ExecutionContext["exports"] };
  }
): ToolDependencies {
  let tool: Tool | undefined;
  switch (spec.id) {
    case "Plot":
      tool = new Plot({
        supabase,
        priorityId,
        priorityAgentId,
      });
      break;
    case "AI":
      tool = new AI(env);
      break;
    case "Auth":
      tool = new Auth({
        path,
        store: new Store({
          path,
          storage,
          priorityAgentId,
        }),
        env,
        priorityAgentId,
        agentId,
        environment,
        callbacks,
      });
      break;
    case "Store":
      tool = new Store({
        path,
        storage,
        priorityAgentId,
      });
      break;
    case "Webhook":
      tool = new Webhook({
        path,
        callbacks,
        priorityAgentId,
        agentId,
        environment,
        baseUrl: env.API_ROOT,
      });
      break;
    case "Run":
      tool = new Run({
        path,
        callbacks,
        priorityAgentId,
        agentId,
        environment,
        queue: env.RUN_QUEUE,
      });
      break;
    case "CallbackTool":
      tool = new CallbackTool({
        callbacks,
        priorityAgentId,
        agentId,
        environment,
        path,
      });
      break;
    case "AgentManager":
      tool = new Agent({
        env,
        ctx,
        supabase,
        priorityAgentId,
        logSubscriptions,
      });
      break;
  }
  return {
    id: spec.id,
    tool: tool ?? undefined,
    dependencies: createTools(
      { path, dependencies: spec.dependencies ?? [] },
      {
        agentId,
        environment,
        supabase,
        priorityId,
        priorityAgentId,
        storage,
        callbacks,
        logSubscriptions,
        env,
        ctx,
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
    dependencies: ToolDependencies[];
  },
  {
    agentId,
    environment,
    supabase,
    priorityId,
    priorityAgentId,
    storage,
    callbacks,
    logSubscriptions,
    env,
    ctx,
  }: {
    agentId: string;
    environment: string;
    supabase: SupabaseClient;
    priorityId: string;
    priorityAgentId: string;
    storage: DurableObjectNamespace<Storage>;
    callbacks: DurableObjectNamespace<Callbacks>;
    logSubscriptions: DurableObjectNamespace<LogSubscriptions>;
    env: Bindings;
    ctx: { exports: ExecutionContext["exports"] };
  }
): ToolDependencies[] {
  const ret = dependencies.map((dep) =>
    createTool(path.concat([dep.id]), dep, {
      agentId,
      environment,
      supabase,
      priorityId,
      priorityAgentId,
      storage,
      callbacks,
      logSubscriptions,
      env,
      ctx,
    })
  );
  return ret;
}
