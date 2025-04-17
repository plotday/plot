export async function summarize(ai: Ai, body: string) {
  body = body.trim();
  console.log(`SUM: ${body} (${body.length})`);
  if (body.length === 0) {
    return {
      title: "Empty",
    };
  }
  if (body.length < 40) {
    return {
      // TODO remove Markdown formatting
      title: body.replaceAll(/\s+/, " ").trim(),
    };
  }
  try {
    const response = await ai.run("@cf/meta/llama-4-scout-17b-16e-instruct", {
      prompt: `Generate a short title for the following item.
Include any details required to distinguish it from similar items.
Prefer the shortest title that is still likely to uniquely identify the item.

Item to title:

\`\`\`markdown
${body}
\`\`\`
`,
      guided_json: {
        type: "object",
        properties: {
          title: {
            type: "string",
          },
        },
      },
    });
    const text = typeof response === "string" ? response : response.response;
    const json = JSON.parse(text);
    return json;
  } catch (e) {
    console.error(e);
    throw e;
  }
}
