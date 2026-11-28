import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { basename } from "node:path";
import {
  GetObjectCommand,
  PutObjectCommand,
  S3Client,
} from "@aws-sdk/client-s3";

const digest = (data) => createHash("sha256").update(data).digest("hex");
const missing = (error) =>
  error?.$metadata?.httpStatusCode === 404 ||
  error?.name === "NoSuchKey" ||
  error?.name === "NotFound";
const conflict = (error) =>
  error?.$metadata?.httpStatusCode === 412 ||
  error?.name === "PreconditionFailed";

export function releaseClient(env = process.env) {
  const {
    CLOUDFLARE_ACCOUNT_ID: account,
    SYNTILA_RELEASE_R2_ACCESS_KEY_ID: accessKeyId,
    SYNTILA_RELEASE_R2_SECRET_ACCESS_KEY: secretAccessKey,
  } = env;
  if (
    !/^[0-9a-f]{32}$/i.test(account || "") ||
    !accessKeyId ||
    !secretAccessKey
  ) {
    throw Error(
      "Set CLOUDFLARE_ACCOUNT_ID, SYNTILA_RELEASE_R2_ACCESS_KEY_ID and SYNTILA_RELEASE_R2_SECRET_ACCESS_KEY.",
    );
  }
  return new S3Client({
    region: "auto",
    endpoint: `https://${account}.r2.cloudflarestorage.com`,
    credentials: { accessKeyId, secretAccessKey },
    requestChecksumCalculation: "WHEN_REQUIRED",
    responseChecksumValidation: "WHEN_REQUIRED",
  });
}

export async function readObject(client, bucket, key) {
  try {
    const result = await client.send(
      new GetObjectCommand({ Bucket: bucket, Key: key }),
    );
    return Buffer.from(await result.Body.transformToByteArray());
  } catch (error) {
    if (missing(error)) return null;
    throw error;
  }
}

// Never replace an existing release object, including when publishers race.
export async function putImmutable(
  client,
  bucket,
  key,
  body,
  contentType = "application/octet-stream",
) {
  const data = Buffer.isBuffer(body) ? body : Buffer.from(body);
  try {
    await client.send(
      new PutObjectCommand({
        Bucket: bucket,
        Key: key,
        Body: data,
        IfNoneMatch: "*",
        ContentType: contentType,
        CacheControl: "public, max-age=31536000, immutable",
      }),
    );
    return "created";
  } catch (error) {
    if (!conflict(error)) throw error;
    const prior = await readObject(client, bucket, key);
    if (prior && prior.length === data.length && digest(prior) === digest(data))
      return "existing";
    throw Error(`Refusing to replace immutable release object: ${key}`);
  }
}

export async function publishConnect({
  client,
  bucket,
  version,
  commit,
  platform,
  paths,
}) {
  if (
    !/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(version) ||
    !/^[0-9a-f]{40}$/.test(commit) ||
    !["linux", "macos", "windows"].includes(platform)
  )
    throw Error("Invalid release version, commit or platform.");
  const entries = new Map();
  for (const path of paths) {
    const name = basename(path);
    if (entries.has(name)) throw Error(`Duplicate release file: ${name}`);
    entries.set(name, await readFile(path));
  }
  const sums = entries.get("SHA256SUMS");
  if (!sums) throw Error("SHA256SUMS is required.");
  const lines = sums.toString("utf8").replace(/\r/g, "").trim().split("\n");
  const expected = new Map();
  for (const line of lines) {
    const match = /^([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._-]*)$/.exec(line);
    if (!match || expected.has(match[2])) throw Error("Invalid SHA256SUMS.");
    expected.set(match[2], match[1]);
  }
  const assets = [...entries.keys()].filter((name) => name !== "SHA256SUMS");
  if (!assets.length || assets.length !== expected.size)
    throw Error("SHA256SUMS does not cover exactly the release files.");
  for (const name of assets) {
    if (
      !(
        name.startsWith(`Syntila-Connect-${version}-${platform}-`) ||
        (platform === "linux" &&
          new RegExp(
            `^syntila-connect_${version.replaceAll(".", "\\.")}_(amd64|arm64)\\.deb$`,
          ).test(name))
      ) ||
      expected.get(name) !== digest(entries.get(name))
    )
      throw Error(`Invalid release asset or checksum: ${name}`);
  }
  const prefix = `connect/${version}`;
  const provenance = Buffer.from(
    `${JSON.stringify({ schemaVersion: 1, version, commit })}\n`,
  );
  await putImmutable(
    client,
    bucket,
    `${prefix}/build.json`,
    provenance,
    "application/json",
  );
  for (const name of assets.sort())
    await putImmutable(client, bucket, `${prefix}/${name}`, entries.get(name));
  await putImmutable(
    client,
    bucket,
    `${prefix}/SHA256SUMS-${platform}`,
    Buffer.from(`${lines.join("\n")}\n`),
    "text/plain; charset=utf-8",
  );
  return assets;
}
