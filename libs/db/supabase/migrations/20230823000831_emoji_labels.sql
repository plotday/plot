ALTER TABLE "public"."label"
    DROP CONSTRAINT "label_name_user_id_unique";

DROP FUNCTION IF EXISTS "public"."label_stats" (user_id bigint, during tstzrange);

DROP FUNCTION IF EXISTS "public"."org_stats" (user_id bigint, during tstzrange);

DROP INDEX IF EXISTS "public"."label_name_user_id_unique";

DELETE FROM label;

ALTER TABLE "public"."label"
    ADD COLUMN "order" integer NOT NULL;

ALTER TABLE "public"."label"
    ADD COLUMN "tag" text NOT NULL;

ALTER TABLE "public"."label"
    ALTER COLUMN "name" DROP NOT NULL;

CREATE UNIQUE INDEX label_user_id_tag_unique ON public.label USING btree (user_id, tag) NULLS NOT DISTINCT;

ALTER TABLE "public"."label"
    ADD CONSTRAINT "label_user_id_tag_unique" UNIQUE USING INDEX "label_user_id_tag_unique";

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.label_stats (user_id bigint, during tstzrange)
    RETURNS TABLE (
        label_id bigint,
        "order" integer,
        tag text,
        name text,
        description text,
        response event_response,
        event_count integer,
        minutes integer)
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN query
    SELECT
        l.id AS label_id,
        l.order AS "order",
        l.tag AS tag,
        l.name AS name,
        l.description AS description,
        e.response,
        count(*)::integer AS event_count,
        sum(e.minutes)::integer AS minutes
    FROM
        event_x e
        JOIN event_label le ON le.event_id = e.id
        JOIN label l ON le.label_id = l.id
    WHERE
        e.user_id = label_stats.user_id
        AND e.at && during
        AND e.status != 'cancelled'
    GROUP BY
        l.id,
        e.status,
        e.response;
END
$function$;

CREATE OR REPLACE FUNCTION public.org_stats (user_id bigint, during tstzrange)
    RETURNS TABLE (
        label_id bigint,
        "order" integer,
        tag text,
        name text,
        description text,
        response event_response,
        event_count integer,
        minutes integer)
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN query
    SELECT
        l.id AS label_id,
        l.order AS "order",
        l.tag AS tag,
        l.name AS name,
        l.description AS description,
        e.response,
        count(*)::integer AS event_count,
        sum((e.minutes + 15) * e.invitee_count)::integer AS minutes
    FROM
        event_x e
        JOIN contact c ON c.id = e.organizer
        JOIN event_label le ON le.event_id = e.id
        JOIN label l ON le.label_id = l.id
    WHERE
        e.user_id = org_stats.user_id
        AND e.at && during
        AND c.contact_user_id = e.user_id
        AND e.status != 'cancelled'
        AND l.id != 24 -- initiated
    GROUP BY
        l.id,
        e.status,
        e.response;
END
$function$;

-- Synchronize this list with src/event.ts
--
-- When changing, copy this in to a manual migration (`pnpm new-migration`).
INSERT INTO label (id, "order", tag, name, description)
    VALUES (1, 10, '💼', 'All meetings', NULL),
    (2, 100, '👥 1:1', NULL, '2 invitees'),
    (3, 110, '👥 SM', NULL, '3-4 invitees'),
    (4, 120, '👥 MD', NULL, '5-7 invitees'),
    (5, 130, '👥 LG', NULL, '8-15 invitees'),
    (6, 140, '👥 XL', NULL, '16-29 invitees'),
    (7, 150, '👥 XXL', NULL, '30+ invitees'),
    (8, 200, '🏢', 'Internal', 'Only invitees from your company'),
    (9, 210, '🤝', 'External', 'Includes invitees from outside your company'),
    (10, 300, '⏳ ¼h', NULL, '≤20 minutes'),
    (11, 310, '⏳ ½h', NULL, '20-39 minutes'),
    (12, 320, '⏳ ¾h', NULL, '40-49 minutes'),
    (13, 330, '⏳ 1h', NULL, '50-74 minutes'),
    (14, 340, '⏳ 1½h', NULL, '75-100 minutes'),
    (15, 350, '⏳ 2h', NULL, '101-130 minutes'),
    (16, 360, '⏳ 2½h', NULL, '131-160 minutes'),
    (17, 370, '⏳ 3h', NULL, '161-180 minutes'),
    (18, 380, '⏳ ½d', NULL, '3-5 hours (inclusive)'),
    (19, 390, '⏳ ¾d', NULL, '5-7 hours (exclusive)'),
    (20, 400, '⏳ 1d', 'All day', '7+ hours'),
    (21, 500, '🔁', 'Recurring', NULL),
    (22, 530, '🚨', 'Short notice', 'Created less than 18 hours before starting'),
    (23, 560, '💨', 'Speedy', 'Shortened by 5-15 minutes from a 30-minute interval'),
    (24, 600, '🫵', 'Initiated', 'Meetings you organize')
ON CONFLICT (id)
    DO UPDATE SET
        name = EXCLUDED.name, tag = EXCLUDED.tag, "order" = EXCLUDED.order, description = EXCLUDED.description;

