#!/usr/bin/env python3
"""Worker Plugin Protocol 1.0 reference; standard library only."""
import hashlib
import json
import pathlib
import sys


def send(frame):
    print(json.dumps(frame, ensure_ascii=True, separators=(",", ":")), flush=True)


def main():
    data = None
    for line in sys.stdin.buffer:
        try:
            if len(line) > 1024 * 1024:
                raise ValueError("oversize")
            frame = json.loads(line)
            kind = frame.get("type")
            request_id = frame.get("id")
            if kind == "hello":
                if "1.0" not in frame["protocol"]["supported"]:
                    send({"type": "error", "code": "unsupported_protocol",
                          "message": "Protocol 1.0 required", "retryable": False})
                    return
                data = pathlib.Path(frame["dataDir"])
                send({"type": "hello.result", "id": request_id, "protocol": "1.0",
                      "plugin": {"id": "echo-python", "version": "1.0.0",
                                 "name": "Echo (Python)"},
                      "capabilities": {"progress": True, "sessionResume": True}})
            elif kind == "probe" and data is not None:
                send({"type": "probe.result", "id": request_id,
                      "state": "ready", "checks": []})
            elif kind == "execute" and data is not None:
                session = frame.get("session")
                state = None
                if session:
                    # Hash opaque keys rather than interpreting them as paths.
                    key = hashlib.sha256(session["key"].encode()).hexdigest()
                    target = data / "sessions" / key
                    if session["mode"] == "resume":
                        if not target.exists():
                            send({"type": "error", "id": request_id,
                                  "code": "session_not_found", "message": "No such session",
                                  "retryable": True})
                            continue
                        state = "resumed"
                    else:
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_text("seen", encoding="utf-8")
                        state = "created"
                send({"type": "progress", "id": request_id, "message": "Reading request"})
                result = {"type": "result", "id": request_id,
                          "output": "echo: " + frame["prompt"][:200], "artifacts": []}
                if state:
                    result["session"] = {"state": state}
                send(result)
            elif kind == "ping":
                send({"type": "pong", "nonce": frame["nonce"]})
            elif kind == "shutdown":
                return
            elif kind in ("cancel", "pong"):
                # Work above completes synchronously before the next frame.
                pass
            else:
                send({"type": "error", "id": request_id, "code": "unsupported_frame",
                      "message": "Unknown frame", "retryable": False})
        except (ValueError, TypeError, KeyError):
            send({"type": "error", "code": "unsupported_frame",
                  "message": "Invalid frame", "retryable": False})


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, OSError):
        # Diagnostics must never enter stdout.
        sys.exit(1)
