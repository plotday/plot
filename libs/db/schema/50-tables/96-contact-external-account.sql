CREATE TABLE "public"."contact_external_account" (
    "contact_id" uuid NOT NULL REFERENCES "public"."contact" ("id") ON DELETE CASCADE,
    "twist_instance_id" uuid NOT NULL REFERENCES "public"."twist_instance" ("id") ON DELETE CASCADE,
    "provider" text NOT NULL,
    "account_id" text NOT NULL,
    "data_fetched_at" timestamp with time zone NOT NULL DEFAULT now(),
    "last_reported_at" timestamp with time zone,
    PRIMARY KEY ("twist_instance_id", "account_id")
);

CREATE INDEX idx_cea_contact ON "public"."contact_external_account" ("contact_id");

CREATE INDEX idx_cea_reporting ON "public"."contact_external_account" ("provider", "last_reported_at");

CREATE INDEX idx_cea_lookup ON "public"."contact_external_account" ("twist_instance_id", "contact_id");
