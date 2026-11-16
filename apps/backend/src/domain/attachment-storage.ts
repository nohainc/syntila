import {
  FileTooLargeError,
  StorageQuotaExceededError,
  attachmentFileLimitSql,
  attachmentStorageQuotaSql,
  getAttachmentLimits,
} from "./account-plan.js";

import { inTransaction } from "../platform/tx-env.js";
import { dataOf } from "../platform/data.js";

/**
 * A reservation outlives the slowest permitted upload (100 MB on a poor
 * connection) but not by much; once expired it counts for nothing.
 */
export const UPLOAD_RESERVATION_TTL_MS = 60 * 60 * 1000;
// These fragments are built from source-controlled SQL and constants only.
const FILE_LIMIT_SQL = attachmentFileLimitSql("uploader.user_id");
const STORAGE_QUOTA_SQL = attachmentStorageQuotaSql("uploader.user_id");

export interface StorageUsage {
  /** Bytes of retained uploaded files, whatever Thread or Space holds them. */
  readonly usedBytes: number;
  readonly fileCount: number;
  /** Bytes held by uploads still in flight; they reduce available room. */
  readonly reservedBytes: number;
}

export async function loadStorageUsage(
  env: { SYNTILA_DB: unknown; SYNTILA_DATA?: unknown },
  userId: string,
  now: Date = new Date(),
): Promise<StorageUsage> {
  const row = await dataOf(env).read.row<StorageUsage>`
      SELECT (SELECT COALESCE(SUM(size_bytes), 0) FROM user_files WHERE user_id = ${userId}) AS "usedBytes",
              (SELECT COUNT(*) FROM user_files WHERE user_id = ${userId}) AS "fileCount",
              (SELECT COALESCE(SUM(size_bytes), 0) FROM user_file_reservations
                WHERE user_id = ${userId} AND expires_at > ${now.toISOString()}) AS "reservedBytes"`;
  return {
    usedBytes: Number(row?.usedBytes ?? 0),
    fileCount: Number(row?.fileCount ?? 0),
    reservedBytes: Number(row?.reservedBytes ?? 0),
  };
}

/**
 * Atomically reserves `sizeBytes` of the uploader's storage for `fileId`.
 *
 * The check and the write are one statement, run under a per-user storage
 * lock: the row is inserted only when the size is within the uploader's
 * per-file limit and retained bytes, other live reservations and this file
 * all fit the total allowance. The lock is what keeps concurrent uploads
 * from both passing the sum (each statement alone would see the other's
 * reservation only after it committed). The file's own earlier row/reservation (a retried
 * or restarted upload of the same id) is excluded, which makes retries
 * idempotent and keeps a finalization recheck from counting itself twice.
 */
export async function reserveUpload(
  env: Env,
  input: {
    fileId: string;
    userId: string;
    sizeBytes: number;
    now?: Date;
  },
): Promise<void> {
  const now = input.now ?? new Date();
  const row = await inTransaction(env, "files.reserve", async (_txEnv, tx) => {
    await tx.lock("syntila.storage", input.userId);
    return tx.row<{ id: string }>`
     INSERT INTO user_file_reservations (id, user_id, size_bytes, created_at, expires_at)
     SELECT ${input.fileId}, uploader.user_id, ${input.sizeBytes}, ${now.toISOString()}, ${new Date(now.getTime() + UPLOAD_RESERVATION_TTL_MS).toISOString()}
       FROM (SELECT ${input.userId}::text AS user_id) uploader
      WHERE ${input.sizeBytes} <= ${tx.raw(FILE_LIMIT_SQL)}
        AND (SELECT COALESCE(SUM(size_bytes), 0) FROM user_files
              WHERE user_id = uploader.user_id AND id != ${input.fileId})
          + (SELECT COALESCE(SUM(size_bytes), 0) FROM user_file_reservations
              WHERE user_id = uploader.user_id AND id != ${input.fileId} AND expires_at > ${now.toISOString()})
          + ${input.sizeBytes} <= ${tx.raw(STORAGE_QUOTA_SQL)}
     ON CONFLICT(id) DO UPDATE SET size_bytes = excluded.size_bytes,
       created_at = excluded.created_at, expires_at = excluded.expires_at
       WHERE user_file_reservations.user_id = excluded.user_id
     RETURNING id`;
  });
  if (row?.id === input.fileId) return;
  // Refused: say which allowance, so "file too large" never reads as "full".
  const limits = await getAttachmentLimits(env, input.userId, now);
  if (input.sizeBytes > limits.fileBytes) throw new FileTooLargeError(limits);
  throw new StorageQuotaExceededError(limits);
}

export async function releaseUpload(
  env: Env,
  fileId: string,
  userId: string,
): Promise<void> {
  await inTransaction(env, "files.release", async (_txEnv, tx) => {
    await tx.run`DELETE FROM user_file_reservations WHERE id = ${fileId} AND user_id = ${userId}`;
  });
}

/** Drops expired reservations (they already count for nothing). */
export async function sweepExpiredUploadReservations(
  env: { SYNTILA_DB: unknown; SYNTILA_DATA?: unknown },
  now: Date = new Date(),
): Promise<void> {
  await inTransaction(env, "files.sweep_reservations", async (_txEnv, tx) => {
    await tx.run`DELETE FROM user_file_reservations WHERE expires_at <= ${now.toISOString()}`;
  });
}
