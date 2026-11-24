import { listWorkerProfiles } from "../worker-profile-registry.js";
import { json, securityContext } from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";
export {
  spaceModelOptions,
  spaceWorkerExecutionOptions,
} from "../worker-execution-options.js";

export async function handleListWorkerCatalog(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  await securityContext(request, env, ctx);
  return json(await listWorkerProfiles(env.SYNTILA_DB));
}
