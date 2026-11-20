/**
 * A Git reference a Workflow step may hand to a later step instead of an
 * artifact (ADR-037). It names where the work is and which commit it was; it
 * carries no credentials and no local path. The receiving Agent decides how to
 * fetch it with its own credentials. A reference that fails any rule here is
 * refused before a step starts.
 */
export interface GitReference {
  readonly kind: "git";
  /** `https://host/path` or `ssh://git@host/path`, with no password, query or fragment. */
  readonly remote: string;
  /** The exact commit, 40 (SHA-1) or 64 (SHA-256) hex digits. */
  readonly commit: string;
  /** Optional branch or tag the commit was on, for display and fetching. */
  readonly ref?: string;
}

export const MAX_GIT_REFERENCES = 8;

const HTTPS_REMOTE = /^https:\/\/[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?(?::\d{1,5})?\/[A-Za-z0-9._~/-]{1,300}$/;
const SSH_REMOTE = /^ssh:\/\/git@[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?(?::\d{1,5})?\/[A-Za-z0-9._~/-]{1,300}$/;
const COMMIT = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;
const REF = /^refs\/(?:heads|tags)\/[A-Za-z0-9._/-]{1,200}$/;

function validRemote(remote: string): boolean {
  if (!HTTPS_REMOTE.test(remote) && !SSH_REMOTE.test(remote)) return false;
  const path = remote.slice(remote.indexOf("/", remote.indexOf("//") + 2));
  return !path.split("/").some((part) => part === ".." || part === ".");
}

function validRef(ref: string): boolean {
  return (
    REF.test(ref) &&
    !ref.includes("..") &&
    !ref.includes("//") &&
    !ref.endsWith("/") &&
    !ref.endsWith(".lock") &&
    !ref.split("/").some((part) => part.startsWith(".") || part.endsWith("."))
  );
}

/** The reference when [value] is a valid one with exactly the known fields, otherwise null. */
export function parseGitReference(value: unknown): GitReference | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const v = value as Record<string, unknown>;
  const allowed = new Set(["kind", "remote", "commit", "ref"]);
  if (Object.keys(v).some((key) => !allowed.has(key))) return null;
  if (v.kind !== "git" || typeof v.remote !== "string" || typeof v.commit !== "string") return null;
  if (!validRemote(v.remote) || !COMMIT.test(v.commit)) return null;
  if (v.ref !== undefined && (typeof v.ref !== "string" || !validRef(v.ref))) return null;
  return { kind: "git", remote: v.remote, commit: v.commit, ...(v.ref !== undefined ? { ref: v.ref as string } : {}) };
}

/** Every reference of a handoff, or the first invalid one's index. */
export function parseGitReferences(values: readonly unknown[]): { ok: true; references: GitReference[] } | { ok: false; index: number } {
  if (values.length > MAX_GIT_REFERENCES) return { ok: false, index: MAX_GIT_REFERENCES };
  const references: GitReference[] = [];
  for (const [index, value] of values.entries()) {
    const parsed = parseGitReference(value);
    if (!parsed) return { ok: false, index };
    references.push(parsed);
  }
  return { ok: true, references };
}
