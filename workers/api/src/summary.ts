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
      title: body.replaceAll(/\s+/g, " ").trim(),
    };
  }
  try {
    const messages = [
      {
        role: "system",
        content:
          "You name items in a productivity app. Create a short title for the user-provided action or note. Respond only with the title.",
      },
      {
        role: "user",
        content: body,
      },
    ];
    const response = await ai.run("@cf/meta/llama-3.3-70b-instruct-fp8-fast", {
      messages,
      max_tokens: 64,
    });
    if (response instanceof ReadableStream) {
      throw new Error("Response is a stream");
    }
    const json = {
      title: response.response,
    };
    return json;
  } catch (e) {
    console.error("Error summarizing text:", e);

    throw e;
  }
}
