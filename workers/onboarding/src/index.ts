import { Agent } from "../../api/src";
import type { Priority } from "../../api/src/priority";

export default class extends Agent {
  async activate(priority: Priority) {
    await priority.createActivity({
      note: "Welcome to Plot!",
    });
  }
}
