/** Parse a pending invite entry that may be `"Name <email>"` or a bare email. */
export function parseInviteAddress(raw: string): { email: string; name?: string } {
  const m = raw.match(/^(.*)<([^>]+)>$/);
  if (m) {
    const email = m[2].trim().toLowerCase();
    let name = m[1].trim();
    if (name.length >= 2 && name.startsWith('"') && name.endsWith('"')) {
      name = name.slice(1, -1).trim();
    }
    return name ? { email, name } : { email };
  }
  return { email: raw.trim().toLowerCase() };
}
