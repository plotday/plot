-- Modify "upsert_priority_block" function
CREATE OR REPLACE FUNCTION "user"."upsert_priority_block" ("user_id" uuid, "p_block" jsonb) RETURNS "user"."priority_block" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
#variable_conflict use_column
DECLARE
    _input "user"."priority_block";
    _new_id uuid;
    v_row "user"."priority_block";
BEGIN
    _input := jsonb_populate_record(NULL::"user"."priority_block", p_block || jsonb_build_object('user_id', upsert_priority_block.user_id));

    PERFORM "user".assert_priority_access(upsert_priority_block.user_id, _input.priority_id);

    INSERT INTO priority_block (id, priority_id, user_id, order_value, effective_at, archived_at, created_by, updated_by)
        VALUES (
            COALESCE(_input.id, uuidv7()),
            _input.priority_id,
            upsert_priority_block.user_id,
            _input.order_value,
            _input.effective_at,
            _input.archived_at,
            _input.created_by,
            COALESCE(_input.updated_by, 0)
        )
    ON CONFLICT (priority_id, effective_at)
        DO UPDATE SET
            order_value = EXCLUDED.order_value,
            archived_at = EXCLUDED.archived_at,
            updated_by = EXCLUDED.updated_by
        RETURNING id INTO _new_id;

    SELECT * INTO v_row
    FROM "user".priority_block
    WHERE id = _new_id AND user_id = upsert_priority_block.user_id;

    RETURN v_row;
END;
$$;
