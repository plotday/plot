-- Global, server-only queue of "inject the extracted article for this URL into
-- this thread once ready" requests. Pairs with extracted_url (the URL->markdown
-- cache) so the Plot-authored article note is delivered when extraction
-- completes, even if that happens after the thread was created.
-- Server-only: not exposed via any user.* view, no seq, no archived_at — never
-- synced to clients (mirrors extracted_url).
CREATE TABLE "public"."extracted_url_injection" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "url_hash" text NOT NULL,
    "thread_id" uuid NOT NULL,
    "priority_id" uuid NOT NULL,
    "requested_by" uuid NOT NULL,
    "status" text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'fulfilled', 'skipped')),
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT "extracted_url_injection_thread_url_unique"
        UNIQUE ("thread_id", "url_hash")
);

CREATE INDEX "extracted_url_injection_url_hash_idx"
    ON "public"."extracted_url_injection" ("url_hash");
CREATE INDEX "extracted_url_injection_status_idx"
    ON "public"."extracted_url_injection" ("status");

CREATE TRIGGER set_extracted_url_injection_updated_at
    BEFORE INSERT OR UPDATE ON "public"."extracted_url_injection"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();
