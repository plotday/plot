import { Agent } from "../../api/src";
import type { Priority } from "../../api/src/priority";

export default class extends Agent {
  async fetch(_request: Request): Promise<Response> {
    return new Response("OK", { status: 200 });
  }

  async activate(priority: Priority) {
    await priority.createActivity({
      note: "Welcome to Plot!",
    });
  }
}
