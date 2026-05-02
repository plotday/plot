-- Create "default_priority_block_user_id" function
CREATE FUNCTION "public"."default_priority_block_user_id" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.user_id IS NULL THEN
        SELECT user_id INTO NEW.user_id
        FROM priority
        WHERE id = NEW.priority_id;
    END IF;
    RETURN NEW;
END;
$$;
-- Create "priority_block" table
CREATE TABLE "public"."priority_block" (
  "id" uuid NOT NULL DEFAULT uuidv7(),
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  "created_by" uuid NOT NULL,
  "user_id" uuid NOT NULL,
  "priority_id" uuid NOT NULL,
  "order_value" double precision NOT NULL,
  "effective_at" timestamptz NOT NULL,
  "archived_at" timestamptz NULL,
  "updated_by" integer NOT NULL DEFAULT 0,
  "seq" xid8 NOT NULL DEFAULT pg_current_xact_id(),
  PRIMARY KEY ("id"),
  CONSTRAINT "priority_block_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "priority_block_priority_id_fkey" FOREIGN KEY ("priority_id") REFERENCES "public"."priority" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "priority_block_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create index "idx_priority_block_priority_effective" to table: "priority_block"
CREATE UNIQUE INDEX "idx_priority_block_priority_effective" ON "public"."priority_block" ("priority_id", "effective_at");
-- Create index "idx_priority_block_priority_effective_desc" to table: "priority_block"
CREATE INDEX "idx_priority_block_priority_effective_desc" ON "public"."priority_block" ("priority_id", "effective_at" DESC);
-- Create index "idx_priority_block_seq" to table: "priority_block"
CREATE INDEX "idx_priority_block_seq" ON "public"."priority_block" ("seq");
-- Create index "idx_priority_block_user_id" to table: "priority_block"
CREATE INDEX "idx_priority_block_user_id" ON "public"."priority_block" ("user_id");
-- Create trigger "default_priority_block_user_id"
CREATE TRIGGER "default_priority_block_user_id" BEFORE INSERT ON "public"."priority_block" FOR EACH ROW EXECUTE FUNCTION "public"."default_priority_block_user_id"();
-- Create trigger "set_priority_block_created_at"
CREATE TRIGGER "set_priority_block_created_at" BEFORE INSERT ON "public"."priority_block" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_priority_block_created_by"
CREATE TRIGGER "set_priority_block_created_by" BEFORE INSERT ON "public"."priority_block" FOR EACH ROW EXECUTE FUNCTION "public"."update_created_by"();
-- Create trigger "set_priority_block_updated_at"
CREATE TRIGGER "set_priority_block_updated_at" BEFORE INSERT OR UPDATE ON "public"."priority_block" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq_and_updated_at"();
-- Create "priority_block" view
CREATE VIEW "user"."priority_block" (
  "id",
  "user_id",
  "priority_id",
  "order_value",
  "effective_at",
  "archived_at",
  "created_at",
  "updated_at",
  "created_by",
  "updated_by",
  "seq"
) AS SELECT id,
    user_id,
    priority_id,
    order_value,
    effective_at,
    archived_at,
    created_at,
    updated_at,
    created_by,
    updated_by,
    seq
   FROM public.priority_block pb;
-- Create "upsert_priority_block" function
CREATE FUNCTION "user"."upsert_priority_block" ("user_id" uuid, "p_block" jsonb) RETURNS "user"."priority_block" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
#variable_conflict use_column
DECLARE
    _input "user"."priority_block";
    _archive_past boolean;
    v_row "user"."priority_block";
BEGIN
    _input := jsonb_populate_record(NULL::"user"."priority_block", p_block || jsonb_build_object('user_id', upsert_priority_block.user_id));
    _archive_past := COALESCE((p_block ->> '_archive_past')::boolean, FALSE);

    PERFORM "user".assert_priority_access(upsert_priority_block.user_id, _input.priority_id);

    IF _archive_past THEN
        UPDATE priority_block
        SET archived_at = now(),
            updated_by = COALESCE(_input.updated_by, 0)
        WHERE priority_id = _input.priority_id
          AND user_id = upsert_priority_block.user_id
          AND effective_at < _input.effective_at
          AND archived_at IS NULL;
    END IF;

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
        RETURNING * INTO v_row;

    SELECT * INTO v_row
    FROM "user".priority_block
    WHERE id = v_row.id AND user_id = upsert_priority_block.user_id;

    RETURN v_row;
END;
$$;
