CREATE TYPE "public"."provider" AS enum (
    'google',
    'outlook'
);

CREATE TYPE "public"."event_availability" AS enum (
    'busy',
    'away',
    'focus',
    'free'
);

CREATE TYPE "public"."event_response" AS enum (
    'accepted',
    'declined',
    'tentative'
);

CREATE TYPE "public"."event_status" AS enum (
    'confirmed',
    'cancelled',
    'tentative'
);

CREATE TYPE "public"."event_visibility" AS enum (
    'normal',
    'private',
    'confidential',
    'public',
    'personal'
);

CREATE TYPE "public"."location_type" AS enum (
    'room',
    'address',
    'other'
);

CREATE TYPE "public"."event_attendance" AS enum (
    'attend',
    'if-possible',
    'skip'
);

