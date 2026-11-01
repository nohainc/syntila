# Run only on a disposable Windows CI runner. Uses an isolated application folder.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Root = Split-Path $PSScriptRoot -Parent
$Installer = @(Get-ChildItem (Join-Path $Root 'dist/syntila/installer/*Setup.exe'))
if ($Installer.Count -ne 1) { throw 'Expected exactly one installer.' }
$Target = Join-Path $env:LOCALAPPDATA 'Programs/Syntila/Workspace-Installer-Test'
function Run-Setup {
    $Process = Start-Process $Installer[0].FullName -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=`"$Target`"") -Wait -PassThru
    if ($Process.ExitCode -ne 0) { throw "Setup failed: $($Process.ExitCode)" }
}
$State = Join-Path $env:LOCALAPPDATA 'Syntila/Workspace/installer-preservation-test.txt'
New-Item -ItemType Directory -Force (Split-Path $State -Parent) | Out-Null
$Sentinel = [guid]::NewGuid().ToString()
Set-Content $State $Sentinel
Run-Setup
$Engine = 'assets/engines/syntila-agent.exe'
foreach ($File in @('syntila.exe', $Engine)) {
    if ((Get-FileHash (Join-Path $Target $File)).Hash -ne
        (Get-FileHash (Join-Path $Root "dist/syntila/windows/release/$File")).Hash) {
        throw "Installed file mismatch: $File"
    }
}
$Gui = 'gui/syntila-workspace-gui.exe'
if (Test-Path (Join-Path $Root "dist/syntila/windows/release/$Gui")) {
    if ((Get-FileHash (Join-Path $Target $Gui)).Hash -ne
        (Get-FileHash (Join-Path $Root "dist/syntila/windows/release/$Gui")).Hash) {
        throw 'Installed GUI executable mismatch.'
    }
    $Shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'Syntila/Syntila Workspace.lnk'
    if (-not (Test-Path $Shortcut)) { throw 'Workspace GUI Start menu shortcut is missing.' }
}
$PreviousService = $env:SYNTILA_TEST_WINDOWS_SERVICE
Push-Location (Join-Path $Root 'apps/workspace')
try {
    $env:SYNTILA_TEST_WINDOWS_SERVICE = Join-Path $Target 'syntila.exe'
    dart test test/windows_service_lifecycle_test.dart
    if ($LASTEXITCODE -ne 0) { throw 'Installed service lifecycle test failed.' }
} finally {
    $env:SYNTILA_TEST_WINDOWS_SERVICE = $PreviousService
    Pop-Location
}
# Repeat installation to exercise the stable AppId upgrade path.
Run-Setup
$TestData = Join-Path $env:RUNNER_TEMP ('workspace-installer-' + [guid]::NewGuid())
$App = Start-Process (Join-Path $Target 'syntila.exe') -ArgumentList @('run', '--data-dir', "`"$TestData`"") -WorkingDirectory $Target -PassThru
try {
    Start-Sleep -Seconds 8
    $App.Refresh()
    if ($App.HasExited) { throw 'Installed service exited early.' }
    $Blocked = Start-Process $Installer[0].FullName -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=`"$Target`"") -Wait -PassThru
    if ($Blocked.ExitCode -eq 0) { throw 'Installer should refuse an active Workspace.' }
} finally {
    if (-not $App.HasExited) { Stop-Process -Id $App.Id -Force; $App.WaitForExit() }
}
if ($env:SYNTILA_WINDOWS_SIGNING) {
    & (Join-Path $PSScriptRoot 'sign-workspace-windows.ps1') (Join-Path $Target 'unins000.exe') -VerifyOnly
}
$Uninstall = Start-Process (Join-Path $Target 'unins000.exe') -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -Wait -PassThru
if ($Uninstall.ExitCode -ne 0) { throw "Uninstall failed: $($Uninstall.ExitCode)" }
Remove-Item $TestData -Recurse -Force -ErrorAction SilentlyContinue
if (Test-Path (Join-Path $Target 'syntila.exe')) { throw 'Uninstall left the app executable.' }

if ((Get-Content $State -Raw).Trim() -ne $Sentinel) { throw 'Installer changed runtime state.' }
Remove-Item $State
