import type { Priority, Activity } from "./priority";

export interface Agent {
  activate(priority: Priority, config: any): Promise<void>;

  activity(activity: Activity, priority: Priority, config: any): Promise<void>;
}