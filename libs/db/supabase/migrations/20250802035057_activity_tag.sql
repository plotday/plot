CREATE TYPE "public"."tag_type" AS enum (
    'toggle',
    'count',
    'calculate'
);

DROP TRIGGER IF EXISTS "upsert_activity_x" ON "public"."activity_x";

DROP TRIGGER IF EXISTS "upsert_priority_x" ON "public"."priority_x";

ALTER TABLE "public"."tag"
    DROP CONSTRAINT "tag_priority_id_fkey";

ALTER TABLE "public"."tag"
    DROP CONSTRAINT "tag_user_id_fkey";

ALTER TABLE "public"."tag"
    DROP CONSTRAINT "tag_user_id_priority_id_emoji_key";

DROP VIEW IF EXISTS "public"."activity_children";

DROP VIEW IF EXISTS "public"."activity_x";

DROP VIEW IF EXISTS "public"."agent_x";

DROP VIEW IF EXISTS "public"."balance";

DROP VIEW IF EXISTS "public"."priority_children";

DROP VIEW IF EXISTS "public"."priority_x";

DROP VIEW IF EXISTS "public"."priority_tags";

DROP INDEX IF EXISTS "public"."tag_user_id_priority_id_emoji_key";

CREATE TABLE "public"."activity_tag" (
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone,
    "user_id" uuid NOT NULL,
    "activity_id" uuid,
    "tag_id" integer,
    "updated_by" integer NOT NULL DEFAULT 0
);

ALTER TABLE "public"."activity_tag" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."tag"
    DROP COLUMN "priority_id";

ALTER TABLE "public"."tag"
    DROP COLUMN "user_id";

ALTER TABLE "public"."tag"
    ADD COLUMN "deleted_at" timestamp with time zone;

ALTER TABLE "public"."tag"
    ADD COLUMN "type" tag_type NOT NULL DEFAULT 'toggle'::tag_type;

ALTER TABLE "public"."tag"
    ADD COLUMN "updated_at" timestamp with time zone NOT NULL DEFAULT now();

ALTER TABLE "public"."tag"
    ALTER COLUMN "id" SET data TYPE integer USING "id"::integer;

CREATE INDEX activity_tag_activity_id_tag_id_idx ON public.activity_tag USING btree (activity_id, tag_id)
WHERE (deleted_at IS NULL);

CREATE UNIQUE INDEX activity_tag_user_id_activity_id_tag_id_key ON public.activity_tag USING btree (user_id, activity_id, tag_id);

CREATE UNIQUE INDEX tag_emoji_key ON public.tag USING btree (emoji);

ALTER TABLE "public"."activity_tag"
    ADD CONSTRAINT "activity_tag_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES activity (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."activity_tag" validate CONSTRAINT "activity_tag_activity_id_fkey";

ALTER TABLE "public"."activity_tag"
    ADD CONSTRAINT "activity_tag_tag_id_fkey" FOREIGN KEY (tag_id) REFERENCES tag (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."activity_tag" validate CONSTRAINT "activity_tag_tag_id_fkey";

ALTER TABLE "public"."activity_tag"
    ADD CONSTRAINT "activity_tag_user_id_activity_id_tag_id_key" UNIQUE USING INDEX "activity_tag_user_id_activity_id_tag_id_key";

ALTER TABLE "public"."activity_tag"
    ADD CONSTRAINT "activity_tag_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."activity_tag" validate CONSTRAINT "activity_tag_user_id_fkey";

ALTER TABLE "public"."tag"
    ADD CONSTRAINT "tag_emoji_key" UNIQUE USING INDEX "tag_emoji_key";

CREATE OR REPLACE VIEW "public"."activity_tags" AS
SELECT
    sq.activity_id,
    jsonb_object_agg(sq.emoji, sq.user_ids) AS tags,
    sq.updated_at,
    sq.updated_by
FROM (
    SELECT
        at.activity_id,
        t.emoji,
        jsonb_agg(at.user_id) AS user_ids,
        max(COALESCE(at.deleted_at, at.created_at)) AS updated_at,
        (array_agg(at.updated_by ORDER BY COALESCE(at.deleted_at, at.created_at) DESC))[1] AS updated_by
    FROM (activity_tag at
        JOIN tag t ON (at.tag_id = t.id))
GROUP BY
    at.activity_id,
    t.emoji) sq
GROUP BY
    sq.activity_id,
    sq.updated_at,
    sq.updated_by;

CREATE OR REPLACE VIEW "public"."activity_x" AS
SELECT
    a.id,
    pu.user_id,
    a.created_at,
    GREATEST (a.updated_at, COALESCE(tags.updated_at, a.updated_at)) AS updated_at,
    CASE WHEN (COALESCE(tags.updated_at, a.updated_at) > a.updated_at) THEN
        tags.updated_by
    ELSE
        a.updated_by
    END AS updated_by,
    a.deleted_at,
    a.created_by,
    a.priority_id,
    a.path,
    a.draft,
    a.private,
    a.pinned,
    a.do_at,
    a.done_at,
    a.title,
    a.note,
    a.event_series,
    a."order",
    (COALESCE(a.done_at, (a.do_at)::timestamp with time zone, a.created_at))::date AS day,
    tags.tags
FROM (((priority_user pu
            JOIN priority p ON (((pu.priority_id = p.id)
                        OR (p.path <@ (
                                SELECT
                                    priority.path
                                FROM
                                    priority
                            WHERE (priority.id = pu.priority_id))))))
        JOIN activity a ON (a.priority_id = p.id))
    LEFT JOIN activity_tags tags ON (tags.activity_id = a.id))
WHERE ((pu.deleted_at IS NULL)
    AND (p.deleted_at IS NULL));

CREATE OR REPLACE VIEW "public"."priority_tags" AS
SELECT
    a.priority_id,
    t.id AS tag_id,
    t.emoji,
    count(*) AS count,
    max(COALESCE(at.deleted_at, at.created_at)) AS latest_at
FROM ((activity_tag at
        JOIN tag t ON (at.tag_id = t.id))
    JOIN activity a ON (at.activity_id = a.id))
WHERE ((at.deleted_at IS NULL)
    AND (a.deleted_at IS NULL))
GROUP BY
    a.priority_id,
    t.id,
    t.emoji;

CREATE OR REPLACE VIEW "public"."priority_x" AS
SELECT
    p.id,
    pu.user_id,
    p.created_at,
    GREATEST (settings.updated_at, pu.updated_at, p.updated_at) AS updated_at,
    GREATEST (pu.deleted_at, p.deleted_at) AS deleted_at,
    p.created_by,
    p.updated_by,
    (root.root
        AND (p.id = root.id)) AS root,
    p.title,
    CASE WHEN root.root THEN
        p.path
    ELSE
        (COALESCE(pu.path, user_root.path) || subpath (p.path, nlevel (root.path)))
    END AS path,
    CASE WHEN (pu.priority_id = p.id) THEN
        COALESCE(pu."order", p."order")
    ELSE
        p."order"
    END AS "order",
    settings.pomodoro,
    settings.color
FROM ((((priority_user pu
                JOIN priority root ON (pu.priority_id = root.id))
            JOIN priority user_root ON (((pu.user_id = user_root.created_by)
                        AND user_root.root)))
        JOIN priority p ON (root.path @> p.path))
    LEFT JOIN priority_settings settings ON (((settings.user_id = pu.user_id)
                AND (p.id = settings.priority_id))));

CREATE OR REPLACE VIEW "public"."activity_children" AS
SELECT
    a.id,
    c.id AS child_id
FROM (activity_x a
    JOIN activity c ON (c.path <@ a.path));

CREATE OR REPLACE VIEW "public"."priority_children" AS
SELECT
    a.id,
    c.id AS child_id
FROM (priority_x a
    JOIN priority c ON (c.path <@ a.path));

CREATE OR REPLACE VIEW "public"."agent_x" AS
SELECT
    pa.id,
    pa.priority_id,
    pa.agent_id,
    pa.name,
    pa.config,
    pa.created_at,
    pa.updated_at,
    pa.deleted_at,
    a.tools,
    pc.child_id AS priority_child_id
FROM ((priority_agent pa
        JOIN priority_children pc ON (pa.priority_id = pc.id))
    JOIN agent a ON (pa.agent_id = a.id));

CREATE OR REPLACE VIEW "public"."balance" AS
SELECT
    b.user_id,
    b.day,
    NULL::uuid AS priority_id,
    b.type,
    sum(b.count) AS count,
    (sum(b.seconds))::integer AS seconds,
    max(b.updated_at) AS updated_at
FROM
    balance_without_children b
WHERE (b.priority_id IS NULL)
GROUP BY
    b.user_id,
    b.day,
    b.type
UNION ALL
SELECT
    b.user_id,
    b.day,
    b.priority_id,
    b.type,
    sum(b.count) AS count,
    (sum(b.seconds))::integer AS seconds,
    max(b.updated_at) AS updated_at
FROM (balance_without_children b
    JOIN priority_children ac ON (b.priority_id = ac.child_id))
WHERE (b.priority_id IS NOT NULL)
GROUP BY
    b.user_id,
    b.day,
    b.priority_id,
    b.type;

CREATE POLICY "Users can insert activity_tag for activities in their accessibl" ON "public"."activity_tag" AS permissive
    FOR INSERT TO public
        WITH CHECK (((user_id = auth.uid ()) AND (EXISTS (
            SELECT
                1
            FROM
                activity a
            WHERE ((a.id = activity_tag.activity_id) AND user_has_priority_access (auth.uid (), a.priority_id))))));

CREATE POLICY "Users can update activity_tag for activities in their accessibl" ON "public"."activity_tag" AS permissive
    FOR UPDATE TO public
        USING (((user_id = auth.uid ()) OR (EXISTS (
            SELECT
                1
            FROM
                activity a
            WHERE ((a.id = activity_tag.activity_id) AND user_has_priority_access (auth.uid (), a.priority_id))))))
        WITH CHECK ((((user_id = auth.uid ()) AND (EXISTS (
            SELECT
                1
            FROM
                activity a
            WHERE ((a.id = activity_tag.activity_id) AND user_has_priority_access (auth.uid (), a.priority_id))))) OR ((user_id <> auth.uid ()) AND (deleted_at IS NOT NULL) AND (EXISTS (
                SELECT
                    1
                FROM (activity a
                JOIN tag t ON (t.id = activity_tag.tag_id))
            WHERE ((a.id = activity_tag.activity_id) AND user_has_priority_access (auth.uid (), a.priority_id) AND (t.type = 'toggle'::tag_type)))))));

CREATE POLICY "Users can view activity_tag in their accessible priorities" ON "public"."activity_tag" AS permissive
    FOR SELECT TO public
        USING (((user_id = auth.uid ()) OR (EXISTS (
            SELECT
                1
            FROM
                activity a
            WHERE ((a.id = activity_tag.activity_id) AND user_has_priority_access (auth.uid (), a.priority_id))))));

CREATE POLICY "Users can view all tags" ON "public"."tag" AS permissive
    FOR SELECT TO public
        USING (TRUE);

CREATE TRIGGER upsert_activity_x
    INSTEAD OF INSERT OR UPDATE ON public.activity_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_activity_x_upsert ();

CREATE TRIGGER upsert_priority_x
    INSTEAD OF INSERT OR UPDATE ON public.priority_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_priority_x_upsert ();

ALTER VIEW "public"."activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_children" SET (security_invoker = TRUE);

ALTER VIEW gap SET (security_invoker = TRUE);

ALTER VIEW gap_monthly SET (security_invoker = TRUE);

ALTER VIEW gap_daily SET (security_invoker = TRUE);

ALTER VIEW insight SET (security_invoker = TRUE);

ALTER VIEW "admin"."sync" SET (security_invoker = FALSE);

ALTER VIEW "admin"."invitation" SET (security_invoker = FALSE);

ALTER VIEW "public"."event_invitees" SET (security_invoker = TRUE);

ALTER VIEW "public"."event_x" SET (security_invoker = TRUE);

ALTER VIEW public.calendar_x SET (security_invoker = TRUE);

ALTER VIEW "admin"."user" SET (security_invoker = FALSE);

ALTER VIEW balance_without_children SET (security_invoker = TRUE);

ALTER VIEW balance SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_children" SET (security_invoker = TRUE);

ALTER VIEW "public"."agent_x" SET (security_invoker = TRUE);

