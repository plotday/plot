-- Precondition guards for thread merge / split via merged_into_thread_id.
--
-- The (twist_id, key) connector identity stays on the source row when
-- it's archived; upsert_thread() follows merged_into_thread_id to route
-- connector resyncs to the merged target. So no key migration is needed
-- — this trigger only enforces caller invariants:
--
--   NULL → set (merge): source must also be archived in the same UPDATE.
--   set → NULL (split): source must also be unarchived in the same UPDATE.
--
-- The Flutter merge/split commands obey this invariant; the guard
-- catches caller bugs loudly rather than silently producing inconsistent
-- state.
CREATE OR REPLACE FUNCTION thread_merge_preconditions ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Merge: NULL → set
    IF OLD.merged_into_thread_id IS NULL AND NEW.merged_into_thread_id IS NOT NULL THEN
        IF NEW.archived_at IS NULL THEN
            RAISE EXCEPTION 'thread merge requires archived_at to be set on source';
        END IF;
        RETURN NEW;
    END IF;

    -- Split: set → NULL
    IF OLD.merged_into_thread_id IS NOT NULL AND NEW.merged_into_thread_id IS NULL THEN
        IF NEW.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'thread split requires archived_at to be cleared on source';
        END IF;
        RETURN NEW;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER thread_merge_preconditions
    BEFORE UPDATE OF merged_into_thread_id ON "public"."thread"
    FOR EACH ROW
    EXECUTE FUNCTION thread_merge_preconditions ();
