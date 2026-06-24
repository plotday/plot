export { default, Gmail } from "./gmail";
export { getGmailChannels, GMAIL_MODIFY_SCOPE, GMAIL_LINK_TYPES } from "./channels";
// Sync/send/watch logic, extracted as host-pattern functions so the combined
// Google connector can reuse them (mirrors @plotday/connector-google-calendar).
export {
  type GmailSyncHost,
  type InitialSyncState,
  type IncrementalState,
  type MailboxWebhookState,
  type InitialSyncBatchResult,
  type GmailWebhookResult,
  SELF_HEAL_INTERVAL_MS,
  SYSTEM_LABEL_ORDER,
  ensureMailboxWebhookFn,
  setupMailboxWebhookFn,
  teardownMailboxWebhookFn,
  renewMailboxWatchFn,
  selfHealCheckFn,
  getMailboxRenewalSchedule,
  initialSyncBatchFn,
  incrementalSyncBatchFn,
  processEmailThreadsFn,
  onNoteCreatedFn,
  onThreadReadFn,
  onThreadToDoFn,
  onCreateLinkFn,
  onGmailWebhookFn,
  downloadAttachmentFn,
  getEnabledChannelsFn,
  addEnabledChannelFn,
  removeEnabledChannelFn,
} from "./sync";
