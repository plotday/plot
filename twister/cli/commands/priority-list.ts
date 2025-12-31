import { handleNetworkError } from "../utils/network-error";
import { getToken } from "../utils/token";

interface PriorityListOptions {
  apiUrl: string;
}

export async function priorityListCommand(options: PriorityListOptions) {
  // Get authentication token
  const token = await getToken();
  if (!token) {
    console.error(
      "\n✗ No authentication token found. Please run 'plot login' first."
    );
    process.exit(1);
  }

  // Make API request
  try {
    const apiResponse = await fetch(`${options.apiUrl}/v1/priorities`, {
      method: "GET",
      headers: {
        Authorization: `Bearer ${token}`,
      },
    });

    if (!apiResponse.ok) {
      const errorText = await apiResponse.text();
      console.error(
        `\n✗ Failed to fetch priorities: ${apiResponse.status} ${apiResponse.statusText}`
      );
      console.error(errorText);
      process.exit(1);
    }

    const priorities = (await apiResponse.json()) as any[];

    if (priorities.length === 0) {
      console.log("No priorities found.");
      return;
    }

    // Display priorities in a table format
    console.log(`${"ID".padEnd(38)} ${"Parent ID".padEnd(38)} Title`);
    console.log("-".repeat(120));

    for (const priority of priorities) {
      const id = priority.id || "";
      const parentId = priority.parentId || "(root)";
      const title = priority.title || "";

      console.log(`${id.padEnd(38)} ${parentId.padEnd(38)} ${title}`);
    }

    console.log(
      `\nTotal: ${priorities.length} ${
        priorities.length === 1 ? "priority" : "priorities"
      }`
    );
  } catch (error) {
    const errorInfo = handleNetworkError(error);
    console.error("\n✗ Failed to fetch priorities:", errorInfo.message);
    if (errorInfo.details) {
      console.error(errorInfo.details);
    }
    process.exit(1);
  }
}
