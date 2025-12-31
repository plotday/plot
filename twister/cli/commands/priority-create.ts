import prompts from "prompts";
import { handleNetworkError } from "../utils/network-error";
import * as out from "../utils/output";
import { getToken } from "../utils/token";

interface PriorityCreateOptions {
  name?: string;
  parentId?: string;
  apiUrl: string;
}

export async function priorityCreateCommand(options: PriorityCreateOptions) {
  out.progress("Creating a new priority...");
  out.blank();

  // Get name and parentId if not provided
  const response = await prompts([
    {
      type: options.name ? null : "text",
      name: "name",
      message: "Priority name:",
      validate: (value: string) => value.length > 0 || "Name is required",
    },
    {
      type: options.parentId ? null : "text",
      name: "parentId",
      message: "Parent priority ID (leave empty for root):",
      validate: (value: string) =>
        !value ||
        /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
          value
        ) ||
        "Must be a valid UUID or empty",
    },
  ]);

  if (Object.keys(response).length === 0) {
    out.plain("\nCancelled.");
    process.exit(0);
  }

  const name = options.name || response.name;
  const parentId = options.parentId || response.parentId || undefined;

  // Get authentication token
  const token = await getToken();
  if (!token) {
    out.error(
      "No authentication token found",
      "Please run 'plot login' first"
    );
    process.exit(1);
  }

  // Make API request
  try {
    const apiResponse = await fetch(`${options.apiUrl}/v1/priority`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        title: name,
        parentId: parentId,
      }),
    });

    if (!apiResponse.ok) {
      const errorText = await apiResponse.text();
      out.error(
        `Priority creation failed: ${apiResponse.status} ${apiResponse.statusText}`,
        errorText
      );
      process.exit(1);
    }

    const result = (await apiResponse.json()) as any;
    out.success(
      `Priority "${result.title}" created`,
      parentId ? [out.colors.dim(`Under parent: ${parentId}`)] : undefined
    );
    out.blank();
  } catch (error) {
    const errorInfo = handleNetworkError(error);
    out.error("Priority creation failed", errorInfo.message);
    if (errorInfo.details) {
      console.error(out.colors.dim(errorInfo.details));
    }
    process.exit(1);
  }
}
