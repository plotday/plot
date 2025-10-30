import {
  ActivityType,
  Agent,
  type NewActivity,
  type Priority,
  type ToolBuilder,
} from "@plotday/agent";
import { Agents, type Log } from "@plotday/agent/tools/agents";
import { Plot } from "@plotday/agent/tools/plot";

export default class AgentBuilderAgent extends Agent<AgentBuilderAgent> {
  build(build: ToolBuilder) {
    return {
      plot: build(Plot),
      agent: build(Agents),
    };
  }

  async activate(_priority: Pick<Priority, "id">) {
    // Generate unique Agent ID
    const agentId = await this.tools.agent.create();

    // Post first activity with getting started instructions
    await this.tools.plot.createActivity({
      type: ActivityType.Note,
      title: "Getting Started",
      note: `Let's build something great!

Plot agents are written in TypeScript and run remotely.

To get started:

1. Run \`npx @plotday/agent agent create\` in your terminal.
2. Edit the generated agent code in the \`src/index.ts\` file.
3. Upload your agent using \`npm deploy\`.
4. Add your agent to a priority in the app to test it.`,
    });

    const logsCallback = await this.callback(this.onLogs);
    await this.tools.agent.watchLogs(agentId, logsCallback);
  }

  async onLogs(logs: Log[]): Promise<void> {
    // Group logs by environment
    const logsByEnvironment = new Map<string, Log[]>();
    for (const log of logs) {
      if (!logsByEnvironment.has(log.environment)) {
        logsByEnvironment.set(log.environment, []);
      }
      logsByEnvironment.get(log.environment)!.push(log);
    }

    // Get stored parent activity IDs
    const parentIds =
      ((await this.tools.store.get("log_parent_ids")) as Record<
        string,
        string
      > | null) ?? {};

    // Create/update parent activities and child logs for each environment
    for (const [environment, envLogs] of logsByEnvironment.entries()) {
      // Get or create parent activity for this environment
      let parentId = parentIds[environment];
      if (!parentId) {
        const parentActivity = await this.tools.plot.createActivity({
          type: ActivityType.Note,
          title: `Agent Logs (${environment})`,
          note: `Console logs from ${environment} environment`,
        });
        parentId = parentActivity.id;
        parentIds[environment] = parentId;
        await this.tools.store.set("log_parent_ids", parentIds);
      }

      // Create child activities for all logs in this batch
      const childActivities: NewActivity[] = envLogs.map((log) => ({
        type: ActivityType.Note,
        title: `[${log.severity}] ${log.message.substring(0, 50)}${
          log.message.length > 50 ? "..." : ""
        }`,
        note: log.message,
        start: log.timestamp,
        parent: { id: parentId },
      }));

      // Batch create all log activities
      await this.tools.plot.createActivities(childActivities);
    }
  }
}
