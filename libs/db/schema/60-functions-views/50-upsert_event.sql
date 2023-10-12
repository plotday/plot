CREATE TYPE contact_upsert AS (
    calendar_id bigint,
    "email" text,
    "name" text,
    "avatar_url" text
);

CREATE OR REPLACE FUNCTION public.upsert_contacts (_contacts contact_upsert[])
    RETURNS VOID
    AS $$
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
        name = EXCLUDED.name,
        avatar_url = EXCLUDED.avatar_url;
END;
$$
LANGUAGE plpgsql;

CREATE TYPE event_ids AS (
    calendar_id bigint,
    provider_id text
);

CREATE OR REPLACE FUNCTION public.cancel_events (_events event_ids[])
    RETURNS VOID
    LANGUAGE plpgsql
    AS $$
BEGIN
    FOR i IN 1..array_length(_events, 1)
    LOOP
        UPDATE
            public.event
        SET
            status = 'cancelled'
        WHERE
            calendar_id = _events[i].calendar_id
            AND provider_id = _events[i].provider_id;
    END LOOP;
END;
$$;

CREATE TYPE invitee_upsert AS (
    event_id bigint,
    email text,
    response event_response,
    is_optional boolean
);

CREATE OR REPLACE FUNCTION public.upsert_invitees (_event_ids bigint[], _invitees invitee_upsert[])
    RETURNS VOID
    AS $$
BEGIN
    DELETE FROM invitee
    WHERE event_id = ANY (_event_ids);
    INSERT INTO invitee (event_id, email, response, is_optional) (
        SELECT
            vals.event_id,
            vals._email,
            min(vals.response),
            bool_and(vals.is_optional)
        FROM
            unnest(_invitees) AS vals (event_id,
                _email,
                response,
                is_optional)
        GROUP BY
            event_id,
            _email)
ON CONFLICT (event_id,
    email)
    DO UPDATE SET
        response = EXCLUDED.response,
        is_optional = EXCLUDED.is_optional;
END;
$$
LANGUAGE plpgsql;

