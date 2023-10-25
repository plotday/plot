import { useId } from "react";

import { Turnstile as BaseTurnstile } from "@marsidev/react-turnstile";

import type { Environment } from "app/env.server";
import { useEnv } from "app/hooks";

export async function validateTurnstile(
  request: Request,
  body: FormData,
  env: Environment
) {
  // Turnstile injects a token in "cf-turnstile-response".
  const token = body.get("cf-turnstile-response");
  const ip = request.headers.get("CF-Connecting-IP") ?? "127.0.0.1";
  if (!token) {
    return false;
  }
  if (!ip) {
    return false;
  }

  let formData = new FormData();
  formData.append("secret", env.TURNSTILE_SECRET_KEY);
  formData.append("response", token);
  formData.append("remoteip", ip);

  const url = "https://challenges.cloudflare.com/turnstile/v0/siteverify";
  const result = await fetch(url, {
    body: formData,
    method: "POST",
  });

  const outcome = await result.json();
  return (outcome as any)?.success;
}

export function Turnstile() {
  const id = useId();
  let env = useEnv();
  const key = env?.TURNSTILE_SITE_KEY;
  if (!key) return null;
  return (
    <BaseTurnstile id={id} siteKey={key} options={{ size: "invisible" }} />
  );
}
