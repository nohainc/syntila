/**
 * Streams an upload into R2 without holding the file in memory. Kept free of
 * application imports so the same code runs unchanged in unit tests and in the
 * workerd evidence harness (`scripts/large-upload`).
 */

/** The stream did not carry exactly the declared number of bytes. */
export class UploadStreamError extends Error {
  readonly code = "upload_size_mismatch";
  constructor() {
    super("The uploaded file size did not match the declared size");
  }
}

const hex = (bytes: ArrayBuffer) =>
  [...new Uint8Array(bytes)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

interface WorkersStreams {
  FixedLengthStream?: new (
    length: number,
  ) => TransformStream<Uint8Array, Uint8Array>;
  crypto: Crypto & {
    DigestStream?: new (algorithm: string) => WritableStream<Uint8Array> & {
      readonly digest: Promise<ArrayBuffer>;
    };
  };
}

/**
 * Streams `stream` into R2 at `key` and returns its SHA-256 digest and first
 * bytes (for a text preview). The byte count is enforced exactly: more bytes
 * than `size` error the stream, and fewer fail the fixed-length R2 write, so a
 * false declared size can never be stored. In the Workers runtime the body is
 * tee'd into R2 (`FixedLengthStream`) and a `DigestStream`, so memory stays at
 * a few chunks whatever the size. Elsewhere (unit tests) the bounded stream is
 * collected instead.
 */
export async function putStream(
  bucket: R2Bucket,
  key: string,
  stream: ReadableStream<Uint8Array>,
  size: number,
  options: R2PutOptions,
): Promise<{ digest: string; head: Uint8Array }> {
  let total = 0;
  const head: number[] = [];
  const counter = new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, controller) {
      total += chunk.byteLength;
      if (total > size) throw new UploadStreamError();
      if (head.length < 1200)
        head.push(...chunk.subarray(0, 1200 - head.length));
      controller.enqueue(chunk);
    },
    flush() {
      if (total !== size) throw new UploadStreamError();
    },
  });
  const counted = stream.pipeThrough(counter);
  const workers = globalThis as unknown as WorkersStreams;
  try {
    if (workers.FixedLengthStream && workers.crypto.DigestStream) {
      const [toStorage, toDigest] = counted.tee();
      const fixed = new workers.FixedLengthStream(size);
      const digestStream = new workers.crypto.DigestStream("SHA-256");
      await Promise.all([
        toStorage.pipeTo(fixed.writable),
        toDigest.pipeTo(digestStream),
        bucket.put(key, fixed.readable, options),
      ]);
      return {
        digest: `sha256:${hex(await digestStream.digest)}`,
        head: Uint8Array.from(head),
      };
    }
    const body = await new Response(counted).arrayBuffer();
    if (body.byteLength !== size) throw new UploadStreamError();
    await bucket.put(key, body, options);
    return {
      digest: `sha256:${hex(await crypto.subtle.digest("SHA-256", body))}`,
      head: Uint8Array.from(head),
    };
  } catch {
    throw new UploadStreamError();
  }
}
