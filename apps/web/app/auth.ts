import type { Provider, Session, SupabaseClient } from "@supabase/supabase-js";

import { jsonFetch as fetch } from "@worker-tools/json-fetch";

import type { CalendarProvider } from "@plotday/cal";

import type { Database } from "app/db";
import { safeQuery } from "app/db";
import type { Environment } from "app/env.server";

export type User = Database["public"]["Tables"]["user"]["Row"];

export const authCookieOptions = {
  name: "pa",
  maxAge: 60 * 60 * 24 * 365, // 1 year
  sameSite: false,
  secure: false,
  domain: "",
  path: "/",
};

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

export const getAuthUserId = async (
  supabase: SupabaseClient,
  session?: Session
) => {
  session ??= (await supabase.auth.getSession()).data.session || undefined;
  if (!session) {
    return null;
  }
  return session.user?.id;
};

export const getUser = async (
  supabase: SupabaseClient,
  env: Environment,
  session?: Session
) => {
  const userId = await getAuthUserId(supabase, session);
  if (!userId) {
    return null;
  }

  const user = safeQuery(
    await supabase
      .from("account")
      .select("user(id, email, name, timezone, activated_at)")
      .eq("auth_user_id", userId)
      .maybeSingle()
    // Typescript somehow confuses this as returning an array rather than an object,
    // so we need to specify the type explicitly
  )?.user as any as User | null;
  if (!user) return null;

  env.sentry.setUser({
    id: user.id.toString(),
    ...(user.email ? { email: user.email } : {}),
  });

  env.tracker.identify(user.id.toString());

  return user;
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
  env: Environment,
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
    env.tracker.identify(user.id.toString(), {
      Email: email,
      Name: name,
    });
    env.tracker.accountWaitlisted(user.id.toString());
  }

  if (credentials.refresh_token) {
    env.tracker.accountAdded(user.id.toString(), {
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

  return { user, account };
}

export async function activateAccount(
  user: User,
  invitation: string,
  env: Environment,
  supabaseAdmin: SupabaseClient
) {
  if (user.activated_at) return;
  safeQuery(
    await supabaseAdmin.rpc("redeem_invitation", {
      _user_id: user.id,
      _invitation: invitation,
    })
  );
  env.tracker.accountActivated(user.id.toString(), {
    "Invitation Code": invitation,
  });
  // Create or link a contact for the user
  safeQuery(
    await supabaseAdmin.from("contact").upsert(
      {
        email: user.email,
        name: user.name,
        user_id: user.id,
        contact_user_id: user.id,
      },
      { onConflict: "user_id,email" }
    )
  );
}

export async function getAccounts(supabase: SupabaseClient, userId: number) {
  return safeQuery(
    await supabase
      .from("account")
      .select("id,provider,email")
      .eq("user_id", userId)
      .not("credentials", "is", "null")
  );
}
