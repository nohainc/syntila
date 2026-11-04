# Plugin resource-limit acceptance

The Engine's plugin path now applies resource limits; this is not sandbox
acceptance and does not change the reported isolation tier from `none`.
Read-only Steps remain ineligible.

## Implementation

- Private `--plugin-child` mode applies limits before starting plugin code.
  POSIX replaces the child via `execv`; no shell or additional packaged helper
  is used. Windows launches the plugin inside a bounded nested Job Object.
- POSIX: hard CPU time of 3,600 seconds **per process**, 256 open files per
  process, and zero-size core dumps. Inherited lower hard limits are preserved.
- Windows: 1 GiB aggregate committed job memory, 3,600 seconds job user CPU,
  and 66 active processes including launcher, plugin and up to 64 descendants.
  The retained job handle kills descendants on launcher exit.
- POSIX: one-second observed samples sum descendant RSS (including shared pages)
  and refuse more than 64 descendants. The sampler uses the system `/bin/ps`.
  This is not a hard memory/process-count guarantee: transient spikes, a
  concurrently changing process tree and detached/reparented processes can evade
  samples. RSS accounting may also stop a run before unique memory reaches 1 GiB.
- Every platform: preflight plus periodic inspection of the plugin data directory
  stops work above 512 MiB or 100,000 entries. Symlinks are not traversed. This is
  an observed logical-size quota, not a disk reservation or filesystem quota.
- Failed limit setup never starts plugin code. Failed resource inspection stops
  work. Runtime breaches use local `plugin_resource_limit`, mapped to the
  existing non-retryable provider-failure wire issue. Conformance uses the same
  launch path and monitoring; the standalone author launcher remains unrestricted.

## Executable evidence on macOS arm64

The tests run on macOS 26.6.2 (25G83), arm64, on the development host,
not a notarized Workspace release:

- `plugin_process_limits_test.dart`: the target reads its actual hard limits;
  excess file opens are refused; a busy loop is terminated with a one-second
  CPU limit; invalid setup is rejected before target execution.
- `plugin_resource_monitor_test.dart`: tree RSS/count accounting, data size and
  entry caps, no symlink traversal, preflight refusal, and real-process memory
  breach observation with termination.
- `plugin_host_test.dart`: a resource breach ends work and the plugin is dead
  after host cleanup.
- `plugin_conformance_engine_test.dart`: the compiled SDK example passes all
  21 cases through the limited Engine child path, including session resume.

## Outstanding acceptance

- Run the POSIX tests on Linux x64/arm64. No Linux execution evidence is claimed.
- Run the Windows job-inheritance test (`windows_limit_probe.dart`) on Windows
  x64. The new `plugin-limits-windows` CI job runs it on engine changes;
  it queries the target's actual inherited job flags and limits. Add and
  retain Windows memory/CPU/process-exhaustion and cleanup evidence before
  release; these native calls are not exercised by macOS tests.
- Defaults are fixed in this implementation. Manifest `limits.memoryMiB` does
  not raise the host ceiling; per-plugin lower-limit configuration is not wired.
- Windows has no implemented open-handle quota. POSIX CPU limits are not an
  aggregate descendant-tree budget. Filesystem/network isolation is absent.
- Retain signed/release Workspace evidence, including stop/crash and detached
  descendants; this development run does not establish launchd/TCC/notarization
  or Linux/Windows host integration claims.

## Native contracts

- [Apple setrlimit](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/setrlimit.2.html)
- [Linux resource limits](https://man7.org/linux/man-pages/man2/setrlimit.2.html)
- [Windows basic job limits](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-jobobject_basic_limit_information)
- [Windows extended job limits](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-jobobject_extended_limit_information)
