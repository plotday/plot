export function quickHash(str: string) {
  let hash = 0x811c9dc5;
  for (let i = 0; i < str.length; ++i) {
    hash ^= str.charCodeAt(i);
    hash = (hash * 0x01000193) >>> 0;
  }
  return hash.toString(16).padStart(8, "0");
}
