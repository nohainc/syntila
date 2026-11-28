#!/usr/bin/env node
import { randomUUID } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import { join, relative } from "node:path";
import { DeleteObjectCommand, PutObjectCommand } from "@aws-sdk/client-s3";
import { putImmutable, readObject } from "./release-r2.mjs";

const lock = "apt/.publication-lock";
async function files(dir) {
  const entries = await readdir(dir, { withFileTypes: true });
  return (
    await Promise.all(
      entries.map(async (e) =>
        e.isDirectory() ? files(join(dir, e.name)) : [join(dir, e.name)],
      ),
    )
  ).flat();
}
const compare = (a, b) => {
  const x = a.split(".").map(Number),
    y = b.split(".").map(Number);
  return x[0] - y[0] || x[1] - y[1] || x[2] - y[2];
};
export async function publishApt({ client, bucket, repo, version }) {
  if (
    !repo ||
    !/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(version || "")
  )
    throw Error("Invalid repository or version.");
  const token = randomUUID();
  const put = async (key, body, type = "application/octet-stream") =>
    client.send(
      new PutObjectCommand({
        Bucket: bucket,
        Key: key,
        Body: body,
        ContentType: type,
        CacheControl: "no-store, max-age=0",
      }),
    );
  try {
    await client.send(
      new PutObjectCommand({
        Bucket: bucket,
        Key: lock,
        Body: token,
        IfNoneMatch: "*",
        CacheControl: "no-store",
      }),
    );
  } catch (e) {
    if (e.$metadata?.httpStatusCode === 412)
      throw Error(
        "Another APT publication holds the lock. If interrupted, verify no publisher is running before removing apt/.publication-lock.",
      );
    throw e;
  }
  try {
    for (const arch of ["amd64", "arm64"]) {
      const path = `dists/stable/main/binary-${arch}/Packages`;
      const current = await readObject(client, bucket, `apt/${path}`);
      if (current) {
        for (const match of current
          .toString()
          .matchAll(/^Version: (\d+\.\d+\.\d+)$/gm)) {
          if (compare(match[1], version) > 0)
            throw Error(
              `Refusing to replace newer APT version ${match[1]} with ${version}.`,
            );
        }
      }
      const next = await readFile(join(repo, path), "utf8");
      if (!next.includes(`Version: ${version}\n`))
        throw Error(`Missing version ${version} in ${path}`);
    }
    const immutable = [
      ...(await files(join(repo, "pool"))),
      ...(await files(join(repo, "dists/stable"))).filter((p) =>
        p.includes("/by-hash/SHA256/"),
      ),
      join(repo, "syntila-archive-keyring.gpg"),
    ];
    for (const path of immutable) {
      const key = `apt/${relative(repo, path)}`;
      await putImmutable(client, bucket, key, await readFile(path));
    }
    for (const arch of ["amd64", "arm64"])
      for (const name of ["Packages", "Packages.gz"]) {
        const path = `dists/stable/main/binary-${arch}/${name}`;
        await put(`apt/${path}`, await readFile(join(repo, path)));
      }
    for (const name of ["Release.gpg", "Release", "InRelease"]) {
      const path = `dists/stable/${name}`;
      await put(`apt/${path}`, await readFile(join(repo, path)), "text/plain");
    }
    await put(
      "apt/index.html",
      await readFile(join(repo, "index.html")),
      "text/html; charset=utf-8",
    );
    console.log(`Published signed APT repository for ${version} to R2.`);
  } finally {
    const owner = await readObject(client, bucket, lock);
    if (owner?.toString() === token)
      await client.send(new DeleteObjectCommand({ Bucket: bucket, Key: lock }));
    else
      console.error(
        "APT publication lock ownership changed; it was not removed.",
      );
  }
}
