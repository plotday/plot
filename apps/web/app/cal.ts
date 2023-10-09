import type { CalendarConfig } from "@plotday/cal";

import type { Environment } from "app/env.server";

export * from "@plotday/cal";
export { getCredentials } from "@plotday/db";

export function getCalendarConfig(env: Environment) {
  const calendarConfig: CalendarConfig = {
    googleClientId: env.GOOGLE_CLIENT_ID,
    googleOauthSecret: env.GOOGLE_OAUTH_SECRET,
    outlookClientId: env.MICROSOFT_CLIENT_ID,
    outlookOauthSecret: env.MICROSOFT_OAUTH_SECRET,
  };
  return calendarConfig;
}
