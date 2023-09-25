import differenceInMinutes from "date-fns/differenceInMinutes";

import { toDate } from "@plotday/tz";

import type { SupabaseClient } from "./";
import type { Database } from "./types";

export type Label = {
  id: number;
  tag: string | null;
  name: string;
  description: string | null;
  order: number;
};

export type LabelMap = {
  [id: number]: Label;
};

export type ConferencingProvider = "zoom" | "meet" | "teams" | "other";

export type DbEvent = NonNullable<Awaited<ReturnType<typeof Event.Get>>>;
export type DbEvents = DbEvent[];

export type Attendance = Database["public"]["Enums"]["event_attendance"] | null;

type ArrayElement<T> = T extends (infer E)[] ? E : never;

export type Invitees = Event["invitees"];
export type Invitee = ArrayElement<Invitees>;

const EVENT_USER_QUERY = "user_id";
const EVENT_QUERY =
  "user_id,id,name,status,at,created_at,series,provider_id,provider_link,summary,visibility,availability,type,conferencing_url,organizer,attendance,ready,reviewed,labels,invitees:invitee(response,is_optional,contact(id,name,email,contact_user_id,organization(id,name)))";

type PostgrestQueryBuilder = ReturnType<
  ReturnType<SupabaseClient["from"]>["select"]
>;

export class Event {
  public static async Get(supabase: SupabaseClient, eventId: number) {
    return (
      await supabase
        .from("event_x2")
        .select(EVENT_QUERY)
        .eq("id", eventId)
        .maybeSingle()
        .throwOnError()
    ).data;
  }

  private static AddFilters<T extends PostgrestQueryBuilder>(
    query: T,
    userId: number,
    from: Date | "-infinity",
    to: Date | "infinity",
    filters: {
      attendance?: Attendance[];
      ready?: boolean;
      reviewed?: boolean;
    }
  ) {
    const during = `[${from instanceof Date ? from.toISOString() : from}, ${
      to instanceof Date ? to.toISOString() : to
    })`;

    query = query.eq("user_id", userId);
    query = query.overlaps("at", during).neq("status", "cancelled");

    if (filters.attendance) {
      const nonNull = filters.attendance
        .filter((f) => f !== null)
        .map((f) => `"${f}"`)
        .join(",");
      const isNull = filters.attendance.filter((f) => f === null);
      query = query.or(
        `attendance.in.(${nonNull}), ${isNull ? "attendance.is.null" : "false"}`
      );
    }
    if (filters.ready !== undefined) {
      query = query.eq("ready", filters.ready);
    }
    if (filters.reviewed !== undefined) {
      query = query.eq("reviewed", filters.reviewed);
    }

    return query;
  }

  public static async GetRange(
    supabase: SupabaseClient,
    userId: number,
    from: Date = new Date(),
    forward: boolean = true,
    filters: {
      attendance?: Attendance[];
      ready?: boolean;
      reviewed?: boolean;
    } = {}
  ) {
    const eventsQuery = Event.AddFilters(
      supabase.from("event_x2").select(`${EVENT_QUERY},${EVENT_USER_QUERY}`),
      userId,
      forward ? from : "-infinity",
      forward ? "infinity" : from,
      filters
    )
      .order("at", { ascending: forward })
      .order("response", { foreignTable: "invitee" })
      .limit(80);
    const events = (await eventsQuery.throwOnError()).data;
    type retType = NonNullable<typeof events>;
    if (!events) return [] as retType;

    return events.filter((e) => !!e) as retType;
  }

  public static async GetCount(
    supabase: SupabaseClient,
    userId: number,
    from: Date | "-infinity",
    to: Date | "infinity",
    filters: {
      attendance?: Attendance[];
      ready?: boolean;
      reviewed?: boolean;
    }
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

  public static Hydrate(dbEvents: DbEvent[], tz: string, labels: LabelMap) {
    return dbEvents.map((e: DbEvent) => new Event(e, tz, labels));
  }

  constructor(
    public dbEvent: DbEvent,
    public tz: string,
    private _labels: LabelMap
  ) {}

  public get id() {
    if (!this.dbEvent.id) throw Error("Event has no id");
    return this.dbEvent.id;
  }

  public get start() {
    const dates = ((this.dbEvent.at as string) || "")
      .replaceAll(/["[\]()]/g, "")
      .split(",");
    return toDate(dates[0], this.tz);
  }

  public get end() {
    const dates = ((this.dbEvent.at as string) || "")
      .replaceAll(/["[\]()]/g, "")
      .split(",");
    return toDate(dates[1], this.tz);
  }

  public get name() {
    if (this.dbEvent.name) {
      return this.dbEvent.name;
    }
    let title = "Untitled event";
    if (this.invitees.length > 1) {
      title = "Meeting";
      const names = this.invitees
        .filter((a) => !a.isSelf)
        .map((a) => a.name || a.email);
      switch (names.length) {
        case 0:
          break;
        case 1:
          title += ` with ${names[0]}`;
          break;
        case 2:
          title += ` with ${names[0]} and ${names[1]}`;
          break;
        default:
          title += ` with ${names.slice(0, 2).join(", ")}, and ${
            names.length - 2
          } other${names.length - 2 > 1 ? "s" : ""}`;
          break;
      }
    }
    return title;
  }

  // public get description() {
  //   return this.dbEvent.description;
  // }

  // calendar owner's response
  public get attendance() {
    return this.dbEvent.attendance;
  }

  // email address associated with the calendar that owns this event
  public get email() {
    return this.invitees.find((invitee) => invitee.isSelf)?.email || null;
  }

  public get providerId() {
    return this.dbEvent.provider_id;
  }

  public get providerLink() {
    return this.dbEvent.provider_link;
  }

  public get conferencing() {
    const url = this.dbEvent.conferencing_url;
    if (!url) return null;
    let provider: ConferencingProvider = "other";
    if (url.includes("zoom.us")) {
      provider = "zoom";
    } else if (url.includes("meet.google.com")) {
      provider = "meet";
    } else if (url.includes("teams.microsoft.com")) {
      provider = "teams";
    }
    return {
      url,
      provider,
    };
  }

  private get self() {
    return this.dbEvent.invitees.filter(
      (invitee) => invitee.contact?.contact_user_id
    )[0];
  }

  public get organizer() {
    const organizer = this.dbEvent.invitees.filter(
      (invitee) => invitee.contact?.id === this.dbEvent.organizer
    )[0];
    if (!organizer) return undefined;
    return this.toInvitee(organizer);
  }

  private toInvitee(invitee: DbEvent["invitees"][number]) {
    // @ts-ignore Type inference is failing for organziation
    const selfOrg = this.self?.contact?.organization?.id;
    return {
      id: invitee.contact?.id,
      name: invitee.contact?.name || invitee.contact?.email,
      email: invitee.contact?.email,
      // This assume contact_user_id is only set for the owner
      isSelf: !!invitee.contact?.contact_user_id,
      // @ts-ignore Type inference is failing for organziation
      isExternal: selfOrg && invitee.contact?.organization?.id !== selfOrg,
      // @ts-ignore Type inference is failing for organziation
      isInternal: selfOrg && invitee.contact?.organization?.id === selfOrg,
      response: invitee.response,
    };
  }

  public get invitees() {
    return this.dbEvent.invitees.map((i) => this.toInvitee(i));
  }

  public get labels() {
    return this.dbEvent.labels?.map((l) => this._labels[l]) ?? [];
  }

  public get duration() {
    return differenceInMinutes(this.end, this.start);
  }

  public get notice() {
    if (!this.dbEvent.created_at) return undefined;
    const notice = differenceInMinutes(
      this.start,
      new Date(this.dbEvent.created_at)
    );
    if (notice < 0) return undefined;
    return notice;
  }

  public get isAllDay() {
    return this.duration >= 23 * 60;
  }

  public get isOrganizer() {
    const selfId = this.self?.contact?.id;
    return this.dbEvent.organizer === selfId;
  }

  public get isRecurring() {
    return !!this.dbEvent.series;
  }

  public get hasExternalInvitees() {
    return this.invitees.some((i) => i.isExternal);
  }

  public get hasOnlyInternalInvitees() {
    return this.invitees.every((i) => i.isInternal);
  }

  public get isReady() {
    return !!this.dbEvent.ready;
  }

  public get isReviewed() {
    return !!this.dbEvent.reviewed;
  }

  public get type() {
    return this.dbEvent.type;
  }

  public isDone(review: boolean) {
    return (
      this.attendance !== null && (review ? this.isReviewed : this.isReady)
    );
  }
}
