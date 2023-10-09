import { assert, expect, test } from "vitest";

import { getContacts } from "../src/";

test("fetches Google contacts", async () => {
  assert(process.env.GOOGLE_CLIENT_ID);
  assert(process.env.GOOGLE_OAUTH_SECRET);
  assert(process.env.MICROSOFT_CLIENT_ID);
  assert(process.env.MICROSOFT_OAUTH_SECRET);
  assert(process.env.TEST_GOOGLE_ACCOUNT_ACCESS_TOKEN);
  assert(process.env.TEST_GOOGLE_ACCOUNT_REFRESH_TOKEN);

  const config = {
    googleClientId: process.env.GOOGLE_CLIENT_ID,
    googleOauthSecret: process.env.GOOGLE_OAUTH_SECRET,
    outlookClientId: process.env.MICROSOFT_CLIENT_ID,
    outlookOauthSecret: process.env.MICROSOFT_OAUTH_SECRET,
  };

  let response = await getContacts(
    config,
    {
      provider: "google",
      email: "kris@plot.day",
      access_token: process.env.TEST_GOOGLE_ACCOUNT_ACCESS_TOKEN,
      refresh_token: process.env.TEST_GOOGLE_ACCOUNT_REFRESH_TOKEN,
      scopes: [
        "https://www.googleapis.com/auth/contacts.readonly",
        "https://www.googleapis.com/auth/contacts.other.readonly",
      ],
    },
    {}
  );
  expect(
    response.contacts.filter((c) => c.name === "Greg Papazian").length
  ).toBe(1);

  response = await getContacts(
    config,
    {
      provider: "google",
      email: "kris@plot.day",
      access_token: process.env.TEST_GOOGLE_ACCOUNT_ACCESS_TOKEN,
      refresh_token: process.env.TEST_GOOGLE_ACCOUNT_REFRESH_TOKEN,
      scopes: [
        "https://www.googleapis.com/auth/contacts.readonly",
        "https://www.googleapis.com/auth/contacts.other.readonly",
      ],
    },
    response.state
  );
  expect(response.state.more).toBe(false);
});
