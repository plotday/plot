UPDATE
    label
SET
    name = '1:1'
WHERE
    name = 'one-on-one';

INSERT INTO label (name)
    VALUES ('recurring'),
    ('initiated'),
    ('short-notice'),
    ('xs'),
    ('sm'),
    ('md'),
    ('lg'),
    ('xl'),
    ('internal');

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.upsert_event (_calendar_id bigint, _raw_event raw_event, _event event, _organizer event_contact, _invitees event_invitee[])
    RETURNS bigint
    LANGUAGE plpgsql
    AS $function$
DECLARE
    _user_id bigint;
    _new_event record;
    _contact_id bigint;
    _invitee event_invitee;
    _organizer_id bigint DEFAULT 343;
BEGIN
    -- get _user_id
    SELECT
        a.user_id INTO _user_id
    FROM
        account a
        JOIN calendar c ON a.id = c.account_id
    WHERE
        c.id = _calendar_id;
    -- create or update raw event
    INSERT INTO public.raw_event (calendar_id, provider_id, event, "sequence")
        VALUES (_raw_event.calendar_id, _raw_event.provider_id, _raw_event.event, _raw_event.sequence)
    ON CONFLICT (calendar_id, provider_id)
        DO UPDATE SET event = EXCLUDED.event, "sequence" = EXCLUDED.sequence;
    -- get (or create) organizer contact
    IF _organizer.email IS NOT NULL THEN
        INSERT INTO public.contact (email, name, user_id)
            VALUES (_organizer.email, _organizer.name, _user_id)
        ON CONFLICT (user_id, email)
            DO UPDATE SET
                name = COALESCE(contact.name, EXCLUDED.name)
            RETURNING
                id INTO _organizer_id;
    END IF;
    -- create or update event
    INSERT INTO public.event (created_at, calendar_id, provider_id, series, name, status, at, attended, provider_link, summary, description, visibility, availability, conferencing_url, organizer)
        VALUES (_event.created_at, _event.calendar_id, _event.provider_id, _event.series, _event.name, _event.status, _event.at, _event.attended, _event.provider_link, _event.summary, _event.description, _event.visibility, _event.availability, _event.conferencing_url, _organizer_id)
    ON CONFLICT (calendar_id, provider_id)
        DO UPDATE SET
            "sequence" = EXCLUDED.sequence + 1, series = EXCLUDED.series, name = EXCLUDED.name, status = EXCLUDED.status, at = EXCLUDED.at, attended = EXCLUDED.attended, provider_link = EXCLUDED.provider_link, summary = EXCLUDED.summary, description = EXCLUDED.description, visibility = EXCLUDED.visibility, availability = EXCLUDED.availability, conferencing_url = EXCLUDED.conferencing_url, organizer = EXCLUDED.organizer
        RETURNING
            id, "sequence" INTO _new_event;
    -- create or update contacts and invitees
    FOREACH _invitee IN ARRAY _invitees LOOP
        INSERT INTO public.contact (email, name, user_id)
            VALUES ((_invitee).contact.email, (_invitee).contact.name, _user_id)
        ON CONFLICT (user_id, email)
            DO UPDATE SET
                name = COALESCE(contact.name, EXCLUDED.name)
            RETURNING
                id INTO _contact_id;
        INSERT INTO public.invitee (event_id, contact_id, response, "sequence", is_optional)
            VALUES (_new_event.id, _contact_id, _invitee.response, _new_event.sequence, _invitee.is_optional)
        ON CONFLICT (event_id, contact_id)
            DO UPDATE SET
                response = EXCLUDED.response, "sequence" = EXCLUDED.sequence, is_optional = EXCLUDED.is_optional;
    END LOOP;
    -- delete any now missing invitees
    DELETE FROM invitee i
    WHERE i.event_id = _new_event.id
        AND "sequence" < _new_event.sequence;
    RETURN _new_event.id;
END;
$function$;

CREATE UNIQUE INDEX label_name_user_id_unique ON public.label USING btree (user_id, name) NULLS NOT DISTINCT;

ALTER TABLE "public"."label"
    ADD CONSTRAINT "label_name_user_id_unique" UNIQUE USING INDEX "label_name_user_id_unique";

