import { describe, expect, it } from "vitest";
import {
  AuthorizationError,
  authorize,
  authorizeProfileAdmin,
  authorizeSpaceMembership,
  authorizeSpaceOwner,
  authorizeSpaceInvitationResponse,
  canAccessSpaceInvitation,
  computePackageDigest,
  extractBearerToken,
  hashToken,
  resolveSpaceSecurityContextFromIdentity,
  type SecurityQuery,
  type SecurityContext,
} from "../src/index.js";

const user = {
  id: "user-1",
  email: "one@example.test",
  displayName: "User One",
  status: "active" as const,
};
const context: SecurityContext = {
  userId: user.id,
  user,
  spaceRoles: { "space-1": "collaborator", "space-2": "viewer" },
  sessionId: "session-1",
  clientType: "web",
};

function database(firstResult: unknown): SecurityQuery {
  return {
    row: async <T>() => firstResult as T,
    rows: async <T>() => [] as T[],
  };
}

describe("current authorization model", () => {
  it("authorizes actions from current Space roles only", () => {
    expect(() => authorize(context, "spaces:write", "space-1")).not.toThrow();
    expect(() => authorize(context, "runs:control", "space-1")).toThrow(
      AuthorizationError,
    );
    expect(() => authorize(context, "spaces:write", "space-2")).toThrow(
      AuthorizationError,
    );
    expect(() => authorize(context, "spaces:read", "unrelated-space")).toThrow(
      AuthorizationError,
    );
  });

  it("rechecks Space membership and ownership in the database", async () => {
    const db = database({ role: "owner" });
    await expect(
      authorizeSpaceMembership(db, context, "space-1", "spaces:manage"),
    ).resolves.toEqual({ role: "owner" });
    await expect(
      authorizeSpaceOwner(db, context, "space-1"),
    ).resolves.toBeUndefined();
    await expect(
      authorizeSpaceMembership(
        database(null),
        context,
        "space-1",
        "spaces:read",
      ),
    ).rejects.toBeInstanceOf(AuthorizationError);
  });

  it("keeps Profile administration separate from Space roles", () => {
    expect(() => authorizeProfileAdmin(context, ["user-1"])).not.toThrow();
    expect(() => authorizeProfileAdmin(context, ["another-user"])).toThrow(
      AuthorizationError,
    );
    expect(() =>
      authorizeProfileAdmin(context, ["user-1"], "profiles:release:manage"),
    ).not.toThrow();
    expect(() =>
      authorizeProfileAdmin(context, ["admin-only"], "profiles:release:manage"),
    ).toThrow(AuthorizationError);

    // Desktop clients must possess syntila.profile-lab.management audience
    const profileLabDesktopContext: SecurityContext = {
      ...context,
      clientType: "desktop",
      audience: "syntila.profile-lab.management",
    };
    expect(() =>
      authorizeProfileAdmin(profileLabDesktopContext, ["user-1"]),
    ).not.toThrow();

    const desktopContext: SecurityContext = {
      ...context,
      clientType: "desktop",
      audience: "syntila.desktop.management",
    };
    expect(() =>
      authorizeProfileAdmin(desktopContext, ["user-1"]),
    ).toThrow(AuthorizationError);

    const unspecifiedDesktopContext: SecurityContext = {
      ...context,
      clientType: "desktop",
    };
    expect(() =>
      authorizeProfileAdmin(unspecifiedDesktopContext, ["user-1"]),
    ).toThrow(AuthorizationError);
  });

  it("resolves human identity and Space roles without legacy aliases", async () => {
    const db: SecurityQuery = {
      row: async <T>() =>
        ({
          id: "user-1",
          email: "one@example.test",
          display_name: "User One",
          avatar_url: null,
          status: "active",
        }) as T,
      rows: async <T>() => [{ space_id: "space-1", role: "owner" }] as unknown as T[],
    };
    const resolved = await resolveSpaceSecurityContextFromIdentity(db, {
      userId: "user-1",
      email: "one@example.test",
      name: "User One",
      sessionId: "session-1",
    });
    expect(resolved.spaceRoles).toEqual({ "space-1": "owner" });
    expect(resolved.clientType).toBe("web");
    expect(resolved.audience).toBeUndefined();
    expect(resolved).not.toHaveProperty("authorizationModel");
    expect(resolved).not.toHaveProperty("legacyRole");
    expect(resolved).not.toHaveProperty("organizationId");

    const desktopResolved = await resolveSpaceSecurityContextFromIdentity(
      db,
      {
        userId: "user-1",
        email: "one@example.test",
        name: "User One",
        sessionId: "session-1",
      },
      "desktop",
      "syntila.profile-lab.management",
    );
    expect(desktopResolved.clientType).toBe("desktop");
    expect(desktopResolved.audience).toBe("syntila.profile-lab.management");
  });
});

describe("security token utilities", () => {
  it("hashes tokens and computes package digests", async () => {
    expect(await hashToken("token")).toMatch(/^[a-f0-9]{64}$/);
    expect(await computePackageDigest("content")).toMatch(
      /^sha256:[a-f0-9]{64}$/,
    );
  });

  it("extracts bearer credentials", () => {
    expect(
      extractBearerToken(new Headers({ authorization: "Bearer abc" })),
    ).toBe("abc");
    expect(
      extractBearerToken(new Headers({ authorization: "Basic abc" })),
    ).toBeNull();
  });
});

describe("invitation authorization", () => {
  const invitation = {
    id: "inv-1",
    spaceId: "space-1",
    email: "one@example.test",
    status: "pending",
    expiresAt: new Date(Date.now() + 60000).toISOString(),
  };

  it("authorizes invitation response when email matches and status is pending", () => {
    expect(() =>
      authorizeSpaceInvitationResponse(context, invitation),
    ).not.toThrow();
  });

  it("rejects invitation response when email does not match", () => {
    const wrongUser = {
      ...context,
      user: { ...context.user, email: "other@example.test" },
    };
    expect(() =>
      authorizeSpaceInvitationResponse(wrongUser, invitation),
    ).toThrow(AuthorizationError);
  });

  it("rejects invitation response when invitation is not pending", () => {
    expect(() =>
      authorizeSpaceInvitationResponse(context, {
        ...invitation,
        status: "accepted",
      }),
    ).toThrow(AuthorizationError);
  });

  it("rejects invitation response when invitation has expired", () => {
    expect(() =>
      authorizeSpaceInvitationResponse(context, {
        ...invitation,
        expiresAt: new Date(Date.now() - 60000).toISOString(),
      }),
    ).toThrow(AuthorizationError);
  });

  it("allows access to space owners or matching recipients", () => {
    expect(canAccessSpaceInvitation(context, invitation)).toBe(true);

    const ownerContext: SecurityContext = {
      userId: "owner-id",
      user: {
        id: "owner-id",
        email: "owner@nohainc.com",
        displayName: "Owner",
        status: "active",
      },
      spaceRoles: { "space-1": "owner" },
      sessionId: "s2",
      clientType: "web",
    };
    expect(canAccessSpaceInvitation(ownerContext, invitation)).toBe(true);

    const unrelatedContext: SecurityContext = {
      userId: "other-id",
      user: {
        id: "other-id",
        email: "unrelated@example.test",
        displayName: "Other",
        status: "active",
      },
      spaceRoles: {},
      sessionId: "s3",
      clientType: "web",
    };
    expect(canAccessSpaceInvitation(unrelatedContext, invitation)).toBe(false);
  });
});
