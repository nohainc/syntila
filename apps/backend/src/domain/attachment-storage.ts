import {
  FileTooLargeError,
  StorageQuotaExceededError,
  attachmentFileLimitSql,
  attachmentStorageQuotaSql,
  getAttachmentLimits,
} from "./account-plan.js";

/**
 * A reservation outlives the slowest permitted upload (100 MB on a poor
 * connection) but not by much; once expired it counts for nothing.
 */
export const UPLOAD_RESERVATION_TTL_MS = 60 * 60 * 1000;

export interface StorageUsage {
  /** Bytes of retained uploaded files, whatever Thread or Space holds them. */
  readonly usedBytes: number;
  readonly fileCount: number;
  /** Bytes held by uploads still in flight; they reduce available room. */
  readonly reservedBytes: number;
}

export async function loadStorageUsage(
  db: D1Database,
  userId: string,
  now: Date = new Date(),
): Promise<StorageUsage> {
  const row = await db
    .prepare(
      `SELECT (SELECT COALESCE(SUM(size_bytes), 0) FROM user_files WHERE user_id = ?1) AS usedBytes,
              (SELECT COUNT(*) FROM user_files WHERE user_id = ?1) AS fileCount,
              (SELECT COALESCE(SUM(size_bytes), 0) FROM user_file_reservations
                WHERE user_id = ?1 AND expires_at > ?2) AS reservedBytes`,
    )
    .bind(userId, now.toISOString())
    .first<StorageUsage>();
  return {
    usedBytes: Number(row?.usedBytes ?? 0),
    fileCount: Number(row?.fileCount ?? 0),
    reservedBytes: Number(row?.reservedBytes ?? 0),
  };
}

/**
 * Atomically reserves `sizeBytes` of the uploader's storage for `fileId`.
 *
 * The check and the write are one statement: the row is inserted only when
 * the size is within the uploader's per-file limit and retained bytes, other
 * live reservations and this file all fit the total allowance, so concurrent
 * uploads cannot exceed it. The file's own earlier row/reservation (a retried
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
  const row = await env.SYNTILA_DB.prepare(
    `INSERT INTO user_file_reservations (id, user_id, size_bytes, created_at, expires_at)
     SELECT ?1, ?2, ?3, ?4, ?5
      WHERE ?3 <= ${attachmentFileLimitSql("?2")}
        AND (SELECT COALESCE(SUM(size_bytes), 0) FROM user_files
              WHERE user_id = ?2 AND id != ?1)
          + (SELECT COALESCE(SUM(size_bytes), 0) FROM user_file_reservations
              WHERE user_id = ?2 AND id != ?1 AND expires_at > ?4)
          + ?3 <= ${attachmentStorageQuotaSql("?2")}
     ON CONFLICT(id) DO UPDATE SET size_bytes = excluded.size_bytes,
       created_at = excluded.created_at, expires_at = excluded.expires_at
       WHERE user_file_reservations.user_id = excluded.user_id
     RETURNING id`,
  )
    .bind(
      input.fileId,
      input.userId,
      input.sizeBytes,
      now.toISOString(),
      new Date(now.getTime() + UPLOAD_RESERVATION_TTL_MS).toISOString(),
    )
    .first<{ id: string }>();
  if (row?.id === input.fileId) return;
  // Refused: say which allowance, so "file too large" never reads as "full".
  const limits = await getAttachmentLimits(env, input.userId, now);
  if (input.sizeBytes > limits.fileBytes) throw new FileTooLargeError(limits);
  throw new StorageQuotaExceededError(limits);
}

export async function releaseUpload(
  db: D1Database,
  fileId: string,
  userId: string,
): Promise<void> {
  await db
    .prepare(
      "DELETE FROM user_file_reservations WHERE id = ?1 AND user_id = ?2",
    )
    .bind(fileId, userId)
    .run();
}

/** Drops expired reservations (they already count for nothing). */
export async function sweepExpiredUploadReservations(
  db: D1Database,
  now: Date = new Date(),
): Promise<void> {
  await db
    .prepare("DELETE FROM user_file_reservations WHERE expires_at <= ?1")
    .bind(now.toISOString())
    .run();
}
