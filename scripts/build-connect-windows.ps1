[CmdletBinding()]
param(
    [switch]$Production,
    [switch]$SkipGui
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') {
    throw 'Build Syntila Connect for Windows on a Windows host.'
}
if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
    throw 'This Windows build requires an x64 host.'
}
$Root = Split-Path $PSScriptRoot -Parent
$ConnectDir = Join-Path $Root 'apps/connect'
$EngineDir = Join-Path $Root 'engines/cli_worker'
$GuiDir = Join-Path $Root 'apps/connect_gui'

foreach ($Tool in @('dart', 'node')) {
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) {
        throw "$Tool is required."
    }
}
if (-not $SkipGui -and -not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw 'Flutter is required for the Connect GUI (use -SkipGui to build the CLI and Engine only).'
}

if ($Production) {
    $TrustRoots = if ($env:SYNTILA_PROFILE_TRUST_ROOTS) { $env:SYNTILA_PROFILE_TRUST_ROOTS } else { $env:SYNTILA_RELEASE_TRUST_KEYS_JSON }
    $UpdateKeys = if ($env:SYNTILA_UPDATE_KEYS) { $env:SYNTILA_UPDATE_KEYS } else { '' }
    if (-not $TrustRoots) {
        throw 'A production build needs SYNTILA_PROFILE_TRUST_ROOTS (or SYNTILA_RELEASE_TRUST_KEYS_JSON).'
    }
} else {
    & node (Join-Path $Root 'scripts/setup-local-profile-signing.mjs')
    if ($LASTEXITCODE -ne 0) { throw "setup-local-profile-signing.mjs failed: $LASTEXITCODE" }
    $TrustRoots = Get-Content (Join-Path $Root '.development/local-profile-signing/trust-roots.json') -Raw
    $UpdateKeys = if ($env:SYNTILA_UPDATE_KEYS) { $env:SYNTILA_UPDATE_KEYS } else { '' }
}

$EngineVersionLine = (Select-String -Path (Join-Path $EngineDir 'pubspec.yaml') -Pattern '^version:').Line
$EngineVersion = ($EngineVersionLine -replace '^version:\s*', '').Trim().Split('+')[0]

$ConnectVersionLine = (Select-String -Path (Join-Path $ConnectDir 'pubspec.yaml') -Pattern '^version:').Line
$ConnectVersion = ($ConnectVersionLine -replace '^version:\s*', '').Trim().Split('+')[0]
if ($env:SYNTILA_CONNECT_VERSION) { $ConnectVersion = $env:SYNTILA_CONNECT_VERSION }
if ($ConnectVersion -notmatch '^\d+\.\d+\.\d+$') { throw "Unsupported Connect version: $ConnectVersion" }

$Variant = if ($Production) { 'release' } else { 'local' }
$Bundle = Join-Path $Root "dist/connect/windows/$Variant"
if (Test-Path $Bundle) { Remove-Item -Recurse -Force $Bundle }
New-Item -ItemType Directory -Force (Join-Path $Bundle 'engine') | Out-Null

Write-Host "Building Engine $EngineVersion..."
Push-Location $EngineDir
try {
    & dart pub get
    if ($LASTEXITCODE -ne 0) { throw "Engine dart pub get failed: $LASTEXITCODE" }
    & dart compile exe "-DENGINE_VERSION=$EngineVersion" bin/syntila_cli_worker.dart -o (Join-Path $Bundle 'engine/syntila-worker.exe')
    if ($LASTEXITCODE -ne 0) { throw "Engine dart compile exe failed: $LASTEXITCODE" }
} finally { Pop-Location }

Write-Host "Building Syntila Connect CLI $ConnectVersion ($Variant)..."
Push-Location $ConnectDir
try {
    & dart pub get
    if ($LASTEXITCODE -ne 0) { throw "Connect dart pub get failed: $LASTEXITCODE" }
    & dart compile exe `
        "--define=SYNTILA_PROFILE_TRUST_ROOTS=$TrustRoots" `
        "--define=SYNTILA_UPDATE_KEYS=$UpdateKeys" `
        bin/syntila_connect.dart -o (Join-Path $Bundle 'syntila-connect.exe')
    if ($LASTEXITCODE -ne 0) { throw "Connect dart compile exe failed: $LASTEXITCODE" }
} finally { Pop-Location }

if (-not $SkipGui) {
    Write-Host "Building Syntila Connect GUI (apps/connect_gui)..."
    Push-Location $GuiDir
    try {
        if (-not (Test-Path (Join-Path $GuiDir 'windows'))) {
            & flutter create --platforms=windows --project-name syntila_connect_gui .
            if ($LASTEXITCODE -ne 0) { throw "flutter create --platforms=windows failed: $LASTEXITCODE" }
        }
        & flutter pub get
        if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed: $LASTEXITCODE" }
        & flutter build windows --release "--build-name=$ConnectVersion"
        if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed: $LASTEXITCODE" }
        $BuiltGui = Join-Path $GuiDir 'build/windows/x64/runner/Release'
        if (-not (Test-Path (Join-Path $BuiltGui 'syntila_connect_gui.exe'))) {
            throw 'Connect GUI executable (syntila_connect_gui.exe) is missing.'
        }
        Copy-Item "$BuiltGui/*" $Bundle -Recurse -Force
    } finally { Pop-Location }
}

foreach ($File in @('syntila-connect.exe', 'engine/syntila-worker.exe')) {
    if (-not (Test-Path (Join-Path $Bundle $File))) { throw "Bundle is missing $File" }
}

$Archive = Join-Path $Root "dist/connect/Syntila-Connect-$ConnectVersion-windows-x64-portable.zip"
Compress-Archive -Path "$Bundle/*" -DestinationPath $Archive -Force
Write-Host "Built Syntila Connect Windows bundle: $Bundle"
Write-Host "Built portable archive: $Archive"
