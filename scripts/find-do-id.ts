// Brute-force which orphan twist_instance_id maps to which Storage DO sqlite.
// We know DO names are derived as ${twistInstanceId}:${parentPath.join(':')}.
// For the LinkedInMessaging/Integrations tools the parent path is empty (the
// Storage namespace's idFromName is just the twistInstanceId), so the SHA-256
// of just the id matches the file name.

import { createHash } from "node:crypto";
import { readdirSync } from "node:fs";

const DO_DIR =
  "workers/api/.wrangler/state/v3/do/api-development-Storage";

// Candidate twist_instance_ids we know about — paste extras here.
const CANDIDATES = [
  "019e4079-d2b1-7196-b5fb-fb3362e9f489",
  "019e4072-95ea-7a6c-b600-8cce7d054aa3",
  "019e4064-2120-772e-bbe6-9881aab81296",
  "019e404e-ced0-7f93-b65a-fa82227ab56d",
  "019e3e0c-5dd1-7836-b247-50fa5c1b8549",
  "019e3dfd-dc5f-73d6-b456-b51427090cd7",
  "019e56b2-a57d-7abc-b4d8-709f1178fd89",
];

function hashesFor(name: string): string[] {
  // Try both bare and with ":Integrations" / common path suffixes.
  return [
    name,
    `${name}:`,
    `${name}:Integrations`,
  ].map((s) => createHash("sha256").update(s).digest("hex"));
}

const files = new Set(
  readdirSync(DO_DIR).map((f) => f.replace(".sqlite", ""))
);

for (const id of CANDIDATES) {
  for (const candidate of hashesFor(id)) {
    if (files.has(candidate)) {
      process.stdout.write(
        `MATCH ${id}  →  ${candidate}.sqlite (input: "${candidate === createHash("sha256").update(id).digest("hex") ? id : id + ":<suffix>"}")\n`
      );
    }
  }
}
process.stdout.write("\nDO files present:\n");
for (const f of files) process.stdout.write("  " + f + "\n");
