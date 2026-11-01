[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')][string]$Mode = 'release'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') {
    throw 'Build Workspace for Windows on a Windows host with the Dart SDK.'
}
if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
    throw 'This preview build currently requires a Windows x64 host.'
}
$Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$Workspace = Join-Path $Root 'apps/workspace'
foreach ($Tool in @('dart', 'node', 'git')) {
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) {
        throw "$Tool is required (bash must be Git for Windows Bash, not WSL)."
    }
}
# Resolve Git's Bash explicitly: PATH may point bash at WSL, which would
# compile a Linux Engine and service instead of Windows executables.
$GitRoot = Split-Path (Split-Path (Get-Command git).Source -Parent) -Parent
$GitBash = Join-Path $GitRoot 'bin/bash.exe'
if (-not (Test-Path $GitBash)) { throw 'Git for Windows bin/bash.exe is required.' }
function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}
Push-Location $Root
try {
    # Reuse the canonical Engine and standalone service build, not a second
    # Windows implementation. These scripts select .exe on Git Bash hosts.
    $Trust = & node scripts/resolve-build-release-trust.mjs
    if ($LASTEXITCODE -ne 0) { throw 'Public application-release trust is required.' }
    Invoke-Checked $GitBash @('scripts/internal/build-workspace-service.sh')
    $Variant = if ($env:SYNTILA_WORKSPACE_ENVIRONMENT -eq 'local') { 'windows-local' } else { 'windows' }
    $Output = Join-Path $Root "dist/syntila/$Variant/$Mode"
    New-Item -ItemType Directory -Force $Output | Out-Null
    Get-ChildItem $Output | Remove-Item -Recurse -Force
    $Canonical = Join-Path $Root 'dist/syntila'
    Copy-Item (Join-Path $Canonical 'syntila.exe') $Output
    Copy-Item (Join-Path $Canonical 'assets') $Output -Recurse -Force
    foreach ($File in @('syntila.exe', 'assets/engines/syntila-agent.exe')) {
        if (-not (Test-Path (Join-Path $Output $File))) { throw "Bundle is missing $File" }
    }
    Copy-Item (Join-Path $Root 'docs/operations/WORKSPACE_WINDOWS_PREVIEW.md') (Join-Path $Output 'README.md')
    $Suffix = if ($Variant -eq 'windows-local') { '-local' } else { '' }
    $Archive = Join-Path $Root "dist/syntila/syntila-workspace-windows-x64-$Mode$Suffix-preview.zip"
    Compress-Archive -Path "$Output/*" -DestinationPath $Archive -Force
    Write-Host "Built unsigned Windows CLI preview: $Archive"
    Write-Warning 'Unsigned runtime candidate. Real provider execution, logon/reboot and release signing require qualification on the target Windows device.'
} finally { Pop-Location }
