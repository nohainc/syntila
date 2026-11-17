import type {
  EmailNotificationCategory,
  EmailTemplateId,
} from "./email-types.js";
import { emailTemplateCatalog } from "./templates/index.js";

/**
 * The first optional-preference surface is intentionally one switch. It
 * covers collaboration updates without exposing a setting for every event.
 */
export interface EmailNotificationPreferences {
  readonly collaborationUpdatesEnabled: boolean;
}

export const DEFAULT_EMAIL_NOTIFICATION_PREFERENCES: EmailNotificationPreferences =
  Object.freeze({ collaborationUpdatesEnabled: false });

export interface EmailNotificationDecision {
  readonly allowed: boolean;
  readonly category: EmailNotificationCategory;
  readonly reason: "essential" | "security-policy" | "collaboration-preference";
}

function categoryForTemplate(
  templateId: EmailTemplateId,
): EmailNotificationCategory {
  const template = emailTemplateCatalog.find(
    (candidate) => candidate.id === templateId,
  );
  if (!template) throw new Error(`Unknown email template: ${templateId}`);
  return template.category;
}

export function decideEmailNotification(
  templateId: EmailTemplateId,
  preferences: EmailNotificationPreferences = DEFAULT_EMAIL_NOTIFICATION_PREFERENCES,
): EmailNotificationDecision {
  const category = categoryForTemplate(templateId);
  if (category === "essential") {
    return { allowed: true, category, reason: "essential" };
  }
  if (category === "security") {
    return { allowed: true, category, reason: "security-policy" };
  }
  return {
    allowed: preferences.collaborationUpdatesEnabled,
    category,
    reason: "collaboration-preference",
  };
}

export function shouldSendEmailNotification(
  templateId: EmailTemplateId,
  preferences?: EmailNotificationPreferences,
): boolean {
  return decideEmailNotification(templateId, preferences).allowed;
}
