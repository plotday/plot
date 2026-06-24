/**
 * Pure classification of inbound Unipile webhook events. Kept in its own module
 * (no heavy imports) so it is cheaply unit-testable without loading the whole
 * webhook-handler dependency graph.
 */

export type HostedWebhookEvent = {
  /** v2 core event shape uses `type` (dot-notation). v1 used `event_type`. */
  type?: string;
  event_type?: string;
  /** Hosted-auth notify_url shape: "CREATION_SUCCESS" / "CREATION_ERROR" /
   * "RECONNECTED" / "CHECKPOINT" / "CREDENTIALS". */
  status?: string;
  /** Some Unipile shapes use snake_case, others use PascalCase. */
  account_id?: string;
  AccountId?: string;
  /** Hosted-auth notify_url echoes the `name` we set when creating the link. */
  name?: string;
  provider?: string;
  payload?: Record<string, unknown>;
  [k: string]: unknown;
};

export type EventDispatch =
  | "account.connected"
  | "account.needs_reauth"
  | "messaging.new_message"
  | "users.invitation.received"
  | "users.new_relation";

/**
 * Map an inbound payload to one of our dispatch kinds. Tolerates the v2 core
 * event shape (`type`-driven, dot-notation), the v1 workspace webhook shape
 * (`event_type`-driven), and the hosted-auth notify_url shape (`status`-driven).
 */
export function classifyEvent(event: HostedWebhookEvent): EventDispatch | null {
  // v2 core events carry the kind in `type` (dot-notation); v1 used `event_type`.
  const t = (event.type as string | undefined) ?? event.event_type;

  // v2 dot-notation events:
  if (t === "message.new") return "messaging.new_message";
  if (t === "account.add" || t === "account.reconnect") return "account.connected";
  if (
    t === "account.status.disconnected" ||
    t === "account.status.errored" ||
    t === "account.status.credentials"
  ) {
    return "account.needs_reauth";
  }
  // A new 1st-degree connection. v2 fires relation.new and/or
  // relation.request.accept (an invitation we sent was accepted).
  if (
    t === "relation.new" ||
    t === "relation.request.accept" ||
    t === "users.new_relation"
  ) {
    return "users.new_relation";
  }
  // NOTE: v2 has no "invitation received" webhook event — received invitations
  // are pulled via listReceivedInvitations. The v1 name is kept only so a
  // straggling v1 delivery during cutover still routes correctly.
  if (t === "users.invitation.received") {
    return "users.invitation.received";
  }

  // v1 fallbacks (kept until the production cutover completes):
  if (t === "account.connected") return "account.connected";
  if (t === "account.disconnected" || t === "account.error" || t === "account.credentials") {
    return "account.needs_reauth";
  }
  if (t === "messaging.new_message") return "messaging.new_message";

  // Hosted-auth notify_url shape:
  if (event.status === "CREATION_SUCCESS" || event.status === "RECONNECTED") {
    return "account.connected";
  }
  if (
    event.status === "CREATION_ERROR" ||
    event.status === "CHECKPOINT" ||
    event.status === "CREDENTIALS"
  ) {
    return "account.needs_reauth";
  }
  return null;
}
