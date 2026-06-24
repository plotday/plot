import {
  getTasksChannels,
  TASKS_SCOPE,
  TASKS_LINK_TYPES,
} from "@plotday/connector-google-tasks";
import type { Product } from "./product";

export const tasksProduct: Product = {
  key: "tasks",
  requiredScopes: [TASKS_SCOPE],
  linkTypes: TASKS_LINK_TYPES,
  getRawChannels: (token) => getTasksChannels(token),
  // Tasks' lifecycle is handled directly by the Google class (it owns
  // scheduling + the tasks: key namespace), so onChannelEnabled/Disabled
  // intercept the `tasks` product before these are reached — mirroring Calendar.
  onEnable: async () => {
    throw new Error(
      "Tasks onEnable must be handled directly by Google.onChannelEnabled"
    );
  },
  onDisable: async () => {
    throw new Error(
      "Tasks onDisable must be handled directly by Google.onChannelDisabled"
    );
  },
};
