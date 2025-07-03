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
    const response = await ai.run("@cf/facebook/bart-large-cnn", {
      input_text: body,
      max_length: 80,
    });
    const json = {
      title: response.summary
    }
    return json;
  } catch (e) {
    console.error(e);
    throw e;
  }
}
