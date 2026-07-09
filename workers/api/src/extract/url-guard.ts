/**
 * SSRF guard for the article-extraction pipeline.
 *
 * The `/app/extract` endpoint and the thread-creation hook both feed
 * user-controlled URLs into a server-side fetch (plain `fetch` plus Cloudflare
 * Browser Rendering). To keep users from pointing that fetch at internal or
 * reserved addresses, reject anything that isn't a public http(s) URL:
 * non-http(s) schemes, `localhost`, internal name suffixes, and private /
 * loopback / link-local / reserved IP literals.
 *
 * Limitations (accepted, bounded residual risk — the fetch runs on the
 * Cloudflare edge, which has no cloud-metadata endpoint and no private-network
 * reachability to our infrastructure):
 *  - A DNS name that resolves to a private IP is not caught (Workers can't
 *    cheaply resolve DNS before fetching).
 *  - This validates the INITIAL URL only. The fetch pipeline follows HTTP
 *    redirects and the Browser Rendering fallback follows in-page navigations
 *    without re-validating each hop, so a public URL that redirects to a
 *    private target is not blocked here. Tightening that (manual per-hop
 *    re-validation across both the fetch and browser paths) is a separate
 *    hardening pass.
 */
export function isPublicHttpUrl(rawUrl: string): boolean {
  let url: URL;
  try {
    url = new URL(rawUrl);
  } catch {
    return false;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return false;

  // Strip trailing FQDN dots ("localhost." / "localhost.." resolve like
  // "localhost") so they can't bypass the name checks below. IPv4/IPv6
  // literals never carry one.
  const host = url.hostname.toLowerCase().replace(/\.+$/, "");
  if (!host) return false;

  // Internal name suffixes.
  if (host === "localhost" || host.endsWith(".localhost")) return false;
  if (host.endsWith(".internal") || host.endsWith(".local")) return false;

  // IPv6 literal — URL.hostname keeps the surrounding brackets.
  if (host.startsWith("[") && host.endsWith("]")) {
    return isPublicIpv6(host.slice(1, -1));
  }

  // IPv4 literal.
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host)) {
    return isPublicIpv4(host);
  }

  // Bare DNS hostname — allowed.
  return true;
}

function isPublicIpv4(ip: string): boolean {
  const octets = ip.split(".").map((s) => Number(s));
  if (
    octets.length !== 4 ||
    octets.some((n) => !Number.isInteger(n) || n < 0 || n > 255)
  ) {
    return false;
  }
  const [a, b] = octets;
  if (a === 0) return false; // 0.0.0.0/8
  if (a === 10) return false; // 10.0.0.0/8 private
  if (a === 127) return false; // 127.0.0.0/8 loopback
  if (a === 169 && b === 254) return false; // 169.254.0.0/16 link-local (incl. metadata)
  if (a === 172 && b >= 16 && b <= 31) return false; // 172.16.0.0/12 private
  if (a === 192 && b === 168) return false; // 192.168.0.0/16 private
  if (a === 100 && b >= 64 && b <= 127) return false; // 100.64.0.0/10 CGNAT
  if (a >= 224) return false; // 224.0.0.0/3 multicast + reserved
  return true;
}

function isPublicIpv6(ip: string): boolean {
  const h = ip.toLowerCase();
  if (h === "::1" || h === "::") return false; // loopback / unspecified
  // IPv4-embedded: the mapped form (::ffff:a.b.c.d) AND the deprecated
  // IPv4-compatible form (::a.b.c.d). Both live in ::/96, which holds no public
  // address, so decode the trailing 32 bits and judge as IPv4. The `ffff:`
  // group is optional so the compatible form (e.g. ::169.254.169.254, which the
  // URL parser normalizes to ::a9fe:a9fe) is caught too. Dotted first
  // (defensive; the parser normally emits the hex form).
  const dotted = h.match(/^::(?:ffff:)?(\d{1,3}(?:\.\d{1,3}){3})$/);
  if (dotted) return isPublicIpv4(dotted[1]);
  const hex = h.match(/^::(?:ffff:)?([0-9a-f]{1,4}):([0-9a-f]{1,4})$/);
  if (hex) {
    const hi = parseInt(hex[1], 16);
    const lo = parseInt(hex[2], 16);
    return isPublicIpv4(
      `${(hi >> 8) & 0xff}.${hi & 0xff}.${(lo >> 8) & 0xff}.${lo & 0xff}`
    );
  }
  // fe80::/10 link-local (fe80–febf).
  if (h.startsWith("fe8") || h.startsWith("fe9") || h.startsWith("fea") || h.startsWith("feb")) {
    return false;
  }
  // fc00::/7 unique-local (fc00–fdff).
  if (h.startsWith("fc") || h.startsWith("fd")) return false;
  return true;
}
