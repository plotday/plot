import { assert, expect, test } from "vitest";

import { getCalendars } from "../src/";

test("fetches Google calendars", async () => {
  assert(process.env.GOOGLE_CLIENT_ID);
  assert(process.env.GOOGLE_OAUTH_SECRET);
  assert(process.env.MICROSOFT_CLIENT_ID);
  assert(process.env.MICROSOFT_OAUTH_SECRET);
  assert(process.env.TEST_GOOGLE_ACCOUNT_ACCESS_TOKEN);
  assert(process.env.TEST_GOOGLE_ACCOUNT_REFRESH_TOKEN);

  const { calendars } = await getCalendars(
    {
      googleClientId: process.env.GOOGLE_CLIENT_ID,
      googleOauthSecret: process.env.GOOGLE_OAUTH_SECRET,
      outlookClientId: process.env.MICROSOFT_CLIENT_ID,
      outlookOauthSecret: process.env.MICROSOFT_OAUTH_SECRET,
    },
    {
      provider: "google",
      email: "kris@plot.day",
      access_token: process.env.TEST_GOOGLE_ACCOUNT_ACCESS_TOKEN,
      refresh_token: process.env.TEST_GOOGLE_ACCOUNT_REFRESH_TOKEN,
      scopes: ["https://www.googleapis.com/auth/calendar.readonly"],
    }
  );
  expect(calendars.length).toBe(4);
});
