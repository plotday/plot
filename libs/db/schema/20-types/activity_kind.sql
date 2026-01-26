-- Activity kind enum for additional categorization
-- Kinds provide finer-grained classification within activities
-- Unlike activity type, kind is flexible and not restricted by type
CREATE TYPE "public"."activity_kind" AS enum (
    'document',
    'messages',
    'meeting',
    'videoconference',
    'phone',
    'focus',
    'meal',
    'exercise',
    'family',
    'travel',
    'social',
    'entertainment'
);
