import { describe, expect, it, vi } from "../helpers/vitest-compat";
import {
  createMockEmailTransport,
  sendPolicyControlledTemplateEmail,
} from "../../../src/domain/email/email-service.js";
import {
  decideEmailNotification,
  shouldSendEmailNotification,
} from "../../../src/domain/email/notification-policy.js";

describe("email notification policy", () => {
  it("always permits essential messages", () => {
    expect(decideEmailNotification("auth.verify-email.v1")).toEqual({
      allowed: true,
      category: "essential",
      reason: "essential",
    });
    expect(shouldSendEmailNotification("auth.welcome.v1")).toBe(true);
    expect(shouldSendEmailNotification("space.invitation.v1")).toBe(true);
  });

  it("permits security messages under the security policy", () => {
    expect(decideEmailNotification("auth.password-changed.v1")).toEqual({
      allowed: true,
      category: "security",
      reason: "security-policy",
    });
  });

  it("suppresses optional collaboration updates by default", () => {
    expect(
      decideEmailNotification("space.invitation-accepted.v1"),
    ).toMatchObject({
      allowed: false,
      category: "optional",
      reason: "collaboration-preference",
    });
    expect(shouldSendEmailNotification("space.access-revoked.v1")).toBe(false);
  });

  it("uses one preference to enable optional collaboration updates", () => {
    expect(
      shouldSendEmailNotification("space.access-revoked.v1", {
        collaborationUpdatesEnabled: true,
      }),
    ).toBe(true);
  });

  it("does not invoke the transport when an optional message is suppressed", async () => {
    const transport = createMockEmailTransport();
    const result = await sendPolicyControlledTemplateEmail(
      { SYNTILA_EMAIL: transport },
      {
        to: "ada@example.com",
        templateId: "space.invitation-accepted.v1",
        input: {
          recipientName: "Grace",
          memberName: "Ada",
          spaceName: "Research",
          role: "member",
        },
      },
    );
    expect(result).toEqual({
      status: "skipped",
      reason: "notification_policy",
    });
    expect(transport.messages).toHaveLength(0);
  });

  it("uses the existing renderer and transport when enabled", async () => {
    const send = vi.fn(async () => ({ messageId: "message-1" }));
    const result = await sendPolicyControlledTemplateEmail(
      { SYNTILA_EMAIL: { send } },
      {
        to: "ada@example.com",
        templateId: "space.invitation-accepted.v1",
        notificationPreferences: { collaborationUpdatesEnabled: true },
        input: {
          recipientName: "Grace",
          memberName: "Ada",
          spaceName: "Research",
          role: "member",
        },
      },
    );
    expect(result).toMatchObject({ status: "accepted" });
    expect(send).toHaveBeenCalledOnce();
  });
});
