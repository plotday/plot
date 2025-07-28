#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

// Get the agents directory path
const agentsDir = path.join(__dirname, "../../../libs/agents");
const agentsPath = path.join(agentsDir, "agents");
const toolsPath = path.join(agentsDir, "tools");
const buildDir = path.join(__dirname, "../build");

// Ensure build directory exists
if (!fs.existsSync(buildDir)) {
  fs.mkdirSync(buildDir, { recursive: true });
}

// Function to read JSON file safely
function readJsonFile(filePath) {
  try {
    const content = fs.readFileSync(filePath, "utf8");
    return JSON.parse(content);
  } catch (error) {
    console.warn(`Could not read ${filePath}:`, error.message);
    return null;
  }
}

// Function to find all agent.json files
function findAgentFiles() {
  const agents = [];
  if (!fs.existsSync(agentsPath)) {
    console.warn(`Agents directory not found: ${agentsPath}`);
    return agents;
  }

  const agentDirs = fs
    .readdirSync(agentsPath, { withFileTypes: true })
    .filter((dirent) => dirent.isDirectory())
    .map((dirent) => dirent.name);

  for (const agentDir of agentDirs) {
    const agentJsonPath = path.join(agentsPath, agentDir, "agent.json");
    const agentData = readJsonFile(agentJsonPath);
    if (agentData) {
      agents.push(agentData);
    }
  }

  return agents;
}

// Function to find all tool.json files
function findToolFiles() {
  const tools = {};
  if (!fs.existsSync(toolsPath)) {
    console.warn(`Tools directory not found: ${toolsPath}`);
    return tools;
  }

  const toolDirs = fs
    .readdirSync(toolsPath, { withFileTypes: true })
    .filter((dirent) => dirent.isDirectory())
    .map((dirent) => dirent.name);

  for (const toolDir of toolDirs) {
    const toolJsonPath = path.join(toolsPath, toolDir, "tool.json");
    const toolData = readJsonFile(toolJsonPath);
    if (toolData) {
      tools[toolData.id] = toolData;
    }
  }

  return tools;
}

// Function to build tools array with dependencies
function buildToolsArray(agentTools, allTools) {
  const result = [];
  const toolsToAdd = new Map(); // toolName -> Set of requiredBy names (or null for direct)

  function collectTool(toolName, requiredBy = null) {
    const tool = allTools[toolName];
    if (!tool) {
      console.warn(`Tool '${toolName}' not found`);
      return;
    }

    // Initialize set for this tool if not exists
    if (!toolsToAdd.has(toolName)) {
      toolsToAdd.set(toolName, new Set());
    }

    // Add who requires this tool
    if (requiredBy) {
      toolsToAdd.get(toolName).add(requiredBy);
    } else {
      toolsToAdd.get(toolName).add(null); // Direct requirement
    }

    // Process tool dependencies
    if (tool.tools && Array.isArray(tool.tools)) {
      for (const depTool of tool.tools) {
        collectTool(depTool, toolName);
      }
    }
  }

  // Collect all tools and their requirements
  if (agentTools && Array.isArray(agentTools)) {
    for (const toolName of agentTools) {
      collectTool(toolName);
    }
  }

  // Convert to result array
  for (const [toolName, requiredBySet] of toolsToAdd) {
    // Check if this tool is only required by other tools (not directly by the agent)
    const directlyRequired = requiredBySet.has(null);

    if (directlyRequired) {
      // Tool is directly required by the agent
      result.push({ id: toolName });
    } else {
      // Tool is only required by other tools, pick the first one as the "tool" field
      const requiredBy = [...requiredBySet][0];
      result.push({ id: toolName, tool: requiredBy });
    }
  }

  return result;
}

// Function to escape SQL strings
function escapeSqlString(str) {
  if (str === null || str === undefined) {
    return "NULL";
  }
  return `'${str.replace(/'/g, "''")}'`;
}

// Function to generate SQL for an agent
function generateAgentSql(agent, allTools) {
  const toolsArray = buildToolsArray(agent.tools, allTools);

  const values = [
    escapeSqlString(agent.id),
    escapeSqlString(agent.name),
    escapeSqlString(agent.description || null),
    escapeSqlString(agent.author?.name || null),
    escapeSqlString(agent.author?.email || null),
    escapeSqlString(agent.author?.url || null),
    `'${JSON.stringify(toolsArray)}'::jsonb`,
  ];

  return `
INSERT INTO public.agent (id, name, description, author_name, author_email, author_url, tools)
VALUES (${values.join(", ")})
ON CONFLICT (id) 
DO UPDATE SET
  name = EXCLUDED.name,
  description = EXCLUDED.description,
  author_name = EXCLUDED.author_name,
  author_email = EXCLUDED.author_email,
  author_url = EXCLUDED.author_url,
  tools = EXCLUDED.tools,
  updated_at = now();`;
}

// Main function
function main() {
  console.log("Generating agents SQL...");

  const agents = findAgentFiles();
  const tools = findToolFiles();

  console.log(
    `Found ${agents.length} agents and ${Object.keys(tools).length} tools`
  );

  if (agents.length === 0) {
    console.warn("No agents found, creating empty SQL file");
  }

  const sqlStatements = agents.map((agent) => generateAgentSql(agent, tools));

  const sqlContent = `-- Generated SQL for agent table
-- This file is auto-generated by the gen-sql script
-- Do not edit manually

${sqlStatements.join("\n\n")}
`;

  const outputPath = path.join(buildDir, "agents.sql");
  fs.writeFileSync(outputPath, sqlContent);

  console.log(`SQL generated successfully: ${outputPath}`);
  console.log("Agents processed:");
  agents.forEach((agent) => {
    console.log(`  - ${agent.id}: ${agent.tools?.join(", ") || "no tools"}`);
  });
}

// Run the script
if (require.main === module) {
  main();
}

module.exports = { main, buildToolsArray, findAgentFiles, findToolFiles };

