-- Modify "transfer_twist_key_on_merge" function
CREATE OR REPLACE FUNCTION "public"."transfer_twist_key_on_merge" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_target_twist_id bigint;
    v_target_key text;
BEGIN
    -- Merge: NULL → set
    IF OLD.merged_into_thread_id IS NULL AND NEW.merged_into_thread_id IS NOT NULL THEN
        IF NEW.archived_at IS NULL THEN
            RAISE EXCEPTION 'thread merge requires archived_at to be set on source';
        END IF;
        IF NEW.twist_id IS NULL OR NEW.key IS NULL THEN
            RETURN NEW;
        END IF;
        SELECT twist_id, key
        INTO v_target_twist_id, v_target_key
        FROM thread
        WHERE id = NEW.merged_into_thread_id
        FOR UPDATE;
        IF NOT FOUND THEN
            RETURN NEW;
        END IF;
        IF v_target_twist_id IS NULL OR v_target_key IS NULL THEN
            UPDATE thread
            SET twist_id = NEW.twist_id,
                key = NEW.key
            WHERE id = NEW.merged_into_thread_id;
        END IF;
        -- If target already has its own different (twist_id, key), do nothing.
        RETURN NEW;
    END IF;

    -- Split: set → NULL
    IF OLD.merged_into_thread_id IS NOT NULL AND NEW.merged_into_thread_id IS NULL THEN
        IF NEW.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'thread split requires archived_at to be cleared on source';
        END IF;
        SELECT twist_id, key
        INTO v_target_twist_id, v_target_key
        FROM thread
        WHERE id = OLD.merged_into_thread_id
        FOR UPDATE;
        IF NOT FOUND THEN
            RETURN NEW;
        END IF;
        IF v_target_twist_id IS NOT NULL
            AND v_target_key IS NOT NULL
            AND v_target_twist_id = NEW.twist_id
            AND v_target_key = NEW.key THEN
            UPDATE thread
            SET twist_id = NULL,
                key = NULL
            WHERE id = OLD.merged_into_thread_id;
        END IF;
        RETURN NEW;
    END IF;

    RETURN NEW;
END;
$$;
