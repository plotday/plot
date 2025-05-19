import * as Sentry from "@sentry/cloudflare";

import type {
  CalendarConfig,
  CalendarCredentials,
  ContactSyncState,
} from "@plotday/cal";
import { getContacts } from "@plotday/cal";
import type { SupabaseClient } from "@plotday/db";
import {
  createClient,
  getAccount,
  safeQuery,
  saveCredentials,
} from "@plotday/db";

export type ContactSyncRequest = {
  accountId: number;
  full?: boolean;
};

interface Env {
  readonly API_KEY: string;

  readonly SUPABASE_URL: string;
  readonly SUPABASE_SERVICE_KEY: string;
  readonly SENTRY_DSN: string;
  readonly GOOGLE_CLIENT_ID: string;
  readonly GOOGLE_OAUTH_SECRET: string;
  readonly MICROSOFT_CLIENT_ID: string;
  readonly MICROSOFT_OAUTH_SECRET: string;
}

async function runSync(
  env: Env,
  supabase: SupabaseClient,
  accountId: number,
  full: boolean = false
) {
  const calendarConfig: CalendarConfig = {
    googleClientId: env.GOOGLE_CLIENT_ID,
    googleOauthSecret: env.GOOGLE_OAUTH_SECRET,
    outlookClientId: env.MICROSOFT_CLIENT_ID,
    outlookOauthSecret: env.MICROSOFT_OAUTH_SECRET,
  };

  let account = await getAccount(supabase, accountId);
  let credentials = account.credentials as CalendarCredentials;

  let state: ContactSyncState = {
    state:
      !full && account.contact_sync_state
        ? JSON.stringify(account.contact_sync_state)
        : undefined,
  };
  do {
    let contacts;
    ({ state, credentials, contacts } = await getContacts(
      calendarConfig,
      credentials,
      state
    ));
    await saveCredentials(supabase, account.user_id, credentials, true);
    console.log(
      `Fetched ${contacts.length} contacts for ${account.id} (${
        state.more ? "more" : "no more"
      })`
    );

    safeQuery(
      await supabase.from("contact").upsert(
        contacts.map((contact) => ({
          user_id: account.user_id,
          name: contact.name,
          email: contact.email,
          avatar_url: contact.avatar,
        })),
        { onConflict: "user_id, email" }
      )
    );
  } while (state.more);

  // save sync state
  safeQuery(
    await supabase
      .from("account")
      .update({
        contact_sync_state: state.state ? JSON.parse(state.state) : null,
      })
      .match({ id: account.id })
  );
}

export default Sentry.withSentry(
  (env) => ({
    dsn: env.SENTRY_DSN,
    environment: ENV,
    release: RELEASE,
    dist: PACKAGE,
  }),
  {
    async queue(batch, env: Env): Promise<void> {
      const supabase = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);

      for (const m of batch.messages) {
        try {
          const message = m as Message<ContactSyncRequest>;
          const accountId = message.body.accountId;
          console.log(`Starting sync (${accountId})`);
          try {
            await runSync(env, supabase, accountId, !!message.body.full);
            console.log(`Sync complete (${accountId})`);
            message.ack();
          } catch (e) {
            console.error(e);
            Sentry.withScope((scope) => {
              scope.setExtra("account-id", accountId);
              Sentry.captureException(e);
            });
            message.retry();
          }
        } catch (e) {
          console.error(e);
          Sentry.captureException(e);
          // It's a failure, but it will never succeed because the parameters
          // are wrong.
          m.ack();
        }
      }
    },
  } satisfies ExportedHandler<Env>
);
