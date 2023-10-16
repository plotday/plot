import { redirect } from "@remix-run/cloudflare";
import type { DataFunctionArgs } from "@remix-run/cloudflare";

import type { Tracker } from "@plotday/tracker";

import { getUser } from "app/auth";
import { createServerAdminClient, createServerClient } from "app/db";
import { getEnv } from "app/env.server";
import type { Sentry } from "app/sentry.server";

import type { Context } from "../server";

const augment = async ({ request, context }: DataFunctionArgs) => {
  const env = getEnv(context);
  const { supabase, response } = createServerClient(request, context);
  const supabaseAdmin = createServerAdminClient(context);
  const sentry = context.sentry as Sentry;
  const tracker = context.tracker as Tracker;
  let user = await getUser(supabase, tracker, sentry);
  let waitlistedUser = null;
  if (user && !user.activated_at) {
    waitlistedUser = user;
    user = null;
  }
  return {
    request,
    context: context as Context,
    env,
    user,
    waitlistedUser,
    response,
    supabase,
    supabaseAdmin,
    sentry,
    tracker,
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
        if (augmentedArgs.waitlistedUser.invitation) {
          throw redirect("/sync");
        } else {
          throw redirect("/waitlist");
        }
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
