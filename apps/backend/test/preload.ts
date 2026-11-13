// Shared test setup for the backend suite (bun test --preload).
// The ported domain tests import "./helpers/vitest-compat" instead of vitest.
import { mock } from "bun:test";
mock.module("cloudflare:workers", () => ({ DurableObject: class {}, WorkflowEntrypoint: class {} }));


// Bun 1.4 leaves `new Response(formData).headers` without a content-type,
// unlike browsers and workerd. Tests build multipart requests that way, so
// recover the boundary from the serialized body.
const NativeResponse = globalThis.Response;
class FormDataResponse extends NativeResponse {
  constructor(body?: BodyInit | null, init?: ResponseInit) {
    super(body, init);
    if (body instanceof FormData && !this.headers.get("content-type")) {
      const native = new NativeResponse(body);
      const self = this;
      const arrayBuffer = NativeResponse.prototype.arrayBuffer;
      Object.defineProperty(this, "arrayBuffer", {
        value: async () => {
          const bytes = await arrayBuffer.call(self);
          const boundary = new TextDecoder().decode(new Uint8Array(bytes, 0, 80)).split("\r\n")[0]!.slice(2);
          self.headers.set("content-type", `multipart/form-data; boundary=${boundary}`);
          return bytes;
        },
      });
      void native;
    }
  }
}
globalThis.Response = FormDataResponse as typeof Response;
