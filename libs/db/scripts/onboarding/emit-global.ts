import type { OnboardingModel } from "./model.ts";

export interface ArchiveSets {
  archivedThreadKeys: string[];
  archivedNoteKeys: string[]; // "threadKey/noteKey"
}

/** Postgres single-quote escape for a SQL string literal body. */
function q(s: string): string {
  return s.replace(/'/g, "''");
}

// Identity/attribution constants — these match how the live global onboarding
// threads are created (system Plot twist instance, routed via the @plot.updates
// auto-maintained announce topic, no groups, contacts = [system instance]).
const SYSTEM_INSTANCE_ID = "0199b6f4-ae64-7718-0000-000000000001";
const TWIST_PACKAGE_ID = "0199b6f4-ae64-7718-8a02-44716f30358f";
const UPDATES_TOPIC_KEY = "@plot.updates";

export function emitGlobalReconcile(model: OnboardingModel, archive: ArchiveSets): string {
  const out: string[] = [];
  out.push("-- Global onboarding thread + note content reconcile (affects all users).");
  out.push("-- Threads are authored by the system Plot twist instance and routed via the");
  out.push("-- @plot.updates auto-maintained announce topic (the @plot.updates topic is how");
  out.push("-- every user receives them — file_thread_priority_for_topic_members files them).");
  out.push("DO $$");
  out.push("DECLARE");
  out.push(`    c_system_instance_id CONSTANT uuid := '${SYSTEM_INSTANCE_ID}';`);
  out.push(`    c_twist_package_id CONSTANT uuid := '${TWIST_PACKAGE_ID}';`);
  out.push("    v_plot_twist_id bigint;");
  out.push("    v_updates_topic_id uuid;");
  out.push("    v_thread_id uuid;");
  out.push("    v_note_id uuid;");
  out.push("BEGIN");
  out.push("    SELECT id INTO v_plot_twist_id FROM public.twist");
  out.push("        WHERE twist_package_id = c_twist_package_id AND environment = 'public' LIMIT 1;");
  out.push(`    SELECT id INTO v_updates_topic_id FROM public.topic`);
  out.push(`        WHERE key = '${UPDATES_TOPIC_KEY}' AND auto_maintained = TRUE AND team_id IS NULL LIMIT 1;`);
  out.push("    -- Atlas-robust: skip on fresh DBs where the system twist / topic isn't seeded yet.");
  out.push("    IF v_plot_twist_id IS NULL OR v_updates_topic_id IS NULL THEN RETURN; END IF;");

  for (const t of model.global) {
    out.push("");
    out.push(`    -- ${t.key}`);
    out.push(`    SELECT id INTO v_thread_id FROM public.thread`);
    out.push(`        WHERE key = '${q(t.key)}' AND created_by = c_system_instance_id AND archived_at IS NULL LIMIT 1;`);
    out.push("    IF v_thread_id IS NULL THEN");
    out.push("        -- topic_id (not just the topic text) is what file_thread_priority_for_topic_members");
    out.push("        -- keys on — without it new users never get the thread filed / never see it.");
    out.push("        INSERT INTO public.thread (created_by, twist_id, icon, title, preview, key, topic_id, topic, contacts)");
    out.push(`            VALUES (c_system_instance_id, v_plot_twist_id, 'twist:' || v_plot_twist_id::text,`);
    out.push(`                '${q(t.title)}', '${q(t.preview)}', '${q(t.key)}', v_updates_topic_id, 'topic:' || v_updates_topic_id::text,`);
    out.push("                ARRAY[c_system_instance_id])");
    out.push("        RETURNING id INTO v_thread_id;");
    out.push("    ELSE");
    out.push(`        UPDATE public.thread SET title = '${q(t.title)}', preview = '${q(t.preview)}',`);
    out.push("                topic_id = v_updates_topic_id, topic = 'topic:' || v_updates_topic_id::text");
    out.push("            WHERE id = v_thread_id");
    out.push(`              AND (title, preview, topic_id) IS DISTINCT FROM ('${q(t.title)}', '${q(t.preview)}', v_updates_topic_id);`);
    out.push("    END IF;");
    t.notes.forEach((n, i) => {
      // Manual upsert by (thread_id, key): these notes have link_id IS NULL, and
      // note_thread_link_key_unique is NULLS-distinct, so ON CONFLICT can't match
      // a NULL link_id and would insert duplicates on re-run. Match explicitly.
      out.push(`    SELECT id INTO v_note_id FROM public.note`);
      out.push(`        WHERE thread_id = v_thread_id AND key = '${q(n.key)}' AND link_id IS NULL AND archived_at IS NULL LIMIT 1;`);
      out.push("    IF v_note_id IS NULL THEN");
      out.push(`        INSERT INTO public.note (author_id, created_by, thread_id, source_created_at, content, key)`);
      out.push(`            VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (${i} * interval '1 minute'), '${q(n.content)}', '${q(n.key)}');`);
      out.push("    ELSE");
      out.push(`        UPDATE public.note SET content = '${q(n.content)}'`);
      out.push(`            WHERE id = v_note_id AND content IS DISTINCT FROM '${q(n.content)}';`);
      out.push("    END IF;");
    });
  }

  for (const key of archive.archivedThreadKeys) {
    out.push("");
    out.push(`    UPDATE public.thread`);
    out.push(`        SET archived_at = now()`);
    out.push(`        WHERE key = '${q(key)}' AND created_by = c_system_instance_id AND archived_at IS NULL;`);
  }
  for (const compound of archive.archivedNoteKeys) {
    const [threadKey, noteKey] = compound.split("/");
    out.push("");
    out.push(`    UPDATE public.note n SET archived_at = now()`);
    out.push(`        FROM public.thread t`);
    out.push(`        WHERE t.id = n.thread_id AND t.key = '${q(threadKey)}' AND t.created_by = c_system_instance_id`);
    out.push(`          AND n.key = '${q(noteKey)}' AND n.archived_at IS NULL;`);
  }

  out.push("END $$;");
  out.push("");
  return out.join("\n");
}
