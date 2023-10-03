import { redirect } from "@remix-run/cloudflare";
import type { DataFunctionArgs } from "@remix-run/cloudflare";

import { getUser } from "app/auth";
import { createServerAdminClient, createServerClient } from "app/db";
import { getEnv } from "app/env.server";

const augment = async ({ request, context }: DataFunctionArgs) => {
  const env = getEnv(context);
  const { supabase, response } = createServerClient(request, context);
  const supabaseAdmin = createServerAdminClient(context);
  let user = await getUser(supabase, env);
  let waitlistedUser = null;
  if (user && !user.activated_at) {
    waitlistedUser = user;
    user = null;
  }
  return {
    request,
    context,
    env,
    user,
    waitlistedUser,
    response,
    supabase,
    supabaseAdmin,
    sentry: env.sentry,
    tracker: env.tracker,
  };
};

export type AugmentedDataArgs = Awaited<ReturnType<typeof augment>>;

export type PrivateDataArgs = Omit<AugmentedDataArgs, "user"> & {
  user: NonNullable<AugmentedDataArgs["user"]>;
};

export function publicLoader<T>(
  func: (args: AugmentedDataArgs) => T
): (args: DataFunctionArgs) => Promise<T> {
  return async (args: DataFunctionArgs) => {
    const augmentedArgs = await augment(args);
    return func(augmentedArgs);
  };
}

export function privateLoader<T>(
  func: (args: PrivateDataArgs) => T
): (args: DataFunctionArgs) => Promise<T> {
  return async (args: DataFunctionArgs) => {
    const augmentedArgs = await augment(args);
    if (!augmentedArgs.user) {
      if (augmentedArgs.waitlistedUser) {
        throw redirect("/waitlist");
      } else {
        throw redirect("/login");
      }
    }
    return func(augmentedArgs as PrivateDataArgs);
  };
}

export function publicAction<T>(
  func: (args: AugmentedDataArgs) => T
): (args: DataFunctionArgs) => Promise<T> {
  return async (args: DataFunctionArgs) => {
    const augmentedArgs = await augment(args);
    return func(augmentedArgs);
  };
}

export function privateAction<T>(
  func: (args: PrivateDataArgs) => T
): (args: DataFunctionArgs) => Promise<T> {
  return async (args: DataFunctionArgs) => {
    const augmentedArgs = await augment(args);
    if (!augmentedArgs.user) {
      throw new Response("Unauthorized", { status: 401 });
    }
    return func(augmentedArgs as PrivateDataArgs);
  };
}
