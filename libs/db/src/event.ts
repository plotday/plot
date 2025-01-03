import type { Event as CalendarEvent, EventResponse } from "@plotday/cal";

import type { SupabaseClient } from "./";
import { safeQuery } from "./query";
import type { Database } from "./types";

export type ConferencingProvider = "zoom" | "meet" | "teams" | "other";

export type DbEvents = NonNullable<Awaited<ReturnType<typeof Event.GetRange>>>;
export type DbDetailedEvent = NonNullable<
  Awaited<ReturnType<typeof Event.Get>>
>;
export type DbEvent = DbEvents[0] & Partial<DbDetailedEvent>;

export type Response = Database["public"]["Enums"]["event_response"] | null;

export type Invitee = {
  email: string;
  response: EventResponse;
  name: string;
  avatar?: string;
  isSelf: boolean;
  isExternal: boolean;
  isInternal: boolean;
};
export type Invitees = Invitee[];

const EVENT_USER_QUERY = "user_id";
const EVENT_QUERY =
  "user_id,id,name,status,at,created_at,series,provider_id,provider_link,category_path,summary,visibility,availability,type,conferencing_url,organizer_email,response,invitees:invitee(email,response,is_optional,contact(id,name,email,avatar_url,contact_user_id,organization(id,name)))";
const EVENT_DETAILS_QUERY =
  "user_id,id,name,description,status,at,created_at,series,provider_id,provider_link,category_path,summary,visibility,availability,type,conferencing_url,organizer_email,response,invitees:invitee(email,response,is_optional,contact(id,name,email,avatar_url,contact_user_id,organization(id,name)))";

type PostgrestQueryBuilder = ReturnType<
  ReturnType<SupabaseClient["from"]>["select"]
>;

export type EventFilters = {
  response?: Response[];
  type?: Database["public"]["Enums"]["event_type"][];
  category?: string;
};

export function calendarToDb(
  user_id: string,
  event: CalendarEvent,
  calendar_id?: number,
  sequence?: number
): Database["public"]["Tables"]["event"]["Insert"] {
  return {
    user_id,
    calendar_id,
    sequence,
    provider_id: event.id,
    series: event.series,
    name: event.name,
    status: event.status,
    description: event.description,
    summary: event.summary,
    provider_link: event.providerLink,
    invitees_hidden: event.inviteesHidden,
    visibility: event.visibility,
    availability: event.availability,
    response: event.response,
    optional: event.isOptional,
    conferencing_url: event.conferencing?.url,
    organizer_email: event.organizer?.email,
    at:
      event.startsAt && event.endsAt
        ? `[${event.startsAt.toISOString()},${event.endsAt.toISOString()})`
        : null,
    ...(event.createdAt && {
      created_at: event.createdAt?.toISOString(),
    }),
  };
}

export class Event {
  public static async Get(supabase: SupabaseClient, eventId: number) {
    return safeQuery(
      await supabase
        .from("event_x")
        .select(EVENT_DETAILS_QUERY)
        .eq("id", eventId)
        .maybeSingle()
    );
  }

  private static AddFilters<T extends PostgrestQueryBuilder>(
    query: T,
    userId: number,
    from: Date | "-infinity",
    to: Date | "infinity",
    filters: EventFilters
  ) {
    const during = `[${from instanceof Date ? from.toISOString() : from}, ${
      to instanceof Date ? to.toISOString() : to
    })`;

    query = query.eq("user_id", userId);
    query = query.overlaps("at", during).neq("status", "cancelled");

    if (filters.response) {
      const nonNull = filters.response
        .filter((f) => f !== null)
        .map((f) => `"${f}"`)
        .join(",");
      const isNull = filters.response.filter((f) => f === null);
      query = query.or(
        `response.in.(${nonNull}), ${isNull ? "response.is.null" : "false"}`
      );
    }

    if (filters.type) {
      const list = filters.type.map((f) => `"${f}"`).join(",");
      query = query.or(`type.in.(${list})`);
    }

    if (filters.category) {
      query = query.eq("category_path", filters.category);
    }

    return query;
  }

  public static async GetRange(
    supabase: SupabaseClient,
    userId: number,
    start: Date = new Date(),
    end: Date = new Date(),
    filters: EventFilters = {}
  ) {
    const eventsQuery = Event.AddFilters(
      supabase.from("event_x").select(`${EVENT_QUERY},${EVENT_USER_QUERY}`),
      userId,
      start,
      end,
      filters
    )
      .order("at", { ascending: true })
      .order("response", { foreignTable: "invitee" })
      .limit(80);
    const events = safeQuery(await eventsQuery);
    type retType = NonNullable<typeof events>;
    if (!events) return [] as retType;

    return events.filter((e) => !!e) as retType;
  }

  public static async GetCount(
    supabase: SupabaseClient,
    userId: number,
    from: Date | "-infinity",
    to: Date | "infinity",
    filters: EventFilters
  ) {
    const eventsQuery = Event.AddFilters(
      supabase
        .from("event_x")
        .select(`*,${EVENT_USER_QUERY}`, { count: "estimated", head: true }),
      userId,
      from,
      to,
      filters
    );
    return (await eventsQuery).count;
  }

  constructor(public dbEvent: DbEvent, public tz: string) {
    if (!tz) throw Error("Missing timezone");
  }

  // public get id() {
  //   if (!this.dbEvent.id) throw Error("Event has no id");
  //   return this.dbEvent.id;
  // }
  //
  // public get start() {
  //   return parseDatetimeRange((this.dbEvent.at as string) || "", this.tz)[0];
  // }
  //
  // public get end() {
  //   return parseDatetimeRange((this.dbEvent.at as string) || "", this.tz)[1];
  // }
  //
  // public get week(): string {
  //   return formatDate(this.start, this.tz, "yyyy-MM-dd");
  // }
  //
  // public get name() {
  //   if (this.dbEvent.name) {
  //     return this.dbEvent.name;
  //   }
  //   let title = "Untitled event";
  //   if (this.invitees.length > 1) {
  //     title = "Meeting";
  //     const names = this.invitees
  //       .filter((a) => !a.isSelf)
  //       .map((a) => a.name || a.email);
  //     switch (names.length) {
  //       case 0:
  //         break;
  //       case 1:
  //         title += ` with ${names[0]}`;
  //         break;
  //       case 2:
  //         title += ` with ${names[0]} and ${names[1]}`;
  //         break;
  //       default:
  //         title += ` with ${names.slice(0, 2).join(", ")}, and ${
  //           names.length - 2
  //         } other${names.length - 2 > 1 ? "s" : ""}`;
  //         break;
  //     }
  //   }
  //   return title;
  // }
  //
  // public get description() {
  //   return this.dbEvent.description;
  // }
  //
  // // calendar owner's response
  // public get response() {
  //   return this.dbEvent.response;
  // }
  //
  // public get providerId() {
  //   return this.dbEvent.provider_id;
  // }
  //
  // public get providerLink() {
  //   return this.dbEvent.provider_link;
  // }
  //
  // public get categoryId() {
  //   return this.dbEvent.category_path;
  // }
  //
  // public get category() {
  //   if (!this.dbEvent.category_path || !this._categories) return undefined;
  //   return this._categories[this.dbEvent.category_path];
  // }
  //
  // public get balance() {
  //   if (!this.dbEvent.category_id || !this._balances) return undefined;
  //   return this._balances[this.week]?.[this.dbEvent.category_id];
  // }
  //
  // public get conferencing() {
  //   const url = this.dbEvent.conferencing_url;
  //   if (!url) return null;
  //   let provider: ConferencingProvider = "other";
  //   if (url.includes("zoom.us")) {
  //     provider = "zoom";
  //   } else if (url.includes("meet.google.com")) {
  //     provider = "meet";
  //   } else if (url.includes("teams.microsoft.com")) {
  //     provider = "teams";
  //   }
  //   return {
  //     url,
  //     provider,
  //   };
  // }
  //
  // private get self() {
  //   return this.dbEvent.invitees.filter(
  //     (invitee) => invitee.contact?.[0]?.contact_user_id
  //   )[0];
  // }
  //
  // public get organizer() {
  //   const organizer = this.invitees.filter(
  //     (invitee) => invitee.email === this.dbEvent.organizer_email
  //   )[0];
  //   if (!organizer) return undefined;
  //   return organizer;
  // }
  //
  // private toInvitee(invitee: DbEvent["invitees"][number]): Invitee {
  //   const selfOrg = this.dbEvent.invitees
  //     // @ts-ignore Type inference is failing
  //     .filter((i) => i.contact?.contact_user_id)?.organization?.id;
  //   // Some TS hackery since it thinks contacts is an array rather than the item
  //   const contact = invitee.contact as any as (typeof invitee.contact)[number];
  //   return {
  //     email: invitee.email,
  //     response: invitee.response,
  //     name: contact?.name || invitee.email,
  //     avatar: contact?.avatar_url ?? undefined,
  //     // This assume contact_user_id is only set for the owner
  //     isSelf: !!contact?.contact_user_id,
  //     // @ts-ignore Type inference is failing for organziation
  //     isExternal: selfOrg && contact?.organization?.id !== selfOrg,
  //     // @ts-ignore Type inference is failing for organziation
  //     isInternal: selfOrg && contact?.organization?.id === selfOrg,
  //   };
  // }
  //
  // public get invitees() {
  //   return this.dbEvent.invitees.map((i) => this.toInvitee(i));
  // }
  //
  // public get duration() {
  //   if (this.type === "note") return 0;
  //   return differenceInMinutes(this.end, this.start);
  // }
  //
  // public get notice() {
  //   if (!this.dbEvent.created_at) return undefined;
  //   const notice = differenceInMinutes(
  //     this.start,
  //     new Date(this.dbEvent.created_at)
  //   );
  //   if (notice < 0) return undefined;
  //   return notice;
  // }
  //
  // public get isAllDay() {
  //   return this.duration >= 23 * 60;
  // }
  //
  // public get isOrganizer() {
  //   return this.organizer?.email === this.self?.email;
  // }
  //
  // public get isRecurring() {
  //   return !!this.dbEvent.series;
  // }
  //
  // public get hasExternalInvitees() {
  //   return this.invitees.some((i) => i.isExternal);
  // }
  //
  // public get hasOnlyInternalInvitees() {
  //   return this.invitees.every((i) => i.isInternal);
  // }
  //
  // public get isMeeting() {
  //   return this.dbEvent.type === "meeting";
  // }
  //
  // public get type() {
  //   return this.dbEvent.type;
  // }
}
