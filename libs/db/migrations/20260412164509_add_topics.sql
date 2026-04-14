-- Create enum type "topic_join_policy"
CREATE TYPE "public"."topic_join_policy" AS ENUM ('member', 'open', 'admin');
-- Create enum type "topic_type"
CREATE TYPE "public"."topic_type" AS ENUM ('public', 'team', 'private', 'announce');
-- Create "topic" table
CREATE TABLE "public"."topic" (
  "id" uuid NOT NULL DEFAULT uuidv7(),
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  "archived_at" timestamptz NULL,
  "name" text NOT NULL,
  "type" "public"."topic_type" NOT NULL DEFAULT 'private',
  "join_policy" "public"."topic_join_policy" NOT NULL DEFAULT 'member',
  "team_id" bigint NULL,
  "created_by" uuid NOT NULL,
  "auto_maintained" boolean NOT NULL DEFAULT false,
  PRIMARY KEY ("id"),
  CONSTRAINT "topic_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "topic_team_id_fkey" FOREIGN KEY ("team_id") REFERENCES "public"."team" ("id") ON UPDATE NO ACTION ON DELETE SET NULL
);
-- Create index "idx_topic_auto_everyone" to table: "topic"
CREATE UNIQUE INDEX "idx_topic_auto_everyone" ON "public"."topic" ("auto_maintained") WHERE ((auto_maintained = true) AND (team_id IS NULL));
-- Create index "idx_topic_auto_team" to table: "topic"
CREATE UNIQUE INDEX "idx_topic_auto_team" ON "public"."topic" ("team_id") WHERE ((auto_maintained = true) AND (team_id IS NOT NULL));
-- Create index "idx_topic_team_id" to table: "topic"
CREATE INDEX "idx_topic_team_id" ON "public"."topic" ("team_id") WHERE (team_id IS NOT NULL);
-- Create index "idx_topic_updated_at" to table: "topic"
CREATE INDEX "idx_topic_updated_at" ON "public"."topic" ("updated_at");
-- Set comment to table: "topic"
COMMENT ON TABLE "public"."topic" IS 'Named groups of contacts. Topics can be added to threads for dynamic group visibility — adding a member retroactively grants access to all threads the topic is on.';
-- Set comment to column: "auto_maintained" on table: "topic"
COMMENT ON COLUMN "public"."topic"."auto_maintained" IS 'TRUE for system-managed topics (Everyone, team topics). Membership is maintained by triggers and cannot be modified via API.';
-- Create "topic_admin" table
CREATE TABLE "public"."topic_admin" (
  "topic_id" uuid NOT NULL,
  "user_id" uuid NOT NULL,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("topic_id", "user_id"),
  CONSTRAINT "topic_admin_topic_id_fkey" FOREIGN KEY ("topic_id") REFERENCES "public"."topic" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "topic_admin_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create index "idx_topic_admin_user_id" to table: "topic_admin"
CREATE INDEX "idx_topic_admin_user_id" ON "public"."topic_admin" ("user_id");
-- Create "topic_member" table
CREATE TABLE "public"."topic_member" (
  "topic_id" uuid NOT NULL,
  "contact_id" uuid NOT NULL,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("topic_id", "contact_id"),
  CONSTRAINT "topic_member_contact_id_fkey" FOREIGN KEY ("contact_id") REFERENCES "public"."contact" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "topic_member_topic_id_fkey" FOREIGN KEY ("topic_id") REFERENCES "public"."topic" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create index "idx_topic_member_contact_id" to table: "topic_member"
CREATE INDEX "idx_topic_member_contact_id" ON "public"."topic_member" ("contact_id");
-- Create "add_topic_members" function
CREATE FUNCTION "public"."add_topic_members" ("p_user_id" uuid, "p_topic_id" uuid, "p_contact_ids" uuid[]) RETURNS void LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_topic RECORD;
BEGIN
    SELECT * INTO v_topic FROM topic WHERE id = p_topic_id;
    IF v_topic IS NULL THEN
        RAISE EXCEPTION 'Topic not found';
    END IF;
    IF v_topic.auto_maintained THEN
        RAISE EXCEPTION 'Cannot modify members of auto-maintained topic';
    END IF;

    IF v_topic.join_policy = 'admin' THEN
        IF NOT EXISTS (
            SELECT 1 FROM topic_admin
            WHERE topic_id = p_topic_id AND user_id = p_user_id
        ) THEN
            RAISE EXCEPTION 'Only admins can add members to this topic';
        END IF;
    ELSIF v_topic.join_policy = 'member' THEN
        IF NOT EXISTS (
            SELECT 1 FROM topic_admin
            WHERE topic_id = p_topic_id AND user_id = p_user_id
        ) AND NOT EXISTS (
            SELECT 1 FROM topic_member tm
            JOIN user_contact uc ON uc.contact_id = tm.contact_id
                AND uc.linked = TRUE AND uc.archived_at IS NULL
            WHERE tm.topic_id = p_topic_id AND uc.user_id = p_user_id
        ) THEN
            RAISE EXCEPTION 'Only members can add members to this topic';
        END IF;
    END IF;

    INSERT INTO topic_member (topic_id, contact_id)
    SELECT p_topic_id, unnest(p_contact_ids)
    ON CONFLICT DO NOTHING;
END;
$$;
-- Create "auto_create_team_topic" function
CREATE FUNCTION "public"."auto_create_team_topic" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_topic_id uuid;
    v_first_admin_id uuid;
BEGIN
    SELECT tu.user_id INTO v_first_admin_id
    FROM team_user tu
    WHERE tu.team_id = NEW.id
    ORDER BY (tu.role = 'admin') DESC, tu.created_at ASC
    LIMIT 1;

    IF v_first_admin_id IS NULL THEN
        RETURN NEW;
    END IF;

    INSERT INTO topic (name, type, team_id, created_by, auto_maintained)
    VALUES (NEW.name || ' Team', 'team', NEW.id, v_first_admin_id, TRUE)
    ON CONFLICT DO NOTHING;

    RETURN NEW;
END;
$$;
-- Create trigger "auto_create_team_topic"
CREATE TRIGGER "auto_create_team_topic" AFTER INSERT ON "public"."team" FOR EACH ROW EXECUTE FUNCTION "public"."auto_create_team_topic"();
-- Create "auto_maintain_team_topic_members" function
CREATE FUNCTION "public"."auto_maintain_team_topic_members" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_topic_id uuid;
    v_contact_id uuid;
    v_team_id bigint;
    v_user_id uuid;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_team_id := OLD.team_id;
        v_user_id := OLD.user_id;
    ELSE
        v_team_id := NEW.team_id;
        v_user_id := NEW.user_id;
    END IF;

    SELECT id INTO v_topic_id
    FROM topic
    WHERE team_id = v_team_id AND auto_maintained = TRUE;

    IF v_topic_id IS NULL AND TG_OP != 'DELETE' THEN
        INSERT INTO topic (name, type, team_id, created_by, auto_maintained)
        SELECT t.name || ' Team', 'team', t.id, v_user_id, TRUE
        FROM team t WHERE t.id = v_team_id
        ON CONFLICT DO NOTHING
        RETURNING id INTO v_topic_id;

        IF v_topic_id IS NULL THEN
            SELECT id INTO v_topic_id
            FROM topic
            WHERE team_id = v_team_id AND auto_maintained = TRUE;
        END IF;
    END IF;

    IF v_topic_id IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    SELECT uc.contact_id INTO v_contact_id
    FROM user_contact uc
    WHERE uc.user_id = v_user_id
      AND uc."primary" = TRUE
      AND uc.linked = TRUE
      AND uc.archived_at IS NULL;

    IF TG_OP = 'INSERT' THEN
        IF v_contact_id IS NOT NULL THEN
            INSERT INTO topic_member (topic_id, contact_id)
            VALUES (v_topic_id, v_contact_id)
            ON CONFLICT DO NOTHING;
        END IF;
        IF NEW.role = 'admin' THEN
            INSERT INTO topic_admin (topic_id, user_id)
            VALUES (v_topic_id, v_user_id)
            ON CONFLICT DO NOTHING;
        END IF;

    ELSIF TG_OP = 'DELETE' THEN
        IF v_contact_id IS NOT NULL THEN
            DELETE FROM topic_member
            WHERE topic_id = v_topic_id AND contact_id = v_contact_id;
        END IF;
        DELETE FROM topic_admin
        WHERE topic_id = v_topic_id AND user_id = v_user_id;

    ELSIF TG_OP = 'UPDATE' THEN
        IF NEW.role = 'admin' AND OLD.role != 'admin' THEN
            INSERT INTO topic_admin (topic_id, user_id)
            VALUES (v_topic_id, v_user_id)
            ON CONFLICT DO NOTHING;
        ELSIF NEW.role != 'admin' AND OLD.role = 'admin' THEN
            DELETE FROM topic_admin
            WHERE topic_id = v_topic_id AND user_id = v_user_id;
        END IF;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;
-- Create trigger "auto_maintain_team_topic_members"
CREATE TRIGGER "auto_maintain_team_topic_members" AFTER DELETE OR INSERT OR UPDATE ON "public"."team_user" FOR EACH ROW EXECUTE FUNCTION "public"."auto_maintain_team_topic_members"();
-- Drop "note_tags" view
DROP VIEW "user"."note_tags";
-- Drop "thread_tags" view
DROP VIEW "user"."thread_tags";
-- Drop "thread" view
DROP VIEW "user"."thread";
-- Modify "thread" table
ALTER TABLE "public"."thread" ADD COLUMN "topics" uuid[] NOT NULL DEFAULT ARRAY[]::uuid[];
-- Create index "idx_thread_topics" to table: "thread"
CREATE INDEX "idx_thread_topics" ON "public"."thread" USING GIN ("topics");
-- Set comment to column: "topics" on table: "thread"
COMMENT ON COLUMN "public"."thread"."topics" IS 'Topic IDs attached to this thread. Members of referenced topics gain visibility dynamically — new members automatically see past threads.';
-- Create "file_thread_priority_for_topic_members" function
CREATE FUNCTION "public"."file_thread_priority_for_topic_members" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
    v_peer_priority_id uuid;
    v_author_user_id uuid;
BEGIN
    IF NEW.topics IS NULL OR cardinality(NEW.topics) = 0 THEN
        RETURN NEW;
    END IF;

    IF EXISTS (SELECT 1 FROM "public"."user" WHERE id = NEW.created_by) THEN
        v_author_user_id := NEW.created_by;
    ELSE
        SELECT pt.owner_id INTO v_author_user_id
        FROM public.twist_instance pt
        WHERE pt.id = NEW.created_by;
    END IF;

    FOR r IN
        SELECT DISTINCT uc.user_id AS peer_user_id
        FROM unnest(NEW.topics) AS arr(topic_id)
        JOIN public.topic_member tm ON tm.topic_id = arr.topic_id
        JOIN public.user_contact uc
          ON uc.contact_id = tm.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM v_author_user_id
    LOOP
        v_peer_priority_id := public.match_priority_for_user(r.peer_user_id);
        IF v_peer_priority_id IS NOT NULL THEN
            INSERT INTO thread_priority (thread_id, user_id, priority_id, matched)
            VALUES (NEW.id, r.peer_user_id, v_peer_priority_id, TRUE)
            ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;

            INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
            VALUES (r.peer_user_id, NEW.id, 'inform-updates', 50)
            ON CONFLICT (user_id, thread_id) DO NOTHING;
        END IF;
    END LOOP;

    RETURN NEW;
END;
$$;
-- Create trigger "file_thread_priority_for_topic_members"
CREATE TRIGGER "file_thread_priority_for_topic_members" AFTER INSERT OR UPDATE OF "topics" ON "public"."thread" FOR EACH ROW EXECUTE FUNCTION "public"."file_thread_priority_for_topic_members"();
-- Create "auto_maintain_everyone_topic" function
CREATE FUNCTION "public"."auto_maintain_everyone_topic" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_everyone_topic_id uuid;
BEGIN
    IF TG_OP = 'INSERT' AND NEW.linked = TRUE AND NEW."primary" = TRUE THEN
        SELECT id INTO v_everyone_topic_id
        FROM topic
        WHERE auto_maintained = TRUE AND team_id IS NULL;

        IF v_everyone_topic_id IS NOT NULL THEN
            INSERT INTO topic_member (topic_id, contact_id)
            VALUES (v_everyone_topic_id, NEW.contact_id)
            ON CONFLICT DO NOTHING;
        END IF;

    ELSIF TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND (
        NEW.linked = FALSE OR NEW."primary" = FALSE OR NEW.archived_at IS NOT NULL
    )) THEN
        SELECT id INTO v_everyone_topic_id
        FROM topic
        WHERE auto_maintained = TRUE AND team_id IS NULL;

        IF v_everyone_topic_id IS NOT NULL THEN
            DELETE FROM topic_member
            WHERE topic_id = v_everyone_topic_id
              AND contact_id = COALESCE(OLD.contact_id, NEW.contact_id);
        END IF;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;
-- Create trigger "auto_maintain_everyone_topic"
CREATE TRIGGER "auto_maintain_everyone_topic" AFTER DELETE OR INSERT OR UPDATE ON "public"."user_contact" FOR EACH ROW EXECUTE FUNCTION "public"."auto_maintain_everyone_topic"();
-- Create "topic" view
CREATE VIEW "user"."topic" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "archived_at",
  "name",
  "type",
  "join_policy",
  "team_id",
  "auto_maintained",
  "is_admin",
  "is_member",
  "member_contact_ids"
) AS SELECT u.id AS user_id,
    t.id,
    t.created_at,
    t.updated_at,
    t.archived_at,
    t.name,
    t.type,
    t.join_policy,
    t.team_id,
    t.auto_maintained,
    (EXISTS ( SELECT 1
           FROM public.topic_admin ta
          WHERE ta.topic_id = t.id AND ta.user_id = u.id)) AS is_admin,
    (EXISTS ( SELECT 1
           FROM public.topic_member tm
             JOIN public.user_contact uc ON uc.contact_id = tm.contact_id AND uc.linked = true AND uc.archived_at IS NULL
          WHERE tm.topic_id = t.id AND uc.user_id = u.id)) AS is_member,
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM public.topic_admin ta
              WHERE ta.topic_id = t.id AND ta.user_id = u.id)) THEN ( SELECT COALESCE(array_agg(tm2.contact_id), ARRAY[]::uuid[]) AS "coalesce"
               FROM public.topic_member tm2
              WHERE tm2.topic_id = t.id)
            WHEN (t.type = ANY (ARRAY['private'::public.topic_type, 'team'::public.topic_type])) AND (EXISTS ( SELECT 1
               FROM public.topic_member tm
                 JOIN public.user_contact uc ON uc.contact_id = tm.contact_id AND uc.linked = true AND uc.archived_at IS NULL
              WHERE tm.topic_id = t.id AND uc.user_id = u.id)) THEN ( SELECT COALESCE(array_agg(tm2.contact_id), ARRAY[]::uuid[]) AS "coalesce"
               FROM public.topic_member tm2
              WHERE tm2.topic_id = t.id)
            ELSE ARRAY[]::uuid[]
        END AS member_contact_ids
   FROM public."user" u
     CROSS JOIN public.topic t
  WHERE t.archived_at IS NULL AND ((t.type = ANY (ARRAY['public'::public.topic_type, 'announce'::public.topic_type])) OR t.type = 'team'::public.topic_type AND (EXISTS ( SELECT 1
           FROM public.team_user tu
          WHERE tu.team_id = t.team_id AND tu.user_id = u.id)) OR t.type = 'private'::public.topic_type AND ((EXISTS ( SELECT 1
           FROM public.topic_admin ta
          WHERE ta.topic_id = t.id AND ta.user_id = u.id)) OR (EXISTS ( SELECT 1
           FROM public.topic_member tm
             JOIN public.user_contact uc ON uc.contact_id = tm.contact_id AND uc.linked = true AND uc.archived_at IS NULL
          WHERE tm.topic_id = t.id AND uc.user_id = u.id))));
-- Create "sync_user_for_topic" function
CREATE FUNCTION "public"."sync_user_for_topic" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    FOR v_user_id IN SELECT DISTINCT
        ut.user_id
    FROM
        new_table n
        JOIN "user"."topic" ut ON ut.id = n.id
    ORDER BY
        ut.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'topic', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create trigger "user_sync_topic_insert"
CREATE TRIGGER "user_sync_topic_insert" AFTER INSERT ON "public"."topic" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_topic"();
-- Create trigger "set_topic_updated_at"
CREATE TRIGGER "set_topic_updated_at" BEFORE INSERT OR UPDATE ON "public"."topic" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "user_sync_topic_update"
CREATE TRIGGER "user_sync_topic_update" AFTER UPDATE ON "public"."topic" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_topic"();
-- Create "file_thread_priority_on_topic_member_change" function
CREATE FUNCTION "public"."file_thread_priority_on_topic_member_change" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r_thread RECORD;
    v_peer_user_id uuid;
    v_peer_priority_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT uc.user_id INTO v_peer_user_id
        FROM public.user_contact uc
        WHERE uc.contact_id = NEW.contact_id
          AND uc.linked = TRUE
          AND uc.archived_at IS NULL
        LIMIT 1;

        IF v_peer_user_id IS NULL THEN
            RETURN NEW;
        END IF;

        v_peer_priority_id := public.match_priority_for_user(v_peer_user_id);
        IF v_peer_priority_id IS NULL THEN
            RETURN NEW;
        END IF;

        FOR r_thread IN
            SELECT t.id AS thread_id
            FROM public.thread t
            WHERE NEW.topic_id = ANY(t.topics)
              AND t.archived_at IS NULL
        LOOP
            INSERT INTO thread_priority (thread_id, user_id, priority_id, matched)
            VALUES (r_thread.thread_id, v_peer_user_id, v_peer_priority_id, TRUE)
            ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;

            INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
            VALUES (v_peer_user_id, r_thread.thread_id, 'inform-updates', 50)
            ON CONFLICT (user_id, thread_id) DO NOTHING;
        END LOOP;

        RETURN NEW;

    ELSIF TG_OP = 'DELETE' THEN
        SELECT uc.user_id INTO v_peer_user_id
        FROM public.user_contact uc
        WHERE uc.contact_id = OLD.contact_id
          AND uc.linked = TRUE
          AND uc.archived_at IS NULL
        LIMIT 1;

        IF v_peer_user_id IS NULL THEN
            RETURN OLD;
        END IF;

        FOR r_thread IN
            SELECT t.id AS thread_id
            FROM public.thread t
            WHERE OLD.topic_id = ANY(t.topics)
              AND t.archived_at IS NULL
        LOOP
            IF NOT EXISTS (
                SELECT 1 FROM public.thread t2
                WHERE t2.id = r_thread.thread_id
                  AND (
                    t2.contacts && "user".user_contact_ids(v_peer_user_id)
                    OR EXISTS (
                        SELECT 1 FROM unnest(t2.topics) AS tid
                        JOIN topic_member tm2 ON tm2.topic_id = tid
                        JOIN user_contact uc2 ON uc2.contact_id = tm2.contact_id
                            AND uc2.linked = TRUE AND uc2.archived_at IS NULL
                        WHERE uc2.user_id = v_peer_user_id
                          AND tm2.topic_id != OLD.topic_id
                    )
                  )
            ) THEN
                DELETE FROM thread_priority
                WHERE thread_id = r_thread.thread_id
                  AND user_id = v_peer_user_id
                  AND matched = TRUE;

                DELETE FROM thread_unread
                WHERE thread_id = r_thread.thread_id
                  AND user_id = v_peer_user_id;
            END IF;
        END LOOP;

        RETURN OLD;
    END IF;
END;
$$;
-- Create trigger "file_thread_priority_on_topic_member_change"
CREATE TRIGGER "file_thread_priority_on_topic_member_change" AFTER DELETE OR INSERT ON "public"."topic_member" FOR EACH ROW EXECUTE FUNCTION "public"."file_thread_priority_on_topic_member_change"();
-- Create trigger "set_topic_member_created_at"
CREATE TRIGGER "set_topic_member_created_at" BEFORE INSERT ON "public"."topic_member" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_topic_member_updated_at"
CREATE TRIGGER "set_topic_member_updated_at" BEFORE INSERT OR UPDATE ON "public"."topic_member" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Modify "setup_plot_app_priority" function
CREATE OR REPLACE FUNCTION "public"."setup_plot_app_priority" ("p_user_id" uuid) RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_priority_id uuid;
    v_priority_path ltree;
    v_created boolean := FALSE;
    v_author_id uuid;
    v_author_contact_id uuid;
    v_thread_id uuid;
    v_note_order integer;
    v_user_contact_id uuid;
BEGIN
    -- Onboarding content is authored by the Plot team account; fall back
    -- to the activating user if that account isn't seeded.
    SELECT id INTO v_author_id
    FROM "user"
    WHERE email = 'kris@plot.day'
    LIMIT 1;

    IF v_author_id IS NULL THEN
        v_author_id := p_user_id;
    END IF;

    SELECT id INTO v_author_contact_id
    FROM contact
    WHERE user_id = v_author_id
      AND "primary" = TRUE
    LIMIT 1;

    -- Get the activating user's primary contact for thread visibility
    SELECT id INTO v_user_contact_id
    FROM contact
    WHERE user_id = p_user_id
      AND "primary" = TRUE
    LIMIT 1;

    -- Get or create the per-user @plot.app priority
    SELECT id, path INTO v_priority_id, v_priority_path
    FROM priority
    WHERE key = '@plot.app'
      AND user_id = p_user_id
    LIMIT 1;

    IF v_priority_id IS NULL THEN
        v_priority_path := generate_path (NULL);
        INSERT INTO priority (created_by, user_id, title, path, color, key, updated_by)
            VALUES (p_user_id, p_user_id, 'Using Plot', v_priority_path, 7, '@plot.app', 0)
        RETURNING id INTO v_priority_id;
        v_created := TRUE;
    ELSE
        UPDATE priority
        SET title = 'Using Plot'
        WHERE id = v_priority_id
          AND title != 'Using Plot';
    END IF;

    -- Create onboarding threads if the 'welcome' thread doesn't exist yet
    IF NOT EXISTS (
        SELECT 1 FROM thread t
        JOIN thread_priority tp ON tp.thread_id = t.id
        WHERE tp.priority_id = v_priority_id AND tp.user_id = p_user_id AND t.key = 'welcome'
    ) THEN
        -- Welcome to Plot!
        INSERT INTO thread (created_by, title, preview, key, contacts)
            VALUES (v_author_id, 'Welcome to Plot!', 'Plot is your workspace for making progress on what matters.', 'welcome', ARRAY[v_author_contact_id, v_user_contact_id])
        RETURNING id INTO v_thread_id;
        INSERT INTO thread_priority (thread_id, user_id, priority_id, matched)
            VALUES (v_thread_id, p_user_id, v_priority_id, FALSE);
        v_note_order := 0;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'Plot is your workspace for making progress on what matters most. **Priorities**, **Threads**, and **Notes** are the core building blocks of Plot:

- **Priorities**: The roles, goals, and projects in your life — the areas you direct your focus and energy toward. Examples include Work, Personal, Launch New Product, Team Leader, and Learn French.
- **Threads**: Everything related to something you work on, collected in one place. A thread can contain notes, messages to collaborators, links syncing with external items, and chats with twists. Threads are the core thing you Start, Schedule, and Finish.
- **Notes**: The content within threads. Notes can be personal notes, messages to others, or synced comments with connected apps. Individual notes can be marked as tasks and assigned to people.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'When a thread needs your attention, you **Start** it — it could be as simple as reading and thinking, or it could mean taking action. You can also **Schedule** a thread to choose when you want to act on it. Starting and scheduling build your personal agenda — it''s not a shared project board, it''s your own action plan.

When you''re done with your part, you **Finish** the thread. This marks any of your tasks in the thread as done and completes linked items in connected apps — for example, closing a Linear ticket. You (and others) might Start and Finish a thread multiple times as work progresses. There''s also a separate **Done** tag you can add to mark a thread as complete for good for everyone.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'The **Agenda** is everything you plan to work on — started and scheduled threads, arranged in your preferred order. You can reorder items freely, move them to a different time or date, or remove them without losing the thread.

The **Activity** view shows what''s happening across your priorities — new threads, updates, and unread items. From Activity, you can add anything to your Agenda by Starting (act on it now) or Scheduling (act on it later).

A useful pattern: when a meeting or event appears in Activity from a calendar connection, tap **Start** to add a planning slot in your Agenda — useful for blocking time to prepare or to follow up afterward.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'Threads can contain links to items in external services — documents, calendar events, web pages, issues, and more. These are created by connections (more on that later). Links keep everything related to your work in one place, so you always have the context you need.');

        -- Create your initial Priorities
        INSERT INTO thread (created_by, title, preview, key, contacts)
            VALUES (v_author_id, 'Create your initial Priorities', 'Priorities are contexts for focus and often correspond to roles and goals. Nesting priorities creates a hierarchy that lets you organize at different levels of detail.', 'priorities', ARRAY[v_author_contact_id, v_user_contact_id])
        RETURNING id INTO v_thread_id;
        INSERT INTO thread_priority (thread_id, user_id, priority_id, matched)
            VALUES (v_thread_id, p_user_id, v_priority_id, FALSE);
        v_note_order := 0;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'Priorities are contexts for focus and often correspond to roles (like VP Marketing and Parent) and goals (like Launch New Product and Run a Marathon). **Nesting priorities** creates a hierarchy — for example, Work > Projects > Feature X > Planning — that lets you organize at different levels of detail.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), '**Viewing a priority shows threads from it and all descendants.** When you view Work, you see everything under Work (including Projects, Feature X, etc.). When you view Work > Projects > Feature X, you only see that specific area. **Everything** is the special priority that shows all your threads across all priorities.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), '**Best practice:** Organize from broad to specific. Example: Work > Marketing Campaign > Content Strategy, or Personal > Home Renovation > Kitchen Planning. Start with top-level contexts (Work, Personal, Family) then add specific projects within each. This allows you to zoom in for focus, and zoom out to make sure you''re not missing anything.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'Create your first priority — for example, **Work** or **Personal**. You can always add more or nest them later.');

        -- Add your Connections
        INSERT INTO thread (created_by, title, preview, key, contacts)
            VALUES (v_author_id, 'Add your Connections', 'Connections sync items from your other apps and services into Plot, often two-way.', 'connections', ARRAY[v_author_contact_id, v_user_contact_id])
        RETURNING id INTO v_thread_id;
        INSERT INTO thread_priority (thread_id, user_id, priority_id, matched)
            VALUES (v_thread_id, p_user_id, v_priority_id, FALSE);
        v_note_order := 0;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), '**Connections** sync items from your other apps and services into Plot, often two-way. For example, connect your calendar to see events as threads, or connect your email to bring in conversations. You can view and interact with items right from Plot — see and add comments on documents, respond to messages, update issues — the goal is to bring everything into one place.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'Each connection has channels you can enable or disable, letting you control exactly what syncs. Use the **Manage connections** command to browse available connections, vote for upcoming ones, and manage which are active.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'Set up your first connection using the **Manage connections** command.');

        -- Getting Around
        INSERT INTO thread (created_by, title, preview, key, contacts)
            VALUES (v_author_id, 'Getting Around', 'Keyboard and touch shortcuts', 'getting-around', ARRAY[v_author_contact_id, v_user_contact_id])
        RETURNING id INTO v_thread_id;
        INSERT INTO thread_priority (thread_id, user_id, priority_id, matched)
            VALUES (v_thread_id, p_user_id, v_priority_id, FALSE);
        v_note_order := 0;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'Plot''s goal is to get you to meaningful work as quickly as possible. Here are some tips for navigating efficiently.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), '**Keyboard Navigation**

- **⌘/** (Ctrl+/ on Windows): Search across all your threads and priorities
- **⌘K** (Ctrl+K on Windows): Open the command palette for quick actions
- **Up/Down arrows**: Select a note within a thread, then ⌘K (Ctrl+K) to open commands for that note
- **⌘T** (Ctrl+T on Windows): Focus a thread in the agenda list, then Up/Down to navigate and Enter to open the command menu
- **⌘⇧T** (Ctrl+Shift+T on Windows): Switch between agenda and activity feed
- **⌘Up/Down** (Ctrl+Up/Down on Windows): Open previous/next thread
- **⌘D** (Ctrl+D on Windows): Mark done / not done
- **⌘⇧D** (Ctrl+Shift+D on Windows): Schedule thread
- **⌘Delete** (Ctrl+Backspace on Windows): Archive thread
- **⌘N** (Ctrl+N on Windows): Create a new note (⌘⇧N / Ctrl+Shift+N on web browsers)
- **⌘Enter** (Ctrl+Enter on Windows): On the new thread page, create a task instead of a note');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), '**Touch Gestures**

- **Long press** on items to open the menu
- **Swipe right** on threads: Start (or Finish if already started)
- **Swipe left** on threads: Schedule for later
- **Share** a link from another app to Plot using the share sheet (iOS and Android)');

        -- Explore Twists
        INSERT INTO thread (created_by, title, preview, key, contacts)
            VALUES (v_author_id, 'Explore Twists', 'Twists are automations, workflows, and agents that do helpful things with your threads.', 'twists', ARRAY[v_author_contact_id, v_user_contact_id])
        RETURNING id INTO v_thread_id;
        INSERT INTO thread_priority (thread_id, user_id, priority_id, matched)
            VALUES (v_thread_id, p_user_id, v_priority_id, FALSE);
        v_note_order := 0;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), '**Twists** are automations, workflows, and agents that do helpful things with your threads — often working with items from your connections. For example, a twist might triage your inbox, summarize meeting notes, or create follow-up tasks from action items.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'You can also **create your own twists**, either by describing what you want (Plot AI will generate it for you) or by writing code. Custom twists can automate any workflow specific to your needs.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'You can also **@mention Plot** in any thread to ask questions about your notes and links. Plot will search your content and answer using AI.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'Try **@mentioning Plot** in any thread to ask a question about your notes.');

        -- Set up Notifications
        INSERT INTO thread (created_by, title, preview, key, contacts)
            VALUES (v_author_id, 'Set up Notifications', 'Plot delivers notifications based on urgency, not instantly. Adjust per-priority timing to match how you work.', 'notifications', ARRAY[v_author_contact_id, v_user_contact_id])
        RETURNING id INTO v_thread_id;
        INSERT INTO thread_priority (thread_id, user_id, priority_id, matched)
            VALUES (v_thread_id, p_user_id, v_priority_id, FALSE);
        v_note_order := 0;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'Plot has smart notifications that are timed based on urgency rather than sending everything immediately. This means new messages and updates won''t interrupt you the moment they arrive — instead, they''re delivered within a timeframe you control. If you''re used to getting notified immediately for every message, you may want to adjust these defaults.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'Each priority has two timing settings:

- **See requests within** (default: 30 minutes) — how quickly you''re notified about messages and mentions
- **See updates within** (default: 1 hour) — how quickly you''re notified about other changes

To adjust, open a priority''s command menu and choose **Notifications**, or tap the notification icon on a priority. Settings inherit from parent priorities, so you can set timing once at the top level and all children will follow.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'Plot also has **quiet hours** (default: 9 PM – 7 AM) during which notifications are silenced. You can customize quiet hours per priority in the same Notifications settings.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'Adjust notification timing for your most important priority.');

        -- Clean up without losing anything
        INSERT INTO thread (created_by, title, preview, key, contacts)
            VALUES (v_author_id, 'Clean up without losing anything', 'When something is no longer actively in progress, you can archive it. Archived items are hidden but never deleted.', 'clean-up', ARRAY[v_author_contact_id, v_user_contact_id])
        RETURNING id INTO v_thread_id;
        INSERT INTO thread_priority (thread_id, user_id, priority_id, matched)
            VALUES (v_thread_id, p_user_id, v_priority_id, FALSE);
        v_note_order := 0;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'When something is no longer actively in progress — a completed project, an old priority, a finished thread — you can **archive it**. Archived items are hidden from your main view but never deleted. You can view archived items or unarchive them anytime.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'You can archive both **priorities** and **threads**. Use the command menu on any priority or thread to find the archive option. Archiving a priority hides it and all its threads from the main view.');
    END IF;

    RETURN jsonb_build_object('success', TRUE, 'priority_id', v_priority_id, 'created', v_created);
END;
$$;
-- Create trigger "set_topic_created_at"
CREATE TRIGGER "set_topic_created_at" BEFORE INSERT ON "public"."topic" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create "create_topic" function
CREATE FUNCTION "public"."create_topic" ("p_user_id" uuid, "p_name" text, "p_type" "public"."topic_type" DEFAULT 'private', "p_join_policy" "public"."topic_join_policy" DEFAULT 'member', "p_team_id" bigint DEFAULT NULL::bigint, "p_member_contact_ids" uuid[] DEFAULT ARRAY[]::uuid[]) RETURNS uuid LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_topic_id uuid;
BEGIN
    IF p_team_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM team_user
            WHERE team_id = p_team_id AND user_id = p_user_id
        ) THEN
            RAISE EXCEPTION 'User is not a member of this team';
        END IF;
    END IF;

    INSERT INTO topic (name, type, join_policy, team_id, created_by)
    VALUES (p_name, p_type, p_join_policy, p_team_id, p_user_id)
    RETURNING id INTO v_topic_id;

    INSERT INTO topic_admin (topic_id, user_id)
    VALUES (v_topic_id, p_user_id);

    IF cardinality(p_member_contact_ids) > 0 THEN
        INSERT INTO topic_member (topic_id, contact_id)
        SELECT v_topic_id, unnest(p_member_contact_ids)
        ON CONFLICT DO NOTHING;
    END IF;

    RETURN v_topic_id;
END;
$$;
-- Create "remove_topic_members" function
CREATE FUNCTION "public"."remove_topic_members" ("p_user_id" uuid, "p_topic_id" uuid, "p_contact_ids" uuid[]) RETURNS void LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_topic RECORD;
BEGIN
    SELECT * INTO v_topic FROM topic WHERE id = p_topic_id;
    IF v_topic IS NULL THEN
        RAISE EXCEPTION 'Topic not found';
    END IF;
    IF v_topic.auto_maintained THEN
        RAISE EXCEPTION 'Cannot modify members of auto-maintained topic';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM topic_admin
        WHERE topic_id = p_topic_id AND user_id = p_user_id
    ) AND NOT EXISTS (
        SELECT 1 FROM topic_member tm
        JOIN user_contact uc ON uc.contact_id = tm.contact_id
            AND uc.linked = TRUE AND uc.archived_at IS NULL
        WHERE tm.topic_id = p_topic_id AND uc.user_id = p_user_id
    ) THEN
        RAISE EXCEPTION 'Insufficient permission to remove topic members';
    END IF;

    DELETE FROM topic_member
    WHERE topic_id = p_topic_id AND contact_id = ANY(p_contact_ids);
END;
$$;
-- Create "share_thread_with_topics" function
CREATE FUNCTION "public"."share_thread_with_topics" ("p_user_id" uuid, "p_thread_id" uuid, "p_add_topic_ids" uuid[] DEFAULT ARRAY[]::uuid[], "p_remove_topic_ids" uuid[] DEFAULT ARRAY[]::uuid[]) RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_current_topics uuid[];
    v_new_topics uuid[];
    v_topic RECORD;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM thread_priority tp
        WHERE tp.thread_id = p_thread_id
          AND tp.user_id = p_user_id
    ) THEN
        RAISE EXCEPTION 'User does not have access to this thread';
    END IF;

    FOR v_topic IN
        SELECT t.id, t.type
        FROM unnest(p_add_topic_ids) AS arr(id)
        JOIN topic t ON t.id = arr.id
        WHERE t.archived_at IS NULL
    LOOP
        IF v_topic.type = 'announce' THEN
            IF NOT EXISTS (
                SELECT 1 FROM topic_admin
                WHERE topic_id = v_topic.id AND user_id = p_user_id
            ) THEN
                RAISE EXCEPTION 'Only admins can add announce topics to threads';
            END IF;
        ELSIF v_topic.type IN ('private', 'team') THEN
            IF NOT EXISTS (
                SELECT 1 FROM topic_admin
                WHERE topic_id = v_topic.id AND user_id = p_user_id
            ) AND NOT EXISTS (
                SELECT 1 FROM topic_member tm
                JOIN user_contact uc ON uc.contact_id = tm.contact_id
                    AND uc.linked = TRUE AND uc.archived_at IS NULL
                WHERE tm.topic_id = v_topic.id AND uc.user_id = p_user_id
            ) THEN
                RAISE EXCEPTION 'User does not have permission to add this topic';
            END IF;
        END IF;
    END LOOP;

    SELECT topics INTO v_current_topics
    FROM thread
    WHERE id = p_thread_id;

    IF v_current_topics IS NULL THEN
        v_current_topics := ARRAY[]::uuid[];
    END IF;

    SELECT COALESCE(array_agg(DISTINCT tid), ARRAY[]::uuid[])
    INTO v_new_topics
    FROM (
        SELECT unnest(v_current_topics) AS tid
        UNION
        SELECT unnest(p_add_topic_ids)
    ) all_topics
    WHERE tid != ALL(COALESCE(p_remove_topic_ids, ARRAY[]::uuid[]));

    UPDATE thread
    SET topics = v_new_topics
    WHERE id = p_thread_id;

    RETURN jsonb_build_object('topics', to_jsonb(v_new_topics));
END;
$$;
-- Modify "upsert_thread" function
CREATE OR REPLACE FUNCTION "user"."upsert_thread" ("user_id" uuid, "p_thread" jsonb, "p_defaults" jsonb DEFAULT '{}') RETURNS "public"."thread" LANGUAGE plpgsql AS $$
DECLARE
    v_result thread;
    v_existing thread;
    v_id uuid;
    -- Variables for derived values
    v_priority_id uuid;
    v_created_by uuid;
    -- Archived status check
    v_is_archived boolean;
BEGIN
    -- Extract required fields from JSONB, with fallback to p_defaults for INSERT
    v_id := COALESCE((p_thread ->> 'id')::uuid, (p_defaults ->> 'id')::uuid);
    v_priority_id := COALESCE((p_thread ->> 'priority_id')::uuid, (p_defaults ->> 'priority_id')::uuid);
    v_created_by := COALESCE((p_thread ->> 'created_by')::uuid, (p_defaults ->> 'created_by')::uuid, user_id);
    -- Generate id if not provided
    -- If key is provided and no id was given, look up existing thread by key + creator
    IF v_id IS NULL THEN
        IF (p_thread ? 'key') AND v_created_by IS NOT NULL THEN
            SELECT id INTO v_id
            FROM thread
            WHERE key = (p_thread ->> 'key')
              AND created_by = v_created_by;
        END IF;
        IF v_id IS NULL THEN
            v_id := uuidv7 ();
        END IF;
    END IF;
    -- Resolve priority_id from existing thread_priority row for this user
    IF v_priority_id IS NULL THEN
        SELECT
            tp.priority_id INTO v_priority_id
        FROM
            thread_priority tp
        WHERE
            tp.thread_id = v_id
            AND tp.user_id = upsert_thread.user_id;
    END IF;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'priority_id must be provided';
    END IF;
    -- Validate access: user must own the target priority
    IF NOT user_has_priority_access(upsert_thread.user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;
    -- Validate created_by when it differs from user_id
    IF v_created_by IS DISTINCT FROM user_id THEN
        IF NOT EXISTS (
            SELECT
                1
            FROM
                twist_instance pt
            WHERE
                pt.id = v_created_by
                AND pt.owner_id = upsert_thread.user_id) THEN
            RAISE EXCEPTION 'created_by must be user or owned twist_instance';
        END IF;
    END IF;
    -- Fetch the existing thread row (if any) so partial updates can fall
    -- back to current values. Postgres evaluates CHECK constraints on the
    -- INSERT values before ON CONFLICT DO UPDATE kicks in, so the VALUES
    -- clause below must already satisfy the constraints — which means the
    -- INSERT must carry the existing row's values for any field the caller
    -- omitted.
    SELECT * INTO v_existing FROM thread WHERE id = v_id;

    v_is_archived := COALESCE(
        v_existing.archived_at IS NOT NULL
        OR (v_existing.id IS NOT NULL AND NOT EXISTS (
            SELECT 1
            FROM thread_priority tp
            WHERE tp.thread_id = v_existing.id
              AND tp.user_id = upsert_thread.user_id
              AND EXISTS (
                  SELECT 1 FROM priority p
                  WHERE p.id = tp.priority_id
                    AND p.archived_at IS NULL
              )
        )),
        FALSE
    );
    -- Perform the upsert and return the full row.
    -- INSERT values fall through p_thread → p_defaults → v_existing so
    -- that on the UPDATE path the INSERT satisfies CHECK constraints even
    -- when the caller omits fields like title.
    INSERT INTO thread (id, created_by, title, preview, updated_by, sync_depth, contacts, topics, draft, key, icon)
        VALUES (
            v_id,
            v_created_by,
            COALESCE(p_thread ->> 'title', p_defaults ->> 'title', v_existing.title),
            COALESCE(p_thread ->> 'preview', p_defaults ->> 'preview', v_existing.preview),
            COALESCE((p_thread ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, v_existing.updated_by, 0),
            COALESCE((p_thread ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint, v_existing.sync_depth),
            CASE
                WHEN p_thread ? 'contacts' AND jsonb_typeof(p_thread -> 'contacts') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'contacts') elem), ARRAY[]::uuid[])
                WHEN p_defaults ? 'contacts' AND jsonb_typeof(p_defaults -> 'contacts') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'contacts') elem), ARRAY[]::uuid[])
                ELSE COALESCE(v_existing.contacts, ARRAY[]::uuid[])
            END,
            CASE
                WHEN p_thread ? 'topics' AND jsonb_typeof(p_thread -> 'topics') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'topics') elem), ARRAY[]::uuid[])
                WHEN p_defaults ? 'topics' AND jsonb_typeof(p_defaults -> 'topics') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'topics') elem), ARRAY[]::uuid[])
                ELSE COALESCE(v_existing.topics, ARRAY[]::uuid[])
            END,
            COALESCE((p_thread ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, v_existing.draft, FALSE),
            COALESCE(p_thread ->> 'key', p_defaults ->> 'key', v_existing.key),
            COALESCE(p_thread ->> 'icon', p_defaults ->> 'icon', v_existing.icon)
        )
    ON CONFLICT (id)
        DO UPDATE SET
            -- Update fields only if key is present in p_thread
            -- Key absent: keep existing value (unless archived, then use p_defaults)
            -- Key present (even with null): use provided value (allows clearing)
            -- If archived: treat as INSERT and apply p_defaults
            title = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'title', p_defaults ->> 'title', thread.title)
            ELSE
                CASE WHEN p_thread ? 'title' THEN
                    p_thread ->> 'title'
                ELSE
                    thread.title
                END
            END,
            preview = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'preview', p_defaults ->> 'preview', thread.preview)
            ELSE
                CASE WHEN p_thread ? 'preview' THEN
                    p_thread ->> 'preview'
                ELSE
                    thread.preview
                END
            END,
            updated_by = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, thread.updated_by)
            ELSE
                CASE WHEN p_thread ? 'updated_by' THEN
                    (p_thread ->> 'updated_by')::integer
                ELSE
                    thread.updated_by
                END
            END,
            sync_depth = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint, thread.sync_depth)
            ELSE
                CASE WHEN p_thread ? 'sync_depth' THEN
                    (p_thread ->> 'sync_depth')::smallint
                ELSE
                    thread.sync_depth
                END
            END,
            contacts = CASE WHEN v_is_archived THEN
                CASE WHEN p_thread ? 'contacts' AND jsonb_typeof(p_thread -> 'contacts') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'contacts') elem), ARRAY[]::uuid[])
                WHEN p_defaults ? 'contacts' AND jsonb_typeof(p_defaults -> 'contacts') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'contacts') elem), ARRAY[]::uuid[])
                ELSE thread.contacts END
            ELSE
                CASE WHEN p_thread ? 'contacts' AND jsonb_typeof(p_thread -> 'contacts') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'contacts') elem), ARRAY[]::uuid[])
                ELSE
                    thread.contacts
                END
            END,
            topics = CASE WHEN v_is_archived THEN
                CASE WHEN p_thread ? 'topics' AND jsonb_typeof(p_thread -> 'topics') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'topics') elem), ARRAY[]::uuid[])
                WHEN p_defaults ? 'topics' AND jsonb_typeof(p_defaults -> 'topics') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'topics') elem), ARRAY[]::uuid[])
                ELSE thread.topics END
            ELSE
                CASE WHEN p_thread ? 'topics' AND jsonb_typeof(p_thread -> 'topics') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'topics') elem), ARRAY[]::uuid[])
                ELSE
                    thread.topics
                END
            END,
            draft = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, thread.draft)
            ELSE
                CASE WHEN p_thread ? 'draft' THEN
                    (p_thread ->> 'draft')::boolean
                ELSE
                    thread.draft
                END
            END,
            icon = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'icon', p_defaults ->> 'icon', thread.icon)
            ELSE
                CASE WHEN p_thread ? 'icon' THEN
                    p_thread ->> 'icon'
                ELSE
                    thread.icon
                END
            END,
            archived_at = CASE WHEN v_is_archived THEN
                CASE WHEN p_thread ? 'archived_at' THEN
                    (p_thread ->> 'archived_at')::timestamptz
                WHEN p_defaults ? 'archived_at' THEN
                    (p_defaults ->> 'archived_at')::timestamptz
                ELSE
                    thread.archived_at
                END
            ELSE
                CASE WHEN p_thread ? 'archived_at' THEN
                    (p_thread ->> 'archived_at')::timestamptz
                ELSE
                    thread.archived_at
                END
            END,
            created_by = v_created_by
        RETURNING
            * INTO v_result;

    -- Upsert the calling user's thread_priority row. On update, only
    -- change priority_id if the caller explicitly provided one.
    INSERT INTO thread_priority (thread_id, user_id, priority_id, matched)
    VALUES (v_result.id, upsert_thread.user_id, v_priority_id, FALSE)
    ON CONFLICT (thread_id, user_id)
    DO UPDATE SET
        priority_id = CASE
            WHEN p_thread ? 'priority_id' THEN EXCLUDED.priority_id
            WHEN v_is_archived THEN EXCLUDED.priority_id
            ELSE thread_priority.priority_id
        END,
        updated_at = now();

    -- Peer thread_priority rows are populated by the file_thread_priority_peers
    -- trigger on thread, so both upsert_thread callers and raw inserts from
    -- the twist runtime share the same filing behaviour.

    RETURN v_result;
END;
$$;
-- Create "user_topic_ids" function
CREATE FUNCTION "user"."user_topic_ids" ("p_user_id" uuid) RETURNS uuid[] LANGUAGE sql STABLE AS $$
SELECT COALESCE(array_agg(DISTINCT tm.topic_id), ARRAY[]::uuid[])
    FROM topic_member tm
    JOIN user_contact uc ON uc.contact_id = tm.contact_id
        AND uc.linked = TRUE
        AND uc.archived_at IS NULL
    WHERE uc.user_id = p_user_id;
$$;
-- Modify "thread_x" view
CREATE OR REPLACE VIEW "public"."thread_x" (
  "id",
  "created_at",
  "updated_at",
  "created_by",
  "updated_by",
  "archived_at",
  "draft",
  "contacts",
  "title",
  "preview",
  "last_note_created_at",
  "sync_depth",
  "last_note_source_created_at",
  "key",
  "icon",
  "topics"
) AS SELECT id,
    created_at,
    updated_at,
    created_by,
    updated_by,
    archived_at,
    draft,
    contacts,
    title,
    preview,
    last_note_created_at,
    sync_depth,
    last_note_source_created_at,
    key,
    icon,
    topics
   FROM public.thread a;
-- Create "thread" view
CREATE VIEW "user"."thread" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "updated_by",
  "archived_at",
  "priority_id",
  "priority_path",
  "draft",
  "contacts",
  "topics",
  "title",
  "preview",
  "icon",
  "last_note_created_at",
  "last_note_source_created_at",
  "bumped_at",
  "unread",
  "importance",
  "urgency",
  "activity_at",
  "agenda_at"
) AS WITH link_agg AS (
         SELECT link.thread_id,
            max(link.source_created_at) AS source_created_at
           FROM public.link
          GROUP BY link.thread_id
        )
 SELECT tp.user_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone), COALESCE(tu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at) AS archived_at,
    tp.priority_id,
    upe.path AS priority_path,
    a.draft,
    a.contacts,
    a.topics,
    a.title,
    a.preview,
    a.icon,
    a.last_note_created_at,
    a.last_note_source_created_at,
    tu.bumped_at,
    COALESCE(tu.read_at IS NULL AND tu.user_id IS NOT NULL, false) AS unread,
    COALESCE(
        CASE
            WHEN tu.read_at IS NULL AND tu.user_id IS NOT NULL THEN tu.importance
            ELSE NULL::smallint
        END, 0::smallint) AS importance,
    COALESCE(
        CASE
            WHEN tu.read_at IS NULL AND tu.user_id IS NOT NULL THEN tu.urgency
            ELSE NULL::text
        END, NULL::text) AS urgency,
    COALESCE(GREATEST(a.last_note_source_created_at, la.source_created_at, tu.bumped_at, ( SELECT
                CASE
                    WHEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamp with time zone) <= now() THEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamp with time zone)
                    ELSE NULL::timestamp with time zone
                END AS "case"
           FROM public.schedule s_feed
          WHERE s_feed.thread_id = a.id AND s_feed.user_id IS NULL AND s_feed.occurrence IS NULL AND s_feed.archived_at IS NULL
         LIMIT 1)), a.created_at) AS activity_at,
    ( SELECT tstzrange(bounds.lo, GREATEST(bounds.lo, bounds.hi), '[]'::text) AS tstzrange
           FROM ( SELECT COALESCE(LEAST(( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                          WHERE s_lo.thread_id = a.id AND s_lo.user_id IS NULL AND s_lo.archived_at IS NULL
                          ORDER BY (COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone))
                         LIMIT 1), ( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                          WHERE s_lo.thread_id = a.id AND s_lo.user_id = tp.user_id AND s_lo.archived_at IS NULL
                          ORDER BY (COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone))
                         LIMIT 1), ( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                             JOIN public.link l_lo ON l_lo.id = s_lo.link_id
                          WHERE l_lo.thread_id = a.id AND s_lo.user_id IS NULL AND s_lo.archived_at IS NULL
                          ORDER BY (COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone))
                         LIMIT 1)), a.created_at) AS lo,
                    COALESCE(
                        CASE
                            WHEN (EXISTS ( SELECT 1
                               FROM public.schedule s_rec
                              WHERE s_rec.thread_id = a.id AND s_rec.archived_at IS NULL AND s_rec.recurrence_rule IS NOT NULL)) OR (EXISTS ( SELECT 1
                               FROM public.schedule s_rec
                                 JOIN public.link l_rec ON l_rec.id = s_rec.link_id
                              WHERE l_rec.thread_id = a.id AND s_rec.archived_at IS NULL AND s_rec.recurrence_rule IS NOT NULL)) THEN 'infinity'::timestamp with time zone
                            WHEN (EXISTS ( SELECT 1
                               FROM public.schedule s_ub
                              WHERE s_ub.thread_id = a.id AND s_ub.archived_at IS NULL AND (s_ub.at IS NOT NULL OR s_ub."on" IS NOT NULL) AND COALESCE(upper(s_ub.at), upper(s_ub."on")::timestamp with time zone) IS NULL)) OR (EXISTS ( SELECT 1
                               FROM public.schedule s_ub
                                 JOIN public.link l_ub ON l_ub.id = s_ub.link_id
                              WHERE l_ub.thread_id = a.id AND s_ub.archived_at IS NULL AND (s_ub.at IS NOT NULL OR s_ub."on" IS NOT NULL) AND COALESCE(upper(s_ub.at), upper(s_ub."on")::timestamp with time zone) IS NULL)) THEN 'infinity'::timestamp with time zone
                            ELSE GREATEST(( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                              WHERE s_hi.thread_id = a.id AND s_hi.user_id IS NULL AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1), ( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                              WHERE s_hi.thread_id = a.id AND s_hi.user_id = tp.user_id AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1), ( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                                 JOIN public.link l_hi ON l_hi.id = s_hi.link_id
                              WHERE l_hi.thread_id = a.id AND s_hi.user_id IS NULL AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1))
                        END, a.created_at) AS hi) bounds) AS agenda_at
   FROM public.thread a
     JOIN public.thread_priority tp ON tp.thread_id = a.id
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = tp.priority_id
     LEFT JOIN public.thread_unread tu ON tu.user_id = tp.user_id AND tu.thread_id = a.id
     LEFT JOIN link_agg la ON la.thread_id = a.id
  WHERE (a.draft = false OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.topics && "user".user_topic_ids(tp.user_id));
-- Create "note_tags" view
CREATE VIEW "user"."note_tags" (
  "user_id",
  "id",
  "updated_at",
  "archived_at",
  "priority_id",
  "priority_path",
  "tags"
) AS SELECT ua.user_id,
    n.id,
    nt.updated_at,
    ua.archived_at,
    ua.priority_id,
    ua.priority_path,
    nt.tags
   FROM public.note_tags nt
     JOIN public.note n ON n.id = nt.note_id
     JOIN "user".thread ua ON ua.id = n.thread_id
  WHERE (n.draft = false OR n.created_by = ua.user_id) AND (n.access_contacts IS NULL OR n.created_by = ua.user_id OR n.access_contacts && "user".user_contact_ids(ua.user_id));
-- Create "thread_tags" view
CREATE VIEW "user"."thread_tags" (
  "user_id",
  "id",
  "archived_at",
  "occurrence",
  "updated_at",
  "priority_id",
  "priority_path",
  "tags"
) AS SELECT ua.user_id,
    ua.id,
    ua.archived_at,
    tt.occurrence,
    tt.updated_at,
    ua.priority_id,
    ua.priority_path,
    tt.tags
   FROM "user".thread ua
     JOIN LATERAL ( SELECT sq.occurrence,
            jsonb_object_agg(sq.tag_id, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL AND jsonb_array_length(sq.actor_ids) > 0) AS tags,
            max(sq.updated_at) AS updated_at
           FROM ( SELECT at.occurrence,
                    at.tag_id,
                    jsonb_agg(at.actor_id) FILTER (WHERE at.archived_at IS NULL) AS actor_ids,
                    max(COALESCE(at.archived_at, at.updated_at)) AS updated_at
                   FROM public.thread_tag at
                  WHERE at.thread_id = ua.id
                  GROUP BY at.occurrence, at.tag_id) sq
          GROUP BY sq.occurrence) tt ON true;
