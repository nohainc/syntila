[CmdletBinding()]
param(
    [string]$Compiler = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Root = Split-Path $PSScriptRoot -Parent
$Bundle = Join-Path $Root 'dist/connect/windows/release'
$Output = Join-Path $Root 'dist/connect/installer'
if (-not (Test-Path $Compiler)) { throw 'Inno Setup 6 ISCC.exe is required.' }
foreach ($File in @('syntila-connect.exe', 'syntila-worker.exe', 'Syntila Connect.exe')) {
    if (-not (Test-Path (Join-Path $Bundle $File))) { throw "Missing Connect release bundle file: $File" }
}
$VersionLine = (Select-String -Path (Join-Path $Root 'apps/connect/pubspec.yaml') -Pattern '^version:').Line
$Version = ($VersionLine -replace '^version:\s*', '').Trim().Split('+')[0]
if ($env:SYNTILA_CONNECT_VERSION) { $Version = $env:SYNTILA_CONNECT_VERSION }
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Unsupported installer version: $Version" }
New-Item -ItemType Directory -Force $Output | Out-Null
$CompilerArguments = @("/DBundleDir=$Bundle", "/DAppVersion=$Version", "/DOutputDir=$Output")
& $Compiler @CompilerArguments (Join-Path $Root 'packaging/windows/connect.iss')
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed: $LASTEXITCODE" }
$Installer = Join-Path $Output "Syntila-Connect-$Version-windows-x64-Setup.exe"
if (-not (Test-Path $Installer)) { throw 'Installer was not produced.' }
Get-FileHash $Installer -Algorithm SHA256 | Format-List
