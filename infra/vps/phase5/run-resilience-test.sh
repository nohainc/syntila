#!/usr/bin/env bash
# Worker restart acceptance is unavailable until it uses a current Connect client.
set -euo pipefail
echo "Worker resilience acceptance is unavailable; no keys or services were changed." >&2
exit 1
