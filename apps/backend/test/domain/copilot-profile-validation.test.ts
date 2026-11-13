import { readFileSync } from "node:fs";
import { describe, expect, it } from "./helpers/vitest-compat";
import { parseProfile } from "../../src/domain/tool-profile-validation.js";

describe("Copilot Profile Cloud validation", () => {
  it("preserves SDK model discovery and Content-Length usage framing", () => {
    const candidate = JSON.parse(
      readFileSync(
        new URL(
          "../../../profile_lab/assets/profiles/copilot.json",
          import.meta.url,
        ),
        "utf8",
      ),
    );

    const { profile } = parseProfile(candidate);

    expect(profile.model.discovery?.format).toBe("copilot_sdk_rpc");
    expect(profile.usage?.jsonRpc?.framing).toBe("content_length");
  });
});
