/**
 * Minimal `cloudflare:workers` surface used by the ported domain code.
 * The durable workflow runner (Phase 7.4) drives `WorkflowEntrypoint.run`.
 */
export abstract class WorkflowEntrypoint<Env = unknown, Params = unknown> {
  constructor(protected ctx: unknown, protected env: Env) {}
  abstract run(event: WorkflowEvent<Params>, step: WorkflowStep): Promise<unknown>;
}

export interface WorkflowEvent<T> { payload: Readonly<T>; timestamp: Date; instanceId: string }

export interface WorkflowStepConfig {
  retries?: { limit: number; delay: string | number; backoff?: "constant" | "linear" | "exponential" };
  timeout?: string | number;
}

export interface WorkflowStep {
  do<T>(name: string, callback: () => Promise<T>): Promise<T>;
  do<T>(name: string, config: WorkflowStepConfig, callback: () => Promise<T>): Promise<T>;
  sleep(name: string, duration: string | number): Promise<void>;
  sleepUntil(name: string, timestamp: Date | number): Promise<void>;
  waitForEvent<T = unknown>(name: string, options: { type: string; timeout?: string | number }): Promise<{ payload: T; timestamp: Date; type: string }>;
}

export class DurableObject<Env = unknown> {
  constructor(protected ctx: unknown, protected env: Env) {}
}
