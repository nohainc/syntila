# Run only on a disposable Windows CI runner. Uses an isolated application folder.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Root = Split-Path $PSScriptRoot -Parent
$Installer = @(Get-ChildItem (Join-Path $Root 'dist/connect/installer/*Setup.exe'))
if ($Installer.Count -ne 1) { throw 'Expected exactly one Connect installer.' }
$Target = Join-Path $env:LOCALAPPDATA 'Programs/Syntila/Connect-Installer-Test'
function Run-Setup {
    $Process = Start-Process $Installer[0].FullName -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=`"$Target`"") -Wait -PassThru
    if ($Process.ExitCode -ne 0) { throw "Setup failed: $($Process.ExitCode)" }
}

Run-Setup
foreach ($File in @('syntila-connect.exe', 'engine/syntila-worker.exe', 'syntila_connect_gui.exe')) {
    if ((Get-FileHash (Join-Path $Target $File)).Hash -ne
        (Get-FileHash (Join-Path $Root "dist/connect/windows/release/$File")).Hash) {
        throw "Installed file mismatch: $File"
    }
}
$Shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'Syntila/Syntila Connect.lnk'
if (-not (Test-Path $Shortcut)) { throw 'Syntila Connect Start menu shortcut is missing.' }

& (Join-Path $Target 'syntila-connect.exe') help | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Installed syntila-connect.exe help failed: $LASTEXITCODE" }

# Repeat installation to exercise the stable AppId upgrade path.
Run-Setup

if ($env:SYNTILA_WINDOWS_SIGNING) {
    & (Join-Path $PSScriptRoot 'sign-connect-windows.ps1') (Join-Path $Target 'unins000.exe') -VerifyOnly
}
$Uninstall = Start-Process (Join-Path $Target 'unins000.exe') -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -Wait -PassThru
if ($Uninstall.ExitCode -ne 0) { throw "Uninstall failed: $($Uninstall.ExitCode)" }
foreach ($File in @('syntila-connect.exe', 'syntila_connect_gui.exe')) {
    if (Test-Path (Join-Path $Target $File)) { throw "Uninstall left $File behind." }
}
