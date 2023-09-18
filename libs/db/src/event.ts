import differenceInMinutes from "date-fns/differenceInMinutes";

import { toDate } from "@plotday/tz";

import type { SupabaseClient } from "./";
import { safeQuery } from "./";
import type { Database } from "./types";

export type ConferencingProvider = "zoom" | "meet" | "teams" | "other";

type Flatten<Type> = Type extends Array<infer Item> ? Item : Type;

type DbEvents = Awaited<ReturnType<typeof Event.GetRange>>;
type DbEvent = Flatten<DbEvents>;

export type Attendance = Database["public"]["Enums"]["event_attendance"] | null;

// Syncrhonize this list with schema/85-data/50-label.sql
export const Label = {
  meeting: 1,
  one_on_one: 2,
  sm: 3,
  md: 4,
  lg: 5,
  xl: 6,
  xxl: 7,
  internal: 8,
  external: 9,
  l_0_25h: 10,
  l_0_5h: 11,
  l_0_75h: 12,
  l_1h: 13,
  l_1_5h: 14,
  l_2h: 15,
  l_2_5h: 16,
  l_3h: 17,
  l_0_5d: 18,
  l_0_75d: 19,
  l_1d: 20,
  recurring: 21,
  short_notice: 22,
  speedy: 23,
  initiated: 24,
} as const;

const EVENT_QUERY =
  "id,name,status,at,created_at,series,provider_id,provider_link,summary,visibility,availability,conferencing_url,organizer,attendance,ready,reviewed,invitees:invitee(response,is_optional,contact(id,name,email,contact_user_id,organization(id,name))),labels:label(id,order,tag,name,description)";

export class Event {
  public static async Get(supabase: SupabaseClient, eventId: number) {
    return safeQuery(
      await supabase
        .from("event_x")
        .select(EVENT_QUERY)
        .eq("id", eventId)
        .maybeSingle()
    );
  }

  public static async GetRange(
    supabase: SupabaseClient,
    from: Date,
    forward: boolean = true,
    filters: {
      attendance?: Attendance[];
    } = {}
  ) {
    let during: string;
    if (forward) {
      during = `[${from.toISOString()}, infinity)`;
    } else {
      during = `(-infinity, ${from.toISOString()}]`;
    }

    let eventsQuery = supabase
      .from("event_x")
      .select(EVENT_QUERY)
      .overlaps("at", during)
      .neq("status", "cancelled");

    if (filters.attendance) {
      eventsQuery = eventsQuery.is("attendance", null);
    }

    eventsQuery = eventsQuery
      .order("at", { ascending: forward })
      .order("response", { foreignTable: "invitee" })
      .limit(80);
    const events = safeQuery(await eventsQuery);
    type retType = NonNullable<typeof events>;
    if (!events) return [] as retType;

    return events.filter((e) => !!e) as retType;
  }

  public static Hydrate(dbEvents: DbEvent[], tz: string) {
    return dbEvents.map((e: DbEvent) => new Event(e, tz));
  }

  constructor(public dbEvent: DbEvent, public tz: string) {}

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
    return this.dbEvent.labels;
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

  public isDone(review: boolean = false) {
    return review ? this.isReviewed : this.isReady;
  }

  public guessLabels() {
    const labels: number[] = [];
    if (this.isAllDay) {
      return labels;
    }
    if (this.invitees.length <= 1) {
      return labels;
    }
    labels.push(Label.meeting);

    const notice = this.notice;
    if (this.isOrganizer) {
      labels.push(Label.initiated);
    }
    if (this.hasOnlyInternalInvitees) {
      labels.push(Label.internal);
    }
    if (this.hasExternalInvitees) {
      labels.push(Label.external);
    }
    if (this.invitees.length == 2) {
      labels.push(Label.one_on_one);
    } else if (this.invitees.length <= 4) {
      labels.push(Label.sm);
    } else if (this.invitees.length <= 7) {
      labels.push(Label.md);
    } else if (this.invitees.length <= 15) {
      labels.push(Label.lg);
    } else if (this.invitees.length <= 30) {
      labels.push(Label.xl);
    } else {
      labels.push(Label.xxl);
    }

    if (this.isRecurring) {
      labels.push(Label.recurring);
    }
    if (notice !== undefined && notice < 18 * 60) {
      labels.push(Label.short_notice);
    }

    if (this.duration <= 20) {
      labels.push(Label.l_0_25h);
    } else if (this.duration < 40) {
      labels.push(Label.l_0_5h);
    } else if (this.duration < 50) {
      labels.push(Label.l_0_75h);
    } else if (this.duration < 75) {
      labels.push(Label.l_1h);
    } else if (this.duration < 101) {
      labels.push(Label.l_1_5h);
    } else if (this.duration < 131) {
      labels.push(Label.l_2h);
    } else if (this.duration < 161) {
      labels.push(Label.l_2_5h);
    } else if (this.duration <= 180) {
      labels.push(Label.l_3h);
    } else if (this.duration <= 300) {
      labels.push(Label.l_0_5d);
    } else if (this.duration <= 420) {
      labels.push(Label.l_0_75d);
    } else if (this.duration <= 420) {
      labels.push(Label.l_1d);
    }

    if (
      this.duration < 30 ||
      (this.duration % 30 >= 10 && this.duration % 30 <= 15)
    ) {
      labels.push(Label.speedy);
    }

    return labels;
  }
}

type ArrayElement<T> = T extends (infer E)[] ? E : never;

export type Invitees = Event["invitees"];
export type Invitee = ArrayElement<Invitees>;

export type Labels = Event["labels"];
export type Label = ArrayElement<Labels>;
