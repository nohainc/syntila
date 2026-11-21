import { expect, it } from "./helpers/vitest-compat";
import { WorkerGateway } from "../../src/domain/worker-gateway.js";

function gatewayWithSocket(sent: string[]) {
  const gateway = new WorkerGateway({} as never, {} as never) as any;
  gateway.knownWorkerId = "w";
  gateway.attachment = { workerId: "w", sessionId: "s", fence: { workerInstanceId: "w", sessionId: "s", epoch: 1 } };
  gateway.socket = { send: (data: string) => sent.push(data), close: () => undefined };
  return gateway;
}

it("relays the Agent's usage report to the waiting owner and keeps nothing", async () => {
  const sent: string[] = [];
  const gateway = gatewayWithSocket(sent);
  const pending = gateway.fetch(new Request("http://gateway/usage-request", { method: "POST" }));
  await Promise.resolve();
  const ack = JSON.parse(sent[0]!);
  const requestId = ack.payload.usageRequestId as string;
  expect(requestId).toMatch(/^usage-/);
  // Repeated on heartbeats until answered.
  expect(gateway.usageNotice()).toEqual({ usageRequestId: requestId });

  await gateway.fetch(new Request("http://gateway/usage-result", {
    method: "POST",
    body: JSON.stringify({ requestId, status: "ok", output: "Session: 6% used", exitCode: 0 }),
  }));
  const response = await pending;
  expect(response.status).toBe(200);
  expect(await response.json()).toEqual(expect.objectContaining({ status: "ok", output: "Session: 6% used" }));
  expect(gateway.usageNotice()).toEqual({});
});

it("ignores an unknown usage answer and refuses when the Worker is offline", async () => {
  const sent: string[] = [];
  const gateway = gatewayWithSocket(sent);
  const stray = await gateway.fetch(new Request("http://gateway/usage-result", { method: "POST", body: JSON.stringify({ requestId: "usage-x", status: "ok" }) }));
  expect(stray.status).toBe(200);
  expect(gateway.usageNotice()).toEqual({});

  gateway.socket = null;
  const offline = await gateway.fetch(new Request("http://gateway/usage-request", { method: "POST" }));
  expect(offline.status).toBe(409);
});
