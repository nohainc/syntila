/** Placeholder for Cloudflare bindings whose in-process replacement is not ported yet. */
export function notImplementedBinding(name: string): unknown {
  const fail = () => { throw new Error(`${name} is not available yet on the VPS backend (Phase 7)`); };
  return new Proxy({}, { get: (_t, prop) => (prop === "then" ? undefined : fail) });
}
