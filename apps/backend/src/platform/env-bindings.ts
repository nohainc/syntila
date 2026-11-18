/**
 * Bindings the backend's runtime adds to the Worker `Env` type, which the cloud
 * package generates for the auth Worker only (it has none of these). `runtime.ts`
 * and `server.ts` provide them (`SYNTILA_ARTIFACTS` is an S3-backed bucket with the
 * subset of the R2 API the domain uses); optional ones are absent in some deployments.
 */
import type { WorkflowHost } from "./workflows";

declare global {
  interface Env {
    SYNTILA_PROVIDER_FAILURE_KEY?: string;
    SYNTILA_ARTIFACTS?: R2Bucket;
    SYNTILA_RUN_WORKFLOW: ReturnType<WorkflowHost["binding"]>;
    SYNTILA_REALTIME_GATEWAY: DurableObjectNamespace;
    SYNTILA_RELEASE_PUBLISHER?: string;
    SYNTILA_RELEASE_TRUST_KEYS_JSON?: string;
  }
}
export {};
