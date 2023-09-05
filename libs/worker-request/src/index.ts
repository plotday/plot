import type { CalendarProvider, RawEvent } from "@plotday/cal";
import type { EmailType } from "@plotday/email";

export type SyncType = "full" | "incremental" | "partial";
export type SyncRequest = {
  accountId: number;
  providerCalendarId?: string;
  syncType?: SyncType;
};

export type EventSyncRequest = {
  provider: CalendarProvider;
  calendarId: number;
  sequence: number;
  rawEvent?: RawEvent;
  fullSyncComplete?: boolean;
};

export type EventLabelRequest = {
  eventId: number;
};

export type MailRequest = {
  to: string[];
  subject: string;
  email: EmailType;
  props?: Record<string, unknown>;
};
