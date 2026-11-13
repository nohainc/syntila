/**
 * Bun 1.4's multipart parser drops each part's Content-Type, so `File.type`
 * is empty. This parses with Bun, then restores part types from the headers.
 */
export async function parseMultipart(bytes: Uint8Array, contentType: string): Promise<FormData> {
  const form = await new Request("http://local/", { method: "POST", headers: { "content-type": contentType }, body: bytes }).formData();
  const boundary = /boundary=(?:"([^"]+)"|([^;]+))/i.exec(contentType);
  if (!boundary) return form;
  const marker = `--${boundary[1] ?? boundary[2]}`;
  const text = new TextDecoder("latin1").decode(bytes);
  const types = new Map<string, string>();
  for (const part of text.split(marker)) {
    const end = part.indexOf("\r\n\r\n");
    if (end < 0) continue;
    const head = part.slice(0, end);
    const name = /name="([^"]*)"/i.exec(head)?.[1];
    const type = /^content-type:\s*([^\r\n]+)/im.exec(head)?.[1]?.trim();
    if (name && type) types.set(name, type);
  }
  for (const [name, type] of types) {
    const value = form.get(name);
    if (value instanceof File && !value.type)
      form.set(name, new File([value], value.name, { type, lastModified: value.lastModified }));
  }
  return form;
}
