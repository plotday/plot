-- Append-only log of applied classification decisions and explicit user
-- moves. One row per APPLIED decision: the TS hybrid classifier (API worker
-- foreground + classify worker consumer), the SQL classifier's inline
-- trigger paths (stage 'sql:applied'), and user corrections
-- (stage 'user_move'). Previews (classify_thread_for_user_explain admin
-- routes, /sync/priority-match) are never logged.
--
-- Deliberately has NO foreign keys: no lock coupling with the
-- deadlock-sensitive thread/thread_priority write paths, and rows must
-- survive cleanup of their referents. Not synced — no user.* view reads
-- this table; it exists for offline mining (eval seeder via the readonly
-- prod proxy: an auto-decision row followed by a user_move row with a
-- different priority_id is a labeled misclassification) and for
-- survival-rate telemetry per stage/classifier version.
CREATE TABLE "public"."classification_decision" (
    "id" bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "thread_id" uuid NOT NULL,
    "user_id" uuid NOT NULL,
    -- Chosen filing as the classifier returned it; NULL only for stage
    -- 'none' (callers' root fallback is not substituted in).
    "priority_id" uuid,
    -- Cascade stage ('scoring', 'llm_tiebreaker', ...), 'sql:applied' for
    -- the SQL trigger paths, or 'user_move'.
    "stage" text NOT NULL,
    "scores" jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- 'ts:hybrid-llm:production@<paramsHash>' | 'sql:classify_thread_for_user' | 'user'
    "classifier" text NOT NULL,
    "llm_calls" int NOT NULL DEFAULT 0,
    "cache_hits" int NOT NULL DEFAULT 0,
    "budget_exhausted" boolean NOT NULL DEFAULT FALSE,
    "duration_ms" real,
    "created_at" timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE "public"."classification_decision" IS 'Append-only log of applied classification decisions (classifier stages, sql:applied trigger paths) and explicit user moves (stage=user_move). No FKs by design; not synced.';

CREATE INDEX classification_decision_user_thread_idx
    ON "public"."classification_decision" ("user_id", "thread_id", "created_at");
