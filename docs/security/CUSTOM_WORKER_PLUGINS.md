# Installing custom Worker plugins

A custom Worker is a program you choose to run on your computer. It executes
under your local user account and may be able to access your files, network and
existing provider logins. A process boundary is not a sandbox.

## Before consenting

Review the origin, author, version, manifest digest, executable digest and
requested access shown by `syntila plugins register` and `enable`. Check the
source or obtain the package through an author you trust. Access declarations
explain the author's intent; they do not restrict the operating system.

A signature proves possession of a signing key. Verify the fingerprint through
a separate trusted source. A self-signed package is not independently reviewed.
A successful conformance test proves protocol behavior only, not safety,
confidentiality, output quality or compliance with access declarations.

The current host checks the pinned executable digest before launch, builds an
allow-listed environment, redacts diagnostics, bounds protocol frames and work
time, and supervises cancellation and process cleanup. Filesystem/network
isolation is not implemented. POSIX has hard CPU/open-file limits plus observed
memory and process-count checks; Windows uses job memory, process-count and CPU
limits (device validation pending). Data size is observed on all platforms.
Sampling can miss short spikes; Windows handle quotas remain unimplemented.
See [resource-limit evidence](../acceptance/PLUGIN_RESOURCE_LIMITS.md). The reported
isolation tier is `none`; read-only Steps are ineligible for plugins.

## Install, test and consent

```sh
syntila plugins import /path/to/package
syntila plugins validate my-plugin
syntila plugins test my-plugin
syntila plugins register my-plugin
syntila plugins enable my-plugin
```

`register` and `enable` show the proposed consent and its hash. Review it before
repeating the command with `--accept <hash>`. Each Workspace needs its own
explicit enablement. Updated content changes the pinned digest and needs new
consent. For interpreted plugins, the system interpreter is outside the pinned
script digest; prefer a self-contained executable from the author.

Keep credentials in the provider's local login mechanism. Do not put keys in a
manifest, prompt, package, log or plugin data directory. Syntila does not supply
managed provider credentials. Redaction cannot guarantee a plugin will keep
secrets confidential.

## Disable, export or remove

Use `syntila plugins disable my-plugin` to stop future scheduling on this
Workspace. Review existing running work separately. Use `syntila plugins export
my-plugin /path/to/export.syntila-plugin` to transfer a credential-free bundle;
exports exclude plugin data, sessions, logs, entitlement leases and credentials.
They still contain executable code and author metadata.

A lapsed Plus entitlement prevents new plugin starts after the locally trusted
lease expires or the Service learns of the lapse. A signed lease allows at most
24 hours of offline use, capped by the plan period end. Existing work may drain
for at most 30 minutes after lapse is observed. Files are retained and exports
remain available. See the [operations runbook](../operations/CUSTOM_WORKER_PLUGINS_OPERATIONS.md)
for provisioning, key rotation and diagnosis.

For a suspected malicious plugin, stop the service to terminate supervised work,
then investigate with your normal host security tools. Disabling or removing a
plugin does not undo changes it already made to user files or external services.
