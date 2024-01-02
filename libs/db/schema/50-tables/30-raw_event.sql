CREATE TABLE "public"."raw_event" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "calendar_id" bigint REFERENCES calendar ON DELETE SET NULL,
    "event" jsonb NOT NULL,
    "provider_id" text NOT NULL,
    CONSTRAINT calendar_provider_id_unique UNIQUE (calendar_id, provider_id)
);

ALTER TABLE "public"."raw_event" ENABLE ROW LEVEL SECURITY;

