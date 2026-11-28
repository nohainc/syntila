import { describe, expect, it } from "vitest";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { publishConnect, putImmutable } from "./internal/release-r2.mjs";
import { publishApt } from "./internal/publish-apt-r2.mjs";

class MemoryStore {
  objects = new Map();
  calls = [];
  async send(command) {
    const { Key, Body, IfNoneMatch } = command.input;
    this.calls.push(command.input);
    if (command.constructor.name === "DeleteObjectCommand") {
      this.objects.delete(Key);
      return {};
    }
    if (command.constructor.name === "PutObjectCommand") {
      if (IfNoneMatch === "*" && this.objects.has(Key))
        throw Object.assign(new Error("exists"), {
          $metadata: { httpStatusCode: 412 },
        });
      this.objects.set(Key, Buffer.from(Body));
      return {};
    }
    if (!this.objects.has(Key))
      throw Object.assign(new Error("missing"), {
        $metadata: { httpStatusCode: 404 },
      });
    const value = this.objects.get(Key);
    return { Body: { transformToByteArray: async () => value } };
  }
}
const hash = (value) => createHash("sha256").update(value).digest("hex");

describe("R2 release publication", () => {
  it("publishes verified assets immutably, supports retries and pins all platforms to one commit", async () => {
    const dir = await mkdtemp(join(tmpdir(), "syntila-release-r2-"));
    try {
      const name = "syntila-connect_0.3.1_amd64.deb";
      const asset = join(dir, name),
        sums = join(dir, "SHA256SUMS");
      await writeFile(asset, "release bytes");
      await writeFile(sums, `${hash("release bytes")}  ${name}\n`);
      const client = new MemoryStore();
      const input = {
        client,
        bucket: "syntila-releases",
        version: "0.3.1",
        commit: "a".repeat(40),
        platform: "linux",
        paths: [asset, sums],
      };
      await publishConnect(input);
      expect(client.objects.get(`connect/0.3.1/${name}`).toString()).toBe(
        "release bytes",
      );
      expect(client.objects.has("connect/0.3.1/SHA256SUMS-linux")).toBe(true);
      expect(
        client.calls
          .filter((call) => call.Body)
          .every((call) => call.IfNoneMatch === "*"),
      ).toBe(true);
      await publishConnect(input);
      await expect(
        publishConnect({ ...input, commit: "b".repeat(40) }),
      ).rejects.toThrow("immutable");
      await writeFile(asset, "different bytes");
      await writeFile(sums, `${hash("different bytes")}  ${name}\n`);
      await expect(publishConnect(input)).rejects.toThrow("immutable");
      expect((await readFile(asset)).toString()).toBe("different bytes");
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
  it("rejects bad checksum lists before writing any objects", async () => {
    const dir = await mkdtemp(join(tmpdir(), "syntila-release-r2-"));
    try {
      const asset = join(dir, "syntila-connect_0.3.1_amd64.deb"),
        sums = join(dir, "SHA256SUMS");
      await writeFile(asset, "release");
      await writeFile(sums, `${"0".repeat(64)}  ${asset.split("/").at(-1)}\n`);
      const client = new MemoryStore();
      await expect(
        publishConnect({
          client,
          bucket: "syntila-releases",
          version: "0.3.1",
          commit: "a".repeat(40),
          platform: "linux",
          paths: [asset, sums],
        }),
      ).rejects.toThrow("checksum");
      expect(client.calls).toHaveLength(0);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
  it("refuses a concurrent conflicting immutable object", async () => {
    const client = new MemoryStore();
    await putImmutable(client, "syntila-releases", "key", Buffer.from("a"));
    await expect(
      putImmutable(client, "syntila-releases", "key", Buffer.from("b")),
    ).rejects.toThrow("immutable");
  });
});

describe("APT R2 publication", () => {
  it("publishes immutable packages before signed indexes and refuses a downgrade", async () => {
    const dir = await mkdtemp(join(tmpdir(), "syntila-apt-r2-"));
    try {
      const putFile = async (path, data) => {
        const full = join(dir, path);
        await mkdir(join(full, ".."), { recursive: true });
        await writeFile(full, data);
      };
      await putFile("pool/test.deb", "package");
      await putFile("syntila-archive-keyring.gpg", "key");
      await putFile("index.html", "index");
      for (const arch of ["amd64", "arm64"]) {
        const base = `dists/stable/main/binary-${arch}`;
        await putFile(
          `${base}/Packages`,
          "Package: syntila-connect\nVersion: 0.3.1\n",
        );
        await putFile(`${base}/Packages.gz`, "compressed");
        await putFile(`${base}/by-hash/SHA256/hash`, "hash content");
      }
      for (const name of ["Release", "Release.gpg", "InRelease"])
        await putFile(`dists/stable/${name}`, name);
      const client = new MemoryStore();
      await publishApt({
        client,
        bucket: "releases",
        repo: dir,
        version: "0.3.1",
      });
      const keys = client.calls.filter((c) => c.Body).map((c) => c.Key);
      expect(keys.indexOf("apt/pool/test.deb")).toBeLessThan(
        keys.indexOf("apt/dists/stable/InRelease"),
      );
      expect(client.objects.has("apt/.publication-lock")).toBe(false);
      await expect(
        publishApt({ client, bucket: "releases", repo: dir, version: "0.2.9" }),
      ).rejects.toThrow("newer APT version");
      expect(client.objects.has("apt/.publication-lock")).toBe(false);
      expect(client.objects.get("apt/dists/stable/InRelease").toString()).toBe(
        "InRelease",
      );
      client.objects.set(
        "apt/.publication-lock",
        Buffer.from("other publisher"),
      );
      await expect(
        publishApt({ client, bucket: "releases", repo: dir, version: "0.3.1" }),
      ).rejects.toThrow("holds the lock");
      expect(client.objects.get("apt/.publication-lock").toString()).toBe(
        "other publisher",
      );
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});
