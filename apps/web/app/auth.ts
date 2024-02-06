import type {
  Provider,
  Session,
  SupabaseClient,
  User,
} from "@supabase/supabase-js";

import { jsonFetch as fetch } from "@worker-tools/json-fetch";

import type { CalendarProvider } from "@plotday/cal";
import type { Tracker } from "@plotday/tracker";

import { safeQuery } from "app/db";
import type { Sentry } from "app/sentry.server";

// Process an Oauth callback and create a session
//
// NOTE: The session is not set for the current request, so functions that rely
// on getting the session or using RLS will fail. Use the returned session or
// redirect to a new request.
export const completeSignIn = async (
  request: Request,
  supabase: SupabaseClient
) => {
  // Supabase appends an extra query string
  const url = new URL(request.url.replace("&%3F", "&"));
  if (url.searchParams.has("error")) {
    if (url.searchParams.get("error_description")) {
      throw Error(url.searchParams.get("error_description") as string);
    } else {
      throw Error(`Calendar provider error (${url.searchParams.get("error")})`);
    }
  }
  const code = url.searchParams.get("code");
  if (typeof code !== "string") throw Error("Missing auth code");

  const { data, error } = await supabase.auth.exchangeCodeForSession(code);
  if (error) throw error;

  const session = data?.session;
  if (!session) {
    throw Error("No session");
  }

  await supabase.auth.setSession(session);

  return session;
};

export const signIn = async (
  supabase: SupabaseClient,
  provider: CalendarProvider,
  callbackUrl: string,
  redirectUrl?: string,
  additionalScopes?: string[],
  additionalParams?: Record<string, string>
) => {
  let supabaseProvider: Provider;
  switch (provider) {
    case "google":
      supabaseProvider = "google";
      break;
    case "outlook":
      supabaseProvider = "azure";
      break;
  }

  const currentUrl = `${location.pathname}${location.search}`;
  redirectUrl ??= currentUrl;
  const params = new URLSearchParams({
    from: currentUrl,
    to: redirectUrl,
  });
  if (additionalParams) {
    for (const [key, value] of Object.entries(additionalParams)) {
      params.append(key, value);
    }
  }
  // Supabase appends an extra query string, so we append a & to avoid
  // concatenating with the last param
  const redirectTo = `${location.origin}${callbackUrl}?${params}&`;

  let baseScopes = [] as string[];
  let providerParams = [] as Record<string, any>;
  switch (provider) {
    case "outlook":
      baseScopes = ["openid", "email", "user.read"];
      break;
    case "google":
      baseScopes = [
        "openid",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
      ];
      providerParams = {
        access_type: additionalScopes ? "offline" : "online",
        prompt: (additionalScopes ? ["select_account", "consent"] : []).join(
          " "
        ),
      };
      break;
  }

  await supabase.auth.signInWithOAuth({
    provider: supabaseProvider,
    options: {
      redirectTo,
      scopes: baseScopes.concat(additionalScopes || []).join(" "),
      queryParams: providerParams,
    },
  });
};

export const logout = async (supabase: SupabaseClient) => {
  await supabase.auth.signOut();
};

export const getUser = async (
  supabase: SupabaseClient,
  tracker: Tracker,
  sentry: Sentry,
  session?: Session,
  defaultTimezone: string = "America/New_York"
) => {
  session ??= (await supabase.auth.getSession()).data.session || undefined;
  if (!session) {
    return null;
  }
  const user = session.user;

  sentry.setUser({
    id: user.id.toString(),
    ...(user.email ? { email: user.email } : {}),
  });

  tracker.identify(user.id.toString());

  return {
    ...user,
    email: user.email!,
    timezone: user.app_metadata?.timezone ?? defaultTimezone,
  };
};

export const getUserMetadata = async (session: Session) => {
  const provider =
    session.user?.app_metadata?.provider === "google"
      ? "google"
      : ("outlook" as CalendarProvider);
  let scopes = [];
  if (provider === "google") {
    const response = await fetch(
      `https://www.googleapis.com/oauth2/v1/tokeninfo?access_token=${session.provider_token}`,
      {
        method: "GET",
      }
    );
    const body = await response.json();
    scopes = (body as any)?.scope?.split(" ") ?? [];
  }
  return {
    id: session.user?.id,
    provider,
    email: session.user?.user_metadata?.email?.toLowerCase() || null,
    name: session.user?.user_metadata?.name || null,
    avatar: session.user?.user_metadata?.avatar_url || null,
    credentials: {
      access_token: session.provider_token,
      refresh_token: session.provider_refresh_token,
      scopes,
    },
  };
};

export async function addAccount(
  user: User | null,
  session: Session,
  tracker: Tracker,
  supabaseAdmin: SupabaseClient
) {
  let {
    id: authUserId,
    name,
    email,
    avatar,
    provider,
    credentials,
  } = await getUserMetadata(session);

  if (!user) {
    user = safeQuery(
      await supabaseAdmin
        .from("user")
        .upsert(
          {
            name,
            email,
            avatar_url: avatar,
          },
          { onConflict: "email" }
        )
        .select()
        .single()
    );
    if (!user) {
      throw Error("Failed to create user");
    }
    tracker.identify(user.id.toString(), {
      Email: email,
      Name: name,
    });
    tracker.accountWaitlisted(user.id.toString());
  }

  if (credentials.refresh_token) {
    tracker.accountAdded(user.id.toString(), {
      Provider: provider,
      Scopes: credentials.scopes,
    });
  }

  const account = safeQuery(
    await supabaseAdmin
      .from("account")
      .upsert(
        {
          user_id: user.id,
          auth_user_id: authUserId,
          email,
          provider,
          ...(credentials.refresh_token ? { credentials } : {}),
        },
        { onConflict: "auth_user_id" }
      )
      .select()
      .single()
  );
  if (!account) {
    throw Error("Failed to create account");
  }

  // Create or link a contact for the user
  safeQuery(
    await supabaseAdmin.from("contact").upsert(
      {
        user_id: user.id,
        email: email,
        name: name ?? user.user_metadata.name,
        avatar_url: avatar ?? user.user_metadata.avatar_url,
        contact_user_id: user.id,
      },
      { onConflict: "user_id,email" }
    )
  );

  return { user, account };
}

export async function redeemInvitation(
  user: User,
  invitation: string,
  tracker: Tracker,
  supabaseAdmin: SupabaseClient
) {
  if (user.app_metadata.invitation) return;
  safeQuery(
    await supabaseAdmin.rpc("redeem_invitation", {
      _user_id: user.id,
      _invitation: invitation,
    })
  );
  tracker.accountActivated(user.id.toString(), {
    "Invitation Code": invitation,
  });
}

export async function getAccounts(supabase: SupabaseClient, userId: string) {
  return safeQuery(
    await supabase
      .from("account")
      .select("id,provider,email")
      .eq("user_id", userId)
      .not("credentials", "is", "null")
  );
}
