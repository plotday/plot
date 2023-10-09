import { assert, expect, test } from "vitest";

import type { CalendarCredentials } from "../src/";
import { sync } from "../src/";

assert(process.env.GOOGLE_CLIENT_ID);
assert(process.env.GOOGLE_OAUTH_SECRET);
assert(process.env.MICROSOFT_CLIENT_ID);
assert(process.env.MICROSOFT_OAUTH_SECRET);
assert(process.env.TEST_GOOGLE_ACCOUNT_ACCESS_TOKEN);
assert(process.env.TEST_GOOGLE_ACCOUNT_REFRESH_TOKEN);
assert(process.env.TEST_OUTLOOK_ACCOUNT_ACCESS_TOKEN);
assert(process.env.TEST_OUTLOOK_ACCOUNT_REFRESH_TOKEN);

const config = {
  googleClientId: process.env.GOOGLE_CLIENT_ID,
  googleOauthSecret: process.env.GOOGLE_OAUTH_SECRET,
  outlookClientId: process.env.MICROSOFT_CLIENT_ID,
  outlookOauthSecret: process.env.MICROSOFT_OAUTH_SECRET,
};

const googleCreds: CalendarCredentials = {
  provider: "google",
  email: "plot.test.1@gmail.com",
  access_token: process.env.TEST_GOOGLE_ACCOUNT_ACCESS_TOKEN,
  refresh_token: process.env.TEST_GOOGLE_ACCOUNT_REFRESH_TOKEN,
  scopes: ["https://www.googleapis.com/auth/calendar.readonly"],
};

const outlookCreds: CalendarCredentials = {
  provider: "outlook",
  email: "adelev@wvcrw.onmicrosoft.com",
  access_token: process.env.TEST_OUTLOOK_ACCOUNT_ACCESS_TOKEN,
  refresh_token: process.env.TEST_OUTLOOK_ACCOUNT_REFRESH_TOKEN,
  scopes: [],
};

test("fetches Google events", async () => {
  const { events } = await sync(
    config,
    googleCreds,
    {
      calendarId: "primary",
      min: new Date("2023-01-03T00:00:00.000Z"),
      max: new Date("2023-01-05T00:00:00.000Z"),
    },
    10
  );
  expect(events.length).toBe(2);
});

test("fetches Outlook events", async () => {
  const { events } = await sync(
    config,
    outlookCreds,
    {
      calendarId: "primary",
      min: new Date("2023-07-10T00:00:00.000Z"),
      max: new Date("2023-07-12T00:00:00.000Z"),
    },
    10
  );
  expect(events.length).toBe(2);
});

test("Outlook recurring events are expanded", async () => {
  const { events } = await sync(config, outlookCreds, {
    calendarId: "primary",
    min: new Date("2023-09-15T00:00:00.000Z"),
    max: new Date("2023-09-22T00:00:00.000Z"),
  });
  expect(events.length).toBe(5);
  expect(events[3].data.subject).toBe("Cockadoodledoo");
});
