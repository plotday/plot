CREATE TABLE "public"."note" (
    "id" uuid PRIMARY KEY DEFAULT uuid_generate_v4 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "modified_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "context_id" uuid REFERENCES context ON DELETE CASCADE,
    "topic_id" uuid NOT NULL,
    "body" text NOT NULL,
    "order" double precision NOT NULL,
    "root" boolean NOT NULL DEFAULT TRUE,
    "private" boolean NOT NULL DEFAULT FALSE
);

ALTER TABLE "public"."note" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_note_modified_at
    BEFORE UPDATE ON "public"."note"
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

CREATE UNIQUE INDEX note_order_root ON "public"."note" (context_id, "order")
WHERE
    root = TRUE;

CREATE UNIQUE INDEX note_topic_root ON public.note (context_id, topic_id)
WHERE
    root = TRUE;

CREATE UNIQUE INDEX note_order_topic ON "public"."note" (context_id, topic_id, "order")
WHERE
    root = FALSE;

CREATE OR REPLACE FUNCTION update_topic_root (note_id uuid)
    RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    _root_order text;
    _context_id uuid;
    _topic_id uuid;
BEGIN
    -- Start a transaction block
    BEGIN
        -- Find the context_id and topic_id for the given ID
        SELECT
            context_id,
            topic_id INTO _context_id,
            _topic_id
        FROM
            "public"."note"
        WHERE
            id = note_id;
        -- Find the previous root and capture the order value
        SELECT
            "order" INTO _root_order
        FROM
            "public"."note"
        WHERE (context_id IS NOT DISTINCT FROM _context_id)
            AND topic_id = _topic_id
            AND root = TRUE
        FOR UPDATE;
        -- Update previous root record to set root = false and order = '!'
        UPDATE
            "public"."note"
        SET
            root = FALSE,
            "order" = '!'
        WHERE (context_id IS NOT DISTINCT FROM _context_id)
            AND topic_id = _topic_id
            AND root = TRUE;
        -- Update the row for the given id to set root = true and order previous order
        UPDATE
            "public"."note"
        SET
            root = TRUE,
            "order" = _root_order
        WHERE
            id = note_id;
    EXCEPTION
        WHEN OTHERS THEN
            -- Rollback the transaction if any exception occurs
            RAISE;
    END;
END;

$$;

