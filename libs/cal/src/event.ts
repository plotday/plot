export type EventStatus = "confirmed" | "cancelled" | "tentative";

export type EventResponse = "accepted" | "declined" | "tentative" | null;

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
  avatar?: string;
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
  response?: EventResponse;
  visibility: EventVisibility;
  availability: EventAvailability;
  isOptional: boolean;
  startsAt?: Date;
  endsAt?: Date;
  createdAt?: Date;
  providerLink?: string; // for editing in the provider client on the web
  summary?: string;
  description?: string;
  conferencing?: Conferencing;
  organizer?: Contact;
  invitees: Invitee[];
  inviteesHidden?: boolean;
  categories: string[];
  locations: Location[];
  attachments: Attachment[];
};
