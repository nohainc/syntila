# Echo plugin (Python)

A standard-library-only Worker Plugin Protocol 1.0 example with progress and
persisted sessions. It echoes at most 200 prompt characters and makes no network
requests. Run it with Python 3; on POSIX the executable script uses the user's
`python3` from PATH. That interpreter is not digest-pinned.

For a local package, copy `echo.py` into `bin/echo.py`, create a `plugin.json`
from the author guide with identity `echo-python`, version `1.0.0`, artifact
command `bin/echo.py`, and capabilities
`{"progress":true,"sessionResume":true}`. Use the SDK `pack` tool to fill the
script hash, then run the standalone conformance command on the package.
On Windows, package a standalone executable instead of relying on a shebang.

This example finishes each request immediately. For longer-running work, use a
separate worker thread or process so the input loop can answer pings and handle
cancel while work runs. Keep stdout exclusively for protocol frames.
