import { type Callback, CallbackTool } from "../agent/tools/callback";
import { type Bindings, type LogMessage } from "../env";

export async function processLogs(
  batch: MessageBatch<LogMessage>,
  env: Bindings
): Promise<void> {
  // Group logs by agent_root_id
  const logsByAgent = new Map<string, LogMessage[]>();

  for (const message of batch.messages) {
    const { agentRootId } = message.body;
    if (!logsByAgent.has(agentRootId)) {
      logsByAgent.set(agentRootId, []);
    }
    logsByAgent.get(agentRootId)!.push(message.body);
  }

  // Process each agent's logs
  for (const [agentRootId, logs] of logsByAgent.entries()) {
    try {
      // Get the LogSubscriptions Durable Object for this agent (sharded by agentRootId)
      const logSubscriptionsId = env.LOG_SUBSCRIPTIONS.idFromName(agentRootId);
      const logSubscriptions = env.LOG_SUBSCRIPTIONS.get(logSubscriptionsId);

      // Get subscribers for this agent
      const subscribers = await logSubscriptions.getSubscribers(agentRootId);

      if (subscribers.length === 0) {
        continue;
      }

      // Convert logs to the format expected by the callback
      const formattedLogs = logs.map((log) => ({
        timestamp: new Date(log.timestamp),
        environment: log.environment,
        severity: log.severity,
        message: log.message,
      }));

      // Call each subscriber
      for (const callbackToken of subscribers) {
        try {
          await CallbackTool.Call(
            env.CALLBACKS,
            callbackToken as Callback,
            formattedLogs
          );
        } catch (error) {
          console.error(`Failed to call log callback ${callbackToken}:`, error);
        }
      }
    } catch (error) {
      console.error(`Error processing logs for agent ${agentRootId}:`, error);
    }
  }
}
