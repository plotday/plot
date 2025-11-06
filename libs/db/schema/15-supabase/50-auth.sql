CREATE SCHEMA IF NOT EXISTS "auth";

CREATE OR REPLACE FUNCTION auth.uid ()
    RETURNS uuid
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        coalesce(nullif (current_setting('request.jwt.claim.sub', TRUE), ''), (nullif (current_setting('request.jwt.claims', TRUE), '')::jsonb ->> 'sub'))::uuid
$function$;

CREATE TABLE IF NOT EXISTS "auth"."users" (
    "instance_id" uuid NULL,
    "id" uuid NOT NULL,
    "aud" character varying(255) NULL,
    "role" character varying(255) NULL,
    "email" character varying(255) NULL,
    "encrypted_password" character varying(255) NULL,
    "email_confirmed_at" timestamptz NULL,
    "invited_at" timestamptz NULL,
    "confirmation_token" character varying(255) NULL,
    "confirmation_sent_at" timestamptz NULL,
    "recovery_token" character varying(255) NULL,
    "recovery_sent_at" timestamptz NULL,
    "email_change_token_new" character varying(255) NULL,
    "email_change" character varying(255) NULL,
    "email_change_sent_at" timestamptz NULL,
    "last_sign_in_at" timestamptz NULL,
    "raw_app_meta_data" jsonb NULL,
    "raw_user_meta_data" jsonb NULL,
    "is_super_admin" boolean NULL,
    "created_at" timestamptz NULL,
    "updated_at" timestamptz NULL,
    "phone" text NULL DEFAULT NULL::character varying,
    "phone_confirmed_at" timestamptz NULL,
    "phone_change" text NULL DEFAULT '', "phone_change_token" character varying(255) NULL DEFAULT '',
    "phone_change_sent_at" timestamptz NULL,
    "confirmed_at" timestamptz NULL GENERATED ALWAYS AS (LEAST (email_confirmed_at, phone_confirmed_at)) STORED,
    "email_change_token_current" character varying(255) NULL DEFAULT '', "email_change_confirm_status" smallint NULL DEFAULT 0, "banned_until" timestamptz NULL, "reauthentication_token" character varying(255) NULL DEFAULT '',
    "reauthentication_sent_at" timestamptz NULL,
    "is_sso_user" boolean NOT NULL DEFAULT FALSE,
    "archived_at" timestamptz NULL,
    PRIMARY KEY ("id"),
    CONSTRAINT "users_email_change_confirm_status_check" CHECK ((email_change_confirm_status >= 0) AND (email_change_confirm_status <= 2))
);

