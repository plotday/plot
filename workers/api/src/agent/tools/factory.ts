import type { Tool, ToolDependencies } from "@plotday/agent";
import type { SupabaseClient } from "@plotday/db";

import type { AgentFactory } from "../../agent";
import { type Callbacks } from "../../callbacks";
import type { Bindings } from "../../env";
import { type Storage } from "../../storage";
import { AiTool } from "./ai";
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
    ai,
    priorityId,
    priorityAgentId,
    storage,
    callbacks,
    env,
    agents,
  }: {
    supabase: SupabaseClient;
    ai: Ai;
    priorityId: string;
    priorityAgentId: string;
    storage: DurableObjectNamespace<Storage>;
    callbacks: DurableObjectNamespace<Callbacks>;
    env: Bindings;
    agents: AgentFactory;
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
      tool = new AiTool({ ai });
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
  }
  return {
    id: spec.id,
    tool: tool as Tool | undefined,
    dependencies: createTools(
      { path, dependencies: spec.tools ?? [] },
      {
        supabase,
        ai,
        priorityId,
        priorityAgentId,
        storage,
        callbacks,
        env,
        agents,
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
    ai,
    priorityId,
    priorityAgentId,
    storage,
    callbacks,
    env,
    agents,
  }: {
    supabase: SupabaseClient;
    ai: Ai;
    priorityId: string;
    priorityAgentId: string;
    storage: DurableObjectNamespace<Storage>;
    callbacks: DurableObjectNamespace<Callbacks>;
    env: Bindings;
    agents: AgentFactory;
  }
): ToolDependencies[] {
  const ret = dependencies.map((dep) =>
    createTool(path.concat([dep.id]), dep, {
      supabase,
      ai,
      priorityId,
      priorityAgentId,
      storage,
      callbacks,
      env,
      agents,
    })
  );
  return ret;
}
