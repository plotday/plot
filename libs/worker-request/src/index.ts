import type { CalendarProvider, RawEvent } from "@plotday/cal";
import type { EmailType } from "@plotday/email";

export type SyncRequest = {
  accountId: number;
  providerCalendarId?: string;
  full?: boolean;
};

export type EventSyncRequest = {
  provider: CalendarProvider;
  calendarId: number;
  sequence: number;
  rawEvent: RawEvent;
};

export type MailRequest = {
  to: string[];
  subject: string;
  email: EmailType;
  props?: Record<string, unknown>;
};
