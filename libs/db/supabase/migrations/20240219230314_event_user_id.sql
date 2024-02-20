DROP POLICY "Users can edit their own events" ON "public"."event";

ALTER TABLE "public"."event"
    ADD COLUMN "user_id" uuid;

UPDATE
    "public"."event" e
SET
    "user_id" = a."user_id"
FROM
    "public"."calendar" c
    JOIN "public"."account" a ON c."account_id" = a."id"
WHERE
    e."calendar_id" = c."id";

ALTER TABLE "public"."event"
    ALTER COLUMN "user_id" SET NOT NULL;

ALTER TABLE "public"."event"
    ADD CONSTRAINT "event_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."event" validate CONSTRAINT "event_user_id_fkey";

CREATE POLICY "Users can edit their own events" ON "public"."event" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = auth.uid ()));

ALTER TABLE "public"."event"
    ALTER COLUMN "provider_id" SET DEFAULT (gen_random_uuid ())::text;

CREATE OR REPLACE VIEW "public"."event_x" AS
WITH event_x1 AS (
    SELECT
        e_1.user_id,
        min(e_1.id) AS id,
        e_1.name,
        CASE WHEN calc_all_day (e_1.at) THEN
            tstzrange(timezone(user_timezone (), timezone('UTC'::text, lower(e_1.at))), timezone(user_timezone (), timezone('UTC'::text, upper(e_1.at))), '[)'::text)
        ELSE
            e_1.at
        END AS at,
        min(c.account_id) AS account_id,
        min(e_1.calendar_id) AS calendar_id,
        min(e_1.provider_id) AS provider_id,
        COALESCE(min(e_1.series), min(e_1.provider_id)) AS series,
        min(e_1.created_at) AS created_at,
        min(e_1.status) AS status,
        min(e_1.provider_link) AS provider_link,
        min(e_1.summary) AS summary,
        min(e_1.description) AS description,
        min(e_1.visibility) AS visibility,
        min(e_1.availability) AS availability,
        min(e_1.conferencing_url) AS conferencing_url,
        min(e_1.organizer_email) AS organizer_email,
        COALESCE(min(i.response) FILTER (WHERE (ct.is_self = TRUE)), 'tentative'::event_response) AS response,
        calc_minutes (e_1.at) AS minutes,
        (count(DISTINCT i.email) FILTER (WHERE (i.response = 'accepted'::event_response)))::integer AS attendee_count,
    (count(DISTINCT i.email))::integer AS invitee_count,
    CASE WHEN (EXTRACT(epoch FROM (upper(e_1.at) - lower(e_1.at))) >= (((60 * 60) * 23))::numeric) THEN
        (timezone(user_timezone (), timezone('UTC'::text, lower(e_1.at))))::date
    ELSE
        ((lower(e_1.at) AT TIME ZONE user_timezone ()))::date
    END AS day,
    COALESCE(bool_or(ct.is_self) FILTER (WHERE (ct.email = e_1.organizer_email)), FALSE) AS initiated,
    calc_all_day (e_1.at) AS all_day,
    calc_event_type (e_1.at, min(e_1.availability), COALESCE(min(i.response) FILTER (WHERE ct.is_self), 'tentative'::event_response), (((count(DISTINCT i.email))::integer > 1)
    OR bool_or(e_1.invitees_hidden))) AS type,
    calc_internal ((count(DISTINCT i.email))::integer, min(ct.domain_id) FILTER (WHERE ct.is_self), array_agg(DISTINCT ct.domain_id)) AS internal,
    array_remove(array_agg(DISTINCT i.email ORDER BY i.email), NULL::text) AS invitees,
    array_remove(array_agg(DISTINCT split_part(i.email, '@'::text, 2)
        ORDER BY (split_part(i.email, '@'::text, 2))), NULL::text) AS invitee_domains,
    bool_or(e_1.invitees_hidden) AS invitees_hidden,
    (min(e_1.series) IS NOT NULL) AS recurring,
    calc_notice (min(e_1.created_at), e_1.at) AS notice,
    calc_speedy (e_1.at) AS speedy,
    calc_rounded_length (e_1.at) AS rounded_length,
    calc_meeting_size ((count(DISTINCT i.email))::integer) AS size
FROM (((event e_1
        LEFT JOIN calendar c ON (e_1.calendar_id = c.id))
        LEFT JOIN invitee i ON (e_1.id = i.event_id))
        LEFT JOIN contact ct ON (((ct.user_id = e_1.user_id)
                    AND (i.email = ct.email))))
    WHERE ((e_1.calendar_id IS NULL)
        OR (c.enabled = TRUE))
GROUP BY
    e_1.user_id,
    e_1.name,
    e_1.at
)
SELECT
    e.user_id,
    e.id,
    e.name,
    e.at,
    e.account_id,
    e.calendar_id,
    e.provider_id,
    e.series,
    e.created_at,
    e.status,
    e.provider_link,
    e.summary,
    e.description,
    e.visibility,
    e.availability,
    e.conferencing_url,
    e.organizer_email,
    e.response,
    e.minutes,
    e.attendee_count,
    e.invitee_count,
    e.day,
    e.initiated,
    e.all_day,
    e.type,
    e.internal,
    e.invitees,
    e.invitee_domains,
    e.invitees_hidden,
    e.recurring,
    e.notice,
    e.speedy,
    e.rounded_length,
    e.size,
    act.id AS activity_id,
    act.path AS activity_path
FROM ((event_x1 e
    LEFT JOIN LATERAL (
        SELECT
            r_1.activity_id,
            (((((((
                CASE WHEN (r_1.series IS NOT NULL) THEN
                    128
                ELSE
                    0
                END + CASE WHEN (r_1.name IS NOT NULL) THEN
                    64
                ELSE
                    0
                END) + CASE WHEN (r_1.invitees IS NOT NULL) THEN
                32
            ELSE
                0
            END) + CASE WHEN (r_1.invitee_domain IS NOT NULL) THEN
            16
        ELSE
            0
        END) + CASE WHEN (r_1.account_id IS NOT NULL) THEN
        8
    ELSE
        0
    END) + CASE WHEN (r_1.calendar_id IS NOT NULL) THEN
    4
ELSE
    0
END) + CASE WHEN (r_1.internal IS NOT NULL) THEN
    2
ELSE
    0
END) + CASE WHEN (r_1.type IS NOT NULL) THEN
    1
ELSE
    0
END) AS priority
        FROM
            rule r_1
        WHERE ((e.user_id = r_1.user_id)
            AND ((r_1.series IS NULL)
                OR (e.series = r_1.series))
            AND ((r_1.name IS NULL)
                OR (e.name = r_1.name))
            AND ((r_1.invitees IS NULL)
                OR (e.invitees = r_1.invitees))
            AND ((r_1.invitee_domain IS NULL)
                OR (e.invitee_domains @> ARRAY[r_1.invitee_domain]))
            AND ((r_1.account_id IS NULL)
                OR (e.account_id = r_1.account_id))
            AND ((r_1.calendar_id IS NULL)
                OR (e.calendar_id = r_1.calendar_id))
            AND ((r_1.internal IS NULL)
                OR (e.internal = r_1.internal))
            AND ((r_1.type IS NULL)
                OR (e.type = r_1.type)))
    ORDER BY
        (((((((
                                    CASE WHEN (r_1.series IS NOT NULL) THEN
                                        128
                                    ELSE
                                        0
                                    END + CASE WHEN (r_1.name IS NOT NULL) THEN
                                        64
                                    ELSE
                                        0
                                    END) + CASE WHEN (r_1.invitees IS NOT NULL) THEN
                                    32
                                ELSE
                                    0
                                END) + CASE WHEN (r_1.invitee_domain IS NOT NULL) THEN
                                16
                            ELSE
                                0
                            END) + CASE WHEN (r_1.account_id IS NOT NULL) THEN
                            8
                        ELSE
                            0
                        END) + CASE WHEN (r_1.calendar_id IS NOT NULL) THEN
                        4
                    ELSE
                        0
                    END) + CASE WHEN (r_1.internal IS NOT NULL) THEN
                    2
                ELSE
                    0
                END) + CASE WHEN (r_1.type IS NOT NULL) THEN
                1
            ELSE
                0
            END) DESC,
        r_1.created_at DESC
    LIMIT 1) r ON (TRUE))
    LEFT JOIN activity act ON (((e.user_id = act.user_id)
                AND (r.activity_id = act.id))));

