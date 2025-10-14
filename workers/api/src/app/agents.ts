import { Hono } from "hono";
import { z } from "zod";

import { agentFactory, createTools } from "../agent";
import {
  add as addAgent,
  deleteAgent,
  getById as getAgentById,
  getByPriority as getAgentsByPriority,
  getAll as getAllAgents,
  update as updateAgent,
} from "../agent/management";
import type { Bindings } from "../env";
import { handleValidationError } from "../utils/validation";

const agents = new Hono<{ Bindings: Bindings }>();

// Schemas
const AgentRequestSchema = z.object({
  priorityId: z.string(),
  agentId: z.string(),
  agentEnvironment: z
    .enum(["personal", "private", "review"])
    .optional()
    .default("personal"),
  name: z.string().optional(),
  config: z.record(z.string(), z.any()).optional(),
});

const AgentUpdateRequestSchema = z.object({
  agent: z.record(z.string(), z.any()),
});

// GET /agents - List all agents accessible to user for a priority
agents.get("/agents", async (c) => {
  const priorityId = c.req.query("priorityId");
  if (!priorityId) {
    return new Response("Bad request (missing priorityId)", { status: 400 });
  }

  const agents = await getAllAgents(c.var.supabase, priorityId);
  return c.json(agents);
});

// GET /agent/:id - Get agent by ID
agents.get("/agent/:id", async (c) => {
  const agentId = c.req.param("id");
  const agents = await getAgentById(c.var.supabase, agentId);
  return c.json(agents);
});

// GET /agent - Get agents by priority
agents.get("/agent", async (c) => {
  const priorityId = c.req.query("priorityId");
  if (!priorityId) {
    return new Response("Bad request (missing priorityId)", { status: 400 });
  }
  const agents = await getAgentsByPriority(c.var.supabase, priorityId);
  return c.json(agents);
});

// POST /agent - Add agent to priority
agents.post("/agent", async (c) => {
  const rawBody = await c.req.json();
  const parseResult = AgentRequestSchema.safeParse(rawBody);
  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }
  const body = parseResult.data;
  try {
    const dbPriorityAgent = await addAgent(
      c.var.supabase,
      c.var.supabaseAdmin,
      body.priorityId,
      body.agentId,
      body.agentEnvironment,
      body.name,
      body.config,
      {
        env: c.env,
        agentFactory: agentFactory(c.env),
        createTools,
      }
    );
    return c.json(dbPriorityAgent.id);
  } catch (error) {
    console.error("Error adding agent:", error);
    if (error instanceof Error) {
      console.warn(error.stack);
      return new Response(`Error adding agent: ${error.message}`, {
        status: 400,
      });
    }
    throw error;
  }
});

// PATCH /agent/:id - Update agent
agents.patch("/agent/:id", async (c) => {
  const agentId = c.req.param("id");
  const rawBody = await c.req.json();
  const parseResult = AgentUpdateRequestSchema.safeParse(rawBody);
  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }
  const body = parseResult.data;
  try {
    const dbAgent = await updateAgent(c.var.supabase, agentId, body.agent);
    return c.json(dbAgent);
  } catch (error) {
    if (error instanceof Error) {
      return new Response(`Error updating agent: ${error.message}`, {
        status: 400,
      });
    }
    throw error;
  }
});

// DELETE /agent/:id - Delete agent
agents.delete("/agent/:id", async (c) => {
  const agentId = c.req.param("id");
  await deleteAgent(c.var.supabase, agentId);
  return c.json({ success: true });
});

export default agents;
