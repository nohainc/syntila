import { expect, it } from "vitest";
import {
  CONVERSATION_WORKFLOWS,
  conversationWorkflowForExecution,
  BUILTIN_WORKFLOWS,
} from "../src/index.js";

it("separates manual product workflow identity from versioned execution", () => {
  expect(Object.keys(CONVERSATION_WORKFLOWS)).toEqual(["chat", "work"]);
  for (const id of ["chat", "work"]) {
    const definition = CONVERSATION_WORKFLOWS[id]!;
    expect(definition.type).toBe("manual");
    expect(definition.version).toBe(1);
    expect(definition.configurationSchema.properties).toHaveProperty(
      "reasoningEffort",
    );
    expect(definition.capabilities).toEqual([
      ...new Set(
        BUILTIN_WORKFLOWS[definition.execution.workflowId]!.steps.flatMap(
          (step) => step.requiredCapabilities,
        ),
      ),
    ]);
    expect(
      conversationWorkflowForExecution(
        definition.execution.workflowId,
        definition.execution.workflowVersion,
      ),
    ).toBe(definition);
  }
  expect(CONVERSATION_WORKFLOWS.work!.execution).toEqual({
    workflowId: "direct",
    workflowVersion: 2,
  });
  expect(conversationWorkflowForExecution("direct", 1)).toBeNull();
  expect(conversationWorkflowForExecution("plan_implement", 1)).toBeNull();
});
