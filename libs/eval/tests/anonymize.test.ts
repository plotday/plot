import { describe, expect, it } from "vitest";

import {
  FREEMAIL_POOL,
  anonymizeDomain,
  anonymizeEmail,
  anonymizeName,
  anonymizePerson,
  anonymizeTopic,
  hashShort,
  scrubGroupName,
} from "../src/seeder/anonymize";
import { leakCheck } from "../src/seeder/leak-check";

describe("hashShort", () => {
  it("is deterministic and respects length", () => {
    expect(hashShort("kris@plot.day", 12)).toBe(hashShort("kris@plot.day", 12));
    expect(hashShort("kris@plot.day", 12)).toMatch(/^[0-9a-f]{12}$/);
    expect(hashShort("a")).not.toBe(hashShort("b"));
  });
});

describe("determinism", () => {
  it("same input gives same output across calls", () => {
    expect(anonymizeName("Anna Vendor")).toBe(anonymizeName("Anna Vendor"));
    expect(anonymizeEmail("anna@stripe.com")).toBe(anonymizeEmail("anna@stripe.com"));
    expect(anonymizeDomain("stripe.com")).toBe(anonymizeDomain("stripe.com"));
    expect(anonymizeTopic("channel:kris@plot.day")).toBe(
      anonymizeTopic("channel:kris@plot.day")
    );
  });
});

describe("anonymizeName", () => {
  it("maps a multi-token name to a realistic First Last", () => {
    const fake = anonymizeName("Anna Vendor");
    expect(fake).not.toBeNull();
    expect(fake).not.toBe("Anna Vendor");
    expect(fake).toMatch(/^[A-Z][a-z]+ [A-Z][a-z]+$/);
    expect(fake).not.toContain("Anna");
    expect(fake).not.toContain("Vendor");
  });

  it("maps a single-token name to a single fake token", () => {
    const fake = anonymizeName("Cher");
    expect(fake).not.toBeNull();
    expect(fake).toMatch(/^[A-Z][a-z]+$/);
    expect(fake).not.toBe("Cher");
  });

  it("passes null through", () => {
    expect(anonymizeName(null)).toBeNull();
  });
});

describe("anonymizeDomain", () => {
  it("is stable per input and distinguishes distinct org domains", () => {
    expect(anonymizeDomain("stripe.com")).toBe(anonymizeDomain("stripe.com"));
    // Not guaranteed for arbitrary pairs (pool is finite), but verified for
    // these two specific inputs when the pools were authored.
    expect(anonymizeDomain("stripe.com")).not.toBe(anonymizeDomain("shopify.com"));
  });

  it("produces fake-org .com domains for org inputs", () => {
    const fake = anonymizeDomain("stripe.com");
    expect(fake).toMatch(/^[a-z]+\.com$/);
    expect(FREEMAIL_POOL).not.toContain(fake);
  });

  it("maps freemail domains into the fixed freemail pool", () => {
    expect(FREEMAIL_POOL).toContain(anonymizeDomain("gmail.com"));
  });

  it("is case-insensitive for freemail detection and selection", () => {
    expect(anonymizeDomain("GMAIL.com")).toBe(anonymizeDomain("gmail.com"));
  });

  it("recognizes non-core freemail domains parsed from the SQL seed", () => {
    // web.de is in libs/db/schema/99-data/10-domains.sql but not in the
    // hard-coded fallback list, so this proves the SQL parse worked.
    expect(FREEMAIL_POOL).toContain(anonymizeDomain("web.de"));
  });

  it("treats subdomains as exact-match-only (like the SQL freemail check)", () => {
    // mail.google.com is not in the seed, so it is an org domain.
    expect(FREEMAIL_POOL).not.toContain(anonymizeDomain("mail.google.com"));
  });
});

describe("anonymizeEmail", () => {
  it("derives the local part from the anonymized name when provided", () => {
    const fakeName = anonymizeName("Anna Vendor")!;
    const fakeEmail = anonymizeEmail("anna@stripe.com", "Anna Vendor")!;
    const [local, domain] = fakeEmail.split("@");
    expect(local).toBe(fakeName.toLowerCase().replace(/ /g, "."));
    expect(domain).toBe(anonymizeDomain("stripe.com"));
  });

  it("falls back to a hash-derived local part without a name", () => {
    const fakeEmail = anonymizeEmail("anna@stripe.com")!;
    const [local] = fakeEmail.split("@");
    expect(local).toMatch(/^c-[0-9a-f]{12}$/);
    expect(local).not.toContain("anna");
  });

  it("preserves the domain class", () => {
    const free = anonymizeEmail("anna@gmail.com")!;
    expect(FREEMAIL_POOL).toContain(free.split("@")[1]);
    const org = anonymizeEmail("anna@stripe.com")!;
    expect(org.split("@")[1]).toBe(anonymizeDomain("stripe.com"));
  });

  it("passes null through", () => {
    expect(anonymizeEmail(null)).toBeNull();
    expect(anonymizeEmail(null, "Anna Vendor")).toBeNull();
  });

  it("treats a whitespace-only name as absent (hash-derived local part)", () => {
    // anonymizeName passes blank input through unchanged, which previously
    // collapsed the local part to "." — blank means no name.
    const fake = anonymizeEmail("anna@stripe.com", "   ")!;
    expect(fake).toBe(anonymizeEmail("anna@stripe.com"));
    expect(fake.split("@")[0]).toMatch(/^c-[0-9a-f]{12}$/);
  });
});

describe("anonymizePerson", () => {
  it("produces a coherent name+email pair", () => {
    const fake = anonymizePerson({ name: "Anna Vendor", email: "anna@stripe.com" });
    expect(fake.name).toBe(anonymizeName("Anna Vendor"));
    expect(fake.email!.split("@")[0]).toBe(fake.name!.toLowerCase().replace(/ /g, "."));
  });

  it("handles missing halves", () => {
    expect(anonymizePerson({ name: null, email: null })).toEqual({
      name: null,
      email: null,
    });
    const emailOnly = anonymizePerson({ name: null, email: "anna@stripe.com" });
    expect(emailOnly.name).toBeNull();
    expect(emailOnly.email).toBe(anonymizeEmail("anna@stripe.com"));
  });
});

describe("anonymizeTopic", () => {
  it("rewrites email-shaped substrings, preserving the prefix", () => {
    const out = anonymizeTopic("channel:kris@plot.day")!;
    expect(out.startsWith("channel:")).toBe(true);
    expect(out).toBe(`channel:${anonymizeEmail("kris@plot.day")}`);
    expect(out).not.toContain("kris@plot.day");
  });

  it("rewrites every email in a multi-email topic", () => {
    const out = anonymizeTopic("dm:anna@stripe.com,bob@gmail.com")!;
    expect(out).toBe(
      `dm:${anonymizeEmail("anna@stripe.com")},${anonymizeEmail("bob@gmail.com")}`
    );
    expect(out).not.toContain("anna@stripe.com");
    expect(out).not.toContain("bob@gmail.com");
  });

  it("replaces non-ASCII (IDN) emails with an opaque token instead of leaking", () => {
    // EMAIL_RE is ASCII-only, so without the fail-closed second pass this
    // address would survive verbatim.
    const out = anonymizeTopic("channel:anna@münchen.de")!;
    expect(out).toBe(`channel:c-${hashShort("anna@münchen.de", 12)}@redacted.example`);
    expect(out).not.toContain("münchen");
    expect(out).not.toContain("anna@");
  });

  it("leaves non-email topics unchanged", () => {
    expect(anonymizeTopic("priority:@plot.app")).toBe("priority:@plot.app");
    expect(anonymizeTopic("channel:12345")).toBe("channel:12345");
  });

  it("passes null through", () => {
    expect(anonymizeTopic(null)).toBeNull();
  });
});

describe("scrubGroupName", () => {
  it("replaces contact-name tokens, including partial-name token matches", () => {
    const contactNames = ["Anna Vendor", "Bob Smith"];
    const { scrubbed, replacedAny, residueTokens } = scrubGroupName(
      "Anna Vendor, Bob",
      contactNames
    );
    expect(replacedAny).toBe(true);
    expect(residueTokens).toEqual([]);
    for (const raw of ["Anna", "Vendor", "Bob"]) {
      expect(scrubbed).not.toContain(raw);
    }
    const fakeAnna = anonymizeName("Anna Vendor")!;
    const fakeBob = anonymizeName("Bob Smith")!;
    expect(scrubbed).toContain(fakeAnna.split(" ")[0]);
    expect(scrubbed).toContain(fakeBob.split(" ")[0]);
    // Structure (separators) preserved.
    expect(scrubbed).toContain(",");
  });

  it("is case-insensitive on the group name tokens", () => {
    const { scrubbed } = scrubGroupName("anna + bob", ["Anna Vendor", "Bob Smith"]);
    expect(scrubbed).not.toMatch(/anna|bob/i);
  });

  it("flags residue tokens that matched no contact token", () => {
    const { scrubbed, replacedAny, residueTokens } = scrubGroupName(
      "Anna Vendor fan club",
      ["Anna Vendor"]
    );
    expect(replacedAny).toBe(true);
    expect(residueTokens).toEqual(["fan", "club"]);
    expect(scrubbed).toContain("fan club");
  });

  it("reports replacedAny=false when nothing matched", () => {
    const { scrubbed, replacedAny, residueTokens } = scrubGroupName("Weekend plans", [
      "Anna Vendor",
    ]);
    expect(replacedAny).toBe(false);
    expect(scrubbed).toBe("Weekend plans");
    expect(residueTokens).toEqual(["Weekend", "plans"]);
  });
});

describe("leakCheck", () => {
  const pii = {
    emails: ["kris@plot.day", "anna@stripe.com"],
    names: ["Anna Vendor", "Re"],
    orgDomains: ["stripe.com", "gmail.com"],
  };

  it("flags raw emails outside title scope as violations with path+line", () => {
    const docs = [
      {
        path: "corpora/x/world.yaml",
        text: "contacts:\n  - email: kris@plot.day\n    name: ok\n",
      },
    ];
    const report = leakCheck(docs, pii);
    expect(report.violations).toHaveLength(1);
    expect(report.violations[0]).toMatchObject({
      path: "corpora/x/world.yaml",
      line: 2,
      kind: "email",
      value: "kris@plot.day",
    });
    expect(report.warnings).toHaveLength(0);
  });

  it("downgrades hits on title/gold_rationale/notes lines to warnings", () => {
    const docs = [
      {
        path: "corpora/x/cases.yaml",
        text: [
          "cases:",
          "  - title: Re kris@plot.day forwarded invoice",
          "    gold_rationale: mentions Anna Vendor explicitly",
          "    notes: stripe.com thread",
        ].join("\n"),
      },
    ];
    const report = leakCheck(docs, pii);
    expect(report.violations).toHaveLength(0);
    // The rationale line hits the full-name needle AND the per-token needles
    // ("anna", "vendor"), so name warnings appear more than once; assert on
    // the distinct kinds.
    expect(new Set(report.warnings.map((w) => w.kind))).toEqual(
      new Set(["domain", "email", "name"])
    );
    const titleHit = report.warnings.find((w) => w.kind === "email")!;
    expect(titleHit.line).toBe(2);
  });

  it("flags emails on folded-scalar continuation lines as violations (conservative)", () => {
    // Warn-scope detection is per-LINE by documented policy: `title: >-`
    // matches WARN_SCOPE_RE, but the folded scalar's continuation line does
    // not, so a raw email there is a hard violation rather than a warning.
    const docs = [
      {
        path: "a.yaml",
        text: "cases:\n  - title: >-\n      Fwd from kris@plot.day yesterday\n",
      },
    ];
    const report = leakCheck(docs, pii);
    expect(report.warnings).toHaveLength(0);
    expect(report.violations).toMatchObject([
      { kind: "email", value: "kris@plot.day", line: 3 },
    ]);
  });

  it("catches a lone leaked name token via per-token needles", () => {
    // scrubGroupName maps contact-name tokens split on WHITESPACE, so a
    // punctuated contact name like "Anna (Vendor)" keys "(vendor)" — the
    // bare "Vendor" token in a group name matches nothing and survives as
    // residue. The full-name needle "anna (vendor)" can't match that
    // residue either; only the per-token needle does.
    const contactName = "Anna (Vendor)";
    const { scrubbed, residueTokens } = scrubGroupName("Anna Vendor sync", [contactName]);
    expect(residueTokens).toContain("Vendor");
    expect(scrubbed).toContain("Vendor");
    const docs = [{ path: "a.yaml", text: `group_name: ${scrubbed}\n` }];
    const report = leakCheck(docs, { emails: [], names: [contactName], orgDomains: [] });
    // Token-needle hits are WARNING-grade (audit list), not violations:
    // service-named prod contacts ("Google", "Linear") make their tokens
    // match benign structural YAML, and violation-grade tokens would block
    // every extraction. Full-name matches stay violations.
    expect(report.warnings.some((v) => v.kind === "name" && v.value === "vendor")).toBe(
      true
    );
    expect(report.violations).toHaveLength(0);
  });

  it("flags org domains anywhere non-title as violations", () => {
    const docs = [{ path: "a.yaml", text: "topic: channel:foo@stripe.com\n" }];
    const report = leakCheck(docs, pii);
    expect(report.violations.some((v) => v.kind === "domain" && v.value === "stripe.com")).toBe(
      true
    );
  });

  it("does not flag freemail domains as domain leaks", () => {
    const docs = [{ path: "a.yaml", text: "email: someone-else@gmail.com\n" }];
    const report = leakCheck(docs, pii);
    expect(report.violations.filter((v) => v.kind === "domain")).toHaveLength(0);
    expect(report.warnings.filter((v) => v.kind === "domain")).toHaveLength(0);
  });

  it("matches names case-insensitively", () => {
    const docs = [{ path: "a.yaml", text: "group: ANNA VENDOR fan club\n" }];
    const report = leakCheck(docs, pii);
    expect(report.violations.some((v) => v.kind === "name")).toBe(true);
  });

  it("skips names shorter than 4 chars (false-positive guard)", () => {
    const docs = [{ path: "a.yaml", text: "subject: Re your message\n" }];
    const report = leakCheck(docs, pii);
    expect(report.violations).toHaveLength(0);
    expect(report.warnings).toHaveLength(0);
  });
});
