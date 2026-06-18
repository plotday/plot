import { sql, type Kysely } from "kysely";

import type { DB } from "../db-types";

/**
 * StoreKit IAP product IDs configured in App Store Connect. Same IDs
 * for iOS and Mac App Store — Apple treats them as a single auto-
 * renewable subscription across the user's Apple ID.
 */
export const IAP_PRODUCT_TO_PLAN: Record<string, "core" | "pro"> = {
  "day.plot.app.core_monthly": "core",
  "day.plot.app.pro_monthly": "pro",
};

/** Apple-issued bundle ID Apple's JWS payloads carry; must match
 *  what's bound to the App Store Connect product. */
export const APPLE_BUNDLE_ID = "day.plot.app";

/**
 * Apple Root CA - G3 SHA-256 fingerprint of the DER-encoded certificate
 * (lowercase hex, no separators).
 *
 * Source: https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
 * Subject: CN=Apple Root CA - G3, OU=Apple Certification Authority,
 *          O=Apple Inc., C=US
 * Algorithm: ECDSA P-384 with SHA-384
 * Validity:  2014-04-30 → 2039-04-30
 *
 * StoreKit 2 signed transactions and App Store Server Notifications V2
 * all anchor their x5c chains at this root. We pin its DER fingerprint
 * rather than trusting whatever root the request supplies — if Apple
 * ever publishes a successor before 2039, this constant must be updated
 * alongside the rollout.
 */
const APPLE_ROOT_CA_G3_FINGERPRINT_SHA256 =
  "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179";

export type JwsTransactionPayload = {
  transactionId: string;
  originalTransactionId: string;
  bundleId: string;
  productId: string;
  subscriptionGroupIdentifier?: string;
  purchaseDate: number;
  originalPurchaseDate: number;
  expiresDate?: number;
  type?: string;
  inAppOwnershipType?: string;
  environment?: "Production" | "Sandbox";
  revocationDate?: number;
  revocationReason?: number;
};

export type JwsRenewalInfoPayload = {
  originalTransactionId: string;
  autoRenewProductId?: string;
  autoRenewStatus?: 0 | 1;
  expirationIntent?: number;
  isInBillingRetryPeriod?: boolean;
  productId: string;
  recentSubscriptionStartDate?: number;
  signedDate?: number;
  environment?: "Production" | "Sandbox";
};

export type JwsNotificationPayload = {
  notificationType: string;
  subtype?: string;
  notificationUUID: string;
  data?: {
    appAppleId?: number;
    bundleId?: string;
    bundleVersion?: string;
    environment?: "Production" | "Sandbox";
    signedTransactionInfo?: string;
    signedRenewalInfo?: string;
    status?: number;
  };
  version: string;
  signedDate: number;
};

/**
 * Decode a JWS payload **without verifying the signature**. Diagnostic
 * and test use only — production code paths must use
 * {@link verifyAppleJws} so a forged or replayed payload can't reach the
 * subscription tables.
 */
export function decodeJws<T = unknown>(jws: string): T {
  const parts = jws.split(".");
  if (parts.length !== 3) {
    throw new Error("Invalid JWS: expected 3 dot-separated parts");
  }
  return JSON.parse(base64UrlToString(parts[1])) as T;
}

/**
 * Decode-only variant of {@link verifyTransaction} — does NOT verify
 * Apple's signature. Use {@link verifyTransaction} in any production
 * code path; this helper exists for tests and offline debugging.
 */
export function decodeTransaction(jws: string): JwsTransactionPayload {
  const payload = decodeJws<JwsTransactionPayload>(jws);
  if (payload.bundleId !== APPLE_BUNDLE_ID) {
    throw new Error(
      `Apple transaction bundleId mismatch: ${payload.bundleId} !== ${APPLE_BUNDLE_ID}`
    );
  }
  if (!IAP_PRODUCT_TO_PLAN[payload.productId]) {
    throw new Error(`Unknown Apple productId: ${payload.productId}`);
  }
  return payload;
}

// ===========================================================================
// JWS signature verification
// ===========================================================================
//
// Apple's signed payloads are compact-serialization JWS with `alg=ES256`
// and an `x5c` header carrying the signing certificate chain. The chain
// runs leaf (StoreKit/App Store Server signing cert, ECDSA P-256/SHA-256)
// → Apple Worldwide Developer Relations CA (P-384/SHA-384) → Apple Root
// CA - G3 (P-384/SHA-384). To trust a payload we:
//
//   1. Pin the chain's root by SHA-256 fingerprint of its DER bytes.
//   2. Confirm every cert in the chain is currently within its validity
//      window.
//   3. Verify each non-root cert's signature against the next cert's
//      public key (X.509 ECDSA signatures are DER-encoded; Web Crypto
//      wants IEEE P1363 — we convert).
//   4. Verify the JWS signature with the leaf cert's public key. JWS
//      signatures are already in P1363 form, so they go straight into
//      `crypto.subtle.verify`.
//
// Implemented inline with a minimal ASN.1 DER parser rather than a JOSE
// library — Cloudflare Workers ship Web Crypto but no JOSE primitives,
// and the surface we need (extract TBS, signature, SPKI, validity) is
// small.

// --- base64url + byte helpers ----------------------------------------------

function base64UrlToBytes(s: string): Uint8Array<ArrayBuffer> {
  // Accept both base64 (x5c entries per RFC 7515 §4.1.6) and base64url
  // (header/payload/signature) by normalizing the alphabet and padding.
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/");
  const padded = b64 + "=".repeat((4 - (b64.length % 4)) % 4);
  const bin = atob(padded);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function base64UrlToString(s: string): string {
  return new TextDecoder().decode(base64UrlToBytes(s));
}

async function sha256Hex(data: Uint8Array<ArrayBuffer>): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", data));
  let s = "";
  for (let i = 0; i < digest.length; i++) {
    s += digest[i].toString(16).padStart(2, "0");
  }
  return s;
}

// --- ASN.1 DER --------------------------------------------------------------

type Tlv = {
  /** Identifier (tag) octet at offset `start`. */
  tag: number;
  /** Offset of the tag byte. */
  start: number;
  /** Offset of the first content byte. */
  contentStart: number;
  /** Offset just past the last content byte (== just past the whole TLV). */
  end: number;
};

const ASN1_INTEGER = 0x02;
const ASN1_BIT_STRING = 0x03;
const ASN1_OID = 0x06;
const ASN1_UTC_TIME = 0x17;
const ASN1_GENERALIZED_TIME = 0x18;
const ASN1_SEQUENCE = 0x30;
const ASN1_CTX0 = 0xa0; // [0] EXPLICIT, constructed, context-specific

function parseTlv(data: Uint8Array<ArrayBuffer>, offset: number): Tlv {
  if (offset + 2 > data.length) throw new Error("ASN.1: truncated TLV");
  const tag = data[offset];
  const lenStart = offset + 1;
  const first = data[lenStart];
  let length: number;
  let contentStart: number;
  if ((first & 0x80) === 0) {
    length = first;
    contentStart = lenStart + 1;
  } else {
    const numLen = first & 0x7f;
    if (numLen === 0 || numLen > 4) {
      throw new Error("ASN.1: unsupported length encoding");
    }
    if (lenStart + 1 + numLen > data.length) {
      throw new Error("ASN.1: length runs past buffer");
    }
    length = 0;
    for (let i = 0; i < numLen; i++) {
      length = (length << 8) | data[lenStart + 1 + i];
    }
    contentStart = lenStart + 1 + numLen;
  }
  const end = contentStart + length;
  if (end > data.length) throw new Error("ASN.1: content runs past buffer");
  return { tag, start: offset, contentStart, end };
}

function childTlvs(data: Uint8Array<ArrayBuffer>, parent: Tlv): Tlv[] {
  const out: Tlv[] = [];
  let off = parent.contentStart;
  while (off < parent.end) {
    const tlv = parseTlv(data, off);
    out.push(tlv);
    off = tlv.end;
  }
  return out;
}

function readOid(data: Uint8Array<ArrayBuffer>, tlv: Tlv): string {
  if (tlv.tag !== ASN1_OID) throw new Error("ASN.1: expected OID");
  const bytes = data.subarray(tlv.contentStart, tlv.end);
  if (bytes.length === 0) throw new Error("ASN.1: empty OID");
  const parts: number[] = [Math.floor(bytes[0] / 40), bytes[0] % 40];
  let value = 0;
  for (let i = 1; i < bytes.length; i++) {
    value = (value << 7) | (bytes[i] & 0x7f);
    if ((bytes[i] & 0x80) === 0) {
      parts.push(value);
      value = 0;
    }
  }
  return parts.join(".");
}

function readAsn1Time(data: Uint8Array<ArrayBuffer>, tlv: Tlv): Date {
  const s = new TextDecoder().decode(data.subarray(tlv.contentStart, tlv.end));
  if (tlv.tag === ASN1_UTC_TIME) {
    const m = s.match(/^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/);
    if (!m) throw new Error("ASN.1: bad UTCTime");
    // RFC 5280: years < 50 are 20YY, otherwise 19YY.
    const yy = parseInt(m[1], 10);
    const year = yy < 50 ? 2000 + yy : 1900 + yy;
    return new Date(
      Date.UTC(year, parseInt(m[2], 10) - 1, +m[3], +m[4], +m[5], +m[6])
    );
  }
  if (tlv.tag === ASN1_GENERALIZED_TIME) {
    const m = s.match(/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/);
    if (!m) throw new Error("ASN.1: bad GeneralizedTime");
    return new Date(
      Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6])
    );
  }
  throw new Error(`ASN.1: unsupported time tag 0x${tlv.tag.toString(16)}`);
}

// --- X.509 ------------------------------------------------------------------

const OID_ECDSA_SHA256 = "1.2.840.10045.4.3.2";
const OID_ECDSA_SHA384 = "1.2.840.10045.4.3.3";
const OID_ECDSA_SHA512 = "1.2.840.10045.4.3.4";
const OID_P256 = "1.2.840.10045.3.1.7";
const OID_P384 = "1.3.132.0.34";

type EcdsaHash = "SHA-256" | "SHA-384" | "SHA-512";
function hashForSigOid(oid: string): EcdsaHash {
  switch (oid) {
    case OID_ECDSA_SHA256:
      return "SHA-256";
    case OID_ECDSA_SHA384:
      return "SHA-384";
    case OID_ECDSA_SHA512:
      return "SHA-512";
    default:
      throw new Error(`Unsupported ECDSA signature algorithm: ${oid}`);
  }
}

type EcCurve = "P-256" | "P-384";
function curveForOid(oid: string): { name: EcCurve; byteLen: number } {
  if (oid === OID_P256) return { name: "P-256", byteLen: 32 };
  if (oid === OID_P384) return { name: "P-384", byteLen: 48 };
  throw new Error(`Unsupported EC curve: ${oid}`);
}

type Cert = {
  /** Full DER bytes — used for fingerprint comparisons. */
  der: Uint8Array<ArrayBuffer>;
  /** TBSCertificate DER (including outer SEQUENCE tag + length). */
  tbsBytes: Uint8Array<ArrayBuffer>;
  /** signatureAlgorithm OID — picks the hash for verifying *this* cert. */
  signatureAlgorithmOid: string;
  /** signatureValue raw bytes (DER ECDSA-Sig-Value SEQUENCE). */
  signatureDer: Uint8Array<ArrayBuffer>;
  /** subjectPublicKeyInfo DER — pass directly to importKey("spki", ...). */
  spkiBytes: Uint8Array<ArrayBuffer>;
  /** EC curve OID of this cert's public key. */
  publicKeyCurveOid: string;
  notBefore: Date;
  notAfter: Date;
};

function parseCertificate(der: Uint8Array<ArrayBuffer>): Cert {
  const root = parseTlv(der, 0);
  if (root.tag !== ASN1_SEQUENCE) {
    throw new Error("X.509: outer element is not a SEQUENCE");
  }
  if (root.end !== der.length) {
    throw new Error("X.509: trailing data after Certificate");
  }
  const top = childTlvs(der, root);
  if (top.length !== 3) {
    throw new Error("X.509: expected 3 top-level Certificate fields");
  }
  const [tbsTlv, sigAlgTlv, sigValTlv] = top;

  const tbsBytes = der.subarray(tbsTlv.start, tbsTlv.end);

  const sigAlgChildren = childTlvs(der, sigAlgTlv);
  if (sigAlgChildren.length < 1) {
    throw new Error("X.509: malformed signatureAlgorithm");
  }
  const signatureAlgorithmOid = readOid(der, sigAlgChildren[0]);

  if (sigValTlv.tag !== ASN1_BIT_STRING) {
    throw new Error("X.509: signature value is not BIT STRING");
  }
  if (sigValTlv.end <= sigValTlv.contentStart) {
    throw new Error("X.509: empty signature BIT STRING");
  }
  if (der[sigValTlv.contentStart] !== 0) {
    throw new Error("X.509: non-zero unused-bits in signature BIT STRING");
  }
  const signatureDer = der.subarray(
    sigValTlv.contentStart + 1,
    sigValTlv.end
  );

  // TBSCertificate fields:
  //   [0] EXPLICIT version (optional, present for v3),
  //   serialNumber, signature, issuer, validity, subject,
  //   subjectPublicKeyInfo, ...
  const tc = childTlvs(der, tbsTlv);
  let i = 0;
  if (tc[i]?.tag === ASN1_CTX0) i++; // skip version
  i++; // serialNumber
  i++; // signature AlgorithmIdentifier (inside TBS)
  i++; // issuer
  const validityTlv = tc[i++];
  i++; // subject
  const spkiTlv = tc[i];
  if (!validityTlv || !spkiTlv || spkiTlv.tag !== ASN1_SEQUENCE) {
    throw new Error("X.509: malformed TBSCertificate");
  }

  const spkiBytes = der.slice(spkiTlv.start, spkiTlv.end);

  const validityChildren = childTlvs(der, validityTlv);
  if (validityChildren.length !== 2) {
    throw new Error("X.509: malformed Validity");
  }
  const notBefore = readAsn1Time(der, validityChildren[0]);
  const notAfter = readAsn1Time(der, validityChildren[1]);

  // SubjectPublicKeyInfo:
  //   SEQUENCE { algorithm AlgorithmIdentifier, subjectPublicKey BIT STRING }
  // For EC, AlgorithmIdentifier = SEQUENCE {
  //   1.2.840.10045.2.1 (id-ecPublicKey), namedCurveOid
  // }
  const spkiChildren = childTlvs(der, spkiTlv);
  if (spkiChildren.length < 2) {
    throw new Error("X.509: malformed SubjectPublicKeyInfo");
  }
  const algChildren = childTlvs(der, spkiChildren[0]);
  if (algChildren.length < 2 || algChildren[1].tag !== ASN1_OID) {
    throw new Error("X.509: SPKI is not EC public key with named curve");
  }
  const publicKeyCurveOid = readOid(der, algChildren[1]);

  return {
    der,
    tbsBytes,
    signatureAlgorithmOid,
    signatureDer,
    spkiBytes,
    publicKeyCurveOid,
    notBefore,
    notAfter,
  };
}

/**
 * Convert a DER-encoded ECDSA signature (SEQUENCE { r INTEGER, s INTEGER })
 * to raw IEEE P1363 (r ‖ s, each zero-padded to `componentLen` bytes).
 * Web Crypto's `verify({name:"ECDSA"}, ...)` expects P1363; X.509 cert
 * signatures use the DER form.
 */
function ecdsaDerToP1363(der: Uint8Array<ArrayBuffer>, componentLen: number): Uint8Array<ArrayBuffer> {
  const root = parseTlv(der, 0);
  if (root.tag !== ASN1_SEQUENCE) {
    throw new Error("ECDSA sig: outer element is not a SEQUENCE");
  }
  if (root.end !== der.length) throw new Error("ECDSA sig: trailing data");
  const parts = childTlvs(der, root);
  if (
    parts.length !== 2 ||
    parts[0].tag !== ASN1_INTEGER ||
    parts[1].tag !== ASN1_INTEGER
  ) {
    throw new Error("ECDSA sig: expected SEQUENCE of two INTEGERs");
  }
  const r = stripLeadingZeros(
    der.subarray(parts[0].contentStart, parts[0].end)
  );
  const s = stripLeadingZeros(
    der.subarray(parts[1].contentStart, parts[1].end)
  );
  if (r.length > componentLen || s.length > componentLen) {
    throw new Error("ECDSA sig: component too large for curve");
  }
  const out = new Uint8Array(componentLen * 2);
  out.set(r, componentLen - r.length);
  out.set(s, componentLen * 2 - s.length);
  return out;
}

function stripLeadingZeros(bytes: Uint8Array<ArrayBuffer>): Uint8Array<ArrayBuffer> {
  let i = 0;
  while (i < bytes.length - 1 && bytes[i] === 0x00) i++;
  return bytes.subarray(i);
}

// --- Top-level verifier ----------------------------------------------------

/**
 * Verify an Apple-issued JWS (StoreKit 2 signed transaction, signed
 * renewal info, or App Store Server Notification V2 `signedPayload`)
 * and return its decoded JSON payload.
 *
 * Throws if the JWS structure is bad, the algorithm is not ES256, the
 * x5c chain doesn't anchor at the pinned Apple Root CA G3 fingerprint,
 * any cert in the chain is outside its validity window, an intra-chain
 * signature fails, or the JWS's own signature does not verify against
 * the leaf cert's public key.
 */
export async function verifyAppleJws<T = unknown>(jws: string): Promise<T> {
  const parts = jws.split(".");
  if (parts.length !== 3) {
    throw new Error("Invalid JWS: expected 3 dot-separated parts");
  }
  const [headerB64, payloadB64, signatureB64] = parts;

  let header: { alg?: string; x5c?: string[] };
  try {
    header = JSON.parse(base64UrlToString(headerB64));
  } catch {
    throw new Error("Invalid JWS: header is not JSON");
  }
  if (header.alg !== "ES256") {
    throw new Error(`Unsupported JWS alg: ${header.alg}`);
  }
  if (!Array.isArray(header.x5c) || header.x5c.length === 0) {
    throw new Error("JWS header missing x5c certificate chain");
  }

  const chain = header.x5c.map((b64) =>
    parseCertificate(base64UrlToBytes(b64))
  );

  // 1. Pin the chain at Apple Root CA - G3 by SHA-256 of its DER bytes.
  const rootFingerprint = await sha256Hex(chain[chain.length - 1].der);
  if (rootFingerprint !== APPLE_ROOT_CA_G3_FINGERPRINT_SHA256) {
    throw new Error("JWS chain does not anchor at Apple Root CA - G3");
  }

  // 2. Every cert in the chain must be inside its validity window.
  const nowMs = Date.now();
  for (let i = 0; i < chain.length; i++) {
    const c = chain[i];
    if (nowMs < c.notBefore.getTime() || nowMs > c.notAfter.getTime()) {
      throw new Error(
        `JWS chain cert ${i} outside validity window: ` +
          `${c.notBefore.toISOString()} – ${c.notAfter.toISOString()}`
      );
    }
  }

  // 3. Walk the chain bottom-up; verify each cert's signature against
  //    its issuer's public key.
  for (let i = 0; i < chain.length - 1; i++) {
    const child = chain[i];
    const issuer = chain[i + 1];
    const hash = hashForSigOid(child.signatureAlgorithmOid);
    const curve = curveForOid(issuer.publicKeyCurveOid);
    const issuerKey = await crypto.subtle.importKey(
      "spki",
      issuer.spkiBytes,
      { name: "ECDSA", namedCurve: curve.name },
      false,
      ["verify"]
    );
    const sigRaw = ecdsaDerToP1363(child.signatureDer, curve.byteLen);
    const ok = await crypto.subtle.verify(
      { name: "ECDSA", hash },
      issuerKey,
      sigRaw,
      child.tbsBytes
    );
    if (!ok) {
      throw new Error(`JWS chain signature failed at cert ${i}`);
    }
  }

  // 4. Verify the JWS signature with the leaf cert's public key.
  //    ES256 ⇒ P-256 + SHA-256; JWS signatures are already IEEE P1363
  //    so they go straight into crypto.subtle.verify.
  const leaf = chain[0];
  if (leaf.publicKeyCurveOid !== OID_P256) {
    throw new Error(
      `JWS leaf cert is not on P-256 (curve OID ${leaf.publicKeyCurveOid})`
    );
  }
  const leafKey = await crypto.subtle.importKey(
    "spki",
    leaf.spkiBytes,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"]
  );
  const signedData = new TextEncoder().encode(`${headerB64}.${payloadB64}`);
  const signatureBytes = base64UrlToBytes(signatureB64);
  const sigOk = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    leafKey,
    signatureBytes,
    signedData
  );
  if (!sigOk) throw new Error("JWS signature verification failed");

  return JSON.parse(base64UrlToString(payloadB64)) as T;
}

/**
 * Verify a StoreKit 2 `signedTransaction` JWS *and* validate that its
 * payload's `bundleId` / `productId` match our app. Use this from any
 * production code path that ingests an Apple transaction.
 */
export async function verifyTransaction(
  jws: string
): Promise<JwsTransactionPayload> {
  const payload = await verifyAppleJws<JwsTransactionPayload>(jws);
  if (payload.bundleId !== APPLE_BUNDLE_ID) {
    throw new Error(
      `Apple transaction bundleId mismatch: ${payload.bundleId} !== ${APPLE_BUNDLE_ID}`
    );
  }
  if (!IAP_PRODUCT_TO_PLAN[payload.productId]) {
    throw new Error(`Unknown Apple productId: ${payload.productId}`);
  }
  return payload;
}

/**
 * Apply a verified Apple transaction to the user's subscription row.
 *
 * Semantics:
 *  - If a row already exists for this `userId`, it's updated in-place
 *    (we maintain one personal subscription per user).
 *  - `apple_original_transaction_id` is the stable cross-renewal ID;
 *    every row from the App Store carries the same value across the
 *    subscription's lifetime.
 *  - `billing_cycle_end` is set from Apple's `expiresDate`. The user is
 *    entitled to the paid plan as long as `expiresDate` is in the
 *    future, regardless of `status`.
 *  - Apple may report ownership types other than "PURCHASED" (e.g.
 *    "FAMILY_SHARED") — we honor entitlement regardless, per Apple's
 *    guidance.
 *  - When `revocationDate` is set, the user is downgraded to free
 *    immediately (refund or family-sharing removal).
 */
export async function applyAppleTransactionToUser(
  db: Kysely<DB>,
  userId: string,
  txn: JwsTransactionPayload
): Promise<{
  plan: "free" | "core" | "pro";
  expiresAt: Date | null;
  previous: {
    origin: string;
    status: string;
    plan: string;
    stripeSubscriptionId: string | null;
    stripeCustomerId: string | null;
  } | null;
}> {
  const plan = IAP_PRODUCT_TO_PLAN[txn.productId];
  if (!plan) {
    throw new Error(`Unsupported productId: ${txn.productId}`);
  }

  // Snapshot the prior row so the caller can reconcile (cancel) any Stripe sub.
  const prior = await db
    .selectFrom("user_subscription")
    .select([
      "origin",
      "status",
      "plan",
      "stripe_subscription_id",
      "stripe_customer_id",
    ])
    .where("user_id", "=", userId)
    .executeTakeFirst();
  const previous = prior
    ? {
        origin: prior.origin,
        status: prior.status,
        plan: prior.plan,
        stripeSubscriptionId: prior.stripe_subscription_id,
        stripeCustomerId: prior.stripe_customer_id,
      }
    : null;

  const now = new Date();
  const expiresAt = txn.expiresDate ? new Date(txn.expiresDate) : null;
  const isExpired = expiresAt !== null && expiresAt.getTime() < now.getTime();
  const isRevoked = txn.revocationDate != null;
  const isEntitled = !isExpired && !isRevoked;

  // billing_cycle_end is NOT NULL in schema — use expiresDate or fall back
  // to a 1-month window from purchaseDate so the constraint is satisfied
  // even for malformed/non-renewing transactions.
  const cycleStart = new Date(txn.purchaseDate);
  const cycleEnd =
    expiresAt ??
    new Date(cycleStart.getTime() + 30 * 24 * 60 * 60 * 1000);

  const targetPlan: "free" | "core" | "pro" = isEntitled ? plan : "free";
  const status = isEntitled ? "active" : "canceled";

  await db
    .insertInto("user_subscription")
    .values({
      user_id: userId,
      plan: targetPlan,
      status,
      origin: "app_store",
      apple_original_transaction_id: txn.originalTransactionId,
      apple_product_id: txn.productId,
      // Intentionally cleared on every Apple transaction (including DID_RENEW):
      // an app_store-origin row must never carry a live Stripe subscription ID.
      stripe_subscription_id: null,
      billing_cycle_start: cycleStart.toISOString(),
      billing_cycle_end: cycleEnd.toISOString(),
    })
    .onConflict((oc) =>
      oc.column("user_id").doUpdateSet({
        plan: targetPlan,
        status,
        origin: "app_store",
        apple_original_transaction_id: txn.originalTransactionId,
        apple_product_id: txn.productId,
        // Intentionally cleared on every Apple transaction (including DID_RENEW):
        // an app_store-origin row must never carry a live Stripe subscription ID.
        stripe_subscription_id: null,
        billing_cycle_start: cycleStart.toISOString(),
        billing_cycle_end: cycleEnd.toISOString(),
        updated_at: sql`now()`,
      })
    )
    .execute();

  return { plan: targetPlan, expiresAt, previous };
}

/**
 * Locate the Plot user owning a given Apple original_transaction_id.
 * Used by the App Store Server Notification webhook, which delivers
 * renewals/refunds without any session context — we have to map them
 * back to the user via the previously-stored originalTransactionId.
 */
export async function findUserByOriginalTransactionId(
  db: Kysely<DB>,
  originalTransactionId: string
): Promise<string | null> {
  const row = await db
    .selectFrom("user_subscription")
    .select("user_id")
    .where("apple_original_transaction_id", "=", originalTransactionId)
    .executeTakeFirst();
  return row?.user_id ?? null;
}
