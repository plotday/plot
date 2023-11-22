import type { Provider, Session, SupabaseClient } from "@supabase/supabase-js";

import { jsonFetch as fetch } from "@worker-tools/json-fetch";

import type { CalendarProvider } from "@plotday/cal";
import type { Tracker } from "@plotday/tracker";

import type { Database } from "app/db";
import { safeQuery } from "app/db";
import type { Sentry } from "app/sentry.server";

export type User = Database["public"]["Tables"]["user"]["Row"];

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
  tracker: Tracker,
  sentry: Sentry,
  session?: Session,
  defaultTimezone: string = "America/New_York"
) => {
  const userId = await getAuthUserId(supabase, session);
  if (!userId) {
    return null;
  }

  const user = safeQuery(
    await supabase
      .from("account")
      .select(
        "user(id, email, name, avatar_url, timezone, invitation, activated_at)"
      )
      .eq("auth_user_id", userId)
      .maybeSingle()
    // Typescript somehow confuses this as returning an array rather than an object,
    // so we need to specify the type explicitly
  )?.user as any as User | null;
  if (!user) return null;

  sentry.setUser({
    id: user.id.toString(),
    ...(user.email ? { email: user.email } : {}),
  });

  tracker.identify(user.id.toString());

  if (!user.timezone) {
    user.timezone = defaultTimezone;
  }

  return {
    ...user,
    timezone: user.timezone ?? defaultTimezone,
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
        name: name ?? user.name,
        avatar_url: avatar ?? user.avatar_url,
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
  if (user.activated_at) {
    const categories = safeQuery(
      await supabaseAdmin.from("category").select("path").eq("user_id", user.id)
    );
    const path = categories.filter((c) => c.path.indexOf(".") === -1)?.[0]
      ?.path;
    if (path) {
      return `/+${path}`;
    } else {
      return "/";
    }
  }
  safeQuery(
    await supabaseAdmin.rpc("redeem_invitation", {
      _user_id: user.id,
      _invitation: invitation,
    })
  );
  tracker.accountActivated(user.id.toString(), {
    "Invitation Code": invitation,
  });
  const userDomain = safeQuery(
    await supabaseAdmin
      .from("user")
      .select("domain(domain,organization(name))")
      .eq("id", user.id)
      .single()
  );
  let root = "personal";
  let name = "Personal";
  let domain = (userDomain.domain as any)?.domain as string | undefined;
  if (domain) {
    let lastDotIndex = domain.lastIndexOf(".");
    if (lastDotIndex !== -1) {
      domain = domain.substring(0, lastDotIndex);
    }
    root = domain.replaceAll(".", "-");
    name =
      ((userDomain.domain as any)?.organization?.name as string | undefined) ??
      "Work";
  }
  safeQuery(
    await supabaseAdmin
      .from("category")
      .upsert([
        {
          user_id: user.id,
          name,
          path: root,
        },
        {
          user_id: user.id,
          name: "Meetings",
          path: `${root}.meetings`,
        },
      ])
      .select()
  );
  return `/+${root}`;
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
