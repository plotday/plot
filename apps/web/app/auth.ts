import type { Provider, Session, SupabaseClient } from "@supabase/supabase-js";

import type { CalendarProvider } from "@plotday/cal";

import { safeQuery } from "./db";

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
// NOTE: The session is not set for the current request, so functions get rely
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

export const isSignedIn = async (
  supabase: SupabaseClient,
  session?: Session
) => {
  const user = await getUser(supabase, session);
  return !!user?.invitation;
};

export const getUser = async (supabase: SupabaseClient, session?: Session) => {
  const userId = await getAuthUserId(supabase, session);
  if (!userId) {
    return null;
  }

  const user = safeQuery(
    await supabase
      .from("account")
      .select("user( id, email, name, timezone, invitation )")
      .eq("auth_user_id", userId)
      .maybeSingle()
  )?.user;
  if (!user) return null;

  // Typescript somehow confuses this as returning an array rather than an object,
  // so we need to specify the type explicitly
  return user as any as {
    id: number;
    email: string;
    name: string | null;
    timezone: string | null;
    invitation: string | null;
  };
};

export const getUserMetadata = async (session: Session) => {
  return {
    id: session.user?.id,
    provider:
      session.user?.app_metadata?.provider === "google" ? "google" : "outlook",
    email: session.user?.user_metadata?.email?.toLowerCase() || null,
    name: session.user?.user_metadata?.name || null,
    avatar: session.user?.user_metadata?.avatar_url || null,
    credentials: {
      access_token: session.provider_token,
      refresh_token: session.provider_refresh_token,
    },
  };
};
