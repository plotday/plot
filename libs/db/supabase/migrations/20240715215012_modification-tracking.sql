ALTER TABLE "public"."account"
    ADD COLUMN "modified_at" timestamp with time zone NOT NULL DEFAULT now();

ALTER TABLE "public"."budget"
    ADD COLUMN "modified_at" timestamp with time zone NOT NULL DEFAULT now();

ALTER TABLE "public"."calendar"
    ADD COLUMN "modified_at" timestamp with time zone NOT NULL DEFAULT now();

ALTER TABLE "public"."context"
    ADD COLUMN "modified_at" timestamp with time zone NOT NULL DEFAULT now();

ALTER TABLE "public"."event"
    ADD COLUMN "modified_at" timestamp with time zone NOT NULL DEFAULT now();

ALTER TABLE "public"."note"
    ADD COLUMN "modified_at" timestamp with time zone NOT NULL DEFAULT now();

ALTER TABLE "public"."series"
    ADD COLUMN "modified_at" timestamp with time zone NOT NULL DEFAULT now();

ALTER TABLE "public"."session"
    ADD COLUMN "modified_at" timestamp with time zone NOT NULL DEFAULT now();

CREATE OR REPLACE FUNCTION public.update_modified_at ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    NEW.modified_at = now();
    RETURN NEW;
END;
$function$;

CREATE TRIGGER set_account_modified_at
    BEFORE UPDATE ON public.account
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

CREATE TRIGGER set_budget_modified_at
    BEFORE UPDATE ON public.budget
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

CREATE TRIGGER set_calendar_modified_at
    BEFORE UPDATE ON public.calendar
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

CREATE TRIGGER set_context_modified_at
    BEFORE UPDATE ON public.context
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

CREATE TRIGGER set_event_modified_at
    BEFORE UPDATE ON public.event
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

CREATE TRIGGER set_note_modified_at
    BEFORE UPDATE ON public.note
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

CREATE TRIGGER set_series_modified_at
    BEFORE UPDATE ON public.series
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

CREATE TRIGGER set_session_modified_at
    BEFORE UPDATE ON public.session
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

