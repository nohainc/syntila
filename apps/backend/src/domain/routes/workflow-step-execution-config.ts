import {
  type BuiltinWorkflowDefinition,
  type TurnExecutionConfig,
} from "@syntila/core";
import { HttpError } from "./http-security.js";

export function resolveWorkflowStepExecutionConfig(
  workflow: BuiltinWorkflowDefinition,
  workerId: string,
  profile: { profileId: string; profileReleaseVersion: number } | undefined,
  modelId: string | null,
  effort: string | null,
): TurnExecutionConfig {
  if (
    !workerId ||
    !profile?.profileId ||
    !Number.isSafeInteger(profile.profileReleaseVersion) ||
    profile.profileReleaseVersion < 1
  )
    throw new HttpError(422, "Selected Worker Profile is unavailable");
  return {
    schemaVersion: 1,
    workerId,
    profileId: profile.profileId,
    profileReleaseVersion: profile.profileReleaseVersion,
    modelId,
    effort,
    workflowId: workflow.id,
    workflowVersion: workflow.version,
  };
}
