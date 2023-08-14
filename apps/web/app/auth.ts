import type { Session, SupabaseClient } from "@supabase/supabase-js";

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
  const url = new URL(request.url);
  if (url.searchParams.has("error")) {
    if (url.searchParams.get("error_description")) {
      throw Error(url.searchParams.get("error_description") as string);
    } else {
      throw Error(`Auth provider error (${url.searchParams.get("error")})`);
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

export const signInWithGoogle = async (
  supabase: SupabaseClient,
  redirectTo: string,
  additionalScopes?: string[]
) => {
  await supabase.auth.signInWithOAuth({
    provider: "google",
    options: {
      redirectTo,
      scopes: (additionalScopes || []).join(" "),
      queryParams: {
        access_type: additionalScopes ? "offline" : "online",
        prompt: (additionalScopes ? ["select_account", "consent"] : []).join(
          " "
        ),
      },
    },
  });
};

export async function signInWithAzure(
  supabase: SupabaseClient,
  redirectTo: string,
  additionalScopes?: string[]
) {
  await supabase.auth.signInWithOAuth({
    provider: "azure",
    options: {
      redirectTo,
      scopes: ["openid", "email", "user.read"]
        .concat(additionalScopes || [])
        .join(" "),
    },
  });
}

export const logout = async (supabase: SupabaseClient) => {
  await supabase.auth.signOut();
};

export const getUserId = async (
  supabase: SupabaseClient,
  session?: Session
) => {
  session =
    session || (await supabase.auth.getSession()).data.session || undefined;
  if (!session) {
    return null;
  }
  return session.user?.id;
};

export const getUser = async (supabase: SupabaseClient, session?: Session) => {
  const userId = await getUserId(supabase, session);
  if (!userId) {
    return null;
  }

  // Typescript somehow confuses this as returning an array rather than an object,
  // so we need to specify the type explicitly
  return (safeQuery(
    await supabase
      .from("account")
      .select("user( id, email, name, timezone )")
      .eq("auth_user_id", userId)
      .maybeSingle()
  )?.user || null) as {
    id: number;
    email: string;
    name: string;
    timezone: string | null;
  } | null;
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
