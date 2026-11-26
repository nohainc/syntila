/** Run at most `concurrency` jobs at once and drain started jobs on failure. */
export async function runWorkerLoad(total, concurrency, run) {
  if (
    !Number.isInteger(total) ||
    total < 0 ||
    !Number.isInteger(concurrency) ||
    concurrency < 1 ||
    concurrency > 8
  ) {
    throw new RangeError(
      "total must be non-negative and concurrency must be between 1 and 8",
    );
  }
  let next = 0;
  let failure;
  const lane = async (index) => {
    while (failure === undefined && next < total) {
      const job = next++;
      try {
        await run(job, index);
      } catch (error) {
        failure ??= error instanceof Error ? error : new Error(String(error));
      }
    }
  };
  await Promise.all(
    Array.from({ length: Math.min(total, concurrency) }, (_, i) => lane(i)),
  );
  if (failure !== undefined) throw failure;
}
