-- Create "custom_emoji" table
CREATE TABLE "public"."custom_emoji" (
  "id" text NOT NULL,
  "provider" text NOT NULL,
  "workspace_id" text NOT NULL,
  "name" text NOT NULL,
  "image_url" text NOT NULL,
  "alias_of" text NULL,
  "archived_at" timestamptz NULL,
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  "seq" xid8 NOT NULL DEFAULT pg_current_xact_id(),
  PRIMARY KEY ("id"),
  CONSTRAINT "custom_emoji_alias_of_fkey" FOREIGN KEY ("alias_of") REFERENCES "public"."custom_emoji" ("id") ON UPDATE NO ACTION ON DELETE SET NULL
);
-- Create index "idx_custom_emoji_provider_workspace" to table: "custom_emoji"
CREATE INDEX "idx_custom_emoji_provider_workspace" ON "public"."custom_emoji" ("provider", "workspace_id") WHERE (archived_at IS NULL);
-- Create index "idx_custom_emoji_seq" to table: "custom_emoji"
CREATE INDEX "idx_custom_emoji_seq" ON "public"."custom_emoji" ("seq");
-- Create trigger "set_custom_emoji_updated_at"
CREATE TRIGGER "set_custom_emoji_updated_at" BEFORE INSERT OR UPDATE ON "public"."custom_emoji" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq_and_updated_at"();
-- Create "note_reaction" table
CREATE TABLE "public"."note_reaction" (
  "id" bigint NOT NULL GENERATED ALWAYS AS IDENTITY,
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  "archived_at" timestamptz NULL,
  "actor_id" uuid NOT NULL,
  "note_id" uuid NOT NULL,
  "emoji" text NOT NULL,
  "updated_by" integer NOT NULL DEFAULT 0,
  "sync_depth" integer NULL,
  "seq" xid8 NOT NULL DEFAULT pg_current_xact_id(),
  PRIMARY KEY ("id"),
  CONSTRAINT "note_reaction_actor_id_note_id_emoji_key" UNIQUE NULLS NOT DISTINCT ("actor_id", "note_id", "emoji"),
  CONSTRAINT "note_reaction_note_id_fkey" FOREIGN KEY ("note_id") REFERENCES "public"."note" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create index "idx_note_reaction_note_id" to table: "note_reaction"
CREATE INDEX "idx_note_reaction_note_id" ON "public"."note_reaction" ("note_id", "emoji") WHERE (archived_at IS NULL);
-- Create index "idx_note_reaction_note_id_full" to table: "note_reaction"
CREATE INDEX "idx_note_reaction_note_id_full" ON "public"."note_reaction" ("note_id");
-- Create index "idx_note_reaction_seq" to table: "note_reaction"
CREATE INDEX "idx_note_reaction_seq" ON "public"."note_reaction" ("seq");
-- Create trigger "set_note_reaction_updated_at"
CREATE TRIGGER "set_note_reaction_updated_at" BEFORE INSERT OR UPDATE ON "public"."note_reaction" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq_and_updated_at"();
-- Create "thread_reaction" table
CREATE TABLE "public"."thread_reaction" (
  "id" bigint NOT NULL GENERATED ALWAYS AS IDENTITY,
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  "archived_at" timestamptz NULL,
  "actor_id" uuid NOT NULL,
  "thread_id" uuid NOT NULL,
  "occurrence" text NULL,
  "emoji" text NOT NULL,
  "updated_by" integer NOT NULL DEFAULT 0,
  "sync_depth" integer NULL,
  "seq" xid8 NOT NULL DEFAULT pg_current_xact_id(),
  PRIMARY KEY ("id"),
  CONSTRAINT "thread_reaction_actor_id_thread_id_occurrence_emoji_key" UNIQUE NULLS NOT DISTINCT ("actor_id", "thread_id", "occurrence", "emoji"),
  CONSTRAINT "thread_reaction_thread_id_fkey" FOREIGN KEY ("thread_id") REFERENCES "public"."thread" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create index "idx_thread_reaction_seq" to table: "thread_reaction"
CREATE INDEX "idx_thread_reaction_seq" ON "public"."thread_reaction" ("seq");
-- Create index "idx_thread_reaction_thread_id" to table: "thread_reaction"
CREATE INDEX "idx_thread_reaction_thread_id" ON "public"."thread_reaction" ("thread_id", "emoji") WHERE (archived_at IS NULL);
-- Create index "idx_thread_reaction_thread_id_all" to table: "thread_reaction"
CREATE INDEX "idx_thread_reaction_thread_id_all" ON "public"."thread_reaction" ("thread_id");
-- Set comment to column: "occurrence" on table: "thread_reaction"
COMMENT ON COLUMN "public"."thread_reaction"."occurrence" IS 'Original occurrence date/datetime in text format. For dates: YYYY-MM-DD, for datetimes: YYYY-MM-DDTHH:MM';
-- Create trigger "set_thread_reaction_updated_at"
CREATE TRIGGER "set_thread_reaction_updated_at" BEFORE INSERT OR UPDATE ON "public"."thread_reaction" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq_and_updated_at"();
-- Create "update_note_reactions" function
CREATE FUNCTION "user"."update_note_reactions" ("user_id" uuid, "p_note_id" uuid, "p_actor_id" uuid, "p_client_id" integer, "p_reaction_updates" jsonb) RETURNS void LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    rec record;
    v_emoji text;
    is_adding boolean;
    v_canonical_actor_id uuid;
    v_actor_sibling_ids uuid[];
    v_caller_sibling_ids uuid[];
    v_priority_id uuid;
BEGIN
    IF p_note_id IS NULL THEN
        RAISE EXCEPTION 'p_note_id must be provided';
    END IF;

    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        note n
        JOIN thread_priority tp ON tp.thread_id = n.thread_id
            AND tp.user_id = update_note_reactions.user_id
    WHERE
        n.id = p_note_id;
    IF v_priority_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM note WHERE id = p_note_id) THEN
            RAISE EXCEPTION 'Note not found';
        END IF;
        RAISE EXCEPTION 'User does not have access to this note';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    v_canonical_actor_id := "user".canonical_contact_id(p_actor_id);
    v_actor_sibling_ids := "user".sibling_contact_ids(p_actor_id);
    v_caller_sibling_ids := "user".user_contact_ids(user_id);
    IF NOT (v_actor_sibling_ids && v_caller_sibling_ids) THEN
        RAISE EXCEPTION 'Cannot modify reactions for other users';
    END IF;

    FOR rec IN
    SELECT
        key,
        value
    FROM
        jsonb_each(p_reaction_updates)
        LOOP
            v_emoji := rec.key;
            is_adding := rec.value::boolean;
            IF v_emoji IS NULL OR v_emoji = '' THEN
                RAISE EXCEPTION 'Reaction emoji must be a non-empty string';
            END IF;

            IF is_adding THEN
                -- Only insert when no live row exists for any of the
                -- actor's linked-contact siblings; always write canonical.
                IF NOT EXISTS (
                    SELECT 1 FROM note_reaction
                    WHERE note_id = p_note_id
                      AND emoji = v_emoji
                      AND actor_id = ANY(v_actor_sibling_ids)
                      AND archived_at IS NULL
                ) THEN
                    INSERT INTO note_reaction (actor_id, note_id, emoji, updated_at, archived_at, updated_by)
                        VALUES (v_canonical_actor_id, p_note_id, v_emoji, now(), NULL, p_client_id)
                    ON CONFLICT (actor_id, note_id, emoji)
                        DO UPDATE SET
                            archived_at = NULL,
                            updated_at = now(),
                            updated_by = p_client_id;
                END IF;
            ELSE
                -- Clearing one alias clears every linked-contact sibling's row.
                UPDATE note_reaction
                SET archived_at = now(),
                    updated_by = p_client_id
                WHERE note_id = p_note_id
                  AND emoji = v_emoji
                  AND actor_id = ANY(v_actor_sibling_ids)
                  AND archived_at IS NULL;
            END IF;
        END LOOP;
END;
$$;
-- Create "update_thread_reactions" function
CREATE FUNCTION "user"."update_thread_reactions" ("user_id" uuid, "p_thread_id" uuid, "p_actor_id" uuid, "p_client_id" integer, "p_reaction_updates" jsonb, "p_occurrence" text DEFAULT NULL::text) RETURNS void LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    rec record;
    v_emoji text;
    is_adding boolean;
    v_canonical_actor_id uuid;
    v_actor_sibling_ids uuid[];
    v_caller_sibling_ids uuid[];
    v_priority_id uuid;
BEGIN
    IF p_thread_id IS NULL THEN
        RAISE EXCEPTION 'p_thread_id must be provided';
    END IF;

    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        thread_priority tp
    WHERE
        tp.thread_id = p_thread_id
        AND tp.user_id = update_thread_reactions.user_id;
    IF v_priority_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM thread WHERE id = p_thread_id) THEN
            RAISE EXCEPTION 'Thread not found';
        END IF;
        RAISE EXCEPTION 'User does not have access to this thread';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    v_canonical_actor_id := "user".canonical_contact_id(p_actor_id);
    v_actor_sibling_ids := "user".sibling_contact_ids(p_actor_id);
    v_caller_sibling_ids := "user".user_contact_ids(user_id);
    IF NOT (v_actor_sibling_ids && v_caller_sibling_ids) THEN
        RAISE EXCEPTION 'Cannot modify reactions for other users';
    END IF;

    FOR rec IN
    SELECT
        key,
        value
    FROM
        jsonb_each(p_reaction_updates)
        LOOP
            v_emoji := rec.key;
            is_adding := rec.value::boolean;
            IF v_emoji IS NULL OR v_emoji = '' THEN
                RAISE EXCEPTION 'Reaction emoji must be a non-empty string';
            END IF;

            IF is_adding THEN
                IF NOT EXISTS (
                    SELECT 1 FROM thread_reaction
                    WHERE thread_id = p_thread_id
                      AND emoji = v_emoji
                      AND (occurrence IS NOT DISTINCT FROM p_occurrence)
                      AND actor_id = ANY(v_actor_sibling_ids)
                      AND archived_at IS NULL
                ) THEN
                    INSERT INTO thread_reaction (actor_id, thread_id, occurrence, emoji, updated_at, archived_at, updated_by)
                        VALUES (v_canonical_actor_id, p_thread_id, p_occurrence, v_emoji, now(), NULL, p_client_id)
                    ON CONFLICT (actor_id, thread_id, occurrence, emoji)
                        DO UPDATE SET
                            archived_at = NULL,
                            updated_at = now(),
                            updated_by = p_client_id;
                END IF;
            ELSE
                UPDATE thread_reaction
                SET archived_at = now(),
                    updated_by = p_client_id
                WHERE thread_id = p_thread_id
                  AND emoji = v_emoji
                  AND (occurrence IS NOT DISTINCT FROM p_occurrence)
                  AND actor_id = ANY(v_actor_sibling_ids)
                  AND archived_at IS NULL;
            END IF;
        END LOOP;
END;
$$;
-- Create "upsert_note_reaction" function
CREATE FUNCTION "user"."upsert_note_reaction" ("user_id" uuid, "p_actor_id" uuid, "p_note_id" uuid, "p_emoji" text, "p_updated_by" integer DEFAULT 0, "p_archived_at" timestamptz DEFAULT NULL::timestamp with time zone) RETURNS "public"."note_reaction" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_priority_id uuid;
    v_canonical_actor_id uuid;
    v_actor_sibling_ids uuid[];
    v_caller_sibling_ids uuid[];
    v_row note_reaction;
BEGIN
    IF p_emoji IS NULL OR p_emoji = '' THEN
        RAISE EXCEPTION 'p_emoji must be provided';
    END IF;

    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        note n
        JOIN thread_priority tp ON tp.thread_id = n.thread_id
            AND tp.user_id = upsert_note_reaction.user_id
    WHERE
        n.id = p_note_id;
    IF v_priority_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM note WHERE id = p_note_id) THEN
            RAISE EXCEPTION 'Note not found';
        END IF;
        RAISE EXCEPTION 'User does not have access to this note';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    -- Linked contacts are equivalent identities. The actor must overlap
    -- the caller's sibling set; we always write against the canonical
    -- (primary) contact id so the live row tracks the user's current
    -- primary contact.
    v_canonical_actor_id := "user".canonical_contact_id(p_actor_id);
    v_actor_sibling_ids := "user".sibling_contact_ids(p_actor_id);
    v_caller_sibling_ids := "user".user_contact_ids(user_id);
    IF NOT (v_actor_sibling_ids && v_caller_sibling_ids) THEN
        RAISE EXCEPTION 'Cannot modify reactions for other users';
    END IF;

    -- Collapse any sibling-aliased live rows to the canonical primary id.
    -- Matches the equivalent upsert_note_tag step.
    IF p_archived_at IS NULL AND array_length(v_actor_sibling_ids, 1) > 1 THEN
        UPDATE note_reaction
        SET archived_at = now(),
            updated_by = COALESCE(p_updated_by, 0)
        WHERE note_id = p_note_id
          AND emoji = p_emoji
          AND actor_id = ANY(v_actor_sibling_ids)
          AND actor_id != v_canonical_actor_id
          AND archived_at IS NULL;
    END IF;

    INSERT INTO note_reaction (actor_id, note_id, emoji, updated_by, archived_at)
        VALUES (v_canonical_actor_id, p_note_id, p_emoji, COALESCE(p_updated_by, 0), p_archived_at)
    ON CONFLICT (actor_id, note_id, emoji)
        DO UPDATE SET
            archived_at = EXCLUDED.archived_at,
            updated_by = EXCLUDED.updated_by,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Create "upsert_thread_reaction" function
CREATE FUNCTION "user"."upsert_thread_reaction" ("user_id" uuid, "p_actor_id" uuid, "p_thread_id" uuid, "p_emoji" text, "p_occurrence" text DEFAULT NULL::text, "p_updated_by" integer DEFAULT 0, "p_archived_at" timestamptz DEFAULT NULL::timestamp with time zone) RETURNS "public"."thread_reaction" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_priority_id uuid;
    v_canonical_actor_id uuid;
    v_actor_sibling_ids uuid[];
    v_caller_sibling_ids uuid[];
    v_row thread_reaction;
BEGIN
    IF p_emoji IS NULL OR p_emoji = '' THEN
        RAISE EXCEPTION 'p_emoji must be provided';
    END IF;

    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        thread_priority tp
    WHERE
        tp.thread_id = p_thread_id
        AND tp.user_id = upsert_thread_reaction.user_id;
    IF v_priority_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM thread WHERE id = p_thread_id) THEN
            RAISE EXCEPTION 'Thread not found';
        END IF;
        RAISE EXCEPTION 'User does not have access to this thread';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    v_canonical_actor_id := "user".canonical_contact_id(p_actor_id);
    v_actor_sibling_ids := "user".sibling_contact_ids(p_actor_id);
    v_caller_sibling_ids := "user".user_contact_ids(user_id);
    IF NOT (v_actor_sibling_ids && v_caller_sibling_ids) THEN
        RAISE EXCEPTION 'Cannot modify reactions for other users';
    END IF;

    IF p_archived_at IS NULL AND array_length(v_actor_sibling_ids, 1) > 1 THEN
        UPDATE thread_reaction
        SET archived_at = now(),
            updated_by = COALESCE(p_updated_by, 0)
        WHERE thread_id = p_thread_id
          AND emoji = p_emoji
          AND (occurrence IS NOT DISTINCT FROM p_occurrence)
          AND actor_id = ANY(v_actor_sibling_ids)
          AND actor_id != v_canonical_actor_id
          AND archived_at IS NULL;
    END IF;

    INSERT INTO thread_reaction (actor_id, thread_id, occurrence, emoji, updated_by, archived_at)
        VALUES (v_canonical_actor_id, p_thread_id, p_occurrence, p_emoji, COALESCE(p_updated_by, 0), p_archived_at)
    ON CONFLICT (actor_id, thread_id, occurrence, emoji)
        DO UPDATE SET
            archived_at = EXCLUDED.archived_at,
            updated_by = EXCLUDED.updated_by,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Create "note_reactions" view
CREATE VIEW "public"."note_reactions" (
  "note_id",
  "reactions",
  "updated_at",
  "seq",
  "updated_by"
) AS SELECT note_id,
    jsonb_object_agg(emoji, actor_ids) FILTER (WHERE actor_ids IS NOT NULL AND jsonb_array_length(actor_ids) > 0) AS reactions,
    max(updated_at) AS updated_at,
    max(seq) AS seq,
    (array_agg(updated_by ORDER BY sq.updated_at DESC))[1] AS updated_by
   FROM ( SELECT nr.note_id,
            nr.emoji,
            jsonb_agg(nr.actor_id) FILTER (WHERE nr.archived_at IS NULL) AS actor_ids,
            max(COALESCE(nr.archived_at, nr.updated_at)) AS updated_at,
            max(nr.seq) AS seq,
            (array_agg(nr.updated_by ORDER BY nr.updated_at DESC))[1] AS updated_by
           FROM public.note_reaction nr
          GROUP BY nr.note_id, nr.emoji) sq
  GROUP BY note_id;
-- Create "thread_reactions" view
CREATE VIEW "public"."thread_reactions" (
  "thread_id",
  "occurrence",
  "reactions",
  "updated_at",
  "seq",
  "updated_by"
) AS SELECT thread_id,
    occurrence,
    jsonb_object_agg(emoji, actor_ids) FILTER (WHERE actor_ids IS NOT NULL AND jsonb_array_length(actor_ids) > 0) AS reactions,
    max(updated_at) AS updated_at,
    max(seq) AS seq,
    (array_agg(updated_by ORDER BY sq.updated_at DESC))[1] AS updated_by
   FROM ( SELECT tr.thread_id,
            tr.occurrence,
            tr.emoji,
            jsonb_agg(tr.actor_id) FILTER (WHERE tr.archived_at IS NULL) AS actor_ids,
            max(COALESCE(tr.archived_at, tr.updated_at)) AS updated_at,
            max(tr.seq) AS seq,
            (array_agg(tr.updated_by ORDER BY tr.updated_at DESC))[1] AS updated_by
           FROM public.thread_reaction tr
          GROUP BY tr.thread_id, tr.occurrence, tr.emoji) sq
  GROUP BY thread_id, occurrence;
