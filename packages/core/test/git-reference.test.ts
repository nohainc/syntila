import { describe, expect, it } from "vitest";
import { parseGitReference, parseGitReferences, MAX_GIT_REFERENCES } from "../src/git-reference.js";

const sha = "a".repeat(40);
const ok = { kind: "git", remote: "https://github.com/nohainc/syntila.git", commit: sha, ref: "refs/heads/main" };

describe("Git reference handoff", () => {
  it("accepts https and ssh remotes with an exact commit", () => {
    expect(parseGitReference(ok)).toEqual(ok);
    expect(parseGitReference({ kind: "git", remote: "ssh://git@example.com/org/repo.git", commit: "b".repeat(64) })).not.toBeNull();
    expect(parseGitReference({ kind: "git", remote: "https://example.com:8443/a/b", commit: sha })).not.toBeNull();
  });

  it("refuses credentials, local paths, odd schemes, short or branch-only commits and unknown fields", () => {
    for (const remote of [
      "https://user:pw@github.com/a/b.git", "https://github.com/a/b?token=1", "https://github.com/a/b#x",
      "file:///Users/alice/repo", "/Users/alice/repo", "../repo", "git@github.com:a/b.git", "http://github.com/a/b",
      "ssh://root@host/a/b", "https://github.com/../b", "https://",
    ]) expect(parseGitReference({ ...ok, remote })).toBeNull();
    for (const commit of ["main", "abc123", "A".repeat(40), "a".repeat(41)]) expect(parseGitReference({ ...ok, commit })).toBeNull();
    for (const ref of ["heads/main", "refs/heads/a..b", "refs/heads/x.lock", "refs/heads//x", "refs/remotes/x", "refs/heads/.x"]) expect(parseGitReference({ ...ok, ref })).toBeNull();
    expect(parseGitReference({ ...ok, path: "/tmp" })).toBeNull();
    expect(parseGitReference("abc")).toBeNull();
    expect(parseGitReference(null)).toBeNull();
  });

  it("validates a whole handoff and caps its size", () => {
    expect(parseGitReferences([ok, ok])).toMatchObject({ ok: true });
    expect(parseGitReferences([ok, { ...ok, commit: "x" }])).toEqual({ ok: false, index: 1 });
    expect(parseGitReferences(Array.from({ length: MAX_GIT_REFERENCES + 1 }, () => ok))).toMatchObject({ ok: false });
  });
});
