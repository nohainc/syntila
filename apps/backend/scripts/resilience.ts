// The retired test depended on a removed Worker gateway. Fail before any
// restart or credential changes until a current Worker reconnect test exists.
console.error("Worker resilience acceptance is unavailable: the test needs a current Connect client. No restart was performed.");
process.exit(1);
