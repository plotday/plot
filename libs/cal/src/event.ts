export type EventStatus = "confirmed" | "cancelled" | "tentative";

export type EventResponse = "accepted" | "declined" | "tentative";

export type CommonVisibility = "normal" | "private" | "confidential";
export type GoogleVisibility = CommonVisibility | "public";
export type OutlookVisibility = CommonVisibility | "personal";
export type EventVisibility = GoogleVisibility | OutlookVisibility;

export type CommonAvailability = "busy" | "away" | "location" | "free";
export type GoogleAvailability = CommonAvailability | "focus";
export type OutlookAvailability = CommonAvailability;
export type EventAvailability = GoogleAvailability | OutlookAvailability;

export type Attachment = {
  name: string;
  url: string;
  contentType: string;
};

export type Contact = {
  email: string;
  name?: string;
};

export type Invitee = Contact & {
  response?: EventResponse;
  isOptional?: boolean;
};

export type Conferencing = {
  url: string;
};

export type LocationType = "room" | "address" | "other";

// Physical location
export type Location = {
  name: string;
  type: LocationType;
};

export type Event = {
  id: string;
  series?: string;
  name?: string;
  status: EventStatus;
  startsAt: Date;
  endsAt: Date;
  createdAt?: Date;
  providerLink?: string; // for editing in the provider client on the web
  summary?: string;
  description?: string;
  visibility: EventVisibility;
  availability: EventAvailability;
  conferencing?: Conferencing;
  organizer?: Contact;
  invitees: Invitee[];
  categories: string[];
  locations: Location[];
  attachments: Attachment[];
};

//   private static HasConferencing(
//     location?: string | null,
//     description?: string | null
//   ): boolean {
//     const both = (location || "") + (description || "");
//     return !!both.match(
//       /(((zoom\.us)|(meet\.google\.com))\/)|(teams\.microsoft\.com\/meetup-join)/
//     );
//   }
//
//   public hasExternalAttendees(): boolean {
//     const [_, internalDomain] = this._accountEmail.split("@");
//     return this.invitee.some((a) => {
//       const [_, domain] = a.email.split("@");
//       return domain !== internalDomain;
//     });
//   }
//
// export class EventError extends Error {
//   constructor(message: string, public event: any, cause?: any) {
//     if (cause) {
//       if (cause.message) {
//         message += `: ${cause.message}`;
//       }
//       if (cause.detail) {
//         message += `\n${cause.detail}`;
//       }
//       if (cause.where) {
//         message += `\n${cause.where}`;
//       }
//     }
//     super(message, { cause });
//     this.name = "EventError";
//   }
// }
