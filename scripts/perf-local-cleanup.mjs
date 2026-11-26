/** Preserve failed or active runs so their diagnostics and work remain available. */
export async function finalizeBenchmarkSpace({
  activeCount,
  succeeded,
  remove,
}) {
  if (activeCount > 0) return "active";
  if (!succeeded) return "failed";
  await remove();
  return "deleted";
}
