CREATE OR REPLACE FUNCTION update_event_labels ()
    RETURNS TRIGGER
    AS $$
BEGIN
    DELETE FROM event_label
    WHERE event_id = _event_id;
    INSERT INTO event_label (event_id, label_id)
    SELECT
        e.id AS event_id,
        unnest(event_label_ids (e)) AS label_id
    FROM
        event_x e
    WHERE
        e.id = _event_id;
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

CREATE TRIGGER event_update_trigger
    AFTER UPDATE ON event
    FOR EACH ROW
    EXECUTE FUNCTION update_event_labels ();

