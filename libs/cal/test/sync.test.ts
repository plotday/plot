import { assert, expect, test } from "vitest";

import { sync } from "../src/";

test("fetches Google events", async () => {
  assert(process.env.GOOGLE_CLIENT_ID);
  assert(process.env.GOOGLE_OAUTH_SECRET);
  assert(process.env.MICROSOFT_CLIENT_ID);
  assert(process.env.MICROSOFT_OAUTH_SECRET);
  assert(process.env.TEST_GOOGLE_ACCOUNT_ACCESS_TOKEN);
  assert(process.env.TEST_GOOGLE_ACCOUNT_REFRESH_TOKEN);

  const { events } = await sync(
    {
      googleClientId: process.env.GOOGLE_CLIENT_ID,
      googleOauthSecret: process.env.GOOGLE_OAUTH_SECRET,
      outlookClientId: process.env.MICROSOFT_CLIENT_ID,
      outlookOauthSecret: process.env.MICROSOFT_OAUTH_SECRET,
    },
    {
      provider: "google",
      access_token: process.env.TEST_GOOGLE_ACCOUNT_ACCESS_TOKEN,
      refresh_token: process.env.TEST_GOOGLE_ACCOUNT_REFRESH_TOKEN,
    },
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
  assert(process.env.GOOGLE_CLIENT_ID);
  assert(process.env.GOOGLE_OAUTH_SECRET);
  assert(process.env.MICROSOFT_CLIENT_ID);
  assert(process.env.MICROSOFT_OAUTH_SECRET);
  assert(process.env.TEST_OUTLOOK_ACCOUNT_ACCESS_TOKEN);
  assert(process.env.TEST_OUTLOOK_ACCOUNT_REFRESH_TOKEN);

  const { events } = await sync(
    {
      googleClientId: process.env.GOOGLE_CLIENT_ID,
      googleOauthSecret: process.env.GOOGLE_OAUTH_SECRET,
      outlookClientId: process.env.MICROSOFT_CLIENT_ID,
      outlookOauthSecret: process.env.MICROSOFT_OAUTH_SECRET,
    },
    {
      provider: "outlook",
      access_token: process.env.TEST_OUTLOOK_ACCOUNT_ACCESS_TOKEN,
      refresh_token: process.env.TEST_OUTLOOK_ACCOUNT_REFRESH_TOKEN,
    },
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
  assert(process.env.GOOGLE_CLIENT_ID);
  assert(process.env.GOOGLE_OAUTH_SECRET);
  assert(process.env.MICROSOFT_CLIENT_ID);
  assert(process.env.MICROSOFT_OAUTH_SECRET);
  assert(process.env.TEST_OUTLOOK_ACCOUNT_ACCESS_TOKEN);
  assert(process.env.TEST_OUTLOOK_ACCOUNT_REFRESH_TOKEN);

  const { events } = await sync(
    {
      googleClientId: process.env.GOOGLE_CLIENT_ID,
      googleOauthSecret: process.env.GOOGLE_OAUTH_SECRET,
      outlookClientId: process.env.MICROSOFT_CLIENT_ID,
      outlookOauthSecret: process.env.MICROSOFT_OAUTH_SECRET,
    },
    {
      provider: "outlook",
      access_token: process.env.TEST_OUTLOOK_ACCOUNT_ACCESS_TOKEN,
      refresh_token: process.env.TEST_OUTLOOK_ACCOUNT_REFRESH_TOKEN,
    },
    {
      calendarId: "primary",
      min: new Date("2023-09-15T00:00:00.000Z"),
      max: new Date("2023-09-22T00:00:00.000Z"),
    }
  );
  expect(events.length).toBe(5);
  expect(events[3].data.subject).toBe("Cockadoodledoo");
});
