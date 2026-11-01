# Windows Workspace releases

The manually dispatched [Windows release workflow](../../.github/workflows/release-windows.yml)
builds the Windows x64 bundle, Authenticode-signs every executable and DLL,
builds a signed Inno Setup installer (Setup.exe and its embedded uninstaller),
tests install/upgrade/uninstall on the signed installer and, when `publish` is
set, attaches the installer, ZIP and `SHA256SUMS` to an immutable GitHub
Release tagged `workspace-windows-v<version>`.

Signing is done by [`scripts/sign-workspace-windows.ps1`](../../scripts/sign-workspace-windows.ps1).
Every signature uses SHA-256 and an RFC 3161 timestamp, and is verified with
`signtool verify /pa` and `Get-AuthenticodeSignature` before packaging and again
on the installer. The headless bundle contains `syntila.exe` and
`assets/engines/syntila-agent.exe`; both are signed before packaging.

## One-time setup

1. **Get a code-signing identity.** Pick one:
   - **Azure Trusted Signing (recommended).** Create a Trusted Signing account
     and complete public identity validation for the publishing organization,
     then create a *Public Trust* certificate profile. Create an Entra ID app
     registration with a client secret and grant it the
     *Trusted Signing Certificate Profile Signer* role on the account.
     The signing key stays in Azure; device qualification still includes SmartScreen.
   - **Certificate file (OV).** Buy an OV code-signing certificate that the CA
     will issue as an exportable PFX. EV and most new OV certificates are only
     issued on hardware tokens/HSMs and cannot be used with this backend; use
     Azure Trusted Signing instead.
2. **Create the `workspace-windows-release` GitHub environment.** Restrict
   deployment to `main` and require a reviewer.
3. **Configure the environment.**

   | Kind | Name | Value |
   | --- | --- | --- |
   | variable | `SYNTILA_WINDOWS_SIGNING` | `azure` or `pfx` |
   | variable | `SYNTILA_RELEASE_TRUST_KEYS_JSON` | production public trust roots (repository variable, as for macOS) |
   | variable (azure) | `SYNTILA_WINDOWS_TRUSTED_SIGNING_ENDPOINT` | regional endpoint, e.g. `https://eus.codesigning.azure.net` |
   | variable (azure) | `SYNTILA_WINDOWS_TRUSTED_SIGNING_ACCOUNT` | Trusted Signing account name |
   | variable (azure) | `SYNTILA_WINDOWS_TRUSTED_SIGNING_PROFILE` | certificate profile name |
   | variable (azure, optional) | `SYNTILA_WINDOWS_TRUSTED_SIGNING_CLIENT_VERSION` | `Microsoft.Trusted.Signing.Client` NuGet version (default `1.0.53`) |
   | secret (azure) | `SYNTILA_WINDOWS_AZURE_TENANT_ID` | Entra tenant ID |
   | secret (azure) | `SYNTILA_WINDOWS_AZURE_CLIENT_ID` | app registration client ID |
   | secret (azure) | `SYNTILA_WINDOWS_AZURE_CLIENT_SECRET` | app registration secret |
   | secret (pfx) | `SYNTILA_WINDOWS_CERTIFICATE_PFX` | base64 of the `.pfx` (`base64 -i cert.pfx`) |
   | secret (pfx) | `SYNTILA_WINDOWS_CERTIFICATE_PASSWORD` | PFX password |
   | variable (pfx, optional) | `SYNTILA_WINDOWS_TIMESTAMP_URL` | RFC 3161 server (default DigiCert) |

## Selected backend: Azure Artifact Signing Basic

Artifact Signing is Microsoft's current name for Trusted Signing. Syntila's
existing `SYNTILA_WINDOWS_TRUSTED_SIGNING_*` variable names remain unchanged.
The GitHub environment selects `SYNTILA_WINDOWS_SIGNING=azure`.

### First activation

1. Create a paid Azure pay-as-you-go subscription. Free, trial and sponsored
   subscriptions are not supported. Complete billing and identity checks in
   Azure, not in repository files or chat.
2. Confirm publisher eligibility before creating the paid signing account.
   EU-registered organizations qualify for public identity validation;
   individual applicants currently must be based in the US or Canada. Use the
   publisher's actual legal name; approval remains Microsoft's decision.
3. In Azure Portal, open Subscriptions → your subscription → Resource providers
   and register `Microsoft.CodeSigning`.
4. Create an **Artifact Signing Account**, selecting **Basic** and an available
   region. Suggested resource group: `syntila-signing`; suggested account name:
   `syntilasigning` (subject to availability). Record the actual account name
   and regional endpoint shown by Azure.
5. In the account's Access control (IAM), assign your onboarding user the
   **Artifact Signing Identity Verifier** role if needed. Submit an
   organization **Public** identity validation and complete Microsoft's email
   and document checks. Validation must finish before production signing.
6. Create a **Public Trust** certificate profile, for example
   `workspace-public`, linked to the approved identity. Public Trust Test and
   Private Trust profiles are not production signing identities.
7. Create a dedicated Entra app registration for GitHub releases. Grant its
   service principal the certificate profile signer role using Azure IAM at
   the intended signing scope. Add its tenant ID, client ID and client secret
   to the GitHub environment secrets listed above. Set the endpoint, account
   and profile variables to the real Azure values. Never commit the secret.
8. Run the signed release dry run, qualify the signed installer, and publish
   only after the release CI gate passes.

### Infrequent releases and stopping signing charges

Basic is listed at USD 9.99 per month for 5,000 signatures, with overage billed
separately. Microsoft states that the SKU charge is not prorated; confirm local
currency, taxes and billing periods in Azure. Annual totals based on active
months are estimates, not a guaranteed invoice.

After successful publication, download and retain the signed artifacts and
checksums. If no further signing is needed, delete only the intended
**Artifact Signing Account** to stop its future account charges. Deleting only
the certificate profile is insufficient. Do not delete the subscription,
resource group or identity validation as a shortcut. Account deletion removes
its profiles but does not invalidate certificates already used for signing.
Existing signatures still depend on their normal trust and timestamp checks.

Identity validations remain at subscription scope. On the next activation,
create an account and a new Public Trust profile and select the retained
validation while it remains valid. Recheck or recreate signer role assignments
and update GitHub account/profile/endpoint variables before signing again.
Deletion disables future signing until this setup is restored. A subscription
may still have charges from other Azure resources.

References, checked 2026-10-27:
[Microsoft setup guide](https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart),
[billing and deletion FAQ](https://learn.microsoft.com/en-us/azure/artifact-signing/faq),
and [Basic pricing](https://learn.microsoft.com/en-us/azure/artifact-signing/how-to-change-sku).

## Publishing a release

1. Set `version:` in `apps/workspace/pubspec.yaml` to the release version
   (`X.Y.Z`; prerelease versions are not packaged) and push to `main`.
2. Wait for CI on that commit to succeed.
3. Dry run: dispatch **Workspace / Windows / Release** from `main` with
   `publish` unchecked. The workflow reads the version from `apps/workspace/pubspec.yaml`.
   Download the `syntila-workspace-windows-x64-release`
   artifact and qualify it on a real Windows 10/11 x64 device (see below).
4. Publish: dispatch again with `publish` checked. The workflow requires the
   CI gate, rebuilds and re-signs, and creates the GitHub Release. Existing tags
   are never overwritten; bump the version to ship a fix.

## Device qualification before announcing

- Right-click Setup.exe → Properties → Digital Signatures shows the Syntila
  publisher with a timestamp; `Get-AuthenticodeSignature` reports `Valid` for
  Setup.exe, `syntila.exe` and the Engine.
- The installer UAC/SmartScreen prompt names the publisher (no "Unknown
  publisher").
- Sign-in, registration, service install/start, a real provider assignment,
  logon/reboot recovery, upgrade over the previous version and uninstall
  (`syntila service uninstall` first) all work; see
  [the installer notes](../operations/WORKSPACE_WINDOWS_INSTALLER.md).
- Run `sha256sum -c SHA256SUMS` against the downloaded release assets.

## Notes

- The Cloud `/api/workspace-releases` catalog is keyed by version alone and
  currently carries the macOS archive, so Windows releases are distributed via
  GitHub Releases and not through the in-app updater. Adding per-platform
  packages to the catalog is a separate Cloud schema change.
- SmartScreen reputation with an OV certificate accrues per certificate over
  downloads; expect warnings for early releases. Check actual SmartScreen behavior on a Windows device.
- When a certificate is renewed or rotated, earlier timestamped releases stay
  valid. Revoke compromised certificates with the CA/Azure and re-release.

## Current release prerequisites

The release environment is `workspace-windows-release`. Add signing secrets
through GitHub Settings → Environments → workspace-windows-release; never
commit certificates or secrets. Windows packaging uses the unified Dart CLI
and `run` service command, without a Flutter UI or a second service executable.
The installer does not automatically register or start the service. After
installation, run `syntila.exe service install` and `setup` from
PowerShell in the installation directory. No runtime-state migration is added.

The pinned Trusted Signing client `1.0.53` was confirmed in the official NuGet
version index on 2026-10-27. Signing and device qualification still require a
configured public-trust signing identity and a Windows host.
