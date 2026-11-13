// Ticks a shared counter once per real millisecond; fake timers on the main
// thread do not affect this worker.
declare const self: Worker;
self.onmessage = (e: MessageEvent) => {
  const ticks = new Int32Array(e.data as SharedArrayBuffer);
  const pause = new Int32Array(new SharedArrayBuffer(4));
  for (;;) { Atomics.wait(pause, 0, 0, 1); Atomics.add(ticks, 0, 1); }
};
