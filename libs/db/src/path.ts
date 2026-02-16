export function urlToPath(url: string) {
  return url.replaceAll("/", ".").replaceAll("-", "_");
}

export function pathToUrl(path: string) {
  return `/@/${path.replaceAll(".", "/").replaceAll("_", "-")}`;
}

export function nameToPath(name: string) {
  return name
    .replace(/[^a-zA-Z0-9]/g, "_")
    .replace(/_+/g, "_")
    .toLowerCase();
}
