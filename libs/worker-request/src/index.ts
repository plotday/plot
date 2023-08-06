import type { CalendarProvider, RawEvent } from "@plotday/cal";

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
