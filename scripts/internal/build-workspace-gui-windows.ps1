[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')][string]$Mode = 'release',
    [switch]$GuiOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'Build the Workspace GUI on a Windows host.' }
$Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$Gui = Join-Path $Root 'apps/workspace_gui'
$Variant = if ($env:SYNTILA_WORKSPACE_ENVIRONMENT -eq 'local') { 'windows-local' } else { 'windows' }
$Bundle = Join-Path $Root "dist/syntila/$Variant/$Mode"
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) { throw 'Flutter is required.' }
if (-not $GuiOnly) { & (Join-Path $PSScriptRoot 'build-workspace-windows.ps1') -Mode $Mode }
if (-not (Test-Path (Join-Path $Bundle 'syntila.exe'))) { throw 'Build the Workspace CLI bundle first.' }
Push-Location $Gui
try {
    & flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed.' }
    $Version = ((Select-String -Path (Join-Path $Root 'apps/workspace/pubspec.yaml') -Pattern '^version:').Line -replace '^version:\s*', '').Trim().Split('+')[0]
    if ($env:SYNTILA_WORKSPACE_VERSION) { $Version = $env:SYNTILA_WORKSPACE_VERSION }
    & flutter build windows "--$Mode" "--build-name=$Version"
    if ($LASTEXITCODE -ne 0) { throw 'flutter build windows failed.' }
    $Configuration = if ($Mode -eq 'release') { 'Release' } else { 'Debug' }
    $BuiltGui = Join-Path $Gui "build/windows/x64/runner/$Configuration"
    if (-not (Test-Path (Join-Path $BuiltGui 'syntila-workspace-gui.exe'))) { throw 'Workspace GUI executable is missing.' }
    $Destination = Join-Path $Bundle 'gui'
    if (Test-Path $Destination) { Remove-Item -Recurse -Force $Destination }
    Copy-Item $BuiltGui $Destination -Recurse -Force
    $Suffix = if ($Variant -eq 'windows-local') { '-local' } else { '' }
    $Archive = Join-Path $Root "dist/syntila/syntila-workspace-windows-x64-$Mode$Suffix-preview.zip"
    Compress-Archive -Path "$Bundle/*" -DestinationPath $Archive -Force
    Write-Host "Built Windows Workspace bundle with GUI: $Archive"
} finally { Pop-Location }
