CREATE TYPE "public"."enter_behavior" AS enum (
    'enter_newline',
    'enter_submits'
);

ALTER TYPE "public"."activity_type" RENAME TO "activity_type__old_version_to_be_dropped";

CREATE TYPE "public"."activity_type" AS enum (
    'action',
    'event',
    'note'
);

CREATE TABLE "public"."activity" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid_v7 (),
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "author_id" uuid NOT NULL,
    "created_by" uuid NOT NULL DEFAULT auth.uid (),
    "assignee_id" uuid,
    "updated_by" integer NOT NULL DEFAULT 0,
    "archived_at" timestamp with time zone,
    "priority_id" uuid NOT NULL,
    "type" activity_type NOT NULL DEFAULT 'note' ::activity_type,
    "order" double precision NOT NULL DEFAULT order_first (),
    "draft" boolean NOT NULL DEFAULT FALSE,
    "private" boolean NOT NULL DEFAULT FALSE,
    "title" text,
    "preview" text,
    "at" tstzrange,
    "on" daterange,
    "duration" interval,
    "done_at" timestamp with time zone,
    "recurrence_rule" text,
    "recurrence_exdates" timestamp with time zone[],
    "recurrence_dates" timestamp with time zone[],
    "meta" jsonb,
    "source" text,
    "created_by_twist_id" bigint,
    "embedding" halfvec (384),
    "pick_priority" jsonb,
    "last_note_created_at" timestamp with time zone
);

ALTER TABLE "public"."activity" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."activity_exception" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid_v7 (),
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_by" integer NOT NULL DEFAULT 0,
    "archived_at" timestamp with time zone,
    "activity_id" uuid NOT NULL,
    "occurrence" text NOT NULL,
    "at" tstzrange,
    "on" daterange,
    "duration" interval,
    "done_at" timestamp with time zone,
    "title" text,
    "note" text,
    "meta" jsonb
);

ALTER TABLE "public"."activity_exception" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."activity_read" (
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "activity_id" uuid NOT NULL,
    "read_at" timestamp with time zone NOT NULL DEFAULT now()
);

ALTER TABLE "public"."activity_read" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."activity_tag" (
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone,
    "actor_id" uuid NOT NULL,
    "activity_id" uuid NOT NULL,
    "occurrence" text,
    "tag_id" integer NOT NULL,
    "updated_by" integer NOT NULL DEFAULT 0
);

ALTER TABLE "public"."activity_tag" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."contact" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid_v7 (),
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone,
    "email" text NOT NULL,
    "name" text,
    "avatar_url" text,
    "user_id" uuid
);

ALTER TABLE "public"."contact" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."cost" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "name" text NOT NULL,
    "start" timestamp with time zone NOT NULL,
    "amount" numeric
);

ALTER TABLE "public"."cost" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."domain" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "name" text NOT NULL,
    "organization_id" bigint
);

ALTER TABLE "public"."domain" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."invitation" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "code" text NOT NULL,
    "remaining" numeric NOT NULL DEFAULT '1' ::numeric
);

ALTER TABLE "public"."invitation" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."note" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid_v7 (),
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "author_id" uuid NOT NULL,
    "created_by" uuid NOT NULL DEFAULT auth.uid (),
    "updated_by" integer NOT NULL DEFAULT 0,
    "archived_at" timestamp with time zone,
    "activity_id" uuid NOT NULL,
    "draft" boolean NOT NULL DEFAULT FALSE,
    "private" boolean NOT NULL DEFAULT FALSE,
    "content" text,
    "links" jsonb,
    "mentions" uuid[]
);

ALTER TABLE "public"."note" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."note_tag" (
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone,
    "actor_id" uuid NOT NULL,
    "note_id" uuid NOT NULL,
    "tag_id" integer NOT NULL,
    "updated_by" integer NOT NULL DEFAULT 0
);

ALTER TABLE "public"."note_tag" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."organization" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "name" text NOT NULL
);

ALTER TABLE "public"."organization" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."priority" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid_v7 (),
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL,
    "root" boolean NOT NULL DEFAULT FALSE,
    "archived_at" timestamp with time zone,
    "title" text NOT NULL,
    "color" integer,
    "path" ltree NOT NULL,
    "updated_by" integer NOT NULL DEFAULT 0
);

ALTER TABLE "public"."priority" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."priority_contact" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone,
    "priority_id" uuid NOT NULL,
    "contact_id" uuid NOT NULL
);

ALTER TABLE "public"."priority_contact" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."priority_settings" (
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "priority_id" uuid NOT NULL,
    "top_order" double precision,
    "path" ltree,
    "pomodoro" integer,
    "color" integer
);

ALTER TABLE "public"."priority_settings" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."priority_twist" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid_v7 (),
    "priority_id" uuid NOT NULL,
    "twist_id" bigint NOT NULL,
    "owner_id" uuid NOT NULL,
    "name" text NOT NULL,
    "config" jsonb NOT NULL DEFAULT '{}' ::jsonb,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone
);

ALTER TABLE "public"."priority_twist" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."priority_user" (
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "priority_id" uuid NOT NULL,
    "archived_at" timestamp with time zone
);

ALTER TABLE "public"."priority_user" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."publisher" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "name" text NOT NULL,
    "email" text,
    "url" text
);

ALTER TABLE "public"."publisher" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."series" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "series" text NOT NULL,
    "invitees" text[],
    "embedding" vector (384),
    "priority_id" uuid
);

ALTER TABLE "public"."series" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."session" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid_v7 (),
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone,
    "user_id" uuid NOT NULL,
    "priority_id" uuid,
    "at" tstzrange NOT NULL,
    "precedence" smallint NOT NULL DEFAULT 0,
    "pomodoro" smallint,
    "pomodoro_at" timestamp with time zone,
    "updated_by" integer NOT NULL DEFAULT 0
);

ALTER TABLE "public"."session" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."token" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid (),
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone,
    "user_id" uuid,
    "publisher_id" bigint,
    "token" text NOT NULL,
    "name" text,
    "last_used_at" timestamp with time zone
);

ALTER TABLE "public"."token" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."twist" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "twist_admin_id" bigint NOT NULL,
    "environment" twist_environment NOT NULL DEFAULT 'personal' ::twist_environment,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone,
    "name" text NOT NULL,
    "description" text,
    "version" text NOT NULL,
    "permissions" jsonb
);

ALTER TABLE "public"."twist" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."twist_admin" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "twist_package_id" uuid NOT NULL DEFAULT gen_random_uuid (),
    "user_id" uuid,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "publisher_id" bigint,
    "priority_id" uuid,
    "auto_approve" boolean NOT NULL DEFAULT FALSE
);

ALTER TABLE "public"."twist_admin" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."usage" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "priority_twist_id" uuid NOT NULL,
    "hour" timestamp with time zone NOT NULL,
    "cost_id" bigint NOT NULL,
    "amount" integer NOT NULL
);

ALTER TABLE "public"."usage" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."user_settings" (
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "enter_behavior" enter_behavior
);

ALTER TABLE "public"."user_settings" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."user_subscription" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "stripe_customer_id" text,
    "stripe_subscription_id" text,
    "plan" subscription_plan NOT NULL DEFAULT 'free' ::subscription_plan,
    "status" subscription_status NOT NULL DEFAULT 'active' ::subscription_status,
    "billing_cycle_start" timestamp with time zone NOT NULL,
    "billing_cycle_end" timestamp with time zone NOT NULL
);

ALTER TABLE "public"."user_subscription" ENABLE ROW LEVEL SECURITY;

DROP TYPE "public"."activity_type__old_version_to_be_dropped";

DROP TYPE "public"."twist_environment__old_version_to_be_dropped";

CREATE INDEX activity_embedding_idx ON public.activity USING hnsw (embedding halfvec_cosine_ops);

CREATE UNIQUE INDEX activity_exception_pkey ON public.activity_exception USING btree (id);

CREATE UNIQUE INDEX activity_pkey ON public.activity USING btree (id);

CREATE UNIQUE INDEX activity_read_unique ON public.activity_read USING btree (user_id, activity_id);

CREATE UNIQUE INDEX activity_tag_actor_id_activity_id_occurrence_tag_id_key ON public.activity_tag USING btree (actor_id, activity_id, occurrence, tag_id) NULLS NOT DISTINCT;

CREATE UNIQUE INDEX contact_pkey ON public.contact USING btree (id);

CREATE UNIQUE INDEX contact_user_email_unique ON public.contact USING btree (email);

CREATE UNIQUE INDEX contact_user_id_unique ON public.contact USING btree (user_id);

CREATE UNIQUE INDEX cost_name_start_key ON public.cost USING btree (name, START);

CREATE UNIQUE INDEX cost_pkey ON public.cost USING btree (id);

CREATE UNIQUE INDEX domain_name_key ON public.domain USING btree (name);

CREATE UNIQUE INDEX domain_pkey ON public.domain USING btree (id);

CREATE INDEX idx_activity_archived ON public.activity USING btree (archived_at)
WHERE (archived_at IS NULL);

CREATE INDEX idx_activity_at ON public.activity USING gist (at);

CREATE INDEX idx_activity_created_at_priority ON public.activity USING btree (created_at DESC, priority_id)
WHERE (archived_at IS NULL);

CREATE INDEX idx_activity_done_at ON public.activity USING btree (done_at);

CREATE INDEX idx_activity_occurrence ON public.activity_exception USING btree (activity_id, occurrence);

CREATE INDEX idx_activity_on ON public.activity USING gist ("on");

CREATE INDEX idx_activity_priority_archived ON public.activity USING btree (priority_id, archived_at);

CREATE INDEX idx_activity_priority_archived_last_note ON public.activity USING btree (priority_id, last_note_created_at, created_at)
WHERE (archived_at IS NULL);

CREATE INDEX idx_activity_priority_id ON public.activity USING btree (priority_id);

CREATE INDEX idx_activity_read_user_read ON public.activity_read USING btree (user_id, activity_id, read_at);

CREATE INDEX idx_activity_source ON public.activity USING btree (source)
WHERE (source IS NOT NULL);

CREATE UNIQUE INDEX idx_activity_source_twist_unique ON public.activity USING btree (source, created_by_twist_id)
WHERE ((source IS NOT NULL) AND (created_by_twist_id IS NOT NULL) AND (archived_at IS NULL));

CREATE INDEX idx_activity_tag_activity_id ON public.activity_tag USING btree (activity_id, tag_id)
WHERE (archived_at IS NULL);

CREATE INDEX idx_note_activity_archived ON public.note USING btree (activity_id, archived_at);

CREATE INDEX idx_note_activity_id ON public.note USING btree (activity_id);

CREATE INDEX idx_note_author_activity ON public.note USING btree (activity_id, author_id, created_at)
WHERE (archived_at IS NULL);

CREATE INDEX idx_note_created_at ON public.note USING btree (activity_id, created_at);

CREATE INDEX idx_note_mentions ON public.note USING gin (mentions)
WHERE ((mentions IS NOT NULL) AND (archived_at IS NULL));

CREATE INDEX idx_note_tag_note_id ON public.note_tag USING btree (note_id, tag_id)
WHERE (archived_at IS NULL);

CREATE INDEX idx_note_tag_note_id_full ON public.note_tag USING btree (note_id);

CREATE UNIQUE INDEX idx_priority_created_by_root_true ON public.priority USING btree (created_by)
WHERE (root = TRUE);

CREATE INDEX idx_priority_path_gist ON public.priority USING gist (path);

CREATE INDEX idx_priority_twist_twist ON public.priority_twist USING btree (twist_id);

CREATE INDEX idx_priority_user_user_id ON public.priority_user USING btree (user_id)
WHERE (archived_at IS NULL);

CREATE INDEX idx_priority_user_user_priority_archived ON public.priority_user USING btree (user_id, priority_id, created_at)
WHERE (archived_at IS NULL);

CREATE INDEX idx_twist_admin_id ON public.twist USING btree (twist_admin_id);

CREATE INDEX idx_twist_environment ON public.twist USING btree (environment);

CREATE INDEX idx_twist_priority_id ON public.priority_twist USING btree (priority_id);

CREATE INDEX idx_usage_priority_twist_id ON public.usage USING btree (priority_twist_id);

CREATE INDEX idx_user_settings_user_id ON public.user_settings USING btree (user_id);

CREATE INDEX idx_user_subscription_stripe_customer_id ON public.user_subscription USING btree (stripe_customer_id);

CREATE INDEX idx_user_subscription_stripe_subscription_id ON public.user_subscription USING btree (stripe_subscription_id)
WHERE (stripe_subscription_id IS NOT NULL);

CREATE INDEX idx_user_subscription_user_id ON public.user_subscription USING btree (user_id);

CREATE UNIQUE INDEX invitation_code_key ON public.invitation USING btree (code);

CREATE UNIQUE INDEX invitation_pkey ON public.invitation USING btree (id);

CREATE INDEX name ON public.domain USING btree (name);

CREATE UNIQUE INDEX note_pkey ON public.note USING btree (id);

CREATE UNIQUE INDEX note_tag_actor_id_note_id_tag_id_key ON public.note_tag USING btree (actor_id, note_id, tag_id) NULLS NOT DISTINCT;

CREATE UNIQUE INDEX organization_pkey ON public.organization USING btree (id);

CREATE UNIQUE INDEX priority_contact_pkey ON public.priority_contact USING btree (id);

CREATE UNIQUE INDEX priority_contact_unique ON public.priority_contact USING btree (priority_id, contact_id);

CREATE UNIQUE INDEX priority_path_key ON public.priority USING btree (path);

CREATE UNIQUE INDEX priority_pkey ON public.priority USING btree (id);

CREATE UNIQUE INDEX priority_settings_unique ON public.priority_settings USING btree (user_id, priority_id);

CREATE UNIQUE INDEX priority_twist_pkey ON public.priority_twist USING btree (id);

CREATE UNIQUE INDEX priority_user_unique ON public.priority_user USING btree (user_id, priority_id);

CREATE UNIQUE INDEX publisher_pkey ON public.publisher USING btree (id);

CREATE UNIQUE INDEX series_pkey ON public.series USING btree (id);

CREATE UNIQUE INDEX series_unique ON public.series USING btree (user_id, series);

CREATE INDEX session_at_idx ON public.session USING spgist (at);

CREATE UNIQUE INDEX session_pkey ON public.session USING btree (id);

CREATE UNIQUE INDEX token_pkey ON public.token USING btree (id);

CREATE UNIQUE INDEX token_token_key ON public.token USING btree (token);

CREATE UNIQUE INDEX twist_admin_package_user_unique ON public.twist_admin USING btree (twist_package_id, user_id) NULLS NOT DISTINCT;

CREATE UNIQUE INDEX twist_admin_pkey ON public.twist_admin USING btree (id);

CREATE UNIQUE INDEX twist_name_unique_public_review ON public.twist USING btree (name)
WHERE (environment = ANY (ARRAY['public'::twist_environment, 'review'::twist_environment]));

CREATE UNIQUE INDEX twist_pkey ON public.twist USING btree (id);

CREATE UNIQUE INDEX usage_pkey ON public.usage USING btree (id);

CREATE UNIQUE INDEX usage_priority_twist_id_hour_cost_id_key ON public.usage USING btree (priority_twist_id, hour, cost_id);

CREATE UNIQUE INDEX user_settings_pkey ON public.user_settings USING btree (user_id);

CREATE UNIQUE INDEX user_subscription_pkey ON public.user_subscription USING btree (id);

CREATE UNIQUE INDEX user_subscription_stripe_customer_id_key ON public.user_subscription USING btree (stripe_customer_id);

CREATE UNIQUE INDEX user_subscription_stripe_subscription_id_key ON public.user_subscription USING btree (stripe_subscription_id);

CREATE UNIQUE INDEX user_subscription_user_id_key ON public.user_subscription USING btree (user_id);

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_pkey" PRIMARY KEY USING INDEX "activity_pkey";

ALTER TABLE "public"."activity_exception"
    ADD CONSTRAINT "activity_exception_pkey" PRIMARY KEY USING INDEX "activity_exception_pkey";

ALTER TABLE "public"."contact"
    ADD CONSTRAINT "contact_pkey" PRIMARY KEY USING INDEX "contact_pkey";

ALTER TABLE "public"."cost"
    ADD CONSTRAINT "cost_pkey" PRIMARY KEY USING INDEX "cost_pkey";

ALTER TABLE "public"."domain"
    ADD CONSTRAINT "domain_pkey" PRIMARY KEY USING INDEX "domain_pkey";

ALTER TABLE "public"."invitation"
    ADD CONSTRAINT "invitation_pkey" PRIMARY KEY USING INDEX "invitation_pkey";

ALTER TABLE "public"."note"
    ADD CONSTRAINT "note_pkey" PRIMARY KEY USING INDEX "note_pkey";

ALTER TABLE "public"."organization"
    ADD CONSTRAINT "organization_pkey" PRIMARY KEY USING INDEX "organization_pkey";

ALTER TABLE "public"."priority"
    ADD CONSTRAINT "priority_pkey" PRIMARY KEY USING INDEX "priority_pkey";

ALTER TABLE "public"."priority_contact"
    ADD CONSTRAINT "priority_contact_pkey" PRIMARY KEY USING INDEX "priority_contact_pkey";

ALTER TABLE "public"."priority_twist"
    ADD CONSTRAINT "priority_twist_pkey" PRIMARY KEY USING INDEX "priority_twist_pkey";

ALTER TABLE "public"."publisher"
    ADD CONSTRAINT "publisher_pkey" PRIMARY KEY USING INDEX "publisher_pkey";

ALTER TABLE "public"."series"
    ADD CONSTRAINT "series_pkey" PRIMARY KEY USING INDEX "series_pkey";

ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_pkey" PRIMARY KEY USING INDEX "session_pkey";

ALTER TABLE "public"."token"
    ADD CONSTRAINT "token_pkey" PRIMARY KEY USING INDEX "token_pkey";

ALTER TABLE "public"."twist"
    ADD CONSTRAINT "twist_pkey" PRIMARY KEY USING INDEX "twist_pkey";

ALTER TABLE "public"."twist_admin"
    ADD CONSTRAINT "twist_admin_pkey" PRIMARY KEY USING INDEX "twist_admin_pkey";

ALTER TABLE "public"."usage"
    ADD CONSTRAINT "usage_pkey" PRIMARY KEY USING INDEX "usage_pkey";

ALTER TABLE "public"."user_settings"
    ADD CONSTRAINT "user_settings_pkey" PRIMARY KEY USING INDEX "user_settings_pkey";

ALTER TABLE "public"."user_subscription"
    ADD CONSTRAINT "user_subscription_pkey" PRIMARY KEY USING INDEX "user_subscription_pkey";

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_action_assignee" CHECK (((type <> 'action'::activity_type) OR (assignee_id IS NOT NULL))) NOT valid;

ALTER TABLE "public"."activity" validate CONSTRAINT "activity_action_assignee";

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_no_complete_recurrence" CHECK (((recurrence_rule IS NULL) OR (done_at IS NULL))) NOT valid;

ALTER TABLE "public"."activity" validate CONSTRAINT "activity_no_complete_recurrence";

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_priority_id_fkey" FOREIGN KEY (priority_id) REFERENCES priority (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."activity" validate CONSTRAINT "activity_priority_id_fkey";

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_recurrence_on_or_at" CHECK (((recurrence_rule IS NULL) OR (at IS NOT NULL) OR ("on" IS NOT NULL))) NOT valid;

ALTER TABLE "public"."activity" validate CONSTRAINT "activity_recurrence_on_or_at";

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_scheduled" CHECK ((((recurrence_rule IS NULL) AND (type <> ALL (ARRAY['action'::activity_type, 'event'::activity_type]))) OR (at IS NOT NULL) OR ("on" IS NOT NULL))) NOT valid;

ALTER TABLE "public"."activity" validate CONSTRAINT "activity_scheduled";

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_single_schedule" CHECK (((at IS NULL) OR ("on" IS NULL))) NOT valid;

ALTER TABLE "public"."activity" validate CONSTRAINT "activity_single_schedule";

ALTER TABLE "public"."activity_exception"
    ADD CONSTRAINT "activity_exception_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES activity (id) NOT valid;

ALTER TABLE "public"."activity_exception" validate CONSTRAINT "activity_exception_activity_id_fkey";

ALTER TABLE "public"."activity_read"
    ADD CONSTRAINT "activity_read_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES activity (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."activity_read" validate CONSTRAINT "activity_read_activity_id_fkey";

ALTER TABLE "public"."activity_read"
    ADD CONSTRAINT "activity_read_unique" UNIQUE USING INDEX "activity_read_unique";

ALTER TABLE "public"."activity_read"
    ADD CONSTRAINT "activity_read_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."activity_read" validate CONSTRAINT "activity_read_user_id_fkey";

ALTER TABLE "public"."activity_tag"
    ADD CONSTRAINT "activity_tag_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES activity (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."activity_tag" validate CONSTRAINT "activity_tag_activity_id_fkey";

ALTER TABLE "public"."activity_tag"
    ADD CONSTRAINT "activity_tag_actor_id_activity_id_occurrence_tag_id_key" UNIQUE USING INDEX "activity_tag_actor_id_activity_id_occurrence_tag_id_key";

ALTER TABLE "public"."contact"
    ADD CONSTRAINT "contact_email_check" CHECK (is_lower (email)) NOT valid;

ALTER TABLE "public"."contact" validate CONSTRAINT "contact_email_check";

ALTER TABLE "public"."contact"
    ADD CONSTRAINT "contact_user_email_unique" UNIQUE USING INDEX "contact_user_email_unique";

ALTER TABLE "public"."contact"
    ADD CONSTRAINT "contact_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED NOT valid;

ALTER TABLE "public"."contact" validate CONSTRAINT "contact_user_id_fkey";

ALTER TABLE "public"."contact"
    ADD CONSTRAINT "contact_user_id_unique" UNIQUE USING INDEX "contact_user_id_unique";

ALTER TABLE "public"."cost"
    ADD CONSTRAINT "cost_name_start_key" UNIQUE USING INDEX "cost_name_start_key";

ALTER TABLE "public"."domain"
    ADD CONSTRAINT "domain_name_check" CHECK (is_lower (name)) NOT valid;

ALTER TABLE "public"."domain" validate CONSTRAINT "domain_name_check";

ALTER TABLE "public"."domain"
    ADD CONSTRAINT "domain_name_key" UNIQUE USING INDEX "domain_name_key";

ALTER TABLE "public"."domain"
    ADD CONSTRAINT "domain_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES organization (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."domain" validate CONSTRAINT "domain_organization_id_fkey";

ALTER TABLE "public"."invitation"
    ADD CONSTRAINT "invitation_code_key" UNIQUE USING INDEX "invitation_code_key";

ALTER TABLE "public"."note"
    ADD CONSTRAINT "note_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES activity (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."note" validate CONSTRAINT "note_activity_id_fkey";

ALTER TABLE "public"."note_tag"
    ADD CONSTRAINT "note_tag_actor_id_note_id_tag_id_key" UNIQUE USING INDEX "note_tag_actor_id_note_id_tag_id_key";

ALTER TABLE "public"."note_tag"
    ADD CONSTRAINT "note_tag_note_id_fkey" FOREIGN KEY (note_id) REFERENCES note (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."note_tag" validate CONSTRAINT "note_tag_note_id_fkey";

ALTER TABLE "public"."priority"
    ADD CONSTRAINT "priority_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority" validate CONSTRAINT "priority_created_by_fkey";

ALTER TABLE "public"."priority"
    ADD CONSTRAINT "priority_path_key" UNIQUE USING INDEX "priority_path_key";

ALTER TABLE "public"."priority_contact"
    ADD CONSTRAINT "priority_contact_contact_id_fkey" FOREIGN KEY (contact_id) REFERENCES contact (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_contact" validate CONSTRAINT "priority_contact_contact_id_fkey";

ALTER TABLE "public"."priority_contact"
    ADD CONSTRAINT "priority_contact_priority_id_fkey" FOREIGN KEY (priority_id) REFERENCES priority (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_contact" validate CONSTRAINT "priority_contact_priority_id_fkey";

ALTER TABLE "public"."priority_contact"
    ADD CONSTRAINT "priority_contact_unique" UNIQUE USING INDEX "priority_contact_unique";

ALTER TABLE "public"."priority_settings"
    ADD CONSTRAINT "priority_settings_priority_id_fkey" FOREIGN KEY (priority_id) REFERENCES priority (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_settings" validate CONSTRAINT "priority_settings_priority_id_fkey";

ALTER TABLE "public"."priority_settings"
    ADD CONSTRAINT "priority_settings_unique" UNIQUE USING INDEX "priority_settings_unique";

ALTER TABLE "public"."priority_settings"
    ADD CONSTRAINT "priority_settings_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_settings" validate CONSTRAINT "priority_settings_user_id_fkey";

ALTER TABLE "public"."priority_twist"
    ADD CONSTRAINT "priority_twist_owner_id_fkey" FOREIGN KEY (owner_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_twist" validate CONSTRAINT "priority_twist_owner_id_fkey";

ALTER TABLE "public"."priority_twist"
    ADD CONSTRAINT "priority_twist_priority_id_fkey" FOREIGN KEY (priority_id) REFERENCES priority (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_twist" validate CONSTRAINT "priority_twist_priority_id_fkey";

ALTER TABLE "public"."priority_twist"
    ADD CONSTRAINT "priority_twist_twist_id_fkey" FOREIGN KEY (twist_id) REFERENCES twist (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_twist" validate CONSTRAINT "priority_twist_twist_id_fkey";

ALTER TABLE "public"."priority_user"
    ADD CONSTRAINT "priority_user_priority_id_fkey" FOREIGN KEY (priority_id) REFERENCES priority (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_user" validate CONSTRAINT "priority_user_priority_id_fkey";

ALTER TABLE "public"."priority_user"
    ADD CONSTRAINT "priority_user_unique" UNIQUE USING INDEX "priority_user_unique";

ALTER TABLE "public"."priority_user"
    ADD CONSTRAINT "priority_user_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_user" validate CONSTRAINT "priority_user_user_id_fkey";

ALTER TABLE "public"."series"
    ADD CONSTRAINT "series_priority_id_fkey" FOREIGN KEY (priority_id) REFERENCES priority (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."series" validate CONSTRAINT "series_priority_id_fkey";

ALTER TABLE "public"."series"
    ADD CONSTRAINT "series_unique" UNIQUE USING INDEX "series_unique";

ALTER TABLE "public"."series"
    ADD CONSTRAINT "series_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."series" validate CONSTRAINT "series_user_id_fkey";

ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_at_check" CHECK (is_finite (at)) NOT valid;

ALTER TABLE "public"."session" validate CONSTRAINT "session_at_check";

ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_pomodoro_check" CHECK (((pomodoro IS NULL) OR (pomodoro > 0))) NOT valid;

ALTER TABLE "public"."session" validate CONSTRAINT "session_pomodoro_check";

ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_priority_id_fkey" FOREIGN KEY (priority_id) REFERENCES priority (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."session" validate CONSTRAINT "session_priority_id_fkey";

ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."session" validate CONSTRAINT "session_user_id_fkey";

ALTER TABLE "public"."token"
    ADD CONSTRAINT "token_owner_check" CHECK (((((user_id IS NOT NULL))::integer + ((publisher_id IS NOT NULL))::integer) = 1)) NOT valid;

ALTER TABLE "public"."token" validate CONSTRAINT "token_owner_check";

ALTER TABLE "public"."token"
    ADD CONSTRAINT "token_publisher_id_fkey" FOREIGN KEY (publisher_id) REFERENCES publisher (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."token" validate CONSTRAINT "token_publisher_id_fkey";

ALTER TABLE "public"."token"
    ADD CONSTRAINT "token_token_key" UNIQUE USING INDEX "token_token_key";

ALTER TABLE "public"."token"
    ADD CONSTRAINT "token_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."token" validate CONSTRAINT "token_user_id_fkey";

ALTER TABLE "public"."twist"
    ADD CONSTRAINT "twist_twist_admin_id_fkey" FOREIGN KEY (twist_admin_id) REFERENCES twist_admin (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."twist" validate CONSTRAINT "twist_twist_admin_id_fkey";

ALTER TABLE "public"."twist_admin"
    ADD CONSTRAINT "twist_admin_ownership_check" CHECK ((((publisher_id IS NOT NULL) AND (user_id IS NULL)) OR ((publisher_id IS NULL) AND (user_id IS NOT NULL)))) NOT valid;

ALTER TABLE "public"."twist_admin" validate CONSTRAINT "twist_admin_ownership_check";

ALTER TABLE "public"."twist_admin"
    ADD CONSTRAINT "twist_admin_package_user_unique" UNIQUE USING INDEX "twist_admin_package_user_unique";

ALTER TABLE "public"."twist_admin"
    ADD CONSTRAINT "twist_admin_priority_id_fkey" FOREIGN KEY (priority_id) REFERENCES priority (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."twist_admin" validate CONSTRAINT "twist_admin_priority_id_fkey";

ALTER TABLE "public"."twist_admin"
    ADD CONSTRAINT "twist_admin_publisher_id_fkey" FOREIGN KEY (publisher_id) REFERENCES publisher (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."twist_admin" validate CONSTRAINT "twist_admin_publisher_id_fkey";

ALTER TABLE "public"."twist_admin"
    ADD CONSTRAINT "twist_admin_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."twist_admin" validate CONSTRAINT "twist_admin_user_id_fkey";

ALTER TABLE "public"."usage"
    ADD CONSTRAINT "usage_cost_id_fkey" FOREIGN KEY (cost_id) REFERENCES COST (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."usage" validate CONSTRAINT "usage_cost_id_fkey";

ALTER TABLE "public"."usage"
    ADD CONSTRAINT "usage_hour_check" CHECK ((hour = date_trunc('hour'::text, hour))) NOT valid;

ALTER TABLE "public"."usage" validate CONSTRAINT "usage_hour_check";

ALTER TABLE "public"."usage"
    ADD CONSTRAINT "usage_priority_twist_id_fkey" FOREIGN KEY (priority_twist_id) REFERENCES priority_twist (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."usage" validate CONSTRAINT "usage_priority_twist_id_fkey";

ALTER TABLE "public"."usage"
    ADD CONSTRAINT "usage_priority_twist_id_hour_cost_id_key" UNIQUE USING INDEX "usage_priority_twist_id_hour_cost_id_key";

ALTER TABLE "public"."user_settings"
    ADD CONSTRAINT "user_settings_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."user_settings" validate CONSTRAINT "user_settings_user_id_fkey";

ALTER TABLE "public"."user_subscription"
    ADD CONSTRAINT "user_subscription_stripe_customer_id_key" UNIQUE USING INDEX "user_subscription_stripe_customer_id_key";

ALTER TABLE "public"."user_subscription"
    ADD CONSTRAINT "user_subscription_stripe_subscription_id_key" UNIQUE USING INDEX "user_subscription_stripe_subscription_id_key";

ALTER TABLE "public"."user_subscription"
    ADD CONSTRAINT "user_subscription_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."user_subscription" validate CONSTRAINT "user_subscription_user_id_fkey";

ALTER TABLE "public"."user_subscription"
    ADD CONSTRAINT "user_subscription_user_id_key" UNIQUE USING INDEX "user_subscription_user_id_key";

SET check_function_bodies = OFF;

CREATE OR REPLACE VIEW "public"."activity_tags" AS
SELECT
    activity_id,
    occurrence,
    jsonb_object_agg(tag_id, actor_ids) FILTER (WHERE ((actor_ids IS NOT NULL)
    AND (jsonb_array_length(actor_ids) > 0))) AS tags,
max(updated_at) AS updated_at,
(array_agg(updated_by ORDER BY sq.updated_at DESC))[1] AS updated_by
FROM (
    SELECT
        at.activity_id,
        at.occurrence,
        at.tag_id,
        jsonb_agg(at.actor_id) FILTER (WHERE (at.archived_at IS NULL)) AS actor_ids,
    max(COALESCE(at.archived_at, at.updated_at)) AS updated_at,
    (array_agg(at.updated_by ORDER BY at.updated_at DESC))[1] AS updated_by
FROM
    activity_tag at
GROUP BY
    at.activity_id,
    at.occurrence,
    at.tag_id) sq
GROUP BY
    activity_id,
    occurrence;

CREATE OR REPLACE VIEW "public"."activity_x" AS
SELECT
    a.id,
    a.created_at,
    a.updated_at,
    a.author_id,
    a.created_by,
    a.assignee_id,
    a.updated_by,
    a.archived_at,
    a.priority_id,
    a.type,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.at,
    a."on",
    a.duration,
    a.done_at,
    a.recurrence_rule,
    a.recurrence_exdates,
    a.recurrence_dates,
    a.meta,
    a.source,
    a.created_by_twist_id,
    a.embedding,
    a.pick_priority,
    a.last_note_created_at,
    p.path AS priority_path,
    m.mentions
FROM ((activity a
        JOIN priority p ON (p.id = a.priority_id))
    LEFT JOIN (
        SELECT
            n.activity_id,
            array_agg(DISTINCT mention.mention) AS mentions
        FROM
            note n,
            LATERAL unnest(n.mentions) mention (mention)
        WHERE ((n.archived_at IS NULL)
            AND (n.mentions IS NOT NULL))
    GROUP BY
        n.activity_id) m ON (m.activity_id = a.id));

CREATE OR REPLACE VIEW "public"."actor" AS
SELECT
    c.id,
    c.created_at,
    c.updated_at,
    CASE WHEN (c.user_id IS NOT NULL) THEN
        'user'::text
    ELSE
        'contact'::text
    END AS type,
    COALESCE(c.name, c.email) AS name,
    c.email,
    c.avatar_url,
    c.archived_at
FROM
    contact c
UNION ALL
SELECT
    pt.id,
    pt.created_at,
    pt.updated_at,
    'priority_twist'::text AS type,
    pt.name,
    NULL::text AS email,
    NULL::text AS avatar_url,
    pt.archived_at
FROM
    priority_twist pt;

CREATE OR REPLACE FUNCTION public.actor (activity)
    RETURNS SETOF actor
    LANGUAGE sql
    STABLE ROWS 1
    AS $function$
    SELECT
        actor.*
    FROM
        actor
    WHERE
        actor.id = $1.author_id
$function$;

CREATE OR REPLACE FUNCTION public.actor (note)
    RETURNS SETOF actor
    LANGUAGE sql
    STABLE ROWS 1
    AS $function$
    SELECT
        actor.*
    FROM
        actor
    WHERE
        actor.id = $1.author_id
$function$;

CREATE OR REPLACE FUNCTION public.all_views_secure ()
    RETURNS boolean
    LANGUAGE plpgsql
    AS $function$
DECLARE
    VIEW text;
BEGIN
    SELECT
        relname INTO VIEW
    FROM
        pg_class
        JOIN pg_catalog.pg_namespace n ON n.oid = pg_class.relnamespace
    WHERE
        n.nspname = 'public'
        AND relname NOT LIKE '%_admin'
        AND relkind = 'v'
        AND (lower(reloptions::text)::text[] && ARRAY['security_invoker=1', 'security_invoker=true', 'security_invoker=on']) IS NULL;
    IF FOUND THEN
        RAISE EXCEPTION 'Found view without security_invoker: %', VIEW;
    END IF;
    RETURN TRUE;
END
$function$;

CREATE OR REPLACE FUNCTION public.assignee (activity)
    RETURNS SETOF actor
    LANGUAGE sql
    STABLE ROWS 1
    AS $function$
    SELECT
        actor.*
    FROM
        actor
    WHERE
        actor.id = $1.assignee_id
$function$;

CREATE OR REPLACE FUNCTION public.can_access_priority (_priority_id uuid)
    RETURNS boolean
    LANGUAGE sql
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.user_priority_expanded upe
            WHERE
                upe.user_id = auth.uid ()
                AND upe.priority_id = _priority_id);
$function$;

CREATE OR REPLACE FUNCTION public.can_access_priority (_priority_path ltree)
    RETURNS boolean
    LANGUAGE sql
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.priority_user pu
                JOIN public.priority p ON p.id = pu.priority_id
            WHERE
                pu.user_id = auth.uid ()
                AND p.path @> _priority_path);
$function$;

CREATE TYPE "public"."contact_upsert" AS (
    "calendar_id" bigint,
    "email" text,
    "name" text,
    "avatar_url" text
);

CREATE OR REPLACE FUNCTION public.count_not_null (val anyelement)
    RETURNS integer
    LANGUAGE sql
    IMMUTABLE
    AS $function$
    SELECT
        CASE WHEN val IS NULL THEN
            0
        ELSE
            1
        END;
$function$;

CREATE OR REPLACE FUNCTION public.find_matching_activities_scored (query_embedding text, created_by_id uuid, required_filters jsonb DEFAULT '{}' ::jsonb, scored_fields jsonb DEFAULT '{}' ::jsonb, activity_data jsonb DEFAULT '{}' ::jsonb, similarity_threshold double precision DEFAULT 0.7)
    RETURNS TABLE (
        id uuid,
        priority_id uuid,
        title text,
        total_score double precision)
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN QUERY WITH filtered_activities AS (
        -- First filter by required exact matches
        SELECT
            a.id,
            a.priority_id,
            a.title,
            a.type,
            a.mentions,
            a.meta,
            a.embedding
        FROM
            public.activity a
        WHERE
            a.created_by = created_by_id
            AND a.archived_at IS NULL
            -- Content similarity filter (when content is required)
            AND ((required_filters ? 'content'
                    AND a.embedding IS NOT NULL
                    AND (1 - (a.embedding <=> query_embedding::vector)) >= similarity_threshold)
                OR NOT (required_filters ? 'content'))
            -- Type exact match (when type is required)
            AND ((required_filters ? 'type'
                    AND a.type = (activity_data ->> 'type')::int)
                OR NOT (required_filters ? 'type'))
            -- Meta field exact matches (when meta.field is required)
            AND (
                -- Check all required meta fields match
                NOT EXISTS (
                    SELECT
                        1
                    FROM
                        jsonb_object_keys(required_filters) AS key
                    WHERE
                        key LIKE 'meta.%'
                        AND (a.meta IS NULL
                            OR a.meta ->> substring(key FROM 6) IS DISTINCT FROM activity_data -> 'meta' ->> substring(key FROM 6))))
),
scored_activities AS (
    -- Calculate scores for each matching activity
    SELECT
        fa.id,
        fa.priority_id,
        fa.title,
        -- Sum up all scores
        (
            -- Content similarity score
            COALESCE(
                CASE WHEN scored_fields ? 'content'
                    AND fa.embedding IS NOT NULL THEN
                    (scored_fields ->> 'content')::float * (1 - (fa.embedding <=> query_embedding::vector))
                ELSE
                    0
                END, 0) +
            -- Type exact match score
            COALESCE(
                CASE WHEN scored_fields ? 'type' THEN
                    CASE WHEN fa.type = (activity_data ->> 'type')::int THEN
                        (scored_fields ->> 'type')::float
                    ELSE
                        0
                END
                ELSE
                    0
                END, 0) +
            -- Mentions array overlap score
            COALESCE(
                CASE WHEN scored_fields ? 'mentions'
                    AND fa.mentions IS NOT NULL
                    AND jsonb_array_length(activity_data -> 'mentions') > 0 THEN
                    (scored_fields ->> 'mentions')::float * (
                        -- Count matching elements / length of existing array
                        (
                            SELECT
                                COUNT(*)::float
                            FROM jsonb_array_elements_text(fa.mentions::jsonb) existing_mention
                            WHERE
                                existing_mention IN (
                                    SELECT
                                        jsonb_array_elements_text(activity_data -> 'mentions'))) / jsonb_array_length(fa.mentions::jsonb))
                ELSE
                    0
                END, 0) +
            -- Meta field exact match scores
            COALESCE((
                SELECT
                    COALESCE(SUM(
                            CASE WHEN fa.meta IS NOT NULL
                                AND fa.meta ->> substring(key FROM 6) IS NOT DISTINCT FROM activity_data -> 'meta' ->> substring(key FROM 6) THEN
                                (scored_fields ->> key)::float
                            ELSE
                                0
                            END), 0)
                FROM jsonb_object_keys(scored_fields) AS key
                WHERE
                    key LIKE 'meta.%'), 0)) AS total_score
FROM
    filtered_activities fa
)
SELECT
    sa.id,
    sa.priority_id,
    sa.title,
    sa.total_score
FROM
    scored_activities sa
WHERE
    sa.total_score > 0
ORDER BY
    sa.total_score DESC
LIMIT 1;
END;
$function$;

CREATE OR REPLACE FUNCTION public.find_similar_activities (query_embedding text, created_by_id uuid, similarity_threshold double precision DEFAULT 0.5, match_limit integer DEFAULT 1)
    RETURNS TABLE (
        id uuid,
        priority_id uuid,
        title text,
        similarity double precision)
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN QUERY
    SELECT
        a.id,
        a.priority_id,
        a.title,
        1 - (a.embedding <=> query_embedding::vector) AS similarity
    FROM
        public.activity a
    WHERE
        a.created_by = created_by_id
        AND a.embedding IS NOT NULL
        AND a.archived_at IS NULL
        AND (1 - (a.embedding <=> query_embedding::vector)) >= similarity_threshold
    ORDER BY
        a.embedding <=> query_embedding::vector
    LIMIT match_limit;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_accessible_twists (p_priority_id uuid)
    RETURNS SETOF twist
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    AS $function$
    SELECT DISTINCT
        twist.*
    FROM
        twist
        JOIN twist_admin ON twist.twist_admin_id = twist_admin.id
    WHERE
        twist.environment = 'public'
        OR (twist.environment = 'personal'
            AND twist_admin.user_id = auth.uid ())
        OR can_access_priority (twist_admin.priority_id)
$function$;

CREATE OR REPLACE FUNCTION public.get_api_root ()
    RETURNS text
    LANGUAGE plpgsql
    STABLE
    AS $function$
BEGIN
    RETURN COALESCE(current_setting('plot.api_root', TRUE), 'http://host.docker.internal:8787/sync');
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_domain (email text)
    RETURNS text
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
DECLARE
BEGIN
    RETURN lower(regexp_replace(split_part(email, '@', 2), '\s+', '', 'g'));
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_tag_type (tag_id integer)
    RETURNS tag_type
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
BEGIN
    IF tag_id BETWEEN 1 AND 99 THEN
        RETURN 'compute'::tag_type;
    ELSIF tag_id BETWEEN 100 AND 999 THEN
        RETURN 'toggle'::tag_type;
    ELSE
        RETURN 'count'::tag_type;
    END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_users_with_priority_access (target_priority_id uuid)
    RETURNS TABLE (
        user_id uuid)
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    AS $function$
    SELECT DISTINCT
        pu.user_id
    FROM
        priority_user pu
        JOIN priority pp ON pu.priority_id = pp.id
        JOIN priority p ON p.path <@ pp.path
    WHERE
        pu.archived_at IS NULL
        AND p.id = get_users_with_priority_access.target_priority_id;
$function$;

CREATE OR REPLACE FUNCTION public.handle_user_priority_upsert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    _priority_id uuid;
    _is_creator boolean;
    _priority_default_color integer;
BEGIN
    _priority_id := NEW.id;
    _is_creator := (NEW.created_by = COALESCE(auth.uid (), NEW.user_id));
    -- Get the priority's default color for initializing new priority_settings
    SELECT
        color INTO _priority_default_color
    FROM
        priority
    WHERE
        id = NEW.id;
    -- Update priority table fields (title, path, archived_at, updated_by)
    -- If creator is updating color, also update priority.color
    IF (OLD IS NULL OR NEW.archived_at IS DISTINCT FROM OLD.archived_at OR NEW.title IS DISTINCT FROM OLD.title OR NEW.path IS DISTINCT FROM OLD.path OR NEW.updated_by IS DISTINCT FROM OLD.updated_by OR (_is_creator AND NEW.color IS DISTINCT FROM OLD.color)) THEN
        INSERT INTO priority (id, archived_at, title, color, path, created_by, updated_by)
            VALUES (NEW.id, NEW.archived_at, NEW.title, CASE WHEN _is_creator THEN
                    NEW.color
                ELSE
                    NULL
                END, NEW.path, NEW.created_by, NEW.updated_by)
        ON CONFLICT (id)
            DO UPDATE SET
                archived_at = NEW.archived_at,
                title = NEW.title,
                color = CASE WHEN _is_creator THEN
                    NEW.color
                ELSE
                    priority.color
                END,
                path = NEW.path,
                updated_by = NEW.updated_by
            RETURNING
                id INTO _priority_id;
    END IF;
    -- Update priority_settings for user-specific inherited fields
    -- Always update priority_settings.color when color changes (for all users)
    -- Initialize color from priority.color if not provided by user
    IF ((OLD IS NULL AND (NEW."path" IS NOT NULL OR NEW."top_order" IS NOT NULL OR NEW."pomodoro" IS NOT NULL OR NEW."color" IS NOT NULL)) OR (OLD IS NOT NULL AND (NEW."path" IS DISTINCT FROM OLD."path" OR NEW."top_order" IS DISTINCT FROM OLD."top_order" OR NEW."pomodoro" IS DISTINCT FROM OLD."pomodoro" OR NEW."color" IS DISTINCT FROM OLD."color"))) THEN
        INSERT INTO priority_settings (user_id, priority_id, path, top_order, pomodoro, color)
            VALUES (COALESCE(auth.uid (), NEW.user_id), _priority_id, NEW.path, NEW.top_order, NEW.pomodoro, COALESCE(NEW.color, _priority_default_color))
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                path = COALESCE(NEW.path, priority_settings.path),
                top_order = COALESCE(NEW.top_order, priority_settings.top_order),
                pomodoro = COALESCE(NEW.pomodoro, priority_settings.pomodoro),
                color = COALESCE(NEW.color, priority_settings.color);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.insert_domain (email text)
    RETURNS bigint
    LANGUAGE plpgsql
    AS $function$
DECLARE
    domain_name text := get_domain (email);
    domain_id bigint;
    org_id bigint;
BEGIN
    SELECT
        id INTO domain_id
    FROM
        public.domain
    WHERE
        "name" = domain_name;
    IF NOT FOUND THEN
        INSERT INTO organization (name)
            VALUES (domain_name)
        RETURNING
            id INTO org_id;
        INSERT INTO public.domain (organization_id, "name")
            VALUES (org_id, domain_name);
    END IF;
    RETURN domain_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.insert_email_domain ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
BEGIN
    IF NEW.email IS NULL THEN
        RETURN NEW;
    END IF;
    PERFORM
        public.insert_domain (NEW.email);
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.insert_priority_user ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
BEGIN
    -- Only create entry for new, top-level priorities.
    IF nlevel (NEW.path) = 1 THEN
        INSERT INTO public.priority_user (user_id, priority_id)
            VALUES (NEW.created_by, NEW.id);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.is_accessible_twist (p_twist_id bigint, p_priority_id uuid)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                twist
                JOIN twist_admin ON twist.twist_admin_id = twist_admin.id
            WHERE
                twist.id = p_twist_id
                AND (twist.environment = 'public'
                    OR (twist.environment = 'personal'
                        AND twist_admin.user_id = auth.uid ())
                    OR can_access_priority (twist_admin.priority_id)))
$function$;

CREATE OR REPLACE FUNCTION public.migrate_existing_users_to_contacts ()
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
DECLARE
    _user_record record;
    _user_name text;
    _contact_id uuid;
    _updated_app_metadata jsonb;
BEGIN
    -- Loop through all existing auth users and create/update corresponding contacts
    FOR _user_record IN
    SELECT
        id,
        email,
        raw_app_meta_data
    FROM
        auth.users
    WHERE
        email IS NOT NULL LOOP
            -- Extract name from user metadata
            _user_name := COALESCE(_user_record.raw_app_meta_data ->> 'full_name', _user_record.raw_app_meta_data ->> 'name', _user_record.email);
            -- Upsert contact for this user and get contact ID
            _contact_id := public.upsert_user_contact (_user_record.id, _user_record.email, _user_name, _user_record.raw_app_meta_data ->> 'avatar_url');
            -- Update the user's app_metadata with contact_id
            _updated_app_metadata := COALESCE(_user_record.raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('contact_id', _contact_id);
            -- Update the user record with the new app_metadata
            UPDATE
                auth.users
            SET
                raw_app_meta_data = _updated_app_metadata
            WHERE
                id = _user_record.id;
        END LOOP;
    RAISE NOTICE 'Migration completed: synchronized % users with contacts', (
        SELECT
            COUNT(*)
        FROM
            auth.users
        WHERE
            email IS NOT NULL);
END;
$function$;

CREATE OR REPLACE FUNCTION public.move_priority (p_priority_id uuid, p_new_parent_path ltree)
    RETURNS void
    LANGUAGE plpgsql
    AS $function$
DECLARE
    v_old_path ltree;
    v_new_path ltree;
    v_priority_label text;
BEGIN
    -- Get the current path of the priority being moved
    SELECT
        path INTO v_old_path
    FROM
        public.priority
    WHERE
        id = p_priority_id;
    -- If priority doesn't exist, raise an exception
    IF v_old_path IS NULL THEN
        RAISE EXCEPTION 'Priority with id % not found', p_priority_id;
    END IF;
    -- Prevent moving a priority to be a descendant of itself
    IF p_new_parent_path IS NOT NULL AND (p_new_parent_path <@ v_old_path OR p_new_parent_path = v_old_path) THEN
        RAISE EXCEPTION 'Cannot move priority to be a descendant of itself';
    END IF;
    -- Extract the last label from the current path (the priority's own identifier)
    v_priority_label := ltree2text (subpath (v_old_path, -1));
    -- Calculate the new path
    IF p_new_parent_path IS NULL THEN
        -- Moving to root level
        v_new_path := text2ltree (v_priority_label);
    ELSE
        -- Moving under a parent
        v_new_path := text2ltree (ltree2text (p_new_parent_path) || '.' || v_priority_label);
    END IF;
    -- Update all priorities whose path starts with the old path
    -- This includes the priority itself and all its descendants
    UPDATE
        public.priority
    SET
        path = CASE
        -- For the priority itself, use the new path directly
        WHEN path = v_old_path THEN
            v_new_path
            -- For descendants, replace the old path prefix with the new path
        ELSE
            text2ltree (ltree2text (v_new_path) || ltree2text (subpath (path, nlevel (v_old_path))))
        END
    WHERE
        path <@ v_old_path
        OR path = v_old_path;
END;
$function$;

CREATE OR REPLACE VIEW "public"."note_tags" AS
SELECT
    note_id,
    jsonb_object_agg(tag_id, actor_ids) FILTER (WHERE ((actor_ids IS NOT NULL)
    AND (jsonb_array_length(actor_ids) > 0))) AS tags,
max(updated_at) AS updated_at,
(array_agg(updated_by ORDER BY sq.updated_at DESC))[1] AS updated_by
FROM (
    SELECT
        nt.note_id,
        nt.tag_id,
        jsonb_agg(nt.actor_id) FILTER (WHERE (nt.archived_at IS NULL)) AS actor_ids,
    max(COALESCE(nt.archived_at, nt.updated_at)) AS updated_at,
    (array_agg(nt.updated_by ORDER BY nt.updated_at DESC))[1] AS updated_by
FROM
    note_tag nt
GROUP BY
    nt.note_id,
    nt.tag_id) sq
GROUP BY
    note_id;

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_activity ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    event_type text;
    twists_data jsonb;
    users_data jsonb;
    enriched_item jsonb;
    previous_enriched_item jsonb;
    current_tags jsonb;
    previous_tags jsonb;
    payload jsonb;
    api_url text;
    hmac_secret text;
    signature text;
    current_item record;
    previous_item record;
BEGIN
    IF TG_OP = 'INSERT' THEN
        event_type := 'created';
        current_item := NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        event_type := 'updated';
        current_item := NEW;
        previous_item := OLD;
    END IF;
    -- Extract twists query into a variable
    SELECT
        jsonb_agg(jsonb_build_object('id', twist_id, 'environment', twist_environment, 'version', version, 'priority_twist_id', id, 'config', config)) INTO twists_data
    FROM
        public.priority_child_twist
    WHERE
        priority_child_id = current_item.priority_id
        AND id != current_item.author_id
        AND archived_at IS NULL;
    -- Get users who have access to this priority
    SELECT
        jsonb_agg(jsonb_build_object('user_id', user_id)) INTO users_data
    FROM
        public.get_users_with_priority_access (current_item.priority_id);
    -- Exit early if no twists or users found
    IF (twists_data IS NULL OR jsonb_array_length(twists_data) = 0) AND (users_data IS NULL OR jsonb_array_length(users_data) = 0) THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    -- Build enriched item with author and priority information
    SELECT
        jsonb_build_object('id', current_item.id, 'created_at', current_item.created_at, 'updated_at', current_item.updated_at, 'author_id', current_item.author_id, 'created_by', current_item.created_by, 'assignee_id', current_item.assignee_id, 'updated_by', current_item.updated_by, 'archived_at', current_item.archived_at, 'priority_id', current_item.priority_id, 'type', current_item.type, 'order', current_item.order, 'draft', current_item.draft, 'private', current_item.private, 'title', current_item.title, 'preview', current_item.preview, 'at', current_item.at, 'on', current_item.on, 'duration', current_item.duration, 'done_at', current_item.done_at, 'recurrence_rule', current_item.recurrence_rule, 'recurrence_exdates', current_item.recurrence_exdates, 'recurrence_dates', current_item.recurrence_dates, 'source', current_item.source, 'meta', current_item.meta, 'mentions', (
                SELECT
                    ARRAY ( SELECT DISTINCT
                            unnest(n.mentions)
                    FROM note n
                    WHERE
                        n.activity_id = current_item.id
                        AND n.archived_at IS NULL
                        AND n.mentions IS NOT NULL)),
            -- Enriched data from JOINs
            'author_name', a.name, 'author_type', a.type, 'priority_title', p.title) INTO enriched_item
    FROM
        actor a,
        priority p
    WHERE
        a.id = current_item.author_id
        AND p.id = current_item.priority_id;
    -- Get tags for current activity
    SELECT
        tags INTO current_tags
    FROM
        activity_tags
    WHERE
        activity_id = current_item.id;
    -- Add tags to enriched item
    enriched_item := enriched_item || jsonb_build_object('tags', current_tags);
    -- Build previous enriched item for updates
    IF TG_OP = 'UPDATE' THEN
        SELECT
            jsonb_build_object('id', previous_item.id, 'created_at', previous_item.created_at, 'updated_at', previous_item.updated_at, 'author_id', previous_item.author_id, 'created_by', previous_item.created_by, 'assignee_id', previous_item.assignee_id, 'updated_by', previous_item.updated_by, 'archived_at', previous_item.archived_at, 'priority_id', previous_item.priority_id, 'type', previous_item.type, 'order', previous_item.order, 'draft', previous_item.draft, 'private', previous_item.private, 'title', previous_item.title, 'preview', previous_item.preview, 'at', previous_item.at, 'on', previous_item.on, 'duration', previous_item.duration, 'done_at', previous_item.done_at, 'recurrence_rule', previous_item.recurrence_rule, 'recurrence_exdates', previous_item.recurrence_exdates, 'recurrence_dates', previous_item.recurrence_dates, 'source', previous_item.source, 'meta', previous_item.meta, 'mentions', (
                    SELECT
                        ARRAY ( SELECT DISTINCT
                                unnest(n.mentions)
                        FROM note n
                        WHERE
                            n.activity_id = previous_item.id
                            AND n.archived_at IS NULL
                            AND n.mentions IS NOT NULL)),
                -- Enriched data from JOINs
                'author_name', a.name, 'author_type', a.type, 'priority_title', p.title) INTO previous_enriched_item
        FROM
            actor a,
            priority p
        WHERE
            a.id = previous_item.author_id
            AND p.id = previous_item.priority_id;
        -- Get tags for previous activity state
        SELECT
            tags INTO previous_tags
        FROM
            activity_tags
        WHERE
            activity_id = previous_item.id;
        -- Add tags to previous enriched item
        previous_enriched_item := previous_enriched_item || jsonb_build_object('tags', previous_tags);
    END IF;
    -- Build the payload
    IF TG_OP = 'UPDATE' THEN
        payload := jsonb_build_object('type', 'activity', 'event', event_type, 'item', enriched_item, 'previous', previous_enriched_item, 'twists', COALESCE(twists_data, '[]'::jsonb), 'users', COALESCE(users_data, '[]'::jsonb), 'timestamp', extract(epoch FROM now()), 'table', 'activity');
    ELSE
        payload := jsonb_build_object('type', 'activity', 'event', event_type, 'item', enriched_item, 'twists', COALESCE(twists_data, '[]'::jsonb), 'users', COALESCE(users_data, '[]'::jsonb), 'timestamp', extract(epoch FROM now()), 'table', 'activity');
    END IF;
    api_url := public.get_api_root () || '/update';
    hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
    signature := encode(extensions.hmac(convert_to(payload::text, 'UTF8'), hmac_secret::bytea, 'sha256'), 'hex');
    PERFORM
        net.http_post (url := api_url, body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_activity_read ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    event_type text;
    users_data jsonb;
    enriched_item jsonb;
    payload jsonb;
    api_url text;
    hmac_secret text;
    signature text;
    current_item record;
BEGIN
    IF TG_OP = 'INSERT' THEN
        event_type := 'created';
        current_item := NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        event_type := 'updated';
        current_item := NEW;
    END IF;
    -- Get user for this activity_read record
    SELECT
        jsonb_agg(jsonb_build_object('user_id', current_item.user_id)) INTO users_data;
    -- Exit early if no users found
    IF users_data IS NULL OR jsonb_array_length(users_data) = 0 THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    -- Build minimal enriched item (only what's needed for sync)
    enriched_item := jsonb_build_object('user_id', current_item.user_id, 'activity_id', current_item.activity_id, 'read_at', current_item.read_at, 'updated_at', current_item.updated_at);
    -- Build the payload (no twists for activity_read)
    payload := jsonb_build_object('type', 'activity_read', 'event', event_type, 'item', enriched_item, 'twists', '[]'::jsonb, 'users', users_data, 'timestamp', extract(epoch FROM now()), 'table', 'activity_read');
    api_url := public.get_api_root () || '/update';
    hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
    signature := encode(extensions.hmac(convert_to(payload::text, 'UTF8'), hmac_secret::bytea, 'sha256'), 'hex');
    PERFORM
        net.http_post (url := api_url, body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_note ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    event_type text;
    twists_data jsonb;
    users_data jsonb;
    enriched_item jsonb;
    previous_enriched_item jsonb;
    current_tags jsonb;
    previous_tags jsonb;
    payload jsonb;
    api_url text;
    hmac_secret text;
    signature text;
    current_item record;
    previous_item record;
    parent_priority_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        event_type := 'created';
        current_item := NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        event_type := 'updated';
        current_item := NEW;
        previous_item := OLD;
    END IF;
    -- Get the parent activity's priority_id
    SELECT
        priority_id INTO parent_priority_id
    FROM
        activity
    WHERE
        id = current_item.activity_id;
    -- Exit early if parent activity not found
    IF parent_priority_id IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    -- Extract twists query into a variable
    SELECT
        jsonb_agg(jsonb_build_object('id', twist_id, 'environment', twist_environment, 'version', version, 'priority_twist_id', id, 'config', config)) INTO twists_data
    FROM
        public.priority_child_twist
    WHERE
        priority_child_id = parent_priority_id
        AND id != current_item.author_id
        AND archived_at IS NULL;
    -- Get users who have access to this priority
    SELECT
        jsonb_agg(jsonb_build_object('user_id', user_id)) INTO users_data
    FROM
        public.get_users_with_priority_access (parent_priority_id);
    -- Exit early if no twists or users found
    IF (twists_data IS NULL OR jsonb_array_length(twists_data) = 0) AND (users_data IS NULL OR jsonb_array_length(users_data) = 0) THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    -- Build enriched item with author and activity information
    SELECT
        jsonb_build_object('id', current_item.id, 'created_at', current_item.created_at, 'updated_at', current_item.updated_at, 'author_id', current_item.author_id, 'created_by', current_item.created_by, 'updated_by', current_item.updated_by, 'archived_at', current_item.archived_at, 'activity_id', current_item.activity_id, 'draft', current_item.draft, 'private', current_item.private, 'content', current_item.content, 'links', current_item.links, 'mentions', current_item.mentions,
            -- Enriched data from JOINs
            'author_name', a.name, 'author_type', a.type, 'activity_title', act.title, 'priority_id', act.priority_id) INTO enriched_item
    FROM
        actor a,
        activity act
    WHERE
        a.id = current_item.author_id
        AND act.id = current_item.activity_id;
    -- Get tags for current note
    SELECT
        tags INTO current_tags
    FROM
        note_tags
    WHERE
        note_id = current_item.id;
    -- Add tags to enriched item
    enriched_item := enriched_item || jsonb_build_object('tags', current_tags);
    -- Build previous enriched item for updates
    IF TG_OP = 'UPDATE' THEN
        SELECT
            jsonb_build_object('id', previous_item.id, 'created_at', previous_item.created_at, 'updated_at', previous_item.updated_at, 'author_id', previous_item.author_id, 'created_by', previous_item.created_by, 'updated_by', previous_item.updated_by, 'archived_at', previous_item.archived_at, 'activity_id', previous_item.activity_id, 'draft', previous_item.draft, 'private', previous_item.private, 'content', previous_item.content, 'links', previous_item.links, 'mentions', previous_item.mentions,
                -- Enriched data from JOINs
                'author_name', a.name, 'author_type', a.type, 'activity_title', act.title, 'priority_id', act.priority_id) INTO previous_enriched_item
        FROM
            actor a,
            activity act
        WHERE
            a.id = previous_item.author_id
            AND act.id = previous_item.activity_id;
        -- Get tags for previous note state
        SELECT
            tags INTO previous_tags
        FROM
            note_tags
        WHERE
            note_id = previous_item.id;
        -- Add tags to previous enriched item
        previous_enriched_item := previous_enriched_item || jsonb_build_object('tags', previous_tags);
    END IF;
    -- Build the payload
    IF TG_OP = 'UPDATE' THEN
        payload := jsonb_build_object('type', 'note', 'event', event_type, 'item', enriched_item, 'previous', previous_enriched_item, 'twists', COALESCE(twists_data, '[]'::jsonb), 'users', COALESCE(users_data, '[]'::jsonb), 'timestamp', extract(epoch FROM now()), 'table', 'note');
    ELSE
        payload := jsonb_build_object('type', 'note', 'event', event_type, 'item', enriched_item, 'twists', COALESCE(twists_data, '[]'::jsonb), 'users', COALESCE(users_data, '[]'::jsonb), 'timestamp', extract(epoch FROM now()), 'table', 'note');
    END IF;
    api_url := public.get_api_root () || '/update';
    hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
    signature := encode(extensions.hmac(convert_to(payload::text, 'UTF8'), hmac_secret::bytea, 'sha256'), 'hex');
    PERFORM
        net.http_post (url := api_url, body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_priority ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    event_type text;
    users_data jsonb;
    enriched_item jsonb;
    payload jsonb;
    api_url text;
    hmac_secret text;
    signature text;
    current_item record;
BEGIN
    IF TG_OP = 'INSERT' THEN
        event_type := 'created';
        current_item := NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        event_type := 'updated';
        current_item := NEW;
    END IF;
    -- Get users who have access to this priority (just the creator for now)
    SELECT
        jsonb_agg(jsonb_build_object('user_id', current_item.created_by)) INTO users_data;
    -- Exit early if no users found
    IF users_data IS NULL OR jsonb_array_length(users_data) = 0 THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    -- Build enriched item
    enriched_item := jsonb_build_object('id', current_item.id, 'created_at', current_item.created_at, 'updated_at', current_item.updated_at, 'created_by', current_item.created_by, 'root', current_item.root, 'archived_at', current_item.archived_at, 'title', current_item.title, 'path', current_item.path, 'updated_by', current_item.updated_by);
    -- Build the payload (no twists for priority)
    payload := jsonb_build_object('type', 'priority', 'event', event_type, 'item', enriched_item, 'twists', '[]'::jsonb, 'users', users_data, 'timestamp', extract(epoch FROM now()), 'table', 'priority');
    api_url := public.get_api_root () || '/update';
    hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
    signature := encode(extensions.hmac(convert_to(payload::text, 'UTF8'), hmac_secret::bytea, 'sha256'), 'hex');
    PERFORM
        net.http_post (url := api_url, body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_priority_twist ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    event_type text;
    twists_data jsonb;
    users_data jsonb;
    enriched_item jsonb;
    payload jsonb;
    api_url text;
    hmac_secret text;
    signature text;
    current_item record;
BEGIN
    IF TG_OP = 'INSERT' THEN
        event_type := 'created';
        current_item := NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        event_type := 'updated';
        current_item := NEW;
    END IF;
    -- Get twists that have access to this priority (excluding the current twist)
    SELECT
        jsonb_agg(jsonb_build_object('id', twist_id, 'environment', twist_environment, 'version', version, 'priority_twist_id', id, 'config', config)) INTO twists_data
    FROM
        public.priority_child_twist
    WHERE
        priority_child_id = current_item.priority_id
        AND id != current_item.id
        AND archived_at IS NULL;
    -- Get users who have access to this priority
    SELECT
        jsonb_agg(jsonb_build_object('user_id', user_id)) INTO users_data
    FROM
        public.get_users_with_priority_access (current_item.priority_id);
    -- Exit early if no twists or users found
    IF (twists_data IS NULL OR jsonb_array_length(twists_data) = 0) AND (users_data IS NULL OR jsonb_array_length(users_data) = 0) THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    -- Build enriched item
    enriched_item := jsonb_build_object('id', current_item.id, 'created_at', current_item.created_at, 'updated_at', current_item.updated_at, 'archived_at', current_item.archived_at, 'priority_id', current_item.priority_id, 'twist_id', current_item.twist_id, 'owner_id', current_item.owner_id, 'name', current_item.name, 'config', current_item.config);
    -- Build the payload
    payload := jsonb_build_object('type', 'priority_twist', 'event', event_type, 'item', enriched_item, 'twists', COALESCE(twists_data, '[]'::jsonb), 'users', COALESCE(users_data, '[]'::jsonb), 'timestamp', extract(epoch FROM now()), 'table', 'priority_twist');
    api_url := public.get_api_root () || '/update';
    hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
    signature := encode(extensions.hmac(convert_to(payload::text, 'UTF8'), hmac_secret::bytea, 'sha256'), 'hex');
    PERFORM
        net.http_post (url := api_url, body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_session ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    event_type text;
    users_data jsonb;
    enriched_item jsonb;
    payload jsonb;
    api_url text;
    hmac_secret text;
    signature text;
    current_item record;
BEGIN
    IF TG_OP = 'INSERT' THEN
        event_type := 'created';
        current_item := NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        event_type := 'updated';
        current_item := NEW;
    END IF;
    -- Get user for this session
    SELECT
        jsonb_agg(jsonb_build_object('user_id', current_item.user_id)) INTO users_data;
    -- Exit early if no users found
    IF users_data IS NULL OR jsonb_array_length(users_data) = 0 THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    -- Build enriched item
    enriched_item := jsonb_build_object('id', current_item.id, 'created_at', current_item.created_at, 'updated_at', current_item.updated_at, 'archived_at', current_item.archived_at, 'user_id', current_item.user_id, 'priority_id', current_item.priority_id, 'at', current_item.at, 'precedence', current_item.precedence, 'pomodoro', current_item.pomodoro, 'pomodoro_at', current_item.pomodoro_at, 'updated_by', current_item.updated_by);
    -- Build the payload (no twists for session)
    payload := jsonb_build_object('type', 'session', 'event', event_type, 'item', enriched_item, 'twists', '[]'::jsonb, 'users', users_data, 'timestamp', extract(epoch FROM now()), 'table', 'session');
    api_url := public.get_api_root () || '/update';
    hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
    signature := encode(extensions.hmac(convert_to(payload::text, 'UTF8'), hmac_secret::bytea, 'sha256'), 'hex');
    PERFORM
        net.http_post (url := api_url, body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE OR REPLACE FUNCTION public.organization (contact)
    RETURNS SETOF organization
    LANGUAGE sql
    STABLE ROWS 1
    AS $function$
    SELECT
        organization.*
    FROM
        organization
        JOIN "domain" ON organization.id = domain.organization_id
    WHERE
        domain.name = get_domain ($1.email)
$function$;

CREATE OR REPLACE FUNCTION public.parent_path (p ltree)
    RETURNS ltree
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
BEGIN
    IF nlevel (p) = 1 THEN
        RETURN p;
    END IF;
    RETURN subpath (p, 0, nlevel (p) - 1);
END;
$function$;

CREATE OR REPLACE FUNCTION public.prevent_priority_root_change ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    -- Check if root column is being changed
    IF OLD.root IS DISTINCT FROM NEW.root THEN
        RAISE EXCEPTION 'Cannot change the root column of a priority after creation';
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.prevent_priority_twist_immutable_changes ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
BEGIN
    -- Prevent changing twist_id
    IF OLD.twist_id IS DISTINCT FROM NEW.twist_id THEN
        RAISE EXCEPTION 'Cannot change twist_id of an existing priority_twist';
    END IF;
    -- Prevent changing owner_id
    IF OLD.owner_id IS DISTINCT FROM NEW.owner_id THEN
        RAISE EXCEPTION 'Cannot change owner_id of an existing priority_twist';
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE VIEW "public"."priority_child" AS
SELECT
    p.id AS priority_id,
    c.id AS child_id,
    c.archived_at
FROM (priority p
    JOIN priority c ON (c.path <@ p.path));

CREATE OR REPLACE VIEW "public"."priority_child_twist" AS
SELECT
    pt.id,
    pt.priority_id,
    pt.twist_id,
    pt.owner_id,
    pt.name,
    pt.config,
    pt.created_at,
    pt.updated_at,
    pt.archived_at,
    t.version,
    t.environment AS twist_environment,
    p.name AS author_name,
    p.email AS author_email,
    p.url AS author_url,
    pc.child_id AS priority_child_id
FROM ((((priority_twist pt
                JOIN priority_child pc ON (pt.priority_id = pc.priority_id))
            JOIN twist t ON (pt.twist_id = t.id))
        JOIN twist_admin ta ON (t.twist_admin_id = ta.id))
    LEFT JOIN publisher p ON (ta.publisher_id = p.id))
WHERE (pt.archived_at IS NULL);

CREATE OR REPLACE VIEW "public"."priority_settings_inherited" AS
WITH inherited_sources AS (
    SELECT
        ps.user_id,
        p.id AS priority_id,
        (nlevel (p.path) - nlevel (parent.path)) AS distance,
        0 AS source_type,
        CASE WHEN ((nlevel (p.path) > nlevel (parent.path))
            AND (subpath (p.path, nlevel (parent.path)) <> ''::ltree)) THEN
            (ps.path || subpath (p.path, nlevel (parent.path)))
        ELSE
            ps.path
        END AS path,
        ps.pomodoro,
        ps.color
    FROM ((priority_settings ps
            JOIN priority parent ON (ps.priority_id = parent.id))
        JOIN priority p ON (p.path <@ parent.path))
    WHERE ((ps.path IS NOT NULL)
        OR (ps.pomodoro IS NOT NULL)
        OR (ps.color IS NOT NULL))
UNION ALL
SELECT
    pu.user_id,
    p.id AS priority_id,
    (nlevel (p.path) - nlevel (parent.path)) AS distance,
    1 AS source_type,
    NULL::ltree AS path,
    NULL::integer AS pomodoro,
    parent.color
FROM (((priority_user pu
            JOIN priority root ON (pu.priority_id = root.id))
        JOIN priority p ON (p.path <@ root.path))
    JOIN priority parent ON (p.path <@ parent.path))
WHERE (parent.color IS NOT NULL))
SELECT DISTINCT ON (user_id, priority_id)
    user_id,
    priority_id,
    path,
    pomodoro,
    color
FROM
    inherited_sources
ORDER BY
    user_id,
    priority_id,
    distance,
    source_type;

CREATE OR REPLACE VIEW "public"."priority_tags" AS
SELECT
    a.priority_id,
    at.tag_id,
    count(*) AS count,
    max(COALESCE(at.archived_at, at.updated_at)) AS updated_at
FROM (activity_tag at
    JOIN activity a ON (at.activity_id = a.id))
WHERE ((at.archived_at IS NULL)
    AND (a.archived_at IS NULL))
GROUP BY
    a.priority_id,
    at.tag_id;

CREATE OR REPLACE FUNCTION public.redeem_invitation_code (invitation_code text, user_id uuid)
    RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
DECLARE
    _remaining numeric;
BEGIN
    -- Authorization: Only allow users to redeem codes for themselves
    IF auth.uid () != user_id THEN
        RAISE EXCEPTION 'Unauthorized: Cannot redeem invitation for other users';
    END IF;
    -- Atomically decrement the invitation code's remaining count
    -- Returns NULL if code doesn't exist or has no remaining uses
    UPDATE
        public.invitation
    SET
        remaining = remaining - 1
    WHERE
        code = invitation_code
        AND remaining > 0
    RETURNING
        remaining INTO _remaining;
    -- Check if update was successful
    IF _remaining IS NULL THEN
        -- Either code doesn't exist or has no remaining uses
        RETURN jsonb_build_object('success', FALSE, 'error', 'invalid_or_exhausted');
    END IF;
    RETURN jsonb_build_object('success', TRUE, 'remaining', _remaining);
END;
$function$;

CREATE OR REPLACE FUNCTION public.server_timestamp ()
    RETURNS timestamp with time zone
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN now();
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_priority_twist_owner_id ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
BEGIN
    NEW.owner_id := auth.uid ();
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_user_status (user_id uuid, status text)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
BEGIN
    -- Authorization: Only allow users to update their own status
    IF auth.uid () != user_id THEN
        RAISE EXCEPTION 'Unauthorized: Cannot update status for other users';
    END IF;
    -- Atomically update the user's app_metadata with status
    -- This avoids race conditions by doing the read and write in one operation
    UPDATE
        auth.users
    SET
        raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('status', status)
    WHERE
        id = user_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_priority_contact_on_delete ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_contact_id uuid;
BEGIN
    -- Get the contact_id for this user
    SELECT
        id INTO v_contact_id
    FROM
        public.contact
    WHERE
        user_id = OLD.user_id;
    -- Delete the corresponding priority_contact if it exists
    IF v_contact_id IS NOT NULL THEN
        DELETE FROM public.priority_contact
        WHERE priority_id = OLD.priority_id
            AND contact_id = v_contact_id;
    END IF;
    RETURN OLD;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_priority_contact_on_insert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_contact_id uuid;
BEGIN
    -- Get the contact_id for this user
    SELECT
        id INTO v_contact_id
    FROM
        public.contact
    WHERE
        user_id = NEW.user_id;
    -- Only create priority_contact if the user has a contact record
    IF v_contact_id IS NOT NULL THEN
        INSERT INTO public.priority_contact (priority_id, contact_id, created_at, archived_at)
            VALUES (NEW.priority_id, v_contact_id, NEW.created_at, NEW.archived_at)
        ON CONFLICT (priority_id, contact_id)
            DO NOTHING;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_priority_contact_on_update ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_contact_id uuid;
BEGIN
    -- Only proceed if archived_at changed
    IF OLD.archived_at IS DISTINCT FROM NEW.archived_at THEN
        -- Get the contact_id for this user
        SELECT
            id INTO v_contact_id
        FROM
            public.contact
        WHERE
            user_id = NEW.user_id;
        -- Update the corresponding priority_contact if it exists
        IF v_contact_id IS NOT NULL THEN
            UPDATE
                public.priority_contact
            SET
                archived_at = NEW.archived_at
            WHERE
                priority_id = NEW.priority_id
                AND contact_id = v_contact_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_user_contact_trigger ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
DECLARE
    _user_name text;
    _contact_id uuid;
BEGIN
    -- Extract name from user metadata
    _user_name := COALESCE(NEW.raw_app_meta_data ->> 'full_name', NEW.raw_app_meta_data ->> 'name', NEW.email);
    -- Upsert contact and get the contact ID
    _contact_id := public.upsert_user_contact (NEW.id, NEW.email, _user_name, NEW.raw_app_meta_data ->> 'avatar_url');
    -- Update NEW.raw_app_meta_data directly (no UPDATE needed, prevents recursion)
    NEW.raw_app_meta_data := COALESCE(NEW.raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('contact_id', _contact_id);
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.tstzrange_to_daterange (p_range tstzrange, p_timezone text DEFAULT 'UTC' ::text)
    RETURNS daterange
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
BEGIN
    RETURN daterange((lower(p_range) AT TIME ZONE p_timezone)::date, (upper(p_range) AT TIME ZONE p_timezone)::date,
    -- preserve inclusive/exclusive bounds of original p_range
    CASE WHEN lower_inc(p_range)
        AND upper_inc(p_range) THEN
        '[]'
    WHEN lower_inc(p_range) THEN
        '[)'
    WHEN upper_inc(p_range) THEN
        '(]'
    ELSE
        '()'
    END)::daterange;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_activity_on_note_change ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
BEGIN
    -- On addition of a non-draft, non-archived note:
    -- Keep the activity read for the note creator if no one else has added notes
    -- since they last marked it read
    IF NEW.draft = FALSE AND NEW.archived_at IS NULL THEN
        -- Upsert activity_read for the note creator
        -- Only update if no other users have created notes since their last read_at
        -- Only track read status for actual users (not twists or contacts)
        INSERT INTO activity_read (user_id, activity_id, read_at)
        SELECT
            NEW.created_by,
            NEW.activity_id,
            NEW.created_at
        WHERE
            -- Only insert if created_by is an actual user from auth.users
            EXISTS (
                SELECT
                    1
                FROM
                    auth.users
                WHERE
                    id = NEW.created_by)
            AND NOT EXISTS (
                -- Check if any other user created notes since this user's last read_at
                SELECT
                    1
                FROM
                    note n
                LEFT JOIN activity_read ar ON ar.user_id = NEW.created_by
                    AND ar.activity_id = NEW.activity_id
            WHERE
                n.activity_id = NEW.activity_id
                AND n.created_by != NEW.created_by
                AND n.draft = FALSE
                AND n.archived_at IS NULL
                AND n.created_at > COALESCE(ar.read_at, '-infinity'::timestamp with time zone))
        ON CONFLICT (user_id,
            activity_id)
            DO UPDATE SET
                read_at = NEW.created_at,
                updated_at = now()
            WHERE
                -- Only update if still no other users have notes since current read_at
                NOT EXISTS (
                    SELECT
                        1
                    FROM
                        note n
                    WHERE
                        n.activity_id = NEW.activity_id
                        AND n.created_by != NEW.created_by
                        AND n.draft = FALSE
                        AND n.archived_at IS NULL
                        AND n.created_at > activity_read.read_at);
        -- Update activity's last_note_created_at when notes are inserted/deleted
        -- Note: note.updated_at changes do NOT trigger this
        UPDATE
            activity
        SET
            last_note_created_at = (
                SELECT
                    MAX(created_at)
                FROM
                    note
                WHERE
                    activity_id = COALESCE(NEW.activity_id, OLD.activity_id)
                    AND draft = FALSE
                    AND archived_at IS NULL)
        WHERE
            id = COALESCE(NEW.activity_id, OLD.activity_id);
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_activity_tags (p_activity_id uuid, p_actor_id uuid, p_client_id integer, p_tag_updates jsonb)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    tag_record record;
    tag_id_int integer;
    is_adding boolean;
    current_tag_type tag_type;
BEGIN
    -- Validate that activity_id is provided
    IF p_activity_id IS NULL THEN
        RAISE EXCEPTION 'p_activity_id must be provided';
    END IF;
    -- Iterate through the tag updates JSON object
    FOR tag_record IN
    SELECT
        key,
        value
    FROM
        jsonb_each(p_tag_updates)
        LOOP
            -- Convert key to integer and value to boolean
            tag_id_int := tag_record.key::integer;
            is_adding := tag_record.value::boolean;
            -- Get tag type using the get_tag_type function
            current_tag_type := get_tag_type (tag_id_int);
            IF is_adding THEN
                -- Adding a tag - use upsert to create or reactivate
                INSERT INTO activity_tag (actor_id, activity_id, occurrence, tag_id, updated_at, archived_at, updated_by)
                    VALUES (p_actor_id, p_activity_id, NULL, tag_id_int, now(), NULL, p_client_id)
                ON CONFLICT (actor_id, activity_id, occurrence, tag_id)
                    DO UPDATE SET
                        archived_at = NULL,
                        updated_at = now(),
                        updated_by = p_client_id;
            ELSE
                -- Removing a tag - use update to soft delete existing records
                IF current_tag_type = 'toggle' THEN
                    -- For toggle tags, remove all users' tags
                    UPDATE
                        activity_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        activity_id = p_activity_id
                        AND tag_id = tag_id_int
                        AND archived_at IS NULL;
                ELSE
                    -- For count/compute tags, only remove current actor's tag
                    UPDATE
                        activity_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        activity_id = p_activity_id
                        AND tag_id = tag_id_int
                        AND actor_id = p_actor_id
                        AND archived_at IS NULL;
                END IF;
            END IF;
        END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_author_and_created_by ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    -- Don't allow users to impersonate others
    NEW.author_id = COALESCE(user_contact_id (), NEW.author_id);
    NEW.created_by = COALESCE(auth.uid (), NEW.created_by);
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_created_by ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    NEW.created_by = COALESCE(auth.uid (), NEW.created_by);
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_note_tags (p_note_id uuid, p_actor_id uuid, p_client_id integer, p_tag_updates jsonb)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    tag_record record;
    tag_id_int integer;
    is_adding boolean;
    current_tag_type tag_type;
BEGIN
    -- Validate that note_id is provided
    IF p_note_id IS NULL THEN
        RAISE EXCEPTION 'p_note_id must be provided';
    END IF;
    -- Iterate through the tag updates JSON object
    FOR tag_record IN
    SELECT
        key,
        value
    FROM
        jsonb_each(p_tag_updates)
        LOOP
            -- Convert key to integer and value to boolean
            tag_id_int := tag_record.key::integer;
            is_adding := tag_record.value::boolean;
            -- Get tag type using the get_tag_type function
            current_tag_type := get_tag_type (tag_id_int);
            IF is_adding THEN
                -- Adding a tag - use upsert to create or reactivate
                INSERT INTO note_tag (actor_id, note_id, tag_id, updated_at, archived_at, updated_by)
                    VALUES (p_actor_id, p_note_id, tag_id_int, now(), NULL, p_client_id)
                ON CONFLICT (actor_id, note_id, tag_id)
                    DO UPDATE SET
                        archived_at = NULL,
                        updated_at = now(),
                        updated_by = p_client_id;
            ELSE
                -- Removing a tag - use update to soft delete existing records
                IF current_tag_type = 'toggle' THEN
                    -- For toggle tags, remove all users' tags
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = tag_id_int
                        AND archived_at IS NULL;
                ELSE
                    -- For count/compute tags, only remove current actor's tag
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = tag_id_int
                        AND actor_id = p_actor_id
                        AND archived_at IS NULL;
                END IF;
            END IF;
        END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_updated_at ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.upsert_activity (p_id uuid, p_user_id uuid, p_updated_by integer, p_archived_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_priority_id uuid DEFAULT NULL::uuid, p_draft boolean DEFAULT NULL::boolean, p_private boolean DEFAULT NULL::boolean, p_at tstzrange DEFAULT NULL::tstzrange, p_on daterange DEFAULT NULL::dateRANGE, p_duration interval DEFAULT NULL::interval, p_done_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_title text DEFAULT NULL::text, p_preview text DEFAULT NULL::text, p_assignee_id uuid DEFAULT NULL::uuid, p_order double precision DEFAULT NULL::double precision, p_recurrence_rule text DEFAULT NULL::text, p_recurrence_exdates timestamp with time zone[] DEFAULT NULL::timestamp with time zone[], p_recurrence_dates timestamp with time zone[] DEFAULT NULL::timestamp with time zone[], p_series uuid DEFAULT NULL::uuid, p_occurrence_start timestamp with time zone DEFAULT NULL::timestamp with time zone)
    RETURNS uuid
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    _activity_id uuid;
    _occurrence_root_id uuid;
    _occurrence_original_start timestamptz;
BEGIN
    -- Convert series field to occurrence_root_id
    _occurrence_root_id := p_series;
    _occurrence_original_start := p_occurrence_start;
    -- Check if this is an update to an existing activity
    IF p_id IS NOT NULL THEN
        SELECT
            id INTO _activity_id
        FROM
            activity
        WHERE
            id = p_id;
    END IF;
    -- If updating a synthetic recurrence instance (generated ID), create a new exception record
    IF _activity_id IS NULL AND _occurrence_root_id IS NOT NULL AND _occurrence_original_start IS NOT NULL THEN
        -- This is a new exception for a recurring activity
        _activity_id := gen_random_uuid_v7 ();
        -- Insert new exception activity
        INSERT INTO activity (id, updated_by, archived_at, priority_id, draft, private, at, "on", duration, done_at, title, preview, assignee_id, "order", recurrence_rule, recurrence_exdates, recurrence_dates, occurrence_root_id, occurrence_original_start)
            VALUES (_activity_id, p_updated_by, p_archived_at, COALESCE(p_priority_id, (
                        SELECT
                            priority_id
                        FROM activity
                        WHERE
                            id = _occurrence_root_id)),
                COALESCE(p_draft, FALSE),
                COALESCE(p_private, FALSE),
                p_at,
                p_on,
                p_duration,
                p_done_at,
                p_title,
                p_preview,
                p_assignee_id,
                p_order,
                NULL, -- Exceptions don't have their own recurrence rules
                NULL,
                NULL,
                _occurrence_root_id,
                _occurrence_original_start);
        RETURN _activity_id;
    END IF;
    -- Standard upsert for regular activities or existing exception records
    INSERT INTO activity (id, updated_by, archived_at, priority_id, draft, private, at, "on", duration, done_at, title, preview, assignee_id, "order", recurrence_rule, recurrence_exdates, recurrence_dates, occurrence_root_id, occurrence_original_start)
        VALUES (COALESCE(p_id, gen_random_uuid_v7 ()), p_updated_by, p_archived_at, p_priority_id, COALESCE(p_draft, FALSE), COALESCE(p_private, FALSE), p_at, p_on, p_duration, p_done_at, p_title, p_preview, p_assignee_id, COALESCE(p_order, public.order_first ()), p_recurrence_rule, p_recurrence_exdates, p_recurrence_dates, _occurrence_root_id, _occurrence_original_start)
    ON CONFLICT (id)
        DO UPDATE SET
            updated_by = EXCLUDED.updated_by,
            updated_at = now(),
            archived_at = COALESCE(EXCLUDED.archived_at, activity.archived_at),
            priority_id = COALESCE(EXCLUDED.priority_id, activity.priority_id),
            draft = COALESCE(EXCLUDED.draft, activity.draft),
            private = COALESCE(EXCLUDED.private, activity.private),
            at = COALESCE(EXCLUDED.at, activity.at),
            "on" = COALESCE(EXCLUDED.on, activity.on),
            duration = COALESCE(EXCLUDED.duration, activity.duration),
            done_at = COALESCE(EXCLUDED.done_at, activity.done_at),
            title = COALESCE(EXCLUDED.title, activity.title),
            preview = COALESCE(EXCLUDED.preview, activity.preview),
            assignee_id = COALESCE(EXCLUDED.assignee_id, activity.assignee_id),
            "order" = COALESCE(EXCLUDED."order", activity."order"),
            recurrence_rule = COALESCE(EXCLUDED.recurrence_rule, activity.recurrence_rule),
            recurrence_exdates = COALESCE(EXCLUDED.recurrence_exdates, activity.recurrence_exdates),
            recurrence_dates = COALESCE(EXCLUDED.recurrence_dates, activity.recurrence_dates)
        RETURNING
            id INTO _activity_id;
    RETURN _activity_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.upsert_contacts (_contacts contact_upsert[])
    RETURNS void
    LANGUAGE plpgsql
    AS $function$
BEGIN
    INSERT INTO contact (user_id, email, name, avatar_url) (
        SELECT
            a.user_id,
            vals.email,
            min(vals.name),
            min(vals.avatar_url)
        FROM
            unnest(_contacts) AS vals (calendar_id,
                email,
                name,
                avatar_url)
            JOIN calendar c ON vals.calendar_id = c.id
            JOIN account a ON c.account_id = a.id
        GROUP BY
            a.user_id,
            vals.email)
ON CONFLICT (user_id,
    email)
    DO UPDATE SET
        name = COALESCE(contact.name, EXCLUDED.name),
        avatar_url = COALESCE(contact.avatar_url, EXCLUDED.avatar_url);
END;
$function$;

CREATE OR REPLACE FUNCTION public.upsert_user_contact (user_id uuid, user_email text, user_name text, avatar_url text)
    RETURNS uuid
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
DECLARE
    _contact_id uuid;
BEGIN
    -- Upsert contact record for the user
    INSERT INTO public.contact (email, name, avatar_url, user_id)
        VALUES (user_email, user_name, avatar_url, user_id)
    ON CONFLICT (email)
        DO UPDATE SET
            name = COALESCE(EXCLUDED.name, contact.name),
            avatar_url = COALESCE(EXCLUDED.avatar_url, contact.avatar_url),
            user_id = COALESCE(EXCLUDED.user_id, contact.user_id),
            updated_at = now()
        RETURNING
            id INTO _contact_id;
    RETURN _contact_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.user_contact_id ()
    RETURNS uuid
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN (auth.jwt () -> 'app_metadata' ->> 'contact_id')::uuid;
END;
$function$;

CREATE OR REPLACE FUNCTION public.user_has_priority_access (user_id uuid, target_priority_id uuid)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                priority_user pu
                JOIN priority pp ON pu.priority_id = pp.id
                JOIN priority p ON p.path <@ pp.path
            WHERE
                pu.user_id = user_has_priority_access.user_id
                AND pu.archived_at IS NULL
                AND p.id = user_has_priority_access.target_priority_id);
$function$;

CREATE OR REPLACE FUNCTION public.user_has_priority_access (user_id uuid, target_priority_path ltree)
    RETURNS boolean
    LANGUAGE plpgsql
    STABLE
    SECURITY DEFINER
    AS $function$
BEGIN
    PERFORM
        set_config('row_security', 'off', TRUE);
    RETURN EXISTS (
        SELECT
            1
        FROM
            priority_user pu
            JOIN priority pp ON pu.priority_id = pp.id
            JOIN priority p ON p.path <@ pp.path
        WHERE
            pu.user_id = user_has_priority_access.user_id
            AND pu.archived_at IS NULL
            AND p.path = user_has_priority_access.target_priority_path);
END;
$function$;

CREATE OR REPLACE FUNCTION public.user_mentioned_in_activity (user_id uuid, activity_id uuid)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.note
            WHERE
                note.activity_id = user_mentioned_in_activity.activity_id
                AND note.archived_at IS NULL
                AND user_mentioned_in_activity.user_id = ANY (note.mentions));
$function$;

CREATE OR REPLACE VIEW "public"."user_priority_expanded" AS
SELECT
    pu.user_id,
    c.child_id AS priority_id,
    min(pu.created_at) AS joined_at,
    CASE WHEN bool_or(pu.archived_at IS NULL) THEN
        NULL::timestamp with time zone
    ELSE
        LEAST (min(pu.archived_at), min(c.archived_at))
    END AS archived_at
FROM (priority_user pu
    JOIN priority_child c ON (pu.priority_id = c.priority_id))
GROUP BY
    pu.user_id,
    c.child_id;

CREATE OR REPLACE VIEW "public"."user_priority_unread" AS
SELECT
    upe.user_id,
    upe.priority_id,
    TRUE AS unread,
    max(GREATEST (COALESCE(ar.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone), CASE WHEN (a.created_by = upe.user_id) THEN
                COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)
            ELSE
                COALESCE(a.last_note_created_at, a.created_at)
            END)) AS updated_at
FROM ((user_priority_expanded upe
        JOIN activity a ON (((a.priority_id = upe.priority_id)
                    AND (a.archived_at IS NULL)
                    AND (((a.created_by = upe.user_id)
                            AND (a.last_note_created_at IS NOT NULL)
                            AND (a.last_note_created_at > upe.joined_at))
                        OR (((a.created_by IS NULL)
                                OR (a.created_by <> upe.user_id))
                            AND (COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at))))))
    LEFT JOIN activity_read ar ON (((ar.user_id = upe.user_id)
                AND (ar.activity_id = a.id))))
GROUP BY
    upe.user_id,
    upe.priority_id;

CREATE OR REPLACE FUNCTION public.user_timezone ()
    RETURNS text
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN COALESCE((auth.jwt () -> 'app_metadata' -> 'timezone')::text, 'America/New_York');
END;
$function$;

CREATE OR REPLACE VIEW "public"."user_twist" AS
SELECT
    upe.user_id,
    pt.id,
    pt.created_at,
    pt.updated_at,
    pt.archived_at,
    pt.priority_id,
    pt.twist_id,
    t.environment AS twist_environment,
    pt.owner_id,
    pt.name,
    pt.config
FROM ((priority_twist pt
        JOIN user_priority_expanded upe ON (upe.priority_id = pt.priority_id))
    JOIN twist t ON (pt.twist_id = t.id));

CREATE OR REPLACE FUNCTION public.week_from_date (d date)
    RETURNS daterange
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        CASE WHEN d IS NULL THEN
            NULL
        ELSE
            daterange(date_bin ('7 days', d, '2023-1-1'::date)::date, date_bin ('7 days', d, '2023-1-1'::date)::date + 7, '[)'::text)
        END
$function$;

CREATE OR REPLACE VIEW "public"."user_activity_unread" AS
SELECT
    upe.user_id,
    a.id AS activity_id,
    (ar.read_at IS NULL) AS unread,
    GREATEST (COALESCE(ar.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone), CASE WHEN (a.created_by = upe.user_id) THEN
            COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)
        ELSE
            COALESCE(a.last_note_created_at, a.created_at)
        END) AS updated_at
FROM ((user_priority_expanded upe
        JOIN activity a ON (((a.priority_id = upe.priority_id)
                    AND (a.archived_at IS NULL)
                    AND (((a.created_by = upe.user_id)
                            AND (a.last_note_created_at IS NOT NULL)
                            AND (a.last_note_created_at > upe.joined_at))
                        OR (((a.created_by IS NULL)
                                OR (a.created_by <> upe.user_id))
                            AND (COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at))))))
    LEFT JOIN activity_read ar ON (((ar.user_id = upe.user_id)
                AND (ar.activity_id = a.id)
                AND (ar.read_at >= CASE WHEN (a.created_by = upe.user_id) THEN
                        a.last_note_created_at
                    ELSE
                        COALESCE(a.last_note_created_at, a.created_at)
                    END))));

CREATE OR REPLACE VIEW "public"."user_note" AS
SELECT
    upe.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.archived_at,
    n.activity_id,
    n.draft,
    n.private,
    n.content,
    n.links,
    n.mentions
FROM ((note n
        JOIN activity a ON (a.id = n.activity_id))
    JOIN user_priority_expanded upe ON (upe.priority_id = a.priority_id));

CREATE OR REPLACE VIEW "public"."user_priority" AS
SELECT
    pu.user_id,
    p.id,
    p.created_at,
    GREATEST (settings.updated_at, pu.updated_at, p.updated_at, COALESCE(upu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    GREATEST (pu.archived_at, p.archived_at) AS archived_at,
    p.created_by,
    p.updated_by,
    (root.root
        AND (p.id = root.id)) AS root,
    p.title,
    CASE WHEN (inherited_settings.path IS NOT NULL) THEN
        inherited_settings.path
    WHEN (user_root.path @> p.path) THEN
        p.path
    ELSE
        (user_root.path || p.path)
    END AS path,
    settings.top_order,
    inherited_settings.pomodoro,
    inherited_settings.color,
    COALESCE(upu.unread, FALSE) AS unread
FROM ((((((priority_user pu
                        JOIN priority root ON (pu.priority_id = root.id))
                    JOIN priority user_root ON (((pu.user_id = user_root.created_by)
                                AND user_root.root)))
                JOIN priority p ON (root.path @> p.path))
            LEFT JOIN priority_settings settings ON (((settings.user_id = pu.user_id)
                        AND (p.id = settings.priority_id))))
        LEFT JOIN priority_settings_inherited inherited_settings ON (((inherited_settings.user_id = pu.user_id)
                    AND (p.id = inherited_settings.priority_id))))
    LEFT JOIN user_priority_unread upu ON (((upu.user_id = pu.user_id)
                AND (upu.priority_id = p.id))))
WHERE (pu.archived_at IS NULL);

CREATE OR REPLACE VIEW "public"."user_activity" AS
SELECT
    upe.user_id,
    a.id,
    a.created_at,
    COALESCE(GREATEST (a.updated_at, a.last_note_created_at), a.updated_at) AS updated_at,
    a.author_id,
    a.assignee_id,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at) AS archived_at,
    a.priority_id,
    a.priority_path,
    a.type,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.at,
    a."on",
    a.duration,
    a.done_at,
    a.recurrence_rule,
    a.recurrence_exdates,
    a.recurrence_dates,
    a.meta,
    a.source,
    a.created_by_twist_id,
    a.last_note_created_at,
    a.mentions,
    CASE WHEN (a.done_at IS NOT NULL) THEN
        tstzrange(a.done_at, a.done_at, '[]'::text)
    WHEN (a.at IS NOT NULL) THEN
        a.at
    WHEN (a."on" IS NOT NULL) THEN
        NULL::tstzrange
    ELSE
        tstzrange(GREATEST (a.created_at, COALESCE(a.last_note_created_at, a.created_at)), GREATEST (a.created_at, COALESCE(a.last_note_created_at, a.created_at)), '[]'::text)
    END AS range_at,
    CASE WHEN (a.done_at IS NOT NULL) THEN
        NULL::daterange
    WHEN (a.at IS NOT NULL) THEN
        NULL::daterange
    WHEN (a."on" IS NOT NULL) THEN
        a."on"
    ELSE
        NULL::daterange
    END AS range_on,
    COALESCE(uau.unread, FALSE) AS unread
FROM ((activity_x a
        JOIN user_priority_expanded upe ON (a.priority_id = upe.priority_id))
    LEFT JOIN user_activity_unread uau ON (((uau.user_id = upe.user_id)
                AND (uau.activity_id = a.id))));

CREATE OR REPLACE VIEW "public"."user_activity_exception" AS
SELECT
    ua.user_id,
    ua.id,
    COALESCE(ae.archived_at, ua.archived_at) AS archived_at,
    ae.occurrence,
    ae.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    ae.at,
    ae."on",
    ae.title,
    ae.note
FROM (activity_exception ae
    JOIN user_activity ua ON (ua.id = ae.activity_id));

CREATE OR REPLACE VIEW "public"."user_activity_tags" AS
SELECT
    ua.user_id,
    ua.id,
    ua.archived_at,
    at.occurrence,
    at.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    at.tags
FROM (activity_tags at
    JOIN user_activity ua ON (ua.id = at.activity_id));

CREATE OR REPLACE VIEW "public"."user_note_tags" AS
SELECT
    ua.user_id,
    n.id,
    nt.updated_at,
    ua.archived_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    nt.tags
FROM ((note_tags nt
        JOIN note n ON (n.id = nt.note_id))
    JOIN user_activity ua ON (ua.id = n.activity_id));

CREATE POLICY "Users can insert activities in their accessible priorities" ON "public"."activity" AS permissive
    FOR INSERT TO public
        WITH CHECK (((author_id = user_contact_id ()) AND user_has_priority_access (auth.uid (), priority_id)));

CREATE POLICY "Users can update activities in their accessible priorities" ON "public"."activity" AS permissive
    FOR UPDATE TO public
        USING ((user_has_priority_access (auth.uid (), priority_id) AND ((draft = FALSE) OR (created_by = auth.uid ())) AND ((private = FALSE) OR (created_by = auth.uid ()) OR user_mentioned_in_activity (auth.uid (), id))))
        WITH CHECK ((user_has_priority_access (auth.uid (), priority_id) AND ((draft = FALSE) OR (created_by = auth.uid ())) AND ((private = FALSE) OR (created_by = auth.uid ()) OR user_mentioned_in_activity (auth.uid (), id))));

CREATE POLICY "Users can view activities in their accessible priorities" ON "public"."activity" AS permissive
    FOR SELECT TO public
        USING ((user_has_priority_access (auth.uid (), priority_id) AND ((draft = FALSE) OR (created_by = auth.uid ())) AND ((private = FALSE) OR (created_by = auth.uid ()) OR user_mentioned_in_activity (auth.uid (), id))));

CREATE POLICY "Users can insert activity exceptions for accessible activities" ON "public"."activity_exception" AS permissive
    FOR INSERT TO public
        WITH CHECK ((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = activity_exception.activity_id) AND user_has_priority_access (auth.uid (), activity.priority_id)))));

CREATE POLICY "Users can update activity exceptions for their own activities" ON "public"."activity_exception" AS permissive
    FOR UPDATE TO public
        USING ((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = activity_exception.activity_id) AND user_has_priority_access (auth.uid (), activity.priority_id)))))
        WITH CHECK ((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = activity_exception.activity_id) AND user_has_priority_access (auth.uid (), activity.priority_id)))));

CREATE POLICY "Users can view activity exceptions for accessible activities" ON "public"."activity_exception" AS permissive
    FOR SELECT TO public
        USING ((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = activity_exception.activity_id) AND user_has_priority_access (auth.uid (), activity.priority_id)))));

CREATE POLICY "Users can delete their own activity read records" ON "public"."activity_read" AS permissive
    FOR DELETE TO public
        USING ((user_id = auth.uid ()));

CREATE POLICY "Users can insert their own activity read records" ON "public"."activity_read" AS permissive
    FOR INSERT TO public
        WITH CHECK ((user_id = auth.uid ()));

CREATE POLICY "Users can update their own activity read records" ON "public"."activity_read" AS permissive
    FOR UPDATE TO public
        USING ((user_id = auth.uid ()));

CREATE POLICY "Users can view their own activity read records" ON "public"."activity_read" AS permissive
    FOR SELECT TO public
        USING ((user_id = auth.uid ()));

CREATE POLICY "Users can insert activity_tag for activities in their accessibl" ON "public"."activity_tag" AS permissive
    FOR INSERT TO public
        WITH CHECK (((actor_id = user_contact_id ()) AND (EXISTS (
            SELECT
                1
            FROM
                activity a
            WHERE ((a.id = activity_tag.activity_id) AND user_has_priority_access (auth.uid (), a.priority_id))))));

CREATE POLICY "Users can update activity_tag for activities in their accessibl" ON "public"."activity_tag" AS permissive
    FOR UPDATE TO public
        USING (((actor_id = user_contact_id ()) OR (EXISTS (
            SELECT
                1
            FROM
                activity a
            WHERE ((a.id = activity_tag.activity_id) AND user_has_priority_access (auth.uid (), a.priority_id) AND (get_tag_type (activity_tag.tag_id) = 'toggle'::tag_type))))))
        WITH CHECK ((actor_id = user_contact_id ()));

CREATE POLICY "Users can view activity_tag in their accessible priorities" ON "public"."activity_tag" AS permissive
    FOR SELECT TO public
        USING (((actor_id = user_contact_id ()) OR (EXISTS (
            SELECT
                1
            FROM
                activity a
            WHERE ((a.id = activity_tag.activity_id) AND user_has_priority_access (auth.uid (), a.priority_id))))));

CREATE POLICY "Users can view contacts linked to their priorities" ON "public"."contact" AS permissive
    FOR SELECT TO authenticated
        USING ((EXISTS (
            SELECT
                1
            FROM
                priority_contact pc
            WHERE ((pc.contact_id = contact.id) AND (pc.archived_at IS NULL) AND user_has_priority_access (auth.uid (), pc.priority_id)))));

CREATE POLICY "Everyone can view all domains" ON "public"."domain" AS permissive
    FOR SELECT TO authenticated
        USING (TRUE);

CREATE POLICY "Users can insert notes for accessible activities" ON "public"."note" AS permissive
    FOR INSERT TO public
        WITH CHECK (((author_id = user_contact_id ()) AND (EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = note.activity_id) AND user_has_priority_access (auth.uid (), activity.priority_id))))));

CREATE POLICY "Users can update notes for accessible activities" ON "public"."note" AS permissive
    FOR UPDATE TO public
        USING (((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = note.activity_id) AND user_has_priority_access (auth.uid (), activity.priority_id)))) AND ((draft = FALSE) OR (created_by = auth.uid ())) AND ((private = FALSE) OR (created_by = auth.uid ()) OR (auth.uid () = ANY (mentions)))))
        WITH CHECK (((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = note.activity_id) AND user_has_priority_access (auth.uid (), activity.priority_id)))) AND ((draft = FALSE) OR (created_by = auth.uid ())) AND ((private = FALSE) OR (created_by = auth.uid ()) OR (auth.uid () = ANY (mentions)))));

CREATE POLICY "Users can view notes for accessible activities" ON "public"."note" AS permissive
    FOR SELECT TO public
        USING (((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = note.activity_id) AND user_has_priority_access (auth.uid (), activity.priority_id)))) AND ((draft = FALSE) OR (created_by = auth.uid ())) AND ((private = FALSE) OR (created_by = auth.uid ()) OR (auth.uid () = ANY (mentions)))));

CREATE POLICY "Users can insert note_tag for notes in their accessible priorit" ON "public"."note_tag" AS permissive
    FOR INSERT TO public
        WITH CHECK (((actor_id = user_contact_id ()) AND (EXISTS (
            SELECT
                1
            FROM (note n
            JOIN activity a ON (a.id = n.activity_id))
        WHERE ((n.id = note_tag.note_id) AND user_has_priority_access (auth.uid (), a.priority_id))))));

CREATE POLICY "Users can update note_tag for notes in their accessible priorit" ON "public"."note_tag" AS permissive
    FOR UPDATE TO public
        USING (((actor_id = user_contact_id ()) OR (EXISTS (
            SELECT
                1
            FROM (note n
            JOIN activity a ON (a.id = n.activity_id))
        WHERE ((n.id = note_tag.note_id) AND user_has_priority_access (auth.uid (), a.priority_id) AND (get_tag_type (note_tag.tag_id) = 'toggle'::tag_type))))))
    WITH CHECK ((actor_id = user_contact_id ()));

CREATE POLICY "Users can view note_tag in their accessible priorities" ON "public"."note_tag" AS permissive
    FOR SELECT TO public
        USING (((actor_id = user_contact_id ()) OR (EXISTS (
            SELECT
                1
            FROM (note n
            JOIN activity a ON (a.id = n.activity_id))
        WHERE ((n.id = note_tag.note_id) AND user_has_priority_access (auth.uid (), a.priority_id))))));

CREATE POLICY "Everyone can view all organizations" ON "public"."organization" AS permissive
    FOR SELECT TO authenticated
        USING (TRUE);

CREATE POLICY "Users can access their priorities" ON "public"."priority" AS permissive
    FOR SELECT TO authenticated
        USING (can_access_priority (id));

CREATE POLICY "Users can create new priorities in their priorities" ON "public"."priority" AS permissive
    FOR INSERT TO authenticated
        WITH CHECK (can_access_priority (parent_path (path)));

CREATE POLICY "Users can update their priorities" ON "public"."priority" AS permissive
    FOR UPDATE TO authenticated
        USING ((can_access_priority (id) AND ((archived_at IS NULL) OR (root = FALSE))))
        WITH CHECK (((nlevel (path) = 1) OR can_access_priority (parent_path (path))));

CREATE POLICY "Users can access priority contacts for their priorities" ON "public"."priority_contact" AS permissive
    FOR ALL TO authenticated
        USING (user_has_priority_access (auth.uid (), priority_id));

CREATE POLICY "Users can read/write their priority settings" ON "public"."priority_settings" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = auth.uid ()));

CREATE POLICY "Users can delete twists in their accessible priorities" ON "public"."priority_twist" AS permissive
    FOR DELETE TO authenticated
        USING (can_access_priority (priority_id));

CREATE POLICY "Users can insert twists in their accessible priorities" ON "public"."priority_twist" AS permissive
    FOR INSERT TO authenticated
        WITH CHECK ((can_access_priority (priority_id) AND (owner_id = auth.uid ())));

CREATE POLICY "Users can update twists in their accessible priorities" ON "public"."priority_twist" AS permissive
    FOR UPDATE TO authenticated
        USING (can_access_priority (priority_id))
        WITH CHECK ((can_access_priority (priority_id) AND (owner_id = auth.uid ())));

CREATE POLICY "Users can view twists in their accessible priorities" ON "public"."priority_twist" AS permissive
    FOR SELECT TO authenticated
        USING (can_access_priority (priority_id));

CREATE POLICY "Users change sharing for their priorities" ON "public"."priority_user" AS permissive
    FOR ALL TO authenticated
        USING (can_access_priority (priority_id));

CREATE POLICY "Users can view twist publishers" ON "public"."publisher" AS permissive
    FOR SELECT TO authenticated
        USING (TRUE);

CREATE POLICY "Users can edit their own series" ON "public"."series" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = auth.uid ()));

CREATE POLICY "Users can edit their sessions" ON "public"."session" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = auth.uid ()));

CREATE POLICY "Users can create their own tokens" ON "public"."token" AS permissive
    FOR INSERT TO public
        WITH CHECK ((auth.uid () = user_id));

CREATE POLICY "Users can delete their own tokens" ON "public"."token" AS permissive
    FOR DELETE TO public
        USING ((auth.uid () = user_id));

CREATE POLICY "Users can update their own tokens" ON "public"."token" AS permissive
    FOR UPDATE TO public
        USING ((auth.uid () = user_id))
        WITH CHECK ((auth.uid () = user_id));

CREATE POLICY "Users can view their own tokens" ON "public"."token" AS permissive
    FOR SELECT TO public
        USING ((auth.uid () = user_id));

CREATE POLICY "Users can view accessible twists" ON "public"."twist" AS permissive
    FOR SELECT TO authenticated
        USING (((environment = 'public'::twist_environment) OR (EXISTS (
            SELECT
                1
            FROM
                twist_admin ta
            WHERE ((ta.id = twist.twist_admin_id) AND (((twist.environment = 'personal'::twist_environment) AND (ta.user_id = auth.uid ())) OR ((twist.environment <> 'personal'::twist_environment) AND (ta.user_id IS NULL) AND ((ta.priority_id IS NULL) OR can_access_priority (ta.priority_id)))))))));

CREATE POLICY "Users can view accessible twist admins" ON "public"."twist_admin" AS permissive
    FOR SELECT TO authenticated
        USING (((user_id = auth.uid ()) OR ((user_id IS NULL) AND ((priority_id IS NULL) OR can_access_priority (priority_id)))));

CREATE POLICY "Users can read/write their settings" ON "public"."user_settings" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = auth.uid ()));

CREATE POLICY "user_subscription_select_own" ON "public"."user_subscription" AS permissive
    FOR SELECT TO authenticated
        USING ((auth.uid () = user_id));

CREATE TRIGGER activity_change_api_call
    AFTER INSERT OR UPDATE ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION notify_internal_api_for_activity ();

CREATE TRIGGER set_activity_author_and_created_by
    BEFORE INSERT ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION update_author_and_created_by ();

CREATE TRIGGER set_activity_updated_at
    BEFORE UPDATE ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER notify_activity_read_change
    AFTER INSERT OR UPDATE ON public.activity_read
    FOR EACH ROW
    EXECUTE FUNCTION notify_internal_api_for_activity_read ();

CREATE TRIGGER set_activity_read_updated_at
    BEFORE UPDATE ON public.activity_read
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_activity_tag_updated_at
    BEFORE UPDATE ON public.activity_tag
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER on_contact_created
    AFTER INSERT ON public.contact
    FOR EACH ROW
    EXECUTE FUNCTION insert_email_domain ();

CREATE TRIGGER set_contact_updated_at
    BEFORE UPDATE ON public.contact
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_cost_updated_at
    BEFORE UPDATE ON public.cost
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER note_change_api_call
    AFTER INSERT OR UPDATE ON public.note
    FOR EACH ROW
    EXECUTE FUNCTION notify_internal_api_for_note ();

CREATE TRIGGER set_note_author_and_created_by
    BEFORE INSERT ON public.note
    FOR EACH ROW
    EXECUTE FUNCTION update_author_and_created_by ();

CREATE TRIGGER set_note_updated_at
    BEFORE UPDATE ON public.note
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER update_activity_last_note_created_at_on_status_change
    AFTER UPDATE OF draft,
    archived_at ON public.note
    FOR EACH ROW
    WHEN (((old.draft IS DISTINCT FROM new.draft) OR (old.archived_at IS DISTINCT FROM new.archived_at)))
    EXECUTE FUNCTION update_activity_on_note_change ();

CREATE TRIGGER update_activity_last_note_created_at_trigger
    AFTER INSERT OR DELETE ON public.note
    FOR EACH ROW
    EXECUTE FUNCTION update_activity_on_note_change ();

CREATE TRIGGER set_note_tag_updated_at
    BEFORE UPDATE ON public.note_tag
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER handle_priority_changes
    AFTER INSERT OR UPDATE ON public.priority
    FOR EACH ROW
    EXECUTE FUNCTION notify_internal_api_for_priority ();

CREATE TRIGGER prevent_priority_root_change_trigger
    BEFORE UPDATE ON public.priority
    FOR EACH ROW
    EXECUTE FUNCTION prevent_priority_root_change ();

CREATE TRIGGER priority_insert_trigger
    AFTER INSERT ON public.priority
    FOR EACH ROW
    EXECUTE FUNCTION insert_priority_user ();

CREATE TRIGGER set_priority_created_by
    BEFORE INSERT ON public.priority
    FOR EACH ROW
    EXECUTE FUNCTION update_created_by ();

CREATE TRIGGER set_priority_updated_at
    BEFORE UPDATE ON public.priority
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_priority_user_updated_at
    BEFORE UPDATE ON public.priority_settings
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER notify_priority_twist_update
    AFTER INSERT OR UPDATE ON public.priority_twist
    FOR EACH ROW
    EXECUTE FUNCTION notify_internal_api_for_priority_twist ();

CREATE TRIGGER prevent_priority_twist_immutable_changes
    BEFORE UPDATE ON public.priority_twist
    FOR EACH ROW
    EXECUTE FUNCTION prevent_priority_twist_immutable_changes ();

CREATE TRIGGER set_priority_twist_owner_id
    BEFORE INSERT ON public.priority_twist
    FOR EACH ROW
    EXECUTE FUNCTION set_priority_twist_owner_id ();

CREATE TRIGGER set_twist_updated_at
    BEFORE UPDATE ON public.priority_twist
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_priority_user_updated_at
    BEFORE UPDATE ON public.priority_user
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER sync_priority_contact_delete
    AFTER DELETE ON public.priority_user
    FOR EACH ROW
    EXECUTE FUNCTION sync_priority_contact_on_delete ();

CREATE TRIGGER sync_priority_contact_insert
    AFTER INSERT ON public.priority_user
    FOR EACH ROW
    EXECUTE FUNCTION sync_priority_contact_on_insert ();

CREATE TRIGGER sync_priority_contact_update
    AFTER UPDATE OF archived_at ON public.priority_user
    FOR EACH ROW
    EXECUTE FUNCTION sync_priority_contact_on_update ();

CREATE TRIGGER set_publisher_updated_at
    BEFORE UPDATE ON public.publisher
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_series_updated_at
    BEFORE UPDATE ON public.series
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER handle_session_changes
    AFTER INSERT OR UPDATE ON public.session
    FOR EACH ROW
    EXECUTE FUNCTION notify_internal_api_for_session ();

CREATE TRIGGER set_session_updated_at
    BEFORE UPDATE ON public.session
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_token_updated_at
    BEFORE UPDATE ON public.token
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_twist_updated_at
    BEFORE UPDATE ON public.twist
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_twist_admin_updated_at
    BEFORE UPDATE ON public.twist_admin
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_usage_updated_at
    BEFORE UPDATE ON public.usage
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER upsert_user_priority
    INSTEAD OF INSERT OR UPDATE ON public.user_priority
    FOR EACH ROW
    EXECUTE FUNCTION handle_user_priority_upsert ();

CREATE TRIGGER set_user_settings_updated_at
    BEFORE UPDATE ON public.user_settings
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_user_subscription_updated_at
    BEFORE UPDATE ON public.user_subscription
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE OR REPLACE FUNCTION public.actor (user_activity)
    RETURNS SETOF actor
    LANGUAGE sql
    STABLE ROWS 1
    AS $function$
    SELECT
        actor.*
    FROM
        actor
    WHERE
        actor.id = $1.author_id
$function$;

CREATE TRIGGER on_user_created_sync_contact
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_user_contact_trigger ();

CREATE TRIGGER on_user_updated_sync_contact
    AFTER UPDATE ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_user_contact_trigger ();

ALTER VIEW "public"."user_note" SET (security_invoker = TRUE);

ALTER VIEW "public"."note_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_note_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_twist" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_exception" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_expanded" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_settings_inherited" SET (security_invoker = TRUE);

ALTER VIEW "public"."actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child_twist" SET (security_invoker = TRUE);

