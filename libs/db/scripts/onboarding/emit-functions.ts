import type { ThreadDef } from "./model.ts";

function q(s: string): string {
  return s.replace(/'/g, "''");
}

/** Body between the schedules markers: the CASE table + the key guard. */
export function emitSchedulesRegion(global: ThreadDef[]): string {
  // No onboarding threads define schedule state — nothing to file for any
  // thread. Emit a valid no-op rather than an empty `IN ()` (a syntax error).
  if (global.length === 0) return "    RETURN NEW;";
  const keys = global.map((t) => `'${q(t.key)}'`).join(", ");
  const lines: string[] = [];
  lines.push(`    IF v_thread_key IN (${keys}) THEN`);
  lines.push("        CASE v_thread_key");
  for (const t of global) {
    const active = t.state.active ? "TRUE" : "FALSE";
    const importance = t.state.importance ?? 50;
    const dateOffset = t.state.dateOffset ?? 0;
    lines.push(
      `            WHEN '${q(t.key)}' THEN v_date_offset := ${dateOffset}; v_order := ${t.order * 100}; v_active := ${active}; v_importance := ${importance};`,
    );
  }
  lines.push("        END CASE;");
  lines.push("");
  lines.push("        INSERT INTO public.thread_state (user_id, thread_id, active, importance, \"order\", \"on\")");
  lines.push("        VALUES (NEW.user_id, NEW.thread_id, v_active, v_importance, v_order,");
  lines.push("            CASE WHEN v_date_offset = 0 THEN daterange('1970-01-01', NULL)");
  lines.push("                 ELSE daterange((CURRENT_DATE + v_date_offset), NULL) END)");
  lines.push("        ON CONFLICT (user_id, thread_id) DO NOTHING;");
  lines.push("    END IF;");
  return lines.join("\n");
}

/** Body between the todos markers: the key guard for threads that have a todo note. */
export function emitTodosRegion(global: ThreadDef[]): string {
  const todoKeys = global.filter((t) => t.notes.some((n) => n.key === "todo")).map((t) => `'${q(t.key)}'`);
  // No onboarding thread defines a todo note — there is nothing to file, so the
  // function is a no-op for every thread. Emit a valid `RETURN NEW;` rather than
  // an empty `IN ()`, which is a syntax error (PostgreSQL 42601).
  if (todoKeys.length === 0) return "    RETURN NEW;";
  const list = todoKeys.join(", ");
  return `    IF v_thread_key NOT IN (${list}) THEN\n        RETURN NEW;\n    END IF;`;
}

export function emitWelcomeUserRegion(thread: ThreadDef): string {
  const importance = thread.state.importance ?? 100;
  const lines: string[] = [];
  lines.push("        INSERT INTO public.thread (created_by, icon, title, preview, key, topic, contacts, groups)");
  lines.push("            VALUES (c_system_instance_id, CASE WHEN v_plot_twist_id IS NOT NULL THEN 'twist:' || v_plot_twist_id::text END,");
  lines.push(`                '${q(thread.title)}', '${q(thread.preview)}', '${q(thread.key)}', 'onboarding',`);
  lines.push("                ARRAY[c_system_instance_id] || (CASE WHEN v_user_contact_id IS NOT NULL THEN ARRAY[v_user_contact_id] ELSE ARRAY[]::uuid[] END),");
  lines.push("                ARRAY[v_plot_team_group_id])");
  lines.push("        RETURNING id INTO v_welcome_thread_id;");
  lines.push("        INSERT INTO public.thread_priority (thread_id, user_id, priority_id)");
  lines.push("            VALUES (v_welcome_thread_id, p_user_id, v_root_priority_id)");
  lines.push("        ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;");
  lines.push(`        INSERT INTO public.thread_state (user_id, thread_id, importance, "order", "on")`);
  lines.push(`            VALUES (p_user_id, v_welcome_thread_id, ${importance}, ${thread.order * 50}, daterange('1970-01-01', NULL))`);
  lines.push("        ON CONFLICT (user_id, thread_id) DO NOTHING;");
  thread.notes.forEach((n, i) => {
    lines.push("        INSERT INTO public.note (author_id, created_by, thread_id, source_created_at, content, key)");
    lines.push(`            VALUES (c_system_instance_id, c_system_instance_id, v_welcome_thread_id, now() + interval '${i} millisecond', '${q(n.content)}', '${q(n.key)}')`);
    lines.push("        ON CONFLICT (thread_id, link_id, key) WHERE key IS NOT NULL DO NOTHING;");
  });
  return lines.join("\n");
}

/** Replace text between `-- ONBOARDING:BEGIN <name>` and `-- ONBOARDING:END <name>`. */
export function replaceRegion(file: string, name: string, body: string): string {
  const begin = `-- ONBOARDING:BEGIN ${name}`;
  const end = `-- ONBOARDING:END ${name}`;
  const bi = file.indexOf(begin);
  const ei = file.indexOf(end);
  if (bi === -1 || ei === -1) throw new Error(`marker '${name}' not found`);
  const before = file.slice(0, bi + begin.length);
  const after = file.slice(ei);
  return `${before}\n${body}\n${after}`;
}
