import {
  privateAction as _privateAction,
  privateLoader as _privateLoader,
  publicAction as _publicAction,
  publicLoader as _publicLoader,
} from "app/util.server";

function noop() {
  return null;
}

export const publicLoader = _publicLoader ?? noop;
export const privateLoader = _privateLoader ?? noop;
export const publicAction = _publicAction ?? noop;
export const privateAction = _privateAction ?? noop;

export function urlToPath(url: string) {
  return url.replaceAll("-", "_").replaceAll(":", ".");
}

export function pathToUrl(path: string) {
  const parts = path.replaceAll("_", "-").split(".");
  return "/+" + [parts[0], parts.slice(1).join(":")].join("/");
}

export function nameToPath(name: string) {
  return name
    .replace(/[^a-zA-Z0-9]/g, "_")
    .replace(/_+/g, "_")
    .toLowerCase();
}
