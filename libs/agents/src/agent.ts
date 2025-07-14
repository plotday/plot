import type { Priority } from "./priority";

export interface Agent {
  activate(priority: Priority): Promise<void>;
}