# Plugin filesystem and network isolation evidence

Production plugin launches still report isolation tier `none` and
`readOnlyEnforced: false`. Read-only Steps remain ineligible. This document
records a facility experiment, not production sandbox acceptance.

## macOS facility check

Run `node scripts/plugin-isolation-acceptance.mjs` on macOS. The check creates
and removes private temporary work/data directories and a loopback TCP listener.
It first proves the unrestricted target can perform every tested operation,
then launches the same target with `/usr/bin/sandbox-exec` and verifies:

| Operation | Unrestricted control | Restricted target |
| --- | --- | --- |
| Overwrite an existing Work file | Allowed | Denied |
| Create a Work file | Allowed | Denied |
| Write into Work through a symlink in the data directory | Allowed | Denied |
| Write into the data directory | Allowed | Allowed |
| Connect to the local TCP listener | Allowed | Denied |

The check fails on unexpected access, a failed control, target failure or a
network timeout. It prints structured evidence without temporary paths or
credentials. It rejects unsupported platforms instead of recording a pass.

On 2026-11-04, macOS arm64 on the development host passed all five probes.
The initial experiment exposed a profile-path mismatch: the temporary directory
was spelled under `/var`, while macOS evaluated its canonical `/private/var`
path. Canonicalizing the root before writing the policy made write denial take
effect. Any production implementation must resolve paths before policy creation
and test the resulting launch; textual paths alone are insufficient evidence.

## Limits and remaining integration

This experimental policy starts with `allow default`, denies network operations,
and denies writes under one canonical Work directory. It allows reads and writes
elsewhere, including the user's home. It does not demonstrate containment of
arbitrary malicious code, inherited descriptors, alternate filesystem paths,
mount changes, process escape, provider logins or descendant behavior. The target
is a Node executable rather than the packaged Engine/plugin chain.

Before reporting a production tier, integrate policy application inside the
Engine's limited launcher, define the exact filesystem/network access contract,
check descendants and escape attempts, and bind executable self-test evidence to
the actual launch. Propagate that evidence through Service readiness and Cloud
eligibility with fail-closed behavior. Retain signed/installed release evidence;
this development-host result does not establish launchd, TCC or notarization
behavior. Linux and Windows filesystem/network facilities still require their
own implementation and evidence.
