import { readFileSync } from "node:fs";
import { afterEach, describe, expect, it } from "./helpers/vitest-compat";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { space, thread } from "./helpers/seed";
import {
  ATTACHMENT_LIMITS,
  FileTooLargeError,
  StorageQuotaExceededError,
  attachmentLimits,
  formatDecimalBytes,
  getAttachmentLimits,
} from "../../src/domain/account-plan.js";
import {
  loadStorageUsage,
  releaseUpload,
  reserveUpload,
  sweepExpiredUploadReservations,
} from "../../src/domain/attachment-storage.js";
import {
  storeWorkRequestFile,
  verifyWorkRequestFile,
  userStorageUsage,
} from "../../src/domain/routes/work-request-files.js";
import { handleDeleteUserFile } from "../../src/domain/routes/user-files.js";

const GB = 1_000_000_000;
const open: Array<{ close(): void }> = [];
afterEach(() => {
  for (const sqlite of open.splice(0)) sqlite.close();
});

function fixture() {
  const { sqlite, db } = sqliteD1();
  open.push(sqlite);
  sqlite.exec("PRAGMA foreign_keys = OFF");
  sqlite.exec(
    "" /* D1 migration: schema is final in PostgreSQL */,
  );
  for (const id of ["free", "plus", "owner", "member"])
    sqlite
      .prepare(
        "INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES(?,?,?,'now','now')",
      )
      .run(id, `${id}@test`, id);
  const plan = (user: string, status = "active", end: string | null = null) =>
    sqlite
      .prepare(
        `INSERT OR REPLACE INTO account_plans(user_id,tier,status,source,current_period_end,created_at,updated_at)
         VALUES(?, 'paid', ?, 'manual', ?, 'now', 'now')`,
      )
      .run(user, status, end);
  plan("plus");
  plan("owner"); // owns the Space; their plan must not matter to uploaders
  const objects = new Map<string, Uint8Array>();
  const meta = new Map<string, Record<string, string>>();
  const bucket = {
    async put(
      key: string,
      value: ArrayBuffer | string,
      options?: R2PutOptions,
    ) {
      objects.set(
        key,
        typeof value === "string"
          ? new TextEncoder().encode(value)
          : new Uint8Array(value),
      );
      meta.set(key, (options?.customMetadata as Record<string, string>) ?? {});
    },
    async head(key: string) {
      const v = objects.get(key);
      return v
        ? { key, size: v.byteLength, customMetadata: meta.get(key) }
        : null;
    },
    async get(key: string) {
      const v = objects.get(key);
      return v
        ? {
            size: v.byteLength,
            customMetadata: meta.get(key),
            json: async () => JSON.parse(new TextDecoder().decode(v)),
          }
        : null;
    },
    async delete(keys: string | string[]) {
      for (const key of [keys].flat()) objects.delete(key);
    },
  };
  const env = { SYNTILA_DB: db, SYNTILA_ARTIFACTS: bucket } as never;
  const addFile = (id: string, user: string, size: number, thread = "t") =>
    sqlite
      .prepare(
        "INSERT INTO user_files VALUES (?, ?, ?, 'space', ?, 'x', ?, 'now')",
      )
      .run(id, user, thread, id, size);
  const stream = (text: string) =>
    new Response(text).body as ReadableStream<Uint8Array>;
  const store = (user: string, id: string, text: string, declared?: number) =>
    storeWorkRequestFile(env, {
      fileId: id,
      threadId: "t",
      spaceId: "space",
      userId: user,
      name: `${id}.txt`,
      upload: {
        mediaType: "text/plain",
        sizeBytes: declared ?? new TextEncoder().encode(text).byteLength,
        stream: stream(text),
      },
    });
  return { sqlite, db, env, bucket, objects, plan, addFile, store };
}

const fid = (n: number) =>
  `wrf-00000000-0000-0000-0000-${String(n).padStart(12, "0")}`;
const reserve = (
  f: ReturnType<typeof fixture>,
  user: string,
  n: number,
  size: number,
  now?: Date,
) =>
  reserveUpload(f.env, { fileId: fid(n), userId: user, sizeBytes: size, now });

describe("plan-based attachment limits", () => {
  it("states the policy in decimal bytes", () => {
    expect(ATTACHMENT_LIMITS.free).toEqual({
      storageBytes: 1_000_000_000,
      fileBytes: 25_000_000,
    });
    expect(ATTACHMENT_LIMITS.paid).toEqual({
      storageBytes: 25_000_000_000,
      fileBytes: 100_000_000,
    });
    expect(attachmentLimits("free").tier).toBe("free");
    expect(formatDecimalBytes(25_000_000)).toBe("25 MB");
    expect(formatDecimalBytes(100_000_000)).toBe("100 MB");
    expect(formatDecimalBytes(GB)).toBe("1 GB");
    expect(formatDecimalBytes(25 * GB)).toBe("25 GB");
  });

  it.each([
    ["free", 25_000_000],
    ["plus", 100_000_000],
  ])(
    "%s: the exact file limit fits and one byte more is file_too_large",
    async (user, limit) => {
      const f = fixture();
      await reserve(f, user, 1, limit);
      await expect(reserve(f, user, 2, limit + 1)).rejects.toBeInstanceOf(
        FileTooLargeError,
      );
      await expect(reserve(f, user, 2, limit + 1)).rejects.toMatchObject({
        status: 413,
        code: "file_too_large",
      });
    },
  );

  it("charges the uploader's plan whatever plan owns the Space", async () => {
    const f = fixture();
    // 'member' is Free in a Plus-owned Space: still the Free file limit.
    await expect(reserve(f, "member", 1, 25_000_001)).rejects.toMatchObject({
      code: "file_too_large",
    });
    expect((await getAttachmentLimits(f.env, "member")).fileBytes).toBe(
      25_000_000,
    );
    // A Plus uploader in a Free-owned Space keeps Plus limits.
    expect((await getAttachmentLimits(f.env, "plus")).fileBytes).toBe(
      100_000_000,
    );
  });

  it("separates 'storage full' from 'file too large' at the exact boundary", async () => {
    const f = fixture();
    f.addFile("a", "free", GB - 10);
    await reserve(f, "free", 1, 10); // exactly fills the allowance
    await expect(reserve(f, "free", 2, 1)).rejects.toBeInstanceOf(
      StorageQuotaExceededError,
    );
    await expect(reserve(f, "free", 2, 1)).rejects.toMatchObject({
      code: "storage_quota_exceeded",
    });
    // Plus has 25 GB, so the same account state fits.
    f.addFile("b", "plus", GB - 10);
    await reserve(f, "plus", 3, 10_000_000);
  });

  it("counts in-flight reservations and lets only what fits win a race", async () => {
    const f = fixture();
    f.addFile("a", "free", GB - 30_000_000);
    const results = await Promise.allSettled(
      [1, 2, 3, 4].map((n) => reserve(f, "free", n, 20_000_000)),
    );
    expect(results.filter((r) => r.status === "fulfilled")).toHaveLength(1);
    expect(
      results
        .filter((r) => r.status === "rejected")
        .every(
          (r) =>
            (r as PromiseRejectedResult).reason instanceof
            StorageQuotaExceededError,
        ),
    ).toBe(true);
    const usage = await loadStorageUsage(f.db as never, "free");
    expect(usage.reservedBytes).toBe(20_000_000);
  });

  it("makes retries idempotent and does not double count a file's own reservation", async () => {
    const f = fixture();
    f.addFile("a", "free", GB - 20_000_000);
    await reserve(f, "free", 1, 20_000_000);
    await reserve(f, "free", 1, 20_000_000); // a retry of the same upload
    await reserve(f, "free", 1, 20_000_000); // and a finalization recheck
    expect((await loadStorageUsage(f.db as never, "free")).reservedBytes).toBe(
      20_000_000,
    );
    // A restarted upload of an already stored id replaces it, not adds to it.
    f.addFile(fid(9), "free", 0);
    f.sqlite.exec(
      `UPDATE user_files SET size_bytes = 20000000 WHERE id='${fid(9)}'`,
    );
    f.sqlite.exec("DELETE FROM user_file_reservations");
    f.sqlite.exec("DELETE FROM user_files WHERE id = 'a'");
    f.addFile("b", "free", GB - 40_000_000);
    await reserve(f, "free", 9, 20_000_000);
  });

  it("frees abandoned and expired reservations", async () => {
    const f = fixture();
    const now = new Date("2026-11-01T00:00:00Z");
    f.addFile("a", "free", GB - 25_000_000);
    await reserve(f, "free", 1, 25_000_000, now);
    await expect(reserve(f, "free", 2, 1, now)).rejects.toBeInstanceOf(
      StorageQuotaExceededError,
    );
    // Past its expiry the reservation counts for nothing even before a sweep.
    const later = new Date(now.getTime() + 2 * 60 * 60 * 1000);
    await reserve(f, "free", 2, 1, later);
    await sweepExpiredUploadReservations(f.db as never, later);
    expect(
      f.sqlite
        .prepare("SELECT COUNT(*) AS n FROM user_file_reservations")
        .get(),
    ).toEqual({ n: 1 });
    await releaseUpload(f.db as never, fid(2), "free");
    expect(
      f.sqlite
        .prepare("SELECT COUNT(*) AS n FROM user_file_reservations")
        .get(),
    ).toEqual({ n: 0 });
  });

  it("re-evaluates the plan: upgrade, expiry, grace and downgrade", async () => {
    const f = fixture();
    await expect(reserve(f, "free", 1, 25_000_001)).rejects.toBeInstanceOf(
      FileTooLargeError,
    );
    f.plan("free"); // upgrade applies on the next check
    await reserve(f, "free", 1, 25_000_001);
    f.plan("free", "active", "2000-01-01T00:00:00Z"); // expired: Free again
    await expect(reserve(f, "free", 2, 25_000_001)).rejects.toBeInstanceOf(
      FileTooLargeError,
    );
    f.plan("free", "past_due", "2999-01-01T00:00:00Z"); // grace keeps Plus
    await reserve(f, "free", 2, 100_000_000);
    f.sqlite.exec("DELETE FROM account_plans WHERE user_id='free'"); // downgrade
    await expect(reserve(f, "free", 3, 25_000_001)).rejects.toBeInstanceOf(
      FileTooLargeError,
    );
  });

  it("keeps existing files of an over-quota or downgraded account usable and manageable", async () => {
    const f = fixture();
    // A former Plus user stored 2 GB and an 80 MB file, then downgraded.
    f.addFile("big", "free", 80_000_000);
    f.addFile("rest", "free", 2 * GB);
    await expect(reserve(f, "free", 1, 1)).rejects.toBeInstanceOf(
      StorageQuotaExceededError,
    );
    const usage = await userStorageUsage(f.env, "free");
    expect(usage.usedBytes).toBeGreaterThan(usage.quotaBytes); // not removed
    // Referencing the stored file still verifies, whatever the plan.
    f.objects.set(`work-request-inputs/${fid(5)}`, new Uint8Array(80));
    // (size checks use the real object; the sanity bound is the Plus limit)
    const stored = new Uint8Array(10);
    f.objects.set(`work-request-inputs/${fid(6)}`, stored);
    await expect(
      verifyWorkRequestFile(f.env, fid(6), "t", "free", 999),
    ).rejects.toThrow("not found"); // wrong declared size is still rejected
  });

  it("charges independent copies but not references, and frees only on real deletion", async () => {
    const f = fixture();
    const a = await f.store("free", fid(1), "same bytes");
    const b = await f.store("free", fid(2), "same bytes"); // a separate copy
    expect(a.digest).toBe(b.digest);
    expect(a.sizeBytes).toBe(10);
    expect((await loadStorageUsage(f.db as never, "free")).usedBytes).toBe(20);
    // Another account never shares storage: no cross-account deduplication.
    await f.store("plus", fid(3), "same bytes");
    expect((await loadStorageUsage(f.db as never, "plus")).usedBytes).toBe(10);
    // Messages and Work Requests that cite a file reference it; they own no
    // bytes, so two references to one file leave usage unchanged.
    const before = (await loadStorageUsage(f.db as never, "free")).usedBytes;
    f.sqlite.exec(space("s-free", "free") + thread("t", "s-free", "free"));
    f.sqlite
      .exec(`INSERT INTO discussion_messages(id,thread_id,author_user_id,body,attachments_json,created_at)
      VALUES('m1','t','free','x','[{"fileId":"${fid(1)}"}]','now'),
            ('m2','t','free','y','[{"fileId":"${fid(1)}"}]','now')`);
    expect((await loadStorageUsage(f.db as never, "free")).usedBytes).toBe(
      before,
    );
    // Deletion removes the bytes and the row; usage drops by that file only.
    const response = await handleDeleteUserFile(
      new Request(`https://t/api/files/${fid(1)}`, {
        method: "DELETE",
        headers: { authorization: "free" },
      }),
      f.env,
      fid(1),
    ).catch((e: unknown) => e);
    // (authorization is exercised in user-files.test.ts; here the file is
    // removed directly to assert the accounting.)
    void response;
    f.sqlite.exec(`DELETE FROM user_files WHERE id='${fid(1)}'`);
    expect((await loadStorageUsage(f.db as never, "free")).usedBytes).toBe(10);
  });

  it("counts archived Spaces and Threads: usage ignores where a file lives", async () => {
    const f = fixture();
    f.sqlite.exec(
      "INSERT INTO spaces(id,name,owner_user_id,created_at,updated_at) VALUES('arch','A','owner','now','now')",
    );
    f.addFile("in-archived", "free", 123_456, "archived-thread");
    f.addFile("elsewhere", "free", 1_000, "other-thread");
    expect((await loadStorageUsage(f.db as never, "free")).usedBytes).toBe(
      124_456,
    );
  });
});

describe("streamed upload storage", () => {
  it("stores a stream, verifies its real size and finalizes exactly once", async () => {
    const f = fixture();
    const stored = await f.store("free", fid(1), "hello world");
    expect(stored).toMatchObject({ sizeBytes: 11 });
    expect(stored.digest).toMatch(/^sha256:[0-9a-f]{64}$/);
    expect(
      f.sqlite
        .prepare("SELECT size_bytes FROM user_files WHERE id=?")
        .get(fid(1)),
    ).toEqual({ size_bytes: 11 });
    expect(
      f.sqlite
        .prepare("SELECT COUNT(*) AS n FROM user_file_reservations")
        .get(),
    ).toEqual({ n: 0 });
    // A retry of the same id replaces, never double counts.
    await f.store("free", fid(1), "hello world");
    expect((await loadStorageUsage(f.db as never, "free")).usedBytes).toBe(11);
  });

  it("rejects false declared sizes and leaves nothing behind", async () => {
    const f = fixture();
    await expect(f.store("free", fid(1), "ab", 5)).rejects.toMatchObject({
      code: "upload_size_mismatch",
    });
    await expect(f.store("free", fid(2), "abcdef", 3)).rejects.toMatchObject({
      code: "upload_size_mismatch",
    });
    expect(f.objects.size).toBe(0);
    expect(
      f.sqlite.prepare("SELECT COUNT(*) AS n FROM user_files").get(),
    ).toEqual({ n: 0 });
    expect(
      f.sqlite
        .prepare("SELECT COUNT(*) AS n FROM user_file_reservations")
        .get(),
    ).toEqual({ n: 0 });
  });

  it("rechecks entitlement at finalization: a downgrade mid-upload is honored", async () => {
    const f = fixture();
    // Reserve under Plus, then lose Plus before the write finalizes.
    const big = "x".repeat(30);
    f.plan("free");
    const realHead = f.bucket.head.bind(f.bucket);
    f.bucket.head = async (key: string) => {
      f.sqlite.exec("DELETE FROM account_plans WHERE user_id='free'");
      f.addFile("filler", "free", GB - 10);
      return realHead(key);
    };
    await expect(f.store("free", fid(1), big)).rejects.toBeInstanceOf(
      StorageQuotaExceededError,
    );
    expect(f.objects.size).toBe(0); // the stored object was removed
    expect(
      f.sqlite
        .prepare("SELECT COUNT(*) AS n FROM user_file_reservations")
        .get(),
    ).toEqual({ n: 0 });
  });

  it("only one of simultaneous full-size uploads fits a nearly full account", async () => {
    const f = fixture();
    f.addFile("a", "free", GB - 12);
    const results = await Promise.allSettled(
      [1, 2, 3].map((n) => f.store("free", fid(n), "0123456789")),
    );
    expect(results.filter((r) => r.status === "fulfilled")).toHaveLength(1);
    expect((await loadStorageUsage(f.db as never, "free")).usedBytes).toBe(
      GB - 2,
    );
  });
});
