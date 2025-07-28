import type {
  ToolDependency,
  ToolForDependency,
} from "@plotday/agents/framework";
import type { SupabaseClient } from "@plotday/db";

import { AiImpl } from "./ai";
import { Plot } from "./plot";

export function createTools({
  dependencies,
  supabase,
  ai,
  priorityId,
  priorityAgentId,
  config,
}: {
  dependencies: ToolDependency[];
  supabase: SupabaseClient;
  ai: Ai;
  priorityId: string;
  priorityAgentId: string;
  config: Record<string, string>;
}): ToolForDependency[] {
  return dependencies.map((dependency) => {
    let tool: unknown;

    switch (dependency.id) {
      case "plot":
        tool = new Plot({
          supabase,
          priorityId,
          priorityAgentId,
          config,
        });
        break;
      case "ai":
        tool = new AiImpl({ ai });
        break;
      default:
        // Leave other dependencies unset
        break;
    }

    return {
      tool,
      dependency,
    };
  });
}
