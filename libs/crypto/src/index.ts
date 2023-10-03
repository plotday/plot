export async function sign(str: string, key: Uint8Array): Promise<string> {
  const encoder = new TextEncoder();

  const importedKey = await crypto.subtle.importKey(
    "raw",
    key,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"]
  );

  const mac = await crypto.subtle.sign(
    "HMAC",
    importedKey,
    encoder.encode(str)
  );

  // `mac` is an ArrayBuffer, so you need to make a few changes to get
  // it into a ByteString, and then a Base64-encoded string.
  let base64Mac = btoa(String.fromCharCode(...new Uint8Array(mac)));

  // must convert "+" to "-" as urls encode "+" as " "
  base64Mac = base64Mac.replaceAll("+", "-");

  return base64Mac;
}

export async function signUrl(url: URL, key: Uint8Array): Promise<URL> {
  const code = await sign(url.toString(), key);
  const newUrl = new URL(url);
  newUrl.searchParams.append("code", code);
  return newUrl;
}

export async function verifyUrl(url: URL, key: Uint8Array): Promise<boolean> {
  const code = url.searchParams.get("code");
  const urlWithoutCode = new URL(url);
  urlWithoutCode.searchParams.delete("code");
  const expectedCode = await sign(urlWithoutCode.toString(), key);
  return code === expectedCode;
}
