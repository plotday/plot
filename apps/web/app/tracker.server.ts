import { init } from "@plotday/tracker";

import { VERSION } from "app/config";
import type { Environment } from "app/env.server";

export const trackerInit = (
  context: { env: Environment },
  request: Request
) => {
  const key = (context.env as any)?.AMPLITUDE_API_KEY;
  if (!key) {
    console.log("No Amplitude API key found, skipping tracking");
  }
  return init(key, VERSION, request.headers);
};
