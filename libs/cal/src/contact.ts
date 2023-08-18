export function normalizeName(name: string | undefined | null) {
  if (!name) return undefined;
  // Remove email address from name
  name = name.replace(/<?[^ ]+@[^ ]+>?/, "").trim();
  // Re-order Last, First to First Last
  name = name.replace(/^([^, ]+),\s*(.+)/, "$2 $1");
  return name;
}
