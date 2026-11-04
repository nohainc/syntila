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
  A second, observed 3,600-second CPU budget accumulates sampled CPU across the
  launch's process tree. Per-process high-water values survive child exit;
  repeated samples and decreasing counters do not reset the total. PID and
  start-time identity distinguish ordinary PID reuse. History is bounded to
  4,096 observed process identities; exceeding it stops work.
- Windows: 1 GiB aggregate committed job memory, 3,600 seconds job user CPU,
  and 66 active processes including launcher, plugin and up to 64 descendants.
  The retained job handle kills descendants on launcher exit. The launcher
  also samples the private job's aggregate executive-handle count every second
  and exits above 4,096 handles (including launcher overhead), closing the job.
  This is an observed handle budget, not a kernel file-descriptor quota.
  Failed native handle inspection also stops the job.
- POSIX: one-second observed samples sum descendant RSS (including shared pages)
  and refuse more than 64 descendants. The sampler uses the system `/bin/ps`.
  This is not a hard memory/process-count guarantee: transient spikes, a
  concurrently changing process tree and detached/reparented processes can evade
  samples. CPU from children born and reaped between samples is not counted;
  cumulative CPU remains a sampled lower bound, not a hard aggregate guarantee.
  RSS accounting may also stop a run before unique memory reaches 1 GiB.
- Every platform: preflight plus periodic inspection of the plugin data directory
  stops work above 512 MiB or 100,000 entries. Symlinks are not traversed. This is
  an observed logical-size quota, not a disk reservation or filesystem quota.
- Failed limit setup never starts plugin code. Failed resource inspection stops
  work. POSIX/data monitor breaches use local `plugin_resource_limit`, mapped to
  the existing non-retryable provider-failure issue. Windows launcher observation
  failures exit with a safe stderr diagnostic; the parent reports process failure,
  as it does for a native hard-limit termination. Conformance uses the same launch
  path and monitoring; the standalone author launcher remains unrestricted.

## Executable evidence on macOS arm64

The tests run on macOS 26.6.2 (25G83), arm64, on the development host,
not a notarized Workspace release:

- `plugin_process_limits_test.dart`: the target reads its actual hard limits;
  excess file opens are refused; a busy loop is terminated with a one-second
  CPU limit; invalid setup is rejected before target execution.
- `plugin_resource_monitor_test.dart`: tree RSS/count accounting, data size and
  entry caps, no symlink traversal, preflight refusal, and real-process memory
  breach observation with termination. CPU tests cover BSD/Linux formats,
  aggregation, exited children, counter high-water marks, PID reuse, bounded
  history and a real multi-process CPU workload whose total breaches the budget
  while each child stays below it.
- `plugin_windows_handles_test.dart`: injected handle-query policy tests cover
  breach, inspection failure and monitor shutdown on every host. The native
  Windows handle-exhaustion case is in `plugin_process_limits_test.dart` and
  requires a Windows runner.
- `plugin_host_test.dart`: a resource breach ends work and the plugin is dead
  after host cleanup.
- `plugin_conformance_engine_test.dart`: the compiled SDK example passes all
  21 cases through the limited Engine child path, including session resume.

The default Engine component validator runs the Engine's process-heavy test
files serially, retaining all existing deadlines. This avoids simultaneous JIT
startups starving each other on busy development hosts. Shared protocol/runtime
package tests retain their normal execution configuration. On the final runtime
source, the local Engine regression suite passed 162 tests with seven skips in
serial mode; Workspace validation passed 646 tests with 22 skips and the headless
Service compile/start/stop smoke check. The prior parallel Engine run hit process
startup timeouts; test deadlines were not relaxed.

## Hosted platform evidence

[Focused acceptance run 41819141616](https://github.com/nohainc/syntila/actions/runs/41819141616)
passed on source commit `87dfc5727a6a645e812be222169781648cd4be1c`:

| Runner | Result | Native checks exercised |
| --- | --- | --- |
| [Ubuntu 24.04 x64](https://github.com/nohainc/syntila/actions/runs/41819141616/job/126537572841) | 17 passed, 5 platform skips | Actual inherited CPU/file/core limits, file exhaustion, hard CPU termination, sampled memory/aggregate CPU termination |
| [Ubuntu 24.04 arm64](https://github.com/nohainc/syntila/actions/runs/41819141616/job/126537570825) | 17 passed, 5 platform skips | Same POSIX native and sampled checks on arm64 |
| [Windows Server 2022 x64](https://github.com/nohainc/syntila/actions/runs/41819141616/job/126537571746) | 17 passed, 5 platform skips | Actual inherited private-job limits; executive-handle exhaustion; committed memory refusal; CPU termination; simultaneous process refusal |

The matrix also runs accounting, data-quota and monitor-policy tests. It builds
AOT Engine/fixture executables on each hosted OS. Each test log is retained as a
`plugin-resources-<runner>` artifact on that run. This does not establish signed
Workspace release, user-service lifecycle or deployed Cloud acceptance.

The native Linux check caught a cross-platform FFI bug: `RLIM_INFINITY` is
`UINT64_MAX` on Linux and reads as `-1` in Dart's 64-bit integer representation.
The launcher now clamps that sentinel to the requested finite limit rather than
preserving unlimited CPU/core settings. Reading actual target limits and killing
a busy target cover this regression on both Linux architectures.

Reproduce only the focused checks with:

```sh
gh workflow run ci.yml --ref feat/custom-plugins-p2 -f plugin_acceptance_only=true
```

The dispatch skips unrelated component builds and deployments. The normal CI
workflow remains unchanged unless this explicit boolean input is set.

## Outstanding acceptance

- Defaults are fixed in this implementation. Manifest `limits.memoryMiB` does
  not raise the host ceiling; per-plugin lower-limit configuration is not wired.
- Windows handles and aggregate POSIX CPU are observed budgets, not hard kernel
  quotas. Processes born/reaped or detached between samples can evade accounting.
  Filesystem/network isolation remains absent.
- Retain installed/signed Workspace release evidence, including stop/crash and
  detached descendants. Hosted resource tests do not establish launchd/TCC,
  notarization, Linux user-service or Windows logon-task integration claims.

## Native contracts

- [Apple setrlimit](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/setrlimit.2.html)
- [Linux resource limits](https://man7.org/linux/man-pages/man2/setrlimit.2.html)
- [Windows basic job limits](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-jobobject_basic_limit_information)
- [Windows extended job limits](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-jobobject_extended_limit_information)

- [Linux ps CPU time and start-time fields](https://man7.org/linux/man-pages/man1/ps.1.html)
- [Windows process handle counts](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocesshandlecount)
