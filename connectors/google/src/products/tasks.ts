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
  onEnable: async () => {
    throw new Error("Phase 3: tasks sync not yet re-homed");
  },
  onDisable: async () => {
    throw new Error("Phase 3: tasks sync not yet re-homed");
  },
};
