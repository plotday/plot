-- A role groups a user's focuses (priorities) and provides a colour and
-- notification template that focuses follow (see 95-triggers/30-role-propagation.sql).
-- One row per role per user. Roles are a flat, single-level grouping — there is
-- no nesting and no "all threads in a role" view.
CREATE TABLE "public"."role" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    -- Per-user owner. Defaulted from created_by by default_role_user_id below.
    "user_id" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    "archived_at" timestamp with time zone,
    "name" text NOT NULL,
    -- Theme colour index 0–7 (see kThemeColors in the Flutter app).
    "color" integer NOT NULL DEFAULT 0,
    -- Sidebar order; defaults to creation order (epoch millis) on insert.
    "order" double precision,
    -- Notification template the role's focuses follow (NULL = app default).
    "early_notifications_enabled" boolean,
    "notify_window" jsonb,
    "see_within" jsonb,
    -- Send-window template the role's focuses follow (list of AttentionWindow
    -- {days,start,end}). NULL/empty = send anytime. Messages drafted outside
    -- a window are auto-scheduled to the next opening (client-side).
    "send_window" jsonb,
    "seq" xid8 NOT NULL DEFAULT pg_current_xact_id()
);

CREATE INDEX idx_role_user_id ON "public"."role" ("user_id");
CREATE INDEX idx_role_seq ON "public"."role" ("seq");

CREATE TRIGGER set_role_updated_at
    BEFORE INSERT OR UPDATE ON "public"."role"
    FOR EACH ROW
    EXECUTE FUNCTION update_seq_and_updated_at ();

CREATE TRIGGER set_role_created_at
    BEFORE INSERT ON "public"."role"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

CREATE TRIGGER set_role_created_by
    BEFORE INSERT ON "public"."role"
    FOR EACH ROW
    EXECUTE FUNCTION update_created_by ();

-- Default role.user_id to the creator when the caller doesn't set it
-- (mirrors default_priority_user_id).
CREATE OR REPLACE FUNCTION public.default_role_user_id ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.user_id IS NULL THEN
        NEW.user_id := NEW.created_by;
    END IF;
    -- Default sidebar order to creation time so new roles append.
    IF NEW."order" IS NULL THEN
        NEW."order" := extract(epoch FROM now()) * 1000;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER default_role_user_id
    BEFORE INSERT ON "public"."role"
    FOR EACH ROW
    EXECUTE FUNCTION public.default_role_user_id ();
