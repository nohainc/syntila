export class WorkflowEntrypoint<Env = unknown, Params = unknown> {
  protected readonly env: Env;
  protected readonly workflowParams: Params | undefined = undefined;

  constructor(_ctx: unknown, env: Env) {
    this.env = env;
  }
}
