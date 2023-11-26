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
