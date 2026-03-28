-- Create "thread_association" table
CREATE TABLE "public"."thread_association" (
  "id" uuid NOT NULL DEFAULT uuidv7(),
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  "parent_thread_id" uuid NOT NULL,
  "child_thread_id" uuid NOT NULL,
  "order" double precision NOT NULL,
  "archived_at" timestamptz NULL,
  PRIMARY KEY ("id"),
  CONSTRAINT "thread_association_child_thread_id_fkey" FOREIGN KEY ("child_thread_id") REFERENCES "public"."thread" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "thread_association_parent_thread_id_fkey" FOREIGN KEY ("parent_thread_id") REFERENCES "public"."thread" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create index "idx_thread_association_child" to table: "thread_association"
CREATE INDEX "idx_thread_association_child" ON "public"."thread_association" ("child_thread_id");
-- Create index "idx_thread_association_parent" to table: "thread_association"
CREATE INDEX "idx_thread_association_parent" ON "public"."thread_association" ("parent_thread_id");
-- Create index "idx_thread_association_updated_at" to table: "thread_association"
CREATE INDEX "idx_thread_association_updated_at" ON "public"."thread_association" ("updated_at");
-- Create index "thread_association_child_active_unique" to table: "thread_association"
CREATE UNIQUE INDEX "thread_association_child_active_unique" ON "public"."thread_association" ("child_thread_id") WHERE (archived_at IS NULL);
-- Create index "thread_association_parent_child_unique" to table: "thread_association"
CREATE UNIQUE INDEX "thread_association_parent_child_unique" ON "public"."thread_association" ("parent_thread_id", "child_thread_id") WHERE (archived_at IS NULL);
-- Create trigger "set_thread_association_created_at"
CREATE TRIGGER "set_thread_association_created_at" BEFORE INSERT ON "public"."thread_association" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_thread_association_updated_at"
CREATE TRIGGER "set_thread_association_updated_at" BEFORE INSERT OR UPDATE ON "public"."thread_association" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create "upsert_thread_association" function
CREATE FUNCTION "user"."upsert_thread_association" ("user_id" uuid, "p_association" jsonb) RETURNS "public"."thread_association" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_id uuid;
    v_parent_thread_id uuid;
    v_child_thread_id uuid;
    v_parent_priority_id uuid;
    v_child_priority_id uuid;
    v_parent_role text;
    v_child_role text;
    v_existing_id uuid;
    v_result thread_association;
BEGIN
    -- Extract fields
    v_id := (p_association ->> 'id')::uuid;
    v_parent_thread_id := (p_association ->> 'parent_thread_id')::uuid;
    v_child_thread_id := (p_association ->> 'child_thread_id')::uuid;

    -- Resolve parent/child from existing association if updating
    IF v_parent_thread_id IS NULL AND v_child_thread_id IS NULL AND v_id IS NOT NULL THEN
        SELECT
            ta.parent_thread_id, ta.child_thread_id
            INTO v_parent_thread_id, v_child_thread_id
        FROM
            thread_association ta
        WHERE
            ta.id = v_id;
    END IF;

    -- Must have both parent and child
    IF v_parent_thread_id IS NULL THEN
        RAISE EXCEPTION 'parent_thread_id must be provided';
    END IF;
    IF v_child_thread_id IS NULL THEN
        RAISE EXCEPTION 'child_thread_id must be provided';
    END IF;

    -- Cannot associate a thread with itself
    IF v_parent_thread_id = v_child_thread_id THEN
        RAISE EXCEPTION 'Cannot associate a thread with itself';
    END IF;

    -- Check access to parent thread's priority
    SELECT
        a.priority_id,
        CASE WHEN bool_or(pu.role = 'member') THEN 'member' ELSE COALESCE(MAX(pu.role), NULL) END
    INTO v_parent_priority_id, v_parent_role
    FROM
        thread a
        JOIN priority p ON p.id = a.priority_id
        LEFT JOIN priority pp ON p.path <@ pp.path
        LEFT JOIN priority_user pu ON pu.priority_id = pp.id
            AND pu.user_id = upsert_thread_association.user_id
            AND pu.archived_at IS NULL
    WHERE
        a.id = v_parent_thread_id
    GROUP BY a.priority_id;

    IF v_parent_priority_id IS NULL THEN
        RAISE EXCEPTION 'Parent thread not found';
    END IF;
    IF v_parent_role IS NULL THEN
        RAISE EXCEPTION 'User does not have access to parent thread priority';
    END IF;
    IF v_parent_role = 'viewer' THEN
        RAISE EXCEPTION 'Viewer members cannot create or modify associations';
    END IF;

    -- Check access to child thread's priority
    SELECT
        a.priority_id,
        CASE WHEN bool_or(pu.role = 'member') THEN 'member' ELSE COALESCE(MAX(pu.role), NULL) END
    INTO v_child_priority_id, v_child_role
    FROM
        thread a
        JOIN priority p ON p.id = a.priority_id
        LEFT JOIN priority pp ON p.path <@ pp.path
        LEFT JOIN priority_user pu ON pu.priority_id = pp.id
            AND pu.user_id = upsert_thread_association.user_id
            AND pu.archived_at IS NULL
    WHERE
        a.id = v_child_thread_id
    GROUP BY a.priority_id;

    IF v_child_priority_id IS NULL THEN
        RAISE EXCEPTION 'Child thread not found';
    END IF;
    IF v_child_role IS NULL THEN
        RAISE EXCEPTION 'User does not have access to child thread priority';
    END IF;

    -- Resolve existing association ID based on unique constraints
    -- Try to find an existing active association for this child (a child
    -- can only be actively associated with one parent at a time)
    IF v_id IS NULL THEN
        SELECT ta.id INTO v_existing_id
        FROM thread_association ta
        WHERE ta.parent_thread_id = v_parent_thread_id
          AND ta.child_thread_id = v_child_thread_id
          AND ta.archived_at IS NULL;

        IF v_existing_id IS NOT NULL THEN
            v_id := v_existing_id;
        END IF;
    END IF;

    -- Archive any existing active association for this child with a different parent
    -- (handles the "move to different event" case)
    UPDATE thread_association
    SET archived_at = now()
    WHERE child_thread_id = v_child_thread_id
      AND archived_at IS NULL
      AND (v_id IS NULL OR id != v_id)
      AND parent_thread_id != v_parent_thread_id;

    -- Generate id if not provided
    IF v_id IS NULL THEN
        v_id := uuidv7();
    END IF;

    -- Perform the upsert
    INSERT INTO thread_association (id, parent_thread_id, child_thread_id, "order", archived_at)
        VALUES (
            v_id,
            v_parent_thread_id,
            v_child_thread_id,
            COALESCE((p_association ->> 'order')::double precision, public.order_first()),
            (p_association ->> 'archived_at')::timestamptz
        )
    ON CONFLICT (id)
        DO UPDATE SET
            "order" = CASE WHEN p_association ? 'order' THEN
                (p_association ->> 'order')::double precision
            ELSE
                thread_association."order"
            END,
            archived_at = CASE WHEN p_association ? 'archived_at' THEN
                (p_association ->> 'archived_at')::timestamptz
            ELSE
                thread_association.archived_at
            END
    RETURNING * INTO v_result;

    RETURN v_result;
END;
$$;
-- Create "thread_association" view
CREATE VIEW "user"."thread_association" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "archived_at",
  "parent_thread_id",
  "child_thread_id",
  "order"
) AS SELECT upe.user_id,
    ta.id,
    ta.created_at,
    ta.updated_at,
    ta.archived_at,
    ta.parent_thread_id,
    ta.child_thread_id,
    ta."order"
   FROM public.thread_association ta
     JOIN public.thread t ON t.id = ta.parent_thread_id
     JOIN "user".priority_expanded upe ON upe.priority_id = t.priority_id;
