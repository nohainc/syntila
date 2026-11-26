[CmdletBinding()]
param(
    # Files to sign. Inno Setup passes one quoted path per call.
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Path = @(),
    # Sign every PE file in a Connect bundle instead of explicit files.
    [string]$Bundle,
    # Only verify existing signatures; never sign.
    [switch]$VerifyOnly
)
# Authenticode signing for Windows Connect releases.
#
# Backends (SYNTILA_WINDOWS_SIGNING):
#   azure - Azure Trusted Signing. Requires SYNTILA_WINDOWS_TRUSTED_SIGNING_ENDPOINT,
#           _ACCOUNT, _PROFILE, _DLIB and AZURE_TENANT_ID/AZURE_CLIENT_ID/AZURE_CLIENT_SECRET.
#   pfx   - Certificate file. Requires SYNTILA_WINDOWS_CERTIFICATE_PATH and
#           SYNTILA_WINDOWS_CERTIFICATE_PASSWORD.
# Every signature is RFC 3161 timestamped so it outlives the certificate.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'Authenticode signing requires Windows.' }

function Find-SignTool {
    $Kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/bin'
    $Tool = Get-ChildItem $Kits -Filter signtool.exe -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -eq 'x64' } |
        Sort-Object { [version]($_.Directory.Parent.Name -replace '[^\d.]', '0') } -Descending |
        Select-Object -First 1
    if (-not $Tool) { throw 'signtool.exe from the Windows 10/11 SDK is required.' }
    $Tool.FullName
}

function Require-Env([string]$Name) {
    $Value = [Environment]::GetEnvironmentVariable($Name)
    if (-not $Value) { throw "$Name is required for Windows signing." }
    $Value
}

$Files = @($Path | Where-Object { $_ })
if ($Bundle) {
    if (-not (Test-Path $Bundle)) { throw "Bundle not found: $Bundle" }
    $Files += Get-ChildItem $Bundle -Recurse -File -Include *.exe, *.dll | ForEach-Object FullName
}
if ($Files.Count -eq 0) { throw 'No files to sign.' }
$SignTool = Find-SignTool

if (-not $VerifyOnly) {
    $Backend = Require-Env 'SYNTILA_WINDOWS_SIGNING'
    $Common = @('sign', '/v', '/fd', 'SHA256', '/td', 'SHA256')
    switch ($Backend) {
        'azure' {
            $Dlib = Require-Env 'SYNTILA_WINDOWS_TRUSTED_SIGNING_DLIB'
            foreach ($Name in @('AZURE_TENANT_ID', 'AZURE_CLIENT_ID', 'AZURE_CLIENT_SECRET')) { Require-Env $Name | Out-Null }
            $Metadata = Join-Path ([System.IO.Path]::GetTempPath()) ("syntila-signing-" + [guid]::NewGuid() + '.json')
            @{
                Endpoint = Require-Env 'SYNTILA_WINDOWS_TRUSTED_SIGNING_ENDPOINT'
                CodeSigningAccountName = Require-Env 'SYNTILA_WINDOWS_TRUSTED_SIGNING_ACCOUNT'
                CertificateProfileName = Require-Env 'SYNTILA_WINDOWS_TRUSTED_SIGNING_PROFILE'
                # Only the environment credential; never fall back to developer logins.
                ExcludeCredentials = @('ManagedIdentityCredential', 'WorkloadIdentityCredential',
                    'SharedTokenCacheCredential', 'VisualStudioCredential', 'VisualStudioCodeCredential',
                    'AzureCliCredential', 'AzurePowerShellCredential', 'AzureDeveloperCliCredential',
                    'InteractiveBrowserCredential')
            } | ConvertTo-Json | Set-Content $Metadata -Encoding utf8
            $Arguments = $Common + @('/tr', 'http://timestamp.acs.microsoft.com', '/dlib', $Dlib, '/dmdf', $Metadata)
        }
        'pfx' {
            $Certificate = Require-Env 'SYNTILA_WINDOWS_CERTIFICATE_PATH'
            if (-not (Test-Path $Certificate)) { throw 'The Windows signing certificate file is missing.' }
            $Timestamp = if ($env:SYNTILA_WINDOWS_TIMESTAMP_URL) { $env:SYNTILA_WINDOWS_TIMESTAMP_URL } else { 'http://timestamp.digicert.com' }
            $Arguments = $Common + @('/tr', $Timestamp, '/f', $Certificate,
                '/p', (Require-Env 'SYNTILA_WINDOWS_CERTIFICATE_PASSWORD'))
        }
        default { throw "Unsupported SYNTILA_WINDOWS_SIGNING backend: $Backend" }
    }
    try {
        foreach ($File in $Files) {
            # Timestamp servers are occasionally unavailable; retry before failing the release.
            $Signed = $false
            for ($Attempt = 1; $Attempt -le 3 -and -not $Signed; $Attempt++) {
                & $SignTool @Arguments $File | Out-Host
                if ($LASTEXITCODE -eq 0) { $Signed = $true } else { Start-Sleep -Seconds (5 * $Attempt) }
            }
            if (-not $Signed) { throw "Signing failed: $File" }
        }
    } finally {
        if ($Backend -eq 'azure') { Remove-Item $Metadata -ErrorAction SilentlyContinue }
    }
}

foreach ($File in $Files) {
    & $SignTool verify /pa /all /tw $File | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Signature verification failed: $File" }
    $Signature = Get-AuthenticodeSignature $File
    if ($Signature.Status -ne 'Valid' -or -not $Signature.TimeStamperCertificate) {
        throw "Untrusted or untimestamped signature ($($Signature.Status)): $File"
    }
}
Write-Host "Verified Authenticode signatures on $($Files.Count) file(s)."
